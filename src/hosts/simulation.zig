//! Sandbox composition shared by the visual and headless hosts.

const std = @import("std");
const engine = @import("incinerator_engine");
const crate_implementation = @import("crate_feature");
const crates = @import("crate_contract");
const character_implementation = @import("character_feature");
const characters = @import("character_contract");
const vehicle_implementation = @import("vehicle_feature");
const vehicles = @import("vehicle_contract");
const district_implementation = @import("district_feature");
const districts = @import("district_feature_contract");
const interaction_implementation = @import("interaction_feature");
const interactions = @import("interaction_feature_contract");
const npc_implementation = @import("npc_feature");
const npcs = @import("npc_contract");
const vitals_implementation = @import("vitals_feature");
const vitals_contract = @import("vitals_contract");
const npc_encounter_implementation = @import("npc_encounter_feature");
const npc_encounter_contract = @import("npc_encounter_contract");
const npc_replacement = @import("sandbox_npc_replacement");
const npc_replacement_contract = @import("sandbox_npc_replacement_contract");
const district_contract = @import("district_contract");
const sandbox_district_recipe = @import("sandbox_district_recipe");
const district_worker_contract = @import("district_worker_contract");
const district_replay_loader = @import("district_replay_loader");
const jolt = @import("jolt_physics");
const sandbox_replay = @import("sandbox_replay");
const simulation_snapshot = @import("simulation_snapshot");
const simulation_diagnostics = @import("simulation_diagnostics");
const sandbox_diagnostics = @import("sandbox_diagnostics_contract");
const sandbox_host_contracts = @import("sandbox_host_contracts");

const Command = crates.Command;
const Outcome = crates.Outcome;
const CrateView = crates.CrateView;
const CrateDraw = crates.CrateDraw;
const PersistentId = engine.PersistentId;

const CharacterCommand = characters.Command;
const CharacterOutcome = characters.Outcome;
const CharacterEvent = characters.Event;
const CharacterView = characters.CharacterView;
const CharacterDraw = characters.CharacterDraw;
const CharacterConfig = characters.Config;
const CharacterConfigV1 = characters.CharacterConfigV1;
const CrateV1 = crates.CrateV1;
const CharacterV1 = characters.CharacterV1;
const VehicleCommand = vehicles.Command;
const VehicleOutcome = vehicles.Outcome;
const VehicleEvent = vehicles.Event;
const VehicleView = vehicles.VehicleView;
const VehicleDraw = vehicles.VehicleDraw;
const VehicleConfigV1 = vehicles.VehicleConfigV1;
const VehicleV1 = vehicles.VehicleV1;
const DistrictCommand = districts.Command;
const DistrictOutcome = districts.Outcome;
const DistrictEvent = districts.Event;
const DistrictDraw = districts.DistrictDraw;
const DistrictAssets = districts.Assets;
const DistrictStateTag = districts.StateTag;
const DistrictV1 = districts.DistrictV1;
const InteractionCommand = interactions.Command;
const InteractionOutcome = interactions.Outcome;
const CarryableView = interactions.CarryableView;
const CarryableDraw = interactions.CarryableDraw;
const InteractionConfigV1 = interactions.InteractionConfigV1;
const InteractionV1 = interactions.InteractionV1;
const NpcCommand = npcs.Command;
const NpcOutcome = npcs.Outcome;
const NpcEvent = npcs.Event;
const NpcView = npcs.NpcView;
const NpcDraw = npcs.NpcDraw;
const NpcConfigV1 = npcs.NpcConfigV1;
const NpcV1 = npcs.NpcV1;
const NpcState = npcs.State;
const VitalsCommand = vitals_contract.Command;
const VitalsOutcome = vitals_contract.Outcome;
const VitalsEvent = vitals_contract.Event;
const VitalsView = vitals_contract.View;
const NpcEncounterCue = npc_encounter_contract.Cue;
const NpcEncounterView = npc_encounter_contract.View;
const NpcEncounterDiagnostics = npc_encounter_contract.Diagnostics;
const NpcEncounterTransition = npc_encounter_contract.Transition;
const NpcReplacementOutcome = npc_replacement_contract.Outcome;
const NpcReplacementDiagnostics = npc_replacement_contract.Diagnostics;
const NavigationNodeRef = npcs.NodeRef;
const navigation_west_coord = sandbox_district_recipe.navigation_west_coord;
const navigation_east_coord = sandbox_district_recipe.navigation_east_coord;
const ChunkCoord = district_contract.ChunkCoord;
const LoadTicket = district_contract.LoadTicket;
const PhysicsDebugConfig = engine.physics_debug.Config;
const PhysicsDebugBatch = engine.physics_debug.Batch;

const Diagnostics = sandbox_diagnostics.Diagnostics;

/// Process-lifecycle boundary for an operational host. Logical state may be
/// serializable while process-local completions or worker ownership are still
/// live; the M3 host therefore requires this stronger quiescence boundary
/// before final shutdown.
pub const OperationalQuiescenceReason = enum {
    runtime_faulted,
    commands_pending,
    outputs_pending,
    district_transition,
    district_outcome_reservations,
    district_worker_busy,
};

/// Caller-owned bounded storage for allocation-free logical digest extraction.
/// One slice is reused serially by the runtime and every feature because each
/// writer completes before the next category begins.
pub const DigestScratch = struct {
    allocator: std.mem.Allocator,
    identities: []engine.PersistentId,

    pub fn init(allocator: std.mem.Allocator, identity_capacity: usize) !DigestScratch {
        if (identity_capacity == 0) return error.InvalidDigestScratchCapacity;
        return .{
            .allocator = allocator,
            .identities = try allocator.alloc(engine.PersistentId, identity_capacity),
        };
    }

    pub fn deinit(self: *DigestScratch) void {
        self.allocator.free(self.identities);
        self.* = undefined;
    }
};

pub const CaptureBoundaryReason = enum {
    already_recording,
    ticks_completed,
    commands_pending,
    entities_present,
    identity_cursor_advanced,
    district_not_quiescent,
    worker_not_idle,
    outputs_pending,
    unexpected_physics_bodies,
    runtime_faulted,
};

pub const CaptureAdmission = union(enum) {
    admitted,
    rejected: CaptureBoundaryReason,
};

pub const ReplayResult = union(enum) {
    matched: struct { completed_ticks: u64 },
    divergent: sandbox_replay.Divergence,
};

/// Consumable public output lanes drained only after their authoritative
/// state has participated in the replay digest. Diagnostic transition rings
/// and immutable views are retained and are therefore intentionally absent.
pub const ReplayBoundaryDrain = struct {
    crate_outcomes: u32 = 0,
    character_outcomes: u32 = 0,
    character_events: u32 = 0,
    vehicle_outcomes: u32 = 0,
    vehicle_events: u32 = 0,
    district_outcomes: u32 = 0,
    district_events: u32 = 0,
    interaction_outcomes: u32 = 0,
    npc_outcomes: u32 = 0,
    npc_events: u32 = 0,
    vitals_outcomes: u32 = 0,
    vitals_events: u32 = 0,
    npc_encounter_cues: u32 = 0,
    npc_replacement_outcomes: u32 = 0,

    pub fn total(self: ReplayBoundaryDrain) u32 {
        return self.crate_outcomes +| self.character_outcomes +|
            self.character_events +| self.vehicle_outcomes +|
            self.vehicle_events +| self.district_outcomes +|
            self.district_events +| self.interaction_outcomes +|
            self.npc_outcomes +| self.npc_events +| self.vitals_outcomes +|
            self.vitals_events +| self.npc_encounter_cues +|
            self.npc_replacement_outcomes;
    }
};

const ActiveCapture = struct {
    recorder: sandbox_replay.Recorder,
    scratch: DigestScratch,

    fn deinit(self: *ActiveCapture) void {
        self.scratch.deinit();
        self.recorder.deinit();
        self.* = undefined;
    }
};

const CrateFeature = crate_implementation.Feature(jolt.CrateBodies);
const CharacterFeature = character_implementation.Feature(jolt.CharacterControllers);
const VehicleFeature = vehicle_implementation.Feature(
    jolt.Vehicles,
    CharacterFeature.DriverAccess,
);
const DistrictFeature = district_implementation.Feature(
    jolt.DistrictBodies,
    district_replay_loader.Loader,
    sandbox_district_recipe,
);
const InteractionFeature = interaction_implementation.Feature(
    jolt.CrateBodies,
    CharacterFeature.CarrierAccess,
);
const NpcFeature = npc_implementation.Feature(
    jolt.CharacterControllers,
    DistrictFeature.NavigationAccess,
);
const VitalsFeature = vitals_implementation.Feature();

const NpcEncounterVisibility = struct {
    controllers: *jolt.CharacterControllers,

    pub fn lineClear(
        self: *NpcEncounterVisibility,
        source_position: [3]f32,
        target_position: [3]f32,
    ) !bool {
        var start = source_position;
        var end = target_position;
        start[1] += 1.0;
        end[1] += 1.0;
        return self.controllers.lineUnobstructed(start, end);
    }
};

const NpcEncounterFeature = npc_encounter_implementation.Feature(NpcEncounterVisibility);

const NpcReplacementAccess = struct {
    runtime: *engine.Runtime,
    controllers: *jolt.CharacterControllers,
    npc_controllers: *jolt.CharacterControllers,
    character_feature: *CharacterFeature,
    vehicle_feature: *VehicleFeature,
    vitals_feature: *VitalsFeature,
    navigation_access: *DistrictFeature.NavigationAccess,
    npc_config: npcs.Config,

    pub fn nodePosition(
        self: *NpcReplacementAccess,
        reference: npcs.NodeRef,
    ) !?[3]f32 {
        try self.runtime.ensureOwnerThread();
        return switch (self.navigation_access.resolveNode(reference)) {
            .ready => |resolved| resolved.node.position,
            .district_inactive => null,
            .invalid_reference => error.InvalidNpcReplacementNavigationReference,
        };
    }

    pub fn spawnClear(self: *NpcReplacementAccess, position: [3]f32) !bool {
        try self.runtime.ensureOwnerThread();
        return self.npc_controllers.placementClear(.{
            .position = position,
            .radius = self.npc_config.radius,
            .half_height = self.npc_config.half_height,
            .max_slope_radians = self.npc_config.max_slope_radians,
            .mass = self.npc_config.mass,
            .max_strength = self.npc_config.max_strength,
        }, 0.05);
    }

    pub fn playerConflict(
        self: *NpcReplacementAccess,
        position: [3]f32,
        minimum_distance: f32,
        visibility_radius: f32,
    ) !?npc_replacement_contract.RetryReason {
        try self.runtime.ensureOwnerThread();
        var storage: [vitals_contract.max_records]CharacterView = undefined;
        const characters_now = try self.character_feature.copyViews(&storage);
        for (characters_now) |character_view| {
            if (self.vitals_feature.viewCurrent(.player, character_view.id)) |vital| {
                if (vital.life_state != .alive) continue;
            }
            const player_position = switch (character_view.driver_mode) {
                .on_foot => character_view.position,
                .driving => |vehicle_id| blk: {
                    const vehicle_view = try self.vehicle_feature.view(vehicle_id);
                    if (vehicle_view.driver_id == null or
                        !std.meta.eql(vehicle_view.driver_id.?, character_view.id))
                    {
                        return error.NpcReplacementVehicleOccupancyInvariantBroken;
                    }
                    break :blk vehicle_view.state.chassis.pose.position;
                },
            };
            const dx = position[0] - player_position[0];
            const dz = position[2] - player_position[2];
            const distance_squared = dx * dx + dz * dz;
            if (distance_squared < minimum_distance * minimum_distance) {
                return .too_close_to_player;
            }
            if (distance_squared <= visibility_radius * visibility_radius) {
                var start = player_position;
                var end = position;
                start[1] += 1.0;
                end[1] += 1.0;
                if (try self.controllers.lineUnobstructed(start, end)) {
                    return .visible_to_player;
                }
            }
        }
        return null;
    }
};

const NpcReplacementPolicy = npc_replacement.Policy(NpcReplacementAccess);

const Config = sandbox_host_contracts.Config;

/// Explicitly composed only by the installed S4 retained-fault smoke. Normal
/// sandbox, headless, replay, save, and M3 products never register this
/// system, so gameplay admission cannot reach it.
const DiagnosticFaultProbe = struct {
    armed: bool = false,

    fn run(
        raw: *anyopaque,
        _: *engine.Runtime,
        _: engine.TickContext,
    ) !void {
        const self: *DiagnosticFaultProbe = @ptrCast(@alignCast(raw));
        if (self.armed) return error.InjectedDeveloperDiagnosticFault;
    }
};

const State = struct {
    allocator: std.mem.Allocator,
    config: Config,
    initial_next_local_id: u64,
    physics: *jolt.Physics,
    runtime: engine.Runtime,
    stepper: jolt.PhysicsStepper,
    bodies: jolt.CrateBodies,
    controllers: jolt.CharacterControllers,
    npc_controllers: jolt.CharacterControllers,
    vehicle_adapter: jolt.Vehicles,
    crate_feature: CrateFeature,
    character_feature: CharacterFeature,
    driver_access: CharacterFeature.DriverAccess,
    carrier_access: CharacterFeature.CarrierAccess,
    district_bodies: jolt.DistrictBodies,
    district_loader: district_replay_loader.Loader,
    district_feature: DistrictFeature,
    navigation_access: DistrictFeature.NavigationAccess,
    interaction_feature: InteractionFeature,
    vehicle_feature: VehicleFeature,
    npc_feature: NpcFeature,
    vitals_feature: VitalsFeature,
    npc_encounter_visibility: NpcEncounterVisibility,
    npc_encounter_feature: NpcEncounterFeature,
    npc_replacement_access: NpcReplacementAccess,
    npc_replacement_policy: NpcReplacementPolicy,
    ground: ?jolt.BodyId,
    block: ?jolt.BodyId,
    capture: ?*ActiveCapture,
    diagnostic_fault_probe: DiagnosticFaultProbe,
    diagnostic_fault_probe_registered: bool,
};

pub const Simulation = struct {
    state: *State,

    pub fn init(allocator: std.mem.Allocator, config: Config) !Simulation {
        var simulation = try initOwnedUnfrozen(allocator, config, 1, 0, .live);
        simulation.state.runtime.finishRegistration();
        return simulation;
    }

    /// Construct the same production simulation plus one dormant, internal
    /// scheduled fault probe for the installed S4 diagnostics smoke. Keeping
    /// this as a distinct constructor makes its absence from every normal
    /// composition explicit and testable.
    pub fn initWithDiagnosticFaultProbe(
        allocator: std.mem.Allocator,
        config: Config,
    ) !Simulation {
        var simulation = try initOwnedUnfrozen(allocator, config, 1, 0, .live);
        errdefer simulation.deinit();
        var registry = simulation.state.runtime.registry();
        try registry.addSystem(
            .commands,
            "diagnostics.injected_fault_probe",
            &simulation.state.diagnostic_fault_probe,
            DiagnosticFaultProbe.run,
        );
        simulation.state.diagnostic_fault_probe_registered = true;
        simulation.state.runtime.finishRegistration();
        return simulation;
    }

    /// The current zflecs wrapper permits only one live world per module.
    /// Parse may happen while another simulation exists, but that simulation
    /// must be deinitialized before this function constructs the fresh world.
    pub fn fromSnapshot(
        allocator: std.mem.Allocator,
        bytes: []const u8,
        config: simulation_snapshot.RestoreConfig,
    ) !Simulation {
        var parsed = try simulation_snapshot.parse(
            allocator,
            bytes,
            config.max_crates,
            config.character.max_characters,
            config.vehicle.max_vehicles,
            config.npc.max_npcs,
        );
        defer parsed.deinit();

        return fromValidatedSnapshot(allocator, parsed.value, config);
    }

    /// Restore only after the snapshot's embedded construction fields have
    /// been bound to the exact world configuration admitted by the durable
    /// envelope. Validation and fingerprint comparison finish before Flecs or
    /// Jolt authority is acquired.
    pub fn fromSnapshotForWorld(
        allocator: std.mem.Allocator,
        bytes: []const u8,
        expected: Config,
        district_assets: DistrictAssets,
    ) !Simulation {
        var parsed = try simulation_snapshot.parse(
            allocator,
            bytes,
            expected.max_crates,
            expected.character.max_characters,
            expected.vehicle.max_vehicles,
            npcs.max_npcs,
        );
        defer parsed.deinit();
        try simulation_snapshot.validateWorldConfig(parsed.value, expected);

        return fromValidatedSnapshot(allocator, parsed.value, .{
            .max_crates = expected.max_crates,
            .assets = expected.assets,
            .create_ground = expected.create_ground,
            .character = .{
                .max_characters = expected.character.max_characters,
                .assets = expected.character.assets,
            },
            .vehicle = .{
                .max_vehicles = expected.vehicle.max_vehicles,
                .assets = expected.vehicle.assets,
            },
            .npc = .{
                .max_npcs = npcs.max_npcs,
                .assets = expected.npc.assets,
            },
            .district_assets = district_assets,
            .block = expected.block,
        });
    }

    fn fromValidatedSnapshot(
        allocator: std.mem.Allocator,
        snapshot: simulation_snapshot.SnapshotV11,
        config: simulation_snapshot.RestoreConfig,
    ) !Simulation {
        try validateNpcLimit(config.npc.max_npcs);
        const character_config = try snapshot.character_config.toConfig(
            config.character.max_characters,
            config.character.assets,
        );
        const vehicle_config = try snapshot.vehicle_config.toConfig(
            config.vehicle.max_vehicles,
            config.vehicle.assets,
        );
        const interaction_config = try snapshot.interaction_config.toConfig();
        const npc_config = try snapshot.npc_config.toConfig(config.npc.assets);
        const npc_encounter_config = try snapshot.npc_encounter_config.toConfig();

        var simulation = try initOwnedUnfrozen(allocator, .{
            .namespace = snapshot.namespace,
            .fixed_delta_seconds = snapshot.fixed_delta_seconds,
            .max_crates = config.max_crates,
            .assets = config.assets,
            .create_ground = config.create_ground,
            .character = character_config,
            .vehicle = vehicle_config,
            .interaction = interaction_config,
            .npc = npc_config,
            .npc_encounter = npc_encounter_config,
            .block = config.block,
        }, snapshot.next_local_id, snapshot.completed_ticks, .live);
        errdefer simulation.deinit();
        try simulation.state.crate_feature.restoreRecords(snapshot.crates);
        try simulation.state.character_feature.restoreRecords(snapshot.characters);
        try simulation.state.district_feature.restoreRecords(
            snapshot.districts,
            config.district_assets,
        );
        try simulation.state.interaction_feature.restoreRecords(snapshot.interactions);
        try simulation.state.vehicle_feature.restoreRecords(snapshot.vehicles);
        try simulation.state.npc_feature.restoreRecords(snapshot.npcs);
        try simulation.state.vitals_feature.restoreRecords(snapshot.vitals);
        try simulation.state.npc_encounter_feature.restoreRecords(snapshot.npc_encounters);
        try simulation.state.npc_replacement_policy.restoreRecords(snapshot.npc_replacements);
        try simulation.restoreNpcEncounterLocomotion();
        simulation.state.runtime.finishRegistration();
        return simulation;
    }

    fn initOwnedUnfrozen(
        allocator: std.mem.Allocator,
        config: Config,
        next_local_id: u64,
        completed_ticks: u64,
        loader_mode: district_replay_loader.Mode,
    ) !Simulation {
        if (config.max_crates == 0) return error.InvalidCrateLimit;
        try config.character.validate();
        try config.vehicle.validate();
        try config.interaction.validate();
        try config.npc.validate();
        try sandbox_host_contracts.validateCanonicalNavigationClearance(config.npc);
        try validateVirtualCharacterBudget(config.character.max_characters, npcs.max_npcs);
        try validatePhysicsBodyBudget(config);
        const state = try allocator.create(State);
        errdefer allocator.destroy(state);
        const physics = try allocator.create(jolt.Physics);
        errdefer allocator.destroy(physics);
        physics.* = try jolt.Physics.initWithAllocator(allocator);
        errdefer physics.deinit();

        state.allocator = allocator;
        state.config = config;
        state.initial_next_local_id = next_local_id;
        state.physics = physics;
        state.ground = null;
        state.block = null;
        state.capture = null;
        state.diagnostic_fault_probe = .{};
        state.diagnostic_fault_probe_registered = false;
        state.runtime = try engine.Runtime.init(allocator, .{
            .namespace = config.namespace,
            .fixed_delta_seconds = config.fixed_delta_seconds,
            .next_local_id = next_local_id,
            .completed_ticks = completed_ticks,
        });
        errdefer state.runtime.deinit();
        state.stepper = physics.stepper();
        state.bodies = physics.crateBodies();
        state.controllers = physics.characterControllers();
        state.npc_controllers = physics.characterControllers();
        state.vehicle_adapter = physics.vehicles();
        state.district_bodies = physics.districtBodies();
        state.district_loader = switch (loader_mode) {
            .live => district_replay_loader.Loader.initLive(),
            .replay => district_replay_loader.Loader.initReplay(),
        };
        errdefer state.district_loader.deinit();
        state.crate_feature = try CrateFeature.init(
            allocator,
            &state.runtime,
            &state.bodies,
            config.assets,
            config.max_crates,
        );
        errdefer state.crate_feature.deinit();
        state.character_feature = try CharacterFeature.init(
            allocator,
            &state.runtime,
            &state.controllers,
            config.character,
        );
        errdefer state.character_feature.deinit();
        state.driver_access = state.character_feature.driverAccess();
        state.carrier_access = state.character_feature.carrierAccess();
        state.district_feature = DistrictFeature.init(
            allocator,
            &state.runtime,
            &state.district_bodies,
            &state.district_loader,
        );
        errdefer state.district_feature.deinit();
        state.navigation_access = state.district_feature.navigationAccess();
        state.interaction_feature = try InteractionFeature.init(
            &state.runtime,
            &state.bodies,
            &state.carrier_access,
            config.interaction,
        );
        errdefer state.interaction_feature.deinit();
        state.vehicle_feature = try VehicleFeature.init(
            allocator,
            &state.runtime,
            &state.vehicle_adapter,
            &state.driver_access,
            config.vehicle,
        );
        errdefer state.vehicle_feature.deinit();
        state.npc_feature = try NpcFeature.init(
            &state.runtime,
            &state.npc_controllers,
            &state.navigation_access,
            config.npc,
        );
        errdefer state.npc_feature.deinit();
        state.vitals_feature = VitalsFeature.init(&state.runtime);
        errdefer state.vitals_feature.deinit();
        state.npc_encounter_visibility = .{ .controllers = &state.controllers };
        state.npc_encounter_feature = try NpcEncounterFeature.init(
            &state.npc_encounter_visibility,
            config.npc_encounter,
        );
        errdefer state.npc_encounter_feature.deinit();
        state.npc_replacement_access = .{
            .runtime = &state.runtime,
            .controllers = &state.controllers,
            .npc_controllers = &state.npc_controllers,
            .character_feature = &state.character_feature,
            .vehicle_feature = &state.vehicle_feature,
            .vitals_feature = &state.vitals_feature,
            .navigation_access = &state.navigation_access,
            .npc_config = config.npc,
        };
        state.npc_replacement_policy = try NpcReplacementPolicy.init(
            &state.npc_replacement_access,
            .{
                .retry_ticks = config.npc_encounter.replacement_retry_ticks,
                .minimum_player_distance = config.npc_encounter.replacement_min_player_distance,
                .visibility_radius = config.npc_encounter.replacement_visibility_radius,
            },
        );
        errdefer state.npc_replacement_policy.deinit();

        var registry = state.runtime.registry();
        try state.crate_feature.register(&registry);
        try state.character_feature.register(&registry);
        try state.district_feature.register(&registry);
        try state.interaction_feature.register(&registry);
        try state.vehicle_feature.register(&registry);
        try state.npc_feature.register(&registry);
        try state.vitals_feature.register(&registry);
        try registry.addSystem(.physics, "physics.step", &state.stepper, stepPhysics);

        if (config.create_ground) {
            state.ground = try physics.createStaticBox(.{ 0, -1, 0 }, .{ 50, 1, 50 });
            errdefer if (state.ground) |ground| {
                _ = physics.removeBody(ground);
            };
        }
        if (config.block) |block| {
            state.block = try physics.createStaticBox(block.position, block.half_extents);
            errdefer if (state.block) |body| {
                _ = physics.removeBody(body);
            };
        }
        return .{ .state = state };
    }

    pub fn deinit(self: *Simulation) void {
        const state = self.state;
        state.runtime.assertOwnerThread();
        if (state.capture) |capture| {
            capture.deinit();
            state.allocator.destroy(capture);
            state.capture = null;
        }
        state.npc_replacement_policy.deinit();
        state.npc_encounter_feature.deinit();
        state.vitals_feature.deinit();
        state.npc_feature.deinit();
        state.vehicle_feature.deinit();
        state.interaction_feature.deinit();
        state.district_feature.deinit();
        state.district_loader.deinit();
        state.character_feature.deinit();
        state.crate_feature.deinit();
        if (state.block) |block| {
            if (!state.physics.removeBody(block)) {
                @panic("simulation block cleanup invariant failed");
            }
        }
        if (state.ground) |ground| {
            if (!state.physics.removeBody(ground)) {
                @panic("simulation ground cleanup invariant failed");
            }
        }
        state.runtime.deinit();
        state.physics.deinit();
        state.allocator.destroy(state.physics);
        const allocator = state.allocator;
        allocator.destroy(state);
        self.* = undefined;
    }

    /// Arm a bounded capture only at the honest cold boundary. Rejection is a
    /// typed value because asking from a running sandbox is expected developer
    /// workflow, not an infrastructure failure.
    pub fn beginFlightRecording(
        self: *Simulation,
        content: sandbox_replay.ContentCohort,
        limits: sandbox_replay.Limits,
    ) !CaptureAdmission {
        try self.state.runtime.ensureOwnerThread();
        if (self.state.runtime.firstFault() != null) {
            return .{ .rejected = .runtime_faulted };
        }
        try self.state.runtime.ensureSnapshotBoundary();
        if (self.captureBoundaryReason()) |reason| {
            return .{ .rejected = reason };
        }

        const capture = try self.state.allocator.create(ActiveCapture);
        errdefer self.state.allocator.destroy(capture);
        capture.recorder = try sandbox_replay.Recorder.init(
            self.state.allocator,
            try self.replayWorldConfig(),
            content,
            limits,
        );
        errdefer capture.recorder.deinit();
        capture.scratch = try DigestScratch.init(
            self.state.allocator,
            self.requiredDigestIdentityCapacity(),
        );
        self.state.capture = capture;
        return .admitted;
    }

    /// Encode and close the current capture. An incomplete envelope remains
    /// inspectable, but its parser/compatibility gate will refuse replay.
    pub fn finishFlightRecording(
        self: *Simulation,
        allocator: std.mem.Allocator,
    ) ![]u8 {
        try self.state.runtime.ensureStoppedInspectionBoundary();
        const capture = self.state.capture orelse return error.FlightRecordingNotActive;
        if (self.hasPendingCommands()) {
            capture.recorder.markIncomplete(.commands_pending_at_finish);
        }
        if (self.state.district_loader.observation().issue != null) {
            capture.recorder.markIncomplete(.loader_issue);
        }
        const bytes = try capture.recorder.encode(allocator);
        capture.deinit();
        self.state.allocator.destroy(capture);
        self.state.capture = null;
        return bytes;
    }

    /// Encode a stable prefix without closing the active recorder. Incident
    /// capture uses this at a normal stopped tick boundary so later gameplay
    /// can continue recording for a newer handoff.
    pub fn snapshotFlightRecording(
        self: *Simulation,
        allocator: std.mem.Allocator,
    ) ![]u8 {
        try self.state.runtime.ensureSnapshotBoundary();
        const capture = self.state.capture orelse return error.FlightRecordingNotActive;
        if (self.hasPendingCommands()) return error.CommandsPendingAtReplaySnapshot;
        if (self.state.district_loader.observation().issue != null) {
            return error.LoaderIssueAtReplaySnapshot;
        }
        return capture.recorder.encode(allocator);
    }

    pub fn flightRecordingIncompleteReason(
        self: *const Simulation,
    ) ?sandbox_replay.IncompleteReason {
        self.state.runtime.assertOwnerThread();
        const capture = self.state.capture orelse return null;
        return capture.recorder.incompleteReason();
    }

    /// Arm the optional S4-only probe. This does not accept an arbitrary
    /// error, phase, or callback and therefore cannot become a general service
    /// locator or mutation escape hatch.
    pub fn armDiagnosticFaultProbe(self: *Simulation) !void {
        try self.state.runtime.ensureOwnerThread();
        try self.state.runtime.ensureHealthy();
        if (!self.state.diagnostic_fault_probe_registered) {
            return error.DiagnosticFaultProbeUnavailable;
        }
        if (self.state.diagnostic_fault_probe.armed) {
            return error.DiagnosticFaultProbeAlreadyArmed;
        }
        self.state.diagnostic_fault_probe.armed = true;
    }

    fn captureBoundaryReason(self: *Simulation) ?CaptureBoundaryReason {
        if (self.state.capture != null) return .already_recording;
        if (self.state.runtime.firstFault() != null) return .runtime_faulted;
        if (self.state.runtime.tickIndex() != 0) return .ticks_completed;
        if (self.hasPendingCommands()) return .commands_pending;
        if (self.state.runtime.entityCount() != 0) return .entities_present;
        const next_local_id = self.state.runtime.nextLocalId() catch
            return .identity_cursor_advanced;
        if (next_local_id != 1 or self.state.initial_next_local_id != 1) {
            return .identity_cursor_advanced;
        }
        const district_diagnostics = self.state.district_feature.diagnostics();
        if (district_diagnostics.active_count != 0 or
            district_diagnostics.loading_count != 0 or
            district_diagnostics.cancelling_count != 0)
        {
            return .district_not_quiescent;
        }
        const worker = self.state.district_loader.diagnostics();
        if (worker.state != .idle or worker.generation != null or
            worker.completion_kind != null)
        {
            return .worker_not_idle;
        }
        if (!self.outputQueuesEmpty()) return .outputs_pending;
        const expected_bodies: u32 =
            @as(u32, @intFromBool(self.state.config.create_ground)) +
            @as(u32, @intFromBool(self.state.config.block != null));
        if (self.state.bodies.bodyCount() != expected_bodies) {
            return .unexpected_physics_bodies;
        }
        return null;
    }

    fn replayWorldConfig(self: *Simulation) !sandbox_replay.WorldConfig {
        return simulation_snapshot.worldConfig(self.state.config);
    }

    fn hasPendingCommands(self: *const Simulation) bool {
        return self.state.crate_feature.hasPendingCommands() or
            self.state.character_feature.hasPendingCommands() or
            self.state.district_feature.hasPendingCommands() or
            self.state.interaction_feature.hasPendingCommands() or
            self.state.vehicle_feature.hasPendingCommands() or
            self.state.npc_feature.hasPendingCommands() or
            self.state.vitals_feature.hasPendingCommands();
    }

    fn outputQueuesEmpty(self: *Simulation) bool {
        const crate_diagnostics = self.state.crate_feature.diagnostics();
        const character_diagnostics = self.state.character_feature.diagnostics();
        const vehicle_diagnostics = self.state.vehicle_feature.diagnostics();
        const district_diagnostics = self.state.district_feature.diagnostics();
        const interaction_diagnostics = self.state.interaction_feature.diagnostics();
        const npc_diagnostics = self.state.npc_feature.diagnostics();
        const vitals_diagnostics = self.state.vitals_feature.diagnostics();
        const encounter_diagnostics = self.state.npc_encounter_feature.diagnostics();
        const replacement_diagnostics = self.state.npc_replacement_policy.diagnostics();
        return crate_diagnostics.outcomes.occupancy == 0 and
            character_diagnostics.outcomes.occupancy == 0 and
            character_diagnostics.events.occupancy == 0 and
            vehicle_diagnostics.outcomes.occupancy == 0 and
            vehicle_diagnostics.events.occupancy == 0 and
            district_diagnostics.outcomes.occupancy == 0 and
            district_diagnostics.events.occupancy == 0 and
            interaction_diagnostics.outcomes.occupancy == 0 and
            npc_diagnostics.outcomes.occupancy == 0 and
            npc_diagnostics.events.occupancy == 0 and
            vitals_diagnostics.outcomes == 0 and
            vitals_diagnostics.events == 0 and
            encounter_diagnostics.cues_pending == 0 and
            replacement_diagnostics.outcomes_pending == 0;
    }

    pub fn operationalQuiescenceReason(
        self: *Simulation,
    ) ?OperationalQuiescenceReason {
        self.state.runtime.assertOwnerThread();
        if (self.state.runtime.firstFault() != null) return .runtime_faulted;
        if (self.hasPendingCommands()) return .commands_pending;
        const district_diagnostics = self.state.district_feature.diagnostics();
        if (district_diagnostics.loading_count != 0 or
            district_diagnostics.cancelling_count != 0)
        {
            return .district_transition;
        }
        if (district_diagnostics.outcome_reservations != 0) {
            return .district_outcome_reservations;
        }
        if (self.state.district_loader.diagnostics().state != .idle) {
            return .district_worker_busy;
        }
        if (!self.outputQueuesEmpty()) return .outputs_pending;
        return null;
    }

    pub fn submit(self: *Simulation, command: Command) !void {
        try self.state.runtime.ensureOwnerThread();
        const eligible_tick = try self.state.runtime.commandTargetTick();
        try self.state.crate_feature.enqueue(command);
        self.recordAcceptedCommand(
            eligible_tick,
            sandbox_replay.NormalizedCommand.fromCrate(command),
        );
    }

    pub fn submitCharacter(self: *Simulation, command: CharacterCommand) !void {
        try self.state.runtime.ensureOwnerThread();
        const eligible_tick = try self.state.runtime.commandTargetTick();
        try self.state.character_feature.enqueue(command);
        self.recordAcceptedCommand(
            eligible_tick,
            sandbox_replay.NormalizedCommand.fromCharacter(command),
        );
    }

    pub fn submitVehicle(self: *Simulation, command: VehicleCommand) !void {
        try self.state.runtime.ensureOwnerThread();
        const eligible_tick = try self.state.runtime.commandTargetTick();
        try self.state.vehicle_feature.enqueue(command);
        self.recordAcceptedCommand(
            eligible_tick,
            sandbox_replay.NormalizedCommand.fromVehicle(command),
        );
    }

    pub fn submitDistrict(self: *Simulation, command: DistrictCommand) !void {
        try self.state.runtime.ensureOwnerThread();
        const eligible_tick = try self.state.runtime.commandTargetTick();
        try self.state.district_feature.enqueue(command);
        self.recordAcceptedCommand(
            eligible_tick,
            sandbox_replay.NormalizedCommand.fromDistrict(command),
        );
    }

    pub fn submitInteraction(self: *Simulation, command: InteractionCommand) !void {
        try self.state.runtime.ensureOwnerThread();
        const eligible_tick = try self.state.runtime.commandTargetTick();
        try self.state.interaction_feature.enqueue(command);
        self.recordAcceptedCommand(
            eligible_tick,
            sandbox_replay.NormalizedCommand.fromInteraction(command),
        );
    }

    pub fn submitNpc(self: *Simulation, command: NpcCommand) !void {
        try self.state.runtime.ensureOwnerThread();
        const eligible_tick = try self.state.runtime.commandTargetTick();
        try self.state.npc_feature.enqueue(command);
        self.recordAcceptedCommand(
            eligible_tick,
            sandbox_replay.NormalizedCommand.fromNpc(command),
        );
    }

    pub fn submitVitals(self: *Simulation, command: VitalsCommand) !void {
        try self.state.runtime.ensureOwnerThread();
        const eligible_tick = try self.state.runtime.commandTargetTick();
        try self.state.vitals_feature.enqueue(command);
        self.recordAcceptedCommand(
            eligible_tick,
            sandbox_replay.NormalizedCommand.fromVitals(command),
        );
    }

    pub fn tick(self: *Simulation) !void {
        return self.tickObserved(null);
    }

    /// Run one authoritative tick with an optional nonfallible phase observer.
    /// Profiling remains a host-owned consumer: the observer cannot reject a
    /// phase and is excluded from saves, replay, and logical digests.
    pub fn tickObserved(self: *Simulation, observer: ?engine.PhaseObserver) !void {
        if (self.state.capture) |capture| {
            if (self.state.runtime.tickIndex() > 0 and !self.outputQueuesEmpty()) {
                capture.recorder.markIncomplete(.output_policy_violated);
            }
        }
        try self.state.district_loader.setCurrentTick(
            try std.math.add(u64, self.state.runtime.tickIndex(), 1),
        );
        self.state.runtime.tickObserved(observer) catch |err| {
            // The worker result has already crossed the feature boundary if a
            // later phase failed. Never let retained replay instrumentation
            // replace or obscure the authoritative runtime fault.
            _ = self.state.district_loader.takeConsumedCompletion();
            if (self.state.capture) |capture| {
                capture.recorder.markIncomplete(.authority_failed);
            }
            return err;
        };
        try self.stepNpcEncounter();
        try self.state.npc_replacement_policy.step(self.state.runtime.tickIndex());
        const consumed = self.state.district_loader.takeConsumedCompletion();
        if (self.state.capture) |capture| {
            if (consumed) |entry| {
                _ = capture.recorder.recordDistrictCompletion(
                    entry.tick_index,
                    entry.completion,
                );
            }
            if (self.state.district_loader.observation().issue != null) {
                capture.recorder.markIncomplete(.loader_issue);
            }
            const digests = self.logicalDigests(&capture.scratch) catch {
                capture.recorder.markIncomplete(.digest_failed);
                return;
            };
            _ = capture.recorder.recordTickDigests(digests);
        }
    }

    fn stepNpcEncounter(self: *Simulation) !void {
        var character_views: [vitals_contract.max_records]CharacterView = undefined;
        const current_characters = try self.state.character_feature.copyViews(&character_views);
        var player_observations: [vitals_contract.max_records]npc_encounter_contract.CombatantObservation = undefined;
        var player_count: usize = 0;
        for (current_characters) |character_view| {
            const vital = self.state.vitals_feature.viewCurrent(.player, character_view.id) orelse continue;
            const position_navigable = switch (self.state.navigation_access.nearestActiveNode(
                character_view.position,
            )) {
                .ready => true,
                .district_inactive, .unavailable => false,
            };
            player_observations[player_count] = .{
                .target = vital.target,
                .position = character_view.position,
                .facing_yaw = character_view.facing_yaw,
                .alive = vital.life_state == .alive,
                .attackable = switch (character_view.driver_mode) {
                    .on_foot => position_navigable,
                    .driving => false,
                },
            };
            player_count += 1;
        }

        var npc_views: [npcs.max_npcs]NpcView = undefined;
        const current_npcs = try self.state.npc_feature.copyViews(&npc_views);
        var npc_observations: [npcs.max_npcs]npc_encounter_contract.NpcObservation = undefined;
        var npc_count: usize = 0;
        for (current_npcs) |npc_view| {
            const vital = self.state.vitals_feature.viewCurrent(.npc, npc_view.id) orelse continue;
            npc_observations[npc_count] = .{
                .target = vital.target,
                .position = npc_view.position,
                .facing_yaw = npc_view.facing_yaw,
                .alive = vital.life_state == .alive,
                .available = npc_view.state == .active and npc_view.controller_present,
                .current_health = vital.current_health,
            };
            npc_count += 1;
        }

        var vitals_facts: [vitals_contract.max_pending_commands]vitals_contract.AppliedDamageFact = undefined;
        const current_facts = try self.state.vitals_feature.copyAppliedDamage(&vitals_facts);
        var encounter_facts: [vitals_contract.max_pending_commands]npc_encounter_contract.DamageFact = undefined;
        for (current_facts, 0..) |fact, index| {
            encounter_facts[index] = .{
                .source = fact.source,
                .target = fact.target,
                .authority_tick = fact.authority_tick,
                .applied_amount = fact.applied_amount,
                .remaining_health = fact.remaining_health,
                .killed = fact.killed,
            };
        }

        try self.state.npc_encounter_feature.step(.{
            .tick = self.state.runtime.tickIndex(),
            .players = player_observations[0..player_count],
            .npcs = npc_observations[0..npc_count],
            .damage_facts = encounter_facts[0..current_facts.len],
        });

        var locomotion = self.state.npc_feature.encounterAccess();
        while (self.state.npc_encounter_feature.pollDirective()) |directive| {
            const mapped: npcs.EncounterLocomotion = switch (directive.locomotion) {
                .hold => .hold,
                .resume_route => .resume_route,
                .pursue => |value| .{ .pursue_position = value.position },
                .face_and_hold => |value| .{ .face_and_hold = value.position },
            };
            try locomotion.apply(directive.npc.id, mapped);
        }
        while (self.state.npc_encounter_feature.pollDamage()) |proposal| {
            try self.state.vitals_feature.enqueue(.{ .damage = proposal });
        }
    }

    fn restoreNpcEncounterLocomotion(self: *Simulation) !void {
        var storage: [npc_encounter_contract.max_records]NpcEncounterView = undefined;
        const views = try self.state.npc_encounter_feature.views(&storage);
        var locomotion = self.state.npc_feature.encounterAccess();
        for (views) |view| {
            const restored: npcs.EncounterLocomotion = if (!view.alive)
                .hold
            else if (view.last_directive) |directive| switch (directive) {
                .hold => .hold,
                .resume_route => .resume_route,
                .pursue => |value| .{ .pursue_position = value.position },
                .face_and_hold => |value| .{ .face_and_hold = value.position },
            } else switch (view.state) {
                .patrolling, .returning => .resume_route,
                .pursuing, .searching => .{ .pursue_position = view.last_seen_position },
                .attack_windup, .attack_recovery => .{
                    .face_and_hold = view.last_seen_position,
                },
            };
            try locomotion.restore(view.npc.id, restored);
        }
    }

    fn recordAcceptedCommand(
        self: *Simulation,
        eligible_tick: u64,
        command: sandbox_replay.NormalizedCommand,
    ) void {
        const capture = self.state.capture orelse return;
        const replayable_eligible_tick = std.math.add(
            u64,
            self.state.runtime.tickIndex(),
            1,
        ) catch {
            capture.recorder.markIncomplete(.unsupported_submission_phase);
            return;
        };
        if (eligible_tick != replayable_eligible_tick) {
            // The first contract injects commands only between completed
            // ticks. A system-internal submission targets a later tick but is
            // already visible in the current tick's queue digest, so merely
            // recording its eligible tick would reproduce it dishonestly.
            capture.recorder.markIncomplete(.unsupported_submission_phase);
            return;
        }
        if (self.state.runtime.tickIndex() == 0) {
            // Cold admission guarantees every pre-first-tick command is
            // eligible on tick one and belongs to the bootstrap section.
            if (eligible_tick != 1) {
                capture.recorder.markIncomplete(.invalid_record);
                return;
            }
            _ = capture.recorder.recordBootstrap(command);
        } else {
            _ = capture.recorder.recordCommand(eligible_tick, command);
        }
    }

    pub fn pollOutcome(self: *Simulation) ?Outcome {
        self.state.runtime.assertOwnerThread();
        return self.state.crate_feature.pollOutcome();
    }

    pub fn pollCharacterOutcome(self: *Simulation) ?CharacterOutcome {
        self.state.runtime.assertOwnerThread();
        return self.state.character_feature.pollOutcome();
    }

    pub fn pollCharacterEvent(self: *Simulation) ?CharacterEvent {
        self.state.runtime.assertOwnerThread();
        return self.state.character_feature.pollEvent();
    }

    pub fn pollVehicleOutcome(self: *Simulation) ?VehicleOutcome {
        self.state.runtime.assertOwnerThread();
        return self.state.vehicle_feature.pollOutcome();
    }

    pub fn pollVehicleEvent(self: *Simulation) ?VehicleEvent {
        self.state.runtime.assertOwnerThread();
        return self.state.vehicle_feature.pollEvent();
    }

    pub fn pollDistrictOutcome(self: *Simulation) ?DistrictOutcome {
        self.state.runtime.assertOwnerThread();
        return self.state.district_feature.pollOutcome();
    }

    pub fn pollDistrictEvent(self: *Simulation) ?DistrictEvent {
        self.state.runtime.assertOwnerThread();
        return self.state.district_feature.pollEvent();
    }

    pub fn pollInteractionOutcome(self: *Simulation) ?InteractionOutcome {
        self.state.runtime.assertOwnerThread();
        return self.state.interaction_feature.pollOutcome();
    }

    pub fn pollNpcOutcome(self: *Simulation) ?NpcOutcome {
        self.state.runtime.assertOwnerThread();
        return self.state.npc_feature.pollOutcome();
    }

    pub fn peekNpcOutcome(self: *const Simulation) ?NpcOutcome {
        self.state.runtime.assertOwnerThread();
        return self.state.npc_feature.peekOutcome();
    }

    pub fn commitNpcOutcome(self: *Simulation, expected: NpcOutcome) !void {
        try self.state.runtime.ensureOwnerThread();
        try self.state.npc_feature.commitOutcome(expected);
    }

    pub fn pollNpcEvent(self: *Simulation) ?NpcEvent {
        self.state.runtime.assertOwnerThread();
        return self.state.npc_feature.pollEvent();
    }

    pub fn pollVitalsOutcome(self: *Simulation) ?VitalsOutcome {
        self.state.runtime.assertOwnerThread();
        return self.state.vitals_feature.pollOutcome();
    }

    pub fn peekVitalsOutcome(self: *const Simulation) ?VitalsOutcome {
        self.state.runtime.assertOwnerThread();
        return self.state.vitals_feature.peekOutcome();
    }

    pub fn commitVitalsOutcome(self: *Simulation, expected: VitalsOutcome) !void {
        try self.state.runtime.ensureOwnerThread();
        try self.state.vitals_feature.commitOutcome(expected);
    }

    pub fn pollVitalsEvent(self: *Simulation) ?VitalsEvent {
        self.state.runtime.assertOwnerThread();
        return self.state.vitals_feature.pollEvent();
    }

    pub fn peekVitalsEvent(self: *const Simulation) ?VitalsEvent {
        self.state.runtime.assertOwnerThread();
        return self.state.vitals_feature.peekEvent();
    }

    pub fn commitVitalsEvent(self: *Simulation, expected: VitalsEvent) !void {
        try self.state.runtime.ensureOwnerThread();
        try self.state.vitals_feature.commitEvent(expected);
    }

    pub fn pollNpcEncounterCue(self: *Simulation) ?NpcEncounterCue {
        self.state.runtime.assertOwnerThread();
        return self.state.npc_encounter_feature.pollCue();
    }

    pub fn scheduleNpcReplacement(
        self: *Simulation,
        slot: u8,
        generation: u16,
        death_tick: u64,
        candidates: []const npcs.NodeRef,
    ) !void {
        try self.state.runtime.ensureSnapshotBoundary();
        const eligible_tick = try self.state.runtime.commandTargetTick();
        const normalized = try sandbox_replay.NormalizedNpcReplacementCommand.fromSchedule(
            slot,
            generation,
            death_tick,
            candidates,
        );
        try self.state.npc_replacement_policy.schedule(.{
            .slot = slot,
            .generation = generation,
            .available_tick = death_tick +|
                self.state.config.npc_encounter.replacement_delay_ticks,
            .candidates = candidates,
        });
        self.recordAcceptedCommand(
            eligible_tick,
            sandbox_replay.NormalizedCommand.fromNpcReplacement(normalized),
        );
    }

    pub fn completeNpcReplacement(
        self: *Simulation,
        slot: u8,
        generation: u16,
    ) !void {
        try self.state.runtime.ensureSnapshotBoundary();
        const eligible_tick = try self.state.runtime.commandTargetTick();
        const normalized = sandbox_replay.NormalizedNpcReplacementCommand.completeCommand(
            slot,
            generation,
        );
        try self.state.npc_replacement_policy.complete(slot, generation);
        self.recordAcceptedCommand(
            eligible_tick,
            sandbox_replay.NormalizedCommand.fromNpcReplacement(normalized),
        );
    }

    pub fn deferNpcReplacement(
        self: *Simulation,
        slot: u8,
        generation: u16,
    ) !void {
        try self.state.runtime.ensureSnapshotBoundary();
        const eligible_tick = try self.state.runtime.commandTargetTick();
        const normalized = sandbox_replay.NormalizedNpcReplacementCommand.deferCommand(
            slot,
            generation,
        );
        try self.state.npc_replacement_policy.deferSpawn(
            slot,
            generation,
            self.state.runtime.tickIndex(),
        );
        self.recordAcceptedCommand(
            eligible_tick,
            sandbox_replay.NormalizedCommand.fromNpcReplacement(normalized),
        );
    }

    pub fn pollNpcReplacementOutcome(self: *Simulation) ?NpcReplacementOutcome {
        self.state.runtime.assertOwnerThread();
        return self.state.npc_replacement_policy.pollOutcome();
    }

    /// Close one replay tick's consumable output boundary. Every public
    /// polling lane is listed explicitly so adding a lane requires updating
    /// this contract and its focused test rather than failing a later replay.
    pub fn drainReplayBoundaryOutputs(self: *Simulation) ReplayBoundaryDrain {
        var drained = ReplayBoundaryDrain{};
        while (self.pollOutcome() != null) drained.crate_outcomes +|= 1;
        while (self.pollCharacterOutcome() != null) drained.character_outcomes +|= 1;
        while (self.pollCharacterEvent() != null) drained.character_events +|= 1;
        while (self.pollVehicleOutcome() != null) drained.vehicle_outcomes +|= 1;
        while (self.pollVehicleEvent() != null) drained.vehicle_events +|= 1;
        while (self.pollDistrictOutcome() != null) drained.district_outcomes +|= 1;
        while (self.pollDistrictEvent() != null) drained.district_events +|= 1;
        while (self.pollInteractionOutcome() != null) drained.interaction_outcomes +|= 1;
        while (self.pollNpcOutcome() != null) drained.npc_outcomes +|= 1;
        while (self.pollNpcEvent() != null) drained.npc_events +|= 1;
        while (self.pollVitalsOutcome() != null) drained.vitals_outcomes +|= 1;
        while (self.pollVitalsEvent() != null) drained.vitals_events +|= 1;
        while (self.pollNpcEncounterCue() != null) drained.npc_encounter_cues +|= 1;
        while (self.pollNpcReplacementOutcome() != null) {
            drained.npc_replacement_outcomes +|= 1;
        }
        return drained;
    }

    pub fn peekNpcReplacementOutcome(self: *const Simulation) ?NpcReplacementOutcome {
        self.state.runtime.assertOwnerThread();
        return self.state.npc_replacement_policy.peekOutcome();
    }

    pub fn commitNpcReplacementOutcome(
        self: *Simulation,
        expected: NpcReplacementOutcome,
    ) !void {
        try self.state.runtime.ensureOwnerThread();
        try self.state.npc_replacement_policy.commitOutcome(expected);
    }

    pub fn npcReplacementDiagnostics(self: *const Simulation) NpcReplacementDiagnostics {
        self.state.runtime.assertOwnerThread();
        return self.state.npc_replacement_policy.diagnostics();
    }

    pub fn npcEncounter(
        self: *const Simulation,
        target: vitals_contract.Target,
    ) ?NpcEncounterView {
        self.state.runtime.assertOwnerThread();
        return self.state.npc_encounter_feature.view(target);
    }

    pub fn npcEncounterDiagnostics(self: *const Simulation) NpcEncounterDiagnostics {
        self.state.runtime.assertOwnerThread();
        return self.state.npc_encounter_feature.diagnostics();
    }

    pub fn npcDeathPresentationTicks(self: *const Simulation) u16 {
        self.state.runtime.assertOwnerThread();
        return self.state.npc_encounter_feature.deathPresentationTicks();
    }

    pub fn copyNpcEncounterTransitions(
        self: *const Simulation,
        storage: []NpcEncounterTransition,
    ) ![]const NpcEncounterTransition {
        self.state.runtime.assertOwnerThread();
        return self.state.npc_encounter_feature.copyTransitions(storage);
    }

    pub fn presentation(
        self: *Simulation,
        alpha: f32,
    ) ![]const CrateDraw {
        try self.state.runtime.ensureOwnerThread();
        return self.state.crate_feature.extract(alpha);
    }

    pub fn characterPresentation(
        self: *Simulation,
        alpha: f32,
    ) ![]const CharacterDraw {
        try self.state.runtime.ensureOwnerThread();
        return self.state.character_feature.extract(alpha);
    }

    pub fn characterSpawnClear(self: *Simulation, position: [3]f32) !bool {
        try self.state.runtime.ensureOwnerThread();
        const config = self.state.config.character;
        return self.state.controllers.placementClear(.{
            .position = position,
            .radius = config.radius,
            .half_height = config.half_height,
            .max_slope_radians = config.max_slope_radians,
            .mass = config.mass,
            .max_strength = config.max_strength,
        }, 0.05);
    }

    pub fn npcSpawnClear(self: *Simulation, position: [3]f32) !bool {
        try self.state.runtime.ensureOwnerThread();
        const config = self.state.config.npc;
        return self.state.npc_controllers.placementClear(.{
            .position = position,
            .radius = config.radius,
            .half_height = config.half_height,
            .max_slope_radians = config.max_slope_radians,
            .mass = config.mass,
            .max_strength = config.max_strength,
        }, 0.05);
    }

    pub fn navigationNodePosition(
        self: *Simulation,
        reference: NavigationNodeRef,
    ) !?[3]f32 {
        try self.state.runtime.ensureOwnerThread();
        return switch (self.state.navigation_access.resolveNode(reference)) {
            .ready => |resolved| resolved.node.position,
            .district_inactive => null,
            .invalid_reference => error.InvalidNavigationReference,
        };
    }

    pub fn meleeLineClear(
        self: *Simulation,
        source_position: [3]f32,
        target_position: [3]f32,
    ) !bool {
        try self.state.runtime.ensureOwnerThread();
        var start = source_position;
        var end = target_position;
        start[1] += 1.0;
        end[1] += 1.0;
        return self.state.controllers.lineUnobstructed(start, end);
    }

    /// Read-only world obstruction query for presentation placement. This
    /// exposes only a normalized segment fraction; backend body identities and
    /// collision ownership remain inside the simulation composition.
    pub fn presentationLineHitFraction(
        self: *Simulation,
        start: [3]f32,
        end: [3]f32,
    ) !?f32 {
        try self.state.runtime.ensureOwnerThread();
        return self.state.controllers.lineHitFraction(start, end);
    }

    pub fn vehiclePresentation(
        self: *Simulation,
        alpha: f32,
    ) ![]const VehicleDraw {
        try self.state.runtime.ensureOwnerThread();
        return self.state.vehicle_feature.extract(alpha);
    }

    pub fn districtPresentation(self: *Simulation) ![]const DistrictDraw {
        try self.state.runtime.ensureOwnerThread();
        return self.state.district_feature.extract();
    }

    pub fn interactionPresentation(self: *Simulation) ![]const CarryableDraw {
        try self.state.runtime.ensureOwnerThread();
        return self.state.interaction_feature.extract();
    }

    pub fn npcPresentation(self: *Simulation, alpha: f32) ![]const NpcDraw {
        try self.state.runtime.ensureOwnerThread();
        return self.state.npc_feature.extract(alpha);
    }

    /// Extract backend-neutral physics and encounter debug geometry only at a
    /// completed healthy tick boundary. Storage is caller-owned and bounded;
    /// extraction cannot mutate simulation state or allocate.
    pub fn extractPhysicsDebug(
        self: *Simulation,
        config: PhysicsDebugConfig,
        storage: *engine.physics_debug.Storage,
    ) !PhysicsDebugBatch {
        try self.state.runtime.ensureSnapshotBoundary();
        const completed_tick = self.state.runtime.tickIndex();
        if (completed_tick == 0) return error.PhysicsDebugBeforeFirstTick;
        _ = self.state.physics.extractDebug(config, completed_tick, storage);
        if (config.bounds) {
            try self.appendDistrictOwnershipDebug(storage);
            try self.appendNpcEncounterDebug(storage);
        }
        return storage.batch() orelse error.PhysicsDebugBatchMissing;
    }

    fn appendDistrictOwnershipDebug(
        self: *Simulation,
        storage: *engine.physics_debug.Storage,
    ) !void {
        const draws = try self.state.district_feature.extract();
        for (draws) |draw| {
            const coord = draw.ticket.coord;
            const center_x = @as(f32, @floatFromInt(coord.x)) * district_contract.chunk_span;
            const center_z = @as(f32, @floatFromInt(coord.z)) * district_contract.chunk_span;
            const min_x = center_x - district_contract.chunk_half_span;
            const max_x = center_x + district_contract.chunk_half_span;
            const min_z = center_z - district_contract.chunk_half_span;
            const max_z = center_z + district_contract.chunk_half_span;
            const y: f32 = 0.08;
            const object = engine.physics_debug.ObjectRef{
                .kind = 0x44495354,
                .serial = draw.persistent_id.local,
            };
            const color: engine.physics_debug.Color = if ((coord.x + coord.z) & 1 == 0)
                .{ 0.1, 0.85, 1.0, 1.0 }
            else
                .{ 1.0, 0.8, 0.15, 1.0 };
            appendDebugLine(storage, .{ min_x, y, min_z }, .{ max_x, y, min_z }, color, object);
            appendDebugLine(storage, .{ max_x, y, min_z }, .{ max_x, y, max_z }, color, object);
            appendDebugLine(storage, .{ max_x, y, max_z }, .{ min_x, y, max_z }, color, object);
            appendDebugLine(storage, .{ min_x, y, max_z }, .{ min_x, y, min_z }, color, object);
            appendDebugCross(storage, .{ center_x, y + 0.04, center_z }, 0.45, color, object);
        }
    }

    fn appendNpcEncounterDebug(
        self: *Simulation,
        storage: *engine.physics_debug.Storage,
    ) !void {
        var encounter_views: [npc_encounter_contract.max_records]NpcEncounterView = undefined;
        const encounters = try self.state.npc_encounter_feature.views(&encounter_views);
        const config = self.state.npc_encounter_feature.config;
        for (encounters) |encounter| {
            if (!encounter.alive) continue;
            const npc_view = self.state.npc_feature.view(encounter.npc.id) catch continue;
            const object = engine.physics_debug.ObjectRef{
                .kind = 0x533131,
                .serial = encounter.npc.id.local,
            };
            const center = debugRaised(npc_view.position, 0.05);
            if (npc_view.navigation_progress.target) |target| {
                const raised_target = debugRaised(target, 0.18);
                const progress_color: engine.physics_debug.Color =
                    if (npc_view.navigation_progress.state == .potentially_stalled)
                        .{ 1.0, 0.05, 0.05, 1.0 }
                    else
                        .{ 0.2, 1.0, 0.35, 1.0 };
                appendDebugLine(storage, center, raised_target, progress_color, object);
                appendDebugCross(storage, raised_target, 0.3, progress_color, object);
            }
            appendDebugCircle(
                storage,
                center,
                config.sight_radius,
                24,
                .{ 0.15, 0.85, 1.0, 1.0 },
                object,
            );
            appendDebugCircle(
                storage,
                center,
                config.combat_standoff_distance,
                16,
                .{ 1.0, 0.55, 0.1, 1.0 },
                object,
            );
            appendDebugCircle(
                storage,
                center,
                config.melee_range,
                16,
                .{ 1.0, 0.2, 0.15, 1.0 },
                object,
            );
            appendDebugCircle(
                storage,
                debugRaised(encounter.encounter_origin, 0.08),
                config.pursuit_leash,
                32,
                .{ 1.0, 0.75, 0.1, 1.0 },
                object,
            );
            appendDebugSightCone(
                storage,
                center,
                npc_view.facing_yaw,
                config.sight_facing_cos,
                config.sight_radius,
                object,
            );
            if (encounter.last_seen_tick != 0) {
                const last_seen = debugRaised(encounter.last_seen_position, 0.12);
                appendDebugLine(
                    storage,
                    center,
                    last_seen,
                    .{ 0.9, 0.25, 1.0, 1.0 },
                    object,
                );
                appendDebugCross(
                    storage,
                    last_seen,
                    0.35,
                    .{ 0.9, 0.25, 1.0, 1.0 },
                    object,
                );
            }

            var route_start = center;
            const route_nodes = npc_view.route.plan.slice();
            const route_index = @min(@as(usize, npc_view.route.index) + 1, route_nodes.len);
            for (route_nodes[route_index..]) |reference| {
                const resolved = try self.navigationNodePosition(reference) orelse continue;
                const route_end = debugRaised(resolved, 0.16);
                appendDebugLine(
                    storage,
                    route_start,
                    route_end,
                    .{ 0.2, 1.0, 0.35, 1.0 },
                    object,
                );
                route_start = route_end;
            }
        }
    }

    pub fn crate(self: *Simulation, id: engine.PersistentId) !CrateView {
        try self.state.runtime.ensureOwnerThread();
        return self.state.crate_feature.view(id);
    }

    pub fn character(self: *Simulation, id: engine.PersistentId) !CharacterView {
        try self.state.runtime.ensureOwnerThread();
        return self.state.character_feature.view(id);
    }

    pub fn vehicle(self: *Simulation, id: engine.PersistentId) !VehicleView {
        try self.state.runtime.ensureOwnerThread();
        return self.state.vehicle_feature.view(id);
    }

    pub fn carryable(self: *Simulation, id: engine.PersistentId) !CarryableView {
        try self.state.runtime.ensureOwnerThread();
        return self.state.interaction_feature.view(id);
    }

    pub fn npc(self: *Simulation, id: engine.PersistentId) !NpcView {
        try self.state.runtime.ensureOwnerThread();
        return self.state.npc_feature.view(id);
    }

    pub fn vitals(self: *const Simulation, target: vitals_contract.Target) ?VitalsView {
        self.state.runtime.assertOwnerThread();
        return self.state.vitals_feature.view(target);
    }

    pub fn currentVitals(
        self: *const Simulation,
        kind: vitals_contract.TargetKind,
        id: engine.PersistentId,
    ) ?VitalsView {
        self.state.runtime.assertOwnerThread();
        return self.state.vitals_feature.viewCurrent(kind, id);
    }

    pub fn save(self: *Simulation, allocator: std.mem.Allocator) ![]u8 {
        try self.state.runtime.ensureSnapshotBoundary();
        if (self.hasPendingCommands()) return error.CommandsPending;
        const crate_records = try self.state.crate_feature.snapshotRecords(allocator);
        defer allocator.free(crate_records);
        const character_records = try self.state.character_feature.snapshotRecords(allocator);
        defer allocator.free(character_records);
        const vehicle_records = try self.state.vehicle_feature.snapshotRecords(allocator);
        defer allocator.free(vehicle_records);
        const district_records = try self.state.district_feature.snapshotRecords(allocator);
        defer allocator.free(district_records);
        const interaction_records = try self.state.interaction_feature.snapshotRecords(allocator);
        defer allocator.free(interaction_records);
        const npc_records = try self.state.npc_feature.snapshotRecords(allocator);
        defer allocator.free(npc_records);
        const vitals_records = try self.state.vitals_feature.snapshotRecords(allocator);
        defer allocator.free(vitals_records);
        const npc_encounter_records = try self.state.npc_encounter_feature.snapshotRecords(
            allocator,
        );
        defer allocator.free(npc_encounter_records);
        const npc_replacement_records = try self.state.npc_replacement_policy.snapshotRecords(
            allocator,
        );
        defer allocator.free(npc_replacement_records);
        return simulation_snapshot.encode(allocator, .{
            .schema_version = simulation_snapshot.schema_version,
            .completed_ticks = self.state.runtime.tickIndex(),
            .fixed_delta_seconds = self.state.runtime.fixedDelta(),
            .namespace = self.state.runtime.namespace(),
            .next_local_id = try self.state.runtime.nextLocalId(),
            .character_config = characters.CharacterConfigV1.fromConfig(
                self.state.character_feature.config,
            ),
            .vehicle_config = vehicles.VehicleConfigV1.fromConfig(
                self.state.vehicle_feature.config,
            ),
            .interaction_config = interactions.InteractionConfigV1.fromConfig(
                self.state.interaction_feature.config,
            ),
            .npc_config = npcs.NpcConfigV1.fromConfig(self.state.npc_feature.config),
            .npc_encounter_config = simulation_snapshot.NpcEncounterConfigV1.fromConfig(
                self.state.npc_encounter_feature.config,
            ),
            .crates = crate_records,
            .characters = character_records,
            .vehicles = vehicle_records,
            .districts = district_records,
            .interactions = interaction_records,
            .npcs = npc_records,
            .npc_encounters = npc_encounter_records,
            .npc_replacements = npc_replacement_records,
            .vitals = vitals_records,
        }, .{
            .max_crates = self.state.config.max_crates,
            .max_characters = self.state.config.character.max_characters,
            .max_vehicles = self.state.config.vehicle.max_vehicles,
            .max_npcs = npcs.max_npcs,
        });
    }

    pub fn crateCount(self: *const Simulation) usize {
        self.state.runtime.assertOwnerThread();
        return self.state.crate_feature.count();
    }

    pub fn characterCount(self: *const Simulation) usize {
        self.state.runtime.assertOwnerThread();
        return self.state.character_feature.count();
    }

    pub fn vehicleCount(self: *const Simulation) usize {
        self.state.runtime.assertOwnerThread();
        return self.state.vehicle_feature.count();
    }

    pub fn districtCount(self: *const Simulation) usize {
        self.state.runtime.assertOwnerThread();
        return self.state.district_feature.count();
    }

    pub fn interactionCount(self: *const Simulation) usize {
        self.state.runtime.assertOwnerThread();
        return self.state.interaction_feature.count();
    }

    pub fn npcCount(self: *const Simulation) usize {
        self.state.runtime.assertOwnerThread();
        return self.state.npc_feature.count();
    }

    pub fn districtBodyCount(self: *const Simulation) usize {
        self.state.runtime.assertOwnerThread();
        return self.state.district_feature.bodyCount();
    }

    pub fn activeDistrictTicketFor(
        self: *const Simulation,
        coord: ChunkCoord,
    ) ?LoadTicket {
        self.state.runtime.assertOwnerThread();
        return self.state.district_feature.activeTicketFor(coord);
    }

    pub fn districtStateFor(
        self: *const Simulation,
        coord: ChunkCoord,
    ) ?DistrictStateTag {
        self.state.runtime.assertOwnerThread();
        return self.state.district_feature.stateForCoord(coord);
    }

    pub fn entityCount(self: *const Simulation) usize {
        self.state.runtime.assertOwnerThread();
        return self.state.runtime.entityCount();
    }

    pub fn bodyCount(self: *const Simulation) u32 {
        self.state.runtime.assertOwnerThread();
        return self.state.bodies.bodyCount();
    }

    /// Adapter diagnostic used by S0 characterization, not feature policy.
    pub fn activeBodyCount(self: *Simulation) u32 {
        self.state.runtime.assertOwnerThread();
        return self.state.bodies.activeBodyCount();
    }

    pub fn tickIndex(self: *const Simulation) u64 {
        self.state.runtime.assertOwnerThread();
        return self.state.runtime.tickIndex();
    }

    pub fn requiredDigestIdentityCapacity(self: *const Simulation) usize {
        self.state.runtime.assertOwnerThread();
        return self.state.config.max_crates +
            self.state.config.character.max_characters +
            self.state.config.vehicle.max_vehicles + districts.max_districts +
            interactions.max_carryables + npcs.max_npcs;
    }

    /// Hash the complete backend-neutral logical state at a completed-tick
    /// boundary. Every category has an independent digest so replay can report
    /// the first useful ownership boundary rather than only a monolithic hash.
    pub fn logicalDigests(
        self: *Simulation,
        scratch: *DigestScratch,
    ) !engine.contracts.replay.TickDigests {
        try self.state.runtime.ensureSnapshotBoundary();
        if (scratch.identities.len < self.requiredDigestIdentityCapacity()) {
            return error.InsufficientLogicalStateScratch;
        }

        var runtime_writer = engine.contracts.replay.Writer.init();
        const runtime_domain = "incinerator.runtime.logical";
        runtime_writer.writeU8(@intCast(runtime_domain.len));
        runtime_writer.writeBytes(runtime_domain);
        runtime_writer.writeU16(1);
        runtime_writer.writeU64(self.state.runtime.tickIndex());
        try runtime_writer.writeF32(self.state.runtime.fixedDelta());
        runtime_writer.writeU64(self.state.runtime.namespace());
        const next_local_id = self.state.runtime.nextLocalId() catch |err| switch (err) {
            error.IdentitySourceExhausted => null,
            else => return err,
        };
        runtime_writer.writeBool(next_local_id != null);
        if (next_local_id) |value| runtime_writer.writeU64(value);
        const persistent_ids = try self.state.runtime.copyPersistentIds(
            scratch.identities,
        );
        runtime_writer.writeU32(std.math.cast(u32, persistent_ids.len) orelse
            return error.LogicalStateCountOverflow);
        for (persistent_ids) |id| {
            runtime_writer.writeU64(id.namespace);
            runtime_writer.writeU64(id.local);
        }

        var crate_writer = engine.contracts.replay.Writer.init();
        try self.state.crate_feature.writeLogicalState(
            &crate_writer,
            scratch.identities,
        );
        var character_writer = engine.contracts.replay.Writer.init();
        try self.state.character_feature.writeLogicalState(
            &character_writer,
            scratch.identities,
        );
        var vehicle_writer = engine.contracts.replay.Writer.init();
        try self.state.vehicle_feature.writeLogicalState(
            &vehicle_writer,
            scratch.identities,
        );
        var district_writer = engine.contracts.replay.Writer.init();
        try self.state.district_feature.writeLogicalState(
            &district_writer,
            scratch.identities,
        );
        var interaction_writer = engine.contracts.replay.Writer.init();
        try self.state.interaction_feature.writeLogicalState(&interaction_writer);
        var npc_writer = engine.contracts.replay.Writer.init();
        try self.state.npc_feature.writeLogicalState(&npc_writer);
        var npc_encounter_writer = engine.contracts.replay.Writer.init();
        try self.state.npc_encounter_feature.writeLogicalState(&npc_encounter_writer);
        self.state.npc_replacement_policy.writeLogicalState(&npc_encounter_writer);

        return .{
            .tick_index = self.state.runtime.tickIndex(),
            .runtime = runtime_writer.final(),
            .crate = crate_writer.final(),
            .character = character_writer.final(),
            .vehicle = vehicle_writer.final(),
            .district = district_writer.final(),
            .interaction = interaction_writer.final(),
            .npc = npc_writer.final(),
            .npc_encounter = npc_encounter_writer.final(),
        };
    }

    pub fn diagnostics(self: *Simulation) Diagnostics {
        self.state.runtime.assertOwnerThread();
        const character_diagnostics = self.state.character_feature.diagnostics();
        const npc_diagnostics = self.state.npc_feature.diagnostics();
        const native_used_count = self.state.controllers.controllerCount();
        const native_capacity_count = self.state.controllers.controllerCapacity();
        const npc_native_used_count = self.state.npc_controllers.controllerCount();
        const npc_native_capacity_count = self.state.npc_controllers.controllerCapacity();
        return simulation_diagnostics.compose(.{
            .tick_index = self.state.runtime.tickIndex(),
            .fixed_delta_seconds = self.state.runtime.fixedDelta(),
            .first_fault = self.state.runtime.firstFault(),
            .entity_count = self.state.runtime.entityCount(),
            .body_count = self.state.bodies.bodyCount(),
            .active_body_count = self.state.bodies.activeBodyCount(),
            .character_native_used = native_used_count,
            .character_native_capacity = native_capacity_count,
            .npc_native_used = npc_native_used_count,
            .npc_native_capacity = npc_native_capacity_count,
            .crates = self.state.crate_feature.diagnostics(),
            .characters = character_diagnostics,
            .vehicles = self.state.vehicle_feature.diagnostics(),
            .district = self.state.district_feature.diagnostics(),
            .interaction = self.state.interaction_feature.diagnostics(),
            .npc = npc_diagnostics,
            .npc_encounter = self.state.npc_encounter_feature.diagnostics(),
            .npc_replacement = self.state.npc_replacement_policy.diagnostics(),
            .district_worker = self.state.district_loader.diagnostics(),
        });
    }

    pub fn recordDiagnostic(
        self: *Simulation,
        entry: engine.runtime.DiagnosticEntry,
    ) engine.runtime.DiagnosticAppendResult {
        return self.state.runtime.recordDiagnostic(entry);
    }

    pub fn armDiagnosticFreeze(
        self: *Simulation,
        condition: engine.runtime.DiagnosticFreezeMatch,
    ) void {
        self.state.runtime.armDiagnosticFreeze(condition);
    }

    pub fn disarmDiagnosticFreeze(self: *Simulation) bool {
        return self.state.runtime.disarmDiagnosticFreeze();
    }

    pub fn diagnosticJournal(
        self: *const Simulation,
    ) *const engine.runtime.DiagnosticJournal {
        return self.state.runtime.diagnosticJournal();
    }

    pub fn firstFault(self: *const Simulation) ?engine.runtime.RuntimeFault {
        return self.state.runtime.firstFault();
    }

    pub fn resumeDiagnosticCapture(self: *Simulation) bool {
        return self.state.runtime.resumeDiagnosticCapture();
    }

    pub fn clearDiagnostics(self: *Simulation) void {
        self.state.runtime.clearDiagnostics();
    }
};

/// Reconstruct and verify one fully parsed exact-cohort capture. Parsing,
/// integrity, ordering, size, and compatibility checks must all complete before
/// this function acquires the process's sole Flecs world lease.
pub fn replayCapture(
    allocator: std.mem.Allocator,
    capture: sandbox_replay.CaptureView,
    expected_content: sandbox_replay.ContentCohort,
) !ReplayResult {
    try capture.validate(.{});
    try capture.validateCompatible(expected_content);

    const config = try simulation_snapshot.configFromReplayWorld(capture.world);
    var simulation = try Simulation.initOwnedUnfrozen(
        allocator,
        config,
        1,
        0,
        .replay,
    );
    simulation.state.runtime.finishRegistration();
    defer simulation.deinit();

    var scratch = try DigestScratch.init(
        allocator,
        simulation.requiredDigestIdentityCapacity(),
    );
    defer scratch.deinit();

    var cursor = try sandbox_replay.ReplayCursor.init(capture);
    for (cursor.bootstrap()) |record| {
        if (record.eligible_tick != 1) return error.InvalidReplayBootstrapTick;
        try submitNormalized(&simulation, record.command);
    }

    while (cursor.next()) |batch| {
        const expected_tick = try std.math.add(u64, simulation.tickIndex(), 1);
        if (batch.tick_index != expected_tick) return error.ReplayTickDiscontinuity;
        for (batch.commands) |record| {
            if (record.eligible_tick != batch.tick_index) {
                return error.InvalidReplayCommandTick;
            }
            try submitNormalized(&simulation, record.command);
        }
        if (batch.district_ingress.len > 1) {
            return error.MultipleDistrictCompletionsPerTick;
        }
        if (batch.district_ingress.len == 1) {
            const ingress = batch.district_ingress[0];
            try simulation.state.district_loader.scheduleReplayCompletion(.{
                .tick_index = ingress.consumption_tick,
                .completion = ingress.completion,
            });
        }

        try simulation.tick();
        const loader = simulation.state.district_loader.observation();
        if (loader.issue != null) return error.ReplayDistrictLoaderIssue;
        if (loader.scheduled_tick != null and
            loader.scheduled_tick.? <= batch.tick_index)
        {
            return error.ReplayDistrictCompletionNotConsumed;
        }

        const actual = try simulation.logicalDigests(&scratch);
        if (sandbox_replay.firstDivergence(batch.expected_digests, actual)) |divergence| {
            return .{ .divergent = divergence };
        }
        _ = simulation.drainReplayBoundaryOutputs();
    }

    return .{ .matched = .{ .completed_ticks = simulation.tickIndex() } };
}

fn submitNormalized(
    simulation: *Simulation,
    command: sandbox_replay.NormalizedCommand,
) !void {
    switch (command) {
        .crate => |value| try simulation.submit(value),
        .character => |value| try simulation.submitCharacter(value),
        .vehicle => |value| try simulation.submitVehicle(value),
        .district => |value| try simulation.submitDistrict(value.toFeature(.{})),
        .interaction => |value| try simulation.submitInteraction(value),
        .npc => |value| try simulation.submitNpc(value),
        .vitals => |value| try simulation.submitVitals(value),
        .npc_replacement => |value| switch (value) {
            .schedule => |schedule| try simulation.scheduleNpcReplacement(
                schedule.slot,
                schedule.generation,
                schedule.death_tick,
                schedule.candidates[0..schedule.candidate_count],
            ),
            .complete => |correlation| try simulation.completeNpcReplacement(
                correlation.slot,
                correlation.generation,
            ),
            .defer_spawn => |correlation| try simulation.deferNpcReplacement(
                correlation.slot,
                correlation.generation,
            ),
        },
    }
}

fn validateNpcLimit(max_npcs: usize) !void {
    if (max_npcs != npcs.max_npcs) return error.InvalidNpcLimit;
}

fn validateVirtualCharacterBudget(max_characters: usize, max_npcs: usize) !void {
    const required = std.math.add(usize, max_characters, max_npcs) catch
        return error.VirtualCharacterCapacityExceeded;
    if (required > jolt.max_virtual_characters) {
        return error.VirtualCharacterCapacityExceeded;
    }
}

fn validatePhysicsBodyBudget(config: Config) !void {
    var required = std.math.add(usize, config.max_crates, config.vehicle.max_vehicles) catch
        return error.PhysicsBodyBudgetExceeded;
    required = std.math.add(
        usize,
        required,
        district_contract.max_static_boxes * districts.max_districts,
    ) catch
        return error.PhysicsBodyBudgetExceeded;
    required = std.math.add(usize, required, interactions.max_carryables) catch
        return error.PhysicsBodyBudgetExceeded;
    if (config.create_ground) {
        required = std.math.add(usize, required, 1) catch
            return error.PhysicsBodyBudgetExceeded;
    }
    if (config.block != null) {
        required = std.math.add(usize, required, 1) catch
            return error.PhysicsBodyBudgetExceeded;
    }
    if (required > jolt.max_bodies) return error.PhysicsBodyBudgetExceeded;
}

fn stepPhysics(
    raw: *anyopaque,
    _: *engine.Runtime,
    tick: engine.TickContext,
) !void {
    const stepper: *jolt.PhysicsStepper = @ptrCast(@alignCast(raw));
    try stepper.step(tick.delta_seconds);
}

fn debugRaised(position: [3]f32, amount: f32) [3]f32 {
    return .{ position[0], position[1] + amount, position[2] };
}

fn appendDebugLine(
    storage: *engine.physics_debug.Storage,
    start: [3]f32,
    end: [3]f32,
    color: engine.physics_debug.Color,
    object: engine.physics_debug.ObjectRef,
) void {
    _ = storage.addLine(.{
        .category = .bounds,
        .start = start,
        .end = end,
        .color = color,
        .object = object,
    });
}

fn appendDebugCircle(
    storage: *engine.physics_debug.Storage,
    center: [3]f32,
    radius: f32,
    segments: u8,
    color: engine.physics_debug.Color,
    object: engine.physics_debug.ObjectRef,
) void {
    std.debug.assert(segments >= 3);
    var index: u8 = 0;
    while (index < segments) : (index += 1) {
        const first_angle = 2.0 * std.math.pi *
            (@as(f32, @floatFromInt(index)) / @as(f32, @floatFromInt(segments)));
        const second_angle = 2.0 * std.math.pi *
            (@as(f32, @floatFromInt(index + 1)) / @as(f32, @floatFromInt(segments)));
        appendDebugLine(
            storage,
            .{
                center[0] + @sin(first_angle) * radius,
                center[1],
                center[2] - @cos(first_angle) * radius,
            },
            .{
                center[0] + @sin(second_angle) * radius,
                center[1],
                center[2] - @cos(second_angle) * radius,
            },
            color,
            object,
        );
    }
}

fn appendDebugSightCone(
    storage: *engine.physics_debug.Storage,
    center: [3]f32,
    facing_yaw: f32,
    minimum_cos: f32,
    radius: f32,
    object: engine.physics_debug.ObjectRef,
) void {
    const half_angle = std.math.acos(minimum_cos);
    inline for (.{ -1.0, 1.0 }) |sign| {
        const angle = facing_yaw + sign * half_angle;
        appendDebugLine(
            storage,
            center,
            .{
                center[0] + @sin(angle) * radius,
                center[1],
                center[2] - @cos(angle) * radius,
            },
            .{ 0.15, 0.85, 1.0, 1.0 },
            object,
        );
    }
}

fn appendDebugCross(
    storage: *engine.physics_debug.Storage,
    center: [3]f32,
    radius: f32,
    color: engine.physics_debug.Color,
    object: engine.physics_debug.ObjectRef,
) void {
    appendDebugLine(
        storage,
        .{ center[0] - radius, center[1], center[2] },
        .{ center[0] + radius, center[1], center[2] },
        color,
        object,
    );
    appendDebugLine(
        storage,
        .{ center[0], center[1], center[2] - radius },
        .{ center[0], center[1], center[2] + radius },
        color,
        object,
    );
}

test "simulation type composes crate and character features with Jolt" {
    comptime engine.physics.assertImplementation(jolt.CrateBodies);
    comptime engine.physics.assertWorldStepImplementation(jolt.PhysicsStepper);
    comptime engine.physics.assertCharacterImplementation(jolt.CharacterControllers);
    comptime if (@hasDecl(jolt.CrateBodies, "step")) {
        @compileError("crate capability must not own the shared physics step");
    };
    _ = Simulation;
}

test "simulation diagnostics compose typed feature queues and adapter counts" {
    var simulation = try Simulation.init(std.testing.allocator, .{
        .namespace = 7014,
        .max_crates = 2,
        .create_ground = false,
    });
    defer simulation.deinit();

    var snapshot = simulation.diagnostics();
    try std.testing.expectEqual(@as(u64, 0), snapshot.tick_index);
    try std.testing.expectEqual(@as(f32, 1.0 / 60.0), snapshot.fixed_delta_seconds);
    try std.testing.expect(snapshot.first_fault == null);
    try std.testing.expectEqual(@as(u32, 0), snapshot.entity_count);
    try std.testing.expectEqual(@as(u32, 0), snapshot.body_count);
    try std.testing.expectEqual(@as(u32, 0), snapshot.active_body_count);
    try std.testing.expectEqual(@as(u32, 0), snapshot.character_controllers.native_used);
    try std.testing.expectEqual(
        @as(u32, jolt.max_virtual_characters),
        snapshot.character_controllers.native_capacity,
    );
    try std.testing.expectEqual(@as(u32, 0), snapshot.character_controllers.feature_owned);
    try std.testing.expect(snapshot.character_controllers.authority_consistent);
    try std.testing.expectEqual(
        district_worker_contract.WorkerState.idle,
        snapshot.district_worker.state,
    );

    try simulation.submit(.{ .spawn = .{ .request_id = 1, .pose = .{} } });
    try simulation.submit(.{ .spawn = .{ .request_id = 2, .pose = .{} } });
    snapshot = simulation.diagnostics();
    try std.testing.expectEqual(@as(u32, 2), snapshot.crates.commands.occupancy);
    try std.testing.expectEqual(@as(u32, 2), snapshot.crates.commands.high_water);

    try simulation.tick();
    snapshot = simulation.diagnostics();
    try std.testing.expectEqual(@as(u64, 1), snapshot.tick_index);
    try std.testing.expectEqual(@as(u32, 2), snapshot.entity_count);
    try std.testing.expectEqual(@as(u32, 2), snapshot.body_count);
    try std.testing.expectEqual(@as(u32, 2), snapshot.active_body_count);
    try std.testing.expectEqual(@as(u32, 2), snapshot.crates.active_count);
    try std.testing.expectEqual(@as(u32, 2), snapshot.crates.outcomes.occupancy);

    _ = simulation.pollOutcome() orelse return error.MissingOutcome;
    snapshot = simulation.diagnostics();
    try std.testing.expectEqual(@as(u32, 1), snapshot.crates.outcomes.occupancy);
    try std.testing.expectEqual(@as(u32, 2), snapshot.crates.outcomes.high_water);

    try simulation.submitCharacter(.{ .spawn = .{
        .request_id = 3,
        .position = .{ 0, 1, 0 },
    } });
    try simulation.tick();
    const character_id = switch (simulation.pollCharacterOutcome() orelse
        return error.MissingCharacterOutcome) {
        .spawned => |value| value.id,
        else => return error.UnexpectedCharacterOutcome,
    };
    snapshot = simulation.diagnostics();
    try std.testing.expectEqual(@as(u32, 1), snapshot.character_controllers.native_used);
    try std.testing.expectEqual(@as(u32, 1), snapshot.character_controllers.feature_owned);
    try std.testing.expect(snapshot.character_controllers.authority_consistent);

    try simulation.submitCharacter(.{ .despawn = .{ .id = character_id } });
    try simulation.tick();
    _ = simulation.pollCharacterOutcome() orelse return error.MissingCharacterOutcome;
    snapshot = simulation.diagnostics();
    try std.testing.expectEqual(@as(u32, 0), snapshot.character_controllers.native_used);
    try std.testing.expectEqual(@as(u32, 0), snapshot.character_controllers.feature_owned);
    try std.testing.expect(snapshot.character_controllers.authority_consistent);

    simulation.armDiagnosticFreeze(.{
        .severity = .info,
        .category = .host,
        .code = 0x7001,
    });
    const append = simulation.recordDiagnostic(.{
        .severity = .info,
        .category = .host,
        .code = 0x7001,
        .thread_role = .simulation,
    });
    try std.testing.expect(append.accepted);
    try std.testing.expect(append.froze);
    try std.testing.expect(!simulation.diagnosticJournal().stats().trigger_armed);
    try std.testing.expectEqual(@as(usize, 1), simulation.diagnosticJournal().stats().count);
    simulation.clearDiagnostics();
    try std.testing.expectEqual(@as(usize, 0), simulation.diagnosticJournal().stats().count);
    try std.testing.expect(simulation.diagnosticJournal().stats().frozen);
    try std.testing.expect(simulation.resumeDiagnosticCapture());
    try std.testing.expect(!simulation.diagnosticJournal().stats().frozen);
    simulation.armDiagnosticFreeze(.{ .code = 0x7002 });
    try std.testing.expect(simulation.diagnosticJournal().stats().trigger_armed);
    try std.testing.expect(simulation.disarmDiagnosticFreeze());
    try std.testing.expect(!simulation.diagnosticJournal().stats().trigger_armed);
    try std.testing.expect(simulation.firstFault() == null);
}

test "replay boundary explicitly drains every consumable output lane" {
    var simulation = try Simulation.init(std.testing.allocator, .{
        .namespace = 0x5242_4401,
        .max_crates = 1,
        .create_ground = false,
    });
    defer simulation.deinit();

    try simulation.submit(.{ .spawn = .{ .request_id = 1, .pose = .{} } });
    try simulation.tick();
    const drained = simulation.drainReplayBoundaryOutputs();
    try std.testing.expectEqual(@as(u32, 1), drained.crate_outcomes);
    try std.testing.expectEqual(@as(u32, 1), drained.total());
    try std.testing.expectEqual(@as(u32, 0), simulation.drainReplayBoundaryOutputs().total());
}

fn testContentCohort(
    source_digest: sandbox_replay.Digest,
    integrity_digest: sandbox_replay.Digest,
) !sandbox_replay.ContentCohort {
    return sandbox_replay.ContentCohort.init(
        "district/simulation-test-catalog",
        sandbox_replay.current_catalog_format_version,
        sandbox_replay.current_catalog_schema_cohort,
        sandbox_district_recipe.current_recipe_version,
        source_digest,
        integrity_digest,
    );
}

test "cold flight capture replays and reports the first altered crate tick" {
    const allocator = std.testing.allocator;
    const content = try testContentCohort(
        [_]u8{0x31} ** 32,
        [_]u8{0x72} ** 32,
    );
    var encoded: []u8 = undefined;
    {
        var simulation = try Simulation.init(allocator, .{
            .namespace = 7_701,
            .max_crates = 4,
            .create_ground = false,
        });
        defer simulation.deinit();
        const admission = try simulation.beginFlightRecording(content, .{});
        try std.testing.expect(admission == .admitted);
        try simulation.submit(.{ .spawn = .{
            .request_id = 41,
            .pose = .{ .position = .{ 0, 4, 0 } },
        } });
        try simulation.tick();
        encoded = try simulation.finishFlightRecording(allocator);
    }
    defer allocator.free(encoded);

    var parsed = try sandbox_replay.parseCompatible(allocator, encoded, content);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.bootstrap_commands.len);
    try std.testing.expectEqual(@as(usize, 1), parsed.tick_digests.len);

    // Structural and cohort rejection must happen before replay attempts to
    // acquire the process's one Flecs world lease.
    {
        var blocker = try Simulation.init(allocator, .{
            .namespace = 7_799,
            .create_ground = false,
        });
        defer blocker.deinit();
        const incompatible_content = try testContentCohort(
            [_]u8{0xa1} ** 32,
            [_]u8{0xb2} ** 32,
        );
        try std.testing.expectError(
            error.IncompatibleContentCohort,
            replayCapture(allocator, parsed.view(), incompatible_content),
        );
        var hostile = parsed.view();
        hostile.world.max_characters = std.math.maxInt(u32);
        try std.testing.expectError(
            error.WorldCapacityOutOfRange,
            replayCapture(allocator, hostile, content),
        );
    }

    const matched = try replayCapture(allocator, parsed.view(), content);
    try std.testing.expect(matched == .matched);
    try std.testing.expectEqual(@as(u64, 1), matched.matched.completed_ticks);

    const original = parsed.bootstrap_commands[0].command.crate.spawn;
    var altered = original;
    altered.pose.position[0] = 1;
    parsed.bootstrap_commands[0].command = .{ .crate = .{ .spawn = altered } };
    const divergent = try replayCapture(allocator, parsed.view(), content);
    try std.testing.expect(divergent == .divergent);
    try std.testing.expectEqual(@as(u64, 1), divergent.divergent.tick_index);
    try std.testing.expectEqual(
        engine.contracts.replay.Category.crate,
        divergent.divergent.category.?,
    );
}

test "captured exact crate relocation replays and reports tick two crate divergence" {
    const allocator = std.testing.allocator;
    const content = try testContentCohort(
        [_]u8{0x45} ** 32,
        [_]u8{0xa7} ** 32,
    );
    const target_pose: engine.physics.Pose = .{
        .position = .{ 7.5, 12.25, -3.75 },
    };
    const target_velocity: engine.physics.Velocity = .{
        .linear = .{ 3.5, 1.25, -2.0 },
        .angular = .{ 0.25, -0.5, 0.75 },
    };

    var encoded: []u8 = undefined;
    {
        var simulation = try Simulation.init(allocator, .{
            .namespace = 7_711,
            .max_crates = 2,
            .create_ground = false,
        });
        defer simulation.deinit();
        try std.testing.expect(
            (try simulation.beginFlightRecording(content, .{})) == .admitted,
        );

        try simulation.submit(.{ .spawn = .{
            .request_id = 51,
            .pose = .{ .position = .{ 0, 4, 0 } },
            .velocity = .{ .linear = .{ 0.5, -1, 0.25 } },
        } });
        try simulation.tick();
        const id = switch (simulation.pollOutcome() orelse return error.MissingOutcome) {
            .spawned => |spawned| spawned.id,
            else => return error.UnexpectedOutcome,
        };
        try std.testing.expect(simulation.pollOutcome() == null);

        try simulation.submit(.{ .relocate = .{
            .transaction_id = 61,
            .id = id,
            .target_pose = target_pose,
            .velocity = .{ .exact = target_velocity },
            .expected_revision = 0,
        } });
        try simulation.tick();
        const relocated = switch (simulation.pollOutcome() orelse return error.MissingOutcome) {
            .relocated => |value| value,
            else => return error.UnexpectedOutcome,
        };
        try std.testing.expectEqual(@as(u64, 61), relocated.transaction_id);
        try std.testing.expectEqual(id, relocated.id);
        try std.testing.expectEqual(@as(u64, 1), relocated.committed_revision);
        try std.testing.expectEqual(target_pose, relocated.after.pose);
        try std.testing.expectEqual(target_velocity, relocated.after.velocity);
        try std.testing.expect(simulation.pollOutcome() == null);

        const authoritative = try simulation.crate(id);
        try std.testing.expectEqual(@as(u64, 1), authoritative.authoring_revision);
        try std.testing.expectEqual(target_pose, authoritative.state.pose);
        try std.testing.expectEqual(target_velocity, authoritative.state.velocity);
        encoded = try simulation.finishFlightRecording(allocator);
    }
    defer allocator.free(encoded);

    var parsed = try sandbox_replay.parseCompatible(allocator, encoded, content);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.bootstrap_commands.len);
    try std.testing.expectEqual(@as(usize, 1), parsed.commands.len);
    try std.testing.expectEqual(@as(usize, 2), parsed.tick_digests.len);
    try std.testing.expectEqual(@as(u64, 2), parsed.commands[0].eligible_tick);
    try std.testing.expect(parsed.commands[0].command == .crate);
    try std.testing.expect(parsed.commands[0].command.crate == .relocate);

    const recorded = parsed.commands[0].command.crate.relocate;
    try std.testing.expectEqual(@as(u64, 61), recorded.transaction_id);
    try std.testing.expectEqual(@as(?u64, 0), recorded.expected_revision);
    try std.testing.expectEqual(target_pose, recorded.target_pose);
    try std.testing.expect(recorded.velocity == .exact);
    try std.testing.expectEqual(target_velocity, recorded.velocity.exact);

    const matched = try replayCapture(allocator, parsed.view(), content);
    try std.testing.expect(matched == .matched);
    try std.testing.expectEqual(@as(u64, 2), matched.matched.completed_ticks);

    var altered = recorded;
    var altered_velocity = target_velocity;
    altered_velocity.linear[0] += 1;
    altered.velocity = .{ .exact = altered_velocity };
    parsed.commands[0].command = .{ .crate = .{ .relocate = altered } };

    const divergent = try replayCapture(allocator, parsed.view(), content);
    try std.testing.expect(divergent == .divergent);
    try std.testing.expectEqual(
        sandbox_replay.DivergenceKind.category_digest,
        divergent.divergent.kind,
    );
    try std.testing.expectEqual(@as(u64, 2), divergent.divergent.tick_index);
    try std.testing.expectEqual(
        engine.contracts.replay.Category.crate,
        divergent.divergent.category.?,
    );
}

test "recorder saturation never fails live authority" {
    const allocator = std.testing.allocator;
    const content = try testContentCohort(
        [_]u8{0x19} ** 32,
        [_]u8{0x91} ** 32,
    );
    var encoded: []u8 = undefined;
    {
        var simulation = try Simulation.init(allocator, .{
            .namespace = 7_702,
            .create_ground = false,
        });
        defer simulation.deinit();
        const admission = try simulation.beginFlightRecording(content, .{
            .max_bootstrap = 0,
        });
        try std.testing.expect(admission == .admitted);
        try simulation.submit(.{ .spawn = .{
            .request_id = 1,
            .pose = .{ .position = .{ 0, 2, 0 } },
        } });
        try std.testing.expectEqual(
            sandbox_replay.IncompleteReason.bootstrap_capacity,
            simulation.flightRecordingIncompleteReason().?,
        );
        try simulation.tick();
        try std.testing.expectEqual(@as(u64, 1), simulation.tickIndex());
        try std.testing.expectEqual(@as(usize, 1), simulation.crateCount());
        encoded = try simulation.finishFlightRecording(allocator);
    }
    defer allocator.free(encoded);

    var parsed = try sandbox_replay.parse(allocator, encoded);
    defer parsed.deinit();
    try std.testing.expectEqual(
        sandbox_replay.IncompleteReason.bootstrap_capacity,
        parsed.incomplete_reason.?,
    );
    try std.testing.expectError(
        error.IncompleteCapture,
        parsed.validateCompatible(content),
    );
}

test "unread outputs mark capture incomplete without stopping the next tick" {
    const allocator = std.testing.allocator;
    const content = try testContentCohort(
        [_]u8{0x28} ** 32,
        [_]u8{0x82} ** 32,
    );
    var encoded: []u8 = undefined;
    {
        var simulation = try Simulation.init(allocator, .{
            .namespace = 7_703,
            .create_ground = false,
        });
        defer simulation.deinit();
        try std.testing.expect(
            (try simulation.beginFlightRecording(content, .{})) == .admitted,
        );
        try simulation.submit(.{ .spawn = .{
            .request_id = 1,
            .pose = .{ .position = .{ 0, 2, 0 } },
        } });
        try simulation.tick();
        // Deliberately leave the spawn outcome unread. Capture policy is lost,
        // but the single-player authority still advances normally.
        try simulation.tick();
        try std.testing.expectEqual(@as(u64, 2), simulation.tickIndex());
        try std.testing.expectEqual(@as(usize, 1), simulation.crateCount());
        try std.testing.expectEqual(
            sandbox_replay.IncompleteReason.output_policy_violated,
            simulation.flightRecordingIncompleteReason().?,
        );
        encoded = try simulation.finishFlightRecording(allocator);
    }
    defer allocator.free(encoded);
    var parsed = try sandbox_replay.parse(allocator, encoded);
    defer parsed.deinit();
    try std.testing.expectEqual(
        sandbox_replay.IncompleteReason.output_policy_violated,
        parsed.incomplete_reason.?,
    );
}

test "faulted capture remains inspectable and later admission is typed" {
    const allocator = std.testing.allocator;
    const content = try testContentCohort(
        [_]u8{0x47} ** 32,
        [_]u8{0x74} ** 32,
    );
    const Injected = struct {
        fn fail(
            _: *anyopaque,
            _: *engine.Runtime,
            _: engine.TickContext,
        ) !void {
            return error.InjectedReplayFault;
        }
    };

    var simulation = try Simulation.initOwnedUnfrozen(
        allocator,
        .{ .namespace = 7_704, .create_ground = false },
        1,
        0,
        .live,
    );
    defer simulation.deinit();
    var injected_context: u8 = 0;
    var registry = simulation.state.runtime.registry();
    try registry.addSystem(
        .commands,
        "test.injected_replay_fault",
        &injected_context,
        Injected.fail,
    );
    simulation.state.runtime.finishRegistration();

    try std.testing.expect(
        (try simulation.beginFlightRecording(content, .{})) == .admitted,
    );
    try std.testing.expectError(error.InjectedReplayFault, simulation.tick());
    try std.testing.expectEqual(
        sandbox_replay.IncompleteReason.authority_failed,
        simulation.flightRecordingIncompleteReason().?,
    );
    const encoded = try simulation.finishFlightRecording(allocator);
    defer allocator.free(encoded);
    var parsed = try sandbox_replay.parse(allocator, encoded);
    defer parsed.deinit();
    try std.testing.expectEqual(
        sandbox_replay.IncompleteReason.authority_failed,
        parsed.incomplete_reason.?,
    );

    const readmission = try simulation.beginFlightRecording(content, .{});
    try std.testing.expect(readmission == .rejected);
    try std.testing.expectEqual(
        CaptureBoundaryReason.runtime_faulted,
        readmission.rejected,
    );
}

test "presentation observations between fixed ticks do not change capture" {
    const allocator = std.testing.allocator;
    const content = try testContentCohort(
        [_]u8{0x56} ** 32,
        [_]u8{0x65} ** 32,
    );
    const Capture = struct {
        fn run(
            capture_allocator: std.mem.Allocator,
            cohort: sandbox_replay.ContentCohort,
            inspect_between_ticks: bool,
        ) ![]u8 {
            var simulation = try Simulation.init(capture_allocator, .{
                .namespace = 7_705,
                .create_ground = false,
            });
            defer simulation.deinit();
            if ((try simulation.beginFlightRecording(cohort, .{})) != .admitted) {
                return error.CaptureAdmissionFailed;
            }
            try simulation.submit(.{ .spawn = .{
                .request_id = 1,
                .pose = .{ .position = .{ 0, 3, 0 } },
            } });
            try simulation.tick();
            const crate_id = simulation.pollOutcome().?.spawned.id;

            if (inspect_between_ticks) {
                // These extra host observations occur between fixed ticks;
                // no semantic command or asynchronous ingress exists here.
                _ = try simulation.presentation(0.0);
                _ = try simulation.presentation(0.25);
                _ = try simulation.presentation(0.75);
                _ = try simulation.presentation(1.0);
            }
            try simulation.submit(.{ .impulse = .{
                .id = crate_id,
                .impulse = .{ 0.5, 1.0, -0.25 },
            } });
            try simulation.tick();
            return simulation.finishFlightRecording(capture_allocator);
        }
    };

    const baseline = try Capture.run(allocator, content, false);
    defer allocator.free(baseline);
    const inspected = try Capture.run(allocator, content, true);
    defer allocator.free(inspected);
    try std.testing.expectEqualSlices(u8, baseline, inspected);
}

test "simulation diagnostics retain the first structured runtime fault" {
    const Injected = struct {
        fn fail(
            _: *anyopaque,
            _: *engine.Runtime,
            _: engine.TickContext,
        ) !void {
            return error.InjectedStructuredDiagnosticsFault;
        }
    };

    var simulation = try Simulation.initOwnedUnfrozen(
        std.testing.allocator,
        .{ .namespace = 7015, .create_ground = false },
        1,
        0,
        .live,
    );
    defer simulation.deinit();
    var injected_context: u8 = 0;
    var registry = simulation.state.runtime.registry();
    try registry.addSystem(
        .commands,
        "test.injected_structured_diagnostics_fault",
        &injected_context,
        Injected.fail,
    );
    simulation.state.runtime.finishRegistration();

    try std.testing.expectError(
        error.InjectedStructuredDiagnosticsFault,
        simulation.tick(),
    );

    const snapshot = simulation.diagnostics();
    const fault = snapshot.first_fault orelse return error.RuntimeFaultMissing;
    try std.testing.expectEqual(engine.Phase.commands, fault.phase);
    try std.testing.expectEqual(@as(u64, 1), fault.tick_index);
    try std.testing.expectEqual(
        @intFromError(error.InjectedStructuredDiagnosticsFault),
        fault.error_code,
    );
    try std.testing.expect(fault.journal_sequence != 0);
    try std.testing.expectEqualStrings(
        "test.injected_structured_diagnostics_fault",
        fault.system_name.slice(),
    );
    try std.testing.expectEqualStrings(
        "InjectedStructuredDiagnosticsFault",
        fault.error_name.slice(),
    );
    try std.testing.expectEqualDeep(fault, simulation.firstFault().?);

    const journal = simulation.diagnosticJournal();
    try std.testing.expect(journal.stats().frozen);
    const retained_count = journal.stats().count;
    try std.testing.expect(retained_count >= 1);
    const entries = journal.borrowedChronological();
    var entry: ?*const engine.diagnostic_contracts.Entry = null;
    for (0..entries.len()) |index| {
        const candidate = entries.at(index).?;
        if (candidate.sequence == fault.journal_sequence) {
            entry = candidate;
            break;
        }
    }
    const fault_entry = entry orelse return error.RuntimeFaultJournalEntryMissing;
    try std.testing.expectEqual(fault.journal_sequence, fault_entry.sequence);
    try std.testing.expectEqual(engine.diagnostic_contracts.Severity.fatal, fault_entry.severity);
    try std.testing.expectEqual(engine.diagnostic_contracts.Category.runtime, fault_entry.category);
    try std.testing.expectEqual(
        engine.diagnostic_contracts.codes.runtime_system_fault,
        fault_entry.code,
    );
    try std.testing.expectEqual(@as(?u64, 1), fault_entry.tick_index);

    try std.testing.expectError(error.RuntimeFaulted, simulation.tick());
    try std.testing.expectEqualDeep(fault, simulation.firstFault().?);
    try std.testing.expectEqual(retained_count, simulation.diagnosticJournal().stats().count);
}

test "diagnostic fault probe exists only in its explicit composition" {
    {
        var normal = try Simulation.init(std.testing.allocator, .{
            .namespace = 7_016,
            .create_ground = false,
        });
        defer normal.deinit();
        try std.testing.expectError(
            error.DiagnosticFaultProbeUnavailable,
            normal.armDiagnosticFaultProbe(),
        );
        try normal.tick();
        try std.testing.expect(normal.firstFault() == null);
    }

    var diagnostic = try Simulation.initWithDiagnosticFaultProbe(
        std.testing.allocator,
        .{ .namespace = 7_017, .create_ground = false },
    );
    defer diagnostic.deinit();
    try diagnostic.armDiagnosticFaultProbe();
    try std.testing.expectError(
        error.DiagnosticFaultProbeAlreadyArmed,
        diagnostic.armDiagnosticFaultProbe(),
    );
    try std.testing.expectError(
        error.InjectedDeveloperDiagnosticFault,
        diagnostic.tick(),
    );
    const fault = diagnostic.firstFault() orelse return error.RuntimeFaultMissing;
    try std.testing.expectEqual(engine.Phase.commands, fault.phase);
    try std.testing.expectEqual(@as(u64, 1), fault.tick_index);
    try std.testing.expectEqual(
        @intFromError(error.InjectedDeveloperDiagnosticFault),
        fault.error_code,
    );
    try std.testing.expectEqualStrings(
        "diagnostics.injected_fault_probe",
        fault.system_name.slice(),
    );
    try std.testing.expectEqualStrings(
        "InjectedDeveloperDiagnosticFault",
        fault.error_name.slice(),
    );
    try std.testing.expectError(error.RuntimeFaulted, diagnostic.tick());
    try std.testing.expectEqualDeep(fault, diagnostic.firstFault().?);
}

test "composition rejects an impossible Jolt body budget before acquiring a world" {
    try std.testing.expectError(
        error.PhysicsBodyBudgetExceeded,
        Simulation.init(std.testing.allocator, .{
            .namespace = 7011,
            .max_crates = jolt.max_bodies,
        }),
    );
    var usable = try Simulation.init(std.testing.allocator, .{ .namespace = 7012 });
    defer usable.deinit();
}

test "composition rejects fallible district submission from a non-owner thread" {
    var simulation = try Simulation.init(std.testing.allocator, .{ .namespace = 7013 });
    defer simulation.deinit();
    var rejected = std.atomic.Value(bool).init(false);
    const Probe = struct {
        fn run(target: *Simulation, result: *std.atomic.Value(bool)) void {
            target.submitDistrict(.{ .request_load = .{
                .request_id = 1,
                .coord = .{ .x = 0, .z = -4 },
                .assets = .{},
            } }) catch |err| {
                result.store(err == error.WrongRuntimeThread, .release);
            };
        }
    };
    const thread = try std.Thread.spawn(.{}, Probe.run, .{ &simulation, &rejected });
    thread.join();
    try std.testing.expect(rejected.load(.acquire));
    try std.testing.expect(simulation.districtStateFor(.{ .x = 0, .z = -4 }) == null);
    try simulation.tick();
}

test "real Jolt character walks, jumps, and stops at the composed block" {
    var simulation = try Simulation.init(std.testing.allocator, .{
        .namespace = 71,
        .block = .{
            .position = .{ 0, 1, -5 },
            .half_extents = .{ 2, 1, 0.5 },
        },
    });
    defer simulation.deinit();

    try simulation.submitCharacter(.{ .spawn = .{
        .request_id = 1,
        .position = .{ 0, 2, 0 },
    } });
    try simulation.tick();
    const spawned = simulation.pollCharacterOutcome().?.spawned;
    while (simulation.pollCharacterOutcome() != null) {}
    while (simulation.pollCharacterEvent() != null) {}

    // Land, then drive a tick-scoped forward action into the wall.
    for (0..120) |_| try simulation.tick();
    try std.testing.expectEqual(
        engine.physics.GroundState.on_ground,
        (try simulation.character(spawned.id)).ground_state,
    );
    for (0..180) |_| {
        try simulation.submitCharacter(.{ .actions = .{
            .id = spawned.id,
            .move = .{ 0, 1 },
            .facing_yaw = 0,
        } });
        try simulation.tick();
    }
    const stopped = try simulation.character(spawned.id);
    try std.testing.expect(stopped.position[2] < -3.5);
    try std.testing.expect(stopped.position[2] > -4.2);

    try simulation.submitCharacter(.{ .actions = .{
        .id = spawned.id,
        .facing_yaw = 0,
        .jump_pressed = true,
    } });
    try simulation.tick();
    try std.testing.expect((try simulation.character(spawned.id)).position[1] > 0);
}

test "real Jolt vehicle enter drive collision exit and teardown share one world" {
    var simulation = try Simulation.init(std.testing.allocator, .{ .namespace = 91 });
    defer simulation.deinit();
    try simulation.submit(.{ .spawn = .{
        .request_id = 1,
        .pose = .{ .position = .{ 0, 0.5, -9 } },
    } });
    try simulation.submitCharacter(.{ .spawn = .{
        .request_id = 2,
        .position = .{ 0, 0, 2 },
    } });
    try simulation.submitVehicle(.{ .spawn = .{
        .request_id = 3,
        .chassis = .{ .pose = .{ .position = .{ 0, 2, 0 } } },
    } });
    try simulation.tick();
    const crate_id = simulation.pollOutcome().?.spawned.id;
    const character_id = simulation.pollCharacterOutcome().?.spawned.id;
    const vehicle_id = simulation.pollVehicleOutcome().?.spawned.id;
    while (simulation.pollCharacterEvent() != null) {}
    while (simulation.pollVehicleEvent() != null) {}

    for (0..240) |_| try simulation.tick();
    const crate_before = (try simulation.crate(crate_id)).state.pose.position;
    try simulation.submitVehicle(.{ .enter = .{
        .vehicle_id = vehicle_id,
        .driver_id = character_id,
    } });
    try simulation.tick();
    try std.testing.expectEqual(
        character_id,
        simulation.pollVehicleOutcome().?.entered.driver_id,
    );
    try std.testing.expectEqual(
        character_id,
        (try simulation.vehicle(vehicle_id)).driver_id.?,
    );
    try std.testing.expectEqual(@as(usize, 0), (try simulation.characterPresentation(1)).len);

    for (0..360) |_| {
        try simulation.submitVehicle(.{ .drive = .{
            .vehicle_id = vehicle_id,
            .driver_id = character_id,
            .input = .{ .throttle = 1 },
        } });
        try simulation.tick();
        _ = simulation.pollVehicleOutcome();
    }
    const driven = try simulation.vehicle(vehicle_id);
    const crate_after = (try simulation.crate(crate_id)).state.pose.position;
    try std.testing.expect(driven.state.chassis.pose.position[2] < -4);
    try std.testing.expect(crate_after[2] < crate_before[2] - 0.2);

    try simulation.submitVehicle(.{ .exit = .{
        .vehicle_id = vehicle_id,
        .driver_id = character_id,
    } });
    try simulation.tick();
    try std.testing.expectEqual(
        character_id,
        simulation.pollVehicleOutcome().?.exited.driver_id,
    );
    try std.testing.expect((try simulation.vehicle(vehicle_id)).driver_id == null);
    try std.testing.expectEqual(@as(usize, 1), (try simulation.characterPresentation(1)).len);

    try simulation.submit(.{ .despawn = .{ .id = crate_id } });
    try simulation.submitCharacter(.{ .despawn = .{ .id = character_id } });
    try simulation.submitVehicle(.{ .despawn = .{ .id = vehicle_id } });
    try simulation.tick();
    try std.testing.expectEqual(crate_id, simulation.pollOutcome().?.despawned);
    try std.testing.expectEqual(character_id, simulation.pollCharacterOutcome().?.despawned);
    try std.testing.expectEqual(vehicle_id, simulation.pollVehicleOutcome().?.despawned);
    try std.testing.expectEqual(@as(usize, 0), simulation.entityCount());
    try std.testing.expectEqual(@as(u32, 1), simulation.bodyCount());
}

test "NPC replacement evaluates a living driver at the occupied chassis" {
    var simulation = try Simulation.init(std.testing.allocator, .{ .namespace = 9_111 });
    defer simulation.deinit();
    try simulation.submitCharacter(.{ .spawn = .{
        .request_id = 1,
        .position = .{ 0, 0, 2 },
    } });
    try simulation.submitVehicle(.{ .spawn = .{
        .request_id = 2,
        .chassis = .{ .pose = .{ .position = .{ 0, 2, 0 } } },
    } });
    try simulation.tick();
    const character_id = simulation.pollCharacterOutcome().?.spawned.id;
    const vehicle_id = simulation.pollVehicleOutcome().?.spawned.id;
    try simulation.submitVitals(.{ .register = .{ .target = .{
        .kind = .player,
        .id = character_id,
        .incarnation = .{ .value = 1 },
    } } });
    try simulation.tick();
    _ = simulation.pollVitalsOutcome() orelse return error.VitalsRegistrationMissing;
    for (0..240) |_| try simulation.tick();

    try simulation.submitVehicle(.{ .enter = .{
        .vehicle_id = vehicle_id,
        .driver_id = character_id,
    } });
    try simulation.tick();
    _ = simulation.pollVehicleOutcome() orelse return error.VehicleEnterOutcomeMissing;
    for (0..240) |_| {
        try simulation.submitVehicle(.{ .drive = .{
            .vehicle_id = vehicle_id,
            .driver_id = character_id,
            .input = .{ .throttle = 1 },
        } });
        try simulation.tick();
        _ = simulation.pollVehicleOutcome();
    }

    const character_position = (try simulation.character(character_id)).position;
    const chassis_position = (try simulation.vehicle(vehicle_id)).state.chassis.pose.position;
    const dx = chassis_position[0] - character_position[0];
    const dz = chassis_position[2] - character_position[2];
    try std.testing.expect(dx * dx + dz * dz > 1);
    try std.testing.expectEqual(
        npc_replacement_contract.RetryReason.too_close_to_player,
        (try simulation.state.npc_replacement_access.playerConflict(
            chassis_position,
            1,
            0,
        )).?,
    );
}

test "NPC replacement treats initial and respawn vitals handoffs as occupied" {
    var simulation = try Simulation.init(std.testing.allocator, .{ .namespace = 9_112 });
    defer simulation.deinit();
    const position = [3]f32{ 4, 0, 0 };
    try simulation.submitCharacter(.{ .spawn = .{
        .request_id = 1,
        .position = position,
    } });
    try simulation.tick();
    const initial = simulation.pollCharacterOutcome().?.spawned.id;
    try std.testing.expect(
        simulation.state.vitals_feature.viewCurrent(.player, initial) == null,
    );
    try std.testing.expectEqual(
        npc_replacement_contract.RetryReason.too_close_to_player,
        (try simulation.state.npc_replacement_access.playerConflict(position, 1, 0)).?,
    );

    const initial_target = vitals_contract.Target{
        .kind = .player,
        .id = initial,
        .incarnation = .{ .value = 1 },
    };
    try simulation.submitVitals(.{ .register = .{ .target = initial_target } });
    try simulation.tick();
    _ = simulation.pollVitalsOutcome() orelse return error.VitalsRegistrationMissing;
    try simulation.submitCharacter(.{ .despawn = .{ .id = initial } });
    try simulation.submitVitals(.{ .remove = initial_target });
    try simulation.tick();
    _ = simulation.pollCharacterOutcome() orelse return error.CharacterDespawnOutcomeMissing;
    _ = simulation.pollVitalsOutcome() orelse return error.VitalsRemovalOutcomeMissing;

    try simulation.submitCharacter(.{ .spawn = .{
        .request_id = 2,
        .position = position,
    } });
    try simulation.tick();
    const respawned = simulation.pollCharacterOutcome().?.spawned.id;
    try std.testing.expect(!std.meta.eql(initial, respawned));
    try std.testing.expect(
        simulation.state.vitals_feature.viewCurrent(.player, respawned) == null,
    );
    try std.testing.expectEqual(
        npc_replacement_contract.RetryReason.too_close_to_player,
        (try simulation.state.npc_replacement_access.playerConflict(position, 1, 0)).?,
    );
}

test "same-tick character commands and vehicle authority follow declared registration order" {
    var simulation = try Simulation.init(std.testing.allocator, .{ .namespace = 911 });
    defer simulation.deinit();
    try simulation.submitCharacter(.{ .spawn = .{
        .request_id = 1,
        .position = .{ 0, 0, 0 },
    } });
    try simulation.submitVehicle(.{ .spawn = .{
        .request_id = 2,
        .chassis = .{ .pose = .{ .position = .{ 0, 2, 0 } } },
    } });
    try simulation.tick();
    const character_id = simulation.pollCharacterOutcome().?.spawned.id;
    const vehicle_id = simulation.pollVehicleOutcome().?.spawned.id;
    while (simulation.pollCharacterEvent() != null) {}
    while (simulation.pollVehicleEvent() != null) {}

    // Character commands are registered before vehicle commands. The action
    // applies while on foot, then enter clears locomotion and takes authority.
    try simulation.submitCharacter(.{ .actions = .{
        .id = character_id,
        .move = .{ 0, 1 },
        .facing_yaw = 0,
    } });
    try simulation.submitVehicle(.{ .enter = .{
        .vehicle_id = vehicle_id,
        .driver_id = character_id,
    } });
    try simulation.tick();
    try std.testing.expect(simulation.pollCharacterOutcome() == null);
    try std.testing.expectEqual(
        character_id,
        simulation.pollVehicleOutcome().?.entered.driver_id,
    );

    // On exit the same ordering rejects action/despawn while still driving;
    // only afterward does the vehicle return authority to the character.
    try simulation.submitCharacter(.{ .actions = .{
        .id = character_id,
        .move = .{ 1, 0 },
        .facing_yaw = 0,
    } });
    try simulation.submitCharacter(.{ .despawn = .{ .id = character_id } });
    try simulation.submitVehicle(.{ .exit = .{
        .vehicle_id = vehicle_id,
        .driver_id = character_id,
    } });
    try simulation.tick();
    const actions_rejected = simulation.pollCharacterOutcome().?.rejected;
    try std.testing.expectEqual(characters.CommandKind.actions, actions_rejected.command);
    try std.testing.expectEqual(characters.RejectionReason.driving, actions_rejected.reason);
    const despawn_rejected = simulation.pollCharacterOutcome().?.rejected;
    try std.testing.expectEqual(characters.CommandKind.despawn, despawn_rejected.command);
    try std.testing.expectEqual(characters.RejectionReason.driving, despawn_rejected.reason);
    try std.testing.expectEqual(
        character_id,
        simulation.pollVehicleOutcome().?.exited.driver_id,
    );
    switch ((try simulation.character(character_id)).driver_mode) {
        .on_foot => {},
        .driving => return error.CharacterAuthorityNotReturned,
    }
}

test "Snapshot V11 restores occupied and unoccupied real vehicles logically" {
    const allocator = std.testing.allocator;
    var original = try Simulation.init(allocator, .{ .namespace = 92 });
    var original_live = true;
    defer if (original_live) original.deinit();
    try original.submitCharacter(.{ .spawn = .{
        .request_id = 1,
        .position = .{ 0, 0, 2 },
    } });
    try original.submitVehicle(.{ .spawn = .{
        .request_id = 2,
        .chassis = .{ .pose = .{
            .position = .{ 0, 2, 0 },
            .rotation = .{ 0, @sin(0.15), 0, @cos(0.15) },
        } },
    } });
    try original.tick();
    const character_id = original.pollCharacterOutcome().?.spawned.id;
    const vehicle_id = original.pollVehicleOutcome().?.spawned.id;
    while (original.pollCharacterEvent() != null) {}
    for (0..240) |_| try original.tick();
    try original.submitVehicle(.{ .enter = .{
        .vehicle_id = vehicle_id,
        .driver_id = character_id,
    } });
    try original.tick();
    _ = original.pollVehicleOutcome();
    _ = original.pollVehicleEvent();
    const occupied_bytes = try original.save(allocator);
    defer allocator.free(occupied_bytes);
    original.deinit();
    original_live = false;

    var occupied = try Simulation.fromSnapshot(allocator, occupied_bytes, .{});
    var occupied_live = true;
    defer if (occupied_live) occupied.deinit();
    try std.testing.expectEqual(@as(usize, 1), occupied.characterCount());
    try std.testing.expectEqual(@as(usize, 1), occupied.vehicleCount());
    try std.testing.expectEqual(character_id, (try occupied.vehicle(vehicle_id)).driver_id.?);
    try std.testing.expectEqual(@as(usize, 0), (try occupied.characterPresentation(0)).len);
    const occupied_resaved = try occupied.save(allocator);
    defer allocator.free(occupied_resaved);
    try std.testing.expectEqualSlices(u8, occupied_bytes, occupied_resaved);

    try occupied.submitVehicle(.{ .exit = .{
        .vehicle_id = vehicle_id,
        .driver_id = character_id,
    } });
    try occupied.tick();
    _ = occupied.pollVehicleOutcome();
    _ = occupied.pollVehicleEvent();
    try std.testing.expect((try occupied.vehicle(vehicle_id)).driver_id == null);
    try std.testing.expectEqual(@as(usize, 1), (try occupied.characterPresentation(1)).len);
    const unoccupied_bytes = try occupied.save(allocator);
    defer allocator.free(unoccupied_bytes);
    occupied.deinit();
    occupied_live = false;

    var unoccupied = try Simulation.fromSnapshot(allocator, unoccupied_bytes, .{});
    defer unoccupied.deinit();
    try std.testing.expect((try unoccupied.vehicle(vehicle_id)).driver_id == null);
    const unoccupied_resaved = try unoccupied.save(allocator);
    defer allocator.free(unoccupied_resaved);
    try std.testing.expectEqualSlices(u8, unoccupied_bytes, unoccupied_resaved);
}

test "grounded snapshot restore preserves an immediate jump" {
    const allocator = std.testing.allocator;
    var snapshot_bytes: []u8 = undefined;
    var expected: CharacterView = undefined;

    {
        var original = try Simulation.init(allocator, .{ .namespace = 74 });
        defer original.deinit();
        try original.submitCharacter(.{ .spawn = .{
            .request_id = 1,
            .position = .{ 0, 0, 0 },
        } });
        try original.tick();
        const id = original.pollCharacterOutcome().?.spawned.id;
        try std.testing.expectEqual(
            engine.physics.GroundState.on_ground,
            (try original.character(id)).ground_state,
        );
        try std.testing.expect(original.pollCharacterEvent() == null);
        snapshot_bytes = try original.save(allocator);

        try original.submitCharacter(.{ .actions = .{
            .id = id,
            .facing_yaw = 0,
            .jump_pressed = true,
        } });
        try original.tick();
        expected = try original.character(id);
        const event = original.pollCharacterEvent().?.ground_state_changed;
        try std.testing.expectEqual(engine.physics.GroundState.on_ground, event.previous);
        try std.testing.expectEqual(engine.physics.GroundState.in_air, event.current);
        try std.testing.expect(original.pollCharacterEvent() == null);
    }
    defer allocator.free(snapshot_bytes);

    var restored = try Simulation.fromSnapshot(allocator, snapshot_bytes, .{});
    defer restored.deinit();
    const id = PersistentId{ .namespace = 74, .local = 1 };
    try std.testing.expectEqual(
        engine.physics.GroundState.on_ground,
        (try restored.character(id)).ground_state,
    );
    try restored.submitCharacter(.{ .actions = .{
        .id = id,
        .facing_yaw = 0,
        .jump_pressed = true,
    } });
    try restored.tick();
    const actual = try restored.character(id);
    try std.testing.expectEqual(engine.physics.GroundState.in_air, actual.ground_state);
    try std.testing.expect(actual.velocity[1] > 0);
    for (expected.position, actual.position) |expected_axis, actual_axis| {
        try std.testing.expectApproxEqAbs(expected_axis, actual_axis, 0.0001);
    }
    for (expected.velocity, actual.velocity) |expected_axis, actual_axis| {
        try std.testing.expectApproxEqAbs(expected_axis, actual_axis, 0.0001);
    }
    const event = restored.pollCharacterEvent().?.ground_state_changed;
    try std.testing.expectEqual(engine.physics.GroundState.on_ground, event.previous);
    try std.testing.expectEqual(engine.physics.GroundState.in_air, event.current);
    try std.testing.expect(restored.pollCharacterEvent() == null);
}

test "snapshot owns character tuning and preserves canonical yaw bytes" {
    const allocator = std.testing.allocator;
    const tuning = CharacterConfig{
        .radius = 0.35,
        .half_height = 0.65,
        .move_speed = 7,
        .jump_speed = 8,
        .gravity = -18,
        .terminal_fall_speed = 72,
        .max_slope_radians = 0.7,
        .mass = 82,
        .max_strength = 135,
        .stick_to_floor_distance = 0.3,
        .step_up_height = 0.25,
    };
    const tiny_yaw = std.math.nextAfter(f32, 0, 1);
    const records = [_]CharacterV1{.{
        .id = .{ .namespace = 75, .local = 1 },
        .position = .{ 0, 0, 0 },
        .velocity = .{ 0, 0, 0 },
        .facing_yaw = tiny_yaw,
    }};
    const initial = try simulation_snapshot.encode(allocator, .{
        .schema_version = simulation_snapshot.schema_version,
        .completed_ticks = 3,
        .fixed_delta_seconds = 1.0 / 120.0,
        .namespace = 75,
        .next_local_id = 2,
        .character_config = CharacterConfigV1.fromConfig(tuning),
        .vehicle_config = VehicleConfigV1.fromConfig(.{}),
        .interaction_config = InteractionConfigV1.fromConfig(.{}),
        .npc_config = NpcConfigV1.fromConfig(.{}),
        .npc_encounter_config = simulation_snapshot.NpcEncounterConfigV1.fromConfig(.{}),
        .crates = &.{},
        .characters = &records,
        .vehicles = &.{},
        .districts = &.{},
        .interactions = &.{},
        .npcs = &.{},
        .npc_encounters = &.{},
        .npc_replacements = &.{},
    }, .{ .max_characters = 2 });
    defer allocator.free(initial);

    const restore_assets = characters.Assets{
        .mesh = .{ .index = 7, .generation = 2 },
        .material = .{ .index = 8, .generation = 3 },
    };
    var restored = try Simulation.fromSnapshot(allocator, initial, .{
        .character = .{ .max_characters = 2, .assets = restore_assets },
    });
    defer restored.deinit();
    const id = records[0].id;
    const view = try restored.character(id);
    try std.testing.expectApproxEqAbs(tuning.radius, view.radius, 0.0001);
    try std.testing.expectApproxEqAbs(tuning.half_height, view.half_height, 0.0001);
    try std.testing.expectEqual(
        @as(u32, @bitCast(tiny_yaw)),
        @as(u32, @bitCast(view.facing_yaw)),
    );
    const draw = (try restored.characterPresentation(0))[0];
    try std.testing.expectEqual(restore_assets.mesh, draw.mesh);
    try std.testing.expectEqual(restore_assets.material, draw.material);

    const saved = try restored.save(allocator);
    defer allocator.free(saved);
    try std.testing.expectEqualSlices(u8, initial, saved);

    try restored.submitCharacter(.{ .actions = .{
        .id = id,
        .move = .{ 1, 0 },
        .facing_yaw = tiny_yaw,
    } });
    try restored.tick();
    const moved = try restored.character(id);
    try std.testing.expect(moved.position[0] > 0.05);
    try std.testing.expectApproxEqAbs(tuning.move_speed, moved.velocity[0], 0.01);
}

test "world-bound restore rejects embedded construction drift before authority" {
    const allocator = std.testing.allocator;
    const expected = Config{
        .namespace = 7_756,
        .fixed_delta_seconds = 1.0 / 90.0,
        .max_crates = 4,
        .character = .{ .max_characters = 2, .move_speed = 5.5 },
        .vehicle = .{ .max_vehicles = 2, .tuning = .{ .mass = 1_700 } },
    };
    var bytes: []u8 = undefined;
    {
        var source = try Simulation.init(allocator, expected);
        defer source.deinit();
        try source.submit(.{ .spawn = .{
            .request_id = 1,
            .pose = .{ .position = .{ 1, 3, -2 } },
        } });
        try source.tick();
        _ = source.pollOutcome();
        bytes = try source.save(allocator);
    }
    defer allocator.free(bytes);

    var restored = try Simulation.fromSnapshotForWorld(
        allocator,
        bytes,
        expected,
        .{},
    );
    restored.deinit();

    var wrong_namespace = expected;
    wrong_namespace.namespace += 1;
    try std.testing.expectError(
        error.SnapshotWorldConfigMismatch,
        Simulation.fromSnapshotForWorld(allocator, bytes, wrong_namespace, .{}),
    );
    var wrong_delta = expected;
    wrong_delta.fixed_delta_seconds = 1.0 / 120.0;
    try std.testing.expectError(
        error.SnapshotWorldConfigMismatch,
        Simulation.fromSnapshotForWorld(allocator, bytes, wrong_delta, .{}),
    );
    var wrong_character = expected;
    wrong_character.character.move_speed = 8;
    try std.testing.expectError(
        error.SnapshotWorldConfigMismatch,
        Simulation.fromSnapshotForWorld(allocator, bytes, wrong_character, .{}),
    );
    var wrong_vehicle = expected;
    wrong_vehicle.vehicle.tuning.mass = 2_000;
    try std.testing.expectError(
        error.SnapshotWorldConfigMismatch,
        Simulation.fromSnapshotForWorld(allocator, bytes, wrong_vehicle, .{}),
    );
    var wrong_interaction = expected;
    wrong_interaction.interaction.collect_range = 4;
    try std.testing.expectError(
        error.SnapshotWorldConfigMismatch,
        Simulation.fromSnapshotForWorld(allocator, bytes, wrong_interaction, .{}),
    );

    // Every mismatch completed before Flecs/Jolt acquisition, so a new world
    // remains immediately constructible in this one-world-per-process module.
    var usable = try Simulation.init(allocator, .{ .namespace = 7_757 });
    defer usable.deinit();
    try usable.tick();
}

test "snapshot tuning and host character capacity fail before world construction" {
    const allocator = std.testing.allocator;
    const records = [_]CharacterV1{.{
        .id = .{ .namespace = 76, .local = 1 },
        .position = .{ 0, 0, 0 },
        .velocity = .{ 0, 0, 0 },
        .facing_yaw = 0,
    }};
    var snapshot = simulation_snapshot.SnapshotV11{
        .schema_version = simulation_snapshot.schema_version,
        .completed_ticks = 0,
        .fixed_delta_seconds = 1.0 / 120.0,
        .namespace = 76,
        .next_local_id = 2,
        .character_config = CharacterConfigV1.fromConfig(.{}),
        .vehicle_config = VehicleConfigV1.fromConfig(.{}),
        .interaction_config = InteractionConfigV1.fromConfig(.{}),
        .npc_config = NpcConfigV1.fromConfig(.{}),
        .npc_encounter_config = simulation_snapshot.NpcEncounterConfigV1.fromConfig(.{}),
        .crates = &.{},
        .characters = &records,
        .vehicles = &.{},
        .districts = &.{},
        .interactions = &.{},
        .npcs = &.{},
        .npc_encounters = &.{},
        .npc_replacements = &.{},
    };
    snapshot.character_config.gravity = 0;
    const invalid = try std.json.Stringify.valueAlloc(allocator, snapshot, .{});
    defer allocator.free(invalid);
    try std.testing.expectError(
        error.InvalidCharacterGravity,
        Simulation.fromSnapshot(allocator, invalid, .{}),
    );

    snapshot.character_config = CharacterConfigV1.fromConfig(.{});
    const valid = try std.json.Stringify.valueAlloc(allocator, snapshot, .{});
    defer allocator.free(valid);
    try std.testing.expectError(
        error.TooManyCharacters,
        Simulation.fromSnapshot(allocator, valid, .{
            .character = .{ .max_characters = 0 },
        }),
    );

    // Both failures occur before a runtime/Jolt world is acquired.
    var usable = try Simulation.init(allocator, .{ .namespace = 77 });
    defer usable.deinit();
    try usable.tick();
}

test "character collides with a crate through shared physics without feature imports" {
    var simulation = try Simulation.init(std.testing.allocator, .{ .namespace = 72 });
    defer simulation.deinit();
    try simulation.submit(.{ .spawn = .{
        .request_id = 1,
        .pose = .{ .position = .{ 0, 0.5, -2 } },
    } });
    try simulation.submitCharacter(.{ .spawn = .{
        .request_id = 2,
        .position = .{ 0, 0, 2 },
    } });
    try simulation.tick();
    const crate_id = simulation.pollOutcome().?.spawned.id;
    const character_id = simulation.pollCharacterOutcome().?.spawned.id;
    while (simulation.pollCharacterOutcome() != null) {}
    while (simulation.pollCharacterEvent() != null) {}
    for (0..60) |_| try simulation.tick();
    const before = (try simulation.crate(crate_id)).state.pose.position;

    for (0..180) |_| {
        try simulation.submitCharacter(.{ .actions = .{
            .id = character_id,
            .move = .{ 0, 1 },
            .facing_yaw = 0,
        } });
        try simulation.tick();
    }
    const after = (try simulation.crate(crate_id)).state.pose.position;
    const character = try simulation.character(character_id);
    // The default dense crate is too heavy for S1's 100 N controller strength,
    // but the character must still stop at the dynamic body's live collider.
    try std.testing.expectApproxEqAbs(before[2], after[2], 0.01);
    try std.testing.expect(character.position[2] > after[2] + 0.85);
    try std.testing.expect(character.position[2] < after[2] + 1.0);
    try std.testing.expectEqual(@as(usize, 2), simulation.entityCount());
    try std.testing.expectEqual(@as(u32, 2), simulation.bodyCount());
}

test "character outcomes distinguish cross-feature and stale identities" {
    var simulation = try Simulation.init(std.testing.allocator, .{ .namespace = 78 });
    defer simulation.deinit();
    try simulation.submit(.{ .spawn = .{
        .request_id = 1,
        .pose = .{ .position = .{ 3, 1, 0 } },
    } });
    try simulation.submitCharacter(.{ .spawn = .{
        .request_id = 2,
        .position = .{ 0, 0, 0 },
    } });
    try simulation.tick();
    const crate_id = simulation.pollOutcome().?.spawned.id;
    const character_id = simulation.pollCharacterOutcome().?.spawned.id;

    try simulation.submitCharacter(.{ .actions = .{
        .id = crate_id,
        .facing_yaw = 0,
    } });
    try simulation.tick();
    const foreign = simulation.pollCharacterOutcome().?.rejected;
    try std.testing.expectEqual(characters.CommandKind.actions, foreign.command);
    try std.testing.expectEqual(characters.RejectionReason.not_owned, foreign.reason);

    try simulation.submitCharacter(.{ .despawn = .{ .id = character_id } });
    try simulation.tick();
    try std.testing.expectEqual(character_id, simulation.pollCharacterOutcome().?.despawned);
    try simulation.submitCharacter(.{ .actions = .{
        .id = character_id,
        .facing_yaw = 0,
    } });
    try simulation.tick();
    const stale = simulation.pollCharacterOutcome().?.rejected;
    try std.testing.expectEqual(characters.CommandKind.actions, stale.command);
    try std.testing.expectEqual(
        characters.RejectionReason.character_not_found,
        stale.reason,
    );
}

test "vehicle enter treats an existing non-character identity as not a driver" {
    var simulation = try Simulation.init(std.testing.allocator, .{ .namespace = 781 });
    defer simulation.deinit();
    try simulation.submit(.{ .spawn = .{
        .request_id = 1,
        .pose = .{ .position = .{ 3, 1, 0 } },
    } });
    try simulation.submitVehicle(.{ .spawn = .{
        .request_id = 2,
        .chassis = .{ .pose = .{ .position = .{ 0, 2, 0 } } },
    } });
    try simulation.tick();
    const crate_id = simulation.pollOutcome().?.spawned.id;
    const vehicle_id = simulation.pollVehicleOutcome().?.spawned.id;
    try simulation.submitVehicle(.{ .enter = .{
        .vehicle_id = vehicle_id,
        .driver_id = crate_id,
    } });
    try simulation.tick();
    const rejected = simulation.pollVehicleOutcome().?.rejected;
    try std.testing.expectEqual(vehicles.CommandKind.enter, rejected.command);
    try std.testing.expectEqual(vehicles.RejectionReason.driver_not_found, rejected.reason);
    try simulation.tick();
}

test "character teardown owns unread outcomes events and pending commands" {
    var simulation = try Simulation.init(std.testing.allocator, .{ .namespace = 79 });
    try simulation.submitCharacter(.{ .spawn = .{
        .request_id = 1,
        .position = .{ 0, 2, 0 },
    } });
    try simulation.tick();
    const id = (try simulation.characterPresentation(1))[0].persistent_id;
    try simulation.submitCharacter(.{ .actions = .{
        .id = id,
        .move = .{ 1, 0 },
        .facing_yaw = 0,
    } });
    // Leave the spawn outcome and action command unread/unapplied. Deinit must
    // still release the controller, entity, queues, and presentation buffer.
    simulation.deinit();
}

test "character presentation interpolates without mutating simulation state" {
    var simulation = try Simulation.init(std.testing.allocator, .{ .namespace = 80 });
    defer simulation.deinit();
    try simulation.submitCharacter(.{ .spawn = .{
        .request_id = 1,
        .position = .{ 0, 0, 0 },
    } });
    try simulation.tick();
    const id = simulation.pollCharacterOutcome().?.spawned.id;
    try simulation.submitCharacter(.{ .actions = .{
        .id = id,
        .move = .{ 1, 0 },
        .facing_yaw = std.math.pi / 2.0,
    } });
    try simulation.tick();

    const state_before = try simulation.character(id);
    const start = (try simulation.characterPresentation(0))[0].pose;
    const midpoint = (try simulation.characterPresentation(0.5))[0].pose;
    const end = (try simulation.characterPresentation(1))[0].pose;
    const state_after = try simulation.character(id);
    for (0..3) |axis| {
        try std.testing.expectApproxEqAbs(
            (start.position[axis] + end.position[axis]) * 0.5,
            midpoint.position[axis],
            0.0001,
        );
    }
    try std.testing.expectEqual(state_before.position, state_after.position);
    try std.testing.expectEqual(state_before.velocity, state_after.velocity);
    try std.testing.expectEqual(state_before.facing_yaw, state_after.facing_yaw);
}

test "character climbs a physical step within configured height" {
    var simulation = try Simulation.init(std.testing.allocator, .{
        .namespace = 81,
        .block = .{
            .position = .{ 0, 0.15, -2 },
            .half_extents = .{ 2, 0.15, 0.5 },
        },
    });
    defer simulation.deinit();
    try simulation.submitCharacter(.{ .spawn = .{
        .request_id = 1,
        .position = .{ 0, 0, 0 },
    } });
    try simulation.tick();
    const id = simulation.pollCharacterOutcome().?.spawned.id;
    var highest_y: f32 = 0;
    for (0..90) |_| {
        try simulation.submitCharacter(.{ .actions = .{
            .id = id,
            .move = .{ 0, 1 },
            .facing_yaw = 0,
        } });
        try simulation.tick();
        highest_y = @max(highest_y, (try simulation.character(id)).position[1]);
    }
    const state = try simulation.character(id);
    try std.testing.expect(highest_y > 0.2);
    try std.testing.expect(state.position[2] < -2.5);
}

test "V11 validation owns schema cursor and cross-feature identity policy" {
    const crate_records = [_]CrateV1{.{
        .id = .{ .namespace = 73, .local = 1 },
        .half_extents = .{ 0.5, 0.5, 0.5 },
        .pose = .{},
        .linear_velocity = .{ 0, 0, 0 },
        .angular_velocity = .{ 0, 0, 0 },
    }};
    const character_records = [_]CharacterV1{.{
        .id = .{ .namespace = 73, .local = 1 },
        .position = .{ 0, 0, 0 },
        .velocity = .{ 0, 0, 0 },
        .facing_yaw = 0,
    }};
    const snapshot = simulation_snapshot.SnapshotV11{
        .schema_version = simulation_snapshot.schema_version,
        .completed_ticks = 0,
        .fixed_delta_seconds = 1.0 / 120.0,
        .namespace = 73,
        .next_local_id = 2,
        .character_config = CharacterConfigV1.fromConfig(.{}),
        .vehicle_config = VehicleConfigV1.fromConfig(.{}),
        .interaction_config = InteractionConfigV1.fromConfig(.{}),
        .npc_config = NpcConfigV1.fromConfig(.{}),
        .npc_encounter_config = simulation_snapshot.NpcEncounterConfigV1.fromConfig(.{}),
        .crates = &crate_records,
        .characters = &character_records,
        .vehicles = &.{},
        .districts = &.{},
        .interactions = &.{},
        .npcs = &.{},
        .npc_encounters = &.{},
        .npc_replacements = &.{},
    };
    try std.testing.expectError(
        error.DuplicatePersistentId,
        simulation_snapshot.validate(snapshot, 8, 1, 1, npcs.max_npcs),
    );
    var wrong_schema = snapshot;
    wrong_schema.schema_version = 1;
    try std.testing.expectError(
        error.UnsupportedSchemaVersion,
        simulation_snapshot.validate(wrong_schema, 8, 1, 1, npcs.max_npcs),
    );
    var colliding_cursor = snapshot;
    colliding_cursor.characters = &.{};
    colliding_cursor.next_local_id = 1;
    try std.testing.expectError(
        error.IdentityCursorWouldCollide,
        simulation_snapshot.validate(colliding_cursor, 8, 1, 1, npcs.max_npcs),
    );

    const build = sandbox_district_recipe.build(
        .{ .x = 0, .z = -4 },
        sandbox_district_recipe.current_recipe_version,
    ).ready;
    const district_records = [_]DistrictV1{.{
        .id = crate_records[0].id,
        .coord = build.coord,
        .recipe_version = build.recipe_version,
        .checksum = build.checksum,
    }};
    var district_collision = snapshot;
    district_collision.characters = &.{};
    district_collision.districts = &district_records;
    try std.testing.expectError(
        error.DuplicatePersistentId,
        simulation_snapshot.validate(district_collision, 8, 1, 1, npcs.max_npcs),
    );
}

test "V11 validation rejects missing and multiply assigned vehicle drivers" {
    const character_records = [_]CharacterV1{
        .{
            .id = .{ .namespace = 731, .local = 1 },
            .position = .{ 0, 0, 0 },
            .velocity = .{ 0, 0, 0 },
            .facing_yaw = 0,
        },
        .{
            .id = .{ .namespace = 731, .local = 2 },
            .position = .{ 1, 0, 0 },
            .velocity = .{ 0, 0, 0 },
            .facing_yaw = 0,
        },
    };
    var vehicle_records = [_]VehicleV1{
        .{
            .id = .{ .namespace = 731, .local = 3 },
            .chassis_pose = .{
                .position = .{ 0, 0, 0 },
                .rotation = .{ 0, 0, 0, 1 },
            },
            .linear_velocity = .{ 0, 0, 0 },
            .angular_velocity = .{ 0, 0, 0 },
            .wheels = @splat(.{ .rotation_angle = 0, .angular_velocity = 0 }),
            .input = .{ .throttle = 0, .steering = 0, .brake = 0, .hand_brake = 0 },
            .driver_id = .{ .namespace = 731, .local = 1 },
        },
        .{
            .id = .{ .namespace = 731, .local = 4 },
            .chassis_pose = .{
                .position = .{ 4, 0, 0 },
                .rotation = .{ 0, 0, 0, 1 },
            },
            .linear_velocity = .{ 0, 0, 0 },
            .angular_velocity = .{ 0, 0, 0 },
            .wheels = @splat(.{ .rotation_angle = 0, .angular_velocity = 0 }),
            .input = .{ .throttle = 0, .steering = 0, .brake = 0, .hand_brake = 0 },
            .driver_id = .{ .namespace = 731, .local = 1 },
        },
    };
    const snapshot = simulation_snapshot.SnapshotV11{
        .schema_version = simulation_snapshot.schema_version,
        .completed_ticks = 0,
        .fixed_delta_seconds = 1.0 / 120.0,
        .namespace = 731,
        .next_local_id = 100,
        .character_config = CharacterConfigV1.fromConfig(.{}),
        .vehicle_config = VehicleConfigV1.fromConfig(.{}),
        .interaction_config = InteractionConfigV1.fromConfig(.{}),
        .npc_config = NpcConfigV1.fromConfig(.{}),
        .npc_encounter_config = simulation_snapshot.NpcEncounterConfigV1.fromConfig(.{}),
        .crates = &.{},
        .characters = &character_records,
        .vehicles = &vehicle_records,
        .districts = &.{},
        .interactions = &.{},
        .npcs = &.{},
        .npc_encounters = &.{},
        .npc_replacements = &.{},
    };

    try std.testing.expectError(
        error.DuplicateVehicleDriver,
        simulation_snapshot.validate(snapshot, 0, 2, 2, npcs.max_npcs),
    );

    vehicle_records[1].driver_id = .{ .namespace = 731, .local = 2 };
    vehicle_records[0].driver_id = .{ .namespace = 731, .local = 99 };
    try std.testing.expectError(
        error.VehicleDriverNotFound,
        simulation_snapshot.validate(snapshot, 0, 2, 2, npcs.max_npcs),
    );

    vehicle_records[0].driver_id = .{ .namespace = 731, .local = 1 };
    try simulation_snapshot.validate(snapshot, 0, 2, 2, npcs.max_npcs);
}

test "V7 interaction preflight rejects holder conflicts before acquiring authority" {
    const allocator = std.testing.allocator;
    const character_id = engine.PersistentId{ .namespace = 7_319, .local = 1 };
    const vehicle_id = engine.PersistentId{ .namespace = 7_319, .local = 2 };
    const carryable_id = engine.PersistentId{ .namespace = 7_319, .local = 3 };
    const character_records = [_]CharacterV1{.{
        .id = character_id,
        .position = .{ 0, 0, 0 },
        .velocity = .{ 0, 0, 0 },
        .facing_yaw = 0,
    }};
    var vehicle_records = [_]VehicleV1{.{
        .id = vehicle_id,
        .chassis_pose = .{
            .position = .{ 0, 0, 0 },
            .rotation = .{ 0, 0, 0, 1 },
        },
        .linear_velocity = .{ 0, 0, 0 },
        .angular_velocity = .{ 0, 0, 0 },
        .wheels = @splat(.{ .rotation_angle = 0, .angular_velocity = 0 }),
        .input = .{ .throttle = 0, .steering = 0, .brake = 0, .hand_brake = 0 },
        .driver_id = character_id,
    }};
    var interaction_records = [_]InteractionV1{.{
        .id = carryable_id,
        .half_extents = .{ 0.35, 0.35, 0.35 },
        .ownership = .{ .inventory_held = character_id },
        .pose = .{},
        .linear_velocity = .{ 0, 0, 0 },
        .angular_velocity = .{ 0, 0, 0 },
    }};
    const snapshot = simulation_snapshot.SnapshotV11{
        .schema_version = simulation_snapshot.schema_version,
        .completed_ticks = 0,
        .fixed_delta_seconds = 1.0 / 120.0,
        .namespace = character_id.namespace,
        .next_local_id = 4,
        .character_config = CharacterConfigV1.fromConfig(.{}),
        .vehicle_config = VehicleConfigV1.fromConfig(.{}),
        .interaction_config = InteractionConfigV1.fromConfig(.{}),
        .npc_config = NpcConfigV1.fromConfig(.{}),
        .npc_encounter_config = simulation_snapshot.NpcEncounterConfigV1.fromConfig(.{}),
        .crates = &.{},
        .characters = &character_records,
        .vehicles = &vehicle_records,
        .districts = &.{},
        .interactions = &interaction_records,
        .npcs = &.{},
        .npc_encounters = &.{},
        .npc_replacements = &.{},
    };

    try std.testing.expectError(
        error.InteractionHolderDriving,
        simulation_snapshot.validate(snapshot, 1, 1, 1, npcs.max_npcs),
    );

    const invalid_bytes = try std.json.Stringify.valueAlloc(allocator, snapshot, .{});
    defer allocator.free(invalid_bytes);
    var blocker = try Simulation.init(allocator, .{
        .namespace = 7_320,
        .create_ground = false,
    });
    defer blocker.deinit();
    try std.testing.expectError(
        error.InteractionHolderDriving,
        Simulation.fromSnapshot(allocator, invalid_bytes, .{}),
    );
    try blocker.tick();

    vehicle_records[0].driver_id = null;
    interaction_records[0].ownership = .{ .inventory_held = vehicle_id };
    try std.testing.expectError(
        error.InteractionHolderNotFound,
        simulation_snapshot.validate(snapshot, 1, 1, 1, npcs.max_npcs),
    );
    interaction_records[0].ownership = .{ .inventory_held = character_id };
    try simulation_snapshot.validate(snapshot, 1, 1, 1, npcs.max_npcs);

    interaction_records[0].id = vehicle_id;
    try std.testing.expectError(
        error.DuplicatePersistentId,
        simulation_snapshot.validate(snapshot, 1, 1, 1, npcs.max_npcs),
    );
}

test "interaction composes real Jolt drop collect and held restore transactionally" {
    const allocator = std.testing.allocator;
    const namespace = 7_321;
    const character_id = engine.PersistentId{ .namespace = namespace, .local = 1 };
    const district_id = engine.PersistentId{ .namespace = namespace, .local = 2 };
    const carryable_id = engine.PersistentId{ .namespace = namespace, .local = 3 };
    const coord = ChunkCoord{ .x = 0, .z = 0 };
    const build = try sandbox_host_contracts.proceduralDistrictBuild(coord);
    const character_records = [_]CharacterV1{.{
        .id = character_id,
        .position = .{ 0, 0, 0 },
        .velocity = .{ 0, 0, 0 },
        .facing_yaw = 0,
    }};
    const district_records = [_]DistrictV1{.{
        .id = district_id,
        .coord = coord,
        .recipe_version = build.recipe_version,
        .checksum = build.checksum,
    }};
    const interaction_records = [_]InteractionV1{.{
        .id = carryable_id,
        .half_extents = .{ 0.35, 0.35, 0.35 },
        .ownership = .{ .inventory_held = character_id },
        .pose = .{ .position = .{ 0, 0.75, -1.5 } },
        .linear_velocity = .{ 0, 0, 0 },
        .angular_velocity = .{ 0, 0, 0 },
    }};
    const initial = try simulation_snapshot.encode(allocator, .{
        .schema_version = simulation_snapshot.schema_version,
        .completed_ticks = 0,
        .fixed_delta_seconds = 1.0 / 120.0,
        .namespace = namespace,
        .next_local_id = 4,
        .character_config = CharacterConfigV1.fromConfig(.{}),
        .vehicle_config = VehicleConfigV1.fromConfig(.{}),
        .interaction_config = InteractionConfigV1.fromConfig(.{}),
        .npc_config = NpcConfigV1.fromConfig(.{}),
        .npc_encounter_config = simulation_snapshot.NpcEncounterConfigV1.fromConfig(.{}),
        .crates = &.{},
        .characters = &character_records,
        .vehicles = &.{},
        .districts = &district_records,
        .interactions = &interaction_records,
        .npcs = &.{},
        .npc_encounters = &.{},
        .npc_replacements = &.{},
    }, .{});
    defer allocator.free(initial);

    var simulation = try Simulation.fromSnapshot(allocator, initial, .{});
    var simulation_live = true;
    defer if (simulation_live) simulation.deinit();
    try std.testing.expectEqual(@as(usize, 1), simulation.interactionCount());
    var held = try simulation.carryable(carryable_id);
    try std.testing.expect(!held.body_present);
    try std.testing.expectEqual(@as(usize, 1), (try simulation.interactionPresentation()).len);
    try std.testing.expectEqual(@as(u32, 1), simulation.diagnostics().interaction.held_count);

    try simulation.submitInteraction(.{ .drop = .{
        .transaction_id = 10,
        .carrier_id = character_id,
        .carryable_id = carryable_id,
        .purpose = .player_requested,
    } });
    try simulation.tick();
    try std.testing.expectEqual(
        carryable_id,
        simulation.pollInteractionOutcome().?.dropped.carryable_id,
    );
    held = try simulation.carryable(carryable_id);
    try std.testing.expect(held.body_present);
    try std.testing.expectEqual(@as(u32, 1), simulation.diagnostics().interaction.dynamic_body_count);

    try simulation.submitInteraction(.{ .collect = .{
        .transaction_id = 11,
        .carrier_id = character_id,
        .carryable_id = carryable_id,
    } });
    try simulation.tick();
    try std.testing.expectEqual(
        carryable_id,
        simulation.pollInteractionOutcome().?.collected.carryable_id,
    );
    held = try simulation.carryable(carryable_id);
    try std.testing.expect(!held.body_present);
    try std.testing.expectEqual(@as(u32, 1), simulation.diagnostics().interaction.held_count);

    const held_save = try simulation.save(allocator);
    defer allocator.free(held_save);
    simulation.deinit();
    simulation_live = false;

    var restored = try Simulation.fromSnapshot(allocator, held_save, .{});
    defer restored.deinit();
    try std.testing.expectEqual(@as(usize, 1), restored.interactionCount());
    try std.testing.expect(!(try restored.carryable(carryable_id)).body_present);
    const resaved = try restored.save(allocator);
    defer allocator.free(resaved);
    try std.testing.expectEqualSlices(u8, held_save, resaved);
}

const npc_test_district_assets = DistrictAssets{
    .scene = .{ .index = 41, .generation = 3 },
};

fn activateNpcTestDistrict(
    simulation: *Simulation,
    request_id: u64,
    coord: ChunkCoord,
) !LoadTicket {
    try simulation.submitDistrict(.{ .request_load = .{
        .request_id = request_id,
        .coord = coord,
        .assets = npc_test_district_assets,
    } });
    try simulation.tick();
    const requested = simulation.pollDistrictOutcome() orelse
        return error.DistrictRequestOutcomeMissing;
    const ticket = switch (requested) {
        .load_requested => |value| value.ticket,
        else => return error.UnexpectedDistrictOutcome,
    };
    while (simulation.pollDistrictEvent() != null) {}

    for (0..10_000) |_| {
        std.Thread.yield() catch {};
        try simulation.tick();
        while (simulation.pollDistrictOutcome()) |outcome| switch (outcome) {
            .activated => |value| {
                if (!LoadTicket.eql(ticket, value.ticket)) {
                    return error.UnexpectedDistrictTicket;
                }
                while (simulation.pollDistrictEvent() != null) {}
                return ticket;
            },
            .load_failed => return error.DistrictLoadFailed,
            .cancelled => return error.DistrictLoadCancelled,
            else => return error.UnexpectedDistrictOutcome,
        };
        while (simulation.pollDistrictEvent() != null) {}
    }
    return error.DistrictWorkerDidNotComplete;
}

fn unloadNpcTestDistrict(
    simulation: *Simulation,
    request_id: u64,
    ticket: LoadTicket,
) !void {
    try simulation.submitDistrict(.{ .unload = .{
        .request_id = request_id,
        .ticket = ticket,
    } });
    try simulation.tick();
    const outcome = simulation.pollDistrictOutcome() orelse
        return error.DistrictUnloadOutcomeMissing;
    switch (outcome) {
        .unloaded => |value| if (!LoadTicket.eql(ticket, value.ticket)) {
            return error.UnexpectedDistrictTicket;
        },
        else => return error.UnexpectedDistrictOutcome,
    }
    while (simulation.pollDistrictEvent() != null) {}
}

fn drainNpcPersistenceTestOutputs(simulation: *Simulation) void {
    while (simulation.pollNpcEncounterCue() != null) {}
    while (simulation.pollNpcEvent() != null) {}
    while (simulation.pollVitalsOutcome() != null) {}
    while (simulation.pollVitalsEvent() != null) {}
}

test "real Jolt NPC patrol waits crosses generations suspends and restores once" {
    const allocator = std.testing.allocator;
    const west_start = NavigationNodeRef{ .coord = navigation_west_coord, .index = 0 };
    const east_end = NavigationNodeRef{ .coord = navigation_east_coord, .index = 2 };
    var saved: []u8 = undefined;
    var npc_id: engine.PersistentId = undefined;

    {
        var simulation = try Simulation.init(allocator, .{
            .namespace = 8_101,
            .create_ground = false,
        });
        defer simulation.deinit();

        _ = try activateNpcTestDistrict(&simulation, 1, navigation_west_coord);
        const first_east_ticket = try activateNpcTestDistrict(
            &simulation,
            2,
            navigation_east_coord,
        );
        try std.testing.expectEqual(
            @as(u32, sandbox_district_recipe.static_box_count) * 2,
            simulation.bodyCount(),
        );

        try simulation.submitNpc(.{ .spawn = .{
            .request_id = 10,
            .node = west_start,
            .goal = .{ .patrol_between = .{
                .first = west_start,
                .second = east_end,
            } },
        } });
        try simulation.tick();
        npc_id = switch (simulation.pollNpcOutcome() orelse
            return error.NpcSpawnOutcomeMissing) {
            .spawned => |value| value.id,
            else => return error.UnexpectedNpcOutcome,
        };
        try std.testing.expectEqual(@as(usize, 1), simulation.npcCount());
        try std.testing.expectEqual(@as(u32, 1), simulation.diagnostics().npc.controller_count);
        try std.testing.expectEqual(
            @as(u32, sandbox_district_recipe.static_box_count) * 2,
            simulation.bodyCount(),
        );
        try std.testing.expectEqual(@as(usize, 1), (try simulation.npcPresentation(0)).len);

        // The route was admitted while both exact content cohorts were active.
        // Removing the destination makes the NPC stop at the seam rather than
        // pinning or entering inactive district authority.
        try unloadNpcTestDistrict(&simulation, 11, first_east_ticket);
        var observed_waiting = false;
        for (0..2_000) |_| {
            try simulation.tick();
            while (simulation.pollNpcEvent()) |_| {}
            const view = try simulation.npc(npc_id);
            if (view.state == .waiting_at_boundary) {
                observed_waiting = true;
                try std.testing.expectEqual(navigation_west_coord, view.owner);
                try std.testing.expect(view.controller_present);
                break;
            }
        }
        try std.testing.expect(observed_waiting);
        try std.testing.expectEqual(
            @as(u32, sandbox_district_recipe.static_box_count),
            simulation.bodyCount(),
        );
        try std.testing.expectEqual(@as(u32, 1), simulation.diagnostics().npc.controller_count);

        const second_east_ticket = try activateNpcTestDistrict(
            &simulation,
            12,
            navigation_east_coord,
        );
        try std.testing.expect(second_east_ticket.generation > first_east_ticket.generation);
        var observed_transfer = false;
        for (0..1_000) |_| {
            try simulation.tick();
            while (simulation.pollNpcEvent()) |event| switch (event) {
                .owner_transferred => |value| {
                    if (std.meta.eql(value.id, npc_id) and
                        ChunkCoord.eql(value.current, navigation_east_coord))
                    {
                        observed_transfer = true;
                    }
                },
                else => {},
            };
            if (ChunkCoord.eql((try simulation.npc(npc_id)).owner, navigation_east_coord)) {
                observed_transfer = true;
                break;
            }
        }
        try std.testing.expect(observed_transfer);
        try std.testing.expectEqual(
            @as(u32, sandbox_district_recipe.static_box_count) * 2,
            simulation.bodyCount(),
        );
        try std.testing.expectEqual(@as(u32, 1), simulation.diagnostics().npc.controller_count);

        // Owner unload destroys only CharacterVirtual state. Reloading the
        // same coordinate under a newer ticket reconstructs exactly one
        // controller and never changes the rigid-body budget.
        try unloadNpcTestDistrict(&simulation, 13, second_east_ticket);
        const dormant = try simulation.npc(npc_id);
        try std.testing.expectEqual(NpcState.dormant, dormant.state);
        try std.testing.expect(!dormant.controller_present);
        try std.testing.expectEqual(@as(u32, 0), simulation.diagnostics().npc.controller_count);
        try std.testing.expectEqual(
            @as(u32, sandbox_district_recipe.static_box_count),
            simulation.bodyCount(),
        );

        const third_east_ticket = try activateNpcTestDistrict(
            &simulation,
            14,
            navigation_east_coord,
        );
        try std.testing.expect(third_east_ticket.generation > second_east_ticket.generation);
        const resumed = try simulation.npc(npc_id);
        try std.testing.expect(resumed.state != .dormant);
        try std.testing.expect(resumed.controller_present);
        try std.testing.expectEqual(@as(u32, 1), simulation.diagnostics().npc.controller_count);
        try std.testing.expectEqual(
            @as(u32, sandbox_district_recipe.static_box_count) * 2,
            simulation.bodyCount(),
        );
        saved = try simulation.save(allocator);
    }
    defer allocator.free(saved);

    var restored = try Simulation.fromSnapshot(allocator, saved, .{
        .create_ground = false,
        .district_assets = npc_test_district_assets,
    });
    defer restored.deinit();
    try std.testing.expectEqual(@as(usize, 1), restored.npcCount());
    try std.testing.expectEqual(@as(usize, 3), restored.entityCount());
    try std.testing.expectEqual(
        @as(u32, sandbox_district_recipe.static_box_count) * 2,
        restored.bodyCount(),
    );
    try std.testing.expectEqual(@as(u32, 1), restored.diagnostics().npc.controller_count);
    try std.testing.expect((try restored.npc(npc_id)).controller_present);
    const resaved = try restored.save(allocator);
    defer allocator.free(resaved);
    try std.testing.expectEqualSlices(u8, saved, resaved);
}

test "former recipe perimeter does not block real Jolt character or vehicle" {
    var simulation = try Simulation.init(std.testing.allocator, .{
        .namespace = 8_107,
        .create_ground = true,
        .character = .{ .max_characters = 1 },
    });
    defer simulation.deinit();

    _ = try activateNpcTestDistrict(&simulation, 1, navigation_west_coord);
    _ = try activateNpcTestDistrict(&simulation, 2, navigation_east_coord);
    try simulation.submitCharacter(.{ .spawn = .{
        .request_id = 3,
        .position = .{ 10, 0, 6 },
    } });
    try simulation.submitVehicle(.{ .spawn = .{
        .request_id = 4,
        .chassis = .{ .pose = .{
            .position = .{ 10, 2, 10 },
            .rotation = .{ 0, -0.70710677, 0, 0.70710677 },
        } },
    } });
    try simulation.tick();
    const character_id = (simulation.pollCharacterOutcome() orelse
        return error.CharacterSpawnOutcomeMissing).spawned.id;
    const vehicle_id = (simulation.pollVehicleOutcome() orelse
        return error.VehicleSpawnOutcomeMissing).spawned.id;
    while (simulation.pollCharacterEvent() != null) {}
    while (simulation.pollVehicleEvent() != null) {}

    for (0..360) |_| {
        try simulation.submitCharacter(.{ .actions = .{
            .id = character_id,
            .move = .{ 0, -1 },
            .facing_yaw = 0,
        } });
        try simulation.tick();
        _ = simulation.pollCharacterOutcome();
        while (simulation.pollCharacterEvent() != null) {}
    }
    const perimeter_character = try simulation.character(character_id);
    // Recipe 4's north wall occupied z=[8, 8.5]. Reaching the vehicle beyond
    // its outer face proves that logical collision no longer contains the
    // character; the vehicle then provides the intentional stop.
    try std.testing.expect(perimeter_character.position[2] > 8.6);

    for (0..240) |_| try simulation.tick();
    try simulation.submitVehicle(.{ .enter = .{
        .vehicle_id = vehicle_id,
        .driver_id = character_id,
    } });
    try simulation.tick();
    const entered = simulation.pollVehicleOutcome() orelse
        return error.VehicleEnterOutcomeMissing;
    try std.testing.expect(entered == .entered);
    for (0..360) |_| {
        try simulation.submitVehicle(.{ .drive = .{
            .vehicle_id = vehicle_id,
            .driver_id = character_id,
            .input = .{ .throttle = 1 },
        } });
        try simulation.tick();
        const applied = simulation.pollVehicleOutcome() orelse
            return error.VehicleDriveOutcomeMissing;
        try std.testing.expect(applied == .drive_applied);
    }
    try std.testing.expect(
        (try simulation.vehicle(vehicle_id)).state.chassis.pose.position[0] > 25,
    );
    try std.testing.expect(simulation.firstFault() == null);
}

test "sustained real Jolt vehicle contact can displace NPC across district seam" {
    var simulation = try Simulation.init(std.testing.allocator, .{
        .namespace = 8_108,
        .create_ground = true,
        .character = .{ .max_characters = 1 },
        .vehicle = .{ .max_entry_distance = 100 },
    });
    defer simulation.deinit();

    _ = try activateNpcTestDistrict(&simulation, 1, navigation_west_coord);
    _ = try activateNpcTestDistrict(&simulation, 2, navigation_east_coord);
    try simulation.submitCharacter(.{ .spawn = .{
        .request_id = 3,
        .position = .{ 3.5, 0, 5 },
    } });
    try simulation.submitVehicle(.{
        .spawn = .{
            .request_id = 4,
            .chassis = .{
                .pose = .{
                    .position = .{ 3.5, 2, 3 },
                    // The canonical vehicle faces -Z. Rotate it toward +X so contact
                    // pushes the west-district NPC across the x=8 ownership seam.
                    .rotation = .{ 0, -0.70710677, 0, 0.70710677 },
                },
            },
        },
    });
    try simulation.submitNpc(.{ .spawn = .{
        .request_id = 5,
        .node = .{ .coord = navigation_west_coord, .index = 2 },
        .goal = .hold,
    } });
    try simulation.tick();
    const character_id = (simulation.pollCharacterOutcome() orelse
        return error.CharacterSpawnOutcomeMissing).spawned.id;
    const vehicle_id = (simulation.pollVehicleOutcome() orelse
        return error.VehicleSpawnOutcomeMissing).spawned.id;
    const npc_id = (simulation.pollNpcOutcome() orelse
        return error.NpcSpawnOutcomeMissing).spawned.id;
    while (simulation.pollCharacterEvent() != null) {}
    while (simulation.pollVehicleEvent() != null) {}
    while (simulation.pollNpcEvent() != null) {}

    for (0..240) |_| try simulation.tick();
    try simulation.submitVehicle(.{ .enter = .{
        .vehicle_id = vehicle_id,
        .driver_id = character_id,
    } });
    try simulation.tick();
    const entered = simulation.pollVehicleOutcome() orelse
        return error.VehicleEnterOutcomeMissing;
    try std.testing.expect(entered == .entered);

    var owner_transfer_observed = false;
    var greatest_npc_x = (try simulation.npc(npc_id)).position[0];
    for (0..1_200) |_| {
        const current_vehicle = try simulation.vehicle(vehicle_id);
        const current_npc = try simulation.npc(npc_id);
        const dx = current_npc.position[0] - current_vehicle.state.chassis.pose.position[0];
        const dz = current_npc.position[2] - current_vehicle.state.chassis.pose.position[2];
        const desired_yaw = try engine.transform.normalizeFacingYaw(std.math.atan2(dx, -dz));
        const current_yaw = try engine.transform.facingYawFromRotation(
            current_vehicle.state.chassis.pose.rotation,
        );
        const heading_error = try engine.transform.normalizeFacingYaw(
            desired_yaw - current_yaw,
        );
        try simulation.submitVehicle(.{ .drive = .{
            .vehicle_id = vehicle_id,
            .driver_id = character_id,
            .input = .{
                .throttle = 0.45,
                .steering = std.math.clamp(heading_error * 0.8, -0.5, 0.5),
            },
        } });
        try simulation.tick();
        const applied = simulation.pollVehicleOutcome() orelse
            return error.VehicleDriveOutcomeMissing;
        try std.testing.expect(applied == .drive_applied);
        while (simulation.pollNpcEvent()) |event| switch (event) {
            .owner_transferred => |transfer| {
                if (std.meta.eql(transfer.id, npc_id) and
                    ChunkCoord.eql(transfer.current, navigation_east_coord))
                {
                    owner_transfer_observed = true;
                }
            },
            else => {},
        };
        greatest_npc_x = @max(greatest_npc_x, (try simulation.npc(npc_id)).position[0]);
        if (owner_transfer_observed and greatest_npc_x > 8.05) break;
    }

    const npc_view = try simulation.npc(npc_id);
    try std.testing.expect(owner_transfer_observed);
    try std.testing.expect(greatest_npc_x > 8.05);
    try std.testing.expect(ChunkCoord.eql(navigation_east_coord, npc_view.owner));
    try std.testing.expect(npc_view.controller_present);
    try std.testing.expect(simulation.firstFault() == null);
    try std.testing.expectEqual(@as(u32, 1), simulation.diagnostics().npc.controller_count);

    // Continue applying contact pressure after the seam transition. The
    // original defect faulted the first attempted post-contact tick.
    for (0..120) |_| {
        try simulation.submitVehicle(.{ .drive = .{
            .vehicle_id = vehicle_id,
            .driver_id = character_id,
            .input = .{ .throttle = 1 },
        } });
        try simulation.tick();
        _ = simulation.pollVehicleOutcome() orelse
            return error.VehicleDriveOutcomeMissing;
        while (simulation.pollNpcEvent() != null) {}
    }
    try std.testing.expect(simulation.firstFault() == null);
}

test "completed-tick encounter authority chases and damages through vitals" {
    const allocator = std.testing.allocator;
    var simulation = try Simulation.init(allocator, .{
        .namespace = 8_109,
        .create_ground = false,
        .character = .{ .max_characters = 1 },
    });
    defer simulation.deinit();

    _ = try activateNpcTestDistrict(&simulation, 1, navigation_west_coord);
    try simulation.submitCharacter(.{ .spawn = .{
        .request_id = 2,
        .position = .{ -4, 0, -2 },
        .facing_yaw = 0,
    } });
    try simulation.submitNpc(.{ .spawn = .{
        .request_id = 3,
        .node = .{ .coord = navigation_west_coord, .index = 0 },
        .goal = .hold,
    } });
    try simulation.tick();
    const character_id = (simulation.pollCharacterOutcome() orelse
        return error.CharacterSpawnOutcomeMissing).spawned.id;
    const npc_id = (simulation.pollNpcOutcome() orelse
        return error.NpcSpawnOutcomeMissing).spawned.id;

    const character_target = vitals_contract.Target{
        .kind = .player,
        .id = character_id,
        .incarnation = .{ .value = 1 },
    };
    const npc_target = vitals_contract.Target{
        .kind = .npc,
        .id = npc_id,
        .incarnation = .{ .value = 1 },
    };
    try simulation.submitVitals(.{ .register = .{ .target = character_target } });
    try simulation.submitVitals(.{ .register = .{ .target = npc_target } });
    try simulation.tick();
    _ = simulation.pollVitalsOutcome() orelse return error.VitalsRegistrationMissing;
    _ = simulation.pollVitalsOutcome() orelse return error.VitalsRegistrationMissing;

    var observed_pursuit = false;
    var observed_damage = false;
    for (0..240) |_| {
        try simulation.tick();
        while (simulation.pollNpcEncounterCue()) |_| {}
        while (simulation.pollNpcEvent()) |_| {}
        while (simulation.pollVitalsOutcome()) |outcome| switch (outcome) {
            .damage => |damage| if (std.meta.eql(damage.proposal.target, character_target) and
                damage.disposition == .applied)
            {
                observed_damage = true;
            },
            else => {},
        };
        const encounter = simulation.npcEncounter(npc_target) orelse
            return error.NpcEncounterMissing;
        observed_pursuit = observed_pursuit or encounter.state != .patrolling;
        if (observed_damage) break;
    }

    try std.testing.expect(observed_pursuit);
    try std.testing.expect(observed_damage);
    const player_vitals = simulation.vitals(character_target) orelse
        return error.CharacterVitalsMissing;
    try std.testing.expect(player_vitals.current_health < player_vitals.maximum_health);

    var debug_lines: [256]engine.physics_debug.Line = undefined;
    var debug_triangles: [1]engine.physics_debug.Triangle = undefined;
    var debug_storage = engine.physics_debug.Storage.init(&debug_lines, &debug_triangles);
    const debug_batch = try simulation.extractPhysicsDebug(.{
        .shapes = false,
        .bounds = true,
        .contacts = false,
        .centers_of_mass = false,
        .velocities = false,
    }, &debug_storage);
    var encounter_lines: usize = 0;
    for (debug_batch.lines) |line| {
        if (line.object) |object| {
            if (object.kind == 0x533131 and object.serial == npc_id.local) {
                encounter_lines += 1;
            }
        }
    }
    try std.testing.expect(encounter_lines >= 76);
}

test "encounter pursuit save restore defers target and owner residency canonically" {
    const allocator = std.testing.allocator;
    const namespace: u64 = 8_109_1;
    const west_start = NavigationNodeRef{ .coord = navigation_west_coord, .index = 0 };
    const east_end = NavigationNodeRef{ .coord = navigation_east_coord, .index = 2 };
    const encounter_config = npc_encounter_contract.Config{
        .sight_facing_cos = -1,
        .ambient_perception_interval_ticks = 1,
        .engaged_perception_interval_ticks = 1,
    };
    const restore_config = simulation_snapshot.RestoreConfig{
        .district_assets = npc_test_district_assets,
    };
    var character_id: engine.PersistentId = undefined;
    var npc_id: engine.PersistentId = undefined;
    var active_pursuit_save: []u8 = undefined;
    var target_inactive_save: []u8 = undefined;

    {
        var simulation = try Simulation.init(allocator, .{
            .namespace = namespace,
            .npc_encounter = encounter_config,
        });
        defer simulation.deinit();
        _ = try activateNpcTestDistrict(&simulation, 1, navigation_west_coord);
        _ = try activateNpcTestDistrict(
            &simulation,
            2,
            navigation_east_coord,
        );
        try simulation.submitCharacter(.{ .spawn = .{
            .request_id = 3,
            .position = .{ 14, 0, 3 },
            .facing_yaw = -@as(f32, std.math.pi) / 2.0,
        } });
        try simulation.submitNpc(.{ .spawn = .{
            .request_id = 4,
            .node = west_start,
            .goal = .{ .patrol_between = .{
                .first = west_start,
                .second = east_end,
            } },
        } });
        try simulation.tick();
        character_id = (simulation.pollCharacterOutcome() orelse
            return error.CharacterSpawnOutcomeMissing).spawned.id;
        npc_id = (simulation.pollNpcOutcome() orelse
            return error.NpcSpawnOutcomeMissing).spawned.id;
        const character_target = vitals_contract.Target{
            .kind = .player,
            .id = character_id,
            .incarnation = .{ .value = 1 },
        };
        const npc_target = vitals_contract.Target{
            .kind = .npc,
            .id = npc_id,
            .incarnation = .{ .value = 1 },
        };
        try simulation.submitVitals(.{ .register = .{ .target = character_target } });
        try simulation.submitVitals(.{ .register = .{ .target = npc_target } });
        try simulation.tick();
        drainNpcPersistenceTestOutputs(&simulation);

        var pursuing = false;
        for (0..120) |_| {
            try simulation.tick();
            drainNpcPersistenceTestOutputs(&simulation);
            if (simulation.npcEncounter(npc_target)) |encounter| {
                if (encounter.state == .pursuing and
                    (try simulation.npc(npc_id)).encounter_locomotion != null)
                {
                    pursuing = true;
                    break;
                }
            }
        }
        try std.testing.expect(pursuing);
        try std.testing.expect(ChunkCoord.eql(
            navigation_west_coord,
            (try simulation.npc(npc_id)).owner,
        ));
        drainNpcPersistenceTestOutputs(&simulation);
        active_pursuit_save = try simulation.save(allocator);
        var parsed = try simulation_snapshot.parse(
            allocator,
            active_pursuit_save,
            restore_config.max_crates,
            restore_config.character.max_characters,
            restore_config.vehicle.max_vehicles,
            restore_config.npc.max_npcs,
        );
        defer parsed.deinit();
        const west_district = for (parsed.value.districts) |district_record| {
            if (ChunkCoord.eql(district_record.coord, navigation_west_coord)) {
                break district_record;
            }
        } else return error.WestDistrictRecordMissing;
        const resident_districts = [_]DistrictV1{west_district};
        var target_inactive = parsed.value;
        target_inactive.districts = &resident_districts;
        target_inactive_save = try simulation_snapshot.encode(
            allocator,
            target_inactive,
            .{},
        );
    }
    defer allocator.free(active_pursuit_save);
    defer allocator.free(target_inactive_save);

    {
        var restored = try Simulation.fromSnapshot(
            allocator,
            target_inactive_save,
            restore_config,
        );
        defer restored.deinit();
        const held = try restored.npc(npc_id);
        try std.testing.expectEqual(NpcState.active, held.state);
        try std.testing.expect(std.meta.activeTag(held.encounter_locomotion.?) == .hold);
        try restored.tick();
        drainNpcPersistenceTestOutputs(&restored);
    }

    var transferred_save: []u8 = undefined;
    {
        var restored = try Simulation.fromSnapshot(
            allocator,
            active_pursuit_save,
            restore_config,
        );
        defer restored.deinit();
        var held = try restored.npc(npc_id);
        try std.testing.expectEqual(NpcState.active, held.state);
        try std.testing.expect(
            std.meta.activeTag(held.encounter_locomotion.?) == .pursue_position,
        );
        var crossed = false;
        for (0..400) |_| {
            try restored.tick();
            drainNpcPersistenceTestOutputs(&restored);
            held = try restored.npc(npc_id);
            if (ChunkCoord.eql(held.owner, navigation_east_coord)) {
                crossed = true;
                break;
            }
        }
        try std.testing.expect(crossed);
        try std.testing.expect(
            std.meta.activeTag(held.encounter_locomotion.?) == .pursue_position,
        );
        transferred_save = try restored.save(allocator);

        var parsed = try simulation_snapshot.parse(
            allocator,
            transferred_save,
            restore_config.max_crates,
            restore_config.character.max_characters,
            restore_config.vehicle.max_vehicles,
            restore_config.npc.max_npcs,
        );
        defer parsed.deinit();
        try std.testing.expectEqual(@as(usize, 1), parsed.value.npcs.len);
        // Positional transfer now rebases the base route before persistence,
        // so the active owner-aligned prefix is durable rather than requiring
        // a restore-time deferred rebuild.
        try std.testing.expectEqual(
            npcs.PersistedRouteMode.exact_prefix,
            parsed.value.npcs[0].route.mode,
        );
        try std.testing.expect(ChunkCoord.eql(
            parsed.value.npcs[0].owner,
            parsed.value.npcs[0].route.current.coord,
        ));
    }
    defer allocator.free(transferred_save);

    var dormant_save: []u8 = undefined;
    {
        var restored = try Simulation.fromSnapshot(
            allocator,
            transferred_save,
            restore_config,
        );
        defer restored.deinit();
        var pursued = try restored.npc(npc_id);
        try std.testing.expectEqual(NpcState.active, pursued.state);
        try std.testing.expect(
            std.meta.activeTag(pursued.encounter_locomotion.?) == .pursue_position,
        );
        const east_ticket = restored.state.district_feature.activeTicketFor(
            navigation_east_coord,
        ) orelse return error.DistrictTicketMissing;
        try unloadNpcTestDistrict(&restored, 7, east_ticket);
        drainNpcPersistenceTestOutputs(&restored);
        pursued = try restored.npc(npc_id);
        try std.testing.expectEqual(NpcState.dormant, pursued.state);
        try std.testing.expect(!pursued.controller_present);
        dormant_save = try restored.save(allocator);
    }
    defer allocator.free(dormant_save);

    {
        var restored = try Simulation.fromSnapshot(
            allocator,
            dormant_save,
            restore_config,
        );
        defer restored.deinit();
        var dormant = try restored.npc(npc_id);
        try std.testing.expectEqual(NpcState.dormant, dormant.state);
        try std.testing.expect(!dormant.controller_present);
        _ = try activateNpcTestDistrict(&restored, 8, navigation_east_coord);
        drainNpcPersistenceTestOutputs(&restored);
        for (0..8) |_| {
            try restored.tick();
            drainNpcPersistenceTestOutputs(&restored);
            dormant = try restored.npc(npc_id);
            if (dormant.state != .dormant) break;
        }
        try std.testing.expect(dormant.state != .dormant);
        try std.testing.expect(dormant.controller_present);
    }
}

test "pending NPC replacement survives cold restore and exact resave" {
    const allocator = std.testing.allocator;
    var saved: []u8 = undefined;
    {
        var simulation = try Simulation.init(allocator, .{
            .namespace = 8_110,
            .create_ground = false,
        });
        defer simulation.deinit();
        const candidates = [_]NavigationNodeRef{
            .{ .coord = navigation_west_coord, .index = 0 },
            .{ .coord = navigation_west_coord, .index = 1 },
            .{ .coord = navigation_west_coord, .index = 2 },
        };
        try simulation.scheduleNpcReplacement(0, 2, 1, &candidates);
        try std.testing.expectEqual(
            @as(u16, 1),
            simulation.npcReplacementDiagnostics().pending,
        );
        saved = try simulation.save(allocator);
    }
    defer allocator.free(saved);

    var restored = try Simulation.fromSnapshot(allocator, saved, .{
        .create_ground = false,
    });
    defer restored.deinit();
    try std.testing.expectEqual(
        @as(u16, 1),
        restored.npcReplacementDiagnostics().pending,
    );
    const resaved = try restored.save(allocator);
    defer allocator.free(resaved);
    try std.testing.expectEqualSlices(u8, saved, resaved);
}

test "NPC capacity and hostile V11 snapshots fail before world authority" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(
        error.VirtualCharacterCapacityExceeded,
        Simulation.init(allocator, .{
            .namespace = 8_110,
            .character = .{ .max_characters = 65 },
        }),
    );

    const valid_npc = NpcV1{
        .id = .{ .namespace = 8_111, .local = 1 },
        .owner = navigation_west_coord,
        .goal = .hold,
        .route = .{ .current = .{ .coord = navigation_west_coord, .index = 0 } },
        .position = .{ -4, 0, 3 },
        .velocity = .{ 0, 0, 0 },
        .facing_yaw = 0,
    };
    var hostile_npc = valid_npc;
    hostile_npc.position = .{ 9, 0, 3 };
    var snapshot = simulation_snapshot.SnapshotV11{
        .schema_version = simulation_snapshot.schema_version,
        .completed_ticks = 0,
        .fixed_delta_seconds = 1.0 / 120.0,
        .namespace = 8_111,
        .next_local_id = 2,
        .character_config = CharacterConfigV1.fromConfig(.{}),
        .vehicle_config = VehicleConfigV1.fromConfig(.{}),
        .interaction_config = InteractionConfigV1.fromConfig(.{}),
        .npc_config = NpcConfigV1.fromConfig(.{}),
        .npc_encounter_config = simulation_snapshot.NpcEncounterConfigV1.fromConfig(.{}),
        .crates = &.{},
        .characters = &.{},
        .vehicles = &.{},
        .districts = &.{},
        .interactions = &.{},
        .npcs = &.{hostile_npc},
        .npc_encounters = &.{},
        .npc_replacements = &.{},
    };
    const hostile_bytes = try std.json.Stringify.valueAlloc(allocator, snapshot, .{});
    defer allocator.free(hostile_bytes);

    var blocker = try Simulation.init(allocator, .{
        .namespace = 8_112,
        .create_ground = false,
    });
    defer blocker.deinit();
    try std.testing.expectError(
        error.NpcOwnerPositionMismatch,
        Simulation.fromSnapshot(allocator, hostile_bytes, .{}),
    );
    try blocker.tick();

    snapshot.npcs = &.{valid_npc};
    const valid_bytes = try std.json.Stringify.valueAlloc(allocator, snapshot, .{});
    defer allocator.free(valid_bytes);
    try std.testing.expectError(
        error.InvalidNpcLimit,
        Simulation.fromSnapshot(allocator, valid_bytes, .{
            .npc = .{ .max_npcs = npcs.max_npcs - 1 },
        }),
    );

    const duplicate_crate = CrateV1{
        .id = valid_npc.id,
        .half_extents = .{ 0.5, 0.5, 0.5 },
        .pose = .{},
        .linear_velocity = .{ 0, 0, 0 },
        .angular_velocity = .{ 0, 0, 0 },
    };
    snapshot.crates = &.{duplicate_crate};
    try std.testing.expectError(
        error.DuplicatePersistentId,
        simulation_snapshot.validate(snapshot, 1, 1, 1, npcs.max_npcs),
    );
}

test "NPC command capture replays with the NPC category digest" {
    const allocator = std.testing.allocator;
    const content = try testContentCohort(
        [_]u8{0x8a} ** 32,
        [_]u8{0xa8} ** 32,
    );
    var encoded: []u8 = undefined;
    {
        var simulation = try Simulation.init(allocator, .{
            .namespace = 8_120,
            .create_ground = false,
        });
        defer simulation.deinit();
        try std.testing.expect(
            (try simulation.beginFlightRecording(content, .{})) == .admitted,
        );
        try simulation.submitNpc(.{ .spawn = .{
            .request_id = 1,
            .node = .{ .coord = navigation_west_coord, .index = 0 },
            .goal = .hold,
        } });
        try simulation.tick();
        const outcome = simulation.pollNpcOutcome() orelse
            return error.NpcSpawnOutcomeMissing;
        try std.testing.expect(outcome == .rejected);
        try std.testing.expectEqual(
            npcs.RejectionReason.start_district_inactive,
            outcome.rejected.reason,
        );
        encoded = try simulation.finishFlightRecording(allocator);
    }
    defer allocator.free(encoded);

    var parsed = try sandbox_replay.parse(allocator, encoded);
    defer parsed.deinit();
    try parsed.validateCompatible(content);
    try std.testing.expectEqual(@as(usize, 1), parsed.bootstrap_commands.len);
    try std.testing.expect(parsed.bootstrap_commands[0].command == .npc);
    const result = try replayCapture(allocator, parsed.view(), content);
    try std.testing.expect(result == .matched);
    try std.testing.expectEqual(@as(u64, 1), result.matched.completed_ticks);
}

test "NPC replacement orchestration is retained in the replay command spine" {
    const allocator = std.testing.allocator;
    const content = try testContentCohort(
        [_]u8{0x8b} ** 32,
        [_]u8{0xb8} ** 32,
    );
    var encoded: []u8 = undefined;
    {
        var simulation = try Simulation.init(allocator, .{
            .namespace = 8_121,
            .create_ground = false,
        });
        defer simulation.deinit();
        try std.testing.expect(
            (try simulation.beginFlightRecording(content, .{})) == .admitted,
        );
        const candidates = [_]NavigationNodeRef{
            .{ .coord = navigation_west_coord, .index = 0 },
            .{ .coord = navigation_west_coord, .index = 1 },
            .{ .coord = navigation_east_coord, .index = 2 },
        };
        try simulation.scheduleNpcReplacement(0, 2, 1, &candidates);
        try simulation.tick();
        encoded = try simulation.finishFlightRecording(allocator);
    }
    defer allocator.free(encoded);

    var parsed = try sandbox_replay.parse(allocator, encoded);
    defer parsed.deinit();
    try parsed.validateCompatible(content);
    try std.testing.expectEqual(@as(usize, 1), parsed.bootstrap_commands.len);
    try std.testing.expect(parsed.bootstrap_commands[0].command == .npc_replacement);
    const result = try replayCapture(allocator, parsed.view(), content);
    try std.testing.expect(result == .matched);
    try std.testing.expectEqual(@as(u64, 1), result.matched.completed_ticks);
}

test "vitals and dead incarnation survive canonical save restart" {
    const allocator = std.testing.allocator;
    var saved: []u8 = undefined;
    const target = vitals_contract.Target{
        .kind = .player,
        .id = .{ .namespace = 8_130, .local = 1 },
        .incarnation = .{ .value = 4 },
    };
    {
        var simulation = try Simulation.init(allocator, .{ .namespace = 8_130 });
        defer simulation.deinit();
        try simulation.submitCharacter(.{ .spawn = .{
            .request_id = 1,
            .position = .{ 0, 0, 0 },
        } });
        try simulation.tick();
        const spawned = (simulation.pollCharacterOutcome() orelse
            return error.CharacterSpawnOutcomeMissing).spawned;
        try std.testing.expect(std.meta.eql(spawned.id, target.id));
        try simulation.submitVitals(.{ .register = .{ .target = target } });
        try simulation.tick();
        _ = simulation.pollVitalsOutcome() orelse return error.VitalsRegistrationMissing;
        try simulation.submitVitals(.{ .damage = .{
            .source = .{
                .kind = .npc,
                .id = .{ .namespace = 8_130, .local = 99 },
                .incarnation = .{ .value = 1 },
                .action_sequence = 1,
            },
            .target = target,
            .cause = .npc_melee,
            .authority_tick = simulation.tickIndex() +| 1,
            .correlation = 1,
            .base_amount = 100,
            .ordinal = 1,
        } });
        try simulation.tick();
        const damage = (simulation.pollVitalsOutcome() orelse
            return error.VitalsDamageOutcomeMissing).damage;
        try std.testing.expect(damage.killed);
        _ = simulation.pollVitalsEvent() orelse return error.VitalsDeathEventMissing;
        saved = try simulation.save(allocator);
    }
    defer allocator.free(saved);

    var restored = try Simulation.fromSnapshot(allocator, saved, .{});
    defer restored.deinit();
    const vital = restored.vitals(target) orelse return error.RestoredVitalsMissing;
    try std.testing.expectEqual(vitals_contract.LifeState.dead, vital.life_state);
    try std.testing.expectEqual(@as(u16, 0), vital.current_health);
    const resaved = try restored.save(allocator);
    defer allocator.free(resaved);
    try std.testing.expectEqualSlices(u8, saved, resaved);
}
