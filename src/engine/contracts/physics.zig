//! Physics data contract for compile-time host composition.
//!
//! The engine does not expose a runtime physics vtable or an upstream body-ID
//! representation. A feature is generic over a concrete `Bodies` adapter and
//! can validate that adapter with `assertImplementation`. Composition roots
//! separately validate their world-step capability.

const std = @import("std");
const transform = @import("../transform.zig");

pub const Pose = transform.Pose;

/// Logical velocity limits shared by persistence, features, and adapters.
///
/// These deliberately match Jolt 5.5's default rigid-body limits. Keeping the
/// limits in the engine contract prevents a snapshot or spawn command from
/// being accepted and then silently clamped by the production adapter.
pub const max_linear_velocity: f32 = 500.0;
pub const max_angular_velocity: f32 = 0.25 * std.math.pi * 60.0;

pub const Velocity = struct {
    linear: [3]f32 = .{ 0, 0, 0 },
    angular: [3]f32 = .{ 0, 0, 0 },

    pub fn validate(self: Velocity) !void {
        try validateFinite(self.linear);
        try validateFinite(self.angular);
        if (!magnitudeFits(self.linear, max_linear_velocity)) {
            return error.LinearVelocityOutOfRange;
        }
        if (!magnitudeFits(self.angular, max_angular_velocity)) {
            return error.AngularVelocityOutOfRange;
        }
    }
};

pub const BodyState = struct {
    pose: Pose = .{},
    velocity: Velocity = .{},

    pub fn validate(self: BodyState) !void {
        try self.pose.validate();
        try self.velocity.validate();
    }

    pub fn normalized(self: BodyState) !BodyState {
        try self.velocity.validate();
        return .{
            .pose = try self.pose.normalized(),
            .velocity = self.velocity,
        };
    }
};

pub const DynamicBoxDesc = struct {
    pose: Pose,
    velocity: Velocity = .{},
    half_extents: [3]f32,

    pub fn validate(self: DynamicBoxDesc) !void {
        try self.pose.validate();
        try self.velocity.validate();
        try validateFinite(self.half_extents);
        for (self.half_extents) |extent| {
            if (extent <= 0) return error.InvalidHalfExtents;
        }
    }

    pub fn normalized(self: DynamicBoxDesc) !DynamicBoxDesc {
        try self.validate();
        return .{
            .pose = try self.pose.normalized(),
            .velocity = self.velocity,
            .half_extents = self.half_extents,
        };
    }
};

/// Gameplay-facing state reported by a character controller. These values are
/// intentionally independent of Jolt's enum and pointer types.
pub const GroundState = enum {
    on_ground,
    on_steep_ground,
    not_supported,
    in_air,
};

/// A bottom-anchored upright capsule. `position` is the point at the center of
/// the capsule's bottom, which is also the feature's logical world position.
pub const CharacterDesc = struct {
    position: [3]f32,
    velocity: [3]f32 = .{ 0, 0, 0 },
    radius: f32 = 0.4,
    half_height: f32 = 0.5,
    max_slope_radians: f32 = std.math.degreesToRadians(50.0),
    mass: f32 = 70.0,
    max_strength: f32 = 100.0,

    pub fn validate(self: CharacterDesc) !void {
        try validateFinite(self.position);
        try validateFinite(self.velocity);
        if (!std.math.isFinite(self.radius) or self.radius <= 0) {
            return error.InvalidCharacterRadius;
        }
        if (!std.math.isFinite(self.half_height) or self.half_height <= 0) {
            return error.InvalidCharacterHalfHeight;
        }
        if (!std.math.isFinite(self.max_slope_radians) or
            self.max_slope_radians <= 0 or
            self.max_slope_radians >= std.math.pi / 2.0)
        {
            return error.InvalidCharacterSlope;
        }
        if (!std.math.isFinite(self.mass) or self.mass <= 0) {
            return error.InvalidCharacterMass;
        }
        if (!std.math.isFinite(self.max_strength) or self.max_strength < 0) {
            return error.InvalidCharacterStrength;
        }
        try (Velocity{ .linear = self.velocity }).validate();
    }
};

/// One controller update. Movement policy lives in the feature; the adapter
/// performs collision, stair walking, and floor adhesion for this velocity.
pub const CharacterUpdate = struct {
    velocity: [3]f32,
    stick_to_floor_distance: f32 = 0.5,
    step_up_height: f32 = 0.4,

    pub fn validate(self: CharacterUpdate) !void {
        try validateFinite(self.velocity);
        try (Velocity{ .linear = self.velocity }).validate();
        if (!std.math.isFinite(self.stick_to_floor_distance) or
            self.stick_to_floor_distance < 0)
        {
            return error.InvalidStickToFloorDistance;
        }
        if (!std.math.isFinite(self.step_up_height) or self.step_up_height < 0) {
            return error.InvalidStepUpHeight;
        }
    }
};

/// Transactional CharacterVirtual relocation used by the vehicle exit seam.
/// `position` remains the character's bottom/feet origin.
pub const CharacterRelocation = struct {
    position: [3]f32,
    velocity: [3]f32 = .{ 0, 0, 0 },
    max_penetration_depth: f32 = 0.001,

    pub fn validate(self: CharacterRelocation) !void {
        try validateFinite(self.position);
        try (Velocity{ .linear = self.velocity }).validate();
        if (!std.math.isFinite(self.max_penetration_depth) or
            self.max_penetration_depth < 0)
        {
            return error.InvalidCharacterPenetrationDepth;
        }
    }
};

pub const CharacterState = struct {
    position: [3]f32,
    velocity: [3]f32,
    ground_state: GroundState,
    ground_velocity: [3]f32,
    ground_normal: [3]f32,

    pub fn validate(self: CharacterState) !void {
        try validateFinite(self.position);
        try validateFinite(self.velocity);
        try validateFinite(self.ground_velocity);
        try validateFinite(self.ground_normal);
        try (Velocity{ .linear = self.velocity }).validate();
        try (Velocity{ .linear = self.ground_velocity }).validate();
    }

    pub fn isSupported(self: CharacterState) bool {
        return self.ground_state == .on_ground or
            self.ground_state == .on_steep_ground;
    }
};

/// Fixed wheel ordering used by the first wheeled-vehicle capability.
///
/// Incinerator uses +Y up, -Z forward, and +X right. Front wheel attachment
/// points therefore have negative Z and left wheel attachment points have
/// negative X.
pub const vehicle_wheel_count: usize = 4;
pub const VehicleWheelIndex = enum(usize) {
    front_left = 0,
    front_right = 1,
    rear_left = 2,
    rear_right = 3,
};

/// Minimal wheel motion restored during logical vehicle reconstruction.
/// Contact, suspension, tire, and solver caches remain backend-owned and are
/// deliberately rebuilt by the first shared physics step.
pub const VehicleWheelDynamics = struct {
    /// Canonical state uses [0, 2π). Construction accepts any finite angle and
    /// `VehicleDesc.normalized` wraps it before it reaches an adapter.
    rotation_angle: f32 = 0,
    angular_velocity: f32 = 0,

    pub fn validate(self: VehicleWheelDynamics) !void {
        try validateFinite([2]f32{ self.rotation_angle, self.angular_velocity });
    }

    pub fn normalized(self: VehicleWheelDynamics) !VehicleWheelDynamics {
        try self.validate();
        var result = self;
        result.rotation_angle = try canonicalVehicleWheelRotation(self.rotation_angle);
        return result;
    }
};

/// Normalize a finite wheel rotation into the engine's unique [0, 2π) range.
/// Exact negative zero is collapsed so logical snapshots can remain byte-stable.
pub fn canonicalVehicleWheelRotation(angle: f32) !f32 {
    if (!std.math.isFinite(angle)) return error.NonFinitePhysicsValue;
    const wrapped = @mod(angle, std.math.tau);
    return if (wrapped == 0) 0 else wrapped;
}

/// Engine-neutral construction data for one conventional four-wheel car.
/// Jolt settings, constraints, collision testers, and body identifiers never
/// cross this boundary.
pub const VehicleDesc = struct {
    chassis: BodyState = .{},
    chassis_half_extents: [3]f32 = .{ 0.9, 0.25, 2.0 },
    center_of_mass_offset: [3]f32 = .{ 0, -0.25, 0 },
    mass: f32 = 1_500,
    wheel_attachment_positions: [vehicle_wheel_count][3]f32 = .{
        .{ -0.8, -0.18, -1.4 },
        .{ 0.8, -0.18, -1.4 },
        .{ -0.8, -0.18, 1.4 },
        .{ 0.8, -0.18, 1.4 },
    },
    initial_wheel_dynamics: [vehicle_wheel_count]VehicleWheelDynamics = .{
        .{}, .{}, .{}, .{},
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
    /// S2 deliberately supports one front-wheel-drive profile rather than a
    /// generic drivetrain graph. These values remain authoritative config.
    front_differential_ratio: f32 = 3.42,
    front_limited_slip_ratio: f32 = 1.4,
    max_pitch_roll_radians: f32 = std.math.degreesToRadians(60.0),
    wheel_collision_max_slope_radians: f32 = std.math.degreesToRadians(60.0),

    pub fn validate(self: VehicleDesc) !void {
        try self.chassis.validate();
        try validateFinite(self.chassis_half_extents);
        for (self.chassis_half_extents) |extent| {
            if (extent <= 0) return error.InvalidVehicleChassisExtents;
        }
        try validateFinite(self.center_of_mass_offset);
        if (!std.math.isFinite(self.mass) or self.mass <= 0) {
            return error.InvalidVehicleMass;
        }
        for (self.wheel_attachment_positions) |position| try validateFinite(position);
        for (self.initial_wheel_dynamics) |dynamics| try dynamics.validate();
        const front_left = self.wheel_attachment_positions[@intFromEnum(VehicleWheelIndex.front_left)];
        const front_right = self.wheel_attachment_positions[@intFromEnum(VehicleWheelIndex.front_right)];
        const rear_left = self.wheel_attachment_positions[@intFromEnum(VehicleWheelIndex.rear_left)];
        const rear_right = self.wheel_attachment_positions[@intFromEnum(VehicleWheelIndex.rear_right)];
        if (front_left[0] >= 0 or rear_left[0] >= 0 or
            front_right[0] <= 0 or rear_right[0] <= 0 or
            front_left[2] >= 0 or front_right[2] >= 0 or
            rear_left[2] <= 0 or rear_right[2] <= 0)
        {
            return error.InvalidVehicleWheelLayout;
        }
        if (!positiveFinite(self.wheel_radius)) return error.InvalidVehicleWheelRadius;
        if (!positiveFinite(self.wheel_width)) return error.InvalidVehicleWheelWidth;
        if (!std.math.isFinite(self.suspension_min_length) or
            !std.math.isFinite(self.suspension_max_length) or
            self.suspension_min_length < 0 or
            self.suspension_max_length <= self.suspension_min_length)
        {
            return error.InvalidVehicleSuspensionRange;
        }
        if (!positiveFinite(self.suspension_frequency) or
            !std.math.isFinite(self.suspension_damping) or
            self.suspension_damping < 0)
        {
            return error.InvalidVehicleSuspensionSpring;
        }
        if (!std.math.isFinite(self.max_steer_radians) or
            self.max_steer_radians <= 0 or
            self.max_steer_radians >= std.math.pi / 2.0)
        {
            return error.InvalidVehicleSteerAngle;
        }
        if (!nonNegativeFinite(self.max_brake_torque) or
            !nonNegativeFinite(self.max_hand_brake_torque))
        {
            return error.InvalidVehicleBrakeTorque;
        }
        if (!positiveFinite(self.front_differential_ratio) or
            !std.math.isFinite(self.front_limited_slip_ratio) or
            self.front_limited_slip_ratio <= 1)
        {
            return error.InvalidVehicleDrivetrain;
        }
        if (!std.math.isFinite(self.max_pitch_roll_radians) or
            self.max_pitch_roll_radians <= 0 or
            self.max_pitch_roll_radians > std.math.pi)
        {
            return error.InvalidVehiclePitchRollAngle;
        }
        if (!std.math.isFinite(self.wheel_collision_max_slope_radians) or
            self.wheel_collision_max_slope_radians <= 0 or
            self.wheel_collision_max_slope_radians >= std.math.pi / 2.0)
        {
            return error.InvalidVehicleCollisionSlope;
        }
    }

    pub fn normalized(self: VehicleDesc) !VehicleDesc {
        try self.validate();
        var result = self;
        result.chassis = try self.chassis.normalized();
        for (&result.initial_wheel_dynamics) |*dynamics| {
            dynamics.* = try dynamics.normalized();
        }
        return result;
    }
};

pub const VehicleInput = struct {
    throttle: f32 = 0,
    steering: f32 = 0,
    brake: f32 = 0,
    hand_brake: f32 = 0,

    pub fn validate(self: VehicleInput) !void {
        try validateFinite([4]f32{ self.throttle, self.steering, self.brake, self.hand_brake });
        if (@abs(self.throttle) > 1 or @abs(self.steering) > 1 or
            self.brake < 0 or self.brake > 1 or
            self.hand_brake < 0 or self.hand_brake > 1)
        {
            return error.InvalidVehicleInput;
        }
    }

    pub fn isNeutral(self: VehicleInput) bool {
        return self.throttle == 0 and self.steering == 0 and
            self.brake == 0 and self.hand_brake == 0;
    }
};

/// A wheel pose uses the engine's canonical wheel-model convention: +X is the
/// axle/right axis and +Y is wheel up. This keeps presentation independent of
/// Jolt's matrix and model-axis parameters.
pub const WheelState = struct {
    pose: Pose,
    angular_velocity: f32,
    rotation_angle: f32,
    /// Steering angle in the engine convention: positive turns toward +X
    /// (right) when the chassis faces -Z.
    steer_angle: f32,
    suspension_length: f32,
    has_contact: bool,

    pub fn validate(self: WheelState) !void {
        try self.pose.validate();
        try validateFinite([4]f32{
            self.angular_velocity,
            self.rotation_angle,
            self.steer_angle,
            self.suspension_length,
        });
        if (self.rotation_angle < 0 or self.rotation_angle >= std.math.tau or
            @as(u32, @bitCast(self.rotation_angle)) == 0x8000_0000)
        {
            return error.NonCanonicalVehicleWheelRotation;
        }
        if (self.suspension_length < 0) return error.InvalidVehicleWheelState;
    }
};

pub const VehicleState = struct {
    chassis: BodyState,
    wheels: [vehicle_wheel_count]WheelState,
    engine_rpm: f32,
    current_gear: i32,

    pub fn validate(self: VehicleState) !void {
        try self.chassis.validate();
        for (self.wheels) |wheel| try wheel.validate();
        if (!std.math.isFinite(self.engine_rpm) or self.engine_rpm < 0) {
            return error.InvalidVehicleEngineState;
        }
    }
};

/// Check the structural contract used by physics-backed features.
///
/// `Bodies.Handle` remains wholly adapter-owned. In particular, this contract
/// never mirrors Jolt's body identifier or world token.
pub fn assertImplementation(comptime Bodies: type) void {
    comptime {
        if (!@hasDecl(Bodies, "Handle")) {
            @compileError("physics implementation must declare Handle");
        }
        if (@TypeOf(Bodies.Handle) != type) {
            @compileError("physics implementation Handle must be a type");
        }

        assertFallibleMethod(
            Bodies,
            "createDynamicBox",
            .{ *Bodies, DynamicBoxDesc },
            Bodies.Handle,
        );
        assertFallibleMethod(
            Bodies,
            "destroyBody",
            .{ *Bodies, Bodies.Handle },
            void,
        );
        assertFallibleMethod(
            Bodies,
            "bodyState",
            .{ *Bodies, Bodies.Handle },
            BodyState,
        );
        assertFallibleMethod(
            Bodies,
            "applyImpulse",
            .{ *Bodies, Bodies.Handle, [3]f32 },
            void,
        );
    }
}

/// Check the world-step capability consumed by a simulation composition.
/// Features do not own or schedule the shared physics step.
pub fn assertWorldStepImplementation(comptime Stepper: type) void {
    comptime {
        assertFallibleMethod(
            Stepper,
            "step",
            .{ *Stepper, f32 },
            void,
        );
    }
}

/// Check the structural contract consumed by the character vertical slice.
/// The controller handle remains wholly owned by the concrete adapter.
pub fn assertCharacterImplementation(comptime Controllers: type) void {
    comptime {
        if (!@hasDecl(Controllers, "Handle")) {
            @compileError("character implementation must declare Handle");
        }
        if (@TypeOf(Controllers.Handle) != type) {
            @compileError("character implementation Handle must be a type");
        }

        assertFallibleMethod(
            Controllers,
            "createCharacter",
            .{ *Controllers, CharacterDesc },
            Controllers.Handle,
        );
        assertFallibleMethod(
            Controllers,
            "destroyCharacter",
            .{ *Controllers, Controllers.Handle },
            void,
        );
        assertFallibleMethod(
            Controllers,
            "characterState",
            .{ *Controllers, Controllers.Handle },
            CharacterState,
        );
        assertFallibleMethod(
            Controllers,
            "prepareCharacter",
            .{ *Controllers, Controllers.Handle },
            CharacterState,
        );
        assertFallibleMethod(
            Controllers,
            "updateCharacter",
            .{ *Controllers, Controllers.Handle, CharacterUpdate, f32 },
            CharacterState,
        );
        assertFallibleMethod(
            Controllers,
            "tryRelocateCharacter",
            .{ *Controllers, Controllers.Handle, CharacterRelocation },
            ?CharacterState,
        );
    }
}

/// Check the structural contract consumed by a four-wheel vehicle feature.
/// The shared world step remains composition-owned.
pub fn assertVehicleImplementation(comptime Vehicles: type) void {
    comptime {
        if (!@hasDecl(Vehicles, "Handle")) {
            @compileError("vehicle implementation must declare Handle");
        }
        if (@TypeOf(Vehicles.Handle) != type) {
            @compileError("vehicle implementation Handle must be a type");
        }
        assertFallibleMethod(
            Vehicles,
            "createVehicle",
            .{ *Vehicles, VehicleDesc },
            Vehicles.Handle,
        );
        assertFallibleMethod(
            Vehicles,
            "destroyVehicle",
            .{ *Vehicles, Vehicles.Handle },
            void,
        );
        assertFallibleMethod(
            Vehicles,
            "setVehicleInput",
            .{ *Vehicles, Vehicles.Handle, VehicleInput },
            void,
        );
        assertFallibleMethod(
            Vehicles,
            "vehicleState",
            .{ *Vehicles, Vehicles.Handle },
            VehicleState,
        );
    }
}

fn assertFallibleMethod(
    comptime Bodies: type,
    comptime name: []const u8,
    comptime expected_params: anytype,
    comptime expected_payload: type,
) void {
    if (!@hasDecl(Bodies, name)) {
        @compileError("physics implementation is missing " ++ name);
    }

    const method_type = @TypeOf(@field(Bodies, name));
    const method = switch (@typeInfo(method_type)) {
        .@"fn" => |info| info,
        else => @compileError("physics implementation declaration " ++ name ++ " must be a function"),
    };
    if (method.params.len != expected_params.len) {
        @compileError("physics implementation method " ++ name ++ " has the wrong parameter count");
    }
    inline for (expected_params, 0..) |expected, index| {
        const actual = method.params[index].type orelse
            @compileError("physics implementation method " ++ name ++ " cannot use an anytype parameter");
        if (actual != expected) {
            @compileError("physics implementation method " ++ name ++ " has an incompatible parameter");
        }
    }

    const return_type = method.return_type orelse
        @compileError("physics implementation method " ++ name ++ " must have a return type");
    const return_payload = switch (@typeInfo(return_type)) {
        .error_union => |info| info.payload,
        else => @compileError("physics implementation method " ++ name ++ " must return an error union"),
    };
    if (return_payload != expected_payload) {
        @compileError("physics implementation method " ++ name ++ " has an incompatible return payload");
    }
}

fn validateFinite(values: anytype) !void {
    for (values) |value| {
        if (!std.math.isFinite(value)) return error.NonFinitePhysicsValue;
    }
}

fn positiveFinite(value: f32) bool {
    return std.math.isFinite(value) and value > 0;
}

fn nonNegativeFinite(value: f32) bool {
    return std.math.isFinite(value) and value >= 0;
}

fn magnitudeSquared(values: [3]f32) f64 {
    var result: f64 = 0;
    for (values) |value| {
        const wide: f64 = value;
        result += wide * wide;
    }
    return result;
}

fn limitSquared(limit: f32) f64 {
    const wide: f64 = limit;
    return wide * wide;
}

/// Require both the exact-ish f64 magnitude and every association of the
/// backend's three f32 squared terms to fit. Jolt performs its clamp test in
/// f32 SIMD; checking only f64 can accept a boundary vector whose rounded f32
/// dot product is just above the limit.
fn magnitudeFits(values: [3]f32, limit: f32) bool {
    if (magnitudeSquared(values) > limitSquared(limit)) return false;
    const squared = [3]f32{
        values[0] * values[0],
        values[1] * values[1],
        values[2] * values[2],
    };
    const association_0 = (squared[0] + squared[1]) + squared[2];
    const association_1 = (squared[0] + squared[2]) + squared[1];
    const association_2 = (squared[1] + squared[2]) + squared[0];
    const backend_upper_bound = @max(association_0, @max(association_1, association_2));
    return backend_upper_bound <= limit * limit;
}

test "physics state validation and normalization stay upstream-neutral" {
    const state = BodyState{
        .pose = .{ .position = .{ 1, 2, 3 }, .rotation = .{ 0, 0, 0, 2 } },
        .velocity = .{ .linear = .{ 4, 5, 6 } },
    };
    const normalized = try state.normalized();
    try std.testing.expectApproxEqAbs(@as(f32, 1), normalized.pose.rotation[3], 0.00001);

    try std.testing.expectError(
        error.NonFinitePhysicsValue,
        (Velocity{ .angular = .{ 0, std.math.nan(f32), 0 } }).validate(),
    );
    try std.testing.expectError(
        error.InvalidHalfExtents,
        (DynamicBoxDesc{
            .pose = .{},
            .half_extents = .{ 1, 0, 1 },
        }).validate(),
    );
}

test "velocity limits accept exact boundaries and reject silent-clamp inputs" {
    try (Velocity{
        .linear = .{ 300, 400, 0 },
        .angular = .{ 0, 0, max_angular_velocity },
    }).validate();
    try (Velocity{
        .linear = .{ -max_linear_velocity, 0, 0 },
        .angular = .{ -max_angular_velocity, 0, 0 },
    }).validate();

    const above_linear = std.math.nextAfter(
        f32,
        max_linear_velocity,
        std.math.inf(f32),
    );
    try std.testing.expectError(
        error.LinearVelocityOutOfRange,
        (Velocity{ .linear = .{ above_linear, 0, 0 } }).validate(),
    );

    const above_angular = std.math.nextAfter(
        f32,
        max_angular_velocity,
        std.math.inf(f32),
    );
    try std.testing.expectError(
        error.AngularVelocityOutOfRange,
        (Velocity{ .angular = .{ 0, above_angular, 0 } }).validate(),
    );

    // These are inside the limit in f64 but exceed it after a possible f32
    // reduction used by Jolt. They must be rejected rather than restored to a
    // silently clamped velocity.
    try std.testing.expectError(
        error.LinearVelocityOutOfRange,
        (Velocity{ .linear = .{ 118.4224777, -462.689972, -147.966568 } }).validate(),
    );
    try std.testing.expectError(
        error.AngularVelocityOutOfRange,
        (Velocity{ .angular = .{ -4.2509985, -29.216375, -36.728645 } }).validate(),
    );
    try std.testing.expectError(
        error.LinearVelocityOutOfRange,
        (Velocity{ .linear = .{ 400, 400, 0 } }).validate(),
    );
}

test "compile-time physics contracts separate feature bodies from host stepping" {
    const FakeBodies = struct {
        pub const Handle = enum(u32) { crate = 1 };

        pub fn createDynamicBox(_: *@This(), _: DynamicBoxDesc) !Handle {
            return .crate;
        }
        pub fn destroyBody(_: *@This(), _: Handle) !void {}
        pub fn bodyState(_: *@This(), _: Handle) !BodyState {
            return .{};
        }
        pub fn applyImpulse(_: *@This(), _: Handle, _: [3]f32) !void {}
    };
    const FakeWorldStepper = struct {
        pub fn step(_: *@This(), _: f32) !void {}
    };

    comptime assertImplementation(FakeBodies);
    comptime assertWorldStepImplementation(FakeWorldStepper);
}

test "character contract validates a bottom-anchored capsule and adapter" {
    const FakeControllers = struct {
        pub const Handle = enum(u32) { player = 1 };

        pub fn createCharacter(_: *@This(), _: CharacterDesc) !Handle {
            return .player;
        }
        pub fn destroyCharacter(_: *@This(), _: Handle) !void {}
        pub fn characterState(_: *@This(), _: Handle) !CharacterState {
            return .{
                .position = .{ 0, 0, 0 },
                .velocity = .{ 0, 0, 0 },
                .ground_state = .in_air,
                .ground_velocity = .{ 0, 0, 0 },
                .ground_normal = .{ 0, 1, 0 },
            };
        }
        pub fn prepareCharacter(self: *@This(), handle: Handle) !CharacterState {
            return self.characterState(handle);
        }
        pub fn updateCharacter(
            self: *@This(),
            handle: Handle,
            _: CharacterUpdate,
            _: f32,
        ) !CharacterState {
            return self.characterState(handle);
        }
        pub fn tryRelocateCharacter(
            _: *@This(),
            _: Handle,
            relocation: CharacterRelocation,
        ) !?CharacterState {
            try relocation.validate();
            return .{
                .position = relocation.position,
                .velocity = relocation.velocity,
                .ground_state = .in_air,
                .ground_velocity = .{ 0, 0, 0 },
                .ground_normal = .{ 0, 1, 0 },
            };
        }
    };

    comptime assertCharacterImplementation(FakeControllers);
    try (CharacterDesc{ .position = .{ 0, 1, 0 } }).validate();
    try std.testing.expectError(
        error.InvalidCharacterRadius,
        (CharacterDesc{ .position = .{ 0, 1, 0 }, .radius = 0 }).validate(),
    );
    try std.testing.expectError(
        error.InvalidCharacterHalfHeight,
        (CharacterDesc{ .position = .{ 0, 1, 0 }, .half_height = 0 }).validate(),
    );
    try std.testing.expectError(
        error.InvalidStepUpHeight,
        (CharacterUpdate{ .velocity = .{ 0, 0, 0 }, .step_up_height = -1 }).validate(),
    );
    try std.testing.expectError(
        error.NonFinitePhysicsValue,
        (CharacterRelocation{ .position = .{ std.math.nan(f32), 0, 0 } }).validate(),
    );
}

test "vehicle contract validates fixed wheel ordering input and adapter" {
    const FakeVehicles = struct {
        pub const Handle = enum(u32) { car = 1 };

        pub fn createVehicle(_: *@This(), _: VehicleDesc) !Handle {
            return .car;
        }
        pub fn destroyVehicle(_: *@This(), _: Handle) !void {}
        pub fn setVehicleInput(_: *@This(), _: Handle, _: VehicleInput) !void {}
        pub fn vehicleState(_: *@This(), _: Handle) !VehicleState {
            const wheel = WheelState{
                .pose = .{},
                .angular_velocity = 0,
                .rotation_angle = 0,
                .steer_angle = 0,
                .suspension_length = 0.3,
                .has_contact = true,
            };
            return .{
                .chassis = .{},
                .wheels = .{ wheel, wheel, wheel, wheel },
                .engine_rpm = 1_000,
                .current_gear = 1,
            };
        }
    };

    comptime assertVehicleImplementation(FakeVehicles);
    try (VehicleDesc{}).validate();
    try (VehicleInput{ .throttle = 1, .steering = -1, .brake = 1 }).validate();
    try std.testing.expectError(
        error.InvalidVehicleInput,
        (VehicleInput{ .throttle = 1.01 }).validate(),
    );
    try std.testing.expectError(
        error.InvalidVehicleWheelLayout,
        (VehicleDesc{
            .wheel_attachment_positions = .{
                .{ 0.8, -0.18, -1.4 },
                .{ -0.8, -0.18, -1.4 },
                .{ -0.8, -0.18, 1.4 },
                .{ 0.8, -0.18, 1.4 },
            },
        }).validate(),
    );
    try std.testing.expectError(
        error.InvalidVehicleSuspensionRange,
        (VehicleDesc{
            .suspension_min_length = 0.5,
            .suspension_max_length = 0.5,
        }).validate(),
    );
    try std.testing.expectError(
        error.InvalidVehicleDrivetrain,
        (VehicleDesc{ .front_differential_ratio = 0 }).validate(),
    );
    try std.testing.expectError(
        error.InvalidVehicleDrivetrain,
        (VehicleDesc{ .front_limited_slip_ratio = 1 }).validate(),
    );
    try std.testing.expectError(
        error.InvalidVehicleDrivetrain,
        (VehicleDesc{ .front_limited_slip_ratio = 0.5 }).validate(),
    );
    try (VehicleDesc{ .front_limited_slip_ratio = 1.001 }).validate();
    try std.testing.expectError(
        error.NonFinitePhysicsValue,
        (VehicleDesc{
            .initial_wheel_dynamics = .{
                .{ .angular_velocity = std.math.nan(f32) }, .{}, .{}, .{},
            },
        }).validate(),
    );
    const wrapped = try (VehicleDesc{
        .initial_wheel_dynamics = .{
            .{ .rotation_angle = -0.25 },
            .{ .rotation_angle = std.math.tau + 0.5 },
            .{ .rotation_angle = @bitCast(@as(u32, 0x8000_0000)) },
            .{},
        },
    }).normalized();
    try std.testing.expectApproxEqAbs(
        std.math.tau - 0.25,
        wrapped.initial_wheel_dynamics[0].rotation_angle,
        0.0001,
    );
    try std.testing.expectApproxEqAbs(
        @as(f32, 0.5),
        wrapped.initial_wheel_dynamics[1].rotation_angle,
        0.0001,
    );
    try std.testing.expectEqual(
        @as(u32, 0),
        @as(u32, @bitCast(wrapped.initial_wheel_dynamics[2].rotation_angle)),
    );
}
