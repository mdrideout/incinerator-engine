//! Canonical value contract for the vehicle gameplay slice.
const std = @import("std");
const engine = @import("engine_contracts");

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
        try self.physicsDescriptor(.{}, zeroWheelDynamics()).validate();
    }

    /// Convert canonical gameplay tuning plus instance state into the
    /// backend-neutral physics contract consumed by the vehicle owner.
    pub fn physicsDescriptor(
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
    commands: engine.diagnostics.QueueStats,
    outcomes: engine.diagnostics.QueueStats,
    events: engine.diagnostics.QueueStats,
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

fn zeroWheelDynamics() [engine.physics.vehicle_wheel_count]engine.physics.VehicleWheelDynamics {
    return .{ .{}, .{}, .{}, .{} };
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

test "vehicle contract retains canonical value validation" {
    try (Config{}).validate();
}
