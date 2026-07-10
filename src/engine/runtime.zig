//! Thin, deterministic runtime for feature-oriented simulation slices.

const std = @import("std");
const flecs = @import("zflecs");
const identity_module = @import("engine_contracts").identity;

pub const PersistentId = identity_module.PersistentId;

pub const RuntimeId = struct {
    runtime_token: u64,
    serial: u64,
};
const PersistentIdentity = struct { id: PersistentId };

var runtime_token_mutex: std.atomic.Mutex = .unlocked;
var next_runtime_token: u64 = 1;
var owned_world_mutex: std.atomic.Mutex = .unlocked;
var owned_world_live: bool = false;

pub const Phase = enum(u8) {
    commands,
    pre_physics,
    physics,
    post_physics,
};

pub const TickContext = struct {
    tick_index: u64,
    delta_seconds: f32,
};

pub const SystemCallback = *const fn (
    context: *anyopaque,
    runtime: *Runtime,
    tick: TickContext,
) anyerror!void;

const System = struct {
    phase: Phase,
    name: []u8,
    context: *anyopaque,
    callback: SystemCallback,
};

pub const Config = struct {
    namespace: u64,
    fixed_delta_seconds: f32,
    next_local_id: u64 = 1,
    completed_ticks: u64 = 0,
};

const Lifecycle = enum { registering, ready, ticking, faulted, deinitialized };

const State = struct {
    gpa: std.mem.Allocator,
    world: *flecs.world_t,
    identities: std.AutoHashMap(PersistentId, RuntimeId),
    entities: std.AutoHashMap(u64, flecs.entity_t),
    issued_identities: std.AutoHashMap(PersistentId, void),
    identity_source: identity_module.IdentitySource,
    runtime_token: u64,
    next_entity_serial: u64 = 1,
    systems: std.ArrayListUnmanaged(System) = .empty,
    fixed_delta_seconds: f32,
    completed_ticks: u64,
    tracked_entity_count: usize = 0,
    lifecycle: Lifecycle = .registering,
};

pub const Runtime = struct {
    /// Type-erased private state keeps Flecs and mutable bookkeeping out of
    /// the public engine layout. All access is centralized below.
    storage: *anyopaque,

    fn statePtr(self: *const Runtime) *State {
        return @ptrCast(@alignCast(self.storage));
    }

    pub fn init(gpa: std.mem.Allocator, config: Config) !Runtime {
        try validateConfig(config);
        try acquireOwnedWorldLease();
        errdefer releaseOwnedWorldLease();
        const world = flecs.init();
        errdefer _ = flecs.fini(world);
        const state = try gpa.create(State);
        errdefer gpa.destroy(state);
        state.* = .{
            .gpa = gpa,
            .world = world,
            .identities = std.AutoHashMap(PersistentId, RuntimeId).init(gpa),
            .entities = std.AutoHashMap(u64, flecs.entity_t).init(gpa),
            .issued_identities = std.AutoHashMap(PersistentId, void).init(gpa),
            .identity_source = try identity_module.IdentitySource.initAt(
                config.namespace,
                config.next_local_id,
            ),
            .runtime_token = try allocateRuntimeToken(),
            .fixed_delta_seconds = config.fixed_delta_seconds,
            .completed_ticks = config.completed_ticks,
        };
        const result = Runtime{ .storage = state };
        flecs.COMPONENT(result.statePtr().world, PersistentIdentity);
        return result;
    }

    pub fn deinit(self: *Runtime) void {
        if (self.statePtr().lifecycle == .deinitialized or
            self.statePtr().lifecycle == .ticking)
        {
            @panic("runtime deinitialized from an invalid lifecycle state");
        }
        // Features remove bodies before their corresponding entities.
        if (self.statePtr().tracked_entity_count != 0 or
            self.statePtr().identities.count() != 0 or
            self.statePtr().entities.count() != 0)
        {
            @panic("runtime deinitialized with live feature entities");
        }
        for (self.statePtr().systems.items) |system| self.statePtr().gpa.free(system.name);
        self.statePtr().systems.deinit(self.statePtr().gpa);
        self.statePtr().identities.deinit();
        self.statePtr().entities.deinit();
        self.statePtr().issued_identities.deinit();
        _ = flecs.fini(self.statePtr().world);
        releaseOwnedWorldLease();
        self.statePtr().lifecycle = .deinitialized;
        const state = self.statePtr();
        state.gpa.destroy(state);
        self.* = undefined;
    }

    pub fn allocator(self: *const Runtime) std.mem.Allocator {
        return self.statePtr().gpa;
    }

    pub fn ensureHealthy(self: *const Runtime) !void {
        if (self.statePtr().lifecycle == .deinitialized) return error.RuntimeDeinitialized;
        if (self.statePtr().lifecycle == .faulted) return error.RuntimeFaulted;
    }

    pub fn isFaulted(self: *const Runtime) bool {
        return self.statePtr().lifecycle == .faulted;
    }

    pub fn ensureSnapshotBoundary(self: *const Runtime) !void {
        try self.ensureHealthy();
        if (self.statePtr().lifecycle == .ticking) return error.TickInProgress;
    }

    /// Commands submitted while a tick is executing target the following
    /// tick, independent of system registration order within `.commands`.
    pub fn commandTargetTick(self: *const Runtime) !u64 {
        try self.ensureHealthy();
        const offset: u64 = if (self.statePtr().lifecycle == .ticking) 2 else 1;
        return std.math.add(u64, self.statePtr().completed_ticks, offset) catch
            error.TickCounterExhausted;
    }

    pub fn registry(self: *Runtime) FeatureRegistry {
        return .{ .runtime = self };
    }

    pub fn finishRegistration(self: *Runtime) void {
        if (self.statePtr().lifecycle == .registering) {
            // Explicit restore IDs are accepted only during registration.
            // Automatic runtime IDs are monotonic, so retaining restore
            // tombstones after this boundary would make normal churn leak.
            self.statePtr().issued_identities.clearAndFree();
            self.statePtr().lifecycle = .ready;
        }
    }

    pub fn tick(self: *Runtime) !void {
        if (self.statePtr().lifecycle == .deinitialized) return error.RuntimeDeinitialized;
        if (self.statePtr().lifecycle == .ticking) return error.ReentrantTick;
        if (self.statePtr().lifecycle == .faulted) return error.RuntimeFaulted;
        self.finishRegistration();

        const next_tick = std.math.add(u64, self.statePtr().completed_ticks, 1) catch
            return error.TickCounterExhausted;
        const context = TickContext{
            .tick_index = next_tick,
            .delta_seconds = self.statePtr().fixed_delta_seconds,
        };

        self.statePtr().lifecycle = .ticking;
        self.runPhase(.commands, context) catch |err| {
            self.statePtr().lifecycle = .faulted;
            return err;
        };
        self.runPhase(.pre_physics, context) catch |err| {
            self.statePtr().lifecycle = .faulted;
            return err;
        };
        self.runPhase(.physics, context) catch |err| {
            self.statePtr().lifecycle = .faulted;
            return err;
        };
        self.runPhase(.post_physics, context) catch |err| {
            self.statePtr().lifecycle = .faulted;
            return err;
        };
        self.statePtr().completed_ticks = next_tick;
        self.statePtr().lifecycle = .ready;
    }

    fn runPhase(self: *Runtime, phase: Phase, context: TickContext) !void {
        for (self.statePtr().systems.items) |system| {
            if (system.phase == phase) {
                try system.callback(system.context, self, context);
            }
        }
    }

    pub fn create(self: *Runtime) !RuntimeId {
        try self.ensureHealthy();
        if (self.statePtr().lifecycle == .registering) {
            try self.statePtr().issued_identities.ensureUnusedCapacity(1);
            // Reserve every fallible index allocation before consuming the
            // automatic persistent ID. If a later creation stage fails, the
            // already-reserved registration tombstone retires that ID.
            try self.statePtr().identities.ensureUnusedCapacity(1);
            try self.statePtr().entities.ensureUnusedCapacity(1);
        }
        const id = try self.statePtr().identity_source.next();
        return self.createWithPersistentIdInternal(id, false);
    }

    pub fn createWithPersistentId(self: *Runtime, id: PersistentId) !RuntimeId {
        try self.ensureHealthy();
        if (self.statePtr().lifecycle != .registering) return error.RestoreIdentityOutsideRegistration;
        try self.statePtr().issued_identities.ensureUnusedCapacity(1);
        return self.createWithPersistentIdInternal(id, true);
    }

    fn createWithPersistentIdInternal(
        self: *Runtime,
        id: PersistentId,
        observe_identity: bool,
    ) !RuntimeId {
        try self.requireLive();
        try id.validate();
        if (id.namespace != self.statePtr().identity_source.namespace) {
            return error.ForeignIdentityNamespace;
        }
        const track_registration_identity = observe_identity or
            self.statePtr().lifecycle == .registering;
        if (track_registration_identity and self.statePtr().issued_identities.contains(id)) {
            return error.PersistentIdAlreadyIssued;
        }
        if (self.statePtr().identities.contains(id)) return error.DuplicatePersistentId;

        try self.statePtr().identities.ensureUnusedCapacity(1);
        try self.statePtr().entities.ensureUnusedCapacity(1);

        if (track_registration_identity) {
            const issued_entry = self.statePtr().issued_identities.getOrPutAssumeCapacity(id);
            if (issued_entry.found_existing) return error.PersistentIdAlreadyIssued;
        }

        const entity = flecs.new_id(self.statePtr().world);
        if (entity == 0) return error.EntityCreationFailed;
        errdefer flecs.delete(self.statePtr().world, entity);
        if (flecs.set(self.statePtr().world, entity, PersistentIdentity, .{ .id = id }) == 0) {
            return error.IdentityComponentSetFailed;
        }

        if (self.statePtr().next_entity_serial == 0) return error.EntitySerialExhausted;
        const entity_serial = self.statePtr().next_entity_serial;
        self.statePtr().next_entity_serial +%= 1;
        const runtime_id = RuntimeId{
            .runtime_token = self.statePtr().runtime_token,
            .serial = entity_serial,
        };

        self.statePtr().identities.putAssumeCapacityNoClobber(id, runtime_id);
        self.statePtr().entities.putAssumeCapacityNoClobber(entity_serial, entity);
        if (observe_identity) self.statePtr().identity_source.observe(id) catch unreachable;
        self.statePtr().tracked_entity_count += 1;
        return runtime_id;
    }

    pub fn destroy(self: *Runtime, runtime_id: RuntimeId) !void {
        try self.requireLive();
        const entity = try self.rawEntity(runtime_id);
        const persistent = flecs.get(self.statePtr().world, entity, PersistentIdentity) orelse
            return error.EntityMissingPersistentIdentity;
        const persistent_id = persistent.id;
        const indexed = self.statePtr().identities.get(persistent_id) orelse
            return error.PersistentIndexInvariantBroken;
        if (!std.meta.eql(indexed, runtime_id)) return error.PersistentIndexInvariantBroken;
        flecs.delete(self.statePtr().world, entity);
        const removed_identity = self.statePtr().identities.remove(persistent_id);
        const removed_entity = self.statePtr().entities.remove(runtime_id.serial);
        if (!removed_identity or !removed_entity) {
            @panic("runtime index removal invariant failed");
        }
        std.debug.assert(self.statePtr().tracked_entity_count > 0);
        self.statePtr().tracked_entity_count -= 1;
    }

    pub fn resolve(self: *const Runtime, id: PersistentId) ?RuntimeId {
        return self.statePtr().identities.get(id);
    }

    pub fn identity(self: *const Runtime, runtime_id: RuntimeId) !PersistentId {
        const entity = try self.rawEntity(runtime_id);
        const component = flecs.get(self.statePtr().world, entity, PersistentIdentity) orelse
            return error.EntityMissingPersistentIdentity;
        return component.id;
    }

    pub fn set(self: *Runtime, runtime_id: RuntimeId, comptime T: type, value: T) !void {
        try self.ensureHealthy();
        const entity = try self.rawEntity(runtime_id);
        if (flecs.set(self.statePtr().world, entity, T, value) == 0) return error.ComponentSetFailed;
    }

    pub fn get(self: *const Runtime, runtime_id: RuntimeId, comptime T: type) ?*const T {
        const entity = self.rawEntity(runtime_id) catch return null;
        return flecs.get(self.statePtr().world, entity, T);
    }

    pub fn getMut(self: *Runtime, runtime_id: RuntimeId, comptime T: type) ?*T {
        self.ensureHealthy() catch return null;
        const entity = self.rawEntity(runtime_id) catch return null;
        return flecs.get_mut(self.statePtr().world, entity, T);
    }

    fn rawEntity(self: *const Runtime, runtime_id: RuntimeId) !flecs.entity_t {
        try self.requireLive();
        if (runtime_id.runtime_token != self.statePtr().runtime_token) return error.ForeignRuntimeId;
        const entity = self.statePtr().entities.get(runtime_id.serial) orelse {
            if (runtime_id.serial != 0 and
                (self.statePtr().next_entity_serial == 0 or
                    runtime_id.serial < self.statePtr().next_entity_serial))
            {
                return error.StaleRuntimeId;
            }
            return error.UntrackedRuntimeId;
        };
        if (entity == 0 or !flecs.is_alive(self.statePtr().world, entity)) return error.StaleRuntimeId;
        const persistent = flecs.get(self.statePtr().world, entity, PersistentIdentity) orelse
            return error.UntrackedRuntimeId;
        const indexed = self.statePtr().identities.get(persistent.id) orelse return error.UntrackedRuntimeId;
        if (!std.meta.eql(indexed, runtime_id)) return error.UntrackedRuntimeId;
        return entity;
    }

    pub fn entityCount(self: *const Runtime) usize {
        return self.statePtr().tracked_entity_count;
    }
    pub fn persistentCount(self: *const Runtime) usize {
        return self.statePtr().identities.count();
    }
    pub fn tickIndex(self: *const Runtime) u64 {
        return self.statePtr().completed_ticks;
    }
    pub fn fixedDelta(self: *const Runtime) f32 {
        return self.statePtr().fixed_delta_seconds;
    }
    pub fn namespace(self: *const Runtime) u64 {
        return self.statePtr().identity_source.namespace;
    }
    pub fn nextLocalId(self: *const Runtime) !u64 {
        return self.statePtr().identity_source.cursor() orelse error.IdentitySourceExhausted;
    }

    /// Persistence-only cursor/clock restoration. It is legal only before the
    /// startup registry is frozen.
    pub fn restoreClock(self: *Runtime, completed_ticks: u64, next_local_id: u64) !void {
        if (self.statePtr().lifecycle != .registering) return error.RegistrationClosed;
        const current_cursor = try self.nextLocalId();
        if (next_local_id < current_cursor) return error.IdentityCursorWouldCollide;
        self.statePtr().identity_source = try identity_module.IdentitySource.initAt(
            self.statePtr().identity_source.namespace,
            next_local_id,
        );
        self.statePtr().completed_ticks = completed_ticks;
    }

    fn requireRegistrationOpen(self: *const Runtime) !void {
        try self.requireLive();
        if (self.statePtr().lifecycle != .registering) return error.RegistrationClosed;
    }
    fn requireLive(self: *const Runtime) !void {
        if (self.statePtr().lifecycle == .deinitialized) return error.RuntimeDeinitialized;
    }
};

pub const FeatureRegistry = struct {
    runtime: *Runtime,

    pub fn registerComponent(self: *FeatureRegistry, comptime T: type) !void {
        try self.runtime.requireRegistrationOpen();
        if (@sizeOf(T) == 0) {
            flecs.TAG(self.runtime.statePtr().world, T);
        } else {
            flecs.COMPONENT(self.runtime.statePtr().world, T);
        }
    }

    pub fn addSystem(
        self: *FeatureRegistry,
        phase: Phase,
        name: []const u8,
        context: *anyopaque,
        callback: SystemCallback,
    ) !void {
        try self.runtime.requireRegistrationOpen();
        if (name.len == 0) return error.EmptySystemName;
        for (self.runtime.statePtr().systems.items) |existing| {
            if (std.mem.eql(u8, existing.name, name)) return error.DuplicateSystemName;
        }
        const owned_name = try self.runtime.statePtr().gpa.dupe(u8, name);
        errdefer self.runtime.statePtr().gpa.free(owned_name);
        try self.runtime.statePtr().systems.append(self.runtime.statePtr().gpa, .{
            .phase = phase,
            .name = owned_name,
            .context = context,
            .callback = callback,
        });
    }
};

fn validateConfig(config: Config) !void {
    _ = try identity_module.IdentitySource.initAt(config.namespace, config.next_local_id);
    if (!std.math.isFinite(config.fixed_delta_seconds) or config.fixed_delta_seconds <= 0) {
        return error.InvalidFixedDelta;
    }
}

fn allocateRuntimeToken() !u64 {
    while (!runtime_token_mutex.tryLock()) std.atomic.spinLoopHint();
    defer runtime_token_mutex.unlock();
    if (next_runtime_token == 0) return error.RuntimeTokenExhausted;
    const result = next_runtime_token;
    next_runtime_token +%= 1;
    return result;
}

fn acquireOwnedWorldLease() !void {
    while (!owned_world_mutex.tryLock()) std.atomic.spinLoopHint();
    defer owned_world_mutex.unlock();
    if (owned_world_live) return error.EngineWorldAlreadyLive;
    owned_world_live = true;
}

fn releaseOwnedWorldLease() void {
    while (!owned_world_mutex.tryLock()) std.atomic.spinLoopHint();
    defer owned_world_mutex.unlock();
    if (!owned_world_live) @panic("owned world lease invariant failed");
    owned_world_live = false;
}

test "runtime separates persistent and live identity" {
    var runtime = try Runtime.init(std.testing.allocator, .{
        .namespace = 44,
        .fixed_delta_seconds = 1.0 / 120.0,
    });
    defer runtime.deinit();

    const first = try runtime.create();
    const stable = try runtime.identity(first);
    try std.testing.expectEqual(PersistentId{ .namespace = 44, .local = 1 }, stable);
    try std.testing.expectEqual(first, runtime.resolve(stable).?);
    try runtime.destroy(first);
    try std.testing.expect(runtime.resolve(stable) == null);
    try std.testing.expectError(error.StaleRuntimeId, runtime.identity(first));
    try std.testing.expectError(
        error.PersistentIdAlreadyIssued,
        runtime.createWithPersistentId(stable),
    );

    const second = try runtime.create();
    try std.testing.expectEqual(@as(u64, 2), (try runtime.identity(second)).local);
    try runtime.destroy(second);

    const restored_id = PersistentId{ .namespace = 44, .local = 20 };
    const restored = try runtime.createWithPersistentId(restored_id);
    try runtime.destroy(restored);
    try std.testing.expectError(
        error.PersistentIdAlreadyIssued,
        runtime.createWithPersistentId(restored_id),
    );
}

test "registration allocation failure does not consume an automatic identity" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var runtime = try Runtime.init(failing.allocator(), .{
        .namespace = 43,
        .fixed_delta_seconds = 1.0 / 60.0,
    });
    defer runtime.deinit();

    // Let the issued-ID tombstone map allocate, then fail the first runtime
    // index reservation. All index capacity must be reserved before `next()`.
    failing.fail_index = failing.alloc_index + 1;
    try std.testing.expectError(error.OutOfMemory, runtime.create());

    failing.fail_index = std.math.maxInt(usize);
    const entity = try runtime.create();
    try std.testing.expectEqual(
        PersistentId{ .namespace = 43, .local = 1 },
        try runtime.identity(entity),
    );
    try runtime.destroy(entity);
}

test "schedule is ordered and freezes before first tick" {
    var runtime = try Runtime.init(std.testing.allocator, .{
        .namespace = 1,
        .fixed_delta_seconds = 0.25,
    });
    defer runtime.deinit();
    var values: std.ArrayListUnmanaged(u8) = .empty;
    defer values.deinit(std.testing.allocator);
    const SharedCounter = struct {
        list: *std.ArrayListUnmanaged(u8),
        allocator: std.mem.Allocator,
        marker: u8,
        fn run(raw: *anyopaque, _: *Runtime, tick: TickContext) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            try std.testing.expectEqual(@as(u64, 1), tick.tick_index);
            try self.list.append(self.allocator, self.marker);
        }
    };
    var first = SharedCounter{ .list = &values, .allocator = std.testing.allocator, .marker = 1 };
    var second = SharedCounter{ .list = &values, .allocator = std.testing.allocator, .marker = 2 };
    var pre = SharedCounter{ .list = &values, .allocator = std.testing.allocator, .marker = 3 };
    var physics_step = SharedCounter{ .list = &values, .allocator = std.testing.allocator, .marker = 4 };
    var post = SharedCounter{ .list = &values, .allocator = std.testing.allocator, .marker = 5 };

    var registry = runtime.registry();
    // Register phases out of order to prove phase order is declared by the
    // runtime, while order inside one phase remains registration order.
    try registry.addSystem(.post_physics, "test.post", &post, SharedCounter.run);
    try registry.addSystem(.commands, "test.command.first", &first, SharedCounter.run);
    try registry.addSystem(.physics, "test.physics", &physics_step, SharedCounter.run);
    try registry.addSystem(.commands, "test.command.second", &second, SharedCounter.run);
    try registry.addSystem(.pre_physics, "test.pre", &pre, SharedCounter.run);
    try runtime.tick();
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5 }, values.items);
    try std.testing.expectEqual(@as(u64, 1), runtime.tickIndex());
    try std.testing.expectError(
        error.RegistrationClosed,
        registry.addSystem(.commands, "test.too-late", &first, SharedCounter.run),
    );
}

test "registry owns system names instead of borrowing caller storage" {
    const Noop = struct {
        fn run(_: *anyopaque, _: *Runtime, _: TickContext) !void {}
    };
    var runtime = try Runtime.init(std.testing.allocator, .{
        .namespace = 2,
        .fixed_delta_seconds = 1.0 / 120.0,
    });
    defer runtime.deinit();
    var context: u8 = 0;
    var mutable_name = [_]u8{ 't', 'e', 's', 't', '.', 'o', 'w', 'n', 'e', 'd' };
    var registry = runtime.registry();
    try registry.addSystem(.commands, &mutable_name, &context, Noop.run);
    mutable_name[0] = 'X';
    try std.testing.expectError(
        error.DuplicateSystemName,
        registry.addSystem(.commands, "test.owned", &context, Noop.run),
    );
}

test "runtime IDs cannot alias a later runtime" {
    var first = try Runtime.init(std.testing.allocator, .{
        .namespace = 101,
        .fixed_delta_seconds = 1.0 / 60.0,
    });
    const first_entity = try first.create();
    try std.testing.expectError(error.UntrackedRuntimeId, first.identity(.{
        .runtime_token = first_entity.runtime_token,
        .serial = first_entity.serial + 1,
    }));
    try first.destroy(first_entity);
    first.deinit();

    var second = try Runtime.init(std.testing.allocator, .{
        .namespace = 202,
        .fixed_delta_seconds = 1.0 / 60.0,
    });
    defer second.deinit();
    try std.testing.expectError(error.ForeignRuntimeId, second.identity(first_entity));
}

test "a scheduled failure terminally faults the runtime" {
    const Failure = struct {
        fn run(_: *anyopaque, _: *Runtime, _: TickContext) !void {
            return error.SyntheticSystemFailure;
        }
    };
    var runtime = try Runtime.init(std.testing.allocator, .{
        .namespace = 303,
        .fixed_delta_seconds = 1.0 / 120.0,
    });
    defer runtime.deinit();
    var context: u8 = 0;
    var registry = runtime.registry();
    try registry.addSystem(.physics, "test.failure", &context, Failure.run);
    try std.testing.expectError(error.SyntheticSystemFailure, runtime.tick());
    try std.testing.expectEqual(@as(u64, 0), runtime.tickIndex());
    try std.testing.expectError(error.RuntimeFaulted, runtime.tick());
}

test "a second owned world returns a defined error before zflecs asserts" {
    var runtime = try Runtime.init(std.testing.allocator, .{
        .namespace = 404,
        .fixed_delta_seconds = 1.0 / 120.0,
    });
    defer runtime.deinit();
    try std.testing.expectError(
        error.EngineWorldAlreadyLive,
        Runtime.init(std.testing.allocator, .{
            .namespace = 405,
            .fixed_delta_seconds = 1.0 / 120.0,
        }),
    );
}
