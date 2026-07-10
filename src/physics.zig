//! Narrow engine adapter for Jolt Physics 5.5 through JoltC.
//!
//! This module owns all C API details used by the current sandbox. ECS,
//! gameplay, and editor code use the engine-defined `BodyId` and `MotionType`
//! below; they do not depend on Jolt's headers or mirrored C layouts.

const std = @import("std");
const engine = @import("engine_contracts");
const c = @import("jolt_c").c;

const invalid_body_id: c.JPH_BodyID = std.math.maxInt(c.JPH_BodyID);
const temp_allocator_bytes: u32 = 10 * 1024 * 1024;

/// JoltC exposes process-global initialization without reference counting.
/// Keep that detail private to this adapter so multiple Physics worlds cannot
/// shut the runtime down while another world is still using it.
var runtime_mutex: std.atomic.Mutex = .unlocked;
var runtime_lease_count: usize = 0;
var runtime_owner_thread: ?std.Thread.Id = null;
var next_world_token: u64 = 1;

pub const StepError = error{
    InvalidDeltaTime,
    ManifoldCacheFull,
    BodyPairCacheFull,
    ContactConstraintsFull,
    MultipleCapacityLimitsExceeded,
    UnknownPhysicsUpdateFailure,
};

pub const BodyId = struct {
    world_token: u64,
    serial: u64,
    value: u32,

    fn toJolt(self: BodyId) c.JPH_BodyID {
        return @intCast(self.value);
    }
};

pub const MotionType = enum {
    static,
    kinematic,
    dynamic,
};

pub const object_layers = struct {
    pub const non_moving: c.JPH_ObjectLayer = 0;
    pub const moving: c.JPH_ObjectLayer = 1;
    pub const count: u32 = 2;
};

const broad_phase_layers = struct {
    const non_moving: c.JPH_BroadPhaseLayer = 0;
    const moving: c.JPH_BroadPhaseLayer = 1;
    const count: u32 = 2;
};

fn acquireRuntimeLease() !u64 {
    lockRuntime();
    defer runtime_mutex.unlock();

    if (runtime_lease_count == std.math.maxInt(usize)) {
        return error.TooManyPhysicsWorlds;
    }
    if (next_world_token == 0) return error.WorldTokenExhausted;

    const current_thread = std.Thread.getCurrentId();
    if (runtime_owner_thread) |owner_thread| {
        if (owner_thread != current_thread) return error.WrongThread;
    }
    if (runtime_lease_count == 0) {
        if (!c.JPH_Init()) return error.JoltInitializationFailed;
        if (runtime_owner_thread == null) runtime_owner_thread = current_thread;
    }

    const world_token = next_world_token;
    next_world_token +%= 1;
    runtime_lease_count += 1;
    return world_token;
}

fn releaseRuntimeLease() void {
    lockRuntime();
    defer runtime_mutex.unlock();

    if (runtime_lease_count == 0 or
        runtime_owner_thread == null or
        runtime_owner_thread.? != std.Thread.getCurrentId())
    {
        @panic("Jolt runtime lease invariant failed");
    }
    runtime_lease_count -= 1;
    if (runtime_lease_count == 0) {
        c.JPH_Shutdown();
    }
}

fn runtimeLeaseCount() usize {
    lockRuntime();
    defer runtime_mutex.unlock();
    return runtime_lease_count;
}

fn lockRuntime() void {
    while (!runtime_mutex.tryLock()) {
        std.atomic.spinLoopHint();
    }
}

pub const Physics = struct {
    /// All per-world methods are confined to the thread that created the world.
    /// Multiple worlds may coexist on that one thread; concurrent world
    /// lifecycle and simulation are deliberately unsupported.
    owner_thread: std.Thread.Id,
    world_token: u64,
    system: *c.JPH_PhysicsSystem,
    body_interface: *c.JPH_BodyInterface,
    job_system: *c.JPH_JobSystem,
    temp_allocator: *c.JPH_TempAllocator,
    body_handles: std.AutoHashMap(u64, u32),
    next_body_serial: u64 = 1,

    pub fn init() !Physics {
        const world_token = try acquireRuntimeLease();
        errdefer releaseRuntimeLease();

        const job_system = c.JPH_JobSystemThreadPool_Create(null) orelse
            return error.JobSystemCreationFailed;
        errdefer c.JPH_JobSystem_Destroy(job_system);

        const temp_allocator = c.JPH_TempAllocator_Create(temp_allocator_bytes) orelse
            return error.TempAllocatorCreationFailed;
        errdefer c.JPH_TempAllocator_Destroy(temp_allocator);

        var object_layer_filter: ?*c.JPH_ObjectLayerPairFilter =
            c.JPH_ObjectLayerPairFilterTable_Create(object_layers.count);
        if (object_layer_filter == null) return error.ObjectLayerFilterCreationFailed;
        errdefer if (object_layer_filter) |filter| {
            c.JPH_ObjectLayerPairFilter_Destroy(filter);
        };

        c.JPH_ObjectLayerPairFilterTable_EnableCollision(
            object_layer_filter.?,
            object_layers.moving,
            object_layers.moving,
        );
        c.JPH_ObjectLayerPairFilterTable_EnableCollision(
            object_layer_filter.?,
            object_layers.moving,
            object_layers.non_moving,
        );

        var broad_phase_interface: ?*c.JPH_BroadPhaseLayerInterface =
            c.JPH_BroadPhaseLayerInterfaceTable_Create(
                object_layers.count,
                broad_phase_layers.count,
            );
        if (broad_phase_interface == null) return error.BroadPhaseInterfaceCreationFailed;
        errdefer if (broad_phase_interface) |layer_interface| {
            c.JPH_BroadPhaseLayerInterface_Destroy(layer_interface);
        };

        c.JPH_BroadPhaseLayerInterfaceTable_MapObjectToBroadPhaseLayer(
            broad_phase_interface.?,
            object_layers.non_moving,
            broad_phase_layers.non_moving,
        );
        c.JPH_BroadPhaseLayerInterfaceTable_MapObjectToBroadPhaseLayer(
            broad_phase_interface.?,
            object_layers.moving,
            broad_phase_layers.moving,
        );

        var object_vs_broad_phase_filter: ?*c.JPH_ObjectVsBroadPhaseLayerFilter =
            c.JPH_ObjectVsBroadPhaseLayerFilterTable_Create(
                broad_phase_interface.?,
                broad_phase_layers.count,
                object_layer_filter.?,
                object_layers.count,
            );
        if (object_vs_broad_phase_filter == null) {
            return error.ObjectVsBroadPhaseFilterCreationFailed;
        }
        errdefer if (object_vs_broad_phase_filter) |filter| {
            c.JPH_ObjectVsBroadPhaseLayerFilter_Destroy(filter);
        };

        const settings = c.JPH_PhysicsSystemSettings{
            .maxBodies = 10_240,
            .numBodyMutexes = 0,
            .maxBodyPairs = 65_536,
            .maxContactConstraints = 10_240,
            ._padding = 0,
            .broadPhaseLayerInterface = broad_phase_interface.?,
            .objectLayerPairFilter = object_layer_filter.?,
            .objectVsBroadPhaseLayerFilter = object_vs_broad_phase_filter.?,
        };

        const system = c.JPH_PhysicsSystem_Create(&settings) orelse
            return error.PhysicsSystemCreationFailed;

        // JoltC transfers these three filter objects into the created system.
        // Disarm individual cleanup before registering system cleanup so a
        // later initialization error destroys every object exactly once.
        broad_phase_interface = null;
        object_layer_filter = null;
        object_vs_broad_phase_filter = null;
        errdefer c.JPH_PhysicsSystem_Destroy(system);

        // A created system always exposes a body interface.
        const body_interface = c.JPH_PhysicsSystem_GetBodyInterface(system) orelse unreachable;

        var gravity = c.JPH_Vec3{ .x = 0, .y = -9.81, .z = 0 };
        c.JPH_PhysicsSystem_SetGravity(system, &gravity);

        return .{
            .owner_thread = std.Thread.getCurrentId(),
            .world_token = world_token,
            .system = system,
            .body_interface = body_interface,
            .job_system = job_system,
            .temp_allocator = temp_allocator,
            .body_handles = std.AutoHashMap(u64, u32).init(std.heap.page_allocator),
        };
    }

    pub fn deinit(self: *Physics) void {
        self.assertOwnerThread();
        if (self.body_handles.count() != 0) {
            @panic("physics world deinitialized with live body handles");
        }
        c.JPH_PhysicsSystem_Destroy(self.system);
        c.JPH_TempAllocator_Destroy(self.temp_allocator);
        c.JPH_JobSystem_Destroy(self.job_system);
        self.body_handles.deinit();
        releaseRuntimeLease();
        self.* = undefined;
    }

    /// Expose only the body operations required by the crate feature. The
    /// feature is generic over this concrete capability and never imports
    /// Jolt or this adapter directly.
    pub fn crateBodies(self: *Physics) CrateBodies {
        return .{ .physics = self };
    }

    fn assertOwnerThread(self: *const Physics) void {
        if (self.owner_thread != std.Thread.getCurrentId()) {
            @panic("Physics world accessed from a non-owner thread");
        }
    }

    fn owns(self: *const Physics, body_id: BodyId) bool {
        return self.world_token == body_id.world_token;
    }

    fn validateBody(self: *Physics, body_id: BodyId) !void {
        self.assertOwnerThread();
        if (!self.owns(body_id)) return error.ForeignBodyId;
        const mapped_raw = self.body_handles.get(body_id.serial) orelse
            return error.InvalidBodyId;
        if (mapped_raw != body_id.value) return error.InvalidBodyId;
        if (!c.JPH_BodyInterface_IsAdded(self.body_interface, body_id.toJolt())) {
            return error.InvalidBodyId;
        }
    }

    pub fn createStaticBox(
        self: *Physics,
        position: [3]f32,
        half_extents: [3]f32,
    ) !BodyId {
        self.assertOwnerThread();
        return try self.createBox(position, half_extents, .static);
    }

    pub fn createDynamicBox(
        self: *Physics,
        position: [3]f32,
        half_extents: [3]f32,
    ) !BodyId {
        self.assertOwnerThread();
        return try self.createBox(position, half_extents, .dynamic);
    }

    fn createBox(
        self: *Physics,
        position: [3]f32,
        half_extents: [3]f32,
        motion_type: MotionType,
    ) !BodyId {
        if (!isFiniteVector(position)) return error.InvalidPosition;
        try validateHalfExtents(half_extents);

        var jolt_extents = toVec3(half_extents);
        const box = c.JPH_BoxShape_Create(&jolt_extents, c.JPH_DEFAULT_CONVEX_RADIUS) orelse
            return error.ShapeCreationFailed;
        const shape: *c.JPH_Shape = @ptrCast(box);
        defer c.JPH_Shape_Destroy(shape);

        return try self.createBody(shape, position, motion_type);
    }

    pub fn createDynamicSphere(
        self: *Physics,
        position: [3]f32,
        radius: f32,
    ) !BodyId {
        self.assertOwnerThread();
        if (!isFiniteVector(position)) return error.InvalidPosition;
        if (!std.math.isFinite(radius) or radius <= 0) return error.InvalidRadius;

        const sphere = c.JPH_SphereShape_Create(radius) orelse
            return error.ShapeCreationFailed;
        const shape: *c.JPH_Shape = @ptrCast(sphere);
        defer c.JPH_Shape_Destroy(shape);

        return try self.createBody(shape, position, .dynamic);
    }

    fn createBody(
        self: *Physics,
        shape: *const c.JPH_Shape,
        position: [3]f32,
        motion_type: MotionType,
    ) !BodyId {
        if (!isFiniteVector(position)) return error.InvalidPosition;

        var jolt_position = toVec3(position);
        const settings = c.JPH_BodyCreationSettings_Create3(
            shape,
            &jolt_position,
            null,
            toJoltMotionType(motion_type),
            objectLayerForMotionType(motion_type),
        ) orelse return error.BodyCreationSettingsFailed;
        defer c.JPH_BodyCreationSettings_Destroy(settings);

        // The public adapter permits explicit motion-mode changes. Jolt must
        // allocate motion properties at creation time for a body to move from
        // static to kinematic/dynamic safely.
        c.JPH_BodyCreationSettings_SetAllowDynamicOrKinematic(settings, true);

        const raw_id = c.JPH_BodyInterface_CreateAndAddBody(
            self.body_interface,
            settings,
            if (motion_type == .static)
                c.JPH_Activation_DontActivate
            else
                c.JPH_Activation_Activate,
        );
        if (raw_id == invalid_body_id) return error.BodyCreationFailed;
        errdefer c.JPH_BodyInterface_RemoveAndDestroyBody(self.body_interface, raw_id);
        if (self.next_body_serial == 0) return error.BodyHandleSerialExhausted;
        const serial = self.next_body_serial;
        self.next_body_serial +%= 1;
        try self.body_handles.put(serial, @intCast(raw_id));

        return .{
            .world_token = self.world_token,
            .serial = serial,
            .value = @intCast(raw_id),
        };
    }

    /// Replace a body's collider with a box while preserving its BodyId, pose,
    /// motion state, and velocities. The old shape remains installed if shape
    /// validation or allocation fails.
    pub fn setBoxHalfExtents(
        self: *Physics,
        body_id: BodyId,
        half_extents: [3]f32,
    ) !void {
        try self.validateBody(body_id);
        try validateHalfExtents(half_extents);

        var jolt_extents = toVec3(half_extents);
        const box = c.JPH_BoxShape_Create(&jolt_extents, c.JPH_DEFAULT_CONVEX_RADIUS) orelse
            return error.ShapeCreationFailed;
        const shape: *c.JPH_Shape = @ptrCast(box);
        defer c.JPH_Shape_Destroy(shape);

        // Jolt's body retains its own shape reference. Releasing the caller's
        // reference above is therefore correct after this call returns.
        c.JPH_BodyInterface_SetShape(
            self.body_interface,
            body_id.toJolt(),
            shape,
            true,
            c.JPH_Activation_Activate,
        );
    }

    pub fn getBodyPosition(self: *Physics, body_id: BodyId) ![3]f32 {
        try self.validateBody(body_id);
        var position: c.JPH_RVec3 = undefined;
        c.JPH_BodyInterface_GetPosition(self.body_interface, body_id.toJolt(), &position);
        return .{ @floatCast(position.x), @floatCast(position.y), @floatCast(position.z) };
    }

    pub fn getBodyRotation(self: *Physics, body_id: BodyId) ![4]f32 {
        try self.validateBody(body_id);
        var rotation: c.JPH_Quat = undefined;
        c.JPH_BodyInterface_GetRotation(self.body_interface, body_id.toJolt(), &rotation);
        return .{ rotation.x, rotation.y, rotation.z, rotation.w };
    }

    pub fn getLinearVelocity(self: *Physics, body_id: BodyId) ![3]f32 {
        try self.validateBody(body_id);
        var velocity: c.JPH_Vec3 = undefined;
        c.JPH_BodyInterface_GetLinearVelocity(
            self.body_interface,
            body_id.toJolt(),
            &velocity,
        );
        return .{ velocity.x, velocity.y, velocity.z };
    }

    pub fn getAngularVelocity(self: *Physics, body_id: BodyId) ![3]f32 {
        try self.validateBody(body_id);
        var velocity: c.JPH_Vec3 = undefined;
        c.JPH_BodyInterface_GetAngularVelocity(
            self.body_interface,
            body_id.toJolt(),
            &velocity,
        );
        return .{ velocity.x, velocity.y, velocity.z };
    }

    pub fn isBodyActive(self: *Physics, body_id: BodyId) !bool {
        try self.validateBody(body_id);
        return c.JPH_BodyInterface_IsActive(self.body_interface, body_id.toJolt());
    }

    pub fn isBodyAdded(self: *Physics, body_id: BodyId) bool {
        self.assertOwnerThread();
        if (!self.owns(body_id)) return false;
        const mapped_raw = self.body_handles.get(body_id.serial) orelse return false;
        if (mapped_raw != body_id.value) return false;
        return c.JPH_BodyInterface_IsAdded(self.body_interface, body_id.toJolt());
    }

    pub fn getActiveBodyCount(self: *Physics) u32 {
        self.assertOwnerThread();
        return c.JPH_PhysicsSystem_GetNumActiveBodies(self.system, c.JPH_BodyType_Rigid);
    }

    pub fn getBodyCount(self: *Physics) u32 {
        self.assertOwnerThread();
        return c.JPH_PhysicsSystem_GetNumBodies(self.system);
    }

    pub fn addImpulse(self: *Physics, body_id: BodyId, impulse: [3]f32) !void {
        try self.validateBody(body_id);
        if (!isFiniteVector(impulse)) return error.InvalidImpulse;
        var value = toVec3(impulse);
        c.JPH_BodyInterface_AddImpulse(self.body_interface, body_id.toJolt(), &value);
    }

    pub fn addForce(self: *Physics, body_id: BodyId, force: [3]f32) !void {
        try self.validateBody(body_id);
        if (!isFiniteVector(force)) return error.InvalidForce;
        var value = toVec3(force);
        c.JPH_BodyInterface_AddForce(self.body_interface, body_id.toJolt(), &value);
    }

    pub fn setLinearVelocity(self: *Physics, body_id: BodyId, velocity: [3]f32) !void {
        try self.validateBody(body_id);
        if (!isFiniteVector(velocity)) return error.InvalidVelocity;
        var value = toVec3(velocity);
        c.JPH_BodyInterface_SetLinearVelocity(self.body_interface, body_id.toJolt(), &value);
    }

    pub fn setBodyPosition(self: *Physics, body_id: BodyId, position: [3]f32) !void {
        try self.validateBody(body_id);
        if (!isFiniteVector(position)) return error.InvalidPosition;
        var value = toVec3(position);
        c.JPH_BodyInterface_SetPosition(
            self.body_interface,
            body_id.toJolt(),
            &value,
            c.JPH_Activation_Activate,
        );
    }

    pub fn setBodyRotation(self: *Physics, body_id: BodyId, rotation: [4]f32) !void {
        try self.validateBody(body_id);
        const normalized = try normalizeQuaternion(rotation);
        var value = c.JPH_Quat{
            .x = normalized[0],
            .y = normalized[1],
            .z = normalized[2],
            .w = normalized[3],
        };
        c.JPH_BodyInterface_SetRotation(
            self.body_interface,
            body_id.toJolt(),
            &value,
            c.JPH_Activation_Activate,
        );
    }

    pub fn setAngularVelocity(self: *Physics, body_id: BodyId, velocity: [3]f32) !void {
        try self.validateBody(body_id);
        if (!isFiniteVector(velocity)) return error.InvalidVelocity;
        var value = toVec3(velocity);
        c.JPH_BodyInterface_SetAngularVelocity(self.body_interface, body_id.toJolt(), &value);
    }

    pub fn getMotionType(self: *Physics, body_id: BodyId) !MotionType {
        try self.validateBody(body_id);
        return fromJoltMotionType(c.JPH_BodyInterface_GetMotionType(
            self.body_interface,
            body_id.toJolt(),
        ));
    }

    pub fn setMotionType(self: *Physics, body_id: BodyId, motion_type: MotionType) !void {
        try self.validateBody(body_id);
        c.JPH_BodyInterface_SetMotionType(
            self.body_interface,
            body_id.toJolt(),
            toJoltMotionType(motion_type),
            c.JPH_Activation_Activate,
        );
        // Motion type and collision layer are independent in Jolt. Keep them
        // coherent so a former static body enters the moving broad phase and
        // can collide with non-moving geometry (and vice versa).
        c.JPH_BodyInterface_SetObjectLayer(
            self.body_interface,
            body_id.toJolt(),
            objectLayerForMotionType(motion_type),
        );
    }

    /// Remove and destroy a body once. A stale or already-removed ID is a
    /// harmless false result rather than a second call into Jolt destruction.
    pub fn removeBody(self: *Physics, body_id: BodyId) bool {
        self.assertOwnerThread();
        if (!self.owns(body_id)) return false;
        const mapped_raw = self.body_handles.get(body_id.serial) orelse return false;
        if (mapped_raw != body_id.value) return false;
        if (!c.JPH_BodyInterface_IsAdded(self.body_interface, body_id.toJolt())) return false;
        c.JPH_BodyInterface_RemoveAndDestroyBody(self.body_interface, body_id.toJolt());
        if (!self.body_handles.remove(body_id.serial)) {
            @panic("physics body handle index removal invariant failed");
        }
        return true;
    }

    pub fn update(self: *Physics, delta_time: f32) StepError!void {
        self.assertOwnerThread();
        if (!std.math.isFinite(delta_time) or delta_time <= 0) {
            return error.InvalidDeltaTime;
        }
        const result = c.JPH_PhysicsSystem_Update2(
            self.system,
            delta_time,
            1,
            self.temp_allocator,
            self.job_system,
        );
        return checkPhysicsUpdateResult(result);
    }

    pub fn optimizeBroadPhase(self: *Physics) void {
        self.assertOwnerThread();
        c.JPH_PhysicsSystem_OptimizeBroadPhase(self.system);
    }
};

/// Compile-time physics capability consumed by the crate vertical slice.
/// Keeping the handle concrete avoids allocation, type erasure, and a Jolt
/// dependency in the feature module while still giving the host an explicit
/// composition seam.
pub const CrateBodies = struct {
    physics: *Physics,

    pub const Handle = BodyId;

    pub fn createDynamicBox(
        self: *CrateBodies,
        desc: engine.physics.DynamicBoxDesc,
    ) !Handle {
        const body_id = try self.physics.createDynamicBox(
            desc.pose.position,
            desc.half_extents,
        );
        errdefer _ = self.physics.removeBody(body_id);

        // Use the validated public adapter operations for the remainder of
        // creation. Any rejected rotation or velocity rolls the new body back.
        try self.physics.setBodyRotation(body_id, desc.pose.rotation);
        try self.physics.setLinearVelocity(body_id, desc.velocity.linear);
        try self.physics.setAngularVelocity(body_id, desc.velocity.angular);
        return body_id;
    }

    pub fn destroyBody(self: *CrateBodies, body_id: Handle) !void {
        try self.physics.validateBody(body_id);
        if (!self.physics.removeBody(body_id)) {
            @panic("validated crate body could not be removed");
        }
    }

    pub fn bodyState(
        self: *CrateBodies,
        body_id: Handle,
    ) !engine.physics.BodyState {
        return (engine.physics.BodyState{
            .pose = .{
                .position = try self.physics.getBodyPosition(body_id),
                .rotation = try self.physics.getBodyRotation(body_id),
            },
            .velocity = .{
                .linear = try self.physics.getLinearVelocity(body_id),
                .angular = try self.physics.getAngularVelocity(body_id),
            },
        }).normalized();
    }

    pub fn applyImpulse(
        self: *CrateBodies,
        body_id: Handle,
        impulse: [3]f32,
    ) !void {
        try self.physics.addImpulse(body_id, impulse);
    }

    pub fn step(self: *CrateBodies, delta_time: f32) !void {
        try self.physics.update(delta_time);
    }

    pub fn bodyCount(self: *CrateBodies) u32 {
        return self.physics.getBodyCount();
    }
};

fn isFiniteVector(value: [3]f32) bool {
    return std.math.isFinite(value[0]) and
        std.math.isFinite(value[1]) and
        std.math.isFinite(value[2]);
}

fn normalizeQuaternion(rotation: [4]f32) ![4]f32 {
    for (rotation) |component| {
        if (!std.math.isFinite(component)) return error.InvalidRotation;
    }

    const length_squared = rotation[0] * rotation[0] +
        rotation[1] * rotation[1] +
        rotation[2] * rotation[2] +
        rotation[3] * rotation[3];
    if (!std.math.isFinite(length_squared) or length_squared <= 1.0e-12) {
        return error.InvalidRotation;
    }

    const inverse_length = 1.0 / @sqrt(length_squared);
    return .{
        rotation[0] * inverse_length,
        rotation[1] * inverse_length,
        rotation[2] * inverse_length,
        rotation[3] * inverse_length,
    };
}

fn validateHalfExtents(half_extents: [3]f32) !void {
    if (!isFiniteVector(half_extents) or
        half_extents[0] <= 0 or
        half_extents[1] <= 0 or
        half_extents[2] <= 0)
    {
        return error.InvalidHalfExtents;
    }
}

fn checkPhysicsUpdateResult(result: c.JPH_PhysicsUpdateError) StepError!void {
    const raw: u32 = @intCast(result);
    if (raw == c.JPH_PhysicsUpdateError_None) return;

    const manifold: u32 = c.JPH_PhysicsUpdateError_ManifoldCacheFull;
    const body_pairs: u32 = c.JPH_PhysicsUpdateError_BodyPairCacheFull;
    const contacts: u32 = c.JPH_PhysicsUpdateError_ContactConstraintsFull;
    const known_mask = manifold | body_pairs | contacts;

    if (raw & ~known_mask != 0) return error.UnknownPhysicsUpdateFailure;
    if (raw & (raw - 1) != 0) return error.MultipleCapacityLimitsExceeded;

    return switch (raw) {
        manifold => error.ManifoldCacheFull,
        body_pairs => error.BodyPairCacheFull,
        contacts => error.ContactConstraintsFull,
        else => error.UnknownPhysicsUpdateFailure,
    };
}

fn getBoxHalfExtentsForTest(physics: *Physics, body_id: BodyId) ![3]f32 {
    try physics.validateBody(body_id);
    const shape = c.JPH_BodyInterface_GetShape(
        physics.body_interface,
        body_id.toJolt(),
    ) orelse return error.InvalidBodyId;
    if (c.JPH_Shape_GetSubType(shape) != c.JPH_ShapeSubType_Box) {
        return error.BodyIsNotBox;
    }

    var half_extents: c.JPH_Vec3 = undefined;
    c.JPH_BoxShape_GetHalfExtent(@ptrCast(shape), &half_extents);
    return .{ half_extents.x, half_extents.y, half_extents.z };
}

fn toVec3(value: [3]f32) c.JPH_Vec3 {
    return .{ .x = value[0], .y = value[1], .z = value[2] };
}

fn toJoltMotionType(motion_type: MotionType) c.JPH_MotionType {
    return switch (motion_type) {
        .static => c.JPH_MotionType_Static,
        .kinematic => c.JPH_MotionType_Kinematic,
        .dynamic => c.JPH_MotionType_Dynamic,
    };
}

fn objectLayerForMotionType(motion_type: MotionType) c.JPH_ObjectLayer {
    return if (motion_type == .static) object_layers.non_moving else object_layers.moving;
}

fn fromJoltMotionType(motion_type: c.JPH_MotionType) MotionType {
    return switch (motion_type) {
        c.JPH_MotionType_Static => .static,
        c.JPH_MotionType_Kinematic => .kinematic,
        c.JPH_MotionType_Dynamic => .dynamic,
        else => unreachable,
    };
}

test "Jolt 5.5 falling body lifecycle" {
    var physics = try Physics.init();
    defer physics.deinit();

    const ground = try physics.createStaticBox(.{ 0, -1, 0 }, .{ 10, 1, 10 });
    const crate = try physics.createDynamicBox(.{ 0, 5, 0 }, .{ 0.5, 0.5, 0.5 });

    try std.testing.expectEqual(@as(u32, 2), physics.getBodyCount());
    const initial_y = (try physics.getBodyPosition(crate))[1];

    for (0..30) |_| try physics.update(1.0 / 60.0);

    try std.testing.expect((try physics.getBodyPosition(crate))[1] < initial_y);

    try std.testing.expect(physics.removeBody(crate));
    try std.testing.expect(physics.removeBody(ground));
    try std.testing.expectEqual(@as(u32, 0), physics.getBodyCount());
}

test "physics update errors preserve Jolt capacity categories" {
    try checkPhysicsUpdateResult(c.JPH_PhysicsUpdateError_None);
    try std.testing.expectError(
        error.ManifoldCacheFull,
        checkPhysicsUpdateResult(c.JPH_PhysicsUpdateError_ManifoldCacheFull),
    );
    try std.testing.expectError(
        error.BodyPairCacheFull,
        checkPhysicsUpdateResult(c.JPH_PhysicsUpdateError_BodyPairCacheFull),
    );
    try std.testing.expectError(
        error.ContactConstraintsFull,
        checkPhysicsUpdateResult(c.JPH_PhysicsUpdateError_ContactConstraintsFull),
    );
    try std.testing.expectError(
        error.MultipleCapacityLimitsExceeded,
        checkPhysicsUpdateResult(
            c.JPH_PhysicsUpdateError_ManifoldCacheFull |
                c.JPH_PhysicsUpdateError_ContactConstraintsFull,
        ),
    );
    try std.testing.expectError(
        error.UnknownPhysicsUpdateFailure,
        checkPhysicsUpdateResult(1 << 10),
    );

    var physics = try Physics.init();
    defer physics.deinit();
    try std.testing.expectError(error.InvalidDeltaTime, physics.update(0));
    try std.testing.expectError(error.InvalidDeltaTime, physics.update(-1));
    try std.testing.expectError(
        error.InvalidDeltaTime,
        physics.update(std.math.nan(f32)),
    );
}

test "body creation rejects invalid geometry before entering Jolt" {
    var physics = try Physics.init();
    defer physics.deinit();

    try std.testing.expectError(
        error.InvalidHalfExtents,
        physics.createDynamicBox(.{ 0, 0, 0 }, .{ 0.5, -0.5, 0.5 }),
    );
    try std.testing.expectError(
        error.InvalidHalfExtents,
        physics.createDynamicBox(.{ 0, 0, 0 }, .{ std.math.inf(f32), 0.5, 0.5 }),
    );
    try std.testing.expectError(
        error.InvalidRadius,
        physics.createDynamicSphere(.{ 0, 0, 0 }, 0),
    );
    try std.testing.expectError(
        error.InvalidPosition,
        physics.createDynamicSphere(.{ std.math.nan(f32), 0, 0 }, 0.5),
    );
    try std.testing.expectEqual(@as(u32, 0), physics.getBodyCount());
}

test "box shape replacement preserves body identity and state" {
    var physics = try Physics.init();
    defer physics.deinit();

    const body = try physics.createDynamicBox(.{ 2, 3, 4 }, .{ 0.5, 0.5, 0.5 });
    defer _ = physics.removeBody(body);

    try physics.setLinearVelocity(body, .{ 1, 2, 3 });
    const position_before = try physics.getBodyPosition(body);

    try physics.setBoxHalfExtents(body, .{ 1.25, 2.5, 3.75 });

    try std.testing.expect(physics.isBodyAdded(body));
    try std.testing.expectEqual(@as(u32, 1), physics.getBodyCount());
    const position_after = try physics.getBodyPosition(body);
    for (position_before, position_after) |before, after| {
        try std.testing.expectApproxEqAbs(before, after, 0.0001);
    }

    const resized = try getBoxHalfExtentsForTest(&physics, body);
    try std.testing.expectApproxEqAbs(@as(f32, 1.25), resized[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 2.5), resized[1], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 3.75), resized[2], 0.0001);

    try std.testing.expectError(
        error.InvalidHalfExtents,
        physics.setBoxHalfExtents(body, .{ 1, -1, 1 }),
    );
    const after_failed_resize = try getBoxHalfExtentsForTest(&physics, body);
    try std.testing.expectEqual(resized, after_failed_resize);
}

test "Jolt runtime lease keeps a surviving world usable" {
    const leases_before = runtimeLeaseCount();

    var first = try Physics.init();
    defer first.deinit();
    try std.testing.expectEqual(leases_before + 1, runtimeLeaseCount());

    var second = try Physics.init();
    try std.testing.expectEqual(leases_before + 2, runtimeLeaseCount());
    second.deinit();
    try std.testing.expectEqual(leases_before + 1, runtimeLeaseCount());

    const body = try first.createDynamicBox(.{ 0, 2, 0 }, .{ 0.5, 0.5, 0.5 });
    try first.update(1.0 / 60.0);
    try std.testing.expect(first.isBodyAdded(body));
    try std.testing.expect(first.removeBody(body));
}

test "body IDs cannot cross live physics worlds" {
    var first = try Physics.init();
    defer first.deinit();
    var second = try Physics.init();
    defer second.deinit();

    const first_body = try first.createDynamicBox(.{ 1, 2, 3 }, .{ 0.5, 0.5, 0.5 });
    defer _ = first.removeBody(first_body);
    const second_body = try second.createDynamicBox(.{ 4, 5, 6 }, .{ 0.5, 0.5, 0.5 });
    defer _ = second.removeBody(second_body);

    try std.testing.expect(first_body.world_token != second_body.world_token);
    try std.testing.expect(!second.isBodyAdded(first_body));
    try std.testing.expect(!second.removeBody(first_body));
    try std.testing.expectError(
        error.ForeignBodyId,
        second.getBodyPosition(first_body),
    );
    try std.testing.expectError(
        error.ForeignBodyId,
        second.setBodyPosition(first_body, .{ 20, 20, 20 }),
    );
    try std.testing.expect(second.isBodyAdded(second_body));
    try std.testing.expectEqual(
        [3]f32{ 4, 5, 6 },
        try second.getBodyPosition(second_body),
    );
}

test "body IDs stay stale across runtime shutdown and world recreation" {
    var first = try Physics.init();
    const stale_body = try first.createDynamicBox(.{ 1, 2, 3 }, .{ 0.5, 0.5, 0.5 });
    try std.testing.expect(first.removeBody(stale_body));
    first.deinit();

    var replacement_world = try Physics.init();
    defer replacement_world.deinit();
    const replacement = try replacement_world.createDynamicBox(
        .{ 7, 8, 9 },
        .{ 0.5, 0.5, 0.5 },
    );
    defer _ = replacement_world.removeBody(replacement);

    try std.testing.expect(stale_body.world_token != replacement.world_token);
    try std.testing.expect(!replacement_world.isBodyAdded(stale_body));
    try std.testing.expect(!replacement_world.removeBody(stale_body));
    try std.testing.expectError(
        error.ForeignBodyId,
        replacement_world.setLinearVelocity(stale_body, .{ 1, 2, 3 }),
    );
    try std.testing.expect(replacement_world.isBodyAdded(replacement));
}

test "body mutators reject stale and invalid values" {
    var physics = try Physics.init();
    defer physics.deinit();

    const body = try physics.createDynamicBox(.{ 0, 1, 0 }, .{ 0.5, 0.5, 0.5 });

    try std.testing.expectError(
        error.InvalidPosition,
        physics.setBodyPosition(body, .{ std.math.inf(f32), 0, 0 }),
    );
    try std.testing.expectError(
        error.InvalidVelocity,
        physics.setLinearVelocity(body, .{ 0, std.math.nan(f32), 0 }),
    );
    try std.testing.expectError(
        error.InvalidForce,
        physics.addForce(body, .{ 0, 0, std.math.inf(f32) }),
    );
    try std.testing.expectError(
        error.InvalidImpulse,
        physics.addImpulse(body, .{ std.math.nan(f32), 0, 0 }),
    );
    try std.testing.expectError(
        error.InvalidRotation,
        physics.setBodyRotation(body, .{ 0, 0, 0, 0 }),
    );
    try std.testing.expectError(
        error.InvalidRotation,
        physics.setBodyRotation(body, .{ 0, 0, 0, std.math.nan(f32) }),
    );

    try physics.setBodyRotation(body, .{ 0, 0, 0, 2 });
    const normalized = try physics.getBodyRotation(body);
    try std.testing.expectApproxEqAbs(@as(f32, 1), normalized[3], 0.0001);

    try std.testing.expect(physics.removeBody(body));
    try std.testing.expectError(
        error.InvalidBodyId,
        physics.setBodyPosition(body, .{ 1, 2, 3 }),
    );
    try std.testing.expectError(
        error.InvalidBodyId,
        physics.getBodyRotation(body),
    );

    const static_body = try physics.createStaticBox(.{ 0, 0, 0 }, .{ 1, 1, 1 });
    defer _ = physics.removeBody(static_body);
    try physics.setMotionType(static_body, .kinematic);
    try std.testing.expectEqual(
        MotionType.kinematic,
        try physics.getMotionType(static_body),
    );
    try physics.setMotionType(static_body, .static);
}

test "motion type changes update the collision layer" {
    var physics = try Physics.init();
    defer physics.deinit();

    const ground = try physics.createStaticBox(.{ 0, -1, 0 }, .{ 5, 1, 5 });
    defer _ = physics.removeBody(ground);
    const box = try physics.createStaticBox(.{ 0, 3, 0 }, .{ 0.5, 0.5, 0.5 });
    defer _ = physics.removeBody(box);

    try physics.setMotionType(box, .dynamic);
    try std.testing.expectEqual(
        object_layers.moving,
        c.JPH_BodyInterface_GetObjectLayer(physics.body_interface, box.toJolt()),
    );
    for (0..240) |_| try physics.update(1.0 / 120.0);
    const landed = try physics.getBodyPosition(box);
    try std.testing.expect(landed[1] > 0.4);
    try std.testing.expect(landed[1] < 0.7);

    try physics.setMotionType(box, .static);
    try std.testing.expectEqual(
        object_layers.non_moving,
        c.JPH_BodyInterface_GetObjectLayer(physics.body_interface, box.toJolt()),
    );
}

test "a live runtime rejects world creation from another thread" {
    var physics = try Physics.init();
    defer physics.deinit();

    const Context = struct {
        result: ?anyerror = null,

        fn run(context: *@This()) void {
            var foreign_world = Physics.init() catch |err| {
                context.result = err;
                return;
            };
            foreign_world.deinit();
        }
    };

    var context = Context{};
    const thread = try std.Thread.spawn(.{}, Context.run, .{&context});
    thread.join();
    try std.testing.expectEqual(error.WrongThread, context.result.?);
}

test "repeated body create and destroy rejects stale removal" {
    var physics = try Physics.init();
    defer physics.deinit();

    for (0..64) |index| {
        const x: f32 = @floatFromInt(index);
        const body = try physics.createDynamicBox(.{ x, 1, 0 }, .{ 0.5, 0.5, 0.5 });
        try std.testing.expect(physics.isBodyAdded(body));
        try std.testing.expectEqual(@as(u32, 1), physics.getBodyCount());
        try std.testing.expect(physics.removeBody(body));
        try std.testing.expect(!physics.isBodyAdded(body));
        try std.testing.expect(!physics.removeBody(body));
        try std.testing.expectEqual(@as(u32, 0), physics.getBodyCount());
    }
}

test "engine body serial stays stale after Jolt sequence wrap" {
    var physics = try Physics.init();
    defer physics.deinit();

    const first = try physics.createDynamicBox(.{ 0, 1, 0 }, .{ 0.5, 0.5, 0.5 });
    try std.testing.expect(physics.removeBody(first));

    // Jolt's native per-slot sequence is eight bits. Reusing a slot beyond
    // 256 cycles must never make the retained engine handle valid again.
    for (0..600) |_| {
        const current = try physics.createDynamicBox(.{ 0, 1, 0 }, .{ 0.5, 0.5, 0.5 });
        try std.testing.expect(!physics.isBodyAdded(first));
        try std.testing.expectError(error.InvalidBodyId, physics.getBodyPosition(first));
        try std.testing.expect(!physics.removeBody(first));
        try std.testing.expect(physics.isBodyAdded(current));
        try std.testing.expect(physics.removeBody(current));
    }
    try std.testing.expectEqual(@as(u32, 0), physics.getBodyCount());
}

test "crate capability round-trips Jolt body state transactionally" {
    comptime engine.physics.assertImplementation(CrateBodies);

    var physics = try Physics.init();
    defer physics.deinit();
    var bodies = physics.crateBodies();

    const desc = engine.physics.DynamicBoxDesc{
        .pose = .{
            .position = .{ 1.5, 4.0, -2.25 },
            // Exercise the adapter's normalization boundary as well as the
            // orientation round trip.
            .rotation = .{ 0, 0, 0, 2 },
        },
        .velocity = .{
            .linear = .{ 0.25, -0.5, 1.5 },
            .angular = .{ -0.75, 0.125, 0.5 },
        },
        .half_extents = .{ 0.5, 1.0, 1.5 },
    };
    const body = try bodies.createDynamicBox(desc);
    try std.testing.expectEqual(@as(u32, 1), bodies.bodyCount());

    const state = try bodies.bodyState(body);
    for (desc.pose.position, state.pose.position) |expected, actual| {
        try std.testing.expectApproxEqAbs(expected, actual, 0.0001);
    }
    try std.testing.expectApproxEqAbs(@as(f32, 0), state.pose.rotation[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), state.pose.rotation[1], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), state.pose.rotation[2], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1), state.pose.rotation[3], 0.0001);
    for (desc.velocity.linear, state.velocity.linear) |expected, actual| {
        try std.testing.expectApproxEqAbs(expected, actual, 0.0001);
    }
    for (desc.velocity.angular, state.velocity.angular) |expected, actual| {
        try std.testing.expectApproxEqAbs(expected, actual, 0.0001);
    }

    try bodies.applyImpulse(body, .{ 0, 0.25, 0 });
    try bodies.step(1.0 / 60.0);

    try bodies.destroyBody(body);
    try std.testing.expectEqual(@as(u32, 0), bodies.bodyCount());
    try std.testing.expectError(error.InvalidBodyId, bodies.destroyBody(body));
    try std.testing.expectError(error.InvalidBodyId, bodies.bodyState(body));

    // Rotation validation happens after Jolt creates the body, so this proves
    // the capability removes a partially configured body on later failure.
    try std.testing.expectError(
        error.InvalidRotation,
        bodies.createDynamicBox(.{
            .pose = .{ .rotation = .{ 0, 0, 0, 0 } },
            .half_extents = .{ 0.5, 0.5, 0.5 },
        }),
    );
    try std.testing.expectEqual(@as(u32, 0), bodies.bodyCount());
}
