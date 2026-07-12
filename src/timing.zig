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

// Use shared SDL bindings to avoid opaque type conflicts
const c = sdl.c;

/// The fixed simulation tick rate (120 Hz = 8.333... ms per tick)
/// This determines how often physics and gameplay logic update.
/// Higher values = lower latency but more CPU usage.
pub const TICK_RATE = fixed_step.tick_rate;

/// Duration of one simulation tick in seconds
pub const TICK_DURATION = fixed_step.tick_duration_seconds;
pub const FixedStepAccumulator = fixed_step.FixedStepAccumulator;

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

    /// Delta time for this frame in seconds after the anti-spiral clamp.
    delta_time: f64,

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
            .fixed_step = FixedStepAccumulator.init(),
            .ticks_this_frame = 0,
            .total_ticks = 0,
            .total_frames = 0,
            .fps = 0.0,
        };
    }

    /// Call at the start of each frame. Updates delta time and accumulator.
    pub fn beginFrame(self: *FrameTimer) void {
        self.previous_frame_start = self.frame_start;
        self.frame_start = c.SDL_GetPerformanceCounter();

        // Calculate raw elapsed time, then apply the shared fixed-step clamp.
        const elapsed_ticks = self.frame_start - self.previous_frame_start;
        const raw_dt = @as(f64, @floatFromInt(elapsed_ticks)) /
            @as(f64, @floatFromInt(self.frequency));
        self.beginFrameWithElapsedSeconds(raw_dt) catch unreachable;
    }

    /// Reset the host-clock baseline without advancing simulation time.
    /// Window suspension uses this after waiting so time spent minimized does
    /// not become a large catch-up frame when presentation resumes.
    pub fn resyncClock(self: *FrameTimer) void {
        const now = c.SDL_GetPerformanceCounter();
        self.frame_start = now;
        self.previous_frame_start = now;
        self.delta_time = 0;
        self.ticks_this_frame = 0;
    }

    /// Feed an explicit frame duration through the same production cadence
    /// policy. Visual smoke tests use this to exercise render rates without
    /// coupling expected tick counts to host scheduling noise.
    pub fn beginFrameWithElapsedSeconds(
        self: *FrameTimer,
        elapsed_seconds: f64,
    ) error{InvalidElapsedTime}!void {
        const dt = try self.fixed_step.addElapsedSeconds(elapsed_seconds);

        self.delta_time = dt;
        self.ticks_this_frame = 0;
        self.total_frames += 1;

        // Update FPS with exponential moving average (smoothing factor 0.1)
        const instant_fps = if (dt > 0) 1.0 / dt else 0.0;
        self.fps = self.fps * 0.9 + instant_fps * 0.1;
    }

    /// Returns true if there's enough accumulated time for another simulation tick.
    /// Call this in a while loop to process all pending ticks.
    pub fn shouldTick(self: *FrameTimer) bool {
        if (self.fixed_step.consumeTick()) {
            self.ticks_this_frame += 1;
            self.total_ticks += 1;
            return true;
        }
        return false;
    }

    /// Returns the interpolation factor (0.0 to 1.0) for smooth rendering.
    /// Use this to blend between the previous and current simulation states.
    ///
    /// Example: render_pos = lerp(prev_pos, curr_pos, timer.alpha())
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

    /// Get delta time as f32 (common for game math)
    pub fn getDeltaTimeF32(self: *const FrameTimer) f32 {
        return @floatCast(self.delta_time);
    }

    /// Debug: Print timing stats to stderr
    pub fn debugPrint(self: *const FrameTimer) void {
        std.debug.print(
            "Frame {d}: FPS={d:.1}, dt={d:.3}ms, ticks={d}, accumulator={d:.3}ms\n",
            .{
                self.total_frames,
                self.fps,
                self.delta_time * 1000.0,
                self.ticks_this_frame,
                self.fixed_step.accumulatedSeconds() * 1000.0,
            },
        );
    }
};

// ============================================================================
// Utility functions for time conversion
// ============================================================================

/// Convert seconds to milliseconds
pub fn secondsToMs(seconds: f64) f64 {
    return seconds * 1000.0;
}

/// Convert milliseconds to seconds
pub fn msToSeconds(ms: f64) f64 {
    return ms / 1000.0;
}

/// Linear interpolation helper
pub fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

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
    try std.testing.expectEqual(@as(u32, 0), timer.ticks_this_frame);
}

test "TICK_DURATION calculation" {
    // 120 Hz should be approximately 8.333ms
    try std.testing.expectApproxEqAbs(TICK_DURATION, 0.008333, 0.001);
}

test "lerp function" {
    try std.testing.expectApproxEqAbs(lerp(0.0, 10.0, 0.5), 5.0, 0.001);
    try std.testing.expectApproxEqAbs(lerp(0.0, 10.0, 0.0), 0.0, 0.001);
    try std.testing.expectApproxEqAbs(lerp(0.0, 10.0, 1.0), 10.0, 0.001);
}
