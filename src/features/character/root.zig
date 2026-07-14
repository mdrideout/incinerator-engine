//! CharacterFeature: player locomotion as an end-to-end vertical slice.

const std = @import("std");
const engine = @import("incinerator_engine");
const driver_contract = @import("driver_contract");
const interaction_contract = @import("interaction_contract");

const logical_state_domain = "incinerator.character.logical";
const logical_state_schema: u16 = 2;

/// Per-world authority budgets. Commands reserve their possible outcome;
/// ground-state events are observational and use bounded best-effort delivery.
pub const max_pending_commands: usize = 128;
pub const max_outcomes: usize = 128;
pub const max_events: usize = 256;

pub const Budget = struct {
    commands: u32 = max_pending_commands,
    outcomes: u32 = max_outcomes,
    events: u32 = max_events,
};

pub const declared_budget = Budget{};

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
    carrying,
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

pub const Diagnostics = struct {
    active_count: u32,
    commands: engine.contracts.diagnostics.QueueStats,
    outcomes: engine.contracts.diagnostics.QueueStats,
    events: engine.contracts.diagnostics.QueueStats,
    events_dropped: u64,
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

fn diagnosticsCount(value: usize) u32 {
    return std.math.cast(u32, value) orelse std.math.maxInt(u32);
}

const FixedQueue = engine.BoundedQueue;

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
        const CarryRuntimeState = struct {
            mode: interaction_contract.CarryMode = .empty,
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
        outcomes: FixedQueue(Outcome, max_outcomes) = .{},
        events: FixedQueue(Event, max_events) = .{},
        presentations: std.ArrayListUnmanaged(CharacterDraw) = .empty,
        commands_high_water: u32 = 0,
        outcomes_high_water: u32 = 0,
        events_high_water: u32 = 0,
        commands_rejected: u64 = 0,
        events_dropped: u64 = 0,

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

            pub fn abandonDriving(
                self: *DriverAccess,
                character_id: engine.PersistentId,
                vehicle_id: engine.PersistentId,
            ) !void {
                try self.feature.abandonDrivingNow(character_id, vehicle_id);
            }
        };

        /// Gameplay port consumed by InteractionFeature. It exposes only the
        /// validated carrier pose/modes and atomic relationship transitions;
        /// private ECS/controller state remains owned by CharacterFeature.
        pub const CarrierAccess = struct {
            feature: *Self,

            pub fn carryState(
                self: *CarrierAccess,
                id: engine.PersistentId,
            ) !?interaction_contract.CarryState {
                return self.feature.carryStateNow(id);
            }

            pub fn beginCarry(
                self: *CarrierAccess,
                character_id: engine.PersistentId,
                item_id: engine.PersistentId,
            ) !void {
                try self.feature.beginCarryNow(character_id, item_id);
            }

            pub fn endCarry(
                self: *CarrierAccess,
                character_id: engine.PersistentId,
                item_id: engine.PersistentId,
            ) !void {
                try self.feature.endCarryNow(character_id, item_id);
            }

            pub fn cancelBeginCarry(
                self: *CarrierAccess,
                character_id: engine.PersistentId,
                item_id: engine.PersistentId,
            ) void {
                self.feature.cancelBeginCarryNow(character_id, item_id);
            }
        };

        pub fn init(
            allocator: std.mem.Allocator,
            runtime: *engine.Runtime,
            controllers: *Controllers,
            config: Config,
        ) !Self {
            try config.validate();
            var self = Self{
                .allocator = allocator,
                .runtime = runtime,
                .controllers = controllers,
                .config = config,
            };
            errdefer self.pending.deinit(allocator);
            errdefer self.applying.deinit(allocator);
            errdefer self.active.deinit(allocator);
            errdefer self.presentations.deinit(allocator);
            try self.pending.ensureTotalCapacityPrecise(allocator, max_pending_commands);
            try self.applying.ensureTotalCapacityPrecise(allocator, max_pending_commands);
            try self.active.ensureTotalCapacityPrecise(allocator, config.max_characters);
            try self.presentations.ensureTotalCapacityPrecise(
                allocator,
                config.max_characters,
            );
            return self;
        }

        pub fn register(self: *Self, registry: *engine.FeatureRegistry) !void {
            try registry.registerComponent(Character);
            try registry.registerComponent(RuntimeController);
            try registry.registerComponent(DriveState);
            try registry.registerComponent(CarryRuntimeState);
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

        pub fn carrierAccess(self: *Self) CarrierAccess {
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
                return error.CharacterCommandQueueFull;
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

        pub fn pollEvent(self: *Self) ?Event {
            const event = self.events.pop();
            self.observeQueueHighWater();
            return event;
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
                .events = .{
                    .occupancy = self.eventOccupancy(),
                    .high_water = self.events_high_water,
                    .capacity = max_events,
                    .rejected = self.events_dropped,
                },
                .events_dropped = self.events_dropped,
            };
        }

        /// Append simulation-relevant character state in stable identity
        /// order. Scratch is caller-owned so the per-tick path never allocates.
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
                    return error.CharacterIdentityInvariantBroken;
                const character = self.runtime.get(runtime_id, Character) orelse
                    return error.NotACharacter;
                const controller = self.runtime.get(runtime_id, RuntimeController) orelse
                    return error.CharacterControllerInvariantBroken;
                const locomotion = self.runtime.get(runtime_id, Locomotion) orelse
                    return error.CharacterLocomotionInvariantBroken;
                const drive = self.runtime.get(runtime_id, DriveState) orelse
                    return error.CharacterDriveStateInvariantBroken;
                const carry = self.runtime.get(runtime_id, CarryRuntimeState) orelse
                    return error.CharacterCarryStateInvariantBroken;
                const state = try self.controllers.characterState(controller.handle);
                try state.validate();

                writePersistentId(writer, id);
                try writer.writeF32(character.radius);
                try writer.writeF32(character.half_height);
                try writeCharacterState(writer, state);

                // Locomotion retains intent and cached values that influence
                // the next controller update independently of the port state.
                try writeVector2(writer, locomotion.move);
                try writer.writeF32(locomotion.facing_yaw);
                writer.writeBool(locomotion.jump_requested);
                try writeVector3(writer, locomotion.velocity);
                writeGroundState(writer, locomotion.ground_state);

                writeDriverMode(writer, drive.mode);
                writer.writeBool(drive.rollback != null);
                if (drive.rollback) |rollback| {
                    try writeVector2(writer, rollback.move);
                    writer.writeBool(rollback.jump_requested);
                }
                writeCarryMode(writer, carry.mode);
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

            writer.writeU32(self.outcomeOccupancy());
            writer.writeU32(self.eventOccupancy());
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
                _ = self.runtime.get(runtime_id, CarryRuntimeState) orelse
                    return error.CharacterCarryStateInvariantBroken;
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
                            error.CharacterCarrying => try self.reject(.{
                                .command = .despawn,
                                .reason = .carrying,
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
            defer self.observeQueueHighWater();
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
                    self.emitEvent(.{ .ground_state_changed = .{
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
            if (emit_outcome) std.debug.assert(self.outcomes.len < max_outcomes);

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
            try self.runtime.set(runtime_id, CarryRuntimeState, .{});
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
                self.outcomes.pushAssumeCapacity(.{ .spawned = .{
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
            const carry = self.runtime.get(runtime_id, CarryRuntimeState) orelse
                return error.CharacterCarryStateInvariantBroken;
            const locomotion = self.runtime.get(runtime_id, Locomotion) orelse
                return error.CharacterLocomotionInvariantBroken;
            const controller = self.runtime.get(runtime_id, RuntimeController) orelse
                return error.CharacterControllerInvariantBroken;
            const state = try self.controllers.characterState(controller.handle);
            const result = driver_contract.DriverState{
                .pose = poseFor(state.position, locomotion.facing_yaw),
                .mode = drive.mode,
                .carried_item = switch (carry.mode) {
                    .empty => null,
                    .holding => |item_id| item_id,
                },
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
            const carry = self.runtime.get(runtime_id, CarryRuntimeState) orelse
                return error.CharacterCarryStateInvariantBroken;
            if (carry.mode != .empty) return error.CharacterCarrying;
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

        /// Teardown-only inverse used after every collision-safe exit candidate
        /// is blocked. The character remains hidden and must be despawned by
        /// the caller; no collision-invalid on-foot pose is ever presented.
        fn abandonDrivingNow(
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
            const locomotion = self.runtime.getMut(runtime_id, Locomotion) orelse
                return error.CharacterLocomotionInvariantBroken;
            const drive = self.runtime.getMut(runtime_id, DriveState) orelse
                return error.CharacterDriveStateInvariantBroken;
            switch (drive.mode) {
                .driving => |current| if (!std.meta.eql(current, vehicle_id)) {
                    return error.CharacterDrivingDifferentVehicle;
                },
                .on_foot => return error.CharacterNotDriving,
            }
            locomotion.move = .{ 0, 0 };
            locomotion.jump_requested = false;
            locomotion.velocity = .{ 0, 0, 0 };
            drive.rollback = null;
            drive.mode = .on_foot;
        }

        fn carryStateNow(
            self: *Self,
            id: engine.PersistentId,
        ) !?interaction_contract.CarryState {
            try id.validate();
            const runtime_id = self.runtime.resolve(id) orelse return null;
            _ = self.runtime.get(runtime_id, Character) orelse return null;
            const controller = self.runtime.get(runtime_id, RuntimeController) orelse
                return error.CharacterControllerInvariantBroken;
            const locomotion = self.runtime.get(runtime_id, Locomotion) orelse
                return error.CharacterLocomotionInvariantBroken;
            const drive = self.runtime.get(runtime_id, DriveState) orelse
                return error.CharacterDriveStateInvariantBroken;
            const carry = self.runtime.get(runtime_id, CarryRuntimeState) orelse
                return error.CharacterCarryStateInvariantBroken;
            const state = try self.controllers.characterState(controller.handle);
            const result = interaction_contract.CarryState{
                .pose = poseFor(state.position, locomotion.facing_yaw),
                .mobility = switch (drive.mode) {
                    .on_foot => .on_foot,
                    .driving => .driving,
                },
                .carry_mode = carry.mode,
            };
            try result.validate();
            return result;
        }

        fn beginCarryNow(
            self: *Self,
            character_id: engine.PersistentId,
            item_id: engine.PersistentId,
        ) !void {
            try character_id.validate();
            try item_id.validate();
            const runtime_id = self.runtime.resolve(character_id) orelse
                return error.CharacterNotFound;
            _ = self.runtime.get(runtime_id, Character) orelse
                return error.NotACharacter;
            const drive = self.runtime.get(runtime_id, DriveState) orelse
                return error.CharacterDriveStateInvariantBroken;
            switch (drive.mode) {
                .on_foot => {},
                .driving => return error.CharacterDriving,
            }
            const carry = self.runtime.getMut(runtime_id, CarryRuntimeState) orelse
                return error.CharacterCarryStateInvariantBroken;
            switch (carry.mode) {
                .empty => carry.mode = .{ .holding = item_id },
                .holding => return error.CharacterAlreadyCarrying,
            }
        }

        fn endCarryNow(
            self: *Self,
            character_id: engine.PersistentId,
            item_id: engine.PersistentId,
        ) !void {
            try character_id.validate();
            try item_id.validate();
            const runtime_id = self.runtime.resolve(character_id) orelse
                return error.CharacterNotFound;
            _ = self.runtime.get(runtime_id, Character) orelse
                return error.NotACharacter;
            const drive = self.runtime.get(runtime_id, DriveState) orelse
                return error.CharacterDriveStateInvariantBroken;
            switch (drive.mode) {
                .on_foot => {},
                .driving => return error.CharacterDriving,
            }
            const carry = self.runtime.getMut(runtime_id, CarryRuntimeState) orelse
                return error.CharacterCarryStateInvariantBroken;
            switch (carry.mode) {
                .empty => return error.CharacterNotCarrying,
                .holding => |held_item| {
                    if (!std.meta.eql(held_item, item_id)) {
                        return error.CharacterCarryingDifferentItem;
                    }
                    carry.mode = .empty;
                },
            }
        }

        fn cancelBeginCarryNow(
            self: *Self,
            character_id: engine.PersistentId,
            item_id: engine.PersistentId,
        ) void {
            const runtime_id = self.runtime.resolve(character_id) orelse
                @panic("collect rollback carrier no longer exists");
            _ = self.runtime.get(runtime_id, Character) orelse
                @panic("collect rollback identity is not a character");
            const carry = self.runtime.getMut(runtime_id, CarryRuntimeState) orelse
                @panic("collect rollback character has no carry state");
            switch (carry.mode) {
                .empty => @panic("collect rollback character is not carrying"),
                .holding => |held_item| if (!std.meta.eql(held_item, item_id)) {
                    @panic("collect rollback character carries a different item");
                },
            }
            carry.mode = .empty;
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
            const carry = self.runtime.get(runtime_id, CarryRuntimeState) orelse
                return error.CharacterCarryStateInvariantBroken;
            if (carry.mode != .empty) return error.CharacterCarrying;
            const controller = self.runtime.get(runtime_id, RuntimeController) orelse
                return error.CharacterControllerInvariantBroken;
            const index = self.activeIndex(runtime_id) orelse
                return error.CharacterActiveIndexInvariantBroken;
            if (emit_outcome) std.debug.assert(self.outcomes.len < max_outcomes);
            try self.controllers.destroyCharacter(controller.handle);
            self.destroyRuntimeOrPanic(runtime_id);
            _ = self.active.orderedRemove(index);
            if (emit_outcome) self.outcomes.pushAssumeCapacity(.{ .despawned = id });
        }

        fn activeIndex(self: *const Self, runtime_id: engine.RuntimeId) ?usize {
            for (self.active.items, 0..) |candidate, index| {
                if (std.meta.eql(candidate, runtime_id)) return index;
            }
            return null;
        }

        fn reject(self: *Self, rejection: CommandRejected) !void {
            std.debug.assert(self.outcomes.len < max_outcomes);
            self.outcomes.pushAssumeCapacity(.{ .rejected = rejection });
        }

        fn emitEvent(self: *Self, event: Event) void {
            if (self.events.len == max_events) {
                self.events_dropped +|= 1;
                return;
            }
            self.events.pushAssumeCapacity(event);
            self.observeQueueHighWater();
        }

        fn commandOccupancyCount(self: *const Self) usize {
            const applying_remaining = if (self.applying_index < self.applying.items.len)
                self.applying.items.len - self.applying_index
            else
                0;
            const total = std.math.add(
                usize,
                self.pending.items.len,
                applying_remaining,
            ) catch std.math.maxInt(usize);
            return total;
        }

        fn commandOccupancy(self: *const Self) u32 {
            return diagnosticsCount(self.commandOccupancyCount());
        }

        fn outcomeOccupancy(self: *const Self) u32 {
            return diagnosticsCount(self.outcomes.len);
        }

        fn eventOccupancy(self: *const Self) u32 {
            return diagnosticsCount(self.events.len);
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
            self.events_high_water = @max(
                self.events_high_water,
                self.eventOccupancy(),
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
                    try writeVector3(writer, spawn.position);
                    try writeVector3(writer, spawn.velocity);
                    try writer.writeF32(spawn.facing_yaw);
                },
                .actions => |actions| {
                    writer.writeU8(2);
                    writePersistentId(writer, actions.id);
                    try writeVector2(writer, actions.move);
                    try writer.writeF32(actions.facing_yaw);
                    writer.writeBool(actions.jump_pressed);
                },
                .despawn => |despawn| {
                    writer.writeU8(3);
                    writePersistentId(writer, despawn.id);
                },
            }
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

fn writePersistentId(
    writer: *engine.contracts.replay.Writer,
    id: engine.PersistentId,
) void {
    writer.writeU64(id.namespace);
    writer.writeU64(id.local);
}

fn writeVector2(
    writer: *engine.contracts.replay.Writer,
    value: [2]f32,
) !void {
    for (value) |component| try writer.writeF32(component);
}

fn writeVector3(
    writer: *engine.contracts.replay.Writer,
    value: [3]f32,
) !void {
    for (value) |component| try writer.writeF32(component);
}

fn writeGroundState(
    writer: *engine.contracts.replay.Writer,
    state: engine.physics.GroundState,
) void {
    writer.writeU8(switch (state) {
        .on_ground => 1,
        .on_steep_ground => 2,
        .not_supported => 3,
        .in_air => 4,
    });
}

fn writeCharacterState(
    writer: *engine.contracts.replay.Writer,
    state: engine.physics.CharacterState,
) !void {
    try state.validate();
    try writeVector3(writer, state.position);
    try writeVector3(writer, state.velocity);
    writeGroundState(writer, state.ground_state);
    try writeVector3(writer, state.ground_velocity);
    try writeVector3(writer, state.ground_normal);
}

fn writeDriverMode(
    writer: *engine.contracts.replay.Writer,
    mode: driver_contract.DriverMode,
) void {
    switch (mode) {
        .on_foot => writer.writeU8(1),
        .driving => |vehicle_id| {
            writer.writeU8(2);
            writePersistentId(writer, vehicle_id);
        },
    }
}

fn writeCarryMode(
    writer: *engine.contracts.replay.Writer,
    mode: interaction_contract.CarryMode,
) void {
    switch (mode) {
        .empty => writer.writeU8(1),
        .holding => |item_id| {
            writer.writeU8(2);
            writePersistentId(writer, item_id);
        },
    }
}

fn lessThanPersistentId(
    _: void,
    lhs: engine.PersistentId,
    rhs: engine.PersistentId,
) bool {
    if (lhs.namespace != rhs.namespace) return lhs.namespace < rhs.namespace;
    return lhs.local < rhs.local;
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
    interaction_contract.assertCarrierImplementation(TestFeature.CarrierAccess);
}

test "character diagnostics retain unread output and command high-water marks" {
    var runtime = try engine.Runtime.init(std.testing.allocator, .{
        .namespace = 49,
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
    try feature.enqueue(.{ .actions = .{
        .id = .{ .namespace = 49, .local = 99 },
        .facing_yaw = 0,
    } });
    var snapshot = feature.diagnostics();
    try std.testing.expectEqual(@as(u32, 2), snapshot.commands.occupancy);
    try std.testing.expectEqual(@as(u32, 2), snapshot.commands.high_water);
    try std.testing.expectEqual(@as(?u32, max_pending_commands), snapshot.commands.capacity);

    try runtime.tick();
    snapshot = feature.diagnostics();
    try std.testing.expectEqual(@as(u32, 1), snapshot.active_count);
    try std.testing.expectEqual(@as(u32, 0), snapshot.commands.occupancy);
    try std.testing.expectEqual(@as(u32, 2), snapshot.outcomes.occupancy);
    try std.testing.expectEqual(@as(u32, 2), snapshot.outcomes.high_water);
    try std.testing.expectEqual(@as(u32, 1), snapshot.events.occupancy);
    try std.testing.expectEqual(@as(u32, 1), snapshot.events.high_water);

    _ = feature.pollOutcome() orelse return error.MissingOutcome;
    _ = feature.pollEvent() orelse return error.MissingEvent;
    snapshot = feature.diagnostics();
    try std.testing.expectEqual(@as(u32, 1), snapshot.outcomes.occupancy);
    try std.testing.expectEqual(@as(u32, 0), snapshot.events.occupancy);
    try std.testing.expectEqual(@as(u32, 1), snapshot.events.high_water);
}

test "character bounded command reservations drain and recover without allocation" {
    var runtime = try engine.Runtime.init(std.testing.allocator, .{
        .namespace = 86,
        .fixed_delta_seconds = 1.0 / 120.0,
    });
    defer runtime.deinit();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var controllers = FakeControllers{};
    var feature = try TestFeature.init(
        failing.allocator(),
        &runtime,
        &controllers,
        .{},
    );
    defer feature.deinit();
    var registry = runtime.registry();
    try feature.register(&registry);
    runtime.finishRegistration();

    const missing = engine.PersistentId{ .namespace = 86, .local = 999 };
    const allocation_count = failing.alloc_index;
    failing.fail_index = allocation_count;
    for (0..max_pending_commands) |_| {
        try feature.enqueue(.{ .actions = .{ .id = missing, .facing_yaw = 0 } });
    }
    try std.testing.expectError(
        error.CharacterCommandQueueFull,
        feature.enqueue(.{ .spawn = .{ .request_id = 900, .position = .{ 0, 0, 0 } } }),
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
        error.CharacterCommandQueueFull,
        feature.enqueue(.{ .spawn = .{ .request_id = 901, .position = .{ 0, 0, 0 } } }),
    );
    try std.testing.expectEqual(@as(u64, 2), feature.diagnostics().commands.rejected);

    for (0..max_outcomes) |_| {
        const outcome = feature.pollOutcome() orelse return error.MissingOutcome;
        switch (outcome) {
            .rejected => |rejected| {
                try std.testing.expectEqual(CommandKind.actions, rejected.command);
                try std.testing.expectEqual(RejectionReason.character_not_found, rejected.reason);
                try std.testing.expectEqual(missing, rejected.id.?);
            },
            else => return error.UnexpectedOutcome,
        }
    }
    try std.testing.expect(feature.pollOutcome() == null);

    try feature.enqueue(.{ .spawn = .{
        .request_id = 902,
        .position = .{ 0, 0, 0 },
    } });
    try runtime.tick();
    const spawned = switch (feature.pollOutcome() orelse return error.MissingOutcome) {
        .spawned => |value| value,
        else => return error.UnexpectedOutcome,
    };
    try std.testing.expectEqual(@as(u64, 902), spawned.request_id);
    _ = feature.pollEvent() orelse return error.MissingEvent;
    try feature.enqueue(.{ .actions = .{ .id = spawned.id, .facing_yaw = 0.25 } });
    try runtime.tick();
    try std.testing.expect(feature.pollOutcome() == null);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), (try feature.view(spawned.id)).facing_yaw, 0.0001);
    try std.testing.expectEqual(allocation_count, failing.alloc_index);
}

test "character event saturation drops exactly and accepts production events after drain" {
    var runtime = try engine.Runtime.init(std.testing.allocator, .{
        .namespace = 87,
        .fixed_delta_seconds = 1.0 / 120.0,
    });
    defer runtime.deinit();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var controllers = FakeControllers{};
    var feature = try TestFeature.init(
        failing.allocator(),
        &runtime,
        &controllers,
        .{},
    );
    defer feature.deinit();
    var registry = runtime.registry();
    try feature.register(&registry);
    runtime.finishRegistration();

    const allocation_count = failing.alloc_index;
    failing.fail_index = allocation_count;
    try feature.enqueue(.{ .spawn = .{
        .request_id = 1,
        .position = .{ 0, 0, 0 },
    } });
    try runtime.tick();
    const id = feature.pollOutcome().?.spawned.id;

    for (0..max_events) |index| {
        const airborne = index % 2 == 0;
        controllers.state.position[1] = if (airborne) 1 else 0;
        controllers.state.velocity = .{ 0, 0, 0 };
        controllers.state.ground_state = .in_air;
        try runtime.tick();
    }

    var diagnostics_value = feature.diagnostics();
    try std.testing.expectEqual(@as(u32, max_events), diagnostics_value.events.occupancy);
    try std.testing.expectEqual(@as(u32, max_events), diagnostics_value.events.high_water);
    try std.testing.expectEqual(@as(?u32, max_events), diagnostics_value.events.capacity);
    try std.testing.expectEqual(@as(u64, 1), diagnostics_value.events.rejected);
    try std.testing.expectEqual(@as(u64, 1), diagnostics_value.events_dropped);

    for (0..max_events) |index| {
        const event = feature.pollEvent() orelse return error.MissingEvent;
        const changed = event.ground_state_changed;
        try std.testing.expectEqual(id, changed.id);
        const expected_previous: engine.physics.GroundState = if (index % 2 == 0)
            .in_air
        else
            .on_ground;
        const expected_current: engine.physics.GroundState = if (index % 2 == 0)
            .on_ground
        else
            .in_air;
        try std.testing.expectEqual(expected_previous, changed.previous);
        try std.testing.expectEqual(expected_current, changed.current);
    }
    try std.testing.expect(feature.pollEvent() == null);

    controllers.state.position[1] = 1;
    controllers.state.velocity = .{ 0, 0, 0 };
    controllers.state.ground_state = .in_air;
    try runtime.tick();
    const recovered = (feature.pollEvent() orelse return error.MissingEvent).ground_state_changed;
    try std.testing.expectEqual(engine.physics.GroundState.on_ground, recovered.previous);
    try std.testing.expectEqual(engine.physics.GroundState.in_air, recovered.current);
    diagnostics_value = feature.diagnostics();
    try std.testing.expectEqual(@as(u64, 1), diagnostics_value.events_dropped);
    try std.testing.expectEqual(@as(u32, 0), diagnostics_value.events.occupancy);
    try std.testing.expectEqual(allocation_count, failing.alloc_index);
}

test "character logical state covers entities and queued semantic actions" {
    var runtime = try engine.Runtime.init(std.testing.allocator, .{
        .namespace = 50,
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
        .position = .{ 1, 2, 3 },
        .facing_yaw = 0.25,
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
    var repeated_writer = engine.contracts.replay.Writer.init();
    try feature.writeLogicalState(&repeated_writer, &scratch);
    try std.testing.expectEqual(first, repeated_writer.final());

    try feature.enqueue(.{ .actions = .{
        .id = scratch[0],
        .move = .{ 0.5, -0.25 },
        .facing_yaw = -0.5,
        .jump_pressed = true,
    } });
    var queued_writer = engine.contracts.replay.Writer.init();
    try feature.writeLogicalState(&queued_writer, &scratch);
    const queued = queued_writer.final();
    try std.testing.expect(!std.mem.eql(u8, &first, &queued));
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

    try drivers.beginDriving(character_id, vehicle_id);
    try drivers.abandonDriving(character_id, vehicle_id);
    const abandoned = (try drivers.driverState(character_id)).?;
    try std.testing.expectEqual(driver_contract.DriverMode.on_foot, abandoned.mode);
    try std.testing.expectEqual(@as(usize, 3), controllers.relocate_calls);
}

test "carrier access is atomic and CharacterV1 restores with empty carry state" {
    const character_id = engine.PersistentId{ .namespace = 51, .local = 10 };
    const item_id = engine.PersistentId{ .namespace = 51, .local = 20 };
    const other_item_id = engine.PersistentId{ .namespace = 51, .local = 21 };
    var record: CharacterV1 = undefined;

    {
        var runtime = try engine.Runtime.init(std.testing.allocator, .{
            .namespace = 51,
            .fixed_delta_seconds = 1.0 / 120.0,
            .next_local_id = 11,
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
        try feature.restoreRecords(&.{.{
            .id = character_id,
            .position = .{ 1, 2, 3 },
            .velocity = .{ 0, 0, 0 },
            .facing_yaw = 0.25,
        }});
        runtime.finishRegistration();

        var carriers = feature.carrierAccess();
        const initial = (try carriers.carryState(character_id)) orelse
            return error.ExpectedCarrier;
        try initial.validate();
        try std.testing.expectEqual(interaction_contract.CarrierMobility.on_foot, initial.mobility);
        try std.testing.expect(initial.carry_mode == .empty);
        try std.testing.expectEqual([3]f32{ 1, 2, 3 }, initial.pose.position);
        try std.testing.expect((try carriers.carryState(.{
            .namespace = 51,
            .local = 999,
        })) == null);

        var scratch: [1]engine.PersistentId = undefined;
        var before_writer = engine.contracts.replay.Writer.init();
        try feature.writeLogicalState(&before_writer, &scratch);
        const before_digest = before_writer.final();

        try carriers.beginCarry(character_id, item_id);
        const holding = (try carriers.carryState(character_id)).?;
        try std.testing.expectEqualDeep(item_id, holding.carry_mode.holding);
        try std.testing.expectEqualDeep(item_id, holding.heldItem().?);
        try std.testing.expectError(
            error.CharacterAlreadyCarrying,
            carriers.beginCarry(character_id, other_item_id),
        );
        try std.testing.expectError(
            error.CharacterCarryingDifferentItem,
            carriers.endCarry(character_id, other_item_id),
        );
        try std.testing.expectEqualDeep(
            item_id,
            (try carriers.carryState(character_id)).?.carry_mode.holding,
        );

        var after_writer = engine.contracts.replay.Writer.init();
        try feature.writeLogicalState(&after_writer, &scratch);
        try std.testing.expect(!std.mem.eql(
            u8,
            &before_digest,
            &after_writer.final(),
        ));

        var drivers = feature.driverAccess();
        const vehicle_id = engine.PersistentId{ .namespace = 51, .local = 30 };
        try std.testing.expectError(
            error.CharacterCarrying,
            drivers.beginDriving(character_id, vehicle_id),
        );
        try feature.enqueue(.{ .despawn = .{ .id = character_id } });
        try runtime.tick();
        try std.testing.expectEqual(
            RejectionReason.carrying,
            feature.pollOutcome().?.rejected.reason,
        );
        try std.testing.expect(controllers.active);

        carriers.cancelBeginCarry(character_id, item_id);
        try std.testing.expect((try carriers.carryState(character_id)).?.carry_mode == .empty);
        try drivers.beginDriving(character_id, vehicle_id);
        try std.testing.expectError(
            error.CharacterDriving,
            carriers.beginCarry(character_id, item_id),
        );
        drivers.cancelDriving(character_id, vehicle_id);

        try carriers.beginCarry(character_id, item_id);
        try carriers.endCarry(character_id, item_id);
        try std.testing.expect((try carriers.carryState(character_id)).?.carry_mode == .empty);

        const records = try feature.snapshotRecords(std.testing.allocator);
        defer std.testing.allocator.free(records);
        try std.testing.expectEqual(@as(usize, 1), records.len);
        record = records[0];
        try std.testing.expect(!@hasField(CharacterV1, "held_item"));
        try std.testing.expect(!@hasField(CharacterV1, "carry_mode"));
    }

    var runtime = try engine.Runtime.init(std.testing.allocator, .{
        .namespace = 51,
        .fixed_delta_seconds = 1.0 / 120.0,
        .next_local_id = 11,
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
    try feature.restoreRecords(&.{record});
    runtime.finishRegistration();
    var carriers = feature.carrierAccess();
    try std.testing.expect((try carriers.carryState(character_id)).?.carry_mode == .empty);
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
