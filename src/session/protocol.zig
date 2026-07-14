//! Small, bounded semantic protocol for MP1/MP2. Transport handles, Flecs IDs,
//! Jolt state, durable-save bytes, and platform identities are excluded.

const std = @import("std");
const budgets = @import("session_budgets");
const identity = @import("session_identity");
const cohort = @import("network_cohort_options");

pub const wire_magic: u32 = 0x494e_434e; // "INCN"
pub const wire_version: u16 = cohort.protocol_revision;
pub const build_cohort: u64 = cohort.build_cohort;
pub const content_cohort: u64 = cohort.content_cohort;

pub const RejectionReason = enum(u8) {
    malformed = 1,
    oversized = 2,
    protocol_mismatch = 3,
    build_mismatch = 4,
    content_mismatch = 5,
    session_full = 6,
    unauthorized = 7,
    stale_connection = 8,
    stale_sequence = 9,
    invalid_state = 10,
    quota_exceeded = 11,
    reconnect_expired = 12,
};

pub const DisconnectReason = enum(u8) {
    requested = 1,
    transport_lost = 2,
    timeout = 3,
    protocol_failure = 4,
    authority_stopping = 5,
};

pub const Hello = struct {
    protocol: u16 = wire_version,
    build: u64 = build_cohort,
    content: u64 = content_cohort,
    account: identity.AccountId,
    reconnect: identity.ReconnectToken = .invalid,
};

pub const InputFrame = struct {
    session: identity.SessionId,
    participant: identity.ParticipantId,
    sequence: identity.InputSequence,
    target_tick: u64,
    move: [2]f32,
    facing_yaw: f32,
    jump_pressed: bool,
};

pub const VehicleInputFrame = struct {
    session: identity.SessionId,
    participant: identity.ParticipantId,
    sequence: identity.InputSequence,
    target_tick: u64,
    vehicle: identity.ReplicatedEntityId,
    throttle: f32,
    steering: f32,
    brake: f32,
    hand_brake: f32,
};

pub const VehicleActionKind = enum(u8) {
    enter = 1,
    exit = 2,
};

pub const VehicleAction = struct {
    session: identity.SessionId,
    participant: identity.ParticipantId,
    sequence: identity.ActionSequence,
    vehicle: identity.ReplicatedEntityId,
    kind: VehicleActionKind,
};

pub const ClientMessage = union(enum) {
    hello: Hello,
    input: InputFrame,
    vehicle_input: VehicleInputFrame,
    vehicle_action: VehicleAction,
    disconnect: DisconnectReason,
};

pub const Welcome = struct {
    session: identity.SessionId,
    participant: identity.ParticipantId,
    connection: identity.ConnectionId,
    reconnect: identity.ReconnectToken,
    authority_tick: u64,
};

pub const CharacterState = struct {
    entity: identity.ReplicatedEntityId,
    owner: identity.ParticipantId,
    position: [3]f32,
    velocity: [3]f32,
    facing_yaw: f32,
};

pub const VehicleState = struct {
    entity: identity.ReplicatedEntityId,
    position: [3]f32,
    rotation: [4]f32,
    linear_velocity: [3]f32,
    angular_velocity: [3]f32,
    driver: ?identity.ParticipantId,
};

pub const Snapshot = struct {
    sequence: identity.SnapshotSequence,
    server_tick: u64,
    acknowledged_input: identity.InputSequence,
    character_count: u8,
    vehicle_count: u8,
    characters: [budgets.max_participants]CharacterState,
    vehicles: [budgets.max_vehicles]VehicleState,

    pub fn empty() Snapshot {
        return .{
            .sequence = .{ .value = 0 },
            .server_tick = 0,
            .acknowledged_input = .{ .value = 0 },
            .character_count = 0,
            .vehicle_count = 0,
            .characters = undefined,
            .vehicles = undefined,
        };
    }

    pub fn slice(self: *const Snapshot) []const CharacterState {
        return self.characters[0..self.character_count];
    }

    pub fn vehicleSlice(self: *const Snapshot) []const VehicleState {
        return self.vehicles[0..self.vehicle_count];
    }
};

pub const VehicleActionDisposition = enum(u8) {
    entered = 1,
    exited = 2,
    vehicle_not_found = 3,
    unavailable = 4,
    too_far = 5,
    exit_blocked = 6,
    invalid_state = 7,
};

pub const VehicleActionResult = struct {
    sequence: identity.ActionSequence,
    vehicle: identity.ReplicatedEntityId,
    action: VehicleActionKind,
    disposition: VehicleActionDisposition,
};

pub const Rejection = struct {
    reason: RejectionReason,
    detail_code: u16 = 0,
};

pub const ServerMessage = union(enum) {
    welcome: Welcome,
    snapshot: Snapshot,
    vehicle_action_result: VehicleActionResult,
    rejected: Rejection,
    disconnected: DisconnectReason,
};

const Direction = enum(u8) { client = 1, server = 2 };
const ClientKind = enum(u8) {
    hello = 1,
    input = 2,
    vehicle_input = 3,
    vehicle_action = 4,
    disconnect = 5,
};
const ServerKind = enum(u8) {
    welcome = 1,
    snapshot = 2,
    vehicle_action_result = 3,
    rejected = 4,
    disconnected = 5,
};

pub fn encodeClient(message: ClientMessage, storage: []u8) ![]const u8 {
    var encoder = Encoder.init(storage);
    try encoder.header(.client, switch (message) {
        .hello => @intFromEnum(ClientKind.hello),
        .input => @intFromEnum(ClientKind.input),
        .vehicle_input => @intFromEnum(ClientKind.vehicle_input),
        .vehicle_action => @intFromEnum(ClientKind.vehicle_action),
        .disconnect => @intFromEnum(ClientKind.disconnect),
    });
    switch (message) {
        .hello => |value| {
            try encoder.u16Value(value.protocol);
            try encoder.u64Value(value.build);
            try encoder.u64Value(value.content);
            try encoder.u64Value(value.account.value);
            try encoder.u64Value(value.reconnect.high);
            try encoder.u64Value(value.reconnect.low);
        },
        .input => |value| {
            try encodeInput(&encoder, value);
        },
        .vehicle_input => |value| try encodeVehicleInput(&encoder, value),
        .vehicle_action => |value| try encodeVehicleAction(&encoder, value),
        .disconnect => |reason| try encoder.u8Value(@intFromEnum(reason)),
    }
    return encoder.finish();
}

pub fn decodeClient(bytes: []const u8) !ClientMessage {
    var decoder = try Decoder.init(bytes, .client);
    const kind = enumFromInt(ClientKind, decoder.kind) catch
        return error.UnknownMessageKind;
    const message: ClientMessage = switch (kind) {
        .hello => .{ .hello = .{
            .protocol = try decoder.u16Value(),
            .build = try decoder.u64Value(),
            .content = try decoder.u64Value(),
            .account = .{ .value = try decoder.u64Value() },
            .reconnect = .{
                .high = try decoder.u64Value(),
                .low = try decoder.u64Value(),
            },
        } },
        .input => .{ .input = try decodeInput(&decoder) },
        .vehicle_input => .{ .vehicle_input = try decodeVehicleInput(&decoder) },
        .vehicle_action => .{ .vehicle_action = try decodeVehicleAction(&decoder) },
        .disconnect => .{ .disconnect = enumFromInt(
            DisconnectReason,
            try decoder.u8Value(),
        ) catch return error.InvalidEnum },
    };
    try decoder.finish();
    try validateClient(message);
    return message;
}

pub fn encodeServer(message: ServerMessage, storage: []u8) ![]const u8 {
    var encoder = Encoder.init(storage);
    try encoder.header(.server, switch (message) {
        .welcome => @intFromEnum(ServerKind.welcome),
        .snapshot => @intFromEnum(ServerKind.snapshot),
        .vehicle_action_result => @intFromEnum(ServerKind.vehicle_action_result),
        .rejected => @intFromEnum(ServerKind.rejected),
        .disconnected => @intFromEnum(ServerKind.disconnected),
    });
    switch (message) {
        .welcome => |value| {
            try encoder.u64Value(value.session.value);
            try encodeParticipant(&encoder, value.participant);
            try encodeConnection(&encoder, value.connection);
            try encoder.u64Value(value.reconnect.high);
            try encoder.u64Value(value.reconnect.low);
            try encoder.u64Value(value.authority_tick);
        },
        .snapshot => |value| {
            if (value.character_count > budgets.max_participants) return error.TooManyCharacters;
            if (value.vehicle_count > budgets.max_vehicles) return error.TooManyVehicles;
            try encoder.u32Value(value.sequence.value);
            try encoder.u64Value(value.server_tick);
            try encoder.u32Value(value.acknowledged_input.value);
            try encoder.u8Value(value.character_count);
            try encoder.u8Value(value.vehicle_count);
            for (value.slice()) |character| try encodeCharacter(&encoder, character);
            for (value.vehicleSlice()) |vehicle| try encodeVehicle(&encoder, vehicle);
        },
        .vehicle_action_result => |value| {
            try encoder.u32Value(value.sequence.value);
            try encodeReplicatedEntity(&encoder, value.vehicle);
            try encoder.u8Value(@intFromEnum(value.action));
            try encoder.u8Value(@intFromEnum(value.disposition));
        },
        .rejected => |value| {
            try encoder.u8Value(@intFromEnum(value.reason));
            try encoder.u16Value(value.detail_code);
        },
        .disconnected => |reason| try encoder.u8Value(@intFromEnum(reason)),
    }
    const bytes = try encoder.finish();
    switch (message) {
        .snapshot => if (bytes.len > budgets.max_snapshot_bytes) {
            return error.SnapshotTooLarge;
        },
        else => {},
    }
    return bytes;
}

pub fn decodeServer(bytes: []const u8) !ServerMessage {
    var decoder = try Decoder.init(bytes, .server);
    const kind = enumFromInt(ServerKind, decoder.kind) catch
        return error.UnknownMessageKind;
    const message: ServerMessage = switch (kind) {
        .welcome => .{ .welcome = .{
            .session = .{ .value = try decoder.u64Value() },
            .participant = try decodeParticipant(&decoder),
            .connection = try decodeConnection(&decoder),
            .reconnect = .{
                .high = try decoder.u64Value(),
                .low = try decoder.u64Value(),
            },
            .authority_tick = try decoder.u64Value(),
        } },
        .snapshot => blk: {
            var snapshot = Snapshot.empty();
            snapshot.sequence.value = try decoder.u32Value();
            snapshot.server_tick = try decoder.u64Value();
            snapshot.acknowledged_input.value = try decoder.u32Value();
            snapshot.character_count = try decoder.u8Value();
            snapshot.vehicle_count = try decoder.u8Value();
            if (snapshot.character_count > budgets.max_participants) return error.TooManyCharacters;
            if (snapshot.vehicle_count > budgets.max_vehicles) return error.TooManyVehicles;
            for (snapshot.characters[0..snapshot.character_count]) |*character| {
                character.* = try decodeCharacter(&decoder);
            }
            for (snapshot.vehicles[0..snapshot.vehicle_count]) |*vehicle| {
                vehicle.* = try decodeVehicle(&decoder);
            }
            break :blk .{ .snapshot = snapshot };
        },
        .vehicle_action_result => .{ .vehicle_action_result = .{
            .sequence = .{ .value = try decoder.u32Value() },
            .vehicle = try decodeReplicatedEntity(&decoder),
            .action = enumFromInt(
                VehicleActionKind,
                try decoder.u8Value(),
            ) catch return error.InvalidEnum,
            .disposition = enumFromInt(
                VehicleActionDisposition,
                try decoder.u8Value(),
            ) catch return error.InvalidEnum,
        } },
        .rejected => .{ .rejected = .{
            .reason = enumFromInt(
                RejectionReason,
                try decoder.u8Value(),
            ) catch return error.InvalidEnum,
            .detail_code = try decoder.u16Value(),
        } },
        .disconnected => .{ .disconnected = enumFromInt(
            DisconnectReason,
            try decoder.u8Value(),
        ) catch return error.InvalidEnum },
    };
    try decoder.finish();
    return message;
}

pub fn validateClient(message: ClientMessage) !void {
    switch (message) {
        .hello => |value| {
            try value.account.validate();
        },
        .input => |value| {
            try value.session.validate();
            try value.participant.validate();
            if (!std.math.isFinite(value.move[0]) or !std.math.isFinite(value.move[1]) or
                !std.math.isFinite(value.facing_yaw)) return error.NonFiniteInput;
            const length_squared = value.move[0] * value.move[0] + value.move[1] * value.move[1];
            if (length_squared > 1.0001) return error.InvalidMovementInput;
        },
        .vehicle_input => |value| {
            try value.session.validate();
            try value.participant.validate();
            try value.vehicle.validate();
            const controls = [4]f32{
                value.throttle,
                value.steering,
                value.brake,
                value.hand_brake,
            };
            for (controls) |control| {
                if (!std.math.isFinite(control)) return error.NonFiniteInput;
                if (@abs(control) > 1) return error.InvalidVehicleInput;
            }
        },
        .vehicle_action => |value| {
            try value.session.validate();
            try value.participant.validate();
            try value.vehicle.validate();
        },
        .disconnect => {},
    }
}

fn encodeInput(encoder: *Encoder, value: InputFrame) !void {
    try encoder.u64Value(value.session.value);
    try encodeParticipant(encoder, value.participant);
    try encoder.u32Value(value.sequence.value);
    try encoder.u64Value(value.target_tick);
    try encoder.f32Value(value.move[0]);
    try encoder.f32Value(value.move[1]);
    try encoder.f32Value(value.facing_yaw);
    try encoder.u8Value(@intFromBool(value.jump_pressed));
}

fn decodeInput(decoder: *Decoder) !InputFrame {
    return .{
        .session = .{ .value = try decoder.u64Value() },
        .participant = try decodeParticipant(decoder),
        .sequence = .{ .value = try decoder.u32Value() },
        .target_tick = try decoder.u64Value(),
        .move = .{ try decoder.f32Value(), try decoder.f32Value() },
        .facing_yaw = try decoder.f32Value(),
        .jump_pressed = switch (try decoder.u8Value()) {
            0 => false,
            1 => true,
            else => return error.InvalidBoolean,
        },
    };
}

fn encodeVehicleInput(encoder: *Encoder, value: VehicleInputFrame) !void {
    try encoder.u64Value(value.session.value);
    try encodeParticipant(encoder, value.participant);
    try encoder.u32Value(value.sequence.value);
    try encoder.u64Value(value.target_tick);
    try encodeReplicatedEntity(encoder, value.vehicle);
    try encoder.f32Value(value.throttle);
    try encoder.f32Value(value.steering);
    try encoder.f32Value(value.brake);
    try encoder.f32Value(value.hand_brake);
}

fn decodeVehicleInput(decoder: *Decoder) !VehicleInputFrame {
    return .{
        .session = .{ .value = try decoder.u64Value() },
        .participant = try decodeParticipant(decoder),
        .sequence = .{ .value = try decoder.u32Value() },
        .target_tick = try decoder.u64Value(),
        .vehicle = try decodeReplicatedEntity(decoder),
        .throttle = try decoder.f32Value(),
        .steering = try decoder.f32Value(),
        .brake = try decoder.f32Value(),
        .hand_brake = try decoder.f32Value(),
    };
}

fn encodeVehicleAction(encoder: *Encoder, value: VehicleAction) !void {
    try encoder.u64Value(value.session.value);
    try encodeParticipant(encoder, value.participant);
    try encoder.u32Value(value.sequence.value);
    try encodeReplicatedEntity(encoder, value.vehicle);
    try encoder.u8Value(@intFromEnum(value.kind));
}

fn decodeVehicleAction(decoder: *Decoder) !VehicleAction {
    return .{
        .session = .{ .value = try decoder.u64Value() },
        .participant = try decodeParticipant(decoder),
        .sequence = .{ .value = try decoder.u32Value() },
        .vehicle = try decodeReplicatedEntity(decoder),
        .kind = enumFromInt(
            VehicleActionKind,
            try decoder.u8Value(),
        ) catch return error.InvalidEnum,
    };
}

fn encodeParticipant(encoder: *Encoder, value: identity.ParticipantId) !void {
    try encoder.u16Value(value.index);
    try encoder.u16Value(value.generation);
}

fn decodeParticipant(decoder: *Decoder) !identity.ParticipantId {
    return .{ .index = try decoder.u16Value(), .generation = try decoder.u16Value() };
}

fn encodeConnection(encoder: *Encoder, value: identity.ConnectionId) !void {
    try encoder.u16Value(value.index);
    try encoder.u16Value(value.generation);
}

fn decodeConnection(decoder: *Decoder) !identity.ConnectionId {
    return .{ .index = try decoder.u16Value(), .generation = try decoder.u16Value() };
}

fn encodeReplicatedEntity(encoder: *Encoder, value: identity.ReplicatedEntityId) !void {
    try encoder.u32Value(value.index);
    try encoder.u16Value(value.generation);
}

fn decodeReplicatedEntity(decoder: *Decoder) !identity.ReplicatedEntityId {
    return .{ .index = try decoder.u32Value(), .generation = try decoder.u16Value() };
}

fn encodeCharacter(encoder: *Encoder, value: CharacterState) !void {
    try encodeReplicatedEntity(encoder, value.entity);
    try encodeParticipant(encoder, value.owner);
    for (value.position) |component| try encoder.f32Value(component);
    for (value.velocity) |component| try encoder.f32Value(component);
    try encoder.f32Value(value.facing_yaw);
}

fn decodeCharacter(decoder: *Decoder) !CharacterState {
    var value = CharacterState{
        .entity = .{
            .index = try decoder.u32Value(),
            .generation = try decoder.u16Value(),
        },
        .owner = try decodeParticipant(decoder),
        .position = undefined,
        .velocity = undefined,
        .facing_yaw = 0,
    };
    for (&value.position) |*component| component.* = try decoder.f32Value();
    for (&value.velocity) |*component| component.* = try decoder.f32Value();
    value.facing_yaw = try decoder.f32Value();
    return value;
}

fn encodeVehicle(encoder: *Encoder, value: VehicleState) !void {
    try encodeReplicatedEntity(encoder, value.entity);
    for (value.position) |component| try encoder.f32Value(component);
    for (value.rotation) |component| try encoder.f32Value(component);
    for (value.linear_velocity) |component| try encoder.f32Value(component);
    for (value.angular_velocity) |component| try encoder.f32Value(component);
    try encoder.u8Value(@intFromBool(value.driver != null));
    if (value.driver) |driver| try encodeParticipant(encoder, driver);
}

fn decodeVehicle(decoder: *Decoder) !VehicleState {
    var value = VehicleState{
        .entity = try decodeReplicatedEntity(decoder),
        .position = undefined,
        .rotation = undefined,
        .linear_velocity = undefined,
        .angular_velocity = undefined,
        .driver = null,
    };
    for (&value.position) |*component| component.* = try decoder.f32Value();
    for (&value.rotation) |*component| component.* = try decoder.f32Value();
    for (&value.linear_velocity) |*component| component.* = try decoder.f32Value();
    for (&value.angular_velocity) |*component| component.* = try decoder.f32Value();
    value.driver = switch (try decoder.u8Value()) {
        0 => null,
        1 => try decodeParticipant(decoder),
        else => return error.InvalidBoolean,
    };
    return value;
}

fn enumFromInt(comptime E: type, value: anytype) !E {
    inline for (std.meta.fields(E)) |field| {
        if (value == field.value) return @enumFromInt(value);
    }
    return error.InvalidEnum;
}

const Encoder = struct {
    storage: []u8,
    cursor: usize = 0,

    fn init(storage: []u8) Encoder {
        return .{ .storage = storage };
    }

    fn header(self: *Encoder, direction: Direction, kind: u8) !void {
        try self.u32Value(wire_magic);
        try self.u16Value(wire_version);
        try self.u8Value(@intFromEnum(direction));
        try self.u8Value(kind);
    }

    fn reserve(self: *Encoder, count: usize) ![]u8 {
        if (count > budgets.max_wire_message_bytes or
            self.cursor > self.storage.len or count > self.storage.len - self.cursor)
        {
            return error.BufferTooSmall;
        }
        const result = self.storage[self.cursor..][0..count];
        self.cursor += count;
        return result;
    }

    fn u8Value(self: *Encoder, value: u8) !void {
        (try self.reserve(1))[0] = value;
    }

    fn u16Value(self: *Encoder, value: u16) !void {
        const out = try self.reserve(2);
        out[0] = @truncate(value);
        out[1] = @truncate(value >> 8);
    }

    fn u32Value(self: *Encoder, value: u32) !void {
        const out = try self.reserve(4);
        inline for (0..4) |index| out[index] = @truncate(value >> (index * 8));
    }

    fn u64Value(self: *Encoder, value: u64) !void {
        const out = try self.reserve(8);
        inline for (0..8) |index| out[index] = @truncate(value >> (index * 8));
    }

    fn f32Value(self: *Encoder, value: f32) !void {
        try self.u32Value(@bitCast(value));
    }

    fn finish(self: *Encoder) ![]const u8 {
        if (self.cursor > budgets.max_wire_message_bytes) return error.MessageTooLarge;
        return self.storage[0..self.cursor];
    }
};

const Decoder = struct {
    bytes: []const u8,
    cursor: usize,
    kind: u8,

    fn init(bytes: []const u8, expected_direction: Direction) !Decoder {
        if (bytes.len > budgets.max_wire_message_bytes) return error.MessageTooLarge;
        var decoder = Decoder{ .bytes = bytes, .cursor = 0, .kind = 0 };
        if (try decoder.u32Value() != wire_magic) return error.InvalidMagic;
        if (try decoder.u16Value() != wire_version) return error.InvalidWireVersion;
        if (try decoder.u8Value() != @intFromEnum(expected_direction)) {
            return error.InvalidDirection;
        }
        decoder.kind = try decoder.u8Value();
        return decoder;
    }

    fn take(self: *Decoder, count: usize) ![]const u8 {
        if (self.cursor > self.bytes.len or count > self.bytes.len - self.cursor) {
            return error.TruncatedMessage;
        }
        const result = self.bytes[self.cursor..][0..count];
        self.cursor += count;
        return result;
    }

    fn u8Value(self: *Decoder) !u8 {
        return (try self.take(1))[0];
    }

    fn u16Value(self: *Decoder) !u16 {
        const data = try self.take(2);
        return @as(u16, data[0]) | (@as(u16, data[1]) << 8);
    }

    fn u32Value(self: *Decoder) !u32 {
        const data = try self.take(4);
        var value: u32 = 0;
        inline for (0..4) |index| value |= @as(u32, data[index]) << (index * 8);
        return value;
    }

    fn u64Value(self: *Decoder) !u64 {
        const data = try self.take(8);
        var value: u64 = 0;
        inline for (0..8) |index| value |= @as(u64, data[index]) << (index * 8);
        return value;
    }

    fn f32Value(self: *Decoder) !f32 {
        return @bitCast(try self.u32Value());
    }

    fn finish(self: *Decoder) !void {
        if (self.cursor != self.bytes.len) return error.TrailingBytes;
    }
};

test "client input round trips without exposing backend identity" {
    var bytes: [256]u8 = undefined;
    const original = ClientMessage{ .input = .{
        .session = .{ .value = 9 },
        .participant = .{ .index = 2, .generation = 3 },
        .sequence = .{ .value = std.math.maxInt(u32) },
        .target_tick = 42,
        .move = .{ 0.5, -0.25 },
        .facing_yaw = 1.25,
        .jump_pressed = true,
    } };
    const encoded = try encodeClient(original, &bytes);
    try std.testing.expectEqualDeep(original, try decodeClient(encoded));
}

test "snapshot round trips at the validation ceiling" {
    var snapshot = Snapshot.empty();
    snapshot.sequence.value = 4;
    snapshot.server_tick = 99;
    snapshot.acknowledged_input.value = 8;
    snapshot.character_count = budgets.max_participants;
    snapshot.vehicle_count = budgets.max_vehicles;
    for (snapshot.characters[0..snapshot.character_count], 0..) |*character, index| {
        character.* = .{
            .entity = .{ .index = @intCast(index + 1), .generation = 1 },
            .owner = .{ .index = @intCast(index + 1), .generation = 1 },
            .position = .{ @floatFromInt(index), 1, -2 },
            .velocity = .{ 0, 0, 0 },
            .facing_yaw = 0,
        };
    }
    for (snapshot.vehicles[0..snapshot.vehicle_count], 0..) |*vehicle, index| {
        vehicle.* = .{
            .entity = .{ .index = @intCast(budgets.max_participants + index + 1), .generation = 1 },
            .position = .{ @floatFromInt(index), 0.5, 1 },
            .rotation = .{ 0, 0, 0, 1 },
            .linear_velocity = .{ 0, 0, -1 },
            .angular_velocity = .{ 0, 0, 0 },
            .driver = if (index == 0) .{ .index = 1, .generation = 1 } else null,
        };
    }
    var bytes: [budgets.max_snapshot_bytes]u8 = undefined;
    const encoded = try encodeServer(.{ .snapshot = snapshot }, &bytes);
    try std.testing.expect(encoded.len <= budgets.max_snapshot_bytes);
    const decoded = try decodeServer(encoded);
    try std.testing.expectEqualDeep(ServerMessage{ .snapshot = snapshot }, decoded);
}

test "vehicle input action and result round trip with explicit transport semantics" {
    var bytes: [256]u8 = undefined;
    const input = ClientMessage{ .vehicle_input = .{
        .session = .{ .value = 9 },
        .participant = .{ .index = 2, .generation = 3 },
        .sequence = .{ .value = 5 },
        .target_tick = 42,
        .vehicle = .{ .index = 17, .generation = 1 },
        .throttle = 1,
        .steering = -0.5,
        .brake = 0,
        .hand_brake = 0,
    } };
    try std.testing.expectEqualDeep(input, try decodeClient(try encodeClient(input, &bytes)));

    const action = ClientMessage{ .vehicle_action = .{
        .session = .{ .value = 9 },
        .participant = .{ .index = 2, .generation = 3 },
        .sequence = .{ .value = 7 },
        .vehicle = .{ .index = 17, .generation = 1 },
        .kind = .enter,
    } };
    try std.testing.expectEqualDeep(action, try decodeClient(try encodeClient(action, &bytes)));

    const result = ServerMessage{ .vehicle_action_result = .{
        .sequence = .{ .value = 7 },
        .vehicle = .{ .index = 17, .generation = 1 },
        .action = .enter,
        .disposition = .entered,
    } };
    try std.testing.expectEqualDeep(result, try decodeServer(try encodeServer(result, &bytes)));
}

test "protocol rejects trailing, oversized movement, and cohort-invalid input" {
    var bytes: [256]u8 = undefined;
    const encoded = try encodeClient(.{ .hello = .{
        .account = .{ .value = 1 },
    } }, &bytes);
    var with_trailing: [257]u8 = undefined;
    @memcpy(with_trailing[0..encoded.len], encoded);
    with_trailing[encoded.len] = 0xff;
    try std.testing.expectError(
        error.TrailingBytes,
        decodeClient(with_trailing[0 .. encoded.len + 1]),
    );
    try std.testing.expectError(error.InvalidMovementInput, validateClient(.{ .input = .{
        .session = .{ .value = 1 },
        .participant = .{ .index = 1, .generation = 1 },
        .sequence = .{ .value = 1 },
        .target_tick = 1,
        .move = .{ 1, 1 },
        .facing_yaw = 0,
        .jump_pressed = false,
    } }));
}
