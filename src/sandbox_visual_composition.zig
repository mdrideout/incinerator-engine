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

pub const Plan = struct {
    ordinal: u16,
    color: [4]f32,
    model: zm.Mat,
};

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
        .color = characterPartColor(part, state_color),
        .model = partModel(part, bounds, rotation, translation),
    };
    return result;
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
        .color = part.cheap_color,
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

fn characterPartColor(part: catalog.Part, state_color: combat.Color) [4]f32 {
    const state_override = std.meta.eql(state_color, combat.colors.hit_flash) or
        std.meta.eql(state_color, combat.colors.dead);
    if (state_override) return state_color;
    return switch (part.surface) {
        .fabric_primary => state_color,
        .fabric_secondary => .{
            state_color[0] * 0.42,
            state_color[1] * 0.42,
            state_color[2] * 0.42,
            state_color[3],
        },
        else => part.cheap_color,
    };
}

test "character composition preserves state readability across every part" {
    const pose = engine.physics.Pose{};
    const dead = characterPlans(0.4, 0.5, pose, combat.colors.dead);
    for (dead, 0..) |plan, index| {
        try std.testing.expectEqual(@as(u16, @intCast(index)), plan.ordinal);
        try std.testing.expectEqualDeep(combat.colors.dead, plan.color);
    }
}

test "vehicle composition preserves catalog ordinals" {
    const plans = vehicleBodyPlans(.{ 0.9, 0.25, 2.0 }, .{});
    for (plans, 0..) |plan, index| {
        try std.testing.expectEqual(@as(u16, @intCast(index)), plan.ordinal);
    }
}
