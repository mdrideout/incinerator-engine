//! Embedded-authority composition used by the graphical solo host.
//!
//! The visual host owns this session, not `sandbox_simulation`. Player input
//! crosses the same identity/sequencing/admission contract used by MP2, while
//! editor, persistence, diagnostics, and validation remain explicit local-host
//! capabilities of the embedded authority.

const std = @import("std");
const engine = @import("incinerator_engine");
const sandbox = @import("sandbox_simulation");
const budgets = @import("session_budgets");
const identity = @import("session_identity");
const protocol = @import("session_protocol");
const local_link = @import("session_local_link");
const session_client = @import("session_client");

pub const CharacterConfig = sandbox.CharacterConfig;
pub const ChunkCoord = sandbox.ChunkCoord;
pub const Command = sandbox.Command;
pub const Config = sandbox.Config;
pub const Diagnostics = sandbox.Diagnostics;
pub const InteractionCommand = sandbox.InteractionCommand;
pub const InteractionOutcome = sandbox.InteractionOutcome;
pub const LoadTicket = sandbox.LoadTicket;
pub const NavigationNodeRef = sandbox.NavigationNodeRef;
pub const NpcEvent = sandbox.NpcEvent;
pub const NpcOutcome = sandbox.NpcOutcome;
pub const NpcState = sandbox.NpcState;
pub const PersistentId = sandbox.PersistentId;
pub const RejectionReason = sandbox.RejectionReason;
pub const StaticBox = sandbox.StaticBox;
pub const VehicleCommandRejected = sandbox.VehicleCommandRejected;
pub const VehicleConfig = sandbox.VehicleConfig;
pub const currentSimulationBuildFingerprint = sandbox.currentSimulationBuildFingerprint;
pub const district_presentation_policies = sandbox.district_presentation_policies;
pub const navigation_east_coord = sandbox.navigation_east_coord;
pub const navigation_west_coord = sandbox.navigation_west_coord;
pub const npc_capacity = sandbox.npc_capacity;
pub const proceduralDistrictBuild = sandbox.proceduralDistrictBuild;
pub const snapshot_schema = sandbox.snapshot_schema;
pub const worldConfigFingerprint = sandbox.worldConfigFingerprint;

const State = struct {
    allocator: std.mem.Allocator,
    authority: sandbox.Simulation,
    link: local_link.Link = .{},
    client: session_client.Client,
    local_character: ?sandbox.PersistentId = null,
    last_input: identity.InputSequence = .{ .value = 0 },
    next_snapshot: identity.SnapshotSequence = .{ .value = 1 },
    character_assets: @FieldType(sandbox.CharacterConfig, "assets"),
    character_radius: f32,
    character_half_height: f32,
    character_draws: [budgets.max_participants]sandbox.CharacterDraw = undefined,

    fn establish(self: *State) !void {
        try self.link.sendFromClient(try self.client.begin());
        try self.pumpAuthorityIngress();
        try self.pumpClientIngress();
        if (self.client.state != .joined) return error.LocalSessionAdmissionFailed;
    }

    fn pumpAuthorityIngress(self: *State) !void {
        while (self.link.receiveForAuthority()) |message| switch (message) {
            .hello => |hello| {
                if (hello.protocol != protocol.wire_version) {
                    try self.link.sendFromAuthority(.{ .rejected = .{
                        .reason = .protocol_mismatch,
                    } });
                    continue;
                }
                if (hello.build != protocol.build_cohort) {
                    try self.link.sendFromAuthority(.{ .rejected = .{
                        .reason = .build_mismatch,
                    } });
                    continue;
                }
                if (hello.content != protocol.content_cohort) {
                    try self.link.sendFromAuthority(.{ .rejected = .{
                        .reason = .content_mismatch,
                    } });
                    continue;
                }
                try self.link.sendFromAuthority(.{ .welcome = .{
                    .session = .{ .value = 1 },
                    .participant = .{ .index = 1, .generation = 1 },
                    .connection = .{ .index = 1, .generation = 1 },
                    .reconnect = .{ .high = 1, .low = 1 },
                    .authority_tick = self.authority.tickIndex(),
                } });
            },
            .input => |input| {
                if (!std.meta.eql(input.session, self.client.session) or
                    !std.meta.eql(input.participant, self.client.participant))
                {
                    return error.LocalSessionIdentityMismatch;
                }
                if (!input.sequence.newerThan(self.last_input)) {
                    return error.LocalSessionStaleInput;
                }
                const next_tick = try std.math.add(u64, self.authority.tickIndex(), 1);
                if (input.target_tick != next_tick) return error.LocalSessionInputTickMismatch;
                const character = self.local_character orelse
                    return error.LocalSessionCharacterNotBound;
                try self.authority.submitCharacter(.{ .actions = .{
                    .id = character,
                    .move = input.move,
                    .facing_yaw = input.facing_yaw,
                    .jump_pressed = input.jump_pressed,
                } });
                self.last_input = input.sequence;
            },
            .vehicle_input, .vehicle_action => return error.LocalSessionUnexpectedNetworkVehicleCommand,
            .disconnect => |reason| {
                try self.link.sendFromAuthority(.{ .disconnected = reason });
            },
        };
    }

    fn publishSnapshot(self: *State, force: bool) !void {
        const tick = self.authority.tickIndex();
        if (!force and tick % budgets.ticks_per_snapshot != 0) return;
        var snapshot = protocol.Snapshot.empty();
        snapshot.sequence = self.next_snapshot;
        self.next_snapshot = self.next_snapshot.next();
        snapshot.server_tick = tick;
        snapshot.acknowledged_input = self.last_input;
        if (self.local_character) |character_id| {
            const view = try self.authority.character(character_id);
            snapshot.character_count = 1;
            snapshot.characters[0] = .{
                .entity = .{ .index = 1, .generation = 1 },
                .owner = self.client.participant,
                .position = view.position,
                .velocity = view.velocity,
                .facing_yaw = view.facing_yaw,
            };
        }
        try self.link.sendFromAuthority(.{ .snapshot = snapshot });
    }

    fn pumpClientIngress(self: *State) !void {
        while (self.link.receiveForClient()) |message| try self.client.receive(message);
    }

    fn bindCharacter(self: *State, id: sandbox.PersistentId) !void {
        if (self.local_character != null and !std.meta.eql(self.local_character.?, id)) {
            return error.LocalSessionCharacterAlreadyBound;
        }
        self.local_character = id;
        try self.publishSnapshot(true);
        try self.pumpClientIngress();
    }
};

pub const PlayerInput = struct {
    move: [2]f32,
    facing_yaw: f32,
    jump_pressed: bool,
};

pub const Session = struct {
    state: *State,

    pub fn init(allocator: std.mem.Allocator, config: Config) !Session {
        return initOwned(allocator, config, false);
    }

    pub fn initWithDiagnosticFaultProbe(
        allocator: std.mem.Allocator,
        config: Config,
    ) !Session {
        return initOwned(allocator, config, true);
    }

    fn initOwned(
        allocator: std.mem.Allocator,
        config: Config,
        comptime diagnostic_fault_probe: bool,
    ) !Session {
        const state = try allocator.create(State);
        errdefer allocator.destroy(state);
        const authority = if (diagnostic_fault_probe)
            try sandbox.Simulation.initWithDiagnosticFaultProbe(allocator, config)
        else
            try sandbox.Simulation.init(allocator, config);
        errdefer {
            var owned = authority;
            owned.deinit();
        }
        state.* = .{
            .allocator = allocator,
            .authority = authority,
            .client = try session_client.Client.init(.{ .value = 1 }),
            .character_assets = config.character.assets,
            .character_radius = config.character.radius,
            .character_half_height = config.character.half_height,
        };
        try state.establish();
        return .{ .state = state };
    }

    pub fn deinit(self: *Session) void {
        const state = self.state;
        state.authority.deinit();
        const allocator = state.allocator;
        allocator.destroy(state);
        self.* = undefined;
    }

    pub fn submitPlayerInput(self: *Session, input: PlayerInput) !void {
        const target_tick = try std.math.add(u64, self.tickIndex(), 1);
        try self.state.link.sendFromClient(try self.state.client.input(
            target_tick,
            input.move,
            input.facing_yaw,
            input.jump_pressed,
        ));
    }

    pub fn sessionDiagnostics(self: *const Session) struct {
        client: session_client.Diagnostics,
        link: local_link.Diagnostics,
    } {
        return .{
            .client = self.state.client.diagnostics(),
            .link = self.state.link.diagnostics(),
        };
    }

    pub fn submit(self: *Session, command: Command) !void {
        try self.state.authority.submit(command);
    }
    pub fn submitCharacter(self: *Session, command: sandbox.CharacterCommand) !void {
        try self.state.authority.submitCharacter(command);
    }
    pub fn submitVehicle(self: *Session, command: sandbox.VehicleCommand) !void {
        try self.state.authority.submitVehicle(command);
    }
    pub fn submitDistrict(self: *Session, command: sandbox.DistrictCommand) !void {
        try self.state.authority.submitDistrict(command);
    }
    pub fn submitInteraction(self: *Session, command: InteractionCommand) !void {
        try self.state.authority.submitInteraction(command);
    }
    pub fn submitNpc(self: *Session, command: sandbox.NpcCommand) !void {
        try self.state.authority.submitNpc(command);
    }

    pub fn tick(self: *Session) !void {
        try self.tickObserved(null);
    }
    pub fn tickObserved(self: *Session, observer: ?engine.PhaseObserver) !void {
        try self.state.pumpAuthorityIngress();
        try self.state.authority.tickObserved(observer);
        try self.state.publishSnapshot(false);
        try self.state.pumpClientIngress();
    }

    pub fn pollOutcome(self: *Session) ?sandbox.Outcome {
        return self.state.authority.pollOutcome();
    }
    pub fn pollCharacterOutcome(self: *Session) ?sandbox.CharacterOutcome {
        const outcome = self.state.authority.pollCharacterOutcome() orelse return null;
        switch (outcome) {
            .spawned => |spawned| if (spawned.request_id == 1 and
                self.state.local_character == null)
            {
                self.state.bindCharacter(spawned.id) catch @panic(
                    "failed to bind embedded local-session character",
                );
            },
            else => {},
        }
        return outcome;
    }
    pub fn pollCharacterEvent(self: *Session) ?sandbox.CharacterEvent {
        return self.state.authority.pollCharacterEvent();
    }
    pub fn pollVehicleOutcome(self: *Session) ?sandbox.VehicleOutcome {
        return self.state.authority.pollVehicleOutcome();
    }
    pub fn pollVehicleEvent(self: *Session) ?sandbox.VehicleEvent {
        return self.state.authority.pollVehicleEvent();
    }
    pub fn pollDistrictOutcome(self: *Session) ?sandbox.DistrictOutcome {
        return self.state.authority.pollDistrictOutcome();
    }
    pub fn pollDistrictEvent(self: *Session) ?sandbox.DistrictEvent {
        return self.state.authority.pollDistrictEvent();
    }
    pub fn pollInteractionOutcome(self: *Session) ?sandbox.InteractionOutcome {
        return self.state.authority.pollInteractionOutcome();
    }
    pub fn pollNpcOutcome(self: *Session) ?sandbox.NpcOutcome {
        return self.state.authority.pollNpcOutcome();
    }
    pub fn pollNpcEvent(self: *Session) ?sandbox.NpcEvent {
        return self.state.authority.pollNpcEvent();
    }

    pub fn presentation(self: *Session, alpha: f32) ![]const sandbox.CrateDraw {
        return self.state.authority.presentation(alpha);
    }
    pub fn characterPresentation(
        self: *Session,
        alpha: f32,
    ) ![]const sandbox.CharacterDraw {
        const world = &self.state.client.world;
        for (world.slice(), 0..) |entry, index| {
            const replicated_character = @import("replicated_world").World.interpolate(
                entry,
                alpha,
            );
            const half_yaw = replicated_character.facing_yaw * 0.5;
            self.state.character_draws[index] = .{
                .persistent_id = self.state.local_character orelse
                    return error.LocalSessionCharacterNotBound,
                .pose = .{
                    .position = replicated_character.position,
                    .rotation = .{ 0, @sin(half_yaw), 0, @cos(half_yaw) },
                },
                .radius = self.state.character_radius,
                .half_height = self.state.character_half_height,
                .camera_target = .{
                    replicated_character.position[0],
                    replicated_character.position[1] + self.state.character_half_height +
                        self.state.character_radius,
                    replicated_character.position[2],
                },
                .mesh = self.state.character_assets.mesh,
                .material = self.state.character_assets.material,
            };
        }
        return self.state.character_draws[0..world.character_count];
    }
    pub fn vehiclePresentation(self: *Session, alpha: f32) ![]const sandbox.VehicleDraw {
        return self.state.authority.vehiclePresentation(alpha);
    }
    pub fn districtPresentation(self: *Session) ![]const sandbox.DistrictDraw {
        return self.state.authority.districtPresentation();
    }
    pub fn interactionPresentation(self: *Session) ![]const sandbox.CarryableDraw {
        return self.state.authority.interactionPresentation();
    }
    pub fn npcPresentation(self: *Session, alpha: f32) ![]const sandbox.NpcDraw {
        return self.state.authority.npcPresentation(alpha);
    }

    pub fn extractPhysicsDebug(
        self: *Session,
        config: sandbox.PhysicsDebugConfig,
        storage: *engine.physics_debug.Storage,
    ) !sandbox.PhysicsDebugBatch {
        return self.state.authority.extractPhysicsDebug(config, storage);
    }
    pub fn crate(self: *Session, id: PersistentId) !sandbox.CrateView {
        return self.state.authority.crate(id);
    }
    pub fn character(self: *Session, id: PersistentId) !sandbox.CharacterView {
        return self.state.authority.character(id);
    }
    pub fn vehicle(self: *Session, id: PersistentId) !sandbox.VehicleView {
        return self.state.authority.vehicle(id);
    }
    pub fn carryable(self: *Session, id: PersistentId) !sandbox.CarryableView {
        return self.state.authority.carryable(id);
    }
    pub fn npc(self: *Session, id: PersistentId) !sandbox.NpcView {
        return self.state.authority.npc(id);
    }
    pub fn save(self: *Session, allocator: std.mem.Allocator) ![]u8 {
        return self.state.authority.save(allocator);
    }

    pub fn crateCount(self: *const Session) usize {
        return self.state.authority.crateCount();
    }
    pub fn characterCount(self: *const Session) usize {
        return self.state.authority.characterCount();
    }
    pub fn vehicleCount(self: *const Session) usize {
        return self.state.authority.vehicleCount();
    }
    pub fn districtCount(self: *const Session) usize {
        return self.state.authority.districtCount();
    }
    pub fn interactionCount(self: *const Session) usize {
        return self.state.authority.interactionCount();
    }
    pub fn npcCount(self: *const Session) usize {
        return self.state.authority.npcCount();
    }
    pub fn districtBodyCount(self: *const Session) usize {
        return self.state.authority.districtBodyCount();
    }
    pub fn activeDistrictTicketFor(self: *const Session, coord: ChunkCoord) ?LoadTicket {
        return self.state.authority.activeDistrictTicketFor(coord);
    }
    pub fn districtStateFor(self: *const Session, coord: ChunkCoord) ?sandbox.DistrictStateTag {
        return self.state.authority.districtStateFor(coord);
    }
    pub fn entityCount(self: *const Session) usize {
        return self.state.authority.entityCount();
    }
    pub fn bodyCount(self: *Session) u32 {
        return self.state.authority.bodyCount();
    }
    pub fn tickIndex(self: *const Session) u64 {
        return self.state.authority.tickIndex();
    }
    pub fn diagnostics(self: *Session) Diagnostics {
        return self.state.authority.diagnostics();
    }
    pub fn recordDiagnostic(
        self: *Session,
        entry: engine.runtime.DiagnosticEntry,
    ) engine.runtime.DiagnosticAppendResult {
        return self.state.authority.recordDiagnostic(entry);
    }
    pub fn armDiagnosticFaultProbe(self: *Session) !void {
        try self.state.authority.armDiagnosticFaultProbe();
    }
    pub fn armDiagnosticFreeze(
        self: *Session,
        condition: engine.runtime.DiagnosticFreezeMatch,
    ) void {
        self.state.authority.armDiagnosticFreeze(condition);
    }
    pub fn disarmDiagnosticFreeze(self: *Session) bool {
        return self.state.authority.disarmDiagnosticFreeze();
    }
    pub fn diagnosticJournal(self: *const Session) *const engine.runtime.DiagnosticJournal {
        return self.state.authority.diagnosticJournal();
    }
    pub fn firstFault(self: *const Session) ?engine.runtime.RuntimeFault {
        return self.state.authority.firstFault();
    }
    pub fn resumeDiagnosticCapture(self: *Session) bool {
        return self.state.authority.resumeDiagnosticCapture();
    }
    pub fn clearDiagnostics(self: *Session) void {
        self.state.authority.clearDiagnostics();
    }
};

test "embedded session admits local client and routes sequenced character input" {
    var session = try Session.init(std.testing.allocator, .{
        .namespace = 1,
        .fixed_delta_seconds = 1.0 / @as(f32, @floatFromInt(budgets.authority_tick_hz)),
        .create_ground = true,
        .character = .{ .max_characters = 1 },
    });
    defer session.deinit();
    try session.submitCharacter(.{ .spawn = .{
        .request_id = 1,
        .position = .{ 0, 0, 0 },
    } });
    try session.tick();
    const spawned = session.pollCharacterOutcome().?.spawned;
    try std.testing.expectEqual(@as(u64, 1), spawned.request_id);
    try session.submitPlayerInput(.{
        .move = .{ 0, -1 },
        .facing_yaw = 0,
        .jump_pressed = false,
    });
    try session.tick();
    try std.testing.expect(session.sessionDiagnostics().client.state == .joined);
    try std.testing.expectEqual(@as(u32, 1), session.sessionDiagnostics().client.snapshots_applied);
}
