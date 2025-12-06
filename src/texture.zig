//! texture.zig - GPU Texture Utilities
//!
//! DOMAIN: Asset/Resource Layer
//!
//! This module provides utilities for creating and uploading textures to the GPU.
//! It handles the transfer buffer pattern used by SDL_GPU for texture uploads.
//!
//! Responsibilities:
//! - Create GPU textures from pixel data
//! - Handle texture upload via transfer buffers
//! - Provide placeholder texture for untextured meshes
//!
//! This module does NOT:
//! - Decode image formats (that's zstbi's job)
//! - Know about materials or shaders
//! - Handle texture caching or asset management

const std = @import("std");
const sdl = @import("sdl.zig");
const c = sdl.c;

// ============================================================================
// Public Types
// ============================================================================

/// A GPU texture ready for sampling in shaders.
/// Call deinit() when done to release GPU resources.
pub const Texture = struct {
    gpu_texture: *c.SDL_GPUTexture,
    device: *c.SDL_GPUDevice,
    width: u32,
    height: u32,

    /// Release GPU resources.
    pub fn deinit(self: *Texture) void {
        c.SDL_ReleaseGPUTexture(self.device, self.gpu_texture);
    }

    /// Get the underlying SDL_GPUTexture pointer for binding.
    pub fn getHandle(self: *const Texture) *c.SDL_GPUTexture {
        return self.gpu_texture;
    }
};

// ============================================================================
// Public API
// ============================================================================

/// Create a GPU texture from RGBA pixel data.
///
/// Parameters:
/// - device: GPU device for texture creation
/// - width: Texture width in pixels
/// - height: Texture height in pixels
/// - pixels: RGBA8 pixel data (4 bytes per pixel, row-major)
///
/// Returns a Texture ready for shader sampling.
/// The caller owns the texture and must call deinit() to release resources.
pub fn createTexture(
    device: *c.SDL_GPUDevice,
    width: u32,
    height: u32,
    pixels: []const u8,
) !Texture {
    const expected_size = width * height * 4;
    if (pixels.len != expected_size) {
        std.debug.print("Texture pixel data size mismatch: expected {d}, got {d}\n", .{ expected_size, pixels.len });
        return error.InvalidPixelData;
    }

    // =========================================================================
    // Step 1: Create the GPU texture
    // =========================================================================
    const gpu_texture = c.SDL_CreateGPUTexture(device, &c.SDL_GPUTextureCreateInfo{
        .type = c.SDL_GPU_TEXTURETYPE_2D,
        .format = c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM,
        .usage = c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
        .width = width,
        .height = height,
        .layer_count_or_depth = 1,
        .num_levels = 1,
        .sample_count = c.SDL_GPU_SAMPLECOUNT_1,
        .props = 0,
    }) orelse {
        std.debug.print("Failed to create GPU texture: {s}\n", .{c.SDL_GetError()});
        return error.TextureCreationFailed;
    };
    errdefer c.SDL_ReleaseGPUTexture(device, gpu_texture);

    // =========================================================================
    // Step 2: Create transfer buffer for upload
    // =========================================================================
    const buffer_size: u32 = @intCast(pixels.len);

    const transfer_buffer = c.SDL_CreateGPUTransferBuffer(device, &c.SDL_GPUTransferBufferCreateInfo{
        .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
        .size = buffer_size,
        .props = 0,
    }) orelse {
        std.debug.print("Failed to create transfer buffer: {s}\n", .{c.SDL_GetError()});
        return error.TransferBufferCreationFailed;
    };
    defer c.SDL_ReleaseGPUTransferBuffer(device, transfer_buffer);

    // =========================================================================
    // Step 3: Map and copy pixel data
    // =========================================================================
    const mapped_ptr = c.SDL_MapGPUTransferBuffer(device, transfer_buffer, false) orelse {
        std.debug.print("Failed to map transfer buffer: {s}\n", .{c.SDL_GetError()});
        return error.TransferBufferMapFailed;
    };
    const mapped: [*]u8 = @ptrCast(mapped_ptr);
    @memcpy(mapped[0..pixels.len], pixels);
    c.SDL_UnmapGPUTransferBuffer(device, transfer_buffer);

    // =========================================================================
    // Step 4: Upload to GPU
    // =========================================================================
    const copy_cmd = c.SDL_AcquireGPUCommandBuffer(device) orelse {
        return error.CommandBufferFailed;
    };

    const copy_pass = c.SDL_BeginGPUCopyPass(copy_cmd) orelse {
        _ = c.SDL_SubmitGPUCommandBuffer(copy_cmd);
        return error.CopyPassFailed;
    };

    c.SDL_UploadToGPUTexture(
        copy_pass,
        &c.SDL_GPUTextureTransferInfo{
            .transfer_buffer = transfer_buffer,
            .offset = 0,
            .pixels_per_row = width,
            .rows_per_layer = height,
        },
        &c.SDL_GPUTextureRegion{
            .texture = gpu_texture,
            .mip_level = 0,
            .layer = 0,
            .x = 0,
            .y = 0,
            .z = 0,
            .w = width,
            .h = height,
            .d = 1,
        },
        false,
    );

    c.SDL_EndGPUCopyPass(copy_pass);

    // Submit and wait for upload to complete
    const fence = c.SDL_SubmitGPUCommandBufferAndAcquireFence(copy_cmd);
    _ = c.SDL_WaitForGPUFences(device, true, &fence, 1);
    c.SDL_ReleaseGPUFence(device, fence);

    return Texture{
        .gpu_texture = gpu_texture,
        .device = device,
        .width = width,
        .height = height,
    };
}

/// Create a 1x1 white placeholder texture.
/// Used for meshes that don't have textures (renders as white).
pub fn createPlaceholderTexture(device: *c.SDL_GPUDevice) !Texture {
    const white_pixel = [_]u8{ 255, 255, 255, 255 };
    return createTexture(device, 1, 1, &white_pixel);
}

// ============================================================================
// Tests
// ============================================================================

test "Texture struct size" {
    // Compile-time check that struct is valid
    _ = Texture;
}
