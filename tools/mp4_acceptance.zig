//! Deterministic MP4-A authoritative-vehicle acceptance over manufactured
//! network conditions. Real GNS ownership/reconnect behavior remains covered
//! by the extended loopback proof.

const std = @import("std");
const budgets = @import("session_budgets");
const protocol = @import("session_protocol");
const session_client = @import("session_client");
const authority_module = @import("session_authority");
const impaired = @import("impaired_link");

const total_ticks: u64 = 1_100;
const enter_after_tick: u64 = 180;
const throttle_ticks: u64 = 300;
const brake_ticks: u64 = 90;
const neutral_ticks: u64 = 60;

fn takeOutbound(authority: anytype) ?authority_module.Outbound {
    const lease = authority.beginOutboundLease() orelse return null;
    authority.commitOutboundLease(lease.generation) catch unreachable;
    return lease.outbound;
}

const Result = struct {
    name: []const u8,
    seed: u64,
    movement_m: f32,
    maximum_snapshot_age_ticks: u64,
    accepted_actions: u64,
    rejected_actions: u64,
    invalid_controls: u64,
    ingress_fingerprint: u64,
    vehicle_prediction: @FieldType(session_client.Diagnostics, "vehicle_prediction"),
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

    for ([_]u64{ 13, 31, 53 }) |seed| {
        const result = try runTrial(
            "nominal",
            impaired.Config.fromProfile(seed, budgets.nominal_profile),
            false,
        );
        if (seed == 13) {
            const repeat = try runTrial(
                "nominal-repeat",
                impaired.Config.fromProfile(seed, budgets.nominal_profile),
                false,
            );
            if (result.ingress_fingerprint != repeat.ingress_fingerprint or
                !std.meta.eql(result.link, repeat.link) or
                !std.meta.eql(result.vehicle_prediction, repeat.vehicle_prediction) or
                result.movement_m != repeat.movement_m)
            {
                return error.ImpairedVehicleTrialWasNotDeterministic;
            }
        }
        try report(result);
    }
    for ([_]u64{ 109, 223, 313 }) |seed| {
        try report(try runTrial(
            "adverse",
            impaired.Config.fromProfile(seed, budgets.adverse_profile),
            false,
        ));
    }
    var blackout = impaired.Config.fromProfile(409, budgets.adverse_profile);
    blackout.blackout = .{ .first_tick = 420, .end_tick = 480 };
    try report(try runTrial("blackout", blackout, true));
}

fn runTrial(name: []const u8, config: impaired.Config, expect_blackout: bool) !Result {
    const authority = try authority_module.DedicatedAuthority.init(std.heap.page_allocator);
    var authority_live = true;
    defer if (authority_live) authority.deinit();
    var client = try session_client.Client.init(.{ .value = config.seed + 20_000 });
    var link = try impaired.Link.init(config);
    defer link.deinit();
    const connection = authority_module.TransportConnection{ .value = 1 };
    _ = try authority.openConnection(connection);
    try link.sendFromClient(try client.begin());

    var initial_vehicle_position: ?[3]f32 = null;
    var last_authority_snapshot: ?protocol.Snapshot = null;
    var last_relevant_vehicle: ?protocol.VehicleState = null;
    var maximum_snapshot_age_ticks: u64 = 0;
    var enter_sent = false;
    var exit_sent = false;
    var saw_owned_vehicle = false;
    var throttle_sent: u64 = 0;
    var brake_sent: u64 = 0;
    var neutral_sent: u64 = 0;
    var character_sequence_sent: u64 = 0;
    var immediate_response_observed = false;
    var steady_snapshot_received = false;

    for (0..total_ticks) |tick| {
        try link.advanceTo(tick);
        while (link.receiveForAuthority()) |message| try authority.ingest(connection, message);
        try authority.tick();
        while (authority.beginOutboundLease()) |lease| {
            const outbound = lease.outbound;
            if (outbound.close_after_send) {
                try authority.commitOutboundLease(lease.generation);
                return error.VehicleTrialSessionTerminated;
            }
            if (outbound.message == .snapshot) {
                last_authority_snapshot = outbound.message.snapshot;
                if (outbound.message.snapshot.vehicle_count != 0) {
                    last_relevant_vehicle = outbound.message.snapshot.vehicles[0];
                }
            }
            link.sendFromAuthority(.{
                .delivery_id = outbound.delivery_id,
                .message = outbound.message,
            }) catch |err| {
                if (outbound.delivery == .reliable) {
                    try authority.retryOutboundLease(lease.generation);
                } else {
                    try authority.commitOutboundLease(lease.generation);
                }
                return err;
            };
            try authority.commitOutboundLease(lease.generation);
        }
        while (link.receiveForClient()) |delivered| {
            const message = delivered.message;
            try client.receiveDelivered(delivered);
            if (message == .snapshot) steady_snapshot_received = true;
            while (client.takeDeliveryReceipt()) |receipt| try link.sendFromClient(receipt);
            if (client.takeBaselineAck()) |ack| try link.sendFromClient(ack);
            if (client.takeSnapshotAck()) |ack| try link.sendFromClient(ack);
        }

        if (client.world.initialized and steady_snapshot_received) {
            maximum_snapshot_age_ticks = @max(
                maximum_snapshot_age_ticks,
                authority.diagnostics().tick -| client.world.server_tick,
            );
            const vehicles = client.world.vehicleSlice();
            if (vehicles.len != 0 and initial_vehicle_position == null) {
                initial_vehicle_position = vehicles[0].current.position;
            }
        }
        if (client.state != .joined or !client.world.initialized) continue;

        if (!enter_sent and authority.diagnostics().tick >= enter_after_tick) {
            const vehicles = client.world.vehicleSlice();
            if (vehicles.len != 1) return error.VehicleTrialMissingVehicle;
            try link.sendFromClient(try client.vehicleAction(.enter, vehicles[0].current.entity));
            enter_sent = true;
            continue;
        }

        if (client.ownedVehicle()) |vehicle| {
            saw_owned_vehicle = true;
            if (throttle_sent < throttle_ticks) {
                const before = client.localVehiclePresentation() orelse
                    return error.VehiclePredictionNotInitialized;
                const message = try client.vehicleInput(
                    authority.diagnostics().tick + 1,
                    vehicle.entity,
                    1,
                    0,
                    0,
                    0,
                );
                const after = client.localVehiclePresentation() orelse
                    return error.VehiclePredictionNotInitialized;
                immediate_response_observed = immediate_response_observed or
                    distance(before.position, after.position) > 0.000001;
                try link.sendFromClient(message);
                throttle_sent += 1;
            } else if (brake_sent < brake_ticks) {
                try link.sendFromClient(try client.vehicleInput(
                    authority.diagnostics().tick + 1,
                    vehicle.entity,
                    0,
                    0,
                    1,
                    0,
                ));
                brake_sent += 1;
            } else if (neutral_sent < neutral_ticks) {
                try link.sendFromClient(try client.vehicleInput(
                    authority.diagnostics().tick + 1,
                    vehicle.entity,
                    0,
                    0,
                    0,
                    0,
                ));
                neutral_sent += 1;
            } else if (!exit_sent and client.pending_vehicle_action == null) {
                try link.sendFromClient(try client.vehicleAction(.exit, vehicle.entity));
                exit_sent = true;
            }
        } else if ((!enter_sent or exit_sent) and client.pending_vehicle_action == null) {
            try link.sendFromClient(try client.input(
                authority.diagnostics().tick + 1,
                .{ 0, 0 },
                0,
                false,
            ));
            character_sequence_sent += 1;
        }
    }

    if (client.state != .joined) return error.VehicleTrialSessionTerminated;
    if (!enter_sent or !exit_sent or !saw_owned_vehicle) return error.VehicleTrialIncomplete;
    if (throttle_sent != throttle_ticks or brake_sent != brake_ticks or
        neutral_sent != neutral_ticks or character_sequence_sent == 0)
    {
        return error.VehicleTrialInputIncomplete;
    }
    if (client.pending_vehicle_action != null or client.ownedVehicle() != null) {
        return error.VehicleTrialDidNotExit;
    }
    var action_result: ?protocol.VehicleActionResult = null;
    while (client.takeVehicleActionResult()) |result| action_result = result;
    const final_action_result = action_result orelse return error.VehicleTrialMissingActionResult;
    if (final_action_result.action != .exit or final_action_result.disposition != .exited) {
        return error.VehicleTrialExitRejected;
    }
    _ = last_authority_snapshot orelse return error.VehicleTrialMissingSnapshot;
    const final_snapshot = snapshotFromClientWorld(&client);
    const final_vehicle = last_relevant_vehicle orelse return error.VehicleTrialMissingVehicle;
    const initial_position = initial_vehicle_position orelse return error.VehicleTrialMissingVehicle;
    const movement = distance(initial_position, final_vehicle.position);
    if (movement < 5) return error.VehicleTrialMovementTooSmall;

    const client_diagnostics = client.diagnostics();
    const authority_diagnostics = authority.diagnostics();
    const link_diagnostics = link.diagnostics();
    if (client_diagnostics.vehicle_actions_accepted != 2 or
        client_diagnostics.vehicle_actions_rejected != 0 or
        authority_diagnostics.vehicle_actions_accepted != 2 or
        authority_diagnostics.vehicle_actions_rejected != 0)
    {
        return error.VehicleActionAccountingMismatch;
    }
    if (!immediate_response_observed) return error.VehiclePredictionDidNotRespondLocally;
    if (client_diagnostics.vehicle_prediction.initialized or
        client_diagnostics.vehicle_prediction.history_overflows != 0 or
        client_diagnostics.vehicle_prediction.ownership_resets == 0)
    {
        return error.VehiclePredictionLifecycleMismatch;
    }
    const prediction = client_diagnostics.vehicle_prediction;
    if (!expect_blackout and
        (prediction.hard_corrections != 0 or
            prediction.maximum_position_error_m >=
                budgets.vehicle_prediction_thresholds.hard_position_error_m or
            prediction.maximum_orientation_error_degrees >=
                budgets.vehicle_prediction_thresholds.hard_orientation_error_degrees))
    {
        return error.VehiclePredictionCorrectionBudgetExceeded;
    }
    const allowed_soft_corrections =
        (@as(u64, budgets.vehicle_prediction_thresholds.maximum_soft_corrections_per_minute) *
            total_ticks + budgets.authority_tick_hz * 60 - 1) /
        (budgets.authority_tick_hz * 60);
    if (prediction.soft_corrections > allowed_soft_corrections) {
        return error.VehiclePredictionCorrectionRateExceeded;
    }
    if (expect_blackout and prediction.horizon_clamps == 0) {
        return error.VehiclePredictionHorizonWasNotExercised;
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
    } else if (link_diagnostics.client_to_authority.blackout_drops == 0 or
        link_diagnostics.authority_to_client.blackout_drops == 0)
    {
        return error.BlackoutDidNotManufactureVehicleLoss;
    }

    var records: [budgets.accepted_ingress_capacity]authority_module.AcceptedIngress = undefined;
    const record_count = authority.copyAcceptedIngress(&records);
    authority.deinit();
    authority_live = false;
    try verifyAcceptedIngressReplay(
        records[0..record_count],
        client.account,
        final_snapshot,
    );

    return .{
        .name = name,
        .seed = config.seed,
        .movement_m = movement,
        .maximum_snapshot_age_ticks = maximum_snapshot_age_ticks,
        .accepted_actions = authority_diagnostics.vehicle_actions_accepted,
        .rejected_actions = authority_diagnostics.vehicle_actions_rejected,
        .invalid_controls = authority_diagnostics.invalid_control_inputs,
        .ingress_fingerprint = authority_diagnostics.ingress_fingerprint,
        .vehicle_prediction = client_diagnostics.vehicle_prediction,
        .link = link_diagnostics,
    };
}

fn verifyAcceptedIngressReplay(
    records: []const authority_module.AcceptedIngress,
    account: @FieldType(protocol.Hello, "account"),
    expected: protocol.Snapshot,
) !void {
    if (records.len == 0) return error.AcceptedIngressJournalWasEmpty;
    const replay = try authority_module.DedicatedAuthority.init(std.heap.page_allocator);
    defer replay.deinit();
    const connection = authority_module.TransportConnection{ .value = 1 };
    _ = try replay.openConnection(connection);
    try replay.ingest(connection, .{ .hello = .{ .account = account } });
    try replay.tick();
    const welcome = takeOutbound(replay).?.message.welcome;
    var cursor: usize = 0;
    var last_snapshot: ?protocol.Snapshot = null;
    for (0..total_ticks) |_| {
        const tick = replay.diagnostics().tick;
        while (cursor < records.len and records[cursor].admitted_tick == tick) : (cursor += 1) {
            const record = records[cursor];
            const message: protocol.ClientMessage = switch (record.kind) {
                .character => .{ .input = .{
                    .session = welcome.session,
                    .participant = welcome.participant,
                    .sequence = record.sequence,
                    .target_tick = record.target_tick,
                    .move = record.move,
                    .facing_yaw = record.facing_yaw,
                    .jump_pressed = record.jump_pressed,
                } },
                .vehicle => .{ .vehicle_input = .{
                    .session = welcome.session,
                    .participant = welcome.participant,
                    .sequence = record.sequence,
                    .target_tick = record.target_tick,
                    .vehicle = record.vehicle,
                    .throttle = record.vehicle_control[0],
                    .steering = record.vehicle_control[1],
                    .brake = record.vehicle_control[2],
                    .hand_brake = record.vehicle_control[3],
                } },
                .vehicle_enter, .vehicle_exit => .{ .vehicle_action = .{
                    .session = welcome.session,
                    .participant = welcome.participant,
                    .sequence = record.action_sequence,
                    .vehicle = record.vehicle,
                    .kind = if (record.kind == .vehicle_enter) .enter else .exit,
                } },
                .interaction_collect, .interaction_drop => .{ .interaction_action = .{
                    .session = welcome.session,
                    .participant = welcome.participant,
                    .sequence = record.action_sequence,
                    .carryable = record.carryable,
                    .kind = if (record.kind == .interaction_collect) .collect else .drop,
                } },
                .melee => .{ .melee_action = .{
                    .session = welcome.session,
                    .participant = welcome.participant,
                    .sequence = record.action_sequence,
                    .avatar_incarnation = record.avatar_incarnation,
                    .target_tick = record.target_tick,
                } },
                .respawn => .{ .respawn_action = .{
                    .session = welcome.session,
                    .participant = welcome.participant,
                    .sequence = record.action_sequence,
                    .dead_incarnation = record.avatar_incarnation,
                } },
            };
            try replay.ingest(connection, message);
        }
        try replay.tick();
        while (takeOutbound(replay)) |outbound| switch (outbound.message) {
            .snapshot => |snapshot| {
                last_snapshot = switch (snapshot.kind) {
                    .full => snapshot,
                    .delta => try protocol.materializeDelta(
                        last_snapshot orelse return error.AcceptedIngressReplayMissingDeltaBase,
                        snapshot,
                    ),
                };
                try replay.ingest(connection, .{ .snapshot_ack = .{
                    .session = welcome.session,
                    .participant = welcome.participant,
                    .baseline_id = snapshot.baseline_id,
                    .sequence = snapshot.sequence,
                } });
            },
            .relevance_baseline => |baseline| {
                last_snapshot = baseline.snapshot;
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
    const actual = last_snapshot orelse return error.AcceptedIngressReplayMissingState;
    if (actual.character_count != expected.character_count or
        actual.vehicle_count != expected.vehicle_count or
        actual.npc_count != expected.npc_count)
    {
        return error.AcceptedIngressMembershipDivergence;
    }
    for (expected.slice(), actual.slice()) |expected_character, actual_character| {
        if (!std.meta.eql(expected_character.entity, actual_character.entity) or
            !std.meta.eql(expected_character.owner, actual_character.owner))
        {
            return error.AcceptedIngressCharacterDivergence;
        }
        if (expected_character.incarnation != actual_character.incarnation or
            expected_character.health != actual_character.health or
            expected_character.maximum_health != actual_character.maximum_health or
            expected_character.life_state != actual_character.life_state)
        {
            return error.AcceptedIngressVitalsDivergence;
        }
        if (distance(expected_character.position, actual_character.position) > 0.0001 or
            distance(expected_character.velocity, actual_character.velocity) > 0.0001)
        {
            return error.AcceptedIngressCharacterDivergence;
        }
    }
    for (expected.vehicleSlice(), actual.vehicleSlice()) |expected_vehicle, actual_vehicle| {
        if (!std.meta.eql(expected_vehicle.entity, actual_vehicle.entity) or
            !std.meta.eql(expected_vehicle.driver, actual_vehicle.driver) or
            distance(expected_vehicle.position, actual_vehicle.position) > 0.0001 or
            distance(expected_vehicle.linear_velocity, actual_vehicle.linear_velocity) > 0.0001 or
            distance(expected_vehicle.angular_velocity, actual_vehicle.angular_velocity) > 0.0001 or
            quaternionDifference(expected_vehicle.rotation, actual_vehicle.rotation) > 0.0001)
        {
            return error.AcceptedIngressVehicleDivergence;
        }
    }
    for (expected.npcSlice(), actual.npcSlice()) |expected_npc, actual_npc| {
        if (!std.meta.eql(expected_npc.entity, actual_npc.entity) or
            expected_npc.incarnation != actual_npc.incarnation or
            expected_npc.health != actual_npc.health or
            expected_npc.maximum_health != actual_npc.maximum_health or
            expected_npc.life_state != actual_npc.life_state)
        {
            return error.AcceptedIngressVitalsDivergence;
        }
    }
}

fn snapshotFromClientWorld(client: *const session_client.Client) protocol.Snapshot {
    var snapshot = protocol.Snapshot.empty();
    snapshot.baseline_id = client.active_baseline_id;
    snapshot.sequence = client.world.sequence;
    snapshot.server_tick = client.world.server_tick;
    for (client.world.slice()) |entry| {
        snapshot.characters[snapshot.character_count] = entry.current;
        snapshot.character_count += 1;
    }
    for (client.world.vehicleSlice()) |entry| {
        snapshot.vehicles[snapshot.vehicle_count] = entry.current;
        snapshot.vehicle_count += 1;
    }
    for (client.world.carryableSlice()) |entry| {
        snapshot.carryables[snapshot.carryable_count] = entry.current;
        snapshot.carryable_count += 1;
    }
    snapshot.npc_update = true;
    for (client.world.npcSlice()) |entry| {
        snapshot.npcs[snapshot.npc_count] = entry.current;
        snapshot.npc_count += 1;
    }
    return snapshot;
}

fn distance(a: [3]f32, b: [3]f32) f32 {
    const x = a[0] - b[0];
    const y = a[1] - b[1];
    const z = a[2] - b[2];
    return @sqrt(x * x + y * y + z * z);
}

fn quaternionDifference(a: [4]f32, b: [4]f32) f32 {
    var direct: f32 = 0;
    var negated: f32 = 0;
    for (a, b) |left, right| {
        direct = @max(direct, @abs(left - right));
        negated = @max(negated, @abs(left + right));
    }
    return @min(direct, negated);
}

fn report(result: Result) !void {
    const up = result.link.client_to_authority;
    const down = result.link.authority_to_client;
    std.debug.print(
        "MP4_TRIAL profile={s} seed={d} movement_m={d:.2} snapshot_age_ticks={d} " ++
            "actions={d}/{d} invalid_controls={d} " ++
            "prediction_soft/hard/clamped={d}/{d}/{d} prediction_error={d:.3}m/{d:.2}deg/{d:.2}mps " ++
            "up_sent/delivered/lost/dup/reorder={d}/{d}/{d}/{d}/{d} " ++
            "down_sent/delivered/lost/dup/reorder={d}/{d}/{d}/{d}/{d} " ++
            "bytes_per_second={d}/{d} queue_high={d}/{d} ingress={x}\n",
        .{
            result.name,
            result.seed,
            result.movement_m,
            result.maximum_snapshot_age_ticks,
            result.accepted_actions,
            result.rejected_actions,
            result.invalid_controls,
            result.vehicle_prediction.soft_corrections,
            result.vehicle_prediction.hard_corrections,
            result.vehicle_prediction.horizon_clamps,
            result.vehicle_prediction.maximum_position_error_m,
            result.vehicle_prediction.maximum_orientation_error_degrees,
            result.vehicle_prediction.maximum_velocity_error_mps,
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
