//! Read-only NR0 input inspection plus explicit presentation toggle request.

const zgui = @import("zgui");
const engine = @import("incinerator_engine");
const tool = @import("../tool.zig");

pub const descriptor = tool.Descriptor{
    .id = .neural_rendering_lab,
    .name = "Neural Rendering Lab",
    .enabled_by_default = true,
};

pub fn draw(input: *const tool.NeuralInput) void {
    zgui.setNextWindowPos(.{ .x = 220, .y = 40, .cond = .first_use_ever });
    zgui.setNextWindowSize(.{ .w = 910, .h = 760, .cond = .first_use_ever });
    if (zgui.begin("Neural Rendering Lab", .{})) {
        const view = input.view;
        if (!view.available) {
            zgui.textWrapped(
                "NR0 inputs are inactive. Start with INCINERATOR_NR_LAB=1 or an external capture root.",
                .{},
            );
        } else {
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
                "Legacy NR-0001 model loaded={} enabled={} predictions={d} inference={d:.3} ms",
                .{
                    view.model_loaded,
                    view.model_enabled,
                    view.model_predictions,
                    view.model_inference_ms,
                },
            );
            zgui.beginDisabled(.{ .disabled = !view.model_loaded });
            if (zgui.button(if (view.model_enabled)
                "Use conventional presentation"
            else
                "Use legacy neural presentation", .{}))
            {
                input.requests.toggleModel();
            }
            zgui.endDisabled();
            zgui.separator();

            for (view.textures) |texture_view| {
                zgui.text("{s}  {d}x{d}", .{
                    engine.neural_rendering.channelName(texture_view.channel),
                    texture_view.width,
                    texture_view.height,
                });
                const texture_ref = zgui.TextureRef{
                    .tex_data = null,
                    .tex_id = @enumFromInt(@intFromPtr(texture_view.binding)),
                };
                zgui.image(texture_ref, .{ .w = 400, .h = 225 });
            }
        }
    }
    zgui.end();
}
