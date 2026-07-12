//! CharacterFeature: player locomotion as an end-to-end vertical slice.

const std = @import("std");
const engine = @import("incinerator_engine");
const driver_contract = @import("driver_contract");

pub const Assets = struct {
    mesh: engine.rendering.MeshHandle = .invalid,
    material: engine.rendering.MaterialHandle = .invalid,
};

pub const Config = struct {
    radius: f32 = 0.4,
    half_height: f32 = 0.5,
    move_speed: f32 = 6.0,
    jump_speed: f32 = 6.0,
    gravity: f32 = -20.0,
    terminal_fall_speed: f32 = 55.0,
    max_slope_radians: f32 = std.math.degreesToRadians(50.0),
    mass: f32 = 70.0,
    max_strength: f32 = 100.0,
    stick_to_floor_distance: f32 = 0.5,
    step_up_height: f32 = 0.4,
    max_characters: usize = 1,
    assets: Assets = .{},

    pub fn validate(self: Config) !void {
        if (self.max_characters == 0) return error.InvalidCharacterLimit;
        try (engine.physics.CharacterDesc{
            .position = .{ 0, 0, 0 },
            .radius = self.radius,
            .half_height = self.half_height,
            .max_slope_radians = self.max_slope_radians,
            .mass = self.mass,
            .max_strength = self.max_strength,
        }).validate();
        for ([_]f32{
            self.move_speed,
            self.jump_speed,
            self.terminal_fall_speed,
            self.stick_to_floor_distance,
            self.step_up_height,
        }) |value| {
            if (!std.math.isFinite(value) or value < 0) {
                return error.InvalidCharacterConfiguration;
            }
        }
        if (!std.math.isFinite(self.gravity) or self.gravity >= 0) {
            return error.InvalidCharacterGravity;
        }
        if (self.terminal_fall_speed == 0) return error.InvalidTerminalFallSpeed;
        if (!combinedCharacterSpeedFits(self.move_speed, self.jump_speed) or
            !combinedCharacterSpeedFits(self.move_speed, self.terminal_fall_speed))
        {
            return error.CharacterSpeedOutOfRange;
        }
    }
};

/// Feature-owned, simulation-relevant character tuning. Presentation handles
/// and host capacity are deliberately excluded.
pub const CharacterConfigV1 = struct {
    radius: f32,
    half_height: f32,
    move_speed: f32,
    jump_speed: f32,
    gravity: f32,
    terminal_fall_speed: f32,
    max_slope_radians: f32,
    mass: f32,
    max_strength: f32,
    stick_to_floor_distance: f32,
    step_up_height: f32,

    pub fn fromConfig(config: Config) CharacterConfigV1 {
        return .{
            .radius = config.radius,
            .half_height = config.half_height,
            .move_speed = config.move_speed,
            .jump_speed = config.jump_speed,
            .gravity = config.gravity,
            .terminal_fall_speed = config.terminal_fall_speed,
            .max_slope_radians = config.max_slope_radians,
            .mass = config.mass,
            .max_strength = config.max_strength,
            .stick_to_floor_distance = config.stick_to_floor_distance,
            .step_up_height = config.step_up_height,
        };
    }

    pub fn toConfig(
        self: CharacterConfigV1,
        max_characters: usize,
        assets: Assets,
    ) !Config {
        const config = Config{
            .radius = self.radius,
            .half_height = self.half_height,
            .move_speed = self.move_speed,
            .jump_speed = self.jump_speed,
            .gravity = self.gravity,
            .terminal_fall_speed = self.terminal_fall_speed,
            .max_slope_radians = self.max_slope_radians,
            .mass = self.mass,
            .max_strength = self.max_strength,
            .stick_to_floor_distance = self.stick_to_floor_distance,
            .step_up_height = self.step_up_height,
            .max_characters = max_characters,
            .assets = assets,
        };
        try config.validate();
        return config;
    }

    pub fn validate(self: CharacterConfigV1) !void {
        _ = try self.toConfig(1, .{});
    }
};

pub const SpawnCharacter = struct {
    request_id: u64,
    position: [3]f32,
    velocity: [3]f32 = .{ 0, 0, 0 },
    facing_yaw: f32 = 0,
};

/// High-level action state for one simulation tick. No SDL key or mouse code
/// crosses this feature boundary.
pub const ApplyActions = struct {
    id: engine.PersistentId,
    move: [2]f32 = .{ 0, 0 },
    facing_yaw: f32,
    jump_pressed: bool = false,
};

pub const DespawnCharacter = struct { id: engine.PersistentId };

pub const Command = union(enum) {
    spawn: SpawnCharacter,
    actions: ApplyActions,
    despawn: DespawnCharacter,
};

pub const Spawned = struct {
    request_id: u64,
    id: engine.PersistentId,
};

pub const GroundStateChanged = struct {
    id: engine.PersistentId,
    previous: engine.physics.GroundState,
    current: engine.physics.GroundState,
};

pub const CommandKind = enum { spawn, actions, despawn };
pub const RejectionReason = enum {
    capacity_reached,
    character_not_found,
    not_owned,
    driving,
};
pub const CommandRejected = struct {
    command: CommandKind,
    reason: RejectionReason,
    request_id: ?u64 = null,
    id: ?engine.PersistentId = null,
};

pub const Outcome = union(enum) {
    spawned: Spawned,
    despawned: engine.PersistentId,
    rejected: CommandRejected,
};

pub const Event = union(enum) {
    ground_state_changed: GroundStateChanged,
};

pub const CharacterView = struct {
    id: engine.PersistentId,
    position: [3]f32,
    velocity: [3]f32,
    facing_yaw: f32,
    ground_state: engine.physics.GroundState,
    radius: f32,
    half_height: f32,
    driver_mode: driver_contract.DriverMode,
};

pub const CharacterDraw = struct {
    persistent_id: engine.PersistentId,
    pose: engine.physics.Pose,
    radius: f32,
    half_height: f32,
    camera_target: [3]f32,
    mesh: engine.rendering.MeshHandle,
    material: engine.rendering.MaterialHandle,
};

/// Feature-owned persistence payload. The composition root owns the enclosing
/// world schema, clock, identity cursor, and records from other features.
pub const CharacterV1 = struct {
    id: engine.PersistentId,
    position: [3]f32,
    velocity: [3]f32,
    facing_yaw: f32,
};

pub fn validateRecord(record: CharacterV1) !void {
    try record.id.validate();
    try validateFinite(record.position);
    try validateFinite(record.velocity);
    if (!std.math.isFinite(record.facing_yaw)) return error.InvalidFacingYaw;
    const pi: f32 = std.math.pi;
    if (record.facing_yaw < -pi or record.facing_yaw >= pi or
        @as(u32, @bitCast(record.facing_yaw)) == 0x8000_0000)
    {
        return error.NonCanonicalFacingYaw;
    }
    try (engine.physics.Velocity{ .linear = record.velocity }).validate();
}

pub fn Feature(comptime Controllers: type) type {
    engine.physics.assertCharacterImplementation(Controllers);

    return struct {
        const Self = @This();

        const Character = struct {
            radius: f32,
            half_height: f32,
        };
        const RuntimeController = struct { handle: Controllers.Handle };
        const DriveRollback = struct {
            move: [2]f32,
            jump_requested: bool,
        };
        const DriveState = struct {
            mode: driver_contract.DriverMode = .on_foot,
            rollback: ?DriveRollback = null,
        };
        const Locomotion = struct {
            move: [2]f32 = .{ 0, 0 },
            facing_yaw: f32 = 0,
            jump_requested: bool = false,
            velocity: [3]f32 = .{ 0, 0, 0 },
            ground_state: engine.physics.GroundState = .in_air,
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

        allocator: std.mem.Allocator,
        runtime: *engine.Runtime,
        controllers: *Controllers,
        config: Config,
        pending: std.ArrayListUnmanaged(QueuedCommand) = .empty,
        applying: std.ArrayListUnmanaged(QueuedCommand) = .empty,
        applying_index: usize = 0,
        active: std.ArrayListUnmanaged(engine.RuntimeId) = .empty,
        outcomes: std.ArrayListUnmanaged(Outcome) = .empty,
        outcomes_head: usize = 0,
        events: std.ArrayListUnmanaged(Event) = .empty,
        events_head: usize = 0,
        presentations: std.ArrayListUnmanaged(CharacterDraw) = .empty,

        /// Gameplay port consumed by VehicleFeature. It exposes no character
        /// ECS component, controller handle, or implementation type.
        pub const DriverAccess = struct {
            feature: *Self,

            pub fn driverState(
                self: *DriverAccess,
                id: engine.PersistentId,
            ) !?driver_contract.DriverState {
                return self.feature.driverStateNow(id);
            }

            pub fn beginDriving(
                self: *DriverAccess,
                character_id: engine.PersistentId,
                vehicle_id: engine.PersistentId,
            ) !void {
                try self.feature.beginDrivingNow(character_id, vehicle_id);
            }

            pub fn attemptEndDriving(
                self: *DriverAccess,
                character_id: engine.PersistentId,
                vehicle_id: engine.PersistentId,
                exit_pose: engine.physics.Pose,
            ) !driver_contract.ExitDisposition {
                return self.feature.attemptEndDrivingNow(
                    character_id,
                    vehicle_id,
                    exit_pose,
                );
            }

            pub fn cancelDriving(
                self: *DriverAccess,
                character_id: engine.PersistentId,
                vehicle_id: engine.PersistentId,
            ) void {
                self.feature.cancelDrivingNow(character_id, vehicle_id);
            }
        };

        pub fn init(
            allocator: std.mem.Allocator,
            runtime: *engine.Runtime,
            controllers: *Controllers,
            config: Config,
        ) !Self {
            try config.validate();
            return .{
                .allocator = allocator,
                .runtime = runtime,
                .controllers = controllers,
                .config = config,
            };
        }

        pub fn register(self: *Self, registry: *engine.FeatureRegistry) !void {
            try registry.registerComponent(Character);
            try registry.registerComponent(RuntimeController);
            try registry.registerComponent(DriveState);
            try registry.registerComponent(Locomotion);
            try registry.registerComponent(TransformHistory);
            try registry.addSystem(
                .commands,
                "character.apply_commands",
                self,
                applyCommandsSystem,
            );
            try registry.addSystem(
                .pre_physics,
                "character.update_controller",
                self,
                updateControllerSystem,
            );
            try registry.addSystem(
                .post_physics,
                "character.publish_controller",
                self,
                publishControllerSystem,
            );
        }

        pub fn driverAccess(self: *Self) DriverAccess {
            return .{ .feature = self };
        }

        pub fn deinit(self: *Self) void {
            while (self.active.items.len > 0) {
                const runtime_id = self.active.items[self.active.items.len - 1];
                if (self.runtime.get(runtime_id, RuntimeController)) |controller| {
                    self.destroyControllerOrPanic(controller.handle);
                }
                self.destroyRuntimeOrPanic(runtime_id);
                _ = self.active.pop();
            }
            self.pending.deinit(self.allocator);
            self.applying.deinit(self.allocator);
            self.active.deinit(self.allocator);
            self.outcomes.deinit(self.allocator);
            self.events.deinit(self.allocator);
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
            if (self.outcomes_head >= self.outcomes.items.len) {
                self.outcomes.clearRetainingCapacity();
                self.outcomes_head = 0;
                return null;
            }
            const outcome = self.outcomes.items[self.outcomes_head];
            self.outcomes_head += 1;
            if (self.outcomes_head == self.outcomes.items.len) {
                self.outcomes.clearRetainingCapacity();
                self.outcomes_head = 0;
            } else if (self.outcomes_head >= 64 and
                self.outcomes_head >= self.outcomes.items.len - self.outcomes_head)
            {
                const remaining = self.outcomes.items.len - self.outcomes_head;
                std.mem.copyForwards(
                    Outcome,
                    self.outcomes.items[0..remaining],
                    self.outcomes.items[self.outcomes_head..],
                );
                self.outcomes.items.len = remaining;
                self.outcomes_head = 0;
            }
            return outcome;
        }

        pub fn pollEvent(self: *Self) ?Event {
            if (self.events_head >= self.events.items.len) {
                self.events.clearRetainingCapacity();
                self.events_head = 0;
                return null;
            }
            const event = self.events.items[self.events_head];
            self.events_head += 1;
            if (self.events_head == self.events.items.len) {
                self.events.clearRetainingCapacity();
                self.events_head = 0;
            } else if (self.events_head >= 64 and
                self.events_head >= self.events.items.len - self.events_head)
            {
                const remaining = self.events.items.len - self.events_head;
                std.mem.copyForwards(
                    Event,
                    self.events.items[0..remaining],
                    self.events.items[self.events_head..],
                );
                self.events.items.len = remaining;
                self.events_head = 0;
            }
            return event;
        }

        pub fn count(self: *const Self) usize {
            return self.active.items.len;
        }

        pub fn hasPendingCommands(self: *const Self) bool {
            return self.pending.items.len != 0 or
                self.applying_index < self.applying.items.len;
        }

        pub fn view(self: *Self, id: engine.PersistentId) !CharacterView {
            const runtime_id = self.runtime.resolve(id) orelse
                return error.CharacterNotFound;
            const character = self.runtime.get(runtime_id, Character) orelse
                return error.NotACharacter;
            const locomotion = self.runtime.get(runtime_id, Locomotion) orelse
                return error.CharacterLocomotionInvariantBroken;
            const controller = self.runtime.get(runtime_id, RuntimeController) orelse
                return error.CharacterControllerInvariantBroken;
            const drive = self.runtime.get(runtime_id, DriveState) orelse
                return error.CharacterDriveStateInvariantBroken;
            const state = try self.controllers.characterState(controller.handle);
            return .{
                .id = id,
                .position = state.position,
                .velocity = state.velocity,
                .facing_yaw = locomotion.facing_yaw,
                .ground_state = state.ground_state,
                .radius = character.radius,
                .half_height = character.half_height,
                .driver_mode = drive.mode,
            };
        }

        pub fn extract(self: *Self, alpha: f32) ![]const CharacterDraw {
            if (!std.math.isFinite(alpha)) return error.InvalidInterpolationAlpha;
            self.presentations.clearRetainingCapacity();
            try self.presentations.ensureTotalCapacity(self.allocator, self.active.items.len);
            for (self.active.items) |runtime_id| {
                const drive = self.runtime.get(runtime_id, DriveState) orelse
                    return error.CharacterDriveStateInvariantBroken;
                switch (drive.mode) {
                    .on_foot => {},
                    .driving => continue,
                }
                const character = self.runtime.get(runtime_id, Character) orelse
                    return error.NotACharacter;
                const history = self.runtime.get(runtime_id, TransformHistory) orelse
                    return error.CharacterTransformInvariantBroken;
                if (history.current_tick != self.runtime.tickIndex()) {
                    return error.CharacterTransformTickInvariantBroken;
                }
                const pose = try engine.transform.interpolate(
                    history.previous,
                    history.current,
                    alpha,
                );
                self.presentations.appendAssumeCapacity(.{
                    .persistent_id = try self.runtime.identity(runtime_id),
                    .pose = pose,
                    .radius = character.radius,
                    .half_height = character.half_height,
                    .camera_target = .{
                        pose.position[0],
                        pose.position[1] + character.radius + character.half_height,
                        pose.position[2],
                    },
                    .mesh = self.config.assets.mesh,
                    .material = self.config.assets.material,
                });
            }
            return self.presentations.items;
        }

        pub fn snapshotRecords(
            self: *Self,
            allocator: std.mem.Allocator,
        ) ![]CharacterV1 {
            try self.runtime.ensureSnapshotBoundary();
            if (self.pending.items.len != 0 or
                self.applying_index < self.applying.items.len)
            {
                return error.CommandsPending;
            }
            const records = try allocator.alloc(CharacterV1, self.active.items.len);
            errdefer allocator.free(records);
            for (self.active.items, 0..) |runtime_id, index| {
                _ = self.runtime.get(runtime_id, DriveState) orelse
                    return error.CharacterDriveStateInvariantBroken;
                const locomotion = self.runtime.get(runtime_id, Locomotion) orelse
                    return error.CharacterLocomotionInvariantBroken;
                const controller = self.runtime.get(runtime_id, RuntimeController) orelse
                    return error.CharacterControllerInvariantBroken;
                const state = try self.controllers.characterState(controller.handle);
                const record = CharacterV1{
                    .id = try self.runtime.identity(runtime_id),
                    .position = state.position,
                    .velocity = state.velocity,
                    .facing_yaw = locomotion.facing_yaw,
                };
                try validateRecord(record);
                records[index] = record;
            }
            std.mem.sort(CharacterV1, records, {}, lessThanRecord);
            return records;
        }

        pub fn restoreRecords(self: *Self, records: []const CharacterV1) !void {
            if (self.active.items.len != 0 or
                self.pending.items.len != 0 or
                self.applying_index < self.applying.items.len)
            {
                return error.RestoreRequiresEmptyFeature;
            }
            if (records.len > self.config.max_characters) {
                return error.TooManyCharacters;
            }
            for (records, 0..) |record, index| {
                try validateRecord(record);
                for (records[0..index]) |earlier| {
                    if (std.meta.eql(earlier.id, record.id)) {
                        return error.DuplicatePersistentId;
                    }
                }
            }
            errdefer self.rollbackAll();
            for (records) |record| {
                _ = try self.spawnNow(.{
                    .request_id = 0,
                    .position = record.position,
                    .velocity = record.velocity,
                    .facing_yaw = record.facing_yaw,
                }, record.id, false);
            }
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
                switch (queued.command) {
                    .spawn => |spawn| {
                        _ = self.spawnNow(spawn, null, true) catch |err| switch (err) {
                            error.TooManyCharacters => {
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
                    .actions => |actions| {
                        self.applyActionsNow(actions) catch |err| switch (err) {
                            error.CharacterNotFound => try self.reject(.{
                                .command = .actions,
                                .reason = .character_not_found,
                                .id = actions.id,
                            }),
                            error.NotACharacter => try self.reject(.{
                                .command = .actions,
                                .reason = .not_owned,
                                .id = actions.id,
                            }),
                            error.CharacterDriving => try self.reject(.{
                                .command = .actions,
                                .reason = .driving,
                                .id = actions.id,
                            }),
                            else => return err,
                        };
                    },
                    .despawn => |despawn| {
                        self.despawnNow(despawn.id, true) catch |err| switch (err) {
                            error.CharacterNotFound => try self.reject(.{
                                .command = .despawn,
                                .reason = .character_not_found,
                                .id = despawn.id,
                            }),
                            error.NotACharacter => try self.reject(.{
                                .command = .despawn,
                                .reason = .not_owned,
                                .id = despawn.id,
                            }),
                            error.CharacterDriving => try self.reject(.{
                                .command = .despawn,
                                .reason = .driving,
                                .id = despawn.id,
                            }),
                            else => return err,
                        };
                    },
                }
            }
            self.applying.clearRetainingCapacity();
            self.applying_index = 0;
        }

        fn updateControllerSystem(
            raw: *anyopaque,
            _: *engine.Runtime,
            tick: engine.TickContext,
        ) !void {
            const self: *Self = @ptrCast(@alignCast(raw));
            try self.events.ensureUnusedCapacity(self.allocator, self.active.items.len);
            for (self.active.items) |runtime_id| {
                const drive = self.runtime.get(runtime_id, DriveState) orelse
                    return error.CharacterDriveStateInvariantBroken;
                switch (drive.mode) {
                    .on_foot => {},
                    .driving => continue,
                }
                const id = try self.runtime.identity(runtime_id);
                const controller = self.runtime.get(runtime_id, RuntimeController) orelse
                    return error.CharacterControllerInvariantBroken;
                const locomotion = self.runtime.getMut(runtime_id, Locomotion) orelse
                    return error.CharacterLocomotionInvariantBroken;
                const before = try self.controllers.prepareCharacter(controller.handle);
                const velocity = calculateVelocity(self.config, locomotion.*, before, tick.delta_seconds);
                const after = try self.controllers.updateCharacter(
                    controller.handle,
                    .{
                        .velocity = velocity,
                        .stick_to_floor_distance = self.config.stick_to_floor_distance,
                        .step_up_height = self.config.step_up_height,
                    },
                    tick.delta_seconds,
                );
                locomotion.velocity = after.velocity;
                // Controls are tick-scoped. A producer must submit one sample
                // per tick; missing input is neutral instead of a stuck hold.
                locomotion.move = .{ 0, 0 };
                locomotion.jump_requested = false;
                if (locomotion.ground_state != after.ground_state) {
                    self.events.appendAssumeCapacity(.{ .ground_state_changed = .{
                        .id = id,
                        .previous = locomotion.ground_state,
                        .current = after.ground_state,
                    } });
                }
                locomotion.ground_state = after.ground_state;
            }
        }

        fn publishControllerSystem(
            raw: *anyopaque,
            _: *engine.Runtime,
            tick: engine.TickContext,
        ) !void {
            const self: *Self = @ptrCast(@alignCast(raw));
            for (self.active.items) |runtime_id| {
                const drive = self.runtime.get(runtime_id, DriveState) orelse
                    return error.CharacterDriveStateInvariantBroken;
                switch (drive.mode) {
                    .on_foot => {},
                    .driving => continue,
                }
                const controller = self.runtime.get(runtime_id, RuntimeController) orelse
                    return error.CharacterControllerInvariantBroken;
                const locomotion = self.runtime.get(runtime_id, Locomotion) orelse
                    return error.CharacterLocomotionInvariantBroken;
                const state = try self.controllers.characterState(controller.handle);
                const history = self.runtime.getMut(runtime_id, TransformHistory) orelse
                    return error.CharacterTransformInvariantBroken;
                history.previous = history.current;
                history.current = poseFor(state.position, locomotion.facing_yaw);
                history.current_tick = tick.tick_index;
            }
        }

        fn spawnNow(
            self: *Self,
            spawn: SpawnCharacter,
            restored_id: ?engine.PersistentId,
            emit_outcome: bool,
        ) !engine.PersistentId {
            try validateSpawn(spawn);
            if (self.active.items.len >= self.config.max_characters) {
                return error.TooManyCharacters;
            }
            try self.active.ensureUnusedCapacity(self.allocator, 1);
            if (emit_outcome) try self.outcomes.ensureUnusedCapacity(self.allocator, 1);

            const runtime_id = if (restored_id) |id|
                try self.runtime.createWithPersistentId(id)
            else
                try self.runtime.create();
            errdefer self.destroyRuntimeOrPanic(runtime_id);
            const id = try self.runtime.identity(runtime_id);
            const controller = try self.controllers.createCharacter(.{
                .position = spawn.position,
                .velocity = spawn.velocity,
                .radius = self.config.radius,
                .half_height = self.config.half_height,
                .max_slope_radians = self.config.max_slope_radians,
                .mass = self.config.mass,
                .max_strength = self.config.max_strength,
            });
            errdefer self.destroyControllerOrPanic(controller);
            const yaw = if (restored_id != null)
                spawn.facing_yaw
            else
                normalizeYaw(spawn.facing_yaw);
            const state = try self.controllers.characterState(controller);
            const pose = poseFor(state.position, yaw);
            try self.runtime.set(runtime_id, Character, .{
                .radius = self.config.radius,
                .half_height = self.config.half_height,
            });
            try self.runtime.set(runtime_id, RuntimeController, .{ .handle = controller });
            try self.runtime.set(runtime_id, DriveState, .{});
            try self.runtime.set(runtime_id, Locomotion, .{
                .facing_yaw = yaw,
                .velocity = state.velocity,
                .ground_state = state.ground_state,
            });
            try self.runtime.set(runtime_id, TransformHistory, .{
                .previous = pose,
                .current = pose,
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

        fn driverStateNow(
            self: *Self,
            id: engine.PersistentId,
        ) !?driver_contract.DriverState {
            try id.validate();
            const runtime_id = self.runtime.resolve(id) orelse return null;
            _ = self.runtime.get(runtime_id, Character) orelse return null;
            const drive = self.runtime.get(runtime_id, DriveState) orelse
                return error.CharacterDriveStateInvariantBroken;
            const locomotion = self.runtime.get(runtime_id, Locomotion) orelse
                return error.CharacterLocomotionInvariantBroken;
            const controller = self.runtime.get(runtime_id, RuntimeController) orelse
                return error.CharacterControllerInvariantBroken;
            const state = try self.controllers.characterState(controller.handle);
            const result = driver_contract.DriverState{
                .pose = poseFor(state.position, locomotion.facing_yaw),
                .mode = drive.mode,
            };
            try result.validate();
            return result;
        }

        fn beginDrivingNow(
            self: *Self,
            character_id: engine.PersistentId,
            vehicle_id: engine.PersistentId,
        ) !void {
            try character_id.validate();
            try vehicle_id.validate();
            const runtime_id = self.runtime.resolve(character_id) orelse
                return error.CharacterNotFound;
            _ = self.runtime.get(runtime_id, Character) orelse
                return error.NotACharacter;
            _ = self.runtime.get(runtime_id, RuntimeController) orelse
                return error.CharacterControllerInvariantBroken;
            _ = self.runtime.get(runtime_id, TransformHistory) orelse
                return error.CharacterTransformInvariantBroken;
            const locomotion = self.runtime.getMut(runtime_id, Locomotion) orelse
                return error.CharacterLocomotionInvariantBroken;
            const drive = self.runtime.getMut(runtime_id, DriveState) orelse
                return error.CharacterDriveStateInvariantBroken;
            switch (drive.mode) {
                .on_foot => {},
                .driving => return error.CharacterAlreadyDriving,
            }
            if (drive.rollback != null) {
                return error.CharacterDriveRollbackInvariantBroken;
            }

            drive.rollback = .{
                .move = locomotion.move,
                .jump_requested = locomotion.jump_requested,
            };
            locomotion.move = .{ 0, 0 };
            locomotion.jump_requested = false;
            drive.mode = .{ .driving = vehicle_id };
        }

        fn attemptEndDrivingNow(
            self: *Self,
            character_id: engine.PersistentId,
            vehicle_id: engine.PersistentId,
            exit_pose: engine.physics.Pose,
        ) !driver_contract.ExitDisposition {
            try character_id.validate();
            try vehicle_id.validate();
            const normalized_exit = try exit_pose.normalized();
            const facing_yaw = try yawFromRotation(normalized_exit.rotation);
            const runtime_id = self.runtime.resolve(character_id) orelse
                return error.CharacterNotFound;
            _ = self.runtime.get(runtime_id, Character) orelse
                return error.NotACharacter;
            const controller = self.runtime.get(runtime_id, RuntimeController) orelse
                return error.CharacterControllerInvariantBroken;
            const locomotion = self.runtime.getMut(runtime_id, Locomotion) orelse
                return error.CharacterLocomotionInvariantBroken;
            const history = self.runtime.getMut(runtime_id, TransformHistory) orelse
                return error.CharacterTransformInvariantBroken;
            const drive = self.runtime.getMut(runtime_id, DriveState) orelse
                return error.CharacterDriveStateInvariantBroken;
            switch (drive.mode) {
                .driving => |current| if (!std.meta.eql(current, vehicle_id)) {
                    return error.CharacterDrivingDifferentVehicle;
                },
                .on_foot => return error.CharacterNotDriving,
            }

            const relocated = (try self.controllers.tryRelocateCharacter(
                controller.handle,
                .{ .position = normalized_exit.position },
            )) orelse return .blocked;
            const character_pose = poseFor(relocated.position, facing_yaw);
            locomotion.move = .{ 0, 0 };
            locomotion.facing_yaw = facing_yaw;
            locomotion.jump_requested = false;
            locomotion.velocity = relocated.velocity;
            locomotion.ground_state = relocated.ground_state;
            history.previous = character_pose;
            history.current = character_pose;
            history.current_tick = self.runtime.tickIndex();
            drive.rollback = null;
            drive.mode = .on_foot;
            return .exited;
        }

        fn cancelDrivingNow(
            self: *Self,
            character_id: engine.PersistentId,
            vehicle_id: engine.PersistentId,
        ) void {
            const runtime_id = self.runtime.resolve(character_id) orelse
                @panic("restore rollback driver no longer exists");
            _ = self.runtime.get(runtime_id, Character) orelse
                @panic("restore rollback identity is not a character");
            const locomotion = self.runtime.getMut(runtime_id, Locomotion) orelse
                @panic("restore rollback character has no locomotion");
            const drive = self.runtime.getMut(runtime_id, DriveState) orelse
                @panic("restore rollback character has no drive state");
            switch (drive.mode) {
                .driving => |current| if (!std.meta.eql(current, vehicle_id)) {
                    @panic("restore rollback character drives a different vehicle");
                },
                .on_foot => @panic("restore rollback character is already on foot"),
            }
            const rollback = drive.rollback orelse
                @panic("restore rollback character has no saved driver state");
            locomotion.move = rollback.move;
            locomotion.jump_requested = rollback.jump_requested;
            drive.rollback = null;
            drive.mode = .on_foot;
        }

        fn applyActionsNow(self: *Self, actions: ApplyActions) !void {
            const runtime_id = self.runtime.resolve(actions.id) orelse
                return error.CharacterNotFound;
            _ = self.runtime.get(runtime_id, Character) orelse
                return error.NotACharacter;
            const drive = self.runtime.get(runtime_id, DriveState) orelse
                return error.CharacterDriveStateInvariantBroken;
            switch (drive.mode) {
                .on_foot => {},
                .driving => return error.CharacterDriving,
            }
            const locomotion = self.runtime.getMut(runtime_id, Locomotion) orelse
                return error.CharacterLocomotionInvariantBroken;
            locomotion.move = normalizeMove(actions.move);
            locomotion.facing_yaw = normalizeYaw(actions.facing_yaw);
            locomotion.jump_requested = locomotion.jump_requested or actions.jump_pressed;
        }

        fn despawnNow(self: *Self, id: engine.PersistentId, emit_outcome: bool) !void {
            const runtime_id = self.runtime.resolve(id) orelse
                return error.CharacterNotFound;
            _ = self.runtime.get(runtime_id, Character) orelse
                return error.NotACharacter;
            const drive = self.runtime.get(runtime_id, DriveState) orelse
                return error.CharacterDriveStateInvariantBroken;
            switch (drive.mode) {
                .on_foot => {},
                .driving => return error.CharacterDriving,
            }
            const controller = self.runtime.get(runtime_id, RuntimeController) orelse
                return error.CharacterControllerInvariantBroken;
            const index = self.activeIndex(runtime_id) orelse
                return error.CharacterActiveIndexInvariantBroken;
            if (emit_outcome) try self.outcomes.ensureUnusedCapacity(self.allocator, 1);
            try self.controllers.destroyCharacter(controller.handle);
            self.destroyRuntimeOrPanic(runtime_id);
            _ = self.active.orderedRemove(index);
            if (emit_outcome) self.outcomes.appendAssumeCapacity(.{ .despawned = id });
        }

        fn activeIndex(self: *const Self, runtime_id: engine.RuntimeId) ?usize {
            for (self.active.items, 0..) |candidate, index| {
                if (std.meta.eql(candidate, runtime_id)) return index;
            }
            return null;
        }

        fn reject(self: *Self, rejection: CommandRejected) !void {
            try self.outcomes.append(self.allocator, .{ .rejected = rejection });
        }

        fn rollbackAll(self: *Self) void {
            while (self.active.items.len > 0) {
                const runtime_id = self.active.items[self.active.items.len - 1];
                if (self.runtime.get(runtime_id, RuntimeController)) |controller| {
                    self.destroyControllerOrPanic(controller.handle);
                }
                self.destroyRuntimeOrPanic(runtime_id);
                _ = self.active.pop();
            }
        }

        fn destroyControllerOrPanic(self: *Self, handle: Controllers.Handle) void {
            self.controllers.destroyCharacter(handle) catch |err| {
                std.debug.panic(
                    "character controller cleanup invariant failed: {s}",
                    .{@errorName(err)},
                );
            };
        }

        fn destroyRuntimeOrPanic(self: *Self, runtime_id: engine.RuntimeId) void {
            self.runtime.destroy(runtime_id) catch |err| {
                std.debug.panic(
                    "character entity cleanup invariant failed: {s}",
                    .{@errorName(err)},
                );
            };
        }
    };
}

fn calculateVelocity(
    config: Config,
    locomotion: anytype,
    state: engine.physics.CharacterState,
    delta_seconds: f32,
) [3]f32 {
    const move = normalizeMove(locomotion.move);
    const sin_yaw = @sin(locomotion.facing_yaw);
    const cos_yaw = @cos(locomotion.facing_yaw);
    const horizontal = [3]f32{
        (move[0] * cos_yaw + move[1] * sin_yaw) * config.move_speed,
        0,
        (move[0] * sin_yaw - move[1] * cos_yaw) * config.move_speed,
    };
    const moving_towards_ground =
        state.velocity[1] - state.ground_velocity[1] < 0.1;
    var result = [3]f32{
        horizontal[0],
        state.velocity[1],
        horizontal[2],
    };
    if (state.ground_state == .on_ground and moving_towards_ground) {
        result[0] += state.ground_velocity[0];
        result[1] = state.ground_velocity[1];
        result[2] += state.ground_velocity[2];
        if (locomotion.jump_requested) result[1] += config.jump_speed;
    }
    // Terminal fall speed is relative to a supporting body's vertical motion.
    // This keeps long free falls representable without preventing the
    // character from following a fast downward platform.
    const vertical_reference = if (state.ground_state == .on_ground)
        state.ground_velocity[1]
    else
        0;
    const accelerated_relative_vertical =
        result[1] - vertical_reference + config.gravity * delta_seconds;
    result[1] = vertical_reference + @max(
        accelerated_relative_vertical,
        -config.terminal_fall_speed,
    );
    return clampCharacterVelocity(result);
}

const character_velocity_limit_margin: f64 = 0.01;

fn combinedCharacterSpeedFits(horizontal: f32, vertical: f32) bool {
    const horizontal_wide: f64 = horizontal;
    const vertical_wide: f64 = vertical;
    const safe_limit: f64 = @as(f64, engine.physics.max_linear_velocity) -
        character_velocity_limit_margin;
    return horizontal_wide * horizontal_wide + vertical_wide * vertical_wide <=
        safe_limit * safe_limit;
}

/// Saturate only at the engine/Jolt representation boundary. Ordinary
/// locomotion is constrained by Config.validate; this additionally handles a
/// fast supporting body without allowing the adapter to clamp silently.
fn clampCharacterVelocity(velocity: [3]f32) [3]f32 {
    var magnitude_squared: f64 = 0;
    for (velocity) |value| {
        const wide: f64 = value;
        magnitude_squared += wide * wide;
    }
    const safe_limit: f64 = @as(f64, engine.physics.max_linear_velocity) -
        character_velocity_limit_margin;
    if (magnitude_squared <= safe_limit * safe_limit) return velocity;
    const scale: f32 = @floatCast(safe_limit / @sqrt(magnitude_squared));
    return .{
        velocity[0] * scale,
        velocity[1] * scale,
        velocity[2] * scale,
    };
}

fn validateCommand(command: Command) !void {
    switch (command) {
        .spawn => |spawn| try validateSpawn(spawn),
        .actions => |actions| {
            try actions.id.validate();
            try validateFinite(actions.move);
            if (@abs(actions.move[0]) > 1 or @abs(actions.move[1]) > 1) {
                return error.InvalidMoveAction;
            }
            if (!std.math.isFinite(actions.facing_yaw)) return error.InvalidFacingYaw;
        },
        .despawn => |despawn| try despawn.id.validate(),
    }
}

fn validateSpawn(spawn: SpawnCharacter) !void {
    try validateFinite(spawn.position);
    try validateFinite(spawn.velocity);
    try (engine.physics.Velocity{ .linear = spawn.velocity }).validate();
    if (!std.math.isFinite(spawn.facing_yaw)) return error.InvalidFacingYaw;
}

fn validateFinite(values: anytype) !void {
    for (values) |value| {
        if (!std.math.isFinite(value)) return error.NonFiniteCharacterValue;
    }
}

fn normalizeMove(move: [2]f32) [2]f32 {
    const length_squared = move[0] * move[0] + move[1] * move[1];
    if (length_squared <= 1 or length_squared == 0) return move;
    const inverse_length = 1.0 / @sqrt(length_squared);
    return .{ move[0] * inverse_length, move[1] * inverse_length };
}

fn normalizeYaw(yaw: f32) f32 {
    return @mod(yaw + std.math.pi, std.math.tau) - std.math.pi;
}

fn yawFromRotation(rotation_value: [4]f32) !f32 {
    const rotation = try engine.transform.normalizeQuaternion(rotation_value);
    const x = rotation[0];
    const y = rotation[1];
    const z = rotation[2];
    const w = rotation[3];
    const yaw = normalizeYaw(std.math.atan2(
        2 * (w * y + x * z),
        1 - 2 * (y * y + z * z),
    ));
    return if (yaw == 0) 0 else yaw;
}

fn poseFor(position: [3]f32, yaw: f32) engine.physics.Pose {
    const half_yaw = yaw * 0.5;
    return .{
        .position = position,
        .rotation = .{ 0, @sin(half_yaw), 0, @cos(half_yaw) },
    };
}

fn lessThanRecord(_: void, lhs: CharacterV1, rhs: CharacterV1) bool {
    if (lhs.id.namespace != rhs.id.namespace) return lhs.id.namespace < rhs.id.namespace;
    return lhs.id.local < rhs.id.local;
}

const FakeControllers = struct {
    pub const Handle = enum(u32) { player = 1 };

    active: bool = false,
    fail_create: bool = false,
    fail_update: bool = false,
    fail_relocate: bool = false,
    block_relocate: bool = false,
    prepare_calls: usize = 0,
    update_calls: usize = 0,
    relocate_calls: usize = 0,
    state: engine.physics.CharacterState = .{
        .position = .{ 0, 0, 0 },
        .velocity = .{ 0, 0, 0 },
        .ground_state = .in_air,
        .ground_velocity = .{ 0, 0, 0 },
        .ground_normal = .{ 0, 1, 0 },
    },

    pub fn createCharacter(
        self: *FakeControllers,
        desc: engine.physics.CharacterDesc,
    ) !Handle {
        if (self.active) return error.FakeCapacityReached;
        if (self.fail_create) return error.InjectedCharacterCreateFailure;
        try desc.validate();
        self.active = true;
        self.state.position = desc.position;
        self.state.velocity = desc.velocity;
        self.state.ground_state = .in_air;
        return .player;
    }

    pub fn destroyCharacter(self: *FakeControllers, _: Handle) !void {
        if (!self.active) return error.InvalidCharacterId;
        self.active = false;
    }

    pub fn characterState(
        self: *FakeControllers,
        _: Handle,
    ) !engine.physics.CharacterState {
        if (!self.active) return error.InvalidCharacterId;
        return self.state;
    }

    pub fn prepareCharacter(
        self: *FakeControllers,
        handle: Handle,
    ) !engine.physics.CharacterState {
        self.prepare_calls += 1;
        return self.characterState(handle);
    }

    pub fn updateCharacter(
        self: *FakeControllers,
        _: Handle,
        update_desc: engine.physics.CharacterUpdate,
        delta_seconds: f32,
    ) !engine.physics.CharacterState {
        self.update_calls += 1;
        if (!self.active) return error.InvalidCharacterId;
        if (self.fail_update) return error.InjectedCharacterUpdateFailure;
        try update_desc.validate();
        self.state.velocity = update_desc.velocity;
        for (0..3) |axis| {
            self.state.position[axis] += self.state.velocity[axis] * delta_seconds;
        }
        if (self.state.position[1] <= 0 and self.state.velocity[1] <= 0) {
            self.state.position[1] = 0;
            self.state.velocity[1] = 0;
            self.state.ground_state = .on_ground;
        } else {
            self.state.ground_state = .in_air;
        }
        return self.state;
    }

    pub fn tryRelocateCharacter(
        self: *FakeControllers,
        _: Handle,
        relocation: engine.physics.CharacterRelocation,
    ) !?engine.physics.CharacterState {
        self.relocate_calls += 1;
        if (!self.active) return error.InvalidCharacterId;
        if (self.fail_relocate) return error.InjectedCharacterRelocationFailure;
        try relocation.validate();
        if (self.block_relocate) return null;
        self.state.position = relocation.position;
        self.state.velocity = relocation.velocity;
        self.state.ground_state = .in_air;
        return self.state;
    }
};

const TestFeature = Feature(FakeControllers);
comptime {
    driver_contract.assertImplementation(TestFeature.DriverAccess);
}

test "driver access makes CharacterVirtual dormant and exits transactionally" {
    var runtime = try engine.Runtime.init(std.testing.allocator, .{
        .namespace = 40,
        .fixed_delta_seconds = 1.0 / 120.0,
    });
    defer runtime.deinit();
    var controllers = FakeControllers{};
    var feature = try TestFeature.init(
        std.testing.allocator,
        &runtime,
        &controllers,
        .{},
    );
    defer feature.deinit();
    var registry = runtime.registry();
    try feature.register(&registry);
    runtime.finishRegistration();

    try feature.enqueue(.{ .spawn = .{
        .request_id = 1,
        .position = .{ 0, 0, 0 },
    } });
    try runtime.tick();
    const character_id = feature.pollOutcome().?.spawned.id;
    while (feature.pollEvent() != null) {}
    var drivers = feature.driverAccess();
    try std.testing.expectEqual(
        driver_contract.DriverMode.on_foot,
        (try drivers.driverState(character_id)).?.mode,
    );

    const vehicle_id = engine.PersistentId{ .namespace = 40, .local = 99 };
    try feature.applyActionsNow(.{
        .id = character_id,
        .move = .{ 0, 1 },
        .facing_yaw = 0,
        .jump_pressed = true,
    });
    const runtime_id = runtime.resolve(character_id) orelse
        return error.ExpectedCharacterRuntimeId;
    const before_cancel = (runtime.get(runtime_id, TestFeature.Locomotion) orelse
        return error.ExpectedCharacterLocomotion).*;
    try drivers.beginDriving(character_id, vehicle_id);
    drivers.cancelDriving(character_id, vehicle_id);
    const after_cancel = (runtime.get(runtime_id, TestFeature.Locomotion) orelse
        return error.ExpectedCharacterLocomotion).*;
    try std.testing.expectEqual(before_cancel.move, after_cancel.move);
    try std.testing.expectEqual(before_cancel.jump_requested, after_cancel.jump_requested);

    try drivers.beginDriving(character_id, vehicle_id);
    try std.testing.expectEqual(
        vehicle_id,
        (try drivers.driverState(character_id)).?.mode.driving,
    );
    try std.testing.expectError(
        error.CharacterAlreadyDriving,
        drivers.beginDriving(character_id, vehicle_id),
    );

    const updates_before = controllers.update_calls;
    try feature.enqueue(.{ .actions = .{
        .id = character_id,
        .move = .{ 0, 1 },
        .facing_yaw = 0,
        .jump_pressed = true,
    } });
    try feature.enqueue(.{ .despawn = .{ .id = character_id } });
    try runtime.tick();
    try std.testing.expectEqual(updates_before, controllers.update_calls);
    try std.testing.expectEqual(
        RejectionReason.driving,
        feature.pollOutcome().?.rejected.reason,
    );
    try std.testing.expectEqual(
        RejectionReason.driving,
        feature.pollOutcome().?.rejected.reason,
    );
    try std.testing.expectEqual(@as(usize, 0), (try feature.extract(0.5)).len);
    try std.testing.expect(controllers.active);

    const exit_pose = engine.physics.Pose{
        .position = .{ 3, 0, -2 },
        .rotation = .{ 0, @sin(0.25), 0, @cos(0.25) },
    };
    controllers.block_relocate = true;
    try std.testing.expectEqual(
        driver_contract.ExitDisposition.blocked,
        try drivers.attemptEndDriving(character_id, vehicle_id, exit_pose),
    );
    try std.testing.expectEqual(
        vehicle_id,
        (try drivers.driverState(character_id)).?.mode.driving,
    );

    controllers.block_relocate = false;
    controllers.fail_relocate = true;
    try std.testing.expectError(
        error.InjectedCharacterRelocationFailure,
        drivers.attemptEndDriving(character_id, vehicle_id, exit_pose),
    );
    try std.testing.expectEqual(
        vehicle_id,
        (try drivers.driverState(character_id)).?.mode.driving,
    );

    controllers.fail_relocate = false;
    try std.testing.expectEqual(
        driver_contract.ExitDisposition.exited,
        try drivers.attemptEndDriving(character_id, vehicle_id, exit_pose),
    );
    const on_foot = (try drivers.driverState(character_id)).?;
    try std.testing.expectEqual(driver_contract.DriverMode.on_foot, on_foot.mode);
    try std.testing.expectEqual(exit_pose.position, on_foot.pose.position);
    const draws = try feature.extract(0.5);
    try std.testing.expectEqual(@as(usize, 1), draws.len);
    try std.testing.expectEqual(exit_pose.position, draws[0].pose.position);
    try std.testing.expectEqual(@as(usize, 3), controllers.relocate_calls);
}

test "typed actions drive a headless character and jump once" {
    var runtime = try engine.Runtime.init(std.testing.allocator, .{
        .namespace = 41,
        .fixed_delta_seconds = 1.0 / 120.0,
    });
    defer runtime.deinit();
    var controllers = FakeControllers{};
    var feature = try Feature(FakeControllers).init(
        std.testing.allocator,
        &runtime,
        &controllers,
        .{},
    );
    defer feature.deinit();
    var registry = runtime.registry();
    try feature.register(&registry);
    runtime.finishRegistration();

    try feature.enqueue(.{ .spawn = .{
        .request_id = 7,
        .position = .{ 0, 0, 0 },
    } });
    try runtime.tick();
    const spawned = feature.pollOutcome().?.spawned;
    try std.testing.expectEqual(@as(u64, 7), spawned.request_id);
    const landed_on_spawn = feature.pollEvent().?.ground_state_changed;
    try std.testing.expectEqual(engine.physics.GroundState.in_air, landed_on_spawn.previous);
    try std.testing.expectEqual(engine.physics.GroundState.on_ground, landed_on_spawn.current);
    while (feature.pollOutcome() != null) {}

    for (0..60) |_| {
        try feature.enqueue(.{ .actions = .{
            .id = spawned.id,
            .move = .{ 0, 1 },
            .facing_yaw = 0,
        } });
        try runtime.tick();
    }
    const walked = try feature.view(spawned.id);
    try std.testing.expect(walked.position[2] < -2.9);
    try std.testing.expectEqual(engine.physics.GroundState.on_ground, walked.ground_state);

    // No action sample means neutral input, not an indefinitely repeated hold.
    try runtime.tick();
    const neutral = try feature.view(spawned.id);
    try std.testing.expectApproxEqAbs(walked.position[2], neutral.position[2], 0.0001);

    for (0..60) |_| {
        try feature.enqueue(.{ .actions = .{
            .id = spawned.id,
            .move = .{ 0, 1 },
            .facing_yaw = std.math.pi / 2.0,
        } });
        try runtime.tick();
    }
    const turned = try feature.view(spawned.id);
    try std.testing.expect(turned.position[0] > 2.9);
    try std.testing.expectApproxEqAbs(
        @as(f32, std.math.pi / 2.0),
        turned.facing_yaw,
        0.0001,
    );

    try feature.enqueue(.{ .actions = .{
        .id = spawned.id,
        .move = .{ 0, 0 },
        .facing_yaw = 0,
        .jump_pressed = true,
    } });
    try runtime.tick();
    const jumped = try feature.view(spawned.id);
    try std.testing.expect(jumped.position[1] > 0);
    try std.testing.expectEqual(engine.physics.GroundState.in_air, jumped.ground_state);
    const left_ground = feature.pollEvent().?.ground_state_changed;
    try std.testing.expectEqual(engine.physics.GroundState.on_ground, left_ground.previous);
    try std.testing.expectEqual(engine.physics.GroundState.in_air, left_ground.current);

    for (0..120) |_| try runtime.tick();
    try std.testing.expectEqual(
        engine.physics.GroundState.on_ground,
        (try feature.view(spawned.id)).ground_state,
    );
    const relanded = feature.pollEvent().?.ground_state_changed;
    try std.testing.expectEqual(engine.physics.GroundState.in_air, relanded.previous);
    try std.testing.expectEqual(engine.physics.GroundState.on_ground, relanded.current);

    const draws = try feature.extract(0.5);
    try std.testing.expectEqual(@as(usize, 1), draws.len);
    try std.testing.expect(std.meta.eql(draws[0].persistent_id, spawned.id));

    while (feature.pollOutcome() != null) {}
    try feature.enqueue(.{ .despawn = .{ .id = spawned.id } });
    try runtime.tick();
    try std.testing.expect(std.meta.eql(feature.pollOutcome().?.despawned, spawned.id));
    try std.testing.expectEqual(@as(usize, 0), feature.count());
    try std.testing.expect(!controllers.active);
}

test "terminal fall speed keeps long diagonal free fall representable" {
    var runtime = try engine.Runtime.init(std.testing.allocator, .{
        .namespace = 45,
        .fixed_delta_seconds = 1.0 / 120.0,
    });
    defer runtime.deinit();
    var controllers = FakeControllers{};
    const config = Config{ .terminal_fall_speed = 60.0 };
    var feature = try Feature(FakeControllers).init(
        std.testing.allocator,
        &runtime,
        &controllers,
        config,
    );
    defer feature.deinit();
    var registry = runtime.registry();
    try feature.register(&registry);
    runtime.finishRegistration();

    try feature.enqueue(.{ .spawn = .{
        .request_id = 1,
        .position = .{ 0, 100_000, 0 },
        .velocity = .{ 0, -engine.physics.max_linear_velocity, 0 },
    } });
    try runtime.tick();
    const id = feature.pollOutcome().?.spawned.id;
    for (0..3_600) |_| {
        try feature.enqueue(.{ .actions = .{
            .id = id,
            .move = .{ 1, 1 },
            .facing_yaw = 0,
        } });
        try runtime.tick();
    }

    try runtime.ensureHealthy();
    const view = try feature.view(id);
    try std.testing.expectApproxEqAbs(-config.terminal_fall_speed, view.velocity[1], 0.001);
    try (engine.physics.Velocity{ .linear = view.velocity }).validate();
}

test "character config rejects locomotion outside the velocity contract" {
    try std.testing.expectError(
        error.CharacterSpeedOutOfRange,
        (Config{
            .move_speed = engine.physics.max_linear_velocity,
            .jump_speed = 1,
        }).validate(),
    );
    try std.testing.expectError(
        error.InvalidTerminalFallSpeed,
        (Config{ .terminal_fall_speed = 0 }).validate(),
    );
}

test "persisted character config round trips every simulation field" {
    const config = Config{
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
        .max_characters = 4,
        .assets = .{
            .mesh = .{ .index = 3, .generation = 2 },
            .material = .{ .index = 4, .generation = 2 },
        },
    };
    try config.validate();
    const persisted = CharacterConfigV1.fromConfig(config);
    try persisted.validate();
    const restored = try persisted.toConfig(9, .{});
    try std.testing.expect(std.meta.eql(persisted, CharacterConfigV1.fromConfig(restored)));
    try std.testing.expectEqual(@as(usize, 9), restored.max_characters);
    try std.testing.expect(!restored.assets.mesh.isValid());
    try std.testing.expect(!restored.assets.material.isValid());
}

test "character records require canonical yaw" {
    const base = CharacterV1{
        .id = .{ .namespace = 46, .local = 1 },
        .position = .{ 0, 0, 0 },
        .velocity = .{ 0, 0, 0 },
        .facing_yaw = 0,
    };
    try validateRecord(base);

    const pi: f32 = std.math.pi;
    var record = base;
    record.facing_yaw = -pi;
    try validateRecord(record);
    record.facing_yaw = std.math.nextAfter(f32, pi, -std.math.inf(f32));
    try validateRecord(record);
    for ([_]f32{
        pi,
        std.math.tau,
        std.math.nextAfter(f32, -pi, -std.math.inf(f32)),
        @bitCast(@as(u32, 0x8000_0000)),
    }) |invalid_yaw| {
        record.facing_yaw = invalid_yaw;
        try std.testing.expectError(error.NonCanonicalFacingYaw, validateRecord(record));
    }
}

test "record restore preserves canonical yaw bits" {
    var runtime = try engine.Runtime.init(std.testing.allocator, .{
        .namespace = 47,
        .fixed_delta_seconds = 1.0 / 120.0,
        .next_local_id = 2,
    });
    defer runtime.deinit();
    var controllers = FakeControllers{};
    var feature = try Feature(FakeControllers).init(
        std.testing.allocator,
        &runtime,
        &controllers,
        .{},
    );
    defer feature.deinit();
    var registry = runtime.registry();
    try feature.register(&registry);

    const tiny_yaw = std.math.nextAfter(f32, 0, 1);
    const records = [_]CharacterV1{.{
        .id = .{ .namespace = 47, .local = 1 },
        .position = .{ 0, 10, 0 },
        .velocity = .{ 0, 0, 0 },
        .facing_yaw = tiny_yaw,
    }};
    try feature.restoreRecords(&records);
    runtime.finishRegistration();
    const saved = try feature.snapshotRecords(std.testing.allocator);
    defer std.testing.allocator.free(saved);
    try std.testing.expectEqual(
        @as(u32, @bitCast(tiny_yaw)),
        @as(u32, @bitCast(saved[0].facing_yaw)),
    );
}

test "character records restore through explicit persistent identities" {
    var runtime = try engine.Runtime.init(std.testing.allocator, .{
        .namespace = 42,
        .fixed_delta_seconds = 1.0 / 120.0,
        .next_local_id = 8,
    });
    defer runtime.deinit();
    var controllers = FakeControllers{};
    var feature = try Feature(FakeControllers).init(
        std.testing.allocator,
        &runtime,
        &controllers,
        .{},
    );
    defer feature.deinit();
    var registry = runtime.registry();
    try feature.register(&registry);

    const records = [_]CharacterV1{.{
        .id = .{ .namespace = 42, .local = 3 },
        .position = .{ 1, 2, 3 },
        .velocity = .{ 0, 0, 0 },
        .facing_yaw = 0.5,
    }};
    try feature.restoreRecords(&records);
    runtime.finishRegistration();
    try runtime.tick();
    const view = try feature.view(records[0].id);
    try std.testing.expectApproxEqAbs(@as(f32, 1), view.position[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), view.facing_yaw, 0.0001);
    const saved = try feature.snapshotRecords(std.testing.allocator);
    defer std.testing.allocator.free(saved);
    try std.testing.expectEqual(@as(usize, 1), saved.len);
    try std.testing.expect(std.meta.eql(records[0].id, saved[0].id));
}

test "controller create failure rolls back the runtime entity" {
    var runtime = try engine.Runtime.init(std.testing.allocator, .{
        .namespace = 43,
        .fixed_delta_seconds = 1.0 / 120.0,
    });
    defer runtime.deinit();
    var controllers = FakeControllers{ .fail_create = true };
    var feature = try Feature(FakeControllers).init(
        std.testing.allocator,
        &runtime,
        &controllers,
        .{},
    );
    defer feature.deinit();
    var registry = runtime.registry();
    try feature.register(&registry);
    runtime.finishRegistration();
    try feature.enqueue(.{ .spawn = .{
        .request_id = 1,
        .position = .{ 0, 0, 0 },
    } });
    try std.testing.expectError(error.InjectedCharacterCreateFailure, runtime.tick());
    try std.testing.expect(runtime.isFaulted());
    try std.testing.expectEqual(@as(usize, 0), runtime.entityCount());
    try std.testing.expectEqual(@as(usize, 0), feature.count());
    try std.testing.expect(!controllers.active);
}

test "controller update failure faults without losing owned cleanup state" {
    var runtime = try engine.Runtime.init(std.testing.allocator, .{
        .namespace = 44,
        .fixed_delta_seconds = 1.0 / 120.0,
    });
    defer runtime.deinit();
    var controllers = FakeControllers{};
    var feature = try Feature(FakeControllers).init(
        std.testing.allocator,
        &runtime,
        &controllers,
        .{},
    );
    defer feature.deinit();
    var registry = runtime.registry();
    try feature.register(&registry);
    runtime.finishRegistration();
    try feature.enqueue(.{ .spawn = .{
        .request_id = 1,
        .position = .{ 0, 0, 0 },
    } });
    try runtime.tick();
    _ = feature.pollOutcome();
    while (feature.pollOutcome() != null) {}
    controllers.fail_update = true;
    try std.testing.expectError(error.InjectedCharacterUpdateFailure, runtime.tick());
    try std.testing.expect(runtime.isFaulted());
    try std.testing.expectEqual(@as(usize, 1), feature.count());
    try std.testing.expectEqual(@as(usize, 1), runtime.entityCount());
    try std.testing.expectError(
        error.RuntimeFaulted,
        feature.snapshotRecords(std.testing.allocator),
    );
}
