//! Server-authoritative session for the multiplayer sandbox vertical slices.
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
    event_quota_tick: u64 = 0,
    reliable_events_this_tick: u16 = 0,
};

const ParticipantSlot = struct {
    active: bool = false,
    generation: u16 = 0,
    account: identity.AccountId = .{ .value = 0 },
    external_identity: protocol.ExternalIdentity = .{},
    connection_index: ?u8 = null,
    reconnect: identity.ReconnectToken = .invalid,
    reconnect_deadline_tick: u64 = 0,
    character: ?sandbox.PersistentId = null,
    replicated: identity.ReplicatedEntityId = .invalid,
    last_input: identity.InputSequence = .{ .value = 0 },
    held_input: ?HeldInput = null,
    last_input_arrival_tick: u64 = 0,
    driving_vehicle_index: ?u8 = null,
    last_vehicle_action: identity.ActionSequence = .{ .value = 0 },
    pending_vehicle_action: ?protocol.VehicleAction = null,
    holding_carryable_index: ?u8 = null,
    last_interaction_action: identity.ActionSequence = .{ .value = 0 },
    pending_interaction_action: ?protocol.InteractionAction = null,
    interaction_cleanup_pending: bool = false,
    relevance_coord: sandbox.ChunkCoord = sandbox.navigation_west_coord,
    baseline_id: u32 = 0,
    baseline_acknowledged: u32 = 0,
    baseline_sent: bool = false,
    exit_pending: bool = false,
    spawn_pending: bool = false,
    despawn_pending: bool = false,
};

const HeldInput = union(enum) {
    character: protocol.InputFrame,
    vehicle: protocol.VehicleInputFrame,
};

const VehicleSlot = struct {
    active: bool = false,
    spawn_pending: bool = false,
    generation: u16 = 0,
    persistent: ?sandbox.PersistentId = null,
    replicated: identity.ReplicatedEntityId = .invalid,
};

const CarryableSlot = struct {
    active: bool = false,
    spawn_pending: bool = false,
    generation: u16 = 0,
    persistent: ?sandbox.PersistentId = null,
    replicated: identity.ReplicatedEntityId = .invalid,
};

const NpcSlot = struct {
    active: bool = false,
    spawn_pending: bool = false,
    generation: u16 = 0,
    persistent: ?sandbox.PersistentId = null,
    replicated: identity.ReplicatedEntityId = .invalid,
};

pub const Options = struct {
    downstream_bytes_per_second: usize = budgets.average_client_down_bytes_per_second,
    full_snapshot_interval_ticks: u64 = budgets.full_snapshot_interval_ticks,
    room_admission: ?RoomAdmission = null,
};

pub const RoomAdmission = struct {
    room_id: u64,
    authority_id: u64,
    room_generation: u32,
    secret: protocol.AdmissionSecret,
};

const SnapshotRecord = struct {
    valid: bool = false,
    snapshot: protocol.Snapshot = protocol.Snapshot.empty(),
};

const ReplicationState = struct {
    history: [budgets.snapshot_history_capacity]SnapshotRecord = @splat(.{}),
    history_next: u8 = 0,
    next_sequence: identity.SnapshotSequence = .{ .value = 1 },
    acknowledged_sequence: identity.SnapshotSequence = .{ .value = 0 },
    baseline_sequence: identity.SnapshotSequence = .{ .value = 0 },
    last_ack_tick: u64 = 0,
    last_full_tick: u64 = 0,
    last_sent_tick: u64 = 0,
    byte_credit: usize = 0,
    byte_remainder: usize = 0,
};

const UsedAdmissionNonce = struct {
    nonce: u64 = 0,
    expires_at_unix_seconds: u64 = 0,
};

pub const Diagnostics = struct {
    tick: u64,
    active_connections: u16,
    active_participants: u16,
    active_vehicles: u16,
    active_carryables: u16,
    active_npcs: u16,
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
    invalid_control_inputs: u64,
    vehicle_actions_accepted: u64,
    vehicle_actions_rejected: u64,
    stale_vehicle_actions: u64,
    forced_vehicle_cleanup: u64,
    interaction_actions_accepted: u64,
    interaction_actions_rejected: u64,
    stale_interaction_actions: u64,
    forced_interaction_cleanup: u64,
    baselines_emitted: u64,
    baselines_acknowledged: u64,
    stale_baseline_acks: u64,
    relevance_transfers: u64,
    npc_state_updates: u64,
    delta_snapshots_emitted: u64,
    full_snapshots_emitted: u64,
    snapshot_acks: u64,
    stale_snapshot_acks: u64,
    snapshot_bytes_emitted: u64,
    npc_updates_deprioritized: u64,
    snapshots_budget_deferred: u64,
    starvation_sends: u64,
    full_snapshot_fallbacks: u64,
    baseline_memory_bytes: usize,
    max_relevant_entities: u16,
    max_reliable_events_per_connection_tick: u16,
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
    action_sequence: identity.ActionSequence,
    target_tick: u64,
    kind: Kind,
    move: [2]f32,
    facing_yaw: f32,
    jump_pressed: bool,
    vehicle: identity.ReplicatedEntityId,
    carryable: identity.ReplicatedEntityId = .invalid,
    vehicle_control: [4]f32,

    pub const Kind = enum(u8) {
        character = 1,
        vehicle = 2,
        vehicle_enter = 3,
        vehicle_exit = 4,
        interaction_collect = 5,
        interaction_drop = 6,
    };
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
    allocator: std.mem.Allocator,
    simulation: sandbox.Simulation,
    session: identity.SessionId,
    connections: [budgets.max_participants]ConnectionSlot = @splat(.{}),
    participants: [budgets.max_participants]ParticipantSlot = @splat(.{}),
    vehicles: [budgets.max_vehicles]VehicleSlot = @splat(.{}),
    carryables: [budgets.max_carryables]CarryableSlot = @splat(.{}),
    npcs: [budgets.max_npcs]NpcSlot = @splat(.{}),
    replication: *[budgets.max_participants]ReplicationState,
    options: Options,
    admission_time_unix_seconds: u64 = 0,
    outbox: *Outbox,
    outbox_high_water: u16 = 0,
    accepted_messages: u64 = 0,
    rejected_messages: u64 = 0,
    malformed_messages: u64 = 0,
    snapshots_emitted: u64 = 0,
    reconnects: u64 = 0,
    stale_inputs: u64 = 0,
    quota_violations: u64 = 0,
    invalid_control_inputs: u64 = 0,
    vehicle_actions_accepted: u64 = 0,
    vehicle_actions_rejected: u64 = 0,
    stale_vehicle_actions: u64 = 0,
    forced_vehicle_cleanup: u64 = 0,
    interaction_actions_accepted: u64 = 0,
    interaction_actions_rejected: u64 = 0,
    stale_interaction_actions: u64 = 0,
    forced_interaction_cleanup: u64 = 0,
    baselines_emitted: u64 = 0,
    baselines_acknowledged: u64 = 0,
    stale_baseline_acks: u64 = 0,
    relevance_transfers: u64 = 0,
    npc_state_updates: u64 = 0,
    delta_snapshots_emitted: u64 = 0,
    full_snapshots_emitted: u64 = 0,
    snapshot_acks: u64 = 0,
    stale_snapshot_acks: u64 = 0,
    snapshot_bytes_emitted: u64 = 0,
    npc_updates_deprioritized: u64 = 0,
    snapshots_budget_deferred: u64 = 0,
    starvation_sends: u64 = 0,
    full_snapshot_fallbacks: u64 = 0,
    max_relevant_entities: u16 = 0,
    max_reliable_events_per_connection_tick: u16 = 0,
    used_admission_nonces: [budgets.admission_nonce_history_capacity]UsedAdmissionNonce =
        @splat(.{}),
    active_districts: [2]bool = @splat(false),
    ingress: IngressJournal = .{},
    force_snapshot: bool = false,

    pub fn init(allocator: std.mem.Allocator) !Authority {
        return initWithOptions(allocator, .{});
    }

    pub fn initWithOptions(allocator: std.mem.Allocator, options: Options) !Authority {
        if (options.downstream_bytes_per_second == 0 or
            options.full_snapshot_interval_ticks == 0)
        {
            return error.InvalidReplicationOptions;
        }
        if (options.room_admission) |room| {
            if (room.room_id == 0 or room.authority_id == 0 or
                room.room_generation == 0)
            {
                return error.InvalidRoomAdmissionOptions;
            }
        }
        if (@sizeOf(protocol.Snapshot) * budgets.snapshot_history_capacity >
            budgets.max_baseline_bytes_per_client)
        {
            return error.BaselineMemoryBudgetExceeded;
        }
        const outbox = try allocator.create(Outbox);
        errdefer allocator.destroy(outbox);
        outbox.* = .{};
        const replication = try allocator.create([budgets.max_participants]ReplicationState);
        errdefer allocator.destroy(replication);
        replication.* = @splat(.{});
        var authority = Authority{
            .allocator = allocator,
            .simulation = try sandbox.Simulation.init(allocator, .{
                .namespace = 0x4d50_3201,
                .fixed_delta_seconds = 1.0 /
                    @as(f32, @floatFromInt(budgets.authority_tick_hz)),
                .create_ground = true,
                .character = .{ .max_characters = budgets.max_participants },
                .vehicle = .{
                    .max_vehicles = budgets.max_vehicles,
                    .max_entry_distance = 5,
                },
            }),
            .session = .{ .value = 0x4d50_3200_0000_0001 },
            .outbox = outbox,
            .replication = replication,
            .options = options,
        };
        errdefer authority.simulation.deinit();
        authority.vehicles[0] = .{
            .spawn_pending = true,
            .generation = 1,
            .replicated = .{
                .index = @intCast(budgets.max_participants + 1),
                .generation = 1,
            },
        };
        try authority.simulation.submitVehicle(.{ .spawn = .{
            .request_id = vehicleSpawnRequestId(0, 1),
            .chassis = .{ .pose = .{ .position = .{ -1.5, 2, -4 } } },
        } });
        authority.carryables[0] = .{
            .generation = 1,
            .replicated = .{
                .index = @intCast(budgets.max_participants + budgets.max_vehicles + 1),
                .generation = 1,
            },
        };
        for (&authority.npcs, 0..) |*npc, index| {
            npc.generation = 1;
            npc.replicated = .{
                .index = @intCast(
                    budgets.max_participants + budgets.max_vehicles +
                        budgets.max_carryables + index + 1,
                ),
                .generation = 1,
            };
        }
        try authority.simulation.submitDistrict(.{ .request_load = .{
            .request_id = districtBootstrapRequestId(0),
            .coord = sandbox.navigation_west_coord,
            .assets = .{},
        } });
        return authority;
    }

    pub fn deinit(self: *Authority) void {
        self.simulation.deinit();
        self.allocator.destroy(self.replication);
        self.allocator.destroy(self.outbox);
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
            slot.event_quota_tick = slot.opened_tick;
            slot.reliable_events_this_tick = 0;
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
        try self.ingestWithAdmissionTime(transport, message, null);
    }

    pub fn ingestAtUnixTime(
        self: *Authority,
        transport: TransportConnection,
        message: protocol.ClientMessage,
        now_unix_seconds: u64,
    ) !void {
        try self.ingestWithAdmissionTime(transport, message, now_unix_seconds);
    }

    fn ingestWithAdmissionTime(
        self: *Authority,
        transport: TransportConnection,
        message: protocol.ClientMessage,
        now_unix_seconds: ?u64,
    ) !void {
        if (now_unix_seconds) |now| try self.updateAdmissionTime(now);
        if (message == .hello and self.options.room_admission != null and
            !message.hello.reconnect.isValid() and now_unix_seconds == null)
        {
            return error.RoomAdmissionRequiresTimestampedIngress;
        }
        const connection_index = self.findConnection(transport) orelse
            return error.UnknownTransportConnection;
        const connection = &self.connections[connection_index];
        connection.received_messages +|= 1;
        connection.last_message_tick = self.simulation.tickIndex();

        switch (message) {
            .hello => |hello| try self.ingestHello(connection_index, hello),
            .input => |input| try self.ingestInput(connection_index, input),
            .vehicle_input => |input| try self.ingestVehicleInput(connection_index, input),
            .vehicle_action => |action| try self.ingestVehicleAction(connection_index, action),
            .interaction_action => |action| try self.ingestInteractionAction(
                connection_index,
                action,
            ),
            .baseline_ack => |ack| try self.ingestBaselineAck(connection_index, ack),
            .snapshot_ack => |ack| try self.ingestSnapshotAck(connection_index, ack),
            .disconnect => |reason| try self.ingestDisconnect(connection_index, reason),
        }
    }

    pub fn tick(self: *Authority) !void {
        self.replenishReplicationBudgets();
        try self.expireConnections(self.simulation.tickIndex());
        try self.expireReconnects();
        try self.applyHeldInputs(self.simulation.tickIndex());
        try self.simulation.tick();
        try self.processCharacterOutcomes();
        try self.processVehicleOutcomes();
        try self.processDistrictOutcomes();
        try self.processInteractionOutcomes();
        try self.processNpcOutcomes();
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

    /// Updated by the room/service ingress owner before ticket admission. It
    /// is intentionally separate from deterministic simulation time.
    pub fn updateAdmissionTime(self: *Authority, now_unix_seconds: u64) !void {
        if (now_unix_seconds < self.admission_time_unix_seconds) {
            return error.AdmissionClockMovedBackward;
        }
        self.admission_time_unix_seconds = now_unix_seconds;
    }

    pub fn diagnostics(self: *const Authority) Diagnostics {
        var active_connections: u16 = 0;
        var active_participants: u16 = 0;
        var active_vehicles: u16 = 0;
        var active_carryables: u16 = 0;
        var active_npcs: u16 = 0;
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
        for (self.vehicles) |vehicle| active_vehicles += @intFromBool(vehicle.active);
        for (self.carryables) |carryable| active_carryables += @intFromBool(carryable.active);
        for (self.npcs) |npc| active_npcs += @intFromBool(npc.active);
        return .{
            .tick = self.simulation.tickIndex(),
            .active_connections = active_connections,
            .active_participants = active_participants,
            .active_vehicles = active_vehicles,
            .active_carryables = active_carryables,
            .active_npcs = active_npcs,
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
            .invalid_control_inputs = self.invalid_control_inputs,
            .vehicle_actions_accepted = self.vehicle_actions_accepted,
            .vehicle_actions_rejected = self.vehicle_actions_rejected,
            .stale_vehicle_actions = self.stale_vehicle_actions,
            .forced_vehicle_cleanup = self.forced_vehicle_cleanup,
            .interaction_actions_accepted = self.interaction_actions_accepted,
            .interaction_actions_rejected = self.interaction_actions_rejected,
            .stale_interaction_actions = self.stale_interaction_actions,
            .forced_interaction_cleanup = self.forced_interaction_cleanup,
            .baselines_emitted = self.baselines_emitted,
            .baselines_acknowledged = self.baselines_acknowledged,
            .stale_baseline_acks = self.stale_baseline_acks,
            .relevance_transfers = self.relevance_transfers,
            .npc_state_updates = self.npc_state_updates,
            .delta_snapshots_emitted = self.delta_snapshots_emitted,
            .full_snapshots_emitted = self.full_snapshots_emitted,
            .snapshot_acks = self.snapshot_acks,
            .stale_snapshot_acks = self.stale_snapshot_acks,
            .snapshot_bytes_emitted = self.snapshot_bytes_emitted,
            .npc_updates_deprioritized = self.npc_updates_deprioritized,
            .snapshots_budget_deferred = self.snapshots_budget_deferred,
            .starvation_sends = self.starvation_sends,
            .full_snapshot_fallbacks = self.full_snapshot_fallbacks,
            .baseline_memory_bytes = @sizeOf(protocol.Snapshot) *
                budgets.snapshot_history_capacity * @as(usize, active_participants),
            .max_relevant_entities = self.max_relevant_entities,
            .max_reliable_events_per_connection_tick = self.max_reliable_events_per_connection_tick,
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
        protocol.validateClient(.{ .hello = hello }) catch {
            try self.rejectConnection(connection_index, .unauthorized, true);
            return;
        };
        const external_identity = normalizedExternalIdentity(hello);

        if (hello.reconnect.isValid()) {
            if (try self.tryReconnect(connection_index, hello)) return;
            try self.rejectConnection(connection_index, .reconnect_expired, true);
            return;
        }

        if (self.options.room_admission) |room| {
            const authorization = hello.join_authorization;
            if (authorization.room_id != room.room_id or
                authorization.authority_id != room.authority_id or
                authorization.room_generation != room.room_generation or
                authorization.expires_at_unix_seconds < self.admission_time_unix_seconds or
                !protocol.verifyJoinAuthorization(
                    room.secret,
                    hello.account,
                    external_identity,
                    authorization,
                ) or self.admissionNonceUsed(authorization.nonce))
            {
                try self.rejectConnection(connection_index, .unauthorized, true);
                return;
            }
        } else if (hello.join_authorization.isPresent()) {
            try self.rejectConnection(connection_index, .unauthorized, true);
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
        if (hello.join_authorization.isPresent()) {
            try self.rememberAdmissionNonce(hello.join_authorization);
        }
        participant.account = hello.account;
        participant.external_identity = external_identity;
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
        participant.relevance_coord = sandbox.navigation_west_coord;
        participant.baseline_id = 1;
        participant.baseline_acknowledged = 0;
        participant.baseline_sent = false;
        self.resetReplicationBaseline(participant_index);
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
        const external_identity = normalizedExternalIdentity(hello);
        for (&self.participants, 0..) |*participant, participant_index| {
            if (!participant.active or participant.connection_index != null or
                participant.despawn_pending or
                !std.meta.eql(participant.account, hello.account) or
                !std.meta.eql(participant.external_identity, external_identity) or
                !std.meta.eql(participant.reconnect, hello.reconnect) or
                tick_index > participant.reconnect_deadline_tick)
            {
                continue;
            }
            participant.connection_index = @intCast(connection_index);
            participant.baseline_id +%= 1;
            if (participant.baseline_id == 0) participant.baseline_id = 1;
            participant.baseline_acknowledged = 0;
            participant.baseline_sent = false;
            self.resetReplicationBaseline(participant_index);
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
        if (participant.driving_vehicle_index != null) {
            self.invalid_control_inputs +|= 1;
            return;
        }
        participant.held_input = .{ .character = input };
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
            .action_sequence = .{ .value = 0 },
            .target_tick = input.target_tick,
            .kind = .character,
            .move = input.move,
            .facing_yaw = input.facing_yaw,
            .jump_pressed = input.jump_pressed,
            .vehicle = .invalid,
            .vehicle_control = .{ 0, 0, 0, 0 },
        });
        self.accepted_messages +|= 1;
    }

    fn ingestVehicleInput(
        self: *Authority,
        connection_index: usize,
        input: protocol.VehicleInputFrame,
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
        const participant_index = connection.participant_index orelse {
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
        const vehicle_index = participant.driving_vehicle_index orelse {
            self.invalid_control_inputs +|= 1;
            return;
        };
        const vehicle = self.vehicles[vehicle_index];
        if (!vehicle.active or !std.meta.eql(vehicle.replicated, input.vehicle)) {
            self.invalid_control_inputs +|= 1;
            return;
        }
        participant.held_input = .{ .vehicle = input };
        participant.last_input_arrival_tick = tick_index;
        participant.last_input = input.sequence;
        self.ingress.append(.{
            .admitted_tick = tick_index,
            .account = participant.account,
            .participant = participantId(participant_index, participant.generation),
            .connection = .{
                .index = @intCast(connection_index + 1),
                .generation = connection.generation,
            },
            .sequence = input.sequence,
            .action_sequence = .{ .value = 0 },
            .target_tick = input.target_tick,
            .kind = .vehicle,
            .move = .{ 0, 0 },
            .facing_yaw = 0,
            .jump_pressed = false,
            .vehicle = input.vehicle,
            .vehicle_control = .{
                input.throttle,
                input.steering,
                input.brake,
                input.hand_brake,
            },
        });
        self.accepted_messages +|= 1;
    }

    fn ingestVehicleAction(
        self: *Authority,
        connection_index: usize,
        action: protocol.VehicleAction,
    ) !void {
        const participant_index = self.connections[connection_index].participant_index orelse {
            try self.rejectConnection(connection_index, .unauthorized, false);
            return;
        };
        const participant = &self.participants[participant_index];
        if (!std.meta.eql(action.session, self.session) or
            !std.meta.eql(action.participant, participantId(
                participant_index,
                participant.generation,
            )))
        {
            try self.rejectConnection(connection_index, .stale_connection, false);
            return;
        }
        if (!action.sequence.newerThan(participant.last_vehicle_action)) {
            self.stale_vehicle_actions +|= 1;
            return;
        }
        participant.last_vehicle_action = action.sequence;
        const vehicle_index = self.findVehicle(action.vehicle) orelse {
            try self.queueVehicleActionResult(
                participant_index,
                action,
                .vehicle_not_found,
            );
            self.vehicle_actions_rejected +|= 1;
            return;
        };
        if (participant.pending_vehicle_action != null or participant.despawn_pending) {
            try self.queueVehicleActionResult(participant_index, action, .invalid_state);
            self.vehicle_actions_rejected +|= 1;
            return;
        }
        const character = participant.character orelse {
            try self.queueVehicleActionResult(participant_index, action, .invalid_state);
            self.vehicle_actions_rejected +|= 1;
            return;
        };
        const vehicle = self.vehicles[vehicle_index];
        const persistent = vehicle.persistent orelse {
            try self.queueVehicleActionResult(participant_index, action, .unavailable);
            self.vehicle_actions_rejected +|= 1;
            return;
        };
        switch (action.kind) {
            .enter => {
                if (participant.driving_vehicle_index != null or
                    participant.holding_carryable_index != null)
                {
                    try self.queueVehicleActionResult(participant_index, action, .invalid_state);
                    self.vehicle_actions_rejected +|= 1;
                    return;
                }
                try self.simulation.submitVehicle(.{ .enter = .{
                    .vehicle_id = persistent,
                    .driver_id = character,
                } });
            },
            .exit => {
                if (participant.driving_vehicle_index == null or
                    participant.driving_vehicle_index.? != vehicle_index)
                {
                    try self.queueVehicleActionResult(participant_index, action, .invalid_state);
                    self.vehicle_actions_rejected +|= 1;
                    return;
                }
                try self.simulation.submitVehicle(.{ .exit = .{
                    .vehicle_id = persistent,
                    .driver_id = character,
                } });
                participant.exit_pending = true;
            },
        }
        self.ingress.append(.{
            .admitted_tick = self.simulation.tickIndex(),
            .account = participant.account,
            .participant = participantId(participant_index, participant.generation),
            .connection = .{
                .index = @intCast(connection_index + 1),
                .generation = self.connections[connection_index].generation,
            },
            .sequence = .{ .value = 0 },
            .action_sequence = action.sequence,
            .target_tick = self.simulation.tickIndex() + 1,
            .kind = if (action.kind == .enter) .vehicle_enter else .vehicle_exit,
            .move = .{ 0, 0 },
            .facing_yaw = 0,
            .jump_pressed = false,
            .vehicle = action.vehicle,
            .vehicle_control = .{ 0, 0, 0, 0 },
        });
        participant.pending_vehicle_action = action;
        participant.held_input = null;
        self.accepted_messages +|= 1;
    }

    fn ingestInteractionAction(
        self: *Authority,
        connection_index: usize,
        action: protocol.InteractionAction,
    ) !void {
        const participant_index = self.connections[connection_index].participant_index orelse {
            try self.rejectConnection(connection_index, .unauthorized, false);
            return;
        };
        const participant = &self.participants[participant_index];
        if (!std.meta.eql(action.session, self.session) or
            !std.meta.eql(action.participant, participantId(
                participant_index,
                participant.generation,
            )))
        {
            try self.rejectConnection(connection_index, .stale_connection, false);
            return;
        }
        if (!action.sequence.newerThan(participant.last_interaction_action)) {
            self.stale_interaction_actions +|= 1;
            return;
        }
        participant.last_interaction_action = action.sequence;
        const carryable_index = self.findCarryable(action.carryable) orelse {
            try self.queueInteractionActionResult(
                participant_index,
                action,
                .carryable_not_found,
            );
            self.interaction_actions_rejected +|= 1;
            return;
        };
        if (participant.pending_interaction_action != null or
            participant.pending_vehicle_action != null or
            participant.despawn_pending)
        {
            try self.queueInteractionActionResult(participant_index, action, .invalid_state);
            self.interaction_actions_rejected +|= 1;
            return;
        }
        const character = participant.character orelse {
            try self.queueInteractionActionResult(participant_index, action, .invalid_state);
            self.interaction_actions_rejected +|= 1;
            return;
        };
        const carryable = self.carryables[carryable_index];
        const persistent = carryable.persistent orelse {
            try self.queueInteractionActionResult(participant_index, action, .unavailable);
            self.interaction_actions_rejected +|= 1;
            return;
        };
        switch (action.kind) {
            .collect => try self.simulation.submitInteraction(.{ .collect = .{
                .transaction_id = interactionTransactionId(
                    participant_index,
                    participant.generation,
                    action.sequence,
                ),
                .carrier_id = character,
                .carryable_id = persistent,
            } }),
            .drop => try self.simulation.submitInteraction(.{ .drop = .{
                .transaction_id = interactionTransactionId(
                    participant_index,
                    participant.generation,
                    action.sequence,
                ),
                .carrier_id = character,
                .carryable_id = persistent,
            } }),
        }
        self.ingress.append(.{
            .admitted_tick = self.simulation.tickIndex(),
            .account = participant.account,
            .participant = participantId(participant_index, participant.generation),
            .connection = .{
                .index = @intCast(connection_index + 1),
                .generation = self.connections[connection_index].generation,
            },
            .sequence = .{ .value = 0 },
            .action_sequence = action.sequence,
            .target_tick = self.simulation.tickIndex() + 1,
            .kind = if (action.kind == .collect)
                .interaction_collect
            else
                .interaction_drop,
            .move = .{ 0, 0 },
            .facing_yaw = 0,
            .jump_pressed = false,
            .vehicle = .invalid,
            .carryable = action.carryable,
            .vehicle_control = .{ 0, 0, 0, 0 },
        });
        participant.pending_interaction_action = action;
        participant.held_input = null;
        self.accepted_messages +|= 1;
    }

    fn ingestBaselineAck(
        self: *Authority,
        connection_index: usize,
        ack: protocol.BaselineAck,
    ) !void {
        const participant_index = self.connections[connection_index].participant_index orelse {
            try self.rejectConnection(connection_index, .unauthorized, false);
            return;
        };
        const participant = &self.participants[participant_index];
        if (!std.meta.eql(ack.session, self.session) or
            !std.meta.eql(ack.participant, participantId(
                participant_index,
                participant.generation,
            )))
        {
            try self.rejectConnection(connection_index, .stale_connection, false);
            return;
        }
        if (!participant.baseline_sent or ack.baseline_id != participant.baseline_id) {
            self.stale_baseline_acks +|= 1;
            return;
        }
        if (participant.baseline_acknowledged != ack.baseline_id) {
            participant.baseline_acknowledged = ack.baseline_id;
            const replication = &self.replication[participant_index];
            if (replication.baseline_sequence.value != 0) {
                replication.acknowledged_sequence = replication.baseline_sequence;
                replication.last_ack_tick = self.simulation.tickIndex();
            }
            self.baselines_acknowledged +|= 1;
            self.force_snapshot = true;
        }
        self.accepted_messages +|= 1;
    }

    fn ingestSnapshotAck(
        self: *Authority,
        connection_index: usize,
        ack: protocol.SnapshotAck,
    ) !void {
        const participant_index = self.connections[connection_index].participant_index orelse {
            try self.rejectConnection(connection_index, .unauthorized, false);
            return;
        };
        const participant = &self.participants[participant_index];
        if (!std.meta.eql(ack.session, self.session) or
            !std.meta.eql(ack.participant, participantId(
                participant_index,
                participant.generation,
            )))
        {
            try self.rejectConnection(connection_index, .stale_connection, false);
            return;
        }
        if (ack.baseline_id != participant.baseline_id or
            self.findReplicationSnapshot(participant_index, ack.sequence) == null)
        {
            self.stale_snapshot_acks +|= 1;
            return;
        }
        const replication = &self.replication[participant_index];
        if (replication.acknowledged_sequence.value == 0 or
            ack.sequence.newerThan(replication.acknowledged_sequence))
        {
            replication.acknowledged_sequence = ack.sequence;
            replication.last_ack_tick = self.simulation.tickIndex();
            self.snapshot_acks +|= 1;
        } else {
            self.stale_snapshot_acks +|= 1;
        }
        self.accepted_messages +|= 1;
    }

    fn replenishReplicationBudgets(self: *Authority) void {
        const per_second = self.options.downstream_bytes_per_second;
        const whole = per_second / budgets.authority_tick_hz;
        const remainder = per_second % budgets.authority_tick_hz;
        const burst = per_second;
        for (self.replication) |*replication| {
            replication.byte_remainder += remainder;
            const carry = replication.byte_remainder / budgets.authority_tick_hz;
            replication.byte_remainder %= budgets.authority_tick_hz;
            replication.byte_credit = @min(
                burst,
                replication.byte_credit +| whole +| carry,
            );
        }
    }

    fn applyHeldInputs(self: *Authority, tick_index: u64) !void {
        for (&self.participants) |*participant| {
            if (!participant.active or participant.connection_index == null or
                participant.character == null or participant.despawn_pending)
            {
                continue;
            }
            const fresh = tick_index -| participant.last_input_arrival_tick <=
                budgets.input_hold_ticks;
            if (!fresh) participant.held_input = null;
            if (participant.driving_vehicle_index) |vehicle_index| {
                if (participant.exit_pending) continue;
                const vehicle = self.vehicles[vehicle_index];
                const persistent = vehicle.persistent orelse continue;
                var control = engine.physics.VehicleInput{};
                if (fresh) if (participant.held_input) |held| switch (held) {
                    .vehicle => |input| control = .{
                        .throttle = input.throttle,
                        .steering = input.steering,
                        .brake = input.brake,
                        .hand_brake = input.hand_brake,
                    },
                    .character => {},
                };
                try self.simulation.submitVehicle(.{ .drive = .{
                    .vehicle_id = persistent,
                    .driver_id = participant.character.?,
                    .input = control,
                } });
                continue;
            }
            if (!fresh) continue;
            const held = participant.held_input orelse continue;
            switch (held) {
                .character => |input| try self.simulation.submitCharacter(.{ .actions = .{
                    .id = participant.character.?,
                    .move = input.move,
                    .facing_yaw = input.facing_yaw,
                    .jump_pressed = input.jump_pressed and
                        tick_index == participant.last_input_arrival_tick,
                } }),
                .vehicle => {},
            }
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
        participant.despawn_pending = true;
        participant.held_input = null;
        try self.continueParticipantDespawn(participant_index);
    }

    fn continueParticipantDespawn(self: *Authority, participant_index: usize) !void {
        const participant = &self.participants[participant_index];
        if (!participant.active or !participant.despawn_pending) return;
        // A queued feature transaction cannot be cancelled after admission.
        // Let its typed outcome settle first, then continue ordered cleanup.
        if (participant.pending_vehicle_action != null or
            participant.pending_interaction_action != null or
            participant.interaction_cleanup_pending or participant.exit_pending) return;
        if (participant.character) |character| {
            if (participant.holding_carryable_index) |carryable_index| {
                const carryable = self.carryables[carryable_index];
                const persistent = carryable.persistent orelse
                    return error.InteractionAuthorityInvariantBroken;
                try self.simulation.submitInteraction(.{ .drop = .{
                    .transaction_id = interactionCleanupTransactionId(
                        participant_index,
                        participant.generation,
                    ),
                    .carrier_id = character,
                    .carryable_id = persistent,
                } });
                participant.interaction_cleanup_pending = true;
                return;
            }
            if (participant.driving_vehicle_index) |vehicle_index| {
                const vehicle = self.vehicles[vehicle_index];
                const persistent = vehicle.persistent orelse
                    return error.VehicleAuthorityInvariantBroken;
                try self.simulation.submitVehicle(.{ .exit = .{
                    .vehicle_id = persistent,
                    .driver_id = character,
                } });
                participant.exit_pending = true;
                return;
            }
            try self.simulation.submitCharacter(.{ .despawn = .{ .id = character } });
        } else if (!participant.spawn_pending) {
            participant.active = false;
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
                        participant.driving_vehicle_index = null;
                        participant.holding_carryable_index = null;
                        participant.pending_vehicle_action = null;
                        participant.pending_interaction_action = null;
                        participant.exit_pending = false;
                        participant.interaction_cleanup_pending = false;
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

    fn processVehicleOutcomes(self: *Authority) !void {
        while (self.simulation.pollVehicleOutcome()) |outcome| switch (outcome) {
            .spawned => |spawned| {
                const decoded = decodeVehicleSpawnRequestId(spawned.request_id) orelse
                    return error.UnexpectedVehicleSpawnOutcome;
                const vehicle = &self.vehicles[decoded.index];
                if (vehicle.generation != decoded.generation or !vehicle.spawn_pending) {
                    return error.StaleVehicleSpawnOutcome;
                }
                vehicle.spawn_pending = false;
                vehicle.active = true;
                vehicle.persistent = spawned.id;
                self.force_snapshot = true;
            },
            .entered => |entered| {
                const participant_index = self.findParticipantByCharacter(entered.driver_id) orelse
                    return error.UnknownVehicleDriver;
                const vehicle_index = self.findVehicleByPersistent(entered.vehicle_id) orelse
                    return error.UnknownVehicleOutcome;
                const participant = &self.participants[participant_index];
                participant.driving_vehicle_index = @intCast(vehicle_index);
                participant.held_input = null;
                if (participant.pending_vehicle_action) |action| {
                    if (action.kind != .enter) return error.VehicleActionOutcomeMismatch;
                    try self.queueVehicleActionResult(participant_index, action, .entered);
                    participant.pending_vehicle_action = null;
                    self.vehicle_actions_accepted +|= 1;
                }
                if (participant.despawn_pending) {
                    try self.simulation.submitVehicle(.{ .exit = .{
                        .vehicle_id = entered.vehicle_id,
                        .driver_id = entered.driver_id,
                    } });
                    participant.exit_pending = true;
                }
                self.force_snapshot = true;
            },
            .drive_applied => {},
            .exited => |exited| {
                const participant_index = self.findParticipantByCharacter(exited.driver_id) orelse
                    return error.UnknownVehicleDriver;
                const participant = &self.participants[participant_index];
                participant.driving_vehicle_index = null;
                participant.exit_pending = false;
                participant.held_input = null;
                if (participant.pending_vehicle_action) |action| {
                    if (action.kind != .exit) return error.VehicleActionOutcomeMismatch;
                    try self.queueVehicleActionResult(participant_index, action, .exited);
                    participant.pending_vehicle_action = null;
                    self.vehicle_actions_accepted +|= 1;
                }
                if (participant.despawn_pending) {
                    try self.simulation.submitCharacter(.{ .despawn = .{
                        .id = exited.driver_id,
                    } });
                }
                self.force_snapshot = true;
            },
            .abandoned => |abandoned| {
                const participant_index = self.findParticipantByCharacter(abandoned.driver_id) orelse
                    return error.UnknownVehicleDriver;
                const participant = &self.participants[participant_index];
                if (!participant.despawn_pending or !participant.exit_pending or
                    participant.pending_vehicle_action != null)
                {
                    return error.UnexpectedVehicleAbandonOutcome;
                }
                participant.driving_vehicle_index = null;
                participant.exit_pending = false;
                participant.held_input = null;
                try self.simulation.submitCharacter(.{ .despawn = .{
                    .id = abandoned.driver_id,
                } });
                self.forced_vehicle_cleanup +|= 1;
                self.force_snapshot = true;
            },
            .despawned => return error.UnexpectedVehicleDespawnOutcome,
            .rejected => |rejected| {
                const driver = rejected.driver_id orelse
                    return error.UnexpectedVehicleRejection;
                const participant_index = self.findParticipantByCharacter(driver) orelse
                    return error.UnknownVehicleDriver;
                const participant = &self.participants[participant_index];
                if (participant.despawn_pending and participant.exit_pending) {
                    if (rejected.command != .exit or rejected.reason != .exit_blocked or
                        rejected.vehicle_id == null)
                    {
                        return error.VehicleCleanupExitRejected;
                    }
                    try self.simulation.submitVehicle(.{ .abandon = .{
                        .vehicle_id = rejected.vehicle_id.?,
                        .driver_id = driver,
                    } });
                    continue;
                }
                const action = participant.pending_vehicle_action orelse
                    return error.UnexpectedVehicleRejection;
                try self.queueVehicleActionResult(
                    participant_index,
                    action,
                    vehicleRejectionDisposition(rejected.reason),
                );
                participant.pending_vehicle_action = null;
                participant.exit_pending = false;
                participant.held_input = null;
                self.vehicle_actions_rejected +|= 1;
                if (participant.despawn_pending and
                    participant.driving_vehicle_index == null)
                {
                    try self.simulation.submitCharacter(.{ .despawn = .{ .id = driver } });
                }
            },
        };
        while (self.simulation.pollVehicleEvent() != null) {}
    }

    fn processDistrictOutcomes(self: *Authority) !void {
        while (self.simulation.pollDistrictOutcome()) |outcome| switch (outcome) {
            .load_requested => |requested| {
                if (decodeDistrictBootstrapRequestId(requested.request_id) == null) {
                    return error.UnexpectedDistrictLoadOutcome;
                }
            },
            .activated => |activated| {
                const district_index = decodeDistrictBootstrapRequestId(
                    activated.request_id,
                ) orelse return error.UnexpectedDistrictActivation;
                const expected = districtBootstrapCoord(district_index);
                if (!std.meta.eql(activated.coord, expected)) {
                    return error.UnexpectedDistrictActivation;
                }
                if (self.active_districts[district_index]) {
                    return error.DuplicateDistrictActivation;
                }
                self.active_districts[district_index] = true;
                if (district_index == 1) {
                    for (&self.npcs, 0..) |*npc, index| {
                        npc.spawn_pending = true;
                        const coord = if (index % 2 == 0)
                            sandbox.navigation_west_coord
                        else
                            sandbox.navigation_east_coord;
                        try self.simulation.submitNpc(.{ .spawn = .{
                            .request_id = npcSpawnRequestId(index, npc.generation),
                            .node = .{ .coord = coord, .index = @intCast(index % 3) },
                            .goal = .hold,
                        } });
                    }
                    continue;
                }
                try self.simulation.submitDistrict(.{ .request_load = .{
                    .request_id = districtBootstrapRequestId(1),
                    .coord = sandbox.navigation_east_coord,
                    .assets = .{},
                } });
                const carryable = &self.carryables[0];
                if (carryable.active or carryable.spawn_pending) {
                    return error.DuplicateCarryableDistrictActivation;
                }
                carryable.spawn_pending = true;
                try self.simulation.submitInteraction(.{ .spawn = .{
                    .request_id = carryableSpawnRequestId(0, carryable.generation),
                    .pose = .{ .position = .{ -2, 1, -1.5 } },
                } });
            },
            .cancellation_requested,
            .cancelled,
            .load_failed,
            .unloaded,
            .rejected,
            => return error.CarryableDistrictBootstrapFailed,
        };
        while (self.simulation.pollDistrictEvent() != null) {}
    }

    fn processInteractionOutcomes(self: *Authority) !void {
        while (self.simulation.pollInteractionOutcome()) |outcome| switch (outcome) {
            .spawned => |spawned| {
                const decoded = decodeCarryableSpawnRequestId(spawned.request_id) orelse
                    return error.UnexpectedCarryableSpawnOutcome;
                const carryable = &self.carryables[decoded.index];
                if (carryable.generation != decoded.generation or !carryable.spawn_pending) {
                    return error.StaleCarryableSpawnOutcome;
                }
                carryable.spawn_pending = false;
                carryable.active = true;
                carryable.persistent = spawned.id;
                self.force_snapshot = true;
            },
            .collected => |collected| {
                const participant_index = self.findParticipantByCharacter(
                    collected.carrier_id,
                ) orelse return error.UnknownInteractionCarrier;
                const carryable_index = self.findCarryableByPersistent(
                    collected.carryable_id,
                ) orelse return error.UnknownInteractionCarryable;
                const participant = &self.participants[participant_index];
                const action = participant.pending_interaction_action orelse
                    return error.UnexpectedInteractionCollectOutcome;
                if (action.kind != .collect or
                    collected.transaction_id != interactionTransactionId(
                        participant_index,
                        participant.generation,
                        action.sequence,
                    ) or
                    !std.meta.eql(action.carryable, self.carryables[carryable_index].replicated) or
                    participant.holding_carryable_index != null)
                {
                    return error.InteractionActionOutcomeMismatch;
                }
                participant.holding_carryable_index = @intCast(carryable_index);
                participant.pending_interaction_action = null;
                participant.held_input = null;
                try self.queueInteractionActionResult(participant_index, action, .collected);
                self.interaction_actions_accepted +|= 1;
                self.force_snapshot = true;
                try self.continueParticipantDespawn(participant_index);
            },
            .dropped => |dropped| {
                const participant_index = self.findParticipantByCharacter(
                    dropped.carrier_id,
                ) orelse return error.UnknownInteractionCarrier;
                const carryable_index = self.findCarryableByPersistent(
                    dropped.carryable_id,
                ) orelse return error.UnknownInteractionCarryable;
                const participant = &self.participants[participant_index];
                if (participant.interaction_cleanup_pending) {
                    if (dropped.transaction_id != interactionCleanupTransactionId(
                        participant_index,
                        participant.generation,
                    ) or participant.holding_carryable_index == null or
                        participant.holding_carryable_index.? != carryable_index)
                    {
                        return error.InteractionCleanupOutcomeMismatch;
                    }
                    participant.interaction_cleanup_pending = false;
                    participant.holding_carryable_index = null;
                    participant.held_input = null;
                    self.forced_interaction_cleanup +|= 1;
                    self.force_snapshot = true;
                    try self.continueParticipantDespawn(participant_index);
                    continue;
                }
                const action = participant.pending_interaction_action orelse
                    return error.UnexpectedInteractionDropOutcome;
                if (action.kind != .drop or
                    dropped.transaction_id != interactionTransactionId(
                        participant_index,
                        participant.generation,
                        action.sequence,
                    ) or
                    !std.meta.eql(action.carryable, self.carryables[carryable_index].replicated) or
                    participant.holding_carryable_index == null or
                    participant.holding_carryable_index.? != carryable_index)
                {
                    return error.InteractionActionOutcomeMismatch;
                }
                participant.holding_carryable_index = null;
                participant.pending_interaction_action = null;
                participant.held_input = null;
                try self.queueInteractionActionResult(participant_index, action, .dropped);
                self.interaction_actions_accepted +|= 1;
                self.force_snapshot = true;
                try self.continueParticipantDespawn(participant_index);
            },
            .despawned => return error.UnexpectedCarryableDespawnOutcome,
            .rejected => |rejected| {
                const carrier = rejected.carrier_id orelse
                    return error.UnexpectedInteractionRejection;
                const participant_index = self.findParticipantByCharacter(carrier) orelse
                    return error.UnknownInteractionCarrier;
                const participant = &self.participants[participant_index];
                if (participant.interaction_cleanup_pending) {
                    if (rejected.transaction_id == null or
                        rejected.transaction_id.? != interactionCleanupTransactionId(
                            participant_index,
                            participant.generation,
                        ))
                    {
                        return error.InteractionCleanupOutcomeMismatch;
                    }
                    return error.InteractionCleanupDropRejected;
                }
                const action = participant.pending_interaction_action orelse
                    return error.UnexpectedInteractionRejection;
                if (rejected.transaction_id == null or
                    rejected.transaction_id.? != interactionTransactionId(
                        participant_index,
                        participant.generation,
                        action.sequence,
                    ))
                {
                    return error.InteractionActionOutcomeMismatch;
                }
                try self.queueInteractionActionResult(
                    participant_index,
                    action,
                    interactionRejectionDisposition(rejected.reason),
                );
                participant.pending_interaction_action = null;
                participant.held_input = null;
                self.interaction_actions_rejected +|= 1;
                try self.continueParticipantDespawn(participant_index);
            },
        };
    }

    fn processNpcOutcomes(self: *Authority) !void {
        while (self.simulation.pollNpcOutcome()) |outcome| switch (outcome) {
            .spawned => |spawned| {
                const decoded = decodeNpcSpawnRequestId(spawned.request_id) orelse
                    return error.UnexpectedNpcSpawnOutcome;
                const npc = &self.npcs[decoded.index];
                if (npc.generation != decoded.generation or !npc.spawn_pending) {
                    return error.StaleNpcSpawnOutcome;
                }
                npc.spawn_pending = false;
                npc.active = true;
                npc.persistent = spawned.id;
                self.force_snapshot = true;
            },
            .goal_set, .despawned => return error.UnexpectedNpcMutationOutcome,
            .rejected => return error.NpcBootstrapRejected,
        };
        while (self.simulation.pollNpcEvent() != null) {}
    }

    fn publishSnapshots(self: *Authority) !void {
        for (0..self.participants.len) |participant_index| {
            const participant = &self.participants[participant_index];
            const connection_index = participant.connection_index orelse continue;
            if (!participant.active or participant.character == null or
                participant.despawn_pending or !self.connections[connection_index].active)
            {
                continue;
            }
            try self.updateParticipantRelevance(participant_index);
            const full_projection = try self.buildRelevantSnapshot(participant_index);
            const relevant_entities: u16 = full_projection.character_count +
                full_projection.vehicle_count + full_projection.carryable_count +
                full_projection.npc_count;
            self.max_relevant_entities = @max(self.max_relevant_entities, relevant_entities);
            if (relevant_entities > budgets.max_relevant_entities_per_client) {
                return error.RelevantEntityBudgetExceeded;
            }
            if (!participant.baseline_sent) {
                var baseline = protocol.RelevanceBaseline{
                    .baseline_id = participant.baseline_id,
                    .district_count = 1,
                    .districts = undefined,
                    .snapshot = full_projection,
                };
                baseline.districts[0] = districtCoord(participant.relevance_coord);
                try self.queue(.{
                    .connection = self.connections[connection_index].transport,
                    .message = .{ .relevance_baseline = baseline },
                    .delivery = .reliable,
                    .lane = .control,
                });
                participant.baseline_sent = true;
                const replication = &self.replication[participant_index];
                replication.baseline_sequence = full_projection.sequence;
                replication.last_full_tick = self.simulation.tickIndex();
                replication.last_sent_tick = self.simulation.tickIndex();
                self.rememberReplicationSnapshot(participant_index, full_projection);
                const byte_count = try snapshotWireBytes(.{ .relevance_baseline = baseline });
                self.snapshot_bytes_emitted +|= byte_count;
                self.full_snapshots_emitted +|= 1;
                self.npc_state_updates +|= full_projection.npc_count;
                self.baselines_emitted +|= 1;
                continue;
            }
            if (participant.baseline_acknowledged != participant.baseline_id) continue;

            const tick_index = self.simulation.tickIndex();
            const replication = &self.replication[participant_index];
            const acknowledged = self.findReplicationSnapshot(
                participant_index,
                replication.acknowledged_sequence,
            );
            const must_send_full = acknowledged == null or
                tick_index -| replication.last_full_tick >=
                    self.options.full_snapshot_interval_ticks or
                tick_index -| replication.last_ack_tick > budgets.max_delta_base_age_ticks;
            var wire_snapshot = if (must_send_full)
                full_projection
            else
                try protocol.makeDelta(
                    acknowledged.?,
                    full_projection,
                    tick_index % budgets.ticks_per_npc_snapshot == 0,
                );
            var materialized = if (wire_snapshot.kind == .delta)
                try protocol.materializeDelta(acknowledged.?, wire_snapshot)
            else
                full_projection;
            var byte_count = try snapshotWireBytes(.{ .snapshot = wire_snapshot });
            if (byte_count > replication.byte_credit and wire_snapshot.kind == .delta and
                wire_snapshot.npc_update)
            {
                wire_snapshot = try protocol.makeDelta(acknowledged.?, full_projection, false);
                materialized = try protocol.materializeDelta(acknowledged.?, wire_snapshot);
                byte_count = try snapshotWireBytes(.{ .snapshot = wire_snapshot });
                self.npc_updates_deprioritized +|= 1;
            }
            if (byte_count > replication.byte_credit and
                tick_index -| replication.last_sent_tick < budgets.max_snapshot_starvation_ticks)
            {
                self.snapshots_budget_deferred +|= 1;
                continue;
            }
            if (byte_count > replication.byte_credit) self.starvation_sends +|= 1;
            try self.queue(.{
                .connection = self.connections[connection_index].transport,
                .message = .{ .snapshot = wire_snapshot },
                .delivery = .unreliable,
                .lane = .snapshot,
            });
            replication.byte_credit -|= byte_count;
            replication.last_sent_tick = tick_index;
            if (wire_snapshot.kind == .full) {
                replication.last_full_tick = tick_index;
                self.full_snapshots_emitted +|= 1;
                self.full_snapshot_fallbacks +|= 1;
            } else {
                self.delta_snapshots_emitted +|= 1;
            }
            self.rememberReplicationSnapshot(participant_index, materialized);
            self.snapshot_bytes_emitted +|= byte_count;
            if (wire_snapshot.npc_update) self.npc_state_updates +|= wire_snapshot.npc_count;
            self.snapshots_emitted +|= 1;
        }
    }

    fn updateParticipantRelevance(self: *Authority, participant_index: usize) !void {
        const participant = &self.participants[participant_index];
        const character = participant.character orelse return;
        const position = if (participant.driving_vehicle_index) |vehicle_index| blk: {
            const persistent = self.vehicles[vehicle_index].persistent orelse
                return error.VehicleAuthorityInvariantBroken;
            break :blk (try self.simulation.vehicle(persistent)).state.chassis.pose.position;
        } else (try self.simulation.character(character)).position;
        const candidate = try sandbox.chunkCoordForWorldPosition(position);
        if (std.meta.eql(candidate, participant.relevance_coord) or
            !self.isDistrictActive(candidate) or
            !insideDistrictHysteresis(position, candidate)) return;
        participant.relevance_coord = candidate;
        participant.baseline_id +%= 1;
        if (participant.baseline_id == 0) participant.baseline_id = 1;
        participant.baseline_acknowledged = 0;
        participant.baseline_sent = false;
        self.resetReplicationBaseline(participant_index);
        self.relevance_transfers +|= 1;
    }

    fn buildRelevantSnapshot(
        self: *Authority,
        participant_index: usize,
    ) !protocol.Snapshot {
        const target = self.participants[participant_index];
        const replication = &self.replication[participant_index];
        var snapshot = protocol.Snapshot.empty();
        snapshot.baseline_id = target.baseline_id;
        snapshot.sequence = replication.next_sequence;
        replication.next_sequence = replication.next_sequence.next();
        if (replication.next_sequence.value == 0) replication.next_sequence.value = 1;
        snapshot.server_tick = self.simulation.tickIndex();
        snapshot.acknowledged_input = target.last_input;
        for (self.participants, 0..) |participant, index| {
            if (!participant.active or participant.character == null or
                participant.despawn_pending) continue;
            const view = try self.simulation.character(participant.character.?);
            const relevant = index == participant_index or std.meta.eql(
                try sandbox.chunkCoordForWorldPosition(view.position),
                target.relevance_coord,
            );
            if (!relevant) continue;
            snapshot.characters[snapshot.character_count] = .{
                .entity = participant.replicated,
                .owner = participantId(index, participant.generation),
                .position = view.position,
                .velocity = view.velocity,
                .facing_yaw = view.facing_yaw,
            };
            snapshot.character_count += 1;
        }
        for (self.vehicles) |vehicle| {
            if (!vehicle.active or vehicle.persistent == null) continue;
            const view = try self.simulation.vehicle(vehicle.persistent.?);
            const driver_index = if (view.driver_id) |driver|
                self.findParticipantByCharacter(driver)
            else
                null;
            const relevant = (driver_index != null and driver_index.? == participant_index) or
                std.meta.eql(
                    try sandbox.chunkCoordForWorldPosition(view.state.chassis.pose.position),
                    target.relevance_coord,
                );
            if (!relevant) continue;
            snapshot.vehicles[snapshot.vehicle_count] = .{
                .entity = vehicle.replicated,
                .position = view.state.chassis.pose.position,
                .rotation = view.state.chassis.pose.rotation,
                .linear_velocity = view.state.chassis.velocity.linear,
                .angular_velocity = view.state.chassis.velocity.angular,
                .driver = if (driver_index) |index|
                    participantId(index, self.participants[index].generation)
                else
                    null,
            };
            snapshot.vehicle_count += 1;
        }
        const carryable_draws = try self.simulation.interactionPresentation();
        for (carryable_draws) |draw| {
            const carryable_index = self.findCarryableByPersistent(draw.persistent_id) orelse
                return error.UnknownInteractionPresentation;
            const view = try self.simulation.carryable(draw.persistent_id);
            const holder_index = switch (draw.ownership) {
                .district_owned => null,
                .inventory_held => |carrier| self.findParticipantByCharacter(carrier) orelse
                    return error.UnknownInteractionCarrier,
            };
            const relevant = (holder_index != null and holder_index.? == participant_index) or
                std.meta.eql(
                    try sandbox.chunkCoordForWorldPosition(draw.pose.position),
                    target.relevance_coord,
                );
            if (!relevant) continue;
            const holder = if (holder_index) |index|
                participantId(index, self.participants[index].generation)
            else
                null;
            snapshot.carryables[snapshot.carryable_count] = .{
                .entity = self.carryables[carryable_index].replicated,
                .position = draw.pose.position,
                .rotation = draw.pose.rotation,
                .linear_velocity = if (holder == null) view.state.velocity.linear else .{ 0, 0, 0 },
                .angular_velocity = if (holder == null) view.state.velocity.angular else .{ 0, 0, 0 },
                .half_extents = draw.half_extents,
                .holder = holder,
            };
            snapshot.carryable_count += 1;
        }
        snapshot.npc_update = true;
        const draws = try self.simulation.npcPresentation(0);
        for (draws) |draw| {
            if (!std.meta.eql(draw.owner, target.relevance_coord)) continue;
            const npc_index = self.findNpcByPersistent(draw.persistent_id) orelse
                return error.UnknownNpcPresentation;
            const view = try self.simulation.npc(draw.persistent_id);
            snapshot.npcs[snapshot.npc_count] = .{
                .entity = self.npcs[npc_index].replicated,
                .position = view.position,
                .velocity = view.velocity,
                .facing_yaw = view.facing_yaw,
                .state = switch (view.state) {
                    .active => .active,
                    .waiting_at_boundary => .waiting_at_boundary,
                    .dormant => continue,
                },
            };
            snapshot.npc_count += 1;
        }
        return snapshot;
    }

    fn rememberReplicationSnapshot(
        self: *Authority,
        participant_index: usize,
        snapshot: protocol.Snapshot,
    ) void {
        std.debug.assert(snapshot.kind == .full);
        const replication = &self.replication[participant_index];
        replication.history[replication.history_next] = .{
            .valid = true,
            .snapshot = snapshot,
        };
        replication.history_next = @intCast(
            (@as(usize, replication.history_next) + 1) % replication.history.len,
        );
    }

    fn findReplicationSnapshot(
        self: *const Authority,
        participant_index: usize,
        sequence: identity.SnapshotSequence,
    ) ?protocol.Snapshot {
        if (sequence.value == 0) return null;
        const baseline_id = self.participants[participant_index].baseline_id;
        for (self.replication[participant_index].history) |record| {
            if (record.valid and std.meta.eql(record.snapshot.sequence, sequence) and
                record.snapshot.baseline_id == baseline_id)
            {
                return record.snapshot;
            }
        }
        return null;
    }

    fn resetReplicationBaseline(self: *Authority, participant_index: usize) void {
        const replication = &self.replication[participant_index];
        replication.history = @splat(.{});
        replication.history_next = 0;
        replication.acknowledged_sequence = .{ .value = 0 };
        replication.baseline_sequence = .{ .value = 0 };
        replication.last_ack_tick = self.simulation.tickIndex();
        replication.last_full_tick = 0;
        replication.last_sent_tick = 0;
    }

    fn isDistrictActive(self: *const Authority, coord: sandbox.ChunkCoord) bool {
        if (std.meta.eql(coord, sandbox.navigation_west_coord)) return self.active_districts[0];
        if (std.meta.eql(coord, sandbox.navigation_east_coord)) return self.active_districts[1];
        return false;
    }

    fn allocateParticipant(self: *Authority) ?usize {
        for (&self.participants, 0..) |*participant, index| {
            if (participant.active) continue;
            participant.generation +%= 1;
            if (participant.generation == 0) participant.generation = 1;
            participant.active = true;
            participant.account = .{ .value = 0 };
            participant.external_identity = .{};
            participant.connection_index = null;
            participant.reconnect_deadline_tick = 0;
            participant.character = null;
            participant.replicated = .invalid;
            participant.last_input = .{ .value = 0 };
            participant.held_input = null;
            participant.last_input_arrival_tick = 0;
            participant.driving_vehicle_index = null;
            participant.last_vehicle_action = .{ .value = 0 };
            participant.pending_vehicle_action = null;
            participant.holding_carryable_index = null;
            participant.last_interaction_action = .{ .value = 0 };
            participant.pending_interaction_action = null;
            participant.interaction_cleanup_pending = false;
            participant.relevance_coord = sandbox.navigation_west_coord;
            participant.baseline_id = 0;
            participant.baseline_acknowledged = 0;
            participant.baseline_sent = false;
            self.replication[index] = .{
                .byte_credit = self.options.downstream_bytes_per_second,
            };
            participant.exit_pending = false;
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

    fn queueVehicleActionResult(
        self: *Authority,
        participant_index: usize,
        action: protocol.VehicleAction,
        disposition: protocol.VehicleActionDisposition,
    ) !void {
        const connection_index = self.participants[participant_index].connection_index orelse
            return;
        if (!self.connections[connection_index].active) return;
        try self.queue(.{
            .connection = self.connections[connection_index].transport,
            .message = .{ .vehicle_action_result = .{
                .sequence = action.sequence,
                .vehicle = action.vehicle,
                .action = action.kind,
                .disposition = disposition,
            } },
            .delivery = .reliable,
            .lane = .gameplay,
        });
    }

    fn queueInteractionActionResult(
        self: *Authority,
        participant_index: usize,
        action: protocol.InteractionAction,
        disposition: protocol.InteractionActionDisposition,
    ) !void {
        const connection_index = self.participants[participant_index].connection_index orelse
            return;
        if (!self.connections[connection_index].active) return;
        try self.queue(.{
            .connection = self.connections[connection_index].transport,
            .message = .{ .interaction_action_result = .{
                .sequence = action.sequence,
                .carryable = action.carryable,
                .action = action.kind,
                .disposition = disposition,
            } },
            .delivery = .reliable,
            .lane = .gameplay,
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
        if (outbound.delivery == .reliable) {
            const connection_index = self.findConnection(outbound.connection) orelse
                return error.UnknownOutboundConnection;
            const connection = &self.connections[connection_index];
            const current_tick = self.simulation.tickIndex();
            if (connection.event_quota_tick != current_tick) {
                connection.event_quota_tick = current_tick;
                connection.reliable_events_this_tick = 0;
            }
            if (connection.reliable_events_this_tick >= budgets.max_reliable_events_per_tick) {
                return error.ReliableEventBudgetExceeded;
            }
            connection.reliable_events_this_tick += 1;
            self.max_reliable_events_per_connection_tick = @max(
                self.max_reliable_events_per_connection_tick,
                connection.reliable_events_this_tick,
            );
        }
        try self.outbox.push(outbound);
        self.outbox_high_water = @max(self.outbox_high_water, @as(u16, @intCast(self.outbox.len)));
    }

    fn findConnection(self: *const Authority, transport: TransportConnection) ?usize {
        for (self.connections, 0..) |connection, index| {
            if (connection.active and connection.transport.value == transport.value) return index;
        }
        return null;
    }

    fn findVehicle(
        self: *const Authority,
        replicated: identity.ReplicatedEntityId,
    ) ?usize {
        for (self.vehicles, 0..) |vehicle, index| {
            if ((vehicle.active or vehicle.spawn_pending) and
                std.meta.eql(vehicle.replicated, replicated)) return index;
        }
        return null;
    }

    fn findVehicleByPersistent(
        self: *const Authority,
        persistent: sandbox.PersistentId,
    ) ?usize {
        for (self.vehicles, 0..) |vehicle, index| {
            if (vehicle.active and vehicle.persistent != null and
                std.meta.eql(vehicle.persistent.?, persistent)) return index;
        }
        return null;
    }

    fn findCarryable(
        self: *const Authority,
        replicated: identity.ReplicatedEntityId,
    ) ?usize {
        for (self.carryables, 0..) |carryable, index| {
            if ((carryable.active or carryable.spawn_pending) and
                std.meta.eql(carryable.replicated, replicated)) return index;
        }
        return null;
    }

    fn findCarryableByPersistent(
        self: *const Authority,
        persistent: sandbox.PersistentId,
    ) ?usize {
        for (self.carryables, 0..) |carryable, index| {
            if (carryable.active and carryable.persistent != null and
                std.meta.eql(carryable.persistent.?, persistent)) return index;
        }
        return null;
    }

    fn findNpcByPersistent(
        self: *const Authority,
        persistent: sandbox.PersistentId,
    ) ?usize {
        for (self.npcs, 0..) |npc, index| {
            if (npc.active and npc.persistent != null and
                std.meta.eql(npc.persistent.?, persistent)) return index;
        }
        return null;
    }

    fn findParticipantByCharacter(
        self: *const Authority,
        character: sandbox.PersistentId,
    ) ?usize {
        for (self.participants, 0..) |participant, index| {
            if (participant.active and participant.character != null and
                std.meta.eql(participant.character.?, character)) return index;
        }
        return null;
    }

    fn admissionNonceUsed(self: *const Authority, nonce: u64) bool {
        const now_unix_seconds = self.admission_time_unix_seconds;
        for (self.used_admission_nonces) |used| {
            if (used.nonce == nonce and
                used.expires_at_unix_seconds >= now_unix_seconds) return true;
        }
        return false;
    }

    fn rememberAdmissionNonce(
        self: *Authority,
        authorization: protocol.JoinAuthorization,
    ) !void {
        const now_unix_seconds = self.admission_time_unix_seconds;
        for (&self.used_admission_nonces) |*used| {
            if (used.nonce == 0 or used.expires_at_unix_seconds < now_unix_seconds) {
                used.* = .{
                    .nonce = authorization.nonce,
                    .expires_at_unix_seconds = authorization.expires_at_unix_seconds,
                };
                return;
            }
        }
        return error.AdmissionNonceHistoryCapacityReached;
    }
};

fn snapshotWireBytes(message: protocol.ServerMessage) !usize {
    var storage: [budgets.max_wire_message_bytes]u8 = undefined;
    return (try protocol.encodeServer(message, &storage)).len;
}

fn normalizedExternalIdentity(hello: protocol.Hello) protocol.ExternalIdentity {
    var external = hello.external_identity;
    if (external.provider == .development and external.subject == 0) {
        external.subject = hello.account.value;
    }
    return external;
}

fn participantId(index: usize, generation: u16) identity.ParticipantId {
    return .{ .index = @intCast(index + 1), .generation = generation };
}

fn districtCoord(value: sandbox.ChunkCoord) protocol.DistrictCoord {
    return .{ .x = value.x, .z = value.z };
}

fn insideDistrictHysteresis(position: [3]f32, coord: sandbox.ChunkCoord) bool {
    const center_x = @as(f32, @floatFromInt(coord.x)) * sandbox.district_chunk_span;
    const center_z = @as(f32, @floatFromInt(coord.z)) * sandbox.district_chunk_span;
    const inner_half_span = sandbox.district_chunk_half_span - 1.0;
    return @abs(position[0] - center_x) <= inner_half_span and
        @abs(position[2] - center_z) <= inner_half_span;
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
        @as(u64, record.action_sequence.value),
        record.target_tick,
        @as(u64, @as(u32, @bitCast(record.move[0]))),
        @as(u64, @as(u32, @bitCast(record.move[1]))),
        @as(u64, @as(u32, @bitCast(record.facing_yaw))),
        @as(u64, @intFromBool(record.jump_pressed)),
        @as(u64, @intFromEnum(record.kind)),
        @as(u64, record.vehicle.index),
        @as(u64, record.vehicle.generation),
        @as(u64, record.carryable.index),
        @as(u64, record.carryable.generation),
        @as(u64, @as(u32, @bitCast(record.vehicle_control[0]))),
        @as(u64, @as(u32, @bitCast(record.vehicle_control[1]))),
        @as(u64, @as(u32, @bitCast(record.vehicle_control[2]))),
        @as(u64, @as(u32, @bitCast(record.vehicle_control[3]))),
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

fn vehicleSpawnRequestId(index: usize, generation: u16) u64 {
    return 0x4d50_3400_0000_0000 |
        (@as(u64, generation) << 16) |
        @as(u64, @intCast(index + 1));
}

fn decodeVehicleSpawnRequestId(value: u64) ?struct { index: usize, generation: u16 } {
    if (value & 0xffff_ffff_0000_0000 != 0x4d50_3400_0000_0000) return null;
    const raw_index: u16 = @truncate(value);
    if (raw_index == 0 or raw_index > budgets.max_vehicles) return null;
    return .{
        .index = raw_index - 1,
        .generation = @truncate(value >> 16),
    };
}

fn districtBootstrapRequestId(index: usize) u64 {
    return 0x4d50_3600_0000_0000 | @as(u64, @intCast(index + 1));
}

fn decodeDistrictBootstrapRequestId(value: u64) ?usize {
    if (value & 0xffff_ffff_ffff_ff00 != 0x4d50_3600_0000_0000) return null;
    const raw: u8 = @truncate(value);
    if (raw == 0 or raw > 2) return null;
    return raw - 1;
}

fn districtBootstrapCoord(index: usize) sandbox.ChunkCoord {
    return switch (index) {
        0 => sandbox.navigation_west_coord,
        1 => sandbox.navigation_east_coord,
        else => unreachable,
    };
}

fn carryableSpawnRequestId(index: usize, generation: u16) u64 {
    return 0x4d50_3500_0000_0000 |
        (@as(u64, generation) << 16) |
        @as(u64, @intCast(index + 1));
}

fn decodeCarryableSpawnRequestId(value: u64) ?struct { index: usize, generation: u16 } {
    if (value & 0xffff_ffff_0000_0000 != 0x4d50_3500_0000_0000) return null;
    const raw_index: u16 = @truncate(value);
    if (raw_index == 0 or raw_index > budgets.max_carryables) return null;
    return .{
        .index = raw_index - 1,
        .generation = @truncate(value >> 16),
    };
}

fn npcSpawnRequestId(index: usize, generation: u16) u64 {
    return 0x4d50_3700_0000_0000 |
        (@as(u64, generation) << 16) |
        @as(u64, @intCast(index + 1));
}

fn decodeNpcSpawnRequestId(value: u64) ?struct { index: usize, generation: u16 } {
    if (value & 0xffff_ffff_0000_0000 != 0x4d50_3700_0000_0000) return null;
    const raw_index: u16 = @truncate(value);
    if (raw_index == 0 or raw_index > budgets.max_npcs) return null;
    return .{
        .index = raw_index - 1,
        .generation = @truncate(value >> 16),
    };
}

fn interactionTransactionId(
    participant_index: usize,
    generation: u16,
    sequence: identity.ActionSequence,
) u64 {
    return 0xd000_0000_0000_0000 |
        (@as(u64, @intCast(participant_index + 1)) << 56) |
        (@as(u64, generation) << 40) |
        @as(u64, sequence.value);
}

fn interactionCleanupTransactionId(participant_index: usize, generation: u16) u64 {
    return 0xc000_0000_0000_0000 |
        (@as(u64, @intCast(participant_index + 1)) << 56) |
        (@as(u64, generation) << 40);
}

fn vehicleRejectionDisposition(
    reason: @FieldType(sandbox.VehicleCommandRejected, "reason"),
) protocol.VehicleActionDisposition {
    return switch (reason) {
        .vehicle_not_found => .vehicle_not_found,
        .too_far => .too_far,
        .exit_blocked => .exit_blocked,
        .seat_occupied, .occupied => .unavailable,
        .capacity_reached,
        .not_owned,
        .driver_not_found,
        .driver_not_on_foot,
        .driver_carrying,
        .wrong_driver,
        => .invalid_state,
    };
}

fn interactionRejectionDisposition(
    reason: anytype,
) protocol.InteractionActionDisposition {
    return switch (reason) {
        .carryable_not_found, .not_owned => .carryable_not_found,
        .carryable_already_held, .carryable_held, .carrier_not_empty => .unavailable,
        .too_far => .too_far,
        .destination_district_inactive, .owner_district_inactive => .destination_unavailable,
        .capacity_reached,
        .carrier_not_found,
        .carrier_not_on_foot,
        .carrier_not_holding,
        .wrong_holder,
        => .invalid_state,
    };
}

fn testTakeAndAcknowledgeBaseline(
    authority: *Authority,
    transport: TransportConnection,
) !protocol.Snapshot {
    var baseline: ?protocol.RelevanceBaseline = null;
    while (authority.pollOutbound()) |outbound| switch (outbound.message) {
        .relevance_baseline => |value| baseline = value,
        else => {},
    };
    const value = baseline orelse return error.MissingInitialBaseline;
    const connection_index = authority.findConnection(transport) orelse
        return error.MissingTestConnection;
    const participant_index = authority.connections[connection_index].participant_index orelse
        return error.MissingTestParticipant;
    try authority.ingest(transport, .{ .baseline_ack = .{
        .session = authority.session,
        .participant = participantId(
            participant_index,
            authority.participants[participant_index].generation,
        ),
        .baseline_id = value.baseline_id,
    } });
    return value.snapshot;
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
    const first_snapshot = try testTakeAndAcknowledgeBaseline(
        &authority,
        .{ .value = 101 },
    );
    try std.testing.expectEqual(@as(u8, 1), first_snapshot.character_count);
    try std.testing.expectEqual(@as(u8, 1), first_snapshot.vehicle_count);

    _ = try authority.openConnection(.{ .value = 202 });
    try authority.ingest(.{ .value = 202 }, .{ .hello = .{
        .account = .{ .value = 2 },
    } });
    _ = authority.pollOutbound().?.message.welcome;
    try authority.tick();
    var saw_two = false;
    while (authority.pollOutbound()) |outbound| switch (outbound.message) {
        .snapshot => |snapshot| saw_two = saw_two or snapshot.character_count == 2,
        .relevance_baseline => |baseline| saw_two = saw_two or baseline.snapshot.character_count == 2,
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

test "authority owns vehicle enter drive exit and dynamic seat projection" {
    var authority = try Authority.init(std.testing.allocator);
    defer authority.deinit();
    const transport = TransportConnection{ .value = 1 };
    _ = try authority.openConnection(transport);
    try authority.ingest(transport, .{ .hello = .{
        .account = .{ .value = 1 },
    } });
    const welcome = authority.pollOutbound().?.message.welcome;
    try authority.tick();
    const initial = try testTakeAndAcknowledgeBaseline(&authority, transport);
    try std.testing.expectEqual(@as(u8, 1), initial.vehicle_count);
    const vehicle = initial.vehicles[0].entity;

    for (0..180) |_| {
        try authority.tick();
        while (authority.pollOutbound() != null) {}
    }
    try authority.ingest(transport, .{ .vehicle_action = .{
        .session = welcome.session,
        .participant = welcome.participant,
        .sequence = .{ .value = 1 },
        .vehicle = vehicle,
        .kind = .enter,
    } });
    try authority.tick();
    var enter_disposition: ?protocol.VehicleActionDisposition = null;
    while (authority.pollOutbound()) |outbound| switch (outbound.message) {
        .vehicle_action_result => |result| enter_disposition = result.disposition,
        else => {},
    };
    try std.testing.expectEqual(
        protocol.VehicleActionDisposition.entered,
        enter_disposition orelse return error.MissingVehicleEnterResult,
    );

    var last_snapshot = initial;
    for (1..181) |sequence| {
        try authority.ingest(transport, .{ .vehicle_input = .{
            .session = welcome.session,
            .participant = welcome.participant,
            .sequence = .{ .value = @intCast(sequence) },
            .target_tick = authority.diagnostics().tick + 1,
            .vehicle = vehicle,
            .throttle = 1,
            .steering = 0,
            .brake = 0,
            .hand_brake = 0,
        } });
        try authority.tick();
        while (authority.pollOutbound()) |outbound| switch (outbound.message) {
            .snapshot => |snapshot| last_snapshot = snapshot,
            else => {},
        };
    }
    try std.testing.expect(last_snapshot.vehicles[0].driver != null);
    try std.testing.expect(last_snapshot.vehicles[0].position[2] <
        initial.vehicles[0].position[2] - 1);

    try authority.ingest(transport, .{ .vehicle_action = .{
        .session = welcome.session,
        .participant = welcome.participant,
        .sequence = .{ .value = 2 },
        .vehicle = vehicle,
        .kind = .exit,
    } });
    try authority.tick();
    var saw_exit = false;
    while (authority.pollOutbound()) |outbound| switch (outbound.message) {
        .vehicle_action_result => |result| saw_exit = result.disposition == .exited,
        else => {},
    };
    try std.testing.expect(saw_exit);
    try std.testing.expectEqual(@as(u64, 2), authority.diagnostics().vehicle_actions_accepted);
}

test "graceful leave orders cleanup behind an admitted vehicle transition" {
    var authority = try Authority.init(std.testing.allocator);
    defer authority.deinit();
    const transport = TransportConnection{ .value = 1 };
    _ = try authority.openConnection(transport);
    try authority.ingest(transport, .{ .hello = .{ .account = .{ .value = 1 } } });
    const welcome = authority.pollOutbound().?.message.welcome;
    try authority.tick();
    const initial = try testTakeAndAcknowledgeBaseline(&authority, transport);
    const vehicle = initial.vehicles[0].entity;
    for (0..180) |_| {
        try authority.tick();
        while (authority.pollOutbound() != null) {}
    }
    try authority.ingest(transport, .{ .vehicle_action = .{
        .session = welcome.session,
        .participant = welcome.participant,
        .sequence = .{ .value = 1 },
        .vehicle = vehicle,
        .kind = .enter,
    } });
    try authority.ingest(transport, .{ .disconnect = .requested });
    for (0..4) |_| {
        try authority.tick();
        while (authority.pollOutbound() != null) {}
    }
    try std.testing.expectEqual(@as(u16, 0), authority.diagnostics().active_participants);
    try std.testing.expectEqual(@as(u16, 1), authority.diagnostics().active_vehicles);
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
