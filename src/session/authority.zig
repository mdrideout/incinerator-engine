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
const npc_encounter_contract = @import("npc_encounter_contract");
const population_contract = @import("population_contract");
const sandbox_population_catalog = @import("sandbox_population_catalog");
const vitals_contract = @import("vitals_contract");
const ranged_combat_contract = @import("ranged_combat_contract");
const ranged_combat = @import("ranged_combat");
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
const sandbox_replay = @import("sandbox_replay");

pub const NavigationGateState = sandbox.NavigationGateState;

comptime {
    if (protocol.vehicle_wheel_count != engine.physics.vehicle_wheel_count) {
        @compileError("session and engine vehicle wheel counts must agree");
    }
}

/// One collision-safe slot per advertised participant. Initial admission
/// searches from the participant index and explicitly reserves its choice so
/// multiple joins in the same authority cycle cannot select the same point.
const automatic_spawn_candidates = [_][3]f32{
    .{ -3, 0, 0 },  .{ -1, 0, 0 },  .{ 1, 0, 0 },  .{ 3, 0, 0 },
    .{ 6, 0, 0 },   .{ -7, 0, 1 },  .{ -1, 0, 2 }, .{ 5, 0, 2 },
    .{ -3, 0, 7 },  .{ -1, 0, 7 },  .{ 1, 0, 7 },  .{ 3, 0, 7 },
    .{ -3, 0, -7 }, .{ -1, 0, -7 }, .{ 1, 0, -7 }, .{ 3, 0, -7 },
};

comptime {
    if (automatic_spawn_candidates.len != budgets.max_participants) {
        @compileError("automatic spawn slots must cover participant capacity exactly");
    }
}

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
    weapon_action_result: protocol.WeaponActionResult,
    shot_event: protocol.ShotEvent,
    respawn_action_result: protocol.RespawnActionResult,
    life_event: protocol.LifeEvent,

    fn serverMessage(self: ReplayMessage) protocol.ServerMessage {
        return switch (self) {
            .vehicle_action_result => |value| .{ .vehicle_action_result = value },
            .interaction_action_result => |value| .{ .interaction_action_result = value },
            .melee_action_result => |value| .{ .melee_action_result = value },
            .weapon_action_result => |value| .{ .weapon_action_result = value },
            .shot_event => |value| .{ .shot_event = value },
            .respawn_action_result => |value| .{ .respawn_action_result = value },
            .life_event => |value| .{ .life_event = value },
        };
    }
};

const ReliableReplayRecord = struct {
    active: bool = false,
    transmitted: bool = false,
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

    // A transport may close every admitted connection before the next tick.
    // Keep those lifecycle notices admissible even when network control traffic
    // fills its share of the existing mailbox. Excess bytes stay in GNS.
    fn canOpenConnection(self: *const IngressMailbox) bool {
        return self.control.len < budgets.inbound_control_capacity - budgets.max_participants;
    }

    fn transportIngressAvailable(self: *const IngressMailbox) bool {
        return self.canOpenConnection() and
            self.gameplay.len < budgets.inbound_gameplay_capacity and
            self.input.len < budgets.inbound_input_capacity and
            self.notice.len < budgets.inbound_notice_capacity;
    }

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
        .vehicle_action,
        .interaction_action,
        .melee_action,
        .weapon_action,
        .respawn_action,
        => .gameplay,
        .input, .vehicle_input => .input,
    };
}

fn reliableMessageReceipted(message: protocol.ServerMessage) bool {
    return switch (message) {
        .welcome => true,
        .vehicle_action_result,
        .interaction_action_result,
        .melee_action_result,
        .weapon_action_result,
        .shot_event,
        .respawn_action_result,
        .life_event,
        => true,
        .snapshot, .relevance_baseline, .rejected, .disconnected => false,
    };
}

test "transport admission preserves close capacity and resumes after a tick" {
    var mailbox = IngressMailbox{};
    for (0..budgets.inbound_control_capacity - budgets.max_participants) |_| {
        try std.testing.expect(mailbox.transportIngressAvailable());
        _ = try mailbox.push(.control, .{ .connection_opened = .{ .value = 1 } });
    }
    try std.testing.expect(!mailbox.transportIngressAvailable());
    try std.testing.expect(!mailbox.canOpenConnection());
    for (0..budgets.max_participants) |_| {
        _ = try mailbox.push(.control, .{ .connection_closed = .{ .value = 1 } });
    }
    var scratch = CycleScratch{};
    scratch.freeze(&mailbox);
    try std.testing.expect(mailbox.transportIngressAvailable());
    for (0..budgets.inbound_notice_capacity) |_| {
        _ = try mailbox.push(.notice, .{ .malformed = .{ .value = 1 } });
    }
    try std.testing.expect(!mailbox.transportIngressAvailable());
    scratch.freeze(&mailbox);
    for (0..budgets.inbound_input_capacity) |_| {
        _ = try mailbox.push(.input, .{ .decoded = .{
            .transport = .{ .value = 1 },
            .message = .{ .input = .{
                .session = .{ .value = 1 },
                .participant = .{ .index = 1, .generation = 1 },
                .sequence = .{ .value = 1 },
                .target_tick = 1,
                .move = .{ 0, 0 },
                .facing_yaw = 0,
                .jump_pressed = false,
            } },
            .admission_time_unix_seconds = null,
        } });
    }
    try std.testing.expect(!mailbox.transportIngressAvailable());
    scratch.freeze(&mailbox);
    try std.testing.expect(mailbox.transportIngressAvailable());
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

/// Presentation-only authority projection retained after the simulation
/// character is torn down. The proxy carries no controller, collision, or
/// vitals authority; it makes the canonical dead lifecycle visible until a
/// replacement incarnation is fully registered.
const PlayerDeathProxy = struct {
    owner: district_contract.ChunkCoord,
    state: protocol.CharacterState,
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
    pending_welcome_delivery_id: u64 = 0,
    reconnect_deadline_tick: u64 = 0,
    character: ?engine.PersistentId = null,
    replicated: identity.ReplicatedEntityId = .invalid,
    avatar_incarnation: u16 = 1,
    lifecycle: PlayerLifecycle = .spawning,
    vitals_pending: bool = false,
    death_tick: u64 = 0,
    respawn_available_tick: u64 = 0,
    death_proxy: ?PlayerDeathProxy = null,
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
    pending_melee_target: ?vitals_contract.Target = null,
    melee_cooldown_until_tick: u64 = 0,
    weapon: ranged_combat_contract.State = .{},
    last_weapon_action: identity.ActionSequence = .{ .value = 0 },
    pending_weapon_action: ?protocol.WeaponAction = null,
    pending_weapon_shot: ?PendingShot = null,
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
    gameplay_consumer_retired: bool = false,
    exit_pending: bool = false,
    spawn_pending: bool = false,
    reserved_spawn_position: ?[3]f32 = null,
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

fn hasPendingVehicleEnter(participant: *const ParticipantSlot) bool {
    const action = participant.pending_vehicle_action orelse return false;
    return action.kind == .enter;
}

fn hasIncomingPendingMelee(
    participants: []const ParticipantSlot,
    target: vitals_contract.Target,
) bool {
    for (participants) |participant| {
        const pending = participant.pending_melee_target orelse continue;
        if (std.meta.eql(pending, target)) return true;
    }
    return false;
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
    population_replacement_spawn_pending: bool = false,
    death_proxy: ?NpcDeathProxy = null,
    population_member: ?population_contract.PopulationMemberId = null,
    population_actor_generation: u16 = 0,
    population_spawn_correlation: u64 = 0,
    population_spawn_slot: ?population_contract.SpawnSlotId = null,
    population_goal_correlation: u64 = 0,
    population_activity_sequence: u64 = 0,
    population_destination: ?npc_contract.DestinationId = null,
};

const NpcDeathProxy = struct {
    owner: district_contract.ChunkCoord,
    state: protocol.NpcState,
};

const NpcPopulationProjection = struct {
    member: u16 = 0,
    role: protocol.NpcPopulationRole = .unassigned,
    combat_disposition: protocol.NpcCombatDisposition = .unassigned,
    activity_kind: protocol.NpcActivityKind = .none,
    activity_state: protocol.NpcActivityState = .unassigned,
};

const melee_damage: u16 = 34;
const melee_range: f32 = 2.75;
const melee_minimum_forward_dot: f32 = 0.2;
const melee_cooldown_ticks: u64 = budgets.authority_tick_hz / 2;
const respawn_cooldown_ticks: u64 = budgets.authority_tick_hz * 3;
const handgun_config = ranged_combat_contract.Config{};

const MeleeTarget = struct {
    kind: vitals_contract.TargetKind,
    persistent: engine.PersistentId,
    replicated: identity.ReplicatedEntityId,
    incarnation: u16,
    distance_squared: f32,
};

const RangedTarget = struct {
    kind: vitals_contract.TargetKind,
    persistent: engine.PersistentId,
    replicated: identity.ReplicatedEntityId,
    incarnation: u16,
    hit_fraction: f32,
};

const ShotRay = struct {
    origin: [3]f32,
    endpoint: [3]f32,
    impact: [3]f32,
    target: ?RangedTarget,
};

const PendingShot = struct {
    target: vitals_contract.Target,
    replicated: identity.ReplicatedEntityId,
    origin: [3]f32,
    impact: [3]f32,
    authority_tick: u64,
};

const ShotResolution = struct {
    origin: [3]f32,
    impact: [3]f32,
    target: identity.ReplicatedEntityId = .invalid,
    target_incarnation: u16 = 0,
    applied_damage: u16 = 0,
    remaining_health: u16 = 0,
    killed: bool = false,
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

/// Per-client NPC publication policy. The current bounded sandbox cohort is
/// deliberately projected in full so human tests never mistake interest
/// culling for gameplay disappearance. Bounded interest remains an explicit
/// future scale policy rather than an implicit product default.
pub const NpcInterestMode = enum {
    full_world,
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
    npc_interest: NpcInterestMode,
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

pub const npc_interest_enter_distance: f32 = 20;
pub const npc_interest_exit_distance: f32 = 24;
pub const npc_interest_exit_grace_ticks: u64 = 30;

pub const NpcInterestReason = enum {
    excluded,
    full_world,
    same_district,
    encounter,
    proximity_enter,
    proximity_retained,
    grace,
};

pub const NpcInterestView = struct {
    included: bool,
    reason: NpcInterestReason,
    evaluated_tick: u64,
    grace_until_tick: u64,
    observer_position: [3]f32,
    npc_position: [3]f32,
    observer_district: district_contract.ChunkCoord,
    owner_district: district_contract.ChunkCoord,
    distance_squared_xz: f32,
    encounter_relevant: bool,
};

/// Authority-owned explanation for the deliberately bounded object cohort.
/// Vehicles and carryables are currently cheap enough to replicate in full;
/// district coordinates remain evidence, not an accidental visibility gate.
pub const ObjectInterestReason = enum {
    bounded_world,
    controlled,
    held,
    district_dormant,
};

pub const ObjectInterestView = struct {
    included: bool,
    reason: ObjectInterestReason,
    evaluated_tick: u64,
    baseline_id: u32,
    snapshot_sequence: u32,
    observer_position: [3]f32,
    object_position: [3]f32,
    observer_district: district_contract.ChunkCoord,
    owner_district: district_contract.ChunkCoord,
    distance_squared_xz: f32,
};

pub const ReplicatedObjectIdentity = struct {
    replicated: identity.ReplicatedEntityId,
    persistent: engine.PersistentId,
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

const NpcInterestState = struct {
    included: bool = false,
    reason: NpcInterestReason = .excluded,
    evaluated_tick: u64 = 0,
    grace_until_tick: u64 = 0,
    observer_position: [3]f32 = .{ 0, 0, 0 },
    npc_position: [3]f32 = .{ 0, 0, 0 },
    observer_district: district_contract.ChunkCoord =
        sandbox_district_recipe.navigation_west_coord,
    owner_district: district_contract.ChunkCoord =
        sandbox_district_recipe.navigation_west_coord,
    distance_squared_xz: f32 = 0,
    encounter_relevant: bool = false,

    fn view(self: NpcInterestState) NpcInterestView {
        return .{
            .included = self.included,
            .reason = self.reason,
            .evaluated_tick = self.evaluated_tick,
            .grace_until_tick = self.grace_until_tick,
            .observer_position = self.observer_position,
            .npc_position = self.npc_position,
            .observer_district = self.observer_district,
            .owner_district = self.owner_district,
            .distance_squared_xz = self.distance_squared_xz,
            .encounter_relevant = self.encounter_relevant,
        };
    }
};

const ObjectInterestState = struct {
    included: bool = false,
    reason: ObjectInterestReason = .bounded_world,
    evaluated_tick: u64 = 0,
    baseline_id: u32 = 0,
    snapshot_sequence: u32 = 0,
    observer_position: [3]f32 = .{ 0, 0, 0 },
    object_position: [3]f32 = .{ 0, 0, 0 },
    observer_district: district_contract.ChunkCoord =
        sandbox_district_recipe.navigation_west_coord,
    owner_district: district_contract.ChunkCoord =
        sandbox_district_recipe.navigation_west_coord,
    distance_squared_xz: f32 = 0,

    fn view(self: ObjectInterestState) ObjectInterestView {
        return .{
            .included = self.included,
            .reason = self.reason,
            .evaluated_tick = self.evaluated_tick,
            .baseline_id = self.baseline_id,
            .snapshot_sequence = self.snapshot_sequence,
            .observer_position = self.observer_position,
            .object_position = self.object_position,
            .observer_district = self.observer_district,
            .owner_district = self.owner_district,
            .distance_squared_xz = self.distance_squared_xz,
        };
    }
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
    vehicle_interest: [budgets.max_vehicles]ObjectInterestState = @splat(.{}),
    carryable_interest: [budgets.max_carryables]ObjectInterestState = @splat(.{}),
    npc_interest: [budgets.max_npcs]NpcInterestState = @splat(.{}),
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
    npc_navigation_transitions: ObservationQueue(npc_contract.NavigationTransition) = .{},
    population_transitions: ObservationQueue(population_contract.Transition) = .{},
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
            self.npc_events.len == 0 and
            self.npc_navigation_transitions.len == 0 and
            self.population_transitions.len == 0;
    }

    fn pending(self: *const HostObservations) u32 {
        const total = self.crate_outcomes.len +
            self.character_outcomes.len + self.character_events.len +
            self.vehicle_outcomes.len + self.vehicle_events.len +
            self.district_outcomes.len + self.district_events.len +
            self.interaction_outcomes.len + self.npc_outcomes.len +
            self.npc_events.len + self.npc_navigation_transitions.len +
            self.population_transitions.len;
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
        weapon_equip_toggle = 9,
        weapon_fire = 10,
        weapon_reload = 11,
    };

    /// Stable semantic digest with absolute authority ticks rebased to the
    /// caller's scenario origin. Operational diagnostics pass zero; virtual
    /// time acceptance runners pass their post-bootstrap start tick so their
    /// retained ingress evidence uses one relative time domain.
    pub fn fingerprintFromTickOrigin(
        self: AcceptedIngress,
        seed: u64,
        tick_origin: u64,
    ) u64 {
        var result = seed;
        inline for (.{
            self.admitted_tick -| tick_origin,
            self.account.value,
            @as(u64, self.participant.index),
            @as(u64, self.participant.generation),
            @as(u64, self.connection.index),
            @as(u64, self.connection.generation),
            @as(u64, self.sequence.value),
            @as(u64, self.action_sequence.value),
            self.target_tick -| tick_origin,
            @as(u64, @as(u32, @bitCast(self.move[0]))),
            @as(u64, @as(u32, @bitCast(self.move[1]))),
            @as(u64, @as(u32, @bitCast(self.facing_yaw))),
            @as(u64, @intFromBool(self.jump_pressed)),
            @as(u64, @intFromEnum(self.kind)),
            @as(u64, self.vehicle.index),
            @as(u64, self.vehicle.generation),
            @as(u64, self.carryable.index),
            @as(u64, self.carryable.generation),
            @as(u64, self.avatar_incarnation),
            @as(u64, @as(u32, @bitCast(self.vehicle_control[0]))),
            @as(u64, @as(u32, @bitCast(self.vehicle_control[1]))),
            @as(u64, @as(u32, @bitCast(self.vehicle_control[2]))),
            @as(u64, @as(u32, @bitCast(self.vehicle_control[3]))),
        }) |value| {
            var stable: u64 = value;
            result = std.hash.Wyhash.hash(result, std.mem.asBytes(&stable));
        }
        return result;
    }
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
    npc_interest_mode: NpcInterestMode,
    population_enabled: bool,
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
    slow_gameplay_consumers_retired: u64 = 0,
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
    weapon_actions_admitted: u64 = 0,
    firearm_hits: u64 = 0,
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
    active_districts: [sandbox_district_recipe.installed_coords.len]bool = @splat(false),
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
            .npc_interest_mode = core_config.npc_interest,
            .population_enabled = core_config.simulation.authored_population,
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
        for (&authority.npcs, 0..) |*npc, index| {
            npc.replicated.index = @intCast(
                budgets.max_participants + budgets.max_vehicles +
                    budgets.max_carryables + index + 1,
            );
            if (core_config.simulation.authored_population and
                index < population_contract.ordinary_member_count)
            {
                npc.population_member = .{ .value = @intCast(index + 1) };
                npc.population_actor_generation = 1;
                npc.generation = 1;
                npc.replicated.generation = 1;
            }
        }
        if (core_config.simulation.authored_population) {
            try authority.simulation.enablePopulation(.{});
        }
        if (core_config.world_bootstrap == .dedicated_fixture) {
            authority.vehicles[0] = .{
                .spawn_pending = true,
                .generation = 1,
                .replicated = .{
                    .index = @intCast(budgets.max_participants + 1),
                    .generation = 1,
                },
            };
            try authority.simulation.submitVehicle(.{
                .spawn = .{
                    .request_id = vehicleSpawnRequestId(0, 1),
                    // Face the fixture down the authored west-to-east route. The
                    // identity rotation drove directly out of the route's south
                    // edge after only four metres.
                    .chassis = .{ .pose = .{
                        .position = .{ -1.5, 2, -4 },
                        .rotation = .{ 0, -0.70710677, 0, 0.70710677 },
                    } },
                },
            });
            authority.carryables[0] = .{
                .generation = 1,
                .replicated = .{
                    .index = @intCast(
                        budgets.max_participants + budgets.max_vehicles + 1,
                    ),
                    .generation = 1,
                },
            };
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
        if (!self.mailbox.canOpenConnection()) return error.IngressClassCapacityReached;
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
                participant.pending_melee_target != null or
                participant.pending_weapon_action != null or
                participant.pending_weapon_shot != null or
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
            .weapon_action => |action| try self.ingestWeaponAction(connection_index, action),
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
        try self.advanceWeaponStates();
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
        const current_tick = self.simulation.tickIndex();
        try self.expireConnections(current_tick);
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
        try self.processNpcEncounterCues();
        if (self.population_enabled) {
            // A pending durable request establishes a bounded capture barrier:
            // finish work already admitted by the population owner, but do not
            // perpetually schedule its next step before stage-seven capture can
            // observe a quiescent simulation boundary.
            if (self.durable_requests.pending == null) {
                try self.simulation.stepPopulation();
            }
            try self.processPopulationIntents();
            while (self.simulation.pollPopulationTransition()) |transition| {
                self.retainObservation(
                    &self.observations.population_transitions,
                    transition,
                );
            }
        }
    }

    fn processNpcEncounterCues(self: *AuthorityCore) !void {
        while (self.simulation.pollNpcEncounterCue()) |cue| {
            switch (cue) {
                .state_changed => |changed| {
                    const npc_index = self.findNpcByPersistent(changed.npc.id) orelse
                        return error.UnknownNpcEncounterCue;
                    const npc = self.npcs[npc_index];
                    const member = npc.population_member orelse {
                        self.force_snapshot = true;
                        continue;
                    };
                    if (changed.previous == .patrolling and
                        changed.current != .patrolling)
                    {
                        try self.simulation.populationInterrupt(
                            member,
                            changed.npc.id,
                        );
                    } else if (changed.current == .patrolling and
                        changed.previous != .patrolling)
                    {
                        try self.simulation.populationResume(
                            member,
                            changed.npc.id,
                        );
                    }
                },
                .target_changed,
                .attack_started,
                .attack_resolved,
                .hit_reaction,
                .died,
                => {},
            }
            self.force_snapshot = true;
        }
    }

    fn processPopulationIntents(self: *AuthorityCore) !void {
        while (self.simulation.peekPopulationIntent()) |intent| switch (intent) {
            .spawn => |spawn| {
                const npc_index = try populationNpcIndex(spawn.member);
                const npc = &self.npcs[npc_index];
                if (npc.population_member == null or
                    !population_contract.PopulationMemberId.eql(
                        npc.population_member.?,
                        spawn.member,
                    ) or
                    npc.active or npc.spawn_pending or npc.despawn_pending or
                    npc.population_spawn_correlation != 0 or
                    npc.population_actor_generation != spawn.actor_generation)
                {
                    return error.InvalidPopulationSpawnState;
                }
                const member = sandbox_population_catalog.memberDefinition(
                    spawn.member,
                ) orelse return error.PopulationMemberNotFound;
                const slot = sandbox_population_catalog.spawnSlotDefinition(
                    spawn.preferred_slot,
                ) orelse return error.PopulationSpawnSlotNotFound;
                if (!slot.roles.accepts(member.role)) {
                    return error.PopulationSpawnRoleMismatch;
                }
                if ((try self.simulation.navigationNodePosition(slot.anchor)) == null) {
                    try self.simulation.populationDeferSpawn(
                        spawn.member,
                        spawn.actor_generation,
                        .district_inactive,
                    );
                    try self.simulation.commitPopulationIntent(intent);
                    continue;
                }
                var reservations: [population_contract.decisions_per_tick][3]f32 = undefined;
                var reservation_count: usize = 0;
                for (self.npcs, 0..) |candidate, candidate_index| {
                    if (candidate_index == npc_index or
                        !candidate.spawn_pending or
                        candidate.population_spawn_slot == null)
                    {
                        continue;
                    }
                    const candidate_slot =
                        sandbox_population_catalog.spawnSlotDefinition(
                            candidate.population_spawn_slot.?,
                        ) orelse return error.PopulationSpawnSlotNotFound;
                    if (reservation_count == reservations.len) {
                        return error.PopulationSpawnReservationCapacityReached;
                    }
                    reservations[reservation_count] = candidate_slot.position;
                    reservation_count += 1;
                }
                const retry_reason = try self.simulation.populationSpawnRetryReason(
                    slot.position,
                    spawn.replacement,
                    reservations[0..reservation_count],
                );
                if (retry_reason != .none) {
                    try self.simulation.populationDeferSpawn(
                        spawn.member,
                        spawn.actor_generation,
                        retry_reason,
                    );
                    try self.simulation.commitPopulationIntent(intent);
                    continue;
                }
                try self.simulation.submitNpc(.{ .spawn = .{
                    .request_id = spawn.correlation_id,
                    .position = slot.position,
                    .facing_yaw = try engine.transform.normalizeFacingYaw(
                        slot.facing_yaw,
                    ),
                    .anchor = slot.anchor,
                    .hostile_to_players = member.combat_disposition == .hostile_to_players,
                    .goal = .hold,
                } });
                npc.generation = spawn.actor_generation;
                npc.replicated.generation = spawn.actor_generation;
                npc.spawn_pending = true;
                npc.population_replacement_spawn_pending = spawn.replacement;
                npc.population_spawn_correlation = spawn.correlation_id;
                npc.population_spawn_slot = spawn.preferred_slot;
                try self.simulation.commitPopulationIntent(intent);
            },
            .set_destination => |destination| {
                const npc_index = try populationNpcIndex(destination.member);
                const npc = &self.npcs[npc_index];
                if (npc.population_member == null or
                    !population_contract.PopulationMemberId.eql(
                        npc.population_member.?,
                        destination.member,
                    ) or
                    npc.population_actor_generation != destination.actor_generation or
                    !npc.active or npc.persistent == null or
                    !std.meta.eql(npc.persistent.?, destination.actor) or
                    npc.population_goal_correlation != 0)
                {
                    return error.InvalidPopulationDestinationState;
                }
                try self.simulation.submitNpc(.{ .set_goal = .{
                    .request_id = destination.correlation_id,
                    .id = destination.actor,
                    .goal = .{ .navigate_to = destination.destination },
                } });
                npc.population_goal_correlation = destination.correlation_id;
                npc.population_activity_sequence = destination.activity_sequence;
                npc.population_destination = destination.destination;
                try self.simulation.commitPopulationIntent(intent);
            },
        };
    }

    fn npcPopulationProjection(
        self: *const AuthorityCore,
        slot: NpcSlot,
    ) !NpcPopulationProjection {
        const member_id = slot.population_member orelse return .{};
        const member = self.simulation.populationMember(member_id) orelse
            return error.PopulationMemberNotFound;
        const definition = sandbox_population_catalog.memberDefinition(member_id) orelse
            return error.PopulationMemberNotFound;
        const program = sandbox_population_catalog.programDefinition(
            definition.program,
        ) orelse return error.PopulationProgramNotFound;
        if (member.program_cursor >= program.step_count) {
            return error.InvalidPopulationProgramCursor;
        }
        const step = program.stepSlice()[member.program_cursor];
        return .{
            .member = member_id.value,
            .role = switch (definition.role) {
                .resident => .resident,
                .worker => .worker,
                .visitor => .visitor,
            },
            .combat_disposition = switch (definition.combat_disposition) {
                .passive => .passive,
                .hostile_to_players => .hostile_to_players,
            },
            .activity_kind = switch (step.kind) {
                .commute => .commute,
                .shop => .shop,
                .visit => .visit,
                .idle => .idle,
            },
            .activity_state = switch (member.activity_state) {
                .selecting => .selecting,
                .waiting_for_slot => .waiting_for_slot,
                .traveling => .traveling,
                .dwelling => .dwelling,
                .completing => .completing,
                .interrupted => .interrupted,
                .vacant => .vacant,
                .replacement_pending => .replacement_pending,
            },
        };
    }

    fn extractReplication(self: *AuthorityCore) !void {
        try self.prepareReliableReplay();
        // Reliable derivatives represent accepted effects and must drain. Once
        // they and every other durable prerequisite are quiet, avoid creating
        // a fresh ordinary state projection solely to make stage seven defer
        // again. The next normal cycle republishes the captured state.
        if (self.durable_requests.pending != null and
            self.prepared_outbox.len == 0 and self.durableDeferral() == null)
        {
            self.force_snapshot = true;
            return;
        }
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
            durableSaveFailure(err);
        self.prepared_durable_result = .{
            .request_id = request_id,
            .disposition = disposition,
        };
    }

    fn durableSaveFailure(err: anyerror) snapshot_source.Disposition {
        return switch (err) {
            // Authored population membership and its actor lifecycle are
            // published by separate simulation systems. A capture can land in
            // the real, one-cycle boundary where the member is live but its
            // actor records have not converged yet. That is pending session
            // work, not a corrupt snapshot or a terminal persistence failure.
            error.PopulationActorLifecycleIncomplete,
            error.PopulationOutputsPending,
            error.PopulationTransactionPending,
            => .{ .deferred = .session_work },
            else => .{ .failed = err },
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
                participant.pending_melee_target != null or
                participant.pending_weapon_action != null or
                participant.pending_weapon_shot != null or
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
            .slow_gameplay_consumers_retired = self.slow_gameplay_consumers_retired,
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
            .weapon_actions_admitted = self.weapon_actions_admitted,
            .firearm_hits = self.firearm_hits,
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
        const planned_spawn: ?[3]f32 = if (self.participant_spawn == .automatic)
            try self.selectInitialSpawnPosition(participant_index) orelse {
                try self.rejectConnection(connection_index, .session_full, true);
                return;
            }
        else
            null;
        const planned_participant = participantId(participant_index, next_generation);
        const credential_serial_before = self.credential_issuer.next_serial;
        const reconnect = try self.issueReconnectCredential(
            hello.account,
            external_identity,
            planned_participant,
        );
        if (planned_spawn) |spawn_position| {
            self.simulation.submitCharacter(.{ .spawn = .{
                .request_id = spawnRequestId(participant_index, next_generation),
                .position = spawn_position,
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
            participant.reserved_spawn_position = planned_spawn;
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
                    participant.holding_carryable_index != null or
                    participant.pending_melee_action != null or
                    hasIncomingPendingMelee(
                        self.participants[0..],
                        playerVitalsTarget(participant.*, character),
                    ))
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
                .purpose = .player_requested,
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
        if (participant.driving_vehicle_index != null or
            hasPendingVehicleEnter(participant))
        {
            try self.queueMeleeActionResult(participant_index, action, .invalid_state);
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
        const pending_target = vitals_contract.Target{
            .kind = target.?.kind,
            .id = target.?.persistent,
            .incarnation = .{ .value = target.?.incarnation },
        };
        try self.simulation.submitVitals(.{ .damage = .{
            .source = .{
                .kind = .player,
                .id = character,
                .incarnation = .{ .value = participant.avatar_incarnation },
                .action_sequence = action.sequence.value,
            },
            .target = pending_target,
            .cause = .melee,
            .authority_tick = tick_index +| 1,
            .correlation = damageCorrelation(participant_index, action.sequence),
            .base_amount = melee_damage,
            .ordinal = 1,
        } });
        participant.pending_melee_action = action;
        participant.pending_melee_target = pending_target;
        self.accepted_messages +|= 1;
    }

    fn ingestWeaponAction(
        self: *AuthorityCore,
        connection_index: usize,
        action: protocol.WeaponAction,
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
        if (!gameplay_admission.actionIsNewer(participant.last_weapon_action, action.sequence)) {
            return;
        }
        participant.last_weapon_action = action.sequence;
        if (action.avatar_incarnation != participant.avatar_incarnation) {
            try self.queueWeaponActionResult(participant_index, action, .wrong_incarnation, null);
            return;
        }
        if (participant.lifecycle != .alive or participant.character == null or
            participant.despawn_pending)
        {
            try self.queueWeaponActionResult(participant_index, action, .dead, null);
            return;
        }
        const tick_index = self.simulation.tickIndex();
        if (action.target_tick < tick_index -| budgets.input_history_ticks or
            action.target_tick > tick_index +| budgets.max_future_input_ticks)
        {
            try self.queueWeaponActionResult(participant_index, action, .invalid_state, null);
            return;
        }
        if (participant.pending_weapon_action != null or
            participant.pending_weapon_shot != null or participant.vitals_pending or
            hasPendingVehicleEnter(participant))
        {
            try self.queueWeaponActionResult(participant_index, action, .invalid_state, null);
            return;
        }
        const decision = try ranged_combat.apply(
            &participant.weapon,
            handgun_config,
            protocolWeaponAction(action.kind),
            .{
                .alive = true,
                .on_foot = participant.driving_vehicle_index == null,
                .hands_free = participant.holding_carryable_index == null,
            },
            tick_index,
        );
        self.force_snapshot = true;
        if (!decision.admittedShot()) {
            try self.queueWeaponActionResult(
                participant_index,
                action,
                protocolWeaponDisposition(decision.disposition),
                null,
            );
            if (decision.disposition == .equipped or
                decision.disposition == .holstered or
                decision.disposition == .reload_started)
            {
                self.recordWeaponIngress(connection_index, participant_index, action);
                self.weapon_actions_admitted +|= 1;
                self.accepted_messages +|= 1;
            }
            return;
        }

        self.recordWeaponIngress(connection_index, participant_index, action);
        const ray = try self.resolveShotRay(participant_index);
        self.weapon_actions_admitted +|= 1;
        self.accepted_messages +|= 1;
        if (ray.target == null) {
            const miss = ShotResolution{
                .origin = ray.origin,
                .impact = ray.impact,
            };
            try self.queueWeaponActionResult(participant_index, action, .fired_miss, miss);
            try self.publishShotEvent(participant_index, action, miss, .miss);
            return;
        }

        const selected = ray.target.?;
        const target = vitals_contract.Target{
            .kind = selected.kind,
            .id = selected.persistent,
            .incarnation = .{ .value = selected.incarnation },
        };
        try self.simulation.submitVitals(.{ .damage = .{
            .source = .{
                .kind = .player,
                .id = participant.character.?,
                .incarnation = .{ .value = participant.avatar_incarnation },
                .action_sequence = action.sequence.value,
            },
            .target = target,
            .cause = .firearm,
            .authority_tick = tick_index +| 1,
            .correlation = weaponDamageCorrelation(participant_index, action.sequence),
            .base_amount = handgun_config.damage,
            .ordinal = 1,
        } });
        participant.pending_weapon_action = action;
        participant.pending_weapon_shot = .{
            .target = target,
            .replicated = selected.replicated,
            .origin = ray.origin,
            .impact = ray.impact,
            .authority_tick = tick_index +| 1,
        };
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
        participant.reserved_spawn_position = spawn_position;
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

    fn recordWeaponIngress(
        self: *AuthorityCore,
        connection_index: usize,
        participant_index: usize,
        action: protocol.WeaponAction,
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
            .kind = switch (action.kind) {
                .equip_toggle => .weapon_equip_toggle,
                .fire => .weapon_fire,
                .reload => .weapon_reload,
            },
            .move = .{ 0, 0 },
            .facing_yaw = 0,
            .jump_pressed = false,
            .vehicle = .invalid,
            .vehicle_control = .{ 0, 0, 0, 0 },
            .avatar_incarnation = action.avatar_incarnation,
        });
    }

    fn advanceWeaponStates(self: *AuthorityCore) !void {
        const tick_index = self.simulation.tickIndex();
        for (self.participants) |*participant| {
            if (!participant.active) continue;
            const advanced = try ranged_combat.advance(
                &participant.weapon,
                handgun_config,
                tick_index,
            );
            if (advanced.completed_reload) self.force_snapshot = true;
        }
    }

    fn resolveShotRay(self: *AuthorityCore, attacker_index: usize) !ShotRay {
        const attacker = self.participants[attacker_index];
        const source = try self.simulation.character(attacker.character.?);
        const origin = [3]f32{
            source.position[0],
            source.position[1] + source.half_height + source.radius,
            source.position[2],
        };
        const direction = [3]f32{ @sin(source.facing_yaw), 0, -@cos(source.facing_yaw) };
        const endpoint = addScaled(origin, direction, handgun_config.range);
        const world_fraction = try self.simulation.presentationLineHitFraction(origin, endpoint);
        var selected: ?RangedTarget = null;

        for (self.participants, 0..) |candidate, index| {
            if (index == attacker_index or !candidate.active or
                candidate.lifecycle != .alive or candidate.character == null or
                candidate.despawn_pending or candidate.vitals_pending or
                candidate.driving_vehicle_index != null or hasPendingVehicleEnter(&candidate))
            {
                continue;
            }
            const view = try self.simulation.character(candidate.character.?);
            const center = [3]f32{
                view.position[0],
                view.position[1] + view.half_height + view.radius,
                view.position[2],
            };
            const fraction = raySphereFraction(origin, endpoint, center, view.radius) orelse
                continue;
            if (world_fraction != null and world_fraction.? + 0.0001 < fraction) continue;
            considerRangedTarget(&selected, .{
                .kind = .player,
                .persistent = candidate.character.?,
                .replicated = candidate.replicated,
                .incarnation = candidate.avatar_incarnation,
                .hit_fraction = fraction,
            });
        }
        for (self.npcs) |candidate| {
            if (!candidate.active or candidate.persistent == null or
                candidate.despawn_pending or candidate.vitals_pending)
            {
                continue;
            }
            const vital = self.simulation.currentVitals(.npc, candidate.persistent.?) orelse
                continue;
            if (vital.life_state != .alive) continue;
            const view = try self.simulation.npc(candidate.persistent.?);
            const center = [3]f32{
                view.position[0],
                view.position[1] + view.half_height + view.radius,
                view.position[2],
            };
            const fraction = raySphereFraction(origin, endpoint, center, view.radius) orelse
                continue;
            if (world_fraction != null and world_fraction.? + 0.0001 < fraction) continue;
            considerRangedTarget(&selected, .{
                .kind = .npc,
                .persistent = candidate.persistent.?,
                .replicated = candidate.replicated,
                .incarnation = candidate.generation,
                .hit_fraction = fraction,
            });
        }

        const impact_fraction = if (selected) |target|
            target.hit_fraction
        else
            world_fraction orelse 1;
        return .{
            .origin = origin,
            .endpoint = endpoint,
            .impact = addScaled(origin, direction, handgun_config.range * impact_fraction),
            .target = selected,
        };
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
                candidate.despawn_pending or candidate.vitals_pending or
                candidate.driving_vehicle_index != null or
                hasPendingVehicleEnter(&candidate))
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
        const participant = self.participants[participant_index];
        const rotation = (@as(usize, participant_index) + participant.avatar_incarnation) %
            automatic_spawn_candidates.len;
        var selected: ?[3]f32 = null;
        var selected_score: f32 = -1;
        for (0..automatic_spawn_candidates.len) |offset| {
            const candidate = automatic_spawn_candidates[
                (rotation + offset) % automatic_spawn_candidates.len
            ];
            const nearest_threat = try self.spawnCandidateScore(
                participant_index,
                candidate,
            ) orelse continue;
            if (nearest_threat > selected_score) {
                selected = candidate;
                selected_score = nearest_threat;
            }
        }
        return selected;
    }

    fn selectInitialSpawnPosition(
        self: *AuthorityCore,
        participant_index: usize,
    ) !?[3]f32 {
        for (0..automatic_spawn_candidates.len) |offset| {
            const candidate = automatic_spawn_candidates[
                (participant_index + offset) % automatic_spawn_candidates.len
            ];
            if (try self.spawnCandidateScore(participant_index, candidate) != null) {
                return candidate;
            }
        }
        return null;
    }

    /// Real placement plus live-avatar/NPC separation. CharacterVirtual
    /// instances are not rigid bodies in Jolt's shape query, so both checks
    /// are required and intentionally kept in one authority policy.
    fn spawnCandidateScore(
        self: *AuthorityCore,
        participant_index: usize,
        candidate: [3]f32,
    ) !?f32 {
        if (!try self.simulation.characterSpawnClear(candidate)) return null;
        var nearest_threat: f32 = std.math.inf(f32);
        for (self.participants, 0..) |other, other_index| {
            if (other_index == participant_index or !other.active) continue;
            if (other.reserved_spawn_position) |reserved| {
                const distance = horizontalDistanceSquared(candidate, reserved);
                if (distance < 2.25) return null;
                nearest_threat = @min(nearest_threat, distance);
            }
            // A spawned character owns space even while its vitals
            // registration is moving the participant from spawning to alive.
            // CharacterVirtual is absent from Jolt shape queries, so skipping
            // this handoff state would permit a same-position admission.
            if (other.despawn_pending) continue;
            const occupied_position = try self.participantAvatarWorldPosition(other_index) orelse
                continue;
            const distance = horizontalDistanceSquared(candidate, occupied_position);
            if (distance < 2.25) return null;
            nearest_threat = @min(nearest_threat, distance);
        }
        for (self.npcs) |npc| {
            if (!npc.active or npc.persistent == null or npc.despawn_pending) continue;
            const view = try self.simulation.npc(npc.persistent.?);
            const distance = horizontalDistanceSquared(candidate, view.position);
            if (distance < 2.25) return null;
            nearest_threat = @min(nearest_threat, distance);
        }
        return nearest_threat;
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
                    .purpose = .forced_cleanup,
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
                    participant.reserved_spawn_position = null;
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
                            participant.pending_melee_target = null;
                            participant.pending_weapon_action = null;
                            participant.pending_weapon_shot = null;
                            ranged_combat.holster(&participant.weapon);
                            participant.exit_pending = false;
                            participant.interaction_cleanup_pending = false;
                            participant.spawn_pending = false;
                            participant.reserved_spawn_position = null;
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
                        participant.reserved_spawn_position = null;
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
                    ranged_combat.holster(&participant.weapon);
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
                    const next_index = district_index + 1;
                    if (next_index < sandbox_district_recipe.installed_coords.len) {
                        try self.simulation.submitDistrict(.{ .request_load = .{
                            .request_id = districtBootstrapRequestId(next_index),
                            .coord = districtBootstrapCoord(next_index),
                            .assets = .{},
                        } });
                    }
                    if (district_index != 0) continue;
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
                            ranged_combat.holster(&participant.weapon);
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
                    ranged_combat.holster(&participant.weapon);
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
                    if (self.findNpcByPopulationSpawnCorrelation(
                        spawned.request_id,
                    )) |npc_index| {
                        const npc = &self.npcs[npc_index];
                        const member = npc.population_member orelse
                            return error.PopulationNpcMemberMissing;
                        if (!npc.spawn_pending or npc.active or
                            npc.population_spawn_correlation != spawned.request_id)
                        {
                            return error.StalePopulationSpawnOutcome;
                        }
                        npc.spawn_pending = false;
                        npc.active = true;
                        npc.persistent = spawned.id;
                        npc.population_spawn_correlation = 0;
                        npc.population_spawn_slot = null;
                        npc.vitals_pending = true;
                        try self.simulation.populationBindActor(
                            member,
                            npc.population_actor_generation,
                            spawned.id,
                        );
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
                .goal_set => |goal_set| {
                    const npc_index = self.findNpcByPopulationGoalCorrelation(
                        goal_set.request_id,
                    ) orelse {
                        if (self.world_bootstrap != .host_managed) {
                            return error.UnexpectedNpcMutationOutcome;
                        }
                        continue;
                    };
                    const npc = &self.npcs[npc_index];
                    if (!npc.active or npc.persistent == null or
                        !std.meta.eql(npc.persistent.?, goal_set.id) or
                        npc.population_goal_correlation != goal_set.request_id or
                        npc.population_destination == null or
                        goal_set.goal != .navigate_to or
                        !npc_contract.DestinationId.eql(
                            npc.population_destination.?,
                            goal_set.goal.navigate_to,
                        ))
                    {
                        return error.StalePopulationGoalOutcome;
                    }
                    npc.population_goal_correlation = 0;
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
                        npc.population_goal_correlation = 0;
                        npc.population_activity_sequence = 0;
                        npc.population_destination = null;
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
                .rejected => |rejected| {
                    if (self.findNpcByPopulationSpawnCorrelation(
                        rejected.request_id,
                    )) |npc_index| {
                        const npc = &self.npcs[npc_index];
                        const member = npc.population_member orelse
                            return error.PopulationNpcMemberMissing;
                        if (!npc.spawn_pending or
                            npc.population_spawn_correlation != rejected.request_id)
                        {
                            return error.StalePopulationSpawnRejection;
                        }
                        npc.spawn_pending = false;
                        npc.population_replacement_spawn_pending = false;
                        npc.population_spawn_correlation = 0;
                        npc.population_spawn_slot = null;
                        try self.simulation.populationDeferSpawn(
                            member,
                            npc.population_actor_generation,
                            try populationSpawnRetryReason(rejected.reason),
                        );
                    } else if (self.findNpcByPopulationGoalCorrelation(
                        rejected.request_id,
                    )) |npc_index| {
                        const npc = &self.npcs[npc_index];
                        const member = npc.population_member orelse
                            return error.PopulationNpcMemberMissing;
                        const actor = npc.persistent orelse
                            return error.PopulationNpcActorMissing;
                        try self.simulation.populationDeferDestination(
                            member,
                            actor,
                            npc.population_activity_sequence,
                        );
                        npc.population_goal_correlation = 0;
                        npc.population_activity_sequence = 0;
                        npc.population_destination = null;
                    } else if (self.world_bootstrap != .host_managed) {
                        return error.NpcBootstrapRejected;
                    }
                },
            }
        }
        while (self.simulation.pollNpcEvent()) |event| {
            self.retainObservation(&self.observations.npc_events, event);
            switch (event) {
                .state_changed, .owner_transferred => self.force_snapshot = true,
                .goal_reached => |reached| {
                    const npc_index = self.findNpcByPersistent(reached.id) orelse
                        continue;
                    const npc = &self.npcs[npc_index];
                    const member = npc.population_member orelse continue;
                    const member_record = self.simulation.populationMember(member) orelse
                        return error.PopulationMemberNotFound;
                    const activity_slot = member_record.activity_slot orelse continue;
                    const definition = sandbox_population_catalog.activitySlotDefinition(
                        activity_slot,
                    ) orelse return error.PopulationActivitySlotNotFound;
                    if (member_record.activity_state == .traveling and
                        npc.population_destination != null and
                        npc_contract.DestinationId.eql(
                            reached.destination,
                            definition.destination,
                        ) and
                        npc_contract.DestinationId.eql(
                            reached.destination,
                            npc.population_destination.?,
                        ))
                    {
                        try self.simulation.populationArrive(member, reached.id);
                        npc.population_activity_sequence = 0;
                        npc.population_destination = null;
                        self.force_snapshot = true;
                    }
                },
            }
        }
        while (self.simulation.pollNpcNavigationTransition()) |transition| {
            self.retainObservation(
                &self.observations.npc_navigation_transitions,
                transition,
            );
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
                    participant.death_proxy = null;
                    try ranged_combat.reset(&participant.weapon, handgun_config);
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
                            .authority_tick = self.simulation.tickIndex(),
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
                    if (npc.population_replacement_spawn_pending) {
                        npc.population_replacement_spawn_pending = false;
                    }
                    // Keep the red death proxy through all safe-spawn delay
                    // and retry states. The registered replacement is the
                    // explicit lifecycle edge that removes it.
                    npc.death_proxy = null;
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
                        switch (damage.proposal.cause) {
                            .melee => {
                                const action = attacker.pending_melee_action orelse
                                    return error.UnexpectedDamageOutcome;
                                if (damage.proposal.correlation !=
                                    damageCorrelation(attacker_index, action.sequence))
                                {
                                    return error.DamageCorrelationMismatch;
                                }
                                const pending_target = attacker.pending_melee_target orelse
                                    return error.UnexpectedDamageOutcome;
                                if (!std.meta.eql(pending_target, damage.proposal.target)) {
                                    return error.DamageTargetMismatch;
                                }
                                const replicated = self.replicatedVitalsTarget(
                                    damage.proposal.target,
                                ) orelse identity.ReplicatedEntityId.invalid;
                                try self.queueDamageResult(attacker_index, action, replicated, damage);
                                if (damage.disposition == .applied) self.melee_hits +|= 1;
                                attacker.pending_melee_action = null;
                                attacker.pending_melee_target = null;
                            },
                            .firearm => {
                                const action = attacker.pending_weapon_action orelse
                                    return error.UnexpectedDamageOutcome;
                                const pending = attacker.pending_weapon_shot orelse
                                    return error.UnexpectedDamageOutcome;
                                if (damage.proposal.correlation !=
                                    weaponDamageCorrelation(attacker_index, action.sequence))
                                {
                                    return error.DamageCorrelationMismatch;
                                }
                                if (!std.meta.eql(pending.target, damage.proposal.target)) {
                                    return error.DamageTargetMismatch;
                                }
                                const resolution = ShotResolution{
                                    .origin = pending.origin,
                                    .impact = pending.impact,
                                    .target = pending.replicated,
                                    .target_incarnation = damage.proposal.target.incarnation.value,
                                    .applied_damage = damage.applied_amount,
                                    .remaining_health = damage.remaining_health,
                                    .killed = damage.killed,
                                };
                                if (damage.disposition == .applied) {
                                    try self.queueWeaponActionResult(
                                        attacker_index,
                                        action,
                                        .fired_hit,
                                        resolution,
                                    );
                                    self.firearm_hits +|= 1;
                                    try self.publishShotEvent(
                                        attacker_index,
                                        action,
                                        resolution,
                                        .hit,
                                    );
                                } else {
                                    // The shot and ammo spend were already admitted. A
                                    // semantic target can become invalid before vitals
                                    // applies the proposal (for example, another shooter
                                    // killed it earlier in this authority cycle). Preserve
                                    // that committed shot as a miss instead of manufacturing
                                    // an action rejection with contradictory target data.
                                    const miss = ShotResolution{
                                        .origin = pending.origin,
                                        .impact = pending.impact,
                                    };
                                    try self.queueWeaponActionResult(
                                        attacker_index,
                                        action,
                                        .fired_miss,
                                        miss,
                                    );
                                    try self.publishShotEvent(
                                        attacker_index,
                                        action,
                                        miss,
                                        .miss,
                                    );
                                }
                                attacker.pending_weapon_action = null;
                                attacker.pending_weapon_shot = null;
                            },
                            .npc_melee => return error.InvalidPlayerDamageCause,
                        }
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
                        if (damage.disposition == .applied and !damage.killed) {
                            const target = self.replicatedVitalsTarget(
                                damage.proposal.target,
                            ) orelse return error.UnknownDamageTarget;
                            try self.publishLifeEvent(.{
                                .avatar = target,
                                .incarnation = damage.proposal.target.incarnation.value,
                                .authority_tick = damage.proposal.authority_tick,
                                .health = damage.remaining_health,
                                .maximum_health = vitals_contract.default_max_health,
                                .state = .alive,
                            });
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
            .authority_tick = died.authority_tick,
            .health = 0,
            .maximum_health = vitals_contract.default_max_health,
            .state = .dead,
            .instigator = instigator,
            .respawn_ready_tick = if (died.target.kind == .player)
                died.authority_tick +| respawn_cooldown_ticks
            else
                0,
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
                const character = try self.simulation.character(died.target.id);
                const position = try self.participantAvatarWorldPosition(
                    participant_index,
                ) orelse return error.ParticipantAuthorityInvariantBroken;
                participant.death_proxy = .{
                    .owner = try district_contract.chunkCoordForWorldPosition(position),
                    .state = .{
                        .entity = participant.replicated,
                        .owner = participantId(participant_index, participant.generation),
                        .position = position,
                        .velocity = .{ 0, 0, 0 },
                        .facing_yaw = character.facing_yaw,
                        .incarnation = participant.avatar_incarnation,
                        .health = 0,
                        .maximum_health = vitals_contract.default_max_health,
                        .life_state = .dead,
                    },
                };
                participant.lifecycle = .dead;
                participant.death_tick = died.authority_tick;
                participant.respawn_available_tick = died.authority_tick +|
                    respawn_cooldown_ticks;
                participant.retain_after_despawn = true;
                participant.despawn_pending = true;
                ranged_combat.holster(&participant.weapon);
                participant.pending_weapon_action = null;
                participant.pending_weapon_shot = null;
                clearParticipantInputs(participant);
                try self.continueParticipantDespawn(participant_index);
            },
            .npc => {
                const npc_index = self.findNpcByPersistent(died.target.id) orelse
                    return error.UnknownNpcDeathTarget;
                const npc = &self.npcs[npc_index];
                if (npc.despawn_pending) return error.DuplicateNpcDeathEvent;
                const view = try self.simulation.npc(died.target.id);
                const encounter = self.simulation.npcEncounter(died.target);
                const owner = try district_contract.chunkCoordForWorldPosition(view.position);
                npc.death_proxy = .{
                    .owner = owner,
                    .state = .{
                        .entity = npc.replicated,
                        .position = view.position,
                        .velocity = .{ 0, 0, 0 },
                        .facing_yaw = view.facing_yaw,
                        .state = .active,
                        .incarnation = npc.generation,
                        .health = 0,
                        .maximum_health = vitals_contract.default_max_health,
                        .life_state = .dead,
                        .encounter_state = if (encounter) |value|
                            protocolNpcEncounterState(value.state)
                        else
                            .patrolling,
                        .encounter_state_enter_tick = if (encounter) |value|
                            value.state_enter_tick
                        else
                            died.authority_tick,
                        .attack_impact_tick = 0,
                        .attack_ready_tick = 0,
                    },
                };
                npc.despawn_pending = true;
                if (npc.population_member) |member| {
                    try self.simulation.populationVacate(member, died.target.id);
                    npc.population_actor_generation =
                        (self.simulation.populationMember(member) orelse
                            return error.PopulationMemberNotFound).actor_generation;
                    npc.population_goal_correlation = 0;
                    npc.population_activity_sequence = 0;
                    npc.population_destination = null;
                }
                const population_projection = try self.npcPopulationProjection(npc.*);
                npc.death_proxy.?.state.population_member =
                    population_projection.member;
                npc.death_proxy.?.state.population_role =
                    population_projection.role;
                npc.death_proxy.?.state.combat_disposition =
                    population_projection.combat_disposition;
                npc.death_proxy.?.state.activity_kind =
                    population_projection.activity_kind;
                npc.death_proxy.?.state.activity_state =
                    population_projection.activity_state;
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
            // simulation character while the host tears it down and later
            // respawns it. Its authority-owned death proxy remains in the
            // projection so death is a visible state rather than absence.
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
                    .district_count = @intCast(
                        sandbox_district_recipe.installed_coords.len,
                    ),
                    .snapshot = full_projection,
                };
                for (sandbox_district_recipe.installed_coords, 0..) |coord, index| {
                    baseline.districts[index] = districtCoord(coord);
                }
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
        const position = try self.participantAvatarWorldPosition(participant_index) orelse return;
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
        const observer_position = try self.participantAvatarWorldPosition(participant_index);
        // A connected participant retains a readable projection while its live
        // character is absent during death/respawn. Prefer the exact retained
        // death pose for interest diagnostics. Full-world development policy
        // does not require a spatial observer, so use the retained district
        // center during the narrower pre-spawn interval instead of erasing the
        // NPC lane.
        const npc_interest_origin = observer_position orelse
            if (target.death_proxy) |proxy|
                proxy.state.position
            else if (self.npc_interest_mode == .full_world)
                districtCenterPosition(target.relevance_coord)
            else
                null;
        var snapshot = protocol.Snapshot.empty();
        snapshot.baseline_id = target.baseline_id;
        snapshot.sequence = replication.next_sequence;
        replication.next_sequence = replication.next_sequence.next();
        if (replication.next_sequence.value == 0) replication.next_sequence.value = 1;
        snapshot.server_tick = self.simulation.tickIndex();
        snapshot.acknowledged_input = target.last_applied_input;
        for (self.participants, 0..) |participant, index| {
            if (!participant.active or participant.character == null or
                participant.despawn_pending or participant.death_proxy != null) continue;
            const view = try self.simulation.character(participant.character.?);
            const occupied_position = try self.participantAvatarWorldPosition(index) orelse
                return error.ParticipantAuthorityInvariantBroken;
            const vital = self.simulation.vitals(playerVitalsTarget(
                participant,
                participant.character.?,
            )) orelse if (participant.vitals_pending)
                pendingVitalsView(playerVitalsTarget(participant, participant.character.?))
            else
                continue;
            const relevant = index == participant_index or std.meta.eql(
                try district_contract.chunkCoordForWorldPosition(occupied_position),
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
                .weapon_mode = protocolWeaponMode(participant.weapon.mode),
                .magazine_ammo = participant.weapon.magazine,
                .reserve_ammo = participant.weapon.reserve,
                .weapon_ready_tick = participant.weapon.next_fire_tick,
                .reload_complete_tick = participant.weapon.reload_complete_tick,
            };
            snapshot.character_count += 1;
        }
        for (self.participants, 0..) |participant, index| {
            const proxy = participant.death_proxy orelse continue;
            if (!participant.active) continue;
            const relevant = index == participant_index or
                std.meta.eql(proxy.owner, target.relevance_coord);
            if (!relevant) continue;
            if (snapshot.character_count == snapshot.characters.len) {
                return error.CharacterSnapshotCapacityReached;
            }
            snapshot.characters[snapshot.character_count] = proxy.state;
            snapshot.character_count += 1;
        }
        for (self.vehicles, 0..) |vehicle, vehicle_index| {
            if (!vehicle.active or vehicle.persistent == null) continue;
            const view = try self.simulation.vehicle(vehicle.persistent.?);
            const driver_index = if (view.driver_id) |driver|
                self.findParticipantByCharacter(driver)
            else
                null;
            recordObjectInterest(
                &replication.vehicle_interest[vehicle_index],
                snapshot.server_tick,
                snapshot.baseline_id,
                snapshot.sequence.value,
                observer_position orelse .{ 0, 0, 0 },
                target.relevance_coord,
                view.state.chassis.pose.position,
                if (driver_index != null and driver_index.? == participant_index)
                    .controlled
                else
                    .bounded_world,
            );
            var wheels: [protocol.vehicle_wheel_count]protocol.VehicleWheelState = undefined;
            for (&wheels, view.state.wheels) |*projected, wheel| {
                projected.* = .{
                    .spin_phase = wheel.rotation_angle,
                    .angular_velocity = wheel.angular_velocity,
                    .steer_angle = wheel.steer_angle,
                    .suspension_length = wheel.suspension_length,
                    .has_contact = wheel.has_contact,
                };
            }
            snapshot.vehicles[snapshot.vehicle_count] = .{
                .entity = vehicle.replicated,
                .position = view.state.chassis.pose.position,
                .rotation = view.state.chassis.pose.rotation,
                .linear_velocity = view.state.chassis.velocity.linear,
                .angular_velocity = view.state.chassis.velocity.angular,
                .wheels = wheels,
                .driver = if (driver_index) |index|
                    participantId(index, self.participants[index].generation)
                else
                    null,
            };
            snapshot.vehicle_count += 1;
        }
        for (self.carryables, 0..) |carryable, carryable_index| {
            if (!carryable.active or carryable.persistent == null) continue;
            const view = try self.simulation.carryable(carryable.persistent.?);
            recordObjectInterest(
                &replication.carryable_interest[carryable_index],
                snapshot.server_tick,
                snapshot.baseline_id,
                snapshot.sequence.value,
                observer_position orelse .{ 0, 0, 0 },
                target.relevance_coord,
                view.state.pose.position,
                .district_dormant,
            );
            replication.carryable_interest[carryable_index].included = false;
        }
        const carryable_draws = try self.simulation.interactionPresentation();
        for (carryable_draws) |draw| {
            const carryable_index = self.findCarryableByPersistent(draw.persistent_id) orelse
                return error.UnknownInteractionPresentation;
            const view = try self.simulation.carryable(draw.persistent_id);
            const holder_index = switch (draw.ownership) {
                .spatially_owned => null,
                .inventory_held => |carrier| self.findParticipantByCharacter(carrier) orelse
                    return error.UnknownInteractionCarrier,
            };
            recordObjectInterest(
                &replication.carryable_interest[carryable_index],
                snapshot.server_tick,
                snapshot.baseline_id,
                snapshot.sequence.value,
                observer_position orelse .{ 0, 0, 0 },
                target.relevance_coord,
                draw.pose.position,
                if (holder_index != null and holder_index.? == participant_index)
                    .held
                else
                    .bounded_world,
            );
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
            const encounter = self.simulation.npcEncounter(vital.target);
            const population_projection = try self.npcPopulationProjection(
                self.npcs[npc_index],
            );
            const interest_origin = npc_interest_origin orelse continue;
            const encounter_relevant = if (encounter) |value| if (value.target) |encounter_target|
                target.character != null and std.meta.eql(
                    encounter_target,
                    playerVitalsTarget(target, target.character.?),
                )
            else
                false else false;
            if (!evaluateNpcInterest(
                self.npc_interest_mode,
                &replication.npc_interest[npc_index],
                snapshot.server_tick,
                interest_origin,
                target.relevance_coord,
                view.position,
                draw.owner,
                encounter_relevant,
            )) continue;
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
                .encounter_state = if (encounter) |value|
                    protocolNpcEncounterState(value.state)
                else
                    .patrolling,
                .encounter_state_enter_tick = if (encounter) |value|
                    value.state_enter_tick
                else
                    0,
                .attack_impact_tick = if (encounter) |value| value.attack_impact_tick else 0,
                .attack_ready_tick = if (encounter) |value| value.ready_tick else 0,
                .population_member = population_projection.member,
                .population_role = population_projection.role,
                .combat_disposition = population_projection.combat_disposition,
                .activity_kind = population_projection.activity_kind,
                .activity_state = population_projection.activity_state,
            };
            snapshot.npc_count += 1;
        }
        for (self.npcs, 0..) |npc, npc_index| {
            if (npc.active) continue;
            const proxy = npc.death_proxy orelse continue;
            const interest_origin = npc_interest_origin orelse continue;
            if (!evaluateNpcInterest(
                self.npc_interest_mode,
                &replication.npc_interest[npc_index],
                snapshot.server_tick,
                interest_origin,
                target.relevance_coord,
                proxy.state.position,
                proxy.owner,
                false,
            )) continue;
            if (snapshot.npc_count == snapshot.npcs.len) {
                return error.NpcSnapshotCapacityReached;
            }
            snapshot.npcs[snapshot.npc_count] = proxy.state;
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
            participant.death_proxy = null;
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
            participant.pending_melee_target = null;
            participant.melee_cooldown_until_tick = 0;
            participant.weapon = .{
                .magazine = handgun_config.magazine_capacity,
                .reserve = handgun_config.starting_reserve,
            };
            participant.last_weapon_action = .{ .value = 0 };
            participant.pending_weapon_action = null;
            participant.pending_weapon_shot = null;
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
            participant.gameplay_consumer_retired = false;
            self.replication[index] = .{
                .byte_credit = self.options.downstream_bytes_per_second,
            };
            participant.exit_pending = false;
            participant.spawn_pending = false;
            participant.reserved_spawn_position = null;
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
                .melee_ready_tick = participant.melee_cooldown_until_tick,
                .weapon_mode = protocolWeaponMode(participant.weapon.mode),
                .magazine_ammo = participant.weapon.magazine,
                .reserve_ammo = participant.weapon.reserve,
                .weapon_ready_tick = participant.weapon.next_fire_tick,
                .reload_complete_tick = participant.weapon.reload_complete_tick,
                .respawn_ready_tick = participant.respawn_available_tick,
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
            .ready_tick = self.participants[participant_index].melee_cooldown_until_tick,
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
            .ready_tick = self.participants[participant_index].melee_cooldown_until_tick,
        } });
    }

    fn queueWeaponActionResult(
        self: *AuthorityCore,
        participant_index: usize,
        action: protocol.WeaponAction,
        disposition: protocol.WeaponActionDisposition,
        resolution: ?ShotResolution,
    ) !void {
        const participant = self.participants[participant_index];
        const shot = resolution orelse ShotResolution{
            .origin = @splat(0),
            .impact = @splat(0),
        };
        try self.queueGameplayResult(participant_index, .{ .weapon_action_result = .{
            .sequence = action.sequence,
            .authority_tick = self.simulation.tickIndex(),
            .action = action.kind,
            .disposition = disposition,
            .mode = protocolWeaponMode(participant.weapon.mode),
            .magazine_ammo = participant.weapon.magazine,
            .reserve_ammo = participant.weapon.reserve,
            .weapon_ready_tick = participant.weapon.next_fire_tick,
            .reload_complete_tick = participant.weapon.reload_complete_tick,
            .target = shot.target,
            .target_incarnation = shot.target_incarnation,
            .ray_origin = shot.origin,
            .impact_position = shot.impact,
            .applied_damage = shot.applied_damage,
            .remaining_health = shot.remaining_health,
            .killed = shot.killed,
        } });
    }

    fn publishShotEvent(
        self: *AuthorityCore,
        shooter_index: usize,
        action: protocol.WeaponAction,
        resolution: ShotResolution,
        disposition: protocol.ShotDisposition,
    ) !void {
        const shooter = self.participants[shooter_index];
        const event = protocol.ShotEvent{
            .shooter = shooter.replicated,
            .shooter_incarnation = shooter.avatar_incarnation,
            .sequence = action.sequence,
            .authority_tick = self.simulation.tickIndex(),
            .disposition = disposition,
            .ray_origin = resolution.origin,
            .impact_position = resolution.impact,
            .target = resolution.target,
            .target_incarnation = resolution.target_incarnation,
            .applied_damage = resolution.applied_damage,
            .remaining_health = resolution.remaining_health,
            .killed = resolution.killed,
        };
        for (self.participants, 0..) |participant, participant_index| {
            if (!participant.active or participant.gameplay_consumer_retired) continue;
            _ = try self.ensureGameplayCapacityOrRetire(participant_index, 1);
        }
        for (self.participants, 0..) |participant, participant_index| {
            if (!participant.active or participant.gameplay_consumer_retired) continue;
            self.appendGameplayResultAssumeCapacity(
                participant_index,
                .{ .shot_event = event },
            );
        }
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
            .ready_tick = participant.respawn_available_tick,
        } });
    }

    fn publishLifeEvent(self: *AuthorityCore, event: protocol.LifeEvent) !void {
        // Resolve every slow consumer before changing a healthy ledger. A
        // participant that exhausted its bounded replay window is retired;
        // it cannot partially publish or fault the room for everyone else.
        for (self.participants, 0..) |participant, participant_index| {
            if (!participant.active or participant.gameplay_consumer_retired) continue;
            _ = try self.ensureGameplayCapacityOrRetire(participant_index, 1);
        }
        for (self.participants, 0..) |participant, participant_index| {
            if (!participant.active or participant.gameplay_consumer_retired) continue;
            self.appendGameplayResultAssumeCapacity(
                participant_index,
                .{ .life_event = event },
            );
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
        const messages = [_]ReplayMessage{message};
        try self.queueGameplayResults(participant_index, &messages);
    }

    /// Commits one logical participant-local burst atomically to the retained
    /// gameplay ledger. Wire quota and outbox space are deliberately absent
    /// here: the send cursor drains the accepted facts over later cycles.
    fn queueGameplayResults(
        self: *AuthorityCore,
        participant_index: usize,
        messages: []const ReplayMessage,
    ) !void {
        if (!try self.ensureGameplayCapacityOrRetire(participant_index, messages.len)) return;
        for (messages) |message| {
            self.appendGameplayResultAssumeCapacity(participant_index, message);
        }
    }

    fn ensureGameplayCapacityOrRetire(
        self: *AuthorityCore,
        participant_index: usize,
        count: usize,
    ) !bool {
        if (!self.publication_preparing) return error.PublicationNotPreparing;
        if (participant_index >= self.participants.len or
            !self.participants[participant_index].active)
        {
            return error.InvalidGameplayPublicationParticipant;
        }
        if (self.participants[participant_index].gameplay_consumer_retired) return false;
        if (count == 0) return true;
        const participant = &self.participants[participant_index];
        var available: usize = 0;
        for (participant.replay_records) |record| {
            available += @intFromBool(!record.active);
        }
        const additional_ids = count - 1;
        const delivery_ids_available = participant.next_gameplay_delivery_id != 0 and
            additional_ids <= std.math.maxInt(u64) - participant.next_gameplay_delivery_id;
        if (available >= count and delivery_ids_available) return true;
        try self.retireSlowGameplayConsumer(participant_index);
        return false;
    }

    fn retireSlowGameplayConsumer(
        self: *AuthorityCore,
        participant_index: usize,
    ) !void {
        const participant = &self.participants[participant_index];
        if (!participant.active or participant.gameplay_consumer_retired) return;
        participant.gameplay_consumer_retired = true;
        participant.reconnect = .invalid;
        participant.retained_reconnect = .invalid;
        participant.reconnect_confirmation_pending = false;
        participant.pending_welcome_delivery_id = 0;
        participant.replay_cursor_delivery_id = 0;
        participant.replay_records = @splat(.{});
        if (participant.connection_index) |connection_index| {
            const connection = &self.connections[connection_index];
            if (connection.active) {
                // The disconnect notice is best-effort under the same bounded
                // outbox. Retirement itself must never wait on more wire room.
                if (!self.prepared_outbox.isFull()) {
                    self.prepared_outbox.pushAssumeCapacity(.{
                        .connection = connection.transport,
                        .message = .{ .disconnected = .protocol_failure },
                        .delivery = .reliable,
                        .lane = .control,
                        .close_after_send = true,
                    });
                }
                self.detachConnection(connection_index, false);
            }
        }
        participant.reconnect_deadline_tick = self.simulation.tickIndex();
        try self.beginParticipantDespawn(participant_index);
        self.slow_gameplay_consumers_retired +|= 1;
    }

    fn appendGameplayResultAssumeCapacity(
        self: *AuthorityCore,
        participant_index: usize,
        message: ReplayMessage,
    ) void {
        const participant = &self.participants[participant_index];
        const record = for (&participant.replay_records) |*candidate| {
            if (!candidate.active) break candidate;
        } else unreachable;
        const delivery_id = participant.next_gameplay_delivery_id;
        std.debug.assert(delivery_id != 0);
        participant.next_gameplay_delivery_id +%= 1;
        record.* = .{
            .active = true,
            .delivery_id = delivery_id,
            .message = message,
        };
        if (participant.connection_index) |connection_index| {
            if (self.connections[connection_index].active and
                participant.replay_cursor_delivery_id == 0)
            {
                participant.replay_cursor_delivery_id = delivery_id;
            }
        }
    }

    fn prepareReliableReplay(self: *AuthorityCore) !void {
        for (self.participants) |*participant| {
            const connection_index = participant.connection_index orelse continue;
            if (!participant.active or participant.gameplay_consumer_retired or
                participant.reconnect_confirmation_pending or
                participant.replay_cursor_delivery_id == 0 or
                !self.connections[connection_index].active)
            {
                continue;
            }
            var cursor = participant.replay_cursor_delivery_id;
            while (cursor < participant.next_gameplay_delivery_id) {
                const record = for (&participant.replay_records) |*candidate| {
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
                const retransmission = record.transmitted;
                record.transmitted = true;
                cursor = record.delivery_id +| 1;
                if (retransmission) self.reliable_replays +|= 1;
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

    fn findNpcByPopulationSpawnCorrelation(
        self: *const AuthorityCore,
        correlation: u64,
    ) ?usize {
        if (correlation == 0) return null;
        for (self.npcs, 0..) |npc, index| {
            if (npc.population_member != null and
                npc.population_spawn_correlation == correlation)
            {
                return index;
            }
        }
        return null;
    }

    fn findNpcByPopulationGoalCorrelation(
        self: *const AuthorityCore,
        correlation: u64,
    ) ?usize {
        if (correlation == 0) return null;
        for (self.npcs, 0..) |npc, index| {
            if (npc.population_member != null and
                npc.population_goal_correlation == correlation)
            {
                return index;
            }
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
        return self.participantAvatarWorldPosition(participant_index);
    }

    /// Canonical world-space location occupied by a participant avatar. A
    /// driver occupies the vehicle chassis, not the retained hidden character
    /// controller pose. Every authority policy that reasons about player
    /// location must pass through this boundary.
    fn participantAvatarWorldPosition(
        self: *AuthorityCore,
        participant_index: usize,
    ) !?[3]f32 {
        if (participant_index >= self.participants.len) {
            return error.ParticipantAuthorityInvariantBroken;
        }
        const participant = self.participants[participant_index];
        const character = participant.character orelse {
            if (participant.driving_vehicle_index != null) {
                return error.VehicleAuthorityInvariantBroken;
            }
            return null;
        };
        const vehicle_index = participant.driving_vehicle_index orelse
            return (try self.simulation.character(character)).position;
        if (vehicle_index >= self.vehicles.len) {
            return error.VehicleAuthorityInvariantBroken;
        }
        const vehicle = self.vehicles[vehicle_index];
        if (!vehicle.active) return error.VehicleAuthorityInvariantBroken;
        const persistent = vehicle.persistent orelse
            return error.VehicleAuthorityInvariantBroken;
        const view = try self.simulation.vehicle(persistent);
        if (view.driver_id == null or !std.meta.eql(view.driver_id.?, character)) {
            return error.VehicleAuthorityInvariantBroken;
        }
        return view.state.chassis.pose.position;
    }

    fn registerHostNpc(
        self: *AuthorityCore,
        persistent: engine.PersistentId,
    ) !void {
        if (self.findNpcByPersistent(persistent) != null) return error.DuplicateHostNpc;
        for (&self.npcs) |*npc| {
            if (npc.population_member != null or npc.active or npc.spawn_pending) continue;
            npc.generation +%= 1;
            if (npc.generation == 0) npc.generation = 1;
            npc.active = true;
            npc.persistent = persistent;
            npc.replicated.generation = npc.generation;
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
        const replicated_index = self.npcs[index].replicated.index;
        self.npcs[index] = .{
            .generation = generation,
            .replicated = .{
                .index = replicated_index,
                .generation = generation,
            },
        };
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

fn dedicatedCoreConfig(authored_population: bool) CoreConfig {
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
            .authored_population = authored_population,
        },
        .world_bootstrap = .dedicated_fixture,
        .participant_spawn = .automatic,
        .observation = .disabled,
        .npc_interest = .full_world,
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
            dedicatedCoreConfig(true),
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

    pub fn transportIngressAvailable(self: *const DedicatedAuthority) bool {
        return self.stateConst().mailbox.transportIngressAvailable();
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

    pub fn populationDiagnostics(
        self: *const DedicatedAuthority,
    ) ?population_contract.Diagnostics {
        return self.stateConst().simulation.populationDiagnostics();
    }

    pub fn populationLogicalDigest(self: *const DedicatedAuthority) ?u64 {
        return self.stateConst().simulation.populationLogicalDigest();
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

    pub fn presentationQueries(self: *EmbeddedAuthority) EmbeddedPresentationQueryRole {
        return .{ .context = embeddedAuthorityCore(self) };
    }

    pub fn inspection(self: *const EmbeddedAuthority) EmbeddedInspectionRole {
        return .{ .context = embeddedAuthorityCoreConst(self) };
    }

    pub fn residency(self: *EmbeddedAuthority) EmbeddedResidencyRole {
        return .{ .context = embeddedAuthorityCore(self) };
    }
};

/// Read-only scene queries needed by the embedded graphical presentation host.
/// The role exposes value results only and keeps Simulation/Jolt ownership
/// inside the authority placement.
pub const EmbeddedPresentationQueryRole = struct {
    context: *anyopaque,

    pub fn lineHitFraction(
        self: EmbeddedPresentationQueryRole,
        start: [3]f32,
        end: [3]f32,
    ) !?f32 {
        return authorityCore(self.context).simulation.presentationLineHitFraction(start, end);
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

    pub fn transportIngressAvailable(self: EmbeddedSessionRole) bool {
        return authorityCore(self.context).mailbox.transportIngressAvailable();
    }

    pub fn rejectOversized(self: EmbeddedSessionRole, transport: TransportConnection) !void {
        try authorityCore(self.context).rejectOversized(transport);
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

    pub fn pollNavigationTransition(
        self: EmbeddedNpcRole,
    ) ?npc_contract.NavigationTransition {
        return authorityCore(
            self.context,
        ).observations.npc_navigation_transitions.pop();
    }

    pub fn pollPopulationTransition(
        self: EmbeddedNpcRole,
    ) ?population_contract.Transition {
        return authorityCore(self.context).observations.population_transitions.pop();
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

    pub fn submitNavigationGate(
        self: EmbeddedDeveloperRole,
        command: sandbox_replay.NavigationGateCommand,
    ) !bool {
        return authorityCore(self.context).simulation.submitNavigationGate(command);
    }

    pub fn navigationGateState(
        self: EmbeddedDeveloperRole,
    ) sandbox.NavigationGateState {
        return authorityCore(self.context).simulation.navigationGateState();
    }

    pub fn beginFlightRecording(
        self: EmbeddedDeveloperRole,
        content: sandbox_replay.ContentCohort,
    ) !sandbox.CaptureAdmission {
        return authorityCore(self.context).simulation.beginFlightRecording(content, .{});
    }

    pub fn snapshotFlightRecording(
        self: EmbeddedDeveloperRole,
        allocator: std.mem.Allocator,
    ) ![]u8 {
        return authorityCore(self.context).simulation.snapshotFlightRecording(allocator);
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

    /// Last committed authority-owned interest evaluation for one observer
    /// and NPC generation. This is diagnostic evidence, not a presentation
    /// source of truth.
    pub fn npcInterest(
        self: EmbeddedInspectionRole,
        participant: identity.ParticipantId,
        npc_entity: identity.ReplicatedEntityId,
    ) ?NpcInterestView {
        if (!participant.isValid() or participant.index == 0 or
            participant.index > budgets.max_participants)
        {
            return null;
        }
        const core = authorityCoreConst(self.context);
        const participant_index = @as(usize, participant.index) - 1;
        const participant_slot = core.participants[participant_index];
        if (!participant_slot.active or
            participant_slot.generation != participant.generation) return null;
        for (core.npcs, 0..) |npc, npc_index| {
            if ((!npc.active and npc.death_proxy == null) or
                !std.meta.eql(npc.replicated, npc_entity)) continue;
            return core.replication[participant_index].npc_interest[npc_index].view();
        }
        return null;
    }

    pub fn vehicleIdentity(
        self: EmbeddedInspectionRole,
        slot_index: usize,
    ) ?ReplicatedObjectIdentity {
        const core = authorityCoreConst(self.context);
        if (slot_index >= core.vehicles.len) return null;
        const slot = core.vehicles[slot_index];
        if (!slot.active or slot.persistent == null) return null;
        return .{ .replicated = slot.replicated, .persistent = slot.persistent.? };
    }

    pub fn carryableIdentity(
        self: EmbeddedInspectionRole,
        slot_index: usize,
    ) ?ReplicatedObjectIdentity {
        const core = authorityCoreConst(self.context);
        if (slot_index >= core.carryables.len) return null;
        const slot = core.carryables[slot_index];
        if (!slot.active or slot.persistent == null) return null;
        return .{ .replicated = slot.replicated, .persistent = slot.persistent.? };
    }

    pub fn vehicleInterest(
        self: EmbeddedInspectionRole,
        participant: identity.ParticipantId,
        entity: identity.ReplicatedEntityId,
    ) ?ObjectInterestView {
        if (!participant.isValid() or participant.index == 0 or
            participant.index > budgets.max_participants) return null;
        const core = authorityCoreConst(self.context);
        const participant_index = @as(usize, participant.index) - 1;
        const participant_slot = core.participants[participant_index];
        if (!participant_slot.active or
            participant_slot.generation != participant.generation) return null;
        for (core.vehicles, 0..) |vehicle, vehicle_index| {
            if (!vehicle.active or !std.meta.eql(vehicle.replicated, entity)) continue;
            const interest = core.replication[participant_index]
                .vehicle_interest[vehicle_index];
            if (interest.evaluated_tick == 0) return null;
            return interest.view();
        }
        return null;
    }

    pub fn carryableInterest(
        self: EmbeddedInspectionRole,
        participant: identity.ParticipantId,
        entity: identity.ReplicatedEntityId,
    ) ?ObjectInterestView {
        if (!participant.isValid() or participant.index == 0 or
            participant.index > budgets.max_participants) return null;
        const core = authorityCoreConst(self.context);
        const participant_index = @as(usize, participant.index) - 1;
        const participant_slot = core.participants[participant_index];
        if (!participant_slot.active or
            participant_slot.generation != participant.generation) return null;
        for (core.carryables, 0..) |carryable, carryable_index| {
            if (!carryable.active or !std.meta.eql(carryable.replicated, entity)) continue;
            const interest = core.replication[participant_index]
                .carryable_interest[carryable_index];
            if (interest.evaluated_tick == 0) return null;
            return interest.view();
        }
        return null;
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

    pub fn npcEncounter(
        self: EmbeddedInspectionRole,
        persistent: engine.PersistentId,
    ) ?npc_encounter_contract.View {
        const core = authorityCoreConst(self.context);
        const vital = core.simulation.currentVitals(.npc, persistent) orelse return null;
        return core.simulation.npcEncounter(vital.target);
    }

    pub fn npcEncounterDiagnostics(
        self: EmbeddedInspectionRole,
    ) npc_encounter_contract.Diagnostics {
        return authorityCoreConst(self.context).simulation.npcEncounterDiagnostics();
    }

    pub fn populationMembers(
        self: EmbeddedInspectionRole,
    ) []const population_contract.MemberRecordV1 {
        return authorityCoreConst(self.context).simulation.populationMembers();
    }

    pub fn populationSlots(
        self: EmbeddedInspectionRole,
    ) []const population_contract.ActivitySlotRecordV1 {
        return authorityCoreConst(self.context).simulation.populationSlots();
    }

    pub fn populationDiagnostics(
        self: EmbeddedInspectionRole,
    ) ?population_contract.Diagnostics {
        return authorityCoreConst(self.context).simulation.populationDiagnostics();
    }

    pub fn populationCatalog(
        self: EmbeddedInspectionRole,
    ) population_contract.Catalog {
        return authorityCoreConst(self.context).simulation.populationCatalog();
    }

    pub fn copyNpcEncounterTransitions(
        self: EmbeddedInspectionRole,
        storage: []npc_encounter_contract.Transition,
    ) ![]const npc_encounter_contract.Transition {
        return authorityCoreConst(self.context).simulation.copyNpcEncounterTransitions(storage);
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

fn districtCenterPosition(coord: district_contract.ChunkCoord) [3]f32 {
    return .{
        @as(f32, @floatFromInt(coord.x)) * district_contract.chunk_span,
        0,
        @as(f32, @floatFromInt(coord.z)) * district_contract.chunk_span,
    };
}

fn authorityDistrictIndex(coord: district_contract.ChunkCoord) ?usize {
    for (sandbox_district_recipe.installed_coords, 0..) |candidate, index| {
        if (std.meta.eql(coord, candidate)) return index;
    }
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

fn evaluateNpcInterest(
    mode: NpcInterestMode,
    state: *NpcInterestState,
    authority_tick: u64,
    observer_position: [3]f32,
    observer_district: district_contract.ChunkCoord,
    npc_position: [3]f32,
    owner_district: district_contract.ChunkCoord,
    encounter_relevant: bool,
) bool {
    const dx = npc_position[0] - observer_position[0];
    const dz = npc_position[2] - observer_position[2];
    const distance_squared = dx * dx + dz * dz;
    const same_district = std.meta.eql(observer_district, owner_district);
    const enter_squared = npc_interest_enter_distance * npc_interest_enter_distance;
    const exit_squared = npc_interest_exit_distance * npc_interest_exit_distance;

    var included = false;
    var reason: NpcInterestReason = .excluded;
    if (mode == .full_world) {
        included = true;
        reason = .full_world;
    } else if (same_district) {
        included = true;
        reason = .same_district;
    } else if (encounter_relevant) {
        included = true;
        reason = .encounter;
    } else if (!state.included and distance_squared <= enter_squared) {
        included = true;
        reason = .proximity_enter;
    } else if (state.included and distance_squared <= exit_squared) {
        included = true;
        reason = .proximity_retained;
    } else if (state.included and authority_tick <= state.grace_until_tick) {
        included = true;
        reason = .grace;
    }

    if (mode == .full_world) {
        state.grace_until_tick = 0;
    } else if (included and reason != .grace) {
        state.grace_until_tick = authority_tick +| npc_interest_exit_grace_ticks;
    } else if (!included) {
        state.grace_until_tick = 0;
    }
    state.included = included;
    state.reason = reason;
    state.evaluated_tick = authority_tick;
    state.observer_position = observer_position;
    state.npc_position = npc_position;
    state.observer_district = observer_district;
    state.owner_district = owner_district;
    state.distance_squared_xz = distance_squared;
    state.encounter_relevant = encounter_relevant;
    return included;
}

fn recordObjectInterest(
    state: *ObjectInterestState,
    authority_tick: u64,
    baseline_id: u32,
    snapshot_sequence: u32,
    observer_position: [3]f32,
    observer_district: district_contract.ChunkCoord,
    object_position: [3]f32,
    reason: ObjectInterestReason,
) void {
    state.* = .{
        .included = true,
        .reason = reason,
        .evaluated_tick = authority_tick,
        .baseline_id = baseline_id,
        .snapshot_sequence = snapshot_sequence,
        .observer_position = observer_position,
        .object_position = object_position,
        .observer_district = observer_district,
        .owner_district = district_contract.chunkCoordForWorldPosition(
            object_position,
        ) catch observer_district,
        .distance_squared_xz = horizontalDistanceSquared(
            observer_position,
            object_position,
        ),
    };
}

test "bounded object interest records cross-district snapshot causality" {
    var state = ObjectInterestState{};
    recordObjectInterest(
        &state,
        42,
        7,
        19,
        .{ -2, 0, 4 },
        sandbox_district_recipe.navigation_west_coord,
        .{ 18, 1, 4 },
        .bounded_world,
    );
    const view = state.view();
    try std.testing.expect(view.included);
    try std.testing.expectEqual(ObjectInterestReason.bounded_world, view.reason);
    try std.testing.expectEqual(@as(u64, 42), view.evaluated_tick);
    try std.testing.expectEqual(@as(u32, 7), view.baseline_id);
    try std.testing.expectEqual(@as(u32, 19), view.snapshot_sequence);
    try std.testing.expect(!std.meta.eql(view.observer_district, view.owner_district));
    try std.testing.expectEqual(@as(f32, 400), view.distance_squared_xz);
}

fn fingerprintIngress(seed: u64, record: AcceptedIngress) u64 {
    return record.fingerprintFromTickOrigin(seed, 0);
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

fn populationNpcIndex(
    member: population_contract.PopulationMemberId,
) !usize {
    try member.validate();
    const index = @as(usize, member.value) - 1;
    if (index >= population_contract.ordinary_member_count or
        index >= budgets.max_npcs)
    {
        return error.PopulationMemberOutsideProductCohort;
    }
    return index;
}

fn populationSpawnRetryReason(
    reason: npc_contract.RejectionReason,
) !population_contract.SpawnRetryReason {
    return switch (reason) {
        .capacity_reached, .controller_capacity_reached => .capacity,
        .start_district_inactive => .district_inactive,
        .start_pose_blocked => .occupied,
        .invalid_start_node => error.InvalidAuthoredPopulationAnchor,
        .goal_district_inactive,
        .invalid_goal,
        .unreachable_goal,
        .npc_not_found,
        .not_owned,
        => error.InvalidPopulationSpawnRejection,
    };
}

fn protocolLifeState(state: vitals_contract.LifeState) protocol.AvatarLifeState {
    return switch (state) {
        .alive => .alive,
        .dead => .dead,
    };
}

fn protocolWeaponMode(mode: ranged_combat_contract.Mode) protocol.WeaponMode {
    return switch (mode) {
        .holstered => .holstered,
        .equipped => .equipped,
        .reloading => .reloading,
    };
}

fn protocolWeaponAction(action: protocol.WeaponActionKind) ranged_combat_contract.Action {
    return switch (action) {
        .equip_toggle => .equip_toggle,
        .fire => .fire,
        .reload => .reload,
    };
}

fn protocolWeaponDisposition(
    disposition: ranged_combat_contract.Disposition,
) protocol.WeaponActionDisposition {
    return switch (disposition) {
        .equipped => .equipped,
        .holstered => .holstered,
        .shot_admitted => unreachable,
        .reload_started => .reload_started,
        .cooldown => .cooldown,
        .empty => .empty,
        .already_full => .already_full,
        .no_reserve => .no_reserve,
        .reloading => .reloading,
        .not_equipped => .not_equipped,
        .invalid_state => .invalid_state,
    };
}

fn addScaled(origin: [3]f32, direction: [3]f32, distance: f32) [3]f32 {
    return .{
        origin[0] + direction[0] * distance,
        origin[1] + direction[1] * distance,
        origin[2] + direction[2] * distance,
    };
}

fn raySphereFraction(
    origin: [3]f32,
    endpoint: [3]f32,
    center: [3]f32,
    radius: f32,
) ?f32 {
    const direction = [3]f32{
        endpoint[0] - origin[0],
        endpoint[1] - origin[1],
        endpoint[2] - origin[2],
    };
    const relative = [3]f32{
        origin[0] - center[0],
        origin[1] - center[1],
        origin[2] - center[2],
    };
    const a = dot3(direction, direction);
    if (a <= 0.000001) return null;
    const b = 2 * dot3(relative, direction);
    const c = dot3(relative, relative) - radius * radius;
    const discriminant = b * b - 4 * a * c;
    if (discriminant < 0) return null;
    const root = @sqrt(discriminant);
    const first = (-b - root) / (2 * a);
    const second = (-b + root) / (2 * a);
    if (first >= 0 and first <= 1) return first;
    if (second >= 0 and second <= 1) return second;
    return null;
}

fn dot3(first: [3]f32, second: [3]f32) f32 {
    return first[0] * second[0] + first[1] * second[1] + first[2] * second[2];
}

fn considerRangedTarget(selected: *?RangedTarget, candidate: RangedTarget) void {
    if (selected.* == null or candidate.hit_fraction < selected.*.?.hit_fraction or
        (candidate.hit_fraction == selected.*.?.hit_fraction and
            candidate.replicated.index < selected.*.?.replicated.index))
    {
        selected.* = candidate;
    }
}

fn protocolNpcEncounterState(
    state: npc_encounter_contract.State,
) protocol.NpcEncounterState {
    return switch (state) {
        .patrolling => .patrolling,
        .pursuing => .pursuing,
        .attack_windup => .attack_windup,
        .attack_recovery => .attack_recovery,
        .searching => .searching,
        .returning => .returning,
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

fn weaponDamageCorrelation(index: usize, sequence: identity.ActionSequence) u64 {
    return 0x5331_3400_0000_0000 |
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
    if (raw == 0 or raw > sandbox_district_recipe.installed_coords.len) return null;
    return raw - 1;
}

fn districtBootstrapCoord(index: usize) district_contract.ChunkCoord {
    return sandbox_district_recipe.installed_coords[index];
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

fn npcNodePosition(reference: npc_contract.NodeRef) [3]f32 {
    const build = switch (sandbox_district_recipe.build(
        reference.coord,
        sandbox_district_recipe.current_recipe_version,
    )) {
        .ready => |value| value,
        .failed => unreachable,
    };
    return build.navigation_nodes[reference.index].position;
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
        .npc_interest = .full_world,
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

fn initTestDedicatedAuthority(
    authored_population: bool,
) !*DedicatedAuthority {
    return @ptrCast(try createAuthorityCore(
        std.testing.allocator,
        dedicatedCoreConfig(authored_population),
        .{},
        null,
        false,
    ));
}

const CombatVehicleFixture = struct {
    authority: *EmbeddedAuthority,
    attacker_transport: TransportConnection,
    target_transport: TransportConnection,
    attacker: protocol.Welcome,
    target: protocol.Welcome,
    vehicle: identity.ReplicatedEntityId,

    fn deinit(self: CombatVehicleFixture) void {
        self.authority.deinit();
    }
};

const RangedCombatFixture = struct {
    authority: *EmbeddedAuthority,
    attacker_transport: TransportConnection,
    target_transport: TransportConnection,
    attacker: protocol.Welcome,
    target: protocol.Welcome,

    fn deinit(self: RangedCombatFixture) void {
        self.authority.deinit();
    }
};

const TestWeaponDelivery = struct {
    result: protocol.WeaponActionResult,
    shot: ?protocol.ShotEvent,
};

fn initRangedCombatFixture(namespace: u64) !RangedCombatFixture {
    const authority = try initTestEmbeddedAuthority(
        testEmbeddedCoreConfig(namespace, .host_managed),
        .{},
        0x84,
    );
    errdefer authority.deinit();
    const session = authority.session();
    const attacker_transport = TransportConnection{ .value = 841 };
    const target_transport = TransportConnection{ .value = 842 };
    _ = try session.openConnection(attacker_transport);
    try session.ingest(attacker_transport, .{ .hello = .{
        .account = .{ .value = 841 },
    } });
    _ = try session.openConnection(target_transport);
    try session.ingest(target_transport, .{ .hello = .{
        .account = .{ .value = 842 },
    } });
    try session.tick();
    var attacker: ?protocol.Welcome = null;
    var target: ?protocol.Welcome = null;
    while (takeOutboundForTest(session)) |outbound| switch (outbound.message) {
        .welcome => |welcome| if (outbound.connection.value == attacker_transport.value) {
            attacker = welcome;
        } else if (outbound.connection.value == target_transport.value) {
            target = welcome;
        },
        else => {},
    };
    const attacker_welcome = attacker orelse return error.MissingAttackerWelcome;
    const target_welcome = target orelse return error.MissingTargetWelcome;
    try authority.characters().spawnParticipant(attacker_transport, .{
        .request_id = 1,
        .position = .{ 0, 0, 2 },
    });
    try authority.characters().spawnParticipant(target_transport, .{
        .request_id = 2,
        .position = .{ 0, 0, -2 },
    });
    const core = embeddedAuthorityCore(authority);
    const attacker_index = @as(usize, attacker_welcome.participant.index) - 1;
    const target_index = @as(usize, target_welcome.participant.index) - 1;
    var ready = false;
    for (0..16) |_| {
        try session.tick();
        while (authority.characters().pollOutcome() != null) {}
        while (takeOutboundForTest(session) != null) {}
        if (core.participants[attacker_index].lifecycle == .alive and
            !core.participants[attacker_index].vitals_pending and
            core.participants[target_index].lifecycle == .alive and
            !core.participants[target_index].vitals_pending)
        {
            ready = true;
            break;
        }
    }
    if (!ready) return error.RangedCombatFixtureNotReady;
    try session.ingest(attacker_transport, .{ .input = .{
        .session = attacker_welcome.session,
        .participant = attacker_welcome.participant,
        .sequence = .{ .value = 1 },
        .target_tick = core.simulation.tickIndex() +| 1,
        .move = .{ 0, 0 },
        .facing_yaw = 0,
        .jump_pressed = false,
    } });
    try session.tick();
    while (takeOutboundForTest(session) != null) {}
    return .{
        .authority = authority,
        .attacker_transport = attacker_transport,
        .target_transport = target_transport,
        .attacker = attacker_welcome,
        .target = target_welcome,
    };
}

fn submitWeaponActionForTest(
    fixture: *RangedCombatFixture,
    sequence: u32,
    kind: protocol.WeaponActionKind,
) !TestWeaponDelivery {
    const session = fixture.authority.session();
    const core = embeddedAuthorityCore(fixture.authority);
    const attacker_index = @as(usize, fixture.attacker.participant.index) - 1;
    try session.ingest(fixture.attacker_transport, .{ .weapon_action = .{
        .session = fixture.attacker.session,
        .participant = fixture.attacker.participant,
        .sequence = .{ .value = sequence },
        .avatar_incarnation = core.participants[attacker_index].avatar_incarnation,
        .target_tick = core.simulation.tickIndex() +| 1,
        .kind = kind,
    } });
    var result: ?protocol.WeaponActionResult = null;
    var shot: ?protocol.ShotEvent = null;
    for (0..4) |_| {
        try session.tick();
        while (takeOutboundForTest(session)) |outbound| switch (outbound.message) {
            .weapon_action_result => |value| if (outbound.connection.value == fixture.attacker_transport.value and
                value.sequence.value == sequence)
            {
                result = value;
            },
            .shot_event => |value| if (value.sequence.value == sequence and shot == null) {
                shot = value;
            },
            else => {},
        };
        if (result != null) break;
    }
    return .{
        .result = result orelse return error.MissingWeaponActionResult,
        .shot = shot,
    };
}

fn initCombatVehicleFixture(
    namespace: u64,
    vehicle_rotation: [4]f32,
) !CombatVehicleFixture {
    var config = testEmbeddedCoreConfig(namespace, .host_managed);
    config.simulation.vehicle.max_entry_distance = 5;
    const authority = try initTestEmbeddedAuthority(config, .{}, 0x82);
    errdefer authority.deinit();
    const session = authority.session();
    const attacker_transport = TransportConnection{ .value = 791 };
    const target_transport = TransportConnection{ .value = 792 };
    _ = try session.openConnection(attacker_transport);
    try session.ingest(attacker_transport, .{ .hello = .{
        .account = .{ .value = 791 },
    } });
    _ = try session.openConnection(target_transport);
    try session.ingest(target_transport, .{ .hello = .{
        .account = .{ .value = 792 },
    } });
    try session.tick();
    var attacker: ?protocol.Welcome = null;
    var target: ?protocol.Welcome = null;
    while (takeOutboundForTest(session)) |outbound| switch (outbound.message) {
        .welcome => |welcome| if (outbound.connection.value == attacker_transport.value) {
            attacker = welcome;
        } else if (outbound.connection.value == target_transport.value) {
            target = welcome;
        },
        else => {},
    };
    const attacker_welcome = attacker orelse return error.MissingAttackerWelcome;
    const target_welcome = target orelse return error.MissingTargetWelcome;

    try authority.characters().spawnParticipant(attacker_transport, .{
        .request_id = 1,
        .position = .{ 0, 0, 2 },
    });
    try authority.characters().spawnParticipant(target_transport, .{
        .request_id = 2,
        .position = .{ 2, 0, 2 },
    });
    try authority.vehicles().submit(.{ .spawn = .{
        .request_id = 3,
        .chassis = .{ .pose = .{
            .position = .{ 0, 2, 0 },
            .rotation = vehicle_rotation,
        } },
    } });
    try session.tick();
    while (authority.characters().pollOutcome() != null) {}
    while (authority.vehicles().pollOutcome() != null) {}
    while (takeOutboundForTest(session) != null) {}

    const core = embeddedAuthorityCore(authority);
    const attacker_index = @as(usize, attacker_welcome.participant.index) - 1;
    const target_index = @as(usize, target_welcome.participant.index) - 1;
    var ready = false;
    for (0..16) |_| {
        if (core.participants[attacker_index].lifecycle == .alive and
            !core.participants[attacker_index].vitals_pending and
            core.participants[target_index].lifecycle == .alive and
            !core.participants[target_index].vitals_pending and
            core.vehicles[0].active)
        {
            ready = true;
            break;
        }
        try session.tick();
        while (takeOutboundForTest(session) != null) {}
    }
    if (!ready) return error.CombatVehicleFixtureNotReady;
    for (0..120) |_| {
        try session.tick();
        while (takeOutboundForTest(session) != null) {}
    }
    try session.ingest(attacker_transport, .{ .input = .{
        .session = attacker_welcome.session,
        .participant = attacker_welcome.participant,
        .sequence = .{ .value = 1 },
        .target_tick = core.simulation.tickIndex() +| 1,
        .move = .{ 0, 0 },
        .facing_yaw = std.math.pi / 2.0,
        .jump_pressed = false,
    } });
    try session.tick();
    while (takeOutboundForTest(session) != null) {}
    const melee_target = try core.selectMeleeTarget(attacker_index) orelse
        return error.MissingCombatVehicleMeleeTarget;
    if (!std.meta.eql(melee_target.persistent, core.participants[target_index].character.?)) {
        return error.UnexpectedCombatVehicleMeleeTarget;
    }
    return .{
        .authority = authority,
        .attacker_transport = attacker_transport,
        .target_transport = target_transport,
        .attacker = attacker_welcome,
        .target = target_welcome,
        .vehicle = core.vehicles[0].replicated,
    };
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

test "automatic participant slots cover capacity and clear canonical blockers" {
    const west = sandbox_district_recipe.build(
        sandbox_district_recipe.navigation_west_coord,
        sandbox_district_recipe.current_recipe_version,
    ).ready;
    const clearance = sandbox_district_recipe.CapsuleClearance{
        .radius = (sandbox_host_contracts.CharacterConfig{}).radius,
        .half_height = (sandbox_host_contracts.CharacterConfig{}).half_height,
        .margin = 0.05,
    };
    try std.testing.expectEqual(budgets.max_participants, automatic_spawn_candidates.len);
    for (automatic_spawn_candidates, 0..) |candidate, index| {
        try std.testing.expect(sandbox_district_recipe.capsuleTraversalClear(
            &west,
            candidate,
            candidate,
            clearance,
        ));
        for (automatic_spawn_candidates[index + 1 ..]) |other| {
            try std.testing.expect(horizontalDistanceSquared(candidate, other) >= 2.25);
        }
    }
}

test "automatic product NPC fixture uses every authored member spawn once" {
    try std.testing.expectEqual(
        population_contract.ordinary_member_count,
        budgets.product_npcs,
    );
    for (0..budgets.product_npcs) |index| {
        const candidate = sandbox_population_catalog.members[index].initial_spawn_slot;
        for (0..index) |earlier_index| {
            try std.testing.expect(!population_contract.SpawnSlotId.eql(
                candidate,
                sandbox_population_catalog.members[earlier_index].initial_spawn_slot,
            ));
        }
    }
}

test "automatic admission reserves product capacity around the live fixture" {
    const authority = try initTestDedicatedAuthority(true);
    defer authority.deinit();
    const core = authority.state();
    var fixture_settled = false;
    for (0..256) |_| {
        var settled_npcs: usize = 0;
        for (core.npcs) |npc| {
            settled_npcs += @intFromBool(
                npc.active and npc.persistent != null and
                    !npc.spawn_pending and !npc.vitals_pending and
                    !npc.despawn_pending,
            );
        }
        if (core.vehicles[0].active and settled_npcs == budgets.product_npcs) {
            fixture_settled = true;
            break;
        }
        try authority.tick();
        while (takeOutboundForTest(authority) != null) {}
        std.Thread.yield() catch {};
    }
    if (!fixture_settled) {
        std.debug.print(
            "S13 fixture did not settle: tick={} population={any}\n",
            .{
                core.simulation.tickIndex(),
                core.simulation.populationDiagnostics(),
            },
        );
        for (core.npcs[0..budgets.product_npcs], 0..) |npc, index| {
            std.debug.print("  member={} npc={any}\n", .{ index + 1, npc });
        }
    }
    try std.testing.expect(fixture_settled);

    for (0..budgets.product_participants) |participant_index| {
        const candidate = try core.selectInitialSpawnPosition(participant_index) orelse
            return error.AutomaticSpawnCapacityUnavailable;
        const participant = &core.participants[participant_index];
        participant.active = true;
        participant.lifecycle = .spawning;
        participant.reserved_spawn_position = candidate;
    }
}

test "spawning character remains occupied during reservation handoff" {
    const authority = try initTestDedicatedAuthority(false);
    defer authority.deinit();
    const core = authority.state();
    const transport = TransportConnection{ .value = 101 };
    _ = try authority.openConnection(transport);
    try authority.ingest(transport, .{ .hello = .{
        .account = .{ .value = 101 },
    } });
    _ = takeOutboundForTest(authority) orelse return error.MissingSpawnHandoffWelcome;

    var character_spawned = false;
    for (0..16) |_| {
        if (core.participants[0].character != null) {
            character_spawned = true;
            break;
        }
        try authority.tick();
        while (takeOutboundForTest(authority) != null) {}
    }
    try std.testing.expect(character_spawned);
    const character = try core.simulation.character(core.participants[0].character.?);
    try std.testing.expectEqual(automatic_spawn_candidates[0], character.position);

    // Recreate the respawn outcome -> vitals registration handoff: the spawn
    // reservation is gone, the character exists, and lifecycle is spawning.
    core.participants[0].lifecycle = .spawning;
    core.participants[0].reserved_spawn_position = automatic_spawn_candidates[15];
    for (2..budgets.max_participants) |participant_index| {
        const participant = &core.participants[participant_index];
        participant.active = true;
        participant.lifecycle = .spawning;
        participant.reserved_spawn_position = automatic_spawn_candidates[participant_index - 1];
    }
    try std.testing.expect((try core.selectInitialSpawnPosition(1)) == null);
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
        authority.npcs().submit(.{ .spawn = .{
            .request_id = 6,
            .position = .{ 0, 0, 0 },
            .facing_yaw = 0,
            .anchor = .{},
            .hostile_to_players = false,
        } }),
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

test "durable barrier drains population then resumes population and replication" {
    var config = testEmbeddedCoreConfig(0x454d_4418, .host_managed);
    config.simulation.authored_population = true;
    const authority = try EmbeddedAuthority.init(std.testing.allocator, config);
    defer authority.deinit();
    const core = embeddedAuthorityCore(authority);
    const source = try authority.persistence().issueSource();
    const transport = TransportConnection{ .value = 1 };
    _ = try authority.session().openConnection(transport);
    try authority.session().ingest(transport, .{ .hello = .{
        .account = .{ .value = 1 },
    } });
    var saw_transient_deferral = false;

    while (true) {
        const request_id = try source.request();
        try authority.session().tick();
        const disposition = (try source.take(request_id)) orelse
            return error.MissingDurableCaptureDisposition;
        switch (disposition) {
            .deferred => {
                saw_transient_deferral = true;
                if (authority.session().beginOutboundLease()) |lease| {
                    try authority.session().commitOutboundLease(lease.generation);
                }
            },
            .captured => |bytes| {
                defer source.release(bytes);
                try std.testing.expect(bytes.len != 0);
                break;
            },
            .failed => |err| return err,
        }
    }
    try std.testing.expect(saw_transient_deferral);
    try std.testing.expect(core.simulation.operationalQuiescenceReason() == null);
    try std.testing.expect(core.force_snapshot);
    const population_before_resume = core.simulation.populationLogicalDigest().?;

    // Releasing the durable request also releases the one-cycle population
    // scheduling barrier. Its next accepted step changes the population-owned
    // logical state, while ordinary replication is again permitted.
    try authority.session().tick();
    try std.testing.expect(
        core.simulation.populationLogicalDigest().? != population_before_resume,
    );
    try std.testing.expect(!core.force_snapshot);
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

test "transient population snapshot boundaries defer durable capture" {
    inline for (.{
        error.PopulationActorLifecycleIncomplete,
        error.PopulationOutputsPending,
        error.PopulationTransactionPending,
    }) |err| {
        const disposition = AuthorityCore.durableSaveFailure(err);
        try std.testing.expectEqual(
            snapshot_source.Deferral.session_work,
            disposition.deferred,
        );
    }

    const disposition = AuthorityCore.durableSaveFailure(error.InvalidSnapshotMagic);
    try std.testing.expectEqual(
        error.InvalidSnapshotMagic,
        disposition.failed,
    );
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
    const authority = try initTestDedicatedAuthority(false);
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
    const authority = try initTestDedicatedAuthority(false);
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

test "authoritative final shot projects automatic reload without synthetic ingress" {
    var fixture = try initRangedCombatFixture(0x454d_4422);
    defer fixture.deinit();
    const session = fixture.authority.session();
    const core = embeddedAuthorityCore(fixture.authority);
    const attacker_index = @as(usize, fixture.attacker.participant.index) - 1;

    const equipped = try submitWeaponActionForTest(&fixture, 1, .equip_toggle);
    try std.testing.expectEqual(protocol.WeaponActionDisposition.equipped, equipped.result.disposition);
    core.participants[attacker_index].weapon.magazine = 1;
    core.participants[attacker_index].weapon.next_fire_tick = 0;

    const final_shot = try submitWeaponActionForTest(&fixture, 2, .fire);
    try std.testing.expectEqual(protocol.WeaponActionDisposition.fired_hit, final_shot.result.disposition);
    try std.testing.expect(final_shot.shot != null);
    try std.testing.expectEqual(protocol.WeaponMode.reloading, final_shot.result.mode);
    try std.testing.expectEqual(@as(u16, 0), final_shot.result.magazine_ammo);
    try std.testing.expectEqual(@as(u16, 36), final_shot.result.reserve_ammo);
    try std.testing.expect(final_shot.result.reload_complete_tick > final_shot.result.authority_tick);
    try std.testing.expectEqual(
        ranged_combat_contract.Mode.reloading,
        core.participants[attacker_index].weapon.mode,
    );

    const blocked_fire = try submitWeaponActionForTest(&fixture, 3, .fire);
    try std.testing.expectEqual(protocol.WeaponActionDisposition.reloading, blocked_fire.result.disposition);
    try std.testing.expect(blocked_fire.shot == null);
    try std.testing.expectEqual(
        final_shot.result.reload_complete_tick,
        blocked_fire.result.reload_complete_tick,
    );

    for (0..handgun_config.reload_ticks + 2) |_| {
        if (core.participants[attacker_index].weapon.mode == .equipped) break;
        try session.tick();
        while (takeOutboundForTest(session) != null) {}
    }
    try std.testing.expectEqual(
        ranged_combat_contract.Mode.equipped,
        core.participants[attacker_index].weapon.mode,
    );
    try std.testing.expectEqual(@as(u16, 12), core.participants[attacker_index].weapon.magazine);
    try std.testing.expectEqual(@as(u16, 24), core.participants[attacker_index].weapon.reserve);

    try std.testing.expectEqual(
        @as(u16, 3),
        session.diagnostics().ingress_entries,
    );
    var ingress_records: [3]AcceptedIngress = undefined;
    const ingress_count = session.copyAcceptedIngress(&ingress_records);
    try std.testing.expectEqual(@as(usize, ingress_records.len), ingress_count);
    var equip_records: u8 = 0;
    var fire_records: u8 = 0;
    var reload_records: u8 = 0;
    for (ingress_records[0..ingress_count]) |record| switch (record.kind) {
        .weapon_equip_toggle => equip_records += 1,
        .weapon_fire => fire_records += 1,
        .weapon_reload => reload_records += 1,
        else => {},
    };
    try std.testing.expectEqual(@as(u8, 1), equip_records);
    try std.testing.expectEqual(@as(u8, 1), fire_records);
    try std.testing.expectEqual(@as(u8, 0), reload_records);
}

test "authoritative handgun owns hit cadence reload reconnect miss and death" {
    var fixture = try initRangedCombatFixture(0x454d_4421);
    defer fixture.deinit();
    const session = fixture.authority.session();
    const core = embeddedAuthorityCore(fixture.authority);
    const attacker_index = @as(usize, fixture.attacker.participant.index) - 1;
    const target_index = @as(usize, fixture.target.participant.index) - 1;

    const equipped = try submitWeaponActionForTest(&fixture, 1, .equip_toggle);
    try std.testing.expectEqual(protocol.WeaponActionDisposition.equipped, equipped.result.disposition);
    try std.testing.expectEqual(protocol.WeaponMode.equipped, equipped.result.mode);
    try std.testing.expectEqual(handgun_config.magazine_capacity, equipped.result.magazine_ammo);
    try std.testing.expect(equipped.shot == null);

    const first_hit = try submitWeaponActionForTest(&fixture, 2, .fire);
    try std.testing.expectEqual(protocol.WeaponActionDisposition.fired_hit, first_hit.result.disposition);
    try std.testing.expectEqual(handgun_config.damage, first_hit.result.applied_damage);
    try std.testing.expectEqual(@as(u16, 75), first_hit.result.remaining_health);
    try std.testing.expectEqual(core.participants[target_index].replicated, first_hit.result.target);
    try std.testing.expectEqual(
        protocol.ShotDisposition.hit,
        (first_hit.shot orelse return error.MissingAuthoritativeShotEvent).disposition,
    );

    const cooldown = try submitWeaponActionForTest(&fixture, 3, .fire);
    try std.testing.expectEqual(protocol.WeaponActionDisposition.cooldown, cooldown.result.disposition);
    try std.testing.expectEqual(@as(u16, 11), cooldown.result.magazine_ammo);
    try std.testing.expect(cooldown.shot == null);

    const reload = try submitWeaponActionForTest(&fixture, 4, .reload);
    try std.testing.expectEqual(protocol.WeaponActionDisposition.reload_started, reload.result.disposition);
    try std.testing.expectEqual(protocol.WeaponMode.reloading, reload.result.mode);
    try std.testing.expect(reload.result.reload_complete_tick > core.simulation.tickIndex());

    _ = try session.transportClosed(fixture.attacker_transport);
    try session.tick();
    while (takeOutboundForTest(session) != null) {}
    const reconnected_transport = TransportConnection{ .value = 843 };
    _ = try session.openConnection(reconnected_transport);
    try session.ingest(reconnected_transport, .{ .hello = .{
        .account = .{ .value = 841 },
        .reconnect = fixture.attacker.reconnect,
    } });
    try session.tick();
    var reconnected: ?protocol.Welcome = null;
    var welcome_delivery_id: u64 = 0;
    while (takeOutboundForTest(session)) |outbound| switch (outbound.message) {
        .welcome => |welcome| if (outbound.connection.value == reconnected_transport.value) {
            reconnected = welcome;
            welcome_delivery_id = outbound.delivery_id;
        },
        else => {},
    };
    const reconnected_welcome = reconnected orelse return error.MissingWeaponReconnectWelcome;
    try std.testing.expectEqual(protocol.WeaponMode.reloading, reconnected_welcome.weapon_mode);
    try std.testing.expectEqual(@as(u16, 11), reconnected_welcome.magazine_ammo);
    try std.testing.expectEqual(@as(u16, 36), reconnected_welcome.reserve_ammo);
    try std.testing.expectEqual(reload.result.reload_complete_tick, reconnected_welcome.reload_complete_tick);
    fixture.attacker_transport = reconnected_transport;
    fixture.attacker = reconnected_welcome;
    try session.ingest(reconnected_transport, .{ .delivery_receipt = .{
        .session = reconnected_welcome.session,
        .participant = reconnected_welcome.participant,
        .lane = .control,
        .delivery_id = welcome_delivery_id,
    } });
    try session.tick();
    var gameplay_delivery_id: u64 = 0;
    while (takeOutboundForTest(session)) |outbound| {
        if (outbound.connection.value == reconnected_transport.value and
            outbound.lane == .gameplay)
        {
            gameplay_delivery_id = @max(gameplay_delivery_id, outbound.delivery_id);
        }
    }
    if (gameplay_delivery_id != 0) {
        try session.ingest(reconnected_transport, .{ .delivery_receipt = .{
            .session = reconnected_welcome.session,
            .participant = reconnected_welcome.participant,
            .lane = .gameplay,
            .delivery_id = gameplay_delivery_id,
        } });
        try session.tick();
        while (takeOutboundForTest(session) != null) {}
    }

    for (0..handgun_config.reload_ticks + 2) |_| {
        if (core.participants[attacker_index].weapon.mode == .equipped) break;
        try session.tick();
        while (takeOutboundForTest(session) != null) {}
    }
    try std.testing.expectEqual(ranged_combat_contract.Mode.equipped, core.participants[attacker_index].weapon.mode);
    try std.testing.expectEqual(@as(u16, 12), core.participants[attacker_index].weapon.magazine);
    try std.testing.expectEqual(@as(u16, 35), core.participants[attacker_index].weapon.reserve);

    try session.ingest(fixture.attacker_transport, .{ .input = .{
        .session = fixture.attacker.session,
        .participant = fixture.attacker.participant,
        .sequence = .{ .value = 2 },
        .target_tick = core.simulation.tickIndex() +| 1,
        .move = .{ 0, 0 },
        .facing_yaw = std.math.pi,
        .jump_pressed = false,
    } });
    try session.tick();
    while (takeOutboundForTest(session) != null) {}
    const miss = try submitWeaponActionForTest(&fixture, 5, .fire);
    try std.testing.expectEqual(protocol.WeaponActionDisposition.fired_miss, miss.result.disposition);
    try std.testing.expect(!miss.result.target.isValid());
    try std.testing.expectEqual(
        protocol.ShotDisposition.miss,
        (miss.shot orelse return error.MissingAuthoritativeMissEvent).disposition,
    );

    try session.ingest(fixture.attacker_transport, .{ .input = .{
        .session = fixture.attacker.session,
        .participant = fixture.attacker.participant,
        .sequence = .{ .value = 3 },
        .target_tick = core.simulation.tickIndex() +| 1,
        .move = .{ 0, 0 },
        .facing_yaw = 0,
        .jump_pressed = false,
    } });
    try session.tick();
    while (takeOutboundForTest(session) != null) {}
    var killing_result: ?protocol.WeaponActionResult = null;
    for (0..3) |shot_index| {
        while (core.simulation.tickIndex() < core.participants[attacker_index].weapon.next_fire_tick) {
            try session.tick();
            while (takeOutboundForTest(session) != null) {}
        }
        const delivery = try submitWeaponActionForTest(
            &fixture,
            @intCast(6 + shot_index),
            .fire,
        );
        try std.testing.expectEqual(protocol.WeaponActionDisposition.fired_hit, delivery.result.disposition);
        killing_result = delivery.result;
    }
    try std.testing.expect((killing_result orelse return error.MissingKillingShotResult).killed);
    for (0..3) |_| {
        if (core.participants[target_index].character == null) break;
        try session.tick();
        while (takeOutboundForTest(session) != null) {}
    }
    try std.testing.expectEqual(PlayerLifecycle.dead, core.participants[target_index].lifecycle);
    try std.testing.expect(core.participants[target_index].character == null);
    try std.testing.expectEqual(@as(u64, 4), core.firearm_hits);
    var ingress_records: [16]AcceptedIngress = undefined;
    const ingress_count = session.copyAcceptedIngress(&ingress_records);
    var equip_records: u8 = 0;
    var fire_records: u8 = 0;
    var reload_records: u8 = 0;
    for (ingress_records[0..ingress_count]) |record| switch (record.kind) {
        .weapon_equip_toggle => equip_records += 1,
        .weapon_fire => fire_records += 1,
        .weapon_reload => reload_records += 1,
        else => {},
    };
    try std.testing.expectEqual(@as(u8, 1), equip_records);
    try std.testing.expectEqual(@as(u8, 5), fire_records);
    try std.testing.expectEqual(@as(u8, 1), reload_records);
}

test "authoritative melee skips driving player targets" {
    const authority = try initTestEmbeddedAuthority(
        testEmbeddedCoreConfig(0x454d_4420, .automatic),
        .{},
        0x81,
    );
    defer authority.deinit();
    const session = authority.session();
    const core = embeddedAuthorityCore(authority);
    const attacker_transport = TransportConnection{ .value = 781 };
    const target_transport = TransportConnection{ .value = 782 };
    _ = try session.openConnection(attacker_transport);
    try session.ingest(attacker_transport, .{ .hello = .{
        .account = .{ .value = 781 },
    } });
    _ = try session.openConnection(target_transport);
    try session.ingest(target_transport, .{ .hello = .{
        .account = .{ .value = 782 },
    } });
    try session.tick();
    var attacker_welcome: ?protocol.Welcome = null;
    var target_welcome: ?protocol.Welcome = null;
    while (takeOutboundForTest(session)) |outbound| switch (outbound.message) {
        .welcome => |welcome| if (outbound.connection.value == attacker_transport.value) {
            attacker_welcome = welcome;
        } else if (outbound.connection.value == target_transport.value) {
            target_welcome = welcome;
        },
        else => {},
    };
    const attacker = attacker_welcome orelse return error.MissingAttackerWelcome;
    const target = target_welcome orelse return error.MissingTargetWelcome;
    const attacker_index = @as(usize, attacker.participant.index) - 1;
    const target_index = @as(usize, target.participant.index) - 1;
    var avatars_alive = false;
    for (0..16) |_| {
        if (core.participants[attacker_index].lifecycle == .alive and
            core.participants[target_index].lifecycle == .alive)
        {
            avatars_alive = true;
            break;
        }
        try session.tick();
        while (takeOutboundForTest(session) != null) {}
    }
    try std.testing.expect(avatars_alive);

    try session.ingest(attacker_transport, .{ .input = .{
        .session = attacker.session,
        .participant = attacker.participant,
        .sequence = .{ .value = 1 },
        .target_tick = core.simulation.tickIndex() +| 1,
        .move = .{ 0, 0 },
        .facing_yaw = std.math.pi / 2.0,
        .jump_pressed = false,
    } });
    try session.tick();
    while (takeOutboundForTest(session) != null) {}
    const on_foot_target = try core.selectMeleeTarget(attacker_index) orelse
        return error.MissingOnFootMeleeTarget;
    try std.testing.expectEqual(vitals_contract.TargetKind.player, on_foot_target.kind);
    try std.testing.expectEqual(
        core.participants[target_index].character.?,
        on_foot_target.persistent,
    );

    core.participants[target_index].driving_vehicle_index = 0;
    try std.testing.expect((try core.selectMeleeTarget(attacker_index)) == null);
    core.participants[target_index].driving_vehicle_index = null;
}

test "npc interest retains nearby and engaged actors across district boundaries" {
    const west = sandbox_district_recipe.navigation_west_coord;
    const east = sandbox_district_recipe.navigation_east_coord;
    var state = NpcInterestState{};

    try std.testing.expect(evaluateNpcInterest(
        .bounded,
        &state,
        10,
        .{ 0, 0, 0 },
        west,
        .{ 100, 0, 0 },
        west,
        false,
    ));
    try std.testing.expectEqual(NpcInterestReason.same_district, state.reason);

    state = .{};
    try std.testing.expect(evaluateNpcInterest(
        .bounded,
        &state,
        20,
        .{ 0, 0, 0 },
        west,
        .{ 19, 0, 0 },
        east,
        false,
    ));
    try std.testing.expectEqual(NpcInterestReason.proximity_enter, state.reason);
    try std.testing.expectEqual(@as(u64, 50), state.grace_until_tick);

    try std.testing.expect(evaluateNpcInterest(
        .bounded,
        &state,
        21,
        .{ 0, 0, 0 },
        west,
        .{ 23, 0, 0 },
        east,
        false,
    ));
    try std.testing.expectEqual(NpcInterestReason.proximity_retained, state.reason);
    try std.testing.expectEqual(@as(u64, 51), state.grace_until_tick);

    try std.testing.expect(evaluateNpcInterest(
        .bounded,
        &state,
        51,
        .{ 0, 0, 0 },
        west,
        .{ 25, 0, 0 },
        east,
        false,
    ));
    try std.testing.expectEqual(NpcInterestReason.grace, state.reason);
    try std.testing.expect(!evaluateNpcInterest(
        .bounded,
        &state,
        52,
        .{ 0, 0, 0 },
        west,
        .{ 25, 0, 0 },
        east,
        false,
    ));
    try std.testing.expectEqual(NpcInterestReason.excluded, state.reason);

    try std.testing.expect(evaluateNpcInterest(
        .bounded,
        &state,
        60,
        .{ 0, 0, 0 },
        west,
        .{ 200, 0, 0 },
        east,
        true,
    ));
    try std.testing.expectEqual(NpcInterestReason.encounter, state.reason);
    try std.testing.expect(evaluateNpcInterest(
        .bounded,
        &state,
        61,
        .{ 0, 0, 0 },
        west,
        .{ 200, 0, 0 },
        east,
        false,
    ));
    try std.testing.expectEqual(NpcInterestReason.grace, state.reason);

    state = .{};
    try std.testing.expect(evaluateNpcInterest(
        .full_world,
        &state,
        70,
        .{ 0, 0, 0 },
        west,
        .{ 10_000, 0, 10_000 },
        east,
        false,
    ));
    try std.testing.expectEqual(NpcInterestReason.full_world, state.reason);
    try std.testing.expectEqual(@as(u64, 0), state.grace_until_tick);
    try std.testing.expectEqual(@as(f32, 200_000_000), state.distance_squared_xz);
}

test "full-world NPC policy projects the sandbox cohort across district seams" {
    const authority = try initTestDedicatedAuthority(true);
    defer authority.deinit();
    const transport = TransportConnection{ .value = 0x4e50_4301 };
    _ = try authority.openConnection(transport);
    try authority.ingest(transport, .{ .hello = .{
        .account = .{ .value = 0x4e50_4301 },
    } });
    const welcome = takeOutboundForTest(authority).?.message.welcome;
    const core = authority.state();
    const participant_index = @as(usize, welcome.participant.index) - 1;

    var npcs_ready = false;
    // Authored population bootstrap crosses the asynchronous content worker.
    // Match the established automatic-fixture settle window above and yield
    // between ticks so a cold, highly parallel build does not starve the
    // worker while this test spins the authority.
    for (0..256) |_| {
        try authority.tick();
        while (takeOutboundForTest(authority) != null) {}
        for (core.npcs[0..budgets.product_npcs]) |npc| {
            if (npc.active) {
                npcs_ready = true;
                break;
            }
        }
        if (npcs_ready and core.participants[participant_index].character != null) break;
        std.Thread.yield() catch {};
    }
    try std.testing.expect(npcs_ready);

    core.participants[participant_index].relevance_coord =
        sandbox_district_recipe.navigation_east_coord;
    core.replication[participant_index].npc_interest = @splat(.{});
    const draws = try core.simulation.npcPresentation(0);
    var west_npc: ?usize = null;
    for (draws) |draw| {
        if (!std.meta.eql(draw.owner, sandbox_district_recipe.navigation_west_coord)) continue;
        const index = core.findNpcByPersistent(draw.persistent_id) orelse continue;
        west_npc = index;
        break;
    }
    const npc_index = west_npc orelse return error.MissingCrossDistrictNpc;
    const snapshot = try core.buildRelevantSnapshot(participant_index);
    var found = false;
    for (snapshot.npcs[0..snapshot.npc_count]) |npc| {
        if (std.meta.eql(npc.entity, core.npcs[npc_index].replicated)) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
    const interest = core.replication[participant_index].npc_interest[npc_index];
    try std.testing.expect(interest.included);
    try std.testing.expectEqual(NpcInterestReason.full_world, interest.reason);
    try std.testing.expect(!std.meta.eql(
        interest.observer_district,
        interest.owner_district,
    ));

    const live_character = core.participants[participant_index].character orelse
        return error.MissingObserverCharacter;
    const live_view = try core.simulation.character(live_character);
    core.participants[participant_index].death_proxy = .{
        .owner = try district_contract.chunkCoordForWorldPosition(live_view.position),
        .state = .{
            .entity = core.participants[participant_index].replicated,
            .owner = welcome.participant,
            .position = live_view.position,
            .velocity = .{ 0, 0, 0 },
            .facing_yaw = live_view.facing_yaw,
            .incarnation = core.participants[participant_index].avatar_incarnation,
            .health = 0,
            .maximum_health = vitals_contract.default_max_health,
            .life_state = .dead,
        },
    };
    core.participants[participant_index].character = null;
    core.replication[participant_index].npc_interest = @splat(.{});
    const dead_observer = try core.buildRelevantSnapshot(participant_index);
    try std.testing.expectEqual(snapshot.npc_count, dead_observer.npc_count);
    var projected_active: u8 = 0;
    for (core.npcs, 0..) |npc, index| {
        if (!npc.active) continue;
        projected_active += 1;
        const dead_interest = core.replication[participant_index].npc_interest[index];
        try std.testing.expect(dead_interest.included);
        try std.testing.expectEqual(NpcInterestReason.full_world, dead_interest.reason);
        try std.testing.expectEqual(live_view.position, dead_interest.observer_position);
    }
    try std.testing.expectEqual(dead_observer.npc_count, projected_active);
}

test "occupied character follows chassis while bounded vehicle stays projected across districts" {
    const fixture = try initCombatVehicleFixture(
        0x454d_4421,
        .{ 0, 0.70710677, 0, 0.70710677 },
    );
    defer fixture.deinit();
    const session = fixture.authority.session();
    const core = embeddedAuthorityCore(fixture.authority);
    const driver_index = @as(usize, fixture.attacker.participant.index) - 1;
    const observer_index = @as(usize, fixture.target.participant.index) - 1;
    try session.ingest(fixture.attacker_transport, .{ .vehicle_action = .{
        .session = fixture.attacker.session,
        .participant = fixture.attacker.participant,
        .sequence = .{ .value = 1 },
        .vehicle = fixture.vehicle,
        .kind = .enter,
    } });
    try session.tick();
    var entered = false;
    while (takeOutboundForTest(session)) |outbound| switch (outbound.message) {
        .vehicle_action_result => |result| entered = result.disposition == .entered,
        else => {},
    };
    try std.testing.expect(entered);

    var crossed = false;
    for (0..720) |offset| {
        try session.ingest(fixture.attacker_transport, .{ .vehicle_input = .{
            .session = fixture.attacker.session,
            .participant = fixture.attacker.participant,
            .sequence = .{ .value = @intCast(offset + 2) },
            .target_tick = core.simulation.tickIndex() +| 1,
            .vehicle = fixture.vehicle,
            .throttle = 1,
            .steering = 0,
            .brake = 0,
            .hand_brake = 0,
        } });
        try session.tick();
        while (takeOutboundForTest(session) != null) {}
        const chassis = (try core.simulation.vehicle(core.vehicles[0].persistent.?))
            .state.chassis.pose.position;
        if (@abs(chassis[0]) > district_contract.chunk_half_span + 1) {
            crossed = true;
            break;
        }
    }
    try std.testing.expect(crossed);
    const character_position = (try core.simulation.character(
        core.participants[driver_index].character.?,
    )).position;
    const chassis_position = (try core.participantAvatarWorldPosition(driver_index)).?;
    try std.testing.expectEqualDeep(
        sandbox_district_recipe.navigation_west_coord,
        try district_contract.chunkCoordForWorldPosition(character_position),
    );
    const chassis_coord = try district_contract.chunkCoordForWorldPosition(chassis_position);
    try std.testing.expect(!std.meta.eql(
        sandbox_district_recipe.navigation_west_coord,
        chassis_coord,
    ));

    core.participants[observer_index].relevance_coord =
        sandbox_district_recipe.navigation_west_coord;
    const west = try core.buildRelevantSnapshot(observer_index);
    var west_has_driver = false;
    for (west.characters[0..west.character_count]) |character| {
        west_has_driver = west_has_driver or
            std.meta.eql(character.owner, fixture.attacker.participant);
    }
    var west_has_vehicle = false;
    for (west.vehicles[0..west.vehicle_count]) |vehicle| {
        west_has_vehicle = west_has_vehicle or std.meta.eql(vehicle.entity, fixture.vehicle);
    }
    try std.testing.expect(!west_has_driver);
    try std.testing.expect(west_has_vehicle);
    const west_vehicle_interest = core.replication[observer_index].vehicle_interest[0];
    try std.testing.expect(west_vehicle_interest.included);
    try std.testing.expectEqual(
        ObjectInterestReason.bounded_world,
        west_vehicle_interest.reason,
    );
    try std.testing.expect(!std.meta.eql(
        west_vehicle_interest.observer_district,
        west_vehicle_interest.owner_district,
    ));

    core.participants[observer_index].relevance_coord = chassis_coord;
    const remote = try core.buildRelevantSnapshot(observer_index);
    var remote_has_driver = false;
    for (remote.characters[0..remote.character_count]) |character| {
        remote_has_driver = remote_has_driver or
            std.meta.eql(character.owner, fixture.attacker.participant);
    }
    var remote_has_occupied_vehicle = false;
    for (remote.vehicles[0..remote.vehicle_count]) |vehicle| {
        remote_has_occupied_vehicle = remote_has_occupied_vehicle or
            (std.meta.eql(vehicle.entity, fixture.vehicle) and vehicle.driver != null and
                std.meta.eql(vehicle.driver.?, fixture.attacker.participant));
    }
    try std.testing.expect(remote_has_driver);
    try std.testing.expect(remote_has_occupied_vehicle);

    const local = try core.buildRelevantSnapshot(driver_index);
    var local_has_driver = false;
    for (local.characters[0..local.character_count]) |character| {
        local_has_driver = local_has_driver or
            std.meta.eql(character.owner, fixture.attacker.participant);
    }
    var local_has_occupied_vehicle = false;
    for (local.vehicles[0..local.vehicle_count]) |vehicle| {
        local_has_occupied_vehicle = local_has_occupied_vehicle or
            (std.meta.eql(vehicle.entity, fixture.vehicle) and vehicle.driver != null and
                std.meta.eql(vehicle.driver.?, fixture.attacker.participant));
    }
    try std.testing.expect(local_has_driver);
    try std.testing.expect(local_has_occupied_vehicle);
}

test "same-cycle vehicle enter and melee permutations remain exclusive" {
    const Case = enum {
        attacker_enter_first,
        attacker_melee_first,
        target_enter_first,
        attacker_melee_target_enter,
    };
    const cases = [_]Case{
        .attacker_enter_first,
        .attacker_melee_first,
        .target_enter_first,
        .attacker_melee_target_enter,
    };
    for (cases, 0..) |case, case_index| {
        const fixture = try initCombatVehicleFixture(
            0x454d_4430 + case_index,
            .{ 0, 0, 0, 1 },
        );
        defer fixture.deinit();
        const session = fixture.authority.session();
        const core = embeddedAuthorityCore(fixture.authority);
        const attacker_index = @as(usize, fixture.attacker.participant.index) - 1;
        const target_index = @as(usize, fixture.target.participant.index) - 1;
        const target_enters = case == .target_enter_first or
            case == .attacker_melee_target_enter;
        const vehicle_actor = if (target_enters)
            fixture.target
        else
            fixture.attacker;
        const vehicle_transport = if (target_enters)
            fixture.target_transport
        else
            fixture.attacker_transport;
        const vehicle_action = protocol.ClientMessage{ .vehicle_action = .{
            .session = vehicle_actor.session,
            .participant = vehicle_actor.participant,
            .sequence = .{ .value = 1 },
            .vehicle = fixture.vehicle,
            .kind = .enter,
        } };
        const melee_action = protocol.ClientMessage{ .melee_action = .{
            .session = fixture.attacker.session,
            .participant = fixture.attacker.participant,
            .sequence = .{ .value = 1 },
            .avatar_incarnation = core.participants[attacker_index].avatar_incarnation,
            .target_tick = core.simulation.tickIndex() +| 1,
        } };
        if (case == .attacker_melee_first or
            case == .attacker_melee_target_enter)
        {
            try session.ingest(fixture.attacker_transport, melee_action);
            try session.ingest(vehicle_transport, vehicle_action);
        } else {
            try session.ingest(vehicle_transport, vehicle_action);
            try session.ingest(fixture.attacker_transport, melee_action);
        }
        try session.tick();
        var vehicle_result: ?protocol.VehicleActionResult = null;
        var melee_result: ?protocol.MeleeActionResult = null;
        while (takeOutboundForTest(session)) |outbound| switch (outbound.message) {
            .vehicle_action_result => |result| vehicle_result = result,
            .melee_action_result => |result| melee_result = result,
            else => {},
        };
        const applied_vehicle = vehicle_result orelse return error.MissingVehiclePermutationResult;
        const applied_melee = melee_result orelse return error.MissingMeleePermutationResult;
        const target_vitals = core.simulation.currentVitals(
            .player,
            core.participants[target_index].character.?,
        ) orelse return error.MissingPermutationTargetVitals;
        switch (case) {
            .attacker_enter_first => {
                try std.testing.expectEqual(
                    protocol.VehicleActionDisposition.entered,
                    applied_vehicle.disposition,
                );
                try std.testing.expectEqual(
                    protocol.MeleeActionDisposition.invalid_state,
                    applied_melee.disposition,
                );
                try std.testing.expectEqual(@as(u16, 100), target_vitals.current_health);
                try std.testing.expectEqual(
                    @as(u64, 0),
                    core.participants[attacker_index].melee_cooldown_until_tick,
                );
                try std.testing.expect(core.participants[attacker_index].driving_vehicle_index != null);
            },
            .attacker_melee_first => {
                try std.testing.expectEqual(
                    protocol.VehicleActionDisposition.invalid_state,
                    applied_vehicle.disposition,
                );
                try std.testing.expectEqual(
                    protocol.MeleeActionDisposition.hit,
                    applied_melee.disposition,
                );
                try std.testing.expectEqual(@as(u16, 100 - melee_damage), target_vitals.current_health);
                try std.testing.expect(core.participants[attacker_index].melee_cooldown_until_tick > 0);
                try std.testing.expect(core.participants[attacker_index].driving_vehicle_index == null);
            },
            .target_enter_first => {
                try std.testing.expectEqual(
                    protocol.VehicleActionDisposition.entered,
                    applied_vehicle.disposition,
                );
                try std.testing.expectEqual(
                    protocol.MeleeActionDisposition.miss,
                    applied_melee.disposition,
                );
                try std.testing.expectEqual(@as(u16, 100), target_vitals.current_health);
                try std.testing.expect(core.participants[target_index].driving_vehicle_index != null);
            },
            .attacker_melee_target_enter => {
                try std.testing.expectEqual(
                    protocol.VehicleActionDisposition.invalid_state,
                    applied_vehicle.disposition,
                );
                try std.testing.expectEqual(
                    protocol.MeleeActionDisposition.hit,
                    applied_melee.disposition,
                );
                try std.testing.expectEqual(@as(u16, 100 - melee_damage), target_vitals.current_health);
                try std.testing.expect(core.participants[attacker_index].melee_cooldown_until_tick > 0);
                try std.testing.expect(core.participants[target_index].driving_vehicle_index == null);
            },
        }
    }
}

test "authoritative melee kills once and explicit respawn replaces avatar incarnation" {
    const authority = try initTestDedicatedAuthority(false);
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
    const retained_death = authority.state().participants[victim_index].death_proxy orelse
        return error.MissingPlayerDeathPresentation;
    try std.testing.expectEqual(protocol.AvatarLifeState.dead, retained_death.state.life_state);
    try std.testing.expectEqual(@as(u16, 0), retained_death.state.health);
    try std.testing.expectEqual(first_incarnation, retained_death.state.incarnation);
    const dead_snapshot = try authority.state().buildRelevantSnapshot(victim_index);
    var projected_dead = false;
    for (dead_snapshot.characters[0..dead_snapshot.character_count]) |character| {
        if (!std.meta.eql(character.owner, victim.participant)) continue;
        try std.testing.expectEqual(protocol.AvatarLifeState.dead, character.life_state);
        try std.testing.expectEqual(@as(u16, 0), character.health);
        try std.testing.expectEqual(first_incarnation, character.incarnation);
        projected_dead = true;
    }
    try std.testing.expect(projected_dead);
    const observer_snapshot = try authority.state().buildRelevantSnapshot(attacker_index);
    var observer_projected_dead = false;
    for (observer_snapshot.characters[0..observer_snapshot.character_count]) |character| {
        if (!std.meta.eql(character.owner, victim.participant)) continue;
        try std.testing.expectEqual(protocol.AvatarLifeState.dead, character.life_state);
        try std.testing.expectEqual(@as(u16, 0), character.health);
        try std.testing.expectEqual(first_incarnation, character.incarnation);
        observer_projected_dead = true;
    }
    try std.testing.expect(observer_projected_dead);

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
    var dead_welcome_delivery_id: u64 = 0;
    while (takeOutboundForTest(authority)) |outbound| switch (outbound.message) {
        .welcome => |welcome| if (outbound.connection.value == reconnected_transport.value) {
            dead_welcome = welcome;
            dead_welcome_delivery_id = outbound.delivery_id;
        },
        else => {},
    };
    const reconnected = dead_welcome orelse return error.MissingDeadReconnectWelcome;
    try authority.ingest(reconnected_transport, .{ .delivery_receipt = .{
        .session = reconnected.session,
        .participant = reconnected.participant,
        .lane = .control,
        .delivery_id = dead_welcome_delivery_id,
    } });
    try authority.tick();
    while (takeOutboundForTest(authority) != null) {}
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
    try std.testing.expect(authority.state().participants[victim_index].death_proxy == null);
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

test "NPC death vacates and replaces the exact authored member" {
    const authority = try initTestDedicatedAuthority(true);
    defer authority.deinit();

    var bootstrapped = false;
    for (0..10_000) |_| {
        try authority.tick();
        while (takeOutboundForTest(authority) != null) {}
        if (authority.state().npcs[0].active and authority.state().npcs[1].active and
            !authority.state().npcs[0].vitals_pending and
            !authority.state().npcs[1].vitals_pending)
        {
            bootstrapped = true;
            break;
        }
        std.Thread.yield() catch {};
    }
    try std.testing.expect(bootstrapped);

    const victim_before = authority.state().npcs[0];
    const source = authority.state().npcs[1];
    const victim_id = victim_before.persistent orelse return error.MissingNpcVictim;
    const source_id = source.persistent orelse return error.MissingNpcSource;
    const application_tick = authority.state().simulation.tickIndex() +| 1;
    for (0..3) |index| {
        try authority.state().simulation.submitVitals(.{ .damage = .{
            .source = .{
                .kind = .npc,
                .id = source_id,
                .incarnation = .{ .value = source.generation },
                .action_sequence = @intCast(index + 1),
            },
            .target = .{
                .kind = .npc,
                .id = victim_id,
                .incarnation = .{ .value = victim_before.generation },
            },
            .cause = .npc_melee,
            .authority_tick = application_tick,
            .correlation = 0x5331_31f0_0000_0000 + index,
            .base_amount = 34,
            .ordinal = @intCast(index),
        } });
    }
    try authority.tick();
    while (takeOutboundForTest(authority) != null) {}
    try std.testing.expect(authority.state().npcs[0].despawn_pending);
    const death_proxy = authority.state().npcs[0].death_proxy orelse
        return error.MissingNpcDeathPresentation;
    try std.testing.expectEqual(protocol.AvatarLifeState.dead, death_proxy.state.life_state);
    try std.testing.expectEqual(@as(u16, 0), death_proxy.state.health);
    const vacant_member = authority.state().simulation.populationMember(.{
        .value = 1,
    }) orelse return error.PopulationMemberMissingAfterDeath;
    try std.testing.expectEqual(
        population_contract.MemberLifecycle.vacant,
        vacant_member.lifecycle,
    );
    try std.testing.expectEqual(
        nextGeneration(victim_before.generation),
        vacant_member.actor_generation,
    );

    var replaced = false;
    var observed_spawn_vitals_handoff = false;
    var observed_proxy_after_despawn = false;
    var observed_proxy_until_replacement = false;
    for (0..500) |_| {
        try authority.tick();
        while (takeOutboundForTest(authority) != null) {}
        const current = authority.state().npcs[0];
        if (current.active and current.vitals_pending and current.persistent != null and
            !std.meta.eql(current.persistent.?, victim_id))
        {
            try std.testing.expect(current.population_replacement_spawn_pending);
            try std.testing.expect(current.death_proxy != null);
            observed_proxy_until_replacement = true;
            observed_spawn_vitals_handoff = true;
        }
        if (!current.active and current.death_proxy != null) {
            observed_proxy_after_despawn = true;
        }
        if (current.active and !current.vitals_pending and current.persistent != null and
            !std.meta.eql(current.persistent.?, victim_id))
        {
            try std.testing.expectEqual(
                nextGeneration(victim_before.generation),
                current.generation,
            );
            try std.testing.expect(current.death_proxy == null);
            replaced = true;
            break;
        }
    }
    try std.testing.expect(replaced);
    try std.testing.expect(observed_spawn_vitals_handoff);
    try std.testing.expect(observed_proxy_after_despawn);
    try std.testing.expect(observed_proxy_until_replacement);
    const rebound = authority.state().simulation.populationMember(.{
        .value = 1,
    }) orelse return error.PopulationMemberMissingAfterReplacement;
    try std.testing.expectEqual(population_contract.MemberLifecycle.live, rebound.lifecycle);
    try std.testing.expect(rebound.actor != null);
    try std.testing.expect(std.meta.eql(
        authority.state().npcs[0].persistent.?,
        rebound.actor.?,
    ));
}

test "authority defers admitted input until its declared target tick" {
    const authority = try initTestDedicatedAuthority(false);
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
    const authority = try initTestDedicatedAuthority(false);
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
    const authority = try initTestDedicatedAuthority(false);
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
    core.publication_preparing = false;
    try session.tick();

    const accepted = session.beginOutboundLease() orelse return error.MissingGameplayResult;
    const gameplay_delivery_id = accepted.outbound.delivery_id;
    try std.testing.expect(gameplay_delivery_id != 0);
    try session.commitOutboundLease(accepted.generation);
    while (session.beginOutboundLease()) |remaining| {
        try session.commitOutboundLease(remaining.generation);
    }

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

test "seventeen logical gameplay results drain in order across the wire budget" {
    const authority = try initTestEmbeddedAuthority(
        testEmbeddedCoreConfig(0x454d_4419, .host_managed),
        .{},
        0x19,
    );
    defer authority.deinit();
    const session = authority.session();
    const transport = TransportConnection{ .value = 1 };
    _ = try session.openConnection(transport);
    try session.ingest(transport, .{ .hello = .{ .account = .{ .value = 19 } } });
    try session.tick();
    const welcome_lease = session.beginOutboundLease() orelse return error.MissingInitialWelcome;
    const welcome = welcome_lease.outbound.message.welcome;
    try session.commitOutboundLease(welcome_lease.generation);
    while (session.beginOutboundLease()) |remaining| {
        try session.commitOutboundLease(remaining.generation);
    }

    const core = embeddedAuthorityCore(authority);
    const participant_index = @as(usize, welcome.participant.index) - 1;
    const burst_count = @as(usize, budgets.max_reliable_events_per_tick) + 1;
    var burst: [burst_count]ReplayMessage = undefined;
    for (&burst, 0..) |*message, index| {
        message.* = .{ .vehicle_action_result = .{
            .sequence = .{ .value = @intCast(index + 1) },
            .vehicle = .{ .index = 17, .generation = 1 },
            .action = .enter,
            .disposition = .entered,
        } };
    }
    core.publication_preparing = true;
    try core.queueGameplayResults(participant_index, &burst);
    core.publication_preparing = false;

    try std.testing.expectEqual(@as(usize, 0), core.prepared_outbox.len);
    try std.testing.expectEqual(
        @as(u64, burst_count + 1),
        core.participants[participant_index].next_gameplay_delivery_id,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        core.participants[participant_index].replay_cursor_delivery_id,
    );
    var retained: usize = 0;
    for (core.participants[participant_index].replay_records) |record| {
        retained += @intFromBool(record.active);
    }
    try std.testing.expectEqual(burst_count, retained);

    try session.tick();
    var expected_delivery_id: u64 = 1;
    var first_drain_count: usize = 0;
    while (session.beginOutboundLease()) |lease| {
        if (lease.outbound.lane == .gameplay) {
            try std.testing.expectEqual(expected_delivery_id, lease.outbound.delivery_id);
            expected_delivery_id += 1;
            first_drain_count += 1;
        }
        try session.commitOutboundLease(lease.generation);
    }
    try std.testing.expectEqual(
        @as(usize, budgets.max_reliable_events_per_tick - 1),
        first_drain_count,
    );
    try std.testing.expectEqual(
        expected_delivery_id,
        core.participants[participant_index].replay_cursor_delivery_id,
    );

    // Appending while a send/replay cursor is active extends the same ordered
    // tail; it must never reset the cursor to the new delivery ID.
    core.publication_preparing = true;
    try core.queueGameplayResult(participant_index, .{ .vehicle_action_result = .{
        .sequence = .{ .value = @intCast(burst_count + 1) },
        .vehicle = .{ .index = 17, .generation = 1 },
        .action = .enter,
        .disposition = .entered,
    } });
    core.publication_preparing = false;
    try std.testing.expectEqual(
        expected_delivery_id,
        core.participants[participant_index].replay_cursor_delivery_id,
    );
    try session.ingest(transport, .{ .delivery_receipt = .{
        .session = welcome.session,
        .participant = welcome.participant,
        .lane = .gameplay,
        .delivery_id = expected_delivery_id - 1,
    } });
    try session.tick();
    var second_drain_count: usize = 0;
    while (session.beginOutboundLease()) |lease| {
        if (lease.outbound.lane == .gameplay) {
            try std.testing.expectEqual(expected_delivery_id, lease.outbound.delivery_id);
            expected_delivery_id += 1;
            second_drain_count += 1;
        }
        try session.commitOutboundLease(lease.generation);
    }
    try std.testing.expectEqual(@as(usize, 3), second_drain_count);
    try std.testing.expectEqual(@as(u64, burst_count + 2), expected_delivery_id);
    try std.testing.expectEqual(
        @as(u64, 0),
        core.participants[participant_index].replay_cursor_delivery_id,
    );
    try std.testing.expect(
        core.max_reliable_events_per_connection_tick <= budgets.max_reliable_events_per_tick,
    );
}

test "gameplay overflow retires only slow consumers and keeps the room healthy" {
    const authority = try initTestEmbeddedAuthority(
        testEmbeddedCoreConfig(0x454d_4420, .host_managed),
        .{},
        0x20,
    );
    defer authority.deinit();
    const session = authority.session();
    const healthy_transport = TransportConnection{ .value = 1 };
    const slow_transport = TransportConnection{ .value = 2 };
    const grace_transport = TransportConnection{ .value = 3 };
    for ([_]TransportConnection{ healthy_transport, slow_transport, grace_transport }, 0..) |
        transport,
        index,
    | {
        _ = try session.openConnection(transport);
        try session.ingest(transport, .{ .hello = .{
            .account = .{ .value = index + 20 },
        } });
    }
    try session.tick();
    var healthy_welcome: ?protocol.Welcome = null;
    var slow_welcome: ?protocol.Welcome = null;
    var grace_welcome: ?protocol.Welcome = null;
    while (session.beginOutboundLease()) |lease| {
        if (lease.outbound.message == .welcome) switch (lease.outbound.connection.value) {
            1 => healthy_welcome = lease.outbound.message.welcome,
            2 => slow_welcome = lease.outbound.message.welcome,
            3 => grace_welcome = lease.outbound.message.welcome,
            else => {},
        };
        try session.commitOutboundLease(lease.generation);
    }
    const healthy = healthy_welcome orelse return error.MissingHealthyWelcome;
    const slow = slow_welcome orelse return error.MissingSlowWelcome;
    const grace = grace_welcome orelse return error.MissingGraceWelcome;

    _ = try session.transportClosed(grace_transport);
    try session.tick();
    while (session.beginOutboundLease()) |lease| {
        try session.commitOutboundLease(lease.generation);
    }

    const core = embeddedAuthorityCore(authority);
    const healthy_index = @as(usize, healthy.participant.index) - 1;
    const slow_index = @as(usize, slow.participant.index) - 1;
    const grace_index = @as(usize, grace.participant.index) - 1;
    try std.testing.expect(core.participants[grace_index].connection_index == null);

    const life = protocol.LifeEvent{
        .avatar = .{ .index = 1, .generation = 1 },
        .incarnation = 1,
        .authority_tick = 1,
        .health = vitals_contract.default_max_health,
        .maximum_health = vitals_contract.default_max_health,
        .state = .alive,
    };
    for ([_]usize{ slow_index, grace_index }) |participant_index| {
        const participant = &core.participants[participant_index];
        for (&participant.replay_records, 0..) |*record, index| {
            record.* = .{
                .active = true,
                .delivery_id = index + 1,
                .message = .{ .life_event = life },
            };
        }
        participant.next_gameplay_delivery_id = participant.replay_records.len + 1;
    }

    // A participant-local burst with only one free slot retires that consumer
    // before assigning either delivery ID.
    const local_overflow_index = for (core.participants, 0..) |participant, index| {
        if (!participant.active) break index;
    } else unreachable;
    core.participants[local_overflow_index] = .{
        .active = true,
        .generation = 1,
    };
    const local_overflow = &core.participants[local_overflow_index];
    for (&local_overflow.replay_records, 0..) |*record, index| {
        record.* = .{
            .active = index + 1 != local_overflow.replay_records.len,
            .delivery_id = index + 1,
            .message = .{ .life_event = life },
        };
    }
    local_overflow.next_gameplay_delivery_id = local_overflow.replay_records.len;
    const overflow = [_]ReplayMessage{
        .{ .vehicle_action_result = .{
            .sequence = .{ .value = 1 },
            .vehicle = .{ .index = 17, .generation = 1 },
            .action = .enter,
            .disposition = .entered,
        } },
        .{ .vehicle_action_result = .{
            .sequence = .{ .value = 2 },
            .vehicle = .{ .index = 17, .generation = 1 },
            .action = .enter,
            .disposition = .entered,
        } },
    };
    core.publication_preparing = true;
    try core.queueGameplayResults(local_overflow_index, &overflow);
    try core.publishLifeEvent(life);
    core.publishPrepared();
    core.publication_preparing = false;

    try std.testing.expect(!core.participants[slow_index].active);
    try std.testing.expect(!core.participants[grace_index].active);
    try std.testing.expect(!core.participants[local_overflow_index].active);
    try std.testing.expect(core.findConnection(slow_transport) == null);
    try std.testing.expectEqual(@as(u64, 3), core.slow_gameplay_consumers_retired);
    for ([_]usize{ slow_index, grace_index, local_overflow_index }) |participant_index| {
        for (core.participants[participant_index].replay_records) |record| {
            try std.testing.expect(!record.active);
        }
    }

    var slow_disconnects: usize = 0;
    while (session.beginOutboundLease()) |lease| {
        if (lease.outbound.connection.value == slow_transport.value and
            lease.outbound.message == .disconnected)
        {
            try std.testing.expectEqual(
                protocol.DisconnectReason.protocol_failure,
                lease.outbound.message.disconnected,
            );
            slow_disconnects += 1;
        }
        try session.commitOutboundLease(lease.generation);
    }
    try std.testing.expectEqual(@as(usize, 1), slow_disconnects);

    try session.tick();
    var healthy_life_events: usize = 0;
    while (session.beginOutboundLease()) |lease| {
        if (lease.outbound.connection.value == healthy_transport.value and
            lease.outbound.message == .life_event)
        {
            try std.testing.expectEqualDeep(life, lease.outbound.message.life_event);
            healthy_life_events += 1;
        }
        try session.commitOutboundLease(lease.generation);
    }
    try std.testing.expectEqual(@as(usize, 1), healthy_life_events);
    try std.testing.expect(core.participants[healthy_index].active);
    try std.testing.expect(core.diagnostics().first_cycle_fault == null);
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
            .transmitted = true,
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
    const authority = try initTestDedicatedAuthority(false);
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
    try std.testing.expect(horizontalDistanceSquared(
        initial.vehicles[0].position,
        last_snapshot.vehicles[0].position,
    ) > 1);
    const core = authority.state();
    const participant_index = @as(usize, welcome.participant.index) - 1;
    const character_position = (try core.simulation.character(
        core.participants[participant_index].character.?,
    )).position;
    const vehicle_index = core.participants[participant_index].driving_vehicle_index orelse
        return error.MissingDrivingVehicleAuthority;
    const chassis_position = (try core.simulation.vehicle(
        core.vehicles[vehicle_index].persistent orelse return error.MissingVehicleAuthority,
    )).state.chassis.pose.position;
    try std.testing.expectEqual(
        chassis_position,
        (try core.participantAvatarWorldPosition(participant_index)).?,
    );
    try std.testing.expect(horizontalDistanceSquared(character_position, chassis_position) > 1);
    try std.testing.expect((try core.spawnCandidateScore(
        if (participant_index == 0) 1 else 0,
        chassis_position,
    )) == null);
    var projected_wheel_motion = false;
    for (last_snapshot.vehicles[0].wheels, initial.vehicles[0].wheels) |
        current_wheel,
        initial_wheel,
    | {
        projected_wheel_motion = projected_wheel_motion or
            @abs(current_wheel.angular_velocity) > 0.01 or
            @abs(current_wheel.spin_phase - initial_wheel.spin_phase) > 0.01;
    }
    try std.testing.expect(projected_wheel_motion);

    try authority.ingest(transport, .{ .melee_action = .{
        .session = welcome.session,
        .participant = welcome.participant,
        .sequence = .{ .value = 1 },
        .avatar_incarnation = core.participants[participant_index].avatar_incarnation,
        .target_tick = core.simulation.tickIndex() +| 1,
    } });
    try authority.tick();
    var driving_melee_result: ?protocol.MeleeActionResult = null;
    while (takeOutboundForTest(authority)) |outbound| switch (outbound.message) {
        .melee_action_result => |result| driving_melee_result = result,
        else => {},
    };
    try std.testing.expectEqual(
        protocol.MeleeActionDisposition.invalid_state,
        (driving_melee_result orelse return error.MissingDrivingMeleeResult).disposition,
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        core.participants[participant_index].melee_cooldown_until_tick,
    );

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
    const authority = try initTestDedicatedAuthority(false);
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
    const authority = try initTestDedicatedAuthority(false);
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
    const authority = try initTestDedicatedAuthority(false);
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
    const authority = try initTestDedicatedAuthority(false);
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

    _ = try authority.openConnection(.{ .value = 4 });
    try authority.ingest(.{ .value = 4 }, .{ .hello = .{
        .content = protocol.content_cohort ^ 1,
        .account = .{ .value = 4 },
    } });
    try std.testing.expectEqual(protocol.RejectionReason.content_mismatch, takeOutboundForTest(authority).?.message.rejected.reason);
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
    const authority = try initTestDedicatedAuthority(false);
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
    var observed_handshake_timeout = false;
    for (0..budgets.handshake_timeout_ticks) |_| {
        try authority.tick();
        while (takeOutboundForTest(authority)) |outbound| switch (outbound.message) {
            .rejected => |rejection| if (rejection.reason == .invalid_state) {
                observed_handshake_timeout = true;
            },
            else => {},
        };
    }
    try std.testing.expect(observed_handshake_timeout);

    authority.state().connections[primary_connection].last_message_tick = 0;
    var observed_timeout = false;
    while (authority.diagnostics().tick <= budgets.idle_timeout_ticks) {
        try authority.tick();
        while (takeOutboundForTest(authority)) |outbound| switch (outbound.message) {
            .disconnected => |reason| if (reason == .timeout) {
                observed_timeout = true;
            },
            else => {},
        };
    }
    try std.testing.expect(observed_timeout);
    try std.testing.expectEqual(@as(u16, 1), authority.diagnostics().reconnecting_participants);
}
