//! Product-side composition of the bounded sandbox visual catalog.
//!
//! This module converts immutable extracted poses and dimensions into colored
//! part transforms. It owns no GPU resources, renderer calls, simulation,
//! collision, navigation, or neural-target policy.

const std = @import("std");
const engine = @import("incinerator_engine");
const zm = @import("zmath");
const combat = @import("combat_presentation");
const catalog = @import("sandbox_visual_catalog.zig");
const render_contract = @import("render_contract.zig");

pub const Plan = struct {
    ordinal: u16,
    surface: catalog.Surface,
    material: render_contract.SurfaceMaterial,
    model: zm.Mat,
};

pub const EnvironmentPart = struct {
    ordinal: u16,
    scale: [3]f32,
    position: [3]f32,
    surface: catalog.Surface,
};

/// Low, non-colliding authored surfaces make roads, walks, plazas, activity
/// areas, and the district seam legible without pretending decorative solids
/// are physical obstacles. Existing recipe blockers provide building massing.
pub const environment_parts = [_]EnvironmentPart{
    .{ .ordinal = 0, .scale = .{ 31.0, 0.025, 5.0 }, .position = .{ 8, 0.012, 0 }, .surface = .road },
    .{ .ordinal = 1, .scale = .{ 31.0, 0.035, 1.4 }, .position = .{ 8, 0.018, 3.25 }, .surface = .sidewalk },
    .{ .ordinal = 2, .scale = .{ 31.0, 0.035, 1.4 }, .position = .{ 8, 0.018, -3.25 }, .surface = .sidewalk },
    .{ .ordinal = 3, .scale = .{ 4.0, 0.045, 3.0 }, .position = .{ -5, 0.023, 5.8 }, .surface = .activity_landmark },
    .{ .ordinal = 4, .scale = .{ 4.0, 0.045, 2.2 }, .position = .{ 4.5, 0.023, 5.8 }, .surface = .building_accent },
    .{ .ordinal = 5, .scale = .{ 5.5, 0.045, 2.4 }, .position = .{ 20.5, 0.023, 5.8 }, .surface = .activity_landmark },
    .{ .ordinal = 6, .scale = .{ 5.0, 0.045, 2.3 }, .position = .{ 20.5, 0.023, -5.5 }, .surface = .route_landmark },
    .{ .ordinal = 7, .scale = .{ 0.16, 0.055, 5.0 }, .position = .{ 8, 0.029, 0 }, .surface = .route_landmark },
    .{ .ordinal = 8, .scale = .{ 3.5, 0.045, 2.2 }, .position = .{ 12.5, 0.023, 5.8 }, .surface = .building_accent },
};

pub fn environmentPlans() [environment_parts.len]Plan {
    var result: [environment_parts.len]Plan = undefined;
    for (environment_parts, 0..) |part, index| result[index] = .{
        .ordinal = part.ordinal,
        .surface = part.surface,
        .material = catalog.material(part.surface),
        .model = zm.mul(
            zm.scaling(part.scale[0], part.scale[1], part.scale[2]),
            zm.translation(part.position[0], part.position[1], part.position[2]),
        ),
    };
    return result;
}

pub fn characterPlans(
    radius: f32,
    half_height: f32,
    pose: engine.physics.Pose,
    state_color: combat.Color,
) [catalog.character_parts.len]Plan {
    const bounds = [3]f32{
        radius * 2,
        (radius + half_height) * 2,
        radius * 2,
    };
    const rotation = poseRotation(pose);
    const translation = poseTranslation(pose);
    var result: [catalog.character_parts.len]Plan = undefined;
    for (catalog.character_parts, 0..) |part, index| result[index] = .{
        .ordinal = part.ordinal,
        .surface = part.surface,
        .material = characterPartMaterial(part, state_color),
        .model = partModel(part, bounds, rotation, translation),
    };
    return result;
}

/// Cheap, readable handgun silhouette attached to the character's right hand.
/// The authority-facing pose owns orientation; this part owns presentation only.
pub fn handgunPlan(
    radius: f32,
    half_height: f32,
    pose: engine.physics.Pose,
) Plan {
    const rotation = poseRotation(pose);
    const translation = poseTranslation(pose);
    return .{
        .ordinal = 100,
        .surface = .painted_metal,
        .material = catalog.materialTinted(.painted_metal, .{ 0.09, 0.10, 0.13, 1 }),
        .model = zm.mul(
            zm.mul(
                zm.mul(
                    zm.scaling(radius * 0.22, radius * 0.16, radius * 0.70),
                    zm.translation(
                        radius * 0.92,
                        (radius + half_height) * 1.15,
                        -radius * 0.72,
                    ),
                ),
                rotation,
            ),
            translation,
        ),
    };
}

pub fn tracerPlan(origin: [3]f32, impact: [3]f32, hit: bool) ?Plan {
    const delta = [3]f32{
        impact[0] - origin[0],
        impact[1] - origin[1],
        impact[2] - origin[2],
    };
    const horizontal = @sqrt(delta[0] * delta[0] + delta[2] * delta[2]);
    const length = @sqrt(horizontal * horizontal + delta[1] * delta[1]);
    if (!std.math.isFinite(length) or length <= 0.001) return null;
    const yaw = std.math.atan2(delta[0], delta[2]);
    const pitch = -std.math.atan2(delta[1], horizontal);
    const midpoint = [3]f32{
        (origin[0] + impact[0]) * 0.5,
        (origin[1] + impact[1]) * 0.5,
        (origin[2] + impact[2]) * 0.5,
    };
    const color: [4]f32 = if (hit)
        .{ 1.0, 0.20, 0.06, 1 }
    else
        .{ 1.0, 0.82, 0.12, 1 };
    return .{
        .ordinal = 0,
        .surface = .emissive,
        .material = catalog.materialTinted(.emissive, color),
        .model = zm.mul(
            zm.mul(
                zm.mul(zm.scaling(0.025, 0.025, length * 0.5), zm.rotationX(pitch)),
                zm.rotationY(yaw),
            ),
            zm.translation(midpoint[0], midpoint[1], midpoint[2]),
        ),
    };
}

pub fn vehicleBodyPlans(
    half_extents: [3]f32,
    pose: engine.physics.Pose,
) [catalog.vehicle_parts.len]Plan {
    const bounds = [3]f32{
        half_extents[0] * 2,
        half_extents[1] * 2,
        half_extents[2] * 2,
    };
    const rotation = poseRotation(pose);
    const translation = poseTranslation(pose);
    var result: [catalog.vehicle_parts.len]Plan = undefined;
    for (catalog.vehicle_parts, 0..) |part, index| result[index] = .{
        .ordinal = part.ordinal,
        .surface = part.surface,
        .material = catalog.materialTinted(part.surface, part.cheap_color),
        .model = partModel(part, bounds, rotation, translation),
    };
    return result;
}

fn partModel(
    part: catalog.Part,
    bounds: [3]f32,
    rotation: zm.Mat,
    translation: zm.Mat,
) zm.Mat {
    const scale = zm.scaling(
        bounds[0] * part.scale[0],
        bounds[1] * part.scale[1],
        bounds[2] * part.scale[2],
    );
    const local_translation = zm.translation(
        bounds[0] * part.offset[0],
        bounds[1] * part.offset[1],
        bounds[2] * part.offset[2],
    );
    return zm.mul(zm.mul(zm.mul(scale, local_translation), rotation), translation);
}

fn poseRotation(pose: engine.physics.Pose) zm.Mat {
    return zm.quatToMat(zm.f32x4(
        pose.rotation[0],
        pose.rotation[1],
        pose.rotation[2],
        pose.rotation[3],
    ));
}

fn poseTranslation(pose: engine.physics.Pose) zm.Mat {
    return zm.translation(pose.position[0], pose.position[1], pose.position[2]);
}

pub fn wheelMarkerModel(
    width: f32,
    radius: f32,
    pose: engine.physics.Pose,
) zm.Mat {
    const rotation = poseRotation(pose);
    const translation = poseTranslation(pose);
    return zm.mul(
        zm.mul(
            zm.mul(
                zm.scaling(width * 1.08, radius * 0.14, radius * 0.72),
                zm.translation(0, radius * 0.22, 0),
            ),
            rotation,
        ),
        translation,
    );
}

fn characterPartMaterial(
    part: catalog.Part,
    state_color: combat.Color,
) render_contract.SurfaceMaterial {
    const state_override = std.meta.eql(state_color, combat.colors.hit_flash) or
        std.meta.eql(state_color, combat.colors.dead);
    if (state_override) return render_contract.SurfaceMaterial.tinted(state_color);
    const color: [4]f32 = switch (part.surface) {
        .fabric_primary => state_color,
        .fabric_secondary => .{
            state_color[0] * 0.42,
            state_color[1] * 0.42,
            state_color[2] * 0.42,
            state_color[3],
        },
        else => part.cheap_color,
    };
    return catalog.materialTinted(part.surface, color);
}

test "character composition preserves state readability across every part" {
    const pose = engine.physics.Pose{};
    const dead = characterPlans(0.4, 0.5, pose, combat.colors.dead);
    for (dead, 0..) |plan, index| {
        try std.testing.expectEqual(@as(u16, @intCast(index)), plan.ordinal);
        try std.testing.expectEqualDeep(combat.colors.dead, plan.material.base_color);
        try std.testing.expectEqualDeep([3]f32{ 0, 0, 0 }, plan.material.emissive);
    }
}

test "vehicle composition preserves catalog ordinals" {
    const plans = vehicleBodyPlans(.{ 0.9, 0.25, 2.0 }, .{});
    for (plans, 0..) |plan, index| {
        try std.testing.expectEqual(@as(u16, @intCast(index)), plan.ordinal);
    }
}

test "environment composition is low profile and stable" {
    const plans = environmentPlans();
    for (plans, 0..) |plan, index| {
        try std.testing.expectEqual(@as(u16, @intCast(index)), plan.ordinal);
        try plan.material.validate();
        try std.testing.expect(environment_parts[index].scale[1] <= 0.055);
    }
}
