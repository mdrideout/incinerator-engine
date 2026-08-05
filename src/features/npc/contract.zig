//! Canonical value contract for the bounded NPC gameplay slice.

const std = @import("std");
const engine = @import("engine_contracts");
const navigation = @import("navigation_contract");
const planner = @import("navigation_planner");

pub const NodeRef = navigation.NodeRef;
pub const ChunkCoord = navigation.ChunkCoord;
pub const DestinationId = navigation.DestinationId;

pub const max_npcs: usize = 64;
pub const max_pending_commands: usize = 128;
pub const max_outcomes: usize = 128;
pub const max_events: usize = 256;
pub const max_navigation_transitions: usize = 256;
pub const max_route_nodes: usize = navigation.max_route_nodes;
pub const max_physical_edge_exclusions: usize = 2;

pub const Budget = struct {
    npcs: u32 = max_npcs,
    controllers: u32 = max_npcs,
    draws: u32 = max_npcs,
    commands: u32 = max_pending_commands,
    outcomes: u32 = max_outcomes,
    events: u32 = max_events,
    navigation_transitions: u32 = max_navigation_transitions,
};

pub const declared_budget = Budget{};

pub const Assets = struct {
    mesh: engine.rendering.MeshHandle = .invalid,
    material: engine.rendering.MaterialHandle = .invalid,
};

pub const Config = struct {
    radius: f32 = 0.35,
    half_height: f32 = 0.45,
    move_speed: f32 = 2.5,
    gravity: f32 = -20,
    terminal_fall_speed: f32 = 55,
    max_slope_radians: f32 = std.math.degreesToRadians(50),
    mass: f32 = 65,
    max_strength: f32 = 100,
    stick_to_floor_distance: f32 = 0.5,
    step_up_height: f32 = 0.4,
    arrival_distance: f32 = 0.08,
    assets: Assets = .{},

    pub fn validate(self: Config) !void {
        try (engine.physics.CharacterDesc{
            .position = .{ 0, 0, 0 },
            .radius = self.radius,
            .half_height = self.half_height,
            .max_slope_radians = self.max_slope_radians,
            .mass = self.mass,
            .max_strength = self.max_strength,
        }).validate();
        if (!std.math.isFinite(self.move_speed) or self.move_speed <= 0 or
            !std.math.isFinite(self.gravity) or self.gravity >= 0 or
            !std.math.isFinite(self.terminal_fall_speed) or
            self.terminal_fall_speed <= 0 or
            !std.math.isFinite(self.stick_to_floor_distance) or
            self.stick_to_floor_distance < 0 or
            !std.math.isFinite(self.step_up_height) or self.step_up_height < 0 or
            !std.math.isFinite(self.arrival_distance) or
            self.arrival_distance <= 0 or self.arrival_distance > 0.25)
        {
            return error.InvalidNpcConfiguration;
        }
        if (!vectorMagnitudeFits(.{ self.move_speed, self.terminal_fall_speed, 0 })) {
            return error.NpcSpeedOutOfRange;
        }
    }
};

pub const NpcConfigV1 = struct {
    radius: f32,
    half_height: f32,
    move_speed: f32,
    gravity: f32,
    terminal_fall_speed: f32,
    max_slope_radians: f32,
    mass: f32,
    max_strength: f32,
    stick_to_floor_distance: f32,
    step_up_height: f32,
    arrival_distance: f32,

    pub fn fromConfig(config: Config) NpcConfigV1 {
        return .{
            .radius = config.radius,
            .half_height = config.half_height,
            .move_speed = config.move_speed,
            .gravity = config.gravity,
            .terminal_fall_speed = config.terminal_fall_speed,
            .max_slope_radians = config.max_slope_radians,
            .mass = config.mass,
            .max_strength = config.max_strength,
            .stick_to_floor_distance = config.stick_to_floor_distance,
            .step_up_height = config.step_up_height,
            .arrival_distance = config.arrival_distance,
        };
    }

    pub fn toConfig(self: NpcConfigV1, assets: Assets) !Config {
        const result = Config{
            .radius = self.radius,
            .half_height = self.half_height,
            .move_speed = self.move_speed,
            .gravity = self.gravity,
            .terminal_fall_speed = self.terminal_fall_speed,
            .max_slope_radians = self.max_slope_radians,
            .mass = self.mass,
            .max_strength = self.max_strength,
            .stick_to_floor_distance = self.stick_to_floor_distance,
            .step_up_height = self.step_up_height,
            .arrival_distance = self.arrival_distance,
            .assets = assets,
        };
        try result.validate();
        return result;
    }

    pub fn validate(self: NpcConfigV1) !void {
        _ = try self.toConfig(.{});
    }
};

pub const PatrolBetween = struct {
    first: DestinationId,
    second: DestinationId,
};

pub const Goal = union(enum) {
    hold,
    navigate_to: DestinationId,
    patrol_between: PatrolBetween,
};

pub const State = enum(u8) {
    active,
    waiting_at_boundary,
    dormant,
};

/// Read-only movement health. A potential stall is diagnostic evidence, not a
/// gameplay exception: authority continues pursuing the same semantic goal.
pub const NavigationProgressState = enum(u8) {
    idle,
    moving,
    waiting_for_content,
    dormant,
    potentially_stalled,
};

pub const NavigationProgress = struct {
    state: NavigationProgressState = .idle,
    target: ?[3]f32 = null,
    no_progress_ticks: u16 = 0,
    last_progress_tick: u64 = 0,
};

/// Semantic navigation execution is independent from controller residency.
/// An NPC may be physically active while waiting, blocked, or arrived.
pub const NavigationStatus = enum(u8) {
    idle,
    resolving,
    following,
    waiting_for_content,
    blocked,
    arrived,
    structurally_unreachable,
};

pub const NavigationReason = enum(u8) {
    none,
    destination_assigned,
    destination_changed,
    restored,
    encounter_resumed,
    external_displacement,
    owner_transferred,
    district_inactive,
    district_generation_changed,
    topology_changed,
    edge_closed,
    physical_obstruction,
    outside_navigation_coverage,
    structurally_disconnected,
    destination_reached,
};

pub const PlanTrigger = enum(u8) {
    destination_assigned,
    destination_changed,
    restored,
    encounter_resumed,
    external_displacement,
    owner_transferred,
    district_generation_changed,
    topology_changed,
    physical_obstruction,
};

pub const PlanResult = enum(u8) {
    none,
    ready,
    waiting_for_content,
    blocked_by_traversal,
    structurally_unreachable,
    invalid_destination,
    invalid_topology,
    capacity_exhausted,
    deferred_budget,
};

pub const NavigationLineage = struct {
    route_revision: u64 = 0,
    planned_tick: u64 = 0,
    topology_revision: u64 = 0,
    last_trigger: PlanTrigger = .destination_assigned,
    last_result: PlanResult = .none,
    replan_count: u32 = 0,
    arrival_tick: ?u64 = null,
    displacement_tick: ?u64 = null,
    teleport_rollback_count: u32 = 0,
};

pub const NavigationTransitionKind = enum(u8) {
    destination_assigned,
    destination_changed,
    plan_requested,
    plan_committed,
    plan_waiting,
    plan_blocked,
    plan_unreachable,
    route_invalidated,
    waypoint_advanced,
    waiting_entered,
    waiting_resumed,
    block_suspected,
    block_confirmed,
    block_cleared,
    displacement_detected,
    anchor_changed,
    destination_arrived,
};

/// Transition-only evidence. Route commits retain the bounded route value so
/// incident capture and deterministic replay never have to infer a fast replan
/// from later state.
pub const NavigationTransition = struct {
    tick: u64,
    id: engine.PersistentId,
    kind: NavigationTransitionKind,
    destination: ?DestinationId = null,
    status: NavigationStatus,
    reason: NavigationReason,
    trigger: PlanTrigger,
    result: PlanResult,
    route_revision: u64,
    topology_revision: u64,
    route: RoutePlan = .{},
    route_index: u8 = 0,
    position: [3]f32,
};

/// Narrow authority port for encounter-owned movement intent. The NPC feature
/// remains the sole owner of controller motion and semantic patrol routes.
pub const EncounterLocomotion = union(enum) {
    pursue_position: [3]f32,
    face_and_hold: [3]f32,
    hold,
    resume_route,

    pub fn validate(self: EncounterLocomotion) !void {
        switch (self) {
            .hold, .resume_route => {},
            .pursue_position, .face_and_hold => |position| for (position) |component| {
                if (!std.math.isFinite(component)) return error.InvalidNpcEncounterPosition;
            },
        }
    }
};

pub const PatrolLeg = enum(u8) {
    none,
    toward_first,
    toward_second,
};

pub const RoutePlan = planner.RoutePlan;
pub const NavigationEdgeExclusion = planner.EdgeExclusion;

pub const RouteCursor = struct {
    plan: RoutePlan = .{},
    patrol_forward: RoutePlan = .{},
    patrol_reverse: RoutePlan = .{},
    index: u8 = 0,
    patrol_leg: PatrolLeg = .none,
    segment_start: [3]f32 = .{ 0, 0, 0 },
    /// Transient restore marker; never serialized.
    needs_rebuild: bool = false,

    pub fn next(self: *const RouteCursor) ?navigation.NodeRef {
        return self.plan.next(self.index);
    }
};

/// Canonical meaning of the compact persisted cursor. An exact prefix retains
/// the next admitted edge and is verified byte-for-byte against active
/// content. A deferred rebuild is an intentional owner-aligned one-node
/// anchor used while encounter or streaming ownership prevents retaining that
/// prefix; it must rebuild before route movement resumes.
pub const PersistedRouteMode = enum(u8) {
    exact_prefix,
    deferred_rebuild,
};

/// Compact, canonical persistence cursor. Runtime route scratch and inactive
/// controller state are deliberately excluded from snapshots. `current` and
/// `next` retain one admitted semantic edge for `exact_prefix`. A
/// `deferred_rebuild` cursor intentionally retains only the owner-aligned
/// current anchor and rebuilds after every required cohort is active again.
pub const NpcRouteCursorV1 = struct {
    current: navigation.NodeRef,
    next: ?navigation.NodeRef = null,
    route_index: u8 = 0,
    patrol_leg: PatrolLeg = .none,
    mode: PersistedRouteMode = .exact_prefix,
};

pub const SpawnNpc = struct {
    request_id: u64,
    position: [3]f32,
    facing_yaw: f32,
    anchor: navigation.NodeRef,
    hostile_to_players: bool,
    goal: Goal = .hold,
};

pub const SetGoal = struct {
    request_id: u64,
    id: engine.PersistentId,
    goal: Goal,
};

pub const DespawnNpc = struct {
    request_id: u64,
    id: engine.PersistentId,
};

pub const Command = union(enum) {
    spawn: SpawnNpc,
    set_goal: SetGoal,
    despawn: DespawnNpc,
};

pub const CommandKind = enum(u8) { spawn, set_goal, despawn };

pub const RejectionReason = enum(u8) {
    capacity_reached,
    controller_capacity_reached,
    npc_not_found,
    not_owned,
    start_district_inactive,
    invalid_start_node,
    start_pose_blocked,
    goal_district_inactive,
    invalid_goal,
    unreachable_goal,
};

pub const CommandRejected = struct {
    command: CommandKind,
    reason: RejectionReason,
    request_id: u64,
    id: ?engine.PersistentId = null,
};

pub const Spawned = struct {
    request_id: u64,
    id: engine.PersistentId,
    owner: navigation.ChunkCoord,
};

pub const GoalSet = struct {
    request_id: u64,
    id: engine.PersistentId,
    goal: Goal,
};

pub const Despawned = struct {
    request_id: u64,
    id: engine.PersistentId,
};

pub const Outcome = union(enum) {
    spawned: Spawned,
    goal_set: GoalSet,
    despawned: Despawned,
    rejected: CommandRejected,
};

pub const StateChanged = struct {
    id: engine.PersistentId,
    previous: State,
    current: State,
};

pub const OwnerTransferred = struct {
    id: engine.PersistentId,
    previous: navigation.ChunkCoord,
    current: navigation.ChunkCoord,
};

pub const GoalReached = struct {
    id: engine.PersistentId,
    destination: DestinationId,
};

pub const Event = union(enum) {
    state_changed: StateChanged,
    owner_transferred: OwnerTransferred,
    goal_reached: GoalReached,
};

pub const EventDropCounts = struct {
    state_changed: u64 = 0,
    owner_transferred: u64 = 0,
    goal_reached: u64 = 0,

    pub fn total(self: EventDropCounts) u64 {
        return self.state_changed +| self.owner_transferred +| self.goal_reached;
    }
};

pub const NpcView = struct {
    id: engine.PersistentId,
    owner: navigation.ChunkCoord,
    hostile_to_players: bool,
    goal: Goal,
    route: RouteCursor,
    state: State,
    position: [3]f32,
    velocity: [3]f32,
    facing_yaw: f32,
    controller_present: bool,
    encounter_locomotion: ?EncounterLocomotion,
    navigation_progress: NavigationProgress,
    navigation_status: NavigationStatus,
    navigation_reason: NavigationReason,
    navigation_lineage: NavigationLineage,
    physical_edge_exclusions: [max_physical_edge_exclusions]NavigationEdgeExclusion =
        [_]NavigationEdgeExclusion{.{
            .source = .{},
            .target = .{},
        }} ** max_physical_edge_exclusions,
    physical_edge_exclusion_count: u8 = 0,
    physical_block_retry_tick: u64 = 0,
};

pub const NpcDraw = struct {
    persistent_id: engine.PersistentId,
    pose: engine.physics.Pose,
    owner: navigation.ChunkCoord,
    state: State,
    radius: f32,
    half_height: f32,
    mesh: engine.rendering.MeshHandle,
    material: engine.rendering.MaterialHandle,
};

pub const Diagnostics = struct {
    active_count: u32,
    waiting_count: u32,
    dormant_count: u32,
    controller_count: u32,
    transfers: u64,
    controllers_suspended: u64,
    controllers_resumed: u64,
    commands: engine.diagnostics.QueueStats,
    outcomes: engine.diagnostics.QueueStats,
    events: engine.diagnostics.QueueStats,
    event_drops: EventDropCounts,
    navigation_transitions: engine.diagnostics.QueueStats,
    replans: u64,
    deferred_replans: u64,
    teleport_rollbacks: u64,
};

pub const NpcV1 = struct {
    id: engine.PersistentId,
    owner: navigation.ChunkCoord,
    hostile_to_players: bool,
    goal: Goal,
    route: NpcRouteCursorV1,
    position: [3]f32,
    velocity: [3]f32,
    facing_yaw: f32,
};

pub fn validateCommand(command: Command) !void {
    switch (command) {
        .spawn => |spawn| {
            if (spawn.request_id == 0) return error.InvalidNpcRequestId;
            try validateNodeRef(spawn.anchor);
            for (spawn.position) |component| {
                if (!std.math.isFinite(component)) return error.InvalidNpcSpawnPosition;
            }
            const owner = try navigation.ownerForPosition(spawn.position);
            if (!navigation.ChunkCoord.eql(owner, spawn.anchor.coord)) {
                return error.NpcSpawnOwnerMismatch;
            }
            const facing = try engine.transform.normalizeFacingYaw(spawn.facing_yaw);
            if (facing != spawn.facing_yaw or
                (spawn.facing_yaw == 0 and std.math.signbit(spawn.facing_yaw)))
            {
                return error.NonCanonicalNpcSpawnFacing;
            }
            try validateGoal(spawn.goal);
        },
        .set_goal => |set_goal| {
            if (set_goal.request_id == 0) return error.InvalidNpcRequestId;
            try set_goal.id.validate();
            try validateGoal(set_goal.goal);
        },
        .despawn => |despawn| {
            if (despawn.request_id == 0) return error.InvalidNpcRequestId;
            try despawn.id.validate();
        },
    }
}

pub fn validateGoal(goal: Goal) !void {
    switch (goal) {
        .hold => {},
        .navigate_to => |destination| try destination.validate(),
        .patrol_between => |patrol| {
            try patrol.first.validate();
            try patrol.second.validate();
            if (DestinationId.eql(patrol.first, patrol.second)) {
                return error.InvalidNpcPatrol;
            }
        },
    }
}

pub fn validateNodeRef(reference: navigation.NodeRef) !void {
    _ = reference;
}

fn vectorMagnitudeFits(values: [3]f32) bool {
    var squared: f64 = 0;
    for (values) |value| {
        if (!std.math.isFinite(value)) return false;
        const wide: f64 = value;
        squared += wide * wide;
    }
    const limit: f64 = engine.physics.max_linear_velocity;
    return squared <= limit * limit;
}

test "NPC contract validates its default configuration" {
    try (Config{}).validate();
}
