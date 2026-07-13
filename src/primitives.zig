//! primitives.zig - Built-in geometric primitives
//!
//! DOMAIN: Asset/Resource Layer (factory functions)
//!
//! This module provides factory functions to create common geometric shapes.
//! It contains the actual vertex DATA for built-in primitives and knows how
//! to construct Mesh objects from that data.
//!
//! Responsibilities:
//! - Define vertex data for built-in shapes (triangle, cube, sphere, etc.)
//! - Provide simple factory functions: createTriangle(), createCube(), etc.
//! - Encapsulate the "recipe" for each primitive
//!
//! This module does NOT:
//! - Store or cache created meshes (caller owns the Mesh)
//! - Know about GPU internals (delegates to Mesh.init)
//! - Know where primitives are used in the scene
//!
//! Usage:
//!   const triangle = try primitives.createTriangle(device);
//!   defer triangle.deinit();
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
// Triangle
// ============================================================================

/// The classic RGB triangle - a simple test primitive.
/// Vertices are in normalized device coordinates (-1 to 1).
const triangle_vertices = [_]Vertex{
    // Bottom-left: Red
    .{ .position = .{ -0.5, -0.5, 0.0 }, .color = .{ 1.0, 0.0, 0.0 } },
    // Bottom-right: Green
    .{ .position = .{ 0.5, -0.5, 0.0 }, .color = .{ 0.0, 1.0, 0.0 } },
    // Top-center: Blue
    .{ .position = .{ 0.0, 0.5, 0.0 }, .color = .{ 0.0, 0.0, 1.0 } },
};

/// Create the classic RGB gradient triangle.
pub fn createTriangle(device: *c.SDL_GPUDevice) !Mesh {
    return Mesh.init(device, &triangle_vertices);
}

// ============================================================================
// Cube
// ============================================================================

/// A unit cube centered at origin (-0.5 to 0.5 on each axis).
/// Each face has a different color for easy orientation:
/// - Front (−Z): Red
/// - Back (+Z): Cyan
/// - Left (−X): Green
/// - Right (+X): Magenta
/// - Top (+Y): Blue
/// - Bottom (−Y): Yellow
const cube_vertices = [_]Vertex{
    // Front face (facing -Z) - RED
    .{ .position = .{ -0.5, -0.5, -0.5 }, .color = .{ 1.0, 0.0, 0.0 } },
    .{ .position = .{ 0.5, -0.5, -0.5 }, .color = .{ 1.0, 0.0, 0.0 } },
    .{ .position = .{ 0.5, 0.5, -0.5 }, .color = .{ 1.0, 0.0, 0.0 } },
    .{ .position = .{ -0.5, -0.5, -0.5 }, .color = .{ 1.0, 0.0, 0.0 } },
    .{ .position = .{ 0.5, 0.5, -0.5 }, .color = .{ 1.0, 0.0, 0.0 } },
    .{ .position = .{ -0.5, 0.5, -0.5 }, .color = .{ 1.0, 0.0, 0.0 } },

    // Back face (facing +Z) - CYAN
    .{ .position = .{ 0.5, -0.5, 0.5 }, .color = .{ 0.0, 1.0, 1.0 } },
    .{ .position = .{ -0.5, -0.5, 0.5 }, .color = .{ 0.0, 1.0, 1.0 } },
    .{ .position = .{ -0.5, 0.5, 0.5 }, .color = .{ 0.0, 1.0, 1.0 } },
    .{ .position = .{ 0.5, -0.5, 0.5 }, .color = .{ 0.0, 1.0, 1.0 } },
    .{ .position = .{ -0.5, 0.5, 0.5 }, .color = .{ 0.0, 1.0, 1.0 } },
    .{ .position = .{ 0.5, 0.5, 0.5 }, .color = .{ 0.0, 1.0, 1.0 } },

    // Left face (facing -X) - GREEN
    .{ .position = .{ -0.5, -0.5, 0.5 }, .color = .{ 0.0, 1.0, 0.0 } },
    .{ .position = .{ -0.5, -0.5, -0.5 }, .color = .{ 0.0, 1.0, 0.0 } },
    .{ .position = .{ -0.5, 0.5, -0.5 }, .color = .{ 0.0, 1.0, 0.0 } },
    .{ .position = .{ -0.5, -0.5, 0.5 }, .color = .{ 0.0, 1.0, 0.0 } },
    .{ .position = .{ -0.5, 0.5, -0.5 }, .color = .{ 0.0, 1.0, 0.0 } },
    .{ .position = .{ -0.5, 0.5, 0.5 }, .color = .{ 0.0, 1.0, 0.0 } },

    // Right face (facing +X) - MAGENTA
    .{ .position = .{ 0.5, -0.5, -0.5 }, .color = .{ 1.0, 0.0, 1.0 } },
    .{ .position = .{ 0.5, -0.5, 0.5 }, .color = .{ 1.0, 0.0, 1.0 } },
    .{ .position = .{ 0.5, 0.5, 0.5 }, .color = .{ 1.0, 0.0, 1.0 } },
    .{ .position = .{ 0.5, -0.5, -0.5 }, .color = .{ 1.0, 0.0, 1.0 } },
    .{ .position = .{ 0.5, 0.5, 0.5 }, .color = .{ 1.0, 0.0, 1.0 } },
    .{ .position = .{ 0.5, 0.5, -0.5 }, .color = .{ 1.0, 0.0, 1.0 } },

    // Top face (facing +Y) - BLUE
    .{ .position = .{ -0.5, 0.5, -0.5 }, .color = .{ 0.0, 0.0, 1.0 } },
    .{ .position = .{ 0.5, 0.5, -0.5 }, .color = .{ 0.0, 0.0, 1.0 } },
    .{ .position = .{ 0.5, 0.5, 0.5 }, .color = .{ 0.0, 0.0, 1.0 } },
    .{ .position = .{ -0.5, 0.5, -0.5 }, .color = .{ 0.0, 0.0, 1.0 } },
    .{ .position = .{ 0.5, 0.5, 0.5 }, .color = .{ 0.0, 0.0, 1.0 } },
    .{ .position = .{ -0.5, 0.5, 0.5 }, .color = .{ 0.0, 0.0, 1.0 } },

    // Bottom face (facing -Y) - YELLOW
    .{ .position = .{ -0.5, -0.5, 0.5 }, .color = .{ 1.0, 1.0, 0.0 } },
    .{ .position = .{ 0.5, -0.5, 0.5 }, .color = .{ 1.0, 1.0, 0.0 } },
    .{ .position = .{ 0.5, -0.5, -0.5 }, .color = .{ 1.0, 1.0, 0.0 } },
    .{ .position = .{ -0.5, -0.5, 0.5 }, .color = .{ 1.0, 1.0, 0.0 } },
    .{ .position = .{ 0.5, -0.5, -0.5 }, .color = .{ 1.0, 1.0, 0.0 } },
    .{ .position = .{ -0.5, -0.5, -0.5 }, .color = .{ 1.0, 1.0, 0.0 } },
};

/// Create a unit cube centered at origin.
pub fn createCube(device: *c.SDL_GPUDevice) !Mesh {
    return Mesh.init(device, &cube_vertices);
}

// ============================================================================
// Wheel Cylinder
// ============================================================================

pub const wheel_segments: usize = 16;
pub const wheel_triangle_count: usize = wheel_segments * 4;
pub const wheel_vertex_count: usize = wheel_triangle_count * 3;

/// Generate a centered unit wheel cylinder. Its axle is +X, matching the
/// engine physics contract; callers scale X by wheel width and Y/Z by wheel
/// diameter. One orange segment makes rotation visible in the debug sandbox.
pub fn wheelCylinderVertices() [wheel_vertex_count]Vertex {
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

pub fn createWheelCylinder(device: *c.SDL_GPUDevice) !Mesh {
    const vertices = wheelCylinderVertices();
    return Mesh.init(device, &vertices);
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
pub fn characterCapsuleVertices(
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

pub fn createCharacterCapsule(
    device: *c.SDL_GPUDevice,
    radius: f32,
    half_height: f32,
) !Mesh {
    if (!std.math.isFinite(radius) or radius <= 0 or
        !std.math.isFinite(half_height) or half_height <= 0)
    {
        return error.InvalidCapsuleDimensions;
    }
    const vertices = characterCapsuleVertices(radius, half_height);
    return Mesh.init(device, &vertices);
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
// Ground Plane (Checkerboard)
// ============================================================================

/// Create a checkerboard ground plane - classic debug pattern.
/// Grid is centered at origin in XZ plane, facing up (+Y).
/// Uses 1 unit = 1 meter convention. Each tile is 2m for good visibility.
/// 32x32 tiles = 64m x 64m coverage (no scaling needed).
pub fn createGroundPlane(device: *c.SDL_GPUDevice) !Mesh {
    const grid_size = 32; // 32x32 tiles for good coverage
    const tile_size: f32 = 2.0; // 2 meters per tile (good for visibility)
    const half_grid: f32 = @as(f32, grid_size) * tile_size / 2.0;

    // Colors: light gray and dark gray for classic checkerboard
    const color_a = [3]f32{ 0.7, 0.7, 0.7 }; // Light
    const color_b = [3]f32{ 0.3, 0.3, 0.3 }; // Dark

    // 6 vertices per tile (2 triangles)
    var vertices: [grid_size * grid_size * 6]Vertex = undefined;
    var idx: usize = 0;

    for (0..grid_size) |zi| {
        for (0..grid_size) |xi| {
            const x: f32 = @as(f32, @floatFromInt(xi)) * tile_size - half_grid;
            const z: f32 = @as(f32, @floatFromInt(zi)) * tile_size - half_grid;

            // Checkerboard pattern: alternate based on sum of indices
            const color = if ((xi + zi) % 2 == 0) color_a else color_b;

            // Two triangles for this tile
            vertices[idx + 0] = .{ .position = .{ x, 0, z }, .color = color };
            vertices[idx + 1] = .{ .position = .{ x + tile_size, 0, z }, .color = color };
            vertices[idx + 2] = .{ .position = .{ x + tile_size, 0, z + tile_size }, .color = color };
            vertices[idx + 3] = .{ .position = .{ x, 0, z }, .color = color };
            vertices[idx + 4] = .{ .position = .{ x + tile_size, 0, z + tile_size }, .color = color };
            vertices[idx + 5] = .{ .position = .{ x, 0, z + tile_size }, .color = color };
            idx += 6;
        }
    }

    return Mesh.init(device, &vertices);
}

// ============================================================================
// Textured Debug Primitives (VertexPNU format)
// ============================================================================
// These primitives have UV coordinates for texture mapping.
// Use with checkerboard textures for classic physics debug visualization.

const VertexPNU = mesh.VertexPNU;

/// Create a textured unit cube with proper UV mapping.
/// Each face gets UV 0-1, so texture tiles once per face.
/// Great for debug visualization with checkerboard textures.
/// Uses CCW winding order to match pos_normal_uv pipeline (glTF convention).
pub fn createTexturedCube(device: *c.SDL_GPUDevice) !Mesh {
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

// ============================================================================
// Future Primitives (placeholders)
// ============================================================================

// pub fn createSphere(device: *c.SDL_GPUDevice, segments: u32) !Mesh { ... }
// pub fn createCapsule(device: *c.SDL_GPUDevice, segments: u32) !Mesh { ... }

test "character capsule geometry is finite and bottom anchored" {
    const radius: f32 = 0.4;
    const half_height: f32 = 0.5;
    const vertices = characterCapsuleVertices(radius, half_height);
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
    const vertices = wheelCylinderVertices();
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
