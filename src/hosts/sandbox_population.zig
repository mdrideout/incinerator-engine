//! Deterministic fixed-capacity authority for authored sandbox population.
//!
//! This owner retains member lifecycle, activity intent, and exclusive slot
//! claims. It emits correlated intents but never creates NPCs, moves actors,
//! queries physics, chooses combat locomotion, or publishes replication.

const std = @import("std");
const engine = @import("incinerator_engine");
const contract = @import("population_contract");
const catalog = @import("sandbox_population_catalog");

pub const max_intents: usize = contract.max_members * 2;
pub const max_transitions: usize = 256;

pub const Cohort = contract.Cohort;
pub const Config = contract.ConfigV1;

pub const Owner = struct {
    config: Config,
    member_records: [contract.max_members]contract.MemberRecordV1 = undefined,
    member_count: usize,
    slot_records: [contract.max_activity_slots]contract.ActivitySlotRecordV1 =
        undefined,
    intents: engine.BoundedQueue(contract.Intent, max_intents) = .{},
    transitions: engine.BoundedQueue(contract.Transition, max_transitions) = .{},
    intents_high_water: u32 = 0,
    transitions_high_water: u32 = 0,
    transition_drops: u64 = 0,
    decisions: u64 = 0,
    slot_contentions: u64 = 0,
    lease_expirations: u64 = 0,
    last_step_tick: u64 = 0,

    pub fn init(config: Config) !Owner {
        try config.validate();
        try catalog.validate();
        const count = switch (config.cohort) {
            .ordinary => contract.ordinary_member_count,
            .physical_stress => contract.max_members,
        };
        var self = Owner{
            .config = config,
            .member_count = count,
        };
        for (catalog.members[0..count], 0..) |definition, index| {
            self.member_records[index] = .{
                .id = definition.id,
                .lifecycle = .awaiting_spawn,
                .actor_generation = 1,
                .spawn_in_flight = false,
                .program_cursor = definition.phase_offset,
                .activity_sequence = 0,
                .activity_state = .replacement_pending,
                .deadline_tick = 0,
                .retry_tick = 1,
                .spawn_retry_reason = .none,
                .spawn_candidate_cursor = 0,
                .last_transition_tick = 0,
                .last_transition_reason = .cold_bootstrap,
            };
        }
        for (catalog.activity_slots, 0..) |definition, index| {
            self.slot_records[index] = .{
                .id = definition.id,
                .state = .free,
                .lease_deadline_tick = 0,
            };
        }
        return self;
    }

    pub fn restore(saved: contract.SnapshotV1) !Owner {
        try saved.config.validate();
        try catalog.validate();
        if (saved.catalog_version != catalog.catalog_version) {
            return error.PopulationCatalogVersionMismatch;
        }
        const expected_members: usize = switch (saved.config.cohort) {
            .ordinary => contract.ordinary_member_count,
            .physical_stress => contract.max_members,
        };
        if (saved.members.len != expected_members or
            saved.slots.len != contract.max_activity_slots)
        {
            return error.InvalidPopulationSnapshotCapacity;
        }
        var self = Owner{
            .config = saved.config,
            .member_count = expected_members,
            .intents_high_water = saved.stats.intents_high_water,
            .transitions_high_water = saved.stats.transitions_high_water,
            .transition_drops = saved.stats.transition_drops,
            .decisions = saved.stats.decisions,
            .slot_contentions = saved.stats.slot_contentions,
            .lease_expirations = saved.stats.lease_expirations,
            .last_step_tick = saved.last_step_tick,
        };
        @memcpy(self.member_records[0..expected_members], saved.members);
        @memcpy(&self.slot_records, saved.slots);
        return self;
    }

    pub fn snapshot(self: *const Owner) !contract.SnapshotV1 {
        if (!self.intents.isEmpty() or !self.transitions.isEmpty()) {
            return error.PopulationOutputsPending;
        }
        for (self.members()) |member| {
            if (member.spawn_in_flight) return error.PopulationTransactionPending;
        }
        return .{
            .catalog_version = catalog.catalog_version,
            .config = self.config,
            .last_step_tick = self.last_step_tick,
            .stats = .{
                .intents_high_water = self.intents_high_water,
                .transitions_high_water = self.transitions_high_water,
                .transition_drops = self.transition_drops,
                .decisions = self.decisions,
                .slot_contentions = self.slot_contentions,
                .lease_expirations = self.lease_expirations,
            },
            .members = self.members(),
            .slots = self.slots(),
        };
    }

    pub fn outputsPending(self: *const Owner) bool {
        return !self.intents.isEmpty() or !self.transitions.isEmpty();
    }

    pub fn step(self: *Owner, tick: u64) !void {
        if (tick == 0 or tick <= self.last_step_tick) {
            return error.InvalidPopulationTick;
        }
        if (!self.intents.isEmpty()) return error.PopulationIntentsPending;
        self.last_step_tick = tick;

        var remaining = contract.decisions_per_tick;
        for (self.member_records[0..self.member_count], 0..) |*member, index| {
            if (remaining == 0) break;
            if (member.lifecycle == .live) continue;
            if (try self.advanceMember(index, tick)) {
                remaining -= 1;
                self.decisions +|= 1;
            }
        }
        if (remaining == 0) return;
        for (self.member_records[0..self.member_count], 0..) |*member, index| {
            if (remaining == 0) break;
            if (member.lifecycle != .live) continue;
            if (try self.advanceMember(index, tick)) {
                remaining -= 1;
                self.decisions +|= 1;
            }
        }
    }

    pub fn bindActor(
        self: *Owner,
        member_id: contract.PopulationMemberId,
        actor_generation: u16,
        actor: engine.PersistentId,
        tick: u64,
    ) !void {
        try actor.validate();
        const member = self.memberMutable(member_id) orelse
            return error.PopulationMemberNotFound;
        if (!member.spawn_in_flight or member.actor_generation != actor_generation or
            (member.lifecycle != .awaiting_spawn and
                member.lifecycle != .replacement_pending))
        {
            return error.StalePopulationSpawnBinding;
        }
        for (self.member_records[0..self.member_count]) |candidate| {
            if (candidate.actor) |existing| {
                if (std.meta.eql(existing, actor)) return error.DuplicatePopulationActor;
            }
        }
        const previous = member.activity_state;
        member.lifecycle = .live;
        member.actor = actor;
        member.spawn_in_flight = false;
        member.activity_state = .selecting;
        member.deadline_tick = 0;
        member.retry_tick = 0;
        member.spawn_retry_reason = .none;
        member.spawn_candidate_cursor = 0;
        self.recordTransition(member.*, previous, .actor_bound, tick);
    }

    pub fn deferSpawn(
        self: *Owner,
        member_id: contract.PopulationMemberId,
        actor_generation: u16,
        reason: contract.SpawnRetryReason,
        tick: u64,
    ) !void {
        if (reason == .none) return error.InvalidPopulationSpawnRetryReason;
        const member = self.memberMutable(member_id) orelse
            return error.PopulationMemberNotFound;
        if (!member.spawn_in_flight or member.actor_generation != actor_generation or
            (member.lifecycle != .awaiting_spawn and
                member.lifecycle != .replacement_pending))
        {
            return error.StalePopulationSpawnDeferral;
        }
        member.spawn_in_flight = false;
        member.retry_tick = tick +| self.config.spawn_retry_ticks;
        member.spawn_retry_reason = reason;
        try member.spawn_retry_counts.increment(reason);
        const definition = self.memberDefinition(member.id);
        const candidate_count = definition.replacementSpawnSlots().len;
        member.spawn_candidate_cursor = @intCast(
            (@as(usize, member.spawn_candidate_cursor) + 1) % candidate_count,
        );
        self.recordTransition(
            member.*,
            member.activity_state,
            .spawn_deferred,
            tick,
        );
    }

    pub fn arrive(
        self: *Owner,
        member_id: contract.PopulationMemberId,
        actor: engine.PersistentId,
        tick: u64,
    ) !void {
        const member = self.memberMutable(member_id) orelse
            return error.PopulationMemberNotFound;
        if (member.lifecycle != .live or member.activity_state != .traveling or
            member.actor == null or !std.meta.eql(member.actor.?, actor) or
            member.activity_slot == null)
        {
            return error.InvalidPopulationArrival;
        }
        const slot = self.slotMutable(member.activity_slot.?) orelse
            return error.ActivitySlotNotFound;
        if (slot.state != .claimed or slot.member == null or
            !contract.PopulationMemberId.eql(slot.member.?, member.id))
        {
            return error.ActivitySlotClaimMismatch;
        }
        const definition = self.memberDefinition(member.id);
        const program = catalog.programDefinition(definition.program) orelse unreachable;
        const step_definition = program.stepSlice()[member.program_cursor];
        const previous = member.activity_state;
        slot.state = .occupied;
        slot.lease_deadline_tick = 0;
        member.activity_state = .dwelling;
        member.deadline_tick = tick +| step_definition.dwell_ticks;
        self.recordTransition(member.*, previous, .destination_arrived, tick);
    }

    pub fn deferDestination(
        self: *Owner,
        member_id: contract.PopulationMemberId,
        actor: engine.PersistentId,
        activity_sequence: u64,
        tick: u64,
    ) !void {
        const member = self.memberMutable(member_id) orelse
            return error.PopulationMemberNotFound;
        if (member.lifecycle != .live or member.activity_state != .traveling or
            member.actor == null or !std.meta.eql(member.actor.?, actor) or
            member.activity_sequence != activity_sequence or
            member.activity_slot == null)
        {
            return error.StalePopulationDestinationDeferral;
        }
        const previous = member.activity_state;
        self.releaseMemberSlot(member);
        member.activity_state = .waiting_for_slot;
        member.deadline_tick = 0;
        member.retry_tick = tick +| self.config.slot_retry_ticks;
        self.recordTransition(member.*, previous, .destination_deferred, tick);
    }

    pub fn interrupt(
        self: *Owner,
        member_id: contract.PopulationMemberId,
        actor: engine.PersistentId,
        tick: u64,
    ) !void {
        const member = self.memberMutable(member_id) orelse
            return error.PopulationMemberNotFound;
        if (member.lifecycle != .live or member.actor == null or
            !std.meta.eql(member.actor.?, actor))
        {
            return error.InvalidPopulationInterruption;
        }
        const previous = member.activity_state;
        self.releaseMemberSlot(member);
        member.activity_state = .interrupted;
        member.deadline_tick = 0;
        member.retry_tick = 0;
        self.recordTransition(member.*, previous, .encounter_interrupted, tick);
    }

    pub fn resumeActivity(
        self: *Owner,
        member_id: contract.PopulationMemberId,
        actor: engine.PersistentId,
        tick: u64,
    ) !void {
        const member = self.memberMutable(member_id) orelse
            return error.PopulationMemberNotFound;
        if (member.lifecycle != .live or member.activity_state != .interrupted or
            member.actor == null or !std.meta.eql(member.actor.?, actor))
        {
            return error.InvalidPopulationResume;
        }
        const previous = member.activity_state;
        member.activity_state = .selecting;
        self.recordTransition(member.*, previous, .encounter_resumed, tick);
    }

    pub fn vacate(
        self: *Owner,
        member_id: contract.PopulationMemberId,
        actor: engine.PersistentId,
        tick: u64,
    ) !void {
        const member = self.memberMutable(member_id) orelse
            return error.PopulationMemberNotFound;
        if (member.lifecycle != .live or member.actor == null or
            !std.meta.eql(member.actor.?, actor))
        {
            return error.InvalidPopulationVacancy;
        }
        const previous = member.activity_state;
        self.releaseMemberSlot(member);
        member.lifecycle = .vacant;
        member.actor = null;
        member.actor_generation +%= 1;
        if (member.actor_generation == 0) member.actor_generation = 1;
        member.spawn_in_flight = false;
        member.activity_state = .vacant;
        member.deadline_tick = tick +| self.config.replacement_delay_ticks;
        member.retry_tick = member.deadline_tick;
        member.spawn_retry_reason = .none;
        const definition = self.memberDefinition(member.id);
        member.spawn_candidate_cursor = @intCast(
            (@as(usize, member.id.value) + member.actor_generation) %
                definition.replacementSpawnSlots().len,
        );
        self.recordTransition(member.*, previous, .member_vacated, tick);
    }

    pub fn peekIntent(self: *const Owner) ?contract.Intent {
        return self.intents.peek();
    }

    pub fn commitIntent(self: *Owner, expected: contract.Intent) !void {
        const actual = self.intents.peek() orelse return error.PopulationIntentMissing;
        if (!std.meta.eql(actual, expected)) {
            return error.PopulationIntentCommitMismatch;
        }
        _ = self.intents.pop().?;
    }

    pub fn pollIntent(self: *Owner) ?contract.Intent {
        return self.intents.pop();
    }

    pub fn peekTransition(self: *const Owner) ?contract.Transition {
        return self.transitions.peek();
    }

    pub fn commitTransition(self: *Owner, expected: contract.Transition) !void {
        const actual = self.transitions.peek() orelse
            return error.PopulationTransitionMissing;
        if (!std.meta.eql(actual, expected)) {
            return error.PopulationTransitionCommitMismatch;
        }
        _ = self.transitions.pop().?;
    }

    pub fn pollTransition(self: *Owner) ?contract.Transition {
        return self.transitions.pop();
    }

    pub fn members(self: *const Owner) []const contract.MemberRecordV1 {
        return self.member_records[0..self.member_count];
    }

    pub fn slots(self: *const Owner) []const contract.ActivitySlotRecordV1 {
        return &self.slot_records;
    }

    pub fn memberView(
        self: *const Owner,
        id: contract.PopulationMemberId,
    ) ?contract.MemberRecordV1 {
        for (self.members()) |record| {
            if (contract.PopulationMemberId.eql(record.id, id)) return record;
        }
        return null;
    }

    pub fn diagnostics(self: *const Owner) contract.Diagnostics {
        var result = contract.Diagnostics{
            .awaiting_spawn = 0,
            .live = 0,
            .vacant = 0,
            .replacement_pending = 0,
            .selecting = 0,
            .waiting_for_slot = 0,
            .traveling = 0,
            .dwelling = 0,
            .interrupted = 0,
            .free_slots = 0,
            .claimed_slots = 0,
            .occupied_slots = 0,
            .decisions = self.decisions,
            .slot_contentions = self.slot_contentions,
            .lease_expirations = self.lease_expirations,
            .spawn_retries = .{},
            .intents = .{
                .occupancy = @intCast(self.intents.len),
                .high_water = self.intents_high_water,
                .capacity = max_intents,
                .rejected = 0,
            },
            .transitions = .{
                .occupancy = @intCast(self.transitions.len),
                .high_water = self.transitions_high_water,
                .capacity = max_transitions,
                .rejected = self.transition_drops,
            },
        };
        for (self.members()) |record| {
            result.spawn_retries.add(record.spawn_retry_counts);
            switch (record.lifecycle) {
                .awaiting_spawn => result.awaiting_spawn += 1,
                .live => result.live += 1,
                .vacant => result.vacant += 1,
                .replacement_pending => result.replacement_pending += 1,
            }
            switch (record.activity_state) {
                .selecting => result.selecting += 1,
                .waiting_for_slot => result.waiting_for_slot += 1,
                .traveling => result.traveling += 1,
                .dwelling => result.dwelling += 1,
                .interrupted => result.interrupted += 1,
                .completing, .vacant, .replacement_pending => {},
            }
        }
        for (self.slots()) |record| switch (record.state) {
            .free => result.free_slots += 1,
            .claimed => result.claimed_slots += 1,
            .occupied => result.occupied_slots += 1,
        };
        return result;
    }

    pub fn logicalDigest(self: *const Owner) u64 {
        var digest: u64 = 0xcbf29ce484222325;
        digest = mix(digest, catalog.catalog_version);
        digest = mix(digest, @intFromEnum(self.config.cohort));
        digest = mix(digest, self.config.slot_retry_ticks);
        digest = mix(digest, self.config.claim_lease_ticks);
        digest = mix(digest, self.config.replacement_delay_ticks);
        digest = mix(digest, self.config.spawn_retry_ticks);
        digest = mix(digest, self.last_step_tick);
        digest = mix(digest, self.decisions);
        digest = mix(digest, self.slot_contentions);
        digest = mix(digest, self.lease_expirations);
        for (self.members()) |record| {
            digest = mix(digest, record.id.value);
            digest = mix(digest, @intFromEnum(record.lifecycle));
            digest = mix(digest, record.actor_generation);
            digest = mix(digest, @intFromBool(record.spawn_in_flight));
            digest = mix(digest, record.program_cursor);
            digest = mix(digest, record.activity_sequence);
            digest = mix(digest, @intFromEnum(record.activity_state));
            digest = mix(digest, if (record.activity_site) |id| id.value else 0);
            digest = mix(digest, if (record.activity_slot) |id| id.value else 0);
            digest = mix(digest, record.deadline_tick);
            digest = mix(digest, record.retry_tick);
            digest = mix(digest, @intFromEnum(record.spawn_retry_reason));
            digest = mix(digest, record.spawn_candidate_cursor);
            digest = mix(digest, record.spawn_retry_counts.district_inactive);
            digest = mix(digest, record.spawn_retry_counts.occupied);
            digest = mix(digest, record.spawn_retry_counts.npc_overlap);
            digest = mix(digest, record.spawn_retry_counts.player_near);
            digest = mix(digest, record.spawn_retry_counts.player_visible);
            digest = mix(digest, record.spawn_retry_counts.capacity);
            digest = mix(digest, record.last_transition_tick);
            digest = mix(digest, @intFromEnum(record.last_transition_reason));
            if (record.actor) |actor| {
                digest = mix(digest, actor.namespace);
                digest = mix(digest, actor.local);
            } else {
                digest = mix(digest, 0);
                digest = mix(digest, 0);
            }
        }
        for (self.slots()) |record| {
            digest = mix(digest, record.id.value);
            digest = mix(digest, @intFromEnum(record.state));
            digest = mix(digest, if (record.member) |id| id.value else 0);
            digest = mix(digest, record.lease_deadline_tick);
        }
        return digest;
    }

    fn advanceMember(self: *Owner, index: usize, tick: u64) !bool {
        const member = &self.member_records[index];
        return switch (member.lifecycle) {
            .awaiting_spawn => self.requestSpawn(member, false, tick),
            .vacant => if (tick < member.deadline_tick)
                false
            else blk: {
                const previous = member.activity_state;
                member.lifecycle = .replacement_pending;
                member.activity_state = .replacement_pending;
                member.retry_tick = tick;
                self.recordTransition(member.*, previous, .replacement_ready, tick);
                break :blk true;
            },
            .replacement_pending => self.requestSpawn(member, true, tick),
            .live => self.advanceLiveMember(member, tick),
        };
    }

    fn requestSpawn(
        self: *Owner,
        member: *contract.MemberRecordV1,
        replacement: bool,
        tick: u64,
    ) !bool {
        if (member.spawn_in_flight or tick < member.retry_tick) return false;
        if (self.intents.isFull()) return error.PopulationIntentCapacityReached;
        const definition = self.memberDefinition(member.id);
        const candidates = definition.replacementSpawnSlots();
        const slot = candidates[
            @as(usize, member.spawn_candidate_cursor) % candidates.len
        ];
        std.debug.assert(replacement or
            member.spawn_candidate_cursor != 0 or
            contract.SpawnSlotId.eql(slot, definition.initial_spawn_slot));
        const intent = contract.Intent{ .spawn = .{
            .correlation_id = correlation(
                1,
                member.id,
                member.actor_generation,
                member.activity_sequence,
            ),
            .member = member.id,
            .actor_generation = member.actor_generation,
            .replacement = replacement,
            .preferred_slot = slot,
        } };
        self.intents.pushAssumeCapacity(intent);
        self.intents_high_water = @max(
            self.intents_high_water,
            @as(u32, @intCast(self.intents.len)),
        );
        member.spawn_in_flight = true;
        member.spawn_retry_reason = .none;
        self.recordTransition(
            member.*,
            member.activity_state,
            .spawn_requested,
            tick,
        );
        return true;
    }

    fn advanceLiveMember(
        self: *Owner,
        member: *contract.MemberRecordV1,
        tick: u64,
    ) !bool {
        return switch (member.activity_state) {
            .selecting => try self.selectActivity(member, tick),
            .waiting_for_slot => if (tick < member.retry_tick)
                false
            else blk: {
                const previous = member.activity_state;
                member.activity_state = .selecting;
                self.recordTransition(member.*, previous, .slot_retry, tick);
                break :blk true;
            },
            .traveling => if (tick < member.deadline_tick)
                false
            else blk: {
                const previous = member.activity_state;
                self.releaseMemberSlot(member);
                member.activity_state = .waiting_for_slot;
                member.deadline_tick = 0;
                member.retry_tick = tick +| self.config.slot_retry_ticks;
                self.lease_expirations +|= 1;
                self.recordTransition(
                    member.*,
                    previous,
                    .claim_lease_expired,
                    tick,
                );
                break :blk true;
            },
            .dwelling => if (tick < member.deadline_tick)
                false
            else blk: {
                const previous = member.activity_state;
                self.releaseMemberSlot(member);
                const definition = self.memberDefinition(member.id);
                const program = catalog.programDefinition(definition.program) orelse
                    unreachable;
                member.program_cursor = (member.program_cursor + 1) % program.step_count;
                member.activity_state = .completing;
                member.deadline_tick = 0;
                self.recordTransition(member.*, previous, .dwell_completed, tick);
                break :blk true;
            },
            .completing => blk: {
                const previous = member.activity_state;
                member.activity_state = .selecting;
                self.recordTransition(member.*, previous, .slot_retry, tick);
                break :blk true;
            },
            .interrupted => false,
            .vacant, .replacement_pending => error.InvalidLivePopulationState,
        };
    }

    fn selectActivity(
        self: *Owner,
        member: *contract.MemberRecordV1,
        tick: u64,
    ) !bool {
        const actor = member.actor orelse return error.LivePopulationActorMissing;
        const definition = self.memberDefinition(member.id);
        const program = catalog.programDefinition(definition.program) orelse unreachable;
        if (member.program_cursor >= program.step_count) {
            return error.InvalidPopulationProgramCursor;
        }
        const step_definition = program.stepSlice()[member.program_cursor];
        const site = catalog.siteDefinition(step_definition.site) orelse unreachable;
        const candidates = site.slotSlice();
        const rotation = @as(usize, member.id.value) % candidates.len;
        var selected: ?contract.ActivitySlotId = null;
        for (0..candidates.len) |offset| {
            const candidate = candidates[(rotation + offset) % candidates.len];
            const slot = self.slotMutable(candidate) orelse unreachable;
            const slot_definition = catalog.activitySlotDefinition(candidate) orelse
                unreachable;
            if (slot.state == .free and
                slot_definition.activities.accepts(step_definition.kind))
            {
                selected = candidate;
                break;
            }
        }
        const selected_id = selected orelse {
            const previous = member.activity_state;
            member.activity_state = .waiting_for_slot;
            member.activity_site = step_definition.site;
            member.activity_slot = null;
            member.retry_tick = tick +| self.config.slot_retry_ticks;
            self.slot_contentions +|= 1;
            self.recordTransition(member.*, previous, .slot_unavailable, tick);
            return true;
        };
        if (self.intents.isFull()) return error.PopulationIntentCapacityReached;
        const slot = self.slotMutable(selected_id) orelse unreachable;
        const slot_definition = catalog.activitySlotDefinition(selected_id) orelse
            unreachable;
        member.activity_sequence +%= 1;
        if (member.activity_sequence == 0) member.activity_sequence = 1;
        slot.state = .claimed;
        slot.member = member.id;
        slot.lease_deadline_tick = tick +| self.config.claim_lease_ticks;
        const previous = member.activity_state;
        member.activity_state = .traveling;
        member.activity_site = step_definition.site;
        member.activity_slot = selected_id;
        member.deadline_tick = slot.lease_deadline_tick;
        member.retry_tick = 0;
        const intent = contract.Intent{ .set_destination = .{
            .correlation_id = correlation(
                2,
                member.id,
                member.actor_generation,
                member.activity_sequence,
            ),
            .member = member.id,
            .actor_generation = member.actor_generation,
            .actor = actor,
            .activity_sequence = member.activity_sequence,
            .slot = selected_id,
            .destination = slot_definition.destination,
        } };
        self.intents.pushAssumeCapacity(intent);
        self.intents_high_water = @max(
            self.intents_high_water,
            @as(u32, @intCast(self.intents.len)),
        );
        self.recordTransition(member.*, previous, .slot_claimed, tick);
        return true;
    }

    fn releaseMemberSlot(self: *Owner, member: *contract.MemberRecordV1) void {
        const slot_id = member.activity_slot orelse {
            member.activity_site = null;
            return;
        };
        const slot = self.slotMutable(slot_id) orelse unreachable;
        std.debug.assert(slot.member != null and
            contract.PopulationMemberId.eql(slot.member.?, member.id));
        slot.* = .{ .id = slot.id, .state = .free, .lease_deadline_tick = 0 };
        member.activity_site = null;
        member.activity_slot = null;
    }

    fn memberMutable(
        self: *Owner,
        id: contract.PopulationMemberId,
    ) ?*contract.MemberRecordV1 {
        for (self.member_records[0..self.member_count]) |*record| {
            if (contract.PopulationMemberId.eql(record.id, id)) return record;
        }
        return null;
    }

    fn slotMutable(
        self: *Owner,
        id: contract.ActivitySlotId,
    ) ?*contract.ActivitySlotRecordV1 {
        if (id.value == 0 or id.value > self.slot_records.len) return null;
        return &self.slot_records[id.value - 1];
    }

    fn memberDefinition(
        _: *const Owner,
        id: contract.PopulationMemberId,
    ) contract.PopulationMemberDefinition {
        return catalog.memberDefinition(id) orelse unreachable;
    }

    fn recordTransition(
        self: *Owner,
        member: contract.MemberRecordV1,
        previous: contract.ActivityState,
        reason: contract.TransitionReason,
        tick: u64,
    ) void {
        const mutable = self.memberMutable(member.id) orelse unreachable;
        const definition = self.memberDefinition(mutable.id);
        const program = catalog.programDefinition(definition.program) orelse unreachable;
        const activity = program.stepSlice()[mutable.program_cursor];
        mutable.last_transition_tick = tick;
        mutable.last_transition_reason = reason;
        self.transitions.push(.{
            .tick = tick,
            .member = mutable.id,
            .actor_generation = mutable.actor_generation,
            .actor = mutable.actor,
            .previous_state = previous,
            .current_state = mutable.activity_state,
            .reason = reason,
            .site = mutable.activity_site,
            .slot = mutable.activity_slot,
            .program = definition.program,
            .program_cursor = mutable.program_cursor,
            .activity_kind = activity.kind,
            .activity_sequence = mutable.activity_sequence,
            .deadline_tick = mutable.deadline_tick,
            .retry_reason = mutable.spawn_retry_reason,
        }) catch {
            self.transition_drops +|= 1;
            return;
        };
        self.transitions_high_water = @max(
            self.transitions_high_water,
            @as(u32, @intCast(self.transitions.len)),
        );
    }
};

fn correlation(
    kind: u8,
    member: contract.PopulationMemberId,
    generation: u16,
    sequence: u64,
) u64 {
    var value: u64 = 0x504f_5055_4c41_0000;
    value = mix(value, kind);
    value = mix(value, member.value);
    value = mix(value, generation);
    value = mix(value, sequence);
    return if (value == 0) 1 else value;
}

fn mix(seed: u64, value: u64) u64 {
    var result = seed;
    var bytes: [@sizeOf(u64)]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    for (bytes) |byte| {
        result = (result ^ byte) *% 0x100000001b3;
    }
    return result;
}

fn drainTransitions(owner: *Owner) void {
    while (owner.pollTransition() != null) {}
}

fn takeSpawn(owner: *Owner, member_value: u16) ?contract.SpawnIntent {
    while (owner.pollIntent()) |intent| switch (intent) {
        .spawn => |spawn| if (spawn.member.value == member_value) return spawn,
        .set_destination => {},
    };
    return null;
}

test "ordinary roster bootstraps in bounded stable waves" {
    var owner = try Owner.init(.{});
    try owner.step(1);
    var first_wave: [contract.decisions_per_tick]contract.SpawnIntent = undefined;
    for (&first_wave) |*intent| {
        intent.* = (owner.pollIntent() orelse return error.MissingPopulationSpawn).spawn;
    }
    try std.testing.expect(owner.pollIntent() == null);
    for (first_wave, 0..) |intent, index| {
        try std.testing.expectEqual(@as(u16, @intCast(index + 1)), intent.member.value);
        try owner.bindActor(
            intent.member,
            intent.actor_generation,
            .{ .namespace = 1, .local = 100 + index },
            1,
        );
    }
    drainTransitions(&owner);
    try owner.step(2);
    var second_wave_count: usize = 0;
    while (owner.pollIntent()) |intent| {
        try std.testing.expectEqual(
            @as(u16, @intCast(5 + second_wave_count)),
            intent.spawn.member.value,
        );
        second_wave_count += 1;
    }
    try std.testing.expectEqual(contract.decisions_per_tick, second_wave_count);
    try std.testing.expectEqual(@as(u16, 4), owner.diagnostics().live);
    try std.testing.expectEqual(@as(u16, 8), owner.diagnostics().awaiting_spawn);
}

test "same-tick contention claims capacity and exposes one typed wait" {
    var owner = try Owner.init(.{ .cohort = .physical_stress });
    var tick: u64 = 1;
    while (tick <= 4) : (tick += 1) {
        try owner.step(tick);
        while (owner.pollIntent()) |intent| switch (intent) {
            .spawn => |spawn| if (spawn.member.value == 1 or
                spawn.member.value == 10 or spawn.member.value == 13)
            {
                try owner.bindActor(
                    spawn.member,
                    spawn.actor_generation,
                    .{ .namespace = 2, .local = spawn.member.value },
                    tick,
                );
            },
            .set_destination => {},
        };
        drainTransitions(&owner);
    }
    try owner.step(5);
    var destination_count: usize = 0;
    while (owner.pollIntent()) |intent| switch (intent) {
        .set_destination => destination_count += 1,
        .spawn => return error.UnexpectedPopulationSpawn,
    };
    try std.testing.expectEqual(@as(usize, 2), destination_count);
    try std.testing.expectEqual(@as(u16, 1), owner.diagnostics().waiting_for_slot);
    try std.testing.expectEqual(@as(u16, 2), owner.diagnostics().claimed_slots);
    try std.testing.expectEqual(@as(u64, 1), owner.diagnostics().slot_contentions);
}

test "arrival dwell completion and claim lease expiry release exact slots" {
    var owner = try Owner.init(.{
        .claim_lease_ticks = 3,
        .slot_retry_ticks = 2,
    });
    try owner.step(1);
    const spawn = takeSpawn(&owner, 1) orelse return error.MissingPopulationSpawn;
    try owner.bindActor(
        spawn.member,
        spawn.actor_generation,
        .{ .namespace = 3, .local = 1 },
        1,
    );
    while (owner.pollIntent() != null) {}
    drainTransitions(&owner);
    try owner.step(2);
    while (owner.pollIntent() != null) {}
    try owner.step(3);
    while (owner.pollIntent() != null) {}
    try owner.step(4);
    const goal = (owner.pollIntent() orelse return error.MissingPopulationGoal)
        .set_destination;
    try owner.arrive(goal.member, goal.actor, 4);
    try std.testing.expectEqual(
        contract.ActivityState.dwelling,
        owner.memberView(goal.member).?.activity_state,
    );
    const dwell_deadline = owner.memberView(goal.member).?.deadline_tick;
    var next_tick: u64 = 5;
    while (next_tick < dwell_deadline) : (next_tick += 1) {
        try owner.step(next_tick);
        while (owner.pollIntent() != null) {}
    }
    try owner.step(dwell_deadline);
    try std.testing.expectEqual(
        contract.ActivityState.completing,
        owner.memberView(goal.member).?.activity_state,
    );
    try std.testing.expectEqual(@as(u16, 0), owner.diagnostics().occupied_slots);

    var lease_owner = try Owner.init(.{
        .claim_lease_ticks = 2,
        .slot_retry_ticks = 2,
    });
    try lease_owner.step(1);
    const lease_spawn = takeSpawn(&lease_owner, 1) orelse
        return error.MissingPopulationSpawn;
    try lease_owner.bindActor(
        lease_spawn.member,
        lease_spawn.actor_generation,
        .{ .namespace = 4, .local = 1 },
        1,
    );
    while (lease_owner.pollIntent() != null) {}
    try lease_owner.step(2);
    while (lease_owner.pollIntent() != null) {}
    try lease_owner.step(3);
    while (lease_owner.pollIntent() != null) {}
    try lease_owner.step(4);
    while (lease_owner.pollIntent() != null) {}
    try lease_owner.step(5);
    while (lease_owner.pollIntent() != null) {}
    try lease_owner.step(6);
    try std.testing.expectEqual(
        contract.ActivityState.waiting_for_slot,
        lease_owner.memberView(.{ .value = 1 }).?.activity_state,
    );
    try std.testing.expectEqual(@as(u16, 0), lease_owner.diagnostics().claimed_slots);
    try std.testing.expectEqual(@as(u64, 1), lease_owner.diagnostics().lease_expirations);
}

test "interruption and vacancy preserve program while replacing actor generation" {
    var owner = try Owner.init(.{ .replacement_delay_ticks = 2 });
    try owner.step(1);
    const spawn = takeSpawn(&owner, 1) orelse return error.MissingPopulationSpawn;
    const actor = engine.PersistentId{ .namespace = 5, .local = 1 };
    try owner.bindActor(spawn.member, spawn.actor_generation, actor, 1);
    while (owner.pollIntent() != null) {}
    try owner.step(2);
    while (owner.pollIntent() != null) {}
    try owner.step(3);
    while (owner.pollIntent() != null) {}
    try owner.step(4);
    while (owner.pollIntent() != null) {}
    const before = owner.memberView(spawn.member).?;
    try owner.interrupt(spawn.member, actor, 4);
    try std.testing.expectEqual(
        contract.ActivityState.interrupted,
        owner.memberView(spawn.member).?.activity_state,
    );
    try owner.resumeActivity(spawn.member, actor, 5);
    try owner.vacate(spawn.member, actor, 6);
    const vacant = owner.memberView(spawn.member).?;
    try std.testing.expectEqual(before.program_cursor, vacant.program_cursor);
    try std.testing.expectEqual(@as(u16, 2), vacant.actor_generation);
    try owner.step(7);
    while (owner.pollIntent() != null) {}
    try owner.step(8);
    try std.testing.expectEqual(
        contract.MemberLifecycle.replacement_pending,
        owner.memberView(spawn.member).?.lifecycle,
    );
    while (owner.pollIntent() != null) {}
    while (owner.pollIntent() != null) {}
    try owner.step(9);
    const replacement = (owner.pollIntent() orelse
        return error.MissingPopulationReplacement).spawn;
    try std.testing.expect(replacement.replacement);
    try std.testing.expectEqual(spawn.member.value, replacement.member.value);
    try std.testing.expectEqual(@as(u16, 2), replacement.actor_generation);
}

test "intent ownership is exact and logical state is deterministic" {
    var first = try Owner.init(.{});
    var second = try Owner.init(.{});
    try first.step(1);
    try second.step(1);
    try std.testing.expectEqual(first.logicalDigest(), second.logicalDigest());
    const intent = first.peekIntent() orelse return error.MissingPopulationIntent;
    var wrong = intent;
    switch (wrong) {
        .spawn => |*spawn| spawn.correlation_id +%= 1,
        .set_destination => |*goal| goal.correlation_id +%= 1,
    }
    try std.testing.expectError(
        error.PopulationIntentCommitMismatch,
        first.commitIntent(wrong),
    );
    try first.commitIntent(intent);
    try std.testing.expectError(error.PopulationIntentsPending, second.step(2));
}

test "typed spawn deferral retries only after its fixed deadline" {
    var owner = try Owner.init(.{ .spawn_retry_ticks = 3 });
    try owner.step(1);
    const spawn = takeSpawn(&owner, 1) orelse return error.MissingPopulationSpawn;
    try owner.deferSpawn(
        spawn.member,
        spawn.actor_generation,
        .npc_overlap,
        1,
    );
    while (owner.pollIntent() != null) {}

    try owner.step(2);
    while (owner.pollIntent() != null) {}
    try owner.step(3);
    while (owner.pollIntent() != null) {}
    try owner.step(4);

    const retried = takeSpawn(&owner, 1) orelse
        return error.MissingPopulationSpawnRetry;
    try std.testing.expectEqual(contract.SpawnRetryReason.none, owner
        .memberView(spawn.member).?.spawn_retry_reason);
    try std.testing.expectEqual(spawn.actor_generation, retried.actor_generation);
    try std.testing.expect(!contract.SpawnSlotId.eql(
        spawn.preferred_slot,
        retried.preferred_slot,
    ));
    const retry_counts = owner.memberView(spawn.member).?.spawn_retry_counts;
    try std.testing.expectEqual(@as(u32, 1), retry_counts.npc_overlap);
    try std.testing.expectEqual(@as(u64, 1), owner.diagnostics().spawn_retries.total());
}

test "unsafe replacement retains one vacancy and rotates its authored candidate" {
    var owner = try Owner.init(.{
        .replacement_delay_ticks = 1,
        .spawn_retry_ticks = 1,
    });
    try owner.step(1);
    const initial = takeSpawn(&owner, 1) orelse
        return error.MissingPopulationSpawn;
    const actor = engine.PersistentId{ .namespace = 8, .local = 1 };
    try owner.bindActor(initial.member, initial.actor_generation, actor, 1);
    while (owner.pollIntent() != null) {}
    try owner.vacate(initial.member, actor, 1);

    try owner.step(2);
    while (owner.pollIntent() != null) {}
    try owner.step(3);
    const first_replacement = takeSpawn(&owner, 1) orelse
        return error.MissingPopulationReplacement;
    while (owner.pollIntent() != null) {}
    try owner.deferSpawn(
        first_replacement.member,
        first_replacement.actor_generation,
        .player_visible,
        3,
    );
    const pending = owner.memberView(initial.member).?;
    try std.testing.expectEqual(contract.MemberLifecycle.replacement_pending, pending.lifecycle);
    try std.testing.expectEqual(contract.ActivityState.replacement_pending, pending.activity_state);
    try std.testing.expect(pending.actor == null);
    try std.testing.expect(!pending.spawn_in_flight);
    try std.testing.expectEqual(@as(u32, 1), pending.spawn_retry_counts.player_visible);

    try owner.step(4);
    const second_replacement = takeSpawn(&owner, 1) orelse
        return error.MissingPopulationReplacementRetry;
    try std.testing.expectEqual(
        first_replacement.actor_generation,
        second_replacement.actor_generation,
    );
    try std.testing.expect(!contract.SpawnSlotId.eql(
        first_replacement.preferred_slot,
        second_replacement.preferred_slot,
    ));
}

test "transition saturation is bounded and explicitly counted" {
    var owner = try Owner.init(.{
        .claim_lease_ticks = 1,
        .slot_retry_ticks = 1,
    });
    try owner.step(1);
    const spawn = takeSpawn(&owner, 1) orelse return error.MissingPopulationSpawn;
    try owner.bindActor(
        spawn.member,
        spawn.actor_generation,
        .{ .namespace = 7, .local = 1 },
        1,
    );
    while (owner.pollIntent() != null) {}

    var tick: u64 = 2;
    while (tick <= 900) : (tick += 1) {
        try owner.step(tick);
        while (owner.pollIntent() != null) {}
    }

    const diagnostics = owner.diagnostics();
    try std.testing.expectEqual(
        @as(u32, @intCast(max_transitions)),
        diagnostics.transitions.high_water,
    );
    try std.testing.expectEqual(
        @as(u32, @intCast(max_transitions)),
        diagnostics.transitions.occupancy,
    );
    try std.testing.expect(diagnostics.transitions.rejected > 0);
}

test "durable snapshot restores exact population lifecycle state" {
    var owner = try Owner.init(.{
        .slot_retry_ticks = 7,
        .claim_lease_ticks = 40,
        .replacement_delay_ticks = 1,
        .spawn_retry_ticks = 5,
    });
    var tick: u64 = 1;
    while (tick <= 3) : (tick += 1) {
        try owner.step(tick);
        while (owner.pollIntent()) |intent| switch (intent) {
            .spawn => |spawn| try owner.bindActor(
                spawn.member,
                spawn.actor_generation,
                .{ .namespace = 19, .local = spawn.member.value },
                tick,
            ),
            .set_destination => return error.UnexpectedPopulationDestination,
        };
        drainTransitions(&owner);
    }

    try owner.step(4);
    while (owner.pollIntent()) |intent| switch (intent) {
        .spawn => return error.UnexpectedPopulationSpawn,
        .set_destination => |destination| switch (destination.member.value) {
            1 => try owner.arrive(destination.member, destination.actor, 4),
            2 => {},
            3 => try owner.deferDestination(
                destination.member,
                destination.actor,
                destination.activity_sequence,
                4,
            ),
            4 => try owner.interrupt(destination.member, destination.actor, 4),
            else => return error.UnexpectedPopulationDestination,
        },
    };
    try owner.vacate(
        .{ .value = 6 },
        .{ .namespace = 19, .local = 6 },
        4,
    );
    drainTransitions(&owner);

    try owner.step(5);
    while (owner.pollIntent()) |intent| switch (intent) {
        .spawn => return error.UnexpectedPopulationSpawn,
        .set_destination => |destination| try owner.deferDestination(
            destination.member,
            destination.actor,
            destination.activity_sequence,
            5,
        ),
    };
    try owner.vacate(
        .{ .value = 5 },
        .{ .namespace = 19, .local = 5 },
        5,
    );
    drainTransitions(&owner);

    const before = try owner.snapshot();
    const digest = owner.logicalDigest();
    var restored = try Owner.restore(before);
    const after = try restored.snapshot();

    try std.testing.expectEqualDeep(before, after);
    try std.testing.expectEqual(digest, restored.logicalDigest());
    try std.testing.expectEqual(
        contract.ActivityState.dwelling,
        restored.memberView(.{ .value = 1 }).?.activity_state,
    );
    try std.testing.expectEqual(
        contract.ActivityState.traveling,
        restored.memberView(.{ .value = 2 }).?.activity_state,
    );
    try std.testing.expectEqual(
        contract.ActivityState.waiting_for_slot,
        restored.memberView(.{ .value = 3 }).?.activity_state,
    );
    try std.testing.expectEqual(
        contract.ActivityState.interrupted,
        restored.memberView(.{ .value = 4 }).?.activity_state,
    );
    try std.testing.expectEqual(
        contract.MemberLifecycle.vacant,
        restored.memberView(.{ .value = 5 }).?.lifecycle,
    );
    try std.testing.expectEqual(
        contract.MemberLifecycle.replacement_pending,
        restored.memberView(.{ .value = 6 }).?.lifecycle,
    );
}
