//! macOS durable save-slot storage.
//!
//! This adapter owns only filesystem commit semantics. It does not interpret
//! save-envelope bytes or construct simulation state. A save becomes committed
//! at the same-directory rename from `<slot>.tmp` to `<slot>.isav`.

const std = @import("std");
const builtin = @import("builtin");

pub const max_root_path_bytes: usize = 1024;
pub const max_slot_id_bytes: usize = 32;
pub const committed_suffix = ".isav";
pub const candidate_suffix = ".tmp";
pub const max_file_name_bytes = max_slot_id_bytes + committed_suffix.len;

pub const Limits = struct {
    max_file_bytes: usize = 8 * 1024 * 1024 + 512,
};

pub const RootPath = struct {
    storage: [max_root_path_bytes]u8 = undefined,
    len: u16,

    pub fn parse(raw: []const u8) !RootPath {
        if (raw.len == 0 or raw.len > max_root_path_bytes or
            !std.fs.path.isAbsolute(raw) or
            std.mem.indexOfScalar(u8, raw, 0) != null)
        {
            return error.InvalidSaveRoot;
        }
        var result = RootPath{ .len = @intCast(raw.len) };
        @memcpy(result.storage[0..raw.len], raw);
        return result;
    }

    pub fn bytes(self: *const RootPath) []const u8 {
        return self.storage[0..self.len];
    }
};

pub const SlotId = struct {
    storage: [max_slot_id_bytes]u8 = undefined,
    len: u8,

    pub fn parse(raw: []const u8) !SlotId {
        if (raw.len == 0 or raw.len > max_slot_id_bytes) return error.InvalidSlotId;
        for (raw) |byte| {
            const allowed = (byte >= 'a' and byte <= 'z') or
                (byte >= '0' and byte <= '9') or byte == '_' or byte == '-';
            if (!allowed) return error.InvalidSlotId;
        }
        var result = SlotId{ .len = @intCast(raw.len) };
        @memcpy(result.storage[0..raw.len], raw);
        return result;
    }

    pub fn bytes(self: *const SlotId) []const u8 {
        return self.storage[0..self.len];
    }

    pub fn committedFileName(
        self: *const SlotId,
        buffer: *[max_file_name_bytes]u8,
    ) []const u8 {
        return self.fileName(committed_suffix, buffer);
    }

    pub fn candidateFileName(
        self: *const SlotId,
        buffer: *[max_file_name_bytes]u8,
    ) []const u8 {
        return self.fileName(candidate_suffix, buffer);
    }

    fn fileName(
        self: *const SlotId,
        suffix: []const u8,
        buffer: *[max_file_name_bytes]u8,
    ) []const u8 {
        const id = self.bytes();
        @memcpy(buffer[0..id.len], id);
        @memcpy(buffer[id.len..][0..suffix.len], suffix);
        return buffer[0 .. id.len + suffix.len];
    }
};

pub const Stage = enum {
    candidate_create,
    candidate_write,
    candidate_sync,
    atomic_replace,
    directory_sync,
    candidate_cleanup,
    committed_open,
    committed_stat,
    committed_read,
    recovery,
};

pub const IoReason = enum {
    access_denied,
    no_space,
    quota,
    read_only,
    io_failure,
    unsupported_platform,
    unexpected,
};

pub const IoFailure = struct {
    stage: Stage,
    reason: IoReason,
};

pub const SizeFailure = struct {
    actual: u64,
    maximum: u64,
};

pub const CandidateState = enum {
    not_created,
    removed,
    may_remain,
};

pub const CommitFailure = union(enum) {
    empty_save,
    too_large: SizeFailure,
    busy,
    io: IoFailure,
};

pub const NotCommitted = struct {
    failure: CommitFailure,
    candidate_state: CandidateState,
    /// Populated only when best-effort cleanup failed. The primary failure is
    /// retained so callers do not mistake cleanup trouble for the commit cause.
    cleanup_failure: ?IoFailure = null,
};

pub const CommitInfo = struct {
    bytes: u64,
};

pub const CommitWarning = union(enum) {
    directory_sync: IoFailure,
};

pub const CommittedWithSyncWarning = struct {
    commit: CommitInfo,
    warning: CommitWarning,
};

/// A result type that never hides whether the atomic replacement occurred.
pub const CommitResult = union(enum) {
    committed: CommitInfo,
    not_committed: NotCommitted,
    committed_sync_warning: CommittedWithSyncWarning,
};

pub const LoadFailure = union(enum) {
    not_found,
    too_large: SizeFailure,
    io: IoFailure,
};

pub const LoadResult = union(enum) {
    loaded: []u8,
    failed: LoadFailure,
};

pub const RecoveryFailure = struct {
    io: IoFailure,
};

pub const RecoveryResult = union(enum) {
    clean,
    discarded_stale_candidate,
    failed: RecoveryFailure,
};

/// Compile-time-only checkpoints for exercising each durability boundary.
/// Tests receive the same typed I/O outcomes a real storage failure produces;
/// the null production specialization contains neither checkpoints nor labels.
const TestFailurePoint = enum {
    after_partial_write,
    candidate_full_sync_unsupported,
    before_replace,
    after_replace_before_directory_sync,
};

/// Explicit directory capability. Production opens an absolute configured
/// root; tests and tools may borrow an already-scoped directory handle.
pub const SaveSlots = struct {
    dir: std.Io.Dir,
    owns_dir: bool,

    pub fn open(io: std.Io, path: RootPath) !SaveSlots {
        if (builtin.os.tag != .macos) return error.UnsupportedPlatform;
        return .{
            .dir = try std.Io.Dir.openDirAbsolute(io, path.bytes(), .{
                .follow_symlinks = false,
            }),
            .owns_dir = true,
        };
    }

    pub fn borrowed(dir: std.Io.Dir) SaveSlots {
        return .{ .dir = dir, .owns_dir = false };
    }

    pub fn deinit(self: *SaveSlots, io: std.Io) void {
        if (self.owns_dir) self.dir.close(io);
        self.* = undefined;
    }

    pub fn commit(
        self: *const SaveSlots,
        io: std.Io,
        slot: SlotId,
        bytes: []const u8,
        limits: Limits,
    ) CommitResult {
        return self.commitWithTestFailure(io, slot, bytes, limits, null);
    }

    fn commitWithTestFailure(
        self: *const SaveSlots,
        io: std.Io,
        slot: SlotId,
        bytes: []const u8,
        limits: Limits,
        comptime failure_point: ?TestFailurePoint,
    ) CommitResult {
        if (bytes.len == 0) return notCommitted(.empty_save, .not_created);
        if (bytes.len > limits.max_file_bytes) {
            return notCommitted(.{ .too_large = .{
                .actual = usizeToU64(bytes.len),
                .maximum = usizeToU64(limits.max_file_bytes),
            } }, .not_created);
        }

        var committed_buffer: [max_file_name_bytes]u8 = undefined;
        var candidate_buffer: [max_file_name_bytes]u8 = undefined;
        const committed_path = slot.committedFileName(&committed_buffer);
        const candidate_path = slot.candidateFileName(&candidate_buffer);

        const candidate = self.dir.createFile(io, candidate_path, .{
            .exclusive = true,
            .permissions = std.Io.File.Permissions.fromMode(0o600),
            .resolve_beneath = true,
        }) catch |err| {
            if (err == error.PathAlreadyExists) {
                return notCommitted(.busy, .not_created);
            }
            return notCommitted(.{ .io = mapIoFailure(.candidate_create, err) }, .not_created);
        };

        if (failure_point == .after_partial_write) {
            const prefix_len = @max(@as(usize, 1), bytes.len / 2);
            candidate.writeStreamingAll(io, bytes[0..prefix_len]) catch |err| {
                return self.closeAndRemoveCandidate(
                    io,
                    candidate,
                    candidate_path,
                    .{ .io = mapIoFailure(.candidate_write, err) },
                );
            };
            return self.closeAndRemoveCandidate(
                io,
                candidate,
                candidate_path,
                .{ .io = .{
                    .stage = .candidate_write,
                    .reason = .io_failure,
                } },
            );
        }

        candidate.writeStreamingAll(io, bytes) catch |err| {
            return self.closeAndRemoveCandidate(
                io,
                candidate,
                candidate_path,
                .{ .io = mapIoFailure(.candidate_write, err) },
            );
        };
        if (failure_point == .candidate_full_sync_unsupported) {
            return self.closeAndRemoveCandidate(
                io,
                candidate,
                candidate_path,
                .{ .io = mapIoFailure(.candidate_sync, error.UnsupportedPlatform) },
            );
        }
        fullSyncHandleDarwin(candidate.handle) catch |err| {
            return self.closeAndRemoveCandidate(
                io,
                candidate,
                candidate_path,
                .{ .io = mapIoFailure(.candidate_sync, err) },
            );
        };
        candidate.close(io);

        if (failure_point == .before_replace) {
            return self.removeClosedCandidate(
                io,
                candidate_path,
                .{ .io = .{
                    .stage = .atomic_replace,
                    .reason = .io_failure,
                } },
            );
        }

        self.dir.rename(candidate_path, self.dir, committed_path, io) catch |err| {
            return self.removeClosedCandidate(
                io,
                candidate_path,
                .{ .io = mapIoFailure(.atomic_replace, err) },
            );
        };

        const info = CommitInfo{ .bytes = usizeToU64(bytes.len) };
        if (failure_point == .after_replace_before_directory_sync) {
            return .{ .committed_sync_warning = .{
                .commit = info,
                .warning = .{ .directory_sync = .{
                    .stage = .directory_sync,
                    .reason = .io_failure,
                } },
            } };
        }
        fullSyncHandleDarwin(self.dir.handle) catch |err| {
            return .{ .committed_sync_warning = .{
                .commit = info,
                .warning = .{ .directory_sync = mapIoFailure(.directory_sync, err) },
            } };
        };
        return .{ .committed = info };
    }

    /// Discard a candidate left by a process that exited before the rename.
    /// Candidates are never promoted: only `.isav` is a committed save.
    pub fn recover(self: *const SaveSlots, io: std.Io, slot: SlotId) RecoveryResult {
        var candidate_buffer: [max_file_name_bytes]u8 = undefined;
        const candidate_path = slot.candidateFileName(&candidate_buffer);
        self.dir.deleteFile(io, candidate_path) catch |err| switch (err) {
            error.FileNotFound => return .clean,
            else => return .{ .failed = .{
                .io = mapIoFailure(.recovery, err),
            } },
        };
        return .discarded_stale_candidate;
    }

    pub fn load(
        self: *const SaveSlots,
        io: std.Io,
        allocator: std.mem.Allocator,
        slot: SlotId,
        limits: Limits,
    ) std.mem.Allocator.Error!LoadResult {
        var committed_buffer: [max_file_name_bytes]u8 = undefined;
        const committed_path = slot.committedFileName(&committed_buffer);
        const file = self.dir.openFile(io, committed_path, .{
            .allow_directory = false,
            .follow_symlinks = false,
            .resolve_beneath = true,
        }) catch |err| switch (err) {
            error.FileNotFound => return .{ .failed = .not_found },
            else => return .{ .failed = .{
                .io = mapIoFailure(.committed_open, err),
            } },
        };
        defer file.close(io);

        const file_len = file.length(io) catch |err| return .{ .failed = .{
            .io = mapIoFailure(.committed_stat, err),
        } };
        if (file_len > limits.max_file_bytes) return .{ .failed = .{ .too_large = .{
            .actual = file_len,
            .maximum = usizeToU64(limits.max_file_bytes),
        } } };
        const byte_len = std.math.cast(usize, file_len) orelse
            return .{ .failed = .{ .too_large = .{
                .actual = file_len,
                .maximum = usizeToU64(limits.max_file_bytes),
            } } };

        var read_buffer: [4096]u8 = undefined;
        var reader = file.reader(io, &read_buffer);
        const bytes = reader.interface.readAlloc(allocator, byte_len) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .{ .failed = .{
                .io = mapIoFailure(.committed_read, err),
            } },
        };
        return .{ .loaded = bytes };
    }

    fn closeAndRemoveCandidate(
        self: *const SaveSlots,
        io: std.Io,
        candidate: std.Io.File,
        candidate_path: []const u8,
        failure: CommitFailure,
    ) CommitResult {
        candidate.close(io);
        return self.removeClosedCandidate(io, candidate_path, failure);
    }

    fn removeClosedCandidate(
        self: *const SaveSlots,
        io: std.Io,
        candidate_path: []const u8,
        failure: CommitFailure,
    ) CommitResult {
        self.dir.deleteFile(io, candidate_path) catch |err| switch (err) {
            error.FileNotFound => return notCommitted(failure, .removed),
            else => return .{ .not_committed = .{
                .failure = failure,
                .candidate_state = .may_remain,
                .cleanup_failure = mapIoFailure(.candidate_cleanup, err),
            } },
        };
        return notCommitted(failure, .removed);
    }
};

fn notCommitted(failure: CommitFailure, state: CandidateState) CommitResult {
    return .{ .not_committed = .{
        .failure = failure,
        .candidate_state = state,
    } };
}

fn mapIoFailure(stage: Stage, err: anyerror) IoFailure {
    return .{ .stage = stage, .reason = switch (err) {
        error.AccessDenied, error.PermissionDenied => .access_denied,
        error.NoSpaceLeft => .no_space,
        error.DiskQuota => .quota,
        error.ReadOnlyFileSystem => .read_only,
        error.InputOutput => .io_failure,
        error.UnsupportedPlatform => .unsupported_platform,
        else => .unexpected,
    } };
}

/// `F_FULLFSYNC` includes `fsync` and asks Darwin to flush the device write
/// cache to stable media. Applying it to both the candidate and, after the
/// rename, its containing directory gives `.committed` power-loss durability
/// on the supported macOS/APFS storage contract. Unsupported filesystems fail
/// explicitly rather than silently weakening the guarantee.
fn fullSyncHandleDarwin(handle: std.posix.fd_t) !void {
    if (builtin.os.tag != .macos) return error.UnsupportedPlatform;
    while (true) {
        switch (std.c.errno(std.c.fcntl(
            handle,
            std.c.F.FULLFSYNC,
            @as(c_int, 0),
        ))) {
            .SUCCESS => return,
            .INTR => continue,
            .IO => return error.InputOutput,
            .NOSPC => return error.NoSpaceLeft,
            .DQUOT => return error.DiskQuota,
            .ROFS => return error.ReadOnlyFileSystem,
            .ACCES, .PERM => return error.AccessDenied,
            .INVAL, .OPNOTSUPP => return error.UnsupportedPlatform,
            else => return error.Unexpected,
        }
    }
}

fn usizeToU64(value: usize) u64 {
    return std.math.cast(u64, value) orelse std.math.maxInt(u64);
}

fn expectLoaded(
    store: *const SaveSlots,
    slot: SlotId,
    expected: []const u8,
) !void {
    const result = try store.load(std.testing.io, std.testing.allocator, slot, .{});
    switch (result) {
        .loaded => |bytes| {
            defer std.testing.allocator.free(bytes);
            try std.testing.expectEqualSlices(u8, expected, bytes);
        },
        .failed => |failure| {
            std.debug.print("unexpected save-slot load failure: {any}\n", .{failure});
            return error.UnexpectedLoadFailure;
        },
    }
}

test "slot and root paths reject traversal and cwd-dependent inputs" {
    const slot = try SlotId.parse("manual_01");
    try std.testing.expectEqualStrings("manual_01", slot.bytes());
    try std.testing.expectError(error.InvalidSlotId, SlotId.parse(""));
    try std.testing.expectError(error.InvalidSlotId, SlotId.parse("../manual"));
    try std.testing.expectError(error.InvalidSlotId, SlotId.parse("Manual"));
    try std.testing.expectError(error.InvalidSlotId, SlotId.parse("manual.save"));
    try std.testing.expectError(error.InvalidSlotId, SlotId.parse("manual\\save"));
    try std.testing.expectError(error.InvalidSaveRoot, RootPath.parse("relative/saves"));
    try std.testing.expectError(error.InvalidSaveRoot, RootPath.parse("/tmp/saves\x00escape"));

    var committed_buffer: [max_file_name_bytes]u8 = undefined;
    var candidate_buffer: [max_file_name_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(
        "manual_01.isav",
        slot.committedFileName(&committed_buffer),
    );
    try std.testing.expectEqualStrings(
        "manual_01.tmp",
        slot.candidateFileName(&candidate_buffer),
    );
}

test "successful commit atomically replaces and loads bounded bytes" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const store = SaveSlots.borrowed(temporary.dir);
    const slot = try SlotId.parse("manual");

    const first = store.commit(std.testing.io, slot, "first", .{});
    try std.testing.expect(first == .committed);
    try std.testing.expectEqual(@as(u64, 5), first.committed.bytes);
    try expectLoaded(&store, slot, "first");

    const second = store.commit(std.testing.io, slot, "second", .{});
    try std.testing.expect(second == .committed);
    try expectLoaded(&store, slot, "second");

    var committed_buffer: [max_file_name_bytes]u8 = undefined;
    const stat = try temporary.dir.statFile(
        std.testing.io,
        slot.committedFileName(&committed_buffer),
        .{},
    );
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), stat.permissions.toMode() & 0o777);
}

test "write and pre-rename failure seams preserve old committed bytes" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const store = SaveSlots.borrowed(temporary.dir);
    const slot = try SlotId.parse("safe");
    try std.testing.expect(store.commit(std.testing.io, slot, "old-committed", .{}) == .committed);

    const partial = store.commitWithTestFailure(
        std.testing.io,
        slot,
        "new-partial",
        .{},
        .after_partial_write,
    );
    try std.testing.expect(partial == .not_committed);
    try std.testing.expect(partial.not_committed.failure == .io);
    try std.testing.expectEqual(
        Stage.candidate_write,
        partial.not_committed.failure.io.stage,
    );
    try std.testing.expectEqual(
        IoReason.io_failure,
        partial.not_committed.failure.io.reason,
    );
    try std.testing.expectEqual(CandidateState.removed, partial.not_committed.candidate_state);
    try expectLoaded(&store, slot, "old-committed");

    const unsupported_full_sync = store.commitWithTestFailure(
        std.testing.io,
        slot,
        "new-without-full-sync",
        .{},
        .candidate_full_sync_unsupported,
    );
    try std.testing.expect(unsupported_full_sync == .not_committed);
    try std.testing.expect(unsupported_full_sync.not_committed.failure == .io);
    try std.testing.expectEqual(
        Stage.candidate_sync,
        unsupported_full_sync.not_committed.failure.io.stage,
    );
    try std.testing.expectEqual(
        IoReason.unsupported_platform,
        unsupported_full_sync.not_committed.failure.io.reason,
    );
    try std.testing.expectEqual(
        CandidateState.removed,
        unsupported_full_sync.not_committed.candidate_state,
    );
    try expectLoaded(&store, slot, "old-committed");

    const before_replace = store.commitWithTestFailure(
        std.testing.io,
        slot,
        "new-before-replace",
        .{},
        .before_replace,
    );
    try std.testing.expect(before_replace == .not_committed);
    try std.testing.expect(before_replace.not_committed.failure == .io);
    try std.testing.expectEqual(
        Stage.atomic_replace,
        before_replace.not_committed.failure.io.stage,
    );
    try std.testing.expectEqual(
        IoReason.io_failure,
        before_replace.not_committed.failure.io.reason,
    );
    try std.testing.expectEqual(CandidateState.removed, before_replace.not_committed.candidate_state);
    try expectLoaded(&store, slot, "old-committed");
}

test "Darwin full sync succeeds for regular-file and directory handles" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const candidate = try temporary.dir.createFile(std.testing.io, "durable.tmp", .{});
    try candidate.writeStreamingAll(std.testing.io, "durable");
    try fullSyncHandleDarwin(candidate.handle);
    candidate.close(std.testing.io);
    try temporary.dir.rename("durable.tmp", temporary.dir, "durable.isav", std.testing.io);
    try fullSyncHandleDarwin(temporary.dir.handle);
}

test "stale candidate never wins and explicit recovery discards it" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const store = SaveSlots.borrowed(temporary.dir);
    const slot = try SlotId.parse("recovery");
    try std.testing.expect(store.commit(std.testing.io, slot, "committed", .{}) == .committed);

    var candidate_buffer: [max_file_name_bytes]u8 = undefined;
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = slot.candidateFileName(&candidate_buffer),
        .data = "newer-but-uncommitted",
        .flags = .{ .exclusive = true },
    });
    try expectLoaded(&store, slot, "committed");

    const busy = store.commit(std.testing.io, slot, "must-not-clobber-candidate", .{});
    try std.testing.expect(busy == .not_committed);
    try std.testing.expect(busy.not_committed.failure == .busy);
    try std.testing.expectEqual(RecoveryResult.discarded_stale_candidate, store.recover(std.testing.io, slot));
    try std.testing.expectEqual(RecoveryResult.clean, store.recover(std.testing.io, slot));
    try expectLoaded(&store, slot, "committed");
}

test "committed save symlink is rejected without reading its target" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const store = SaveSlots.borrowed(temporary.dir);
    const slot = try SlotId.parse("linked_save");
    const target_path = "committed-target.bin";
    const target_bytes = "must-never-be-loaded-as-save-bytes";

    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = target_path,
        .data = target_bytes,
    });
    var committed_buffer: [max_file_name_bytes]u8 = undefined;
    try temporary.dir.symLink(
        std.testing.io,
        target_path,
        slot.committedFileName(&committed_buffer),
        .{},
    );

    const result = try store.load(std.testing.io, std.testing.allocator, slot, .{});
    switch (result) {
        .loaded => |bytes| {
            std.testing.allocator.free(bytes);
            return error.SymlinkTargetWasLoaded;
        },
        .failed => |failure| switch (failure) {
            .io => |io_failure| try std.testing.expectEqual(
                Stage.committed_open,
                io_failure.stage,
            ),
            else => return error.UnexpectedSymlinkLoadFailure,
        },
    }

    const target_after = try temporary.dir.readFileAlloc(
        std.testing.io,
        target_path,
        std.testing.allocator,
        .limited(1024),
    );
    defer std.testing.allocator.free(target_after);
    try std.testing.expectEqualSlices(u8, target_bytes, target_after);
}

test "candidate symlink is busy until recovery unlinks only the symlink" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const store = SaveSlots.borrowed(temporary.dir);
    const slot = try SlotId.parse("linked_candidate");
    const target_path = "candidate-target.bin";
    const target_bytes = "target-must-survive-recovery";

    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = target_path,
        .data = target_bytes,
    });
    var candidate_buffer: [max_file_name_bytes]u8 = undefined;
    try temporary.dir.symLink(
        std.testing.io,
        target_path,
        slot.candidateFileName(&candidate_buffer),
        .{},
    );

    const busy = store.commit(std.testing.io, slot, "committed-after-recovery", .{});
    try std.testing.expect(busy == .not_committed);
    try std.testing.expect(busy.not_committed.failure == .busy);
    try std.testing.expectEqual(CandidateState.not_created, busy.not_committed.candidate_state);

    try std.testing.expectEqual(
        RecoveryResult.discarded_stale_candidate,
        store.recover(std.testing.io, slot),
    );
    const target_after_recovery = try temporary.dir.readFileAlloc(
        std.testing.io,
        target_path,
        std.testing.allocator,
        .limited(1024),
    );
    defer std.testing.allocator.free(target_after_recovery);
    try std.testing.expectEqualSlices(u8, target_bytes, target_after_recovery);

    const committed = store.commit(std.testing.io, slot, "committed-after-recovery", .{});
    try std.testing.expect(committed == .committed);
    try expectLoaded(&store, slot, "committed-after-recovery");

    const target_after_commit = try temporary.dir.readFileAlloc(
        std.testing.io,
        target_path,
        std.testing.allocator,
        .limited(1024),
    );
    defer std.testing.allocator.free(target_after_commit);
    try std.testing.expectEqualSlices(u8, target_bytes, target_after_commit);
}

test "post-rename sync warning reports committed state without rollback fiction" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const store = SaveSlots.borrowed(temporary.dir);
    const slot = try SlotId.parse("warning");
    try std.testing.expect(store.commit(std.testing.io, slot, "old", .{}) == .committed);

    const result = store.commitWithTestFailure(
        std.testing.io,
        slot,
        "new-is-visible",
        .{},
        .after_replace_before_directory_sync,
    );
    try std.testing.expect(result == .committed_sync_warning);
    try std.testing.expect(result.committed_sync_warning.warning == .directory_sync);
    try std.testing.expectEqual(
        Stage.directory_sync,
        result.committed_sync_warning.warning.directory_sync.stage,
    );
    try std.testing.expectEqual(
        IoReason.io_failure,
        result.committed_sync_warning.warning.directory_sync.reason,
    );
    try expectLoaded(&store, slot, "new-is-visible");
}

test "empty oversized and missing saves fail structurally without mutation" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const store = SaveSlots.borrowed(temporary.dir);
    const slot = try SlotId.parse("limits");

    const empty = store.commit(std.testing.io, slot, "", .{});
    try std.testing.expect(empty == .not_committed);
    try std.testing.expect(empty.not_committed.failure == .empty_save);

    const missing = try store.load(std.testing.io, std.testing.allocator, slot, .{});
    try std.testing.expect(missing == .failed);
    try std.testing.expect(missing.failed == .not_found);

    try std.testing.expect(store.commit(std.testing.io, slot, "old", .{}) == .committed);
    const oversized = store.commit(
        std.testing.io,
        slot,
        "12345",
        .{ .max_file_bytes = 4 },
    );
    try std.testing.expect(oversized == .not_committed);
    try std.testing.expect(oversized.not_committed.failure == .too_large);
    try std.testing.expectEqual(@as(u64, 5), oversized.not_committed.failure.too_large.actual);
    try expectLoaded(&store, slot, "old");

    var committed_buffer: [max_file_name_bytes]u8 = undefined;
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = slot.committedFileName(&committed_buffer),
        .data = "12345",
    });
    const too_large_load = try store.load(
        std.testing.io,
        std.testing.allocator,
        slot,
        .{ .max_file_bytes = 4 },
    );
    try std.testing.expect(too_large_load == .failed);
    try std.testing.expect(too_large_load.failed == .too_large);
    try std.testing.expectEqual(@as(u64, 5), too_large_load.failed.too_large.actual);
}

test "absolute root opens as an owned explicit directory capability" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try temporary.dir.realPath(std.testing.io, &path_buffer);
    var store = try SaveSlots.open(
        std.testing.io,
        try RootPath.parse(path_buffer[0..path_len]),
    );
    defer store.deinit(std.testing.io);
    const slot = try SlotId.parse("owned");
    try std.testing.expect(store.commit(std.testing.io, slot, "bytes", .{}) == .committed);
    try expectLoaded(&store, slot, "bytes");
}
