//! Optional S5 crate-authoring editor extension.
//!
//! This module renders immutable host-neutral values and appends semantic
//! requests to a fixed mailbox. It deliberately has no Simulation, ECS,
//! physics-adapter, renderer, storage, or filesystem import.

const std = @import("std");
const zgui = @import("zgui");
const engine = @import("incinerator_engine");
const sandbox_authoring = @import("sandbox_authoring");
const tool_module = @import("../tool.zig");

const AuthoringInput = tool_module.AuthoringInput;

pub const descriptor = tool_module.Descriptor{
    .id = .crate_authoring,
    .name = "Crate Authoring",
    .category = .authoring,
    .default_region = .right,
    .purpose = "Relocate the selected persistent crate and commit the authoritative sandbox save slot.",
    .reads = "Immutable crate authoring session, selection, feedback, and save projection.",
    .requests = "Emits typed begin/apply/cancel/undo/redo/save requests through the authoring boundary.",
    .examples = &.{ "crate=1:4 revision=7", "save=committed slot=sandbox" },
    .audit_fields = &.{ "authority_tick", "persistent_id", "transaction_id", "authoring_revision" },
};

pub const State = struct {
    id: ?engine.PersistentId = null,
    position: [3]f32 = .{ 0, 0, 0 },
    dirty: bool = false,
    observed_feedback_sequence: u64 = 0,

    fn reset(self: *State) void {
        self.* = .{};
    }

    fn synchronize(
        self: *State,
        view: *const tool_module.CrateAuthoringView,
    ) void {
        const selected = coherentSelection(view) orelse {
            self.reset();
            self.observed_feedback_sequence = view.feedback.sequence;
            return;
        };

        if (self.id == null or !std.meta.eql(self.id.?, selected.id)) {
            self.* = .{
                .id = selected.id,
                .position = selected.state.pose.position,
                .observed_feedback_sequence = view.feedback.sequence,
            };
            return;
        }

        if (view.feedback.sequence != self.observed_feedback_sequence) {
            self.observed_feedback_sequence = view.feedback.sequence;
            if (view.feedback.id) |feedback_id| {
                if (std.meta.eql(feedback_id, selected.id)) {
                    switch (view.feedback.status) {
                        .applied => self.dirty = false,
                        .none, .rejected, .submission_failed => {},
                    }
                }
            }
        }

        // A clean draft follows ordinary physics publication every frame. A
        // dirty draft remains stable while the dynamic crate keeps simulating.
        if (!self.dirty) self.position = selected.state.pose.position;
    }
};

fn coherentSelection(
    view: *const tool_module.CrateAuthoringView,
) ?tool_module.AuthoringCrateView {
    const selected_id = view.session.selected orelse return null;
    const selected = view.selected_crate orelse return null;
    if (!std.meta.eql(selected_id, selected.id)) return null;
    return selected;
}

fn push(ctx: *const AuthoringInput, request: sandbox_authoring.Request) bool {
    return ctx.requests.push(request);
}

fn drawIdentity(label: []const u8, id: engine.PersistentId) void {
    zgui.text(
        "{s}: namespace={d}, local={d}",
        .{ label, id.namespace, id.local },
    );
}

fn drawOperationFeedback(feedback: tool_module.AuthoringFeedback) void {
    zgui.separatorText("Last authority result");
    if (feedback.sequence == 0 or feedback.status == .none) {
        zgui.text("No authoring result yet", .{});
        return;
    }

    const color: [4]f32 = switch (feedback.status) {
        .applied => .{ 0.25, 0.9, 0.35, 1 },
        .rejected, .submission_failed => .{ 1, 0.35, 0.25, 1 },
        .none => .{ 0.7, 0.7, 0.7, 1 },
    };
    zgui.textColored(
        color,
        "#{d}: {s}",
        .{ feedback.sequence, @tagName(feedback.status) },
    );
    if (feedback.operation) |operation| {
        zgui.text("Operation: {s}", .{@tagName(operation)});
    }
    if (feedback.transaction_id) |transaction_id| {
        zgui.text("Transaction: {d}", .{transaction_id});
    }
    if (feedback.id) |id| drawIdentity("Crate", id);
    if (feedback.rejection_reason) |reason| {
        zgui.text("Reason: {s}", .{@tagName(reason)});
    }
    if (feedback.detail.len != 0) zgui.textWrapped("{s}", .{feedback.detail});
}

fn drawChangeEvidence(evidence: ?sandbox_authoring.ChangeEvidence) void {
    zgui.separatorText("Authored-change evidence");
    const value = evidence orelse {
        zgui.text("No authored transaction recorded yet", .{});
        return;
    };
    zgui.text(
        "Run: {d}:{d}",
        .{
            value.record.run_id.started_wall_unix_ms,
            value.record.run_id.nonce,
        },
    );
    zgui.text(
        "Source/scope: {s}/{s}",
        .{
            @tagName(value.record.request.source),
            @tagName(value.record.request.scope),
        },
    );
    zgui.text(
        "Transaction/revision: {d} expected {d} committed {?d}",
        .{
            value.record.request.transaction_id,
            value.record.request.expected_revision,
            value.record.committed_revision,
        },
    );
    zgui.text(
        "Time: wall {d} ms, tick {?d}, frame {?d}",
        .{
            value.record.wall_unix_ms,
            value.record.authority_tick,
            value.record.presentation_frame,
        },
    );
    zgui.text("Disposition: {s}", .{@tagName(value.record.disposition)});
    if (value.record.rejection) |rejection| switch (rejection) {
        .common => |common| zgui.text("Rejection: {s}", .{@tagName(common)}),
        .owner => |owner| zgui.text(
            "Rejection: owner {d}:{d}",
            .{ owner.domain, owner.code },
        ),
    };
    if (value.before) |before| zgui.text(
        "Before: ({d:.3}, {d:.3}, {d:.3})",
        .{
            before.pose.position[0],
            before.pose.position[1],
            before.pose.position[2],
        },
    );
    zgui.text(
        "Requested: ({d:.3}, {d:.3}, {d:.3})",
        .{
            value.requested.target_pose.position[0],
            value.requested.target_pose.position[1],
            value.requested.target_pose.position[2],
        },
    );
    if (value.committed) |committed| zgui.text(
        "Committed: ({d:.3}, {d:.3}, {d:.3})",
        .{
            committed.pose.position[0],
            committed.pose.position[1],
            committed.pose.position[2],
        },
    );
}

fn drawSaveFeedback(feedback: tool_module.SaveFeedback) void {
    zgui.separatorText("Durable save");
    const color: [4]f32 = switch (feedback.status) {
        .committed => .{ 0.25, 0.9, 0.35, 1 },
        .committed_sync_warning => .{ 1, 0.75, 0.2, 1 },
        .not_committed => .{ 1, 0.35, 0.25, 1 },
        .unavailable, .idle, .queued, .committing => .{ 0.75, 0.75, 0.75, 1 },
    };
    zgui.textColored(
        color,
        "Save: {s} (result #{d})",
        .{ @tagName(feedback.status), feedback.sequence },
    );
    if (feedback.slot_label.len != 0) {
        zgui.text("Slot: {s}", .{feedback.slot_label});
    }
    if (feedback.detail.len != 0) zgui.textWrapped("{s}", .{feedback.detail});
}

pub fn draw(state: *State, ctx: *const AuthoringInput) void {
    const view = ctx.view;
    state.synchronize(view);

    if (zgui.begin("Crate Authoring", .{})) {
        const session = view.session;
        var request_emitted = false;

        if (session.pending) |pending| {
            zgui.textColored(.{ 1, 0.75, 0.2, 1 }, "Authority operation pending", .{});
            zgui.text(
                "{s} transaction {d}",
                .{ @tagName(pending.kind), pending.transaction_id },
            );
            drawIdentity("Pending crate", pending.id);
        } else {
            zgui.textColored(.{ 0.25, 0.9, 0.35, 1 }, "Authority idle", .{});
        }

        zgui.text(
            "History: undo {d}, redo {d}, capacity {d}",
            .{ session.undo_count, session.redo_count, session.history_capacity },
        );
        zgui.text(
            "Loss: capacity {d}, stale history {d}, operations rejected {d}, selections invalidated {d}",
            .{
                session.dropped_history,
                session.invalidated_history,
                session.rejected_operations,
                session.invalidated_selections,
            },
        );
        zgui.text(
            "UI mailbox rejections: {d}",
            .{@max(view.request_rejections, ctx.requests.rejected)},
        );

        zgui.separatorText("Selection");
        const selected = coherentSelection(view);
        if (selected) |crate| {
            drawIdentity("Selected crate", crate.id);
            zgui.text("Authoring revision: {d}", .{crate.authoring_revision});
            zgui.text(
                "Published position: ({d:.3}, {d:.3}, {d:.3})",
                .{
                    crate.state.pose.position[0],
                    crate.state.pose.position[1],
                    crate.state.pose.position[2],
                },
            );

            const pending = session.pending != null;
            zgui.beginDisabled(.{ .disabled = pending });
            if (zgui.inputFloat3("Draft position", .{
                .v = &state.position,
                .cfmt = "%.3f",
            })) {
                state.dirty = true;
            }
            if (zgui.button("Revert draft", .{})) {
                state.position = crate.state.pose.position;
                state.dirty = false;
            }
            zgui.sameLine(.{});
            if (zgui.button("Clear selection", .{})) {
                request_emitted = push(ctx, .clear_selection);
            }
            zgui.endDisabled();

            if (state.dirty) {
                zgui.textColored(
                    .{ 1, 0.75, 0.2, 1 },
                    "Draft modified; natural physics refresh is paused",
                    .{},
                );
            } else {
                zgui.text("Draft follows natural physics publication", .{});
            }

            zgui.beginDisabled(.{ .disabled = pending or request_emitted or !state.dirty });
            if (zgui.button("Apply position", .{})) {
                request_emitted = push(ctx, .{ .relocate = .{
                    .id = crate.id,
                    .target_pose = .{
                        .position = state.position,
                        .rotation = crate.state.pose.rotation,
                    },
                    .velocity = .zero,
                } });
            }
            zgui.endDisabled();

            zgui.sameLine(.{});
            zgui.beginDisabled(.{
                .disabled = pending or request_emitted or state.dirty or !session.canUndo(),
            });
            if (zgui.button("Undo", .{})) request_emitted = push(ctx, .undo);
            zgui.endDisabled();

            zgui.sameLine(.{});
            zgui.beginDisabled(.{
                .disabled = pending or request_emitted or state.dirty or !session.canRedo(),
            });
            if (zgui.button("Redo", .{})) request_emitted = push(ctx, .redo);
            zgui.endDisabled();
        } else if (session.selected) |stale_id| {
            zgui.textColored(
                .{ 1, 0.35, 0.25, 1 },
                "Selected crate is unavailable or view is incoherent",
                .{},
            );
            drawIdentity("Stale selection", stale_id);
            zgui.beginDisabled(.{ .disabled = session.pending != null });
            if (zgui.button("Clear stale selection", .{})) {
                request_emitted = push(ctx, .clear_selection);
            }
            zgui.endDisabled();
        } else if (view.available_crate) |crate| {
            drawIdentity("Available crate", crate.id);
            zgui.text(
                "Position: ({d:.3}, {d:.3}, {d:.3})",
                .{
                    crate.state.pose.position[0],
                    crate.state.pose.position[1],
                    crate.state.pose.position[2],
                },
            );
            zgui.beginDisabled(.{ .disabled = session.pending != null });
            if (zgui.button("Select crate", .{})) {
                request_emitted = push(ctx, .{ .select = crate.id });
            }
            zgui.endDisabled();
        } else {
            zgui.text("No crate is currently available", .{});
        }

        drawOperationFeedback(view.feedback);
        drawChangeEvidence(view.latest_change);
        drawSaveFeedback(view.save);

        const save_busy = switch (view.save.status) {
            .queued, .committing => true,
            else => false,
        };
        zgui.beginDisabled(.{
            .disabled = session.pending != null or
                request_emitted or
                state.dirty or
                save_busy or
                view.save.status == .unavailable,
        });
        if (zgui.button("Save authoritative world", .{})) {
            _ = push(ctx, .save);
        }
        zgui.endDisabled();
    }
    zgui.end();
}

fn testSession(selected: ?engine.PersistentId) sandbox_authoring.Snapshot {
    return .{
        .selected = selected,
        .pending = null,
        .undo_count = 0,
        .redo_count = 0,
        .history_capacity = 64,
        .dropped_history = 0,
        .rejected_operations = 0,
        .invalidated_selections = 0,
    };
}

test "clean authoring draft follows physics while dirty draft remains stable" {
    const id = engine.PersistentId{ .namespace = 9, .local = 3 };
    var view = tool_module.CrateAuthoringView{
        .session = testSession(id),
        .selected_crate = .{
            .id = id,
            .state = .{ .pose = .{ .position = .{ 1, 2, 3 } } },
            .authoring_revision = 0,
        },
    };
    var state = State{};
    state.synchronize(&view);
    try std.testing.expectEqual([3]f32{ 1, 2, 3 }, state.position);

    view.selected_crate.?.state.pose.position = .{ 4, 5, 6 };
    state.synchronize(&view);
    try std.testing.expectEqual([3]f32{ 4, 5, 6 }, state.position);

    state.position = .{ 20, 21, 22 };
    state.dirty = true;
    view.selected_crate.?.state.pose.position = .{ 7, 8, 9 };
    state.synchronize(&view);
    try std.testing.expectEqual([3]f32{ 20, 21, 22 }, state.position);
    try std.testing.expect(state.dirty);
}

test "correlated applied feedback refreshes draft and rejection preserves it" {
    const id = engine.PersistentId{ .namespace = 11, .local = 8 };
    var view = tool_module.CrateAuthoringView{
        .session = testSession(id),
        .selected_crate = .{
            .id = id,
            .state = .{ .pose = .{ .position = .{ 1, 1, 1 } } },
            .authoring_revision = 0,
        },
    };
    var state = State{};
    state.synchronize(&view);
    state.position = .{ 9, 9, 9 };
    state.dirty = true;

    view.feedback = .{
        .sequence = 1,
        .status = .rejected,
        .operation = .edit,
        .transaction_id = 4,
        .id = id,
        .detail = "state_conflict",
    };
    state.synchronize(&view);
    try std.testing.expect(state.dirty);
    try std.testing.expectEqual([3]f32{ 9, 9, 9 }, state.position);

    view.selected_crate.?.state.pose.position = .{ 5, 6, 7 };
    view.feedback = .{
        .sequence = 2,
        .status = .applied,
        .operation = .edit,
        .transaction_id = 5,
        .id = id,
    };
    state.synchronize(&view);
    try std.testing.expect(!state.dirty);
    try std.testing.expectEqual([3]f32{ 5, 6, 7 }, state.position);
}

test "incoherent immutable selection cannot produce a draft target" {
    const selected_id = engine.PersistentId{ .namespace = 2, .local = 4 };
    const different_id = engine.PersistentId{ .namespace = 2, .local = 5 };
    const view = tool_module.CrateAuthoringView{
        .session = testSession(selected_id),
        .selected_crate = .{
            .id = different_id,
            .state = .{},
            .authoring_revision = 0,
        },
    };
    var state = State{
        .id = selected_id,
        .position = .{ 9, 9, 9 },
        .dirty = true,
    };
    state.synchronize(&view);
    try std.testing.expectEqual(@as(?engine.PersistentId, null), state.id);
    try std.testing.expect(!state.dirty);
}
