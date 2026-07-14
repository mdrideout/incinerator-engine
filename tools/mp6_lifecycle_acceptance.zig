//! Deterministic selectable MP6 room-lifecycle/fault acceptance.

const std = @import("std");
const budgets = @import("session_budgets");
const room = @import("session_room");
const coordinator_module = @import("room_coordinator");
const impaired_link = @import("impaired_link");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const impairment = try parseImpairment(args);
    var link = try impaired_link.Link.init(configFor(impairment));
    defer link.deinit();

    var coordinator = coordinator_module.Coordinator{};
    coordinator.setImpairment(impairment);
    const first_generation = try coordinator.begin(.join);
    var members = [_]coordinator_module.Member{
        .{
            .account = .{ .value = 1 },
            .lobby_present = true,
            .ready = false,
            .connection = .none,
            .local = true,
        },
        .{
            .account = .{ .value = 2 },
            .lobby_present = true,
            .ready = true,
            .connection = .connected,
            .local = false,
        },
    };
    _ = try coordinator.completeJoin(first_generation, try joinIntent(), &members);
    _ = try coordinator.markReady(first_generation);
    _ = try coordinator.beginRouteResolution(first_generation);
    _ = try coordinator.routeResolved(first_generation);
    _ = try coordinator.transportConnected(first_generation);
    _ = try coordinator.authorityAccepted(first_generation);
    _ = try coordinator.synchronized(first_generation);

    try link.advanceTo(if (impairment == .blackout) 5 else 0);
    try link.sendFromClient(.{ .input = .{
        .session = .{ .value = 1 },
        .participant = .{ .index = 1, .generation = 1 },
        .sequence = .{ .value = 1 },
        .target_tick = 1,
        .move = .{ 1, 0 },
        .facing_yaw = 0,
        .jump_pressed = false,
    } });
    try link.advanceTo(100);
    _ = link.receiveForAuthority();
    const fault_diagnostics = link.diagnostics();
    if (impairment == .blackout and
        fault_diagnostics.client_to_authority.blackout_drops != 1)
    {
        return error.BlackoutWasNotManufactured;
    }

    const reconnect_generation = try coordinator.networkLost();
    const stale = try coordinator.replaceMemberPresentation(first_generation, &members);
    if (stale != .stale) return error.StaleCompletionMutatedNewAttempt;
    _ = try coordinator.transportConnected(reconnect_generation);
    _ = try coordinator.authorityAccepted(reconnect_generation);
    _ = try coordinator.synchronized(reconnect_generation);
    try coordinator.lobbyDeparted(.{ .value = 2 });
    const view = coordinator.view();
    if (view.state != .playable or view.generation != reconnect_generation or
        view.stale_completions != 1 or view.memberSlice()[1].lobby_present)
    {
        return error.RoomLifecycleInvariantFailed;
    }

    std.debug.print(
        "MP6_LIFECYCLE_PASS impairment={s} generation={d} stale={d} blackout_drops={d} lobby_independent=true reconnect=true\n",
        .{
            @tagName(impairment),
            view.generation,
            view.stale_completions,
            fault_diagnostics.client_to_authority.blackout_drops,
        },
    );
}

fn parseImpairment(args: []const []const u8) !coordinator_module.Impairment {
    if (args.len != 3 or !std.mem.eql(u8, args[1], "--impairment")) {
        return error.InvalidArguments;
    }
    inline for (std.meta.tags(coordinator_module.Impairment)) |value| {
        if (std.mem.eql(u8, args[2], @tagName(value))) return value;
    }
    return error.UnknownImpairment;
}

fn configFor(value: coordinator_module.Impairment) impaired_link.Config {
    return switch (value) {
        .clean => .{
            .seed = 0x4d50_3600,
            .one_way_latency_ticks = 0,
            .jitter_ticks = 0,
            .loss_per_10k = 0,
            .duplicate_per_10k = 0,
            .reorder_per_10k = 0,
        },
        .nominal => impaired_link.Config.fromProfile(0x4d50_3601, budgets.nominal_profile),
        .adverse => impaired_link.Config.fromProfile(0x4d50_3602, budgets.adverse_profile),
        .blackout => .{
            .seed = 0x4d50_3603,
            .one_way_latency_ticks = 1,
            .jitter_ticks = 0,
            .loss_per_10k = 0,
            .duplicate_per_10k = 0,
            .reorder_per_10k = 0,
            .blackout = .{ .first_tick = 5, .end_tick = 10 },
        },
    };
}

fn joinIntent() !room.JoinIntent {
    const authenticator: [32]u8 = @splat(1);
    return .{
        .room_id = .{ .value = 6001 },
        .authority_id = 9001,
        .account = .{ .value = 1 },
        .external_identity = .{ .provider = .development, .subject = 1 },
        .placement = .listen,
        .route = .{ .direct_ip = try room.DirectEndpoint.init("127.0.0.1:27021") },
        .authorization = .{
            .room_id = 6001,
            .authority_id = 9001,
            .room_generation = 1,
            .nonce = 1,
            .expires_at_unix_seconds = 100,
            .authenticator = authenticator,
        },
    };
}

test "MP6 impairment selection rejects unknown values" {
    try std.testing.expectError(
        error.UnknownImpairment,
        parseImpairment(&.{ "acceptance", "--impairment", "chaos" }),
    );
}
