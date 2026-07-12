//! Sandbox composition shared by the visual and headless hosts.

const std = @import("std");
const engine = @import("incinerator_engine");
const crates = @import("crate_feature");
const characters = @import("character_feature");
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

pub const StaticBox = struct {
    position: [3]f32,
    half_extents: [3]f32,
};

pub const SnapshotV2 = struct {
    schema_version: u16,
    completed_ticks: u64,
    fixed_delta_seconds: f32,
    namespace: u64,
    next_local_id: u64,
    character_config: CharacterConfigV1,
    crates: []const CrateV1,
    characters: []const CharacterV1,
};

pub const max_snapshot_bytes: usize = 8 * 1024 * 1024;

const CrateFeature = crates.Feature(jolt.CrateBodies);
const CharacterFeature = characters.Feature(jolt.CharacterControllers);

pub const Config = struct {
    namespace: u64,
    fixed_delta_seconds: f32 = 1.0 / 120.0,
    max_crates: usize = 1024,
    assets: Assets = .{},
    create_ground: bool = true,
    character: CharacterConfig = .{},
    block: ?StaticBox = null,
};

pub const CharacterRestoreOptions = struct {
    max_characters: usize = 1,
    assets: characters.Assets = .{},
};

pub const RestoreConfig = struct {
    max_crates: usize = 1024,
    assets: Assets = .{},
    create_ground: bool = true,
    character: CharacterRestoreOptions = .{},
    block: ?StaticBox = null,
};

const State = struct {
    allocator: std.mem.Allocator,
    physics: *jolt.Physics,
    runtime: engine.Runtime,
    bodies: jolt.CrateBodies,
    controllers: jolt.CharacterControllers,
    crate_feature: CrateFeature,
    character_feature: CharacterFeature,
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
        );
        defer parsed.deinit();

        const character_config = try parsed.value.character_config.toConfig(
            config.character.max_characters,
            config.character.assets,
        );

        var simulation = try initOwnedUnfrozen(allocator, .{
            .namespace = parsed.value.namespace,
            .fixed_delta_seconds = parsed.value.fixed_delta_seconds,
            .max_crates = config.max_crates,
            .assets = config.assets,
            .create_ground = config.create_ground,
            .character = character_config,
            .block = config.block,
        }, parsed.value.next_local_id, parsed.value.completed_ticks);
        errdefer simulation.deinit();
        try simulation.state.crate_feature.restoreRecords(parsed.value.crates);
        try simulation.state.character_feature.restoreRecords(parsed.value.characters);
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
        state.bodies = physics.crateBodies();
        state.controllers = physics.characterControllers();
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

        var registry = state.runtime.registry();
        try state.crate_feature.register(&registry);
        try state.character_feature.register(&registry);
        try registry.addSystem(.physics, "physics.step", &state.bodies, stepPhysics);

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
        try self.state.crate_feature.enqueue(command);
    }

    pub fn submitCharacter(self: *Simulation, command: CharacterCommand) !void {
        try self.state.character_feature.enqueue(command);
    }

    pub fn tick(self: *Simulation) !void {
        try self.state.runtime.tick();
    }

    pub fn pollOutcome(self: *Simulation) ?Outcome {
        return self.state.crate_feature.pollOutcome();
    }

    pub fn pollCharacterOutcome(self: *Simulation) ?CharacterOutcome {
        return self.state.character_feature.pollOutcome();
    }

    pub fn pollCharacterEvent(self: *Simulation) ?CharacterEvent {
        return self.state.character_feature.pollEvent();
    }

    pub fn presentation(
        self: *Simulation,
        alpha: f32,
    ) ![]const CrateDraw {
        return self.state.crate_feature.extract(alpha);
    }

    pub fn characterPresentation(
        self: *Simulation,
        alpha: f32,
    ) ![]const CharacterDraw {
        return self.state.character_feature.extract(alpha);
    }

    pub fn crate(self: *Simulation, id: engine.PersistentId) !CrateView {
        return self.state.crate_feature.view(id);
    }

    pub fn character(self: *Simulation, id: engine.PersistentId) !CharacterView {
        return self.state.character_feature.view(id);
    }

    pub fn save(self: *Simulation, allocator: std.mem.Allocator) ![]u8 {
        try self.state.runtime.ensureSnapshotBoundary();
        if (self.state.crate_feature.hasPendingCommands() or
            self.state.character_feature.hasPendingCommands())
        {
            return error.CommandsPending;
        }
        const crate_records = try self.state.crate_feature.snapshotRecords(allocator);
        defer allocator.free(crate_records);
        const character_records = try self.state.character_feature.snapshotRecords(allocator);
        defer allocator.free(character_records);
        return std.json.Stringify.valueAlloc(allocator, SnapshotV2{
            .schema_version = 2,
            .completed_ticks = self.state.runtime.tickIndex(),
            .fixed_delta_seconds = self.state.runtime.fixedDelta(),
            .namespace = self.state.runtime.namespace(),
            .next_local_id = try self.state.runtime.nextLocalId(),
            .character_config = CharacterConfigV1.fromConfig(
                self.state.character_feature.config,
            ),
            .crates = crate_records,
            .characters = character_records,
        }, .{});
    }

    pub fn crateCount(self: *const Simulation) usize {
        return self.state.crate_feature.count();
    }

    pub fn characterCount(self: *const Simulation) usize {
        return self.state.character_feature.count();
    }

    pub fn entityCount(self: *const Simulation) usize {
        return self.state.runtime.entityCount();
    }

    pub fn bodyCount(self: *Simulation) u32 {
        return self.state.bodies.bodyCount();
    }

    /// Adapter diagnostic used by S0 characterization, not feature policy.
    pub fn activeBodyCount(self: *Simulation) u32 {
        return self.state.bodies.activeBodyCount();
    }

    pub fn tickIndex(self: *const Simulation) u64 {
        return self.state.runtime.tickIndex();
    }
};

pub fn parseSnapshot(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    max_crates: usize,
    max_characters: usize,
) !std.json.Parsed(SnapshotV2) {
    if (bytes.len > max_snapshot_bytes) return error.SnapshotTooLarge;
    var parsed = try std.json.parseFromSlice(SnapshotV2, allocator, bytes, .{});
    errdefer parsed.deinit();
    try validateSnapshot(parsed.value, max_crates, max_characters);
    return parsed;
}

pub fn validateSnapshot(
    snapshot: SnapshotV2,
    max_crates: usize,
    max_characters: usize,
) !void {
    if (snapshot.schema_version != 2) return error.UnsupportedSchemaVersion;
    if (snapshot.namespace == 0) return error.InvalidIdentityNamespace;
    if (snapshot.next_local_id == 0) return error.InvalidIdentityCursor;
    if (!std.math.isFinite(snapshot.fixed_delta_seconds) or
        snapshot.fixed_delta_seconds <= 0)
    {
        return error.InvalidFixedDelta;
    }
    try snapshot.character_config.validate();
    try crates.validateRecords(snapshot.crates, max_crates);
    if (snapshot.characters.len > max_characters) return error.TooManyCharacters;

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
}

fn validateSnapshotIdentity(id: engine.PersistentId, snapshot: SnapshotV2) !void {
    if (id.namespace != snapshot.namespace) return error.ForeignIdentityNamespace;
    if (id.local >= snapshot.next_local_id) return error.IdentityCursorWouldCollide;
}

fn stepPhysics(
    raw: *anyopaque,
    _: *engine.Runtime,
    tick: engine.TickContext,
) !void {
    const bodies: *jolt.CrateBodies = @ptrCast(@alignCast(raw));
    try bodies.step(tick.delta_seconds);
}

test "simulation type composes crate and character features with Jolt" {
    comptime engine.physics.assertImplementation(jolt.CrateBodies);
    comptime engine.physics.assertWorldStepImplementation(jolt.CrateBodies);
    comptime engine.physics.assertCharacterImplementation(jolt.CharacterControllers);
    _ = Simulation;
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
    const initial = try std.json.Stringify.valueAlloc(allocator, SnapshotV2{
        .schema_version = 2,
        .completed_ticks = 3,
        .fixed_delta_seconds = 1.0 / 120.0,
        .namespace = 75,
        .next_local_id = 2,
        .character_config = CharacterConfigV1.fromConfig(tuning),
        .crates = &.{},
        .characters = &records,
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
    var snapshot = SnapshotV2{
        .schema_version = 2,
        .completed_ticks = 0,
        .fixed_delta_seconds = 1.0 / 120.0,
        .namespace = 76,
        .next_local_id = 2,
        .character_config = CharacterConfigV1.fromConfig(.{}),
        .crates = &.{},
        .characters = &records,
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

test "V2 validation owns schema cursor and cross-feature identity policy" {
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
    const snapshot = SnapshotV2{
        .schema_version = 2,
        .completed_ticks = 0,
        .fixed_delta_seconds = 1.0 / 120.0,
        .namespace = 73,
        .next_local_id = 2,
        .character_config = CharacterConfigV1.fromConfig(.{}),
        .crates = &crate_records,
        .characters = &character_records,
    };
    try std.testing.expectError(
        error.DuplicatePersistentId,
        validateSnapshot(snapshot, 8, 1),
    );
    var wrong_schema = snapshot;
    wrong_schema.schema_version = 1;
    try std.testing.expectError(
        error.UnsupportedSchemaVersion,
        validateSnapshot(wrong_schema, 8, 1),
    );
    var colliding_cursor = snapshot;
    colliding_cursor.characters = &.{};
    colliding_cursor.next_local_id = 1;
    try std.testing.expectError(
        error.IdentityCursorWouldCollide,
        validateSnapshot(colliding_cursor, 8, 1),
    );
}
