//! Bounded navigation-driven NPC authority.
//!
//! NPCs own semantic goals, a fixed route cursor, streamed-district ownership,
//! and CharacterVirtual controller lifetimes. Navigation is queried only
//! through copied generation-aware values. Goal admission performs one bounded
//! fixed-array search; steady ticks only advance the retained cursor.

const std = @import("std");
const engine = @import("incinerator_engine");
const navigation = @import("navigation_contract");

pub const NodeRef = navigation.NodeRef;
pub const ChunkCoord = navigation.ChunkCoord;

const logical_state_domain = "incinerator.npc.logical";
const logical_state_schema: u16 = 2;

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

    fn next(self: *const RoutePlan, index: u8) ?navigation.NodeRef {
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
    commands: engine.contracts.diagnostics.QueueStats,
    outcomes: engine.contracts.diagnostics.QueueStats,
    events: engine.contracts.diagnostics.QueueStats,
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

const FixedQueue = engine.BoundedQueue;

const RouteBuild = union(enum) {
    ready: RoutePlan,
    inactive,
    invalid_content,
    no_path,
};

const GoalRouteBuild = union(enum) {
    ready: RouteCursor,
    inactive,
    invalid_content,
    no_path,
};

pub fn Feature(comptime Controllers: type, comptime NavigationAccess: type) type {
    engine.physics.assertCharacterImplementation(Controllers);
    navigation.assertImplementation(NavigationAccess);

    return struct {
        const Self = @This();

        // Runtime.set is a data-component operation; keep this marker nonzero
        // rather than attempting to set a zero-sized Flecs tag.
        const Npc = struct { marker: u8 = 1 };
        const LogicalState = struct {
            owner: navigation.ChunkCoord,
            goal: Goal,
            route: RouteCursor,
            state: State,
            position: [3]f32,
            velocity: [3]f32,
            facing_yaw: f32,
        };
        /// The controller is valid only for the exact owner content cohort.
        /// Tickets are runtime-only and are never persisted.
        const RuntimeController = struct {
            handle: ?Controllers.Handle = null,
            owner_ticket: ?navigation.LoadTicket = null,
        };
        const TransformHistory = struct {
            previous: engine.physics.Pose,
            current: engine.physics.Pose,
            current_tick: u64,
        };
        const QueuedCommand = struct {
            command: Command,
            eligible_tick: u64,
        };

        runtime: *engine.Runtime,
        controllers: *Controllers,
        navigation_access: *NavigationAccess,
        config: Config,
        records: [max_npcs]engine.RuntimeId = undefined,
        record_count: usize = 0,
        commands: FixedQueue(QueuedCommand, max_pending_commands) = .{},
        outcomes: FixedQueue(Outcome, max_outcomes) = .{},
        events: FixedQueue(Event, max_events) = .{},
        commands_high_water: u32 = 0,
        outcomes_high_water: u32 = 0,
        events_high_water: u32 = 0,
        commands_rejected: u64 = 0,
        event_drops: EventDropCounts = .{},
        transfers: u64 = 0,
        controllers_suspended: u64 = 0,
        controllers_resumed: u64 = 0,
        presentation: [max_npcs]NpcDraw = undefined,
        presentation_count: usize = 0,

        pub fn init(
            runtime: *engine.Runtime,
            controllers: *Controllers,
            navigation_access: *NavigationAccess,
            config: Config,
        ) !Self {
            try config.validate();
            return .{
                .runtime = runtime,
                .controllers = controllers,
                .navigation_access = navigation_access,
                .config = config,
            };
        }

        pub fn register(self: *Self, registry: *engine.FeatureRegistry) !void {
            try registry.registerComponent(Npc);
            try registry.registerComponent(LogicalState);
            try registry.registerComponent(RuntimeController);
            try registry.registerComponent(TransformHistory);
            try registry.addSystem(.commands, "npc.reconcile_and_commands", self, commandsSystem);
            try registry.addSystem(.pre_physics, "npc.controller_update", self, updateSystem);
            try registry.addSystem(.post_physics, "npc.publish_and_transfer", self, publishSystem);
        }

        pub fn deinit(self: *Self) void {
            while (self.record_count != 0) {
                const runtime_id = self.records[self.record_count - 1];
                if (self.runtime.get(runtime_id, RuntimeController)) |controller| {
                    if (controller.handle) |handle| self.destroyControllerOrPanic(handle);
                }
                self.destroyRuntimeOrPanic(runtime_id);
                self.record_count -= 1;
            }
            self.* = undefined;
        }

        pub fn enqueue(self: *Self, command: Command) !void {
            try self.runtime.ensureHealthy();
            try validateCommand(command);
            if (self.commands.len == max_pending_commands or
                self.commands.len + self.outcomes.len >= max_outcomes)
            {
                self.commands_rejected +|= 1;
                return error.NpcCommandQueueFull;
            }
            try self.commands.push(.{
                .command = command,
                .eligible_tick = try self.runtime.commandTargetTick(),
            });
            self.observeQueueHighWater();
        }

        pub fn pollOutcome(self: *Self) ?Outcome {
            const result = self.outcomes.pop();
            self.observeQueueHighWater();
            return result;
        }

        pub fn pollEvent(self: *Self) ?Event {
            const result = self.events.pop();
            self.observeQueueHighWater();
            return result;
        }

        pub fn hasPendingCommands(self: *const Self) bool {
            return self.commands.len != 0;
        }

        pub fn count(self: *const Self) usize {
            return self.record_count;
        }

        pub fn view(self: *Self, id: engine.PersistentId) !NpcView {
            const runtime_id = self.runtime.resolve(id) orelse return error.NpcNotFound;
            _ = self.runtime.get(runtime_id, Npc) orelse return error.NotAnNpc;
            const logical = self.runtime.get(runtime_id, LogicalState) orelse
                return error.NpcLogicalStateInvariantBroken;
            const controller = self.runtime.get(runtime_id, RuntimeController) orelse
                return error.NpcControllerInvariantBroken;
            return .{
                .id = id,
                .owner = logical.owner,
                .goal = logical.goal,
                .route = logical.route,
                .state = logical.state,
                .position = logical.position,
                .velocity = logical.velocity,
                .facing_yaw = logical.facing_yaw,
                .controller_present = controller.handle != null,
            };
        }

        pub fn extract(self: *Self, alpha: f32) ![]const NpcDraw {
            if (!std.math.isFinite(alpha)) return error.InvalidInterpolationAlpha;
            self.presentation_count = 0;
            for (self.records[0..self.record_count]) |runtime_id| {
                const logical = self.runtime.get(runtime_id, LogicalState) orelse
                    return error.NpcLogicalStateInvariantBroken;
                if (logical.state == .dormant) continue;
                const controller = self.runtime.get(runtime_id, RuntimeController) orelse
                    return error.NpcControllerInvariantBroken;
                if (controller.handle == null or controller.owner_ticket == null) {
                    return error.NpcControllerInvariantBroken;
                }
                const history = self.runtime.get(runtime_id, TransformHistory) orelse
                    return error.NpcTransformInvariantBroken;
                if (history.current_tick != self.runtime.tickIndex()) {
                    return error.NpcTransformTickInvariantBroken;
                }
                const pose = try engine.transform.interpolate(
                    history.previous,
                    history.current,
                    alpha,
                );
                self.presentation[self.presentation_count] = .{
                    .persistent_id = try self.runtime.identity(runtime_id),
                    .pose = pose,
                    .owner = logical.owner,
                    .state = logical.state,
                    .radius = self.config.radius,
                    .half_height = self.config.half_height,
                    .mesh = self.config.assets.mesh,
                    .material = self.config.assets.material,
                };
                self.presentation_count += 1;
            }
            std.mem.sort(NpcDraw, self.presentation[0..self.presentation_count], {}, lessThanDraw);
            return self.presentation[0..self.presentation_count];
        }

        pub fn snapshotRecords(
            self: *Self,
            allocator: std.mem.Allocator,
        ) ![]NpcV1 {
            try self.runtime.ensureSnapshotBoundary();
            if (self.hasPendingCommands()) return error.CommandsPending;
            const records = try allocator.alloc(NpcV1, self.record_count);
            errdefer allocator.free(records);
            for (self.records[0..self.record_count], 0..) |runtime_id, index| {
                const logical = self.runtime.get(runtime_id, LogicalState) orelse
                    return error.NpcLogicalStateInvariantBroken;
                const id = try self.runtime.identity(runtime_id);
                records[index] = .{
                    .id = id,
                    .owner = logical.owner,
                    .goal = logical.goal,
                    .route = .{
                        .current = try currentRouteNode(logical.route),
                        .next = logical.route.next(),
                        .route_index = 0,
                        .patrol_leg = logical.route.patrol_leg,
                    },
                    .position = canonicalVector(logical.position),
                    .velocity = canonicalVector(logical.velocity),
                    .facing_yaw = canonicalFloat(normalizeYaw(logical.facing_yaw)),
                };
            }
            std.mem.sort(NpcV1, records, {}, lessThanRecord);
            try validateRecordsWithNavigation(self.navigation_access, records);
            return records;
        }

        /// Restore is registration-only. All records are preflighted before
        /// the first Runtime entity or CharacterVirtual controller exists.
        pub fn restoreRecords(self: *Self, records: []const NpcV1) !void {
            if (self.record_count != 0 or self.hasPendingCommands() or
                self.outcomes.len != 0 or self.events.len != 0)
            {
                return error.RestoreRequiresEmptyFeature;
            }
            try validateRecordsWithNavigation(self.navigation_access, records);
            errdefer self.rollbackAll();
            for (records) |record| try self.restoreOne(record);
        }

        pub fn writeLogicalState(
            self: *Self,
            writer: *engine.contracts.replay.Writer,
        ) !void {
            try self.runtime.ensureOwnerThread();
            writer.writeU8(@intCast(logical_state_domain.len));
            writer.writeBytes(logical_state_domain);
            writer.writeU16(logical_state_schema);
            writer.writeU64(self.runtime.tickIndex());

            var ids: [max_npcs]engine.PersistentId = undefined;
            for (self.records[0..self.record_count], 0..) |runtime_id, index| {
                ids[index] = try self.runtime.identity(runtime_id);
            }
            std.mem.sort(engine.PersistentId, ids[0..self.record_count], {}, lessThanPersistentId);
            writer.writeU32(@intCast(self.record_count));
            for (ids[0..self.record_count]) |id| {
                const value = try self.view(id);
                writePersistentId(writer, id);
                writeCoord(writer, value.owner);
                try writeGoal(writer, value.goal);
                writePersistentRouteCursor(writer, .{
                    .current = try currentRouteNode(value.route),
                    .next = value.route.next(),
                    .route_index = 0,
                    .patrol_leg = value.route.patrol_leg,
                });
                writeState(writer, value.state);
                try writeVector3(writer, value.position);
                try writeVector3(writer, value.velocity);
                try writer.writeF32(value.facing_yaw);
            }
            writer.writeU32(@intCast(self.commands.len));
            for (0..self.commands.len) |index| {
                const queued = self.commands.atAssumeValid(index);
                writer.writeU64(queued.eligible_tick);
                try writeCommand(writer, queued.command);
            }
            writer.writeU32(@intCast(self.outcomes.len));
            for (0..self.outcomes.len) |index| {
                try writeOutcome(writer, self.outcomes.atAssumeValid(index));
            }
            writer.writeU32(@intCast(self.events.len));
            for (0..self.events.len) |index| {
                writeEvent(writer, self.events.atAssumeValid(index));
            }

            // These counters retain observable transition history after the
            // corresponding event FIFO has been drained or saturated.
            writer.writeU64(self.event_drops.state_changed);
            writer.writeU64(self.event_drops.owner_transferred);
            writer.writeU64(self.event_drops.goal_reached);
            writer.writeU64(self.transfers);
            writer.writeU64(self.controllers_suspended);
            writer.writeU64(self.controllers_resumed);
        }

        pub fn diagnostics(self: *const Self) Diagnostics {
            var active: u32 = 0;
            var waiting: u32 = 0;
            var dormant: u32 = 0;
            var controller_count: u32 = 0;
            for (self.records[0..self.record_count]) |runtime_id| {
                if (self.runtime.get(runtime_id, LogicalState)) |logical| switch (logical.state) {
                    .active => active += 1,
                    .waiting_at_boundary => waiting += 1,
                    .dormant => dormant += 1,
                };
                if (self.runtime.get(runtime_id, RuntimeController)) |controller| {
                    if (controller.handle != null) controller_count += 1;
                }
            }
            return .{
                .active_count = active,
                .waiting_count = waiting,
                .dormant_count = dormant,
                .controller_count = controller_count,
                .transfers = self.transfers,
                .controllers_suspended = self.controllers_suspended,
                .controllers_resumed = self.controllers_resumed,
                .commands = .{
                    .occupancy = @intCast(self.commands.len),
                    .high_water = self.commands_high_water,
                    .capacity = max_pending_commands,
                    .rejected = self.commands_rejected,
                },
                .outcomes = .{
                    .occupancy = @intCast(self.outcomes.len),
                    .high_water = self.outcomes_high_water,
                    .capacity = max_outcomes,
                    .rejected = 0,
                },
                .events = .{
                    .occupancy = @intCast(self.events.len),
                    .high_water = self.events_high_water,
                    .capacity = max_events,
                    .rejected = self.event_drops.total(),
                },
                .event_drops = self.event_drops,
            };
        }

        fn commandsSystem(
            raw: *anyopaque,
            _: *engine.Runtime,
            tick: engine.TickContext,
        ) !void {
            const self: *Self = @ptrCast(@alignCast(raw));
            defer self.observeQueueHighWater();
            try self.reconcileResidency();
            const command_count = self.commands.len;
            for (0..command_count) |_| {
                const queued = self.commands.pop() orelse
                    return error.NpcCommandQueueInvariantBroken;
                if (queued.eligible_tick > tick.tick_index) {
                    self.commands.pushAssumeCapacity(queued);
                    continue;
                }
                std.debug.assert(self.outcomes.len < max_outcomes);
                self.outcomes.pushAssumeCapacity(try self.applyCommand(queued.command));
            }
        }

        fn updateSystem(
            raw: *anyopaque,
            _: *engine.Runtime,
            tick: engine.TickContext,
        ) !void {
            const self: *Self = @ptrCast(@alignCast(raw));
            // This second reconciliation is intentional: no controller can
            // move without resolving and comparing its exact owner ticket in
            // the movement phase itself.
            try self.reconcileResidency();
            for (self.records[0..self.record_count]) |runtime_id| {
                const logical = self.runtime.getMut(runtime_id, LogicalState) orelse
                    return error.NpcLogicalStateInvariantBroken;
                if (logical.state == .dormant) continue;
                const runtime_controller = self.runtime.get(runtime_id, RuntimeController) orelse
                    return error.NpcControllerInvariantBroken;
                const handle = runtime_controller.handle orelse
                    return error.NpcControllerInvariantBroken;
                if (runtime_controller.owner_ticket == null or
                    !navigation.ChunkCoord.eql(runtime_controller.owner_ticket.?.coord, logical.owner))
                {
                    return error.NpcControllerTicketInvariantBroken;
                }

                const before = try self.controllers.prepareCharacter(handle);
                var horizontal = [2]f32{ 0, 0 };
                if (logical.state == .active) {
                    if (logical.route.next()) |next_ref| {
                        const target: ?navigation.ResolvedNode = switch (self.navigation_access.resolveNode(next_ref)) {
                            .ready => |resolved| resolved,
                            .district_inactive => blk: {
                                try self.transition(runtime_id, logical, .waiting_at_boundary);
                                break :blk null;
                            },
                            .invalid_reference => return error.NpcRouteReferenceInvalid,
                        };
                        if (target) |resolved| {
                            const dx = resolved.node.position[0] - before.position[0];
                            const dz = resolved.node.position[2] - before.position[2];
                            const distance = @sqrt(dx * dx + dz * dz);
                            if (distance > self.config.arrival_distance) {
                                const speed = @min(
                                    self.config.move_speed,
                                    distance / tick.delta_seconds,
                                );
                                horizontal = .{ dx / distance * speed, dz / distance * speed };
                                logical.facing_yaw = normalizeYaw(std.math.atan2(dx, -dz));
                            }
                        }
                    }
                }
                const moving_towards_ground =
                    before.velocity[1] - before.ground_velocity[1] < 0.1;
                var vertical = before.velocity[1];
                if (before.ground_state == .on_ground and moving_towards_ground) {
                    horizontal[0] += before.ground_velocity[0];
                    horizontal[1] += before.ground_velocity[2];
                    vertical = before.ground_velocity[1];
                }
                const vertical_reference = if (before.ground_state == .on_ground)
                    before.ground_velocity[1]
                else
                    0;
                vertical = vertical_reference + @max(
                    vertical - vertical_reference + self.config.gravity * tick.delta_seconds,
                    -self.config.terminal_fall_speed,
                );
                const velocity = clampVelocity(.{ horizontal[0], vertical, horizontal[1] });
                const after = try self.controllers.updateCharacter(
                    handle,
                    .{
                        .velocity = velocity,
                        .stick_to_floor_distance = self.config.stick_to_floor_distance,
                        .step_up_height = self.config.step_up_height,
                    },
                    tick.delta_seconds,
                );
                logical.velocity = after.velocity;
            }
        }

        fn publishSystem(
            raw: *anyopaque,
            _: *engine.Runtime,
            tick: engine.TickContext,
        ) !void {
            const self: *Self = @ptrCast(@alignCast(raw));
            for (self.records[0..self.record_count]) |runtime_id| {
                const logical = self.runtime.getMut(runtime_id, LogicalState) orelse
                    return error.NpcLogicalStateInvariantBroken;
                if (logical.state == .dormant) continue;
                const runtime_controller = self.runtime.getMut(runtime_id, RuntimeController) orelse
                    return error.NpcControllerInvariantBroken;
                const handle = runtime_controller.handle orelse
                    return error.NpcControllerInvariantBroken;
                const state = try self.controllers.characterState(handle);
                try state.validate();
                logical.position = canonicalVector(state.position);
                logical.velocity = canonicalVector(state.velocity);

                const next_owner = try navigation.ownerForPosition(logical.position);
                if (!navigation.ChunkCoord.eql(next_owner, logical.owner)) {
                    const next_ref = logical.route.next() orelse
                        return error.NpcUnexpectedOwnerTransfer;
                    if (!navigation.ChunkCoord.eql(next_ref.coord, next_owner)) {
                        return error.NpcUnexpectedOwnerTransfer;
                    }
                    const destination = switch (self.navigation_access.resolveNode(next_ref)) {
                        .ready => |resolved| resolved,
                        .district_inactive => return error.NpcEnteredInactiveDistrict,
                        .invalid_reference => return error.NpcRouteReferenceInvalid,
                    };
                    const previous_owner = logical.owner;
                    // CharacterVirtual is world-global rather than owned by a
                    // district backend. Transfer atomically rebinds the same
                    // live handle to the already-resolved destination cohort;
                    // destructive reconstruction is reserved for generation
                    // changes and dormancy.
                    logical.owner = next_owner;
                    runtime_controller.owner_ticket = destination.ticket;
                    self.transfers +|= 1;
                    try self.emitEvent(.{ .owner_transferred = .{
                        .id = try self.runtime.identity(runtime_id),
                        .previous = previous_owner,
                        .current = next_owner,
                    } });
                }

                try self.advanceIfArrived(runtime_id, logical);
                const history = self.runtime.getMut(runtime_id, TransformHistory) orelse
                    return error.NpcTransformInvariantBroken;
                history.previous = history.current;
                history.current = poseFor(logical.position, logical.facing_yaw);
                history.current_tick = tick.tick_index;
            }
        }

        fn applyCommand(self: *Self, command: Command) !Outcome {
            return switch (command) {
                .spawn => |value| self.applySpawn(value),
                .set_goal => |value| self.applySetGoal(value),
                .despawn => |value| self.applyDespawn(value),
            };
        }

        fn applySpawn(self: *Self, spawn: SpawnNpc) !Outcome {
            if (self.record_count >= max_npcs) {
                return rejection(.spawn, .capacity_reached, spawn.request_id, null);
            }
            const start = switch (self.navigation_access.resolveNode(spawn.node)) {
                .ready => |resolved| resolved,
                .district_inactive => return rejection(
                    .spawn,
                    .start_district_inactive,
                    spawn.request_id,
                    null,
                ),
                .invalid_reference => return rejection(
                    .spawn,
                    .invalid_start_node,
                    spawn.request_id,
                    null,
                ),
            };
            const route_result = try self.buildGoalRoute(spawn.node, spawn.goal, start.node.position);
            const route_tag = std.meta.activeTag(route_result);
            if (route_tag == .inactive) {
                return rejection(.spawn, .goal_district_inactive, spawn.request_id, null);
            }
            if (route_tag == .invalid_content) {
                return rejection(.spawn, .invalid_goal, spawn.request_id, null);
            }
            if (route_tag == .no_path) {
                return rejection(.spawn, .unreachable_goal, spawn.request_id, null);
            }
            const route = route_result.ready;
            self.createRecord(
                null,
                start.reference.coord,
                spawn.goal,
                route,
                start.node.position,
                .{ 0, 0, 0 },
                0,
                start.ticket,
            ) catch |err| switch (err) {
                error.TooManyCharacters => return rejection(
                    .spawn,
                    .controller_capacity_reached,
                    spawn.request_id,
                    null,
                ),
                else => return err,
            };
            const runtime_id = self.records[self.record_count - 1];
            return .{ .spawned = .{
                .request_id = spawn.request_id,
                .id = try self.runtime.identity(runtime_id),
                .owner = start.reference.coord,
            } };
        }

        fn applySetGoal(self: *Self, command: SetGoal) !Outcome {
            const runtime_id = self.runtime.resolve(command.id) orelse
                return rejection(.set_goal, .npc_not_found, command.request_id, command.id);
            _ = self.runtime.get(runtime_id, Npc) orelse
                return rejection(.set_goal, .not_owned, command.request_id, command.id);
            const logical = self.runtime.getMut(runtime_id, LogicalState) orelse
                return error.NpcLogicalStateInvariantBroken;
            const start = try ownerRouteNode(logical.*);
            const route_result = try self.buildGoalRoute(start, command.goal, logical.position);
            const route_tag = std.meta.activeTag(route_result);
            if (route_tag == .inactive) {
                return rejection(.set_goal, .goal_district_inactive, command.request_id, command.id);
            }
            if (route_tag == .invalid_content) {
                return rejection(.set_goal, .invalid_goal, command.request_id, command.id);
            }
            if (route_tag == .no_path) {
                return rejection(.set_goal, .unreachable_goal, command.request_id, command.id);
            }
            const route = route_result.ready;
            logical.goal = command.goal;
            logical.route = route;
            return .{ .goal_set = .{
                .request_id = command.request_id,
                .id = command.id,
                .goal = command.goal,
            } };
        }

        fn applyDespawn(self: *Self, command: DespawnNpc) !Outcome {
            const runtime_id = self.runtime.resolve(command.id) orelse
                return rejection(.despawn, .npc_not_found, command.request_id, command.id);
            _ = self.runtime.get(runtime_id, Npc) orelse
                return rejection(.despawn, .not_owned, command.request_id, command.id);
            const controller = self.runtime.getMut(runtime_id, RuntimeController) orelse
                return error.NpcControllerInvariantBroken;
            if (controller.handle) |handle| {
                try self.controllers.destroyCharacter(handle);
                controller.* = .{};
            }
            try self.runtime.destroy(runtime_id);
            try self.removeRecord(runtime_id);
            return .{ .despawned = .{
                .request_id = command.request_id,
                .id = command.id,
            } };
        }

        fn buildGoalRoute(
            self: *Self,
            start: navigation.NodeRef,
            goal: Goal,
            segment_start: [3]f32,
        ) !GoalRouteBuild {
            return switch (goal) {
                .hold => .{ .ready = .{
                    .plan = planWithOne(start),
                    .segment_start = segment_start,
                } },
                .navigate_to => |target| switch (try self.buildRoute(start, target)) {
                    .ready => |plan| .{ .ready = .{
                        .plan = plan,
                        .segment_start = segment_start,
                    } },
                    .inactive => .inactive,
                    .invalid_content => .invalid_content,
                    .no_path => .no_path,
                },
                .patrol_between => |patrol| blk: {
                    const forward = switch (try self.buildRoute(patrol.first, patrol.second)) {
                        .ready => |plan| plan,
                        .inactive => break :blk .inactive,
                        .invalid_content => break :blk .invalid_content,
                        .no_path => break :blk .no_path,
                    };
                    const reverse = switch (try self.buildRoute(patrol.second, patrol.first)) {
                        .ready => |plan| plan,
                        .inactive => break :blk .inactive,
                        .invalid_content => break :blk .invalid_content,
                        .no_path => break :blk .no_path,
                    };
                    var result = RouteCursor{
                        .patrol_forward = forward,
                        .patrol_reverse = reverse,
                        .segment_start = segment_start,
                    };
                    if (navigation.NodeRef.eql(start, patrol.first)) {
                        result.plan = forward;
                        result.patrol_leg = .toward_second;
                    } else if (navigation.NodeRef.eql(start, patrol.second)) {
                        result.plan = reverse;
                        result.patrol_leg = .toward_first;
                    } else {
                        result.plan = switch (try self.buildRoute(start, patrol.first)) {
                            .ready => |plan| plan,
                            .inactive => break :blk .inactive,
                            .invalid_content => break :blk .invalid_content,
                            .no_path => break :blk .no_path,
                        };
                        result.patrol_leg = .toward_first;
                    }
                    break :blk .{ .ready = result };
                },
            };
        }

        fn buildRestoredGoalRoute(
            self: *Self,
            start: navigation.NodeRef,
            goal: Goal,
            persisted_leg: PatrolLeg,
            persisted_next: ?navigation.NodeRef,
            segment_start: [3]f32,
        ) !GoalRouteBuild {
            return switch (goal) {
                .hold, .navigate_to => self.buildGoalRoute(start, goal, segment_start),
                .patrol_between => |patrol| blk: {
                    const forward = switch (try self.buildRoute(patrol.first, patrol.second)) {
                        .ready => |plan| plan,
                        .inactive => break :blk .inactive,
                        .invalid_content => break :blk .invalid_content,
                        .no_path => break :blk .no_path,
                    };
                    const reverse = switch (try self.buildRoute(patrol.second, patrol.first)) {
                        .ready => |plan| plan,
                        .inactive => break :blk .inactive,
                        .invalid_content => break :blk .invalid_content,
                        .no_path => break :blk .no_path,
                    };
                    var leg = persisted_leg;
                    var target = switch (leg) {
                        .toward_first => patrol.first,
                        .toward_second => patrol.second,
                        .none => break :blk .invalid_content,
                    };
                    // A compact null-next endpoint means the inbound leg just
                    // completed; canonical runtime state immediately selects
                    // the outbound leg once its content can be rebuilt.
                    if (persisted_next == null and navigation.NodeRef.eql(start, target)) {
                        switch (leg) {
                            .toward_first => {
                                leg = .toward_second;
                                target = patrol.second;
                            },
                            .toward_second => {
                                leg = .toward_first;
                                target = patrol.first;
                            },
                            .none => unreachable,
                        }
                    }
                    const plan = switch (try self.buildRoute(start, target)) {
                        .ready => |value| value,
                        .inactive => break :blk .inactive,
                        .invalid_content => break :blk .invalid_content,
                        .no_path => break :blk .no_path,
                    };
                    break :blk .{ .ready = .{
                        .plan = plan,
                        .patrol_forward = forward,
                        .patrol_reverse = reverse,
                        .patrol_leg = leg,
                        .segment_start = segment_start,
                    } };
                },
            };
        }

        /// Fixed-array breadth-first admission search. It runs only when a
        /// semantic goal is admitted or rebuilt, never in a steady movement
        /// tick and never allocates.
        fn buildRoute(
            self: *Self,
            start: navigation.NodeRef,
            target: navigation.NodeRef,
        ) !RouteBuild {
            const start_resolved = switch (self.navigation_access.resolveNode(start)) {
                .ready => |resolved| resolved,
                .district_inactive => return .inactive,
                .invalid_reference => return .invalid_content,
            };
            _ = start_resolved;
            switch (self.navigation_access.resolveNode(target)) {
                .ready => {},
                .district_inactive => return .inactive,
                .invalid_reference => return .invalid_content,
            }
            if (navigation.NodeRef.eql(start, target)) return .{ .ready = planWithOne(start) };

            var refs: [max_route_nodes]navigation.NodeRef = undefined;
            var previous: [max_route_nodes]i8 = @splat(-1);
            var queue: [max_route_nodes]u8 = undefined;
            var discovered_count: usize = 1;
            var head: usize = 0;
            var tail: usize = 1;
            refs[0] = start;
            queue[0] = 0;
            var target_index: ?usize = null;

            while (head < tail and target_index == null) : (head += 1) {
                const source_index: usize = queue[head];
                const source_ref = refs[source_index];
                const source = switch (self.navigation_access.resolveNode(source_ref)) {
                    .ready => |resolved| resolved,
                    .district_inactive => return .inactive,
                    .invalid_reference => return error.NpcRouteReferenceInvalid,
                };
                for (0..source.node.edge_count) |ordinal_usize| {
                    const ordinal: u8 = @intCast(ordinal_usize);
                    const resolved_edge = switch (self.navigation_access.resolveEdge(
                        source_ref,
                        ordinal,
                    )) {
                        .ready => |resolved| resolved,
                        .district_inactive => return .inactive,
                        .invalid_reference, .invalid_ordinal => return error.NpcNavigationPortInvariantBroken,
                    };
                    if (!navigation.LoadTicket.eql(resolved_edge.ticket, source.ticket) or
                        !navigation.NodeRef.eql(resolved_edge.source, source_ref) or
                        resolved_edge.ordinal != ordinal)
                    {
                        return error.NpcNavigationTicketInvariantBroken;
                    }
                    const candidate = resolved_edge.edge.target;
                    switch (self.navigation_access.resolveNode(candidate)) {
                        .invalid_reference => return error.NpcNavigationPortInvariantBroken,
                        .district_inactive => continue,
                        .ready => {},
                    }
                    var seen: ?usize = null;
                    for (refs[0..discovered_count], 0..) |existing, index| {
                        if (navigation.NodeRef.eql(existing, candidate)) {
                            seen = index;
                            break;
                        }
                    }
                    if (seen != null) continue;
                    if (discovered_count == max_route_nodes) return .no_path;
                    refs[discovered_count] = candidate;
                    previous[discovered_count] = @intCast(source_index);
                    queue[tail] = @intCast(discovered_count);
                    tail += 1;
                    if (navigation.NodeRef.eql(candidate, target)) target_index = discovered_count;
                    discovered_count += 1;
                }
            }
            const found = target_index orelse return .no_path;
            var reversed: [max_route_nodes]navigation.NodeRef = undefined;
            var length: usize = 0;
            var cursor: i8 = @intCast(found);
            while (cursor >= 0) {
                reversed[length] = refs[@intCast(cursor)];
                length += 1;
                cursor = previous[@intCast(cursor)];
            }
            var plan = RoutePlan{ .len = @intCast(length) };
            for (0..length) |index| plan.nodes[index] = reversed[length - 1 - index];
            return .{ .ready = plan };
        }

        fn reconcileResidency(self: *Self) !void {
            for (self.records[0..self.record_count]) |runtime_id| {
                try self.reconcileOne(runtime_id);
            }
        }

        fn reconcileOne(self: *Self, runtime_id: engine.RuntimeId) !void {
            const logical = self.runtime.getMut(runtime_id, LogicalState) orelse
                return error.NpcLogicalStateInvariantBroken;
            const controller = self.runtime.getMut(runtime_id, RuntimeController) orelse
                return error.NpcControllerInvariantBroken;
            const anchor = try ownerRouteNode(logical.*);
            const resolution = self.navigation_access.resolveNode(anchor);
            switch (resolution) {
                .invalid_reference => return error.NpcOwnerReferenceInvalid,
                .district_inactive => {
                    if (controller.handle) |handle| {
                        const state = try self.controllers.characterState(handle);
                        logical.position = canonicalVector(state.position);
                        logical.velocity = canonicalVector(state.velocity);
                        try self.controllers.destroyCharacter(handle);
                        controller.* = .{};
                        self.controllers_suspended +|= 1;
                    } else if (controller.owner_ticket != null) {
                        return error.NpcControllerTicketInvariantBroken;
                    }
                    try self.transition(runtime_id, logical, .dormant);
                    return;
                },
                .ready => |resolved| {
                    if (!navigation.ChunkCoord.eql(resolved.ticket.coord, logical.owner)) {
                        return error.NpcOwnerTicketMismatch;
                    }
                    if (controller.handle) |handle| {
                        const old_ticket = controller.owner_ticket orelse
                            return error.NpcControllerTicketInvariantBroken;
                        if (!navigation.LoadTicket.eql(old_ticket, resolved.ticket)) {
                            const state = try self.controllers.characterState(handle);
                            logical.position = canonicalVector(state.position);
                            logical.velocity = canonicalVector(state.velocity);
                            try self.controllers.destroyCharacter(handle);
                            controller.* = .{};
                            self.controllers_suspended +|= 1;
                        }
                    } else if (controller.owner_ticket != null) {
                        return error.NpcControllerTicketInvariantBroken;
                    }
                    if (logical.route.needs_rebuild and
                        logical.route.next() == null and
                        try self.rebuildTargetReady(logical.*))
                    {
                        try self.rebuildRestoredRoute(logical);
                    }
                    if (controller.handle == null) {
                        try self.createController(logical, controller, resolved.ticket);
                        self.controllers_resumed +|= 1;
                    }
                    const desired: State = if (try self.destinationReady(logical.*))
                        .active
                    else
                        .waiting_at_boundary;
                    try self.transition(runtime_id, logical, desired);
                },
            }
        }

        fn destinationReady(self: *Self, logical: LogicalState) !bool {
            const next_ref = logical.route.next() orelse return true;
            return switch (self.navigation_access.resolveNode(next_ref)) {
                .ready => true,
                .district_inactive => false,
                .invalid_reference => error.NpcRouteReferenceInvalid,
            };
        }

        /// A single node probe gates semantic route reconstruction. Inactive
        /// restored goals therefore do not trigger a graph search every tick.
        fn rebuildTargetReady(self: *Self, logical: LogicalState) !bool {
            const current = try currentRouteNode(logical.route);
            const target: ?navigation.NodeRef = switch (logical.goal) {
                .hold => null,
                .navigate_to => |value| value,
                .patrol_between => |patrol| switch (logical.route.patrol_leg) {
                    .toward_first => if (navigation.NodeRef.eql(current, patrol.first))
                        patrol.second
                    else
                        patrol.first,
                    .toward_second => if (navigation.NodeRef.eql(current, patrol.second))
                        patrol.first
                    else
                        patrol.second,
                    .none => return error.NpcPatrolCursorInvariantBroken,
                },
            };
            const reference = target orelse return false;
            return switch (self.navigation_access.resolveNode(reference)) {
                .ready => true,
                .district_inactive => false,
                .invalid_reference => error.NpcRouteReferenceInvalid,
            };
        }

        fn rebuildRestoredRoute(self: *Self, logical: *LogicalState) !void {
            const persisted_next = logical.route.next();
            const current = try currentRouteNode(logical.route);
            const rebuilt = switch (try self.buildRestoredGoalRoute(
                current,
                logical.goal,
                logical.route.patrol_leg,
                persisted_next,
                logical.position,
            )) {
                .ready => |route| route,
                .inactive => return,
                .invalid_content => return error.NpcPersistedGoalInvalid,
                .no_path => return error.NpcPersistedGoalUnreachable,
            };
            if (!isCompletedPatrolEndpoint(
                logical.goal,
                current,
                logical.route.patrol_leg,
                persisted_next,
            ) and !optionalNodeRefEql(persisted_next, rebuilt.next())) {
                return error.NpcPersistedRouteMismatch;
            }
            logical.route = rebuilt;
        }

        fn createRecord(
            self: *Self,
            restored_id: ?engine.PersistentId,
            owner: navigation.ChunkCoord,
            goal: Goal,
            route: RouteCursor,
            position: [3]f32,
            velocity: [3]f32,
            facing_yaw: f32,
            ticket: ?navigation.LoadTicket,
        ) !void {
            if (self.record_count >= max_npcs) return error.TooManyNpcs;
            const runtime_id = if (restored_id) |id|
                try self.runtime.createWithPersistentId(id)
            else
                try self.runtime.create();
            errdefer self.destroyRuntimeOrPanic(runtime_id);

            var logical = LogicalState{
                .owner = owner,
                .goal = goal,
                .route = route,
                .state = if (ticket == null) .dormant else .active,
                .position = canonicalVector(position),
                .velocity = canonicalVector(velocity),
                .facing_yaw = canonicalFloat(normalizeYaw(facing_yaw)),
            };
            var controller = RuntimeController{};
            if (ticket) |active_ticket| {
                try self.createController(&logical, &controller, active_ticket);
            }
            errdefer if (controller.handle) |handle| self.destroyControllerOrPanic(handle);
            const pose = poseFor(logical.position, logical.facing_yaw);
            try self.runtime.set(runtime_id, Npc, .{});
            try self.runtime.set(runtime_id, LogicalState, logical);
            try self.runtime.set(runtime_id, RuntimeController, controller);
            try self.runtime.set(runtime_id, TransformHistory, .{
                .previous = pose,
                .current = pose,
                .current_tick = self.runtime.tickIndex(),
            });
            self.records[self.record_count] = runtime_id;
            self.record_count += 1;
        }

        fn restoreOne(self: *Self, record: NpcV1) !void {
            var route = routeFromRecord(record.route, record.position);
            // If every relevant cohort is active, rebuild and re-verify the
            // lean record before installing it. Otherwise the retained edge
            // is checked again before movement after activation.
            switch (try self.buildRestoredGoalRoute(
                record.route.current,
                record.goal,
                record.route.patrol_leg,
                record.route.next,
                record.position,
            )) {
                .ready => |rebuilt| {
                    if (!isCompletedPatrolEndpoint(
                        record.goal,
                        record.route.current,
                        record.route.patrol_leg,
                        record.route.next,
                    ) and !optionalNodeRefEql(record.route.next, rebuilt.next())) {
                        return error.NpcPersistedRouteMismatch;
                    }
                    route = rebuilt;
                },
                .inactive => {},
                .invalid_content => return error.NpcPersistedGoalInvalid,
                .no_path => return error.NpcPersistedGoalUnreachable,
            }
            const anchor = ownerRouteNodeValue(record.owner, route) orelse
                return error.NpcPersistedOwnerRouteMismatch;
            const ticket: ?navigation.LoadTicket = switch (self.navigation_access.resolveNode(anchor)) {
                .ready => |resolved| resolved.ticket,
                .district_inactive => null,
                .invalid_reference => return error.NpcPersistedRouteInvalid,
            };
            try self.createRecord(
                record.id,
                record.owner,
                record.goal,
                route,
                record.position,
                record.velocity,
                record.facing_yaw,
                ticket,
            );
            const runtime_id = self.records[self.record_count - 1];
            const logical = self.runtime.getMut(runtime_id, LogicalState) orelse
                return error.NpcLogicalStateInvariantBroken;
            const desired: State = if (ticket == null)
                .dormant
            else if (try self.destinationReady(logical.*))
                .active
            else
                .waiting_at_boundary;
            logical.state = desired;
        }

        fn createController(
            self: *Self,
            logical: *LogicalState,
            runtime_controller: *RuntimeController,
            ticket: navigation.LoadTicket,
        ) !void {
            if (!navigation.ChunkCoord.eql(ticket.coord, logical.owner)) {
                return error.NpcOwnerTicketMismatch;
            }
            if (runtime_controller.handle != null or runtime_controller.owner_ticket != null) {
                return error.NpcControllerAlreadyPresent;
            }
            const handle = try self.controllers.createCharacter(.{
                .position = logical.position,
                .velocity = logical.velocity,
                .radius = self.config.radius,
                .half_height = self.config.half_height,
                .max_slope_radians = self.config.max_slope_radians,
                .mass = self.config.mass,
                .max_strength = self.config.max_strength,
            });
            errdefer self.destroyControllerOrPanic(handle);
            const state = try self.controllers.characterState(handle);
            try state.validate();
            logical.position = canonicalVector(state.position);
            logical.velocity = canonicalVector(state.velocity);
            runtime_controller.* = .{
                .handle = handle,
                .owner_ticket = ticket,
            };
        }

        fn advanceIfArrived(self: *Self, runtime_id: engine.RuntimeId, logical: *LogicalState) !void {
            const next_ref = logical.route.next() orelse return;
            const target = switch (self.navigation_access.resolveNode(next_ref)) {
                .ready => |resolved| resolved,
                .district_inactive => return,
                .invalid_reference => return error.NpcRouteReferenceInvalid,
            };
            const dx = target.node.position[0] - logical.position[0];
            const dz = target.node.position[2] - logical.position[2];
            const distance = @sqrt(dx * dx + dz * dz);
            if (distance > self.config.arrival_distance and
                !passedTarget(logical.route.segment_start, target.node.position, logical.position))
            {
                return;
            }
            logical.route.index += 1;
            logical.route.segment_start = logical.position;
            if (logical.route.next() != null) return;

            try self.emitEvent(.{ .goal_reached = .{
                .id = try self.runtime.identity(runtime_id),
                .node = next_ref,
            } });
            switch (logical.goal) {
                .hold, .navigate_to => {},
                .patrol_between => {
                    var next_plan: RoutePlan = undefined;
                    var next_leg: PatrolLeg = undefined;
                    switch (logical.route.patrol_leg) {
                        .toward_first => {
                            next_plan = logical.route.patrol_forward;
                            next_leg = .toward_second;
                        },
                        .toward_second => {
                            next_plan = logical.route.patrol_reverse;
                            next_leg = .toward_first;
                        },
                        .none => return error.NpcPatrolCursorInvariantBroken,
                    }
                    if (next_plan.len == 0) {
                        const rebuilt = switch (try self.buildRestoredGoalRoute(
                            next_ref,
                            logical.goal,
                            logical.route.patrol_leg,
                            null,
                            logical.position,
                        )) {
                            .ready => |value| value,
                            .inactive => {
                                logical.route.needs_rebuild = true;
                                return;
                            },
                            .invalid_content => return error.NpcPersistedGoalInvalid,
                            .no_path => return error.NpcPersistedGoalUnreachable,
                        };
                        logical.route = rebuilt;
                    } else {
                        const forward = logical.route.patrol_forward;
                        const reverse = logical.route.patrol_reverse;
                        logical.route = .{
                            .plan = next_plan,
                            .patrol_forward = forward,
                            .patrol_reverse = reverse,
                            .patrol_leg = next_leg,
                            .segment_start = target.node.position,
                        };
                    }
                },
            }
        }

        fn transition(
            self: *Self,
            runtime_id: engine.RuntimeId,
            logical: *LogicalState,
            desired: State,
        ) !void {
            if (logical.state == desired) return;
            const previous = logical.state;
            logical.state = desired;
            try self.emitEvent(.{ .state_changed = .{
                .id = try self.runtime.identity(runtime_id),
                .previous = previous,
                .current = desired,
            } });
        }

        fn emitEvent(self: *Self, event: Event) !void {
            if (self.events.len < max_events) {
                self.events.pushAssumeCapacity(event);
                self.observeQueueHighWater();
                return;
            }
            switch (event) {
                .state_changed => self.event_drops.state_changed +|= 1,
                .owner_transferred => self.event_drops.owner_transferred +|= 1,
                .goal_reached => self.event_drops.goal_reached +|= 1,
            }
        }

        fn removeRecord(self: *Self, runtime_id: engine.RuntimeId) !void {
            for (self.records[0..self.record_count], 0..) |candidate, index| {
                if (std.meta.eql(candidate, runtime_id)) {
                    self.record_count -= 1;
                    self.records[index] = self.records[self.record_count];
                    return;
                }
            }
            return error.NpcRecordIndexInvariantBroken;
        }

        fn rollbackAll(self: *Self) void {
            while (self.record_count != 0) {
                const runtime_id = self.records[self.record_count - 1];
                if (self.runtime.get(runtime_id, RuntimeController)) |controller| {
                    if (controller.handle) |handle| self.destroyControllerOrPanic(handle);
                }
                self.destroyRuntimeOrPanic(runtime_id);
                self.record_count -= 1;
            }
        }

        fn observeQueueHighWater(self: *Self) void {
            self.commands_high_water = @max(self.commands_high_water, @as(u32, @intCast(self.commands.len)));
            self.outcomes_high_water = @max(self.outcomes_high_water, @as(u32, @intCast(self.outcomes.len)));
            self.events_high_water = @max(self.events_high_water, @as(u32, @intCast(self.events.len)));
        }

        fn destroyControllerOrPanic(self: *Self, handle: Controllers.Handle) void {
            self.controllers.destroyCharacter(handle) catch |err| {
                std.debug.panic("NPC controller cleanup failed: {s}", .{@errorName(err)});
            };
        }

        fn destroyRuntimeOrPanic(self: *Self, runtime_id: engine.RuntimeId) void {
            self.runtime.destroy(runtime_id) catch |err| {
                std.debug.panic("NPC runtime cleanup failed: {s}", .{@errorName(err)});
            };
        }
    };
}

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

fn validateGoal(goal: Goal) !void {
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

fn validateNodeRef(reference: navigation.NodeRef) !void {
    _ = reference;
}

/// Cold snapshot preflight. The access may be a catalog-backed validator or
/// the live district port; no Runtime entity or physics controller is needed.
pub fn validateRecordsWithNavigation(
    navigation_access: anytype,
    records: []const NpcV1,
) !void {
    const Access = @TypeOf(navigation_access.*);
    navigation.assertImplementation(Access);
    if (records.len > max_npcs) return error.TooManyNpcs;
    for (records, 0..) |record, record_index| {
        try record.id.validate();
        for (records[0..record_index]) |earlier| {
            if (std.meta.eql(earlier.id, record.id)) return error.DuplicateNpcPersistentId;
        }
        try validateGoal(record.goal);
        try validateFiniteVector(record.position);
        try validateFiniteVector(record.velocity);
        try (engine.physics.Velocity{ .linear = record.velocity }).validate();
        if (!std.math.isFinite(record.facing_yaw) or
            record.facing_yaw != normalizeYaw(record.facing_yaw) or
            isNegativeZero(record.facing_yaw))
        {
            return error.NonCanonicalNpcFacing;
        }
        for (record.position) |component| {
            if (isNegativeZero(component)) return error.NonCanonicalNpcPosition;
        }
        for (record.velocity) |component| {
            if (isNegativeZero(component)) return error.NonCanonicalNpcVelocity;
        }
        const owner = try navigation.ownerForPosition(record.position);
        if (!navigation.ChunkCoord.eql(owner, record.owner)) {
            return error.NpcOwnerPositionMismatch;
        }
        if (record.route.route_index != 0) return error.NonCanonicalNpcRouteIndex;
        try validateNodeRef(record.route.current);
        if (record.route.next) |next| {
            try validateNodeRef(next);
            if (navigation.NodeRef.eql(record.route.current, next)) {
                return error.NpcRouteCursorSelfEdge;
            }
            switch (navigation_access.validateTraversal(record.route.current, next)) {
                .valid => {},
                .invalid_source, .invalid_target => return error.NpcPersistedRouteInvalid,
                .not_connected => return error.NpcPersistedRouteMismatch,
            }
        }
        if (ownerRouteNodeValue(record.owner, routeFromRecord(record.route, record.position)) == null) {
            return error.NpcPersistedOwnerRouteMismatch;
        }

        try requireValidContentNode(navigation_access, record.route.current);
        if (record.route.next) |next| try requireValidContentNode(navigation_access, next);
        switch (record.goal) {
            .hold => {
                if (record.route.next != null or record.route.patrol_leg != .none) {
                    return error.NpcHoldCursorMismatch;
                }
            },
            .navigate_to => |target| {
                try requireValidContentNode(navigation_access, target);
                if (record.route.patrol_leg != .none) return error.NpcNavigateCursorMismatch;
                if ((record.route.next == null) !=
                    navigation.NodeRef.eql(record.route.current, target))
                {
                    return error.NpcNavigateCursorMismatch;
                }
                try verifyActiveRoutePrefix(
                    navigation_access,
                    record.route.current,
                    target,
                    record.route.next,
                );
            },
            .patrol_between => |patrol| {
                try requireValidContentNode(navigation_access, patrol.first);
                try requireValidContentNode(navigation_access, patrol.second);
                const target = switch (record.route.patrol_leg) {
                    .toward_first => patrol.first,
                    .toward_second => patrol.second,
                    .none => return error.NpcPatrolCursorMismatch,
                };
                if ((record.route.next == null) !=
                    navigation.NodeRef.eql(record.route.current, target))
                {
                    return error.NpcPatrolCursorMismatch;
                }
                try verifyActiveRoutePrefix(
                    navigation_access,
                    record.route.current,
                    target,
                    record.route.next,
                );
            },
        }
    }
}

fn requireValidContentNode(access: anytype, reference: navigation.NodeRef) !void {
    switch (access.resolveNode(reference)) {
        .ready, .district_inactive => {},
        .invalid_reference => return error.NpcPersistedRouteInvalid,
    }
}

fn verifyActiveRoutePrefix(
    access: anytype,
    start: navigation.NodeRef,
    target: navigation.NodeRef,
    expected_next: ?navigation.NodeRef,
) !void {
    const route = switch (try buildRouteForValidation(access, start, target)) {
        .ready => |plan| plan,
        .inactive => return,
        .invalid_content => return error.NpcPersistedRouteInvalid,
        .no_path => return error.NpcPersistedGoalUnreachable,
    };
    if (!optionalNodeRefEql(expected_next, route.next(0))) {
        return error.NpcPersistedRouteMismatch;
    }
}

fn buildRouteForValidation(
    access: anytype,
    start: navigation.NodeRef,
    target: navigation.NodeRef,
) !RouteBuild {
    switch (access.resolveNode(start)) {
        .ready => {},
        .district_inactive => return .inactive,
        .invalid_reference => return .invalid_content,
    }
    switch (access.resolveNode(target)) {
        .ready => {},
        .district_inactive => return .inactive,
        .invalid_reference => return .invalid_content,
    }
    if (navigation.NodeRef.eql(start, target)) return .{ .ready = planWithOne(start) };
    var refs: [max_route_nodes]navigation.NodeRef = undefined;
    var previous: [max_route_nodes]i8 = @splat(-1);
    var queue: [max_route_nodes]u8 = undefined;
    refs[0] = start;
    queue[0] = 0;
    var count: usize = 1;
    var head: usize = 0;
    var tail: usize = 1;
    var target_index: ?usize = null;
    while (head < tail and target_index == null) : (head += 1) {
        const source_index: usize = queue[head];
        const source_ref = refs[source_index];
        const source = switch (access.resolveNode(source_ref)) {
            .ready => |resolved| resolved,
            .district_inactive => return .inactive,
            .invalid_reference => return .invalid_content,
        };
        for (0..source.node.edge_count) |ordinal_usize| {
            const ordinal: u8 = @intCast(ordinal_usize);
            const resolved_edge = switch (access.resolveEdge(source_ref, ordinal)) {
                .ready => |resolved| resolved,
                .district_inactive => return .inactive,
                .invalid_reference, .invalid_ordinal => return error.NpcNavigationPortInvariantBroken,
            };
            if (!navigation.LoadTicket.eql(source.ticket, resolved_edge.ticket)) {
                return error.NpcNavigationTicketInvariantBroken;
            }
            const candidate = resolved_edge.edge.target;
            switch (access.resolveNode(candidate)) {
                .ready => {},
                .district_inactive => continue,
                .invalid_reference => return error.NpcNavigationPortInvariantBroken,
            }
            var found = false;
            for (refs[0..count]) |existing| {
                if (navigation.NodeRef.eql(existing, candidate)) {
                    found = true;
                    break;
                }
            }
            if (found) continue;
            if (count == max_route_nodes) return .no_path;
            refs[count] = candidate;
            previous[count] = @intCast(source_index);
            queue[tail] = @intCast(count);
            tail += 1;
            if (navigation.NodeRef.eql(candidate, target)) target_index = count;
            count += 1;
        }
    }
    const found = target_index orelse return .no_path;
    var reversed: [max_route_nodes]navigation.NodeRef = undefined;
    var length: usize = 0;
    var cursor: i8 = @intCast(found);
    while (cursor >= 0) {
        reversed[length] = refs[@intCast(cursor)];
        length += 1;
        cursor = previous[@intCast(cursor)];
    }
    var plan = RoutePlan{ .len = @intCast(length) };
    for (0..length) |index| plan.nodes[index] = reversed[length - 1 - index];
    return .{ .ready = plan };
}

fn planWithOne(reference: navigation.NodeRef) RoutePlan {
    var result = RoutePlan{ .len = 1 };
    result.nodes[0] = reference;
    return result;
}

fn routeFromRecord(record: NpcRouteCursorV1, position: [3]f32) RouteCursor {
    var result = RouteCursor{
        .index = 0,
        .patrol_leg = record.patrol_leg,
        .segment_start = position,
        .needs_rebuild = true,
    };
    result.plan.nodes[0] = record.current;
    result.plan.len = 1;
    if (record.next) |next| {
        result.plan.nodes[1] = next;
        result.plan.len += 1;
    }
    return result;
}

fn currentRouteNode(route: RouteCursor) !navigation.NodeRef {
    if (route.index >= route.plan.len or route.index >= max_route_nodes) {
        return error.NpcRouteCursorInvariantBroken;
    }
    return route.plan.nodes[route.index];
}

fn ownerRouteNode(logical: anytype) !navigation.NodeRef {
    return ownerRouteNodeValue(logical.owner, logical.route) orelse
        error.NpcOwnerRouteInvariantBroken;
}

fn ownerRouteNodeValue(owner: navigation.ChunkCoord, route: RouteCursor) ?navigation.NodeRef {
    const current = currentRouteNode(route) catch return null;
    if (navigation.ChunkCoord.eql(current.coord, owner)) return current;
    if (route.next()) |next| {
        if (navigation.ChunkCoord.eql(next.coord, owner)) return next;
    }
    return null;
}

fn optionalNodeRefEql(a: ?navigation.NodeRef, b: ?navigation.NodeRef) bool {
    if (a == null or b == null) return a == null and b == null;
    return navigation.NodeRef.eql(a.?, b.?);
}

fn isCompletedPatrolEndpoint(
    goal: Goal,
    current: navigation.NodeRef,
    leg: PatrolLeg,
    next: ?navigation.NodeRef,
) bool {
    if (next != null) return false;
    return switch (goal) {
        .patrol_between => |patrol| switch (leg) {
            .toward_first => navigation.NodeRef.eql(current, patrol.first),
            .toward_second => navigation.NodeRef.eql(current, patrol.second),
            .none => false,
        },
        else => false,
    };
}

fn rejection(
    kind: CommandKind,
    reason: RejectionReason,
    request_id: u64,
    id: ?engine.PersistentId,
) Outcome {
    return .{ .rejected = .{
        .command = kind,
        .reason = reason,
        .request_id = request_id,
        .id = id,
    } };
}

fn poseFor(position: [3]f32, yaw: f32) engine.physics.Pose {
    const half_yaw = yaw * 0.5;
    return .{
        .position = position,
        .rotation = .{ 0, @sin(half_yaw), 0, @cos(half_yaw) },
    };
}

fn normalizeYaw(yaw: f32) f32 {
    if (!std.math.isFinite(yaw)) return yaw;
    const tau: f32 = 2 * std.math.pi;
    var result = @mod(yaw + std.math.pi, tau) - std.math.pi;
    if (result == 0) result = 0;
    return result;
}

fn canonicalFloat(value: f32) f32 {
    return if (value == 0) 0 else value;
}

fn canonicalVector(value: [3]f32) [3]f32 {
    return .{
        canonicalFloat(value[0]),
        canonicalFloat(value[1]),
        canonicalFloat(value[2]),
    };
}

fn isNegativeZero(value: f32) bool {
    return value == 0 and @as(u32, @bitCast(value)) != 0;
}

fn validateFiniteVector(value: [3]f32) !void {
    for (value) |component| if (!std.math.isFinite(component)) return error.NonFiniteNpcVector;
}

fn clampVelocity(value: [3]f32) [3]f32 {
    var length_squared: f64 = 0;
    for (value) |component| {
        const wide: f64 = component;
        length_squared += wide * wide;
    }
    const limit: f64 = @as(f64, engine.physics.max_linear_velocity) - 0.01;
    if (length_squared <= limit * limit) return value;
    const scale: f32 = @floatCast(limit / @sqrt(length_squared));
    return .{ value[0] * scale, value[1] * scale, value[2] * scale };
}

fn passedTarget(start: [3]f32, target: [3]f32, position: [3]f32) bool {
    const segment_x = target[0] - start[0];
    const segment_z = target[2] - start[2];
    return segment_x * (position[0] - target[0]) +
        segment_z * (position[2] - target[2]) >= 0;
}

fn lessThanPersistentId(_: void, lhs: engine.PersistentId, rhs: engine.PersistentId) bool {
    if (lhs.namespace != rhs.namespace) return lhs.namespace < rhs.namespace;
    return lhs.local < rhs.local;
}

fn lessThanRecord(_: void, lhs: NpcV1, rhs: NpcV1) bool {
    return lessThanPersistentId({}, lhs.id, rhs.id);
}

fn lessThanDraw(_: void, lhs: NpcDraw, rhs: NpcDraw) bool {
    return lessThanPersistentId({}, lhs.persistent_id, rhs.persistent_id);
}

fn writePersistentId(writer: *engine.contracts.replay.Writer, id: engine.PersistentId) void {
    writer.writeU64(id.namespace);
    writer.writeU64(id.local);
}

fn writeCoord(writer: *engine.contracts.replay.Writer, coord: navigation.ChunkCoord) void {
    writer.writeI32(coord.x);
    writer.writeI32(coord.z);
}

fn writeNodeRef(writer: *engine.contracts.replay.Writer, reference: navigation.NodeRef) void {
    writeCoord(writer, reference.coord);
    writer.writeU8(reference.index);
}

fn writeGoal(writer: *engine.contracts.replay.Writer, goal: Goal) !void {
    switch (goal) {
        .hold => writer.writeU8(1),
        .navigate_to => |target| {
            writer.writeU8(2);
            writeNodeRef(writer, target);
        },
        .patrol_between => |patrol| {
            writer.writeU8(3);
            writeNodeRef(writer, patrol.first);
            writeNodeRef(writer, patrol.second);
        },
    }
}

fn writePersistentRouteCursor(
    writer: *engine.contracts.replay.Writer,
    route: NpcRouteCursorV1,
) void {
    writeNodeRef(writer, route.current);
    writer.writeBool(route.next != null);
    if (route.next) |next| writeNodeRef(writer, next);
    writer.writeU8(route.route_index);
    writePatrolLeg(writer, route.patrol_leg);
}

fn writeVector3(writer: *engine.contracts.replay.Writer, value: [3]f32) !void {
    for (value) |component| try writer.writeF32(component);
}

fn writeCommand(writer: *engine.contracts.replay.Writer, command: Command) !void {
    switch (command) {
        .spawn => |spawn| {
            writer.writeU8(1);
            writer.writeU64(spawn.request_id);
            writeNodeRef(writer, spawn.node);
            try writeGoal(writer, spawn.goal);
        },
        .set_goal => |set_goal| {
            writer.writeU8(2);
            writer.writeU64(set_goal.request_id);
            writePersistentId(writer, set_goal.id);
            try writeGoal(writer, set_goal.goal);
        },
        .despawn => |despawn| {
            writer.writeU8(3);
            writer.writeU64(despawn.request_id);
            writePersistentId(writer, despawn.id);
        },
    }
}

fn writeOutcome(writer: *engine.contracts.replay.Writer, outcome: Outcome) !void {
    switch (outcome) {
        .spawned => |spawned| {
            writer.writeU8(1);
            writer.writeU64(spawned.request_id);
            writePersistentId(writer, spawned.id);
            writeCoord(writer, spawned.owner);
        },
        .goal_set => |goal_set| {
            writer.writeU8(2);
            writer.writeU64(goal_set.request_id);
            writePersistentId(writer, goal_set.id);
            try writeGoal(writer, goal_set.goal);
        },
        .despawned => |despawned| {
            writer.writeU8(3);
            writer.writeU64(despawned.request_id);
            writePersistentId(writer, despawned.id);
        },
        .rejected => |rejected| {
            writer.writeU8(4);
            writeCommandKind(writer, rejected.command);
            writeRejectionReason(writer, rejected.reason);
            writer.writeU64(rejected.request_id);
            writer.writeBool(rejected.id != null);
            if (rejected.id) |id| writePersistentId(writer, id);
        },
    }
}

fn writeEvent(writer: *engine.contracts.replay.Writer, event: Event) void {
    switch (event) {
        .state_changed => |changed| {
            writer.writeU8(1);
            writePersistentId(writer, changed.id);
            writeState(writer, changed.previous);
            writeState(writer, changed.current);
        },
        .owner_transferred => |transferred| {
            writer.writeU8(2);
            writePersistentId(writer, transferred.id);
            writeCoord(writer, transferred.previous);
            writeCoord(writer, transferred.current);
        },
        .goal_reached => |reached| {
            writer.writeU8(3);
            writePersistentId(writer, reached.id);
            writeNodeRef(writer, reached.node);
        },
    }
}

fn writeCommandKind(writer: *engine.contracts.replay.Writer, kind: CommandKind) void {
    writer.writeU8(switch (kind) {
        .spawn => 1,
        .set_goal => 2,
        .despawn => 3,
    });
}

fn writeRejectionReason(
    writer: *engine.contracts.replay.Writer,
    reason: RejectionReason,
) void {
    writer.writeU8(switch (reason) {
        .capacity_reached => 1,
        .controller_capacity_reached => 2,
        .npc_not_found => 3,
        .not_owned => 4,
        .start_district_inactive => 5,
        .invalid_start_node => 6,
        .goal_district_inactive => 7,
        .invalid_goal => 8,
        .unreachable_goal => 9,
    });
}

fn writeState(writer: *engine.contracts.replay.Writer, state: State) void {
    writer.writeU8(switch (state) {
        .active => 1,
        .waiting_at_boundary => 2,
        .dormant => 3,
    });
}

fn writePatrolLeg(writer: *engine.contracts.replay.Writer, leg: PatrolLeg) void {
    writer.writeU8(switch (leg) {
        .none => 0,
        .toward_first => 1,
        .toward_second => 2,
    });
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

const test_namespace: u64 = 0x4e_50_43;
const west_coord = navigation.ChunkCoord{ .x = 0, .z = 0 };
const east_coord = navigation.ChunkCoord{ .x = 1, .z = 0 };

fn westNode(index: u8) navigation.NodeRef {
    return .{ .coord = west_coord, .index = index };
}

fn eastNode(index: u8) navigation.NodeRef {
    return .{ .coord = east_coord, .index = index };
}

const FakeNavigation = struct {
    west_active: bool = true,
    east_active: bool = true,
    west_generation: u64 = 1,
    east_generation: u64 = 1,
    seam_connected: bool = true,
    resolve_edge_calls: usize = 0,

    pub fn resolveNode(
        self: *FakeNavigation,
        reference: navigation.NodeRef,
    ) navigation.NodeResolution {
        if (!validReference(reference)) return .invalid_reference;
        if (!self.active(reference.coord)) return .district_inactive;
        return .{ .ready = .{
            .ticket = self.ticket(reference.coord),
            .reference = reference,
            .node = .{
                .position = nodePosition(reference),
                .first_edge = 0,
                .edge_count = self.edgeCount(reference),
                .flags = if ((navigation.NodeRef.eql(reference, westNode(0)) or
                    navigation.NodeRef.eql(reference, eastNode(2)))) 1 else 0,
                .reserved = 0,
            },
        } };
    }

    pub fn resolveEdge(
        self: *FakeNavigation,
        source: navigation.NodeRef,
        ordinal: u8,
    ) navigation.EdgeResolution {
        self.resolve_edge_calls += 1;
        if (!validReference(source)) return .invalid_reference;
        const target = self.edgeTarget(source, ordinal) orelse return .invalid_ordinal;
        if (!self.active(source.coord)) return .district_inactive;
        return .{ .ready = .{
            .ticket = self.ticket(source.coord),
            .source = source,
            .ordinal = ordinal,
            .edge = .{ .target = target },
        } };
    }

    pub fn validateTraversal(
        self: *FakeNavigation,
        source: navigation.NodeRef,
        target: navigation.NodeRef,
    ) navigation.TraversalValidation {
        if (!validReference(source)) return .invalid_source;
        if (!validReference(target)) return .invalid_target;
        for (0..self.edgeCount(source)) |ordinal| {
            if (navigation.NodeRef.eql(self.edgeTarget(source, @intCast(ordinal)).?, target)) {
                return .valid;
            }
        }
        return .not_connected;
    }

    fn active(self: *const FakeNavigation, coord: navigation.ChunkCoord) bool {
        if (navigation.ChunkCoord.eql(coord, west_coord)) return self.west_active;
        if (navigation.ChunkCoord.eql(coord, east_coord)) return self.east_active;
        return false;
    }

    fn ticket(self: *const FakeNavigation, coord: navigation.ChunkCoord) navigation.LoadTicket {
        return .{
            .coord = coord,
            .generation = if (navigation.ChunkCoord.eql(coord, west_coord))
                self.west_generation
            else
                self.east_generation,
        };
    }

    fn edgeCount(self: *const FakeNavigation, source: navigation.NodeRef) u8 {
        var count_value: u8 = 0;
        while (self.edgeTarget(source, count_value) != null) count_value += 1;
        return count_value;
    }

    fn edgeTarget(
        self: *const FakeNavigation,
        source: navigation.NodeRef,
        ordinal: u8,
    ) ?navigation.NodeRef {
        if (navigation.NodeRef.eql(source, westNode(0))) {
            return if (ordinal == 0) westNode(1) else null;
        }
        if (navigation.NodeRef.eql(source, westNode(1))) return switch (ordinal) {
            0 => westNode(0),
            1 => westNode(2),
            else => null,
        };
        if (navigation.NodeRef.eql(source, westNode(2))) return switch (ordinal) {
            0 => westNode(1),
            1 => if (self.seam_connected) eastNode(0) else null,
            else => null,
        };
        if (navigation.NodeRef.eql(source, eastNode(0))) return switch (ordinal) {
            0 => if (self.seam_connected) westNode(2) else eastNode(1),
            1 => if (self.seam_connected) eastNode(1) else null,
            else => null,
        };
        if (navigation.NodeRef.eql(source, eastNode(1))) return switch (ordinal) {
            0 => eastNode(0),
            1 => eastNode(2),
            else => null,
        };
        if (navigation.NodeRef.eql(source, eastNode(2))) {
            return if (ordinal == 0) eastNode(1) else null;
        }
        return null;
    }
};

fn validReference(reference: navigation.NodeRef) bool {
    return reference.index < 3 and
        (navigation.ChunkCoord.eql(reference.coord, west_coord) or
            navigation.ChunkCoord.eql(reference.coord, east_coord));
}

fn nodePosition(reference: navigation.NodeRef) [3]f32 {
    if (navigation.ChunkCoord.eql(reference.coord, west_coord)) return switch (reference.index) {
        0 => .{ -4, 0, 3 },
        1 => .{ 2, 0, 3 },
        2 => .{ 7, 0, 3 },
        else => unreachable,
    };
    return switch (reference.index) {
        0 => .{ 9, 0, 3 },
        1 => .{ 14, 0, 3 },
        2 => .{ 20, 0, 3 },
        else => unreachable,
    };
}

const FakeControllers = struct {
    pub const Handle = struct {
        index: u8,
        generation: u32,
    };

    const Slot = struct {
        live: bool = false,
        generation: u32 = 1,
        state: engine.physics.CharacterState = groundedState(.{ 0, 0, 0 }),
    };

    slots: [128]Slot = [_]Slot{.{}} ** 128,
    live_count: usize = 0,
    max_live: usize = 128,
    create_calls: usize = 0,
    destroy_calls: usize = 0,
    update_calls: usize = 0,
    fail_create_call: ?usize = null,

    pub fn createCharacter(
        self: *FakeControllers,
        desc: engine.physics.CharacterDesc,
    ) !Handle {
        try desc.validate();
        const call = self.create_calls;
        self.create_calls += 1;
        if (self.fail_create_call != null and self.fail_create_call.? == call) {
            return error.InjectedControllerCreationFailure;
        }
        if (self.live_count >= self.max_live) return error.TooManyCharacters;
        for (&self.slots, 0..) |*slot, index| {
            if (slot.live) continue;
            slot.live = true;
            slot.state = groundedState(desc.position);
            slot.state.velocity = desc.velocity;
            self.live_count += 1;
            return .{ .index = @intCast(index), .generation = slot.generation };
        }
        return error.TooManyCharacters;
    }

    pub fn destroyCharacter(self: *FakeControllers, handle: Handle) !void {
        const slot = try self.slotFor(handle);
        slot.live = false;
        slot.generation +%= 1;
        if (slot.generation == 0) slot.generation = 1;
        self.live_count -= 1;
        self.destroy_calls += 1;
    }

    pub fn characterState(
        self: *FakeControllers,
        handle: Handle,
    ) !engine.physics.CharacterState {
        return (try self.slotFor(handle)).state;
    }

    pub fn prepareCharacter(
        self: *FakeControllers,
        handle: Handle,
    ) !engine.physics.CharacterState {
        return self.characterState(handle);
    }

    pub fn updateCharacter(
        self: *FakeControllers,
        handle: Handle,
        update: engine.physics.CharacterUpdate,
        delta_seconds: f32,
    ) !engine.physics.CharacterState {
        try update.validate();
        const slot = try self.slotFor(handle);
        slot.state.position[0] += update.velocity[0] * delta_seconds;
        slot.state.position[2] += update.velocity[2] * delta_seconds;
        slot.state.position[1] = 0;
        slot.state.velocity = .{ update.velocity[0], 0, update.velocity[2] };
        slot.state.ground_state = .on_ground;
        self.update_calls += 1;
        return slot.state;
    }

    pub fn tryRelocateCharacter(
        self: *FakeControllers,
        handle: Handle,
        relocation: engine.physics.CharacterRelocation,
    ) !?engine.physics.CharacterState {
        try relocation.validate();
        const slot = try self.slotFor(handle);
        slot.state = groundedState(relocation.position);
        slot.state.velocity = relocation.velocity;
        return slot.state;
    }

    fn slotFor(self: *FakeControllers, handle: Handle) !*Slot {
        if (handle.index >= self.slots.len) return error.InvalidFakeController;
        const slot = &self.slots[handle.index];
        if (!slot.live or slot.generation != handle.generation) {
            return error.InvalidFakeController;
        }
        return slot;
    }
};

fn groundedState(position: [3]f32) engine.physics.CharacterState {
    return .{
        .position = position,
        .velocity = .{ 0, 0, 0 },
        .ground_state = .on_ground,
        .ground_velocity = .{ 0, 0, 0 },
        .ground_normal = .{ 0, 1, 0 },
    };
}

const TestFeature = Feature(FakeControllers, FakeNavigation);

const TestWorld = struct {
    runtime: engine.Runtime,
    controllers: FakeControllers,
    navigation_access: FakeNavigation,
    feature: TestFeature,

    fn init(self: *TestWorld) !void {
        return self.initWithConfig(.{ .move_speed = 5 });
    }

    fn initWithConfig(self: *TestWorld, config: Config) !void {
        self.runtime = try engine.Runtime.init(std.testing.allocator, .{
            .namespace = test_namespace,
            .fixed_delta_seconds = 0.1,
        });
        errdefer self.runtime.deinit();
        self.controllers = .{};
        self.navigation_access = .{};
        self.feature = try TestFeature.init(
            &self.runtime,
            &self.controllers,
            &self.navigation_access,
            config,
        );
        var registry = self.runtime.registry();
        try self.feature.register(&registry);
    }

    fn deinit(self: *TestWorld) void {
        self.feature.deinit();
        std.testing.expectEqual(@as(usize, 0), self.controllers.live_count) catch
            @panic("fake NPC controller leak");
        std.testing.expectEqual(@as(usize, 0), self.runtime.persistentCount()) catch
            @panic("fake NPC runtime leak");
        self.runtime.deinit();
    }
};

fn spawnPatrol(world: *TestWorld, request_id: u64) !engine.PersistentId {
    try world.feature.enqueue(.{ .spawn = .{
        .request_id = request_id,
        .node = westNode(0),
        .goal = .{ .patrol_between = .{
            .first = westNode(0),
            .second = eastNode(2),
        } },
    } });
    try world.runtime.tick();
    return switch (world.feature.pollOutcome() orelse return error.MissingNpcOutcome) {
        .spawned => |spawned| spawned.id,
        else => error.UnexpectedNpcOutcome,
    };
}

fn expectRejected(
    outcome: ?Outcome,
    kind: CommandKind,
    reason: RejectionReason,
) !void {
    switch (outcome orelse return error.MissingNpcOutcome) {
        .rejected => |rejected_value| {
            try std.testing.expectEqual(kind, rejected_value.command);
            try std.testing.expectEqual(reason, rejected_value.reason);
        },
        else => return error.ExpectedNpcRejection,
    }
}

fn validNpcRecord(id_local: u64) NpcV1 {
    return .{
        .id = .{ .namespace = test_namespace, .local = id_local },
        .owner = west_coord,
        .goal = .{ .navigate_to = eastNode(2) },
        .route = .{
            .current = westNode(0),
            .next = westNode(1),
            .route_index = 0,
            .patrol_leg = .none,
        },
        .position = nodePosition(westNode(0)),
        .velocity = .{ 0, 0, 0 },
        .facing_yaw = 0,
    };
}

fn npcLogicalDigest(world: *TestWorld) !engine.contracts.replay.Digest {
    var writer = engine.contracts.replay.Writer.init();
    try world.feature.writeLogicalState(&writer);
    return writer.final();
}

test "NPC logical digest is stable and includes FIFO output payloads" {
    var world: TestWorld = undefined;
    try world.init();
    defer world.deinit();

    const stable_first = try npcLogicalDigest(&world);
    const stable_second = try npcLogicalDigest(&world);
    try std.testing.expectEqual(stable_first, stable_second);

    const id = engine.PersistentId{ .namespace = test_namespace, .local = 41 };
    world.feature.outcomes.pushAssumeCapacity(.{ .spawned = .{
        .request_id = 41,
        .id = id,
        .owner = west_coord,
    } });
    const first_outcome = try npcLogicalDigest(&world);
    _ = world.feature.pollOutcome() orelse return error.MissingNpcOutcome;
    world.feature.outcomes.pushAssumeCapacity(.{ .spawned = .{
        .request_id = 42,
        .id = id,
        .owner = west_coord,
    } });
    try std.testing.expectEqual(@as(usize, 1), world.feature.outcomes.len);
    const changed_outcome_payload = try npcLogicalDigest(&world);
    try std.testing.expect(!std.mem.eql(u8, &first_outcome, &changed_outcome_payload));
    _ = world.feature.pollOutcome() orelse return error.MissingNpcOutcome;

    world.feature.events.pushAssumeCapacity(.{ .goal_reached = .{
        .id = id,
        .node = westNode(0),
    } });
    const first_event = try npcLogicalDigest(&world);
    _ = world.feature.pollEvent() orelse return error.MissingNpcEvent;
    world.feature.events.pushAssumeCapacity(.{ .goal_reached = .{
        .id = id,
        .node = westNode(1),
    } });
    try std.testing.expectEqual(@as(usize, 1), world.feature.events.len);
    const changed_event_payload = try npcLogicalDigest(&world);
    try std.testing.expect(!std.mem.eql(u8, &first_event, &changed_event_payload));

    _ = world.feature.pollEvent() orelse return error.MissingNpcEvent;
    const after_event_poll = try npcLogicalDigest(&world);
    try std.testing.expect(!std.mem.eql(u8, &changed_event_payload, &after_event_poll));
    try std.testing.expectEqual(after_event_poll, try npcLogicalDigest(&world));
}

test "NPC logical digest includes saturated drops and transition counters" {
    var world: TestWorld = undefined;
    try world.init();
    defer world.deinit();

    for (0..max_events) |index| {
        world.feature.events.pushAssumeCapacity(.{ .goal_reached = .{
            .id = .{ .namespace = test_namespace, .local = index + 1 },
            .node = westNode(@intCast(index % 3)),
        } });
    }
    try std.testing.expectEqual(max_events, world.feature.events.len);
    const saturated = try npcLogicalDigest(&world);

    world.feature.event_drops.state_changed = 1;
    const state_drop = try npcLogicalDigest(&world);
    try std.testing.expect(!std.mem.eql(u8, &saturated, &state_drop));
    world.feature.event_drops.owner_transferred = 1;
    const owner_drop = try npcLogicalDigest(&world);
    try std.testing.expect(!std.mem.eql(u8, &state_drop, &owner_drop));
    world.feature.event_drops.goal_reached = 1;
    const goal_drop = try npcLogicalDigest(&world);
    try std.testing.expect(!std.mem.eql(u8, &owner_drop, &goal_drop));

    world.feature.transfers = 1;
    const transfer = try npcLogicalDigest(&world);
    try std.testing.expect(!std.mem.eql(u8, &goal_drop, &transfer));
    world.feature.controllers_suspended = 1;
    const suspended = try npcLogicalDigest(&world);
    try std.testing.expect(!std.mem.eql(u8, &transfer, &suspended));
    world.feature.controllers_resumed = 1;
    const resumed = try npcLogicalDigest(&world);
    try std.testing.expect(!std.mem.eql(u8, &suspended, &resumed));
    try std.testing.expectEqual(resumed, try npcLogicalDigest(&world));
}

test "NPC configuration budgets and compact persistence are bounded" {
    try (Config{}).validate();
    try NpcConfigV1.fromConfig(.{}).validate();
    try std.testing.expectError(
        error.InvalidNpcConfiguration,
        (Config{ .move_speed = 0 }).validate(),
    );
    try std.testing.expectError(
        error.InvalidNpcConfiguration,
        (Config{ .arrival_distance = 0.5 }).validate(),
    );
    try std.testing.expectEqual(@as(u32, 64), declared_budget.npcs);
    try std.testing.expectEqual(@as(u32, 128), declared_budget.commands);
    try std.testing.expectEqual(@as(u32, 256), declared_budget.events);

    var access = FakeNavigation{};
    var records: [max_npcs]NpcV1 = undefined;
    for (&records, 0..) |*record, index| record.* = validNpcRecord(index + 1);
    try validateRecordsWithNavigation(&access, &records);
    const json = try std.json.Stringify.valueAlloc(std.testing.allocator, records, .{});
    defer std.testing.allocator.free(json);
    try std.testing.expect(json.len < 128 * 1024);
}

test "cold NPC preflight rejects hostile owner cursor and content records" {
    var access = FakeNavigation{ .west_active = false, .east_active = false };
    const valid = validNpcRecord(1);
    try validateRecordsWithNavigation(&access, &.{valid});

    var hostile = valid;
    hostile.owner = east_coord;
    try std.testing.expectError(
        error.NpcOwnerPositionMismatch,
        validateRecordsWithNavigation(&access, &.{hostile}),
    );
    hostile = valid;
    hostile.route.next = westNode(2);
    try std.testing.expectError(
        error.NpcPersistedRouteMismatch,
        validateRecordsWithNavigation(&access, &.{hostile}),
    );
    hostile = valid;
    hostile.route.next = .{ .coord = east_coord, .index = 7 };
    try std.testing.expectError(
        error.NpcPersistedRouteInvalid,
        validateRecordsWithNavigation(&access, &.{hostile}),
    );
    hostile = valid;
    hostile.route.route_index = 1;
    try std.testing.expectError(
        error.NonCanonicalNpcRouteIndex,
        validateRecordsWithNavigation(&access, &.{hostile}),
    );
    hostile = valid;
    hostile.facing_yaw = -0.0;
    try std.testing.expectError(
        error.NonCanonicalNpcFacing,
        validateRecordsWithNavigation(&access, &.{hostile}),
    );
    try std.testing.expectError(
        error.DuplicateNpcPersistentId,
        validateRecordsWithNavigation(&access, &.{ valid, valid }),
    );
}

test "NPC waits crosses half-open boundary binds generations and becomes dormant" {
    var world: TestWorld = undefined;
    try world.init();
    defer world.deinit();

    const id = try spawnPatrol(&world, 1);
    try std.testing.expectEqual(@as(usize, 1), world.controllers.live_count);
    const create_before_generation = world.controllers.create_calls;
    world.navigation_access.west_generation += 1;
    try world.runtime.tick();
    try std.testing.expectEqual(create_before_generation + 1, world.controllers.create_calls);
    try std.testing.expectEqual(@as(u64, 1), world.feature.diagnostics().controllers_suspended);

    world.navigation_access.east_active = false;
    for (0..40) |_| try world.runtime.tick();
    var view_value = try world.feature.view(id);
    try std.testing.expectEqual(State.waiting_at_boundary, view_value.state);
    try std.testing.expect(navigation.ChunkCoord.eql(west_coord, view_value.owner));
    try std.testing.expect(view_value.position[0] < 8);
    try std.testing.expectEqual(@as(usize, 1), world.controllers.live_count);

    const create_calls_before_transfer = world.controllers.create_calls;
    world.navigation_access.east_active = true;
    world.navigation_access.east_generation += 1;
    for (0..8) |_| {
        try world.runtime.tick();
        view_value = try world.feature.view(id);
        if (navigation.ChunkCoord.eql(view_value.owner, east_coord)) break;
    }
    view_value = try world.feature.view(id);
    try std.testing.expect(navigation.ChunkCoord.eql(east_coord, view_value.owner));
    try std.testing.expect(view_value.position[0] >= 8);
    try std.testing.expect(world.feature.diagnostics().transfers >= 1);
    try std.testing.expectEqual(create_calls_before_transfer, world.controllers.create_calls);
    try std.testing.expectEqual(@as(usize, 1), world.controllers.live_count);

    world.navigation_access.east_active = false;
    try world.runtime.tick();
    view_value = try world.feature.view(id);
    try std.testing.expectEqual(State.dormant, view_value.state);
    try std.testing.expect(!view_value.controller_present);
    try std.testing.expectEqual(@as(usize, 0), world.controllers.live_count);
    try std.testing.expectEqual(@as(usize, 0), (try world.feature.extract(0.5)).len);

    world.navigation_access.east_active = true;
    world.navigation_access.east_generation += 1;
    try world.runtime.tick();
    view_value = try world.feature.view(id);
    try std.testing.expect(view_value.state != .dormant);
    try std.testing.expect(view_value.controller_present);
}

fn patrolRecord(
    id_local: u64,
    current: navigation.NodeRef,
    next: ?navigation.NodeRef,
    leg: PatrolLeg,
    position: [3]f32,
) NpcV1 {
    return .{
        .id = .{ .namespace = test_namespace, .local = id_local },
        .owner = navigation.ownerForPosition(position) catch unreachable,
        .goal = .{ .patrol_between = .{
            .first = westNode(0),
            .second = eastNode(2),
        } },
        .route = .{
            .current = current,
            .next = next,
            .route_index = 0,
            .patrol_leg = leg,
        },
        .position = position,
        .velocity = .{ 1, 0, 0 },
        .facing_yaw = -@as(f32, std.math.pi) / 2.0,
    };
}

fn expectRecordRoundTrip(record: NpcV1) !void {
    var world: TestWorld = undefined;
    try world.init();
    defer world.deinit();
    try world.feature.restoreRecords(&.{record});
    const snapshot = try world.feature.snapshotRecords(std.testing.allocator);
    defer std.testing.allocator.free(snapshot);
    try std.testing.expectEqualDeep(@as(usize, 1), snapshot.len);
    try std.testing.expectEqualDeep(record, snapshot[0]);
}

test "compact patrol persistence round trips both interior directions" {
    try expectRecordRoundTrip(patrolRecord(
        1,
        westNode(1),
        westNode(2),
        .toward_second,
        .{ 2.25, 0, 3 },
    ));
    try expectRecordRoundTrip(patrolRecord(
        2,
        eastNode(1),
        eastNode(0),
        .toward_first,
        .{ 13.75, 0, 3 },
    ));
}

test "restored patrol endpoint waits then selects outbound leg" {
    var world: TestWorld = undefined;
    try world.init();
    defer world.deinit();
    world.navigation_access.east_active = false;
    const record = patrolRecord(1, westNode(0), null, .toward_first, .{ -4, 0, 3 });
    try world.feature.restoreRecords(&.{record});
    const edge_calls_before_wait = world.navigation_access.resolve_edge_calls;
    for (0..5) |_| try world.runtime.tick();
    try std.testing.expectEqual(
        edge_calls_before_wait,
        world.navigation_access.resolve_edge_calls,
    );
    var value = try world.feature.view(record.id);
    try std.testing.expectEqual(PatrolLeg.toward_first, value.route.patrol_leg);
    try std.testing.expect(value.route.next() == null);

    world.navigation_access.east_active = true;
    world.navigation_access.east_generation += 1;
    try world.runtime.tick();
    value = try world.feature.view(record.id);
    try std.testing.expectEqual(PatrolLeg.toward_second, value.route.patrol_leg);
    try std.testing.expect(value.route.next() != null);
    try std.testing.expect(navigation.NodeRef.eql(westNode(1), value.route.next().?));
}

test "NPC restore rolls back runtime and controllers on injected failure" {
    var world: TestWorld = undefined;
    try world.init();
    defer world.deinit();
    world.controllers.fail_create_call = 1;
    const records = [_]NpcV1{
        validNpcRecord(1),
        validNpcRecord(2),
    };
    try std.testing.expectError(
        error.InjectedControllerCreationFailure,
        world.feature.restoreRecords(&records),
    );
    try std.testing.expectEqual(@as(usize, 0), world.feature.count());
    try std.testing.expectEqual(@as(usize, 0), world.controllers.live_count);
    try std.testing.expectEqual(@as(usize, 0), world.runtime.entityCount());
}

test "NPC commands reject invalid inactive unreachable stale and controller capacity" {
    var world: TestWorld = undefined;
    try world.init();
    defer world.deinit();

    try world.feature.enqueue(.{ .spawn = .{
        .request_id = 1,
        .node = .{ .coord = west_coord, .index = 7 },
    } });
    try world.runtime.tick();
    try expectRejected(world.feature.pollOutcome(), .spawn, .invalid_start_node);

    world.navigation_access.east_active = false;
    try world.feature.enqueue(.{ .spawn = .{
        .request_id = 2,
        .node = westNode(0),
        .goal = .{ .navigate_to = eastNode(2) },
    } });
    try world.runtime.tick();
    try expectRejected(world.feature.pollOutcome(), .spawn, .goal_district_inactive);

    world.navigation_access.east_active = true;
    world.navigation_access.seam_connected = false;
    try world.feature.enqueue(.{ .spawn = .{
        .request_id = 3,
        .node = westNode(0),
        .goal = .{ .navigate_to = eastNode(2) },
    } });
    try world.runtime.tick();
    try expectRejected(world.feature.pollOutcome(), .spawn, .unreachable_goal);
    world.navigation_access.seam_connected = true;

    try world.feature.enqueue(.{ .spawn = .{
        .request_id = 4,
        .node = westNode(0),
        .goal = .{ .navigate_to = .{ .coord = east_coord, .index = 7 } },
    } });
    try world.runtime.tick();
    try expectRejected(world.feature.pollOutcome(), .spawn, .invalid_goal);

    const stale = engine.PersistentId{ .namespace = test_namespace, .local = 999 };
    try world.feature.enqueue(.{ .set_goal = .{
        .request_id = 5,
        .id = stale,
        .goal = .hold,
    } });
    try world.runtime.tick();
    try expectRejected(world.feature.pollOutcome(), .set_goal, .npc_not_found);

    world.controllers.max_live = 0;
    try world.feature.enqueue(.{ .spawn = .{
        .request_id = 6,
        .node = westNode(0),
    } });
    try world.runtime.tick();
    try expectRejected(world.feature.pollOutcome(), .spawn, .controller_capacity_reached);
    try std.testing.expectEqual(@as(usize, 0), world.feature.count());
    try std.testing.expectEqual(@as(usize, 0), world.runtime.entityCount());
}

test "rejected set goal is atomic across view digest entities and controller ownership" {
    const spawn = Command{ .spawn = .{
        .request_id = 1,
        .node = westNode(0),
        .goal = .hold,
    } };
    var subject_id: engine.PersistentId = undefined;
    var view_before: NpcView = undefined;
    var view_after: NpcView = undefined;
    var digest_before: engine.contracts.replay.Digest = undefined;
    var digest_after: engine.contracts.replay.Digest = undefined;
    {
        var subject: TestWorld = undefined;
        try subject.init();
        defer subject.deinit();
        try subject.feature.enqueue(spawn);
        try subject.runtime.tick();
        subject_id = switch (subject.feature.pollOutcome() orelse
            return error.MissingNpcOutcome) {
            .spawned => |value| value.id,
            else => return error.UnexpectedNpcOutcome,
        };
        view_before = try subject.feature.view(subject_id);
        digest_before = try npcLogicalDigest(&subject);
        const entities_before = subject.runtime.entityCount();
        const persistent_before = subject.runtime.persistentCount();
        const controllers_before = subject.controllers.live_count;
        const creates_before = subject.controllers.create_calls;
        const destroys_before = subject.controllers.destroy_calls;
        const subject_runtime_id = subject.runtime.resolve(subject_id) orelse
            return error.NpcIdentityMissing;
        const controller_before = (subject.runtime.get(
            subject_runtime_id,
            TestFeature.RuntimeController,
        ) orelse return error.NpcControllerInvariantBroken).*;

        try subject.feature.enqueue(.{ .set_goal = .{
            .request_id = 2,
            .id = subject_id,
            .goal = .{ .navigate_to = .{ .coord = east_coord, .index = 7 } },
        } });
        try subject.runtime.tick();
        switch (subject.feature.pollOutcome() orelse return error.MissingNpcOutcome) {
            .rejected => |value| {
                try std.testing.expectEqual(CommandKind.set_goal, value.command);
                try std.testing.expectEqual(RejectionReason.invalid_goal, value.reason);
                try std.testing.expectEqual(@as(u64, 2), value.request_id);
                try std.testing.expectEqual(@as(?engine.PersistentId, subject_id), value.id);
            },
            else => return error.ExpectedNpcRejection,
        }

        view_after = try subject.feature.view(subject_id);
        digest_after = try npcLogicalDigest(&subject);
        try std.testing.expectEqualDeep(view_before, view_after);
        try std.testing.expectEqual(entities_before, subject.runtime.entityCount());
        try std.testing.expectEqual(persistent_before, subject.runtime.persistentCount());
        try std.testing.expectEqual(controllers_before, subject.controllers.live_count);
        try std.testing.expectEqual(creates_before, subject.controllers.create_calls);
        try std.testing.expectEqual(destroys_before, subject.controllers.destroy_calls);
        try std.testing.expectEqualDeep(
            controller_before,
            (subject.runtime.get(
                subject_runtime_id,
                TestFeature.RuntimeController,
            ) orelse return error.NpcControllerInvariantBroken).*,
        );
        try std.testing.expect(subject.feature.pollOutcome() == null);
        try std.testing.expect(subject.feature.pollEvent() == null);
    }

    // Runtime tick is part of the digest, so compare against an otherwise
    // identical authority advanced through the same two ticks without the
    // rejected transaction.
    var control: TestWorld = undefined;
    try control.init();
    defer control.deinit();
    try control.feature.enqueue(spawn);
    try control.runtime.tick();
    const control_id = switch (control.feature.pollOutcome() orelse
        return error.MissingNpcOutcome) {
        .spawned => |value| value.id,
        else => return error.UnexpectedNpcOutcome,
    };
    try std.testing.expectEqual(subject_id, control_id);
    try std.testing.expectEqual(digest_before, try npcLogicalDigest(&control));
    try control.runtime.tick();
    try std.testing.expectEqualDeep(view_after, try control.feature.view(control_id));
    try std.testing.expectEqual(digest_after, try npcLogicalDigest(&control));
}

test "foreign persistent identity is rejected as not owned" {
    var world: TestWorld = undefined;
    try world.init();
    defer world.deinit();

    const foreign_runtime_id = try world.runtime.create();
    const foreign_id = try world.runtime.identity(foreign_runtime_id);
    try world.feature.enqueue(.{ .set_goal = .{
        .request_id = 1,
        .id = foreign_id,
        .goal = .hold,
    } });
    try world.feature.enqueue(.{ .despawn = .{
        .request_id = 2,
        .id = foreign_id,
    } });
    try world.runtime.tick();
    for ([_]CommandKind{ .set_goal, .despawn }, 1..) |kind, request_id| {
        switch (world.feature.pollOutcome() orelse return error.MissingNpcOutcome) {
            .rejected => |value| {
                try std.testing.expectEqual(kind, value.command);
                try std.testing.expectEqual(RejectionReason.not_owned, value.reason);
                try std.testing.expectEqual(@as(u64, @intCast(request_id)), value.request_id);
                try std.testing.expectEqual(@as(?engine.PersistentId, foreign_id), value.id);
            },
            else => return error.ExpectedNpcRejection,
        }
    }
    try std.testing.expect(world.feature.pollOutcome() == null);
    try std.testing.expectEqual(@as(usize, 0), world.feature.count());
    try std.testing.expectEqual(@as(usize, 0), world.controllers.live_count);
    try std.testing.expectEqual(@as(usize, 1), world.runtime.entityCount());
    try world.runtime.destroy(foreign_runtime_id);
    try std.testing.expectEqual(@as(usize, 0), world.runtime.entityCount());
}

test "NPC authority queues reserve all outcomes and enforce population capacity" {
    var world: TestWorld = undefined;
    try world.init();
    defer world.deinit();

    for (0..max_pending_commands) |index| {
        try world.feature.enqueue(.{ .spawn = .{
            .request_id = index + 1,
            .node = westNode(0),
        } });
    }
    try std.testing.expectError(
        error.NpcCommandQueueFull,
        world.feature.enqueue(.{ .spawn = .{
            .request_id = max_pending_commands + 1,
            .node = westNode(0),
        } }),
    );
    var diagnostics_value = world.feature.diagnostics();
    try std.testing.expectEqual(@as(u32, max_pending_commands), diagnostics_value.commands.occupancy);
    try std.testing.expectEqual(@as(u32, max_pending_commands), diagnostics_value.commands.high_water);
    try std.testing.expectEqual(@as(u64, 1), diagnostics_value.commands.rejected);
    try std.testing.expectEqual(@as(u32, 0), diagnostics_value.outcomes.occupancy);

    try world.runtime.tick();
    try std.testing.expectEqual(@as(usize, max_npcs), world.feature.count());
    try std.testing.expectEqual(@as(usize, max_npcs), world.controllers.live_count);
    try std.testing.expectEqual(@as(usize, max_npcs), world.runtime.entityCount());
    try std.testing.expectEqual(@as(usize, max_npcs), world.runtime.persistentCount());
    try std.testing.expectEqual(@as(usize, max_npcs), world.controllers.create_calls);
    diagnostics_value = world.feature.diagnostics();
    try std.testing.expectEqual(@as(u32, max_outcomes), diagnostics_value.outcomes.occupancy);
    try std.testing.expectEqual(@as(u32, max_pending_commands), diagnostics_value.commands.high_water);
    try std.testing.expectEqual(@as(u64, 1), diagnostics_value.commands.rejected);

    var ids: [max_npcs]engine.PersistentId = undefined;
    var spawned: usize = 0;
    var rejected_count: usize = 0;
    while (world.feature.pollOutcome()) |outcome| switch (outcome) {
        .spawned => |value| {
            try std.testing.expect(value.request_id <= max_npcs);
            ids[spawned] = value.id;
            spawned += 1;
        },
        .rejected => |rejected_value| {
            try std.testing.expectEqual(CommandKind.spawn, rejected_value.command);
            try std.testing.expectEqual(RejectionReason.capacity_reached, rejected_value.reason);
            try std.testing.expectEqual(
                @as(u64, max_npcs + rejected_count + 1),
                rejected_value.request_id,
            );
            try std.testing.expect(rejected_value.id == null);
            rejected_count += 1;
        },
        else => return error.UnexpectedNpcOutcome,
    };
    try std.testing.expectEqual(@as(usize, max_npcs), spawned);
    try std.testing.expectEqual(@as(usize, max_npcs), rejected_count);
    try std.testing.expectEqual(@as(usize, max_npcs), world.feature.count());
    try std.testing.expectEqual(@as(usize, max_npcs), world.controllers.live_count);
    try std.testing.expectEqual(@as(usize, max_npcs), world.runtime.entityCount());

    for (ids, 0..) |id, index| {
        try world.feature.enqueue(.{ .despawn = .{
            .request_id = 1_000 + index,
            .id = id,
        } });
    }
    try world.runtime.tick();
    for (ids, 0..) |id, index| switch (world.feature.pollOutcome() orelse
        return error.MissingNpcOutcome) {
        .despawned => |value| {
            try std.testing.expectEqual(@as(u64, 1_000 + index), value.request_id);
            try std.testing.expectEqual(id, value.id);
        },
        else => return error.UnexpectedNpcOutcome,
    };
    try std.testing.expect(world.feature.pollOutcome() == null);
    diagnostics_value = world.feature.diagnostics();
    try std.testing.expectEqual(@as(usize, 0), world.feature.count());
    try std.testing.expectEqual(@as(usize, 0), world.controllers.live_count);
    try std.testing.expectEqual(@as(usize, 0), world.runtime.entityCount());
    try std.testing.expectEqual(@as(u32, 0), diagnostics_value.commands.occupancy);
    try std.testing.expectEqual(@as(u32, 0), diagnostics_value.outcomes.occupancy);
    try std.testing.expectEqual(@as(u32, 0), diagnostics_value.events.occupancy);

    try world.feature.enqueue(.{ .spawn = .{
        .request_id = 2_000,
        .node = westNode(0),
    } });
    try world.runtime.tick();
    const fresh_id = switch (world.feature.pollOutcome() orelse
        return error.MissingNpcOutcome) {
        .spawned => |value| value.id,
        else => return error.UnexpectedNpcOutcome,
    };
    try std.testing.expectEqual(@as(usize, 1), world.feature.count());
    try std.testing.expectEqual(@as(usize, 1), world.controllers.live_count);
    try world.feature.enqueue(.{ .despawn = .{
        .request_id = 2_001,
        .id = fresh_id,
    } });
    try world.runtime.tick();
    switch (world.feature.pollOutcome() orelse return error.MissingNpcOutcome) {
        .despawned => |value| try std.testing.expectEqual(fresh_id, value.id),
        else => return error.UnexpectedNpcOutcome,
    }
    try std.testing.expectEqual(@as(usize, 0), world.feature.count());
    try std.testing.expectEqual(@as(usize, 0), world.controllers.live_count);
    try std.testing.expectEqual(@as(usize, 0), world.runtime.entityCount());
}

test "NPC extraction is sorted interpolated immutable clamped and residency filtered" {
    const test_mesh = engine.rendering.MeshHandle{ .index = 7, .generation = 3 };
    const test_material = engine.rendering.MaterialHandle{ .index = 11, .generation = 5 };
    const test_config = Config{
        .radius = 0.4,
        .half_height = 0.6,
        .move_speed = 5,
        .assets = .{ .mesh = test_mesh, .material = test_material },
    };
    var world: TestWorld = undefined;
    try world.initWithConfig(test_config);
    defer world.deinit();

    // Registration order deliberately opposes persistent identity order.
    const records = [_]NpcV1{
        validNpcRecord(30),
        validNpcRecord(10),
        validNpcRecord(20),
    };
    try world.feature.restoreRecords(&records);
    try world.runtime.tick();

    const expected_locals = [_]u64{ 10, 20, 30 };
    var views_before: [records.len]NpcView = undefined;
    for (expected_locals, 0..) |local, index| {
        views_before[index] = try world.feature.view(.{
            .namespace = test_namespace,
            .local = local,
        });
    }
    const digest_before = try npcLogicalDigest(&world);

    const half_slice = try world.feature.extract(0.5);
    try std.testing.expectEqual(@as(usize, records.len), half_slice.len);
    var half_draws: [records.len]NpcDraw = undefined;
    @memcpy(&half_draws, half_slice);
    for (half_draws, expected_locals, views_before) |draw, local, view_value| {
        try std.testing.expectEqual(
            engine.PersistentId{ .namespace = test_namespace, .local = local },
            draw.persistent_id,
        );
        try std.testing.expectEqual(west_coord, draw.owner);
        try std.testing.expectEqual(State.active, draw.state);
        try std.testing.expectEqual(test_config.radius, draw.radius);
        try std.testing.expectEqual(test_config.half_height, draw.half_height);
        try std.testing.expectEqual(test_mesh, draw.mesh);
        try std.testing.expectEqual(test_material, draw.material);
        const expected_pose = try engine.transform.interpolate(
            poseFor(nodePosition(westNode(0)), 0),
            poseFor(view_value.position, view_value.facing_yaw),
            0.5,
        );
        try std.testing.expectEqualDeep(expected_pose, draw.pose);
    }
    try std.testing.expectEqualDeep(
        half_draws[0..],
        try world.feature.extract(0.5),
    );
    for (expected_locals, views_before) |local, before| {
        try std.testing.expectEqualDeep(before, try world.feature.view(.{
            .namespace = test_namespace,
            .local = local,
        }));
    }
    try std.testing.expectEqual(digest_before, try npcLogicalDigest(&world));

    var zero_draws: [records.len]NpcDraw = undefined;
    @memcpy(&zero_draws, try world.feature.extract(0));
    try std.testing.expectEqualDeep(zero_draws[0..], try world.feature.extract(-10));
    var one_draws: [records.len]NpcDraw = undefined;
    @memcpy(&one_draws, try world.feature.extract(1));
    try std.testing.expectEqualDeep(one_draws[0..], try world.feature.extract(10));
    try std.testing.expectError(
        error.InvalidInterpolationAlpha,
        world.feature.extract(std.math.nan(f32)),
    );
    try std.testing.expectError(
        error.InvalidInterpolationAlpha,
        world.feature.extract(std.math.inf(f32)),
    );
    try std.testing.expectError(
        error.InvalidInterpolationAlpha,
        world.feature.extract(-std.math.inf(f32)),
    );
    try std.testing.expectEqual(digest_before, try npcLogicalDigest(&world));

    world.navigation_access.east_active = false;
    for (0..128) |_| {
        try world.runtime.tick();
        if (world.feature.diagnostics().waiting_count == records.len) break;
    }
    try std.testing.expectEqual(
        @as(u32, records.len),
        world.feature.diagnostics().waiting_count,
    );
    const waiting_digest = try npcLogicalDigest(&world);
    const waiting_draws = try world.feature.extract(0.5);
    try std.testing.expectEqual(@as(usize, records.len), waiting_draws.len);
    for (waiting_draws, expected_locals) |draw, local| {
        try std.testing.expectEqual(local, draw.persistent_id.local);
        try std.testing.expectEqual(west_coord, draw.owner);
        try std.testing.expectEqual(State.waiting_at_boundary, draw.state);
        try std.testing.expectEqual(test_mesh, draw.mesh);
        try std.testing.expectEqual(test_material, draw.material);
    }
    try std.testing.expectEqual(waiting_digest, try npcLogicalDigest(&world));

    world.navigation_access.west_active = false;
    try world.runtime.tick();
    try std.testing.expectEqual(
        @as(u32, records.len),
        world.feature.diagnostics().dormant_count,
    );
    const dormant_digest = try npcLogicalDigest(&world);
    try std.testing.expectEqual(@as(usize, 0), (try world.feature.extract(0.5)).len);
    try std.testing.expectEqual(@as(usize, 0), (try world.feature.extract(1)).len);
    try std.testing.expectEqual(dormant_digest, try npcLogicalDigest(&world));
    for (expected_locals) |local| {
        const view_value = try world.feature.view(.{
            .namespace = test_namespace,
            .local = local,
        });
        try std.testing.expectEqual(State.dormant, view_value.state);
        try std.testing.expect(!view_value.controller_present);
    }
}

const EventSaturationKind = enum { state_changed, owner_transferred, goal_reached };

fn exerciseActualEventSaturation(kind: EventSaturationKind) !void {
    var world: TestWorld = undefined;
    try world.init();
    defer world.deinit();

    var ids: [max_npcs]engine.PersistentId = undefined;
    const goal: Goal = switch (kind) {
        .state_changed => .hold,
        .owner_transferred => .{ .patrol_between = .{
            .first = westNode(0),
            .second = eastNode(2),
        } },
        .goal_reached => .{ .navigate_to = westNode(1) },
    };
    for (0..max_npcs) |index| {
        try world.feature.enqueue(.{ .spawn = .{
            .request_id = index + 1,
            .node = westNode(0),
            .goal = goal,
        } });
    }
    try world.runtime.tick();
    for (&ids, 0..) |*id, index| switch (world.feature.pollOutcome() orelse
        return error.MissingNpcOutcome) {
        .spawned => |value| {
            try std.testing.expectEqual(@as(u64, @intCast(index + 1)), value.request_id);
            id.* = value.id;
        },
        else => return error.UnexpectedNpcOutcome,
    };
    try std.testing.expect(world.feature.pollOutcome() == null);
    try std.testing.expect(world.feature.pollEvent() == null);

    // Four real 64-wide residency transitions fill the event FIFO exactly.
    for (0..2) |_| {
        world.navigation_access.west_active = false;
        try world.runtime.tick();
        world.navigation_access.west_active = true;
        world.navigation_access.west_generation += 1;
        try world.runtime.tick();
    }
    var diagnostics_value = world.feature.diagnostics();
    try std.testing.expectEqual(@as(u32, max_events), diagnostics_value.events.occupancy);
    try std.testing.expectEqual(EventDropCounts{}, diagnostics_value.event_drops);

    // Generate the audited event through production transition/movement code
    // while the FIFO is full. Every NPC remains authoritative even though its
    // corresponding observation must be dropped.
    switch (kind) {
        .state_changed => {
            world.navigation_access.west_active = false;
            try world.runtime.tick();
        },
        .owner_transferred => {
            for (0..128) |_| {
                try world.runtime.tick();
                if (world.feature.diagnostics().transfers == max_npcs) break;
            }
        },
        .goal_reached => {
            for (0..128) |_| {
                try world.runtime.tick();
                if (world.feature.diagnostics().event_drops.goal_reached == max_npcs) break;
            }
        },
    }
    diagnostics_value = world.feature.diagnostics();
    const expected_drops = EventDropCounts{
        .state_changed = if (kind == .state_changed) max_npcs else 0,
        .owner_transferred = if (kind == .owner_transferred) max_npcs else 0,
        .goal_reached = if (kind == .goal_reached) max_npcs else 0,
    };
    try std.testing.expectEqual(expected_drops, diagnostics_value.event_drops);
    try std.testing.expectEqual(
        diagnostics_value.event_drops.total(),
        diagnostics_value.events.rejected,
    );
    try std.testing.expectEqual(@as(u32, max_events), diagnostics_value.events.occupancy);
    try std.testing.expectEqual(@as(usize, max_npcs), world.feature.count());
    try std.testing.expectEqual(
        if (kind == .state_changed) @as(usize, 0) else max_npcs,
        world.controllers.live_count,
    );
    try std.testing.expectEqual(@as(usize, max_npcs), world.runtime.entityCount());

    const saturated_drops = diagnostics_value.event_drops;
    const saturated_rejected = diagnostics_value.events.rejected;
    var drained_events: usize = 0;
    while (world.feature.pollEvent() != null) drained_events += 1;
    try std.testing.expectEqual(@as(usize, max_events), drained_events);
    diagnostics_value = world.feature.diagnostics();
    try std.testing.expectEqual(@as(u32, 0), diagnostics_value.events.occupancy);
    try std.testing.expectEqual(saturated_drops, diagnostics_value.event_drops);
    try std.testing.expectEqual(saturated_rejected, diagnostics_value.events.rejected);

    // Recover through the same production path that saturated. The empty FIFO
    // must retain every new event without changing any historical drop count.
    switch (kind) {
        .state_changed => {
            world.navigation_access.west_active = true;
            world.navigation_access.west_generation += 1;
            try world.runtime.tick();
        },
        .owner_transferred => {
            const recovery_goal: Goal = .{ .navigate_to = westNode(0) };
            const transfer_target = diagnostics_value.transfers + max_npcs;
            for (ids, 0..) |id, index| {
                try world.feature.enqueue(.{ .set_goal = .{
                    .request_id = 500 + index,
                    .id = id,
                    .goal = recovery_goal,
                } });
            }
            try world.runtime.tick();
            for (ids, 0..) |id, index| switch (world.feature.pollOutcome() orelse
                return error.MissingNpcOutcome) {
                .goal_set => |value| {
                    try std.testing.expectEqual(@as(u64, 500 + index), value.request_id);
                    try std.testing.expectEqual(id, value.id);
                    try std.testing.expectEqualDeep(recovery_goal, value.goal);
                },
                else => return error.UnexpectedNpcOutcome,
            };
            try std.testing.expect(world.feature.pollOutcome() == null);
            for (0..128) |_| {
                if (world.feature.diagnostics().transfers == transfer_target) break;
                try world.runtime.tick();
            }
            try std.testing.expectEqual(
                transfer_target,
                world.feature.diagnostics().transfers,
            );
        },
        .goal_reached => {
            const recovery_goal: Goal = .{ .navigate_to = westNode(2) };
            for (ids, 0..) |id, index| {
                try world.feature.enqueue(.{ .set_goal = .{
                    .request_id = 500 + index,
                    .id = id,
                    .goal = recovery_goal,
                } });
            }
            try world.runtime.tick();
            for (ids, 0..) |id, index| switch (world.feature.pollOutcome() orelse
                return error.MissingNpcOutcome) {
                .goal_set => |value| {
                    try std.testing.expectEqual(@as(u64, 500 + index), value.request_id);
                    try std.testing.expectEqual(id, value.id);
                    try std.testing.expectEqualDeep(recovery_goal, value.goal);
                },
                else => return error.UnexpectedNpcOutcome,
            };
            try std.testing.expect(world.feature.pollOutcome() == null);
            for (0..128) |_| {
                if (world.feature.diagnostics().events.occupancy == max_npcs) break;
                try world.runtime.tick();
            }
        },
    }

    diagnostics_value = world.feature.diagnostics();
    try std.testing.expectEqual(@as(u32, max_npcs), diagnostics_value.events.occupancy);
    try std.testing.expectEqual(saturated_drops, diagnostics_value.event_drops);
    try std.testing.expectEqual(saturated_rejected, diagnostics_value.events.rejected);
    for (ids) |id| {
        const event = world.feature.pollEvent() orelse return error.MissingNpcEvent;
        switch (kind) {
            .state_changed => switch (event) {
                .state_changed => |value| {
                    try std.testing.expectEqual(id, value.id);
                    try std.testing.expectEqual(State.dormant, value.previous);
                    try std.testing.expectEqual(State.active, value.current);
                },
                else => return error.UnexpectedNpcEvent,
            },
            .owner_transferred => switch (event) {
                .owner_transferred => |value| {
                    try std.testing.expectEqual(id, value.id);
                    try std.testing.expectEqual(east_coord, value.previous);
                    try std.testing.expectEqual(west_coord, value.current);
                },
                else => return error.UnexpectedNpcEvent,
            },
            .goal_reached => switch (event) {
                .goal_reached => |value| {
                    try std.testing.expectEqual(id, value.id);
                    try std.testing.expect(navigation.NodeRef.eql(westNode(2), value.node));
                },
                else => return error.UnexpectedNpcEvent,
            },
        }
    }
    try std.testing.expect(world.feature.pollEvent() == null);
    diagnostics_value = world.feature.diagnostics();
    try std.testing.expectEqual(@as(u32, 0), diagnostics_value.events.occupancy);
    try std.testing.expectEqual(saturated_drops, diagnostics_value.event_drops);
    try std.testing.expectEqual(saturated_rejected, diagnostics_value.events.rejected);

    for (ids, 0..) |id, index| {
        try world.feature.enqueue(.{ .despawn = .{
            .request_id = 1_000 + index,
            .id = id,
        } });
    }
    try world.runtime.tick();
    for (ids) |id| switch (world.feature.pollOutcome() orelse
        return error.MissingNpcOutcome) {
        .despawned => |value| try std.testing.expectEqual(id, value.id),
        else => return error.UnexpectedNpcOutcome,
    };
    try std.testing.expect(world.feature.pollOutcome() == null);
    try std.testing.expect(world.feature.pollEvent() == null);
    diagnostics_value = world.feature.diagnostics();
    try std.testing.expectEqual(@as(usize, 0), world.feature.count());
    try std.testing.expectEqual(@as(usize, 0), world.controllers.live_count);
    try std.testing.expectEqual(@as(usize, 0), world.runtime.entityCount());
    try std.testing.expectEqual(@as(usize, 0), world.runtime.persistentCount());
    try std.testing.expectEqual(@as(u32, 0), diagnostics_value.commands.occupancy);
    try std.testing.expectEqual(@as(u32, 0), diagnostics_value.outcomes.occupancy);
    try std.testing.expectEqual(@as(u32, 0), diagnostics_value.events.occupancy);
    try std.testing.expectEqual(saturated_drops, diagnostics_value.event_drops);
    try std.testing.expectEqual(saturated_rejected, diagnostics_value.events.rejected);

    world.navigation_access.west_active = true;
    world.navigation_access.west_generation += 1;
    try world.feature.enqueue(.{ .spawn = .{
        .request_id = 2_000,
        .node = westNode(0),
    } });
    try world.runtime.tick();
    const fresh_id = switch (world.feature.pollOutcome() orelse
        return error.MissingNpcOutcome) {
        .spawned => |value| value.id,
        else => return error.UnexpectedNpcOutcome,
    };
    try std.testing.expectEqual(@as(usize, 1), world.feature.count());
    try std.testing.expectEqual(@as(usize, 1), world.controllers.live_count);
    try world.feature.enqueue(.{ .despawn = .{
        .request_id = 2_001,
        .id = fresh_id,
    } });
    try world.runtime.tick();
    switch (world.feature.pollOutcome() orelse return error.MissingNpcOutcome) {
        .despawned => |value| try std.testing.expectEqual(fresh_id, value.id),
        else => return error.UnexpectedNpcOutcome,
    }
    try std.testing.expectEqual(@as(usize, 0), world.feature.count());
    try std.testing.expectEqual(@as(usize, 0), world.controllers.live_count);
    try std.testing.expectEqual(@as(usize, 0), world.runtime.entityCount());
    try std.testing.expectEqual(@as(usize, 0), world.runtime.persistentCount());
    diagnostics_value = world.feature.diagnostics();
    try std.testing.expectEqual(@as(u32, 0), diagnostics_value.commands.occupancy);
    try std.testing.expectEqual(@as(u32, 0), diagnostics_value.outcomes.occupancy);
    try std.testing.expectEqual(@as(u32, 0), diagnostics_value.events.occupancy);
    try std.testing.expectEqual(saturated_drops, diagnostics_value.event_drops);
    try std.testing.expectEqual(saturated_rejected, diagnostics_value.events.rejected);
}

test "actual saturated NPC events retain per-kind drop accounting and recover" {
    try exerciseActualEventSaturation(.state_changed);
    try exerciseActualEventSaturation(.owner_transferred);
    try exerciseActualEventSaturation(.goal_reached);
}
