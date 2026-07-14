//! Cold macOS MP2 authority process using direct-IP GameNetworkingSockets.

const std = @import("std");
const budgets = @import("session_budgets");
const protocol = @import("session_protocol");
const authority_module = @import("session_authority");
const transport_policy = @import("session_transport_policy");
const gns = @import("gns_direct");

const max_ticks_per_pump: u8 = 8;
const default_port: u16 = 27_020;
const shutdown_linger_ms: u64 = 100;

const Invocation = struct {
    port: u16 = default_port,
    max_ticks: ?u64 = null,
    allow_remote: bool = false,
};

const TransportDiagnostics = struct {
    sampled_connections: u16 = 0,
    maximum_ping_ms: i32 = 0,
    outgoing_bytes_per_second: f32 = 0,
    incoming_bytes_per_second: f32 = 0,
    pending_unreliable_bytes: i64 = 0,
    pending_reliable_bytes: i64 = 0,
};

const Server = struct {
    network: gns.Network,
    listen_socket: gns.ListenSocket,
    authority: authority_module.Authority,
    connections: [budgets.max_participants]gns.Connection = @splat(.invalid),
    receive_storage: [budgets.max_wire_message_bytes]u8 = undefined,
    encode_storage: [budgets.max_wire_message_bytes]u8 = undefined,

    fn init(allocator: std.mem.Allocator, port: u16, allow_remote: bool) !Server {
        var network = try gns.Network.init();
        errdefer network.deinit();
        const listen_socket = try network.listen(
            port,
            if (allow_remote) .any_interface else .loopback,
        );
        errdefer network.closeListen(listen_socket);
        var authority = try authority_module.Authority.init(allocator);
        errdefer authority.deinit();
        return .{
            .network = network,
            .listen_socket = listen_socket,
            .authority = authority,
        };
    }

    fn deinit(self: *Server) void {
        for (self.connections) |connection| {
            if (connection.isValid()) {
                self.network.close(connection, 1000, "authority stopping", .immediate);
            }
        }
        self.network.closeListen(self.listen_socket);
        self.authority.deinit();
        self.network.deinit();
        self.* = undefined;
    }

    fn stop(self: *Server, io: std.Io) !void {
        try self.authority.stop();
        try self.flushAuthorityOutput();
        // Give the GNS networking thread a bounded opportunity to transmit the
        // reliable terminal message before global transport teardown.
        try std.Io.sleep(io, .fromMilliseconds(shutdown_linger_ms), .awake);
        self.network.runCallbacks();
        while (self.network.pollEvent()) |event| try self.handleEvent(event);
    }

    fn pumpNetwork(self: *Server) !void {
        self.network.runCallbacks();
        while (self.network.pollEvent()) |event| try self.handleEvent(event);
        for (&self.connections) |*connection| {
            if (!connection.isValid()) continue;
            var received_count: usize = 0;
            while (received_count < budgets.inbound_message_capacity) : (received_count += 1) {
                const received = self.network.receive(
                    connection.*,
                    &self.receive_storage,
                ) catch |err| switch (err) {
                    error.ReceivedMessageTooLarge => {
                        try self.authority.rejectOversized(.{ .value = connection.value });
                        break;
                    },
                    else => return err,
                } orelse break;
                const message = protocol.decodeClient(received.bytes) catch {
                    try self.authority.ingestBytes(
                        .{ .value = connection.value },
                        received.bytes,
                    );
                    continue;
                };
                if (!transport_policy.matches(
                    transport_policy.clientClass(message),
                    fromGnsDelivery(received.delivery),
                    fromGnsLane(received.lane),
                )) {
                    self.network.close(
                        connection.*,
                        4001,
                        "protocol delivery class mismatch",
                        .immediate,
                    );
                    self.authority.transportClosed(.{ .value = connection.value });
                    connection.* = .invalid;
                    break;
                }
                try self.authority.ingest(.{ .value = connection.value }, message);
            }
        }
        try self.flushAuthorityOutput();
    }

    fn tick(self: *Server) !void {
        try self.authority.tick();
        try self.flushAuthorityOutput();
    }

    fn handleEvent(self: *Server, event: gns.Event) !void {
        switch (event.new_state) {
            .connecting => {
                if (event.listen_socket.value == self.listen_socket.value) {
                    try self.network.accept(event.connection);
                }
            },
            .connected => {
                if (self.findConnection(event.connection) == null) {
                    const slot = self.freeConnectionSlot() orelse {
                        self.network.close(
                            event.connection,
                            4002,
                            "server connection capacity",
                            .immediate,
                        );
                        return;
                    };
                    _ = self.authority.openConnection(.{ .value = event.connection.value }) catch {
                        self.network.close(
                            event.connection,
                            4002,
                            "authority connection capacity",
                            .immediate,
                        );
                        return;
                    };
                    self.connections[slot] = event.connection;
                    std.debug.print("MP2_CONNECTION opened transport={d}\n", .{event.connection.value});
                }
            },
            .closed_by_peer, .problem_detected_locally => {
                self.authority.transportClosed(.{ .value = event.connection.value });
                self.removeConnection(event.connection);
                self.network.close(
                    event.connection,
                    event.end_reason,
                    "transport terminal",
                    .immediate,
                );
                std.debug.print(
                    "MP2_CONNECTION closed transport={d} reason={d} detail={s}\n",
                    .{ event.connection.value, event.end_reason, event.debugText() },
                );
            },
            .none, .finding_route => {},
        }
    }

    fn flushAuthorityOutput(self: *Server) !void {
        while (self.authority.pollOutbound()) |outbound| {
            const connection = gns.Connection{ .value = outbound.connection.value };
            if (self.findConnection(connection) == null) continue;
            const bytes = try protocol.encodeServer(outbound.message, &self.encode_storage);
            self.network.send(
                connection,
                bytes,
                switch (outbound.delivery) {
                    .unreliable => .unreliable,
                    .reliable => .reliable,
                },
                switch (outbound.lane) {
                    .input => .input,
                    .snapshot => .snapshot,
                    .gameplay => .gameplay,
                    .control => .control,
                },
            ) catch |err| {
                if (outbound.delivery == .reliable) return err;
            };
            if (outbound.close_after_send) {
                self.network.close(connection, 1000, "session closed", .linger);
                self.removeConnection(connection);
            }
        }
    }

    fn freeConnectionSlot(self: *const Server) ?usize {
        for (self.connections, 0..) |connection, index| {
            if (!connection.isValid()) return index;
        }
        return null;
    }

    fn findConnection(self: *const Server, target: gns.Connection) ?usize {
        for (self.connections, 0..) |connection, index| {
            if (connection.value == target.value and connection.isValid()) return index;
        }
        return null;
    }

    fn removeConnection(self: *Server, target: gns.Connection) void {
        if (self.findConnection(target)) |index| self.connections[index] = .invalid;
    }

    fn transportDiagnostics(self: *Server) TransportDiagnostics {
        var result = TransportDiagnostics{};
        for (self.connections) |connection| {
            const stats = self.network.stats(connection) orelse continue;
            result.sampled_connections += 1;
            result.maximum_ping_ms = @max(result.maximum_ping_ms, stats.ping_ms);
            result.outgoing_bytes_per_second += stats.out_bytes_per_second;
            result.incoming_bytes_per_second += stats.in_bytes_per_second;
            result.pending_unreliable_bytes += stats.pending_unreliable_bytes;
            result.pending_reliable_bytes += stats.pending_reliable_bytes;
        }
        return result;
    }
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const invocation = try parseInvocation(args);
    var server = try Server.init(init.gpa, invocation.port, invocation.allow_remote);
    defer server.deinit();

    std.debug.print(
        "MP2_SERVER_READY endpoint={s}:{d} authority_hz={d} snapshot_hz={d} " ++
            "identity=unauthenticated-development\n",
        .{
            if (invocation.allow_remote) "0.0.0.0" else "127.0.0.1",
            invocation.port,
            budgets.authority_tick_hz,
            budgets.snapshot_hz,
        },
    );

    const start = std.Io.Clock.Timestamp.now(init.io, .awake);
    var completed_ticks: u64 = 0;
    var last_reported_tick: u64 = 0;
    while (invocation.max_ticks == null or completed_ticks < invocation.max_ticks.?) {
        try server.pumpNetwork();
        const elapsed = elapsedNs(start, std.Io.Clock.Timestamp.now(init.io, .awake));
        const due = (@as(u128, elapsed) * budgets.authority_tick_hz) / std.time.ns_per_s;
        const due_ticks = std.math.cast(u64, due) orelse return error.ServerClockRangeExceeded;
        const granted = @min(due_ticks -| completed_ticks, max_ticks_per_pump);
        var remaining = granted;
        while (remaining > 0) : (remaining -= 1) {
            try server.tick();
            completed_ticks += 1;
        }
        if (completed_ticks -| last_reported_tick >= 300) {
            const diagnostics = server.authority.diagnostics();
            const transport = server.transportDiagnostics();
            std.debug.print(
                "MP2_SERVER tick={d} connections={d} participants={d} reconnecting={d} " ++
                    "outbox_high={d} accepted={d} rejected={d} malformed={d} snapshots={d} " ++
                    "vehicle_actions={d}/{d} forced_cleanup={d} " ++
                    "ping_max_ms={d} out_Bps={d:.0} in_Bps={d:.0} pending={d}/{d} " ++
                    "dropped_events={d}\n",
                .{
                    diagnostics.tick,
                    diagnostics.active_connections,
                    diagnostics.active_participants,
                    diagnostics.reconnecting_participants,
                    diagnostics.outbox_high_water,
                    diagnostics.accepted_messages,
                    diagnostics.rejected_messages,
                    diagnostics.malformed_messages,
                    diagnostics.snapshots_emitted,
                    diagnostics.vehicle_actions_accepted,
                    diagnostics.vehicle_actions_rejected,
                    diagnostics.forced_vehicle_cleanup,
                    transport.maximum_ping_ms,
                    transport.outgoing_bytes_per_second,
                    transport.incoming_bytes_per_second,
                    transport.pending_unreliable_bytes,
                    transport.pending_reliable_bytes,
                    server.network.droppedEvents(),
                },
            );
            last_reported_tick = completed_ticks;
        }
        if (granted == 0) {
            try std.Io.sleep(init.io, .fromMilliseconds(1), .awake);
        }
    }
    const diagnostics = server.authority.diagnostics();
    try server.stop(init.io);
    std.debug.print(
        "MP2_SERVER_STOP tick={d} participants={d} snapshots={d} forced_cleanup={d}\n",
        .{
            diagnostics.tick,
            diagnostics.active_participants,
            diagnostics.snapshots_emitted,
            diagnostics.forced_vehicle_cleanup,
        },
    );
}

fn fromGnsDelivery(value: gns.Delivery) transport_policy.Delivery {
    return if (value == .reliable) .reliable else .unreliable;
}

fn fromGnsLane(value: gns.Lane) transport_policy.Lane {
    return @enumFromInt(@intFromEnum(value));
}

fn parseInvocation(args: []const []const u8) !Invocation {
    var result = Invocation{};
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--port")) {
            index += 1;
            if (index >= args.len) return error.MissingPort;
            result.port = try std.fmt.parseInt(u16, args[index], 10);
            if (result.port == 0) return error.InvalidPort;
        } else if (std.mem.eql(u8, args[index], "--max-ticks")) {
            index += 1;
            if (index >= args.len) return error.MissingMaxTicks;
            result.max_ticks = try std.fmt.parseInt(u64, args[index], 10);
        } else if (std.mem.eql(u8, args[index], "--allow-remote")) {
            result.allow_remote = true;
        } else return error.UnknownArgument;
    }
    return result;
}

fn elapsedNs(start: std.Io.Clock.Timestamp, end: std.Io.Clock.Timestamp) u64 {
    const nanoseconds = start.durationTo(end).raw.nanoseconds;
    if (nanoseconds <= 0) return 0;
    return std.math.cast(u64, nanoseconds) orelse std.math.maxInt(u64);
}

test "MP2 ingress lanes match the accepted protocol classes" {
    const message = protocol.ClientMessage{ .hello = .{ .account = .{ .value = 1 } } };
    try std.testing.expect(transport_policy.matches(
        transport_policy.clientClass(message),
        .reliable,
        .control,
    ));
    try std.testing.expect(!transport_policy.matches(
        transport_policy.clientClass(message),
        .unreliable,
        .input,
    ));
}

test "MP2 authority is loopback-only unless remote exposure is explicit" {
    const local = try parseInvocation(&.{"server"});
    try std.testing.expect(!local.allow_remote);
    const remote = try parseInvocation(&.{ "server", "--allow-remote" });
    try std.testing.expect(remote.allow_remote);
}
