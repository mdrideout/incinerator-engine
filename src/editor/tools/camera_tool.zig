//! camera_tool.zig - Camera Inspector Tool
//!
//! DOMAIN: Editor Layer (Tool)
//!
//! This tool provides a real-time inspector for the game camera, displaying:
//! - Position (X, Y, Z coordinates in world space)
//! - Orientation (Yaw and Pitch in both radians and degrees)
//! - Projection settings (FOV, near/far planes)
//! - Movement parameters (speed, sensitivity)
//!
//! Why is this useful?
//! ------------------
//! 1. Debugging: "Where is my camera?" is the first question when things look wrong
//! 2. Learning: Watch how values change as you move - builds 3D math intuition
//! 3. Tuning: Adjust FOV, speed, sensitivity without recompiling
//! 4. Verification: Confirm camera is at expected position for screenshots/testing
//!
//! The camera uses a right-handed coordinate system:
//! - +X is right
//! - +Y is up
//! - -Z is forward (into the screen)

const std = @import("std");
const zgui = @import("zgui");
const tool_module = @import("../tool.zig");

const Tool = tool_module.Tool;
const EditorContext = tool_module.EditorContext;

// ============================================================================
// Tool Definition
// ============================================================================
// Every tool needs a public `tool` variable that gets registered in editor.zig.
// This is the "plugin" pattern - the tool defines itself, the editor just
// collects and iterates over all registered tools.

/// The Camera tool instance.
/// Starts disabled (false) since it's more specialized than Stats.
/// Users can enable it from the Tools menu when needed.
pub var tool = Tool{
    .name = "Camera", // Window title and menu item name
    .enabled = false, // Start hidden - enable from Tools menu
    .draw_fn = draw, // Function pointer to our draw implementation
    .shortcut = null, // Could assign F4 or similar
};

// ============================================================================
// Helper Functions
// ============================================================================

/// Convert radians to degrees for human-readable display.
/// Most people think in degrees: 90° is a right angle, 360° is a full turn.
/// But internally we use radians because trig functions expect them.
fn radiansToDegrees(radians: f32) f32 {
    return radians * (180.0 / std.math.pi);
}

// ============================================================================
// Draw Function
// ============================================================================
// This is called every frame when the tool is enabled.
// It receives the EditorContext which contains a pointer to the camera.
//
// ImGui is an "immediate mode" GUI - you call functions every frame to draw
// widgets, and they return true if the user interacted with them. There's no
// retained widget tree like in HTML/CSS or traditional GUI frameworks.

fn draw(ctx: *EditorContext) void {
    // ========================================================================
    // Window Setup
    // ========================================================================
    // setNextWindowPos/Size only apply to the NEXT window created.
    // The `cond = .first_use_ever` means these only apply the first time
    // the window is opened - after that, ImGui remembers user's position.

    zgui.setNextWindowPos(.{
        .x = 10,
        .y = 220, // Below the Stats window (which is at y=30, height ~180)
        .cond = .first_use_ever,
    });
    zgui.setNextWindowSize(.{
        .w = 280,
        .h = 300, // Taller than Stats since we have more info
        .cond = .first_use_ever,
    });

    // ========================================================================
    // Begin Window
    // ========================================================================
    // zgui.begin() returns true if the window is not collapsed.
    // We MUST call zgui.end() whether or not begin() returned true!
    // This is a common pattern in ImGui - always match begin/end.

    if (zgui.begin("Camera", .{})) {
        const camera = ctx.camera;

        // ====================================================================
        // Position Section
        // ====================================================================
        // The camera position is a zm.Vec (SIMD f32x4 vector).
        // We extract X, Y, Z components for display.
        // The 4th component (W) is always 1.0 for positions.

        zgui.text("Position", .{});
        zgui.separator();

        // Display each axis on its own line for clarity
        // Format: 2 decimal places is enough precision for most debugging
        zgui.text("  X: {d:.2}", .{camera.position[0]});
        zgui.text("  Y: {d:.2}", .{camera.position[1]});
        zgui.text("  Z: {d:.2}", .{camera.position[2]});

        zgui.spacing(); // Add vertical space between sections

        // ====================================================================
        // Orientation Section
        // ====================================================================
        // Yaw = rotation around Y axis (looking left/right)
        // Pitch = rotation around X axis (looking up/down)
        //
        // We show both radians (what the code uses) and degrees (what humans
        // understand). This is educational - you learn to mentally convert.

        zgui.text("Orientation", .{});
        zgui.separator();

        // Yaw: 0 = looking at -Z, positive = looking right
        const yaw_deg = radiansToDegrees(camera.yaw);
        zgui.text("  Yaw:   {d:.2} rad ({d:.1}\xc2\xb0)", .{ camera.yaw, yaw_deg });

        // Pitch: 0 = level, positive = looking up, negative = looking down
        const pitch_deg = radiansToDegrees(camera.pitch);
        zgui.text("  Pitch: {d:.2} rad ({d:.1}\xc2\xb0)", .{ camera.pitch, pitch_deg });

        zgui.spacing();

        // ====================================================================
        // Projection Section
        // ====================================================================
        // These values define what the camera "sees":
        // - FOV: How wide the view is (larger = more peripheral vision)
        // - Near: Closest distance that renders (too close = clipping)
        // - Far: Farthest distance that renders (too far = precision issues)

        zgui.text("Projection", .{});
        zgui.separator();

        const fov_deg = radiansToDegrees(camera.fov);
        zgui.text("  FOV:  {d:.1}\xc2\xb0", .{fov_deg});
        zgui.text("  Near: {d:.2}", .{camera.near});
        zgui.text("  Far:  {d:.1}", .{camera.far});

        zgui.spacing();

        // ====================================================================
        // Movement Parameters Section
        // ====================================================================
        // These affect how the camera responds to input.
        // Being able to see these helps when tuning feels "off".

        zgui.text("Movement", .{});
        zgui.separator();

        zgui.text("  Speed:       {d:.1} units/sec", .{camera.move_speed});
        zgui.text("  Sensitivity: {d:.4} rad/pixel", .{camera.look_sensitivity});

        zgui.spacing();

        // ====================================================================
        // Direction Vectors (Advanced)
        // ====================================================================
        // Show the computed forward direction - useful for debugging
        // movement or aiming systems. This is derived from yaw/pitch.

        zgui.text("Direction Vectors", .{});
        zgui.separator();

        const forward = camera.getForward();
        zgui.text("  Forward: ({d:.2}, {d:.2}, {d:.2})", .{
            forward[0],
            forward[1],
            forward[2],
        });

        const right = camera.getRight();
        zgui.text("  Right:   ({d:.2}, {d:.2}, {d:.2})", .{
            right[0],
            right[1],
            right[2],
        });
    }
    zgui.end(); // ALWAYS call end(), even if begin() returned false
}
