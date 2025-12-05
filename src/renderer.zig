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
//! - Know what entities exist (that's world.zig)
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

const c = sdl.c;
const Mesh = mesh_module.Mesh;
const Vertex = mesh_module.Vertex;

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

fn getShaderCode() ShaderCode {
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

// ============================================================================
// Renderer
// ============================================================================

/// Renderer manages the SDL_GPU device and handles frame rendering.
pub const Renderer = struct {
    device: *c.SDL_GPUDevice,
    window: *c.SDL_Window,
    pipeline: *c.SDL_GPUGraphicsPipeline,

    // Frame state (valid between beginFrame and endFrame)
    current_cmd: ?*c.SDL_GPUCommandBuffer = null,
    current_render_pass: ?*c.SDL_GPURenderPass = null,

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

        // Create the graphics pipeline (shaders + vertex layout + render state)
        const pipeline = try createPipeline(device, window);
        errdefer c.SDL_ReleaseGPUGraphicsPipeline(device, pipeline);

        std.debug.print("Renderer initialized successfully\n", .{});

        return Renderer{
            .device = device,
            .window = window,
            .pipeline = pipeline,
        };
    }

    /// Clean up GPU resources
    pub fn deinit(self: *Renderer) void {
        c.SDL_ReleaseGPUGraphicsPipeline(self.device, self.pipeline);
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
        if (!c.SDL_AcquireGPUSwapchainTexture(cmd, self.window, &swapchain_texture, null, null)) {
            std.debug.print("SDL_AcquireGPUSwapchainTexture failed: {s}\n", .{c.SDL_GetError()});
            _ = c.SDL_SubmitGPUCommandBuffer(cmd);
            return false;
        }

        // If swapchain_texture is null, window might be minimized - skip frame
        if (swapchain_texture == null) {
            _ = c.SDL_SubmitGPUCommandBuffer(cmd);
            return false;
        }

        // Step 3: Begin render pass with clear color
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

        const render_pass = c.SDL_BeginGPURenderPass(
            cmd,
            &color_target,
            1,
            null,
        ) orelse {
            std.debug.print("SDL_BeginGPURenderPass failed: {s}\n", .{c.SDL_GetError()});
            _ = c.SDL_SubmitGPUCommandBuffer(cmd);
            return false;
        };

        // Bind the pipeline once at the start of the frame
        c.SDL_BindGPUGraphicsPipeline(render_pass, self.pipeline);

        // Store frame state
        self.current_cmd = cmd;
        self.current_render_pass = render_pass;

        return true;
    }

    /// Draw a mesh with the given MVP matrix.
    /// Must be called between beginFrame() and endFrame().
    ///
    /// The MVP (Model-View-Projection) matrix transforms vertices from
    /// local object space to clip space for rendering.
    pub fn drawMesh(self: *Renderer, m: *const Mesh, mvp: zm.Mat) void {
        const render_pass = self.current_render_pass orelse {
            std.debug.print("drawMesh called outside of beginFrame/endFrame\n", .{});
            return;
        };

        const cmd = self.current_cmd orelse return;

        // Push MVP matrix to vertex shader uniform buffer (slot 0)
        // zmath stores matrices in row-major order, which matches our shader
        const uniforms = Uniforms{ .mvp = zm.matToArr(mvp) };
        c.SDL_PushGPUVertexUniformData(cmd, 0, &uniforms, @sizeOf(Uniforms));

        // Bind vertex buffer
        const buffer_binding = c.SDL_GPUBufferBinding{
            .buffer = m.vertex_buffer,
            .offset = 0,
        };
        c.SDL_BindGPUVertexBuffers(render_pass, 0, &buffer_binding, 1);

        // Draw vertices
        c.SDL_DrawGPUPrimitives(render_pass, m.vertex_count, 1, 0, 0);
    }

    /// End the current frame and present to screen.
    pub fn endFrame(self: *Renderer) void {
        if (self.current_render_pass) |render_pass| {
            c.SDL_EndGPURenderPass(render_pass);
        }

        if (self.current_cmd) |cmd| {
            if (!c.SDL_SubmitGPUCommandBuffer(cmd)) {
                std.debug.print("SDL_SubmitGPUCommandBuffer failed: {s}\n", .{c.SDL_GetError()});
            }
        }

        // Clear frame state
        self.current_cmd = null;
        self.current_render_pass = null;
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

fn createPipeline(device: *c.SDL_GPUDevice, window: *c.SDL_Window) !*c.SDL_GPUGraphicsPipeline {
    const shaders = getShaderCode();

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

    // Get swapchain texture format
    const swapchain_format = c.SDL_GetGPUSwapchainTextureFormat(device, window);

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

    // Color target description
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
            .cull_mode = c.SDL_GPU_CULLMODE_NONE,
            .front_face = c.SDL_GPU_FRONTFACE_COUNTER_CLOCKWISE,
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
            .enable_depth_test = false,
            .enable_depth_write = false,
            .enable_stencil_test = false,
            .padding1 = 0,
            .padding2 = 0,
            .padding3 = 0,
        },
        .target_info = .{
            .color_target_descriptions = &color_target_desc,
            .num_color_targets = 1,
            .depth_stencil_format = c.SDL_GPU_TEXTUREFORMAT_INVALID,
            .has_depth_stencil_target = false,
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
