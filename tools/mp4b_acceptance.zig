//! MP4-B carry-interaction acceptance over deterministic manufactured faults.
//! Real-GNS two-client contention remains covered by mp2_loopback.zig.

const std = @import("std");
const budgets = @import("session_budgets");
const protocol = @import("session_protocol");
const session_client = @import("session_client");
const authority_module = @import("session_authority");
const impaired = @import("impaired_link");

const total_ticks: u64 = 600;

const Result = struct {
    name: []const u8,
    seed: u64,
    completed_tick: u64,
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
    try report(try runTrial("clean", clean));

    const nominal_config = impaired.Config.fromProfile(71, budgets.nominal_profile);
    const nominal = try runTrial("nominal", nominal_config);
    const repeat = try runTrial("nominal-repeat", nominal_config);
    if (nominal.completed_tick != repeat.completed_tick or
        nominal.ingress_fingerprint != repeat.ingress_fingerprint or
        !std.meta.eql(nominal.link, repeat.link))
    {
        return error.InteractionTrialWasNotDeterministic;
    }
    try report(nominal);

    var adverse = impaired.Config.fromProfile(307, budgets.adverse_profile);
    adverse.blackout = .{ .first_tick = 120, .end_tick = 180 };
    try report(try runTrial("adverse-blackout", adverse));
    try verifyDisconnectCleanup();
}

fn runTrial(name: []const u8, config: impaired.Config) !Result {
    const authority = try authority_module.DedicatedAuthority.init(std.heap.page_allocator);
    defer authority.deinit();
    var client = try session_client.Client.init(.{ .value = config.seed + 40_000 });
    var link = try impaired.Link.init(config);
    defer link.deinit();
    const connection = authority_module.TransportConnection{ .value = 1 };
    _ = try authority.openConnection(connection);
    try link.sendFromClient(try client.begin());

    var collect_sent = false;
    var drop_sent = false;
    var completed_tick: ?u64 = null;
    var target = @FieldType(protocol.InteractionAction, "carryable").invalid;

    for (0..total_ticks) |tick| {
        try link.advanceTo(tick);
        while (link.receiveForAuthority()) |message| try authority.ingest(connection, message);
        try authority.tick();
        while (authority.pollOutbound()) |outbound| {
            if (outbound.close_after_send) return error.InteractionTrialSessionTerminated;
            try link.sendFromAuthority(outbound.message);
        }
        while (link.receiveForClient()) |message| {
            try client.receive(message);
            if (client.takeBaselineAck()) |ack| try link.sendFromClient(ack);
            if (client.takeSnapshotAck()) |ack| try link.sendFromClient(ack);
        }

        if (client.state != .joined or !client.world.initialized) continue;
        if (!collect_sent and client.world.carryableSlice().len == 1) {
            target = client.world.carryableSlice()[0].current.entity;
            try link.sendFromClient(try client.interactionAction(.collect, target));
            collect_sent = true;
            continue;
        }
        if (collect_sent and !drop_sent and client.heldCarryable() != null and
            client.pending_interaction_action == null)
        {
            try link.sendFromClient(try client.interactionAction(.drop, target));
            drop_sent = true;
            continue;
        }
        if (drop_sent and client.pending_interaction_action == null and
            client.heldCarryable() == null)
        {
            while (client.takeInteractionActionResult()) |result| {
                if (result.action == .drop and result.disposition == .dropped) {
                    completed_tick = authority.diagnostics().tick;
                    break;
                }
            }
            if (completed_tick != null) break;
        }
    }

    const completion = completed_tick orelse return error.InteractionTrialDidNotComplete;
    const authority_diagnostics = authority.diagnostics();
    const client_diagnostics = client.diagnostics();
    const link_diagnostics = link.diagnostics();
    if (authority_diagnostics.interaction_actions_accepted != 2 or
        authority_diagnostics.interaction_actions_rejected != 0 or
        client_diagnostics.interaction_actions_accepted != 2 or
        client_diagnostics.interaction_actions_rejected != 0)
    {
        return error.InteractionActionAccountingMismatch;
    }
    if (client.world.carryable_count != 1 or
        client.world.carryableSlice()[0].current.holder != null)
    {
        return error.InteractionFinalProjectionMismatch;
    }
    if (link_diagnostics.client_to_authority.queue_overflows != 0 or
        link_diagnostics.authority_to_client.queue_overflows != 0)
    {
        return error.InteractionImpairedQueueOverflow;
    }
    return .{
        .name = name,
        .seed = config.seed,
        .completed_tick = completion,
        .ingress_fingerprint = authority_diagnostics.ingress_fingerprint,
        .link = link_diagnostics,
    };
}

fn verifyDisconnectCleanup() !void {
    const authority = try authority_module.DedicatedAuthority.init(std.heap.page_allocator);
    defer authority.deinit();
    var client = try session_client.Client.init(.{ .value = 50_001 });
    const connection = authority_module.TransportConnection{ .value = 1 };
    _ = try authority.openConnection(connection);
    try authority.ingest(connection, try client.begin());
    try pumpDirect(authority, &client);

    for (0..10_000) |_| {
        try authority.tick();
        try drainDirect(authority, &client);
        if (client.world.carryable_count == 1) break;
        std.Thread.yield() catch {};
    }
    if (client.world.carryable_count != 1) return error.CleanupCarryableMissing;
    const carryable = client.world.carryableSlice()[0].current.entity;
    try authority.ingest(connection, try client.interactionAction(.collect, carryable));
    for (0..120) |_| {
        try authority.tick();
        try drainDirect(authority, &client);
        if (client.heldCarryable() != null) break;
    }
    if (client.heldCarryable() == null) return error.CleanupCollectFailed;

    try authority.ingest(connection, .{ .disconnect = .requested });
    while (authority.pollOutbound() != null) {}
    for (0..120) |_| {
        try authority.tick();
        while (authority.pollOutbound() != null) {}
        if (authority.diagnostics().active_participants == 0) break;
    }
    const diagnostics = authority.diagnostics();
    if (diagnostics.active_participants != 0 or
        diagnostics.active_carryables != 1 or
        diagnostics.forced_interaction_cleanup != 1)
    {
        return error.InteractionDisconnectCleanupFailed;
    }
    std.debug.print(
        "MP4B_CLEANUP_PASS carryables={d} forced_cleanup={d}\n",
        .{ diagnostics.active_carryables, diagnostics.forced_interaction_cleanup },
    );
}

fn pumpDirect(
    authority: *authority_module.DedicatedAuthority,
    client: *session_client.Client,
) !void {
    try authority.tick();
    try drainDirect(authority, client);
}

fn drainDirect(
    authority: *authority_module.DedicatedAuthority,
    client: *session_client.Client,
) !void {
    while (authority.pollOutbound()) |outbound| {
        try client.receive(outbound.message);
        if (client.takeBaselineAck()) |ack| {
            try authority.ingest(.{ .value = 1 }, ack);
        }
        if (client.takeSnapshotAck()) |ack| {
            try authority.ingest(.{ .value = 1 }, ack);
        }
    }
}

fn report(result: Result) !void {
    std.debug.print(
        "MP4B_TRIAL profile={s} seed={d} completed_tick={d} " ++
            "actions=2/0 up_loss={d} down_loss={d} ingress={x}\n",
        .{
            result.name,
            result.seed,
            result.completed_tick,
            result.link.client_to_authority.lost_messages,
            result.link.authority_to_client.lost_messages,
            result.ingress_fingerprint,
        },
    );
}
