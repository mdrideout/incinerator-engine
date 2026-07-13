//! Sandbox composition shared by the visual and headless hosts.

const std = @import("std");
const engine = @import("incinerator_engine");
const crates = @import("crate_feature");
const characters = @import("character_feature");
const vehicles = @import("vehicle_feature");
const districts = @import("district_feature");
const district_contract = @import("district_contract");
const district_worker = @import("district_worker");
const jolt = @import("jolt_physics");

pub const Command = crates.Command;
pub const Outcome = crates.Outcome;
pub const SpawnCrate = crates.SpawnCrate;
pub const DespawnEntity = crates.DespawnEntity;
pub const ApplyImpulse = crates.ApplyImpulse;
pub const CommandKind = crates.CommandKind;
pub const RejectionReason = crates.RejectionReason;
pub const CrateView = crates.CrateView;
pub const CrateDraw = crates.CrateDraw;
pub const Assets = crates.Assets;
pub const PersistentId = engine.PersistentId;

pub const CharacterCommand = characters.Command;
pub const CharacterOutcome = characters.Outcome;
pub const CharacterEvent = characters.Event;
pub const SpawnCharacter = characters.SpawnCharacter;
pub const CharacterActions = characters.ApplyActions;
pub const DespawnCharacter = characters.DespawnCharacter;
pub const CharacterView = characters.CharacterView;
pub const CharacterDraw = characters.CharacterDraw;
pub const CharacterConfig = characters.Config;
pub const CharacterConfigV1 = characters.CharacterConfigV1;
pub const GroundState = engine.physics.GroundState;
pub const CrateV1 = crates.CrateV1;
pub const CharacterV1 = characters.CharacterV1;
pub const VehicleCommand = vehicles.Command;
pub const VehicleOutcome = vehicles.Outcome;
pub const VehicleEvent = vehicles.Event;
pub const SpawnVehicle = vehicles.SpawnVehicle;
pub const EnterVehicle = vehicles.EnterVehicle;
pub const DriveVehicle = vehicles.DriveVehicle;
pub const ExitVehicle = vehicles.ExitVehicle;
pub const DespawnVehicle = vehicles.DespawnVehicle;
pub const VehicleView = vehicles.VehicleView;
pub const VehicleDraw = vehicles.VehicleDraw;
pub const VehicleConfig = vehicles.Config;
pub const VehicleConfigV1 = vehicles.VehicleConfigV1;
pub const VehicleV1 = vehicles.VehicleV1;
pub const DistrictCommand = districts.Command;
pub const DistrictOutcome = districts.Outcome;
pub const DistrictEvent = districts.Event;
pub const DistrictDraw = districts.DistrictDraw;
pub const DistrictAssets = districts.Assets;
pub const DistrictStateTag = districts.StateTag;
pub const DistrictV1 = districts.DistrictV1;
pub const ChunkCoord = district_contract.ChunkCoord;
pub const LoadTicket = district_contract.LoadTicket;

pub const StaticBox = struct {
    position: [3]f32,
    half_extents: [3]f32,
};

pub const SnapshotV4 = struct {
    schema_version: u16,
    completed_ticks: u64,
    fixed_delta_seconds: f32,
    namespace: u64,
    next_local_id: u64,
    character_config: CharacterConfigV1,
    vehicle_config: VehicleConfigV1,
    crates: []const CrateV1,
    characters: []const CharacterV1,
    vehicles: []const VehicleV1,
    districts: []const DistrictV1,
};

pub const max_snapshot_bytes: usize = 8 * 1024 * 1024;

const CrateFeature = crates.Feature(jolt.CrateBodies);
const CharacterFeature = characters.Feature(jolt.CharacterControllers);
const VehicleFeature = vehicles.Feature(jolt.Vehicles, CharacterFeature.DriverAccess);
const DistrictFeature = districts.Feature(jolt.DistrictBodies, district_worker.Worker);

pub const Config = struct {
    namespace: u64,
    fixed_delta_seconds: f32 = 1.0 / 120.0,
    max_crates: usize = 1024,
    assets: Assets = .{},
    create_ground: bool = true,
    character: CharacterConfig = .{},
    vehicle: VehicleConfig = .{},
    block: ?StaticBox = null,
};

pub const CharacterRestoreOptions = struct {
    max_characters: usize = 1,
    assets: characters.Assets = .{},
};

pub const VehicleRestoreOptions = struct {
    max_vehicles: usize = 1,
    assets: vehicles.Assets = .{},
};

pub const RestoreConfig = struct {
    max_crates: usize = 1024,
    assets: Assets = .{},
    create_ground: bool = true,
    character: CharacterRestoreOptions = .{},
    vehicle: VehicleRestoreOptions = .{},
    district_assets: DistrictAssets = .{},
    block: ?StaticBox = null,
};

const State = struct {
    allocator: std.mem.Allocator,
    physics: *jolt.Physics,
    runtime: engine.Runtime,
    stepper: jolt.PhysicsStepper,
    bodies: jolt.CrateBodies,
    controllers: jolt.CharacterControllers,
    vehicle_adapter: jolt.Vehicles,
    crate_feature: CrateFeature,
    character_feature: CharacterFeature,
    driver_access: CharacterFeature.DriverAccess,
    vehicle_feature: VehicleFeature,
    district_bodies: jolt.DistrictBodies,
    district_worker: district_worker.Worker,
    district_feature: DistrictFeature,
    ground: ?jolt.BodyId,
    block: ?jolt.BodyId,
};

pub const Simulation = struct {
    state: *State,

    pub fn init(allocator: std.mem.Allocator, config: Config) !Simulation {
        var simulation = try initOwnedUnfrozen(allocator, config, 1, 0);
        simulation.state.runtime.finishRegistration();
        return simulation;
    }

    /// The current zflecs wrapper permits only one live world per module.
    /// Parse may happen while another simulation exists, but that simulation
    /// must be deinitialized before this function constructs the fresh world.
    pub fn fromSnapshot(
        allocator: std.mem.Allocator,
        bytes: []const u8,
        config: RestoreConfig,
    ) !Simulation {
        var parsed = try parseSnapshot(
            allocator,
            bytes,
            config.max_crates,
            config.character.max_characters,
            config.vehicle.max_vehicles,
        );
        defer parsed.deinit();

        const character_config = try parsed.value.character_config.toConfig(
            config.character.max_characters,
            config.character.assets,
        );
        const vehicle_config = try parsed.value.vehicle_config.toConfig(
            config.vehicle.max_vehicles,
            config.vehicle.assets,
        );

        var simulation = try initOwnedUnfrozen(allocator, .{
            .namespace = parsed.value.namespace,
            .fixed_delta_seconds = parsed.value.fixed_delta_seconds,
            .max_crates = config.max_crates,
            .assets = config.assets,
            .create_ground = config.create_ground,
            .character = character_config,
            .vehicle = vehicle_config,
            .block = config.block,
        }, parsed.value.next_local_id, parsed.value.completed_ticks);
        errdefer simulation.deinit();
        try simulation.state.crate_feature.restoreRecords(parsed.value.crates);
        try simulation.state.character_feature.restoreRecords(parsed.value.characters);
        try simulation.state.vehicle_feature.restoreRecords(parsed.value.vehicles);
        try simulation.state.district_feature.restoreRecords(
            parsed.value.districts,
            config.district_assets,
        );
        simulation.state.runtime.finishRegistration();
        return simulation;
    }

    fn initOwnedUnfrozen(
        allocator: std.mem.Allocator,
        config: Config,
        next_local_id: u64,
        completed_ticks: u64,
    ) !Simulation {
        if (config.max_crates == 0) return error.InvalidCrateLimit;
        try validatePhysicsBodyBudget(config);
        const state = try allocator.create(State);
        errdefer allocator.destroy(state);
        const physics = try allocator.create(jolt.Physics);
        errdefer allocator.destroy(physics);
        physics.* = try jolt.Physics.initWithAllocator(allocator);
        errdefer physics.deinit();

        state.allocator = allocator;
        state.physics = physics;
        state.ground = null;
        state.block = null;
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
        state.vehicle_adapter = physics.vehicles();
        state.district_bodies = physics.districtBodies();
        state.district_worker = district_worker.Worker.init();
        errdefer state.district_worker.deinit();
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
        state.vehicle_feature = try VehicleFeature.init(
            allocator,
            &state.runtime,
            &state.vehicle_adapter,
            &state.driver_access,
            config.vehicle,
        );
        errdefer state.vehicle_feature.deinit();
        state.district_feature = DistrictFeature.init(
            allocator,
            &state.runtime,
            &state.district_bodies,
            &state.district_worker,
        );
        errdefer state.district_feature.deinit();

        var registry = state.runtime.registry();
        try state.crate_feature.register(&registry);
        try state.character_feature.register(&registry);
        try state.vehicle_feature.register(&registry);
        try state.district_feature.register(&registry);
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
        state.district_feature.deinit();
        state.district_worker.deinit();
        state.vehicle_feature.deinit();
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

    pub fn submit(self: *Simulation, command: Command) !void {
        try self.state.runtime.ensureOwnerThread();
        try self.state.crate_feature.enqueue(command);
    }

    pub fn submitCharacter(self: *Simulation, command: CharacterCommand) !void {
        try self.state.runtime.ensureOwnerThread();
        try self.state.character_feature.enqueue(command);
    }

    pub fn submitVehicle(self: *Simulation, command: VehicleCommand) !void {
        try self.state.runtime.ensureOwnerThread();
        try self.state.vehicle_feature.enqueue(command);
    }

    pub fn submitDistrict(self: *Simulation, command: DistrictCommand) !void {
        try self.state.runtime.ensureOwnerThread();
        try self.state.district_feature.enqueue(command);
    }

    pub fn tick(self: *Simulation) !void {
        try self.state.runtime.tick();
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

    pub fn save(self: *Simulation, allocator: std.mem.Allocator) ![]u8 {
        try self.state.runtime.ensureSnapshotBoundary();
        if (self.state.crate_feature.hasPendingCommands() or
            self.state.character_feature.hasPendingCommands() or
            self.state.vehicle_feature.hasPendingCommands() or
            self.state.district_feature.hasPendingCommands())
        {
            return error.CommandsPending;
        }
        const crate_records = try self.state.crate_feature.snapshotRecords(allocator);
        defer allocator.free(crate_records);
        const character_records = try self.state.character_feature.snapshotRecords(allocator);
        defer allocator.free(character_records);
        const vehicle_records = try self.state.vehicle_feature.snapshotRecords(allocator);
        defer allocator.free(vehicle_records);
        const district_records = try self.state.district_feature.snapshotRecords(allocator);
        defer allocator.free(district_records);
        return std.json.Stringify.valueAlloc(allocator, SnapshotV4{
            .schema_version = 4,
            .completed_ticks = self.state.runtime.tickIndex(),
            .fixed_delta_seconds = self.state.runtime.fixedDelta(),
            .namespace = self.state.runtime.namespace(),
            .next_local_id = try self.state.runtime.nextLocalId(),
            .character_config = CharacterConfigV1.fromConfig(
                self.state.character_feature.config,
            ),
            .vehicle_config = VehicleConfigV1.fromConfig(
                self.state.vehicle_feature.config,
            ),
            .crates = crate_records,
            .characters = character_records,
            .vehicles = vehicle_records,
            .districts = district_records,
        }, .{});
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

    pub fn districtBodyCount(self: *const Simulation) usize {
        self.state.runtime.assertOwnerThread();
        return self.state.district_feature.bodyCount();
    }

    pub fn districtState(self: *const Simulation) DistrictStateTag {
        self.state.runtime.assertOwnerThread();
        return self.state.district_feature.stateTag();
    }

    pub fn activeDistrictTicket(self: *const Simulation) ?LoadTicket {
        self.state.runtime.assertOwnerThread();
        return self.state.district_feature.activeTicket();
    }

    pub fn entityCount(self: *const Simulation) usize {
        self.state.runtime.assertOwnerThread();
        return self.state.runtime.entityCount();
    }

    pub fn bodyCount(self: *Simulation) u32 {
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
};

pub fn parseSnapshot(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    max_crates: usize,
    max_characters: usize,
    max_vehicles: usize,
) !std.json.Parsed(SnapshotV4) {
    if (bytes.len > max_snapshot_bytes) return error.SnapshotTooLarge;
    var parsed = try std.json.parseFromSlice(SnapshotV4, allocator, bytes, .{});
    errdefer parsed.deinit();
    try validateSnapshot(parsed.value, max_crates, max_characters, max_vehicles);
    return parsed;
}

pub fn validateSnapshot(
    snapshot: SnapshotV4,
    max_crates: usize,
    max_characters: usize,
    max_vehicles: usize,
) !void {
    if (snapshot.schema_version != 4) return error.UnsupportedSchemaVersion;
    if (snapshot.namespace == 0) return error.InvalidIdentityNamespace;
    if (snapshot.next_local_id == 0) return error.InvalidIdentityCursor;
    if (!std.math.isFinite(snapshot.fixed_delta_seconds) or
        snapshot.fixed_delta_seconds <= 0)
    {
        return error.InvalidFixedDelta;
    }
    try snapshot.character_config.validate();
    try snapshot.vehicle_config.validate();
    try crates.validateRecords(snapshot.crates, max_crates);
    if (snapshot.characters.len > max_characters) return error.TooManyCharacters;
    try vehicles.validateRecords(snapshot.vehicles, max_vehicles);
    try districts.validateRecords(snapshot.districts);

    for (snapshot.crates) |record| {
        try validateSnapshotIdentity(record.id, snapshot);
    }
    for (snapshot.characters, 0..) |record, index| {
        try characters.validateRecord(record);
        try validateSnapshotIdentity(record.id, snapshot);
        for (snapshot.characters[0..index]) |earlier| {
            if (std.meta.eql(earlier.id, record.id)) return error.DuplicatePersistentId;
        }
        for (snapshot.crates) |crate_record| {
            if (std.meta.eql(crate_record.id, record.id)) {
                return error.DuplicatePersistentId;
            }
        }
    }
    for (snapshot.vehicles, 0..) |record, index| {
        try validateSnapshotIdentity(record.id, snapshot);
        for (snapshot.crates) |crate_record| {
            if (std.meta.eql(crate_record.id, record.id)) {
                return error.DuplicatePersistentId;
            }
        }
        for (snapshot.characters) |character_record| {
            if (std.meta.eql(character_record.id, record.id)) {
                return error.DuplicatePersistentId;
            }
        }
        if (record.driver_id) |driver_id| {
            try validateSnapshotIdentity(driver_id, snapshot);
            var found = false;
            for (snapshot.characters) |character_record| {
                if (std.meta.eql(character_record.id, driver_id)) {
                    found = true;
                    break;
                }
            }
            if (!found) return error.VehicleDriverNotFound;
            for (snapshot.vehicles[0..index]) |earlier| {
                if (earlier.driver_id) |earlier_driver| {
                    if (std.meta.eql(earlier_driver, driver_id)) {
                        return error.DuplicateVehicleDriver;
                    }
                }
            }
        }
    }
    for (snapshot.districts) |record| {
        try validateSnapshotIdentity(record.id, snapshot);
        for (snapshot.crates) |crate_record| {
            if (std.meta.eql(crate_record.id, record.id)) return error.DuplicatePersistentId;
        }
        for (snapshot.characters) |character_record| {
            if (std.meta.eql(character_record.id, record.id)) {
                return error.DuplicatePersistentId;
            }
        }
        for (snapshot.vehicles) |vehicle_record| {
            if (std.meta.eql(vehicle_record.id, record.id)) {
                return error.DuplicatePersistentId;
            }
        }
    }
}

fn validateSnapshotIdentity(id: engine.PersistentId, snapshot: SnapshotV4) !void {
    if (id.namespace != snapshot.namespace) return error.ForeignIdentityNamespace;
    if (id.local >= snapshot.next_local_id) return error.IdentityCursorWouldCollide;
}

fn validatePhysicsBodyBudget(config: Config) !void {
    var required = std.math.add(usize, config.max_crates, config.vehicle.max_vehicles) catch
        return error.PhysicsBodyBudgetExceeded;
    required = std.math.add(usize, required, district_contract.max_static_boxes) catch
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

test "simulation type composes crate and character features with Jolt" {
    comptime engine.physics.assertImplementation(jolt.CrateBodies);
    comptime engine.physics.assertWorldStepImplementation(jolt.PhysicsStepper);
    comptime engine.physics.assertCharacterImplementation(jolt.CharacterControllers);
    comptime if (@hasDecl(jolt.CrateBodies, "step")) {
        @compileError("crate capability must not own the shared physics step");
    };
    _ = Simulation;
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
    try std.testing.expectEqual(DistrictStateTag.absent, simulation.districtState());
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

test "Snapshot V4 restores occupied and unoccupied real vehicles logically" {
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
    const initial = try std.json.Stringify.valueAlloc(allocator, SnapshotV4{
        .schema_version = 4,
        .completed_ticks = 3,
        .fixed_delta_seconds = 1.0 / 120.0,
        .namespace = 75,
        .next_local_id = 2,
        .character_config = CharacterConfigV1.fromConfig(tuning),
        .vehicle_config = VehicleConfigV1.fromConfig(.{}),
        .crates = &.{},
        .characters = &records,
        .vehicles = &.{},
        .districts = &.{},
    }, .{});
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

test "snapshot tuning and host character capacity fail before world construction" {
    const allocator = std.testing.allocator;
    const records = [_]CharacterV1{.{
        .id = .{ .namespace = 76, .local = 1 },
        .position = .{ 0, 0, 0 },
        .velocity = .{ 0, 0, 0 },
        .facing_yaw = 0,
    }};
    var snapshot = SnapshotV4{
        .schema_version = 4,
        .completed_ticks = 0,
        .fixed_delta_seconds = 1.0 / 120.0,
        .namespace = 76,
        .next_local_id = 2,
        .character_config = CharacterConfigV1.fromConfig(.{}),
        .vehicle_config = VehicleConfigV1.fromConfig(.{}),
        .crates = &.{},
        .characters = &records,
        .vehicles = &.{},
        .districts = &.{},
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

test "V4 validation owns schema cursor and cross-feature identity policy" {
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
    const snapshot = SnapshotV4{
        .schema_version = 4,
        .completed_ticks = 0,
        .fixed_delta_seconds = 1.0 / 120.0,
        .namespace = 73,
        .next_local_id = 2,
        .character_config = CharacterConfigV1.fromConfig(.{}),
        .vehicle_config = VehicleConfigV1.fromConfig(.{}),
        .crates = &crate_records,
        .characters = &character_records,
        .vehicles = &.{},
        .districts = &.{},
    };
    try std.testing.expectError(
        error.DuplicatePersistentId,
        validateSnapshot(snapshot, 8, 1, 1),
    );
    var wrong_schema = snapshot;
    wrong_schema.schema_version = 1;
    try std.testing.expectError(
        error.UnsupportedSchemaVersion,
        validateSnapshot(wrong_schema, 8, 1, 1),
    );
    var colliding_cursor = snapshot;
    colliding_cursor.characters = &.{};
    colliding_cursor.next_local_id = 1;
    try std.testing.expectError(
        error.IdentityCursorWouldCollide,
        validateSnapshot(colliding_cursor, 8, 1, 1),
    );

    const build = district_contract.proceduralBuild(
        .{ .x = 0, .z = -4 },
        district_contract.current_recipe_version,
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
        validateSnapshot(district_collision, 8, 1, 1),
    );
}

test "V4 validation rejects missing and multiply assigned vehicle drivers" {
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
    const snapshot = SnapshotV4{
        .schema_version = 4,
        .completed_ticks = 0,
        .fixed_delta_seconds = 1.0 / 120.0,
        .namespace = 731,
        .next_local_id = 100,
        .character_config = CharacterConfigV1.fromConfig(.{}),
        .vehicle_config = VehicleConfigV1.fromConfig(.{}),
        .crates = &.{},
        .characters = &character_records,
        .vehicles = &vehicle_records,
        .districts = &.{},
    };

    try std.testing.expectError(
        error.DuplicateVehicleDriver,
        validateSnapshot(snapshot, 0, 2, 2),
    );

    vehicle_records[1].driver_id = .{ .namespace = 731, .local = 2 };
    vehicle_records[0].driver_id = .{ .namespace = 731, .local = 99 };
    try std.testing.expectError(
        error.VehicleDriverNotFound,
        validateSnapshot(snapshot, 0, 2, 2),
    );

    vehicle_records[0].driver_id = .{ .namespace = 731, .local = 1 };
    try validateSnapshot(snapshot, 0, 2, 2);
}
