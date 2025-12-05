//! timing.zig - High-precision frame timing for the canonical game loop
//!
//! This module provides the timing infrastructure for fixed-timestep simulation
//! with interpolated rendering. It uses SDL3's performance counters for
//! nanosecond-precision timing.
//!
//! Key concepts:
//! - `delta_time`: Raw time since last frame (for FPS calculations)
//! - `accumulator`: Builds up time for fixed-rate simulation ticks
//! - `alpha`: Interpolation factor for smooth rendering between ticks

const std = @import("std");
const sdl = @import("sdl.zig");

// Use shared SDL bindings to avoid opaque type conflicts
const c = sdl.c;

/// The fixed simulation tick rate (120 Hz = 8.333... ms per tick)
/// This determines how often physics and gameplay logic update.
/// Higher values = lower latency but more CPU usage.
pub const TICK_RATE: u32 = 120;

/// Duration of one simulation tick in seconds
pub const TICK_DURATION: f64 = 1.0 / @as(f64, @floatFromInt(TICK_RATE));

/// Maximum frame time to prevent spiral of death.
/// If a frame takes longer than this, we clamp it to avoid
/// the simulation falling further and further behind.
const MAX_FRAME_TIME: f64 = 0.25; // 250ms = 4 FPS minimum

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

    /// Raw delta time for this frame in seconds (unclamped)
    delta_time: f64,

    /// Accumulated time for fixed timestep simulation
    accumulator: f64,

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
            .accumulator = 0.0,
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

        // Calculate raw delta time
        const elapsed_ticks = self.frame_start - self.previous_frame_start;
        var dt = @as(f64, @floatFromInt(elapsed_ticks)) / @as(f64, @floatFromInt(self.frequency));

        // Clamp to prevent spiral of death (e.g., during debugging breakpoints)
        if (dt > MAX_FRAME_TIME) {
            dt = MAX_FRAME_TIME;
        }

        self.delta_time = dt;
        self.accumulator += dt;
        self.ticks_this_frame = 0;
        self.total_frames += 1;

        // Update FPS with exponential moving average (smoothing factor 0.1)
        const instant_fps = if (dt > 0) 1.0 / dt else 0.0;
        self.fps = self.fps * 0.9 + instant_fps * 0.1;
    }

    /// Returns true if there's enough accumulated time for another simulation tick.
    /// Call this in a while loop to process all pending ticks.
    pub fn shouldTick(self: *FrameTimer) bool {
        if (self.accumulator >= TICK_DURATION) {
            self.accumulator -= TICK_DURATION;
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
        return @floatCast(self.accumulator / TICK_DURATION);
    }

    /// Get current FPS (smoothed)
    pub fn getFps(self: *const FrameTimer) f64 {
        return self.fps;
    }

    /// Get the raw delta time for this frame in seconds
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
                self.accumulator * 1000.0,
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
    const timer = FrameTimer.init();
    try std.testing.expect(timer.frequency > 0);
    try std.testing.expect(timer.accumulator == 0.0);
    try std.testing.expect(timer.total_frames == 0);
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
