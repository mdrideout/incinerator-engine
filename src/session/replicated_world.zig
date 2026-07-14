//! Lightweight non-authoritative client state. It owns no Flecs world, Jolt
//! body, durable state, or gameplay decision.

const std = @import("std");
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
};

pub const World = struct {
    entries: [budgets.max_participants]Entry = undefined,
    character_count: u8 = 0,
    vehicles: [budgets.max_vehicles]VehicleEntry = undefined,
    vehicle_count: u8 = 0,
    server_tick: u64 = 0,
    sequence: identity.SnapshotSequence = .{ .value = 0 },
    initialized: bool = false,
    stale_snapshots: u64 = 0,

    pub fn apply(self: *World, snapshot: protocol.Snapshot) !void {
        if (snapshot.character_count > budgets.max_participants) return error.TooManyCharacters;
        if (snapshot.vehicle_count > budgets.max_vehicles) return error.TooManyVehicles;
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
            const previous = self.findVehicle(vehicle.entity) orelse vehicle;
            next_vehicles[index] = .{ .previous = previous, .current = vehicle };
        }
        self.entries = next;
        self.character_count = snapshot.character_count;
        self.vehicles = next_vehicles;
        self.vehicle_count = snapshot.vehicle_count;
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
        for (self.vehicleSlice()) |entry| {
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
        result.facing_yaw = entry.previous.facing_yaw +
            (entry.current.facing_yaw - entry.previous.facing_yaw) * t;
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
        .facing_yaw = 0,
    };
    try world.apply(first);
    var second = first;
    second.sequence.value = 2;
    second.server_tick = 6;
    second.characters[0].position[0] = 2;
    try world.apply(second);
    const midpoint = World.interpolate(world.slice()[0], 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 1), midpoint.position[0], 0.0001);
    try std.testing.expectError(error.StaleSnapshot, world.apply(first));
}

test "replicated world interpolates vehicle pose and replaces dynamic ownership" {
    var world = World{};
    var first = protocol.Snapshot.empty();
    first.sequence.value = 1;
    first.vehicle_count = 1;
    first.vehicles[0] = .{
        .entity = .{ .index = 17, .generation = 1 },
        .position = .{ 0, 1, 0 },
        .rotation = .{ 0, 0, 0, 1 },
        .linear_velocity = .{ 0, 0, -1 },
        .angular_velocity = .{ 0, 0, 0 },
        .driver = null,
    };
    try world.apply(first);
    var second = first;
    second.sequence.value = 2;
    second.vehicles[0].position[2] = -4;
    second.vehicles[0].driver = .{ .index = 1, .generation = 1 };
    try world.apply(second);
    const midpoint = World.interpolateVehicle(world.vehicleSlice()[0], 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, -2), midpoint.position[2], 0.0001);
    try std.testing.expectEqual(second.vehicles[0].driver, midpoint.driver);
}
