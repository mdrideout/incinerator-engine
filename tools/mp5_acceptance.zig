//! MP5 open room/invite/session-placement acceptance. No Steamworks SDK or
//! live service is required; Steam remains an opaque optional provider seam.

const std = @import("std");
const protocol = @import("session_protocol");
const room_module = @import("session_room");
const session_client = @import("session_client");
const authority_module = @import("session_authority");

const secret: protocol.AdmissionSecret = @splat(0x5a);

pub fn main(init: std.process.Init) !void {
    _ = init;
    const endpoint = try room_module.DirectEndpoint.init("127.0.0.1:27020");
    var intents: [2]room_module.JoinIntent = undefined;
    {
        var registry = room_module.Registry{};
        const handle = try registry.create(.{
            .id = .{ .value = 77 },
            .authority_id = 9_001,
            .placement = .dedicated,
            .route = .{ .direct_ip = endpoint },
            .host = .{ .value = 1 },
            .secret = secret,
        });
        for (&intents, 0..) |*intent, index| {
            const account_value = @as(u64, index) + 2;
            const invite_value = try registry.invite(
                handle,
                .{ .value = account_value },
                .{ .provider = .development, .subject = account_value },
                10,
                120,
            );
            if (index == 0) {
                try std.testing.expectError(
                    error.InviteExpired,
                    registry.join(invite_value, 131),
                );
            }
            intent.* = try registry.join(invite_value, 11);
            try registry.setReady(handle, intent.account, true);
            try registry.beginConnect(handle, intent.account);
            try registry.connected(handle, intent.account);
        }
        try registry.leaveLobby(handle, intents[0].account);
        if ((try registry.memberView(handle, intents[0].account)).connection != .connected) {
            return error.LobbyLeaveTerminatedGameplayConnection;
        }
        try registry.networkDisconnected(handle, intents[1].account);
        const disconnected = try registry.memberView(handle, intents[1].account);
        if (!disconnected.lobby_present or disconnected.connection != .reconnecting) {
            return error.NetworkDisconnectRemovedLobbyMembership;
        }
    }

    // The registry/service is now out of scope. Already admitted authority
    // operation must not depend on its availability.
    var authority = try authority_module.Authority.initWithOptions(
        std.heap.page_allocator,
        .{
            .room_admission = .{
                .room_id = 77,
                .authority_id = 9_001,
                .room_generation = intents[0].authorization.room_generation,
                .secret = secret,
            },
        },
    );
    defer authority.deinit();

    var clockless = try session_client.Client.init(intents[0].account);
    try clockless.configureJoin(intents[0].external_identity, intents[0].authorization);
    const clockless_connection = authority_module.TransportConnection{ .value = 98 };
    _ = try authority.openConnection(clockless_connection);
    try std.testing.expectError(
        error.RoomAdmissionRequiresTimestampedIngress,
        authority.ingest(clockless_connection, try clockless.begin()),
    );
    authority.transportClosed(clockless_connection);

    // A ticket is bound to its account/external identity and fails before any
    // participant state is allocated.
    var impostor = try session_client.Client.init(.{ .value = 99 });
    try impostor.configureJoin(
        .{ .provider = .development, .subject = 99 },
        intents[0].authorization,
    );
    const bad_connection = authority_module.TransportConnection{ .value = 99 };
    _ = try authority.openConnection(bad_connection);
    try authority.ingestAtUnixTime(bad_connection, try impostor.begin(), 11);
    var rejected = false;
    while (authority.pollOutbound()) |outbound| switch (outbound.message) {
        .rejected => |value| rejected = value.reason == .unauthorized,
        else => return error.ImpostorReceivedPartialSessionState,
    };
    if (!rejected or authority.diagnostics().active_participants != 0) {
        return error.IdentityBoundAdmissionFailed;
    }

    var clients = [2]session_client.Client{
        try session_client.Client.init(intents[0].account),
        try session_client.Client.init(intents[1].account),
    };
    const connections = [2]authority_module.TransportConnection{
        .{ .value = 1 },
        .{ .value = 2 },
    };
    for (&clients, intents, connections) |*client, intent, connection| {
        try client.configureJoin(intent.external_identity, intent.authorization);
        _ = try authority.openConnection(connection);
        try authority.ingestAtUnixTime(connection, try client.begin(), 11);
    }

    for (0..180) |_| {
        for (&clients, connections) |*client, connection| {
            if (client.state == .joined and client.world.initialized and
                client.ownedVehicle() == null)
            {
                try authority.ingest(connection, try client.input(
                    authority.diagnostics().tick + 1,
                    .{ 0, 1 },
                    0,
                    false,
                ));
            }
        }
        try authority.tick();
        while (authority.pollOutbound()) |outbound| {
            const index: usize = if (outbound.connection.value == 1) 0 else 1;
            const client = &clients[index];
            try client.receive(outbound.message);
            if (client.takeBaselineAck()) |ack| try authority.ingest(connections[index], ack);
            if (client.takeSnapshotAck()) |ack| try authority.ingest(connections[index], ack);
        }
    }

    const diagnostics = authority.diagnostics();
    if (diagnostics.active_participants != 2 or diagnostics.connected_participants != 2) {
        return error.InvitedPlayersDidNotReachAuthority;
    }
    for (clients) |client| {
        if (client.state != .joined or !client.world.initialized or
            client.diagnostics().snapshots_applied == 0)
        {
            return error.InvitedClientDidNotReceiveGameplayState;
        }
    }
    std.debug.print(
        "MP5_ROOM_PASS room=77 authority=9001 participants={d} " ++
            "identity_rejection=true service_independent=true route={s}\n",
        .{ diagnostics.active_participants, endpoint.slice() },
    );
}
