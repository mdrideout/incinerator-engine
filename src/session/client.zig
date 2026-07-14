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
                if (self.ownedCharacter()) |character| {
                    self.prediction.reconcile(character, snapshot.acknowledged_input);
                } else {
                    self.prediction.clearOwnership();
                }
            },
            .rejected => {
                self.rejections +|= 1;
                self.state = .rejected;
                self.prediction.clearOwnership();
            },
            .disconnected => |reason| {
                self.disconnect_reason = reason;
                self.state = switch (reason) {
                    .transport_lost, .timeout => .disconnected,
                    .requested, .protocol_failure, .authority_stopping => .stopped,
                };
                self.connection = .invalid;
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
    }

    pub fn localPresentation(self: *const Client) ?protocol.CharacterState {
        if (!self.prediction.initialized) return null;
        return self.prediction.presentation();
    }

    pub fn diagnostics(self: *const Client) Diagnostics {
        return .{
            .state = self.state,
            .snapshots_applied = self.snapshots_applied,
            .stale_snapshots = self.world.stale_snapshots,
            .prejoin_snapshots = self.prejoin_snapshots,
            .rejections = self.rejections,
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
