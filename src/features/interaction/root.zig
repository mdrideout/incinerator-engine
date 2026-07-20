//! InteractionFeature: one persistent carryable crossing spatial ownership.
//!
//! This slice deliberately proves the ownership transaction without becoming
//! a general inventory or entity-registry subsystem. The feature owns one
//! logical object, CharacterFeature exposes a narrow carrier capability, and
//! Spatial district coordinates index world state but do not gate whether a
//! live carryable has a physics body or can be dropped.

const std = @import("std");
const engine = @import("incinerator_engine");
const feature_contract = @import("interaction_feature_contract");
const district_contract = @import("district_contract");
const interaction_contract = @import("interaction_contract");

const logical_state_domain = "incinerator.interaction.logical";
const logical_state_schema: u16 = 2;

const max_carryables = feature_contract.max_carryables;
const max_pending_commands = feature_contract.max_pending_commands;
const max_outcomes = feature_contract.max_outcomes;
const declared_budget = feature_contract.declared_budget;
const Config = feature_contract.Config;
const InteractionConfigV1 = feature_contract.InteractionConfigV1;
const Ownership = feature_contract.Ownership;
const SpawnCarryable = feature_contract.SpawnCarryable;
const DespawnCarryable = feature_contract.DespawnCarryable;
const Collect = feature_contract.Collect;
const Drop = feature_contract.Drop;
const DropPlacement = feature_contract.DropPlacement;
const Command = feature_contract.Command;
const CommandKind = feature_contract.CommandKind;
const RejectionReason = feature_contract.RejectionReason;
const Outcome = feature_contract.Outcome;
const CarryableView = feature_contract.CarryableView;
const CarryableDraw = feature_contract.CarryableDraw;
const Diagnostics = feature_contract.Diagnostics;
const InteractionV1 = feature_contract.InteractionV1;
const validateRecords = feature_contract.validateRecords;

const held_presentation_offset: [3]f32 = .{ 0, 1.0, -0.6 };

const FixedQueue = engine.BoundedQueue;

pub fn Feature(
    comptime Bodies: type,
    comptime CarrierAccess: type,
) type {
    engine.physics.assertImplementation(Bodies);
    interaction_contract.assertCarrierImplementation(CarrierAccess);

    return struct {
        const Self = @This();

        const Carryable = struct { half_extents: [3]f32 };
        const LogicalState = struct {
            ownership: Ownership,
            state: engine.physics.BodyState,
        };
        const RuntimeBody = struct { handle: ?Bodies.Handle = null };
        const QueuedCommand = struct {
            command: Command,
            eligible_tick: u64,
        };

        runtime: *engine.Runtime,
        bodies: *Bodies,
        carriers: *CarrierAccess,
        config: Config,
        active: ?engine.RuntimeId = null,
        commands: FixedQueue(QueuedCommand, max_pending_commands) = .{},
        outcomes: FixedQueue(Outcome, max_outcomes) = .{},
        commands_high_water: u32 = 0,
        outcomes_high_water: u32 = 0,
        commands_rejected: u64 = 0,
        presentation: [max_carryables]CarryableDraw = undefined,
        presentation_count: usize = 0,

        pub fn init(
            runtime: *engine.Runtime,
            bodies: *Bodies,
            carriers: *CarrierAccess,
            config: Config,
        ) !Self {
            try config.validate();
            return .{
                .runtime = runtime,
                .bodies = bodies,
                .carriers = carriers,
                .config = config,
            };
        }

        pub fn register(self: *Self, registry: *engine.FeatureRegistry) !void {
            try registry.registerComponent(Carryable);
            try registry.registerComponent(LogicalState);
            try registry.registerComponent(RuntimeBody);
            try registry.addSystem(
                .commands,
                "interaction.reconcile_and_apply_commands",
                self,
                applyCommandsSystem,
            );
            try registry.addSystem(
                .post_physics,
                "interaction.publish_physics",
                self,
                publishPhysicsSystem,
            );
        }

        pub fn deinit(self: *Self) void {
            if (self.active) |runtime_id| {
                const id = self.runtime.identity(runtime_id) catch |err| {
                    std.debug.panic("interaction identity cleanup failed: {s}", .{@errorName(err)});
                };
                const logical = self.runtime.get(runtime_id, LogicalState) orelse
                    @panic("interaction logical cleanup invariant failed");
                switch (logical.ownership) {
                    .spatially_owned => {},
                    .inventory_held => |holder| {
                        // A faulted runtime is terminal and rejects mutable
                        // carrier access. Character teardown immediately
                        // destroys its private runtime state afterward, so
                        // only a healthy world needs the explicit detach.
                        if (!self.runtime.isFaulted()) {
                            self.carriers.endCarry(holder, id) catch |err| {
                                std.debug.panic("interaction carrier cleanup failed: {s}", .{@errorName(err)});
                            };
                        }
                    },
                }
                if (self.runtime.get(runtime_id, RuntimeBody)) |body| {
                    if (body.handle) |handle| self.destroyBodyOrPanic(handle);
                }
                self.destroyRuntimeOrPanic(runtime_id);
            }
            self.* = undefined;
        }

        /// Commands and unread outcomes share one reservation budget. An
        /// accepted command is therefore guaranteed one outcome slot before
        /// it can mutate gameplay state.
        pub fn enqueue(self: *Self, command: Command) !void {
            try self.runtime.ensureHealthy();
            try validateCommand(command);
            if (self.commands.len == max_pending_commands or
                self.commands.len + self.outcomes.len >= max_outcomes)
            {
                self.commands_rejected +|= 1;
                return error.InteractionCommandQueueFull;
            }
            try self.commands.push(.{
                .command = command,
                .eligible_tick = try self.runtime.commandTargetTick(),
            });
            self.observeQueueHighWater();
        }

        pub fn pollOutcome(self: *Self) ?Outcome {
            const outcome = self.outcomes.pop();
            self.observeQueueHighWater();
            return outcome;
        }

        pub fn hasPendingCommands(self: *const Self) bool {
            return self.commands.len != 0;
        }

        pub fn count(self: *const Self) usize {
            return if (self.active == null) 0 else 1;
        }

        pub fn diagnostics(self: *const Self) Diagnostics {
            var spatially_owned: u32 = 0;
            var held: u32 = 0;
            var bodies: u32 = 0;
            if (self.active) |runtime_id| {
                if (self.runtime.get(runtime_id, LogicalState)) |logical| {
                    switch (logical.ownership) {
                        .spatially_owned => spatially_owned = 1,
                        .inventory_held => held = 1,
                    }
                }
                if (self.runtime.get(runtime_id, RuntimeBody)) |body| {
                    if (body.handle != null) bodies = 1;
                }
            }
            return .{
                .active_count = if (self.active == null) 0 else 1,
                .spatially_owned_count = spatially_owned,
                .held_count = held,
                .dynamic_body_count = bodies,
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
            };
        }

        pub fn view(self: *Self, id: engine.PersistentId) !CarryableView {
            const runtime_id = self.runtime.resolve(id) orelse
                return error.InteractionCarryableNotFound;
            const carryable = self.runtime.get(runtime_id, Carryable) orelse
                return error.InteractionCarryableNotOwned;
            const logical = self.runtime.getMut(runtime_id, LogicalState) orelse
                return error.InteractionLogicalStateInvariantBroken;
            const body = self.runtime.get(runtime_id, RuntimeBody) orelse
                return error.InteractionBodyStateInvariantBroken;
            if (body.handle) |handle| {
                logical.state = try (try self.bodies.bodyState(handle)).normalized();
            }
            return .{
                .id = id,
                .half_extents = carryable.half_extents,
                .ownership = logical.ownership,
                .state = logical.state,
                .body_present = body.handle != null,
            };
        }

        pub fn extract(self: *Self) ![]const CarryableDraw {
            self.presentation_count = 0;
            const runtime_id = self.active orelse return self.presentation[0..0];
            const id = try self.runtime.identity(runtime_id);
            const view_value = try self.view(id);
            const pose = switch (view_value.ownership) {
                .spatially_owned => if (view_value.body_present)
                    view_value.state.pose
                else
                    return self.presentation[0..0],
                .inventory_held => |holder| blk: {
                    const carrier = (try self.carriers.carryState(holder)) orelse
                        return error.InteractionCarrierNotFound;
                    try carrier.validate();
                    switch (carrier.carry_mode) {
                        .holding => |item| if (!std.meta.eql(item, id)) {
                            return error.InteractionCarrierRelationshipInvariantBroken;
                        },
                        .empty => return error.InteractionCarrierRelationshipInvariantBroken,
                    }
                    break :blk try deriveDropPose(carrier.pose, held_presentation_offset);
                },
            };
            self.presentation[0] = .{
                .persistent_id = id,
                .pose = pose,
                .half_extents = view_value.half_extents,
                .ownership = view_value.ownership,
            };
            self.presentation_count = 1;
            return self.presentation[0..self.presentation_count];
        }

        pub fn snapshotRecords(
            self: *Self,
            allocator: std.mem.Allocator,
        ) ![]InteractionV1 {
            try self.runtime.ensureSnapshotBoundary();
            if (self.hasPendingCommands()) return error.CommandsPending;
            const record_count: usize = if (self.active == null) 0 else 1;
            const records = try allocator.alloc(InteractionV1, record_count);
            errdefer allocator.free(records);
            if (self.active) |runtime_id| {
                const id = try self.runtime.identity(runtime_id);
                const view_value = try self.view(id);
                records[0] = .{
                    .id = id,
                    .half_extents = view_value.half_extents,
                    .ownership = view_value.ownership,
                    .pose = try view_value.state.pose.normalized(),
                    .linear_velocity = view_value.state.velocity.linear,
                    .angular_velocity = view_value.state.velocity.angular,
                };
            }
            return records;
        }

        /// Restore into an empty, registering feature. Spatial world objects
        /// always recreate their body; inventory-held records rebuild the
        /// character relationship without creating a physics body.
        pub fn restoreRecords(self: *Self, records: []const InteractionV1) !void {
            try validateRecords(records);
            if (self.active != null or self.hasPendingCommands() or self.outcomes.len != 0) {
                return error.RestoreRequiresEmptyFeature;
            }
            if (records.len == 0) return;

            const record = records[0];
            const state = try (engine.physics.BodyState{
                .pose = record.pose,
                .velocity = .{
                    .linear = record.linear_velocity,
                    .angular = record.angular_velocity,
                },
            }).normalized();

            switch (record.ownership) {
                .spatially_owned => {
                    const body = try self.bodies.createDynamicBox(.{
                        .pose = state.pose,
                        .velocity = state.velocity,
                        .half_extents = record.half_extents,
                    });
                    errdefer self.destroyBodyOrPanic(body);
                    const runtime_id = try self.createRuntimeRecord(
                        record.id,
                        record.half_extents,
                        record.ownership,
                        state,
                        body,
                    );
                    self.active = runtime_id;
                },
                .inventory_held => |holder| {
                    const carrier = (try self.carriers.carryState(holder)) orelse
                        return error.InteractionCarrierNotFound;
                    try carrier.validate();
                    if (carrier.mobility != .on_foot) {
                        return error.InteractionCarrierNotOnFoot;
                    }
                    switch (carrier.carry_mode) {
                        .empty => {},
                        .holding => return error.InteractionCarrierNotEmpty,
                    }
                    const runtime_id = try self.createRuntimeRecord(
                        record.id,
                        record.half_extents,
                        record.ownership,
                        state,
                        null,
                    );
                    errdefer self.destroyRuntimeOrPanic(runtime_id);
                    try self.carriers.beginCarry(holder, record.id);
                    self.active = runtime_id;
                },
            }
        }

        /// Append the complete feature-owned state to a canonical replay
        /// writer. Fixed queues make this path allocation-free.
        pub fn writeLogicalState(
            self: *Self,
            writer: *engine.contracts.replay.Writer,
        ) !void {
            try self.runtime.ensureOwnerThread();
            writer.writeU8(@intCast(logical_state_domain.len));
            writer.writeBytes(logical_state_domain);
            writer.writeU16(logical_state_schema);
            writer.writeU64(self.runtime.tickIndex());
            writer.writeBool(self.active != null);

            if (self.active) |runtime_id| {
                const id = try self.runtime.identity(runtime_id);
                const view_value = try self.view(id);
                writePersistentId(writer, id);
                try writeVector3(writer, view_value.half_extents);
                try writeOwnership(writer, view_value.ownership);
                try writeBodyState(writer, view_value.state);
                writer.writeBool(view_value.body_present);
            }

            writer.writeU32(@intCast(self.commands.len));
            for (0..self.commands.len) |index| {
                const queued = self.commands.atAssumeValid(index);
                writer.writeU64(queued.eligible_tick);
                try writeCommand(writer, queued.command);
            }
            writer.writeU32(@intCast(self.outcomes.len));
        }

        fn applyCommandsSystem(
            raw: *anyopaque,
            _: *engine.Runtime,
            tick: engine.TickContext,
        ) !void {
            const self: *Self = @ptrCast(@alignCast(raw));
            defer self.observeQueueHighWater();
            const command_count = self.commands.len;
            for (0..command_count) |_| {
                const queued = self.commands.pop() orelse
                    return error.InteractionCommandQueueInvariantBroken;
                if (queued.eligible_tick > tick.tick_index) {
                    self.commands.pushAssumeCapacity(queued);
                    continue;
                }
                // enqueue reserves this slot before admission.
                std.debug.assert(self.outcomes.len < max_outcomes);
                self.outcomes.pushAssumeCapacity(try self.applyCommand(queued.command));
            }
        }

        fn publishPhysicsSystem(
            raw: *anyopaque,
            _: *engine.Runtime,
            _: engine.TickContext,
        ) !void {
            const self: *Self = @ptrCast(@alignCast(raw));
            const runtime_id = self.active orelse return;
            const body = self.runtime.get(runtime_id, RuntimeBody) orelse
                return error.InteractionBodyStateInvariantBroken;
            const handle = body.handle orelse return;
            const logical = self.runtime.getMut(runtime_id, LogicalState) orelse
                return error.InteractionLogicalStateInvariantBroken;
            switch (logical.ownership) {
                .spatially_owned => {},
                .inventory_held => return error.HeldInteractionHasBody,
            }
            logical.state = try (try self.bodies.bodyState(handle)).normalized();
        }

        fn applyCommand(self: *Self, command: Command) !Outcome {
            return switch (command) {
                .spawn => |spawn| self.applySpawn(spawn),
                .despawn => |despawn| self.applyDespawn(despawn),
                .collect => |collect| self.applyCollect(collect),
                .drop => |drop| self.applyDrop(drop),
            };
        }

        fn applySpawn(self: *Self, spawn: SpawnCarryable) !Outcome {
            if (self.active != null) return .{ .rejected = .{
                .command = .spawn,
                .reason = .capacity_reached,
                .request_id = spawn.request_id,
            } };
            const desc = try (engine.physics.DynamicBoxDesc{
                .pose = spawn.pose,
                .velocity = spawn.velocity,
                .half_extents = spawn.half_extents,
            }).normalized();
            const coord = try district_contract.chunkCoordForWorldPosition(desc.pose.position);
            const runtime_id = try self.runtime.create();
            errdefer self.destroyRuntimeOrPanic(runtime_id);
            const id = try self.runtime.identity(runtime_id);
            const body = try self.bodies.createDynamicBox(desc);
            errdefer self.destroyBodyOrPanic(body);
            try self.installRuntimeComponents(
                runtime_id,
                desc.half_extents,
                .{ .spatially_owned = coord },
                .{ .pose = desc.pose, .velocity = desc.velocity },
                body,
            );
            self.active = runtime_id;
            return .{ .spawned = .{
                .request_id = spawn.request_id,
                .id = id,
                .owner = coord,
            } };
        }

        fn applyDespawn(self: *Self, despawn: DespawnCarryable) !Outcome {
            const runtime_id = self.runtime.resolve(despawn.id) orelse
                return rejectionFor(.despawn, .carryable_not_found, null, null, despawn.id);
            _ = self.runtime.get(runtime_id, Carryable) orelse
                return rejectionFor(.despawn, .not_owned, null, null, despawn.id);
            if (self.active == null or !std.meta.eql(self.active.?, runtime_id)) {
                return error.InteractionActiveIndexInvariantBroken;
            }
            const logical = self.runtime.get(runtime_id, LogicalState) orelse
                return error.InteractionLogicalStateInvariantBroken;
            switch (logical.ownership) {
                .spatially_owned => {},
                .inventory_held => return rejectionFor(
                    .despawn,
                    .carryable_held,
                    null,
                    null,
                    despawn.id,
                ),
            }
            const body = self.runtime.get(runtime_id, RuntimeBody) orelse
                return error.InteractionBodyStateInvariantBroken;
            if (body.handle) |handle| try self.bodies.destroyBody(handle);
            try self.runtime.destroy(runtime_id);
            self.active = null;
            return .{ .despawned = despawn.id };
        }

        fn applyCollect(self: *Self, collect: Collect) !Outcome {
            const runtime_id = self.runtime.resolve(collect.carryable_id) orelse
                return rejectionFor(
                    .collect,
                    .carryable_not_found,
                    collect.transaction_id,
                    collect.carrier_id,
                    collect.carryable_id,
                );
            const carryable = self.runtime.get(runtime_id, Carryable) orelse
                return rejectionFor(
                    .collect,
                    .not_owned,
                    collect.transaction_id,
                    collect.carrier_id,
                    collect.carryable_id,
                );
            if (self.active == null or !std.meta.eql(self.active.?, runtime_id)) {
                return error.InteractionActiveIndexInvariantBroken;
            }
            const logical = self.runtime.get(runtime_id, LogicalState) orelse
                return error.InteractionLogicalStateInvariantBroken;
            const previous_owner = switch (logical.ownership) {
                .spatially_owned => |coord| coord,
                .inventory_held => return rejectionFor(
                    .collect,
                    .carryable_already_held,
                    collect.transaction_id,
                    collect.carrier_id,
                    collect.carryable_id,
                ),
            };
            const carrier = (try self.carriers.carryState(collect.carrier_id)) orelse
                return rejectionFor(
                    .collect,
                    .carrier_not_found,
                    collect.transaction_id,
                    collect.carrier_id,
                    collect.carryable_id,
                );
            try carrier.validate();
            if (carrier.mobility != .on_foot) {
                return rejectionFor(
                    .collect,
                    .carrier_not_on_foot,
                    collect.transaction_id,
                    collect.carrier_id,
                    collect.carryable_id,
                );
            }
            switch (carrier.carry_mode) {
                .empty => {},
                .holding => return rejectionFor(
                    .collect,
                    .carrier_not_empty,
                    collect.transaction_id,
                    collect.carrier_id,
                    collect.carryable_id,
                ),
            }

            const body = self.runtime.getMut(runtime_id, RuntimeBody) orelse
                return error.InteractionBodyStateInvariantBroken;
            const handle = body.handle orelse
                return error.SpatialInteractionMissingBody;
            const state = try (try self.bodies.bodyState(handle)).normalized();
            if (!withinRange(
                carrier.pose.position,
                state.pose.position,
                self.config.collect_range,
            )) {
                return rejectionFor(
                    .collect,
                    .too_far,
                    collect.transaction_id,
                    collect.carrier_id,
                    collect.carryable_id,
                );
            }

            // The character transition happens first. If body removal fails,
            // its exact inverse restores the prior empty carrier while the
            // still-live body and object ownership remain untouched.
            try self.carriers.beginCarry(collect.carrier_id, collect.carryable_id);
            self.bodies.destroyBody(handle) catch |err| {
                self.carriers.cancelBeginCarry(
                    collect.carrier_id,
                    collect.carryable_id,
                );
                return err;
            };

            const logical_mut = self.runtime.getMut(runtime_id, LogicalState) orelse
                @panic("interaction logical state disappeared during collect commit");
            logical_mut.state = state;
            logical_mut.ownership = .{ .inventory_held = collect.carrier_id };
            body.handle = null;
            _ = carryable;
            return .{ .collected = .{
                .transaction_id = collect.transaction_id,
                .carrier_id = collect.carrier_id,
                .carryable_id = collect.carryable_id,
                .previous_owner = previous_owner,
            } };
        }

        fn applyDrop(self: *Self, drop: Drop) !Outcome {
            const runtime_id = self.runtime.resolve(drop.carryable_id) orelse
                return rejectionFor(
                    .drop,
                    .carryable_not_found,
                    drop.transaction_id,
                    drop.carrier_id,
                    drop.carryable_id,
                );
            const carryable = self.runtime.get(runtime_id, Carryable) orelse
                return rejectionFor(
                    .drop,
                    .not_owned,
                    drop.transaction_id,
                    drop.carrier_id,
                    drop.carryable_id,
                );
            if (self.active == null or !std.meta.eql(self.active.?, runtime_id)) {
                return error.InteractionActiveIndexInvariantBroken;
            }
            const logical = self.runtime.get(runtime_id, LogicalState) orelse
                return error.InteractionLogicalStateInvariantBroken;
            const holder = switch (logical.ownership) {
                .spatially_owned => return rejectionFor(
                    .drop,
                    .carrier_not_holding,
                    drop.transaction_id,
                    drop.carrier_id,
                    drop.carryable_id,
                ),
                .inventory_held => |holder_id| holder_id,
            };
            if (!std.meta.eql(holder, drop.carrier_id)) {
                return rejectionFor(
                    .drop,
                    .wrong_holder,
                    drop.transaction_id,
                    drop.carrier_id,
                    drop.carryable_id,
                );
            }

            const carrier = (try self.carriers.carryState(drop.carrier_id)) orelse
                return rejectionFor(
                    .drop,
                    .carrier_not_found,
                    drop.transaction_id,
                    drop.carrier_id,
                    drop.carryable_id,
                );
            try carrier.validate();
            if (carrier.mobility != .on_foot) {
                return rejectionFor(
                    .drop,
                    .carrier_not_on_foot,
                    drop.transaction_id,
                    drop.carrier_id,
                    drop.carryable_id,
                );
            }
            switch (carrier.carry_mode) {
                .empty => return rejectionFor(
                    .drop,
                    .carrier_not_holding,
                    drop.transaction_id,
                    drop.carrier_id,
                    drop.carryable_id,
                ),
                .holding => |item_id| if (!std.meta.eql(item_id, drop.carryable_id)) {
                    return rejectionFor(
                        .drop,
                        .wrong_holder,
                        drop.transaction_id,
                        drop.carrier_id,
                        drop.carryable_id,
                    );
                },
            }

            const placement = try self.resolveDropPlacement(carrier.pose);
            const drop_pose = placement.pose;
            const destination = placement.destination;
            const body_component = self.runtime.getMut(runtime_id, RuntimeBody) orelse
                return error.InteractionBodyStateInvariantBroken;
            if (body_component.handle != null) return error.HeldInteractionHasBody;
            const state = engine.physics.BodyState{ .pose = drop_pose, .velocity = .{} };

            // Body creation is the candidate. If the atomic character detach
            // fails, destroying it restores the exact held/bodyless state.
            const candidate = try self.bodies.createDynamicBox(.{
                .pose = drop_pose,
                .velocity = .{},
                .half_extents = carryable.half_extents,
            });
            self.carriers.endCarry(drop.carrier_id, drop.carryable_id) catch |err| {
                self.destroyBodyOrPanic(candidate);
                return err;
            };

            const logical_mut = self.runtime.getMut(runtime_id, LogicalState) orelse
                @panic("interaction logical state disappeared during drop commit");
            logical_mut.state = state;
            logical_mut.ownership = .{ .spatially_owned = destination };
            body_component.handle = candidate;
            return .{ .dropped = .{
                .transaction_id = drop.transaction_id,
                .carrier_id = drop.carrier_id,
                .carryable_id = drop.carryable_id,
                .owner = destination,
                .pose = drop_pose,
                .placement = placement.kind,
            } };
        }

        const ResolvedDropPlacement = struct {
            pose: engine.physics.Pose,
            destination: district_contract.ChunkCoord,
            kind: DropPlacement,
        };

        fn resolveDropPlacement(
            self: *Self,
            raw_carrier_pose: engine.physics.Pose,
        ) !ResolvedDropPlacement {
            const carrier_pose = try raw_carrier_pose.normalized();
            const pose = try deriveDropPose(carrier_pose, self.config.drop_offset);
            return .{
                .pose = pose,
                .destination = try district_contract.chunkCoordForWorldPosition(pose.position),
                .kind = .configured_offset,
            };
        }

        fn createRuntimeRecord(
            self: *Self,
            id: engine.PersistentId,
            half_extents: [3]f32,
            ownership: Ownership,
            state: engine.physics.BodyState,
            body: ?Bodies.Handle,
        ) !engine.RuntimeId {
            const runtime_id = try self.runtime.createWithPersistentId(id);
            errdefer self.destroyRuntimeOrPanic(runtime_id);
            try self.installRuntimeComponents(
                runtime_id,
                half_extents,
                ownership,
                state,
                body,
            );
            return runtime_id;
        }

        fn installRuntimeComponents(
            self: *Self,
            runtime_id: engine.RuntimeId,
            half_extents: [3]f32,
            ownership: Ownership,
            state: engine.physics.BodyState,
            body: ?Bodies.Handle,
        ) !void {
            try self.runtime.set(runtime_id, Carryable, .{ .half_extents = half_extents });
            try self.runtime.set(runtime_id, LogicalState, .{
                .ownership = ownership,
                .state = state,
            });
            try self.runtime.set(runtime_id, RuntimeBody, .{ .handle = body });
        }

        fn observeQueueHighWater(self: *Self) void {
            self.commands_high_water = @max(
                self.commands_high_water,
                @as(u32, @intCast(self.commands.len)),
            );
            self.outcomes_high_water = @max(
                self.outcomes_high_water,
                @as(u32, @intCast(self.outcomes.len)),
            );
        }

        fn destroyBodyOrPanic(self: *Self, handle: Bodies.Handle) void {
            self.bodies.destroyBody(handle) catch |err| {
                std.debug.panic(
                    "interaction body cleanup invariant failed: {s}",
                    .{@errorName(err)},
                );
            };
        }

        fn destroyRuntimeOrPanic(self: *Self, runtime_id: engine.RuntimeId) void {
            self.runtime.destroy(runtime_id) catch |err| {
                std.debug.panic(
                    "interaction entity cleanup invariant failed: {s}",
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
        .collect => |collect| {
            if (collect.transaction_id == 0) return error.InvalidTransactionId;
            try collect.carrier_id.validate();
            try collect.carryable_id.validate();
        },
        .drop => |drop| {
            if (drop.transaction_id == 0) return error.InvalidTransactionId;
            try drop.carrier_id.validate();
            try drop.carryable_id.validate();
        },
    }
}

fn rejectionFor(
    command: CommandKind,
    reason: RejectionReason,
    transaction_id: ?u64,
    carrier_id: ?engine.PersistentId,
    carryable_id: engine.PersistentId,
) Outcome {
    return .{ .rejected = .{
        .command = command,
        .reason = reason,
        .transaction_id = transaction_id,
        .carrier_id = carrier_id,
        .carryable_id = carryable_id,
    } };
}

fn withinRange(a: [3]f32, b: [3]f32, range: f32) bool {
    var squared: f32 = 0;
    inline for (0..3) |index| {
        const delta = a[index] - b[index];
        squared += delta * delta;
    }
    return std.math.isFinite(squared) and squared <= range * range;
}

fn deriveDropPose(
    raw_carrier_pose: engine.physics.Pose,
    local_offset: [3]f32,
) !engine.physics.Pose {
    const carrier_pose = try raw_carrier_pose.normalized();
    const rotated = rotateVector(carrier_pose.rotation, local_offset);
    return (engine.physics.Pose{
        .position = .{
            carrier_pose.position[0] + rotated[0],
            carrier_pose.position[1] + rotated[1],
            carrier_pose.position[2] + rotated[2],
        },
        .rotation = carrier_pose.rotation,
    }).normalized();
}

fn rotateVector(rotation: [4]f32, value: [3]f32) [3]f32 {
    const x = rotation[0];
    const y = rotation[1];
    const z = rotation[2];
    const w = rotation[3];
    const dot_uv = x * value[0] + y * value[1] + z * value[2];
    const dot_uu = x * x + y * y + z * z;
    const cross = [3]f32{
        y * value[2] - z * value[1],
        z * value[0] - x * value[2],
        x * value[1] - y * value[0],
    };
    return .{
        2 * dot_uv * x + (w * w - dot_uu) * value[0] + 2 * w * cross[0],
        2 * dot_uv * y + (w * w - dot_uu) * value[1] + 2 * w * cross[1],
        2 * dot_uv * z + (w * w - dot_uu) * value[2] + 2 * w * cross[2],
    };
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

fn writeBodyState(
    writer: *engine.contracts.replay.Writer,
    state: engine.physics.BodyState,
) !void {
    try writePose(writer, state.pose);
    try writeVelocity(writer, state.velocity);
}

fn writeOwnership(
    writer: *engine.contracts.replay.Writer,
    ownership: Ownership,
) !void {
    switch (ownership) {
        .spatially_owned => |coord| {
            writer.writeU8(1);
            writer.writeI32(coord.x);
            writer.writeI32(coord.z);
        },
        .inventory_held => |holder| {
            writer.writeU8(2);
            writePersistentId(writer, holder);
        },
    }
}

fn writeCommand(
    writer: *engine.contracts.replay.Writer,
    command: Command,
) !void {
    switch (command) {
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
        .collect => |collect| {
            writer.writeU8(3);
            writer.writeU64(collect.transaction_id);
            writePersistentId(writer, collect.carrier_id);
            writePersistentId(writer, collect.carryable_id);
        },
        .drop => |drop| {
            writer.writeU8(4);
            writer.writeU64(drop.transaction_id);
            writePersistentId(writer, drop.carrier_id);
            writePersistentId(writer, drop.carryable_id);
        },
    }
}

fn quaternionNeedsNegation(rotation: [4]f32) bool {
    for ([_]usize{ 3, 2, 1, 0 }) |index| {
        if (rotation[index] > 0) return false;
        if (rotation[index] < 0) return true;
    }
    return false;
}

const FakeBodies = struct {
    pub const Handle = u32;
    const capacity: usize = 64;

    states: [capacity]engine.physics.BodyState = [_]engine.physics.BodyState{.{}} ** capacity,
    half_extents: [capacity][3]f32 = [_][3]f32{.{ 1, 1, 1 }} ** capacity,
    live: [capacity]bool = [_]bool{false} ** capacity,
    next_handle: Handle = 1,
    live_count: usize = 0,
    creates: u64 = 0,
    destroys: u64 = 0,
    fail_next_create: bool = false,
    fail_next_destroy: bool = false,
    fail_next_state: bool = false,

    pub fn createDynamicBox(
        self: *FakeBodies,
        raw: engine.physics.DynamicBoxDesc,
    ) !Handle {
        if (self.fail_next_create) {
            self.fail_next_create = false;
            return error.InjectedBodyCreateFailure;
        }
        const desc = try raw.normalized();
        if (self.next_handle >= capacity) return error.FakeBodyCapacityReached;
        const handle = self.next_handle;
        self.next_handle += 1;
        self.states[handle] = .{ .pose = desc.pose, .velocity = desc.velocity };
        self.half_extents[handle] = desc.half_extents;
        self.live[handle] = true;
        self.live_count += 1;
        self.creates += 1;
        return handle;
    }

    pub fn destroyBody(self: *FakeBodies, handle: Handle) !void {
        if (self.fail_next_destroy) {
            self.fail_next_destroy = false;
            return error.InjectedBodyDestroyFailure;
        }
        try self.requireLive(handle);
        self.live[handle] = false;
        self.live_count -= 1;
        self.destroys += 1;
    }

    pub fn bodyState(self: *FakeBodies, handle: Handle) !engine.physics.BodyState {
        if (self.fail_next_state) {
            self.fail_next_state = false;
            return error.InjectedBodyStateFailure;
        }
        try self.requireLive(handle);
        return self.states[handle];
    }

    pub fn relocateBody(
        self: *FakeBodies,
        handle: Handle,
        raw: engine.physics.BodyState,
    ) !void {
        try self.requireLive(handle);
        self.states[handle] = try raw.normalized();
    }

    pub fn applyImpulse(
        self: *FakeBodies,
        handle: Handle,
        impulse: [3]f32,
    ) !void {
        try self.requireLive(handle);
        for (impulse, 0..) |component, index| {
            self.states[handle].velocity.linear[index] += component;
        }
    }

    fn requireLive(self: *const FakeBodies, handle: Handle) !void {
        if (handle == 0 or handle >= capacity or !self.live[handle]) {
            return error.FakeBodyNotFound;
        }
    }

    fn onlyLiveHandle(self: *const FakeBodies) ?Handle {
        for (1..self.next_handle) |raw| {
            const handle: Handle = @intCast(raw);
            if (self.live[handle]) return handle;
        }
        return null;
    }
};

const test_namespace: u64 = 77;
const test_carrier_id = engine.PersistentId{ .namespace = test_namespace, .local = 900 };
const other_carrier_id = engine.PersistentId{ .namespace = test_namespace, .local = 901 };

const FakeCarrierAccess = struct {
    id: engine.PersistentId = test_carrier_id,
    state: interaction_contract.CarryState = .{
        .pose = .{},
        .mobility = .on_foot,
        .carry_mode = .empty,
    },
    present: bool = true,
    fail_next_begin: bool = false,
    fail_next_end: bool = false,
    begins: u64 = 0,
    ends: u64 = 0,
    cancellations: u64 = 0,

    pub fn carryState(
        self: *FakeCarrierAccess,
        id: engine.PersistentId,
    ) !?interaction_contract.CarryState {
        if (!self.present or !std.meta.eql(id, self.id)) return null;
        return self.state;
    }

    pub fn beginCarry(
        self: *FakeCarrierAccess,
        carrier_id: engine.PersistentId,
        item_id: engine.PersistentId,
    ) !void {
        if (!self.present or !std.meta.eql(carrier_id, self.id)) {
            return error.FakeCarrierNotFound;
        }
        if (self.fail_next_begin) {
            self.fail_next_begin = false;
            return error.InjectedBeginCarryFailure;
        }
        if (self.state.mobility != .on_foot) return error.FakeCarrierDriving;
        switch (self.state.carry_mode) {
            .empty => {},
            .holding => return error.FakeCarrierOccupied,
        }
        self.state.carry_mode = .{ .holding = item_id };
        self.begins += 1;
    }

    pub fn endCarry(
        self: *FakeCarrierAccess,
        carrier_id: engine.PersistentId,
        item_id: engine.PersistentId,
    ) !void {
        if (!self.present or !std.meta.eql(carrier_id, self.id)) {
            return error.FakeCarrierNotFound;
        }
        if (self.fail_next_end) {
            self.fail_next_end = false;
            return error.InjectedEndCarryFailure;
        }
        switch (self.state.carry_mode) {
            .empty => return error.FakeCarrierEmpty,
            .holding => |held| if (!std.meta.eql(held, item_id)) {
                return error.FakeWrongHeldItem;
            },
        }
        self.state.carry_mode = .empty;
        self.ends += 1;
    }

    pub fn cancelBeginCarry(
        self: *FakeCarrierAccess,
        carrier_id: engine.PersistentId,
        item_id: engine.PersistentId,
    ) void {
        std.debug.assert(std.meta.eql(carrier_id, self.id));
        switch (self.state.carry_mode) {
            .empty => @panic("fake cancel without held item"),
            .holding => |held| std.debug.assert(std.meta.eql(held, item_id)),
        }
        self.state.carry_mode = .empty;
        self.cancellations += 1;
    }
};

const TestFeature = Feature(FakeBodies, FakeCarrierAccess);

const TestWorld = struct {
    runtime: engine.Runtime,
    bodies: FakeBodies = .{},
    carriers: FakeCarrierAccess = .{},
    feature: TestFeature,

    fn init(self: *TestWorld, config: Config) !void {
        self.* = .{
            .runtime = try engine.Runtime.init(std.testing.allocator, .{
                .namespace = test_namespace,
                .fixed_delta_seconds = 1.0 / 120.0,
            }),
            .feature = undefined,
        };
        errdefer self.runtime.deinit();
        self.feature = try TestFeature.init(
            &self.runtime,
            &self.bodies,
            &self.carriers,
            config,
        );
        var registry = self.runtime.registry();
        try self.feature.register(&registry);
    }

    fn deinit(self: *TestWorld) void {
        self.feature.deinit();
        tryExpectNoLeaks(self) catch |err| {
            std.debug.panic("interaction fake cleanup failed: {s}", .{@errorName(err)});
        };
        self.runtime.deinit();
    }

    fn tryExpectNoLeaks(self: *const TestWorld) !void {
        try std.testing.expectEqual(@as(usize, 0), self.bodies.live_count);
        try std.testing.expectEqual(@as(usize, 0), self.runtime.persistentCount());
    }
};

fn spawnTestCarryable(world: *TestWorld, position: [3]f32) !engine.PersistentId {
    try world.feature.enqueue(.{ .spawn = .{
        .request_id = 10,
        .pose = .{ .position = position },
    } });
    try world.runtime.tick();
    const outcome = world.feature.pollOutcome() orelse return error.MissingSpawnOutcome;
    return switch (outcome) {
        .spawned => |spawned| spawned.id,
        else => error.UnexpectedSpawnOutcome,
    };
}

fn expectRejection(
    outcome: ?Outcome,
    command: CommandKind,
    reason: RejectionReason,
) !void {
    const actual = outcome orelse return error.MissingInteractionOutcome;
    switch (actual) {
        .rejected => |rejected| {
            try std.testing.expectEqual(command, rejected.command);
            try std.testing.expectEqual(reason, rejected.reason);
        },
        else => return error.ExpectedInteractionRejection,
    }
}

fn runCommand(world: *TestWorld, command: Command) !Outcome {
    try world.feature.enqueue(command);
    try world.runtime.tick();
    return world.feature.pollOutcome() orelse error.MissingInteractionOutcome;
}

test "interaction configuration records and declared budgets are bounded" {
    try (Config{}).validate();
    try InteractionConfigV1.fromConfig(.{}).validate();
    try std.testing.expectError(
        error.InvalidCollectRange,
        (Config{ .collect_range = 0 }).validate(),
    );
    try std.testing.expectError(
        error.InvalidDropOffset,
        (Config{ .drop_offset = .{ 0, std.math.nan(f32), 0 } }).validate(),
    );
    try std.testing.expectEqual(@as(u32, 1), declared_budget.carryables);
    try std.testing.expectEqual(@as(u32, 1), declared_budget.dynamic_bodies);
    try std.testing.expectEqual(@as(u32, 16), declared_budget.commands);
    try std.testing.expectEqual(@as(u32, 16), declared_budget.outcomes);

    const valid = [_]InteractionV1{.{
        .id = .{ .namespace = test_namespace, .local = 1 },
        .half_extents = .{ 0.25, 0.25, 0.25 },
        .ownership = .{ .spatially_owned = .{ .x = 0, .z = 0 } },
        .pose = .{},
        .linear_velocity = .{ 0, 0, 0 },
        .angular_velocity = .{ 0, 0, 0 },
    }};
    try validateRecords(&valid);
    const too_many = [_]InteractionV1{ valid[0], valid[0] };
    try std.testing.expectError(error.TooManyCarryables, validateRecords(&too_many));
}

test "collect carry across half-open boundary and drop commits one identity" {
    var world: TestWorld = undefined;
    try world.init(.{});
    defer world.deinit();

    const id = try spawnTestCarryable(&world, .{ 7.5, 0.5, 0 });
    try std.testing.expectEqual(@as(usize, 1), world.bodies.live_count);
    world.carriers.state.pose.position = .{ 7.0, 0, 0 };
    try world.feature.enqueue(.{ .collect = .{
        .transaction_id = 20,
        .carrier_id = test_carrier_id,
        .carryable_id = id,
    } });
    try world.runtime.tick();
    const collected = world.feature.pollOutcome().?;
    try std.testing.expectEqual(@as(u64, 20), collected.collected.transaction_id);
    try std.testing.expectEqualDeep(
        district_contract.ChunkCoord{ .x = 0, .z = 0 },
        collected.collected.previous_owner,
    );
    try std.testing.expectEqual(@as(usize, 0), world.bodies.live_count);
    try std.testing.expectEqual(id, world.carriers.state.carry_mode.holding);
    try std.testing.expectEqual(@as(u32, 1), world.feature.diagnostics().held_count);
    try std.testing.expectEqual(@as(usize, 1), (try world.feature.extract()).len);

    // Exactly X=8 belongs to the east half-open cell. The default drop offset
    // changes Z only, so this also exercises canonical boundary ownership.
    world.carriers.state.pose.position = .{ 8.0, 0, 0 };
    try world.feature.enqueue(.{ .drop = .{
        .transaction_id = 21,
        .carrier_id = test_carrier_id,
        .carryable_id = id,
        .purpose = .player_requested,
    } });
    try world.runtime.tick();
    const dropped = world.feature.pollOutcome().?;
    try std.testing.expectEqual(@as(u64, 21), dropped.dropped.transaction_id);
    try std.testing.expectEqualDeep(
        district_contract.ChunkCoord{ .x = 1, .z = 0 },
        dropped.dropped.owner,
    );
    try std.testing.expectEqual(
        DropPlacement.configured_offset,
        dropped.dropped.placement,
    );
    try std.testing.expectEqual(@as(usize, 1), world.bodies.live_count);
    try std.testing.expectEqual(interaction_contract.CarryMode.empty, world.carriers.state.carry_mode);
    const view_value = try world.feature.view(id);
    try std.testing.expectEqualDeep(
        Ownership{ .spatially_owned = .{ .x = 1, .z = 0 } },
        view_value.ownership,
    );
    try std.testing.expect(view_value.body_present);
    try std.testing.expectEqual(@as(usize, 1), world.runtime.persistentCount());
}

test "held presentation and drop offsets follow semantic carrier facing" {
    var world: TestWorld = undefined;
    try world.init(.{});
    defer world.deinit();

    const id = try spawnTestCarryable(&world, .{ 0, 0.5, 0 });
    const carrier_rotation = try engine.transform.rotationFromFacingYaw(
        std.math.pi / 2.0,
    );
    world.carriers.state.pose = .{
        .position = .{ 0, 0, 0 },
        .rotation = carrier_rotation,
    };
    _ = try runCommand(&world, .{ .collect = .{
        .transaction_id = 30,
        .carrier_id = test_carrier_id,
        .carryable_id = id,
    } });

    const held = try world.feature.extract();
    try std.testing.expectEqual(@as(usize, 1), held.len);
    const expected_held_position = [3]f32{ 0.6, 1, 0 };
    for (held[0].pose.position, expected_held_position) |actual, expected| {
        try std.testing.expectApproxEqAbs(expected, actual, 0.0001);
    }
    for (held[0].pose.rotation, carrier_rotation) |actual, expected| {
        try std.testing.expectApproxEqAbs(expected, actual, 0.0001);
    }

    _ = try runCommand(&world, .{ .drop = .{
        .transaction_id = 31,
        .carrier_id = test_carrier_id,
        .carryable_id = id,
        .purpose = .player_requested,
    } });
    const dropped = try world.feature.view(id);
    const expected_drop_position = [3]f32{ 1.5, 0.75, 0 };
    for (dropped.state.pose.position, expected_drop_position) |actual, expected| {
        try std.testing.expectApproxEqAbs(expected, actual, 0.0001);
    }
    for (dropped.state.pose.rotation, carrier_rotation) |actual, expected| {
        try std.testing.expectApproxEqAbs(expected, actual, 0.0001);
    }

    _ = try runCommand(&world, .{ .despawn = .{ .id = id } });
}

test "drop remains beside a carrier when configured offset crosses a spatial boundary" {
    var world: TestWorld = undefined;
    try world.init(.{});
    defer world.deinit();

    const id = try spawnTestCarryable(&world, .{ 0, 0.5, 0 });
    _ = try runCommand(&world, .{ .collect = .{
        .transaction_id = 40,
        .carrier_id = test_carrier_id,
        .carryable_id = id,
    } });
    world.carriers.state.pose.position = .{ 0, 0, -7.75 };
    const outcome = try runCommand(&world, .{ .drop = .{
        .transaction_id = 41,
        .carrier_id = test_carrier_id,
        .carryable_id = id,
        .purpose = .player_requested,
    } });
    try std.testing.expectEqual(
        DropPlacement.configured_offset,
        outcome.dropped.placement,
    );
    try std.testing.expectEqualDeep(
        district_contract.ChunkCoord{ .x = 0, .z = -1 },
        outcome.dropped.owner,
    );
    try std.testing.expect(outcome.dropped.pose.position[2] < -8.0);
    try std.testing.expectEqual(interaction_contract.CarryMode.empty, world.carriers.state.carry_mode);
    try std.testing.expectEqual(@as(usize, 1), world.bodies.live_count);
}

test "drop outside authored districts preserves the item beside its carrier" {
    var world: TestWorld = undefined;
    try world.init(.{});
    defer world.deinit();

    const id = try spawnTestCarryable(&world, .{ 0, 0.5, 0 });
    _ = try runCommand(&world, .{ .collect = .{
        .transaction_id = 50,
        .carrier_id = test_carrier_id,
        .carryable_id = id,
    } });
    world.carriers.state.pose.position = .{ 40, 0, 40 };
    const outcome = try runCommand(&world, .{ .drop = .{
        .transaction_id = 51,
        .carrier_id = test_carrier_id,
        .carryable_id = id,
        .purpose = .player_requested,
    } });
    try std.testing.expectEqual(
        DropPlacement.configured_offset,
        outcome.dropped.placement,
    );
    try std.testing.expectEqualDeep(
        district_contract.ChunkCoord{ .x = 3, .z = 2 },
        outcome.dropped.owner,
    );
    try std.testing.expectEqualDeep([3]f32{ 40, 0.75, 38.5 }, outcome.dropped.pose.position);
    try std.testing.expectEqual(interaction_contract.CarryMode.empty, world.carriers.state.carry_mode);
    try std.testing.expectEqual(@as(usize, 1), world.bodies.live_count);
}

test "expected stale range holder and capacity failures are typed" {
    var world: TestWorld = undefined;
    try world.init(.{});
    defer world.deinit();

    const id = try spawnTestCarryable(&world, .{ 0, 0.5, 0 });
    try expectRejection(
        try runCommand(&world, .{ .spawn = .{
            .request_id = 2,
            .pose = .{ .position = .{ 1, 1, 0 } },
        } }),
        .spawn,
        .capacity_reached,
    );

    try expectRejection(
        try runCommand(&world, .{ .collect = .{
            .transaction_id = 3,
            .carrier_id = test_carrier_id,
            .carryable_id = .{ .namespace = test_namespace, .local = 700 },
        } }),
        .collect,
        .carryable_not_found,
    );
    try expectRejection(
        try runCommand(&world, .{ .collect = .{
            .transaction_id = 4,
            .carrier_id = other_carrier_id,
            .carryable_id = id,
        } }),
        .collect,
        .carrier_not_found,
    );

    world.carriers.state.pose.position = .{ 20, 0, 0 };
    try expectRejection(
        try runCommand(&world, .{ .collect = .{
            .transaction_id = 5,
            .carrier_id = test_carrier_id,
            .carryable_id = id,
        } }),
        .collect,
        .too_far,
    );
    world.carriers.state.pose.position = .{ 0, 0, 0 };
    world.carriers.state.mobility = .driving;
    try expectRejection(
        try runCommand(&world, .{ .collect = .{
            .transaction_id = 6,
            .carrier_id = test_carrier_id,
            .carryable_id = id,
        } }),
        .collect,
        .carrier_not_on_foot,
    );
    world.carriers.state.mobility = .on_foot;
    world.carriers.state.carry_mode = .{ .holding = .{
        .namespace = test_namespace,
        .local = 800,
    } };
    try expectRejection(
        try runCommand(&world, .{ .collect = .{
            .transaction_id = 7,
            .carrier_id = test_carrier_id,
            .carryable_id = id,
        } }),
        .collect,
        .carrier_not_empty,
    );
    world.carriers.state.carry_mode = .empty;

    _ = try runCommand(&world, .{ .collect = .{
        .transaction_id = 9,
        .carrier_id = test_carrier_id,
        .carryable_id = id,
    } });
    try expectRejection(
        try runCommand(&world, .{ .collect = .{
            .transaction_id = 10,
            .carrier_id = test_carrier_id,
            .carryable_id = id,
        } }),
        .collect,
        .carryable_already_held,
    );
    try expectRejection(
        try runCommand(&world, .{ .despawn = .{ .id = id } }),
        .despawn,
        .carryable_held,
    );
    try expectRejection(
        try runCommand(&world, .{ .drop = .{
            .transaction_id = 11,
            .carrier_id = other_carrier_id,
            .carryable_id = id,
            .purpose = .player_requested,
        } }),
        .drop,
        .wrong_holder,
    );

    world.carriers.state.carry_mode = .empty;
    try expectRejection(
        try runCommand(&world, .{ .drop = .{
            .transaction_id = 12,
            .carrier_id = test_carrier_id,
            .carryable_id = id,
            .purpose = .player_requested,
        } }),
        .drop,
        .carrier_not_holding,
    );
    world.carriers.state.carry_mode = .{ .holding = id };
    world.carriers.state.pose.position = .{ 8, 0, 0 };
    _ = try runCommand(&world, .{ .drop = .{
        .transaction_id = 13,
        .carrier_id = test_carrier_id,
        .carryable_id = id,
        .purpose = .player_requested,
    } });
    try expectRejection(
        try runCommand(&world, .{ .drop = .{
            .transaction_id = 14,
            .carrier_id = test_carrier_id,
            .carryable_id = id,
            .purpose = .player_requested,
        } }),
        .drop,
        .carrier_not_holding,
    );

    const despawned = try runCommand(&world, .{ .despawn = .{ .id = id } });
    try std.testing.expectEqual(id, despawned.despawned);
    try std.testing.expectEqual(@as(usize, 0), world.bodies.live_count);
    try std.testing.expectEqual(@as(usize, 0), world.runtime.persistentCount());
}

test "collect carrier and body failures preserve the exact world state" {
    {
        var world: TestWorld = undefined;
        try world.init(.{});
        defer world.deinit();
        const id = try spawnTestCarryable(&world, .{ 0, 0.5, 0 });
        world.carriers.fail_next_begin = true;
        try world.feature.enqueue(.{ .collect = .{
            .transaction_id = 30,
            .carrier_id = test_carrier_id,
            .carryable_id = id,
        } });
        try std.testing.expectError(
            error.InjectedBeginCarryFailure,
            world.runtime.tick(),
        );
        try std.testing.expectEqual(
            interaction_contract.CarryMode.empty,
            world.carriers.state.carry_mode,
        );
        try std.testing.expectEqual(@as(u64, 0), world.carriers.cancellations);
        try std.testing.expectEqual(@as(usize, 1), world.bodies.live_count);
        const diagnostics = world.feature.diagnostics();
        try std.testing.expectEqual(@as(u32, 1), diagnostics.spatially_owned_count);
        try std.testing.expectEqual(@as(u32, 1), diagnostics.dynamic_body_count);
    }
    {
        var world: TestWorld = undefined;
        try world.init(.{});
        defer world.deinit();
        const id = try spawnTestCarryable(&world, .{ 0, 0.5, 0 });
        world.bodies.fail_next_destroy = true;
        try world.feature.enqueue(.{ .collect = .{
            .transaction_id = 31,
            .carrier_id = test_carrier_id,
            .carryable_id = id,
        } });
        try std.testing.expectError(
            error.InjectedBodyDestroyFailure,
            world.runtime.tick(),
        );
        try std.testing.expectEqual(
            interaction_contract.CarryMode.empty,
            world.carriers.state.carry_mode,
        );
        try std.testing.expectEqual(@as(u64, 1), world.carriers.cancellations);
        try std.testing.expectEqual(@as(usize, 1), world.bodies.live_count);
        const diagnostics = world.feature.diagnostics();
        try std.testing.expectEqual(@as(u32, 1), diagnostics.spatially_owned_count);
        try std.testing.expectEqual(@as(u32, 1), diagnostics.dynamic_body_count);
    }
}

test "drop candidate creation and carrier detach failures roll back" {
    {
        var world: TestWorld = undefined;
        try world.init(.{});
        defer world.deinit();
        const id = try spawnTestCarryable(&world, .{ 0, 0.5, 0 });
        _ = try runCommand(&world, .{ .collect = .{
            .transaction_id = 40,
            .carrier_id = test_carrier_id,
            .carryable_id = id,
        } });
        world.bodies.fail_next_create = true;
        try world.feature.enqueue(.{ .drop = .{
            .transaction_id = 41,
            .carrier_id = test_carrier_id,
            .carryable_id = id,
            .purpose = .player_requested,
        } });
        try std.testing.expectError(
            error.InjectedBodyCreateFailure,
            world.runtime.tick(),
        );
        try std.testing.expectEqual(@as(usize, 0), world.bodies.live_count);
        try std.testing.expectEqual(id, world.carriers.state.carry_mode.holding);
        try std.testing.expectEqual(@as(u32, 1), world.feature.diagnostics().held_count);
    }
    {
        var world: TestWorld = undefined;
        try world.init(.{});
        defer world.deinit();
        const id = try spawnTestCarryable(&world, .{ 0, 0.5, 0 });
        _ = try runCommand(&world, .{ .collect = .{
            .transaction_id = 42,
            .carrier_id = test_carrier_id,
            .carryable_id = id,
        } });
        const destroys_before = world.bodies.destroys;
        world.carriers.fail_next_end = true;
        try world.feature.enqueue(.{ .drop = .{
            .transaction_id = 43,
            .carrier_id = test_carrier_id,
            .carryable_id = id,
            .purpose = .player_requested,
        } });
        try std.testing.expectError(
            error.InjectedEndCarryFailure,
            world.runtime.tick(),
        );
        try std.testing.expectEqual(@as(usize, 0), world.bodies.live_count);
        try std.testing.expectEqual(destroys_before + 1, world.bodies.destroys);
        try std.testing.expectEqual(id, world.carriers.state.carry_mode.holding);
        const diagnostics = world.feature.diagnostics();
        try std.testing.expectEqual(@as(u32, 1), diagnostics.held_count);
        try std.testing.expectEqual(@as(u32, 0), diagnostics.dynamic_body_count);
    }
}

test "restore rebuilds spatial and held ownership exactly" {
    const district_record = InteractionV1{
        .id = .{ .namespace = test_namespace, .local = 50 },
        .half_extents = .{ 0.2, 0.3, 0.4 },
        .ownership = .{ .spatially_owned = .{ .x = 0, .z = 0 } },
        .pose = .{ .position = .{ 2, 1, 3 } },
        .linear_velocity = .{ 1, 0, 0 },
        .angular_velocity = .{ 0, 0.25, 0 },
    };
    {
        var world: TestWorld = undefined;
        try world.init(.{});
        defer world.deinit();
        try world.feature.restoreRecords(&.{district_record});
        try std.testing.expectEqual(@as(usize, 1), world.feature.count());
        try std.testing.expectEqual(@as(usize, 1), world.bodies.live_count);
        const view_value = try world.feature.view(district_record.id);
        try std.testing.expect(view_value.body_present);
        try std.testing.expectEqualDeep(district_record.ownership, view_value.ownership);
        const records = try world.feature.snapshotRecords(std.testing.allocator);
        defer std.testing.allocator.free(records);
        try std.testing.expectEqual(@as(usize, 1), records.len);
        try std.testing.expectEqualDeep(district_record, records[0]);
    }
    {
        var world: TestWorld = undefined;
        try world.init(.{});
        defer world.deinit();
        const held_record = InteractionV1{
            .id = .{ .namespace = test_namespace, .local = 51 },
            .half_extents = .{ 0.2, 0.3, 0.4 },
            .ownership = .{ .inventory_held = test_carrier_id },
            .pose = .{ .position = .{ 2, 1, 3 } },
            .linear_velocity = .{ 1, 0, 0 },
            .angular_velocity = .{ 0, 0.25, 0 },
        };
        try world.feature.restoreRecords(&.{held_record});
        try std.testing.expectEqual(@as(usize, 0), world.bodies.live_count);
        try std.testing.expectEqual(held_record.id, world.carriers.state.carry_mode.holding);
        try std.testing.expectEqual(@as(usize, 1), (try world.feature.extract()).len);
        const records = try world.feature.snapshotRecords(std.testing.allocator);
        defer std.testing.allocator.free(records);
        try std.testing.expectEqualDeep(held_record, records[0]);
    }
}

test "restore relationship and body failures leave no candidate entity" {
    const held_record = InteractionV1{
        .id = .{ .namespace = test_namespace, .local = 60 },
        .half_extents = .{ 0.25, 0.25, 0.25 },
        .ownership = .{ .inventory_held = test_carrier_id },
        .pose = .{},
        .linear_velocity = .{ 0, 0, 0 },
        .angular_velocity = .{ 0, 0, 0 },
    };
    {
        var world: TestWorld = undefined;
        try world.init(.{});
        defer world.deinit();
        world.carriers.fail_next_begin = true;
        try std.testing.expectError(
            error.InjectedBeginCarryFailure,
            world.feature.restoreRecords(&.{held_record}),
        );
        try std.testing.expectEqual(@as(usize, 0), world.feature.count());
        try std.testing.expectEqual(@as(usize, 0), world.runtime.persistentCount());
        try std.testing.expectEqual(
            interaction_contract.CarryMode.empty,
            world.carriers.state.carry_mode,
        );
    }
    {
        var world: TestWorld = undefined;
        try world.init(.{});
        defer world.deinit();
        world.bodies.fail_next_create = true;
        var district_record = held_record;
        district_record.ownership = .{ .spatially_owned = .{ .x = 0, .z = 0 } };
        try std.testing.expectError(
            error.InjectedBodyCreateFailure,
            world.feature.restoreRecords(&.{district_record}),
        );
        try std.testing.expectEqual(@as(usize, 0), world.feature.count());
        try std.testing.expectEqual(@as(usize, 0), world.runtime.persistentCount());
        try std.testing.expectEqual(@as(usize, 0), world.bodies.live_count);
    }
}

fn logicalDigestFor(record: InteractionV1) !engine.contracts.replay.Digest {
    var world: TestWorld = undefined;
    try world.init(.{});
    defer world.deinit();
    try world.feature.restoreRecords(&.{record});
    var writer = engine.contracts.replay.Writer.init();
    try world.feature.writeLogicalState(&writer);
    return writer.final();
}

test "logical state canonicalizes pose aliases and covers ownership" {
    const positive = InteractionV1{
        .id = .{ .namespace = test_namespace, .local = 70 },
        .half_extents = .{ 0.25, 0.25, 0.25 },
        .ownership = .{ .spatially_owned = .{ .x = 0, .z = 0 } },
        .pose = .{
            .position = .{ 0, 1, 2 },
            .rotation = .{ 0, 0, 0, 1 },
        },
        .linear_velocity = .{ 0, 0, 0 },
        .angular_velocity = .{ 0, 0, 0 },
    };
    var alias = positive;
    alias.pose.position[0] = @bitCast(@as(u32, 0x8000_0000));
    alias.pose.rotation = .{ 0, 0, 0, -2 };
    try std.testing.expectEqual(
        try logicalDigestFor(positive),
        try logicalDigestFor(alias),
    );

    var different_owner = positive;
    different_owner.ownership = .{ .spatially_owned = .{ .x = 1, .z = 0 } };
    try std.testing.expect(!std.mem.eql(
        u8,
        &(try logicalDigestFor(positive)),
        &(try logicalDigestFor(different_owner)),
    ));
}

test "fixed command and outcome budgets saturate visibly without mutation loss" {
    var world: TestWorld = undefined;
    try world.init(.{});
    defer world.deinit();

    for (0..max_pending_commands) |index| {
        try world.feature.enqueue(.{ .spawn = .{
            .request_id = @intCast(index + 1),
            .pose = .{ .position = .{ 0, 1, 0 } },
        } });
    }
    try std.testing.expectError(
        error.InteractionCommandQueueFull,
        world.feature.enqueue(.{ .spawn = .{
            .request_id = 99,
            .pose = .{ .position = .{ 0, 1, 0 } },
        } }),
    );
    var diagnostics = world.feature.diagnostics();
    try std.testing.expectEqual(@as(u32, max_pending_commands), diagnostics.commands.occupancy);
    try std.testing.expectEqual(@as(u32, max_pending_commands), diagnostics.commands.high_water);
    try std.testing.expectEqual(@as(u64, 1), diagnostics.commands.rejected);

    try world.runtime.tick();
    diagnostics = world.feature.diagnostics();
    try std.testing.expectEqual(@as(u32, max_outcomes), diagnostics.outcomes.occupancy);
    try std.testing.expectEqual(@as(u32, max_outcomes), diagnostics.outcomes.high_water);
    try std.testing.expectError(
        error.InteractionCommandQueueFull,
        world.feature.enqueue(.{ .despawn = .{
            .id = .{ .namespace = test_namespace, .local = 1 },
        } }),
    );

    var spawned_count: usize = 0;
    var rejected_count: usize = 0;
    while (world.feature.pollOutcome()) |outcome| switch (outcome) {
        .spawned => spawned_count += 1,
        .rejected => |rejected| {
            try std.testing.expectEqual(RejectionReason.capacity_reached, rejected.reason);
            rejected_count += 1;
        },
        else => return error.UnexpectedInteractionOutcome,
    };
    try std.testing.expectEqual(@as(usize, 1), spawned_count);
    try std.testing.expectEqual(max_pending_commands - 1, rejected_count);
    try std.testing.expectEqual(@as(u32, 0), world.feature.diagnostics().outcomes.occupancy);
}

test "repeated collect boundary drop cycles return queues bodies and entity to baseline" {
    var world: TestWorld = undefined;
    try world.init(.{});
    defer world.deinit();
    const id = try spawnTestCarryable(&world, .{ 0, 0.5, 0 });

    var carrier_x: f32 = 0;
    for (0..8) |cycle| {
        world.carriers.state.pose.position = .{ carrier_x, 0, 0 };
        const collected = try runCommand(&world, .{ .collect = .{
            .transaction_id = 100 + cycle * 2,
            .carrier_id = test_carrier_id,
            .carryable_id = id,
        } });
        try std.testing.expectEqual(id, collected.collected.carryable_id);
        try std.testing.expectEqual(@as(usize, 0), world.bodies.live_count);

        carrier_x = if (carrier_x == 0) 8 else 0;
        world.carriers.state.pose.position = .{ carrier_x, 0, 0 };
        const dropped = try runCommand(&world, .{ .drop = .{
            .transaction_id = 101 + cycle * 2,
            .carrier_id = test_carrier_id,
            .carryable_id = id,
            .purpose = .player_requested,
        } });
        try std.testing.expectEqual(id, dropped.dropped.carryable_id);
        try std.testing.expectEqual(@as(usize, 1), world.bodies.live_count);
        try std.testing.expectEqual(
            interaction_contract.CarryMode.empty,
            world.carriers.state.carry_mode,
        );
    }

    _ = try runCommand(&world, .{ .despawn = .{ .id = id } });
    const diagnostics = world.feature.diagnostics();
    try std.testing.expectEqual(@as(u32, 0), diagnostics.active_count);
    try std.testing.expectEqual(@as(u32, 0), diagnostics.dynamic_body_count);
    try std.testing.expectEqual(@as(u32, 0), diagnostics.commands.occupancy);
    try std.testing.expectEqual(@as(u32, 0), diagnostics.outcomes.occupancy);
    try std.testing.expectEqual(@as(usize, 0), world.bodies.live_count);
    try std.testing.expectEqual(@as(usize, 0), world.runtime.persistentCount());
}
