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

const Result = struct {
    name: []const u8,
    seed: u64,
    movement_m: f32,
    maximum_snapshot_age_ticks: u64,
    accepted_actions: u64,
    rejected_actions: u64,
    invalid_controls: u64,
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
    var authority = try authority_module.Authority.init(std.heap.page_allocator);
    var authority_live = true;
    defer if (authority_live) authority.deinit();
    var client = try session_client.Client.init(.{ .value = config.seed + 20_000 });
    var link = try impaired.Link.init(config);
    const connection = authority_module.TransportConnection{ .value = 1 };
    _ = try authority.openConnection(connection);
    try link.sendFromClient(try client.begin());

    var initial_vehicle_position: ?[3]f32 = null;
    var last_authority_snapshot: ?protocol.Snapshot = null;
    var maximum_snapshot_age_ticks: u64 = 0;
    var enter_sent = false;
    var exit_sent = false;
    var saw_owned_vehicle = false;
    var throttle_sent: u64 = 0;
    var brake_sent: u64 = 0;
    var neutral_sent: u64 = 0;
    var character_sequence_sent: u64 = 0;

    for (0..total_ticks) |tick| {
        try link.advanceTo(tick);
        while (link.receiveForAuthority()) |message| try authority.ingest(connection, message);
        try authority.tick();
        while (authority.pollOutbound()) |outbound| {
            if (outbound.close_after_send) return error.VehicleTrialSessionTerminated;
            if (outbound.message == .snapshot) last_authority_snapshot = outbound.message.snapshot;
            try link.sendFromAuthority(outbound.message);
        }
        while (link.receiveForClient()) |message| try client.receive(message);

        if (client.world.initialized) {
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
                try link.sendFromClient(try client.vehicleInput(
                    authority.diagnostics().tick + 1,
                    vehicle.entity,
                    1,
                    0,
                    0,
                    0,
                ));
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
    const action_result = client.last_vehicle_action_result orelse
        return error.VehicleTrialMissingActionResult;
    if (action_result.action != .exit or action_result.disposition != .exited) {
        return error.VehicleTrialExitRejected;
    }
    const final_snapshot = last_authority_snapshot orelse return error.VehicleTrialMissingSnapshot;
    if (final_snapshot.vehicle_count != 1) return error.VehicleTrialMissingVehicle;
    const initial_position = initial_vehicle_position orelse return error.VehicleTrialMissingVehicle;
    const movement = distance(initial_position, final_snapshot.vehicles[0].position);
    if (movement < 5) return error.VehicleTrialMovementTooSmall;
    if (final_snapshot.vehicles[0].driver != null) return error.VehicleTrialOwnershipNotReleased;

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
        .link = link_diagnostics,
    };
}

fn verifyAcceptedIngressReplay(
    records: []const authority_module.AcceptedIngress,
    account: @FieldType(protocol.Hello, "account"),
    expected: protocol.Snapshot,
) !void {
    if (records.len == 0) return error.AcceptedIngressJournalWasEmpty;
    var replay = try authority_module.Authority.init(std.heap.page_allocator);
    defer replay.deinit();
    const connection = authority_module.TransportConnection{ .value = 1 };
    _ = try replay.openConnection(connection);
    try replay.ingest(connection, .{ .hello = .{ .account = account } });
    const welcome = replay.pollOutbound().?.message.welcome;
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
            };
            try replay.ingest(connection, message);
        }
        try replay.tick();
        while (replay.pollOutbound()) |outbound| switch (outbound.message) {
            .snapshot => |snapshot| last_snapshot = snapshot,
            else => {},
        };
    }
    if (cursor != records.len) return error.AcceptedIngressReplayDidNotConsumeJournal;
    const actual = last_snapshot orelse return error.AcceptedIngressReplayMissingState;
    if (actual.character_count != expected.character_count or
        actual.vehicle_count != expected.vehicle_count)
    {
        return error.AcceptedIngressMembershipDivergence;
    }
    for (expected.slice(), actual.slice()) |expected_character, actual_character| {
        if (!std.meta.eql(expected_character.entity, actual_character.entity) or
            !std.meta.eql(expected_character.owner, actual_character.owner) or
            distance(expected_character.position, actual_character.position) > 0.0001 or
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
