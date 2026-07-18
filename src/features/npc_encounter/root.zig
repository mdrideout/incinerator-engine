//! Bounded authoritative NPC perception, behavior, and melee intent.

const std = @import("std");
const engine = @import("incinerator_engine");
const contract = @import("npc_encounter_contract");
const vitals = @import("vitals_contract");

const FixedQueue = engine.BoundedQueue;

const Record = struct {
    npc: vitals.Target,
    state: contract.State = .patrolling,
    state_enter_tick: u64,
    target: ?vitals.Target = null,
    encounter_origin: [3]f32,
    last_seen_position: [3]f32,
    last_seen_tick: u64 = 0,
    forget_tick: u64 = 0,
    attack_impact_tick: u64 = 0,
    ready_tick: u64 = 0,
    death_presentation_until_tick: u64 = 0,
    attack_sequence: u32 = 1,
    last_health: u16,
    alive: bool,
    recent_damage_instigator: ?vitals.Target = null,
    recent_damage_tick: u64 = 0,
    next_perception_tick: u64,
    target_visible: bool = false,
    force_perception: bool = false,
    last_directive_tick: u64 = 0,
    last_directive: ?contract.Locomotion = null,
};

const PerceptionCandidate = struct {
    observation: contract.CombatantObservation,
    threat_tier: u8,
    distance_squared: f32,
};

pub fn Feature(comptime Visibility: type) type {
    contract.assertVisibilityImplementation(Visibility);

    return struct {
        const Self = @This();

        visibility: *Visibility,
        config: contract.Config,
        records: [contract.max_records]Record = undefined,
        record_count: usize = 0,
        directives: FixedQueue(contract.LocomotionDirective, contract.max_directives) = .{},
        damage: FixedQueue(vitals.DamageProposal, contract.max_damage_proposals) = .{},
        cues: FixedQueue(contract.Cue, contract.max_cues) = .{},
        transitions: FixedQueue(contract.Transition, contract.max_transition_history) = .{},
        candidates_considered: u64 = 0,
        los_queries: u64 = 0,
        los_deferred: u64 = 0,
        targets_acquired: u64 = 0,
        targets_switched: u64 = 0,
        targets_lost: u64 = 0,
        attacks_started: u64 = 0,
        attacks_committed: u64 = 0,
        attacks_cancelled: u64 = 0,
        hit_reactions: u64 = 0,

        pub fn init(visibility: *Visibility, config: contract.Config) !Self {
            try config.validate();
            return .{ .visibility = visibility, .config = config };
        }

        pub fn deinit(self: *Self) void {
            self.* = undefined;
        }

        pub fn step(self: *Self, frame: contract.Frame) !void {
            try frame.validate();
            if (self.directives.len != 0 or self.damage.len != 0 or self.cues.len != 0) {
                return error.NpcEncounterOutputsPending;
            }
            try self.synchronize(frame);
            try self.applyDamageFacts(frame);

            var los_remaining: u8 = self.config.los_queries_per_tick;
            const start = perceptionStartIndex(
                frame.tick,
                self.record_count,
                self.config,
            );
            var offset: usize = 0;
            while (offset < self.record_count) : (offset += 1) {
                const index = (start + offset) % self.record_count;
                const record = &self.records[index];
                const npc = findNpc(frame.npcs, record.npc) orelse
                    return error.NpcEncounterRecordMissingObservation;
                if (!npc.alive) continue;
                if (!npc.available) {
                    try self.suspendForNavigation(record, frame.tick);
                    continue;
                }

                var npc_los_remaining = @min(
                    los_remaining,
                    self.config.los_queries_per_npc,
                );
                try self.updatePerception(
                    record,
                    npc,
                    frame,
                    &los_remaining,
                    &npc_los_remaining,
                );
                try self.advanceRecord(
                    record,
                    npc,
                    frame,
                    &los_remaining,
                    &npc_los_remaining,
                );
            }
        }

        pub fn pollDirective(self: *Self) ?contract.LocomotionDirective {
            return self.directives.pop();
        }

        pub fn pollDamage(self: *Self) ?vitals.DamageProposal {
            return self.damage.pop();
        }

        pub fn pollCue(self: *Self) ?contract.Cue {
            return self.cues.pop();
        }

        pub fn pollTransition(self: *Self) ?contract.Transition {
            return self.transitions.pop();
        }

        pub fn copyTransitions(
            self: *const Self,
            storage: []contract.Transition,
        ) ![]const contract.Transition {
            if (storage.len < self.transitions.len) {
                return error.InsufficientNpcEncounterTransitionStorage;
            }
            for (0..self.transitions.len) |index| {
                storage[index] = self.transitions.atAssumeValid(index);
            }
            return storage[0..self.transitions.len];
        }

        pub fn view(self: *const Self, npc: vitals.Target) ?contract.View {
            const index = self.findRecord(npc) orelse return null;
            return viewRecord(self.records[index]);
        }

        pub fn views(self: *const Self, storage: []contract.View) ![]const contract.View {
            if (storage.len < self.record_count) return error.InsufficientNpcEncounterViewStorage;
            for (self.records[0..self.record_count], 0..) |record, index| {
                storage[index] = viewRecord(record);
            }
            return storage[0..self.record_count];
        }

        pub fn snapshotRecords(
            self: *const Self,
            allocator: std.mem.Allocator,
        ) ![]contract.RecordV1 {
            if (self.directives.len != 0 or self.damage.len != 0 or self.cues.len != 0) {
                return error.NpcEncounterOutputsPending;
            }
            const result = try allocator.alloc(contract.RecordV1, self.record_count);
            errdefer allocator.free(result);
            for (self.records[0..self.record_count], 0..) |record, index| {
                result[index] = persistedRecord(record);
                try contract.validateRecord(result[index]);
            }
            return result;
        }

        pub fn restoreRecords(self: *Self, records: []const contract.RecordV1) !void {
            if (self.record_count != 0 or self.directives.len != 0 or
                self.damage.len != 0 or self.cues.len != 0)
            {
                return error.NpcEncounterRestoreNotCold;
            }
            if (records.len > contract.max_records) return error.TooManyNpcEncounterRecords;
            for (records, 0..) |record, index| {
                try contract.validateRecord(record);
                if (index != 0 and !contract.lessThanTarget(
                    {},
                    records[index - 1].npc,
                    record.npc,
                )) return error.NpcEncounterRecordsNotCanonical;
                self.records[index] = runtimeRecord(record);
            }
            self.record_count = records.len;
        }

        pub fn writeLogicalState(
            self: *const Self,
            writer: *engine.contracts.replay.Writer,
        ) !void {
            const domain = "incinerator.npc_encounter.logical";
            writer.writeU8(@intCast(domain.len));
            writer.writeBytes(domain);
            writer.writeU16(1);
            writer.writeU32(@intCast(self.record_count));
            for (self.records[0..self.record_count]) |record| {
                writeTarget(writer, record.npc);
                writer.writeU8(@intFromEnum(record.state));
                writer.writeU64(record.state_enter_tick);
                writer.writeBool(record.target != null);
                if (record.target) |target| writeTarget(writer, target);
                try writeVector(writer, record.encounter_origin);
                try writeVector(writer, record.last_seen_position);
                writer.writeU64(record.last_seen_tick);
                writer.writeU64(record.forget_tick);
                writer.writeU64(record.attack_impact_tick);
                writer.writeU64(record.ready_tick);
                writer.writeU64(record.death_presentation_until_tick);
                writer.writeU32(record.attack_sequence);
                writer.writeU16(record.last_health);
                writer.writeBool(record.alive);
                writer.writeBool(record.recent_damage_instigator != null);
                if (record.recent_damage_instigator) |instigator| {
                    writeTarget(writer, instigator);
                }
                writer.writeU64(record.recent_damage_tick);
                writer.writeU64(record.next_perception_tick);
                writer.writeBool(record.target_visible);
                writer.writeBool(record.force_perception);
                writer.writeU64(record.last_directive_tick);
                writer.writeBool(record.last_directive != null);
                if (record.last_directive) |locomotion| {
                    try writeDirective(writer, .{ .npc = record.npc, .locomotion = locomotion });
                }
            }
            writer.writeU32(@intCast(self.directives.len));
            for (0..self.directives.len) |index| {
                try writeDirective(writer, self.directives.atAssumeValid(index));
            }
            writer.writeU32(@intCast(self.damage.len));
            for (0..self.damage.len) |index| writeDamage(writer, self.damage.atAssumeValid(index));
            writer.writeU32(@intCast(self.cues.len));
        }

        pub fn diagnostics(self: *const Self) contract.Diagnostics {
            var result = contract.Diagnostics{
                .records = @intCast(self.record_count),
                .patrolling = 0,
                .pursuing = 0,
                .attack_windup = 0,
                .attack_recovery = 0,
                .searching = 0,
                .returning = 0,
                .candidates_considered = self.candidates_considered,
                .los_queries = self.los_queries,
                .los_deferred = self.los_deferred,
                .targets_acquired = self.targets_acquired,
                .targets_switched = self.targets_switched,
                .targets_lost = self.targets_lost,
                .attacks_started = self.attacks_started,
                .attacks_committed = self.attacks_committed,
                .attacks_cancelled = self.attacks_cancelled,
                .hit_reactions = self.hit_reactions,
                .directives_pending = @intCast(self.directives.len),
                .damage_pending = @intCast(self.damage.len),
                .cues_pending = @intCast(self.cues.len),
                .transition_history = @intCast(self.transitions.len),
            };
            for (self.records[0..self.record_count]) |record| switch (record.state) {
                .patrolling => result.patrolling += 1,
                .pursuing => result.pursuing += 1,
                .attack_windup => result.attack_windup += 1,
                .attack_recovery => result.attack_recovery += 1,
                .searching => result.searching += 1,
                .returning => result.returning += 1,
            };
            return result;
        }

        pub fn deathPresentationTicks(self: *const Self) u16 {
            return self.config.death_presentation_ticks;
        }

        fn synchronize(self: *Self, frame: contract.Frame) !void {
            var index: usize = self.record_count;
            while (index != 0) {
                index -= 1;
                const observed = findNpc(frame.npcs, self.records[index].npc);
                if (observed == null or !isHostileNpc(
                    frame.npcs,
                    self.records[index].npc,
                    self.config.hostile_npc_limit,
                )) {
                    self.removeRecord(index);
                } else {
                    self.records[index].alive = observed.?.alive;
                    self.records[index].last_health = observed.?.current_health;
                }
            }

            for (frame.npcs) |npc| {
                if (!isHostileNpc(frame.npcs, npc.target, self.config.hostile_npc_limit)) {
                    continue;
                }
                if (!npc.alive or !npc.available or self.findRecord(npc.target) != null) continue;
                if (self.record_count == contract.max_records) {
                    return error.NpcEncounterCapacityReached;
                }
                self.records[self.record_count] = .{
                    .npc = npc.target,
                    .state_enter_tick = frame.tick,
                    .encounter_origin = npc.position,
                    .last_seen_position = npc.position,
                    .last_health = npc.current_health,
                    .alive = true,
                    .next_perception_tick = frame.tick +| perceptionPhase(
                        npc.target,
                        self.config.ambient_perception_interval_ticks,
                    ),
                };
                self.record_count += 1;
            }
            std.mem.sort(Record, self.records[0..self.record_count], {}, lessThanRecord);
        }

        fn applyDamageFacts(self: *Self, frame: contract.Frame) !void {
            for (frame.damage_facts) |fact| {
                if (fact.target.kind != .npc or fact.applied_amount == 0) continue;
                const index = self.findRecord(fact.target) orelse continue;
                const record = &self.records[index];
                record.last_health = fact.remaining_health;
                record.alive = !fact.killed;
                self.hit_reactions +|= 1;
                try self.emitCue(.{ .hit_reaction = .{
                    .npc = record.npc,
                    .source = fact.source,
                    .authority_tick = fact.authority_tick,
                    .remaining_health = fact.remaining_health,
                } });
                if (fact.killed) {
                    record.death_presentation_until_tick = fact.authority_tick +|
                        self.config.death_presentation_ticks;
                    try self.emitDirective(record, .hold, frame.tick);
                    try self.emitCue(.{ .died = .{
                        .npc = record.npc,
                        .source = fact.source,
                        .authority_tick = fact.authority_tick,
                        .presentation_until_tick = fact.authority_tick +|
                            self.config.death_presentation_ticks,
                    } });
                    continue;
                }
                if (fact.source.kind == .player) {
                    const target = vitals.Target{
                        .kind = .player,
                        .id = fact.source.id,
                        .incarnation = fact.source.incarnation,
                    };
                    if (findPlayer(frame.players, target)) |player| {
                        if (player.alive and player.attackable) {
                            const previous = record.target;
                            record.target = target;
                            record.recent_damage_instigator = target;
                            record.recent_damage_tick = frame.tick;
                            record.last_seen_position = player.position;
                            record.last_seen_tick = frame.tick;
                            record.forget_tick = frame.tick +| self.config.last_seen_memory_ticks;
                            record.target_visible = true;
                            record.force_perception = true;
                            try self.emitTargetChanged(record.npc, previous, record.target, frame.tick);
                            if (record.state == .patrolling or record.state == .searching or
                                record.state == .returning)
                            {
                                try self.transition(record, .pursuing, .damage_instigator, frame.tick);
                            }
                        }
                    }
                }
            }
        }

        fn updatePerception(
            self: *Self,
            record: *Record,
            npc: contract.NpcObservation,
            frame: contract.Frame,
            los_remaining: *u8,
            npc_los_remaining: *u8,
        ) !void {
            const interval = if (record.target == null)
                self.config.ambient_perception_interval_ticks
            else
                self.config.engaged_perception_interval_ticks;
            if (!record.force_perception and frame.tick < record.next_perception_tick) return;
            record.force_perception = false;
            record.next_perception_tick = frame.tick +| interval;
            if (record.recent_damage_instigator != null and
                frame.tick > record.recent_damage_tick +| self.config.last_seen_memory_ticks)
            {
                record.recent_damage_instigator = null;
                record.recent_damage_tick = 0;
            }

            var candidates: [contract.max_combatants]PerceptionCandidate = undefined;
            var candidate_count: usize = 0;
            for (frame.players) |player| {
                self.candidates_considered +|= 1;
                if (!player.alive or !player.attackable) continue;
                const distance_squared = horizontalDistanceSquared(npc.position, player.position);
                if (distance_squared > self.config.sight_radius * self.config.sight_radius or
                    horizontalDistanceSquared(record.encounter_origin, player.position) >
                        self.config.pursuit_leash * self.config.pursuit_leash or
                    !faces(npc.position, npc.facing_yaw, player.position, self.config.sight_facing_cos))
                {
                    continue;
                }
                const threat_tier: u8 = if (record.recent_damage_instigator != null and
                    std.meta.eql(record.recent_damage_instigator.?, player.target))
                    2
                else if (record.target != null and
                    std.meta.eql(record.target.?, player.target))
                    1
                else
                    0;
                candidates[candidate_count] = .{
                    .observation = player,
                    .threat_tier = threat_tier,
                    .distance_squared = distance_squared,
                };
                candidate_count += 1;
            }
            std.mem.sort(
                PerceptionCandidate,
                candidates[0..candidate_count],
                {},
                lessThanPerceptionCandidate,
            );

            var best: ?contract.CombatantObservation = null;
            var query_deferred = false;
            for (candidates[0..candidate_count]) |candidate| {
                if (los_remaining.* == 0 or npc_los_remaining.* == 0) {
                    query_deferred = true;
                    self.los_deferred +|= 1;
                    break;
                }
                los_remaining.* -= 1;
                npc_los_remaining.* -= 1;
                self.los_queries +|= 1;
                if (!try self.visibility.lineClear(
                    npc.position,
                    candidate.observation.position,
                )) continue;
                best = candidate.observation;
                break;
            }

            if (best) |visible| {
                const previous = record.target;
                record.target = visible.target;
                record.target_visible = true;
                record.last_seen_position = visible.position;
                record.last_seen_tick = frame.tick;
                record.forget_tick = frame.tick +| self.config.last_seen_memory_ticks;
                if (previous == null or !std.meta.eql(previous.?, visible.target)) {
                    if (previous == null) self.targets_acquired +|= 1 else self.targets_switched +|= 1;
                    try self.emitTargetChanged(record.npc, previous, record.target, frame.tick);
                }
                if (record.state == .patrolling or record.state == .searching or
                    record.state == .returning)
                {
                    try self.transition(record, .pursuing, .sight_acquired, frame.tick);
                }
                return;
            }

            if (query_deferred) {
                record.next_perception_tick = frame.tick +| 1;
                return;
            }

            record.target_visible = false;
            if (record.target != null and frame.tick > record.forget_tick) {
                try self.clearTarget(record, frame.tick);
            }
        }

        fn advanceRecord(
            self: *Self,
            record: *Record,
            npc: contract.NpcObservation,
            frame: contract.Frame,
            los_remaining: *u8,
            npc_los_remaining: *u8,
        ) !void {
            const target = if (record.target) |value| findPlayer(frame.players, value) else null;
            if (record.target != null and
                (target == null or !target.?.alive or !target.?.attackable))
            {
                try self.clearTarget(record, frame.tick);
            }

            switch (record.state) {
                .patrolling => {},
                .pursuing => {
                    const current = if (record.target) |value|
                        findPlayer(frame.players, value)
                    else
                        null;
                    if (current == null) {
                        try self.beginReturn(record, frame.tick, .target_invalid);
                        return;
                    }
                    if (horizontalDistanceSquared(record.encounter_origin, current.?.position) >
                        self.config.pursuit_leash * self.config.pursuit_leash)
                    {
                        try self.clearTarget(record, frame.tick);
                        try self.beginReturn(record, frame.tick, .leash_exceeded);
                        return;
                    }
                    if (!record.target_visible) {
                        if (frame.tick <= record.forget_tick) {
                            try self.transition(record, .searching, .target_not_visible, frame.tick);
                            try self.emitDirective(record, .{ .pursue = .{
                                .target = current.?.target,
                                .position = record.last_seen_position,
                            } }, frame.tick);
                        } else {
                            try self.clearTarget(record, frame.tick);
                            try self.beginReturn(record, frame.tick, .memory_expired);
                        }
                        return;
                    }
                    const in_range = horizontalDistanceSquared(npc.position, current.?.position) <=
                        self.config.melee_range * self.config.melee_range;
                    if (in_range) {
                        record.attack_impact_tick = frame.tick +| self.config.attack_windup_ticks;
                        try self.transition(record, .attack_windup, .attack_range_entered, frame.tick);
                        self.attacks_started +|= 1;
                        try self.emitCue(.{ .attack_started = .{
                            .npc = record.npc,
                            .target = current.?.target,
                            .start_tick = frame.tick,
                            .impact_tick = record.attack_impact_tick,
                        } });
                        try self.emitDirective(record, .{ .face_and_hold = .{
                            .target = current.?.target,
                            .position = current.?.position,
                        } }, frame.tick);
                    } else {
                        try self.emitDirective(record, .{ .pursue = .{
                            .target = current.?.target,
                            .position = approachPosition(
                                npc.position,
                                current.?.position,
                                self.config.combat_standoff_distance,
                            ),
                        } }, frame.tick);
                    }
                },
                .attack_windup => {
                    const current = if (record.target) |value|
                        findPlayer(frame.players, value)
                    else
                        null;
                    if (current == null or !current.?.alive or !current.?.attackable) {
                        try self.resolveAttack(record, null, .target_invalid, .target_missing, frame.tick);
                        try self.beginReturn(record, frame.tick, .target_invalid);
                        return;
                    }
                    try self.emitDirective(record, .{ .face_and_hold = .{
                        .target = current.?.target,
                        .position = current.?.position,
                    } }, frame.tick);
                    if (frame.tick < record.attack_impact_tick) return;
                    if (horizontalDistanceSquared(npc.position, current.?.position) >
                        self.config.melee_range * self.config.melee_range)
                    {
                        try self.resolveAttack(record, current.?.target, .target_not_visible, .out_of_range, frame.tick);
                        return;
                    }
                    if (!faces(npc.position, npc.facing_yaw, current.?.position, self.config.melee_facing_cos)) {
                        try self.resolveAttack(record, current.?.target, .target_not_visible, .not_facing, frame.tick);
                        return;
                    }
                    if (los_remaining.* == 0 or npc_los_remaining.* == 0) {
                        self.los_deferred +|= 1;
                        try self.emitAttackResolved(
                            record,
                            current.?.target,
                            record.attack_sequence,
                            .query_budget_deferred,
                            frame.tick,
                        );
                        return;
                    }
                    los_remaining.* -= 1;
                    npc_los_remaining.* -= 1;
                    self.los_queries +|= 1;
                    if (!try self.visibility.lineClear(npc.position, current.?.position)) {
                        try self.resolveAttack(record, current.?.target, .target_not_visible, .occluded, frame.tick);
                        return;
                    }
                    try self.commitAttack(record, current.?.target, frame.tick);
                },
                .attack_recovery => {
                    const current = if (record.target) |value|
                        findPlayer(frame.players, value)
                    else
                        null;
                    if (current) |value| {
                        try self.emitDirective(record, .{ .face_and_hold = .{
                            .target = value.target,
                            .position = value.position,
                        } }, frame.tick);
                    }
                    if (frame.tick >= record.ready_tick) {
                        if (record.target == null) {
                            try self.beginReturn(record, frame.tick, .target_invalid);
                        } else {
                            try self.transition(record, .pursuing, .recovery_complete, frame.tick);
                        }
                    }
                },
                .searching => {
                    if (record.target_visible and record.target != null) {
                        try self.transition(record, .pursuing, .sight_acquired, frame.tick);
                        return;
                    }
                    if (frame.tick > record.forget_tick) {
                        try self.clearTarget(record, frame.tick);
                        try self.beginReturn(record, frame.tick, .memory_expired);
                        return;
                    }
                    if (horizontalDistanceSquared(npc.position, record.last_seen_position) <=
                        self.config.search_arrival_distance * self.config.search_arrival_distance)
                    {
                        try self.clearTarget(record, frame.tick);
                        try self.beginReturn(record, frame.tick, .search_arrived);
                        return;
                    }
                    const search_target = record.target orelse return error.NpcEncounterSearchTargetMissing;
                    try self.emitDirective(record, .{ .pursue = .{
                        .target = search_target,
                        .position = record.last_seen_position,
                    } }, frame.tick);
                },
                .returning => {
                    try self.emitDirective(record, .resume_route, frame.tick);
                    try self.transition(record, .patrolling, .route_resumed, frame.tick);
                },
            }
        }

        fn commitAttack(
            self: *Self,
            record: *Record,
            target: vitals.Target,
            tick: u64,
        ) !void {
            if (self.damage.isFull()) return error.NpcEncounterDamageQueueFull;
            const action_sequence = record.attack_sequence;
            record.attack_sequence +%= 1;
            if (record.attack_sequence == 0) record.attack_sequence = 1;
            const application_tick = try std.math.add(u64, tick, 1);
            self.damage.pushAssumeCapacity(.{
                .source = .{
                    .kind = .npc,
                    .id = record.npc.id,
                    .incarnation = record.npc.incarnation,
                    .action_sequence = action_sequence,
                },
                .target = target,
                .cause = .npc_melee,
                .authority_tick = application_tick,
                .correlation = contract.attackDamageCorrelation(record.npc, action_sequence),
                .base_amount = self.config.attack_damage,
                .ordinal = @intCast(self.damage.len),
            });
            self.attacks_committed +|= 1;
            try self.emitAttackResolved(
                record,
                target,
                action_sequence,
                .committed,
                application_tick,
            );
            record.ready_tick = application_tick +| self.config.attack_recovery_ticks;
            record.attack_impact_tick = 0;
            try self.transition(record, .attack_recovery, .attack_committed, tick);
        }

        fn resolveAttack(
            self: *Self,
            record: *Record,
            target: ?vitals.Target,
            reason: contract.TransitionReason,
            disposition: contract.AttackDisposition,
            tick: u64,
        ) !void {
            self.attacks_cancelled +|= 1;
            try self.emitAttackResolved(record, target, record.attack_sequence, disposition, tick);
            record.ready_tick = tick +| self.config.attack_recovery_ticks;
            record.attack_impact_tick = 0;
            try self.transition(record, .attack_recovery, reason, tick);
        }

        fn emitAttackResolved(
            self: *Self,
            record: *Record,
            target: ?vitals.Target,
            action_sequence: u32,
            disposition: contract.AttackDisposition,
            tick: u64,
        ) !void {
            try self.emitCue(.{ .attack_resolved = .{
                .npc = record.npc,
                .target = target,
                .action_sequence = action_sequence,
                .authority_tick = tick,
                .disposition = disposition,
            } });
        }

        fn beginReturn(
            self: *Self,
            record: *Record,
            tick: u64,
            reason: contract.TransitionReason,
        ) !void {
            if (record.state != .returning) try self.transition(record, .returning, reason, tick);
            try self.emitDirective(record, .resume_route, tick);
        }

        fn suspendForNavigation(self: *Self, record: *Record, tick: u64) !void {
            if (record.state == .attack_windup) {
                self.attacks_cancelled +|= 1;
                try self.emitAttackResolved(
                    record,
                    record.target,
                    record.attack_sequence,
                    .source_unavailable,
                    tick,
                );
            }
            record.attack_impact_tick = 0;
            record.ready_tick = 0;
            record.recent_damage_instigator = null;
            record.recent_damage_tick = 0;
            try self.clearTarget(record, tick);
            // `last_directive` is the retained locomotion ownership handoff.
            // No directive means patrol already owns movement; resume_route
            // means that handoff was already made. Re-emitting either case can
            // spur needless route reconstruction while content is unloaded.
            const encounter_owns_locomotion = if (record.last_directive) |directive|
                switch (directive) {
                    .pursue, .face_and_hold, .hold => true,
                    .resume_route => false,
                }
            else
                false;
            if (encounter_owns_locomotion) {
                try self.emitDirective(record, .resume_route, tick);
            }
            try self.transition(record, .patrolling, .navigation_unavailable, tick);
        }

        fn clearTarget(self: *Self, record: *Record, tick: u64) !void {
            if (record.target == null) return;
            const previous = record.target;
            record.target = null;
            record.target_visible = false;
            record.last_seen_tick = 0;
            record.forget_tick = 0;
            self.targets_lost +|= 1;
            try self.emitTargetChanged(record.npc, previous, null, tick);
        }

        fn transition(
            self: *Self,
            record: *Record,
            current: contract.State,
            reason: contract.TransitionReason,
            tick: u64,
        ) !void {
            if (record.state == current) return;
            const previous = record.state;
            record.state = current;
            record.state_enter_tick = tick;
            const value = contract.Transition{
                .npc = record.npc,
                .previous = previous,
                .current = current,
                .reason = reason,
                .authority_tick = tick,
            };
            if (self.transitions.isFull()) _ = self.transitions.pop();
            self.transitions.pushAssumeCapacity(value);
            try self.emitCue(.{ .state_changed = .{
                .npc = record.npc,
                .previous = previous,
                .current = current,
                .reason = reason,
                .authority_tick = tick,
            } });
        }

        fn emitTargetChanged(
            self: *Self,
            npc: vitals.Target,
            previous: ?vitals.Target,
            current: ?vitals.Target,
            tick: u64,
        ) !void {
            try self.emitCue(.{ .target_changed = .{
                .npc = npc,
                .previous = previous,
                .current = current,
                .authority_tick = tick,
            } });
        }

        fn emitDirective(
            self: *Self,
            record: *Record,
            locomotion: contract.Locomotion,
            tick: u64,
        ) !void {
            if (!directiveChanged(record, locomotion, self.config, tick)) return;
            if (self.directives.isFull()) return error.NpcEncounterDirectiveQueueFull;
            self.directives.pushAssumeCapacity(.{ .npc = record.npc, .locomotion = locomotion });
            record.last_directive = locomotion;
            record.last_directive_tick = tick;
        }

        fn emitCue(self: *Self, cue: contract.Cue) !void {
            if (self.cues.isFull()) return error.NpcEncounterCueQueueFull;
            self.cues.pushAssumeCapacity(cue);
        }

        fn findRecord(self: *const Self, npc: vitals.Target) ?usize {
            for (self.records[0..self.record_count], 0..) |record, index| {
                if (std.meta.eql(record.npc, npc)) return index;
            }
            return null;
        }

        fn removeRecord(self: *Self, index: usize) void {
            std.debug.assert(index < self.record_count);
            for (index + 1..self.record_count) |source| {
                self.records[source - 1] = self.records[source];
            }
            self.record_count -= 1;
        }
    };
}

fn findNpc(
    observations: []const contract.NpcObservation,
    target: vitals.Target,
) ?contract.NpcObservation {
    for (observations) |observation| {
        if (std.meta.eql(observation.target, target)) return observation;
    }
    return null;
}

fn isHostileNpc(
    observations: []const contract.NpcObservation,
    target: vitals.Target,
    limit: u8,
) bool {
    var ordinal: usize = 0;
    for (observations) |observation| {
        if (contract.lessThanTarget({}, observation.target, target)) ordinal += 1;
    }
    return ordinal < limit;
}

fn findPlayer(
    observations: []const contract.CombatantObservation,
    target: vitals.Target,
) ?contract.CombatantObservation {
    for (observations) |observation| {
        if (std.meta.eql(observation.target, target)) return observation;
    }
    return null;
}

fn horizontalDistanceSquared(lhs: [3]f32, rhs: [3]f32) f32 {
    const dx = rhs[0] - lhs[0];
    const dz = rhs[2] - lhs[2];
    return dx * dx + dz * dz;
}

fn perceptionPhase(target: vitals.Target, interval: u8) u8 {
    var hash = std.hash.Wyhash.init(0x5331_3150);
    hash.update(std.mem.asBytes(&target.id.namespace));
    hash.update(std.mem.asBytes(&target.id.local));
    hash.update(std.mem.asBytes(&target.incarnation.value));
    return @intCast(hash.final() % interval);
}

fn perceptionStartIndex(
    tick: u64,
    record_count: usize,
    config: contract.Config,
) usize {
    if (record_count == 0) return 0;
    const records_per_budget = @max(
        @as(u64, 1),
        @as(u64, config.los_queries_per_tick) / config.los_queries_per_npc,
    );
    return @intCast(
        ((tick - 1) *% records_per_budget) % @as(u64, @intCast(record_count)),
    );
}

fn faces(origin: [3]f32, yaw: f32, target: [3]f32, minimum_cos: f32) bool {
    const dx = target[0] - origin[0];
    const dz = target[2] - origin[2];
    const length_squared = dx * dx + dz * dz;
    if (length_squared <= std.math.floatEps(f32)) return true;
    const inverse_length = 1.0 / @sqrt(length_squared);
    const forward_x = @sin(yaw);
    const forward_z = -@cos(yaw);
    return (forward_x * dx + forward_z * dz) * inverse_length >= minimum_cos;
}

fn directiveChanged(
    record: *const Record,
    next: contract.Locomotion,
    config: contract.Config,
    tick: u64,
) bool {
    const previous = record.last_directive orelse return true;
    if (std.meta.activeTag(previous) != std.meta.activeTag(next)) return true;
    if (tick >= record.last_directive_tick +| config.route_replan_interval_ticks) return true;
    return switch (next) {
        .hold, .resume_route => false,
        .pursue => |value| switch (previous) {
            .pursue => |old| !std.meta.eql(value.target, old.target) or
                horizontalDistanceSquared(value.position, old.position) >=
                    config.directive_position_threshold * config.directive_position_threshold,
            else => true,
        },
        .face_and_hold => |value| switch (previous) {
            .face_and_hold => |old| !std.meta.eql(value.target, old.target) or
                horizontalDistanceSquared(value.position, old.position) >=
                    config.directive_position_threshold * config.directive_position_threshold,
            else => true,
        },
    };
}

fn approachPosition(
    source: [3]f32,
    target: [3]f32,
    standoff_distance: f32,
) [3]f32 {
    const dx = target[0] - source[0];
    const dz = target[2] - source[2];
    const distance_squared = dx * dx + dz * dz;
    if (distance_squared <= standoff_distance * standoff_distance or
        distance_squared <= std.math.floatEps(f32))
    {
        return source;
    }
    const distance = @sqrt(distance_squared);
    const scale = (distance - standoff_distance) / distance;
    return .{
        source[0] + dx * scale,
        target[1],
        source[2] + dz * scale,
    };
}

fn viewRecord(record: Record) contract.View {
    return .{
        .npc = record.npc,
        .state = record.state,
        .state_enter_tick = record.state_enter_tick,
        .target = record.target,
        .last_seen_position = record.last_seen_position,
        .encounter_origin = record.encounter_origin,
        .last_seen_tick = record.last_seen_tick,
        .forget_tick = record.forget_tick,
        .attack_impact_tick = record.attack_impact_tick,
        .ready_tick = record.ready_tick,
        .death_presentation_until_tick = record.death_presentation_until_tick,
        .alive = record.alive,
        .current_health = record.last_health,
        .recent_damage_instigator = record.recent_damage_instigator,
        .recent_damage_tick = record.recent_damage_tick,
        .target_visible = record.target_visible,
        .next_perception_tick = record.next_perception_tick,
        .last_directive = record.last_directive,
        .last_directive_tick = record.last_directive_tick,
    };
}

fn persistedRecord(record: Record) contract.RecordV1 {
    return .{
        .npc = record.npc,
        .state = record.state,
        .state_enter_tick = record.state_enter_tick,
        .target = record.target,
        .encounter_origin = record.encounter_origin,
        .last_seen_position = record.last_seen_position,
        .last_seen_tick = record.last_seen_tick,
        .forget_tick = record.forget_tick,
        .attack_impact_tick = record.attack_impact_tick,
        .ready_tick = record.ready_tick,
        .death_presentation_until_tick = record.death_presentation_until_tick,
        .attack_sequence = record.attack_sequence,
        .last_health = record.last_health,
        .alive = record.alive,
        .recent_damage_instigator = record.recent_damage_instigator,
        .recent_damage_tick = record.recent_damage_tick,
        .next_perception_tick = record.next_perception_tick,
        .target_visible = record.target_visible,
        .force_perception = record.force_perception,
        .last_directive = record.last_directive,
        .last_directive_tick = record.last_directive_tick,
    };
}

fn runtimeRecord(record: contract.RecordV1) Record {
    return .{
        .npc = record.npc,
        .state = record.state,
        .state_enter_tick = record.state_enter_tick,
        .target = record.target,
        .encounter_origin = record.encounter_origin,
        .last_seen_position = record.last_seen_position,
        .last_seen_tick = record.last_seen_tick,
        .forget_tick = record.forget_tick,
        .attack_impact_tick = record.attack_impact_tick,
        .ready_tick = record.ready_tick,
        .death_presentation_until_tick = record.death_presentation_until_tick,
        .attack_sequence = record.attack_sequence,
        .last_health = record.last_health,
        .alive = record.alive,
        .recent_damage_instigator = record.recent_damage_instigator,
        .recent_damage_tick = record.recent_damage_tick,
        .next_perception_tick = record.next_perception_tick,
        .target_visible = record.target_visible,
        .force_perception = record.force_perception,
        .last_directive = record.last_directive,
        .last_directive_tick = record.last_directive_tick,
    };
}

fn lessThanRecord(_: void, lhs: Record, rhs: Record) bool {
    return contract.lessThanTarget({}, lhs.npc, rhs.npc);
}

fn lessThanPerceptionCandidate(
    _: void,
    lhs: PerceptionCandidate,
    rhs: PerceptionCandidate,
) bool {
    if (lhs.threat_tier != rhs.threat_tier) return lhs.threat_tier > rhs.threat_tier;
    if (lhs.distance_squared != rhs.distance_squared) {
        return lhs.distance_squared < rhs.distance_squared;
    }
    return contract.lessThanTarget({}, lhs.observation.target, rhs.observation.target);
}

fn writeTarget(writer: *engine.contracts.replay.Writer, target: vitals.Target) void {
    writer.writeU8(@intFromEnum(target.kind));
    writer.writeU64(target.id.namespace);
    writer.writeU64(target.id.local);
    writer.writeU16(target.incarnation.value);
}

fn writeVector(writer: *engine.contracts.replay.Writer, value: [3]f32) !void {
    for (value) |component| try writer.writeF32(component);
}

fn writeDirective(
    writer: *engine.contracts.replay.Writer,
    directive: contract.LocomotionDirective,
) !void {
    writeTarget(writer, directive.npc);
    writer.writeU8(@intFromEnum(std.meta.activeTag(directive.locomotion)));
    switch (directive.locomotion) {
        .hold, .resume_route => {},
        .pursue => |value| {
            writeTarget(writer, value.target);
            try writeVector(writer, value.position);
        },
        .face_and_hold => |value| {
            writeTarget(writer, value.target);
            try writeVector(writer, value.position);
        },
    }
}

fn writeDamage(writer: *engine.contracts.replay.Writer, value: vitals.DamageProposal) void {
    writer.writeU8(@intFromEnum(value.source.kind));
    writer.writeU64(value.source.id.namespace);
    writer.writeU64(value.source.id.local);
    writer.writeU16(value.source.incarnation.value);
    writer.writeU32(value.source.action_sequence);
    writeTarget(writer, value.target);
    writer.writeU8(@intFromEnum(value.cause));
    writer.writeU64(value.authority_tick);
    writer.writeU64(value.correlation);
    writer.writeU16(value.base_amount);
    writer.writeU16(value.ordinal);
}

const TestVisibility = struct {
    clear: bool = true,
    queries: u32 = 0,

    pub fn lineClear(self: *TestVisibility, _: [3]f32, _: [3]f32) !bool {
        self.queries += 1;
        return self.clear;
    }
};

fn testTarget(kind: vitals.TargetKind, local: u64) vitals.Target {
    return .{
        .kind = kind,
        .id = .{ .namespace = 77, .local = local },
        .incarnation = .{ .value = 1 },
    };
}

test "stable target selection starts pursuit and emits one directive" {
    var visibility = TestVisibility{};
    var feature = try Feature(TestVisibility).init(&visibility, .{
        .ambient_perception_interval_ticks = 1,
        .engaged_perception_interval_ticks = 1,
    });
    defer feature.deinit();

    const npc = contract.NpcObservation{
        .target = testTarget(.npc, 10),
        .position = .{ 0, 0, 0 },
        .facing_yaw = 0,
        .alive = true,
    };
    const farther = contract.CombatantObservation{
        .target = testTarget(.player, 3),
        .position = .{ 0, 0, -5 },
        .facing_yaw = 0,
        .alive = true,
    };
    const nearer = contract.CombatantObservation{
        .target = testTarget(.player, 2),
        .position = .{ 0, 0, -4 },
        .facing_yaw = 0,
        .alive = true,
    };
    try feature.step(.{
        .tick = 1,
        .players = &.{ farther, nearer },
        .npcs = &.{npc},
        .damage_facts = &.{},
    });
    const view = feature.view(npc.target) orelse return error.MissingEncounterView;
    try std.testing.expectEqual(contract.State.pursuing, view.state);
    try std.testing.expectEqualDeep(nearer.target, view.target.?);
    const directive = feature.pollDirective() orelse return error.MissingDirective;
    try std.testing.expectEqualDeep(nearer.target, directive.locomotion.pursue.target);
    try std.testing.expectEqualDeep(
        [3]f32{ 0, 0, -2.5 },
        directive.locomotion.pursue.position,
    );
    while (feature.pollCue() != null) {}
}

test "pursuit holds an authored stand-off before melee windup" {
    var visibility = TestVisibility{};
    var feature = try Feature(TestVisibility).init(&visibility, .{
        .ambient_perception_interval_ticks = 1,
        .engaged_perception_interval_ticks = 1,
        .combat_standoff_distance = 1.5,
        .melee_range = 2.25,
    });
    defer feature.deinit();

    const npc = contract.NpcObservation{
        .target = testTarget(.npc, 10),
        .position = .{ 0, 0, 0 },
        .facing_yaw = 0,
        .alive = true,
    };
    var player = contract.CombatantObservation{
        .target = testTarget(.player, 1),
        .position = .{ 0, 0, -2.5 },
        .facing_yaw = 0,
        .alive = true,
    };
    try feature.step(.{
        .tick = 1,
        .players = &.{player},
        .npcs = &.{npc},
        .damage_facts = &.{},
    });
    try std.testing.expectEqual(contract.State.pursuing, feature.view(npc.target).?.state);
    const pursue = feature.pollDirective() orelse return error.MissingDirective;
    try std.testing.expectEqualDeep(
        [3]f32{ 0, 0, -1.0 },
        pursue.locomotion.pursue.position,
    );
    while (feature.pollCue() != null) {}

    player.position = .{ 0, 0, -2.0 };
    try feature.step(.{
        .tick = 2,
        .players = &.{player},
        .npcs = &.{npc},
        .damage_facts = &.{},
    });
    try std.testing.expectEqual(
        contract.State.attack_windup,
        feature.view(npc.target).?.state,
    );
    const hold = feature.pollDirective() orelse return error.MissingDirective;
    try std.testing.expectEqual(
        std.meta.Tag(contract.Locomotion).face_and_hold,
        std.meta.activeTag(hold.locomotion),
    );
}

test "windup commits authoritative NPC melee then enters recovery" {
    var visibility = TestVisibility{};
    var feature = try Feature(TestVisibility).init(&visibility, .{
        .ambient_perception_interval_ticks = 1,
        .engaged_perception_interval_ticks = 1,
        .attack_windup_ticks = 1,
        .attack_recovery_ticks = 2,
    });
    defer feature.deinit();

    const npc = contract.NpcObservation{
        .target = testTarget(.npc, 10),
        .position = .{ 0, 0, 0 },
        .facing_yaw = 0,
        .alive = true,
    };
    const player = contract.CombatantObservation{
        .target = testTarget(.player, 1),
        .position = .{ 0, 0, -1.5 },
        .facing_yaw = 0,
        .alive = true,
    };
    try feature.step(.{
        .tick = 1,
        .players = &.{player},
        .npcs = &.{npc},
        .damage_facts = &.{},
    });
    _ = feature.pollDirective();
    while (feature.pollCue() != null) {}
    try std.testing.expectEqual(contract.State.attack_windup, feature.view(npc.target).?.state);

    try feature.step(.{
        .tick = 2,
        .players = &.{player},
        .npcs = &.{npc},
        .damage_facts = &.{},
    });
    _ = feature.pollDirective();
    const proposal = feature.pollDamage() orelse return error.MissingNpcDamage;
    try std.testing.expectEqual(vitals.Cause.npc_melee, proposal.cause);
    try std.testing.expectEqualDeep(player.target, proposal.target);
    try std.testing.expectEqual(@as(u64, 3), proposal.authority_tick);
    try std.testing.expectEqual(contract.State.attack_recovery, feature.view(npc.target).?.state);
    while (feature.pollCue() != null) {}
}

test "damage stimulus deterministically retargets its player instigator" {
    var visibility = TestVisibility{ .clear = false };
    var feature = try Feature(TestVisibility).init(&visibility, .{});
    defer feature.deinit();

    const npc = contract.NpcObservation{
        .target = testTarget(.npc, 10),
        .position = .{ 0, 0, 0 },
        .facing_yaw = 0,
        .alive = true,
    };
    const player = contract.CombatantObservation{
        .target = testTarget(.player, 4),
        .position = .{ 2, 0, 0 },
        .facing_yaw = 0,
        .alive = true,
    };
    const source = vitals.Source{
        .kind = .player,
        .id = player.target.id,
        .incarnation = player.target.incarnation,
        .action_sequence = 9,
    };
    try feature.step(.{
        .tick = 1,
        .players = &.{player},
        .npcs = &.{npc},
        .damage_facts = &.{.{
            .source = source,
            .target = npc.target,
            .authority_tick = 1,
            .applied_amount = 20,
            .remaining_health = 80,
            .killed = false,
        }},
    });
    try std.testing.expectEqualDeep(player.target, feature.view(npc.target).?.target.?);
    try std.testing.expectEqual(contract.State.searching, feature.view(npc.target).?.state);
    try std.testing.expectEqual(@as(u64, 1), feature.diagnostics().hit_reactions);
    _ = feature.pollDirective();
    while (feature.pollCue() != null) {}
}

test "stable NPC order enforces the shared LOS budget without silent work" {
    var visibility = TestVisibility{};
    var feature = try Feature(TestVisibility).init(&visibility, .{
        .hostile_npc_limit = 2,
        .ambient_perception_interval_ticks = 1,
        .engaged_perception_interval_ticks = 1,
        .los_queries_per_tick = 1,
        .los_queries_per_npc = 1,
    });
    defer feature.deinit();

    const first = contract.NpcObservation{
        .target = testTarget(.npc, 10),
        .position = .{ 0, 0, 0 },
        .facing_yaw = 0,
        .alive = true,
    };
    const second = contract.NpcObservation{
        .target = testTarget(.npc, 11),
        .position = .{ 1, 0, 0 },
        .facing_yaw = 0,
        .alive = true,
    };
    const player = contract.CombatantObservation{
        .target = testTarget(.player, 1),
        .position = .{ 0, 0, -5 },
        .facing_yaw = 0,
        .alive = true,
    };
    try feature.step(.{
        .tick = 1,
        .players = &.{player},
        .npcs = &.{ second, first },
        .damage_facts = &.{},
    });
    try std.testing.expectEqual(contract.State.pursuing, feature.view(first.target).?.state);
    try std.testing.expectEqual(contract.State.patrolling, feature.view(second.target).?.state);
    try std.testing.expectEqual(@as(u64, 1), feature.diagnostics().los_deferred);
    _ = feature.pollDirective();
    while (feature.pollCue() != null) {}
}

test "occluded target is searched, forgotten, and returned to patrol" {
    var visibility = TestVisibility{};
    var feature = try Feature(TestVisibility).init(&visibility, .{
        .ambient_perception_interval_ticks = 1,
        .engaged_perception_interval_ticks = 1,
        .last_seen_memory_ticks = 1,
    });
    defer feature.deinit();
    const npc = contract.NpcObservation{
        .target = testTarget(.npc, 10),
        .position = .{ 0, 0, 0 },
        .facing_yaw = 0,
        .alive = true,
    };
    const player = contract.CombatantObservation{
        .target = testTarget(.player, 1),
        .position = .{ 0, 0, -5 },
        .facing_yaw = 0,
        .alive = true,
    };
    try feature.step(.{ .tick = 1, .players = &.{player}, .npcs = &.{npc}, .damage_facts = &.{} });
    _ = feature.pollDirective();
    while (feature.pollCue() != null) {}

    visibility.clear = false;
    try feature.step(.{ .tick = 2, .players = &.{player}, .npcs = &.{npc}, .damage_facts = &.{} });
    try std.testing.expectEqual(contract.State.searching, feature.view(npc.target).?.state);
    _ = feature.pollDirective();
    while (feature.pollCue() != null) {}

    try feature.step(.{ .tick = 3, .players = &.{player}, .npcs = &.{npc}, .damage_facts = &.{} });
    try std.testing.expectEqual(contract.State.returning, feature.view(npc.target).?.state);
    _ = feature.pollDirective();
    while (feature.pollCue() != null) {}

    try feature.step(.{ .tick = 4, .players = &.{player}, .npcs = &.{npc}, .damage_facts = &.{} });
    try std.testing.expectEqual(contract.State.patrolling, feature.view(npc.target).?.state);
    _ = feature.pollDirective();
    while (feature.pollCue() != null) {}
}

test "occupied-vehicle target becomes ineligible and disengages" {
    var visibility = TestVisibility{};
    var feature = try Feature(TestVisibility).init(&visibility, .{
        .ambient_perception_interval_ticks = 1,
        .engaged_perception_interval_ticks = 1,
    });
    defer feature.deinit();
    const npc = contract.NpcObservation{
        .target = testTarget(.npc, 10),
        .position = .{ 0, 0, 0 },
        .facing_yaw = 0,
        .alive = true,
    };
    var player = contract.CombatantObservation{
        .target = testTarget(.player, 1),
        .position = .{ 0, 0, -5 },
        .facing_yaw = 0,
        .alive = true,
    };
    try feature.step(.{ .tick = 1, .players = &.{player}, .npcs = &.{npc}, .damage_facts = &.{} });
    _ = feature.pollDirective();
    while (feature.pollCue() != null) {}
    player.attackable = false;
    try feature.step(.{ .tick = 2, .players = &.{player}, .npcs = &.{npc}, .damage_facts = &.{} });
    try std.testing.expectEqual(contract.State.returning, feature.view(npc.target).?.state);
    try std.testing.expect(feature.view(npc.target).?.target == null);
    _ = feature.pollDirective();
    while (feature.pollCue() != null) {}
}

test "death during windup emits hold and cannot commit post-death damage" {
    var visibility = TestVisibility{};
    var feature = try Feature(TestVisibility).init(&visibility, .{
        .ambient_perception_interval_ticks = 1,
        .engaged_perception_interval_ticks = 1,
        .attack_windup_ticks = 2,
    });
    defer feature.deinit();
    const npc = contract.NpcObservation{
        .target = testTarget(.npc, 10),
        .position = .{ 0, 0, 0 },
        .facing_yaw = 0,
        .alive = true,
    };
    const player = contract.CombatantObservation{
        .target = testTarget(.player, 1),
        .position = .{ 0, 0, -1.5 },
        .facing_yaw = 0,
        .alive = true,
    };
    try feature.step(.{ .tick = 1, .players = &.{player}, .npcs = &.{npc}, .damage_facts = &.{} });
    _ = feature.pollDirective();
    while (feature.pollCue() != null) {}
    try std.testing.expectEqual(contract.State.attack_windup, feature.view(npc.target).?.state);

    var dead_npc = npc;
    dead_npc.alive = false;
    dead_npc.current_health = 0;
    try feature.step(.{
        .tick = 2,
        .players = &.{player},
        .npcs = &.{dead_npc},
        .damage_facts = &.{.{
            .source = .{
                .kind = .player,
                .id = player.target.id,
                .incarnation = player.target.incarnation,
                .action_sequence = 1,
            },
            .target = npc.target,
            .authority_tick = 2,
            .applied_amount = 100,
            .remaining_health = 0,
            .killed = true,
        }},
    });
    try std.testing.expect(!feature.view(npc.target).?.alive);
    try std.testing.expect(feature.pollDirective().?.locomotion == .hold);
    try std.testing.expect(feature.pollDamage() == null);
    while (feature.pollCue() != null) {}
}

test "navigation unavailability cancels windup and returns to patrol" {
    var visibility = TestVisibility{};
    var feature = try Feature(TestVisibility).init(&visibility, .{
        .ambient_perception_interval_ticks = 1,
        .engaged_perception_interval_ticks = 1,
        .attack_windup_ticks = 2,
    });
    defer feature.deinit();
    var npc = contract.NpcObservation{
        .target = testTarget(.npc, 10),
        .position = .{ 0, 0, 0 },
        .facing_yaw = 0,
        .alive = true,
    };
    const player = contract.CombatantObservation{
        .target = testTarget(.player, 1),
        .position = .{ 0, 0, -1.5 },
        .facing_yaw = 0,
        .alive = true,
    };
    try feature.step(.{
        .tick = 1,
        .players = &.{player},
        .npcs = &.{npc},
        .damage_facts = &.{},
    });
    _ = feature.pollDirective();
    while (feature.pollCue() != null) {}
    try std.testing.expectEqual(contract.State.attack_windup, feature.view(npc.target).?.state);

    npc.available = false;
    try feature.step(.{
        .tick = 2,
        .players = &.{player},
        .npcs = &.{npc},
        .damage_facts = &.{},
    });
    const view = feature.view(npc.target).?;
    try std.testing.expectEqual(contract.State.patrolling, view.state);
    try std.testing.expectEqual(@as(?vitals.Target, null), view.target);
    try std.testing.expectEqual(@as(u64, 0), view.attack_impact_tick);
    try std.testing.expect(feature.pollDirective().?.locomotion == .resume_route);

    var saw_unavailable_attack = false;
    var saw_unavailable_transition = false;
    while (feature.pollCue()) |cue| switch (cue) {
        .attack_resolved => |resolved| {
            saw_unavailable_attack = resolved.disposition == .source_unavailable;
        },
        .state_changed => |changed| {
            saw_unavailable_transition = changed.reason == .navigation_unavailable;
        },
        else => {},
    };
    try std.testing.expect(saw_unavailable_attack);
    try std.testing.expect(saw_unavailable_transition);
    try std.testing.expect(feature.pollDamage() == null);

    // Continued unavailability must not periodically re-emit resume_route;
    // patrol already owns locomotion after the first handoff.
    try feature.step(.{
        .tick = 3,
        .players = &.{player},
        .npcs = &.{npc},
        .damage_facts = &.{},
    });
    try std.testing.expect(feature.pollDirective() == null);
    try std.testing.expect(feature.pollDamage() == null);
    while (feature.pollCue() != null) {}
}

test "navigation unavailability without an encounter override keeps patrol ownership" {
    var visibility = TestVisibility{};
    var feature = try Feature(TestVisibility).init(&visibility, .{
        .ambient_perception_interval_ticks = 1,
        .engaged_perception_interval_ticks = 1,
    });
    defer feature.deinit();
    var npc = contract.NpcObservation{
        .target = testTarget(.npc, 10),
        .position = .{ 0, 0, 0 },
        .facing_yaw = 0,
        .alive = true,
    };

    try feature.step(.{
        .tick = 1,
        .players = &.{},
        .npcs = &.{npc},
        .damage_facts = &.{},
    });
    try std.testing.expectEqual(contract.State.patrolling, feature.view(npc.target).?.state);
    try std.testing.expect(feature.pollDirective() == null);
    try std.testing.expect(feature.pollDamage() == null);
    while (feature.pollCue() != null) {}

    npc.available = false;
    try feature.step(.{
        .tick = 2,
        .players = &.{},
        .npcs = &.{npc},
        .damage_facts = &.{},
    });
    try std.testing.expectEqual(contract.State.patrolling, feature.view(npc.target).?.state);
    try std.testing.expect(feature.pollDirective() == null);
    try std.testing.expect(feature.pollDamage() == null);
    while (feature.pollCue() != null) {}
}

test "mid-windup canonical records restore exact authority deadlines" {
    var visibility = TestVisibility{};
    var source = try Feature(TestVisibility).init(&visibility, .{
        .ambient_perception_interval_ticks = 1,
        .engaged_perception_interval_ticks = 1,
    });
    defer source.deinit();
    const npc = contract.NpcObservation{
        .target = testTarget(.npc, 10),
        .position = .{ 0, 0, 0 },
        .facing_yaw = 0,
        .alive = true,
    };
    const player = contract.CombatantObservation{
        .target = testTarget(.player, 1),
        .position = .{ 0, 0, -1.5 },
        .facing_yaw = 0,
        .alive = true,
    };
    try source.step(.{ .tick = 1, .players = &.{player}, .npcs = &.{npc}, .damage_facts = &.{} });
    _ = source.pollDirective();
    while (source.pollCue() != null) {}
    const records = try source.snapshotRecords(std.testing.allocator);
    defer std.testing.allocator.free(records);

    var restored = try Feature(TestVisibility).init(&visibility, source.config);
    defer restored.deinit();
    try restored.restoreRecords(records);
    try std.testing.expectEqualDeep(source.view(npc.target).?, restored.view(npc.target).?);
    const restored_records = try restored.snapshotRecords(std.testing.allocator);
    defer std.testing.allocator.free(restored_records);
    try std.testing.expectEqualDeep(records, restored_records);
}

test "undrained output rejects the next frame before authority state changes" {
    var visibility = TestVisibility{};
    var feature = try Feature(TestVisibility).init(&visibility, .{
        .ambient_perception_interval_ticks = 1,
        .engaged_perception_interval_ticks = 1,
    });
    defer feature.deinit();
    const npc = contract.NpcObservation{
        .target = testTarget(.npc, 10),
        .position = .{ 0, 0, 0 },
        .facing_yaw = 0,
        .alive = true,
    };
    const player = contract.CombatantObservation{
        .target = testTarget(.player, 1),
        .position = .{ 0, 0, -5 },
        .facing_yaw = 0,
        .alive = true,
    };
    try feature.step(.{ .tick = 1, .players = &.{player}, .npcs = &.{npc}, .damage_facts = &.{} });
    const before = feature.view(npc.target).?;
    try std.testing.expectError(
        error.NpcEncounterOutputsPending,
        feature.step(.{ .tick = 2, .players = &.{}, .npcs = &.{npc}, .damage_facts = &.{} }),
    );
    try std.testing.expectEqualDeep(before, feature.view(npc.target).?);
    _ = feature.pollDirective();
    while (feature.pollCue() != null) {}
}

test "64 NPC and 16 participant ceiling consumes the exact shared LOS budget deterministically" {
    var players: [16]contract.CombatantObservation = undefined;
    for (&players, 0..) |*player, index| player.* = .{
        .target = testTarget(.player, @intCast(index + 1)),
        .position = .{ @as(f32, @floatFromInt(index % 4)) * 0.25, 0, -5 },
        .facing_yaw = 0,
        .alive = true,
    };
    var npcs_observed: [contract.max_records]contract.NpcObservation = undefined;
    for (&npcs_observed, 0..) |*npc, index| npc.* = .{
        .target = testTarget(.npc, @intCast(index + 100)),
        .position = .{ @as(f32, @floatFromInt(index % 8)) * 0.1, 0, 0 },
        .facing_yaw = 0,
        .alive = true,
    };
    const config = contract.Config{
        .hostile_npc_limit = contract.max_records,
        .ambient_perception_interval_ticks = 1,
        .engaged_perception_interval_ticks = 1,
        .los_queries_per_tick = 16,
        .los_queries_per_npc = 4,
    };
    var first_visibility = TestVisibility{};
    var first = try Feature(TestVisibility).init(&first_visibility, config);
    defer first.deinit();
    var second_visibility = TestVisibility{};
    var second = try Feature(TestVisibility).init(&second_visibility, config);
    defer second.deinit();
    const frame = contract.Frame{
        .tick = 1,
        .players = &players,
        .npcs = &npcs_observed,
        .damage_facts = &.{},
    };
    for (1..17) |tick| {
        var current = frame;
        current.tick = tick;
        try first.step(current);
        try second.step(current);
        while (first.pollDirective() != null) {}
        while (second.pollDirective() != null) {}
        while (first.pollCue() != null) {}
        while (second.pollCue() != null) {}
    }
    try std.testing.expectEqual(@as(u64, 16 * 16), first.diagnostics().los_queries);
    try std.testing.expect(first.diagnostics().los_deferred > 0);
    try std.testing.expectEqualDeep(first.diagnostics(), second.diagnostics());
    for (npcs_observed) |npc| {
        try std.testing.expectEqual(contract.State.pursuing, first.view(npc.target).?.state);
    }
    const first_records = try first.snapshotRecords(std.testing.allocator);
    defer std.testing.allocator.free(first_records);
    const second_records = try second.snapshotRecords(std.testing.allocator);
    defer std.testing.allocator.free(second_records);
    try std.testing.expectEqualDeep(first_records, second_records);
}
