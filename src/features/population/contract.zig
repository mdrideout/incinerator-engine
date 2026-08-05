//! Canonical value contract for authored sandbox population intent.
//!
//! These values contain no ECS entity, physics handle, allocator, session
//! identity, or mutable authority state. The sandbox catalog owns definitions;
//! the population runtime owns member/slot lifecycle; NPC owns movement.

const std = @import("std");
const engine = @import("engine_contracts");
const npc = @import("npc_contract");

pub const max_members: usize = 16;
pub const ordinary_member_count: usize = 12;
pub const max_roles: usize = 3;
pub const max_programs: usize = 4;
pub const max_program_steps: usize = 6;
pub const max_sites: usize = 8;
pub const max_activity_slots: usize = 16;
pub const max_spawn_slots: usize = 24;
pub const max_member_spawn_candidates: usize = 8;
pub const max_site_slots: usize = 3;
pub const decisions_per_tick: usize = 4;
pub const synthetic_command_capacity: usize = npc.max_npcs;

pub const PopulationMemberId = struct {
    value: u16 = 0,

    pub fn validate(self: PopulationMemberId) !void {
        if (self.value == 0) return error.InvalidPopulationMemberId;
    }

    pub fn eql(a: PopulationMemberId, b: PopulationMemberId) bool {
        return a.value == b.value;
    }
};

pub const ActivityProgramId = struct {
    value: u8 = 0,

    pub fn validate(self: ActivityProgramId) !void {
        if (self.value == 0) return error.InvalidActivityProgramId;
    }

    pub fn eql(a: ActivityProgramId, b: ActivityProgramId) bool {
        return a.value == b.value;
    }
};

pub const ActivitySiteId = struct {
    value: u16 = 0,

    pub fn validate(self: ActivitySiteId) !void {
        if (self.value == 0) return error.InvalidActivitySiteId;
    }

    pub fn eql(a: ActivitySiteId, b: ActivitySiteId) bool {
        return a.value == b.value;
    }
};

pub const ActivitySlotId = struct {
    value: u16 = 0,

    pub fn validate(self: ActivitySlotId) !void {
        if (self.value == 0) return error.InvalidActivitySlotId;
    }

    pub fn eql(a: ActivitySlotId, b: ActivitySlotId) bool {
        return a.value == b.value;
    }
};

pub const SpawnSlotId = struct {
    value: u16 = 0,

    pub fn validate(self: SpawnSlotId) !void {
        if (self.value == 0) return error.InvalidSpawnSlotId;
    }

    pub fn eql(a: SpawnSlotId, b: SpawnSlotId) bool {
        return a.value == b.value;
    }
};

pub const Role = enum(u8) {
    resident = 1,
    worker = 2,
    visitor = 3,
};

pub const CombatDisposition = enum(u8) {
    passive = 1,
    hostile_to_players = 2,
};

pub const MemberLifecycle = enum(u8) {
    awaiting_spawn = 1,
    live = 2,
    vacant = 3,
    replacement_pending = 4,
};

pub const ActivityState = enum(u8) {
    selecting = 1,
    waiting_for_slot = 2,
    traveling = 3,
    dwelling = 4,
    completing = 5,
    interrupted = 6,
    vacant = 7,
    replacement_pending = 8,
};

pub const SlotState = enum(u8) {
    free = 1,
    claimed = 2,
    occupied = 3,
};

pub const Cohort = enum(u8) {
    ordinary = 1,
    physical_stress = 2,
};

pub const ConfigV1 = struct {
    cohort: Cohort = .ordinary,
    slot_retry_ticks: u16 = 60,
    claim_lease_ticks: u16 = 900,
    replacement_delay_ticks: u16 = 180,
    spawn_retry_ticks: u16 = 60,

    pub fn validate(self: ConfigV1) !void {
        if (self.slot_retry_ticks == 0 or self.claim_lease_ticks == 0 or
            self.replacement_delay_ticks == 0 or self.spawn_retry_ticks == 0)
        {
            return error.InvalidPopulationConfiguration;
        }
    }
};

pub const SpawnRetryReason = enum(u8) {
    none = 0,
    district_inactive = 1,
    occupied = 2,
    npc_overlap = 3,
    player_near = 4,
    player_visible = 5,
    capacity = 6,
};

pub const SpawnRetryCounts = struct {
    district_inactive: u32 = 0,
    occupied: u32 = 0,
    npc_overlap: u32 = 0,
    player_near: u32 = 0,
    player_visible: u32 = 0,
    capacity: u32 = 0,

    pub fn increment(self: *SpawnRetryCounts, reason: SpawnRetryReason) !void {
        switch (reason) {
            .none => return error.InvalidPopulationSpawnRetryReason,
            .district_inactive => self.district_inactive +|= 1,
            .occupied => self.occupied +|= 1,
            .npc_overlap => self.npc_overlap +|= 1,
            .player_near => self.player_near +|= 1,
            .player_visible => self.player_visible +|= 1,
            .capacity => self.capacity +|= 1,
        }
    }

    pub fn add(self: *SpawnRetryCounts, other: SpawnRetryCounts) void {
        self.district_inactive +|= other.district_inactive;
        self.occupied +|= other.occupied;
        self.npc_overlap +|= other.npc_overlap;
        self.player_near +|= other.player_near;
        self.player_visible +|= other.player_visible;
        self.capacity +|= other.capacity;
    }

    pub fn total(self: SpawnRetryCounts) u64 {
        return @as(u64, self.district_inactive) +
            self.occupied +
            self.npc_overlap +
            self.player_near +
            self.player_visible +
            self.capacity;
    }
};

pub const TransitionReason = enum(u8) {
    cold_bootstrap = 1,
    spawn_requested = 2,
    actor_bound = 3,
    slot_claimed = 4,
    slot_unavailable = 5,
    slot_retry = 6,
    destination_arrived = 7,
    dwell_completed = 8,
    claim_lease_expired = 9,
    encounter_interrupted = 10,
    encounter_resumed = 11,
    member_vacated = 12,
    replacement_ready = 13,
    spawn_deferred = 14,
    destination_deferred = 15,
};

pub const ActivityKind = enum(u8) {
    commute = 1,
    shop = 2,
    visit = 3,
    idle = 4,
};

pub const ActivityKindMask = packed struct(u8) {
    commute: bool = false,
    shop: bool = false,
    visit: bool = false,
    idle: bool = false,
    reserved: u4 = 0,

    pub fn accepts(self: ActivityKindMask, kind: ActivityKind) bool {
        return switch (kind) {
            .commute => self.commute,
            .shop => self.shop,
            .visit => self.visit,
            .idle => self.idle,
        };
    }

    pub fn validate(self: ActivityKindMask) !void {
        if (self.reserved != 0 or
            (!self.commute and !self.shop and !self.visit and !self.idle))
        {
            return error.InvalidActivityKindMask;
        }
    }
};

pub const RoleMask = packed struct(u8) {
    resident: bool = false,
    worker: bool = false,
    visitor: bool = false,
    reserved: u5 = 0,

    pub fn accepts(self: RoleMask, role: Role) bool {
        return switch (role) {
            .resident => self.resident,
            .worker => self.worker,
            .visitor => self.visitor,
        };
    }

    pub fn validate(self: RoleMask) !void {
        if (self.reserved != 0 or
            (!self.resident and !self.worker and !self.visitor))
        {
            return error.InvalidPopulationRoleMask;
        }
    }
};

pub const RoleDefinition = struct {
    role: Role,
    label: []const u8,
    base_color: [4]f32,
};

pub const ActivityStep = struct {
    site: ActivitySiteId,
    kind: ActivityKind,
    dwell_ticks: u16,
};

pub const ActivityProgramDefinition = struct {
    id: ActivityProgramId,
    label: []const u8,
    steps: [max_program_steps]ActivityStep = @splat(.{
        .site = .{},
        .kind = .idle,
        .dwell_ticks = 0,
    }),
    step_count: u8,

    pub fn stepSlice(self: *const ActivityProgramDefinition) []const ActivityStep {
        return self.steps[0..@min(
            @as(usize, self.step_count),
            max_program_steps,
        )];
    }
};

pub const PopulationMemberDefinition = struct {
    id: PopulationMemberId,
    label: []const u8,
    ordinary_product: bool,
    role: Role,
    program: ActivityProgramId,
    phase_offset: u8,
    combat_disposition: CombatDisposition,
    initial_spawn_slot: SpawnSlotId,
    replacement_spawn_slots: [max_member_spawn_candidates]SpawnSlotId =
        @splat(.{}),
    replacement_spawn_slot_count: u8,

    pub fn replacementSpawnSlots(
        self: *const PopulationMemberDefinition,
    ) []const SpawnSlotId {
        return self.replacement_spawn_slots[0..@min(
            @as(usize, self.replacement_spawn_slot_count),
            max_member_spawn_candidates,
        )];
    }
};

pub const ActivitySiteDefinition = struct {
    id: ActivitySiteId,
    label: []const u8,
    owner: npc.ChunkCoord,
    slots: [max_site_slots]ActivitySlotId = @splat(.{}),
    slot_count: u8,

    pub fn slotSlice(self: *const ActivitySiteDefinition) []const ActivitySlotId {
        return self.slots[0..@min(@as(usize, self.slot_count), max_site_slots)];
    }
};

pub const ActivitySlotDefinition = struct {
    id: ActivitySlotId,
    label: []const u8,
    site: ActivitySiteId,
    destination: npc.DestinationId,
    position: [3]f32,
    facing_yaw: f32,
    activities: ActivityKindMask,
};

pub const SpawnSlotDefinition = struct {
    id: SpawnSlotId,
    label: []const u8,
    position: [3]f32,
    facing_yaw: f32,
    anchor: npc.NodeRef,
    roles: RoleMask,
};

pub const Catalog = struct {
    roles: []const RoleDefinition,
    programs: []const ActivityProgramDefinition,
    members: []const PopulationMemberDefinition,
    sites: []const ActivitySiteDefinition,
    activity_slots: []const ActivitySlotDefinition,
    spawn_slots: []const SpawnSlotDefinition,
};

pub const MemberRecordV1 = struct {
    id: PopulationMemberId,
    lifecycle: MemberLifecycle,
    actor: ?engine.PersistentId = null,
    actor_generation: u16,
    spawn_in_flight: bool,
    program_cursor: u8,
    activity_sequence: u64,
    activity_state: ActivityState,
    activity_site: ?ActivitySiteId = null,
    activity_slot: ?ActivitySlotId = null,
    deadline_tick: u64,
    retry_tick: u64,
    spawn_retry_reason: SpawnRetryReason,
    spawn_candidate_cursor: u8,
    spawn_retry_counts: SpawnRetryCounts = .{},
    last_transition_tick: u64,
    last_transition_reason: TransitionReason,
};

pub const ActivitySlotRecordV1 = struct {
    id: ActivitySlotId,
    state: SlotState,
    member: ?PopulationMemberId = null,
    lease_deadline_tick: u64,
};

pub const RuntimeStatsV1 = struct {
    intents_high_water: u32 = 0,
    transitions_high_water: u32 = 0,
    transition_drops: u64 = 0,
    decisions: u64 = 0,
    slot_contentions: u64 = 0,
    lease_expirations: u64 = 0,
};

/// Canonical durable population authority. Output and transition queues are
/// deliberately absent: a save boundary must drain both before serialization.
pub const SnapshotV1 = struct {
    catalog_version: u16,
    config: ConfigV1,
    last_step_tick: u64,
    stats: RuntimeStatsV1,
    members: []const MemberRecordV1,
    slots: []const ActivitySlotRecordV1,
};

pub const SpawnIntent = struct {
    correlation_id: u64,
    member: PopulationMemberId,
    actor_generation: u16,
    replacement: bool,
    preferred_slot: SpawnSlotId,
};

pub const DestinationIntent = struct {
    correlation_id: u64,
    member: PopulationMemberId,
    actor_generation: u16,
    actor: engine.PersistentId,
    activity_sequence: u64,
    slot: ActivitySlotId,
    destination: npc.DestinationId,
};

pub const Intent = union(enum) {
    spawn: SpawnIntent,
    set_destination: DestinationIntent,
};

pub const Transition = struct {
    tick: u64,
    member: PopulationMemberId,
    actor_generation: u16,
    actor: ?engine.PersistentId,
    previous_state: ActivityState,
    current_state: ActivityState,
    reason: TransitionReason,
    site: ?ActivitySiteId,
    slot: ?ActivitySlotId,
    program: ActivityProgramId,
    program_cursor: u8,
    activity_kind: ActivityKind,
    activity_sequence: u64,
    deadline_tick: u64,
    retry_reason: SpawnRetryReason,
};

pub const Diagnostics = struct {
    awaiting_spawn: u16,
    live: u16,
    vacant: u16,
    replacement_pending: u16,
    selecting: u16,
    waiting_for_slot: u16,
    traveling: u16,
    dwelling: u16,
    interrupted: u16,
    free_slots: u16,
    claimed_slots: u16,
    occupied_slots: u16,
    decisions: u64,
    slot_contentions: u64,
    lease_expirations: u64,
    spawn_retries: SpawnRetryCounts,
    intents: engine.diagnostics.QueueStats,
    transitions: engine.diagnostics.QueueStats,
};

/// Historical NPC-boundary pressure producer. It deliberately owns no
/// population member, activity, physical-placement, or product policy.
pub const SyntheticTemplate = struct {
    first_request_id: u64,
    position: [3]f32,
    facing_yaw: f32,
    anchor: npc.NodeRef,
    hostile_to_players: bool,
    goal: npc.Goal,
};

pub const SyntheticBatch = struct {
    commands: [synthetic_command_capacity]npc.Command = undefined,
    len: u8 = 0,

    pub fn slice(self: *const SyntheticBatch) []const npc.Command {
        return self.commands[0..self.len];
    }
};

pub fn planSynthetic(count: usize, template: SyntheticTemplate) !SyntheticBatch {
    if (count > synthetic_command_capacity) {
        return error.SyntheticPopulationCapacityExceeded;
    }
    if (count != 0 and template.first_request_id == 0) {
        return error.InvalidSyntheticPopulationRequestId;
    }
    if (count != 0 and
        template.first_request_id > std.math.maxInt(u64) - (count - 1))
    {
        return error.SyntheticPopulationRequestIdOverflow;
    }
    var result = SyntheticBatch{ .len = @intCast(count) };
    for (result.commands[0..count], 0..) |*command, index| {
        command.* = .{ .spawn = .{
            .request_id = template.first_request_id + index,
            .position = template.position,
            .facing_yaw = template.facing_yaw,
            .anchor = template.anchor,
            .hostile_to_players = template.hostile_to_players,
            .goal = template.goal,
        } };
    }
    return result;
}

pub fn validLabel(label: []const u8) bool {
    return label.len != 0 and label.len <= 48;
}

pub fn validPose(position: [3]f32, facing_yaw: f32) bool {
    for (position) |component| {
        if (!std.math.isFinite(component)) return false;
    }
    return std.math.isFinite(facing_yaw) and
        facing_yaw >= -std.math.pi and facing_yaw < std.math.pi;
}

test "population value identities and masks are explicit and bounded" {
    try (PopulationMemberId{ .value = 1 }).validate();
    try std.testing.expectError(
        error.InvalidPopulationMemberId,
        (PopulationMemberId{}).validate(),
    );
    const activities = ActivityKindMask{ .shop = true, .visit = true };
    try activities.validate();
    try std.testing.expect(activities.accepts(.shop));
    try std.testing.expect(!activities.accepts(.commute));
    const roles = RoleMask{ .resident = true, .visitor = true };
    try roles.validate();
    try std.testing.expect(roles.accepts(.resident));
    try std.testing.expect(!roles.accepts(.worker));
}

test "bounded authored slices clamp hostile lengths without escaping storage" {
    var program = ActivityProgramDefinition{
        .id = .{ .value = 1 },
        .label = "test",
        .step_count = std.math.maxInt(u8),
    };
    try std.testing.expectEqual(max_program_steps, program.stepSlice().len);
    var member = PopulationMemberDefinition{
        .id = .{ .value = 1 },
        .label = "test",
        .ordinary_product = true,
        .role = .resident,
        .program = .{ .value = 1 },
        .phase_offset = 0,
        .combat_disposition = .passive,
        .initial_spawn_slot = .{ .value = 1 },
        .replacement_spawn_slot_count = std.math.maxInt(u8),
    };
    try std.testing.expectEqual(
        max_member_spawn_candidates,
        member.replacementSpawnSlots().len,
    );
}

test "synthetic pressure planning remains stateless and explicitly non-product" {
    const template = SyntheticTemplate{
        .first_request_id = 40,
        .position = .{ 0, 0, 0 },
        .facing_yaw = 0,
        .anchor = .{ .coord = .{ .x = 0, .z = 0 }, .index = 0 },
        .hostile_to_players = false,
        .goal = .hold,
    };
    const first = try planSynthetic(synthetic_command_capacity, template);
    const second = try planSynthetic(synthetic_command_capacity, template);
    try std.testing.expectEqualDeep(first, second);
    try std.testing.expectEqual(synthetic_command_capacity, first.slice().len);
    try std.testing.expectError(
        error.SyntheticPopulationCapacityExceeded,
        planSynthetic(synthetic_command_capacity + 1, template),
    );
}
