//! Minimal graphical multiplayer client. It renders replicated character and
//! vehicle state;
//! no Simulation, Flecs world, Jolt body, save authority, or feature internals
//! are linked into this product.

const std = @import("std");
const zm = @import("zmath");
const budgets = @import("session_budgets");
const protocol = @import("session_protocol");
const session_client = @import("session_client");
const replicated_world = @import("replicated_world");
const transport_policy = @import("session_transport_policy");
const reconnect_policy = @import("reconnect_policy");
const client_clock = @import("client_clock");
const gns = @import("gns_direct");
const presentation = @import("mp2_presentation");
const renderer = presentation.renderer;
const primitives = presentation.primitives;
const mesh = presentation.mesh;
const camera = presentation.camera;

const c = presentation.c;
const default_endpoint = "127.0.0.1:27020";

const Invocation = struct {
    endpoint: []const u8 = default_endpoint,
    account: u64 = 1,
    max_frames: ?u64 = null,
};

const App = struct {
    io: std.Io,
    window: *c.SDL_Window,
    gpu: renderer.Renderer,
    ground: mesh.Mesh,
    character: mesh.Mesh,
    vehicle: mesh.Mesh,
    camera: camera.Camera,
    network: gns.Network,
    connection: gns.Connection,
    client: session_client.Client,
    endpoint: [256]u8,
    endpoint_len: u16,
    keys: [512]bool = @splat(false),
    running: bool = true,
    hello_sent: bool = false,
    vehicle_action_requested: bool = false,
    vehicle_prediction_enabled: bool = true,
    reconnect_requested: bool = false,
    frame: u64 = 0,
    last_input_tick: u64 = 0,
    clock: client_clock.Clock = .{},
    retry: reconnect_policy.Policy,
    last_snapshot_ns: u64 = 0,
    snapshot_interval_ns: u64 = std.time.ns_per_s / budgets.snapshot_hz,
    receive_storage: [budgets.max_wire_message_bytes]u8 = undefined,
    encode_storage: [budgets.max_wire_message_bytes]u8 = undefined,

    fn init(process_init: std.process.Init, invocation: Invocation) !App {
        if (!c.SDL_Init(c.SDL_INIT_VIDEO)) return error.SDLInitFailed;
        errdefer c.SDL_Quit();
        var title_buffer: [128]u8 = undefined;
        const title = try std.fmt.bufPrintZ(
            &title_buffer,
            "Incinerator MP4-A2 Client {d}",
            .{invocation.account},
        );
        const window = c.SDL_CreateWindow(
            title.ptr,
            960,
            540,
            c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_HIGH_PIXEL_DENSITY,
        ) orelse return error.SDLWindowFailed;
        errdefer c.SDL_DestroyWindow(window);
        var gpu = try renderer.Renderer.init(window);
        errdefer gpu.deinit();
        var ground = try primitives.createGroundPlane(gpu.getDevice());
        errdefer ground.deinit();
        var character = try primitives.createCharacterCapsule(gpu.getDevice(), 0.4, 0.5);
        errdefer character.deinit();
        var vehicle = try primitives.createCube(gpu.getDevice());
        errdefer vehicle.deinit();
        var network = try gns.Network.init();
        errdefer network.deinit();
        var endpoint_buffer: [256]u8 = @splat(0);
        const endpoint = try std.fmt.bufPrintZ(&endpoint_buffer, "{s}", .{invocation.endpoint});
        const connection = try network.connect(endpoint);
        return .{
            .io = process_init.io,
            .window = window,
            .gpu = gpu,
            .ground = ground,
            .character = character,
            .vehicle = vehicle,
            .camera = .{ .pitch = -0.25 },
            .network = network,
            .connection = connection,
            .client = try session_client.Client.init(.{ .value = invocation.account }),
            .retry = reconnect_policy.Policy.init(invocation.account),
            .endpoint = endpoint_buffer,
            .endpoint_len = @intCast(endpoint.len),
        };
    }

    fn deinit(self: *App) void {
        if (self.connection.isValid()) {
            self.network.close(self.connection, 1000, "client shutdown", .immediate);
        }
        self.network.deinit();
        self.vehicle.deinit();
        self.character.deinit();
        self.ground.deinit();
        self.gpu.deinit();
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
            try self.sendVehicleActionIfRequested();
            if (self.client.state == .joined and self.clock.anchored) {
                const due_tick = self.clock.inputTick(now_ns);
                var catch_up: u8 = 0;
                while (self.last_input_tick < due_tick and catch_up < 8) : (catch_up += 1) {
                    self.last_input_tick += 1;
                    try self.sendInput(self.last_input_tick);
                }
                if (self.last_input_tick < due_tick) self.last_input_tick = due_tick;
            }
            try self.render(now_ns);
            self.frame += 1;
            if (self.frame % 60 == 0) self.updateTitle();
            try std.Io.sleep(self.io, .fromMilliseconds(1), .awake);
        }
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
                if (event.key.scancode == c.SDL_SCANCODE_P and !was_down) {
                    self.vehicle_prediction_enabled = !self.vehicle_prediction_enabled;
                    std.debug.print("MP4_VEHICLE_PREDICTION enabled={}\n", .{
                        self.vehicle_prediction_enabled,
                    });
                    self.updateTitle();
                }
                if (event.key.scancode == c.SDL_SCANCODE_F8 and !was_down) {
                    self.reconnect_requested = true;
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
                    try self.sendClientMessage(try self.client.begin());
                    self.hello_sent = true;
                }
            },
            .closed_by_peer, .problem_detected_locally => {
                if (event.connection.value != self.connection.value) continue;
                self.client.transportDisconnected();
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
            const message = try protocol.decodeServer(received.bytes);
            if (!transport_policy.matches(
                transport_policy.serverClass(message),
                fromGnsDelivery(received.delivery),
                fromGnsLane(received.lane),
            )) {
                return error.ServerDeliveryClassMismatch;
            }
            try self.client.receive(message);
            switch (message) {
                .welcome => |welcome| {
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
                    if (self.last_snapshot_ns != 0 and now_ns > self.last_snapshot_ns) {
                        self.snapshot_interval_ns = now_ns - self.last_snapshot_ns;
                    }
                    self.last_snapshot_ns = now_ns;
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
                .rejected => |rejected| {
                    std.debug.print(
                        "MP2_CLIENT_REJECTED reason={s}\n",
                        .{@tagName(rejected.reason)},
                    );
                    self.running = false;
                },
                .disconnected => |reason| {
                    std.debug.print("MP2_CLIENT_SESSION_ENDED reason={s}\n", .{@tagName(reason)});
                    if (self.client.state == .stopped) self.running = false;
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
            const throttle = @as(f32, @floatFromInt(@intFromBool(self.key(c.SDL_SCANCODE_W)))) -
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
        const move = normalizedMove(.{
            @as(f32, @floatFromInt(@intFromBool(self.key(c.SDL_SCANCODE_D)))) -
                @as(f32, @floatFromInt(@intFromBool(self.key(c.SDL_SCANCODE_A)))),
            @as(f32, @floatFromInt(@intFromBool(self.key(c.SDL_SCANCODE_W)))) -
                @as(f32, @floatFromInt(@intFromBool(self.key(c.SDL_SCANCODE_S)))),
        });
        try self.sendClientMessage(try self.client.input(
            target_tick,
            move,
            self.camera.yaw,
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

    fn render(self: *App, now_ns: u64) !void {
        switch (try self.gpu.beginFrame(renderer.Colors.CORNFLOWER_BLUE)) {
            .unavailable => return,
            .ready => {},
        }
        const size = self.gpu.getWindowSize();
        const aspect = @as(f32, @floatFromInt(size.width)) /
            @as(f32, @floatFromInt(size.height));
        if (self.ownedVehiclePresentation(now_ns)) |owned| {
            self.camera.followTarget(.{
                owned.position[0],
                owned.position[1] + 0.75,
                owned.position[2],
            }, 9);
        } else for (self.client.world.slice()) |entry| {
            const state = self.presentedState(entry, now_ns);
            if (!std.meta.eql(state.owner, self.client.participant)) continue;
            self.camera.followTarget(.{
                state.position[0],
                state.position[1] + 0.9,
                state.position[2],
            }, 7);
            break;
        }
        const view_projection = self.camera.getViewProjectionMatrix(aspect);
        self.gpu.drawMesh(&self.ground, zm.identity(), view_projection);
        for (self.client.world.slice()) |entry| {
            const state = self.presentedState(entry, now_ns);
            if (self.participantDriving(state.owner)) continue;
            const half_yaw = state.facing_yaw * 0.5;
            const rotation = zm.quatToMat(zm.f32x4(0, @sin(half_yaw), 0, @cos(half_yaw)));
            const translation = zm.translation(
                state.position[0],
                state.position[1],
                state.position[2],
            );
            self.gpu.drawMeshWithMaterial(
                &self.character,
                null,
                if (std.meta.eql(state.owner, self.client.participant))
                    .{ 0.15, 0.95, 0.25, 1 }
                else
                    .{ 0.95, 0.25, 0.15, 1 },
                zm.mul(rotation, translation),
                view_projection,
            );
        }
        for (self.client.world.vehicleSlice()) |entry| {
            const state = self.presentedVehicle(entry, now_ns);
            const scale = zm.scaling(1.8, 0.5, 4.0);
            const rotation = zm.quatToMat(zm.f32x4(
                state.rotation[0],
                state.rotation[1],
                state.rotation[2],
                state.rotation[3],
            ));
            const translation = zm.translation(
                state.position[0],
                state.position[1],
                state.position[2],
            );
            self.gpu.drawMeshWithMaterial(
                &self.vehicle,
                null,
                if (state.driver != null) .{ 0.95, 0.65, 0.10, 1 } else .{ 0.25, 0.35, 0.95, 1 },
                zm.mul(zm.mul(scale, rotation), translation),
                view_projection,
            );
        }
        self.gpu.endRenderPass();
        try self.gpu.submitFrame();
    }

    fn updateTitle(self: *App) void {
        var title_storage: [256]u8 = undefined;
        const stats = self.network.stats(self.connection);
        const title = std.fmt.bufPrintZ(
            &title_storage,
            "Incinerator MP4-A2 | {s} | entities {d} | ping {d} ms | age {d}t | mode {s} | pred {s} | correction {d}/{d} max {d:.2}m/{d:.1}deg",
            .{
                @tagName(self.client.state),
                self.client.world.character_count + self.client.world.vehicle_count,
                if (stats) |value| value.ping_ms else -1,
                self.last_input_tick -| self.client.world.server_tick,
                if (self.client.ownedVehicle() != null) "vehicle" else "on-foot",
                if (self.vehicle_prediction_enabled) "on" else "off",
                self.client.vehicle_prediction.soft_corrections,
                self.client.vehicle_prediction.hard_corrections,
                self.client.vehicle_prediction.maximum_position_error_m,
                self.client.vehicle_prediction.maximum_orientation_error_degrees,
            },
        ) catch return;
        _ = c.SDL_SetWindowTitle(self.window, title.ptr);
    }

    fn key(self: *const App, scancode: c.SDL_Scancode) bool {
        const index: usize = @intCast(scancode);
        return index < self.keys.len and self.keys[index];
    }

    fn presentedState(
        self: *const App,
        entry: replicated_world.Entry,
        now_ns: u64,
    ) protocol.CharacterState {
        if (std.meta.eql(entry.current.owner, self.client.participant)) {
            if (self.client.localPresentation()) |predicted| return predicted;
        }
        const elapsed = now_ns -| self.last_snapshot_ns;
        const alpha = if (self.snapshot_interval_ns == 0)
            @as(f32, 1)
        else
            @as(f32, @floatFromInt(elapsed)) /
                @as(f32, @floatFromInt(self.snapshot_interval_ns));
        return replicated_world.World.interpolate(entry, alpha);
    }

    fn presentedVehicle(
        self: *const App,
        entry: replicated_world.VehicleEntry,
        now_ns: u64,
    ) protocol.VehicleState {
        if (self.vehicle_prediction_enabled and entry.current.driver != null and
            std.meta.eql(entry.current.driver.?, self.client.participant))
        {
            if (self.client.localVehiclePresentation()) |predicted| return predicted;
        }
        const elapsed = now_ns -| self.last_snapshot_ns;
        const alpha = if (self.snapshot_interval_ns == 0)
            @as(f32, 1)
        else
            @as(f32, @floatFromInt(elapsed)) /
                @as(f32, @floatFromInt(self.snapshot_interval_ns));
        return replicated_world.World.interpolateVehicle(entry, alpha);
    }

    fn ownedVehiclePresentation(self: *const App, now_ns: u64) ?protocol.VehicleState {
        for (self.client.world.vehicleSlice()) |entry| {
            if (entry.current.driver) |driver| {
                if (std.meta.eql(driver, self.client.participant)) {
                    return self.presentedVehicle(entry, now_ns);
                }
            }
        }
        return null;
    }

    fn participantDriving(self: *const App, participant: @TypeOf(self.client.participant)) bool {
        for (self.client.world.vehicleSlice()) |entry| {
            if (entry.current.driver) |driver| {
                if (std.meta.eql(driver, participant)) return true;
            }
        }
        return false;
    }
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const invocation = try parseInvocation(args);
    var app = try App.init(init, invocation);
    defer app.deinit();
    std.debug.print(
        "MP4_CLIENT_CONNECT endpoint={s} account={d} controls=WASD/SPACE/LSHIFT/E enter-exit/P prediction/F8 reconnect/ESC\n",
        .{ invocation.endpoint, invocation.account },
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
        } else if (std.mem.eql(u8, args[index], "--account")) {
            index += 1;
            if (index >= args.len) return error.MissingAccount;
            result.account = try std.fmt.parseInt(u64, args[index], 10);
            if (result.account == 0) return error.InvalidAccount;
        } else if (std.mem.eql(u8, args[index], "--max-frames")) {
            index += 1;
            if (index >= args.len) return error.MissingMaxFrames;
            result.max_frames = try std.fmt.parseInt(u64, args[index], 10);
        } else return error.UnknownArgument;
    }
    return result;
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
