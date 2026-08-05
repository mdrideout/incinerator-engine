//! SDL/editor/GPU-free S4-B capture and replay tool.

const std = @import("std");
const content = @import("content");
const district_content_catalog = @import("district_content_catalog");
const replay = @import("sandbox_replay");
const sandbox = @import("sandbox_simulation");
const sandbox_contracts = @import("sandbox_host_contracts");
const npc_contract = @import("npc_contract");

const fixture_coord = sandbox_contracts.ChunkCoord{ .x = 0, .z = 0 };
const worker_progress_limit: usize = 2_000;
const vehicle_settle_ticks: usize = 240;
const vehicle_drive_ticks: usize = 60;
const interaction_crossing_limit: usize = 800;
const npc_progress_limit: usize = 600;

const Request = struct {
    const crate_spawn: u64 = 1;
    const character_spawn: u64 = 2;
    const vehicle_spawn: u64 = 3;
    const district_load_cancelled: u64 = 4;
    const district_cancel: u64 = 5;
    const district_load_active: u64 = 6;
    const district_load_east: u64 = 7;
    const interaction_spawn: u64 = 8;
    const district_unload_destination: u64 = 9;
    const district_reload_destination: u64 = 10;
    const npc_spawn: u64 = 11;
};

const Transaction = struct {
    const collect: u64 = 1;
    const drop: u64 = 2;
};

const ScenarioState = struct {
    crate_id: ?sandbox_contracts.PersistentId = null,
    character_id: ?sandbox_contracts.PersistentId = null,
    vehicle_id: ?sandbox_contracts.PersistentId = null,
    carryable_id: ?sandbox_contracts.PersistentId = null,
    npc_id: ?sandbox_contracts.PersistentId = null,
    cancelled_ticket: ?sandbox_contracts.LoadTicket = null,
    active_ticket: ?sandbox_contracts.LoadTicket = null,
    east_ticket: ?sandbox_contracts.LoadTicket = null,
    crate_impulse_applied: bool = false,
    crate_despawned: bool = false,
    character_action_applied: bool = false,
    vehicle_entered: bool = false,
    vehicle_drive_count: usize = 0,
    vehicle_exited: bool = false,
    vehicle_despawned: bool = false,
    cancellation_requested: bool = false,
    cancellation_completed: bool = false,
    district_activated: bool = false,
    east_activated: bool = false,
    interaction_source: ?sandbox_contracts.ChunkCoord = null,
    interaction_destination: ?sandbox_contracts.ChunkCoord = null,
    carryable_collected: bool = false,
    crossed_district_boundary: bool = false,
    carryable_dropped: bool = false,
    destination_unloaded: bool = false,
    destination_reload_ticket: ?sandbox_contracts.LoadTicket = null,
    destination_reactivated: bool = false,
    npc_spawned: bool = false,
    npc_owner_transfers: usize = 0,
    npc_goal_reached: bool = false,
    npc_state_changes: usize = 0,

    fn requireSpawned(self: ScenarioState) !void {
        if (self.crate_id == null or self.character_id == null or self.vehicle_id == null) {
            return error.SmokeSpawnIncomplete;
        }
    }

    fn requireComplete(self: ScenarioState) !void {
        try self.requireSpawned();
        if (!self.crate_impulse_applied or
            !self.crate_despawned or
            !self.character_action_applied or
            !self.vehicle_entered or
            self.vehicle_drive_count != vehicle_drive_ticks or
            !self.vehicle_exited or
            !self.vehicle_despawned or
            self.cancelled_ticket == null or
            !self.cancellation_requested or
            !self.cancellation_completed or
            self.active_ticket == null or
            !self.district_activated or
            self.east_ticket == null or
            !self.east_activated or
            self.carryable_id == null or
            self.interaction_source == null or
            self.interaction_destination == null or
            !self.carryable_collected or
            !self.crossed_district_boundary or
            !self.carryable_dropped or
            !self.destination_unloaded or
            self.destination_reload_ticket == null or
            !self.destination_reactivated or
            self.npc_id == null or
            !self.npc_spawned or
            self.npc_owner_transfers == 0 or
            !self.npc_goal_reached)
        {
            return error.SmokeScenarioIncomplete;
        }
    }
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len == 2 and std.mem.eql(u8, args[1], "--help")) {
        printUsage();
        return;
    }
    if (args.len != 4) {
        printUsage();
        return error.InvalidArguments;
    }

    if (std.mem.eql(u8, args[1], "record-smoke")) {
        try recordSmoke(init, args[2], args[3]);
    } else if (std.mem.eql(u8, args[1], "verify")) {
        try verify(init, args[2], args[3], .match_only);
    } else if (std.mem.eql(u8, args[1], "verify-smoke")) {
        try verify(init, args[2], args[3], .altered_evidence);
    } else if (std.mem.eql(u8, args[1], "verify-incident")) {
        const capture_path = try std.fs.path.join(
            init.arena.allocator(),
            &.{ args[2], "replay/accepted-ingress.icrp" },
        );
        try verify(init, capture_path, args[3], .match_only);
    } else {
        printUsage();
        return error.UnknownCommand;
    }
}

fn printUsage() void {
    std.debug.print(
        \\usage:
        \\  incinerator_replay record-smoke <capture-path> <installed-content-root>
        \\  incinerator_replay verify        <capture-path> <installed-content-root>
        \\  incinerator_replay verify-smoke  <capture-path> <installed-content-root>
        \\  incinerator_replay verify-incident <run-folder> <installed-content-root>
        \\
    , .{});
}

fn recordSmoke(init: std.process.Init, capture_path: []const u8, root_path: []const u8) !void {
    const cohort = try loadFixtureCohort(init, root_path);
    var simulation = try sandbox.Simulation.init(init.gpa, .{
        .namespace = 0x5334_4252,
        .max_crates = 8,
        .interaction = .{ .drop_offset = .{ 0, 0.75, 0 } },
        .npc = .{ .move_speed = 12 },
    });
    defer simulation.deinit();

    switch (try simulation.beginFlightRecording(cohort, .{})) {
        .admitted => {},
        .rejected => |reason| {
            std.debug.print("capture boundary rejected: {s}\n", .{@tagName(reason)});
            return error.CaptureBoundaryRejected;
        },
    }

    var state = ScenarioState{};
    try runSmokeScenario(init.io, &simulation, &state);
    try state.requireComplete();
    if (simulation.flightRecordingIncompleteReason()) |reason| {
        std.debug.print("flight recording became incomplete: {s}\n", .{@tagName(reason)});
        return error.FlightRecordingIncomplete;
    }

    const capture = try simulation.finishFlightRecording(init.gpa);
    defer init.gpa.free(capture);
    if (capture.len > replay.max_envelope_bytes) return error.ReplayEnvelopeTooLarge;
    var parsed = try replay.parse(init.gpa, capture);
    defer parsed.deinit();
    try parsed.validateCompatible(cohort);
    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = capture_path,
        .data = capture,
    });
    std.debug.print(
        "recorded S4 replay: path={s} bytes={d} ticks={d}\n",
        .{ capture_path, capture.len, simulation.tickIndex() },
    );
}

const Verification = enum {
    match_only,
    altered_evidence,
};

fn verify(
    init: std.process.Init,
    capture_path: []const u8,
    root_path: []const u8,
    verification: Verification,
) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        capture_path,
        init.gpa,
        .limited(replay.max_envelope_bytes),
    );
    defer init.gpa.free(bytes);

    var parsed = try replay.parse(init.gpa, bytes);
    defer parsed.deinit();
    const expected_content = try loadFixtureCohort(init, root_path);
    try parsed.validateCompatible(expected_content);

    const completed_ticks = try requireMatchedReplay(
        init.gpa,
        parsed.view(),
        expected_content,
    );
    std.debug.print(
        "verified S4 replay: path={s} ticks={d}\n",
        .{ capture_path, completed_ticks },
    );
    if (verification == .altered_evidence) {
        try requireAlteredDistrictIngressDivergence(
            init.gpa,
            &parsed,
            expected_content,
        );
        const restored_ticks = try requireMatchedReplay(
            init.gpa,
            parsed.view(),
            expected_content,
        );
        if (restored_ticks != completed_ticks) return error.RestoredReplayTickMismatch;
        try requireAlteredInteractionCommandDivergence(
            init.gpa,
            &parsed,
            expected_content,
        );
        const twice_restored_ticks = try requireMatchedReplay(
            init.gpa,
            parsed.view(),
            expected_content,
        );
        if (twice_restored_ticks != completed_ticks) {
            return error.RestoredReplayTickMismatch;
        }
        try requireAlteredNpcGoalDivergence(
            init.gpa,
            &parsed,
            expected_content,
        );
        const thrice_restored_ticks = try requireMatchedReplay(
            init.gpa,
            parsed.view(),
            expected_content,
        );
        if (thrice_restored_ticks != completed_ticks) {
            return error.RestoredReplayTickMismatch;
        }
    }
}

fn requireMatchedReplay(
    allocator: std.mem.Allocator,
    capture: replay.CaptureView,
    expected_content: replay.ContentCohort,
) !u64 {
    return switch (try sandbox.replayCapture(allocator, capture, expected_content)) {
        .matched => |matched| matched.completed_ticks,
        .divergent => |divergence| {
            const category = if (divergence.category) |value|
                @tagName(value)
            else
                "tick_index";
            std.debug.print(
                "replay divergence: tick={d} category={s}\n",
                .{ divergence.tick_index, category },
            );
            return error.ReplayDiverged;
        },
    };
}

fn requireAlteredDistrictIngressDivergence(
    allocator: std.mem.Allocator,
    parsed: *replay.ParsedCapture,
    expected_content: replay.ContentCohort,
) !void {
    const ingress = findReadyDistrictIngress(parsed) orelse
        return error.MissingReadyDistrictIngress;
    const expected_tick = ingress.consumption_tick;
    const original_completion = ingress.completion;
    defer ingress.completion = original_completion;

    switch (ingress.completion) {
        .ready => |*ready| {
            if (ready.build.static_box_count == 0) return error.EmptyDistrictBuild;
            const box_index = @as(usize, ready.build.static_box_count) - 1;
            ready.build.static_boxes[box_index].half_extents[0] += 0.25;
            ready.build.checksum = try ready.build.calculateChecksum();
            try ready.build.validate();
            if (!sandbox_contracts.LoadTicket.eql(ready.ticket, original_completion.ready.ticket)) {
                return error.AlteredDistrictIngressTicket;
            }
            if (std.meta.eql(ready.build, original_completion.ready.build)) {
                return error.UnalteredDistrictBuild;
            }
        },
        else => unreachable,
    }

    switch (try sandbox.replayCapture(allocator, parsed.view(), expected_content)) {
        .matched => return error.AlteredDistrictIngressDidNotDiverge,
        .divergent => |divergence| {
            if (divergence.kind != .category_digest or
                divergence.tick_index != expected_tick or
                divergence.category != @as(?replay.DigestCategory, .district))
            {
                const category = if (divergence.category) |value|
                    @tagName(value)
                else
                    "tick_index";
                std.debug.print(
                    "unexpected altered-ingress divergence: expected_tick={d} actual_tick={d} category={s}\n",
                    .{ expected_tick, divergence.tick_index, category },
                );
                return error.UnexpectedAlteredDistrictIngressDivergence;
            }
            std.debug.print(
                "verified altered district ingress divergence: tick={d} category=district\n",
                .{expected_tick},
            );
        },
    }
}

fn findReadyDistrictIngress(
    parsed: *replay.ParsedCapture,
) ?*replay.DistrictCompletionIngress {
    for (parsed.district_ingress) |*ingress| {
        switch (ingress.completion) {
            .ready => return ingress,
            else => {},
        }
    }
    return null;
}

fn requireAlteredInteractionCommandDivergence(
    allocator: std.mem.Allocator,
    parsed: *replay.ParsedCapture,
    expected_content: replay.ContentCohort,
) !void {
    const record = findInteractionSpawnRecord(parsed) orelse
        return error.MissingInteractionSpawnCommand;
    const expected_tick = record.eligible_tick;
    const original_command = record.command;
    defer record.command = original_command;

    switch (record.command) {
        .interaction => |*interaction| switch (interaction.*) {
            .spawn => |*spawn| {
                spawn.half_extents[0] += 0.05;
                if (std.meta.eql(record.command, original_command)) {
                    return error.UnalteredInteractionCommand;
                }
            },
            else => unreachable,
        },
        else => unreachable,
    }

    switch (try sandbox.replayCapture(allocator, parsed.view(), expected_content)) {
        .matched => return error.AlteredInteractionCommandDidNotDiverge,
        .divergent => |divergence| {
            if (divergence.kind != .category_digest or
                divergence.tick_index != expected_tick or
                divergence.category != @as(?replay.DigestCategory, .interaction))
            {
                const category = if (divergence.category) |value|
                    @tagName(value)
                else
                    "tick_index";
                std.debug.print(
                    "unexpected altered-interaction divergence: expected_tick={d} actual_tick={d} category={s}\n",
                    .{ expected_tick, divergence.tick_index, category },
                );
                return error.UnexpectedAlteredInteractionDivergence;
            }
            std.debug.print(
                "verified altered interaction divergence: tick={d} category=interaction\n",
                .{expected_tick},
            );
        },
    }
}

fn findInteractionSpawnRecord(
    parsed: *replay.ParsedCapture,
) ?*replay.RecordedCommand {
    for (parsed.bootstrap_commands) |*record| switch (record.command) {
        .interaction => |interaction| if (interaction == .spawn) return record,
        else => {},
    };
    for (parsed.commands) |*record| switch (record.command) {
        .interaction => |interaction| if (interaction == .spawn) return record,
        else => {},
    };
    return null;
}

fn requireAlteredNpcGoalDivergence(
    allocator: std.mem.Allocator,
    parsed: *replay.ParsedCapture,
    expected_content: replay.ContentCohort,
) !void {
    const record = findNpcPatrolRecord(parsed) orelse return error.MissingNpcPatrolCommand;
    const expected_tick = record.eligible_tick;
    const original_command = record.command;
    defer record.command = original_command;

    switch (record.command) {
        .npc => |*npc| switch (npc.*) {
            .spawn => |*spawn| switch (spawn.goal) {
                .patrol_between => |*patrol| {
                    if (patrol.second.value !=
                        sandbox_contracts.market_terminal_destination.value)
                    {
                        return error.UnexpectedNpcPatrolGoal;
                    }
                    patrol.second =
                        sandbox_contracts.transit_yard_destination;
                },
                else => unreachable,
            },
            else => unreachable,
        },
        else => unreachable,
    }
    if (std.meta.eql(record.command, original_command)) {
        return error.UnalteredNpcGoalCommand;
    }

    switch (try sandbox.replayCapture(allocator, parsed.view(), expected_content)) {
        .matched => return error.AlteredNpcGoalDidNotDiverge,
        .divergent => |divergence| {
            if (divergence.kind != .category_digest or
                divergence.tick_index != expected_tick or
                divergence.category != @as(?replay.DigestCategory, .npc))
            {
                const category = if (divergence.category) |value|
                    @tagName(value)
                else
                    "tick_index";
                std.debug.print(
                    "unexpected altered-NPC divergence: expected_tick={d} " ++
                        "actual_tick={d} category={s}\n",
                    .{ expected_tick, divergence.tick_index, category },
                );
                return error.UnexpectedAlteredNpcDivergence;
            }
            std.debug.print(
                "verified altered NPC goal divergence: tick={d} category=npc\n",
                .{expected_tick},
            );
        },
    }
}

fn findNpcPatrolRecord(parsed: *replay.ParsedCapture) ?*replay.RecordedCommand {
    for (parsed.bootstrap_commands) |*record| {
        if (isNpcPatrolSpawn(record.command)) return record;
    }
    for (parsed.commands) |*record| {
        if (isNpcPatrolSpawn(record.command)) return record;
    }
    return null;
}

fn isNpcPatrolSpawn(command: replay.NormalizedCommand) bool {
    return switch (command) {
        .npc => |npc| switch (npc) {
            .spawn => |spawn| spawn.goal == .patrol_between,
            else => false,
        },
        else => false,
    };
}

fn loadFixtureCohort(init: std.process.Init, raw_root_path: []const u8) !replay.ContentCohort {
    const root_path = try content.ContentRootPath.parse(raw_root_path);
    var admission = switch (try district_content_catalog.admit(
        init.io,
        init.gpa,
        root_path,
    )) {
        .admitted => |value| value,
        .failed => |failure| {
            std.debug.print("installed district catalog failed admission: {any}\n", .{failure});
            return error.InstalledContentAdmissionFailed;
        },
    };
    defer admission.deinit();
    const build = try sandbox_contracts.proceduralDistrictBuild(fixture_coord);
    try admission.validateLogicalRecord(
        fixture_coord,
        build.recipe_version,
        build.checksum,
    );
    return admission.contentCohort();
}

fn runSmokeScenario(
    io: std.Io,
    simulation: *sandbox.Simulation,
    state: *ScenarioState,
) !void {
    try simulation.submit(.{ .spawn = .{
        .request_id = Request.crate_spawn,
        .pose = .{ .position = .{ 6, 8, 0 } },
    } });
    try simulation.submitCharacter(.{ .spawn = .{
        .request_id = Request.character_spawn,
        .position = .{ 0, 0, 2.5 },
    } });
    try simulation.submitVehicle(.{ .spawn = .{
        .request_id = Request.vehicle_spawn,
        .chassis = .{ .pose = .{ .position = .{ 0, 2, 0 } } },
    } });
    try tickAndDrain(simulation, state);
    try state.requireSpawned();

    try simulation.submit(.{ .impulse = .{
        .id = state.crate_id.?,
        .impulse = .{ 1.5, 0.5, -0.75 },
    } });
    try simulation.submitCharacter(.{ .actions = .{
        .id = state.character_id.?,
        .move = .{ 0.25, -0.5 },
        .facing_yaw = 0.25,
    } });
    try tickAndDrain(simulation, state);
    if (!state.crate_impulse_applied) return error.MissingCrateImpulseOutcome;
    if ((try simulation.character(state.character_id.?)).facing_yaw != 0.25) {
        return error.CharacterActionNotApplied;
    }
    state.character_action_applied = true;

    for (0..vehicle_settle_ticks) |_| try tickAndDrain(simulation, state);
    try simulation.submitVehicle(.{ .enter = .{
        .vehicle_id = state.vehicle_id.?,
        .driver_id = state.character_id.?,
    } });
    try tickAndDrain(simulation, state);
    if (!state.vehicle_entered) return error.MissingVehicleEnterOutcome;

    for (0..vehicle_drive_ticks) |tick_index| {
        const steering: f32 = if ((tick_index / 20) % 2 == 0) 0.15 else -0.15;
        try simulation.submitVehicle(.{ .drive = .{
            .vehicle_id = state.vehicle_id.?,
            .driver_id = state.character_id.?,
            .input = .{ .throttle = 0.65, .steering = steering },
        } });
        try tickAndDrain(simulation, state);
    }
    if (state.vehicle_drive_count != vehicle_drive_ticks) {
        return error.MissingVehicleDriveOutcome;
    }

    try simulation.submitVehicle(.{ .exit = .{
        .vehicle_id = state.vehicle_id.?,
        .driver_id = state.character_id.?,
    } });
    try tickAndDrain(simulation, state);
    if (!state.vehicle_exited) return error.MissingVehicleExitOutcome;
    try simulation.submitVehicle(.{ .despawn = .{ .id = state.vehicle_id.? } });
    try tickAndDrain(simulation, state);
    if (!state.vehicle_despawned) return error.MissingVehicleDespawnOutcome;
    try simulation.submit(.{ .despawn = .{ .id = state.crate_id.? } });
    try tickAndDrain(simulation, state);
    if (!state.crate_despawned) return error.MissingCrateDespawnOutcome;

    try simulation.submitDistrict(.{ .request_load = .{
        .request_id = Request.district_load_cancelled,
        .coord = fixture_coord,
        .assets = .{},
    } });
    try tickAndDrain(simulation, state);
    const cancelled_ticket = state.cancelled_ticket orelse
        return error.MissingDistrictLoadRequestOutcome;

    try simulation.submitDistrict(.{ .cancel_load = .{
        .request_id = Request.district_cancel,
        .ticket = cancelled_ticket,
    } });
    try tickAndDrain(simulation, state);
    if (!state.cancellation_requested) return error.MissingDistrictCancellationOutcome;
    try progressWorkerUntil(io, simulation, state, .cancelled);

    try simulation.submitDistrict(.{ .request_load = .{
        .request_id = Request.district_load_active,
        .coord = fixture_coord,
        .assets = .{},
    } });
    try tickAndDrain(simulation, state);
    if (state.active_ticket == null) return error.MissingDistrictReloadOutcome;
    try progressWorkerUntil(io, simulation, state, .activated);

    try simulation.submitDistrict(.{ .request_load = .{
        .request_id = Request.district_load_east,
        .coord = .{ .x = 1, .z = 0 },
        .assets = .{},
    } });
    try tickAndDrain(simulation, state);
    if (state.east_ticket == null) return error.MissingEastDistrictLoadOutcome;
    try progressWorkerUntil(io, simulation, state, .east_activated);
    if (simulation.districtCount() != 2 or simulation.districtBodyCount() != 6) {
        return error.MultiDistrictAuthorityMissing;
    }

    try simulation.submitNpc(.{ .spawn = .{
        .request_id = Request.npc_spawn,
        .position = .{ -5, 0, 5 },
        .facing_yaw = 0,
        .anchor = .{ .coord = sandbox_contracts.navigation_west_coord, .index = 0 },
        .hostile_to_players = true,
        .goal = .{ .patrol_between = .{
            .first = sandbox_contracts.player_plaza_destination,
            .second = sandbox_contracts.market_terminal_destination,
        } },
    } });
    try tickAndDrain(simulation, state);
    if (!state.npc_spawned or state.npc_id == null) return error.MissingNpcSpawnOutcome;
    for (0..npc_progress_limit) |_| {
        if (state.npc_owner_transfers != 0 and state.npc_goal_reached) break;
        try tickAndDrain(simulation, state);
    }
    if (state.npc_owner_transfers == 0 or !state.npc_goal_reached) {
        return error.NpcPatrolDidNotTransition;
    }
    const npc_view = try simulation.npc(state.npc_id.?);
    if (npc_view.goal != .patrol_between or
        !npc_view.controller_present or
        npc_view.state == .dormant)
    {
        return error.UnexpectedNpcPatrolState;
    }
    const npc_diagnostics = simulation.diagnostics().npc;
    if (npc_diagnostics.commands.occupancy != 0 or
        npc_diagnostics.outcomes.occupancy != 0 or
        npc_diagnostics.events.occupancy != 0 or
        npc_diagnostics.event_drops.total() != 0)
    {
        return error.NpcAuthorityOutputNotDrained;
    }

    const character_before_collect = try simulation.character(state.character_id.?);
    try simulation.submitInteraction(.{ .spawn = .{
        .request_id = Request.interaction_spawn,
        .pose = .{ .position = .{
            character_before_collect.position[0],
            character_before_collect.position[1] + 2.0,
            character_before_collect.position[2],
        } },
    } });
    try tickAndDrain(simulation, state);
    const carryable_id = state.carryable_id orelse
        return error.MissingCarryableSpawnOutcome;
    const source = state.interaction_source orelse
        return error.MissingCarryableSource;
    const destination = if (sandbox_contracts.ChunkCoord.eql(source, fixture_coord))
        sandbox_contracts.ChunkCoord{ .x = 1, .z = 0 }
    else if (sandbox_contracts.ChunkCoord.eql(source, .{ .x = 1, .z = 0 }))
        fixture_coord
    else
        return error.CarryableSpawnedOutsideActiveDistricts;
    state.interaction_destination = destination;

    try simulation.submitInteraction(.{ .collect = .{
        .transaction_id = Transaction.collect,
        .carrier_id = state.character_id.?,
        .carryable_id = carryable_id,
    } });
    try tickAndDrain(simulation, state);
    if (!state.carryable_collected) return error.MissingCollectOutcome;
    const held = try simulation.carryable(carryable_id);
    if (!std.meta.eql(held.ownership, .{ .inventory_held = state.character_id.? }) or
        held.body_present)
    {
        return error.HeldCarryableOwnershipMismatch;
    }

    const direction: f32 = if (destination.x > source.x) 1 else -1;
    for (0..interaction_crossing_limit) |_| {
        const position = (try simulation.character(state.character_id.?)).position;
        const crossed = if (direction > 0) position[0] >= 8 else position[0] < 8;
        if (crossed) {
            state.crossed_district_boundary = true;
            break;
        }
        try simulation.submitCharacter(.{ .actions = .{
            .id = state.character_id.?,
            .move = .{ direction, 0 },
            .facing_yaw = 0,
        } });
        try tickAndDrain(simulation, state);
    }
    if (!state.crossed_district_boundary) {
        const final_position = (try simulation.character(state.character_id.?)).position;
        std.debug.print(
            "interaction crossing failed: source=({d},{d}) destination=({d},{d}) " ++
                "direction={d} start_x={d} final=({d},{d},{d})\n",
            .{
                source.x,
                source.z,
                destination.x,
                destination.z,
                direction,
                character_before_collect.position[0],
                final_position[0],
                final_position[1],
                final_position[2],
            },
        );
        return error.CharacterDidNotCrossDistrictBoundary;
    }

    try simulation.submitInteraction(.{ .drop = .{
        .transaction_id = Transaction.drop,
        .carrier_id = state.character_id.?,
        .carryable_id = carryable_id,
        .purpose = .player_requested,
    } });
    try tickAndDrain(simulation, state);
    if (!state.carryable_dropped) return error.MissingDropOutcome;
    const dropped = try simulation.carryable(carryable_id);
    if (!std.meta.eql(dropped.ownership, .{ .spatially_owned = destination }) or
        !dropped.body_present)
    {
        return error.DroppedCarryableOwnershipMismatch;
    }

    const destination_ticket = if (sandbox_contracts.ChunkCoord.eql(destination, fixture_coord))
        state.active_ticket.?
    else
        state.east_ticket.?;
    try simulation.submitDistrict(.{ .unload = .{
        .request_id = Request.district_unload_destination,
        .ticket = destination_ticket,
    } });
    try tickAndDrain(simulation, state);
    if (!state.destination_unloaded) return error.MissingDestinationUnloadOutcome;
    const content_unloaded = try simulation.carryable(carryable_id);
    if (!std.meta.eql(content_unloaded.ownership, .{ .spatially_owned = destination }) or
        !content_unloaded.body_present)
    {
        return error.ContentUnloadedCarryableOwnershipMismatch;
    }

    try simulation.submitDistrict(.{ .request_load = .{
        .request_id = Request.district_reload_destination,
        .coord = destination,
        .assets = .{},
    } });
    try tickAndDrain(simulation, state);
    if (state.destination_reload_ticket == null) {
        return error.MissingDestinationReloadOutcome;
    }
    try progressWorkerUntil(io, simulation, state, .destination_reactivated);
    const content_reloaded = try simulation.carryable(carryable_id);
    if (!std.meta.eql(content_reloaded.ownership, .{ .spatially_owned = destination }) or
        !content_reloaded.body_present)
    {
        return error.ContentReloadedCarryableOwnershipMismatch;
    }
    if (simulation.districtCount() != 2 or simulation.districtBodyCount() != 6) {
        return error.MultiDistrictAuthorityMissingAfterInteraction;
    }
}

const WorkerGoal = enum { cancelled, activated, east_activated, destination_reactivated };

fn progressWorkerUntil(
    io: std.Io,
    simulation: *sandbox.Simulation,
    state: *ScenarioState,
    goal: WorkerGoal,
) !void {
    for (0..worker_progress_limit) |_| {
        const complete = switch (goal) {
            .cancelled => state.cancellation_completed,
            .activated => state.district_activated,
            .east_activated => state.east_activated,
            .destination_reactivated => state.destination_reactivated,
        };
        if (complete) return;
        try io.sleep(.fromMilliseconds(1), .awake);
        try tickAndDrain(simulation, state);
    }
    return error.DistrictWorkerDidNotComplete;
}

fn tickAndDrain(simulation: *sandbox.Simulation, state: *ScenarioState) !void {
    try simulation.tick();
    try drainOutputs(simulation, state);
}

fn drainOutputs(simulation: *sandbox.Simulation, state: *ScenarioState) !void {
    while (simulation.pollOutcome()) |outcome| switch (outcome) {
        .spawned => |spawned| {
            if (spawned.request_id != Request.crate_spawn or state.crate_id != null) {
                return error.UnexpectedCrateOutcome;
            }
            state.crate_id = spawned.id;
        },
        .impulse_applied => |id| {
            if (state.crate_id == null or !std.meta.eql(id, state.crate_id.?)) {
                return error.UnexpectedCrateOutcome;
            }
            state.crate_impulse_applied = true;
        },
        .despawned => |id| {
            if (state.crate_id == null or
                !std.meta.eql(id, state.crate_id.?) or
                state.crate_despawned)
            {
                return error.UnexpectedCrateOutcome;
            }
            state.crate_despawned = true;
        },
        .relocated, .rejected => return error.UnexpectedCrateOutcome,
    };

    while (simulation.pollCharacterOutcome()) |outcome| switch (outcome) {
        .spawned => |spawned| {
            if (spawned.request_id != Request.character_spawn or state.character_id != null) {
                return error.UnexpectedCharacterOutcome;
            }
            state.character_id = spawned.id;
        },
        .despawned, .rejected => return error.UnexpectedCharacterOutcome,
    };
    while (simulation.pollCharacterEvent() != null) {}

    while (simulation.pollVehicleOutcome()) |outcome| switch (outcome) {
        .spawned => |spawned| {
            if (spawned.request_id != Request.vehicle_spawn or state.vehicle_id != null) {
                return error.UnexpectedVehicleOutcome;
            }
            state.vehicle_id = spawned.id;
        },
        .entered => |entered| {
            try requireDriverTransition(state, entered.vehicle_id, entered.driver_id);
            if (state.vehicle_entered) return error.UnexpectedVehicleOutcome;
            state.vehicle_entered = true;
        },
        .drive_applied => |applied| {
            try requireDriverTransition(state, applied.vehicle_id, applied.driver_id);
            if (applied.input.throttle != 0.65 or
                @abs(applied.input.steering) != 0.15 or
                applied.input.brake != 0 or
                applied.input.hand_brake != 0)
            {
                return error.UnexpectedVehicleOutcome;
            }
            state.vehicle_drive_count += 1;
        },
        .exited => |exited| {
            try requireDriverTransition(state, exited.vehicle_id, exited.driver_id);
            if (state.vehicle_exited) return error.UnexpectedVehicleOutcome;
            state.vehicle_exited = true;
        },
        .abandoned => return error.UnexpectedVehicleOutcome,
        .despawned => |id| {
            if (state.vehicle_id == null or
                !std.meta.eql(id, state.vehicle_id.?) or
                state.vehicle_despawned)
            {
                return error.UnexpectedVehicleOutcome;
            }
            state.vehicle_despawned = true;
        },
        .rejected => return error.UnexpectedVehicleOutcome,
    };
    while (simulation.pollVehicleEvent() != null) {}

    while (simulation.pollDistrictOutcome()) |outcome| switch (outcome) {
        .load_requested => |requested| switch (requested.request_id) {
            Request.district_load_cancelled => {
                if (state.cancelled_ticket != null) return error.UnexpectedDistrictOutcome;
                state.cancelled_ticket = requested.ticket;
            },
            Request.district_load_active => {
                if (state.active_ticket != null) return error.UnexpectedDistrictOutcome;
                state.active_ticket = requested.ticket;
            },
            Request.district_load_east => {
                if (state.east_ticket != null) return error.UnexpectedDistrictOutcome;
                state.east_ticket = requested.ticket;
            },
            Request.district_reload_destination => {
                if (state.destination_reload_ticket != null or
                    state.interaction_destination == null or
                    !sandbox_contracts.ChunkCoord.eql(
                        requested.ticket.coord,
                        state.interaction_destination.?,
                    ))
                {
                    return error.UnexpectedDistrictOutcome;
                }
                state.destination_reload_ticket = requested.ticket;
            },
            else => return error.UnexpectedDistrictOutcome,
        },
        .cancellation_requested => |requested| {
            if (requested.request_id != Request.district_cancel or
                state.cancelled_ticket == null or
                !sandbox_contracts.LoadTicket.eql(requested.ticket, state.cancelled_ticket.?))
            {
                return error.UnexpectedDistrictOutcome;
            }
            state.cancellation_requested = true;
        },
        .cancelled => |cancelled| {
            if (state.cancelled_ticket == null or
                !sandbox_contracts.LoadTicket.eql(cancelled.ticket, state.cancelled_ticket.?))
            {
                return error.UnexpectedDistrictOutcome;
            }
            state.cancellation_completed = true;
        },
        .activated => |activated| switch (activated.request_id) {
            Request.district_load_active => {
                if (state.active_ticket == null or
                    !sandbox_contracts.LoadTicket.eql(activated.ticket, state.active_ticket.?) or
                    !sandbox_contracts.ChunkCoord.eql(activated.coord, fixture_coord) or
                    activated.static_box_count != 3)
                {
                    return error.UnexpectedDistrictOutcome;
                }
                state.district_activated = true;
            },
            Request.district_load_east => {
                if (state.east_ticket == null or
                    !sandbox_contracts.LoadTicket.eql(activated.ticket, state.east_ticket.?) or
                    !sandbox_contracts.ChunkCoord.eql(activated.coord, .{ .x = 1, .z = 0 }) or
                    activated.static_box_count != 3)
                {
                    return error.UnexpectedDistrictOutcome;
                }
                state.east_activated = true;
            },
            Request.district_reload_destination => {
                if (state.destination_reload_ticket == null or
                    state.interaction_destination == null or
                    !sandbox_contracts.LoadTicket.eql(
                        activated.ticket,
                        state.destination_reload_ticket.?,
                    ) or
                    !sandbox_contracts.ChunkCoord.eql(
                        activated.coord,
                        state.interaction_destination.?,
                    ) or
                    activated.static_box_count != 3)
                {
                    return error.UnexpectedDistrictOutcome;
                }
                state.destination_reactivated = true;
            },
            else => return error.UnexpectedDistrictOutcome,
        },
        .load_failed => |failed| {
            std.debug.print("district worker failed during capture: {any}\n", .{failed.failure});
            return error.DistrictLoadFailed;
        },
        .unloaded => |unloaded| {
            if (unloaded.request_id != Request.district_unload_destination or
                state.interaction_destination == null or
                !sandbox_contracts.ChunkCoord.eql(
                    unloaded.ticket.coord,
                    state.interaction_destination.?,
                ))
            {
                return error.UnexpectedDistrictOutcome;
            }
            state.destination_unloaded = true;
        },
        .rejected => return error.UnexpectedDistrictOutcome,
    };
    while (simulation.pollDistrictEvent() != null) {}

    while (simulation.pollInteractionOutcome()) |outcome| switch (outcome) {
        .spawned => |spawned| {
            if (spawned.request_id != Request.interaction_spawn or
                state.carryable_id != null)
            {
                return error.UnexpectedInteractionOutcome;
            }
            state.carryable_id = spawned.id;
            state.interaction_source = spawned.owner;
        },
        .collected => |collected| {
            if (collected.transaction_id != Transaction.collect or
                state.character_id == null or
                state.carryable_id == null or
                state.interaction_source == null or
                !std.meta.eql(collected.carrier_id, state.character_id.?) or
                !std.meta.eql(collected.carryable_id, state.carryable_id.?) or
                !sandbox_contracts.ChunkCoord.eql(
                    collected.previous_owner,
                    state.interaction_source.?,
                ))
            {
                return error.UnexpectedInteractionOutcome;
            }
            state.carryable_collected = true;
        },
        .dropped => |dropped| {
            if (dropped.transaction_id != Transaction.drop or
                state.character_id == null or
                state.carryable_id == null or
                state.interaction_destination == null or
                !std.meta.eql(dropped.carrier_id, state.character_id.?) or
                !std.meta.eql(dropped.carryable_id, state.carryable_id.?) or
                !sandbox_contracts.ChunkCoord.eql(dropped.owner, state.interaction_destination.?))
            {
                return error.UnexpectedInteractionOutcome;
            }
            state.carryable_dropped = true;
        },
        .despawned, .rejected => return error.UnexpectedInteractionOutcome,
    };

    while (simulation.pollNpcOutcome()) |outcome| switch (outcome) {
        .spawned => |spawned| {
            if (spawned.request_id != Request.npc_spawn or
                state.npc_id != null or
                !sandbox_contracts.ChunkCoord.eql(spawned.owner, sandbox_contracts.navigation_west_coord))
            {
                return error.UnexpectedNpcOutcome;
            }
            state.npc_id = spawned.id;
            state.npc_spawned = true;
        },
        .goal_set, .despawned, .rejected => return error.UnexpectedNpcOutcome,
    };
    while (simulation.pollNpcEvent()) |event| switch (event) {
        .state_changed => |changed| {
            try requireNpcIdentity(state, changed.id);
            if (changed.previous == changed.current) return error.UnexpectedNpcEvent;
            state.npc_state_changes += 1;
        },
        .owner_transferred => |transferred| {
            try requireNpcIdentity(state, transferred.id);
            const west_to_east = sandbox_contracts.ChunkCoord.eql(
                transferred.previous,
                sandbox_contracts.navigation_west_coord,
            ) and sandbox_contracts.ChunkCoord.eql(
                transferred.current,
                sandbox_contracts.navigation_east_coord,
            );
            const east_to_west = sandbox_contracts.ChunkCoord.eql(
                transferred.previous,
                sandbox_contracts.navigation_east_coord,
            ) and sandbox_contracts.ChunkCoord.eql(
                transferred.current,
                sandbox_contracts.navigation_west_coord,
            );
            if (!west_to_east and !east_to_west) return error.UnexpectedNpcEvent;
            state.npc_owner_transfers += 1;
        },
        .goal_reached => |reached| {
            try requireNpcIdentity(state, reached.id);
            const is_west = npc_contract.DestinationId.eql(
                reached.destination,
                sandbox_contracts.player_plaza_destination,
            );
            const is_east = npc_contract.DestinationId.eql(
                reached.destination,
                sandbox_contracts.market_terminal_destination,
            );
            if (!is_west and !is_east) return error.UnexpectedNpcEvent;
            state.npc_goal_reached = true;
        },
    };
}

fn requireNpcIdentity(state: *const ScenarioState, id: sandbox_contracts.PersistentId) !void {
    if (state.npc_id == null or !std.meta.eql(id, state.npc_id.?)) {
        return error.UnexpectedNpcEvent;
    }
}

fn requireDriverTransition(
    state: *const ScenarioState,
    vehicle_id: sandbox_contracts.PersistentId,
    driver_id: sandbox_contracts.PersistentId,
) !void {
    if (state.vehicle_id == null or
        state.character_id == null or
        !std.meta.eql(vehicle_id, state.vehicle_id.?) or
        !std.meta.eql(driver_id, state.character_id.?))
    {
        return error.UnexpectedVehicleOutcome;
    }
}
