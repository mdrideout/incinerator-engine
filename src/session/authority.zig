//! Server-authoritative session for the multiplayer sandbox vertical slices.
//!
//! Transport ownership is outside this module. It accepts copied, decoded
//! semantic messages associated with an opaque transport connection and emits
//! bounded messages plus explicit close policy.

const std = @import("std");
const builtin = @import("builtin");
const engine = @import("incinerator_engine");
const sandbox = @import("sandbox_simulation");
const simulation_snapshot = @import("simulation_snapshot");
const crate_contract = @import("crate_contract");
const character_contract = @import("character_contract");
const vehicle_contract = @import("vehicle_contract");
const district_feature_contract = @import("district_feature_contract");
const interaction_feature_contract = @import("interaction_feature_contract");
const npc_contract = @import("npc_contract");
const district_contract = @import("district_contract");
const sandbox_district_recipe = @import("sandbox_district_recipe");
const sandbox_diagnostics_contract = @import("sandbox_diagnostics_contract");
const sandbox_host_contracts = @import("sandbox_host_contracts");
const budgets = @import("session_budgets");
const identity = @import("session_identity");
const protocol = @import("session_protocol");
const gameplay_admission = @import("gameplay_admission");
const snapshot_source = @import("snapshot_source");
const transport_policy = @import("session_transport_policy");
const authority_diagnostics = @import("session_authority_diagnostics");

pub const TransportConnection = struct { value: u32 };

pub const Outbound = struct {
    connection: TransportConnection,
    message: protocol.ServerMessage,
    delivery: transport_policy.Delivery,
    lane: transport_policy.Lane,
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
    retained_reconnect: identity.ReconnectToken = .invalid,
    reconnect_confirmation_pending: bool = false,
    reconnect_deadline_tick: u64 = 0,
    character: ?engine.PersistentId = null,
    replicated: identity.ReplicatedEntityId = .invalid,
    last_received_input: identity.InputSequence = .{ .value = 0 },
    last_applied_input: identity.InputSequence = .{ .value = 0 },
    pending_inputs: PendingInputs = .{},
    held_input: ?HeldInput = null,
    held_input_applied: bool = false,
    held_input_started_tick: u64 = 0,
    driving_vehicle_index: ?u8 = null,
    last_vehicle_action: identity.ActionSequence = .{ .value = 0 },
    pending_vehicle_action: ?protocol.VehicleAction = null,
    holding_carryable_index: ?u8 = null,
    last_interaction_action: identity.ActionSequence = .{ .value = 0 },
    pending_interaction_action: ?protocol.InteractionAction = null,
    interaction_cleanup_pending: bool = false,
    relevance_coord: district_contract.ChunkCoord = sandbox_district_recipe.navigation_west_coord,
    baseline_id: u32 = 0,
    baseline_acknowledged: u32 = 0,
    baseline_sent: bool = false,
    exit_pending: bool = false,
    spawn_pending: bool = false,
    host_spawn_request_id: ?u64 = null,
    despawn_pending: bool = false,
    retain_after_despawn: bool = false,
};

const HeldInput = union(enum) {
    character: protocol.InputFrame,
    vehicle: protocol.VehicleInputFrame,
};

const PendingInput = struct {
    value: HeldInput,
};

const pending_input_capacity: usize = budgets.max_input_messages_per_tick;

/// One ordered input sample per declared target tick. A newer sequence for the
/// same target deterministically supersedes the older sample; distinct future
/// targets remain queued and cannot overwrite one another.
const PendingInputs = struct {
    values: [pending_input_capacity]PendingInput = undefined,
    len: u8 = 0,

    fn push(self: *PendingInputs, pending: PendingInput) !void {
        if (self.len != 0) {
            const last = &self.values[self.len - 1];
            const last_target = heldInputTargetTick(last.value);
            const target = heldInputTargetTick(pending.value);
            if (target < last_target) return error.NonMonotonicInputTarget;
            if (target == last_target) {
                last.* = pending;
                return;
            }
        }
        if (self.len == self.values.len) return error.InputQueueCapacityReached;
        self.values[self.len] = pending;
        self.len += 1;
    }

    fn takeLatestDue(self: *PendingInputs, target_tick: u64) ?PendingInput {
        var due_count: usize = 0;
        while (due_count < self.len and
            heldInputTargetTick(self.values[due_count].value) <= target_tick)
        {
            due_count += 1;
        }
        if (due_count == 0) return null;
        const latest = self.values[due_count - 1];
        const remaining = @as(usize, self.len) - due_count;
        std.mem.copyForwards(
            PendingInput,
            self.values[0..remaining],
            self.values[due_count..self.len],
        );
        self.len = @intCast(remaining);
        return latest;
    }

    fn clear(self: *PendingInputs) void {
        self.len = 0;
    }
};

fn heldInputTargetTick(input: HeldInput) u64 {
    return switch (input) {
        .character => |frame| frame.target_tick,
        .vehicle => |frame| frame.target_tick,
    };
}

fn heldInputSequence(input: HeldInput) identity.InputSequence {
    return switch (input) {
        .character => |frame| frame.sequence,
        .vehicle => |frame| frame.sequence,
    };
}

fn clearParticipantInputs(participant: *ParticipantSlot) void {
    participant.pending_inputs.clear();
    participant.held_input = null;
    participant.held_input_applied = false;
    participant.held_input_started_tick = 0;
}

const VehicleSlot = struct {
    active: bool = false,
    spawn_pending: bool = false,
    generation: u16 = 0,
    persistent: ?engine.PersistentId = null,
    replicated: identity.ReplicatedEntityId = .invalid,
};

const CarryableSlot = struct {
    active: bool = false,
    spawn_pending: bool = false,
    generation: u16 = 0,
    persistent: ?engine.PersistentId = null,
    replicated: identity.ReplicatedEntityId = .invalid,
};

const NpcSlot = struct {
    active: bool = false,
    spawn_pending: bool = false,
    generation: u16 = 0,
    persistent: ?engine.PersistentId = null,
    replicated: identity.ReplicatedEntityId = .invalid,
};

pub const Options = struct {
    downstream_bytes_per_second: usize = budgets.average_client_down_bytes_per_second,
    full_snapshot_interval_ticks: u64 = budgets.full_snapshot_interval_ticks,
    room_admission: ?RoomAdmission = null,
};

pub const WorldBootstrap = enum {
    dedicated_fixture,
    host_managed,
};

pub const ParticipantSpawn = enum {
    automatic,
    host_managed,
};

pub const ObservationMode = enum {
    disabled,
    bounded,
};

/// Placement-neutral construction policy for the concrete sandbox authority.
/// The simulation remains authority-owned; callers provide value configuration
/// and select explicit bootstrap/capability behavior only.
pub const CoreConfig = struct {
    simulation: sandbox_host_contracts.Config,
    world_bootstrap: WorldBootstrap,
    participant_spawn: ParticipantSpawn,
    observation: ObservationMode,
};

pub const PersistenceCohort = struct {
    payload_schema: u16,
    simulation_build_digest: [32]u8,
    world_config_digest: [32]u8,
};

pub const HostObservationDiagnostics = struct {
    pending_records: u32,
    records_dropped: u64,
};

fn beginAuthorityCycle(completed_tick: u64) authority_diagnostics.CycleTrace {
    return .{
        .target_tick = completed_tick +| 1,
        .completed_tick_before = completed_tick,
        .completed_tick_after = completed_tick,
    };
}

fn recordAuthorityCycleStage(
    trace: *authority_diagnostics.CycleTrace,
    stage: authority_diagnostics.CycleStage,
    completed_tick: u64,
) void {
    std.debug.assert(trace.count < trace.stages.len);
    trace.stages[trace.count] = stage;
    trace.count += 1;
    trace.completed_tick_after = completed_tick;
}

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

const CredentialIssuer = struct {
    secret: [32]u8,
    next_serial: u64 = 1,

    fn init(test_secret: ?[32]u8) !CredentialIssuer {
        return .{ .secret = test_secret orelse try secureCredentialSecret() };
    }

    fn deinit(self: *CredentialIssuer) void {
        std.crypto.secureZero(u8, &self.secret);
        self.next_serial = 0;
    }

    fn issueSession(self: *CredentialIssuer) !identity.SessionId {
        for (0..8) |_| {
            const digest = try self.derive(.session, .{}, .{}, .invalid);
            const value = credentialU64(digest[0..8]);
            if (value != 0) return .{ .value = value };
        }
        return error.CredentialIssuerCollision;
    }

    fn issueReconnect(
        self: *CredentialIssuer,
        session: identity.SessionId,
        account: identity.AccountId,
        external_identity: protocol.ExternalIdentity,
        participant: identity.ParticipantId,
    ) !identity.ReconnectToken {
        const digest = try self.derive(
            .reconnect,
            .{ .session = session, .account = account },
            external_identity,
            participant,
        );
        return .{
            .high = credentialU64(digest[0..8]),
            .low = credentialU64(digest[8..16]),
        };
    }

    const Domain = enum(u8) { session = 1, reconnect = 2 };
    const Principal = struct {
        session: identity.SessionId = .{ .value = 0 },
        account: identity.AccountId = .{ .value = 0 },
    };

    fn derive(
        self: *CredentialIssuer,
        domain: Domain,
        principal: Principal,
        external_identity: protocol.ExternalIdentity,
        participant: identity.ParticipantId,
    ) ![32]u8 {
        if (self.next_serial == std.math.maxInt(u64)) {
            return error.CredentialIssuerExhausted;
        }
        const serial = self.next_serial;
        self.next_serial += 1;

        var message: [64]u8 = @splat(0);
        message[0] = @intFromEnum(domain);
        writeCredentialU64(&message, 8, serial);
        writeCredentialU64(&message, 16, principal.session.value);
        writeCredentialU64(&message, 24, principal.account.value);
        writeCredentialU64(&message, 32, @intFromEnum(external_identity.provider));
        writeCredentialU64(&message, 40, external_identity.subject);
        writeCredentialU64(&message, 48, participant.index);
        writeCredentialU64(&message, 56, participant.generation);

        var digest: [32]u8 = undefined;
        std.crypto.auth.hmac.sha2.HmacSha256.create(
            &digest,
            &message,
            &self.secret,
        );
        return digest;
    }
};

fn secureCredentialSecret() ![32]u8 {
    var secret: [32]u8 = undefined;
    switch (builtin.os.tag) {
        .driverkit,
        .ios,
        .maccatalyst,
        .macos,
        .tvos,
        .visionos,
        .watchos,
        .dragonfly,
        .freebsd,
        .illumos,
        .netbsd,
        .openbsd,
        => std.c.arc4random_buf(secret[0..].ptr, secret.len),
        else => return error.SecureCredentialEntropyUnavailable,
    }
    return secret;
}

fn writeCredentialU64(message: *[64]u8, offset: usize, value: u64) void {
    inline for (0..8) |index| message[offset + index] = @truncate(value >> (index * 8));
}

fn credentialU64(bytes: []const u8) u64 {
    std.debug.assert(bytes.len == 8);
    var value: u64 = 0;
    inline for (0..8) |index| value |= @as(u64, bytes[index]) << (index * 8);
    return value;
}

fn reconnectCredentialsEqual(
    lhs: identity.ReconnectToken,
    rhs: identity.ReconnectToken,
) bool {
    return std.crypto.timing_safe.eql(
        [2]u64,
        .{ lhs.high, lhs.low },
        .{ rhs.high, rhs.low },
    );
}

fn admissionSecretIsZero(secret: protocol.AdmissionSecret) bool {
    for (secret) |byte| if (byte != 0) return false;
    return true;
}

const host_observation_capacity: usize = budgets.inbound_message_capacity;

fn ObservationQueue(comptime T: type) type {
    return engine.BoundedQueue(T, host_observation_capacity);
}

const HostObservations = struct {
    crate_outcomes: ObservationQueue(crate_contract.Outcome) = .{},
    character_outcomes: ObservationQueue(character_contract.Outcome) = .{},
    character_events: ObservationQueue(character_contract.Event) = .{},
    vehicle_outcomes: ObservationQueue(vehicle_contract.Outcome) = .{},
    vehicle_events: ObservationQueue(vehicle_contract.Event) = .{},
    district_outcomes: ObservationQueue(district_feature_contract.Outcome) = .{},
    district_events: ObservationQueue(district_feature_contract.Event) = .{},
    interaction_outcomes: ObservationQueue(interaction_feature_contract.Outcome) = .{},
    npc_outcomes: ObservationQueue(npc_contract.Outcome) = .{},
    npc_events: ObservationQueue(npc_contract.Event) = .{},
    records_dropped: u64 = 0,

    fn empty(self: *const HostObservations) bool {
        return self.crate_outcomes.len == 0 and
            self.character_outcomes.len == 0 and
            self.character_events.len == 0 and
            self.vehicle_outcomes.len == 0 and
            self.vehicle_events.len == 0 and
            self.district_outcomes.len == 0 and
            self.district_events.len == 0 and
            self.interaction_outcomes.len == 0 and
            self.npc_outcomes.len == 0 and
            self.npc_events.len == 0;
    }

    fn pending(self: *const HostObservations) u32 {
        const total = self.crate_outcomes.len +
            self.character_outcomes.len + self.character_events.len +
            self.vehicle_outcomes.len + self.vehicle_events.len +
            self.district_outcomes.len + self.district_events.len +
            self.interaction_outcomes.len + self.npc_outcomes.len +
            self.npc_events.len;
        return std.math.cast(u32, total) orelse std.math.maxInt(u32);
    }
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

/// Concrete game-specific authority implementation shared by authority
/// placements. Placement façades in this module deliberately control which
/// capabilities escape; the dedicated host receives session/transport
/// operations only.
const AuthorityCore = struct {
    allocator: std.mem.Allocator,
    simulation: sandbox.Simulation,
    world_bootstrap: WorldBootstrap,
    participant_spawn: ParticipantSpawn,
    observation_mode: ObservationMode,
    observations: HostObservations = .{},
    snapshot_source_issued: bool = false,
    persistence_cohort: PersistenceCohort,
    credential_issuer: CredentialIssuer,
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
    last_cycle: authority_diagnostics.CycleTrace = .{},
    first_cycle_fault: ?authority_diagnostics.CycleFault = null,
    fn init(
        allocator: std.mem.Allocator,
        core_config: CoreConfig,
        options: Options,
        test_credential_secret: ?[32]u8,
        comptime diagnostic_fault_probe: bool,
    ) !AuthorityCore {
        const authority_fixed_delta_seconds = 1.0 /
            @as(f32, @floatFromInt(budgets.authority_tick_hz));
        if (core_config.simulation.fixed_delta_seconds != authority_fixed_delta_seconds) {
            return error.AuthorityTickRateMismatch;
        }
        if (options.downstream_bytes_per_second == 0 or
            options.full_snapshot_interval_ticks == 0)
        {
            return error.InvalidReplicationOptions;
        }
        if (options.room_admission) |room| {
            if (room.room_id == 0 or room.authority_id == 0 or
                room.room_generation == 0 or admissionSecretIsZero(room.secret))
            {
                return error.InvalidRoomAdmissionOptions;
            }
        }
        if (@sizeOf(protocol.Snapshot) * budgets.snapshot_history_capacity >
            budgets.max_baseline_bytes_per_client)
        {
            return error.BaselineMemoryBudgetExceeded;
        }
        const persistence_cohort = PersistenceCohort{
            .payload_schema = sandbox_host_contracts.snapshot_schema,
            .simulation_build_digest = try simulation_snapshot.currentSimulationBuildFingerprint(),
            .world_config_digest = try simulation_snapshot.worldConfigFingerprint(
                core_config.simulation,
            ),
        };
        var credential_issuer = try CredentialIssuer.init(test_credential_secret);
        errdefer credential_issuer.deinit();
        const session = try credential_issuer.issueSession();
        const outbox = try allocator.create(Outbox);
        errdefer allocator.destroy(outbox);
        outbox.* = .{};
        const replication = try allocator.create([budgets.max_participants]ReplicationState);
        errdefer allocator.destroy(replication);
        replication.* = @splat(.{});
        var authority = AuthorityCore{
            .allocator = allocator,
            .simulation = if (diagnostic_fault_probe)
                try sandbox.Simulation.initWithDiagnosticFaultProbe(
                    allocator,
                    core_config.simulation,
                )
            else
                try sandbox.Simulation.init(allocator, core_config.simulation),
            .world_bootstrap = core_config.world_bootstrap,
            .participant_spawn = core_config.participant_spawn,
            .observation_mode = core_config.observation,
            .persistence_cohort = persistence_cohort,
            .credential_issuer = credential_issuer,
            .session = session,
            .outbox = outbox,
            .replication = replication,
            .options = options,
        };
        errdefer authority.simulation.deinit();
        if (core_config.world_bootstrap == .dedicated_fixture) {
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
                    .index = @intCast(
                        budgets.max_participants + budgets.max_vehicles + 1,
                    ),
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
                .coord = sandbox_district_recipe.navigation_west_coord,
                .assets = .{},
            } });
        }
        return authority;
    }

    fn deinit(self: *AuthorityCore) void {
        self.simulation.deinit();
        self.allocator.destroy(self.replication);
        self.allocator.destroy(self.outbox);
        self.credential_issuer.deinit();
        self.* = undefined;
    }

    fn openConnection(
        self: *AuthorityCore,
        transport: TransportConnection,
    ) !identity.ConnectionId {
        try self.ensureOperationalMutation();
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

    fn transportClosed(
        self: *AuthorityCore,
        transport: TransportConnection,
    ) void {
        const connection_index = self.findConnection(transport) orelse return;
        self.detachConnection(connection_index, true);
    }

    fn spawnHostParticipantCharacter(
        self: *AuthorityCore,
        transport: TransportConnection,
        requested: character_contract.SpawnCharacter,
    ) !void {
        try self.ensureOperationalMutation();
        if (self.participant_spawn != .host_managed) {
            return error.HostManagedParticipantSpawnDisabled;
        }
        const connection_index = self.findConnection(transport) orelse
            return error.UnknownTransportConnection;
        const participant_index = self.connections[connection_index].participant_index orelse
            return error.ParticipantNotAdmitted;
        const participant = &self.participants[participant_index];
        if (!participant.active or participant.character != null or participant.spawn_pending) {
            return error.ParticipantCharacterAlreadyAssigned;
        }
        participant.spawn_pending = true;
        participant.host_spawn_request_id = requested.request_id;
        errdefer {
            participant.spawn_pending = false;
            participant.host_spawn_request_id = null;
        }
        var internal = requested;
        internal.request_id = spawnRequestId(participant_index, participant.generation);
        try self.simulation.submitCharacter(.{ .spawn = internal });
    }

    fn despawnHostParticipantCharacter(
        self: *AuthorityCore,
        transport: TransportConnection,
        id: engine.PersistentId,
    ) !void {
        try self.ensureOperationalMutation();
        if (self.participant_spawn != .host_managed) {
            return error.HostManagedParticipantSpawnDisabled;
        }
        const connection_index = self.findConnection(transport) orelse
            return error.UnknownTransportConnection;
        const participant_index = self.connections[connection_index].participant_index orelse
            return error.ParticipantNotAdmitted;
        const participant = &self.participants[participant_index];
        if (!participant.active or participant.character == null or
            !std.meta.eql(participant.character.?, id))
        {
            return error.ParticipantCharacterNotAssigned;
        }
        if (participant.despawn_pending) return error.ParticipantDespawnPending;
        participant.retain_after_despawn = true;
        participant.despawn_pending = true;
        clearParticipantInputs(participant);
        errdefer {
            participant.retain_after_despawn = false;
            participant.despawn_pending = false;
        }
        try self.continueParticipantDespawn(participant_index);
    }

    fn requireHostManaged(self: *const AuthorityCore) !void {
        if (self.world_bootstrap != .host_managed) {
            return error.HostManagedAuthorityCapabilityDisabled;
        }
    }

    fn submitHostCrate(self: *AuthorityCore, command: crate_contract.Command) !void {
        try self.ensureOperationalMutation();
        try self.requireHostManaged();
        try self.simulation.submit(command);
    }

    fn submitHostVehicle(
        self: *AuthorityCore,
        command: vehicle_contract.Command,
    ) !void {
        try self.ensureOperationalMutation();
        try self.requireHostManaged();
        if (command == .spawn and
            decodeVehicleSpawnRequestId(command.spawn.request_id) != null)
        {
            return error.ReservedAuthorityCorrelation;
        }
        try self.simulation.submitVehicle(command);
    }

    fn submitHostDistrict(
        self: *AuthorityCore,
        command: district_feature_contract.Command,
    ) !void {
        try self.ensureOperationalMutation();
        try self.requireHostManaged();
        const request_id, const coord = switch (command) {
            .request_load => |value| .{ value.request_id, value.coord },
            .cancel_load => |value| .{ value.request_id, value.ticket.coord },
            .unload => |value| .{ value.request_id, value.ticket.coord },
        };
        if (authorityDistrictIndex(coord) == null) return error.UnsupportedAuthorityDistrict;
        if (decodeDistrictBootstrapRequestId(request_id) != null) {
            return error.ReservedAuthorityCorrelation;
        }
        try self.simulation.submitDistrict(command);
    }

    fn submitHostInteraction(
        self: *AuthorityCore,
        command: interaction_feature_contract.Command,
    ) !void {
        try self.ensureOperationalMutation();
        try self.requireHostManaged();
        switch (command) {
            .spawn => |value| if (decodeCarryableSpawnRequestId(value.request_id) != null) {
                return error.ReservedAuthorityCorrelation;
            },
            .collect => |value| if (isReservedInteractionTransaction(value.transaction_id)) {
                return error.ReservedAuthorityCorrelation;
            },
            .drop => |value| if (isReservedInteractionTransaction(value.transaction_id)) {
                return error.ReservedAuthorityCorrelation;
            },
            .despawn => {},
        }
        try self.simulation.submitInteraction(command);
    }

    fn submitHostNpc(self: *AuthorityCore, command: npc_contract.Command) !void {
        try self.ensureOperationalMutation();
        try self.requireHostManaged();
        if (command == .spawn and decodeNpcSpawnRequestId(command.spawn.request_id) != null) {
            return error.ReservedAuthorityCorrelation;
        }
        try self.simulation.submitNpc(command);
    }

    fn issueSnapshotSource(self: *AuthorityCore) !snapshot_source.Source {
        try self.ensureOperationalMutation();
        try self.requireHostManaged();
        if (self.snapshot_source_issued) return error.SnapshotSourceAlreadyIssued;
        self.snapshot_source_issued = true;
        return .{
            .context = self,
            .capture_fn = captureSnapshotForPersistence,
        };
    }

    fn captureSnapshotForPersistence(
        context: *anyopaque,
        allocator: std.mem.Allocator,
    ) anyerror![]u8 {
        const self: *AuthorityCore = @ptrCast(@alignCast(context));
        if (self.first_cycle_fault != null) return error.AuthorityFaulted;
        if (self.outbox.len != 0 or !self.observations.empty()) {
            return error.AuthorityOutputsPending;
        }
        for (self.participants) |participant| {
            if (participant.pending_inputs.len != 0 or
                (participant.held_input != null and !participant.held_input_applied) or
                participant.spawn_pending or participant.despawn_pending or
                participant.pending_vehicle_action != null or
                participant.pending_interaction_action != null or
                participant.interaction_cleanup_pending or participant.exit_pending)
            {
                return error.SessionWorkPending;
            }
        }
        if (self.simulation.operationalQuiescenceReason()) |reason| switch (reason) {
            .runtime_faulted => return error.AuthorityFaulted,
            .commands_pending => return error.CommandsPending,
            .district_transition,
            .district_outcome_reservations,
            .district_worker_busy,
            => return error.DistrictTransitionPending,
            .outputs_pending => return error.AuthorityOutputsPending,
        };
        return self.simulation.save(allocator);
    }

    fn ingestBytes(
        self: *AuthorityCore,
        transport: TransportConnection,
        bytes: []const u8,
    ) !void {
        try self.ensureOperationalMutation();
        const message = protocol.decodeClient(bytes) catch {
            self.malformed_messages +|= 1;
            try self.rejectTransport(transport, .malformed, true);
            return;
        };
        try self.ingest(transport, message);
    }

    fn ingest(
        self: *AuthorityCore,
        transport: TransportConnection,
        message: protocol.ClientMessage,
    ) !void {
        try self.ingestWithAdmissionTime(transport, message, null);
    }

    fn ingestAtUnixTime(
        self: *AuthorityCore,
        transport: TransportConnection,
        message: protocol.ClientMessage,
        now_unix_seconds: u64,
    ) !void {
        try self.ingestWithAdmissionTime(transport, message, now_unix_seconds);
    }

    fn ingestWithAdmissionTime(
        self: *AuthorityCore,
        transport: TransportConnection,
        message: protocol.ClientMessage,
        now_unix_seconds: ?u64,
    ) !void {
        try self.ensureOperationalMutation();
        // Hello retains its explicit admission/rejection policy below. Every
        // other typed ingress must cross the same semantic boundary as byte
        // decoding and the in-process link before authority state is touched.
        if (message != .hello) try protocol.validateClient(message);
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
        const accepted_messages_before = self.accepted_messages;

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
        if (message != .hello and self.accepted_messages != accepted_messages_before) {
            self.confirmReconnectCredential(connection_index);
        }
    }

    fn tick(self: *AuthorityCore) !void {
        try self.tickImpl(null, null);
    }

    fn tickObserved(
        self: *AuthorityCore,
        observer: ?engine.PhaseObserver,
    ) !void {
        try self.tickImpl(observer, null);
    }

    fn tickImpl(
        self: *AuthorityCore,
        observer: ?engine.PhaseObserver,
        comptime fault_stage: ?authority_diagnostics.CycleStage,
    ) !void {
        try self.ensureOperationalMutation();
        self.last_cycle = beginAuthorityCycle(self.simulation.tickIndex());

        try self.maybeInjectCycleFault(fault_stage, .pre_simulation);
        self.prepareSimulationTick() catch |err| {
            self.latchCycleFault(.pre_simulation, err);
            return err;
        };
        recordAuthorityCycleStage(
            &self.last_cycle,
            .pre_simulation,
            self.simulation.tickIndex(),
        );

        try self.maybeInjectCycleFault(fault_stage, .simulation);
        self.simulation.tickObserved(observer) catch |err| {
            self.latchCycleFault(.simulation, err);
            return err;
        };
        recordAuthorityCycleStage(
            &self.last_cycle,
            .simulation,
            self.simulation.tickIndex(),
        );

        try self.maybeInjectCycleFault(fault_stage, .outcome_drain);
        self.drainSimulationOutcomes() catch |err| {
            self.latchCycleFault(.outcome_drain, err);
            return err;
        };
        recordAuthorityCycleStage(
            &self.last_cycle,
            .outcome_drain,
            self.simulation.tickIndex(),
        );

        try self.maybeInjectCycleFault(fault_stage, .replication_extraction);
        self.extractReplication() catch |err| {
            self.latchCycleFault(.replication_extraction, err);
            return err;
        };
        recordAuthorityCycleStage(
            &self.last_cycle,
            .replication_extraction,
            self.simulation.tickIndex(),
        );
    }

    inline fn maybeInjectCycleFault(
        self: *AuthorityCore,
        comptime fault_stage: ?authority_diagnostics.CycleStage,
        comptime current_stage: authority_diagnostics.CycleStage,
    ) !void {
        if (fault_stage == current_stage) {
            self.latchCycleFault(current_stage, error.InjectedAuthorityCycleFault);
            return error.InjectedAuthorityCycleFault;
        }
    }

    fn prepareSimulationTick(self: *AuthorityCore) !void {
        self.replenishReplicationBudgets();
        try self.expireConnections(self.simulation.tickIndex());
        try self.expireReconnects();
        try self.applyHeldInputs(self.simulation.tickIndex());
    }

    fn drainSimulationOutcomes(self: *AuthorityCore) !void {
        self.processCrateOutcomes();
        try self.processCharacterOutcomes();
        try self.processVehicleOutcomes();
        try self.processDistrictOutcomes();
        try self.processInteractionOutcomes();
        try self.processNpcOutcomes();
    }

    fn extractReplication(self: *AuthorityCore) !void {
        const tick_index = self.simulation.tickIndex();
        if (self.force_snapshot or tick_index % budgets.ticks_per_snapshot == 0) {
            try self.publishSnapshots();
            self.force_snapshot = false;
        }
    }

    fn latchCycleFault(
        self: *AuthorityCore,
        stage: authority_diagnostics.CycleStage,
        err: anyerror,
    ) void {
        self.last_cycle.failed_stage = stage;
        self.last_cycle.completed_tick_after = self.simulation.tickIndex();
        if (self.first_cycle_fault == null) {
            self.first_cycle_fault = .{
                .stage = stage,
                .target_tick = self.last_cycle.target_tick,
                .completed_tick = self.simulation.tickIndex(),
                .error_code = @intFromError(err),
                .error_name = engine.runtime.FaultText.copy(@errorName(err)),
            };
        }
    }

    fn pollOutbound(self: *AuthorityCore) ?Outbound {
        return self.outbox.pop();
    }

    fn stop(self: *AuthorityCore) !void {
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

    fn copyAcceptedIngress(
        self: *const AuthorityCore,
        output: []AcceptedIngress,
    ) usize {
        return self.ingress.copy(output);
    }

    fn rejectOversized(
        self: *AuthorityCore,
        transport: TransportConnection,
    ) !void {
        try self.ensureOperationalMutation();
        try self.rejectTransport(transport, .oversized, true);
    }

    /// Updated by the room/service ingress owner before ticket admission. It
    /// is intentionally separate from deterministic simulation time.
    fn updateAdmissionTime(self: *AuthorityCore, now_unix_seconds: u64) !void {
        try self.ensureOperationalMutation();
        if (now_unix_seconds < self.admission_time_unix_seconds) {
            return error.AdmissionClockMovedBackward;
        }
        self.admission_time_unix_seconds = now_unix_seconds;
    }

    fn ensureOperationalMutation(self: *const AuthorityCore) !void {
        if (self.first_cycle_fault != null) return error.AuthorityFaulted;
    }

    fn diagnostics(self: *const AuthorityCore) authority_diagnostics.Diagnostics {
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
            .last_cycle = self.last_cycle,
            .first_cycle_fault = self.first_cycle_fault,
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

    fn ingestHello(self: *AuthorityCore, connection_index: usize, hello: protocol.Hello) !void {
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
        const reconnecting = hello.reconnect.isValid();

        if (!self.authorizationValid(hello, external_identity, reconnecting)) {
            try self.rejectConnection(connection_index, .unauthorized, true);
            return;
        }

        if (reconnecting) {
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
        const admission_nonce_slot = if (hello.join_authorization.isPresent())
            self.availableAdmissionNonceSlot() orelse
                return error.AdmissionNonceHistoryCapacityReached
        else
            null;
        const participant_index = self.allocateParticipant() orelse {
            try self.rejectConnection(connection_index, .session_full, true);
            return;
        };
        const participant = &self.participants[participant_index];
        if (admission_nonce_slot) |slot| {
            self.commitAdmissionNonce(slot, hello.join_authorization);
        }
        participant.account = hello.account;
        participant.external_identity = external_identity;
        participant.connection_index = @intCast(connection_index);
        participant.reconnect = try self.issueReconnectCredential(
            hello.account,
            external_identity,
            participantId(participant_index, participant.generation),
        );
        participant.replicated = .{
            .index = @intCast(participant_index + 1),
            .generation = participant.generation,
        };
        participant.relevance_coord = sandbox_district_recipe.navigation_west_coord;
        participant.baseline_id = 1;
        participant.baseline_acknowledged = 0;
        participant.baseline_sent = false;
        self.resetReplicationBaseline(participant_index);
        self.connections[connection_index].participant_index = @intCast(participant_index);
        if (self.participant_spawn == .automatic) {
            participant.spawn_pending = true;
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
        }
        try self.queueWelcome(connection_index, participant_index);
        self.accepted_messages +|= 1;
        self.force_snapshot = true;
    }

    fn tryReconnect(
        self: *AuthorityCore,
        connection_index: usize,
        hello: protocol.Hello,
    ) !bool {
        const tick_index = self.simulation.tickIndex();
        const external_identity = normalizedExternalIdentity(hello);
        for (&self.participants, 0..) |*participant, participant_index| {
            const current_credential = reconnectCredentialsEqual(
                participant.reconnect,
                hello.reconnect,
            );
            const retained_credential = participant.reconnect_confirmation_pending and
                reconnectCredentialsEqual(participant.retained_reconnect, hello.reconnect);
            if (!participant.active or participant.connection_index != null or
                participant.despawn_pending or
                !std.meta.eql(participant.account, hello.account) or
                !std.meta.eql(participant.external_identity, external_identity) or
                (!current_credential and !retained_credential) or
                tick_index > participant.reconnect_deadline_tick)
            {
                continue;
            }
            const next_reconnect = try self.issueReconnectCredential(
                participant.account,
                participant.external_identity,
                participantId(participant_index, participant.generation),
            );
            const previous_reconnect = participant.reconnect;
            const previous_retained_reconnect = participant.retained_reconnect;
            const previous_confirmation_pending = participant.reconnect_confirmation_pending;
            const connection = &self.connections[connection_index];
            const previous_event_quota_tick = connection.event_quota_tick;
            const previous_reliable_events = connection.reliable_events_this_tick;
            const previous_max_reliable_events = self.max_reliable_events_per_connection_tick;
            // Retain only the credential actually presented until a valid
            // post-Hello message proves the client received this Welcome.
            // This bounds recovery to one prior credential while preventing a
            // lost queued Welcome from stranding the client.
            participant.retained_reconnect = hello.reconnect;
            participant.reconnect_confirmation_pending = true;
            participant.reconnect = next_reconnect;
            self.queueWelcome(connection_index, participant_index) catch |err| {
                participant.reconnect = previous_reconnect;
                participant.retained_reconnect = previous_retained_reconnect;
                participant.reconnect_confirmation_pending = previous_confirmation_pending;
                connection.event_quota_tick = previous_event_quota_tick;
                connection.reliable_events_this_tick = previous_reliable_events;
                self.max_reliable_events_per_connection_tick = previous_max_reliable_events;
                return err;
            };
            participant.connection_index = @intCast(connection_index);
            participant.baseline_id +%= 1;
            if (participant.baseline_id == 0) participant.baseline_id = 1;
            participant.baseline_acknowledged = 0;
            participant.baseline_sent = false;
            self.resetReplicationBaseline(participant_index);
            self.connections[connection_index].participant_index = @intCast(participant_index);
            self.reconnects +|= 1;
            self.accepted_messages +|= 1;
            self.force_snapshot = true;
            return true;
        }
        return false;
    }

    fn confirmReconnectCredential(self: *AuthorityCore, connection_index: usize) void {
        const participant_index = self.connections[connection_index].participant_index orelse
            return;
        const participant = &self.participants[participant_index];
        if (!participant.active or participant.connection_index == null or
            @as(usize, participant.connection_index.?) != connection_index or
            !participant.reconnect_confirmation_pending)
        {
            return;
        }
        participant.retained_reconnect = .invalid;
        participant.reconnect_confirmation_pending = false;
    }

    fn ingestInput(
        self: *AuthorityCore,
        connection_index: usize,
        input: protocol.InputFrame,
    ) !void {
        const tick_index = self.simulation.tickIndex();
        const connection = &self.connections[connection_index];
        if (!gameplay_admission.consumeInputQuota(
            tick_index,
            &connection.input_quota_tick,
            &connection.input_messages_this_tick,
        )) {
            self.quota_violations +|= 1;
            try self.rejectConnection(connection_index, .quota_exceeded, true);
            return;
        }
        const participant_index = self.connections[connection_index].participant_index orelse {
            try self.rejectConnection(connection_index, .unauthorized, false);
            return;
        };
        const participant = &self.participants[participant_index];
        if (!gameplay_admission.identitiesMatch(
            self.session,
            participantId(
                participant_index,
                participant.generation,
            ),
            input.session,
            input.participant,
        )) {
            try self.rejectConnection(connection_index, .stale_connection, false);
            return;
        }
        switch (gameplay_admission.classifyInput(
            participant.last_received_input,
            tick_index,
            input.sequence,
            input.target_tick,
        )) {
            .accepted => {},
            .stale_sequence => {
                self.stale_inputs +|= 1;
                return;
            },
            .outside_tick_window => {
                try self.rejectConnection(connection_index, .stale_sequence, false);
                return;
            },
        }
        if (participant.character == null and !participant.spawn_pending) {
            try self.rejectConnection(connection_index, .invalid_state, false);
            return;
        }
        if (participant.driving_vehicle_index != null) {
            self.invalid_control_inputs +|= 1;
            return;
        }
        participant.pending_inputs.push(.{
            .value = .{ .character = input },
        }) catch |err| switch (err) {
            error.NonMonotonicInputTarget => {
                self.stale_inputs +|= 1;
                return;
            },
            error.InputQueueCapacityReached => {
                self.quota_violations +|= 1;
                try self.rejectConnection(connection_index, .quota_exceeded, true);
                return;
            },
        };
        participant.last_received_input = input.sequence;
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
        self: *AuthorityCore,
        connection_index: usize,
        input: protocol.VehicleInputFrame,
    ) !void {
        const tick_index = self.simulation.tickIndex();
        const connection = &self.connections[connection_index];
        if (!gameplay_admission.consumeInputQuota(
            tick_index,
            &connection.input_quota_tick,
            &connection.input_messages_this_tick,
        )) {
            self.quota_violations +|= 1;
            try self.rejectConnection(connection_index, .quota_exceeded, true);
            return;
        }
        const participant_index = connection.participant_index orelse {
            try self.rejectConnection(connection_index, .unauthorized, false);
            return;
        };
        const participant = &self.participants[participant_index];
        if (!gameplay_admission.identitiesMatch(
            self.session,
            participantId(
                participant_index,
                participant.generation,
            ),
            input.session,
            input.participant,
        )) {
            try self.rejectConnection(connection_index, .stale_connection, false);
            return;
        }
        switch (gameplay_admission.classifyInput(
            participant.last_received_input,
            tick_index,
            input.sequence,
            input.target_tick,
        )) {
            .accepted => {},
            .stale_sequence => {
                self.stale_inputs +|= 1;
                return;
            },
            .outside_tick_window => {
                try self.rejectConnection(connection_index, .stale_sequence, false);
                return;
            },
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
        participant.pending_inputs.push(.{
            .value = .{ .vehicle = input },
        }) catch |err| switch (err) {
            error.NonMonotonicInputTarget => {
                self.stale_inputs +|= 1;
                return;
            },
            error.InputQueueCapacityReached => {
                self.quota_violations +|= 1;
                try self.rejectConnection(connection_index, .quota_exceeded, true);
                return;
            },
        };
        participant.last_received_input = input.sequence;
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
        self: *AuthorityCore,
        connection_index: usize,
        action: protocol.VehicleAction,
    ) !void {
        const participant_index = self.connections[connection_index].participant_index orelse {
            try self.rejectConnection(connection_index, .unauthorized, false);
            return;
        };
        const participant = &self.participants[participant_index];
        if (!gameplay_admission.identitiesMatch(
            self.session,
            participantId(
                participant_index,
                participant.generation,
            ),
            action.session,
            action.participant,
        )) {
            try self.rejectConnection(connection_index, .stale_connection, false);
            return;
        }
        if (!gameplay_admission.actionIsNewer(
            participant.last_vehicle_action,
            action.sequence,
        )) {
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
        clearParticipantInputs(participant);
        self.accepted_messages +|= 1;
    }

    fn ingestInteractionAction(
        self: *AuthorityCore,
        connection_index: usize,
        action: protocol.InteractionAction,
    ) !void {
        const participant_index = self.connections[connection_index].participant_index orelse {
            try self.rejectConnection(connection_index, .unauthorized, false);
            return;
        };
        const participant = &self.participants[participant_index];
        if (!gameplay_admission.identitiesMatch(
            self.session,
            participantId(
                participant_index,
                participant.generation,
            ),
            action.session,
            action.participant,
        )) {
            try self.rejectConnection(connection_index, .stale_connection, false);
            return;
        }
        if (!gameplay_admission.actionIsNewer(
            participant.last_interaction_action,
            action.sequence,
        )) {
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
        clearParticipantInputs(participant);
        self.accepted_messages +|= 1;
    }

    fn ingestBaselineAck(
        self: *AuthorityCore,
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
        self: *AuthorityCore,
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

    fn replenishReplicationBudgets(self: *AuthorityCore) void {
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

    fn applyHeldInputs(self: *AuthorityCore, tick_index: u64) !void {
        const next_tick = tick_index +| 1;
        for (&self.participants) |*participant| {
            if (!participant.active or participant.connection_index == null or
                participant.character == null or participant.despawn_pending)
            {
                continue;
            }
            if (participant.pending_inputs.takeLatestDue(next_tick)) |pending| {
                participant.held_input = pending.value;
                participant.held_input_applied = false;
                participant.held_input_started_tick = tick_index;
            }
            const fresh = participant.held_input != null and
                tick_index -| participant.held_input_started_tick <= budgets.input_hold_ticks;
            if (!fresh) {
                participant.held_input = null;
                participant.held_input_applied = false;
                participant.held_input_started_tick = 0;
            }
            if (participant.driving_vehicle_index) |vehicle_index| {
                if (participant.exit_pending) continue;
                const vehicle = self.vehicles[vehicle_index];
                const persistent = vehicle.persistent orelse continue;
                var control = engine.physics.VehicleInput{};
                var applied_input: ?HeldInput = null;
                if (fresh) if (participant.held_input) |held| switch (held) {
                    .vehicle => |input| {
                        control = .{
                            .throttle = input.throttle,
                            .steering = input.steering,
                            .brake = input.brake,
                            .hand_brake = input.hand_brake,
                        };
                        applied_input = held;
                    },
                    .character => {},
                };
                try self.simulation.submitVehicle(.{ .drive = .{
                    .vehicle_id = persistent,
                    .driver_id = participant.character.?,
                    .input = control,
                } });
                if (applied_input) |input| {
                    participant.held_input_applied = true;
                    participant.last_applied_input = heldInputSequence(input);
                }
                continue;
            }
            if (!fresh) continue;
            const held = participant.held_input orelse continue;
            switch (held) {
                .character => |input| {
                    try self.simulation.submitCharacter(.{ .actions = .{
                        .id = participant.character.?,
                        .move = input.move,
                        .facing_yaw = input.facing_yaw,
                        .jump_pressed = input.jump_pressed and !participant.held_input_applied,
                    } });
                    participant.held_input_applied = true;
                    participant.last_applied_input = input.sequence;
                },
                .vehicle => {},
            }
        }
    }

    fn ingestDisconnect(
        self: *AuthorityCore,
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

    fn expireConnections(self: *AuthorityCore, tick_index: u64) !void {
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

    fn expireReconnects(self: *AuthorityCore) !void {
        const tick_index = self.simulation.tickIndex();
        for (&self.participants, 0..) |participant, index| {
            if (participant.active and participant.connection_index == null and
                !participant.despawn_pending and tick_index >= participant.reconnect_deadline_tick)
            {
                try self.beginParticipantDespawn(index);
            }
        }
    }

    fn beginParticipantDespawn(self: *AuthorityCore, participant_index: usize) !void {
        const participant = &self.participants[participant_index];
        // Transport/reconnect retirement always wins over a concurrent local
        // host request that would otherwise retain the participant slot.
        participant.retain_after_despawn = false;
        if (!participant.active or participant.despawn_pending) return;
        participant.despawn_pending = true;
        clearParticipantInputs(participant);
        try self.continueParticipantDespawn(participant_index);
    }

    fn retainObservation(
        self: *AuthorityCore,
        target_queue: anytype,
        value: anytype,
    ) void {
        if (self.observation_mode == .disabled) return;
        if (target_queue.isFull()) {
            _ = target_queue.pop();
            self.observations.records_dropped +|= 1;
        }
        target_queue.pushAssumeCapacity(value);
    }

    fn processCrateOutcomes(self: *AuthorityCore) void {
        while (self.simulation.pollOutcome()) |outcome| {
            self.retainObservation(&self.observations.crate_outcomes, outcome);
        }
    }

    fn continueParticipantDespawn(self: *AuthorityCore, participant_index: usize) !void {
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

    fn processCharacterOutcomes(self: *AuthorityCore) !void {
        while (self.simulation.pollCharacterOutcome()) |outcome| {
            var observed = outcome;
            defer self.retainObservation(&self.observations.character_outcomes, observed);
            switch (outcome) {
                .spawned => |spawned| {
                    const decoded = decodeSpawnRequestId(spawned.request_id) orelse
                        return error.UnexpectedCharacterSpawnOutcome;
                    const participant = &self.participants[decoded.index];
                    if (!participant.active or participant.generation != decoded.generation or
                        !participant.spawn_pending)
                    {
                        return error.StaleCharacterSpawnOutcome;
                    }
                    if (participant.host_spawn_request_id) |request_id| {
                        var remapped = spawned;
                        remapped.request_id = request_id;
                        observed = .{ .spawned = remapped };
                        participant.host_spawn_request_id = null;
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
                            const retain_participant = participant.retain_after_despawn and
                                participant.connection_index != null;
                            participant.active = retain_participant;
                            if (!retain_participant) participant.connection_index = null;
                            participant.character = null;
                            participant.driving_vehicle_index = null;
                            participant.holding_carryable_index = null;
                            participant.pending_vehicle_action = null;
                            participant.pending_interaction_action = null;
                            participant.exit_pending = false;
                            participant.interaction_cleanup_pending = false;
                            participant.spawn_pending = false;
                            participant.host_spawn_request_id = null;
                            participant.despawn_pending = false;
                            participant.retain_after_despawn = false;
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
                        if (participant.host_spawn_request_id) |host_request_id| {
                            var remapped = rejected;
                            remapped.request_id = host_request_id;
                            observed = .{ .rejected = remapped };
                            participant.host_spawn_request_id = null;
                        }
                        if (participant.connection_index) |connection_index| {
                            try self.rejectConnection(connection_index, .invalid_state, true);
                        }
                        participant.spawn_pending = false;
                        participant.active = false;
                    } else return error.UnexpectedCharacterRejection;
                },
            }
        }
        while (self.simulation.pollCharacterEvent()) |event| {
            self.retainObservation(&self.observations.character_events, event);
        }
    }

    fn processVehicleOutcomes(self: *AuthorityCore) !void {
        while (self.simulation.pollVehicleOutcome()) |outcome| {
            defer self.retainObservation(&self.observations.vehicle_outcomes, outcome);
            switch (outcome) {
                .spawned => |spawned| {
                    if (decodeVehicleSpawnRequestId(spawned.request_id)) |decoded| {
                        const vehicle = &self.vehicles[decoded.index];
                        if (vehicle.generation != decoded.generation or !vehicle.spawn_pending) {
                            return error.StaleVehicleSpawnOutcome;
                        }
                        vehicle.spawn_pending = false;
                        vehicle.active = true;
                        vehicle.persistent = spawned.id;
                    } else if (self.world_bootstrap == .host_managed) {
                        try self.registerHostVehicle(spawned.id);
                    } else {
                        return error.UnexpectedVehicleSpawnOutcome;
                    }
                    self.force_snapshot = true;
                },
                .entered => |entered| {
                    const participant_index = self.findParticipantByCharacter(
                        entered.driver_id,
                    ) orelse {
                        if (self.world_bootstrap == .host_managed) continue;
                        return error.UnknownVehicleDriver;
                    };
                    const vehicle_index = self.findVehicleByPersistent(
                        entered.vehicle_id,
                    ) orelse {
                        if (self.world_bootstrap == .host_managed) continue;
                        return error.UnknownVehicleOutcome;
                    };
                    const participant = &self.participants[participant_index];
                    participant.driving_vehicle_index = @intCast(vehicle_index);
                    clearParticipantInputs(participant);
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
                    const participant_index = self.findParticipantByCharacter(
                        exited.driver_id,
                    ) orelse {
                        if (self.world_bootstrap == .host_managed) continue;
                        return error.UnknownVehicleDriver;
                    };
                    const participant = &self.participants[participant_index];
                    participant.driving_vehicle_index = null;
                    participant.exit_pending = false;
                    clearParticipantInputs(participant);
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
                    const participant_index = self.findParticipantByCharacter(
                        abandoned.driver_id,
                    ) orelse {
                        if (self.world_bootstrap == .host_managed) continue;
                        return error.UnknownVehicleDriver;
                    };
                    const participant = &self.participants[participant_index];
                    if (!participant.despawn_pending or !participant.exit_pending or
                        participant.pending_vehicle_action != null)
                    {
                        return error.UnexpectedVehicleAbandonOutcome;
                    }
                    participant.driving_vehicle_index = null;
                    participant.exit_pending = false;
                    clearParticipantInputs(participant);
                    try self.simulation.submitCharacter(.{ .despawn = .{
                        .id = abandoned.driver_id,
                    } });
                    self.forced_vehicle_cleanup +|= 1;
                    self.force_snapshot = true;
                },
                .despawned => |id| {
                    if (self.world_bootstrap != .host_managed) {
                        return error.UnexpectedVehicleDespawnOutcome;
                    }
                    self.unregisterHostVehicle(id);
                    self.force_snapshot = true;
                },
                .rejected => |rejected| {
                    const driver = rejected.driver_id orelse {
                        if (self.world_bootstrap == .host_managed) continue;
                        return error.UnexpectedVehicleRejection;
                    };
                    const participant_index = self.findParticipantByCharacter(driver) orelse {
                        if (self.world_bootstrap == .host_managed) continue;
                        return error.UnknownVehicleDriver;
                    };
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
                    const action = participant.pending_vehicle_action orelse {
                        if (self.world_bootstrap == .host_managed) continue;
                        return error.UnexpectedVehicleRejection;
                    };
                    try self.queueVehicleActionResult(
                        participant_index,
                        action,
                        vehicleRejectionDisposition(rejected.reason),
                    );
                    participant.pending_vehicle_action = null;
                    participant.exit_pending = false;
                    clearParticipantInputs(participant);
                    self.vehicle_actions_rejected +|= 1;
                    if (participant.despawn_pending and
                        participant.driving_vehicle_index == null)
                    {
                        try self.simulation.submitCharacter(.{ .despawn = .{ .id = driver } });
                    }
                },
            }
        }
        while (self.simulation.pollVehicleEvent()) |event| {
            self.retainObservation(&self.observations.vehicle_events, event);
        }
    }

    fn processDistrictOutcomes(self: *AuthorityCore) !void {
        while (self.simulation.pollDistrictOutcome()) |outcome| {
            defer self.retainObservation(&self.observations.district_outcomes, outcome);
            if (self.world_bootstrap == .host_managed) {
                switch (outcome) {
                    .activated => |activated| {
                        try self.setHostDistrictActive(activated.coord, true);
                        self.force_snapshot = true;
                    },
                    .unloaded => |unloaded| {
                        try self.setHostDistrictActive(unloaded.ticket.coord, false);
                        self.force_snapshot = true;
                    },
                    .cancelled => |cancelled| {
                        try self.setHostDistrictActive(cancelled.ticket.coord, false);
                    },
                    .load_failed => |failed| {
                        try self.setHostDistrictActive(failed.ticket.coord, false);
                    },
                    .load_requested, .cancellation_requested, .rejected => {},
                }
                continue;
            }
            switch (outcome) {
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
                                sandbox_district_recipe.navigation_west_coord
                            else
                                sandbox_district_recipe.navigation_east_coord;
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
                        .coord = sandbox_district_recipe.navigation_east_coord,
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
            }
        }
        while (self.simulation.pollDistrictEvent()) |event| {
            self.retainObservation(&self.observations.district_events, event);
        }
    }

    fn processInteractionOutcomes(self: *AuthorityCore) !void {
        while (self.simulation.pollInteractionOutcome()) |outcome| {
            defer self.retainObservation(&self.observations.interaction_outcomes, outcome);
            switch (outcome) {
                .spawned => |spawned| {
                    if (decodeCarryableSpawnRequestId(spawned.request_id)) |decoded| {
                        const carryable = &self.carryables[decoded.index];
                        if (carryable.generation != decoded.generation or
                            !carryable.spawn_pending)
                        {
                            return error.StaleCarryableSpawnOutcome;
                        }
                        carryable.spawn_pending = false;
                        carryable.active = true;
                        carryable.persistent = spawned.id;
                    } else if (self.world_bootstrap == .host_managed) {
                        try self.registerHostCarryable(spawned.id);
                    } else {
                        return error.UnexpectedCarryableSpawnOutcome;
                    }
                    self.force_snapshot = true;
                },
                .collected => |collected| {
                    const participant_index = self.findParticipantByCharacter(
                        collected.carrier_id,
                    ) orelse {
                        if (self.world_bootstrap == .host_managed) continue;
                        return error.UnknownInteractionCarrier;
                    };
                    const carryable_index = self.findCarryableByPersistent(
                        collected.carryable_id,
                    ) orelse {
                        if (self.world_bootstrap == .host_managed) continue;
                        return error.UnknownInteractionCarryable;
                    };
                    const participant = &self.participants[participant_index];
                    const action = participant.pending_interaction_action orelse {
                        if (self.world_bootstrap == .host_managed) {
                            participant.holding_carryable_index = @intCast(carryable_index);
                            clearParticipantInputs(participant);
                            self.force_snapshot = true;
                            continue;
                        }
                        return error.UnexpectedInteractionCollectOutcome;
                    };
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
                    clearParticipantInputs(participant);
                    try self.queueInteractionActionResult(participant_index, action, .collected);
                    self.interaction_actions_accepted +|= 1;
                    self.force_snapshot = true;
                    try self.continueParticipantDespawn(participant_index);
                },
                .dropped => |dropped| {
                    const participant_index = self.findParticipantByCharacter(
                        dropped.carrier_id,
                    ) orelse {
                        if (self.world_bootstrap == .host_managed) continue;
                        return error.UnknownInteractionCarrier;
                    };
                    const carryable_index = self.findCarryableByPersistent(
                        dropped.carryable_id,
                    ) orelse {
                        if (self.world_bootstrap == .host_managed) continue;
                        return error.UnknownInteractionCarryable;
                    };
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
                        clearParticipantInputs(participant);
                        self.forced_interaction_cleanup +|= 1;
                        self.force_snapshot = true;
                        try self.continueParticipantDespawn(participant_index);
                        continue;
                    }
                    const action = participant.pending_interaction_action orelse {
                        if (self.world_bootstrap == .host_managed) {
                            if (participant.holding_carryable_index != null and
                                participant.holding_carryable_index.? == carryable_index)
                            {
                                participant.holding_carryable_index = null;
                            }
                            clearParticipantInputs(participant);
                            self.force_snapshot = true;
                            continue;
                        }
                        return error.UnexpectedInteractionDropOutcome;
                    };
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
                    clearParticipantInputs(participant);
                    try self.queueInteractionActionResult(participant_index, action, .dropped);
                    self.interaction_actions_accepted +|= 1;
                    self.force_snapshot = true;
                    try self.continueParticipantDespawn(participant_index);
                },
                .despawned => |id| {
                    if (self.world_bootstrap != .host_managed) {
                        return error.UnexpectedCarryableDespawnOutcome;
                    }
                    self.unregisterHostCarryable(id);
                    self.force_snapshot = true;
                },
                .rejected => |rejected| {
                    const carrier = rejected.carrier_id orelse {
                        if (self.world_bootstrap == .host_managed) continue;
                        return error.UnexpectedInteractionRejection;
                    };
                    const participant_index = self.findParticipantByCharacter(carrier) orelse {
                        if (self.world_bootstrap == .host_managed) continue;
                        return error.UnknownInteractionCarrier;
                    };
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
                    const action = participant.pending_interaction_action orelse {
                        if (self.world_bootstrap == .host_managed) continue;
                        return error.UnexpectedInteractionRejection;
                    };
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
                    clearParticipantInputs(participant);
                    self.interaction_actions_rejected +|= 1;
                    try self.continueParticipantDespawn(participant_index);
                },
            }
        }
    }

    fn processNpcOutcomes(self: *AuthorityCore) !void {
        while (self.simulation.pollNpcOutcome()) |outcome| {
            defer self.retainObservation(&self.observations.npc_outcomes, outcome);
            switch (outcome) {
                .spawned => |spawned| {
                    if (decodeNpcSpawnRequestId(spawned.request_id)) |decoded| {
                        const npc = &self.npcs[decoded.index];
                        if (npc.generation != decoded.generation or !npc.spawn_pending) {
                            return error.StaleNpcSpawnOutcome;
                        }
                        npc.spawn_pending = false;
                        npc.active = true;
                        npc.persistent = spawned.id;
                    } else if (self.world_bootstrap == .host_managed) {
                        try self.registerHostNpc(spawned.id);
                    } else {
                        return error.UnexpectedNpcSpawnOutcome;
                    }
                    self.force_snapshot = true;
                },
                .goal_set => if (self.world_bootstrap != .host_managed) {
                    return error.UnexpectedNpcMutationOutcome;
                },
                .despawned => |despawned| {
                    if (self.world_bootstrap != .host_managed) {
                        return error.UnexpectedNpcMutationOutcome;
                    }
                    self.unregisterHostNpc(despawned.id);
                    self.force_snapshot = true;
                },
                .rejected => if (self.world_bootstrap != .host_managed) {
                    return error.NpcBootstrapRejected;
                },
            }
        }
        while (self.simulation.pollNpcEvent()) |event| {
            self.retainObservation(&self.observations.npc_events, event);
            switch (event) {
                .state_changed, .owner_transferred => self.force_snapshot = true,
                .goal_reached => {},
            }
        }
    }

    fn publishSnapshots(self: *AuthorityCore) !void {
        for (0..self.participants.len) |participant_index| {
            const participant = &self.participants[participant_index];
            const connection_index = participant.connection_index orelse continue;
            if (!participant.active or participant.despawn_pending or
                !self.connections[connection_index].active)
            {
                continue;
            }
            // A retained, connected participant may temporarily have no
            // character while the host tears it down and later respawns it.
            // It must still receive the empty authoritative projection so the
            // client removes the old replicated entity.
            if (participant.character != null) {
                try self.updateParticipantRelevance(participant_index);
            }
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

    fn updateParticipantRelevance(self: *AuthorityCore, participant_index: usize) !void {
        const participant = &self.participants[participant_index];
        const character = participant.character orelse return;
        const position = if (participant.driving_vehicle_index) |vehicle_index| blk: {
            const persistent = self.vehicles[vehicle_index].persistent orelse
                return error.VehicleAuthorityInvariantBroken;
            break :blk (try self.simulation.vehicle(persistent)).state.chassis.pose.position;
        } else (try self.simulation.character(character)).position;
        const candidate = try district_contract.chunkCoordForWorldPosition(position);
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
        self: *AuthorityCore,
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
        snapshot.acknowledged_input = target.last_applied_input;
        for (self.participants, 0..) |participant, index| {
            if (!participant.active or participant.character == null or
                participant.despawn_pending) continue;
            const view = try self.simulation.character(participant.character.?);
            const relevant = index == participant_index or std.meta.eql(
                try district_contract.chunkCoordForWorldPosition(view.position),
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
                    try district_contract.chunkCoordForWorldPosition(view.state.chassis.pose.position),
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
                    try district_contract.chunkCoordForWorldPosition(draw.pose.position),
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
        self: *AuthorityCore,
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
        self: *const AuthorityCore,
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

    fn resetReplicationBaseline(self: *AuthorityCore, participant_index: usize) void {
        const replication = &self.replication[participant_index];
        replication.history = @splat(.{});
        replication.history_next = 0;
        replication.acknowledged_sequence = .{ .value = 0 };
        replication.baseline_sequence = .{ .value = 0 };
        replication.last_ack_tick = self.simulation.tickIndex();
        replication.last_full_tick = 0;
        replication.last_sent_tick = 0;
    }

    fn isDistrictActive(self: *const AuthorityCore, coord: district_contract.ChunkCoord) bool {
        const index = authorityDistrictIndex(coord) orelse return false;
        return self.active_districts[index];
    }

    fn setHostDistrictActive(
        self: *AuthorityCore,
        coord: district_contract.ChunkCoord,
        active: bool,
    ) !void {
        const index = authorityDistrictIndex(coord) orelse
            return error.UnsupportedAuthorityDistrictOutcome;
        self.active_districts[index] = active;
    }

    fn allocateParticipant(self: *AuthorityCore) ?usize {
        for (&self.participants, 0..) |*participant, index| {
            if (participant.active) continue;
            participant.generation +%= 1;
            if (participant.generation == 0) participant.generation = 1;
            participant.active = true;
            participant.account = .{ .value = 0 };
            participant.external_identity = .{};
            participant.connection_index = null;
            participant.reconnect = .invalid;
            participant.retained_reconnect = .invalid;
            participant.reconnect_confirmation_pending = false;
            participant.reconnect_deadline_tick = 0;
            participant.character = null;
            participant.replicated = .invalid;
            participant.last_received_input = .{ .value = 0 };
            participant.last_applied_input = .{ .value = 0 };
            clearParticipantInputs(participant);
            participant.driving_vehicle_index = null;
            participant.last_vehicle_action = .{ .value = 0 };
            participant.pending_vehicle_action = null;
            participant.holding_carryable_index = null;
            participant.last_interaction_action = .{ .value = 0 };
            participant.pending_interaction_action = null;
            participant.interaction_cleanup_pending = false;
            participant.relevance_coord = sandbox_district_recipe.navigation_west_coord;
            participant.baseline_id = 0;
            participant.baseline_acknowledged = 0;
            participant.baseline_sent = false;
            self.replication[index] = .{
                .byte_credit = self.options.downstream_bytes_per_second,
            };
            participant.exit_pending = false;
            participant.spawn_pending = false;
            participant.host_spawn_request_id = null;
            participant.despawn_pending = false;
            participant.retain_after_despawn = false;
            return index;
        }
        return null;
    }

    fn detachConnection(self: *AuthorityCore, connection_index: usize, allow_reconnect: bool) void {
        const connection = &self.connections[connection_index];
        if (!connection.active) return;
        if (connection.participant_index) |participant_index| {
            const participant = &self.participants[participant_index];
            if (participant.active and participant.connection_index != null and
                @as(usize, participant.connection_index.?) == connection_index)
            {
                participant.connection_index = null;
                clearParticipantInputs(participant);
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
        self: *AuthorityCore,
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
        self: *AuthorityCore,
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
        self: *AuthorityCore,
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
        self: *AuthorityCore,
        transport: TransportConnection,
        reason: protocol.RejectionReason,
        close_after_send: bool,
    ) !void {
        const connection_index = self.findConnection(transport) orelse
            return error.UnknownTransportConnection;
        try self.rejectConnection(connection_index, reason, close_after_send);
    }

    fn rejectConnection(
        self: *AuthorityCore,
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

    fn queue(self: *AuthorityCore, outbound: Outbound) !void {
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

    fn findConnection(self: *const AuthorityCore, transport: TransportConnection) ?usize {
        for (self.connections, 0..) |connection, index| {
            if (connection.active and connection.transport.value == transport.value) return index;
        }
        return null;
    }

    fn findVehicle(
        self: *const AuthorityCore,
        replicated: identity.ReplicatedEntityId,
    ) ?usize {
        for (self.vehicles, 0..) |vehicle, index| {
            if ((vehicle.active or vehicle.spawn_pending) and
                std.meta.eql(vehicle.replicated, replicated)) return index;
        }
        return null;
    }

    fn registerHostVehicle(
        self: *AuthorityCore,
        persistent: engine.PersistentId,
    ) !void {
        if (self.findVehicleByPersistent(persistent) != null) {
            return error.DuplicateHostVehicle;
        }
        for (&self.vehicles, 0..) |*vehicle, index| {
            if (vehicle.active or vehicle.spawn_pending) continue;
            vehicle.generation +%= 1;
            if (vehicle.generation == 0) vehicle.generation = 1;
            vehicle.active = true;
            vehicle.persistent = persistent;
            vehicle.replicated = .{
                .index = @intCast(budgets.max_participants + index + 1),
                .generation = vehicle.generation,
            };
            return;
        }
        return error.HostVehicleReplicationCapacityReached;
    }

    fn unregisterHostVehicle(
        self: *AuthorityCore,
        persistent: engine.PersistentId,
    ) void {
        const index = self.findVehicleByPersistent(persistent) orelse return;
        const generation = self.vehicles[index].generation;
        self.vehicles[index] = .{ .generation = generation };
    }

    fn findVehicleByPersistent(
        self: *const AuthorityCore,
        persistent: engine.PersistentId,
    ) ?usize {
        for (self.vehicles, 0..) |vehicle, index| {
            if (vehicle.active and vehicle.persistent != null and
                std.meta.eql(vehicle.persistent.?, persistent)) return index;
        }
        return null;
    }

    fn findCarryable(
        self: *const AuthorityCore,
        replicated: identity.ReplicatedEntityId,
    ) ?usize {
        for (self.carryables, 0..) |carryable, index| {
            if ((carryable.active or carryable.spawn_pending) and
                std.meta.eql(carryable.replicated, replicated)) return index;
        }
        return null;
    }

    fn registerHostCarryable(
        self: *AuthorityCore,
        persistent: engine.PersistentId,
    ) !void {
        if (self.findCarryableByPersistent(persistent) != null) {
            return error.DuplicateHostCarryable;
        }
        for (&self.carryables, 0..) |*carryable, index| {
            if (carryable.active or carryable.spawn_pending) continue;
            carryable.generation +%= 1;
            if (carryable.generation == 0) carryable.generation = 1;
            carryable.active = true;
            carryable.persistent = persistent;
            carryable.replicated = .{
                .index = @intCast(
                    budgets.max_participants + budgets.max_vehicles + index + 1,
                ),
                .generation = carryable.generation,
            };
            return;
        }
        return error.HostCarryableReplicationCapacityReached;
    }

    fn unregisterHostCarryable(
        self: *AuthorityCore,
        persistent: engine.PersistentId,
    ) void {
        const index = self.findCarryableByPersistent(persistent) orelse return;
        for (&self.participants) |*participant| {
            if (participant.holding_carryable_index != null and
                participant.holding_carryable_index.? == index)
            {
                participant.holding_carryable_index = null;
            }
        }
        const generation = self.carryables[index].generation;
        self.carryables[index] = .{ .generation = generation };
    }

    fn findCarryableByPersistent(
        self: *const AuthorityCore,
        persistent: engine.PersistentId,
    ) ?usize {
        for (self.carryables, 0..) |carryable, index| {
            if (carryable.active and carryable.persistent != null and
                std.meta.eql(carryable.persistent.?, persistent)) return index;
        }
        return null;
    }

    fn findNpcByPersistent(
        self: *const AuthorityCore,
        persistent: engine.PersistentId,
    ) ?usize {
        for (self.npcs, 0..) |npc, index| {
            if (npc.active and npc.persistent != null and
                std.meta.eql(npc.persistent.?, persistent)) return index;
        }
        return null;
    }

    /// Resolves the authority-owned durable identity for an exact active
    /// replicated generation. This is intentionally read-only: feature views
    /// remain the canonical source for feature-owned presentation metadata.
    fn persistentId(
        self: *const AuthorityCore,
        replicated: identity.ReplicatedEntityId,
    ) ?engine.PersistentId {
        for (self.participants) |participant| {
            if (participant.active and participant.character != null and
                std.meta.eql(participant.replicated, replicated))
            {
                return participant.character.?;
            }
        }
        for (self.vehicles) |vehicle| {
            if (vehicle.active and vehicle.persistent != null and
                std.meta.eql(vehicle.replicated, replicated))
            {
                return vehicle.persistent.?;
            }
        }
        for (self.carryables) |carryable| {
            if (carryable.active and carryable.persistent != null and
                std.meta.eql(carryable.replicated, replicated))
            {
                return carryable.persistent.?;
            }
        }
        for (self.npcs) |npc| {
            if (npc.active and npc.persistent != null and
                std.meta.eql(npc.replicated, replicated))
            {
                return npc.persistent.?;
            }
        }
        return null;
    }

    /// Resolves the current replicated generation for an exact active durable
    /// identity. Pending, inactive, stale, and unknown slots never resolve.
    fn replicatedId(
        self: *const AuthorityCore,
        persistent: engine.PersistentId,
    ) ?identity.ReplicatedEntityId {
        for (self.participants) |participant| {
            if (participant.active and participant.character != null and
                std.meta.eql(participant.character.?, persistent))
            {
                return participant.replicated;
            }
        }
        for (self.vehicles) |vehicle| {
            if (vehicle.active and vehicle.persistent != null and
                std.meta.eql(vehicle.persistent.?, persistent))
            {
                return vehicle.replicated;
            }
        }
        for (self.carryables) |carryable| {
            if (carryable.active and carryable.persistent != null and
                std.meta.eql(carryable.persistent.?, persistent))
            {
                return carryable.replicated;
            }
        }
        for (self.npcs) |npc| {
            if (npc.active and npc.persistent != null and
                std.meta.eql(npc.persistent.?, persistent))
            {
                return npc.replicated;
            }
        }
        return null;
    }

    /// Resolve the canonical world-space focus used by host residency policy
    /// without exposing participant slots or feature views to the host.
    fn authoritativeFocusPosition(
        self: *AuthorityCore,
        participant_id: identity.ParticipantId,
    ) !?[3]f32 {
        if (!participant_id.isValid()) return null;
        const participant_index = @as(usize, participant_id.index) - 1;
        if (participant_index >= self.participants.len) return null;
        const participant = self.participants[participant_index];
        if (!participant.active or
            participant.generation != participant_id.generation)
        {
            return null;
        }
        const character = participant.character orelse return null;
        if (participant.driving_vehicle_index) |vehicle_index| {
            const persistent = self.vehicles[vehicle_index].persistent orelse
                return error.VehicleAuthorityInvariantBroken;
            return (try self.simulation.vehicle(persistent)).state.chassis.pose.position;
        }
        return (try self.simulation.character(character)).position;
    }

    fn registerHostNpc(
        self: *AuthorityCore,
        persistent: engine.PersistentId,
    ) !void {
        if (self.findNpcByPersistent(persistent) != null) return error.DuplicateHostNpc;
        for (&self.npcs, 0..) |*npc, index| {
            if (npc.active or npc.spawn_pending) continue;
            npc.generation +%= 1;
            if (npc.generation == 0) npc.generation = 1;
            npc.active = true;
            npc.persistent = persistent;
            npc.replicated = .{
                .index = @intCast(
                    budgets.max_participants + budgets.max_vehicles +
                        budgets.max_carryables + index + 1,
                ),
                .generation = npc.generation,
            };
            return;
        }
        return error.HostNpcReplicationCapacityReached;
    }

    fn unregisterHostNpc(
        self: *AuthorityCore,
        persistent: engine.PersistentId,
    ) void {
        const index = self.findNpcByPersistent(persistent) orelse return;
        const generation = self.npcs[index].generation;
        self.npcs[index] = .{ .generation = generation };
    }

    fn findParticipantByCharacter(
        self: *const AuthorityCore,
        character: engine.PersistentId,
    ) ?usize {
        for (self.participants, 0..) |participant, index| {
            if (participant.active and participant.character != null and
                std.meta.eql(participant.character.?, character)) return index;
        }
        return null;
    }

    fn admissionNonceUsed(self: *const AuthorityCore, nonce: u64) bool {
        const now_unix_seconds = self.admission_time_unix_seconds;
        for (self.used_admission_nonces) |used| {
            if (used.nonce == nonce and
                used.expires_at_unix_seconds >= now_unix_seconds) return true;
        }
        return false;
    }

    fn authorizationValid(
        self: *const AuthorityCore,
        hello: protocol.Hello,
        external_identity: protocol.ExternalIdentity,
        reconnecting: bool,
    ) bool {
        const room = self.options.room_admission orelse
            return !hello.join_authorization.isPresent();
        const authorization = hello.join_authorization;
        if (authorization.room_id != room.room_id or
            authorization.authority_id != room.authority_id or
            authorization.room_generation != room.room_generation or
            !protocol.verifyJoinAuthorization(
                room.secret,
                hello.account,
                external_identity,
                authorization,
            ))
        {
            return false;
        }
        // A reconnect presents the already verified room authorization plus a
        // rotating authority credential. It does not consume the ticket nonce
        // again or depend on the room service extending the original expiry.
        return reconnecting or
            (authorization.expires_at_unix_seconds >= self.admission_time_unix_seconds and
                !self.admissionNonceUsed(authorization.nonce));
    }

    fn availableAdmissionNonceSlot(self: *const AuthorityCore) ?usize {
        const now_unix_seconds = self.admission_time_unix_seconds;
        for (self.used_admission_nonces, 0..) |used, index| {
            if (used.nonce == 0 or used.expires_at_unix_seconds < now_unix_seconds) {
                return index;
            }
        }
        return null;
    }

    fn commitAdmissionNonce(
        self: *AuthorityCore,
        slot: usize,
        authorization: protocol.JoinAuthorization,
    ) void {
        std.debug.assert(slot < self.used_admission_nonces.len);
        const previous = self.used_admission_nonces[slot];
        std.debug.assert(previous.nonce == 0 or
            previous.expires_at_unix_seconds < self.admission_time_unix_seconds);
        self.used_admission_nonces[slot] = .{
            .nonce = authorization.nonce,
            .expires_at_unix_seconds = authorization.expires_at_unix_seconds,
        };
    }

    fn issueReconnectCredential(
        self: *AuthorityCore,
        account: identity.AccountId,
        external_identity: protocol.ExternalIdentity,
        participant: identity.ParticipantId,
    ) !identity.ReconnectToken {
        for (0..8) |_| {
            const credential = try self.credential_issuer.issueReconnect(
                self.session,
                account,
                external_identity,
                participant,
            );
            if (credential.isValid() and !self.reconnectCredentialAssigned(credential)) {
                return credential;
            }
        }
        return error.CredentialIssuerCollision;
    }

    fn reconnectCredentialAssigned(
        self: *const AuthorityCore,
        credential: identity.ReconnectToken,
    ) bool {
        for (self.participants) |participant| {
            if (participant.active and
                (reconnectCredentialsEqual(participant.reconnect, credential) or
                    (participant.reconnect_confirmation_pending and
                        reconnectCredentialsEqual(participant.retained_reconnect, credential))))
            {
                return true;
            }
        }
        return false;
    }
};

fn dedicatedCoreConfig() CoreConfig {
    return .{
        .simulation = .{
            .namespace = 0x4d50_3201,
            .fixed_delta_seconds = 1.0 /
                @as(f32, @floatFromInt(budgets.authority_tick_hz)),
            .create_ground = true,
            .character = .{ .max_characters = budgets.max_participants },
            .vehicle = .{
                .max_vehicles = budgets.max_vehicles,
                .max_entry_distance = 5,
            },
        },
        .world_bootstrap = .dedicated_fixture,
        .participant_spawn = .automatic,
        .observation = .disabled,
    };
}

fn createAuthorityCore(
    allocator: std.mem.Allocator,
    core_config: CoreConfig,
    options: Options,
    test_credential_secret: ?[32]u8,
    comptime diagnostic_fault_probe: bool,
) !*AuthorityCore {
    const core = try allocator.create(AuthorityCore);
    errdefer allocator.destroy(core);
    core.* = try AuthorityCore.init(
        allocator,
        core_config,
        options,
        test_credential_secret,
        diagnostic_fault_probe,
    );
    return core;
}

fn destroyAuthorityCore(core: *AuthorityCore) void {
    const allocator = core.allocator;
    core.deinit();
    allocator.destroy(core);
}

/// Narrow transport-neutral authority surface owned by a dedicated host.
///
/// Network adapters own sockets, byte delivery, and connection callbacks. This
/// façade owns the authoritative session behavior and exposes no Simulation,
/// feature command, persistence, editor, or presentation capability.
pub const DedicatedAuthority = opaque {
    fn state(self: *DedicatedAuthority) *AuthorityCore {
        return @ptrCast(@alignCast(self));
    }

    fn stateConst(self: *const DedicatedAuthority) *const AuthorityCore {
        return @ptrCast(@alignCast(self));
    }

    pub fn init(allocator: std.mem.Allocator) !*DedicatedAuthority {
        return initWithOptions(allocator, .{});
    }

    pub fn initWithOptions(
        allocator: std.mem.Allocator,
        options: Options,
    ) !*DedicatedAuthority {
        return @ptrCast(try createAuthorityCore(
            allocator,
            dedicatedCoreConfig(),
            options,
            null,
            false,
        ));
    }

    pub fn deinit(self: *DedicatedAuthority) void {
        destroyAuthorityCore(self.state());
    }

    pub fn openConnection(
        self: *DedicatedAuthority,
        transport: TransportConnection,
    ) !identity.ConnectionId {
        return self.state().openConnection(transport);
    }

    pub fn transportClosed(
        self: *DedicatedAuthority,
        transport: TransportConnection,
    ) void {
        self.state().transportClosed(transport);
    }

    pub fn ingestBytes(
        self: *DedicatedAuthority,
        transport: TransportConnection,
        bytes: []const u8,
    ) !void {
        try self.state().ingestBytes(transport, bytes);
    }

    pub fn ingest(
        self: *DedicatedAuthority,
        transport: TransportConnection,
        message: protocol.ClientMessage,
    ) !void {
        try self.state().ingest(transport, message);
    }

    pub fn ingestAtUnixTime(
        self: *DedicatedAuthority,
        transport: TransportConnection,
        message: protocol.ClientMessage,
        now_unix_seconds: u64,
    ) !void {
        try self.state().ingestAtUnixTime(transport, message, now_unix_seconds);
    }

    pub fn tick(self: *DedicatedAuthority) !void {
        try self.state().tick();
    }

    pub fn pollOutbound(self: *DedicatedAuthority) ?Outbound {
        return self.state().pollOutbound();
    }

    pub fn stop(self: *DedicatedAuthority) !void {
        try self.state().stop();
    }

    pub fn copyAcceptedIngress(
        self: *const DedicatedAuthority,
        output: []AcceptedIngress,
    ) usize {
        return self.stateConst().copyAcceptedIngress(output);
    }

    pub fn rejectOversized(
        self: *DedicatedAuthority,
        transport: TransportConnection,
    ) !void {
        try self.state().rejectOversized(transport);
    }

    pub fn updateAdmissionTime(
        self: *DedicatedAuthority,
        now_unix_seconds: u64,
    ) !void {
        try self.state().updateAdmissionTime(now_unix_seconds);
    }

    pub fn diagnostics(
        self: *const DedicatedAuthority,
    ) authority_diagnostics.Diagnostics {
        return self.stateConst().diagnostics();
    }
};

fn authorityCore(context: *anyopaque) *AuthorityCore {
    return @ptrCast(@alignCast(context));
}

fn authorityCoreConst(context: *const anyopaque) *const AuthorityCore {
    return @ptrCast(@alignCast(context));
}

/// Embedded placement handle. It owns the same concrete core as the dedicated
/// façade while exposing host-only work through separate, type-erased roles.
pub const EmbeddedAuthority = opaque {
    pub fn init(
        allocator: std.mem.Allocator,
        core_config: CoreConfig,
    ) !*EmbeddedAuthority {
        return initWithOptions(allocator, core_config, .{});
    }

    pub fn initWithOptions(
        allocator: std.mem.Allocator,
        core_config: CoreConfig,
        options: Options,
    ) !*EmbeddedAuthority {
        return @ptrCast(try createAuthorityCore(
            allocator,
            core_config,
            options,
            null,
            false,
        ));
    }

    /// Validation-only constructor. Keeping the probe in an explicit
    /// compile-time lane prevents its system and error markers from becoming
    /// reachable in the operational embedded product.
    pub fn initWithDiagnosticFaultProbe(
        allocator: std.mem.Allocator,
        core_config: CoreConfig,
    ) !*EmbeddedAuthority {
        return @ptrCast(try createAuthorityCore(
            allocator,
            core_config,
            .{},
            null,
            true,
        ));
    }

    pub fn deinit(self: *EmbeddedAuthority) void {
        destroyAuthorityCore(embeddedAuthorityCore(self));
    }

    pub fn session(self: *EmbeddedAuthority) EmbeddedSessionRole {
        return .{ .context = embeddedAuthorityCore(self) };
    }

    pub fn crates(self: *EmbeddedAuthority) EmbeddedCrateRole {
        return .{ .context = embeddedAuthorityCore(self) };
    }

    pub fn characters(self: *EmbeddedAuthority) EmbeddedCharacterRole {
        return .{ .context = embeddedAuthorityCore(self) };
    }

    pub fn vehicles(self: *EmbeddedAuthority) EmbeddedVehicleRole {
        return .{ .context = embeddedAuthorityCore(self) };
    }

    pub fn districts(self: *EmbeddedAuthority) EmbeddedDistrictRole {
        return .{ .context = embeddedAuthorityCore(self) };
    }

    pub fn interactions(self: *EmbeddedAuthority) EmbeddedInteractionRole {
        return .{ .context = embeddedAuthorityCore(self) };
    }

    pub fn npcs(self: *EmbeddedAuthority) EmbeddedNpcRole {
        return .{ .context = embeddedAuthorityCore(self) };
    }

    pub fn developer(self: *EmbeddedAuthority) EmbeddedDeveloperRole {
        return .{ .context = embeddedAuthorityCore(self) };
    }

    pub fn persistence(self: *EmbeddedAuthority) EmbeddedPersistenceRole {
        return .{ .context = embeddedAuthorityCore(self) };
    }

    pub fn inspection(self: *const EmbeddedAuthority) EmbeddedInspectionRole {
        return .{ .context = embeddedAuthorityCoreConst(self) };
    }

    pub fn residency(self: *EmbeddedAuthority) EmbeddedResidencyRole {
        return .{ .context = embeddedAuthorityCore(self) };
    }
};

fn embeddedAuthorityCore(authority: *EmbeddedAuthority) *AuthorityCore {
    return @ptrCast(@alignCast(authority));
}

fn embeddedAuthorityCoreConst(authority: *const EmbeddedAuthority) *const AuthorityCore {
    return @ptrCast(@alignCast(authority));
}

pub const EmbeddedSessionRole = struct {
    context: *anyopaque,

    pub fn openConnection(
        self: EmbeddedSessionRole,
        transport: TransportConnection,
    ) !identity.ConnectionId {
        return authorityCore(self.context).openConnection(transport);
    }

    pub fn transportClosed(
        self: EmbeddedSessionRole,
        transport: TransportConnection,
    ) void {
        authorityCore(self.context).transportClosed(transport);
    }

    pub fn ingest(
        self: EmbeddedSessionRole,
        transport: TransportConnection,
        message: protocol.ClientMessage,
    ) !void {
        try authorityCore(self.context).ingest(transport, message);
    }

    pub fn ingestAtUnixTime(
        self: EmbeddedSessionRole,
        transport: TransportConnection,
        message: protocol.ClientMessage,
        now_unix_seconds: u64,
    ) !void {
        try authorityCore(self.context).ingestAtUnixTime(
            transport,
            message,
            now_unix_seconds,
        );
    }

    pub fn tick(self: EmbeddedSessionRole) !void {
        try authorityCore(self.context).tick();
    }

    pub fn tickObserved(
        self: EmbeddedSessionRole,
        observer: ?engine.PhaseObserver,
    ) !void {
        try authorityCore(self.context).tickObserved(observer);
    }

    pub fn pollOutbound(self: EmbeddedSessionRole) ?Outbound {
        return authorityCore(self.context).pollOutbound();
    }

    pub fn stop(self: EmbeddedSessionRole) !void {
        try authorityCore(self.context).stop();
    }

    pub fn copyAcceptedIngress(
        self: EmbeddedSessionRole,
        output: []AcceptedIngress,
    ) usize {
        return authorityCoreConst(self.context).copyAcceptedIngress(output);
    }

    pub fn diagnostics(
        self: EmbeddedSessionRole,
    ) authority_diagnostics.Diagnostics {
        return authorityCoreConst(self.context).diagnostics();
    }
};

pub const EmbeddedCrateRole = struct {
    context: *anyopaque,

    pub fn submit(self: EmbeddedCrateRole, command: crate_contract.Command) !void {
        try authorityCore(self.context).submitHostCrate(command);
    }

    pub fn pollOutcome(self: EmbeddedCrateRole) ?crate_contract.Outcome {
        return authorityCore(self.context).observations.crate_outcomes.pop();
    }

    pub fn presentation(
        self: EmbeddedCrateRole,
        alpha: f32,
    ) ![]const crate_contract.CrateDraw {
        return authorityCore(self.context).simulation.presentation(alpha);
    }

    pub fn view(
        self: EmbeddedCrateRole,
        id: engine.PersistentId,
    ) !crate_contract.CrateView {
        return authorityCore(self.context).simulation.crate(id);
    }

    pub fn count(self: EmbeddedCrateRole) usize {
        return authorityCoreConst(self.context).simulation.crateCount();
    }
};

pub const EmbeddedCharacterRole = struct {
    context: *anyopaque,

    pub fn spawnParticipant(
        self: EmbeddedCharacterRole,
        transport: TransportConnection,
        spawn: character_contract.SpawnCharacter,
    ) !void {
        try authorityCore(self.context).spawnHostParticipantCharacter(transport, spawn);
    }

    pub fn despawnParticipant(
        self: EmbeddedCharacterRole,
        transport: TransportConnection,
        id: engine.PersistentId,
    ) !void {
        try authorityCore(self.context).despawnHostParticipantCharacter(transport, id);
    }

    pub fn pollOutcome(self: EmbeddedCharacterRole) ?character_contract.Outcome {
        return authorityCore(self.context).observations.character_outcomes.pop();
    }

    pub fn pollEvent(self: EmbeddedCharacterRole) ?character_contract.Event {
        return authorityCore(self.context).observations.character_events.pop();
    }

    pub fn view(
        self: EmbeddedCharacterRole,
        id: engine.PersistentId,
    ) !character_contract.CharacterView {
        return authorityCore(self.context).simulation.character(id);
    }

    pub fn count(self: EmbeddedCharacterRole) usize {
        return authorityCoreConst(self.context).simulation.characterCount();
    }
};

pub const EmbeddedVehicleRole = struct {
    context: *anyopaque,

    pub fn submit(self: EmbeddedVehicleRole, command: vehicle_contract.Command) !void {
        try authorityCore(self.context).submitHostVehicle(command);
    }

    pub fn pollOutcome(self: EmbeddedVehicleRole) ?vehicle_contract.Outcome {
        return authorityCore(self.context).observations.vehicle_outcomes.pop();
    }

    pub fn pollEvent(self: EmbeddedVehicleRole) ?vehicle_contract.Event {
        return authorityCore(self.context).observations.vehicle_events.pop();
    }

    pub fn presentation(
        self: EmbeddedVehicleRole,
        alpha: f32,
    ) ![]const vehicle_contract.VehicleDraw {
        return authorityCore(self.context).simulation.vehiclePresentation(alpha);
    }

    pub fn view(
        self: EmbeddedVehicleRole,
        id: engine.PersistentId,
    ) !vehicle_contract.VehicleView {
        return authorityCore(self.context).simulation.vehicle(id);
    }

    pub fn count(self: EmbeddedVehicleRole) usize {
        return authorityCoreConst(self.context).simulation.vehicleCount();
    }
};

pub const EmbeddedDistrictRole = struct {
    context: *anyopaque,

    pub fn submit(self: EmbeddedDistrictRole, command: district_feature_contract.Command) !void {
        try authorityCore(self.context).submitHostDistrict(command);
    }

    pub fn pollOutcome(self: EmbeddedDistrictRole) ?district_feature_contract.Outcome {
        return authorityCore(self.context).observations.district_outcomes.pop();
    }

    pub fn pollEvent(self: EmbeddedDistrictRole) ?district_feature_contract.Event {
        return authorityCore(self.context).observations.district_events.pop();
    }

    pub fn presentation(self: EmbeddedDistrictRole) ![]const district_feature_contract.DistrictDraw {
        return authorityCore(self.context).simulation.districtPresentation();
    }

    pub fn count(self: EmbeddedDistrictRole) usize {
        return authorityCoreConst(self.context).simulation.districtCount();
    }

    pub fn bodyCount(self: EmbeddedDistrictRole) usize {
        return authorityCoreConst(self.context).simulation.districtBodyCount();
    }

    pub fn activeTicket(
        self: EmbeddedDistrictRole,
        coord: district_contract.ChunkCoord,
    ) ?district_contract.LoadTicket {
        return authorityCoreConst(self.context).simulation.activeDistrictTicketFor(coord);
    }

    pub fn state(
        self: EmbeddedDistrictRole,
        coord: district_contract.ChunkCoord,
    ) ?district_feature_contract.StateTag {
        return authorityCoreConst(self.context).simulation.districtStateFor(coord);
    }
};

pub const EmbeddedInteractionRole = struct {
    context: *anyopaque,

    pub fn submit(
        self: EmbeddedInteractionRole,
        command: interaction_feature_contract.Command,
    ) !void {
        try authorityCore(self.context).submitHostInteraction(command);
    }

    pub fn pollOutcome(self: EmbeddedInteractionRole) ?interaction_feature_contract.Outcome {
        return authorityCore(self.context).observations.interaction_outcomes.pop();
    }

    pub fn presentation(self: EmbeddedInteractionRole) ![]const interaction_feature_contract.CarryableDraw {
        return authorityCore(self.context).simulation.interactionPresentation();
    }

    pub fn view(
        self: EmbeddedInteractionRole,
        id: engine.PersistentId,
    ) !interaction_feature_contract.CarryableView {
        return authorityCore(self.context).simulation.carryable(id);
    }

    pub fn count(self: EmbeddedInteractionRole) usize {
        return authorityCoreConst(self.context).simulation.interactionCount();
    }
};

pub const EmbeddedNpcRole = struct {
    context: *anyopaque,

    pub fn submit(self: EmbeddedNpcRole, command: npc_contract.Command) !void {
        try authorityCore(self.context).submitHostNpc(command);
    }

    pub fn pollOutcome(self: EmbeddedNpcRole) ?npc_contract.Outcome {
        return authorityCore(self.context).observations.npc_outcomes.pop();
    }

    pub fn pollEvent(self: EmbeddedNpcRole) ?npc_contract.Event {
        return authorityCore(self.context).observations.npc_events.pop();
    }

    pub fn presentation(
        self: EmbeddedNpcRole,
        alpha: f32,
    ) ![]const npc_contract.NpcDraw {
        return authorityCore(self.context).simulation.npcPresentation(alpha);
    }

    pub fn view(
        self: EmbeddedNpcRole,
        id: engine.PersistentId,
    ) !npc_contract.NpcView {
        return authorityCore(self.context).simulation.npc(id);
    }

    pub fn count(self: EmbeddedNpcRole) usize {
        return authorityCoreConst(self.context).simulation.npcCount();
    }
};

pub const EmbeddedDeveloperRole = struct {
    context: *anyopaque,

    pub fn diagnostics(self: EmbeddedDeveloperRole) sandbox_diagnostics_contract.Diagnostics {
        return authorityCore(self.context).simulation.diagnostics();
    }

    pub fn record(
        self: EmbeddedDeveloperRole,
        entry: engine.runtime.DiagnosticEntry,
    ) engine.runtime.DiagnosticAppendResult {
        return authorityCore(self.context).simulation.recordDiagnostic(entry);
    }

    pub fn armFaultProbe(self: EmbeddedDeveloperRole) !void {
        try authorityCore(self.context).simulation.armDiagnosticFaultProbe();
    }

    pub fn armFreeze(
        self: EmbeddedDeveloperRole,
        condition: engine.runtime.DiagnosticFreezeMatch,
    ) void {
        authorityCore(self.context).simulation.armDiagnosticFreeze(condition);
    }

    pub fn disarmFreeze(self: EmbeddedDeveloperRole) bool {
        return authorityCore(self.context).simulation.disarmDiagnosticFreeze();
    }

    pub fn journal(
        self: EmbeddedDeveloperRole,
    ) *const engine.runtime.DiagnosticJournal {
        return authorityCoreConst(self.context).simulation.diagnosticJournal();
    }

    pub fn firstFault(self: EmbeddedDeveloperRole) ?engine.runtime.RuntimeFault {
        return authorityCoreConst(self.context).simulation.firstFault();
    }

    pub fn resumeCapture(self: EmbeddedDeveloperRole) bool {
        return authorityCore(self.context).simulation.resumeDiagnosticCapture();
    }

    pub fn clear(self: EmbeddedDeveloperRole) void {
        authorityCore(self.context).simulation.clearDiagnostics();
    }

    pub fn extractPhysicsDebug(
        self: EmbeddedDeveloperRole,
        config: engine.physics_debug.Config,
        storage: *engine.physics_debug.Storage,
    ) !engine.physics_debug.Batch {
        return authorityCore(self.context).simulation.extractPhysicsDebug(config, storage);
    }
};

pub const EmbeddedPersistenceRole = struct {
    context: *anyopaque,

    /// Transfers the sole canonical-byte source to the durable owner. The
    /// embedded authority must remain alive and at a quiescent safe point for
    /// every capture.
    pub fn issueSource(self: EmbeddedPersistenceRole) !snapshot_source.Source {
        return authorityCore(self.context).issueSnapshotSource();
    }
};

/// Privileged host-only read capability for canonical logical residency.
/// Client prediction and presentation remain on the separate local player
/// role; this role returns only a copied authority value.
pub const EmbeddedResidencyRole = struct {
    context: *anyopaque,

    pub fn authoritativeFocusPosition(
        self: EmbeddedResidencyRole,
        participant: identity.ParticipantId,
    ) !?[3]f32 {
        return authorityCore(self.context).authoritativeFocusPosition(
            participant,
        );
    }
};

pub const EmbeddedInspectionRole = struct {
    context: *const anyopaque,

    pub fn tickIndex(self: EmbeddedInspectionRole) u64 {
        return authorityCoreConst(self.context).simulation.tickIndex();
    }

    pub fn entityCount(self: EmbeddedInspectionRole) usize {
        return authorityCoreConst(self.context).simulation.entityCount();
    }

    pub fn bodyCount(self: EmbeddedInspectionRole) u32 {
        return authorityCoreConst(self.context).simulation.bodyCount();
    }

    pub fn persistenceCohort(self: EmbeddedInspectionRole) PersistenceCohort {
        return authorityCoreConst(self.context).persistence_cohort;
    }

    /// Returns the durable feature identity for an exact active replicated
    /// entity generation. Stale, pending, and unknown identities do not
    /// resolve.
    pub fn persistentId(
        self: EmbeddedInspectionRole,
        entity: identity.ReplicatedEntityId,
    ) ?engine.PersistentId {
        return authorityCoreConst(self.context).persistentId(entity);
    }

    /// Returns the exact active replicated generation for a durable feature
    /// identity. This host-validation capability is not a presentation API.
    pub fn replicatedId(
        self: EmbeddedInspectionRole,
        persistent: engine.PersistentId,
    ) ?identity.ReplicatedEntityId {
        return authorityCoreConst(self.context).replicatedId(persistent);
    }

    pub fn observationDiagnostics(
        self: EmbeddedInspectionRole,
    ) HostObservationDiagnostics {
        const observations = authorityCoreConst(self.context).observations;
        return .{
            .pending_records = observations.pending(),
            .records_dropped = observations.records_dropped,
        };
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

fn districtCoord(value: district_contract.ChunkCoord) protocol.DistrictCoord {
    return .{ .x = value.x, .z = value.z };
}

fn authorityDistrictIndex(coord: district_contract.ChunkCoord) ?usize {
    if (std.meta.eql(coord, sandbox_district_recipe.navigation_west_coord)) return 0;
    if (std.meta.eql(coord, sandbox_district_recipe.navigation_east_coord)) return 1;
    return null;
}

fn insideDistrictHysteresis(position: [3]f32, coord: district_contract.ChunkCoord) bool {
    const center_x = @as(f32, @floatFromInt(coord.x)) * district_contract.chunk_span;
    const center_z = @as(f32, @floatFromInt(coord.z)) * district_contract.chunk_span;
    const inner_half_span = district_contract.chunk_half_span - 1.0;
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

fn districtBootstrapCoord(index: usize) district_contract.ChunkCoord {
    return switch (index) {
        0 => sandbox_district_recipe.navigation_west_coord,
        1 => sandbox_district_recipe.navigation_east_coord,
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

fn isReservedInteractionTransaction(value: u64) bool {
    const authority_domain = value & 0xf000_0000_0000_0000;
    return authority_domain == 0xc000_0000_0000_0000 or
        authority_domain == 0xd000_0000_0000_0000;
}

fn vehicleRejectionDisposition(
    reason: @FieldType(vehicle_contract.CommandRejected, "reason"),
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

fn testEmbeddedCoreConfig(
    namespace: u64,
    participant_spawn: ParticipantSpawn,
) CoreConfig {
    return .{
        .simulation = .{
            .namespace = namespace,
            .fixed_delta_seconds = 1.0 /
                @as(f32, @floatFromInt(budgets.authority_tick_hz)),
            .create_ground = true,
            .character = .{ .max_characters = budgets.max_participants },
            .vehicle = .{ .max_vehicles = budgets.max_vehicles },
        },
        .world_bootstrap = .host_managed,
        .participant_spawn = participant_spawn,
        .observation = .bounded,
    };
}

fn initTestEmbeddedAuthority(
    core_config: CoreConfig,
    options: Options,
    credential_secret_byte: u8,
) !*EmbeddedAuthority {
    return @ptrCast(try createAuthorityCore(
        std.testing.allocator,
        core_config,
        options,
        @splat(credential_secret_byte),
        false,
    ));
}

fn testRoomAuthorization(
    secret: protocol.AdmissionSecret,
    account: identity.AccountId,
    external_identity: protocol.ExternalIdentity,
    nonce: u64,
    expires_at_unix_seconds: u64,
) protocol.JoinAuthorization {
    var authorization = protocol.JoinAuthorization{
        .room_id = 71,
        .authority_id = 9_001,
        .room_generation = 3,
        .nonce = nonce,
        .expires_at_unix_seconds = expires_at_unix_seconds,
    };
    protocol.signJoinAuthorization(
        secret,
        account,
        external_identity,
        &authorization,
    );
    return authorization;
}

fn legacyReconnectGuess(
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

test "authority placement facades expose opaque role-scoped state" {
    try std.testing.expect(switch (@typeInfo(DedicatedAuthority)) {
        .@"opaque" => true,
        else => false,
    });
    try std.testing.expect(!@hasDecl(DedicatedAuthority, "submitCharacter"));
    try std.testing.expect(!@hasDecl(DedicatedAuthority, "save"));
    try std.testing.expect(switch (@typeInfo(EmbeddedAuthority)) {
        .@"opaque" => true,
        else => false,
    });
    try std.testing.expect(!@hasDecl(EmbeddedAuthority, "submitCharacter"));
    try std.testing.expect(!@hasDecl(EmbeddedAuthority, "save"));
    try std.testing.expect(!@hasDecl(EmbeddedCharacterRole, "submit"));
    inline for (.{
        EmbeddedSessionRole,
        EmbeddedCrateRole,
        EmbeddedCharacterRole,
        EmbeddedVehicleRole,
        EmbeddedDistrictRole,
        EmbeddedInteractionRole,
        EmbeddedNpcRole,
        EmbeddedDeveloperRole,
        EmbeddedPersistenceRole,
        EmbeddedResidencyRole,
        EmbeddedInspectionRole,
    }) |Role| {
        try std.testing.expect(!@hasField(Role, "core"));
        try std.testing.expect(!@hasField(Role, "simulation"));
    }
}

test "authority issues bound one-time reconnect credentials and unique sessions" {
    const first = try initTestEmbeddedAuthority(
        testEmbeddedCoreConfig(0x454d_4401, .host_managed),
        .{},
        0x11,
    );
    var first_live = true;
    defer if (first_live) first.deinit();

    const account = identity.AccountId{ .value = 41 };
    const external_identity = protocol.ExternalIdentity{ .provider = .steam, .subject = 7001 };
    const initial_transport = TransportConnection{ .value = 1 };
    _ = try first.session().openConnection(initial_transport);
    try first.session().ingest(initial_transport, .{ .hello = .{
        .account = account,
        .external_identity = external_identity,
    } });
    const initial = first.session().pollOutbound().?.message.welcome;
    try std.testing.expect(initial.reconnect.isValid());
    try std.testing.expect(!reconnectCredentialsEqual(
        initial.reconnect,
        legacyReconnectGuess(initial.session, account, initial.participant),
    ));

    const other_account = identity.AccountId{ .value = 42 };
    _ = try first.session().openConnection(.{ .value = 2 });
    try first.session().ingest(.{ .value = 2 }, .{ .hello = .{ .account = other_account } });
    const other = first.session().pollOutbound().?.message.welcome;
    try std.testing.expect(!reconnectCredentialsEqual(initial.reconnect, other.reconnect));

    first.session().transportClosed(initial_transport);

    // Possession of a valid credential does not authorize a different account
    // or external platform identity.
    _ = try first.session().openConnection(.{ .value = 4 });
    try first.session().ingest(.{ .value = 4 }, .{ .hello = .{
        .account = account,
        .external_identity = .{ .provider = .steam, .subject = 7002 },
        .reconnect = initial.reconnect,
    } });
    try std.testing.expectEqual(
        protocol.RejectionReason.reconnect_expired,
        first.session().pollOutbound().?.message.rejected.reason,
    );

    _ = try first.session().openConnection(.{ .value = 5 });
    try first.session().ingest(.{ .value = 5 }, .{ .hello = .{
        .account = account,
        .external_identity = external_identity,
        .reconnect = legacyReconnectGuess(initial.session, account, initial.participant),
    } });
    try std.testing.expectEqual(
        protocol.RejectionReason.reconnect_expired,
        first.session().pollOutbound().?.message.rejected.reason,
    );

    _ = try first.session().openConnection(.{ .value = 6 });
    try first.session().ingest(.{ .value = 6 }, .{ .hello = .{
        .account = account,
        .external_identity = external_identity,
        .reconnect = initial.reconnect,
    } });
    const rotated = first.session().pollOutbound().?.message.welcome;
    try std.testing.expectEqual(initial.participant, rotated.participant);
    try std.testing.expect(!reconnectCredentialsEqual(initial.reconnect, rotated.reconnect));

    try first.session().tick();
    var reconnect_baseline: ?protocol.RelevanceBaseline = null;
    while (first.session().pollOutbound()) |outbound| {
        if (outbound.connection.value == 6 and outbound.message == .relevance_baseline) {
            reconnect_baseline = outbound.message.relevance_baseline;
        }
    }
    const confirmed_baseline = reconnect_baseline orelse
        return error.MissingReconnectConfirmationBaseline;
    try first.session().ingest(.{ .value = 6 }, .{ .baseline_ack = .{
        .session = rotated.session,
        .participant = rotated.participant,
        .baseline_id = confirmed_baseline.baseline_id,
    } });

    first.session().transportClosed(.{ .value = 6 });
    _ = try first.session().openConnection(.{ .value = 7 });
    try first.session().ingest(.{ .value = 7 }, .{ .hello = .{
        .account = account,
        .external_identity = external_identity,
        .reconnect = initial.reconnect,
    } });
    try std.testing.expectEqual(
        protocol.RejectionReason.reconnect_expired,
        first.session().pollOutbound().?.message.rejected.reason,
    );

    _ = try first.session().openConnection(.{ .value = 8 });
    try first.session().ingest(.{ .value = 8 }, .{ .hello = .{
        .account = account,
        .external_identity = external_identity,
        .reconnect = rotated.reconnect,
    } });
    const rotated_again = first.session().pollOutbound().?.message.welcome;
    try std.testing.expectEqual(initial.participant, rotated_again.participant);
    try std.testing.expect(!reconnectCredentialsEqual(rotated.reconnect, rotated_again.reconnect));

    const first_session = initial.session;
    first.deinit();
    first_live = false;
    const second = try initTestEmbeddedAuthority(
        testEmbeddedCoreConfig(0x454d_4402, .host_managed),
        .{},
        0x22,
    );
    defer second.deinit();
    _ = try second.session().openConnection(.{ .value = 3 });
    try second.session().ingest(.{ .value = 3 }, .{ .hello = .{ .account = account } });
    const other_session = second.session().pollOutbound().?.message.welcome;
    try std.testing.expect(first_session.value != other_session.session.value);
}

test "reconnect retains one presented credential until Welcome is confirmed" {
    const authority = try initTestEmbeddedAuthority(
        testEmbeddedCoreConfig(0x454d_4407, .host_managed),
        .{},
        0x66,
    );
    defer authority.deinit();
    const core = embeddedAuthorityCore(authority);
    const account = identity.AccountId{ .value = 81 };

    _ = try authority.session().openConnection(.{ .value = 1 });
    try authority.session().ingest(.{ .value = 1 }, .{ .hello = .{ .account = account } });
    const initial = authority.session().pollOutbound().?.message.welcome;
    authority.session().transportClosed(.{ .value = 1 });

    // The first rotated Welcome is lost. The client can still retry with the
    // credential it actually possesses.
    _ = try authority.session().openConnection(.{ .value = 2 });
    try authority.session().ingest(.{ .value = 2 }, .{ .hello = .{
        .account = account,
        .reconnect = initial.reconnect,
    } });
    const first_rotation = authority.session().pollOutbound().?.message.welcome;
    authority.session().transportClosed(.{ .value = 2 });

    _ = try authority.session().openConnection(.{ .value = 3 });
    try authority.session().ingest(.{ .value = 3 }, .{ .hello = .{
        .account = account,
        .reconnect = initial.reconnect,
    } });
    const second_rotation = authority.session().pollOutbound().?.message.welcome;
    try std.testing.expect(!reconnectCredentialsEqual(
        first_rotation.reconnect,
        second_rotation.reconnect,
    ));
    authority.session().transportClosed(.{ .value = 3 });

    // A client that did receive the latest Welcome can also reconnect with
    // the current credential. Only that presented value is retained.
    _ = try authority.session().openConnection(.{ .value = 4 });
    try authority.session().ingest(.{ .value = 4 }, .{ .hello = .{
        .account = account,
        .reconnect = second_rotation.reconnect,
    } });
    _ = authority.session().pollOutbound().?.message.welcome;
    authority.session().transportClosed(.{ .value = 4 });
    const participant_index = @as(usize, initial.participant.index) - 1;
    try std.testing.expect(core.participants[participant_index].reconnect_confirmation_pending);
    try std.testing.expect(reconnectCredentialsEqual(
        core.participants[participant_index].retained_reconnect,
        second_rotation.reconnect,
    ));

    _ = try authority.session().openConnection(.{ .value = 5 });
    try authority.session().ingest(.{ .value = 5 }, .{ .hello = .{
        .account = account,
        .reconnect = initial.reconnect,
    } });
    try std.testing.expectEqual(
        protocol.RejectionReason.reconnect_expired,
        authority.session().pollOutbound().?.message.rejected.reason,
    );

    // The one retained credential remains a recovery path until a valid
    // post-Hello baseline acknowledgement confirms delivery.
    _ = try authority.session().openConnection(.{ .value = 6 });
    try authority.session().ingest(.{ .value = 6 }, .{ .hello = .{
        .account = account,
        .reconnect = second_rotation.reconnect,
    } });
    const confirmed_rotation = authority.session().pollOutbound().?.message.welcome;
    try authority.session().tick();
    var baseline: ?protocol.RelevanceBaseline = null;
    while (authority.session().pollOutbound()) |outbound| {
        if (outbound.connection.value == 6 and outbound.message == .relevance_baseline) {
            baseline = outbound.message.relevance_baseline;
        }
    }
    const confirmation = baseline orelse return error.MissingReconnectRecoveryBaseline;
    try authority.session().ingest(.{ .value = 6 }, .{ .baseline_ack = .{
        .session = confirmed_rotation.session,
        .participant = confirmed_rotation.participant,
        .baseline_id = confirmation.baseline_id,
    } });
    try std.testing.expect(!core.participants[participant_index].reconnect_confirmation_pending);
    try std.testing.expect(!core.participants[participant_index].retained_reconnect.isValid());
    authority.session().transportClosed(.{ .value = 6 });

    _ = try authority.session().openConnection(.{ .value = 7 });
    try authority.session().ingest(.{ .value = 7 }, .{ .hello = .{
        .account = account,
        .reconnect = second_rotation.reconnect,
    } });
    try std.testing.expectEqual(
        protocol.RejectionReason.reconnect_expired,
        authority.session().pollOutbound().?.message.rejected.reason,
    );
}

test "failed reconnect Welcome queueing rolls credential rotation back atomically" {
    const authority = try initTestEmbeddedAuthority(
        testEmbeddedCoreConfig(0x454d_4408, .host_managed),
        .{},
        0x77,
    );
    defer authority.deinit();
    const core = embeddedAuthorityCore(authority);
    const account = identity.AccountId{ .value = 91 };
    const reconnect_transport = TransportConnection{ .value = 2 };

    _ = try authority.session().openConnection(.{ .value = 1 });
    try authority.session().ingest(.{ .value = 1 }, .{ .hello = .{ .account = account } });
    const initial = authority.session().pollOutbound().?.message.welcome;
    authority.session().transportClosed(.{ .value = 1 });
    _ = try authority.session().openConnection(reconnect_transport);
    const participant_index = @as(usize, initial.participant.index) - 1;
    const connection_index = core.findConnection(reconnect_transport) orelse
        return error.MissingReconnectRollbackConnection;
    const participant_before = core.participants[participant_index];
    const event_quota_tick_before = core.connections[connection_index].event_quota_tick;
    const reliable_events_before = core.connections[connection_index].reliable_events_this_tick;
    const max_reliable_events_before = core.max_reliable_events_per_connection_tick;

    for (0..budgets.outbound_message_capacity) |_| {
        try core.outbox.push(.{
            .connection = reconnect_transport,
            .message = .{ .disconnected = .requested },
            .delivery = .reliable,
            .lane = .control,
        });
    }
    try std.testing.expectError(
        error.QueueFull,
        authority.session().ingest(reconnect_transport, .{ .hello = .{
            .account = account,
            .reconnect = initial.reconnect,
        } }),
    );
    try std.testing.expect(reconnectCredentialsEqual(
        participant_before.reconnect,
        core.participants[participant_index].reconnect,
    ));
    try std.testing.expect(reconnectCredentialsEqual(
        participant_before.retained_reconnect,
        core.participants[participant_index].retained_reconnect,
    ));
    try std.testing.expectEqual(
        participant_before.reconnect_confirmation_pending,
        core.participants[participant_index].reconnect_confirmation_pending,
    );
    try std.testing.expect(core.participants[participant_index].connection_index == null);
    try std.testing.expect(core.connections[connection_index].participant_index == null);
    try std.testing.expectEqual(
        event_quota_tick_before,
        core.connections[connection_index].event_quota_tick,
    );
    try std.testing.expectEqual(
        reliable_events_before,
        core.connections[connection_index].reliable_events_this_tick,
    );
    try std.testing.expectEqual(
        max_reliable_events_before,
        core.max_reliable_events_per_connection_tick,
    );

    core.outbox.clear();
    try authority.session().ingest(reconnect_transport, .{ .hello = .{
        .account = account,
        .reconnect = initial.reconnect,
    } });
    const recovered = authority.session().pollOutbound().?.message.welcome;
    try std.testing.expectEqual(initial.participant, recovered.participant);
    try std.testing.expect(!reconnectCredentialsEqual(initial.reconnect, recovered.reconnect));
}

test "room reconnect validates signed identity before rotating its credential" {
    const room_secret: protocol.AdmissionSecret = @splat(0x5a);
    var options = Options{};
    options.room_admission = .{
        .room_id = 71,
        .authority_id = 9_001,
        .room_generation = 3,
        .secret = room_secret,
    };
    const authority = try initTestEmbeddedAuthority(
        testEmbeddedCoreConfig(0x454d_4403, .host_managed),
        options,
        0x33,
    );
    defer authority.deinit();

    const account = identity.AccountId{ .value = 51 };
    const external_identity = protocol.ExternalIdentity{ .provider = .steam, .subject = 8001 };
    const authorization = testRoomAuthorization(
        room_secret,
        account,
        external_identity,
        401,
        20,
    );
    _ = try authority.session().openConnection(.{ .value = 1 });
    try authority.session().ingestAtUnixTime(.{ .value = 1 }, .{ .hello = .{
        .account = account,
        .external_identity = external_identity,
        .join_authorization = authorization,
    } }, 10);
    const initial = authority.session().pollOutbound().?.message.welcome;
    authority.session().transportClosed(.{ .value = 1 });

    // The original ticket cannot be replayed under a different external
    // identity even when the attacker also presents the reconnect token.
    _ = try authority.session().openConnection(.{ .value = 2 });
    try authority.session().ingestAtUnixTime(.{ .value = 2 }, .{ .hello = .{
        .account = account,
        .external_identity = .{ .provider = .steam, .subject = 8002 },
        .join_authorization = authorization,
        .reconnect = initial.reconnect,
    } }, 100);
    try std.testing.expectEqual(
        protocol.RejectionReason.unauthorized,
        authority.session().pollOutbound().?.message.rejected.reason,
    );

    // Reconnect remains independent of a live room service and of extending
    // the consumed ticket; its signature, identity binding, and rotating
    // authority credential still must all match.
    _ = try authority.session().openConnection(.{ .value = 3 });
    try authority.session().ingestAtUnixTime(.{ .value = 3 }, .{ .hello = .{
        .account = account,
        .external_identity = external_identity,
        .join_authorization = authorization,
        .reconnect = initial.reconnect,
    } }, 100);
    const reconnected = authority.session().pollOutbound().?.message.welcome;
    try std.testing.expectEqual(initial.participant, reconnected.participant);
    try std.testing.expect(!reconnectCredentialsEqual(initial.reconnect, reconnected.reconnect));
}

test "authority rejects a room admission configuration with a known zero secret" {
    try std.testing.expectError(
        error.InvalidRoomAdmissionOptions,
        EmbeddedAuthority.initWithOptions(
            std.testing.allocator,
            testEmbeddedCoreConfig(0x454d_4406, .host_managed),
            .{ .room_admission = .{
                .room_id = 71,
                .authority_id = 9_001,
                .room_generation = 3,
                .secret = @splat(0),
            } },
        ),
    );
}

test "faulted authority rejects every operational mutation but preserves shutdown drains" {
    const authority = try initTestEmbeddedAuthority(
        testEmbeddedCoreConfig(0x454d_4404, .host_managed),
        .{},
        0x44,
    );
    defer authority.deinit();
    const core = embeddedAuthorityCore(authority);
    const participant_transport = TransportConnection{ .value = 1 };
    const idle_transport = TransportConnection{ .value = 2 };
    _ = try authority.session().openConnection(participant_transport);
    _ = try authority.session().openConnection(idle_transport);
    try authority.session().ingest(participant_transport, .{ .hello = .{
        .account = .{ .value = 61 },
    } });
    _ = authority.session().pollOutbound().?.message.welcome;
    try std.testing.expectError(
        error.InjectedAuthorityCycleFault,
        core.tickImpl(null, .pre_simulation),
    );

    const diagnostics_before = authority.session().diagnostics();
    const simulation_before = authority.developer().diagnostics();
    const observations_before = authority.inspection().observationDiagnostics();
    const outbox_before = core.outbox.len;
    const admission_time_before = core.admission_time_unix_seconds;
    const source_issued_before = core.snapshot_source_issued;
    const id = engine.PersistentId{ .namespace = 1, .local = 1 };

    try std.testing.expectError(
        error.AuthorityFaulted,
        authority.session().openConnection(.{ .value = 3 }),
    );
    try std.testing.expectError(
        error.AuthorityFaulted,
        authority.session().ingest(participant_transport, .{ .disconnect = .requested }),
    );
    try std.testing.expectError(
        error.AuthorityFaulted,
        authority.session().ingestAtUnixTime(
            participant_transport,
            .{ .disconnect = .requested },
            10,
        ),
    );
    try std.testing.expectError(
        error.AuthorityFaulted,
        core.ingestBytes(participant_transport, &.{}),
    );
    try std.testing.expectError(
        error.AuthorityFaulted,
        core.rejectOversized(participant_transport),
    );
    try std.testing.expectError(error.AuthorityFaulted, core.updateAdmissionTime(10));
    try std.testing.expectError(
        error.AuthorityFaulted,
        authority.characters().spawnParticipant(participant_transport, .{
            .request_id = 1,
            .position = .{ 0, 0, 0 },
        }),
    );
    try std.testing.expectError(
        error.AuthorityFaulted,
        authority.characters().despawnParticipant(participant_transport, id),
    );
    try std.testing.expectError(
        error.AuthorityFaulted,
        authority.crates().submit(.{ .spawn = .{ .request_id = 2, .pose = .{} } }),
    );
    try std.testing.expectError(
        error.AuthorityFaulted,
        authority.vehicles().submit(.{ .spawn = .{ .request_id = 3 } }),
    );
    try std.testing.expectError(
        error.AuthorityFaulted,
        authority.districts().submit(.{ .request_load = .{
            .request_id = 4,
            .coord = sandbox_district_recipe.navigation_west_coord,
            .assets = .{},
        } }),
    );
    try std.testing.expectError(
        error.AuthorityFaulted,
        authority.interactions().submit(.{ .spawn = .{
            .request_id = 5,
            .pose = .{},
        } }),
    );
    try std.testing.expectError(
        error.AuthorityFaulted,
        authority.npcs().submit(.{ .spawn = .{ .request_id = 6, .node = .{} } }),
    );
    try std.testing.expectError(error.AuthorityFaulted, authority.persistence().issueSource());
    try std.testing.expectError(error.AuthorityFaulted, authority.session().tick());

    try std.testing.expect(std.meta.eql(diagnostics_before, authority.session().diagnostics()));
    try std.testing.expect(std.meta.eql(simulation_before, authority.developer().diagnostics()));
    try std.testing.expect(std.meta.eql(
        observations_before,
        authority.inspection().observationDiagnostics(),
    ));
    try std.testing.expectEqual(outbox_before, core.outbox.len);
    try std.testing.expectEqual(admission_time_before, core.admission_time_unix_seconds);
    try std.testing.expectEqual(source_issued_before, core.snapshot_source_issued);

    authority.session().transportClosed(participant_transport);
    try authority.session().stop();
    const shutdown = authority.session().pollOutbound() orelse
        return error.MissingFaultedAuthorityShutdown;
    try std.testing.expectEqual(
        protocol.DisconnectReason.authority_stopping,
        shutdown.message.disconnected,
    );
}

test "admission nonce capacity preflight leaves no participant and reuses only expired slots" {
    const room_secret: protocol.AdmissionSecret = @splat(0x6b);
    var options = Options{};
    options.room_admission = .{
        .room_id = 71,
        .authority_id = 9_001,
        .room_generation = 3,
        .secret = room_secret,
    };
    const authority = try initTestEmbeddedAuthority(
        testEmbeddedCoreConfig(0x454d_4405, .automatic),
        options,
        0x55,
    );
    defer authority.deinit();
    const core = embeddedAuthorityCore(authority);
    for (&core.used_admission_nonces, 0..) |*used, index| {
        used.* = .{
            .nonce = index + 1,
            .expires_at_unix_seconds = 100,
        };
    }
    const nonces_before = core.used_admission_nonces;
    const simulation_before = authority.developer().diagnostics();
    const account = identity.AccountId{ .value = 71 };
    const external_identity = protocol.ExternalIdentity{ .provider = .steam, .subject = 9001 };
    const authorization = testRoomAuthorization(
        room_secret,
        account,
        external_identity,
        10_001,
        100,
    );
    const transport = TransportConnection{ .value = 1 };
    _ = try authority.session().openConnection(transport);
    try std.testing.expectError(
        error.AdmissionNonceHistoryCapacityReached,
        authority.session().ingestAtUnixTime(transport, .{ .hello = .{
            .account = account,
            .external_identity = external_identity,
            .join_authorization = authorization,
        } }, 10),
    );
    try std.testing.expectEqual(@as(u16, 0), authority.session().diagnostics().active_participants);
    const connection_index = core.findConnection(transport) orelse
        return error.MissingNonceCapacityConnection;
    try std.testing.expect(core.connections[connection_index].participant_index == null);
    try std.testing.expectEqual(@as(usize, 0), core.outbox.len);
    try std.testing.expect(std.meta.eql(simulation_before, authority.developer().diagnostics()));
    try std.testing.expect(std.meta.eql(nonces_before, core.used_admission_nonces));

    const expired_slot: usize = 37;
    core.used_admission_nonces[expired_slot].expires_at_unix_seconds = 9;
    try authority.session().ingestAtUnixTime(transport, .{ .hello = .{
        .account = account,
        .external_identity = external_identity,
        .join_authorization = authorization,
    } }, 10);
    try std.testing.expectEqual(
        authorization.nonce,
        core.used_admission_nonces[expired_slot].nonce,
    );
    try std.testing.expectEqual(
        authorization.expires_at_unix_seconds,
        core.used_admission_nonces[expired_slot].expires_at_unix_seconds,
    );
    for (core.used_admission_nonces, 0..) |used, index| {
        if (index == expired_slot) continue;
        try std.testing.expectEqual(nonces_before[index], used);
    }
    try std.testing.expectEqual(@as(u16, 1), authority.session().diagnostics().active_participants);
    try std.testing.expect(authority.session().pollOutbound().?.message == .welcome);
}

test "embedded authority rejects a simulation clock outside the session contract" {
    var config = testEmbeddedCoreConfig(0x454d_4205, .host_managed);
    config.simulation.fixed_delta_seconds = 1.0 / 30.0;
    try std.testing.expectError(
        error.AuthorityTickRateMismatch,
        EmbeddedAuthority.init(std.testing.allocator, config),
    );
}

test "embedded inspection round-trips only exact active authority identities" {
    const authority = try EmbeddedAuthority.init(
        std.testing.allocator,
        testEmbeddedCoreConfig(0x454d_4206, .host_managed),
    );
    defer authority.deinit();
    const core = embeddedAuthorityCore(authority);

    const character_persistent = engine.PersistentId{ .namespace = 101, .local = 1 };
    const vehicle_persistent = engine.PersistentId{ .namespace = 101, .local = 2 };
    const carryable_persistent = engine.PersistentId{ .namespace = 101, .local = 3 };
    const npc_persistent = engine.PersistentId{ .namespace = 101, .local = 4 };
    const character_replicated = identity.ReplicatedEntityId{ .index = 1, .generation = 7 };
    const vehicle_replicated = identity.ReplicatedEntityId{ .index = 17, .generation = 8 };
    const carryable_replicated = identity.ReplicatedEntityId{ .index = 33, .generation = 9 };
    const npc_replicated = identity.ReplicatedEntityId{ .index = 49, .generation = 10 };

    core.participants[0] = .{
        .active = true,
        .character = character_persistent,
        .replicated = character_replicated,
    };
    core.vehicles[0] = .{
        .active = true,
        .persistent = vehicle_persistent,
        .replicated = vehicle_replicated,
    };
    core.carryables[0] = .{
        .active = true,
        .persistent = carryable_persistent,
        .replicated = carryable_replicated,
    };
    core.npcs[0] = .{
        .active = true,
        .persistent = npc_persistent,
        .replicated = npc_replicated,
    };

    const pairs = [_]struct {
        persistent: engine.PersistentId,
        replicated: identity.ReplicatedEntityId,
    }{
        .{ .persistent = character_persistent, .replicated = character_replicated },
        .{ .persistent = vehicle_persistent, .replicated = vehicle_replicated },
        .{ .persistent = carryable_persistent, .replicated = carryable_replicated },
        .{ .persistent = npc_persistent, .replicated = npc_replicated },
    };
    for (pairs) |pair| {
        try std.testing.expectEqual(
            pair.replicated,
            authority.inspection().replicatedId(pair.persistent).?,
        );
        try std.testing.expectEqual(
            pair.persistent,
            authority.inspection().persistentId(pair.replicated).?,
        );
    }

    var stale_character = character_replicated;
    stale_character.generation +%= 1;
    try std.testing.expect(authority.inspection().persistentId(stale_character) == null);
    try std.testing.expect(authority.inspection().replicatedId(.{
        .namespace = 101,
        .local = 999,
    }) == null);

    core.participants[0].active = false;
    core.vehicles[0].active = false;
    core.vehicles[0].spawn_pending = true;
    core.carryables[0].active = false;
    core.npcs[0].active = false;
    for (pairs) |pair| {
        try std.testing.expect(authority.inspection().replicatedId(pair.persistent) == null);
    }
}

test "authority cycle faults stop later stages and latch the first failure" {
    inline for (
        std.meta.fields(authority_diagnostics.CycleStage),
        0..,
    ) |stage_field, expected_completed_stages| {
        const stage = @field(authority_diagnostics.CycleStage, stage_field.name);
        const config = testEmbeddedCoreConfig(
            0x454d_4300 + expected_completed_stages,
            .host_managed,
        );
        const authority = try EmbeddedAuthority.init(std.testing.allocator, config);
        defer authority.deinit();

        try std.testing.expectError(
            error.InjectedAuthorityCycleFault,
            embeddedAuthorityCore(authority).tickImpl(null, stage),
        );
        const diagnostics = authority.session().diagnostics();
        try std.testing.expectEqual(
            @as(u8, @intCast(expected_completed_stages)),
            diagnostics.last_cycle.count,
        );
        try std.testing.expectEqual(stage, diagnostics.last_cycle.failed_stage.?);
        const expected_completed_tick: u64 = if (stage == .pre_simulation or
            stage == .simulation) 0 else 1;
        try std.testing.expectEqual(expected_completed_tick, diagnostics.tick);
        const first_fault = diagnostics.first_cycle_fault orelse
            return error.MissingAuthorityCycleFault;
        try std.testing.expectEqual(stage, first_fault.stage);
        try std.testing.expectEqual(
            @intFromError(error.InjectedAuthorityCycleFault),
            first_fault.error_code,
        );
        try std.testing.expectError(error.AuthorityFaulted, authority.session().tick());
    }
}

test "host-managed participant spawn preserves caller correlation and publishes state" {
    const authority = try EmbeddedAuthority.init(
        std.testing.allocator,
        testEmbeddedCoreConfig(0x454d_4201, .host_managed),
    );
    defer authority.deinit();
    const transport = TransportConnection{ .value = 71 };
    _ = try authority.session().openConnection(transport);
    try authority.session().ingest(transport, .{ .hello = .{
        .account = .{ .value = 7 },
    } });
    try std.testing.expect(authority.session().pollOutbound().?.message == .welcome);
    try authority.characters().spawnParticipant(transport, .{
        .request_id = 1,
        .position = .{ 0, 0, 0 },
    });
    try authority.session().tick();
    const outcome = authority.characters().pollOutcome() orelse
        return error.MissingHostParticipantSpawnOutcome;
    try std.testing.expect(outcome == .spawned);
    try std.testing.expectEqual(@as(u64, 1), outcome.spawned.request_id);
    try std.testing.expectEqual(@as(usize, 1), authority.characters().count());

    var saw_baseline = false;
    var replicated_character = identity.ReplicatedEntityId.invalid;
    while (authority.session().pollOutbound()) |outbound| {
        if (outbound.message == .relevance_baseline) {
            saw_baseline = true;
            try std.testing.expectEqual(
                @as(u8, 1),
                outbound.message.relevance_baseline.snapshot.character_count,
            );
            replicated_character = outbound.message.relevance_baseline.snapshot.characters[0].entity;
        }
    }
    try std.testing.expect(saw_baseline);
    try std.testing.expectEqual(
        outcome.spawned.id,
        authority.inspection().persistentId(replicated_character).?,
    );
    var stale_character = replicated_character;
    stale_character.generation +%= 1;
    try std.testing.expect(authority.inspection().persistentId(stale_character) == null);
}

test "host-managed vehicle registry accepts spawn and despawn without fixture assumptions" {
    const authority = try EmbeddedAuthority.init(
        std.testing.allocator,
        testEmbeddedCoreConfig(0x454d_4202, .host_managed),
    );
    defer authority.deinit();
    try authority.vehicles().submit(.{ .spawn = .{
        .request_id = 9,
        .chassis = .{ .pose = .{ .position = .{ 0, 2, 0 } } },
    } });
    try authority.session().tick();
    const spawned = (authority.vehicles().pollOutcome() orelse
        return error.MissingHostVehicleSpawnOutcome).spawned;
    try std.testing.expectEqual(@as(u64, 9), spawned.request_id);
    try std.testing.expectEqual(@as(usize, 1), authority.vehicles().count());

    try authority.vehicles().submit(.{ .despawn = .{ .id = spawned.id } });
    try authority.session().tick();
    const despawned = authority.vehicles().pollOutcome() orelse
        return error.MissingHostVehicleDespawnOutcome;
    try std.testing.expect(despawned == .despawned);
    try std.testing.expectEqual(@as(usize, 0), authority.vehicles().count());
}

test "host-managed feature rejections remain observable instead of authority-fatal" {
    const authority = try EmbeddedAuthority.init(
        std.testing.allocator,
        testEmbeddedCoreConfig(0x454d_4205, .host_managed),
    );
    defer authority.deinit();
    const missing = engine.PersistentId{ .namespace = 0x454d_4205, .local = 999 };

    try std.testing.expectError(
        error.UnsupportedAuthorityDistrict,
        authority.districts().submit(.{ .request_load = .{
            .request_id = 20,
            .coord = .{ .x = 99, .z = 99 },
            .assets = .{},
        } }),
    );
    try authority.districts().submit(.{ .unload = .{
        .request_id = 21,
        .ticket = .{ .coord = sandbox_district_recipe.navigation_west_coord, .generation = 1 },
    } });
    try authority.interactions().submit(.{ .despawn = .{ .id = missing } });
    try authority.npcs().submit(.{ .despawn = .{ .request_id = 22, .id = missing } });
    try authority.session().tick();

    try std.testing.expect((authority.districts().pollOutcome() orelse
        return error.MissingHostDistrictRejection) == .rejected);
    try std.testing.expect((authority.interactions().pollOutcome() orelse
        return error.MissingHostInteractionRejection) == .rejected);
    try std.testing.expect((authority.npcs().pollOutcome() orelse
        return error.MissingHostNpcRejection) == .rejected);
    try std.testing.expectEqual(@as(usize, 0), authority.districts().count());
    try std.testing.expectEqual(@as(usize, 0), authority.interactions().count());
    try std.testing.expectEqual(@as(usize, 0), authority.npcs().count());
    try std.testing.expectEqual(@as(usize, 0), (try authority.districts().presentation()).len);
    try std.testing.expectEqual(
        @as(usize, 0),
        (try authority.interactions().presentation()).len,
    );
    try std.testing.expectEqual(@as(usize, 0), (try authority.npcs().presentation(0)).len);
}

test "bounded host observation drops oldest records without blocking authority" {
    const authority = try EmbeddedAuthority.init(
        std.testing.allocator,
        testEmbeddedCoreConfig(0x454d_4203, .host_managed),
    );
    defer authority.deinit();
    for (0..host_observation_capacity + 1) |index| {
        try authority.crates().submit(.{ .spawn = .{
            .request_id = index + 1,
            .pose = .{ .position = .{ 0, 4, 0 } },
        } });
        try authority.session().tick();
    }
    const diagnostics = authority.inspection().observationDiagnostics();
    try std.testing.expectEqual(
        @as(u32, host_observation_capacity),
        diagnostics.pending_records,
    );
    try std.testing.expectEqual(@as(u64, 1), diagnostics.records_dropped);
    const oldest = authority.crates().pollOutcome() orelse
        return error.MissingRetainedHostObservation;
    try std.testing.expectEqual(@as(u64, 2), oldest.spawned.request_id);
}

test "embedded persistence transfers one opaque quiescent snapshot source" {
    const authority = try EmbeddedAuthority.init(
        std.testing.allocator,
        testEmbeddedCoreConfig(0x454d_4204, .host_managed),
    );
    defer authority.deinit();
    const cohort = authority.inspection().persistenceCohort();
    try std.testing.expectEqual(sandbox_host_contracts.snapshot_schema, cohort.payload_schema);
    const source = try authority.persistence().issueSource();
    try std.testing.expectError(
        error.SnapshotSourceAlreadyIssued,
        authority.persistence().issueSource(),
    );
    try authority.crates().submit(.{ .spawn = .{
        .request_id = 1,
        .pose = .{ .position = .{ 0, 2, 0 } },
    } });
    try std.testing.expectError(
        error.CommandsPending,
        source.capture(std.testing.allocator),
    );
    try authority.session().tick();
    try std.testing.expectError(
        error.AuthorityOutputsPending,
        source.capture(std.testing.allocator),
    );
    _ = authority.crates().pollOutcome() orelse
        return error.MissingPersistenceSafePointOutcome;
    const bytes = try source.capture(std.testing.allocator);
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(bytes.len != 0);
}

fn testTakeAndAcknowledgeBaseline(
    authority: *DedicatedAuthority,
    transport: TransportConnection,
) !protocol.Snapshot {
    var baseline: ?protocol.RelevanceBaseline = null;
    while (authority.pollOutbound()) |outbound| switch (outbound.message) {
        .relevance_baseline => |value| baseline = value,
        else => {},
    };
    const value = baseline orelse return error.MissingInitialBaseline;
    const connection_index = authority.state().findConnection(transport) orelse
        return error.MissingTestConnection;
    const participant_index = authority.state().connections[connection_index].participant_index orelse
        return error.MissingTestParticipant;
    try authority.ingest(transport, .{ .baseline_ack = .{
        .session = authority.state().session,
        .participant = participantId(
            participant_index,
            authority.state().participants[participant_index].generation,
        ),
        .baseline_id = value.baseline_id,
    } });
    return value.snapshot;
}

test "authority admits two participants and emits join-in-progress snapshots" {
    const authority = try DedicatedAuthority.init(std.testing.allocator);
    defer authority.deinit();

    _ = try authority.openConnection(.{ .value = 101 });
    try authority.ingest(.{ .value = 101 }, .{ .hello = .{
        .account = .{ .value = 1 },
    } });
    const welcome_one = authority.pollOutbound().?.message.welcome;
    try authority.tick();
    const first_snapshot = try testTakeAndAcknowledgeBaseline(
        authority,
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
    const authority = try DedicatedAuthority.init(std.testing.allocator);
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

test "authority defers admitted input until its declared target tick" {
    const authority = try DedicatedAuthority.init(std.testing.allocator);
    defer authority.deinit();
    const transport = TransportConnection{ .value = 1 };
    _ = try authority.openConnection(transport);
    try authority.ingest(transport, .{ .hello = .{
        .account = .{ .value = 1 },
    } });
    const welcome = authority.pollOutbound().?.message.welcome;
    try authority.tick();
    while (authority.pollOutbound() != null) {}

    const connection_index = authority.state().findConnection(transport) orelse
        return error.MissingTestConnection;
    const participant_index = authority.state().connections[connection_index].participant_index orelse
        return error.MissingTestParticipant;
    const character = authority.state().participants[participant_index].character orelse
        return error.MissingTestCharacter;
    const before = try authority.state().simulation.character(character);
    const first_target_tick = authority.state().simulation.tickIndex() + 3;
    const second_target_tick = first_target_tick + 1;
    try authority.ingest(transport, .{ .input = .{
        .session = welcome.session,
        .participant = welcome.participant,
        .sequence = .{ .value = 1 },
        .target_tick = first_target_tick,
        .move = .{ 0, 1 },
        .facing_yaw = 0,
        .jump_pressed = false,
    } });
    try authority.ingest(transport, .{ .input = .{
        .session = welcome.session,
        .participant = welcome.participant,
        .sequence = .{ .value = 2 },
        .target_tick = second_target_tick,
        .move = .{ 1, 0 },
        .facing_yaw = 0,
        .jump_pressed = false,
    } });
    try std.testing.expectEqual(
        @as(u8, 2),
        authority.state().participants[participant_index].pending_inputs.len,
    );
    try std.testing.expectEqual(
        @as(u32, 0),
        authority.state().participants[participant_index].last_applied_input.value,
    );

    for (0..2) |_| {
        try authority.tick();
        while (authority.pollOutbound() != null) {}
        const deferred = try authority.state().simulation.character(character);
        try std.testing.expectApproxEqAbs(before.position[2], deferred.position[2], 0.0001);
    }
    try authority.tick();
    const first_applied = try authority.state().simulation.character(character);
    try std.testing.expectEqual(first_target_tick, authority.state().simulation.tickIndex());
    try std.testing.expect(first_applied.position[2] < before.position[2]);
    try std.testing.expectEqual(
        @as(u32, 1),
        authority.state().participants[participant_index].last_applied_input.value,
    );
    try std.testing.expectEqual(
        @as(u32, 1),
        (try authority.state().buildRelevantSnapshot(participant_index))
            .acknowledged_input.value,
    );

    try authority.tick();
    try std.testing.expectEqual(second_target_tick, authority.state().simulation.tickIndex());
    try std.testing.expectEqual(
        @as(u32, 2),
        authority.state().participants[participant_index].last_applied_input.value,
    );
    try std.testing.expectEqual(
        @as(u32, 2),
        (try authority.state().buildRelevantSnapshot(participant_index))
            .acknowledged_input.value,
    );
}

test "typed authority ingress rejects zero action sequences before state drift" {
    const authority = try DedicatedAuthority.init(std.testing.allocator);
    defer authority.deinit();
    const transport = TransportConnection{ .value = 1 };
    _ = try authority.openConnection(transport);
    const connection_index = authority.state().findConnection(transport) orelse
        return error.MissingTestConnection;
    const received_before = authority.state().connections[connection_index].received_messages;
    const diagnostics_before = authority.diagnostics();

    try std.testing.expectError(
        error.InvalidActionSequence,
        authority.ingest(transport, .{ .vehicle_action = .{
            .session = .{ .value = 1 },
            .participant = .{ .index = 1, .generation = 1 },
            .sequence = .{ .value = 0 },
            .vehicle = .{ .index = 17, .generation = 1 },
            .kind = .enter,
        } }),
    );
    try std.testing.expectError(
        error.InvalidActionSequence,
        authority.ingest(transport, .{ .interaction_action = .{
            .session = .{ .value = 1 },
            .participant = .{ .index = 1, .generation = 1 },
            .sequence = .{ .value = 0 },
            .carryable = .{ .index = 21, .generation = 1 },
            .kind = .collect,
        } }),
    );

    const diagnostics_after = authority.diagnostics();
    try std.testing.expectEqual(
        received_before,
        authority.state().connections[connection_index].received_messages,
    );
    try std.testing.expectEqual(
        diagnostics_before.accepted_messages,
        diagnostics_after.accepted_messages,
    );
    try std.testing.expectEqual(
        diagnostics_before.rejected_messages,
        diagnostics_after.rejected_messages,
    );
    try std.testing.expectEqual(
        diagnostics_before.malformed_messages,
        diagnostics_after.malformed_messages,
    );
    try std.testing.expectEqual(
        diagnostics_before.ingress_entries,
        diagnostics_after.ingress_entries,
    );
    try std.testing.expect(authority.pollOutbound() == null);
}

test "authority owns vehicle enter drive exit and dynamic seat projection" {
    const authority = try DedicatedAuthority.init(std.testing.allocator);
    defer authority.deinit();
    const transport = TransportConnection{ .value = 1 };
    _ = try authority.openConnection(transport);
    try authority.ingest(transport, .{ .hello = .{
        .account = .{ .value = 1 },
    } });
    const welcome = authority.pollOutbound().?.message.welcome;
    try authority.tick();
    const initial = try testTakeAndAcknowledgeBaseline(authority, transport);
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
    const authority = try DedicatedAuthority.init(std.testing.allocator);
    defer authority.deinit();
    const transport = TransportConnection{ .value = 1 };
    _ = try authority.openConnection(transport);
    try authority.ingest(transport, .{ .hello = .{ .account = .{ .value = 1 } } });
    const welcome = authority.pollOutbound().?.message.welcome;
    try authority.tick();
    const initial = try testTakeAndAcknowledgeBaseline(authority, transport);
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
    const authority = try DedicatedAuthority.init(std.testing.allocator);
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
    try std.testing.expectEqual(transport_policy.Delivery.reliable, outbound.delivery);
}

test "per-tick input quota terminates abusive ingress without growth" {
    const authority = try DedicatedAuthority.init(std.testing.allocator);
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
    const authority = try DedicatedAuthority.init(std.testing.allocator);
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
    const authority = try DedicatedAuthority.init(std.testing.allocator);
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
    try authority.state().expireConnections(
        authority.state().simulation.tickIndex() + budgets.handshake_timeout_ticks,
    );
    try std.testing.expectEqual(
        protocol.RejectionReason.invalid_state,
        authority.pollOutbound().?.message.rejected.reason,
    );

    try authority.state().expireConnections(
        authority.state().simulation.tickIndex() + budgets.idle_timeout_ticks,
    );
    try std.testing.expectEqual(
        protocol.DisconnectReason.timeout,
        authority.pollOutbound().?.message.disconnected,
    );
    try std.testing.expectEqual(@as(u16, 1), authority.diagnostics().reconnecting_participants);
}
