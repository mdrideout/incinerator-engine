//! Durable sandbox policy for delayed, safe hostile-NPC replacement.
//!
//! The policy owns only bounded replacement records and candidate admission.
//! It never creates an NPC, allocates an identity, or mutates session state.

const std = @import("std");
const engine = @import("incinerator_engine");
const npc = @import("npc_contract");
const contract = @import("sandbox_npc_replacement_contract");

const max_records = contract.max_records;
const max_candidates = contract.max_candidates;
const max_outcomes = contract.max_outcomes;
const Config = contract.Config;
const Status = contract.Status;
const RecordV1 = contract.RecordV1;
const Schedule = contract.Schedule;
const RetryReason = contract.RetryReason;
const Outcome = contract.Outcome;
const Diagnostics = contract.Diagnostics;

const RuntimeRecord = struct {
    persisted: RecordV1,
    ready_announced: bool = false,
};

pub fn Policy(comptime Access: type) type {
    assertAccess(Access);
    return struct {
        const Self = @This();

        access: *Access,
        config: Config,
        records: [max_records]RuntimeRecord = undefined,
        record_count: usize = 0,
        outcomes: engine.BoundedQueue(Outcome, max_outcomes) = .{},
        outcomes_high_water: u16 = 0,
        attempts: u64 = 0,
        replacements_ready: u64 = 0,
        retries: u64 = 0,
        district_inactive: u64 = 0,
        occupied: u64 = 0,
        too_close_to_player: u64 = 0,
        visible_to_player: u64 = 0,

        pub fn init(access: *Access, config: Config) !Self {
            try config.validate();
            return .{ .access = access, .config = config };
        }

        pub fn deinit(self: *Self) void {
            self.* = undefined;
        }

        pub fn schedule(self: *Self, value: Schedule) !void {
            if (value.slot >= max_records or value.generation == 0 or
                value.available_tick == 0 or value.candidates.len == 0 or
                value.candidates.len > max_candidates)
            {
                return error.InvalidNpcReplacementSchedule;
            }
            if (self.find(value.slot) != null) return error.DuplicateNpcReplacementSchedule;
            if (self.record_count == max_records) return error.NpcReplacementCapacityReached;

            var record = RecordV1{
                .slot = value.slot,
                .generation = value.generation,
                .available_tick = value.available_tick,
                .next_attempt_tick = value.available_tick,
                .status = .pending,
                .candidate_count = @intCast(value.candidates.len),
                .candidates = @splat(.{}),
            };
            for (value.candidates, 0..) |candidate, index| {
                try contract.validateNode(candidate);
                for (value.candidates[0..index]) |earlier| {
                    if (npc.NodeRef.eql(earlier, candidate)) {
                        return error.DuplicateNpcReplacementCandidate;
                    }
                }
                record.candidates[index] = candidate;
            }
            self.records[self.record_count] = .{ .persisted = record };
            self.record_count += 1;
            std.mem.sort(RuntimeRecord, self.records[0..self.record_count], {}, lessThanRecord);
        }

        pub fn step(self: *Self, tick: u64) !void {
            if (tick == 0) return error.InvalidNpcReplacementTick;
            if (self.outcomes.len != 0) return error.NpcReplacementOutcomesPending;
            for (self.records[0..self.record_count]) |*runtime_record| {
                const record = &runtime_record.persisted;
                if (record.status == .awaiting_spawn) {
                    if (!runtime_record.ready_announced) {
                        try self.emit(.{ .ready = .{
                            .slot = record.slot,
                            .generation = record.generation,
                            .node = record.candidates[0],
                        } });
                        runtime_record.ready_announced = true;
                    }
                    continue;
                }
                if (tick < record.available_tick or tick < record.next_attempt_tick) continue;

                self.attempts +|= 1;
                var last_reason: RetryReason = .district_inactive;
                for (record.candidates[0..record.candidate_count], 0..) |candidate, candidate_index| {
                    const position = try self.access.nodePosition(candidate) orelse {
                        last_reason = .district_inactive;
                        continue;
                    };
                    if (!try self.access.spawnClear(position)) {
                        last_reason = .occupied;
                        continue;
                    }
                    if (try self.access.playerConflict(
                        position,
                        self.config.minimum_player_distance,
                        self.config.visibility_radius,
                    )) |reason| {
                        last_reason = reason;
                        continue;
                    }
                    record.status = .awaiting_spawn;
                    // The selected stable candidate becomes the first entry so
                    // an awaiting record can replay the same ready decision.
                    const first = record.candidates[0];
                    record.candidates[0] = candidate;
                    record.candidates[candidate_index] = first;
                    runtime_record.ready_announced = true;
                    self.replacements_ready +|= 1;
                    try self.emit(.{ .ready = .{
                        .slot = record.slot,
                        .generation = record.generation,
                        .node = candidate,
                    } });
                    break;
                } else {
                    record.next_attempt_tick = tick +| self.config.retry_ticks;
                    self.retries +|= 1;
                    self.countReason(last_reason);
                    try self.emit(.{ .deferred = .{
                        .slot = record.slot,
                        .generation = record.generation,
                        .reason = last_reason,
                        .next_attempt_tick = record.next_attempt_tick,
                    } });
                }
            }
        }

        pub fn complete(self: *Self, slot: u8, generation: u16) !void {
            const index = self.find(slot) orelse return error.NpcReplacementNotFound;
            if (self.records[index].persisted.generation != generation or
                self.records[index].persisted.status != .awaiting_spawn)
            {
                return error.StaleNpcReplacementCompletion;
            }
            self.remove(index);
        }

        pub fn deferSpawn(self: *Self, slot: u8, generation: u16, tick: u64) !void {
            const index = self.find(slot) orelse return error.NpcReplacementNotFound;
            const runtime_record = &self.records[index];
            if (runtime_record.persisted.generation != generation or
                runtime_record.persisted.status != .awaiting_spawn)
            {
                return error.StaleNpcReplacementDeferral;
            }
            runtime_record.persisted.status = .pending;
            runtime_record.persisted.next_attempt_tick = tick +| self.config.retry_ticks;
            runtime_record.ready_announced = false;
        }

        pub fn pollOutcome(self: *Self) ?Outcome {
            return self.outcomes.pop();
        }

        pub fn peekOutcome(self: *const Self) ?Outcome {
            return self.outcomes.peek();
        }

        /// The owner thread must remain exclusive between peek and commit.
        pub fn commitOutcome(self: *Self, expected: Outcome) !void {
            const actual = self.outcomes.peek() orelse
                return error.NpcReplacementOutcomeMissing;
            if (!std.meta.eql(actual, expected)) {
                return error.NpcReplacementOutcomeCommitMismatch;
            }
            _ = self.outcomes.pop().?;
        }

        pub fn snapshotRecords(self: *const Self, allocator: std.mem.Allocator) ![]RecordV1 {
            if (self.outcomes.len != 0) return error.NpcReplacementOutcomesPending;
            const result = try allocator.alloc(RecordV1, self.record_count);
            errdefer allocator.free(result);
            for (self.records[0..self.record_count], 0..) |record, index| {
                result[index] = record.persisted;
                try contract.validateRecord(result[index]);
            }
            return result;
        }

        pub fn restoreRecords(self: *Self, records: []const RecordV1) !void {
            if (self.record_count != 0 or self.outcomes.len != 0) {
                return error.NpcReplacementRestoreNotCold;
            }
            if (records.len > max_records) return error.TooManyNpcReplacementRecords;
            for (records, 0..) |record, index| {
                try contract.validateRecord(record);
                if (index != 0 and records[index - 1].slot >= record.slot) {
                    return error.NpcReplacementRecordsNotCanonical;
                }
                self.records[index] = .{ .persisted = record };
            }
            self.record_count = records.len;
        }

        pub fn writeLogicalState(
            self: *const Self,
            writer: *engine.contracts.replay.Writer,
        ) void {
            const domain = "incinerator.sandbox.npc_replacement.logical";
            writer.writeU8(@intCast(domain.len));
            writer.writeBytes(domain);
            writer.writeU16(1);
            writer.writeU32(@intCast(self.record_count));
            for (self.records[0..self.record_count]) |runtime_record| {
                const record = runtime_record.persisted;
                writer.writeU8(record.slot);
                writer.writeU16(record.generation);
                writer.writeU64(record.available_tick);
                writer.writeU64(record.next_attempt_tick);
                writer.writeU8(@intFromEnum(record.status));
                writer.writeU8(record.candidate_count);
                for (record.candidates[0..record.candidate_count]) |candidate| {
                    writer.writeI32(candidate.coord.x);
                    writer.writeI32(candidate.coord.z);
                    writer.writeU8(candidate.index);
                }
            }
        }

        pub fn diagnostics(self: *const Self) Diagnostics {
            var pending: u16 = 0;
            var awaiting: u16 = 0;
            for (self.records[0..self.record_count]) |record| switch (record.persisted.status) {
                .pending => pending += 1,
                .awaiting_spawn => awaiting += 1,
            };
            return .{
                .pending = pending,
                .awaiting_spawn = awaiting,
                .attempts = self.attempts,
                .replacements_ready = self.replacements_ready,
                .retries = self.retries,
                .district_inactive = self.district_inactive,
                .occupied = self.occupied,
                .too_close_to_player = self.too_close_to_player,
                .visible_to_player = self.visible_to_player,
                .outcomes_pending = @intCast(self.outcomes.len),
                .outcomes_high_water = self.outcomes_high_water,
            };
        }

        fn emit(self: *Self, outcome: Outcome) !void {
            if (self.outcomes.isFull()) return error.NpcReplacementOutcomeQueueFull;
            self.outcomes.pushAssumeCapacity(outcome);
            self.outcomes_high_water = @max(
                self.outcomes_high_water,
                @as(u16, @intCast(self.outcomes.len)),
            );
        }

        fn countReason(self: *Self, reason: RetryReason) void {
            switch (reason) {
                .district_inactive => self.district_inactive +|= 1,
                .occupied => self.occupied +|= 1,
                .too_close_to_player => self.too_close_to_player +|= 1,
                .visible_to_player => self.visible_to_player +|= 1,
            }
        }

        fn find(self: *const Self, slot: u8) ?usize {
            for (self.records[0..self.record_count], 0..) |record, index| {
                if (record.persisted.slot == slot) return index;
            }
            return null;
        }

        fn remove(self: *Self, index: usize) void {
            for (index + 1..self.record_count) |source| {
                self.records[source - 1] = self.records[source];
            }
            self.record_count -= 1;
        }
    };
}

fn lessThanRecord(_: void, lhs: RuntimeRecord, rhs: RuntimeRecord) bool {
    return lhs.persisted.slot < rhs.persisted.slot;
}

fn assertAccess(comptime Access: type) void {
    comptime {
        assertFallibleMethod(Access, "nodePosition", .{ *Access, npc.NodeRef }, ?[3]f32);
        assertFallibleMethod(Access, "spawnClear", .{ *Access, [3]f32 }, bool);
        assertFallibleMethod(
            Access,
            "playerConflict",
            .{ *Access, [3]f32, f32, f32 },
            ?RetryReason,
        );
    }
}

fn assertFallibleMethod(
    comptime Access: type,
    comptime name: []const u8,
    comptime params: anytype,
    comptime Payload: type,
) void {
    if (!@hasDecl(Access, name)) @compileError("NPC replacement access missing " ++ name);
    const info = @typeInfo(@TypeOf(@field(Access, name))).@"fn";
    if (info.params.len != params.len) @compileError("NPC replacement access arity mismatch");
    inline for (params, 0..) |expected, index| {
        if (info.params[index].type == null or info.params[index].type.? != expected) {
            @compileError("NPC replacement access parameter mismatch");
        }
    }
    const return_type = info.return_type orelse
        @compileError("NPC replacement access return missing");
    const payload = switch (@typeInfo(return_type)) {
        .error_union => |error_union| error_union.payload,
        else => @compileError("NPC replacement access must be fallible"),
    };
    if (payload != Payload) {
        @compileError("NPC replacement access return mismatch");
    }
}

const TestAccess = struct {
    conflict: ?RetryReason = null,
    clear: bool = true,

    pub fn nodePosition(_: *TestAccess, node: npc.NodeRef) !?[3]f32 {
        return .{ @floatFromInt(node.index), 0, 0 };
    }

    pub fn spawnClear(self: *TestAccess, _: [3]f32) !bool {
        return self.clear;
    }

    pub fn playerConflict(
        self: *TestAccess,
        _: [3]f32,
        _: f32,
        _: f32,
    ) !?RetryReason {
        return self.conflict;
    }
};

test "replacement retries deterministically then emits one stable ready decision" {
    var access = TestAccess{ .conflict = .visible_to_player };
    var policy = try Policy(TestAccess).init(&access, .{
        .retry_ticks = 2,
        .minimum_player_distance = 2,
        .visibility_radius = 5,
    });
    defer policy.deinit();
    try policy.schedule(.{
        .slot = 2,
        .generation = 4,
        .available_tick = 3,
        .candidates = &.{
            .{ .coord = .{ .x = 0, .z = 0 }, .index = 1 },
            .{ .coord = .{ .x = 0, .z = 0 }, .index = 2 },
        },
    });
    try policy.step(3);
    try std.testing.expectEqual(
        RetryReason.visible_to_player,
        policy.pollOutcome().?.deferred.reason,
    );
    access.conflict = null;
    try policy.step(4);
    try std.testing.expect(policy.pollOutcome() == null);
    try policy.step(5);
    const ready = policy.pollOutcome().?.ready;
    try std.testing.expectEqual(@as(u8, 1), ready.node.index);
    try policy.complete(ready.slot, ready.generation);
    try std.testing.expectEqual(@as(u16, 0), policy.diagnostics().pending);
}

test "awaiting replacement survives canonical restore and reannounces" {
    var access = TestAccess{};
    var source = try Policy(TestAccess).init(&access, .{
        .retry_ticks = 2,
        .minimum_player_distance = 2,
        .visibility_radius = 5,
    });
    defer source.deinit();
    try source.schedule(.{
        .slot = 1,
        .generation = 2,
        .available_tick = 1,
        .candidates = &.{.{ .coord = .{ .x = 0, .z = 0 }, .index = 0 }},
    });
    try source.step(1);
    _ = source.pollOutcome();
    const records = try source.snapshotRecords(std.testing.allocator);
    defer std.testing.allocator.free(records);

    var restored = try Policy(TestAccess).init(&access, source.config);
    defer restored.deinit();
    try restored.restoreRecords(records);
    try restored.step(2);
    try std.testing.expectEqual(@as(u16, 2), restored.pollOutcome().?.ready.generation);
}
