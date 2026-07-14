//! Client-owned connection state, protocol identity, and replicated world.
//! This owner can run over the typed local link or a byte/network transport.

const std = @import("std");
const identity = @import("session_identity");
const budgets = @import("session_budgets");
const protocol = @import("session_protocol");
const replicated = @import("replicated_world");
const prediction_module = @import("session_prediction");
const vehicle_prediction_module = @import("vehicle_prediction");

pub const State = enum { disconnected, hello_sent, joined, rejected, stopped };

pub const Diagnostics = struct {
    state: State,
    snapshots_applied: u64,
    stale_snapshots: u64,
    prejoin_snapshots: u64,
    rejections: u64,
    vehicle_actions_accepted: u64,
    vehicle_actions_rejected: u64,
    interaction_actions_accepted: u64,
    interaction_actions_rejected: u64,
    baselines_applied: u64,
    delta_snapshots_applied: u64,
    full_snapshots_applied: u64,
    delta_base_misses: u64,
    active_baseline_id: u32,
    last_server_tick: u64,
    disconnect_reason: ?protocol.DisconnectReason,
    prediction: prediction_module.Diagnostics,
    vehicle_prediction: vehicle_prediction_module.Diagnostics,
};

pub const Client = struct {
    account: identity.AccountId,
    external_identity: protocol.ExternalIdentity,
    join_authorization: protocol.JoinAuthorization = .{},
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
    vehicle_prediction: vehicle_prediction_module.Prediction = .{},
    next_vehicle_action: identity.ActionSequence = .{ .value = 1 },
    pending_vehicle_action: ?protocol.VehicleAction = null,
    last_vehicle_action_result: ?protocol.VehicleActionResult = null,
    vehicle_actions_accepted: u64 = 0,
    vehicle_actions_rejected: u64 = 0,
    next_interaction_action: identity.ActionSequence = .{ .value = 1 },
    pending_interaction_action: ?protocol.InteractionAction = null,
    last_interaction_action_result: ?protocol.InteractionActionResult = null,
    interaction_actions_accepted: u64 = 0,
    interaction_actions_rejected: u64 = 0,
    baselines_applied: u64 = 0,
    active_baseline_id: u32 = 0,
    pending_baseline_ack: ?u32 = null,
    pending_snapshot_ack: ?identity.SnapshotSequence = null,
    snapshot_history: [budgets.snapshot_history_capacity]SnapshotRecord = @splat(.{}),
    snapshot_history_next: u8 = 0,
    delta_snapshots_applied: u64 = 0,
    full_snapshots_applied: u64 = 0,
    delta_base_misses: u64 = 0,
    relevant_district_count: u8 = 0,
    relevant_districts: [protocol.max_relevant_districts]protocol.DistrictCoord = undefined,

    pub fn init(account: identity.AccountId) !Client {
        try account.validate();
        return .{
            .account = account,
            .external_identity = .{
                .provider = .development,
                .subject = account.value,
            },
        };
    }

    pub fn configureJoin(
        self: *Client,
        external_identity: protocol.ExternalIdentity,
        authorization: protocol.JoinAuthorization,
    ) !void {
        if (self.state != .disconnected) return error.ClientAlreadyStarted;
        var hello = protocol.Hello{
            .account = self.account,
            .external_identity = external_identity,
            .join_authorization = authorization,
        };
        try protocol.validateClient(.{ .hello = hello });
        if (hello.external_identity.provider == .development and
            hello.external_identity.subject == 0)
        {
            hello.external_identity.subject = self.account.value;
        }
        self.external_identity = hello.external_identity;
        self.join_authorization = hello.join_authorization;
    }

    pub fn begin(self: *Client) !protocol.ClientMessage {
        if (self.state != .disconnected) return error.ClientAlreadyStarted;
        self.state = .hello_sent;
        return .{ .hello = .{
            .account = self.account,
            .external_identity = self.external_identity,
            .join_authorization = self.join_authorization,
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
                if (snapshot.baseline_id != self.active_baseline_id) return;
                try self.applyNetworkSnapshot(snapshot);
            },
            .relevance_baseline => |baseline| {
                if (self.state != .joined) return error.UnexpectedRelevanceBaseline;
                if (baseline.baseline_id < self.active_baseline_id) return;
                if (baseline.baseline_id != self.active_baseline_id) {
                    self.clearSnapshotHistory();
                    try self.applySnapshot(baseline.snapshot);
                    self.rememberSnapshot(baseline.snapshot);
                    self.active_baseline_id = baseline.baseline_id;
                    self.relevant_district_count = baseline.district_count;
                    for (baseline.districtSlice(), 0..) |district, index| {
                        self.relevant_districts[index] = district;
                    }
                    self.baselines_applied +|= 1;
                }
                self.pending_baseline_ack = baseline.baseline_id;
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
            .interaction_action_result => |result| {
                const pending = self.pending_interaction_action orelse
                    return error.UnexpectedInteractionActionResult;
                if (pending.sequence.value != result.sequence.value or
                    !std.meta.eql(pending.carryable, result.carryable) or
                    pending.kind != result.action)
                {
                    return error.MismatchedInteractionActionResult;
                }
                self.last_interaction_action_result = result;
                self.pending_interaction_action = null;
                switch (result.disposition) {
                    .collected, .dropped => self.interaction_actions_accepted +|= 1,
                    else => self.interaction_actions_rejected +|= 1,
                }
            },
            .rejected => {
                self.rejections +|= 1;
                self.state = .rejected;
                self.prediction.clearOwnership();
                self.vehicle_prediction.clearOwnership();
                self.pending_vehicle_action = null;
                self.pending_interaction_action = null;
                self.pending_baseline_ack = null;
                self.pending_snapshot_ack = null;
            },
            .disconnected => |reason| {
                self.disconnect_reason = reason;
                self.state = switch (reason) {
                    .transport_lost, .timeout => .disconnected,
                    .requested, .protocol_failure, .authority_stopping => .stopped,
                };
                self.connection = .invalid;
                self.pending_vehicle_action = null;
                self.pending_interaction_action = null;
                self.pending_snapshot_ack = null;
                if (self.state == .stopped) {
                    self.prediction.clearOwnership();
                    self.vehicle_prediction.clearOwnership();
                } else {
                    self.prediction.transportDisconnected();
                    self.vehicle_prediction.transportDisconnected();
                }
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
        self.vehicle_prediction.record(message.vehicle_input);
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
            .enter => {
                if (self.ownedVehicle() != null) return error.AlreadyDriving;
                if (self.heldCarryable() != null) return error.CannotDriveWhileCarrying;
            },
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

    pub fn interactionAction(
        self: *Client,
        kind: protocol.InteractionActionKind,
        carryable: identity.ReplicatedEntityId,
    ) !protocol.ClientMessage {
        if (self.state != .joined) return error.ClientNotJoined;
        if (self.pending_interaction_action != null) return error.InteractionActionPending;
        switch (kind) {
            .collect => {
                if (self.ownedVehicle() != null) return error.CannotCarryWhileDriving;
                if (self.heldCarryable() != null) return error.AlreadyCarrying;
            },
            .drop => {
                const held = self.heldCarryable() orelse return error.NotCarrying;
                if (!std.meta.eql(held.entity, carryable)) return error.NotCarrying;
            },
        }
        const action = protocol.InteractionAction{
            .session = self.session,
            .participant = self.participant,
            .sequence = self.next_interaction_action,
            .carryable = carryable,
            .kind = kind,
        };
        self.next_interaction_action = self.next_interaction_action.next();
        const message = protocol.ClientMessage{ .interaction_action = action };
        try protocol.validateClient(message);
        self.pending_interaction_action = action;
        return message;
    }

    pub fn takeBaselineAck(self: *Client) ?protocol.ClientMessage {
        const baseline_id = self.pending_baseline_ack orelse return null;
        self.pending_baseline_ack = null;
        return .{ .baseline_ack = .{
            .session = self.session,
            .participant = self.participant,
            .baseline_id = baseline_id,
        } };
    }

    pub fn takeSnapshotAck(self: *Client) ?protocol.ClientMessage {
        const sequence = self.pending_snapshot_ack orelse return null;
        self.pending_snapshot_ack = null;
        return .{ .snapshot_ack = .{
            .session = self.session,
            .participant = self.participant,
            .baseline_id = self.active_baseline_id,
            .sequence = sequence,
        } };
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
        self.vehicle_prediction.transportDisconnected();
        self.pending_vehicle_action = null;
        self.pending_interaction_action = null;
        self.pending_snapshot_ack = null;
    }

    pub fn localPresentation(self: *const Client) ?protocol.CharacterState {
        if (!self.prediction.initialized) return null;
        return self.prediction.presentation();
    }

    pub fn localVehiclePresentation(self: *const Client) ?protocol.VehicleState {
        if (!self.vehicle_prediction.initialized) return null;
        return self.vehicle_prediction.presentation();
    }

    pub fn ownedVehicle(self: *const Client) ?protocol.VehicleState {
        for (self.world.vehicleSlice()) |entry| {
            if (entry.current.driver) |driver| {
                if (std.meta.eql(driver, self.participant)) return entry.current;
            }
        }
        return null;
    }

    pub fn heldCarryable(self: *const Client) ?protocol.CarryableState {
        for (self.world.carryableSlice()) |entry| {
            if (entry.current.holder) |holder| {
                if (std.meta.eql(holder, self.participant)) return entry.current;
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
            .interaction_actions_accepted = self.interaction_actions_accepted,
            .interaction_actions_rejected = self.interaction_actions_rejected,
            .baselines_applied = self.baselines_applied,
            .delta_snapshots_applied = self.delta_snapshots_applied,
            .full_snapshots_applied = self.full_snapshots_applied,
            .delta_base_misses = self.delta_base_misses,
            .active_baseline_id = self.active_baseline_id,
            .last_server_tick = self.world.server_tick,
            .disconnect_reason = self.disconnect_reason,
            .prediction = self.prediction.diagnostics(),
            .vehicle_prediction = self.vehicle_prediction.diagnostics(),
        };
    }

    fn ownedCharacter(self: *const Client) ?protocol.CharacterState {
        for (self.world.slice()) |entry| {
            if (std.meta.eql(entry.current.owner, self.participant)) return entry.current;
        }
        return null;
    }

    fn applySnapshot(self: *Client, snapshot: protocol.Snapshot) !void {
        self.world.apply(snapshot) catch |err| switch (err) {
            error.StaleSnapshot => return,
            else => return err,
        };
        self.last_acknowledged_input = snapshot.acknowledged_input;
        self.snapshots_applied +|= 1;
        if (self.ownedVehicle()) |vehicle| {
            self.prediction.clearOwnership();
            self.vehicle_prediction.reconcile(
                vehicle,
                snapshot.acknowledged_input,
                snapshot.server_tick,
            );
        } else if (self.ownedCharacter()) |character| {
            self.vehicle_prediction.clearOwnership();
            self.prediction.reconcile(character, snapshot.acknowledged_input);
        } else {
            self.prediction.clearOwnership();
            self.vehicle_prediction.clearOwnership();
        }
    }

    fn applyNetworkSnapshot(self: *Client, snapshot: protocol.Snapshot) !void {
        if (self.world.initialized and !snapshot.sequence.newerThan(self.world.sequence)) {
            self.world.stale_snapshots +|= 1;
            return;
        }
        const materialized = switch (snapshot.kind) {
            .full => snapshot,
            .delta => blk: {
                const base = self.findSnapshot(snapshot.base_sequence) orelse {
                    self.delta_base_misses +|= 1;
                    return;
                };
                break :blk try protocol.materializeDelta(base, snapshot);
            },
        };
        self.applySnapshot(materialized) catch |err| switch (err) {
            error.StaleSnapshot => return,
            else => return err,
        };
        self.rememberSnapshot(materialized);
        self.pending_snapshot_ack = materialized.sequence;
        switch (snapshot.kind) {
            .full => self.full_snapshots_applied +|= 1,
            .delta => self.delta_snapshots_applied +|= 1,
        }
    }

    fn rememberSnapshot(self: *Client, snapshot: protocol.Snapshot) void {
        self.snapshot_history[self.snapshot_history_next] = .{
            .valid = true,
            .snapshot = snapshot,
        };
        self.snapshot_history_next = @intCast(
            (@as(usize, self.snapshot_history_next) + 1) % self.snapshot_history.len,
        );
    }

    fn findSnapshot(
        self: *const Client,
        sequence: identity.SnapshotSequence,
    ) ?protocol.Snapshot {
        for (self.snapshot_history) |record| {
            if (record.valid and std.meta.eql(record.snapshot.sequence, sequence) and
                record.snapshot.baseline_id == self.active_baseline_id)
            {
                return record.snapshot;
            }
        }
        return null;
    }

    fn clearSnapshotHistory(self: *Client) void {
        self.snapshot_history = @splat(.{});
        self.snapshot_history_next = 0;
        self.pending_snapshot_ack = null;
    }
};

const SnapshotRecord = struct {
    valid: bool = false,
    snapshot: protocol.Snapshot = protocol.Snapshot.empty(),
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
    const before_prediction = client.localVehiclePresentation() orelse
        return error.MissingVehiclePrediction;
    try std.testing.expect((try client.vehicleInput(
        2,
        snapshot.vehicles[0].entity,
        1,
        0,
        0,
        0,
    )) == .vehicle_input);
    const after_prediction = client.localVehiclePresentation() orelse
        return error.MissingVehiclePrediction;
    try std.testing.expect(after_prediction.position[2] < before_prediction.position[2]);
    try std.testing.expectError(
        error.CharacterControlUnavailable,
        client.input(2, .{ 0, 1 }, 0, false),
    );

    snapshot.sequence.value = 3;
    snapshot.server_tick = 2;
    snapshot.acknowledged_input.value = 1;
    snapshot.vehicles[0].driver = null;
    try client.receive(.{ .snapshot = snapshot });
    try std.testing.expect(client.localVehiclePresentation() == null);
}

test "carry interaction follows snapshot ownership and reliable action correlation" {
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
    snapshot.carryable_count = 1;
    snapshot.carryables[0] = .{
        .entity = .{ .index = 21, .generation = 1 },
        .position = .{ 0, 1, 0 },
        .rotation = .{ 0, 0, 0, 1 },
        .linear_velocity = .{ 0, 0, 0 },
        .angular_velocity = .{ 0, 0, 0 },
        .half_extents = .{ 0.35, 0.35, 0.35 },
        .holder = null,
    };
    try client.receive(.{ .snapshot = snapshot });
    const collect = (try client.interactionAction(
        .collect,
        snapshot.carryables[0].entity,
    )).interaction_action;
    try client.receive(.{ .interaction_action_result = .{
        .sequence = collect.sequence,
        .carryable = collect.carryable,
        .action = collect.kind,
        .disposition = .collected,
    } });
    snapshot.sequence.value = 2;
    snapshot.carryables[0].holder = participant;
    try client.receive(.{ .snapshot = snapshot });
    try std.testing.expect(client.heldCarryable() != null);

    const drop = (try client.interactionAction(
        .drop,
        snapshot.carryables[0].entity,
    )).interaction_action;
    try client.receive(.{ .interaction_action_result = .{
        .sequence = drop.sequence,
        .carryable = drop.carryable,
        .action = drop.kind,
        .disposition = .dropped,
    } });
    snapshot.sequence.value = 3;
    snapshot.carryables[0].holder = null;
    try client.receive(.{ .snapshot = snapshot });
    try std.testing.expect(client.heldCarryable() == null);
    try std.testing.expectEqual(@as(u64, 2), client.interaction_actions_accepted);
}
