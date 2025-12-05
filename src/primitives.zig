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
// Future Primitives (placeholders)
// ============================================================================

// pub fn createQuad(device: *c.SDL_GPUDevice) !Mesh { ... }
// pub fn createCube(device: *c.SDL_GPUDevice) !Mesh { ... }
// pub fn createSphere(device: *c.SDL_GPUDevice, segments: u32) !Mesh { ... }
// pub fn createGrid(device: *c.SDL_GPUDevice, size: f32, divisions: u32) !Mesh { ... }
