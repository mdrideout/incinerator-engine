//! primitives.zig - Built-in geometric primitives
//!
//! DOMAIN: Asset/Resource Layer (factory functions)
//!
//! This module provides factory functions to create common geometric shapes.
//! It contains the actual vertex DATA for built-in primitives and knows how
//! to construct Mesh objects from that data.
//!
//! Responsibilities:
//! - Define vertex data for built-in shapes (cube, sphere, etc.)
//! - Provide simple factory functions for sandbox primitives
//! - Encapsulate the "recipe" for each primitive
//!
//! This module does NOT:
//! - Store or cache created meshes (caller owns the Mesh)
//! - Know about GPU internals (delegates to Mesh.init)
//! - Know where primitives are used in the scene
//!
//! Future additions:
//! - Cube, Sphere, Plane/Quad, Cylinder, Capsule
//! - Configurable parameters (sphere segments, grid divisions)
//! - Debug primitives (wireframe grid, axis gizmo)

const std = @import("std");
const mesh = @import("mesh.zig");
const sdl = @import("sdl.zig");

const Mesh = mesh.Mesh;
const Vertex = mesh.Vertex;
const c = sdl.c;

// ============================================================================
// Wheel Cylinder
// ============================================================================

pub const wheel_segments: usize = 16;
pub const wheel_triangle_count: usize = wheel_segments * 4;
pub const wheel_vertex_count: usize = wheel_triangle_count * 3;

/// Generate a centered unit wheel cylinder. Its axle is +X, matching the
/// engine physics contract; callers scale X by wheel width and Y/Z by wheel
/// diameter. One orange segment makes rotation visible in the debug sandbox.
fn wheelCylinderScaffold() [wheel_vertex_count]Vertex {
    const half_extent: f32 = 0.5;
    const left_center = [3]f32{ -half_extent, 0, 0 };
    const right_center = [3]f32{ half_extent, 0, 0 };
    var vertices: [wheel_vertex_count]Vertex = undefined;
    var cursor: usize = 0;

    for (0..wheel_segments) |segment| {
        const angle = std.math.tau *
            @as(f32, @floatFromInt(segment)) /
            @as(f32, @floatFromInt(wheel_segments));
        const next_angle = std.math.tau *
            @as(f32, @floatFromInt(segment + 1)) /
            @as(f32, @floatFromInt(wheel_segments));
        const a = [2]f32{ half_extent * @cos(angle), half_extent * @sin(angle) };
        const b = [2]f32{ half_extent * @cos(next_angle), half_extent * @sin(next_angle) };
        const left_a = [3]f32{ -half_extent, a[0], a[1] };
        const right_a = [3]f32{ half_extent, a[0], a[1] };
        const left_b = [3]f32{ -half_extent, b[0], b[1] };
        const right_b = [3]f32{ half_extent, b[0], b[1] };
        const tread_color = if (segment == 0)
            [3]f32{ 0.95, 0.45, 0.08 }
        else
            [3]f32{ 0.08, 0.09, 0.11 };
        const sidewall_color = if (segment == 0)
            [3]f32{ 0.95, 0.45, 0.08 }
        else
            [3]f32{ 0.16, 0.17, 0.20 };

        // The pos_color pipeline uses clockwise exterior winding. These
        // conventional cross products therefore point into the cylinder.
        appendWheelTriangle(&vertices, &cursor, left_a, right_a, right_b, tread_color);
        appendWheelTriangle(&vertices, &cursor, left_a, right_b, left_b, tread_color);
        appendWheelTriangle(&vertices, &cursor, left_center, left_a, left_b, sidewall_color);
        appendWheelTriangle(&vertices, &cursor, right_center, right_b, right_a, sidewall_color);
    }
    std.debug.assert(cursor == vertices.len);
    return vertices;
}

fn appendWheelTriangle(
    vertices: *[wheel_vertex_count]Vertex,
    cursor: *usize,
    a: [3]f32,
    b: [3]f32,
    d: [3]f32,
    color: [3]f32,
) void {
    vertices[cursor.*] = .{ .position = a, .color = color };
    vertices[cursor.* + 1] = .{ .position = b, .color = color };
    vertices[cursor.* + 2] = .{ .position = d, .color = color };
    cursor.* += 3;
}

// ============================================================================
// Character Capsule
// ============================================================================

pub const capsule_segments: usize = 16;
pub const capsule_hemisphere_bands: usize = 5;
pub const capsule_radial_rings: usize = capsule_hemisphere_bands * 2;
pub const capsule_triangle_count: usize = capsule_segments * 2 +
    (capsule_radial_rings - 1) * capsule_segments * 2;
pub const capsule_vertex_count: usize = capsule_triangle_count * 3;

/// Generate the gameplay capsule at its authored physical dimensions with its
/// foot at Y=0. A blue forward stripe makes yaw visible.
fn characterCapsuleScaffold(
    radius: f32,
    half_height: f32,
) [capsule_vertex_count]Vertex {
    std.debug.assert(std.math.isFinite(radius) and radius > 0);
    std.debug.assert(std.math.isFinite(half_height) and half_height > 0);
    const cylinder_top = radius + half_height * 2.0;
    const top = cylinder_top + radius;
    var rings: [capsule_radial_rings][capsule_segments][3]f32 = undefined;

    // Bottom hemisphere rings, including its equator.
    for (0..capsule_hemisphere_bands) |band_index| {
        const band: f32 = @floatFromInt(band_index + 1);
        const bands: f32 = @floatFromInt(capsule_hemisphere_bands);
        const angle = -std.math.pi / 2.0 + (std.math.pi / 2.0) * band / bands;
        fillCapsuleRing(&rings[band_index], radius * @cos(angle), radius + radius * @sin(angle));
    }
    // Top equator followed by its intermediate rings. The top pole is emitted
    // as a fan and is not duplicated around a zero-radius ring.
    for (0..capsule_hemisphere_bands) |band_index| {
        const band: f32 = @floatFromInt(band_index);
        const bands: f32 = @floatFromInt(capsule_hemisphere_bands);
        const angle = (std.math.pi / 2.0) * band / bands;
        fillCapsuleRing(
            &rings[capsule_hemisphere_bands + band_index],
            radius * @cos(angle),
            cylinder_top + radius * @sin(angle),
        );
    }

    var vertices: [capsule_vertex_count]Vertex = undefined;
    var cursor: usize = 0;
    const bottom_pole = [3]f32{ 0, 0, 0 };
    const top_pole = [3]f32{ 0, top, 0 };

    for (0..capsule_segments) |segment| {
        const next = (segment + 1) % capsule_segments;
        const color = capsuleColor(segment);
        // Reversed from mathematical CCW because the pos_color pipeline uses
        // clockwise exterior winding.
        appendTriangle(&vertices, &cursor, bottom_pole, rings[0][next], rings[0][segment], color);
    }
    for (0..capsule_radial_rings - 1) |ring_index| {
        for (0..capsule_segments) |segment| {
            const next = (segment + 1) % capsule_segments;
            const color = capsuleColor(segment);
            appendTriangle(
                &vertices,
                &cursor,
                rings[ring_index][segment],
                rings[ring_index + 1][next],
                rings[ring_index + 1][segment],
                color,
            );
            appendTriangle(
                &vertices,
                &cursor,
                rings[ring_index][segment],
                rings[ring_index][next],
                rings[ring_index + 1][next],
                color,
            );
        }
    }
    const last_ring = capsule_radial_rings - 1;
    for (0..capsule_segments) |segment| {
        const next = (segment + 1) % capsule_segments;
        const color = capsuleColor(segment);
        appendTriangle(&vertices, &cursor, top_pole, rings[last_ring][segment], rings[last_ring][next], color);
    }
    std.debug.assert(cursor == vertices.len);
    return vertices;
}

fn fillCapsuleRing(ring: *[capsule_segments][3]f32, radius: f32, y: f32) void {
    for (0..capsule_segments) |segment| {
        const angle = std.math.tau *
            @as(f32, @floatFromInt(segment)) /
            @as(f32, @floatFromInt(capsule_segments));
        ring[segment] = .{ radius * @cos(angle), y, radius * @sin(angle) };
    }
}

fn appendTriangle(
    vertices: *[capsule_vertex_count]Vertex,
    cursor: *usize,
    a: [3]f32,
    b: [3]f32,
    d: [3]f32,
    color: [3]f32,
) void {
    vertices[cursor.*] = .{ .position = a, .color = color };
    vertices[cursor.* + 1] = .{ .position = b, .color = color };
    vertices[cursor.* + 2] = .{ .position = d, .color = color };
    cursor.* += 3;
}

fn capsuleColor(segment: usize) [3]f32 {
    // Forward is -Z, centered around segment 12 for this parameterization.
    return if (segment >= 11 and segment <= 13)
        .{ 0.12, 0.32, 0.95 }
    else
        .{ 0.95, 0.42, 0.12 };
}

// ============================================================================
// Normal-bearing Product Primitives (VertexPNU format)
// ============================================================================

const VertexPNU = mesh.VertexPNU;

/// Create the shared normal-bearing unit cube used by conventional product
/// solids. Each face carries complete UVs for optional authored textures.
/// Uses CCW winding order to match pos_normal_uv pipeline (glTF convention).
pub fn createLitCube(device: *c.SDL_GPUDevice) !Mesh {
    // Normal vectors for each face
    const n_front = [3]f32{ 0, 0, -1 };
    const n_back = [3]f32{ 0, 0, 1 };
    const n_left = [3]f32{ -1, 0, 0 };
    const n_right = [3]f32{ 1, 0, 0 };
    const n_top = [3]f32{ 0, 1, 0 };
    const n_bottom = [3]f32{ 0, -1, 0 };

    // CCW winding order (when viewed from outside the cube, vertices go counter-clockwise)
    const vertices = [_]VertexPNU{
        // Front face (facing -Z) - viewed from -Z, CCW is: BL -> TL -> TR, BL -> TR -> BR
        .{ .position = .{ -0.5, -0.5, -0.5 }, .normal = n_front, .texcoord = .{ 0, 1 } }, // BL
        .{ .position = .{ -0.5, 0.5, -0.5 }, .normal = n_front, .texcoord = .{ 0, 0 } }, // TL
        .{ .position = .{ 0.5, 0.5, -0.5 }, .normal = n_front, .texcoord = .{ 1, 0 } }, // TR
        .{ .position = .{ -0.5, -0.5, -0.5 }, .normal = n_front, .texcoord = .{ 0, 1 } }, // BL
        .{ .position = .{ 0.5, 0.5, -0.5 }, .normal = n_front, .texcoord = .{ 1, 0 } }, // TR
        .{ .position = .{ 0.5, -0.5, -0.5 }, .normal = n_front, .texcoord = .{ 1, 1 } }, // BR

        // Back face (facing +Z) - viewed from +Z, CCW is: BR -> TR -> TL, BR -> TL -> BL
        .{ .position = .{ 0.5, -0.5, 0.5 }, .normal = n_back, .texcoord = .{ 0, 1 } }, // BR
        .{ .position = .{ 0.5, 0.5, 0.5 }, .normal = n_back, .texcoord = .{ 0, 0 } }, // TR
        .{ .position = .{ -0.5, 0.5, 0.5 }, .normal = n_back, .texcoord = .{ 1, 0 } }, // TL
        .{ .position = .{ 0.5, -0.5, 0.5 }, .normal = n_back, .texcoord = .{ 0, 1 } }, // BR
        .{ .position = .{ -0.5, 0.5, 0.5 }, .normal = n_back, .texcoord = .{ 1, 0 } }, // TL
        .{ .position = .{ -0.5, -0.5, 0.5 }, .normal = n_back, .texcoord = .{ 1, 1 } }, // BL

        // Left face (facing -X) - viewed from -X, CCW
        .{ .position = .{ -0.5, -0.5, 0.5 }, .normal = n_left, .texcoord = .{ 0, 1 } },
        .{ .position = .{ -0.5, 0.5, 0.5 }, .normal = n_left, .texcoord = .{ 0, 0 } },
        .{ .position = .{ -0.5, 0.5, -0.5 }, .normal = n_left, .texcoord = .{ 1, 0 } },
        .{ .position = .{ -0.5, -0.5, 0.5 }, .normal = n_left, .texcoord = .{ 0, 1 } },
        .{ .position = .{ -0.5, 0.5, -0.5 }, .normal = n_left, .texcoord = .{ 1, 0 } },
        .{ .position = .{ -0.5, -0.5, -0.5 }, .normal = n_left, .texcoord = .{ 1, 1 } },

        // Right face (facing +X) - viewed from +X, CCW
        .{ .position = .{ 0.5, -0.5, -0.5 }, .normal = n_right, .texcoord = .{ 0, 1 } },
        .{ .position = .{ 0.5, 0.5, -0.5 }, .normal = n_right, .texcoord = .{ 0, 0 } },
        .{ .position = .{ 0.5, 0.5, 0.5 }, .normal = n_right, .texcoord = .{ 1, 0 } },
        .{ .position = .{ 0.5, -0.5, -0.5 }, .normal = n_right, .texcoord = .{ 0, 1 } },
        .{ .position = .{ 0.5, 0.5, 0.5 }, .normal = n_right, .texcoord = .{ 1, 0 } },
        .{ .position = .{ 0.5, -0.5, 0.5 }, .normal = n_right, .texcoord = .{ 1, 1 } },

        // Top face (facing +Y) - viewed from +Y, CCW
        .{ .position = .{ -0.5, 0.5, -0.5 }, .normal = n_top, .texcoord = .{ 0, 0 } },
        .{ .position = .{ -0.5, 0.5, 0.5 }, .normal = n_top, .texcoord = .{ 0, 1 } },
        .{ .position = .{ 0.5, 0.5, 0.5 }, .normal = n_top, .texcoord = .{ 1, 1 } },
        .{ .position = .{ -0.5, 0.5, -0.5 }, .normal = n_top, .texcoord = .{ 0, 0 } },
        .{ .position = .{ 0.5, 0.5, 0.5 }, .normal = n_top, .texcoord = .{ 1, 1 } },
        .{ .position = .{ 0.5, 0.5, -0.5 }, .normal = n_top, .texcoord = .{ 1, 0 } },

        // Bottom face (facing -Y) - viewed from -Y, CCW
        .{ .position = .{ -0.5, -0.5, 0.5 }, .normal = n_bottom, .texcoord = .{ 0, 0 } },
        .{ .position = .{ -0.5, -0.5, -0.5 }, .normal = n_bottom, .texcoord = .{ 0, 1 } },
        .{ .position = .{ 0.5, -0.5, -0.5 }, .normal = n_bottom, .texcoord = .{ 1, 1 } },
        .{ .position = .{ -0.5, -0.5, 0.5 }, .normal = n_bottom, .texcoord = .{ 0, 0 } },
        .{ .position = .{ 0.5, -0.5, -0.5 }, .normal = n_bottom, .texcoord = .{ 1, 1 } },
        .{ .position = .{ 0.5, -0.5, 0.5 }, .normal = n_bottom, .texcoord = .{ 1, 0 } },
    };

    return Mesh.initTextured(device, &vertices);
}

pub const lit_ground_grid_size: usize = 32;
pub const lit_ground_vertex_count: usize = lit_ground_grid_size * lit_ground_grid_size * 6;

/// Create the 64 m product support plane on the normal-bearing geometry path.
/// Surface color and lighting are supplied explicitly by sandbox composition.
pub fn litGroundVertices() [lit_ground_vertex_count]VertexPNU {
    const tile_size: f32 = 2;
    const half_grid: f32 = @as(f32, lit_ground_grid_size) * tile_size / 2;
    const normal = [3]f32{ 0, 1, 0 };
    var vertices: [lit_ground_vertex_count]VertexPNU = undefined;
    var cursor: usize = 0;
    for (0..lit_ground_grid_size) |zi| {
        for (0..lit_ground_grid_size) |xi| {
            const x: f32 = @as(f32, @floatFromInt(xi)) * tile_size - half_grid;
            const z: f32 = @as(f32, @floatFromInt(zi)) * tile_size - half_grid;
            const uv_x: f32 = @floatFromInt(xi);
            const uv_z: f32 = @floatFromInt(zi);
            const p0 = VertexPNU{ .position = .{ x, 0, z }, .normal = normal, .texcoord = .{ uv_x, uv_z } };
            const p1 = VertexPNU{ .position = .{ x + tile_size, 0, z }, .normal = normal, .texcoord = .{ uv_x + 1, uv_z } };
            const p2 = VertexPNU{ .position = .{ x + tile_size, 0, z + tile_size }, .normal = normal, .texcoord = .{ uv_x + 1, uv_z + 1 } };
            const p3 = VertexPNU{ .position = .{ x, 0, z + tile_size }, .normal = normal, .texcoord = .{ uv_x, uv_z + 1 } };
            vertices[cursor] = p0;
            vertices[cursor + 1] = p2;
            vertices[cursor + 2] = p1;
            vertices[cursor + 3] = p0;
            vertices[cursor + 4] = p3;
            vertices[cursor + 5] = p2;
            cursor += 6;
        }
    }
    std.debug.assert(cursor == vertices.len);
    return vertices;
}

pub fn createLitGroundPlane(device: *c.SDL_GPUDevice) !Mesh {
    const vertices = litGroundVertices();
    return Mesh.initTextured(device, &vertices);
}

/// Convert the canonical wheel geometry to CCW normal-bearing triangles. A
/// separate authored spoke is used for exact roll readability.
pub fn litWheelCylinderVertices() [wheel_vertex_count]VertexPNU {
    const source = wheelCylinderScaffold();
    var result: [wheel_vertex_count]VertexPNU = undefined;
    var triangle: usize = 0;
    while (triangle < source.len) : (triangle += 3) {
        const a = source[triangle].position;
        const b = source[triangle + 2].position;
        const d = source[triangle + 1].position;
        const normal = triangleNormal(a, b, d);
        result[triangle] = .{ .position = a, .normal = normal, .texcoord = .{ 0, 0 } };
        result[triangle + 1] = .{ .position = b, .normal = normal, .texcoord = .{ 0, 1 } };
        result[triangle + 2] = .{ .position = d, .normal = normal, .texcoord = .{ 1, 0 } };
    }
    return result;
}

pub fn createLitWheelCylinder(device: *c.SDL_GPUDevice) !Mesh {
    const vertices = litWheelCylinderVertices();
    return Mesh.initTextured(device, &vertices);
}

/// Normal-bearing version of the physical capsule retained by graphical
/// network clients and semantic visibility fixtures.
pub fn litCharacterCapsuleVertices(
    radius: f32,
    half_height: f32,
) [capsule_vertex_count]VertexPNU {
    const source = characterCapsuleScaffold(radius, half_height);
    var result: [capsule_vertex_count]VertexPNU = undefined;
    var triangle: usize = 0;
    while (triangle < source.len) : (triangle += 3) {
        const a = source[triangle].position;
        const b = source[triangle + 2].position;
        const d = source[triangle + 1].position;
        const normal = triangleNormal(a, b, d);
        result[triangle] = .{ .position = a, .normal = normal, .texcoord = .{ 0, 0 } };
        result[triangle + 1] = .{ .position = b, .normal = normal, .texcoord = .{ 0, 1 } };
        result[triangle + 2] = .{ .position = d, .normal = normal, .texcoord = .{ 1, 0 } };
    }
    return result;
}

pub fn createLitCharacterCapsule(
    device: *c.SDL_GPUDevice,
    radius: f32,
    half_height: f32,
) !Mesh {
    const vertices = litCharacterCapsuleVertices(radius, half_height);
    return Mesh.initTextured(device, &vertices);
}

fn triangleNormal(a: [3]f32, b: [3]f32, d: [3]f32) [3]f32 {
    const ab = [3]f32{ b[0] - a[0], b[1] - a[1], b[2] - a[2] };
    const ad = [3]f32{ d[0] - a[0], d[1] - a[1], d[2] - a[2] };
    const cross = [3]f32{
        ab[1] * ad[2] - ab[2] * ad[1],
        ab[2] * ad[0] - ab[0] * ad[2],
        ab[0] * ad[1] - ab[1] * ad[0],
    };
    const length = @sqrt(cross[0] * cross[0] + cross[1] * cross[1] + cross[2] * cross[2]);
    std.debug.assert(std.math.isFinite(length) and length > 0.000001);
    return .{ cross[0] / length, cross[1] / length, cross[2] / length };
}

test "lit procedural product geometry is finite normal bearing and CCW" {
    const ground = litGroundVertices();
    const wheel = litWheelCylinderVertices();
    const character = litCharacterCapsuleVertices(0.4, 0.5);
    for (ground ++ wheel ++ character) |vertex| {
        for (vertex.position ++ vertex.normal ++ vertex.texcoord) |value| {
            try std.testing.expect(std.math.isFinite(value));
        }
        const length_squared = vertex.normal[0] * vertex.normal[0] +
            vertex.normal[1] * vertex.normal[1] +
            vertex.normal[2] * vertex.normal[2];
        try std.testing.expectApproxEqAbs(@as(f32, 1), length_squared, 0.0001);
    }
}

test "character capsule geometry is finite and bottom anchored" {
    const radius: f32 = 0.4;
    const half_height: f32 = 0.5;
    const vertices = characterCapsuleScaffold(radius, half_height);
    try std.testing.expectEqual(capsule_vertex_count, vertices.len);
    var minimum_y = std.math.inf(f32);
    var maximum_y = -std.math.inf(f32);
    var saw_forward_color = false;
    for (vertices) |vertex| {
        for (vertex.position) |value| try std.testing.expect(std.math.isFinite(value));
        minimum_y = @min(minimum_y, vertex.position[1]);
        maximum_y = @max(maximum_y, vertex.position[1]);
        saw_forward_color = saw_forward_color or vertex.color[2] > 0.9;
    }
    try std.testing.expectApproxEqAbs(@as(f32, 0), minimum_y, 0.00001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.8), maximum_y, 0.00001);
    try std.testing.expect(saw_forward_color);

    const top_center_y = radius + half_height * 2.0;
    var triangle_index: usize = 0;
    while (triangle_index < vertices.len) : (triangle_index += 3) {
        const a = vertices[triangle_index].position;
        const b = vertices[triangle_index + 1].position;
        const d = vertices[triangle_index + 2].position;
        const ab = [3]f32{ b[0] - a[0], b[1] - a[1], b[2] - a[2] };
        const ad = [3]f32{ d[0] - a[0], d[1] - a[1], d[2] - a[2] };
        const normal = [3]f32{
            ab[1] * ad[2] - ab[2] * ad[1],
            ab[2] * ad[0] - ab[0] * ad[2],
            ab[0] * ad[1] - ab[1] * ad[0],
        };
        const center = [3]f32{
            (a[0] + b[0] + d[0]) / 3.0,
            (a[1] + b[1] + d[1]) / 3.0,
            (a[2] + b[2] + d[2]) / 3.0,
        };
        const outward = if (center[1] < radius)
            [3]f32{ center[0], center[1] - radius, center[2] }
        else if (center[1] > top_center_y)
            [3]f32{ center[0], center[1] - top_center_y, center[2] }
        else
            [3]f32{ center[0], 0, center[2] };
        const orientation = normal[0] * outward[0] +
            normal[1] * outward[1] +
            normal[2] * outward[2];
        try std.testing.expect(orientation < 0);
    }
}

test "wheel cylinder geometry follows the canonical axle and winding" {
    const vertices = wheelCylinderScaffold();
    try std.testing.expectEqual(wheel_vertex_count, vertices.len);

    var minimum = [3]f32{ std.math.inf(f32), std.math.inf(f32), std.math.inf(f32) };
    var maximum = [3]f32{ -std.math.inf(f32), -std.math.inf(f32), -std.math.inf(f32) };
    var saw_rotation_marker = false;
    for (vertices) |vertex| {
        for (vertex.position, 0..) |value, axis| {
            try std.testing.expect(std.math.isFinite(value));
            minimum[axis] = @min(minimum[axis], value);
            maximum[axis] = @max(maximum[axis], value);
        }
        for (vertex.color) |value| try std.testing.expect(std.math.isFinite(value));
        saw_rotation_marker = saw_rotation_marker or vertex.color[0] > 0.9;
    }
    for (minimum) |value| {
        try std.testing.expectApproxEqAbs(@as(f32, -0.5), value, 0.00001);
    }
    for (maximum) |value| {
        try std.testing.expectApproxEqAbs(@as(f32, 0.5), value, 0.00001);
    }
    try std.testing.expect(saw_rotation_marker);

    var triangle_index: usize = 0;
    while (triangle_index < vertices.len) : (triangle_index += 3) {
        const a = vertices[triangle_index].position;
        const b = vertices[triangle_index + 1].position;
        const d = vertices[triangle_index + 2].position;
        const ab = [3]f32{ b[0] - a[0], b[1] - a[1], b[2] - a[2] };
        const ad = [3]f32{ d[0] - a[0], d[1] - a[1], d[2] - a[2] };
        const normal = [3]f32{
            ab[1] * ad[2] - ab[2] * ad[1],
            ab[2] * ad[0] - ab[0] * ad[2],
            ab[0] * ad[1] - ab[1] * ad[0],
        };
        const normal_length_squared = normal[0] * normal[0] +
            normal[1] * normal[1] +
            normal[2] * normal[2];
        try std.testing.expect(normal_length_squared > 0.000001);

        const center = [3]f32{
            (a[0] + b[0] + d[0]) / 3.0,
            (a[1] + b[1] + d[1]) / 3.0,
            (a[2] + b[2] + d[2]) / 3.0,
        };
        const is_cap = a[0] == b[0] and b[0] == d[0];
        const outward = if (is_cap)
            [3]f32{ if (center[0] < 0) -1 else 1, 0, 0 }
        else
            [3]f32{ 0, center[1], center[2] };
        const orientation = normal[0] * outward[0] +
            normal[1] * outward[1] +
            normal[2] * outward[2];
        try std.testing.expect(orientation < 0);
    }
}
