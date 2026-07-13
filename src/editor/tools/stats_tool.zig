//! stats_tool.zig - Performance Statistics Tool
//!
//! DOMAIN: Editor Layer (Tool)
//!
//! Displays real-time performance metrics including:
//! - Frames per second (FPS)
//! - Frame time in milliseconds
//! - Simulation tick rate
//! - Memory usage (future)
//!
//! This is typically the first tool you want when developing - it tells you
//! immediately if something is wrong with performance.

const std = @import("std");
const zgui = @import("zgui");
const tool_module = @import("../tool.zig");
const FrameTimer = @import("../../timing.zig").FrameTimer;

// ============================================================================
// Tool Definition
// ============================================================================

/// Immutable metadata registered by editor.zig.
pub const descriptor = tool_module.Descriptor{
    .id = .stats,
    .name = "Stats",
    .enabled_by_default = true,
};

// ============================================================================
// Frame Time History (for graph)
// ============================================================================

const HISTORY_SIZE = 120; // ~1 second at 120 FPS
pub const State = struct {
    frame_time_history: [HISTORY_SIZE]f32 = [_]f32{0.0} ** HISTORY_SIZE,
    history_index: usize = 0,
};

// ============================================================================
// Draw Function
// ============================================================================

pub fn draw(state: *State, frame_timer: *const FrameTimer) void {
    // Set initial window size and position (first time only)
    // The struct fields include the condition for when to apply
    zgui.setNextWindowPos(.{ .x = 10, .y = 30, .cond = .first_use_ever });
    zgui.setNextWindowSize(.{ .w = 280, .h = 180, .cond = .first_use_ever });

    // Begin window - the "Stats" title matches our tool name
    if (zgui.begin("Stats", .{
        .flags = .{
            .no_collapse = false, // Allow collapsing
        },
    })) {
        const timer = frame_timer;

        // Current FPS (large, prominent)
        const fps = timer.getFps();
        zgui.text("FPS: ", .{});
        zgui.sameLine(.{});

        // Color-code FPS: green = good, yellow = warning, red = bad
        const fps_color: [4]f32 = if (fps >= 60.0)
            .{ 0.0, 1.0, 0.0, 1.0 } // Green
        else if (fps >= 30.0)
            .{ 1.0, 1.0, 0.0, 1.0 } // Yellow
        else
            .{ 1.0, 0.0, 0.0, 1.0 }; // Red

        zgui.textColored(fps_color, "{d:.1}", .{fps});

        // Frame time
        const frame_time_ms = timer.getDeltaTime() * 1000.0;
        zgui.text("Frame time: {d:.2} ms", .{frame_time_ms});

        // Update frame time history for graph
        state.frame_time_history[state.history_index] = @floatCast(frame_time_ms);
        state.history_index = (state.history_index + 1) % HISTORY_SIZE;

        // Simulation info
        zgui.separator();
        zgui.text("Sim ticks/frame: {d}", .{timer.ticks_this_frame});
        zgui.text("Total frames: {d}", .{timer.total_frames});

        // Frame time graph
        zgui.separator();
        zgui.text("Frame Time History:", .{});

        // Plot the frame time history
        // The graph automatically scrolls as we update values
        zgui.plotLines("##frame_times", .{
            .v = &state.frame_time_history,
            .v_count = @intCast(HISTORY_SIZE),
            .scale_min = 0.0,
            .scale_max = 33.3, // Cap at ~30 FPS equivalent
            .graph_size = .{ 0, 50 }, // 0 width = use available, 50 height
        });

        // Target line explanation
        zgui.textColored(.{ 0.5, 0.5, 0.5, 1.0 }, "Target: 8.33ms (120 FPS)", .{});
    }
    zgui.end();
}
