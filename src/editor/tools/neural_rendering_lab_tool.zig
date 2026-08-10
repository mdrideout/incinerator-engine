//! Read-only live neural input/output comparison with optional deep diagnostics.

const zgui = @import("zgui");
const engine = @import("incinerator_engine");
const tool = @import("../tool.zig");

pub const descriptor = tool.Descriptor{
    .id = .neural_rendering_lab,
    .name = "Neural Input / Output",
    .enabled_by_default = true,
};

pub fn draw(input: *const tool.NeuralInput) void {
    zgui.setNextWindowPos(.{ .x = 1110, .y = 40, .cond = .first_use_ever });
    zgui.setNextWindowSize(.{ .w = 460, .h = 720, .cond = .first_use_ever });
    if (zgui.begin("Neural Input / Output", .{})) {
        const view = input.view;
        if (!view.available) {
            zgui.textWrapped(
                "Neural inputs are inactive. Start with INCINERATOR_NR_LAB=1 or an external trial/capture root.",
                .{},
            );
        } else {
            drawPrimaryFrames(view);

            zgui.beginDisabled(.{ .disabled = !view.model_loaded });
            if (zgui.button(if (view.model_enabled)
                "Use conventional presentation"
            else
                "Use NR5-E neural presentation", .{}))
            {
                input.requests.toggleModel();
            }
            zgui.endDisabled();
            zgui.separator();

            if (zgui.collapsingHeader("Diagnostics", .{})) {
                drawDiagnostics(view);
            }
            if (zgui.collapsingHeader("Auxiliary neural inputs", .{})) {
                drawAuxiliaryInputs(view);
            }
        }
    }
    zgui.end();
}

fn drawPrimaryFrames(view: *const tool.NeuralView) void {
    const appearance = appearance: for (view.textures) |texture_view| {
        if (texture_view.channel == .appearance) break :appearance texture_view;
    } else null;

    zgui.text("Input frame: deterministic appearance", .{});
    if (appearance) |texture_view| {
        zgui.text("Native resolution: {d} x {d}", .{ texture_view.width, texture_view.height });
        drawTexture(texture_view.binding, texture_view.width, texture_view.height);
    } else {
        zgui.textColored(.{ 1, 0.25, 0.25, 1 }, "Appearance input unavailable", .{});
    }

    zgui.spacing();
    zgui.text("Neural renderer output", .{});
    if (view.model_output) |output| {
        zgui.text("Native resolution: {d} x {d}", .{ output.width, output.height });
        drawTexture(output.binding, output.width, output.height);
        zgui.text(
            "Source frame {d}; presented source frame {d}",
            .{ view.model_last_source_frame, view.model_last_presented_source_frame },
        );
    } else if (!view.model_loaded) {
        zgui.textWrapped("No NR5-E trial model is loaded; the main view remains conventional.", .{});
    } else {
        zgui.textWrapped("The model has not produced a displayable output; the main view remains conventional.", .{});
    }
}

fn drawDiagnostics(view: *const tool.NeuralView) void {
    zgui.text("{s} schema {d}", .{ view.schema_name, view.schema_version });
    zgui.text(
        "tick {d} frame {d} draws {d} history {d}/{d}",
        .{
            view.authority_tick,
            view.presentation_frame,
            view.draw_count,
            view.history_valid_draws,
            view.history_reset_draws,
        },
    );
    zgui.text(
        "frames {d} failures {d} ID collisions {d}",
        .{ view.rendered_frames, view.render_failures, view.compact_id_collisions },
    );
    zgui.textWrapped("schema fingerprint: {s}", .{view.schema_fingerprint});
    zgui.textWrapped("shader fingerprint: {s}", .{view.shader_fingerprint});
    zgui.text(
        "global controls: sun {d:.3} world {d:.3} local {d:.3} emissive {d:.3}",
        .{
            view.global_controls.sun_strength,
            view.global_controls.world_strength,
            view.global_controls.local_light_strength,
            view.global_controls.emissive_strength,
        },
    );
    if (view.last_error.len != 0) {
        zgui.textColored(.{ 1, 0.25, 0.25, 1 }, "last error: {s}", .{view.last_error});
    }
    if (view.capture_active) {
        zgui.separator();
        zgui.text(
            "Capture {d}/{d}, failures {d}, cohort {s}",
            .{
                view.capture_recorded_frames,
                view.capture_requested_frames,
                view.capture_failures,
                view.capture_cohort,
            },
        );
        zgui.textWrapped("sequence {s} / camera {s}", .{
            view.capture_sequence,
            view.capture_camera_path,
        });
        zgui.textWrapped("external root: {s}", .{view.capture_root});
    }
    zgui.separator();
    zgui.text(
        "NR5-E trial loaded={} enabled={} output_ready={} readbacks={d} predictions={d} failures={d}",
        .{
            view.model_loaded,
            view.model_enabled,
            view.model_output_ready,
            view.model_readbacks,
            view.model_predictions,
            view.model_failures,
        },
    );
    if (view.model_loaded) {
        zgui.text(
            "source tick/frame {d}/{d}; presented source frame {d}; inference {d:.3} ms; staged mean/max {d:.3}/{d:.3} ms",
            .{
                view.model_last_source_tick,
                view.model_last_source_frame,
                view.model_last_presented_source_frame,
                view.model_inference_ms,
                view.model_pipeline_mean_ms,
                view.model_pipeline_maximum_ms,
            },
        );
        zgui.text(
            "unknown pixels semantic={d} instance={d} (mapped to trained background)",
            .{ view.model_unknown_semantic_pixels, view.model_unknown_instance_pixels },
        );
        zgui.textWrapped("external trial bundle: {s}", .{view.model_bundle_root});
        zgui.textWrapped("checkpoint: {s}", .{view.model_checkpoint_digest});
        zgui.textWrapped("bundle manifest: {s}", .{&view.model_manifest_digest});
    }
}

fn drawAuxiliaryInputs(view: *const tool.NeuralView) void {
    for (view.textures) |texture_view| {
        if (texture_view.channel == .appearance) continue;
        zgui.text("{s}  {d}x{d}", .{
            engine.neural_rendering.channelName(texture_view.channel),
            texture_view.width,
            texture_view.height,
        });
        drawTexture(texture_view.binding, texture_view.width, texture_view.height);
    }
}

fn drawTexture(binding: *const anyopaque, width: u32, height: u32) void {
    const texture_ref = zgui.TextureRef{
        .tex_data = null,
        .tex_id = @enumFromInt(@intFromPtr(binding)),
    };
    zgui.image(texture_ref, .{
        .w = @floatFromInt(width),
        .h = @floatFromInt(height),
    });
}
