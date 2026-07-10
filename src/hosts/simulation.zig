//! Concrete S0 composition shared by the visual and headless hosts.

const std = @import("std");
const engine = @import("incinerator_engine");
const crates = @import("crate_feature");
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

const CrateFeature = crates.Feature(jolt.CrateBodies);

pub const Config = struct {
    namespace: u64,
    fixed_delta_seconds: f32 = 1.0 / 120.0,
    max_crates: usize = 1024,
    assets: Assets = .{},
    create_ground: bool = true,
};

pub const RestoreConfig = struct {
    max_crates: usize = 1024,
    assets: Assets = .{},
    create_ground: bool = true,
};

const State = struct {
    allocator: std.mem.Allocator,
    physics: *jolt.Physics,
    owns_physics: bool,
    runtime: engine.Runtime,
    bodies: jolt.CrateBodies,
    crate_feature: CrateFeature,
    ground: ?jolt.BodyId,
};

pub const Simulation = struct {
    state: *State,

    pub fn init(allocator: std.mem.Allocator, config: Config) !Simulation {
        var simulation = try initOwnedUnfrozen(allocator, config, 1, 0);
        simulation.state.runtime.finishRegistration();
        return simulation;
    }

    /// Compose S0 into the sandbox's existing worlds during migration. The
    /// caller must keep both borrowed owners alive until `deinit` returns.
    pub fn initBorrowed(
        allocator: std.mem.Allocator,
        world_context: *anyopaque,
        physics: *jolt.Physics,
        config: Config,
    ) !Simulation {
        const state = try allocator.create(State);
        errdefer allocator.destroy(state);

        state.allocator = allocator;
        state.physics = physics;
        state.owns_physics = false;
        state.ground = null;
        state.runtime = try engine.Runtime.initBorrowed(allocator, world_context, .{
            .namespace = config.namespace,
            .fixed_delta_seconds = config.fixed_delta_seconds,
        });
        errdefer state.runtime.deinit();
        state.bodies = physics.crateBodies();
        state.crate_feature = try CrateFeature.init(
            allocator,
            &state.runtime,
            &state.bodies,
            config.assets,
            config.max_crates,
        );
        errdefer state.crate_feature.deinit();

        var registry = state.runtime.registry();
        try state.crate_feature.register(&registry);
        try registry.addSystem(.physics, "physics.step", &state.bodies, stepPhysics);
        if (config.create_ground) {
            state.ground = try physics.createStaticBox(.{ 0, -1, 0 }, .{ 50, 1, 50 });
            errdefer if (state.ground) |ground| {
                _ = physics.removeBody(ground);
            };
        }
        state.runtime.finishRegistration();
        return .{ .state = state };
    }

    /// The current zflecs wrapper permits only one live world per module.
    /// Parse may happen while another simulation exists, but that simulation
    /// must be deinitialized before this function constructs the fresh world.
    pub fn fromSnapshot(
        allocator: std.mem.Allocator,
        bytes: []const u8,
        config: RestoreConfig,
    ) !Simulation {
        var parsed = try crates.parseSnapshot(allocator, bytes, config.max_crates);
        defer parsed.deinit();

        var simulation = try initOwnedUnfrozen(allocator, .{
            .namespace = parsed.value.namespace,
            .fixed_delta_seconds = parsed.value.fixed_delta_seconds,
            .max_crates = config.max_crates,
            .assets = config.assets,
            .create_ground = config.create_ground,
        }, parsed.value.next_local_id, parsed.value.completed_ticks);
        errdefer simulation.deinit();
        try simulation.state.crate_feature.restoreSnapshot(parsed.value);
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
        physics.* = try jolt.Physics.init();
        errdefer physics.deinit();

        state.allocator = allocator;
        state.physics = physics;
        state.owns_physics = true;
        state.ground = null;
        state.runtime = try engine.Runtime.init(allocator, .{
            .namespace = config.namespace,
            .fixed_delta_seconds = config.fixed_delta_seconds,
            .next_local_id = next_local_id,
            .completed_ticks = completed_ticks,
        });
        errdefer state.runtime.deinit();
        state.bodies = physics.crateBodies();
        state.crate_feature = try CrateFeature.init(
            allocator,
            &state.runtime,
            &state.bodies,
            config.assets,
            config.max_crates,
        );
        errdefer state.crate_feature.deinit();

        var registry = state.runtime.registry();
        try state.crate_feature.register(&registry);
        try registry.addSystem(.physics, "physics.step", &state.bodies, stepPhysics);

        if (config.create_ground) {
            state.ground = try physics.createStaticBox(.{ 0, -1, 0 }, .{ 50, 1, 50 });
            errdefer if (state.ground) |ground| {
                _ = physics.removeBody(ground);
            };
        }
        return .{ .state = state };
    }

    pub fn deinit(self: *Simulation) void {
        const state = self.state;
        state.crate_feature.deinit();
        if (state.ground) |ground| {
            if (!state.physics.removeBody(ground)) {
                @panic("simulation ground cleanup invariant failed");
            }
        }
        state.runtime.deinit();
        if (state.owns_physics) {
            state.physics.deinit();
            state.allocator.destroy(state.physics);
        }
        const allocator = state.allocator;
        allocator.destroy(state);
        self.* = undefined;
    }

    pub fn submit(self: *Simulation, command: Command) !void {
        try self.state.crate_feature.enqueue(command);
    }

    pub fn tick(self: *Simulation) !void {
        try self.state.runtime.tick();
    }

    pub fn pollOutcome(self: *Simulation) ?Outcome {
        return self.state.crate_feature.pollOutcome();
    }

    pub fn presentation(
        self: *Simulation,
        alpha: f32,
    ) ![]const CrateDraw {
        return self.state.crate_feature.extract(alpha);
    }

    pub fn crate(self: *Simulation, id: engine.PersistentId) !CrateView {
        return self.state.crate_feature.view(id);
    }

    pub fn save(self: *Simulation, allocator: std.mem.Allocator) ![]u8 {
        return self.state.crate_feature.save(allocator);
    }

    pub fn crateCount(self: *const Simulation) usize {
        return self.state.crate_feature.count();
    }

    pub fn entityCount(self: *const Simulation) usize {
        return self.state.runtime.entityCount();
    }

    pub fn bodyCount(self: *Simulation) u32 {
        return self.state.bodies.bodyCount();
    }

    pub fn tickIndex(self: *const Simulation) u64 {
        return self.state.runtime.tickIndex();
    }
};

fn stepPhysics(
    raw: *anyopaque,
    _: *engine.Runtime,
    tick: engine.TickContext,
) !void {
    const bodies: *jolt.CrateBodies = @ptrCast(@alignCast(raw));
    try bodies.step(tick.delta_seconds);
}

test "simulation type composes the crate feature with Jolt" {
    comptime engine.physics.assertImplementation(jolt.CrateBodies);
    _ = Simulation;
}
