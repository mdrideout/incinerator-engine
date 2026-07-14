//! In-process client/authority composition for the graphical solo product.
//!
//! This placement deliberately runs the same authoritative session core and
//! client protocol state used by networked play. The in-process link removes
//! byte encoding and sockets only; it does not bypass admission, identity,
//! sequencing, replication, prediction, or gameplay authorization.

const std = @import("std");
const engine = @import("incinerator_engine");
const host_contracts = @import("sandbox_host_contracts");
const crate_contract = @import("crate_contract");
const character_contract = @import("character_contract");
const vehicle_contract = @import("vehicle_contract");
const district_contract = @import("district_feature_contract");
const interaction_contract = @import("interaction_feature_contract");
const npc_contract = @import("npc_contract");
const diagnostics_contract = @import("sandbox_diagnostics_contract");
const budgets = @import("session_budgets");
const identity = @import("session_identity");
const protocol = @import("session_protocol");
const snapshot_source = @import("snapshot_source");
const local_link = @import("session_local_link");
const session_client = @import("session_client");
const replicated_world = @import("replicated_world");
const session_authority = @import("session_authority");
const authority_diagnostics = @import("session_authority_diagnostics");

const local_transport = session_authority.TransportConnection{ .value = 1 };

pub const PlayerInput = struct {
    move: [2]f32,
    facing_yaw: f32,
    jump_pressed: bool,
};

pub const VehicleInput = struct {
    throttle: f32,
    steering: f32,
    brake: f32,
    hand_brake: f32,
};

pub const ReplicatedEntityId = identity.ReplicatedEntityId;
pub const ParticipantId = identity.ParticipantId;
pub const VehicleActionKind = protocol.VehicleActionKind;
pub const VehicleActionDisposition = protocol.VehicleActionDisposition;
pub const InteractionActionKind = protocol.InteractionActionKind;
pub const InteractionActionDisposition = protocol.InteractionActionDisposition;

pub const VehicleActionResult = struct {
    sequence: u32,
    vehicle: ReplicatedEntityId,
    action: VehicleActionKind,
    disposition: VehicleActionDisposition,
};

pub const InteractionActionResult = struct {
    sequence: u32,
    carryable: ReplicatedEntityId,
    action: InteractionActionKind,
    disposition: InteractionActionDisposition,
};

pub const CharacterAdminCommand = union(enum) {
    spawn: character_contract.SpawnCharacter,
    despawn: character_contract.DespawnCharacter,
};

pub const CharacterAdminCommandKind = enum { spawn, despawn };
pub const CharacterAdminRejected = struct {
    command: CharacterAdminCommandKind,
    reason: character_contract.RejectionReason,
    request_id: ?u64 = null,
    id: ?engine.PersistentId = null,
};
pub const CharacterAdminOutcome = union(enum) {
    spawned: character_contract.Spawned,
    despawned: engine.PersistentId,
    rejected: CharacterAdminRejected,
};

pub const VehicleAdminCommand = union(enum) {
    spawn: vehicle_contract.SpawnVehicle,
    despawn: vehicle_contract.DespawnVehicle,
};

pub const VehicleAdminCommandKind = enum { spawn, despawn };
pub const VehicleAdminRejected = struct {
    command: VehicleAdminCommandKind,
    reason: vehicle_contract.RejectionReason,
    request_id: ?u64 = null,
    vehicle_id: ?engine.PersistentId = null,
};
pub const VehicleAdminOutcome = union(enum) {
    spawned: vehicle_contract.Spawned,
    despawned: engine.PersistentId,
    rejected: VehicleAdminRejected,
};

pub const InteractionAdminCommand = union(enum) {
    spawn: interaction_contract.SpawnCarryable,
    despawn: interaction_contract.DespawnCarryable,
};

pub const InteractionAdminCommandKind = enum { spawn, despawn };
pub const InteractionAdminRejected = struct {
    command: InteractionAdminCommandKind,
    reason: interaction_contract.RejectionReason,
    request_id: ?u64 = null,
    carryable_id: ?engine.PersistentId = null,
};
pub const InteractionAdminOutcome = union(enum) {
    spawned: interaction_contract.Spawned,
    despawned: engine.PersistentId,
    rejected: InteractionAdminRejected,
};

/// Client-owned presentation values. Replicated/session identity is retained
/// deliberately: durable PersistentId values belong to authority inspection,
/// authoring, and persistence and are never required to render a client view.
pub const CharacterDraw = struct {
    entity: ReplicatedEntityId,
    owner: ParticipantId,
    local_player: bool,
    pose: engine.physics.Pose,
    radius: f32,
    half_height: f32,
    camera_target: [3]f32,
    mesh: engine.rendering.MeshHandle,
    material: engine.rendering.MaterialHandle,
};

pub const VehicleDraw = struct {
    entity: ReplicatedEntityId,
    driver: ?ParticipantId,
    chassis_pose: engine.physics.Pose,
    chassis_half_extents: [3]f32,
    chassis_mesh: engine.rendering.MeshHandle,
    chassis_material: engine.rendering.MaterialHandle,
    wheels: [engine.physics.vehicle_wheel_count]vehicle_contract.WheelDraw,
};

pub const CarryableDraw = struct {
    entity: ReplicatedEntityId,
    holder: ?ParticipantId,
    pose: engine.physics.Pose,
    half_extents: [3]f32,
};

pub const NpcDraw = struct {
    entity: ReplicatedEntityId,
    pose: engine.physics.Pose,
    state: npc_contract.State,
    radius: f32,
    half_height: f32,
    mesh: engine.rendering.MeshHandle,
    material: engine.rendering.MaterialHandle,
};

pub const TickStage = enum {
    client_ingress,
    authority_tick,
    authority_egress,
    client_delivery,
    acknowledgement_ingress,
};

pub const TickTrace = struct {
    tick: u64 = 0,
    stages: [5]TickStage = @splat(.client_ingress),
    count: u8 = 0,

    fn begin(tick: u64) TickTrace {
        return .{ .tick = tick };
    }

    fn record(self: *TickTrace, stage: TickStage) void {
        std.debug.assert(self.count < self.stages.len);
        self.stages[self.count] = stage;
        self.count += 1;
    }
};

const ProjectionStamp = struct {
    tick: u64,
    npc_update: bool,
};

const ProjectionClock = struct {
    previous_tick: u64 = 0,
    last_tick: u64 = 0,

    fn note(self: *ProjectionClock, tick: u64) void {
        if (tick <= self.last_tick and self.last_tick != 0) return;
        self.previous_tick = self.last_tick;
        self.last_tick = tick;
    }

    fn alpha(
        self: ProjectionClock,
        authority_tick: u64,
        frame_alpha: f32,
        expected_interval: u64,
    ) f32 {
        if (!std.math.isFinite(frame_alpha) or self.last_tick == 0) return 1;
        const elapsed_ticks = authority_tick -| self.last_tick;
        const observed_interval = self.last_tick -| self.previous_tick;
        const interval = @max(
            @as(u64, 1),
            @min(observed_interval, expected_interval),
        );
        const numerator = @as(f32, @floatFromInt(elapsed_ticks)) +
            std.math.clamp(frame_alpha, 0, 1);
        return std.math.clamp(numerator / @as(f32, @floatFromInt(interval)), 0, 1);
    }
};

pub const ClientDiagnostics = struct {
    client: session_client.Diagnostics,
    link: local_link.Diagnostics,
    authority: authority_diagnostics.Diagnostics,
    observations: session_authority.HostObservationDiagnostics,
    last_tick: TickTrace,
};

pub const Composition = struct {
    placement: *Placement,
    snapshot_source: snapshot_source.Source,
};

const State = struct {
    allocator: std.mem.Allocator,
    authority: *session_authority.EmbeddedAuthority,
    link: local_link.Link = .{},
    client: session_client.Client,
    config: host_contracts.Config,
    canonical_snapshot_source: ?snapshot_source.Source = null,
    projection_clock: ProjectionClock = .{},
    npc_projection_clock: ProjectionClock = .{},
    last_tick: TickTrace = .{},
    last_interaction_observation: ?interaction_contract.Outcome = null,
    character_draws: [budgets.max_participants]CharacterDraw = undefined,
    vehicle_draws: [budgets.max_vehicles]VehicleDraw = undefined,
    carryable_draws: [budgets.max_carryables]CarryableDraw = undefined,
    npc_draws: [budgets.max_npcs]NpcDraw = undefined,

    fn establish(self: *State) !void {
        _ = try self.authority.session().openConnection(local_transport);
        try self.link.sendFromClient(try self.client.begin());
        try self.deliverClientIngress();
        try self.deliverAuthorityEgress();
        try self.deliverClientMessages();
        try self.deliverAcknowledgements();
        if (self.client.state != .joined) return error.LocalSessionAdmissionFailed;
    }

    fn deliverClientIngress(self: *State) !void {
        while (self.link.receiveForAuthority()) |message| {
            try self.authority.session().ingest(local_transport, message);
        }
    }

    fn deliverAuthorityEgress(self: *State) !void {
        while (self.authority.session().pollOutbound()) |outbound| {
            if (!std.meta.eql(outbound.connection, local_transport)) {
                return error.UnexpectedLocalTransport;
            }
            try self.link.sendFromAuthority(outbound.message);
            if (outbound.close_after_send) {
                self.authority.session().transportClosed(local_transport);
            }
        }
    }

    fn deliverClientMessages(self: *State) !void {
        while (self.link.receiveForClient()) |message| {
            const projection_stamp: ?ProjectionStamp = switch (message) {
                .snapshot => |snapshot| .{
                    .tick = snapshot.server_tick,
                    .npc_update = snapshot.npc_update,
                },
                .relevance_baseline => |baseline| .{
                    .tick = baseline.snapshot.server_tick,
                    .npc_update = baseline.snapshot.npc_update,
                },
                else => null,
            };
            const applied_before = self.client.diagnostics().snapshots_applied;
            try self.client.receive(message);
            const projection_applied = self.client.diagnostics().snapshots_applied !=
                applied_before;
            if (projection_stamp) |stamp| if (projection_applied) {
                self.projection_clock.note(stamp.tick);
                if (stamp.npc_update) self.npc_projection_clock.note(stamp.tick);
            };
        }
    }

    fn deliverAcknowledgements(self: *State) !void {
        if (self.client.takeBaselineAck()) |message| {
            try self.link.sendFromClient(message);
        }
        if (self.client.takeSnapshotAck()) |message| {
            try self.link.sendFromClient(message);
        }
        try self.deliverClientIngress();
    }

    fn tickObserved(self: *State, observer: ?engine.PhaseObserver) !void {
        self.last_tick = TickTrace.begin(
            try std.math.add(u64, self.authority.inspection().tickIndex(), 1),
        );
        try self.deliverClientIngress();
        self.last_tick.record(.client_ingress);
        try self.authority.session().tickObserved(observer);
        self.last_tick.record(.authority_tick);
        try self.deliverAuthorityEgress();
        self.last_tick.record(.authority_egress);
        try self.deliverClientMessages();
        self.last_tick.record(.client_delivery);
        try self.deliverAcknowledgements();
        self.last_tick.record(.acknowledgement_ingress);
    }

    fn projectionAlpha(self: *const State, frame_alpha: f32) f32 {
        return self.projection_clock.alpha(
            self.authority.inspection().tickIndex(),
            frame_alpha,
            budgets.ticks_per_snapshot,
        );
    }

    fn npcProjectionAlpha(self: *const State, frame_alpha: f32) f32 {
        return self.npc_projection_clock.alpha(
            self.authority.inspection().tickIndex(),
            frame_alpha,
            budgets.ticks_per_npc_snapshot,
        );
    }

    fn submitMovement(self: *State, input: PlayerInput) !void {
        const target_tick = try std.math.add(u64, self.authority.inspection().tickIndex(), 1);
        try self.link.sendFromClient(try self.client.input(
            target_tick,
            input.move,
            input.facing_yaw,
            input.jump_pressed,
        ));
    }

    fn submitVehicleControl(self: *State, input: VehicleInput) !u32 {
        const vehicle = self.client.ownedVehicle() orelse
            return error.VehicleControlUnavailable;
        const target_tick = try std.math.add(u64, self.authority.inspection().tickIndex(), 1);
        const message = try self.client.vehicleInput(
            target_tick,
            vehicle.entity,
            input.throttle,
            input.steering,
            input.brake,
            input.hand_brake,
        );
        try self.link.sendFromClient(message);
        return message.vehicle_input.sequence.value;
    }

    fn requestVehicleToggle(self: *State) !void {
        if (self.client.ownedVehicle()) |vehicle| {
            try self.link.sendFromClient(try self.client.vehicleAction(.exit, vehicle.entity));
            return;
        }
        const position = self.focusPosition() orelse return error.LocalCharacterUnavailable;
        const vehicle = nearestVehicle(
            self.client.world.vehicleSlice(),
            position,
            self.config.vehicle.max_entry_distance,
        ) orelse return error.NoVehicleInRange;
        try self.link.sendFromClient(try self.client.vehicleAction(.enter, vehicle));
    }

    fn requestInteractionToggle(self: *State) !void {
        if (self.client.heldCarryable()) |carryable| {
            try self.link.sendFromClient(try self.client.interactionAction(.drop, carryable.entity));
            return;
        }
        const position = self.focusPosition() orelse return error.LocalCharacterUnavailable;
        const carryable = nearestCarryable(
            self.client.world.carryableSlice(),
            position,
            self.config.interaction.collect_range,
        ) orelse return error.NoCarryableInRange;
        try self.link.sendFromClient(try self.client.interactionAction(.collect, carryable));
    }

    fn requestInteraction(
        self: *State,
        action: InteractionActionKind,
        carryable: ReplicatedEntityId,
    ) !void {
        try self.link.sendFromClient(try self.client.interactionAction(
            action,
            carryable,
        ));
    }

    fn takeVehicleActionResult(self: *State) ?VehicleActionResult {
        const result = self.client.takeVehicleActionResult() orelse return null;
        return .{
            .sequence = result.sequence.value,
            .vehicle = result.vehicle,
            .action = result.action,
            .disposition = result.disposition,
        };
    }

    fn takeInteractionActionResult(self: *State) ?InteractionActionResult {
        const result = self.client.takeInteractionActionResult() orelse return null;
        return .{
            .sequence = result.sequence.value,
            .carryable = result.carryable,
            .action = result.action,
            .disposition = result.disposition,
        };
    }

    fn focusPosition(self: *const State) ?[3]f32 {
        if (self.client.ownedVehicle()) |vehicle| {
            return if (self.client.localVehiclePresentation()) |predicted|
                predicted.position
            else
                vehicle.position;
        }
        if (self.client.localPresentation()) |predicted| return predicted.position;
        for (self.client.world.slice()) |entry| {
            if (std.meta.eql(entry.current.owner, self.client.participant)) {
                return entry.current.position;
            }
        }
        return null;
    }

    fn authoritativeFocusPosition(self: *State) !?[3]f32 {
        return self.authority.residency().authoritativeFocusPosition(
            self.client.participant,
        );
    }

    fn characterPresentation(
        self: *State,
        frame_alpha: f32,
    ) []const CharacterDraw {
        const alpha = self.projectionAlpha(frame_alpha);
        var count: usize = 0;
        for (self.client.world.slice()) |entry| {
            if (participantIsDriving(&self.client.world, entry.current.owner)) continue;
            var character = replicated_world.World.interpolate(entry, alpha);
            if (std.meta.eql(character.owner, self.client.participant)) {
                if (self.client.localPresentation()) |predicted| character = predicted;
            }
            const half_yaw = character.facing_yaw * 0.5;
            self.character_draws[count] = .{
                .entity = character.entity,
                .owner = character.owner,
                .local_player = std.meta.eql(character.owner, self.client.participant),
                .pose = .{
                    .position = character.position,
                    .rotation = .{ 0, @sin(half_yaw), 0, @cos(half_yaw) },
                },
                .radius = self.config.character.radius,
                .half_height = self.config.character.half_height,
                .camera_target = .{
                    character.position[0],
                    character.position[1] + self.config.character.radius +
                        self.config.character.half_height,
                    character.position[2],
                },
                .mesh = self.config.character.assets.mesh,
                .material = self.config.character.assets.material,
            };
            count += 1;
        }
        return self.character_draws[0..count];
    }

    fn vehiclePresentation(
        self: *State,
        frame_alpha: f32,
    ) []const VehicleDraw {
        const alpha = self.projectionAlpha(frame_alpha);
        var count: usize = 0;
        for (self.client.world.vehicleSlice()) |entry| {
            var vehicle = replicated_world.World.interpolateVehicle(entry, alpha);
            if (vehicle.driver) |driver| if (std.meta.eql(driver, self.client.participant)) {
                if (self.client.localVehiclePresentation()) |predicted| vehicle = predicted;
            };
            const chassis_pose = engine.physics.Pose{
                .position = vehicle.position,
                .rotation = vehicle.rotation,
            };
            var wheels: [engine.physics.vehicle_wheel_count]vehicle_contract.WheelDraw = undefined;
            for (&wheels, self.config.vehicle.tuning.wheel_attachment_positions, 0..) |
                *wheel,
                attachment,
                index,
            | {
                var visual_offset = attachment;
                visual_offset[1] -= (self.config.vehicle.tuning.suspension_min_length +
                    self.config.vehicle.tuning.suspension_max_length) * 0.5;
                wheel.* = .{
                    .index = @enumFromInt(index),
                    .pose = localOffsetPose(chassis_pose, visual_offset),
                    .radius = self.config.vehicle.tuning.wheel_radius,
                    .width = self.config.vehicle.tuning.wheel_width,
                    .mesh = self.config.vehicle.assets.wheel_mesh,
                    .material = self.config.vehicle.assets.wheel_material,
                };
            }
            self.vehicle_draws[count] = .{
                .entity = vehicle.entity,
                .driver = vehicle.driver,
                .chassis_pose = chassis_pose,
                .chassis_half_extents = self.config.vehicle.tuning.chassis_half_extents,
                .chassis_mesh = self.config.vehicle.assets.chassis_mesh,
                .chassis_material = self.config.vehicle.assets.chassis_material,
                .wheels = wheels,
            };
            count += 1;
        }
        return self.vehicle_draws[0..count];
    }

    fn carryablePresentation(
        self: *State,
        frame_alpha: f32,
    ) []const CarryableDraw {
        const alpha = self.projectionAlpha(frame_alpha);
        var count: usize = 0;
        for (self.client.world.carryableSlice()) |entry| {
            const carryable = replicated_world.World.interpolateCarryable(entry, alpha);
            self.carryable_draws[count] = .{
                .entity = carryable.entity,
                .holder = carryable.holder,
                .pose = .{
                    .position = carryable.position,
                    .rotation = carryable.rotation,
                },
                .half_extents = carryable.half_extents,
            };
            count += 1;
        }
        return self.carryable_draws[0..count];
    }

    fn npcPresentation(
        self: *State,
        frame_alpha: f32,
    ) []const NpcDraw {
        const alpha = self.npcProjectionAlpha(frame_alpha);
        var count: usize = 0;
        for (self.client.world.npcSlice()) |entry| {
            const npc = replicated_world.World.interpolateNpc(entry, alpha);
            const half_yaw = npc.facing_yaw * 0.5;
            self.npc_draws[count] = .{
                .entity = npc.entity,
                .pose = .{
                    .position = npc.position,
                    .rotation = .{ 0, @sin(half_yaw), 0, @cos(half_yaw) },
                },
                .state = switch (npc.state) {
                    .active => .active,
                    .waiting_at_boundary => .waiting_at_boundary,
                },
                .radius = self.config.npc.radius,
                .half_height = self.config.npc.half_height,
                .mesh = self.config.npc.assets.mesh,
                .material = self.config.npc.assets.material,
            };
            count += 1;
        }
        return self.npc_draws[0..count];
    }

    fn issueSnapshotSource(self: *State) !snapshot_source.Source {
        if (self.canonical_snapshot_source != null) return error.SnapshotSourceAlreadyIssued;
        self.canonical_snapshot_source = try self.authority.persistence().issueSource();
        return .{ .context = self, .capture_fn = captureSnapshot };
    }

    fn operationalQuiescenceReason(self: *const State) ?error{
        SessionWorkPending,
        AuthorityOutputsPending,
    } {
        const link_diagnostics = self.link.diagnostics();
        if (link_diagnostics.client_to_authority_occupancy != 0) {
            return error.SessionWorkPending;
        }
        if (link_diagnostics.authority_to_client_occupancy != 0) {
            return error.AuthorityOutputsPending;
        }
        return null;
    }

    fn captureSnapshot(
        context: *anyopaque,
        allocator: std.mem.Allocator,
    ) anyerror![]u8 {
        const self = stateFrom(context);
        if (self.operationalQuiescenceReason()) |reason| return reason;
        const source = self.canonical_snapshot_source orelse
            return error.SnapshotSourceNotIssued;
        return source.capture(allocator);
    }
};

fn stateFrom(context: *anyopaque) *State {
    return @ptrCast(@alignCast(context));
}

fn stateFromConst(context: *const anyopaque) *const State {
    return @ptrCast(@alignCast(context));
}

pub const Placement = opaque {
    pub fn initComposition(
        allocator: std.mem.Allocator,
        config: host_contracts.Config,
    ) !Composition {
        const placement = try initOwned(allocator, config, false);
        errdefer placement.deinit();
        return .{
            .snapshot_source = try stateFrom(placement).issueSnapshotSource(),
            .placement = placement,
        };
    }

    pub fn initCompositionWithDiagnosticFaultProbe(
        allocator: std.mem.Allocator,
        config: host_contracts.Config,
    ) !Composition {
        const placement = try initOwned(allocator, config, true);
        errdefer placement.deinit();
        return .{
            .snapshot_source = try stateFrom(placement).issueSnapshotSource(),
            .placement = placement,
        };
    }

    pub fn deinit(self: *Placement) void {
        const state = stateFrom(self);
        state.authority.deinit();
        const allocator = state.allocator;
        allocator.destroy(state);
    }

    pub fn player(self: *Placement) PlayerRole {
        return .{ .context = self };
    }

    pub fn presentation(self: *Placement) PresentationRole {
        return .{ .context = self };
    }

    pub fn lifecycle(self: *Placement) LifecycleRole {
        return .{ .context = self };
    }

    pub fn crates(self: *Placement) CrateRole {
        return .{ .context = self };
    }

    pub fn characters(self: *Placement) CharacterRole {
        return .{ .context = self };
    }

    pub fn vehicles(self: *Placement) VehicleRole {
        return .{ .context = self };
    }

    pub fn districts(self: *Placement) DistrictRole {
        return .{ .context = self };
    }

    pub fn interactions(self: *Placement) InteractionRole {
        return .{ .context = self };
    }

    pub fn npcs(self: *Placement) NpcRole {
        return .{ .context = self };
    }

    pub fn developer(self: *Placement) DeveloperRole {
        return .{ .context = self };
    }

    pub fn inspection(self: *const Placement) InspectionRole {
        return .{ .context = self };
    }

    pub fn residency(self: *Placement) ResidencyRole {
        return .{ .context = self };
    }
};

fn initOwned(
    allocator: std.mem.Allocator,
    config: host_contracts.Config,
    comptime diagnostic_fault_probe: bool,
) !*Placement {
    const state = try allocator.create(State);
    errdefer allocator.destroy(state);
    const authority_config = session_authority.CoreConfig{
        .simulation = config,
        .world_bootstrap = .host_managed,
        .participant_spawn = .host_managed,
        .observation = .bounded,
    };
    var authority = if (diagnostic_fault_probe)
        try session_authority.EmbeddedAuthority.initWithDiagnosticFaultProbe(
            allocator,
            authority_config,
        )
    else
        try session_authority.EmbeddedAuthority.init(
            allocator,
            authority_config,
        );
    errdefer authority.deinit();
    state.* = .{
        .allocator = allocator,
        .authority = authority,
        .client = try session_client.Client.init(.{ .value = 1 }),
        .config = config,
    };
    try state.establish();
    return @ptrCast(state);
}

/// Privileged embedded-host value port for canonical district residency.
/// It is intentionally separate from the prediction-facing PlayerRole.
pub const ResidencyRole = struct {
    context: *anyopaque,

    pub fn authoritativeFocusPosition(self: ResidencyRole) !?[3]f32 {
        return stateFrom(self.context).authoritativeFocusPosition();
    }
};

pub const PlayerRole = struct {
    context: *anyopaque,

    pub fn submitMovement(self: PlayerRole, input: PlayerInput) !void {
        try stateFrom(self.context).submitMovement(input);
    }

    pub fn submitVehicleControl(self: PlayerRole, input: VehicleInput) !u32 {
        return stateFrom(self.context).submitVehicleControl(input);
    }

    pub fn requestVehicleToggle(self: PlayerRole) !void {
        try stateFrom(self.context).requestVehicleToggle();
    }

    pub fn requestInteractionToggle(self: PlayerRole) !void {
        try stateFrom(self.context).requestInteractionToggle();
    }

    pub fn requestInteraction(
        self: PlayerRole,
        action: InteractionActionKind,
        carryable: ReplicatedEntityId,
    ) !void {
        try stateFrom(self.context).requestInteraction(action, carryable);
    }

    pub fn pollVehicleActionResult(self: PlayerRole) ?VehicleActionResult {
        return stateFrom(self.context).takeVehicleActionResult();
    }

    pub fn pollInteractionActionResult(self: PlayerRole) ?InteractionActionResult {
        return stateFrom(self.context).takeInteractionActionResult();
    }

    pub fn lastAcknowledgedInput(self: PlayerRole) u32 {
        return stateFromConst(self.context).client.last_acknowledged_input.value;
    }

    pub fn focusPosition(self: PlayerRole) ?[3]f32 {
        return stateFromConst(self.context).focusPosition();
    }
};

pub const PresentationRole = struct {
    context: *anyopaque,

    pub fn characters(self: PresentationRole, alpha: f32) []const CharacterDraw {
        return stateFrom(self.context).characterPresentation(alpha);
    }

    pub fn vehicles(self: PresentationRole, alpha: f32) []const VehicleDraw {
        return stateFrom(self.context).vehiclePresentation(alpha);
    }

    pub fn carryables(self: PresentationRole, alpha: f32) []const CarryableDraw {
        return stateFrom(self.context).carryablePresentation(alpha);
    }

    pub fn npcs(self: PresentationRole, alpha: f32) []const NpcDraw {
        return stateFrom(self.context).npcPresentation(alpha);
    }
};

pub const LifecycleRole = struct {
    context: *anyopaque,

    pub fn tick(self: LifecycleRole) !void {
        try stateFrom(self.context).tickObserved(null);
    }

    pub fn tickObserved(self: LifecycleRole, observer: ?engine.PhaseObserver) !void {
        try stateFrom(self.context).tickObserved(observer);
    }
};

pub const CrateRole = struct {
    context: *anyopaque,

    pub fn submit(self: CrateRole, command: crate_contract.Command) !void {
        try stateFrom(self.context).authority.crates().submit(command);
    }

    pub fn pollOutcome(self: CrateRole) ?crate_contract.Outcome {
        return stateFrom(self.context).authority.crates().pollOutcome();
    }

    pub fn presentation(self: CrateRole, alpha: f32) ![]const crate_contract.CrateDraw {
        return stateFrom(self.context).authority.crates().presentation(alpha);
    }

    pub fn view(self: CrateRole, id: engine.PersistentId) !crate_contract.CrateView {
        return stateFrom(self.context).authority.crates().view(id);
    }

    pub fn count(self: CrateRole) usize {
        return stateFromConst(self.context).authority.crates().count();
    }
};

pub const CharacterRole = struct {
    context: *anyopaque,

    pub fn submit(self: CharacterRole, command: CharacterAdminCommand) !void {
        const state = stateFrom(self.context);
        switch (command) {
            .spawn => |spawn| try state.authority.characters().spawnParticipant(
                local_transport,
                spawn,
            ),
            .despawn => |despawn| try state.authority.characters().despawnParticipant(
                local_transport,
                despawn.id,
            ),
        }
    }

    pub fn pollOutcome(self: CharacterRole) ?CharacterAdminOutcome {
        while (stateFrom(self.context).authority.characters().pollOutcome()) |outcome| {
            switch (outcome) {
                .spawned => |value| return .{ .spawned = value },
                .despawned => |value| return .{ .despawned = value },
                .rejected => |rejected| switch (rejected.command) {
                    .spawn => return .{ .rejected = .{
                        .command = .spawn,
                        .reason = rejected.reason,
                        .request_id = rejected.request_id,
                        .id = rejected.id,
                    } },
                    .despawn => return .{ .rejected = .{
                        .command = .despawn,
                        .reason = rejected.reason,
                        .request_id = rejected.request_id,
                        .id = rejected.id,
                    } },
                    .actions => continue,
                },
            }
        }
        return null;
    }

    pub fn pollEvent(self: CharacterRole) ?character_contract.Event {
        return stateFrom(self.context).authority.characters().pollEvent();
    }

    pub fn view(self: CharacterRole, id: engine.PersistentId) !character_contract.CharacterView {
        return stateFrom(self.context).authority.characters().view(id);
    }

    pub fn count(self: CharacterRole) usize {
        return stateFromConst(self.context).authority.characters().count();
    }
};

pub const VehicleRole = struct {
    context: *anyopaque,

    pub fn submit(self: VehicleRole, command: VehicleAdminCommand) !void {
        try stateFrom(self.context).authority.vehicles().submit(switch (command) {
            .spawn => |value| .{ .spawn = value },
            .despawn => |value| .{ .despawn = value },
        });
    }

    pub fn pollOutcome(self: VehicleRole) ?VehicleAdminOutcome {
        while (stateFrom(self.context).authority.vehicles().pollOutcome()) |outcome| {
            switch (outcome) {
                .spawned => |value| return .{ .spawned = value },
                .despawned => |value| return .{ .despawned = value },
                .rejected => |rejected| switch (rejected.command) {
                    .spawn => return .{ .rejected = .{
                        .command = .spawn,
                        .reason = rejected.reason,
                        .request_id = rejected.request_id,
                        .vehicle_id = rejected.vehicle_id,
                    } },
                    .despawn => return .{ .rejected = .{
                        .command = .despawn,
                        .reason = rejected.reason,
                        .request_id = rejected.request_id,
                        .vehicle_id = rejected.vehicle_id,
                    } },
                    .enter, .drive, .exit, .abandon => continue,
                },
                .entered, .drive_applied, .exited, .abandoned => continue,
            }
        }
        return null;
    }

    pub fn pollEvent(self: VehicleRole) ?vehicle_contract.Event {
        return stateFrom(self.context).authority.vehicles().pollEvent();
    }

    pub fn view(self: VehicleRole, id: engine.PersistentId) !vehicle_contract.VehicleView {
        return stateFrom(self.context).authority.vehicles().view(id);
    }

    pub fn count(self: VehicleRole) usize {
        return stateFromConst(self.context).authority.vehicles().count();
    }
};

pub const DistrictRole = struct {
    context: *anyopaque,

    pub fn submit(self: DistrictRole, command: district_contract.Command) !void {
        try stateFrom(self.context).authority.districts().submit(command);
    }

    pub fn pollOutcome(self: DistrictRole) ?district_contract.Outcome {
        return stateFrom(self.context).authority.districts().pollOutcome();
    }

    pub fn pollEvent(self: DistrictRole) ?district_contract.Event {
        return stateFrom(self.context).authority.districts().pollEvent();
    }

    pub fn presentation(self: DistrictRole) ![]const district_contract.DistrictDraw {
        return stateFrom(self.context).authority.districts().presentation();
    }

    pub fn count(self: DistrictRole) usize {
        return stateFromConst(self.context).authority.districts().count();
    }

    pub fn bodyCount(self: DistrictRole) usize {
        return stateFromConst(self.context).authority.districts().bodyCount();
    }

    pub fn activeTicket(
        self: DistrictRole,
        coord: host_contracts.ChunkCoord,
    ) ?host_contracts.LoadTicket {
        return stateFromConst(self.context).authority.districts().activeTicket(coord);
    }

    pub fn state(
        self: DistrictRole,
        coord: host_contracts.ChunkCoord,
    ) ?district_contract.StateTag {
        return stateFromConst(self.context).authority.districts().state(coord);
    }
};

pub const InteractionRole = struct {
    context: *anyopaque,

    pub fn submit(self: InteractionRole, command: InteractionAdminCommand) !void {
        try stateFrom(self.context).authority.interactions().submit(switch (command) {
            .spawn => |value| .{ .spawn = value },
            .despawn => |value| .{ .despawn = value },
        });
    }

    pub fn pollOutcome(self: InteractionRole) ?InteractionAdminOutcome {
        const state = stateFrom(self.context);
        while (state.authority.interactions().pollOutcome()) |outcome| {
            state.last_interaction_observation = outcome;
            switch (outcome) {
                .spawned => |value| return .{ .spawned = value },
                .despawned => |value| return .{ .despawned = value },
                .rejected => |rejected| switch (rejected.command) {
                    .spawn => return .{ .rejected = .{
                        .command = .spawn,
                        .reason = rejected.reason,
                        .request_id = rejected.request_id,
                        .carryable_id = rejected.carryable_id,
                    } },
                    .despawn => return .{ .rejected = .{
                        .command = .despawn,
                        .reason = rejected.reason,
                        .request_id = rejected.request_id,
                        .carryable_id = rejected.carryable_id,
                    } },
                    .collect, .drop => continue,
                },
                .collected, .dropped => continue,
            }
        }
        return null;
    }

    pub fn view(
        self: InteractionRole,
        id: engine.PersistentId,
    ) !interaction_contract.CarryableView {
        return stateFrom(self.context).authority.interactions().view(id);
    }

    pub fn count(self: InteractionRole) usize {
        return stateFromConst(self.context).authority.interactions().count();
    }
};

pub const NpcRole = struct {
    context: *anyopaque,

    pub fn submit(self: NpcRole, command: npc_contract.Command) !void {
        try stateFrom(self.context).authority.npcs().submit(command);
    }

    pub fn pollOutcome(self: NpcRole) ?npc_contract.Outcome {
        return stateFrom(self.context).authority.npcs().pollOutcome();
    }

    pub fn pollEvent(self: NpcRole) ?npc_contract.Event {
        return stateFrom(self.context).authority.npcs().pollEvent();
    }

    pub fn view(self: NpcRole, id: engine.PersistentId) !npc_contract.NpcView {
        return stateFrom(self.context).authority.npcs().view(id);
    }

    pub fn count(self: NpcRole) usize {
        return stateFromConst(self.context).authority.npcs().count();
    }
};

pub const DeveloperRole = struct {
    context: *anyopaque,

    pub fn diagnostics(self: DeveloperRole) diagnostics_contract.Diagnostics {
        return stateFrom(self.context).authority.developer().diagnostics();
    }

    /// Retained authority observation for developer tooling only. Product
    /// action handling consumes PlayerRole results instead.
    pub fn lastInteractionObservation(
        self: DeveloperRole,
    ) ?interaction_contract.Outcome {
        return stateFromConst(self.context).last_interaction_observation;
    }

    pub fn record(
        self: DeveloperRole,
        entry: engine.runtime.DiagnosticEntry,
    ) engine.runtime.DiagnosticAppendResult {
        return stateFrom(self.context).authority.developer().record(entry);
    }

    pub fn armFaultProbe(self: DeveloperRole) !void {
        try stateFrom(self.context).authority.developer().armFaultProbe();
    }

    pub fn armFreeze(
        self: DeveloperRole,
        condition: engine.runtime.DiagnosticFreezeMatch,
    ) void {
        stateFrom(self.context).authority.developer().armFreeze(condition);
    }

    pub fn disarmFreeze(self: DeveloperRole) bool {
        return stateFrom(self.context).authority.developer().disarmFreeze();
    }

    pub fn journal(self: DeveloperRole) *const engine.runtime.DiagnosticJournal {
        return stateFrom(self.context).authority.developer().journal();
    }

    pub fn firstFault(self: DeveloperRole) ?engine.runtime.RuntimeFault {
        return stateFrom(self.context).authority.developer().firstFault();
    }

    pub fn resumeCapture(self: DeveloperRole) bool {
        return stateFrom(self.context).authority.developer().resumeCapture();
    }

    pub fn clear(self: DeveloperRole) void {
        stateFrom(self.context).authority.developer().clear();
    }

    pub fn extractPhysicsDebug(
        self: DeveloperRole,
        config: engine.physics_debug.Config,
        storage: *engine.physics_debug.Storage,
    ) !engine.physics_debug.Batch {
        return stateFrom(self.context).authority.developer().extractPhysicsDebug(config, storage);
    }
};

pub const InspectionRole = struct {
    context: *const anyopaque,

    pub fn tickIndex(self: InspectionRole) u64 {
        return stateFromConst(self.context).authority.inspection().tickIndex();
    }

    pub fn entityCount(self: InspectionRole) usize {
        return stateFromConst(self.context).authority.inspection().entityCount();
    }

    pub fn bodyCount(self: InspectionRole) u32 {
        return stateFromConst(self.context).authority.inspection().bodyCount();
    }

    pub fn persistenceCohort(self: InspectionRole) session_authority.PersistenceCohort {
        return stateFromConst(self.context).authority.inspection().persistenceCohort();
    }

    /// Privileged host/validation identity lookup. Replicated presentation
    /// values never call this path.
    pub fn replicatedId(
        self: InspectionRole,
        persistent: engine.PersistentId,
    ) ?ReplicatedEntityId {
        return stateFromConst(self.context).authority.inspection().replicatedId(
            persistent,
        );
    }

    pub fn clientDiagnostics(self: InspectionRole) ClientDiagnostics {
        const state = stateFromConst(self.context);
        return .{
            .client = state.client.diagnostics(),
            .link = state.link.diagnostics(),
            .authority = state.authority.session().diagnostics(),
            .observations = state.authority.inspection().observationDiagnostics(),
            .last_tick = state.last_tick,
        };
    }
};

fn participantIsDriving(world: *const replicated_world.World, participant: identity.ParticipantId) bool {
    for (world.vehicleSlice()) |entry| {
        if (entry.current.driver) |driver| {
            if (std.meta.eql(driver, participant)) return true;
        }
    }
    return false;
}

fn nearestVehicle(
    entries: []const replicated_world.VehicleEntry,
    position: [3]f32,
    maximum_distance: f32,
) ?identity.ReplicatedEntityId {
    var result: ?identity.ReplicatedEntityId = null;
    var best_distance_squared = @as(f64, maximum_distance) * maximum_distance;
    for (entries) |entry| {
        if (entry.current.driver != null) continue;
        const distance_squared = distanceSquared(position, entry.current.position);
        if (distance_squared > best_distance_squared) continue;
        if (distance_squared < best_distance_squared or result == null or
            replicatedIdLessThan(entry.current.entity, result.?))
        {
            result = entry.current.entity;
            best_distance_squared = distance_squared;
        }
    }
    return result;
}

fn nearestCarryable(
    entries: []const replicated_world.CarryableEntry,
    position: [3]f32,
    maximum_distance: f32,
) ?identity.ReplicatedEntityId {
    var result: ?identity.ReplicatedEntityId = null;
    var best_distance_squared = @as(f64, maximum_distance) * maximum_distance;
    for (entries) |entry| {
        if (entry.current.holder != null) continue;
        const distance_squared = distanceSquared(position, entry.current.position);
        if (distance_squared > best_distance_squared) continue;
        if (distance_squared < best_distance_squared or result == null or
            replicatedIdLessThan(entry.current.entity, result.?))
        {
            result = entry.current.entity;
            best_distance_squared = distance_squared;
        }
    }
    return result;
}

fn replicatedIdLessThan(
    lhs: identity.ReplicatedEntityId,
    rhs: identity.ReplicatedEntityId,
) bool {
    return lhs.index < rhs.index or
        (lhs.index == rhs.index and lhs.generation < rhs.generation);
}

fn distanceSquared(a: [3]f32, b: [3]f32) f64 {
    var result: f64 = 0;
    for (a, b) |lhs, rhs| {
        const delta = @as(f64, lhs) - @as(f64, rhs);
        result += delta * delta;
    }
    return result;
}

fn localOffsetPose(chassis: engine.physics.Pose, offset: [3]f32) engine.physics.Pose {
    const rotated = rotateVector(chassis.rotation, offset);
    return .{
        .position = .{
            chassis.position[0] + rotated[0],
            chassis.position[1] + rotated[1],
            chassis.position[2] + rotated[2],
        },
        .rotation = chassis.rotation,
    };
}

fn rotateVector(q: [4]f32, value: [3]f32) [3]f32 {
    const qv = [3]f32{ q[0], q[1], q[2] };
    const first = cross(qv, value);
    const doubled = [3]f32{ first[0] * 2, first[1] * 2, first[2] * 2 };
    const second = cross(qv, doubled);
    return .{
        value[0] + doubled[0] * q[3] + second[0],
        value[1] + doubled[1] * q[3] + second[1],
        value[2] + doubled[2] * q[3] + second[2],
    };
}

fn cross(a: [3]f32, b: [3]f32) [3]f32 {
    return .{
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    };
}

test "public solo handles are opaque and role scoped" {
    switch (@typeInfo(Placement)) {
        .@"opaque" => {},
        else => return error.SoloPlacementMustRemainOpaque,
    }
    try std.testing.expect(!@hasDecl(Placement, "init"));
    try std.testing.expect(!@hasDecl(Placement, "initWithDiagnosticFaultProbe"));
    try std.testing.expect(!@hasDecl(Placement, "submit"));
    try std.testing.expect(!@hasDecl(Placement, "tick"));
    inline for (.{
        PlayerRole,
        PresentationRole,
        LifecycleRole,
        CrateRole,
        CharacterRole,
        VehicleRole,
        DistrictRole,
        InteractionRole,
        NpcRole,
        DeveloperRole,
        InspectionRole,
    }) |Role| {
        try std.testing.expect(@hasField(Role, "context"));
        try std.testing.expect(!@hasField(Role, "state"));
    }
    inline for (.{ CharacterDraw, VehicleDraw, CarryableDraw, NpcDraw }) |Draw| {
        try std.testing.expect(!@hasField(Draw, "persistent_id"));
        try std.testing.expect(@hasField(Draw, "entity"));
    }
    try std.testing.expect(!@hasField(CharacterAdminCommand, "actions"));
    try std.testing.expect(!@hasField(VehicleAdminCommand, "enter"));
    try std.testing.expect(!@hasField(VehicleAdminCommand, "drive"));
    try std.testing.expect(!@hasField(VehicleAdminCommand, "exit"));
    try std.testing.expect(!@hasField(VehicleAdminCommand, "abandon"));
    try std.testing.expect(!@hasField(InteractionAdminCommand, "collect"));
    try std.testing.expect(!@hasField(InteractionAdminCommand, "drop"));
}

test "solo placement joins shared authority and applies replicated movement" {
    const placement = try initOwned(std.testing.allocator, testConfig(0x4c4f_4301), false);
    defer placement.deinit();
    try placement.characters().submit(.{ .spawn = .{
        .request_id = 1,
        .position = .{ 0, 0, 0 },
    } });
    try placement.lifecycle().tick();
    const spawned = placement.characters().pollOutcome().?.spawned;
    try std.testing.expectEqual(@as(u64, 1), spawned.request_id);
    try placement.player().submitMovement(.{
        .move = .{ 0, -1 },
        .facing_yaw = 0,
        .jump_pressed = false,
    });
    try placement.lifecycle().tick();
    try placement.lifecycle().tick();
    const diagnostics = placement.inspection().clientDiagnostics();
    try std.testing.expectEqual(session_client.State.joined, diagnostics.client.state);
    try std.testing.expect(diagnostics.client.snapshots_applied > 0);
    try std.testing.expectEqual(@as(u32, 0), diagnostics.link.client_to_authority_occupancy);
    try std.testing.expectEqual(@as(u32, 0), diagnostics.link.authority_to_client_occupancy);
    try std.testing.expectEqual(@as(u8, 5), diagnostics.last_tick.count);
    try std.testing.expectEqualSlices(TickStage, &.{
        .client_ingress,
        .authority_tick,
        .authority_egress,
        .client_delivery,
        .acknowledgement_ingress,
    }, diagnostics.last_tick.stages[0..diagnostics.last_tick.count]);
    try std.testing.expectEqual(@as(u8, 4), diagnostics.authority.last_cycle.count);
    try std.testing.expectEqualSlices(
        authority_diagnostics.CycleStage,
        &.{ .pre_simulation, .simulation, .outcome_drain, .replication_extraction },
        diagnostics.authority.last_cycle.stages[0..diagnostics.authority.last_cycle.count],
    );
    try std.testing.expect(diagnostics.authority.first_cycle_fault == null);
    const draws = placement.presentation().characters(0.5);
    try std.testing.expectEqual(@as(usize, 1), draws.len);
    try std.testing.expect(draws[0].local_player);
    try std.testing.expectEqual(
        placement.inspection().replicatedId(spawned.id).?,
        draws[0].entity,
    );
}

test "solo vehicle actions and control use shared authority admission" {
    const placement = try initOwned(std.testing.allocator, testConfig(0x4c4f_4302), false);
    defer placement.deinit();
    try placement.characters().submit(.{ .spawn = .{
        .request_id = 1,
        .position = .{ 0, 0, 0 },
    } });
    try placement.vehicles().submit(.{ .spawn = .{
        .request_id = 2,
        .chassis = .{ .pose = .{ .position = .{ 0, 1, 0 } } },
    } });
    try placement.lifecycle().tick();
    _ = placement.characters().pollOutcome() orelse return error.MissingCharacterOutcome;
    const vehicle_id = (placement.vehicles().pollOutcome() orelse
        return error.MissingVehicleOutcome).spawned.id;

    try placement.player().requestVehicleToggle();
    try placement.lifecycle().tick();
    try std.testing.expect(placement.vehicles().pollOutcome() == null);
    const entered = placement.player().pollVehicleActionResult() orelse
        return error.MissingVehicleEnterOutcome;
    try std.testing.expectEqual(VehicleActionDisposition.entered, entered.disposition);
    try std.testing.expectEqual(
        placement.inspection().replicatedId(vehicle_id).?,
        entered.vehicle,
    );
    const input_sequence = try placement.player().submitVehicleControl(.{
        .throttle = 1,
        .steering = 0.25,
        .brake = 0,
        .hand_brake = 0,
    });
    try placement.lifecycle().tick();
    try std.testing.expect(placement.vehicles().pollOutcome() == null);
    const diagnostics = placement.inspection().clientDiagnostics();
    try std.testing.expectEqual(@as(u64, 1), diagnostics.client.vehicle_actions_accepted);
    try std.testing.expect(diagnostics.authority.vehicle_actions_accepted >= 1);
    try std.testing.expect(diagnostics.authority.accepted_messages >= 4);
    try std.testing.expect(diagnostics.client.last_acknowledged_input.value >= input_sequence);
    const draws = placement.presentation().vehicles(0.5);
    try std.testing.expectEqual(@as(usize, 1), draws.len);
    try std.testing.expectEqual(entered.vehicle, draws[0].entity);
}

test "host character teardown retains the admitted local participant" {
    const placement = try initOwned(std.testing.allocator, testConfig(0x4c4f_4305), false);
    defer placement.deinit();
    try placement.characters().submit(.{ .spawn = .{
        .request_id = 1,
        .position = .{ 0, 0, 0 },
    } });
    try placement.lifecycle().tick();
    const first = (placement.characters().pollOutcome() orelse
        return error.MissingCharacterOutcome).spawned.id;
    try placement.characters().submit(.{ .despawn = .{ .id = first } });
    try placement.lifecycle().tick();
    try std.testing.expectEqual(
        first,
        (placement.characters().pollOutcome() orelse
            return error.MissingCharacterDespawnOutcome).despawned,
    );
    try std.testing.expectEqual(
        session_client.State.joined,
        placement.inspection().clientDiagnostics().client.state,
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        placement.presentation().characters(1).len,
    );
    try placement.characters().submit(.{ .spawn = .{
        .request_id = 2,
        .position = .{ 1, 0, 0 },
    } });
    try placement.lifecycle().tick();
    const second = (placement.characters().pollOutcome() orelse
        return error.MissingCharacterRespawnOutcome).spawned;
    try std.testing.expectEqual(@as(u64, 2), second.request_id);
    try std.testing.expect(!std.meta.eql(first, second.id));
}

test "solo carry collect and drop use shared authority admission" {
    const placement = try initOwned(std.testing.allocator, testConfig(0x4c4f_4306), false);
    defer placement.deinit();
    try placement.characters().submit(.{ .spawn = .{
        .request_id = 1,
        .position = .{ 0, 0, 0 },
    } });
    try placement.districts().submit(.{ .request_load = .{
        .request_id = 2,
        .coord = host_contracts.navigation_west_coord,
        .assets = .{},
    } });
    var requested_ticket: ?host_contracts.LoadTicket = null;
    var district_active = false;
    for (0..10_000) |_| {
        // District preparation is intentionally asynchronous. Yield before
        // pumping the shared authority so readiness is bounded by semantic
        // worker progress rather than by how quickly this test burns CPU.
        std.Thread.yield() catch {};
        try placement.lifecycle().tick();
        while (placement.districts().pollOutcome()) |outcome| switch (outcome) {
            .load_requested => |requested| {
                if (requested.request_id != 2 or
                    !host_contracts.ChunkCoord.eql(
                        requested.ticket.coord,
                        host_contracts.navigation_west_coord,
                    ) or requested_ticket != null)
                {
                    return error.UnexpectedDistrictLoadRequest;
                }
                requested_ticket = requested.ticket;
            },
            .activated => |activated| {
                const expected = requested_ticket orelse
                    return error.DistrictActivatedBeforeLoadRequest;
                if (activated.request_id != 2 or
                    !host_contracts.LoadTicket.eql(expected, activated.ticket) or
                    !host_contracts.ChunkCoord.eql(
                        activated.coord,
                        host_contracts.navigation_west_coord,
                    ))
                {
                    return error.UnexpectedDistrictActivation;
                }
                district_active = true;
            },
            .load_failed => return error.DistrictLoadFailed,
            .rejected => return error.DistrictLoadRejected,
            .cancelled => return error.DistrictLoadCancelled,
            .cancellation_requested, .unloaded => {
                return error.UnexpectedDistrictLoadOutcome;
            },
        };
        while (placement.districts().pollEvent()) |_| {}
        if (district_active) break;
    }
    if (!district_active) return error.SoloDistrictActivationTimeout;
    _ = (placement.characters().pollOutcome() orelse
        return error.MissingCharacterOutcome).spawned.id;
    while (placement.characters().pollEvent()) |_| {}

    try placement.interactions().submit(.{ .spawn = .{
        .request_id = 3,
        .pose = .{ .position = .{ 0, 0.5, 0 } },
    } });
    try placement.lifecycle().tick();
    const carryable_id = (placement.interactions().pollOutcome() orelse
        return error.MissingCarryableOutcome).spawned.id;
    try placement.player().requestInteractionToggle();
    try placement.lifecycle().tick();
    try std.testing.expect(placement.interactions().pollOutcome() == null);
    const collected = placement.player().pollInteractionActionResult() orelse
        return error.MissingCollectOutcome;
    try std.testing.expectEqual(InteractionActionDisposition.collected, collected.disposition);
    try std.testing.expectEqual(
        placement.inspection().replicatedId(carryable_id).?,
        collected.carryable,
    );
    try placement.player().requestInteractionToggle();
    try placement.lifecycle().tick();
    try std.testing.expect(placement.interactions().pollOutcome() == null);
    const dropped = placement.player().pollInteractionActionResult() orelse
        return error.MissingDropOutcome;
    try std.testing.expectEqual(InteractionActionDisposition.dropped, dropped.disposition);
    try std.testing.expectEqual(collected.carryable, dropped.carryable);
    const diagnostics = placement.inspection().clientDiagnostics();
    try std.testing.expectEqual(@as(u64, 2), diagnostics.client.interaction_actions_accepted);
    try std.testing.expectEqual(@as(u64, 2), diagnostics.authority.interaction_actions_accepted);
}

test "solo replication remains twenty hertz on the sixty hertz authority clock" {
    const placement = try initOwned(std.testing.allocator, testConfig(0x4c4f_4303), false);
    defer placement.deinit();
    try placement.characters().submit(.{ .spawn = .{
        .request_id = 1,
        .position = .{ 0, 0, 0 },
    } });
    try placement.lifecycle().tick();
    _ = placement.characters().pollOutcome() orelse return error.MissingCharacterOutcome;
    // Let the join baseline acknowledgement and its forced follow-up snapshot
    // settle, then measure from a normal replication boundary.
    try placement.lifecycle().tick();
    try placement.lifecycle().tick();
    const before = placement.inspection().clientDiagnostics();
    const before_tick = placement.inspection().tickIndex();
    for (0..budgets.authority_tick_hz * 2) |_| try placement.lifecycle().tick();
    const after = placement.inspection().clientDiagnostics();
    try std.testing.expectEqual(
        before_tick + budgets.authority_tick_hz * 2,
        after.last_tick.tick,
    );
    try std.testing.expectEqual(
        @as(u64, budgets.snapshot_hz * 2),
        after.client.snapshots_applied - before.client.snapshots_applied,
    );
    try std.testing.expectEqual(
        @as(u64, budgets.snapshot_hz * 2),
        after.authority.snapshots_emitted - before.authority.snapshots_emitted,
    );
}

test "composition transfers one quiescence-checked snapshot source" {
    const composition = try Placement.initComposition(
        std.testing.allocator,
        testConfig(0x4c4f_4304),
    );
    defer composition.placement.deinit();
    const bytes = try composition.snapshot_source.capture(std.testing.allocator);
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(bytes.len > 0);

    const state = stateFrom(composition.placement);
    try state.link.sendFromClient(.{ .disconnect = .requested });
    try std.testing.expectError(
        error.SessionWorkPending,
        composition.snapshot_source.capture(std.testing.allocator),
    );
}

test "persistence rejects admitted input that has not reached its target tick" {
    const composition = try Placement.initComposition(
        std.testing.allocator,
        testConfig(0x4c4f_4307),
    );
    defer composition.placement.deinit();
    try composition.placement.characters().submit(.{ .spawn = .{
        .request_id = 1,
        .position = .{ 0, 0, 0 },
    } });
    try composition.placement.lifecycle().tick();
    _ = composition.placement.characters().pollOutcome() orelse
        return error.MissingCharacterOutcome;
    while (composition.placement.characters().pollEvent()) |_| {}
    try composition.placement.player().submitMovement(.{
        .move = .{ 0, -1 },
        .facing_yaw = 0,
        .jump_pressed = false,
    });
    const state = stateFrom(composition.placement);
    try state.deliverClientIngress();
    try std.testing.expectError(
        error.SessionWorkPending,
        composition.snapshot_source.capture(std.testing.allocator),
    );

    // The held sample remains available for the declared input-hold policy,
    // but once its target tick has completed it is no longer pending durable
    // authority work.
    try composition.placement.lifecycle().tick();
    while (composition.placement.characters().pollOutcome()) |_| {}
    while (composition.placement.characters().pollEvent()) |_| {}
    const bytes = try composition.snapshot_source.capture(std.testing.allocator);
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(bytes.len > 0);
}

test "failed local authority tick records only successfully completed stages" {
    const placement = try initOwned(
        std.testing.allocator,
        testConfig(0x4c4f_4308),
        true,
    );
    defer placement.deinit();
    try placement.developer().armFaultProbe();
    try std.testing.expectError(
        error.InjectedDeveloperDiagnosticFault,
        placement.lifecycle().tick(),
    );
    var diagnostics = placement.inspection().clientDiagnostics();
    const trace = diagnostics.last_tick;
    try std.testing.expectEqual(@as(u8, 1), trace.count);
    try std.testing.expectEqual(TickStage.client_ingress, trace.stages[0]);
    try std.testing.expectEqual(
        authority_diagnostics.CycleStage.simulation,
        diagnostics.authority.last_cycle.failed_stage.?,
    );
    try std.testing.expectEqual(@as(u8, 1), diagnostics.authority.last_cycle.count);
    try std.testing.expectEqual(
        authority_diagnostics.CycleStage.pre_simulation,
        diagnostics.authority.last_cycle.stages[0],
    );
    const first_fault = diagnostics.authority.first_cycle_fault orelse
        return error.MissingAuthorityCycleFault;
    try std.testing.expectEqual(
        @intFromError(error.InjectedDeveloperDiagnosticFault),
        first_fault.error_code,
    );

    try std.testing.expectError(error.AuthorityFaulted, placement.lifecycle().tick());
    diagnostics = placement.inspection().clientDiagnostics();
    try std.testing.expectEqual(@as(u64, 0), diagnostics.authority.tick);
    try std.testing.expectEqual(
        first_fault.error_code,
        diagnostics.authority.first_cycle_fault.?.error_code,
    );
}

test "npc interpolation clock advances only with npc-bearing snapshots" {
    var projection_clock = ProjectionClock{};
    var npc_clock = ProjectionClock{};
    projection_clock.note(6);
    npc_clock.note(6);

    // A normal 20 Hz projection at tick 9 omitted the 10 Hz NPC lane.
    projection_clock.note(9);
    try std.testing.expectEqual(@as(u64, 9), projection_clock.last_tick);
    try std.testing.expectEqual(@as(u64, 6), npc_clock.last_tick);
    try std.testing.expectApproxEqAbs(
        @as(f32, 0.5),
        npc_clock.alpha(9, 0, budgets.ticks_per_npc_snapshot),
        0.0001,
    );

    npc_clock.note(12);
    try std.testing.expectEqual(@as(u64, 12), npc_clock.last_tick);
    try std.testing.expectEqual(@as(u64, 6), npc_clock.previous_tick);
}

test "ignored snapshots do not advance local interpolation clocks" {
    const placement = try initOwned(std.testing.allocator, testConfig(0x4c4f_4309), false);
    defer placement.deinit();
    try placement.characters().submit(.{ .spawn = .{
        .request_id = 1,
        .position = .{ 0, 0, 0 },
    } });
    try placement.lifecycle().tick();
    _ = placement.characters().pollOutcome() orelse return error.MissingCharacterOutcome;

    const state = stateFrom(placement);
    const projection_tick = state.projection_clock.last_tick;
    const npc_projection_tick = state.npc_projection_clock.last_tick;
    const history_index = (@as(usize, state.client.snapshot_history_next) +
        state.client.snapshot_history.len - 1) % state.client.snapshot_history.len;
    var stale = state.client.snapshot_history[history_index].snapshot;
    stale.sequence = state.client.world.sequence;
    stale.server_tick = projection_tick + 100;
    stale.npc_update = true;
    try state.link.sendFromAuthority(.{ .snapshot = stale });
    try state.deliverClientMessages();
    try std.testing.expectEqual(projection_tick, state.projection_clock.last_tick);
    try std.testing.expectEqual(npc_projection_tick, state.npc_projection_clock.last_tick);
}

test "nearest replicated target selection is deterministic" {
    const farther = identity.ReplicatedEntityId{ .index = 9, .generation = 1 };
    const lower_id = identity.ReplicatedEntityId{ .index = 2, .generation = 1 };
    var vehicles: [2]replicated_world.VehicleEntry = undefined;
    vehicles[0] = repeatedVehicle(farther, .{ 1, 0, 0 });
    vehicles[1] = repeatedVehicle(lower_id, .{ -1, 0, 0 });
    try std.testing.expectEqual(lower_id, nearestVehicle(&vehicles, .{ 0, 0, 0 }, 2).?);
    try std.testing.expect(nearestVehicle(&vehicles, .{ 0, 0, 0 }, 0.5) == null);
}

fn testConfig(namespace: u64) host_contracts.Config {
    return .{
        .namespace = namespace,
        .fixed_delta_seconds = 1.0 / @as(f32, @floatFromInt(budgets.authority_tick_hz)),
        .create_ground = true,
        .character = .{ .max_characters = 1 },
        .vehicle = .{ .max_vehicles = 1 },
    };
}

fn repeatedVehicle(
    entity: identity.ReplicatedEntityId,
    position: [3]f32,
) replicated_world.VehicleEntry {
    const value = protocol.VehicleState{
        .entity = entity,
        .position = position,
        .rotation = .{ 0, 0, 0, 1 },
        .linear_velocity = .{ 0, 0, 0 },
        .angular_velocity = .{ 0, 0, 0 },
        .driver = null,
    };
    return .{ .previous = value, .current = value };
}
