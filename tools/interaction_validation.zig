//! Deterministic IV5 gameplay journey/fault/fuzz/soak acceptance.
//!
//! This drives the shared hostile-contact scenario through the production
//! session client, dedicated authority, and semantic impaired-link adapter.
//! It is virtual-time and allocation-bounded after owner initialization. Real
//! GNS and graphical listen/dedicated processes remain separate aggregate
//! gate dependencies.

const std = @import("std");
const budgets = @import("session_budgets");
const protocol = @import("session_protocol");
const session_client = @import("session_client");
const authority_module = @import("session_authority");
const impaired = @import("impaired_link");
const gameplay_scenarios = @import("sandbox_gameplay_scenarios");

const scenario = gameplay_scenarios.get(
    .hostile_npc_approach_contact_death_respawn,
);
const settle_ticks: u64 = 600;
const bootstrap_tick_limit: u64 = 10_000;
const ingress_fingerprint_seed: u64 = 0x4d50_3300_0000_0001;

const Profile = enum { clean, nominal, adverse, blackout };

const Invocation = struct {
    profile: Profile = .clean,
    seed: u64 = scenario.seed,
    ticks: u64 = scenario.deadline_ticks,
    fuzz: bool = false,
    reconnect: bool = false,
    repeat: bool = false,
};

const FailureContext = struct {
    tick: u64 = 0,
    authority_tick: u64 = 0,
    client_server_tick: u64 = 0,
    action_fingerprint: u64 = 0,
    joined: bool = false,
    lifecycle_known: bool = false,
    avatar_alive: bool = false,
    character_alive: bool = false,
    avatar_health: u16 = 0,
    avatar_entity_index: u32 = 0,
    avatar_entity_generation: u16 = 0,
    avatar_incarnation: u16 = 0,
    character_entity_index: u32 = 0,
    character_entity_generation: u16 = 0,
    character_incarnation: u16 = 0,
    life_events: u64 = 0,
    respawn_ready_tick: u64 = 0,
    melee_pending: bool = false,
    respawn_pending: bool = false,
    provocation_hit: bool = false,
    player_dead: bool = false,
    player_respawned: bool = false,
    npc_killed: bool = false,
    npc_killed_tick: u64 = 0,
    npc_replaced: bool = false,
    reconnected: bool = false,
};

const Summary = struct {
    ticks: u64,
    action_fingerprint: u64,
    submission_fingerprint: u64,
    outcome_fingerprint: u64,
    ingress_fingerprint: u64,
    player_deaths: u16,
    player_respawns: u16,
    npc_kills: u16,
    npc_replacements: u16,
    reconnects: u64,
    melee_submitted: u64,
    melee_results: u64,
    respawn_submitted: u64,
    respawn_results: u64,
    rejected_actions: u64,
    relevance_transfers: u64,
    link: impaired.Diagnostics,
};

const SplitMix64 = struct {
    state: u64,

    fn next(self: *SplitMix64) u64 {
        self.state +%= 0x9e37_79b9_7f4a_7c15;
        var value = self.state;
        value = (value ^ (value >> 30)) *% 0xbf58_476d_1ce4_e5b9;
        value = (value ^ (value >> 27)) *% 0x94d0_49bb_1331_11eb;
        return value ^ (value >> 31);
    }
};

const Journey = struct {
    const InputIntent = struct {
        move: [2]f32,
        facing_yaw: f32,
        jump: bool,
    };

    rng: SplitMix64,
    action_fingerprint: u64 = 0xcbf2_9ce4_8422_2325,
    submission_fingerprint: u64 = 0x5355_424d_4954_0001,
    outcome_fingerprint: u64 = 0x4f55_5443_4f4d_0001,
    last_input_intent: ?InputIntent = null,
    joined_tick: ?u64 = null,
    provocation_hit: bool = false,
    player_dead: bool = false,
    player_respawned: bool = false,
    player_deaths: u16 = 0,
    player_respawns: u16 = 0,
    npc_killed: bool = false,
    npc_killed_tick: u64 = 0,
    npc_kills: u16 = 0,
    dead_npc_index: u32 = 0,
    dead_npc_generation: u16 = 0,
    npc_replaced: bool = false,
    npc_replacements: u16 = 0,
    reconnect_started: bool = false,
    reconnected: bool = false,
    melee_submitted: u64 = 0,
    melee_results: u64 = 0,
    respawn_submitted: u64 = 0,
    respawn_results: u64 = 0,
    rejected_actions: u64 = 0,

    fn init(seed: u64) Journey {
        return .{ .rng = .{ .state = seed } };
    }

    fn note(self: *Journey, tag: u64, value: u64) void {
        self.action_fingerprint = fingerprintNote(self.action_fingerprint, tag, value);
        const category = switch (tag) {
            0x52_45_43_4f,
            0x49_4e_50_54,
            0x49_4e_50_55,
            0x49_4e_50_59,
            0x49_4e_50_4a,
            0x52_53_50_4e,
            0x4d_45_4c_45,
            => &self.submission_fingerprint,
            0x4d_52_53_4c,
            0x52_52_53_4c,
            0x4c_49_46_45,
            0x4e_50_43_52,
            => &self.outcome_fingerprint,
            else => unreachable,
        };
        category.* = fingerprintNote(category.*, tag, value);
    }

    fn noteInput(self: *Journey, move: [2]f32, facing_yaw: f32, jump: bool) void {
        const next = InputIntent{ .move = move, .facing_yaw = facing_yaw, .jump = jump };
        if (self.last_input_intent) |previous| {
            if (@as(u32, @bitCast(previous.move[0])) == @as(u32, @bitCast(move[0])) and
                @as(u32, @bitCast(previous.move[1])) == @as(u32, @bitCast(move[1])) and
                @as(u32, @bitCast(previous.facing_yaw)) == @as(u32, @bitCast(facing_yaw)) and
                previous.jump == jump)
            {
                return;
            }
        }
        self.last_input_intent = next;
        self.note(0x49_4e_50_54, @as(u32, @bitCast(move[0])));
        self.note(0x49_4e_50_55, @as(u32, @bitCast(move[1])));
        self.note(0x49_4e_50_59, @as(u32, @bitCast(facing_yaw)));
        self.note(0x49_4e_50_4a, @intFromBool(jump));
    }

    fn baseComplete(self: Journey, require_reconnect: bool) bool {
        return self.player_dead and self.player_respawned and self.npc_killed and
            self.npc_replaced and (!require_reconnect or self.reconnected);
    }
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const invocation = try parseInvocation(args);
    if (invocation.ticks < scenario.deadline_ticks or
        invocation.ticks <= settle_ticks)
    {
        return error.InteractionValidationDurationTooShort;
    }
    std.debug.print(
        "IV5_INTERACTION_BEGIN profile={s} seed={d} ticks={d} fuzz={} " ++
            "reconnect={} scenario={s} scenario_seed={x} deadline_ticks={d}\n",
        .{
            @tagName(invocation.profile),
            invocation.seed,
            invocation.ticks,
            invocation.fuzz,
            invocation.reconnect,
            scenario.name,
            scenario.seed,
            scenario.deadline_ticks,
        },
    );

    var failure = FailureContext{};
    const first = runTrial(invocation, &failure) catch |err| {
        writeFailureArtifact(init.io, invocation, failure, err) catch |artifact_err| {
            std.debug.print("IV5_ARTIFACT_WRITE_FAILED error={s}\n", .{@errorName(artifact_err)});
        };
        std.debug.print(
            "IV5_INTERACTION_REPRO zig_build='zig build run-interaction-validation -- " ++
                "--profile {s} --seed {d} --ticks {d}{s}{s}' error={s}\n",
            .{
                @tagName(invocation.profile),
                invocation.seed,
                invocation.ticks,
                if (invocation.fuzz) " --fuzz" else "",
                if (invocation.reconnect) " --reconnect" else "",
                @errorName(err),
            },
        );
        return err;
    };
    if (invocation.repeat) {
        var repeat_failure = FailureContext{};
        const repeated = try runTrial(invocation, &repeat_failure);
        if (!equivalentScenarioOutcome(first, repeated)) {
            std.debug.print("IV5_DETERMINISM_MISMATCH first:\n", .{});
            report(invocation, first);
            std.debug.print("IV5_DETERMINISM_MISMATCH repeat:\n", .{});
            report(invocation, repeated);
            std.debug.print("IV5_DETERMINISM_RAW first={any}\n", .{first});
            std.debug.print("IV5_DETERMINISM_RAW repeat={any}\n", .{repeated});
            return error.InteractionTrialNotDeterministic;
        }
    }
    report(invocation, first);
}

/// The product fixture deliberately exercises the live asynchronous district
/// loader. Worker completion can change the patrol/snapshot phase at the
/// post-bootstrap barrier, so a reactive client may emit one more neutral
/// sample or a slightly different facing value without changing gameplay.
/// Exact same-message seeded impairment remains a direct `impaired_link`
/// contract; this aggregate repeat proves the causal gameplay outcome and
/// accepted/rejected action cardinality instead of claiming bitwise lockstep.
fn equivalentScenarioOutcome(first: Summary, repeated: Summary) bool {
    return first.ticks == repeated.ticks and
        first.outcome_fingerprint == repeated.outcome_fingerprint and
        first.player_deaths == repeated.player_deaths and
        first.player_respawns == repeated.player_respawns and
        first.npc_kills == repeated.npc_kills and
        first.npc_replacements == repeated.npc_replacements and
        first.reconnects == repeated.reconnects and
        first.melee_submitted == repeated.melee_submitted and
        first.melee_results == repeated.melee_results and
        first.respawn_submitted == repeated.respawn_submitted and
        first.respawn_results == repeated.respawn_results and
        first.rejected_actions == repeated.rejected_actions and
        first.relevance_transfers == repeated.relevance_transfers;
}

test "scenario repeat separates semantic outcome from live bootstrap sampling" {
    const empty_link = impaired.Diagnostics{
        .client_to_authority = .{},
        .authority_to_client = .{},
    };
    const first = Summary{
        .ticks = 4800,
        .action_fingerprint = 1,
        .submission_fingerprint = 2,
        .outcome_fingerprint = 3,
        .ingress_fingerprint = 4,
        .player_deaths = 1,
        .player_respawns = 1,
        .npc_kills = 1,
        .npc_replacements = 1,
        .reconnects = 1,
        .melee_submitted = 3,
        .melee_results = 3,
        .respawn_submitted = 1,
        .respawn_results = 1,
        .rejected_actions = 0,
        .relevance_transfers = 1,
        .link = empty_link,
    };
    var same_outcome = first;
    same_outcome.action_fingerprint = 10;
    same_outcome.submission_fingerprint = 11;
    same_outcome.ingress_fingerprint = 12;
    same_outcome.link.client_to_authority.sent_messages = 1;
    try std.testing.expect(equivalentScenarioOutcome(first, same_outcome));

    var changed_outcome = same_outcome;
    changed_outcome.outcome_fingerprint +%= 1;
    try std.testing.expect(!equivalentScenarioOutcome(first, changed_outcome));
}

fn runTrial(invocation: Invocation, failure: *FailureContext) !Summary {
    const authority = try authority_module.DedicatedAuthority.init(std.heap.page_allocator);
    defer authority.deinit();
    const tick_origin = try settleProductBootstrap(authority);
    var client = try session_client.Client.init(.{ .value = invocation.seed | 1 });
    var link = try impaired.Link.init(configFor(invocation.profile, invocation.seed));
    defer link.deinit();
    var accumulated_link = impaired.Diagnostics{
        .client_to_authority = .{},
        .authority_to_client = .{},
    };
    var connection = authority_module.TransportConnection{ .value = 1 };
    _ = try authority.openConnection(connection);
    try link.sendFromClient(try client.begin());
    var journey = Journey.init(invocation.seed ^ scenario.seed);
    var terminal_output = false;
    var scenario_contract_completed_tick: ?u64 = null;

    for (0..invocation.ticks) |tick_index| {
        const tick: u64 = @intCast(tick_index);
        failure.* = .{
            .tick = tick,
            .authority_tick = authority.diagnostics().tick,
            .client_server_tick = client.world.server_tick,
            .action_fingerprint = journey.action_fingerprint,
            .joined = client.state == .joined,
            .lifecycle_known = client.avatar_life_state != null,
            .avatar_alive = client.avatar_life_state == .alive,
            .character_alive = if (ownedCharacter(&client)) |character|
                character.life_state == .alive
            else
                false,
            .avatar_health = if (ownedCharacter(&client)) |character| character.health else 0,
            .avatar_entity_index = client.avatar_entity.index,
            .avatar_entity_generation = client.avatar_entity.generation,
            .avatar_incarnation = client.avatar_incarnation,
            .character_entity_index = if (ownedCharacter(&client)) |character|
                character.entity.index
            else
                0,
            .character_entity_generation = if (ownedCharacter(&client)) |character|
                character.entity.generation
            else
                0,
            .character_incarnation = if (ownedCharacter(&client)) |character|
                character.incarnation
            else
                0,
            .life_events = client.diagnostics().life_events,
            .respawn_ready_tick = client.respawn_ready_tick,
            .melee_pending = client.pending_melee_action != null,
            .respawn_pending = client.pending_respawn_action != null,
            .provocation_hit = journey.provocation_hit,
            .player_dead = journey.player_dead,
            .player_respawned = journey.player_respawned,
            .npc_killed = journey.npc_killed,
            .npc_replaced = journey.npc_replaced,
            .reconnected = journey.reconnected,
        };

        if (invocation.reconnect and journey.player_respawned and
            !journey.reconnect_started and client.state == .joined and
            client.pending_melee_action == null and client.pending_respawn_action == null)
        {
            accumulateDiagnostics(&accumulated_link, link.diagnostics());
            _ = try authority.transportClosed(connection);
            client.transportDisconnected();
            link.deinit();
            link = try impaired.Link.init(configFor(invocation.profile, invocation.seed +% 1));
            try link.advanceTo(tick);
            connection.value +%= 1;
            _ = try authority.openConnection(connection);
            try link.sendFromClient(try client.begin());
            journey.reconnect_started = true;
            journey.note(0x52_45_43_4f, 1);
        }

        try link.advanceTo(tick);
        while (link.receiveForAuthority()) |message| try authority.ingest(connection, message);
        try authority.tick();
        while (authority.beginOutboundLease()) |lease| {
            const outbound = lease.outbound;
            terminal_output = terminal_output or outbound.close_after_send;
            if (outbound.connection.value != connection.value) {
                try authority.commitOutboundLease(lease.generation);
                continue;
            }
            link.sendFromAuthority(.{
                .delivery_id = outbound.delivery_id,
                .message = outbound.message,
            }) catch |err| {
                if (outbound.delivery == .reliable) {
                    try authority.retryOutboundLease(lease.generation);
                } else try authority.commitOutboundLease(lease.generation);
                return err;
            };
            try authority.commitOutboundLease(lease.generation);
        }
        while (link.receiveForClient()) |delivered| {
            try client.receiveDelivered(delivered);
            while (client.takeDeliveryReceipt()) |receipt| try link.sendFromClient(receipt);
            if (client.takeBaselineAck()) |ack| try link.sendFromClient(ack);
            if (client.takeSnapshotAck()) |ack| try link.sendFromClient(ack);
        }
        observeResults(&client, &journey);
        try observeWorld(&client, &journey);
        if (journey.reconnect_started and client.state == .joined and
            authority.diagnostics().reconnects != 0)
        {
            journey.reconnected = true;
        }
        if (journey.player_respawned and scenario_contract_completed_tick == null) {
            scenario_contract_completed_tick = tick;
        }
        if (scenario_contract_completed_tick == null and journey.joined_tick != null and
            tick > journey.joined_tick.? +| scenario.deadline_ticks)
        {
            return error.SharedInteractionScenarioDeadlineExceeded;
        }

        const reconnect_pending = invocation.reconnect and journey.player_respawned and
            !journey.reconnect_started and client.pending_melee_action == null and
            client.pending_respawn_action == null;
        if (client.state == .joined and !reconnect_pending) {
            const fuzz_active = invocation.fuzz and
                journey.baseComplete(invocation.reconnect) and
                tick +| settle_ticks < invocation.ticks;
            try submitActions(
                &client,
                &link,
                authority.diagnostics().tick,
                tick,
                fuzz_active,
                &journey,
            );
        }
    }

    accumulateDiagnostics(&accumulated_link, link.diagnostics());
    observeResults(&client, &journey);
    try observeWorld(&client, &journey);
    const authority_diagnostics = authority.diagnostics();
    const client_diagnostics = client.diagnostics();
    if (terminal_output or client.state != .joined) return error.InteractionSessionTerminated;
    if (!journey.baseComplete(invocation.reconnect)) return error.InteractionJourneyIncomplete;
    if (authority_diagnostics.first_cycle_fault != null) return error.InteractionAuthorityFaulted;
    if (client.pending_melee_action != null or client.pending_respawn_action != null) {
        return error.InteractionActionDidNotReachTerminalDisposition;
    }
    if (journey.melee_submitted != journey.melee_results or
        journey.respawn_submitted != journey.respawn_results)
    {
        return error.InteractionActionDispositionCountMismatch;
    }
    if (client_diagnostics.prediction.history_overflows != 0) {
        return error.InteractionPredictionHistoryOverflow;
    }
    if (accumulated_link.client_to_authority.queue_overflows != 0 or
        accumulated_link.authority_to_client.queue_overflows != 0)
    {
        return error.InteractionImpairedQueueOverflow;
    }
    if (invocation.profile == .blackout and
        (accumulated_link.client_to_authority.blackout_drops == 0 or
            accumulated_link.authority_to_client.blackout_drops == 0))
    {
        return error.InteractionBlackoutNotObserved;
    }
    if (invocation.profile == .adverse and
        (accumulated_link.client_to_authority.lost_messages == 0 or
            accumulated_link.client_to_authority.duplicated_messages == 0 or
            accumulated_link.client_to_authority.reordered_messages == 0 or
            accumulated_link.authority_to_client.lost_messages == 0))
    {
        return error.InteractionAdverseFaultClassMissing;
    }

    return .{
        .ticks = invocation.ticks,
        .action_fingerprint = journey.action_fingerprint,
        .submission_fingerprint = journey.submission_fingerprint,
        .outcome_fingerprint = journey.outcome_fingerprint,
        .ingress_fingerprint = normalizedIngressFingerprint(authority, tick_origin),
        .player_deaths = journey.player_deaths,
        .player_respawns = journey.player_respawns,
        .npc_kills = journey.npc_kills,
        .npc_replacements = journey.npc_replacements,
        .reconnects = authority_diagnostics.reconnects,
        .melee_submitted = journey.melee_submitted,
        .melee_results = journey.melee_results,
        .respawn_submitted = journey.respawn_submitted,
        .respawn_results = journey.respawn_results,
        .rejected_actions = journey.rejected_actions,
        .relevance_transfers = authority_diagnostics.relevance_transfers,
        .link = accumulated_link,
    };
}

fn fingerprintNote(seed: u64, tag: u64, value: u64) u64 {
    var result = seed;
    result ^= tag +% 0x9e37_79b9 +% (result << 6) +% (result >> 2);
    result ^= value;
    result *%= 0x0000_0100_0000_01b3;
    return result;
}

fn settleProductBootstrap(authority: *authority_module.DedicatedAuthority) !u64 {
    for (0..bootstrap_tick_limit) |_| {
        const diagnostics = authority.diagnostics();
        if (diagnostics.first_cycle_fault != null) return error.InteractionBootstrapAuthorityFaulted;
        if (diagnostics.active_vehicles == 1 and diagnostics.active_carryables == 1 and
            diagnostics.active_npcs == budgets.product_npcs)
        {
            return diagnostics.tick;
        }
        try authority.tick();
        while (authority.beginOutboundLease()) |lease| {
            try authority.commitOutboundLease(lease.generation);
        }
        std.Thread.yield() catch {};
    }
    return error.InteractionProductBootstrapTimedOut;
}

fn normalizedIngressFingerprint(
    authority: *const authority_module.DedicatedAuthority,
    tick_origin: u64,
) u64 {
    var records: [budgets.accepted_ingress_capacity]authority_module.AcceptedIngress = undefined;
    const count = authority.copyAcceptedIngress(&records);
    var fingerprint = ingress_fingerprint_seed;
    for (records[0..count]) |record| {
        fingerprint = record.fingerprintFromTickOrigin(fingerprint, tick_origin);
    }
    return fingerprint;
}

fn submitActions(
    client: *session_client.Client,
    link: *impaired.Link,
    authority_tick: u64,
    tick: u64,
    fuzz_active: bool,
    journey: *Journey,
) !void {
    if (journey.joined_tick == null) journey.joined_tick = tick;
    // A successful respawn result can lead the next snapshot. During that
    // bounded window the world may still contain the prior incarnation's
    // visible death proxy. It is presentation evidence, not an interactive
    // avatar, so do not submit movement or melee through it.
    const character = ownedInteractiveCharacter(client);
    const nearest = if (character) |value| nearestLivingNpc(client, value.position) else null;
    var move = [2]f32{ 0, 0 };
    var facing_yaw: f32 = 0;
    var jump = false;

    if (character != null and client.avatar_life_state == .alive) {
        if (fuzz_active) {
            const phase = (tick / 240) % 4;
            move = switch (phase) {
                0 => .{ 0, 1 },
                1 => .{ 1, 0 },
                2 => .{ 0, -1 },
                else => .{ -1, 0 },
            };
            facing_yaw = switch (phase) {
                0 => 0,
                1 => -std.math.pi / 2.0,
                2 => std.math.pi,
                else => std.math.pi / 2.0,
            };
            jump = journey.rng.next() % 97 == 0;
        } else if ((!journey.provocation_hit or journey.player_respawned) and
            !journey.npc_killed and nearest != null)
        {
            const dx = nearest.?.position[0] - character.?.position[0];
            const dz = nearest.?.position[2] - character.?.position[2];
            facing_yaw = std.math.atan2(dx, -dz);
            if (nearest.?.distance_squared > 1.5 * 1.5) move = .{ 0, 1 };
        } else if (journey.npc_killed and !journey.npc_replaced and
            tick >= journey.npc_killed_tick +| 360)
        {
            // Match the graphical process adapter's bounded relevance seek so
            // the replacement lifecycle becomes observable to this client.
            move = .{ 0, 1 };
            facing_yaw = std.math.pi / 2.0;
        }
        try link.sendFromClient(try client.input(
            authority_tick +| 1,
            move,
            facing_yaw,
            jump,
        ));
        journey.noteInput(move, facing_yaw, jump);
    }

    if (client.avatar_life_state == .dead and client.pending_respawn_action == null) {
        const should_submit = if (fuzz_active)
            journey.rng.next() % 19 == 0
        else
            client.world.server_tick >= client.respawn_ready_tick;
        if (should_submit) {
            try link.sendFromClient(try client.respawnAction());
            journey.respawn_submitted +|= 1;
            journey.note(0x52_53_50_4e, journey.respawn_submitted);
        }
        return;
    }

    if (character == null or nearest == null or client.pending_melee_action != null) return;
    const should_melee = if (fuzz_active)
        journey.rng.next() % 23 == 0
    else if (!journey.provocation_hit)
        nearest.?.distance_squared <= 2.2 * 2.2
    else
        journey.player_respawned and !journey.npc_killed and
            nearest.?.distance_squared <= 2.2 * 2.2 and
            client.world.server_tick >= client.melee_ready_tick;
    if (should_melee) {
        try link.sendFromClient(try client.meleeAction(authority_tick +| 1));
        journey.melee_submitted +|= 1;
        journey.note(0x4d_45_4c_45, journey.melee_submitted);
    }
}

fn observeResults(client: *session_client.Client, journey: *Journey) void {
    while (client.takeMeleeActionResult()) |result| {
        journey.melee_results +|= 1;
        journey.note(0x4d_52_53_4c, @intFromEnum(result.disposition));
        if (result.disposition == .hit) {
            if (!journey.provocation_hit) journey.provocation_hit = true;
            if (result.killed) {
                journey.npc_killed = true;
                journey.npc_killed_tick = result.ready_tick;
                journey.npc_kills +|= 1;
                journey.dead_npc_index = result.target.index;
                journey.dead_npc_generation = result.target.generation;
            }
        } else journey.rejected_actions +|= 1;
    }
    while (client.takeRespawnActionResult()) |result| {
        journey.respawn_results +|= 1;
        journey.note(0x52_52_53_4c, @intFromEnum(result.disposition));
        if (result.disposition == .respawned) {
            journey.player_respawned = true;
            journey.player_respawns +|= 1;
        } else journey.rejected_actions +|= 1;
    }
    while (client.takeLifeEvent()) |event| {
        journey.note(0x4c_49_46_45, @intFromEnum(event.state));
        if (event.state == .dead and event.avatar.index == client.avatar_entity.index) {
            journey.player_dead = true;
            journey.player_deaths +|= 1;
        }
        if (event.state == .alive and journey.player_dead and
            event.avatar.index == client.avatar_entity.index)
        {
            journey.player_respawned = true;
        }
    }
}

fn observeWorld(client: *const session_client.Client, journey: *Journey) !void {
    for (client.world.slice()) |entry| try validateCharacter(entry.current);
    if (ownedCharacter(client)) |character| {
        const cached = client.avatar_life_state orelse
            return error.InteractionAvatarLifecycleUnavailable;
        // Reliable death feedback may lead the next unreliable snapshot. The
        // reverse transition for the same incarnation is never valid: only a
        // successful respawn creates the next living incarnation.
        if (cached == .alive and character.life_state == .dead and
            character.incarnation == client.avatar_incarnation)
        {
            return error.InteractionAvatarLifecycleProjectionMismatch;
        }
    }
    for (client.world.npcSlice()) |entry| {
        const npc = entry.current;
        try validateNpc(npc);
        if (journey.npc_killed and !journey.npc_replaced and
            npc.entity.index == journey.dead_npc_index and
            npc.entity.generation != journey.dead_npc_generation and
            npc.life_state == .alive)
        {
            journey.npc_replaced = true;
            journey.npc_replacements +|= 1;
            journey.note(0x4e_50_43_52, npc.entity.generation);
        }
    }
}

const NearestNpc = struct {
    position: [3]f32,
    distance_squared: f32,
};

fn nearestLivingNpc(client: *const session_client.Client, origin: [3]f32) ?NearestNpc {
    var nearest: ?NearestNpc = null;
    for (client.world.npcSlice()) |entry| {
        if (entry.current.life_state != .alive) continue;
        const dx = entry.current.position[0] - origin[0];
        const dz = entry.current.position[2] - origin[2];
        const distance_squared = dx * dx + dz * dz;
        if (nearest == null or distance_squared < nearest.?.distance_squared) {
            nearest = .{ .position = entry.current.position, .distance_squared = distance_squared };
        }
    }
    return nearest;
}

fn ownedCharacter(client: *const session_client.Client) ?protocol.CharacterState {
    for (client.world.slice()) |entry| {
        if (std.meta.eql(entry.current.owner, client.participant)) return entry.current;
    }
    return null;
}

fn ownedInteractiveCharacter(client: *const session_client.Client) ?protocol.CharacterState {
    const character = ownedCharacter(client) orelse return null;
    if (client.avatar_life_state != .alive or character.life_state != .alive or
        character.incarnation != client.avatar_incarnation or
        !std.meta.eql(character.entity, client.avatar_entity))
    {
        return null;
    }
    return character;
}

fn validateCharacter(value: protocol.CharacterState) !void {
    for (value.position) |component| if (!std.math.isFinite(component)) {
        return error.InteractionNonFiniteCharacter;
    };
    if (!std.math.isFinite(value.facing_yaw) or !value.entity.isValid() or
        value.maximum_health == 0 or value.health > value.maximum_health or
        (value.life_state == .alive and value.health == 0) or
        (value.life_state == .dead and value.health != 0))
    {
        return error.InteractionInvalidCharacterProjection;
    }
}

fn validateNpc(value: protocol.NpcState) !void {
    for (value.position) |component| if (!std.math.isFinite(component)) {
        return error.InteractionNonFiniteNpc;
    };
    if (!std.math.isFinite(value.facing_yaw) or !value.entity.isValid() or
        value.maximum_health == 0 or value.health > value.maximum_health or
        (value.life_state == .alive and value.health == 0) or
        (value.life_state == .dead and value.health != 0))
    {
        return error.InteractionInvalidNpcProjection;
    }
}

fn configFor(profile: Profile, seed: u64) impaired.Config {
    return switch (profile) {
        .clean => .{
            .seed = seed,
            .one_way_latency_ticks = 0,
            .jitter_ticks = 0,
            .loss_per_10k = 0,
            .duplicate_per_10k = 0,
            .reorder_per_10k = 0,
        },
        .nominal => impaired.Config.fromProfile(seed, budgets.nominal_profile),
        .adverse => impaired.Config.fromProfile(seed, budgets.adverse_profile),
        .blackout => blk: {
            var result = impaired.Config.fromProfile(seed, budgets.adverse_profile);
            result.blackout = .{ .first_tick = 240, .end_tick = 300 };
            break :blk result;
        },
    };
}

fn accumulateDiagnostics(total: *impaired.Diagnostics, value: impaired.Diagnostics) void {
    accumulateDirection(&total.client_to_authority, value.client_to_authority);
    accumulateDirection(&total.authority_to_client, value.authority_to_client);
}

fn accumulateDirection(
    total: *impaired.DirectionDiagnostics,
    value: impaired.DirectionDiagnostics,
) void {
    total.sent_messages +|= value.sent_messages;
    total.sent_bytes +|= value.sent_bytes;
    total.delivered_messages +|= value.delivered_messages;
    total.delivered_bytes +|= value.delivered_bytes;
    total.lost_messages +|= value.lost_messages;
    total.duplicated_messages +|= value.duplicated_messages;
    total.reordered_messages +|= value.reordered_messages;
    total.blackout_drops +|= value.blackout_drops;
    total.bandwidth_deferrals +|= value.bandwidth_deferrals;
    total.queue_occupancy = value.queue_occupancy;
    total.queue_high_water = @max(total.queue_high_water, value.queue_high_water);
    total.queue_overflows +|= value.queue_overflows;
}

fn report(invocation: Invocation, result: Summary) void {
    const up = result.link.client_to_authority;
    const down = result.link.authority_to_client;
    std.debug.print(
        "IV5_INTERACTION_PASS profile={s} seed={d} ticks={d} repeat={} fuzz={} " ++
            "reconnect={} deaths/respawns={d}/{d} npc_kills/replacements={d}/{d} " ++
            "actions_melee={d}/{d} actions_respawn={d}/{d} rejected={d} " ++
            "relevance_transfers={d} up_lost/dup/reorder/blackout={d}/{d}/{d}/{d} " ++
            "down_lost/dup/reorder/blackout={d}/{d}/{d}/{d} queue_high={d}/{d} " ++
            "action_fingerprint={x} submission_fingerprint={x} " ++
            "outcome_fingerprint={x} ingress_fingerprint={x}\n",
        .{
            @tagName(invocation.profile),
            invocation.seed,
            result.ticks,
            invocation.repeat,
            invocation.fuzz,
            invocation.reconnect,
            result.player_deaths,
            result.player_respawns,
            result.npc_kills,
            result.npc_replacements,
            result.melee_submitted,
            result.melee_results,
            result.respawn_submitted,
            result.respawn_results,
            result.rejected_actions,
            result.relevance_transfers,
            up.lost_messages,
            up.duplicated_messages,
            up.reordered_messages,
            up.blackout_drops,
            down.lost_messages,
            down.duplicated_messages,
            down.reordered_messages,
            down.blackout_drops,
            up.queue_high_water,
            down.queue_high_water,
            result.action_fingerprint,
            result.submission_fingerprint,
            result.outcome_fingerprint,
            result.ingress_fingerprint,
        },
    );
}

fn parseInvocation(args: []const []const u8) !Invocation {
    var result = Invocation{};
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--profile")) {
            index += 1;
            if (index >= args.len) return error.MissingInteractionProfile;
            result.profile = parseProfile(args[index]) orelse return error.UnknownInteractionProfile;
        } else if (std.mem.eql(u8, args[index], "--seed")) {
            index += 1;
            if (index >= args.len) return error.MissingInteractionSeed;
            result.seed = try std.fmt.parseInt(u64, args[index], 0);
            if (result.seed == 0) return error.InvalidInteractionSeed;
        } else if (std.mem.eql(u8, args[index], "--ticks")) {
            index += 1;
            if (index >= args.len) return error.MissingInteractionTicks;
            result.ticks = try std.fmt.parseInt(u64, args[index], 10);
        } else if (std.mem.eql(u8, args[index], "--fuzz")) {
            result.fuzz = true;
        } else if (std.mem.eql(u8, args[index], "--reconnect")) {
            result.reconnect = true;
        } else if (std.mem.eql(u8, args[index], "--repeat")) {
            result.repeat = true;
        } else return error.UnknownInteractionValidationArgument;
    }
    return result;
}

fn parseProfile(value: []const u8) ?Profile {
    inline for (std.meta.tags(Profile)) |profile| {
        if (std.mem.eql(u8, value, @tagName(profile))) return profile;
    }
    return null;
}

fn writeFailureArtifact(
    io: std.Io,
    invocation: Invocation,
    failure: FailureContext,
    err: anyerror,
) !void {
    var bytes: [2048]u8 = undefined;
    const header = try std.fmt.bufPrint(
        &bytes,
        "scenario={s}\nscenario_seed={x}\nprofile={s}\nseed={d}\nticks={d}\n" ++
            "fuzz={}\nreconnect={}\nfailing_tick={d}\nerror={s}\n" ++
            "authority_tick={d}\nclient_server_tick={d}\naction_fingerprint={x}\n" ++
            "joined={}\nlifecycle_known={}\navatar_alive={}\ncharacter_alive={}\n" ++
            "avatar_health={d}\nlife_events={d}\n" ++
            "avatar_entity={d}:{d}\navatar_incarnation={d}\n" ++
            "character_entity={d}:{d}\ncharacter_incarnation={d}\n",
        .{
            scenario.name,
            scenario.seed,
            @tagName(invocation.profile),
            invocation.seed,
            invocation.ticks,
            invocation.fuzz,
            invocation.reconnect,
            failure.tick,
            @errorName(err),
            failure.authority_tick,
            failure.client_server_tick,
            failure.action_fingerprint,
            failure.joined,
            failure.lifecycle_known,
            failure.avatar_alive,
            failure.character_alive,
            failure.avatar_health,
            failure.life_events,
            failure.avatar_entity_index,
            failure.avatar_entity_generation,
            failure.avatar_incarnation,
            failure.character_entity_index,
            failure.character_entity_generation,
            failure.character_incarnation,
        },
    );
    const detail = try std.fmt.bufPrint(
        bytes[header.len..],
        "respawn_ready_tick={d}\nmelee_pending={}\nrespawn_pending={}\n" ++
            "provocation_hit={}\nplayer_dead={}\nplayer_respawned={}\n" ++
            "npc_killed={}\nnpc_replaced={}\nreconnected={}\n" ++
            "repro=zig build run-interaction-validation -- --profile {s} --seed {d} --ticks {d}{s}{s}\n",
        .{
            failure.respawn_ready_tick,
            failure.melee_pending,
            failure.respawn_pending,
            failure.provocation_hit,
            failure.player_dead,
            failure.player_respawned,
            failure.npc_killed,
            failure.npc_replaced,
            failure.reconnected,
            @tagName(invocation.profile),
            invocation.seed,
            invocation.ticks,
            if (invocation.fuzz) " --fuzz" else "",
            if (invocation.reconnect) " --reconnect" else "",
        },
    );
    const data = bytes[0 .. header.len + detail.len];
    var tmp = try std.Io.Dir.openDirAbsolute(io, "/tmp", .{});
    defer tmp.close(io);
    try tmp.writeFile(io, .{
        .sub_path = "incinerator-interaction-first-failure.txt",
        .data = data,
    });
}

test "IV5 invocation is explicit and bounded" {
    const parsed = try parseInvocation(&.{
        "interaction",
        "--profile",
        "adverse",
        "--seed",
        "17",
        "--ticks",
        "8192",
        "--fuzz",
        "--reconnect",
        "--repeat",
    });
    try std.testing.expectEqual(Profile.adverse, parsed.profile);
    try std.testing.expectEqual(@as(u64, 17), parsed.seed);
    try std.testing.expectEqual(@as(u64, 8192), parsed.ticks);
    try std.testing.expect(parsed.fuzz and parsed.reconnect and parsed.repeat);
    try std.testing.expectError(
        error.UnknownInteractionProfile,
        parseInvocation(&.{ "interaction", "--profile", "chaos" }),
    );
}

test "SplitMix action seed is deterministic" {
    var first = SplitMix64{ .state = 17 };
    var second = SplitMix64{ .state = 17 };
    for (0..128) |_| try std.testing.expectEqual(first.next(), second.next());
}
