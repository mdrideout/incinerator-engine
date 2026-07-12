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

pub const CharacterId = struct {
    world_token: u64,
    serial: u64,
};

pub const VehicleId = struct {
    world_token: u64,
    serial: u64,
};

const VehicleHandleRecord = struct {
    body_id: c.JPH_BodyID,
    constraint: *c.JPH_VehicleConstraint,
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

/// Deterministic checkpoints for testing cleanup across Jolt's real ownership
/// transitions. This stays private to the adapter: production callers cannot
/// request a partially initialized world.
const InitFailurePoint = enum {
    after_runtime_lease,
    after_job_and_temp_allocators,
    after_filter_bundle,
    after_physics_system_transfer,
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
    requested: ?InitFailurePoint,
    reached: InitFailurePoint,
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
    body_handles: std.AutoHashMap(u64, u32),
    character_handles: std.AutoHashMap(u64, *c.JPH_CharacterVirtual),
    vehicle_handles: std.AutoHashMap(u64, VehicleHandleRecord),
    next_body_serial: u64 = 1,
    next_character_serial: u64 = 1,
    next_vehicle_serial: u64 = 1,

    pub fn init() !Physics {
        return initWithAllocator(std.heap.page_allocator);
    }

    pub fn initWithAllocator(allocator: std.mem.Allocator) !Physics {
        return initWithAllocatorAndFailurePoint(allocator, null);
    }

    fn initWithAllocatorAndFailurePoint(
        allocator: std.mem.Allocator,
        failure_point: ?InitFailurePoint,
    ) !Physics {
        const world_token = try acquireRuntimeLease();
        errdefer releaseRuntimeLease();
        try failInitAt(failure_point, .after_runtime_lease);

        const job_system = c.JPH_JobSystemThreadPool_Create(null) orelse
            return error.JobSystemCreationFailed;
        errdefer c.JPH_JobSystem_Destroy(job_system);

        const temp_allocator = c.JPH_TempAllocator_Create(temp_allocator_bytes) orelse
            return error.TempAllocatorCreationFailed;
        errdefer c.JPH_TempAllocator_Destroy(temp_allocator);
        try failInitAt(failure_point, .after_job_and_temp_allocators);

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
        try failInitAt(failure_point, .after_filter_bundle);

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
        try failInitAt(failure_point, .after_physics_system_transfer);

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
            .body_handles = std.AutoHashMap(u64, u32).init(allocator),
            .character_handles = std.AutoHashMap(u64, *c.JPH_CharacterVirtual).init(allocator),
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
        const mapped_raw = self.body_handles.get(body_id.serial) orelse
            return error.InvalidBodyId;
        if (mapped_raw != body_id.value) return error.InvalidBodyId;
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
        return self.character_handles.get(character_id.serial) orelse
            error.InvalidCharacterId;
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
        self.character_handles.putAssumeCapacityNoClobber(serial, character);
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
        failure_point: ?VehicleCreateFailurePoint,
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
        try injectVehicleCreateFailure(failure_point, .after_body);

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
        try injectVehicleCreateFailure(failure_point, .after_settings);

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
        try injectVehicleCreateFailure(failure_point, .after_constraint);

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
        try injectVehicleCreateFailure(failure_point, .after_collision_tester);

        c.JPH_PhysicsSystem_AddConstraint(self.system, @ptrCast(constraint));
        constraint_added = true;
        c.JPH_PhysicsSystem_AddStepListener(
            self.system,
            c.JPH_VehicleConstraint_AsPhysicsStepListener(constraint),
        );
        listener_added = true;
        try injectVehicleCreateFailure(failure_point, .after_registration);

        const serial = self.next_vehicle_serial;
        self.vehicle_handles.putAssumeCapacityNoClobber(serial, .{
            .body_id = raw_body_id,
            .constraint = constraint,
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

    pub fn activeBodyCount(self: *CrateBodies) u32 {
        return self.physics.getActiveBodyCount();
    }
};

/// Compile-time capability consumed by the character vertical slice. Virtual
/// character allocation and Jolt query details remain private to this adapter.
pub const CharacterControllers = struct {
    physics: *Physics,

    pub const Handle = CharacterId;

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
    requested: ?VehicleCreateFailurePoint,
    reached: VehicleCreateFailurePoint,
) !void {
    if (requested == reached) return error.InjectedVehicleCreateFailure;
}

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

    for (failure_points) |failure_point| {
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
    };

    for (failure_points) |failure_point| {
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
