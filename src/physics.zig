//! Narrow engine adapter for Jolt Physics 5.5 through JoltC.
//!
//! This module owns all C API details used by the current sandbox. ECS,
//! gameplay, and editor code use the engine-defined `BodyId` and `MotionType`
//! below; they do not depend on Jolt's headers or mirrored C layouts.

const std = @import("std");
const engine = @import("engine_contracts");
const c = @import("jolt_c").c;
const simulation_cohort_options = @import("simulation_cohort_options");
const physics_debug = engine.physics_debug;

const invalid_body_id: c.JPH_BodyID = std.math.maxInt(c.JPH_BodyID);
const temp_allocator_bytes: u32 = 10 * 1024 * 1024;
pub const max_bodies: u32 = simulation_cohort_options.jolt_max_bodies;
/// Fixed per-world Jolt broad/narrow-phase product budgets. Exhaustion is a
/// typed terminal step error; representative S8/M3 scale remains far below
/// these ceilings and never relies on Jolt reallocating authority implicitly.
pub const max_body_pairs: u32 = 65_536;
pub const max_contact_constraints: u32 = 10_240;
/// One Physics-owned ceiling shared by every CharacterControllers view.
pub const max_virtual_characters: usize =
    simulation_cohort_options.jolt_max_virtual_characters;

/// Exact job-system sizing for the supported Jolt 5.5/JoltC cohort.
///
/// JoltC maps a null config, zero capacities, or a non-positive thread count
/// back to Jolt defaults; the thread default is hardware-derived. Keep every
/// field positive and explicit so world creation has a stable resource and
/// scheduling footprint. One worker is the smallest explicit count this JoltC
/// wrapper honors; Jolt may also execute jobs on the owner thread while it
/// waits, giving the world a maximum concurrency of two.
pub const job_system_worker_count: i32 = simulation_cohort_options.jolt_worker_count;
pub const job_system_max_jobs: u32 = simulation_cohort_options.jolt_max_jobs;
pub const job_system_max_barriers: u32 = simulation_cohort_options.jolt_max_barriers;

fn jobSystemThreadPoolConfig() c.JobSystemThreadPoolConfig {
    return .{
        .maxJobs = job_system_max_jobs,
        .maxBarriers = job_system_max_barriers,
        .numThreads = job_system_worker_count,
    };
}

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

pub const CharacterId = struct {
    world_token: u64,
    serial: u64,
};

pub const VehicleId = struct {
    world_token: u64,
    serial: u64,
};

const DebugConfig = physics_debug.Config;

/// Availability of the optional rigid-body contact evidence producer.
///
/// CharacterVirtual and vehicle-wheel contacts are extracted directly and do
/// not depend on this capability. Physics authority and every other debug
/// category remain usable when this optional producer is unavailable.
pub const RigidContactCaptureAvailability = enum {
    available,
    unavailable_scratch_allocation,
    unavailable_listener_creation,
};

pub const DebugExtraction = struct {
    batch: physics_debug.Batch,
    rigid_contact_capture: RigidContactCaptureAvailability,
};

/// Plain namespaces used only to correlate debug primitives. These are engine
/// serials, never Jolt body IDs or pointers.
pub const debug_object_kinds = struct {
    pub const body: u32 = 1;
    pub const character: u32 = 2;
    pub const vehicle: u32 = 3;
};

const BodyShapeDescriptor = union(enum) {
    box: [3]f32,
    sphere: f32,
};

const BodyHandleRecord = struct {
    raw_id: u32,
    shape: BodyShapeDescriptor,
};

const CharacterHandleRecord = struct {
    character: *c.JPH_CharacterVirtual,
    radius: f32,
    half_height: f32,
};

const VehicleHandleRecord = struct {
    body_id: c.JPH_BodyID,
    constraint: *c.JPH_VehicleConstraint,
    chassis_half_extents: [3]f32,
    center_of_mass_offset: [3]f32,
    wheel_attachment_positions: [engine.physics.vehicle_wheel_count][3]f32,
    wheel_radius: f32,
    wheel_width: f32,
};

const rigid_contact_capacity: usize = 4_096;

const RigidContact = struct {
    body_a: u32,
    body_b: u32,
    point: [3]f32,
    normal: [3]f32,
};

const ContactSlot = struct {
    contact: RigidContact = undefined,
    published: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

/// Jolt may call one listener from its worker and from the owner thread. Each
/// callback atomically reserves one disjoint slot and only copies plain values;
/// the owner consumes the scratch after JPH_PhysicsSystem_Update2 returns.
const ContactScratch = struct {
    reserved: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    dropped: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    contacts: [rigid_contact_capacity]ContactSlot =
        [_]ContactSlot{.{}} ** rigid_contact_capacity,

    fn reset(self: *ContactScratch) void {
        for (self.contacts[0..self.count()]) |*slot| {
            slot.published.store(false, .monotonic);
        }
        self.reserved.store(0, .release);
        self.dropped.store(0, .release);
    }

    fn append(self: *ContactScratch, contact: RigidContact) void {
        const index = self.reserved.fetchAdd(1, .acq_rel);
        if (index >= rigid_contact_capacity) {
            _ = self.dropped.fetchAdd(1, .monotonic);
            return;
        }
        self.contacts[index].contact = contact;
        self.contacts[index].published.store(true, .release);
    }

    fn count(self: *const ContactScratch) usize {
        return @min(
            @as(usize, self.reserved.load(.acquire)),
            rigid_contact_capacity,
        );
    }
};

const ContactDebugResources = struct {
    listener: *c.JPH_ContactListener,
    scratch: *ContactScratch,
};

/// Private deterministic seam for the native creation-null branch. Scratch
/// allocation failure is tested with a genuinely bounded allocator instead.
const ContactDebugCreationTestFailure = enum {
    listener_creation,
};

/// A tagged union keeps the listener/scratch lifetime invariant structural:
/// resources are either both present or both absent with a visible reason.
const ContactDebugCapture = union(RigidContactCaptureAvailability) {
    available: ContactDebugResources,
    unavailable_scratch_allocation: void,
    unavailable_listener_creation: void,

    fn init(
        allocator: std.mem.Allocator,
        comptime test_failure: ?ContactDebugCreationTestFailure,
    ) ContactDebugCapture {
        const scratch = allocator.create(ContactScratch) catch {
            return .{ .unavailable_scratch_allocation = {} };
        };
        scratch.* = .{};

        c.JPH_ContactListener_SetProcs(&contact_listener_procs);
        if (test_failure == .listener_creation) {
            allocator.destroy(scratch);
            return .{ .unavailable_listener_creation = {} };
        }
        const listener = c.JPH_ContactListener_Create(scratch) orelse {
            allocator.destroy(scratch);
            return .{ .unavailable_listener_creation = {} };
        };
        return .{ .available = .{
            .listener = listener,
            .scratch = scratch,
        } };
    }

    fn availability(self: ContactDebugCapture) RigidContactCaptureAvailability {
        return std.meta.activeTag(self);
    }

    fn install(self: ContactDebugCapture, system: *c.JPH_PhysicsSystem) void {
        switch (self) {
            .available => |resources| {
                c.JPH_PhysicsSystem_SetContactListener(system, resources.listener);
            },
            else => {},
        }
    }

    fn deinit(
        self: ContactDebugCapture,
        system: *c.JPH_PhysicsSystem,
        allocator: std.mem.Allocator,
    ) void {
        switch (self) {
            .available => |resources| {
                // Update jobs have joined before Physics.update returns. The
                // owner detaches first so no future callback can retain the
                // scratch pointer, then releases listener and scratch in order.
                c.JPH_PhysicsSystem_SetContactListener(system, null);
                c.JPH_ContactListener_Destroy(resources.listener);
                allocator.destroy(resources.scratch);
            },
            else => {},
        }
    }

    fn reset(self: *ContactDebugCapture) void {
        switch (self.*) {
            .available => |resources| resources.scratch.reset(),
            else => {},
        }
    }
};

fn captureRigidContacts(
    raw: ?*anyopaque,
    body_a: ?*const c.JPH_Body,
    body_b: ?*const c.JPH_Body,
    manifold: ?*const c.JPH_ContactManifold,
) void {
    const scratch: *ContactScratch = @ptrCast(@alignCast(raw.?));
    var normal: c.JPH_Vec3 = undefined;
    c.JPH_ContactManifold_GetWorldSpaceNormal(manifold, &normal);
    const point_count = c.JPH_ContactManifold_GetPointCount(manifold);
    const raw_body_a: u32 = @intCast(c.JPH_Body_GetID(body_a));
    const raw_body_b: u32 = @intCast(c.JPH_Body_GetID(body_b));
    for (0..point_count) |index| {
        var point: c.JPH_RVec3 = undefined;
        c.JPH_ContactManifold_GetWorldSpaceContactPointOn1(
            manifold,
            @intCast(index),
            &point,
        );
        scratch.append(.{
            .body_a = raw_body_a,
            .body_b = raw_body_b,
            .point = fromRVec3(point),
            .normal = fromVec3(normal),
        });
    }
}

fn contactAdded(
    raw: ?*anyopaque,
    body_a: ?*const c.JPH_Body,
    body_b: ?*const c.JPH_Body,
    manifold: ?*const c.JPH_ContactManifold,
    _: [*c]c.JPH_ContactSettings,
) callconv(.c) void {
    captureRigidContacts(raw, body_a, body_b, manifold);
}

fn contactPersisted(
    raw: ?*anyopaque,
    body_a: ?*const c.JPH_Body,
    body_b: ?*const c.JPH_Body,
    manifold: ?*const c.JPH_ContactManifold,
    _: [*c]c.JPH_ContactSettings,
) callconv(.c) void {
    captureRigidContacts(raw, body_a, body_b, manifold);
}

const contact_listener_procs = c.JPH_ContactListener_Procs{
    .OnContactAdded = contactAdded,
    .OnContactPersisted = contactPersisted,
};

const VehicleCreateFailurePoint = enum {
    after_body,
    after_settings,
    after_constraint,
    after_collision_tester,
    after_registration,
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

const CharacterRelocationQuery = struct {
    body_interface: *c.JPH_BodyInterface,
    max_penetration_depth: f32,
    blocked: bool = false,
};

fn collectCharacterRelocationHit(
    raw: ?*anyopaque,
    result: [*c]const c.JPH_CollideShapeResult,
) callconv(.c) f32 {
    const query: *CharacterRelocationQuery = @ptrCast(@alignCast(raw.?));
    const hit = result[0];
    if (hit.penetrationDepth <= query.max_penetration_depth or
        c.JPH_BodyInterface_IsSensor(query.body_interface, hit.bodyID2))
    {
        return std.math.floatMax(f32);
    }
    query.blocked = true;
    return 0;
}

/// Deterministic checkpoints for testing cleanup across Jolt's real ownership
/// transitions. This stays private to the adapter: production callers cannot
/// request a partially initialized world.
const InitFailurePoint = enum {
    after_runtime_lease,
    after_job_and_temp_allocators,
    after_filter_bundle,
    after_physics_system_transfer,
    after_contact_listener,
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

fn failInitAt(
    comptime requested: ?InitFailurePoint,
    comptime reached: InitFailurePoint,
) !void {
    if (requested == reached) return error.InjectedInitFailure;
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
    scratch_allocator: std.mem.Allocator,
    contact_debug_capture: ContactDebugCapture,
    body_handles: std.AutoHashMap(u64, BodyHandleRecord),
    character_handles: std.AutoHashMap(u64, CharacterHandleRecord),
    vehicle_handles: std.AutoHashMap(u64, VehicleHandleRecord),
    next_body_serial: u64 = 1,
    next_character_serial: u64 = 1,
    next_vehicle_serial: u64 = 1,
    update_in_progress: bool = false,
    has_completed_update: bool = false,

    pub fn init() !Physics {
        return initWithAllocator(std.heap.page_allocator);
    }

    pub fn initWithAllocator(allocator: std.mem.Allocator) !Physics {
        return initWithAllocatorAndFailurePoint(allocator, null);
    }

    fn initWithAllocatorAndFailurePoint(
        allocator: std.mem.Allocator,
        comptime failure_point: ?InitFailurePoint,
    ) !Physics {
        return initWithOptions(allocator, failure_point, null);
    }

    fn initWithContactDebugFailureForTest(
        allocator: std.mem.Allocator,
        comptime contact_debug_failure: ContactDebugCreationTestFailure,
    ) !Physics {
        return initWithOptions(allocator, null, contact_debug_failure);
    }

    fn initWithOptions(
        allocator: std.mem.Allocator,
        comptime failure_point: ?InitFailurePoint,
        comptime contact_debug_failure: ?ContactDebugCreationTestFailure,
    ) !Physics {
        const world_token = try acquireRuntimeLease();
        errdefer releaseRuntimeLease();
        if (failure_point != null) {
            try failInitAt(failure_point, .after_runtime_lease);
        }

        const job_system_config = jobSystemThreadPoolConfig();
        const job_system = c.JPH_JobSystemThreadPool_Create(&job_system_config) orelse
            return error.JobSystemCreationFailed;
        errdefer c.JPH_JobSystem_Destroy(job_system);

        const temp_allocator = c.JPH_TempAllocator_Create(temp_allocator_bytes) orelse
            return error.TempAllocatorCreationFailed;
        errdefer c.JPH_TempAllocator_Destroy(temp_allocator);
        if (failure_point != null) {
            try failInitAt(failure_point, .after_job_and_temp_allocators);
        }

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
        if (failure_point != null) {
            try failInitAt(failure_point, .after_filter_bundle);
        }

        const settings = c.JPH_PhysicsSystemSettings{
            .maxBodies = max_bodies,
            .numBodyMutexes = 0,
            .maxBodyPairs = max_body_pairs,
            .maxContactConstraints = max_contact_constraints,
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
        if (failure_point != null) {
            try failInitAt(failure_point, .after_physics_system_transfer);
        }

        // A created system always exposes a body interface.
        const body_interface = c.JPH_PhysicsSystem_GetBodyInterface(system) orelse unreachable;

        const contact_debug_capture = ContactDebugCapture.init(
            allocator,
            contact_debug_failure,
        );
        errdefer contact_debug_capture.deinit(system, allocator);
        contact_debug_capture.install(system);
        if (failure_point != null) {
            try failInitAt(failure_point, .after_contact_listener);
        }

        var gravity = c.JPH_Vec3{ .x = 0, .y = -9.81, .z = 0 };
        c.JPH_PhysicsSystem_SetGravity(system, &gravity);

        return .{
            .owner_thread = std.Thread.getCurrentId(),
            .world_token = world_token,
            .system = system,
            .body_interface = body_interface,
            .job_system = job_system,
            .temp_allocator = temp_allocator,
            .scratch_allocator = allocator,
            .contact_debug_capture = contact_debug_capture,
            .body_handles = std.AutoHashMap(u64, BodyHandleRecord).init(allocator),
            .character_handles = std.AutoHashMap(u64, CharacterHandleRecord).init(allocator),
            .vehicle_handles = std.AutoHashMap(u64, VehicleHandleRecord).init(allocator),
        };
    }

    pub fn deinit(self: *Physics) void {
        self.assertOwnerThread();
        if (self.body_handles.count() != 0) {
            @panic("physics world deinitialized with live body handles");
        }
        if (self.character_handles.count() != 0) {
            @panic("physics world deinitialized with live character handles");
        }
        if (self.vehicle_handles.count() != 0) {
            @panic("physics world deinitialized with live vehicle handles");
        }
        self.contact_debug_capture.deinit(self.system, self.scratch_allocator);
        c.JPH_PhysicsSystem_Destroy(self.system);
        c.JPH_TempAllocator_Destroy(self.temp_allocator);
        c.JPH_JobSystem_Destroy(self.job_system);
        self.body_handles.deinit();
        self.character_handles.deinit();
        self.vehicle_handles.deinit();
        releaseRuntimeLease();
        self.* = undefined;
    }

    /// Expose only the body operations required by the crate feature. The
    /// feature is generic over this concrete capability and never imports
    /// Jolt or this adapter directly.
    pub fn crateBodies(self: *Physics) CrateBodies {
        return .{ .physics = self };
    }

    /// Expose only static-body ownership to district environment features.
    pub fn districtBodies(self: *Physics) DistrictBodies {
        return .{ .physics = self };
    }

    /// Expose the world step independently from every feature capability. The
    /// composition root registers exactly one instance for the shared world.
    pub fn stepper(self: *Physics) PhysicsStepper {
        return .{ .physics = self };
    }

    /// Expose only the controller operations required by CharacterFeature.
    pub fn characterControllers(self: *Physics) CharacterControllers {
        return .{ .physics = self };
    }

    /// Expose only the four-wheel operations required by the S2 capability.
    pub fn vehicles(self: *Physics) Vehicles {
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
        const record = self.body_handles.get(body_id.serial) orelse
            return error.InvalidBodyId;
        if (record.raw_id != body_id.value) return error.InvalidBodyId;
        if (!c.JPH_BodyInterface_IsAdded(self.body_interface, body_id.toJolt())) {
            return error.InvalidBodyId;
        }
    }

    fn characterPtr(
        self: *Physics,
        character_id: CharacterId,
    ) !*c.JPH_CharacterVirtual {
        self.assertOwnerThread();
        if (self.world_token != character_id.world_token) {
            return error.ForeignCharacterId;
        }
        const record = self.character_handles.get(character_id.serial) orelse
            return error.InvalidCharacterId;
        return record.character;
    }

    fn createVirtualCharacter(
        self: *Physics,
        desc: engine.physics.CharacterDesc,
    ) !CharacterId {
        self.assertOwnerThread();
        try desc.validate();
        if (self.next_character_serial == 0) {
            return error.CharacterHandleSerialExhausted;
        }
        if (self.character_handles.count() >= max_virtual_characters) {
            return error.TooManyCharacters;
        }
        try self.character_handles.ensureUnusedCapacity(1);

        var capsule_offset = toVec3(.{ 0, desc.half_height + desc.radius, 0 });
        const capsule = c.JPH_CapsuleShape_Create(desc.half_height, desc.radius) orelse
            return error.CharacterShapeCreationFailed;
        const capsule_shape: *c.JPH_Shape = @ptrCast(capsule);
        defer c.JPH_Shape_Destroy(capsule_shape);

        // CharacterVirtual expects a bottom-anchored shape. Offset the normal
        // center-origin capsule so the logical position is at its feet.
        const translated = c.JPH_RotatedTranslatedShape_Create(
            &capsule_offset,
            null,
            capsule_shape,
        ) orelse return error.CharacterShapeCreationFailed;
        const character_shape: *c.JPH_Shape = @ptrCast(translated);
        defer c.JPH_Shape_Destroy(character_shape);

        const serial = self.next_character_serial;
        const settings = c.JPH_CharacterVirtualSettings{
            .base = .{
                .up = toVec3(.{ 0, 1, 0 }),
                .supportingVolume = .{
                    .normal = toVec3(.{ 0, 1, 0 }),
                    .distance = -desc.radius,
                },
                .maxSlopeAngle = desc.max_slope_radians,
                .enhancedInternalEdgeRemoval = true,
                .shape = character_shape,
            },
            // Zero preserves the process-unique ID generated by the
            // CharacterVirtualSettings constructor inside JoltC. Engine
            // handles use their separate world-qualified serial below.
            .ID = 0,
            .mass = desc.mass,
            .maxStrength = desc.max_strength,
            .shapeOffset = toVec3(.{ 0, 0, 0 }),
            .backFaceMode = c.JPH_BackFaceMode_CollideWithBackFaces,
            .predictiveContactDistance = 0.1,
            .maxCollisionIterations = 5,
            .maxConstraintIterations = 15,
            .minTimeRemaining = 0.0001,
            .collisionTolerance = 0.001,
            .characterPadding = 0.02,
            .maxNumHits = 256,
            .hitReductionCosMaxAngle = 0.999,
            .penetrationRecoverySpeed = 1.0,
            .innerBodyShape = null,
            .innerBodyIDOverride = 0,
            .innerBodyLayer = object_layers.moving,
        };
        var position = toRVec3(desc.position);
        const character = c.JPH_CharacterVirtual_Create(
            &settings,
            &position,
            null,
            0,
            self.system,
        ) orelse return error.CharacterCreationFailed;
        errdefer c.JPH_CharacterBase_Destroy(@ptrCast(character));

        var velocity = toVec3(desc.velocity);
        c.JPH_CharacterVirtual_SetLinearVelocity(character, &velocity);
        // Creation and snapshot reconstruction are logical teleports. Seed
        // support/contact state before gameplay can submit its first action.
        c.JPH_CharacterVirtual_RefreshContacts(
            character,
            object_layers.moving,
            self.system,
            null,
            null,
        );
        try ensureCharacterContactCapacity(character);
        self.character_handles.putAssumeCapacityNoClobber(serial, .{
            .character = character,
            .radius = desc.radius,
            .half_height = desc.half_height,
        });
        self.next_character_serial +%= 1;
        return .{ .world_token = self.world_token, .serial = serial };
    }

    fn destroyVirtualCharacter(
        self: *Physics,
        character_id: CharacterId,
    ) !void {
        const character = try self.characterPtr(character_id);
        c.JPH_CharacterBase_Destroy(@ptrCast(character));
        if (!self.character_handles.remove(character_id.serial)) {
            @panic("character handle index removal invariant failed");
        }
    }

    fn virtualCharacterState(
        self: *Physics,
        character_id: CharacterId,
    ) !engine.physics.CharacterState {
        const character = try self.characterPtr(character_id);
        var position: c.JPH_RVec3 = undefined;
        var velocity: c.JPH_Vec3 = undefined;
        var ground_velocity: c.JPH_Vec3 = undefined;
        var ground_normal: c.JPH_Vec3 = undefined;
        c.JPH_CharacterVirtual_GetPosition(character, &position);
        c.JPH_CharacterVirtual_GetLinearVelocity(character, &velocity);
        const base: *c.JPH_CharacterBase = @ptrCast(character);
        c.JPH_CharacterBase_GetGroundVelocity(base, &ground_velocity);
        c.JPH_CharacterBase_GetGroundNormal(base, &ground_normal);

        const state = engine.physics.CharacterState{
            .position = fromRVec3(position),
            .velocity = fromVec3(velocity),
            .ground_state = fromJoltGroundState(c.JPH_CharacterBase_GetGroundState(base)),
            .ground_velocity = fromVec3(ground_velocity),
            .ground_normal = fromVec3(ground_normal),
        };
        try state.validate();
        return state;
    }

    fn prepareVirtualCharacter(
        self: *Physics,
        character_id: CharacterId,
    ) !engine.physics.CharacterState {
        const character = try self.characterPtr(character_id);
        c.JPH_CharacterVirtual_UpdateGroundVelocity(character);
        return self.virtualCharacterState(character_id);
    }

    fn updateVirtualCharacter(
        self: *Physics,
        character_id: CharacterId,
        update_desc: engine.physics.CharacterUpdate,
        delta_time: f32,
    ) !engine.physics.CharacterState {
        self.assertOwnerThread();
        try update_desc.validate();
        if (!std.math.isFinite(delta_time) or delta_time <= 0) {
            return error.InvalidDeltaTime;
        }
        const character = try self.characterPtr(character_id);
        var velocity = toVec3(update_desc.velocity);
        c.JPH_CharacterVirtual_SetLinearVelocity(character, &velocity);
        const settings = c.JPH_ExtendedUpdateSettings{
            .stickToFloorStepDown = toVec3(.{ 0, -update_desc.stick_to_floor_distance, 0 }),
            .walkStairsStepUp = toVec3(.{ 0, update_desc.step_up_height, 0 }),
            .walkStairsMinStepForward = 0.02,
            .walkStairsStepForwardTest = 0.15,
            .walkStairsCosAngleForwardContact = 0.25881904,
            .walkStairsStepDownExtra = toVec3(.{ 0, 0, 0 }),
        };
        c.JPH_CharacterVirtual_ExtendedUpdate(
            character,
            delta_time,
            &settings,
            object_layers.moving,
            self.system,
            null,
            null,
        );
        try ensureCharacterContactCapacity(character);
        return self.virtualCharacterState(character_id);
    }

    fn tryRelocateVirtualCharacter(
        self: *Physics,
        character_id: CharacterId,
        relocation: engine.physics.CharacterRelocation,
    ) !?engine.physics.CharacterState {
        self.assertOwnerThread();
        try relocation.validate();
        const character = try self.characterPtr(character_id);

        var original_position: c.JPH_RVec3 = undefined;
        var original_velocity: c.JPH_Vec3 = undefined;
        c.JPH_CharacterVirtual_GetPosition(character, &original_position);
        c.JPH_CharacterVirtual_GetLinearVelocity(character, &original_velocity);

        // Query the candidate transform before mutating CharacterVirtual. This
        // keeps a blocked exit from changing active contacts or callbacks.
        var center_of_mass_transform: c.JPH_RMat4 = undefined;
        c.JPH_CharacterVirtual_GetCenterOfMassTransform(
            character,
            &center_of_mass_transform,
        );
        center_of_mass_transform.column[3].x +=
            relocation.position[0] - @as(f32, @floatCast(original_position.x));
        center_of_mass_transform.column[3].y +=
            relocation.position[1] - @as(f32, @floatCast(original_position.y));
        center_of_mass_transform.column[3].z +=
            relocation.position[2] - @as(f32, @floatCast(original_position.z));
        var collide_settings: c.JPH_CollideShapeSettings = undefined;
        c.JPH_CollideShapeSettings_Init(&collide_settings);
        collide_settings.maxSeparationDistance = 0;
        var scale = toVec3(.{ 1, 1, 1 });
        var base_offset = toRVec3(.{ 0, 0, 0 });
        const shape = c.JPH_CharacterBase_GetShape(@ptrCast(character)) orelse
            return error.CharacterShapeInvariantBroken;
        const narrow_phase = c.JPH_PhysicsSystem_GetNarrowPhaseQuery(self.system) orelse
            return error.CharacterQueryInvariantBroken;
        var query = CharacterRelocationQuery{
            .body_interface = self.body_interface,
            .max_penetration_depth = relocation.max_penetration_depth,
        };
        _ = c.JPH_NarrowPhaseQuery_CollideShape(
            narrow_phase,
            shape,
            &scale,
            &center_of_mass_transform,
            &collide_settings,
            &base_offset,
            collectCharacterRelocationHit,
            &query,
            null,
            null,
            null,
            null,
        );
        if (query.blocked) return null;

        var committed = false;
        defer if (!committed) {
            c.JPH_CharacterVirtual_SetPosition(character, &original_position);
            c.JPH_CharacterVirtual_SetLinearVelocity(character, &original_velocity);
            c.JPH_CharacterVirtual_RefreshContacts(
                character,
                object_layers.moving,
                self.system,
                null,
                null,
            );
            if (c.JPH_CharacterVirtual_GetMaxHitsExceeded(character)) {
                @panic("character relocation rollback exceeded contact capacity");
            }
        };

        var position = toRVec3(relocation.position);
        var velocity = toVec3(relocation.velocity);
        c.JPH_CharacterVirtual_SetPosition(character, &position);
        c.JPH_CharacterVirtual_SetLinearVelocity(character, &velocity);
        c.JPH_CharacterVirtual_RefreshContacts(
            character,
            object_layers.moving,
            self.system,
            null,
            null,
        );
        try ensureCharacterContactCapacity(character);

        const state = try self.virtualCharacterState(character_id);
        committed = true;
        return state;
    }

    fn vehicleRecord(
        self: *Physics,
        vehicle_id: VehicleId,
    ) !VehicleHandleRecord {
        self.assertOwnerThread();
        if (self.world_token != vehicle_id.world_token) {
            return error.ForeignVehicleId;
        }
        const record = self.vehicle_handles.get(vehicle_id.serial) orelse
            return error.InvalidVehicleId;
        if (!c.JPH_BodyInterface_IsAdded(self.body_interface, record.body_id)) {
            return error.InvalidVehicleId;
        }
        return record;
    }

    fn createFourWheelVehicle(
        self: *Physics,
        desc: engine.physics.VehicleDesc,
        comptime failure_point: ?VehicleCreateFailurePoint,
    ) !VehicleId {
        self.assertOwnerThread();
        const normalized = try desc.normalized();
        if (self.next_vehicle_serial == 0) {
            return error.VehicleHandleSerialExhausted;
        }
        try self.vehicle_handles.ensureUnusedCapacity(1);

        var half_extents = toVec3(normalized.chassis_half_extents);
        const box = c.JPH_BoxShape_Create(
            &half_extents,
            c.JPH_DEFAULT_CONVEX_RADIUS,
        ) orelse return error.VehicleShapeCreationFailed;
        const box_shape: *c.JPH_Shape = @ptrCast(box);
        defer c.JPH_Shape_Destroy(box_shape);

        var center_of_mass_offset = toVec3(normalized.center_of_mass_offset);
        const offset_shape_raw = c.JPH_OffsetCenterOfMassShape_Create(
            &center_of_mass_offset,
            box_shape,
        ) orelse return error.VehicleShapeCreationFailed;
        const offset_shape: *c.JPH_Shape = @ptrCast(offset_shape_raw);
        defer c.JPH_Shape_Destroy(offset_shape);

        var position = toRVec3(normalized.chassis.pose.position);
        var rotation = toJoltQuat(normalized.chassis.pose.rotation);
        const body_settings = c.JPH_BodyCreationSettings_Create3(
            offset_shape,
            &position,
            &rotation,
            c.JPH_MotionType_Dynamic,
            object_layers.moving,
        ) orelse return error.VehicleBodySettingsCreationFailed;
        defer c.JPH_BodyCreationSettings_Destroy(body_settings);
        c.JPH_BodyCreationSettings_SetMaxLinearVelocity(
            body_settings,
            engine.physics.max_linear_velocity,
        );
        c.JPH_BodyCreationSettings_SetMaxAngularVelocity(
            body_settings,
            engine.physics.max_angular_velocity,
        );
        c.JPH_BodyCreationSettings_SetOverrideMassProperties(
            body_settings,
            c.JPH_OverrideMassProperties_CalculateInertia,
        );
        var mass_properties: c.JPH_MassProperties = undefined;
        c.JPH_BodyCreationSettings_GetMassPropertiesOverride(
            body_settings,
            &mass_properties,
        );
        mass_properties.mass = normalized.mass;
        c.JPH_BodyCreationSettings_SetMassPropertiesOverride(
            body_settings,
            &mass_properties,
        );

        const body = c.JPH_BodyInterface_CreateBody(
            self.body_interface,
            body_settings,
        ) orelse return error.VehicleBodyCreationFailed;
        const raw_body_id = c.JPH_Body_GetID(body);
        if (raw_body_id == invalid_body_id) {
            c.JPH_BodyInterface_DestroyBodyWithoutID(self.body_interface, body);
            return error.VehicleBodyCreationFailed;
        }
        var body_added = false;
        errdefer if (body_added) {
            c.JPH_BodyInterface_RemoveAndDestroyBody(self.body_interface, raw_body_id);
        } else {
            c.JPH_BodyInterface_DestroyBody(self.body_interface, raw_body_id);
        };
        c.JPH_BodyInterface_AddBody(
            self.body_interface,
            raw_body_id,
            c.JPH_Activation_Activate,
        );
        body_added = true;
        var linear_velocity = toVec3(normalized.chassis.velocity.linear);
        var angular_velocity = toVec3(normalized.chassis.velocity.angular);
        c.JPH_BodyInterface_SetLinearAndAngularVelocity(
            self.body_interface,
            raw_body_id,
            &linear_velocity,
            &angular_velocity,
        );
        if (failure_point != null) {
            try injectVehicleCreateFailure(failure_point, .after_body);
        }

        var wheel_settings: [engine.physics.vehicle_wheel_count]*c.JPH_WheelSettings = undefined;
        var wheel_settings_count: usize = 0;
        defer {
            for (wheel_settings[0..wheel_settings_count]) |settings| {
                c.JPH_WheelSettings_Destroy(settings);
            }
        }
        const suspension_direction = toVec3(.{ 0, -1, 0 });
        const steering_axis = toVec3(.{ 0, 1, 0 });
        const wheel_up = toVec3(.{ 0, 1, 0 });
        const vehicle_forward = toVec3(.{ 0, 0, -1 });
        for (normalized.wheel_attachment_positions, 0..) |attachment, index| {
            const settings_wv = c.JPH_WheelSettingsWV_Create() orelse
                return error.VehicleWheelSettingsCreationFailed;
            const settings: *c.JPH_WheelSettings = @ptrCast(settings_wv);
            wheel_settings[index] = settings;
            wheel_settings_count += 1;

            var attachment_value = toVec3(attachment);
            c.JPH_WheelSettings_SetPosition(settings, &attachment_value);
            c.JPH_WheelSettings_SetSuspensionDirection(settings, &suspension_direction);
            c.JPH_WheelSettings_SetSteeringAxis(settings, &steering_axis);
            c.JPH_WheelSettings_SetWheelUp(settings, &wheel_up);
            c.JPH_WheelSettings_SetWheelForward(settings, &vehicle_forward);
            c.JPH_WheelSettings_SetSuspensionMinLength(
                settings,
                normalized.suspension_min_length,
            );
            c.JPH_WheelSettings_SetSuspensionMaxLength(
                settings,
                normalized.suspension_max_length,
            );
            var spring: c.JPH_SpringSettings = undefined;
            c.JPH_WheelSettings_GetSuspensionSpring(settings, &spring);
            spring.mode = c.JPH_SpringMode_FrequencyAndDamping;
            spring.frequencyOrStiffness = normalized.suspension_frequency;
            spring.damping = normalized.suspension_damping;
            c.JPH_WheelSettings_SetSuspensionSpring(settings, &spring);
            c.JPH_WheelSettings_SetRadius(settings, normalized.wheel_radius);
            c.JPH_WheelSettings_SetWidth(settings, normalized.wheel_width);
            c.JPH_WheelSettingsWV_SetMaxSteerAngle(
                settings_wv,
                if (index < 2) normalized.max_steer_radians else 0,
            );
            c.JPH_WheelSettingsWV_SetMaxBrakeTorque(
                settings_wv,
                normalized.max_brake_torque,
            );
            c.JPH_WheelSettingsWV_SetMaxHandBrakeTorque(
                settings_wv,
                if (index < 2) 0 else normalized.max_hand_brake_torque,
            );
        }

        const controller_settings =
            c.JPH_WheeledVehicleControllerSettings_Create() orelse
            return error.VehicleControllerSettingsCreationFailed;
        defer c.JPH_VehicleControllerSettings_Destroy(@ptrCast(controller_settings));

        // Do not use pinned JoltC's AddDifferential helper: it leaves
        // leftRightSplit uninitialized. Populate every field from upstream
        // defaults and install the differential through SetDifferentials.
        var differential: c.JPH_VehicleDifferentialSettings = undefined;
        c.JPH_VehicleDifferentialSettings_Init(&differential);
        differential.leftWheel = @intFromEnum(engine.physics.VehicleWheelIndex.front_left);
        differential.rightWheel = @intFromEnum(engine.physics.VehicleWheelIndex.front_right);
        differential.differentialRatio = normalized.front_differential_ratio;
        differential.leftRightSplit = 0.5;
        differential.limitedSlipRatio = normalized.front_limited_slip_ratio;
        differential.engineTorqueRatio = 1.0;
        c.JPH_WheeledVehicleControllerSettings_SetDifferentials(
            controller_settings,
            &differential,
            1,
        );

        var vehicle_settings: c.JPH_VehicleConstraintSettings = undefined;
        c.JPH_VehicleConstraintSettings_Init(&vehicle_settings);
        vehicle_settings.up = toVec3(.{ 0, 1, 0 });
        vehicle_settings.forward = vehicle_forward;
        vehicle_settings.maxPitchRollAngle = normalized.max_pitch_roll_radians;
        vehicle_settings.wheelsCount = engine.physics.vehicle_wheel_count;
        vehicle_settings.wheels = @ptrCast(&wheel_settings);
        vehicle_settings.controller = @ptrCast(controller_settings);
        if (failure_point != null) {
            try injectVehicleCreateFailure(failure_point, .after_settings);
        }

        const constraint = c.JPH_VehicleConstraint_Create(
            body,
            &vehicle_settings,
        ) orelse return error.VehicleConstraintCreationFailed;
        var constraint_added = false;
        var listener_added = false;
        errdefer {
            if (listener_added) {
                c.JPH_PhysicsSystem_RemoveStepListener(
                    self.system,
                    c.JPH_VehicleConstraint_AsPhysicsStepListener(constraint),
                );
            }
            if (constraint_added) {
                c.JPH_PhysicsSystem_RemoveConstraint(self.system, @ptrCast(constraint));
            }
            c.JPH_Constraint_Destroy(@ptrCast(constraint));
        }
        for (normalized.initial_wheel_dynamics, 0..) |dynamics, index| {
            const wheel = c.JPH_VehicleConstraint_GetWheel(
                constraint,
                @intCast(index),
            ) orelse return error.VehicleWheelInvariantBroken;
            c.JPH_Wheel_SetRotationAngle(wheel, dynamics.rotation_angle);
            c.JPH_Wheel_SetAngularVelocity(wheel, dynamics.angular_velocity);
        }
        if (failure_point != null) {
            try injectVehicleCreateFailure(failure_point, .after_constraint);
        }

        var world_up = toVec3(.{ 0, 1, 0 });
        const tester_raw = c.JPH_VehicleCollisionTesterCastSphere_Create(
            object_layers.moving,
            normalized.wheel_width * 0.5,
            &world_up,
            normalized.wheel_collision_max_slope_radians,
        ) orelse return error.VehicleCollisionTesterCreationFailed;
        const tester: *c.JPH_VehicleCollisionTester = @ptrCast(tester_raw);
        defer c.JPH_VehicleCollisionTester_Destroy(tester);
        c.JPH_VehicleConstraint_SetVehicleCollisionTester(constraint, tester);
        if (failure_point != null) {
            try injectVehicleCreateFailure(failure_point, .after_collision_tester);
        }

        c.JPH_PhysicsSystem_AddConstraint(self.system, @ptrCast(constraint));
        constraint_added = true;
        c.JPH_PhysicsSystem_AddStepListener(
            self.system,
            c.JPH_VehicleConstraint_AsPhysicsStepListener(constraint),
        );
        listener_added = true;
        if (failure_point != null) {
            try injectVehicleCreateFailure(failure_point, .after_registration);
        }

        const serial = self.next_vehicle_serial;
        self.vehicle_handles.putAssumeCapacityNoClobber(serial, .{
            .body_id = raw_body_id,
            .constraint = constraint,
            .chassis_half_extents = normalized.chassis_half_extents,
            .center_of_mass_offset = normalized.center_of_mass_offset,
            .wheel_attachment_positions = normalized.wheel_attachment_positions,
            .wheel_radius = normalized.wheel_radius,
            .wheel_width = normalized.wheel_width,
        });
        self.next_vehicle_serial +%= 1;
        return .{ .world_token = self.world_token, .serial = serial };
    }

    fn destroyFourWheelVehicle(self: *Physics, vehicle_id: VehicleId) !void {
        const record = try self.vehicleRecord(vehicle_id);
        c.JPH_PhysicsSystem_RemoveStepListener(
            self.system,
            c.JPH_VehicleConstraint_AsPhysicsStepListener(record.constraint),
        );
        c.JPH_PhysicsSystem_RemoveConstraint(self.system, @ptrCast(record.constraint));
        c.JPH_Constraint_Destroy(@ptrCast(record.constraint));
        c.JPH_BodyInterface_RemoveAndDestroyBody(self.body_interface, record.body_id);
        if (!self.vehicle_handles.remove(vehicle_id.serial)) {
            @panic("vehicle handle index removal invariant failed");
        }
    }

    fn setFourWheelVehicleInput(
        self: *Physics,
        vehicle_id: VehicleId,
        input: engine.physics.VehicleInput,
    ) !void {
        try input.validate();
        const record = try self.vehicleRecord(vehicle_id);
        const controller_base = c.JPH_VehicleConstraint_GetController(record.constraint) orelse
            return error.VehicleControllerInvariantBroken;
        const controller: *c.JPH_WheeledVehicleController = @ptrCast(controller_base);
        c.JPH_WheeledVehicleController_SetDriverInput(
            controller,
            input.throttle,
            input.steering,
            input.brake,
            input.hand_brake,
        );
        if (!input.isNeutral()) {
            c.JPH_BodyInterface_ActivateBody(self.body_interface, record.body_id);
        }
    }

    fn fourWheelVehicleState(
        self: *Physics,
        vehicle_id: VehicleId,
    ) !engine.physics.VehicleState {
        const record = try self.vehicleRecord(vehicle_id);
        const wheel_count = c.JPH_VehicleConstraint_GetWheelsCount(record.constraint);
        if (wheel_count != engine.physics.vehicle_wheel_count) {
            return error.VehicleWheelCountInvariantBroken;
        }

        var chassis_position: c.JPH_RVec3 = undefined;
        var chassis_rotation: c.JPH_Quat = undefined;
        var linear_velocity: c.JPH_Vec3 = undefined;
        var angular_velocity: c.JPH_Vec3 = undefined;
        c.JPH_BodyInterface_GetPosition(
            self.body_interface,
            record.body_id,
            &chassis_position,
        );
        c.JPH_BodyInterface_GetRotation(
            self.body_interface,
            record.body_id,
            &chassis_rotation,
        );
        c.JPH_BodyInterface_GetLinearAndAngularVelocity(
            self.body_interface,
            record.body_id,
            &linear_velocity,
            &angular_velocity,
        );

        const canonical_wheel_right = toVec3(.{ 1, 0, 0 });
        const canonical_wheel_up = toVec3(.{ 0, 1, 0 });
        var wheels: [engine.physics.vehicle_wheel_count]engine.physics.WheelState = undefined;
        for (&wheels, 0..) |*result, index| {
            const wheel = c.JPH_VehicleConstraint_GetWheel(
                record.constraint,
                @intCast(index),
            ) orelse return error.VehicleWheelInvariantBroken;
            var world_transform: c.JPH_RMat4 = undefined;
            c.JPH_VehicleConstraint_GetWheelWorldTransform(
                record.constraint,
                @intCast(index),
                &canonical_wheel_right,
                &canonical_wheel_up,
                &world_transform,
            );
            result.* = .{
                .pose = try poseFromJoltMatrix(world_transform),
                .angular_velocity = c.JPH_Wheel_GetAngularVelocity(wheel),
                .rotation_angle = try engine.physics.canonicalVehicleWheelRotation(
                    c.JPH_Wheel_GetRotationAngle(wheel),
                ),
                // Jolt's positive wheel angle turns left for this -Z-forward
                // setup; expose the engine's positive-right convention.
                .steer_angle = -c.JPH_Wheel_GetSteerAngle(wheel),
                .suspension_length = c.JPH_Wheel_GetSuspensionLength(wheel),
                .has_contact = c.JPH_Wheel_HasContact(wheel),
            };
        }

        const controller_base = c.JPH_VehicleConstraint_GetController(record.constraint) orelse
            return error.VehicleControllerInvariantBroken;
        const controller: *c.JPH_WheeledVehicleController = @ptrCast(controller_base);
        const vehicle_engine = c.JPH_WheeledVehicleController_GetEngine(controller) orelse
            return error.VehicleControllerInvariantBroken;
        const transmission = c.JPH_WheeledVehicleController_GetTransmission(controller) orelse
            return error.VehicleControllerInvariantBroken;
        const state = engine.physics.VehicleState{
            .chassis = .{
                .pose = .{
                    .position = fromRVec3(chassis_position),
                    .rotation = fromJoltQuat(chassis_rotation),
                },
                .velocity = .{
                    .linear = fromVec3(linear_velocity),
                    .angular = fromVec3(angular_velocity),
                },
            },
            .wheels = wheels,
            .engine_rpm = c.JPH_VehicleEngine_GetCurrentRPM(vehicle_engine),
            .current_gear = @intCast(c.JPH_VehicleTransmission_GetCurrentGear(transmission)),
        };
        try state.validate();
        return state;
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

        return try self.createBody(
            shape,
            position,
            motion_type,
            .{ .box = half_extents },
        );
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

        return try self.createBody(
            shape,
            position,
            .dynamic,
            .{ .sphere = radius },
        );
    }

    fn createBody(
        self: *Physics,
        shape: *const c.JPH_Shape,
        position: [3]f32,
        motion_type: MotionType,
        debug_shape: BodyShapeDescriptor,
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
        c.JPH_BodyCreationSettings_SetMaxLinearVelocity(
            settings,
            engine.physics.max_linear_velocity,
        );
        c.JPH_BodyCreationSettings_SetMaxAngularVelocity(
            settings,
            engine.physics.max_angular_velocity,
        );

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
        try self.body_handles.put(serial, .{
            .raw_id = @intCast(raw_id),
            .shape = debug_shape,
        });

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
        const record = self.body_handles.getPtr(body_id.serial) orelse unreachable;
        record.shape = .{ .box = half_extents };
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
        const record = self.body_handles.get(body_id.serial) orelse return false;
        if (record.raw_id != body_id.value) return false;
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
        try (engine.physics.Velocity{ .linear = velocity }).validate();
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
        try (engine.physics.Velocity{ .angular = velocity }).validate();
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
        const record = self.body_handles.get(body_id.serial) orelse return false;
        if (record.raw_id != body_id.value) return false;
        if (!c.JPH_BodyInterface_IsAdded(self.body_interface, body_id.toJolt())) return false;
        c.JPH_BodyInterface_RemoveAndDestroyBody(self.body_interface, body_id.toJolt());
        if (!self.body_handles.remove(body_id.serial)) {
            @panic("physics body handle index removal invariant failed");
        }
        return true;
    }

    /// Extract one immutable renderer-neutral batch after a completed world
    /// update. This method performs only bounded reads from stopped Jolt state
    /// and writes to caller-owned storage; it allocates nothing and does not
    /// change body, controller, vehicle, listener, or solver state.
    pub fn extractDebug(
        self: *Physics,
        config: DebugConfig,
        completed_tick: u64,
        storage: *physics_debug.Storage,
    ) physics_debug.Batch {
        return self.extractDebugWithStatus(config, completed_tick, storage).batch;
    }

    /// Extract debug geometry together with the precise availability of the
    /// optional rigid-body contact producer. The batch also carries a neutral
    /// per-category `source_unavailable` marker so consumers that only retain
    /// `Batch` still observe degraded contact evidence.
    pub fn extractDebugWithStatus(
        self: *Physics,
        config: DebugConfig,
        completed_tick: u64,
        storage: *physics_debug.Storage,
    ) DebugExtraction {
        self.assertOwnerThread();
        if (self.update_in_progress or !self.has_completed_update) {
            @panic("physics debug extraction requires a completed stopped update");
        }

        const contact_availability = self.rigidContactCaptureAvailability();
        storage.begin(completed_tick);
        if (!config.enabled()) return .{
            .batch = storage.batch().?,
            .rigid_contact_capture = contact_availability,
        };

        var bodies = self.body_handles.iterator();
        while (bodies.next()) |entry| {
            const record = entry.value_ptr.*;
            self.emitRigidBodyDebug(
                record.raw_id,
                record.shape,
                .{ .kind = debug_object_kinds.body, .serial = entry.key_ptr.* },
                config,
                storage,
            );
        }

        var characters = self.character_handles.iterator();
        while (characters.next()) |entry| {
            self.emitCharacterDebug(
                entry.value_ptr.*,
                .{ .kind = debug_object_kinds.character, .serial = entry.key_ptr.* },
                config,
                storage,
            );
        }

        var vehicle_iterator = self.vehicle_handles.iterator();
        while (vehicle_iterator.next()) |entry| {
            const object = physics_debug.ObjectRef{
                .kind = debug_object_kinds.vehicle,
                .serial = entry.key_ptr.*,
            };
            const record = entry.value_ptr.*;
            self.emitRigidBodyDebug(
                @intCast(record.body_id),
                .{ .box = record.chassis_half_extents },
                object,
                config,
                storage,
            );
            self.emitVehicleWheelsDebug(record, object, config, storage);
        }

        if (config.contacts) switch (self.contact_debug_capture) {
            .available => |resources| {
                var unpublished: u64 = 0;
                for (resources.scratch.contacts[0..resources.scratch.count()]) |*slot| {
                    if (!slot.published.load(.acquire)) {
                        unpublished += 1;
                        continue;
                    }
                    const contact = slot.contact;
                    emitContact(
                        storage,
                        contact.point,
                        contact.normal,
                        self.objectForRawBody(contact.body_a) orelse
                            self.objectForRawBody(contact.body_b),
                    );
                }
                _ = storage.recordOverflow(
                    .contact,
                    .line,
                    4 * (@as(u64, resources.scratch.dropped.load(.acquire)) + unpublished),
                );
            },
            else => {
                _ = storage.markSourceUnavailable(.contact);
            },
        };

        return .{
            .batch = storage.batch().?,
            .rigid_contact_capture = contact_availability,
        };
    }

    /// Query optional rigid-contact evidence without allocating or mutating
    /// either debug or authoritative physics state.
    pub fn rigidContactCaptureAvailability(
        self: *const Physics,
    ) RigidContactCaptureAvailability {
        self.assertOwnerThread();
        return self.contact_debug_capture.availability();
    }

    fn objectForRawBody(
        self: *Physics,
        raw_id: u32,
    ) ?physics_debug.ObjectRef {
        var bodies = self.body_handles.iterator();
        while (bodies.next()) |entry| {
            if (entry.value_ptr.raw_id == raw_id) {
                return .{
                    .kind = debug_object_kinds.body,
                    .serial = entry.key_ptr.*,
                };
            }
        }
        var vehicle_iterator = self.vehicle_handles.iterator();
        while (vehicle_iterator.next()) |entry| {
            if (entry.value_ptr.body_id == raw_id) {
                return .{
                    .kind = debug_object_kinds.vehicle,
                    .serial = entry.key_ptr.*,
                };
            }
        }
        return null;
    }

    fn emitRigidBodyDebug(
        self: *Physics,
        raw_id: u32,
        shape: BodyShapeDescriptor,
        object: physics_debug.ObjectRef,
        config: DebugConfig,
        storage: *physics_debug.Storage,
    ) void {
        const body_id: c.JPH_BodyID = @intCast(raw_id);
        var position: c.JPH_RVec3 = undefined;
        var rotation: c.JPH_Quat = undefined;
        c.JPH_BodyInterface_GetPosition(self.body_interface, body_id, &position);
        c.JPH_BodyInterface_GetRotation(self.body_interface, body_id, &rotation);
        const world_position = fromRVec3(position);
        const world_rotation = fromJoltQuat(rotation);

        if (config.shapes) {
            switch (shape) {
                .box => |half_extents| emitBox(
                    storage,
                    world_position,
                    world_rotation,
                    half_extents,
                    object,
                ),
                .sphere => |radius| emitSphere(
                    storage,
                    world_position,
                    radius,
                    object,
                ),
            }
        }

        const body = c.JPH_PhysicsSystem_GetBodyPtr(self.system, body_id) orelse return;
        var center_of_mass: c.JPH_RVec3 = undefined;
        c.JPH_Body_GetCenterOfMassPosition(body, &center_of_mass);
        const com = fromRVec3(center_of_mass);

        if (config.bounds) {
            var bounds: c.JPH_AABox = undefined;
            c.JPH_Body_GetWorldSpaceBounds(body, &bounds);
            emitBounds(storage, fromVec3(bounds.min), fromVec3(bounds.max), object);
        }
        if (config.centers_of_mass) emitCenterOfMass(storage, com, object);
        if (config.velocities) {
            var velocity: c.JPH_Vec3 = undefined;
            c.JPH_BodyInterface_GetLinearVelocity(self.body_interface, body_id, &velocity);
            emitVelocity(storage, com, fromVec3(velocity), object);
        }
    }

    fn emitCharacterDebug(
        self: *Physics,
        record: CharacterHandleRecord,
        object: physics_debug.ObjectRef,
        config: DebugConfig,
        storage: *physics_debug.Storage,
    ) void {
        _ = self;
        var center_of_mass_transform: c.JPH_RMat4 = undefined;
        c.JPH_CharacterVirtual_GetCenterOfMassTransform(
            record.character,
            &center_of_mass_transform,
        );

        if (config.shapes) {
            emitCapsule(
                storage,
                center_of_mass_transform,
                record.radius,
                record.half_height,
                object,
            );
        }
        if (config.bounds) {
            const shape = c.JPH_CharacterBase_GetShape(@ptrCast(record.character)) orelse
                unreachable;
            var scale = toVec3(.{ 1, 1, 1 });
            var bounds: c.JPH_AABox = undefined;
            c.JPH_Shape_GetWorldSpaceBounds(
                shape,
                &center_of_mass_transform,
                &scale,
                &bounds,
            );
            emitBounds(storage, fromVec3(bounds.min), fromVec3(bounds.max), object);
        }
        const center = [3]f32{
            center_of_mass_transform.column[3].x,
            center_of_mass_transform.column[3].y,
            center_of_mass_transform.column[3].z,
        };
        if (config.centers_of_mass) emitCenterOfMass(storage, center, object);
        if (config.velocities) {
            var velocity: c.JPH_Vec3 = undefined;
            c.JPH_CharacterVirtual_GetLinearVelocity(record.character, &velocity);
            emitVelocity(storage, center, fromVec3(velocity), object);
        }
        if (config.contacts) {
            const count = c.JPH_CharacterVirtual_GetNumActiveContacts(record.character);
            for (0..count) |index| {
                var contact: c.JPH_CharacterVirtualContact = undefined;
                c.JPH_CharacterVirtual_GetActiveContact(
                    record.character,
                    @intCast(index),
                    &contact,
                );
                if (contact.wasDiscarded) continue;
                emitContact(
                    storage,
                    fromRVec3(contact.position),
                    fromVec3(contact.contactNormal),
                    object,
                );
            }
        }
    }

    fn emitVehicleWheelsDebug(
        self: *Physics,
        record: VehicleHandleRecord,
        object: physics_debug.ObjectRef,
        config: DebugConfig,
        storage: *physics_debug.Storage,
    ) void {
        _ = self;
        const wheel_right = toVec3(.{ 1, 0, 0 });
        const wheel_up = toVec3(.{ 0, 1, 0 });
        for (0..engine.physics.vehicle_wheel_count) |index| {
            const wheel = c.JPH_VehicleConstraint_GetWheel(
                record.constraint,
                @intCast(index),
            ) orelse continue;
            if (config.shapes) {
                var transform: c.JPH_RMat4 = undefined;
                c.JPH_VehicleConstraint_GetWheelWorldTransform(
                    record.constraint,
                    @intCast(index),
                    &wheel_right,
                    &wheel_up,
                    &transform,
                );
                emitWheel(
                    storage,
                    transform,
                    record.wheel_radius,
                    record.wheel_width,
                    object,
                );
            }
            if (config.contacts and c.JPH_Wheel_HasContact(wheel)) {
                var point: c.JPH_RVec3 = undefined;
                var normal: c.JPH_Vec3 = undefined;
                c.JPH_Wheel_GetContactPosition(wheel, &point);
                c.JPH_Wheel_GetContactNormal(wheel, &normal);
                emitContact(storage, fromRVec3(point), fromVec3(normal), object);
            }
        }
    }

    pub fn update(self: *Physics, delta_time: f32) StepError!void {
        self.assertOwnerThread();
        if (!std.math.isFinite(delta_time) or delta_time <= 0) {
            return error.InvalidDeltaTime;
        }
        if (self.update_in_progress) @panic("nested Physics update");
        self.update_in_progress = true;
        defer {
            self.update_in_progress = false;
            self.has_completed_update = true;
        }
        self.contact_debug_capture.reset();
        const result = c.JPH_PhysicsSystem_Update2(
            self.system,
            delta_time,
            1,
            self.temp_allocator,
            self.job_system,
        );
        return checkPhysicsUpdateResult(result);
    }
};

const shape_line_color: physics_debug.Color = .{ 0.15, 0.85, 1.0, 1.0 };
const shape_fill_color: physics_debug.Color = .{ 0.1, 0.45, 0.8, 1.0 };
const bounds_color: physics_debug.Color = .{ 1.0, 0.75, 0.1, 1.0 };
const contact_color: physics_debug.Color = .{ 1.0, 0.2, 0.2, 1.0 };
const center_of_mass_color: physics_debug.Color = .{ 1.0, 0.2, 1.0, 1.0 };
const velocity_color: physics_debug.Color = .{ 0.2, 1.0, 0.25, 1.0 };

fn add3(a: [3]f32, b: [3]f32) [3]f32 {
    return .{ a[0] + b[0], a[1] + b[1], a[2] + b[2] };
}

fn sub3(a: [3]f32, b: [3]f32) [3]f32 {
    return .{ a[0] - b[0], a[1] - b[1], a[2] - b[2] };
}

fn scale3(value: [3]f32, scalar: f32) [3]f32 {
    return .{ value[0] * scalar, value[1] * scalar, value[2] * scalar };
}

fn cross3(a: [3]f32, b: [3]f32) [3]f32 {
    return .{
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    };
}

fn rotate3(rotation: [4]f32, value: [3]f32) [3]f32 {
    const q = [3]f32{ rotation[0], rotation[1], rotation[2] };
    const twice_cross = scale3(cross3(q, value), 2);
    return add3(
        value,
        add3(
            scale3(twice_cross, rotation[3]),
            cross3(q, twice_cross),
        ),
    );
}

fn transformedPoint(
    position: [3]f32,
    rotation: [4]f32,
    local: [3]f32,
) [3]f32 {
    return add3(position, rotate3(rotation, local));
}

fn addDebugLine(
    storage: *physics_debug.Storage,
    category: physics_debug.Category,
    start: [3]f32,
    end: [3]f32,
    color: physics_debug.Color,
    object: ?physics_debug.ObjectRef,
) void {
    _ = storage.addLine(.{
        .category = category,
        .start = start,
        .end = end,
        .color = color,
        .object = object,
    });
}

fn addDebugTriangle(
    storage: *physics_debug.Storage,
    category: physics_debug.Category,
    a: [3]f32,
    b: [3]f32,
    triangle_c: [3]f32,
    color: physics_debug.Color,
    object: ?physics_debug.ObjectRef,
) void {
    _ = storage.addTriangle(.{
        .category = category,
        .a = a,
        .b = b,
        .c = triangle_c,
        .color = color,
        .object = object,
    });
}

const box_edges = [_][2]usize{
    .{ 0, 1 }, .{ 1, 3 }, .{ 3, 2 }, .{ 2, 0 },
    .{ 4, 5 }, .{ 5, 7 }, .{ 7, 6 }, .{ 6, 4 },
    .{ 0, 4 }, .{ 1, 5 }, .{ 2, 6 }, .{ 3, 7 },
};

const box_triangles = [_][3]usize{
    .{ 0, 2, 1 }, .{ 1, 2, 3 },
    .{ 4, 5, 6 }, .{ 5, 7, 6 },
    .{ 0, 1, 4 }, .{ 1, 5, 4 },
    .{ 2, 6, 3 }, .{ 3, 6, 7 },
    .{ 0, 4, 2 }, .{ 2, 4, 6 },
    .{ 1, 3, 5 }, .{ 3, 7, 5 },
};

fn localBoxCorners(half_extents: [3]f32) [8][3]f32 {
    return .{
        .{ -half_extents[0], -half_extents[1], -half_extents[2] },
        .{ half_extents[0], -half_extents[1], -half_extents[2] },
        .{ -half_extents[0], half_extents[1], -half_extents[2] },
        .{ half_extents[0], half_extents[1], -half_extents[2] },
        .{ -half_extents[0], -half_extents[1], half_extents[2] },
        .{ half_extents[0], -half_extents[1], half_extents[2] },
        .{ -half_extents[0], half_extents[1], half_extents[2] },
        .{ half_extents[0], half_extents[1], half_extents[2] },
    };
}

fn emitBox(
    storage: *physics_debug.Storage,
    position: [3]f32,
    rotation: [4]f32,
    half_extents: [3]f32,
    object: physics_debug.ObjectRef,
) void {
    const local = localBoxCorners(half_extents);
    var world: [8][3]f32 = undefined;
    for (local, 0..) |corner, index| {
        world[index] = transformedPoint(position, rotation, corner);
    }
    for (box_edges) |edge| {
        addDebugLine(
            storage,
            .shape,
            world[edge[0]],
            world[edge[1]],
            shape_line_color,
            object,
        );
    }
    for (box_triangles) |triangle| {
        addDebugTriangle(
            storage,
            .shape,
            world[triangle[0]],
            world[triangle[1]],
            world[triangle[2]],
            shape_fill_color,
            object,
        );
    }
}

fn emitSphere(
    storage: *physics_debug.Storage,
    center: [3]f32,
    radius: f32,
    object: physics_debug.ObjectRef,
) void {
    const segment_count: usize = 16;
    for (0..3) |plane| {
        for (0..segment_count) |index| {
            const first_angle = std.math.tau * @as(f32, @floatFromInt(index)) /
                @as(f32, @floatFromInt(segment_count));
            const second_angle = std.math.tau * @as(f32, @floatFromInt(index + 1)) /
                @as(f32, @floatFromInt(segment_count));
            const first_circle = [2]f32{ @cos(first_angle) * radius, @sin(first_angle) * radius };
            const second_circle = [2]f32{ @cos(second_angle) * radius, @sin(second_angle) * radius };
            const first = switch (plane) {
                0 => add3(center, .{ first_circle[0], first_circle[1], 0 }),
                1 => add3(center, .{ first_circle[0], 0, first_circle[1] }),
                else => add3(center, .{ 0, first_circle[0], first_circle[1] }),
            };
            const second = switch (plane) {
                0 => add3(center, .{ second_circle[0], second_circle[1], 0 }),
                1 => add3(center, .{ second_circle[0], 0, second_circle[1] }),
                else => add3(center, .{ 0, second_circle[0], second_circle[1] }),
            };
            addDebugLine(storage, .shape, first, second, shape_line_color, object);
        }
    }

    const points = [_][3]f32{
        add3(center, .{ radius, 0, 0 }),
        add3(center, .{ -radius, 0, 0 }),
        add3(center, .{ 0, radius, 0 }),
        add3(center, .{ 0, -radius, 0 }),
        add3(center, .{ 0, 0, radius }),
        add3(center, .{ 0, 0, -radius }),
    };
    const triangles = [_][3]usize{
        .{ 0, 2, 4 }, .{ 4, 2, 1 }, .{ 1, 2, 5 }, .{ 5, 2, 0 },
        .{ 4, 3, 0 }, .{ 1, 3, 4 }, .{ 5, 3, 1 }, .{ 0, 3, 5 },
    };
    for (triangles) |triangle| {
        addDebugTriangle(
            storage,
            .shape,
            points[triangle[0]],
            points[triangle[1]],
            points[triangle[2]],
            shape_fill_color,
            object,
        );
    }
}

fn emitCapsule(
    storage: *physics_debug.Storage,
    transform: c.JPH_RMat4,
    radius: f32,
    half_height: f32,
    object: physics_debug.ObjectRef,
) void {
    const segment_count: usize = 16;
    const bottom_y = -half_height;
    const top_y = half_height;
    for (0..segment_count) |index| {
        const first_angle = std.math.tau * @as(f32, @floatFromInt(index)) /
            @as(f32, @floatFromInt(segment_count));
        const second_angle = std.math.tau * @as(f32, @floatFromInt(index + 1)) /
            @as(f32, @floatFromInt(segment_count));
        const first_direction = [3]f32{ @cos(first_angle) * radius, 0, @sin(first_angle) * radius };
        const second_direction = [3]f32{ @cos(second_angle) * radius, 0, @sin(second_angle) * radius };
        addDebugLine(
            storage,
            .shape,
            transformMatrixPoint(transform, add3(first_direction, .{ 0, bottom_y, 0 })),
            transformMatrixPoint(transform, add3(second_direction, .{ 0, bottom_y, 0 })),
            shape_line_color,
            object,
        );
        addDebugLine(
            storage,
            .shape,
            transformMatrixPoint(transform, add3(first_direction, .{ 0, top_y, 0 })),
            transformMatrixPoint(transform, add3(second_direction, .{ 0, top_y, 0 })),
            shape_line_color,
            object,
        );
        if (index % 4 == 0) {
            addDebugLine(
                storage,
                .shape,
                transformMatrixPoint(transform, add3(first_direction, .{ 0, bottom_y, 0 })),
                transformMatrixPoint(transform, add3(first_direction, .{ 0, top_y, 0 })),
                shape_line_color,
                object,
            );
        }
    }

    const arc_segments: usize = 8;
    const directions = [_][3]f32{ .{ 1, 0, 0 }, .{ -1, 0, 0 }, .{ 0, 0, 1 }, .{ 0, 0, -1 } };
    for (directions) |direction| {
        for (0..arc_segments) |index| {
            const first_fraction = @as(f32, @floatFromInt(index)) /
                @as(f32, @floatFromInt(arc_segments));
            const second_fraction = @as(f32, @floatFromInt(index + 1)) /
                @as(f32, @floatFromInt(arc_segments));
            const first_angle = first_fraction * (std.math.pi / 2.0);
            const second_angle = second_fraction * (std.math.pi / 2.0);
            const first_radial = scale3(direction, @cos(first_angle) * radius);
            const second_radial = scale3(direction, @cos(second_angle) * radius);
            addDebugLine(
                storage,
                .shape,
                transformMatrixPoint(transform, add3(first_radial, .{ 0, bottom_y - @sin(first_angle) * radius, 0 })),
                transformMatrixPoint(transform, add3(second_radial, .{ 0, bottom_y - @sin(second_angle) * radius, 0 })),
                shape_line_color,
                object,
            );
            addDebugLine(
                storage,
                .shape,
                transformMatrixPoint(transform, add3(first_radial, .{ 0, top_y + @sin(first_angle) * radius, 0 })),
                transformMatrixPoint(transform, add3(second_radial, .{ 0, top_y + @sin(second_angle) * radius, 0 })),
                shape_line_color,
                object,
            );
        }
    }
}

fn transformMatrixPoint(matrix: c.JPH_RMat4, local: [3]f32) [3]f32 {
    return .{
        matrix.column[3].x + matrix.column[0].x * local[0] + matrix.column[1].x * local[1] + matrix.column[2].x * local[2],
        matrix.column[3].y + matrix.column[0].y * local[0] + matrix.column[1].y * local[1] + matrix.column[2].y * local[2],
        matrix.column[3].z + matrix.column[0].z * local[0] + matrix.column[1].z * local[1] + matrix.column[2].z * local[2],
    };
}

fn emitWheel(
    storage: *physics_debug.Storage,
    transform: c.JPH_RMat4,
    radius: f32,
    width: f32,
    object: physics_debug.ObjectRef,
) void {
    const segment_count: usize = 16;
    for (0..segment_count) |index| {
        const first_angle = std.math.tau * @as(f32, @floatFromInt(index)) /
            @as(f32, @floatFromInt(segment_count));
        const second_angle = std.math.tau * @as(f32, @floatFromInt(index + 1)) /
            @as(f32, @floatFromInt(segment_count));
        for ([_]f32{ -width * 0.5, width * 0.5 }) |side| {
            addDebugLine(
                storage,
                .shape,
                transformMatrixPoint(transform, .{ side, @cos(first_angle) * radius, @sin(first_angle) * radius }),
                transformMatrixPoint(transform, .{ side, @cos(second_angle) * radius, @sin(second_angle) * radius }),
                shape_line_color,
                object,
            );
        }
        if (index % 4 == 0) {
            addDebugLine(
                storage,
                .shape,
                transformMatrixPoint(transform, .{ -width * 0.5, @cos(first_angle) * radius, @sin(first_angle) * radius }),
                transformMatrixPoint(transform, .{ width * 0.5, @cos(first_angle) * radius, @sin(first_angle) * radius }),
                shape_line_color,
                object,
            );
        }
    }
}

fn emitBounds(
    storage: *physics_debug.Storage,
    minimum: [3]f32,
    maximum: [3]f32,
    object: physics_debug.ObjectRef,
) void {
    const center = scale3(add3(minimum, maximum), 0.5);
    const half_extents = scale3(sub3(maximum, minimum), 0.5);
    const local = localBoxCorners(half_extents);
    var world: [8][3]f32 = undefined;
    for (local, 0..) |corner, index| world[index] = add3(center, corner);
    for (box_edges) |edge| {
        addDebugLine(
            storage,
            .bounds,
            world[edge[0]],
            world[edge[1]],
            bounds_color,
            object,
        );
    }
}

fn emitCenterOfMass(
    storage: *physics_debug.Storage,
    center: [3]f32,
    object: physics_debug.ObjectRef,
) void {
    const radius: f32 = 0.12;
    for ([_][3]f32{ .{ radius, 0, 0 }, .{ 0, radius, 0 }, .{ 0, 0, radius } }) |axis| {
        addDebugLine(
            storage,
            .center_of_mass,
            sub3(center, axis),
            add3(center, axis),
            center_of_mass_color,
            object,
        );
    }
}

fn emitVelocity(
    storage: *physics_debug.Storage,
    origin: [3]f32,
    velocity: [3]f32,
    object: physics_debug.ObjectRef,
) void {
    addDebugLine(
        storage,
        .velocity,
        origin,
        add3(origin, scale3(velocity, 0.1)),
        velocity_color,
        object,
    );
}

fn emitContact(
    storage: *physics_debug.Storage,
    point: [3]f32,
    normal: [3]f32,
    object: ?physics_debug.ObjectRef,
) void {
    const marker_radius: f32 = 0.05;
    for ([_][3]f32{
        .{ marker_radius, 0, 0 },
        .{ 0, marker_radius, 0 },
        .{ 0, 0, marker_radius },
    }) |axis| {
        addDebugLine(
            storage,
            .contact,
            sub3(point, axis),
            add3(point, axis),
            contact_color,
            object,
        );
    }
    addDebugLine(
        storage,
        .contact,
        point,
        add3(point, scale3(normal, 0.35)),
        contact_color,
        object,
    );
}

/// Compile-time physics capability consumed by the crate vertical slice.
/// Keeping the handle concrete avoids allocation, type erasure, and a Jolt
/// dependency in the feature module while still giving the host an explicit
/// composition seam.
pub const PhysicsStepper = struct {
    physics: *Physics,

    pub fn step(self: *PhysicsStepper, delta_time: f32) !void {
        try self.physics.update(delta_time);
    }
};

pub const CrateBodies = struct {
    physics: *Physics,

    pub const Handle = BodyId;

    pub fn createDynamicBox(
        self: *CrateBodies,
        desc: engine.physics.DynamicBoxDesc,
    ) !Handle {
        const normalized = try desc.normalized();
        const body_id = try self.physics.createDynamicBox(
            normalized.pose.position,
            normalized.half_extents,
        );
        errdefer _ = self.physics.removeBody(body_id);

        try self.physics.setBodyRotation(body_id, normalized.pose.rotation);
        try self.physics.setLinearVelocity(body_id, normalized.velocity.linear);
        try self.physics.setAngularVelocity(body_id, normalized.velocity.angular);
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

    /// Atomically install the complete authoritative motion state and wake the
    /// crate. Every fallible check and conversion happens before the first Jolt
    /// mutation. Jolt's combined operation preserves the body identifier,
    /// shape, motion type, collision layer, mass, and other body properties.
    pub fn relocateBody(
        self: *CrateBodies,
        body_id: Handle,
        state: engine.physics.BodyState,
    ) !void {
        try self.physics.validateBody(body_id);
        const normalized = try state.normalized();

        var position = toRVec3(normalized.pose.position);
        var rotation = c.JPH_Quat{
            .x = normalized.pose.rotation[0],
            .y = normalized.pose.rotation[1],
            .z = normalized.pose.rotation[2],
            .w = normalized.pose.rotation[3],
        };
        var linear_velocity = toVec3(normalized.velocity.linear);
        var angular_velocity = toVec3(normalized.velocity.angular);

        c.JPH_BodyInterface_SetPositionRotationAndVelocity(
            self.physics.body_interface,
            body_id.toJolt(),
            &position,
            &rotation,
            &linear_velocity,
            &angular_velocity,
        );
        // Jolt's combined setter wakes only for non-zero velocity. Authoring
        // relocation has explicit wake semantics even when velocity is zero.
        c.JPH_BodyInterface_ActivateBody(
            self.physics.body_interface,
            body_id.toJolt(),
        );
    }

    pub fn applyImpulse(
        self: *CrateBodies,
        body_id: Handle,
        impulse: [3]f32,
    ) !void {
        try self.physics.addImpulse(body_id, impulse);
    }

    pub fn bodyCount(self: *CrateBodies) u32 {
        return self.physics.getBodyCount();
    }

    pub fn activeBodyCount(self: *CrateBodies) u32 {
        return self.physics.getActiveBodyCount();
    }
};

/// Static-body capability for district environment features. Creation is
/// transactional: a body whose rotation cannot be applied is removed before
/// the error crosses the adapter boundary.
pub const DistrictBodies = struct {
    physics: *Physics,

    pub const Handle = BodyId;

    pub fn createStaticBox(
        self: *DistrictBodies,
        desc: engine.physics.StaticBoxDesc,
    ) !Handle {
        const normalized = try desc.normalized();
        const body_id = try self.physics.createStaticBox(
            normalized.pose.position,
            normalized.half_extents,
        );
        errdefer _ = self.physics.removeBody(body_id);

        try self.physics.setBodyRotation(body_id, normalized.pose.rotation);
        return body_id;
    }

    pub fn destroyBody(self: *DistrictBodies, body_id: Handle) !void {
        try self.physics.validateBody(body_id);
        const body = c.JPH_PhysicsSystem_GetBodyPtr(
            self.physics.system,
            body_id.toJolt(),
        ) orelse return error.InvalidBodyId;
        var bounds: c.JPH_AABox = undefined;
        c.JPH_Body_GetWorldSpaceBounds(body, &bounds);
        const wake_padding: f32 = 0.05;
        bounds.min.x -= wake_padding;
        bounds.min.y -= wake_padding;
        bounds.min.z -= wake_padding;
        bounds.max.x += wake_padding;
        bounds.max.y += wake_padding;
        bounds.max.z += wake_padding;
        // Removing static streaming support must wake sleeping moving bodies
        // that touched it; otherwise they can remain suspended indefinitely.
        c.JPH_PhysicsSystem_ActivateBodiesInAABox(
            self.physics.system,
            &bounds,
            object_layers.moving,
        );
        if (!self.physics.removeBody(body_id)) {
            @panic("validated district body could not be removed");
        }
    }

    /// Host-only diagnostic. This is intentionally not part of the static-body
    /// feature contract.
    pub fn bodyCount(self: *DistrictBodies) u32 {
        return self.physics.getBodyCount();
    }
};

/// Compile-time capability consumed by the character vertical slice. Virtual
/// character allocation and Jolt query details remain private to this adapter.
pub const CharacterControllers = struct {
    physics: *Physics,

    pub const Handle = CharacterId;

    /// Host-only diagnostics. The count is Physics-global, not wrapper-local.
    pub fn controllerCount(self: *CharacterControllers) usize {
        self.physics.assertOwnerThread();
        return self.physics.character_handles.count();
    }

    pub fn controllerCapacity(_: *const CharacterControllers) usize {
        return max_virtual_characters;
    }

    pub fn createCharacter(
        self: *CharacterControllers,
        desc: engine.physics.CharacterDesc,
    ) !Handle {
        return self.physics.createVirtualCharacter(desc);
    }

    pub fn destroyCharacter(
        self: *CharacterControllers,
        character_id: Handle,
    ) !void {
        try self.physics.destroyVirtualCharacter(character_id);
    }

    pub fn characterState(
        self: *CharacterControllers,
        character_id: Handle,
    ) !engine.physics.CharacterState {
        return self.physics.virtualCharacterState(character_id);
    }

    pub fn prepareCharacter(
        self: *CharacterControllers,
        character_id: Handle,
    ) !engine.physics.CharacterState {
        return self.physics.prepareVirtualCharacter(character_id);
    }

    pub fn updateCharacter(
        self: *CharacterControllers,
        character_id: Handle,
        update_desc: engine.physics.CharacterUpdate,
        delta_time: f32,
    ) !engine.physics.CharacterState {
        return self.physics.updateVirtualCharacter(
            character_id,
            update_desc,
            delta_time,
        );
    }

    pub fn tryRelocateCharacter(
        self: *CharacterControllers,
        character_id: Handle,
        relocation: engine.physics.CharacterRelocation,
    ) !?engine.physics.CharacterState {
        return self.physics.tryRelocateVirtualCharacter(character_id, relocation);
    }
};

/// Compile-time capability consumed by the first four-wheel vehicle slice.
/// Vehicle constraints advance through the composition-owned shared Jolt step;
/// this surface intentionally has no per-vehicle update method.
pub const Vehicles = struct {
    physics: *Physics,

    pub const Handle = VehicleId;

    pub fn createVehicle(
        self: *Vehicles,
        desc: engine.physics.VehicleDesc,
    ) !Handle {
        return self.physics.createFourWheelVehicle(desc, null);
    }

    pub fn destroyVehicle(self: *Vehicles, vehicle_id: Handle) !void {
        try self.physics.destroyFourWheelVehicle(vehicle_id);
    }

    pub fn setVehicleInput(
        self: *Vehicles,
        vehicle_id: Handle,
        input: engine.physics.VehicleInput,
    ) !void {
        try self.physics.setFourWheelVehicleInput(vehicle_id, input);
    }

    pub fn vehicleState(
        self: *Vehicles,
        vehicle_id: Handle,
    ) !engine.physics.VehicleState {
        return self.physics.fourWheelVehicleState(vehicle_id);
    }
};

fn injectVehicleCreateFailure(
    comptime requested: ?VehicleCreateFailurePoint,
    comptime reached: VehicleCreateFailurePoint,
) !void {
    if (requested == reached) return error.InjectedVehicleCreateFailure;
}

fn isFiniteVector(value: [3]f32) bool {
    return std.math.isFinite(value[0]) and
        std.math.isFinite(value[1]) and
        std.math.isFinite(value[2]);
}

fn normalizeQuaternion(rotation: [4]f32) ![4]f32 {
    return engine.transform.normalizeQuaternion(rotation) catch
        return error.InvalidRotation;
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

fn ensureCharacterContactCapacity(
    character: *c.JPH_CharacterVirtual,
) error{CharacterContactCapacityExceeded}!void {
    if (c.JPH_CharacterVirtual_GetMaxHitsExceeded(character)) {
        return error.CharacterContactCapacityExceeded;
    }
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

fn contactDebugResourcesForTest(physics: *Physics) ?ContactDebugResources {
    return switch (physics.contact_debug_capture) {
        .available => |resources| resources,
        else => null,
    };
}

fn toVec3(value: [3]f32) c.JPH_Vec3 {
    return .{ .x = value[0], .y = value[1], .z = value[2] };
}

fn toRVec3(value: [3]f32) c.JPH_RVec3 {
    return .{ .x = value[0], .y = value[1], .z = value[2] };
}

fn toJoltQuat(value: [4]f32) c.JPH_Quat {
    return .{ .x = value[0], .y = value[1], .z = value[2], .w = value[3] };
}

fn fromVec3(value: c.JPH_Vec3) [3]f32 {
    return .{ value.x, value.y, value.z };
}

fn fromRVec3(value: c.JPH_RVec3) [3]f32 {
    return .{ @floatCast(value.x), @floatCast(value.y), @floatCast(value.z) };
}

fn fromJoltQuat(value: c.JPH_Quat) [4]f32 {
    return .{ value.x, value.y, value.z, value.w };
}

/// Convert Jolt's column-major rigid transform into an engine pose. The build
/// fixes single-precision world coordinates, so JPH_RMat4 aliases JPH_Mat4.
fn poseFromJoltMatrix(value: c.JPH_RMat4) !engine.physics.Pose {
    const m00 = value.column[0].x;
    const m01 = value.column[1].x;
    const m02 = value.column[2].x;
    const m10 = value.column[0].y;
    const m11 = value.column[1].y;
    const m12 = value.column[2].y;
    const m20 = value.column[0].z;
    const m21 = value.column[1].z;
    const m22 = value.column[2].z;

    var rotation: [4]f32 = undefined;
    const trace = m00 + m11 + m22;
    if (trace > 0) {
        const scale = 2.0 * @sqrt(@max(@as(f32, 0), trace + 1.0));
        rotation = .{
            (m21 - m12) / scale,
            (m02 - m20) / scale,
            (m10 - m01) / scale,
            0.25 * scale,
        };
    } else if (m00 > m11 and m00 > m22) {
        const scale = 2.0 * @sqrt(@max(@as(f32, 0), 1.0 + m00 - m11 - m22));
        rotation = .{
            0.25 * scale,
            (m01 + m10) / scale,
            (m02 + m20) / scale,
            (m21 - m12) / scale,
        };
    } else if (m11 > m22) {
        const scale = 2.0 * @sqrt(@max(@as(f32, 0), 1.0 + m11 - m00 - m22));
        rotation = .{
            (m01 + m10) / scale,
            0.25 * scale,
            (m12 + m21) / scale,
            (m02 - m20) / scale,
        };
    } else {
        const scale = 2.0 * @sqrt(@max(@as(f32, 0), 1.0 + m22 - m00 - m11));
        rotation = .{
            (m02 + m20) / scale,
            (m12 + m21) / scale,
            0.25 * scale,
            (m10 - m01) / scale,
        };
    }

    return (engine.physics.Pose{
        .position = .{
            value.column[3].x,
            value.column[3].y,
            value.column[3].z,
        },
        .rotation = rotation,
    }).normalized();
}

fn expectEquivalentRotation(expected: [4]f32, actual: [4]f32) !void {
    const dot = expected[0] * actual[0] +
        expected[1] * actual[1] +
        expected[2] * actual[2] +
        expected[3] * actual[3];
    try std.testing.expectApproxEqAbs(@as(f32, 1), @abs(dot), 0.0001);
}

fn expectBodyStateApprox(
    expected: engine.physics.BodyState,
    actual: engine.physics.BodyState,
) !void {
    for (expected.pose.position, actual.pose.position) |expected_value, actual_value| {
        try std.testing.expectApproxEqAbs(expected_value, actual_value, 0.0001);
    }
    try expectEquivalentRotation(expected.pose.rotation, actual.pose.rotation);
    for (expected.velocity.linear, actual.velocity.linear) |expected_value, actual_value| {
        try std.testing.expectApproxEqAbs(expected_value, actual_value, 0.0001);
    }
    for (expected.velocity.angular, actual.velocity.angular) |expected_value, actual_value| {
        try std.testing.expectApproxEqAbs(expected_value, actual_value, 0.0001);
    }
}

fn fromJoltGroundState(value: c.JPH_GroundState) engine.physics.GroundState {
    return switch (value) {
        c.JPH_GroundState_OnGround => .on_ground,
        c.JPH_GroundState_OnSteepGround => .on_steep_ground,
        c.JPH_GroundState_NotSupported => .not_supported,
        c.JPH_GroundState_InAir => .in_air,
        else => unreachable,
    };
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

test "Jolt job-system sizing matches the supported exact cohort" {
    try std.testing.expectEqual(@as(i32, 1), job_system_worker_count);
    try std.testing.expectEqual(
        @as(u32, c.JPH_MAX_PHYSICS_JOBS),
        job_system_max_jobs,
    );
    try std.testing.expectEqual(
        @as(u32, c.JPH_MAX_PHYSICS_BARRIERS),
        job_system_max_barriers,
    );
}

test "Jolt job-system C config never requests wrapper defaults" {
    const config = jobSystemThreadPoolConfig();

    try std.testing.expect(config.maxJobs > 0);
    try std.testing.expect(config.maxBarriers > 0);
    try std.testing.expect(config.numThreads > 0);
    try std.testing.expectEqual(job_system_max_jobs, config.maxJobs);
    try std.testing.expectEqual(job_system_max_barriers, config.maxBarriers);
    try std.testing.expectEqual(job_system_worker_count, config.numThreads);
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

test "Jolt rigid matrix conversion covers identity and 180 degree branches" {
    const identity_translation = c.JPH_RMat4{ .column = .{
        .{ .x = 1, .y = 0, .z = 0, .w = 0 },
        .{ .x = 0, .y = 1, .z = 0, .w = 0 },
        .{ .x = 0, .y = 0, .z = 1, .w = 0 },
        .{ .x = 3, .y = -4, .z = 5, .w = 1 },
    } };
    const identity_pose = try poseFromJoltMatrix(identity_translation);
    for ([3]f32{ 3, -4, 5 }, identity_pose.position) |expected, actual| {
        try std.testing.expectApproxEqAbs(expected, actual, 0.0001);
    }
    try expectEquivalentRotation(.{ 0, 0, 0, 1 }, identity_pose.rotation);

    const rotations = [_]struct {
        matrix: c.JPH_RMat4,
        quaternion: [4]f32,
        position: [3]f32,
    }{
        .{
            .matrix = .{ .column = .{
                .{ .x = 1, .y = 0, .z = 0, .w = 0 },
                .{ .x = 0, .y = -1, .z = 0, .w = 0 },
                .{ .x = 0, .y = 0, .z = -1, .w = 0 },
                .{ .x = 0, .y = 0, .z = 0, .w = 1 },
            } },
            .quaternion = .{ 1, 0, 0, 0 },
            .position = .{ 0, 0, 0 },
        },
        .{
            .matrix = .{ .column = .{
                .{ .x = -1, .y = 0, .z = 0, .w = 0 },
                .{ .x = 0, .y = 1, .z = 0, .w = 0 },
                .{ .x = 0, .y = 0, .z = -1, .w = 0 },
                .{ .x = 0, .y = 0, .z = 0, .w = 1 },
            } },
            .quaternion = .{ 0, 1, 0, 0 },
            .position = .{ 0, 0, 0 },
        },
        .{
            .matrix = .{ .column = .{
                .{ .x = -1, .y = 0, .z = 0, .w = 0 },
                .{ .x = 0, .y = -1, .z = 0, .w = 0 },
                .{ .x = 0, .y = 0, .z = 1, .w = 0 },
                .{ .x = 0, .y = 0, .z = 0, .w = 1 },
            } },
            .quaternion = .{ 0, 0, 1, 0 },
            .position = .{ 0, 0, 0 },
        },
        .{
            // A non-self-inverse +90 degree yaw detects row/column and sign
            // mistakes that all 180 degree matrices necessarily hide.
            .matrix = .{ .column = .{
                .{ .x = 0, .y = 0, .z = -1, .w = 0 },
                .{ .x = 0, .y = 1, .z = 0, .w = 0 },
                .{ .x = 1, .y = 0, .z = 0, .w = 0 },
                .{ .x = 7, .y = 8, .z = 9, .w = 1 },
            } },
            .quaternion = .{ 0, @sqrt(0.5), 0, @sqrt(0.5) },
            .position = .{ 7, 8, 9 },
        },
    };
    for (rotations) |rotation| {
        const pose = try poseFromJoltMatrix(rotation.matrix);
        try expectEquivalentRotation(rotation.quaternion, pose.rotation);
        for (rotation.position, pose.position) |expected, actual| {
            try std.testing.expectApproxEqAbs(expected, actual, 0.0001);
        }
    }
}

test "Jolt 5.5 four-wheel vehicle settles drives toward minus Z and brakes" {
    comptime engine.physics.assertVehicleImplementation(Vehicles);

    var physics = try Physics.init();
    defer physics.deinit();
    const ground = try physics.createStaticBox(.{ 0, -1, 0 }, .{ 100, 1, 100 });
    defer _ = physics.removeBody(ground);
    var vehicles = physics.vehicles();
    const vehicle = try vehicles.createVehicle(.{
        .chassis = .{ .pose = .{ .position = .{ 0, 2, 0 } } },
    });
    defer vehicles.destroyVehicle(vehicle) catch unreachable;

    try std.testing.expectEqual(@as(u32, 2), physics.getBodyCount());
    try std.testing.expectEqual(
        @as(u32, 1),
        c.JPH_PhysicsSystem_GetNumConstraints(physics.system),
    );

    for (0..240) |_| try physics.update(1.0 / 120.0);
    const settled = try vehicles.vehicleState(vehicle);
    for (settled.wheels) |wheel| {
        try std.testing.expect(wheel.has_contact);
        try wheel.validate();
    }

    try vehicles.setVehicleInput(vehicle, .{ .throttle = 1 });
    for (0..240) |_| try physics.update(1.0 / 120.0);
    const driven = try vehicles.vehicleState(vehicle);
    try std.testing.expect(driven.chassis.pose.position[2] < settled.chassis.pose.position[2] - 1);
    try std.testing.expect(driven.current_gear > 0);
    try std.testing.expect(driven.engine_rpm > 0);
    var wheel_spinning = false;
    for (driven.wheels) |wheel| {
        wheel_spinning = wheel_spinning or @abs(wheel.angular_velocity) > 0.1;
    }
    try std.testing.expect(wheel_spinning);

    try vehicles.setVehicleInput(vehicle, .{ .brake = 1 });
    for (0..600) |_| try physics.update(1.0 / 120.0);
    const stopped = try vehicles.vehicleState(vehicle);
    const horizontal_speed = @sqrt(
        stopped.chassis.velocity.linear[0] * stopped.chassis.velocity.linear[0] +
            stopped.chassis.velocity.linear[2] * stopped.chassis.velocity.linear[2],
    );
    try std.testing.expect(horizontal_speed < 0.5);
}

test "four-wheel vehicle positive steering follows engine right convention" {
    var physics = try Physics.init();
    defer physics.deinit();
    const ground = try physics.createStaticBox(.{ 0, -1, 0 }, .{ 100, 1, 100 });
    defer _ = physics.removeBody(ground);
    var vehicles = physics.vehicles();
    const vehicle = try vehicles.createVehicle(.{
        .chassis = .{ .pose = .{ .position = .{ 0, 2, 0 } } },
    });
    defer vehicles.destroyVehicle(vehicle) catch unreachable;
    for (0..240) |_| try physics.update(1.0 / 120.0);

    try vehicles.setVehicleInput(vehicle, .{ .throttle = 1, .steering = 0.7 });
    for (0..300) |_| try physics.update(1.0 / 120.0);
    const turned = try vehicles.vehicleState(vehicle);
    try std.testing.expect(turned.chassis.pose.position[0] > 0.25);
    try std.testing.expect(turned.chassis.pose.position[2] < -0.5);
    try std.testing.expect(turned.wheels[@intFromEnum(engine.physics.VehicleWheelIndex.front_left)].steer_angle > 0);
    try std.testing.expect(turned.wheels[@intFromEnum(engine.physics.VehicleWheelIndex.front_right)].steer_angle > 0);
}

test "four-wheel vehicle handles are stale safe world qualified and repeatable" {
    var first = try Physics.init();
    defer first.deinit();
    var second = try Physics.init();
    defer second.deinit();
    var first_vehicles = first.vehicles();
    var second_vehicles = second.vehicles();

    const yaw: f32 = 0.4;
    const first_vehicle = try first_vehicles.createVehicle(.{
        .chassis = .{ .pose = .{
            .position = .{ 3, 4, -2 },
            .rotation = .{ 0, @sin(yaw * 0.5), 0, @cos(yaw * 0.5) },
        } },
        .initial_wheel_dynamics = .{
            .{ .rotation_angle = 0.1, .angular_velocity = 1 },
            .{ .rotation_angle = 0.2, .angular_velocity = 2 },
            .{ .rotation_angle = 0.3, .angular_velocity = 3 },
            .{ .rotation_angle = 0.4, .angular_velocity = 4 },
        },
    });
    const initial = try first_vehicles.vehicleState(first_vehicle);
    for ([3]f32{ 3, 4, -2 }, initial.chassis.pose.position) |expected, actual| {
        try std.testing.expectApproxEqAbs(expected, actual, 0.0001);
    }
    for ([4]f32{ 0, @sin(yaw * 0.5), 0, @cos(yaw * 0.5) }, initial.chassis.pose.rotation) |expected, actual| {
        try std.testing.expectApproxEqAbs(expected, actual, 0.0001);
    }
    for (initial.wheels, 0..) |wheel, index| {
        const ordinal: f32 = @floatFromInt(index + 1);
        try std.testing.expectApproxEqAbs(ordinal * 0.1, wheel.rotation_angle, 0.0001);
        try std.testing.expectApproxEqAbs(ordinal, wheel.angular_velocity, 0.0001);
    }
    try std.testing.expectError(
        error.ForeignVehicleId,
        second_vehicles.vehicleState(first_vehicle),
    );
    try first_vehicles.destroyVehicle(first_vehicle);
    try std.testing.expectError(
        error.InvalidVehicleId,
        first_vehicles.vehicleState(first_vehicle),
    );
    try std.testing.expectError(
        error.InvalidVehicleId,
        first_vehicles.destroyVehicle(first_vehicle),
    );

    // Cross Jolt's 8-bit body-generation range while the engine handle serial
    // remains monotonic, proving native slot reuse cannot revive a stale ID.
    for (0..300) |_| {
        const vehicle = try first_vehicles.createVehicle(.{
            .chassis = .{ .pose = .{ .position = .{ 0, 2, 0 } } },
        });
        try first_vehicles.destroyVehicle(vehicle);
    }
    try std.testing.expectEqual(@as(usize, 0), first.vehicle_handles.count());
    try std.testing.expectEqual(@as(u32, 0), first.getBodyCount());
    try std.testing.expectEqual(
        @as(u32, 0),
        c.JPH_PhysicsSystem_GetNumConstraints(first.system),
    );
}

test "four-wheel vehicle handles reject after sequential world recreation" {
    var stale: VehicleId = undefined;
    {
        var original = try Physics.init();
        defer original.deinit();
        var original_vehicles = original.vehicles();
        stale = try original_vehicles.createVehicle(.{});
        try original_vehicles.destroyVehicle(stale);
    }

    var recreated = try Physics.init();
    defer recreated.deinit();
    var recreated_vehicles = recreated.vehicles();
    const current = try recreated_vehicles.createVehicle(.{});
    defer recreated_vehicles.destroyVehicle(current) catch unreachable;
    try std.testing.expectError(
        error.ForeignVehicleId,
        recreated_vehicles.vehicleState(stale),
    );
}

test "four-wheel vehicle creation failures roll back every native owner" {
    var physics = try Physics.init();
    defer physics.deinit();
    const failure_points = [_]VehicleCreateFailurePoint{
        .after_body,
        .after_settings,
        .after_constraint,
        .after_collision_tester,
        .after_registration,
    };

    inline for (failure_points) |failure_point| {
        try std.testing.expectError(
            error.InjectedVehicleCreateFailure,
            physics.createFourWheelVehicle(.{
                .chassis = .{ .pose = .{ .position = .{ 0, 2, 0 } } },
            }, failure_point),
        );
        try std.testing.expectEqual(@as(usize, 0), physics.vehicle_handles.count());
        try std.testing.expectEqual(@as(u32, 0), physics.getBodyCount());
        try std.testing.expectEqual(
            @as(u32, 0),
            c.JPH_PhysicsSystem_GetNumConstraints(physics.system),
        );

        var vehicles = physics.vehicles();
        const healthy = try vehicles.createVehicle(.{
            .chassis = .{ .pose = .{ .position = .{ 0, 2, 0 } } },
        });
        try physics.update(1.0 / 120.0);
        _ = try vehicles.vehicleState(healthy);
        try vehicles.destroyVehicle(healthy);
    }
}

test "Jolt 5.5 virtual character walks, lands, and releases its shape" {
    var physics = try Physics.init();
    defer physics.deinit();

    const ground = try physics.createStaticBox(.{ 0, -1, 0 }, .{ 10, 1, 10 });
    defer _ = physics.removeBody(ground);
    var controllers = physics.characterControllers();
    comptime engine.physics.assertCharacterImplementation(CharacterControllers);
    const character = try controllers.createCharacter(.{
        .position = .{ 0, 2, 0 },
    });
    defer controllers.destroyCharacter(character) catch unreachable;

    var landed = false;
    for (0..240) |_| {
        const before = try controllers.characterState(character);
        var velocity = before.velocity;
        velocity[0] = 1.0;
        velocity[2] = 0;
        if (before.ground_state == .on_ground and velocity[1] < 0.1) {
            velocity[1] = before.ground_velocity[1];
        }
        velocity[1] += -9.81 / 120.0;
        const after = try controllers.updateCharacter(
            character,
            .{ .velocity = velocity },
            1.0 / 120.0,
        );
        landed = landed or after.ground_state == .on_ground;
    }

    const state = try controllers.characterState(character);
    try std.testing.expect(landed);
    try std.testing.expect(state.position[0] > 1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0), state.position[1], 0.05);
}

test "virtual character creation reconstructs grounded contacts" {
    var physics = try Physics.init();
    defer physics.deinit();

    const ground = try physics.createStaticBox(.{ 0, -1, 0 }, .{ 10, 1, 10 });
    defer _ = physics.removeBody(ground);
    var controllers = physics.characterControllers();
    const character = try controllers.createCharacter(.{
        .position = .{ 0, 0, 0 },
    });
    defer controllers.destroyCharacter(character) catch unreachable;

    const state = try controllers.characterState(character);
    try std.testing.expectEqual(engine.physics.GroundState.on_ground, state.ground_state);
    try std.testing.expectApproxEqAbs(@as(f32, 0), state.position[1], 0.0001);
}

test "virtual character relocation is transactional when an exit is blocked" {
    var physics = try Physics.init();
    defer physics.deinit();
    const ground = try physics.createStaticBox(.{ 0, -1, 0 }, .{ 20, 1, 20 });
    defer _ = physics.removeBody(ground);
    const blocker = try physics.createStaticBox(.{ 5, 1, 0 }, .{ 1, 1, 1 });
    defer _ = physics.removeBody(blocker);
    var controllers = physics.characterControllers();
    const character = try controllers.createCharacter(.{
        .position = .{ 0, 0, 0 },
        .velocity = .{ 0.5, 0, 0 },
    });
    defer controllers.destroyCharacter(character) catch unreachable;
    const original = try controllers.characterState(character);

    try std.testing.expect((try controllers.tryRelocateCharacter(character, .{
        .position = .{ 5, 0, 0 },
    })) == null);
    const rolled_back = try controllers.characterState(character);
    try std.testing.expectEqualDeep(original.position, rolled_back.position);
    try std.testing.expectEqualDeep(original.velocity, rolled_back.velocity);

    const accepted = (try controllers.tryRelocateCharacter(character, .{
        .position = .{ 3, 0, 0 },
        .velocity = .{ 1, 0, -2 },
    })) orelse return error.ExpectedRelocation;
    try std.testing.expectEqualDeep([3]f32{ 3, 0, 0 }, accepted.position);
    try std.testing.expectEqualDeep([3]f32{ 1, 0, -2 }, accepted.velocity);
    const relocated = try controllers.characterState(character);
    try std.testing.expectEqualDeep([3]f32{ 3, 0, 0 }, relocated.position);
    try std.testing.expectEqualDeep([3]f32{ 1, 0, -2 }, relocated.velocity);
}

test "virtual character handles reject stale and foreign worlds" {
    var first = try Physics.init();
    defer first.deinit();
    var second = try Physics.init();
    defer second.deinit();
    var first_controllers = first.characterControllers();
    var second_controllers = second.characterControllers();
    const character = try first_controllers.createCharacter(.{
        .position = .{ 0, 1, 0 },
    });
    const second_character = try second_controllers.createCharacter(.{
        .position = .{ 0, 1, 0 },
    });
    defer second_controllers.destroyCharacter(second_character) catch unreachable;

    const first_jolt_id = c.JPH_CharacterVirtual_GetID(
        try first.characterPtr(character),
    );
    const second_jolt_id = c.JPH_CharacterVirtual_GetID(
        try second.characterPtr(second_character),
    );
    try std.testing.expect(first_jolt_id != second_jolt_id);

    try std.testing.expectError(
        error.ForeignCharacterId,
        second_controllers.characterState(character),
    );
    try first_controllers.destroyCharacter(character);
    try std.testing.expectError(
        error.InvalidCharacterId,
        first_controllers.characterState(character),
    );
    try std.testing.expectError(
        error.InvalidCharacterId,
        first_controllers.destroyCharacter(character),
    );
}

test "virtual character lifecycle can be repeated without retained handles" {
    var physics = try Physics.init();
    defer physics.deinit();
    var controllers = physics.characterControllers();
    for (0..64) |index| {
        const x: f32 = @floatFromInt(index);
        const character = try controllers.createCharacter(.{
            .position = .{ x, 1, 0 },
        });
        _ = try controllers.updateCharacter(
            character,
            .{ .velocity = .{ 0, -1, 0 } },
            1.0 / 120.0,
        );
        try controllers.destroyCharacter(character);
    }
    try std.testing.expectEqual(@as(usize, 0), physics.character_handles.count());
}

test "character controller views share one fixed global capacity" {
    var physics = try Physics.init();
    defer physics.deinit();
    var first = physics.characterControllers();
    var second = physics.characterControllers();
    try std.testing.expectEqual(max_virtual_characters, first.controllerCapacity());
    try std.testing.expectEqual(max_virtual_characters, second.controllerCapacity());

    var handles: [max_virtual_characters]CharacterId = undefined;
    for (&handles, 0..) |*handle, index| {
        const x: f32 = @floatFromInt(index % 16);
        const z: f32 = @floatFromInt(index / 16);
        const controllers = if (index < max_virtual_characters / 2) &first else &second;
        handle.* = try controllers.createCharacter(.{
            .position = .{ x * 2, 1, z * 2 },
        });
    }
    try std.testing.expectEqual(max_virtual_characters, first.controllerCount());
    try std.testing.expectEqual(max_virtual_characters, second.controllerCount());
    for (handles, 0..) |handle, index| {
        const controllers = if (index < max_virtual_characters / 2) &first else &second;
        _ = try controllers.prepareCharacter(handle);
        _ = try controllers.updateCharacter(
            handle,
            .{ .velocity = .{ 0, -1, 0 } },
            1.0 / 120.0,
        );
    }
    try std.testing.expectError(
        error.TooManyCharacters,
        second.createCharacter(.{ .position = .{ 40, 1, 40 } }),
    );

    try first.destroyCharacter(handles[0]);
    const replacement = try second.createCharacter(.{ .position = .{ 40, 1, 40 } });
    _ = try second.updateCharacter(
        replacement,
        .{ .velocity = .{ 0, -1, 0 } },
        1.0 / 120.0,
    );
    for (handles[1..]) |handle| try first.destroyCharacter(handle);
    try second.destroyCharacter(replacement);
    try std.testing.expectEqual(@as(usize, 0), first.controllerCount());
}

test "virtual character distinguishes walkable and steep support" {
    try std.testing.expect(try observesGroundStateOnRamp(
        std.math.degreesToRadians(30.0),
        .on_ground,
    ));
    try std.testing.expect(try observesGroundStateOnRamp(
        std.math.degreesToRadians(60.0),
        .on_steep_ground,
    ));
}

fn observesGroundStateOnRamp(
    angle: f32,
    expected: engine.physics.GroundState,
) !bool {
    var physics = try Physics.init();
    defer physics.deinit();
    const ramp = try physics.createStaticBox(.{ 0, 0, 0 }, .{ 3, 0.1, 3 });
    defer _ = physics.removeBody(ramp);
    try physics.setBodyRotation(ramp, .{
        0,
        0,
        @sin(angle * 0.5),
        @cos(angle * 0.5),
    });
    var controllers = physics.characterControllers();
    const character = try controllers.createCharacter(.{
        .position = .{ 0, 2, 0 },
    });
    defer controllers.destroyCharacter(character) catch unreachable;
    var observed = false;
    for (0..240) |_| {
        const before = try controllers.characterState(character);
        var velocity = before.velocity;
        if (before.ground_state == .on_ground and
            velocity[1] - before.ground_velocity[1] < 0.1)
        {
            velocity[1] = before.ground_velocity[1];
        }
        velocity[1] -= 9.81 / 120.0;
        const after = try controllers.updateCharacter(
            character,
            .{ .velocity = velocity },
            1.0 / 120.0,
        );
        observed = observed or after.ground_state == expected;
    }
    return observed;
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

test "physics init failure checkpoints unwind and permit healthy restart" {
    const leases_before = runtimeLeaseCount();
    const failure_points = [_]InitFailurePoint{
        .after_runtime_lease,
        .after_job_and_temp_allocators,
        .after_filter_bundle,
        .after_physics_system_transfer,
        .after_contact_listener,
    };

    inline for (failure_points) |failure_point| {
        try std.testing.expectError(
            error.InjectedInitFailure,
            Physics.initWithAllocatorAndFailurePoint(
                std.heap.page_allocator,
                failure_point,
            ),
        );
        try std.testing.expectEqual(leases_before, runtimeLeaseCount());

        {
            var healthy = try Physics.init();
            defer healthy.deinit();
            try std.testing.expectEqual(leases_before + 1, runtimeLeaseCount());

            const body = try healthy.createDynamicBox(
                .{ 0, 2, 0 },
                .{ 0.5, 0.5, 0.5 },
            );
            try healthy.update(1.0 / 60.0);
            try std.testing.expect(healthy.isBodyAdded(body));
            try std.testing.expect(healthy.removeBody(body));
        }

        try std.testing.expectEqual(leases_before, runtimeLeaseCount());
    }
}

test "contact scratch allocation failure preserves authority and reports partial evidence" {
    const leases_before = runtimeLeaseCount();
    var allocator_bytes: [16 * 1024]u8 = undefined;
    try std.testing.expect(allocator_bytes.len < @sizeOf(ContactScratch));
    var fixed = std.heap.FixedBufferAllocator.init(&allocator_bytes);

    var physics = try Physics.initWithAllocator(fixed.allocator());
    defer physics.deinit();
    try std.testing.expectEqual(leases_before + 1, runtimeLeaseCount());
    try std.testing.expectEqual(
        RigidContactCaptureAvailability.unavailable_scratch_allocation,
        physics.rigidContactCaptureAvailability(),
    );

    const body = try physics.createStaticBox(.{ 0, -1, 0 }, .{ 3, 1, 3 });
    defer _ = physics.removeBody(body);
    try physics.update(1.0 / 60.0);

    var first_lines: [256]physics_debug.Line = undefined;
    var first_triangles: [64]physics_debug.Triangle = undefined;
    var first_storage = physics_debug.Storage.init(&first_lines, &first_triangles);
    const first = physics.extractDebugWithStatus(.{}, 1, &first_storage);
    try std.testing.expectEqual(
        RigidContactCaptureAvailability.unavailable_scratch_allocation,
        first.rigid_contact_capture,
    );
    try std.testing.expect(first.batch.statsFor(.contact).source_unavailable);
    try std.testing.expectEqual(
        physics_debug.PrimitiveStats{},
        first.batch.statsFor(.contact).lines,
    );
    inline for (.{
        physics_debug.Category.shape,
        physics_debug.Category.bounds,
        physics_debug.Category.center_of_mass,
        physics_debug.Category.velocity,
    }) |category| {
        try std.testing.expect(first.batch.statsFor(category).lines.admitted > 0);
        try std.testing.expect(!first.batch.statsFor(category).source_unavailable);
    }
    try std.testing.expect(first.batch.statsFor(.shape).triangles.admitted > 0);

    // Re-reading the same stopped authoritative state remains deterministic
    // even though one optional producer never existed.
    var second_lines: [256]physics_debug.Line = undefined;
    var second_triangles: [64]physics_debug.Triangle = undefined;
    var second_storage = physics_debug.Storage.init(&second_lines, &second_triangles);
    const second = physics.extractDebugWithStatus(.{}, 1, &second_storage);
    try std.testing.expectEqual(first.batch.lines.len, second.batch.lines.len);
    try std.testing.expectEqual(first.batch.triangles.len, second.batch.triangles.len);
    for (first.batch.lines, second.batch.lines) |expected, actual| {
        try std.testing.expect(std.meta.eql(expected, actual));
    }
    for (first.batch.triangles, second.batch.triangles) |expected, actual| {
        try std.testing.expect(std.meta.eql(expected, actual));
    }

    var contacts_disabled = DebugConfig{};
    contacts_disabled.contacts = false;
    const disabled = physics.extractDebugWithStatus(
        contacts_disabled,
        1,
        &second_storage,
    );
    try std.testing.expect(!disabled.batch.statsFor(.contact).source_unavailable);
}

test "contact listener creation failure is optional and tears scratch down safely" {
    const leases_before = runtimeLeaseCount();
    var physics = try Physics.initWithContactDebugFailureForTest(
        std.testing.allocator,
        .listener_creation,
    );
    defer physics.deinit();
    try std.testing.expectEqual(leases_before + 1, runtimeLeaseCount());
    try std.testing.expectEqual(
        RigidContactCaptureAvailability.unavailable_listener_creation,
        physics.rigidContactCaptureAvailability(),
    );

    const body = try physics.createDynamicBox(.{ 0, 2, 0 }, .{ 0.5, 0.5, 0.5 });
    defer _ = physics.removeBody(body);
    try physics.update(1.0 / 60.0);

    var lines: [256]physics_debug.Line = undefined;
    var triangles: [64]physics_debug.Triangle = undefined;
    var storage = physics_debug.Storage.init(&lines, &triangles);
    const extraction = physics.extractDebugWithStatus(.{}, 1, &storage);
    try std.testing.expectEqual(
        RigidContactCaptureAvailability.unavailable_listener_creation,
        extraction.rigid_contact_capture,
    );
    try std.testing.expect(extraction.batch.statsFor(.contact).source_unavailable);
    try std.testing.expect(extraction.batch.statsFor(.shape).lines.admitted > 0);
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
    var stepper = physics.stepper();
    try stepper.step(1.0 / 60.0);

    try bodies.destroyBody(body);
    try std.testing.expectEqual(@as(u32, 0), bodies.bodyCount());
    try std.testing.expectError(error.InvalidBodyId, bodies.destroyBody(body));
    try std.testing.expectError(error.InvalidBodyId, bodies.bodyState(body));

    try std.testing.expectError(
        error.DegenerateQuaternion,
        bodies.createDynamicBox(.{
            .pose = .{ .rotation = .{ 0, 0, 0, 0 } },
            .half_extents = .{ 0.5, 0.5, 0.5 },
        }),
    );
    try std.testing.expectEqual(@as(u32, 0), bodies.bodyCount());
}

test "crate capability preserves accepted boundary velocities without clamping" {
    var physics = try Physics.init();
    defer physics.deinit();
    var bodies = physics.crateBodies();
    const desc = engine.physics.DynamicBoxDesc{
        .pose = .{ .position = .{ 0, 10, 0 } },
        .velocity = .{
            .linear = .{ 300, 400, 0 },
            .angular = .{ 0, 0, engine.physics.max_angular_velocity },
        },
        .half_extents = .{ 0.5, 0.5, 0.5 },
    };
    const body = try bodies.createDynamicBox(desc);
    defer bodies.destroyBody(body) catch @panic("boundary body cleanup failed");
    const state = try bodies.bodyState(body);
    for (desc.velocity.linear, state.velocity.linear) |expected, actual| {
        try std.testing.expectApproxEqAbs(expected, actual, 0.0001);
    }
    for (desc.velocity.angular, state.velocity.angular) |expected, actual| {
        try std.testing.expectApproxEqAbs(expected, actual, 0.0001);
    }
}

test "crate relocation atomically installs state preserves body properties and explicitly wakes" {
    var physics = try Physics.init();
    defer physics.deinit();
    const ground = try physics.createStaticBox(.{ 0, -1, 0 }, .{ 20, 1, 20 });
    defer _ = physics.removeBody(ground);
    var bodies = physics.crateBodies();
    const body = try bodies.createDynamicBox(.{
        .pose = .{ .position = .{ 0, 4, 0 } },
        .half_extents = .{ 0.5, 0.75, 1.25 },
    });
    defer bodies.destroyBody(body) catch @panic("relocated body cleanup failed");

    // Settle all the way to sleep so the zero-velocity relocation exercises
    // the adapter's explicit wake rather than Jolt's velocity-based wake.
    for (0..2_000) |_| {
        try physics.update(1.0 / 120.0);
        if (!try physics.isBodyActive(body)) break;
    }
    try std.testing.expect(!try physics.isBodyActive(body));

    const record_before = physics.body_handles.get(body.serial) orelse
        return error.MissingBodyHandleRecord;
    const body_count_before = bodies.bodyCount();
    const motion_before = try physics.getMotionType(body);
    const layer_before = c.JPH_BodyInterface_GetObjectLayer(
        physics.body_interface,
        body.toJolt(),
    );
    const target = try (engine.physics.BodyState{
        .pose = .{
            .position = .{ 8.25, 6.5, -3.75 },
            .rotation = .{ 0, 2, 0, 2 },
        },
        .velocity = .{},
    }).normalized();

    try bodies.relocateBody(body, target);
    try expectBodyStateApprox(target, try bodies.bodyState(body));
    try std.testing.expect(try physics.isBodyActive(body));
    try std.testing.expectEqual(body_count_before, bodies.bodyCount());
    try std.testing.expectEqual(motion_before, try physics.getMotionType(body));
    try std.testing.expectEqual(
        layer_before,
        c.JPH_BodyInterface_GetObjectLayer(physics.body_interface, body.toJolt()),
    );
    const record_after = physics.body_handles.get(body.serial) orelse
        return error.MissingBodyHandleRecord;
    try std.testing.expectEqual(record_before.raw_id, record_after.raw_id);
    try std.testing.expect(std.meta.eql(record_before.shape, record_after.shape));
    try std.testing.expect(physics.isBodyAdded(body));
}

test "crate relocation rejects invalid stale and foreign state without mutation" {
    var first = try Physics.init();
    defer first.deinit();
    var first_bodies = first.crateBodies();
    const body = try first_bodies.createDynamicBox(.{
        .pose = .{ .position = .{ 1, 2, 3 } },
        .velocity = .{
            .linear = .{ 4, 5, 6 },
            .angular = .{ 1, 2, 3 },
        },
        .half_extents = .{ 0.5, 1, 1.5 },
    });

    const state_before = try first_bodies.bodyState(body);
    const record_before = first.body_handles.get(body.serial) orelse
        return error.MissingBodyHandleRecord;
    const body_count_before = first_bodies.bodyCount();
    const active_before = try first.isBodyActive(body);
    const motion_before = try first.getMotionType(body);
    const layer_before = c.JPH_BodyInterface_GetObjectLayer(
        first.body_interface,
        body.toJolt(),
    );
    try std.testing.expectError(
        error.NonFiniteTransform,
        first_bodies.relocateBody(body, .{
            .pose = .{ .position = .{ std.math.inf(f32), 0, 0 } },
        }),
    );
    try std.testing.expectError(
        error.LinearVelocityOutOfRange,
        first_bodies.relocateBody(body, .{
            .velocity = .{ .linear = .{ engine.physics.max_linear_velocity, 1, 0 } },
        }),
    );
    try expectBodyStateApprox(state_before, try first_bodies.bodyState(body));
    try std.testing.expectEqual(body_count_before, first_bodies.bodyCount());
    try std.testing.expectEqual(active_before, try first.isBodyActive(body));
    try std.testing.expectEqual(motion_before, try first.getMotionType(body));
    try std.testing.expectEqual(
        layer_before,
        c.JPH_BodyInterface_GetObjectLayer(first.body_interface, body.toJolt()),
    );
    const record_after_rejection = first.body_handles.get(body.serial) orelse
        return error.MissingBodyHandleRecord;
    try std.testing.expectEqual(record_before.raw_id, record_after_rejection.raw_id);
    try std.testing.expect(std.meta.eql(record_before.shape, record_after_rejection.shape));

    var second = try Physics.init();
    defer second.deinit();
    var second_bodies = second.crateBodies();
    try std.testing.expectError(
        error.ForeignBodyId,
        second_bodies.relocateBody(body, .{ .pose = .{ .position = .{ 9, 9, 9 } } }),
    );
    try expectBodyStateApprox(state_before, try first_bodies.bodyState(body));
    try std.testing.expectEqual(@as(u32, 0), second_bodies.bodyCount());

    try first_bodies.destroyBody(body);
    try std.testing.expectError(
        error.InvalidBodyId,
        first_bodies.relocateBody(body, .{ .pose = .{ .position = .{ 7, 7, 7 } } }),
    );
    try std.testing.expectEqual(@as(u32, 0), first_bodies.bodyCount());
}

test "district capability creates rotated static bodies and tears them down" {
    comptime engine.physics.assertStaticBodyImplementation(DistrictBodies);

    var physics = try Physics.init();
    defer physics.deinit();
    var bodies = physics.districtBodies();

    const half_angle = std.math.pi / 8.0;
    const desc = engine.physics.StaticBoxDesc{
        .pose = .{
            .position = .{ 4.5, 2.0, -7.25 },
            // Exercise both normalization and a non-identity rotation.
            .rotation = .{ 0, 2 * @sin(half_angle), 0, 2 * @cos(half_angle) },
        },
        .half_extents = .{ 3.0, 1.5, 0.75 },
    };

    const body = try bodies.createStaticBox(desc);
    try std.testing.expectEqual(@as(u32, 1), bodies.bodyCount());
    try std.testing.expectEqual(MotionType.static, try physics.getMotionType(body));

    const position = try physics.getBodyPosition(body);
    for (desc.pose.position, position) |expected, actual| {
        try std.testing.expectApproxEqAbs(expected, actual, 0.0001);
    }
    const expected_pose = try desc.pose.normalized();
    try expectEquivalentRotation(
        expected_pose.rotation,
        try physics.getBodyRotation(body),
    );

    try bodies.destroyBody(body);
    try std.testing.expectEqual(@as(u32, 0), bodies.bodyCount());
    try std.testing.expectError(error.InvalidBodyId, bodies.destroyBody(body));
}

test "district capability rejects invalid input and foreign handles" {
    var first = try Physics.init();
    defer first.deinit();
    var second = try Physics.init();
    defer second.deinit();
    var first_bodies = first.districtBodies();
    var second_bodies = second.districtBodies();

    try std.testing.expectError(
        error.InvalidHalfExtents,
        first_bodies.createStaticBox(.{
            .pose = .{},
            .half_extents = .{ 1, -1, 1 },
        }),
    );
    try std.testing.expectError(
        error.NonFinitePhysicsValue,
        first_bodies.createStaticBox(.{
            .pose = .{},
            .half_extents = .{ 1, std.math.nan(f32), 1 },
        }),
    );
    try std.testing.expectError(
        error.DegenerateQuaternion,
        first_bodies.createStaticBox(.{
            .pose = .{ .rotation = .{ 0, 0, 0, 0 } },
            .half_extents = .{ 1, 1, 1 },
        }),
    );
    try std.testing.expectEqual(@as(u32, 0), first_bodies.bodyCount());

    const body = try first_bodies.createStaticBox(.{
        .pose = .{ .position = .{ 2, 3, 4 } },
        .half_extents = .{ 1, 1, 1 },
    });
    try std.testing.expectError(
        error.ForeignBodyId,
        second_bodies.destroyBody(body),
    );
    try std.testing.expectEqual(@as(u32, 0), second_bodies.bodyCount());
    try std.testing.expectEqual(@as(u32, 1), first_bodies.bodyCount());

    try first_bodies.destroyBody(body);
    try std.testing.expectError(
        error.InvalidBodyId,
        first_bodies.destroyBody(body),
    );
    try std.testing.expectEqual(@as(u32, 0), first_bodies.bodyCount());
}

fn batchHasObjectLine(
    batch: physics_debug.Batch,
    category: physics_debug.Category,
    object: physics_debug.ObjectRef,
) bool {
    for (batch.lines) |line| {
        if (line.category == category and line.object != null and
            std.meta.eql(line.object.?, object))
        {
            return true;
        }
    }
    return false;
}

fn expectShapeInsideObjectBounds(
    batch: physics_debug.Batch,
    object: physics_debug.ObjectRef,
) !void {
    var minimum = [3]f32{ std.math.inf(f32), std.math.inf(f32), std.math.inf(f32) };
    var maximum = [3]f32{ -std.math.inf(f32), -std.math.inf(f32), -std.math.inf(f32) };
    var bounds_found = false;
    for (batch.lines) |line| {
        if (line.category != .bounds or line.object == null or
            !std.meta.eql(line.object.?, object))
        {
            continue;
        }
        bounds_found = true;
        for (0..3) |axis| {
            minimum[axis] = @min(minimum[axis], @min(line.start[axis], line.end[axis]));
            maximum[axis] = @max(maximum[axis], @max(line.start[axis], line.end[axis]));
        }
    }
    try std.testing.expect(bounds_found);

    var shape_found = false;
    for (batch.lines) |line| {
        if (line.category != .shape or line.object == null or
            !std.meta.eql(line.object.?, object))
        {
            continue;
        }
        shape_found = true;
        for (0..3) |axis| {
            try std.testing.expect(line.start[axis] >= minimum[axis] - 0.01);
            try std.testing.expect(line.start[axis] <= maximum[axis] + 0.01);
            try std.testing.expect(line.end[axis] >= minimum[axis] - 0.01);
            try std.testing.expect(line.end[axis] <= maximum[axis] + 0.01);
        }
    }
    try std.testing.expect(shape_found);
}

test "renderer-neutral extraction covers rigid character vehicle and district evidence" {
    var physics = try Physics.init();
    defer physics.deinit();

    const ground = try physics.createStaticBox(.{ 0, -1, 0 }, .{ 100, 1, 100 });
    defer _ = physics.removeBody(ground);

    var district_bodies = physics.districtBodies();
    const district = try district_bodies.createStaticBox(.{
        .pose = .{ .position = .{ 15, 1, 0 } },
        .half_extents = .{ 2, 1, 3 },
    });
    defer district_bodies.destroyBody(district) catch unreachable;

    var crate_bodies = physics.crateBodies();
    const crate = try crate_bodies.createDynamicBox(.{
        .pose = .{ .position = .{ -4, 2, 0 } },
        .half_extents = .{ 0.5, 0.5, 0.5 },
    });
    defer crate_bodies.destroyBody(crate) catch unreachable;

    const sphere = try physics.createDynamicSphere(.{ 8, 2, 0 }, 0.6);
    defer _ = physics.removeBody(sphere);

    var characters = physics.characterControllers();
    const character = try characters.createCharacter(.{
        .position = .{ 4, 0.02, 0 },
    });
    defer characters.destroyCharacter(character) catch unreachable;

    var vehicle_api = physics.vehicles();
    const vehicle = try vehicle_api.createVehicle(.{
        .chassis = .{ .pose = .{ .position = .{ 0, 2, 5 } } },
    });
    defer vehicle_api.destroyVehicle(vehicle) catch unreachable;

    const delta_time: f32 = 1.0 / 120.0;
    for (0..300) |_| {
        _ = try characters.updateCharacter(
            character,
            .{ .velocity = .{ 0, 0, 0 } },
            delta_time,
        );
        try physics.update(delta_time);
    }

    const vehicle_state = try vehicle_api.vehicleState(vehicle);
    for (vehicle_state.wheels) |wheel| try std.testing.expect(wheel.has_contact);

    // Wake the settled crate into its support contact so the exact completed
    // step contains rigid listener evidence as well as CharacterVirtual and
    // wheel contacts. Sleeping rigid pairs do not issue persisted callbacks.
    try crate_bodies.applyImpulse(crate, .{ 0, -0.25, 0 });
    _ = try characters.updateCharacter(
        character,
        .{ .velocity = .{ 0, 0, 0 } },
        delta_time,
    );
    try physics.update(delta_time);

    var lines: [4_096]physics_debug.Line = undefined;
    var triangles: [512]physics_debug.Triangle = undefined;
    var storage = physics_debug.Storage.init(&lines, &triangles);
    const batch = physics.extractDebug(.{}, 301, &storage);

    try std.testing.expectEqual(@as(u64, 301), batch.completed_tick);
    try std.testing.expectEqual(@as(u64, 1), batch.generation);
    try std.testing.expect(batch.lines.len > 0);
    try std.testing.expect(batch.triangles.len > 0);
    inline for (.{
        physics_debug.Category.shape,
        physics_debug.Category.bounds,
        physics_debug.Category.contact,
        physics_debug.Category.center_of_mass,
        physics_debug.Category.velocity,
    }) |category| {
        try std.testing.expect(batch.statsFor(category).lines.admitted > 0);
    }
    try std.testing.expect(batch.statsFor(.shape).triangles.admitted > 0);

    const ground_ref = physics_debug.ObjectRef{
        .kind = debug_object_kinds.body,
        .serial = ground.serial,
    };
    const district_ref = physics_debug.ObjectRef{
        .kind = debug_object_kinds.body,
        .serial = district.serial,
    };
    const crate_ref = physics_debug.ObjectRef{
        .kind = debug_object_kinds.body,
        .serial = crate.serial,
    };
    const sphere_ref = physics_debug.ObjectRef{
        .kind = debug_object_kinds.body,
        .serial = sphere.serial,
    };
    const character_ref = physics_debug.ObjectRef{
        .kind = debug_object_kinds.character,
        .serial = character.serial,
    };
    const vehicle_ref = physics_debug.ObjectRef{
        .kind = debug_object_kinds.vehicle,
        .serial = vehicle.serial,
    };
    for ([_]physics_debug.ObjectRef{
        ground_ref,
        district_ref,
        crate_ref,
        sphere_ref,
        character_ref,
        vehicle_ref,
    }) |object| {
        try std.testing.expect(batchHasObjectLine(batch, .shape, object));
        try std.testing.expect(batchHasObjectLine(batch, .bounds, object));
        try std.testing.expect(batchHasObjectLine(batch, .center_of_mass, object));
        try std.testing.expect(batchHasObjectLine(batch, .velocity, object));
    }

    try expectShapeInsideObjectBounds(batch, ground_ref);
    try expectShapeInsideObjectBounds(batch, district_ref);
    try expectShapeInsideObjectBounds(batch, crate_ref);
    try expectShapeInsideObjectBounds(batch, sphere_ref);
    try expectShapeInsideObjectBounds(batch, character_ref);

    try std.testing.expect(batchHasObjectLine(batch, .contact, character_ref));
    try std.testing.expect(batchHasObjectLine(batch, .contact, vehicle_ref));
    var rigid_contact_found = false;
    for (batch.lines) |line| {
        if (line.category == .contact and line.object != null and
            line.object.?.kind == debug_object_kinds.body)
        {
            rigid_contact_found = true;
            break;
        }
    }
    try std.testing.expect(rigid_contact_found);
}

test "debug toggles and bounded overflow do not mutate authoritative physics" {
    var physics = try Physics.init();
    defer physics.deinit();
    const ground = try physics.createStaticBox(.{ 0, -1, 0 }, .{ 10, 1, 10 });
    defer _ = physics.removeBody(ground);
    const body = try physics.createDynamicBox(.{ 0, 1, 0 }, .{ 0.5, 0.5, 0.5 });
    defer _ = physics.removeBody(body);
    for (0..120) |_| try physics.update(1.0 / 120.0);

    const position_before = try physics.getBodyPosition(body);
    const rotation_before = try physics.getBodyRotation(body);
    const linear_before = try physics.getLinearVelocity(body);
    const angular_before = try physics.getAngularVelocity(body);
    const motion_before = try physics.getMotionType(body);
    const body_count_before = physics.getBodyCount();
    const active_count_before = physics.getActiveBodyCount();
    const contact_resources_before = contactDebugResourcesForTest(&physics).?;

    var lines: [1]physics_debug.Line = undefined;
    var triangles: [1]physics_debug.Triangle = undefined;
    var storage = physics_debug.Storage.init(&lines, &triangles);
    const disabled = DebugConfig{
        .shapes = false,
        .bounds = false,
        .contacts = false,
        .centers_of_mass = false,
        .velocities = false,
    };
    for (0..100) |index| {
        const enabled = index % 2 == 0;
        const batch = physics.extractDebug(
            if (enabled) DebugConfig{} else disabled,
            @intCast(index + 1),
            &storage,
        );
        if (enabled) {
            try std.testing.expect(batch.lines.len == 1);
            try std.testing.expect(batch.triangles.len == 1);
            var visible_overflow = false;
            for (batch.category_stats) |stats| {
                visible_overflow = visible_overflow or
                    stats.lines.overflow_dropped > 0 or
                    stats.triangles.overflow_dropped > 0;
            }
            try std.testing.expect(visible_overflow);
        } else {
            try std.testing.expectEqual(@as(usize, 0), batch.lines.len);
            try std.testing.expectEqual(@as(usize, 0), batch.triangles.len);
        }
    }
    try std.testing.expectEqual(@as(u64, 100), storage.batch().?.generation);
    const contact_resources_after = contactDebugResourcesForTest(&physics).?;
    try std.testing.expect(
        contact_resources_before.listener == contact_resources_after.listener,
    );
    try std.testing.expect(
        contact_resources_before.scratch == contact_resources_after.scratch,
    );
    try std.testing.expectEqual(position_before, try physics.getBodyPosition(body));
    try std.testing.expectEqual(rotation_before, try physics.getBodyRotation(body));
    try std.testing.expectEqual(linear_before, try physics.getLinearVelocity(body));
    try std.testing.expectEqual(angular_before, try physics.getAngularVelocity(body));
    try std.testing.expectEqual(motion_before, try physics.getMotionType(body));
    try std.testing.expectEqual(body_count_before, physics.getBodyCount());
    try std.testing.expectEqual(active_count_before, physics.getActiveBodyCount());
}

test "contact callback scratch reserves concurrently and reports saturation" {
    var scratch = ContactScratch{};
    const thread_count: usize = 4;
    const writes_per_thread: usize = rigid_contact_capacity / 2;
    const Context = struct {
        target: *ContactScratch,
        seed: u32,

        fn run(context: *@This()) void {
            for (0..writes_per_thread) |index| {
                const value: f32 = @floatFromInt(context.seed + @as(u32, @intCast(index)));
                context.target.append(.{
                    .body_a = context.seed,
                    .body_b = context.seed + 1,
                    .point = .{ value, 0, 0 },
                    .normal = .{ 0, 1, 0 },
                });
            }
        }
    };

    var contexts: [thread_count]Context = undefined;
    var threads: [thread_count]std.Thread = undefined;
    for (&threads, &contexts, 0..) |*thread, *context, index| {
        context.* = .{ .target = &scratch, .seed = @intCast(index * writes_per_thread) };
        thread.* = try std.Thread.spawn(.{}, Context.run, .{context});
    }
    for (&threads) |*thread| thread.join();

    try std.testing.expectEqual(rigid_contact_capacity, scratch.count());
    try std.testing.expectEqual(
        @as(u32, thread_count * writes_per_thread - rigid_contact_capacity),
        scratch.dropped.load(.acquire),
    );
    var seen = [_]bool{false} ** (thread_count * writes_per_thread);
    for (scratch.contacts[0..scratch.count()]) |*slot| {
        try std.testing.expect(slot.published.load(.acquire));
        const payload_index: usize = @intFromFloat(slot.contact.point[0]);
        try std.testing.expect(payload_index < seen.len);
        try std.testing.expect(!seen[payload_index]);
        seen[payload_index] = true;
        try std.testing.expectEqual([3]f32{ 0, 1, 0 }, slot.contact.normal);
    }
    scratch.reset();
    try std.testing.expectEqual(@as(usize, 0), scratch.count());
    try std.testing.expectEqual(@as(u32, 0), scratch.dropped.load(.acquire));
    for (&scratch.contacts) |*slot| {
        try std.testing.expect(!slot.published.load(.acquire));
    }
}

test "contact listener lifecycle survives repeated same-process worlds" {
    const leases_before = runtimeLeaseCount();
    for (0..6) |cycle| {
        var physics = try Physics.init();
        try std.testing.expectEqual(leases_before + 1, runtimeLeaseCount());
        const ground = try physics.createStaticBox(.{ 0, -1, 0 }, .{ 5, 1, 5 });
        const body = try physics.createDynamicBox(.{ 0, 0.75, 0 }, .{ 0.5, 0.5, 0.5 });
        var contact_observed = false;
        for (0..120) |_| {
            try physics.update(1.0 / 120.0);
            const resources = contactDebugResourcesForTest(&physics).?;
            if (resources.scratch.count() > 0) {
                contact_observed = true;
                break;
            }
        }
        try std.testing.expect(contact_observed);

        var lines: [512]physics_debug.Line = undefined;
        var triangles: [64]physics_debug.Triangle = undefined;
        var storage = physics_debug.Storage.init(&lines, &triangles);
        const batch = physics.extractDebug(.{}, @intCast(cycle + 1), &storage);
        try std.testing.expect(batch.statsFor(.contact).lines.admitted > 0);

        try std.testing.expect(physics.removeBody(body));
        try std.testing.expect(physics.removeBody(ground));
        physics.deinit();
        try std.testing.expectEqual(leases_before, runtimeLeaseCount());
    }
}

test "debug shape descriptors follow successful replacement only" {
    var physics = try Physics.init();
    defer physics.deinit();
    const body = try physics.createDynamicBox(.{ 0, 4, 0 }, .{ 0.5, 0.5, 0.5 });
    defer _ = physics.removeBody(body);
    try physics.update(1.0 / 60.0);

    try physics.setBoxHalfExtents(body, .{ 1, 2, 3 });
    const record_after_success = physics.body_handles.get(body.serial).?;
    try std.testing.expectEqual([3]f32{ 1, 2, 3 }, record_after_success.shape.box);
    try std.testing.expectError(
        error.InvalidHalfExtents,
        physics.setBoxHalfExtents(body, .{ 9, -1, 9 }),
    );
    const record_after_failure = physics.body_handles.get(body.serial).?;
    try std.testing.expectEqual([3]f32{ 1, 2, 3 }, record_after_failure.shape.box);
}
