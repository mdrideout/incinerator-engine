//! Canonical value contract for the bounded NPC gameplay slice.

const std = @import("std");
const engine = @import("engine_contracts");
const navigation = @import("navigation_contract");

pub const NodeRef = navigation.NodeRef;
pub const ChunkCoord = navigation.ChunkCoord;

pub const max_npcs: usize = 64;
pub const max_pending_commands: usize = 128;
pub const max_outcomes: usize = 128;
pub const max_events: usize = 256;
pub const max_route_nodes: usize = 16;

pub const Budget = struct {
    npcs: u32 = max_npcs,
    controllers: u32 = max_npcs,
    draws: u32 = max_npcs,
    commands: u32 = max_pending_commands,
    outcomes: u32 = max_outcomes,
    events: u32 = max_events,
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
    first: navigation.NodeRef,
    second: navigation.NodeRef,
};

pub const Goal = union(enum) {
    hold,
    navigate_to: navigation.NodeRef,
    patrol_between: PatrolBetween,
};

pub const State = enum(u8) {
    active,
    waiting_at_boundary,
    dormant,
};

pub const PatrolLeg = enum(u8) {
    none,
    toward_first,
    toward_second,
};

pub const RoutePlan = struct {
    nodes: [max_route_nodes]navigation.NodeRef = [_]navigation.NodeRef{.{}} ** max_route_nodes,
    len: u8 = 0,

    pub fn slice(self: *const RoutePlan) []const navigation.NodeRef {
        return self.nodes[0..@min(@as(usize, self.len), max_route_nodes)];
    }

    pub fn next(self: *const RoutePlan, index: u8) ?navigation.NodeRef {
        const next_index = @as(usize, index) + 1;
        if (next_index >= self.len or next_index >= max_route_nodes) return null;
        return self.nodes[next_index];
    }
};

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

/// Compact, canonical persistence cursor. Runtime route scratch and inactive
/// controller state are deliberately excluded from snapshots. `current` and
/// `next` retain the one admitted semantic edge across a save; the remainder
/// is rebuilt at a semantic transition after its content is active again.
pub const NpcRouteCursorV1 = struct {
    current: navigation.NodeRef,
    next: ?navigation.NodeRef = null,
    route_index: u8 = 0,
    patrol_leg: PatrolLeg = .none,
};

pub const SpawnNpc = struct {
    request_id: u64,
    node: navigation.NodeRef,
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
    node: navigation.NodeRef,
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
    goal: Goal,
    route: RouteCursor,
    state: State,
    position: [3]f32,
    velocity: [3]f32,
    facing_yaw: f32,
    controller_present: bool,
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
};

pub const NpcV1 = struct {
    id: engine.PersistentId,
    owner: navigation.ChunkCoord,
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
            try validateNodeRef(spawn.node);
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
        .navigate_to => |target| try validateNodeRef(target),
        .patrol_between => |patrol| {
            try validateNodeRef(patrol.first);
            try validateNodeRef(patrol.second);
            if (navigation.NodeRef.eql(patrol.first, patrol.second)) {
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
