//! Bounded deterministic vitals authority for player and NPC avatars.

const std = @import("std");
const engine = @import("incinerator_engine");
const contract = @import("vitals_contract");

const QueuedCommand = struct {
    command: contract.Command,
    eligible_tick: u64,
};

const Record = struct {
    target: contract.Target,
    current_health: u16,
    maximum_health: u16,
    life_state: contract.LifeState,
    death_tick: u64,
};

pub fn Feature() type {
    return struct {
        const Self = @This();

        runtime: *engine.Runtime,
        records: [contract.max_records]Record = undefined,
        record_count: u8 = 0,
        commands: engine.BoundedQueue(QueuedCommand, contract.max_pending_commands) = .{},
        outcomes: engine.BoundedQueue(contract.Outcome, contract.max_outcomes) = .{},
        events: engine.BoundedQueue(contract.Event, contract.max_events) = .{},
        proposals: [contract.max_pending_commands]contract.DamageProposal = undefined,
        proposal_count: u16 = 0,
        applied_facts: [contract.max_pending_commands]contract.AppliedDamageFact = undefined,
        applied_fact_count: u16 = 0,
        proposals_applied: u64 = 0,
        proposals_rejected: u64 = 0,
        deaths: u64 = 0,

        pub fn init(runtime: *engine.Runtime) Self {
            return .{ .runtime = runtime };
        }

        pub fn register(self: *Self, registry: *engine.FeatureRegistry) !void {
            try registry.addSystem(.post_physics, "vitals.apply", self, applySystem);
        }

        pub fn deinit(self: *Self) void {
            self.* = undefined;
        }

        pub fn enqueue(self: *Self, command: contract.Command) !void {
            try self.runtime.ensureHealthy();
            try validateCommand(command);
            if (self.commands.isFull() or
                self.commands.len + self.outcomes.len >= contract.max_outcomes)
            {
                return error.VitalsCommandQueueFull;
            }
            try self.commands.push(.{
                .command = command,
                .eligible_tick = try self.runtime.commandTargetTick(),
            });
        }

        pub fn pollOutcome(self: *Self) ?contract.Outcome {
            return self.outcomes.pop();
        }

        pub fn peekOutcome(self: *const Self) ?contract.Outcome {
            return self.outcomes.peek();
        }

        /// The owner thread must remain exclusive between peek and commit.
        pub fn commitOutcome(self: *Self, expected: contract.Outcome) !void {
            const actual = self.outcomes.peek() orelse return error.VitalsOutcomeMissing;
            if (!std.meta.eql(actual, expected)) return error.VitalsOutcomeCommitMismatch;
            _ = self.outcomes.pop().?;
        }

        pub fn pollEvent(self: *Self) ?contract.Event {
            return self.events.pop();
        }

        pub fn peekEvent(self: *const Self) ?contract.Event {
            return self.events.peek();
        }

        /// The owner thread must remain exclusive between peek and commit.
        pub fn commitEvent(self: *Self, expected: contract.Event) !void {
            const actual = self.events.peek() orelse return error.VitalsEventMissing;
            if (!std.meta.eql(actual, expected)) return error.VitalsEventCommitMismatch;
            _ = self.events.pop().?;
        }

        pub fn hasPendingCommands(self: *const Self) bool {
            return self.commands.len != 0;
        }

        pub fn view(self: *const Self, target: contract.Target) ?contract.View {
            const index = self.findExact(target) orelse return null;
            return viewRecord(self.records[index]);
        }

        pub fn viewCurrent(
            self: *const Self,
            kind: contract.TargetKind,
            id: engine.PersistentId,
        ) ?contract.View {
            for (self.records[0..self.record_count]) |record| {
                if (record.target.kind == kind and std.meta.eql(record.target.id, id)) {
                    return viewRecord(record);
                }
            }
            return null;
        }

        pub fn copyAppliedDamage(
            self: *const Self,
            storage: []contract.AppliedDamageFact,
        ) ![]const contract.AppliedDamageFact {
            if (storage.len < self.applied_fact_count) {
                return error.InsufficientAppliedDamageStorage;
            }
            @memcpy(storage[0..self.applied_fact_count], self.applied_facts[0..self.applied_fact_count]);
            return storage[0..self.applied_fact_count];
        }

        pub fn snapshotRecords(
            self: *const Self,
            allocator: std.mem.Allocator,
        ) ![]contract.VitalsV1 {
            try self.runtime.ensureSnapshotBoundary();
            if (self.commands.len != 0) return error.CommandsPending;
            const result = try allocator.alloc(contract.VitalsV1, self.record_count);
            for (self.records[0..self.record_count], 0..) |record, index| {
                result[index] = .{
                    .target = record.target,
                    .current_health = record.current_health,
                    .maximum_health = record.maximum_health,
                    .life_state = record.life_state,
                    .death_tick = record.death_tick,
                };
            }
            std.mem.sort(contract.VitalsV1, result, {}, lessThanSnapshot);
            return result;
        }

        pub fn restoreRecords(self: *Self, records: []const contract.VitalsV1) !void {
            try contract.validateRecords(records);
            if (self.record_count != 0 or self.commands.len != 0) {
                return error.VitalsRestoreNotCold;
            }
            for (records) |record| {
                self.records[self.record_count] = .{
                    .target = record.target,
                    .current_health = record.current_health,
                    .maximum_health = record.maximum_health,
                    .life_state = record.life_state,
                    .death_tick = record.death_tick,
                };
                self.record_count += 1;
            }
        }

        pub fn diagnostics(self: *const Self) contract.Diagnostics {
            var alive: u16 = 0;
            for (self.records[0..self.record_count]) |record| {
                alive += @intFromBool(record.life_state == .alive);
            }
            return .{
                .active_records = self.record_count,
                .alive_records = alive,
                .pending_commands = @intCast(self.commands.len),
                .outcomes = @intCast(self.outcomes.len),
                .events = @intCast(self.events.len),
                .proposals_applied = self.proposals_applied,
                .proposals_rejected = self.proposals_rejected,
                .deaths = self.deaths,
            };
        }

        fn applySystem(raw: *anyopaque, _: *engine.Runtime, context: engine.TickContext) !void {
            const self: *Self = @ptrCast(@alignCast(raw));
            self.proposal_count = 0;
            self.applied_fact_count = 0;
            while (self.commands.peek()) |queued| {
                if (queued.eligible_tick > context.tick_index) break;
                const command = self.commands.pop().?;
                switch (command.command) {
                    .register => |value| try self.applyRegister(value),
                    .remove => |target| try self.applyRemove(target),
                    .damage => |proposal| {
                        self.proposals[self.proposal_count] = proposal;
                        self.proposal_count += 1;
                    },
                }
            }
            std.mem.sort(
                contract.DamageProposal,
                self.proposals[0..self.proposal_count],
                {},
                lessThanProposal,
            );
            for (self.proposals[0..self.proposal_count]) |proposal| {
                try self.applyDamage(proposal, context.tick_index);
            }
            self.proposal_count = 0;
        }

        fn applyRegister(self: *Self, value: contract.Register) !void {
            if (self.findExact(value.target) != null) {
                return self.pushOutcome(.{ .rejected = .{
                    .target = value.target,
                    .reason = .duplicate_target,
                } });
            }
            if (self.findByIdentity(value.target.kind, value.target.id) != null) {
                return self.pushOutcome(.{ .rejected = .{
                    .target = value.target,
                    .reason = .stale_incarnation,
                } });
            }
            if (self.record_count == self.records.len) {
                return self.pushOutcome(.{ .rejected = .{
                    .target = value.target,
                    .reason = .capacity_reached,
                } });
            }
            self.records[self.record_count] = .{
                .target = value.target,
                .current_health = value.current_health,
                .maximum_health = value.maximum_health,
                .life_state = value.life_state,
                .death_tick = value.death_tick,
            };
            self.record_count += 1;
            try self.pushOutcome(.{ .registered = value.target });
        }

        fn applyRemove(self: *Self, target: contract.Target) !void {
            const index = self.findExact(target) orelse {
                const reason: contract.RejectionReason = if (self.findByIdentity(
                    target.kind,
                    target.id,
                ) != null) .stale_incarnation else .target_missing;
                return self.pushOutcome(.{ .rejected = .{ .target = target, .reason = reason } });
            };
            const removed = self.records[index].target;
            const last = @as(usize, self.record_count) - 1;
            self.records[index] = self.records[last];
            self.record_count -= 1;
            try self.pushOutcome(.{ .removed = removed });
        }

        fn applyDamage(
            self: *Self,
            proposal: contract.DamageProposal,
            tick_index: u64,
        ) !void {
            var outcome = contract.DamageOutcome{
                .proposal = proposal,
                .disposition = .target_missing,
            };
            const index = self.findExact(proposal.target) orelse {
                if (self.findByIdentity(proposal.target.kind, proposal.target.id) != null) {
                    outcome.disposition = .stale_incarnation;
                }
                self.proposals_rejected +|= 1;
                return self.pushOutcome(.{ .damage = outcome });
            };
            const record = &self.records[index];
            outcome.remaining_health = record.current_health;
            if (record.life_state == .dead) {
                outcome.disposition = .already_dead;
                self.proposals_rejected +|= 1;
                return self.pushOutcome(.{ .damage = outcome });
            }
            const applied = @min(proposal.base_amount, record.current_health);
            record.current_health -= applied;
            outcome.disposition = .applied;
            outcome.applied_amount = applied;
            outcome.remaining_health = record.current_health;
            self.proposals_applied +|= 1;
            if (record.current_health == 0) {
                record.life_state = .dead;
                record.death_tick = tick_index;
                outcome.killed = true;
                self.deaths +|= 1;
                try self.pushEvent(.{ .died = .{
                    .target = record.target,
                    .source = proposal.source,
                    .cause = proposal.cause,
                    .authority_tick = tick_index,
                    .correlation = proposal.correlation,
                } });
            }
            self.applied_facts[self.applied_fact_count] = .{
                .source = proposal.source,
                .target = proposal.target,
                .authority_tick = tick_index,
                .applied_amount = outcome.applied_amount,
                .remaining_health = outcome.remaining_health,
                .killed = outcome.killed,
            };
            self.applied_fact_count += 1;
            try self.pushOutcome(.{ .damage = outcome });
        }

        fn findExact(self: *const Self, target: contract.Target) ?usize {
            for (self.records[0..self.record_count], 0..) |record, index| {
                if (std.meta.eql(record.target, target)) return index;
            }
            return null;
        }

        fn findByIdentity(
            self: *const Self,
            kind: contract.TargetKind,
            id: engine.PersistentId,
        ) ?usize {
            for (self.records[0..self.record_count], 0..) |record, index| {
                if (record.target.kind == kind and std.meta.eql(record.target.id, id)) return index;
            }
            return null;
        }

        fn pushOutcome(self: *Self, outcome: contract.Outcome) !void {
            if (self.outcomes.isFull()) return error.VitalsOutcomeQueueFull;
            try self.outcomes.push(outcome);
        }

        fn pushEvent(self: *Self, event: contract.Event) !void {
            if (self.events.isFull()) return error.VitalsEventQueueFull;
            try self.events.push(event);
        }
    };
}

fn validateCommand(command: contract.Command) !void {
    switch (command) {
        .register => |value| try contract.validateRegister(value),
        .remove => |target| try target.validate(),
        .damage => |value| try value.validate(),
    }
}

fn viewRecord(record: Record) contract.View {
    return .{
        .target = record.target,
        .current_health = record.current_health,
        .maximum_health = record.maximum_health,
        .life_state = record.life_state,
        .death_tick = record.death_tick,
    };
}

fn lessThanProposal(_: void, lhs: contract.DamageProposal, rhs: contract.DamageProposal) bool {
    if (lhs.target.id.namespace != rhs.target.id.namespace) {
        return lhs.target.id.namespace < rhs.target.id.namespace;
    }
    if (lhs.target.id.local != rhs.target.id.local) {
        return lhs.target.id.local < rhs.target.id.local;
    }
    if (lhs.cause.priority() != rhs.cause.priority()) {
        return lhs.cause.priority() < rhs.cause.priority();
    }
    if (lhs.source.id.namespace != rhs.source.id.namespace) {
        return lhs.source.id.namespace < rhs.source.id.namespace;
    }
    if (lhs.source.id.local != rhs.source.id.local) {
        return lhs.source.id.local < rhs.source.id.local;
    }
    if (lhs.source.action_sequence != rhs.source.action_sequence) {
        return lhs.source.action_sequence < rhs.source.action_sequence;
    }
    return lhs.ordinal < rhs.ordinal;
}

fn lessThanSnapshot(_: void, lhs: contract.VitalsV1, rhs: contract.VitalsV1) bool {
    if (lhs.target.id.namespace != rhs.target.id.namespace) {
        return lhs.target.id.namespace < rhs.target.id.namespace;
    }
    if (lhs.target.id.local != rhs.target.id.local) return lhs.target.id.local < rhs.target.id.local;
    if (lhs.target.kind != rhs.target.kind) return @intFromEnum(lhs.target.kind) < @intFromEnum(rhs.target.kind);
    return lhs.target.incarnation.value < rhs.target.incarnation.value;
}

test "same-tick overkill clamps and emits exactly one death" {
    var runtime = try engine.Runtime.init(std.testing.allocator, .{
        .namespace = 1,
        .fixed_delta_seconds = 1.0 / 60.0,
    });
    defer runtime.deinit();
    var feature = Feature().init(&runtime);
    defer feature.deinit();
    var registry = runtime.registry();
    try feature.register(&registry);
    runtime.finishRegistration();

    const target = contract.Target{
        .kind = .player,
        .id = .{ .namespace = 1, .local = 2 },
        .incarnation = .{ .value = 1 },
    };
    const source = contract.Source{
        .kind = .player,
        .id = .{ .namespace = 1, .local = 1 },
        .incarnation = .{ .value = 1 },
        .action_sequence = 1,
    };
    try feature.enqueue(.{ .register = .{ .target = target } });
    try runtime.tick();
    _ = feature.pollOutcome();
    try feature.enqueue(.{ .damage = .{
        .source = source,
        .target = target,
        .cause = .melee,
        .authority_tick = 2,
        .correlation = 1,
        .base_amount = 70,
        .ordinal = 2,
    } });
    var second = source;
    second.kind = .npc;
    second.id.local = 3;
    try feature.enqueue(.{ .damage = .{
        .source = second,
        .target = target,
        .cause = .npc_melee,
        .authority_tick = 2,
        .correlation = 2,
        .base_amount = 70,
        .ordinal = 1,
    } });
    try runtime.tick();
    const first_outcome = feature.pollOutcome().?.damage;
    const second_outcome = feature.pollOutcome().?.damage;
    try std.testing.expect(first_outcome.killed or second_outcome.killed);
    try std.testing.expect(!(first_outcome.killed and second_outcome.killed));
    try std.testing.expectEqual(@as(u16, 0), feature.view(target).?.current_health);
    _ = feature.pollEvent().?.died;
    try std.testing.expect(feature.pollEvent() == null);
}
