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

const zgui = @import("zgui");
const tool_module = @import("../tool.zig");
const renderer_module = @import("../../renderer.zig");

const RenderSettings = renderer_module.RenderSettings;

// ============================================================================
// Tool Definition
// ============================================================================

/// Immutable metadata registered by editor.zig.
pub const descriptor = tool_module.Descriptor{
    .id = .render,
    .name = "Render",
    .enabled_by_default = true,
};

// ============================================================================
// Draw Function
// ============================================================================

pub fn draw(render_settings: *RenderSettings) void {
    // Set initial window position and size
    zgui.setNextWindowPos(.{ .x = 10, .y = 450, .cond = .first_use_ever });
    zgui.setNextWindowSize(.{ .w = 200, .h = 120, .cond = .first_use_ever });

    if (zgui.begin("Render", .{
        .flags = .{
            .no_collapse = false,
        },
    })) {
        drawSettingsUI(render_settings);
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
