//! render_tool.zig - Render Settings Tool
//!
//! DOMAIN: Editor Layer (Tool)
//!
//! Provides controls for mesh rendering options:
//! - Wireframe mode toggle (show mesh edges)
//! - Texture toggle (show textures or plain white)
//!
//! These toggles help debug mesh geometry, UV mapping,
//! and lighting without textures obscuring the view.

const std = @import("std");
const zgui = @import("zgui");
const tool_module = @import("../tool.zig");
const renderer_module = @import("../../renderer.zig");

const Tool = tool_module.Tool;
const EditorContext = tool_module.EditorContext;
const RenderSettings = renderer_module.RenderSettings;

// ============================================================================
// Tool Definition
// ============================================================================

/// The Render Settings tool instance.
/// This is what gets registered in editor.zig's tool array.
pub var tool = Tool{
    .name = "Render",
    .enabled = true,
    .draw_fn = draw,
};

// ============================================================================
// Settings Reference
// ============================================================================

/// Pointer to the Renderer's settings.
/// Set via setRenderSettings() from main.zig during initialization.
var render_settings: ?*RenderSettings = null;

/// Wire up the render settings reference from the Renderer.
/// Call this from main.zig after initializing the renderer.
pub fn setRenderSettings(settings: *RenderSettings) void {
    render_settings = settings;
}

/// Toggle wireframe mode on/off. Could be wired to a hotkey.
pub fn toggleWireframe() void {
    if (render_settings) |settings| {
        settings.wireframe_mode = !settings.wireframe_mode;
    }
}

/// Toggle texture display on/off. Could be wired to a hotkey.
pub fn toggleTextures() void {
    if (render_settings) |settings| {
        settings.show_textures = !settings.show_textures;
    }
}

// ============================================================================
// Draw Function
// ============================================================================

fn draw(ctx: *EditorContext) void {
    _ = ctx;

    // Set initial window position and size
    zgui.setNextWindowPos(.{ .x = 10, .y = 450, .cond = .first_use_ever });
    zgui.setNextWindowSize(.{ .w = 200, .h = 120, .cond = .first_use_ever });

    if (zgui.begin("Render", .{
        .flags = .{
            .no_collapse = false,
        },
    })) {
        if (render_settings) |settings| {
            drawSettingsUI(settings);
        } else {
            zgui.textColored(.{ 0.8, 0.3, 0.3, 1.0 }, "Not initialized", .{});
            zgui.textWrapped("Renderer not connected. Check main.zig initialization.", .{});
        }
    }
    zgui.end();
}

fn drawSettingsUI(settings: *RenderSettings) void {
    zgui.text("Mesh Rendering", .{});
    zgui.separator();

    // Wireframe mode toggle
    _ = zgui.checkbox("Wireframe Mode", .{ .v = &settings.wireframe_mode });
    zgui.textColored(.{ 0.6, 0.6, 0.6, 1.0 }, "  Show mesh edges only", .{});

    zgui.spacing();

    // Texture toggle
    _ = zgui.checkbox("Show Textures", .{ .v = &settings.show_textures });
    zgui.textColored(.{ 0.6, 0.6, 0.6, 1.0 }, "  Disable for lighting-only view", .{});
}
