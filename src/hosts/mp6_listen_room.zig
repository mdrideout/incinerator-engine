//! MP6 constrained private-listen composition.
//!
//! One embedded authority owns gameplay. The host client reaches it through
//! the typed local link while invited guests use a loopback/LAN GNS listener.
//! The room registry owns discovery state only, and the graphical host sees a
//! sanitized generation-safe coordinator view.

const std = @import("std");
const budgets = @import("session_budgets");
const identity = @import("session_identity");
const protocol = @import("session_protocol");
const combat_presentation = @import("combat_presentation");
const room = @import("session_room");
const room_coordinator = @import("room_coordinator");
const room_ticket = @import("room_ticket");
const session_client = @import("session_client");
const authority_module = @import("session_authority");
const local_link = @import("session_local_link");
const transport_policy = @import("session_transport_policy");
const gns = @import("gns_direct");

const host_transport = authority_module.TransportConnection{ .value = 0xffff_fffe };
const invite_lifetime_seconds: u64 = 24 * 60 * 60;

pub const Config = struct {
    port: u16 = 27_021,
    room_id: u64 = 6_101,
    authority_id: u64 = 9_101,
    host_account: identity.AccountId = .{ .value = 1 },
    guest_account: identity.AccountId = .{ .value = 2 },
    advertise_host: []const u8 = "127.0.0.1",
    allow_remote: bool = false,
};

const GuestConnection = struct {
    transport: gns.Connection = .invalid,
    account: ?identity.AccountId = null,
};

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    network: gns.Network,
    listen_socket: gns.ListenSocket,
    authority: *authority_module.EmbeddedAuthority,
    registry: room.Registry,
    room_handle: room.Handle,
    host_intent: room.JoinIntent,
    guest_intent: room.JoinIntent,
    coordinator: room_coordinator.Coordinator,
    coordinator_generation: u64,
    host_link: local_link.Link = .{},
    client: session_client.Client,
    guest_connections: [budgets.max_participants]GuestConnection = @splat(.{}),
    receive_storage: [budgets.max_wire_message_bytes]u8 = undefined,
    encode_storage: [budgets.max_wire_message_bytes]u8 = undefined,
    combat_feedback: combat_presentation.FeedbackQueue = .{},
    guest_input_ingress: transport_policy.InputIngressBudget(
        budgets.max_participants,
        budgets.max_input_messages_per_tick,
    ) = .{},
    closed: bool = false,

    pub fn create(
        allocator: std.mem.Allocator,
        config: Config,
        now_unix_seconds: u64,
    ) !*Runtime {
        try validateConfig(config);
        const result = try allocator.create(Runtime);
        errdefer allocator.destroy(result);
        var network = try gns.Network.init();
        errdefer network.deinit();
        const listen_socket = try network.listen(
            config.port,
            if (config.allow_remote) .any_interface else .loopback,
        );
        errdefer network.closeListen(listen_socket);

        var secret: protocol.AdmissionSecret = undefined;
        std.c.arc4random_buf(secret[0..].ptr, secret.len);
        defer std.crypto.secureZero(u8, &secret);
        if (std.mem.allEqual(u8, &secret, 0)) return error.SecureRoomEntropyFailed;

        var registry = room.Registry{};
        var endpoint_storage: [room.max_endpoint_bytes]u8 = undefined;
        const endpoint = try std.fmt.bufPrint(
            &endpoint_storage,
            "{s}:{d}",
            .{ config.advertise_host, config.port },
        );
        const room_handle = try registry.create(.{
            .id = .{ .value = config.room_id },
            .authority_id = config.authority_id,
            .placement = .listen,
            .route = .{ .direct_ip = try room.DirectEndpoint.init(endpoint) },
            .host = config.host_account,
            .secret = secret,
        });
        const host_intent = try joinAccount(
            &registry,
            room_handle,
            config.host_account,
            now_unix_seconds,
        );
        const guest_intent = try joinAccount(
            &registry,
            room_handle,
            config.guest_account,
            now_unix_seconds,
        );
        try registry.setReady(room_handle, config.host_account, true);
        try registry.beginConnect(room_handle, config.host_account);

        const authority = try authority_module.EmbeddedAuthority.initWithOptions(
            allocator,
            embeddedCoreConfig(),
            .{ .room_admission = .{
                .room_id = config.room_id,
                .authority_id = config.authority_id,
                .room_generation = host_intent.authorization.room_generation,
                .secret = secret,
            } },
        );
        errdefer authority.deinit();

        var client = try session_client.Client.init(config.host_account);
        try client.configureJoin(
            host_intent.external_identity,
            host_intent.authorization,
        );
        var coordinator = room_coordinator.Coordinator{};
        const generation = try coordinator.begin(.create_private);
        var members = [_]room_coordinator.Member{
            .{
                .account = config.host_account,
                .lobby_present = true,
                .ready = false,
                .connection = .none,
                .local = true,
            },
            .{
                .account = config.guest_account,
                .lobby_present = true,
                .ready = false,
                .connection = .none,
                .local = false,
            },
        };
        _ = try coordinator.completeJoin(
            generation,
            host_intent,
            &members,
        );
        _ = try coordinator.markReady(generation);
        _ = try coordinator.beginRouteResolution(generation);
        _ = try coordinator.routeResolved(generation);
        _ = try coordinator.transportConnected(generation);

        result.* = .{
            .allocator = allocator,
            .network = network,
            .listen_socket = listen_socket,
            .authority = authority,
            .registry = registry,
            .room_handle = room_handle,
            .host_intent = host_intent,
            .guest_intent = guest_intent,
            .coordinator = coordinator,
            .coordinator_generation = generation,
            .client = client,
        };
        errdefer result.deinit();
        _ = try result.authority.session().openConnection(host_transport);
        try result.host_link.sendFromClient(try result.client.begin());
        for (0..8) |_| {
            try result.step(now_unix_seconds);
            if (result.coordinator.view().state == .playable) break;
        }
        if (result.coordinator.view().state != .playable) {
            return error.ListenHostAdmissionFailed;
        }
        return result;
    }

    pub fn destroy(self: *Runtime) void {
        const allocator = self.allocator;
        self.deinit();
        allocator.destroy(self);
    }

    pub fn deinit(self: *Runtime) void {
        for (self.guest_connections) |connection| {
            if (connection.transport.isValid()) {
                self.network.close(
                    connection.transport,
                    1000,
                    "listen room teardown",
                    .immediate,
                );
            }
        }
        self.network.closeListen(self.listen_socket);
        self.authority.deinit();
        self.network.deinit();
        std.crypto.secureZero(u8, std.mem.asBytes(&self.registry));
        self.* = undefined;
    }

    pub fn writeGuestTicket(
        self: *const Runtime,
        io: std.Io,
        path: []const u8,
    ) !void {
        var artifact = room_ticket.Artifact{
            .intent = self.guest_intent,
            .member_count = 2,
        };
        artifact.members[0] = self.host_intent.account;
        artifact.members[1] = self.guest_intent.account;
        var storage: [room_ticket.maximum_bytes]u8 = undefined;
        const bytes = try room_ticket.encode(artifact, &storage);
        var atomic = try std.Io.Dir.cwd().createFileAtomic(io, path, .{
            .permissions = std.Io.File.Permissions.fromMode(0o600),
            .make_path = true,
            .replace = true,
        });
        defer atomic.deinit(io);
        try atomic.file.writeStreamingAll(io, bytes);
        try atomic.replace(io);
    }

    pub fn step(self: *Runtime, now_unix_seconds: u64) !void {
        if (self.closed) return error.ListenRoomClosed;
        self.network.runCallbacks();
        while (self.network.pollEvent()) |event| try self.handleEvent(event);
        try self.receiveGuestIngress(now_unix_seconds);
        try self.receiveHostIngress(now_unix_seconds);
        try self.authority.session().tick();
        try self.flushAuthorityOutput();
        try self.receiveHostEgress();
        try self.receiveHostIngress(now_unix_seconds);
        if (self.network.droppedEvents() != 0) return error.TransportEventOverflow;
    }

    pub fn sendHostInput(
        self: *Runtime,
        move: [2]f32,
        facing_yaw: f32,
        jump_pressed: bool,
    ) !void {
        if (self.client.state != .joined) return;
        try self.host_link.sendFromClient(try self.client.input(
            self.authority.session().diagnostics().tick + 1,
            normalizedMove(move),
            facing_yaw,
            jump_pressed,
        ));
    }

    pub fn sendHostVehicleInput(
        self: *Runtime,
        throttle: f32,
        steering: f32,
        brake: f32,
        hand_brake: f32,
    ) !void {
        const vehicle = self.client.ownedVehicle() orelse return;
        try self.host_link.sendFromClient(try self.client.vehicleInput(
            self.authority.session().diagnostics().tick + 1,
            vehicle.entity,
            throttle,
            steering,
            brake,
            hand_brake,
        ));
    }

    pub fn toggleHostVehicle(self: *Runtime) !void {
        if (self.client.state != .joined or self.client.pending_vehicle_action != null) return;
        const message = if (self.client.ownedVehicle()) |vehicle|
            try self.client.vehicleAction(.exit, vehicle.entity)
        else blk: {
            const vehicles = self.client.world.vehicleSlice();
            if (vehicles.len == 0) return;
            break :blk try self.client.vehicleAction(.enter, vehicles[0].current.entity);
        };
        try self.host_link.sendFromClient(message);
    }

    pub fn toggleHostCarry(self: *Runtime) !void {
        if (self.client.state != .joined or
            self.client.pending_interaction_action != null or
            self.client.ownedVehicle() != null) return;
        const message = if (self.client.heldCarryable()) |held|
            try self.client.interactionAction(.drop, held.entity)
        else blk: {
            const carryables = self.client.world.carryableSlice();
            if (carryables.len == 0) return;
            break :blk try self.client.interactionAction(
                .collect,
                carryables[0].current.entity,
            );
        };
        try self.host_link.sendFromClient(message);
    }

    pub fn requestHostMelee(self: *Runtime) !void {
        if (self.client.state != .joined or self.client.pending_melee_action != null) return;
        if (self.client.ownedVehicle() != null) return;
        try self.host_link.sendFromClient(try self.client.meleeAction(
            self.authority.session().diagnostics().tick +| 1,
        ));
    }

    pub fn requestHostRespawn(self: *Runtime) !void {
        if (self.client.state != .joined or self.client.pending_respawn_action != null) return;
        try self.host_link.sendFromClient(try self.client.respawnAction());
    }

    pub fn roomView(self: *const Runtime) room_coordinator.View {
        return self.coordinator.view();
    }

    pub fn takeCombatFeedback(self: *Runtime) ?combat_presentation.Feedback {
        return self.combat_feedback.pop();
    }

    pub fn close(self: *Runtime, io: std.Io) !void {
        if (self.closed) return;
        const generation = try self.coordinator.beginDrain();
        try self.registry.beginDrain(self.room_handle);
        try self.authority.session().stop();
        try self.flushAuthorityOutput();
        try self.receiveHostEgress();
        try std.Io.sleep(io, .fromMilliseconds(100), .awake);
        self.network.runCallbacks();
        try self.registry.close(self.room_handle);
        _ = try self.coordinator.closed(generation);
        self.closed = true;
    }

    fn handleEvent(self: *Runtime, event: gns.Event) !void {
        switch (event.new_state) {
            .connecting => if (event.listen_socket.value == self.listen_socket.value) {
                try self.network.accept(event.connection);
            },
            .connected => if (event.listen_socket.value == self.listen_socket.value and
                self.findGuest(event.connection) == null)
            {
                const slot = self.freeGuest() orelse {
                    self.network.close(
                        event.connection,
                        4002,
                        "listen room capacity",
                        .immediate,
                    );
                    return;
                };
                _ = self.authority.session().openConnection(.{
                    .value = event.connection.value,
                }) catch {
                    self.network.close(
                        event.connection,
                        4002,
                        "authority connection capacity",
                        .immediate,
                    );
                    return;
                };
                self.guest_connections[slot].transport = event.connection;
            },
            .closed_by_peer, .problem_detected_locally => {
                if (self.findGuest(event.connection)) |index| {
                    const connection = self.guest_connections[index];
                    _ = try self.authority.session().transportClosed(.{
                        .value = event.connection.value,
                    });
                    if (connection.account) |account| {
                        self.noteGuestDisconnected(account);
                    }
                    self.guest_connections[index] = .{};
                    try self.refreshMembers();
                }
                self.network.close(
                    event.connection,
                    event.end_reason,
                    "listen transport terminal",
                    .immediate,
                );
            },
            .none, .finding_route => {},
        }
    }

    fn receiveGuestIngress(self: *Runtime, now_unix_seconds: u64) !void {
        self.guest_input_ingress.beginTick(self.authority.session().diagnostics().tick);
        for (&self.guest_connections, 0..) |*connection, connection_index| {
            if (!connection.transport.isValid()) continue;
            if (!self.guest_input_ingress.available(connection_index)) continue;
            var count: usize = 0;
            while (count < budgets.inbound_message_capacity) : (count += 1) {
                const received = try self.network.receive(
                    connection.transport,
                    &self.receive_storage,
                ) orelse break;
                const message = protocol.decodeClient(received.bytes) catch {
                    try self.authority.session().ingestBytes(
                        .{ .value = connection.transport.value },
                        received.bytes,
                    );
                    continue;
                };
                if (!transport_policy.matches(
                    transport_policy.clientClass(message),
                    fromGnsDelivery(received.delivery),
                    fromGnsLane(received.lane),
                )) {
                    try self.terminateGuest(
                        connection_index,
                        4001,
                        "protocol delivery class mismatch",
                    );
                    break;
                }
                if (message == .hello) {
                    const account = message.hello.account;
                    if (connection.account == null) {
                        connection.account = account;
                    } else if (!std.meta.eql(connection.account.?, account)) {
                        try self.terminateGuest(
                            connection_index,
                            4003,
                            "connection account changed",
                        );
                        break;
                    }
                }
                try self.authority.session().ingestAtUnixTime(
                    .{ .value = connection.transport.value },
                    message,
                    now_unix_seconds,
                );
                if (transport_policy.isClientInputSample(message)) {
                    std.debug.assert(self.guest_input_ingress.consume(connection_index));
                    if (!self.guest_input_ingress.available(connection_index)) break;
                }
            }
        }
    }

    fn receiveHostIngress(self: *Runtime, now_unix_seconds: u64) !void {
        while (self.host_link.receiveForAuthority()) |message| {
            try self.authority.session().ingestAtUnixTime(
                host_transport,
                message,
                now_unix_seconds,
            );
        }
    }

    fn flushAuthorityOutput(self: *Runtime) !void {
        while (self.authority.session().beginOutboundLease()) |lease| {
            const outbound = lease.outbound;
            if (std.meta.eql(outbound.connection, host_transport)) {
                self.host_link.sendFromAuthority(.{
                    .delivery_id = outbound.delivery_id,
                    .message = outbound.message,
                }) catch |err| {
                    try self.authority.session().retryOutboundLease(lease.generation);
                    return err;
                };
            } else {
                const connection = gns.Connection{ .value = outbound.connection.value };
                if (self.findGuest(connection) == null) {
                    try self.authority.session().commitOutboundLease(lease.generation);
                    continue;
                }
                const bytes = try protocol.encodeDeliveredServer(.{
                    .delivery_id = outbound.delivery_id,
                    .message = outbound.message,
                }, &self.encode_storage);
                self.network.send(
                    connection,
                    bytes,
                    toGnsDelivery(outbound.delivery),
                    toGnsLane(outbound.lane),
                ) catch |err| {
                    if (outbound.delivery == .reliable) {
                        try self.authority.session().retryOutboundLease(lease.generation);
                        return err;
                    }
                };
                if (outbound.message == .welcome) {
                    if (self.findGuest(connection)) |index| {
                        if (self.guest_connections[index].account) |account| {
                            try self.registry.setReady(self.room_handle, account, true);
                            try self.registry.beginConnect(self.room_handle, account);
                            try self.registry.connected(self.room_handle, account);
                            try self.refreshMembers();
                        }
                    }
                } else if (outbound.message == .rejected) {
                    if (self.findGuest(connection)) |index| {
                        if (self.guest_connections[index].account) |account| {
                            self.registry.connectFailed(
                                self.room_handle,
                                account,
                                mapConnectFailure(outbound.message.rejected.reason),
                            ) catch {};
                            try self.refreshMembers();
                        }
                    }
                }
            }
            try self.authority.session().commitOutboundLease(lease.generation);
            if (outbound.close_after_send and !std.meta.eql(outbound.connection, host_transport)) {
                const connection = gns.Connection{ .value = outbound.connection.value };
                self.network.close(connection, 1000, "session terminal", .linger);
                _ = try self.authority.session().transportClosed(outbound.connection);
                if (self.findGuest(connection)) |index| self.guest_connections[index] = .{};
            }
        }
    }

    fn receiveHostEgress(self: *Runtime) !void {
        while (self.host_link.receiveForClient()) |delivered| {
            const message = delivered.message;
            try self.client.receiveDelivered(delivered);
            while (self.client.takeVehicleActionResult()) |result| {
                std.debug.print(
                    "MP6_LISTEN_HOST_VEHICLE action={s} result={s}\n",
                    .{ @tagName(result.action), @tagName(result.disposition) },
                );
            }
            while (self.client.takeInteractionActionResult()) |result| {
                std.debug.print(
                    "MP6_LISTEN_HOST_CARRY action={s} result={s}\n",
                    .{ @tagName(result.action), @tagName(result.disposition) },
                );
            }
            while (self.client.takeMeleeActionResult()) |result| {
                try self.combat_feedback.push(.{ .melee = result });
                std.debug.print(
                    "S10_LISTEN_HOST_MELEE result={s} damage={d} health={d} killed={}\n",
                    .{
                        @tagName(result.disposition),
                        result.applied_damage,
                        result.remaining_health,
                        result.killed,
                    },
                );
            }
            while (self.client.takeRespawnActionResult()) |result| {
                try self.combat_feedback.push(.{ .respawn = result });
                std.debug.print(
                    "S10_LISTEN_HOST_RESPAWN result={s} incarnation={d}\n",
                    .{ @tagName(result.disposition), result.incarnation },
                );
            }
            while (self.client.takeLifeEvent()) |event| {
                try self.combat_feedback.push(.{ .life = event });
                std.debug.print(
                    "S10_LISTEN_HOST_LIFE avatar={d}:{d} incarnation={d} state={s} health={d}\n",
                    .{
                        event.avatar.index,
                        event.avatar.generation,
                        event.incarnation,
                        @tagName(event.state),
                        event.health,
                    },
                );
            }
            while (self.client.takeDeliveryReceipt()) |receipt| {
                try self.host_link.sendFromClient(receipt);
            }
            if (self.client.takeBaselineAck()) |ack| try self.host_link.sendFromClient(ack);
            if (self.client.takeSnapshotAck()) |ack| try self.host_link.sendFromClient(ack);
            switch (message) {
                .welcome => {
                    _ = try self.coordinator.authorityAccepted(self.coordinator_generation);
                    try self.registry.connected(self.room_handle, self.host_intent.account);
                    try self.refreshMembers();
                },
                .snapshot, .relevance_baseline => if (self.client.world.initialized and
                    self.coordinator.view().state == .synchronizing)
                {
                    _ = try self.coordinator.synchronized(self.coordinator_generation);
                    try self.refreshMembers();
                },
                .rejected => |value| {
                    _ = try self.coordinator.fail(
                        self.coordinator_generation,
                        failureFromRejection(value.reason),
                        true,
                    );
                },
                else => {},
            }
        }
    }

    fn refreshMembers(self: *Runtime) !void {
        const host = try self.registry.memberView(self.room_handle, self.host_intent.account);
        const guest = try self.registry.memberView(self.room_handle, self.guest_intent.account);
        const members = [_]room_coordinator.Member{
            fromMemberView(host, true),
            fromMemberView(guest, false),
        };
        _ = try self.coordinator.replaceMemberPresentation(
            self.coordinator_generation,
            &members,
        );
    }

    fn findGuest(self: *const Runtime, transport: gns.Connection) ?usize {
        for (self.guest_connections, 0..) |connection, index| {
            if (connection.transport.isValid() and
                connection.transport.value == transport.value) return index;
        }
        return null;
    }

    fn freeGuest(self: *const Runtime) ?usize {
        for (self.guest_connections, 0..) |connection, index| {
            if (!connection.transport.isValid()) return index;
        }
        return null;
    }

    fn terminateGuest(
        self: *Runtime,
        index: usize,
        reason: i32,
        detail: [:0]const u8,
    ) !void {
        const connection = self.guest_connections[index];
        if (!connection.transport.isValid()) return;
        _ = try self.authority.session().transportClosed(.{
            .value = connection.transport.value,
        });
        if (connection.account) |account| {
            self.noteGuestDisconnected(account);
        }
        self.network.close(connection.transport, reason, detail, .immediate);
        self.guest_connections[index] = .{};
        try self.refreshMembers();
    }

    fn noteGuestDisconnected(self: *Runtime, account: identity.AccountId) void {
        const member = self.registry.memberView(self.room_handle, account) catch return;
        switch (member.connection) {
            .connecting, .connected, .reconnecting => self.registry.networkDisconnected(
                self.room_handle,
                account,
            ) catch {},
            .none, .failed => {},
        }
    }
};

fn embeddedCoreConfig() authority_module.CoreConfig {
    return .{
        .simulation = .{
            .namespace = 0x4d50_3601,
            .fixed_delta_seconds = 1.0 /
                @as(f32, @floatFromInt(budgets.authority_tick_hz)),
            .create_ground = true,
            .character = .{ .max_characters = budgets.max_participants },
            .vehicle = .{
                .max_vehicles = budgets.max_vehicles,
                .max_entry_distance = 5,
            },
        },
        .world_bootstrap = .dedicated_fixture,
        .participant_spawn = .automatic,
        .observation = .disabled,
        .npc_interest = .full_world,
    };
}

fn validateConfig(config: Config) !void {
    if (config.port == 0 or config.room_id == 0 or config.authority_id == 0 or
        config.advertise_host.len == 0)
    {
        return error.InvalidListenRoomConfig;
    }
    try config.host_account.validate();
    try config.guest_account.validate();
    if (std.meta.eql(config.host_account, config.guest_account)) {
        return error.DuplicateRoomAccount;
    }
    if (config.allow_remote and std.mem.eql(u8, config.advertise_host, "127.0.0.1")) {
        return error.RemoteRoomRequiresAdvertisedHost;
    }
}

fn joinAccount(
    registry: *room.Registry,
    handle: room.Handle,
    account: identity.AccountId,
    now_unix_seconds: u64,
) !room.JoinIntent {
    const invite = try registry.invite(
        handle,
        account,
        .{ .provider = .development, .subject = account.value },
        now_unix_seconds,
        invite_lifetime_seconds,
    );
    return registry.join(invite, now_unix_seconds);
}

fn fromMemberView(value: room.MemberView, local: bool) room_coordinator.Member {
    return .{
        .account = value.account,
        .lobby_present = value.lobby_present,
        .ready = value.ready,
        .connection = value.connection,
        .local = local,
    };
}

fn normalizedMove(value: [2]f32) [2]f32 {
    const length_squared = value[0] * value[0] + value[1] * value[1];
    if (length_squared <= 1) return value;
    const scale = 1.0 / @sqrt(length_squared);
    return .{ value[0] * scale, value[1] * scale };
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

fn mapConnectFailure(reason: protocol.RejectionReason) room.ConnectFailure {
    return switch (reason) {
        .protocol_mismatch, .build_mismatch, .content_mismatch => .version_mismatch,
        .session_full => .authority_full,
        .unauthorized, .reconnect_expired => .authorization_rejected,
        else => .route_unavailable,
    };
}

fn failureFromRejection(reason: protocol.RejectionReason) room_coordinator.Failure {
    return switch (reason) {
        .protocol_mismatch, .build_mismatch => .version_mismatch,
        .content_mismatch => .content_mismatch,
        .session_full => .room_full,
        .unauthorized => .authorization_rejected,
        .reconnect_expired => .reconnect_expired,
        else => .authority_unavailable,
    };
}

test "listen room config keeps remote exposure explicit" {
    try std.testing.expectError(
        error.RemoteRoomRequiresAdvertisedHost,
        validateConfig(.{ .allow_remote = true }),
    );
    try validateConfig(.{
        .allow_remote = true,
        .advertise_host = "192.168.1.25",
    });
}
