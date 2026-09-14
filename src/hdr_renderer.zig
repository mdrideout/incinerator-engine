//! Linear scene/display resources. The caller owns frame submission and fences.
const std = @import("std");
const c = @import("sdl.zig").c;
const shaders = @import("shader_assets");
pub const Display = @import("engine_contracts").lighting.Display;
pub const format = c.SDL_GPU_TEXTUREFORMAT_R16G16B16A16_FLOAT;
const allocator = std.heap.page_allocator;

pub const Image = struct {
    texture: *c.SDL_GPUTexture,
    width: u32,
    height: u32,

    pub fn init(device: *c.SDL_GPUDevice, image_format: c.SDL_GPUTextureFormat, width: u32, height: u32) !Image {
        const texture = c.SDL_CreateGPUTexture(device, &std.mem.zeroInit(c.SDL_GPUTextureCreateInfo, .{
            .type = c.SDL_GPU_TEXTURETYPE_2D,
            .format = image_format,
            .usage = c.SDL_GPU_TEXTUREUSAGE_COLOR_TARGET | c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
            .width = width,
            .height = height,
            .layer_count_or_depth = 1,
            .num_levels = 1,
        })) orelse return error.HdrTextureCreationFailed;
        return .{ .texture = texture, .width = width, .height = height };
    }

    pub fn deinit(self: Image, device: *c.SDL_GPUDevice) void {
        c.SDL_ReleaseGPUTexture(device, self.texture);
    }
};

pub const Targets = struct {
    scene: Image,
    bloom: std.ArrayList(Image) = .empty,

    pub fn init(device: *c.SDL_GPUDevice, width: u32, height: u32) !Targets {
        var self = Targets{ .scene = try Image.init(device, format, width, height) };
        errdefer self.deinit(device);
        var w = width;
        var h = height;
        while (w > 1 or h > 1) {
            w = @max(1, w / 2);
            h = @max(1, h / 2);
            const next = try Image.init(device, format, w, h);
            self.bloom.append(allocator, next) catch |err| {
                next.deinit(device);
                return err;
            };
        }
        return self;
    }

    pub fn deinit(self: *Targets, device: *c.SDL_GPUDevice) void {
        for (self.bloom.items) |item| item.deinit(device);
        self.bloom.deinit(allocator);
        self.scene.deinit(device);
    }
};

pub const Owner = struct {
    device: *c.SDL_GPUDevice,
    display_pipeline: *c.SDL_GPUGraphicsPipeline,
    bloom_down: *c.SDL_GPUGraphicsPipeline,
    bloom_up: *c.SDL_GPUGraphicsPipeline,
    sampler: *c.SDL_GPUSampler,
    targets: Targets,

    pub fn init(device: *c.SDL_GPUDevice, display_format: c.SDL_GPUTextureFormat, width: u32, height: u32) !Owner {
        if (!c.SDL_GPUTextureSupportsFormat(device, format, c.SDL_GPU_TEXTURETYPE_2D, c.SDL_GPU_TEXTUREUSAGE_COLOR_TARGET | c.SDL_GPU_TEXTUREUSAGE_SAMPLER)) return error.HdrFormatUnsupported;
        const display_pipeline = try pipeline(device, display_format, shaders.display_fragment, 2, false);
        errdefer c.SDL_ReleaseGPUGraphicsPipeline(device, display_pipeline);
        const bloom_down = try pipeline(device, format, shaders.bloom_fragment, 1, false);
        errdefer c.SDL_ReleaseGPUGraphicsPipeline(device, bloom_down);
        const bloom_up = try pipeline(device, format, shaders.bloom_fragment, 1, true);
        errdefer c.SDL_ReleaseGPUGraphicsPipeline(device, bloom_up);
        const sampler = c.SDL_CreateGPUSampler(device, &std.mem.zeroInit(c.SDL_GPUSamplerCreateInfo, .{
            .min_filter = c.SDL_GPU_FILTER_LINEAR,
            .mag_filter = c.SDL_GPU_FILTER_LINEAR,
            .mipmap_mode = c.SDL_GPU_SAMPLERMIPMAPMODE_NEAREST,
            .address_mode_u = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
            .address_mode_v = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
            .address_mode_w = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
        })) orelse return error.HdrSamplerCreationFailed;
        errdefer c.SDL_ReleaseGPUSampler(device, sampler);
        return .{ .device = device, .display_pipeline = display_pipeline, .bloom_down = bloom_down, .bloom_up = bloom_up, .sampler = sampler, .targets = try Targets.init(device, width, height) };
    }

    pub fn deinit(self: *Owner) void {
        self.targets.deinit(self.device);
        c.SDL_ReleaseGPUSampler(self.device, self.sampler);
        c.SDL_ReleaseGPUGraphicsPipeline(self.device, self.display_pipeline);
        c.SDL_ReleaseGPUGraphicsPipeline(self.device, self.bloom_down);
        c.SDL_ReleaseGPUGraphicsPipeline(self.device, self.bloom_up);
    }

    pub fn ensureExtent(self: *Owner, width: u32, height: u32) !void {
        if (self.targets.scene.width == width and self.targets.scene.height == height) return;
        const replacement = try Targets.init(self.device, width, height);
        self.targets.deinit(self.device);
        self.targets = replacement;
    }

    pub fn resolve(self: *Owner, cmd: *c.SDL_GPUCommandBuffer, targets: *const Targets, destination: *c.SDL_GPUTexture, settings: Display) !void {
        try settings.validate();
        var levels: usize = 0;
        var footprint: f32 = 1;
        if (settings.bloom_strength > 0) while (levels < targets.bloom.items.len and footprint < settings.bloom_radius) {
            levels += 1;
            footprint *= 2;
        };
        var source = targets.scene;
        for (targets.bloom.items[0..levels], 0..) |image, i| {
            try self.draw(cmd, image.texture, self.bloom_down, source.texture, source.texture, .{ 1 / @as(f32, @floatFromInt(source.width)), 1 / @as(f32, @floatFromInt(source.height)), settings.bloom_threshold, if (i == 0) 1 else 0 }, false, 1);
            source = image;
        }
        var i = levels;
        while (i > 1) {
            i -= 1;
            source = targets.bloom.items[i];
            try self.draw(cmd, targets.bloom.items[i - 1].texture, self.bloom_up, source.texture, source.texture, .{ 1 / @as(f32, @floatFromInt(source.width)), 1 / @as(f32, @floatFromInt(source.height)), 0, 0 }, true, 1);
        }
        const bloom = if (levels > 0) targets.bloom.items[0].texture else targets.scene.texture;
        try self.draw(cmd, destination, self.display_pipeline, targets.scene.texture, bloom, .{ if (levels > 0) settings.bloom_strength / @as(f32, @floatFromInt(levels)) else 0, 0, 0, 0 }, false, 2);
    }

    fn draw(self: *Owner, cmd: *c.SDL_GPUCommandBuffer, target: *c.SDL_GPUTexture, pipe: *c.SDL_GPUGraphicsPipeline, source: *c.SDL_GPUTexture, second: *c.SDL_GPUTexture, values: [4]f32, load: bool, sampler_count: u32) !void {
        const color = std.mem.zeroInit(c.SDL_GPUColorTargetInfo, .{ .texture = target, .load_op = @as(c.SDL_GPULoadOp, if (load) c.SDL_GPU_LOADOP_LOAD else c.SDL_GPU_LOADOP_DONT_CARE), .store_op = c.SDL_GPU_STOREOP_STORE });
        const pass = c.SDL_BeginGPURenderPass(cmd, &color, 1, null) orelse return error.HdrResolvePassFailed;
        defer c.SDL_EndGPURenderPass(pass);
        c.SDL_BindGPUGraphicsPipeline(pass, pipe);
        const textures = [_]c.SDL_GPUTextureSamplerBinding{ .{ .texture = source, .sampler = self.sampler }, .{ .texture = second, .sampler = self.sampler } };
        c.SDL_BindGPUFragmentSamplers(pass, 0, &textures, sampler_count);
        c.SDL_PushGPUFragmentUniformData(cmd, 0, &values, @sizeOf(@TypeOf(values)));
        c.SDL_DrawGPUPrimitives(pass, 3, 1, 0, 0);
    }
};

fn pipeline(device: *c.SDL_GPUDevice, target_format: c.SDL_GPUTextureFormat, fragment: []const u8, samplers: u32, additive: bool) !*c.SDL_GPUGraphicsPipeline {
    const vertex = c.SDL_CreateGPUShader(device, &std.mem.zeroInit(c.SDL_GPUShaderCreateInfo, .{
        .code = shaders.fullscreen_vertex.ptr,
        .code_size = shaders.fullscreen_vertex.len,
        .entrypoint = shaders.entrypoint,
        .format = c.SDL_GPU_SHADERFORMAT_MSL,
        .stage = c.SDL_GPU_SHADERSTAGE_VERTEX,
    })) orelse return error.HdrShaderCreationFailed;
    defer c.SDL_ReleaseGPUShader(device, vertex);
    const frag = c.SDL_CreateGPUShader(device, &std.mem.zeroInit(c.SDL_GPUShaderCreateInfo, .{
        .code = fragment.ptr,
        .code_size = fragment.len,
        .entrypoint = shaders.entrypoint,
        .format = c.SDL_GPU_SHADERFORMAT_MSL,
        .stage = c.SDL_GPU_SHADERSTAGE_FRAGMENT,
        .num_samplers = samplers,
        .num_uniform_buffers = 1,
    })) orelse return error.HdrShaderCreationFailed;
    defer c.SDL_ReleaseGPUShader(device, frag);
    const color = std.mem.zeroInit(c.SDL_GPUColorTargetDescription, .{ .format = target_format, .blend_state = std.mem.zeroInit(c.SDL_GPUColorTargetBlendState, .{
        .src_color_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE,
        .dst_color_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE,
        .color_blend_op = c.SDL_GPU_BLENDOP_ADD,
        .src_alpha_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE,
        .dst_alpha_blendfactor = c.SDL_GPU_BLENDFACTOR_ZERO,
        .alpha_blend_op = c.SDL_GPU_BLENDOP_ADD,
        .enable_blend = additive,
    }) });
    return c.SDL_CreateGPUGraphicsPipeline(device, &std.mem.zeroInit(c.SDL_GPUGraphicsPipelineCreateInfo, .{
        .vertex_shader = vertex,
        .fragment_shader = frag,
        .primitive_type = c.SDL_GPU_PRIMITIVETYPE_TRIANGLELIST,
        .target_info = std.mem.zeroInit(c.SDL_GPUGraphicsPipelineTargetInfo, .{ .color_target_descriptions = &color, .num_color_targets = 1 }),
    })) orelse return error.HdrPipelineCreationFailed;
}
