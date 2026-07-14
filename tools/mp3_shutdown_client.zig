//! Presentation-free process probe for reliable authority-stop delivery over
//! the real GNS adapter.

const std = @import("std");
const budgets = @import("session_budgets");
const protocol = @import("session_protocol");
const session_client = @import("session_client");
const transport_policy = @import("session_transport_policy");
const gns = @import("gns_direct");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const endpoint = if (args.len == 2) args[1] else return error.ExpectedEndpoint;
    if (endpoint.len == 0 or endpoint.len >= 256) return error.InvalidEndpoint;
    var endpoint_storage: [256]u8 = @splat(0);
    const endpoint_z = try std.fmt.bufPrintZ(&endpoint_storage, "{s}", .{endpoint});

    var network = try gns.Network.init();
    defer network.deinit();
    var connection = try network.connect(endpoint_z);
    defer if (connection.isValid()) {
        network.close(connection, 1000, "shutdown probe complete", .immediate);
    };
    var client = try session_client.Client.init(.{ .value = 81_001 });
    var receive_storage: [budgets.max_wire_message_bytes]u8 = undefined;
    var encode_storage: [budgets.max_wire_message_bytes]u8 = undefined;
    const start = std.Io.Clock.Timestamp.now(init.io, .awake);
    var joined = false;

    while (elapsedNs(start, std.Io.Clock.Timestamp.now(init.io, .awake)) <
        10 * std.time.ns_per_s)
    {
        network.runCallbacks();
        while (network.pollEvent()) |event| switch (event.new_state) {
            .connected => if (event.connection.value == connection.value) {
                try network.configureConnected(connection);
                const hello = try client.begin();
                const bytes = try protocol.encodeClient(hello, &encode_storage);
                const class = transport_policy.clientClass(hello);
                try network.send(
                    connection,
                    bytes,
                    toGnsDelivery(class.delivery),
                    toGnsLane(class.lane),
                );
            },
            .closed_by_peer, .problem_detected_locally => {
                if (event.connection.value == connection.value) {
                    connection = .invalid;
                    if (client.state == .stopped and
                        client.disconnect_reason == .authority_stopping)
                    {
                        std.debug.print("MP3_SHUTDOWN_CLIENT_PASS joined={}\n", .{joined});
                        return;
                    }
                    return error.TransportClosedBeforeAuthorityStop;
                }
            },
            .none, .connecting, .finding_route => {},
        };
        if (connection.isValid()) {
            while (try network.receive(connection, &receive_storage)) |received| {
                const message = (try protocol.decodeDeliveredServer(received.bytes)).message;
                if (!transport_policy.matches(
                    transport_policy.serverClass(message),
                    fromGnsDelivery(received.delivery),
                    fromGnsLane(received.lane),
                )) return error.ServerDeliveryClassMismatch;
                try client.receive(message);
                if (client.takeBaselineAck()) |ack| {
                    const bytes = try protocol.encodeClient(ack, &encode_storage);
                    const class = transport_policy.clientClass(ack);
                    try network.send(
                        connection,
                        bytes,
                        toGnsDelivery(class.delivery),
                        toGnsLane(class.lane),
                    );
                }
                if (client.takeSnapshotAck()) |ack| {
                    const bytes = try protocol.encodeClient(ack, &encode_storage);
                    const class = transport_policy.clientClass(ack);
                    try network.send(
                        connection,
                        bytes,
                        toGnsDelivery(class.delivery),
                        toGnsLane(class.lane),
                    );
                }
                if (message == .welcome) joined = true;
                if (client.state == .rejected) return error.ShutdownProbeRejected;
                if (client.state == .stopped) {
                    if (client.disconnect_reason != .authority_stopping) {
                        return error.UnexpectedTerminalReason;
                    }
                    std.debug.print("MP3_SHUTDOWN_CLIENT_PASS joined={}\n", .{joined});
                    return;
                }
            }
        }
        try std.Io.sleep(init.io, .fromMilliseconds(1), .awake);
    }
    return error.AuthorityStopTimeout;
}

fn elapsedNs(start: std.Io.Clock.Timestamp, end: std.Io.Clock.Timestamp) u64 {
    const nanoseconds = start.durationTo(end).raw.nanoseconds;
    if (nanoseconds <= 0) return 0;
    return std.math.cast(u64, nanoseconds) orelse std.math.maxInt(u64);
}

fn toGnsDelivery(value: transport_policy.Delivery) gns.Delivery {
    return if (value == .reliable) .reliable else .unreliable;
}

fn fromGnsDelivery(value: gns.Delivery) transport_policy.Delivery {
    return if (value == .reliable) .reliable else .unreliable;
}

fn toGnsLane(value: transport_policy.Lane) gns.Lane {
    return @enumFromInt(@intFromEnum(value));
}

fn fromGnsLane(value: gns.Lane) transport_policy.Lane {
    return @enumFromInt(@intFromEnum(value));
}
