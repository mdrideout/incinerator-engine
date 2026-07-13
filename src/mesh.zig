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
//! - Know where meshes are used in presentation
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

/// SDL GPU buffer sizes are u32. Validate all CPU-side counts before any
/// allocation, mapping, or narrowing cast reaches the backend.
fn checkedGpuBufferSize(element_size: usize, element_count: usize) !u32 {
    if (element_size == 0 or element_count == 0) return error.EmptyBufferData;

    const byte_count = std.math.mul(usize, element_size, element_count) catch
        return error.GPUBufferTooLarge;
    if (byte_count > std.math.maxInt(u32)) return error.GPUBufferTooLarge;
    return @intCast(byte_count);
}

fn checkedGpuBufferTotal(first: u32, second: u32) !u32 {
    if (first == 0 or second == 0) return error.EmptyBufferData;
    return std.math.add(u32, first, second) catch error.GPUBufferTooLarge;
}

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

    // Non-owning diffuse texture view (optional - null for untextured meshes).
    // The texture owner must outlive this mesh. When null, the renderer uses
    // its placeholder white texture.
    diffuse_texture: ?Texture = null,

    /// Returns true if this mesh uses indexed rendering.
    /// When true, renderer should use SDL_DrawGPUIndexedPrimitives.
    pub fn isIndexed(self: *const Mesh) bool {
        return self.index_buffer != null;
    }

    /// Upload vertex data to the GPU and create a Mesh (non-indexed).
    pub fn init(device: *c.SDL_GPUDevice, vertices: []const Vertex) !Mesh {
        const buffer_size = try checkedGpuBufferSize(@sizeOf(Vertex), vertices.len);

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
            std.debug.print("Failed to acquire mesh upload command buffer: {s}\n", .{c.SDL_GetError()});
            return error.CommandBufferFailed;
        };

        const copy_pass = c.SDL_BeginGPUCopyPass(copy_cmd) orelse {
            std.debug.print("Failed to begin mesh upload copy pass: {s}\n", .{c.SDL_GetError()});
            if (!c.SDL_CancelGPUCommandBuffer(copy_cmd)) {
                std.debug.print("Failed to cancel mesh upload command buffer: {s}\n", .{c.SDL_GetError()});
            }
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

        // Submit and wait for upload to complete.
        try submitUploadAndWait(device, copy_cmd);

        return Mesh{
            .vertex_buffer = vertex_buffer,
            .vertex_count = @intCast(vertices.len),
            .vertex_format = .pos_color, // Vertex = position + color
            .device = device,
        };
    }

    /// Create a non-indexed textured mesh from VertexPNU data.
    /// Use for simple textured primitives (cubes, cylinders, etc.)
    pub fn initTextured(device: *c.SDL_GPUDevice, vertices: []const VertexPNU) !Mesh {
        const buffer_size = try checkedGpuBufferSize(@sizeOf(VertexPNU), vertices.len);

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
        const mapped: [*]VertexPNU = @ptrCast(@alignCast(mapped_ptr));
        @memcpy(mapped[0..vertices.len], vertices);
        c.SDL_UnmapGPUTransferBuffer(device, transfer_buffer);

        // Upload to GPU
        const copy_cmd = c.SDL_AcquireGPUCommandBuffer(device) orelse {
            std.debug.print("Failed to acquire mesh upload command buffer: {s}\n", .{c.SDL_GetError()});
            return error.CommandBufferFailed;
        };

        const copy_pass = c.SDL_BeginGPUCopyPass(copy_cmd) orelse {
            std.debug.print("Failed to begin mesh upload copy pass: {s}\n", .{c.SDL_GetError()});
            if (!c.SDL_CancelGPUCommandBuffer(copy_cmd)) {
                std.debug.print("Failed to cancel mesh upload command buffer: {s}\n", .{c.SDL_GetError()});
            }
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

        // Submit and wait for upload to complete.
        try submitUploadAndWait(device, copy_cmd);

        return Mesh{
            .vertex_buffer = vertex_buffer,
            .vertex_count = @intCast(vertices.len),
            .vertex_format = .pos_normal_uv,
            .device = device,
        };
    }

    /// Release GPU resources.
    pub fn deinit(self: *Mesh) void {
        // `diffuse_texture` is a borrowed view; its aggregate owner releases it.
        self.diffuse_texture = null;
        // Release index buffer if this is an indexed mesh
        if (self.index_buffer) |idx_buf| {
            c.SDL_ReleaseGPUBuffer(self.device, idx_buf);
        }
        c.SDL_ReleaseGPUBuffer(self.device, self.vertex_buffer);
    }
};

/// Finish a synchronous resource upload and surface submission/wait failures.
/// SDL consumes the command buffer even when fence acquisition fails.
fn submitUploadAndWait(device: *c.SDL_GPUDevice, copy_cmd: *c.SDL_GPUCommandBuffer) !void {
    const fence = c.SDL_SubmitGPUCommandBufferAndAcquireFence(copy_cmd) orelse {
        std.debug.print("Failed to submit mesh upload command buffer: {s}\n", .{c.SDL_GetError()});
        return error.CommandBufferSubmitFailed;
    };
    defer c.SDL_ReleaseGPUFence(device, fence);

    if (!c.SDL_WaitForGPUFences(device, true, &fence, 1)) {
        std.debug.print("Failed to wait for mesh upload fence: {s}\n", .{c.SDL_GetError()});
        return error.FenceWaitFailed;
    }
}

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

test "GPU buffer sizes reject empty and oversized inputs" {
    try std.testing.expectError(error.EmptyBufferData, checkedGpuBufferSize(@sizeOf(Vertex), 0));
    try std.testing.expectEqual(@as(u32, @sizeOf(Vertex)), try checkedGpuBufferSize(@sizeOf(Vertex), 1));

    const largest_vertex_count = std.math.maxInt(u32) / @sizeOf(Vertex);
    const largest_vertex_bytes: u32 = @intCast(largest_vertex_count * @sizeOf(Vertex));
    try std.testing.expectEqual(
        largest_vertex_bytes,
        try checkedGpuBufferSize(@sizeOf(Vertex), largest_vertex_count),
    );
    try std.testing.expectError(
        error.GPUBufferTooLarge,
        checkedGpuBufferSize(@sizeOf(Vertex), largest_vertex_count + 1),
    );
    try std.testing.expectError(
        error.GPUBufferTooLarge,
        checkedGpuBufferSize(std.math.maxInt(usize), 2),
    );
}

test "combined GPU upload size rejects overflow" {
    try std.testing.expectError(error.EmptyBufferData, checkedGpuBufferTotal(0, 1));
    try std.testing.expectEqual(@as(u32, 3), try checkedGpuBufferTotal(1, 2));
    try std.testing.expectError(
        error.GPUBufferTooLarge,
        checkedGpuBufferTotal(std.math.maxInt(u32), 1),
    );
}
