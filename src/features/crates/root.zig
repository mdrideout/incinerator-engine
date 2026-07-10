//! CrateFeature: the first complete engine vertical slice.

const std = @import("std");
const engine = @import("incinerator_engine");

pub const Assets = struct {
    mesh: engine.rendering.MeshHandle = .invalid,
    material: engine.rendering.MaterialHandle = .invalid,
};

pub const SpawnCrate = struct {
    request_id: u64,
    pose: engine.physics.Pose,
    velocity: engine.physics.Velocity = .{},
    half_extents: [3]f32 = .{ 0.5, 0.5, 0.5 },
};

pub const DespawnEntity = struct { id: engine.PersistentId };
pub const ApplyImpulse = struct {
    id: engine.PersistentId,
    impulse: [3]f32,
};

pub const Command = union(enum) {
    spawn: SpawnCrate,
    despawn: DespawnEntity,
    impulse: ApplyImpulse,
};

pub const Spawned = struct {
    request_id: u64,
    id: engine.PersistentId,
};

pub const CommandKind = enum { spawn, despawn, impulse };
pub const RejectionReason = enum { capacity_reached, crate_not_found, not_owned };
pub const CommandRejected = struct {
    command: CommandKind,
    reason: RejectionReason,
    request_id: ?u64 = null,
    id: ?engine.PersistentId = null,
};

pub const Outcome = union(enum) {
    spawned: Spawned,
    despawned: engine.PersistentId,
    impulse_applied: engine.PersistentId,
    rejected: CommandRejected,
};

pub const CrateView = struct {
    id: engine.PersistentId,
    half_extents: [3]f32,
    state: engine.physics.BodyState,
};

/// Immutable feature-owned presentation record. It contains no backend
/// pointers and transfers no resource ownership.
pub const CrateDraw = struct {
    persistent_id: engine.PersistentId,
    pose: engine.physics.Pose,
    half_extents: [3]f32,
    mesh: engine.rendering.MeshHandle,
    material: engine.rendering.MaterialHandle,
};

pub const CrateV1 = struct {
    id: engine.PersistentId,
    half_extents: [3]f32,
    pose: engine.physics.Pose,
    linear_velocity: [3]f32,
    angular_velocity: [3]f32,
};

pub const SnapshotV1 = struct {
    schema_version: u16,
    completed_ticks: u64,
    fixed_delta_seconds: f32,
    namespace: u64,
    next_local_id: u64,
    crates: []const CrateV1,
};

pub const max_snapshot_bytes: usize = 8 * 1024 * 1024;

pub fn parseSnapshot(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    max_crates: usize,
) !std.json.Parsed(SnapshotV1) {
    if (bytes.len > max_snapshot_bytes) return error.SnapshotTooLarge;
    var parsed = try std.json.parseFromSlice(SnapshotV1, allocator, bytes, .{});
    errdefer parsed.deinit();
    try validateSnapshot(parsed.value, max_crates);
    return parsed;
}

pub fn validateSnapshot(snapshot: SnapshotV1, max_crates: usize) !void {
    if (snapshot.schema_version != 1) return error.UnsupportedSchemaVersion;
    if (snapshot.namespace == 0) return error.InvalidIdentityNamespace;
    if (snapshot.next_local_id == 0) return error.InvalidIdentityCursor;
    if (!std.math.isFinite(snapshot.fixed_delta_seconds) or
        snapshot.fixed_delta_seconds <= 0)
    {
        return error.InvalidFixedDelta;
    }
    if (snapshot.crates.len > max_crates) return error.TooManyCrates;

    for (snapshot.crates, 0..) |record, index| {
        try record.id.validate();
        if (record.id.namespace != snapshot.namespace) {
            return error.ForeignIdentityNamespace;
        }
        if (record.id.local >= snapshot.next_local_id) {
            return error.IdentityCursorWouldCollide;
        }
        try (engine.physics.DynamicBoxDesc{
            .pose = record.pose,
            .velocity = .{
                .linear = record.linear_velocity,
                .angular = record.angular_velocity,
            },
            .half_extents = record.half_extents,
        }).validate();
        for (snapshot.crates[0..index]) |earlier| {
            if (std.meta.eql(earlier.id, record.id)) return error.DuplicatePersistentId;
        }
    }
}

pub fn Feature(comptime Bodies: type) type {
    engine.physics.assertImplementation(Bodies);

    return struct {
        const Self = @This();

        const Crate = struct { half_extents: [3]f32 };
        const PhysicsDriven = struct { enabled: bool = true };
        const RuntimeBody = struct { handle: Bodies.Handle };
        const TransformHistory = struct {
            previous: engine.physics.Pose,
            current: engine.physics.Pose,
            current_tick: u64,
        };
        const QueuedCommand = struct {
            command: Command,
            eligible_tick: u64,
        };

        allocator: std.mem.Allocator,
        runtime: *engine.Runtime,
        bodies: *Bodies,
        assets: Assets,
        max_crates: usize,
        pending: std.ArrayListUnmanaged(QueuedCommand) = .empty,
        applying: std.ArrayListUnmanaged(QueuedCommand) = .empty,
        applying_index: usize = 0,
        active: std.ArrayListUnmanaged(engine.RuntimeId) = .empty,
        outcomes: std.ArrayListUnmanaged(Outcome) = .empty,
        presentations: std.ArrayListUnmanaged(CrateDraw) = .empty,

        pub fn init(
            allocator: std.mem.Allocator,
            runtime: *engine.Runtime,
            bodies: *Bodies,
            assets: Assets,
            max_crates: usize,
        ) !Self {
            if (max_crates == 0) return error.InvalidCrateLimit;
            return .{
                .allocator = allocator,
                .runtime = runtime,
                .bodies = bodies,
                .assets = assets,
                .max_crates = max_crates,
            };
        }

        pub fn register(self: *Self, registry: *engine.FeatureRegistry) !void {
            try registry.registerComponent(Crate);
            try registry.registerComponent(PhysicsDriven);
            try registry.registerComponent(RuntimeBody);
            try registry.registerComponent(TransformHistory);
            try registry.addSystem(
                .commands,
                "crates.apply_commands",
                self,
                applyCommandsSystem,
            );
            try registry.addSystem(
                .post_physics,
                "crates.publish_physics",
                self,
                publishPhysicsSystem,
            );
        }

        pub fn deinit(self: *Self) void {
            while (self.active.items.len > 0) {
                const runtime_id = self.active.items[self.active.items.len - 1];
                if (self.runtime.get(runtime_id, RuntimeBody)) |body| {
                    self.destroyBodyOrPanic(body.handle);
                }
                self.destroyRuntimeOrPanic(runtime_id);
                _ = self.active.pop();
            }
            self.pending.deinit(self.allocator);
            self.applying.deinit(self.allocator);
            self.active.deinit(self.allocator);
            self.outcomes.deinit(self.allocator);
            self.presentations.deinit(self.allocator);
            self.* = undefined;
        }

        pub fn enqueue(self: *Self, command: Command) !void {
            try self.runtime.ensureHealthy();
            try validateCommand(command);
            try self.pending.append(self.allocator, .{
                .command = command,
                .eligible_tick = try self.runtime.commandTargetTick(),
            });
        }

        pub fn pollOutcome(self: *Self) ?Outcome {
            if (self.outcomes.items.len == 0) return null;
            return self.outcomes.orderedRemove(0);
        }

        pub fn count(self: *const Self) usize {
            return self.active.items.len;
        }

        pub fn hasPendingCommands(self: *const Self) bool {
            return self.pending.items.len != 0 or
                self.applying_index < self.applying.items.len;
        }

        pub fn view(self: *Self, id: engine.PersistentId) !CrateView {
            const runtime_id = self.runtime.resolve(id) orelse return error.CrateNotFound;
            const crate = self.runtime.get(runtime_id, Crate) orelse return error.NotACrate;
            try self.requirePhysicsAuthority(runtime_id);
            const body = self.runtime.get(runtime_id, RuntimeBody) orelse
                return error.CrateBodyInvariantBroken;
            const state = try (try self.bodies.bodyState(body.handle)).normalized();
            return .{
                .id = id,
                .half_extents = crate.half_extents,
                .state = state,
            };
        }

        pub fn extract(self: *Self, alpha: f32) ![]const CrateDraw {
            if (!std.math.isFinite(alpha)) return error.InvalidInterpolationAlpha;
            self.presentations.clearRetainingCapacity();
            try self.presentations.ensureTotalCapacity(self.allocator, self.active.items.len);

            for (self.active.items) |runtime_id| {
                try self.requirePhysicsAuthority(runtime_id);
                const history = self.runtime.get(runtime_id, TransformHistory) orelse
                    return error.CrateTransformInvariantBroken;
                if (history.current_tick != self.runtime.tickIndex()) {
                    return error.CrateTransformTickInvariantBroken;
                }
                const crate = self.runtime.get(runtime_id, Crate) orelse
                    return error.NotACrate;
                self.presentations.appendAssumeCapacity(.{
                    .persistent_id = try self.runtime.identity(runtime_id),
                    .pose = try engine.transform.interpolate(
                        history.previous,
                        history.current,
                        alpha,
                    ),
                    .half_extents = crate.half_extents,
                    .mesh = self.assets.mesh,
                    .material = self.assets.material,
                });
            }
            return self.presentations.items;
        }

        pub fn save(self: *Self, allocator: std.mem.Allocator) ![]u8 {
            try self.runtime.ensureSnapshotBoundary();
            if (self.hasPendingCommands()) return error.CommandsPending;

            const records = try allocator.alloc(CrateV1, self.active.items.len);
            defer allocator.free(records);
            for (self.active.items, 0..) |runtime_id, index| {
                try self.requirePhysicsAuthority(runtime_id);
                const history = self.runtime.get(runtime_id, TransformHistory) orelse
                    return error.CrateTransformInvariantBroken;
                if (history.current_tick != self.runtime.tickIndex()) {
                    return error.CrateTransformTickInvariantBroken;
                }
                const crate = self.runtime.get(runtime_id, Crate) orelse
                    return error.NotACrate;
                const body = self.runtime.get(runtime_id, RuntimeBody) orelse
                    return error.CrateBodyInvariantBroken;
                const state = try (try self.bodies.bodyState(body.handle)).normalized();
                records[index] = .{
                    .id = try self.runtime.identity(runtime_id),
                    .half_extents = crate.half_extents,
                    .pose = try state.pose.normalized(),
                    .linear_velocity = state.velocity.linear,
                    .angular_velocity = state.velocity.angular,
                };
            }
            std.mem.sort(CrateV1, records, {}, lessThanRecord);

            return std.json.Stringify.valueAlloc(allocator, SnapshotV1{
                .schema_version = 1,
                .completed_ticks = self.runtime.tickIndex(),
                .fixed_delta_seconds = self.runtime.fixedDelta(),
                .namespace = self.runtime.namespace(),
                .next_local_id = try self.runtime.nextLocalId(),
                .crates = records,
            }, .{});
        }

        /// Restore into a newly initialized, still-registering feature. The
        /// operation rolls back every recreated crate if any record fails.
        pub fn restoreSnapshot(self: *Self, snapshot: SnapshotV1) !void {
            try validateSnapshot(snapshot, self.max_crates);
            if (self.active.items.len != 0 or self.hasPendingCommands()) {
                return error.RestoreRequiresEmptyFeature;
            }
            if (snapshot.namespace != self.runtime.namespace()) {
                return error.ForeignIdentityNamespace;
            }
            if (snapshot.fixed_delta_seconds != self.runtime.fixedDelta()) {
                return error.FixedDeltaMismatch;
            }

            errdefer self.rollbackAll();
            for (snapshot.crates) |record| {
                _ = try self.spawnNow(.{
                    .request_id = 0,
                    .pose = record.pose,
                    .velocity = .{
                        .linear = record.linear_velocity,
                        .angular = record.angular_velocity,
                    },
                    .half_extents = record.half_extents,
                }, record.id, false);
            }
            try self.runtime.restoreClock(snapshot.completed_ticks, snapshot.next_local_id);
        }

        fn applyCommandsSystem(
            raw: *anyopaque,
            _: *engine.Runtime,
            tick: engine.TickContext,
        ) !void {
            const self: *Self = @ptrCast(@alignCast(raw));
            if (self.applying_index >= self.applying.items.len) {
                self.applying.clearRetainingCapacity();
                self.applying_index = 0;
                std.mem.swap(
                    std.ArrayListUnmanaged(QueuedCommand),
                    &self.pending,
                    &self.applying,
                );
            }

            try self.pending.ensureUnusedCapacity(
                self.allocator,
                self.applying.items.len - self.applying_index,
            );

            while (self.applying_index < self.applying.items.len) {
                const queued = self.applying.items[self.applying_index];
                self.applying_index += 1;
                if (queued.eligible_tick > tick.tick_index) {
                    self.pending.appendAssumeCapacity(queued);
                    continue;
                }
                const command = queued.command;
                switch (command) {
                    .spawn => |spawn| {
                        _ = self.spawnNow(spawn, null, true) catch |err| switch (err) {
                            error.TooManyCrates => {
                                try self.reject(.{
                                    .command = .spawn,
                                    .reason = .capacity_reached,
                                    .request_id = spawn.request_id,
                                });
                                continue;
                            },
                            else => return err,
                        };
                    },
                    .despawn => |despawn| {
                        self.despawnNow(despawn.id, true) catch |err| switch (err) {
                            error.CrateNotFound => try self.reject(.{
                                .command = .despawn,
                                .reason = .crate_not_found,
                                .id = despawn.id,
                            }),
                            error.NotACrate => try self.reject(.{
                                .command = .despawn,
                                .reason = .not_owned,
                                .id = despawn.id,
                            }),
                            else => return err,
                        };
                    },
                    .impulse => |impulse| {
                        self.impulseNow(impulse, true) catch |err| switch (err) {
                            error.CrateNotFound => try self.reject(.{
                                .command = .impulse,
                                .reason = .crate_not_found,
                                .id = impulse.id,
                            }),
                            error.NotACrate => try self.reject(.{
                                .command = .impulse,
                                .reason = .not_owned,
                                .id = impulse.id,
                            }),
                            else => return err,
                        };
                    },
                }
            }
            self.applying.clearRetainingCapacity();
            self.applying_index = 0;
        }

        fn publishPhysicsSystem(
            raw: *anyopaque,
            _: *engine.Runtime,
            tick: engine.TickContext,
        ) !void {
            const self: *Self = @ptrCast(@alignCast(raw));
            for (self.active.items) |runtime_id| {
                try self.requirePhysicsAuthority(runtime_id);
                const body = self.runtime.get(runtime_id, RuntimeBody) orelse
                    return error.CrateBodyInvariantBroken;
                const history = self.runtime.getMut(runtime_id, TransformHistory) orelse
                    return error.CrateTransformInvariantBroken;
                const state = try (try self.bodies.bodyState(body.handle)).normalized();
                history.previous = history.current;
                history.current = state.pose;
                history.current_tick = tick.tick_index;
            }
        }

        fn spawnNow(
            self: *Self,
            spawn: SpawnCrate,
            restored_id: ?engine.PersistentId,
            emit_outcome: bool,
        ) !engine.PersistentId {
            const desc = try (engine.physics.DynamicBoxDesc{
                .pose = spawn.pose,
                .velocity = spawn.velocity,
                .half_extents = spawn.half_extents,
            }).normalized();
            if (self.active.items.len >= self.max_crates) return error.TooManyCrates;

            try self.active.ensureUnusedCapacity(self.allocator, 1);
            if (emit_outcome) try self.outcomes.ensureUnusedCapacity(self.allocator, 1);

            const runtime_id = if (restored_id) |id|
                try self.runtime.createWithPersistentId(id)
            else
                try self.runtime.create();
            errdefer self.destroyRuntimeOrPanic(runtime_id);

            const id = try self.runtime.identity(runtime_id);
            const body = try self.bodies.createDynamicBox(desc);
            errdefer self.destroyBodyOrPanic(body);

            try self.runtime.set(runtime_id, Crate, .{ .half_extents = desc.half_extents });
            try self.runtime.set(runtime_id, PhysicsDriven, .{});
            try self.runtime.set(runtime_id, RuntimeBody, .{ .handle = body });
            try self.runtime.set(runtime_id, TransformHistory, .{
                .previous = desc.pose,
                .current = desc.pose,
                .current_tick = self.runtime.tickIndex(),
            });
            self.active.appendAssumeCapacity(runtime_id);
            if (emit_outcome) {
                self.outcomes.appendAssumeCapacity(.{ .spawned = .{
                    .request_id = spawn.request_id,
                    .id = id,
                } });
            }
            return id;
        }

        fn despawnNow(self: *Self, id: engine.PersistentId, emit_outcome: bool) !void {
            const runtime_id = self.runtime.resolve(id) orelse return error.CrateNotFound;
            _ = self.runtime.get(runtime_id, Crate) orelse return error.NotACrate;
            try self.requirePhysicsAuthority(runtime_id);
            const body = self.runtime.get(runtime_id, RuntimeBody) orelse
                return error.CrateBodyInvariantBroken;
            _ = try self.runtime.identity(runtime_id);
            const index = self.activeIndex(runtime_id) orelse
                return error.CrateActiveIndexInvariantBroken;
            if (emit_outcome) try self.outcomes.ensureUnusedCapacity(self.allocator, 1);

            try self.bodies.destroyBody(body.handle);
            self.destroyRuntimeOrPanic(runtime_id);
            _ = self.active.orderedRemove(index);
            if (emit_outcome) self.outcomes.appendAssumeCapacity(.{ .despawned = id });
        }

        fn impulseNow(self: *Self, impulse: ApplyImpulse, emit_outcome: bool) !void {
            const runtime_id = self.runtime.resolve(impulse.id) orelse
                return error.CrateNotFound;
            _ = self.runtime.get(runtime_id, Crate) orelse return error.NotACrate;
            try self.requirePhysicsAuthority(runtime_id);
            const body = self.runtime.get(runtime_id, RuntimeBody) orelse
                return error.CrateBodyInvariantBroken;
            if (emit_outcome) try self.outcomes.ensureUnusedCapacity(self.allocator, 1);
            try self.bodies.applyImpulse(body.handle, impulse.impulse);
            if (emit_outcome) {
                self.outcomes.appendAssumeCapacity(.{ .impulse_applied = impulse.id });
            }
        }

        fn activeIndex(self: *const Self, runtime_id: engine.RuntimeId) ?usize {
            for (self.active.items, 0..) |candidate, index| {
                if (std.meta.eql(candidate, runtime_id)) return index;
            }
            return null;
        }

        fn requirePhysicsAuthority(self: *const Self, runtime_id: engine.RuntimeId) !void {
            const authority = self.runtime.get(runtime_id, PhysicsDriven) orelse
                return error.CrateAuthorityInvariantBroken;
            if (!authority.enabled) return error.CrateAuthorityInvariantBroken;
        }

        fn reject(self: *Self, rejection: CommandRejected) !void {
            try self.outcomes.append(self.allocator, .{ .rejected = rejection });
        }

        fn rollbackAll(self: *Self) void {
            while (self.active.items.len > 0) {
                const runtime_id = self.active.items[self.active.items.len - 1];
                if (self.runtime.get(runtime_id, RuntimeBody)) |body| {
                    self.destroyBodyOrPanic(body.handle);
                }
                self.destroyRuntimeOrPanic(runtime_id);
                _ = self.active.pop();
            }
        }

        fn destroyBodyOrPanic(self: *Self, body: Bodies.Handle) void {
            self.bodies.destroyBody(body) catch |err| {
                std.debug.panic(
                    "crate body cleanup invariant failed: {s}",
                    .{@errorName(err)},
                );
            };
        }

        fn destroyRuntimeOrPanic(self: *Self, runtime_id: engine.RuntimeId) void {
            self.runtime.destroy(runtime_id) catch |err| {
                std.debug.panic(
                    "crate entity cleanup invariant failed: {s}",
                    .{@errorName(err)},
                );
            };
        }
    };
}

fn validateCommand(command: Command) !void {
    switch (command) {
        .spawn => |spawn| try (engine.physics.DynamicBoxDesc{
            .pose = spawn.pose,
            .velocity = spawn.velocity,
            .half_extents = spawn.half_extents,
        }).validate(),
        .despawn => |despawn| try despawn.id.validate(),
        .impulse => |impulse| {
            try impulse.id.validate();
            for (impulse.impulse) |value| {
                if (!std.math.isFinite(value)) return error.InvalidImpulse;
            }
        },
    }
}

fn lessThanRecord(_: void, lhs: CrateV1, rhs: CrateV1) bool {
    if (lhs.id.namespace != rhs.id.namespace) return lhs.id.namespace < rhs.id.namespace;
    return lhs.id.local < rhs.id.local;
}

test "V1 validation rejects duplicate identities and colliding cursor" {
    const records = [_]CrateV1{
        .{
            .id = .{ .namespace = 9, .local = 1 },
            .half_extents = .{ 0.5, 0.5, 0.5 },
            .pose = .{},
            .linear_velocity = .{ 0, 0, 0 },
            .angular_velocity = .{ 0, 0, 0 },
        },
        .{
            .id = .{ .namespace = 9, .local = 1 },
            .half_extents = .{ 0.5, 0.5, 0.5 },
            .pose = .{},
            .linear_velocity = .{ 0, 0, 0 },
            .angular_velocity = .{ 0, 0, 0 },
        },
    };
    try std.testing.expectError(error.DuplicatePersistentId, validateSnapshot(.{
        .schema_version = 1,
        .completed_ticks = 0,
        .fixed_delta_seconds = 1.0 / 120.0,
        .namespace = 9,
        .next_local_id = 2,
        .crates = &records,
    }, 8));

    try std.testing.expectError(error.IdentityCursorWouldCollide, validateSnapshot(.{
        .schema_version = 1,
        .completed_ticks = 0,
        .fixed_delta_seconds = 1.0 / 120.0,
        .namespace = 9,
        .next_local_id = 1,
        .crates = records[0..1],
    }, 8));
}

test "V1 parser requires an explicit supported schema version" {
    const missing_version =
        \\{"completed_ticks":0,"fixed_delta_seconds":0.008333333,
        \\"namespace":9,"next_local_id":1,"crates":[]}
    ;
    try std.testing.expectError(
        error.MissingField,
        parseSnapshot(std.testing.allocator, missing_version, 8),
    );

    const unknown_version =
        \\{"schema_version":2,"completed_ticks":0,
        \\"fixed_delta_seconds":0.008333333,"namespace":9,
        \\"next_local_id":1,"crates":[]}
    ;
    try std.testing.expectError(
        error.UnsupportedSchemaVersion,
        parseSnapshot(std.testing.allocator, unknown_version, 8),
    );
}

const FakeBodiesForTest = struct {
    pub const Handle = u32;

    states: [16]engine.physics.BodyState = [_]engine.physics.BodyState{.{}} ** 16,
    live: [16]bool = [_]bool{false} ** 16,
    next_handle: u32 = 0,
    live_count: u32 = 0,
    create_calls: u32 = 0,
    fail_create_call: ?u32 = null,
    fail_body_state: bool = false,
    fail_step: bool = false,

    pub fn createDynamicBox(
        self: *FakeBodiesForTest,
        desc: engine.physics.DynamicBoxDesc,
    ) !Handle {
        self.create_calls += 1;
        if (self.fail_create_call == self.create_calls) return error.InjectedBodyCreateFailure;
        const normalized = try desc.normalized();
        if (self.next_handle >= self.states.len) return error.FakeCapacityReached;
        const handle = self.next_handle;
        self.next_handle += 1;
        self.states[handle] = .{ .pose = normalized.pose, .velocity = normalized.velocity };
        self.live[handle] = true;
        self.live_count += 1;
        return handle;
    }

    pub fn destroyBody(self: *FakeBodiesForTest, handle: Handle) !void {
        if (handle >= self.live.len or !self.live[handle]) return error.InvalidFakeBody;
        self.live[handle] = false;
        self.live_count -= 1;
    }

    pub fn bodyState(
        self: *FakeBodiesForTest,
        handle: Handle,
    ) !engine.physics.BodyState {
        if (handle >= self.live.len or !self.live[handle]) return error.InvalidFakeBody;
        if (self.fail_body_state) return error.InjectedBodyReadFailure;
        return self.states[handle];
    }

    pub fn applyImpulse(
        self: *FakeBodiesForTest,
        handle: Handle,
        impulse: [3]f32,
    ) !void {
        if (handle >= self.live.len or !self.live[handle]) return error.InvalidFakeBody;
        for (0..3) |axis| self.states[handle].velocity.linear[axis] += impulse[axis];
    }

    pub fn step(self: *FakeBodiesForTest, _: f32) !void {
        if (self.fail_step) return error.InjectedPhysicsStepFailure;
    }
};

const TestFeature = Feature(FakeBodiesForTest);

fn stepFakeBodies(
    raw: *anyopaque,
    _: *engine.Runtime,
    tick: engine.TickContext,
) !void {
    const bodies: *FakeBodiesForTest = @ptrCast(@alignCast(raw));
    try bodies.step(tick.delta_seconds);
}

test "body creation failure rolls back the provisional runtime entity" {
    var runtime = try engine.Runtime.init(std.testing.allocator, .{
        .namespace = 501,
        .fixed_delta_seconds = 1.0 / 120.0,
    });
    defer runtime.deinit();
    var bodies = FakeBodiesForTest{ .fail_create_call = 1 };
    var feature = try TestFeature.init(
        std.testing.allocator,
        &runtime,
        &bodies,
        .{},
        4,
    );
    defer feature.deinit();
    var registry = runtime.registry();
    try feature.register(&registry);
    try registry.addSystem(.physics, "fake.step", &bodies, stepFakeBodies);
    try feature.enqueue(.{ .spawn = .{ .request_id = 1, .pose = .{} } });

    try std.testing.expectError(error.InjectedBodyCreateFailure, runtime.tick());
    try std.testing.expectEqual(@as(usize, 0), feature.count());
    try std.testing.expectEqual(@as(usize, 0), runtime.entityCount());
    try std.testing.expectEqual(@as(u32, 0), bodies.live_count);
}

test "restore failure rolls back every recreated crate" {
    var runtime = try engine.Runtime.init(std.testing.allocator, .{
        .namespace = 502,
        .fixed_delta_seconds = 1.0 / 120.0,
    });
    defer runtime.deinit();
    var bodies = FakeBodiesForTest{ .fail_create_call = 2 };
    var feature = try TestFeature.init(
        std.testing.allocator,
        &runtime,
        &bodies,
        .{},
        4,
    );
    defer feature.deinit();
    var registry = runtime.registry();
    try feature.register(&registry);

    const records = [_]CrateV1{
        .{
            .id = .{ .namespace = 502, .local = 1 },
            .half_extents = .{ 0.5, 0.5, 0.5 },
            .pose = .{},
            .linear_velocity = .{ 0, 0, 0 },
            .angular_velocity = .{ 0, 0, 0 },
        },
        .{
            .id = .{ .namespace = 502, .local = 2 },
            .half_extents = .{ 0.5, 0.5, 0.5 },
            .pose = .{ .position = .{ 1, 0, 0 } },
            .linear_velocity = .{ 0, 0, 0 },
            .angular_velocity = .{ 0, 0, 0 },
        },
    };
    try std.testing.expectError(error.InjectedBodyCreateFailure, feature.restoreSnapshot(.{
        .schema_version = 1,
        .completed_ticks = 0,
        .fixed_delta_seconds = 1.0 / 120.0,
        .namespace = 502,
        .next_local_id = 3,
        .crates = &records,
    }));
    try std.testing.expectEqual(@as(usize, 0), feature.count());
    try std.testing.expectEqual(@as(usize, 0), runtime.entityCount());
    try std.testing.expectEqual(@as(u32, 0), bodies.live_count);
}

const DeferredEmitter = struct {
    feature: *TestFeature,
    emitted: bool = false,

    fn run(raw: *anyopaque, _: *engine.Runtime, _: engine.TickContext) !void {
        const self: *DeferredEmitter = @ptrCast(@alignCast(raw));
        if (self.emitted) return;
        self.emitted = true;
        try self.feature.enqueue(.{ .spawn = .{ .request_id = 7, .pose = .{} } });
    }
};

test "a command emitted during the command phase waits for the next tick" {
    var runtime = try engine.Runtime.init(std.testing.allocator, .{
        .namespace = 503,
        .fixed_delta_seconds = 1.0 / 120.0,
    });
    defer runtime.deinit();
    var bodies = FakeBodiesForTest{};
    var feature = try TestFeature.init(
        std.testing.allocator,
        &runtime,
        &bodies,
        .{},
        4,
    );
    defer feature.deinit();
    var emitter = DeferredEmitter{ .feature = &feature };
    var registry = runtime.registry();
    try registry.addSystem(.commands, "test.emit_command", &emitter, DeferredEmitter.run);
    try feature.register(&registry);
    try registry.addSystem(.physics, "fake.step", &bodies, stepFakeBodies);

    try runtime.tick();
    try std.testing.expectEqual(@as(usize, 0), feature.count());
    try runtime.tick();
    try std.testing.expectEqual(@as(usize, 1), feature.count());
    const id = switch (feature.pollOutcome().?) {
        .spawned => |spawned| spawned.id,
        else => return error.UnexpectedOutcome,
    };
    try feature.enqueue(.{ .despawn = .{ .id = id } });
    try runtime.tick();
    try std.testing.expectEqual(@as(usize, 0), feature.count());
}

test "a post-physics read failure faults commands and persistence but still tears down" {
    var runtime = try engine.Runtime.init(std.testing.allocator, .{
        .namespace = 504,
        .fixed_delta_seconds = 1.0 / 120.0,
    });
    defer runtime.deinit();
    var bodies = FakeBodiesForTest{ .fail_body_state = true };
    var feature = try TestFeature.init(
        std.testing.allocator,
        &runtime,
        &bodies,
        .{},
        4,
    );
    defer feature.deinit();
    var registry = runtime.registry();
    try feature.register(&registry);
    try registry.addSystem(.physics, "fake.step", &bodies, stepFakeBodies);
    try feature.enqueue(.{ .spawn = .{ .request_id = 1, .pose = .{} } });

    try std.testing.expectError(error.InjectedBodyReadFailure, runtime.tick());
    try std.testing.expect(runtime.isFaulted());
    try std.testing.expectEqual(@as(usize, 1), feature.count());
    try std.testing.expectError(
        error.RuntimeFaulted,
        feature.enqueue(.{ .spawn = .{ .request_id = 2, .pose = .{} } }),
    );
    try std.testing.expectError(error.RuntimeFaulted, feature.save(std.testing.allocator));
}
