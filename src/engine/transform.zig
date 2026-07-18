//! Renderer- and physics-neutral transform data.

const std = @import("std");

pub const Vec3 = [3]f32;
pub const Quaternion = [4]f32;

/// Canonical semantic facing convention shared by gameplay and presentation:
///
/// - the engine is right-handed with +Y up;
/// - yaw 0 faces local/world -Z;
/// - positive yaw turns toward +X (right), so +pi/2 faces +X;
/// - canonical yaw is in [-pi, pi), with zero stored as positive zero.
///
/// Positive semantic facing yaw therefore has the opposite sign from a
/// right-handed quaternion rotation about +Y. Keeping that conversion here
/// prevents camera, locomotion, physics poses, and presentation from each
/// inventing a subtly different convention.
pub fn normalizeFacingYaw(yaw: f32) !f32 {
    if (!std.math.isFinite(yaw)) return error.NonFiniteFacingYaw;
    const normalized = @mod(yaw + std.math.pi, std.math.tau) - std.math.pi;
    return if (normalized == 0) 0 else normalized;
}

/// Unit horizontal forward direction for a semantic facing yaw.
pub fn forwardFromFacingYaw(yaw: f32) !Vec3 {
    const normalized = try normalizeFacingYaw(yaw);
    return .{ @sin(normalized), 0, -@cos(normalized) };
}

/// Convert semantic facing yaw to the engine's right-handed quaternion pose.
pub fn rotationFromFacingYaw(yaw: f32) !Quaternion {
    const normalized = try normalizeFacingYaw(yaw);
    const half_rotation = normalized * -0.5;
    return .{ 0, @sin(half_rotation), 0, @cos(half_rotation) };
}

/// Recover semantic horizontal facing from a validated engine quaternion.
/// Pitch and roll are tolerated as long as local -Z has a horizontal heading.
pub fn facingYawFromRotation(raw_rotation: Quaternion) !f32 {
    const rotation = try normalizeQuaternion(raw_rotation);
    const x = rotation[0];
    const y = rotation[1];
    const z = rotation[2];
    const w = rotation[3];
    const forward_x = -2 * (x * z + w * y);
    const forward_z = -(1 - 2 * (x * x + y * y));
    const horizontal_length_squared = forward_x * forward_x + forward_z * forward_z;
    if (!std.math.isFinite(horizontal_length_squared) or
        horizontal_length_squared <= 1.0e-12)
    {
        return error.DegenerateFacingDirection;
    }
    return normalizeFacingYaw(std.math.atan2(forward_x, -forward_z));
}

/// Interpolate canonical facing along the shortest wrapped angular arc.
/// Finite alpha is clamped to [0, 1], matching `interpolate` for full poses.
pub fn interpolateFacingYaw(previous: f32, current: f32, alpha: f32) !f32 {
    if (!std.math.isFinite(alpha)) return error.InvalidInterpolationAlpha;
    const from = try normalizeFacingYaw(previous);
    const to = try normalizeFacingYaw(current);
    const delta = try normalizeFacingYaw(to - from);
    const clamped_alpha = std.math.clamp(alpha, 0, 1);
    return normalizeFacingYaw(from + delta * clamped_alpha);
}

pub const Pose = struct {
    position: Vec3 = .{ 0, 0, 0 },
    rotation: Quaternion = .{ 0, 0, 0, 1 },

    pub fn validate(self: Pose) !void {
        try validateFiniteVector(self.position);
        try validateQuaternion(self.rotation);
    }

    pub fn normalized(self: Pose) !Pose {
        try validateFiniteVector(self.position);
        return .{
            .position = self.position,
            .rotation = try normalizeQuaternion(self.rotation),
        };
    }
};

pub fn validateFiniteVector(values: anytype) !void {
    for (values) |value| {
        if (!std.math.isFinite(value)) return error.NonFiniteTransform;
    }
}

pub fn validateQuaternion(rotation: Quaternion) !void {
    _ = try normalizedQuaternion(rotation);
}

pub fn normalizeQuaternion(rotation: Quaternion) !Quaternion {
    return normalizedQuaternion(rotation);
}

/// Scale before squaring so every finite, non-degenerate quaternion remains
/// normalizable even when its raw f32 length-squared would overflow.
fn normalizedQuaternion(rotation: Quaternion) !Quaternion {
    try validateFiniteVector(rotation);
    var scale: f32 = 0;
    for (rotation) |component| scale = @max(scale, @abs(component));
    if (scale == 0) return error.DegenerateQuaternion;

    const scaled = Quaternion{
        rotation[0] / scale,
        rotation[1] / scale,
        rotation[2] / scale,
        rotation[3] / scale,
    };
    const scaled_length = @sqrt(quaternionLengthSquared(scaled));
    if (!std.math.isFinite(scaled_length) or
        scale <= 1.0e-6 / scaled_length)
    {
        return error.DegenerateQuaternion;
    }
    const inverse_scaled_length = 1.0 / scaled_length;
    return .{
        scaled[0] * inverse_scaled_length,
        scaled[1] * inverse_scaled_length,
        scaled[2] * inverse_scaled_length,
        scaled[3] * inverse_scaled_length,
    };
}

/// Interpolate two validated poses for presentation.
///
/// Quaternion endpoints and the result are normalized. When the quaternion dot
/// product is negative, the second endpoint is negated so nlerp follows the
/// shortest rotational arc rather than taking an equivalent long path.
pub fn interpolate(previous: Pose, current: Pose, alpha: f32) !Pose {
    if (!std.math.isFinite(alpha)) return error.InvalidInterpolationAlpha;
    const clamped_alpha = std.math.clamp(alpha, 0, 1);
    try validateFiniteVector(previous.position);
    try validateFiniteVector(current.position);

    const from = try normalizeQuaternion(previous.rotation);
    var to = try normalizeQuaternion(current.rotation);
    if (quaternionDot(from, to) < 0) {
        for (&to) |*component| component.* = -component.*;
    }

    const inverse_alpha = 1 - clamped_alpha;
    const blended = Quaternion{
        from[0] * inverse_alpha + to[0] * clamped_alpha,
        from[1] * inverse_alpha + to[1] * clamped_alpha,
        from[2] * inverse_alpha + to[2] * clamped_alpha,
        from[3] * inverse_alpha + to[3] * clamped_alpha,
    };

    return .{
        .position = .{
            previous.position[0] * inverse_alpha + current.position[0] * clamped_alpha,
            previous.position[1] * inverse_alpha + current.position[1] * clamped_alpha,
            previous.position[2] * inverse_alpha + current.position[2] * clamped_alpha,
        },
        .rotation = try normalizeQuaternion(blended),
    };
}

fn quaternionLengthSquared(rotation: Quaternion) f32 {
    return quaternionDot(rotation, rotation);
}

fn quaternionDot(a: Quaternion, b: Quaternion) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2] + a[3] * b[3];
}

test "pose interpolation normalizes and takes the shortest quaternion arc" {
    // These two endpoints encode the same rotation with opposite signs. A
    // naive lerp would collapse to the zero quaternion at alpha 0.5.
    const result = try interpolate(
        .{ .position = .{ 0, 2, 4 }, .rotation = .{ 0, 0, 0, 2 } },
        .{ .position = .{ 4, 6, 8 }, .rotation = .{ 0, 0, 0, -3 } },
        0.5,
    );

    try std.testing.expectEqual(Vec3{ 2, 4, 6 }, result.position);
    try std.testing.expectApproxEqAbs(@as(f32, 0), result.rotation[0], 0.00001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), result.rotation[1], 0.00001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), result.rotation[2], 0.00001);
    try std.testing.expectApproxEqAbs(@as(f32, 1), result.rotation[3], 0.00001);
}

test "pose interpolation clamps finite alpha and rejects invalid boundary data" {
    const identity = Pose{};
    const before = try interpolate(
        .{ .position = .{ 1, 2, 3 } },
        .{ .position = .{ 4, 5, 6 } },
        -0.01,
    );
    try std.testing.expectEqual([3]f32{ 1, 2, 3 }, before.position);
    const after = try interpolate(
        .{ .position = .{ 1, 2, 3 } },
        .{ .position = .{ 4, 5, 6 } },
        1.01,
    );
    try std.testing.expectEqual([3]f32{ 4, 5, 6 }, after.position);
    try std.testing.expectError(
        error.InvalidInterpolationAlpha,
        interpolate(identity, identity, std.math.nan(f32)),
    );
    try std.testing.expectError(
        error.DegenerateQuaternion,
        interpolate(identity, .{ .rotation = .{ 0, 0, 0, 0 } }, 0.5),
    );
    try std.testing.expectError(
        error.NonFiniteTransform,
        interpolate(identity, .{ .position = .{ 0, std.math.inf(f32), 0 } }, 0.5),
    );
}

test "quaternion normalization cannot overflow on large finite components" {
    const large = std.math.floatMax(f32);
    const normalized = try normalizeQuaternion(.{ large, large, large, large });
    for (normalized) |component| {
        try std.testing.expectApproxEqAbs(@as(f32, 0.5), component, 0.00001);
    }
}

test "captured physics quaternion normalization is exact and idempotent" {
    // Captured from a live carryable at the M3 persistence boundary. The
    // scale-safe engine normalizer leaves it stable; the former adapter-local
    // length-squared implementation changed components on cold restore.
    const rotation = Quaternion{
        -0.00000015895778915364644,
        0.01797596924006939,
        0.0000005184497240406927,
        0.9998383522033691,
    };
    const once = try normalizeQuaternion(rotation);
    const twice = try normalizeQuaternion(once);
    try std.testing.expectEqual(rotation, once);
    try std.testing.expectEqual(once, twice);
}

test "semantic facing basis agrees with quaternion rotation" {
    const cases = [_]struct {
        yaw: f32,
        forward: Vec3,
    }{
        .{ .yaw = 0, .forward = .{ 0, 0, -1 } },
        .{ .yaw = std.math.pi / 2.0, .forward = .{ 1, 0, 0 } },
        .{ .yaw = -std.math.pi / 2.0, .forward = .{ -1, 0, 0 } },
    };

    for (cases) |case| {
        const forward = try forwardFromFacingYaw(case.yaw);
        const rotation = try rotationFromFacingYaw(case.yaw);
        const rotated_forward = rotateVectorForTest(rotation, .{ 0, 0, -1 });
        for (forward, rotated_forward, case.forward) |semantic, rotated, expected| {
            try std.testing.expectApproxEqAbs(expected, semantic, 0.00001);
            try std.testing.expectApproxEqAbs(expected, rotated, 0.00001);
        }
        try std.testing.expectApproxEqAbs(
            try normalizeFacingYaw(case.yaw),
            try facingYawFromRotation(rotation),
            0.00001,
        );
    }
}

test "semantic facing is canonical and rejects invalid boundaries" {
    try std.testing.expectApproxEqAbs(
        @as(f32, -std.math.pi),
        try normalizeFacingYaw(std.math.pi),
        0.00001,
    );
    try std.testing.expectEqual(
        @as(u32, 0),
        @as(u32, @bitCast(try normalizeFacingYaw(-0.0))),
    );
    try std.testing.expectError(
        error.NonFiniteFacingYaw,
        normalizeFacingYaw(std.math.nan(f32)),
    );
    try std.testing.expectError(
        error.DegenerateQuaternion,
        facingYawFromRotation(.{ 0, 0, 0, 0 }),
    );
    try std.testing.expectError(
        error.DegenerateFacingDirection,
        facingYawFromRotation(.{ @sin(std.math.pi / 4.0), 0, 0, @cos(std.math.pi / 4.0) }),
    );
}

test "semantic facing interpolation takes the shortest wrapped arc" {
    const degrees_to_radians = std.math.pi / 180.0;
    const previous = 179.0 * degrees_to_radians;
    const current = -179.0 * degrees_to_radians;
    const midpoint = try interpolateFacingYaw(previous, current, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, std.math.pi), @abs(midpoint), 0.00001);
    try std.testing.expectApproxEqAbs(
        previous,
        try interpolateFacingYaw(previous, current, -1),
        0.00001,
    );
    try std.testing.expectApproxEqAbs(
        current,
        try interpolateFacingYaw(previous, current, 2),
        0.00001,
    );
    try std.testing.expectError(
        error.InvalidInterpolationAlpha,
        interpolateFacingYaw(previous, current, std.math.nan(f32)),
    );
}

fn rotateVectorForTest(rotation: Quaternion, value: Vec3) Vec3 {
    const axis = Vec3{ rotation[0], rotation[1], rotation[2] };
    const twice_cross = Vec3{
        2 * (axis[1] * value[2] - axis[2] * value[1]),
        2 * (axis[2] * value[0] - axis[0] * value[2]),
        2 * (axis[0] * value[1] - axis[1] * value[0]),
    };
    return .{
        value[0] + rotation[3] * twice_cross[0] +
            axis[1] * twice_cross[2] - axis[2] * twice_cross[1],
        value[1] + rotation[3] * twice_cross[1] +
            axis[2] * twice_cross[0] - axis[0] * twice_cross[2],
        value[2] + rotation[3] * twice_cross[2] +
            axis[0] * twice_cross[1] - axis[1] * twice_cross[0],
    };
}
