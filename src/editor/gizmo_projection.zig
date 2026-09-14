//! Shared geometric mapping for bounded editor translation handles.
const std = @import("std");
const tool_module = @import("tool.zig");
const viewport = tool_module.viewport;
pub const Axis = enum(u2) { x, y, z };
pub const GizmoDragMapping = struct {
    projection: ScreenProjection,
    axis: Axis,
    world_origin: [3]f32,
    screen_origin: [2]f32,
    screen_direction: [2]f32,
    pointer_origin: [2]f32,

    pub fn init(
        projection: ScreenProjection,
        axis: Axis,
        world_origin: [3]f32,
        screen_origin: [2]f32,
        axis_projection: AxisProjection,
        pointer_origin: [2]f32,
    ) ?GizmoDragMapping {
        for (world_origin ++ screen_origin ++ axis_projection.direction ++ pointer_origin) |value| {
            if (!std.math.isFinite(value)) return null;
        }
        const direction_length = @sqrt(
            axis_projection.direction[0] * axis_projection.direction[0] +
                axis_projection.direction[1] * axis_projection.direction[1],
        );
        if (!std.math.isFinite(direction_length) or direction_length <= 0) return null;
        return .{
            .projection = projection,
            .axis = axis,
            .world_origin = world_origin,
            .screen_origin = screen_origin,
            .screen_direction = .{
                axis_projection.direction[0] / direction_length,
                axis_projection.direction[1] / direction_length,
            },
            .pointer_origin = pointer_origin,
        };
    }

    pub fn worldDisplacement(self: GizmoDragMapping, pointer: [2]f32) ?f32 {
        if (!std.math.isFinite(pointer[0]) or !std.math.isFinite(pointer[1])) return null;
        const pointer_delta = [2]f32{
            pointer[0] - self.pointer_origin[0],
            pointer[1] - self.pointer_origin[1],
        };
        const screen_distance = pointer_delta[0] * self.screen_direction[0] +
            pointer_delta[1] * self.screen_direction[1];
        const target_screen = [2]f32{
            self.screen_origin[0] + self.screen_direction[0] * screen_distance,
            self.screen_origin[1] + self.screen_direction[1] * screen_distance,
        };
        const ray_direction = self.projection.rayDirection(target_screen) orelse return null;
        var world_axis = [3]f32{ 0, 0, 0 };
        world_axis[@intFromEnum(self.axis)] = 1;
        const camera_to_axis = sub3(self.projection.camera.position, self.world_origin);
        const ray_axis_dot = dot3(ray_direction, world_axis);
        const denominator = 1 - ray_axis_dot * ray_axis_dot;
        if (!std.math.isFinite(denominator) or denominator <= std.math.floatEps(f32)) return null;
        const displacement = (dot3(world_axis, camera_to_axis) -
            ray_axis_dot * dot3(ray_direction, camera_to_axis)) / denominator;
        return if (std.math.isFinite(displacement)) displacement else null;
    }
};

pub const ScreenProjection = struct {
    camera: tool_module.CameraView,
    screen_extent: [2]f32,

    pub fn rayDirection(self: ScreenProjection, screen: [2]f32) ?[3]f32 {
        for (self.camera.forward ++ self.camera.right ++ self.screen_extent ++ screen) |value| {
            if (!std.math.isFinite(value)) return null;
        }
        if (self.screen_extent[0] <= 0 or self.screen_extent[1] <= 0 or
            self.camera.fov <= 0 or self.camera.fov >= std.math.pi)
        {
            return null;
        }
        const forward = normalize3(self.camera.forward) orelse return null;
        const right = normalize3(self.camera.right) orelse return null;
        const up = normalize3(cross3(right, forward)) orelse return null;
        const tangent = @tan(self.camera.fov * 0.5);
        const aspect = self.screen_extent[0] / self.screen_extent[1];
        if (!std.math.isFinite(tangent) or tangent <= 0 or !std.math.isFinite(aspect) or aspect <= 0) return null;
        const ndc_x = screen[0] * 2 / self.screen_extent[0] - 1;
        const ndc_y = 1 - screen[1] * 2 / self.screen_extent[1];
        return normalize3(.{
            forward[0] + right[0] * ndc_x * tangent * aspect + up[0] * ndc_y * tangent,
            forward[1] + right[1] * ndc_x * tangent * aspect + up[1] * ndc_y * tangent,
            forward[2] + right[2] * ndc_x * tangent * aspect + up[2] * ndc_y * tangent,
        });
    }

    pub fn project(self: ScreenProjection, world: [3]f32) ?[2]f32 {
        for (self.camera.position ++ self.camera.forward ++ self.camera.right ++ world ++ self.screen_extent) |value| {
            if (!std.math.isFinite(value)) return null;
        }
        if (self.screen_extent[0] <= 0 or self.screen_extent[1] <= 0 or
            self.camera.fov <= 0 or self.camera.fov >= std.math.pi)
        {
            return null;
        }
        const forward = normalize3(self.camera.forward) orelse return null;
        const right = normalize3(self.camera.right) orelse return null;
        const up = normalize3(cross3(right, forward)) orelse return null;
        const relative = sub3(world, self.camera.position);
        const depth = dot3(relative, forward);
        if (!std.math.isFinite(depth) or depth <= @max(self.camera.near, @as(f32, 0.0001)) or depth >= self.camera.far) return null;
        const tangent = @tan(self.camera.fov * 0.5);
        const aspect = self.screen_extent[0] / self.screen_extent[1];
        if (!std.math.isFinite(tangent) or tangent <= 0 or !std.math.isFinite(aspect) or aspect <= 0) return null;
        const ndc_x = dot3(relative, right) / (depth * tangent * aspect);
        const ndc_y = dot3(relative, up) / (depth * tangent);
        if (!std.math.isFinite(ndc_x) or !std.math.isFinite(ndc_y)) return null;
        return .{
            (ndc_x + 1) * 0.5 * self.screen_extent[0],
            (1 - ndc_y) * 0.5 * self.screen_extent[1],
        };
    }
};

pub const AxisProjection = struct { endpoint: [2]f32, direction: [2]f32, pixels_per_meter: f32 };

pub fn projectAxis(
    projection: ScreenProjection,
    origin_world: [3]f32,
    origin_screen: [2]f32,
    axis: Axis,
) ?AxisProjection {
    var unit_world = origin_world;
    unit_world[@intFromEnum(axis)] += 1;
    const unit_screen = projection.project(unit_world) orelse return null;
    const delta = [2]f32{ unit_screen[0] - origin_screen[0], unit_screen[1] - origin_screen[1] };
    const length = @sqrt(delta[0] * delta[0] + delta[1] * delta[1]);
    if (!std.math.isFinite(length) or length < 0.5) return null;
    const direction = [2]f32{ delta[0] / length, delta[1] / length };
    return .{
        .endpoint = .{ origin_screen[0] + direction[0] * 68, origin_screen[1] + direction[1] * 68 },
        .direction = direction,
        .pixels_per_meter = length,
    };
}

pub fn pointInsideInset(scene: viewport.SceneRect, point: [2]f32, inset: f32) bool {
    return point[0] >= scene.minimum[0] + inset and point[0] < scene.maximum[0] - inset and
        point[1] >= scene.minimum[1] + inset and point[1] < scene.maximum[1] - inset;
}

pub fn dot3(first: [3]f32, second: [3]f32) f32 {
    return first[0] * second[0] + first[1] * second[1] + first[2] * second[2];
}

pub fn sub3(first: [3]f32, second: [3]f32) [3]f32 {
    return .{ first[0] - second[0], first[1] - second[1], first[2] - second[2] };
}

pub fn cross3(first: [3]f32, second: [3]f32) [3]f32 {
    return .{
        first[1] * second[2] - first[2] * second[1],
        first[2] * second[0] - first[0] * second[2],
        first[0] * second[1] - first[1] * second[0],
    };
}

pub fn normalize3(value: [3]f32) ?[3]f32 {
    const length = @sqrt(dot3(value, value));
    if (!std.math.isFinite(length) or length <= 0.000001) return null;
    return .{ value[0] / length, value[1] / length, value[2] / length };
}
