//! Synchronous readback at an explicit acceptance anchor, outside the live frame loop.
const std = @import("std");
const c = @import("sdl.zig").c;
const Renderer = @import("renderer.zig").Renderer;

pub fn write(gpu: *Renderer, path: []const u8) !void {
    const extent = gpu.getProductSceneExtent();
    const byte_count = extent.width * extent.height * 4;
    const device = gpu.getDevice();
    const transfer = c.SDL_CreateGPUTransferBuffer(device, &c.SDL_GPUTransferBufferCreateInfo{
        .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_DOWNLOAD,
        .size = byte_count,
    }) orelse return error.OffscreenTransferFailed;
    defer c.SDL_ReleaseGPUTransferBuffer(device, transfer);
    const cmd = c.SDL_AcquireGPUCommandBuffer(device) orelse return error.OffscreenCommandFailed;
    const copy = c.SDL_BeginGPUCopyPass(cmd) orelse {
        _ = c.SDL_CancelGPUCommandBuffer(cmd);
        return error.OffscreenCopyFailed;
    };
    c.SDL_DownloadFromGPUTexture(copy, &c.SDL_GPUTextureRegion{
        .texture = gpu.getProductSceneTexture(),
        .w = extent.width,
        .h = extent.height,
        .d = 1,
    }, &c.SDL_GPUTextureTransferInfo{
        .transfer_buffer = transfer,
        .pixels_per_row = extent.width,
        .rows_per_layer = extent.height,
    });
    c.SDL_EndGPUCopyPass(copy);
    const fence = c.SDL_SubmitGPUCommandBufferAndAcquireFence(cmd) orelse return error.OffscreenSubmitFailed;
    defer c.SDL_ReleaseGPUFence(device, fence);
    var fences = [_]?*c.SDL_GPUFence{fence};
    if (!c.SDL_WaitForGPUFences(device, true, &fences, 1)) return error.OffscreenFenceFailed;
    const mapped = c.SDL_MapGPUTransferBuffer(device, transfer, false) orelse return error.OffscreenMapFailed;
    defer c.SDL_UnmapGPUTransferBuffer(device, transfer);
    const pixels = @as([*]const u8, @ptrCast(mapped))[0..byte_count];
    var file = try std.Io.Dir.cwd().createFile(std.testing.io, path, .{});
    defer file.close(std.testing.io);
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(std.testing.io, &buffer);
    try writer.interface.print("P6\n{d} {d}\n255\n", .{ extent.width, extent.height });
    var nonuniform = false;
    var offset: usize = 0;
    while (offset < pixels.len) : (offset += 4) {
        // initOffscreen explicitly selects BGRA8; reject an empty clear-only image.
        const rgb = [3]u8{ pixels[offset + 2], pixels[offset + 1], pixels[offset] };
        nonuniform = nonuniform or !std.mem.eql(u8, pixels[0..3], pixels[offset..][0..3]);
        try writer.interface.writeAll(&rgb);
    }
    try writer.interface.flush();
    try std.testing.expect(nonuniform);
}
