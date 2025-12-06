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

/// Create a cylinder primitive with UV mapping.
/// Height is 1 unit (Y axis), radius is 0.5 units.
/// comptime segments: number of sides (more = smoother, 16-32 typical)
/// Uses CCW winding order to match pos_normal_uv pipeline (glTF convention).
pub fn createCylinder(device: *c.SDL_GPUDevice, comptime segments: u32) !Mesh {
    const segs = if (segments < 8) 8 else segments;

    // Each segment of the side needs 6 vertices (2 triangles)
    // Top cap: segs * 3 vertices (triangle fan as individual triangles)
    // Bottom cap: segs * 3 vertices
    const side_verts = segs * 6;
    const cap_verts = segs * 3 * 2; // top and bottom
    const total_verts = side_verts + cap_verts;

    var vertices: [total_verts]VertexPNU = undefined;
    var idx: usize = 0;

    const radius: f32 = 0.5;
    const half_height: f32 = 0.5;
    const pi = std.math.pi;

    // Generate side vertices (CCW winding when viewed from outside)
    for (0..segs) |i| {
        const angle0 = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segs)) * 2.0 * pi;
        const angle1 = @as(f32, @floatFromInt(i + 1)) / @as(f32, @floatFromInt(segs)) * 2.0 * pi;

        const x0 = @cos(angle0) * radius;
        const z0 = @sin(angle0) * radius;
        const x1 = @cos(angle1) * radius;
        const z1 = @sin(angle1) * radius;

        // Normal is perpendicular to surface (points outward)
        const n0 = [3]f32{ @cos(angle0), 0, @sin(angle0) };
        const n1 = [3]f32{ @cos(angle1), 0, @sin(angle1) };

        // UV: tex_u wraps around (0-1 over full circumference), v is height (0-1)
        const tex_u0 = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segs));
        const tex_u1 = @as(f32, @floatFromInt(i + 1)) / @as(f32, @floatFromInt(segs));

        // Triangle 1 (CCW: bottom-left, top-left, top-right)
        vertices[idx] = .{ .position = .{ x0, -half_height, z0 }, .normal = n0, .texcoord = .{ tex_u0, 1 } };
        idx += 1;
        vertices[idx] = .{ .position = .{ x0, half_height, z0 }, .normal = n0, .texcoord = .{ tex_u0, 0 } };
        idx += 1;
        vertices[idx] = .{ .position = .{ x1, half_height, z1 }, .normal = n1, .texcoord = .{ tex_u1, 0 } };
        idx += 1;

        // Triangle 2 (CCW: bottom-left, top-right, bottom-right)
        vertices[idx] = .{ .position = .{ x0, -half_height, z0 }, .normal = n0, .texcoord = .{ tex_u0, 1 } };
        idx += 1;
        vertices[idx] = .{ .position = .{ x1, half_height, z1 }, .normal = n1, .texcoord = .{ tex_u1, 0 } };
        idx += 1;
        vertices[idx] = .{ .position = .{ x1, -half_height, z1 }, .normal = n1, .texcoord = .{ tex_u1, 1 } };
        idx += 1;
    }

    // Generate top cap (facing +Y) - CCW when viewed from above
    const n_top = [3]f32{ 0, 1, 0 };
    for (0..segs) |i| {
        const angle0 = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segs)) * 2.0 * pi;
        const angle1 = @as(f32, @floatFromInt(i + 1)) / @as(f32, @floatFromInt(segs)) * 2.0 * pi;

        const x0 = @cos(angle0) * radius;
        const z0 = @sin(angle0) * radius;
        const x1 = @cos(angle1) * radius;
        const z1 = @sin(angle1) * radius;

        // UV maps to unit circle on cap (CCW: center, edge1, edge0)
        vertices[idx] = .{ .position = .{ 0, half_height, 0 }, .normal = n_top, .texcoord = .{ 0.5, 0.5 } };
        idx += 1;
        vertices[idx] = .{ .position = .{ x1, half_height, z1 }, .normal = n_top, .texcoord = .{ x1 + 0.5, z1 + 0.5 } };
        idx += 1;
        vertices[idx] = .{ .position = .{ x0, half_height, z0 }, .normal = n_top, .texcoord = .{ x0 + 0.5, z0 + 0.5 } };
        idx += 1;
    }

    // Generate bottom cap (facing -Y) - CCW when viewed from below
    const n_bottom = [3]f32{ 0, -1, 0 };
    for (0..segs) |i| {
        const angle0 = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segs)) * 2.0 * pi;
        const angle1 = @as(f32, @floatFromInt(i + 1)) / @as(f32, @floatFromInt(segs)) * 2.0 * pi;

        const x0 = @cos(angle0) * radius;
        const z0 = @sin(angle0) * radius;
        const x1 = @cos(angle1) * radius;
        const z1 = @sin(angle1) * radius;

        // CCW when viewed from below: center, edge0, edge1
        vertices[idx] = .{ .position = .{ 0, -half_height, 0 }, .normal = n_bottom, .texcoord = .{ 0.5, 0.5 } };
        idx += 1;
        vertices[idx] = .{ .position = .{ x0, -half_height, z0 }, .normal = n_bottom, .texcoord = .{ x0 + 0.5, z0 + 0.5 } };
        idx += 1;
        vertices[idx] = .{ .position = .{ x1, -half_height, z1 }, .normal = n_bottom, .texcoord = .{ x1 + 0.5, z1 + 0.5 } };
        idx += 1;
    }

    return Mesh.initTextured(device, vertices[0..idx]);
}

// ============================================================================
// Future Primitives (placeholders)
// ============================================================================

// pub fn createSphere(device: *c.SDL_GPUDevice, segments: u32) !Mesh { ... }
// pub fn createCapsule(device: *c.SDL_GPUDevice, segments: u32) !Mesh { ... }
