//! Deterministic MP2 acceptance proof over real loopback GameNetworkingSockets.
//! One process owns a cold authority composition and two independent protocol
//! clients; no local-link shortcut is involved.

const std = @import("std");
const budgets = @import("session_budgets");
const protocol = @import("session_protocol");
const session_client = @import("session_client");
const authority_module = @import("session_authority");
const transport_policy = @import("session_transport_policy");
const gns = @import("gns_direct");

const default_port: u16 = 29_721;
const max_pump_steps: usize = 4_000;

const Peer = struct {
    client: session_client.Client,
    transport: gns.Connection = .invalid,
    connected_events: u32 = 0,
    terminal_events: u32 = 0,
    last_vehicle_action_result: ?protocol.VehicleActionResult = null,
    last_interaction_action_result: ?protocol.InteractionActionResult = null,
};

const Harness = struct {
    network: gns.Network,
    listen_socket: gns.ListenSocket,
    authority: *authority_module.DedicatedAuthority,
    peers: [2]Peer,
    server_connections: [budgets.max_participants]gns.Connection = @splat(.invalid),
    bad_transport: gns.Connection = .invalid,
    bad_hello_sent: bool = false,
    bad_rejection: ?protocol.RejectionReason = null,
    receive_storage: [budgets.max_wire_message_bytes]u8 = undefined,
    encode_storage: [budgets.max_wire_message_bytes]u8 = undefined,

    fn init(allocator: std.mem.Allocator, port: u16) !Harness {
        var network = try gns.Network.init();
        errdefer network.deinit();
        const listen_socket = try network.listen(port, .loopback);
        errdefer network.closeListen(listen_socket);
        const authority = try authority_module.DedicatedAuthority.init(allocator);
        errdefer authority.deinit();
        return .{
            .network = network,
            .listen_socket = listen_socket,
            .authority = authority,
            .peers = .{
                .{ .client = try session_client.Client.init(.{ .value = 10_001 }) },
                .{ .client = try session_client.Client.init(.{ .value = 10_002 }) },
            },
        };
    }

    fn deinit(self: *Harness) void {
        for (self.peers) |peer| {
            if (peer.transport.isValid()) {
                self.network.close(peer.transport, 1000, "acceptance complete", .immediate);
            }
        }
        if (self.bad_transport.isValid()) {
            self.network.close(self.bad_transport, 1000, "acceptance complete", .immediate);
        }
        for (self.server_connections) |connection| {
            if (connection.isValid()) {
                self.network.close(connection, 1000, "acceptance complete", .immediate);
            }
        }
        self.network.closeListen(self.listen_socket);
        self.authority.deinit();
        self.network.deinit();
        self.* = undefined;
    }

    fn connectPeer(self: *Harness, peer_index: usize, endpoint: [:0]const u8) !void {
        const peer = &self.peers[peer_index];
        if (peer.transport.isValid() or peer.client.state != .disconnected) {
            return error.PeerNotReadyToConnect;
        }
        peer.transport = try self.network.connect(endpoint);
    }

    fn connectBadCohort(self: *Harness, endpoint: [:0]const u8) !void {
        if (self.bad_transport.isValid()) return error.BadProbeAlreadyConnected;
        self.bad_transport = try self.network.connect(endpoint);
        self.bad_hello_sent = false;
        self.bad_rejection = null;
    }

    fn closePeerForReconnect(self: *Harness, peer_index: usize) !void {
        const peer = &self.peers[peer_index];
        if (!peer.transport.isValid() or peer.client.state != .joined) {
            return error.PeerNotJoined;
        }
        const transport = peer.transport;
        self.network.close(transport, 1001, "loopback reconnect proof", .immediate);
        // A locally initiated close is known synchronously; stop polling the
        // dead handle while the remote terminal callback enters reconnect grace.
        peer.transport = .invalid;
        peer.client.transportDisconnected();
    }

    fn sendInput(self: *Harness, peer_index: usize, move: [2]f32) !void {
        const peer = &self.peers[peer_index];
        const message = try peer.client.input(
            self.authority.diagnostics().tick + 1,
            move,
            0,
            false,
        );
        try self.sendClient(peer.transport, message);
    }

    fn sendVehicleInput(self: *Harness, peer_index: usize, throttle: f32) !void {
        const peer = &self.peers[peer_index];
        const vehicle = peer.client.ownedVehicle() orelse return error.PeerDoesNotOwnVehicle;
        const message = try peer.client.vehicleInput(
            self.authority.diagnostics().tick + 1,
            vehicle.entity,
            throttle,
            0,
            0,
            0,
        );
        try self.sendClient(peer.transport, message);
    }

    fn sendVehicleAction(
        self: *Harness,
        peer_index: usize,
        kind: protocol.VehicleActionKind,
        vehicle: @FieldType(protocol.VehicleState, "entity"),
    ) !void {
        const peer = &self.peers[peer_index];
        try self.sendClient(peer.transport, try peer.client.vehicleAction(kind, vehicle));
    }

    fn sendInteractionAction(
        self: *Harness,
        peer_index: usize,
        kind: protocol.InteractionActionKind,
        carryable: @FieldType(protocol.CarryableState, "entity"),
    ) !void {
        const peer = &self.peers[peer_index];
        try self.sendClient(peer.transport, try peer.client.interactionAction(kind, carryable));
    }

    fn step(self: *Harness, io: std.Io) !void {
        self.network.runCallbacks();
        while (self.network.pollEvent()) |event| try self.handleEvent(event);
        try self.receiveAuthorityIngress();
        try self.receivePeerEgress();
        try self.authority.tick();
        try self.flushAuthorityOutput();
        if (self.network.droppedEvents() != 0) return error.TransportEventOverflow;
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }

    fn handleEvent(self: *Harness, event: gns.Event) !void {
        switch (event.new_state) {
            .connecting => {
                if (event.listen_socket.value == self.listen_socket.value) {
                    try self.network.accept(event.connection);
                }
            },
            .connected => {
                if (self.findPeer(event.connection)) |peer_index| {
                    const peer = &self.peers[peer_index];
                    try self.network.configureConnected(event.connection);
                    try self.sendClient(event.connection, try peer.client.begin());
                    peer.connected_events +|= 1;
                } else if (event.connection.value == self.bad_transport.value) {
                    try self.network.configureConnected(event.connection);
                    try self.sendClient(event.connection, .{ .hello = .{
                        .build = protocol.build_cohort + 1,
                        .account = .{ .value = 99_999 },
                    } });
                    self.bad_hello_sent = true;
                } else if (event.listen_socket.value == self.listen_socket.value and
                    self.findServer(event.connection) == null)
                {
                    const slot = self.freeServerSlot() orelse return error.ServerConnectionCapacity;
                    _ = try self.authority.openConnection(.{ .value = event.connection.value });
                    self.server_connections[slot] = event.connection;
                }
            },
            .closed_by_peer, .problem_detected_locally => {
                if (self.findServer(event.connection)) |server_index| {
                    _ = try self.authority.transportClosed(.{ .value = event.connection.value });
                    self.server_connections[server_index] = .invalid;
                }
                if (self.findPeer(event.connection)) |peer_index| {
                    const peer = &self.peers[peer_index];
                    peer.transport = .invalid;
                    peer.client.transportDisconnected();
                    peer.terminal_events +|= 1;
                }
                if (event.connection.value == self.bad_transport.value) {
                    self.bad_transport = .invalid;
                }
                self.network.close(
                    event.connection,
                    event.end_reason,
                    "loopback terminal",
                    .immediate,
                );
            },
            .none, .finding_route => {},
        }
    }

    fn receiveAuthorityIngress(self: *Harness) !void {
        for (self.server_connections) |connection| {
            if (!connection.isValid()) continue;
            var count: usize = 0;
            while (count < budgets.inbound_message_capacity) : (count += 1) {
                const received = try self.network.receive(connection, &self.receive_storage) orelse
                    break;
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
                    return error.ClientDeliveryClassMismatch;
                }
                try self.authority.ingest(.{ .value = connection.value }, message);
            }
        }
    }

    fn receivePeerEgress(self: *Harness) !void {
        for (&self.peers) |*peer| {
            if (!peer.transport.isValid()) continue;
            var count: usize = 0;
            while (count < budgets.inbound_message_capacity) : (count += 1) {
                const received = try self.network.receive(
                    peer.transport,
                    &self.receive_storage,
                ) orelse break;
                const delivered = try protocol.decodeDeliveredServer(received.bytes);
                const message = delivered.message;
                if (!transport_policy.matches(
                    transport_policy.serverClass(message),
                    fromGnsDelivery(received.delivery),
                    fromGnsLane(received.lane),
                )) {
                    return error.ServerDeliveryClassMismatch;
                }
                try peer.client.receiveDelivered(delivered);
                while (peer.client.takeVehicleActionResult()) |result| {
                    peer.last_vehicle_action_result = result;
                }
                while (peer.client.takeInteractionActionResult()) |result| {
                    peer.last_interaction_action_result = result;
                }
                while (peer.client.takeDeliveryReceipt()) |receipt| {
                    try self.sendClient(peer.transport, receipt);
                }
                if (peer.client.takeBaselineAck()) |ack| {
                    try self.sendClient(peer.transport, ack);
                }
                if (peer.client.takeSnapshotAck()) |ack| {
                    try self.sendClient(peer.transport, ack);
                }
            }
        }
        if (!self.bad_transport.isValid()) return;
        var count: usize = 0;
        while (count < budgets.inbound_message_capacity) : (count += 1) {
            const received = try self.network.receive(
                self.bad_transport,
                &self.receive_storage,
            ) orelse break;
            const message = (try protocol.decodeDeliveredServer(received.bytes)).message;
            if (!transport_policy.matches(
                transport_policy.serverClass(message),
                fromGnsDelivery(received.delivery),
                fromGnsLane(received.lane),
            )) {
                return error.ServerDeliveryClassMismatch;
            }
            switch (message) {
                .rejected => |rejection| self.bad_rejection = rejection.reason,
                else => return error.BadCohortWasNotRejected,
            }
        }
    }

    fn flushAuthorityOutput(self: *Harness) !void {
        while (self.authority.beginOutboundLease()) |lease| {
            const outbound = lease.outbound;
            const connection = gns.Connection{ .value = outbound.connection.value };
            if (self.findServer(connection) == null) {
                try self.authority.commitOutboundLease(lease.generation);
                continue;
            }
            const bytes = try protocol.encodeDeliveredServer(.{
                .delivery_id = outbound.delivery_id,
                .message = outbound.message,
            }, &self.encode_storage);
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
                if (outbound.delivery == .reliable) {
                    try self.authority.retryOutboundLease(lease.generation);
                    return err;
                }
                try self.authority.commitOutboundLease(lease.generation);
                continue;
            };
            try self.authority.commitOutboundLease(lease.generation);
            if (outbound.close_after_send) {
                self.network.close(connection, 1000, "session rejection", .linger);
                _ = try self.authority.transportClosed(.{ .value = connection.value });
                if (self.findServer(connection)) |server_index| {
                    self.server_connections[server_index] = .invalid;
                }
            }
        }
    }

    fn sendClient(
        self: *Harness,
        connection: gns.Connection,
        message: protocol.ClientMessage,
    ) !void {
        const bytes = try protocol.encodeClient(message, &self.encode_storage);
        const class = transport_policy.clientClass(message);
        try self.network.send(
            connection,
            bytes,
            toGnsDelivery(class.delivery),
            toGnsLane(class.lane),
        );
    }

    fn findPeer(self: *const Harness, connection: gns.Connection) ?usize {
        for (self.peers, 0..) |peer, index| {
            if (peer.transport.isValid() and peer.transport.value == connection.value) return index;
        }
        return null;
    }

    fn findServer(self: *const Harness, connection: gns.Connection) ?usize {
        for (self.server_connections, 0..) |candidate, index| {
            if (candidate.isValid() and candidate.value == connection.value) return index;
        }
        return null;
    }

    fn freeServerSlot(self: *const Harness) ?usize {
        for (self.server_connections, 0..) |candidate, index| {
            if (!candidate.isValid()) return index;
        }
        return null;
    }
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const port = try parsePort(args);
    var endpoint_storage: [64]u8 = undefined;
    const endpoint = try std.fmt.bufPrintZ(&endpoint_storage, "127.0.0.1:{d}", .{port});
    const harness = try init.gpa.create(Harness);
    defer init.gpa.destroy(harness);
    harness.* = try Harness.init(init.gpa, port);
    defer harness.deinit();

    try harness.connectPeer(0, endpoint);
    try pumpUntil(harness, init.io, firstPeerReady, max_pump_steps);
    const first_join_participant = harness.peers[0].client.participant;

    try harness.connectPeer(1, endpoint);
    try pumpUntil(harness, init.io, twoPeersReady, max_pump_steps);
    for (0..180) |_| try harness.step(init.io);
    try pumpUntil(harness, init.io, npcProjectionReady, max_pump_steps);

    const carryable = firstCarryable(&harness.peers[0]) orelse
        return error.CarryableMissing;
    try harness.sendInteractionAction(0, .collect, carryable.entity);
    try pumpUntil(harness, init.io, firstPeerHolding, max_pump_steps);
    try harness.sendInteractionAction(1, .collect, carryable.entity);
    try pumpUntil(harness, init.io, secondPeerDeniedCarryable, max_pump_steps);
    try harness.sendInteractionAction(0, .drop, carryable.entity);
    try pumpUntil(harness, init.io, firstPeerDropped, max_pump_steps);

    const vehicle = firstVehicle(&harness.peers[0]) orelse return error.VehicleMissing;
    try harness.sendVehicleAction(0, .enter, vehicle.entity);
    try pumpUntil(harness, init.io, firstPeerDriving, max_pump_steps);
    if (harness.peers[1].client.ownedVehicle() != null) return error.VehicleOwnershipDuplicated;

    try harness.sendVehicleAction(1, .enter, vehicle.entity);
    try pumpUntil(harness, init.io, secondPeerDeniedVehicle, max_pump_steps);
    const initial_vehicle_position = firstVehicle(&harness.peers[0]).?.position;
    for (0..180) |_| {
        try harness.sendVehicleInput(0, 1);
        try harness.sendInput(1, .{ 1, 0 });
        try harness.step(init.io);
    }
    try pumpUntil(harness, init.io, vehicleMoved, max_pump_steps);
    try pumpUntil(harness, init.io, secondPeerEastRelevant, max_pump_steps);
    const driven_vehicle_position = firstVehicle(&harness.peers[0]).?.position;
    const east_vehicle = firstVehicle(&harness.peers[1]) orelse
        return error.BoundedVehicleProjectionMissing;
    const east_carryable = firstCarryable(&harness.peers[1]) orelse
        return error.BoundedCarryableProjectionMissing;
    if (!std.meta.eql(east_vehicle.entity, vehicle.entity)) {
        return error.VehicleIdentityChangedAcrossRelevanceTransfer;
    }
    if (!std.meta.eql(east_carryable.entity, carryable.entity)) {
        return error.CarryableIdentityChangedAcrossRelevanceTransfer;
    }
    if (harness.peers[0].client.localVehiclePresentation() == null) {
        return error.VehiclePredictionNotInitialized;
    }

    try harness.closePeerForReconnect(0);
    if (harness.peers[0].client.localVehiclePresentation() != null or
        harness.peers[0].client.vehicle_prediction.transport_resets != 1)
    {
        return error.VehiclePredictionNotResetForReconnect;
    }
    try pumpUntil(harness, init.io, firstPeerDisconnected, max_pump_steps);
    if (harness.authority.diagnostics().reconnecting_participants != 1) {
        return error.ReconnectGraceNotEntered;
    }
    try harness.connectPeer(0, endpoint);
    try pumpUntil(harness, init.io, firstPeerRejoinedDriving, max_pump_steps);
    if (!std.meta.eql(first_join_participant, harness.peers[0].client.participant)) {
        return error.ParticipantIdentityChangedAcrossReconnect;
    }
    if (harness.peers[0].client.localVehiclePresentation() == null) {
        return error.VehiclePredictionNotRestoredAfterReconnect;
    }

    try harness.sendVehicleAction(0, .exit, vehicle.entity);
    try pumpUntil(harness, init.io, firstPeerExited, max_pump_steps);
    if (harness.peers[0].client.localVehiclePresentation() != null) {
        return error.VehiclePredictionRetainedAfterExit;
    }
    const initial_position = characterPosition(&harness.peers[0]) orelse
        return error.LocalCharacterMissing;

    for (0..120) |_| {
        try harness.sendInput(0, .{ 1, 0 });
        try harness.step(init.io);
    }
    try pumpUntil(harness, init.io, movedAndAcknowledged, max_pump_steps);
    const moved_position = characterPosition(&harness.peers[0]) orelse
        return error.LocalCharacterMissing;
    if (moved_position[0] <= initial_position[0] + 0.25) {
        return error.AuthoritativeMovementNotObserved;
    }

    try harness.connectBadCohort(endpoint);
    try pumpUntil(harness, init.io, badCohortRejected, max_pump_steps);

    const diagnostics = harness.authority.diagnostics();
    if (diagnostics.baselines_acknowledged < 3 or diagnostics.relevance_transfers == 0 or
        diagnostics.active_npcs != budgets.product_npcs or diagnostics.npc_state_updates == 0)
    {
        return error.RelevanceLifecycleNotExercised;
    }
    std.debug.print(
        "MP4_LOOPBACK_PASS tick={d} participants={d} reconnects={d} " ++
            "snapshots={d} vehicle_actions={d}/{d} interaction_actions={d}/{d} " ++
            "baselines={d}/{d} transfers={d} npcs={d} npc_updates={d} vehicle_moved_m={d:.3} " ++
            "character_moved_x={d:.3} dropped_events={d}\n",
        .{
            diagnostics.tick,
            diagnostics.active_participants,
            diagnostics.reconnects,
            diagnostics.snapshots_emitted,
            diagnostics.vehicle_actions_accepted,
            diagnostics.vehicle_actions_rejected,
            diagnostics.interaction_actions_accepted,
            diagnostics.interaction_actions_rejected,
            diagnostics.baselines_emitted,
            diagnostics.baselines_acknowledged,
            diagnostics.relevance_transfers,
            diagnostics.active_npcs,
            diagnostics.npc_state_updates,
            @sqrt(
                std.math.pow(f32, driven_vehicle_position[0] - initial_vehicle_position[0], 2) +
                    std.math.pow(f32, driven_vehicle_position[2] - initial_vehicle_position[2], 2),
            ),
            moved_position[0] - initial_position[0],
            harness.network.droppedEvents(),
        },
    );
}

fn pumpUntil(
    harness: *Harness,
    io: std.Io,
    predicate: *const fn (*const Harness) bool,
    limit: usize,
) !void {
    for (0..limit) |_| {
        try harness.step(io);
        if (predicate(harness)) return;
    }
    std.debug.print(
        "MP2_TIMEOUT tick={d} reconnects={d} npc_updates={d} p0={s} baseline={d} " ++
            "entities={d}/{d}/{d}/{d} districts={d} owned_vehicle={} " ++
            "p1={s} entities={d}/{d}/{d}/{d} districts={d}\n",
        .{
            harness.authority.diagnostics().tick,
            harness.authority.diagnostics().reconnects,
            harness.authority.diagnostics().npc_state_updates,
            @tagName(harness.peers[0].client.state),
            harness.peers[0].client.active_baseline_id,
            harness.peers[0].client.world.character_count,
            harness.peers[0].client.world.vehicle_count,
            harness.peers[0].client.world.carryable_count,
            harness.peers[0].client.world.npc_count,
            harness.peers[0].client.relevant_district_count,
            harness.peers[0].client.ownedVehicle() != null,
            @tagName(harness.peers[1].client.state),
            harness.peers[1].client.world.character_count,
            harness.peers[1].client.world.vehicle_count,
            harness.peers[1].client.world.carryable_count,
            harness.peers[1].client.world.npc_count,
            harness.peers[1].client.relevant_district_count,
        },
    );
    return error.MP2AcceptanceTimeout;
}

fn firstPeerReady(harness: *const Harness) bool {
    return harness.peers[0].client.state == .joined and
        harness.peers[0].client.world.character_count == 1;
}

fn twoPeersReady(harness: *const Harness) bool {
    return harness.peers[0].client.state == .joined and
        harness.peers[1].client.state == .joined and
        harness.peers[0].client.world.character_count == 2 and
        harness.peers[1].client.world.character_count == 2 and
        harness.peers[0].client.world.vehicle_count == 1 and
        harness.peers[1].client.world.vehicle_count == 1 and
        harness.peers[0].client.world.carryable_count == 1 and
        harness.peers[1].client.world.carryable_count == 1;
}

fn firstPeerHolding(harness: *const Harness) bool {
    const result = harness.peers[0].last_interaction_action_result orelse return false;
    return result.action == .collect and result.disposition == .collected and
        harness.peers[0].client.heldCarryable() != null;
}

fn secondPeerDeniedCarryable(harness: *const Harness) bool {
    const result = harness.peers[1].last_interaction_action_result orelse return false;
    return result.action == .collect and result.disposition == .unavailable and
        harness.peers[1].client.heldCarryable() == null;
}

fn firstPeerDropped(harness: *const Harness) bool {
    const result = harness.peers[0].last_interaction_action_result orelse return false;
    return result.action == .drop and result.disposition == .dropped and
        harness.peers[0].client.heldCarryable() == null;
}

fn firstPeerDriving(harness: *const Harness) bool {
    return harness.peers[0].client.ownedVehicle() != null and
        harness.peers[0].last_vehicle_action_result != null and
        harness.peers[0].last_vehicle_action_result.?.disposition == .entered;
}

fn secondPeerDeniedVehicle(harness: *const Harness) bool {
    const result = harness.peers[1].last_vehicle_action_result orelse return false;
    return result.action == .enter and result.disposition == .unavailable;
}

fn vehicleMoved(harness: *const Harness) bool {
    const vehicle = firstVehicle(&harness.peers[0]) orelse return false;
    return vehicle.position[2] < -1;
}

fn secondPeerEastRelevant(harness: *const Harness) bool {
    const client = &harness.peers[1].client;
    return client.relevant_district_count == 1 and
        client.relevant_districts[0].x == 1 and
        client.relevant_districts[0].z == 0 and
        client.world.character_count == 1 and
        client.world.vehicle_count == 1 and
        client.world.carryable_count == 1 and
        client.world.npc_count != 0;
}

fn npcProjectionReady(harness: *const Harness) bool {
    return harness.authority.diagnostics().active_npcs == budgets.product_npcs and
        harness.peers[0].client.world.npc_count != 0 and
        harness.peers[1].client.world.npc_count != 0;
}

fn movedAndAcknowledged(harness: *const Harness) bool {
    const client = &harness.peers[0].client;
    const position = characterPosition(&harness.peers[0]) orelse return false;
    return client.last_acknowledged_input.value != 0 and position[0] > -2.75;
}

fn badCohortRejected(harness: *const Harness) bool {
    return harness.bad_hello_sent and harness.bad_rejection == .build_mismatch;
}

fn firstPeerDisconnected(harness: *const Harness) bool {
    return harness.peers[0].client.state == .disconnected and
        !harness.peers[0].transport.isValid() and
        harness.authority.diagnostics().reconnecting_participants == 1;
}

fn firstPeerRejoinedDriving(harness: *const Harness) bool {
    return harness.peers[0].client.state == .joined and
        harness.peers[1].client.state == .joined and
        harness.authority.diagnostics().reconnects == 1 and
        harness.peers[0].client.ownedVehicle() != null and
        harness.peers[0].client.localVehiclePresentation() != null;
}

fn firstPeerExited(harness: *const Harness) bool {
    const result = harness.peers[0].last_vehicle_action_result orelse return false;
    return result.action == .exit and result.disposition == .exited and
        harness.peers[0].client.ownedVehicle() == null;
}

fn characterPosition(peer: *const Peer) ?[3]f32 {
    for (peer.client.world.slice()) |entry| {
        if (std.meta.eql(entry.current.owner, peer.client.participant)) {
            return entry.current.position;
        }
    }
    return null;
}

fn firstVehicle(peer: *const Peer) ?protocol.VehicleState {
    const vehicles = peer.client.world.vehicleSlice();
    return if (vehicles.len == 0) null else vehicles[0].current;
}

fn firstCarryable(peer: *const Peer) ?protocol.CarryableState {
    const carryables = peer.client.world.carryableSlice();
    return if (carryables.len == 0) null else carryables[0].current;
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

fn parsePort(args: []const []const u8) !u16 {
    if (args.len == 1) return default_port;
    if (args.len != 3 or !std.mem.eql(u8, args[1], "--port")) {
        return error.InvalidArguments;
    }
    const port = try std.fmt.parseInt(u16, args[2], 10);
    if (port == 0) return error.InvalidPort;
    return port;
}
