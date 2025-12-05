//! mesh.zig - Mesh and Vertex types
//!
//! DOMAIN: Asset/Resource Layer
//!
//! This module defines the core geometry types used throughout the engine.
//! A Mesh represents geometry uploaded to the GPU - it's the bridge between
//! CPU-side vertex data and GPU-side buffers that can be rendered.
//!
//! Responsibilities:
//! - Define vertex formats (what data each vertex contains)
//! - Manage GPU buffer lifecycle (create, upload, destroy)
//! - Provide a clean abstraction over SDL_GPU buffer operations
//!
//! This module does NOT:
//! - Know about specific shapes (that's primitives.zig)
//! - Know where meshes are used in the scene (that's world.zig)
//! - Handle rendering/draw calls (that's renderer.zig)
//!
//! Future additions:
//! - Index buffers for indexed rendering
//! - Multiple vertex streams (positions, normals, UVs in separate buffers)
//! - Mesh loading from files (OBJ, glTF)
//! - Bounding box calculation for culling

const std = @import("std");
const sdl = @import("sdl.zig");
const c = sdl.c;

// ============================================================================
// Vertex Definition
// ============================================================================

/// Vertex structure matching our shader inputs:
///   layout(location = 0) in vec3 in_position;
///   layout(location = 1) in vec3 in_color;
///
/// Future: This will likely become VertexPosColor, and we'll have other
/// vertex formats like VertexPosNormalUV for textured meshes.
pub const Vertex = extern struct {
    position: [3]f32, // x, y, z
    color: [3]f32, // r, g, b
};

// ============================================================================
// Mesh
// ============================================================================

/// A mesh is geometry data living on the GPU, ready to be drawn.
pub const Mesh = struct {
    vertex_buffer: *c.SDL_GPUBuffer,
    vertex_count: u32,
    device: *c.SDL_GPUDevice, // Needed for cleanup

    // Future fields:
    // index_buffer: ?*c.SDL_GPUBuffer = null,
    // index_count: u32 = 0,
    // bounds: BoundingBox,

    /// Upload vertex data to the GPU and create a Mesh.
    pub fn init(device: *c.SDL_GPUDevice, vertices: []const Vertex) !Mesh {
        const buffer_size: u32 = @intCast(@sizeOf(Vertex) * vertices.len);

        // Create GPU buffer
        const vertex_buffer = c.SDL_CreateGPUBuffer(device, &c.SDL_GPUBufferCreateInfo{
            .usage = c.SDL_GPU_BUFFERUSAGE_VERTEX,
            .size = buffer_size,
            .props = 0,
        }) orelse {
            std.debug.print("Failed to create vertex buffer: {s}\n", .{c.SDL_GetError()});
            return error.BufferCreationFailed;
        };
        errdefer c.SDL_ReleaseGPUBuffer(device, vertex_buffer);

        // Create transfer buffer to upload data
        const transfer_buffer = c.SDL_CreateGPUTransferBuffer(device, &c.SDL_GPUTransferBufferCreateInfo{
            .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
            .size = buffer_size,
            .props = 0,
        }) orelse {
            std.debug.print("Failed to create transfer buffer: {s}\n", .{c.SDL_GetError()});
            return error.TransferBufferCreationFailed;
        };
        defer c.SDL_ReleaseGPUTransferBuffer(device, transfer_buffer);

        // Map transfer buffer and copy vertex data
        const mapped_ptr = c.SDL_MapGPUTransferBuffer(device, transfer_buffer, false) orelse {
            std.debug.print("Failed to map transfer buffer: {s}\n", .{c.SDL_GetError()});
            return error.TransferBufferMapFailed;
        };
        const mapped: [*]Vertex = @ptrCast(@alignCast(mapped_ptr));
        @memcpy(mapped[0..vertices.len], vertices);
        c.SDL_UnmapGPUTransferBuffer(device, transfer_buffer);

        // Upload to GPU
        const copy_cmd = c.SDL_AcquireGPUCommandBuffer(device) orelse {
            return error.CommandBufferFailed;
        };

        const copy_pass = c.SDL_BeginGPUCopyPass(copy_cmd) orelse {
            _ = c.SDL_SubmitGPUCommandBuffer(copy_cmd);
            return error.CopyPassFailed;
        };

        c.SDL_UploadToGPUBuffer(
            copy_pass,
            &c.SDL_GPUTransferBufferLocation{
                .transfer_buffer = transfer_buffer,
                .offset = 0,
            },
            &c.SDL_GPUBufferRegion{
                .buffer = vertex_buffer,
                .offset = 0,
                .size = buffer_size,
            },
            false,
        );

        c.SDL_EndGPUCopyPass(copy_pass);

        // Submit and wait for upload to complete
        const fence = c.SDL_SubmitGPUCommandBufferAndAcquireFence(copy_cmd);
        _ = c.SDL_WaitForGPUFences(device, true, &fence, 1);
        c.SDL_ReleaseGPUFence(device, fence);

        return Mesh{
            .vertex_buffer = vertex_buffer,
            .vertex_count = @intCast(vertices.len),
            .device = device,
        };
    }

    /// Release GPU resources.
    pub fn deinit(self: *Mesh) void {
        c.SDL_ReleaseGPUBuffer(self.device, self.vertex_buffer);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Vertex size is correct" {
    // 3 floats for position + 3 floats for color = 6 floats = 24 bytes
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(Vertex));
}
