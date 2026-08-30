//! Renderer-neutral S5 crate-authoring session.
//!
//! This owner stores only persistent IDs, immutable change sets, and bounded
//! editor/tool intent. It never owns an ECS entity, physics handle, Simulation
//! pointer, filesystem, or UI object. The composition submits the returned
//! feature command and routes its eventual typed outcome back here.

const std = @import("std");
const engine = @import("incinerator_engine");
const crates = @import("crate_contract");

pub const CrateOutcome = crates.Outcome;

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
    request: engine.authoring.Request,
    requested: RelocateRequest,
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
    /// Optimistic authoring revision observed when the producer began its
    /// draft. The composition must not replace this with a newer live value
    /// when the request is eventually submitted.
    expected_revision: u64,
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

pub const ObservationContext = struct {
    run_id: engine.authoring.RunId,
    wall_unix_ms: i64,
    authority_tick: ?u64,
    presentation_frame: ?u64,
};

/// Crate-owned typed authored-change evidence. The generic record supplies
/// stable correlation and timing while these fields retain the actual concrete
/// values instead of converting them into a property bag.
pub const ChangeEvidence = struct {
    record: engine.authoring.AuthoredChange,
    operation: OperationKind,
    id: engine.PersistentId,
    requested: RelocateRequest,
    before: ?engine.physics.BodyState = null,
    committed: ?engine.physics.BodyState = null,
    owner_rejection: ?crates.RejectionReason = null,
    actual_revision: ?u64 = null,

    pub fn init(
        pending: PendingSummary,
        outcome: crates.Outcome,
        context: ObservationContext,
    ) !ChangeEvidence {
        const requested_digest = try digestRelocateRequest(pending.requested);
        var result = ChangeEvidence{
            .record = .{
                .run_id = context.run_id,
                .request = pending.request,
                .committed_revision = null,
                .wall_unix_ms = context.wall_unix_ms,
                .authority_tick = context.authority_tick,
                .presentation_frame = context.presentation_frame,
                .disposition = .rejected,
                .rejection = .{ .common = .invalid_request },
                .values = .{ .requested = requested_digest },
            },
            .operation = pending.kind,
            .id = pending.id,
            .requested = pending.requested,
        };

        switch (outcome) {
            .relocated => |relocated| {
                if (relocated.transaction_id != pending.transaction_id or
                    !std.meta.eql(relocated.id, pending.id))
                {
                    return error.UnrelatedAuthoringEvidence;
                }
                result.before = try relocated.before.normalized();
                result.committed = try relocated.after.normalized();
                result.record.committed_revision = relocated.committed_revision;
                result.record.disposition = .accepted;
                result.record.rejection = null;
                result.record.values.before = try digestBodyState(result.before.?);
                result.record.values.committed = try digestBodyState(result.committed.?);
            },
            .rejected => |rejected| {
                if (rejected.command != .relocate or
                    rejected.transaction_id == null or
                    rejected.transaction_id.? != pending.transaction_id or
                    rejected.id == null or !std.meta.eql(rejected.id.?, pending.id))
                {
                    return error.UnrelatedAuthoringEvidence;
                }
                result.owner_rejection = rejected.reason;
                result.actual_revision = rejected.actual_revision;
                result.record.rejection = .{ .common = switch (rejected.reason) {
                    .capacity_reached => .owner_busy,
                    .crate_not_found, .not_owned => .target_not_found,
                    .state_conflict => .stale_revision,
                } };
            },
            else => return error.UnrelatedAuthoringEvidence,
        }
        try result.record.validate();
        return result;
    }

    pub fn rejectedBeforeOwnerOutcome(
        pending: PendingSummary,
        rejection: engine.authoring.CommonRejection,
        context: ObservationContext,
    ) !ChangeEvidence {
        const result = ChangeEvidence{
            .record = .{
                .run_id = context.run_id,
                .request = pending.request,
                .committed_revision = null,
                .wall_unix_ms = context.wall_unix_ms,
                .authority_tick = context.authority_tick,
                .presentation_frame = context.presentation_frame,
                .disposition = .rejected,
                .rejection = .{ .common = rejection },
                .values = .{
                    .requested = try digestRelocateRequest(pending.requested),
                },
            },
            .operation = pending.kind,
            .id = pending.id,
            .requested = pending.requested,
        };
        try result.record.validate();
        return result;
    }
};

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
            request: engine.authoring.Request,
            requested: RelocateRequest,
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
                    .request = pending.request,
                    .requested = pending.requested,
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

        /// UI convenience wrapper. Other admitted producers use
        /// `beginEditFrom` so provenance survives the shared owner path.
        pub fn beginEdit(self: *Self, request: RelocateRequest) !crates.Command {
            return self.beginEditFrom(request, .ui);
        }

        pub fn beginEditFrom(
            self: *Self,
            request: RelocateRequest,
            source: engine.authoring.Source,
        ) !crates.Command {
            try self.requireIdle();
            const selected = self.selected orelse return error.NoAuthoringSelection;
            if (!std.meta.eql(selected, request.id)) return error.SelectionMismatch;
            try validateRelocateRequest(request);
            return self.begin(.edit, .{
                .transaction_id = try self.transactions.take(),
                .source = source,
                .scope = .session,
                .id = request.id,
                .target_pose = request.target_pose,
                .velocity = request.velocity,
                .expected_revision = request.expected_revision,
            });
        }

        pub fn beginUndo(self: *Self) !crates.Command {
            return self.beginUndoFrom(.ui);
        }

        pub fn beginUndoFrom(
            self: *Self,
            source: engine.authoring.Source,
        ) !crates.Command {
            const change = try self.peekUndo();
            return self.beginUndoAtRevisionFrom(
                change.id,
                change.expected_revision,
                source,
            );
        }

        /// External producers must echo the identity and revision they
        /// inspected. The retained inverse value still comes from this owner.
        /// A caller cannot substitute a newer revision for this producer's
        /// retained lineage: that would turn undo into an overwrite of another
        /// producer's commit rather than an optimistic history operation.
        pub fn beginUndoAtRevisionFrom(
            self: *Self,
            id: engine.PersistentId,
            expected_revision: u64,
            source: engine.authoring.Source,
        ) !crates.Command {
            try self.requireIdle();
            const change = try self.peekUndo();
            try id.validate();
            if (!std.meta.eql(change.id, id)) return error.UndoTargetMismatch;
            if (change.expected_revision != expected_revision) {
                return error.AuthoringHistoryRevisionMismatch;
            }
            const transaction_id = try self.transactions.take();
            self.selected = change.id;
            return self.begin(.undo, .{
                .transaction_id = transaction_id,
                .source = source,
                .scope = .session,
                .id = change.id,
                .target_pose = change.before.pose,
                .velocity = .{ .exact = change.before.velocity },
                .expected_revision = expected_revision,
            });
        }

        pub fn beginRedo(self: *Self) !crates.Command {
            return self.beginRedoFrom(.ui);
        }

        pub fn beginRedoFrom(
            self: *Self,
            source: engine.authoring.Source,
        ) !crates.Command {
            const change = try self.peekRedo();
            return self.beginRedoAtRevisionFrom(
                change.id,
                change.expected_revision,
                source,
            );
        }

        /// External producers echo the target and optimistic revision while
        /// this owner supplies the retained forward state. The echoed revision
        /// must still match this producer's retained history lineage.
        pub fn beginRedoAtRevisionFrom(
            self: *Self,
            id: engine.PersistentId,
            expected_revision: u64,
            source: engine.authoring.Source,
        ) !crates.Command {
            try self.requireIdle();
            const change = try self.peekRedo();
            try id.validate();
            if (!std.meta.eql(change.id, id)) return error.RedoTargetMismatch;
            if (change.expected_revision != expected_revision) {
                return error.AuthoringHistoryRevisionMismatch;
            }
            const transaction_id = try self.transactions.take();
            self.selected = change.id;
            return self.begin(.redo, .{
                .transaction_id = transaction_id,
                .source = source,
                .scope = .session,
                .id = change.id,
                .target_pose = change.after.pose,
                .velocity = .{ .exact = change.after.velocity },
                .expected_revision = expected_revision,
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
                    // An accepted edit based on a revision outside this
                    // producer's retained lineage proves another producer
                    // committed first. Prune only after owner evidence, not
                    // merely because a caller submitted an outdated request.
                    if (pending.kind == .edit and
                        !self.historyMatchesRevision(
                            pending.id,
                            pending.request.expected_revision,
                        ))
                    {
                        self.pruneIdentity(pending.id);
                    }
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
                    if (rejected.reason == .state_conflict and
                        (rejected.actual_revision == null or
                            !self.historyMatchesRevision(
                                pending.id,
                                rejected.actual_revision.?,
                            )))
                    {
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
            const request = relocation.authoringRequest() catch unreachable;
            const expected_revision = relocation.expected_revision orelse unreachable;
            self.pending = .{
                .kind = kind,
                .transaction_id = relocation.transaction_id,
                .id = relocation.id,
                .request = request,
                .requested = .{
                    .id = relocation.id,
                    .expected_revision = expected_revision,
                    .target_pose = relocation.target_pose,
                    .velocity = relocation.velocity,
                },
            };
            return .{ .relocate = relocation };
        }

        fn requireIdle(self: *const Self) !void {
            if (self.pending != null) return error.AuthoringOperationPending;
        }

        fn peekUndo(self: *const Self) !ChangeSet {
            if (self.undo_len == 0) return error.UndoHistoryEmpty;
            return self.undo[self.undo_len - 1];
        }

        fn peekRedo(self: *const Self) !ChangeSet {
            if (self.redo_len == 0) return error.RedoHistoryEmpty;
            return self.redo[self.redo_len - 1];
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

fn digestRelocateRequest(request: RelocateRequest) !engine.assets.Digest {
    var writer = engine.contracts.replay.Writer.init();
    writer.writeBytes("incinerator.crate-relocate-request.v2");
    writer.writeU64(request.id.namespace);
    writer.writeU64(request.id.local);
    writer.writeU64(request.expected_revision);
    try writePoseDigest(&writer, request.target_pose);
    switch (request.velocity) {
        .preserve => writer.writeU8(1),
        .zero => writer.writeU8(2),
        .exact => |velocity| {
            writer.writeU8(3);
            try writeVelocityDigest(&writer, velocity);
        },
    }
    return writer.final();
}

fn digestBodyState(raw: engine.physics.BodyState) !engine.assets.Digest {
    const state = try raw.normalized();
    var writer = engine.contracts.replay.Writer.init();
    writer.writeBytes("incinerator.crate-body-state.v1");
    try writePoseDigest(&writer, state.pose);
    try writeVelocityDigest(&writer, state.velocity);
    return writer.final();
}

fn writePoseDigest(
    writer: *engine.contracts.replay.Writer,
    raw: engine.physics.Pose,
) !void {
    const pose = try raw.normalized();
    for (pose.position) |value| try writer.writeF32(value);
    for (pose.rotation) |value| try writer.writeF32(value);
}

fn writeVelocityDigest(
    writer: *engine.contracts.replay.Writer,
    velocity: engine.physics.Velocity,
) !void {
    try velocity.validate();
    for (velocity.linear) |value| try writer.writeF32(value);
    for (velocity.angular) |value| try writer.writeF32(value);
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
        .expected_revision = 0,
        .target_pose = after.pose,
        .velocity = .zero,
    });
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

test "crate evidence retains generic audit fields and concrete values" {
    const id = engine.PersistentId{ .namespace = 7, .local = 30 };
    var transactions = TransactionSequencer{};
    var controller = Controller(2).init(&transactions);
    try controller.select(id);
    const before = testState(0, 2);
    const after = testState(5, 0);
    const command = try controller.beginEdit(.{
        .id = id,
        .expected_revision = 0,
        .target_pose = after.pose,
        .velocity = .zero,
    });
    const pending = controller.snapshot().pending.?;
    const outcome = relocatedOutcome(command, before, after, 1);
    const evidence = try ChangeEvidence.init(pending, outcome, .{
        .run_id = .{ .started_wall_unix_ms = 1_700_000_000_000, .nonce = 7 },
        .wall_unix_ms = 1_700_000_000_100,
        .authority_tick = 3,
        .presentation_frame = 9,
    });
    try evidence.record.validate();
    try std.testing.expectEqual(engine.authoring.Source.ui, evidence.record.request.source);
    try std.testing.expectEqual(engine.authoring.EditScope.session, evidence.record.request.scope);
    try std.testing.expectEqual(engine.authoring.Disposition.accepted, evidence.record.disposition);
    try std.testing.expectEqual(@as(?u64, 1), evidence.record.committed_revision);
    try std.testing.expectEqualDeep(before, evidence.before.?);
    try std.testing.expectEqualDeep(after, evidence.committed.?);
    try std.testing.expect(evidence.record.values.before != null);
    try std.testing.expect(evidence.record.values.requested != null);
    try std.testing.expect(evidence.record.values.committed != null);
}

test "explicit producer source survives the shared edit undo and redo owner path" {
    const id = engine.PersistentId{ .namespace = 7, .local = 32 };
    var transactions = TransactionSequencer{};
    var controller = Controller(2).init(&transactions);
    try controller.select(id);
    const before = testState(0, 0);
    const after = testState(2, 0);

    const edit = try controller.beginEditFrom(.{
        .id = id,
        .expected_revision = 7,
        .target_pose = after.pose,
    }, .local_developer_client);
    try std.testing.expectEqual(engine.authoring.Source.local_developer_client, edit.relocate.source);
    try std.testing.expectEqual(
        engine.authoring.Source.local_developer_client,
        controller.snapshot().pending.?.request.source,
    );
    try std.testing.expectEqual(
        @as(u64, 7),
        controller.snapshot().pending.?.requested.expected_revision,
    );
    _ = try controller.observe(relocatedOutcome(edit, before, after, 8));

    const undo = try controller.beginUndoFrom(.local_developer_client);
    try std.testing.expectEqual(engine.authoring.Source.local_developer_client, undo.relocate.source);
    _ = try controller.observe(relocatedOutcome(undo, after, before, 9));

    const redo = try controller.beginRedoFrom(.scripted_validation);
    try std.testing.expectEqual(engine.authoring.Source.scripted_validation, redo.relocate.source);
}

test "external undo and redo reject revisions outside retained producer lineage" {
    const id = engine.PersistentId{ .namespace = 7, .local = 33 };
    var transactions = TransactionSequencer{};
    var controller = Controller(2).init(&transactions);
    try controller.select(id);
    const before = testState(0, 0);
    const after = testState(2, 0);

    const edit = try controller.beginEdit(.{
        .id = id,
        .expected_revision = 4,
        .target_pose = after.pose,
    });
    _ = try controller.observe(relocatedOutcome(edit, before, after, 5));

    try std.testing.expectError(
        error.AuthoringHistoryRevisionMismatch,
        controller.beginUndoAtRevisionFrom(id, 4, .local_developer_client),
    );
    const undo = try controller.beginUndoAtRevisionFrom(
        id,
        5,
        .local_developer_client,
    );
    try std.testing.expectEqual(@as(?u64, 5), undo.relocate.expected_revision);
    try std.testing.expectEqualDeep(before.pose, undo.relocate.target_pose);
    try std.testing.expectEqual(
        engine.authoring.Source.local_developer_client,
        undo.relocate.source,
    );
    _ = try controller.observe(relocatedOutcome(undo, after, before, 6));

    try std.testing.expectError(
        error.AuthoringHistoryRevisionMismatch,
        controller.beginRedoAtRevisionFrom(id, 5, .local_developer_client),
    );
    const redo = try controller.beginRedoAtRevisionFrom(
        id,
        6,
        .local_developer_client,
    );
    try std.testing.expectEqual(@as(?u64, 6), redo.relocate.expected_revision);
    try std.testing.expectEqualDeep(after.pose, redo.relocate.target_pose);
}

test "crate evidence maps stale revision to typed rejected record" {
    const id = engine.PersistentId{ .namespace = 7, .local = 31 };
    var transactions = TransactionSequencer{};
    var controller = Controller(2).init(&transactions);
    try controller.select(id);
    const command = try controller.beginEdit(.{
        .id = id,
        .expected_revision = 2,
        .target_pose = testState(5, 0).pose,
    });
    const pending = controller.snapshot().pending.?;
    const evidence = try ChangeEvidence.init(pending, .{ .rejected = .{
        .command = .relocate,
        .reason = .state_conflict,
        .transaction_id = command.relocate.transaction_id,
        .id = id,
        .expected_revision = 2,
        .actual_revision = 3,
    } }, .{
        .run_id = .{ .started_wall_unix_ms = 1_700_000_000_000, .nonce = 8 },
        .wall_unix_ms = 1_700_000_000_100,
        .authority_tick = 4,
        .presentation_frame = null,
    });
    try evidence.record.validate();
    try std.testing.expectEqual(engine.authoring.Disposition.rejected, evidence.record.disposition);
    try std.testing.expectEqual(
        engine.authoring.CommonRejection.stale_revision,
        evidence.record.rejection.?.common,
    );
    try std.testing.expectEqual(crates.RejectionReason.state_conflict, evidence.owner_rejection.?);
    try std.testing.expectEqual(@as(?u64, 3), evidence.actual_revision);
    try std.testing.expect(evidence.before == null);
    try std.testing.expect(evidence.committed == null);
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
        .expected_revision = 0,
        .target_pose = first_state.pose,
        .velocity = .{ .exact = first_state.velocity },
    });
    try std.testing.expectEqual(ObserveResult.applied, try controller.observe(
        relocatedOutcome(first_edit, initial, first_state, 1),
    ));
    const second_edit = try controller.beginEdit(.{
        .id = id,
        .expected_revision = 1,
        .target_pose = second_state.pose,
        .velocity = .{ .exact = second_state.velocity },
    });
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
        .expected_revision = 0,
        .target_pose = first_once.pose,
    });
    _ = try controller.observe(relocatedOutcome(first_edit, initial, first_once, 1));

    try controller.select(second_id);
    const second_edit = try controller.beginEdit(.{
        .id = second_id,
        .expected_revision = 0,
        .target_pose = second_once.pose,
    });
    _ = try controller.observe(relocatedOutcome(second_edit, initial, second_once, 1));

    try controller.select(first_id);
    const first_edit_again = try controller.beginEdit(.{
        .id = first_id,
        .expected_revision = 1,
        .target_pose = first_twice.pose,
    });
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
        .expected_revision = 0,
        .target_pose = testState(1, 0).pose,
    });
    try std.testing.expect(controller.submissionFailed(command.relocate.transaction_id));
    try std.testing.expectEqual(@as(u16, 0), controller.snapshot().undo_count);

    const retry = try controller.beginEdit(.{
        .id = id,
        .expected_revision = 0,
        .target_pose = testState(1, 0).pose,
    });
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
        .expected_revision = 0,
        .target_pose = first_state.pose,
    });
    _ = try first.observe(relocatedOutcome(first_edit, initial, first_state, 1));

    const external_edit = try second.beginEdit(.{
        .id = id,
        .expected_revision = 1,
        .target_pose = external_state.pose,
    });
    _ = try second.observe(relocatedOutcome(external_edit, first_state, external_state, 2));

    // The authoritative view supplies revision 2. The owner-confirmed commit,
    // rather than request construction alone, discards revision-1 lineage.
    const newest_edit = try first.beginEdit(.{
        .id = id,
        .expected_revision = 2,
        .target_pose = newest_state.pose,
    });
    try std.testing.expectEqual(@as(u16, 1), first.snapshot().undo_count);
    _ = try first.observe(relocatedOutcome(newest_edit, external_state, newest_state, 3));
    try std.testing.expectEqual(@as(u64, 1), first.snapshot().invalidated_history);

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

test "outdated rejected edit preserves history when owner revision matches lineage" {
    const id = engine.PersistentId{ .namespace = 8, .local = 4 };
    var transactions = TransactionSequencer{};
    var controller = Controller(4).init(&transactions);
    try controller.select(id);
    const initial = testState(0, 0);
    const committed = testState(1, 0);
    const edit = try controller.beginEdit(.{
        .id = id,
        .expected_revision = 0,
        .target_pose = committed.pose,
    });
    _ = try controller.observe(relocatedOutcome(edit, initial, committed, 1));

    const stale = try controller.beginEdit(.{
        .id = id,
        .expected_revision = 0,
        .target_pose = testState(9, 0).pose,
    });
    try std.testing.expectEqual(ObserveResult.rejected, try controller.observe(.{
        .rejected = .{
            .command = .relocate,
            .reason = .state_conflict,
            .transaction_id = stale.relocate.transaction_id,
            .id = id,
            .expected_revision = 0,
            .actual_revision = 1,
        },
    }));
    try std.testing.expectEqual(@as(u16, 1), controller.snapshot().undo_count);
    try std.testing.expectEqual(@as(u64, 0), controller.snapshot().invalidated_history);
    const undo = try controller.beginUndo();
    try std.testing.expectEqualDeep(initial.pose, undo.relocate.target_pose);
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
        .expected_revision = 0,
        .target_pose = local_state.pose,
    });
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
        .expected_revision = 2,
        .target_pose = newest_state.pose,
    });
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
            .expected_revision = 0,
            .target_pose = testState(@floatFromInt(index + 1), 0).pose,
        });
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
        .expected_revision = 0,
        .target_pose = testState(3, 0).pose,
    });
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
        .expected_revision = 0,
        .target_pose = first_state.pose,
    });
    const second_command = try second.beginEdit(.{
        .id = id,
        .expected_revision = 1,
        .target_pose = second_state.pose,
    });
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
