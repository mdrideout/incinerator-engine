//! Graphical MP6 private-listen host for Apple Silicon macOS.
//!
//! The local player renders a replicated client world and reaches the shared
//! embedded authority through the typed local link. Invited guests use the
//! GNS route emitted in the account-bound room ticket.

const std = @import("std");
const budgets = @import("session_budgets");
const listen_room = @import("mp6_listen_room");
const client_scene = @import("client_scene");
const presentation = @import("mp2_presentation");
const c = presentation.c;

const default_ticket_path = "/tmp/incinerator-mp6-listen/account-2.room";
const max_ticks_per_frame: u8 = 8;

const Invocation = struct {
    config: listen_room.Config = .{},
    ticket_path: []const u8 = default_ticket_path,
    max_frames: ?u64 = null,
    smoke_actions: bool = false,
    s10_attacker: bool = false,
};

const App = struct {
    io: std.Io,
    window: *c.SDL_Window,
    scene: client_scene.Scene,
    room: *listen_room.Runtime,
    keys: [512]bool = @splat(false),
    running: bool = true,
    vehicle_action_requested: bool = false,
    carry_action_requested: bool = false,
    melee_action_requested: bool = false,
    respawn_action_requested: bool = false,
    frame: u64 = 0,
    completed_ticks: u64 = 0,
    last_snapshot_tick: u64 = 0,
    guest_join_announced: bool = false,
    smoke_actions: bool = false,
    smoke_milestones: u8 = 0,
    smoke_vehicle_start: ?[3]f32 = null,
    smoke_vehicle_moved: bool = false,
    smoke_walk_start: ?[3]f32 = null,
    smoke_walked: bool = false,
    s10_start_tick: ?u64 = null,
    s10_milestones: u8 = 0,
    s10_pass_printed: bool = false,
    s10_completion_tick: ?u64 = null,
    s10_attacker: bool = false,

    fn init(process_init: std.process.Init, invocation: Invocation) !App {
        const now = try unixSeconds(process_init.io);
        const room = try listen_room.Runtime.create(process_init.gpa, invocation.config, now);
        errdefer room.destroy();
        try room.writeGuestTicket(process_init.io, invocation.ticket_path);

        if (!c.SDL_Init(c.SDL_INIT_VIDEO)) return error.SDLInitFailed;
        errdefer c.SDL_Quit();
        const window = c.SDL_CreateWindow(
            "Incinerator Private Listen Room",
            960,
            540,
            c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_HIGH_PIXEL_DENSITY,
        ) orelse return error.SDLWindowFailed;
        errdefer c.SDL_DestroyWindow(window);
        var scene = try client_scene.Scene.init(window);
        errdefer scene.deinit();
        return .{
            .io = process_init.io,
            .window = window,
            .scene = scene,
            .room = room,
            .smoke_actions = invocation.smoke_actions,
            .s10_attacker = invocation.s10_attacker,
        };
    }

    fn deinit(self: *App) void {
        self.room.destroy();
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
            const due_wide = (@as(u128, now_ns) * budgets.authority_tick_hz) /
                std.time.ns_per_s;
            const due = std.math.cast(u64, due_wide) orelse
                return error.ListenClockRangeExceeded;
            var remaining = @min(due -| self.completed_ticks, max_ticks_per_frame);
            while (remaining > 0) : (remaining -= 1) {
                self.scheduleSmokeActions();
                self.scheduleS10Actions();
                try self.submitInput();
                try self.submitActions();
                try self.room.step(try unixSeconds(self.io));
                self.completed_ticks += 1;
            }
            const snapshot_tick = self.room.client.world.server_tick;
            if (snapshot_tick != 0 and snapshot_tick != self.last_snapshot_tick) {
                self.scene.observeSnapshot(now_ns);
                self.last_snapshot_tick = snapshot_tick;
            }
            self.observeSmokeProgress();
            self.finishS10Smoke();
            try self.scene.render(&self.room.client, now_ns);
            self.frame += 1;
            self.announceGuestJoin();
            if (self.frame % 30 == 0) self.updateTitle();
            if (due <= self.completed_ticks) {
                try std.Io.sleep(self.io, .fromMilliseconds(1), .awake);
            }
        }
        try self.finishSmokeActions();
        try self.room.close(self.io);
        std.debug.print(
            "MP6_LISTEN_CLOSED tick={d} host_migration=false\n",
            .{self.completed_ticks},
        );
    }

    fn pumpEvents(self: *App) void {
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event)) switch (event.type) {
            c.SDL_EVENT_QUIT, c.SDL_EVENT_WINDOW_CLOSE_REQUESTED => self.running = false,
            c.SDL_EVENT_KEY_DOWN => {
                const index: usize = @intCast(event.key.scancode);
                const was_down = index < self.keys.len and self.keys[index];
                if (index < self.keys.len) self.keys[index] = true;
                if (event.key.scancode == c.SDL_SCANCODE_E and !was_down) {
                    self.vehicle_action_requested = true;
                }
                if (event.key.scancode == c.SDL_SCANCODE_F and !was_down) {
                    self.carry_action_requested = true;
                }
                if (event.key.scancode == c.SDL_SCANCODE_Q and !was_down) {
                    self.melee_action_requested = true;
                }
                if (event.key.scancode == c.SDL_SCANCODE_R and !was_down) {
                    self.respawn_action_requested = true;
                }
                if (event.key.scancode == c.SDL_SCANCODE_P and !was_down) {
                    const enabled = self.scene.toggleVehiclePrediction();
                    std.debug.print("MP6_LISTEN_PREDICTION enabled={}\n", .{enabled});
                }
                if (event.key.scancode == c.SDL_SCANCODE_C or
                    event.key.scancode == c.SDL_SCANCODE_L or
                    event.key.scancode == c.SDL_SCANCODE_ESCAPE)
                {
                    self.running = false;
                }
            },
            c.SDL_EVENT_KEY_UP => {
                const index: usize = @intCast(event.key.scancode);
                if (index < self.keys.len) self.keys[index] = false;
            },
            else => {},
        };
    }

    fn submitInput(self: *App) !void {
        if (self.room.client.ownedVehicle() != null) {
            const scripted_drive = self.smoke_actions and
                self.completed_ticks >= 55 and self.completed_ticks < 60;
            const throttle = if (scripted_drive)
                @as(f32, 1)
            else
                axis(self.key(c.SDL_SCANCODE_W), self.key(c.SDL_SCANCODE_S));
            const steering = axis(self.key(c.SDL_SCANCODE_D), self.key(c.SDL_SCANCODE_A));
            try self.room.sendHostVehicleInput(
                throttle,
                steering,
                @floatFromInt(@intFromBool(self.key(c.SDL_SCANCODE_SPACE))),
                @floatFromInt(@intFromBool(self.key(c.SDL_SCANCODE_LSHIFT))),
            );
        } else {
            const move = if (self.s10_attacker and self.guest_join_announced)
                [2]f32{ 0, 0 }
            else if (self.smoke_actions and
                self.completed_ticks >= 75 and self.completed_ticks < 90)
                [2]f32{ -1, 0 }
            else
                [2]f32{
                    axis(self.key(c.SDL_SCANCODE_D), self.key(c.SDL_SCANCODE_A)),
                    axis(self.key(c.SDL_SCANCODE_W), self.key(c.SDL_SCANCODE_S)),
                };
            try self.room.sendHostInput(
                move,
                if (self.s10_attacker and self.guest_join_announced)
                    std.math.pi / 2.0
                else
                    self.scene.camera.yaw,
                self.key(c.SDL_SCANCODE_SPACE),
            );
        }
    }

    fn submitActions(self: *App) !void {
        if (self.vehicle_action_requested) {
            self.vehicle_action_requested = false;
            try self.room.toggleHostVehicle();
        }
        if (self.carry_action_requested) {
            self.carry_action_requested = false;
            try self.room.toggleHostCarry();
        }
        if (self.melee_action_requested) {
            self.melee_action_requested = false;
            try self.room.requestHostMelee();
        }
        if (self.respawn_action_requested) {
            self.respawn_action_requested = false;
            self.room.requestHostRespawn() catch |err| switch (err) {
                error.AvatarLifecycleUnavailable => {},
                else => return err,
            };
        }
    }

    fn scheduleSmokeActions(self: *App) void {
        if (!self.smoke_actions) return;
        if (self.completed_ticks >= 10 and self.smoke_milestones & 1 == 0) {
            self.carry_action_requested = true;
            self.smoke_milestones |= 1;
        }
        if (self.completed_ticks >= 25 and self.smoke_milestones & 2 == 0) {
            self.carry_action_requested = true;
            self.smoke_milestones |= 2;
        }
        if (self.completed_ticks >= 45 and self.smoke_milestones & 4 == 0) {
            self.vehicle_action_requested = true;
            self.smoke_milestones |= 4;
        }
        if (self.completed_ticks >= 65 and self.smoke_milestones & 8 == 0) {
            self.vehicle_action_requested = true;
            self.smoke_milestones |= 8;
        }
    }

    fn scheduleS10Actions(self: *App) void {
        if (!self.s10_attacker or !self.guest_join_announced or
            self.room.client.world.character_count < 2)
        {
            return;
        }
        if (self.s10_start_tick == null) self.s10_start_tick = self.completed_ticks;
        const elapsed = self.completed_ticks -| self.s10_start_tick.?;
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
    }

    fn finishS10Smoke(self: *App) void {
        if (!self.s10_attacker) return;
        if (self.s10_completion_tick) |completion_tick| {
            if (self.completed_ticks >= completion_tick +| 60) self.running = false;
            return;
        }
        const diagnostics = self.room.authority.session().diagnostics();
        if (self.room.client.melee_actions_accepted < 3 or
            diagnostics.deaths < 1 or diagnostics.respawns < 1)
        {
            return;
        }
        std.debug.print(
            "S10_LISTEN_ATTACKER_PASS hits={d} deaths={d} respawns={d}\n",
            .{
                self.room.client.melee_actions_accepted,
                diagnostics.deaths,
                diagnostics.respawns,
            },
        );
        self.s10_pass_printed = true;
        self.s10_completion_tick = self.completed_ticks;
    }

    fn observeSmokeProgress(self: *App) void {
        if (!self.smoke_actions or self.room.client.state != .joined) return;
        if (self.room.client.ownedVehicle()) |vehicle| {
            if (self.smoke_vehicle_start == null) {
                self.smoke_vehicle_start = vehicle.position;
            } else if (distanceSquared(self.smoke_vehicle_start.?, vehicle.position) > 0.0004) {
                self.smoke_vehicle_moved = true;
            }
        }
        if (self.completed_ticks >= 70 and self.room.client.ownedVehicle() == null) {
            if (localCharacterPosition(&self.room.client)) |position| {
                if (self.smoke_walk_start == null) {
                    self.smoke_walk_start = position;
                } else if (self.completed_ticks >= 90 and
                    distanceSquared(self.smoke_walk_start.?, position) > 0.01)
                {
                    self.smoke_walked = true;
                }
            }
        }
    }

    fn finishSmokeActions(self: *const App) !void {
        if (!self.smoke_actions) return;
        if (self.completed_ticks < 90 or
            self.room.client.vehicle_actions_accepted < 2 or
            self.room.client.interaction_actions_accepted < 2 or
            !self.smoke_vehicle_moved or !self.smoke_walked)
        {
            return error.ListenHostSmokeActionsIncomplete;
        }
        std.debug.print(
            "MP6_LISTEN_HOST_SMOKE_PASS walk=true drive=true carry=true vehicle_actions={d} interaction_actions={d}\n",
            .{
                self.room.client.vehicle_actions_accepted,
                self.room.client.interaction_actions_accepted,
            },
        );
    }

    fn announceGuestJoin(self: *App) void {
        if (self.guest_join_announced) return;
        const view = self.room.roomView();
        for (view.memberSlice()) |member| {
            if (!member.local and member.connection == .connected) {
                self.guest_join_announced = true;
                std.debug.print("MP6_LISTEN_GUEST_JOINED account={d}\n", .{
                    member.account.value,
                });
                return;
            }
        }
    }

    fn updateTitle(self: *App) void {
        const view = self.room.roomView();
        var guest_state: []const u8 = "none";
        for (view.memberSlice()) |member| {
            if (!member.local) guest_state = @tagName(member.connection);
        }
        const failure = if (view.failure) |value| @tagName(value) else "none";
        var storage: [256]u8 = undefined;
        const title = std.fmt.bufPrintZ(
            &storage,
            "Private Room | {s} | members {d} | guest {s} | failure {s} | session {s} | entities {d} | mode {s} | carry {s}",
            .{
                @tagName(view.state),
                view.member_count,
                guest_state,
                failure,
                @tagName(self.room.client.state),
                self.room.client.world.character_count +
                    self.room.client.world.vehicle_count +
                    self.room.client.world.carryable_count +
                    self.room.client.world.npc_count,
                if (self.room.client.ownedVehicle() != null) "vehicle" else "on-foot",
                if (self.room.client.heldCarryable() != null) "holding" else "empty",
            },
        ) catch return;
        _ = c.SDL_SetWindowTitle(self.window, title.ptr);
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
        "MP6_LISTEN_READY endpoint={s}:{d} host={d} guest={d} ticket={s} controls=WASD/SPACE/LSHIFT/E enter-exit/F collect-drop/Q melee/R respawn/P prediction/C-L-ESC close\n",
        .{
            invocation.config.advertise_host,
            invocation.config.port,
            invocation.config.host_account.value,
            invocation.config.guest_account.value,
            invocation.ticket_path,
        },
    );
    try app.run(invocation.max_frames);
}

fn parseInvocation(args: []const []const u8) !Invocation {
    var result = Invocation{};
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--port")) {
            index += 1;
            if (index >= args.len) return error.MissingPort;
            result.config.port = try std.fmt.parseInt(u16, args[index], 10);
        } else if (std.mem.eql(u8, args[index], "--ticket")) {
            index += 1;
            if (index >= args.len or args[index].len == 0) return error.MissingTicketPath;
            result.ticket_path = args[index];
        } else if (std.mem.eql(u8, args[index], "--max-frames")) {
            index += 1;
            if (index >= args.len) return error.MissingMaxFrames;
            result.max_frames = try std.fmt.parseInt(u64, args[index], 10);
        } else if (std.mem.eql(u8, args[index], "--allow-remote")) {
            result.config.allow_remote = true;
        } else if (std.mem.eql(u8, args[index], "--smoke-actions")) {
            result.smoke_actions = true;
        } else if (std.mem.eql(u8, args[index], "--s10-attacker")) {
            result.s10_attacker = true;
        } else if (std.mem.eql(u8, args[index], "--advertise")) {
            index += 1;
            if (index >= args.len or args[index].len == 0) return error.MissingAdvertiseHost;
            result.config.advertise_host = args[index];
        } else return error.UnknownArgument;
    }
    return result;
}

fn axis(positive: bool, negative: bool) f32 {
    return @as(f32, @floatFromInt(@intFromBool(positive))) -
        @as(f32, @floatFromInt(@intFromBool(negative)));
}

fn localCharacterPosition(client: anytype) ?[3]f32 {
    for (client.world.slice()) |entry| {
        if (std.meta.eql(entry.current.owner, client.participant)) {
            return entry.current.position;
        }
    }
    return null;
}

fn distanceSquared(a: [3]f32, b: [3]f32) f32 {
    const x = b[0] - a[0];
    const y = b[1] - a[1];
    const z = b[2] - a[2];
    return x * x + y * y + z * z;
}

fn unixSeconds(io: std.Io) !u64 {
    const nanoseconds = std.Io.Clock.Timestamp.now(io, .real).raw.nanoseconds;
    if (nanoseconds <= 0) return error.SystemClockBeforeUnixEpoch;
    return std.math.cast(u64, @divFloor(nanoseconds, std.time.ns_per_s)) orelse
        error.SystemClockRangeExceeded;
}

fn elapsedNs(start: std.Io.Clock.Timestamp, end: std.Io.Clock.Timestamp) u64 {
    const nanoseconds = start.durationTo(end).raw.nanoseconds;
    if (nanoseconds <= 0) return 0;
    return std.math.cast(u64, nanoseconds) orelse std.math.maxInt(u64);
}

test "listen invocation remains localhost-only by default" {
    const invocation = try parseInvocation(&.{"listen"});
    try std.testing.expectEqualStrings("127.0.0.1", invocation.config.advertise_host);
    try std.testing.expect(!invocation.config.allow_remote);
    try std.testing.expectEqualStrings(default_ticket_path, invocation.ticket_path);
}
