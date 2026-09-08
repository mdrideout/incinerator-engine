//! Tool-owned offscreen material preview. It borrows the renderer's material
//! pipeline and never changes the gameplay camera, scene, or input ownership.
const std = @import("std");
const c = @import("sdl.zig").c;
const renderer = @import("renderer.zig");
const mesh = @import("mesh.zig");
const zm = @import("zmath");

pub const Preview = struct {
    device: *c.SDL_GPUDevice,
    color: *c.SDL_GPUTexture,
    depth: *c.SDL_GPUTexture,
    binding: c.SDL_GPUTextureSamplerBinding,
    extent: u32,

    pub fn init(gpu: *renderer.Renderer, extent: u32) !Preview {
        if (extent == 0) return error.InvalidPreviewExtent;
        const device = gpu.getDevice();
        const color = c.SDL_CreateGPUTexture(device, &std.mem.zeroInit(c.SDL_GPUTextureCreateInfo, .{
            .type = c.SDL_GPU_TEXTURETYPE_2D,
            .format = gpu.getSwapchainFormat(),
            .usage = c.SDL_GPU_TEXTUREUSAGE_COLOR_TARGET | c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
            .width = extent,
            .height = extent,
            .layer_count_or_depth = 1,
            .num_levels = 1,
        })) orelse return error.MaterialPreviewTextureFailed;
        errdefer c.SDL_ReleaseGPUTexture(device, color);
        const depth = c.SDL_CreateGPUTexture(device, &std.mem.zeroInit(c.SDL_GPUTextureCreateInfo, .{
            .type = c.SDL_GPU_TEXTURETYPE_2D,
            .format = gpu.getDepthFormat(),
            .usage = c.SDL_GPU_TEXTUREUSAGE_DEPTH_STENCIL_TARGET,
            .width = extent,
            .height = extent,
            .layer_count_or_depth = 1,
            .num_levels = 1,
        })) orelse return error.MaterialPreviewDepthFailed;
        return .{ .device = device, .color = color, .depth = depth, .extent = extent, .binding = .{ .texture = color, .sampler = gpu.getDefaultSampler() } };
    }

    pub fn deinit(self: *Preview) void {
        c.SDL_ReleaseGPUTexture(self.device, self.depth);
        c.SDL_ReleaseGPUTexture(self.device, self.color);
        self.* = undefined;
    }

    pub fn render(self: *Preview, gpu: *renderer.Renderer, shape: *const mesh.Mesh, textures: renderer.MaterialTextures, material: renderer.SurfaceMaterial) !void {
        if (gpu.current_render_pass != null) return error.MaterialPreviewInsideScenePass;
        const cmd = gpu.current_cmd orelse return error.MaterialPreviewWithoutFrame;
        const color = std.mem.zeroInit(c.SDL_GPUColorTargetInfo, .{
            .texture = self.color,
            .clear_color = .{ .r = 0.18, .g = 0.18, .b = 0.18, .a = 1 },
            .load_op = c.SDL_GPU_LOADOP_CLEAR,
            .store_op = c.SDL_GPU_STOREOP_STORE,
        });
        const depth = std.mem.zeroInit(c.SDL_GPUDepthStencilTargetInfo, .{
            .texture = self.depth,
            .clear_depth = 1,
            .load_op = c.SDL_GPU_LOADOP_CLEAR,
            .store_op = c.SDL_GPU_STOREOP_DONT_CARE,
            .stencil_load_op = c.SDL_GPU_LOADOP_DONT_CARE,
            .stencil_store_op = c.SDL_GPU_STOREOP_DONT_CARE,
        });
        const pass = c.SDL_BeginGPURenderPass(cmd, &color, 1, &depth) orelse return error.MaterialPreviewPassFailed;
        defer c.SDL_EndGPURenderPass(pass);
        // This borrowed draw context does not own or destroy renderer resources.
        // Its camera, light and statistics belong exclusively to the preview.
        var context = gpu.*;
        context.current_render_pass = pass;
        context.camera_position = .{ 2.4, 1.7, 3.4 };
        try context.setSceneLight(.{ .sun_direction = .{ 0.5773503, 0.5773503, 0.5773503 }, .sun_color = .{ 1, 1, 1 }, .sun_intensity = 2.2, .ambient_color = .{ 0.22, 0.22, 0.22 } });
        const view = zm.lookAtRh(zm.f32x4(2.4, 1.7, 3.4, 1), zm.f32x4(0, 0, 0, 1), zm.f32x4(0, 1, 0, 0));
        const projection = zm.perspectiveFovRh(std.math.pi / 4.0, 1, 0.1, 20);
        context.drawMeshWithTextures(shape, textures, material, zm.scaling(2, 2, 2), zm.mul(view, projection));
    }
};
