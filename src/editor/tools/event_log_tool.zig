//! Bottom-wide bounded diagnostic and gameplay event histories.
//!
//! The tool owns no journal storage. It renders borrowed history and emits
//! only the existing typed recording-control requests.

const zgui = @import("zgui");
const tool_module = @import("../tool.zig");
const gameplay_inspector_tool = @import("gameplay_inspector_tool.zig");
const engine = @import("incinerator_engine");
const developer_diagnostics = @import("developer_diagnostics");

const DeveloperInput = tool_module.DeveloperInput;
const GameplayInput = tool_module.GameplayInput;
const EntityRef = engine.gameplay_trace.EntityRef;

pub const descriptor = tool_module.Descriptor{
    .id = .event_log,
    .name = "Event Log",
    .category = .diagnostics,
    .default_region = .bottom,
    .purpose = "Inspect collapsed, bounded engine/runtime and selected-entity gameplay event histories.",
    .reads = "Bounded authority diagnostic journal and bounded gameplay event history.",
    .requests = "Emits bounded diagnostic-journal and gameplay-history recording controls.",
    .examples = &.{ "runtime/stream_content_ready tick=1422", "firearm admitted actor=1:2:1" },
    .audit_fields = &.{ "authority_tick", "presentation_frame", "journal_sequence", "correlation_id" },
};

fn diagnosticRequest(ctx: *const DeveloperInput, value: developer_diagnostics.Request) void {
    _ = ctx.diagnostic_requests.push(value);
}

fn diagnosticCodeLabel(code: engine.diagnostic_contracts.Code) []const u8 {
    const codes = engine.diagnostic_contracts.codes;
    return switch (code) {
        codes.runtime_system_fault => "runtime_system_fault",
        codes.district_load_requested => "district_load_requested",
        codes.district_cancellation_requested => "district_cancellation_requested",
        codes.district_cancelled => "district_cancelled",
        codes.district_load_failed => "district_load_failed",
        codes.district_activated => "district_activated",
        codes.district_unloaded => "district_unloaded",
        codes.district_stream_content_requested => "stream_content_requested",
        codes.district_stream_content_cancel_requested => "stream_content_cancel_requested",
        codes.district_stream_content_cancelled => "stream_content_cancelled",
        codes.district_stream_content_ready => "stream_content_ready",
        codes.district_stream_content_failed => "stream_content_failed",
        codes.district_stream_logical_submitted => "stream_logical_submitted",
        codes.district_stream_logical_cancel_submitted => "stream_logical_cancel_submitted",
        codes.district_stream_logical_unload_submitted => "stream_logical_unload_submitted",
        codes.district_stream_logical_admitted => "stream_logical_admitted",
        codes.district_stream_logical_activated => "stream_logical_activated",
        codes.district_stream_logical_cancelled => "stream_logical_cancelled",
        codes.district_stream_logical_unloaded => "stream_logical_unloaded",
        codes.district_stream_logical_failed => "stream_logical_failed",
        codes.district_stream_gpu_reserved => "stream_gpu_reserved",
        codes.district_stream_gpu_staged => "stream_gpu_staged",
        codes.district_stream_gpu_submitted => "stream_gpu_submitted",
        codes.district_stream_gpu_resident => "stream_gpu_resident",
        codes.district_stream_gpu_release_requested => "stream_gpu_release_requested",
        codes.district_stream_gpu_drained => "stream_gpu_drained",
        else => "custom",
    };
}

fn drawDiagnosticHistory(ctx: *const DeveloperInput) void {
    if (!zgui.collapsingHeader("Diagnostic event log", .{})) return;

    const journal = ctx.snapshot.journal;
    zgui.textWrapped(
        "Structured engine/runtime events used to explain faults and streaming transitions. Recording controls affect this journal only; they do not pause gameplay.",
        .{},
    );
    zgui.text(
        "Recorded {d}/{d} | overwritten {d} | rejected while paused {d} | sequence exhausted {d}",
        .{
            journal.count,
            journal.capacity,
            journal.overwritten,
            journal.rejected_while_frozen,
            journal.rejected_sequence_exhausted,
        },
    );
    zgui.text(
        "Recording {s} | trigger {s} | sequence {s}",
        .{
            if (journal.frozen) "PAUSED" else "ACTIVE",
            if (journal.trigger_armed) "ARMED" else "disarmed",
            if (journal.sequence_exhausted) "EXHAUSTED" else "available",
        },
    );
    if (zgui.button("Arm: next entry", .{})) {
        diagnosticRequest(ctx, .{ .arm_freeze = .{} });
    }
    zgui.sameLine(.{});
    if (zgui.button("Arm: runtime fault", .{})) {
        diagnosticRequest(ctx, .{ .arm_freeze = .{
            .severity = .fatal,
            .category = .runtime,
            .code = engine.diagnostic_contracts.codes.runtime_system_fault,
        } });
    }
    if (zgui.button("Disarm trigger", .{})) diagnosticRequest(ctx, .disarm_freeze);
    zgui.sameLine(.{});
    if (zgui.button("Resume journal recording", .{})) diagnosticRequest(ctx, .resume_capture);
    zgui.sameLine(.{});
    if (zgui.button("Clear journal", .{})) diagnosticRequest(ctx, .clear);
    zgui.sameLine(.{});
    if (zgui.button("Export JSON", .{})) diagnosticRequest(ctx, .export_json);

    if (zgui.beginChild("##diagnostic_journal_entries", .{
        .h = 180,
        .child_flags = .{ .frame_style = true },
    })) {
        for (0..ctx.journal.len()) |index| {
            const entry = ctx.journal.at(index).?;
            zgui.text(
                "#{d} [{s}/{s}] {s} (0x{x}) tick={?d} correlation={d}",
                .{
                    entry.sequence,
                    @tagName(entry.severity),
                    @tagName(entry.category),
                    diagnosticCodeLabel(entry.code),
                    entry.code,
                    entry.tick_index,
                    entry.correlation_id,
                },
            );
        }
        if (ctx.journal.len() == 0) {
            zgui.textDisabled("No diagnostic entries recorded.", .{});
        }
    }
    zgui.endChild();
}

pub fn draw(
    developer: *const DeveloperInput,
    gameplay: *const GameplayInput,
    selected_entity: ?EntityRef,
) void {
    if (zgui.begin("Event Log", .{})) {
        zgui.textWrapped(
            "These are bounded diagnostic histories, not gameplay modes. Both entry lists start collapsed and scroll inside this bottom-wide panel when opened.",
            .{},
        );
        drawDiagnosticHistory(developer);
        gameplay_inspector_tool.drawEventHistory(gameplay, selected_entity);
    }
    zgui.end();
}
