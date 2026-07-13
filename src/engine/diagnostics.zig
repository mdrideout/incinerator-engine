//! Allocation-free owner-thread diagnostic journal.

const std = @import("std");
const contract = @import("engine_contracts").diagnostics;

pub const Severity = contract.Severity;
pub const Category = contract.Category;
pub const ThreadRole = contract.ThreadRole;
pub const Code = contract.Code;
pub const Entry = contract.Entry;
pub const QueueStats = contract.QueueStats;
pub const codes = contract.codes;

pub const default_capacity: usize = 256;

/// Every populated field must equal the admitted entry. An empty match is an
/// intentional match-all condition.
pub const FreezeMatch = struct {
    severity: ?Severity = null,
    category: ?Category = null,
    code: ?Code = null,

    pub fn matches(self: FreezeMatch, entry: Entry) bool {
        if (self.severity) |value| {
            if (entry.severity != value) return false;
        }
        if (self.category) |value| {
            if (entry.category != value) return false;
        }
        if (self.code) |value| {
            if (entry.code != value) return false;
        }
        return true;
    }
};

pub const AppendRejection = enum(u8) {
    none,
    frozen,
    sequence_exhausted,
};

pub const AppendResult = struct {
    accepted: bool,
    sequence: u64 = 0,
    overwrote_oldest: bool = false,
    froze: bool = false,
    rejection: AppendRejection = .none,
};

pub const JournalStats = struct {
    count: usize,
    capacity: usize,
    overwritten: u64,
    rejected_while_frozen: u64,
    rejected_sequence_exhausted: u64,
    sequence_exhausted: bool,
    frozen: bool,
    trigger_armed: bool,
};

pub fn currentThreadId() u64 {
    return @intCast(std.Thread.getCurrentId());
}

/// A fixed-capacity journal whose storage is part of the value itself. All
/// operations are confined to the thread that initialized it. When full, a
/// normal append overwrites the oldest entry and records that loss visibly.
pub fn Journal(comptime capacity_value: usize) type {
    if (capacity_value == 0) @compileError("diagnostic journal capacity must be nonzero");

    return struct {
        const Self = @This();

        pub const capacity = capacity_value;

        pub const BorrowedView = struct {
            first: []const Entry,
            second: []const Entry,

            pub fn len(self: BorrowedView) usize {
                return self.first.len + self.second.len;
            }

            pub fn at(self: BorrowedView, index: usize) ?*const Entry {
                if (index < self.first.len) return &self.first[index];
                const second_index = index - self.first.len;
                if (second_index < self.second.len) return &self.second[second_index];
                return null;
            }
        };

        owner_thread: std.Thread.Id,
        storage: [capacity_value]Entry = undefined,
        start: usize = 0,
        count: usize = 0,
        next_sequence: ?u64 = 1,
        overwritten: u64 = 0,
        rejected_while_frozen: u64 = 0,
        rejected_sequence_exhausted: u64 = 0,
        frozen: bool = false,
        armed_match: ?FreezeMatch = null,

        pub fn init() Self {
            return .{ .owner_thread = std.Thread.getCurrentId() };
        }

        /// Append never allocates and never returns an error. A freeze trigger
        /// is applied only after the triggering entry has been retained.
        pub fn append(self: *Self, entry_value: Entry) AppendResult {
            self.assertOwnerThread();
            if (self.frozen) {
                self.rejected_while_frozen +|= 1;
                return .{ .accepted = false, .rejection = .frozen };
            }
            const sequence = self.next_sequence orelse {
                self.rejected_sequence_exhausted +|= 1;
                return .{ .accepted = false, .rejection = .sequence_exhausted };
            };

            const overwrote = self.count == capacity_value;
            const write_index = if (overwrote)
                self.start
            else
                (self.start + self.count) % capacity_value;
            if (overwrote) {
                self.start = (self.start + 1) % capacity_value;
                self.overwritten +|= 1;
            } else {
                self.count += 1;
            }

            var admitted = entry_value;
            admitted.sequence = sequence;
            self.storage[write_index] = admitted;
            self.next_sequence = if (sequence == std.math.maxInt(u64))
                null
            else
                sequence + 1;

            const should_freeze = if (self.armed_match) |condition|
                condition.matches(admitted)
            else
                false;
            if (should_freeze) {
                // Conditional capture is one-shot: only a retained matching
                // entry consumes the arm. Rejected entries leave it intact.
                self.armed_match = null;
                self.frozen = true;
            }
            return .{
                .accepted = true,
                .sequence = admitted.sequence,
                .overwrote_oldest = overwrote,
                .froze = should_freeze,
            };
        }

        /// Arm a one-shot owner-wide condition. Every later append evaluates
        /// this match until a retained entry consumes it or the host disarms.
        pub fn armFreeze(self: *Self, condition: FreezeMatch) void {
            self.assertOwnerThread();
            self.armed_match = condition;
        }

        /// Disarming never resumes a frozen capture. Returns whether an armed
        /// condition was present so hosts can expose idempotent controls.
        pub fn disarmFreeze(self: *Self) bool {
            self.assertOwnerThread();
            const was_armed = self.armed_match != null;
            self.armed_match = null;
            return was_armed;
        }

        /// Runtime fault retention uses this independent safety path after it
        /// attempts to append the immutable fault entry. It intentionally does
        /// not consume an unrelated host-owned conditional arm.
        pub fn forceFreeze(self: *Self) bool {
            self.assertOwnerThread();
            const was_frozen = self.frozen;
            self.frozen = true;
            return !was_frozen;
        }

        /// Resume admission without changing retained entries, cumulative loss
        /// counters, or the next sequence. Returns whether capture was frozen.
        pub fn resumeCapture(self: *Self) bool {
            self.assertOwnerThread();
            const was_frozen = self.frozen;
            self.frozen = false;
            return was_frozen;
        }

        /// Remove retained entries without implicitly resuming capture. Loss
        /// counters and the monotonic sequence cursor are lifetime values and
        /// therefore survive a clear.
        pub fn clear(self: *Self) void {
            self.assertOwnerThread();
            self.start = 0;
            self.count = 0;
        }

        /// Chronological borrowed access is represented as at most two slices
        /// because the oldest entry may be in the middle of the ring. Both
        /// slices are invalidated by a later successful append or clear.
        pub fn borrowedChronological(self: *const Self) BorrowedView {
            self.assertOwnerThread();
            if (self.count == 0) return .{
                .first = self.storage[0..0],
                .second = self.storage[0..0],
            };
            const first_len = @min(self.count, capacity_value - self.start);
            return .{
                .first = self.storage[self.start..][0..first_len],
                .second = self.storage[0 .. self.count - first_len],
            };
        }

        /// Copy as many oldest-to-newest entries as the destination can hold.
        /// The returned slice aliases only the caller's destination.
        pub fn copyChronological(self: *const Self, destination: []Entry) []Entry {
            const view = self.borrowedChronological();
            const copy_count = @min(destination.len, view.len());
            const first_count = @min(copy_count, view.first.len);
            @memcpy(destination[0..first_count], view.first[0..first_count]);
            const second_count = copy_count - first_count;
            @memcpy(
                destination[first_count..copy_count],
                view.second[0..second_count],
            );
            return destination[0..copy_count];
        }

        pub fn stats(self: *const Self) JournalStats {
            self.assertOwnerThread();
            return .{
                .count = self.count,
                .capacity = capacity_value,
                .overwritten = self.overwritten,
                .rejected_while_frozen = self.rejected_while_frozen,
                .rejected_sequence_exhausted = self.rejected_sequence_exhausted,
                .sequence_exhausted = self.next_sequence == null,
                .frozen = self.frozen,
                .trigger_armed = self.armed_match != null,
            };
        }

        fn assertOwnerThread(self: *const Self) void {
            if (std.Thread.getCurrentId() != self.owner_thread) {
                @panic("diagnostic journal accessed from a non-owner thread");
            }
        }
    };
}

pub const DefaultJournal = Journal(default_capacity);

test "default journal has the documented fixed capacity" {
    try std.testing.expectEqual(@as(usize, 256), DefaultJournal.capacity);
}

test "freeze match requires every populated severity category and code field" {
    const condition = FreezeMatch{
        .severity = .fatal,
        .category = .physics,
        .code = 42,
    };
    const matching = Entry{
        .severity = .fatal,
        .category = .physics,
        .code = 42,
    };
    try std.testing.expect(condition.matches(matching));
    var changed = matching;
    changed.severity = .err;
    try std.testing.expect(!condition.matches(changed));
    changed = matching;
    changed.category = .runtime;
    try std.testing.expect(!condition.matches(changed));
    changed = matching;
    changed.code = 43;
    try std.testing.expect(!condition.matches(changed));
}

fn testEntry(code: Code) Entry {
    return .{
        .severity = .info,
        .category = .general,
        .code = code,
        .thread_role = .simulation,
        .thread_id = currentThreadId(),
    };
}

test "journal wraps with chronological borrowed and copied views" {
    var journal = Journal(3).init();
    _ = journal.append(testEntry(1));
    _ = journal.append(testEntry(2));
    _ = journal.append(testEntry(3));
    const fourth = journal.append(testEntry(4));
    try std.testing.expect(fourth.accepted);
    try std.testing.expect(fourth.overwrote_oldest);
    try std.testing.expectEqual(@as(u64, 4), fourth.sequence);

    const borrowed = journal.borrowedChronological();
    try std.testing.expectEqual(@as(usize, 3), borrowed.len());
    try std.testing.expectEqual(@as(Code, 2), borrowed.at(0).?.code);
    try std.testing.expectEqual(@as(Code, 3), borrowed.at(1).?.code);
    try std.testing.expectEqual(@as(Code, 4), borrowed.at(2).?.code);
    try std.testing.expect(borrowed.at(3) == null);

    var destination: [4]Entry = undefined;
    const copied = journal.copyChronological(&destination);
    try std.testing.expectEqual(@as(usize, 3), copied.len);
    try std.testing.expectEqual(@as(Code, 2), copied[0].code);
    try std.testing.expectEqual(@as(Code, 4), copied[2].code);
    const stats_value = journal.stats();
    try std.testing.expectEqual(@as(u64, 1), stats_value.overwritten);
    try std.testing.expectEqual(@as(u64, 0), stats_value.rejected_while_frozen);
}

test "conditional freeze retains its triggering entry and rejects later saturation" {
    var journal = Journal(2).init();
    journal.armFreeze(.{
        .severity = .fatal,
        .category = .runtime,
        .code = 12,
    });
    _ = journal.append(testEntry(10));
    _ = journal.append(testEntry(11));
    try std.testing.expect(journal.stats().trigger_armed);
    try std.testing.expect(!journal.stats().frozen);
    var matching = testEntry(12);
    matching.severity = .fatal;
    matching.category = .runtime;
    const trigger = journal.append(matching);
    try std.testing.expect(trigger.accepted);
    try std.testing.expect(trigger.overwrote_oldest);
    try std.testing.expect(trigger.froze);
    try std.testing.expect(!journal.stats().trigger_armed);

    const rejected = journal.append(testEntry(13));
    try std.testing.expect(!rejected.accepted);
    try std.testing.expectEqual(@as(u64, 0), rejected.sequence);
    try std.testing.expectEqual(AppendRejection.frozen, rejected.rejection);

    var destination: [2]Entry = undefined;
    const copied = journal.copyChronological(&destination);
    try std.testing.expectEqual(@as(Code, 11), copied[0].code);
    try std.testing.expectEqual(@as(Code, 12), copied[1].code);
    const stats_value = journal.stats();
    try std.testing.expect(stats_value.frozen);
    try std.testing.expectEqual(@as(u64, 1), stats_value.overwritten);
    try std.testing.expectEqual(@as(u64, 1), stats_value.rejected_while_frozen);
}

test "resume and clear preserve lifetime counters and monotonic sequence" {
    var journal = Journal(3).init();
    _ = journal.append(testEntry(20));
    journal.armFreeze(.{ .code = 21 });
    const frozen = journal.append(testEntry(21));
    try std.testing.expect(frozen.froze);
    try std.testing.expect(!journal.stats().trigger_armed);
    _ = journal.append(testEntry(22));
    try std.testing.expect(journal.resumeCapture());

    const resumed = journal.append(testEntry(23));
    try std.testing.expectEqual(@as(u64, 3), resumed.sequence);
    try std.testing.expect(!resumed.froze);
    try std.testing.expect(!journal.stats().trigger_armed);
    journal.clear();
    const cleared_stats = journal.stats();
    try std.testing.expectEqual(@as(usize, 0), cleared_stats.count);
    try std.testing.expectEqual(@as(u64, 1), cleared_stats.rejected_while_frozen);
    try std.testing.expect(!cleared_stats.frozen);

    const after_clear = journal.append(testEntry(24));
    try std.testing.expectEqual(@as(u64, 4), after_clear.sequence);
}

test "arm disarm and clear remain independent from frozen capture state" {
    var journal = Journal(3).init();
    journal.armFreeze(.{ .code = 42 });
    try std.testing.expect(journal.stats().trigger_armed);
    const unrelated = journal.append(testEntry(41));
    try std.testing.expect(unrelated.accepted);
    try std.testing.expect(!unrelated.froze);
    try std.testing.expect(journal.stats().trigger_armed);

    journal.clear();
    try std.testing.expectEqual(@as(usize, 0), journal.stats().count);
    try std.testing.expect(journal.stats().trigger_armed);
    try std.testing.expect(journal.disarmFreeze());
    try std.testing.expect(!journal.disarmFreeze());
    const disarmed_match = journal.append(testEntry(42));
    try std.testing.expect(disarmed_match.accepted);
    try std.testing.expect(!disarmed_match.froze);

    try std.testing.expect(journal.forceFreeze());
    journal.armFreeze(.{ .code = 44 });
    const rejected = journal.append(testEntry(44));
    try std.testing.expectEqual(AppendRejection.frozen, rejected.rejection);
    try std.testing.expect(journal.stats().trigger_armed);
    journal.clear();
    try std.testing.expect(journal.stats().frozen);
    try std.testing.expect(journal.stats().trigger_armed);
    try std.testing.expect(journal.resumeCapture());
    const staged_match = journal.append(testEntry(44));
    try std.testing.expect(staged_match.froze);
    try std.testing.expect(!journal.stats().trigger_armed);
}

test "sequence exhaustion admits max once then fails closed visibly" {
    var journal = Journal(2).init();
    journal.armFreeze(.{ .code = 31 });
    journal.next_sequence = std.math.maxInt(u64);
    const last = journal.append(testEntry(30));
    try std.testing.expect(last.accepted);
    try std.testing.expectEqual(std.math.maxInt(u64), last.sequence);
    try std.testing.expect(journal.stats().trigger_armed);

    const rejected = journal.append(testEntry(31));
    try std.testing.expect(!rejected.accepted);
    try std.testing.expectEqual(AppendRejection.sequence_exhausted, rejected.rejection);
    const stats_value = journal.stats();
    try std.testing.expect(stats_value.sequence_exhausted);
    try std.testing.expect(stats_value.trigger_armed);
    try std.testing.expectEqual(@as(u64, 1), stats_value.rejected_sequence_exhausted);
    try std.testing.expectEqual(@as(usize, 1), stats_value.count);
    try std.testing.expectEqual(@as(Code, 30), journal.borrowedChronological().at(0).?.code);
}
