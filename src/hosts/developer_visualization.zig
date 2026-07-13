//! Typed host-only controls and immutable summaries for S4-C visualization.
//!
//! This module does not import a renderer, physics backend, editor, or runtime.
//! Requests are applied by the visual composition root between frames and can
//! never mutate authoritative simulation state.

const std = @import("std");
const physics_debug = @import("engine_contracts").physics_debug;

pub const request_capacity: usize = 24;

pub const Config = struct {
    enabled: bool = false,
    shapes: bool = true,
    bounds: bool = true,
    contacts: bool = true,
    centers_of_mass: bool = true,
    velocities: bool = true,
};

pub const Request = union(enum) {
    set_enabled: bool,
    set_category: struct {
        category: physics_debug.Category,
        enabled: bool,
    },
    set_profiling_enabled: bool,
    clear_profile_history,
};

pub const RequestBuffer = struct {
    values: [request_capacity]Request = undefined,
    count: usize = 0,
    rejected: u64 = 0,

    pub fn push(self: *RequestBuffer, request: Request) bool {
        if (self.count == self.values.len) {
            physics_debug.saturatingIncrement(&self.rejected);
            return false;
        }
        self.values[self.count] = request;
        self.count += 1;
        return true;
    }

    pub fn slice(self: *const RequestBuffer) []const Request {
        return self.values[0..self.count];
    }

    pub fn clear(self: *RequestBuffer) void {
        self.count = 0;
    }
};

pub const Controller = struct {
    config: Config = .{},
    profiling_enabled: bool = true,

    /// Apply a host request and report whether profile history must be cleared.
    /// Clearing belongs to the profiler owner, so this controller returns that
    /// action instead of retaining a mutable pointer to it.
    pub fn apply(self: *Controller, request: Request) bool {
        return switch (request) {
            .set_enabled => |enabled| blk: {
                self.config.enabled = enabled;
                break :blk false;
            },
            .set_category => |change| blk: {
                switch (change.category) {
                    .shape => self.config.shapes = change.enabled,
                    .bounds => self.config.bounds = change.enabled,
                    .contact => self.config.contacts = change.enabled,
                    .center_of_mass => self.config.centers_of_mass = change.enabled,
                    .velocity => self.config.velocities = change.enabled,
                }
                break :blk false;
            },
            .set_profiling_enabled => |enabled| blk: {
                self.profiling_enabled = enabled;
                break :blk false;
            },
            .clear_profile_history => true,
        };
    }
};

pub const BatchSummary = struct {
    completed_tick: u64,
    generation: u64,
    line_count: u32,
    triangle_count: u32,
    category_stats: [physics_debug.category_count]physics_debug.CategoryStats,

    pub fn fromBatch(batch: physics_debug.Batch) BatchSummary {
        var stats: [physics_debug.category_count]physics_debug.CategoryStats = undefined;
        @memcpy(stats[0..], batch.category_stats);
        return .{
            .completed_tick = batch.completed_tick,
            .generation = batch.generation,
            .line_count = @intCast(batch.lines.len),
            .triangle_count = @intCast(batch.triangles.len),
            .category_stats = stats,
        };
    }

    pub fn dropped(self: BatchSummary) u64 {
        var total: u64 = 0;
        for (self.category_stats) |stats| {
            physics_debug.saturatingAdd(&total, stats.lines.dropped);
            physics_debug.saturatingAdd(&total, stats.triangles.dropped);
        }
        return total;
    }
};

pub const GpuSummary = struct {
    available: bool,
    enabled: bool,
    uploaded_generation: u64,
    line_vertices: u32,
    triangle_vertices: u32,
    upload_bytes: u64,
    uploads: u64,
    draws: u64,
    dropped_batches: u64,
    failures: u64,
    backpressure_drops: u64,
    slot_count: u8,
    free_slots: u8,
    busy_slots: u8,
    copy_pending_slots: u8,
    retired_slots: u8,
    live_fences: u8,
    peak_fences: u8,
    max_fences: u8,
    frame_fence_failures: u64,
    slot_retirements: u64,
};

pub const Snapshot = struct {
    config: Config,
    profiling_enabled: bool,
    rejected_requests: u64,
    /// False when the visual host could not reserve optional CPU geometry.
    /// Simulation authority remains available in that state.
    cpu_available: bool,
    batch: ?BatchSummary,
    gpu: ?GpuSummary,
};

test "bounded visualization requests apply without a mutable service pointer" {
    var requests = RequestBuffer{};
    try std.testing.expect(requests.push(.{ .set_enabled = true }));
    try std.testing.expect(requests.push(.{ .set_category = .{
        .category = .bounds,
        .enabled = false,
    } }));
    try std.testing.expect(requests.push(.{ .set_profiling_enabled = false }));
    try std.testing.expect(requests.push(.clear_profile_history));

    var controller = Controller{};
    var clear_requested = false;
    for (requests.slice()) |request| {
        clear_requested = controller.apply(request) or clear_requested;
    }
    try std.testing.expect(controller.config.enabled);
    try std.testing.expect(!controller.config.bounds);
    try std.testing.expect(!controller.profiling_enabled);
    try std.testing.expect(clear_requested);
    requests.clear();
    try std.testing.expectEqual(@as(usize, 0), requests.slice().len);
}

test "request saturation and batch drops remain visible" {
    var requests = RequestBuffer{};
    for (0..request_capacity) |_| {
        try std.testing.expect(requests.push(.{ .set_enabled = true }));
    }
    try std.testing.expect(!requests.push(.{ .set_enabled = false }));
    try std.testing.expectEqual(@as(u64, 1), requests.rejected);

    var lines: [1]physics_debug.Line = undefined;
    var triangles: [0]physics_debug.Triangle = undefined;
    var storage = physics_debug.Storage.init(&lines, &triangles);
    storage.begin(9);
    try std.testing.expect(storage.markSourceUnavailable(.contact));
    const line = physics_debug.Line{
        .category = .shape,
        .start = .{ 0, 0, 0 },
        .end = .{ 1, 0, 0 },
        .color = .{ 1, 1, 1, 1 },
    };
    try std.testing.expectEqual(physics_debug.Admission.admitted, storage.addLine(line));
    try std.testing.expectEqual(physics_debug.Admission.dropped_overflow, storage.addLine(line));
    const summary = BatchSummary.fromBatch(storage.batch().?);
    try std.testing.expectEqual(@as(u32, 1), summary.line_count);
    try std.testing.expectEqual(@as(u64, 1), summary.dropped());
    try std.testing.expect(summary.category_stats[@intFromEnum(physics_debug.Category.contact)].source_unavailable);
}
