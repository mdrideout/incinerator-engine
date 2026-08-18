//! Small renderer-neutral visual vocabulary for the default sandbox.
//!
//! These records describe presentation parts only. They do not own GPU
//! resources, gameplay dimensions, collision, navigation, or scene lifetime.
//! The conventional host and offline neural-target fixture deliberately share
//! this vocabulary so cheap silhouettes and rich material intent stay aligned.

const std = @import("std");
const render_contract = @import("render_contract.zig");

pub const Surface = enum {
    ground,
    road,
    sidewalk,
    building_primary,
    building_accent,
    route_landmark,
    activity_landmark,
    obstacle,
    carryable,
    tire,
    wheel_marker,
    health_marker,
    painted_metal,
    glass,
    emissive,
    fabric_primary,
    fabric_secondary,
    skin,
    facing_marker,
};

pub const scene_light = render_contract.SceneLight{
    .sun_direction = .{ 0.431934, 0.863868, 0.259161 },
    .sun_color = .{ 1.0, 0.93, 0.82 },
    .sun_intensity = 0.88,
    .ambient_color = .{ 0.20, 0.24, 0.31 },
};

pub fn material(surface: Surface) render_contract.SurfaceMaterial {
    return switch (surface) {
        .ground => .{ .base_color = .{ 0.22, 0.29, 0.20, 1 } },
        .road => .{ .base_color = .{ 0.12, 0.14, 0.17, 1 } },
        .sidewalk => .{ .base_color = .{ 0.48, 0.47, 0.43, 1 } },
        .building_primary => .{ .base_color = .{ 0.34, 0.39, 0.46, 1 } },
        .building_accent => .{ .base_color = .{ 0.56, 0.27, 0.16, 1 } },
        .route_landmark => .{
            .base_color = .{ 0.15, 0.48, 0.68, 1 },
            .emissive = .{ 0.02, 0.08, 0.12 },
        },
        .activity_landmark => .{
            .base_color = .{ 0.76, 0.52, 0.12, 1 },
            .emissive = .{ 0.08, 0.04, 0.01 },
        },
        .obstacle => .{ .base_color = .{ 0.48, 0.18, 0.12, 1 } },
        .carryable => .{ .base_color = .{ 0.88, 0.68, 0.12, 1 } },
        .tire => .{ .base_color = .{ 0.055, 0.065, 0.08, 1 } },
        .wheel_marker => .{
            .base_color = .{ 0.95, 0.38, 0.06, 1 },
            .emissive = .{ 0.05, 0.01, 0 },
        },
        .health_marker => .{ .base_color = .{ 1, 1, 1, 1 }, .lit = false },
        .painted_metal => .{ .base_color = .{ 0.10, 0.42, 0.72, 1 } },
        .glass => .{ .base_color = .{ 0.12, 0.34, 0.48, 1 } },
        .emissive => .{
            .base_color = .{ 1.0, 0.78, 0.32, 1 },
            .emissive = .{ 0.55, 0.32, 0.08 },
        },
        .fabric_primary => .{ .base_color = .{ 0.70, 0.78, 0.90, 1 } },
        .fabric_secondary => .{ .base_color = .{ 0.16, 0.20, 0.28, 1 } },
        .skin => .{ .base_color = .{ 0.82, 0.62, 0.45, 1 } },
        .facing_marker => .{
            .base_color = .{ 0.08, 0.18, 0.35, 1 },
            .emissive = .{ 0.01, 0.02, 0.05 },
        },
    };
}

pub fn materialTinted(surface: Surface, color: [4]f32) render_contract.SurfaceMaterial {
    var result = material(surface);
    result.base_color = color;
    return result;
}

pub const Part = struct {
    label: []const u8,
    ordinal: u16,
    /// Scale relative to the owning presentation bounds.
    scale: [3]f32,
    /// Center offset relative to the owning presentation bounds.
    offset: [3]f32,
    surface: Surface,
    cheap_color: [4]f32,

    pub fn validate(self: Part) !void {
        if (self.label.len == 0) return error.SandboxVisualPartLabelRequired;
        for (self.scale) |value| {
            if (!std.math.isFinite(value) or value <= 0) {
                return error.InvalidSandboxVisualPartScale;
            }
        }
        for (self.offset ++ self.cheap_color) |value| {
            if (!std.math.isFinite(value)) return error.NonFiniteSandboxVisualPart;
        }
        for (self.cheap_color) |value| {
            if (value < 0 or value > 1) return error.InvalidSandboxVisualPartColor;
        }
    }
};

/// Character bounds are `{ diameter, full height, diameter }` and begin at
/// the authority capsule's foot plane. The shoulder bar makes the silhouette
/// intentionally T-shaped even at 160x90.
pub const character_parts = [_]Part{
    .{ .label = "left-leg", .ordinal = 0, .scale = .{ 0.26, 0.28, 0.42 }, .offset = .{ -0.19, 0.14, 0 }, .surface = .fabric_secondary, .cheap_color = .{ 0.16, 0.20, 0.28, 1 } },
    .{ .label = "right-leg", .ordinal = 1, .scale = .{ 0.26, 0.28, 0.42 }, .offset = .{ 0.19, 0.14, 0 }, .surface = .fabric_secondary, .cheap_color = .{ 0.16, 0.20, 0.28, 1 } },
    .{ .label = "torso", .ordinal = 2, .scale = .{ 0.66, 0.34, 0.58 }, .offset = .{ 0, 0.45, 0 }, .surface = .fabric_primary, .cheap_color = .{ 0.70, 0.78, 0.90, 1 } },
    .{ .label = "shoulder-arm-bar", .ordinal = 3, .scale = .{ 1.34, 0.12, 0.42 }, .offset = .{ 0, 0.66, 0 }, .surface = .fabric_primary, .cheap_color = .{ 0.70, 0.78, 0.90, 1 } },
    .{ .label = "head", .ordinal = 4, .scale = .{ 0.48, 0.20, 0.46 }, .offset = .{ 0, 0.84, 0 }, .surface = .skin, .cheap_color = .{ 0.82, 0.62, 0.45, 1 } },
    // The marker deliberately overlaps and protrudes beyond the head face.
    // A nearly coplanar sliver was one cheap pixel in an oblique RF6 camera
    // while Cycles correctly occluded it, invalidating exact pair ownership.
    .{ .label = "facing-marker", .ordinal = 5, .scale = .{ 0.24, 0.10, 0.08 }, .offset = .{ 0, 0.84, -0.28 }, .surface = .facing_marker, .cheap_color = .{ 0.08, 0.18, 0.35, 1 } },
};

/// Vehicle bounds are the authority chassis full extents. Longitudinal is Z,
/// lateral is X, matching the Jolt wheel attachment contract.
pub const vehicle_parts = [_]Part{
    .{ .label = "lower-body", .ordinal = 0, .scale = .{ 1.00, 0.62, 1.00 }, .offset = .{ 0, -0.10, 0 }, .surface = .painted_metal, .cheap_color = .{ 0.10, 0.42, 0.72, 1 } },
    .{ .label = "hood", .ordinal = 1, .scale = .{ 0.92, 0.22, 0.34 }, .offset = .{ 0, 0.30, -0.33 }, .surface = .painted_metal, .cheap_color = .{ 0.12, 0.48, 0.80, 1 } },
    .{ .label = "cabin", .ordinal = 2, .scale = .{ 0.82, 0.80, 0.43 }, .offset = .{ 0, 0.46, 0.14 }, .surface = .painted_metal, .cheap_color = .{ 0.08, 0.34, 0.62, 1 } },
    .{ .label = "windshield", .ordinal = 3, .scale = .{ 0.68, 0.42, 0.035 }, .offset = .{ 0, 0.48, -0.085 }, .surface = .glass, .cheap_color = .{ 0.18, 0.50, 0.68, 1 } },
    .{ .label = "rear-window", .ordinal = 4, .scale = .{ 0.68, 0.36, 0.035 }, .offset = .{ 0, 0.48, 0.365 }, .surface = .glass, .cheap_color = .{ 0.16, 0.42, 0.58, 1 } },
    .{ .label = "left-window", .ordinal = 5, .scale = .{ 0.035, 0.36, 0.30 }, .offset = .{ -0.425, 0.48, 0.14 }, .surface = .glass, .cheap_color = .{ 0.16, 0.44, 0.62, 1 } },
    .{ .label = "right-window", .ordinal = 6, .scale = .{ 0.035, 0.36, 0.30 }, .offset = .{ 0.425, 0.48, 0.14 }, .surface = .glass, .cheap_color = .{ 0.16, 0.44, 0.62, 1 } },
    .{ .label = "front-bumper", .ordinal = 7, .scale = .{ 1.18, 0.18, 0.065 }, .offset = .{ 0, -0.02, -0.525 }, .surface = .painted_metal, .cheap_color = .{ 0.10, 0.11, 0.14, 1 } },
    .{ .label = "rear-bumper", .ordinal = 8, .scale = .{ 1.18, 0.18, 0.065 }, .offset = .{ 0, -0.02, 0.525 }, .surface = .painted_metal, .cheap_color = .{ 0.10, 0.11, 0.14, 1 } },
    .{ .label = "left-headlight", .ordinal = 9, .scale = .{ 0.24, 0.22, 0.05 }, .offset = .{ -0.42, 0.12, -0.54 }, .surface = .emissive, .cheap_color = .{ 1.00, 0.86, 0.45, 1 } },
    .{ .label = "right-headlight", .ordinal = 10, .scale = .{ 0.24, 0.22, 0.05 }, .offset = .{ 0.42, 0.12, -0.54 }, .surface = .emissive, .cheap_color = .{ 1.00, 0.86, 0.45, 1 } },
};

fn validateCatalog(parts: []const Part) !void {
    for (parts, 0..) |part, index| {
        try part.validate();
        try std.testing.expectEqual(index, part.ordinal);
        for (parts[index + 1 ..]) |other| {
            try std.testing.expect(!std.mem.eql(u8, part.label, other.label));
            try std.testing.expect(part.ordinal != other.ordinal);
        }
    }
}

test "sandbox visual catalogs are explicit valid and stable" {
    try scene_light.validate();
    inline for (std.meta.tags(Surface)) |surface| try material(surface).validate();
    try validateCatalog(&character_parts);
    try validateCatalog(&vehicle_parts);
}

test "character catalog keeps a readable T silhouette" {
    const shoulders = character_parts[3];
    const torso = character_parts[2];
    try std.testing.expect(shoulders.scale[0] > torso.scale[0]);
    try std.testing.expect(shoulders.offset[1] > torso.offset[1]);
    try std.testing.expect(character_parts[5].offset[2] < 0);
    const head = character_parts[4];
    const marker = character_parts[5];
    try std.testing.expect(
        -marker.offset[2] + marker.scale[2] * 0.5 > head.scale[2] * 0.5,
    );
}
