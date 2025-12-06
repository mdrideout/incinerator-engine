//! ecs.zig - Entity Component System (zflecs wrapper)
//!
//! DOMAIN: Scene Layer
//!
//! This module wraps the flecs ECS library (via zflecs) to provide high-performance
//! entity management for the game engine. All game objects (vehicles, NPCs, props,
//! debris, particles) are represented as entities with components.
//!
//! Architecture:
//! - **Entity**: Just an ID (u64). No data stored on the entity itself.
//! - **Component**: Pure data structs (Position, Rotation, Mesh reference, etc.)
//! - **System**: Functions that operate on entities with specific component combinations
//!
//! Why ECS?
//! ---------
//! 1. **Cache Efficiency**: Archetype storage keeps similar entities together in memory
//! 2. **Scalability**: Efficiently handles 10,000+ entities (vehicles, debris, NPCs)
//! 3. **Flexibility**: Add/remove components at runtime without changing entity type
//! 4. **Relationships**: flecs supports parent-child hierarchies (car → wheels)
//!
//! For a GTA-style game with multi-car pileups and explosions, this architecture
//! enables smooth physics simulation at scale.
//!
//! Usage:
//! ```zig
//! var game = GameWorld.init();
//! defer game.deinit();
//!
//! // Spawn an entity with components
//! const car = game.spawn(.{
//!     .position = .{ 0, 0, 0 },
//!     .rotation = .{ 0, 0, 0, 1 },
//!     .scale = .{ 1, 1, 1 },
//!     .mesh = &car_mesh,
//! });
//!
//! // Query all renderable entities
//! var iter = game.renderables();
//! while (iter.next()) |entity| {
//!     renderer.drawMesh(entity.mesh, entity.transform);
//! }
//! ```

const std = @import("std");
const flecs = @import("zflecs");
const zm = @import("zmath");
const mesh_module = @import("mesh.zig");

// ============================================================================
// Components
// ============================================================================
// Components are pure data - no methods, no logic. They represent aspects of
// an entity that can be combined freely.
//
// Naming convention: Components are simple nouns (Position, not PositionComponent)

/// 3D position in world space (meters)
pub const Position = struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,

    pub fn toVec(self: Position) zm.Vec {
        return zm.f32x4(self.x, self.y, self.z, 1.0);
    }

    pub fn fromVec(v: zm.Vec) Position {
        return .{ .x = v[0], .y = v[1], .z = v[2] };
    }
};

/// 3D rotation as Euler angles (radians)
/// For physics, we'll eventually use quaternions, but Euler is easier to debug
pub const Rotation = struct {
    x: f32 = 0, // Pitch
    y: f32 = 0, // Yaw
    z: f32 = 0, // Roll

    pub fn toMatrix(self: Rotation) zm.Mat {
        // Build rotation matrix from Euler angles (YXZ order for typical FPS camera)
        const rot_x = zm.rotationX(self.x);
        const rot_y = zm.rotationY(self.y);
        const rot_z = zm.rotationZ(self.z);
        return zm.mul(zm.mul(rot_z, rot_x), rot_y);
    }
};

/// 3D scale (uniform or non-uniform)
pub const Scale = struct {
    x: f32 = 1,
    y: f32 = 1,
    z: f32 = 1,

    pub fn uniform(s: f32) Scale {
        return .{ .x = s, .y = s, .z = s };
    }

    pub fn toMatrix(self: Scale) zm.Mat {
        return zm.scaling(self.x, self.y, self.z);
    }
};

/// Reference to a renderable mesh
/// This is a component that points to mesh data (not owned by the entity)
pub const Renderable = struct {
    mesh: *mesh_module.Mesh,
};

/// Optional name for debugging (stored as a flecs built-in)
pub const Name = struct {
    value: [:0]const u8,
};

// ============================================================================
// Tags
// ============================================================================
// Tags are marker components with no data - used for filtering/categorization

/// Marks an entity as static (won't move, can be optimized)
pub const Static = struct {};

/// Marks an entity as a vehicle
pub const Vehicle = struct {};

/// Marks an entity as debris (from explosions, etc.)
pub const Debris = struct {};

// ============================================================================
// GameWorld - Main ECS Interface
// ============================================================================

/// The game world manages all entities and provides query interfaces.
/// This is the main entry point for ECS operations.
pub const GameWorld = struct {
    world: *flecs.world_t,
    renderable_query: *flecs.query_t,
    entity_count: i32 = 0, // Track manually since flecs doesn't expose this directly

    /// Initialize the ECS world and register all components
    pub fn init() GameWorld {
        const world = flecs.init();

        // Register components - this tells flecs about our data types
        // Must be done before using the components
        flecs.COMPONENT(world, Position);
        flecs.COMPONENT(world, Rotation);
        flecs.COMPONENT(world, Scale);
        flecs.COMPONENT(world, Renderable);

        // Register tags
        flecs.TAG(world, Static);
        flecs.TAG(world, Vehicle);
        flecs.TAG(world, Debris);

        // Create the renderable query once (cached for performance)
        var query_desc = flecs.query_desc_t{};
        query_desc.terms[0] = .{ .id = flecs.id(Position) };
        query_desc.terms[1] = .{ .id = flecs.id(Rotation) };
        query_desc.terms[2] = .{ .id = flecs.id(Scale) };
        query_desc.terms[3] = .{ .id = flecs.id(Renderable) };

        const renderable_query = flecs.query_init(world, &query_desc) catch {
            std.debug.print("Failed to create renderable query\n", .{});
            @panic("ECS query init failed");
        };

        std.debug.print("ECS World initialized (flecs)\n", .{});

        return .{
            .world = world,
            .renderable_query = renderable_query,
            .entity_count = 0,
        };
    }

    /// Shutdown the ECS world
    pub fn deinit(self: *GameWorld) void {
        flecs.query_fini(self.renderable_query);
        _ = flecs.fini(self.world);
        std.debug.print("ECS World shutdown\n", .{});
    }

    // ========================================================================
    // Entity Spawning
    // ========================================================================

    /// Spawn options - which components to add to a new entity
    pub const SpawnOptions = struct {
        name: ?[:0]const u8 = null,
        position: ?Position = null,
        rotation: ?Rotation = null,
        scale: ?Scale = null,
        mesh: ?*mesh_module.Mesh = null,
        is_static: bool = false,
    };

    /// Spawn a new entity with the given components
    pub fn spawn(self: *GameWorld, opts: SpawnOptions) flecs.entity_t {
        // Create entity (optionally with name)
        const entity = if (opts.name) |name|
            flecs.new_entity(self.world, name)
        else
            flecs.new_id(self.world);

        // Add components based on options
        if (opts.position) |pos| {
            _ = flecs.set(self.world, entity, Position, pos);
        }

        if (opts.rotation) |rot| {
            _ = flecs.set(self.world, entity, Rotation, rot);
        }

        if (opts.scale) |s| {
            _ = flecs.set(self.world, entity, Scale, s);
        }

        if (opts.mesh) |m| {
            _ = flecs.set(self.world, entity, Renderable, .{ .mesh = m });
        }

        if (opts.is_static) {
            flecs.add(self.world, entity, Static);
        }

        self.entity_count += 1;
        return entity;
    }

    /// Spawn a simple renderable entity with transform and mesh
    pub fn spawnRenderable(
        self: *GameWorld,
        name: ?[:0]const u8,
        pos: Position,
        rot: Rotation,
        scl: Scale,
        m: *mesh_module.Mesh,
    ) flecs.entity_t {
        return self.spawn(.{
            .name = name,
            .position = pos,
            .rotation = rot,
            .scale = scl,
            .mesh = m,
        });
    }

    // ========================================================================
    // Component Access
    // ========================================================================

    /// Get a component from an entity (returns null if not present)
    pub fn get(self: *GameWorld, entity: flecs.entity_t, comptime T: type) ?*const T {
        return flecs.get(self.world, entity, T);
    }

    /// Get a mutable component from an entity
    pub fn getMut(self: *GameWorld, entity: flecs.entity_t, comptime T: type) ?*T {
        return flecs.get_mut(self.world, entity, T);
    }

    /// Set a component value on an entity
    pub fn set(self: *GameWorld, entity: flecs.entity_t, comptime T: type, value: T) void {
        _ = flecs.set(self.world, entity, T, value);
    }

    // ========================================================================
    // Queries
    // ========================================================================

    /// Data returned for each renderable entity
    pub const RenderableEntity = struct {
        entity: flecs.entity_t,
        position: Position,
        rotation: Rotation,
        scale: Scale,
        mesh: *mesh_module.Mesh,

        /// Compute the model matrix for this entity
        pub fn getModelMatrix(self: RenderableEntity) zm.Mat {
            const translation = zm.translation(self.position.x, self.position.y, self.position.z);
            const rotation = self.rotation.toMatrix();
            const scl = self.scale.toMatrix();
            // Order: Scale → Rotate → Translate (applied right to left)
            return zm.mul(zm.mul(scl, rotation), translation);
        }
    };

    /// Iterator for renderable entities
    pub const RenderableIterator = struct {
        world: *flecs.world_t,
        query: *flecs.query_t,
        iter: flecs.iter_t,
        index: usize,
        count: usize,
        positions: ?[]Position,
        rotations: ?[]Rotation,
        scales: ?[]Scale,
        renderables: ?[]Renderable,
        entities: []const flecs.entity_t,
        // Track iteration state for proper cleanup
        finished: bool = false, // true when query_next returned false (naturally consumed)

        pub fn next(self: *RenderableIterator) ?RenderableEntity {
            // Check if we need to advance to next table
            while (self.index >= self.count) {
                if (!flecs.query_next(&self.iter)) {
                    self.finished = true; // Iterator naturally exhausted
                    return null;
                }
                self.count = self.iter.count();
                self.index = 0;
                self.entities = self.iter.entities();

                // Get component arrays for this table
                self.positions = flecs.field(&self.iter, Position, 0);
                self.rotations = flecs.field(&self.iter, Rotation, 1);
                self.scales = flecs.field(&self.iter, Scale, 2);
                self.renderables = flecs.field(&self.iter, Renderable, 3);
            }

            const i = self.index;
            self.index += 1;

            // Default values if component not present (shouldn't happen with our query)
            const pos = if (self.positions) |p| p[i] else Position{};
            const rot = if (self.rotations) |r| r[i] else Rotation{};
            const scl = if (self.scales) |s| s[i] else Scale{ .x = 1, .y = 1, .z = 1 };
            const mesh_ptr = if (self.renderables) |r| r[i].mesh else return null;

            return .{
                .entity = self.entities[i],
                .position = pos,
                .rotation = rot,
                .scale = scl,
                .mesh = mesh_ptr,
            };
        }

        /// Finalize the iterator. Must be called when iteration is stopped early
        /// (via break). Safe to call even if fully consumed - becomes a no-op.
        pub fn deinit(self: *RenderableIterator) void {
            // Only finalize if iteration was interrupted (not naturally exhausted)
            // Calling iter_fini on a fully-consumed iterator would assert
            if (!self.finished) {
                flecs.iter_fini(&self.iter);
            }
        }
    };

    /// Query all entities with Position, Rotation, Scale, and Renderable components
    pub fn renderables(self: *GameWorld) RenderableIterator {
        const iter = flecs.query_iter(self.world, self.renderable_query);

        return .{
            .world = self.world,
            .query = self.renderable_query,
            .iter = iter,
            .index = 0,
            .count = 0,
            .positions = null,
            .rotations = null,
            .scales = null,
            .renderables = null,
            .entities = &[_]flecs.entity_t{},
            .finished = false,
        };
    }

    // ========================================================================
    // Statistics
    // ========================================================================

    /// Get the total number of game entities we've spawned
    pub fn entityCount(self: *GameWorld) i32 {
        return self.entity_count;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "GameWorld basic operations" {
    var world = GameWorld.init();
    defer world.deinit();

    // Note: Can't fully test without a real mesh, but we can test the API
    const entity = world.spawn(.{
        .name = "TestEntity",
        .position = .{ .x = 1, .y = 2, .z = 3 },
        .rotation = .{ .x = 0, .y = std.math.pi, .z = 0 },
        .scale = .{ .x = 1, .y = 1, .z = 1 },
    });

    const pos = world.get(entity, Position);
    try std.testing.expect(pos != null);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), pos.?.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), pos.?.y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), pos.?.z, 0.001);
}

test "Position toVec" {
    const pos = Position{ .x = 1, .y = 2, .z = 3 };
    const vec = pos.toVec();
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), vec[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), vec[1], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), vec[2], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), vec[3], 0.001); // w = 1 for positions
}
