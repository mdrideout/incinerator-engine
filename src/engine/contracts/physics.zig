//! Physics data contract for compile-time host composition.
//!
//! The engine does not expose a runtime physics vtable or an upstream body-ID
//! representation. A feature is generic over a concrete `Bodies` adapter and
//! can validate that adapter with `assertImplementation`.

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
        assertFallibleMethod(
            Bodies,
            "step",
            .{ *Bodies, f32 },
            void,
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

test "compile-time physics structural contract accepts an adapter-owned handle" {
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
        pub fn step(_: *@This(), _: f32) !void {}
    };

    comptime assertImplementation(FakeBodies);
}
