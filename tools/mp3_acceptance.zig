//! Deterministic MP3 character-prediction acceptance over the semantic fault
//! adapter. Real GNS lifecycle remains covered by `verify-mp2`.

const std = @import("std");
const budgets = @import("session_budgets");
const protocol = @import("session_protocol");
const session_client = @import("session_client");
const authority_module = @import("session_authority");
const impaired = @import("impaired_link");

const movement_input_ticks: u64 = 360;
const total_ticks: u64 = 900;

const Result = struct {
    name: []const u8,
    seed: u64,
    movement_m: f32,
    convergence_error_m: f32,
    maximum_prediction_error_m: f32,
    maximum_snapshot_age_ticks: u64,
    soft_corrections: u64,
    hard_corrections: u64,
    stale_inputs: u64,
    ingress_fingerprint: u64,
    link: impaired.Diagnostics,
};

pub fn main(init: std.process.Init) !void {
    _ = init;
    const clean = impaired.Config{
        .seed = 1,
        .one_way_latency_ticks = 0,
        .jitter_ticks = 0,
        .loss_per_10k = 0,
        .duplicate_per_10k = 0,
        .reorder_per_10k = 0,
    };
    try report(try runTrial("clean", clean, false));

    for ([_]u64{ 11, 29, 47 }) |seed| {
        const result = try runTrial(
            "nominal",
            impaired.Config.fromProfile(seed, budgets.nominal_profile),
            false,
        );
        if (seed == 11) {
            const repeat = try runTrial(
                "nominal-repeat",
                impaired.Config.fromProfile(seed, budgets.nominal_profile),
                false,
            );
            if (result.ingress_fingerprint != repeat.ingress_fingerprint or
                !std.meta.eql(result.link, repeat.link) or
                result.movement_m != repeat.movement_m or
                result.maximum_prediction_error_m != repeat.maximum_prediction_error_m)
            {
                return error.ImpairedTrialWasNotDeterministic;
            }
        }
        try report(result);
    }
    for ([_]u64{ 101, 211, 307 }) |seed| {
        try report(try runTrial(
            "adverse",
            impaired.Config.fromProfile(seed, budgets.adverse_profile),
            false,
        ));
    }
    var blackout = impaired.Config.fromProfile(401, budgets.adverse_profile);
    blackout.blackout = .{ .first_tick = 240, .end_tick = 300 };
    try report(try runTrial("blackout", blackout, true));
}

fn runTrial(name: []const u8, config: impaired.Config, expect_blackout: bool) !Result {
    var authority = try authority_module.Authority.init(std.heap.page_allocator);
    var authority_live = true;
    defer if (authority_live) authority.deinit();
    var client = try session_client.Client.init(.{ .value = config.seed + 1_000 });
    var link = try impaired.Link.init(config);
    defer link.deinit();
    const connection = authority_module.TransportConnection{ .value = 1 };
    _ = try authority.openConnection(connection);
    try link.sendFromClient(try client.begin());

    var produced_inputs: u64 = 0;
    var initial_position: ?[3]f32 = null;
    var maximum_snapshot_age_ticks: u64 = 0;
    var saw_terminal_output = false;
    var steady_snapshot_received = false;

    for (0..total_ticks) |tick| {
        try link.advanceTo(tick);
        while (link.receiveForAuthority()) |message| {
            try authority.ingest(connection, message);
        }
        try authority.tick();
        while (authority.pollOutbound()) |outbound| {
            if (outbound.close_after_send) saw_terminal_output = true;
            try link.sendFromAuthority(outbound.message);
        }
        while (link.receiveForClient()) |message| {
            try client.receive(message);
            if (message == .snapshot) steady_snapshot_received = true;
            if (client.takeBaselineAck()) |ack| try link.sendFromClient(ack);
            if (client.takeSnapshotAck()) |ack| try link.sendFromClient(ack);
        }

        if (client.state == .joined) {
            if (ownedCharacter(&client)) |character| {
                if (initial_position == null) initial_position = character.position;
            }
            const move: [2]f32 = if (produced_inputs < movement_input_ticks)
                .{ 0, 1 }
            else
                .{ 0, 0 };
            try link.sendFromClient(try client.input(
                authority.diagnostics().tick + 1,
                move,
                0,
                false,
            ));
            produced_inputs += 1;
        }
        if (client.world.initialized and steady_snapshot_received) {
            maximum_snapshot_age_ticks = @max(
                maximum_snapshot_age_ticks,
                authority.diagnostics().tick -| client.world.server_tick,
            );
        }
    }

    if (saw_terminal_output or client.state != .joined) return error.TrialSessionTerminated;
    if (produced_inputs <= movement_input_ticks) return error.TrialDidNotSettle;
    const initial = initial_position orelse return error.TrialMissingInitialState;
    const authoritative = ownedCharacter(&client) orelse return error.TrialMissingOwnedCharacter;
    const predicted = client.localPresentation() orelse return error.TrialMissingPrediction;
    const movement = distance(initial, authoritative.position);
    const convergence = distance(predicted.position, authoritative.position);
    const client_diagnostics = client.diagnostics();
    const authority_diagnostics = authority.diagnostics();
    const link_diagnostics = link.diagnostics();

    if (authority_diagnostics.active_npcs != budgets.product_npcs or
        client.world.npc_count != budgets.product_npcs / 2 or
        authority_diagnostics.npc_state_updates >
            (total_ticks / budgets.ticks_per_npc_snapshot + 4) *
                (budgets.product_npcs / 2))
    {
        return error.NpcProjectionRateOrMembershipMismatch;
    }

    if (movement < 20) {
        std.debug.print("MP3_MOVEMENT_DIAGNOSTIC profile={s} movement={d:.3}\n", .{
            name,
            movement,
        });
        return error.TrialMovementTooSmall;
    }
    if (convergence > budgets.prediction_thresholds.soft_position_error_m) {
        return error.TrialDidNotConverge;
    }
    if (client_diagnostics.prediction.history_overflows != 0) {
        return error.PredictionHistoryOverflow;
    }
    const allowed_soft_corrections =
        (@as(u64, budgets.prediction_thresholds.maximum_soft_corrections_per_minute) *
            total_ticks + budgets.authority_tick_hz * 60 - 1) /
        (budgets.authority_tick_hz * 60);
    if (client_diagnostics.prediction.soft_corrections > allowed_soft_corrections) {
        return error.SoftCorrectionBudgetExceeded;
    }
    if (link_diagnostics.client_to_authority.queue_overflows != 0 or
        link_diagnostics.authority_to_client.queue_overflows != 0)
    {
        return error.ImpairedQueueOverflow;
    }
    if (!expect_blackout) {
        const maximum_age_ticks = (@as(u64, budgets.prediction_thresholds.maximum_snapshot_age_ms) *
            budgets.authority_tick_hz + 999) / 1000;
        if (maximum_snapshot_age_ticks > maximum_age_ticks) {
            return error.SnapshotAgeBudgetExceeded;
        }
        if (client_diagnostics.prediction.hard_corrections != 0 or
            client_diagnostics.prediction.maximum_error_m >=
                budgets.prediction_thresholds.hard_position_error_m)
        {
            return error.UnexpectedHardCorrection;
        }
    } else if (link_diagnostics.client_to_authority.blackout_drops == 0 or
        link_diagnostics.authority_to_client.blackout_drops == 0)
    {
        return error.BlackoutDidNotManufactureLoss;
    }
    var replay_records: [budgets.accepted_ingress_capacity]authority_module.AcceptedIngress = undefined;
    const replay_record_count = authority.copyAcceptedIngress(&replay_records);
    authority.deinit();
    authority_live = false;
    try verifyAcceptedIngressReplay(
        replay_records[0..replay_record_count],
        client.account,
        authoritative,
    );

    return .{
        .name = name,
        .seed = config.seed,
        .movement_m = movement,
        .convergence_error_m = convergence,
        .maximum_prediction_error_m = client_diagnostics.prediction.maximum_error_m,
        .maximum_snapshot_age_ticks = maximum_snapshot_age_ticks,
        .soft_corrections = client_diagnostics.prediction.soft_corrections,
        .hard_corrections = client_diagnostics.prediction.hard_corrections,
        .stale_inputs = authority_diagnostics.stale_inputs,
        .ingress_fingerprint = authority_diagnostics.ingress_fingerprint,
        .link = link_diagnostics,
    };
}

fn verifyAcceptedIngressReplay(
    records: []const authority_module.AcceptedIngress,
    account: @TypeOf((protocol.Hello{ .account = undefined }).account),
    expected: protocol.CharacterState,
) !void {
    if (records.len == 0) return error.AcceptedIngressJournalWasEmpty;

    var replay = try authority_module.Authority.init(std.heap.page_allocator);
    defer replay.deinit();
    const connection = authority_module.TransportConnection{ .value = 1 };
    _ = try replay.openConnection(connection);
    try replay.ingest(connection, .{ .hello = .{ .account = account } });
    const welcome = replay.pollOutbound().?.message.welcome;
    var final_state: ?protocol.CharacterState = null;
    var cursor: usize = 0;
    for (0..total_ticks) |_| {
        const tick = replay.diagnostics().tick;
        while (cursor < records.len and records[cursor].admitted_tick == tick) : (cursor += 1) {
            const record = records[cursor];
            try replay.ingest(connection, .{ .input = .{
                .session = welcome.session,
                .participant = welcome.participant,
                .sequence = record.sequence,
                .target_tick = record.target_tick,
                .move = record.move,
                .facing_yaw = record.facing_yaw,
                .jump_pressed = record.jump_pressed,
            } });
        }
        try replay.tick();
        while (replay.pollOutbound()) |outbound| switch (outbound.message) {
            .snapshot => |snapshot| {
                for (snapshot.slice()) |character| {
                    if (std.meta.eql(character.owner, welcome.participant)) {
                        final_state = character;
                    }
                }
            },
            .relevance_baseline => |baseline| {
                for (baseline.snapshot.slice()) |character| {
                    if (std.meta.eql(character.owner, welcome.participant)) {
                        final_state = character;
                    }
                }
                try replay.ingest(connection, .{ .baseline_ack = .{
                    .session = welcome.session,
                    .participant = welcome.participant,
                    .baseline_id = baseline.baseline_id,
                } });
            },
            else => {},
        };
    }
    if (cursor != records.len) return error.AcceptedIngressReplayDidNotConsumeJournal;
    const actual = final_state orelse return error.AcceptedIngressReplayMissingState;
    if (!std.meta.eql(expected.entity, actual.entity) or
        !std.meta.eql(expected.owner, actual.owner))
    {
        return error.AcceptedIngressIdentityDivergence;
    }
    if (distance(expected.position, actual.position) > 0.0001) {
        return error.AcceptedIngressPositionDivergence;
    }
    if (distance(expected.velocity, actual.velocity) > 0.0001) {
        return error.AcceptedIngressVelocityDivergence;
    }
    if (@abs(expected.facing_yaw - actual.facing_yaw) > 0.0001) {
        return error.AcceptedIngressFacingDivergence;
    }
}

fn ownedCharacter(client: *const session_client.Client) ?protocol.CharacterState {
    for (client.world.slice()) |entry| {
        if (std.meta.eql(entry.current.owner, client.participant)) return entry.current;
    }
    return null;
}

fn distance(a: [3]f32, b: [3]f32) f32 {
    const x = a[0] - b[0];
    const y = a[1] - b[1];
    const z = a[2] - b[2];
    return @sqrt(x * x + y * y + z * z);
}

fn report(result: Result) !void {
    const up = result.link.client_to_authority;
    const down = result.link.authority_to_client;
    std.debug.print(
        "MP3_TRIAL profile={s} seed={d} movement_m={d:.2} convergence_m={d:.3} " ++
            "prediction_max_m={d:.3} snapshot_age_ticks={d} corrections={d}/{d} stale_inputs={d} " ++
            "up_sent/delivered/lost/dup/reorder={d}/{d}/{d}/{d}/{d} " ++
            "down_sent/delivered/lost/dup/reorder={d}/{d}/{d}/{d}/{d} " ++
            "bytes_per_second={d}/{d} queue_high={d}/{d} ingress={x}\n",
        .{
            result.name,
            result.seed,
            result.movement_m,
            result.convergence_error_m,
            result.maximum_prediction_error_m,
            result.maximum_snapshot_age_ticks,
            result.soft_corrections,
            result.hard_corrections,
            result.stale_inputs,
            up.sent_messages,
            up.delivered_messages,
            up.lost_messages,
            up.duplicated_messages,
            up.reordered_messages,
            down.sent_messages,
            down.delivered_messages,
            down.lost_messages,
            down.duplicated_messages,
            down.reordered_messages,
            up.sent_bytes * budgets.authority_tick_hz / total_ticks,
            down.sent_bytes * budgets.authority_tick_hz / total_ticks,
            up.queue_high_water,
            down.queue_high_water,
            result.ingress_fingerprint,
        },
    );
}
