//! Bounded navigation-driven NPC authority.
//!
//! NPCs own semantic goals, a fixed route cursor, streamed-district ownership,
//! and CharacterVirtual controller lifetimes. Navigation is queried only
//! through copied generation-aware values. Goal admission performs one bounded
//! fixed-array search; steady ticks only advance the retained cursor.

const std = @import("std");
const engine = @import("incinerator_engine");
const feature_contract = @import("npc_contract");
const snapshot_validation = @import("npc_snapshot_validation");
const navigation = @import("navigation_contract");
const navigation_planner = @import("navigation_planner");

const logical_state_domain = "incinerator.npc.logical";
const logical_state_schema: u16 = 5;

const NodeRef = feature_contract.NodeRef;
const ChunkCoord = feature_contract.ChunkCoord;
const max_npcs = feature_contract.max_npcs;
const max_pending_commands = feature_contract.max_pending_commands;
const max_outcomes = feature_contract.max_outcomes;
const max_events = feature_contract.max_events;
const max_navigation_transitions = feature_contract.max_navigation_transitions;
const max_route_nodes = feature_contract.max_route_nodes;
const max_physical_edge_exclusions = feature_contract.max_physical_edge_exclusions;
const declared_budget = feature_contract.declared_budget;
const Config = feature_contract.Config;
const NpcConfigV1 = feature_contract.NpcConfigV1;
const Goal = feature_contract.Goal;
const State = feature_contract.State;
const NavigationProgress = feature_contract.NavigationProgress;
const NavigationStatus = feature_contract.NavigationStatus;
const NavigationReason = feature_contract.NavigationReason;
const NavigationLineage = feature_contract.NavigationLineage;
const NavigationTransition = feature_contract.NavigationTransition;
const NavigationTransitionKind = feature_contract.NavigationTransitionKind;
const PlanTrigger = feature_contract.PlanTrigger;
const PlanResult = feature_contract.PlanResult;
const EncounterLocomotion = feature_contract.EncounterLocomotion;
const PatrolLeg = feature_contract.PatrolLeg;
const PersistedRouteMode = feature_contract.PersistedRouteMode;
const RoutePlan = feature_contract.RoutePlan;
const RouteCursor = feature_contract.RouteCursor;
const NpcRouteCursorV1 = feature_contract.NpcRouteCursorV1;
const SpawnNpc = feature_contract.SpawnNpc;
const SetGoal = feature_contract.SetGoal;
const DespawnNpc = feature_contract.DespawnNpc;
const Command = feature_contract.Command;
const CommandKind = feature_contract.CommandKind;
const RejectionReason = feature_contract.RejectionReason;
const Outcome = feature_contract.Outcome;
const Event = feature_contract.Event;
const EventDropCounts = feature_contract.EventDropCounts;
const NpcView = feature_contract.NpcView;
const NpcDraw = feature_contract.NpcDraw;
const Diagnostics = feature_contract.Diagnostics;
const NpcV1 = feature_contract.NpcV1;
const validateCommand = feature_contract.validateCommand;

const FixedQueue = engine.BoundedQueue;

const navigation_progress_epsilon: f32 = 0.002;
const potential_stall_ticks: u16 = 120;
const physical_block_retry_ticks: u64 = 60;

fn updateNavigationProgress(
    progress: *NavigationProgress,
    state: State,
    previous: [3]f32,
    current: [3]f32,
    tick_index: u64,
) void {
    if (state == .dormant) {
        progress.* = .{ .state = .dormant };
        return;
    }
    if (state == .waiting_at_boundary) {
        progress.* = .{ .state = .waiting_for_content };
        return;
    }
    const target = progress.target orelse {
        progress.* = .{ .state = .idle, .last_progress_tick = progress.last_progress_tick };
        return;
    };
    const previous_dx = target[0] - previous[0];
    const previous_dz = target[2] - previous[2];
    const current_dx = target[0] - current[0];
    const current_dz = target[2] - current[2];
    const previous_distance = @sqrt(
        previous_dx * previous_dx + previous_dz * previous_dz,
    );
    const current_distance = @sqrt(
        current_dx * current_dx + current_dz * current_dz,
    );
    if (previous_distance - current_distance >= navigation_progress_epsilon) {
        progress.no_progress_ticks = 0;
        progress.last_progress_tick = tick_index;
        progress.state = .moving;
        return;
    }
    progress.no_progress_ticks +|= 1;
    progress.state = if (progress.no_progress_ticks >= potential_stall_ticks)
        .potentially_stalled
    else
        .moving;
}

const RouteBuild = union(enum) {
    ready: RoutePlan,
    blocked,
    structurally_unreachable,
    invalid_content,
};

const GoalRouteBuild = union(enum) {
    ready: RouteCursor,
    blocked,
    structurally_unreachable,
    invalid_content,
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
            hostile_to_players: bool,
            goal: Goal,
            route: RouteCursor,
            state: State,
            position: [3]f32,
            velocity: [3]f32,
            facing_yaw: f32,
            encounter_locomotion: ?EncounterLocomotion = null,
            /// Transient cooked-graph route for encounter pursuit. The
            /// encounter feature persists the destination and rebuilds this
            /// scratch route after restore.
            encounter_route: ?RouteCursor = null,
            /// Restore/streaming handoff retained while a pursuit route cannot
            /// yet be resolved through active content. `encounter_locomotion`
            /// remains `.hold` until this typed intent can be installed.
            pending_encounter_locomotion: ?EncounterLocomotion = null,
            navigation_progress: NavigationProgress = .{},
            navigation_status: NavigationStatus = .idle,
            navigation_reason: NavigationReason = .none,
            navigation_lineage: NavigationLineage = .{},
            outside_navigation_coverage: bool = false,
            physical_edge_exclusions: [max_physical_edge_exclusions]navigation_planner.EdgeExclusion =
                [_]navigation_planner.EdgeExclusion{.{
                    .source = .{},
                    .target = .{},
                }} ** max_physical_edge_exclusions,
            physical_edge_exclusion_count: u8 = 0,
            physical_block_retry_tick: u64 = 0,

            fn physicalEdgeExclusions(
                self: *const LogicalState,
            ) []const navigation_planner.EdgeExclusion {
                return self.physical_edge_exclusions[0..@min(
                    @as(usize, self.physical_edge_exclusion_count),
                    max_physical_edge_exclusions,
                )];
            }
        };
        /// The controller is valid only for the exact owner content cohort.
        /// Tickets are runtime-only and are never persisted.
        const RuntimeController = struct {
            handle: ?Controllers.Handle = null,
            owner_ticket: ?navigation.LoadTicket = null,
        };
        const PreparedEncounterOwnerTransfer = struct {
            locomotion: ?EncounterLocomotion = null,
            route: ?RouteCursor = null,
            pending: ?EncounterLocomotion = null,
        };
        const PreparedGoalOwnerTransfer = struct {
            route: RouteCursor,
            result: PlanResult,
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
        const ReplanCandidate = struct {
            id: engine.PersistentId,
            runtime_id: engine.RuntimeId,
            trigger: PlanTrigger,
        };

        fn lessThanReplanCandidate(
            _: void,
            lhs: ReplanCandidate,
            rhs: ReplanCandidate,
        ) bool {
            return lessThanPersistentId({}, lhs.id, rhs.id);
        }

        runtime: *engine.Runtime,
        controllers: *Controllers,
        navigation_access: *NavigationAccess,
        config: Config,
        records: [max_npcs]engine.RuntimeId = undefined,
        record_count: usize = 0,
        commands: FixedQueue(QueuedCommand, max_pending_commands) = .{},
        outcomes: FixedQueue(Outcome, max_outcomes) = .{},
        events: FixedQueue(Event, max_events) = .{},
        navigation_transitions: FixedQueue(
            NavigationTransition,
            max_navigation_transitions,
        ) = .{},
        commands_high_water: u32 = 0,
        outcomes_high_water: u32 = 0,
        events_high_water: u32 = 0,
        navigation_transitions_high_water: u32 = 0,
        commands_rejected: u64 = 0,
        event_drops: EventDropCounts = .{},
        transfers: u64 = 0,
        controllers_suspended: u64 = 0,
        controllers_resumed: u64 = 0,
        replans: u64 = 0,
        deferred_replans: u64 = 0,
        navigation_transition_drops: u64 = 0,
        presentation: [max_npcs]NpcDraw = undefined,
        presentation_count: usize = 0,

        /// Completed-tick composition port consumed by `npc_encounter`.
        /// Applying intent here cannot move a controller; the next registered
        /// NPC movement phase remains the sole mutation point.
        pub const EncounterAccess = struct {
            feature: *Self,

            pub fn apply(
                self: *EncounterAccess,
                id: engine.PersistentId,
                locomotion: EncounterLocomotion,
            ) !void {
                try self.feature.applyEncounterLocomotion(id, locomotion);
            }

            pub fn restore(
                self: *EncounterAccess,
                id: engine.PersistentId,
                locomotion: EncounterLocomotion,
            ) !void {
                try self.feature.restoreEncounterLocomotion(id, locomotion);
            }
        };

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

        pub fn peekOutcome(self: *const Self) ?Outcome {
            return self.outcomes.peek();
        }

        /// The owner thread must remain exclusive between peek and commit.
        pub fn commitOutcome(self: *Self, expected: Outcome) !void {
            const actual = self.outcomes.peek() orelse return error.NpcOutcomeMissing;
            if (!std.meta.eql(actual, expected)) return error.NpcOutcomeCommitMismatch;
            _ = self.outcomes.pop().?;
            self.observeQueueHighWater();
        }

        pub fn pollEvent(self: *Self) ?Event {
            const result = self.events.pop();
            self.observeQueueHighWater();
            return result;
        }

        pub fn pollNavigationTransition(self: *Self) ?NavigationTransition {
            const result = self.navigation_transitions.pop();
            self.observeQueueHighWater();
            return result;
        }

        pub fn hasPendingCommands(self: *const Self) bool {
            return self.commands.len != 0;
        }

        pub fn count(self: *const Self) usize {
            return self.record_count;
        }

        pub fn encounterAccess(self: *Self) EncounterAccess {
            return .{ .feature = self };
        }

        pub fn copyViews(self: *Self, storage: []NpcView) ![]const NpcView {
            if (storage.len < self.record_count) return error.InsufficientNpcViewStorage;
            for (self.records[0..self.record_count], 0..) |runtime_id, index| {
                storage[index] = try self.view(try self.runtime.identity(runtime_id));
            }
            std.mem.sort(NpcView, storage[0..self.record_count], {}, lessThanView);
            return storage[0..self.record_count];
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
                .hostile_to_players = logical.hostile_to_players,
                .goal = logical.goal,
                .route = logical.route,
                .state = logical.state,
                .position = logical.position,
                .velocity = logical.velocity,
                .facing_yaw = logical.facing_yaw,
                .controller_present = controller.handle != null,
                .encounter_locomotion = logical.encounter_locomotion,
                .navigation_progress = logical.navigation_progress,
                .navigation_status = logical.navigation_status,
                .navigation_reason = logical.navigation_reason,
                .navigation_lineage = logical.navigation_lineage,
                .physical_edge_exclusions = logical.physical_edge_exclusions,
                .physical_edge_exclusion_count = logical.physical_edge_exclusion_count,
                .physical_block_retry_tick = logical.physical_block_retry_tick,
            };
        }

        fn applyEncounterLocomotion(
            self: *Self,
            id: engine.PersistentId,
            locomotion: EncounterLocomotion,
        ) !void {
            try self.runtime.ensureSnapshotBoundary();
            try locomotion.validate();
            const runtime_id = self.runtime.resolve(id) orelse return error.NpcNotFound;
            _ = self.runtime.get(runtime_id, Npc) orelse return error.NotAnNpc;
            const logical = self.runtime.getMut(runtime_id, LogicalState) orelse
                return error.NpcLogicalStateInvariantBroken;
            switch (locomotion) {
                .resume_route => {
                    logical.pending_encounter_locomotion = null;
                    const start = try encounterOwnerRouteNode(self, logical.*);
                    const patrol_leg = logical.route.patrol_leg;
                    logical.route = switch (try self.buildGoalRoute(
                        start,
                        logical.goal,
                        logical.position,
                    )) {
                        .ready => |route| route,
                        // Streaming residency is not a semantic route failure.
                        // Retain an owner-aligned cursor until every cohort
                        // needed by the admitted goal is active again; normal
                        // residency reconciliation owns the eventual rebuild.
                        .blocked, .structurally_unreachable => routeAwaitingRebuild(
                            start,
                            patrol_leg,
                            logical.position,
                        ),
                        .invalid_content => return error.NpcEncounterReturnRouteInvalid,
                    };
                    logical.encounter_locomotion = null;
                    logical.encounter_route = null;
                },
                .hold, .face_and_hold => {
                    logical.pending_encounter_locomotion = null;
                    logical.encounter_locomotion = locomotion;
                    if (logical.encounter_route == null) {
                        const anchor = try encounterOwnerRouteNode(self, logical.*);
                        logical.encounter_route = .{
                            .plan = planWithOne(anchor),
                            .segment_start = logical.position,
                        };
                    }
                },
                .pursue_position => |position| {
                    if (!try self.installEncounterPursuit(logical, position)) {
                        try deferEncounterLocomotion(logical, locomotion);
                    }
                },
            }
        }

        fn restoreEncounterLocomotion(
            self: *Self,
            id: engine.PersistentId,
            locomotion: EncounterLocomotion,
        ) !void {
            try self.runtime.ensureSnapshotBoundary();
            try locomotion.validate();
            const runtime_id = self.runtime.resolve(id) orelse return error.NpcNotFound;
            _ = self.runtime.get(runtime_id, Npc) orelse return error.NotAnNpc;
            const logical = self.runtime.getMut(runtime_id, LogicalState) orelse
                return error.NpcLogicalStateInvariantBroken;
            switch (locomotion) {
                .resume_route => {
                    logical.encounter_locomotion = null;
                    logical.encounter_route = null;
                    logical.pending_encounter_locomotion = null;
                },
                .hold, .face_and_hold => {
                    logical.pending_encounter_locomotion = null;
                    try installAnchoredEncounterLocomotion(logical, locomotion);
                },
                .pursue_position => |position| {
                    if (!try self.installEncounterPursuit(logical, position)) {
                        try deferEncounterLocomotion(logical, locomotion);
                    }
                },
            }
        }

        fn installEncounterPursuit(
            self: *Self,
            logical: *LogicalState,
            position: [3]f32,
        ) !bool {
            const start = switch (self.navigation_access.nearestActiveNode(logical.position)) {
                .ready => |resolved| resolved.reference,
                .district_inactive => return false,
                .unavailable => return error.NpcEncounterStartNodeUnavailable,
            };
            const target = switch (self.navigation_access.nearestActiveNode(position)) {
                .ready => |resolved| resolved.reference,
                .district_inactive => return false,
                .unavailable => return error.NpcEncounterTargetNodeUnavailable,
            };
            const plan = switch (try self.buildRoute(start, target)) {
                .ready => |value| value,
                .blocked => return false,
                .structurally_unreachable => return error.NpcEncounterRouteUnavailable,
                .invalid_content => return error.NpcEncounterRouteInvalid,
            };
            logical.encounter_locomotion = .{ .pursue_position = position };
            logical.encounter_route = .{
                .plan = plan,
                .segment_start = logical.position,
            };
            logical.pending_encounter_locomotion = null;
            return true;
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
                const route = try persistentRouteCursor(
                    self.navigation_access,
                    logical.*,
                );
                records[index] = .{
                    .id = id,
                    .owner = logical.owner,
                    .hostile_to_players = logical.hostile_to_players,
                    .goal = logical.goal,
                    .route = route,
                    .position = canonicalVector(logical.position),
                    .velocity = canonicalVector(logical.velocity),
                    .facing_yaw = canonicalFloat(try engine.transform.normalizeFacingYaw(
                        logical.facing_yaw,
                    )),
                };
            }
            std.mem.sort(NpcV1, records, {}, lessThanRecord);
            try snapshot_validation.validateRecords(self.navigation_access, records);
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
            try snapshot_validation.validateRecords(self.navigation_access, records);
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
                const runtime_id = self.runtime.resolve(id) orelse
                    return error.NpcLogicalStateInvariantBroken;
                const logical = self.runtime.get(runtime_id, LogicalState) orelse
                    return error.NpcLogicalStateInvariantBroken;
                writePersistentId(writer, id);
                writeCoord(writer, logical.owner);
                writer.writeBool(logical.hostile_to_players);
                try writeGoal(writer, logical.goal);
                writePersistentRouteCursor(
                    writer,
                    try persistentRouteCursor(self.navigation_access, logical.*),
                );
                writeState(writer, logical.state);
                try writeVector3(writer, logical.position);
                try writeVector3(writer, logical.velocity);
                try writer.writeF32(logical.facing_yaw);
                writer.writeU8(@intFromEnum(logical.navigation_status));
                writer.writeU8(@intFromEnum(logical.navigation_reason));
                writer.writeU64(logical.navigation_lineage.route_revision);
                writer.writeU64(logical.navigation_lineage.planned_tick);
                writer.writeU64(logical.navigation_lineage.topology_revision);
                writer.writeU8(@intFromEnum(logical.navigation_lineage.last_trigger));
                writer.writeU8(@intFromEnum(logical.navigation_lineage.last_result));
                writer.writeU32(logical.navigation_lineage.replan_count);
                writer.writeBool(logical.navigation_lineage.arrival_tick != null);
                if (logical.navigation_lineage.arrival_tick) |tick| writer.writeU64(tick);
                writer.writeBool(logical.navigation_lineage.displacement_tick != null);
                if (logical.navigation_lineage.displacement_tick) |tick| writer.writeU64(tick);
                writer.writeBool(logical.outside_navigation_coverage);
                writer.writeU8(logical.route.index);
                writer.writeU8(logical.route.plan.len);
                writer.writeU8(logical.route.plan.active_prefix_len);
                writer.writeU32(logical.route.plan.total_cost);
                writer.writeU64(logical.route.plan.topology_revision);
                writer.writeU64(logical.route.plan.digest);
                writer.writeU8(logical.physical_edge_exclusion_count);
                for (logical.physicalEdgeExclusions()) |excluded| {
                    writeNodeRef(writer, excluded.source);
                    writeNodeRef(writer, excluded.target);
                }
                writer.writeU64(logical.physical_block_retry_tick);
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
            // Navigation transitions are a diagnostic projection consumed at
            // a different host boundary in live authority and direct replay;
            // authoritative route state and the retained drop counter remain
            // in this digest, but the consumable diagnostic FIFO does not.
            writer.writeU64(self.event_drops.state_changed);
            writer.writeU64(self.event_drops.owner_transferred);
            writer.writeU64(self.event_drops.goal_reached);
            writer.writeU64(self.transfers);
            writer.writeU64(self.controllers_suspended);
            writer.writeU64(self.controllers_resumed);
            writer.writeU64(self.replans);
            writer.writeU64(self.deferred_replans);
            writer.writeU64(self.navigation_transition_drops);
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
                .navigation_transitions = .{
                    .occupancy = @intCast(self.navigation_transitions.len),
                    .high_water = self.navigation_transitions_high_water,
                    .capacity = max_navigation_transitions,
                    .rejected = self.navigation_transition_drops,
                },
                .replans = self.replans,
                .deferred_replans = self.deferred_replans,
                .teleport_rollbacks = 0,
            };
        }

        fn commandsSystem(
            raw: *anyopaque,
            _: *engine.Runtime,
            tick: engine.TickContext,
        ) !void {
            const self: *Self = @ptrCast(@alignCast(raw));
            defer self.observeQueueHighWater();
            try self.replanNavigationChanges();
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

        fn replanNavigationChanges(self: *Self) !void {
            var candidates: [max_npcs]ReplanCandidate = undefined;
            var candidate_count: usize = 0;
            const topology_revision = self.navigation_access.topologyRevision();
            for (self.records[0..self.record_count]) |runtime_id| {
                const logical = self.runtime.getMut(runtime_id, LogicalState) orelse
                    return error.NpcLogicalStateInvariantBroken;
                if (logical.goal == .hold or logical.encounter_locomotion != null) continue;
                const trigger: ?PlanTrigger =
                    if (logical.navigation_lineage.topology_revision != topology_revision)
                        .topology_changed
                    else if (try self.refreshPhysicalObstruction(
                        runtime_id,
                        logical,
                    ))
                        .physical_obstruction
                    else if (logical.navigation_status == .waiting_for_content and
                    try self.destinationReady(logical.*))
                        .district_generation_changed
                    else
                        null;
                if (trigger) |value| {
                    candidates[candidate_count] = .{
                        .id = try self.runtime.identity(runtime_id),
                        .runtime_id = runtime_id,
                        .trigger = value,
                    };
                    candidate_count += 1;
                }
            }
            std.mem.sort(
                ReplanCandidate,
                candidates[0..candidate_count],
                {},
                lessThanReplanCandidate,
            );
            const admitted = @min(candidate_count, @as(usize, 8));
            for (candidates[0..admitted]) |candidate| {
                try self.replanOne(candidate.runtime_id, candidate.trigger);
            }
            self.deferred_replans +|= candidate_count - admitted;
        }

        fn replanOne(
            self: *Self,
            runtime_id: engine.RuntimeId,
            trigger: PlanTrigger,
        ) !void {
            const logical = self.runtime.getMut(runtime_id, LogicalState) orelse
                return error.NpcLogicalStateInvariantBroken;
            const start = try ownerRouteNode(logical.*);
            const result = try self.buildRestoredGoalRouteExcluding(
                start,
                logical.goal,
                logical.route.patrol_leg,
                logical.route.next(),
                logical.position,
                logical.physicalEdgeExclusions(),
            );
            const route = switch (result) {
                .ready => |value| value,
                .blocked, .structurally_unreachable => routeAwaitingRebuild(
                    start,
                    logical.route.patrol_leg,
                    logical.position,
                ),
                .invalid_content => return error.NpcDestinationInvalid,
            };
            try self.commitNavigationPlan(
                runtime_id,
                logical,
                route,
                trigger,
                classifyGoalRoute(logical.goal, result),
                .route_invalidated,
            );
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
                logical.navigation_progress.target = null;
                var horizontal = [2]f32{ 0, 0 };
                if (logical.state == .active) {
                    if (logical.encounter_locomotion) |locomotion| switch (locomotion) {
                        .resume_route => unreachable,
                        .hold => {},
                        .face_and_hold => |target_position| {
                            const dx = target_position[0] - before.position[0];
                            const dz = target_position[2] - before.position[2];
                            if (dx * dx + dz * dz > std.math.floatEps(f32)) {
                                logical.facing_yaw = try engine.transform.normalizeFacingYaw(
                                    std.math.atan2(dx, -dz),
                                );
                            }
                        },
                        .pursue_position => |target_position| {
                            const movement_target = if (logical.encounter_route) |route|
                                if (route.next()) |next_ref|
                                    switch (self.navigation_access.resolveNode(next_ref)) {
                                        .ready => |resolved| resolved.node.position,
                                        .district_inactive => return error.NpcEncounterRouteDistrictInactive,
                                        .invalid_reference => return error.NpcEncounterRouteInvalid,
                                    }
                                else
                                    target_position
                            else
                                target_position;
                            const dx = movement_target[0] - before.position[0];
                            const dz = movement_target[2] - before.position[2];
                            const distance = @sqrt(dx * dx + dz * dz);
                            if (distance > self.config.arrival_distance) {
                                logical.navigation_progress.target = movement_target;
                                const speed = @min(
                                    self.config.move_speed,
                                    distance / tick.delta_seconds,
                                );
                                horizontal = .{ dx / distance * speed, dz / distance * speed };
                                logical.facing_yaw = try engine.transform.normalizeFacingYaw(
                                    std.math.atan2(dx, -dz),
                                );
                            }
                        },
                    } else if (logical.route.next()) |next_ref| {
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
                                logical.navigation_progress.target = resolved.node.position;
                                const speed = @min(
                                    self.config.move_speed,
                                    distance / tick.delta_seconds,
                                );
                                horizontal = .{ dx / distance * speed, dz / distance * speed };
                                logical.facing_yaw = try engine.transform.normalizeFacingYaw(
                                    std.math.atan2(dx, -dz),
                                );
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
                const previous_position = logical.position;
                const state = try self.controllers.characterState(handle);
                try state.validate();
                logical.position = canonicalVector(state.position);
                logical.velocity = canonicalVector(state.velocity);
                updateNavigationProgress(
                    &logical.navigation_progress,
                    logical.state,
                    previous_position,
                    logical.position,
                    tick.tick_index,
                );
                try self.confirmPhysicalObstruction(runtime_id, logical);

                const next_owner = try navigation.ownerForPosition(logical.position);
                if (!navigation.ChunkCoord.eql(next_owner, logical.owner)) {
                    switch (self.navigation_access.nearestActiveNode(logical.position)) {
                        .ready => |destination| self.adoptPositionalOwner(
                            runtime_id,
                            logical,
                            runtime_controller,
                            next_owner,
                            destination,
                        ) catch |err| switch (err) {
                            error.NpcDisplacementAnchorObstructed,
                            error.NpcEncounterTargetNodeUnavailable,
                            error.NpcEncounterRouteUnavailable,
                            => try self.recoverExternalDisplacement(
                                runtime_id,
                                logical,
                                runtime_controller,
                                handle,
                            ),
                            else => return err,
                        },
                        .district_inactive, .unavailable => try self.recoverExternalDisplacement(
                            runtime_id,
                            logical,
                            runtime_controller,
                            handle,
                        ),
                    }
                }

                if (logical.encounter_route != null) {
                    try self.advanceEncounterRouteIfArrived(logical);
                } else if (logical.encounter_locomotion == null) {
                    try self.advanceIfArrived(runtime_id, logical);
                }
                const history = self.runtime.getMut(runtime_id, TransformHistory) orelse
                    return error.NpcTransformInvariantBroken;
                history.previous = history.current;
                history.current = try poseFor(logical.position, logical.facing_yaw);
                history.current_tick = tick.tick_index;
            }
        }

        fn adoptPositionalOwner(
            self: *Self,
            runtime_id: engine.RuntimeId,
            logical: *LogicalState,
            runtime_controller: *RuntimeController,
            next_owner: navigation.ChunkCoord,
            destination: navigation.ResolvedNode,
        ) !void {
            if (!navigation.ChunkCoord.eql(destination.reference.coord, next_owner) or
                !navigation.ChunkCoord.eql(destination.ticket.coord, next_owner))
            {
                return error.NpcPositionalOwnerResolutionMismatch;
            }
            if (!try self.anchorReachable(
                logical.position,
                destination.node.position,
            )) {
                return error.NpcDisplacementAnchorObstructed;
            }

            // Prepare every fallible route decision before changing owner or
            // ticket. Physical position determines spatial ownership; the
            // retained goal and encounter route are movement intent rebuilt
            // from an owner-aligned navigation anchor.
            const rebased_route = try self.prepareGoalAfterOwnerTransfer(
                logical.*,
                destination.reference,
            );
            const rebased_encounter = try self.prepareEncounterAfterOwnerTransfer(
                logical.*,
                destination.reference,
            );
            const id = try self.runtime.identity(runtime_id);
            const previous_owner = logical.owner;

            // CharacterVirtual is world-global rather than district-owned.
            // Rebind the same live controller; reconstruction remains reserved
            // for generation changes, inactive content, and dormancy.
            logical.owner = next_owner;
            logical.route = rebased_route.route;
            logical.encounter_locomotion = rebased_encounter.locomotion;
            logical.encounter_route = rebased_encounter.route;
            logical.pending_encounter_locomotion = rebased_encounter.pending;
            runtime_controller.owner_ticket = destination.ticket;
            logical.navigation_status = navigationStatus(
                logical.goal,
                rebased_route.result,
            );
            logical.navigation_reason = navigationReason(
                rebased_route.result,
                .owner_transferred,
            );
            logical.navigation_lineage.route_revision +|= 1;
            logical.navigation_lineage.planned_tick = self.runtime.tickIndex();
            logical.navigation_lineage.topology_revision =
                self.navigation_access.topologyRevision();
            logical.navigation_lineage.last_trigger = .owner_transferred;
            logical.navigation_lineage.last_result = rebased_route.result;
            logical.navigation_lineage.replan_count +|= 1;
            self.replans +|= 1;
            self.transfers +|= 1;
            try self.emitEvent(.{ .owner_transferred = .{
                .id = id,
                .previous = previous_owner,
                .current = next_owner,
            } });
            try self.emitNavigationTransition(runtime_id, logical, .anchor_changed);
        }

        fn prepareGoalAfterOwnerTransfer(
            self: *Self,
            logical: LogicalState,
            anchor: navigation.NodeRef,
        ) !PreparedGoalOwnerTransfer {
            return switch (try self.buildRestoredGoalRoute(
                anchor,
                logical.goal,
                logical.route.patrol_leg,
                null,
                logical.position,
            )) {
                .ready => |route| .{
                    .route = route,
                    .result = classifyRouteCursor(logical.goal, route),
                },
                .invalid_content => error.NpcDisplacedGoalInvalid,
                .blocked => .{
                    .route = routeAwaitingRebuild(
                        anchor,
                        logical.route.patrol_leg,
                        logical.position,
                    ),
                    .result = .blocked_by_traversal,
                },
                .structurally_unreachable => .{
                    .route = routeAwaitingRebuild(
                        anchor,
                        logical.route.patrol_leg,
                        logical.position,
                    ),
                    .result = .structurally_unreachable,
                },
            };
        }

        fn prepareEncounterAfterOwnerTransfer(
            self: *Self,
            logical: LogicalState,
            anchor: navigation.NodeRef,
        ) !PreparedEncounterOwnerTransfer {
            const desired = logical.pending_encounter_locomotion orelse
                logical.encounter_locomotion orelse return .{};
            return switch (desired) {
                .resume_route => error.NpcEncounterLocomotionInvariantBroken,
                .hold, .face_and_hold => .{
                    .locomotion = desired,
                    .route = .{
                        .plan = planWithOne(anchor),
                        .segment_start = logical.position,
                    },
                },
                .pursue_position => |target_position| blk: {
                    const target = switch (self.navigation_access.nearestActiveNode(
                        target_position,
                    )) {
                        .ready => |resolved| resolved.reference,
                        .district_inactive => break :blk deferredEncounterTransfer(
                            anchor,
                            desired,
                            logical.position,
                        ),
                        .unavailable => return error.NpcEncounterTargetNodeUnavailable,
                    };
                    const plan = switch (try self.buildRoute(anchor, target)) {
                        .ready => |value| value,
                        .blocked => break :blk deferredEncounterTransfer(
                            anchor,
                            desired,
                            logical.position,
                        ),
                        .structurally_unreachable => return error.NpcEncounterRouteUnavailable,
                        .invalid_content => return error.NpcEncounterRouteInvalid,
                    };
                    break :blk .{
                        .locomotion = .{ .pursue_position = target_position },
                        .route = .{
                            .plan = plan,
                            .segment_start = logical.position,
                        },
                    };
                },
            };
        }

        fn deferredEncounterTransfer(
            anchor: navigation.NodeRef,
            desired: EncounterLocomotion,
            position: [3]f32,
        ) PreparedEncounterOwnerTransfer {
            return .{
                .locomotion = .hold,
                .route = .{
                    .plan = planWithOne(anchor),
                    .segment_start = position,
                },
                .pending = desired,
            };
        }

        fn recoverExternalDisplacement(
            self: *Self,
            runtime_id: engine.RuntimeId,
            logical: *LogicalState,
            runtime_controller: *RuntimeController,
            handle: Controllers.Handle,
        ) !void {
            // Physical displacement is authoritative fact. If the destination
            // district is unavailable, retain the new pose and semantic goal,
            // suspend only the controller, and rebuild from a catalog anchor
            // after content becomes active. Never relocate to the old route.
            const previous_owner = logical.owner;
            const next_owner = try navigation.ownerForPosition(logical.position);
            logical.physical_edge_exclusion_count = 0;
            logical.physical_block_retry_tick = 0;
            try self.controllers.destroyCharacter(handle);
            runtime_controller.* = .{};
            logical.owner = next_owner;
            const anchor = try self.nearestCatalogNode(logical.position);
            if (anchor == null) {
                logical.outside_navigation_coverage = true;
                logical.navigation_status = .blocked;
                logical.navigation_reason = .outside_navigation_coverage;
                logical.navigation_lineage.displacement_tick = self.runtime.tickIndex();
                logical.navigation_lineage.last_trigger = .external_displacement;
                logical.navigation_lineage.last_result = .blocked_by_traversal;
                self.controllers_suspended +|= 1;
                try self.emitNavigationTransition(
                    runtime_id,
                    logical,
                    .displacement_detected,
                );
                try self.transition(runtime_id, logical, .dormant);
                return;
            }
            logical.outside_navigation_coverage = false;
            logical.route = routeAwaitingRebuild(
                anchor.?,
                logical.route.patrol_leg,
                logical.position,
            );
            logical.navigation_status = .blocked;
            logical.navigation_reason = .external_displacement;
            logical.navigation_lineage.displacement_tick = self.runtime.tickIndex();
            logical.navigation_lineage.last_trigger = .external_displacement;
            logical.navigation_lineage.last_result = .blocked_by_traversal;
            logical.navigation_lineage.topology_revision =
                self.navigation_access.topologyRevision();
            if (logical.encounter_locomotion) |locomotion| {
                logical.pending_encounter_locomotion = locomotion;
                logical.encounter_locomotion = .hold;
                logical.encounter_route = .{
                    .plan = planWithOne(anchor.?),
                    .segment_start = logical.position,
                };
            }
            self.controllers_suspended +|= 1;
            try self.emitNavigationTransition(
                runtime_id,
                logical,
                .displacement_detected,
            );
            try self.emitNavigationTransition(runtime_id, logical, .anchor_changed);
            try self.transition(runtime_id, logical, .dormant);
            if (!navigation.ChunkCoord.eql(previous_owner, next_owner)) {
                self.transfers +|= 1;
                try self.emitEvent(.{ .owner_transferred = .{
                    .id = try self.runtime.identity(runtime_id),
                    .previous = previous_owner,
                    .current = next_owner,
                } });
            }
        }

        fn nearestCatalogNode(
            self: *Self,
            position: [3]f32,
        ) !?navigation.NodeRef {
            const coord = navigation.ownerForPosition(position) catch return null;
            var best: ?navigation.NodeRef = null;
            var best_distance_squared = std.math.inf(f32);
            for (0..8) |index| {
                const reference = navigation.NodeRef{
                    .coord = coord,
                    .index = @intCast(index),
                };
                const resolved = switch (self.navigation_access.resolveCatalogNode(
                    reference,
                )) {
                    .ready => |value| value,
                    .invalid_reference => continue,
                };
                if (!try self.anchorReachable(position, resolved.node.position)) {
                    continue;
                }
                const dx = resolved.node.position[0] - position[0];
                const dz = resolved.node.position[2] - position[2];
                const distance_squared = dx * dx + dz * dz;
                if (best == null or distance_squared < best_distance_squared or
                    (distance_squared == best_distance_squared and
                        nodeRefLessThan(reference, best.?)))
                {
                    best = reference;
                    best_distance_squared = distance_squared;
                }
            }
            return best;
        }

        fn anchorReachable(
            self: *Self,
            position: [3]f32,
            anchor_position: [3]f32,
        ) !bool {
            const center_height = self.config.half_height + self.config.radius;
            return self.controllers.lineUnobstructed(
                .{ position[0], position[1] + center_height, position[2] },
                .{
                    anchor_position[0],
                    anchor_position[1] + center_height,
                    anchor_position[2],
                },
            );
        }

        fn confirmPhysicalObstruction(
            self: *Self,
            runtime_id: engine.RuntimeId,
            logical: *LogicalState,
        ) !void {
            if (logical.encounter_locomotion != null or
                logical.navigation_status != .following or
                logical.navigation_progress.state != .potentially_stalled or
                self.runtime.tickIndex() < logical.physical_block_retry_tick)
            {
                return;
            }
            const target_ref = logical.route.next() orelse return;
            const target = switch (self.navigation_access.resolveNode(target_ref)) {
                .ready => |resolved| resolved,
                .district_inactive => return,
                .invalid_reference => return error.NpcRouteReferenceInvalid,
            };
            if (try self.anchorReachable(logical.position, target.node.position)) return;

            const source_ref = try currentRouteNode(logical.route);
            self.addPhysicalEdgeExclusion(logical, .{
                .source = source_ref,
                .target = target_ref,
            });
            logical.navigation_reason = .physical_obstruction;
            logical.navigation_lineage.last_trigger = .physical_obstruction;
            logical.navigation_lineage.last_result = .blocked_by_traversal;
            try self.emitNavigationTransition(runtime_id, logical, .block_suspected);
            logical.navigation_status = .blocked;
            try self.emitNavigationTransition(runtime_id, logical, .block_confirmed);
            logical.physical_block_retry_tick =
                self.runtime.tickIndex() +| physical_block_retry_ticks;
            try self.replanOne(runtime_id, .physical_obstruction);
        }

        fn addPhysicalEdgeExclusion(
            _: *Self,
            logical: *LogicalState,
            exclusion: navigation_planner.EdgeExclusion,
        ) void {
            for (logical.physicalEdgeExclusions()) |existing| {
                if (existing.matches(exclusion.source, exclusion.target)) return;
            }
            if (logical.physical_edge_exclusion_count < max_physical_edge_exclusions) {
                const index = logical.physical_edge_exclusion_count;
                logical.physical_edge_exclusions[index] = exclusion;
                logical.physical_edge_exclusion_count += 1;
                return;
            }
            for (0..max_physical_edge_exclusions - 1) |index| {
                logical.physical_edge_exclusions[index] =
                    logical.physical_edge_exclusions[index + 1];
            }
            logical.physical_edge_exclusions[max_physical_edge_exclusions - 1] =
                exclusion;
        }

        /// Retry a confirmed dynamic obstruction only on a bounded cadence.
        /// Alternate routes may continue while the exclusion ages out. A
        /// blocked route is retried only after the obstructed segment is
        /// physically clear.
        fn refreshPhysicalObstruction(
            self: *Self,
            runtime_id: engine.RuntimeId,
            logical: *LogicalState,
        ) !bool {
            if (logical.physical_edge_exclusion_count == 0 or
                self.runtime.tickIndex() < logical.physical_block_retry_tick)
            {
                return false;
            }
            if (logical.navigation_status == .blocked) {
                const excluded = logical.physical_edge_exclusions[0];
                const target = switch (self.navigation_access.resolveCatalogNode(
                    excluded.target,
                )) {
                    .ready => |resolved| resolved,
                    .invalid_reference => return error.NpcRouteReferenceInvalid,
                };
                if (!try self.anchorReachable(logical.position, target.node.position)) {
                    logical.physical_block_retry_tick =
                        self.runtime.tickIndex() +| physical_block_retry_ticks;
                    return false;
                }
            }
            logical.physical_edge_exclusion_count = 0;
            logical.physical_block_retry_tick = 0;
            logical.navigation_reason = .physical_obstruction;
            logical.navigation_lineage.last_trigger = .physical_obstruction;
            try self.emitNavigationTransition(runtime_id, logical, .block_cleared);
            return logical.navigation_status == .blocked;
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
            const start = switch (self.navigation_access.resolveNode(spawn.anchor)) {
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
            if (!std.meta.eql(spawn.position, start.node.position) and
                !try self.anchorReachable(spawn.position, start.node.position))
            {
                return rejection(
                    .spawn,
                    .start_pose_blocked,
                    spawn.request_id,
                    null,
                );
            }
            const route_result = try self.buildGoalRoute(
                spawn.anchor,
                spawn.goal,
                spawn.position,
            );
            const route_tag = std.meta.activeTag(route_result);
            if (route_tag == .invalid_content) {
                return rejection(.spawn, .invalid_goal, spawn.request_id, null);
            }
            const route = switch (route_result) {
                .ready => |value| value,
                .blocked, .structurally_unreachable => routeAwaitingRebuild(
                    spawn.anchor,
                    try self.initialPatrolLeg(spawn.anchor, spawn.goal),
                    spawn.position,
                ),
                .invalid_content => unreachable,
            };
            const plan_result = classifyGoalRoute(spawn.goal, route_result);
            self.createRecord(
                null,
                start.reference.coord,
                spawn.hostile_to_players,
                spawn.goal,
                route,
                spawn.position,
                .{ 0, 0, 0 },
                spawn.facing_yaw,
                start.ticket,
                .destination_assigned,
                plan_result,
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
            if (route_tag == .invalid_content) {
                return rejection(.set_goal, .invalid_goal, command.request_id, command.id);
            }
            const route = switch (route_result) {
                .ready => |value| value,
                .blocked, .structurally_unreachable => routeAwaitingRebuild(
                    start,
                    try self.initialPatrolLeg(start, command.goal),
                    logical.position,
                ),
                .invalid_content => unreachable,
            };
            logical.goal = command.goal;
            logical.physical_edge_exclusion_count = 0;
            logical.physical_block_retry_tick = 0;
            try self.commitNavigationPlan(
                runtime_id,
                logical,
                route,
                .destination_changed,
                classifyGoalRoute(command.goal, route_result),
                .destination_changed,
            );
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
            return self.buildGoalRouteExcluding(
                start,
                goal,
                segment_start,
                &.{},
            );
        }

        fn buildGoalRouteExcluding(
            self: *Self,
            start: navigation.NodeRef,
            goal: Goal,
            segment_start: [3]f32,
            exclusions: []const navigation_planner.EdgeExclusion,
        ) !GoalRouteBuild {
            return switch (goal) {
                .hold => .{ .ready = .{
                    .plan = planWithOne(start),
                    .segment_start = segment_start,
                } },
                .navigate_to => |destination| switch (try self.buildDestinationRouteExcluding(
                    start,
                    destination,
                    exclusions,
                )) {
                    .ready => |plan| .{ .ready = .{
                        .plan = plan,
                        .segment_start = segment_start,
                    } },
                    .blocked => .blocked,
                    .structurally_unreachable => .structurally_unreachable,
                    .invalid_content => .invalid_content,
                },
                .patrol_between => |patrol| blk: {
                    const first = try self.destinationPrimaryAnchor(patrol.first);
                    const second = try self.destinationPrimaryAnchor(patrol.second);
                    const forward = switch (try self.buildRouteExcluding(
                        first,
                        second,
                        exclusions,
                    )) {
                        .ready => |plan| plan,
                        .blocked => break :blk .blocked,
                        .structurally_unreachable => break :blk .structurally_unreachable,
                        .invalid_content => break :blk .invalid_content,
                    };
                    const reverse = switch (try self.buildRouteExcluding(
                        second,
                        first,
                        exclusions,
                    )) {
                        .ready => |plan| plan,
                        .blocked => break :blk .blocked,
                        .structurally_unreachable => break :blk .structurally_unreachable,
                        .invalid_content => break :blk .invalid_content,
                    };
                    var result = RouteCursor{
                        .patrol_forward = forward,
                        .patrol_reverse = reverse,
                        .segment_start = segment_start,
                    };
                    if (navigation.NodeRef.eql(start, first)) {
                        result.plan = forward;
                        result.patrol_leg = .toward_second;
                    } else if (navigation.NodeRef.eql(start, second)) {
                        result.plan = reverse;
                        result.patrol_leg = .toward_first;
                    } else {
                        result.plan = switch (try self.buildDestinationRouteExcluding(
                            start,
                            patrol.first,
                            exclusions,
                        )) {
                            .ready => |plan| plan,
                            .blocked => break :blk .blocked,
                            .structurally_unreachable => break :blk .structurally_unreachable,
                            .invalid_content => break :blk .invalid_content,
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
            return self.buildRestoredGoalRouteExcluding(
                start,
                goal,
                persisted_leg,
                persisted_next,
                segment_start,
                &.{},
            );
        }

        fn buildRestoredGoalRouteExcluding(
            self: *Self,
            start: navigation.NodeRef,
            goal: Goal,
            persisted_leg: PatrolLeg,
            persisted_next: ?navigation.NodeRef,
            segment_start: [3]f32,
            exclusions: []const navigation_planner.EdgeExclusion,
        ) !GoalRouteBuild {
            return switch (goal) {
                .hold, .navigate_to => self.buildGoalRouteExcluding(
                    start,
                    goal,
                    segment_start,
                    exclusions,
                ),
                .patrol_between => |patrol| blk: {
                    const first = try self.destinationPrimaryAnchor(patrol.first);
                    const second = try self.destinationPrimaryAnchor(patrol.second);
                    const forward = switch (try self.buildRouteExcluding(
                        first,
                        second,
                        exclusions,
                    )) {
                        .ready => |plan| plan,
                        .blocked => break :blk .blocked,
                        .structurally_unreachable => break :blk .structurally_unreachable,
                        .invalid_content => break :blk .invalid_content,
                    };
                    const reverse = switch (try self.buildRouteExcluding(
                        second,
                        first,
                        exclusions,
                    )) {
                        .ready => |plan| plan,
                        .blocked => break :blk .blocked,
                        .structurally_unreachable => break :blk .structurally_unreachable,
                        .invalid_content => break :blk .invalid_content,
                    };
                    var leg = persisted_leg;
                    var target = switch (leg) {
                        .toward_first => first,
                        .toward_second => second,
                        .none => break :blk .invalid_content,
                    };
                    // A compact null-next endpoint means the inbound leg just
                    // completed; canonical runtime state immediately selects
                    // the outbound leg once its content can be rebuilt.
                    if (persisted_next == null and navigation.NodeRef.eql(start, target)) {
                        switch (leg) {
                            .toward_first => {
                                leg = .toward_second;
                                target = second;
                            },
                            .toward_second => {
                                leg = .toward_first;
                                target = first;
                            },
                            .none => unreachable,
                        }
                    }
                    const plan = switch (try self.buildRouteExcluding(
                        start,
                        target,
                        exclusions,
                    )) {
                        .ready => |value| value,
                        .blocked => break :blk .blocked,
                        .structurally_unreachable => break :blk .structurally_unreachable,
                        .invalid_content => break :blk .invalid_content,
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

        fn destinationPrimaryAnchor(
            self: *Self,
            id: navigation.DestinationId,
        ) !navigation.NodeRef {
            const destination = switch (self.navigation_access.resolveDestination(id)) {
                .ready => |value| value,
                .invalid_destination => return error.NpcDestinationInvalid,
            };
            destination.validate() catch return error.NpcDestinationInvalid;
            return destination.anchorSlice()[0];
        }

        fn initialPatrolLeg(
            self: *Self,
            start: navigation.NodeRef,
            goal: Goal,
        ) !PatrolLeg {
            return switch (goal) {
                .hold, .navigate_to => .none,
                .patrol_between => |patrol| blk: {
                    const first = try self.destinationPrimaryAnchor(patrol.first);
                    const second = try self.destinationPrimaryAnchor(patrol.second);
                    break :blk if (navigation.NodeRef.eql(start, second))
                        .toward_first
                    else if (navigation.NodeRef.eql(start, first))
                        .toward_second
                    else
                        .toward_first;
                },
            };
        }

        fn buildRoute(
            self: *Self,
            start: navigation.NodeRef,
            target: navigation.NodeRef,
        ) !RouteBuild {
            return self.buildRouteExcluding(start, target, &.{});
        }

        fn buildRouteExcluding(
            self: *Self,
            start: navigation.NodeRef,
            target: navigation.NodeRef,
            exclusions: []const navigation_planner.EdgeExclusion,
        ) !RouteBuild {
            return routeBuildFromPlanner(navigation_planner.planToNodeExcluding(
                self.navigation_access,
                start,
                target,
                exclusions,
            ));
        }

        fn buildDestinationRoute(
            self: *Self,
            start: navigation.NodeRef,
            destination: navigation.DestinationId,
        ) !RouteBuild {
            return self.buildDestinationRouteExcluding(start, destination, &.{});
        }

        fn buildDestinationRouteExcluding(
            self: *Self,
            start: navigation.NodeRef,
            destination: navigation.DestinationId,
            exclusions: []const navigation_planner.EdgeExclusion,
        ) !RouteBuild {
            return routeBuildFromPlanner(navigation_planner.planExcluding(
                self.navigation_access,
                start,
                destination,
                exclusions,
            ));
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
            if (logical.outside_navigation_coverage) {
                if (controller.handle != null or controller.owner_ticket != null) {
                    return error.NpcOutsideCoverageControllerInvariantBroken;
                }
                try self.transition(runtime_id, logical, .dormant);
                return;
            }
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
                    if (logical.navigation_status == .waiting_for_content and
                        logical.route.needs_rebuild and
                        logical.route.next() == null and
                        try self.rebuildTargetReady(logical.*))
                    {
                        try self.rebuildRestoredRoute(logical);
                    }
                    try self.reconcileEncounterResidency(logical);
                    if (controller.handle == null) {
                        try self.createController(logical, controller, resolved.ticket);
                        self.controllers_resumed +|= 1;
                    }
                    const desired: State = if (logical.encounter_locomotion != null)
                        .active
                    else if (try self.destinationReady(logical.*))
                        .active
                    else
                        .waiting_at_boundary;
                    try self.transition(runtime_id, logical, desired);
                },
            }
        }

        fn destinationReady(self: *Self, logical: LogicalState) !bool {
            if (logical.route.needs_rebuild and logical.route.next() == null) {
                return switch (logical.goal) {
                    .hold => true,
                    .navigate_to, .patrol_between => self.rebuildTargetReady(logical),
                };
            }
            const next_ref = logical.route.next() orelse return true;
            return switch (self.navigation_access.resolveNode(next_ref)) {
                .ready => true,
                .district_inactive => false,
                .invalid_reference => error.NpcRouteReferenceInvalid,
            };
        }

        fn reconcileEncounterResidency(self: *Self, logical: *LogicalState) !void {
            if (logical.pending_encounter_locomotion) |pending| {
                switch (pending) {
                    .pursue_position => |position| {
                        _ = try self.installEncounterPursuit(logical, position);
                    },
                    .hold, .face_and_hold, .resume_route => {
                        return error.NpcEncounterPendingLocomotionInvariantBroken;
                    },
                }
                return;
            }
            const locomotion = logical.encounter_locomotion orelse return;
            switch (locomotion) {
                .pursue_position => {
                    const route = logical.encounter_route orelse
                        return error.NpcEncounterRouteInvariantBroken;
                    const next = route.next() orelse return;
                    switch (self.navigation_access.resolveNode(next)) {
                        .ready => {},
                        .district_inactive => try deferEncounterLocomotion(
                            logical,
                            locomotion,
                        ),
                        .invalid_reference => return error.NpcEncounterRouteInvalid,
                    }
                },
                .hold, .face_and_hold => {},
                .resume_route => return error.NpcEncounterLocomotionInvariantBroken,
            }
        }

        /// A catalog probe gates semantic route reconstruction. Residency is
        /// classified by the resulting active prefix rather than by rejecting
        /// durable intent.
        fn rebuildTargetReady(self: *Self, logical: LogicalState) !bool {
            const destination: ?navigation.DestinationId = switch (logical.goal) {
                .hold => null,
                .navigate_to => |value| value,
                .patrol_between => |patrol| switch (logical.route.patrol_leg) {
                    .toward_first => patrol.first,
                    .toward_second => patrol.second,
                    .none => return error.NpcPatrolCursorInvariantBroken,
                },
            };
            const id = destination orelse return false;
            return switch (self.navigation_access.resolveDestination(id)) {
                .ready => true,
                .invalid_destination => error.NpcDestinationInvalid,
            };
        }

        fn rebuildRestoredRoute(self: *Self, logical: *LogicalState) !void {
            const persisted_next = logical.route.next();
            const current = try currentRouteNode(logical.route);
            const deferred_without_prefix = persisted_next == null and
                !isCompletedGoalEndpoint(
                    self.navigation_access,
                    logical.goal,
                    current,
                    logical.route.patrol_leg,
                );
            const rebuilt = switch (try self.buildRestoredGoalRoute(
                current,
                logical.goal,
                logical.route.patrol_leg,
                persisted_next,
                logical.position,
            )) {
                .ready => |route| route,
                .invalid_content => return error.NpcPersistedGoalInvalid,
                .blocked, .structurally_unreachable => return,
            };
            if (!deferred_without_prefix and
                !isCompletedPatrolEndpoint(
                    self.navigation_access,
                    logical.goal,
                    current,
                    logical.route.patrol_leg,
                    persisted_next,
                ) and
                !optionalNodeRefEql(persisted_next, rebuilt.next()))
            {
                return error.NpcPersistedRouteMismatch;
            }
            logical.route = rebuilt;
        }

        fn createRecord(
            self: *Self,
            restored_id: ?engine.PersistentId,
            owner: navigation.ChunkCoord,
            hostile_to_players: bool,
            goal: Goal,
            route: RouteCursor,
            position: [3]f32,
            velocity: [3]f32,
            facing_yaw: f32,
            ticket: ?navigation.LoadTicket,
            trigger: PlanTrigger,
            plan_result: PlanResult,
        ) !void {
            if (self.record_count >= max_npcs) return error.TooManyNpcs;
            const runtime_id = if (restored_id) |id|
                try self.runtime.createWithPersistentId(id)
            else
                try self.runtime.create();
            errdefer self.destroyRuntimeOrPanic(runtime_id);

            var logical = LogicalState{
                .owner = owner,
                .hostile_to_players = hostile_to_players,
                .goal = goal,
                .route = route,
                .state = if (ticket == null) .dormant else .active,
                .position = canonicalVector(position),
                .velocity = canonicalVector(velocity),
                .facing_yaw = canonicalFloat(try engine.transform.normalizeFacingYaw(
                    facing_yaw,
                )),
                .navigation_status = navigationStatus(goal, plan_result),
                .navigation_reason = navigationReason(plan_result, trigger),
                .navigation_lineage = .{
                    .route_revision = if (goal == .hold) 0 else 1,
                    .planned_tick = self.runtime.tickIndex(),
                    .topology_revision = self.navigation_access.topologyRevision(),
                    .last_trigger = trigger,
                    .last_result = plan_result,
                    .replan_count = if (goal == .hold) 0 else 1,
                },
            };
            var controller = RuntimeController{};
            if (ticket) |active_ticket| {
                try self.createController(&logical, &controller, active_ticket);
            }
            errdefer if (controller.handle) |handle| self.destroyControllerOrPanic(handle);
            const pose = try poseFor(logical.position, logical.facing_yaw);
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
            if (goal != .hold) {
                self.replans +|= 1;
                try self.emitNavigationTransition(
                    runtime_id,
                    &logical,
                    .destination_assigned,
                );
            }
        }

        fn restoreOne(self: *Self, record: NpcV1) !void {
            var route = routeFromRecord(record.route, record.position);
            var plan_result = classifyRouteCursor(record.goal, route);
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
                    if (record.route.mode == .exact_prefix) {
                        if (!isCompletedPatrolEndpoint(
                            self.navigation_access,
                            record.goal,
                            record.route.current,
                            record.route.patrol_leg,
                            record.route.next,
                        ) and !optionalNodeRefEql(record.route.next, rebuilt.next())) {
                            return error.NpcPersistedRouteMismatch;
                        }
                    }
                    route = rebuilt;
                    plan_result = classifyRouteCursor(record.goal, route);
                },
                .invalid_content => return error.NpcPersistedGoalInvalid,
                .blocked => plan_result = .blocked_by_traversal,
                .structurally_unreachable => {
                    plan_result = .structurally_unreachable;
                },
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
                record.hostile_to_players,
                record.goal,
                route,
                record.position,
                record.velocity,
                record.facing_yaw,
                ticket,
                .restored,
                plan_result,
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
            const next_ref = logical.route.next() orelse {
                if (logical.goal == .hold) return;
                if (logical.navigation_status == .arrived) return;
                const current = try currentRouteNode(logical.route);
                if (!isCompletedGoalEndpoint(
                    self.navigation_access,
                    logical.goal,
                    current,
                    logical.route.patrol_leg,
                )) return;
                return self.completeDestinationArrival(runtime_id, logical, current);
            };
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
            if (logical.route.next() != null) {
                try self.emitNavigationTransition(
                    runtime_id,
                    logical,
                    .waypoint_advanced,
                );
                return;
            }

            // A compact exact-prefix restore may retain one verified edge
            // while farther goal content is inactive. Consuming that edge is
            // not semantic goal completion: install the arrived node as the
            // deferred owner-aligned anchor and let residency reconciliation
            // rebuild only after the actual target is ready.
            if (logical.route.needs_rebuild and
                !isCompletedGoalEndpoint(
                    self.navigation_access,
                    logical.goal,
                    next_ref,
                    logical.route.patrol_leg,
                ))
            {
                logical.route = routeAwaitingRebuild(
                    next_ref,
                    logical.route.patrol_leg,
                    logical.position,
                );
                try self.transition(runtime_id, logical, .waiting_at_boundary);
                return;
            }

            try self.completeDestinationArrival(runtime_id, logical, next_ref);
        }

        fn completeDestinationArrival(
            self: *Self,
            runtime_id: engine.RuntimeId,
            logical: *LogicalState,
            reached_ref: navigation.NodeRef,
        ) !void {
            try self.emitEvent(.{ .goal_reached = .{
                .id = try self.runtime.identity(runtime_id),
                .destination = reachedDestination(
                    logical.goal,
                    logical.route.patrol_leg,
                ) orelse return error.NpcGoalReachedInvariantBroken,
            } });
            logical.navigation_status = .arrived;
            logical.navigation_reason = .destination_reached;
            logical.navigation_lineage.arrival_tick = self.runtime.tickIndex();
            logical.physical_edge_exclusion_count = 0;
            logical.physical_block_retry_tick = 0;
            try self.emitNavigationTransition(
                runtime_id,
                logical,
                .destination_arrived,
            );
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
                            reached_ref,
                            logical.goal,
                            logical.route.patrol_leg,
                            null,
                            logical.position,
                        )) {
                            .ready => |value| value,
                            .blocked => {
                                logical.route.needs_rebuild = true;
                                return;
                            },
                            .structurally_unreachable => {
                                logical.route.needs_rebuild = true;
                                return;
                            },
                            .invalid_content => return error.NpcPersistedGoalInvalid,
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
                            .segment_start = switch (self.navigation_access.resolveCatalogNode(
                                reached_ref,
                            )) {
                                .ready => |resolved| resolved.node.position,
                                .invalid_reference => return error.NpcRouteReferenceInvalid,
                            },
                        };
                    }
                    logical.navigation_status = .following;
                    logical.navigation_reason = .destination_reached;
                },
            }
        }

        fn advanceEncounterRouteIfArrived(self: *Self, logical: *LogicalState) !void {
            const route = if (logical.encounter_route) |*value| value else return;
            const next_ref = route.next() orelse return;
            const target = switch (self.navigation_access.resolveNode(next_ref)) {
                .ready => |resolved| resolved,
                .district_inactive => return,
                .invalid_reference => return error.NpcEncounterRouteInvalid,
            };
            const dx = target.node.position[0] - logical.position[0];
            const dz = target.node.position[2] - logical.position[2];
            const distance = @sqrt(dx * dx + dz * dz);
            if (distance > self.config.arrival_distance and
                !passedTarget(route.segment_start, target.node.position, logical.position))
            {
                return;
            }
            route.index += 1;
            route.segment_start = logical.position;
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
            if (desired == .dormant or desired == .waiting_at_boundary) {
                updateNavigationProgress(
                    &logical.navigation_progress,
                    desired,
                    logical.position,
                    logical.position,
                    self.runtime.tickIndex(),
                );
            }
            if (desired == .waiting_at_boundary) {
                logical.navigation_status = .waiting_for_content;
                logical.navigation_reason = .district_inactive;
                try self.emitNavigationTransition(
                    runtime_id,
                    logical,
                    .waiting_entered,
                );
            } else if (previous == .waiting_at_boundary and desired == .active and
                logical.goal != .hold)
            {
                logical.navigation_status = .following;
                logical.navigation_reason = .district_generation_changed;
                try self.emitNavigationTransition(
                    runtime_id,
                    logical,
                    .waiting_resumed,
                );
            }
            try self.emitEvent(.{ .state_changed = .{
                .id = try self.runtime.identity(runtime_id),
                .previous = previous,
                .current = desired,
            } });
        }

        fn commitNavigationPlan(
            self: *Self,
            runtime_id: engine.RuntimeId,
            logical: *LogicalState,
            route: RouteCursor,
            trigger: PlanTrigger,
            result: PlanResult,
            transition_kind: NavigationTransitionKind,
        ) !void {
            logical.route = route;
            logical.navigation_status = navigationStatus(logical.goal, result);
            logical.navigation_reason = navigationReason(result, trigger);
            logical.navigation_lineage.route_revision +|= 1;
            logical.navigation_lineage.planned_tick = self.runtime.tickIndex();
            logical.navigation_lineage.topology_revision =
                self.navigation_access.topologyRevision();
            logical.navigation_lineage.last_trigger = trigger;
            logical.navigation_lineage.last_result = result;
            logical.navigation_lineage.replan_count +|= 1;
            logical.navigation_lineage.arrival_tick = null;
            self.replans +|= 1;
            try self.emitNavigationTransition(runtime_id, logical, transition_kind);
            const result_kind: NavigationTransitionKind = switch (result) {
                .ready => .plan_committed,
                .waiting_for_content => .plan_waiting,
                .blocked_by_traversal => .plan_blocked,
                .structurally_unreachable => .plan_unreachable,
                else => .route_invalidated,
            };
            try self.emitNavigationTransition(runtime_id, logical, result_kind);
        }

        fn emitNavigationTransition(
            self: *Self,
            runtime_id: engine.RuntimeId,
            logical: *const LogicalState,
            kind: NavigationTransitionKind,
        ) !void {
            if (self.navigation_transitions.len == max_navigation_transitions) {
                self.navigation_transition_drops +|= 1;
                return;
            }
            const id = try self.runtime.identity(runtime_id);
            self.navigation_transitions.pushAssumeCapacity(.{
                .tick = self.runtime.tickIndex(),
                .id = id,
                .kind = kind,
                .destination = goalDestination(logical.goal, logical.route.patrol_leg),
                .status = logical.navigation_status,
                .reason = logical.navigation_reason,
                .trigger = logical.navigation_lineage.last_trigger,
                .result = logical.navigation_lineage.last_result,
                .route_revision = logical.navigation_lineage.route_revision,
                .topology_revision = logical.navigation_lineage.topology_revision,
                .route = logical.route.plan,
                .route_index = logical.route.index,
                .position = logical.position,
            });
            self.observeQueueHighWater();
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
            self.navigation_transitions_high_water = @max(
                self.navigation_transitions_high_water,
                @as(u32, @intCast(self.navigation_transitions.len)),
            );
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

test "navigation progress marks a stationary mover without changing gameplay state" {
    var progress = NavigationProgress{ .target = .{ 10, 0, 0 } };
    for (1..potential_stall_ticks + 1) |tick| {
        updateNavigationProgress(
            &progress,
            .active,
            .{ 0, 0, 0 },
            .{ 0, 0, 0 },
            tick,
        );
    }
    try std.testing.expectEqual(
        feature_contract.NavigationProgressState.potentially_stalled,
        progress.state,
    );
    try std.testing.expectEqual(potential_stall_ticks, progress.no_progress_ticks);

    updateNavigationProgress(
        &progress,
        .active,
        .{ 0, 0, 0 },
        .{ navigation_progress_epsilon * 2, 0, 0 },
        potential_stall_ticks + 1,
    );
    try std.testing.expectEqual(feature_contract.NavigationProgressState.moving, progress.state);
    try std.testing.expectEqual(@as(u16, 0), progress.no_progress_ticks);
}

test "navigation progress does not count lateral displacement away from intent" {
    var progress = NavigationProgress{
        .target = .{ 10, 0, 0 },
        .no_progress_ticks = 4,
    };
    updateNavigationProgress(
        &progress,
        .active,
        .{ 0, 0, 0 },
        .{ 0, 0, 1 },
        8,
    );
    try std.testing.expectEqual(@as(u16, 5), progress.no_progress_ticks);
}

fn classifyGoalRoute(goal: Goal, result: GoalRouteBuild) PlanResult {
    return switch (result) {
        .ready => |route| classifyRouteCursor(goal, route),
        .blocked => .blocked_by_traversal,
        .structurally_unreachable => .structurally_unreachable,
        .invalid_content => .invalid_destination,
    };
}

fn classifyRouteCursor(goal: Goal, route: RouteCursor) PlanResult {
    return switch (goal) {
        .hold => .none,
        else => if (route.plan.active_prefix_len < route.plan.len)
            .waiting_for_content
        else
            .ready,
    };
}

fn navigationStatus(goal: Goal, result: PlanResult) NavigationStatus {
    return switch (goal) {
        .hold => .idle,
        else => switch (result) {
            .none => .idle,
            .ready => .following,
            .waiting_for_content => .following,
            .blocked_by_traversal, .deferred_budget => .blocked,
            .structurally_unreachable,
            .invalid_destination,
            .invalid_topology,
            .capacity_exhausted,
            => .structurally_unreachable,
        },
    };
}

fn navigationReason(result: PlanResult, trigger: PlanTrigger) NavigationReason {
    return switch (result) {
        .blocked_by_traversal => if (trigger == .physical_obstruction)
            .physical_obstruction
        else
            .edge_closed,
        .structurally_unreachable => .structurally_disconnected,
        .waiting_for_content => .district_inactive,
        else => switch (trigger) {
            .destination_assigned => .destination_assigned,
            .destination_changed => .destination_changed,
            .restored => .restored,
            .encounter_resumed => .encounter_resumed,
            .external_displacement => .external_displacement,
            .owner_transferred => .owner_transferred,
            .district_generation_changed => .district_generation_changed,
            .topology_changed => .topology_changed,
            .physical_obstruction => .physical_obstruction,
        },
    };
}

fn goalDestination(goal: Goal, leg: PatrolLeg) ?navigation.DestinationId {
    return switch (goal) {
        .hold => null,
        .navigate_to => |destination| destination,
        .patrol_between => |patrol| switch (leg) {
            .toward_first => patrol.first,
            .toward_second => patrol.second,
            .none => patrol.first,
        },
    };
}

fn planWithOne(reference: navigation.NodeRef) RoutePlan {
    var result = RoutePlan{
        .len = 1,
        .active_prefix_len = 1,
    };
    result.nodes[0] = reference;
    return result;
}

fn nodeRefLessThan(
    lhs: navigation.NodeRef,
    rhs: navigation.NodeRef,
) bool {
    if (lhs.coord.x != rhs.coord.x) return lhs.coord.x < rhs.coord.x;
    if (lhs.coord.z != rhs.coord.z) return lhs.coord.z < rhs.coord.z;
    return lhs.index < rhs.index;
}

fn routeBuildFromPlanner(result: navigation_planner.Result) !RouteBuild {
    return switch (result) {
        .ready => |plan| .{ .ready = plan },
        .waiting_for_content => |plan| .{ .ready = plan },
        .blocked_by_traversal => .blocked,
        .structurally_unreachable => .structurally_unreachable,
        .invalid_destination, .invalid_topology => .invalid_content,
        .capacity_exhausted => error.NpcRoutePlannerCapacityExceeded,
    };
}

fn routeAwaitingRebuild(
    anchor: navigation.NodeRef,
    patrol_leg: PatrolLeg,
    position: [3]f32,
) RouteCursor {
    return .{
        .plan = planWithOne(anchor),
        .patrol_leg = patrol_leg,
        .segment_start = position,
        .needs_rebuild = true,
    };
}

fn persistentRouteCursor(navigation_access: anytype, logical: anytype) !NpcRouteCursorV1 {
    const base_current = try currentRouteNode(logical.route);
    if (logical.encounter_route) |encounter_route| {
        if (!navigation.ChunkCoord.eql(base_current.coord, logical.owner)) {
            const anchor = ownerRouteNodeValue(logical.owner, encounter_route) orelse
                return error.NpcEncounterOwnerRouteInvariantBroken;
            const mode: PersistedRouteMode = if (isCompletedGoalEndpoint(
                navigation_access,
                logical.goal,
                anchor,
                logical.route.patrol_leg,
            ))
                .exact_prefix
            else
                .deferred_rebuild;
            return .{
                .current = anchor,
                .patrol_leg = logical.route.patrol_leg,
                .mode = mode,
            };
        }
    }
    const next = logical.route.next();
    const mode: PersistedRouteMode = if (logical.route.needs_rebuild and
        next == null and
        !isCompletedGoalEndpoint(
            navigation_access,
            logical.goal,
            base_current,
            logical.route.patrol_leg,
        ))
        .deferred_rebuild
    else
        .exact_prefix;
    return .{
        .current = base_current,
        .next = next,
        .patrol_leg = logical.route.patrol_leg,
        .mode = mode,
    };
}

fn installAnchoredEncounterLocomotion(
    logical: anytype,
    locomotion: EncounterLocomotion,
) !void {
    const anchor = ownerRouteNodeValue(logical.owner, logical.route) orelse
        return error.NpcEncounterOwnerRouteInvariantBroken;
    logical.encounter_locomotion = locomotion;
    logical.encounter_route = .{
        .plan = planWithOne(anchor),
        .segment_start = logical.position,
    };
}

fn deferEncounterLocomotion(
    logical: anytype,
    locomotion: EncounterLocomotion,
) !void {
    const route = logical.encounter_route orelse logical.route;
    const anchor = ownerRouteNodeValue(logical.owner, route) orelse
        return error.NpcEncounterOwnerRouteInvariantBroken;
    logical.encounter_locomotion = .hold;
    logical.encounter_route = .{
        .plan = planWithOne(anchor),
        .segment_start = logical.position,
    };
    logical.pending_encounter_locomotion = locomotion;
}

fn encounterNextNode(logical: anytype) ?navigation.NodeRef {
    if (logical.encounter_route) |route| return route.next();
    return logical.route.next();
}

fn encounterOwnerRouteNode(self: anytype, logical: anytype) !navigation.NodeRef {
    if (logical.encounter_route) |route| {
        return ownerRouteNodeValue(logical.owner, route) orelse
            error.NpcEncounterOwnerRouteInvariantBroken;
    }
    return switch (self.navigation_access.nearestActiveNode(logical.position)) {
        .ready => |resolved| if (navigation.ChunkCoord.eql(resolved.reference.coord, logical.owner))
            resolved.reference
        else
            error.NpcEncounterOwnerPositionInvariantBroken,
        .district_inactive => error.NpcEncounterOwnerDistrictInactive,
        .unavailable => error.NpcEncounterOwnerNodeUnavailable,
    };
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
    const route = logical.encounter_route orelse logical.route;
    return ownerRouteNodeValue(logical.owner, route) orelse
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
    navigation_access: anytype,
    goal: Goal,
    current: navigation.NodeRef,
    leg: PatrolLeg,
    next: ?navigation.NodeRef,
) bool {
    if (next != null) return false;
    return switch (goal) {
        .patrol_between => |patrol| switch (leg) {
            .toward_first => destinationHasAnchor(
                navigation_access,
                patrol.first,
                current,
            ),
            .toward_second => destinationHasAnchor(
                navigation_access,
                patrol.second,
                current,
            ),
            .none => false,
        },
        else => false,
    };
}

fn isCompletedGoalEndpoint(
    navigation_access: anytype,
    goal: Goal,
    current: navigation.NodeRef,
    leg: PatrolLeg,
) bool {
    return switch (goal) {
        .hold => true,
        .navigate_to => |destination| destinationHasAnchor(
            navigation_access,
            destination,
            current,
        ),
        .patrol_between => |patrol| switch (leg) {
            .toward_first => destinationHasAnchor(
                navigation_access,
                patrol.first,
                current,
            ),
            .toward_second => destinationHasAnchor(
                navigation_access,
                patrol.second,
                current,
            ),
            .none => false,
        },
    };
}

fn destinationHasAnchor(
    navigation_access: anytype,
    id: navigation.DestinationId,
    reference: navigation.NodeRef,
) bool {
    const destination = switch (navigation_access.resolveDestination(id)) {
        .ready => |value| value,
        .invalid_destination => return false,
    };
    for (destination.anchorSlice()) |anchor| {
        if (navigation.NodeRef.eql(anchor, reference)) return true;
    }
    return false;
}

fn reachedDestination(goal: Goal, leg: PatrolLeg) ?navigation.DestinationId {
    return switch (goal) {
        .hold => null,
        .navigate_to => |destination| destination,
        .patrol_between => |patrol| switch (leg) {
            .toward_first => patrol.first,
            .toward_second => patrol.second,
            .none => null,
        },
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

fn poseFor(position: [3]f32, yaw: f32) !engine.physics.Pose {
    return .{
        .position = position,
        .rotation = try engine.transform.rotationFromFacingYaw(yaw),
    };
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

fn lessThanView(_: void, lhs: NpcView, rhs: NpcView) bool {
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
        .navigate_to => |destination| {
            writer.writeU8(2);
            writer.writeU16(destination.value);
        },
        .patrol_between => |patrol| {
            writer.writeU8(3);
            writer.writeU16(patrol.first.value);
            writer.writeU16(patrol.second.value);
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
    writer.writeU8(@intFromEnum(route.mode));
}

fn writeVector3(writer: *engine.contracts.replay.Writer, value: [3]f32) !void {
    for (value) |component| try writer.writeF32(component);
}

fn writeCommand(writer: *engine.contracts.replay.Writer, command: Command) !void {
    switch (command) {
        .spawn => |spawn| {
            writer.writeU8(1);
            writer.writeU64(spawn.request_id);
            try writeVector3(writer, spawn.position);
            try writer.writeF32(spawn.facing_yaw);
            writeNodeRef(writer, spawn.anchor);
            writer.writeBool(spawn.hostile_to_players);
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
            writer.writeU16(reached.destination.value);
        },
    }
}

fn writeNavigationTransition(
    writer: *engine.contracts.replay.Writer,
    transition: NavigationTransition,
) void {
    writer.writeU64(transition.tick);
    writePersistentId(writer, transition.id);
    writer.writeU8(@intFromEnum(transition.kind));
    writer.writeBool(transition.destination != null);
    if (transition.destination) |destination| writer.writeU16(destination.value);
    writer.writeU8(@intFromEnum(transition.status));
    writer.writeU8(@intFromEnum(transition.reason));
    writer.writeU8(@intFromEnum(transition.trigger));
    writer.writeU8(@intFromEnum(transition.result));
    writer.writeU64(transition.route_revision);
    writer.writeU64(transition.topology_revision);
    writer.writeU8(transition.route_index);
    writer.writeU8(transition.route.len);
    writer.writeU8(transition.route.active_prefix_len);
    writer.writeU32(transition.route.total_cost);
    writer.writeU64(transition.route.digest);
    for (transition.route.slice()) |node| writeNodeRef(writer, node);
    writeVector3(writer, transition.position) catch unreachable;
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
        .start_pose_blocked => 7,
        .goal_district_inactive => 8,
        .invalid_goal => 9,
        .unreachable_goal => 10,
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
const west_start_destination = navigation.DestinationId{ .value = 1 };
const west_end_destination = navigation.DestinationId{ .value = 2 };
const east_seam_destination = navigation.DestinationId{ .value = 3 };
const east_end_destination = navigation.DestinationId{ .value = 4 };

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
    topology_revision: u64 = 1,
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

    pub fn nearestActiveNode(
        self: *FakeNavigation,
        position: [3]f32,
    ) navigation.NearestNodeResolution {
        const coord = navigation.ownerForPosition(position) catch return .unavailable;
        if (!self.active(coord)) return .district_inactive;
        var best: ?navigation.ResolvedNode = null;
        var best_distance_squared = std.math.inf(f32);
        for (0..3) |index| {
            const resolved = switch (self.resolveNode(.{
                .coord = coord,
                .index = @intCast(index),
            })) {
                .ready => |value| value,
                .district_inactive => return .district_inactive,
                .invalid_reference => return .unavailable,
            };
            const dx = resolved.node.position[0] - position[0];
            const dz = resolved.node.position[2] - position[2];
            const distance_squared = dx * dx + dz * dz;
            if (best == null or distance_squared < best_distance_squared) {
                best = resolved;
                best_distance_squared = distance_squared;
            }
        }
        return .{ .ready = best orelse return .unavailable };
    }

    pub fn resolveDestination(
        _: *FakeNavigation,
        id: navigation.DestinationId,
    ) navigation.DestinationResolution {
        const anchor = switch (id.value) {
            1 => westNode(0),
            2 => westNode(2),
            3 => eastNode(0),
            4 => eastNode(2),
            else => return .invalid_destination,
        };
        return .{ .ready = .{
            .id = id,
            .position = nodePosition(anchor),
            .arrival_radius = 0.25,
            .anchors = .{ anchor, .{} },
            .anchor_count = 1,
        } };
    }

    pub fn resolveCatalogNode(
        self: *FakeNavigation,
        reference: navigation.NodeRef,
    ) navigation.CatalogNodeResolution {
        if (!validReference(reference)) return .invalid_reference;
        return .{ .ready = .{
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

    pub fn resolveCatalogEdge(
        self: *FakeNavigation,
        source: navigation.NodeRef,
        ordinal: u8,
    ) navigation.CatalogEdgeResolution {
        if (!validReference(source)) return .invalid_reference;
        const target = self.edgeTarget(source, ordinal) orelse
            return .invalid_ordinal;
        return .{ .ready = .{
            .source = source,
            .ordinal = ordinal,
            .edge = .{ .target = target, .cost = 100 },
        } };
    }

    pub fn activeTicketFor(
        self: *FakeNavigation,
        coord: navigation.ChunkCoord,
    ) ?navigation.LoadTicket {
        return if (self.active(coord)) self.ticket(coord) else null;
    }

    pub fn topologyRevision(self: *FakeNavigation) u64 {
        return self.topology_revision;
    }

    pub fn edgeAvailability(
        self: *FakeNavigation,
        source: navigation.NodeRef,
        target: navigation.NodeRef,
    ) navigation.EdgeAvailability {
        const seam = (navigation.NodeRef.eql(source, westNode(2)) and
            navigation.NodeRef.eql(target, eastNode(0))) or
            (navigation.NodeRef.eql(source, eastNode(0)) and
                navigation.NodeRef.eql(target, westNode(2)));
        if (seam and !self.seam_connected) return .closed;
        return .open;
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
        _: *const FakeNavigation,
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
            1 => eastNode(0),
            else => null,
        };
        if (navigation.NodeRef.eql(source, eastNode(0))) return switch (ordinal) {
            0 => westNode(2),
            1 => eastNode(1),
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
    reject_relocation: bool = false,
    freeze_updates: bool = false,
    line_unobstructed: bool = true,

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
        if (self.freeze_updates) {
            slot.state.velocity = .{ 0, 0, 0 };
            self.update_calls += 1;
            return slot.state;
        }
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
        if (self.reject_relocation) return null;
        const slot = try self.slotFor(handle);
        slot.state = groundedState(relocation.position);
        slot.state.velocity = relocation.velocity;
        return slot.state;
    }

    pub fn lineUnobstructed(
        self: *FakeControllers,
        _: [3]f32,
        _: [3]f32,
    ) !bool {
        return self.line_unobstructed;
    }

    fn forceOnlyCharacterPosition(
        self: *FakeControllers,
        position: [3]f32,
    ) !void {
        if (self.live_count != 1) return error.ExpectedOneFakeController;
        for (&self.slots) |*slot| {
            if (!slot.live) continue;
            slot.state.position = position;
            slot.state.velocity = .{ 0, 0, 0 };
            return;
        }
        return error.ExpectedOneFakeController;
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
    try world.feature.enqueue(.{ .spawn = testSpawn(
        request_id,
        westNode(0),
        .{ .patrol_between = .{
            .first = west_start_destination,
            .second = east_end_destination,
        } },
    ) });
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

fn testSpawn(request_id: u64, anchor: navigation.NodeRef, goal: Goal) SpawnNpc {
    return .{
        .request_id = request_id,
        .position = if (validReference(anchor))
            nodePosition(anchor)
        else
            .{ 0, 0, 0 },
        .facing_yaw = 0,
        .anchor = anchor,
        .hostile_to_players = false,
        .goal = goal,
    };
}

fn validNpcRecord(id_local: u64) NpcV1 {
    return .{
        .id = .{ .namespace = test_namespace, .local = id_local },
        .owner = west_coord,
        .hostile_to_players = false,
        .goal = .{ .navigate_to = east_end_destination },
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
        .destination = west_start_destination,
    } });
    const first_event = try npcLogicalDigest(&world);
    _ = world.feature.pollEvent() orelse return error.MissingNpcEvent;
    world.feature.events.pushAssumeCapacity(.{ .goal_reached = .{
        .id = id,
        .destination = west_end_destination,
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
            .destination = .{ .value = @intCast(index % 4 + 1) },
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

    try world.feature.enqueue(.{ .spawn = testSpawn(
        1,
        westNode(0),
        .{ .navigate_to = east_end_destination },
    ) });
    try world.runtime.tick();
    _ = world.feature.pollOutcome() orelse return error.MissingNpcOutcome;
    while (world.feature.pollEvent() != null) {}
    try std.testing.expect(world.feature.navigation_transitions.len != 0);
    const with_diagnostic_transitions = try npcLogicalDigest(&world);
    while (world.feature.pollNavigationTransition() != null) {}
    try std.testing.expectEqual(
        with_diagnostic_transitions,
        try npcLogicalDigest(&world),
    );
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
    try snapshot_validation.validateRecords(&access, &records);
    const json = try std.json.Stringify.valueAlloc(std.testing.allocator, records, .{});
    defer std.testing.allocator.free(json);
    try std.testing.expect(json.len < 128 * 1024);
}

test "cold NPC preflight rejects hostile owner cursor and content records" {
    var access = FakeNavigation{ .west_active = false, .east_active = false };
    const valid = validNpcRecord(1);
    try snapshot_validation.validateRecords(&access, &.{valid});

    var hostile = valid;
    hostile.owner = east_coord;
    try std.testing.expectError(
        error.NpcOwnerPositionMismatch,
        snapshot_validation.validateRecords(&access, &.{hostile}),
    );
    hostile = valid;
    hostile.route.next = null;
    try std.testing.expectError(
        error.NpcNavigateCursorMismatch,
        snapshot_validation.validateRecords(&access, &.{hostile}),
    );
    hostile = valid;
    hostile.route.mode = .deferred_rebuild;
    try std.testing.expectError(
        error.NpcNavigateCursorMismatch,
        snapshot_validation.validateRecords(&access, &.{hostile}),
    );
    hostile = valid;
    hostile.route.next = westNode(2);
    try std.testing.expectError(
        error.NpcPersistedRouteMismatch,
        snapshot_validation.validateRecords(&access, &.{hostile}),
    );
    hostile = valid;
    hostile.route.next = .{ .coord = east_coord, .index = 7 };
    try std.testing.expectError(
        error.NpcPersistedRouteInvalid,
        snapshot_validation.validateRecords(&access, &.{hostile}),
    );
    hostile = valid;
    hostile.route.route_index = 1;
    try std.testing.expectError(
        error.NonCanonicalNpcRouteIndex,
        snapshot_validation.validateRecords(&access, &.{hostile}),
    );
    hostile = valid;
    hostile.facing_yaw = -0.0;
    try std.testing.expectError(
        error.NonCanonicalNpcFacing,
        snapshot_validation.validateRecords(&access, &.{hostile}),
    );
    try std.testing.expectError(
        error.DuplicateNpcPersistentId,
        snapshot_validation.validateRecords(&access, &.{ valid, valid }),
    );
}

test "intentional deferred cursor cold restores and canonicalizes with active content" {
    var world: TestWorld = undefined;
    try world.init();
    defer world.deinit();

    var deferred = validNpcRecord(1);
    deferred.route.next = null;
    deferred.route.mode = .deferred_rebuild;
    try world.feature.restoreRecords(&.{deferred});

    const view_value = try world.feature.view(deferred.id);
    try std.testing.expectEqual(State.active, view_value.state);
    try std.testing.expect(!view_value.route.needs_rebuild);
    try std.testing.expect(view_value.route.next() != null);

    const snapshot = try world.feature.snapshotRecords(std.testing.allocator);
    defer std.testing.allocator.free(snapshot);
    try std.testing.expectEqual(@as(usize, 1), snapshot.len);
    try std.testing.expectEqual(PersistedRouteMode.exact_prefix, snapshot[0].route.mode);
    try std.testing.expect(navigation.NodeRef.eql(westNode(1), snapshot[0].route.next.?));
}

test "cold restored exact prefix waits instead of completing a farther inactive goal" {
    var world: TestWorld = undefined;
    try world.init();
    defer world.deinit();

    world.navigation_access.east_active = false;
    const record = validNpcRecord(1);
    try world.feature.restoreRecords(&.{record});
    var restored = try world.feature.view(record.id);
    try std.testing.expect(!restored.route.needs_rebuild);
    try std.testing.expect(navigation.NodeRef.eql(westNode(1), restored.route.next().?));

    var falsely_completed = false;
    for (0..32) |_| {
        try world.runtime.tick();
        while (world.feature.pollEvent()) |event| switch (event) {
            .goal_reached => falsely_completed = true,
            else => {},
        };
        restored = try world.feature.view(record.id);
        if (restored.state == .waiting_at_boundary) break;
    }
    try std.testing.expect(!falsely_completed);
    try std.testing.expectEqual(State.waiting_at_boundary, restored.state);
    try std.testing.expect(!restored.route.needs_rebuild);
    try std.testing.expectEqual(
        feature_contract.NavigationStatus.waiting_for_content,
        restored.navigation_status,
    );
    try std.testing.expect(navigation.NodeRef.eql(
        eastNode(0),
        restored.route.next().?,
    ));

    world.navigation_access.east_active = true;
    world.navigation_access.east_generation += 1;
    try world.runtime.tick();
    restored = try world.feature.view(record.id);
    try std.testing.expectEqual(State.active, restored.state);
    try std.testing.expect(!restored.route.needs_rebuild);
    try std.testing.expect(restored.route.next() != null);
}

test "cold restored patrol prefix waits without flipping its semantic leg" {
    var world: TestWorld = undefined;
    try world.init();
    defer world.deinit();

    world.navigation_access.east_active = false;
    const record = patrolRecord(
        1,
        westNode(0),
        westNode(1),
        .toward_second,
        nodePosition(westNode(0)),
    );
    try world.feature.restoreRecords(&.{record});
    var restored = try world.feature.view(record.id);
    var falsely_completed = false;
    for (0..32) |_| {
        try world.runtime.tick();
        while (world.feature.pollEvent()) |event| switch (event) {
            .goal_reached => falsely_completed = true,
            else => {},
        };
        restored = try world.feature.view(record.id);
        if (restored.state == .waiting_at_boundary) break;
    }
    try std.testing.expect(!falsely_completed);
    try std.testing.expectEqual(State.waiting_at_boundary, restored.state);
    try std.testing.expect(!restored.route.needs_rebuild);
    try std.testing.expectEqual(PatrolLeg.toward_second, restored.route.patrol_leg);
    try std.testing.expect(navigation.NodeRef.eql(
        eastNode(0),
        restored.route.next().?,
    ));

    world.navigation_access.east_active = true;
    world.navigation_access.east_generation += 1;
    try world.runtime.tick();
    restored = try world.feature.view(record.id);
    try std.testing.expectEqual(State.active, restored.state);
    try std.testing.expect(!restored.route.needs_rebuild);
    try std.testing.expectEqual(PatrolLeg.toward_second, restored.route.patrol_leg);
    try std.testing.expect(restored.route.next() != null);
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

test "externally displaced NPC adopts positional owner and rebases hold intent" {
    var world: TestWorld = undefined;
    try world.init();
    defer world.deinit();

    try world.feature.enqueue(.{ .spawn = testSpawn(1, westNode(2), .hold) });
    try world.runtime.tick();
    const spawned = switch (world.feature.pollOutcome() orelse
        return error.MissingNpcOutcome) {
        .spawned => |value| value,
        else => return error.UnexpectedNpcOutcome,
    };
    const create_calls = world.controllers.create_calls;

    // Model a vehicle or other physical body pushing the CharacterVirtual in
    // the opposite direction from its semantic intent. Position owns spatial
    // authority; a hold route is not a collision barrier.
    try world.controllers.forceOnlyCharacterPosition(.{ 8.1, 0, 3 });
    try world.runtime.tick();

    const displaced = try world.feature.view(spawned.id);
    try std.testing.expect(navigation.ChunkCoord.eql(east_coord, displaced.owner));
    try std.testing.expect(navigation.ChunkCoord.eql(
        east_coord,
        (try currentRouteNode(displaced.route)).coord,
    ));
    try std.testing.expectEqual(create_calls, world.controllers.create_calls);
    try std.testing.expectEqual(@as(usize, 1), world.controllers.live_count);
    try std.testing.expect(world.runtime.firstFault() == null);

    const transferred = world.feature.pollEvent() orelse
        return error.NpcOwnerTransferEventMissing;
    switch (transferred) {
        .owner_transferred => |value| {
            try std.testing.expectEqual(spawned.id, value.id);
            try std.testing.expect(navigation.ChunkCoord.eql(west_coord, value.previous));
            try std.testing.expect(navigation.ChunkCoord.eql(east_coord, value.current));
        },
        else => return error.UnexpectedNpcEvent,
    }
    try std.testing.expect(world.feature.pollEvent() == null);
}

test "external displacement into unavailable navigation recovers locally" {
    for ([_]struct {
        position: [3]f32,
        deactivate_east: bool,
    }{
        .{ .position = .{ 8.1, 0, 3 }, .deactivate_east = true },
        .{ .position = .{ 7, 0, 8.1 }, .deactivate_east = false },
    }) |scenario| {
        var world: TestWorld = undefined;
        try world.init();
        defer world.deinit();

        try world.feature.enqueue(.{ .spawn = testSpawn(1, westNode(2), .hold) });
        try world.runtime.tick();
        const spawned = switch (world.feature.pollOutcome() orelse
            return error.MissingNpcOutcome) {
            .spawned => |value| value,
            else => return error.UnexpectedNpcOutcome,
        };
        if (scenario.deactivate_east) world.navigation_access.east_active = false;

        try world.controllers.forceOnlyCharacterPosition(scenario.position);
        try world.runtime.tick();

        const recovered = try world.feature.view(spawned.id);
        const physical_owner = try navigation.ownerForPosition(scenario.position);
        try std.testing.expect(navigation.ChunkCoord.eql(physical_owner, recovered.owner));
        try std.testing.expectEqualDeep(scenario.position, recovered.position);
        try std.testing.expectEqual(State.dormant, recovered.state);
        try std.testing.expect(!recovered.controller_present);
        try std.testing.expectEqual(@as(usize, 0), world.controllers.live_count);
        try std.testing.expect(world.runtime.firstFault() == null);
    }
}

test "external displacement without a route recovers locally" {
    var world: TestWorld = undefined;
    try world.init();
    defer world.deinit();
    world.navigation_access.seam_connected = false;

    try world.feature.enqueue(.{ .spawn = testSpawn(
        1,
        westNode(2),
        .{ .navigate_to = west_start_destination },
    ) });
    try world.runtime.tick();
    const spawned = switch (world.feature.pollOutcome() orelse
        return error.MissingNpcOutcome) {
        .spawned => |value| value,
        else => return error.UnexpectedNpcOutcome,
    };
    // Runtime traversal is closed, but the displaced pose remains physical
    // truth and the semantic destination survives as recoverable blocked
    // intent.
    try world.controllers.forceOnlyCharacterPosition(.{ 9.1, 0, 3 });
    try world.runtime.tick();
    const recovered = try world.feature.view(spawned.id);
    try std.testing.expect(navigation.ChunkCoord.eql(east_coord, recovered.owner));
    try std.testing.expect(recovered.position[0] <= 9.1);
    try std.testing.expect(recovered.position[0] > 8.1);
    try std.testing.expectEqual(@as(f32, 0), recovered.position[1]);
    try std.testing.expectEqual(@as(f32, 3), recovered.position[2]);
    try std.testing.expectEqualDeep(
        Goal{ .navigate_to = west_start_destination },
        recovered.goal,
    );
    try std.testing.expectEqual(State.active, recovered.state);
    try std.testing.expect(recovered.controller_present);
    try std.testing.expectEqual(NavigationStatus.blocked, recovered.navigation_status);
    try std.testing.expectEqual(@as(usize, 1), world.controllers.live_count);
    try std.testing.expect(world.runtime.firstFault() == null);
}

test "blocked displacement recovery suspends and reconstructs locally" {
    var world: TestWorld = undefined;
    try world.init();
    defer world.deinit();

    try world.feature.enqueue(.{ .spawn = testSpawn(1, westNode(2), .hold) });
    try world.runtime.tick();
    const spawned = switch (world.feature.pollOutcome() orelse
        return error.MissingNpcOutcome) {
        .spawned => |value| value,
        else => return error.UnexpectedNpcOutcome,
    };

    world.navigation_access.east_active = false;
    world.controllers.reject_relocation = true;
    try world.controllers.forceOnlyCharacterPosition(.{ 8.1, 0, 3 });
    try world.runtime.tick();

    var recovered = try world.feature.view(spawned.id);
    try std.testing.expectEqual(State.dormant, recovered.state);
    try std.testing.expect(!recovered.controller_present);
    try std.testing.expect(navigation.ChunkCoord.eql(east_coord, recovered.owner));
    try std.testing.expectEqualDeep([3]f32{ 8.1, 0, 3 }, recovered.position);
    try std.testing.expectEqual(@as(usize, 0), world.controllers.live_count);
    try std.testing.expect(world.runtime.firstFault() == null);

    // Reconciliation owns reconstruction on the following tick. The failure
    // remains scoped to this NPC instead of poisoning the authority cycle.
    world.controllers.reject_relocation = false;
    world.navigation_access.east_active = true;
    world.navigation_access.east_generation += 1;
    try world.runtime.tick();
    recovered = try world.feature.view(spawned.id);
    try std.testing.expect(recovered.state != .dormant);
    try std.testing.expect(recovered.controller_present);
    try std.testing.expect(navigation.ChunkCoord.eql(east_coord, recovered.owner));
    try std.testing.expectEqual(@as(usize, 1), world.controllers.live_count);
    try std.testing.expect(world.runtime.firstFault() == null);
}

test "encounter pursuit crosses ownership and resumes an owner-aligned route" {
    var world: TestWorld = undefined;
    try world.init();
    defer world.deinit();

    const id = try spawnPatrol(&world, 1);
    var encounter = world.feature.encounterAccess();
    try encounter.apply(id, .{ .pursue_position = nodePosition(eastNode(2)) });

    var crossed = false;
    for (0..80) |_| {
        try world.runtime.tick();
        const view_value = try world.feature.view(id);
        if (navigation.ChunkCoord.eql(view_value.owner, east_coord)) {
            crossed = true;
            break;
        }
    }
    try std.testing.expect(crossed);

    try encounter.apply(id, .{ .face_and_hold = nodePosition(eastNode(2)) });
    try world.runtime.tick();
    try std.testing.expect(navigation.ChunkCoord.eql(
        east_coord,
        (try world.feature.view(id)).owner,
    ));

    try encounter.apply(id, .resume_route);
    const rebased = try world.feature.view(id);
    try std.testing.expect(navigation.ChunkCoord.eql(rebased.owner, east_coord));
    try std.testing.expect(navigation.ChunkCoord.eql(
        (try currentRouteNode(rebased.route)).coord,
        east_coord,
    ));
    try world.runtime.tick();
    const resumed = try world.feature.view(id);
    try std.testing.expect(ownerRouteNodeValue(resumed.owner, resumed.route) != null);
}

test "encounter resume waits for an inactive patrol destination then rebuilds" {
    var world: TestWorld = undefined;
    try world.init();
    defer world.deinit();

    const id = try spawnPatrol(&world, 1);
    const admitted = try world.feature.view(id);
    try std.testing.expectEqual(PatrolLeg.toward_second, admitted.route.patrol_leg);

    var encounter = world.feature.encounterAccess();
    try encounter.apply(id, .{ .face_and_hold = nodePosition(westNode(1)) });
    world.navigation_access.east_active = false;
    try encounter.apply(id, .resume_route);

    var deferred = try world.feature.view(id);
    try std.testing.expect(deferred.encounter_locomotion == null);
    try std.testing.expect(navigation.NodeRef.eql(westNode(1), deferred.route.next().?));
    try std.testing.expectEqual(PatrolLeg.toward_second, deferred.route.patrol_leg);
    try std.testing.expect(!deferred.route.needs_rebuild);
    try std.testing.expect(navigation.ChunkCoord.eql(
        deferred.owner,
        (try currentRouteNode(deferred.route)).coord,
    ));

    try world.runtime.tick();
    deferred = try world.feature.view(id);
    try std.testing.expectEqual(State.active, deferred.state);
    try std.testing.expect(!deferred.route.needs_rebuild);
    const deferred_snapshot = try world.feature.snapshotRecords(std.testing.allocator);
    defer std.testing.allocator.free(deferred_snapshot);
    try std.testing.expectEqual(@as(usize, 1), deferred_snapshot.len);
    try std.testing.expect(deferred_snapshot[0].route.next != null);
    try std.testing.expectEqual(
        PersistedRouteMode.exact_prefix,
        deferred_snapshot[0].route.mode,
    );

    world.navigation_access.east_active = true;
    world.navigation_access.east_generation += 1;
    try world.runtime.tick();
    const rebuilt = try world.feature.view(id);
    try std.testing.expectEqual(State.active, rebuilt.state);
    try std.testing.expect(!rebuilt.route.needs_rebuild);
    try std.testing.expect(rebuilt.route.next() != null);
    try std.testing.expectEqual(PatrolLeg.toward_second, rebuilt.route.patrol_leg);
}

test "encounter resume survives dormant owner and rebuilds after owner reload" {
    var world: TestWorld = undefined;
    try world.init();
    defer world.deinit();

    const id = try spawnPatrol(&world, 1);
    var encounter = world.feature.encounterAccess();
    try encounter.apply(id, .{ .face_and_hold = nodePosition(westNode(1)) });

    world.navigation_access.west_active = false;
    try world.runtime.tick();
    var dormant = try world.feature.view(id);
    try std.testing.expectEqual(State.dormant, dormant.state);
    try std.testing.expect(!dormant.controller_present);

    try encounter.apply(id, .resume_route);
    dormant = try world.feature.view(id);
    try std.testing.expect(dormant.encounter_locomotion == null);
    try std.testing.expect(!dormant.route.needs_rebuild);
    try std.testing.expectEqual(PatrolLeg.toward_second, dormant.route.patrol_leg);
    try std.testing.expect(navigation.ChunkCoord.eql(
        dormant.owner,
        (try currentRouteNode(dormant.route)).coord,
    ));
    try world.runtime.tick();
    try std.testing.expectEqual(State.dormant, (try world.feature.view(id)).state);
    const dormant_snapshot = try world.feature.snapshotRecords(std.testing.allocator);
    defer std.testing.allocator.free(dormant_snapshot);
    try std.testing.expectEqual(@as(usize, 1), dormant_snapshot.len);
    try std.testing.expect(dormant_snapshot[0].route.next != null);
    try std.testing.expectEqual(
        PersistedRouteMode.exact_prefix,
        dormant_snapshot[0].route.mode,
    );

    world.navigation_access.west_active = true;
    world.navigation_access.west_generation += 1;
    try world.runtime.tick();
    const rebuilt = try world.feature.view(id);
    try std.testing.expectEqual(State.active, rebuilt.state);
    try std.testing.expect(rebuilt.controller_present);
    try std.testing.expect(!rebuilt.route.needs_rebuild);
    try std.testing.expect(rebuilt.route.next() != null);
    try std.testing.expectEqual(PatrolLeg.toward_second, rebuilt.route.patrol_leg);
}

test "restored pursuit holds for an inactive target then installs on reload" {
    var world: TestWorld = undefined;
    try world.init();
    defer world.deinit();

    world.navigation_access.east_active = false;
    const record = validNpcRecord(1);
    try world.feature.restoreRecords(&.{record});
    var encounter = world.feature.encounterAccess();
    try encounter.restore(record.id, .{ .pursue_position = nodePosition(eastNode(2)) });

    var deferred = try world.feature.view(record.id);
    try std.testing.expect(std.meta.activeTag(deferred.encounter_locomotion.?) == .hold);
    try world.runtime.tick();
    deferred = try world.feature.view(record.id);
    try std.testing.expectEqual(State.active, deferred.state);
    try std.testing.expect(std.meta.activeTag(deferred.encounter_locomotion.?) == .hold);

    world.navigation_access.east_active = true;
    world.navigation_access.east_generation += 1;
    try world.runtime.tick();
    const resumed = try world.feature.view(record.id);
    try std.testing.expectEqual(State.active, resumed.state);
    try std.testing.expect(
        std.meta.activeTag(resumed.encounter_locomotion.?) == .pursue_position,
    );
}

test "restored pursuit holds through dormant owner then installs on reload" {
    var world: TestWorld = undefined;
    try world.init();
    defer world.deinit();

    world.navigation_access.west_active = false;
    const record = validNpcRecord(1);
    try world.feature.restoreRecords(&.{record});
    var encounter = world.feature.encounterAccess();
    try encounter.restore(record.id, .{ .pursue_position = nodePosition(eastNode(2)) });

    var dormant = try world.feature.view(record.id);
    try std.testing.expectEqual(State.dormant, dormant.state);
    try std.testing.expect(std.meta.activeTag(dormant.encounter_locomotion.?) == .hold);
    try world.runtime.tick();
    try std.testing.expectEqual(State.dormant, (try world.feature.view(record.id)).state);

    world.navigation_access.west_active = true;
    world.navigation_access.west_generation += 1;
    try world.runtime.tick();
    dormant = try world.feature.view(record.id);
    try std.testing.expectEqual(State.active, dormant.state);
    try std.testing.expect(dormant.controller_present);
    try std.testing.expect(
        std.meta.activeTag(dormant.encounter_locomotion.?) == .pursue_position,
    );
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
        .hostile_to_players = false,
        .goal = .{ .patrol_between = .{
            .first = west_start_destination,
            .second = east_end_destination,
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
    const draws = try world.feature.extract(1);
    try std.testing.expectEqual(@as(usize, 1), draws.len);
    const expected_rotation = try engine.transform.rotationFromFacingYaw(record.facing_yaw);
    for (draws[0].pose.rotation, expected_rotation) |actual, expected| {
        try std.testing.expectApproxEqAbs(expected, actual, 0.0001);
    }
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
    try std.testing.expectEqual(PatrolLeg.toward_second, value.route.patrol_leg);
    try std.testing.expect(value.route.next() != null);

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

test "NPC commands accept waiting and blocked intent but reject invalid stale and capacity" {
    var world: TestWorld = undefined;
    try world.init();
    defer world.deinit();

    try world.feature.enqueue(.{ .spawn = testSpawn(
        1,
        .{ .coord = west_coord, .index = 7 },
        .hold,
    ) });
    try world.runtime.tick();
    try expectRejected(world.feature.pollOutcome(), .spawn, .invalid_start_node);

    world.navigation_access.east_active = false;
    try world.feature.enqueue(.{ .spawn = testSpawn(
        2,
        westNode(0),
        .{ .navigate_to = east_end_destination },
    ) });
    try world.runtime.tick();
    const waiting_id = switch (world.feature.pollOutcome() orelse
        return error.MissingNpcOutcome) {
        .spawned => |value| value.id,
        else => return error.ExpectedNpcSpawn,
    };
    try std.testing.expectEqual(
        PlanResult.waiting_for_content,
        (try world.feature.view(waiting_id)).navigation_lineage.last_result,
    );

    world.navigation_access.east_active = true;
    world.navigation_access.seam_connected = false;
    try world.feature.enqueue(.{ .spawn = testSpawn(
        3,
        westNode(0),
        .{ .navigate_to = east_end_destination },
    ) });
    try world.runtime.tick();
    const blocked_id = switch (world.feature.pollOutcome() orelse
        return error.MissingNpcOutcome) {
        .spawned => |value| value.id,
        else => return error.ExpectedNpcSpawn,
    };
    try std.testing.expectEqual(
        PlanResult.blocked_by_traversal,
        (try world.feature.view(blocked_id)).navigation_lineage.last_result,
    );
    world.navigation_access.seam_connected = true;

    try world.feature.enqueue(.{ .spawn = testSpawn(
        4,
        westNode(0),
        .{ .navigate_to = .{ .value = 99 } },
    ) });
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

    world.controllers.max_live = world.controllers.live_count;
    try world.feature.enqueue(.{ .spawn = testSpawn(6, westNode(0), .hold) });
    try world.runtime.tick();
    try expectRejected(world.feature.pollOutcome(), .spawn, .controller_capacity_reached);
    try std.testing.expectEqual(@as(usize, 2), world.feature.count());
    try std.testing.expectEqual(@as(usize, 2), world.runtime.entityCount());
}

test "topology revision replans retained destination through blocked and resumed states" {
    var world: TestWorld = undefined;
    try world.init();
    defer world.deinit();

    try world.feature.enqueue(.{ .spawn = testSpawn(
        1,
        westNode(0),
        .{ .navigate_to = east_end_destination },
    ) });
    try world.runtime.tick();
    const id = switch (world.feature.pollOutcome() orelse
        return error.MissingNpcOutcome) {
        .spawned => |value| value.id,
        else => return error.ExpectedNpcSpawn,
    };
    while (world.feature.pollNavigationTransition() != null) {}
    const initial = try world.feature.view(id);

    world.navigation_access.seam_connected = false;
    world.navigation_access.topology_revision += 1;
    try world.runtime.tick();
    const blocked = try world.feature.view(id);
    try std.testing.expectEqual(NavigationStatus.blocked, blocked.navigation_status);
    try std.testing.expectEqual(
        PlanResult.blocked_by_traversal,
        blocked.navigation_lineage.last_result,
    );
    try std.testing.expect(blocked.navigation_lineage.route_revision >
        initial.navigation_lineage.route_revision);
    try std.testing.expectEqualDeep(initial.goal, blocked.goal);

    world.navigation_access.seam_connected = true;
    world.navigation_access.topology_revision += 1;
    try world.runtime.tick();
    const resumed = try world.feature.view(id);
    try std.testing.expectEqual(NavigationStatus.following, resumed.navigation_status);
    try std.testing.expectEqual(PlanResult.ready, resumed.navigation_lineage.last_result);
    try std.testing.expect(resumed.route.next() != null);
}

test "topology replan wave is stable-ID ordered and bounded to eight per tick" {
    var world: TestWorld = undefined;
    try world.init();
    defer world.deinit();

    for (0..max_npcs) |index| {
        try world.feature.enqueue(.{ .spawn = testSpawn(
            index + 1,
            westNode(0),
            .{ .navigate_to = east_end_destination },
        ) });
    }
    try world.runtime.tick();
    var ids: [max_npcs]engine.PersistentId = undefined;
    for (&ids) |*id| {
        id.* = switch (world.feature.pollOutcome() orelse
            return error.MissingNpcOutcome) {
            .spawned => |value| value.id,
            else => return error.ExpectedNpcSpawn,
        };
    }
    while (world.feature.pollNavigationTransition() != null) {}

    world.navigation_access.seam_connected = false;
    world.navigation_access.topology_revision += 1;
    try world.runtime.tick();
    var blocked_count: usize = 0;
    var following_count: usize = 0;
    for (ids) |id| switch ((try world.feature.view(id)).navigation_status) {
        .blocked => blocked_count += 1,
        .following => following_count += 1,
        else => return error.UnexpectedNavigationStatus,
    };
    try std.testing.expectEqual(@as(usize, 8), blocked_count);
    try std.testing.expectEqual(max_npcs - 8, following_count);
    try std.testing.expectEqual(@as(u64, max_npcs - 8), world.feature.diagnostics().deferred_replans);
    while (world.feature.pollNavigationTransition() != null) {}

    for (0..7) |_| {
        try world.runtime.tick();
        while (world.feature.pollNavigationTransition() != null) {}
    }
    for (ids) |id| {
        try std.testing.expectEqual(
            NavigationStatus.blocked,
            (try world.feature.view(id)).navigation_status,
        );
    }
    try std.testing.expectEqual(@as(u64, 224), world.feature.diagnostics().deferred_replans);
}

test "confirmed physical blockage excludes the segment and retries after clearance" {
    var world: TestWorld = undefined;
    try world.init();
    defer world.deinit();
    world.controllers.freeze_updates = true;
    world.controllers.line_unobstructed = false;

    try world.feature.enqueue(.{ .spawn = testSpawn(
        1,
        westNode(0),
        .{ .navigate_to = east_end_destination },
    ) });
    try world.runtime.tick();
    const id = switch (world.feature.pollOutcome() orelse
        return error.MissingNpcOutcome) {
        .spawned => |value| value.id,
        else => return error.ExpectedNpcSpawn,
    };
    while (world.feature.pollNavigationTransition() != null) {}

    for (0..potential_stall_ticks + 1) |_| try world.runtime.tick();
    const blocked = try world.feature.view(id);
    try std.testing.expectEqual(NavigationStatus.blocked, blocked.navigation_status);
    try std.testing.expectEqual(
        NavigationReason.physical_obstruction,
        blocked.navigation_reason,
    );
    try std.testing.expectEqual(@as(u8, 1), blocked.physical_edge_exclusion_count);
    try std.testing.expect(
        blocked.physical_block_retry_tick > world.runtime.tickIndex(),
    );
    var saw_confirmed = false;
    while (world.feature.pollNavigationTransition()) |transition| {
        saw_confirmed = saw_confirmed or transition.kind == .block_confirmed;
    }
    try std.testing.expect(saw_confirmed);

    world.controllers.line_unobstructed = true;
    world.controllers.freeze_updates = false;
    while (world.runtime.tickIndex() <= blocked.physical_block_retry_tick) {
        try world.runtime.tick();
    }
    const resumed = try world.feature.view(id);
    try std.testing.expectEqual(NavigationStatus.following, resumed.navigation_status);
    try std.testing.expectEqual(@as(u8, 0), resumed.physical_edge_exclusion_count);
    try std.testing.expect(resumed.route.next() != null);
    var saw_cleared = false;
    while (world.feature.pollNavigationTransition()) |transition| {
        saw_cleared = saw_cleared or transition.kind == .block_cleared;
    }
    try std.testing.expect(saw_cleared);
}

test "rejected set goal is atomic across view digest entities and controller ownership" {
    const spawn = Command{ .spawn = testSpawn(1, westNode(0), .hold) };
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
            .goal = .{ .navigate_to = .{ .value = 99 } },
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
        try world.feature.enqueue(.{ .spawn = testSpawn(
            index + 1,
            westNode(0),
            .hold,
        ) });
    }
    try std.testing.expectError(
        error.NpcCommandQueueFull,
        world.feature.enqueue(.{ .spawn = testSpawn(
            max_pending_commands + 1,
            westNode(0),
            .hold,
        ) }),
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

    try world.feature.enqueue(.{ .spawn = testSpawn(2_000, westNode(0), .hold) });
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
            try poseFor(nodePosition(westNode(0)), 0),
            try poseFor(view_value.position, view_value.facing_yaw),
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
            .first = west_start_destination,
            .second = east_end_destination,
        } },
        .goal_reached => .{ .navigate_to = west_end_destination },
    };
    for (0..max_npcs) |index| {
        try world.feature.enqueue(.{ .spawn = testSpawn(index + 1, westNode(0), goal) });
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
            for (0..512) |_| {
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
            const recovery_goal: Goal = .{ .navigate_to = west_start_destination };
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
            const recovery_goal: Goal = .{ .navigate_to = west_end_destination };
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
            for (0..512) |_| {
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
                    try std.testing.expectEqual(
                        west_end_destination,
                        value.destination,
                    );
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
    try world.feature.enqueue(.{ .spawn = testSpawn(2_000, westNode(0), .hold) });
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
