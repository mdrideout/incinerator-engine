//! Host-only developer controls for fixed-step execution.
//!
//! These values are deliberately absent from authoritative simulation state
//! and persistence. They control when the host grants ticks; they never alter
//! the duration of a simulation tick.

const std = @import("std");

/// Deliberately small, validated set of developer playback rates. Arbitrary
/// floating-point rates are not accepted at the host/timer boundary.
pub const TimeScale = enum {
    quarter,
    half,
    normal,
    double,

    pub fn multiplier(self: TimeScale) f64 {
        return switch (self) {
            .quarter => 0.25,
            .half => 0.5,
            .normal => 1.0,
            .double => 2.0,
        };
    }
};

/// Per-frame clock policy consumed by the presentation-clock adapter. A
/// paused frame still samples raw wall time for frame diagnostics, but grants
/// no wall-time contribution to the fixed-step accumulator.
pub const ClockPolicy = union(enum) {
    paused,
    running: TimeScale,
};

/// Typed requests are the only mutation surface intended for editor/debug UI.
/// Applying one changes ephemeral host policy, never authoritative state.
pub const Request = union(enum) {
    set_paused: bool,
    single_step,
    set_time_scale: TimeScale,
};

pub const max_frame_requests: usize = 8;

/// Fixed per-frame UI-to-host mailbox. Saturation is visible and cannot
/// allocate or mutate simulation directly.
pub const RequestBuffer = struct {
    items: [max_frame_requests]Request = undefined,
    count: u8 = 0,
    rejected: u64 = 0,

    pub fn push(self: *RequestBuffer, request: Request) bool {
        if (self.count == max_frame_requests) {
            self.rejected +|= 1;
            return false;
        }
        self.items[self.count] = request;
        self.count += 1;
        return true;
    }

    pub fn slice(self: *const RequestBuffer) []const Request {
        return self.items[0..self.count];
    }

    pub fn clear(self: *RequestBuffer) void {
        self.count = 0;
    }
};

pub const ApplyResult = struct {
    entered_pause: bool = false,
    resumed: bool = false,
    scale_changed: bool = false,
    step_queued: bool = false,
};

/// Immutable value suitable for diagnostics and UI display.
pub const Snapshot = struct {
    paused: bool,
    time_scale: TimeScale,
    single_step_pending: bool,
};

pub const Controller = struct {
    paused: bool = false,
    time_scale: TimeScale = .normal,
    single_step_pending: bool = false,

    pub fn apply(self: *Controller, request: Request) !ApplyResult {
        return switch (request) {
            .set_paused => |value| self.setPaused(value),
            .single_step => self.queueSingleStep(),
            .set_time_scale => |value| self.setTimeScale(value),
        };
    }

    pub fn clockPolicy(self: *const Controller) ClockPolicy {
        return if (self.paused)
            .paused
        else
            .{ .running = self.time_scale };
    }

    /// Consume at most one previously accepted step. The boolean request is
    /// intentionally non-counting so repeated UI submission cannot create an
    /// accidental catch-up burst.
    pub fn takeSingleStep(self: *Controller) bool {
        if (!self.paused or !self.single_step_pending) return false;
        self.single_step_pending = false;
        return true;
    }

    pub fn snapshot(self: *const Controller) Snapshot {
        return .{
            .paused = self.paused,
            .time_scale = self.time_scale,
            .single_step_pending = self.single_step_pending,
        };
    }

    fn setPaused(self: *Controller, value: bool) !ApplyResult {
        if (self.paused == value) return .{};
        if (!value and self.single_step_pending) {
            return error.SingleStepPending;
        }
        self.paused = value;
        return if (value)
            .{ .entered_pause = true }
        else
            .{ .resumed = true };
    }

    fn queueSingleStep(self: *Controller) !ApplyResult {
        if (!self.paused) return error.SingleStepRequiresPause;
        if (self.single_step_pending) return error.SingleStepAlreadyPending;
        self.single_step_pending = true;
        return .{ .step_queued = true };
    }

    fn setTimeScale(self: *Controller, value: TimeScale) ApplyResult {
        if (self.time_scale == value) return .{};
        self.time_scale = value;
        return .{ .scale_changed = true };
    }
};

test "time scales expose only the supported finite multipliers" {
    try std.testing.expectEqual(@as(f64, 0.25), TimeScale.quarter.multiplier());
    try std.testing.expectEqual(@as(f64, 0.5), TimeScale.half.multiplier());
    try std.testing.expectEqual(@as(f64, 1.0), TimeScale.normal.multiplier());
    try std.testing.expectEqual(@as(f64, 2.0), TimeScale.double.multiplier());
    inline for (std.meta.tags(TimeScale)) |scale| {
        try std.testing.expect(std.math.isFinite(scale.multiplier()));
        try std.testing.expect(scale.multiplier() > 0);
    }
}

test "pause and resume produce explicit host transitions" {
    var controller = Controller{};
    try std.testing.expectEqual(
        ClockPolicy{ .running = .normal },
        controller.clockPolicy(),
    );

    const paused = try controller.apply(.{ .set_paused = true });
    try std.testing.expect(paused.entered_pause);
    try std.testing.expect(controller.clockPolicy() == .paused);
    try std.testing.expectEqual(ApplyResult{}, try controller.apply(.{ .set_paused = true }));

    const resumed = try controller.apply(.{ .set_paused = false });
    try std.testing.expect(resumed.resumed);
    try std.testing.expectEqual(
        ClockPolicy{ .running = .normal },
        controller.clockPolicy(),
    );
}

test "single step is accepted only while paused and consumed exactly once" {
    var controller = Controller{};
    try std.testing.expectError(
        error.SingleStepRequiresPause,
        controller.apply(.single_step),
    );

    _ = try controller.apply(.{ .set_paused = true });
    const queued = try controller.apply(.single_step);
    try std.testing.expect(queued.step_queued);
    try std.testing.expectError(
        error.SingleStepAlreadyPending,
        controller.apply(.single_step),
    );
    try std.testing.expectError(
        error.SingleStepPending,
        controller.apply(.{ .set_paused = false }),
    );

    try std.testing.expect(controller.takeSingleStep());
    try std.testing.expect(!controller.takeSingleStep());
    try std.testing.expect(controller.snapshot().paused);
    _ = try controller.apply(.{ .set_paused = false });
}

test "time scale can be selected while paused without granting a step" {
    var controller = Controller{};
    _ = try controller.apply(.{ .set_paused = true });
    const changed = try controller.apply(.{ .set_time_scale = .double });
    try std.testing.expect(changed.scale_changed);
    try std.testing.expect(controller.clockPolicy() == .paused);
    try std.testing.expect(!controller.takeSingleStep());

    _ = try controller.apply(.{ .set_paused = false });
    try std.testing.expectEqual(
        ClockPolicy{ .running = .double },
        controller.clockPolicy(),
    );
}

test "per-frame request buffer is bounded and visibly rejects overflow" {
    var requests = RequestBuffer{};
    for (0..max_frame_requests) |_| {
        try std.testing.expect(requests.push(.{ .set_paused = true }));
    }
    try std.testing.expect(!requests.push(.single_step));
    try std.testing.expectEqual(@as(u64, 1), requests.rejected);
    try std.testing.expectEqual(max_frame_requests, requests.slice().len);
    requests.clear();
    try std.testing.expectEqual(@as(usize, 0), requests.slice().len);
    try std.testing.expectEqual(@as(u64, 1), requests.rejected);
}
