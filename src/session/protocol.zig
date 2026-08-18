//! Small, bounded semantic protocol for the multiplayer foundation. Transport handles, Flecs IDs,
//! Jolt state, durable-save bytes, and platform identities are excluded.

const std = @import("std");
const budgets = @import("session_budgets");
const identity = @import("session_identity");
const cohort = @import("network_cohort_options");

pub const wire_magic: u32 = 0x494e_434e; // "INCN"
pub const wire_version: u16 = cohort.protocol_revision;
pub const build_cohort: u64 = cohort.build_cohort;
pub const content_cohort: u64 = cohort.content_cohort;
pub const max_relevant_districts = budgets.max_relevant_districts_per_client;

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

pub const IdentityProvider = enum(u8) {
    development = 1,
    steam = 2,
};

pub const ExternalIdentity = struct {
    provider: IdentityProvider = .development,
    subject: u64 = 0,
};

pub const JoinAuthorization = struct {
    room_id: u64 = 0,
    authority_id: u64 = 0,
    room_generation: u32 = 0,
    nonce: u64 = 0,
    expires_at_unix_seconds: u64 = 0,
    authenticator: [32]u8 = @splat(0),

    pub fn isPresent(self: JoinAuthorization) bool {
        return self.room_id != 0;
    }

    pub fn none() JoinAuthorization {
        return .{};
    }
};

pub const Hello = struct {
    protocol: u16 = wire_version,
    build: u64 = build_cohort,
    content: u64 = content_cohort,
    account: identity.AccountId,
    external_identity: ExternalIdentity = .{},
    join_authorization: JoinAuthorization = .{},
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

pub const InteractionActionKind = enum(u8) {
    collect = 1,
    drop = 2,
};

pub const InteractionAction = struct {
    session: identity.SessionId,
    participant: identity.ParticipantId,
    sequence: identity.ActionSequence,
    carryable: identity.ReplicatedEntityId,
    kind: InteractionActionKind,
};

pub const MeleeAction = struct {
    session: identity.SessionId,
    participant: identity.ParticipantId,
    sequence: identity.ActionSequence,
    avatar_incarnation: u16,
    target_tick: u64,
};

pub const WeaponActionKind = enum(u8) {
    equip_toggle = 1,
    fire = 2,
    reload = 3,
};

pub const WeaponAction = struct {
    session: identity.SessionId,
    participant: identity.ParticipantId,
    sequence: identity.ActionSequence,
    avatar_incarnation: u16,
    target_tick: u64,
    kind: WeaponActionKind,
};

pub const WeaponMode = enum(u8) {
    holstered = 1,
    equipped = 2,
    reloading = 3,
};

pub const RespawnAction = struct {
    session: identity.SessionId,
    participant: identity.ParticipantId,
    sequence: identity.ActionSequence,
    dead_incarnation: u16,
};

pub const BaselineAck = struct {
    session: identity.SessionId,
    participant: identity.ParticipantId,
    baseline_id: u32,
};

pub const SnapshotAck = struct {
    session: identity.SessionId,
    participant: identity.ParticipantId,
    baseline_id: u32,
    sequence: identity.SnapshotSequence,
};

pub const ReliableLane = enum(u8) {
    gameplay = 2,
    control = 3,
};

pub const DeliveryReceipt = struct {
    session: identity.SessionId,
    participant: identity.ParticipantId,
    lane: ReliableLane,
    delivery_id: u64,
};

pub const ClientMessage = union(enum) {
    hello: Hello,
    input: InputFrame,
    vehicle_input: VehicleInputFrame,
    vehicle_action: VehicleAction,
    interaction_action: InteractionAction,
    melee_action: MeleeAction,
    weapon_action: WeaponAction,
    respawn_action: RespawnAction,
    baseline_ack: BaselineAck,
    snapshot_ack: SnapshotAck,
    delivery_receipt: DeliveryReceipt,
    disconnect: DisconnectReason,
};

pub const Welcome = struct {
    session: identity.SessionId,
    participant: identity.ParticipantId,
    connection: identity.ConnectionId,
    reconnect: identity.ReconnectToken,
    authority_tick: u64,
    avatar: identity.ReplicatedEntityId,
    avatar_incarnation: u16,
    life_state: AvatarLifeState,
    melee_ready_tick: u64 = 0,
    weapon_mode: WeaponMode = .holstered,
    magazine_ammo: u16 = 0,
    reserve_ammo: u16 = 0,
    weapon_ready_tick: u64 = 0,
    reload_complete_tick: u64 = 0,
    respawn_ready_tick: u64 = 0,
};

pub const CharacterState = struct {
    entity: identity.ReplicatedEntityId,
    owner: identity.ParticipantId,
    position: [3]f32,
    velocity: [3]f32,
    facing_yaw: f32,
    incarnation: u16 = 1,
    health: u16 = 100,
    maximum_health: u16 = 100,
    life_state: AvatarLifeState = .alive,
    weapon_mode: WeaponMode = .holstered,
    magazine_ammo: u16 = 0,
    reserve_ammo: u16 = 0,
    weapon_ready_tick: u64 = 0,
    reload_complete_tick: u64 = 0,
};

/// Compact, engine-neutral wheel presentation projected by authority. The
/// client combines these values with cohort-owned vehicle layout data and the
/// presented chassis pose; Jolt transforms and solver caches never cross the
/// session boundary.
pub const vehicle_wheel_count: usize = 4;
pub const max_vehicle_wheel_angular_velocity: f32 = 4_096;
pub const max_vehicle_wheel_steer_angle: f32 = std.math.pi / 2.0;
pub const max_vehicle_wheel_suspension_length: f32 = 4;

pub const VehicleWheelState = struct {
    /// Canonical visual spin phase in [0, 2pi). Angular velocity disambiguates
    /// phase wrapping when a wheel advances more than half a turn between the
    /// 20 Hz vehicle snapshots.
    spin_phase: f32 = 0,
    angular_velocity: f32 = 0,
    /// Engine convention: positive steers toward +X when the chassis faces -Z.
    steer_angle: f32 = 0,
    suspension_length: f32 = 0,
    has_contact: bool = false,

    pub fn validate(self: VehicleWheelState) !void {
        try validateFiniteComponents(&[_]f32{
            self.spin_phase,
            self.angular_velocity,
            self.steer_angle,
            self.suspension_length,
        });
        if (self.spin_phase < 0 or self.spin_phase >= std.math.tau or
            @as(u32, @bitCast(self.spin_phase)) == 0x8000_0000)
        {
            return error.NonCanonicalVehicleWheelPhase;
        }
        if (@abs(self.angular_velocity) > max_vehicle_wheel_angular_velocity) {
            return error.VehicleWheelAngularVelocityOutOfRange;
        }
        if (@abs(self.steer_angle) >= max_vehicle_wheel_steer_angle) {
            return error.VehicleWheelSteerAngleOutOfRange;
        }
        if (self.suspension_length < 0 or
            self.suspension_length > max_vehicle_wheel_suspension_length)
        {
            return error.InvalidVehicleWheelSuspension;
        }
    }
};

pub const VehicleState = struct {
    entity: identity.ReplicatedEntityId,
    position: [3]f32,
    rotation: [4]f32,
    linear_velocity: [3]f32,
    angular_velocity: [3]f32,
    wheels: [vehicle_wheel_count]VehicleWheelState = @splat(.{}),
    driver: ?identity.ParticipantId,
};

pub const CarryableState = struct {
    entity: identity.ReplicatedEntityId,
    position: [3]f32,
    rotation: [4]f32,
    linear_velocity: [3]f32,
    angular_velocity: [3]f32,
    half_extents: [3]f32,
    holder: ?identity.ParticipantId,
};

pub const NpcPresentationState = enum(u8) {
    active = 1,
    waiting_at_boundary = 2,
};

pub const AvatarLifeState = enum(u8) {
    alive = 1,
    dead = 2,
};

pub const NpcEncounterState = enum(u8) {
    patrolling = 1,
    pursuing = 2,
    attack_windup = 3,
    attack_recovery = 4,
    searching = 5,
    returning = 6,
};

pub const NpcPopulationRole = enum(u8) {
    unassigned = 0,
    resident = 1,
    worker = 2,
    visitor = 3,
};

pub const NpcCombatDisposition = enum(u8) {
    unassigned = 0,
    passive = 1,
    hostile_to_players = 2,
};

pub const NpcActivityKind = enum(u8) {
    none = 0,
    commute = 1,
    shop = 2,
    visit = 3,
    idle = 4,
};

pub const NpcActivityState = enum(u8) {
    unassigned = 0,
    selecting = 1,
    waiting_for_slot = 2,
    traveling = 3,
    dwelling = 4,
    completing = 5,
    interrupted = 6,
    vacant = 7,
    replacement_pending = 8,
};

pub const NpcState = struct {
    entity: identity.ReplicatedEntityId,
    position: [3]f32,
    velocity: [3]f32,
    facing_yaw: f32,
    state: NpcPresentationState,
    incarnation: u16 = 1,
    health: u16 = 100,
    maximum_health: u16 = 100,
    life_state: AvatarLifeState = .alive,
    encounter_state: NpcEncounterState = .patrolling,
    encounter_state_enter_tick: u64 = 0,
    attack_impact_tick: u64 = 0,
    attack_ready_tick: u64 = 0,
    population_member: u16 = 0,
    population_role: NpcPopulationRole = .unassigned,
    combat_disposition: NpcCombatDisposition = .unassigned,
    activity_kind: NpcActivityKind = .none,
    activity_state: NpcActivityState = .unassigned,
};

pub const SnapshotKind = enum(u8) {
    full = 1,
    delta = 2,
};

pub const Snapshot = struct {
    kind: SnapshotKind,
    baseline_id: u32,
    base_sequence: identity.SnapshotSequence,
    sequence: identity.SnapshotSequence,
    server_tick: u64,
    acknowledged_input: identity.InputSequence,
    character_count: u8,
    vehicle_count: u8,
    carryable_count: u8,
    npc_update: bool,
    npc_count: u8,
    removed_character_count: u8,
    removed_vehicle_count: u8,
    removed_carryable_count: u8,
    removed_npc_count: u8,
    characters: [budgets.max_participants]CharacterState,
    vehicles: [budgets.max_vehicles]VehicleState,
    carryables: [budgets.max_carryables]CarryableState,
    npcs: [budgets.max_npcs]NpcState,
    removed_characters: [budgets.max_participants]identity.ReplicatedEntityId,
    removed_vehicles: [budgets.max_vehicles]identity.ReplicatedEntityId,
    removed_carryables: [budgets.max_carryables]identity.ReplicatedEntityId,
    removed_npcs: [budgets.max_npcs]identity.ReplicatedEntityId,

    pub fn empty() Snapshot {
        return .{
            .kind = .full,
            .baseline_id = 0,
            .base_sequence = .{ .value = 0 },
            .sequence = .{ .value = 0 },
            .server_tick = 0,
            .acknowledged_input = .{ .value = 0 },
            .character_count = 0,
            .vehicle_count = 0,
            .carryable_count = 0,
            .npc_update = false,
            .npc_count = 0,
            .removed_character_count = 0,
            .removed_vehicle_count = 0,
            .removed_carryable_count = 0,
            .removed_npc_count = 0,
            .characters = undefined,
            .vehicles = undefined,
            .carryables = undefined,
            .npcs = undefined,
            .removed_characters = undefined,
            .removed_vehicles = undefined,
            .removed_carryables = undefined,
            .removed_npcs = undefined,
        };
    }

    pub fn slice(self: *const Snapshot) []const CharacterState {
        return self.characters[0..self.character_count];
    }

    pub fn vehicleSlice(self: *const Snapshot) []const VehicleState {
        return self.vehicles[0..self.vehicle_count];
    }

    pub fn carryableSlice(self: *const Snapshot) []const CarryableState {
        return self.carryables[0..self.carryable_count];
    }

    pub fn npcSlice(self: *const Snapshot) []const NpcState {
        return self.npcs[0..self.npc_count];
    }
};

pub const DistrictCoord = struct {
    x: i32 = 0,
    z: i32 = 0,
};

pub const RelevanceBaseline = struct {
    baseline_id: u32,
    district_count: u8,
    // The inactive tail is initialized because this bounded control value is
    // copied, retained, and compared as a whole. Only districtSlice() is sent
    // on the wire, but leaving the tail undefined would make otherwise equal
    // baselines depend on build mode and stack contents.
    districts: [budgets.max_relevant_districts_per_client]DistrictCoord = @splat(.{}),
    snapshot: Snapshot,

    pub fn districtSlice(self: *const RelevanceBaseline) []const DistrictCoord {
        return self.districts[0..self.district_count];
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

pub const InteractionActionDisposition = enum(u8) {
    collected = 1,
    dropped = 2,
    carryable_not_found = 3,
    unavailable = 4,
    too_far = 5,
    invalid_state = 6,
};

pub const InteractionActionResult = struct {
    sequence: identity.ActionSequence,
    carryable: identity.ReplicatedEntityId,
    action: InteractionActionKind,
    disposition: InteractionActionDisposition,
};

pub const MeleeActionDisposition = enum(u8) {
    hit = 1,
    miss = 2,
    cooldown = 3,
    dead = 4,
    wrong_incarnation = 5,
    invalid_state = 6,
};

pub const MeleeActionResult = struct {
    sequence: identity.ActionSequence,
    disposition: MeleeActionDisposition,
    target: identity.ReplicatedEntityId = .invalid,
    target_incarnation: u16 = 0,
    applied_damage: u16 = 0,
    remaining_health: u16 = 0,
    killed: bool = false,
    ready_tick: u64 = 0,
};

pub const WeaponActionDisposition = enum(u8) {
    equipped = 1,
    holstered = 2,
    fired_hit = 3,
    fired_miss = 4,
    reload_started = 5,
    cooldown = 6,
    empty = 7,
    already_full = 8,
    no_reserve = 9,
    reloading = 10,
    not_equipped = 11,
    dead = 12,
    wrong_incarnation = 13,
    invalid_state = 14,
};

pub const WeaponActionResult = struct {
    sequence: identity.ActionSequence,
    authority_tick: u64,
    action: WeaponActionKind,
    disposition: WeaponActionDisposition,
    mode: WeaponMode,
    magazine_ammo: u16,
    reserve_ammo: u16,
    weapon_ready_tick: u64,
    reload_complete_tick: u64,
    target: identity.ReplicatedEntityId = .invalid,
    target_incarnation: u16 = 0,
    ray_origin: [3]f32 = @splat(0),
    impact_position: [3]f32 = @splat(0),
    applied_damage: u16 = 0,
    remaining_health: u16 = 0,
    killed: bool = false,
};

pub const ShotDisposition = enum(u8) {
    hit = 1,
    miss = 2,
};

pub const ShotEvent = struct {
    shooter: identity.ReplicatedEntityId,
    shooter_incarnation: u16,
    sequence: identity.ActionSequence,
    authority_tick: u64,
    disposition: ShotDisposition,
    ray_origin: [3]f32,
    impact_position: [3]f32,
    target: identity.ReplicatedEntityId = .invalid,
    target_incarnation: u16 = 0,
    applied_damage: u16 = 0,
    remaining_health: u16 = 0,
    killed: bool = false,
};

pub const RespawnActionDisposition = enum(u8) {
    respawned = 1,
    alive = 2,
    cooldown = 3,
    cleanup_pending = 4,
    no_safe_spawn = 5,
    wrong_incarnation = 6,
    invalid_state = 7,
};

pub const RespawnActionResult = struct {
    sequence: identity.ActionSequence,
    disposition: RespawnActionDisposition,
    avatar: identity.ReplicatedEntityId = .invalid,
    incarnation: u16,
    ready_tick: u64 = 0,
};

pub const LifeEvent = struct {
    avatar: identity.ReplicatedEntityId,
    incarnation: u16,
    /// Authority ordering stamp used to reconcile reliable events with the
    /// independently delivered unreliable snapshot lane.
    authority_tick: u64,
    health: u16,
    maximum_health: u16,
    state: AvatarLifeState,
    instigator: ?identity.ParticipantId = null,
    respawn_ready_tick: u64 = 0,
};

pub const Rejection = struct {
    reason: RejectionReason,
    detail_code: u16 = 0,
};

pub const ServerMessage = union(enum) {
    welcome: Welcome,
    snapshot: Snapshot,
    relevance_baseline: RelevanceBaseline,
    vehicle_action_result: VehicleActionResult,
    interaction_action_result: InteractionActionResult,
    melee_action_result: MeleeActionResult,
    weapon_action_result: WeaponActionResult,
    shot_event: ShotEvent,
    respawn_action_result: RespawnActionResult,
    life_event: LifeEvent,
    rejected: Rejection,
    disconnected: DisconnectReason,
};

/// Wire/link envelope for the application-observation commit point. Delivery
/// ID zero denotes an unreliable or non-replayable semantic message.
pub const DeliveredServerMessage = struct {
    delivery_id: u64 = 0,
    message: ServerMessage,
};

const Direction = enum(u8) { client = 1, server = 2 };
const ClientKind = enum(u8) {
    hello = 1,
    input = 2,
    vehicle_input = 3,
    vehicle_action = 4,
    disconnect = 5,
    interaction_action = 6,
    baseline_ack = 7,
    snapshot_ack = 8,
    delivery_receipt = 9,
    melee_action = 10,
    respawn_action = 11,
    weapon_action = 12,
};
const ServerKind = enum(u8) {
    welcome = 1,
    snapshot = 2,
    vehicle_action_result = 3,
    rejected = 4,
    disconnected = 5,
    interaction_action_result = 6,
    relevance_baseline = 7,
    melee_action_result = 8,
    respawn_action_result = 9,
    life_event = 10,
    weapon_action_result = 11,
    shot_event = 12,
};

pub fn encodeClient(message: ClientMessage, storage: []u8) ![]const u8 {
    try validateClient(message);
    var encoder = Encoder.init(storage);
    try encoder.header(.client, switch (message) {
        .hello => @intFromEnum(ClientKind.hello),
        .input => @intFromEnum(ClientKind.input),
        .vehicle_input => @intFromEnum(ClientKind.vehicle_input),
        .vehicle_action => @intFromEnum(ClientKind.vehicle_action),
        .interaction_action => @intFromEnum(ClientKind.interaction_action),
        .melee_action => @intFromEnum(ClientKind.melee_action),
        .weapon_action => @intFromEnum(ClientKind.weapon_action),
        .respawn_action => @intFromEnum(ClientKind.respawn_action),
        .baseline_ack => @intFromEnum(ClientKind.baseline_ack),
        .snapshot_ack => @intFromEnum(ClientKind.snapshot_ack),
        .delivery_receipt => @intFromEnum(ClientKind.delivery_receipt),
        .disconnect => @intFromEnum(ClientKind.disconnect),
    });
    switch (message) {
        .hello => |value| {
            try encoder.u16Value(value.protocol);
            try encoder.u64Value(value.build);
            try encoder.u64Value(value.content);
            try encoder.u64Value(value.account.value);
            try encoder.u8Value(@intFromEnum(value.external_identity.provider));
            try encoder.u64Value(value.external_identity.subject);
            try encoder.u64Value(value.join_authorization.room_id);
            try encoder.u64Value(value.join_authorization.authority_id);
            try encoder.u32Value(value.join_authorization.room_generation);
            try encoder.u64Value(value.join_authorization.nonce);
            try encoder.u64Value(value.join_authorization.expires_at_unix_seconds);
            for (value.join_authorization.authenticator) |byte| try encoder.u8Value(byte);
            try encoder.u64Value(value.reconnect.high);
            try encoder.u64Value(value.reconnect.low);
        },
        .input => |value| {
            try encodeInput(&encoder, value);
        },
        .vehicle_input => |value| try encodeVehicleInput(&encoder, value),
        .vehicle_action => |value| try encodeVehicleAction(&encoder, value),
        .interaction_action => |value| try encodeInteractionAction(&encoder, value),
        .melee_action => |value| {
            try encoder.u64Value(value.session.value);
            try encodeParticipant(&encoder, value.participant);
            try encoder.u32Value(value.sequence.value);
            try encoder.u16Value(value.avatar_incarnation);
            try encoder.u64Value(value.target_tick);
        },
        .weapon_action => |value| {
            try encoder.u64Value(value.session.value);
            try encodeParticipant(&encoder, value.participant);
            try encoder.u32Value(value.sequence.value);
            try encoder.u16Value(value.avatar_incarnation);
            try encoder.u64Value(value.target_tick);
            try encoder.u8Value(@intFromEnum(value.kind));
        },
        .respawn_action => |value| {
            try encoder.u64Value(value.session.value);
            try encodeParticipant(&encoder, value.participant);
            try encoder.u32Value(value.sequence.value);
            try encoder.u16Value(value.dead_incarnation);
        },
        .baseline_ack => |value| {
            try encoder.u64Value(value.session.value);
            try encodeParticipant(&encoder, value.participant);
            try encoder.u32Value(value.baseline_id);
        },
        .snapshot_ack => |value| {
            try encoder.u64Value(value.session.value);
            try encodeParticipant(&encoder, value.participant);
            try encoder.u32Value(value.baseline_id);
            try encoder.u32Value(value.sequence.value);
        },
        .delivery_receipt => |value| {
            try encoder.u64Value(value.session.value);
            try encodeParticipant(&encoder, value.participant);
            try encoder.u8Value(@intFromEnum(value.lane));
            try encoder.u64Value(value.delivery_id);
        },
        .disconnect => |reason| try encoder.u8Value(@intFromEnum(reason)),
    }
    return encoder.finish();
}

pub fn decodeClient(bytes: []const u8) !ClientMessage {
    var decoder = try Decoder.init(bytes, .client);
    const kind = enumFromInt(ClientKind, decoder.kind) catch
        return error.UnknownMessageKind;
    const message: ClientMessage = switch (kind) {
        .hello => .{ .hello = try decodeHello(&decoder) },
        .input => .{ .input = try decodeInput(&decoder) },
        .vehicle_input => .{ .vehicle_input = try decodeVehicleInput(&decoder) },
        .vehicle_action => .{ .vehicle_action = try decodeVehicleAction(&decoder) },
        .interaction_action => .{
            .interaction_action = try decodeInteractionAction(&decoder),
        },
        .melee_action => .{ .melee_action = .{
            .session = .{ .value = try decoder.u64Value() },
            .participant = try decodeParticipant(&decoder),
            .sequence = .{ .value = try decoder.u32Value() },
            .avatar_incarnation = try decoder.u16Value(),
            .target_tick = try decoder.u64Value(),
        } },
        .weapon_action => .{ .weapon_action = .{
            .session = .{ .value = try decoder.u64Value() },
            .participant = try decodeParticipant(&decoder),
            .sequence = .{ .value = try decoder.u32Value() },
            .avatar_incarnation = try decoder.u16Value(),
            .target_tick = try decoder.u64Value(),
            .kind = enumFromInt(
                WeaponActionKind,
                try decoder.u8Value(),
            ) catch return error.InvalidEnum,
        } },
        .respawn_action => .{ .respawn_action = .{
            .session = .{ .value = try decoder.u64Value() },
            .participant = try decodeParticipant(&decoder),
            .sequence = .{ .value = try decoder.u32Value() },
            .dead_incarnation = try decoder.u16Value(),
        } },
        .baseline_ack => .{ .baseline_ack = .{
            .session = .{ .value = try decoder.u64Value() },
            .participant = try decodeParticipant(&decoder),
            .baseline_id = try decoder.u32Value(),
        } },
        .snapshot_ack => .{ .snapshot_ack = .{
            .session = .{ .value = try decoder.u64Value() },
            .participant = try decodeParticipant(&decoder),
            .baseline_id = try decoder.u32Value(),
            .sequence = .{ .value = try decoder.u32Value() },
        } },
        .delivery_receipt => .{ .delivery_receipt = .{
            .session = .{ .value = try decoder.u64Value() },
            .participant = try decodeParticipant(&decoder),
            .lane = enumFromInt(
                ReliableLane,
                try decoder.u8Value(),
            ) catch return error.InvalidEnum,
            .delivery_id = try decoder.u64Value(),
        } },
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
    try validateServer(message);
    var encoder = Encoder.init(storage);
    try encoder.header(.server, switch (message) {
        .welcome => @intFromEnum(ServerKind.welcome),
        .snapshot => @intFromEnum(ServerKind.snapshot),
        .relevance_baseline => @intFromEnum(ServerKind.relevance_baseline),
        .vehicle_action_result => @intFromEnum(ServerKind.vehicle_action_result),
        .interaction_action_result => @intFromEnum(ServerKind.interaction_action_result),
        .melee_action_result => @intFromEnum(ServerKind.melee_action_result),
        .weapon_action_result => @intFromEnum(ServerKind.weapon_action_result),
        .shot_event => @intFromEnum(ServerKind.shot_event),
        .respawn_action_result => @intFromEnum(ServerKind.respawn_action_result),
        .life_event => @intFromEnum(ServerKind.life_event),
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
            try encodeReplicatedEntity(&encoder, value.avatar);
            try encoder.u16Value(value.avatar_incarnation);
            try encoder.u8Value(@intFromEnum(value.life_state));
            try encoder.u64Value(value.melee_ready_tick);
            try encoder.u8Value(@intFromEnum(value.weapon_mode));
            try encoder.u16Value(value.magazine_ammo);
            try encoder.u16Value(value.reserve_ammo);
            try encoder.u64Value(value.weapon_ready_tick);
            try encoder.u64Value(value.reload_complete_tick);
            try encoder.u64Value(value.respawn_ready_tick);
        },
        .snapshot => |value| try encodeSnapshot(&encoder, value),
        .relevance_baseline => |value| {
            try encoder.u32Value(value.baseline_id);
            try encoder.u8Value(value.district_count);
            for (value.districtSlice()) |district| {
                try encoder.u32Value(@bitCast(district.x));
                try encoder.u32Value(@bitCast(district.z));
            }
            try encodeSnapshot(&encoder, value.snapshot);
        },
        .vehicle_action_result => |value| {
            try encoder.u32Value(value.sequence.value);
            try encodeReplicatedEntity(&encoder, value.vehicle);
            try encoder.u8Value(@intFromEnum(value.action));
            try encoder.u8Value(@intFromEnum(value.disposition));
        },
        .interaction_action_result => |value| {
            try encoder.u32Value(value.sequence.value);
            try encodeReplicatedEntity(&encoder, value.carryable);
            try encoder.u8Value(@intFromEnum(value.action));
            try encoder.u8Value(@intFromEnum(value.disposition));
        },
        .melee_action_result => |value| {
            try encoder.u32Value(value.sequence.value);
            try encoder.u8Value(@intFromEnum(value.disposition));
            try encodeReplicatedEntity(&encoder, value.target);
            try encoder.u16Value(value.target_incarnation);
            try encoder.u16Value(value.applied_damage);
            try encoder.u16Value(value.remaining_health);
            try encoder.u8Value(@intFromBool(value.killed));
            try encoder.u64Value(value.ready_tick);
        },
        .weapon_action_result => |value| {
            try encoder.u32Value(value.sequence.value);
            try encoder.u64Value(value.authority_tick);
            try encoder.u8Value(@intFromEnum(value.action));
            try encoder.u8Value(@intFromEnum(value.disposition));
            try encoder.u8Value(@intFromEnum(value.mode));
            try encoder.u16Value(value.magazine_ammo);
            try encoder.u16Value(value.reserve_ammo);
            try encoder.u64Value(value.weapon_ready_tick);
            try encoder.u64Value(value.reload_complete_tick);
            try encodeReplicatedEntity(&encoder, value.target);
            try encoder.u16Value(value.target_incarnation);
            for (value.ray_origin) |component| try encoder.f32Value(component);
            for (value.impact_position) |component| try encoder.f32Value(component);
            try encoder.u16Value(value.applied_damage);
            try encoder.u16Value(value.remaining_health);
            try encoder.u8Value(@intFromBool(value.killed));
        },
        .shot_event => |value| {
            try encodeReplicatedEntity(&encoder, value.shooter);
            try encoder.u16Value(value.shooter_incarnation);
            try encoder.u32Value(value.sequence.value);
            try encoder.u64Value(value.authority_tick);
            try encoder.u8Value(@intFromEnum(value.disposition));
            for (value.ray_origin) |component| try encoder.f32Value(component);
            for (value.impact_position) |component| try encoder.f32Value(component);
            try encodeReplicatedEntity(&encoder, value.target);
            try encoder.u16Value(value.target_incarnation);
            try encoder.u16Value(value.applied_damage);
            try encoder.u16Value(value.remaining_health);
            try encoder.u8Value(@intFromBool(value.killed));
        },
        .respawn_action_result => |value| {
            try encoder.u32Value(value.sequence.value);
            try encoder.u8Value(@intFromEnum(value.disposition));
            try encodeReplicatedEntity(&encoder, value.avatar);
            try encoder.u16Value(value.incarnation);
            try encoder.u64Value(value.ready_tick);
        },
        .life_event => |value| {
            try encodeReplicatedEntity(&encoder, value.avatar);
            try encoder.u16Value(value.incarnation);
            try encoder.u64Value(value.authority_tick);
            try encoder.u16Value(value.health);
            try encoder.u16Value(value.maximum_health);
            try encoder.u8Value(@intFromEnum(value.state));
            try encoder.u8Value(@intFromBool(value.instigator != null));
            if (value.instigator) |instigator| try encodeParticipant(&encoder, instigator);
            try encoder.u64Value(value.respawn_ready_tick);
        },
        .rejected => |value| {
            try encoder.u8Value(@intFromEnum(value.reason));
            try encoder.u16Value(value.detail_code);
        },
        .disconnected => |reason| try encoder.u8Value(@intFromEnum(reason)),
    }
    const bytes = try encoder.finish();
    switch (message) {
        .snapshot, .relevance_baseline => if (bytes.len > budgets.max_snapshot_bytes) {
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
            .avatar = try decodeReplicatedEntity(&decoder),
            .avatar_incarnation = try decoder.u16Value(),
            .life_state = try enumFromInt(AvatarLifeState, try decoder.u8Value()),
            .melee_ready_tick = try decoder.u64Value(),
            .weapon_mode = try enumFromInt(WeaponMode, try decoder.u8Value()),
            .magazine_ammo = try decoder.u16Value(),
            .reserve_ammo = try decoder.u16Value(),
            .weapon_ready_tick = try decoder.u64Value(),
            .reload_complete_tick = try decoder.u64Value(),
            .respawn_ready_tick = try decoder.u64Value(),
        } },
        .snapshot => .{ .snapshot = try decodeSnapshot(&decoder) },
        .relevance_baseline => blk: {
            var baseline = RelevanceBaseline{
                .baseline_id = try decoder.u32Value(),
                .district_count = try decoder.u8Value(),
                .snapshot = undefined,
            };
            if (baseline.baseline_id == 0) return error.InvalidBaseline;
            if (baseline.district_count == 0 or
                baseline.district_count > budgets.max_relevant_districts_per_client)
            {
                return error.InvalidRelevantDistrictCount;
            }
            for (baseline.districts[0..baseline.district_count]) |*district| {
                district.* = .{
                    .x = @bitCast(try decoder.u32Value()),
                    .z = @bitCast(try decoder.u32Value()),
                };
            }
            baseline.snapshot = try decodeSnapshot(&decoder);
            if (baseline.snapshot.baseline_id != baseline.baseline_id) {
                return error.InvalidBaseline;
            }
            break :blk .{ .relevance_baseline = baseline };
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
        .interaction_action_result => .{ .interaction_action_result = .{
            .sequence = .{ .value = try decoder.u32Value() },
            .carryable = try decodeReplicatedEntity(&decoder),
            .action = enumFromInt(
                InteractionActionKind,
                try decoder.u8Value(),
            ) catch return error.InvalidEnum,
            .disposition = enumFromInt(
                InteractionActionDisposition,
                try decoder.u8Value(),
            ) catch return error.InvalidEnum,
        } },
        .melee_action_result => .{ .melee_action_result = .{
            .sequence = .{ .value = try decoder.u32Value() },
            .disposition = enumFromInt(
                MeleeActionDisposition,
                try decoder.u8Value(),
            ) catch return error.InvalidEnum,
            .target = try decodeReplicatedEntity(&decoder),
            .target_incarnation = try decoder.u16Value(),
            .applied_damage = try decoder.u16Value(),
            .remaining_health = try decoder.u16Value(),
            .killed = switch (try decoder.u8Value()) {
                0 => false,
                1 => true,
                else => return error.InvalidBoolean,
            },
            .ready_tick = try decoder.u64Value(),
        } },
        .weapon_action_result => .{ .weapon_action_result = .{
            .sequence = .{ .value = try decoder.u32Value() },
            .authority_tick = try decoder.u64Value(),
            .action = enumFromInt(WeaponActionKind, try decoder.u8Value()) catch
                return error.InvalidEnum,
            .disposition = enumFromInt(
                WeaponActionDisposition,
                try decoder.u8Value(),
            ) catch return error.InvalidEnum,
            .mode = enumFromInt(WeaponMode, try decoder.u8Value()) catch
                return error.InvalidEnum,
            .magazine_ammo = try decoder.u16Value(),
            .reserve_ammo = try decoder.u16Value(),
            .weapon_ready_tick = try decoder.u64Value(),
            .reload_complete_tick = try decoder.u64Value(),
            .target = try decodeReplicatedEntity(&decoder),
            .target_incarnation = try decoder.u16Value(),
            .ray_origin = .{
                try decoder.f32Value(), try decoder.f32Value(), try decoder.f32Value(),
            },
            .impact_position = .{
                try decoder.f32Value(), try decoder.f32Value(), try decoder.f32Value(),
            },
            .applied_damage = try decoder.u16Value(),
            .remaining_health = try decoder.u16Value(),
            .killed = try decodeBool(&decoder),
        } },
        .shot_event => .{ .shot_event = .{
            .shooter = try decodeReplicatedEntity(&decoder),
            .shooter_incarnation = try decoder.u16Value(),
            .sequence = .{ .value = try decoder.u32Value() },
            .authority_tick = try decoder.u64Value(),
            .disposition = enumFromInt(ShotDisposition, try decoder.u8Value()) catch
                return error.InvalidEnum,
            .ray_origin = .{
                try decoder.f32Value(), try decoder.f32Value(), try decoder.f32Value(),
            },
            .impact_position = .{
                try decoder.f32Value(), try decoder.f32Value(), try decoder.f32Value(),
            },
            .target = try decodeReplicatedEntity(&decoder),
            .target_incarnation = try decoder.u16Value(),
            .applied_damage = try decoder.u16Value(),
            .remaining_health = try decoder.u16Value(),
            .killed = try decodeBool(&decoder),
        } },
        .respawn_action_result => .{ .respawn_action_result = .{
            .sequence = .{ .value = try decoder.u32Value() },
            .disposition = enumFromInt(
                RespawnActionDisposition,
                try decoder.u8Value(),
            ) catch return error.InvalidEnum,
            .avatar = try decodeReplicatedEntity(&decoder),
            .incarnation = try decoder.u16Value(),
            .ready_tick = try decoder.u64Value(),
        } },
        .life_event => .{ .life_event = .{
            .avatar = try decodeReplicatedEntity(&decoder),
            .incarnation = try decoder.u16Value(),
            .authority_tick = try decoder.u64Value(),
            .health = try decoder.u16Value(),
            .maximum_health = try decoder.u16Value(),
            .state = enumFromInt(
                AvatarLifeState,
                try decoder.u8Value(),
            ) catch return error.InvalidEnum,
            .instigator = switch (try decoder.u8Value()) {
                0 => null,
                1 => try decodeParticipant(&decoder),
                else => return error.InvalidBoolean,
            },
            .respawn_ready_tick = try decoder.u64Value(),
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
    try validateServer(message);
    return message;
}

pub fn encodeDeliveredServer(
    delivered: DeliveredServerMessage,
    storage: []u8,
) ![]const u8 {
    if (storage.len < 8) return error.MessageTooLarge;
    std.mem.writeInt(u64, storage[0..8], delivered.delivery_id, .little);
    const message = try encodeServer(delivered.message, storage[8..]);
    return storage[0 .. 8 + message.len];
}

pub fn decodeDeliveredServer(bytes: []const u8) !DeliveredServerMessage {
    if (bytes.len < 8) return error.TruncatedMessage;
    return .{
        .delivery_id = std.mem.readInt(u64, bytes[0..8], .little),
        .message = try decodeServer(bytes[8..]),
    };
}

pub fn validateClient(message: ClientMessage) !void {
    switch (message) {
        .hello => |value| {
            try value.account.validate();
            if (value.external_identity.provider == .steam and
                value.external_identity.subject == 0)
            {
                return error.InvalidExternalIdentity;
            }
            if (value.external_identity.provider == .development and
                value.external_identity.subject != 0 and
                value.external_identity.subject != value.account.value)
            {
                return error.ExternalIdentityAccountMismatch;
            }
            const authorization = value.join_authorization;
            if (authorization.isPresent()) {
                if (authorization.authority_id == 0 or
                    authorization.room_generation == 0 or authorization.nonce == 0 or
                    authorization.expires_at_unix_seconds == 0 or
                    std.mem.allEqual(u8, &authorization.authenticator, 0))
                {
                    return error.InvalidJoinAuthorization;
                }
            } else if (authorization.authority_id != 0 or
                authorization.room_generation != 0 or authorization.nonce != 0 or
                authorization.expires_at_unix_seconds != 0 or
                !std.mem.allEqual(u8, &authorization.authenticator, 0))
            {
                return error.PartialJoinAuthorization;
            }
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
            try value.sequence.validate();
            try value.vehicle.validate();
        },
        .interaction_action => |value| {
            try value.session.validate();
            try value.participant.validate();
            try value.sequence.validate();
            try value.carryable.validate();
        },
        .melee_action => |value| {
            try value.session.validate();
            try value.participant.validate();
            try value.sequence.validate();
            if (value.avatar_incarnation == 0 or value.target_tick == 0) {
                return error.InvalidMeleeAction;
            }
        },
        .weapon_action => |value| {
            try value.session.validate();
            try value.participant.validate();
            try value.sequence.validate();
            if (value.avatar_incarnation == 0 or value.target_tick == 0) {
                return error.InvalidWeaponAction;
            }
        },
        .respawn_action => |value| {
            try value.session.validate();
            try value.participant.validate();
            try value.sequence.validate();
            if (value.dead_incarnation == 0) return error.InvalidRespawnAction;
        },
        .baseline_ack => |value| {
            try value.session.validate();
            try value.participant.validate();
            if (value.baseline_id == 0) return error.InvalidBaseline;
        },
        .snapshot_ack => |value| {
            try value.session.validate();
            try value.participant.validate();
            if (value.baseline_id == 0 or value.sequence.value == 0) {
                return error.InvalidSnapshotAck;
            }
        },
        .delivery_receipt => |value| {
            try value.session.validate();
            try value.participant.validate();
            if (value.delivery_id == 0) return error.InvalidDeliveryReceipt;
        },
        .disconnect => {},
    }
}

/// Validates transport-independent server semantics. Byte transports call this
/// before encoding and after decoding; typed in-process links call it before
/// enqueueing so local play exercises the same message contract.
pub fn validateServer(message: ServerMessage) !void {
    switch (message) {
        .welcome => |value| {
            try value.session.validate();
            try value.participant.validate();
            try value.connection.validate();
            if (!value.reconnect.isValid()) return error.InvalidReconnectToken;
            try value.avatar.validate();
            if (value.avatar_incarnation == 0 or
                value.avatar.generation != value.avatar_incarnation)
            {
                return error.InvalidWelcomeAvatar;
            }
        },
        .snapshot => |value| try validateSnapshot(value),
        .relevance_baseline => |value| {
            if (value.baseline_id == 0 or
                value.snapshot.baseline_id != value.baseline_id or
                value.snapshot.kind != .full)
            {
                return error.InvalidBaseline;
            }
            if (value.district_count == 0 or
                value.district_count > budgets.max_relevant_districts_per_client)
            {
                return error.InvalidRelevantDistrictCount;
            }
            try validateSnapshot(value.snapshot);
        },
        .vehicle_action_result => |value| {
            try value.sequence.validate();
            try value.vehicle.validate();
            try validateVehicleActionResult(value);
        },
        .interaction_action_result => |value| {
            try value.sequence.validate();
            try value.carryable.validate();
            try validateInteractionActionResult(value);
        },
        .melee_action_result => |value| {
            try value.sequence.validate();
            const hit = value.disposition == .hit;
            if (hit) {
                try value.target.validate();
                if (value.target_incarnation == 0 or value.applied_damage == 0) {
                    return error.InvalidMeleeActionResult;
                }
            } else if (value.target.isValid() or value.target_incarnation != 0 or
                value.applied_damage != 0 or value.remaining_health != 0 or value.killed)
            {
                return error.InvalidMeleeActionResult;
            }
        },
        .weapon_action_result => |value| {
            try value.sequence.validate();
            try validateWeaponProjection(
                value.mode,
                value.reload_complete_tick,
            );
            try validateFiniteComponents(&value.ray_origin);
            try validateFiniteComponents(&value.impact_position);
            const fired = value.disposition == .fired_hit or
                value.disposition == .fired_miss;
            if (fired and value.action != .fire) {
                return error.InvalidWeaponActionResult;
            }
            if (value.disposition == .fired_hit) {
                try value.target.validate();
                if (value.target_incarnation == 0 or value.applied_damage == 0) {
                    return error.InvalidWeaponActionResult;
                }
            } else if (value.target.isValid() or value.target_incarnation != 0 or
                value.applied_damage != 0 or value.remaining_health != 0 or value.killed)
            {
                return error.InvalidWeaponActionResult;
            }
        },
        .shot_event => |value| {
            try value.shooter.validate();
            try value.sequence.validate();
            if (value.shooter_incarnation == 0 or value.authority_tick == 0) {
                return error.InvalidShotEvent;
            }
            try validateFiniteComponents(&value.ray_origin);
            try validateFiniteComponents(&value.impact_position);
            if (value.disposition == .hit) {
                try value.target.validate();
                if (value.target_incarnation == 0 or value.applied_damage == 0) {
                    return error.InvalidShotEvent;
                }
            } else if (value.target.isValid() or value.target_incarnation != 0 or
                value.applied_damage != 0 or value.remaining_health != 0 or value.killed)
            {
                return error.InvalidShotEvent;
            }
        },
        .respawn_action_result => |value| {
            try value.sequence.validate();
            if (value.incarnation == 0) return error.InvalidRespawnActionResult;
            if (value.disposition == .respawned) {
                try value.avatar.validate();
            } else if (value.avatar.isValid()) return error.InvalidRespawnActionResult;
        },
        .life_event => |value| {
            try value.avatar.validate();
            if (value.incarnation == 0 or value.authority_tick == 0 or
                value.maximum_health == 0 or
                value.health > value.maximum_health)
            {
                return error.InvalidLifeEvent;
            }
            if ((value.state == .alive and value.health == 0) or
                (value.state == .dead and value.health != 0))
            {
                return error.InvalidLifeEvent;
            }
            if (value.instigator) |instigator| try instigator.validate();
        },
        .rejected, .disconnected => {},
    }
}

fn validateVehicleActionResult(value: VehicleActionResult) !void {
    const compatible = switch (value.action) {
        .enter => switch (value.disposition) {
            .entered,
            .vehicle_not_found,
            .unavailable,
            .too_far,
            .invalid_state,
            => true,
            .exited, .exit_blocked => false,
        },
        .exit => switch (value.disposition) {
            .exited,
            .vehicle_not_found,
            .unavailable,
            .exit_blocked,
            .invalid_state,
            => true,
            .entered, .too_far => false,
        },
    };
    if (!compatible) return error.InvalidVehicleActionResultDisposition;
}

fn validateInteractionActionResult(value: InteractionActionResult) !void {
    const compatible = switch (value.action) {
        .collect => switch (value.disposition) {
            .collected,
            .carryable_not_found,
            .unavailable,
            .too_far,
            .invalid_state,
            => true,
            .dropped => false,
        },
        .drop => switch (value.disposition) {
            .dropped,
            .carryable_not_found,
            .unavailable,
            .invalid_state,
            => true,
            .collected, .too_far => false,
        },
    };
    if (!compatible) return error.InvalidInteractionActionResultDisposition;
}

/// Validates a complete projection before it is retained by client state.
/// Wire deltas must be materialized first; this final check catches identity
/// conflicts between a delta and unchanged entities inherited from its base.
pub fn validateMaterializedSnapshot(value: Snapshot) !void {
    if (value.kind != .full) return error.SnapshotNotMaterialized;
    try validateSnapshot(value);
}

const max_projection_identity_count = budgets.max_participants +
    budgets.max_vehicles + budgets.max_carryables + budgets.max_npcs;

const ProjectionIdentitySet = struct {
    values: [max_projection_identity_count]identity.ReplicatedEntityId = undefined,
    count: usize = 0,

    fn contains(
        self: *const ProjectionIdentitySet,
        candidate: identity.ReplicatedEntityId,
    ) bool {
        for (self.values[0..self.count]) |value| {
            if (std.meta.eql(value, candidate)) return true;
        }
        return false;
    }

    fn insert(
        self: *ProjectionIdentitySet,
        candidate: identity.ReplicatedEntityId,
    ) bool {
        if (self.contains(candidate)) return false;
        std.debug.assert(self.count < self.values.len);
        self.values[self.count] = candidate;
        self.count += 1;
        return true;
    }
};

fn recordActiveProjectionIdentity(
    active: *ProjectionIdentitySet,
    entity: identity.ReplicatedEntityId,
) !void {
    if (!active.insert(entity)) return error.DuplicateActiveProjectionEntity;
}

fn recordRemovedProjectionIdentity(
    active: *const ProjectionIdentitySet,
    removed: *ProjectionIdentitySet,
    entity: identity.ReplicatedEntityId,
) !void {
    if (active.contains(entity)) return error.ConflictingProjectionEntityChange;
    if (!removed.insert(entity)) return error.DuplicateRemovedProjectionEntity;
}

fn validateProjectionIdentities(value: Snapshot) !void {
    var active = ProjectionIdentitySet{};
    for (value.slice()) |character| {
        try recordActiveProjectionIdentity(&active, character.entity);
    }
    for (value.vehicleSlice()) |vehicle| {
        try recordActiveProjectionIdentity(&active, vehicle.entity);
    }
    for (value.carryableSlice()) |carryable| {
        try recordActiveProjectionIdentity(&active, carryable.entity);
    }
    for (value.npcSlice()) |npc| {
        try recordActiveProjectionIdentity(&active, npc.entity);
    }

    if (value.kind == .full) return;

    var removed = ProjectionIdentitySet{};
    for (value.removed_characters[0..value.removed_character_count]) |entity| {
        try recordRemovedProjectionIdentity(&active, &removed, entity);
    }
    for (value.removed_vehicles[0..value.removed_vehicle_count]) |entity| {
        try recordRemovedProjectionIdentity(&active, &removed, entity);
    }
    for (value.removed_carryables[0..value.removed_carryable_count]) |entity| {
        try recordRemovedProjectionIdentity(&active, &removed, entity);
    }
    for (value.removed_npcs[0..value.removed_npc_count]) |entity| {
        try recordRemovedProjectionIdentity(&active, &removed, entity);
    }
}

fn validateSnapshot(value: Snapshot) !void {
    if (value.sequence.value == 0) return error.InvalidSnapshotSequence;
    if (value.character_count > budgets.max_participants) return error.TooManyCharacters;
    if (value.vehicle_count > budgets.max_vehicles) return error.TooManyVehicles;
    if (value.carryable_count > budgets.max_carryables) return error.TooManyCarryables;
    if (value.npc_count > budgets.max_npcs or
        (!value.npc_update and (value.npc_count != 0 or value.removed_npc_count != 0)))
    {
        return error.InvalidNpcProjection;
    }
    if (value.removed_character_count > budgets.max_participants or
        value.removed_vehicle_count > budgets.max_vehicles or
        value.removed_carryable_count > budgets.max_carryables or
        value.removed_npc_count > budgets.max_npcs)
    {
        return error.TooManyRemovedEntities;
    }
    if ((value.kind == .full and (value.base_sequence.value != 0 or
        value.removed_character_count != 0 or value.removed_vehicle_count != 0 or
        value.removed_carryable_count != 0 or value.removed_npc_count != 0)) or
        (value.kind == .delta and value.base_sequence.value == 0))
    {
        return error.InvalidSnapshotKind;
    }

    for (value.slice()) |character| {
        try character.entity.validate();
        try character.owner.validate();
        try validateFiniteComponents(&character.position);
        try validateFiniteComponents(&character.velocity);
        if (!std.math.isFinite(character.facing_yaw)) return error.NonFiniteProjection;
        try validateVitalsProjection(
            character.entity,
            character.incarnation,
            character.health,
            character.maximum_health,
            character.life_state,
        );
        try validateWeaponProjection(
            character.weapon_mode,
            character.reload_complete_tick,
        );
    }
    for (value.vehicleSlice()) |vehicle| {
        try vehicle.entity.validate();
        if (vehicle.driver) |driver| try driver.validate();
        try validateFiniteComponents(&vehicle.position);
        try validateProjectionQuaternion(vehicle.rotation);
        try validateFiniteComponents(&vehicle.linear_velocity);
        try validateFiniteComponents(&vehicle.angular_velocity);
        for (vehicle.wheels) |wheel| try wheel.validate();
    }
    for (value.carryableSlice()) |carryable| {
        try carryable.entity.validate();
        if (carryable.holder) |holder| try holder.validate();
        try validateFiniteComponents(&carryable.position);
        try validateProjectionQuaternion(carryable.rotation);
        try validateFiniteComponents(&carryable.linear_velocity);
        try validateFiniteComponents(&carryable.angular_velocity);
        try validateFiniteComponents(&carryable.half_extents);
        for (carryable.half_extents) |extent| {
            if (extent <= 0) return error.InvalidCarryableExtents;
        }
    }
    for (value.npcSlice()) |npc| {
        try npc.entity.validate();
        try validateFiniteComponents(&npc.position);
        try validateFiniteComponents(&npc.velocity);
        if (!std.math.isFinite(npc.facing_yaw)) return error.NonFiniteProjection;
        try validateVitalsProjection(
            npc.entity,
            npc.incarnation,
            npc.health,
            npc.maximum_health,
            npc.life_state,
        );
        if (npc.population_member == 0) {
            if (npc.population_role != .unassigned or
                npc.combat_disposition != .unassigned or
                npc.activity_kind != .none or
                npc.activity_state != .unassigned)
            {
                return error.InvalidNpcPopulationProjection;
            }
        } else if (npc.population_role == .unassigned or
            npc.combat_disposition == .unassigned or
            npc.activity_state == .unassigned)
        {
            return error.InvalidNpcPopulationProjection;
        }
    }
    for (value.removed_characters[0..value.removed_character_count]) |entity| {
        try entity.validate();
    }
    for (value.removed_vehicles[0..value.removed_vehicle_count]) |entity| {
        try entity.validate();
    }
    for (value.removed_carryables[0..value.removed_carryable_count]) |entity| {
        try entity.validate();
    }
    for (value.removed_npcs[0..value.removed_npc_count]) |entity| {
        try entity.validate();
    }
    try validateProjectionIdentities(value);
}

fn validateVitalsProjection(
    entity: identity.ReplicatedEntityId,
    incarnation: u16,
    health: u16,
    maximum_health: u16,
    life_state: AvatarLifeState,
) !void {
    _ = entity;
    if (incarnation == 0 or maximum_health == 0 or health > maximum_health) {
        return error.InvalidVitalsProjection;
    }
    if ((life_state == .alive and health == 0) or
        (life_state == .dead and health != 0)) return error.InvalidVitalsProjection;
}

fn validateFiniteComponents(values: []const f32) !void {
    for (values) |value| {
        if (!std.math.isFinite(value)) return error.NonFiniteProjection;
    }
}

fn validateWeaponProjection(mode: WeaponMode, reload_complete_tick: u64) !void {
    switch (mode) {
        .holstered, .equipped => if (reload_complete_tick != 0) {
            return error.InvalidWeaponProjection;
        },
        .reloading => if (reload_complete_tick == 0) {
            return error.InvalidWeaponProjection;
        },
    }
}

fn decodeBool(decoder: *Decoder) !bool {
    return switch (try decoder.u8Value()) {
        0 => false,
        1 => true,
        else => error.InvalidBoolean,
    };
}

fn validateProjectionQuaternion(value: [4]f32) !void {
    try validateFiniteComponents(&value);
    var scale: f32 = 0;
    for (value) |component| scale = @max(scale, @abs(component));
    if (scale == 0) return error.DegenerateQuaternion;

    var scaled_length_squared: f32 = 0;
    for (value) |component| {
        const scaled = component / scale;
        scaled_length_squared += scaled * scaled;
    }
    if (!std.math.isFinite(scaled_length_squared) or scaled_length_squared == 0) {
        return error.DegenerateQuaternion;
    }
}

fn decodeHello(decoder: *Decoder) !Hello {
    var hello = Hello{
        .protocol = try decoder.u16Value(),
        .build = try decoder.u64Value(),
        .content = try decoder.u64Value(),
        .account = .{ .value = try decoder.u64Value() },
        .external_identity = .{
            .provider = enumFromInt(
                IdentityProvider,
                try decoder.u8Value(),
            ) catch return error.InvalidEnum,
            .subject = try decoder.u64Value(),
        },
        .join_authorization = .{
            .room_id = try decoder.u64Value(),
            .authority_id = try decoder.u64Value(),
            .room_generation = try decoder.u32Value(),
            .nonce = try decoder.u64Value(),
            .expires_at_unix_seconds = try decoder.u64Value(),
            .authenticator = undefined,
        },
        .reconnect = undefined,
    };
    for (&hello.join_authorization.authenticator) |*byte| byte.* = try decoder.u8Value();
    hello.reconnect = .{
        .high = try decoder.u64Value(),
        .low = try decoder.u64Value(),
    };
    return hello;
}

pub const AdmissionSecret = [32]u8;

pub fn signJoinAuthorization(
    secret: AdmissionSecret,
    account: identity.AccountId,
    external_identity: ExternalIdentity,
    authorization: *JoinAuthorization,
) void {
    var message: [64]u8 = @splat(0);
    var offset: usize = 0;
    inline for (.{
        account.value,
        @as(u64, @intFromEnum(external_identity.provider)),
        external_identity.subject,
        authorization.room_id,
        authorization.authority_id,
        @as(u64, authorization.room_generation),
        authorization.nonce,
        authorization.expires_at_unix_seconds,
    }) |value| {
        inline for (0..8) |index| message[offset + index] = @truncate(value >> (index * 8));
        offset += 8;
    }
    std.crypto.auth.hmac.sha2.HmacSha256.create(
        &authorization.authenticator,
        &message,
        &secret,
    );
}

pub fn verifyJoinAuthorization(
    secret: AdmissionSecret,
    account: identity.AccountId,
    external_identity: ExternalIdentity,
    authorization: JoinAuthorization,
) bool {
    var expected = authorization;
    expected.authenticator = @splat(0);
    signJoinAuthorization(secret, account, external_identity, &expected);
    return std.crypto.timing_safe.eql(
        [32]u8,
        expected.authenticator,
        authorization.authenticator,
    );
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

fn encodeSnapshot(encoder: *Encoder, value: Snapshot) !void {
    try encoder.u8Value(@intFromEnum(value.kind));
    try encoder.u32Value(value.baseline_id);
    try encoder.u32Value(value.base_sequence.value);
    try encoder.u32Value(value.sequence.value);
    try encoder.u64Value(value.server_tick);
    try encoder.u32Value(value.acknowledged_input.value);
    try encoder.u8Value(value.character_count);
    try encoder.u8Value(value.vehicle_count);
    try encoder.u8Value(value.carryable_count);
    try encoder.u8Value(@intFromBool(value.npc_update));
    try encoder.u8Value(value.npc_count);
    try encoder.u8Value(value.removed_character_count);
    try encoder.u8Value(value.removed_vehicle_count);
    try encoder.u8Value(value.removed_carryable_count);
    try encoder.u8Value(value.removed_npc_count);
    for (value.slice()) |character| try encodeCharacter(encoder, character);
    for (value.vehicleSlice()) |vehicle| try encodeVehicle(encoder, vehicle);
    for (value.carryableSlice()) |carryable| try encodeCarryable(encoder, carryable);
    for (value.npcSlice()) |npc| try encodeNpc(encoder, npc);
    for (value.removed_characters[0..value.removed_character_count]) |entity| {
        try encodeReplicatedEntity(encoder, entity);
    }
    for (value.removed_vehicles[0..value.removed_vehicle_count]) |entity| {
        try encodeReplicatedEntity(encoder, entity);
    }
    for (value.removed_carryables[0..value.removed_carryable_count]) |entity| {
        try encodeReplicatedEntity(encoder, entity);
    }
    for (value.removed_npcs[0..value.removed_npc_count]) |entity| {
        try encodeReplicatedEntity(encoder, entity);
    }
}

fn decodeSnapshot(decoder: *Decoder) !Snapshot {
    var snapshot = Snapshot.empty();
    snapshot.kind = enumFromInt(SnapshotKind, try decoder.u8Value()) catch
        return error.InvalidEnum;
    snapshot.baseline_id = try decoder.u32Value();
    snapshot.base_sequence.value = try decoder.u32Value();
    snapshot.sequence.value = try decoder.u32Value();
    snapshot.server_tick = try decoder.u64Value();
    snapshot.acknowledged_input.value = try decoder.u32Value();
    snapshot.character_count = try decoder.u8Value();
    snapshot.vehicle_count = try decoder.u8Value();
    snapshot.carryable_count = try decoder.u8Value();
    snapshot.npc_update = switch (try decoder.u8Value()) {
        0 => false,
        1 => true,
        else => return error.InvalidBoolean,
    };
    snapshot.npc_count = try decoder.u8Value();
    snapshot.removed_character_count = try decoder.u8Value();
    snapshot.removed_vehicle_count = try decoder.u8Value();
    snapshot.removed_carryable_count = try decoder.u8Value();
    snapshot.removed_npc_count = try decoder.u8Value();
    if (snapshot.character_count > budgets.max_participants) return error.TooManyCharacters;
    if (snapshot.vehicle_count > budgets.max_vehicles) return error.TooManyVehicles;
    if (snapshot.carryable_count > budgets.max_carryables) return error.TooManyCarryables;
    if (snapshot.npc_count > budgets.max_npcs or
        (!snapshot.npc_update and snapshot.npc_count != 0))
    {
        return error.InvalidNpcProjection;
    }
    if (snapshot.removed_character_count > budgets.max_participants or
        snapshot.removed_vehicle_count > budgets.max_vehicles or
        snapshot.removed_carryable_count > budgets.max_carryables or
        snapshot.removed_npc_count > budgets.max_npcs)
    {
        return error.TooManyRemovedEntities;
    }
    if ((snapshot.kind == .full and (snapshot.base_sequence.value != 0 or
        snapshot.removed_character_count != 0 or snapshot.removed_vehicle_count != 0 or
        snapshot.removed_carryable_count != 0 or snapshot.removed_npc_count != 0)) or
        (snapshot.kind == .delta and snapshot.base_sequence.value == 0))
    {
        return error.InvalidSnapshotKind;
    }
    for (snapshot.characters[0..snapshot.character_count]) |*character| {
        character.* = try decodeCharacter(decoder);
    }
    for (snapshot.vehicles[0..snapshot.vehicle_count]) |*vehicle| {
        vehicle.* = try decodeVehicle(decoder);
    }
    for (snapshot.carryables[0..snapshot.carryable_count]) |*carryable| {
        carryable.* = try decodeCarryable(decoder);
    }
    for (snapshot.npcs[0..snapshot.npc_count]) |*npc| {
        npc.* = try decodeNpc(decoder);
    }
    for (snapshot.removed_characters[0..snapshot.removed_character_count]) |*entity| {
        entity.* = try decodeReplicatedEntity(decoder);
    }
    for (snapshot.removed_vehicles[0..snapshot.removed_vehicle_count]) |*entity| {
        entity.* = try decodeReplicatedEntity(decoder);
    }
    for (snapshot.removed_carryables[0..snapshot.removed_carryable_count]) |*entity| {
        entity.* = try decodeReplicatedEntity(decoder);
    }
    for (snapshot.removed_npcs[0..snapshot.removed_npc_count]) |*entity| {
        entity.* = try decodeReplicatedEntity(decoder);
    }
    return snapshot;
}

/// Builds a replaceable state delta against an acknowledged, materialized
/// projection. Both inputs remain backend-neutral full projections.
pub fn makeDelta(base: Snapshot, current: Snapshot, include_npcs: bool) !Snapshot {
    if (base.kind != .full or current.kind != .full or
        base.baseline_id == 0 or base.baseline_id != current.baseline_id or
        base.sequence.value == 0 or current.sequence.value == 0)
    {
        return error.InvalidDeltaBase;
    }
    try validateMaterializedSnapshot(base);
    try validateMaterializedSnapshot(current);
    var delta = Snapshot.empty();
    delta.kind = .delta;
    delta.baseline_id = current.baseline_id;
    delta.base_sequence = base.sequence;
    delta.sequence = current.sequence;
    delta.server_tick = current.server_tick;
    delta.acknowledged_input = current.acknowledged_input;

    for (current.slice()) |value| {
        const previous = findCharacter(base.slice(), value.entity);
        if (previous == null or !std.meta.eql(previous.?, value)) {
            delta.characters[delta.character_count] = value;
            delta.character_count += 1;
        }
    }
    for (base.slice()) |value| if (findCharacter(current.slice(), value.entity) == null) {
        delta.removed_characters[delta.removed_character_count] = value.entity;
        delta.removed_character_count += 1;
    };

    for (current.vehicleSlice()) |value| {
        const previous = findVehicle(base.vehicleSlice(), value.entity);
        if (previous == null or !std.meta.eql(previous.?, value)) {
            delta.vehicles[delta.vehicle_count] = value;
            delta.vehicle_count += 1;
        }
    }
    for (base.vehicleSlice()) |value| if (findVehicle(current.vehicleSlice(), value.entity) == null) {
        delta.removed_vehicles[delta.removed_vehicle_count] = value.entity;
        delta.removed_vehicle_count += 1;
    };

    for (current.carryableSlice()) |value| {
        const previous = findCarryable(base.carryableSlice(), value.entity);
        if (previous == null or !std.meta.eql(previous.?, value)) {
            delta.carryables[delta.carryable_count] = value;
            delta.carryable_count += 1;
        }
    }
    for (base.carryableSlice()) |value| if (findCarryable(current.carryableSlice(), value.entity) == null) {
        delta.removed_carryables[delta.removed_carryable_count] = value.entity;
        delta.removed_carryable_count += 1;
    };

    delta.npc_update = include_npcs;
    if (include_npcs) {
        for (current.npcSlice()) |value| {
            const previous = findNpc(base.npcSlice(), value.entity);
            if (previous == null or !std.meta.eql(previous.?, value)) {
                delta.npcs[delta.npc_count] = value;
                delta.npc_count += 1;
            }
        }
        for (base.npcSlice()) |value| if (findNpc(current.npcSlice(), value.entity) == null) {
            delta.removed_npcs[delta.removed_npc_count] = value.entity;
            delta.removed_npc_count += 1;
        };
    }
    try validateSnapshot(delta);
    return delta;
}

/// Reconstructs a complete projection from an exact base and its delta. This
/// keeps later deltas correct even when several reference the same acked base.
pub fn materializeDelta(base: Snapshot, delta: Snapshot) !Snapshot {
    if (base.kind != .full or delta.kind != .delta or
        !std.meta.eql(base.sequence, delta.base_sequence) or
        base.baseline_id != delta.baseline_id)
    {
        return error.DeltaBaseMismatch;
    }
    try validateMaterializedSnapshot(base);
    try validateSnapshot(delta);
    var result = base;
    result.kind = .full;
    result.base_sequence = .{ .value = 0 };
    result.sequence = delta.sequence;
    result.server_tick = delta.server_tick;
    result.acknowledged_input = delta.acknowledged_input;
    for (delta.removed_characters[0..delta.removed_character_count]) |entity| {
        removeCharacter(&result, entity);
    }
    for (delta.slice()) |value| try upsertCharacter(&result, value);
    for (delta.removed_vehicles[0..delta.removed_vehicle_count]) |entity| {
        removeVehicle(&result, entity);
    }
    for (delta.vehicleSlice()) |value| try upsertVehicle(&result, value);
    for (delta.removed_carryables[0..delta.removed_carryable_count]) |entity| {
        removeCarryable(&result, entity);
    }
    for (delta.carryableSlice()) |value| try upsertCarryable(&result, value);
    if (delta.npc_update) {
        for (delta.removed_npcs[0..delta.removed_npc_count]) |entity| removeNpc(&result, entity);
        for (delta.npcSlice()) |value| try upsertNpc(&result, value);
    }
    result.npc_update = true;
    result.removed_character_count = 0;
    result.removed_vehicle_count = 0;
    result.removed_carryable_count = 0;
    result.removed_npc_count = 0;
    try validateMaterializedSnapshot(result);
    return result;
}

fn findCharacter(values: []const CharacterState, entity: identity.ReplicatedEntityId) ?CharacterState {
    for (values) |value| if (std.meta.eql(value.entity, entity)) return value;
    return null;
}

fn findVehicle(values: []const VehicleState, entity: identity.ReplicatedEntityId) ?VehicleState {
    for (values) |value| if (std.meta.eql(value.entity, entity)) return value;
    return null;
}

fn findCarryable(values: []const CarryableState, entity: identity.ReplicatedEntityId) ?CarryableState {
    for (values) |value| if (std.meta.eql(value.entity, entity)) return value;
    return null;
}

fn findNpc(values: []const NpcState, entity: identity.ReplicatedEntityId) ?NpcState {
    for (values) |value| if (std.meta.eql(value.entity, entity)) return value;
    return null;
}

fn upsertCharacter(snapshot: *Snapshot, value: CharacterState) !void {
    for (snapshot.characters[0..snapshot.character_count]) |*existing| {
        if (std.meta.eql(existing.entity, value.entity)) {
            existing.* = value;
            return;
        }
    }
    if (snapshot.character_count == budgets.max_participants) return error.TooManyCharacters;
    snapshot.characters[snapshot.character_count] = value;
    snapshot.character_count += 1;
}

fn upsertVehicle(snapshot: *Snapshot, value: VehicleState) !void {
    for (snapshot.vehicles[0..snapshot.vehicle_count]) |*existing| {
        if (std.meta.eql(existing.entity, value.entity)) {
            existing.* = value;
            return;
        }
    }
    if (snapshot.vehicle_count == budgets.max_vehicles) return error.TooManyVehicles;
    snapshot.vehicles[snapshot.vehicle_count] = value;
    snapshot.vehicle_count += 1;
}

fn upsertCarryable(snapshot: *Snapshot, value: CarryableState) !void {
    for (snapshot.carryables[0..snapshot.carryable_count]) |*existing| {
        if (std.meta.eql(existing.entity, value.entity)) {
            existing.* = value;
            return;
        }
    }
    if (snapshot.carryable_count == budgets.max_carryables) return error.TooManyCarryables;
    snapshot.carryables[snapshot.carryable_count] = value;
    snapshot.carryable_count += 1;
}

fn upsertNpc(snapshot: *Snapshot, value: NpcState) !void {
    for (snapshot.npcs[0..snapshot.npc_count]) |*existing| {
        if (std.meta.eql(existing.entity, value.entity)) {
            existing.* = value;
            return;
        }
    }
    if (snapshot.npc_count == budgets.max_npcs) return error.TooManyNpcs;
    snapshot.npcs[snapshot.npc_count] = value;
    snapshot.npc_count += 1;
}

fn removeCharacter(snapshot: *Snapshot, entity: identity.ReplicatedEntityId) void {
    var index: usize = 0;
    while (index < snapshot.character_count) : (index += 1) if (std.meta.eql(snapshot.characters[index].entity, entity)) {
        snapshot.character_count -= 1;
        snapshot.characters[index] = snapshot.characters[snapshot.character_count];
        return;
    };
}

fn removeVehicle(snapshot: *Snapshot, entity: identity.ReplicatedEntityId) void {
    var index: usize = 0;
    while (index < snapshot.vehicle_count) : (index += 1) if (std.meta.eql(snapshot.vehicles[index].entity, entity)) {
        snapshot.vehicle_count -= 1;
        snapshot.vehicles[index] = snapshot.vehicles[snapshot.vehicle_count];
        return;
    };
}

fn removeCarryable(snapshot: *Snapshot, entity: identity.ReplicatedEntityId) void {
    var index: usize = 0;
    while (index < snapshot.carryable_count) : (index += 1) if (std.meta.eql(snapshot.carryables[index].entity, entity)) {
        snapshot.carryable_count -= 1;
        snapshot.carryables[index] = snapshot.carryables[snapshot.carryable_count];
        return;
    };
}

fn removeNpc(snapshot: *Snapshot, entity: identity.ReplicatedEntityId) void {
    var index: usize = 0;
    while (index < snapshot.npc_count) : (index += 1) if (std.meta.eql(snapshot.npcs[index].entity, entity)) {
        snapshot.npc_count -= 1;
        snapshot.npcs[index] = snapshot.npcs[snapshot.npc_count];
        return;
    };
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

fn encodeInteractionAction(encoder: *Encoder, value: InteractionAction) !void {
    try encoder.u64Value(value.session.value);
    try encodeParticipant(encoder, value.participant);
    try encoder.u32Value(value.sequence.value);
    try encodeReplicatedEntity(encoder, value.carryable);
    try encoder.u8Value(@intFromEnum(value.kind));
}

fn decodeInteractionAction(decoder: *Decoder) !InteractionAction {
    return .{
        .session = .{ .value = try decoder.u64Value() },
        .participant = try decodeParticipant(decoder),
        .sequence = .{ .value = try decoder.u32Value() },
        .carryable = try decodeReplicatedEntity(decoder),
        .kind = enumFromInt(
            InteractionActionKind,
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
    try encoder.u16Value(value.incarnation);
    try encoder.u16Value(value.health);
    try encoder.u16Value(value.maximum_health);
    try encoder.u8Value(@intFromEnum(value.life_state));
    try encoder.u8Value(@intFromEnum(value.weapon_mode));
    try encoder.u16Value(value.magazine_ammo);
    try encoder.u16Value(value.reserve_ammo);
    try encoder.u64Value(value.weapon_ready_tick);
    try encoder.u64Value(value.reload_complete_tick);
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
        .incarnation = 0,
        .health = 0,
        .maximum_health = 0,
        .life_state = undefined,
        .weapon_mode = undefined,
    };
    for (&value.position) |*component| component.* = try decoder.f32Value();
    for (&value.velocity) |*component| component.* = try decoder.f32Value();
    value.facing_yaw = try decoder.f32Value();
    value.incarnation = try decoder.u16Value();
    value.health = try decoder.u16Value();
    value.maximum_health = try decoder.u16Value();
    value.life_state = enumFromInt(
        AvatarLifeState,
        try decoder.u8Value(),
    ) catch return error.InvalidEnum;
    value.weapon_mode = enumFromInt(
        WeaponMode,
        try decoder.u8Value(),
    ) catch return error.InvalidEnum;
    value.magazine_ammo = try decoder.u16Value();
    value.reserve_ammo = try decoder.u16Value();
    value.weapon_ready_tick = try decoder.u64Value();
    value.reload_complete_tick = try decoder.u64Value();
    return value;
}

fn encodeVehicle(encoder: *Encoder, value: VehicleState) !void {
    try encodeReplicatedEntity(encoder, value.entity);
    for (value.position) |component| try encoder.f32Value(component);
    for (value.rotation) |component| try encoder.f32Value(component);
    for (value.linear_velocity) |component| try encoder.f32Value(component);
    for (value.angular_velocity) |component| try encoder.f32Value(component);
    for (value.wheels) |wheel| {
        try encoder.f32Value(wheel.spin_phase);
        try encoder.f32Value(wheel.angular_velocity);
        try encoder.f32Value(wheel.steer_angle);
        try encoder.f32Value(wheel.suspension_length);
        try encoder.u8Value(@intFromBool(wheel.has_contact));
    }
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
        .wheels = undefined,
        .driver = null,
    };
    for (&value.position) |*component| component.* = try decoder.f32Value();
    for (&value.rotation) |*component| component.* = try decoder.f32Value();
    for (&value.linear_velocity) |*component| component.* = try decoder.f32Value();
    for (&value.angular_velocity) |*component| component.* = try decoder.f32Value();
    for (&value.wheels) |*wheel| {
        wheel.* = .{
            .spin_phase = try decoder.f32Value(),
            .angular_velocity = try decoder.f32Value(),
            .steer_angle = try decoder.f32Value(),
            .suspension_length = try decoder.f32Value(),
            .has_contact = switch (try decoder.u8Value()) {
                0 => false,
                1 => true,
                else => return error.InvalidBoolean,
            },
        };
    }
    value.driver = switch (try decoder.u8Value()) {
        0 => null,
        1 => try decodeParticipant(decoder),
        else => return error.InvalidBoolean,
    };
    return value;
}

fn encodeCarryable(encoder: *Encoder, value: CarryableState) !void {
    try encodeReplicatedEntity(encoder, value.entity);
    for (value.position) |component| try encoder.f32Value(component);
    for (value.rotation) |component| try encoder.f32Value(component);
    for (value.linear_velocity) |component| try encoder.f32Value(component);
    for (value.angular_velocity) |component| try encoder.f32Value(component);
    for (value.half_extents) |component| try encoder.f32Value(component);
    try encoder.u8Value(@intFromBool(value.holder != null));
    if (value.holder) |holder| try encodeParticipant(encoder, holder);
}

fn decodeCarryable(decoder: *Decoder) !CarryableState {
    var value = CarryableState{
        .entity = try decodeReplicatedEntity(decoder),
        .position = undefined,
        .rotation = undefined,
        .linear_velocity = undefined,
        .angular_velocity = undefined,
        .half_extents = undefined,
        .holder = null,
    };
    for (&value.position) |*component| component.* = try decoder.f32Value();
    for (&value.rotation) |*component| component.* = try decoder.f32Value();
    for (&value.linear_velocity) |*component| component.* = try decoder.f32Value();
    for (&value.angular_velocity) |*component| component.* = try decoder.f32Value();
    for (&value.half_extents) |*component| component.* = try decoder.f32Value();
    value.holder = switch (try decoder.u8Value()) {
        0 => null,
        1 => try decodeParticipant(decoder),
        else => return error.InvalidBoolean,
    };
    return value;
}

fn encodeNpc(encoder: *Encoder, value: NpcState) !void {
    try encodeReplicatedEntity(encoder, value.entity);
    for (value.position) |component| try encoder.f32Value(component);
    for (value.velocity) |component| try encoder.f32Value(component);
    try encoder.f32Value(value.facing_yaw);
    try encoder.u8Value(@intFromEnum(value.state));
    try encoder.u16Value(value.incarnation);
    try encoder.u16Value(value.health);
    try encoder.u16Value(value.maximum_health);
    try encoder.u8Value(@intFromEnum(value.life_state));
    try encoder.u8Value(@intFromEnum(value.encounter_state));
    try encoder.u64Value(value.encounter_state_enter_tick);
    try encoder.u64Value(value.attack_impact_tick);
    try encoder.u64Value(value.attack_ready_tick);
    try encoder.u16Value(value.population_member);
    try encoder.u8Value(@intFromEnum(value.population_role));
    try encoder.u8Value(@intFromEnum(value.combat_disposition));
    try encoder.u8Value(@intFromEnum(value.activity_kind));
    try encoder.u8Value(@intFromEnum(value.activity_state));
}

fn decodeNpc(decoder: *Decoder) !NpcState {
    var value = NpcState{
        .entity = try decodeReplicatedEntity(decoder),
        .position = undefined,
        .velocity = undefined,
        .facing_yaw = undefined,
        .state = undefined,
        .incarnation = 0,
        .health = 0,
        .maximum_health = 0,
        .life_state = undefined,
        .encounter_state = undefined,
        .encounter_state_enter_tick = 0,
        .attack_impact_tick = 0,
        .attack_ready_tick = 0,
        .population_member = 0,
        .population_role = .unassigned,
        .combat_disposition = .unassigned,
        .activity_kind = .none,
        .activity_state = .unassigned,
    };
    for (&value.position) |*component| component.* = try decoder.f32Value();
    for (&value.velocity) |*component| component.* = try decoder.f32Value();
    value.facing_yaw = try decoder.f32Value();
    value.state = enumFromInt(
        NpcPresentationState,
        try decoder.u8Value(),
    ) catch return error.InvalidEnum;
    value.incarnation = try decoder.u16Value();
    value.health = try decoder.u16Value();
    value.maximum_health = try decoder.u16Value();
    value.life_state = enumFromInt(
        AvatarLifeState,
        try decoder.u8Value(),
    ) catch return error.InvalidEnum;
    value.encounter_state = enumFromInt(
        NpcEncounterState,
        try decoder.u8Value(),
    ) catch return error.InvalidEnum;
    value.encounter_state_enter_tick = try decoder.u64Value();
    value.attack_impact_tick = try decoder.u64Value();
    value.attack_ready_tick = try decoder.u64Value();
    value.population_member = try decoder.u16Value();
    value.population_role = enumFromInt(
        NpcPopulationRole,
        try decoder.u8Value(),
    ) catch return error.InvalidEnum;
    value.combat_disposition = enumFromInt(
        NpcCombatDisposition,
        try decoder.u8Value(),
    ) catch return error.InvalidEnum;
    value.activity_kind = enumFromInt(
        NpcActivityKind,
        try decoder.u8Value(),
    ) catch return error.InvalidEnum;
    value.activity_state = enumFromInt(
        NpcActivityState,
        try decoder.u8Value(),
    ) catch return error.InvalidEnum;
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

fn expectSnapshotEqual(expected: Snapshot, actual: Snapshot) !void {
    try std.testing.expectEqual(expected.kind, actual.kind);
    try std.testing.expectEqual(expected.baseline_id, actual.baseline_id);
    try std.testing.expectEqual(expected.base_sequence, actual.base_sequence);
    try std.testing.expectEqual(expected.sequence, actual.sequence);
    try std.testing.expectEqual(expected.server_tick, actual.server_tick);
    try std.testing.expectEqual(expected.acknowledged_input, actual.acknowledged_input);
    try std.testing.expectEqual(expected.npc_update, actual.npc_update);
    try std.testing.expectEqual(expected.character_count, actual.character_count);
    try std.testing.expectEqual(expected.vehicle_count, actual.vehicle_count);
    try std.testing.expectEqual(expected.carryable_count, actual.carryable_count);
    try std.testing.expectEqual(expected.npc_count, actual.npc_count);
    try std.testing.expectEqual(expected.removed_character_count, actual.removed_character_count);
    try std.testing.expectEqual(expected.removed_vehicle_count, actual.removed_vehicle_count);
    try std.testing.expectEqual(expected.removed_carryable_count, actual.removed_carryable_count);
    try std.testing.expectEqual(expected.removed_npc_count, actual.removed_npc_count);
    try std.testing.expectEqualDeep(expected.slice(), actual.slice());
    try std.testing.expectEqualDeep(expected.vehicleSlice(), actual.vehicleSlice());
    try std.testing.expectEqualDeep(expected.carryableSlice(), actual.carryableSlice());
    try std.testing.expectEqualDeep(expected.npcSlice(), actual.npcSlice());
    try std.testing.expectEqualDeep(
        expected.removed_characters[0..expected.removed_character_count],
        actual.removed_characters[0..actual.removed_character_count],
    );
    try std.testing.expectEqualDeep(
        expected.removed_vehicles[0..expected.removed_vehicle_count],
        actual.removed_vehicles[0..actual.removed_vehicle_count],
    );
    try std.testing.expectEqualDeep(
        expected.removed_carryables[0..expected.removed_carryable_count],
        actual.removed_carryables[0..actual.removed_carryable_count],
    );
    try std.testing.expectEqualDeep(
        expected.removed_npcs[0..expected.removed_npc_count],
        actual.removed_npcs[0..actual.removed_npc_count],
    );
}

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
    snapshot.carryable_count = budgets.max_carryables;
    snapshot.npc_update = true;
    snapshot.npc_count = budgets.max_npcs;
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
        for (&vehicle.wheels, 0..) |*wheel, wheel_index| {
            wheel.* = .{
                .spin_phase = @as(f32, @floatFromInt(wheel_index)) * 0.75,
                .angular_velocity = @as(f32, @floatFromInt(wheel_index + 1)) * 8,
                .steer_angle = if (wheel_index < 2) 0.2 else 0,
                .suspension_length = 0.2 +
                    @as(f32, @floatFromInt(wheel_index)) * 0.05,
                .has_contact = wheel_index % 2 == 0,
            };
        }
    }
    for (snapshot.carryables[0..snapshot.carryable_count], 0..) |*carryable, index| {
        carryable.* = .{
            .entity = .{
                .index = @intCast(budgets.max_participants + budgets.max_vehicles + index + 1),
                .generation = 1,
            },
            .position = .{ @floatFromInt(index), 0.5, -1 },
            .rotation = .{ 0, 0, 0, 1 },
            .linear_velocity = .{ 0, 0, 0 },
            .angular_velocity = .{ 0, 0, 0 },
            .half_extents = .{ 0.35, 0.35, 0.35 },
            .holder = if (index == 0) .{ .index = 1, .generation = 1 } else null,
        };
    }
    for (snapshot.npcs[0..snapshot.npc_count], 0..) |*npc, index| {
        npc.* = .{
            .entity = .{ .index = @intCast(1_000 + index), .generation = 1 },
            .position = .{ @floatFromInt(index), 0, 0 },
            .velocity = .{ 0, 0, 0 },
            .facing_yaw = 0,
            .state = .active,
        };
    }
    var bytes: [budgets.max_snapshot_bytes]u8 = undefined;
    const encoded = try encodeServer(.{ .snapshot = snapshot }, &bytes);
    try std.testing.expect(encoded.len <= budgets.max_snapshot_bytes);
    const decoded = try decodeServer(encoded);
    switch (decoded) {
        .snapshot => |actual| try expectSnapshotEqual(snapshot, actual),
        else => return error.UnexpectedServerMessage,
    }
}

test "district baseline and acknowledgement round trip as bounded control messages" {
    var snapshot = Snapshot.empty();
    snapshot.baseline_id = 7;
    snapshot.sequence.value = 9;
    snapshot.server_tick = 27;
    var baseline = RelevanceBaseline{
        .baseline_id = 7,
        .district_count = 1,
        .snapshot = snapshot,
    };
    baseline.districts[0] = .{ .x = -2, .z = 3 };
    var storage: [budgets.max_wire_message_bytes]u8 = undefined;
    const encoded = try encodeServer(.{ .relevance_baseline = baseline }, &storage);
    switch (try decodeServer(encoded)) {
        .relevance_baseline => |actual| {
            try std.testing.expectEqual(baseline.baseline_id, actual.baseline_id);
            try std.testing.expectEqual(baseline.district_count, actual.district_count);
            try std.testing.expectEqualDeep(baseline.districtSlice(), actual.districtSlice());
            try expectSnapshotEqual(baseline.snapshot, actual.snapshot);
        },
        else => return error.UnexpectedServerMessage,
    }

    const ack = ClientMessage{ .baseline_ack = .{
        .session = .{ .value = 1 },
        .participant = .{ .index = 1, .generation = 2 },
        .baseline_id = 7,
    } };
    const ack_bytes = try encodeClient(ack, &storage);
    try std.testing.expectEqualDeep(ack, try decodeClient(ack_bytes));
}

test "server semantic validation is shared by typed and encoded messages" {
    var invalid = Snapshot.empty();
    invalid.sequence.value = 1;
    invalid.npc_count = 1;
    const message = ServerMessage{ .snapshot = invalid };
    try std.testing.expectError(error.InvalidNpcProjection, validateServer(message));

    var storage: [budgets.max_wire_message_bytes]u8 = undefined;
    try std.testing.expectError(
        error.InvalidNpcProjection,
        encodeServer(message, &storage),
    );
}

test "client action semantic validation reserves sequence zero" {
    const messages = [_]ClientMessage{
        .{ .vehicle_action = .{
            .session = .{ .value = 9 },
            .participant = .{ .index = 2, .generation = 3 },
            .sequence = .{ .value = 0 },
            .vehicle = .{ .index = 17, .generation = 1 },
            .kind = .enter,
        } },
        .{ .interaction_action = .{
            .session = .{ .value = 9 },
            .participant = .{ .index = 2, .generation = 3 },
            .sequence = .{ .value = 0 },
            .carryable = .{ .index = 21, .generation = 1 },
            .kind = .collect,
        } },
        .{ .melee_action = .{
            .session = .{ .value = 9 },
            .participant = .{ .index = 2, .generation = 3 },
            .sequence = .{ .value = 0 },
            .avatar_incarnation = 3,
            .target_tick = 42,
        } },
        .{ .respawn_action = .{
            .session = .{ .value = 9 },
            .participant = .{ .index = 2, .generation = 3 },
            .sequence = .{ .value = 0 },
            .dead_incarnation = 3,
        } },
    };
    var storage: [256]u8 = undefined;
    for (messages) |message| {
        try std.testing.expectError(
            error.InvalidActionSequence,
            validateClient(message),
        );
        try std.testing.expectError(
            error.InvalidActionSequence,
            encodeClient(message, &storage),
        );

        // Model an untrusted peer that did not use the validating encoder.
        var encoder = Encoder.init(&storage);
        switch (message) {
            .vehicle_action => |action| {
                try encoder.header(.client, @intFromEnum(ClientKind.vehicle_action));
                try encodeVehicleAction(&encoder, action);
            },
            .interaction_action => |action| {
                try encoder.header(.client, @intFromEnum(ClientKind.interaction_action));
                try encodeInteractionAction(&encoder, action);
            },
            .melee_action => |action| {
                try encoder.header(.client, @intFromEnum(ClientKind.melee_action));
                try encoder.u64Value(action.session.value);
                try encodeParticipant(&encoder, action.participant);
                try encoder.u32Value(action.sequence.value);
                try encoder.u16Value(action.avatar_incarnation);
                try encoder.u64Value(action.target_tick);
            },
            .respawn_action => |action| {
                try encoder.header(.client, @intFromEnum(ClientKind.respawn_action));
                try encoder.u64Value(action.session.value);
                try encodeParticipant(&encoder, action.participant);
                try encoder.u32Value(action.sequence.value);
                try encoder.u16Value(action.dead_incarnation);
            },
            else => unreachable,
        }
        try std.testing.expectError(
            error.InvalidActionSequence,
            decodeClient(try encoder.finish()),
        );
    }
}

test "snapshot validation rejects zero sequence and invalid physical projection" {
    var storage: [budgets.max_wire_message_bytes]u8 = undefined;
    var snapshot = Snapshot.empty();
    try std.testing.expectError(
        error.InvalidSnapshotSequence,
        validateServer(.{ .snapshot = snapshot }),
    );
    try std.testing.expectError(
        error.InvalidSnapshotSequence,
        encodeServer(.{ .snapshot = snapshot }, &storage),
    );

    snapshot.sequence.value = 1;
    snapshot.vehicle_count = 1;
    snapshot.vehicles[0] = .{
        .entity = .{ .index = 17, .generation = 1 },
        .position = .{ 0, 1, 0 },
        .rotation = .{ 0, 0, 0, 0 },
        .linear_velocity = .{ 0, 0, 0 },
        .angular_velocity = .{ 0, 0, 0 },
        .driver = null,
    };
    try std.testing.expectError(
        error.DegenerateQuaternion,
        validateServer(.{ .snapshot = snapshot }),
    );

    snapshot.vehicles[0].rotation = .{ 0, 0, 0, 1 };
    snapshot.vehicles[0].wheels[0].spin_phase = std.math.tau;
    try std.testing.expectError(
        error.NonCanonicalVehicleWheelPhase,
        validateServer(.{ .snapshot = snapshot }),
    );
    try std.testing.expectError(
        error.NonCanonicalVehicleWheelPhase,
        encodeServer(.{ .snapshot = snapshot }, &storage),
    );
    snapshot.vehicles[0].wheels[0].spin_phase = 0;
    snapshot.vehicles[0].wheels[0].suspension_length = -0.01;
    try std.testing.expectError(
        error.InvalidVehicleWheelSuspension,
        validateServer(.{ .snapshot = snapshot }),
    );
    snapshot.vehicles[0].wheels[0].suspension_length = 0;
    snapshot.vehicles[0].wheels[0].angular_velocity =
        max_vehicle_wheel_angular_velocity + 1;
    try std.testing.expectError(
        error.VehicleWheelAngularVelocityOutOfRange,
        validateServer(.{ .snapshot = snapshot }),
    );
    snapshot.vehicles[0].wheels[0].angular_velocity = 0;
    snapshot.vehicles[0].wheels[0].steer_angle = max_vehicle_wheel_steer_angle;
    try std.testing.expectError(
        error.VehicleWheelSteerAngleOutOfRange,
        validateServer(.{ .snapshot = snapshot }),
    );
    snapshot.vehicles[0].wheels[0].steer_angle = 0;
    snapshot.vehicles[0].wheels[0].suspension_length =
        max_vehicle_wheel_suspension_length + 1;
    try std.testing.expectError(
        error.InvalidVehicleWheelSuspension,
        validateServer(.{ .snapshot = snapshot }),
    );

    snapshot.vehicle_count = 0;
    snapshot.carryable_count = 1;
    snapshot.carryables[0] = .{
        .entity = .{ .index = 21, .generation = 1 },
        .position = .{ 0, 0.5, 0 },
        .rotation = .{ 0, 0, 0, 1 },
        .linear_velocity = .{ 0, 0, 0 },
        .angular_velocity = .{ 0, 0, 0 },
        .half_extents = .{ 0.25, 0, 0.25 },
        .holder = null,
    };
    try std.testing.expectError(
        error.InvalidCarryableExtents,
        validateServer(.{ .snapshot = snapshot }),
    );
    try std.testing.expectError(
        error.InvalidCarryableExtents,
        encodeServer(.{ .snapshot = snapshot }, &storage),
    );

    snapshot.carryables[0].half_extents = .{ 0.25, 0.25, 0.25 };
    snapshot.carryables[0].rotation = .{ 0, 0, 0, 0 };
    try std.testing.expectError(
        error.DegenerateQuaternion,
        validateServer(.{ .snapshot = snapshot }),
    );
}

test "action result validation rejects dispositions impossible for their action" {
    const vehicle = identity.ReplicatedEntityId{ .index = 17, .generation = 1 };
    var storage: [budgets.max_wire_message_bytes]u8 = undefined;
    var vehicle_result = VehicleActionResult{
        .sequence = .{ .value = 1 },
        .vehicle = vehicle,
        .action = .enter,
        .disposition = .exited,
    };
    try std.testing.expectError(
        error.InvalidVehicleActionResultDisposition,
        validateServer(.{ .vehicle_action_result = vehicle_result }),
    );
    try std.testing.expectError(
        error.InvalidVehicleActionResultDisposition,
        encodeServer(.{ .vehicle_action_result = vehicle_result }, &storage),
    );
    vehicle_result.disposition = .exit_blocked;
    try std.testing.expectError(
        error.InvalidVehicleActionResultDisposition,
        validateServer(.{ .vehicle_action_result = vehicle_result }),
    );
    vehicle_result.disposition = .too_far;
    try validateServer(.{ .vehicle_action_result = vehicle_result });
    vehicle_result.action = .exit;
    try std.testing.expectError(
        error.InvalidVehicleActionResultDisposition,
        validateServer(.{ .vehicle_action_result = vehicle_result }),
    );

    var interaction_result = InteractionActionResult{
        .sequence = .{ .value = 1 },
        .carryable = .{ .index = 21, .generation = 1 },
        .action = .collect,
        .disposition = .dropped,
    };
    try std.testing.expectError(
        error.InvalidInteractionActionResultDisposition,
        validateServer(.{ .interaction_action_result = interaction_result }),
    );
    interaction_result.disposition = .too_far;
    try validateServer(.{ .interaction_action_result = interaction_result });
    interaction_result.action = .drop;
    try std.testing.expectError(
        error.InvalidInteractionActionResultDisposition,
        validateServer(.{ .interaction_action_result = interaction_result }),
    );
}

test "server validation rejects globally duplicate active projection identities" {
    const duplicate = identity.ReplicatedEntityId{ .index = 7, .generation = 1 };
    var snapshot = Snapshot.empty();
    snapshot.sequence.value = 1;
    snapshot.character_count = 1;
    snapshot.characters[0] = .{
        .entity = duplicate,
        .owner = .{ .index = 1, .generation = 1 },
        .position = .{ 0, 0, 0 },
        .velocity = .{ 0, 0, 0 },
        .facing_yaw = 0,
    };
    snapshot.vehicle_count = 1;
    snapshot.vehicles[0] = .{
        .entity = duplicate,
        .position = .{ 0, 1, 0 },
        .rotation = .{ 0, 0, 0, 1 },
        .linear_velocity = .{ 0, 0, 0 },
        .angular_velocity = .{ 0, 0, 0 },
        .driver = null,
    };
    const message = ServerMessage{ .snapshot = snapshot };
    try std.testing.expectError(
        error.DuplicateActiveProjectionEntity,
        validateServer(message),
    );

    var storage: [budgets.max_wire_message_bytes]u8 = undefined;
    try std.testing.expectError(
        error.DuplicateActiveProjectionEntity,
        encodeServer(message, &storage),
    );
}

test "delta validation rejects duplicate removals and conflicting identity edits" {
    const entity = identity.ReplicatedEntityId{ .index = 9, .generation = 1 };
    var delta = Snapshot.empty();
    delta.kind = .delta;
    delta.baseline_id = 1;
    delta.base_sequence.value = 1;
    delta.sequence.value = 2;
    delta.character_count = 1;
    delta.characters[0] = .{
        .entity = entity,
        .owner = .{ .index = 1, .generation = 1 },
        .position = .{ 0, 0, 0 },
        .velocity = .{ 0, 0, 0 },
        .facing_yaw = 0,
    };
    delta.removed_character_count = 1;
    delta.removed_characters[0] = entity;
    try std.testing.expectError(
        error.ConflictingProjectionEntityChange,
        validateServer(.{ .snapshot = delta }),
    );
    var storage: [budgets.max_wire_message_bytes]u8 = undefined;
    try std.testing.expectError(
        error.ConflictingProjectionEntityChange,
        encodeServer(.{ .snapshot = delta }, &storage),
    );

    delta.character_count = 0;
    delta.removed_vehicle_count = 1;
    delta.removed_vehicles[0] = entity;
    try std.testing.expectError(
        error.DuplicateRemovedProjectionEntity,
        validateServer(.{ .snapshot = delta }),
    );
}

test "materialization rejects a delta identity collision with an unchanged lane" {
    const entity = identity.ReplicatedEntityId{ .index = 11, .generation = 1 };
    var base = Snapshot.empty();
    base.baseline_id = 1;
    base.sequence.value = 1;
    base.vehicle_count = 1;
    base.vehicles[0] = .{
        .entity = entity,
        .position = .{ 0, 1, 0 },
        .rotation = .{ 0, 0, 0, 1 },
        .linear_velocity = .{ 0, 0, 0 },
        .angular_velocity = .{ 0, 0, 0 },
        .driver = null,
    };

    var delta = Snapshot.empty();
    delta.kind = .delta;
    delta.baseline_id = base.baseline_id;
    delta.base_sequence = base.sequence;
    delta.sequence.value = 2;
    delta.character_count = 1;
    delta.characters[0] = .{
        .entity = entity,
        .owner = .{ .index = 1, .generation = 1 },
        .position = .{ 0, 0, 0 },
        .velocity = .{ 0, 0, 0 },
        .facing_yaw = 0,
    };
    try validateServer(.{ .snapshot = delta });
    try std.testing.expectError(
        error.DuplicateActiveProjectionEntity,
        materializeDelta(base, delta),
    );
}

test "acknowledged delta materializes updates removals and retained NPC state" {
    var base = Snapshot.empty();
    base.baseline_id = 1;
    base.sequence.value = 10;
    base.npc_update = true;
    base.character_count = 1;
    base.characters[0] = .{
        .entity = .{ .index = 1, .generation = 1 },
        .owner = .{ .index = 1, .generation = 1 },
        .position = .{ 0, 0, 0 },
        .velocity = .{ 0, 0, 0 },
        .facing_yaw = 0,
    };
    base.npc_count = 1;
    base.npcs[0] = .{
        .entity = .{ .index = 100, .generation = 1 },
        .position = .{ 1, 0, 0 },
        .velocity = .{ 0, 0, 0 },
        .facing_yaw = 0,
        .state = .active,
    };
    var current = base;
    current.sequence.value = 11;
    current.character_count = 0;
    current.vehicle_count = 1;
    current.vehicles[0] = .{
        .entity = .{ .index = 20, .generation = 1 },
        .position = .{ 2, 1, 0 },
        .rotation = .{ 0, 0, 0, 1 },
        .linear_velocity = .{ 0, 0, 0 },
        .angular_velocity = .{ 0, 0, 0 },
        .driver = null,
    };
    current.vehicles[0].wheels[0] = .{
        .spin_phase = 5.75,
        .angular_velocity = 72,
        .steer_angle = 0.35,
        .suspension_length = 0.27,
        .has_contact = true,
    };
    const delta = try makeDelta(base, current, false);
    try std.testing.expectEqual(SnapshotKind.delta, delta.kind);
    try std.testing.expectEqual(@as(u8, 1), delta.removed_character_count);
    try std.testing.expectEqual(@as(u8, 1), delta.vehicle_count);
    try std.testing.expect(!delta.npc_update);
    const materialized = try materializeDelta(base, delta);
    try std.testing.expectEqual(@as(u8, 0), materialized.character_count);
    try std.testing.expectEqual(@as(u8, 1), materialized.vehicle_count);
    try std.testing.expectEqualDeep(current.vehicles[0], materialized.vehicles[0]);
    try std.testing.expectEqual(@as(u8, 1), materialized.npc_count);
    try std.testing.expectEqual(current.sequence, materialized.sequence);
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

test "interaction action and result round trip with explicit ownership semantics" {
    var bytes: [256]u8 = undefined;
    const action = ClientMessage{ .interaction_action = .{
        .session = .{ .value = 9 },
        .participant = .{ .index = 2, .generation = 3 },
        .sequence = .{ .value = 8 },
        .carryable = .{ .index = 21, .generation = 1 },
        .kind = .collect,
    } };
    try std.testing.expectEqualDeep(action, try decodeClient(try encodeClient(action, &bytes)));

    const result = ServerMessage{ .interaction_action_result = .{
        .sequence = .{ .value = 8 },
        .carryable = .{ .index = 21, .generation = 1 },
        .action = .collect,
        .disposition = .collected,
    } };
    try std.testing.expectEqualDeep(result, try decodeServer(try encodeServer(result, &bytes)));
}

test "melee respawn and life messages preserve avatar incarnation" {
    var bytes: [256]u8 = undefined;
    const melee = ClientMessage{ .melee_action = .{
        .session = .{ .value = 9 },
        .participant = .{ .index = 2, .generation = 3 },
        .sequence = .{ .value = 11 },
        .avatar_incarnation = 7,
        .target_tick = 42,
    } };
    try std.testing.expectEqualDeep(melee, try decodeClient(try encodeClient(melee, &bytes)));
    const respawn = ClientMessage{ .respawn_action = .{
        .session = .{ .value = 9 },
        .participant = .{ .index = 2, .generation = 3 },
        .sequence = .{ .value = 12 },
        .dead_incarnation = 7,
    } };
    try std.testing.expectEqualDeep(respawn, try decodeClient(try encodeClient(respawn, &bytes)));
    const hit = ServerMessage{ .melee_action_result = .{
        .sequence = .{ .value = 11 },
        .disposition = .hit,
        .target = .{ .index = 4, .generation = 7 },
        .target_incarnation = 7,
        .applied_damage = 34,
        .remaining_health = 66,
    } };
    try std.testing.expectEqualDeep(hit, try decodeServer(try encodeServer(hit, &bytes)));
    const replaced = ServerMessage{ .respawn_action_result = .{
        .sequence = .{ .value = 12 },
        .disposition = .respawned,
        .avatar = .{ .index = 4, .generation = 8 },
        .incarnation = 8,
    } };
    try std.testing.expectEqualDeep(replaced, try decodeServer(try encodeServer(replaced, &bytes)));
    const death = ServerMessage{ .life_event = .{
        .avatar = .{ .index = 4, .generation = 7 },
        .incarnation = 7,
        .authority_tick = 19,
        .health = 0,
        .maximum_health = 100,
        .state = .dead,
        .instigator = .{ .index = 2, .generation = 3 },
    } };
    try std.testing.expectEqualDeep(death, try decodeServer(try encodeServer(death, &bytes)));
}

test "weapon action result and shot event preserve authoritative evidence" {
    var bytes: [512]u8 = undefined;
    const action = ClientMessage{ .weapon_action = .{
        .session = .{ .value = 9 },
        .participant = .{ .index = 2, .generation = 3 },
        .sequence = .{ .value = 13 },
        .avatar_incarnation = 7,
        .target_tick = 42,
        .kind = .fire,
    } };
    try std.testing.expectEqualDeep(action, try decodeClient(try encodeClient(action, &bytes)));

    const result = ServerMessage{ .weapon_action_result = .{
        .sequence = .{ .value = 13 },
        .authority_tick = 43,
        .action = .fire,
        .disposition = .fired_hit,
        .mode = .equipped,
        .magazine_ammo = 11,
        .reserve_ammo = 36,
        .weapon_ready_tick = 54,
        .reload_complete_tick = 0,
        .target = .{ .index = 4, .generation = 7 },
        .target_incarnation = 7,
        .ray_origin = .{ 1, 1.4, 2 },
        .impact_position = .{ 1, 1.4, -2 },
        .applied_damage = 25,
        .remaining_health = 75,
    } };
    try std.testing.expectEqualDeep(result, try decodeServer(try encodeServer(result, &bytes)));

    const event = ServerMessage{ .shot_event = .{
        .shooter = .{ .index = 2, .generation = 7 },
        .shooter_incarnation = 7,
        .sequence = .{ .value = 13 },
        .authority_tick = 43,
        .disposition = .hit,
        .ray_origin = .{ 1, 1.4, 2 },
        .impact_position = .{ 1, 1.4, -2 },
        .target = .{ .index = 4, .generation = 7 },
        .target_incarnation = 7,
        .applied_damage = 25,
        .remaining_health = 75,
    } };
    try std.testing.expectEqualDeep(event, try decodeServer(try encodeServer(event, &bytes)));

    var invalid = result;
    invalid.weapon_action_result.reload_complete_tick = 1;
    try std.testing.expectError(error.InvalidWeaponProjection, validateServer(invalid));
    try std.testing.expectError(error.InvalidWeaponAction, validateClient(.{ .weapon_action = .{
        .session = .{ .value = 9 },
        .participant = .{ .index = 2, .generation = 3 },
        .sequence = .{ .value = 14 },
        .avatar_incarnation = 0,
        .target_tick = 42,
        .kind = .fire,
    } }));
}

test "snapshot delta carries authoritative health and life changes" {
    var base = Snapshot.empty();
    base.baseline_id = 1;
    base.sequence.value = 1;
    base.character_count = 1;
    base.characters[0] = .{
        .entity = .{ .index = 1, .generation = 4 },
        .owner = .{ .index = 1, .generation = 1 },
        .position = .{ 0, 0, 0 },
        .velocity = .{ 0, 0, 0 },
        .facing_yaw = 0,
        .incarnation = 4,
    };
    var current = base;
    current.sequence.value = 2;
    current.characters[0].health = 0;
    current.characters[0].life_state = .dead;
    const delta = try makeDelta(base, current, true);
    try std.testing.expectEqual(@as(u8, 1), delta.character_count);
    const materialized = try materializeDelta(base, delta);
    try std.testing.expectEqual(@as(u16, 0), materialized.characters[0].health);
    try std.testing.expectEqual(AvatarLifeState.dead, materialized.characters[0].life_state);
    try std.testing.expectEqual(@as(u16, 4), materialized.characters[0].incarnation);
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
