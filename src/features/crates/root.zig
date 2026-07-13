//! CrateFeature: the first complete engine vertical slice.

const std = @import("std");
const engine = @import("incinerator_engine");

const logical_state_domain = "incinerator.crates.logical";
const logical_state_schema: u16 = 2;

/// Per-world authority budgets. Every accepted command retains one outcome
/// reservation until it is applied (or, for relocation, post-physics commit).
pub const max_pending_commands: usize = 128;
pub const max_outcomes: usize = 128;

pub const Budget = struct {
    commands: u32 = max_pending_commands,
    outcomes: u32 = max_outcomes,
};

pub const declared_budget = Budget{};

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

/// How a relocation derives the authoritative velocity installed with its
/// target pose. `preserve` samples the body at the commit boundary, `zero`
/// deliberately stops it, and `exact` supports precise undo/redo change sets.
pub const RelocationVelocity = union(enum) {
    preserve,
    zero,
    exact: engine.physics.Velocity,
};

pub const RelocateCrate = struct {
    transaction_id: u64,
    id: engine.PersistentId,
    target_pose: engine.physics.Pose,
    velocity: RelocationVelocity = .zero,
    /// Optimistic authoring concurrency, intentionally independent of ordinary
    /// physics motion. Revision zero is the initial/restored crate revision.
    expected_revision: ?u64 = null,
};

pub const Command = union(enum) {
    spawn: SpawnCrate,
    despawn: DespawnEntity,
    impulse: ApplyImpulse,
    relocate: RelocateCrate,
};

pub const Spawned = struct {
    request_id: u64,
    id: engine.PersistentId,
};

pub const Relocated = struct {
    transaction_id: u64,
    id: engine.PersistentId,
    before: engine.physics.BodyState,
    after: engine.physics.BodyState,
    committed_revision: u64,
};

pub const CommandKind = enum { spawn, despawn, impulse, relocate };
pub const RejectionReason = enum {
    capacity_reached,
    crate_not_found,
    not_owned,
    state_conflict,
};
pub const CommandRejected = struct {
    command: CommandKind,
    reason: RejectionReason,
    request_id: ?u64 = null,
    transaction_id: ?u64 = null,
    id: ?engine.PersistentId = null,
    expected_revision: ?u64 = null,
    actual_revision: ?u64 = null,
};

pub const Outcome = union(enum) {
    spawned: Spawned,
    despawned: engine.PersistentId,
    impulse_applied: engine.PersistentId,
    relocated: Relocated,
    rejected: CommandRejected,
};

pub const CrateView = struct {
    id: engine.PersistentId,
    half_extents: [3]f32,
    state: engine.physics.BodyState,
    authoring_revision: u64,
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

pub const Diagnostics = struct {
    active_count: u32,
    commands: engine.contracts.diagnostics.QueueStats,
    outcomes: engine.contracts.diagnostics.QueueStats,
};

pub const CrateV1 = struct {
    id: engine.PersistentId,
    half_extents: [3]f32,
    pose: engine.physics.Pose,
    linear_velocity: [3]f32,
    angular_velocity: [3]f32,
};

/// Validate only the crate-owned portion of a composed snapshot. World schema,
/// clock, namespace, identity-cursor, and cross-feature identity validation
/// belong to the composition that owns the complete persistence envelope.
pub fn validateRecords(records: []const CrateV1, max_crates: usize) !void {
    if (records.len > max_crates) return error.TooManyCrates;

    for (records, 0..) |record, index| {
        try record.id.validate();
        try (engine.physics.DynamicBoxDesc{
            .pose = record.pose,
            .velocity = .{
                .linear = record.linear_velocity,
                .angular = record.angular_velocity,
            },
            .half_extents = record.half_extents,
        }).validate();
        for (records[0..index]) |earlier| {
            if (std.meta.eql(earlier.id, record.id)) return error.DuplicatePersistentId;
        }
    }
}

fn diagnosticsCount(value: usize) u32 {
    return std.math.cast(u32, value) orelse std.math.maxInt(u32);
}

const FixedQueue = engine.BoundedQueue;

pub fn Feature(comptime Bodies: type) type {
    engine.physics.assertImplementation(Bodies);

    return struct {
        const Self = @This();

        const Crate = struct { half_extents: [3]f32 };
        const PhysicsDriven = struct { enabled: bool = true };
        const RuntimeBody = struct { handle: Bodies.Handle };
        const AuthoringRevision = struct { value: u64 = 0 };
        const TransformHistory = struct {
            previous: engine.physics.Pose,
            current: engine.physics.Pose,
            current_tick: u64,
        };
        const QueuedCommand = struct {
            command: Command,
            eligible_tick: u64,
        };
        const StagedRelocation = struct {
            command: RelocateCrate,
            commit_tick: u64,
        };

        allocator: std.mem.Allocator,
        runtime: *engine.Runtime,
        bodies: *Bodies,
        assets: Assets,
        max_crates: usize,
        pending: std.ArrayListUnmanaged(QueuedCommand) = .empty,
        applying: std.ArrayListUnmanaged(QueuedCommand) = .empty,
        applying_index: usize = 0,
        staged_relocations: std.ArrayListUnmanaged(StagedRelocation) = .empty,
        staged_relocation_index: usize = 0,
        active: std.ArrayListUnmanaged(engine.RuntimeId) = .empty,
        outcomes: FixedQueue(Outcome, max_outcomes) = .{},
        presentations: std.ArrayListUnmanaged(CrateDraw) = .empty,
        commands_high_water: u32 = 0,
        outcomes_high_water: u32 = 0,
        commands_rejected: u64 = 0,

        pub fn init(
            allocator: std.mem.Allocator,
            runtime: *engine.Runtime,
            bodies: *Bodies,
            assets: Assets,
            max_crates: usize,
        ) !Self {
            if (max_crates == 0) return error.InvalidCrateLimit;
            var self = Self{
                .allocator = allocator,
                .runtime = runtime,
                .bodies = bodies,
                .assets = assets,
                .max_crates = max_crates,
            };
            errdefer self.pending.deinit(allocator);
            errdefer self.applying.deinit(allocator);
            errdefer self.staged_relocations.deinit(allocator);
            errdefer self.active.deinit(allocator);
            errdefer self.presentations.deinit(allocator);
            try self.pending.ensureTotalCapacityPrecise(allocator, max_pending_commands);
            try self.applying.ensureTotalCapacityPrecise(allocator, max_pending_commands);
            try self.staged_relocations.ensureTotalCapacityPrecise(
                allocator,
                max_pending_commands,
            );
            try self.active.ensureTotalCapacityPrecise(allocator, max_crates);
            try self.presentations.ensureTotalCapacityPrecise(allocator, max_crates);
            return self;
        }

        pub fn register(self: *Self, registry: *engine.FeatureRegistry) !void {
            try registry.registerComponent(Crate);
            try registry.registerComponent(PhysicsDriven);
            try registry.registerComponent(RuntimeBody);
            try registry.registerComponent(AuthoringRevision);
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
            // Relocations commit after ordinary publication so a successful
            // authoring transaction owns the exact completed-tick history.
            try registry.addSystem(
                .post_physics,
                "crates.commit_relocations",
                self,
                commitRelocationsSystem,
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
            self.staged_relocations.deinit(self.allocator);
            self.active.deinit(self.allocator);
            self.presentations.deinit(self.allocator);
            self.* = undefined;
        }

        pub fn enqueue(self: *Self, command: Command) !void {
            try self.runtime.ensureHealthy();
            try validateCommand(command);
            const eligible_tick = try self.runtime.commandTargetTick();
            const command_count = self.commandOccupancyCount();
            if (command_count >= max_pending_commands or
                command_count + self.outcomes.len >= max_outcomes)
            {
                self.commands_rejected +|= 1;
                return error.CrateCommandQueueFull;
            }
            self.pending.appendAssumeCapacity(.{
                .command = command,
                .eligible_tick = eligible_tick,
            });
            self.observeQueueHighWater();
        }

        pub fn pollOutcome(self: *Self) ?Outcome {
            const outcome = self.outcomes.pop();
            self.observeQueueHighWater();
            return outcome;
        }

        pub fn count(self: *const Self) usize {
            return self.active.items.len;
        }

        pub fn diagnostics(self: *const Self) Diagnostics {
            self.runtime.assertOwnerThread();
            return .{
                .active_count = diagnosticsCount(self.active.items.len),
                .commands = .{
                    .occupancy = self.commandOccupancy(),
                    .high_water = self.commands_high_water,
                    .capacity = max_pending_commands,
                    .rejected = self.commands_rejected,
                },
                .outcomes = .{
                    .occupancy = self.outcomeOccupancy(),
                    .high_water = self.outcomes_high_water,
                    .capacity = max_outcomes,
                    .rejected = 0,
                },
            };
        }

        /// Append the complete crate-owned logical state to a caller-owned
        /// replay digest. The caller supplies identity scratch so this path
        /// performs no allocation at the tick boundary.
        pub fn writeLogicalState(
            self: *Self,
            writer: *engine.contracts.replay.Writer,
            scratch: []engine.PersistentId,
        ) !void {
            try self.runtime.ensureOwnerThread();
            if (scratch.len < self.active.items.len) {
                return error.InsufficientLogicalStateScratch;
            }

            writer.writeU8(@intCast(logical_state_domain.len));
            writer.writeBytes(logical_state_domain);
            writer.writeU16(logical_state_schema);
            writer.writeU64(self.runtime.tickIndex());
            writer.writeU32(std.math.cast(u32, self.active.items.len) orelse
                return error.LogicalStateCountOverflow);

            const ids = scratch[0..self.active.items.len];
            for (self.active.items, 0..) |runtime_id, index| {
                ids[index] = try self.runtime.identity(runtime_id);
            }
            std.mem.sort(engine.PersistentId, ids, {}, lessThanPersistentId);

            for (ids) |id| {
                const runtime_id = self.runtime.resolve(id) orelse
                    return error.CrateIdentityInvariantBroken;
                const crate = self.runtime.get(runtime_id, Crate) orelse
                    return error.NotACrate;
                const authority = self.runtime.get(runtime_id, PhysicsDriven) orelse
                    return error.CrateAuthorityInvariantBroken;
                const body = self.runtime.get(runtime_id, RuntimeBody) orelse
                    return error.CrateBodyInvariantBroken;
                const revision = self.runtime.get(runtime_id, AuthoringRevision) orelse
                    return error.CrateAuthoringRevisionInvariantBroken;
                const state = try (try self.bodies.bodyState(body.handle)).normalized();

                writePersistentId(writer, id);
                try writeVector3(writer, crate.half_extents);
                writer.writeBool(authority.enabled);
                writer.writeU64(revision.value);
                try writeBodyState(writer, state);
            }

            const applying = if (self.applying_index < self.applying.items.len)
                self.applying.items[self.applying_index..]
            else
                self.applying.items[0..0];
            writer.writeU32(std.math.cast(u32, applying.len) orelse
                return error.LogicalStateCountOverflow);
            for (applying) |queued| try writeQueuedCommand(writer, queued);
            writer.writeU32(std.math.cast(u32, self.pending.items.len) orelse
                return error.LogicalStateCountOverflow);
            for (self.pending.items) |queued| try writeQueuedCommand(writer, queued);
            const staged = if (self.staged_relocation_index < self.staged_relocations.items.len)
                self.staged_relocations.items[self.staged_relocation_index..]
            else
                self.staged_relocations.items[0..0];
            writer.writeU32(std.math.cast(u32, staged.len) orelse
                return error.LogicalStateCountOverflow);
            for (staged) |relocation| {
                writer.writeU64(relocation.commit_tick);
                try writeRelocation(writer, relocation.command);
            }

            writer.writeU32(self.outcomeOccupancy());
        }

        pub fn hasPendingCommands(self: *const Self) bool {
            return self.pending.items.len != 0 or
                self.applying_index < self.applying.items.len or
                self.staged_relocation_index < self.staged_relocations.items.len;
        }

        pub fn view(self: *Self, id: engine.PersistentId) !CrateView {
            const runtime_id = self.runtime.resolve(id) orelse return error.CrateNotFound;
            const crate = self.runtime.get(runtime_id, Crate) orelse return error.NotACrate;
            try self.requirePhysicsAuthority(runtime_id);
            const body = self.runtime.get(runtime_id, RuntimeBody) orelse
                return error.CrateBodyInvariantBroken;
            const revision = self.runtime.get(runtime_id, AuthoringRevision) orelse
                return error.CrateAuthoringRevisionInvariantBroken;
            const state = try (try self.bodies.bodyState(body.handle)).normalized();
            return .{
                .id = id,
                .half_extents = crate.half_extents,
                .state = state,
                .authoring_revision = revision.value,
            };
        }

        pub fn extract(self: *Self, alpha: f32) ![]const CrateDraw {
            if (!std.math.isFinite(alpha)) return error.InvalidInterpolationAlpha;
            self.presentations.clearRetainingCapacity();

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

        /// Return the crate-owned records for a composition snapshot. The
        /// caller owns the returned slice and is responsible for serializing
        /// it together with runtime metadata and other feature records.
        pub fn snapshotRecords(
            self: *Self,
            allocator: std.mem.Allocator,
        ) ![]CrateV1 {
            try self.runtime.ensureSnapshotBoundary();
            if (self.hasPendingCommands()) return error.CommandsPending;

            const records = try allocator.alloc(CrateV1, self.active.items.len);
            errdefer allocator.free(records);
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
            return records;
        }

        /// Restore into a newly initialized, still-registering feature. The
        /// operation rolls back every recreated crate if any record fails.
        pub fn restoreRecords(self: *Self, records: []const CrateV1) !void {
            try validateRecords(records, self.max_crates);
            if (self.active.items.len != 0 or self.hasPendingCommands()) {
                return error.RestoreRequiresEmptyFeature;
            }

            errdefer self.rollbackAll();
            for (records) |record| {
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
        }

        fn applyCommandsSystem(
            raw: *anyopaque,
            _: *engine.Runtime,
            tick: engine.TickContext,
        ) !void {
            const self: *Self = @ptrCast(@alignCast(raw));
            defer self.observeQueueHighWater();
            if (self.applying_index >= self.applying.items.len) {
                self.applying.clearRetainingCapacity();
                self.applying_index = 0;
                std.mem.swap(
                    std.ArrayListUnmanaged(QueuedCommand),
                    &self.pending,
                    &self.applying,
                );
            }

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
                    .relocate => |relocation| {
                        self.staged_relocations.appendAssumeCapacity(.{
                            .command = relocation,
                            .commit_tick = tick.tick_index,
                        });
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

        fn commitRelocationsSystem(
            raw: *anyopaque,
            _: *engine.Runtime,
            tick: engine.TickContext,
        ) !void {
            const self: *Self = @ptrCast(@alignCast(raw));
            defer self.observeQueueHighWater();

            while (self.staged_relocation_index < self.staged_relocations.items.len) {
                const staged = self.staged_relocations.items[self.staged_relocation_index];
                if (staged.commit_tick != tick.tick_index) {
                    return error.CrateRelocationTickInvariantBroken;
                }
                try self.commitRelocation(staged.command, tick.tick_index);
                self.staged_relocation_index += 1;
            }
            self.staged_relocations.clearRetainingCapacity();
            self.staged_relocation_index = 0;
        }

        fn commitRelocation(
            self: *Self,
            relocation: RelocateCrate,
            tick_index: u64,
        ) !void {
            // Reserve the one possible outcome before inspecting or mutating
            // authority. Everything after a successful adapter call is
            // non-failing local publication.
            std.debug.assert(self.outcomes.len < max_outcomes);
            const runtime_id = self.runtime.resolve(relocation.id) orelse {
                self.outcomes.pushAssumeCapacity(.{ .rejected = .{
                    .command = .relocate,
                    .reason = .crate_not_found,
                    .transaction_id = relocation.transaction_id,
                    .id = relocation.id,
                    .expected_revision = relocation.expected_revision,
                } });
                return;
            };
            _ = self.runtime.get(runtime_id, Crate) orelse {
                self.outcomes.pushAssumeCapacity(.{ .rejected = .{
                    .command = .relocate,
                    .reason = .not_owned,
                    .transaction_id = relocation.transaction_id,
                    .id = relocation.id,
                    .expected_revision = relocation.expected_revision,
                } });
                return;
            };
            try self.requirePhysicsAuthority(runtime_id);
            const body = self.runtime.get(runtime_id, RuntimeBody) orelse
                return error.CrateBodyInvariantBroken;
            const history = self.runtime.getMut(runtime_id, TransformHistory) orelse
                return error.CrateTransformInvariantBroken;
            const revision = self.runtime.getMut(runtime_id, AuthoringRevision) orelse
                return error.CrateAuthoringRevisionInvariantBroken;
            if (relocation.expected_revision) |expected| {
                if (expected != revision.value) {
                    self.outcomes.pushAssumeCapacity(.{ .rejected = .{
                        .command = .relocate,
                        .reason = .state_conflict,
                        .transaction_id = relocation.transaction_id,
                        .id = relocation.id,
                        .expected_revision = expected,
                        .actual_revision = revision.value,
                    } });
                    return;
                }
            }
            if (revision.value == std.math.maxInt(u64)) {
                return error.AuthoringRevisionExhausted;
            }

            const before = try (try self.bodies.bodyState(body.handle)).normalized();
            const velocity: engine.physics.Velocity = switch (relocation.velocity) {
                .preserve => before.velocity,
                .zero => .{},
                .exact => |exact| exact,
            };
            const after = try (engine.physics.BodyState{
                .pose = relocation.target_pose,
                .velocity = velocity,
            }).normalized();
            const committed_revision = revision.value + 1;

            try self.bodies.relocateBody(body.handle, after);
            history.previous = after.pose;
            history.current = after.pose;
            history.current_tick = tick_index;
            revision.value = committed_revision;
            self.outcomes.pushAssumeCapacity(.{ .relocated = .{
                .transaction_id = relocation.transaction_id,
                .id = relocation.id,
                .before = before,
                .after = after,
                .committed_revision = committed_revision,
            } });
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

            if (emit_outcome) std.debug.assert(self.outcomes.len < max_outcomes);

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
            try self.runtime.set(runtime_id, AuthoringRevision, .{});
            try self.runtime.set(runtime_id, TransformHistory, .{
                .previous = desc.pose,
                .current = desc.pose,
                .current_tick = self.runtime.tickIndex(),
            });
            self.active.appendAssumeCapacity(runtime_id);
            if (emit_outcome) {
                self.outcomes.pushAssumeCapacity(.{ .spawned = .{
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
            if (emit_outcome) std.debug.assert(self.outcomes.len < max_outcomes);

            try self.bodies.destroyBody(body.handle);
            self.destroyRuntimeOrPanic(runtime_id);
            _ = self.active.orderedRemove(index);
            if (emit_outcome) self.outcomes.pushAssumeCapacity(.{ .despawned = id });
        }

        fn impulseNow(self: *Self, impulse: ApplyImpulse, emit_outcome: bool) !void {
            const runtime_id = self.runtime.resolve(impulse.id) orelse
                return error.CrateNotFound;
            _ = self.runtime.get(runtime_id, Crate) orelse return error.NotACrate;
            try self.requirePhysicsAuthority(runtime_id);
            const body = self.runtime.get(runtime_id, RuntimeBody) orelse
                return error.CrateBodyInvariantBroken;
            if (emit_outcome) std.debug.assert(self.outcomes.len < max_outcomes);
            try self.bodies.applyImpulse(body.handle, impulse.impulse);
            if (emit_outcome) {
                self.outcomes.pushAssumeCapacity(.{ .impulse_applied = impulse.id });
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
            std.debug.assert(self.outcomes.len < max_outcomes);
            self.outcomes.pushAssumeCapacity(.{ .rejected = rejection });
        }

        fn commandOccupancyCount(self: *const Self) usize {
            const applying_remaining = if (self.applying_index < self.applying.items.len)
                self.applying.items.len - self.applying_index
            else
                0;
            var total = std.math.add(
                usize,
                self.pending.items.len,
                applying_remaining,
            ) catch std.math.maxInt(usize);
            const staged_remaining = if (self.staged_relocation_index <
                self.staged_relocations.items.len)
                self.staged_relocations.items.len - self.staged_relocation_index
            else
                0;
            total = std.math.add(usize, total, staged_remaining) catch
                std.math.maxInt(usize);
            return total;
        }

        fn commandOccupancy(self: *const Self) u32 {
            return diagnosticsCount(self.commandOccupancyCount());
        }

        fn outcomeOccupancy(self: *const Self) u32 {
            return diagnosticsCount(self.outcomes.len);
        }

        fn observeQueueHighWater(self: *Self) void {
            self.commands_high_water = @max(
                self.commands_high_water,
                self.commandOccupancy(),
            );
            self.outcomes_high_water = @max(
                self.outcomes_high_water,
                self.outcomeOccupancy(),
            );
        }

        fn writeQueuedCommand(
            writer: *engine.contracts.replay.Writer,
            queued: QueuedCommand,
        ) !void {
            writer.writeU64(queued.eligible_tick);
            switch (queued.command) {
                .spawn => |spawn| {
                    writer.writeU8(1);
                    writer.writeU64(spawn.request_id);
                    try writePose(writer, spawn.pose);
                    try writeVelocity(writer, spawn.velocity);
                    try writeVector3(writer, spawn.half_extents);
                },
                .despawn => |despawn| {
                    writer.writeU8(2);
                    writePersistentId(writer, despawn.id);
                },
                .impulse => |impulse| {
                    writer.writeU8(3);
                    writePersistentId(writer, impulse.id);
                    try writeVector3(writer, impulse.impulse);
                },
                .relocate => |relocation| {
                    writer.writeU8(4);
                    try writeRelocation(writer, relocation);
                },
            }
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
        .relocate => |relocation| {
            if (relocation.transaction_id == 0) return error.InvalidTransactionId;
            try relocation.id.validate();
            _ = try relocation.target_pose.normalized();
            switch (relocation.velocity) {
                .preserve, .zero => {},
                .exact => |velocity| try velocity.validate(),
            }
        },
    }
}

fn writePersistentId(
    writer: *engine.contracts.replay.Writer,
    id: engine.PersistentId,
) void {
    writer.writeU64(id.namespace);
    writer.writeU64(id.local);
}

fn writeVector3(
    writer: *engine.contracts.replay.Writer,
    value: [3]f32,
) !void {
    for (value) |component| try writer.writeF32(component);
}

fn writePose(
    writer: *engine.contracts.replay.Writer,
    raw: engine.physics.Pose,
) !void {
    var pose = try raw.normalized();
    if (quaternionNeedsNegation(pose.rotation)) {
        for (&pose.rotation) |*component| component.* = -component.*;
    }
    for (&pose.position) |*component| if (component.* == 0) {
        component.* = 0;
    };
    for (&pose.rotation) |*component| if (component.* == 0) {
        component.* = 0;
    };
    try writeVector3(writer, pose.position);
    for (pose.rotation) |component| try writer.writeF32(component);
}

fn writeVelocity(
    writer: *engine.contracts.replay.Writer,
    velocity: engine.physics.Velocity,
) !void {
    try velocity.validate();
    try writeVector3(writer, velocity.linear);
    try writeVector3(writer, velocity.angular);
}

fn writeRelocation(
    writer: *engine.contracts.replay.Writer,
    relocation: RelocateCrate,
) !void {
    writer.writeU64(relocation.transaction_id);
    writePersistentId(writer, relocation.id);
    try writePose(writer, relocation.target_pose);
    switch (relocation.velocity) {
        .preserve => writer.writeU8(1),
        .zero => writer.writeU8(2),
        .exact => |velocity| {
            writer.writeU8(3);
            try writeVelocity(writer, velocity);
        },
    }
    writer.writeBool(relocation.expected_revision != null);
    if (relocation.expected_revision) |revision| writer.writeU64(revision);
}

fn writeBodyState(
    writer: *engine.contracts.replay.Writer,
    state: engine.physics.BodyState,
) !void {
    try state.validate();
    try writePose(writer, state.pose);
    try writeVelocity(writer, state.velocity);
}

fn quaternionNeedsNegation(rotation: [4]f32) bool {
    for ([_]usize{ 3, 2, 1, 0 }) |index| {
        if (rotation[index] > 0) return false;
        if (rotation[index] < 0) return true;
    }
    return false;
}

fn lessThanPersistentId(
    _: void,
    lhs: engine.PersistentId,
    rhs: engine.PersistentId,
) bool {
    if (lhs.namespace != rhs.namespace) return lhs.namespace < rhs.namespace;
    return lhs.local < rhs.local;
}

fn lessThanRecord(_: void, lhs: CrateV1, rhs: CrateV1) bool {
    if (lhs.id.namespace != rhs.id.namespace) return lhs.id.namespace < rhs.id.namespace;
    return lhs.id.local < rhs.id.local;
}

fn testCrateRecord(namespace: u64, local: u64) CrateV1 {
    return .{
        .id = .{ .namespace = namespace, .local = local },
        .half_extents = .{ 0.5, 0.5, 0.5 },
        .pose = .{},
        .linear_velocity = .{ 0, 0, 0 },
        .angular_velocity = .{ 0, 0, 0 },
    };
}

test "crate record validation rejects duplicate identities and limits" {
    const records = [_]CrateV1{
        testCrateRecord(9, 1),
        testCrateRecord(9, 1),
    };
    try std.testing.expectError(
        error.DuplicatePersistentId,
        validateRecords(&records, 8),
    );
    try std.testing.expectError(
        error.TooManyCrates,
        validateRecords(records[0..1], 0),
    );
}

test "crate record validation leaves world namespace policy to composition" {
    const records = [_]CrateV1{
        testCrateRecord(10, 1),
        testCrateRecord(11, 1),
    };
    try validateRecords(&records, records.len);
}

test "crate record validation rejects invalid identities and physics" {
    var record = testCrateRecord(10, 1);

    record.id.local = 0;
    try std.testing.expectError(
        error.InvalidIdentityLocal,
        validateRecords((&record)[0..1], 1),
    );
    record.id.local = 1;

    record.pose.position[0] = std.math.inf(f32);
    try std.testing.expectError(
        error.NonFiniteTransform,
        validateRecords((&record)[0..1], 1),
    );
    record.pose.position[0] = 0;
    record.pose.rotation = .{ 0, 0, 0, 0 };
    try std.testing.expectError(
        error.DegenerateQuaternion,
        validateRecords((&record)[0..1], 1),
    );
    record.pose.rotation = .{ 0, 0, 0, 1 };

    record.linear_velocity[0] = std.math.nan(f32);
    try std.testing.expectError(
        error.NonFinitePhysicsValue,
        validateRecords((&record)[0..1], 1),
    );
    record.linear_velocity[0] = 0;
    record.linear_velocity[0] = std.math.nextAfter(
        f32,
        engine.physics.max_linear_velocity,
        std.math.inf(f32),
    );
    try std.testing.expectError(
        error.LinearVelocityOutOfRange,
        validateRecords((&record)[0..1], 1),
    );
    record.linear_velocity[0] = 0;
    record.angular_velocity[0] = std.math.nextAfter(
        f32,
        engine.physics.max_angular_velocity,
        std.math.inf(f32),
    );
    try std.testing.expectError(
        error.AngularVelocityOutOfRange,
        validateRecords((&record)[0..1], 1),
    );
    record.angular_velocity[0] = 0;

    record.half_extents[1] = 0;
    try std.testing.expectError(
        error.InvalidHalfExtents,
        validateRecords((&record)[0..1], 1),
    );
}

const FakeBodiesForTest = struct {
    pub const Handle = u32;

    states: [16]engine.physics.BodyState = [_]engine.physics.BodyState{.{}} ** 16,
    live: [16]bool = [_]bool{false} ** 16,
    next_handle: u32 = 0,
    live_count: u32 = 0,
    create_calls: u32 = 0,
    destroy_calls: u32 = 0,
    impulse_calls: u32 = 0,
    relocate_calls: u32 = 0,
    fail_create_call: ?u32 = null,
    fail_body_state: bool = false,
    fail_destroy: bool = false,
    fail_impulse: bool = false,
    fail_relocate: bool = false,

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
        self.destroy_calls += 1;
        if (self.fail_destroy) return error.InjectedBodyDestroyFailure;
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
        self.impulse_calls += 1;
        if (self.fail_impulse) return error.InjectedImpulseFailure;
        for (0..3) |axis| self.states[handle].velocity.linear[axis] += impulse[axis];
    }

    pub fn relocateBody(
        self: *FakeBodiesForTest,
        handle: Handle,
        state: engine.physics.BodyState,
    ) !void {
        if (handle >= self.live.len or !self.live[handle]) return error.InvalidFakeBody;
        const normalized = try state.normalized();
        self.relocate_calls += 1;
        if (self.fail_relocate) return error.InjectedRelocationFailure;
        self.states[handle] = normalized;
    }
};

const TestFeature = Feature(FakeBodiesForTest);

const FakeWorldStepper = struct {
    step_calls: u32 = 0,
    fail_step: bool = false,

    pub fn step(self: *FakeWorldStepper, _: f32) !void {
        self.step_calls += 1;
        if (self.fail_step) return error.InjectedPhysicsStepFailure;
    }
};

const StagedRelocationProbe = struct {
    feature: *TestFeature,
    armed: bool = false,
    saw_pending: bool = false,
    digest: engine.contracts.replay.Digest = [_]u8{0} ** 32,

    fn run(raw: *anyopaque, _: *engine.Runtime, _: engine.TickContext) !void {
        const self: *StagedRelocationProbe = @ptrCast(@alignCast(raw));
        if (!self.armed) return;
        self.saw_pending = self.feature.hasPendingCommands();
        var scratch: [1]engine.PersistentId = undefined;
        var writer = engine.contracts.replay.Writer.init();
        try self.feature.writeLogicalState(&writer, &scratch);
        self.digest = writer.final();
        self.armed = false;
    }
};

fn stepFakeWorld(
    raw: *anyopaque,
    _: *engine.Runtime,
    tick: engine.TickContext,
) !void {
    const stepper: *FakeWorldStepper = @ptrCast(@alignCast(raw));
    try stepper.step(tick.delta_seconds);
}

test "crate diagnostics retain source-owned command and outcome high-water marks" {
    var runtime = try engine.Runtime.init(std.testing.allocator, .{
        .namespace = 509,
        .fixed_delta_seconds = 1.0 / 120.0,
    });
    defer runtime.deinit();
    var bodies = FakeBodiesForTest{};
    var feature = try TestFeature.init(
        std.testing.allocator,
        &runtime,
        &bodies,
        .{},
        2,
    );
    defer feature.deinit();
    var stepper = FakeWorldStepper{};
    var registry = runtime.registry();
    try feature.register(&registry);
    try registry.addSystem(.physics, "fake.step", &stepper, stepFakeWorld);
    runtime.finishRegistration();

    try feature.enqueue(.{ .spawn = .{ .request_id = 1, .pose = .{} } });
    try feature.enqueue(.{ .spawn = .{ .request_id = 2, .pose = .{} } });
    var snapshot = feature.diagnostics();
    try std.testing.expectEqual(@as(u32, 2), snapshot.commands.occupancy);
    try std.testing.expectEqual(@as(u32, 2), snapshot.commands.high_water);
    try std.testing.expectEqual(@as(?u32, max_pending_commands), snapshot.commands.capacity);
    try std.testing.expectEqual(@as(u64, 0), snapshot.commands.rejected);

    try runtime.tick();
    snapshot = feature.diagnostics();
    try std.testing.expectEqual(@as(u32, 2), snapshot.active_count);
    try std.testing.expectEqual(@as(u32, 0), snapshot.commands.occupancy);
    try std.testing.expectEqual(@as(u32, 2), snapshot.commands.high_water);
    try std.testing.expectEqual(@as(u32, 2), snapshot.outcomes.occupancy);
    try std.testing.expectEqual(@as(u32, 2), snapshot.outcomes.high_water);

    _ = feature.pollOutcome() orelse return error.MissingOutcome;
    snapshot = feature.diagnostics();
    try std.testing.expectEqual(@as(u32, 1), snapshot.outcomes.occupancy);
    try std.testing.expectEqual(@as(u32, 2), snapshot.outcomes.high_water);
    _ = feature.pollOutcome() orelse return error.MissingOutcome;
    try std.testing.expectEqual(
        @as(u32, 0),
        feature.diagnostics().outcomes.occupancy,
    );
}

test "crate bounded queues reject atomically then drain and recover without allocation" {
    var runtime = try engine.Runtime.init(std.testing.allocator, .{
        .namespace = 522,
        .fixed_delta_seconds = 1.0 / 120.0,
    });
    defer runtime.deinit();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var bodies = FakeBodiesForTest{};
    var feature = try TestFeature.init(
        failing.allocator(),
        &runtime,
        &bodies,
        .{},
        1,
    );
    defer feature.deinit();
    var stepper = FakeWorldStepper{};
    var registry = runtime.registry();
    try feature.register(&registry);
    try registry.addSystem(.physics, "fake.step", &stepper, stepFakeWorld);
    runtime.finishRegistration();

    const missing = engine.PersistentId{ .namespace = 522, .local = 999 };
    const allocation_count = failing.alloc_index;
    failing.fail_index = allocation_count;
    for (0..max_pending_commands) |_| {
        try feature.enqueue(.{ .impulse = .{ .id = missing, .impulse = .{ 0, 0, 0 } } });
    }
    try std.testing.expectError(
        error.CrateCommandQueueFull,
        feature.enqueue(.{ .spawn = .{ .request_id = 900, .pose = .{} } }),
    );
    var diagnostics_value = feature.diagnostics();
    try std.testing.expectEqual(@as(u32, max_pending_commands), diagnostics_value.commands.occupancy);
    try std.testing.expectEqual(@as(u32, max_pending_commands), diagnostics_value.commands.high_water);
    try std.testing.expectEqual(@as(?u32, max_pending_commands), diagnostics_value.commands.capacity);
    try std.testing.expectEqual(@as(u64, 1), diagnostics_value.commands.rejected);
    try std.testing.expectEqual(@as(usize, 0), feature.count());

    try runtime.tick();
    diagnostics_value = feature.diagnostics();
    try std.testing.expectEqual(@as(u32, 0), diagnostics_value.commands.occupancy);
    try std.testing.expectEqual(@as(u32, max_outcomes), diagnostics_value.outcomes.occupancy);
    try std.testing.expectEqual(@as(u32, max_outcomes), diagnostics_value.outcomes.high_water);
    try std.testing.expectEqual(@as(?u32, max_outcomes), diagnostics_value.outcomes.capacity);
    try std.testing.expectError(
        error.CrateCommandQueueFull,
        feature.enqueue(.{ .spawn = .{ .request_id = 901, .pose = .{} } }),
    );
    try std.testing.expectEqual(@as(u64, 2), feature.diagnostics().commands.rejected);

    for (0..max_outcomes) |_| {
        const outcome = feature.pollOutcome() orelse return error.MissingOutcome;
        switch (outcome) {
            .rejected => |rejected| {
                try std.testing.expectEqual(CommandKind.impulse, rejected.command);
                try std.testing.expectEqual(RejectionReason.crate_not_found, rejected.reason);
                try std.testing.expectEqual(missing, rejected.id.?);
            },
            else => return error.UnexpectedOutcome,
        }
    }
    try std.testing.expect(feature.pollOutcome() == null);

    try feature.enqueue(.{ .spawn = .{ .request_id = 902, .pose = .{} } });
    try runtime.tick();
    const spawned = switch (feature.pollOutcome() orelse return error.MissingOutcome) {
        .spawned => |value| value,
        else => return error.UnexpectedOutcome,
    };
    try std.testing.expectEqual(@as(u64, 902), spawned.request_id);
    try std.testing.expectEqual(@as(usize, 1), feature.count());
    try feature.enqueue(.{ .despawn = .{ .id = spawned.id } });
    try runtime.tick();
    try std.testing.expectEqual(spawned.id, feature.pollOutcome().?.despawned);
    try std.testing.expectEqual(@as(usize, 0), feature.count());
    try std.testing.expectEqual(allocation_count, failing.alloc_index);
}

test "crate logical state is allocation-free and canonicalizes pose aliases" {
    var runtime = try engine.Runtime.init(std.testing.allocator, .{
        .namespace = 510,
        .fixed_delta_seconds = 1.0 / 120.0,
    });
    defer runtime.deinit();
    var bodies = FakeBodiesForTest{};
    var feature = try TestFeature.init(
        std.testing.allocator,
        &runtime,
        &bodies,
        .{},
        1,
    );
    defer feature.deinit();
    var stepper = FakeWorldStepper{};
    var registry = runtime.registry();
    try feature.register(&registry);
    try registry.addSystem(.physics, "fake.step", &stepper, stepFakeWorld);
    runtime.finishRegistration();

    try feature.enqueue(.{ .spawn = .{
        .request_id = 1,
        .pose = .{ .rotation = .{ 0, 0, 0, -1 } },
    } });
    try runtime.tick();

    var none: [0]engine.PersistentId = .{};
    var too_small = engine.contracts.replay.Writer.init();
    try std.testing.expectError(
        error.InsufficientLogicalStateScratch,
        feature.writeLogicalState(&too_small, &none),
    );

    var scratch: [1]engine.PersistentId = undefined;
    var first_writer = engine.contracts.replay.Writer.init();
    try feature.writeLogicalState(&first_writer, &scratch);
    const first = first_writer.final();

    bodies.states[0].pose.position[0] = @bitCast(@as(u32, 0x8000_0000));
    for (&bodies.states[0].pose.rotation) |*component| component.* = -component.*;
    var aliased_writer = engine.contracts.replay.Writer.init();
    try feature.writeLogicalState(&aliased_writer, &scratch);
    try std.testing.expectEqual(first, aliased_writer.final());
}

fn snapshotThroughFakeFeature(
    records: []const CrateV1,
    namespace: u64,
    next_local_id: u64,
    completed_ticks: u64,
) ![]CrateV1 {
    var runtime = try engine.Runtime.init(std.testing.allocator, .{
        .namespace = namespace,
        .fixed_delta_seconds = 1.0 / 120.0,
        .next_local_id = next_local_id,
        .completed_ticks = completed_ticks,
    });
    defer runtime.deinit();
    var bodies = FakeBodiesForTest{};
    var feature = try TestFeature.init(
        std.testing.allocator,
        &runtime,
        &bodies,
        .{},
        16,
    );
    defer feature.deinit();
    var registry = runtime.registry();
    try feature.register(&registry);
    try feature.restoreRecords(records);
    return feature.snapshotRecords(std.testing.allocator);
}

test "multi-record restore and snapshot is sorted and stable" {
    const records = [_]CrateV1{
        .{
            .id = .{ .namespace = 500, .local = 3 },
            .half_extents = .{ 3, 3.5, 4 },
            .pose = .{ .position = .{ 30, 31, 32 } },
            .linear_velocity = .{ 300, 400, 0 },
            .angular_velocity = .{ 0, 0, engine.physics.max_angular_velocity },
        },
        .{
            .id = .{ .namespace = 500, .local = 1 },
            .half_extents = .{ 1, 1.5, 2 },
            .pose = .{ .position = .{ 10, 11, 12 } },
            .linear_velocity = .{ 1, 2, 3 },
            .angular_velocity = .{ 4, 5, 6 },
        },
        .{
            .id = .{ .namespace = 500, .local = 2 },
            .half_extents = .{ 2, 2.5, 3 },
            .pose = .{
                .position = .{ 20, 21, 22 },
                .rotation = .{ 0, 0, 0, 2 },
            },
            .linear_velocity = .{ -1, -2, -3 },
            .angular_velocity = .{ -4, -5, -6 },
        },
    };
    const first = try snapshotThroughFakeFeature(&records, 500, 4, 37);
    defer std.testing.allocator.free(first);

    try std.testing.expectEqual(@as(usize, 3), first.len);
    try std.testing.expectEqual(@as(u64, 1), first[0].id.local);
    try std.testing.expectEqual(@as(u64, 2), first[1].id.local);
    try std.testing.expectEqual(@as(u64, 3), first[2].id.local);
    try std.testing.expectEqualDeep(
        [3]f32{ 10, 11, 12 },
        first[0].pose.position,
    );
    try std.testing.expectEqualDeep(
        [4]f32{ 0, 0, 0, 1 },
        first[1].pose.rotation,
    );
    try std.testing.expectEqualDeep(
        [3]f32{ 300, 400, 0 },
        first[2].linear_velocity,
    );

    const second = try snapshotThroughFakeFeature(first, 500, 4, 37);
    defer std.testing.allocator.free(second);
    try std.testing.expectEqual(first.len, second.len);
    for (first, second) |expected, actual| {
        try std.testing.expectEqualDeep(expected, actual);
    }
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
    var stepper = FakeWorldStepper{};
    var registry = runtime.registry();
    try feature.register(&registry);
    try registry.addSystem(.physics, "fake.step", &stepper, stepFakeWorld);
    try feature.enqueue(.{ .spawn = .{ .request_id = 1, .pose = .{} } });

    try std.testing.expectError(error.InjectedBodyCreateFailure, runtime.tick());
    try std.testing.expectEqual(@as(usize, 0), feature.count());
    try std.testing.expectEqual(@as(usize, 0), runtime.entityCount());
    try std.testing.expectEqual(@as(usize, 0), runtime.persistentCount());
    try std.testing.expectEqual(@as(u32, 0), bodies.live_count);
    try std.testing.expectEqual(@as(u64, 2), try runtime.nextLocalId());
    try std.testing.expect(runtime.resolve(.{ .namespace = 501, .local = 1 }) == null);
    try std.testing.expect(feature.pollOutcome() == null);
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
    try std.testing.expectError(
        error.InjectedBodyCreateFailure,
        feature.restoreRecords(&records),
    );
    try std.testing.expectEqual(@as(usize, 0), feature.count());
    try std.testing.expectEqual(@as(usize, 0), runtime.entityCount());
    try std.testing.expectEqual(@as(usize, 0), runtime.persistentCount());
    try std.testing.expectEqual(@as(u32, 0), bodies.live_count);
    try std.testing.expectEqual(@as(u64, 3), try runtime.nextLocalId());
    try std.testing.expect(runtime.resolve(records[0].id) == null);
    try std.testing.expect(runtime.resolve(records[1].id) == null);
    try std.testing.expect(feature.pollOutcome() == null);
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
    var stepper = FakeWorldStepper{};
    var registry = runtime.registry();
    try registry.addSystem(.commands, "test.emit_command", &emitter, DeferredEmitter.run);
    try feature.register(&registry);
    try registry.addSystem(.physics, "fake.step", &stepper, stepFakeWorld);

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

test "capacity rejection preserves identity and outcome ordering" {
    var runtime = try engine.Runtime.init(std.testing.allocator, .{
        .namespace = 505,
        .fixed_delta_seconds = 1.0 / 120.0,
    });
    defer runtime.deinit();
    var bodies = FakeBodiesForTest{};
    var feature = try TestFeature.init(
        std.testing.allocator,
        &runtime,
        &bodies,
        .{},
        1,
    );
    defer feature.deinit();
    var stepper = FakeWorldStepper{};
    var registry = runtime.registry();
    try feature.register(&registry);
    try registry.addSystem(.physics, "fake.step", &stepper, stepFakeWorld);

    try feature.enqueue(.{ .spawn = .{ .request_id = 11, .pose = .{} } });
    try feature.enqueue(.{ .spawn = .{ .request_id = 12, .pose = .{} } });
    try runtime.tick();

    const spawned = switch (feature.pollOutcome() orelse return error.MissingOutcome) {
        .spawned => |value| value,
        else => return error.UnexpectedOutcome,
    };
    try std.testing.expectEqual(@as(u64, 11), spawned.request_id);
    try std.testing.expectEqualDeep(
        engine.PersistentId{ .namespace = 505, .local = 1 },
        spawned.id,
    );
    const rejected = switch (feature.pollOutcome() orelse return error.MissingOutcome) {
        .rejected => |value| value,
        else => return error.UnexpectedOutcome,
    };
    try std.testing.expectEqual(CommandKind.spawn, rejected.command);
    try std.testing.expectEqual(RejectionReason.capacity_reached, rejected.reason);
    try std.testing.expectEqual(@as(?u64, 12), rejected.request_id);
    try std.testing.expect(rejected.id == null);
    try std.testing.expect(feature.pollOutcome() == null);
    try std.testing.expectEqual(@as(usize, 1), feature.count());
    try std.testing.expectEqual(@as(usize, 1), runtime.entityCount());
    try std.testing.expectEqual(@as(usize, 1), runtime.persistentCount());
    try std.testing.expectEqual(@as(u32, 1), bodies.live_count);
    try std.testing.expectEqual(@as(u64, 2), try runtime.nextLocalId());

    try feature.enqueue(.{ .despawn = .{ .id = spawned.id } });
    try runtime.tick();
    const despawned = switch (feature.pollOutcome() orelse return error.MissingOutcome) {
        .despawned => |value| value,
        else => return error.UnexpectedOutcome,
    };
    try std.testing.expectEqualDeep(spawned.id, despawned);
    try std.testing.expect(feature.pollOutcome() == null);
    try std.testing.expectEqual(@as(usize, 0), feature.count());
    try std.testing.expectEqual(@as(usize, 0), runtime.entityCount());
    try std.testing.expectEqual(@as(usize, 0), runtime.persistentCount());
    try std.testing.expectEqual(@as(u32, 0), bodies.live_count);
}

test "physics step failure preserves live state and feature teardown removes it" {
    var runtime = try engine.Runtime.init(std.testing.allocator, .{
        .namespace = 506,
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
    var feature_live = true;
    defer {
        if (feature_live) feature.deinit();
    }
    var stepper = FakeWorldStepper{};
    var registry = runtime.registry();
    try feature.register(&registry);
    try registry.addSystem(.physics, "fake.step", &stepper, stepFakeWorld);
    try feature.enqueue(.{ .spawn = .{ .request_id = 1, .pose = .{} } });
    try runtime.tick();
    const id = switch (feature.pollOutcome() orelse return error.MissingOutcome) {
        .spawned => |spawned| spawned.id,
        else => return error.UnexpectedOutcome,
    };

    stepper.fail_step = true;
    try std.testing.expectError(error.InjectedPhysicsStepFailure, runtime.tick());
    try std.testing.expect(runtime.isFaulted());
    try std.testing.expectEqual(@as(u64, 1), runtime.tickIndex());
    try std.testing.expectEqual(@as(u32, 2), stepper.step_calls);
    try std.testing.expectEqual(@as(usize, 1), feature.count());
    try std.testing.expectEqual(@as(usize, 1), runtime.entityCount());
    try std.testing.expectEqual(@as(usize, 1), runtime.persistentCount());
    try std.testing.expect(runtime.resolve(id) != null);
    try std.testing.expectEqual(@as(u32, 1), bodies.live_count);
    try std.testing.expectError(
        error.RuntimeFaulted,
        feature.enqueue(.{ .spawn = .{ .request_id = 2, .pose = .{} } }),
    );
    try std.testing.expectError(
        error.RuntimeFaulted,
        feature.snapshotRecords(std.testing.allocator),
    );

    feature.deinit();
    feature_live = false;
    try std.testing.expectEqual(@as(usize, 0), runtime.entityCount());
    try std.testing.expectEqual(@as(usize, 0), runtime.persistentCount());
    try std.testing.expect(runtime.resolve(id) == null);
    try std.testing.expectEqual(@as(u32, 0), bodies.live_count);
    try std.testing.expectEqual(@as(u32, 1), bodies.destroy_calls);
}

test "body destroy failure leaves ownership intact until feature teardown" {
    var runtime = try engine.Runtime.init(std.testing.allocator, .{
        .namespace = 507,
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
    var feature_live = true;
    defer {
        if (feature_live) feature.deinit();
    }
    var stepper = FakeWorldStepper{};
    var registry = runtime.registry();
    try feature.register(&registry);
    try registry.addSystem(.physics, "fake.step", &stepper, stepFakeWorld);
    try feature.enqueue(.{ .spawn = .{ .request_id = 1, .pose = .{} } });
    try runtime.tick();
    const id = switch (feature.pollOutcome() orelse return error.MissingOutcome) {
        .spawned => |spawned| spawned.id,
        else => return error.UnexpectedOutcome,
    };

    bodies.fail_destroy = true;
    try feature.enqueue(.{ .despawn = .{ .id = id } });
    try std.testing.expectError(error.InjectedBodyDestroyFailure, runtime.tick());
    try std.testing.expect(runtime.isFaulted());
    try std.testing.expectEqual(@as(u64, 1), runtime.tickIndex());
    try std.testing.expectEqual(@as(usize, 1), feature.count());
    try std.testing.expectEqual(@as(usize, 1), runtime.entityCount());
    try std.testing.expectEqual(@as(usize, 1), runtime.persistentCount());
    try std.testing.expect(runtime.resolve(id) != null);
    try std.testing.expectEqual(@as(u32, 1), bodies.live_count);
    try std.testing.expectEqual(@as(u32, 1), bodies.destroy_calls);
    try std.testing.expect(feature.pollOutcome() == null);

    bodies.fail_destroy = false;
    feature.deinit();
    feature_live = false;
    try std.testing.expectEqual(@as(usize, 0), runtime.entityCount());
    try std.testing.expectEqual(@as(usize, 0), runtime.persistentCount());
    try std.testing.expect(runtime.resolve(id) == null);
    try std.testing.expectEqual(@as(u32, 0), bodies.live_count);
    try std.testing.expectEqual(@as(u32, 2), bodies.destroy_calls);
}

test "impulse failure does not mutate the body and teardown removes it" {
    var runtime = try engine.Runtime.init(std.testing.allocator, .{
        .namespace = 508,
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
    var feature_live = true;
    defer {
        if (feature_live) feature.deinit();
    }
    var stepper = FakeWorldStepper{};
    var registry = runtime.registry();
    try feature.register(&registry);
    try registry.addSystem(.physics, "fake.step", &stepper, stepFakeWorld);
    try feature.enqueue(.{ .spawn = .{ .request_id = 1, .pose = .{} } });
    try runtime.tick();
    const id = switch (feature.pollOutcome() orelse return error.MissingOutcome) {
        .spawned => |spawned| spawned.id,
        else => return error.UnexpectedOutcome,
    };
    const before = bodies.states[0];

    bodies.fail_impulse = true;
    try feature.enqueue(.{ .impulse = .{ .id = id, .impulse = .{ 1, 2, 3 } } });
    try std.testing.expectError(error.InjectedImpulseFailure, runtime.tick());
    try std.testing.expect(runtime.isFaulted());
    try std.testing.expectEqual(@as(u64, 1), runtime.tickIndex());
    try std.testing.expectEqual(@as(u32, 1), bodies.impulse_calls);
    try std.testing.expectEqualDeep(before, bodies.states[0]);
    try std.testing.expectEqual(@as(usize, 1), feature.count());
    try std.testing.expectEqual(@as(usize, 1), runtime.entityCount());
    try std.testing.expectEqual(@as(usize, 1), runtime.persistentCount());
    try std.testing.expect(runtime.resolve(id) != null);
    try std.testing.expectEqual(@as(u32, 1), bodies.live_count);
    try std.testing.expect(feature.pollOutcome() == null);

    feature.deinit();
    feature_live = false;
    try std.testing.expectEqual(@as(usize, 0), runtime.entityCount());
    try std.testing.expectEqual(@as(usize, 0), runtime.persistentCount());
    try std.testing.expect(runtime.resolve(id) == null);
    try std.testing.expectEqual(@as(u32, 0), bodies.live_count);
    try std.testing.expectEqual(@as(u32, 1), bodies.destroy_calls);
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
    var feature_live = true;
    defer {
        if (feature_live) feature.deinit();
    }
    var stepper = FakeWorldStepper{};
    var registry = runtime.registry();
    try feature.register(&registry);
    try registry.addSystem(.physics, "fake.step", &stepper, stepFakeWorld);
    try feature.enqueue(.{ .spawn = .{ .request_id = 1, .pose = .{} } });

    try std.testing.expectError(error.InjectedBodyReadFailure, runtime.tick());
    try std.testing.expect(runtime.isFaulted());
    try std.testing.expectEqual(@as(usize, 1), feature.count());
    try std.testing.expectEqual(@as(usize, 1), runtime.entityCount());
    try std.testing.expectEqual(@as(usize, 1), runtime.persistentCount());
    try std.testing.expectEqual(@as(u32, 1), bodies.live_count);
    try std.testing.expect(
        runtime.resolve(.{ .namespace = 504, .local = 1 }) != null,
    );
    try std.testing.expectError(
        error.RuntimeFaulted,
        feature.enqueue(.{ .spawn = .{ .request_id = 2, .pose = .{} } }),
    );
    try std.testing.expectError(
        error.RuntimeFaulted,
        feature.snapshotRecords(std.testing.allocator),
    );

    feature.deinit();
    feature_live = false;
    try std.testing.expectEqual(@as(usize, 0), runtime.entityCount());
    try std.testing.expectEqual(@as(usize, 0), runtime.persistentCount());
    try std.testing.expectEqual(@as(u32, 0), bodies.live_count);
    try std.testing.expectEqual(@as(u32, 1), bodies.destroy_calls);
}

test "partially drained bounded outcome FIFO wraps while preserving order" {
    var runtime = try engine.Runtime.init(std.testing.allocator, .{
        .namespace = 506,
        .fixed_delta_seconds = 1.0 / 120.0,
    });
    defer runtime.deinit();
    var bodies = FakeBodiesForTest{};
    var feature = try TestFeature.init(
        std.testing.allocator,
        &runtime,
        &bodies,
        .{},
        1,
    );
    defer feature.deinit();
    var stepper = FakeWorldStepper{};
    var registry = runtime.registry();
    try feature.register(&registry);
    try registry.addSystem(.physics, "fake.step", &stepper, stepFakeWorld);

    try feature.enqueue(.{ .spawn = .{ .request_id = 1, .pose = .{} } });
    try runtime.tick();
    const id = switch (feature.pollOutcome() orelse return error.MissingOutcome) {
        .spawned => |spawned| spawned.id,
        else => return error.UnexpectedOutcome,
    };

    try feature.enqueue(.{ .impulse = .{ .id = id, .impulse = .{ 0, 0, 0 } } });
    try feature.enqueue(.{ .impulse = .{ .id = id, .impulse = .{ 0, 0, 0 } } });
    try runtime.tick();
    _ = feature.pollOutcome() orelse return error.MissingOutcome;

    for (0..512) |_| {
        try feature.enqueue(.{ .impulse = .{ .id = id, .impulse = .{ 0, 0, 0 } } });
        try runtime.tick();
        switch (feature.pollOutcome() orelse return error.MissingOutcome) {
            .impulse_applied => |applied_id| try std.testing.expectEqual(id, applied_id),
            else => return error.UnexpectedOutcome,
        }
    }
    try std.testing.expectEqual(@as(usize, 1), feature.outcomes.len);
    switch (feature.pollOutcome() orelse return error.MissingOutcome) {
        .impulse_applied => |applied_id| try std.testing.expectEqual(id, applied_id),
        else => return error.UnexpectedOutcome,
    }
    try std.testing.expect(feature.pollOutcome() == null);
}

test "relocation velocity policies commit exact change sets without interpolation smear" {
    var runtime = try engine.Runtime.init(std.testing.allocator, .{
        .namespace = 511,
        .fixed_delta_seconds = 1.0 / 120.0,
    });
    defer runtime.deinit();
    var bodies = FakeBodiesForTest{};
    var feature = try TestFeature.init(
        std.testing.allocator,
        &runtime,
        &bodies,
        .{},
        1,
    );
    defer feature.deinit();
    var stepper = FakeWorldStepper{};
    var registry = runtime.registry();
    try feature.register(&registry);
    try registry.addSystem(.physics, "fake.step", &stepper, stepFakeWorld);

    const initial_velocity = engine.physics.Velocity{
        .linear = .{ 1, 2, 3 },
        .angular = .{ 4, 5, 6 },
    };
    try feature.enqueue(.{ .spawn = .{
        .request_id = 1,
        .pose = .{ .position = .{ 1, 2, 3 } },
        .velocity = initial_velocity,
    } });
    try runtime.tick();
    const id = switch (feature.pollOutcome() orelse return error.MissingOutcome) {
        .spawned => |spawned| spawned.id,
        else => return error.UnexpectedOutcome,
    };
    try std.testing.expectEqual(@as(u64, 0), (try feature.view(id)).authoring_revision);

    const initial_state = bodies.states[0];
    const preserve_pose = try (engine.physics.Pose{
        .position = .{ 10, 11, 12 },
        .rotation = .{ 0, 0, 0, 2 },
    }).normalized();
    try feature.enqueue(.{ .relocate = .{
        .transaction_id = 101,
        .id = id,
        .target_pose = preserve_pose,
        .velocity = .preserve,
        .expected_revision = 0,
    } });
    try runtime.tick();
    const preserved = switch (feature.pollOutcome() orelse return error.MissingOutcome) {
        .relocated => |relocated| relocated,
        else => return error.UnexpectedOutcome,
    };
    try std.testing.expectEqual(@as(u64, 101), preserved.transaction_id);
    try std.testing.expectEqualDeep(id, preserved.id);
    try std.testing.expectEqualDeep(initial_state, preserved.before);
    try std.testing.expectEqualDeep(preserve_pose, preserved.after.pose);
    try std.testing.expectEqualDeep(initial_velocity, preserved.after.velocity);
    try std.testing.expectEqual(@as(u64, 1), preserved.committed_revision);
    try std.testing.expectEqual(@as(u64, 1), (try feature.view(id)).authoring_revision);

    for ([_]f32{ 0, 0.5, 1 }) |alpha| {
        const draws = try feature.extract(alpha);
        try std.testing.expectEqual(@as(usize, 1), draws.len);
        try std.testing.expectEqualDeep(preserve_pose, draws[0].pose);
    }

    // Ordinary physics movement is not an authoring edit and therefore does
    // not invalidate the revision observed by a UI on an earlier frame.
    bodies.states[0].pose.position = .{ 20, 21, 22 };
    bodies.states[0].velocity = .{
        .linear = .{ -7, 8, -9 },
        .angular = .{ 1, -2, 3 },
    };
    const naturally_moved = bodies.states[0];
    try std.testing.expectEqual(@as(u64, 1), (try feature.view(id)).authoring_revision);

    const zero_pose = engine.physics.Pose{ .position = .{ 30, 31, 32 } };
    try feature.enqueue(.{ .relocate = .{
        .transaction_id = 102,
        .id = id,
        .target_pose = zero_pose,
        .velocity = .zero,
        .expected_revision = 1,
    } });
    try runtime.tick();
    const zeroed = switch (feature.pollOutcome() orelse return error.MissingOutcome) {
        .relocated => |relocated| relocated,
        else => return error.UnexpectedOutcome,
    };
    try std.testing.expectEqualDeep(naturally_moved, zeroed.before);
    try std.testing.expectEqualDeep(zero_pose, zeroed.after.pose);
    try std.testing.expectEqualDeep(engine.physics.Velocity{}, zeroed.after.velocity);
    try std.testing.expectEqual(@as(u64, 2), zeroed.committed_revision);

    const exact_velocity = engine.physics.Velocity{
        .linear = .{ 9, -8, 7 },
        .angular = .{ -3, 2, -1 },
    };
    const exact_pose = try (engine.physics.Pose{
        .position = .{ 40, 41, 42 },
        .rotation = .{ 0, 1, 0, 1 },
    }).normalized();
    try feature.enqueue(.{ .relocate = .{
        .transaction_id = 103,
        .id = id,
        .target_pose = exact_pose,
        .velocity = .{ .exact = exact_velocity },
        .expected_revision = 2,
    } });
    try runtime.tick();
    const exact = switch (feature.pollOutcome() orelse return error.MissingOutcome) {
        .relocated => |relocated| relocated,
        else => return error.UnexpectedOutcome,
    };
    try std.testing.expectEqualDeep(exact_pose, exact.after.pose);
    try std.testing.expectEqualDeep(exact_velocity, exact.after.velocity);
    try std.testing.expectEqual(@as(u64, 3), exact.committed_revision);
    try std.testing.expectEqualDeep(exact.after, bodies.states[0]);
    try std.testing.expectEqual(@as(u32, 3), bodies.relocate_calls);
    try std.testing.expectEqual(@as(u64, 3), (try feature.view(id)).authoring_revision);
    try std.testing.expect(feature.pollOutcome() == null);
}

test "relocation validates transaction pose velocity and optimistic revision" {
    var runtime = try engine.Runtime.init(std.testing.allocator, .{
        .namespace = 512,
        .fixed_delta_seconds = 1.0 / 120.0,
    });
    defer runtime.deinit();
    var bodies = FakeBodiesForTest{};
    var feature = try TestFeature.init(
        std.testing.allocator,
        &runtime,
        &bodies,
        .{},
        1,
    );
    defer feature.deinit();
    var stepper = FakeWorldStepper{};
    var registry = runtime.registry();
    try feature.register(&registry);
    try registry.addSystem(.physics, "fake.step", &stepper, stepFakeWorld);
    try feature.enqueue(.{ .spawn = .{ .request_id = 1, .pose = .{} } });
    try runtime.tick();
    const id = switch (feature.pollOutcome() orelse return error.MissingOutcome) {
        .spawned => |spawned| spawned.id,
        else => return error.UnexpectedOutcome,
    };

    try std.testing.expectError(
        error.InvalidTransactionId,
        feature.enqueue(.{ .relocate = .{
            .transaction_id = 0,
            .id = id,
            .target_pose = .{},
        } }),
    );
    try std.testing.expectError(
        error.DegenerateQuaternion,
        feature.enqueue(.{ .relocate = .{
            .transaction_id = 1,
            .id = id,
            .target_pose = .{ .rotation = .{ 0, 0, 0, 0 } },
        } }),
    );
    try std.testing.expectError(
        error.NonFinitePhysicsValue,
        feature.enqueue(.{ .relocate = .{
            .transaction_id = 1,
            .id = id,
            .target_pose = .{},
            .velocity = .{ .exact = .{
                .linear = .{ std.math.nan(f32), 0, 0 },
            } },
        } }),
    );
    try std.testing.expectEqual(@as(u32, 0), feature.diagnostics().commands.occupancy);

    const body_before = bodies.states[0];
    try feature.enqueue(.{ .relocate = .{
        .transaction_id = 77,
        .id = id,
        .target_pose = .{ .position = .{ 99, 98, 97 } },
        .expected_revision = 9,
    } });
    try runtime.tick();
    const rejected = switch (feature.pollOutcome() orelse return error.MissingOutcome) {
        .rejected => |value| value,
        else => return error.UnexpectedOutcome,
    };
    try std.testing.expectEqual(CommandKind.relocate, rejected.command);
    try std.testing.expectEqual(RejectionReason.state_conflict, rejected.reason);
    try std.testing.expectEqual(@as(?u64, 77), rejected.transaction_id);
    try std.testing.expectEqual(@as(?u64, 9), rejected.expected_revision);
    try std.testing.expectEqual(@as(?u64, 0), rejected.actual_revision);
    try std.testing.expectEqualDeep(@as(?engine.PersistentId, id), rejected.id);
    try std.testing.expectEqualDeep(body_before, bodies.states[0]);
    try std.testing.expectEqual(@as(u32, 0), bodies.relocate_calls);
    try std.testing.expectEqual(@as(u64, 0), (try feature.view(id)).authoring_revision);
    for ([_]f32{ 0, 0.5, 1 }) |alpha| {
        const draws = try feature.extract(alpha);
        try std.testing.expectEqualDeep(body_before.pose, draws[0].pose);
    }
}

test "relocation rejects deleted and non-crate identities without stale body access" {
    var runtime = try engine.Runtime.init(std.testing.allocator, .{
        .namespace = 513,
        .fixed_delta_seconds = 1.0 / 120.0,
    });
    defer runtime.deinit();
    var bodies = FakeBodiesForTest{};
    var feature = try TestFeature.init(
        std.testing.allocator,
        &runtime,
        &bodies,
        .{},
        1,
    );
    defer feature.deinit();
    var stepper = FakeWorldStepper{};
    var registry = runtime.registry();
    try feature.register(&registry);
    try registry.addSystem(.physics, "fake.step", &stepper, stepFakeWorld);

    const foreign_runtime_id = try runtime.create();
    defer runtime.destroy(foreign_runtime_id) catch unreachable;
    const non_crate_id = try runtime.identity(foreign_runtime_id);
    try feature.enqueue(.{ .relocate = .{
        .transaction_id = 1,
        .id = non_crate_id,
        .target_pose = .{ .position = .{ 1, 2, 3 } },
    } });
    try feature.enqueue(.{ .spawn = .{ .request_id = 2, .pose = .{} } });
    try runtime.tick();
    const spawned_id = switch (feature.pollOutcome() orelse return error.MissingOutcome) {
        .spawned => |spawned| spawned.id,
        else => return error.UnexpectedOutcome,
    };
    const not_owned = switch (feature.pollOutcome() orelse return error.MissingOutcome) {
        .rejected => |value| value,
        else => return error.UnexpectedOutcome,
    };
    try std.testing.expectEqual(RejectionReason.not_owned, not_owned.reason);
    try std.testing.expectEqual(@as(?u64, 1), not_owned.transaction_id);

    // The relocation is staged before the despawn but resolves identity only
    // at commit, so it cannot retain or dereference the destroyed body handle.
    try feature.enqueue(.{ .relocate = .{
        .transaction_id = 3,
        .id = spawned_id,
        .target_pose = .{ .position = .{ 9, 9, 9 } },
    } });
    try feature.enqueue(.{ .despawn = .{ .id = spawned_id } });
    try runtime.tick();
    switch (feature.pollOutcome() orelse return error.MissingOutcome) {
        .despawned => |id| try std.testing.expectEqualDeep(spawned_id, id),
        else => return error.UnexpectedOutcome,
    }
    const not_found = switch (feature.pollOutcome() orelse return error.MissingOutcome) {
        .rejected => |value| value,
        else => return error.UnexpectedOutcome,
    };
    try std.testing.expectEqual(CommandKind.relocate, not_found.command);
    try std.testing.expectEqual(RejectionReason.crate_not_found, not_found.reason);
    try std.testing.expectEqual(@as(?u64, 3), not_found.transaction_id);
    try std.testing.expectEqualDeep(@as(?engine.PersistentId, spawned_id), not_found.id);
    try std.testing.expectEqual(@as(u32, 0), bodies.relocate_calls);
    try std.testing.expectEqual(@as(u32, 0), bodies.live_count);
    try std.testing.expect(!feature.hasPendingCommands());
}

test "relocation adapter failure leaves body and revision unchanged" {
    var runtime = try engine.Runtime.init(std.testing.allocator, .{
        .namespace = 514,
        .fixed_delta_seconds = 1.0 / 120.0,
    });
    defer runtime.deinit();
    var bodies = FakeBodiesForTest{};
    var feature = try TestFeature.init(
        std.testing.allocator,
        &runtime,
        &bodies,
        .{},
        1,
    );
    var feature_live = true;
    defer if (feature_live) feature.deinit();
    var stepper = FakeWorldStepper{};
    var registry = runtime.registry();
    try feature.register(&registry);
    try registry.addSystem(.physics, "fake.step", &stepper, stepFakeWorld);
    try feature.enqueue(.{ .spawn = .{ .request_id = 1, .pose = .{} } });
    try runtime.tick();
    const id = switch (feature.pollOutcome() orelse return error.MissingOutcome) {
        .spawned => |spawned| spawned.id,
        else => return error.UnexpectedOutcome,
    };
    const body_before = bodies.states[0];

    bodies.fail_relocate = true;
    try feature.enqueue(.{ .relocate = .{
        .transaction_id = 1,
        .id = id,
        .target_pose = .{ .position = .{ 10, 20, 30 } },
        .expected_revision = 0,
    } });
    try std.testing.expectError(error.InjectedRelocationFailure, runtime.tick());
    try std.testing.expect(runtime.isFaulted());
    try std.testing.expectEqualDeep(body_before, bodies.states[0]);
    try std.testing.expectEqual(@as(u32, 1), bodies.relocate_calls);
    const runtime_id = runtime.resolve(id) orelse return error.MissingRuntimeIdentity;
    const revision = runtime.get(runtime_id, TestFeature.AuthoringRevision) orelse
        return error.MissingAuthoringRevision;
    try std.testing.expectEqual(@as(u64, 0), revision.value);
    try std.testing.expect(feature.pollOutcome() == null);

    feature.deinit();
    feature_live = false;
}

test "relocation revision exhaustion fails before adapter mutation" {
    var exhausted_runtime = try engine.Runtime.init(std.testing.allocator, .{
        .namespace = 515,
        .fixed_delta_seconds = 1.0 / 120.0,
    });
    defer exhausted_runtime.deinit();
    var exhausted_bodies = FakeBodiesForTest{};
    var exhausted_feature = try TestFeature.init(
        std.testing.allocator,
        &exhausted_runtime,
        &exhausted_bodies,
        .{},
        1,
    );
    defer exhausted_feature.deinit();
    var exhausted_stepper = FakeWorldStepper{};
    var exhausted_registry = exhausted_runtime.registry();
    try exhausted_feature.register(&exhausted_registry);
    try exhausted_registry.addSystem(
        .physics,
        "fake.step",
        &exhausted_stepper,
        stepFakeWorld,
    );
    try exhausted_feature.enqueue(.{ .spawn = .{ .request_id = 1, .pose = .{} } });
    try exhausted_runtime.tick();
    const exhausted_id = switch (exhausted_feature.pollOutcome() orelse
        return error.MissingOutcome) {
        .spawned => |spawned| spawned.id,
        else => return error.UnexpectedOutcome,
    };
    const exhausted_runtime_id = exhausted_runtime.resolve(exhausted_id) orelse
        return error.MissingRuntimeIdentity;
    const exhausted_revision = exhausted_runtime.getMut(
        exhausted_runtime_id,
        TestFeature.AuthoringRevision,
    ) orelse return error.MissingAuthoringRevision;
    exhausted_revision.value = std.math.maxInt(u64);
    const exhausted_body_before = exhausted_bodies.states[0];
    try exhausted_feature.enqueue(.{ .relocate = .{
        .transaction_id = 2,
        .id = exhausted_id,
        .target_pose = .{ .position = .{ 8, 8, 8 } },
        .expected_revision = std.math.maxInt(u64),
    } });
    try std.testing.expectError(error.AuthoringRevisionExhausted, exhausted_runtime.tick());
    try std.testing.expectEqualDeep(exhausted_body_before, exhausted_bodies.states[0]);
    try std.testing.expectEqual(@as(u32, 0), exhausted_bodies.relocate_calls);
    try std.testing.expectEqual(std.math.maxInt(u64), exhausted_revision.value);
    try std.testing.expect(exhausted_feature.pollOutcome() == null);
}

test "queued and staged relocations remain pending and affect logical digest" {
    var runtime = try engine.Runtime.init(std.testing.allocator, .{
        .namespace = 516,
        .fixed_delta_seconds = 1.0 / 120.0,
    });
    defer runtime.deinit();
    var bodies = FakeBodiesForTest{};
    var feature = try TestFeature.init(
        std.testing.allocator,
        &runtime,
        &bodies,
        .{},
        1,
    );
    defer feature.deinit();
    var stepper = FakeWorldStepper{};
    var probe = StagedRelocationProbe{ .feature = &feature };
    var registry = runtime.registry();
    try feature.register(&registry);
    try registry.addSystem(.pre_physics, "test.relocation_probe", &probe, StagedRelocationProbe.run);
    try registry.addSystem(.physics, "fake.step", &stepper, stepFakeWorld);
    try feature.enqueue(.{ .spawn = .{ .request_id = 1, .pose = .{} } });
    try runtime.tick();
    const id = switch (feature.pollOutcome() orelse return error.MissingOutcome) {
        .spawned => |spawned| spawned.id,
        else => return error.UnexpectedOutcome,
    };

    var scratch: [1]engine.PersistentId = undefined;
    var baseline_writer = engine.contracts.replay.Writer.init();
    try feature.writeLogicalState(&baseline_writer, &scratch);
    const baseline = baseline_writer.final();

    try feature.enqueue(.{ .relocate = .{
        .transaction_id = 19,
        .id = id,
        .target_pose = .{ .position = .{ 3, 4, 5 } },
        .velocity = .preserve,
        .expected_revision = 0,
    } });
    try std.testing.expect(feature.hasPendingCommands());
    var queued_writer = engine.contracts.replay.Writer.init();
    try feature.writeLogicalState(&queued_writer, &scratch);
    const queued = queued_writer.final();
    try std.testing.expect(!std.mem.eql(u8, &baseline, &queued));

    probe.armed = true;
    try runtime.tick();
    try std.testing.expect(probe.saw_pending);
    try std.testing.expect(!std.mem.eql(u8, &queued, &probe.digest));
    try std.testing.expect(!feature.hasPendingCommands());
    const relocated = switch (feature.pollOutcome() orelse return error.MissingOutcome) {
        .relocated => |value| value,
        else => return error.UnexpectedOutcome,
    };
    try std.testing.expectEqual(@as(u64, 1), relocated.committed_revision);

    var committed_writer = engine.contracts.replay.Writer.init();
    try feature.writeLogicalState(&committed_writer, &scratch);
    const committed = committed_writer.final();
    try std.testing.expect(!std.mem.eql(u8, &probe.digest, &committed));
}
