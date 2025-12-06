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
// Future Primitives (placeholders)
// ============================================================================

// pub fn createSphere(device: *c.SDL_GPUDevice, segments: u32) !Mesh { ... }
// pub fn createGrid(device: *c.SDL_GPUDevice, size: f32, divisions: u32) !Mesh { ... }
