//! Indexed direct-light shadow views. Depth and color consume the same immutable
//! product draw list. Arrays grow with authored content; allocation fails openly.
const std = @import("std");
const zm = @import("zmath");
const c = @import("sdl.zig").c;
const mesh = @import("mesh.zig");
const assets = @import("shader_assets");
const contracts = @import("engine_contracts");
const allocator = std.heap.page_allocator;
const depth_format = c.SDL_GPU_TEXTUREFORMAT_D32_FLOAT;
pub const Record = extern struct { matrix: [16]f32, parameters: [4]f32 };
pub const View = struct { matrix: zm.Mat, light_id: u64, face: u32 };
pub const Owner = struct {
    device: *c.SDL_GPUDevice,
    texture: *c.SDL_GPUTexture,
    sampler: *c.SDL_GPUSampler,
    pipelines: [2]*c.SDL_GPUGraphicsPipeline,
    views: std.ArrayList(View) = .empty,
    records: std.ArrayList(Record) = .empty,
    buffer: ?*c.SDL_GPUBuffer = null,
    transfer: ?*c.SDL_GPUTransferBuffer = null,
    bytes: u32 = 0,
    resolution: u32 = 1,
    layers: u32 = 1,
    caster_draws: u64 = 0,

    pub fn init(device: *c.SDL_GPUDevice) !Owner {
        if (!c.SDL_GPUTextureSupportsFormat(device, depth_format, c.SDL_GPU_TEXTURETYPE_2D_ARRAY, c.SDL_GPU_TEXTUREUSAGE_DEPTH_STENCIL_TARGET | c.SDL_GPU_TEXTUREUSAGE_SAMPLER)) return error.ShadowDepthArrayUnsupported;
        const texture = try image(device, 1, 1);
        errdefer c.SDL_ReleaseGPUTexture(device, texture);
        const sampler = c.SDL_CreateGPUSampler(device, &std.mem.zeroInit(c.SDL_GPUSamplerCreateInfo, .{
            .min_filter = c.SDL_GPU_FILTER_LINEAR,
            .mag_filter = c.SDL_GPU_FILTER_LINEAR,
            .mipmap_mode = c.SDL_GPU_SAMPLERMIPMAPMODE_NEAREST,
            .address_mode_u = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
            .address_mode_v = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
            .address_mode_w = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
            .enable_compare = true,
            .compare_op = c.SDL_GPU_COMPAREOP_LESS_OR_EQUAL,
        })) orelse return error.ShadowSamplerFailed;
        errdefer c.SDL_ReleaseGPUSampler(device, sampler);
        const color = try pipeline(device, .pos_color);
        errdefer c.SDL_ReleaseGPUGraphicsPipeline(device, color);
        const normal = try pipeline(device, .pos_normal_uv);
        return .{ .device = device, .texture = texture, .sampler = sampler, .pipelines = .{ color, normal } };
    }
    pub fn deinit(self: *Owner) void {
        self.views.deinit(allocator);
        self.records.deinit(allocator);
        c.SDL_ReleaseGPUTexture(self.device, self.texture);
        c.SDL_ReleaseGPUSampler(self.device, self.sampler);
        for (self.pipelines) |value| c.SDL_ReleaseGPUGraphicsPipeline(self.device, value);
        if (self.buffer) |value| c.SDL_ReleaseGPUBuffer(self.device, value);
        if (self.transfer) |value| c.SDL_ReleaseGPUTransferBuffer(self.device, value);
    }
    pub fn prepare(self: *Owner, cmd: *c.SDL_GPUCommandBuffer, instances: anytype, light_records: anytype, draws: anytype, resolution: u32, bias: f32) !void {
        self.views.clearRetainingCapacity();
        self.records.clearRetainingCapacity();
        self.caster_draws = 0;
        var index: usize = 0;
        for (instances) |instance| {
            if (!instance.light.enabled or instance.light.intensity == 0) continue;
            const record = &light_records[index];
            index += 1;
            if (!instance.light.casts_shadows or draws.len == 0) continue;
            const first = self.views.items.len;
            const light = instance.light;
            const pose = try instance.pose.normalized();
            const direction = contracts.lighting.emittedDirection(pose);
            if (light.kind == .directional) {
                // World-anchored fit: camera motion alone cannot slide the sun map.
                const view = look(.{ 0, 0, 0 }, direction);
                var bounds = emptyBounds();
                for (draws) |command| switch (command) {
                    .product => |draw| if (!draw.material.display_space and draw.material.casts_shadows) extend(&bounds, draw.mesh.bounds, zm.mul(draw.model, view)),
                    .debug => {},
                };
                if (!std.math.isFinite(bounds.min[0])) continue;
                const width = @max(bounds.max[0] - bounds.min[0], 0.01);
                const height = @max(bounds.max[1] - bounds.min[1], 0.01);
                const texel_x = width / @as(f32, @floatFromInt(resolution));
                const texel_y = height / @as(f32, @floatFromInt(resolution));
                const center_x = @floor((bounds.min[0] + bounds.max[0]) * 0.5 / texel_x) * texel_x;
                const center_y = @floor((bounds.min[1] + bounds.max[1]) * 0.5 / texel_y) * texel_y;
                const projection = zm.orthographicOffCenterRh(center_x - width * 0.5 - texel_x, center_x + width * 0.5 + texel_x, center_y + height * 0.5 + texel_y, center_y - height * 0.5 - texel_y, -bounds.max[2] - 0.1, -bounds.min[2] + 0.1);
                try self.append(zm.mul(view, projection), instance.id, 0, resolution, bias);
            } else {
                var far = light.range orelse 0;
                if (light.range == null) {
                    var bounds = emptyBounds();
                    for (draws) |command| switch (command) {
                        .product => |draw| if (!draw.material.display_space and draw.material.casts_shadows) extend(&bounds, draw.mesh.bounds, draw.model),
                        .debug => {},
                    };
                    if (!std.math.isFinite(bounds.min[0])) continue;
                    for (corners(bounds)) |corner| {
                        const d = corner - zm.loadArr3(pose.position);
                        far = @max(far, @sqrt(zm.dot3(d, d)[0]));
                    }
                }
                // Near clip follows the authored source's regularization scale.
                const near = @min(@max(light.source_radius * 0.1, 0.001), far * 0.01);
                if (light.kind == .spot and light.outer_angle < std.math.pi / 2.0) {
                    // A full hemisphere uses the same six addressed views as a
                    // point source; cone attenuation still defines its energy.
                    try self.append(zm.mul(look(pose.position, direction), zm.perspectiveFovRh(light.outer_angle * 2, 1, near, far)), instance.id, 0, resolution, bias);
                } else {
                    const directions = [_][3]f32{ .{ 1, 0, 0 }, .{ -1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, -1, 0 }, .{ 0, 0, 1 }, .{ 0, 0, -1 } };
                    for (directions, 0..) |face, face_index| try self.append(zm.mul(look(pose.position, face), zm.perspectiveFovRh(std.math.pi / 2.0, 1, near, far)), instance.id, @intCast(face_index), resolution, bias);
                }
            }
            record.parameters[3] = @floatFromInt(first);
        }
        const layers = std.math.cast(u32, @max(1, self.views.items.len)) orelse return error.ShadowLayerDeviceSizeExceeded;
        // Pinned SDL depth attachments expose Uint8 layers and document at most
        // 255 layers. Fail before allocation; never truncate authored lights.
        if (layers > std.math.maxInt(u8)) return error.SDLDepthArrayLayerAddressExceeded;
        const actual_resolution = if (self.views.items.len == 0) 1 else resolution;
        if (layers > self.layers or actual_resolution != self.resolution) {
            const next = try image(self.device, actual_resolution, layers);
            c.SDL_ReleaseGPUTexture(self.device, self.texture);
            self.texture = next;
            self.layers = layers;
            self.resolution = actual_resolution;
        }
        try self.upload(cmd);
        // Clear the dummy layer too: neutral previews bind a valid depth array.
        for (0..@max(1, self.views.items.len)) |layer| {
            const target = std.mem.zeroInit(c.SDL_GPUDepthStencilTargetInfo, .{
                .texture = self.texture,
                .layer = @as(u8, @intCast(layer)),
                .clear_depth = 1,
                .load_op = c.SDL_GPU_LOADOP_CLEAR,
                .store_op = c.SDL_GPU_STOREOP_STORE,
                .stencil_load_op = c.SDL_GPU_LOADOP_DONT_CARE,
                .stencil_store_op = c.SDL_GPU_STOREOP_DONT_CARE,
            });
            const pass = c.SDL_BeginGPURenderPass(cmd, null, 0, &target) orelse return error.ShadowPassFailed;
            defer c.SDL_EndGPURenderPass(pass);
            if (layer >= self.views.items.len) continue;
            const view = self.views.items[layer];
            for (draws) |command| switch (command) {
                .debug => {},
                .product => |draw| {
                    if (draw.material.display_space or !draw.material.casts_shadows) continue;
                    if (!intersectsClip(draw.mesh.bounds, zm.mul(draw.model, view.matrix))) continue;
                    c.SDL_BindGPUGraphicsPipeline(pass, self.pipelines[@intFromEnum(draw.mesh.vertex_format)]);
                    const matrix = zm.matToArr(zm.mul(draw.model, view.matrix));
                    c.SDL_PushGPUVertexUniformData(cmd, 0, &matrix, @sizeOf(@TypeOf(matrix)));
                    c.SDL_BindGPUVertexBuffers(pass, 0, &.{ .buffer = draw.mesh.vertex_buffer, .offset = 0 }, 1);
                    if (draw.mesh.index_buffer) |buffer| {
                        c.SDL_BindGPUIndexBuffer(pass, &.{ .buffer = buffer, .offset = 0 }, c.SDL_GPU_INDEXELEMENTSIZE_32BIT);
                        c.SDL_DrawGPUIndexedPrimitives(pass, draw.mesh.index_count, 1, 0, 0, 0);
                    } else c.SDL_DrawGPUPrimitives(pass, draw.mesh.vertex_count, 1, 0, 0);
                    self.caster_draws += 1;
                },
            };
        }
    }
    fn append(self: *Owner, matrix: zm.Mat, id: u64, face: u32, resolution: u32, bias: f32) !void {
        try self.views.append(allocator, .{ .matrix = matrix, .light_id = id, .face = face });
        try self.records.append(allocator, .{ .matrix = zm.matToArr(matrix), .parameters = .{ bias, 1 / @as(f32, @floatFromInt(resolution)), 0, 0 } });
    }
    fn upload(self: *Owner, cmd: *c.SDL_GPUCommandBuffer) !void {
        const size = std.math.cast(u32, try std.math.mul(usize, @max(1, self.records.items.len), @sizeOf(Record))) orelse return error.ShadowBufferDeviceSizeExceeded;
        if (size > self.bytes) {
            const buffer = c.SDL_CreateGPUBuffer(self.device, &std.mem.zeroInit(c.SDL_GPUBufferCreateInfo, .{ .usage = c.SDL_GPU_BUFFERUSAGE_GRAPHICS_STORAGE_READ, .size = size })) orelse return error.ShadowBufferAllocationFailed;
            errdefer c.SDL_ReleaseGPUBuffer(self.device, buffer);
            const transfer = c.SDL_CreateGPUTransferBuffer(self.device, &std.mem.zeroInit(c.SDL_GPUTransferBufferCreateInfo, .{ .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD, .size = size })) orelse return error.ShadowTransferAllocationFailed;
            if (self.buffer) |old| c.SDL_ReleaseGPUBuffer(self.device, old);
            if (self.transfer) |old| c.SDL_ReleaseGPUTransferBuffer(self.device, old);
            self.buffer = buffer;
            self.transfer = transfer;
            self.bytes = size;
        }
        const mapped = c.SDL_MapGPUTransferBuffer(self.device, self.transfer.?, true) orelse return error.ShadowTransferMapFailed;
        const output = @as([*]u8, @ptrCast(mapped))[0..size];
        @memset(output, 0);
        @memcpy(output[0 .. self.records.items.len * @sizeOf(Record)], std.mem.sliceAsBytes(self.records.items));
        c.SDL_UnmapGPUTransferBuffer(self.device, self.transfer.?);
        const copy = c.SDL_BeginGPUCopyPass(cmd) orelse return error.ShadowUploadPassFailed;
        defer c.SDL_EndGPUCopyPass(copy);
        c.SDL_UploadToGPUBuffer(copy, &.{ .transfer_buffer = self.transfer.?, .offset = 0 }, &.{ .buffer = self.buffer.?, .offset = 0, .size = size }, true);
    }
};
fn image(device: *c.SDL_GPUDevice, resolution: u32, layers: u32) !*c.SDL_GPUTexture {
    return c.SDL_CreateGPUTexture(device, &std.mem.zeroInit(c.SDL_GPUTextureCreateInfo, .{ .type = c.SDL_GPU_TEXTURETYPE_2D_ARRAY, .format = depth_format, .usage = c.SDL_GPU_TEXTUREUSAGE_DEPTH_STENCIL_TARGET | c.SDL_GPU_TEXTUREUSAGE_SAMPLER, .width = resolution, .height = resolution, .layer_count_or_depth = layers, .num_levels = 1 })) orelse error.ShadowArrayAllocationFailed;
}
fn look(position: [3]f32, direction: [3]f32) zm.Mat {
    const eye = zm.f32x4(position[0], position[1], position[2], 1);
    const ray = zm.f32x4(direction[0], direction[1], direction[2], 0);
    return zm.lookAtRh(eye, eye + ray, if (@abs(direction[1]) > 0.99) zm.f32x4(0, 0, 1, 0) else zm.f32x4(0, 1, 0, 0));
}
fn emptyBounds() mesh.Bounds {
    return .{ .min = @splat(std.math.inf(f32)), .max = @splat(-std.math.inf(f32)) };
}
fn corners(bounds: mesh.Bounds) [8]zm.Vec {
    var result: [8]zm.Vec = undefined;
    for (&result, 0..) |*corner, index| corner.* = zm.f32x4(if (index & 1 == 0) bounds.min[0] else bounds.max[0], if (index & 2 == 0) bounds.min[1] else bounds.max[1], if (index & 4 == 0) bounds.min[2] else bounds.max[2], 1);
    return result;
}
fn extend(bounds: *mesh.Bounds, source: mesh.Bounds, transform: zm.Mat) void {
    for (corners(source)) |corner| {
        const value = zm.mul(corner, transform);
        inline for (0..3) |axis| {
            bounds.min[axis] = @min(bounds.min[axis], value[axis]);
            bounds.max[axis] = @max(bounds.max[axis], value[axis]);
        }
    }
}
pub fn intersectsClip(bounds: mesh.Bounds, transform: zm.Mat) bool {
    var outside: [6]bool = @splat(true);
    for (corners(bounds)) |corner| {
        const p = zm.mul(corner, transform);
        const planes = [_]bool{ p[0] < -p[3], p[0] > p[3], p[1] < -p[3], p[1] > p[3], p[2] < 0, p[2] > p[3] };
        for (&outside, planes) |*all, one| all.* = all.* and one;
    }
    for (outside) |all| if (all) return false;
    return true;
}
fn pipeline(device: *c.SDL_GPUDevice, format: mesh.VertexFormat) !*c.SDL_GPUGraphicsPipeline {
    const vertex = c.SDL_CreateGPUShader(device, &std.mem.zeroInit(c.SDL_GPUShaderCreateInfo, .{ .code = assets.shadow_vertex.ptr, .code_size = assets.shadow_vertex.len, .entrypoint = assets.entrypoint, .format = c.SDL_GPU_SHADERFORMAT_MSL, .stage = c.SDL_GPU_SHADERSTAGE_VERTEX, .num_uniform_buffers = 1 })) orelse return error.ShadowVertexShaderFailed;
    defer c.SDL_ReleaseGPUShader(device, vertex);
    const fragment = c.SDL_CreateGPUShader(device, &std.mem.zeroInit(c.SDL_GPUShaderCreateInfo, .{ .code = assets.shadow_fragment.ptr, .code_size = assets.shadow_fragment.len, .entrypoint = assets.entrypoint, .format = c.SDL_GPU_SHADERFORMAT_MSL, .stage = c.SDL_GPU_SHADERSTAGE_FRAGMENT })) orelse return error.ShadowFragmentShaderFailed;
    defer c.SDL_ReleaseGPUShader(device, fragment);
    const buffer = std.mem.zeroInit(c.SDL_GPUVertexBufferDescription, .{ .slot = 0, .pitch = format.stride(), .input_rate = c.SDL_GPU_VERTEXINPUTRATE_VERTEX });
    const attribute = std.mem.zeroInit(c.SDL_GPUVertexAttribute, .{ .location = 0, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT3, .offset = 0 });
    return c.SDL_CreateGPUGraphicsPipeline(device, &std.mem.zeroInit(c.SDL_GPUGraphicsPipelineCreateInfo, .{
        .vertex_shader = vertex,
        .fragment_shader = fragment,
        .vertex_input_state = .{ .vertex_buffer_descriptions = &buffer, .num_vertex_buffers = 1, .vertex_attributes = &attribute, .num_vertex_attributes = 1 },
        .primitive_type = c.SDL_GPU_PRIMITIVETYPE_TRIANGLELIST,
        .rasterizer_state = .{ .fill_mode = c.SDL_GPU_FILLMODE_FILL, .cull_mode = c.SDL_GPU_CULLMODE_NONE, .front_face = c.SDL_GPU_FRONTFACE_COUNTER_CLOCKWISE, .enable_depth_clip = true },
        .depth_stencil_state = .{ .compare_op = c.SDL_GPU_COMPAREOP_LESS, .enable_depth_test = true, .enable_depth_write = true },
        .target_info = .{ .has_depth_stencil_target = true, .depth_stencil_format = depth_format },
    })) orelse error.ShadowPipelineFailed;
}
