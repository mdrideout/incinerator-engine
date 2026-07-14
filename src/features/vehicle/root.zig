//! VehicleFeature: one conventional four-wheel car and one driver seat.

const std = @import("std");
const engine = @import("incinerator_engine");
const driver_contract = @import("driver_contract");

const logical_state_domain = "incinerator.vehicle.logical";
const logical_state_schema: u16 = 1;

/// Per-world authority budgets. Commands reserve their possible outcome;
/// occupancy events are observational and use bounded best-effort delivery.
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
    chassis_mesh: engine.rendering.MeshHandle = .invalid,
    chassis_material: engine.rendering.MaterialHandle = .invalid,
    wheel_mesh: engine.rendering.MeshHandle = .invalid,
    wheel_material: engine.rendering.MaterialHandle = .invalid,
};

/// Simulation-relevant tuning shared by every S2 vehicle instance.
/// Per-instance chassis and wheel dynamics are supplied at spawn/restore.
pub const VehicleTuning = struct {
    chassis_half_extents: [3]f32 = .{ 0.9, 0.25, 2.0 },
    center_of_mass_offset: [3]f32 = .{ 0, -0.25, 0 },
    mass: f32 = 1_500,
    wheel_attachment_positions: [engine.physics.vehicle_wheel_count][3]f32 = .{
        .{ -0.8, -0.18, -1.4 },
        .{ 0.8, -0.18, -1.4 },
        .{ -0.8, -0.18, 1.4 },
        .{ 0.8, -0.18, 1.4 },
    },
    wheel_radius: f32 = 0.3,
    wheel_width: f32 = 0.2,
    suspension_min_length: f32 = 0.2,
    suspension_max_length: f32 = 0.5,
    suspension_frequency: f32 = 1.5,
    suspension_damping: f32 = 0.5,
    max_steer_radians: f32 = std.math.degreesToRadians(30.0),
    max_brake_torque: f32 = 1_500,
    max_hand_brake_torque: f32 = 4_000,
    front_differential_ratio: f32 = 3.42,
    front_limited_slip_ratio: f32 = 1.4,
    max_pitch_roll_radians: f32 = std.math.degreesToRadians(60.0),
    wheel_collision_max_slope_radians: f32 = std.math.degreesToRadians(60.0),

    pub fn validate(self: VehicleTuning) !void {
        try self.desc(.{}, zeroWheelDynamics()).validate();
    }

    fn desc(
        self: VehicleTuning,
        chassis: engine.physics.BodyState,
        wheel_dynamics: [engine.physics.vehicle_wheel_count]engine.physics.VehicleWheelDynamics,
    ) engine.physics.VehicleDesc {
        return .{
            .chassis = chassis,
            .chassis_half_extents = self.chassis_half_extents,
            .center_of_mass_offset = self.center_of_mass_offset,
            .mass = self.mass,
            .wheel_attachment_positions = self.wheel_attachment_positions,
            .initial_wheel_dynamics = wheel_dynamics,
            .wheel_radius = self.wheel_radius,
            .wheel_width = self.wheel_width,
            .suspension_min_length = self.suspension_min_length,
            .suspension_max_length = self.suspension_max_length,
            .suspension_frequency = self.suspension_frequency,
            .suspension_damping = self.suspension_damping,
            .max_steer_radians = self.max_steer_radians,
            .max_brake_torque = self.max_brake_torque,
            .max_hand_brake_torque = self.max_hand_brake_torque,
            .front_differential_ratio = self.front_differential_ratio,
            .front_limited_slip_ratio = self.front_limited_slip_ratio,
            .max_pitch_roll_radians = self.max_pitch_roll_radians,
            .wheel_collision_max_slope_radians = self.wheel_collision_max_slope_radians,
        };
    }
};

pub const Config = struct {
    tuning: VehicleTuning = .{},
    max_entry_distance: f32 = 3.0,
    exit_offset: [3]f32 = .{ 1.5, 0, 0 },
    max_vehicles: usize = 1,
    assets: Assets = .{},

    pub fn validate(self: Config) !void {
        if (self.max_vehicles == 0) return error.InvalidVehicleLimit;
        try self.tuning.validate();
        if (!std.math.isFinite(self.max_entry_distance) or self.max_entry_distance < 0) {
            return error.InvalidVehicleEntryDistance;
        }
        try engine.transform.validateFiniteVector(self.exit_offset);
    }
};

/// Feature-owned authoritative tuning. Host capacity and presentation handles
/// are deliberately excluded from persistence.
pub const VehicleTuningV1 = struct {
    chassis_half_extents: [3]f32,
    center_of_mass_offset: [3]f32,
    mass: f32,
    wheel_attachment_positions: [engine.physics.vehicle_wheel_count][3]f32,
    wheel_radius: f32,
    wheel_width: f32,
    suspension_min_length: f32,
    suspension_max_length: f32,
    suspension_frequency: f32,
    suspension_damping: f32,
    max_steer_radians: f32,
    max_brake_torque: f32,
    max_hand_brake_torque: f32,
    front_differential_ratio: f32,
    front_limited_slip_ratio: f32,
    max_pitch_roll_radians: f32,
    wheel_collision_max_slope_radians: f32,

    pub fn fromTuning(tuning: VehicleTuning) VehicleTuningV1 {
        return .{
            .chassis_half_extents = tuning.chassis_half_extents,
            .center_of_mass_offset = tuning.center_of_mass_offset,
            .mass = tuning.mass,
            .wheel_attachment_positions = tuning.wheel_attachment_positions,
            .wheel_radius = tuning.wheel_radius,
            .wheel_width = tuning.wheel_width,
            .suspension_min_length = tuning.suspension_min_length,
            .suspension_max_length = tuning.suspension_max_length,
            .suspension_frequency = tuning.suspension_frequency,
            .suspension_damping = tuning.suspension_damping,
            .max_steer_radians = tuning.max_steer_radians,
            .max_brake_torque = tuning.max_brake_torque,
            .max_hand_brake_torque = tuning.max_hand_brake_torque,
            .front_differential_ratio = tuning.front_differential_ratio,
            .front_limited_slip_ratio = tuning.front_limited_slip_ratio,
            .max_pitch_roll_radians = tuning.max_pitch_roll_radians,
            .wheel_collision_max_slope_radians = tuning.wheel_collision_max_slope_radians,
        };
    }

    pub fn toTuning(self: VehicleTuningV1) !VehicleTuning {
        const tuning = VehicleTuning{
            .chassis_half_extents = self.chassis_half_extents,
            .center_of_mass_offset = self.center_of_mass_offset,
            .mass = self.mass,
            .wheel_attachment_positions = self.wheel_attachment_positions,
            .wheel_radius = self.wheel_radius,
            .wheel_width = self.wheel_width,
            .suspension_min_length = self.suspension_min_length,
            .suspension_max_length = self.suspension_max_length,
            .suspension_frequency = self.suspension_frequency,
            .suspension_damping = self.suspension_damping,
            .max_steer_radians = self.max_steer_radians,
            .max_brake_torque = self.max_brake_torque,
            .max_hand_brake_torque = self.max_hand_brake_torque,
            .front_differential_ratio = self.front_differential_ratio,
            .front_limited_slip_ratio = self.front_limited_slip_ratio,
            .max_pitch_roll_radians = self.max_pitch_roll_radians,
            .wheel_collision_max_slope_radians = self.wheel_collision_max_slope_radians,
        };
        try tuning.validate();
        return tuning;
    }
};

pub const VehicleConfigV1 = struct {
    tuning: VehicleTuningV1,
    max_entry_distance: f32,
    exit_offset: [3]f32,

    pub fn fromConfig(config: Config) VehicleConfigV1 {
        return .{
            .tuning = VehicleTuningV1.fromTuning(config.tuning),
            .max_entry_distance = config.max_entry_distance,
            .exit_offset = config.exit_offset,
        };
    }

    pub fn toConfig(
        self: VehicleConfigV1,
        max_vehicles: usize,
        assets: Assets,
    ) !Config {
        const config = Config{
            .tuning = try self.tuning.toTuning(),
            .max_entry_distance = self.max_entry_distance,
            .exit_offset = self.exit_offset,
            .max_vehicles = max_vehicles,
            .assets = assets,
        };
        try config.validate();
        return config;
    }

    pub fn validate(self: VehicleConfigV1) !void {
        _ = try self.toConfig(1, .{});
    }
};

pub const SpawnVehicle = struct {
    request_id: u64,
    chassis: engine.physics.BodyState = .{},
};

pub const EnterVehicle = struct {
    vehicle_id: engine.PersistentId,
    driver_id: engine.PersistentId,
};

/// One high-level control sample for one fixed simulation tick.
pub const DriveVehicle = struct {
    vehicle_id: engine.PersistentId,
    driver_id: engine.PersistentId,
    input: engine.physics.VehicleInput = .{},
};

pub const ExitVehicle = struct {
    vehicle_id: engine.PersistentId,
    driver_id: engine.PersistentId,
};

/// Teardown-only release after every collision-safe exit candidate is blocked.
/// The caller must immediately despawn the hidden driver.
pub const AbandonVehicle = struct {
    vehicle_id: engine.PersistentId,
    driver_id: engine.PersistentId,
};

pub const DespawnVehicle = struct { id: engine.PersistentId };

pub const Command = union(enum) {
    spawn: SpawnVehicle,
    enter: EnterVehicle,
    drive: DriveVehicle,
    exit: ExitVehicle,
    abandon: AbandonVehicle,
    despawn: DespawnVehicle,
};

pub const Spawned = struct {
    request_id: u64,
    id: engine.PersistentId,
};

pub const DriverTransition = struct {
    vehicle_id: engine.PersistentId,
    driver_id: engine.PersistentId,
};

pub const DriveApplied = struct {
    vehicle_id: engine.PersistentId,
    driver_id: engine.PersistentId,
    input: engine.physics.VehicleInput,
};

pub const Exited = struct {
    vehicle_id: engine.PersistentId,
    driver_id: engine.PersistentId,
    exit_pose: engine.physics.Pose,
};

pub const CommandKind = enum { spawn, enter, drive, exit, abandon, despawn };
pub const RejectionReason = enum {
    capacity_reached,
    vehicle_not_found,
    not_owned,
    driver_not_found,
    driver_not_on_foot,
    driver_carrying,
    seat_occupied,
    too_far,
    wrong_driver,
    exit_blocked,
    occupied,
};

pub const CommandRejected = struct {
    command: CommandKind,
    reason: RejectionReason,
    request_id: ?u64 = null,
    vehicle_id: ?engine.PersistentId = null,
    driver_id: ?engine.PersistentId = null,
};

pub const Outcome = union(enum) {
    spawned: Spawned,
    entered: DriverTransition,
    drive_applied: DriveApplied,
    exited: Exited,
    abandoned: DriverTransition,
    despawned: engine.PersistentId,
    rejected: CommandRejected,
};

pub const OccupancyChanged = struct {
    vehicle_id: engine.PersistentId,
    previous: ?engine.PersistentId,
    current: ?engine.PersistentId,
};

pub const Event = union(enum) {
    occupancy_changed: OccupancyChanged,
};

pub const VehicleView = struct {
    id: engine.PersistentId,
    state: engine.physics.VehicleState,
    input: engine.physics.VehicleInput,
    driver_id: ?engine.PersistentId,
};

pub const WheelDraw = struct {
    index: engine.physics.VehicleWheelIndex,
    pose: engine.physics.Pose,
    radius: f32,
    width: f32,
    mesh: engine.rendering.MeshHandle,
    material: engine.rendering.MaterialHandle,
};

/// Immutable presentation snapshot. Wheel ordering has fixed semantic meaning.
pub const VehicleDraw = struct {
    persistent_id: engine.PersistentId,
    chassis_pose: engine.physics.Pose,
    chassis_half_extents: [3]f32,
    chassis_mesh: engine.rendering.MeshHandle,
    chassis_material: engine.rendering.MaterialHandle,
    wheels: [engine.physics.vehicle_wheel_count]WheelDraw,
};

pub const Diagnostics = struct {
    active_count: u32,
    commands: engine.contracts.diagnostics.QueueStats,
    outcomes: engine.contracts.diagnostics.QueueStats,
    events: engine.contracts.diagnostics.QueueStats,
    events_dropped: u64,
};

pub const VehicleWheelV1 = struct {
    rotation_angle: f32,
    angular_velocity: f32,
};

pub const VehiclePoseV1 = struct {
    position: [3]f32,
    rotation: [4]f32,

    pub fn fromPose(pose: engine.physics.Pose) VehiclePoseV1 {
        return .{ .position = pose.position, .rotation = pose.rotation };
    }

    pub fn toPose(self: VehiclePoseV1) engine.physics.Pose {
        return .{ .position = self.position, .rotation = self.rotation };
    }
};

pub const VehicleInputV1 = struct {
    throttle: f32,
    steering: f32,
    brake: f32,
    hand_brake: f32,

    pub fn fromInput(input: engine.physics.VehicleInput) VehicleInputV1 {
        return .{
            .throttle = input.throttle,
            .steering = input.steering,
            .brake = input.brake,
            .hand_brake = input.hand_brake,
        };
    }

    pub fn toInput(self: VehicleInputV1) engine.physics.VehicleInput {
        return .{
            .throttle = self.throttle,
            .steering = self.steering,
            .brake = self.brake,
            .hand_brake = self.hand_brake,
        };
    }
};

/// Logical vehicle reconstruction record. Backend drivetrain/contact caches and
/// runtime handles are intentionally absent.
pub const VehicleV1 = struct {
    id: engine.PersistentId,
    chassis_pose: VehiclePoseV1,
    linear_velocity: [3]f32,
    angular_velocity: [3]f32,
    wheels: [engine.physics.vehicle_wheel_count]VehicleWheelV1,
    input: VehicleInputV1,
    driver_id: ?engine.PersistentId,
};

pub fn validateRecords(records: []const VehicleV1, max_vehicles: usize) !void {
    if (records.len > max_vehicles) return error.TooManyVehicles;
    for (records, 0..) |record, index| {
        try validateRecord(record);
        for (records[0..index]) |earlier| {
            if (std.meta.eql(earlier.id, record.id)) return error.DuplicatePersistentId;
            if (record.driver_id != null and earlier.driver_id != null and
                std.meta.eql(record.driver_id.?, earlier.driver_id.?))
            {
                return error.DuplicateVehicleDriver;
            }
        }
    }
}

fn diagnosticsCount(value: usize) u32 {
    return std.math.cast(u32, value) orelse std.math.maxInt(u32);
}

const FixedQueue = engine.BoundedQueue;

pub fn validateRecord(record: VehicleV1) !void {
    try record.id.validate();
    const chassis_pose = record.chassis_pose.toPose();
    try validateCanonicalChassisPose(chassis_pose);
    try (engine.physics.BodyState{
        .pose = chassis_pose,
        .velocity = .{
            .linear = record.linear_velocity,
            .angular = record.angular_velocity,
        },
    }).validate();
    for (record.wheels) |wheel| {
        if (!std.math.isFinite(wheel.angular_velocity)) {
            return error.NonFiniteVehicleWheelDynamics;
        }
        const canonical = try engine.physics.canonicalVehicleWheelRotation(
            wheel.rotation_angle,
        );
        if (@as(u32, @bitCast(canonical)) != @as(u32, @bitCast(wheel.rotation_angle))) {
            return error.NonCanonicalVehicleWheelRotation;
        }
    }
    const input = record.input.toInput();
    try input.validate();
    if (record.driver_id == null and !input.isNeutral()) {
        return error.UnoccupiedVehicleInput;
    }
    if (record.driver_id) |driver_id| try driver_id.validate();
}

pub fn Feature(comptime Vehicles: type, comptime DriverAccess: type) type {
    engine.physics.assertVehicleImplementation(Vehicles);
    driver_contract.assertImplementation(DriverAccess);

    return struct {
        const Self = @This();

        const Vehicle = struct {
            chassis_half_extents: [3]f32,
            wheel_radius: f32,
            wheel_width: f32,
        };
        const PhysicsDriven = struct { enabled: bool = true };
        const RuntimeVehicle = struct { handle: Vehicles.Handle };
        const Control = struct {
            input: engine.physics.VehicleInput = .{},
            driver_id: ?engine.PersistentId = null,
        };
        const PoseHistory = struct {
            previous: engine.physics.Pose,
            current: engine.physics.Pose,
        };
        const PresentationHistory = struct {
            chassis: PoseHistory,
            wheels: [engine.physics.vehicle_wheel_count]PoseHistory,
            current_tick: u64,
        };
        /// Preserve an accepted logical reconstruction byte-for-byte until its
        /// first physics publication. A backend may renormalize a quaternion
        /// or rebuild wheel caches during create; that must not make an
        /// immediate save-after-restore change the declared logical record.
        const RestoredLogicalState = struct {
            pending_publication: bool = false,
            chassis: engine.physics.BodyState = .{},
            wheels: [engine.physics.vehicle_wheel_count]VehicleWheelV1 = .{
                .{ .rotation_angle = 0, .angular_velocity = 0 },
                .{ .rotation_angle = 0, .angular_velocity = 0 },
                .{ .rotation_angle = 0, .angular_velocity = 0 },
                .{ .rotation_angle = 0, .angular_velocity = 0 },
            },
        };
        const QueuedCommand = struct {
            command: Command,
            eligible_tick: u64,
        };
        const DriverRollback = struct {
            vehicle_id: engine.PersistentId,
            driver_id: engine.PersistentId,
        };

        allocator: std.mem.Allocator,
        runtime: *engine.Runtime,
        vehicles: *Vehicles,
        drivers: *DriverAccess,
        config: Config,
        pending: std.ArrayListUnmanaged(QueuedCommand) = .empty,
        applying: std.ArrayListUnmanaged(QueuedCommand) = .empty,
        applying_index: usize = 0,
        active: std.ArrayListUnmanaged(engine.RuntimeId) = .empty,
        outcomes: FixedQueue(Outcome, max_outcomes) = .{},
        events: FixedQueue(Event, max_events) = .{},
        presentations: std.ArrayListUnmanaged(VehicleDraw) = .empty,
        commands_high_water: u32 = 0,
        outcomes_high_water: u32 = 0,
        events_high_water: u32 = 0,
        commands_rejected: u64 = 0,
        events_dropped: u64 = 0,

        pub fn init(
            allocator: std.mem.Allocator,
            runtime: *engine.Runtime,
            vehicles: *Vehicles,
            drivers: *DriverAccess,
            config: Config,
        ) !Self {
            try config.validate();
            var self = Self{
                .allocator = allocator,
                .runtime = runtime,
                .vehicles = vehicles,
                .drivers = drivers,
                .config = config,
            };
            errdefer self.pending.deinit(allocator);
            errdefer self.applying.deinit(allocator);
            errdefer self.active.deinit(allocator);
            errdefer self.presentations.deinit(allocator);
            try self.pending.ensureTotalCapacityPrecise(allocator, max_pending_commands);
            try self.applying.ensureTotalCapacityPrecise(allocator, max_pending_commands);
            try self.active.ensureTotalCapacityPrecise(allocator, config.max_vehicles);
            try self.presentations.ensureTotalCapacityPrecise(
                allocator,
                config.max_vehicles,
            );
            return self;
        }

        pub fn register(self: *Self, registry: *engine.FeatureRegistry) !void {
            try registry.registerComponent(Vehicle);
            try registry.registerComponent(PhysicsDriven);
            try registry.registerComponent(RuntimeVehicle);
            try registry.registerComponent(Control);
            try registry.registerComponent(PresentationHistory);
            try registry.registerComponent(RestoredLogicalState);
            try registry.addSystem(.commands, "vehicle.apply_commands", self, applyCommandsSystem);
            try registry.addSystem(.pre_physics, "vehicle.apply_input", self, applyInputSystem);
            try registry.addSystem(.post_physics, "vehicle.publish_physics", self, publishPhysicsSystem);
        }

        pub fn deinit(self: *Self) void {
            while (self.active.items.len > 0) {
                const runtime_id = self.active.items[self.active.items.len - 1];
                if (self.runtime.get(runtime_id, RuntimeVehicle)) |vehicle| {
                    self.destroyVehicleOrPanic(vehicle.handle);
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
                return error.VehicleCommandQueueFull;
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

        /// Append the complete backend-neutral vehicle state in persistent-ID
        /// order. Sorting uses caller-owned scratch and does not allocate.
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
                    return error.VehicleIdentityInvariantBroken;
                const vehicle = self.runtime.get(runtime_id, Vehicle) orelse
                    return error.VehicleFeatureNotOwned;
                const authority = self.runtime.get(runtime_id, PhysicsDriven) orelse
                    return error.VehicleAuthorityInvariantBroken;
                const live = self.runtime.get(runtime_id, RuntimeVehicle) orelse
                    return error.VehicleHandleInvariantBroken;
                const control = self.runtime.get(runtime_id, Control) orelse
                    return error.VehicleControlInvariantBroken;
                const restored = self.runtime.get(runtime_id, RestoredLogicalState) orelse
                    return error.VehicleRestoreStateInvariantBroken;
                const state = try canonicalState(try self.vehicleStateFromPort(live.handle));

                writePersistentId(writer, id);
                try writeVector3(writer, vehicle.chassis_half_extents);
                try writer.writeF32(vehicle.wheel_radius);
                try writer.writeF32(vehicle.wheel_width);
                writer.writeBool(authority.enabled);
                try writeVehicleState(writer, state);
                try writeVehicleInput(writer, control.input);
                writeOptionalPersistentId(writer, control.driver_id);

                // This transition flag and payload can affect an immediate
                // snapshot before the first backend publication.
                writer.writeBool(restored.pending_publication);
                if (restored.pending_publication) {
                    try writeBodyState(writer, restored.chassis);
                    for (restored.wheels) |wheel| {
                        try writer.writeF32(wheel.rotation_angle);
                        try writer.writeF32(wheel.angular_velocity);
                    }
                }
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

        pub fn view(self: *Self, id: engine.PersistentId) !VehicleView {
            const runtime_id = self.runtime.resolve(id) orelse return error.VehicleFeatureNotFound;
            _ = self.runtime.get(runtime_id, Vehicle) orelse return error.VehicleFeatureNotOwned;
            try self.requirePhysicsAuthority(runtime_id);
            const live = self.runtime.get(runtime_id, RuntimeVehicle) orelse
                return error.VehicleHandleInvariantBroken;
            const control = self.runtime.get(runtime_id, Control) orelse
                return error.VehicleControlInvariantBroken;
            return .{
                .id = id,
                .state = try canonicalState(try self.vehicleStateFromPort(live.handle)),
                .input = control.input,
                .driver_id = control.driver_id,
            };
        }

        pub fn extract(self: *Self, alpha: f32) ![]const VehicleDraw {
            if (!std.math.isFinite(alpha)) return error.InvalidInterpolationAlpha;
            self.presentations.clearRetainingCapacity();
            for (self.active.items) |runtime_id| {
                try self.requirePhysicsAuthority(runtime_id);
                const vehicle = self.runtime.get(runtime_id, Vehicle) orelse
                    return error.VehicleFeatureNotOwned;
                const history = self.runtime.get(runtime_id, PresentationHistory) orelse
                    return error.VehiclePresentationInvariantBroken;
                if (history.current_tick != self.runtime.tickIndex()) {
                    return error.VehiclePresentationTickInvariantBroken;
                }
                var wheels: [engine.physics.vehicle_wheel_count]WheelDraw = undefined;
                for (&wheels, 0..) |*draw, index| {
                    draw.* = .{
                        .index = @enumFromInt(index),
                        .pose = try engine.transform.interpolate(
                            history.wheels[index].previous,
                            history.wheels[index].current,
                            alpha,
                        ),
                        .radius = vehicle.wheel_radius,
                        .width = vehicle.wheel_width,
                        .mesh = self.config.assets.wheel_mesh,
                        .material = self.config.assets.wheel_material,
                    };
                }
                self.presentations.appendAssumeCapacity(.{
                    .persistent_id = try self.runtime.identity(runtime_id),
                    .chassis_pose = try engine.transform.interpolate(
                        history.chassis.previous,
                        history.chassis.current,
                        alpha,
                    ),
                    .chassis_half_extents = vehicle.chassis_half_extents,
                    .chassis_mesh = self.config.assets.chassis_mesh,
                    .chassis_material = self.config.assets.chassis_material,
                    .wheels = wheels,
                });
            }
            return self.presentations.items;
        }

        pub fn snapshotRecords(self: *Self, allocator: std.mem.Allocator) ![]VehicleV1 {
            try self.runtime.ensureSnapshotBoundary();
            if (self.hasPendingCommands()) return error.CommandsPending;
            const records = try allocator.alloc(VehicleV1, self.active.items.len);
            errdefer allocator.free(records);
            for (self.active.items, 0..) |runtime_id, index| {
                try self.requirePhysicsAuthority(runtime_id);
                const live = self.runtime.get(runtime_id, RuntimeVehicle) orelse
                    return error.VehicleHandleInvariantBroken;
                const control = self.runtime.get(runtime_id, Control) orelse
                    return error.VehicleControlInvariantBroken;
                const restored = self.runtime.get(runtime_id, RestoredLogicalState) orelse
                    return error.VehicleRestoreStateInvariantBroken;
                var wheels: [engine.physics.vehicle_wheel_count]VehicleWheelV1 = undefined;
                const chassis = if (restored.pending_publication)
                    restored.chassis
                else blk: {
                    const state = try canonicalState(try self.vehicleStateFromPort(live.handle));
                    for (&wheels, 0..) |*wheel, wheel_index| {
                        wheel.* = .{
                            .rotation_angle = state.wheels[wheel_index].rotation_angle,
                            .angular_velocity = state.wheels[wheel_index].angular_velocity,
                        };
                    }
                    break :blk state.chassis;
                };
                if (restored.pending_publication) wheels = restored.wheels;
                const record = VehicleV1{
                    .id = try self.runtime.identity(runtime_id),
                    .chassis_pose = VehiclePoseV1.fromPose(chassis.pose),
                    .linear_velocity = chassis.velocity.linear,
                    .angular_velocity = chassis.velocity.angular,
                    .wheels = wheels,
                    .input = VehicleInputV1.fromInput(control.input),
                    .driver_id = control.driver_id,
                };
                try validateRecord(record);
                records[index] = record;
            }
            std.mem.sort(VehicleV1, records, {}, lessThanRecord);
            return records;
        }

        /// Restore vehicles and then establish validated driver links. All
        /// allocations occur before the first driver transition, and any later
        /// failure unwinds links before destroying recreated vehicles.
        pub fn restoreRecords(self: *Self, records: []const VehicleV1) !void {
            try validateRecords(records, self.config.max_vehicles);
            if (self.active.items.len != 0 or self.hasPendingCommands()) {
                return error.RestoreRequiresEmptyFeature;
            }

            const rollbacks = try self.allocator.alloc(DriverRollback, records.len);
            defer self.allocator.free(rollbacks);
            var rollback_count: usize = 0;
            errdefer {
                self.rollbackDrivers(rollbacks[0..rollback_count]);
                self.rollbackAll();
            }

            for (records) |record| {
                var dynamics: [engine.physics.vehicle_wheel_count]engine.physics.VehicleWheelDynamics = undefined;
                for (&dynamics, 0..) |*wheel, index| {
                    wheel.* = .{
                        .rotation_angle = record.wheels[index].rotation_angle,
                        .angular_velocity = record.wheels[index].angular_velocity,
                    };
                }
                _ = try self.spawnNow(.{
                    .request_id = 0,
                    .chassis = .{
                        .pose = record.chassis_pose.toPose(),
                        .velocity = .{
                            .linear = record.linear_velocity,
                            .angular = record.angular_velocity,
                        },
                    },
                }, dynamics, record.input.toInput(), record.id, false, .{
                    .pending_publication = true,
                    .chassis = .{
                        .pose = record.chassis_pose.toPose(),
                        .velocity = .{
                            .linear = record.linear_velocity,
                            .angular = record.angular_velocity,
                        },
                    },
                    .wheels = record.wheels,
                });
            }

            for (records) |record| {
                const driver_id = record.driver_id orelse continue;
                const driver = (try self.driverStateFromPort(driver_id)) orelse
                    return error.VehicleFeatureDriverNotFound;
                try driver.validate();
                switch (driver.mode) {
                    .on_foot => {},
                    .driving => return error.VehicleFeatureDriverNotOnFoot,
                }
                const runtime_id = self.runtime.resolve(record.id) orelse
                    return error.VehicleRestoreInvariantBroken;
                const control = self.runtime.getMut(runtime_id, Control) orelse
                    return error.VehicleControlInvariantBroken;
                try self.beginDrivingThroughPort(driver_id, record.id);
                rollbacks[rollback_count] = .{
                    .vehicle_id = record.id,
                    .driver_id = driver_id,
                };
                rollback_count += 1;
                control.driver_id = driver_id;
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
                        _ = self.spawnNow(
                            spawn,
                            zeroWheelDynamics(),
                            .{},
                            null,
                            true,
                            null,
                        ) catch |err| switch (err) {
                            error.VehicleFeatureCapacityReached => try self.reject(.{
                                .command = .spawn,
                                .reason = .capacity_reached,
                                .request_id = spawn.request_id,
                            }),
                            else => return err,
                        };
                    },
                    .enter => |enter| self.enterNow(enter) catch |err| switch (err) {
                        error.VehicleFeatureNotFound => try self.rejectFor(.enter, .vehicle_not_found, enter),
                        error.VehicleFeatureNotOwned => try self.rejectFor(.enter, .not_owned, enter),
                        error.VehicleFeatureDriverNotFound => try self.rejectFor(.enter, .driver_not_found, enter),
                        error.VehicleFeatureDriverNotOnFoot => try self.rejectFor(.enter, .driver_not_on_foot, enter),
                        error.VehicleFeatureDriverCarrying => try self.rejectFor(.enter, .driver_carrying, enter),
                        error.VehicleFeatureSeatOccupied => try self.rejectFor(.enter, .seat_occupied, enter),
                        error.VehicleFeatureDriverTooFar => try self.rejectFor(.enter, .too_far, enter),
                        else => return err,
                    },
                    .drive => |drive| self.driveNow(drive) catch |err| switch (err) {
                        error.VehicleFeatureNotFound => try self.rejectFor(.drive, .vehicle_not_found, drive),
                        error.VehicleFeatureNotOwned => try self.rejectFor(.drive, .not_owned, drive),
                        error.VehicleFeatureWrongDriver => try self.rejectFor(.drive, .wrong_driver, drive),
                        else => return err,
                    },
                    .exit => |exit_command| self.exitNow(exit_command) catch |err| switch (err) {
                        error.VehicleFeatureNotFound => try self.rejectFor(.exit, .vehicle_not_found, exit_command),
                        error.VehicleFeatureNotOwned => try self.rejectFor(.exit, .not_owned, exit_command),
                        error.VehicleFeatureDriverNotFound => try self.rejectFor(.exit, .driver_not_found, exit_command),
                        error.VehicleFeatureWrongDriver => try self.rejectFor(.exit, .wrong_driver, exit_command),
                        error.VehicleFeatureExitBlocked => try self.rejectFor(.exit, .exit_blocked, exit_command),
                        else => return err,
                    },
                    .abandon => |abandon| self.abandonNow(abandon) catch |err| switch (err) {
                        error.VehicleFeatureNotFound => try self.rejectFor(.abandon, .vehicle_not_found, abandon),
                        error.VehicleFeatureNotOwned => try self.rejectFor(.abandon, .not_owned, abandon),
                        error.VehicleFeatureDriverNotFound => try self.rejectFor(.abandon, .driver_not_found, abandon),
                        error.VehicleFeatureWrongDriver => try self.rejectFor(.abandon, .wrong_driver, abandon),
                        else => return err,
                    },
                    .despawn => |despawn| self.despawnNow(despawn.id, true) catch |err| switch (err) {
                        error.VehicleFeatureNotFound => try self.reject(.{
                            .command = .despawn,
                            .reason = .vehicle_not_found,
                            .vehicle_id = despawn.id,
                        }),
                        error.VehicleFeatureNotOwned => try self.reject(.{
                            .command = .despawn,
                            .reason = .not_owned,
                            .vehicle_id = despawn.id,
                        }),
                        error.VehicleFeatureOccupied => try self.reject(.{
                            .command = .despawn,
                            .reason = .occupied,
                            .vehicle_id = despawn.id,
                        }),
                        else => return err,
                    },
                }
            }
            self.applying.clearRetainingCapacity();
            self.applying_index = 0;
        }

        fn applyInputSystem(
            raw: *anyopaque,
            _: *engine.Runtime,
            _: engine.TickContext,
        ) !void {
            const self: *Self = @ptrCast(@alignCast(raw));
            for (self.active.items) |runtime_id| {
                try self.requirePhysicsAuthority(runtime_id);
                const live = self.runtime.get(runtime_id, RuntimeVehicle) orelse
                    return error.VehicleHandleInvariantBroken;
                const control = self.runtime.getMut(runtime_id, Control) orelse
                    return error.VehicleControlInvariantBroken;
                try self.setVehicleInputThroughPort(live.handle, control.input);
                // Controls are tick-scoped. A missing sample is neutral rather
                // than a sticky throttle/steering hold.
                control.input = .{};
            }
        }

        fn publishPhysicsSystem(
            raw: *anyopaque,
            _: *engine.Runtime,
            tick: engine.TickContext,
        ) !void {
            const self: *Self = @ptrCast(@alignCast(raw));
            for (self.active.items) |runtime_id| {
                try self.requirePhysicsAuthority(runtime_id);
                const live = self.runtime.get(runtime_id, RuntimeVehicle) orelse
                    return error.VehicleHandleInvariantBroken;
                const history = self.runtime.getMut(runtime_id, PresentationHistory) orelse
                    return error.VehiclePresentationInvariantBroken;
                const restored = self.runtime.getMut(runtime_id, RestoredLogicalState) orelse
                    return error.VehicleRestoreStateInvariantBroken;
                const state = try canonicalState(try self.vehicleStateFromPort(live.handle));
                history.chassis.previous = history.chassis.current;
                history.chassis.current = state.chassis.pose;
                for (&history.wheels, 0..) |*wheel, index| {
                    wheel.previous = wheel.current;
                    wheel.current = state.wheels[index].pose;
                }
                history.current_tick = tick.tick_index;
                restored.pending_publication = false;
            }
        }

        fn spawnNow(
            self: *Self,
            spawn: SpawnVehicle,
            wheel_dynamics: [engine.physics.vehicle_wheel_count]engine.physics.VehicleWheelDynamics,
            input: engine.physics.VehicleInput,
            restored_id: ?engine.PersistentId,
            emit_outcome: bool,
            restored_logical: ?RestoredLogicalState,
        ) !engine.PersistentId {
            const desc = try self.config.tuning.desc(spawn.chassis, wheel_dynamics).normalized();
            try input.validate();
            if (self.active.items.len >= self.config.max_vehicles) {
                return error.VehicleFeatureCapacityReached;
            }
            if (emit_outcome) std.debug.assert(self.outcomes.len < max_outcomes);

            const runtime_id = if (restored_id) |id|
                try self.runtime.createWithPersistentId(id)
            else
                try self.runtime.create();
            errdefer self.destroyRuntimeOrPanic(runtime_id);
            const id = try self.runtime.identity(runtime_id);
            const handle = try self.createVehicleThroughPort(desc);
            errdefer self.destroyVehicleOrPanic(handle);
            const state = try canonicalState(try self.vehicleStateFromPort(handle));

            try self.runtime.set(runtime_id, Vehicle, .{
                .chassis_half_extents = desc.chassis_half_extents,
                .wheel_radius = desc.wheel_radius,
                .wheel_width = desc.wheel_width,
            });
            try self.runtime.set(runtime_id, PhysicsDriven, .{});
            try self.runtime.set(runtime_id, RuntimeVehicle, .{ .handle = handle });
            try self.runtime.set(runtime_id, Control, .{ .input = input });
            try self.runtime.set(
                runtime_id,
                RestoredLogicalState,
                restored_logical orelse .{},
            );
            var history: PresentationHistory = undefined;
            const initial_chassis_pose = if (restored_logical) |logical|
                logical.chassis.pose
            else
                state.chassis.pose;
            history.chassis = .{
                .previous = initial_chassis_pose,
                .current = initial_chassis_pose,
            };
            for (&history.wheels, 0..) |*wheel, index| {
                wheel.* = .{
                    .previous = state.wheels[index].pose,
                    .current = state.wheels[index].pose,
                };
            }
            history.current_tick = self.runtime.tickIndex();
            try self.runtime.set(runtime_id, PresentationHistory, history);
            self.active.appendAssumeCapacity(runtime_id);
            if (emit_outcome) {
                self.outcomes.pushAssumeCapacity(.{ .spawned = .{
                    .request_id = spawn.request_id,
                    .id = id,
                } });
            }
            return id;
        }

        fn enterNow(self: *Self, enter: EnterVehicle) !void {
            const runtime_id = self.runtime.resolve(enter.vehicle_id) orelse
                return error.VehicleFeatureNotFound;
            _ = self.runtime.get(runtime_id, Vehicle) orelse
                return error.VehicleFeatureNotOwned;
            try self.requirePhysicsAuthority(runtime_id);
            const driver = (try self.driverStateFromPort(enter.driver_id)) orelse
                return error.VehicleFeatureDriverNotFound;
            try driver.validate();
            switch (driver.mode) {
                .on_foot => {},
                .driving => return error.VehicleFeatureDriverNotOnFoot,
            }
            if (driver.carried_item != null) {
                return error.VehicleFeatureDriverCarrying;
            }
            const control = self.runtime.getMut(runtime_id, Control) orelse
                return error.VehicleControlInvariantBroken;
            if (control.driver_id != null) return error.VehicleFeatureSeatOccupied;
            const live = self.runtime.get(runtime_id, RuntimeVehicle) orelse
                return error.VehicleHandleInvariantBroken;
            const state = try canonicalState(try self.vehicleStateFromPort(live.handle));
            if (!withinDistance(
                driver.pose.position,
                state.chassis.pose.position,
                self.config.max_entry_distance,
            )) return error.VehicleFeatureDriverTooFar;

            // The only fallible driver transition follows all validation and
            // capacity reservations. Occupancy commit and emission cannot fail.
            std.debug.assert(self.outcomes.len < max_outcomes);
            try self.beginDrivingThroughPort(enter.driver_id, enter.vehicle_id);
            control.driver_id = enter.driver_id;
            self.outcomes.pushAssumeCapacity(.{ .entered = .{
                .vehicle_id = enter.vehicle_id,
                .driver_id = enter.driver_id,
            } });
            self.emitEvent(.{ .occupancy_changed = .{
                .vehicle_id = enter.vehicle_id,
                .previous = null,
                .current = enter.driver_id,
            } });
        }

        fn driveNow(self: *Self, drive: DriveVehicle) !void {
            const runtime_id = self.runtime.resolve(drive.vehicle_id) orelse
                return error.VehicleFeatureNotFound;
            _ = self.runtime.get(runtime_id, Vehicle) orelse
                return error.VehicleFeatureNotOwned;
            const control = self.runtime.getMut(runtime_id, Control) orelse
                return error.VehicleControlInvariantBroken;
            if (control.driver_id == null or
                !std.meta.eql(control.driver_id.?, drive.driver_id))
            {
                return error.VehicleFeatureWrongDriver;
            }
            std.debug.assert(self.outcomes.len < max_outcomes);
            control.input = drive.input;
            self.outcomes.pushAssumeCapacity(.{ .drive_applied = .{
                .vehicle_id = drive.vehicle_id,
                .driver_id = drive.driver_id,
                .input = drive.input,
            } });
        }

        fn exitNow(self: *Self, exit_command: ExitVehicle) !void {
            const runtime_id = self.runtime.resolve(exit_command.vehicle_id) orelse
                return error.VehicleFeatureNotFound;
            const vehicle = self.runtime.get(runtime_id, Vehicle) orelse
                return error.VehicleFeatureNotOwned;
            try self.requirePhysicsAuthority(runtime_id);
            const control = self.runtime.getMut(runtime_id, Control) orelse
                return error.VehicleControlInvariantBroken;
            if (control.driver_id == null or
                !std.meta.eql(control.driver_id.?, exit_command.driver_id))
            {
                return error.VehicleFeatureWrongDriver;
            }
            const driver = (try self.driverStateFromPort(exit_command.driver_id)) orelse
                return error.VehicleFeatureDriverNotFound;
            try driver.validate();
            switch (driver.mode) {
                .driving => |vehicle_id| if (!std.meta.eql(vehicle_id, exit_command.vehicle_id)) {
                    return error.VehicleFeatureWrongDriver;
                },
                .on_foot => return error.VehicleFeatureWrongDriver,
            }
            const live = self.runtime.get(runtime_id, RuntimeVehicle) orelse
                return error.VehicleHandleInvariantBroken;
            const state = try canonicalState(try self.vehicleStateFromPort(live.handle));
            std.debug.assert(self.outcomes.len < max_outcomes);
            const candidates = exitCandidateOffsets(
                self.config.exit_offset,
                vehicle.chassis_half_extents,
            );
            var selected_exit_pose: ?engine.physics.Pose = null;
            for (candidates) |offset| {
                const candidate = try localOffsetPose(state.chassis.pose, offset);
                const disposition = try self.attemptEndDrivingThroughPort(
                    exit_command.driver_id,
                    exit_command.vehicle_id,
                    candidate,
                );
                if (disposition == .blocked) continue;
                selected_exit_pose = candidate;
                break;
            }
            const exit_pose = selected_exit_pose orelse
                return error.VehicleFeatureExitBlocked;
            control.driver_id = null;
            control.input = .{};
            self.outcomes.pushAssumeCapacity(.{ .exited = .{
                .vehicle_id = exit_command.vehicle_id,
                .driver_id = exit_command.driver_id,
                .exit_pose = exit_pose,
            } });
            self.emitEvent(.{ .occupancy_changed = .{
                .vehicle_id = exit_command.vehicle_id,
                .previous = exit_command.driver_id,
                .current = null,
            } });
        }

        fn despawnNow(self: *Self, id: engine.PersistentId, emit_outcome: bool) !void {
            const runtime_id = self.runtime.resolve(id) orelse
                return error.VehicleFeatureNotFound;
            _ = self.runtime.get(runtime_id, Vehicle) orelse
                return error.VehicleFeatureNotOwned;
            try self.requirePhysicsAuthority(runtime_id);
            const control = self.runtime.get(runtime_id, Control) orelse
                return error.VehicleControlInvariantBroken;
            if (control.driver_id != null) return error.VehicleFeatureOccupied;
            const live = self.runtime.get(runtime_id, RuntimeVehicle) orelse
                return error.VehicleHandleInvariantBroken;
            const index = self.activeIndex(runtime_id) orelse
                return error.VehicleActiveIndexInvariantBroken;
            if (emit_outcome) std.debug.assert(self.outcomes.len < max_outcomes);
            try self.destroyVehicleThroughPort(live.handle);
            self.destroyRuntimeOrPanic(runtime_id);
            _ = self.active.orderedRemove(index);
            if (emit_outcome) self.outcomes.pushAssumeCapacity(.{ .despawned = id });
        }

        fn abandonNow(self: *Self, command: AbandonVehicle) !void {
            const runtime_id = self.runtime.resolve(command.vehicle_id) orelse
                return error.VehicleFeatureNotFound;
            _ = self.runtime.get(runtime_id, Vehicle) orelse
                return error.VehicleFeatureNotOwned;
            const control = self.runtime.getMut(runtime_id, Control) orelse
                return error.VehicleControlInvariantBroken;
            if (control.driver_id == null or
                !std.meta.eql(control.driver_id.?, command.driver_id))
            {
                return error.VehicleFeatureWrongDriver;
            }
            const driver = (try self.driverStateFromPort(command.driver_id)) orelse
                return error.VehicleFeatureDriverNotFound;
            switch (driver.mode) {
                .driving => |vehicle_id| if (!std.meta.eql(vehicle_id, command.vehicle_id)) {
                    return error.VehicleFeatureWrongDriver;
                },
                .on_foot => return error.VehicleFeatureWrongDriver,
            }
            std.debug.assert(self.outcomes.len < max_outcomes);
            try self.abandonDrivingThroughPort(command.driver_id, command.vehicle_id);
            control.driver_id = null;
            control.input = .{};
            self.outcomes.pushAssumeCapacity(.{ .abandoned = .{
                .vehicle_id = command.vehicle_id,
                .driver_id = command.driver_id,
            } });
            self.emitEvent(.{ .occupancy_changed = .{
                .vehicle_id = command.vehicle_id,
                .previous = command.driver_id,
                .current = null,
            } });
        }

        fn rejectFor(
            self: *Self,
            kind: CommandKind,
            reason: RejectionReason,
            command: anytype,
        ) !void {
            try self.reject(.{
                .command = kind,
                .reason = reason,
                .vehicle_id = command.vehicle_id,
                .driver_id = command.driver_id,
            });
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
                    try writeBodyState(writer, spawn.chassis);
                },
                .enter => |enter| {
                    writer.writeU8(2);
                    writePersistentId(writer, enter.vehicle_id);
                    writePersistentId(writer, enter.driver_id);
                },
                .drive => |drive| {
                    writer.writeU8(3);
                    writePersistentId(writer, drive.vehicle_id);
                    writePersistentId(writer, drive.driver_id);
                    try writeVehicleInput(writer, drive.input);
                },
                .exit => |exit_command| {
                    writer.writeU8(4);
                    writePersistentId(writer, exit_command.vehicle_id);
                    writePersistentId(writer, exit_command.driver_id);
                },
                .despawn => |despawn| {
                    writer.writeU8(5);
                    writePersistentId(writer, despawn.id);
                },
                .abandon => |abandon| {
                    writer.writeU8(6);
                    writePersistentId(writer, abandon.vehicle_id);
                    writePersistentId(writer, abandon.driver_id);
                },
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
                return error.VehicleAuthorityInvariantBroken;
            if (!authority.enabled) return error.VehicleAuthorityInvariantBroken;
        }

        // Adapter errors are wrapped before they reach command classification.
        // Zig error identities are global; allowing a port error to propagate
        // unchanged could accidentally match a feature-domain rejection name.
        fn createVehicleThroughPort(
            self: *Self,
            desc: engine.physics.VehicleDesc,
        ) !Vehicles.Handle {
            return self.vehicles.createVehicle(desc) catch
                return error.VehiclePhysicsPortFailure;
        }

        fn destroyVehicleThroughPort(self: *Self, handle: Vehicles.Handle) !void {
            self.vehicles.destroyVehicle(handle) catch
                return error.VehiclePhysicsPortFailure;
        }

        fn setVehicleInputThroughPort(
            self: *Self,
            handle: Vehicles.Handle,
            input: engine.physics.VehicleInput,
        ) !void {
            self.vehicles.setVehicleInput(handle, input) catch
                return error.VehiclePhysicsPortFailure;
        }

        fn vehicleStateFromPort(
            self: *Self,
            handle: Vehicles.Handle,
        ) !engine.physics.VehicleState {
            return self.vehicles.vehicleState(handle) catch
                return error.VehiclePhysicsPortFailure;
        }

        fn driverStateFromPort(
            self: *Self,
            driver_id: engine.PersistentId,
        ) !?driver_contract.DriverState {
            return self.drivers.driverState(driver_id) catch
                return error.VehicleDriverPortFailure;
        }

        fn beginDrivingThroughPort(
            self: *Self,
            driver_id: engine.PersistentId,
            vehicle_id: engine.PersistentId,
        ) !void {
            self.drivers.beginDriving(driver_id, vehicle_id) catch
                return error.VehicleDriverPortFailure;
        }

        fn attemptEndDrivingThroughPort(
            self: *Self,
            driver_id: engine.PersistentId,
            vehicle_id: engine.PersistentId,
            exit_pose: engine.physics.Pose,
        ) !driver_contract.ExitDisposition {
            return self.drivers.attemptEndDriving(
                driver_id,
                vehicle_id,
                exit_pose,
            ) catch return error.VehicleDriverPortFailure;
        }

        fn abandonDrivingThroughPort(
            self: *Self,
            driver_id: engine.PersistentId,
            vehicle_id: engine.PersistentId,
        ) !void {
            self.drivers.abandonDriving(driver_id, vehicle_id) catch
                return error.VehicleDriverPortFailure;
        }

        fn rollbackDrivers(self: *Self, rollbacks: []const DriverRollback) void {
            var index = rollbacks.len;
            while (index > 0) {
                index -= 1;
                const rollback = rollbacks[index];
                self.drivers.cancelDriving(
                    rollback.driver_id,
                    rollback.vehicle_id,
                );
                if (self.runtime.resolve(rollback.vehicle_id)) |runtime_id| {
                    const control = self.runtime.getMut(runtime_id, Control) orelse
                        @panic("vehicle control missing during restore rollback");
                    control.driver_id = null;
                }
            }
        }

        fn rollbackAll(self: *Self) void {
            while (self.active.items.len > 0) {
                const runtime_id = self.active.items[self.active.items.len - 1];
                if (self.runtime.get(runtime_id, RuntimeVehicle)) |vehicle| {
                    self.destroyVehicleOrPanic(vehicle.handle);
                }
                self.destroyRuntimeOrPanic(runtime_id);
                _ = self.active.pop();
            }
        }

        fn destroyVehicleOrPanic(self: *Self, handle: Vehicles.Handle) void {
            self.vehicles.destroyVehicle(handle) catch |err| std.debug.panic(
                "vehicle cleanup invariant failed: {s}",
                .{@errorName(err)},
            );
        }

        fn destroyRuntimeOrPanic(self: *Self, runtime_id: engine.RuntimeId) void {
            self.runtime.destroy(runtime_id) catch |err| std.debug.panic(
                "vehicle entity cleanup invariant failed: {s}",
                .{@errorName(err)},
            );
        }
    };
}

fn validateCommand(command: Command) !void {
    switch (command) {
        .spawn => |spawn| try spawn.chassis.validate(),
        .enter => |enter| {
            try enter.vehicle_id.validate();
            try enter.driver_id.validate();
        },
        .drive => |drive| {
            try drive.vehicle_id.validate();
            try drive.driver_id.validate();
            try drive.input.validate();
        },
        .exit => |exit_command| {
            try exit_command.vehicle_id.validate();
            try exit_command.driver_id.validate();
        },
        .abandon => |abandon| {
            try abandon.vehicle_id.validate();
            try abandon.driver_id.validate();
        },
        .despawn => |despawn| try despawn.id.validate(),
    }
}

fn zeroWheelDynamics() [engine.physics.vehicle_wheel_count]engine.physics.VehicleWheelDynamics {
    return .{ .{}, .{}, .{}, .{} };
}

/// The configured side remains first. The other deterministic candidates are
/// authority policy for ordinary obstruction and disconnect cleanup; callers
/// never choose or trust an exit transform.
fn exitCandidateOffsets(
    primary: [3]f32,
    half_extents: [3]f32,
) [5][3]f32 {
    const side_clearance = @max(@abs(primary[0]), half_extents[0] + 0.75);
    const end_clearance = @max(@abs(primary[2]), half_extents[2] + 0.75);
    const vertical_clearance = @max(primary[1], half_extents[1] + 1.75);
    const alternate_side: f32 = if (primary[0] >= 0) -side_clearance else side_clearance;
    return .{
        primary,
        .{ alternate_side, primary[1], 0 },
        .{ 0, primary[1], end_clearance },
        .{ 0, primary[1], -end_clearance },
        .{ 0, vertical_clearance, 0 },
    };
}

fn canonicalState(input: engine.physics.VehicleState) !engine.physics.VehicleState {
    try input.validate();
    var result = input;
    result.chassis = try input.chassis.normalized();
    result.chassis.pose = try canonicalPose(result.chassis.pose);
    for (&result.wheels) |*wheel| wheel.pose = try canonicalPose(wheel.pose);
    return result;
}

fn writePersistentId(
    writer: *engine.contracts.replay.Writer,
    id: engine.PersistentId,
) void {
    writer.writeU64(id.namespace);
    writer.writeU64(id.local);
}

fn writeOptionalPersistentId(
    writer: *engine.contracts.replay.Writer,
    id: ?engine.PersistentId,
) void {
    writer.writeBool(id != null);
    if (id) |value| writePersistentId(writer, value);
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
    const pose = try canonicalPose(raw);
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
    try state.validate();
    try writePose(writer, state.pose);
    try writeVelocity(writer, state.velocity);
}

fn writeVehicleInput(
    writer: *engine.contracts.replay.Writer,
    input: engine.physics.VehicleInput,
) !void {
    try input.validate();
    try writer.writeF32(input.throttle);
    try writer.writeF32(input.steering);
    try writer.writeF32(input.brake);
    try writer.writeF32(input.hand_brake);
}

fn writeVehicleState(
    writer: *engine.contracts.replay.Writer,
    raw: engine.physics.VehicleState,
) !void {
    const state = try canonicalState(raw);
    try writeBodyState(writer, state.chassis);
    for (state.wheels) |wheel| {
        try writePose(writer, wheel.pose);
        try writer.writeF32(wheel.angular_velocity);
        try writer.writeF32(wheel.rotation_angle);
        try writer.writeF32(wheel.steer_angle);
        try writer.writeF32(wheel.suspension_length);
        writer.writeBool(wheel.has_contact);
    }
    try writer.writeF32(state.engine_rpm);
    writer.writeI32(state.current_gear);
}

fn canonicalPose(raw: engine.physics.Pose) !engine.physics.Pose {
    var result = try raw.normalized();
    if (quaternionNeedsNegation(result.rotation)) {
        for (&result.rotation) |*component| component.* = -component.*;
    }
    for (&result.position) |*component| if (component.* == 0) {
        component.* = 0;
    };
    for (&result.rotation) |*component| if (component.* == 0) {
        component.* = 0;
    };
    return result;
}

fn validateCanonicalChassisPose(pose: engine.physics.Pose) !void {
    try pose.validate();
    for (pose.position) |component| {
        if (@as(u32, @bitCast(component)) == 0x8000_0000) {
            return error.NonCanonicalVehicleChassisPose;
        }
    }
    for (pose.rotation) |component| {
        if (@as(u32, @bitCast(component)) == 0x8000_0000) {
            return error.NonCanonicalVehicleChassisPose;
        }
    }
    if (quaternionNeedsNegation(pose.rotation)) {
        return error.NonCanonicalVehicleChassisPose;
    }
    var length_squared: f64 = 0;
    for (pose.rotation) |component| {
        const wide: f64 = component;
        length_squared += wide * wide;
    }
    if (@abs(length_squared - 1) > 0.00001) {
        return error.NonCanonicalVehicleChassisPose;
    }
}

fn quaternionNeedsNegation(rotation: [4]f32) bool {
    for ([_]usize{ 3, 2, 1, 0 }) |index| {
        if (rotation[index] > 0) return false;
        if (rotation[index] < 0) return true;
    }
    return false;
}

fn withinDistance(a: [3]f32, b: [3]f32, maximum: f32) bool {
    var distance_squared: f64 = 0;
    for (0..3) |axis| {
        const delta: f64 = @as(f64, a[axis]) - @as(f64, b[axis]);
        distance_squared += delta * delta;
    }
    const maximum_wide: f64 = maximum;
    return distance_squared <= maximum_wide * maximum_wide;
}

fn localOffsetPose(chassis: engine.physics.Pose, offset: [3]f32) !engine.physics.Pose {
    const normalized = try chassis.normalized();
    const rotated = rotateVector(normalized.rotation, offset);
    return .{
        .position = .{
            normalized.position[0] + rotated[0],
            normalized.position[1] + rotated[1],
            normalized.position[2] + rotated[2],
        },
        .rotation = normalized.rotation,
    };
}

fn rotateVector(q: [4]f32, v: [3]f32) [3]f32 {
    const t = scaleVector(cross(.{ q[0], q[1], q[2] }, v), 2);
    return addVector(addVector(v, scaleVector(t, q[3])), cross(.{ q[0], q[1], q[2] }, t));
}

fn cross(a: [3]f32, b: [3]f32) [3]f32 {
    return .{
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    };
}

fn scaleVector(value: [3]f32, scale: f32) [3]f32 {
    return .{ value[0] * scale, value[1] * scale, value[2] * scale };
}

fn addVector(a: [3]f32, b: [3]f32) [3]f32 {
    return .{ a[0] + b[0], a[1] + b[1], a[2] + b[2] };
}

fn lessThanRecord(_: void, lhs: VehicleV1, rhs: VehicleV1) bool {
    if (lhs.id.namespace != rhs.id.namespace) return lhs.id.namespace < rhs.id.namespace;
    return lhs.id.local < rhs.id.local;
}

fn lessThanPersistentId(
    _: void,
    lhs: engine.PersistentId,
    rhs: engine.PersistentId,
) bool {
    if (lhs.namespace != rhs.namespace) return lhs.namespace < rhs.namespace;
    return lhs.local < rhs.local;
}

const FakeVehicles = struct {
    pub const Handle = u8;
    const capacity = 8;

    live: [capacity]bool = [_]bool{false} ** capacity,
    states: [capacity]engine.physics.VehicleState = [_]engine.physics.VehicleState{
        emptyVehicleState(),
    } ** capacity,
    inputs: [capacity]engine.physics.VehicleInput = [_]engine.physics.VehicleInput{.{}} ** capacity,
    next_handle: u8 = 0,
    live_count: usize = 0,
    create_calls: usize = 0,
    destroy_calls: usize = 0,
    input_calls: usize = 0,
    state_calls: usize = 0,
    last_input: engine.physics.VehicleInput = .{},
    fail_create_call: ?usize = null,
    fail_create_with_domain_name: bool = false,
    fail_destroy: bool = false,
    fail_input: bool = false,
    fail_state: bool = false,

    pub fn createVehicle(self: *FakeVehicles, raw_desc: engine.physics.VehicleDesc) !Handle {
        self.create_calls += 1;
        if (self.fail_create_with_domain_name) return error.VehicleFeatureCapacityReached;
        if (self.fail_create_call == self.create_calls) return error.InjectedVehicleCreateFailure;
        const desc = try raw_desc.normalized();
        if (self.next_handle >= capacity) return error.FakeVehicleCapacityReached;
        const handle = self.next_handle;
        self.next_handle += 1;
        self.live[handle] = true;
        self.states[handle] = stateFromDesc(desc);
        self.live_count += 1;
        return handle;
    }

    pub fn destroyVehicle(self: *FakeVehicles, handle: Handle) !void {
        if (handle >= capacity or !self.live[handle]) return error.InvalidFakeVehicle;
        self.destroy_calls += 1;
        if (self.fail_destroy) return error.InjectedVehicleDestroyFailure;
        self.live[handle] = false;
        self.live_count -= 1;
    }

    pub fn setVehicleInput(
        self: *FakeVehicles,
        handle: Handle,
        input: engine.physics.VehicleInput,
    ) !void {
        if (handle >= capacity or !self.live[handle]) return error.InvalidFakeVehicle;
        if (self.fail_input) return error.InjectedVehicleInputFailure;
        try input.validate();
        self.input_calls += 1;
        self.inputs[handle] = input;
        self.last_input = input;
    }

    pub fn vehicleState(self: *FakeVehicles, handle: Handle) !engine.physics.VehicleState {
        if (handle >= capacity or !self.live[handle]) return error.InvalidFakeVehicle;
        if (self.fail_state) return error.InjectedVehicleStateFailure;
        self.state_calls += 1;
        return self.states[handle];
    }

    fn stateFromDesc(desc: engine.physics.VehicleDesc) engine.physics.VehicleState {
        var state = emptyVehicleState();
        state.chassis = desc.chassis;
        for (&state.wheels, 0..) |*wheel, index| {
            wheel.pose = .{
                .position = addVector(
                    desc.chassis.pose.position,
                    desc.wheel_attachment_positions[index],
                ),
                .rotation = desc.chassis.pose.rotation,
            };
            wheel.rotation_angle = desc.initial_wheel_dynamics[index].rotation_angle;
            wheel.angular_velocity = desc.initial_wheel_dynamics[index].angular_velocity;
            wheel.suspension_length = desc.suspension_max_length;
        }
        return state;
    }
};

fn emptyVehicleState() engine.physics.VehicleState {
    const wheel = engine.physics.WheelState{
        .pose = .{},
        .angular_velocity = 0,
        .rotation_angle = 0,
        .steer_angle = 0,
        .suspension_length = 0.5,
        .has_contact = false,
    };
    return .{
        .chassis = .{},
        .wheels = .{ wheel, wheel, wheel, wheel },
        .engine_rpm = 0,
        .current_gear = 0,
    };
}

const FakeDrivers = struct {
    const capacity = 8;
    const Entry = struct {
        id: engine.PersistentId = .{ .namespace = 1, .local = 1 },
        state: driver_contract.DriverState = .{ .pose = .{}, .mode = .on_foot },
        live: bool = false,
    };

    entries: [capacity]Entry = [_]Entry{.{}} ** capacity,
    count: usize = 0,
    begin_calls: usize = 0,
    exit_calls: usize = 0,
    abandon_calls: usize = 0,
    fail_begin: bool = false,
    fail_begin_call: ?usize = null,
    fail_begin_with_domain_name: bool = false,
    fail_exit: bool = false,
    block_exit: bool = false,
    blocked_exit_attempts: usize = 0,
    last_exit_pose: ?engine.physics.Pose = null,

    fn add(self: *FakeDrivers, id: engine.PersistentId, pose: engine.physics.Pose) void {
        std.debug.assert(self.count < capacity);
        self.entries[self.count] = .{
            .id = id,
            .state = .{ .pose = pose, .mode = .on_foot },
            .live = true,
        };
        self.count += 1;
    }

    pub fn driverState(
        self: *FakeDrivers,
        id: engine.PersistentId,
    ) !?driver_contract.DriverState {
        const index = self.indexOf(id) orelse return null;
        return self.entries[index].state;
    }

    pub fn beginDriving(
        self: *FakeDrivers,
        driver_id: engine.PersistentId,
        vehicle_id: engine.PersistentId,
    ) !void {
        self.begin_calls += 1;
        if (self.fail_begin_with_domain_name) return error.VehicleFeatureDriverNotFound;
        if (self.fail_begin or self.fail_begin_call == self.begin_calls) {
            return error.InjectedBeginDrivingFailure;
        }
        const index = self.indexOf(driver_id) orelse return error.FakeDriverNotFound;
        switch (self.entries[index].state.mode) {
            .on_foot => {},
            .driving => return error.FakeDriverAlreadyDriving,
        }
        self.entries[index].state.mode = .{ .driving = vehicle_id };
    }

    pub fn attemptEndDriving(
        self: *FakeDrivers,
        driver_id: engine.PersistentId,
        vehicle_id: engine.PersistentId,
        exit_pose: engine.physics.Pose,
    ) !driver_contract.ExitDisposition {
        self.exit_calls += 1;
        if (self.fail_exit) return error.InjectedEndDrivingFailure;
        const index = self.indexOf(driver_id) orelse return error.FakeDriverNotFound;
        switch (self.entries[index].state.mode) {
            .driving => |current| if (!std.meta.eql(current, vehicle_id)) {
                return error.FakeDriverVehicleMismatch;
            },
            .on_foot => return error.FakeDriverNotDriving,
        }
        if (self.block_exit or self.exit_calls <= self.blocked_exit_attempts) return .blocked;
        try exit_pose.validate();
        self.entries[index].state.pose = exit_pose;
        self.entries[index].state.mode = .on_foot;
        self.last_exit_pose = exit_pose;
        return .exited;
    }

    pub fn cancelDriving(
        self: *FakeDrivers,
        driver_id: engine.PersistentId,
        vehicle_id: engine.PersistentId,
    ) void {
        const index = self.indexOf(driver_id) orelse
            @panic("fake restore rollback driver missing");
        switch (self.entries[index].state.mode) {
            .driving => |current| if (!std.meta.eql(current, vehicle_id)) {
                @panic("fake restore rollback vehicle mismatch");
            },
            .on_foot => @panic("fake restore rollback driver already on foot"),
        }
        self.entries[index].state.mode = .on_foot;
    }

    pub fn abandonDriving(
        self: *FakeDrivers,
        driver_id: engine.PersistentId,
        vehicle_id: engine.PersistentId,
    ) !void {
        self.abandon_calls += 1;
        const index = self.indexOf(driver_id) orelse return error.FakeDriverNotFound;
        switch (self.entries[index].state.mode) {
            .driving => |current| if (!std.meta.eql(current, vehicle_id)) {
                return error.FakeDriverVehicleMismatch;
            },
            .on_foot => return error.FakeDriverNotDriving,
        }
        self.entries[index].state.mode = .on_foot;
    }

    fn indexOf(self: *const FakeDrivers, id: engine.PersistentId) ?usize {
        for (self.entries[0..self.count], 0..) |entry, index| {
            if (entry.live and std.meta.eql(entry.id, id)) return index;
        }
        return null;
    }
};

const TestFeature = Feature(FakeVehicles, FakeDrivers);

test "vehicle diagnostics retain unread output and command high-water marks" {
    var runtime = try engine.Runtime.init(std.testing.allocator, .{
        .namespace = 89,
        .fixed_delta_seconds = 1.0 / 120.0,
    });
    defer runtime.deinit();
    var vehicles = FakeVehicles{};
    var drivers = FakeDrivers{};
    var feature = try TestFeature.init(
        std.testing.allocator,
        &runtime,
        &vehicles,
        &drivers,
        .{ .max_vehicles = 2 },
    );
    defer feature.deinit();
    var registry = runtime.registry();
    try feature.register(&registry);
    runtime.finishRegistration();

    try feature.enqueue(.{ .spawn = .{ .request_id = 1 } });
    try feature.enqueue(.{ .spawn = .{ .request_id = 2 } });
    var snapshot = feature.diagnostics();
    try std.testing.expectEqual(@as(u32, 2), snapshot.commands.occupancy);
    try std.testing.expectEqual(@as(u32, 2), snapshot.commands.high_water);
    try std.testing.expectEqual(@as(?u32, max_pending_commands), snapshot.commands.capacity);
    try std.testing.expectEqual(@as(u64, 0), snapshot.commands.rejected);

    try runtime.tick();
    snapshot = feature.diagnostics();
    try std.testing.expectEqual(@as(u32, 2), snapshot.active_count);
    try std.testing.expectEqual(@as(u32, 0), snapshot.commands.occupancy);
    try std.testing.expectEqual(@as(u32, 2), snapshot.outcomes.occupancy);
    try std.testing.expectEqual(@as(u32, 2), snapshot.outcomes.high_water);
    try std.testing.expectEqual(@as(u32, 0), snapshot.events.occupancy);
    try std.testing.expectEqual(@as(u32, 0), snapshot.events.high_water);

    _ = feature.pollOutcome() orelse return error.MissingOutcome;
    snapshot = feature.diagnostics();
    try std.testing.expectEqual(@as(u32, 1), snapshot.outcomes.occupancy);
    try std.testing.expectEqual(@as(u32, 2), snapshot.outcomes.high_water);
}

test "vehicle bounded command reservations drain and recover without allocation" {
    var runtime = try engine.Runtime.init(std.testing.allocator, .{
        .namespace = 95,
        .fixed_delta_seconds = 1.0 / 120.0,
    });
    defer runtime.deinit();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var vehicles = FakeVehicles{};
    var drivers = FakeDrivers{};
    var feature = try TestFeature.init(
        failing.allocator(),
        &runtime,
        &vehicles,
        &drivers,
        .{},
    );
    defer feature.deinit();
    var registry = runtime.registry();
    try feature.register(&registry);
    runtime.finishRegistration();

    const missing_vehicle = engine.PersistentId{ .namespace = 95, .local = 999 };
    const missing_driver = engine.PersistentId{ .namespace = 95, .local = 998 };
    const allocation_count = failing.alloc_index;
    failing.fail_index = allocation_count;
    for (0..max_pending_commands) |_| {
        try feature.enqueue(.{ .drive = .{
            .vehicle_id = missing_vehicle,
            .driver_id = missing_driver,
        } });
    }
    try std.testing.expectError(
        error.VehicleCommandQueueFull,
        feature.enqueue(.{ .spawn = .{ .request_id = 900 } }),
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
        error.VehicleCommandQueueFull,
        feature.enqueue(.{ .spawn = .{ .request_id = 901 } }),
    );
    try std.testing.expectEqual(@as(u64, 2), feature.diagnostics().commands.rejected);

    for (0..max_outcomes) |_| {
        const outcome = feature.pollOutcome() orelse return error.MissingOutcome;
        switch (outcome) {
            .rejected => |rejected| {
                try std.testing.expectEqual(CommandKind.drive, rejected.command);
                try std.testing.expectEqual(RejectionReason.vehicle_not_found, rejected.reason);
                try std.testing.expectEqual(missing_vehicle, rejected.vehicle_id.?);
                try std.testing.expectEqual(missing_driver, rejected.driver_id.?);
            },
            else => return error.UnexpectedOutcome,
        }
    }
    try std.testing.expect(feature.pollOutcome() == null);

    try feature.enqueue(.{ .spawn = .{ .request_id = 902 } });
    try runtime.tick();
    const spawned = switch (feature.pollOutcome() orelse return error.MissingOutcome) {
        .spawned => |value| value,
        else => return error.UnexpectedOutcome,
    };
    try std.testing.expectEqual(@as(u64, 902), spawned.request_id);
    try feature.enqueue(.{ .despawn = .{ .id = spawned.id } });
    try runtime.tick();
    try std.testing.expectEqual(spawned.id, feature.pollOutcome().?.despawned);
    try std.testing.expectEqual(@as(usize, 0), feature.count());
    try std.testing.expectEqual(allocation_count, failing.alloc_index);
}

test "vehicle transition events saturate, drop exactly, and recover after drain" {
    var runtime = try engine.Runtime.init(std.testing.allocator, .{
        .namespace = 96,
        .fixed_delta_seconds = 1.0 / 120.0,
    });
    defer runtime.deinit();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var vehicles = FakeVehicles{};
    var drivers = FakeDrivers{};
    const driver_id = engine.PersistentId{ .namespace = 96, .local = 40 };
    drivers.add(driver_id, .{ .position = .{ 1, 0, 0 } });
    var feature = try TestFeature.init(
        failing.allocator(),
        &runtime,
        &vehicles,
        &drivers,
        .{},
    );
    defer feature.deinit();
    var registry = runtime.registry();
    try feature.register(&registry);
    runtime.finishRegistration();

    const allocation_count = failing.alloc_index;
    failing.fail_index = allocation_count;
    try feature.enqueue(.{ .spawn = .{ .request_id = 1 } });
    try runtime.tick();
    const vehicle_id = feature.pollOutcome().?.spawned.id;

    for (0..max_events + 1) |index| {
        if (index % 2 == 0) {
            try feature.enqueue(.{ .enter = .{
                .vehicle_id = vehicle_id,
                .driver_id = driver_id,
            } });
            try runtime.tick();
            try std.testing.expect(feature.pollOutcome().? == .entered);
        } else {
            try feature.enqueue(.{ .exit = .{
                .vehicle_id = vehicle_id,
                .driver_id = driver_id,
            } });
            try runtime.tick();
            try std.testing.expect(feature.pollOutcome().? == .exited);
        }
    }

    var diagnostics_value = feature.diagnostics();
    try std.testing.expectEqual(@as(u32, max_events), diagnostics_value.events.occupancy);
    try std.testing.expectEqual(@as(u32, max_events), diagnostics_value.events.high_water);
    try std.testing.expectEqual(@as(?u32, max_events), diagnostics_value.events.capacity);
    try std.testing.expectEqual(@as(u64, 1), diagnostics_value.events.rejected);
    try std.testing.expectEqual(@as(u64, 1), diagnostics_value.events_dropped);
    try std.testing.expectEqual(driver_id, (try feature.view(vehicle_id)).driver_id.?);

    for (0..max_events) |index| {
        const changed = (feature.pollEvent() orelse return error.MissingEvent).occupancy_changed;
        try std.testing.expectEqual(vehicle_id, changed.vehicle_id);
        if (index % 2 == 0) {
            try std.testing.expect(changed.previous == null);
            try std.testing.expectEqual(driver_id, changed.current.?);
        } else {
            try std.testing.expectEqual(driver_id, changed.previous.?);
            try std.testing.expect(changed.current == null);
        }
    }
    try std.testing.expect(feature.pollEvent() == null);

    try feature.enqueue(.{ .exit = .{
        .vehicle_id = vehicle_id,
        .driver_id = driver_id,
    } });
    try runtime.tick();
    try std.testing.expect(feature.pollOutcome().? == .exited);
    const recovered = (feature.pollEvent() orelse return error.MissingEvent).occupancy_changed;
    try std.testing.expectEqual(driver_id, recovered.previous.?);
    try std.testing.expect(recovered.current == null);
    diagnostics_value = feature.diagnostics();
    try std.testing.expectEqual(@as(u64, 1), diagnostics_value.events_dropped);
    try std.testing.expectEqual(@as(u32, 0), diagnostics_value.events.occupancy);
    try std.testing.expectEqual(allocation_count, failing.alloc_index);
}

test "vehicle logical state hashes the full canonical backend state" {
    var runtime = try engine.Runtime.init(std.testing.allocator, .{
        .namespace = 90,
        .fixed_delta_seconds = 1.0 / 120.0,
    });
    defer runtime.deinit();
    var vehicles = FakeVehicles{};
    var drivers = FakeDrivers{};
    var feature = try TestFeature.init(
        std.testing.allocator,
        &runtime,
        &vehicles,
        &drivers,
        .{},
    );
    defer feature.deinit();
    var registry = runtime.registry();
    try feature.register(&registry);
    runtime.finishRegistration();

    try feature.enqueue(.{ .spawn = .{
        .request_id = 1,
        .chassis = .{ .pose = .{ .rotation = .{ 0, 0, 0, -1 } } },
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

    vehicles.states[0].chassis.pose.position[0] = @bitCast(@as(u32, 0x8000_0000));
    for (&vehicles.states[0].chassis.pose.rotation) |*component| component.* = -component.*;
    for (&vehicles.states[0].wheels) |*wheel| {
        for (&wheel.pose.rotation) |*component| component.* = -component.*;
    }
    var aliased_writer = engine.contracts.replay.Writer.init();
    try feature.writeLogicalState(&aliased_writer, &scratch);
    try std.testing.expectEqual(first, aliased_writer.final());
}

fn testId(namespace: u64, local: u64) engine.PersistentId {
    return .{ .namespace = namespace, .local = local };
}

fn testRecord(namespace: u64, local: u64) VehicleV1 {
    return .{
        .id = testId(namespace, local),
        .chassis_pose = .{
            .position = .{ 0, 0, 0 },
            .rotation = .{ 0, 0, 0, 1 },
        },
        .linear_velocity = .{ 0, 0, 0 },
        .angular_velocity = .{ 0, 0, 0 },
        .wheels = .{
            .{ .rotation_angle = 0, .angular_velocity = 0 },
            .{ .rotation_angle = 0.25, .angular_velocity = 1 },
            .{ .rotation_angle = 1.5, .angular_velocity = -2 },
            .{ .rotation_angle = 6.0, .angular_velocity = 3 },
        },
        .input = .{
            .throttle = 0,
            .steering = 0,
            .brake = 0,
            .hand_brake = 0,
        },
        .driver_id = null,
    };
}

fn expectRejected(
    feature: *TestFeature,
    command: CommandKind,
    reason: RejectionReason,
) !void {
    const outcome = feature.pollOutcome() orelse return error.ExpectedVehicleOutcome;
    const rejection = switch (outcome) {
        .rejected => |value| value,
        else => return error.ExpectedVehicleRejection,
    };
    try std.testing.expectEqual(command, rejection.command);
    try std.testing.expectEqual(reason, rejection.reason);
}

test "vehicle config persistence excludes host policy and assets" {
    const config = Config{
        .max_entry_distance = 4.5,
        .exit_offset = .{ -2, 0.25, 0.5 },
        .max_vehicles = 7,
    };
    const persisted = VehicleConfigV1.fromConfig(config);
    try persisted.validate();
    const restored = try persisted.toConfig(3, .{});
    try std.testing.expect(std.meta.eql(persisted, VehicleConfigV1.fromConfig(restored)));
    try std.testing.expectEqual(@as(usize, 3), restored.max_vehicles);
    try std.testing.expect(!restored.assets.chassis_mesh.isValid());
    try std.testing.expect(!restored.assets.wheel_mesh.isValid());
    try std.testing.expectError(
        error.MissingField,
        std.json.parseFromSlice(VehicleTuningV1, std.testing.allocator, "{}", .{}),
    );
}

test "vehicle records enforce finite canonical wheel dynamics" {
    var record = testRecord(70, 1);
    try validateRecord(record);
    record.chassis_pose.rotation = .{ 0, 0, 0, 2 };
    try std.testing.expectError(error.NonCanonicalVehicleChassisPose, validateRecord(record));
    record.chassis_pose.rotation = .{ 0, 0, 0, 1 };
    record.wheels[0].rotation_angle = std.math.tau;
    try std.testing.expectError(error.NonCanonicalVehicleWheelRotation, validateRecord(record));
    record.wheels[0].rotation_angle = @bitCast(@as(u32, 0x8000_0000));
    try std.testing.expectError(error.NonCanonicalVehicleWheelRotation, validateRecord(record));
    record.wheels[0].rotation_angle = 0;
    record.wheels[1].angular_velocity = std.math.nan(f32);
    try std.testing.expectError(error.NonFiniteVehicleWheelDynamics, validateRecord(record));
    record = testRecord(70, 1);
    record.input.throttle = 1;
    try std.testing.expectError(error.UnoccupiedVehicleInput, validateRecord(record));

    const duplicate = [_]VehicleV1{ testRecord(70, 1), testRecord(70, 1) };
    try std.testing.expectError(error.DuplicatePersistentId, validateRecords(&duplicate, 2));
    try std.testing.expectError(error.TooManyVehicles, validateRecords(duplicate[0..1], 0));
    var duplicate_drivers = [_]VehicleV1{ testRecord(70, 1), testRecord(70, 2) };
    duplicate_drivers[0].driver_id = testId(70, 10);
    duplicate_drivers[1].driver_id = testId(70, 10);
    try std.testing.expectError(
        error.DuplicateVehicleDriver,
        validateRecords(&duplicate_drivers, 2),
    );
    try std.testing.expectError(
        error.MissingField,
        std.json.parseFromSlice(VehiclePoseV1, std.testing.allocator, "{}", .{}),
    );
    try std.testing.expectError(
        error.MissingField,
        std.json.parseFromSlice(VehicleInputV1, std.testing.allocator, "{}", .{}),
    );
}

test "invalid missing foreign-feature and capacity commands reject explicitly" {
    var runtime = try engine.Runtime.init(std.testing.allocator, .{
        .namespace = 80,
        .fixed_delta_seconds = 1.0 / 120.0,
    });
    defer runtime.deinit();
    var vehicles = FakeVehicles{};
    var drivers = FakeDrivers{};
    const driver_id = testId(80, 40);
    drivers.add(driver_id, .{ .position = .{ 1, 0, 0 } });
    var feature = try TestFeature.init(
        std.testing.allocator,
        &runtime,
        &vehicles,
        &drivers,
        .{},
    );
    defer feature.deinit();
    var registry = runtime.registry();
    try feature.register(&registry);
    const foreign_feature_entity = try runtime.create();
    const foreign_feature_id = try runtime.identity(foreign_feature_entity);
    runtime.finishRegistration();

    try std.testing.expectError(error.InvalidIdentityLocal, feature.enqueue(.{ .enter = .{
        .vehicle_id = .{ .namespace = 80, .local = 0 },
        .driver_id = driver_id,
    } }));
    try feature.enqueue(.{ .enter = .{
        .vehicle_id = testId(80, 99),
        .driver_id = driver_id,
    } });
    try feature.enqueue(.{ .enter = .{
        .vehicle_id = foreign_feature_id,
        .driver_id = driver_id,
    } });
    try feature.enqueue(.{ .spawn = .{ .request_id = 1 } });
    try feature.enqueue(.{ .spawn = .{ .request_id = 2 } });
    try runtime.tick();
    try expectRejected(&feature, .enter, .vehicle_not_found);
    try expectRejected(&feature, .enter, .not_owned);
    _ = feature.pollOutcome().?.spawned;
    try expectRejected(&feature, .spawn, .capacity_reached);
    try runtime.destroy(foreign_feature_entity);
}

test "ordered commands transfer authority and missing drive input neutralizes" {
    var runtime = try engine.Runtime.init(std.testing.allocator, .{
        .namespace = 71,
        .fixed_delta_seconds = 1.0 / 120.0,
    });
    defer runtime.deinit();
    var vehicles = FakeVehicles{};
    var drivers = FakeDrivers{};
    const driver_id = testId(71, 40);
    drivers.add(driver_id, .{ .position = .{ 1, 0, 0 } });
    var feature = try TestFeature.init(
        std.testing.allocator,
        &runtime,
        &vehicles,
        &drivers,
        .{},
    );
    defer feature.deinit();
    var registry = runtime.registry();
    try feature.register(&registry);
    runtime.finishRegistration();

    try feature.enqueue(.{ .spawn = .{ .request_id = 9 } });
    try runtime.tick();
    const vehicle_id = feature.pollOutcome().?.spawned.id;
    try std.testing.expect(vehicles.last_input.isNeutral());

    const drive_input = engine.physics.VehicleInput{
        .throttle = 0.75,
        .steering = -0.25,
    };
    try feature.enqueue(.{ .enter = .{ .vehicle_id = vehicle_id, .driver_id = driver_id } });
    try feature.enqueue(.{ .drive = .{
        .vehicle_id = vehicle_id,
        .driver_id = driver_id,
        .input = drive_input,
    } });
    try runtime.tick();
    try std.testing.expectEqual(driver_id, feature.pollOutcome().?.entered.driver_id);
    try std.testing.expect(std.meta.eql(drive_input, feature.pollOutcome().?.drive_applied.input));
    try std.testing.expect(std.meta.eql(drive_input, vehicles.last_input));
    const event = feature.pollEvent().?.occupancy_changed;
    try std.testing.expect(event.previous == null);
    try std.testing.expectEqual(driver_id, event.current.?);

    try runtime.tick();
    try std.testing.expect(vehicles.last_input.isNeutral());
    const view = try feature.view(vehicle_id);
    try std.testing.expect(view.input.isNeutral());

    try feature.enqueue(.{ .exit = .{ .vehicle_id = vehicle_id, .driver_id = driver_id } });
    try feature.enqueue(.{ .despawn = .{ .id = vehicle_id } });
    try runtime.tick();
    try std.testing.expectEqual(driver_id, feature.pollOutcome().?.exited.driver_id);
    try std.testing.expectEqual(vehicle_id, feature.pollOutcome().?.despawned);
    try std.testing.expectEqual(@as(usize, 0), feature.count());
}

test "enter rejects missing far occupied and already-driving characters" {
    var runtime = try engine.Runtime.init(std.testing.allocator, .{
        .namespace = 72,
        .fixed_delta_seconds = 1.0 / 120.0,
    });
    defer runtime.deinit();
    var vehicles = FakeVehicles{};
    var drivers = FakeDrivers{};
    const near = testId(72, 40);
    const far = testId(72, 41);
    const other = testId(72, 42);
    drivers.add(near, .{ .position = .{ 1, 0, 0 } });
    drivers.add(far, .{ .position = .{ 100, 0, 0 } });
    drivers.add(other, .{ .position = .{ 1, 0, 0 } });
    var feature = try TestFeature.init(
        std.testing.allocator,
        &runtime,
        &vehicles,
        &drivers,
        .{ .max_vehicles = 2 },
    );
    defer feature.deinit();
    var registry = runtime.registry();
    try feature.register(&registry);
    runtime.finishRegistration();

    try feature.enqueue(.{ .spawn = .{ .request_id = 1 } });
    try feature.enqueue(.{ .spawn = .{ .request_id = 2, .chassis = .{
        .pose = .{ .position = .{ 10, 0, 0 } },
    } } });
    try runtime.tick();
    const first = feature.pollOutcome().?.spawned.id;
    const second = feature.pollOutcome().?.spawned.id;

    try feature.enqueue(.{ .enter = .{
        .vehicle_id = first,
        .driver_id = testId(72, 99),
    } });
    try feature.enqueue(.{ .enter = .{ .vehicle_id = first, .driver_id = far } });
    try feature.enqueue(.{ .enter = .{ .vehicle_id = first, .driver_id = near } });
    try feature.enqueue(.{ .enter = .{ .vehicle_id = first, .driver_id = other } });
    try feature.enqueue(.{ .enter = .{ .vehicle_id = second, .driver_id = near } });
    try runtime.tick();
    try expectRejected(&feature, .enter, .driver_not_found);
    try expectRejected(&feature, .enter, .too_far);
    try std.testing.expectEqual(near, feature.pollOutcome().?.entered.driver_id);
    try expectRejected(&feature, .enter, .seat_occupied);
    try expectRejected(&feature, .enter, .driver_not_on_foot);
    try std.testing.expect(feature.pollOutcome() == null);
}

test "carrying driver is a typed rejection and leaves both relationships healthy" {
    var runtime = try engine.Runtime.init(std.testing.allocator, .{
        .namespace = 721,
        .fixed_delta_seconds = 1.0 / 120.0,
    });
    defer runtime.deinit();
    var vehicles = FakeVehicles{};
    var drivers = FakeDrivers{};
    const driver_id = testId(721, 40);
    const item_id = testId(721, 41);
    drivers.add(driver_id, .{ .position = .{ 1, 0, 0 } });
    drivers.entries[0].state.carried_item = item_id;
    var feature = try TestFeature.init(
        std.testing.allocator,
        &runtime,
        &vehicles,
        &drivers,
        .{},
    );
    defer feature.deinit();
    var registry = runtime.registry();
    try feature.register(&registry);
    runtime.finishRegistration();

    try feature.enqueue(.{ .spawn = .{ .request_id = 1 } });
    try runtime.tick();
    const vehicle_id = feature.pollOutcome().?.spawned.id;
    const before = try feature.snapshotRecords(std.testing.allocator);
    defer std.testing.allocator.free(before);

    try feature.enqueue(.{ .enter = .{
        .vehicle_id = vehicle_id,
        .driver_id = driver_id,
    } });
    try runtime.tick();
    try expectRejected(&feature, .enter, .driver_carrying);
    try std.testing.expectEqual(@as(usize, 0), drivers.begin_calls);
    try std.testing.expectEqualDeep(
        item_id,
        (try drivers.driverState(driver_id)).?.carried_item.?,
    );
    try std.testing.expect((try feature.view(vehicle_id)).driver_id == null);
    const after = try feature.snapshotRecords(std.testing.allocator);
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualDeep(before, after);

    // The rejection is non-terminal: resolving the conflicting relationship
    // permits the same command on the next tick.
    drivers.entries[0].state.carried_item = null;
    try feature.enqueue(.{ .enter = .{
        .vehicle_id = vehicle_id,
        .driver_id = driver_id,
    } });
    try runtime.tick();
    try std.testing.expectEqual(driver_id, feature.pollOutcome().?.entered.driver_id);
}

test "authority blocked exit and occupied despawn preserve the relationship" {
    var runtime = try engine.Runtime.init(std.testing.allocator, .{
        .namespace = 73,
        .fixed_delta_seconds = 1.0 / 120.0,
    });
    defer runtime.deinit();
    var vehicles = FakeVehicles{};
    var drivers = FakeDrivers{};
    const driver_id = testId(73, 40);
    const intruder_id = testId(73, 41);
    drivers.add(driver_id, .{ .position = .{ 1, 0, 0 } });
    drivers.add(intruder_id, .{ .position = .{ 1, 0, 0 } });
    var feature = try TestFeature.init(
        std.testing.allocator,
        &runtime,
        &vehicles,
        &drivers,
        .{},
    );
    defer feature.deinit();
    var registry = runtime.registry();
    try feature.register(&registry);
    runtime.finishRegistration();
    try feature.enqueue(.{ .spawn = .{ .request_id = 1 } });
    try runtime.tick();
    const vehicle_id = feature.pollOutcome().?.spawned.id;
    try feature.enqueue(.{ .enter = .{ .vehicle_id = vehicle_id, .driver_id = driver_id } });
    try runtime.tick();
    _ = feature.pollOutcome();

    drivers.block_exit = true;
    try feature.enqueue(.{ .drive = .{
        .vehicle_id = vehicle_id,
        .driver_id = intruder_id,
        .input = .{ .throttle = 1 },
    } });
    try feature.enqueue(.{ .exit = .{
        .vehicle_id = vehicle_id,
        .driver_id = intruder_id,
    } });
    try feature.enqueue(.{ .exit = .{ .vehicle_id = vehicle_id, .driver_id = driver_id } });
    try feature.enqueue(.{ .despawn = .{ .id = vehicle_id } });
    try runtime.tick();
    try expectRejected(&feature, .drive, .wrong_driver);
    try expectRejected(&feature, .exit, .wrong_driver);
    try expectRejected(&feature, .exit, .exit_blocked);
    try expectRejected(&feature, .despawn, .occupied);
    try std.testing.expectEqual(driver_id, (try feature.view(vehicle_id)).driver_id.?);
    try std.testing.expectEqual(
        vehicle_id,
        (try drivers.driverState(driver_id)).?.mode.driving,
    );

    drivers.block_exit = false;
    const attempts_before_fallback = drivers.exit_calls;
    drivers.blocked_exit_attempts = attempts_before_fallback + 3;
    try feature.enqueue(.{ .exit = .{ .vehicle_id = vehicle_id, .driver_id = driver_id } });
    try runtime.tick();
    const exited = feature.pollOutcome().?.exited;
    try std.testing.expectEqual(attempts_before_fallback + 4, drivers.exit_calls);
    try std.testing.expectEqual(driver_id, exited.driver_id);
    try std.testing.expect((try feature.view(vehicle_id)).driver_id == null);
    try std.testing.expectEqual(driver_contract.DriverMode.on_foot, (try drivers.driverState(driver_id)).?.mode);

    try feature.enqueue(.{ .enter = .{ .vehicle_id = vehicle_id, .driver_id = driver_id } });
    try runtime.tick();
    _ = feature.pollOutcome().?.entered;
    drivers.block_exit = true;
    try feature.enqueue(.{ .exit = .{ .vehicle_id = vehicle_id, .driver_id = driver_id } });
    try runtime.tick();
    try expectRejected(&feature, .exit, .exit_blocked);
    try feature.enqueue(.{ .abandon = .{
        .vehicle_id = vehicle_id,
        .driver_id = driver_id,
    } });
    try runtime.tick();
    const abandoned = feature.pollOutcome().?.abandoned;
    try std.testing.expectEqual(driver_id, abandoned.driver_id);
    try std.testing.expectEqual(@as(usize, 1), drivers.abandon_calls);
    try std.testing.expect((try feature.view(vehicle_id)).driver_id == null);
}

test "domain-named driver adapter failure remains terminal and preserves authority" {
    var runtime = try engine.Runtime.init(std.testing.allocator, .{
        .namespace = 74,
        .fixed_delta_seconds = 1.0 / 120.0,
    });
    defer runtime.deinit();
    var vehicles = FakeVehicles{};
    var drivers = FakeDrivers{};
    const driver_id = testId(74, 40);
    drivers.add(driver_id, .{ .position = .{ 1, 0, 0 } });
    var feature = try TestFeature.init(
        std.testing.allocator,
        &runtime,
        &vehicles,
        &drivers,
        .{},
    );
    defer feature.deinit();
    var registry = runtime.registry();
    try feature.register(&registry);
    runtime.finishRegistration();
    try feature.enqueue(.{ .spawn = .{ .request_id = 1 } });
    try runtime.tick();
    const vehicle_id = feature.pollOutcome().?.spawned.id;

    drivers.fail_begin_with_domain_name = true;
    try feature.enqueue(.{ .enter = .{ .vehicle_id = vehicle_id, .driver_id = driver_id } });
    try std.testing.expectError(error.VehicleDriverPortFailure, runtime.tick());
    try std.testing.expect((try feature.view(vehicle_id)).driver_id == null);
    try std.testing.expectEqual(driver_contract.DriverMode.on_foot, (try drivers.driverState(driver_id)).?.mode);
}

test "end-driving adapter failure preserves both sides of occupancy" {
    var runtime = try engine.Runtime.init(std.testing.allocator, .{
        .namespace = 741,
        .fixed_delta_seconds = 1.0 / 120.0,
    });
    defer runtime.deinit();
    var vehicles = FakeVehicles{};
    var drivers = FakeDrivers{};
    const driver_id = testId(741, 40);
    drivers.add(driver_id, .{ .position = .{ 1, 0, 0 } });
    var feature = try TestFeature.init(
        std.testing.allocator,
        &runtime,
        &vehicles,
        &drivers,
        .{},
    );
    defer feature.deinit();
    var registry = runtime.registry();
    try feature.register(&registry);
    runtime.finishRegistration();
    try feature.enqueue(.{ .spawn = .{ .request_id = 1 } });
    try runtime.tick();
    const vehicle_id = feature.pollOutcome().?.spawned.id;
    try feature.enqueue(.{ .enter = .{ .vehicle_id = vehicle_id, .driver_id = driver_id } });
    try runtime.tick();
    _ = feature.pollOutcome();

    drivers.fail_exit = true;
    try feature.enqueue(.{ .exit = .{ .vehicle_id = vehicle_id, .driver_id = driver_id } });
    try std.testing.expectError(error.VehicleDriverPortFailure, runtime.tick());
    try std.testing.expectEqual(driver_id, (try feature.view(vehicle_id)).driver_id.?);
    try std.testing.expectEqual(
        vehicle_id,
        (try drivers.driverState(driver_id)).?.mode.driving,
    );
}

test "accepted enter uses reserved storage and cannot allocate during commit" {
    var runtime = try engine.Runtime.init(std.testing.allocator, .{
        .namespace = 75,
        .fixed_delta_seconds = 1.0 / 120.0,
    });
    defer runtime.deinit();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var vehicles = FakeVehicles{};
    var drivers = FakeDrivers{};
    const driver_id = testId(75, 40);
    drivers.add(driver_id, .{ .position = .{ 1, 0, 0 } });
    var feature = try TestFeature.init(
        failing.allocator(),
        &runtime,
        &vehicles,
        &drivers,
        .{},
    );
    defer feature.deinit();
    var registry = runtime.registry();
    try feature.register(&registry);
    runtime.finishRegistration();
    try feature.enqueue(.{ .spawn = .{ .request_id = 1 } });
    try runtime.tick();
    const vehicle_id = feature.pollOutcome().?.spawned.id;
    try feature.enqueue(.{ .enter = .{ .vehicle_id = vehicle_id, .driver_id = driver_id } });
    failing.fail_index = failing.alloc_index;
    try runtime.tick();
    try std.testing.expectEqual(@as(usize, 1), drivers.begin_calls);
    try std.testing.expectEqual(driver_id, (try feature.view(vehicle_id)).driver_id.?);
    try std.testing.expectEqual(
        vehicle_id,
        (try drivers.driverState(driver_id)).?.mode.driving,
    );
    try std.testing.expect(feature.pollOutcome().? == .entered);
    try std.testing.expect(feature.pollEvent().? == .occupancy_changed);
}

test "domain-named vehicle adapter failure remains terminal and rolls back ownership" {
    var runtime = try engine.Runtime.init(std.testing.allocator, .{
        .namespace = 76,
        .fixed_delta_seconds = 1.0 / 120.0,
    });
    defer runtime.deinit();
    var vehicles = FakeVehicles{ .fail_create_with_domain_name = true };
    var drivers = FakeDrivers{};
    var feature = try TestFeature.init(
        std.testing.allocator,
        &runtime,
        &vehicles,
        &drivers,
        .{},
    );
    defer feature.deinit();
    var registry = runtime.registry();
    try feature.register(&registry);
    runtime.finishRegistration();
    try feature.enqueue(.{ .spawn = .{ .request_id = 1 } });
    try std.testing.expectError(error.VehiclePhysicsPortFailure, runtime.tick());
    try std.testing.expectEqual(@as(usize, 0), feature.count());
    try std.testing.expectEqual(@as(usize, 0), vehicles.live_count);
    try std.testing.expectEqual(@as(usize, 0), runtime.entityCount());
}

test "restore failure rolls back every previously created vehicle" {
    var runtime = try engine.Runtime.init(std.testing.allocator, .{
        .namespace = 77,
        .fixed_delta_seconds = 1.0 / 120.0,
        .next_local_id = 3,
    });
    defer runtime.deinit();
    var vehicles = FakeVehicles{ .fail_create_call = 2 };
    var drivers = FakeDrivers{};
    var feature = try TestFeature.init(
        std.testing.allocator,
        &runtime,
        &vehicles,
        &drivers,
        .{ .max_vehicles = 2 },
    );
    defer feature.deinit();
    var registry = runtime.registry();
    try feature.register(&registry);
    const records = [_]VehicleV1{ testRecord(77, 1), testRecord(77, 2) };
    try std.testing.expectError(
        error.VehiclePhysicsPortFailure,
        feature.restoreRecords(&records),
    );
    try std.testing.expectEqual(@as(usize, 0), feature.count());
    try std.testing.expectEqual(@as(usize, 0), vehicles.live_count);
    try std.testing.expectEqual(@as(usize, 0), runtime.entityCount());
}

test "second occupied restore link failure cancels the first link infallibly" {
    var runtime = try engine.Runtime.init(std.testing.allocator, .{
        .namespace = 771,
        .fixed_delta_seconds = 1.0 / 120.0,
        .next_local_id = 5,
    });
    defer runtime.deinit();
    var vehicles = FakeVehicles{};
    var drivers = FakeDrivers{ .fail_begin_call = 2 };
    const first_driver = testId(771, 3);
    const second_driver = testId(771, 4);
    drivers.add(first_driver, .{});
    drivers.add(second_driver, .{});
    var feature = try TestFeature.init(
        std.testing.allocator,
        &runtime,
        &vehicles,
        &drivers,
        .{ .max_vehicles = 2 },
    );
    defer feature.deinit();
    var registry = runtime.registry();
    try feature.register(&registry);
    var records = [_]VehicleV1{ testRecord(771, 1), testRecord(771, 2) };
    records[0].driver_id = first_driver;
    records[1].driver_id = second_driver;
    try std.testing.expectError(
        error.VehicleDriverPortFailure,
        feature.restoreRecords(&records),
    );
    try std.testing.expectEqual(@as(usize, 0), feature.count());
    try std.testing.expectEqual(@as(usize, 0), vehicles.live_count);
    try std.testing.expectEqual(
        driver_contract.DriverMode.on_foot,
        (try drivers.driverState(first_driver)).?.mode,
    );
    try std.testing.expectEqual(
        driver_contract.DriverMode.on_foot,
        (try drivers.driverState(second_driver)).?.mode,
    );
}

test "chassis and all wheel presentation samples interpolate immutably" {
    var runtime = try engine.Runtime.init(std.testing.allocator, .{
        .namespace = 78,
        .fixed_delta_seconds = 1.0 / 120.0,
    });
    defer runtime.deinit();
    var vehicles = FakeVehicles{};
    var drivers = FakeDrivers{};
    var feature = try TestFeature.init(
        std.testing.allocator,
        &runtime,
        &vehicles,
        &drivers,
        .{},
    );
    defer feature.deinit();
    var registry = runtime.registry();
    try feature.register(&registry);
    runtime.finishRegistration();
    try feature.enqueue(.{ .spawn = .{ .request_id = 1 } });
    try runtime.tick();
    _ = feature.pollOutcome();

    vehicles.states[0].chassis.pose.position[0] = 10;
    for (&vehicles.states[0].wheels) |*wheel| wheel.pose.position[0] += 10;
    try runtime.tick();
    const draws = try feature.extract(0.5);
    try std.testing.expectEqual(@as(usize, 1), draws.len);
    try std.testing.expectApproxEqAbs(@as(f32, 5), draws[0].chassis_pose.position[0], 0.0001);
    for (draws[0].wheels, 0..) |wheel, index| {
        const expected = (VehicleTuning{}).wheel_attachment_positions[index][0] + 5;
        try std.testing.expectApproxEqAbs(expected, wheel.pose.position[0], 0.0001);
        try std.testing.expectEqual(@as(engine.physics.VehicleWheelIndex, @enumFromInt(index)), wheel.index);
    }
    const second_read = try feature.extract(0.5);
    try std.testing.expect(std.meta.eql(draws[0], second_read[0]));
}

test "occupied logical restore is immediately byte-stable" {
    var runtime = try engine.Runtime.init(std.testing.allocator, .{
        .namespace = 79,
        .fixed_delta_seconds = 1.0 / 120.0,
        .next_local_id = 2,
        .completed_ticks = 12,
    });
    defer runtime.deinit();
    var vehicles = FakeVehicles{};
    var drivers = FakeDrivers{};
    const driver_id = testId(79, 40);
    drivers.add(driver_id, .{ .position = .{ 2, 0, 0 } });
    var feature = try TestFeature.init(
        std.testing.allocator,
        &runtime,
        &vehicles,
        &drivers,
        .{},
    );
    defer feature.deinit();
    var registry = runtime.registry();
    try feature.register(&registry);

    var record = testRecord(79, 1);
    record.chassis_pose.position = .{ 3, 4, 5 };
    record.linear_velocity = .{ 1, 2, 3 };
    record.angular_velocity = .{ 0.1, 0.2, 0.3 };
    record.input = .{
        .throttle = 0.5,
        .steering = -0.25,
        .brake = 0.1,
        .hand_brake = 0,
    };
    record.driver_id = driver_id;
    try feature.restoreRecords((&record)[0..1]);
    runtime.finishRegistration();

    const saved = try feature.snapshotRecords(std.testing.allocator);
    defer std.testing.allocator.free(saved);
    try std.testing.expectEqual(@as(usize, 1), saved.len);
    try std.testing.expect(std.meta.eql(record, saved[0]));
    try std.testing.expectEqual(record.id, (try drivers.driverState(driver_id)).?.mode.driving);
    const draws = try feature.extract(0.25);
    try std.testing.expectEqual(record.chassis_pose.position, draws[0].chassis_pose.position);
}

test "rotated chassis transforms the local exit offset" {
    const half_turn: f32 = std.math.pi / 4.0;
    const pose = try localOffsetPose(.{
        .position = .{ 10, 2, 3 },
        .rotation = .{ 0, @sin(half_turn), 0, @cos(half_turn) },
    }, .{ 1, 0, 0 });
    try std.testing.expectApproxEqAbs(@as(f32, 10), pose.position[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 2), pose.position[1], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 2), pose.position[2], 0.0001);
}
