//! Lightweight non-authoritative client state. It owns no Flecs world, Jolt
//! body, durable state, or gameplay decision.

const std = @import("std");
const engine_transform = @import("engine_contracts").transform;
const budgets = @import("session_budgets");
const identity = @import("session_identity");
const protocol = @import("session_protocol");

pub const Entry = struct {
    previous: protocol.CharacterState,
    current: protocol.CharacterState,
};

pub const VehicleEntry = struct {
    previous: protocol.VehicleState,
    current: protocol.VehicleState,
    previous_tick: u64 = 0,
    current_tick: u64 = 0,
};

pub const CarryableEntry = struct {
    previous: protocol.CarryableState,
    current: protocol.CarryableState,
};

pub const NpcEntry = struct {
    previous: protocol.NpcState,
    current: protocol.NpcState,
};

pub const NpcPresentationSeparation = struct {
    state: protocol.NpcState,
    correction_distance: f32 = 0,
};

/// Sparse remote NPC interpolation can lag a local avatar even when authority
/// has valid physical contact. Preserve the two authoritative radii in the
/// presentation plan so depth cannot make the local avatar, including its
/// retained dead projection, appear to be consumed by an NPC. The returned
/// correction remains explicit for validation/diagnostics; no authority or
/// replicated state is mutated.
pub fn separateNpcPresentation(
    npc: protocol.NpcState,
    local_character: protocol.CharacterState,
    npc_radius: f32,
    character_radius: f32,
) NpcPresentationSeparation {
    const minimum = npc_radius + character_radius;
    const dx = npc.position[0] - local_character.position[0];
    const dz = npc.position[2] - local_character.position[2];
    const distance_squared = dx * dx + dz * dz;
    if (distance_squared >= minimum * minimum) return .{ .state = npc };

    var result = npc;
    const distance = @sqrt(distance_squared);
    const correction = minimum - distance;
    if (distance > std.math.floatEps(f32)) {
        result.position[0] += dx / distance * correction;
        result.position[2] += dz / distance * correction;
    } else {
        // Exact coincidence has no geometric normal. Replicated identity gives
        // every client the same stable escape axis.
        const direction: f32 = if ((npc.entity.index & 1) == 0) 1 else -1;
        result.position[0] += direction * minimum;
    }
    return .{ .state = result, .correction_distance = correction };
}

/// Selects which independently scheduled projection lanes advance when a
/// materialized snapshot is applied. The common lanes are present in every
/// snapshot; NPC state may intentionally retain its existing interpolation
/// endpoints until the next lower-frequency NPC update.
pub const ApplyLanes = struct {
    npcs: bool,
};

/// Presentation clocks follow snapshots that were actually admitted into the
/// replicated world. The common and NPC lanes advance independently because
/// the authority deliberately publishes them at different rates.
pub const PresentationTimeline = struct {
    common_sequence: identity.SnapshotSequence = .{ .value = 0 },
    npc_sequence: identity.SnapshotSequence = .{ .value = 0 },
    common_last_ns: u64 = 0,
    npc_last_ns: u64 = 0,
    common_interval_ns: u64 = std.time.ns_per_s / budgets.snapshot_hz,
    npc_interval_ns: u64 = std.time.ns_per_s / budgets.npc_snapshot_hz,
    common_observed: bool = false,
    npc_observed: bool = false,

    pub fn observeAppliedWorld(
        self: *PresentationTimeline,
        world: *const World,
        now_ns: u64,
    ) void {
        if (!world.initialized) return;
        if (!self.common_observed or
            !std.meta.eql(self.common_sequence, world.sequence))
        {
            observeLane(
                &self.common_last_ns,
                &self.common_interval_ns,
                self.common_observed,
                now_ns,
            );
            self.common_sequence = world.sequence;
            self.common_observed = true;
        }
        if (world.npc_initialized and
            (!self.npc_observed or !std.meta.eql(self.npc_sequence, world.npc_sequence)))
        {
            observeLane(
                &self.npc_last_ns,
                &self.npc_interval_ns,
                self.npc_observed,
                now_ns,
            );
            self.npc_sequence = world.npc_sequence;
            self.npc_observed = true;
        }
    }

    pub fn commonAlpha(self: *const PresentationTimeline, now_ns: u64) f32 {
        return laneAlpha(
            self.common_observed,
            self.common_last_ns,
            self.common_interval_ns,
            now_ns,
        );
    }

    pub fn npcAlpha(self: *const PresentationTimeline, now_ns: u64) f32 {
        return laneAlpha(
            self.npc_observed,
            self.npc_last_ns,
            self.npc_interval_ns,
            now_ns,
        );
    }

    fn observeLane(
        last_ns: *u64,
        interval_ns: *u64,
        already_observed: bool,
        now_ns: u64,
    ) void {
        if (already_observed and now_ns > last_ns.*) {
            interval_ns.* = now_ns - last_ns.*;
        }
        last_ns.* = now_ns;
    }

    fn laneAlpha(
        observed: bool,
        last_ns: u64,
        interval_ns: u64,
        now_ns: u64,
    ) f32 {
        if (!observed or interval_ns == 0) return 1;
        const elapsed = now_ns -| last_ns;
        return @as(f32, @floatFromInt(elapsed)) /
            @as(f32, @floatFromInt(interval_ns));
    }
};

pub const World = struct {
    entries: [budgets.max_participants]Entry = undefined,
    character_count: u8 = 0,
    vehicles: [budgets.max_vehicles]VehicleEntry = undefined,
    vehicle_count: u8 = 0,
    carryables: [budgets.max_carryables]CarryableEntry = undefined,
    carryable_count: u8 = 0,
    npcs: [budgets.max_npcs]NpcEntry = undefined,
    npc_count: u8 = 0,
    server_tick: u64 = 0,
    sequence: identity.SnapshotSequence = .{ .value = 0 },
    npc_sequence: identity.SnapshotSequence = .{ .value = 0 },
    npc_server_tick: u64 = 0,
    npc_initialized: bool = false,
    initialized: bool = false,
    stale_snapshots: u64 = 0,

    pub fn apply(self: *World, snapshot: protocol.Snapshot) !void {
        return self.applyLanes(snapshot, .{ .npcs = snapshot.npc_update });
    }

    pub fn applyLanes(
        self: *World,
        snapshot: protocol.Snapshot,
        lanes: ApplyLanes,
    ) !void {
        // Transport validation is the primary trust boundary, but this owner is
        // also a public state container. Revalidate complete projections here
        // so a direct caller cannot install ambiguous replicated identities.
        try protocol.validateMaterializedSnapshot(snapshot);
        if (snapshot.character_count > budgets.max_participants) return error.TooManyCharacters;
        if (snapshot.vehicle_count > budgets.max_vehicles) return error.TooManyVehicles;
        if (snapshot.carryable_count > budgets.max_carryables) return error.TooManyCarryables;
        if (snapshot.npc_count > budgets.max_npcs) return error.TooManyNpcs;
        if (lanes.npcs and !snapshot.npc_update) return error.NpcProjectionUnavailable;
        if (self.initialized and !snapshot.sequence.newerThan(self.sequence)) {
            self.stale_snapshots +|= 1;
            return error.StaleSnapshot;
        }

        var next: [budgets.max_participants]Entry = undefined;
        for (snapshot.slice(), 0..) |character, index| {
            try character.entity.validate();
            try character.owner.validate();
            try validateFinite(character);
            const previous = self.find(character.entity) orelse character;
            next[index] = .{ .previous = previous, .current = character };
        }
        var next_vehicles: [budgets.max_vehicles]VehicleEntry = undefined;
        for (snapshot.vehicleSlice(), 0..) |vehicle, index| {
            try vehicle.entity.validate();
            if (vehicle.driver) |driver| try driver.validate();
            try validateVehicleFinite(vehicle);
            if (self.findVehicleEntry(vehicle.entity)) |previous| {
                next_vehicles[index] = .{
                    .previous = previous.current,
                    .current = vehicle,
                    .previous_tick = previous.current_tick,
                    .current_tick = snapshot.server_tick,
                };
            } else {
                next_vehicles[index] = .{
                    .previous = vehicle,
                    .current = vehicle,
                    .previous_tick = snapshot.server_tick,
                    .current_tick = snapshot.server_tick,
                };
            }
        }
        var next_carryables: [budgets.max_carryables]CarryableEntry = undefined;
        for (snapshot.carryableSlice(), 0..) |carryable, index| {
            try carryable.entity.validate();
            if (carryable.holder) |holder| try holder.validate();
            try validateCarryableFinite(carryable);
            const previous = self.findCarryable(carryable.entity) orelse carryable;
            next_carryables[index] = .{ .previous = previous, .current = carryable };
        }
        var next_npcs: [budgets.max_npcs]NpcEntry = undefined;
        if (lanes.npcs) for (snapshot.npcSlice(), 0..) |npc, index| {
            try npc.entity.validate();
            try validateNpcFinite(npc);
            const previous = self.findNpc(npc.entity) orelse npc;
            next_npcs[index] = .{ .previous = previous, .current = npc };
        };
        self.entries = next;
        self.character_count = snapshot.character_count;
        self.vehicles = next_vehicles;
        self.vehicle_count = snapshot.vehicle_count;
        self.carryables = next_carryables;
        self.carryable_count = snapshot.carryable_count;
        if (lanes.npcs) {
            self.npcs = next_npcs;
            self.npc_count = snapshot.npc_count;
            self.npc_sequence = snapshot.sequence;
            self.npc_server_tick = snapshot.server_tick;
            self.npc_initialized = true;
        }
        self.server_tick = snapshot.server_tick;
        self.sequence = snapshot.sequence;
        self.initialized = true;
    }

    pub fn slice(self: *const World) []const Entry {
        return self.entries[0..self.character_count];
    }

    pub fn vehicleSlice(self: *const World) []const VehicleEntry {
        return self.vehicles[0..self.vehicle_count];
    }

    pub fn carryableSlice(self: *const World) []const CarryableEntry {
        return self.carryables[0..self.carryable_count];
    }

    pub fn npcSlice(self: *const World) []const NpcEntry {
        return self.npcs[0..self.npc_count];
    }

    pub fn find(self: *const World, id: identity.ReplicatedEntityId) ?protocol.CharacterState {
        for (self.slice()) |entry| {
            if (std.meta.eql(entry.current.entity, id)) return entry.current;
        }
        return null;
    }

    pub fn findVehicle(
        self: *const World,
        id: identity.ReplicatedEntityId,
    ) ?protocol.VehicleState {
        return if (self.findVehicleEntry(id)) |entry| entry.current else null;
    }

    pub fn findCarryable(
        self: *const World,
        id: identity.ReplicatedEntityId,
    ) ?protocol.CarryableState {
        for (self.carryableSlice()) |entry| {
            if (std.meta.eql(entry.current.entity, id)) return entry.current;
        }
        return null;
    }

    pub fn findNpc(
        self: *const World,
        id: identity.ReplicatedEntityId,
    ) ?protocol.NpcState {
        for (self.npcSlice()) |entry| {
            if (std.meta.eql(entry.current.entity, id)) return entry.current;
        }
        return null;
    }

    pub fn interpolate(entry: Entry, alpha: f32) protocol.CharacterState {
        const t = std.math.clamp(alpha, 0, 1);
        var result = entry.current;
        for (&result.position, entry.previous.position, entry.current.position) |
            *out,
            previous,
            current,
        | out.* = previous + (current - previous) * t;
        for (&result.velocity, entry.previous.velocity, entry.current.velocity) |
            *out,
            previous,
            current,
        | out.* = previous + (current - previous) * t;
        result.facing_yaw = engine_transform.interpolateFacingYaw(
            entry.previous.facing_yaw,
            entry.current.facing_yaw,
            t,
        ) catch unreachable;
        return result;
    }

    pub fn interpolateVehicle(entry: VehicleEntry, alpha: f32) protocol.VehicleState {
        const t = std.math.clamp(alpha, 0, 1);
        var result = entry.current;
        for (&result.position, entry.previous.position, entry.current.position) |
            *out,
            previous,
            current,
        | out.* = previous + (current - previous) * t;
        for (&result.linear_velocity, entry.previous.linear_velocity, entry.current.linear_velocity) |
            *out,
            previous,
            current,
        | out.* = previous + (current - previous) * t;
        for (&result.angular_velocity, entry.previous.angular_velocity, entry.current.angular_velocity) |
            *out,
            previous,
            current,
        | out.* = previous + (current - previous) * t;
        result.rotation = interpolateQuaternion(entry.previous.rotation, entry.current.rotation, t);
        const interval_ticks = entry.current_tick -| entry.previous_tick;
        for (&result.wheels, entry.previous.wheels, entry.current.wheels) |
            *out,
            previous,
            current,
        | out.* = interpolateVehicleWheel(previous, current, interval_ticks, t);
        return result;
    }

    fn findVehicleEntry(
        self: *const World,
        id: identity.ReplicatedEntityId,
    ) ?VehicleEntry {
        for (self.vehicleSlice()) |entry| {
            if (std.meta.eql(entry.current.entity, id)) return entry;
        }
        return null;
    }

    pub fn interpolateCarryable(entry: CarryableEntry, alpha: f32) protocol.CarryableState {
        const t = std.math.clamp(alpha, 0, 1);
        var result = entry.current;
        for (&result.position, entry.previous.position, entry.current.position) |
            *out,
            previous,
            current,
        | out.* = previous + (current - previous) * t;
        for (&result.linear_velocity, entry.previous.linear_velocity, entry.current.linear_velocity) |
            *out,
            previous,
            current,
        | out.* = previous + (current - previous) * t;
        for (&result.angular_velocity, entry.previous.angular_velocity, entry.current.angular_velocity) |
            *out,
            previous,
            current,
        | out.* = previous + (current - previous) * t;
        result.rotation = interpolateQuaternion(entry.previous.rotation, entry.current.rotation, t);
        return result;
    }

    pub fn interpolateNpc(entry: NpcEntry, alpha: f32) protocol.NpcState {
        const t = std.math.clamp(alpha, 0, 1);
        var result = entry.current;
        for (&result.position, entry.previous.position, entry.current.position) |
            *out,
            previous,
            current,
        | out.* = previous + (current - previous) * t;
        for (&result.velocity, entry.previous.velocity, entry.current.velocity) |
            *out,
            previous,
            current,
        | out.* = previous + (current - previous) * t;
        result.facing_yaw = engine_transform.interpolateFacingYaw(
            entry.previous.facing_yaw,
            entry.current.facing_yaw,
            t,
        ) catch unreachable;
        return result;
    }
};

fn validateFinite(character: protocol.CharacterState) !void {
    for (character.position ++ character.velocity ++ .{character.facing_yaw}) |value| {
        if (!std.math.isFinite(value)) return error.NonFiniteReplicatedState;
    }
}

fn validateVehicleFinite(vehicle: protocol.VehicleState) !void {
    for (vehicle.position ++ vehicle.rotation ++ vehicle.linear_velocity ++
        vehicle.angular_velocity) |value|
    {
        if (!std.math.isFinite(value)) return error.NonFiniteReplicatedState;
    }
    _ = try normalizedQuaternion(vehicle.rotation);
    for (vehicle.wheels) |wheel| try wheel.validate();
}

fn validateCarryableFinite(carryable: protocol.CarryableState) !void {
    for (carryable.position ++ carryable.rotation ++ carryable.linear_velocity ++
        carryable.angular_velocity ++ carryable.half_extents) |value|
    {
        if (!std.math.isFinite(value)) return error.NonFiniteReplicatedState;
    }
    for (carryable.half_extents) |extent| {
        if (extent <= 0) return error.InvalidCarryableExtents;
    }
    _ = try normalizedQuaternion(carryable.rotation);
}

fn validateNpcFinite(npc: protocol.NpcState) !void {
    for (npc.position ++ npc.velocity ++ .{npc.facing_yaw}) |value| {
        if (!std.math.isFinite(value)) return error.NonFiniteReplicatedState;
    }
}

fn interpolateQuaternion(previous: [4]f32, current: [4]f32, alpha: f32) [4]f32 {
    const from = normalizedQuaternion(previous) catch unreachable;
    var to = normalizedQuaternion(current) catch unreachable;
    if (quaternionDot(from, to) < 0) {
        for (&to) |*component| component.* = -component.*;
    }
    const inverse = 1 - alpha;
    return normalizedQuaternion(.{
        from[0] * inverse + to[0] * alpha,
        from[1] * inverse + to[1] * alpha,
        from[2] * inverse + to[2] * alpha,
        from[3] * inverse + to[3] * alpha,
    }) catch unreachable;
}

fn interpolateVehicleWheel(
    previous: protocol.VehicleWheelState,
    current: protocol.VehicleWheelState,
    interval_ticks: u64,
    alpha: f32,
) protocol.VehicleWheelState {
    const tick_seconds = @as(f64, @floatFromInt(interval_ticks)) /
        @as(f64, @floatFromInt(budgets.authority_tick_hz));
    const expected_delta = (@as(f64, previous.angular_velocity) +
        @as(f64, current.angular_velocity)) * 0.5 * tick_seconds;
    const raw_delta = @as(f64, current.spin_phase) - @as(f64, previous.spin_phase);
    const turns = @round((expected_delta - raw_delta) / std.math.tau);
    const unwrapped_delta = raw_delta + turns * std.math.tau;
    const phase = canonicalWheelPhase(
        @as(f64, previous.spin_phase) + unwrapped_delta * @as(f64, alpha),
    );
    return .{
        .spin_phase = phase,
        .angular_velocity = lerp(previous.angular_velocity, current.angular_velocity, alpha),
        .steer_angle = lerp(previous.steer_angle, current.steer_angle, alpha),
        .suspension_length = lerp(
            previous.suspension_length,
            current.suspension_length,
            alpha,
        ),
        .has_contact = current.has_contact,
    };
}

fn canonicalWheelPhase(value: f64) f32 {
    const canonical_tau = @as(f32, std.math.tau);
    const wrapped = @mod(value, @as(f64, canonical_tau));
    const narrowed: f32 = @floatCast(wrapped);
    return if (narrowed == 0 or narrowed >= canonical_tau) 0 else narrowed;
}

fn lerp(previous: f32, current: f32, alpha: f32) f32 {
    return previous + (current - previous) * alpha;
}

/// Preserve the disposable locally predicted chassis while retaining the
/// authoritative/interpolated wheel presentation and confirmed ownership.
pub fn applyPredictedChassis(
    interpolated: protocol.VehicleState,
    predicted: protocol.VehicleState,
) protocol.VehicleState {
    var result = interpolated;
    result.position = predicted.position;
    result.rotation = predicted.rotation;
    result.linear_velocity = predicted.linear_velocity;
    result.angular_velocity = predicted.angular_velocity;
    return result;
}

pub const VehicleWheelLayout = struct {
    attachment_positions: [protocol.vehicle_wheel_count][3]f32,
    suspension_direction: [3]f32 = .{ 0, -1, 0 },
    radius: f32,
    width: f32,
    suspension_max_length: f32,
    max_steer_radians: f32,

    pub fn validate(self: VehicleWheelLayout) !void {
        for (self.attachment_positions) |position| try validateFiniteVector(position);
        try validateFiniteVector(self.suspension_direction);
        const suspension_length_squared = dot3(
            self.suspension_direction,
            self.suspension_direction,
        );
        if (@abs(suspension_length_squared - 1) > 0.0001) {
            return error.InvalidVehicleSuspensionDirection;
        }
        if (!std.math.isFinite(self.radius) or self.radius <= 0) {
            return error.InvalidVehicleWheelRadius;
        }
        if (!std.math.isFinite(self.width) or self.width <= 0) {
            return error.InvalidVehicleWheelWidth;
        }
        if (!std.math.isFinite(self.suspension_max_length) or
            self.suspension_max_length < 0 or
            self.suspension_max_length > protocol.max_vehicle_wheel_suspension_length)
        {
            return error.InvalidVehicleSuspensionRange;
        }
        if (!std.math.isFinite(self.max_steer_radians) or
            self.max_steer_radians <= 0 or
            self.max_steer_radians >= protocol.max_vehicle_wheel_steer_angle)
        {
            return error.InvalidVehicleSteerAngle;
        }
    }
};

/// Current single-archetype client layout. The content cohort keeps this in
/// lockstep with VehicleTuning until vehicle archetype identity is projected.
pub const default_vehicle_wheel_layout = VehicleWheelLayout{
    .attachment_positions = .{
        .{ -0.8, -0.18, -1.4 },
        .{ 0.8, -0.18, -1.4 },
        .{ -0.8, -0.18, 1.4 },
        .{ 0.8, -0.18, 1.4 },
    },
    .radius = 0.3,
    .width = 0.2,
    .suspension_max_length = 0.5,
    .max_steer_radians = std.math.degreesToRadians(30),
};

pub const WheelPose = struct {
    position: [3]f32,
    rotation: [4]f32,
};

/// Compose canonical +X-axle wheel model poses from a presented chassis and
/// compact replicated wheel state. This is the one pure path used by embedded
/// solo and graphical network clients.
pub fn composeVehicleWheelPoses(
    vehicle: protocol.VehicleState,
    layout: VehicleWheelLayout,
) ![protocol.vehicle_wheel_count]WheelPose {
    try validateVehicleFinite(vehicle);
    try layout.validate();
    const chassis_rotation = try normalizedQuaternion(vehicle.rotation);
    var result: [protocol.vehicle_wheel_count]WheelPose = undefined;
    for (&result, layout.attachment_positions, vehicle.wheels) |
        *pose,
        attachment,
        wheel,
    | {
        if (wheel.suspension_length > layout.suspension_max_length + 0.0001) {
            return error.VehicleWheelSuspensionExceedsLayout;
        }
        if (@abs(wheel.steer_angle) > layout.max_steer_radians + 0.0001) {
            return error.VehicleWheelSteeringExceedsLayout;
        }
        const suspension_offset = scale3(
            layout.suspension_direction,
            wheel.suspension_length,
        );
        const local_position = add3(attachment, suspension_offset);
        const world_offset = rotateVector(chassis_rotation, local_position);
        // Positive engine steering turns toward +X from local -Z, which is a
        // negative right-handed rotation about +Y. Spin remains about model +X.
        const steer_rotation = axisAngleY(-wheel.steer_angle);
        const spin_rotation = axisAngleX(wheel.spin_phase);
        const position = add3(vehicle.position, world_offset);
        try validateFiniteVector(position);
        pose.* = .{
            .position = position,
            .rotation = try normalizedQuaternion(quaternionMultiply(
                quaternionMultiply(chassis_rotation, steer_rotation),
                spin_rotation,
            )),
        };
    }
    return result;
}

fn validateFiniteVector(value: [3]f32) !void {
    for (value) |component| {
        if (!std.math.isFinite(component)) return error.NonFiniteVehicleWheelLayout;
    }
}

fn quaternionMultiply(a: [4]f32, b: [4]f32) [4]f32 {
    return .{
        a[3] * b[0] + a[0] * b[3] + a[1] * b[2] - a[2] * b[1],
        a[3] * b[1] - a[0] * b[2] + a[1] * b[3] + a[2] * b[0],
        a[3] * b[2] + a[0] * b[1] - a[1] * b[0] + a[2] * b[3],
        a[3] * b[3] - a[0] * b[0] - a[1] * b[1] - a[2] * b[2],
    };
}

fn axisAngleX(angle: f32) [4]f32 {
    const half = angle * 0.5;
    return .{ @sin(half), 0, 0, @cos(half) };
}

fn axisAngleY(angle: f32) [4]f32 {
    const half = angle * 0.5;
    return .{ 0, @sin(half), 0, @cos(half) };
}

fn rotateVector(rotation: [4]f32, value: [3]f32) [3]f32 {
    const vector = [3]f32{ rotation[0], rotation[1], rotation[2] };
    const doubled_cross = scale3(cross3(vector, value), 2);
    return add3(
        add3(value, scale3(doubled_cross, rotation[3])),
        cross3(vector, doubled_cross),
    );
}

fn add3(a: [3]f32, b: [3]f32) [3]f32 {
    return .{ a[0] + b[0], a[1] + b[1], a[2] + b[2] };
}

fn scale3(value: [3]f32, scalar: f32) [3]f32 {
    return .{ value[0] * scalar, value[1] * scalar, value[2] * scalar };
}

fn dot3(a: [3]f32, b: [3]f32) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

fn cross3(a: [3]f32, b: [3]f32) [3]f32 {
    return .{
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    };
}

fn normalizedQuaternion(value: [4]f32) ![4]f32 {
    var scale: f32 = 0;
    for (value) |component| scale = @max(scale, @abs(component));
    if (!std.math.isFinite(scale) or scale == 0) return error.DegenerateQuaternion;
    const scaled = [4]f32{
        value[0] / scale,
        value[1] / scale,
        value[2] / scale,
        value[3] / scale,
    };
    const length = @sqrt(quaternionDot(scaled, scaled));
    if (!std.math.isFinite(length) or length == 0) return error.DegenerateQuaternion;
    return .{
        scaled[0] / length,
        scaled[1] / length,
        scaled[2] / length,
        scaled[3] / length,
    };
}

fn quaternionDot(a: [4]f32, b: [4]f32) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2] + a[3] * b[3];
}

test "replicated world replaces membership and retains interpolation history" {
    var world = World{};
    var first = protocol.Snapshot.empty();
    first.sequence.value = 1;
    first.server_tick = 3;
    first.character_count = 1;
    first.characters[0] = .{
        .entity = .{ .index = 1, .generation = 1 },
        .owner = .{ .index = 1, .generation = 1 },
        .position = .{ 0, 0, 0 },
        .velocity = .{ 1, 0, 0 },
        .facing_yaw = @as(f32, std.math.pi - 0.1),
    };
    try world.apply(first);
    var second = first;
    second.sequence.value = 2;
    second.server_tick = 6;
    second.characters[0].position[0] = 2;
    second.characters[0].facing_yaw = @as(f32, -std.math.pi + 0.1);
    try world.apply(second);
    const midpoint = World.interpolate(world.slice()[0], 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 1), midpoint.position[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, -std.math.pi), midpoint.facing_yaw, 0.0001);
    try std.testing.expectError(error.StaleSnapshot, world.apply(first));
}

test "replicated world defensively rejects duplicate projection identities" {
    const duplicate = identity.ReplicatedEntityId{ .index = 5, .generation = 1 };
    var snapshot = protocol.Snapshot.empty();
    snapshot.sequence.value = 1;
    snapshot.character_count = 1;
    snapshot.characters[0] = .{
        .entity = duplicate,
        .owner = .{ .index = 1, .generation = 1 },
        .position = .{ 0, 0, 0 },
        .velocity = .{ 0, 0, 0 },
        .facing_yaw = 0,
    };
    snapshot.vehicle_count = 1;
    snapshot.vehicles[0] = .{
        .entity = duplicate,
        .position = .{ 0, 1, 0 },
        .rotation = .{ 0, 0, 0, 1 },
        .linear_velocity = .{ 0, 0, 0 },
        .angular_velocity = .{ 0, 0, 0 },
        .driver = null,
    };

    var world = World{};
    try std.testing.expectError(
        error.DuplicateActiveProjectionEntity,
        world.apply(snapshot),
    );
    try std.testing.expect(!world.initialized);
    try std.testing.expectEqual(@as(u8, 0), world.character_count);
    try std.testing.expectEqual(@as(u8, 0), world.vehicle_count);
}

test "replicated world rejects invalid projection physics without mutation" {
    var initial = protocol.Snapshot.empty();
    initial.sequence.value = 1;
    initial.character_count = 1;
    initial.characters[0] = .{
        .entity = .{ .index = 1, .generation = 1 },
        .owner = .{ .index = 1, .generation = 1 },
        .position = .{ 1, 0, 0 },
        .velocity = .{ 0, 0, 0 },
        .facing_yaw = 0,
    };
    var world = World{};
    try world.apply(initial);

    var invalid = protocol.Snapshot.empty();
    invalid.sequence.value = 2;
    invalid.vehicle_count = 1;
    invalid.vehicles[0] = .{
        .entity = .{ .index = 17, .generation = 1 },
        .position = .{ 0, 1, 0 },
        .rotation = .{ 0, 0, 0, 0 },
        .linear_velocity = .{ 0, 0, 0 },
        .angular_velocity = .{ 0, 0, 0 },
        .driver = null,
    };
    try std.testing.expectError(error.DegenerateQuaternion, world.apply(invalid));
    try std.testing.expectEqual(initial.sequence, world.sequence);
    try std.testing.expectEqual(@as(u8, 1), world.character_count);
    try std.testing.expectEqual(@as(u8, 0), world.vehicle_count);
    try std.testing.expectEqualDeep(initial.characters[0], world.slice()[0].current);

    invalid.vehicles[0].rotation = .{ 0, 0, 0, 1 };
    invalid.vehicles[0].wheels[0].suspension_length = -0.1;
    try std.testing.expectError(
        error.InvalidVehicleWheelSuspension,
        world.apply(invalid),
    );
    try std.testing.expectEqual(initial.sequence, world.sequence);

    invalid.vehicle_count = 0;
    invalid.carryable_count = 1;
    invalid.carryables[0] = .{
        .entity = .{ .index = 21, .generation = 1 },
        .position = .{ 0, 0.5, 0 },
        .rotation = .{ 0, 0, 0, 1 },
        .linear_velocity = .{ 0, 0, 0 },
        .angular_velocity = .{ 0, 0, 0 },
        .half_extents = .{ 0.25, -0.25, 0.25 },
        .holder = null,
    };
    try std.testing.expectError(error.InvalidCarryableExtents, world.apply(invalid));
    try std.testing.expectEqual(initial.sequence, world.sequence);
    try std.testing.expectEqual(@as(u8, 0), world.carryable_count);
}

test "replicated world interpolates vehicle pose and replaces dynamic ownership" {
    var world = World{};
    var first = protocol.Snapshot.empty();
    first.sequence.value = 1;
    first.server_tick = 30;
    first.vehicle_count = 1;
    first.vehicles[0] = .{
        .entity = .{ .index = 17, .generation = 1 },
        .position = .{ 0, 1, 0 },
        .rotation = .{ 0, 0, 0, 1 },
        .linear_velocity = .{ 0, 0, -1 },
        .angular_velocity = .{ 0, 0, 0 },
        .driver = null,
    };
    first.vehicles[0].wheels[0] = .{
        .spin_phase = 5.5,
        .angular_velocity = 100,
        .steer_angle = 0.1,
        .suspension_length = 0.2,
        .has_contact = false,
    };
    try world.apply(first);
    var second = first;
    second.sequence.value = 2;
    second.server_tick = 33;
    second.vehicles[0].position[2] = -4;
    second.vehicles[0].driver = .{ .index = 1, .generation = 1 };
    second.vehicles[0].wheels[0] = .{
        .spin_phase = @mod(@as(f32, 5.5 + 5.0), std.math.tau),
        .angular_velocity = 100,
        .steer_angle = 0.5,
        .suspension_length = 0.4,
        .has_contact = true,
    };
    try world.apply(second);
    const midpoint = World.interpolateVehicle(world.vehicleSlice()[0], 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, -2), midpoint.position[2], 0.0001);
    try std.testing.expectEqual(second.vehicles[0].driver, midpoint.driver);
    try std.testing.expectApproxEqAbs(
        @mod(@as(f32, 5.5 + 2.5), std.math.tau),
        midpoint.wheels[0].spin_phase,
        0.0001,
    );
    try std.testing.expectApproxEqAbs(@as(f32, 0.3), midpoint.wheels[0].steer_angle, 0.0001);
    try std.testing.expectApproxEqAbs(
        @as(f32, 0.3),
        midpoint.wheels[0].suspension_length,
        0.0001,
    );
    try std.testing.expect(midpoint.wheels[0].has_contact);
}

test "wheel phase interpolation remains canonical at floating point wrap boundaries" {
    const canonical_tau = @as(f32, std.math.tau);
    const below_tau: f32 = @bitCast(@as(u32, @bitCast(canonical_tau)) - 1);
    try std.testing.expectEqual(
        @as(u32, 0),
        @as(u32, @bitCast(canonicalWheelPhase(-0.00000001))),
    );
    try std.testing.expectEqual(
        @as(u32, 0),
        @as(u32, @bitCast(canonicalWheelPhase(@as(f64, canonical_tau) - 0.00000001))),
    );

    const slow_reverse = interpolateVehicleWheel(
        .{ .spin_phase = 0, .angular_velocity = -0.00001 },
        .{ .spin_phase = below_tau, .angular_velocity = -0.00001 },
        3,
        0.01,
    );
    try slow_reverse.validate();
    const slow_forward = interpolateVehicleWheel(
        .{ .spin_phase = below_tau, .angular_velocity = 0.00001 },
        .{ .spin_phase = 0, .angular_velocity = 0.00001 },
        3,
        0.99,
    );
    try slow_forward.validate();
    const multi_turn = interpolateVehicleWheel(
        .{ .spin_phase = 0.1, .angular_velocity = 100 },
        .{ .spin_phase = 0.2, .angular_velocity = 100 },
        3,
        0.5,
    );
    try multi_turn.validate();
}

test "predicted chassis does not erase authoritative wheel presentation" {
    var interpolated = protocol.VehicleState{
        .entity = .{ .index = 17, .generation = 1 },
        .position = .{ 1, 2, 3 },
        .rotation = .{ 0, 0, 0, 1 },
        .linear_velocity = .{ 1, 0, 0 },
        .angular_velocity = .{ 0, 1, 0 },
        .driver = .{ .index = 2, .generation = 1 },
    };
    interpolated.wheels[0] = .{
        .spin_phase = 1.5,
        .angular_velocity = 20,
        .steer_angle = 0.3,
        .suspension_length = 0.25,
        .has_contact = true,
    };
    var predicted = interpolated;
    predicted.position = .{ 8, 9, 10 };
    predicted.rotation = .{ 0, 1, 0, 0 };
    predicted.linear_velocity = .{ 4, 5, 6 };
    predicted.angular_velocity = .{ 7, 8, 9 };
    predicted.driver = null;
    predicted.wheels[0] = .{};

    const presented = applyPredictedChassis(interpolated, predicted);
    try std.testing.expectEqualDeep(predicted.position, presented.position);
    try std.testing.expectEqualDeep(predicted.rotation, presented.rotation);
    try std.testing.expectEqualDeep(predicted.linear_velocity, presented.linear_velocity);
    try std.testing.expectEqualDeep(predicted.angular_velocity, presented.angular_velocity);
    try std.testing.expectEqualDeep(interpolated.driver, presented.driver);
    try std.testing.expectEqualDeep(interpolated.wheels, presented.wheels);
}

test "vehicle wheel composition applies suspension steering and spin once" {
    var vehicle = protocol.VehicleState{
        .entity = .{ .index = 17, .generation = 1 },
        .position = .{ 10, 2, 3 },
        .rotation = .{ 0, 0, 0, 1 },
        .linear_velocity = .{ 0, 0, 0 },
        .angular_velocity = .{ 0, 0, 0 },
        .driver = null,
    };
    vehicle.wheels[0] = .{ .steer_angle = 0.4, .suspension_length = 0.2 };
    vehicle.wheels[1] = .{
        .spin_phase = @as(f32, std.math.pi / 2.0),
        .suspension_length = 0.3,
    };
    vehicle.wheels[2] = .{ .suspension_length = 0.4 };
    vehicle.wheels[3] = .{ .suspension_length = 0.5 };

    const poses = try composeVehicleWheelPoses(vehicle, default_vehicle_wheel_layout);
    for (poses, default_vehicle_wheel_layout.attachment_positions, vehicle.wheels) |
        pose,
        attachment,
        wheel,
    | {
        try std.testing.expectApproxEqAbs(10 + attachment[0], pose.position[0], 0.0001);
        try std.testing.expectApproxEqAbs(
            2 + attachment[1] - wheel.suspension_length,
            pose.position[1],
            0.0001,
        );
        try std.testing.expectApproxEqAbs(3 + attachment[2], pose.position[2], 0.0001);
    }
    try std.testing.expectApproxEqAbs(@sin(@as(f32, -0.2)), poses[0].rotation[1], 0.0001);
    try std.testing.expectApproxEqAbs(@cos(@as(f32, 0.2)), poses[0].rotation[3], 0.0001);
    const quarter_turn_component = @sqrt(@as(f32, 0.5));
    try std.testing.expectApproxEqAbs(quarter_turn_component, poses[1].rotation[0], 0.0001);
    try std.testing.expectApproxEqAbs(quarter_turn_component, poses[1].rotation[3], 0.0001);
    try std.testing.expectEqualDeep([4]f32{ 0, 0, 0, 1 }, poses[2].rotation);

    vehicle.wheels[0].suspension_length =
        default_vehicle_wheel_layout.suspension_max_length + 0.01;
    try std.testing.expectError(
        error.VehicleWheelSuspensionExceedsLayout,
        composeVehicleWheelPoses(vehicle, default_vehicle_wheel_layout),
    );
    vehicle.wheels[0].suspension_length = 0;
    vehicle.wheels[0].steer_angle =
        default_vehicle_wheel_layout.max_steer_radians + 0.01;
    try std.testing.expectError(
        error.VehicleWheelSteeringExceedsLayout,
        composeVehicleWheelPoses(vehicle, default_vehicle_wheel_layout),
    );
}

test "replicated world interpolates carryables and replaces holder ownership" {
    var world = World{};
    var first = protocol.Snapshot.empty();
    first.sequence.value = 1;
    first.carryable_count = 1;
    first.carryables[0] = .{
        .entity = .{ .index = 21, .generation = 1 },
        .position = .{ 0, 1, 0 },
        .rotation = .{ 0, 0, 0, 1 },
        .linear_velocity = .{ 0, 0, 0 },
        .angular_velocity = .{ 0, 0, 0 },
        .half_extents = .{ 0.35, 0.35, 0.35 },
        .holder = null,
    };
    try world.apply(first);
    var second = first;
    second.sequence.value = 2;
    second.carryables[0].position[0] = 2;
    second.carryables[0].holder = .{ .index = 1, .generation = 1 };
    try world.apply(second);
    const midpoint = World.interpolateCarryable(world.carryableSlice()[0], 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 1), midpoint.position[0], 0.0001);
    try std.testing.expectEqual(second.carryables[0].holder, midpoint.holder);
}

test "NPC updates interpolate at their own rate and absent updates preserve membership" {
    var world = World{};
    var first = protocol.Snapshot.empty();
    first.sequence.value = 1;
    first.npc_update = true;
    first.npc_count = 1;
    first.npcs[0] = .{
        .entity = .{ .index = 100, .generation = 1 },
        .position = .{ 0, 0, 0 },
        .velocity = .{ 1, 0, 0 },
        .facing_yaw = @as(f32, std.math.pi - 0.1),
        .state = .active,
    };
    try world.apply(first);
    var character_only = protocol.Snapshot.empty();
    character_only.sequence.value = 2;
    try world.apply(character_only);
    try std.testing.expectEqual(@as(u8, 1), world.npc_count);

    var second = protocol.Snapshot.empty();
    second.sequence.value = 3;
    second.npc_update = true;
    second.npc_count = 1;
    second.npcs[0] = first.npcs[0];
    second.npcs[0].position = .{ 2, 0, 0 };
    second.npcs[0].facing_yaw = @as(f32, -std.math.pi + 0.1);
    try world.apply(second);
    const midpoint = World.interpolateNpc(world.npcs[0], 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 1), midpoint.position[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, -std.math.pi), midpoint.facing_yaw, 0.0001);
}

test "NPC presentation correction preserves local capsule separation" {
    const character = protocol.CharacterState{
        .entity = .{ .index = 1, .generation = 1 },
        .owner = .{ .index = 1, .generation = 1 },
        .position = .{ 0, 0, 0 },
        .velocity = .{ 0, 0, 0 },
        .facing_yaw = 0,
    };
    const npc = protocol.NpcState{
        .entity = .{ .index = 2, .generation = 1 },
        .position = .{ 0, 0, -0.6 },
        .velocity = .{ 0, 0, 0 },
        .facing_yaw = 0,
        .state = .active,
    };
    const result = separateNpcPresentation(npc, character, 0.35, 0.4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.15), result.correction_distance, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, -0.75), result.state.position[2], 0.0001);
    try std.testing.expectEqual(npc.position[1], result.state.position[1]);
    try std.testing.expectEqual(npc.facing_yaw, result.state.facing_yaw);
}

test "NPC presentation correction preserves retained dead avatar visibility" {
    const character = protocol.CharacterState{
        .entity = .{ .index = 1, .generation = 1 },
        .owner = .{ .index = 1, .generation = 1 },
        .position = .{ 0, 0, 0 },
        .velocity = .{ 0, 0, 0 },
        .facing_yaw = 0,
        .health = 0,
        .maximum_health = 100,
        .life_state = .dead,
    };
    const npc = protocol.NpcState{
        .entity = .{ .index = 2, .generation = 1 },
        .position = .{ 0, 0, 0 },
        .velocity = .{ 0, 0, 0 },
        .facing_yaw = 0,
        .state = .active,
    };
    const result = separateNpcPresentation(npc, character, 0.35, 0.4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), result.correction_distance, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), @abs(result.state.position[0]), 0.0001);
    try std.testing.expectEqual(@as(f32, 0), result.state.position[2]);
}

test "presentation timeline advances common and NPC snapshot lanes independently" {
    var world = World{};
    var timeline = PresentationTimeline{};

    var first = protocol.Snapshot.empty();
    first.sequence.value = 1;
    first.server_tick = 6;
    first.npc_update = true;
    try world.apply(first);
    timeline.observeAppliedWorld(&world, 100 * std.time.ns_per_ms);

    var common_only = protocol.Snapshot.empty();
    common_only.sequence.value = 2;
    common_only.server_tick = 9;
    try world.apply(common_only);
    timeline.observeAppliedWorld(&world, 150 * std.time.ns_per_ms);

    try std.testing.expectEqual(@as(u32, 2), timeline.common_sequence.value);
    try std.testing.expectEqual(@as(u32, 1), timeline.npc_sequence.value);
    try std.testing.expectEqual(@as(u64, 150 * std.time.ns_per_ms), timeline.common_last_ns);
    try std.testing.expectEqual(@as(u64, 100 * std.time.ns_per_ms), timeline.npc_last_ns);
    try std.testing.expectApproxEqAbs(@as(f32, 0), timeline.commonAlpha(150 * std.time.ns_per_ms), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), timeline.npcAlpha(150 * std.time.ns_per_ms), 0.0001);

    // Re-observing an unchanged applied world must not reset either clock.
    timeline.observeAppliedWorld(&world, 175 * std.time.ns_per_ms);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), timeline.commonAlpha(175 * std.time.ns_per_ms), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), timeline.npcAlpha(175 * std.time.ns_per_ms), 0.0001);

    var second_npc = protocol.Snapshot.empty();
    second_npc.sequence.value = 3;
    second_npc.server_tick = 12;
    second_npc.npc_update = true;
    try world.apply(second_npc);
    timeline.observeAppliedWorld(&world, 200 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(u64, 100 * std.time.ns_per_ms), timeline.npc_interval_ns);
    try std.testing.expectApproxEqAbs(@as(f32, 0), timeline.npcAlpha(200 * std.time.ns_per_ms), 0.0001);
}
