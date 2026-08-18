//! Graphical MP6 private-listen host for Apple Silicon macOS.
//!
//! The local player renders a replicated client world and reaches the shared
//! embedded authority through the typed local link. Invited guests use the
//! GNS route emitted in the account-bound room ticket.

const std = @import("std");
const budgets = @import("session_budgets");
const protocol = @import("session_protocol");
const listen_room = @import("mp6_listen_room");
const client_scene = @import("client_scene");
const presentation = @import("mp2_presentation");
const gameplay_scenarios = @import("sandbox_gameplay_scenarios");
const c = presentation.c;

const default_ticket_path = "/tmp/incinerator-mp6-listen/account-2.room";
const max_ticks_per_frame: u8 = 8;
const s11_peer_completion_timeout_ticks: u64 = 600;
const s11_scenario = gameplay_scenarios.get(
    .hostile_npc_approach_contact_death_respawn,
);

const Invocation = struct {
    config: listen_room.Config = .{},
    ticket_path: []const u8 = default_ticket_path,
    max_frames: ?u64 = null,
    smoke_actions: bool = false,
    s10_attacker: bool = false,
    s11_observer: bool = false,
    s14_ranged_observer: bool = false,
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
    weapon_action_requested: ?protocol.WeaponActionKind = null,
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
    s11_observer: bool = false,
    s11_dead_npc_index: u32 = 0,
    s11_dead_npc_generation: u16 = 0,
    s11_death_tick: u64 = 0,
    s11_death_observed: bool = false,
    s11_replacement_observed: bool = false,
    s11_completion_tick: ?u64 = null,
    s11_last_respawn_request_tick: u64 = 0,
    s11_scenario_start_tick: ?u64 = null,
    s14_ranged_observer: bool = false,
    s14_shot_observed: bool = false,

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
            .s11_observer = invocation.s11_observer,
            .s14_ranged_observer = invocation.s14_ranged_observer,
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
                self.scheduleS11Actions();
                try self.submitInput();
                try self.submitActions();
                try self.room.step(try unixSeconds(self.io));
                while (self.room.takeCombatFeedback()) |feedback| {
                    if (self.s14_ranged_observer) switch (feedback) {
                        .shot => |event| {
                            self.s14_shot_observed = true;
                            std.debug.print(
                                "S14_LISTEN_OBSERVER_SHOT shooter={d}:{d} result={s} target={d}:{d} damage={d}\n",
                                .{
                                    event.shooter.index,
                                    event.shooter.generation,
                                    @tagName(event.disposition),
                                    event.target.index,
                                    event.target.generation,
                                    event.applied_damage,
                                },
                            );
                        },
                        else => {},
                    };
                    self.scene.noteCombatFeedback(&self.room.client, feedback);
                }
                self.completed_ticks += 1;
            }
            const snapshot_tick = self.room.client.world.server_tick;
            if (snapshot_tick != 0 and snapshot_tick != self.last_snapshot_tick) {
                self.scene.observeAppliedWorld(&self.room.client, now_ns);
                self.last_snapshot_tick = snapshot_tick;
            }
            self.observeSmokeProgress();
            self.observeS11Lifecycle();
            self.finishS10Smoke();
            self.finishS11Observer();
            try self.validateS11Deadline();
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
                    if (self.room.client.avatar_life_state == .dead)
                        self.respawn_action_requested = true
                    else
                        self.weapon_action_requested = .reload;
                }
                if (event.key.scancode == c.SDL_SCANCODE_1 and !was_down) {
                    self.weapon_action_requested = .equip_toggle;
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
            c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
                if (event.button.button == c.SDL_BUTTON_RIGHT) {
                    self.scene.setLookActive(true);
                } else if (event.button.button == c.SDL_BUTTON_LEFT) {
                    self.weapon_action_requested = .fire;
                }
            },
            c.SDL_EVENT_MOUSE_BUTTON_UP => {
                if (event.button.button == c.SDL_BUTTON_RIGHT) {
                    self.scene.setLookActive(false);
                }
            },
            c.SDL_EVENT_MOUSE_MOTION => self.scene.applyLookMotion(
                event.motion.xrel,
                event.motion.yrel,
            ),
            c.SDL_EVENT_WINDOW_FOCUS_LOST => {
                self.keys = @splat(false);
                self.scene.cancelLook();
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
            const seek_s11_replacement = self.s11_observer and self.s11_death_observed and
                self.completed_ticks >= self.s11_death_tick +| 360;
            const move = if (seek_s11_replacement)
                [2]f32{ 0, 1 }
            else if (self.s10_attacker and self.guest_join_announced)
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
                if (seek_s11_replacement)
                    std.math.pi / 2.0
                else if (self.s10_attacker and self.guest_join_announced)
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
        if (self.weapon_action_requested) |action| {
            self.weapon_action_requested = null;
            try self.room.requestHostWeapon(action);
        }
        if (self.respawn_action_requested) {
            self.respawn_action_requested = false;
            self.room.requestHostRespawn() catch |err| {
                if (!recoverableRespawnRequestError(err)) return err;
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

    fn scheduleS11Actions(self: *App) void {
        if (!self.s11_observer or self.room.client.state != .joined or
            self.room.client.avatar_life_state != .dead)
        {
            return;
        }
        const tick = self.room.client.world.server_tick;
        if (self.s11_scenario_start_tick == null) self.s11_scenario_start_tick = tick;
        if (self.room.client.pending_respawn_action != null or
            tick < self.room.client.respawn_ready_tick or
            tick < self.s11_last_respawn_request_tick +| 30)
        {
            return;
        }
        self.respawn_action_requested = true;
        self.s11_last_respawn_request_tick = tick;
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

    fn observeS11Lifecycle(self: *App) void {
        if (!self.s11_observer or self.room.client.state != .joined) return;
        if (!self.s11_death_observed) {
            for (self.room.client.world.npcSlice()) |entry| {
                if (entry.current.life_state != .dead) continue;
                self.s11_death_observed = true;
                self.s11_dead_npc_index = entry.current.entity.index;
                self.s11_dead_npc_generation = entry.current.entity.generation;
                self.s11_death_tick = self.completed_ticks;
                std.debug.print(
                    "S11_LISTEN_OBSERVER_DEATH entity={d} generation={d}\n",
                    .{ self.s11_dead_npc_index, self.s11_dead_npc_generation },
                );
                break;
            }
        }
        if (!self.s11_death_observed or self.s11_replacement_observed) return;
        for (self.room.client.world.npcSlice()) |entry| {
            if (entry.current.entity.index != self.s11_dead_npc_index or
                entry.current.entity.generation == self.s11_dead_npc_generation or
                entry.current.life_state != .alive)
            {
                continue;
            }
            self.s11_replacement_observed = true;
            self.s11_completion_tick = self.completed_ticks;
            std.debug.print(
                "S11_LISTEN_OBSERVER_REPLACEMENT entity={d} previous_generation={d} current_generation={d}\n",
                .{
                    entry.current.entity.index,
                    self.s11_dead_npc_generation,
                    entry.current.entity.generation,
                },
            );
            break;
        }
    }

    fn finishS11Observer(self: *App) void {
        const completion = self.s11_completion_tick orelse return;
        if (self.completed_ticks < completion +| 60) return;
        const view = self.room.roomView();
        for (view.memberSlice()) |member| {
            if (!member.local and member.connection == .connected) return;
        }
        if (self.s14_ranged_observer) {
            if (!self.s14_shot_observed) return;
            std.debug.print(
                "S14_LISTEN_OBSERVER_PASS shot=true npc_death=true replacement=true\n",
                .{},
            );
        } else {
            std.debug.print(
                "S11_LISTEN_OBSERVER_PASS npc_death=true replacement=true\n",
                .{},
            );
        }
        self.running = false;
        self.s11_completion_tick = null;
    }

    fn validateS11Deadline(self: *const App) !void {
        if (!self.s11_observer) return;
        if (self.s11_completion_tick) |completion| {
            if (self.completed_ticks > completion +| s11_peer_completion_timeout_ticks) {
                return error.S11AttackerCompletionHandshakeTimedOut;
            }
            return;
        }
        const start = self.s11_scenario_start_tick orelse return;
        if (self.completed_ticks > start +| s11_scenario.deadline_ticks) {
            return error.S11SharedScenarioDeadlineExceeded;
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
        const combat_hud = self.scene.combatHud();
        const health = if (combat_hud) |hud| hud.health else 0;
        const maximum_health = if (combat_hud) |hud| hud.maximum_health else 0;
        const life = if (combat_hud) |hud| @tagName(hud.life_state) else "unknown";
        const melee_cooldown = if (combat_hud) |hud| hud.melee_remaining_ticks else 0;
        const respawn_cooldown = if (combat_hud) |hud| hud.respawn_remaining_ticks else 0;
        const respawn_disposition = if (combat_hud) |hud|
            if (hud.latest_respawn_disposition) |disposition|
                @tagName(disposition)
            else
                "none"
        else
            "none";
        var storage: [384]u8 = undefined;
        const title = std.fmt.bufPrintZ(
            &storage,
            "Private Room | {s} | members {d} | guest {s} | failure {s} | session {s} | HP {d}/{d} {s} respawn {d}t/{s} melee {d}t | entities {d} | mode {s} | carry {s}",
            .{
                @tagName(view.state),
                view.member_count,
                guest_state,
                failure,
                @tagName(self.room.client.state),
                health,
                maximum_health,
                life,
                respawn_cooldown,
                respawn_disposition,
                melee_cooldown,
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
        "MP6_LISTEN_READY endpoint={s}:{d} host={d} guest={d} ticket={s} controls=WASD/SPACE/LSHIFT/right-drag look/E enter-exit/F collect-drop/Q melee/1 handgun/left-click fire/R reload-respawn/P prediction/C-L-ESC close\n",
        .{
            invocation.config.advertise_host,
            invocation.config.port,
            invocation.config.host_account.value,
            invocation.config.guest_account.value,
            invocation.ticket_path,
        },
    );
    if (invocation.s11_observer) std.debug.print(
        "{s}_SCENARIO_ADAPTER topology=listen role=observer scenario={s} seed={x} deadline_ticks={d}\n",
        .{
            if (invocation.s14_ranged_observer) "S14" else "S11",
            s11_scenario.name,
            s11_scenario.seed,
            s11_scenario.deadline_ticks,
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
        } else if (std.mem.eql(u8, args[index], "--s11-observer")) {
            result.s11_observer = true;
        } else if (std.mem.eql(u8, args[index], "--s14-observer")) {
            result.s11_observer = true;
            result.s14_ranged_observer = true;
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

fn recoverableRespawnRequestError(err: anyerror) bool {
    return err == error.AvatarLifecycleUnavailable or err == error.AvatarAlive;
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

test "listen respawn control treats an already-living avatar as an idle press" {
    try std.testing.expect(recoverableRespawnRequestError(error.AvatarLifecycleUnavailable));
    try std.testing.expect(recoverableRespawnRequestError(error.AvatarAlive));
    try std.testing.expect(!recoverableRespawnRequestError(error.RespawnActionPending));
}
