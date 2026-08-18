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
    .name = "Render Lab",
    .category = .rendering,
    .default_region = .right,
    .purpose = "Inspect the deterministic render contract, scene light, draw paths, and last semantic material while changing presentation-only settings.",
    .reads = "An immutable conventional RenderView plus the renderer-owned RenderSettings value borrowed for this frame.",
    .requests = "Mutates only borrowed presentation settings; never gameplay authority.",
    .examples = &.{ "mode=sdl_gpu_metal_deterministic", "visual_schema=1", "lit_product_draws=104", "last_surface=painted_metal" },
    .audit_fields = &.{ "presentation_frame", "render_mode", "visual_schema", "semantic", "part", "ordinal", "surface" },
};

// ============================================================================
// Draw Function
// ============================================================================

pub fn draw(render_settings: *RenderSettings, input: *const tool_module.RenderInput) void {
    if (zgui.begin("Render Lab", .{
        .flags = .{
            .no_collapse = false,
        },
    })) {
        drawContract(input.view);
        zgui.spacing();
        drawSettingsUI(render_settings);
    }
    zgui.end();
}

fn drawContract(view: *const tool_module.RenderView) void {
    zgui.text("Conventional deterministic path", .{});
    zgui.separator();
    zgui.text("mode: {s}", .{view.mode});
    zgui.text("visual schema: {d}", .{view.visual_schema});
    zgui.text(
        "sun direction: ({d:.3}, {d:.3}, {d:.3})",
        .{ view.scene_light.sun_direction[0], view.scene_light.sun_direction[1], view.scene_light.sun_direction[2] },
    );
    zgui.text(
        "sun: ({d:.2}, {d:.2}, {d:.2}) x {d:.2}",
        .{ view.scene_light.sun_color[0], view.scene_light.sun_color[1], view.scene_light.sun_color[2], view.scene_light.sun_intensity },
    );
    zgui.text(
        "ambient: ({d:.2}, {d:.2}, {d:.2})",
        .{ view.scene_light.ambient_color[0], view.scene_light.ambient_color[1], view.scene_light.ambient_color[2] },
    );
    zgui.spacing();
    zgui.text(
        "draws: lit {d}, unlit {d}, debug {d}",
        .{ view.frame_stats.lit_product_draws, view.frame_stats.unlit_product_draws, view.frame_stats.debug_draws },
    );
    zgui.text(
        "geometry: normal {d}, color {d}",
        .{ view.frame_stats.normal_geometry_draws, view.frame_stats.color_geometry_draws },
    );
    zgui.spacing();
    zgui.text("last semantic: {s}/{s} ordinal {d}", .{
        view.last_semantic,
        view.last_part,
        view.last_ordinal,
    });
    zgui.text("last surface: {s}", .{view.last_surface});
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
