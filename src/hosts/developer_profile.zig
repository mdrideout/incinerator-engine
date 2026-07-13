//! Bounded, allocation-free host profiling records.
//!
//! This is deliberately not a tracing service and does not append to the
//! diagnostic journal. Hosts provide explicit monotonic timestamps so the
//! recorder has no platform-clock dependency; recording is nonfallible and
//! any lost evidence remains visible through cumulative ring statistics.

const std = @import("std");

pub const default_span_capacity: usize = 2_048;
pub const default_frame_capacity: usize = 240;

/// Fixed identifiers for the composed sandbox hot path. Adding a phase is a
/// deliberate schema change rather than accepting arbitrary producer text.
pub const Phase = enum(u8) {
    input = 0,
    content_pump = 1,
    runtime_commands = 2,
    runtime_pre_physics = 3,
    physics = 4,
    runtime_post_physics = 5,
    debug_extraction = 6,
    stream_gpu_pump = 7,
    debug_upload = 8,
    scene_extraction = 9,
    scene_draw = 10,
    debug_draw = 11,
    editor = 12,
    submission = 13,
};

pub const Outcome = enum(u8) {
    success,
    failure,
};

/// Counts sampled once for a completed host frame. Event-like fields should
/// be accumulated during that frame; live resource fields are gauges sampled
/// at its completion.
pub const Counts = struct {
    draw_calls: u64 = 0,
    debug_primitives: u64 = 0,
    debug_upload_bytes: u64 = 0,
    streaming_submissions: u64 = 0,
    streaming_publishes: u64 = 0,
    live_resources: u64 = 0,
    live_resource_bytes: u64 = 0,

    /// Merge partial host/adapter counts without allowing instrumentation
    /// overflow to affect authority or wrap into misleading values.
    pub fn merge(self: *Counts, other: Counts) void {
        self.draw_calls +|= other.draw_calls;
        self.debug_primitives +|= other.debug_primitives;
        self.debug_upload_bytes +|= other.debug_upload_bytes;
        self.streaming_submissions +|= other.streaming_submissions;
        self.streaming_publishes +|= other.streaming_publishes;
        self.live_resources +|= other.live_resources;
        self.live_resource_bytes +|= other.live_resource_bytes;
    }
};

pub const SpanToken = struct {
    phase: Phase,
    frame_index: ?u64 = null,
    tick_index: ?u64 = null,
    start_ns: u64,
};

pub const Span = struct {
    /// Assigned by the retaining ring. Zero denotes an unadmitted value.
    sequence: u64 = 0,
    phase: Phase,
    frame_index: ?u64 = null,
    tick_index: ?u64 = null,
    start_ns: u64,
    end_ns: u64,
    duration_ns: u64,
    outcome: Outcome,
};

pub const FrameToken = struct {
    frame_index: u64,
    tick_index: ?u64 = null,
    start_ns: u64,
};

pub const Frame = struct {
    /// Assigned by the retaining ring. Zero denotes an unadmitted value.
    sequence: u64 = 0,
    frame_index: u64,
    tick_index: ?u64 = null,
    start_ns: u64,
    end_ns: u64,
    duration_ns: u64,
    outcome: Outcome,
    counts: Counts,
};

pub const Rejection = enum(u8) {
    none,
    invalid_interval,
    duplicate_scope_finish,
    sequence_exhausted,
};

pub const RecordResult = struct {
    accepted: bool,
    sequence: u64 = 0,
    overwrote_oldest: bool = false,
    rejection: Rejection = .none,
};

pub const HistoryStats = struct {
    count: usize,
    capacity: usize,
    overwritten: u64,
    rejected: u64,
    rejected_invalid_interval: u64,
    rejected_duplicate_scope_finish: u64,
    rejected_sequence_exhausted: u64,
    sequence_exhausted: bool,
};

pub const RecorderStats = struct {
    spans: HistoryStats,
    frames: HistoryStats,
};

/// Storage primitive shared by the span and per-frame histories. `Entry` must
/// contain a `sequence: u64` field; successful admission always replaces its
/// incoming value. A full ring overwrites its oldest entry and records that
/// evidence loss rather than rejecting or allocating.
pub fn FixedHistory(comptime Entry: type, comptime capacity_value: usize) type {
    if (capacity_value == 0) @compileError("profile history capacity must be nonzero");
    if (!@hasField(Entry, "sequence")) {
        @compileError("profile history entry must contain sequence: u64");
    }
    if (@FieldType(Entry, "sequence") != u64) {
        @compileError("profile history entry sequence must be u64");
    }

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

        storage: [capacity_value]Entry = undefined,
        start: usize = 0,
        count: usize = 0,
        next_sequence: ?u64 = 1,
        overwritten: u64 = 0,
        rejected_invalid_interval: u64 = 0,
        rejected_duplicate_scope_finish: u64 = 0,
        rejected_sequence_exhausted: u64 = 0,

        /// Never allocates and never returns an error. Sequence exhaustion is
        /// terminal for admission but remains a profiling-evidence failure,
        /// not an authoritative host failure.
        pub fn append(self: *Self, entry_value: Entry) RecordResult {
            const sequence = self.next_sequence orelse {
                self.rejected_sequence_exhausted +|= 1;
                return .{
                    .accepted = false,
                    .rejection = .sequence_exhausted,
                };
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

            return .{
                .accepted = true,
                .sequence = sequence,
                .overwrote_oldest = overwrote,
            };
        }

        /// Chronological borrowed access as at most two slices. A later
        /// successful append invalidates both slices.
        pub fn view(self: *const Self) BorrowedView {
            if (self.count == 0) return .{
                .first = self.storage[0..0],
                .second = self.storage[0..0],
            };
            const first_count = @min(self.count, capacity_value - self.start);
            return .{
                .first = self.storage[self.start..][0..first_count],
                .second = self.storage[0 .. self.count - first_count],
            };
        }

        /// Drop retained samples without resetting lifetime accounting or the
        /// monotonic sequence cursor. This makes a developer clear operation
        /// unable to disguise earlier evidence loss or reuse sequence IDs.
        pub fn clearRetained(self: *Self) void {
            self.start = 0;
            self.count = 0;
        }

        pub fn stats(self: *const Self) HistoryStats {
            var rejected = self.rejected_invalid_interval;
            rejected +|= self.rejected_duplicate_scope_finish;
            rejected +|= self.rejected_sequence_exhausted;
            return .{
                .count = self.count,
                .capacity = capacity_value,
                .overwritten = self.overwritten,
                .rejected = rejected,
                .rejected_invalid_interval = self.rejected_invalid_interval,
                .rejected_duplicate_scope_finish = self.rejected_duplicate_scope_finish,
                .rejected_sequence_exhausted = self.rejected_sequence_exhausted,
                .sequence_exhausted = self.next_sequence == null,
            };
        }

        fn rejectInvalidInterval(self: *Self) RecordResult {
            self.rejected_invalid_interval +|= 1;
            return .{
                .accepted = false,
                .rejection = .invalid_interval,
            };
        }

        fn rejectDuplicateScopeFinish(self: *Self) RecordResult {
            self.rejected_duplicate_scope_finish +|= 1;
            return .{
                .accepted = false,
                .rejection = .duplicate_scope_finish,
            };
        }
    };
}

pub fn SpanRing(comptime capacity_value: usize) type {
    return struct {
        const Self = @This();
        const History = FixedHistory(Span, capacity_value);

        pub const capacity = capacity_value;
        pub const BorrowedView = History.BorrowedView;

        pub const Scope = struct {
            owner: *Self,
            token: SpanToken,
            open: bool = true,

            /// Finish exactly once. An accidental second call is rejected and
            /// counted; use `finishIfOpen` for an unconditional defer guard.
            pub fn finish(
                self: *Scope,
                end_ns: u64,
                outcome: Outcome,
            ) RecordResult {
                if (!self.open) return self.owner.history.rejectDuplicateScopeFinish();
                self.open = false;
                return self.owner.finish(self.token, end_ns, outcome);
            }

            /// Intended for `defer`: after an explicit successful finish it is
            /// a no-op, while an early return still emits the supplied outcome.
            pub fn finishIfOpen(
                self: *Scope,
                end_ns: u64,
                outcome: Outcome,
            ) ?RecordResult {
                if (!self.open) return null;
                return self.finish(end_ns, outcome);
            }
        };

        history: History = .{},

        pub fn begin(
            _: *Self,
            phase: Phase,
            frame_index: ?u64,
            tick_index: ?u64,
            start_ns: u64,
        ) SpanToken {
            return .{
                .phase = phase,
                .frame_index = frame_index,
                .tick_index = tick_index,
                .start_ns = start_ns,
            };
        }

        pub fn scoped(
            self: *Self,
            phase: Phase,
            frame_index: ?u64,
            tick_index: ?u64,
            start_ns: u64,
        ) Scope {
            return .{
                .owner = self,
                .token = self.begin(phase, frame_index, tick_index, start_ns),
            };
        }

        pub fn finish(
            self: *Self,
            token: SpanToken,
            end_ns: u64,
            outcome: Outcome,
        ) RecordResult {
            if (end_ns < token.start_ns) return self.history.rejectInvalidInterval();
            return self.history.append(.{
                .phase = token.phase,
                .frame_index = token.frame_index,
                .tick_index = token.tick_index,
                .start_ns = token.start_ns,
                .end_ns = end_ns,
                .duration_ns = end_ns - token.start_ns,
                .outcome = outcome,
            });
        }

        pub fn view(self: *const Self) BorrowedView {
            return self.history.view();
        }

        pub fn stats(self: *const Self) HistoryStats {
            return self.history.stats();
        }

        pub fn clearRetained(self: *Self) void {
            self.history.clearRetained();
        }
    };
}

pub fn FrameRing(comptime capacity_value: usize) type {
    return struct {
        const Self = @This();
        const History = FixedHistory(Frame, capacity_value);

        pub const capacity = capacity_value;
        pub const BorrowedView = History.BorrowedView;

        history: History = .{},

        pub fn begin(
            _: *Self,
            frame_index: u64,
            tick_index: ?u64,
            start_ns: u64,
        ) FrameToken {
            return .{
                .frame_index = frame_index,
                .tick_index = tick_index,
                .start_ns = start_ns,
            };
        }

        pub fn finish(
            self: *Self,
            token: FrameToken,
            end_ns: u64,
            outcome: Outcome,
            counts: Counts,
        ) RecordResult {
            if (end_ns < token.start_ns) return self.history.rejectInvalidInterval();
            return self.history.append(.{
                .frame_index = token.frame_index,
                .tick_index = token.tick_index,
                .start_ns = token.start_ns,
                .end_ns = end_ns,
                .duration_ns = end_ns - token.start_ns,
                .outcome = outcome,
                .counts = counts,
            });
        }

        pub fn view(self: *const Self) BorrowedView {
            return self.history.view();
        }

        pub fn stats(self: *const Self) HistoryStats {
            return self.history.stats();
        }

        pub fn clearRetained(self: *Self) void {
            self.history.clearRetained();
        }
    };
}

/// One host-owned profiler with independently bounded span and frame-count
/// histories. It contains all storage inline and has no initialization or
/// deinitialization path.
pub fn Recorder(
    comptime span_capacity: usize,
    comptime frame_capacity: usize,
) type {
    return struct {
        const Self = @This();

        spans: SpanRing(span_capacity) = .{},
        frames: FrameRing(frame_capacity) = .{},

        pub fn stats(self: *const Self) RecorderStats {
            return .{
                .spans = self.spans.stats(),
                .frames = self.frames.stats(),
            };
        }

        pub fn clearRetained(self: *Self) void {
            self.spans.clearRetained();
            self.frames.clearRetained();
        }
    };
}

pub const DefaultRecorder = Recorder(default_span_capacity, default_frame_capacity);

test "fixed phases retain stable explicit identifiers" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(Phase.input));
    try std.testing.expectEqual(@as(u8, 4), @intFromEnum(Phase.physics));
    try std.testing.expectEqual(@as(u8, 13), @intFromEnum(Phase.submission));
    try std.testing.expectEqual(@as(usize, 14), std.meta.tags(Phase).len);
}

test "nested scopes retain completion order and exact durations" {
    var ring = SpanRing(4){};
    var outer = ring.scoped(.runtime_pre_physics, 3, 7, 100);
    var inner = ring.scoped(.physics, 3, 7, 115);

    const inner_result = inner.finish(145, .success);
    const outer_result = outer.finish(160, .success);
    try std.testing.expect(inner_result.accepted);
    try std.testing.expect(outer_result.accepted);

    const view = ring.view();
    try std.testing.expectEqual(@as(usize, 2), view.len());
    const retained_inner = view.at(0).?.*;
    const retained_outer = view.at(1).?.*;
    try std.testing.expectEqual(@as(u64, 1), retained_inner.sequence);
    try std.testing.expectEqual(Phase.physics, retained_inner.phase);
    try std.testing.expectEqual(@as(?u64, 3), retained_inner.frame_index);
    try std.testing.expectEqual(@as(?u64, 7), retained_inner.tick_index);
    try std.testing.expectEqual(@as(u64, 30), retained_inner.duration_ns);
    try std.testing.expectEqual(@as(u64, 2), retained_outer.sequence);
    try std.testing.expectEqual(Phase.runtime_pre_physics, retained_outer.phase);
    try std.testing.expectEqual(@as(u64, 60), retained_outer.duration_ns);
}

test "defer guard closes a failed span without a fallible path" {
    const Harness = struct {
        fn fail(ring: *SpanRing(2)) error{InjectedFault}!void {
            var scope = ring.scoped(.runtime_commands, null, 11, 1_000);
            defer _ = scope.finishIfOpen(1_075, .failure);
            return error.InjectedFault;
        }
    };

    var ring = SpanRing(2){};
    try std.testing.expectError(error.InjectedFault, Harness.fail(&ring));
    const retained = ring.view().at(0).?.*;
    try std.testing.expectEqual(Outcome.failure, retained.outcome);
    try std.testing.expectEqual(@as(u64, 75), retained.duration_ns);
}

test "overwrite invalid duplicate and exhausted losses remain visible" {
    var ring = SpanRing(2){};
    inline for (0..3) |index| {
        const token = ring.begin(.input, index, null, index * 10);
        const result = ring.finish(token, index * 10 + 5, .success);
        try std.testing.expect(result.accepted);
    }

    var view = ring.view();
    try std.testing.expectEqual(@as(usize, 2), view.len());
    try std.testing.expectEqual(@as(u64, 2), view.at(0).?.sequence);
    try std.testing.expectEqual(@as(u64, 3), view.at(1).?.sequence);
    try std.testing.expectEqual(@as(u64, 1), ring.stats().overwritten);

    const invalid = ring.finish(ring.begin(.physics, 4, 9, 100), 99, .failure);
    try std.testing.expectEqual(Rejection.invalid_interval, invalid.rejection);

    var scope = ring.scoped(.editor, 4, null, 100);
    try std.testing.expect(scope.finish(101, .success).accepted);
    const duplicate = scope.finish(102, .success);
    try std.testing.expectEqual(Rejection.duplicate_scope_finish, duplicate.rejection);
    try std.testing.expect(scope.finishIfOpen(103, .failure) == null);

    ring.history.next_sequence = std.math.maxInt(u64);
    const last = ring.finish(ring.begin(.submission, 5, null, 200), 201, .success);
    try std.testing.expect(last.accepted);
    try std.testing.expectEqual(std.math.maxInt(u64), last.sequence);
    const exhausted = ring.finish(ring.begin(.submission, 5, null, 201), 202, .success);
    try std.testing.expectEqual(Rejection.sequence_exhausted, exhausted.rejection);

    const stats = ring.stats();
    try std.testing.expectEqual(@as(u64, 3), stats.overwritten);
    try std.testing.expectEqual(@as(u64, 3), stats.rejected);
    try std.testing.expectEqual(@as(u64, 1), stats.rejected_invalid_interval);
    try std.testing.expectEqual(@as(u64, 1), stats.rejected_duplicate_scope_finish);
    try std.testing.expectEqual(@as(u64, 1), stats.rejected_sequence_exhausted);
    try std.testing.expect(stats.sequence_exhausted);
}

test "per-frame counts have an independent bounded history" {
    var recorder = Recorder(2, 2){};
    var counts = Counts{};
    counts.merge(.{
        .draw_calls = 7,
        .debug_primitives = 12,
        .debug_upload_bytes = 1_024,
        .streaming_submissions = 2,
        .streaming_publishes = 1,
        .live_resources = 9,
        .live_resource_bytes = 8_192,
    });

    inline for (0..3) |index| {
        const token = recorder.frames.begin(index, index * 2, index * 100);
        const result = recorder.frames.finish(
            token,
            index * 100 + 16,
            .success,
            counts,
        );
        try std.testing.expect(result.accepted);
    }

    const frames = recorder.frames.view();
    try std.testing.expectEqual(@as(usize, 2), frames.len());
    try std.testing.expectEqual(@as(u64, 1), frames.at(0).?.frame_index);
    try std.testing.expectEqual(@as(u64, 2), frames.at(1).?.frame_index);
    try std.testing.expectEqual(@as(u64, 7), frames.at(1).?.counts.draw_calls);
    try std.testing.expectEqual(@as(u64, 1_024), frames.at(1).?.counts.debug_upload_bytes);
    try std.testing.expectEqual(@as(u64, 8_192), frames.at(1).?.counts.live_resource_bytes);

    const stats = recorder.stats();
    try std.testing.expectEqual(@as(u64, 0), stats.spans.overwritten);
    try std.testing.expectEqual(@as(u64, 1), stats.frames.overwritten);
    try std.testing.expectEqual(@as(u64, 0), stats.frames.rejected);
}

test "count merging saturates instead of wrapping" {
    var counts = Counts{
        .draw_calls = std.math.maxInt(u64),
        .debug_upload_bytes = std.math.maxInt(u64) - 1,
    };
    counts.merge(.{ .draw_calls = 1, .debug_upload_bytes = 5 });
    try std.testing.expectEqual(std.math.maxInt(u64), counts.draw_calls);
    try std.testing.expectEqual(std.math.maxInt(u64), counts.debug_upload_bytes);
}

test "clear drops retained samples but preserves sequence and lifetime loss" {
    var recorder = Recorder(1, 1){};

    _ = recorder.spans.finish(
        recorder.spans.begin(.input, 1, null, 10),
        11,
        .success,
    );
    _ = recorder.spans.finish(
        recorder.spans.begin(.physics, 1, 1, 12),
        13,
        .success,
    );
    _ = recorder.frames.finish(
        recorder.frames.begin(1, 1, 10),
        14,
        .success,
        .{ .draw_calls = 1 },
    );
    try std.testing.expectEqual(@as(u64, 1), recorder.spans.stats().overwritten);

    recorder.clearRetained();
    try std.testing.expectEqual(@as(usize, 0), recorder.spans.view().len());
    try std.testing.expectEqual(@as(usize, 0), recorder.frames.view().len());
    try std.testing.expectEqual(@as(u64, 1), recorder.spans.stats().overwritten);

    const span_result = recorder.spans.finish(
        recorder.spans.begin(.submission, 2, null, 20),
        21,
        .success,
    );
    const frame_result = recorder.frames.finish(
        recorder.frames.begin(2, 2, 20),
        22,
        .success,
        .{ .draw_calls = 2 },
    );
    try std.testing.expectEqual(@as(u64, 3), span_result.sequence);
    try std.testing.expectEqual(@as(u64, 2), frame_result.sequence);
    try std.testing.expectEqual(@as(u64, 1), recorder.spans.stats().overwritten);
}
