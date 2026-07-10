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
//! var game = try GameWorld.init();
//! defer game.deinit();
//!
//! // Spawn an entity with components
//! const car = try game.spawn(.{
//!     .position = .{ 0, 0, 0 },
//!     .rotation = .{ 0, 0, 0, 1 },
//!     .scale = .{ 1, 1, 1 },
//!     .mesh = &car_mesh,
//! });
//!
//! // Query all renderable entities
//! var iter = game.renderables();
//! while (iter.next()) |entity| {
//!     renderer.drawMesh(entity.mesh, entity.model, view_projection);
//! }
//! ```

const std = @import("std");
const engine = @import("incinerator_engine");
const flecs = @import("zflecs");
const zm = @import("zmath");
const mesh_module = @import("mesh.zig");
const physics_module = @import("jolt_physics");

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

/// 3D rotation stored as quaternion [x, y, z, w].
/// Identity rotation is (0, 0, 0, 1).
/// See ADR-005 for why we use quaternions (no gimbal lock, direct physics sync).
pub const Rotation = struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
    w: f32 = 1,

    pub fn toMatrix(self: Rotation) zm.Mat {
        return zm.quatToMat(zm.f32x4(self.x, self.y, self.z, self.w));
    }

    /// Convert to zmath's pitch/yaw/roll convention (radians, Y-X-Z order).
    /// Euler values are editor presentation only; quaternions remain canonical.
    pub fn toEuler(self: Rotation) [3]f32 {
        return zm.quatToRollPitchYaw(zm.f32x4(self.x, self.y, self.z, self.w));
    }

    /// Create rotation from Euler angles around X, Y, and Z respectively.
    pub fn fromEuler(pitch: f32, yaw: f32, roll: f32) Rotation {
        const quat = zm.quatFromRollPitchYaw(pitch, yaw, roll);
        return .{ .x = quat[0], .y = quat[1], .z = quat[2], .w = quat[3] };
    }

    pub const identity = Rotation{ .x = 0, .y = 0, .z = 0, .w = 1 };
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

/// Links an entity to a physics rigid body.
/// The sync system reads the body's transform and writes to Position/Rotation.
/// See ADR-005 for the physics-ECS integration pattern.
pub const RigidBody = struct {
    body_id: physics_module.BodyId,
    sync_rotation: bool = true, // Set false for objects that only need position sync
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
    physics_query: *flecs.query_t, // Query for physics-enabled entities
    physics_world: ?*physics_module.Physics = null, // Reference to physics system for sync
    entity_count: i32 = 0, // Track manually since flecs doesn't expose this directly

    /// Initialize the ECS world and register all components
    pub fn init() !GameWorld {
        try engine.runtime.claimExternalWorld();
        errdefer engine.runtime.releaseExternalWorld();
        const world = flecs.init();

        // Register components - this tells flecs about our data types
        // Must be done before using the components
        flecs.COMPONENT(world, Position);
        flecs.COMPONENT(world, Rotation);
        flecs.COMPONENT(world, Scale);
        flecs.COMPONENT(world, Renderable);
        flecs.COMPONENT(world, RigidBody);

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

        // Create physics query for entities with Position, Rotation, and RigidBody
        var physics_query_desc = flecs.query_desc_t{};
        physics_query_desc.terms[0] = .{ .id = flecs.id(Position) };
        physics_query_desc.terms[1] = .{ .id = flecs.id(Rotation) };
        physics_query_desc.terms[2] = .{ .id = flecs.id(RigidBody) };

        const physics_query = flecs.query_init(world, &physics_query_desc) catch {
            std.debug.print("Failed to create physics query\n", .{});
            @panic("ECS physics query init failed");
        };

        std.debug.print("ECS World initialized (flecs)\n", .{});

        return .{
            .world = world,
            .renderable_query = renderable_query,
            .physics_query = physics_query,
            .entity_count = 0,
        };
    }

    /// Shutdown the ECS world
    pub fn deinit(self: *GameWorld) void {
        flecs.query_fini(self.physics_query);
        flecs.query_fini(self.renderable_query);
        _ = flecs.fini(self.world);
        engine.runtime.releaseExternalWorld();
        std.debug.print("ECS World shutdown\n", .{});
    }

    /// Transitional S0 composition seam. The new runtime borrows the legacy
    /// sandbox's one live Flecs world without exposing Flecs types through the
    /// public engine API. Remove this when the sandbox finishes migrating to
    /// the feature runtime as its sole world owner.
    pub fn borrowWorldContext(self: *GameWorld) *anyopaque {
        return @ptrCast(self.world);
    }

    /// Set the physics world reference for sync operations.
    /// Must be called before syncPhysicsToECS().
    pub fn setPhysicsWorld(self: *GameWorld, pw: *physics_module.Physics) void {
        self.physics_world = pw;
    }

    // ========================================================================
    // Entity Spawning
    // ========================================================================

    /// Spawn options - which components to add to a new entity
    pub const SpawnOptions = struct {
        /// Optional unique Flecs lookup identity. This is not a display label:
        /// attempting to reuse it is an error instead of aliasing an entity.
        unique_name: ?[:0]const u8 = null,
        position: ?Position = null,
        rotation: ?Rotation = null,
        scale: ?Scale = null,
        mesh: ?*mesh_module.Mesh = null,
        is_static: bool = false,
    };

    /// Spawn a new entity with the given components
    pub fn spawn(self: *GameWorld, opts: SpawnOptions) !flecs.entity_t {
        if (opts.unique_name) |name| {
            try validateUniqueEntityName(name);
            if (flecs.lookup_child(self.world, 0, name) != 0) {
                return error.DuplicateEntityName;
            }
        }

        const entity = flecs.new_id(self.world);
        if (entity == 0) return error.EntityCreationFailed;
        errdefer flecs.delete(self.world, entity);

        if (opts.unique_name) |name| {
            if (flecs.set_name(self.world, entity, name) == 0) {
                return error.EntityNamingFailed;
            }
        }

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
    ) !flecs.entity_t {
        return self.spawn(.{
            .unique_name = name,
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

    // ========================================================================
    // Physics Sync
    // ========================================================================

    /// Sync physics body transforms to ECS components.
    /// Call this each tick AFTER physics.update() and BEFORE rendering.
    /// See ADR-005 for the physics-ECS integration pattern.
    pub fn syncPhysicsToECS(self: *GameWorld) !void {
        const pw = self.physics_world orelse {
            // No physics world set - nothing to sync
            return;
        };

        var iter = flecs.query_iter(self.world, self.physics_query);
        while (flecs.query_next(&iter)) {
            const count = iter.count();

            // Get mutable component arrays
            const positions = flecs.field(&iter, Position, 0);
            const rotations = flecs.field(&iter, Rotation, 1);
            const rigid_bodies = flecs.field(&iter, RigidBody, 2);

            if (positions == null or rotations == null or rigid_bodies == null) continue;

            // Update each entity's transform from physics
            for (0..count) |i| {
                const body_id = rigid_bodies.?[i].body_id;

                // Get position from physics
                const phys_pos = try pw.getBodyPosition(body_id);
                positions.?[i] = .{
                    .x = phys_pos[0],
                    .y = phys_pos[1],
                    .z = phys_pos[2],
                };

                // Get rotation from physics - direct quaternion copy (no conversion)
                if (rigid_bodies.?[i].sync_rotation) {
                    const quat = try pw.getBodyRotation(body_id);
                    rotations.?[i] = .{
                        .x = quat[0],
                        .y = quat[1],
                        .z = quat[2],
                        .w = quat[3],
                    };
                }
            }
        }
    }
};

fn validateUniqueEntityName(name: [:0]const u8) !void {
    // This API creates one root identity, not a Flecs path. Rejecting path
    // syntax keeps validation and assignment semantics identical and prevents
    // Flecs from aborting on a duplicate literal name missed by path lookup.
    if (name.len == 0 or std.mem.indexOfScalar(u8, name, '.') != null) {
        return error.InvalidEntityName;
    }
}

// ============================================================================
// Tests
// ============================================================================

fn expectMatrixApproxEq(expected: zm.Mat, actual: zm.Mat, tolerance: f32) !void {
    inline for (0..4) |row| {
        try zm.expectVecApproxEqAbs(expected[row], actual[row], tolerance);
    }
}

test "GameWorld basic operations" {
    var world = try GameWorld.init();
    defer world.deinit();

    // Note: Can't fully test without a real mesh, but we can test the API
    const entity = try world.spawn(.{
        .unique_name = "TestEntity",
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

test "a second legacy world returns a defined lease error" {
    var world = try GameWorld.init();
    defer world.deinit();
    try std.testing.expectError(error.EngineWorldAlreadyLive, GameWorld.init());
}

test "Position toVec" {
    const pos = Position{ .x = 1, .y = 2, .z = 3 };
    const vec = pos.toVec();
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), vec[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), vec[1], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), vec[2], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), vec[3], 0.001); // w = 1 for positions
}

test "Rotation.fromEuler maps pitch yaw roll to X Y Z axes" {
    const angle: f32 = 0.37;
    try expectMatrixApproxEq(zm.rotationX(angle), Rotation.fromEuler(angle, 0, 0).toMatrix(), 0.0001);
    try expectMatrixApproxEq(zm.rotationY(angle), Rotation.fromEuler(0, angle, 0).toMatrix(), 0.0001);
    try expectMatrixApproxEq(zm.rotationZ(angle), Rotation.fromEuler(0, 0, angle).toMatrix(), 0.0001);
}

test "Rotation Euler conversion roundtrips combined non-singular angles" {
    const expected = [3]f32{ 0.3, -0.4, 0.5 };
    const actual = Rotation.fromEuler(expected[0], expected[1], expected[2]).toEuler();
    for (expected, actual) |expected_angle, actual_angle| {
        try std.testing.expectApproxEqAbs(expected_angle, actual_angle, 0.0001);
    }
}

test "unique entity names reject aliasing without mutating the original" {
    var world = try GameWorld.init();
    defer world.deinit();

    const original = try world.spawn(.{
        .unique_name = "UniqueEntity",
        .position = .{ .x = 1, .y = 2, .z = 3 },
    });
    try std.testing.expectError(error.DuplicateEntityName, world.spawn(.{
        .unique_name = "UniqueEntity",
        .position = .{ .x = 99, .y = 99, .z = 99 },
    }));

    try std.testing.expectEqual(@as(i32, 1), world.entityCount());
    const position = world.get(original, Position).?;
    try std.testing.expectApproxEqAbs(@as(f32, 1), position.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 2), position.y, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 3), position.z, 0.0001);
}

test "unique entity names reject empty and path syntax without mutation" {
    var world = try GameWorld.init();
    defer world.deinit();

    try std.testing.expectError(error.InvalidEntityName, world.spawn(.{ .unique_name = "" }));
    try std.testing.expectError(error.InvalidEntityName, world.spawn(.{ .unique_name = "parent.child" }));
    try std.testing.expectEqual(@as(i32, 0), world.entityCount());
}

test "unnamed entity spawns always allocate distinct identities" {
    var world = try GameWorld.init();
    defer world.deinit();

    const first = try world.spawn(.{});
    const second = try world.spawn(.{});
    try std.testing.expect(first != second);
    try std.testing.expectEqual(@as(i32, 2), world.entityCount());
}
