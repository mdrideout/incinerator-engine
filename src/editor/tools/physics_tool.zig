//! physics_tool.zig - Physics Debug Visualization Tool
//!
//! DOMAIN: Editor Layer (Tool)
//!
//! Provides controls for physics debug rendering including:
//! - Master toggle (F4 hotkey)
//! - Collision shape visualization
//! - Wireframe vs solid rendering
//! - Bounding boxes, velocity vectors, center of mass
//!
//! This tool allows developers to visualize the physics simulation
//! to debug collision issues, see invisible geometry, and understand
//! why objects behave unexpectedly.

const std = @import("std");
const zgui = @import("zgui");
const tool_module = @import("../tool.zig");
const physics_debug = @import("../../physics_debug.zig");

const Tool = tool_module.Tool;
const EditorContext = tool_module.EditorContext;
const DebugDrawSettings = physics_debug.DebugDrawSettings;

// ============================================================================
// Tool Definition
// ============================================================================

/// The Physics Debug tool instance.
/// This is what gets registered in editor.zig's tool array.
pub var tool = Tool{
    .name = "Physics Debug",
    .enabled = true,
    .draw_fn = draw,
};

// ============================================================================
// Settings Reference
// ============================================================================

/// Pointer to the PhysicsDebugRenderer's settings.
/// Set via setDebugSettings() from main.zig during initialization.
var debug_settings: ?*DebugDrawSettings = null;

/// Wire up the debug settings reference from the PhysicsDebugRenderer.
/// Call this from main.zig after initializing the physics debug renderer.
pub fn setDebugSettings(settings: *DebugDrawSettings) void {
    debug_settings = settings;
}

/// Toggle debug rendering on/off. Called by editor.zig for F4 hotkey.
pub fn toggleEnabled() void {
    if (debug_settings) |settings| {
        settings.enabled = !settings.enabled;
    }
}

/// Check if debug rendering is currently enabled.
pub fn isEnabled() bool {
    if (debug_settings) |settings| {
        return settings.enabled;
    }
    return false;
}

// ============================================================================
// Draw Function
// ============================================================================

fn draw(ctx: *EditorContext) void {
    _ = ctx;

    // Set initial window position and size
    zgui.setNextWindowPos(.{ .x = 10, .y = 220, .cond = .first_use_ever });
    zgui.setNextWindowSize(.{ .w = 250, .h = 220, .cond = .first_use_ever });

    if (zgui.begin("Physics Debug", .{
        .flags = .{
            .no_collapse = false,
        },
    })) {
        if (debug_settings) |settings| {
            drawSettingsUI(settings);
        } else {
            zgui.textColored(.{ 0.8, 0.3, 0.3, 1.0 }, "Not initialized", .{});
            zgui.textWrapped("Physics debug renderer not connected. Check main.zig initialization.", .{});
        }
    }
    zgui.end();
}

fn drawSettingsUI(settings: *DebugDrawSettings) void {
    // Master toggle with hotkey hint
    _ = zgui.checkbox("Enabled (F4)", .{ .v = &settings.enabled });

    if (!settings.enabled) {
        zgui.beginDisabled(.{});
    }

    zgui.separator();
    zgui.text("Working Options", .{});

    // AABB visualization - the main working feature
    _ = zgui.checkbox("AABBs (Bounding Boxes)", .{ .v = &settings.draw_bounding_boxes });
    zgui.textColored(.{ 0.6, 0.6, 0.6, 1.0 }, "  Axis-aligned, expand on rotation", .{});

    _ = zgui.checkbox("Velocity Vectors", .{ .v = &settings.draw_velocity });
    _ = zgui.checkbox("Center of Mass", .{ .v = &settings.draw_center_of_mass });
    _ = zgui.checkbox("World Transform", .{ .v = &settings.draw_world_transform });

    // Collision shapes (now working!)
    zgui.separator();
    zgui.text("Collision Shapes", .{});
    _ = zgui.checkbox("Shapes", .{ .v = &settings.draw_shapes });
    zgui.indent(.{ .indent_w = 20.0 });
    _ = zgui.checkbox("Wireframe", .{ .v = &settings.wireframe });
    zgui.unindent(.{ .indent_w = 20.0 });
    zgui.textColored(.{ 0.6, 0.6, 0.6, 1.0 }, "  Shows actual collision geometry", .{});

    if (!settings.enabled) {
        zgui.endDisabled();
    }

    // Show status
    zgui.separator();
    if (settings.enabled) {
        zgui.textColored(.{ 0.0, 1.0, 0.0, 1.0 }, "Debug rendering active", .{});
    } else {
        zgui.textColored(.{ 0.5, 0.5, 0.5, 1.0 }, "Press F4 to enable", .{});
    }
}
