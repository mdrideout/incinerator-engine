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

/// A copy-safe, non-owning GPU texture view.
///
/// Copying this value never transfers or duplicates ownership. The
/// corresponding `OwnedTexture` must outlive every copy of this view.
pub const Texture = struct {
    gpu_texture: *c.SDL_GPUTexture,
    width: u32,
    height: u32,

    /// Get the underlying SDL_GPUTexture pointer for binding.
    pub fn getHandle(self: Texture) *c.SDL_GPUTexture {
        return self.gpu_texture;
    }
};

/// The unique owner of an SDL GPU texture.
///
/// Use `borrow()` to obtain copy-safe `Texture` views. `deinit()` is
/// idempotent so cleanup paths can converge without releasing the SDL handle
/// twice. Copying an `OwnedTexture` is still a logical ownership error; owners
/// belong in resource-owning aggregates, while consumers store `Texture`.
pub const OwnedTexture = struct {
    device: *c.SDL_GPUDevice,
    texture: ?Texture,

    /// Borrow a copy-safe view. Borrowing after deinitialization is a bug.
    pub fn borrow(self: *const OwnedTexture) Texture {
        return self.texture orelse @panic("attempted to borrow a released texture");
    }

    /// Release the owned SDL resource at most once.
    pub fn deinit(self: *OwnedTexture) void {
        self.deinitWith({}, releaseSdlTexture);
    }

    fn releaseSdlTexture(_: void, device: *c.SDL_GPUDevice, texture: *c.SDL_GPUTexture) void {
        c.SDL_ReleaseGPUTexture(device, texture);
    }

    /// Private release seam keeps the public type bound to SDL while allowing
    /// its exactly-once ownership transition to be tested without a GPU.
    fn deinitWith(self: *OwnedTexture, context: anytype, comptime release_fn: anytype) void {
        const owned = self.take() orelse return;
        release_fn(context, self.device, owned.gpu_texture);
    }

    /// Remove ownership from this value. Kept private so only this module can
    /// turn an owner into a raw resource scheduled for release.
    fn take(self: *OwnedTexture) ?Texture {
        const owned = self.texture orelse return null;
        self.texture = null;
        return owned;
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
/// Returns an OwnedTexture ready for shader sampling.
/// The caller owns the texture and must call deinit() to release resources.
pub fn createTexture(
    device: *c.SDL_GPUDevice,
    width: u32,
    height: u32,
    pixels: []const u8,
) !OwnedTexture {
    if (width == 0 or height == 0) return error.InvalidTextureDimensions;

    const pixel_count = std.math.mul(usize, width, height) catch return error.TextureTooLarge;
    const expected_size = std.math.mul(usize, pixel_count, 4) catch return error.TextureTooLarge;
    if (pixels.len != expected_size) {
        std.debug.print("Texture pixel data size mismatch: expected {d}, got {d}\n", .{ expected_size, pixels.len });
        return error.InvalidPixelData;
    }
    if (expected_size > std.math.maxInt(u32)) return error.TextureTooLarge;

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
    const buffer_size: u32 = @intCast(expected_size);

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
        std.debug.print("Failed to acquire texture upload command buffer: {s}\n", .{c.SDL_GetError()});
        return error.CommandBufferFailed;
    };

    const copy_pass = c.SDL_BeginGPUCopyPass(copy_cmd) orelse {
        std.debug.print("Failed to begin texture upload copy pass: {s}\n", .{c.SDL_GetError()});
        if (!c.SDL_CancelGPUCommandBuffer(copy_cmd)) {
            std.debug.print("Failed to cancel texture upload command buffer: {s}\n", .{c.SDL_GetError()});
        }
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
    const fence = c.SDL_SubmitGPUCommandBufferAndAcquireFence(copy_cmd) orelse {
        std.debug.print("Failed to submit texture upload command buffer: {s}\n", .{c.SDL_GetError()});
        return error.CommandBufferSubmitFailed;
    };
    defer c.SDL_ReleaseGPUFence(device, fence);

    if (!c.SDL_WaitForGPUFences(device, true, &fence, 1)) {
        std.debug.print("Failed to wait for texture upload fence: {s}\n", .{c.SDL_GetError()});
        return error.FenceWaitFailed;
    }

    return OwnedTexture{
        .device = device,
        .texture = .{
            .gpu_texture = gpu_texture,
            .width = width,
            .height = height,
        },
    };
}

/// Create a 1x1 white placeholder texture.
/// Used for meshes that don't have textures (renders as white).
pub fn createPlaceholderTexture(device: *c.SDL_GPUDevice) !OwnedTexture {
    const white_pixel = [_]u8{ 255, 255, 255, 255 };
    return createTexture(device, 1, 1, &white_pixel);
}

/// Create a checkerboard debug texture.
/// Classic pattern for physics/debug visualization - shows scale, rotation, UV mapping.
/// comptime tile_size: pixels per tile (e.g., 64 for 64x64 pixel tiles)
/// comptime tiles: number of tiles per side (e.g., 2 for 2x2 = 4 tiles)
pub fn createCheckerboardTexture(
    device: *c.SDL_GPUDevice,
    comptime tile_size: u32,
    comptime tiles: u32,
    color_a: [3]u8,
    color_b: [3]u8,
) !OwnedTexture {
    const size = tile_size * tiles;
    var pixels: [size * size * 4]u8 = undefined;

    for (0..size) |y| {
        for (0..size) |x| {
            const tile_x = x / tile_size;
            const tile_y = y / tile_size;
            const is_light = (tile_x + tile_y) % 2 == 0;
            const color = if (is_light) color_a else color_b;

            const idx = (y * size + x) * 4;
            pixels[idx + 0] = color[0]; // R
            pixels[idx + 1] = color[1]; // G
            pixels[idx + 2] = color[2]; // B
            pixels[idx + 3] = 255; // A
        }
    }

    return createTexture(device, size, size, &pixels);
}

/// Create a standard debug checkerboard (gray/white, 128x128, 2x2 tiles).
/// Good default for physics debug visualization.
pub fn createDebugCheckerboard(device: *c.SDL_GPUDevice) !OwnedTexture {
    return createCheckerboardTexture(
        device,
        64, // 64 pixels per tile
        2, // 2x2 tiles = 128x128 texture
        .{ 220, 220, 220 }, // Light gray
        .{ 140, 140, 140 }, // Dark gray
    );
}

// ============================================================================
// Tests
// ============================================================================

test "Texture is a copy-safe non-owning view" {
    try std.testing.expect(!@hasDecl(Texture, "deinit"));

    const handle: *c.SDL_GPUTexture = @ptrFromInt(0x1000);
    const original = Texture{
        .gpu_texture = handle,
        .width = 16,
        .height = 8,
    };
    const copied = original;

    try std.testing.expectEqual(original.getHandle(), copied.getHandle());
    try std.testing.expectEqual(original.width, copied.width);
    try std.testing.expectEqual(original.height, copied.height);
}

test "OwnedTexture relinquishes ownership at most once" {
    const device: *c.SDL_GPUDevice = @ptrFromInt(0x1000);
    const handle: *c.SDL_GPUTexture = @ptrFromInt(0x2000);
    var owned = OwnedTexture{
        .device = device,
        .texture = .{
            .gpu_texture = handle,
            .width = 4,
            .height = 2,
        },
    };

    const ReleaseCounter = struct {
        fn release(count: *usize, _: *c.SDL_GPUDevice, _: *c.SDL_GPUTexture) void {
            count.* += 1;
        }
    };

    const view = owned.borrow();
    try std.testing.expectEqual(handle, view.getHandle());

    var release_count: usize = 0;
    owned.deinitWith(&release_count, ReleaseCounter.release);
    owned.deinitWith(&release_count, ReleaseCounter.release);

    try std.testing.expectEqual(@as(usize, 1), release_count);
    try std.testing.expect(owned.texture == null);
}
