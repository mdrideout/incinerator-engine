//! Deterministic fixed-step accumulation independent of any platform clock.

const std = @import("std");

/// Fixed simulation rate shared by visual and headless hosts.
pub const tick_rate: u32 = 120;
pub const tick_duration_seconds: f64 = 1.0 / @as(f64, @floatFromInt(tick_rate));

/// One presentation frame contributes at most 250 ms of simulation time. At
/// 120 Hz this permits at most 30 ticks before excess wall time is discarded.
pub const max_frame_seconds: f64 = 0.25;
pub const max_frame_nanoseconds: u64 = 250_000_000;
pub const max_ticks_per_frame: u32 = tick_rate / 4;

/// Pure fixed-step accumulation policy. Time is stored in fractional simulation
/// ticks, making rational cadences such as 240 Hz and 80 Hz exact relative to
/// the 120 Hz simulation rate without depending on a platform timer.
pub const FixedStepAccumulator = struct {
    tick_phase: f64 = 0.0,

    pub fn init() FixedStepAccumulator {
        return .{};
    }

    /// Add explicit elapsed seconds and return the duration accepted after the
    /// anti-spiral clamp. Negative and non-finite durations are rejected.
    pub fn addElapsedSeconds(
        self: *FixedStepAccumulator,
        elapsed_seconds: f64,
    ) error{InvalidElapsedTime}!f64 {
        if (!std.math.isFinite(elapsed_seconds) or elapsed_seconds < 0.0) {
            return error.InvalidElapsedTime;
        }
        const clamped = @min(elapsed_seconds, max_frame_seconds);
        self.tick_phase += clamped * @as(f64, @floatFromInt(tick_rate));
        return clamped;
    }

    /// Add explicit elapsed nanoseconds and return the accepted duration in
    /// seconds. Clamping before conversion keeps very large inputs precise.
    pub fn addElapsedNanoseconds(
        self: *FixedStepAccumulator,
        elapsed_nanoseconds: u64,
    ) f64 {
        const clamped_nanoseconds = @min(
            elapsed_nanoseconds,
            max_frame_nanoseconds,
        );
        const clamped_seconds = @as(f64, @floatFromInt(clamped_nanoseconds)) /
            @as(f64, @floatFromInt(std.time.ns_per_s));
        self.tick_phase += clamped_seconds * @as(f64, @floatFromInt(tick_rate));
        return clamped_seconds;
    }

    /// Consume one available fixed tick. Call until this returns false before
    /// using `alpha` for presentation interpolation.
    pub fn consumeTick(self: *FixedStepAccumulator) bool {
        if (self.tick_phase < 1.0) return false;
        self.tick_phase -= 1.0;
        return true;
    }

    /// Interpolation phase remaining after all available ticks are consumed.
    pub fn alpha(self: *const FixedStepAccumulator) f32 {
        return @floatCast(@min(self.tick_phase, 1.0));
    }

    pub fn accumulatedSeconds(self: *const FixedStepAccumulator) f64 {
        return self.tick_phase * tick_duration_seconds;
    }
};

test "240 Hz presentation produces 240 ticks across 480 frames" {
    var fixed_step = FixedStepAccumulator.init();
    var total_ticks: u32 = 0;
    var zero_tick_frames: u32 = 0;
    var saw_intermediate_alpha = false;

    for (0..480) |_| {
        _ = try fixed_step.addElapsedSeconds(1.0 / 240.0);
        var frame_ticks: u32 = 0;
        while (fixed_step.consumeTick()) {
            frame_ticks += 1;
            total_ticks += 1;
        }
        if (frame_ticks == 0) zero_tick_frames += 1;
        const interpolation = fixed_step.alpha();
        if (interpolation > 0.0 and interpolation < 1.0) {
            saw_intermediate_alpha = true;
        }
    }

    try std.testing.expectEqual(@as(u32, 240), total_ticks);
    try std.testing.expectEqual(@as(u32, 240), zero_tick_frames);
    try std.testing.expect(saw_intermediate_alpha);
    try std.testing.expectEqual(@as(f32, 0.0), fixed_step.alpha());
}

test "80 Hz presentation produces one- and two-tick frames" {
    var fixed_step = FixedStepAccumulator.init();
    var total_ticks: u32 = 0;
    var one_tick_frames: u32 = 0;
    var two_tick_frames: u32 = 0;
    var saw_intermediate_alpha = false;

    for (0..160) |_| {
        _ = try fixed_step.addElapsedSeconds(1.0 / 80.0);
        var frame_ticks: u32 = 0;
        while (fixed_step.consumeTick()) {
            frame_ticks += 1;
            total_ticks += 1;
        }
        if (frame_ticks == 1) one_tick_frames += 1;
        if (frame_ticks == 2) two_tick_frames += 1;
        const interpolation = fixed_step.alpha();
        if (interpolation > 0.0 and interpolation < 1.0) {
            saw_intermediate_alpha = true;
        }
    }

    try std.testing.expectEqual(@as(u32, 240), total_ticks);
    try std.testing.expectEqual(@as(u32, 80), one_tick_frames);
    try std.testing.expectEqual(@as(u32, 80), two_tick_frames);
    try std.testing.expect(saw_intermediate_alpha);
    try std.testing.expectEqual(@as(f32, 0.0), fixed_step.alpha());
}

test "long frame is clamped to 30 fixed ticks" {
    var fixed_step = FixedStepAccumulator.init();
    const accepted_seconds = fixed_step.addElapsedNanoseconds(2 * std.time.ns_per_s);
    var ticks: u32 = 0;
    while (fixed_step.consumeTick()) ticks += 1;

    try std.testing.expectEqual(max_ticks_per_frame, ticks);
    try std.testing.expectEqual(max_frame_seconds, accepted_seconds);
    try std.testing.expectEqual(@as(f32, 0.0), fixed_step.alpha());
}
