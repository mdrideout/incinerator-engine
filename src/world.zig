//! world.zig - Scene/World management
//!
//! DOMAIN: Scene Layer
//!
//! This module manages the collection of entities that exist in the game world.
//! It's the "what to render" layer - it knows which objects exist and where they
//! are, but delegates the actual rendering to the renderer.
//!
//! Responsibilities:
//! - Store and manage entities (things that can be rendered)
//! - Track entity transforms (position, rotation, scale)
//! - Provide iteration over entities for rendering
//! - (Future) Spatial organization for culling/queries
//!
//! This module does NOT:
//! - Perform rendering (that's renderer.zig)
//! - Own mesh data (meshes are referenced, not owned)
//! - Contain game logic (that's game.zig or entity-specific code)
//!
//! Architecture note:
//! Currently uses a simple array of entities. As the engine grows, this may
//! evolve into an ECS (Entity Component System) or scene graph with parent-
//! child hierarchies.
//!
//! Future additions:
//! - Entity spawning/despawning
//! - Spatial partitioning (octree, BVH) for frustum culling
//! - Parent-child transform hierarchies
//! - Entity queries by tag/type

const std = @import("std");
const mesh = @import("mesh.zig");

const Mesh = mesh.Mesh;

// ============================================================================
// Transform
// ============================================================================

/// Transform represents an entity's position, rotation, and scale in 3D space.
///
/// NOTE: Currently a placeholder! Transforms are stored but NOT yet applied
/// during rendering. We need to add uniform buffers to pass transform matrices
/// to the vertex shader before this will have any visual effect.
///
/// Future: This will contain a Mat4 or decomposed pos/rot/scale with methods
/// to compute the final model matrix.
pub const Transform = struct {
    position: [3]f32 = .{ 0, 0, 0 },
    rotation: [3]f32 = .{ 0, 0, 0 }, // Euler angles (placeholder)
    scale: [3]f32 = .{ 1, 1, 1 },

    pub const identity = Transform{};

    // Future methods:
    // pub fn toMatrix(self: Transform) Mat4 { ... }
    // pub fn translate(self: *Transform, delta: Vec3) void { ... }
    // pub fn rotate(self: *Transform, axis: Vec3, angle: f32) void { ... }
};

// ============================================================================
// Entity
// ============================================================================

/// An Entity is something that exists in the world and can be rendered.
///
/// Currently minimal - just a mesh reference and transform. Will grow to
/// include materials, components, tags, etc.
pub const Entity = struct {
    mesh: *Mesh,
    transform: Transform,

    // Future fields:
    // material: *Material,
    // visible: bool = true,
    // tags: TagSet,
    // components: ComponentList,
};

// ============================================================================
// World
// ============================================================================

/// Maximum entities supported. Static for simplicity; will become dynamic.
const MAX_ENTITIES: usize = 1024;

/// The World holds all entities in the scene.
///
/// Currently a simple fixed-size array. Provides iteration for the renderer
/// and basic add/remove operations.
pub const World = struct {
    entities: [MAX_ENTITIES]Entity = undefined,
    entity_count: usize = 0,

    pub fn init() World {
        return World{};
    }

    /// Add an entity to the world. Returns error if world is full.
    pub fn spawn(self: *World, entity: Entity) !*Entity {
        if (self.entity_count >= MAX_ENTITIES) {
            return error.WorldFull;
        }
        self.entities[self.entity_count] = entity;
        self.entity_count += 1;
        return &self.entities[self.entity_count - 1];
    }

    /// Iterate over all entities (for rendering).
    pub fn iterator(self: *World) []Entity {
        return self.entities[0..self.entity_count];
    }

    /// Number of entities in the world.
    pub fn count(self: *const World) usize {
        return self.entity_count;
    }

    // Future methods:
    // pub fn despawn(self: *World, entity: *Entity) void { ... }
    // pub fn clear(self: *World) void { ... }
    // pub fn findByTag(self: *World, tag: Tag) []Entity { ... }

    pub fn deinit(self: *World) void {
        // Currently entities don't own their meshes, so nothing to clean up.
        // This will change when entities own components.
        _ = self;
    }
};
