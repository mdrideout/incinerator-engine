//! physics.zig - Jolt Physics Integration via zphysics
//!
//! DOMAIN: Simulation Layer
//!
//! This module wraps zphysics (Jolt Physics) to provide physics simulation
//! for the game world. It handles:
//! - PhysicsSystem lifecycle (init/deinit)
//! - Collision layer configuration (static vs dynamic objects)
//! - Body creation and management
//! - Physics stepping (called from simulateTick)
//!
//! Architecture:
//! - Uses Jolt's object layers to separate static (ground, buildings) from dynamic (characters, props)
//! - BroadPhase layers optimize collision detection by grouping objects
//! - The PhysicsSystem is updated at fixed 120Hz timestep (matching our game tick rate)
//!
//! Usage:
//!   var physics = try Physics.init(allocator);
//!   defer physics.deinit();
//!
//!   // Create bodies
//!   const ground = physics.createStaticBox(.{0, -1, 0}, .{50, 1, 50});
//!   const cube = physics.createDynamicBox(.{0, 10, 0}, .{0.5, 0.5, 0.5});
//!
//!   // In game loop
//!   physics.update(delta_time);

const std = @import("std");
const builtin = @import("builtin");
const zphysics = @import("zphysics");

const Allocator = std.mem.Allocator;

// ============================================================================
// Object Layers
// ============================================================================
// Object layers determine which objects can collide with each other.
// This is a coarse filter - objects in different layers may still not collide
// based on the ObjectLayerPairFilter.

pub const object_layers = struct {
    /// Object layer for static geometry (ground, walls, buildings)
    /// These objects don't move and have infinite mass.
    pub const non_moving: zphysics.ObjectLayer = 0;
    /// Object layer for dynamic objects (characters, props, vehicles)
    pub const moving: zphysics.ObjectLayer = 1;
    pub const len: u32 = 2;
};

// ============================================================================
// Broad Phase Layers
// ============================================================================
// Broad phase layers are a coarser grouping for the broad phase collision
// detection algorithm. This speeds up collision detection by culling
// impossible collisions early.

pub const broad_phase_layers = struct {
    pub const non_moving: zphysics.BroadPhaseLayer = 0;
    pub const moving: zphysics.BroadPhaseLayer = 1;
    pub const len: u32 = 2;
};

// ============================================================================
// Layer Interfaces (Required by Jolt)
// ============================================================================

/// Maps object layers to broad phase layers.
/// Jolt uses this to know which broad phase layer an object belongs to.
const MyBroadPhaseLayerInterface = extern struct {
    interface: zphysics.BroadPhaseLayerInterface = .init(@This()),
    object_to_broad_phase: [object_layers.len]zphysics.BroadPhaseLayer = undefined,

    fn create() MyBroadPhaseLayerInterface {
        var layer_interface: MyBroadPhaseLayerInterface = .{};
        layer_interface.object_to_broad_phase[object_layers.non_moving] = broad_phase_layers.non_moving;
        layer_interface.object_to_broad_phase[object_layers.moving] = broad_phase_layers.moving;
        return layer_interface;
    }

    pub fn getNumBroadPhaseLayers(interface: *const zphysics.BroadPhaseLayerInterface) callconv(.c) u32 {
        _ = interface;
        return broad_phase_layers.len;
    }

    pub const getBroadPhaseLayer = if (builtin.abi == .msvc) _getBroadPhaseLayerMsvc else _getBroadPhaseLayer;

    fn _getBroadPhaseLayer(
        interface: *const zphysics.BroadPhaseLayerInterface,
        layer: zphysics.ObjectLayer,
    ) callconv(.c) zphysics.BroadPhaseLayer {
        const self: *const MyBroadPhaseLayerInterface = @alignCast(@fieldParentPtr("interface", interface));
        return self.object_to_broad_phase[@intCast(layer)];
    }

    fn _getBroadPhaseLayerMsvc(
        interface: *const zphysics.BroadPhaseLayerInterface,
        out_layer: *zphysics.BroadPhaseLayer,
        layer: zphysics.ObjectLayer,
    ) callconv(.c) *const zphysics.BroadPhaseLayer {
        const self: *const MyBroadPhaseLayerInterface = @alignCast(@fieldParentPtr("interface", interface));
        out_layer.* = self.object_to_broad_phase[@intCast(layer)];
        return out_layer;
    }
};

/// Determines if an object layer should collide with a broad phase layer.
/// This is used during the broad phase to cull impossible collisions.
const MyObjectVsBroadPhaseLayerFilter = extern struct {
    filter: zphysics.ObjectVsBroadPhaseLayerFilter = .init(@This()),

    pub fn shouldCollide(
        _: *const zphysics.ObjectVsBroadPhaseLayerFilter,
        layer1: zphysics.ObjectLayer,
        layer2: zphysics.BroadPhaseLayer,
    ) callconv(.c) bool {
        return switch (layer1) {
            object_layers.non_moving => layer2 == broad_phase_layers.moving,
            object_layers.moving => true, // Moving objects collide with everything
            else => false,
        };
    }
};

/// Determines if two object layers should collide with each other.
/// This is the fine-grained collision filter.
const MyObjectLayerPairFilter = extern struct {
    filter: zphysics.ObjectLayerPairFilter = .init(@This()),

    pub fn shouldCollide(
        _: *const zphysics.ObjectLayerPairFilter,
        object1: zphysics.ObjectLayer,
        object2: zphysics.ObjectLayer,
    ) callconv(.c) bool {
        return switch (object1) {
            object_layers.non_moving => object2 == object_layers.moving,
            object_layers.moving => true, // Moving collides with moving and non-moving
            else => false,
        };
    }
};

/// Contact listener for collision events (optional, for gameplay callbacks)
const MyContactListener = extern struct {
    listener: zphysics.ContactListener = .init(@This()),

    pub fn onContactValidate(
        _: *zphysics.ContactListener,
        _: *const zphysics.Body,
        _: *const zphysics.Body,
        _: *const [3]zphysics.Real,
        _: *const zphysics.CollideShapeResult,
    ) callconv(.c) zphysics.ValidateResult {
        // Accept all contacts by default
        return .accept_all_contacts;
    }

    pub fn onContactAdded(
        _: *zphysics.ContactListener,
        _: *const zphysics.Body,
        _: *const zphysics.Body,
        _: *const zphysics.ContactManifold,
        _: *zphysics.ContactSettings,
    ) callconv(.c) void {
        // Can be used for sound effects, particles, etc.
    }

    pub fn onContactPersisted(
        _: *zphysics.ContactListener,
        _: *const zphysics.Body,
        _: *const zphysics.Body,
        _: *const zphysics.ContactManifold,
        _: *zphysics.ContactSettings,
    ) callconv(.c) void {}

    pub fn onContactRemoved(
        _: *zphysics.ContactListener,
        _: *const zphysics.SubShapeIdPair,
    ) callconv(.c) void {}
};

// ============================================================================
// Physics System Wrapper
// ============================================================================

pub const Physics = struct {
    allocator: Allocator,
    physics_system: *zphysics.PhysicsSystem,

    // Layer interfaces (must be kept alive while physics system exists)
    broad_phase_layer_interface: *MyBroadPhaseLayerInterface,
    object_vs_broad_phase_layer_filter: *MyObjectVsBroadPhaseLayerFilter,
    object_layer_pair_filter: *MyObjectLayerPairFilter,
    contact_listener: *MyContactListener,

    // ========================================================================
    // Initialization
    // ========================================================================

    /// Initialize the physics system.
    /// Call this once at startup before creating any physics bodies.
    pub fn init(allocator: Allocator) !Physics {
        // Initialize zphysics global state (thread pool, allocators)
        try zphysics.init(allocator, .{});

        // Allocate layer interfaces (these must outlive the PhysicsSystem)
        const broad_phase_layer_interface = try allocator.create(MyBroadPhaseLayerInterface);
        errdefer allocator.destroy(broad_phase_layer_interface);
        broad_phase_layer_interface.* = MyBroadPhaseLayerInterface.create();

        const object_vs_broad_phase_layer_filter = try allocator.create(MyObjectVsBroadPhaseLayerFilter);
        errdefer allocator.destroy(object_vs_broad_phase_layer_filter);
        object_vs_broad_phase_layer_filter.* = .{};

        const object_layer_pair_filter = try allocator.create(MyObjectLayerPairFilter);
        errdefer allocator.destroy(object_layer_pair_filter);
        object_layer_pair_filter.* = .{};

        const contact_listener = try allocator.create(MyContactListener);
        errdefer allocator.destroy(contact_listener);
        contact_listener.* = .{};

        // Create the physics system
        const physics_system = zphysics.PhysicsSystem.create(
            @ptrCast(&broad_phase_layer_interface.interface),
            @ptrCast(&object_vs_broad_phase_layer_filter.filter),
            @ptrCast(&object_layer_pair_filter.filter),
            .{
                .max_bodies = 1024,
                .num_body_mutexes = 0, // Auto
                .max_body_pairs = 1024,
                .max_contact_constraints = 1024,
            },
        ) catch |err| {
            std.debug.print("Failed to create PhysicsSystem: {any}\n", .{err});
            return error.PhysicsSystemCreationFailed;
        };

        // Set gravity (default: -9.81 m/s^2 in Y direction)
        physics_system.setGravity(.{ 0, -9.81, 0 });

        // Register contact listener for collision events
        physics_system.setContactListener(@ptrCast(&contact_listener.listener));

        std.debug.print("Physics system initialized\n", .{});

        return Physics{
            .allocator = allocator,
            .physics_system = physics_system,
            .broad_phase_layer_interface = broad_phase_layer_interface,
            .object_vs_broad_phase_layer_filter = object_vs_broad_phase_layer_filter,
            .object_layer_pair_filter = object_layer_pair_filter,
            .contact_listener = contact_listener,
        };
    }

    /// Cleanup the physics system.
    /// Call this at shutdown after all bodies have been destroyed.
    pub fn deinit(self: *Physics) void {
        self.physics_system.destroy();
        zphysics.deinit();

        // Free layer interfaces
        self.allocator.destroy(self.contact_listener);
        self.allocator.destroy(self.object_layer_pair_filter);
        self.allocator.destroy(self.object_vs_broad_phase_layer_filter);
        self.allocator.destroy(self.broad_phase_layer_interface);

        std.debug.print("Physics system shutdown\n", .{});
    }

    // ========================================================================
    // Body Creation
    // ========================================================================

    /// Create a static (immovable) box body.
    /// Use for ground planes, walls, buildings, etc.
    ///
    /// Parameters:
    /// - position: World position [x, y, z]
    /// - half_extents: Half-size in each dimension [hx, hy, hz]
    ///
    /// Returns the body ID for later reference, or null if creation failed.
    pub fn createStaticBox(
        self: *Physics,
        position: [3]f32,
        half_extents: [3]f32,
    ) ?zphysics.BodyId {
        // Create shape settings, then create the actual shape
        const shape_settings = zphysics.BoxShapeSettings.create(half_extents) catch {
            std.debug.print("Failed to create box shape settings\n", .{});
            return null;
        };
        defer shape_settings.asShapeSettings().release();

        const shape = shape_settings.asShapeSettings().createShape() catch {
            std.debug.print("Failed to create box shape\n", .{});
            return null;
        };
        // Note: Shape is ref-counted, body takes ownership

        const body_interface = self.physics_system.getBodyInterfaceMut();

        const body_id = body_interface.createAndAddBody(.{
            .position = .{ position[0], position[1], position[2], 1.0 },
            .rotation = .{ 0, 0, 0, 1 }, // Identity quaternion
            .shape = shape,
            .motion_type = .static,
            .object_layer = object_layers.non_moving,
        }, .dont_activate) catch {
            std.debug.print("Failed to create static body\n", .{});
            shape.release();
            return null;
        };

        return body_id;
    }

    /// Create a dynamic (movable) box body affected by gravity.
    /// Use for crates, props, characters, etc.
    ///
    /// Parameters:
    /// - position: World position [x, y, z]
    /// - half_extents: Half-size in each dimension [hx, hy, hz]
    ///
    /// Returns the body ID for later reference, or null if creation failed.
    pub fn createDynamicBox(
        self: *Physics,
        position: [3]f32,
        half_extents: [3]f32,
    ) ?zphysics.BodyId {
        const shape_settings = zphysics.BoxShapeSettings.create(half_extents) catch {
            std.debug.print("Failed to create box shape settings\n", .{});
            return null;
        };
        defer shape_settings.asShapeSettings().release();

        const shape = shape_settings.asShapeSettings().createShape() catch {
            std.debug.print("Failed to create box shape\n", .{});
            return null;
        };

        const body_interface = self.physics_system.getBodyInterfaceMut();

        const body_id = body_interface.createAndAddBody(.{
            .position = .{ position[0], position[1], position[2], 1.0 },
            .rotation = .{ 0, 0, 0, 1 }, // Identity quaternion
            .shape = shape,
            .motion_type = .dynamic,
            .object_layer = object_layers.moving,
        }, .activate) catch {
            std.debug.print("Failed to create dynamic body\n", .{});
            shape.release();
            return null;
        };

        return body_id;
    }

    /// Create a dynamic sphere body.
    /// Good for balls, projectiles, simple character colliders.
    pub fn createDynamicSphere(
        self: *Physics,
        position: [3]f32,
        radius: f32,
    ) ?zphysics.BodyId {
        const shape_settings = zphysics.SphereShapeSettings.create(radius) catch {
            std.debug.print("Failed to create sphere shape settings\n", .{});
            return null;
        };
        defer shape_settings.asShapeSettings().release();

        const shape = shape_settings.asShapeSettings().createShape() catch {
            std.debug.print("Failed to create sphere shape\n", .{});
            return null;
        };

        const body_interface = self.physics_system.getBodyInterfaceMut();

        const body_id = body_interface.createAndAddBody(.{
            .position = .{ position[0], position[1], position[2], 1.0 },
            .rotation = .{ 0, 0, 0, 1 },
            .shape = shape,
            .motion_type = .dynamic,
            .object_layer = object_layers.moving,
        }, .activate) catch {
            std.debug.print("Failed to create dynamic sphere body\n", .{});
            shape.release();
            return null;
        };

        return body_id;
    }

    // ========================================================================
    // Body Queries
    // ========================================================================

    /// Get the current position of a body.
    pub fn getBodyPosition(self: *Physics, body_id: zphysics.BodyId) [3]f32 {
        const body_interface = self.physics_system.getBodyInterface();
        const pos = body_interface.getCenterOfMassPosition(body_id);
        return .{ pos[0], pos[1], pos[2] };
    }

    /// Get the current rotation of a body as a quaternion [x, y, z, w].
    pub fn getBodyRotation(self: *Physics, body_id: zphysics.BodyId) [4]f32 {
        const body_interface = self.physics_system.getBodyInterface();
        return body_interface.getRotation(body_id);
    }

    /// Check if a body is currently active (simulating).
    /// Bodies go to sleep when they stop moving to save CPU.
    pub fn isBodyActive(self: *Physics, body_id: zphysics.BodyId) bool {
        const body_interface = self.physics_system.getBodyInterface();
        return body_interface.isActive(body_id);
    }

    /// Get the number of active bodies.
    pub fn getActiveBodyCount(self: *Physics) u32 {
        return self.physics_system.getNumActiveBodies(.dynamic);
    }

    /// Get total body count.
    pub fn getBodyCount(self: *Physics) u32 {
        return self.physics_system.getNumBodies();
    }

    // ========================================================================
    // Body Manipulation
    // ========================================================================

    /// Apply an impulse to a body (instantaneous force).
    /// Good for explosions, jumps, etc.
    pub fn addImpulse(self: *Physics, body_id: zphysics.BodyId, impulse: [3]f32) void {
        const body_interface = self.physics_system.getBodyInterfaceMut();
        body_interface.addImpulse(body_id, impulse);
    }

    /// Apply a force to a body (continuous, applied each frame).
    pub fn addForce(self: *Physics, body_id: zphysics.BodyId, force: [3]f32) void {
        const body_interface = self.physics_system.getBodyInterfaceMut();
        body_interface.addForce(body_id, force);
    }

    /// Set the linear velocity of a body directly.
    pub fn setLinearVelocity(self: *Physics, body_id: zphysics.BodyId, velocity: [3]f32) void {
        const body_interface = self.physics_system.getBodyInterfaceMut();
        body_interface.setLinearVelocity(body_id, velocity);
    }

    /// Remove a body from the simulation.
    pub fn removeBody(self: *Physics, body_id: zphysics.BodyId) void {
        const body_interface = self.physics_system.getBodyInterfaceMut();
        body_interface.removeAndDestroyBody(body_id);
    }

    // ========================================================================
    // Simulation
    // ========================================================================

    /// Step the physics simulation forward by delta_time seconds.
    /// Should be called once per game tick (at 120Hz in our engine).
    ///
    /// Parameters:
    /// - delta_time: Time step in seconds (e.g., 1.0/120.0 for 120Hz)
    ///
    /// The physics engine uses fixed substeps internally for stability.
    pub fn update(self: *Physics, delta_time: f32) void {
        // Jolt recommends 1-4 collision steps per update depending on timestep
        // At 120Hz (~8.33ms), 1 step is usually sufficient
        const collision_steps: u32 = 1;

        self.physics_system.update(delta_time, .{ .collision_steps = collision_steps }) catch |err| {
            std.debug.print("Physics update error: {any}\n", .{err});
        };
    }

    /// Optimize the broad phase after adding many bodies.
    /// Call this after batch body creation for better performance.
    pub fn optimizeBroadPhase(self: *Physics) void {
        self.physics_system.optimizeBroadPhase();
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Physics struct is valid" {
    _ = Physics;
}

test "Object layers are valid" {
    try std.testing.expect(object_layers.non_moving == 0);
    try std.testing.expect(object_layers.moving == 1);
}
