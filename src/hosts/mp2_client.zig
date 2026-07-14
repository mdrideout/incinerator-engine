//! Minimal graphical multiplayer client. It renders replicated character,
//! vehicle, and carryable state;
//! no Simulation, Flecs world, Jolt body, save authority, or feature internals
//! are linked into this product.

const std = @import("std");
const budgets = @import("session_budgets");
const protocol = @import("session_protocol");
const session_client = @import("session_client");
const transport_policy = @import("session_transport_policy");
const reconnect_policy = @import("reconnect_policy");
const client_clock = @import("client_clock");
const room_coordinator = @import("room_coordinator");
const room_ticket = @import("room_ticket");
const gns = @import("gns_direct");
const presentation = @import("mp2_presentation");
const client_scene = @import("client_scene");

const c = presentation.c;
const default_endpoint = "127.0.0.1:27020";

const S10SmokeRole = enum { none, attacker, victim };

const Invocation = struct {
    endpoint: []const u8 = default_endpoint,
    account: u64 = 1,
    endpoint_explicit: bool = false,
    account_explicit: bool = false,
    ticket_path: ?[]const u8 = null,
    max_frames: ?u64 = null,
    smoke_actions: bool = false,
    s10_smoke_role: S10SmokeRole = .none,
};

const App = struct {
    io: std.Io,
    window: *c.SDL_Window,
    scene: client_scene.Scene,
    network: gns.Network,
    connection: gns.Connection,
    client: session_client.Client,
    room: ?room_coordinator.Coordinator = null,
    room_generation: u64 = 0,
    endpoint: [256]u8,
    endpoint_len: u16,
    keys: [512]bool = @splat(false),
    running: bool = true,
    hello_sent: bool = false,
    vehicle_action_requested: bool = false,
    interaction_action_requested: bool = false,
    melee_action_requested: bool = false,
    respawn_action_requested: bool = false,
    reconnect_requested: bool = false,
    smoke_actions: bool = false,
    smoke_milestones: u8 = 0,
    smoke_vehicle_start: ?[3]f32 = null,
    smoke_vehicle_moved: bool = false,
    smoke_walk_start: ?[3]f32 = null,
    smoke_walked: bool = false,
    smoke_reconnect_started: bool = false,
    smoke_reconnect_disconnected: bool = false,
    smoke_reconnect_completed: bool = false,
    s10_start_tick: ?u64 = null,
    s10_dead_tick: ?u64 = null,
    s10_milestones: u8 = 0,
    s10_respawn_requested: bool = false,
    s10_pass_printed: bool = false,
    s10_smoke_role: S10SmokeRole = .none,
    frame: u64 = 0,
    last_input_tick: u64 = 0,
    clock: client_clock.Clock = .{},
    retry: reconnect_policy.Policy,
    receive_storage: [budgets.max_wire_message_bytes]u8 = undefined,
    encode_storage: [budgets.max_wire_message_bytes]u8 = undefined,

    fn init(process_init: std.process.Init, invocation: Invocation) !App {
        if (invocation.ticket_path != null and invocation.endpoint_explicit) {
            return error.TicketOwnsEndpoint;
        }
        var ticket_artifact: ?room_ticket.Artifact = null;
        if (invocation.ticket_path) |path| {
            const bytes = try std.Io.Dir.cwd().readFileAlloc(
                process_init.io,
                path,
                process_init.gpa,
                .limited(room_ticket.maximum_bytes),
            );
            defer process_init.gpa.free(bytes);
            ticket_artifact = try room_ticket.decode(bytes);
            if (invocation.account_explicit and
                invocation.account != ticket_artifact.?.intent.account.value)
            {
                return error.TicketAccountMismatch;
            }
        }
        const account = if (ticket_artifact) |artifact|
            artifact.intent.account.value
        else
            invocation.account;
        const endpoint_text = if (ticket_artifact) |*artifact| switch (artifact.intent.route) {
            .direct_ip => |*endpoint| endpoint.slice(),
            else => return error.UnsupportedRoomTicketRoute,
        } else invocation.endpoint;

        if (!c.SDL_Init(c.SDL_INIT_VIDEO)) return error.SDLInitFailed;
        errdefer c.SDL_Quit();
        var title_buffer: [128]u8 = undefined;
        const title = try std.fmt.bufPrintZ(
            &title_buffer,
            "Incinerator MP4-B Client {d}",
            .{account},
        );
        const window = c.SDL_CreateWindow(
            title.ptr,
            960,
            540,
            c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_HIGH_PIXEL_DENSITY,
        ) orelse return error.SDLWindowFailed;
        errdefer c.SDL_DestroyWindow(window);
        var scene = try client_scene.Scene.init(window);
        errdefer scene.deinit();
        var network = try gns.Network.init();
        errdefer network.deinit();
        var endpoint_buffer: [256]u8 = @splat(0);
        const endpoint = try std.fmt.bufPrintZ(&endpoint_buffer, "{s}", .{endpoint_text});
        const connection = try network.connect(endpoint);
        var client = try session_client.Client.init(.{ .value = account });
        var coordinator: ?room_coordinator.Coordinator = null;
        var coordinator_generation: u64 = 0;
        if (ticket_artifact) |artifact| {
            try client.configureJoin(
                artifact.intent.external_identity,
                artifact.intent.authorization,
            );
            var value = room_coordinator.Coordinator{};
            coordinator_generation = try value.begin(.join);
            var members: [budgets.max_participants]room_coordinator.Member = undefined;
            for (artifact.memberSlice(), 0..) |member, index| members[index] = .{
                .account = member,
                .lobby_present = true,
                .ready = false,
                .connection = .none,
                .local = std.meta.eql(member, artifact.intent.account),
            };
            _ = try value.completeJoin(
                coordinator_generation,
                artifact.intent,
                members[0..artifact.member_count],
            );
            _ = try value.markReady(coordinator_generation);
            _ = try value.beginRouteResolution(coordinator_generation);
            _ = try value.routeResolved(coordinator_generation);
            coordinator = value;
        }
        return .{
            .io = process_init.io,
            .window = window,
            .scene = scene,
            .network = network,
            .connection = connection,
            .client = client,
            .room = coordinator,
            .room_generation = coordinator_generation,
            .retry = reconnect_policy.Policy.init(account),
            .smoke_actions = invocation.smoke_actions,
            .s10_smoke_role = invocation.s10_smoke_role,
            .endpoint = endpoint_buffer,
            .endpoint_len = @intCast(endpoint.len),
        };
    }

    fn deinit(self: *App) void {
        if (self.connection.isValid()) {
            self.network.close(self.connection, 1000, "client shutdown", .immediate);
        }
        self.network.deinit();
        self.scene.deinit();
        c.SDL_DestroyWindow(self.window);
        c.SDL_Quit();
        self.* = undefined;
    }

    fn run(self: *App, max_frames: ?u64) !void {
        const start = std.Io.Clock.Timestamp.now(self.io, .awake);
        while (self.running and (max_frames == null or self.frame < max_frames.?)) {
            self.pumpEvents();
            const now = std.Io.Clock.Timestamp.now(self.io, .awake);
            const now_ns = elapsedNs(start, now);
            try self.pumpNetwork(now_ns);
            self.forceReconnect(now_ns);
            try self.reconnectIfDue(now_ns);
            self.scheduleSmokeActions();
            self.scheduleS10Actions();
            try self.sendVehicleActionIfRequested();
            try self.sendInteractionActionIfRequested();
            try self.sendMeleeActionIfRequested();
            try self.sendRespawnActionIfRequested();
            if (self.client.state == .joined and self.clock.anchored) {
                const due_tick = self.clock.inputTick(now_ns);
                var catch_up: u8 = 0;
                while (self.last_input_tick < due_tick and catch_up < 8) : (catch_up += 1) {
                    self.last_input_tick += 1;
                    try self.sendInput(self.last_input_tick);
                }
                if (self.last_input_tick < due_tick) self.last_input_tick = due_tick;
            }
            self.observeSmokeProgress();
            self.finishS10Smoke();
            try self.scene.render(&self.client, now_ns);
            self.frame += 1;
            if (self.frame % 60 == 0) self.updateTitle();
            try std.Io.sleep(self.io, .fromMilliseconds(1), .awake);
        }
        try self.finishSmokeActions();
    }

    fn pumpEvents(self: *App) void {
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event)) switch (event.type) {
            c.SDL_EVENT_QUIT => self.running = false,
            c.SDL_EVENT_WINDOW_CLOSE_REQUESTED => self.running = false,
            c.SDL_EVENT_KEY_DOWN => {
                const index: usize = @intCast(event.key.scancode);
                const was_down = index < self.keys.len and self.keys[index];
                if (index < self.keys.len) self.keys[index] = true;
                if (event.key.scancode == c.SDL_SCANCODE_E and !was_down) {
                    self.vehicle_action_requested = true;
                }
                if (event.key.scancode == c.SDL_SCANCODE_F and !was_down) {
                    self.interaction_action_requested = true;
                }
                if (event.key.scancode == c.SDL_SCANCODE_Q and !was_down) {
                    self.melee_action_requested = true;
                }
                if (event.key.scancode == c.SDL_SCANCODE_R and !was_down) {
                    self.respawn_action_requested = true;
                }
                if (event.key.scancode == c.SDL_SCANCODE_P and !was_down) {
                    const enabled = self.scene.toggleVehiclePrediction();
                    std.debug.print("MP4_VEHICLE_PREDICTION enabled={}\n", .{
                        enabled,
                    });
                    self.updateTitle();
                }
                if (event.key.scancode == c.SDL_SCANCODE_F8 and !was_down) {
                    self.reconnect_requested = true;
                }
                if (event.key.scancode == c.SDL_SCANCODE_C and !was_down) {
                    self.cancelRoomFlow();
                }
                if (event.key.scancode == c.SDL_SCANCODE_L and !was_down) {
                    self.leaveRoom();
                }
                if (event.key.scancode == c.SDL_SCANCODE_ESCAPE) self.running = false;
            },
            c.SDL_EVENT_KEY_UP => {
                const index: usize = @intCast(event.key.scancode);
                if (index < self.keys.len) self.keys[index] = false;
            },
            else => {},
        };
    }

    fn pumpNetwork(self: *App, now_ns: u64) !void {
        self.network.runCallbacks();
        while (self.network.pollEvent()) |event| switch (event.new_state) {
            .connected => {
                if (event.connection.value == self.connection.value and !self.hello_sent) {
                    try self.network.configureConnected(self.connection);
                    if (self.room) |*coordinator| {
                        _ = try coordinator.transportConnected(self.room_generation);
                    }
                    try self.sendClientMessage(try self.client.begin());
                    self.hello_sent = true;
                }
            },
            .closed_by_peer, .problem_detected_locally => {
                if (event.connection.value != self.connection.value) continue;
                self.client.transportDisconnected();
                self.noteRoomNetworkLoss();
                self.connection = .invalid;
                self.hello_sent = false;
                if (self.client.state == .disconnected) {
                    const delay = self.retry.schedule(now_ns) orelse {
                        std.debug.print("MP2_CLIENT_RECONNECT_EXHAUSTED\n", .{});
                        self.running = false;
                        continue;
                    };
                    std.debug.print(
                        "MP2_CLIENT_DISCONNECTED reason={d} detail={s} reconnect_in_ms={d}\n",
                        .{ event.end_reason, event.debugText(), delay / std.time.ns_per_ms },
                    );
                } else {
                    self.running = false;
                }
            },
            .none, .connecting, .finding_route => {},
        };

        if (!self.connection.isValid()) return;
        while (try self.network.receive(self.connection, &self.receive_storage)) |received| {
            const delivered = try protocol.decodeDeliveredServer(received.bytes);
            const message = delivered.message;
            if (!transport_policy.matches(
                transport_policy.serverClass(message),
                fromGnsDelivery(received.delivery),
                fromGnsLane(received.lane),
            )) {
                return error.ServerDeliveryClassMismatch;
            }
            try self.client.receiveDelivered(delivered);
            while (self.client.takeDeliveryReceipt()) |receipt| {
                try self.sendClientMessage(receipt);
            }
            if (self.client.takeBaselineAck()) |ack| try self.sendClientMessage(ack);
            if (self.client.takeSnapshotAck()) |ack| try self.sendClientMessage(ack);
            switch (message) {
                .welcome => |welcome| {
                    if (self.room) |*coordinator| {
                        _ = try coordinator.authorityAccepted(self.room_generation);
                    }
                    self.clock.synchronize(welcome.authority_tick, now_ns);
                    self.last_input_tick = welcome.authority_tick;
                    self.retry.reset();
                    std.debug.print(
                        "MP2_CLIENT_JOINED participant={d}:{d} tick={d}\n",
                        .{ welcome.participant.index, welcome.participant.generation, welcome.authority_tick },
                    );
                },
                .snapshot => |snapshot| {
                    self.clock.observe(snapshot.server_tick);
                    self.scene.observeSnapshot(now_ns);
                    try self.finishRoomSynchronization();
                },
                .relevance_baseline => |baseline| {
                    self.clock.observe(baseline.snapshot.server_tick);
                    self.scene.observeSnapshot(now_ns);
                    std.debug.print(
                        "MP4_BASELINE id={d} districts={d} entities={d}\n",
                        .{
                            baseline.baseline_id,
                            baseline.district_count,
                            baseline.snapshot.character_count +
                                baseline.snapshot.vehicle_count +
                                baseline.snapshot.carryable_count +
                                baseline.snapshot.npc_count,
                        },
                    );
                    try self.finishRoomSynchronization();
                },
                .vehicle_action_result => |result| {
                    std.debug.print(
                        "MP4_VEHICLE_ACTION action={s} result={s} vehicle={d}:{d}\n",
                        .{
                            @tagName(result.action),
                            @tagName(result.disposition),
                            result.vehicle.index,
                            result.vehicle.generation,
                        },
                    );
                },
                .interaction_action_result => |result| {
                    std.debug.print(
                        "MP4_INTERACTION_ACTION action={s} result={s} carryable={d}:{d}\n",
                        .{
                            @tagName(result.action),
                            @tagName(result.disposition),
                            result.carryable.index,
                            result.carryable.generation,
                        },
                    );
                },
                .melee_action_result => |result| {
                    _ = self.client.takeMeleeActionResult();
                    std.debug.print(
                        "S10_CLIENT_MELEE result={s} damage={d} health={d} killed={}\n",
                        .{
                            @tagName(result.disposition),
                            result.applied_damage,
                            result.remaining_health,
                            result.killed,
                        },
                    );
                },
                .respawn_action_result => |result| {
                    _ = self.client.takeRespawnActionResult();
                    std.debug.print(
                        "S10_CLIENT_RESPAWN result={s} incarnation={d}\n",
                        .{ @tagName(result.disposition), result.incarnation },
                    );
                },
                .life_event => |event| {
                    _ = self.client.takeLifeEvent();
                    std.debug.print(
                        "S10_CLIENT_LIFE avatar={d}:{d} incarnation={d} state={s} health={d}\n",
                        .{
                            event.avatar.index,
                            event.avatar.generation,
                            event.incarnation,
                            @tagName(event.state),
                            event.health,
                        },
                    );
                    if (self.s10_smoke_role == .victim and event.state == .dead and
                        event.avatar.index == self.client.participant.index)
                    {
                        self.s10_dead_tick = self.client.world.server_tick;
                    }
                },
                .rejected => |rejected| {
                    std.debug.print(
                        "MP2_CLIENT_REJECTED reason={s}\n",
                        .{@tagName(rejected.reason)},
                    );
                    if (self.room) |*coordinator| {
                        _ = try coordinator.fail(
                            self.room_generation,
                            failureFromRejection(rejected.reason),
                            rejected.reason == .protocol_mismatch or
                                rejected.reason == .build_mismatch or
                                rejected.reason == .content_mismatch,
                        );
                    } else self.running = false;
                },
                .disconnected => |reason| {
                    std.debug.print("MP2_CLIENT_SESSION_ENDED reason={s}\n", .{@tagName(reason)});
                    if (self.client.state == .stopped) {
                        if (self.room) |*coordinator| {
                            _ = coordinator.fail(
                                self.room_generation,
                                .host_closed,
                                true,
                            ) catch {};
                        } else self.running = false;
                    }
                },
            }
        }
    }

    fn reconnectIfDue(self: *App, now_ns: u64) !void {
        if (self.connection.isValid() or self.client.state != .disconnected or
            !self.retry.due(now_ns)) return;
        self.retry.consume();
        self.connection = self.network.connect(
            self.endpoint[0..self.endpoint_len :0],
        ) catch {
            if (self.retry.schedule(now_ns) == null) self.running = false;
            return;
        };
        std.debug.print("MP2_CLIENT_RECONNECTING endpoint={s}\n", .{
            self.endpoint[0..self.endpoint_len],
        });
    }

    fn forceReconnect(self: *App, now_ns: u64) void {
        if (!self.reconnect_requested) return;
        self.reconnect_requested = false;
        if (!self.connection.isValid() or self.client.state != .joined) return;
        self.network.close(
            self.connection,
            1001,
            "manual reconnect test",
            .immediate,
        );
        self.connection = .invalid;
        self.hello_sent = false;
        self.client.transportDisconnected();
        self.noteRoomNetworkLoss();
        const delay = self.retry.schedule(now_ns) orelse {
            self.running = false;
            return;
        };
        std.debug.print("MP4_CLIENT_MANUAL_RECONNECT reconnect_in_ms={d}\n", .{
            delay / std.time.ns_per_ms,
        });
    }

    fn sendInput(self: *App, target_tick: u64) !void {
        if (self.client.state != .joined) return;
        if (self.client.ownedVehicle()) |vehicle| {
            const scripted_drive = self.smoke_actions and
                self.client.world.server_tick >= 150 and
                self.client.world.server_tick < 165;
            const throttle = if (scripted_drive)
                @as(f32, 1)
            else
                @as(f32, @floatFromInt(@intFromBool(self.key(c.SDL_SCANCODE_W)))) -
                    @as(f32, @floatFromInt(@intFromBool(self.key(c.SDL_SCANCODE_S))));
            const steering = @as(f32, @floatFromInt(@intFromBool(self.key(c.SDL_SCANCODE_D)))) -
                @as(f32, @floatFromInt(@intFromBool(self.key(c.SDL_SCANCODE_A))));
            try self.sendClientMessage(try self.client.vehicleInput(
                target_tick,
                vehicle.entity,
                throttle,
                steering,
                @floatFromInt(@intFromBool(self.key(c.SDL_SCANCODE_SPACE))),
                @floatFromInt(@intFromBool(self.key(c.SDL_SCANCODE_LSHIFT))),
            ));
            return;
        }
        const tick = self.client.world.server_tick;
        if (self.s10_smoke_role != .none) {
            try self.sendClientMessage(try self.client.input(
                target_tick,
                .{ 0, 0 },
                if (self.s10_smoke_role == .attacker)
                    s10TargetYaw(&self.client) orelse self.scene.camera.yaw
                else
                    -std.math.pi / 2.0,
                false,
            ));
            return;
        }
        const move = if (self.smoke_actions and tick >= 40 and tick < 54)
            normalizedMove(.{ -0.25, 1 })
        else if (self.smoke_actions and tick >= 190 and tick < 220)
            [2]f32{ 1, 0 }
        else
            normalizedMove(.{
                @as(f32, @floatFromInt(@intFromBool(self.key(c.SDL_SCANCODE_D)))) -
                    @as(f32, @floatFromInt(@intFromBool(self.key(c.SDL_SCANCODE_A)))),
                @as(f32, @floatFromInt(@intFromBool(self.key(c.SDL_SCANCODE_W)))) -
                    @as(f32, @floatFromInt(@intFromBool(self.key(c.SDL_SCANCODE_S)))),
            });
        try self.sendClientMessage(try self.client.input(
            target_tick,
            move,
            self.scene.camera.yaw,
            self.key(c.SDL_SCANCODE_SPACE),
        ));
    }

    fn sendVehicleActionIfRequested(self: *App) !void {
        if (!self.vehicle_action_requested) return;
        self.vehicle_action_requested = false;
        if (self.client.state != .joined or self.client.pending_vehicle_action != null) return;
        if (self.client.ownedVehicle()) |vehicle| {
            try self.sendClientMessage(try self.client.vehicleAction(.exit, vehicle.entity));
            return;
        }
        const vehicle_entries = self.client.world.vehicleSlice();
        if (vehicle_entries.len == 0) return;
        try self.sendClientMessage(try self.client.vehicleAction(
            .enter,
            vehicle_entries[0].current.entity,
        ));
    }

    fn sendInteractionActionIfRequested(self: *App) !void {
        if (!self.interaction_action_requested) return;
        self.interaction_action_requested = false;
        if (self.client.state != .joined or
            self.client.pending_interaction_action != null) return;
        if (self.client.heldCarryable()) |held| {
            try self.sendClientMessage(try self.client.interactionAction(.drop, held.entity));
            return;
        }
        if (self.client.ownedVehicle() != null) return;
        const carryables = self.client.world.carryableSlice();
        if (carryables.len == 0) return;
        try self.sendClientMessage(try self.client.interactionAction(
            .collect,
            carryables[0].current.entity,
        ));
    }

    fn sendMeleeActionIfRequested(self: *App) !void {
        if (!self.melee_action_requested) return;
        self.melee_action_requested = false;
        if (self.client.state != .joined or self.client.pending_melee_action != null) return;
        try self.sendClientMessage(try self.client.meleeAction(
            self.client.world.server_tick +| 1,
        ));
    }

    fn sendRespawnActionIfRequested(self: *App) !void {
        if (!self.respawn_action_requested) return;
        self.respawn_action_requested = false;
        if (self.client.state != .joined or self.client.pending_respawn_action != null) return;
        const message = self.client.respawnAction() catch |err| switch (err) {
            error.AvatarLifecycleUnavailable => return,
            else => return err,
        };
        try self.sendClientMessage(message);
    }

    fn sendClientMessage(self: *App, message: protocol.ClientMessage) !void {
        const bytes = try protocol.encodeClient(message, &self.encode_storage);
        const class = transport_policy.clientClass(message);
        try self.network.send(
            self.connection,
            bytes,
            toGnsDelivery(class.delivery),
            toGnsLane(class.lane),
        );
    }

    fn scheduleS10Actions(self: *App) void {
        if (self.s10_smoke_role == .none or self.client.state != .joined) {
            return;
        }
        const tick = self.client.world.server_tick;
        if (self.s10_smoke_role == .attacker) {
            if (self.client.world.character_count < 2) return;
            if (self.s10_start_tick == null) self.s10_start_tick = tick;
            const elapsed = tick -| self.s10_start_tick.?;
            inline for (.{
                .{ @as(u64, 5), @as(u8, 1) },
                .{ @as(u64, 40), @as(u8, 2) },
                .{ @as(u64, 75), @as(u8, 4) },
            }) |milestone| {
                if (elapsed >= milestone[0] and self.s10_milestones & milestone[1] == 0) {
                    self.melee_action_requested = true;
                    self.s10_milestones |= milestone[1];
                }
            }
        } else if (self.s10_dead_tick) |death_tick| {
            if (!self.s10_respawn_requested and tick >= death_tick +| 185) {
                self.respawn_action_requested = true;
                self.s10_respawn_requested = true;
            }
        }
    }

    fn finishS10Smoke(self: *App) void {
        if (self.s10_pass_printed) return;
        if (self.s10_smoke_role == .attacker and
            self.client.melee_actions_accepted >= 3 and self.client.life_events >= 2)
        {
            std.debug.print(
                "S10_CLIENT_ATTACKER_PASS hits={d} life_events={d}\n",
                .{ self.client.melee_actions_accepted, self.client.life_events },
            );
            self.s10_pass_printed = true;
            self.running = false;
        } else if (self.s10_smoke_role == .victim and
            self.client.respawns_accepted >= 1 and localCharacterPosition(&self.client) != null)
        {
            std.debug.print(
                "S10_CLIENT_VICTIM_PASS respawns={d} incarnation={d}\n",
                .{ self.client.respawns_accepted, self.client.avatar_incarnation },
            );
            self.s10_pass_printed = true;
            self.running = false;
        }
    }

    fn scheduleSmokeActions(self: *App) void {
        if (!self.smoke_actions or self.client.state != .joined) return;
        const tick = self.client.world.server_tick;
        if (tick >= 100 and self.smoke_milestones & 1 == 0) {
            self.interaction_action_requested = true;
            self.smoke_milestones |= 1;
        }
        if (tick >= 120 and self.smoke_milestones & 2 == 0) {
            self.interaction_action_requested = true;
            self.smoke_milestones |= 2;
        }
        if (tick >= 140 and self.smoke_milestones & 4 == 0) {
            self.vehicle_action_requested = true;
            self.smoke_milestones |= 4;
        }
        if (tick >= 175 and self.smoke_milestones & 8 == 0) {
            self.vehicle_action_requested = true;
            self.smoke_milestones |= 8;
        }
        if (tick >= 230 and self.smoke_milestones & 16 == 0) {
            self.reconnect_requested = true;
            self.smoke_reconnect_started = true;
            self.smoke_milestones |= 16;
        }
    }

    fn observeSmokeProgress(self: *App) void {
        if (!self.smoke_actions) return;
        if (self.smoke_reconnect_started and self.client.state == .disconnected) {
            self.smoke_reconnect_disconnected = true;
        }
        if (self.smoke_reconnect_disconnected and self.client.state == .joined) {
            if (self.room) |*coordinator| {
                if (coordinator.view().state == .playable) {
                    self.smoke_reconnect_completed = true;
                }
            }
        }
        if (self.client.state != .joined) return;
        const tick = self.client.world.server_tick;
        if (self.client.ownedVehicle()) |vehicle| {
            if (self.smoke_vehicle_start == null) {
                self.smoke_vehicle_start = vehicle.position;
            } else if (distanceSquared(self.smoke_vehicle_start.?, vehicle.position) > 0.0004) {
                self.smoke_vehicle_moved = true;
            }
        }
        if (tick >= 185 and self.client.ownedVehicle() == null) {
            if (localCharacterPosition(&self.client)) |position| {
                if (self.smoke_walk_start == null) {
                    self.smoke_walk_start = position;
                } else if (tick >= 215 and
                    distanceSquared(self.smoke_walk_start.?, position) > 0.01)
                {
                    self.smoke_walked = true;
                }
            }
        }
    }

    fn finishSmokeActions(self: *const App) !void {
        if (!self.smoke_actions) return;
        if (self.client.world.server_tick < 215 or
            self.client.vehicle_actions_accepted < 2 or
            self.client.interaction_actions_accepted < 2 or
            !self.smoke_vehicle_moved or !self.smoke_walked or
            !self.smoke_reconnect_completed)
        {
            return error.GraphicalClientSmokeActionsIncomplete;
        }
        std.debug.print(
            "MP6_CLIENT_SMOKE_PASS account={d} walk=true drive=true carry=true reconnect=true vehicle_actions={d} interaction_actions={d}\n",
            .{
                self.client.account.value,
                self.client.vehicle_actions_accepted,
                self.client.interaction_actions_accepted,
            },
        );
    }

    fn updateTitle(self: *App) void {
        var title_storage: [256]u8 = undefined;
        const stats = self.network.stats(self.connection);
        const room_view = if (self.room) |*coordinator| coordinator.view() else null;
        const room_state = if (room_view) |view| @tagName(view.state) else "direct-development";
        const room_members = if (room_view) |view| view.member_count else 0;
        var ready_members: u8 = 0;
        var connected_members: u8 = 0;
        if (room_view) |*view| for (view.memberSlice()) |member| {
            ready_members += @intFromBool(member.ready);
            connected_members += @intFromBool(member.connection == .connected);
        };
        const room_failure = if (room_view) |view|
            if (view.failure) |failure| @tagName(failure) else "none"
        else
            "none";
        const title = std.fmt.bufPrintZ(
            &title_storage,
            "Room {s} members {d} ready {d} connected {d} failure {s} | session {s} | entities {d} | ping {d} ms | age {d}t | net d/f/m {d}/{d}/{d} | mode {s} | carry {s} | pred {s} | correction {d}/{d} max {d:.2}m/{d:.1}deg",
            .{
                room_state,
                room_members,
                ready_members,
                connected_members,
                room_failure,
                @tagName(self.client.state),
                self.client.world.character_count + self.client.world.vehicle_count +
                    self.client.world.carryable_count + self.client.world.npc_count,
                if (stats) |value| value.ping_ms else -1,
                self.last_input_tick -| self.client.world.server_tick,
                self.client.delta_snapshots_applied,
                self.client.full_snapshots_applied,
                self.client.delta_base_misses,
                if (self.client.ownedVehicle() != null) "vehicle" else "on-foot",
                if (self.client.heldCarryable() != null) "holding" else "empty",
                if (self.scene.vehicle_prediction_enabled) "on" else "off",
                self.client.vehicle_prediction.soft_corrections,
                self.client.vehicle_prediction.hard_corrections,
                self.client.vehicle_prediction.maximum_position_error_m,
                self.client.vehicle_prediction.maximum_orientation_error_degrees,
            },
        ) catch return;
        _ = c.SDL_SetWindowTitle(self.window, title.ptr);
    }

    fn finishRoomSynchronization(self: *App) !void {
        if (!self.client.world.initialized) return;
        if (self.room) |*coordinator| {
            if (coordinator.view().state == .synchronizing) {
                _ = try coordinator.synchronized(self.room_generation);
                self.updateTitle();
            }
        }
    }

    fn noteRoomNetworkLoss(self: *App) void {
        if (self.room) |*coordinator| switch (coordinator.view().state) {
            .playable, .authenticating, .synchronizing => {
                self.room_generation = coordinator.networkLost() catch return;
                self.updateTitle();
            },
            else => {},
        };
    }

    fn cancelRoomFlow(self: *App) void {
        const coordinator = if (self.room) |*value| value else return;
        const generation = coordinator.cancel() catch return;
        _ = coordinator.cancelled(generation) catch return;
        self.running = false;
    }

    fn leaveRoom(self: *App) void {
        const coordinator = if (self.room) |*value| value else return;
        const generation = coordinator.leave() catch return;
        _ = coordinator.left(generation) catch return;
        self.running = false;
    }

    fn key(self: *const App, scancode: c.SDL_Scancode) bool {
        const index: usize = @intCast(scancode);
        return index < self.keys.len and self.keys[index];
    }
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const invocation = try parseInvocation(args);
    var app = try App.init(init, invocation);
    defer app.deinit();
    std.debug.print(
        "MP6_CLIENT_CONNECT endpoint={s} account={d} ticketed={} controls=WASD/SPACE/LSHIFT/E enter-exit/F collect-drop/Q melee/R respawn/P prediction/F8 reconnect/C cancel/L leave/ESC\n",
        .{
            app.endpoint[0..app.endpoint_len],
            app.client.account.value,
            invocation.ticket_path != null,
        },
    );
    try app.run(invocation.max_frames);
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

fn normalizedMove(value: [2]f32) [2]f32 {
    const length_squared = value[0] * value[0] + value[1] * value[1];
    if (length_squared <= 1) return value;
    const scale = 1.0 / @sqrt(length_squared);
    return .{ value[0] * scale, value[1] * scale };
}

fn localCharacterPosition(client: *const session_client.Client) ?[3]f32 {
    for (client.world.slice()) |entry| {
        if (std.meta.eql(entry.current.owner, client.participant)) {
            return entry.current.position;
        }
    }
    return null;
}

fn s10TargetYaw(client: *const session_client.Client) ?f32 {
    const own = localCharacterPosition(client) orelse return null;
    var selected: ?[3]f32 = null;
    var selected_distance = std.math.inf(f32);
    for (client.world.slice()) |entry| {
        if (std.meta.eql(entry.current.owner, client.participant)) continue;
        const distance = distanceSquared(own, entry.current.position);
        if (distance < selected_distance) {
            selected_distance = distance;
            selected = entry.current.position;
        }
    }
    const target = selected orelse return null;
    return std.math.atan2(target[0] - own[0], -(target[2] - own[2]));
}

fn distanceSquared(a: [3]f32, b: [3]f32) f32 {
    const x = b[0] - a[0];
    const y = b[1] - a[1];
    const z = b[2] - a[2];
    return x * x + y * y + z * z;
}

fn parseInvocation(args: []const []const u8) !Invocation {
    var result = Invocation{};
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--connect")) {
            index += 1;
            if (index >= args.len or args[index].len == 0 or args[index].len >= 256) {
                return error.InvalidEndpoint;
            }
            result.endpoint = args[index];
            result.endpoint_explicit = true;
        } else if (std.mem.eql(u8, args[index], "--account")) {
            index += 1;
            if (index >= args.len) return error.MissingAccount;
            result.account = try std.fmt.parseInt(u64, args[index], 10);
            if (result.account == 0) return error.InvalidAccount;
            result.account_explicit = true;
        } else if (std.mem.eql(u8, args[index], "--ticket")) {
            index += 1;
            if (index >= args.len or args[index].len == 0) return error.MissingRoomTicket;
            result.ticket_path = args[index];
        } else if (std.mem.eql(u8, args[index], "--max-frames")) {
            index += 1;
            if (index >= args.len) return error.MissingMaxFrames;
            result.max_frames = try std.fmt.parseInt(u64, args[index], 10);
        } else if (std.mem.eql(u8, args[index], "--smoke-actions")) {
            result.smoke_actions = true;
        } else if (std.mem.eql(u8, args[index], "--s10-attacker")) {
            if (result.s10_smoke_role != .none) return error.DuplicateS10SmokeRole;
            result.s10_smoke_role = .attacker;
        } else if (std.mem.eql(u8, args[index], "--s10-victim")) {
            if (result.s10_smoke_role != .none) return error.DuplicateS10SmokeRole;
            result.s10_smoke_role = .victim;
        } else return error.UnknownArgument;
    }
    return result;
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

fn elapsedNs(start: std.Io.Clock.Timestamp, end: std.Io.Clock.Timestamp) u64 {
    const nanoseconds = start.durationTo(end).raw.nanoseconds;
    if (nanoseconds <= 0) return 0;
    return std.math.cast(u64, nanoseconds) orelse std.math.maxInt(u64);
}

test "diagonal input is normalized before protocol admission" {
    const move = normalizedMove(.{ 1, 1 });
    try std.testing.expectApproxEqAbs(@as(f32, 1), move[0] * move[0] + move[1] * move[1], 0.0001);
}
