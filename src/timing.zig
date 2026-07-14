//! timing.zig - High-precision frame timing for the canonical game loop
//!
//! This module adapts SDL3 performance counters to the platform-independent
//! fixed-step accumulation policy used for simulation and interpolation.
//!
//! Key concepts:
//! - `delta_time`: Clamped time since last frame (for FPS calculations)
//! - `accumulator`: Builds up time for fixed-rate simulation ticks
//! - `alpha`: Interpolation factor for smooth rendering between ticks

const std = @import("std");
const sdl = @import("sdl.zig");
const fixed_step = @import("incinerator_engine").fixed_step;
const developer_controls = @import("developer_controls");

// Use shared SDL bindings to avoid opaque type conflicts
const c = sdl.c;

/// Graphical embedded-authority rate (60 Hz = 16.666... ms per tick).
/// Presentation cadence is independent of this simulation contract.
pub const TICK_RATE = fixed_step.tick_rate;

/// Duration of one simulation tick in seconds
pub const TICK_DURATION = fixed_step.tick_duration_seconds;
pub const FixedStepAccumulator = fixed_step.FixedStepAccumulator;
pub const ClockPolicy = developer_controls.ClockPolicy;
pub const TimeScale = developer_controls.TimeScale;

/// FrameTimer handles all timing for the game loop.
///
/// Usage:
/// ```zig
/// var timer = FrameTimer.init();
/// while (running) {
///     timer.beginFrame();
///
///     // Fixed timestep simulation
///     while (timer.shouldTick()) {
///         simulate(TICK_DURATION);
///         timer.recordCompletedTick();
///     }
///
///     // Render with interpolation
///     render(timer.alpha());
/// }
/// ```
pub const FrameTimer = struct {
    /// SDL performance counter frequency (ticks per second)
    frequency: u64,

    /// Counter value at the start of the current frame
    frame_start: u64,

    /// Counter value at the start of the previous frame
    previous_frame_start: u64,

    /// Raw presentation delta for this frame after the anti-spiral clamp.
    delta_time: f64,

    /// Wall-time contribution granted to the fixed-step accumulator after the
    /// host pause/time-scale policy and anti-spiral clamp are applied.
    simulation_delta_time: f64,

    /// Pure fixed-step policy fed by the SDL clock adapter.
    fixed_step: FixedStepAccumulator,

    /// Number of simulation ticks this frame (for debugging)
    ticks_this_frame: u32,

    /// Total simulation ticks since start (for debugging)
    total_ticks: u64,

    /// Total frames rendered since start
    total_frames: u64,

    /// Running average FPS (exponential moving average)
    fps: f64,

    /// Initialize the frame timer. Call once at startup.
    pub fn init() FrameTimer {
        const freq = c.SDL_GetPerformanceFrequency();
        const now = c.SDL_GetPerformanceCounter();

        return FrameTimer{
            .frequency = freq,
            .frame_start = now,
            .previous_frame_start = now,
            .delta_time = 0.0,
            .simulation_delta_time = 0.0,
            .fixed_step = FixedStepAccumulator.init(),
            .ticks_this_frame = 0,
            .total_ticks = 0,
            .total_frames = 0,
            .fps = 0.0,
        };
    }

    /// Call at the start of each frame. Updates delta time and accumulator.
    pub fn beginFrame(self: *FrameTimer) void {
        self.beginControlledFrame(.{ .running = .normal });
    }

    /// Sample the platform clock while applying ephemeral host execution
    /// policy. Paused frames continue to update presentation timing but add no
    /// simulation time. A scale changes only accumulator contribution; it
    /// never changes the fixed delta passed to a simulation tick.
    pub fn beginControlledFrame(self: *FrameTimer, policy: ClockPolicy) void {
        self.previous_frame_start = self.frame_start;
        self.frame_start = c.SDL_GetPerformanceCounter();

        // Calculate raw elapsed time, then apply the shared presentation and
        // simulation clamps independently.
        const elapsed_ticks = self.frame_start - self.previous_frame_start;
        const raw_dt = @as(f64, @floatFromInt(elapsed_ticks)) /
            @as(f64, @floatFromInt(self.frequency));
        self.beginControlledFrameWithElapsedSeconds(raw_dt, policy) catch unreachable;
    }

    /// Reset the host-clock baseline without advancing simulation time.
    /// Window suspension uses this after waiting so time spent minimized does
    /// not become a large catch-up frame when presentation resumes.
    pub fn resyncClock(self: *FrameTimer) void {
        const now = c.SDL_GetPerformanceCounter();
        self.frame_start = now;
        self.previous_frame_start = now;
        self.delta_time = 0;
        self.simulation_delta_time = 0;
        self.ticks_this_frame = 0;
    }

    /// Feed an explicit frame duration through the same production cadence
    /// policy. Visual smoke tests use this to exercise render rates without
    /// coupling expected tick counts to host scheduling noise.
    pub fn beginFrameWithElapsedSeconds(
        self: *FrameTimer,
        elapsed_seconds: f64,
    ) error{InvalidElapsedTime}!void {
        try self.beginControlledFrameWithElapsedSeconds(
            elapsed_seconds,
            .{ .running = .normal },
        );
    }

    /// Feed explicit raw presentation time through the same controlled policy
    /// as `beginControlledFrame`. This is the deterministic seam used by host
    /// cadence tests and visual smokes.
    pub fn beginControlledFrameWithElapsedSeconds(
        self: *FrameTimer,
        elapsed_seconds: f64,
        policy: ClockPolicy,
    ) error{InvalidElapsedTime}!void {
        if (!std.math.isFinite(elapsed_seconds) or elapsed_seconds < 0) {
            return error.InvalidElapsedTime;
        }

        const raw_dt = @min(elapsed_seconds, fixed_step.max_frame_seconds);
        const requested_simulation_dt = switch (policy) {
            .paused => 0,
            .running => |scale| raw_dt * scale.multiplier(),
        };
        // Scaling cannot bypass the existing anti-spiral budget. At double
        // speed the host grants more fixed ticks only while the same per-frame
        // maximum remains respected.
        const simulation_dt = @min(
            requested_simulation_dt,
            fixed_step.max_frame_seconds,
        );
        _ = try self.fixed_step.addElapsedSeconds(simulation_dt);

        self.delta_time = raw_dt;
        self.simulation_delta_time = simulation_dt;
        self.ticks_this_frame = 0;
        self.total_frames += 1;

        // Update FPS with exponential moving average (smoothing factor 0.1)
        const instant_fps = if (raw_dt > 0) 1.0 / raw_dt else 0.0;
        self.fps = self.fps * 0.9 + instant_fps * 0.1;
    }

    /// Consume one accumulated tick opportunity. This deliberately does not
    /// increment completed-tick diagnostics; the host calls
    /// `recordCompletedTick` only after the authoritative tick succeeds.
    pub fn shouldTick(self: *FrameTimer) bool {
        return self.fixed_step.consumeTick();
    }

    /// Account for one successfully completed authoritative tick.
    pub fn recordCompletedTick(self: *FrameTimer) void {
        self.ticks_this_frame += 1;
        self.total_ticks += 1;
    }

    /// Account for one host-granted single step after the caller successfully
    /// executes that fixed tick. This does not add or consume elapsed time, so
    /// interpolation phase and resume cadence are unchanged.
    pub fn recordSingleStep(self: *FrameTimer) void {
        self.recordCompletedTick();
    }

    /// Returns the interpolation factor (0.0 to 1.0) for smooth rendering.
    /// Use this to blend between the previous and current simulation states.
    ///
    /// Presentation uses this value to interpolate previous/current state.
    pub fn alpha(self: *const FrameTimer) f32 {
        return self.fixed_step.alpha();
    }

    /// Get current FPS (smoothed)
    pub fn getFps(self: *const FrameTimer) f64 {
        return self.fps;
    }

    /// Get the clamped delta time for this frame in seconds
    pub fn getDeltaTime(self: *const FrameTimer) f64 {
        return self.delta_time;
    }

    /// Get the post-policy wall-time contribution added to the fixed-step
    /// accumulator for this frame. This is zero while paused.
    pub fn getSimulationDeltaTime(self: *const FrameTimer) f64 {
        return self.simulation_delta_time;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "FrameTimer initialization" {
    var timer = FrameTimer.init();
    try std.testing.expect(timer.frequency > 0);
    try std.testing.expectEqual(@as(f32, 0.0), timer.fixed_step.alpha());
    try std.testing.expect(timer.total_frames == 0);
    timer.resyncClock();
    try std.testing.expectEqual(@as(f64, 0), timer.delta_time);
    try std.testing.expectEqual(@as(f64, 0), timer.simulation_delta_time);
    try std.testing.expectEqual(@as(u32, 0), timer.ticks_this_frame);
}

test "TICK_DURATION calculation" {
    try std.testing.expectEqual(@as(u32, 60), TICK_RATE);
    try std.testing.expectApproxEqAbs(TICK_DURATION, 1.0 / 60.0, 0.000001);
}

test "long pause adds no simulation time and resume has no catch-up burst" {
    var timer = FrameTimer.init();
    for (0..600) |_| {
        try timer.beginControlledFrameWithElapsedSeconds(1.0 / 30.0, .paused);
        try std.testing.expect(!timer.shouldTick());
        try std.testing.expectEqual(@as(f64, 0), timer.getSimulationDeltaTime());
    }
    try std.testing.expectEqual(@as(u64, 0), timer.total_ticks);
    try std.testing.expectEqual(@as(f64, 0), timer.fixed_step.accumulatedSeconds());

    // Resuming at 240 Hz grants only new wall time. Four quarter-tick frames
    // produce one 60 Hz authority tick; paused time is never replayed.
    for (0..3) |_| {
        try timer.beginControlledFrameWithElapsedSeconds(
            1.0 / 240.0,
            .{ .running = .normal },
        );
        try std.testing.expect(!timer.shouldTick());
    }
    try timer.beginControlledFrameWithElapsedSeconds(
        1.0 / 240.0,
        .{ .running = .normal },
    );
    try std.testing.expect(timer.shouldTick());
    timer.recordCompletedTick();
    try std.testing.expect(!timer.shouldTick());
    try std.testing.expectEqual(@as(u64, 1), timer.total_ticks);
}

test "half and double scales change cadence only" {
    const expected_fixed_delta = TICK_DURATION;
    const presentation_hz = 120;
    var half_timer = FrameTimer.init();
    for (0..presentation_hz) |_| {
        try half_timer.beginControlledFrameWithElapsedSeconds(
            1.0 / @as(f64, @floatFromInt(presentation_hz)),
            .{ .running = .half },
        );
        while (half_timer.shouldTick()) half_timer.recordCompletedTick();
    }
    try std.testing.expectEqual(@as(u64, TICK_RATE / 2), half_timer.total_ticks);

    var double_timer = FrameTimer.init();
    for (0..presentation_hz) |_| {
        try double_timer.beginControlledFrameWithElapsedSeconds(
            1.0 / @as(f64, @floatFromInt(presentation_hz)),
            .{ .running = .double },
        );
        while (double_timer.shouldTick()) double_timer.recordCompletedTick();
    }
    try std.testing.expectEqual(@as(u64, TICK_RATE * 2), double_timer.total_ticks);
    // Host cadence policy has no API capable of mutating the authoritative
    // fixed tick duration.
    try std.testing.expectEqual(expected_fixed_delta, TICK_DURATION);
}

test "80 Hz presentation remains independent of 60 Hz authority cadence" {
    var timer = FrameTimer.init();
    var zero_tick_frames: u32 = 0;
    var one_tick_frames: u32 = 0;

    for (0..160) |_| {
        try timer.beginControlledFrameWithElapsedSeconds(
            1.0 / 80.0,
            .{ .running = .normal },
        );
        var frame_ticks: u32 = 0;
        while (timer.shouldTick()) {
            timer.recordCompletedTick();
            frame_ticks += 1;
        }
        if (frame_ticks == 0) zero_tick_frames += 1;
        if (frame_ticks == 1) one_tick_frames += 1;
        try std.testing.expect(frame_ticks <= 1);
    }

    try std.testing.expectEqual(@as(u64, 120), timer.total_ticks);
    try std.testing.expectEqual(@as(u32, 40), zero_tick_frames);
    try std.testing.expectEqual(@as(u32, 120), one_tick_frames);
    try std.testing.expectEqual(@as(f32, 0), timer.alpha());
}

test "single step is counted once without manufacturing elapsed time" {
    var controller = developer_controls.Controller{};
    _ = try controller.apply(.{ .set_paused = true });
    _ = try controller.apply(.single_step);

    var timer = FrameTimer.init();
    try timer.beginControlledFrameWithElapsedSeconds(
        1.0 / 60.0,
        controller.clockPolicy(),
    );
    const phase_before = timer.fixed_step.accumulatedSeconds();
    var granted_ticks: u8 = 0;
    if (controller.takeSingleStep()) {
        // The host calls the real fixed-delta simulation tick here, then
        // accounts for it only after success.
        timer.recordSingleStep();
        granted_ticks += 1;
    }
    if (controller.takeSingleStep()) granted_ticks += 1;

    try std.testing.expectEqual(@as(u8, 1), granted_ticks);
    try std.testing.expectEqual(@as(u64, 1), timer.total_ticks);
    try std.testing.expectEqual(@as(u32, 1), timer.ticks_this_frame);
    try std.testing.expectEqual(phase_before, timer.fixed_step.accumulatedSeconds());
    try std.testing.expect(!timer.shouldTick());
}

test "a consumed tick opportunity is counted only after authoritative success" {
    var timer = FrameTimer.init();
    try timer.beginControlledFrameWithElapsedSeconds(
        TICK_DURATION,
        .{ .running = .normal },
    );
    try std.testing.expect(timer.shouldTick());

    // Model a failed simulation call by intentionally omitting the completion
    // record. Diagnostics must not describe the attempted tick as completed.
    try std.testing.expectEqual(@as(u64, 0), timer.total_ticks);
    try std.testing.expectEqual(@as(u32, 0), timer.ticks_this_frame);
    try std.testing.expect(!timer.shouldTick());

    timer.recordCompletedTick();
    try std.testing.expectEqual(@as(u64, 1), timer.total_ticks);
    try std.testing.expectEqual(@as(u32, 1), timer.ticks_this_frame);
}

test "controlled frames reject invalid raw elapsed time even while paused" {
    var timer = FrameTimer.init();
    try std.testing.expectError(
        error.InvalidElapsedTime,
        timer.beginControlledFrameWithElapsedSeconds(-1, .paused),
    );
    try std.testing.expectError(
        error.InvalidElapsedTime,
        timer.beginControlledFrameWithElapsedSeconds(std.math.nan(f64), .paused),
    );
    try std.testing.expectEqual(@as(u64, 0), timer.total_frames);
    try std.testing.expectEqual(@as(f64, 0), timer.fixed_step.accumulatedSeconds());
}
