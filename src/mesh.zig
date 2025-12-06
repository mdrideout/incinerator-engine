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
//! - Know where meshes are used in the scene (that's ecs.zig)
//! - Handle rendering/draw calls (that's renderer.zig)
//!
//! Vertex Formats:
//! - Vertex (VertexPosColor): Simple colored vertices for debug/primitives
//! - VertexPNU: Position + Normal + UV for loaded 3D models

const std = @import("std");
const sdl = @import("sdl.zig");
const texture_module = @import("texture.zig");
const c = sdl.c;
const Texture = texture_module.Texture;

// ============================================================================
// Vertex Definition
// ============================================================================

/// Vertex structure for colored primitives (debug shapes, cubes, etc.)
/// Matches shader inputs:
///   layout(location = 0) in vec3 in_position;
///   layout(location = 1) in vec3 in_color;
pub const Vertex = extern struct {
    position: [3]f32, // x, y, z
    color: [3]f32, // r, g, b
};

/// Vertex structure for loaded 3D models (glTF, OBJ, etc.)
/// Contains position, normal (for lighting), and UV (for textures).
/// Matches shader inputs:
///   layout(location = 0) in vec3 in_position;
///   layout(location = 1) in vec3 in_normal;
///   layout(location = 2) in vec2 in_texcoord;
pub const VertexPNU = extern struct {
    position: [3]f32, // x, y, z
    normal: [3]f32, // nx, ny, nz (unit vector for lighting)
    texcoord: [2]f32, // u, v (texture coordinates, 0-1 range)
};

/// Identifies which vertex format a mesh uses.
/// The renderer needs this to bind the correct pipeline.
pub const VertexFormat = enum {
    /// Position + Color (24 bytes) - for debug/primitive shapes
    pos_color,
    /// Position + Normal + UV (32 bytes) - for loaded models
    pos_normal_uv,

    /// Returns the size in bytes of a single vertex for this format
    pub fn stride(self: VertexFormat) u32 {
        return switch (self) {
            .pos_color => @sizeOf(Vertex),
            .pos_normal_uv => @sizeOf(VertexPNU),
        };
    }
};

// ============================================================================
// Mesh
// ============================================================================

/// A mesh is geometry data living on the GPU, ready to be drawn.
/// Supports both indexed and non-indexed rendering:
/// - Non-indexed: Every 3 vertices form a triangle (simple but duplicates vertices)
/// - Indexed: Vertices are shared, index buffer says which vertices form triangles
pub const Mesh = struct {
    vertex_buffer: *c.SDL_GPUBuffer,
    vertex_count: u32,
    vertex_format: VertexFormat, // Which vertex layout this mesh uses
    device: *c.SDL_GPUDevice, // Needed for cleanup

    // Index buffer (optional - null for non-indexed meshes like primitives)
    index_buffer: ?*c.SDL_GPUBuffer = null,
    index_count: u32 = 0,

    // Diffuse texture (optional - null for untextured meshes)
    // When null, renderer uses placeholder white texture
    diffuse_texture: ?Texture = null,

    /// Returns true if this mesh uses indexed rendering.
    /// When true, renderer should use SDL_DrawGPUIndexedPrimitives.
    pub fn isIndexed(self: *const Mesh) bool {
        return self.index_buffer != null;
    }

    /// Upload vertex data to the GPU and create a Mesh (non-indexed).
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
            .vertex_format = .pos_color, // Vertex = position + color
            .device = device,
        };
    }

    /// Create an indexed mesh from VertexPNU data (used for loaded models).
    /// Index buffer allows vertices to be shared between triangles, saving memory.
    ///
    /// Parameters:
    /// - device: GPU device for buffer creation
    /// - vertices: Array of VertexPNU (position + normal + UV)
    /// - indices: Array of u32 indices (every 3 indices = one triangle)
    pub fn initIndexed(
        device: *c.SDL_GPUDevice,
        vertices: []const VertexPNU,
        indices: []const u32,
    ) !Mesh {
        // =====================================================================
        // Create Vertex Buffer
        // =====================================================================
        const vertex_size: u32 = @intCast(@sizeOf(VertexPNU) * vertices.len);

        const vertex_buffer = c.SDL_CreateGPUBuffer(device, &c.SDL_GPUBufferCreateInfo{
            .usage = c.SDL_GPU_BUFFERUSAGE_VERTEX,
            .size = vertex_size,
            .props = 0,
        }) orelse {
            std.debug.print("Failed to create vertex buffer: {s}\n", .{c.SDL_GetError()});
            return error.BufferCreationFailed;
        };
        errdefer c.SDL_ReleaseGPUBuffer(device, vertex_buffer);

        // =====================================================================
        // Create Index Buffer
        // =====================================================================
        const index_size: u32 = @intCast(@sizeOf(u32) * indices.len);

        const index_buffer = c.SDL_CreateGPUBuffer(device, &c.SDL_GPUBufferCreateInfo{
            .usage = c.SDL_GPU_BUFFERUSAGE_INDEX,
            .size = index_size,
            .props = 0,
        }) orelse {
            std.debug.print("Failed to create index buffer: {s}\n", .{c.SDL_GetError()});
            return error.BufferCreationFailed;
        };
        errdefer c.SDL_ReleaseGPUBuffer(device, index_buffer);

        // =====================================================================
        // Create Transfer Buffer (big enough for both vertex + index data)
        // =====================================================================
        const total_size = vertex_size + index_size;

        const transfer_buffer = c.SDL_CreateGPUTransferBuffer(device, &c.SDL_GPUTransferBufferCreateInfo{
            .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
            .size = total_size,
            .props = 0,
        }) orelse {
            std.debug.print("Failed to create transfer buffer: {s}\n", .{c.SDL_GetError()});
            return error.TransferBufferCreationFailed;
        };
        defer c.SDL_ReleaseGPUTransferBuffer(device, transfer_buffer);

        // =====================================================================
        // Map and Copy Data
        // =====================================================================
        const mapped_ptr = c.SDL_MapGPUTransferBuffer(device, transfer_buffer, false) orelse {
            std.debug.print("Failed to map transfer buffer: {s}\n", .{c.SDL_GetError()});
            return error.TransferBufferMapFailed;
        };

        // Copy vertices to first part of transfer buffer
        const vertex_dest: [*]VertexPNU = @ptrCast(@alignCast(mapped_ptr));
        @memcpy(vertex_dest[0..vertices.len], vertices);

        // Copy indices to second part of transfer buffer (after vertices)
        // Need to convert to byte pointer for offset arithmetic
        const byte_ptr: [*]u8 = @ptrCast(mapped_ptr);
        const index_dest: [*]u32 = @ptrCast(@alignCast(byte_ptr + vertex_size));
        @memcpy(index_dest[0..indices.len], indices);

        c.SDL_UnmapGPUTransferBuffer(device, transfer_buffer);

        // =====================================================================
        // Upload to GPU
        // =====================================================================
        const copy_cmd = c.SDL_AcquireGPUCommandBuffer(device) orelse {
            return error.CommandBufferFailed;
        };

        const copy_pass = c.SDL_BeginGPUCopyPass(copy_cmd) orelse {
            _ = c.SDL_SubmitGPUCommandBuffer(copy_cmd);
            return error.CopyPassFailed;
        };

        // Upload vertex data
        c.SDL_UploadToGPUBuffer(
            copy_pass,
            &c.SDL_GPUTransferBufferLocation{
                .transfer_buffer = transfer_buffer,
                .offset = 0,
            },
            &c.SDL_GPUBufferRegion{
                .buffer = vertex_buffer,
                .offset = 0,
                .size = vertex_size,
            },
            false,
        );

        // Upload index data
        c.SDL_UploadToGPUBuffer(
            copy_pass,
            &c.SDL_GPUTransferBufferLocation{
                .transfer_buffer = transfer_buffer,
                .offset = vertex_size, // Indices start after vertices
            },
            &c.SDL_GPUBufferRegion{
                .buffer = index_buffer,
                .offset = 0,
                .size = index_size,
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
            .vertex_format = .pos_normal_uv, // VertexPNU format
            .device = device,
            .index_buffer = index_buffer,
            .index_count = @intCast(indices.len),
        };
    }

    /// Release GPU resources.
    pub fn deinit(self: *Mesh) void {
        // Release texture if this mesh owns one
        if (self.diffuse_texture) |*tex| {
            tex.deinit();
        }
        // Release index buffer if this is an indexed mesh
        if (self.index_buffer) |idx_buf| {
            c.SDL_ReleaseGPUBuffer(self.device, idx_buf);
        }
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

test "VertexPNU size is correct" {
    // 3 floats position + 3 floats normal + 2 floats UV = 8 floats = 32 bytes
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(VertexPNU));
}

test "VertexFormat stride returns correct sizes" {
    try std.testing.expectEqual(@as(u32, 24), VertexFormat.pos_color.stride());
    try std.testing.expectEqual(@as(u32, 32), VertexFormat.pos_normal_uv.stride());
}
