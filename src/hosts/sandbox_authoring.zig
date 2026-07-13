//! Renderer-neutral S5 crate-authoring session.
//!
//! This owner stores only persistent IDs, immutable change sets, and bounded
//! editor/tool intent. It never owns an ECS entity, physics handle, Simulation
//! pointer, filesystem, or UI object. The composition submits the returned
//! feature command and routes its eventual typed outcome back here.

const std = @import("std");
const engine = @import("incinerator_engine");
const crates = @import("crate_feature");

pub const default_history_capacity: usize = 64;
pub const request_capacity: usize = 16;

pub const ChangeSet = struct {
    id: engine.PersistentId,
    before: engine.physics.BodyState,
    after: engine.physics.BodyState,
    /// Revision to expect before the next inverse/exact application of this
    /// change. Ordinary physics publication does not advance this value.
    expected_revision: u64,
};

pub const OperationKind = enum { edit, undo, redo };

pub const PendingSummary = struct {
    kind: OperationKind,
    transaction_id: u64,
    id: engine.PersistentId,
};

pub const Snapshot = struct {
    selected: ?engine.PersistentId,
    pending: ?PendingSummary,
    undo_count: u16,
    redo_count: u16,
    history_capacity: u16,
    dropped_history: u64,
    invalidated_history: u64 = 0,
    rejected_operations: u64,
    invalidated_selections: u64,

    pub fn canUndo(self: Snapshot) bool {
        return self.pending == null and self.undo_count != 0;
    }

    pub fn canRedo(self: Snapshot) bool {
        return self.pending == null and self.redo_count != 0;
    }
};

pub const RelocateRequest = struct {
    id: engine.PersistentId,
    target_pose: engine.physics.Pose,
    velocity: crates.RelocationVelocity = .zero,
};

/// Fixed UI/tool mailbox. Save is a composition request because this module
/// deliberately owns no filesystem or simulation snapshot capability.
pub const Request = union(enum) {
    select: engine.PersistentId,
    clear_selection,
    relocate: RelocateRequest,
    undo,
    redo,
    save,
};

pub const RequestBuffer = struct {
    items: [request_capacity]Request = undefined,
    len: u8 = 0,
    rejected: u64 = 0,

    pub fn push(self: *RequestBuffer, request: Request) bool {
        if (self.len >= self.items.len) {
            self.rejected +|= 1;
            return false;
        }
        self.items[self.len] = request;
        self.len += 1;
        return true;
    }

    pub fn slice(self: *const RequestBuffer) []const Request {
        return self.items[0..self.len];
    }

    pub fn clear(self: *RequestBuffer) void {
        self.len = 0;
    }
};

pub const ObserveResult = enum { unrelated, applied, rejected };

/// Monotonic transaction source owned by the composition. Sharing one source
/// prevents correlation aliases if a later composition adds multiple
/// producers, but it does not route outcomes by itself. The visual host keeps
/// one relocation producer on this lane; M3 external producers use their
/// separate transaction-to-owner router. Zero is reserved and wraparound
/// fails closed, so an ID is never reused.
pub const TransactionSequencer = struct {
    next_id: u64 = 1,

    pub fn take(self: *TransactionSequencer) !u64 {
        const result = self.next_id;
        if (result == 0) return error.AuthoringTransactionIdExhausted;
        self.next_id +%= 1;
        return result;
    }
};

pub fn Controller(comptime history_capacity: usize) type {
    if (history_capacity == 0 or history_capacity > std.math.maxInt(u16)) {
        @compileError("authoring history capacity must fit a nonzero u16");
    }

    return struct {
        const Self = @This();

        const Pending = struct {
            kind: OperationKind,
            transaction_id: u64,
            id: engine.PersistentId,
            prune_identity_after_outcome: bool = false,
        };

        transactions: *TransactionSequencer,
        selected: ?engine.PersistentId = null,
        pending: ?Pending = null,
        undo: [history_capacity]ChangeSet = undefined,
        undo_len: usize = 0,
        redo: [history_capacity]ChangeSet = undefined,
        redo_len: usize = 0,
        dropped_history: u64 = 0,
        invalidated_history: u64 = 0,
        rejected_operations: u64 = 0,
        invalidated_selections: u64 = 0,

        pub fn init(transactions: *TransactionSequencer) Self {
            return .{ .transactions = transactions };
        }

        pub fn snapshot(self: *const Self) Snapshot {
            return .{
                .selected = self.selected,
                .pending = if (self.pending) |pending| .{
                    .kind = pending.kind,
                    .transaction_id = pending.transaction_id,
                    .id = pending.id,
                } else null,
                .undo_count = @intCast(self.undo_len),
                .redo_count = @intCast(self.redo_len),
                .history_capacity = history_capacity,
                .dropped_history = self.dropped_history,
                .invalidated_history = self.invalidated_history,
                .rejected_operations = self.rejected_operations,
                .invalidated_selections = self.invalidated_selections,
            };
        }

        pub fn select(self: *Self, id: engine.PersistentId) !void {
            try id.validate();
            self.selected = id;
        }

        pub fn clearSelection(self: *Self) void {
            self.selected = null;
        }

        /// Clear a deleted/stale selection and remove its history. If an
        /// operation for that identity is already in flight, pruning waits for
        /// its correlated outcome so stack transitions remain well-defined.
        pub fn invalidateIdentity(self: *Self, id: engine.PersistentId) void {
            if (self.selected != null and std.meta.eql(self.selected.?, id)) {
                self.selected = null;
                self.invalidated_selections +|= 1;
            }
            if (self.pending) |*pending| {
                if (std.meta.eql(pending.id, id)) {
                    pending.prune_identity_after_outcome = true;
                    return;
                }
            }
            self.pruneIdentity(id);
        }

        pub fn beginEdit(
            self: *Self,
            request: RelocateRequest,
            expected_revision: u64,
        ) !crates.Command {
            try self.requireIdle();
            const selected = self.selected orelse return error.NoAuthoringSelection;
            if (!std.meta.eql(selected, request.id)) return error.SelectionMismatch;
            try validateRelocateRequest(request);
            // A current view from another producer may be newer than this
            // controller's retained lineage. Never rebase old private history
            // across that external commit merely because a new edit succeeds.
            if (!self.historyMatchesRevision(request.id, expected_revision)) {
                self.pruneIdentity(request.id);
            }
            return self.begin(.edit, .{
                .transaction_id = try self.transactions.take(),
                .id = request.id,
                .target_pose = request.target_pose,
                .velocity = request.velocity,
                .expected_revision = expected_revision,
            });
        }

        pub fn beginUndo(self: *Self) !crates.Command {
            try self.requireIdle();
            if (self.undo_len == 0) return error.UndoHistoryEmpty;
            const change = self.undo[self.undo_len - 1];
            const transaction_id = try self.transactions.take();
            self.selected = change.id;
            return self.begin(.undo, .{
                .transaction_id = transaction_id,
                .id = change.id,
                .target_pose = change.before.pose,
                .velocity = .{ .exact = change.before.velocity },
                .expected_revision = change.expected_revision,
            });
        }

        pub fn beginRedo(self: *Self) !crates.Command {
            try self.requireIdle();
            if (self.redo_len == 0) return error.RedoHistoryEmpty;
            const change = self.redo[self.redo_len - 1];
            const transaction_id = try self.transactions.take();
            self.selected = change.id;
            return self.begin(.redo, .{
                .transaction_id = transaction_id,
                .id = change.id,
                .target_pose = change.after.pose,
                .velocity = .{ .exact = change.after.velocity },
                .expected_revision = change.expected_revision,
            });
        }

        /// Roll back only the ephemeral pending marker when the composition
        /// could not enqueue the returned feature command. History is untouched.
        pub fn submissionFailed(self: *Self, transaction_id: u64) bool {
            const pending = self.pending orelse return false;
            if (pending.transaction_id != transaction_id) return false;
            self.pending = null;
            return true;
        }

        pub fn observe(self: *Self, outcome: crates.Outcome) !ObserveResult {
            const pending = self.pending orelse return .unrelated;
            switch (outcome) {
                .relocated => |relocated| {
                    if (relocated.transaction_id != pending.transaction_id or
                        !std.meta.eql(relocated.id, pending.id))
                    {
                        return .unrelated;
                    }
                    const change = ChangeSet{
                        .id = relocated.id,
                        .before = try relocated.before.normalized(),
                        .after = try relocated.after.normalized(),
                        .expected_revision = relocated.committed_revision,
                    };
                    switch (pending.kind) {
                        .edit => {
                            self.redo_len = 0;
                            self.pushUndo(change);
                        },
                        .undo => {
                            if (self.undo_len == 0 or
                                !std.meta.eql(self.undo[self.undo_len - 1].id, relocated.id))
                            {
                                return error.AuthoringUndoInvariantBroken;
                            }
                            var original = self.undo[self.undo_len - 1];
                            self.undo_len -= 1;
                            original.expected_revision = relocated.committed_revision;
                            self.redo[self.redo_len] = original;
                            self.redo_len += 1;
                        },
                        .redo => {
                            if (self.redo_len == 0 or
                                !std.meta.eql(self.redo[self.redo_len - 1].id, relocated.id))
                            {
                                return error.AuthoringRedoInvariantBroken;
                            }
                            var original = self.redo[self.redo_len - 1];
                            self.redo_len -= 1;
                            original.expected_revision = relocated.committed_revision;
                            self.pushUndo(original);
                        },
                    }
                    // The authoring revision belongs to the identity, not to a
                    // single history entry. Every retained inverse/forward
                    // change for this crate must expect the newest committed
                    // revision before another multi-level undo or redo.
                    self.refreshIdentityRevision(relocated.id, relocated.committed_revision);
                    self.pending = null;
                    if (pending.prune_identity_after_outcome) self.pruneIdentity(pending.id);
                    return .applied;
                },
                .rejected => |rejected| {
                    if (rejected.command != .relocate or
                        rejected.transaction_id == null or
                        rejected.transaction_id.? != pending.transaction_id or
                        rejected.id == null or !std.meta.eql(rejected.id.?, pending.id))
                    {
                        return .unrelated;
                    }
                    self.pending = null;
                    self.rejected_operations +|= 1;
                    if (rejected.reason == .state_conflict) {
                        self.pruneIdentity(pending.id);
                    }
                    if (pending.prune_identity_after_outcome or
                        rejected.reason == .crate_not_found or rejected.reason == .not_owned)
                    {
                        self.invalidateIdentity(pending.id);
                    }
                    return .rejected;
                },
                else => return .unrelated,
            }
        }

        /// A cold restore starts a new authoring session. Transaction IDs stay
        /// monotonic within the host lifetime, but no selection/history crosses
        /// the process/world boundary.
        pub fn resetForRestore(self: *Self) void {
            self.selected = null;
            self.pending = null;
            self.undo_len = 0;
            self.redo_len = 0;
        }

        fn begin(
            self: *Self,
            kind: OperationKind,
            relocation: crates.RelocateCrate,
        ) crates.Command {
            self.pending = .{
                .kind = kind,
                .transaction_id = relocation.transaction_id,
                .id = relocation.id,
            };
            return .{ .relocate = relocation };
        }

        fn requireIdle(self: *const Self) !void {
            if (self.pending != null) return error.AuthoringOperationPending;
        }

        fn pushUndo(self: *Self, change: ChangeSet) void {
            if (self.undo_len == history_capacity) {
                std.mem.copyForwards(
                    ChangeSet,
                    self.undo[0 .. history_capacity - 1],
                    self.undo[1..history_capacity],
                );
                self.undo_len -= 1;
                self.dropped_history +|= 1;
            }
            self.undo[self.undo_len] = change;
            self.undo_len += 1;
        }

        fn pruneIdentity(self: *Self, id: engine.PersistentId) void {
            const before = self.undo_len + self.redo_len;
            self.undo_len = removeIdentity(self.undo[0..self.undo_len], id);
            self.redo_len = removeIdentity(self.redo[0..self.redo_len], id);
            const removed = before - (self.undo_len + self.redo_len);
            self.invalidated_history +|= removed;
        }

        fn historyMatchesRevision(
            self: *const Self,
            id: engine.PersistentId,
            revision: u64,
        ) bool {
            for (self.undo[0..self.undo_len]) |change| {
                if (std.meta.eql(change.id, id) and
                    change.expected_revision != revision)
                {
                    return false;
                }
            }
            for (self.redo[0..self.redo_len]) |change| {
                if (std.meta.eql(change.id, id) and
                    change.expected_revision != revision)
                {
                    return false;
                }
            }
            return true;
        }

        fn refreshIdentityRevision(self: *Self, id: engine.PersistentId, revision: u64) void {
            for (self.undo[0..self.undo_len]) |*change| {
                if (std.meta.eql(change.id, id)) change.expected_revision = revision;
            }
            for (self.redo[0..self.redo_len]) |*change| {
                if (std.meta.eql(change.id, id)) change.expected_revision = revision;
            }
        }
    };
}

pub const DefaultController = Controller(default_history_capacity);

fn validateRelocateRequest(request: RelocateRequest) !void {
    try request.id.validate();
    _ = try request.target_pose.normalized();
    switch (request.velocity) {
        .preserve, .zero => {},
        .exact => |velocity| try velocity.validate(),
    }
}

fn removeIdentity(items: []ChangeSet, id: engine.PersistentId) usize {
    var write: usize = 0;
    for (items) |item| {
        if (std.meta.eql(item.id, id)) continue;
        items[write] = item;
        write += 1;
    }
    return write;
}

fn testState(x: f32, velocity_x: f32) engine.physics.BodyState {
    return .{
        .pose = .{ .position = .{ x, 2, 0 } },
        .velocity = .{ .linear = .{ velocity_x, 0, 0 } },
    };
}

fn relocatedOutcome(
    command: crates.Command,
    before: engine.physics.BodyState,
    after: engine.physics.BodyState,
    revision: u64,
) crates.Outcome {
    const relocation = command.relocate;
    return .{ .relocated = .{
        .transaction_id = relocation.transaction_id,
        .id = relocation.id,
        .before = before,
        .after = after,
        .committed_revision = revision,
    } };
}

test "edit undo redo use one correlated semantic command and revision chain" {
    const id = engine.PersistentId{ .namespace = 7, .local = 3 };
    var transactions = TransactionSequencer{};
    var controller = Controller(4).init(&transactions);
    try controller.select(id);

    const before = testState(0, 2);
    const after = testState(5, 0);
    const edit = try controller.beginEdit(.{
        .id = id,
        .target_pose = after.pose,
        .velocity = .zero,
    }, 0);
    try std.testing.expect(std.meta.activeTag(edit) == .relocate);
    try std.testing.expectEqual(@as(?u64, 0), edit.relocate.expected_revision);
    try std.testing.expectEqual(ObserveResult.applied, try controller.observe(
        relocatedOutcome(edit, before, after, 1),
    ));
    try std.testing.expectEqual(@as(u16, 1), controller.snapshot().undo_count);

    // Natural physics may have moved the body; undo still conflicts only on
    // the authoring revision and restores the recorded exact state.
    const undo = try controller.beginUndo();
    try std.testing.expectEqual(@as(?u64, 1), undo.relocate.expected_revision);
    try std.testing.expectEqualDeep(before.pose, undo.relocate.target_pose);
    try std.testing.expectEqualDeep(before.velocity, undo.relocate.velocity.exact);
    try std.testing.expectEqual(ObserveResult.applied, try controller.observe(
        relocatedOutcome(undo, testState(5.25, -1), before, 2),
    ));
    try std.testing.expectEqual(@as(u16, 1), controller.snapshot().redo_count);

    const redo = try controller.beginRedo();
    try std.testing.expectEqual(@as(?u64, 2), redo.relocate.expected_revision);
    try std.testing.expectEqualDeep(after.pose, redo.relocate.target_pose);
    try std.testing.expectEqual(ObserveResult.applied, try controller.observe(
        relocatedOutcome(redo, before, after, 3),
    ));
    const snapshot = controller.snapshot();
    try std.testing.expectEqual(@as(u16, 1), snapshot.undo_count);
    try std.testing.expectEqual(@as(u16, 0), snapshot.redo_count);
    try std.testing.expect(snapshot.pending == null);
}

test "multi-level same-crate undo and redo follow the identity revision" {
    const id = engine.PersistentId{ .namespace = 7, .local = 4 };
    var transactions = TransactionSequencer{};
    var controller = Controller(4).init(&transactions);
    try controller.select(id);

    const initial = testState(0, 0);
    const first_state = testState(1, 1);
    const second_state = testState(2, 2);
    const first_edit = try controller.beginEdit(.{
        .id = id,
        .target_pose = first_state.pose,
        .velocity = .{ .exact = first_state.velocity },
    }, 0);
    try std.testing.expectEqual(ObserveResult.applied, try controller.observe(
        relocatedOutcome(first_edit, initial, first_state, 1),
    ));
    const second_edit = try controller.beginEdit(.{
        .id = id,
        .target_pose = second_state.pose,
        .velocity = .{ .exact = second_state.velocity },
    }, 1);
    try std.testing.expectEqual(ObserveResult.applied, try controller.observe(
        relocatedOutcome(second_edit, first_state, second_state, 2),
    ));

    const undo_second = try controller.beginUndo();
    try std.testing.expectEqual(@as(?u64, 2), undo_second.relocate.expected_revision);
    try std.testing.expectEqual(ObserveResult.applied, try controller.observe(
        relocatedOutcome(undo_second, second_state, first_state, 3),
    ));
    const undo_first = try controller.beginUndo();
    try std.testing.expectEqual(@as(?u64, 3), undo_first.relocate.expected_revision);
    try std.testing.expectEqualDeep(initial.pose, undo_first.relocate.target_pose);
    try std.testing.expectEqual(ObserveResult.applied, try controller.observe(
        relocatedOutcome(undo_first, first_state, initial, 4),
    ));

    const redo_first = try controller.beginRedo();
    try std.testing.expectEqual(@as(?u64, 4), redo_first.relocate.expected_revision);
    try std.testing.expectEqualDeep(first_state.pose, redo_first.relocate.target_pose);
    try std.testing.expectEqual(ObserveResult.applied, try controller.observe(
        relocatedOutcome(redo_first, initial, first_state, 5),
    ));
    const redo_second = try controller.beginRedo();
    try std.testing.expectEqual(@as(?u64, 5), redo_second.relocate.expected_revision);
    try std.testing.expectEqualDeep(second_state.pose, redo_second.relocate.target_pose);
    try std.testing.expectEqual(ObserveResult.applied, try controller.observe(
        relocatedOutcome(redo_second, first_state, second_state, 6),
    ));
}

test "interleaved crate history advances revisions only for the affected identity" {
    const first_id = engine.PersistentId{ .namespace = 7, .local = 5 };
    const second_id = engine.PersistentId{ .namespace = 7, .local = 6 };
    var transactions = TransactionSequencer{};
    var controller = Controller(6).init(&transactions);
    const initial = testState(0, 0);
    const first_once = testState(1, 0);
    const first_twice = testState(2, 0);
    const second_once = testState(3, 0);

    try controller.select(first_id);
    const first_edit = try controller.beginEdit(.{
        .id = first_id,
        .target_pose = first_once.pose,
    }, 0);
    _ = try controller.observe(relocatedOutcome(first_edit, initial, first_once, 1));

    try controller.select(second_id);
    const second_edit = try controller.beginEdit(.{
        .id = second_id,
        .target_pose = second_once.pose,
    }, 0);
    _ = try controller.observe(relocatedOutcome(second_edit, initial, second_once, 1));

    try controller.select(first_id);
    const first_edit_again = try controller.beginEdit(.{
        .id = first_id,
        .target_pose = first_twice.pose,
    }, 1);
    _ = try controller.observe(relocatedOutcome(first_edit_again, first_once, first_twice, 2));

    const undo_first_again = try controller.beginUndo();
    try std.testing.expectEqual(@as(?u64, 2), undo_first_again.relocate.expected_revision);
    _ = try controller.observe(relocatedOutcome(undo_first_again, first_twice, first_once, 3));

    const undo_second = try controller.beginUndo();
    try std.testing.expectEqual(second_id, undo_second.relocate.id);
    try std.testing.expectEqual(@as(?u64, 1), undo_second.relocate.expected_revision);
    _ = try controller.observe(relocatedOutcome(undo_second, second_once, initial, 2));

    const undo_first = try controller.beginUndo();
    try std.testing.expectEqual(first_id, undo_first.relocate.id);
    try std.testing.expectEqual(@as(?u64, 3), undo_first.relocate.expected_revision);
    _ = try controller.observe(relocatedOutcome(undo_first, first_once, initial, 4));
}

test "rejection and failed submission preserve history" {
    const id = engine.PersistentId{ .namespace = 8, .local = 1 };
    var transactions = TransactionSequencer{};
    var controller = Controller(2).init(&transactions);
    try controller.select(id);
    const command = try controller.beginEdit(.{
        .id = id,
        .target_pose = testState(1, 0).pose,
    }, 0);
    try std.testing.expect(controller.submissionFailed(command.relocate.transaction_id));
    try std.testing.expectEqual(@as(u16, 0), controller.snapshot().undo_count);

    const retry = try controller.beginEdit(.{
        .id = id,
        .target_pose = testState(1, 0).pose,
    }, 0);
    try std.testing.expectEqual(ObserveResult.rejected, try controller.observe(.{
        .rejected = .{
            .command = .relocate,
            .reason = .state_conflict,
            .transaction_id = retry.relocate.transaction_id,
            .id = id,
            .expected_revision = 0,
            .actual_revision = 1,
        },
    }));
    const snapshot = controller.snapshot();
    try std.testing.expectEqual(@as(u64, 1), snapshot.rejected_operations);
    try std.testing.expectEqual(@as(u16, 0), snapshot.undo_count);
}

test "new edit prunes stale lineage instead of crossing another producer" {
    const id = engine.PersistentId{ .namespace = 8, .local = 2 };
    var transactions = TransactionSequencer{};
    var first = Controller(6).init(&transactions);
    var second = Controller(6).init(&transactions);
    try first.select(id);
    try second.select(id);

    const initial = testState(0, 0);
    const first_state = testState(1, 0);
    const external_state = testState(2, 0);
    const newest_state = testState(3, 0);
    const first_edit = try first.beginEdit(.{
        .id = id,
        .target_pose = first_state.pose,
    }, 0);
    _ = try first.observe(relocatedOutcome(first_edit, initial, first_state, 1));

    const external_edit = try second.beginEdit(.{
        .id = id,
        .target_pose = external_state.pose,
    }, 1);
    _ = try second.observe(relocatedOutcome(external_edit, first_state, external_state, 2));

    // The authoritative view supplies revision 2. Starting a new local edit
    // must discard first's revision-1 lineage before recording revision 3.
    const newest_edit = try first.beginEdit(.{
        .id = id,
        .target_pose = newest_state.pose,
    }, 2);
    try std.testing.expectEqual(@as(u16, 0), first.snapshot().undo_count);
    try std.testing.expectEqual(@as(u64, 1), first.snapshot().invalidated_history);
    _ = try first.observe(relocatedOutcome(newest_edit, external_state, newest_state, 3));

    const undo_newest = try first.beginUndo();
    try std.testing.expectEqualDeep(external_state.pose, undo_newest.relocate.target_pose);
    _ = try first.observe(relocatedOutcome(
        undo_newest,
        newest_state,
        external_state,
        4,
    ));
    try std.testing.expectError(error.UndoHistoryEmpty, first.beginUndo());
}

test "state conflict prunes stale lineage before a later local edit" {
    const id = engine.PersistentId{ .namespace = 8, .local = 3 };
    var transactions = TransactionSequencer{};
    var controller = Controller(6).init(&transactions);
    try controller.select(id);

    const initial = testState(0, 0);
    const local_state = testState(1, 0);
    const external_state = testState(2, 0);
    const newest_state = testState(3, 0);
    const first_edit = try controller.beginEdit(.{
        .id = id,
        .target_pose = local_state.pose,
    }, 0);
    _ = try controller.observe(relocatedOutcome(first_edit, initial, local_state, 1));

    const stale_undo = try controller.beginUndo();
    try std.testing.expectEqual(ObserveResult.rejected, try controller.observe(.{
        .rejected = .{
            .command = .relocate,
            .reason = .state_conflict,
            .transaction_id = stale_undo.relocate.transaction_id,
            .id = id,
            .expected_revision = 1,
            .actual_revision = 2,
        },
    }));
    try std.testing.expectEqual(@as(u16, 0), controller.snapshot().undo_count);
    try std.testing.expectEqual(@as(u16, 0), controller.snapshot().redo_count);
    try std.testing.expectEqual(@as(u64, 1), controller.snapshot().invalidated_history);

    const newest_edit = try controller.beginEdit(.{
        .id = id,
        .target_pose = newest_state.pose,
    }, 2);
    _ = try controller.observe(relocatedOutcome(
        newest_edit,
        external_state,
        newest_state,
        3,
    ));
    const undo_newest = try controller.beginUndo();
    try std.testing.expectEqualDeep(external_state.pose, undo_newest.relocate.target_pose);
    _ = try controller.observe(relocatedOutcome(
        undo_newest,
        newest_state,
        external_state,
        4,
    ));
    try std.testing.expectError(error.UndoHistoryEmpty, controller.beginUndo());
}

test "bounded history evicts oldest and identity invalidation prunes safely" {
    const first = engine.PersistentId{ .namespace = 9, .local = 1 };
    const second = engine.PersistentId{ .namespace = 9, .local = 2 };
    var transactions = TransactionSequencer{};
    var controller = Controller(1).init(&transactions);

    for ([_]engine.PersistentId{ first, second }, 0..) |id, index| {
        try controller.select(id);
        const command = try controller.beginEdit(.{
            .id = id,
            .target_pose = testState(@floatFromInt(index + 1), 0).pose,
        }, 0);
        try std.testing.expectEqual(ObserveResult.applied, try controller.observe(
            relocatedOutcome(command, testState(0, 0), testState(@floatFromInt(index + 1), 0), 1),
        ));
    }
    try std.testing.expectEqual(@as(u64, 1), controller.snapshot().dropped_history);
    controller.invalidateIdentity(second);
    const snapshot = controller.snapshot();
    try std.testing.expect(snapshot.selected == null);
    try std.testing.expectEqual(@as(u16, 0), snapshot.undo_count);
    try std.testing.expectEqual(@as(u64, 1), snapshot.invalidated_selections);
}

test "identity deletion during pending operation defers history pruning" {
    const id = engine.PersistentId{ .namespace = 10, .local = 1 };
    var transactions = TransactionSequencer{};
    var controller = Controller(2).init(&transactions);
    try controller.select(id);
    const command = try controller.beginEdit(.{
        .id = id,
        .target_pose = testState(3, 0).pose,
    }, 0);
    controller.invalidateIdentity(id);
    try std.testing.expect(controller.snapshot().selected == null);
    try std.testing.expectEqual(ObserveResult.applied, try controller.observe(
        relocatedOutcome(command, testState(0, 0), testState(3, 0), 1),
    ));
    try std.testing.expectEqual(@as(u16, 0), controller.snapshot().undo_count);
}

test "shared sequencer prevents aliases but outcome delivery remains owner explicit" {
    const id = engine.PersistentId{ .namespace = 11, .local = 1 };
    var transactions = TransactionSequencer{};
    var first = Controller(2).init(&transactions);
    var second = Controller(2).init(&transactions);
    try first.select(id);
    try second.select(id);

    const initial = testState(0, 0);
    const first_state = testState(1, 0);
    const second_state = testState(2, 0);
    const first_command = try first.beginEdit(.{
        .id = id,
        .target_pose = first_state.pose,
    }, 0);
    const second_command = try second.beginEdit(.{
        .id = id,
        .target_pose = second_state.pose,
    }, 1);
    try std.testing.expect(first_command.relocate.transaction_id != 0);
    try std.testing.expect(second_command.relocate.transaction_id != 0);
    try std.testing.expect(
        first_command.relocate.transaction_id != second_command.relocate.transaction_id,
    );

    // Delivery is deliberately reversed. Both operations target the same
    // identity, so transaction identity is the only safe correlation key.
    const second_outcome = relocatedOutcome(second_command, first_state, second_state, 2);
    try std.testing.expectEqual(ObserveResult.unrelated, try first.observe(second_outcome));
    try std.testing.expectEqual(ObserveResult.applied, try second.observe(second_outcome));
    const first_outcome = relocatedOutcome(first_command, initial, first_state, 1);
    try std.testing.expectEqual(ObserveResult.applied, try first.observe(first_outcome));
    try std.testing.expectEqual(ObserveResult.unrelated, try second.observe(first_outcome));

    try std.testing.expectEqual(@as(u16, 1), first.snapshot().undo_count);
    try std.testing.expectEqual(@as(u16, 1), second.snapshot().undo_count);
}

test "request mailbox is fixed and visibly rejects overflow" {
    var requests = RequestBuffer{};
    for (0..request_capacity) |_| try std.testing.expect(requests.push(.undo));
    try std.testing.expect(!requests.push(.redo));
    try std.testing.expectEqual(@as(u64, 1), requests.rejected);
    try std.testing.expectEqual(request_capacity, requests.slice().len);
    requests.clear();
    try std.testing.expectEqual(@as(usize, 0), requests.slice().len);
}
