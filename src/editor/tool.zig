//! tool.zig - Editor Tool Interface
//!
//! DOMAIN: Editor Layer
//!
//! Defines the interface that all editor tools must implement. Tools are
//! self-contained UI panels/windows that provide debugging, inspection,
//! or manipulation capabilities.
//!
//! Design Philosophy:
//! - Tools are composable: each tool is independent and focused
//! - Tools are toggleable: can be enabled/disabled at runtime
//! - Tools share context: read from EditorContext for engine state
//! - Tools are explicit: manually registered, not auto-discovered
//!
//! Example Usage:
//!     const my_tool = Tool{
//!         .name = "My Tool",
//!         .draw_fn = myDrawFunction,
//!     };
//!
//!     fn myDrawFunction(ctx: *EditorContext) void {
//!         if (zgui.begin("My Tool", .{})) {
//!             zgui.text("Hello from my tool!");
//!         }
//!         zgui.end();
//!     }

const std = @import("std");
const zm = @import("zmath");

// Forward declarations for engine types
// These will be the actual types once we wire everything up
const Camera = @import("../camera.zig").Camera;
const World = @import("../world.zig").World;
const FrameTimer = @import("../timing.zig").FrameTimer;

// ============================================================================
// Editor Context
// ============================================================================

/// Shared context passed to all tools during rendering.
/// Contains read-only references to engine systems and mutable editor state.
///
/// This is the "bridge" between the engine and the editor - tools can inspect
/// engine state but modifications go through proper channels.
pub const EditorContext = struct {
    // -------------------------------------------------------------------------
    // Engine References (read-only access to engine state)
    // -------------------------------------------------------------------------

    /// The player/debug camera - tools can read position, rotation, etc.
    camera: *const Camera,

    /// The game world - tools can enumerate entities and inspect transforms
    world: *const World,

    /// Frame timing information - for FPS display, profiling, etc.
    frame_timer: *const FrameTimer,

    // -------------------------------------------------------------------------
    // Editor State (mutable, shared between tools)
    // -------------------------------------------------------------------------

    /// Currently selected entity (if any). Used by inspector, gizmos, etc.
    /// null means nothing is selected.
    selected_entity: ?usize = null,

    /// Current gizmo operation mode
    gizmo_mode: GizmoMode = .translate,

    /// Whether gizmos operate in local or world space
    gizmo_space: GizmoSpace = .world,

    /// Whether the editor wants to capture mouse input (e.g., gizmo is being manipulated)
    /// When true, game should not process mouse input
    wants_mouse: bool = false,

    /// Whether the editor wants to capture keyboard input (e.g., text input active)
    /// When true, game should not process keyboard input
    wants_keyboard: bool = false,
};

/// Transform gizmo operation mode
pub const GizmoMode = enum {
    translate,
    rotate,
    scale,
};

/// Transform gizmo coordinate space
pub const GizmoSpace = enum {
    local,
    world,
};

// ============================================================================
// Tool Interface
// ============================================================================

/// A Tool is a self-contained editor panel/window.
///
/// Tools are defined as data + function pointer rather than a vtable interface
/// because:
/// 1. Simpler - no need for allocations or dynamic dispatch overhead
/// 2. Composable - tools are just data, easy to store in arrays
/// 3. Zig-idiomatic - follows pattern used in std.Build, etc.
pub const Tool = struct {
    /// Display name shown in window title and tool menu
    /// Must be null-terminated for ImGui compatibility
    name: [:0]const u8,

    /// Whether this tool is currently visible
    /// Tools can be toggled on/off at runtime via the editor menu
    enabled: bool = true,

    /// The draw function - called every frame when enabled.
    /// Should use zgui to render the tool's UI.
    draw_fn: *const fn (ctx: *EditorContext) void,

    /// Optional shortcut key to toggle this tool
    /// Uses SDL scancode values (e.g., SDL_SCANCODE_F1)
    shortcut: ?u32 = null,

    /// Draw this tool if enabled
    pub fn draw(self: *const Tool, ctx: *EditorContext) void {
        if (self.enabled) {
            self.draw_fn(ctx);
        }
    }

    /// Toggle this tool's visibility
    pub fn toggle(self: *Tool) void {
        self.enabled = !self.enabled;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "EditorContext has sensible defaults" {
    // Can't fully test without actual engine references, but we can check defaults
    const mode: GizmoMode = .translate;
    const space: GizmoSpace = .world;
    try std.testing.expect(mode == .translate);
    try std.testing.expect(space == .world);
}

test "Tool toggle works" {
    var tool = Tool{
        .name = "Test Tool",
        .enabled = true,
        .draw_fn = struct {
            fn draw(_: *EditorContext) void {}
        }.draw,
    };

    try std.testing.expect(tool.enabled == true);
    tool.toggle();
    try std.testing.expect(tool.enabled == false);
    tool.toggle();
    try std.testing.expect(tool.enabled == true);
}
