//! Client-owned connection state, protocol identity, and replicated world.
//! This owner can run over the typed local link or a byte/network transport.

const std = @import("std");
const identity = @import("session_identity");
const protocol = @import("session_protocol");
const replicated = @import("replicated_world");
const prediction_module = @import("session_prediction");

pub const State = enum { disconnected, hello_sent, joined, rejected, stopped };

pub const Diagnostics = struct {
    state: State,
    snapshots_applied: u64,
    stale_snapshots: u64,
    prejoin_snapshots: u64,
    rejections: u64,
    vehicle_actions_accepted: u64,
    vehicle_actions_rejected: u64,
    last_server_tick: u64,
    disconnect_reason: ?protocol.DisconnectReason,
    prediction: prediction_module.Diagnostics,
};

pub const Client = struct {
    account: identity.AccountId,
    state: State = .disconnected,
    session: identity.SessionId = .{ .value = 0 },
    participant: identity.ParticipantId = .invalid,
    connection: identity.ConnectionId = .invalid,
    reconnect: identity.ReconnectToken = .invalid,
    next_input: identity.InputSequence = .{ .value = 1 },
    last_acknowledged_input: identity.InputSequence = .{ .value = 0 },
    world: replicated.World = .{},
    snapshots_applied: u64 = 0,
    rejections: u64 = 0,
    prejoin_snapshots: u64 = 0,
    disconnect_reason: ?protocol.DisconnectReason = null,
    prediction: prediction_module.Prediction = .{},
    next_vehicle_action: identity.ActionSequence = .{ .value = 1 },
    pending_vehicle_action: ?protocol.VehicleAction = null,
    last_vehicle_action_result: ?protocol.VehicleActionResult = null,
    vehicle_actions_accepted: u64 = 0,
    vehicle_actions_rejected: u64 = 0,

    pub fn init(account: identity.AccountId) !Client {
        try account.validate();
        return .{ .account = account };
    }

    pub fn begin(self: *Client) !protocol.ClientMessage {
        if (self.state != .disconnected) return error.ClientAlreadyStarted;
        self.state = .hello_sent;
        return .{ .hello = .{
            .account = self.account,
            .reconnect = self.reconnect,
        } };
    }

    pub fn receive(self: *Client, message: protocol.ServerMessage) !void {
        switch (message) {
            .welcome => |welcome| {
                if (self.state != .hello_sent) return error.UnexpectedWelcome;
                try welcome.session.validate();
                try welcome.participant.validate();
                try welcome.connection.validate();
                if (!welcome.reconnect.isValid()) return error.InvalidReconnectToken;
                self.session = welcome.session;
                self.participant = welcome.participant;
                self.connection = welcome.connection;
                self.reconnect = welcome.reconnect;
                self.disconnect_reason = null;
                self.state = .joined;
            },
            .snapshot => |snapshot| {
                if (self.state != .joined) {
                    self.prejoin_snapshots +|= 1;
                    return;
                }
                self.world.apply(snapshot) catch |err| switch (err) {
                    // Unreliable snapshot lanes may reorder by design. The
                    // replicated world records this diagnostic and the client
                    // treats the older sample as an expected drop.
                    error.StaleSnapshot => return,
                    else => return err,
                };
                self.last_acknowledged_input = snapshot.acknowledged_input;
                self.snapshots_applied +|= 1;
                if (self.ownedVehicle() != null) {
                    self.prediction.clearOwnership();
                } else if (self.ownedCharacter()) |character| {
                    self.prediction.reconcile(character, snapshot.acknowledged_input);
                } else {
                    self.prediction.clearOwnership();
                }
            },
            .vehicle_action_result => |result| {
                const pending = self.pending_vehicle_action orelse
                    return error.UnexpectedVehicleActionResult;
                if (pending.sequence.value != result.sequence.value or
                    !std.meta.eql(pending.vehicle, result.vehicle) or
                    pending.kind != result.action)
                {
                    return error.MismatchedVehicleActionResult;
                }
                self.last_vehicle_action_result = result;
                self.pending_vehicle_action = null;
                switch (result.disposition) {
                    .entered, .exited => self.vehicle_actions_accepted +|= 1,
                    else => self.vehicle_actions_rejected +|= 1,
                }
            },
            .rejected => {
                self.rejections +|= 1;
                self.state = .rejected;
                self.prediction.clearOwnership();
                self.pending_vehicle_action = null;
            },
            .disconnected => |reason| {
                self.disconnect_reason = reason;
                self.state = switch (reason) {
                    .transport_lost, .timeout => .disconnected,
                    .requested, .protocol_failure, .authority_stopping => .stopped,
                };
                self.connection = .invalid;
                self.pending_vehicle_action = null;
                if (self.state == .stopped) self.prediction.clearOwnership();
            },
        }
    }

    pub fn input(
        self: *Client,
        target_tick: u64,
        move: [2]f32,
        facing_yaw: f32,
        jump_pressed: bool,
    ) !protocol.ClientMessage {
        if (self.state != .joined) return error.ClientNotJoined;
        if (self.ownedVehicle() != null) return error.CharacterControlUnavailable;
        const sequence = self.next_input;
        self.next_input = sequence.next();
        const message = protocol.ClientMessage{ .input = .{
            .session = self.session,
            .participant = self.participant,
            .sequence = sequence,
            .target_tick = target_tick,
            .move = move,
            .facing_yaw = facing_yaw,
            .jump_pressed = jump_pressed,
        } };
        try protocol.validateClient(message);
        self.prediction.record(message.input);
        return message;
    }

    pub fn vehicleInput(
        self: *Client,
        target_tick: u64,
        vehicle: identity.ReplicatedEntityId,
        throttle: f32,
        steering: f32,
        brake: f32,
        hand_brake: f32,
    ) !protocol.ClientMessage {
        if (self.state != .joined) return error.ClientNotJoined;
        const owned = self.ownedVehicle() orelse return error.VehicleControlUnavailable;
        if (!std.meta.eql(owned.entity, vehicle)) return error.VehicleControlUnavailable;
        const sequence = self.next_input;
        self.next_input = sequence.next();
        const message = protocol.ClientMessage{ .vehicle_input = .{
            .session = self.session,
            .participant = self.participant,
            .sequence = sequence,
            .target_tick = target_tick,
            .vehicle = vehicle,
            .throttle = throttle,
            .steering = steering,
            .brake = brake,
            .hand_brake = hand_brake,
        } };
        try protocol.validateClient(message);
        return message;
    }

    pub fn vehicleAction(
        self: *Client,
        kind: protocol.VehicleActionKind,
        vehicle: identity.ReplicatedEntityId,
    ) !protocol.ClientMessage {
        if (self.state != .joined) return error.ClientNotJoined;
        if (self.pending_vehicle_action != null) return error.VehicleActionPending;
        switch (kind) {
            .enter => if (self.ownedVehicle() != null) return error.AlreadyDriving,
            .exit => {
                const owned = self.ownedVehicle() orelse return error.NotDriving;
                if (!std.meta.eql(owned.entity, vehicle)) return error.NotDriving;
            },
        }
        const action = protocol.VehicleAction{
            .session = self.session,
            .participant = self.participant,
            .sequence = self.next_vehicle_action,
            .vehicle = vehicle,
            .kind = kind,
        };
        self.next_vehicle_action = self.next_vehicle_action.next();
        const message = protocol.ClientMessage{ .vehicle_action = action };
        try protocol.validateClient(message);
        self.pending_vehicle_action = action;
        return message;
    }

    /// A transport loss preserves the reconnect credential and replicated
    /// presentation, but invalidates connection-scoped identity. Calling
    /// `begin` on the next transport will therefore request a reconnect.
    pub fn transportDisconnected(self: *Client) void {
        if (self.state == .disconnected or self.state == .rejected or
            self.state == .stopped) return;
        self.state = .disconnected;
        self.connection = .invalid;
        self.disconnect_reason = .transport_lost;
        self.prediction.transportDisconnected();
        self.pending_vehicle_action = null;
    }

    pub fn localPresentation(self: *const Client) ?protocol.CharacterState {
        if (!self.prediction.initialized) return null;
        return self.prediction.presentation();
    }

    pub fn ownedVehicle(self: *const Client) ?protocol.VehicleState {
        for (self.world.vehicleSlice()) |entry| {
            if (entry.current.driver) |driver| {
                if (std.meta.eql(driver, self.participant)) return entry.current;
            }
        }
        return null;
    }

    pub fn diagnostics(self: *const Client) Diagnostics {
        return .{
            .state = self.state,
            .snapshots_applied = self.snapshots_applied,
            .stale_snapshots = self.world.stale_snapshots,
            .prejoin_snapshots = self.prejoin_snapshots,
            .rejections = self.rejections,
            .vehicle_actions_accepted = self.vehicle_actions_accepted,
            .vehicle_actions_rejected = self.vehicle_actions_rejected,
            .last_server_tick = self.world.server_tick,
            .disconnect_reason = self.disconnect_reason,
            .prediction = self.prediction.diagnostics(),
        };
    }

    fn ownedCharacter(self: *const Client) ?protocol.CharacterState {
        for (self.world.slice()) |entry| {
            if (std.meta.eql(entry.current.owner, self.participant)) return entry.current;
        }
        return null;
    }
};

test "client owns admission identity and sequenced input" {
    var client = try Client.init(.{ .value = 9 });
    try std.testing.expect((try client.begin()) == .hello);
    try client.receive(.{ .welcome = .{
        .session = .{ .value = 1 },
        .participant = .{ .index = 1, .generation = 1 },
        .connection = .{ .index = 1, .generation = 1 },
        .reconnect = .{ .high = 1, .low = 2 },
        .authority_tick = 0,
    } });
    const first = (try client.input(1, .{ 0, 1 }, 0, false)).input;
    const second = (try client.input(2, .{ 0, 1 }, 0, false)).input;
    try std.testing.expect(second.sequence.newerThan(first.sequence));
}

test "transport loss preserves the credential required for reconnect" {
    var client = try Client.init(.{ .value = 9 });
    _ = try client.begin();
    try client.receive(.{ .welcome = .{
        .session = .{ .value = 1 },
        .participant = .{ .index = 1, .generation = 1 },
        .connection = .{ .index = 1, .generation = 1 },
        .reconnect = .{ .high = 1, .low = 2 },
        .authority_tick = 0,
    } });
    client.transportDisconnected();
    const hello = (try client.begin()).hello;
    try std.testing.expect(hello.reconnect.isValid());
}

test "reordered unreliable snapshots are dropped without failing the client" {
    var client = try Client.init(.{ .value = 9 });
    _ = try client.begin();
    try client.receive(.{ .welcome = .{
        .session = .{ .value = 1 },
        .participant = .{ .index = 1, .generation = 1 },
        .connection = .{ .index = 1, .generation = 1 },
        .reconnect = .{ .high = 1, .low = 2 },
        .authority_tick = 0,
    } });
    var newer = protocol.Snapshot.empty();
    newer.sequence.value = 2;
    try client.receive(.{ .snapshot = newer });
    var older = protocol.Snapshot.empty();
    older.sequence.value = 1;
    try client.receive(.{ .snapshot = older });
    try std.testing.expectEqual(@as(u64, 1), client.snapshots_applied);
    try std.testing.expectEqual(@as(u64, 1), client.world.stale_snapshots);
}

test "authority stop is terminal while transport loss remains reconnectable" {
    var stopped = try Client.init(.{ .value = 9 });
    _ = try stopped.begin();
    try stopped.receive(.{ .disconnected = .authority_stopping });
    try std.testing.expectEqual(State.stopped, stopped.state);
    stopped.transportDisconnected();
    try std.testing.expectEqual(State.stopped, stopped.state);

    var retry = try Client.init(.{ .value = 10 });
    _ = try retry.begin();
    retry.transportDisconnected();
    try std.testing.expectEqual(State.disconnected, retry.state);
}

test "vehicle control follows snapshot ownership and reliable action correlation" {
    var client = try Client.init(.{ .value = 9 });
    _ = try client.begin();
    const participant = identity.ParticipantId{ .index = 1, .generation = 1 };
    try client.receive(.{ .welcome = .{
        .session = .{ .value = 1 },
        .participant = participant,
        .connection = .{ .index = 1, .generation = 1 },
        .reconnect = .{ .high = 1, .low = 2 },
        .authority_tick = 0,
    } });
    var snapshot = protocol.Snapshot.empty();
    snapshot.sequence.value = 1;
    snapshot.vehicle_count = 1;
    snapshot.vehicles[0] = .{
        .entity = .{ .index = 17, .generation = 1 },
        .position = .{ 0, 1, 0 },
        .rotation = .{ 0, 0, 0, 1 },
        .linear_velocity = .{ 0, 0, 0 },
        .angular_velocity = .{ 0, 0, 0 },
        .driver = null,
    };
    try client.receive(.{ .snapshot = snapshot });
    const action = (try client.vehicleAction(.enter, snapshot.vehicles[0].entity)).vehicle_action;
    try client.receive(.{ .vehicle_action_result = .{
        .sequence = action.sequence,
        .vehicle = action.vehicle,
        .action = action.kind,
        .disposition = .entered,
    } });
    snapshot.sequence.value = 2;
    snapshot.vehicles[0].driver = participant;
    try client.receive(.{ .snapshot = snapshot });
    try std.testing.expect((try client.vehicleInput(
        2,
        snapshot.vehicles[0].entity,
        1,
        0,
        0,
        0,
    )) == .vehicle_input);
    try std.testing.expectError(
        error.CharacterControlUnavailable,
        client.input(2, .{ 0, 1 }, 0, false),
    );
}
