//! Human-test incident capture controls and recorder health.
//!
//! This tool owns only editor-local selection and note draft state. All
//! capture, filesystem, replay, screenshot, and clipboard work remains behind
//! the developer-host request/view boundary.

const std = @import("std");
const zgui = @import("zgui");
const tool_module = @import("../tool.zig");
const incident = @import("../../engine/incident.zig");

pub const descriptor = tool_module.Descriptor{
    .id = .incident_capture,
    .name = "Incident Capture",
    .category = .diagnostics,
    .default_region = .bottom,
    .purpose = "Flag anomalies, annotate evidence, inspect recorder health, and prepare an LLM handoff.",
    .reads = "Immutable incident run health, anomaly lifecycle, paths, and evidence capability matrix.",
    .requests = "Emits bounded flag, save-note, handoff, clipboard, and folder requests.",
    .examples = &.{ "anomaly=6 status=complete", "run=~/Library/Logs/Incinerator/runs/..." },
    .audit_fields = &.{ "wall_unix_ms", "authority_tick", "presentation_frame", "anomaly_id" },
};

pub const State = struct {
    selected_anomaly: ?incident.AnomalyId = null,
    anomaly_note: [incident.max_note_bytes:0]u8 = @splat(0),
};

/// Always-visible confirmation for shortcut flags. This is status only; all
/// controls remain in the dedicated Incident Capture tool window.
pub fn drawProductStatus(ctx: *const tool_module.IncidentInput) void {
    const view = ctx.view;
    const anomalies = view.anomalySlice();
    if (!view.health.enabled or anomalies.len == 0) return;
    const latest = anomalies[anomalies.len - 1];

    zgui.setNextWindowPos(.{ .x = 300, .y = 10, .cond = .always });
    zgui.setNextWindowBgAlpha(.{ .alpha = 0.78 });
    if (zgui.begin("##incident_product_status", .{
        .flags = .{
            .no_title_bar = true,
            .no_resize = true,
            .no_move = true,
            .no_collapse = true,
            .always_auto_resize = true,
            .no_saved_settings = true,
            .no_focus_on_appearing = true,
        },
    })) {
        zgui.textColored(
            if (latest.status == .capturing)
                .{ 1, 0.75, 0.15, 1 }
            else if (latest.status == .partial)
                .{ 1, 0.3, 0.2, 1 }
            else
                .{ 0.25, 0.95, 0.35, 1 },
            "INCIDENT #{d} {s}",
            .{ latest.id, @tagName(latest.status) },
        );
        if (view.status_len != 0) zgui.text("{s}", .{view.statusText()});
    }
    zgui.end();
}

fn request(ctx: *const tool_module.IncidentInput, value: incident.Request) void {
    _ = ctx.requests.push(value);
}

pub fn draw(state: *State, ctx: *const tool_module.IncidentInput) void {
    if (zgui.begin("Incident Capture", .{})) {
        const view = ctx.view;
        if (!view.health.enabled) {
            zgui.textDisabled("Disabled for this build/run", .{});
            zgui.end();
            return;
        }

        zgui.textWrapped("Run: {s}", .{view.runPath()});
        zgui.textColored(
            if (view.health.writer_failed)
                .{ 1, 0.25, 0.2, 1 }
            else if (view.health.visual_budget_exhausted)
                .{ 1, 0.75, 0.15, 1 }
            else
                .{ 0.25, 0.9, 0.35, 1 },
            "writer ready={} failed={} queue={d} peak={d} dropped={d} images-missed={d}",
            .{
                view.health.writer_ready,
                view.health.writer_failed,
                view.health.queued,
                view.health.queue_high_water,
                view.health.dropped_records,
                view.health.screenshot_misses,
            },
        );
        zgui.textDisabled(
            "visual budget={d}/{d} rejected={d} handoff-persisted={}",
            .{
                view.health.visual_bytes_reserved,
                view.health.visual_budget_bytes,
                view.health.visual_budget_rejections,
                view.health.handoff_persisted,
            },
        );
        if (view.status_len != 0) zgui.textWrapped("{s}", .{view.statusText()});

        zgui.separatorText("Capture controls");
        zgui.text("Shortcut: Cmd+Option+I", .{});
        zgui.textDisabled("Optional: F9 / Fn+F9 or Cmd+Shift+9", .{});
        zgui.text(
            "shortcut received={d} matched={d} queued={d} applied={d}",
            .{
                view.shortcuts.received,
                view.shortcuts.matched,
                view.shortcuts.queued,
                view.shortcuts.applied,
            },
        );
        if (view.shortcuts.received != 0) {
            zgui.textDisabled(
                "last window={d} scancode={d} keycode={d} raw={d} mods=0x{x} focused={} matched={}",
                .{
                    view.shortcuts.last_window_id,
                    view.shortcuts.last_scancode,
                    view.shortcuts.last_keycode,
                    view.shortcuts.last_raw,
                    view.shortcuts.last_modifiers,
                    view.shortcuts.last_focused,
                    view.shortcuts.last_matched,
                },
            );
        }
        if (zgui.button("Flag anomaly", .{})) request(ctx, .flag);
        zgui.sameLine(.{});
        if (zgui.button("Open run folder", .{})) request(ctx, .open_run_folder);

        zgui.separatorText("Flagged anomalies");
        const anomalies = view.anomalySlice();
        if (anomalies.len == 0) {
            zgui.text("No anomalies flagged", .{});
            zgui.end();
            return;
        }
        if (state.selected_anomaly == null) {
            selectAnomaly(state, &anomalies[anomalies.len - 1]);
        }
        for (anomalies) |anomaly| {
            var label: [96]u8 = undefined;
            const text = std.fmt.bufPrintZ(
                &label,
                "#{d} tick={d} frame={d} {s}##incident-{d}",
                .{
                    anomaly.id,
                    anomaly.authority_tick,
                    anomaly.presentation_frame,
                    @tagName(anomaly.status),
                    anomaly.id,
                },
            ) catch continue;
            if (zgui.selectable(text, .{
                .selected = state.selected_anomaly == anomaly.id,
            })) selectAnomaly(state, &anomaly);
        }

        const selected_id = state.selected_anomaly orelse {
            zgui.end();
            return;
        };
        var selected: ?incident.AnomalyView = null;
        for (anomalies) |anomaly| {
            if (anomaly.id == selected_id) {
                selected = anomaly;
                break;
            }
        }
        if (selected) |anomaly| {
            zgui.textWrapped(
                "Persisted note: {s}",
                .{if (anomaly.noteSlice().len == 0) "(empty)" else anomaly.noteSlice()},
            );
        }
        _ = zgui.inputText("Note", .{ .buf = &state.anomaly_note });
        if (zgui.button("Save anomaly note", .{})) {
            request(ctx, .{ .save_note = noteUpdate(state, selected_id) });
        }
        zgui.sameLine(.{});
        if (zgui.button("Save note + Copy for LLM", .{})) {
            request(ctx, .{ .save_note_and_copy = noteUpdate(state, selected_id) });
        }
    }
    zgui.end();
}

fn noteUpdate(state: *const State, id: incident.AnomalyId) incident.NoteUpdate {
    var result = incident.NoteUpdate{ .id = id, .note = @splat(0), .note_len = 0 };
    const text = std.mem.sliceTo(&state.anomaly_note, 0);
    @memcpy(result.note[0..text.len], text);
    result.note_len = @intCast(text.len);
    return result;
}

fn selectAnomaly(state: *State, anomaly: *const incident.AnomalyView) void {
    state.selected_anomaly = anomaly.id;
    @memset(&state.anomaly_note, 0);
    const note = anomaly.noteSlice();
    @memcpy(state.anomaly_note[0..note.len], note);
}

test "selecting an anomaly copies its bounded note into editor-owned draft state" {
    var anomaly = incident.AnomalyView{
        .id = 7,
        .authority_tick = 10,
        .presentation_frame = 20,
        .wall_unix_ms = 30,
        .status = .complete,
    };
    const note = "vehicle wheels stopped";
    @memcpy(anomaly.note[0..note.len], note);
    anomaly.note_len = note.len;
    var state = State{};
    selectAnomaly(&state, &anomaly);
    try std.testing.expectEqual(@as(?incident.AnomalyId, 7), state.selected_anomaly);
    try std.testing.expectEqualStrings(note, std.mem.sliceTo(&state.anomaly_note, 0));
}

test "note and copy request snapshots the current editor draft" {
    var state = State{};
    const note = "vehicle omitted before district transfer";
    @memcpy(state.anomaly_note[0..note.len], note);
    const update = noteUpdate(&state, 9);
    try std.testing.expectEqual(@as(incident.AnomalyId, 9), update.id);
    try std.testing.expectEqualStrings(note, update.note[0..update.note_len]);
}
