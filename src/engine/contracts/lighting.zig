//! Authored direct lighting. Values carry no GPU handles or gameplay authority.
const std = @import("std");
const transform = @import("../transform.zig");

pub const schema_version: u32 = 1;
pub const Kind = enum { directional, point, spot };
pub const Instance = struct { id: u64, light: Light, pose: transform.Pose };

pub const Light = struct {
    kind: Kind = .point,
    color: [3]f32 = .{ 1, 1, 1 },
    /// Lux for a directional source; candela for a point or spot source.
    intensity: f32 = 800,
    enabled: bool = true,
    /// Metres, with a smooth cutoff. Null means no distance cutoff.
    range: ?f32 = 24,
    /// Spot cone half angles in radians, measured from emitted local -Z.
    inner_angle: f32 = std.math.pi / 8.0,
    outer_angle: f32 = std.math.pi / 4.0,
    /// Near-source distance regularization in metres, not an area-light model.
    source_radius: f32 = 0.1,
    casts_shadows: bool = true,

    pub fn validate(self: Light) !void {
        try nonnegative(self.color);
        try nonnegative(.{ self.intensity, self.source_radius });
        if (self.range) |range| if (!std.math.isFinite(range) or range <= 0)
            return error.InvalidLightRange;
        if (!std.math.isFinite(self.inner_angle) or !std.math.isFinite(self.outer_angle) or
            self.inner_angle < 0 or self.inner_angle >= self.outer_angle or
            self.outer_angle > std.math.pi / 2.0) return error.InvalidLightCone;
    }

    /// Independent CPU reference for validation and authoring contribution probes.
    /// Directional lux or punctual irradiance on a surface normal to the ray.
    pub fn incidentIntensity(self: Light, distance: f32, ray_cosine: f32) f32 {
        if (!self.enabled) return 0;
        if (self.kind == .directional) return self.intensity;
        const distance2 = distance * distance;
        var falloff: f32 = 1;
        if (self.range) |range| {
            if (distance >= range) return 0;
            const ratio2 = distance2 / (range * range);
            const fade = @max(0, 1 - ratio2 * ratio2);
            falloff = fade * fade;
        }
        if (self.kind == .spot) {
            const outer = @cos(self.outer_angle);
            const inner = @cos(self.inner_angle);
            const cone = std.math.clamp((ray_cosine - outer) / (inner - outer), 0, 1);
            falloff *= cone * cone * (3 - 2 * cone);
        }
        return self.intensity * falloff / @max(distance2, @max(self.source_radius * self.source_radius, 1e-8));
    }
};

pub const Display = struct {
    /// Linear exposure multiplier applied once, before storage in scene HDR.
    exposure: f32 = 1,
    bloom_strength: f32 = 0.08,
    /// Threshold in exposed linear scene values; zero includes all radiance.
    bloom_threshold: f32 = 1,
    /// Display-space blur radius in pixels. This controls the pyramid footprint.
    bloom_radius: f32 = 32,

    pub fn validate(self: Display) !void {
        try nonnegative(.{ self.exposure, self.bloom_strength, self.bloom_threshold, self.bloom_radius });
        if (self.exposure == 0) return error.InvalidExposure;
    }
};

pub const Environment = struct {
    sun: Light = .{ .kind = .directional, .intensity = 100000, .range = null },
    /// World-space emitted-ray direction, opposite the legacy surface-to-sun field.
    sun_direction: [3]f32 = .{ -0.5773503, -0.5773503, -0.5773503 },
    ambient: [3]f32 = .{ 8000, 10000, 14000 },
    background: [3]f32 = .{ 8000, 14000, 22000 },
    display: Display = .{ .exposure = 0.00004 },
    headlights_enabled: bool = false,
    artificial_lights_enabled: bool = false,
    /// Authored shadow image quality, not a maximum light count.
    shadow_resolution: u32 = 1024,
    shadow_bias: f32 = 0.00002,

    pub fn validate(self: Environment) !void {
        try self.sun.validate();
        if (self.sun.kind != .directional) return error.InvalidSunKind;
        try unitDirection(self.sun_direction);
        try nonnegative(self.ambient);
        try nonnegative(self.background);
        try nonnegative(.{self.shadow_bias});
        try self.display.validate();
        if (self.shadow_resolution == 0) return error.InvalidShadowResolution;
    }
};

/// Shortest rotation from the emitter's local -Z axis to a world ray.
pub fn rotationFromDirection(direction: [3]f32) ![4]f32 {
    try unitDirection(direction);
    if (direction[2] > 0.999999) return .{ 0, 1, 0, 0 };
    var rotation = [4]f32{ direction[1], -direction[0], 0, 1 - direction[2] };
    var length: f32 = 0;
    for (rotation) |v| length += v * v;
    length = @sqrt(length);
    for (&rotation) |*v| v.* /= length;
    return rotation;
}

pub fn emittedDirection(pose: transform.Pose) [3]f32 {
    const q = pose.rotation;
    return .{ -2 * (q[0] * q[2] + q[3] * q[1]), -2 * (q[1] * q[2] - q[3] * q[0]), -(1 - 2 * (q[0] * q[0] + q[1] * q[1])) };
}

pub fn unitDirection(direction: [3]f32) !void {
    try transform.validateFiniteVector(direction);
    var square: f32 = 0;
    for (direction) |v| square += v * v;
    if (@abs(square - 1) > 0.001) return error.LightDirectionNotNormalized;
}

fn nonnegative(values: anytype) !void {
    inline for (values) |value| if (!std.math.isFinite(value) or value < 0)
        return error.InvalidLightEnergy;
}

test "photometric reference inverse square and cone boundaries" {
    const point = Light{ .intensity = 100, .range = null };
    try std.testing.expectApproxEqAbs(@as(f32, 25), point.incidentIntensity(2, 1), 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 6.25), point.incidentIntensity(4, 1), 1e-5);
    const spot = Light{ .kind = .spot, .intensity = 100, .range = null };
    try std.testing.expectApproxEqAbs(@as(f32, 25), spot.incidentIntensity(2, 1), 1e-5);
    try std.testing.expectEqual(@as(f32, 0), spot.incidentIntensity(2, @cos(spot.outer_angle)));
    const cutoff = Light{ .range = 5 };
    try std.testing.expectEqual(@as(f32, 0), cutoff.incidentIntensity(5, 1));
    try std.testing.expectEqual(@as(f32, 0), cutoff.incidentIntensity(8, 1));
    try std.testing.expect((Light{ .kind = .directional }).incidentIntensity(10000, 0) == 800);
}

test "lighting values reject invalid energy and poses without an arbitrary intensity cap" {
    try (Environment{}).validate();
    try (Light{ .intensity = 1e9 }).validate();
    try std.testing.expectError(error.InvalidLightRange, (Light{ .range = 0 }).validate());
    try std.testing.expectError(error.InvalidLightCone, (Light{ .inner_angle = 1, .outer_angle = 0.5 }).validate());
    try std.testing.expectError(error.InvalidLightEnergy, (Light{ .intensity = std.math.inf(f32) }).validate());
    try std.testing.expectError(error.InvalidExposure, (Display{ .exposure = 0 }).validate());
    const pose = transform.Pose{ .rotation = try transform.rotationFromFacingYaw(std.math.pi / 2.0) };
    const direction = emittedDirection(pose);
    try std.testing.expectApproxEqAbs(@as(f32, 1), direction[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0), direction[2], 1e-5);
}
