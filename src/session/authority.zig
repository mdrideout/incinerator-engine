//! Server-authoritative MP2 session for the character vertical slice.
//!
//! Transport ownership is outside this module. It accepts copied, decoded
//! semantic messages associated with an opaque transport connection and emits
//! bounded messages plus explicit close policy.

const std = @import("std");
const engine = @import("incinerator_engine");
const sandbox = @import("sandbox_simulation");
const budgets = @import("session_budgets");
const identity = @import("session_identity");
const protocol = @import("session_protocol");
const transport_policy = @import("session_transport_policy");

pub const TransportConnection = struct { value: u32 };

pub const Delivery = transport_policy.Delivery;
pub const Lane = transport_policy.Lane;

pub const Outbound = struct {
    connection: TransportConnection,
    message: protocol.ServerMessage,
    delivery: Delivery,
    lane: Lane,
    close_after_send: bool = false,
};

const Outbox = engine.BoundedQueue(Outbound, budgets.outbound_message_capacity);

const ConnectionSlot = struct {
    active: bool = false,
    generation: u16 = 0,
    transport: TransportConnection = .{ .value = 0 },
    participant_index: ?u8 = null,
    opened_tick: u64 = 0,
    last_message_tick: u64 = 0,
    received_messages: u64 = 0,
    rejected_messages: u64 = 0,
    input_quota_tick: u64 = 0,
    input_messages_this_tick: u16 = 0,
};

const ParticipantSlot = struct {
    active: bool = false,
    generation: u16 = 0,
    account: identity.AccountId = .{ .value = 0 },
    connection_index: ?u8 = null,
    reconnect: identity.ReconnectToken = .invalid,
    reconnect_deadline_tick: u64 = 0,
    character: ?sandbox.PersistentId = null,
    replicated: identity.ReplicatedEntityId = .invalid,
    last_input: identity.InputSequence = .{ .value = 0 },
    held_input: ?protocol.InputFrame = null,
    last_input_arrival_tick: u64 = 0,
    spawn_pending: bool = false,
    despawn_pending: bool = false,
};

pub const Diagnostics = struct {
    tick: u64,
    active_connections: u16,
    active_participants: u16,
    connected_participants: u16,
    reconnecting_participants: u16,
    outbox_occupancy: u16,
    outbox_high_water: u16,
    accepted_messages: u64,
    rejected_messages: u64,
    malformed_messages: u64,
    snapshots_emitted: u64,
    reconnects: u64,
    stale_inputs: u64,
    quota_violations: u64,
    ingress_entries: u16,
    ingress_high_water: u16,
    ingress_overwrites: u64,
    ingress_fingerprint: u64,
};

pub const AcceptedIngress = struct {
    admitted_tick: u64,
    account: identity.AccountId,
    participant: identity.ParticipantId,
    connection: identity.ConnectionId,
    sequence: identity.InputSequence,
    target_tick: u64,
    move: [2]f32,
    facing_yaw: f32,
    jump_pressed: bool,
};

const IngressJournal = struct {
    records: [budgets.accepted_ingress_capacity]AcceptedIngress = undefined,
    start: u16 = 0,
    count: u16 = 0,
    high_water: u16 = 0,
    overwrites: u64 = 0,
    fingerprint: u64 = 0x4d50_3300_0000_0001,

    fn append(self: *IngressJournal, record: AcceptedIngress) void {
        const index = if (self.count < self.records.len) blk: {
            const next = (@as(usize, self.start) + self.count) % self.records.len;
            self.count += 1;
            self.high_water = @max(self.high_water, self.count);
            break :blk next;
        } else blk: {
            const next = self.start;
            self.start = @intCast((@as(usize, self.start) + 1) % self.records.len);
            self.overwrites +|= 1;
            break :blk next;
        };
        self.records[index] = record;
        self.fingerprint = fingerprintIngress(self.fingerprint, record);
    }

    fn copy(self: *const IngressJournal, output: []AcceptedIngress) usize {
        const amount = @min(output.len, self.count);
        for (output[0..amount], 0..) |*record, offset| {
            const index = (@as(usize, self.start) + offset) % self.records.len;
            record.* = self.records[index];
        }
        return amount;
    }
};

pub const Authority = struct {
    simulation: sandbox.Simulation,
    session: identity.SessionId,
    connections: [budgets.max_participants]ConnectionSlot = @splat(.{}),
    participants: [budgets.max_participants]ParticipantSlot = @splat(.{}),
    outbox: Outbox = .{},
    outbox_high_water: u16 = 0,
    accepted_messages: u64 = 0,
    rejected_messages: u64 = 0,
    malformed_messages: u64 = 0,
    snapshots_emitted: u64 = 0,
    reconnects: u64 = 0,
    stale_inputs: u64 = 0,
    quota_violations: u64 = 0,
    ingress: IngressJournal = .{},
    force_snapshot: bool = false,

    pub fn init(allocator: std.mem.Allocator) !Authority {
        return .{
            .simulation = try sandbox.Simulation.init(allocator, .{
                .namespace = 0x4d50_3201,
                .fixed_delta_seconds = 1.0 /
                    @as(f32, @floatFromInt(budgets.authority_tick_hz)),
                .create_ground = true,
                .character = .{ .max_characters = budgets.max_participants },
            }),
            .session = .{ .value = 0x4d50_3200_0000_0001 },
        };
    }

    pub fn deinit(self: *Authority) void {
        self.simulation.deinit();
        self.* = undefined;
    }

    pub fn openConnection(
        self: *Authority,
        transport: TransportConnection,
    ) !identity.ConnectionId {
        if (transport.value == 0) return error.InvalidTransportConnection;
        if (self.findConnection(transport) != null) return error.DuplicateTransportConnection;
        for (&self.connections, 0..) |*slot, index| {
            if (slot.active) continue;
            slot.generation +%= 1;
            if (slot.generation == 0) slot.generation = 1;
            slot.active = true;
            slot.transport = transport;
            slot.participant_index = null;
            slot.opened_tick = self.simulation.tickIndex();
            slot.last_message_tick = slot.opened_tick;
            slot.received_messages = 0;
            slot.rejected_messages = 0;
            slot.input_quota_tick = slot.opened_tick;
            slot.input_messages_this_tick = 0;
            return .{ .index = @intCast(index + 1), .generation = slot.generation };
        }
        return error.ConnectionCapacityReached;
    }

    pub fn transportClosed(
        self: *Authority,
        transport: TransportConnection,
    ) void {
        const connection_index = self.findConnection(transport) orelse return;
        self.detachConnection(connection_index, true);
    }

    pub fn ingestBytes(
        self: *Authority,
        transport: TransportConnection,
        bytes: []const u8,
    ) !void {
        const message = protocol.decodeClient(bytes) catch {
            self.malformed_messages +|= 1;
            try self.rejectTransport(transport, .malformed, true);
            return;
        };
        try self.ingest(transport, message);
    }

    pub fn ingest(
        self: *Authority,
        transport: TransportConnection,
        message: protocol.ClientMessage,
    ) !void {
        const connection_index = self.findConnection(transport) orelse
            return error.UnknownTransportConnection;
        const connection = &self.connections[connection_index];
        connection.received_messages +|= 1;
        connection.last_message_tick = self.simulation.tickIndex();

        switch (message) {
            .hello => |hello| try self.ingestHello(connection_index, hello),
            .input => |input| try self.ingestInput(connection_index, input),
            .disconnect => |reason| try self.ingestDisconnect(connection_index, reason),
        }
    }

    pub fn tick(self: *Authority) !void {
        try self.expireConnections(self.simulation.tickIndex());
        try self.expireReconnects();
        try self.applyHeldInputs(self.simulation.tickIndex());
        try self.simulation.tick();
        try self.processCharacterOutcomes();
        const tick_index = self.simulation.tickIndex();
        if (self.force_snapshot or tick_index % budgets.ticks_per_snapshot == 0) {
            try self.publishSnapshots();
            self.force_snapshot = false;
        }
    }

    pub fn pollOutbound(self: *Authority) ?Outbound {
        return self.outbox.pop();
    }

    pub fn stop(self: *Authority) !void {
        for (0..self.connections.len) |connection_index| {
            if (!self.connections[connection_index].active) continue;
            try self.queue(.{
                .connection = self.connections[connection_index].transport,
                .message = .{ .disconnected = .authority_stopping },
                .delivery = .reliable,
                .lane = .control,
                .close_after_send = true,
            });
            self.detachConnection(connection_index, false);
        }
    }

    pub fn copyAcceptedIngress(
        self: *const Authority,
        output: []AcceptedIngress,
    ) usize {
        return self.ingress.copy(output);
    }

    pub fn rejectOversized(
        self: *Authority,
        transport: TransportConnection,
    ) !void {
        try self.rejectTransport(transport, .oversized, true);
    }

    pub fn diagnostics(self: *const Authority) Diagnostics {
        var active_connections: u16 = 0;
        var active_participants: u16 = 0;
        var connected_participants: u16 = 0;
        var reconnecting_participants: u16 = 0;
        for (self.connections) |connection| active_connections += @intFromBool(connection.active);
        for (self.participants) |participant| {
            active_participants += @intFromBool(participant.active);
            connected_participants += @intFromBool(
                participant.active and participant.connection_index != null,
            );
            reconnecting_participants += @intFromBool(
                participant.active and participant.connection_index == null and
                    !participant.despawn_pending,
            );
        }
        return .{
            .tick = self.simulation.tickIndex(),
            .active_connections = active_connections,
            .active_participants = active_participants,
            .connected_participants = connected_participants,
            .reconnecting_participants = reconnecting_participants,
            .outbox_occupancy = @intCast(self.outbox.len),
            .outbox_high_water = self.outbox_high_water,
            .accepted_messages = self.accepted_messages,
            .rejected_messages = self.rejected_messages,
            .malformed_messages = self.malformed_messages,
            .snapshots_emitted = self.snapshots_emitted,
            .reconnects = self.reconnects,
            .stale_inputs = self.stale_inputs,
            .quota_violations = self.quota_violations,
            .ingress_entries = self.ingress.count,
            .ingress_high_water = self.ingress.high_water,
            .ingress_overwrites = self.ingress.overwrites,
            .ingress_fingerprint = self.ingress.fingerprint,
        };
    }

    fn ingestHello(self: *Authority, connection_index: usize, hello: protocol.Hello) !void {
        if (self.connections[connection_index].participant_index != null) {
            try self.rejectConnection(connection_index, .invalid_state, false);
            return;
        }
        if (hello.protocol != protocol.wire_version) {
            try self.rejectConnection(connection_index, .protocol_mismatch, true);
            return;
        }
        if (hello.build != protocol.build_cohort) {
            try self.rejectConnection(connection_index, .build_mismatch, true);
            return;
        }
        if (hello.content != protocol.content_cohort) {
            try self.rejectConnection(connection_index, .content_mismatch, true);
            return;
        }
        hello.account.validate() catch {
            try self.rejectConnection(connection_index, .unauthorized, true);
            return;
        };

        if (hello.reconnect.isValid()) {
            if (try self.tryReconnect(connection_index, hello)) return;
            try self.rejectConnection(connection_index, .reconnect_expired, true);
            return;
        }

        for (self.participants) |participant| {
            if (participant.active and std.meta.eql(participant.account, hello.account)) {
                try self.rejectConnection(connection_index, .unauthorized, true);
                return;
            }
        }
        const participant_index = self.allocateParticipant() orelse {
            try self.rejectConnection(connection_index, .session_full, true);
            return;
        };
        const participant = &self.participants[participant_index];
        participant.account = hello.account;
        participant.connection_index = @intCast(connection_index);
        participant.reconnect = reconnectToken(
            self.session,
            hello.account,
            participantId(participant_index, participant.generation),
        );
        participant.replicated = .{
            .index = @intCast(participant_index + 1),
            .generation = participant.generation,
        };
        participant.spawn_pending = true;
        self.connections[connection_index].participant_index = @intCast(participant_index);
        const lane = participant_index % 4;
        const row = participant_index / 4;
        try self.simulation.submitCharacter(.{ .spawn = .{
            .request_id = spawnRequestId(participant_index, participant.generation),
            .position = .{
                @as(f32, @floatFromInt(lane)) * 2.0 - 3.0,
                0,
                @as(f32, @floatFromInt(row)) * 2.0,
            },
        } });
        try self.queueWelcome(connection_index, participant_index);
        self.accepted_messages +|= 1;
        self.force_snapshot = true;
    }

    fn tryReconnect(
        self: *Authority,
        connection_index: usize,
        hello: protocol.Hello,
    ) !bool {
        const tick_index = self.simulation.tickIndex();
        for (&self.participants, 0..) |*participant, participant_index| {
            if (!participant.active or participant.connection_index != null or
                participant.despawn_pending or
                !std.meta.eql(participant.account, hello.account) or
                !std.meta.eql(participant.reconnect, hello.reconnect) or
                tick_index > participant.reconnect_deadline_tick)
            {
                continue;
            }
            participant.connection_index = @intCast(connection_index);
            self.connections[connection_index].participant_index = @intCast(participant_index);
            try self.queueWelcome(connection_index, participant_index);
            self.reconnects +|= 1;
            self.accepted_messages +|= 1;
            self.force_snapshot = true;
            return true;
        }
        return false;
    }

    fn ingestInput(
        self: *Authority,
        connection_index: usize,
        input: protocol.InputFrame,
    ) !void {
        const tick_index = self.simulation.tickIndex();
        const connection = &self.connections[connection_index];
        if (connection.input_quota_tick != tick_index) {
            connection.input_quota_tick = tick_index;
            connection.input_messages_this_tick = 0;
        }
        if (connection.input_messages_this_tick >= budgets.max_input_messages_per_tick) {
            self.quota_violations +|= 1;
            try self.rejectConnection(connection_index, .quota_exceeded, true);
            return;
        }
        connection.input_messages_this_tick += 1;
        const participant_index = self.connections[connection_index].participant_index orelse {
            try self.rejectConnection(connection_index, .unauthorized, false);
            return;
        };
        const participant = &self.participants[participant_index];
        if (!std.meta.eql(input.session, self.session) or
            !std.meta.eql(input.participant, participantId(
                participant_index,
                participant.generation,
            )))
        {
            try self.rejectConnection(connection_index, .stale_connection, false);
            return;
        }
        if (!input.sequence.newerThan(participant.last_input)) {
            self.stale_inputs +|= 1;
            return;
        }
        if (input.target_tick > tick_index + budgets.max_future_input_ticks or
            input.target_tick + budgets.input_history_ticks < tick_index)
        {
            try self.rejectConnection(connection_index, .stale_sequence, false);
            return;
        }
        if (participant.character == null and !participant.spawn_pending) {
            try self.rejectConnection(connection_index, .invalid_state, false);
            return;
        }
        participant.held_input = input;
        participant.last_input_arrival_tick = tick_index;
        participant.last_input = input.sequence;
        self.ingress.append(.{
            .admitted_tick = tick_index,
            .account = participant.account,
            .participant = participantId(participant_index, participant.generation),
            .connection = .{
                .index = @intCast(connection_index + 1),
                .generation = self.connections[connection_index].generation,
            },
            .sequence = input.sequence,
            .target_tick = input.target_tick,
            .move = input.move,
            .facing_yaw = input.facing_yaw,
            .jump_pressed = input.jump_pressed,
        });
        self.accepted_messages +|= 1;
    }

    fn applyHeldInputs(self: *Authority, tick_index: u64) !void {
        for (&self.participants) |*participant| {
            if (!participant.active or participant.connection_index == null or
                participant.character == null or participant.despawn_pending)
            {
                continue;
            }
            const input = participant.held_input orelse continue;
            if (tick_index -| participant.last_input_arrival_tick > budgets.input_hold_ticks) {
                participant.held_input = null;
                continue;
            }
            try self.simulation.submitCharacter(.{ .actions = .{
                .id = participant.character.?,
                .move = input.move,
                .facing_yaw = input.facing_yaw,
                .jump_pressed = input.jump_pressed and
                    tick_index == participant.last_input_arrival_tick,
            } });
        }
    }

    fn ingestDisconnect(
        self: *Authority,
        connection_index: usize,
        reason: protocol.DisconnectReason,
    ) !void {
        _ = reason;
        if (self.connections[connection_index].participant_index) |participant_index| {
            try self.beginParticipantDespawn(participant_index);
        }
        try self.queue(.{
            .connection = self.connections[connection_index].transport,
            .message = .{ .disconnected = .requested },
            .delivery = .reliable,
            .lane = .control,
            .close_after_send = true,
        });
        self.detachConnection(connection_index, false);
        self.accepted_messages +|= 1;
    }

    fn expireConnections(self: *Authority, tick_index: u64) !void {
        for (0..self.connections.len) |connection_index| {
            const connection = self.connections[connection_index];
            if (!connection.active) continue;
            if (connection.participant_index == null and
                tick_index -| connection.opened_tick >= budgets.handshake_timeout_ticks)
            {
                try self.rejectConnection(connection_index, .invalid_state, true);
                continue;
            }
            if (connection.participant_index != null and
                tick_index -| connection.last_message_tick >= budgets.idle_timeout_ticks)
            {
                try self.queue(.{
                    .connection = connection.transport,
                    .message = .{ .disconnected = .timeout },
                    .delivery = .reliable,
                    .lane = .control,
                    .close_after_send = true,
                });
                self.detachConnection(connection_index, true);
            }
        }
    }

    fn expireReconnects(self: *Authority) !void {
        const tick_index = self.simulation.tickIndex();
        for (&self.participants, 0..) |participant, index| {
            if (participant.active and participant.connection_index == null and
                !participant.despawn_pending and tick_index >= participant.reconnect_deadline_tick)
            {
                try self.beginParticipantDespawn(index);
            }
        }
    }

    fn beginParticipantDespawn(self: *Authority, participant_index: usize) !void {
        const participant = &self.participants[participant_index];
        if (!participant.active or participant.despawn_pending) return;
        if (participant.character) |character| {
            try self.simulation.submitCharacter(.{ .despawn = .{ .id = character } });
            participant.despawn_pending = true;
        } else if (!participant.spawn_pending) {
            participant.active = false;
        } else {
            participant.despawn_pending = true;
        }
    }

    fn processCharacterOutcomes(self: *Authority) !void {
        while (self.simulation.pollCharacterOutcome()) |outcome| switch (outcome) {
            .spawned => |spawned| {
                const decoded = decodeSpawnRequestId(spawned.request_id) orelse
                    return error.UnexpectedCharacterSpawnOutcome;
                const participant = &self.participants[decoded.index];
                if (!participant.active or participant.generation != decoded.generation or
                    !participant.spawn_pending)
                {
                    return error.StaleCharacterSpawnOutcome;
                }
                participant.spawn_pending = false;
                participant.character = spawned.id;
                if (participant.despawn_pending) {
                    try self.simulation.submitCharacter(.{ .despawn = .{ .id = spawned.id } });
                }
                self.force_snapshot = true;
            },
            .despawned => |id| {
                for (&self.participants) |*participant| {
                    if (participant.active and participant.character != null and
                        std.meta.eql(participant.character.?, id))
                    {
                        participant.active = false;
                        participant.connection_index = null;
                        participant.character = null;
                        participant.spawn_pending = false;
                        participant.despawn_pending = false;
                        self.force_snapshot = true;
                        break;
                    }
                }
            },
            .rejected => |rejected| {
                if (rejected.request_id) |request_id| {
                    const decoded = decodeSpawnRequestId(request_id) orelse
                        return error.UnexpectedCharacterRejection;
                    const participant = &self.participants[decoded.index];
                    if (participant.connection_index) |connection_index| {
                        try self.rejectConnection(connection_index, .invalid_state, true);
                    }
                    participant.active = false;
                } else return error.UnexpectedCharacterRejection;
            },
        };
        while (self.simulation.pollCharacterEvent() != null) {}
    }

    fn publishSnapshots(self: *Authority) !void {
        var template = protocol.Snapshot.empty();
        template.sequence.value = @truncate(self.simulation.tickIndex() /
            budgets.ticks_per_snapshot + 1);
        template.server_tick = self.simulation.tickIndex();
        for (self.participants, 0..) |participant, participant_index| {
            if (!participant.active or participant.character == null or
                participant.despawn_pending) continue;
            if (template.count == budgets.max_participants) break;
            const view = try self.simulation.character(participant.character.?);
            template.characters[template.count] = .{
                .entity = participant.replicated,
                .owner = participantId(participant_index, participant.generation),
                .position = view.position,
                .velocity = view.velocity,
                .facing_yaw = view.facing_yaw,
            };
            template.count += 1;
        }
        for (self.participants, 0..) |participant, participant_index| {
            const connection_index = participant.connection_index orelse continue;
            if (!participant.active or !self.connections[connection_index].active) continue;
            var snapshot = template;
            snapshot.acknowledged_input = self.participants[participant_index].last_input;
            try self.queue(.{
                .connection = self.connections[connection_index].transport,
                .message = .{ .snapshot = snapshot },
                .delivery = .unreliable,
                .lane = .snapshot,
            });
            self.snapshots_emitted +|= 1;
        }
    }

    fn allocateParticipant(self: *Authority) ?usize {
        for (&self.participants, 0..) |*participant, index| {
            if (participant.active) continue;
            participant.generation +%= 1;
            if (participant.generation == 0) participant.generation = 1;
            participant.active = true;
            participant.connection_index = null;
            participant.reconnect_deadline_tick = 0;
            participant.character = null;
            participant.replicated = .invalid;
            participant.last_input = .{ .value = 0 };
            participant.held_input = null;
            participant.last_input_arrival_tick = 0;
            participant.spawn_pending = false;
            participant.despawn_pending = false;
            return index;
        }
        return null;
    }

    fn detachConnection(self: *Authority, connection_index: usize, allow_reconnect: bool) void {
        const connection = &self.connections[connection_index];
        if (!connection.active) return;
        if (connection.participant_index) |participant_index| {
            const participant = &self.participants[participant_index];
            if (participant.active and participant.connection_index != null and
                @as(usize, participant.connection_index.?) == connection_index)
            {
                participant.connection_index = null;
                participant.held_input = null;
                participant.reconnect_deadline_tick = if (allow_reconnect)
                    self.simulation.tickIndex() + budgets.reconnect_grace_ticks
                else
                    self.simulation.tickIndex();
            }
        }
        connection.active = false;
        connection.transport = .{ .value = 0 };
        connection.participant_index = null;
    }

    fn queueWelcome(
        self: *Authority,
        connection_index: usize,
        participant_index: usize,
    ) !void {
        const participant = self.participants[participant_index];
        try self.queue(.{
            .connection = self.connections[connection_index].transport,
            .message = .{ .welcome = .{
                .session = self.session,
                .participant = participantId(participant_index, participant.generation),
                .connection = .{
                    .index = @intCast(connection_index + 1),
                    .generation = self.connections[connection_index].generation,
                },
                .reconnect = participant.reconnect,
                .authority_tick = self.simulation.tickIndex(),
            } },
            .delivery = .reliable,
            .lane = .control,
        });
    }

    fn rejectTransport(
        self: *Authority,
        transport: TransportConnection,
        reason: protocol.RejectionReason,
        close_after_send: bool,
    ) !void {
        const connection_index = self.findConnection(transport) orelse
            return error.UnknownTransportConnection;
        try self.rejectConnection(connection_index, reason, close_after_send);
    }

    fn rejectConnection(
        self: *Authority,
        connection_index: usize,
        reason: protocol.RejectionReason,
        close_after_send: bool,
    ) !void {
        self.connections[connection_index].rejected_messages +|= 1;
        self.rejected_messages +|= 1;
        try self.queue(.{
            .connection = self.connections[connection_index].transport,
            .message = .{ .rejected = .{ .reason = reason } },
            .delivery = .reliable,
            .lane = .control,
            .close_after_send = close_after_send,
        });
        if (close_after_send) self.detachConnection(connection_index, false);
    }

    fn queue(self: *Authority, outbound: Outbound) !void {
        try self.outbox.push(outbound);
        self.outbox_high_water = @max(self.outbox_high_water, @as(u16, @intCast(self.outbox.len)));
    }

    fn findConnection(self: *const Authority, transport: TransportConnection) ?usize {
        for (self.connections, 0..) |connection, index| {
            if (connection.active and connection.transport.value == transport.value) return index;
        }
        return null;
    }
};

fn participantId(index: usize, generation: u16) identity.ParticipantId {
    return .{ .index = @intCast(index + 1), .generation = generation };
}

fn fingerprintIngress(seed: u64, record: AcceptedIngress) u64 {
    var result = seed;
    inline for (.{
        record.admitted_tick,
        record.account.value,
        @as(u64, record.participant.index),
        @as(u64, record.participant.generation),
        @as(u64, record.connection.index),
        @as(u64, record.connection.generation),
        @as(u64, record.sequence.value),
        record.target_tick,
        @as(u64, @as(u32, @bitCast(record.move[0]))),
        @as(u64, @as(u32, @bitCast(record.move[1]))),
        @as(u64, @as(u32, @bitCast(record.facing_yaw))),
        @as(u64, @intFromBool(record.jump_pressed)),
    }) |value| {
        var stable: u64 = value;
        result = std.hash.Wyhash.hash(result, std.mem.asBytes(&stable));
    }
    return result;
}

fn reconnectToken(
    session: identity.SessionId,
    account: identity.AccountId,
    participant: identity.ParticipantId,
) identity.ReconnectToken {
    return .{
        .high = session.value ^ account.value ^ 0xa65f_19d3_c41b_7201,
        .low = (@as(u64, participant.generation) << 48) |
            (@as(u64, participant.index) << 32) | 0x7f31_a9c5,
    };
}

fn spawnRequestId(index: usize, generation: u16) u64 {
    return 0x4d50_3200_0000_0000 |
        (@as(u64, generation) << 16) |
        @as(u64, @intCast(index + 1));
}

fn decodeSpawnRequestId(value: u64) ?struct { index: usize, generation: u16 } {
    if (value & 0xffff_ffff_0000_0000 != 0x4d50_3200_0000_0000) return null;
    const raw_index: u16 = @truncate(value);
    if (raw_index == 0 or raw_index > budgets.max_participants) return null;
    return .{
        .index = raw_index - 1,
        .generation = @truncate(value >> 16),
    };
}

test "authority admits two participants and emits join-in-progress snapshots" {
    var authority = try Authority.init(std.testing.allocator);
    defer authority.deinit();

    _ = try authority.openConnection(.{ .value = 101 });
    try authority.ingest(.{ .value = 101 }, .{ .hello = .{
        .account = .{ .value = 1 },
    } });
    const welcome_one = authority.pollOutbound().?.message.welcome;
    try authority.tick();
    const first_snapshot = authority.pollOutbound().?.message.snapshot;
    try std.testing.expectEqual(@as(u8, 1), first_snapshot.count);

    _ = try authority.openConnection(.{ .value = 202 });
    try authority.ingest(.{ .value = 202 }, .{ .hello = .{
        .account = .{ .value = 2 },
    } });
    _ = authority.pollOutbound().?.message.welcome;
    try authority.tick();
    var saw_two = false;
    while (authority.pollOutbound()) |outbound| switch (outbound.message) {
        .snapshot => |snapshot| saw_two = saw_two or snapshot.count == 2,
        else => {},
    };
    try std.testing.expect(saw_two);

    authority.transportClosed(.{ .value = 101 });
    _ = try authority.openConnection(.{ .value = 303 });
    try authority.ingest(.{ .value = 303 }, .{ .hello = .{
        .account = .{ .value = 1 },
        .reconnect = welcome_one.reconnect,
    } });
    const reconnected = authority.pollOutbound().?.message.welcome;
    try std.testing.expect(std.meta.eql(welcome_one.participant, reconnected.participant));
    try std.testing.expectEqual(@as(u64, 1), authority.diagnostics().reconnects);
}

test "authority drops stale input without terminating an unreliable stream" {
    var authority = try Authority.init(std.testing.allocator);
    defer authority.deinit();
    _ = try authority.openConnection(.{ .value = 1 });
    try authority.ingest(.{ .value = 1 }, .{ .hello = .{
        .account = .{ .value = 1 },
    } });
    const welcome = authority.pollOutbound().?.message.welcome;
    try authority.tick();
    while (authority.pollOutbound() != null) {}
    const input = protocol.ClientMessage{ .input = .{
        .session = welcome.session,
        .participant = welcome.participant,
        .sequence = .{ .value = 1 },
        .target_tick = authority.diagnostics().tick + 1,
        .move = .{ 0, -1 },
        .facing_yaw = 0,
        .jump_pressed = false,
    } };
    try authority.ingest(.{ .value = 1 }, input);
    try authority.ingest(.{ .value = 1 }, input);
    try std.testing.expectEqual(@as(u64, 1), authority.diagnostics().stale_inputs);
    try std.testing.expectEqual(@as(u64, 0), authority.diagnostics().rejected_messages);
    try std.testing.expectEqual(@as(u16, 1), authority.diagnostics().ingress_entries);
    var ingress: [1]AcceptedIngress = undefined;
    try std.testing.expectEqual(@as(usize, 1), authority.copyAcceptedIngress(&ingress));
    try std.testing.expectEqual(@as(u32, 1), ingress[0].sequence.value);
}

test "authority shutdown is a reliable terminal semantic message" {
    var authority = try Authority.init(std.testing.allocator);
    defer authority.deinit();
    _ = try authority.openConnection(.{ .value = 1 });
    try authority.ingest(.{ .value = 1 }, .{ .hello = .{
        .account = .{ .value = 1 },
    } });
    while (authority.pollOutbound() != null) {}
    try authority.stop();
    const outbound = authority.pollOutbound().?;
    try std.testing.expectEqual(protocol.DisconnectReason.authority_stopping, outbound.message.disconnected);
    try std.testing.expect(outbound.close_after_send);
    try std.testing.expectEqual(Delivery.reliable, outbound.delivery);
}

test "per-tick input quota terminates abusive ingress without growth" {
    var authority = try Authority.init(std.testing.allocator);
    defer authority.deinit();
    _ = try authority.openConnection(.{ .value = 1 });
    try authority.ingest(.{ .value = 1 }, .{ .hello = .{
        .account = .{ .value = 1 },
    } });
    const welcome = authority.pollOutbound().?.message.welcome;
    try authority.tick();
    while (authority.pollOutbound() != null) {}
    for (1..budgets.max_input_messages_per_tick + 2) |sequence| {
        try authority.ingest(.{ .value = 1 }, .{ .input = .{
            .session = welcome.session,
            .participant = welcome.participant,
            .sequence = .{ .value = @intCast(sequence) },
            .target_tick = authority.diagnostics().tick + 1,
            .move = .{ 1, 0 },
            .facing_yaw = 0,
            .jump_pressed = false,
        } });
        if (authority.diagnostics().quota_violations != 0) break;
    }
    try std.testing.expectEqual(@as(u64, 1), authority.diagnostics().quota_violations);
    try std.testing.expectEqual(@as(u16, 0), authority.diagnostics().active_connections);
    try std.testing.expectEqual(
        protocol.RejectionReason.quota_exceeded,
        authority.pollOutbound().?.message.rejected.reason,
    );
}

test "terminal admission failures release connections without partial participants" {
    var authority = try Authority.init(std.testing.allocator);
    defer authority.deinit();

    _ = try authority.openConnection(.{ .value = 1 });
    try authority.ingest(.{ .value = 1 }, .{ .hello = .{
        .build = protocol.build_cohort + 1,
        .account = .{ .value = 1 },
    } });
    try std.testing.expectEqual(
        protocol.RejectionReason.build_mismatch,
        authority.pollOutbound().?.message.rejected.reason,
    );
    try std.testing.expectEqual(@as(u16, 0), authority.diagnostics().active_connections);
    try std.testing.expectEqual(@as(u16, 0), authority.diagnostics().active_participants);

    _ = try authority.openConnection(.{ .value = 2 });
    try authority.rejectOversized(.{ .value = 2 });
    try std.testing.expectEqual(
        protocol.RejectionReason.oversized,
        authority.pollOutbound().?.message.rejected.reason,
    );
    try std.testing.expectEqual(@as(u16, 0), authority.diagnostics().active_connections);

    _ = try authority.openConnection(.{ .value = 3 });
    try authority.ingestBytes(.{ .value = 3 }, &.{ 0, 1, 2 });
    try std.testing.expectEqual(
        protocol.RejectionReason.malformed,
        authority.pollOutbound().?.message.rejected.reason,
    );
    try std.testing.expectEqual(@as(u64, 1), authority.diagnostics().malformed_messages);
    try std.testing.expectEqual(@as(u16, 0), authority.diagnostics().active_participants);
}

test "duplicate account and connection timeouts are bounded session decisions" {
    var authority = try Authority.init(std.testing.allocator);
    defer authority.deinit();

    _ = try authority.openConnection(.{ .value = 1 });
    try authority.ingest(.{ .value = 1 }, .{ .hello = .{
        .account = .{ .value = 7 },
    } });
    _ = authority.pollOutbound().?.message.welcome;
    try authority.tick();
    while (authority.pollOutbound() != null) {}

    _ = try authority.openConnection(.{ .value = 2 });
    try authority.ingest(.{ .value = 2 }, .{ .hello = .{
        .account = .{ .value = 7 },
    } });
    try std.testing.expectEqual(
        protocol.RejectionReason.unauthorized,
        authority.pollOutbound().?.message.rejected.reason,
    );
    try std.testing.expectEqual(@as(u16, 1), authority.diagnostics().active_participants);

    _ = try authority.openConnection(.{ .value = 3 });
    try authority.expireConnections(
        authority.simulation.tickIndex() + budgets.handshake_timeout_ticks,
    );
    try std.testing.expectEqual(
        protocol.RejectionReason.invalid_state,
        authority.pollOutbound().?.message.rejected.reason,
    );

    try authority.expireConnections(
        authority.simulation.tickIndex() + budgets.idle_timeout_ticks,
    );
    try std.testing.expectEqual(
        protocol.DisconnectReason.timeout,
        authority.pollOutbound().?.message.disconnected,
    );
    try std.testing.expectEqual(@as(u16, 1), authority.diagnostics().reconnecting_participants);
}
