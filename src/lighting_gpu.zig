//! Renderer-owned light transport. Game composition supplies resolved emitters.
const std = @import("std");
const c = @import("sdl.zig").c;
const contracts = @import("engine_contracts");
const shadows_module = @import("shadow_renderer.zig");
const allocator = std.heap.page_allocator;

pub const Instance = contracts.lighting.Instance;

/// std140 array stride 64; no packed vec3 or compiler-dependent enum layout.
pub const Record = extern struct {
    position_range: [4]f32,
    color_intensity: [4]f32,
    direction_outer: [4]f32,
    parameters: [4]f32, // inner cosine, squared source radius, kind, shadow view
};

pub const Owner = struct {
    device: *c.SDL_GPUDevice,
    instances: std.ArrayList(Instance) = .empty,
    frame_instances: std.ArrayList(Instance) = .empty,
    environment: ?contracts.lighting.Environment = null,
    shadows: ?shadows_module.Owner = null,
    records: std.ArrayList(Record) = .empty,
    buffer: ?*c.SDL_GPUBuffer = null,
    transfer: ?*c.SDL_GPUTransferBuffer = null,
    capacity_bytes: u32 = 0,

    pub fn deinit(self: *Owner) void {
        self.instances.deinit(allocator);
        self.frame_instances.deinit(allocator);
        if (self.shadows) |*owner| owner.deinit();
        self.records.deinit(allocator);
        if (self.buffer) |buffer| c.SDL_ReleaseGPUBuffer(self.device, buffer);
        if (self.transfer) |transfer| c.SDL_ReleaseGPUTransferBuffer(self.device, transfer);
    }

    pub fn set(self: *Owner, instances: []const Instance) !void {
        for (instances, 0..) |instance, index| {
            for (instances[0..index]) |previous| if (previous.id == instance.id) return error.DuplicateLightIdentity;
            if (instance.id == 0) return error.InvalidLightIdentity;
            try instance.light.validate();
            try instance.pose.validate();
        }
        try self.instances.ensureTotalCapacity(allocator, instances.len);
        self.instances.clearRetainingCapacity();
        self.instances.appendSliceAssumeCapacity(instances);
    }

    pub fn prepare(self: *Owner, cmd: *c.SDL_GPUCommandBuffer, draws: anytype) !void {
        self.frame_instances.clearRetainingCapacity();
        if (self.environment) |environment| try self.frame_instances.append(allocator, .{ .id = 0, .light = environment.sun, .pose = .{ .rotation = try contracts.lighting.rotationFromDirection(environment.sun_direction) } });
        try self.frame_instances.appendSlice(allocator, self.instances.items);

        self.records.clearRetainingCapacity();
        for (self.frame_instances.items) |instance| {
            if (!instance.light.enabled or instance.light.intensity == 0) continue;
            const pose = try instance.pose.normalized();
            const direction = contracts.lighting.emittedDirection(pose);
            const light = instance.light;
            try self.records.append(allocator, .{
                .position_range = .{ pose.position[0], pose.position[1], pose.position[2], light.range orelse 0 },
                .color_intensity = .{ light.color[0], light.color[1], light.color[2], light.intensity },
                .direction_outer = .{ direction[0], direction[1], direction[2], @cos(light.outer_angle) },
                .parameters = .{ @cos(light.inner_angle), @max(light.source_radius * light.source_radius, 1e-8), @floatFromInt(@intFromEnum(light.kind)), -1 },
            });
        }
        if (self.shadows == null) self.shadows = try shadows_module.Owner.init(self.device);
        try self.shadows.?.prepare(cmd, self.frame_instances.items, self.records.items, draws, if (self.environment) |environment| environment.shadow_resolution else 1024, if (self.environment) |environment| environment.shadow_bias else 0.00002);
        const length = try std.math.mul(usize, @max(1, self.records.items.len), @sizeOf(Record));
        const bytes = std.math.cast(u32, length) orelse return error.LightBufferDeviceSizeExceeded;
        if (bytes > self.capacity_bytes) {
            const buffer = c.SDL_CreateGPUBuffer(self.device, &std.mem.zeroInit(c.SDL_GPUBufferCreateInfo, .{
                .usage = c.SDL_GPU_BUFFERUSAGE_GRAPHICS_STORAGE_READ,
                .size = bytes,
            })) orelse return error.LightBufferAllocationFailed;
            errdefer c.SDL_ReleaseGPUBuffer(self.device, buffer);
            const transfer = c.SDL_CreateGPUTransferBuffer(self.device, &std.mem.zeroInit(c.SDL_GPUTransferBufferCreateInfo, .{
                .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
                .size = bytes,
            })) orelse return error.LightTransferAllocationFailed;
            if (self.buffer) |old| c.SDL_ReleaseGPUBuffer(self.device, old);
            if (self.transfer) |old| c.SDL_ReleaseGPUTransferBuffer(self.device, old);
            self.buffer = buffer;
            self.transfer = transfer;
            self.capacity_bytes = bytes;
        }
        const mapped = c.SDL_MapGPUTransferBuffer(self.device, self.transfer.?, true) orelse return error.LightTransferMapFailed;
        const output = @as([*]u8, @ptrCast(mapped))[0..bytes];
        @memset(output, 0);
        @memcpy(output[0 .. self.records.items.len * @sizeOf(Record)], std.mem.sliceAsBytes(self.records.items));
        c.SDL_UnmapGPUTransferBuffer(self.device, self.transfer.?);
        const copy = c.SDL_BeginGPUCopyPass(cmd) orelse return error.LightUploadPassFailed;
        defer c.SDL_EndGPUCopyPass(copy);
        c.SDL_UploadToGPUBuffer(copy, &.{ .transfer_buffer = self.transfer.?, .offset = 0 }, &.{ .buffer = self.buffer.?, .offset = 0, .size = bytes }, true);
    }

    pub fn bind(self: *const Owner, pass: *c.SDL_GPURenderPass) void {
        const buffers = [_]?*c.SDL_GPUBuffer{ self.buffer, self.shadows.?.buffer };
        c.SDL_BindGPUFragmentStorageBuffers(pass, 0, &buffers, buffers.len);
        c.SDL_BindGPUFragmentSamplers(pass, 5, &.{ .texture = self.shadows.?.texture, .sampler = self.shadows.?.sampler }, 1);
    }
};

comptime {
    std.debug.assert(@sizeOf(Record) == 64);
}
