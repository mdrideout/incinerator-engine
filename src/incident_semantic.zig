//! Asynchronous semantic-ID evidence for human-test incident flags.
//!
//! This is a single bounded offscreen pass encoded into the current product
//! frame. It reuses the validation visibility shader, polls a post-submission
//! fence without waiting, and emits one colored ID image plus stable identity
//! map per flag.

const std = @import("std");
const zm = @import("zmath");
const engine = @import("incinerator_engine");
const renderer = @import("renderer.zig");
const mesh_module = @import("mesh.zig");
const sdl = @import("sdl.zig");
const visibility = @import("visibility_oracle.zig");
const incident_capture = @import("hosts/incident_capture.zig");

const c = sdl.c;

pub const maximum_draws: usize = visibility.maximum_draws;
pub const maximum_schedules: usize = 32;

comptime {
    std.debug.assert(maximum_draws == incident_capture.maximum_semantic_entries);
}

pub const Draw = struct {
    entity: engine.gameplay_trace.EntityRef,
    mesh: *const mesh_module.Mesh,
    model: zm.Mat,
    view_projection: zm.Mat,
};

const Status = enum { idle, encoded, submitted };

const Schedule = struct {
    anomaly_id: u32,
    flagged_ns: u64,
    submitted: bool = false,
    complete: bool = false,
};

const Slot = struct {
    status: Status = .idle,
    fence: ?*renderer.SubmissionFence = null,
    schedule_index: u8 = 0,
    capture_sequence: u64 = 0,
    captured_ns: u64 = 0,
    submitted_ns: u64 = 0,
    authority_tick: u64 = 0,
    presentation_frame: u64 = 0,
    entries: [maximum_draws]incident_capture.SemanticMapEntry = undefined,
    entry_count: u8 = 0,
};

pub const Owner = struct {
    device: *c.SDL_GPUDevice,
    pipeline: *c.SDL_GPUGraphicsPipeline,
    id_target: *c.SDL_GPUTexture,
    color_target: *c.SDL_GPUTexture,
    depth_target: *c.SDL_GPUTexture,
    download: *c.SDL_GPUTransferBuffer,
    schedules: [maximum_schedules]Schedule = undefined,
    schedule_count: u8 = 0,
    slot: Slot = .{},
    next_capture_sequence: u64 = 0x8000_0000_0000_0001,

    pub fn init(gpu: *renderer.Renderer) !Owner {
        const device = gpu.getDevice();
        const id_target = try visibility.createColorTarget(device);
        errdefer c.SDL_ReleaseGPUTexture(device, id_target);
        const color_target = try visibility.createColorTarget(device);
        errdefer c.SDL_ReleaseGPUTexture(device, color_target);
        const depth_target = c.SDL_CreateGPUTexture(device, &c.SDL_GPUTextureCreateInfo{
            .type = c.SDL_GPU_TEXTURETYPE_2D,
            .format = gpu.getDepthFormat(),
            .usage = c.SDL_GPU_TEXTUREUSAGE_DEPTH_STENCIL_TARGET,
            .width = visibility.width,
            .height = visibility.height,
            .layer_count_or_depth = 1,
            .num_levels = 1,
            .sample_count = c.SDL_GPU_SAMPLECOUNT_1,
            .props = 0,
        }) orelse return error.IncidentSemanticDepthCreationFailed;
        errdefer c.SDL_ReleaseGPUTexture(device, depth_target);
        const download = c.SDL_CreateGPUTransferBuffer(
            device,
            &c.SDL_GPUTransferBufferCreateInfo{
                .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_DOWNLOAD,
                .size = visibility.target_bytes,
                .props = 0,
            },
        ) orelse return error.IncidentSemanticTransferCreationFailed;
        errdefer c.SDL_ReleaseGPUTransferBuffer(device, download);
        return .{
            .device = device,
            .pipeline = try visibility.createPipeline(device, gpu.getDepthFormat()),
            .id_target = id_target,
            .color_target = color_target,
            .depth_target = depth_target,
            .download = download,
        };
    }

    pub fn deinit(self: *Owner) void {
        if (self.slot.fence) |fence| fence.release();
        c.SDL_ReleaseGPUGraphicsPipeline(self.device, self.pipeline);
        c.SDL_ReleaseGPUTransferBuffer(self.device, self.download);
        c.SDL_ReleaseGPUTexture(self.device, self.depth_target);
        c.SDL_ReleaseGPUTexture(self.device, self.color_target);
        c.SDL_ReleaseGPUTexture(self.device, self.id_target);
        self.* = undefined;
    }

    pub fn flag(
        self: *Owner,
        capture: *incident_capture.Capture,
        anomaly_id: u32,
        flagged_ns: u64,
    ) void {
        if (self.schedule_count == self.schedules.len) {
            capture.noteVisualFailure(anomaly_id);
            return;
        }
        self.schedules[self.schedule_count] = .{
            .anomaly_id = anomaly_id,
            .flagged_ns = flagged_ns,
        };
        self.schedule_count += 1;
    }

    pub fn prepare(
        self: *Owner,
        gpu: *renderer.Renderer,
        capture: *incident_capture.Capture,
        now_ns: u64,
        authority_tick: u64,
        presentation_frame: u64,
        draws: []const Draw,
    ) void {
        self.poll(capture, now_ns);
        if (self.slot.status != .idle) return;
        var schedule_index: ?u8 = null;
        for (self.schedules[0..self.schedule_count], 0..) |schedule, index| {
            if (!schedule.submitted and !schedule.complete) {
                schedule_index = @intCast(index);
                break;
            }
        }
        const selected_schedule = schedule_index orelse return;
        const schedule = &self.schedules[selected_schedule];
        if (draws.len == 0 or draws.len > maximum_draws) {
            schedule.complete = true;
            capture.noteVisualFailure(schedule.anomaly_id);
            return;
        }
        const cmd = gpu.getCurrentCommandBuffer() orelse return;
        var semantic_draws: [maximum_draws]visibility.Draw = undefined;
        for (draws, 0..) |draw, index| {
            const object_id: u32 = @intCast(index + 1);
            const color = semanticColor(object_id);
            semantic_draws[index] = .{
                .object_id = object_id,
                .mesh = draw.mesh,
                .model = draw.model,
                .view_projection = draw.view_projection,
                .display_color = .{
                    @as(f32, @floatFromInt(color[0])) / 255.0,
                    @as(f32, @floatFromInt(color[1])) / 255.0,
                    @as(f32, @floatFromInt(color[2])) / 255.0,
                    1,
                },
            };
            self.slot.entries[index] = .{
                .object_id = object_id,
                .entity = draw.entity,
                .color_rgb = color,
            };
        }
        const targets = [_]c.SDL_GPUColorTargetInfo{
            visibility.colorTargetInfo(self.id_target),
            visibility.colorTargetInfo(self.color_target),
        };
        const depth = c.SDL_GPUDepthStencilTargetInfo{
            .texture = self.depth_target,
            .clear_depth = 1.0,
            .load_op = c.SDL_GPU_LOADOP_CLEAR,
            .store_op = c.SDL_GPU_STOREOP_DONT_CARE,
            .stencil_load_op = c.SDL_GPU_LOADOP_DONT_CARE,
            .stencil_store_op = c.SDL_GPU_STOREOP_DONT_CARE,
            .cycle = false,
            .clear_stencil = 0,
            .mip_level = 0,
            .layer = 0,
        };
        const pass = c.SDL_BeginGPURenderPass(cmd, &targets, targets.len, &depth) orelse {
            schedule.complete = true;
            capture.noteVisualFailure(schedule.anomaly_id);
            return;
        };
        c.SDL_BindGPUGraphicsPipeline(pass, self.pipeline);
        for (semantic_draws[0..draws.len]) |draw| visibility.drawOne(cmd, pass, draw);
        c.SDL_EndGPURenderPass(pass);
        const copy = c.SDL_BeginGPUCopyPass(cmd) orelse {
            schedule.complete = true;
            capture.noteVisualFailure(schedule.anomaly_id);
            return;
        };
        visibility.downloadTarget(copy, self.id_target, self.download, 0);
        c.SDL_EndGPUCopyPass(copy);

        schedule.submitted = true;
        self.slot.status = .encoded;
        self.slot.schedule_index = selected_schedule;
        self.slot.capture_sequence = self.next_capture_sequence;
        self.next_capture_sequence +|= 1;
        self.slot.captured_ns = now_ns;
        self.slot.submitted_ns = now_ns;
        self.slot.authority_tick = authority_tick;
        self.slot.presentation_frame = presentation_frame;
        self.slot.entry_count = @intCast(draws.len);
    }

    pub fn afterSubmission(
        self: *Owner,
        gpu: *renderer.Renderer,
        capture: *incident_capture.Capture,
    ) void {
        if (self.slot.status != .encoded) return;
        self.slot.fence = gpu.retainSubmissionFence() catch {
            const schedule = &self.schedules[self.slot.schedule_index];
            schedule.complete = true;
            capture.noteVisualFailure(schedule.anomaly_id);
            self.slot.status = .idle;
            return;
        };
        self.slot.status = .submitted;
    }

    pub fn needsSubmissionFence(self: *const Owner) bool {
        return self.slot.status == .encoded;
    }

    pub fn drain(self: *Owner, capture: *incident_capture.Capture) void {
        _ = c.SDL_WaitForGPUIdle(self.device);
        if (self.slot.status == .submitted) self.poll(capture, capture.nowNs());
        if (self.slot.status == .encoded) {
            const schedule = &self.schedules[self.slot.schedule_index];
            schedule.complete = true;
            capture.noteVisualFailure(schedule.anomaly_id);
            self.slot.status = .idle;
        }
    }

    fn poll(self: *Owner, capture: *incident_capture.Capture, now_ns: u64) void {
        if (self.slot.status != .submitted) return;
        const fence = self.slot.fence orelse return;
        if (!fence.signaled()) return;
        fence.release();
        self.slot.fence = null;
        const schedule = &self.schedules[self.slot.schedule_index];
        defer {
            schedule.complete = true;
            self.slot.status = .idle;
        }
        const mapped = c.SDL_MapGPUTransferBuffer(self.device, self.download, false) orelse {
            capture.noteVisualFailure(schedule.anomaly_id);
            return;
        };
        defer c.SDL_UnmapGPUTransferBuffer(self.device, self.download);
        const raw: [*]const u8 = @ptrCast(mapped);
        const owned = std.heap.page_allocator.alloc(u8, visibility.target_bytes) catch {
            capture.noteVisualFailure(schedule.anomaly_id);
            return;
        };
        var visible_pixels: usize = 0;
        var offset: usize = 0;
        while (offset < visibility.target_bytes) : (offset += 4) {
            const object_id = visibility.decodeId(raw[offset .. offset + 4]);
            if (object_id == 0 or object_id > self.slot.entry_count) {
                @memset(owned[offset .. offset + 4], 0);
                continue;
            }
            visible_pixels += 1;
            const color = self.slot.entries[object_id - 1].color_rgb;
            owned[offset + 0] = color[0];
            owned[offset + 1] = color[1];
            owned[offset + 2] = color[2];
            owned[offset + 3] = 255;
        }
        const attached = capture.attachSemanticVisual(
            schedule.anomaly_id,
            .{
                .capture_sequence = self.slot.capture_sequence,
                .source = .semantic_id,
                .requested_offset_ms = 0,
                .flag_monotonic_ns = schedule.flagged_ns,
                .target_monotonic_ns = schedule.flagged_ns,
                .captured_monotonic_ns = self.slot.captured_ns,
                .submitted_monotonic_ns = self.slot.submitted_ns,
                .completed_monotonic_ns = now_ns,
                .authority_tick = self.slot.authority_tick,
                .presentation_frame = self.slot.presentation_frame,
                .drawable_generation = 1,
                .width = visibility.width,
                .height = visibility.height,
                .bgra = false,
                .fence_latency_ns = now_ns -| self.slot.submitted_ns,
                .pixel_digest = std.hash.Wyhash.hash(0, owned),
                .suspicious = visible_pixels == 0,
            },
            owned,
            self.slot.entries[0..self.slot.entry_count],
        );
        if (!attached) return;
    }
};

fn semanticColor(object_id: u32) [3]u8 {
    return .{
        @intCast(64 + (object_id *% 97) % 192),
        @intCast(64 + (object_id *% 57) % 192),
        @intCast(64 + (object_id *% 31) % 192),
    };
}

test "semantic colors are non-black and stable" {
    try std.testing.expectEqual([3]u8{ 161, 121, 95 }, semanticColor(1));
    try std.testing.expect(!std.meta.eql(semanticColor(1), semanticColor(2)));
}
