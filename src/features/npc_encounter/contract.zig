//! Backend-neutral contract for the bounded authoritative NPC encounter slice.

const std = @import("std");
const engine = @import("engine_contracts");
const vitals = @import("vitals_contract");

pub const max_records: usize = 64;
pub const max_combatants: usize = 16;
pub const max_directives: usize = 128;
pub const max_damage_proposals: usize = 64;
pub const max_cues: usize = 1024;
pub const max_transition_history: usize = 256;

pub const Config = struct {
    sight_radius: f32 = 20.0,
    sight_facing_cos: f32 = 0.5,
    last_seen_memory_ticks: u16 = 180,
    pursuit_leash: f32 = 30.0,
    ambient_perception_interval_ticks: u8 = 30,
    engaged_perception_interval_ticks: u8 = 6,
    route_replan_interval_ticks: u8 = 12,
    directive_position_threshold: f32 = 0.25,
    search_arrival_distance: f32 = 0.5,
    /// Authored center-to-center pursuit destination. Attack windup begins at
    /// `melee_range`, which is deliberately larger so navigation arrival
    /// tolerance cannot strand the NPC just outside the transition. Either
    /// way, locomotion never targets the player's center.
    combat_standoff_distance: f32 = 1.5,
    melee_range: f32 = 2.25,
    melee_facing_cos: f32 = 0.5,
    attack_windup_ticks: u16 = 30,
    attack_recovery_ticks: u16 = 45,
    attack_damage: u16 = 20,
    death_presentation_ticks: u16 = 90,
    replacement_delay_ticks: u16 = 300,
    replacement_retry_ticks: u16 = 60,
    replacement_min_player_distance: f32 = 8.0,
    replacement_visibility_radius: f32 = 20.0,
    los_queries_per_tick: u8 = 16,
    los_queries_per_npc: u8 = 4,

    pub fn validate(self: Config) !void {
        if (!positiveFinite(self.sight_radius) or
            !unitCos(self.sight_facing_cos) or
            self.last_seen_memory_ticks == 0 or
            !positiveFinite(self.pursuit_leash) or
            self.ambient_perception_interval_ticks == 0 or
            self.engaged_perception_interval_ticks == 0 or
            self.route_replan_interval_ticks == 0 or
            !positiveFinite(self.directive_position_threshold) or
            !positiveFinite(self.search_arrival_distance) or
            !positiveFinite(self.combat_standoff_distance) or
            !positiveFinite(self.melee_range) or
            !unitCos(self.melee_facing_cos) or
            self.attack_windup_ticks == 0 or
            self.attack_recovery_ticks == 0 or
            self.attack_damage == 0 or
            self.death_presentation_ticks == 0 or
            self.replacement_delay_ticks == 0 or
            self.replacement_retry_ticks == 0 or
            !positiveFinite(self.replacement_min_player_distance) or
            !positiveFinite(self.replacement_visibility_radius) or
            self.los_queries_per_tick == 0 or
            self.los_queries_per_npc == 0 or
            self.los_queries_per_npc > self.los_queries_per_tick or
            self.combat_standoff_distance >= self.melee_range or
            self.melee_range >= self.sight_radius or
            self.search_arrival_distance >= self.sight_radius)
        {
            return error.InvalidNpcEncounterConfiguration;
        }
    }
};

pub const ConfigV1 = struct {
    sight_radius: f32,
    sight_facing_cos: f32,
    last_seen_memory_ticks: u16,
    pursuit_leash: f32,
    ambient_perception_interval_ticks: u8,
    engaged_perception_interval_ticks: u8,
    route_replan_interval_ticks: u8,
    directive_position_threshold: f32,
    search_arrival_distance: f32,
    combat_standoff_distance: f32,
    melee_range: f32,
    melee_facing_cos: f32,
    attack_windup_ticks: u16,
    attack_recovery_ticks: u16,
    attack_damage: u16,
    death_presentation_ticks: u16,
    replacement_delay_ticks: u16,
    replacement_retry_ticks: u16,
    replacement_min_player_distance: f32,
    replacement_visibility_radius: f32,
    los_queries_per_tick: u8,
    los_queries_per_npc: u8,

    pub fn fromConfig(config: Config) ConfigV1 {
        return .{
            .sight_radius = config.sight_radius,
            .sight_facing_cos = config.sight_facing_cos,
            .last_seen_memory_ticks = config.last_seen_memory_ticks,
            .pursuit_leash = config.pursuit_leash,
            .ambient_perception_interval_ticks = config.ambient_perception_interval_ticks,
            .engaged_perception_interval_ticks = config.engaged_perception_interval_ticks,
            .route_replan_interval_ticks = config.route_replan_interval_ticks,
            .directive_position_threshold = config.directive_position_threshold,
            .search_arrival_distance = config.search_arrival_distance,
            .combat_standoff_distance = config.combat_standoff_distance,
            .melee_range = config.melee_range,
            .melee_facing_cos = config.melee_facing_cos,
            .attack_windup_ticks = config.attack_windup_ticks,
            .attack_recovery_ticks = config.attack_recovery_ticks,
            .attack_damage = config.attack_damage,
            .death_presentation_ticks = config.death_presentation_ticks,
            .replacement_delay_ticks = config.replacement_delay_ticks,
            .replacement_retry_ticks = config.replacement_retry_ticks,
            .replacement_min_player_distance = config.replacement_min_player_distance,
            .replacement_visibility_radius = config.replacement_visibility_radius,
            .los_queries_per_tick = config.los_queries_per_tick,
            .los_queries_per_npc = config.los_queries_per_npc,
        };
    }

    pub fn toConfig(self: ConfigV1) !Config {
        const result = Config{
            .sight_radius = self.sight_radius,
            .sight_facing_cos = self.sight_facing_cos,
            .last_seen_memory_ticks = self.last_seen_memory_ticks,
            .pursuit_leash = self.pursuit_leash,
            .ambient_perception_interval_ticks = self.ambient_perception_interval_ticks,
            .engaged_perception_interval_ticks = self.engaged_perception_interval_ticks,
            .route_replan_interval_ticks = self.route_replan_interval_ticks,
            .directive_position_threshold = self.directive_position_threshold,
            .search_arrival_distance = self.search_arrival_distance,
            .combat_standoff_distance = self.combat_standoff_distance,
            .melee_range = self.melee_range,
            .melee_facing_cos = self.melee_facing_cos,
            .attack_windup_ticks = self.attack_windup_ticks,
            .attack_recovery_ticks = self.attack_recovery_ticks,
            .attack_damage = self.attack_damage,
            .death_presentation_ticks = self.death_presentation_ticks,
            .replacement_delay_ticks = self.replacement_delay_ticks,
            .replacement_retry_ticks = self.replacement_retry_ticks,
            .replacement_min_player_distance = self.replacement_min_player_distance,
            .replacement_visibility_radius = self.replacement_visibility_radius,
            .los_queries_per_tick = self.los_queries_per_tick,
            .los_queries_per_npc = self.los_queries_per_npc,
        };
        try result.validate();
        return result;
    }
};

pub const State = enum(u8) {
    patrolling = 1,
    pursuing = 2,
    attack_windup = 3,
    attack_recovery = 4,
    searching = 5,
    returning = 6,
};

pub const TransitionReason = enum(u8) {
    sight_acquired = 1,
    damage_instigator = 2,
    attack_range_entered = 3,
    attack_committed = 4,
    recovery_complete = 5,
    target_not_visible = 6,
    target_invalid = 7,
    memory_expired = 8,
    leash_exceeded = 9,
    search_arrived = 10,
    route_resumed = 11,
    navigation_unavailable = 12,
};

pub const AttackDisposition = enum(u8) {
    committed = 1,
    source_dead = 2,
    target_missing = 3,
    target_dead = 4,
    target_ineligible = 5,
    out_of_range = 6,
    not_facing = 7,
    occluded = 8,
    query_budget_deferred = 9,
    source_unavailable = 10,
};

pub const CombatantObservation = struct {
    target: vitals.Target,
    position: [3]f32,
    facing_yaw: f32,
    alive: bool,
    attackable: bool = true,
};

pub const NpcObservation = struct {
    target: vitals.Target,
    position: [3]f32,
    facing_yaw: f32,
    alive: bool,
    hostile_to_players: bool,
    available: bool = true,
    current_health: u16 = vitals.default_max_health,
};

pub const DamageFact = struct {
    source: vitals.Source,
    target: vitals.Target,
    authority_tick: u64,
    applied_amount: u16,
    remaining_health: u16,
    killed: bool,

    pub fn validate(self: DamageFact) !void {
        try self.source.validate();
        try self.target.validate();
        if (self.authority_tick == 0 or self.applied_amount == 0) {
            return error.InvalidNpcEncounterDamageFact;
        }
        if (self.killed != (self.remaining_health == 0)) {
            return error.InvalidNpcEncounterDamageFact;
        }
    }
};

/// Stable correlation domain for damage proposals owned by this feature.
/// Hosts may use this pure contract function to distinguish encounter-owned
/// completions from unrelated producers without consuming a shared FIFO head.
pub fn attackDamageCorrelation(npc: vitals.Target, action_sequence: u32) u64 {
    var value: u64 = 0x5331_3100_0000_0000;
    value = std.hash.Wyhash.hash(value, std.mem.asBytes(&npc.id.namespace));
    value = std.hash.Wyhash.hash(value, std.mem.asBytes(&npc.id.local));
    value = std.hash.Wyhash.hash(value, std.mem.asBytes(&npc.incarnation.value));
    value = std.hash.Wyhash.hash(value, std.mem.asBytes(&action_sequence));
    return if (value == 0) 1 else value;
}

pub const Frame = struct {
    tick: u64,
    players: []const CombatantObservation,
    npcs: []const NpcObservation,
    damage_facts: []const DamageFact,

    pub fn validate(self: Frame) !void {
        if (self.tick == 0 or self.players.len > max_combatants or
            self.npcs.len > max_records)
        {
            return error.InvalidNpcEncounterFrame;
        }
        for (self.players, 0..) |player, index| {
            try validateCombatant(player, .player);
            for (self.players[0..index]) |earlier| {
                if (std.meta.eql(earlier.target, player.target)) {
                    return error.DuplicateNpcEncounterCombatant;
                }
            }
        }
        for (self.npcs, 0..) |npc, index| {
            try validateNpc(npc);
            for (self.npcs[0..index]) |earlier| {
                if (std.meta.eql(earlier.target, npc.target)) {
                    return error.DuplicateNpcEncounterNpc;
                }
            }
        }
        if (self.damage_facts.len > vitals.max_pending_commands) {
            return error.TooManyNpcEncounterDamageFacts;
        }
        for (self.damage_facts) |fact| try fact.validate();
    }
};

pub const Pursue = struct {
    target: vitals.Target,
    position: [3]f32,
};

pub const FaceAndHold = struct {
    target: vitals.Target,
    position: [3]f32,
};

pub const Locomotion = union(enum) {
    pursue: Pursue,
    face_and_hold: FaceAndHold,
    hold,
    resume_route,
};

pub const LocomotionDirective = struct {
    npc: vitals.Target,
    locomotion: Locomotion,
};

pub const StateChanged = struct {
    npc: vitals.Target,
    previous: State,
    current: State,
    reason: TransitionReason,
    authority_tick: u64,
};

pub const TargetChanged = struct {
    npc: vitals.Target,
    previous: ?vitals.Target,
    current: ?vitals.Target,
    authority_tick: u64,
};

pub const AttackStarted = struct {
    npc: vitals.Target,
    target: vitals.Target,
    start_tick: u64,
    impact_tick: u64,
};

pub const AttackResolved = struct {
    npc: vitals.Target,
    target: ?vitals.Target,
    action_sequence: u32,
    authority_tick: u64,
    disposition: AttackDisposition,
};

pub const HitReaction = struct {
    npc: vitals.Target,
    source: vitals.Source,
    authority_tick: u64,
    remaining_health: u16,
};

pub const Died = struct {
    npc: vitals.Target,
    source: vitals.Source,
    authority_tick: u64,
    presentation_until_tick: u64,
};

pub const Cue = union(enum) {
    state_changed: StateChanged,
    target_changed: TargetChanged,
    attack_started: AttackStarted,
    attack_resolved: AttackResolved,
    hit_reaction: HitReaction,
    died: Died,
};

pub const View = struct {
    npc: vitals.Target,
    state: State,
    state_enter_tick: u64,
    target: ?vitals.Target,
    encounter_origin: [3]f32,
    last_seen_position: [3]f32,
    last_seen_tick: u64,
    forget_tick: u64,
    attack_impact_tick: u64,
    ready_tick: u64,
    death_presentation_until_tick: u64,
    alive: bool,
    current_health: u16,
    recent_damage_instigator: ?vitals.Target,
    recent_damage_tick: u64,
    target_visible: bool,
    next_perception_tick: u64,
    last_directive: ?Locomotion,
    last_directive_tick: u64,
};

pub const RecordV1 = struct {
    npc: vitals.Target,
    state: State,
    state_enter_tick: u64,
    target: ?vitals.Target,
    encounter_origin: [3]f32,
    last_seen_position: [3]f32,
    last_seen_tick: u64,
    forget_tick: u64,
    attack_impact_tick: u64,
    ready_tick: u64,
    death_presentation_until_tick: u64,
    attack_sequence: u32,
    last_health: u16,
    alive: bool,
    recent_damage_instigator: ?vitals.Target,
    recent_damage_tick: u64,
    next_perception_tick: u64,
    target_visible: bool,
    force_perception: bool,
    last_directive: ?Locomotion,
    last_directive_tick: u64,
};

pub const Transition = struct {
    npc: vitals.Target,
    previous: State,
    current: State,
    reason: TransitionReason,
    authority_tick: u64,
};

pub const Diagnostics = struct {
    records: u16,
    patrolling: u16,
    pursuing: u16,
    attack_windup: u16,
    attack_recovery: u16,
    searching: u16,
    returning: u16,
    candidates_considered: u64,
    los_queries: u64,
    los_deferred: u64,
    targets_acquired: u64,
    targets_switched: u64,
    targets_lost: u64,
    attacks_started: u64,
    attacks_committed: u64,
    attacks_cancelled: u64,
    hit_reactions: u64,
    directives_pending: u16,
    damage_pending: u16,
    cues_pending: u16,
    transition_history: u16,
};

pub fn assertVisibilityImplementation(comptime Visibility: type) void {
    comptime assertFallibleMethod(
        Visibility,
        "lineClear",
        .{ *Visibility, [3]f32, [3]f32 },
        bool,
    );
}

pub fn lessThanTarget(_: void, lhs: vitals.Target, rhs: vitals.Target) bool {
    if (@intFromEnum(lhs.kind) != @intFromEnum(rhs.kind)) {
        return @intFromEnum(lhs.kind) < @intFromEnum(rhs.kind);
    }
    if (lhs.id.namespace != rhs.id.namespace) return lhs.id.namespace < rhs.id.namespace;
    if (lhs.id.local != rhs.id.local) return lhs.id.local < rhs.id.local;
    return lhs.incarnation.value < rhs.incarnation.value;
}

pub fn validateRecord(record: RecordV1) !void {
    try record.npc.validate();
    if (record.npc.kind != .npc or record.state_enter_tick == 0 or
        record.attack_sequence == 0 or record.alive != (record.last_health != 0) or
        (record.alive and record.death_presentation_until_tick != 0) or
        (!record.alive and record.death_presentation_until_tick == 0))
    {
        return error.InvalidNpcEncounterRecord;
    }
    if (record.target) |target| {
        try target.validate();
        if (target.kind != .player) return error.InvalidNpcEncounterRecord;
    }
    if (record.recent_damage_instigator) |instigator| {
        try instigator.validate();
        if (instigator.kind != .player or record.recent_damage_tick == 0) {
            return error.InvalidNpcEncounterRecord;
        }
    } else if (record.recent_damage_tick != 0) {
        return error.InvalidNpcEncounterRecord;
    }
    try validateVector(record.encounter_origin);
    try validateVector(record.last_seen_position);
    if ((record.last_seen_tick == 0) != (record.forget_tick == 0) or
        (record.last_seen_tick != 0 and record.forget_tick < record.last_seen_tick))
    {
        return error.InvalidNpcEncounterRecord;
    }
    if (record.target_visible and record.target == null) return error.InvalidNpcEncounterRecord;
    if (record.last_directive) |directive| switch (directive) {
        .hold, .resume_route => {},
        .pursue => |value| {
            try value.target.validate();
            try validateVector(value.position);
        },
        .face_and_hold => |value| {
            try value.target.validate();
            try validateVector(value.position);
        },
    };
}

fn validateCombatant(value: CombatantObservation, expected: vitals.TargetKind) !void {
    try value.target.validate();
    if (value.target.kind != expected) return error.InvalidNpcEncounterCombatant;
    try validateVector(value.position);
    if (!std.math.isFinite(value.facing_yaw)) return error.InvalidNpcEncounterCombatant;
}

fn validateNpc(value: NpcObservation) !void {
    try value.target.validate();
    if (value.target.kind != .npc) return error.InvalidNpcEncounterNpc;
    try validateVector(value.position);
    if (!std.math.isFinite(value.facing_yaw)) return error.InvalidNpcEncounterNpc;
    if (value.alive != (value.current_health != 0)) return error.InvalidNpcEncounterNpc;
}

fn validateVector(value: [3]f32) !void {
    for (value) |component| {
        if (!std.math.isFinite(component)) return error.InvalidNpcEncounterVector;
    }
}

fn positiveFinite(value: f32) bool {
    return std.math.isFinite(value) and value > 0;
}

fn unitCos(value: f32) bool {
    return std.math.isFinite(value) and value >= -1 and value <= 1;
}

fn assertFallibleMethod(
    comptime Implementation: type,
    comptime name: []const u8,
    comptime expected_params: anytype,
    comptime expected_payload: type,
) void {
    if (!@hasDecl(Implementation, name)) {
        @compileError("NPC encounter visibility implementation is missing " ++ name);
    }
    const method = switch (@typeInfo(@TypeOf(@field(Implementation, name)))) {
        .@"fn" => |info| info,
        else => @compileError("NPC encounter visibility declaration must be a function"),
    };
    if (method.params.len != expected_params.len) {
        @compileError("NPC encounter visibility method has wrong parameter count");
    }
    inline for (expected_params, 0..) |expected, index| {
        const actual = method.params[index].type orelse
            @compileError("NPC encounter visibility method cannot use anytype");
        if (actual != expected) {
            @compileError("NPC encounter visibility method has incompatible parameter");
        }
    }
    const return_type = method.return_type orelse
        @compileError("NPC encounter visibility method must have a return type");
    const payload = switch (@typeInfo(return_type)) {
        .error_union => |info| info.payload,
        else => @compileError("NPC encounter visibility method must return an error union"),
    };
    if (payload != expected_payload) {
        @compileError("NPC encounter visibility method has incompatible return payload");
    }
}

const ExampleVisibility = struct {
    pub fn lineClear(_: *ExampleVisibility, _: [3]f32, _: [3]f32) !bool {
        return true;
    }
};

test "encounter configuration and visibility capability are explicit" {
    comptime assertVisibilityImplementation(ExampleVisibility);
    try (Config{}).validate();
    const persisted = ConfigV1.fromConfig(.{});
    try std.testing.expectEqualDeep(Config{}, try persisted.toConfig());

    var invalid = Config{};
    invalid.los_queries_per_tick = 0;
    try std.testing.expectError(error.InvalidNpcEncounterConfiguration, invalid.validate());

    invalid = .{};
    invalid.combat_standoff_distance = invalid.melee_range;
    try std.testing.expectError(error.InvalidNpcEncounterConfiguration, invalid.validate());
}

test "encounter frame rejects duplicate generational targets" {
    const player = CombatantObservation{
        .target = .{
            .kind = .player,
            .id = .{ .namespace = 1, .local = 1 },
            .incarnation = .{ .value = 1 },
        },
        .position = .{ 0, 0, 0 },
        .facing_yaw = 0,
        .alive = true,
    };
    try std.testing.expectError(error.DuplicateNpcEncounterCombatant, (Frame{
        .tick = 1,
        .players = &.{ player, player },
        .npcs = &.{},
        .damage_facts = &.{},
    }).validate());
}
