//! Sandbox persistence host boundary.
//!
//! This owner coordinates canonical snapshot observation and capture with the
//! durable sandbox envelope and macOS save-slot adapter. Callers submit typed
//! requests and receive typed results; they never own canonical bytes, a save
//! store, or envelope construction and filesystem-commit policy.

const std = @import("std");
const sandbox_save = @import("sandbox_save");
const save_slots = @import("save_slots");
const snapshot_source = @import("snapshot_source");

pub const slot_label = "sandbox";

/// Exact identities admitted by the composition that constructs the sandbox.
/// The persistence owner retains these identities for every durable commit.
pub const Cohort = struct {
    payload_schema: u16,
    simulation_build_digest: sandbox_save.Digest,
    world_config_digest: sandbox_save.Digest,
    content_digest: sandbox_save.Digest,

    fn metadata(self: Cohort) sandbox_save.Metadata {
        return .{
            .payload_schema = self.payload_schema,
            .simulation_build_digest = self.simulation_build_digest,
            .world_config_digest = self.world_config_digest,
            .content_digest = self.content_digest,
        };
    }
};

/// Storage capability lifecycle. Immutable snapshot observation remains
/// available while storage is unconfigured.
pub const Lifecycle = enum {
    storage_unconfigured,
    ready,
};

pub const FeedbackStatus = enum {
    unavailable,
    idle,
    committed,
    committed_sync_warning,
    not_committed,
};

pub const Feedback = struct {
    sequence: u64 = 0,
    status: FeedbackStatus,
    slot: []const u8 = slot_label,
    detail: []const u8,
};

pub const CommitRequest = struct {
    authoring_transaction_pending: bool,
};

pub const Request = union(enum) {
    observe_snapshot,
    commit: CommitRequest,
};

pub const CommitResult = enum {
    storage_unavailable,
    deferred_authoring_transaction,
    deferred_capture_pending,
    deferred_simulation_commands,
    deferred_district_transition,
    deferred_session_work,
    deferred_authority_outputs,
    deferred_authority_fault,
    capture_failed,
    encode_failed,
    committed,
    committed_sync_warning,
    not_committed,
};

/// Opaque equality evidence for validation and diagnostics. Snapshot bytes
/// never cross the persistence boundary.
pub const SnapshotObservation = struct {
    canonical_size: usize,
    fingerprint: sandbox_save.Digest,
};

pub const Result = union(enum) {
    observed: SnapshotObservation,
    commit: CommitResult,
};

const OwnedSnapshot = struct {
    source: snapshot_source.Source,
    bytes: []u8,

    fn deinit(self: *OwnedSnapshot) void {
        self.source.release(self.bytes);
        self.* = undefined;
    }
};

const Ready = struct {
    store: save_slots.SaveSlots,
    metadata: sandbox_save.Metadata,
};

const State = union(Lifecycle) {
    storage_unconfigured,
    ready: Ready,
};

const Data = struct {
    allocator: std.mem.Allocator,
    source: snapshot_source.Source,
    state: State,
    retained_feedback: Feedback,
    pending_capture: ?snapshot_source.RequestId = null,
};

/// Type-erased durable owner. Its public representation cannot expose the
/// canonical-byte source, save adapter, metadata, or allocator to callers.
pub const Owner = opaque {
    pub fn withoutStorage(
        allocator: std.mem.Allocator,
        source: snapshot_source.Source,
    ) !*Owner {
        const data = try allocator.create(Data);
        data.* = .{
            .allocator = allocator,
            .source = source,
            .state = .storage_unconfigured,
            .retained_feedback = .{
                .status = .unavailable,
                .detail = "start with --save-root=<absolute-existing-directory>",
            },
        };
        return @ptrCast(data);
    }

    pub fn open(
        io: std.Io,
        allocator: std.mem.Allocator,
        root: save_slots.RootPath,
        cohort: Cohort,
        source: snapshot_source.Source,
    ) !*Owner {
        const metadata = cohort.metadata();
        try metadata.validate();

        var store = try save_slots.SaveSlots.open(io, root);
        errdefer store.deinit(io);
        switch (store.recover(io, sandboxSlot())) {
            .clean, .discarded_stale_candidate => {},
            .failed => |failure| {
                std.debug.print("Save candidate recovery failed: {any}\n", .{failure});
                return error.SaveRecoveryFailed;
            },
        }
        return try ready(allocator, source, store, metadata);
    }

    pub fn deinit(self: *Owner, io: std.Io) void {
        const data = self.ownerData();
        switch (data.state) {
            .ready => |*value| value.store.deinit(io),
            .storage_unconfigured => {},
        }
        const allocator = data.allocator;
        allocator.destroy(data);
    }

    pub fn lifecycle(self: *const Owner) Lifecycle {
        return std.meta.activeTag(self.ownerDataConst().state);
    }

    pub fn feedback(self: *const Owner) Feedback {
        return self.ownerDataConst().retained_feedback;
    }

    pub fn apply(
        self: *Owner,
        io: std.Io,
        request: Request,
    ) !Result {
        return switch (request) {
            .observe_snapshot => .{ .observed = try self.observe() },
            .commit => |commit_request| .{ .commit = try self.commit(
                io,
                commit_request,
            ) },
        };
    }

    fn ready(
        allocator: std.mem.Allocator,
        source: snapshot_source.Source,
        store: save_slots.SaveSlots,
        metadata: sandbox_save.Metadata,
    ) !*Owner {
        const data = try allocator.create(Data);
        data.* = .{
            .allocator = allocator,
            .source = source,
            .state = .{ .ready = .{
                .store = store,
                .metadata = metadata,
            } },
            .retained_feedback = .{
                .status = .idle,
                .detail = "ready",
            },
        };
        return @ptrCast(data);
    }

    fn capture(self: *Owner) anyerror!OwnedSnapshot {
        const data = self.ownerData();
        const request_id = data.pending_capture orelse blk: {
            const queued = try data.source.request();
            data.pending_capture = queued;
            break :blk queued;
        };
        const disposition = (try data.source.take(request_id)) orelse
            return error.CapturePending;
        data.pending_capture = null;
        return switch (disposition) {
            .captured => |bytes| .{ .source = data.source, .bytes = bytes },
            .deferred => |reason| {
                // Keep the durable barrier continuously armed across transient
                // retries. Leaving one authority cycle between attempts lets
                // active population schedule fresh work and can alternate
                // forever between a deferral and a newly pending capture.
                data.pending_capture = try data.source.request();
                return switch (reason) {
                    .session_work => error.SessionWorkPending,
                    .simulation_commands => error.CommandsPending,
                    .district_transition => error.DistrictTransitionPending,
                    .authority_outputs => error.AuthorityOutputsPending,
                };
            },
            .failed => |err| err,
        };
    }

    fn observe(self: *Owner) anyerror!SnapshotObservation {
        const data = self.ownerData();
        const bytes = try data.source.observe(data.allocator);
        defer data.allocator.free(bytes);
        var fingerprint: sandbox_save.Digest = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &fingerprint, .{});
        return .{
            .canonical_size = bytes.len,
            .fingerprint = fingerprint,
        };
    }

    fn commit(
        self: *Owner,
        io: std.Io,
        request: CommitRequest,
    ) anyerror!CommitResult {
        const data = self.ownerData();
        const durable = switch (data.state) {
            .storage_unconfigured => {
                self.setFeedback(
                    .unavailable,
                    "start with --save-root=<absolute-existing-directory>",
                );
                return .storage_unavailable;
            },
            .ready => |*value| value,
        };
        if (request.authoring_transaction_pending) {
            self.setFeedback(.not_committed, "authoring transaction pending");
            return .deferred_authoring_transaction;
        }

        var snapshot = self.capture() catch |err| switch (err) {
            error.CapturePending => {
                self.setFeedback(.not_committed, "authority capture pending");
                return .deferred_capture_pending;
            },
            error.CommandsPending => {
                self.setFeedback(.not_committed, "simulation commands pending");
                return .deferred_simulation_commands;
            },
            error.DistrictTransitionPending => {
                self.setFeedback(.not_committed, "district transition pending");
                return .deferred_district_transition;
            },
            error.SessionWorkPending => {
                self.setFeedback(.not_committed, "session work pending");
                return .deferred_session_work;
            },
            error.AuthorityOutputsPending => {
                self.setFeedback(.not_committed, "authority outputs pending");
                return .deferred_authority_outputs;
            },
            error.AuthorityFaulted => {
                self.setFeedback(.not_committed, "authority faulted");
                return .deferred_authority_fault;
            },
            else => {
                std.log.warn(
                    "canonical snapshot capture failed: {s}",
                    .{@errorName(err)},
                );
                self.setFeedback(.not_committed, "canonical snapshot capture failed");
                return .capture_failed;
            },
        };
        defer snapshot.deinit();

        const envelope = sandbox_save.encode(
            data.allocator,
            durable.metadata,
            snapshot.bytes,
        ) catch {
            self.setFeedback(.not_committed, "canonical envelope encode failed");
            return .encode_failed;
        };
        defer data.allocator.free(envelope);
        const result = durable.store.commit(
            io,
            sandboxSlot(),
            envelope,
            .{ .max_file_bytes = sandbox_save.max_envelope_bytes },
        );
        return switch (result) {
            .committed => result: {
                self.setFeedback(.committed, "atomic replace and sync complete");
                break :result .committed;
            },
            .committed_sync_warning => result: {
                self.setFeedback(
                    .committed_sync_warning,
                    "atomic replace committed; directory sync uncertain",
                );
                break :result .committed_sync_warning;
            },
            .not_committed => result: {
                self.setFeedback(.not_committed, "previous committed slot retained");
                break :result .not_committed;
            },
        };
    }

    fn setFeedback(
        self: *Owner,
        status: FeedbackStatus,
        detail: []const u8,
    ) void {
        const data = self.ownerData();
        data.retained_feedback = .{
            .sequence = data.retained_feedback.sequence +| 1,
            .status = status,
            .detail = detail,
        };
    }

    fn initBorrowedForTest(
        allocator: std.mem.Allocator,
        dir: std.Io.Dir,
        cohort: Cohort,
        source: snapshot_source.Source,
    ) !*Owner {
        const metadata = cohort.metadata();
        try metadata.validate();
        return try ready(
            allocator,
            source,
            save_slots.SaveSlots.borrowed(dir),
            metadata,
        );
    }

    fn ownerData(self: *Owner) *Data {
        return @ptrCast(@alignCast(self));
    }

    fn ownerDataConst(self: *const Owner) *const Data {
        return @ptrCast(@alignCast(self));
    }
};

fn sandboxSlot() save_slots.SlotId {
    return save_slots.SlotId.parse(slot_label) catch unreachable;
}

const TestCaptureFailure = enum {
    none,
    commands_pending,
    district_transition_pending,
    session_work_pending,
    authority_outputs_pending,
    authority_faulted,
    unexpected,
};

const TestSource = struct {
    payload: []const u8 = "canonical-snapshot",
    calls: *usize,
    failure: TestCaptureFailure = .none,
    pending: bool = false,
    allocator: std.mem.Allocator = std.testing.allocator,

    fn asSource(self: *TestSource) snapshot_source.Source {
        return .{
            .context = self,
            .observe_fn = observe,
            .request_fn = request,
            .take_fn = take,
            .release_fn = release,
        };
    }

    fn observe(context: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
        const self: *TestSource = @ptrCast(@alignCast(context));
        self.calls.* += 1;
        return allocator.dupe(u8, self.payload);
    }

    fn request(context: *anyopaque) anyerror!snapshot_source.RequestId {
        const self: *TestSource = @ptrCast(@alignCast(context));
        if (self.pending) return error.CaptureBusy;
        self.pending = true;
        self.calls.* += 1;
        return 1;
    }

    fn take(
        context: *anyopaque,
        request_id: snapshot_source.RequestId,
    ) anyerror!?snapshot_source.Disposition {
        const self: *TestSource = @ptrCast(@alignCast(context));
        if (!self.pending or request_id != 1) return error.UnknownCaptureRequest;
        self.pending = false;
        return switch (self.failure) {
            .none => .{ .captured = try self.allocator.dupe(u8, self.payload) },
            .commands_pending => .{ .deferred = .simulation_commands },
            .district_transition_pending => .{ .deferred = .district_transition },
            .session_work_pending => .{ .deferred = .session_work },
            .authority_outputs_pending => .{ .deferred = .authority_outputs },
            .authority_faulted => .{ .failed = error.AuthorityFaulted },
            .unexpected => .{ .failed = error.UnexpectedCaptureFailure },
        };
    }

    fn release(context: *anyopaque, bytes: []u8) void {
        const self: *TestSource = @ptrCast(@alignCast(context));
        self.allocator.free(bytes);
    }
};

fn testCohort() Cohort {
    return .{
        .payload_schema = 7,
        .simulation_build_digest = @splat(1),
        .world_config_digest = @splat(2),
        .content_digest = @splat(3),
    };
}

test "unconfigured storage exposes only immutable snapshot observations" {
    var calls: usize = 0;
    var source = TestSource{ .calls = &calls };
    const owner = try Owner.withoutStorage(std.testing.allocator, source.asSource());
    defer owner.deinit(std.testing.io);
    try std.testing.expectEqual(Lifecycle.storage_unconfigured, owner.lifecycle());
    try std.testing.expectEqual(FeedbackStatus.unavailable, owner.feedback().status);

    const observation = switch (try owner.apply(
        std.testing.io,
        .observe_snapshot,
    )) {
        .observed => |value| value,
        .commit => unreachable,
    };
    var expected_fingerprint: sandbox_save.Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(
        source.payload,
        &expected_fingerprint,
        .{},
    );
    try std.testing.expectEqual(source.payload.len, observation.canonical_size);
    try std.testing.expectEqualSlices(
        u8,
        &expected_fingerprint,
        &observation.fingerprint,
    );
    try std.testing.expectEqual(@as(usize, 1), calls);

    const commit_result = switch (try owner.apply(
        std.testing.io,
        .{ .commit = .{ .authoring_transaction_pending = false } },
    )) {
        .commit => |result| result,
        .observed => unreachable,
    };
    try std.testing.expectEqual(CommitResult.storage_unavailable, commit_result);
    try std.testing.expectEqual(@as(usize, 1), calls);
    try std.testing.expectEqual(@as(u64, 1), owner.feedback().sequence);
    try std.testing.expectEqual(FeedbackStatus.unavailable, owner.feedback().status);
}

test "public owner representation hides storage and snapshot capabilities" {
    switch (@typeInfo(Owner)) {
        .@"opaque" => {},
        else => return error.PersistenceOwnerMustRemainOpaque,
    }
    try std.testing.expect(!@hasDecl(Owner, "Data"));
}

test "commit writes the canonical envelope admitted by the owner cohort" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var calls: usize = 0;
    var source = TestSource{
        .payload = "durable-canonical-snapshot",
        .calls = &calls,
    };
    const owner = try Owner.initBorrowedForTest(
        std.testing.allocator,
        temporary.dir,
        testCohort(),
        source.asSource(),
    );
    defer owner.deinit(std.testing.io);
    try std.testing.expectEqual(Lifecycle.ready, owner.lifecycle());

    const commit_result = switch (try owner.apply(
        std.testing.io,
        .{ .commit = .{ .authoring_transaction_pending = false } },
    )) {
        .commit => |result| result,
        .observed => unreachable,
    };
    try std.testing.expect(
        commit_result == .committed or commit_result == .committed_sync_warning,
    );
    try std.testing.expectEqual(@as(usize, 1), calls);
    try std.testing.expectEqual(@as(u64, 1), owner.feedback().sequence);

    const bytes = try temporary.dir.readFileAlloc(
        std.testing.io,
        "sandbox.isav",
        std.testing.allocator,
        .limited(sandbox_save.max_envelope_bytes),
    );
    defer std.testing.allocator.free(bytes);
    const view = try sandbox_save.parse(bytes);
    try view.validateCompatible(testCohort().metadata());
    try std.testing.expectEqualStrings(source.payload, view.payload);
}

test "transient capture disposition immediately rearms the durable barrier" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var calls: usize = 0;
    var source = TestSource{
        .calls = &calls,
        .failure = .session_work_pending,
    };
    const owner = try Owner.initBorrowedForTest(
        std.testing.allocator,
        temporary.dir,
        testCohort(),
        source.asSource(),
    );
    defer owner.deinit(std.testing.io);

    const deferred = switch (try owner.apply(
        std.testing.io,
        .{ .commit = .{ .authoring_transaction_pending = false } },
    )) {
        .commit => |result| result,
        .observed => unreachable,
    };
    try std.testing.expectEqual(CommitResult.deferred_session_work, deferred);
    try std.testing.expect(source.pending);
    try std.testing.expectEqual(@as(usize, 2), calls);

    // The next authority cycle runs with request two already pending. A
    // successful disposition is consumed directly without an unbarriered
    // request-admission cycle between attempts.
    source.failure = .none;
    const committed = switch (try owner.apply(
        std.testing.io,
        .{ .commit = .{ .authoring_transaction_pending = false } },
    )) {
        .commit => |result| result,
        .observed => unreachable,
    };
    try std.testing.expect(
        committed == .committed or committed == .committed_sync_warning,
    );
    try std.testing.expect(!source.pending);
    try std.testing.expectEqual(@as(usize, 2), calls);
}

test "encode failure is typed and preserves the previous committed slot" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var calls: usize = 0;
    var initial_source = TestSource{ .payload = "previous", .calls = &calls };
    const initial_owner = try Owner.initBorrowedForTest(
        std.testing.allocator,
        temporary.dir,
        testCohort(),
        initial_source.asSource(),
    );
    const initial_result = switch (try initial_owner.apply(
        std.testing.io,
        .{ .commit = .{ .authoring_transaction_pending = false } },
    )) {
        .commit => |value| value,
        .observed => unreachable,
    };
    try std.testing.expect(initial_result == .committed or
        initial_result == .committed_sync_warning);
    initial_owner.deinit(std.testing.io);

    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        // Owner state and canonical capture succeed; envelope allocation fails.
        .{ .fail_index = 2 },
    );
    var replacement_source = TestSource{
        .payload = "replacement",
        .calls = &calls,
        .allocator = failing.allocator(),
    };
    const failing_owner = try Owner.initBorrowedForTest(
        failing.allocator(),
        temporary.dir,
        testCohort(),
        replacement_source.asSource(),
    );
    defer failing_owner.deinit(std.testing.io);
    const failure = switch (try failing_owner.apply(
        std.testing.io,
        .{ .commit = .{ .authoring_transaction_pending = false } },
    )) {
        .commit => |value| value,
        .observed => unreachable,
    };
    try std.testing.expectEqual(CommitResult.encode_failed, failure);
    try std.testing.expectEqualStrings(
        "canonical envelope encode failed",
        failing_owner.feedback().detail,
    );
    try std.testing.expect(failing.has_induced_failure);

    const bytes = try temporary.dir.readFileAlloc(
        std.testing.io,
        "sandbox.isav",
        std.testing.allocator,
        .limited(sandbox_save.max_envelope_bytes),
    );
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("previous", (try sandbox_save.parse(bytes)).payload);
}

test "commit deferrals are typed, truthful, and never write a slot" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var calls: usize = 0;
    var source = TestSource{ .calls = &calls };
    const owner = try Owner.initBorrowedForTest(
        std.testing.allocator,
        temporary.dir,
        testCohort(),
        source.asSource(),
    );
    defer owner.deinit(std.testing.io);
    const authoring_result = switch (try owner.apply(
        std.testing.io,
        .{ .commit = .{ .authoring_transaction_pending = true } },
    )) {
        .commit => |result| result,
        .observed => unreachable,
    };
    try std.testing.expectEqual(
        CommitResult.deferred_authoring_transaction,
        authoring_result,
    );
    try std.testing.expectEqualStrings(
        "authoring transaction pending",
        owner.feedback().detail,
    );
    try std.testing.expectEqual(@as(usize, 0), calls);

    source.failure = .commands_pending;
    const commands_result = switch (try owner.apply(
        std.testing.io,
        .{ .commit = .{ .authoring_transaction_pending = false } },
    )) {
        .commit => |result| result,
        .observed => unreachable,
    };
    try std.testing.expectEqual(
        CommitResult.deferred_simulation_commands,
        commands_result,
    );
    try std.testing.expectEqualStrings(
        "simulation commands pending",
        owner.feedback().detail,
    );

    source.failure = .district_transition_pending;
    const district_result = switch (try owner.apply(
        std.testing.io,
        .{ .commit = .{ .authoring_transaction_pending = false } },
    )) {
        .commit => |result| result,
        .observed => unreachable,
    };
    try std.testing.expectEqual(
        CommitResult.deferred_district_transition,
        district_result,
    );
    try std.testing.expectEqualStrings(
        "district transition pending",
        owner.feedback().detail,
    );
    try std.testing.expectEqual(@as(u64, 3), owner.feedback().sequence);

    const additional_deferrals = [_]struct {
        failure: TestCaptureFailure,
        expected: CommitResult,
        detail: []const u8,
    }{
        .{ .failure = .session_work_pending, .expected = .deferred_session_work, .detail = "session work pending" },
        .{ .failure = .authority_outputs_pending, .expected = .deferred_authority_outputs, .detail = "authority outputs pending" },
        .{ .failure = .authority_faulted, .expected = .deferred_authority_fault, .detail = "authority faulted" },
    };
    for (additional_deferrals) |expected| {
        source.failure = expected.failure;
        const result = switch (try owner.apply(
            std.testing.io,
            .{ .commit = .{ .authoring_transaction_pending = false } },
        )) {
            .commit => |value| value,
            .observed => unreachable,
        };
        try std.testing.expectEqual(expected.expected, result);
        try std.testing.expectEqualStrings(expected.detail, owner.feedback().detail);
    }

    source.failure = .unexpected;
    const capture_failure = switch (try owner.apply(
        std.testing.io,
        .{ .commit = .{ .authoring_transaction_pending = false } },
    )) {
        .commit => |value| value,
        .observed => unreachable,
    };
    try std.testing.expectEqual(CommitResult.capture_failed, capture_failure);
    try std.testing.expectEqualStrings(
        "canonical snapshot capture failed",
        owner.feedback().detail,
    );
    try std.testing.expectEqual(@as(u64, 7), owner.feedback().sequence);
    try std.testing.expectError(
        error.FileNotFound,
        temporary.dir.statFile(std.testing.io, "sandbox.isav", .{}),
    );
}
