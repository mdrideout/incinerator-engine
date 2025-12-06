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
//! - Know what entities exist (that's ecs.zig)
//! - Own mesh data (meshes are passed in for drawing)
//! - Contain game logic or scene management
//!
//! SDL_GPU automatically selects the best backend for your platform:
//! - macOS: Metal
//! - Windows: D3D12 or Vulkan
//! - Linux: Vulkan
//!
//! The render loop follows the modern GPU pattern:
//! 1. beginFrame() - acquire command buffer, start render pass
//! 2. drawMesh() - record draw commands (call multiple times)
//! 3. endFrame() - end render pass, submit commands
//!
//! Future additions:
//! - Multiple pipelines (different shaders/materials)
//! - Uniform buffer updates (for transforms)
//! - Texture binding
//! - Instanced rendering
//! - Depth buffer

const std = @import("std");
const builtin = @import("builtin");
const zm = @import("zmath");
const sdl = @import("sdl.zig");
const mesh_module = @import("mesh.zig");
const texture_module = @import("texture.zig");

const c = sdl.c;
const Mesh = mesh_module.Mesh;
const Vertex = mesh_module.Vertex;
const VertexPNU = mesh_module.VertexPNU;
const VertexFormat = mesh_module.VertexFormat;
const Texture = texture_module.Texture;

/// MVP matrix uniform data sent to vertex shader.
/// Uses [16]f32 layout for direct compatibility with zmath's matToArr().
pub const Uniforms = extern struct {
    mvp: [16]f32,
};

// ============================================================================
// Shader Loading (Platform-Aware)
// ============================================================================

/// Load shaders at compile time based on target platform.
/// This embeds the correct shader format directly into the binary.
const ShaderCode = struct {
    vertex: []const u8,
    fragment: []const u8,
    format: c.SDL_GPUShaderFormat,
};

/// Get triangle shaders (pos + color vertex format) for primitives
fn getTriangleShaderCode() ShaderCode {
    return switch (builtin.os.tag) {
        .macos, .ios => .{
            .vertex = @embedFile("shaders/compiled/triangle.vert.metal"),
            .fragment = @embedFile("shaders/compiled/triangle.frag.metal"),
            .format = c.SDL_GPU_SHADERFORMAT_MSL,
        },
        // Linux and others use SPIR-V
        else => .{
            .vertex = @embedFile("shaders/compiled/triangle.vert.spv"),
            .fragment = @embedFile("shaders/compiled/triangle.frag.spv"),
            .format = c.SDL_GPU_SHADERFORMAT_SPIRV,
        },
    };
}

/// Get model shaders (pos + normal + uv vertex format) for loaded 3D models
fn getModelShaderCode() ShaderCode {
    return switch (builtin.os.tag) {
        .macos, .ios => .{
            .vertex = @embedFile("shaders/compiled/model.vert.metal"),
            .fragment = @embedFile("shaders/compiled/model.frag.metal"),
            .format = c.SDL_GPU_SHADERFORMAT_MSL,
        },
        // Linux and others use SPIR-V
        else => .{
            .vertex = @embedFile("shaders/compiled/model.vert.spv"),
            .fragment = @embedFile("shaders/compiled/model.frag.spv"),
            .format = c.SDL_GPU_SHADERFORMAT_SPIRV,
        },
    };
}

// ============================================================================
// Renderer
// ============================================================================

/// Renderer manages the SDL_GPU device and handles frame rendering.
pub const Renderer = struct {
    device: *c.SDL_GPUDevice,
    window: *c.SDL_Window,

    // Graphics pipelines for different vertex formats
    pipeline_pos_color: *c.SDL_GPUGraphicsPipeline, // For primitives (Vertex)
    pipeline_pos_normal_uv: *c.SDL_GPUGraphicsPipeline, // For loaded models (VertexPNU)

    // Depth buffer for proper 3D rendering (closer pixels occlude farther ones)
    depth_texture: *c.SDL_GPUTexture,
    depth_width: u32,
    depth_height: u32,

    // Texture sampling resources
    default_sampler: *c.SDL_GPUSampler,
    placeholder_texture: Texture, // 1x1 white texture for untextured meshes

    // Frame state (valid between beginFrame and endFrame/submitFrame)
    current_cmd: ?*c.SDL_GPUCommandBuffer = null,
    current_render_pass: ?*c.SDL_GPURenderPass = null,
    current_swapchain: ?*c.SDL_GPUTexture = null, // Swapchain texture for this frame

    /// Initialize the GPU renderer for a window.
    /// This creates the GPU device and graphics pipeline.
    pub fn init(window: *c.SDL_Window) !Renderer {
        // Create GPU device - SDL chooses the best backend automatically
        const device = c.SDL_CreateGPUDevice(
            c.SDL_GPU_SHADERFORMAT_SPIRV | c.SDL_GPU_SHADERFORMAT_MSL | c.SDL_GPU_SHADERFORMAT_DXIL,
            true, // debug_mode: enables validation layers
            null, // No specific device preference
        ) orelse {
            std.debug.print("SDL_CreateGPUDevice failed: {s}\n", .{c.SDL_GetError()});
            return error.GPUDeviceCreationFailed;
        };
        errdefer c.SDL_DestroyGPUDevice(device);

        // Log which GPU driver SDL selected
        const driver_name = c.SDL_GetGPUDeviceDriver(device);
        std.debug.print("GPU Device created: {s}\n", .{driver_name});

        // Claim the window for GPU rendering (creates the swapchain)
        if (!c.SDL_ClaimWindowForGPUDevice(device, window)) {
            std.debug.print("SDL_ClaimWindowForGPUDevice failed: {s}\n", .{c.SDL_GetError()});
            return error.GPUWindowClaimFailed;
        }

        // Create graphics pipelines for different vertex formats
        // Pipeline 1: pos_color for primitives (triangle, cube, etc.)
        const pipeline_pos_color = try createPipelinePosColor(device);
        errdefer c.SDL_ReleaseGPUGraphicsPipeline(device, pipeline_pos_color);

        // Pipeline 2: pos_normal_uv for loaded 3D models (GLB files)
        const pipeline_pos_normal_uv = try createPipelinePosNormalUv(device);
        errdefer c.SDL_ReleaseGPUGraphicsPipeline(device, pipeline_pos_normal_uv);

        // Get initial window size for depth buffer
        var w: c_int = 0;
        var h: c_int = 0;
        _ = c.SDL_GetWindowSize(window, &w, &h);
        const width: u32 = @intCast(w);
        const height: u32 = @intCast(h);

        // Create depth texture (same size as window)
        const depth_texture = createDepthTexture(device, width, height) orelse {
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

        std.debug.print("Renderer initialized successfully (with depth buffer and texture support)\n", .{});

        return Renderer{
            .device = device,
            .window = window,
            .pipeline_pos_color = pipeline_pos_color,
            .pipeline_pos_normal_uv = pipeline_pos_normal_uv,
            .depth_texture = depth_texture,
            .depth_width = width,
            .depth_height = height,
            .default_sampler = default_sampler,
            .placeholder_texture = placeholder_texture,
        };
    }

    /// Clean up GPU resources
    pub fn deinit(self: *Renderer) void {
        self.placeholder_texture.deinit();
        c.SDL_ReleaseGPUSampler(self.device, self.default_sampler);
        c.SDL_ReleaseGPUTexture(self.device, self.depth_texture);
        c.SDL_ReleaseGPUGraphicsPipeline(self.device, self.pipeline_pos_color);
        c.SDL_ReleaseGPUGraphicsPipeline(self.device, self.pipeline_pos_normal_uv);
        c.SDL_ReleaseWindowFromGPUDevice(self.device, self.window);
        c.SDL_DestroyGPUDevice(self.device);
    }

    /// Get the GPU device (needed for creating meshes).
    pub fn getDevice(self: *Renderer) *c.SDL_GPUDevice {
        return self.device;
    }

    // ========================================================================
    // Frame Rendering
    // ========================================================================

    /// Begin a new frame. Must call endFrame() after drawing.
    /// Returns false if frame should be skipped (e.g., window minimized).
    pub fn beginFrame(self: *Renderer, clear_color: [4]f32) bool {
        // Step 1: Acquire a command buffer
        const cmd = c.SDL_AcquireGPUCommandBuffer(self.device) orelse {
            std.debug.print("SDL_AcquireGPUCommandBuffer failed: {s}\n", .{c.SDL_GetError()});
            return false;
        };

        // Step 2: Acquire the swapchain texture (what we render to)
        var swapchain_texture: ?*c.SDL_GPUTexture = null;
        var swapchain_width: u32 = 0;
        var swapchain_height: u32 = 0;
        if (!c.SDL_AcquireGPUSwapchainTexture(cmd, self.window, &swapchain_texture, &swapchain_width, &swapchain_height)) {
            std.debug.print("SDL_AcquireGPUSwapchainTexture failed: {s}\n", .{c.SDL_GetError()});
            _ = c.SDL_SubmitGPUCommandBuffer(cmd);
            return false;
        }

        // If swapchain_texture is null, window might be minimized - skip frame
        if (swapchain_texture == null) {
            _ = c.SDL_SubmitGPUCommandBuffer(cmd);
            return false;
        }

        // Step 3: Recreate depth buffer if window was resized
        if (swapchain_width != self.depth_width or swapchain_height != self.depth_height) {
            c.SDL_ReleaseGPUTexture(self.device, self.depth_texture);
            self.depth_texture = createDepthTexture(self.device, swapchain_width, swapchain_height) orelse {
                std.debug.print("Failed to recreate depth texture: {s}\n", .{c.SDL_GetError()});
                _ = c.SDL_SubmitGPUCommandBuffer(cmd);
                return false;
            };
            self.depth_width = swapchain_width;
            self.depth_height = swapchain_height;
        }

        // Step 4: Set up color target (what we see on screen)
        const color_target = c.SDL_GPUColorTargetInfo{
            .texture = swapchain_texture,
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
            .texture = self.depth_texture,
            .clear_depth = 1.0, // Clear to far plane (max depth)
            .load_op = c.SDL_GPU_LOADOP_CLEAR,
            .store_op = c.SDL_GPU_STOREOP_DONT_CARE, // Don't need to preserve after frame
            .stencil_load_op = c.SDL_GPU_LOADOP_DONT_CARE,
            .stencil_store_op = c.SDL_GPU_STOREOP_DONT_CARE,
            .cycle = false,
            .clear_stencil = 0,
            .padding1 = 0,
            .padding2 = 0,
        };

        // Step 6: Begin render pass with both color and depth targets
        const render_pass = c.SDL_BeginGPURenderPass(
            cmd,
            &color_target,
            1,
            &depth_target, // Now passing depth target!
        ) orelse {
            std.debug.print("SDL_BeginGPURenderPass failed: {s}\n", .{c.SDL_GetError()});
            _ = c.SDL_SubmitGPUCommandBuffer(cmd);
            return false;
        };

        // Note: Pipeline is bound per-draw in drawMesh() based on mesh vertex format

        // Store frame state
        self.current_cmd = cmd;
        self.current_render_pass = render_pass;
        self.current_swapchain = swapchain_texture; // Store for editor overlay

        return true;
    }

    /// Draw a mesh with the given MVP matrix.
    /// Must be called between beginFrame() and endFrame().
    ///
    /// Automatically selects the correct pipeline based on mesh vertex format
    /// and handles both indexed and non-indexed rendering.
    ///
    /// The MVP (Model-View-Projection) matrix transforms vertices from
    /// local object space to clip space for rendering.
    pub fn drawMesh(self: *Renderer, m: *const Mesh, mvp: zm.Mat) void {
        const render_pass = self.current_render_pass orelse {
            std.debug.print("drawMesh called outside of beginFrame/endFrame\n", .{});
            return;
        };

        const cmd = self.current_cmd orelse return;

        // =====================================================================
        // Step 1: Bind the correct pipeline based on vertex format
        // =====================================================================
        // Each pipeline has a different vertex layout configured, so we must
        // bind the one that matches the mesh's vertex data.
        const pipeline = switch (m.vertex_format) {
            .pos_color => self.pipeline_pos_color,
            .pos_normal_uv => self.pipeline_pos_normal_uv,
        };
        c.SDL_BindGPUGraphicsPipeline(render_pass, pipeline);

        // =====================================================================
        // Step 2: Push MVP matrix to vertex shader uniform buffer
        // =====================================================================
        const uniforms = Uniforms{ .mvp = zm.matToArr(mvp) };
        c.SDL_PushGPUVertexUniformData(cmd, 0, &uniforms, @sizeOf(Uniforms));

        // =====================================================================
        // Step 3: Bind texture and sampler for textured meshes
        // =====================================================================
        if (m.vertex_format == .pos_normal_uv) {
            // Use mesh's texture if available, otherwise use placeholder (white)
            const texture_handle = if (m.diffuse_texture) |*tex|
                tex.getHandle()
            else
                self.placeholder_texture.getHandle();

            const sampler_binding = c.SDL_GPUTextureSamplerBinding{
                .texture = texture_handle,
                .sampler = self.default_sampler,
            };
            c.SDL_BindGPUFragmentSamplers(render_pass, 0, &sampler_binding, 1);
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
    pub fn submitFrame(self: *Renderer) void {
        if (self.current_cmd) |cmd| {
            if (!c.SDL_SubmitGPUCommandBuffer(cmd)) {
                std.debug.print("SDL_SubmitGPUCommandBuffer failed: {s}\n", .{c.SDL_GetError()});
            }
        }

        // Clear frame state
        self.current_cmd = null;
        self.current_swapchain = null;
    }

    /// End the current frame and present to screen.
    /// Convenience method that calls endRenderPass() and submitFrame().
    pub fn endFrame(self: *Renderer) void {
        self.endRenderPass();
        self.submitFrame();
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

/// Depth texture format used throughout the renderer
const DEPTH_FORMAT = c.SDL_GPU_TEXTUREFORMAT_D32_FLOAT;

/// Create pipeline for pos_color vertex format (primitives like cube, triangle)
fn createPipelinePosColor(device: *c.SDL_GPUDevice) !*c.SDL_GPUGraphicsPipeline {
    const shaders = getTriangleShaderCode();

    // Create vertex shader
    // NOTE: num_uniform_buffers = 1 tells SDL_GPU we have a uniform buffer at binding 0
    const vertex_shader = c.SDL_CreateGPUShader(device, &c.SDL_GPUShaderCreateInfo{
        .code = shaders.vertex.ptr,
        .code_size = shaders.vertex.len,
        .entrypoint = "main0", // spirv-cross generates "main0" for MSL
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
        .entrypoint = "main0",
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

    // Color target description (using BGRA8 which is common swapchain format)
    const color_target_desc = c.SDL_GPUColorTargetDescription{
        .format = c.SDL_GPU_TEXTUREFORMAT_B8G8R8A8_UNORM,
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
            .padding1 = 0,
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
            .depth_stencil_format = DEPTH_FORMAT, // Must match depth texture
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
fn createPipelinePosNormalUv(device: *c.SDL_GPUDevice) !*c.SDL_GPUGraphicsPipeline {
    const shaders = getModelShaderCode();

    // Create vertex shader
    const vertex_shader = c.SDL_CreateGPUShader(device, &c.SDL_GPUShaderCreateInfo{
        .code = shaders.vertex.ptr,
        .code_size = shaders.vertex.len,
        .entrypoint = "main0",
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

    // Create fragment shader (with 1 texture sampler for diffuse texture)
    const fragment_shader = c.SDL_CreateGPUShader(device, &c.SDL_GPUShaderCreateInfo{
        .code = shaders.fragment.ptr,
        .code_size = shaders.fragment.len,
        .entrypoint = "main0",
        .format = shaders.format,
        .stage = c.SDL_GPU_SHADERSTAGE_FRAGMENT,
        .num_samplers = 1, // Diffuse texture sampler
        .num_storage_textures = 0,
        .num_storage_buffers = 0,
        .num_uniform_buffers = 0,
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
        .format = c.SDL_GPU_TEXTUREFORMAT_B8G8R8A8_UNORM,
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
            .fill_mode = c.SDL_GPU_FILLMODE_FILL,
            .cull_mode = c.SDL_GPU_CULLMODE_BACK,
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
            .padding1 = 0,
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
            .depth_stencil_format = DEPTH_FORMAT,
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

/// Create a depth texture for the given dimensions
fn createDepthTexture(device: *c.SDL_GPUDevice, width: u32, height: u32) ?*c.SDL_GPUTexture {
    return c.SDL_CreateGPUTexture(device, &c.SDL_GPUTextureCreateInfo{
        .type = c.SDL_GPU_TEXTURETYPE_2D,
        .format = DEPTH_FORMAT,
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
    pub const BLACK = [4]f32{ 0.0, 0.0, 0.0, 1.0 };
    pub const DARK_GRAY = [4]f32{ 0.1, 0.1, 0.1, 1.0 };
    pub const FOREST_GREEN = [4]f32{ 0.133, 0.545, 0.133, 1.0 };
};

// ============================================================================
// Tests
// ============================================================================

test "Colors are valid" {
    for (Colors.CORNFLOWER_BLUE) |component| {
        try std.testing.expect(component >= 0.0 and component <= 1.0);
    }
}
