//! Bounded causal evidence for gameplay interactions.
//!
//! This journal records typed transitions across gameplay layers. It is
//! deliberately separate from the runtime diagnostic journal: ordinary
//! accepted, rejected, applied, and presented actions are evidence, not
//! faults. Owners append transitions only; per-entity/per-tick state sampling
//! belongs to scenario observations.

const std = @import("std");

pub const Stage = enum {
    input_sampled,
    local_preflight,
    client_submitted,
    authority_admitted,
    authority_rejected,
    simulation_intent,
    simulation_outcome,
    publication,
    client_applied,
    presentation_planned,
    draw_submitted,
    visibility_observed,
    checkpoint,
    invariant,
};

pub const Kind = enum {
    movement,
    jump,
    vehicle_toggle,
    vehicle_control,
    carry_toggle,
    melee,
    respawn,
    perception,
    damage,
    death,
    spawn,
    despawn,
    replication,
    presentation,
    draw,
    visibility,
    checkpoint,
    invariant,
};

pub const Disposition = enum {
    observed,
    accepted,
    rejected,
    applied,
    ignored,
    emitted,
    delivered,
    visible,
    invisible,
    passed,
    failed,
    timed_out,
};

/// Numeric reasons come from deliberately separate closed domains. Keeping
/// the domain beside the value prevents a protocol disposition such as
/// `destination_unavailable = 6` from being misread as Zig error number 6 by
/// the inspector or an exported trace consumer.
pub const ReasonDomain = enum {
    none,
    error_code,
    protocol_disposition,
    validation_code,
};

pub const Source = enum {
    scenario,
    input,
    client,
    authority,
    simulation,
    replication,
    presentation,
    renderer,
    visibility_oracle,
};

/// Identity is intentionally engine-neutral. A feature adapter maps its own
/// persistent, replicated, participant, or render identity into this tuple.
pub const EntityRef = struct {
    namespace: u64,
    local: u64,
    incarnation: u32 = 0,
};

/// Small typed payload for the first implementation. Zero-valued absent
/// fields are distinguished by `fields`; no heap allocation or strings occur
/// on the capture path.
pub const Fields = packed struct(u8) {
    position: bool = false,
    health: bool = false,
    state: bool = false,
    deadline: bool = false,
    visibility: bool = false,
    _reserved: u3 = 0,
};

pub const Record = struct {
    sequence: u64 = 0,
    authority_tick: u64,
    presentation_frame: ?u64 = null,
    topology_id: u64 = 0,
    scenario_id: u64 = 0,
    correlation_id: u64 = 0,
    actor: ?EntityRef = null,
    target: ?EntityRef = null,
    source: Source,
    stage: Stage,
    kind: Kind,
    disposition: Disposition,
    reason_domain: ReasonDomain = .none,
    reason: u32 = 0,
    fields: Fields = .{},
    position: [3]f32 = @splat(0),
    health: u16 = 0,
    maximum_health: u16 = 0,
    state: u16 = 0,
    deadline_tick: u64 = 0,
    visible_pixels: u32 = 0,
};

pub const AppendResult = enum {
    appended,
    overwritten_oldest,
    rejected_frozen,
    rejected_sequence_exhausted,
};

pub const Stats = struct {
    occupancy: usize,
    capacity: usize,
    high_water: usize,
    overwritten: u64,
    rejected_while_frozen: u64,
    rejected_sequence_exhausted: u64,
    frozen: bool,
    sequence_exhausted: bool,
};

/// Type-erased immutable journal borrow for editor and validation consumers.
/// The producing owner retains the concrete capacity and lifetime; consumers
/// can only inspect the stable chronological record sequence.
pub const BorrowedView = struct {
    context: *const anyopaque,
    summary: Stats,
    at_fn: *const fn (*const anyopaque, usize) ?Record,

    pub fn len(self: BorrowedView) usize {
        return self.summary.occupancy;
    }

    pub fn at(self: BorrowedView, chronological_index: usize) ?Record {
        return self.at_fn(self.context, chronological_index);
    }
};

pub const Request = enum {
    freeze,
    resume_capture,
    clear,
};

pub const max_frame_requests: usize = 8;

/// Fixed editor-to-owner mailbox. The editor cannot mutate the journal
/// directly and saturation is retained rather than silently ignored.
pub const RequestBuffer = struct {
    items: [max_frame_requests]Request = undefined,
    count: u8 = 0,
    rejected: u64 = 0,

    pub fn push(self: *RequestBuffer, request: Request) bool {
        if (self.count == max_frame_requests) {
            self.rejected +|= 1;
            return false;
        }
        self.items[self.count] = request;
        self.count += 1;
        return true;
    }

    pub fn slice(self: *const RequestBuffer) []const Request {
        return self.items[0..self.count];
    }

    pub fn clear(self: *RequestBuffer) void {
        self.count = 0;
    }
};

pub fn Journal(comptime capacity: usize) type {
    if (capacity == 0) @compileError("gameplay trace capacity must be positive");

    return struct {
        const Self = @This();

        records: [capacity]Record = undefined,
        start: usize = 0,
        count: usize = 0,
        high_water: usize = 0,
        next_sequence: u64 = 1,
        overwritten: u64 = 0,
        rejected_while_frozen: u64 = 0,
        rejected_sequence_exhausted: u64 = 0,
        frozen: bool = false,
        sequence_exhausted: bool = false,

        pub fn append(self: *Self, value: Record) AppendResult {
            if (self.frozen) {
                self.rejected_while_frozen +|= 1;
                return .rejected_frozen;
            }
            if (self.sequence_exhausted) {
                self.rejected_sequence_exhausted +|= 1;
                return .rejected_sequence_exhausted;
            }

            var record = value;
            record.sequence = self.next_sequence;
            if (self.next_sequence == std.math.maxInt(u64)) {
                self.sequence_exhausted = true;
            } else {
                self.next_sequence += 1;
            }

            if (self.count < capacity) {
                self.records[(self.start + self.count) % capacity] = record;
                self.count += 1;
                self.high_water = @max(self.high_water, self.count);
                return .appended;
            }

            self.records[self.start] = record;
            self.start = (self.start + 1) % capacity;
            self.overwritten +|= 1;
            return .overwritten_oldest;
        }

        pub fn freeze(self: *Self) bool {
            if (self.frozen) return false;
            self.frozen = true;
            return true;
        }

        pub fn resumeCapture(self: *Self) bool {
            if (!self.frozen) return false;
            self.frozen = false;
            return true;
        }

        pub fn clear(self: *Self) void {
            self.start = 0;
            self.count = 0;
            self.high_water = 0;
            self.next_sequence = 1;
            self.overwritten = 0;
            self.rejected_while_frozen = 0;
            self.rejected_sequence_exhausted = 0;
            self.frozen = false;
            self.sequence_exhausted = false;
        }

        pub fn at(self: *const Self, chronological_index: usize) ?Record {
            if (chronological_index >= self.count) return null;
            return self.records[(self.start + chronological_index) % capacity];
        }

        pub fn borrowedChronological(self: *const Self) BorrowedView {
            return .{
                .context = self,
                .summary = self.stats(),
                .at_fn = borrowedAt,
            };
        }

        fn borrowedAt(
            context: *const anyopaque,
            chronological_index: usize,
        ) ?Record {
            const self: *const Self = @ptrCast(@alignCast(context));
            return self.at(chronological_index);
        }

        pub fn copyChronological(
            self: *const Self,
            destination: *[capacity]Record,
        ) []const Record {
            for (0..self.count) |index| destination[index] = self.at(index).?;
            return destination[0..self.count];
        }

        pub fn stats(self: *const Self) Stats {
            return .{
                .occupancy = self.count,
                .capacity = capacity,
                .high_water = self.high_water,
                .overwritten = self.overwritten,
                .rejected_while_frozen = self.rejected_while_frozen,
                .rejected_sequence_exhausted = self.rejected_sequence_exhausted,
                .frozen = self.frozen,
                .sequence_exhausted = self.sequence_exhausted,
            };
        }

        /// Explicit export path. Capture remains allocation-free.
        pub fn formatJsonAlloc(
            self: *const Self,
            allocator: std.mem.Allocator,
        ) ![]u8 {
            var ordered: [capacity]Record = undefined;
            const payload = .{
                .schema = @as(u16, 2),
                .stats = self.stats(),
                .records = self.copyChronological(&ordered),
            };
            return std.json.Stringify.valueAlloc(allocator, payload, .{});
        }
    };
}

fn testRecord(tick: u64) Record {
    return .{
        .authority_tick = tick,
        .source = .client,
        .stage = .client_submitted,
        .kind = .melee,
        .disposition = .accepted,
    };
}

test "gameplay trace retains chronological transitions across wrap" {
    var journal: Journal(3) = .{};
    try std.testing.expectEqual(AppendResult.appended, journal.append(testRecord(10)));
    try std.testing.expectEqual(AppendResult.appended, journal.append(testRecord(11)));
    try std.testing.expectEqual(AppendResult.appended, journal.append(testRecord(12)));
    try std.testing.expectEqual(
        AppendResult.overwritten_oldest,
        journal.append(testRecord(13)),
    );

    try std.testing.expectEqual(@as(u64, 2), journal.at(0).?.sequence);
    try std.testing.expectEqual(@as(u64, 11), journal.at(0).?.authority_tick);
    try std.testing.expectEqual(@as(u64, 4), journal.at(2).?.sequence);
    try std.testing.expectEqual(@as(u64, 1), journal.stats().overwritten);
}

test "gameplay trace freeze preserves first retained cause" {
    var journal: Journal(2) = .{};
    _ = journal.append(testRecord(1));
    try std.testing.expect(journal.freeze());
    try std.testing.expectEqual(
        AppendResult.rejected_frozen,
        journal.append(testRecord(2)),
    );
    try std.testing.expectEqual(@as(usize, 1), journal.stats().occupancy);
    try std.testing.expectEqual(@as(u64, 1), journal.stats().rejected_while_frozen);
    try std.testing.expect(journal.resumeCapture());
    try std.testing.expectEqual(AppendResult.appended, journal.append(testRecord(3)));
}

test "gameplay trace JSON export is ordered and self describing" {
    var journal: Journal(2) = .{};
    _ = journal.append(testRecord(7));
    _ = journal.append(testRecord(8));
    var rejected = testRecord(9);
    rejected.disposition = .rejected;
    rejected.reason_domain = .protocol_disposition;
    rejected.reason = 6;
    _ = journal.append(rejected);

    const json = try journal.formatJsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(json);
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        json,
        .{},
    );
    defer parsed.deinit();

    try std.testing.expectEqual(@as(i64, 2), parsed.value.object.get("schema").?.integer);
    const records = parsed.value.object.get("records").?.array;
    try std.testing.expectEqual(@as(usize, 2), records.items.len);
    try std.testing.expectEqual(@as(i64, 8), records.items[0].object.get("authority_tick").?.integer);
    try std.testing.expectEqual(@as(i64, 9), records.items[1].object.get("authority_tick").?.integer);
    try std.testing.expectEqualStrings(
        "protocol_disposition",
        records.items[1].object.get("reason_domain").?.string,
    );
    try std.testing.expectEqual(@as(i64, 6), records.items[1].object.get("reason").?.integer);
}

test "gameplay trace borrowed view is immutable and chronological" {
    var journal: Journal(2) = .{};
    _ = journal.append(testRecord(10));
    _ = journal.append(testRecord(11));
    const view = journal.borrowedChronological();
    try std.testing.expectEqual(@as(usize, 2), view.len());
    try std.testing.expectEqual(@as(u64, 10), view.at(0).?.authority_tick);
    try std.testing.expectEqual(@as(u64, 11), view.at(1).?.authority_tick);
    try std.testing.expect(view.at(2) == null);
}

test "gameplay trace request mailbox reports saturation" {
    var requests = RequestBuffer{};
    for (0..max_frame_requests) |_| {
        try std.testing.expect(requests.push(.freeze));
    }
    try std.testing.expect(!requests.push(.clear));
    try std.testing.expectEqual(@as(u64, 1), requests.rejected);
    requests.clear();
    try std.testing.expectEqual(@as(usize, 0), requests.slice().len);
}
