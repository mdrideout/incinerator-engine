//! renderer.zig - SDL3 GPU Rendering Backend
//!
//! DOMAIN: Rendering Layer (low-level)
//!
//! This module manages the GPU device and provides rendering operations.
//! It's the "how to render" layer - it knows about GPU pipelines, shaders,
//! and draw calls, but not about what's in the scene.
//!
//! Responsibilities:
//! - GPU device lifecycle (create, destroy)
//! - Graphics pipeline management (shaders, render state)
//! - Frame rendering (command buffers, render passes)
//! - Draw operations (drawMesh, etc.)
//!
//! This module does NOT:
//! - Know what simulation entities exist
//! - Own mesh data (meshes are passed in for drawing)
//! - Contain game logic or scene management
//!
//! The target build embeds one shader format and requests its matching backend:
//! Metal on macOS, Vulkan on Linux, and D3D12 by default on Windows (with an
//! explicit Vulkan fallback). Render-target formats are queried at runtime.
//!
//! The render loop follows the modern GPU pattern:
//! 1. beginFrame() - acquire command buffer, start render pass
//! 2. drawMesh() - record draw commands (call multiple times)
//! 3. endFrame() - end render pass, submit commands
//!
//! Currently implemented:
//! - Multiple pipelines (pos_color for primitives, pos_normal_uv for models)
//! - Uniform buffer for MVP transforms
//! - Texture binding with sampler
//! - Depth buffer for proper occlusion
//!
//! Future additions:
//! - Instanced rendering
//! - Shadow mapping
//! - Multiple render targets

const std = @import("std");
const zm = @import("zmath");
const shader_assets = @import("shader_assets");
const sdl = @import("sdl.zig");
const mesh_module = @import("mesh.zig");
const texture_module = @import("texture.zig");

const c = sdl.c;
const Mesh = mesh_module.Mesh;
const Texture = texture_module.Texture;
const Vertex = mesh_module.Vertex;
const VertexPNU = mesh_module.VertexPNU;
const VertexFormat = mesh_module.VertexFormat;
const OwnedTexture = texture_module.OwnedTexture;

/// MVP matrix uniform data sent to vertex shader.
/// Uses [16]f32 layout for direct compatibility with zmath's matToArr().
pub const Uniforms = extern struct {
    mvp: [16]f32,
};

/// Per-model vertex data. Normals are lit in world space, so they require the
/// inverse-transpose of the model transform in addition to clip-space MVP.
pub const ModelUniforms = extern struct {
    mvp: [16]f32,
    normal_matrix: [16]f32,
};

/// Fragment shader settings (for texture toggle, etc.)
/// Passed as uniform buffer to fragment shader.
pub const FragmentSettings = extern struct {
    use_texture: f32, // 1.0 = use texture, 0.0 = use white
    _padding: [3]f32 = .{ 0, 0, 0 }, // Pad to 16 bytes for GPU alignment
    base_color: [4]f32 = .{ 1, 1, 1, 1 },
};

comptime {
    std.debug.assert(@sizeOf(FragmentSettings) == 32);
}

/// Render settings that can be toggled at runtime.
/// These control debug visualization modes.
pub const RenderSettings = struct {
    wireframe_mode: bool = false, // Draw meshes as wireframes
    show_textures: bool = true, // Sample textures (false = white)
};

/// A frame is either ready for draw commands or temporarily unavailable
/// because the window cannot currently provide a swapchain texture.
/// All GPU/SDL failures are returned as errors instead of being conflated with
/// the benign unavailable state.
pub const FrameStatus = enum {
    ready,
    unavailable,
};

/// Explicit checkpoints for native teardown validation. These are intentionally
/// aligned with real SDL GPU ownership transitions so an injected failure runs
/// the same `errdefer` cleanup as a production initialization error.
pub const InitFailurePoint = enum {
    after_window_claim,
    after_pipelines,
    after_placeholder_resources,
};

fn injectInitFailure(configured: ?InitFailurePoint, reached: InitFailurePoint) !void {
    if (configured == reached) return error.InjectedRendererInitFailure;
}

const DepthTarget = struct {
    texture: *c.SDL_GPUTexture,
    width: u32,
    height: u32,
};

const ReleaseTextureFn = *const fn (*anyopaque, *c.SDL_GPUTexture) void;

fn releaseGpuTexture(context: *anyopaque, gpu_texture: *c.SDL_GPUTexture) void {
    const device: *c.SDL_GPUDevice = @ptrCast(@alignCast(context));
    c.SDL_ReleaseGPUTexture(device, gpu_texture);
}

/// Commit a replacement only after creation succeeds. Keeping this small seam
/// separate makes the lifetime transition testable without creating a GPU.
fn commitDepthReplacement(
    target: *DepthTarget,
    replacement: ?*c.SDL_GPUTexture,
    width: u32,
    height: u32,
    release_context: *anyopaque,
    release_texture: ReleaseTextureFn,
) !void {
    const next = replacement orelse return error.DepthTextureCreationFailed;
    const previous = target.texture;
    target.* = .{
        .texture = next,
        .width = width,
        .height = height,
    };
    release_texture(release_context, previous);
}

fn cancelCommandBuffer(cmd: *c.SDL_GPUCommandBuffer) !void {
    if (!c.SDL_CancelGPUCommandBuffer(cmd)) {
        std.debug.print("SDL_CancelGPUCommandBuffer failed: {s}\n", .{c.SDL_GetError()});
        return error.CommandBufferCancelFailed;
    }
}

/// Once a non-null swapchain texture has been acquired SDL requires the
/// command buffer to be submitted, even when later frame setup fails.
fn retireAcquiredSwapchain(cmd: *c.SDL_GPUCommandBuffer) !void {
    if (!c.SDL_SubmitGPUCommandBuffer(cmd)) {
        std.debug.print("SDL_SubmitGPUCommandBuffer failed while retiring a swapchain texture: {s}\n", .{c.SDL_GetError()});
        return error.CommandBufferSubmissionFailed;
    }
}

const AcquireFailureCleanup = enum { cancel, submit };

fn acquireFailureCleanup(swapchain_texture: ?*c.SDL_GPUTexture) AcquireFailureCleanup {
    return if (swapchain_texture == null) .cancel else .submit;
}

// ============================================================================
// Shader Loading (Platform-Aware)
// ============================================================================

/// Load shaders at compile time based on target platform.
/// This embeds the correct shader format directly into the binary.
const ShaderCode = struct {
    vertex: []const u8,
    fragment: []const u8,
    format: c.SDL_GPUShaderFormat,
    entrypoint: [*:0]const u8,
};

fn embeddedShaderFormat() c.SDL_GPUShaderFormat {
    return switch (shader_assets.format) {
        .msl => c.SDL_GPU_SHADERFORMAT_MSL,
        .spirv => c.SDL_GPU_SHADERFORMAT_SPIRV,
        .dxil => c.SDL_GPU_SHADERFORMAT_DXIL,
    };
}

fn normalMatrix(model: zm.Mat) zm.Mat {
    return zm.transpose(zm.inverse(model));
}

/// Get triangle shaders (pos + color vertex format) for primitives
fn getTriangleShaderCode() ShaderCode {
    return .{
        .vertex = shader_assets.triangle_vertex,
        .fragment = shader_assets.triangle_fragment,
        .format = embeddedShaderFormat(),
        .entrypoint = shader_assets.entrypoint,
    };
}

/// Get model shaders (pos + normal + uv vertex format) for loaded 3D models
fn getModelShaderCode() ShaderCode {
    return .{
        .vertex = shader_assets.model_vertex,
        .fragment = shader_assets.model_fragment,
        .format = embeddedShaderFormat(),
        .entrypoint = shader_assets.entrypoint,
    };
}

// ============================================================================
// Renderer
// ============================================================================

/// Renderer manages the SDL_GPU device and handles frame rendering.
pub const Renderer = struct {
    device: *c.SDL_GPUDevice,
    window: *c.SDL_Window,
    swapchain_format: c.SDL_GPUTextureFormat,
    depth_format: c.SDL_GPUTextureFormat,

    // Graphics pipelines for different vertex formats
    pipeline_pos_color: *c.SDL_GPUGraphicsPipeline, // For primitives (Vertex)
    pipeline_pos_normal_uv: *c.SDL_GPUGraphicsPipeline, // For loaded models (VertexPNU)
    pipeline_pos_normal_uv_wireframe: *c.SDL_GPUGraphicsPipeline, // For models in wireframe mode
    pipeline_lines: *c.SDL_GPUGraphicsPipeline, // For debug lines (Vertex format, LINELIST primitive)

    // Runtime render settings (wireframe, textures, etc.)
    render_settings: RenderSettings = .{},

    // Depth buffer for proper 3D rendering (closer pixels occlude farther ones)
    depth_target: DepthTarget,

    // Texture sampling resources
    default_sampler: *c.SDL_GPUSampler,
    placeholder_texture: OwnedTexture, // 1x1 white texture for untextured meshes

    // Frame state (valid between beginFrame and endFrame/submitFrame)
    current_cmd: ?*c.SDL_GPUCommandBuffer = null,
    current_render_pass: ?*c.SDL_GPURenderPass = null,
    current_swapchain: ?*c.SDL_GPUTexture = null, // Swapchain texture for this frame

    /// Initialize the GPU renderer for a window.
    /// This creates the GPU device and graphics pipeline.
    pub fn init(window: *c.SDL_Window) !Renderer {
        return initWithFailurePoint(window, null);
    }

    /// Initialize with a deliberate failure at a real ownership boundary.
    /// Intended for bounded native lifecycle smokes; normal callers use init.
    pub fn initWithFailurePoint(
        window: *c.SDL_Window,
        failure_point: ?InitFailurePoint,
    ) !Renderer {
        // Advertise only the format embedded in this target binary. SDL uses
        // that contract to select a compatible backend; claiming a format for
        // which no bytecode exists can select an unusable device.
        const shader_format = embeddedShaderFormat();
        if (!c.SDL_GPUSupportsShaderFormats(shader_format, shader_assets.driver)) {
            std.debug.print(
                "SDL GPU driver {s} does not support the embedded shader format: {s}\n",
                .{ shader_assets.driver, c.SDL_GetError() },
            );
            return error.UnsupportedShaderFormat;
        }

        const device = c.SDL_CreateGPUDevice(
            shader_format,
            true, // debug_mode: enables validation layers
            shader_assets.driver,
        ) orelse {
            std.debug.print("SDL_CreateGPUDevice failed: {s}\n", .{c.SDL_GetError()});
            return error.GPUDeviceCreationFailed;
        };
        errdefer c.SDL_DestroyGPUDevice(device);

        // Log which GPU driver SDL selected
        const driver_name = c.SDL_GetGPUDeviceDriver(device);
        std.debug.print("GPU Device created: {s}\n", .{driver_name});

        if (c.SDL_GetGPUShaderFormats(device) & shader_format == 0) {
            std.debug.print("GPU backend {s} does not accept the embedded shader format\n", .{driver_name});
            return error.UnsupportedShaderFormat;
        }

        // Claim the window for GPU rendering (creates the swapchain)
        if (!c.SDL_ClaimWindowForGPUDevice(device, window)) {
            std.debug.print("SDL_ClaimWindowForGPUDevice failed: {s}\n", .{c.SDL_GetError()});
            return error.GPUWindowClaimFailed;
        }
        errdefer c.SDL_ReleaseWindowFromGPUDevice(device, window);
        try injectInitFailure(failure_point, .after_window_claim);

        const swapchain_format = c.SDL_GetGPUSwapchainTextureFormat(device, window);
        if (swapchain_format == c.SDL_GPU_TEXTUREFORMAT_INVALID) {
            std.debug.print("SDL_GetGPUSwapchainTextureFormat failed: {s}\n", .{c.SDL_GetError()});
            return error.SwapchainFormatUnavailable;
        }

        const depth_format = selectDepthFormat(device) orelse {
            std.debug.print("No supported SDL GPU depth-target format is available\n", .{});
            return error.DepthFormatUnavailable;
        };

        // Create graphics pipelines for different vertex formats
        // Pipeline 1: pos_color for primitives (triangle, cube, etc.)
        const pipeline_pos_color = try createPipelinePosColor(device, swapchain_format, depth_format);
        errdefer c.SDL_ReleaseGPUGraphicsPipeline(device, pipeline_pos_color);

        // Pipeline 2: pos_normal_uv for loaded 3D models (GLB files)
        const pipeline_pos_normal_uv = try createPipelinePosNormalUv(device, swapchain_format, depth_format, false);
        errdefer c.SDL_ReleaseGPUGraphicsPipeline(device, pipeline_pos_normal_uv);

        // Pipeline 3: pos_normal_uv wireframe variant for debug visualization
        const pipeline_pos_normal_uv_wireframe = try createPipelinePosNormalUv(device, swapchain_format, depth_format, true);
        errdefer c.SDL_ReleaseGPUGraphicsPipeline(device, pipeline_pos_normal_uv_wireframe);

        // Pipeline 4: lines for debug visualization (physics colliders, etc.)
        const pipeline_lines = try createPipelineLines(device, swapchain_format, depth_format);
        errdefer c.SDL_ReleaseGPUGraphicsPipeline(device, pipeline_lines);
        try injectInitFailure(failure_point, .after_pipelines);

        // Get initial window size for depth buffer
        var w: c_int = 0;
        var h: c_int = 0;
        if (!c.SDL_GetWindowSizeInPixels(window, &w, &h) or w <= 0 or h <= 0) {
            std.debug.print("SDL_GetWindowSizeInPixels failed or returned an empty drawable: {s}\n", .{c.SDL_GetError()});
            return error.InvalidDrawableSize;
        }
        const width: u32 = @intCast(w);
        const height: u32 = @intCast(h);

        // Create depth texture (same size as window)
        const depth_texture = createDepthTexture(device, depth_format, width, height) orelse {
            std.debug.print("Failed to create depth texture: {s}\n", .{c.SDL_GetError()});
            return error.DepthTextureCreationFailed;
        };
        errdefer c.SDL_ReleaseGPUTexture(device, depth_texture);

        // Create default sampler for texture sampling (linear filtering)
        const default_sampler = c.SDL_CreateGPUSampler(device, &c.SDL_GPUSamplerCreateInfo{
            .min_filter = c.SDL_GPU_FILTER_LINEAR,
            .mag_filter = c.SDL_GPU_FILTER_LINEAR,
            .mipmap_mode = c.SDL_GPU_SAMPLERMIPMAPMODE_LINEAR,
            .address_mode_u = c.SDL_GPU_SAMPLERADDRESSMODE_REPEAT,
            .address_mode_v = c.SDL_GPU_SAMPLERADDRESSMODE_REPEAT,
            .address_mode_w = c.SDL_GPU_SAMPLERADDRESSMODE_REPEAT,
            .mip_lod_bias = 0.0,
            .max_anisotropy = 1.0,
            .compare_op = c.SDL_GPU_COMPAREOP_INVALID,
            .min_lod = 0.0,
            .max_lod = 1000.0,
            .enable_anisotropy = false,
            .enable_compare = false,
            .padding1 = 0,
            .padding2 = 0,
            .props = 0,
        }) orelse {
            std.debug.print("Failed to create sampler: {s}\n", .{c.SDL_GetError()});
            return error.SamplerCreationFailed;
        };
        errdefer c.SDL_ReleaseGPUSampler(device, default_sampler);

        // Create placeholder texture (1x1 white) for untextured meshes
        var placeholder_texture = try texture_module.createPlaceholderTexture(device);
        errdefer placeholder_texture.deinit();
        try injectInitFailure(failure_point, .after_placeholder_resources);

        std.debug.print(
            "Renderer initialized (swapchain format {d}, depth format {d})\n",
            .{ swapchain_format, depth_format },
        );

        return Renderer{
            .device = device,
            .window = window,
            .swapchain_format = swapchain_format,
            .depth_format = depth_format,
            .pipeline_pos_color = pipeline_pos_color,
            .pipeline_pos_normal_uv = pipeline_pos_normal_uv,
            .pipeline_pos_normal_uv_wireframe = pipeline_pos_normal_uv_wireframe,
            .pipeline_lines = pipeline_lines,
            .depth_target = .{
                .texture = depth_texture,
                .width = width,
                .height = height,
            },
            .default_sampler = default_sampler,
            .placeholder_texture = placeholder_texture,
        };
    }

    /// Clean up GPU resources
    pub fn deinit(self: *Renderer) void {
        // A ready frame owns a non-cancellable swapchain acquisition. Retire it
        // before releasing any pipeline/target resources, including during
        // error unwinding from future fallible draw work.
        self.endRenderPass();
        if (self.current_cmd) |cmd| {
            if (!c.SDL_SubmitGPUCommandBuffer(cmd)) {
                std.debug.print("SDL_SubmitGPUCommandBuffer failed during renderer teardown: {s}\n", .{c.SDL_GetError()});
            }
            self.current_cmd = null;
            self.current_swapchain = null;
        }

        self.placeholder_texture.deinit();
        c.SDL_ReleaseGPUSampler(self.device, self.default_sampler);
        c.SDL_ReleaseGPUTexture(self.device, self.depth_target.texture);
        c.SDL_ReleaseGPUGraphicsPipeline(self.device, self.pipeline_pos_color);
        c.SDL_ReleaseGPUGraphicsPipeline(self.device, self.pipeline_pos_normal_uv);
        c.SDL_ReleaseGPUGraphicsPipeline(self.device, self.pipeline_pos_normal_uv_wireframe);
        c.SDL_ReleaseGPUGraphicsPipeline(self.device, self.pipeline_lines);
        c.SDL_ReleaseWindowFromGPUDevice(self.device, self.window);
        c.SDL_DestroyGPUDevice(self.device);
    }

    /// Get the GPU device (needed for creating meshes).
    pub fn getDevice(self: *Renderer) *c.SDL_GPUDevice {
        return self.device;
    }

    /// Actual format selected for this claimed window's swapchain.
    pub fn getSwapchainFormat(self: *const Renderer) c.SDL_GPUTextureFormat {
        return self.swapchain_format;
    }

    // ========================================================================
    // Frame Rendering
    // ========================================================================

    /// Begin a new frame. A ready frame must eventually be submitted.
    /// `.unavailable` is reserved for a benign missing swapchain texture, such
    /// as a minimized window; all SDL/GPU failures are returned as errors.
    pub fn beginFrame(self: *Renderer, clear_color: [4]f32) !FrameStatus {
        if (self.current_cmd != null or self.current_render_pass != null) {
            return error.FrameAlreadyInProgress;
        }

        // Step 1: Acquire a command buffer
        const cmd = c.SDL_AcquireGPUCommandBuffer(self.device) orelse {
            std.debug.print("SDL_AcquireGPUCommandBuffer failed: {s}\n", .{c.SDL_GetError()});
            return error.CommandBufferAcquisitionFailed;
        };

        // Step 2: Wait for normal GPU backpressure, then acquire the swapchain
        // texture. A null texture after a successful call is benign (usually a
        // minimized window) and leaves the command buffer safe to cancel.
        var swapchain_texture: ?*c.SDL_GPUTexture = null;
        var swapchain_width: u32 = 0;
        var swapchain_height: u32 = 0;
        if (!c.SDL_WaitAndAcquireGPUSwapchainTexture(cmd, self.window, &swapchain_texture, &swapchain_width, &swapchain_height)) {
            std.debug.print("SDL_WaitAndAcquireGPUSwapchainTexture failed: {s}\n", .{c.SDL_GetError()});
            switch (acquireFailureCleanup(swapchain_texture)) {
                .cancel => try cancelCommandBuffer(cmd),
                .submit => try retireAcquiredSwapchain(cmd),
            }
            return error.SwapchainAcquisitionFailed;
        }

        if (swapchain_texture == null) {
            try cancelCommandBuffer(cmd);
            return .unavailable;
        }
        const acquired_swapchain = swapchain_texture.?;

        if (swapchain_width == 0 or swapchain_height == 0) {
            try retireAcquiredSwapchain(cmd);
            return error.InvalidSwapchainSize;
        }

        // Step 3: Recreate depth buffer if window was resized
        if (swapchain_width != self.depth_target.width or swapchain_height != self.depth_target.height) {
            const replacement = createDepthTexture(
                self.device,
                self.depth_format,
                swapchain_width,
                swapchain_height,
            );
            commitDepthReplacement(
                &self.depth_target,
                replacement,
                swapchain_width,
                swapchain_height,
                @ptrCast(self.device),
                releaseGpuTexture,
            ) catch |err| {
                std.debug.print("Failed to recreate depth texture: {s}\n", .{c.SDL_GetError()});
                try retireAcquiredSwapchain(cmd);
                return err;
            };
        }

        // Step 4: Set up color target (what we see on screen)
        const color_target = c.SDL_GPUColorTargetInfo{
            .texture = acquired_swapchain,
            .mip_level = 0,
            .layer_or_depth_plane = 0,
            .clear_color = c.SDL_FColor{
                .r = clear_color[0],
                .g = clear_color[1],
                .b = clear_color[2],
                .a = clear_color[3],
            },
            .load_op = c.SDL_GPU_LOADOP_CLEAR,
            .store_op = c.SDL_GPU_STOREOP_STORE,
            .resolve_texture = null,
            .resolve_mip_level = 0,
            .resolve_layer = 0,
            .cycle = false,
            .cycle_resolve_texture = false,
            .padding1 = 0,
            .padding2 = 0,
        };

        // Step 5: Set up depth target (for depth testing)
        const depth_target = c.SDL_GPUDepthStencilTargetInfo{
            .texture = self.depth_target.texture,
            .clear_depth = 1.0, // Clear to far plane (max depth)
            .load_op = c.SDL_GPU_LOADOP_CLEAR,
            .store_op = c.SDL_GPU_STOREOP_DONT_CARE, // Don't need to preserve after frame
            .stencil_load_op = c.SDL_GPU_LOADOP_DONT_CARE,
            .stencil_store_op = c.SDL_GPU_STOREOP_DONT_CARE,
            .cycle = false,
            .clear_stencil = 0,
            .mip_level = 0,
            .layer = 0,
        };

        // Step 6: Begin render pass with both color and depth targets
        const render_pass = c.SDL_BeginGPURenderPass(
            cmd,
            &color_target,
            1,
            &depth_target, // Now passing depth target!
        ) orelse {
            std.debug.print("SDL_BeginGPURenderPass failed: {s}\n", .{c.SDL_GetError()});
            try retireAcquiredSwapchain(cmd);
            return error.RenderPassBeginFailed;
        };

        // Note: Pipeline is bound per-draw in drawMesh() based on mesh vertex format

        // Store frame state
        self.current_cmd = cmd;
        self.current_render_pass = render_pass;
        self.current_swapchain = acquired_swapchain; // Store for editor overlay

        return .ready;
    }

    /// Draw a mesh with its model and view-projection matrices.
    /// Must be called between beginFrame() and endFrame().
    ///
    /// Automatically selects the correct pipeline based on mesh vertex format
    /// and handles both indexed and non-indexed rendering.
    ///
    pub fn drawMesh(self: *Renderer, m: *const Mesh, model: zm.Mat, view_projection: zm.Mat) void {
        self.drawMeshWithMaterial(
            m,
            m.diffuse_texture,
            .{ 1, 1, 1, 1 },
            model,
            view_projection,
        );
    }

    /// Draw a mesh with an explicitly resolved material texture.
    ///
    /// Streamed scene registries keep mesh and material ownership separate;
    /// this seam lets them supply a borrowed texture without mutating `Mesh`.
    /// Legacy callers continue through `drawMesh` and its mesh-local view.
    pub fn drawMeshWithTexture(
        self: *Renderer,
        m: *const Mesh,
        diffuse_texture: ?Texture,
        model: zm.Mat,
        view_projection: zm.Mat,
    ) void {
        self.drawMeshWithMaterial(
            m,
            diffuse_texture,
            .{ 1, 1, 1, 1 },
            model,
            view_projection,
        );
    }

    /// Draw a mesh with independently resolved material inputs.
    pub fn drawMeshWithMaterial(
        self: *Renderer,
        m: *const Mesh,
        diffuse_texture: ?Texture,
        base_color: [4]f32,
        model: zm.Mat,
        view_projection: zm.Mat,
    ) void {
        const render_pass = self.current_render_pass orelse {
            std.debug.print("drawMesh called outside of beginFrame/endFrame\n", .{});
            return;
        };

        const cmd = self.current_cmd orelse return;

        // =====================================================================
        // Step 1: Bind the correct pipeline based on vertex format and settings
        // =====================================================================
        // Each pipeline has a different vertex layout configured, so we must
        // bind the one that matches the mesh's vertex data.
        // Wireframe mode uses a variant pipeline with FILLMODE_LINE.
        const pipeline = switch (m.vertex_format) {
            .pos_color => self.pipeline_pos_color,
            .pos_normal_uv => if (self.render_settings.wireframe_mode)
                self.pipeline_pos_normal_uv_wireframe
            else
                self.pipeline_pos_normal_uv,
        };
        c.SDL_BindGPUGraphicsPipeline(render_pass, pipeline);

        // =====================================================================
        // Step 2: Push vertex uniforms. Models additionally receive an
        // inverse-transpose normal matrix so lighting stays in world space
        // under rotation and non-uniform scale.
        // =====================================================================
        const mvp = zm.mul(model, view_projection);
        switch (m.vertex_format) {
            .pos_color => {
                const uniforms = Uniforms{ .mvp = zm.matToArr(mvp) };
                c.SDL_PushGPUVertexUniformData(cmd, 0, &uniforms, @sizeOf(Uniforms));
            },
            .pos_normal_uv => {
                const uniforms = ModelUniforms{
                    .mvp = zm.matToArr(mvp),
                    .normal_matrix = zm.matToArr(normalMatrix(model)),
                };
                c.SDL_PushGPUVertexUniformData(cmd, 0, &uniforms, @sizeOf(ModelUniforms));
            },
        }

        // =====================================================================
        // Step 3: Bind texture, sampler, and push fragment settings
        // =====================================================================
        if (m.vertex_format == .pos_normal_uv) {
            // Use mesh's texture if available, otherwise use placeholder (white)
            const texture_handle = if (diffuse_texture) |tex|
                tex.getHandle()
            else
                self.placeholder_texture.borrow().getHandle();

            const sampler_binding = c.SDL_GPUTextureSamplerBinding{
                .texture = texture_handle,
                .sampler = self.default_sampler,
            };
            c.SDL_BindGPUFragmentSamplers(render_pass, 0, &sampler_binding, 1);

            // Push fragment settings (texture toggle)
            const frag_settings = FragmentSettings{
                .use_texture = if (self.render_settings.show_textures) 1.0 else 0.0,
                .base_color = base_color,
            };
            c.SDL_PushGPUFragmentUniformData(cmd, 0, &frag_settings, @sizeOf(FragmentSettings));
        }

        // =====================================================================
        // Step 4: Bind vertex buffer
        // =====================================================================
        const buffer_binding = c.SDL_GPUBufferBinding{
            .buffer = m.vertex_buffer,
            .offset = 0,
        };
        c.SDL_BindGPUVertexBuffers(render_pass, 0, &buffer_binding, 1);

        // =====================================================================
        // Step 5: Draw (indexed or non-indexed)
        // =====================================================================
        if (m.isIndexed()) {
            // Indexed rendering: Use index buffer to look up vertices
            // This is more memory-efficient as vertices can be shared
            c.SDL_BindGPUIndexBuffer(
                render_pass,
                &c.SDL_GPUBufferBinding{
                    .buffer = m.index_buffer.?, // We know it's non-null from isIndexed()
                    .offset = 0,
                },
                c.SDL_GPU_INDEXELEMENTSIZE_32BIT, // u32 indices
            );
            c.SDL_DrawGPUIndexedPrimitives(render_pass, m.index_count, 1, 0, 0, 0);
        } else {
            // Non-indexed rendering: Every 3 vertices form a triangle
            c.SDL_DrawGPUPrimitives(render_pass, m.vertex_count, 1, 0, 0);
        }
    }

    /// Draw debug lines with the given MVP matrix.
    /// Used for physics debug visualization (collision shapes, velocities, etc.)
    ///
    /// vertex_buffer: GPU buffer containing Vertex data (pos + color)
    /// vertex_count: Number of vertices (must be even - each pair forms a line)
    /// mvp: Model-View-Projection matrix for transforming vertices
    pub fn drawLines(self: *Renderer, vertex_buffer: *c.SDL_GPUBuffer, vertex_count: u32, mvp: zm.Mat) void {
        const render_pass = self.current_render_pass orelse {
            std.debug.print("drawLines called outside of beginFrame/endFrame\n", .{});
            return;
        };

        const cmd = self.current_cmd orelse return;

        // Bind the line pipeline (uses LINELIST primitive type)
        c.SDL_BindGPUGraphicsPipeline(render_pass, self.pipeline_lines);

        // Push MVP matrix to vertex shader
        const uniforms = Uniforms{ .mvp = zm.matToArr(mvp) };
        c.SDL_PushGPUVertexUniformData(cmd, 0, &uniforms, @sizeOf(Uniforms));

        // Bind vertex buffer
        const buffer_binding = c.SDL_GPUBufferBinding{
            .buffer = vertex_buffer,
            .offset = 0,
        };
        c.SDL_BindGPUVertexBuffers(render_pass, 0, &buffer_binding, 1);

        // Draw lines (every 2 vertices form a line segment)
        c.SDL_DrawGPUPrimitives(render_pass, vertex_count, 1, 0, 0);
    }

    /// Draw debug triangles with the given MVP matrix.
    /// Used for physics debug visualization (solid collision shapes).
    ///
    /// vertex_buffer: GPU buffer containing Vertex data (pos + color)
    /// vertex_count: Number of vertices (must be multiple of 3)
    /// mvp: Model-View-Projection matrix for transforming vertices
    pub fn drawDebugTriangles(self: *Renderer, vertex_buffer: *c.SDL_GPUBuffer, vertex_count: u32, mvp: zm.Mat) void {
        const render_pass = self.current_render_pass orelse {
            std.debug.print("drawDebugTriangles called outside of beginFrame/endFrame\n", .{});
            return;
        };

        const cmd = self.current_cmd orelse return;

        // Bind the pos_color pipeline (uses TRIANGLELIST primitive type)
        c.SDL_BindGPUGraphicsPipeline(render_pass, self.pipeline_pos_color);

        // Push MVP matrix to vertex shader
        const uniforms = Uniforms{ .mvp = zm.matToArr(mvp) };
        c.SDL_PushGPUVertexUniformData(cmd, 0, &uniforms, @sizeOf(Uniforms));

        // Bind vertex buffer
        const buffer_binding = c.SDL_GPUBufferBinding{
            .buffer = vertex_buffer,
            .offset = 0,
        };
        c.SDL_BindGPUVertexBuffers(render_pass, 0, &buffer_binding, 1);

        // Draw triangles
        c.SDL_DrawGPUPrimitives(render_pass, vertex_count, 1, 0, 0);
    }

    /// End just the render pass (without submitting).
    /// Use this when you need to do GPU work between the scene render pass
    /// and frame submission (e.g., ImGui rendering needs a copy pass first).
    pub fn endRenderPass(self: *Renderer) void {
        if (self.current_render_pass) |render_pass| {
            c.SDL_EndGPURenderPass(render_pass);
            self.current_render_pass = null;
        }
    }

    /// Submit the command buffer and present to screen.
    /// Call this after endRenderPass() and any additional rendering (like ImGui).
    pub fn submitFrame(self: *Renderer) !void {
        const cmd = self.current_cmd orelse return error.NoFrameInProgress;
        if (self.current_render_pass != null) return error.RenderPassStillActive;

        defer {
            self.current_cmd = null;
            self.current_swapchain = null;
        }

        if (!c.SDL_SubmitGPUCommandBuffer(cmd)) {
            std.debug.print("SDL_SubmitGPUCommandBuffer failed: {s}\n", .{c.SDL_GetError()});
            return error.CommandBufferSubmissionFailed;
        }
    }

    /// End the current frame and present to screen.
    /// Convenience method that calls endRenderPass() and submitFrame().
    pub fn endFrame(self: *Renderer) !void {
        self.endRenderPass();
        try self.submitFrame();
    }

    /// Get the swapchain texture for additional render passes (e.g., ImGui overlay).
    /// Returns the texture that was acquired in beginFrame().
    /// Returns null if no frame is in progress.
    pub fn getSwapchainTexture(self: *Renderer) ?*c.SDL_GPUTexture {
        return self.current_swapchain;
    }

    /// Get the window dimensions
    pub fn getWindowSize(self: *const Renderer) struct { width: i32, height: i32 } {
        var w: c_int = 0;
        var h: c_int = 0;
        _ = c.SDL_GetWindowSize(self.window, &w, &h);
        return .{ .width = w, .height = h };
    }
};

// ============================================================================
// Pipeline Creation
// ============================================================================

const preferred_depth_formats = [_]c.SDL_GPUTextureFormat{
    c.SDL_GPU_TEXTUREFORMAT_D32_FLOAT,
    c.SDL_GPU_TEXTUREFORMAT_D24_UNORM,
    c.SDL_GPU_TEXTUREFORMAT_D16_UNORM,
};

fn selectDepthFormat(device: *c.SDL_GPUDevice) ?c.SDL_GPUTextureFormat {
    for (preferred_depth_formats) |format| {
        if (c.SDL_GPUTextureSupportsFormat(
            device,
            format,
            c.SDL_GPU_TEXTURETYPE_2D,
            c.SDL_GPU_TEXTUREUSAGE_DEPTH_STENCIL_TARGET,
        )) return format;
    }
    return null;
}

/// Create pipeline for pos_color vertex format (primitives like cube, triangle)
fn createPipelinePosColor(
    device: *c.SDL_GPUDevice,
    swapchain_format: c.SDL_GPUTextureFormat,
    depth_format: c.SDL_GPUTextureFormat,
) !*c.SDL_GPUGraphicsPipeline {
    const shaders = getTriangleShaderCode();

    // Create vertex shader
    // NOTE: num_uniform_buffers = 1 tells SDL_GPU we have a uniform buffer at binding 0
    const vertex_shader = c.SDL_CreateGPUShader(device, &c.SDL_GPUShaderCreateInfo{
        .code = shaders.vertex.ptr,
        .code_size = shaders.vertex.len,
        .entrypoint = shaders.entrypoint,
        .format = shaders.format,
        .stage = c.SDL_GPU_SHADERSTAGE_VERTEX,
        .num_samplers = 0,
        .num_storage_textures = 0,
        .num_storage_buffers = 0,
        .num_uniform_buffers = 1, // MVP matrix uniform buffer
        .props = 0,
    }) orelse {
        std.debug.print("Failed to create vertex shader: {s}\n", .{c.SDL_GetError()});
        return error.ShaderCreationFailed;
    };
    defer c.SDL_ReleaseGPUShader(device, vertex_shader);

    // Create fragment shader
    const fragment_shader = c.SDL_CreateGPUShader(device, &c.SDL_GPUShaderCreateInfo{
        .code = shaders.fragment.ptr,
        .code_size = shaders.fragment.len,
        .entrypoint = shaders.entrypoint,
        .format = shaders.format,
        .stage = c.SDL_GPU_SHADERSTAGE_FRAGMENT,
        .num_samplers = 0,
        .num_storage_textures = 0,
        .num_storage_buffers = 0,
        .num_uniform_buffers = 0,
        .props = 0,
    }) orelse {
        std.debug.print("Failed to create fragment shader: {s}\n", .{c.SDL_GetError()});
        return error.ShaderCreationFailed;
    };
    defer c.SDL_ReleaseGPUShader(device, fragment_shader);

    // Define vertex buffer layout (must match Vertex struct in mesh.zig)
    const vertex_buffer_desc = c.SDL_GPUVertexBufferDescription{
        .slot = 0,
        .pitch = @sizeOf(Vertex), // Bytes between vertices
        .input_rate = c.SDL_GPU_VERTEXINPUTRATE_VERTEX,
        .instance_step_rate = 0,
    };

    // Define vertex attributes (must match shader inputs!)
    const vertex_attributes = [_]c.SDL_GPUVertexAttribute{
        // layout(location = 0) in vec3 in_position
        .{
            .location = 0,
            .buffer_slot = 0,
            .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT3,
            .offset = @offsetOf(Vertex, "position"),
        },
        // layout(location = 1) in vec3 in_color
        .{
            .location = 1,
            .buffer_slot = 0,
            .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT3,
            .offset = @offsetOf(Vertex, "color"),
        },
    };

    // Color target description must match the claimed window's swapchain.
    const color_target_desc = c.SDL_GPUColorTargetDescription{
        .format = swapchain_format,
        .blend_state = .{
            .src_color_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE,
            .dst_color_blendfactor = c.SDL_GPU_BLENDFACTOR_ZERO,
            .color_blend_op = c.SDL_GPU_BLENDOP_ADD,
            .src_alpha_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE,
            .dst_alpha_blendfactor = c.SDL_GPU_BLENDFACTOR_ZERO,
            .alpha_blend_op = c.SDL_GPU_BLENDOP_ADD,
            .color_write_mask = 0xF, // Write all channels (RGBA)
            .enable_blend = false,
            .enable_color_write_mask = false,
            .padding1 = 0,
            .padding2 = 0,
        },
    };

    // Create the graphics pipeline
    const pipeline = c.SDL_CreateGPUGraphicsPipeline(device, &c.SDL_GPUGraphicsPipelineCreateInfo{
        .vertex_shader = vertex_shader,
        .fragment_shader = fragment_shader,
        .vertex_input_state = .{
            .vertex_buffer_descriptions = &vertex_buffer_desc,
            .num_vertex_buffers = 1,
            .vertex_attributes = &vertex_attributes,
            .num_vertex_attributes = vertex_attributes.len,
        },
        .primitive_type = c.SDL_GPU_PRIMITIVETYPE_TRIANGLELIST,
        .rasterizer_state = .{
            .fill_mode = c.SDL_GPU_FILLMODE_FILL,
            .cull_mode = c.SDL_GPU_CULLMODE_BACK, // Cull back faces (interior)
            .front_face = c.SDL_GPU_FRONTFACE_CLOCKWISE, // Our vertices are CW when viewed from outside
            .depth_bias_constant_factor = 0,
            .depth_bias_clamp = 0,
            .depth_bias_slope_factor = 0,
            .enable_depth_bias = false,
            .enable_depth_clip = false,
            .padding1 = 0,
            .padding2 = 0,
        },
        .multisample_state = .{
            .sample_count = c.SDL_GPU_SAMPLECOUNT_1,
            .sample_mask = 0,
            .enable_mask = false,
            .enable_alpha_to_coverage = false,
            .padding2 = 0,
            .padding3 = 0,
        },
        .depth_stencil_state = .{
            .compare_op = c.SDL_GPU_COMPAREOP_LESS, // Closer pixels win
            .back_stencil_state = std.mem.zeroes(c.SDL_GPUStencilOpState),
            .front_stencil_state = std.mem.zeroes(c.SDL_GPUStencilOpState),
            .compare_mask = 0,
            .write_mask = 0,
            .enable_depth_test = true, // ENABLED: test depth before writing
            .enable_depth_write = true, // ENABLED: write depth when test passes
            .enable_stencil_test = false,
            .padding1 = 0,
            .padding2 = 0,
            .padding3 = 0,
        },
        .target_info = .{
            .color_target_descriptions = &color_target_desc,
            .num_color_targets = 1,
            .depth_stencil_format = depth_format, // Must match depth texture
            .has_depth_stencil_target = true, // ENABLED: we have a depth buffer
            .padding1 = 0,
            .padding2 = 0,
            .padding3 = 0,
        },
        .props = 0,
    }) orelse {
        std.debug.print("Failed to create graphics pipeline: {s}\n", .{c.SDL_GetError()});
        return error.PipelineCreationFailed;
    };

    return pipeline;
}

/// Create pipeline for pos_normal_uv vertex format (loaded 3D models)
/// Set wireframe=true to create a wireframe variant using FILLMODE_LINE
fn createPipelinePosNormalUv(
    device: *c.SDL_GPUDevice,
    swapchain_format: c.SDL_GPUTextureFormat,
    depth_format: c.SDL_GPUTextureFormat,
    wireframe: bool,
) !*c.SDL_GPUGraphicsPipeline {
    const shaders = getModelShaderCode();

    // Create vertex shader
    const vertex_shader = c.SDL_CreateGPUShader(device, &c.SDL_GPUShaderCreateInfo{
        .code = shaders.vertex.ptr,
        .code_size = shaders.vertex.len,
        .entrypoint = shaders.entrypoint,
        .format = shaders.format,
        .stage = c.SDL_GPU_SHADERSTAGE_VERTEX,
        .num_samplers = 0,
        .num_storage_textures = 0,
        .num_storage_buffers = 0,
        .num_uniform_buffers = 1, // MVP matrix uniform buffer
        .props = 0,
    }) orelse {
        std.debug.print("Failed to create model vertex shader: {s}\n", .{c.SDL_GetError()});
        return error.ShaderCreationFailed;
    };
    defer c.SDL_ReleaseGPUShader(device, vertex_shader);

    // Create fragment shader (with 1 texture sampler and 1 uniform buffer)
    const fragment_shader = c.SDL_CreateGPUShader(device, &c.SDL_GPUShaderCreateInfo{
        .code = shaders.fragment.ptr,
        .code_size = shaders.fragment.len,
        .entrypoint = shaders.entrypoint,
        .format = shaders.format,
        .stage = c.SDL_GPU_SHADERSTAGE_FRAGMENT,
        .num_samplers = 1, // Diffuse texture sampler
        .num_storage_textures = 0,
        .num_storage_buffers = 0,
        .num_uniform_buffers = 1, // FragmentSettings uniform buffer
        .props = 0,
    }) orelse {
        std.debug.print("Failed to create model fragment shader: {s}\n", .{c.SDL_GetError()});
        return error.ShaderCreationFailed;
    };
    defer c.SDL_ReleaseGPUShader(device, fragment_shader);

    // Define vertex buffer layout for VertexPNU (32 bytes per vertex)
    const vertex_buffer_desc = c.SDL_GPUVertexBufferDescription{
        .slot = 0,
        .pitch = @sizeOf(VertexPNU), // 32 bytes: pos(12) + normal(12) + uv(8)
        .input_rate = c.SDL_GPU_VERTEXINPUTRATE_VERTEX,
        .instance_step_rate = 0,
    };

    // Define vertex attributes matching VertexPNU and model.vert shader
    const vertex_attributes = [_]c.SDL_GPUVertexAttribute{
        // layout(location = 0) in vec3 in_position
        .{
            .location = 0,
            .buffer_slot = 0,
            .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT3,
            .offset = @offsetOf(VertexPNU, "position"),
        },
        // layout(location = 1) in vec3 in_normal
        .{
            .location = 1,
            .buffer_slot = 0,
            .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT3,
            .offset = @offsetOf(VertexPNU, "normal"),
        },
        // layout(location = 2) in vec2 in_texcoord
        .{
            .location = 2,
            .buffer_slot = 0,
            .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2,
            .offset = @offsetOf(VertexPNU, "texcoord"),
        },
    };

    // Color target description (same as pos_color pipeline)
    const color_target_desc = c.SDL_GPUColorTargetDescription{
        .format = swapchain_format,
        .blend_state = .{
            .src_color_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE,
            .dst_color_blendfactor = c.SDL_GPU_BLENDFACTOR_ZERO,
            .color_blend_op = c.SDL_GPU_BLENDOP_ADD,
            .src_alpha_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE,
            .dst_alpha_blendfactor = c.SDL_GPU_BLENDFACTOR_ZERO,
            .alpha_blend_op = c.SDL_GPU_BLENDOP_ADD,
            .color_write_mask = 0xF,
            .enable_blend = false,
            .enable_color_write_mask = false,
            .padding1 = 0,
            .padding2 = 0,
        },
    };

    // Create the graphics pipeline
    const pipeline = c.SDL_CreateGPUGraphicsPipeline(device, &c.SDL_GPUGraphicsPipelineCreateInfo{
        .vertex_shader = vertex_shader,
        .fragment_shader = fragment_shader,
        .vertex_input_state = .{
            .vertex_buffer_descriptions = &vertex_buffer_desc,
            .num_vertex_buffers = 1,
            .vertex_attributes = &vertex_attributes,
            .num_vertex_attributes = vertex_attributes.len,
        },
        .primitive_type = c.SDL_GPU_PRIMITIVETYPE_TRIANGLELIST,
        .rasterizer_state = .{
            .fill_mode = if (wireframe) c.SDL_GPU_FILLMODE_LINE else c.SDL_GPU_FILLMODE_FILL,
            .cull_mode = if (wireframe) c.SDL_GPU_CULLMODE_NONE else c.SDL_GPU_CULLMODE_BACK,
            .front_face = c.SDL_GPU_FRONTFACE_COUNTER_CLOCKWISE, // glTF uses CCW winding
            .depth_bias_constant_factor = 0,
            .depth_bias_clamp = 0,
            .depth_bias_slope_factor = 0,
            .enable_depth_bias = false,
            .enable_depth_clip = false,
            .padding1 = 0,
            .padding2 = 0,
        },
        .multisample_state = .{
            .sample_count = c.SDL_GPU_SAMPLECOUNT_1,
            .sample_mask = 0,
            .enable_mask = false,
            .enable_alpha_to_coverage = false,
            .padding2 = 0,
            .padding3 = 0,
        },
        .depth_stencil_state = .{
            .compare_op = c.SDL_GPU_COMPAREOP_LESS,
            .back_stencil_state = std.mem.zeroes(c.SDL_GPUStencilOpState),
            .front_stencil_state = std.mem.zeroes(c.SDL_GPUStencilOpState),
            .compare_mask = 0,
            .write_mask = 0,
            .enable_depth_test = true,
            .enable_depth_write = true,
            .enable_stencil_test = false,
            .padding1 = 0,
            .padding2 = 0,
            .padding3 = 0,
        },
        .target_info = .{
            .color_target_descriptions = &color_target_desc,
            .num_color_targets = 1,
            .depth_stencil_format = depth_format,
            .has_depth_stencil_target = true,
            .padding1 = 0,
            .padding2 = 0,
            .padding3 = 0,
        },
        .props = 0,
    }) orelse {
        std.debug.print("Failed to create model graphics pipeline: {s}\n", .{c.SDL_GetError()});
        return error.PipelineCreationFailed;
    };

    return pipeline;
}

/// Create pipeline for debug line rendering (physics colliders, velocities, etc.)
/// Uses the same vertex format as pos_color (Vertex) but with LINELIST primitive type.
///
/// Key differences from pos_color pipeline:
/// - Primitive type: LINELIST (every 2 vertices form a line segment)
/// - Cull mode: NONE (lines have no faces to cull)
/// - Depth write: false (lines overlay scene, don't occlude each other)
/// - Depth test: LESS_OR_EQUAL (slightly reduced z-fighting)
fn createPipelineLines(
    device: *c.SDL_GPUDevice,
    swapchain_format: c.SDL_GPUTextureFormat,
    depth_format: c.SDL_GPUTextureFormat,
) !*c.SDL_GPUGraphicsPipeline {
    const shaders = getTriangleShaderCode(); // Reuse triangle shaders (same vertex format)

    // Create vertex shader
    const vertex_shader = c.SDL_CreateGPUShader(device, &c.SDL_GPUShaderCreateInfo{
        .code = shaders.vertex.ptr,
        .code_size = shaders.vertex.len,
        .entrypoint = shaders.entrypoint,
        .format = shaders.format,
        .stage = c.SDL_GPU_SHADERSTAGE_VERTEX,
        .num_samplers = 0,
        .num_storage_textures = 0,
        .num_storage_buffers = 0,
        .num_uniform_buffers = 1, // MVP matrix uniform buffer
        .props = 0,
    }) orelse {
        std.debug.print("Failed to create line vertex shader: {s}\n", .{c.SDL_GetError()});
        return error.ShaderCreationFailed;
    };
    defer c.SDL_ReleaseGPUShader(device, vertex_shader);

    // Create fragment shader
    const fragment_shader = c.SDL_CreateGPUShader(device, &c.SDL_GPUShaderCreateInfo{
        .code = shaders.fragment.ptr,
        .code_size = shaders.fragment.len,
        .entrypoint = shaders.entrypoint,
        .format = shaders.format,
        .stage = c.SDL_GPU_SHADERSTAGE_FRAGMENT,
        .num_samplers = 0,
        .num_storage_textures = 0,
        .num_storage_buffers = 0,
        .num_uniform_buffers = 0,
        .props = 0,
    }) orelse {
        std.debug.print("Failed to create line fragment shader: {s}\n", .{c.SDL_GetError()});
        return error.ShaderCreationFailed;
    };
    defer c.SDL_ReleaseGPUShader(device, fragment_shader);

    // Vertex layout (same as pos_color pipeline - Vertex struct)
    const vertex_buffer_desc = c.SDL_GPUVertexBufferDescription{
        .slot = 0,
        .pitch = @sizeOf(Vertex), // 24 bytes: pos(12) + color(12)
        .input_rate = c.SDL_GPU_VERTEXINPUTRATE_VERTEX,
        .instance_step_rate = 0,
    };

    const vertex_attributes = [_]c.SDL_GPUVertexAttribute{
        // layout(location = 0) in vec3 in_position
        .{
            .location = 0,
            .buffer_slot = 0,
            .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT3,
            .offset = @offsetOf(Vertex, "position"),
        },
        // layout(location = 1) in vec3 in_color
        .{
            .location = 1,
            .buffer_slot = 0,
            .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT3,
            .offset = @offsetOf(Vertex, "color"),
        },
    };

    // Color target (same as other pipelines)
    const color_target_desc = c.SDL_GPUColorTargetDescription{
        .format = swapchain_format,
        .blend_state = .{
            .src_color_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE,
            .dst_color_blendfactor = c.SDL_GPU_BLENDFACTOR_ZERO,
            .color_blend_op = c.SDL_GPU_BLENDOP_ADD,
            .src_alpha_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE,
            .dst_alpha_blendfactor = c.SDL_GPU_BLENDFACTOR_ZERO,
            .alpha_blend_op = c.SDL_GPU_BLENDOP_ADD,
            .color_write_mask = 0xF,
            .enable_blend = false,
            .enable_color_write_mask = false,
            .padding1 = 0,
            .padding2 = 0,
        },
    };

    // Create the line pipeline
    const pipeline = c.SDL_CreateGPUGraphicsPipeline(device, &c.SDL_GPUGraphicsPipelineCreateInfo{
        .vertex_shader = vertex_shader,
        .fragment_shader = fragment_shader,
        .vertex_input_state = .{
            .vertex_buffer_descriptions = &vertex_buffer_desc,
            .num_vertex_buffers = 1,
            .vertex_attributes = &vertex_attributes,
            .num_vertex_attributes = vertex_attributes.len,
        },
        // KEY DIFFERENCE: LINELIST primitive type (every 2 vertices = 1 line)
        .primitive_type = c.SDL_GPU_PRIMITIVETYPE_LINELIST,
        .rasterizer_state = .{
            .fill_mode = c.SDL_GPU_FILLMODE_FILL, // No effect for lines, but required
            .cull_mode = c.SDL_GPU_CULLMODE_NONE, // Lines have no faces to cull
            .front_face = c.SDL_GPU_FRONTFACE_CLOCKWISE,
            .depth_bias_constant_factor = 0,
            .depth_bias_clamp = 0,
            .depth_bias_slope_factor = 0,
            .enable_depth_bias = false,
            .enable_depth_clip = false,
            .padding1 = 0,
            .padding2 = 0,
        },
        .multisample_state = .{
            .sample_count = c.SDL_GPU_SAMPLECOUNT_1,
            .sample_mask = 0,
            .enable_mask = false,
            .enable_alpha_to_coverage = false,
            .padding2 = 0,
            .padding3 = 0,
        },
        .depth_stencil_state = .{
            // LESS_OR_EQUAL reduces z-fighting for lines on surfaces
            .compare_op = c.SDL_GPU_COMPAREOP_LESS_OR_EQUAL,
            .back_stencil_state = std.mem.zeroes(c.SDL_GPUStencilOpState),
            .front_stencil_state = std.mem.zeroes(c.SDL_GPUStencilOpState),
            .compare_mask = 0,
            .write_mask = 0,
            .enable_depth_test = true, // Test against scene depth
            .enable_depth_write = false, // Don't write to depth (lines overlay)
            .enable_stencil_test = false,
            .padding1 = 0,
            .padding2 = 0,
            .padding3 = 0,
        },
        .target_info = .{
            .color_target_descriptions = &color_target_desc,
            .num_color_targets = 1,
            .depth_stencil_format = depth_format,
            .has_depth_stencil_target = true,
            .padding1 = 0,
            .padding2 = 0,
            .padding3 = 0,
        },
        .props = 0,
    }) orelse {
        std.debug.print("Failed to create line graphics pipeline: {s}\n", .{c.SDL_GetError()});
        return error.PipelineCreationFailed;
    };

    return pipeline;
}

/// Create a depth texture for the given dimensions
fn createDepthTexture(
    device: *c.SDL_GPUDevice,
    depth_format: c.SDL_GPUTextureFormat,
    width: u32,
    height: u32,
) ?*c.SDL_GPUTexture {
    return c.SDL_CreateGPUTexture(device, &c.SDL_GPUTextureCreateInfo{
        .type = c.SDL_GPU_TEXTURETYPE_2D,
        .format = depth_format,
        .usage = c.SDL_GPU_TEXTUREUSAGE_DEPTH_STENCIL_TARGET,
        .width = width,
        .height = height,
        .layer_count_or_depth = 1,
        .num_levels = 1,
        .sample_count = c.SDL_GPU_SAMPLECOUNT_1,
        .props = 0,
    });
}

// ============================================================================
// Color Constants
// ============================================================================

pub const Colors = struct {
    pub const CORNFLOWER_BLUE = [4]f32{ 0.392, 0.584, 0.929, 1.0 };
};

// ============================================================================
// Tests
// ============================================================================

test "Colors are valid" {
    for (Colors.CORNFLOWER_BLUE) |component| {
        try std.testing.expect(component >= 0.0 and component <= 1.0);
    }
}

test "renderer init failure injection triggers only at the selected boundary" {
    try injectInitFailure(null, .after_window_claim);
    try injectInitFailure(.after_pipelines, .after_window_claim);
    try std.testing.expectError(
        error.InjectedRendererInitFailure,
        injectInitFailure(.after_pipelines, .after_pipelines),
    );
}

test "failed swapchain acquisition cleanup never cancels an acquired texture" {
    try std.testing.expectEqual(AcquireFailureCleanup.cancel, acquireFailureCleanup(null));
    const texture: *c.SDL_GPUTexture = @ptrFromInt(0x1000);
    try std.testing.expectEqual(AcquireFailureCleanup.submit, acquireFailureCleanup(texture));
}

test "model normal matrix preserves perpendicularity under non-uniform scale" {
    try std.testing.expectEqual(@as(usize, 128), @sizeOf(ModelUniforms));

    const model = zm.mul(
        zm.scaling(2.0, 0.5, 3.0),
        zm.rotationZ(0.63),
    );
    const object_tangent = zm.normalize3(zm.f32x4(1, 1, 0, 0));
    const object_normal = zm.normalize3(zm.f32x4(1, -1, 0, 0));
    const tangent = zm.normalize3(zm.mul(object_tangent, model));
    const incorrect_normal = zm.normalize3(zm.mul(object_normal, model));
    const normal = zm.normalize3(zm.mul(object_normal, normalMatrix(model)));

    // This fixture must fail if the model matrix is accidentally used directly.
    try std.testing.expect(@abs(zm.dot3(tangent, incorrect_normal)[0]) > 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 0), zm.dot3(tangent, normal)[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1), zm.length3(normal)[0], 0.0001);
}

test "depth replacement preserves old target on failure and commits atomically" {
    const Recorder = struct {
        release_count: usize = 0,
        released: ?*c.SDL_GPUTexture = null,

        fn release(context: *anyopaque, gpu_texture: *c.SDL_GPUTexture) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.release_count += 1;
            self.released = gpu_texture;
        }
    };

    const old_texture: *c.SDL_GPUTexture = @ptrFromInt(0x1000);
    const new_texture: *c.SDL_GPUTexture = @ptrFromInt(0x2000);
    var target = DepthTarget{
        .texture = old_texture,
        .width = 640,
        .height = 480,
    };
    var recorder = Recorder{};

    try std.testing.expectError(
        error.DepthTextureCreationFailed,
        commitDepthReplacement(
            &target,
            null,
            1280,
            720,
            @ptrCast(&recorder),
            Recorder.release,
        ),
    );
    try std.testing.expectEqual(old_texture, target.texture);
    try std.testing.expectEqual(@as(u32, 640), target.width);
    try std.testing.expectEqual(@as(u32, 480), target.height);
    try std.testing.expectEqual(@as(usize, 0), recorder.release_count);

    try commitDepthReplacement(
        &target,
        new_texture,
        1280,
        720,
        @ptrCast(&recorder),
        Recorder.release,
    );
    try std.testing.expectEqual(new_texture, target.texture);
    try std.testing.expectEqual(@as(u32, 1280), target.width);
    try std.testing.expectEqual(@as(u32, 720), target.height);
    try std.testing.expectEqual(@as(usize, 1), recorder.release_count);
    try std.testing.expectEqual(old_texture, recorder.released.?);
}
