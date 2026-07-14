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
const vitals_contract = @import("vitals_contract");
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
    delivery_id: u64 = 0,
    close_after_send: bool = false,
};

const ReplayMessage = union(enum) {
    vehicle_action_result: protocol.VehicleActionResult,
    interaction_action_result: protocol.InteractionActionResult,
    melee_action_result: protocol.MeleeActionResult,
    respawn_action_result: protocol.RespawnActionResult,
    life_event: protocol.LifeEvent,

    fn serverMessage(self: ReplayMessage) protocol.ServerMessage {
        return switch (self) {
            .vehicle_action_result => |value| .{ .vehicle_action_result = value },
            .interaction_action_result => |value| .{ .interaction_action_result = value },
            .melee_action_result => |value| .{ .melee_action_result = value },
            .respawn_action_result => |value| .{ .respawn_action_result = value },
            .life_event => |value| .{ .life_event = value },
        };
    }
};

const ReliableReplayRecord = struct {
    active: bool = false,
    delivery_id: u64 = 0,
    message: ReplayMessage = undefined,
};

/// One adapter-owned view of the live publication head. The authority keeps
/// the message until the adapter explicitly commits this generation.
pub const OutboundLease = struct {
    generation: u64,
    outbound: Outbound,
};

const Outbox = engine.BoundedQueue(Outbound, budgets.outbound_message_capacity);

const IngressClass = enum { control, gameplay, input, notice };

const IngressPayload = union(enum) {
    connection_opened: TransportConnection,
    connection_closed: TransportConnection,
    decoded: struct {
        transport: TransportConnection,
        message: protocol.ClientMessage,
        admission_time_unix_seconds: ?u64,
    },
    malformed: TransportConnection,
    oversized: TransportConnection,
};

const IngressEnvelope = struct {
    ordinal: u64,
    payload: IngressPayload,
};

fn IngressQueue(comptime capacity: usize) type {
    return engine.BoundedQueue(IngressEnvelope, capacity);
}

/// Single-owner, class-reserved mailbox. Each class has guaranteed space and
/// the frozen cycle prefix is merged back into original arrival order.
const IngressMailbox = struct {
    control: IngressQueue(budgets.inbound_control_capacity) = .{},
    gameplay: IngressQueue(budgets.inbound_gameplay_capacity) = .{},
    input: IngressQueue(budgets.inbound_input_capacity) = .{},
    notice: IngressQueue(budgets.inbound_notice_capacity) = .{},
    next_ordinal: u64 = 1,
    high_water: u16 = 0,
    rejected: u64 = 0,

    fn push(self: *IngressMailbox, class: IngressClass, payload: IngressPayload) !u64 {
        const ordinal = self.next_ordinal;
        if (ordinal == 0) return error.IngressOrdinalExhausted;
        const envelope = IngressEnvelope{ .ordinal = ordinal, .payload = payload };
        (switch (class) {
            .control => self.control.push(envelope),
            .gameplay => self.gameplay.push(envelope),
            .input => self.input.push(envelope),
            .notice => self.notice.push(envelope),
        }) catch {
            self.rejected +|= 1;
            return error.IngressClassCapacityReached;
        };
        self.next_ordinal +%= 1;
        self.high_water = @max(self.high_water, @as(u16, @intCast(self.len())));
        return ordinal;
    }

    fn len(self: *const IngressMailbox) usize {
        return self.control.len + self.gameplay.len + self.input.len + self.notice.len;
    }

    fn popOldest(self: *IngressMailbox) ?IngressEnvelope {
        var oldest: ?struct { class: IngressClass, ordinal: u64 } = null;
        inline for (.{
            .{ IngressClass.control, &self.control },
            .{ IngressClass.gameplay, &self.gameplay },
            .{ IngressClass.input, &self.input },
            .{ IngressClass.notice, &self.notice },
        }) |candidate| {
            if (candidate[1].peek()) |envelope| {
                if (oldest == null or envelope.ordinal < oldest.?.ordinal) {
                    oldest = .{ .class = candidate[0], .ordinal = envelope.ordinal };
                }
            }
        }
        const selected = oldest orelse return null;
        return switch (selected.class) {
            .control => self.control.pop(),
            .gameplay => self.gameplay.pop(),
            .input => self.input.pop(),
            .notice => self.notice.pop(),
        };
    }
};

const CycleScratch = struct {
    ingress: [budgets.inbound_message_capacity]IngressEnvelope = undefined,
    admission: [budgets.inbound_message_capacity]AdmissionDisposition = undefined,
    ingress_len: u16 = 0,

    fn clear(self: *CycleScratch) void {
        self.ingress_len = 0;
    }

    fn freeze(self: *CycleScratch, mailbox: *IngressMailbox) void {
        self.clear();
        const frozen_len = mailbox.len();
        std.debug.assert(frozen_len <= self.ingress.len);
        while (self.ingress_len < frozen_len) {
            self.ingress[self.ingress_len] = mailbox.popOldest().?;
            self.ingress_len += 1;
        }
    }

    fn slice(self: *const CycleScratch) []const IngressEnvelope {
        return self.ingress[0..self.ingress_len];
    }
};

const AdmissionDisposition = enum {
    apply,
    discard,
};

const DurableCaptureResult = struct {
    request_id: snapshot_source.RequestId,
    disposition: snapshot_source.Disposition,
};

const DurableRequestQueue = struct {
    next_request_id: snapshot_source.RequestId = 1,
    pending: ?snapshot_source.RequestId = null,
    result: ?DurableCaptureResult = null,

    fn request(self: *DurableRequestQueue) !snapshot_source.RequestId {
        if (self.pending != null or self.result != null) return error.CaptureBusy;
        const request_id = self.next_request_id;
        if (request_id == 0) return error.CaptureRequestIdExhausted;
        self.next_request_id +%= 1;
        self.pending = request_id;
        return request_id;
    }

    fn take(
        self: *DurableRequestQueue,
        request_id: snapshot_source.RequestId,
    ) !?snapshot_source.Disposition {
        const result = self.result orelse {
            if (self.pending == request_id) return null;
            return error.UnknownCaptureRequest;
        };
        if (result.request_id != request_id) return error.UnknownCaptureRequest;
        self.result = null;
        return result.disposition;
    }
};

fn ingressClass(message: protocol.ClientMessage) IngressClass {
    return switch (message) {
        .hello, .baseline_ack, .snapshot_ack, .delivery_receipt, .disconnect => .control,
        .vehicle_action, .interaction_action, .melee_action, .respawn_action => .gameplay,
        .input, .vehicle_input => .input,
    };
}

fn reliableMessageReceipted(message: protocol.ServerMessage) bool {
    return switch (message) {
        .welcome => true,
        .vehicle_action_result,
        .interaction_action_result,
        .melee_action_result,
        .respawn_action_result,
        .life_event,
        => true,
        .snapshot, .relevance_baseline, .rejected, .disconnected => false,
    };
}

test "ingress mailbox reserves control capacity and freezes a stable ordered prefix" {
    var mailbox = IngressMailbox{};
    var input_ordinals: [budgets.inbound_input_capacity]u64 = undefined;
    for (&input_ordinals, 0..) |*ordinal, index| {
        ordinal.* = try mailbox.push(.input, .{ .connection_closed = .{
            .value = @intCast(index + 1),
        } });
    }
    try std.testing.expectError(
        error.IngressClassCapacityReached,
        mailbox.push(.input, .{ .connection_closed = .{ .value = 10_000 } }),
    );

    const control_ordinal = try mailbox.push(
        .control,
        .{ .connection_opened = .{ .value = 20_000 } },
    );
    try std.testing.expect(control_ordinal > input_ordinals[input_ordinals.len - 1]);

    var scratch = CycleScratch{};
    scratch.freeze(&mailbox);
    try std.testing.expectEqual(input_ordinals.len + 1, scratch.slice().len);
    for (scratch.slice(), 0..) |envelope, index| {
        const expected = if (index < input_ordinals.len)
            input_ordinals[index]
        else
            control_ordinal;
        try std.testing.expectEqual(expected, envelope.ordinal);
    }

    const next_cycle_ordinal = try mailbox.push(
        .control,
        .{ .connection_closed = .{ .value = 20_000 } },
    );
    try std.testing.expectEqual(@as(usize, 1), mailbox.len());
    try std.testing.expectEqual(next_cycle_ordinal, mailbox.control.peek().?.ordinal);
    try std.testing.expectEqual(input_ordinals.len + 1, scratch.slice().len);
}

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

const PlayerLifecycle = enum { spawning, alive, dead, respawn_pending };

const ParticipantSlot = struct {
    active: bool = false,
    generation: u16 = 0,
    account: identity.AccountId = .{ .value = 0 },
    external_identity: protocol.ExternalIdentity = .{},
    connection_index: ?u8 = null,
    reconnect: identity.ReconnectToken = .invalid,
    retained_reconnect: identity.ReconnectToken = .invalid,
    reconnect_confirmation_pending: bool = false,
    pending_welcome_delivery_id: u64 = 0,
    reconnect_deadline_tick: u64 = 0,
    character: ?engine.PersistentId = null,
    replicated: identity.ReplicatedEntityId = .invalid,
    avatar_incarnation: u16 = 1,
    lifecycle: PlayerLifecycle = .spawning,
    vitals_pending: bool = false,
    death_tick: u64 = 0,
    respawn_available_tick: u64 = 0,
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
    last_melee_action: identity.ActionSequence = .{ .value = 0 },
    pending_melee_action: ?protocol.MeleeAction = null,
    melee_cooldown_until_tick: u64 = 0,
    last_respawn_action: identity.ActionSequence = .{ .value = 0 },
    pending_respawn_action: ?protocol.RespawnAction = null,
    interaction_cleanup_pending: bool = false,
    relevance_coord: district_contract.ChunkCoord = sandbox_district_recipe.navigation_west_coord,
    baseline_id: u32 = 0,
    baseline_acknowledged: u32 = 0,
    baseline_sent: bool = false,
    baseline_eligible_tick: u64 = 0,
    next_control_delivery_id: u64 = 1,
    next_gameplay_delivery_id: u64 = 1,
    applied_control_delivery_id: u64 = 0,
    applied_gameplay_delivery_id: u64 = 0,
    replay_cursor_delivery_id: u64 = 0,
    replay_records: [budgets.reliable_replay_records_per_participant]ReliableReplayRecord =
        @splat(.{}),
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

fn nextGeneration(current: u16) u16 {
    const candidate = current +% 1;
    return if (candidate == 0) 1 else candidate;
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
    vitals_pending: bool = false,
    despawn_pending: bool = false,
};

const melee_damage: u16 = 34;
const melee_range: f32 = 2.75;
const melee_minimum_forward_dot: f32 = 0.2;
const melee_cooldown_ticks: u64 = budgets.authority_tick_hz / 2;
const respawn_cooldown_ticks: u64 = budgets.authority_tick_hz * 3;

const MeleeTarget = struct {
    kind: vitals_contract.TargetKind,
    persistent: engine.PersistentId,
    replicated: identity.ReplicatedEntityId,
    incarnation: u16,
    distance_squared: f32,
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
    avatar_incarnation: u16 = 0,

    pub const Kind = enum(u8) {
        character = 1,
        vehicle = 2,
        vehicle_enter = 3,
        vehicle_exit = 4,
        interaction_collect = 5,
        interaction_drop = 6,
        melee = 7,
        respawn = 8,
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
    durable_requests: DurableRequestQueue = .{},
    prepared_durable_result: ?DurableCaptureResult = null,
    persistence_cohort: PersistenceCohort,
    credential_issuer: CredentialIssuer,
    session: identity.SessionId,
    connections: [budgets.max_participants]ConnectionSlot = @splat(.{}),
    participants: *[budgets.max_participants]ParticipantSlot,
    prepared_participants: *[budgets.max_participants]ParticipantSlot,
    vehicles: [budgets.max_vehicles]VehicleSlot = @splat(.{}),
    carryables: [budgets.max_carryables]CarryableSlot = @splat(.{}),
    npcs: [budgets.max_npcs]NpcSlot = @splat(.{}),
    replication: *[budgets.max_participants]ReplicationState,
    prepared_replication: *[budgets.max_participants]ReplicationState,
    options: Options,
    admission_time_unix_seconds: u64 = 0,
    mailbox: IngressMailbox = .{},
    scratch: CycleScratch = .{},
    outbox: *Outbox,
    prepared_outbox: *Outbox,
    publication_preparing: bool = false,
    publication_metadata_staged: bool = false,
    lease_active: bool = false,
    lease_generation: u64 = 0,
    outbox_high_water: u16 = 0,
    delivery_receipts: u64 = 0,
    reliable_replays: u64 = 0,
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
    melee_actions_admitted: u64 = 0,
    melee_hits: u64 = 0,
    deaths: u64 = 0,
    respawns: u64 = 0,
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
    defer_replication_this_cycle: bool = false,
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
        const prepared_outbox = try allocator.create(Outbox);
        errdefer allocator.destroy(prepared_outbox);
        prepared_outbox.* = .{};
        const participants = try allocator.create([budgets.max_participants]ParticipantSlot);
        errdefer allocator.destroy(participants);
        participants.* = @splat(.{});
        const prepared_participants = try allocator.create(
            [budgets.max_participants]ParticipantSlot,
        );
        errdefer allocator.destroy(prepared_participants);
        prepared_participants.* = @splat(.{});
        const replication = try allocator.create([budgets.max_participants]ReplicationState);
        errdefer allocator.destroy(replication);
        replication.* = @splat(.{});
        const prepared_replication = try allocator.create(
            [budgets.max_participants]ReplicationState,
        );
        errdefer allocator.destroy(prepared_replication);
        prepared_replication.* = @splat(.{});
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
            .participants = participants,
            .prepared_participants = prepared_participants,
            .outbox = outbox,
            .prepared_outbox = prepared_outbox,
            .replication = replication,
            .prepared_replication = prepared_replication,
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
        if (self.prepared_durable_result) |result| switch (result.disposition) {
            .captured => |bytes| self.allocator.free(bytes),
            .deferred, .failed => {},
        };
        if (self.durable_requests.result) |result| switch (result.disposition) {
            .captured => |bytes| self.allocator.free(bytes),
            .deferred, .failed => {},
        };
        self.simulation.deinit();
        self.allocator.destroy(self.prepared_replication);
        self.allocator.destroy(self.replication);
        self.allocator.destroy(self.prepared_participants);
        self.allocator.destroy(self.participants);
        self.allocator.destroy(self.prepared_outbox);
        self.allocator.destroy(self.outbox);
        self.credential_issuer.deinit();
        self.* = undefined;
    }

    fn openConnection(
        self: *AuthorityCore,
        transport: TransportConnection,
    ) !u64 {
        try self.ensureOperationalMutation();
        if (transport.value == 0) return error.InvalidTransportConnection;
        return self.mailbox.push(.control, .{ .connection_opened = transport });
    }

    fn applyConnectionOpened(
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
    ) !u64 {
        if (transport.value == 0) return error.InvalidTransportConnection;
        if (self.first_cycle_fault != null) {
            self.applyTransportClosed(transport);
            return 0;
        }
        return self.mailbox.push(.control, .{ .connection_closed = transport });
    }

    fn applyTransportClosed(
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
            .observe_fn = observeSnapshotForDiagnostics,
            .request_fn = requestSnapshotForPersistence,
            .take_fn = takeSnapshotForPersistence,
            .release_fn = releaseSnapshotForPersistence,
        };
    }

    fn observeSnapshotForDiagnostics(
        context: *anyopaque,
        allocator: std.mem.Allocator,
    ) anyerror![]u8 {
        const self: *AuthorityCore = @ptrCast(@alignCast(context));
        if (self.first_cycle_fault != null) return error.AuthorityFaulted;
        if (self.mailbox.len() != 0) return error.SessionWorkPending;
        if (self.publication_preparing or self.lease_active or self.outbox.len != 0 or
            !self.observations.empty()) return error.AuthorityOutputsPending;
        for (self.participants) |participant| {
            if (participant.pending_inputs.len != 0 or
                (participant.held_input != null and !participant.held_input_applied) or
                participant.spawn_pending or participant.despawn_pending or
                participant.pending_vehicle_action != null or
                participant.pending_interaction_action != null or
                participant.pending_melee_action != null or
                participant.pending_respawn_action != null or
                participant.vitals_pending or
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

    fn requestSnapshotForPersistence(
        context: *anyopaque,
    ) anyerror!snapshot_source.RequestId {
        const self: *AuthorityCore = @ptrCast(@alignCast(context));
        if (self.first_cycle_fault != null) return error.AuthorityFaulted;
        return self.durable_requests.request();
    }

    fn takeSnapshotForPersistence(
        context: *anyopaque,
        request_id: snapshot_source.RequestId,
    ) anyerror!?snapshot_source.Disposition {
        const self: *AuthorityCore = @ptrCast(@alignCast(context));
        if (self.first_cycle_fault != null and self.durable_requests.result == null) {
            return error.AuthorityFaulted;
        }
        return self.durable_requests.take(request_id);
    }

    fn releaseSnapshotForPersistence(context: *anyopaque, bytes: []u8) void {
        const self: *AuthorityCore = @ptrCast(@alignCast(context));
        self.allocator.free(bytes);
    }

    fn ingestBytes(
        self: *AuthorityCore,
        transport: TransportConnection,
        bytes: []const u8,
    ) !void {
        try self.ensureOperationalMutation();
        const message = protocol.decodeClient(bytes) catch {
            _ = try self.mailbox.push(.notice, .{ .malformed = transport });
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
        try protocol.validateClient(message);
        if (message == .hello and self.options.room_admission != null and
            !message.hello.reconnect.isValid() and now_unix_seconds == null)
        {
            return error.RoomAdmissionRequiresTimestampedIngress;
        }
        _ = try self.mailbox.push(ingressClass(message), .{ .decoded = .{
            .transport = transport,
            .message = message,
            .admission_time_unix_seconds = now_unix_seconds,
        } });
    }

    fn applyDecodedIngress(
        self: *AuthorityCore,
        transport: TransportConnection,
        message: protocol.ClientMessage,
        now_unix_seconds: ?u64,
    ) !void {
        if (now_unix_seconds) |now| try self.applyAdmissionTime(now);
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
            .melee_action => |action| try self.ingestMeleeAction(connection_index, action),
            .respawn_action => |action| try self.ingestRespawnAction(connection_index, action),
            .baseline_ack => |ack| try self.ingestBaselineAck(connection_index, ack),
            .snapshot_ack => |ack| try self.ingestSnapshotAck(connection_index, ack),
            .delivery_receipt => |receipt| try self.ingestDeliveryReceipt(
                connection_index,
                receipt,
            ),
            .disconnect => |reason| try self.ingestDisconnect(connection_index, reason),
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
        if (self.outbox.len != 0 or self.lease_active) {
            return error.AuthorityOutputsPending;
        }
        std.debug.assert(self.prepared_outbox.len == 0);
        self.last_cycle = beginAuthorityCycle(self.simulation.tickIndex());
        self.defer_replication_this_cycle = false;
        self.publication_preparing = true;
        errdefer self.publication_preparing = false;

        try self.maybeInjectCycleFault(fault_stage, .ingress_freeze);
        self.scratch.freeze(&self.mailbox);
        recordAuthorityCycleStage(
            &self.last_cycle,
            .ingress_freeze,
            self.simulation.tickIndex(),
        );

        try self.maybeInjectCycleFault(fault_stage, .admission);
        self.planFrozenIngress() catch |err| {
            self.failCycle(.admission, err);
            return err;
        };
        recordAuthorityCycleStage(
            &self.last_cycle,
            .admission,
            self.simulation.tickIndex(),
        );

        try self.maybeInjectCycleFault(fault_stage, .semantic_work);
        self.applyFrozenIngress() catch |err| {
            self.failCycle(.semantic_work, err);
            return err;
        };
        self.prepareSimulationTick() catch |err| {
            self.failCycle(.semantic_work, err);
            return err;
        };
        recordAuthorityCycleStage(
            &self.last_cycle,
            .semantic_work,
            self.simulation.tickIndex(),
        );

        try self.maybeInjectCycleFault(fault_stage, .simulation);
        self.simulation.tickObserved(observer) catch |err| {
            self.failCycle(.simulation, err);
            return err;
        };
        recordAuthorityCycleStage(
            &self.last_cycle,
            .simulation,
            self.simulation.tickIndex(),
        );

        try self.maybeInjectCycleFault(fault_stage, .outcome_drain);
        self.drainSimulationOutcomes() catch |err| {
            self.failCycle(.outcome_drain, err);
            return err;
        };
        recordAuthorityCycleStage(
            &self.last_cycle,
            .outcome_drain,
            self.simulation.tickIndex(),
        );

        try self.maybeInjectCycleFault(fault_stage, .derivative_preparation);
        self.stagePublicationMetadata();
        self.extractReplication() catch |err| {
            self.failCycle(.derivative_preparation, err);
            return err;
        };
        recordAuthorityCycleStage(
            &self.last_cycle,
            .derivative_preparation,
            self.simulation.tickIndex(),
        );

        try self.maybeInjectCycleFault(fault_stage, .durable_disposition);
        self.evaluateDurableRequest();
        recordAuthorityCycleStage(
            &self.last_cycle,
            .durable_disposition,
            self.simulation.tickIndex(),
        );

        try self.maybeInjectCycleFault(fault_stage, .publication);
        self.publishPrepared();
        recordAuthorityCycleStage(
            &self.last_cycle,
            .publication,
            self.simulation.tickIndex(),
        );
        self.publication_preparing = false;
    }

    inline fn maybeInjectCycleFault(
        self: *AuthorityCore,
        comptime fault_stage: ?authority_diagnostics.CycleStage,
        comptime current_stage: authority_diagnostics.CycleStage,
    ) !void {
        if (fault_stage == current_stage) {
            self.failCycle(current_stage, error.InjectedAuthorityCycleFault);
            return error.InjectedAuthorityCycleFault;
        }
    }

    fn planFrozenIngress(self: *AuthorityCore) !void {
        var projected_connections: [budgets.max_participants]TransportConnection =
            @splat(.{ .value = 0 });
        for (self.connections, 0..) |connection, index| {
            if (connection.active) projected_connections[index] = connection.transport;
        }
        for (self.scratch.slice(), 0..) |envelope, index| {
            self.scratch.admission[index] = .apply;
            switch (envelope.payload) {
                .connection_opened => |transport| {
                    if (transport.value == 0) return error.InvalidTransportConnection;
                    var free_index: ?usize = null;
                    for (projected_connections, 0..) |projected, projected_index| {
                        if (std.meta.eql(projected, transport)) {
                            self.scratch.admission[index] = .discard;
                            break;
                        }
                        if (projected.value == 0 and free_index == null) {
                            free_index = projected_index;
                        }
                    } else if (free_index) |available| {
                        projected_connections[available] = transport;
                    } else {
                        self.scratch.admission[index] = .discard;
                    }
                },
                .connection_closed => |transport| {
                    if (transport.value == 0) return error.InvalidTransportConnection;
                    for (&projected_connections) |*projected| {
                        if (std.meta.eql(projected.*, transport)) {
                            projected.* = .{ .value = 0 };
                            break;
                        }
                    }
                },
                .decoded => |decoded| {
                    if (decoded.transport.value == 0) return error.InvalidTransportConnection;
                    try protocol.validateClient(decoded.message);
                    for (projected_connections) |projected| {
                        if (std.meta.eql(projected, decoded.transport)) break;
                    } else self.scratch.admission[index] = .discard;
                },
                .malformed, .oversized => |transport| {
                    if (transport.value == 0) return error.InvalidTransportConnection;
                },
            }
        }
    }

    fn applyFrozenIngress(self: *AuthorityCore) !void {
        for (self.scratch.slice(), 0..) |envelope, index| {
            if (self.scratch.admission[index] == .discard) {
                self.rejected_messages +|= 1;
                continue;
            }
            switch (envelope.payload) {
                .connection_opened => |transport| {
                    _ = self.applyConnectionOpened(transport) catch |err| switch (err) {
                        error.DuplicateTransportConnection,
                        error.ConnectionCapacityReached,
                        => {
                            self.rejected_messages +|= 1;
                            continue;
                        },
                        else => return err,
                    };
                },
                .connection_closed => |transport| self.applyTransportClosed(transport),
                .decoded => |decoded| self.applyDecodedIngress(
                    decoded.transport,
                    decoded.message,
                    decoded.admission_time_unix_seconds,
                ) catch |err| switch (err) {
                    error.UnknownTransportConnection => {
                        self.rejected_messages +|= 1;
                        continue;
                    },
                    error.AdmissionNonceHistoryCapacityReached => {
                        const connection_index = self.findConnection(decoded.transport) orelse {
                            self.rejected_messages +|= 1;
                            continue;
                        };
                        try self.rejectConnection(connection_index, .session_full, false);
                        continue;
                    },
                    error.AdmissionClockMovedBackward,
                    error.CredentialIssuerExhausted,
                    error.ReliableEventBudgetExceeded,
                    error.CharacterCommandQueueFull,
                    => {
                        const connection_index = self.findConnection(decoded.transport) orelse {
                            self.rejected_messages +|= 1;
                            continue;
                        };
                        try self.rejectConnection(connection_index, .invalid_state, false);
                        continue;
                    },
                    else => return err,
                },
                .malformed => |transport| {
                    self.malformed_messages +|= 1;
                    if (self.findConnection(transport) != null) {
                        try self.rejectTransport(transport, .malformed, true);
                    } else {
                        self.rejected_messages +|= 1;
                    }
                },
                .oversized => |transport| {
                    if (self.findConnection(transport) != null) {
                        try self.rejectTransport(transport, .oversized, true);
                    } else {
                        self.rejected_messages +|= 1;
                    }
                },
            }
        }
    }

    fn publishPrepared(self: *AuthorityCore) void {
        std.debug.assert(self.outbox.len == 0);
        std.debug.assert(!self.lease_active);
        const previous_live = self.outbox;
        self.outbox = self.prepared_outbox;
        self.prepared_outbox = previous_live;
        std.debug.assert(self.prepared_outbox.len == 0);
        self.outbox_high_water = @max(
            self.outbox_high_water,
            @as(u16, @intCast(self.outbox.len)),
        );
        if (self.prepared_durable_result) |result| {
            std.debug.assert(self.durable_requests.pending == result.request_id);
            std.debug.assert(self.durable_requests.result == null);
            self.durable_requests.pending = null;
            self.durable_requests.result = result;
            self.prepared_durable_result = null;
        }
        self.publication_metadata_staged = false;
        self.scratch.clear();
    }

    fn failCycle(
        self: *AuthorityCore,
        stage: authority_diagnostics.CycleStage,
        err: anyerror,
    ) void {
        self.prepared_outbox.clear();
        self.rollbackPublicationMetadata();
        if (self.prepared_durable_result) |result| switch (result.disposition) {
            .captured => |bytes| self.allocator.free(bytes),
            .deferred, .failed => {},
        };
        self.prepared_durable_result = null;
        self.publication_preparing = false;
        self.latchCycleFault(stage, err);
    }

    fn stagePublicationMetadata(self: *AuthorityCore) void {
        std.debug.assert(!self.publication_metadata_staged);
        self.prepared_participants.* = self.participants.*;
        self.prepared_replication.* = self.replication.*;
        const live_participants = self.participants;
        self.participants = self.prepared_participants;
        self.prepared_participants = live_participants;
        const live_replication = self.replication;
        self.replication = self.prepared_replication;
        self.prepared_replication = live_replication;
        self.publication_metadata_staged = true;
    }

    fn rollbackPublicationMetadata(self: *AuthorityCore) void {
        if (!self.publication_metadata_staged) return;
        const staged_participants = self.participants;
        self.participants = self.prepared_participants;
        self.prepared_participants = staged_participants;
        const staged_replication = self.replication;
        self.replication = self.prepared_replication;
        self.prepared_replication = staged_replication;
        self.publication_metadata_staged = false;
    }

    fn prepareSimulationTick(self: *AuthorityCore) !void {
        self.replenishReplicationBudgets();
        try self.expireConnections(self.simulation.tickIndex());
        try self.expireReconnects();
        try self.applyHeldInputs(self.simulation.tickIndex());
    }

    fn drainSimulationOutcomes(self: *AuthorityCore) !void {
        self.processCrateOutcomes();
        try self.processVitalsOutcomes();
        try self.processCharacterOutcomes();
        try self.processVehicleOutcomes();
        try self.processDistrictOutcomes();
        try self.processInteractionOutcomes();
        try self.processNpcOutcomes();
    }

    fn extractReplication(self: *AuthorityCore) !void {
        try self.prepareReliableReplay();
        if (self.defer_replication_this_cycle) {
            self.force_snapshot = self.force_snapshot or self.hasPendingBaseline();
            return;
        }
        const tick_index = self.simulation.tickIndex();
        if (self.force_snapshot or tick_index % budgets.ticks_per_snapshot == 0) {
            try self.publishSnapshots();
            self.force_snapshot = self.hasPendingBaseline();
        }
    }

    fn hasPendingBaseline(self: *const AuthorityCore) bool {
        for (self.participants) |participant| {
            if (participant.active and participant.connection_index != null and
                !participant.baseline_sent) return true;
        }
        return false;
    }

    fn evaluateDurableRequest(self: *AuthorityCore) void {
        const request_id = self.durable_requests.pending orelse return;
        std.debug.assert(self.prepared_durable_result == null);
        const disposition: snapshot_source.Disposition = if (self.durableDeferral()) |deferral|
            .{ .deferred = deferral }
        else if (self.simulation.save(self.allocator)) |bytes|
            .{ .captured = bytes }
        else |err|
            .{ .failed = err };
        self.prepared_durable_result = .{
            .request_id = request_id,
            .disposition = disposition,
        };
    }

    fn durableDeferral(self: *AuthorityCore) ?snapshot_source.Deferral {
        if (self.mailbox.len() != 0) return .session_work;
        if (self.lease_active or self.outbox.len != 0 or
            self.prepared_outbox.len != 0 or !self.observations.empty())
        {
            return .authority_outputs;
        }
        for (self.participants) |participant| {
            if (participant.pending_inputs.len != 0 or
                (participant.held_input != null and !participant.held_input_applied) or
                participant.spawn_pending or participant.despawn_pending or
                participant.pending_vehicle_action != null or
                participant.pending_interaction_action != null or
                participant.pending_melee_action != null or
                participant.pending_respawn_action != null or
                participant.vitals_pending or
                participant.interaction_cleanup_pending or participant.exit_pending)
            {
                return .session_work;
            }
        }
        if (self.simulation.operationalQuiescenceReason()) |reason| return switch (reason) {
            .runtime_faulted => null,
            .commands_pending => .simulation_commands,
            .district_transition,
            .district_outcome_reservations,
            .district_worker_busy,
            => .district_transition,
            .outputs_pending => .authority_outputs,
        };
        return null;
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

    fn beginOutboundLease(self: *AuthorityCore) ?OutboundLease {
        if (self.lease_active) {
            return .{
                .generation = self.lease_generation,
                .outbound = self.outbox.peek().?,
            };
        }
        const outbound = self.outbox.peek() orelse return null;
        self.lease_generation +%= 1;
        if (self.lease_generation == 0) self.lease_generation = 1;
        self.lease_active = true;
        return .{ .generation = self.lease_generation, .outbound = outbound };
    }

    fn commitOutboundLease(self: *AuthorityCore, generation: u64) !void {
        if (!self.lease_active or generation != self.lease_generation) {
            return error.StaleOutboundLease;
        }
        _ = self.outbox.pop() orelse return error.OutboundLeaseInvariant;
        self.lease_active = false;
    }

    fn retryOutboundLease(self: *AuthorityCore, generation: u64) !void {
        if (!self.lease_active or generation != self.lease_generation) {
            return error.StaleOutboundLease;
        }
    }

    fn stop(self: *AuthorityCore) !void {
        if (self.publication_preparing or self.lease_active or self.outbox.len != 0) {
            return error.AuthorityOutputsPending;
        }
        for (0..self.connections.len) |connection_index| {
            if (!self.connections[connection_index].active) continue;
            try self.queueLive(.{
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
        _ = try self.mailbox.push(.notice, .{ .oversized = transport });
    }

    fn applyAdmissionTime(self: *AuthorityCore, now_unix_seconds: u64) !void {
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
        var alive_participants: u16 = 0;
        var dead_participants: u16 = 0;
        var spawning_participants: u16 = 0;
        var active_vehicles: u16 = 0;
        var active_carryables: u16 = 0;
        var active_npcs: u16 = 0;
        var connected_participants: u16 = 0;
        var reconnecting_participants: u16 = 0;
        var reliable_replay_records: u16 = 0;
        for (self.connections) |connection| active_connections += @intFromBool(connection.active);
        for (self.participants) |participant| {
            active_participants += @intFromBool(participant.active);
            if (participant.active) switch (participant.lifecycle) {
                .alive => alive_participants += 1,
                .dead, .respawn_pending => dead_participants += 1,
                .spawning => spawning_participants += 1,
            };
            connected_participants += @intFromBool(
                participant.active and participant.connection_index != null,
            );
            reconnecting_participants += @intFromBool(
                participant.active and participant.connection_index == null and
                    !participant.despawn_pending,
            );
            for (participant.replay_records) |record| {
                reliable_replay_records += @intFromBool(record.active);
            }
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
            .alive_participants = alive_participants,
            .dead_participants = dead_participants,
            .spawning_participants = spawning_participants,
            .active_vehicles = active_vehicles,
            .active_carryables = active_carryables,
            .active_npcs = active_npcs,
            .connected_participants = connected_participants,
            .reconnecting_participants = reconnecting_participants,
            .mailbox_occupancy = @intCast(self.mailbox.len()),
            .mailbox_high_water = self.mailbox.high_water,
            .mailbox_rejected = self.mailbox.rejected,
            .outbox_occupancy = @intCast(self.outbox.len),
            .outbox_high_water = self.outbox_high_water,
            .outbound_lease_active = self.lease_active,
            .reliable_replay_records = reliable_replay_records,
            .delivery_receipts = self.delivery_receipts,
            .reliable_replays = self.reliable_replays,
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
            .melee_actions_admitted = self.melee_actions_admitted,
            .melee_hits = self.melee_hits,
            .deaths = self.deaths,
            .respawns = self.respawns,
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
        const participant_index = self.availableParticipantIndex() orelse {
            try self.rejectConnection(connection_index, .session_full, true);
            return;
        };
        try self.preflightReliablePublication(connection_index, 1);
        const next_generation = nextGeneration(self.participants[participant_index].generation);
        const planned_participant = participantId(participant_index, next_generation);
        const credential_serial_before = self.credential_issuer.next_serial;
        const reconnect = try self.issueReconnectCredential(
            hello.account,
            external_identity,
            planned_participant,
        );
        if (self.participant_spawn == .automatic) {
            const lane = participant_index % 4;
            const row = participant_index / 4;
            self.simulation.submitCharacter(.{ .spawn = .{
                .request_id = spawnRequestId(participant_index, next_generation),
                .position = .{
                    @as(f32, @floatFromInt(lane)) * 2.0 - 3.0,
                    0,
                    @as(f32, @floatFromInt(row)) * 2.0,
                },
            } }) catch |err| {
                self.credential_issuer.next_serial = credential_serial_before;
                return err;
            };
        }
        const allocated_index = self.allocateParticipant() orelse unreachable;
        std.debug.assert(allocated_index == participant_index);
        const participant = &self.participants[participant_index];
        std.debug.assert(participant.generation == next_generation);
        if (admission_nonce_slot) |slot| {
            self.commitAdmissionNonce(slot, hello.join_authorization);
        }
        participant.account = hello.account;
        participant.external_identity = external_identity;
        participant.connection_index = @intCast(connection_index);
        participant.reconnect = reconnect;
        participant.avatar_incarnation = participant.generation;
        participant.lifecycle = .spawning;
        participant.replicated = .{
            .index = @intCast(participant_index + 1),
            .generation = participant.avatar_incarnation,
        };
        participant.relevance_coord = sandbox_district_recipe.navigation_west_coord;
        participant.baseline_id = 1;
        participant.baseline_acknowledged = 0;
        participant.baseline_sent = false;
        participant.baseline_eligible_tick = self.simulation.tickIndex() +| 2;
        self.resetReplicationBaseline(participant_index);
        self.connections[connection_index].participant_index = @intCast(participant_index);
        if (self.participant_spawn == .automatic) {
            participant.spawn_pending = true;
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
        for (self.participants, 0..) |*participant, participant_index| {
            const current_credential = reconnectCredentialsEqual(
                participant.reconnect,
                hello.reconnect,
            );
            const retained_credential = participant.reconnect_confirmation_pending and
                reconnectCredentialsEqual(participant.retained_reconnect, hello.reconnect);
            if (!participant.active or participant.connection_index != null or
                (participant.despawn_pending and participant.lifecycle != .dead) or
                !std.meta.eql(participant.account, hello.account) or
                !std.meta.eql(participant.external_identity, external_identity) or
                (!current_credential and !retained_credential) or
                tick_index > participant.reconnect_deadline_tick)
            {
                continue;
            }
            try self.preflightReliablePublication(connection_index, 1);
            const next_reconnect = try self.issueReconnectCredential(
                participant.account,
                participant.external_identity,
                participantId(participant_index, participant.generation),
            );
            const previous_reconnect = participant.reconnect;
            const previous_retained_reconnect = participant.retained_reconnect;
            const previous_confirmation_pending = participant.reconnect_confirmation_pending;
            const previous_pending_welcome = participant.pending_welcome_delivery_id;
            const previous_next_control_delivery = participant.next_control_delivery_id;
            const previous_replay_cursor = participant.replay_cursor_delivery_id;
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
                participant.pending_welcome_delivery_id = previous_pending_welcome;
                participant.next_control_delivery_id = previous_next_control_delivery;
                participant.replay_cursor_delivery_id = previous_replay_cursor;
                connection.event_quota_tick = previous_event_quota_tick;
                connection.reliable_events_this_tick = previous_reliable_events;
                self.max_reliable_events_per_connection_tick = previous_max_reliable_events;
                return err;
            };
            participant.replay_cursor_delivery_id =
                participant.applied_gameplay_delivery_id +| 1;
            participant.connection_index = @intCast(connection_index);
            participant.baseline_id +%= 1;
            if (participant.baseline_id == 0) participant.baseline_id = 1;
            participant.baseline_acknowledged = 0;
            participant.baseline_sent = false;
            participant.baseline_eligible_tick = self.simulation.tickIndex() +| 2;
            self.resetReplicationBaseline(participant_index);
            self.connections[connection_index].participant_index = @intCast(participant_index);
            self.reconnects +|= 1;
            self.accepted_messages +|= 1;
            self.force_snapshot = true;
            return true;
        }
        return false;
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
        if (participant.lifecycle != .alive) {
            self.invalid_control_inputs +|= 1;
            return;
        }
        if (participant.character == null and !participant.spawn_pending) {
            self.invalid_control_inputs +|= 1;
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
        if (participant.lifecycle != .alive) {
            self.invalid_control_inputs +|= 1;
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
        if (participant.lifecycle != .alive or participant.pending_vehicle_action != null or
            participant.despawn_pending)
        {
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
        if (participant.lifecycle != .alive or participant.pending_interaction_action != null or
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

    fn ingestMeleeAction(
        self: *AuthorityCore,
        connection_index: usize,
        action: protocol.MeleeAction,
    ) !void {
        const participant_index = self.connections[connection_index].participant_index orelse {
            try self.rejectConnection(connection_index, .unauthorized, false);
            return;
        };
        const participant = &self.participants[participant_index];
        if (!gameplay_admission.identitiesMatch(
            self.session,
            participantId(participant_index, participant.generation),
            action.session,
            action.participant,
        )) {
            try self.rejectConnection(connection_index, .stale_connection, false);
            return;
        }
        if (!gameplay_admission.actionIsNewer(participant.last_melee_action, action.sequence)) {
            return;
        }
        participant.last_melee_action = action.sequence;
        if (action.avatar_incarnation != participant.avatar_incarnation) {
            try self.queueMeleeActionResult(participant_index, action, .wrong_incarnation);
            return;
        }
        if (participant.lifecycle != .alive or participant.character == null or
            participant.despawn_pending)
        {
            try self.queueMeleeActionResult(participant_index, action, .dead);
            return;
        }
        if (participant.vitals_pending) {
            try self.queueMeleeActionResult(participant_index, action, .invalid_state);
            return;
        }
        const tick_index = self.simulation.tickIndex();
        if (action.target_tick < tick_index -| budgets.input_history_ticks or
            action.target_tick > tick_index +| budgets.max_future_input_ticks)
        {
            try self.queueMeleeActionResult(participant_index, action, .invalid_state);
            return;
        }
        if (participant.pending_melee_action != null) {
            try self.queueMeleeActionResult(participant_index, action, .invalid_state);
            return;
        }
        if (tick_index < participant.melee_cooldown_until_tick) {
            try self.queueMeleeActionResult(participant_index, action, .cooldown);
            return;
        }
        participant.melee_cooldown_until_tick = tick_index +| melee_cooldown_ticks;
        self.recordMeleeIngress(connection_index, participant_index, action);
        const target = try self.selectMeleeTarget(participant_index);
        if (target == null) {
            try self.queueMeleeActionResult(participant_index, action, .miss);
            self.accepted_messages +|= 1;
            return;
        }
        const character = participant.character.?;
        try self.simulation.submitVitals(.{ .damage = .{
            .source = .{
                .kind = .player,
                .id = character,
                .incarnation = .{ .value = participant.avatar_incarnation },
                .action_sequence = action.sequence.value,
            },
            .target = .{
                .kind = target.?.kind,
                .id = target.?.persistent,
                .incarnation = .{ .value = target.?.incarnation },
            },
            .cause = .melee,
            .authority_tick = tick_index +| 1,
            .correlation = damageCorrelation(participant_index, action.sequence),
            .base_amount = melee_damage,
            .ordinal = 1,
        } });
        participant.pending_melee_action = action;
        self.accepted_messages +|= 1;
    }

    fn ingestRespawnAction(
        self: *AuthorityCore,
        connection_index: usize,
        action: protocol.RespawnAction,
    ) !void {
        const participant_index = self.connections[connection_index].participant_index orelse {
            try self.rejectConnection(connection_index, .unauthorized, false);
            return;
        };
        const participant = &self.participants[participant_index];
        if (!gameplay_admission.identitiesMatch(
            self.session,
            participantId(participant_index, participant.generation),
            action.session,
            action.participant,
        )) {
            try self.rejectConnection(connection_index, .stale_connection, false);
            return;
        }
        if (!gameplay_admission.actionIsNewer(participant.last_respawn_action, action.sequence)) {
            return;
        }
        participant.last_respawn_action = action.sequence;
        if (action.dead_incarnation != participant.avatar_incarnation) {
            try self.queueRespawnActionResult(participant_index, action, .wrong_incarnation);
            return;
        }
        if (participant.lifecycle == .alive or participant.lifecycle == .spawning) {
            try self.queueRespawnActionResult(participant_index, action, .alive);
            return;
        }
        if (participant.character != null or participant.despawn_pending or
            participant.vitals_pending)
        {
            try self.queueRespawnActionResult(participant_index, action, .cleanup_pending);
            return;
        }
        if (self.simulation.tickIndex() < participant.respawn_available_tick) {
            try self.queueRespawnActionResult(participant_index, action, .cooldown);
            return;
        }
        const spawn_position = try self.selectRespawnPosition(participant_index) orelse {
            participant.lifecycle = .respawn_pending;
            try self.queueRespawnActionResult(participant_index, action, .no_safe_spawn);
            return;
        };
        try self.simulation.submitCharacter(.{ .spawn = .{
            .request_id = spawnRequestId(participant_index, participant.generation),
            .position = spawn_position,
        } });
        participant.lifecycle = .spawning;
        participant.spawn_pending = true;
        participant.pending_respawn_action = action;
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
            .target_tick = self.simulation.tickIndex() +| 1,
            .kind = .respawn,
            .move = .{ 0, 0 },
            .facing_yaw = 0,
            .jump_pressed = false,
            .vehicle = .invalid,
            .vehicle_control = .{ 0, 0, 0, 0 },
            .avatar_incarnation = action.dead_incarnation,
        });
        self.accepted_messages +|= 1;
    }

    fn recordMeleeIngress(
        self: *AuthorityCore,
        connection_index: usize,
        participant_index: usize,
        action: protocol.MeleeAction,
    ) void {
        const participant = self.participants[participant_index];
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
            .target_tick = action.target_tick,
            .kind = .melee,
            .move = .{ 0, 0 },
            .facing_yaw = 0,
            .jump_pressed = false,
            .vehicle = .invalid,
            .vehicle_control = .{ 0, 0, 0, 0 },
            .avatar_incarnation = action.avatar_incarnation,
        });
        self.melee_actions_admitted +|= 1;
    }

    fn selectMeleeTarget(
        self: *AuthorityCore,
        attacker_index: usize,
    ) !?MeleeTarget {
        const attacker = self.participants[attacker_index];
        const source = try self.simulation.character(attacker.character.?);
        const forward = [2]f32{ @sin(source.facing_yaw), -@cos(source.facing_yaw) };
        var selected: ?MeleeTarget = null;
        for (self.participants, 0..) |candidate, index| {
            if (index == attacker_index or !candidate.active or
                candidate.lifecycle != .alive or candidate.character == null or
                candidate.despawn_pending or candidate.vitals_pending)
            {
                continue;
            }
            const view = try self.simulation.character(candidate.character.?);
            if (!try self.simulation.meleeLineClear(source.position, view.position)) continue;
            considerMeleeTarget(&selected, source.position, forward, .{
                .kind = .player,
                .persistent = candidate.character.?,
                .replicated = candidate.replicated,
                .incarnation = candidate.avatar_incarnation,
                .distance_squared = horizontalDistanceSquared(source.position, view.position),
            }, view.position);
        }
        for (self.npcs) |npc| {
            if (!npc.active or npc.persistent == null or npc.despawn_pending or
                npc.vitals_pending)
            {
                continue;
            }
            const vitals = self.simulation.currentVitals(.npc, npc.persistent.?) orelse continue;
            if (vitals.life_state != .alive) continue;
            const view = try self.simulation.npc(npc.persistent.?);
            if (!try self.simulation.meleeLineClear(source.position, view.position)) continue;
            considerMeleeTarget(&selected, source.position, forward, .{
                .kind = .npc,
                .persistent = npc.persistent.?,
                .replicated = npc.replicated,
                .incarnation = npc.generation,
                .distance_squared = horizontalDistanceSquared(source.position, view.position),
            }, view.position);
        }
        return selected;
    }

    fn selectRespawnPosition(
        self: *AuthorityCore,
        participant_index: usize,
    ) !?[3]f32 {
        const candidates = [_][3]f32{
            .{ -3, 0, 0 },  .{ 3, 0, 0 },  .{ -3, 0, 4 }, .{ 3, 0, 4 },
            .{ -6, 0, -3 }, .{ 6, 0, -3 }, .{ 0, 0, 7 },  .{ 0, 0, -7 },
        };
        const participant = self.participants[participant_index];
        const rotation = (@as(usize, participant_index) + participant.avatar_incarnation) %
            candidates.len;
        var selected: ?[3]f32 = null;
        var selected_score: f32 = -1;
        for (0..candidates.len) |offset| {
            const candidate = candidates[(rotation + offset) % candidates.len];
            if (!try self.simulation.characterSpawnClear(candidate)) continue;
            var nearest_threat: f32 = std.math.inf(f32);
            var blocked = false;
            for (self.participants, 0..) |other, other_index| {
                if (other_index == participant_index or !other.active or
                    other.lifecycle != .alive or other.character == null or
                    other.despawn_pending)
                {
                    continue;
                }
                const view = try self.simulation.character(other.character.?);
                const distance = horizontalDistanceSquared(candidate, view.position);
                if (distance < 2.25) {
                    blocked = true;
                    break;
                }
                nearest_threat = @min(nearest_threat, distance);
            }
            if (blocked) continue;
            for (self.npcs) |npc| {
                if (!npc.active or npc.persistent == null or npc.despawn_pending) continue;
                const view = try self.simulation.npc(npc.persistent.?);
                const distance = horizontalDistanceSquared(candidate, view.position);
                if (distance < 2.25) {
                    blocked = true;
                    break;
                }
                nearest_threat = @min(nearest_threat, distance);
            }
            if (blocked) continue;
            if (nearest_threat > selected_score) {
                selected = candidate;
                selected_score = nearest_threat;
            }
        }
        return selected;
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
        self.delivery_receipts +|= 1;
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

    fn ingestDeliveryReceipt(
        self: *AuthorityCore,
        connection_index: usize,
        receipt: protocol.DeliveryReceipt,
    ) !void {
        const participant_index = self.connections[connection_index].participant_index orelse {
            try self.rejectConnection(connection_index, .unauthorized, false);
            return;
        };
        const participant = &self.participants[participant_index];
        if (!std.meta.eql(receipt.session, self.session) or
            !std.meta.eql(receipt.participant, participantId(
                participant_index,
                participant.generation,
            )))
        {
            try self.rejectConnection(connection_index, .stale_connection, false);
            return;
        }
        const next_id = switch (receipt.lane) {
            .control => participant.next_control_delivery_id,
            .gameplay => participant.next_gameplay_delivery_id,
        };
        if (receipt.delivery_id >= next_id) {
            try self.rejectConnection(connection_index, .stale_sequence, false);
            return;
        }
        const applied = switch (receipt.lane) {
            .control => &participant.applied_control_delivery_id,
            .gameplay => &participant.applied_gameplay_delivery_id,
        };
        if (receipt.delivery_id > applied.*) applied.* = receipt.delivery_id;
        if (receipt.lane == .gameplay) {
            for (&participant.replay_records) |*record| {
                if (record.active and record.delivery_id <= applied.*) record.active = false;
            }
            if (participant.replay_cursor_delivery_id != 0 and
                participant.replay_cursor_delivery_id <= applied.*)
            {
                const next = applied.* +| 1;
                participant.replay_cursor_delivery_id = if (next >= participant.next_gameplay_delivery_id) 0 else next;
            }
        }
        if (receipt.lane == .control and participant.reconnect_confirmation_pending and
            participant.pending_welcome_delivery_id != 0 and
            receipt.delivery_id >= participant.pending_welcome_delivery_id)
        {
            participant.retained_reconnect = .invalid;
            participant.reconnect_confirmation_pending = false;
            participant.pending_welcome_delivery_id = 0;
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
        for (self.participants) |*participant| {
            if (!participant.active or participant.connection_index == null or
                participant.lifecycle != .alive or participant.character == null or
                participant.despawn_pending)
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
        for (self.participants, 0..) |participant, index| {
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
                    participant.vitals_pending = true;
                    if (participant.pending_respawn_action != null) {
                        const incarnation = nextGeneration(participant.avatar_incarnation);
                        participant.avatar_incarnation = incarnation;
                        participant.replicated.generation = incarnation;
                        participant.lifecycle = .spawning;
                        participant.baseline_id +%= 1;
                        if (participant.baseline_id == 0) participant.baseline_id = 1;
                        participant.baseline_acknowledged = 0;
                        participant.baseline_sent = false;
                        participant.baseline_eligible_tick = self.simulation.tickIndex() +| 2;
                        self.resetReplicationBaseline(decoded.index);
                    } else {
                        participant.lifecycle = .alive;
                    }
                    try self.simulation.submitVitals(.{ .register = .{
                        .target = playerVitalsTarget(participant.*, spawned.id),
                    } });
                    if (participant.despawn_pending) {
                        try self.simulation.submitCharacter(.{ .despawn = .{ .id = spawned.id } });
                    }
                    self.force_snapshot = true;
                },
                .despawned => |id| {
                    for (self.participants) |*participant| {
                        if (participant.active and participant.character != null and
                            std.meta.eql(participant.character.?, id))
                        {
                            const removed_target = playerVitalsTarget(participant.*, id);
                            if (self.simulation.vitals(removed_target) != null) {
                                try self.simulation.submitVitals(.{ .remove = removed_target });
                            }
                            const retain_participant = participant.retain_after_despawn and
                                participant.connection_index != null;
                            participant.active = retain_participant;
                            if (!retain_participant) participant.connection_index = null;
                            participant.character = null;
                            participant.driving_vehicle_index = null;
                            participant.holding_carryable_index = null;
                            participant.pending_vehicle_action = null;
                            participant.pending_interaction_action = null;
                            participant.pending_melee_action = null;
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
                        if (participant.pending_respawn_action) |action| {
                            try self.queueRespawnActionResult(
                                decoded.index,
                                action,
                                .no_safe_spawn,
                            );
                            participant.pending_respawn_action = null;
                            participant.lifecycle = .dead;
                        } else if (participant.connection_index) |connection_index| {
                            try self.rejectConnection(connection_index, .invalid_state, true);
                            participant.active = false;
                        }
                        participant.spawn_pending = false;
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
                        npc.vitals_pending = true;
                        try self.simulation.submitVitals(.{ .register = .{
                            .target = npcVitalsTarget(npc.*, spawned.id),
                        } });
                    } else if (self.world_bootstrap == .host_managed) {
                        try self.registerHostNpc(spawned.id);
                        const npc_index = self.findNpcByPersistent(spawned.id) orelse
                            return error.HostNpcRegistrationMissing;
                        const npc = &self.npcs[npc_index];
                        npc.vitals_pending = true;
                        try self.simulation.submitVitals(.{ .register = .{
                            .target = npcVitalsTarget(npc.*, spawned.id),
                        } });
                    } else {
                        return error.UnexpectedNpcSpawnOutcome;
                    }
                    self.force_snapshot = true;
                },
                .goal_set => if (self.world_bootstrap != .host_managed) {
                    return error.UnexpectedNpcMutationOutcome;
                },
                .despawned => |despawned| {
                    if (decodeNpcDeathRequestId(despawned.request_id)) |decoded| {
                        const npc = &self.npcs[decoded.index];
                        if (npc.generation != decoded.generation or !npc.despawn_pending or
                            npc.persistent == null or
                            !std.meta.eql(npc.persistent.?, despawned.id))
                        {
                            return error.StaleNpcDeathDespawnOutcome;
                        }
                        const removed_target = npcVitalsTarget(npc.*, despawned.id);
                        if (self.simulation.vitals(removed_target) != null) {
                            try self.simulation.submitVitals(.{ .remove = removed_target });
                        }
                        npc.active = false;
                        npc.despawn_pending = false;
                        npc.persistent = null;
                        self.force_snapshot = true;
                    } else if (self.world_bootstrap != .host_managed) {
                        return error.UnexpectedNpcMutationOutcome;
                    } else {
                        const npc_index = self.findNpcByPersistent(despawned.id) orelse
                            return error.UnknownHostNpcDespawn;
                        const npc = self.npcs[npc_index];
                        const removed_target = npcVitalsTarget(npc, despawned.id);
                        if (self.simulation.vitals(removed_target) != null) {
                            try self.simulation.submitVitals(.{ .remove = removed_target });
                        }
                        self.unregisterHostNpc(despawned.id);
                        self.force_snapshot = true;
                    }
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

    fn processVitalsOutcomes(self: *AuthorityCore) !void {
        while (self.simulation.pollVitalsOutcome()) |outcome| switch (outcome) {
            .registered => |target| switch (target.kind) {
                .player => {
                    const participant_index = self.findParticipantByCharacter(target.id) orelse
                        return error.UnknownPlayerVitalsRegistration;
                    const participant = &self.participants[participant_index];
                    if (participant.avatar_incarnation != target.incarnation.value or
                        !participant.vitals_pending)
                    {
                        return error.StalePlayerVitalsRegistration;
                    }
                    participant.vitals_pending = false;
                    participant.lifecycle = .alive;
                    participant.death_tick = 0;
                    if (participant.pending_respawn_action) |action| {
                        try self.queueRespawnActionResult(
                            participant_index,
                            action,
                            .respawned,
                        );
                        participant.pending_respawn_action = null;
                        self.respawns +|= 1;
                        try self.publishLifeEvent(.{
                            .avatar = participant.replicated,
                            .incarnation = participant.avatar_incarnation,
                            .health = vitals_contract.default_max_health,
                            .maximum_health = vitals_contract.default_max_health,
                            .state = .alive,
                        });
                    }
                    self.force_snapshot = true;
                },
                .npc => {
                    const npc_index = self.findNpcByPersistent(target.id) orelse
                        return error.UnknownNpcVitalsRegistration;
                    const npc = &self.npcs[npc_index];
                    if (npc.generation != target.incarnation.value or !npc.vitals_pending) {
                        return error.StaleNpcVitalsRegistration;
                    }
                    npc.vitals_pending = false;
                    self.force_snapshot = true;
                },
            },
            .removed => {},
            .damage => |damage| {
                switch (damage.proposal.source.kind) {
                    .player => {
                        const attacker_index = self.findParticipantByCharacter(
                            damage.proposal.source.id,
                        ) orelse return error.UnknownDamageInstigator;
                        const attacker = &self.participants[attacker_index];
                        const action = attacker.pending_melee_action orelse
                            return error.UnexpectedDamageOutcome;
                        if (damage.proposal.correlation !=
                            damageCorrelation(attacker_index, action.sequence))
                        {
                            return error.DamageCorrelationMismatch;
                        }
                        const replicated = self.replicatedVitalsTarget(
                            damage.proposal.target,
                        ) orelse identity.ReplicatedEntityId.invalid;
                        try self.queueDamageResult(attacker_index, action, replicated, damage);
                        if (damage.disposition == .applied) self.melee_hits +|= 1;
                        attacker.pending_melee_action = null;
                    },
                    .npc => {
                        const npc_index = self.findNpcByPersistent(
                            damage.proposal.source.id,
                        ) orelse return error.UnknownDamageInstigator;
                        if (self.npcs[npc_index].generation !=
                            damage.proposal.source.incarnation.value)
                        {
                            return error.StaleNpcDamageInstigator;
                        }
                    },
                }
                self.force_snapshot = true;
            },
            .rejected => return error.AuthorityVitalsCommandRejected,
        };
        while (self.simulation.pollVitalsEvent()) |event| switch (event) {
            .died => |died| try self.processDeathEvent(died),
        };
    }

    fn processDeathEvent(
        self: *AuthorityCore,
        died: vitals_contract.DeathEvent,
    ) !void {
        const instigator = if (died.source.kind == .player)
            if (self.findParticipantByCharacter(died.source.id)) |index|
                participantId(index, self.participants[index].generation)
            else
                null
        else
            null;
        const replicated = self.replicatedVitalsTarget(died.target) orelse
            return error.UnknownDeathTarget;
        try self.publishLifeEvent(.{
            .avatar = replicated,
            .incarnation = died.target.incarnation.value,
            .health = 0,
            .maximum_health = vitals_contract.default_max_health,
            .state = .dead,
            .instigator = instigator,
        });
        switch (died.target.kind) {
            .player => {
                const participant_index = self.findParticipantByCharacter(died.target.id) orelse
                    return error.UnknownPlayerDeathTarget;
                const participant = &self.participants[participant_index];
                if (participant.avatar_incarnation != died.target.incarnation.value or
                    participant.lifecycle != .alive)
                {
                    return error.StalePlayerDeathEvent;
                }
                participant.lifecycle = .dead;
                participant.death_tick = died.authority_tick;
                participant.respawn_available_tick = died.authority_tick +|
                    respawn_cooldown_ticks;
                participant.retain_after_despawn = true;
                participant.despawn_pending = true;
                clearParticipantInputs(participant);
                try self.continueParticipantDespawn(participant_index);
            },
            .npc => {
                const npc_index = self.findNpcByPersistent(died.target.id) orelse
                    return error.UnknownNpcDeathTarget;
                const npc = &self.npcs[npc_index];
                if (npc.despawn_pending) return error.DuplicateNpcDeathEvent;
                npc.despawn_pending = true;
                try self.simulation.submitNpc(.{ .despawn = .{
                    .request_id = npcDeathRequestId(npc_index, npc.generation),
                    .id = died.target.id,
                } });
            },
        }
        self.deaths +|= 1;
        self.force_snapshot = true;
    }

    fn replicatedVitalsTarget(
        self: *const AuthorityCore,
        target: vitals_contract.Target,
    ) ?identity.ReplicatedEntityId {
        return switch (target.kind) {
            .player => if (self.findParticipantByCharacter(target.id)) |index|
                self.participants[index].replicated
            else
                null,
            .npc => if (self.findNpcByPersistent(target.id)) |index|
                self.npcs[index].replicated
            else
                null,
        };
    }

    fn publishSnapshots(self: *AuthorityCore) !void {
        var publication_ceiling: usize = 0;
        for (self.participants) |participant| {
            if (participant.active and participant.connection_index != null and
                !participant.despawn_pending) publication_ceiling += 1;
        }
        if (self.prepared_outbox.len + publication_ceiling >
            budgets.outbound_message_capacity)
        {
            return error.QueueFull;
        }
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
                if (self.simulation.tickIndex() < participant.baseline_eligible_tick) continue;
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
            const vital = self.simulation.vitals(playerVitalsTarget(
                participant,
                participant.character.?,
            )) orelse if (participant.vitals_pending)
                pendingVitalsView(playerVitalsTarget(participant, participant.character.?))
            else
                continue;
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
                .incarnation = participant.avatar_incarnation,
                .health = vital.current_health,
                .maximum_health = vital.maximum_health,
                .life_state = protocolLifeState(vital.life_state),
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
            const vital = self.simulation.vitals(npcVitalsTarget(
                self.npcs[npc_index],
                draw.persistent_id,
            )) orelse if (self.npcs[npc_index].vitals_pending)
                pendingVitalsView(npcVitalsTarget(
                    self.npcs[npc_index],
                    draw.persistent_id,
                ))
            else
                continue;
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
                .incarnation = self.npcs[npc_index].generation,
                .health = vital.current_health,
                .maximum_health = vital.maximum_health,
                .life_state = protocolLifeState(vital.life_state),
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
        for (self.participants, 0..) |*participant, index| {
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
            participant.pending_welcome_delivery_id = 0;
            participant.reconnect_deadline_tick = 0;
            participant.character = null;
            participant.replicated = .invalid;
            participant.avatar_incarnation = participant.generation;
            participant.lifecycle = .spawning;
            participant.vitals_pending = false;
            participant.death_tick = 0;
            participant.respawn_available_tick = 0;
            participant.last_received_input = .{ .value = 0 };
            participant.last_applied_input = .{ .value = 0 };
            clearParticipantInputs(participant);
            participant.driving_vehicle_index = null;
            participant.last_vehicle_action = .{ .value = 0 };
            participant.pending_vehicle_action = null;
            participant.holding_carryable_index = null;
            participant.last_interaction_action = .{ .value = 0 };
            participant.pending_interaction_action = null;
            participant.last_melee_action = .{ .value = 0 };
            participant.pending_melee_action = null;
            participant.melee_cooldown_until_tick = 0;
            participant.last_respawn_action = .{ .value = 0 };
            participant.pending_respawn_action = null;
            participant.interaction_cleanup_pending = false;
            participant.relevance_coord = sandbox_district_recipe.navigation_west_coord;
            participant.baseline_id = 0;
            participant.baseline_acknowledged = 0;
            participant.baseline_sent = false;
            participant.baseline_eligible_tick = 0;
            participant.next_control_delivery_id = 1;
            participant.next_gameplay_delivery_id = 1;
            participant.applied_control_delivery_id = 0;
            participant.applied_gameplay_delivery_id = 0;
            participant.replay_cursor_delivery_id = 0;
            participant.replay_records = @splat(.{});
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

    fn availableParticipantIndex(self: *const AuthorityCore) ?usize {
        for (self.participants, 0..) |participant, index| {
            if (!participant.active) return index;
        }
        return null;
    }

    fn preflightReliablePublication(
        self: *const AuthorityCore,
        connection_index: usize,
        count: usize,
    ) !void {
        if (self.prepared_outbox.len + count > budgets.outbound_message_capacity) {
            return error.QueueFull;
        }
        const connection = self.connections[connection_index];
        const current_tick = self.simulation.tickIndex();
        const used: usize = if (connection.event_quota_tick == current_tick)
            connection.reliable_events_this_tick
        else
            0;
        if (used + count > budgets.max_reliable_events_per_tick) {
            return error.ReliableEventBudgetExceeded;
        }
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
                participant.replay_cursor_delivery_id = 0;
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
        self.defer_replication_this_cycle = true;
        const participant = self.participants[participant_index];
        const delivery_id = try self.queuePrepared(.{
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
                .avatar = participant.replicated,
                .avatar_incarnation = participant.avatar_incarnation,
                .life_state = if (participant.lifecycle == .dead or
                    participant.lifecycle == .respawn_pending)
                    .dead
                else
                    .alive,
            } },
            .delivery = .reliable,
            .lane = .control,
        });
        self.participants[participant_index].pending_welcome_delivery_id = delivery_id;
    }

    fn queueVehicleActionResult(
        self: *AuthorityCore,
        participant_index: usize,
        action: protocol.VehicleAction,
        disposition: protocol.VehicleActionDisposition,
    ) !void {
        try self.queueGameplayResult(participant_index, .{ .vehicle_action_result = .{
            .sequence = action.sequence,
            .vehicle = action.vehicle,
            .action = action.kind,
            .disposition = disposition,
        } });
    }

    fn queueInteractionActionResult(
        self: *AuthorityCore,
        participant_index: usize,
        action: protocol.InteractionAction,
        disposition: protocol.InteractionActionDisposition,
    ) !void {
        try self.queueGameplayResult(participant_index, .{ .interaction_action_result = .{
            .sequence = action.sequence,
            .carryable = action.carryable,
            .action = action.kind,
            .disposition = disposition,
        } });
    }

    fn queueMeleeActionResult(
        self: *AuthorityCore,
        participant_index: usize,
        action: protocol.MeleeAction,
        disposition: protocol.MeleeActionDisposition,
    ) !void {
        try self.queueGameplayResult(participant_index, .{ .melee_action_result = .{
            .sequence = action.sequence,
            .disposition = disposition,
        } });
    }

    fn queueDamageResult(
        self: *AuthorityCore,
        participant_index: usize,
        action: protocol.MeleeAction,
        target: identity.ReplicatedEntityId,
        outcome: vitals_contract.DamageOutcome,
    ) !void {
        try self.queueGameplayResult(participant_index, .{ .melee_action_result = .{
            .sequence = action.sequence,
            .disposition = if (outcome.disposition == .applied) .hit else .invalid_state,
            .target = target,
            .target_incarnation = outcome.proposal.target.incarnation.value,
            .applied_damage = outcome.applied_amount,
            .remaining_health = outcome.remaining_health,
            .killed = outcome.killed,
        } });
    }

    fn queueRespawnActionResult(
        self: *AuthorityCore,
        participant_index: usize,
        action: protocol.RespawnAction,
        disposition: protocol.RespawnActionDisposition,
    ) !void {
        const participant = self.participants[participant_index];
        try self.queueGameplayResult(participant_index, .{ .respawn_action_result = .{
            .sequence = action.sequence,
            .disposition = disposition,
            .avatar = if (disposition == .respawned) participant.replicated else .invalid,
            .incarnation = if (disposition == .respawned)
                participant.avatar_incarnation
            else
                action.dead_incarnation,
        } });
    }

    fn publishLifeEvent(self: *AuthorityCore, event: protocol.LifeEvent) !void {
        for (self.participants, 0..) |participant, participant_index| {
            if (!participant.active) continue;
            try self.queueGameplayResult(participant_index, .{ .life_event = event });
        }
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
        self.defer_replication_this_cycle = true;
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
        _ = try self.queuePrepared(outbound);
    }

    fn queuePrepared(self: *AuthorityCore, outbound: Outbound) !u64 {
        if (!self.publication_preparing) return error.PublicationNotPreparing;
        if (self.prepared_outbox.isFull()) return error.QueueFull;
        var prepared = outbound;
        if (outbound.delivery == .reliable and switch (outbound.message) {
            .rejected, .disconnected => false,
            else => true,
        }) {
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
        if (reliableMessageReceipted(outbound.message)) {
            const participant_index = self.outboundParticipantIndex(outbound) orelse
                return error.UnknownOutboundParticipant;
            const participant = &self.participants[participant_index];
            const next = switch (outbound.lane) {
                .control => &participant.next_control_delivery_id,
                .gameplay => &participant.next_gameplay_delivery_id,
                .input, .snapshot => return error.InvalidReliableLane,
            };
            if (next.* == 0) return error.DeliveryIdExhausted;
            prepared.delivery_id = next.*;
            next.* +%= 1;
        }
        self.prepared_outbox.pushAssumeCapacity(prepared);
        return prepared.delivery_id;
    }

    fn queueGameplayResult(
        self: *AuthorityCore,
        participant_index: usize,
        message: ReplayMessage,
    ) !void {
        const participant = &self.participants[participant_index];
        const record = for (&participant.replay_records) |*candidate| {
            if (!candidate.active) break candidate;
        } else return error.ReliableReplayCapacityReached;
        const delivery_id = participant.next_gameplay_delivery_id;
        if (delivery_id == 0) return error.DeliveryIdExhausted;
        if (participant.connection_index) |connection_index| {
            if (self.connections[connection_index].active) {
                if (self.prepared_outbox.isFull()) return error.QueueFull;
                try self.consumeReliableQuota(connection_index);
                self.prepared_outbox.pushAssumeCapacity(.{
                    .connection = self.connections[connection_index].transport,
                    .message = message.serverMessage(),
                    .delivery = .reliable,
                    .lane = .gameplay,
                    .delivery_id = delivery_id,
                });
            }
        }
        participant.next_gameplay_delivery_id +%= 1;
        record.* = .{
            .active = true,
            .delivery_id = delivery_id,
            .message = message,
        };
    }

    fn prepareReliableReplay(self: *AuthorityCore) !void {
        for (self.participants) |*participant| {
            const connection_index = participant.connection_index orelse continue;
            if (!participant.active or participant.reconnect_confirmation_pending or
                participant.replay_cursor_delivery_id == 0 or
                !self.connections[connection_index].active)
            {
                continue;
            }
            var cursor = participant.replay_cursor_delivery_id;
            while (cursor < participant.next_gameplay_delivery_id) {
                const record = for (participant.replay_records) |candidate| {
                    if (candidate.active and candidate.delivery_id == cursor) break candidate;
                } else return error.ReliableReplayLedgerGap;
                if (self.prepared_outbox.isFull()) break;
                const connection = &self.connections[connection_index];
                const used = if (connection.event_quota_tick == self.simulation.tickIndex())
                    connection.reliable_events_this_tick
                else
                    0;
                if (used >= budgets.max_reliable_events_per_tick - 1) break;
                self.consumeReliableQuota(connection_index) catch break;
                self.prepared_outbox.pushAssumeCapacity(.{
                    .connection = self.connections[connection_index].transport,
                    .message = record.message.serverMessage(),
                    .delivery = .reliable,
                    .lane = .gameplay,
                    .delivery_id = record.delivery_id,
                });
                cursor = record.delivery_id +| 1;
                self.reliable_replays +|= 1;
            }
            participant.replay_cursor_delivery_id = if (cursor >= participant.next_gameplay_delivery_id) 0 else cursor;
        }
    }

    fn consumeReliableQuota(self: *AuthorityCore, connection_index: usize) !void {
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

    fn outboundParticipantIndex(
        self: *const AuthorityCore,
        outbound: Outbound,
    ) ?usize {
        if (self.findConnection(outbound.connection)) |connection_index| {
            if (self.connections[connection_index].participant_index) |index| return index;
        }
        return switch (outbound.message) {
            .welcome => |welcome| if (welcome.participant.index == 0)
                null
            else
                @as(usize, welcome.participant.index) - 1,
            else => null,
        };
    }

    fn queueLive(self: *AuthorityCore, outbound: Outbound) !void {
        try self.outbox.push(outbound);
        self.outbox_high_water = @max(
            self.outbox_high_water,
            @as(u16, @intCast(self.outbox.len)),
        );
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
        for (self.participants) |*participant| {
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
    ) !u64 {
        return self.state().openConnection(transport);
    }

    pub fn transportClosed(
        self: *DedicatedAuthority,
        transport: TransportConnection,
    ) !u64 {
        return self.state().transportClosed(transport);
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

    pub fn beginOutboundLease(self: *DedicatedAuthority) ?OutboundLease {
        return self.state().beginOutboundLease();
    }

    pub fn commitOutboundLease(self: *DedicatedAuthority, generation: u64) !void {
        try self.state().commitOutboundLease(generation);
    }

    pub fn retryOutboundLease(self: *DedicatedAuthority, generation: u64) !void {
        try self.state().retryOutboundLease(generation);
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
    ) !u64 {
        return authorityCore(self.context).openConnection(transport);
    }

    pub fn transportClosed(
        self: EmbeddedSessionRole,
        transport: TransportConnection,
    ) !u64 {
        return authorityCore(self.context).transportClosed(transport);
    }

    pub fn ingest(
        self: EmbeddedSessionRole,
        transport: TransportConnection,
        message: protocol.ClientMessage,
    ) !void {
        try authorityCore(self.context).ingest(transport, message);
    }

    pub fn ingestBytes(
        self: EmbeddedSessionRole,
        transport: TransportConnection,
        bytes: []const u8,
    ) !void {
        try authorityCore(self.context).ingestBytes(transport, bytes);
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

    pub fn beginOutboundLease(self: EmbeddedSessionRole) ?OutboundLease {
        return authorityCore(self.context).beginOutboundLease();
    }

    pub fn commitOutboundLease(self: EmbeddedSessionRole, generation: u64) !void {
        try authorityCore(self.context).commitOutboundLease(generation);
    }

    pub fn retryOutboundLease(self: EmbeddedSessionRole, generation: u64) !void {
        try authorityCore(self.context).retryOutboundLease(generation);
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

fn horizontalDistanceSquared(lhs: [3]f32, rhs: [3]f32) f32 {
    const x = rhs[0] - lhs[0];
    const z = rhs[2] - lhs[2];
    return x * x + z * z;
}

fn considerMeleeTarget(
    selected: *?MeleeTarget,
    source: [3]f32,
    forward: [2]f32,
    candidate: MeleeTarget,
    target_position: [3]f32,
) void {
    if (candidate.distance_squared <= 0.0001 or
        candidate.distance_squared > melee_range * melee_range)
    {
        return;
    }
    const inverse_distance = 1.0 / @sqrt(candidate.distance_squared);
    const direction = [2]f32{
        (target_position[0] - source[0]) * inverse_distance,
        (target_position[2] - source[2]) * inverse_distance,
    };
    if (direction[0] * forward[0] + direction[1] * forward[1] <
        melee_minimum_forward_dot)
    {
        return;
    }
    if (selected.* == null or candidate.distance_squared < selected.*.?.distance_squared or
        (candidate.distance_squared == selected.*.?.distance_squared and
            persistentLessThan(candidate.persistent, selected.*.?.persistent)))
    {
        selected.* = candidate;
    }
}

fn persistentLessThan(lhs: engine.PersistentId, rhs: engine.PersistentId) bool {
    return lhs.namespace < rhs.namespace or
        (lhs.namespace == rhs.namespace and lhs.local < rhs.local);
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
        @as(u64, record.avatar_incarnation),
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

fn playerVitalsTarget(
    participant: ParticipantSlot,
    id: engine.PersistentId,
) vitals_contract.Target {
    return .{
        .kind = .player,
        .id = id,
        .incarnation = .{ .value = participant.avatar_incarnation },
    };
}

fn npcVitalsTarget(npc: NpcSlot, id: engine.PersistentId) vitals_contract.Target {
    return .{
        .kind = .npc,
        .id = id,
        .incarnation = .{ .value = npc.generation },
    };
}

fn protocolLifeState(state: vitals_contract.LifeState) protocol.AvatarLifeState {
    return switch (state) {
        .alive => .alive,
        .dead => .dead,
    };
}

fn pendingVitalsView(target: vitals_contract.Target) vitals_contract.View {
    return .{
        .target = target,
        .current_health = vitals_contract.default_max_health,
        .maximum_health = vitals_contract.default_max_health,
        .life_state = .alive,
        .death_tick = 0,
    };
}

fn damageCorrelation(index: usize, sequence: identity.ActionSequence) u64 {
    return 0x5331_3000_0000_0000 |
        (@as(u64, @intCast(index + 1)) << 32) |
        @as(u64, sequence.value);
}

fn npcDeathRequestId(index: usize, generation: u16) u64 {
    return 0x5331_3001_0000_0000 |
        (@as(u64, generation) << 16) |
        @as(u64, @intCast(index + 1));
}

fn decodeNpcDeathRequestId(value: u64) ?struct { index: usize, generation: u16 } {
    if (value & 0xffff_ffff_0000_0000 != 0x5331_3001_0000_0000) return null;
    const raw_index: u16 = @truncate(value);
    if (raw_index == 0 or raw_index > budgets.max_npcs) return null;
    return .{
        .index = raw_index - 1,
        .generation = @truncate(value >> 16),
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

/// Test code consumes a lease immediately because it has no physical adapter.
/// Product adapters must commit only after their own acceptance point.
fn takeOutboundForTest(owner: anytype) ?Outbound {
    if (owner.beginOutboundLease() == null and
        owner.diagnostics().mailbox_occupancy != 0)
    {
        owner.tick() catch return null;
    }
    const lease = owner.beginOutboundLease() orelse return null;
    owner.commitOutboundLease(lease.generation) catch unreachable;
    return lease.outbound;
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
    const initial = takeOutboundForTest(first.session()).?.message.welcome;
    try std.testing.expect(initial.reconnect.isValid());
    try std.testing.expect(!reconnectCredentialsEqual(
        initial.reconnect,
        legacyReconnectGuess(initial.session, account, initial.participant),
    ));

    const other_account = identity.AccountId{ .value = 42 };
    _ = try first.session().openConnection(.{ .value = 2 });
    try first.session().ingest(.{ .value = 2 }, .{ .hello = .{ .account = other_account } });
    const other = takeOutboundForTest(first.session()).?.message.welcome;
    try std.testing.expect(!reconnectCredentialsEqual(initial.reconnect, other.reconnect));

    _ = try first.session().transportClosed(initial_transport);

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
        takeOutboundForTest(first.session()).?.message.rejected.reason,
    );

    _ = try first.session().openConnection(.{ .value = 5 });
    try first.session().ingest(.{ .value = 5 }, .{ .hello = .{
        .account = account,
        .external_identity = external_identity,
        .reconnect = legacyReconnectGuess(initial.session, account, initial.participant),
    } });
    try std.testing.expectEqual(
        protocol.RejectionReason.reconnect_expired,
        takeOutboundForTest(first.session()).?.message.rejected.reason,
    );

    _ = try first.session().openConnection(.{ .value = 6 });
    try first.session().ingest(.{ .value = 6 }, .{ .hello = .{
        .account = account,
        .external_identity = external_identity,
        .reconnect = initial.reconnect,
    } });
    const rotated_outbound = takeOutboundForTest(first.session()).?;
    const rotated = rotated_outbound.message.welcome;
    try std.testing.expectEqual(initial.participant, rotated.participant);
    try std.testing.expect(!reconnectCredentialsEqual(initial.reconnect, rotated.reconnect));

    try first.session().tick();
    var reconnect_baseline: ?protocol.RelevanceBaseline = null;
    while (takeOutboundForTest(first.session())) |outbound| {
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
    try first.session().ingest(.{ .value = 6 }, .{ .delivery_receipt = .{
        .session = rotated.session,
        .participant = rotated.participant,
        .lane = .control,
        .delivery_id = rotated_outbound.delivery_id,
    } });

    _ = try first.session().transportClosed(.{ .value = 6 });
    _ = try first.session().openConnection(.{ .value = 7 });
    try first.session().ingest(.{ .value = 7 }, .{ .hello = .{
        .account = account,
        .external_identity = external_identity,
        .reconnect = initial.reconnect,
    } });
    try std.testing.expectEqual(
        protocol.RejectionReason.reconnect_expired,
        takeOutboundForTest(first.session()).?.message.rejected.reason,
    );

    _ = try first.session().openConnection(.{ .value = 8 });
    try first.session().ingest(.{ .value = 8 }, .{ .hello = .{
        .account = account,
        .external_identity = external_identity,
        .reconnect = rotated.reconnect,
    } });
    const rotated_again = takeOutboundForTest(first.session()).?.message.welcome;
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
    const other_session = takeOutboundForTest(second.session()).?.message.welcome;
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
    const initial = takeOutboundForTest(authority.session()).?.message.welcome;
    _ = try authority.session().transportClosed(.{ .value = 1 });

    // The first rotated Welcome is lost. The client can still retry with the
    // credential it actually possesses.
    _ = try authority.session().openConnection(.{ .value = 2 });
    try authority.session().ingest(.{ .value = 2 }, .{ .hello = .{
        .account = account,
        .reconnect = initial.reconnect,
    } });
    const first_rotation = takeOutboundForTest(authority.session()).?.message.welcome;
    _ = try authority.session().transportClosed(.{ .value = 2 });

    _ = try authority.session().openConnection(.{ .value = 3 });
    try authority.session().ingest(.{ .value = 3 }, .{ .hello = .{
        .account = account,
        .reconnect = initial.reconnect,
    } });
    const second_rotation = takeOutboundForTest(authority.session()).?.message.welcome;
    try std.testing.expect(!reconnectCredentialsEqual(
        first_rotation.reconnect,
        second_rotation.reconnect,
    ));
    _ = try authority.session().transportClosed(.{ .value = 3 });

    // A client that did receive the latest Welcome can also reconnect with
    // the current credential. Only that presented value is retained.
    _ = try authority.session().openConnection(.{ .value = 4 });
    try authority.session().ingest(.{ .value = 4 }, .{ .hello = .{
        .account = account,
        .reconnect = second_rotation.reconnect,
    } });
    _ = takeOutboundForTest(authority.session()).?.message.welcome;
    _ = try authority.session().transportClosed(.{ .value = 4 });
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
        takeOutboundForTest(authority.session()).?.message.rejected.reason,
    );

    // The one retained credential remains a recovery path until an explicit
    // application receipt confirms the reconnect Welcome.
    _ = try authority.session().openConnection(.{ .value = 6 });
    try authority.session().ingest(.{ .value = 6 }, .{ .hello = .{
        .account = account,
        .reconnect = second_rotation.reconnect,
    } });
    const confirmed_outbound = takeOutboundForTest(authority.session()).?;
    const confirmed_rotation = confirmed_outbound.message.welcome;
    try authority.session().tick();
    var baseline: ?protocol.RelevanceBaseline = null;
    while (takeOutboundForTest(authority.session())) |outbound| {
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
    try authority.session().ingest(.{ .value = 6 }, .{ .delivery_receipt = .{
        .session = confirmed_rotation.session,
        .participant = confirmed_rotation.participant,
        .lane = .control,
        .delivery_id = confirmed_outbound.delivery_id,
    } });
    try authority.session().tick();
    try std.testing.expect(!core.participants[participant_index].reconnect_confirmation_pending);
    try std.testing.expect(!core.participants[participant_index].retained_reconnect.isValid());
    while (takeOutboundForTest(authority.session()) != null) {}
    _ = try authority.session().transportClosed(.{ .value = 6 });

    _ = try authority.session().openConnection(.{ .value = 7 });
    try authority.session().ingest(.{ .value = 7 }, .{ .hello = .{
        .account = account,
        .reconnect = second_rotation.reconnect,
    } });
    try std.testing.expectEqual(
        protocol.RejectionReason.reconnect_expired,
        takeOutboundForTest(authority.session()).?.message.rejected.reason,
    );
}

test "pending publication prevents reconnect mutation before a new cycle" {
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
    const initial = takeOutboundForTest(authority.session()).?.message.welcome;
    _ = try authority.session().transportClosed(.{ .value = 1 });
    _ = try authority.session().openConnection(reconnect_transport);
    try authority.session().tick();
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
    try authority.session().ingest(reconnect_transport, .{ .hello = .{
        .account = account,
        .reconnect = initial.reconnect,
    } });
    try std.testing.expectError(
        error.AuthorityOutputsPending,
        authority.session().tick(),
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
    const recovered = takeOutboundForTest(authority.session()).?.message.welcome;
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
    const initial = takeOutboundForTest(authority.session()).?.message.welcome;
    _ = try authority.session().transportClosed(.{ .value = 1 });

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
        takeOutboundForTest(authority.session()).?.message.rejected.reason,
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
    const reconnected = takeOutboundForTest(authority.session()).?.message.welcome;
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
    _ = takeOutboundForTest(authority.session()).?.message.welcome;
    try std.testing.expectError(
        error.InjectedAuthorityCycleFault,
        core.tickImpl(null, .ingress_freeze),
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

    _ = try authority.session().transportClosed(participant_transport);
    try authority.session().stop();
    const shutdown = takeOutboundForTest(authority.session()) orelse
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
    try authority.session().ingestAtUnixTime(transport, .{ .hello = .{
        .account = account,
        .external_identity = external_identity,
        .join_authorization = authorization,
    } }, 10);
    try authority.session().tick();
    try std.testing.expectEqual(
        protocol.RejectionReason.session_full,
        takeOutboundForTest(authority.session()).?.message.rejected.reason,
    );
    try std.testing.expectEqual(@as(u16, 0), authority.session().diagnostics().active_participants);
    const connection_index = core.findConnection(transport) orelse
        return error.MissingNonceCapacityConnection;
    try std.testing.expect(core.connections[connection_index].participant_index == null);
    try std.testing.expectEqual(@as(usize, 0), core.outbox.len);
    try std.testing.expectEqual(
        simulation_before.entity_count,
        authority.developer().diagnostics().entity_count,
    );
    try std.testing.expect(std.meta.eql(nonces_before, core.used_admission_nonces));

    const expired_slot: usize = 37;
    core.used_admission_nonces[expired_slot].expires_at_unix_seconds = 9;
    try authority.session().ingestAtUnixTime(transport, .{ .hello = .{
        .account = account,
        .external_identity = external_identity,
        .join_authorization = authorization,
    } }, 10);
    try std.testing.expect(takeOutboundForTest(authority.session()).?.message == .welcome);
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
}

test "fresh admission failures preserve participant nonce and credential state" {
    const room_secret: protocol.AdmissionSecret = @splat(0x7c);
    const Fixture = struct {
        fn create(namespace: u64, secret: protocol.AdmissionSecret) !*EmbeddedAuthority {
            return initTestEmbeddedAuthority(
                testEmbeddedCoreConfig(namespace, .automatic),
                .{ .room_admission = .{
                    .room_id = 71,
                    .authority_id = 9_001,
                    .room_generation = 3,
                    .secret = secret,
                } },
                0x71,
            );
        }

        fn hello(secret: protocol.AdmissionSecret, nonce: u64) protocol.Hello {
            const account = identity.AccountId{ .value = nonce };
            const external = protocol.ExternalIdentity{
                .provider = .steam,
                .subject = nonce + 10_000,
            };
            return .{
                .account = account,
                .external_identity = external,
                .join_authorization = testRoomAuthorization(
                    secret,
                    account,
                    external,
                    nonce,
                    100,
                ),
            };
        }

        fn expectUnchanged(
            core: *AuthorityCore,
            connection_index: usize,
            nonces: [budgets.admission_nonce_history_capacity]UsedAdmissionNonce,
            credential_serial: u64,
        ) !void {
            try std.testing.expectEqual(@as(u16, 0), core.diagnostics().active_participants);
            try std.testing.expect(core.connections[connection_index].participant_index == null);
            try std.testing.expect(std.meta.eql(nonces, core.used_admission_nonces));
            try std.testing.expectEqual(credential_serial, core.credential_issuer.next_serial);
        }
    };

    {
        const authority = try Fixture.create(0x454d_4413, room_secret);
        defer authority.deinit();
        const core = embeddedAuthorityCore(authority);
        const connection_index = @as(usize, (try core.applyConnectionOpened(.{
            .value = 1,
        })).index) - 1;
        core.publication_preparing = true;
        core.credential_issuer.next_serial = std.math.maxInt(u64);
        const nonces = core.used_admission_nonces;
        const credential_serial = core.credential_issuer.next_serial;
        try std.testing.expectError(
            error.CredentialIssuerExhausted,
            core.ingestHello(connection_index, Fixture.hello(room_secret, 1)),
        );
        try Fixture.expectUnchanged(core, connection_index, nonces, credential_serial);
    }

    {
        const authority = try Fixture.create(0x454d_4414, room_secret);
        defer authority.deinit();
        const core = embeddedAuthorityCore(authority);
        const connection_index = @as(usize, (try core.applyConnectionOpened(.{
            .value = 2,
        })).index) - 1;
        core.publication_preparing = true;
        for (0..character_contract.max_pending_commands) |index| {
            try core.simulation.submitCharacter(.{ .spawn = .{
                .request_id = 10_000 + index,
                .position = .{ 0, 0, 0 },
            } });
        }
        const nonces = core.used_admission_nonces;
        const credential_serial = core.credential_issuer.next_serial;
        try std.testing.expectError(
            error.CharacterCommandQueueFull,
            core.ingestHello(connection_index, Fixture.hello(room_secret, 2)),
        );
        try Fixture.expectUnchanged(core, connection_index, nonces, credential_serial);
    }

    {
        const authority = try Fixture.create(0x454d_4415, room_secret);
        defer authority.deinit();
        const core = embeddedAuthorityCore(authority);
        const transport = TransportConnection{ .value = 3 };
        const connection_index = @as(usize, (try core.applyConnectionOpened(transport)).index) - 1;
        core.publication_preparing = true;
        for (0..budgets.outbound_message_capacity) |_| {
            try core.prepared_outbox.push(.{
                .connection = transport,
                .message = .{ .rejected = .{ .reason = .invalid_state } },
                .delivery = .reliable,
                .lane = .control,
            });
        }
        const nonces = core.used_admission_nonces;
        const credential_serial = core.credential_issuer.next_serial;
        try std.testing.expectError(
            error.QueueFull,
            core.ingestHello(connection_index, Fixture.hello(room_secret, 3)),
        );
        try Fixture.expectUnchanged(core, connection_index, nonces, credential_serial);
    }
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
        const expected_completed_tick: u64 = if (@intFromEnum(stage) <= @intFromEnum(authority_diagnostics.CycleStage.simulation)) 0 else 1;
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

test "publication failure rolls back unpublished derivatives and durable disposition" {
    const authority = try initTestEmbeddedAuthority(
        testEmbeddedCoreConfig(0x454d_4416, .host_managed),
        .{},
        0x16,
    );
    defer authority.deinit();
    const core = embeddedAuthorityCore(authority);
    const transport = TransportConnection{ .value = 1 };
    const connection_index = @as(usize, (try core.applyConnectionOpened(transport)).index) - 1;
    const participant_index = core.allocateParticipant() orelse
        return error.MissingPublicationTestParticipant;
    core.connections[connection_index].participant_index = @intCast(participant_index);
    core.participants[participant_index].connection_index = @intCast(connection_index);
    core.participants[participant_index].replicated = .{
        .index = @intCast(participant_index + 1),
        .generation = core.participants[participant_index].generation,
    };
    core.participants[participant_index].baseline_id = 1;
    core.participants[participant_index].baseline_eligible_tick = 0;
    core.force_snapshot = true;
    const sequence_before = core.replication[participant_index].next_sequence;
    const source = try authority.persistence().issueSource();
    const request_id = try source.request();

    try std.testing.expectError(
        error.InjectedAuthorityCycleFault,
        core.tickImpl(null, .publication),
    );
    try std.testing.expect(!core.participants[participant_index].baseline_sent);
    try std.testing.expectEqual(
        sequence_before,
        core.replication[participant_index].next_sequence,
    );
    try std.testing.expectEqual(@as(usize, 0), core.outbox.len);
    try std.testing.expectEqual(@as(usize, 0), core.prepared_outbox.len);
    try std.testing.expect(core.prepared_durable_result == null);
    try std.testing.expectError(error.AuthorityFaulted, source.take(request_id));
}

test "unexpected real feature outcome faults the outcome-drain stage without publication" {
    const authority = try initTestEmbeddedAuthority(
        testEmbeddedCoreConfig(0x454d_4417, .automatic),
        .{},
        0x17,
    );
    defer authority.deinit();
    const core = embeddedAuthorityCore(authority);
    try core.simulation.submitCharacter(.{ .spawn = .{
        .request_id = 1,
        .position = .{ 0, 0, 0 },
    } });

    try std.testing.expectError(
        error.UnexpectedCharacterSpawnOutcome,
        authority.session().tick(),
    );
    const diagnostics = authority.session().diagnostics();
    try std.testing.expectEqual(@as(u64, 1), diagnostics.tick);
    try std.testing.expectEqual(
        authority_diagnostics.CycleStage.outcome_drain,
        diagnostics.last_cycle.failed_stage.?,
    );
    try std.testing.expectEqual(@as(u8, 4), diagnostics.last_cycle.count);
    try std.testing.expectEqual(@as(usize, 0), core.outbox.len);
    try std.testing.expectEqual(@as(usize, 0), core.prepared_outbox.len);
    try std.testing.expectError(error.AuthorityFaulted, authority.session().tick());
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
    try std.testing.expect(takeOutboundForTest(authority.session()).?.message == .welcome);
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
    while (takeOutboundForTest(authority.session())) |outbound| {
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
        source.observe(std.testing.allocator),
    );
    try authority.session().tick();
    try std.testing.expectError(
        error.AuthorityOutputsPending,
        source.observe(std.testing.allocator),
    );
    _ = authority.crates().pollOutcome() orelse
        return error.MissingPersistenceSafePointOutcome;
    const bytes = try source.observe(std.testing.allocator);
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(bytes.len != 0);
}

test "durable capture is decided at cycle stage seven and released by its owner" {
    const authority = try EmbeddedAuthority.init(
        std.testing.allocator,
        testEmbeddedCoreConfig(0x454d_4411, .host_managed),
    );
    defer authority.deinit();
    const source = try authority.persistence().issueSource();
    const request_id = try source.request();
    try std.testing.expect((try source.take(request_id)) == null);
    try authority.session().tick();
    const disposition = (try source.take(request_id)) orelse
        return error.MissingDurableCaptureDisposition;
    switch (disposition) {
        .captured => |bytes| {
            defer source.release(bytes);
            try std.testing.expect(bytes.len != 0);
        },
        .deferred => return error.UnexpectedDurableCaptureDeferral,
        .failed => |err| return err,
    }
    try std.testing.expectEqual(
        authority_diagnostics.CycleStage.durable_disposition,
        authority.session().diagnostics().last_cycle.stages[6],
    );
}

test "durable capture returns a typed stage-seven deferral while publication is pending" {
    const authority = try initTestEmbeddedAuthority(
        testEmbeddedCoreConfig(0x454d_4412, .host_managed),
        .{},
        0x12,
    );
    defer authority.deinit();
    const source = try authority.persistence().issueSource();
    const transport = TransportConnection{ .value = 1 };
    _ = try authority.session().openConnection(transport);
    try authority.session().ingest(transport, .{ .hello = .{
        .account = .{ .value = 1 },
    } });
    const request_id = try source.request();

    try authority.session().tick();
    const disposition = (try source.take(request_id)) orelse
        return error.MissingDurableDeferral;
    try std.testing.expectEqual(
        snapshot_source.Deferral.authority_outputs,
        disposition.deferred,
    );
    try std.testing.expect(authority.session().beginOutboundLease() != null);
}

fn testTakeAndAcknowledgeBaseline(
    authority: *DedicatedAuthority,
    transport: TransportConnection,
) !protocol.Snapshot {
    var baseline: ?protocol.RelevanceBaseline = null;
    while (takeOutboundForTest(authority)) |outbound| switch (outbound.message) {
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
    const welcome_one = takeOutboundForTest(authority).?.message.welcome;
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
    _ = takeOutboundForTest(authority).?.message.welcome;
    try authority.tick();
    var saw_two = false;
    while (takeOutboundForTest(authority)) |outbound| switch (outbound.message) {
        .snapshot => |snapshot| saw_two = saw_two or snapshot.character_count == 2,
        .relevance_baseline => |baseline| saw_two = saw_two or baseline.snapshot.character_count == 2,
        else => {},
    };
    try std.testing.expect(saw_two);

    _ = try authority.transportClosed(.{ .value = 101 });
    _ = try authority.openConnection(.{ .value = 303 });
    try authority.ingest(.{ .value = 303 }, .{ .hello = .{
        .account = .{ .value = 1 },
        .reconnect = welcome_one.reconnect,
    } });
    const reconnected = takeOutboundForTest(authority).?.message.welcome;
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
    const welcome = takeOutboundForTest(authority).?.message.welcome;
    try authority.tick();
    while (takeOutboundForTest(authority) != null) {}
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
    try authority.tick();
    try std.testing.expectEqual(@as(u64, 1), authority.diagnostics().stale_inputs);
    try std.testing.expectEqual(@as(u64, 0), authority.diagnostics().rejected_messages);
    try std.testing.expectEqual(@as(u16, 1), authority.diagnostics().ingress_entries);
    var ingress: [1]AcceptedIngress = undefined;
    try std.testing.expectEqual(@as(usize, 1), authority.copyAcceptedIngress(&ingress));
    try std.testing.expectEqual(@as(u32, 1), ingress[0].sequence.value);
}

test "authoritative melee kills once and explicit respawn replaces avatar incarnation" {
    const authority = try DedicatedAuthority.init(std.testing.allocator);
    defer authority.deinit();
    const attacker_transport = TransportConnection{ .value = 801 };
    const victim_transport = TransportConnection{ .value = 802 };
    _ = try authority.openConnection(attacker_transport);
    try authority.ingest(attacker_transport, .{ .hello = .{
        .account = .{ .value = 801 },
    } });
    _ = try authority.openConnection(victim_transport);
    try authority.ingest(victim_transport, .{ .hello = .{
        .account = .{ .value = 802 },
    } });
    try authority.tick();
    var attacker_welcome: ?protocol.Welcome = null;
    var victim_welcome: ?protocol.Welcome = null;
    while (takeOutboundForTest(authority)) |outbound| switch (outbound.message) {
        .welcome => |welcome| if (outbound.connection.value == attacker_transport.value) {
            attacker_welcome = welcome;
        } else if (outbound.connection.value == victim_transport.value) {
            victim_welcome = welcome;
        },
        else => {},
    };
    const attacker = attacker_welcome orelse return error.MissingAttackerWelcome;
    const victim = victim_welcome orelse return error.MissingVictimWelcome;
    for (0..2) |_| {
        try authority.tick();
        while (takeOutboundForTest(authority) != null) {}
    }
    try authority.ingest(attacker_transport, .{ .input = .{
        .session = attacker.session,
        .participant = attacker.participant,
        .sequence = .{ .value = 1 },
        .target_tick = authority.state().simulation.tickIndex() +| 1,
        .move = .{ 0, 0 },
        .facing_yaw = std.math.pi / 2.0,
        .jump_pressed = false,
    } });
    try authority.tick();
    while (takeOutboundForTest(authority) != null) {}

    const attacker_index: usize = attacker.participant.index - 1;
    const victim_index: usize = victim.participant.index - 1;
    const first_incarnation = authority.state().participants[victim_index].avatar_incarnation;
    for (1..4) |raw_sequence| {
        const sequence = identity.ActionSequence{ .value = @intCast(raw_sequence) };
        try authority.ingest(attacker_transport, .{ .melee_action = .{
            .session = attacker.session,
            .participant = attacker.participant,
            .sequence = sequence,
            .avatar_incarnation = authority.state().participants[attacker_index].avatar_incarnation,
            .target_tick = authority.state().simulation.tickIndex() +| 1,
        } });
        try authority.tick();
        var result: ?protocol.MeleeActionResult = null;
        var deaths: u8 = 0;
        while (takeOutboundForTest(authority)) |outbound| switch (outbound.message) {
            .melee_action_result => |value| if (outbound.connection.value ==
                attacker_transport.value)
            {
                result = value;
            },
            .life_event => |value| if (value.state == .dead) {
                deaths += 1;
            },
            else => {},
        };
        const applied = result orelse return error.MissingMeleeResult;
        try std.testing.expectEqual(protocol.MeleeActionDisposition.hit, applied.disposition);
        try std.testing.expectEqual(
            @as(u16, if (raw_sequence == 3) 32 else melee_damage),
            applied.applied_damage,
        );
        try std.testing.expectEqual(raw_sequence == 3, applied.killed);
        if (raw_sequence == 3) {
            try std.testing.expectEqual(@as(u8, 2), deaths);
        } else {
            try std.testing.expectEqual(@as(u8, 0), deaths);
        }
        if (raw_sequence != 3) for (0..melee_cooldown_ticks) |_| {
            try authority.tick();
            while (takeOutboundForTest(authority) != null) {}
        };
    }
    for (0..3) |_| {
        try authority.tick();
        while (takeOutboundForTest(authority) != null) {}
    }
    try std.testing.expectEqual(PlayerLifecycle.dead, authority.state().participants[victim_index].lifecycle);
    try std.testing.expect(authority.state().participants[victim_index].character == null);

    _ = try authority.transportClosed(victim_transport);
    try authority.tick();
    while (takeOutboundForTest(authority) != null) {}
    const reconnected_transport = TransportConnection{ .value = 803 };
    _ = try authority.openConnection(reconnected_transport);
    try authority.ingest(reconnected_transport, .{ .hello = .{
        .account = .{ .value = 802 },
        .reconnect = victim.reconnect,
    } });
    try authority.tick();
    var dead_welcome: ?protocol.Welcome = null;
    while (takeOutboundForTest(authority)) |outbound| switch (outbound.message) {
        .welcome => |welcome| if (outbound.connection.value == reconnected_transport.value) {
            dead_welcome = welcome;
        },
        else => {},
    };
    const reconnected = dead_welcome orelse return error.MissingDeadReconnectWelcome;
    try std.testing.expectEqual(protocol.AvatarLifeState.dead, reconnected.life_state);
    try std.testing.expectEqual(first_incarnation, reconnected.avatar_incarnation);

    while (authority.state().simulation.tickIndex() <
        authority.state().participants[victim_index].respawn_available_tick)
    {
        try authority.tick();
        while (takeOutboundForTest(authority) != null) {}
    }
    try authority.ingest(reconnected_transport, .{ .respawn_action = .{
        .session = reconnected.session,
        .participant = reconnected.participant,
        .sequence = .{ .value = 1 },
        .dead_incarnation = first_incarnation,
    } });
    var respawn_result: ?protocol.RespawnActionResult = null;
    for (0..3) |_| {
        try authority.tick();
        while (takeOutboundForTest(authority)) |outbound| switch (outbound.message) {
            .respawn_action_result => |value| if (outbound.connection.value ==
                reconnected_transport.value)
            {
                respawn_result = value;
            },
            else => {},
        };
    }
    const respawned = respawn_result orelse return error.MissingRespawnResult;
    try std.testing.expectEqual(protocol.RespawnActionDisposition.respawned, respawned.disposition);
    try std.testing.expect(respawned.incarnation != first_incarnation);
    try std.testing.expectEqual(PlayerLifecycle.alive, authority.state().participants[victim_index].lifecycle);
    try std.testing.expect(authority.state().participants[victim_index].character != null);
    var ingress_records: [16]AcceptedIngress = undefined;
    const ingress_count = authority.copyAcceptedIngress(&ingress_records);
    var melee_records: u8 = 0;
    var respawn_records: u8 = 0;
    for (ingress_records[0..ingress_count]) |record| switch (record.kind) {
        .melee => melee_records += 1,
        .respawn => respawn_records += 1,
        else => {},
    };
    try std.testing.expectEqual(@as(u8, 3), melee_records);
    try std.testing.expectEqual(@as(u8, 1), respawn_records);
}

test "authority defers admitted input until its declared target tick" {
    const authority = try DedicatedAuthority.init(std.testing.allocator);
    defer authority.deinit();
    const transport = TransportConnection{ .value = 1 };
    _ = try authority.openConnection(transport);
    try authority.tick();
    try authority.ingest(transport, .{ .hello = .{
        .account = .{ .value = 1 },
    } });
    const welcome = takeOutboundForTest(authority).?.message.welcome;
    try authority.tick();
    while (takeOutboundForTest(authority) != null) {}

    const connection_index = authority.state().findConnection(transport) orelse
        return error.MissingTestConnection;
    const participant_index = authority.state().connections[connection_index].participant_index orelse
        return error.MissingTestParticipant;
    const character = authority.state().participants[participant_index].character orelse
        return error.MissingTestCharacter;
    const before = try authority.state().simulation.character(character);
    // One cycle first admits the frozen mailbox batch; the two following
    // cycles must still precede the declared application tick.
    const first_target_tick = authority.state().simulation.tickIndex() + 4;
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
    try authority.tick();
    while (takeOutboundForTest(authority) != null) {}
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
        while (takeOutboundForTest(authority) != null) {}
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
    try authority.tick();
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
    try std.testing.expect(takeOutboundForTest(authority) == null);
}

test "outbound lease retry preserves the exact publication head" {
    const authority = try DedicatedAuthority.init(std.testing.allocator);
    defer authority.deinit();
    const transport = TransportConnection{ .value = 1 };
    _ = try authority.openConnection(transport);
    try authority.ingest(transport, .{ .hello = .{ .account = .{ .value = 1 } } });
    try authority.tick();

    const first = authority.beginOutboundLease() orelse return error.MissingOutboundLease;
    try std.testing.expect(first.outbound.message == .welcome);
    try authority.retryOutboundLease(first.generation);
    const retry = authority.beginOutboundLease() orelse return error.MissingRetriedLease;
    try std.testing.expectEqual(first.generation, retry.generation);
    try std.testing.expect(std.meta.eql(first.outbound, retry.outbound));
    try authority.commitOutboundLease(retry.generation);
    try std.testing.expect(authority.beginOutboundLease() == null);
    try std.testing.expectError(
        error.StaleOutboundLease,
        authority.commitOutboundLease(retry.generation),
    );
}

test "accepted gameplay result replays after transport loss until application receipt" {
    const authority = try initTestEmbeddedAuthority(
        testEmbeddedCoreConfig(0x454d_4410, .host_managed),
        .{},
        0x88,
    );
    defer authority.deinit();
    const session = authority.session();
    const first_transport = TransportConnection{ .value = 1 };
    _ = try session.openConnection(first_transport);
    try session.ingest(first_transport, .{ .hello = .{ .account = .{ .value = 17 } } });
    try session.tick();
    const initial_lease = session.beginOutboundLease() orelse return error.MissingInitialWelcome;
    const initial_welcome = initial_lease.outbound.message.welcome;
    try session.commitOutboundLease(initial_lease.generation);

    const core = embeddedAuthorityCore(authority);
    const participant_index = @as(usize, initial_welcome.participant.index) - 1;
    core.publication_preparing = true;
    try core.queueGameplayResult(participant_index, .{ .melee_action_result = .{
        .sequence = .{ .value = 1 },
        .disposition = .hit,
        .target = .{ .index = 17, .generation = 1 },
        .target_incarnation = 1,
        .applied_damage = 34,
        .remaining_health = 66,
    } });
    core.publishPrepared();
    core.publication_preparing = false;

    const accepted = session.beginOutboundLease() orelse return error.MissingGameplayResult;
    const gameplay_delivery_id = accepted.outbound.delivery_id;
    try std.testing.expect(gameplay_delivery_id != 0);
    try session.commitOutboundLease(accepted.generation);

    _ = try session.transportClosed(first_transport);
    const reconnect_transport = TransportConnection{ .value = 2 };
    _ = try session.openConnection(reconnect_transport);
    try session.ingest(reconnect_transport, .{ .hello = .{
        .account = .{ .value = 17 },
        .reconnect = initial_welcome.reconnect,
    } });
    try session.tick();
    const welcome_lease = session.beginOutboundLease() orelse return error.MissingReconnectWelcome;
    const reconnect_welcome = welcome_lease.outbound.message.welcome;
    const reconnect_welcome_delivery_id = welcome_lease.outbound.delivery_id;
    try session.commitOutboundLease(welcome_lease.generation);
    try std.testing.expect(session.beginOutboundLease() == null);
    try session.ingest(reconnect_transport, .{ .delivery_receipt = .{
        .session = reconnect_welcome.session,
        .participant = reconnect_welcome.participant,
        .lane = .control,
        .delivery_id = reconnect_welcome_delivery_id,
    } });
    try session.tick();
    const replay = session.beginOutboundLease() orelse return error.MissingGameplayReplay;
    try std.testing.expect(replay.outbound.message == .melee_action_result);
    try std.testing.expectEqual(gameplay_delivery_id, replay.outbound.delivery_id);
    try session.commitOutboundLease(replay.generation);
    while (session.beginOutboundLease()) |remaining| {
        try session.commitOutboundLease(remaining.generation);
    }

    try session.ingest(reconnect_transport, .{ .delivery_receipt = .{
        .session = reconnect_welcome.session,
        .participant = reconnect_welcome.participant,
        .lane = .gameplay,
        .delivery_id = gameplay_delivery_id,
    } });
    try session.tick();
    for (core.participants[participant_index].replay_records) |record| {
        try std.testing.expect(!record.active);
    }
}

test "reconnect replay drains a full bounded ledger across quota-safe cycles" {
    const authority = try initTestEmbeddedAuthority(
        testEmbeddedCoreConfig(0x454d_4418, .host_managed),
        .{},
        0x18,
    );
    defer authority.deinit();
    const session = authority.session();
    const first_transport = TransportConnection{ .value = 1 };
    _ = try session.openConnection(first_transport);
    try session.ingest(first_transport, .{ .hello = .{ .account = .{ .value = 18 } } });
    try session.tick();
    const initial = session.beginOutboundLease() orelse return error.MissingInitialWelcome;
    const initial_welcome = initial.outbound.message.welcome;
    try session.commitOutboundLease(initial.generation);

    const core = embeddedAuthorityCore(authority);
    const participant_index = @as(usize, initial_welcome.participant.index) - 1;
    const participant = &core.participants[participant_index];
    for (&participant.replay_records, 0..) |*record, index| {
        const delivery_id = index + 1;
        record.* = .{
            .active = true,
            .delivery_id = delivery_id,
            .message = .{ .vehicle_action_result = .{
                .sequence = .{ .value = @intCast(delivery_id) },
                .vehicle = .{ .index = 17, .generation = 1 },
                .action = .enter,
                .disposition = .entered,
            } },
        };
    }
    participant.next_gameplay_delivery_id = participant.replay_records.len + 1;
    const replay_record_count = participant.replay_records.len;

    _ = try session.transportClosed(first_transport);
    const reconnect_transport = TransportConnection{ .value = 2 };
    _ = try session.openConnection(reconnect_transport);
    try session.ingest(reconnect_transport, .{ .hello = .{
        .account = .{ .value = 18 },
        .reconnect = initial_welcome.reconnect,
    } });
    try session.tick();
    const reconnect = session.beginOutboundLease() orelse return error.MissingReconnectWelcome;
    const reconnect_welcome = reconnect.outbound.message.welcome;
    const welcome_delivery_id = reconnect.outbound.delivery_id;
    try session.commitOutboundLease(reconnect.generation);
    try session.ingest(reconnect_transport, .{ .delivery_receipt = .{
        .session = reconnect_welcome.session,
        .participant = reconnect_welcome.participant,
        .lane = .control,
        .delivery_id = welcome_delivery_id,
    } });

    var expected_delivery_id: u64 = 1;
    var replayed: usize = 0;
    while (replayed < replay_record_count) {
        try session.tick();
        var replayed_this_cycle: usize = 0;
        while (session.beginOutboundLease()) |lease| {
            if (lease.outbound.lane == .gameplay) {
                try std.testing.expectEqual(expected_delivery_id, lease.outbound.delivery_id);
                expected_delivery_id += 1;
                replayed += 1;
                replayed_this_cycle += 1;
            }
            try session.commitOutboundLease(lease.generation);
        }
        try std.testing.expect(replayed_this_cycle <=
            budgets.max_reliable_events_per_tick - 1);
    }
    try std.testing.expectEqual(
        replay_record_count + 1,
        expected_delivery_id,
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        core.participants[participant_index].replay_cursor_delivery_id,
    );
}

test "authority owns vehicle enter drive exit and dynamic seat projection" {
    const authority = try DedicatedAuthority.init(std.testing.allocator);
    defer authority.deinit();
    const transport = TransportConnection{ .value = 1 };
    _ = try authority.openConnection(transport);
    try authority.ingest(transport, .{ .hello = .{
        .account = .{ .value = 1 },
    } });
    const welcome = takeOutboundForTest(authority).?.message.welcome;
    try authority.tick();
    const initial = try testTakeAndAcknowledgeBaseline(authority, transport);
    try std.testing.expectEqual(@as(u8, 1), initial.vehicle_count);
    const vehicle = initial.vehicles[0].entity;

    for (0..180) |_| {
        try authority.tick();
        while (takeOutboundForTest(authority) != null) {}
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
    while (takeOutboundForTest(authority)) |outbound| switch (outbound.message) {
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
        while (takeOutboundForTest(authority)) |outbound| switch (outbound.message) {
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
    while (takeOutboundForTest(authority)) |outbound| switch (outbound.message) {
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
    const welcome = takeOutboundForTest(authority).?.message.welcome;
    try authority.tick();
    const initial = try testTakeAndAcknowledgeBaseline(authority, transport);
    const vehicle = initial.vehicles[0].entity;
    for (0..180) |_| {
        try authority.tick();
        while (takeOutboundForTest(authority) != null) {}
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
        while (takeOutboundForTest(authority) != null) {}
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
    while (takeOutboundForTest(authority) != null) {}
    try authority.stop();
    const outbound = takeOutboundForTest(authority).?;
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
    const welcome = takeOutboundForTest(authority).?.message.welcome;
    try authority.tick();
    while (takeOutboundForTest(authority) != null) {}
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
    }
    try authority.tick();
    try std.testing.expectEqual(@as(u64, 1), authority.diagnostics().quota_violations);
    try std.testing.expectEqual(@as(u16, 0), authority.diagnostics().active_connections);
    try std.testing.expectEqual(
        protocol.RejectionReason.quota_exceeded,
        takeOutboundForTest(authority).?.message.rejected.reason,
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
        takeOutboundForTest(authority).?.message.rejected.reason,
    );
    try std.testing.expectEqual(@as(u16, 0), authority.diagnostics().active_connections);
    try std.testing.expectEqual(@as(u16, 0), authority.diagnostics().active_participants);

    _ = try authority.openConnection(.{ .value = 2 });
    try authority.rejectOversized(.{ .value = 2 });
    try std.testing.expectEqual(
        protocol.RejectionReason.oversized,
        takeOutboundForTest(authority).?.message.rejected.reason,
    );
    try std.testing.expectEqual(@as(u16, 0), authority.diagnostics().active_connections);

    _ = try authority.openConnection(.{ .value = 3 });
    try authority.ingestBytes(.{ .value = 3 }, &.{ 0, 1, 2 });
    try std.testing.expectEqual(
        protocol.RejectionReason.malformed,
        takeOutboundForTest(authority).?.message.rejected.reason,
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
    _ = takeOutboundForTest(authority).?.message.welcome;
    try authority.tick();
    while (takeOutboundForTest(authority) != null) {}

    _ = try authority.openConnection(.{ .value = 2 });
    try authority.ingest(.{ .value = 2 }, .{ .hello = .{
        .account = .{ .value = 7 },
    } });
    try std.testing.expectEqual(
        protocol.RejectionReason.unauthorized,
        takeOutboundForTest(authority).?.message.rejected.reason,
    );
    try std.testing.expectEqual(@as(u16, 1), authority.diagnostics().active_participants);

    _ = try authority.openConnection(.{ .value = 3 });
    try authority.tick();
    const primary_connection = authority.state().findConnection(.{ .value = 1 }) orelse
        return error.MissingPrimaryTimeoutConnection;
    authority.state().connections[primary_connection].last_message_tick =
        std.math.maxInt(u64);
    for (0..budgets.handshake_timeout_ticks) |_| try authority.tick();
    try std.testing.expectEqual(
        protocol.RejectionReason.invalid_state,
        takeOutboundForTest(authority).?.message.rejected.reason,
    );

    authority.state().connections[primary_connection].last_message_tick = 0;
    while (authority.diagnostics().tick <= budgets.idle_timeout_ticks) {
        try authority.tick();
    }
    try std.testing.expectEqual(
        protocol.DisconnectReason.timeout,
        takeOutboundForTest(authority).?.message.disconnected,
    );
    try std.testing.expectEqual(@as(u16, 1), authority.diagnostics().reconnecting_participants);
}
