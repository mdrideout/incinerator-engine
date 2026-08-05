//! ReleaseFast S12 navigation measurement.
//!
//! Planner scale and physical movement are intentionally separate. The
//! planner cohort executes 64 deterministic requests per wave without native
//! actors. The Jolt cohort moves six controllers from distinct authored
//! anchors instead of manufacturing 64 deeply overlapping characters.

const std = @import("std");
const builtin = @import("builtin");
const content = @import("content");
const district_content_catalog = @import("district_content_catalog");
const navigation = @import("navigation_contract");
const navigation_planner = @import("navigation_planner");
const sandbox_contracts = @import("sandbox_host_contracts");
const sandbox_navigation = @import("sandbox_navigation");
const simulation = @import("sandbox_simulation");

const schema_version: u16 = 1;
const planner_waves: usize = 4_096;
const planner_request_cohort: usize = 64;
const planner_queries_per_wave: usize = 8;
const movement_ticks: usize = 2_048;
const movement_npcs: usize = 6;
const p99_ceiling_ns: u64 = 4_166_000;
const worker_progress_limit: usize = 10_000;

const Distribution = struct {
    samples: usize,
    mean_ns: f64,
    p50_ns: u64,
    p95_ns: u64,
    p99_ns: u64,
    max_ns: u64,
};

const PlannerReport = struct {
    request_cohort: usize,
    waves: usize,
    queries_per_wave: usize,
    total_queries: usize,
    route_digest_accumulator: u64,
    searched_nodes: u64,
    searched_edges: u64,
    timing: Distribution,
};

const MovementReport = struct {
    ticks: usize,
    npcs: usize,
    moved_npcs: usize,
    arrived_npcs: usize,
    blocked_npcs: usize,
    peak_controllers: u32,
    route_replans: u64,
    teleport_rollbacks: u64,
    timing: Distribution,
};

const Report = struct {
    schema_version: u16,
    benchmark: []const u8,
    zig_version: []const u8,
    optimize: []const u8,
    target_arch: []const u8,
    target_os: []const u8,
    content_cohort_fingerprint: []const u8,
    methodology: []const u8,
    planner: PlannerReport,
    movement: MovementReport,
    p99_ceiling_ns: u64,
};

pub fn main(init: std.process.Init) !void {
    if (builtin.mode != .ReleaseFast) {
        return error.S12MeasurementRequiresReleaseFast;
    }
    const root = try parseContentRoot(init);
    const fingerprint = try admitContentCohort(init, root);
    const fingerprint_hex = std.fmt.bytesToHex(fingerprint, .lower);
    const planner = try measurePlanner(init);
    const movement = try measureMovement(init);
    if (planner.timing.p99_ns > p99_ceiling_ns) {
        return error.S12PlannerWaveP99CeilingExceeded;
    }
    if (movement.timing.p99_ns > p99_ceiling_ns) {
        return error.S12MovementTickP99CeilingExceeded;
    }
    try writeJson(init, Report{
        .schema_version = schema_version,
        .benchmark = "s12-destination-navigation",
        .zig_version = builtin.zig_version_string,
        .optimize = @tagName(builtin.mode),
        .target_arch = @tagName(builtin.target.cpu.arch),
        .target_os = @tagName(builtin.target.os.tag),
        .content_cohort_fingerprint = &fingerprint_hex,
        .methodology = "64-request planner cohorts admitted at the eight-query authority budget over 4096 measured waves, plus 2048 real-Jolt ticks for six controllers at distinct authored anchors",
        .planner = planner,
        .movement = movement,
        .p99_ceiling_ns = p99_ceiling_ns,
    });
}

fn measurePlanner(init: std.process.Init) !PlannerReport {
    var samples: [planner_waves]u64 = undefined;
    var catalog = sandbox_navigation.CanonicalAccess{};
    const Access = sandbox_navigation.RuntimeAccess(sandbox_navigation.CanonicalAccess);
    var access = Access.init(&catalog);
    const start = navigation.NodeRef{
        .coord = sandbox_contracts.navigation_west_coord,
        .index = 0,
    };
    const destinations = [_]navigation.DestinationId{
        sandbox_contracts.market_terminal_destination,
        sandbox_contracts.alley_junction_destination,
        sandbox_contracts.transit_yard_destination,
    };
    var route_digest_accumulator: u64 = 0;
    var searched_nodes: u64 = 0;
    var searched_edges: u64 = 0;

    for (&samples, 0..) |*sample, wave| {
        _ = access.setGate(.north, wave % 2 == 0);
        const started = now(init.io);
        for (0..planner_queries_per_wave) |query| {
            const result = navigation_planner.plan(
                &access,
                start,
                destinations[query % destinations.len],
            );
            const route = switch (result) {
                .ready => |value| value,
                else => return error.S12PlannerWaveDidNotResolve,
            };
            if (route.len < 2 or route.active_prefix_len != route.len or
                route.digest == 0)
            {
                return error.S12PlannerWaveRouteInvalid;
            }
            route_digest_accumulator +%= route.digest;
            searched_nodes +%= route.searched_nodes;
            searched_edges +%= route.searched_edges;
        }
        sample.* = elapsedNs(started, now(init.io));
    }
    return .{
        .request_cohort = planner_request_cohort,
        .waves = planner_waves,
        .queries_per_wave = planner_queries_per_wave,
        .total_queries = planner_waves * planner_queries_per_wave,
        .route_digest_accumulator = route_digest_accumulator,
        .searched_nodes = searched_nodes,
        .searched_edges = searched_edges,
        .timing = summarize(&samples),
    };
}

fn measureMovement(init: std.process.Init) !MovementReport {
    var world = try simulation.Simulation.init(init.gpa, .{
        .namespace = 12_012,
        .fixed_delta_seconds = 1.0 / 120.0,
        .create_ground = false,
        .npc = .{ .move_speed = 4 },
    });
    defer world.deinit();
    _ = try activateDistrict(&world, 1, sandbox_contracts.navigation_west_coord);
    _ = try activateDistrict(&world, 2, sandbox_contracts.navigation_east_coord);

    const starts = [_]navigation.NodeRef{
        .{ .coord = sandbox_contracts.navigation_west_coord, .index = 0 },
        .{ .coord = sandbox_contracts.navigation_west_coord, .index = 1 },
        .{ .coord = sandbox_contracts.navigation_west_coord, .index = 2 },
        .{ .coord = sandbox_contracts.navigation_west_coord, .index = 3 },
        .{ .coord = sandbox_contracts.navigation_west_coord, .index = 4 },
        .{ .coord = sandbox_contracts.navigation_west_coord, .index = 5 },
    };
    const destinations = [_]navigation.DestinationId{
        sandbox_contracts.market_terminal_destination,
        sandbox_contracts.transit_yard_destination,
        sandbox_contracts.alley_junction_destination,
        sandbox_contracts.transit_yard_destination,
        sandbox_contracts.market_terminal_destination,
        sandbox_contracts.alley_junction_destination,
    };
    var initial_positions: [movement_npcs][3]f32 = undefined;
    for (starts, 0..) |start, index| {
        initial_positions[index] = (try world.navigationNodePosition(start)) orelse
            return error.S12MovementStartInactive;
        try world.submitNpc(.{ .spawn = .{
            .request_id = 100 + index,
            .position = initial_positions[index],
            .facing_yaw = 0,
            .anchor = start,
            .hostile_to_players = false,
            .goal = .{ .navigate_to = destinations[index] },
        } });
    }
    try world.tick();
    var ids: [movement_npcs]sandbox_contracts.PersistentId = undefined;
    var spawned: usize = 0;
    while (world.pollNpcOutcome()) |outcome| switch (outcome) {
        .spawned => |value| {
            if (spawned == ids.len) return error.S12MovementSpawnOverflow;
            ids[spawned] = value.id;
            spawned += 1;
        },
        else => return error.S12MovementSpawnRejected,
    };
    if (spawned != movement_npcs) return error.S12MovementSpawnMissing;
    drainOutputs(&world);

    var samples: [movement_ticks]u64 = undefined;
    var peak_controllers: u32 = 0;
    for (&samples) |*sample| {
        const started = now(init.io);
        try world.tick();
        sample.* = elapsedNs(started, now(init.io));
        const diagnostics = world.diagnostics();
        peak_controllers = @max(
            peak_controllers,
            diagnostics.character_controllers.native_used,
        );
        drainOutputs(&world);
    }

    var moved_npcs: usize = 0;
    var arrived_npcs: usize = 0;
    var blocked_npcs: usize = 0;
    var teleport_rollbacks: u64 = 0;
    for (ids, initial_positions) |id, initial| {
        const view = try world.npc(id);
        const dx = view.position[0] - initial[0];
        const dz = view.position[2] - initial[2];
        if (dx * dx + dz * dz > 0.25) moved_npcs += 1;
        switch (view.navigation_status) {
            .arrived => arrived_npcs += 1,
            .blocked => blocked_npcs += 1,
            else => {},
        }
        if (!view.controller_present) return error.S12MovementControllerMissing;
        teleport_rollbacks +%= view.navigation_lineage.teleport_rollback_count;
    }
    if (moved_npcs != movement_npcs or peak_controllers != movement_npcs or
        teleport_rollbacks != 0)
    {
        return error.S12MovementEvidenceInvalid;
    }
    return .{
        .ticks = movement_ticks,
        .npcs = movement_npcs,
        .moved_npcs = moved_npcs,
        .arrived_npcs = arrived_npcs,
        .blocked_npcs = blocked_npcs,
        .peak_controllers = peak_controllers,
        .route_replans = world.diagnostics().npc.replans,
        .teleport_rollbacks = teleport_rollbacks,
        .timing = summarize(&samples),
    };
}

fn activateDistrict(
    world: *simulation.Simulation,
    request_id: u64,
    coord: navigation.ChunkCoord,
) !navigation.LoadTicket {
    try world.submitDistrict(.{ .request_load = .{
        .request_id = request_id,
        .coord = coord,
        .assets = .{ .scene = .{ .index = 41, .generation = 3 } },
    } });
    try world.tick();
    const requested = world.pollDistrictOutcome() orelse
        return error.DistrictRequestOutcomeMissing;
    const ticket = switch (requested) {
        .load_requested => |value| value.ticket,
        else => return error.UnexpectedDistrictOutcome,
    };
    while (world.pollDistrictEvent() != null) {}

    for (0..worker_progress_limit) |_| {
        std.Thread.yield() catch {};
        try world.tick();
        while (world.pollDistrictOutcome()) |outcome| switch (outcome) {
            .activated => |value| {
                if (!navigation.LoadTicket.eql(ticket, value.ticket)) {
                    return error.UnexpectedDistrictTicket;
                }
                while (world.pollDistrictEvent() != null) {}
                return ticket;
            },
            .load_failed => return error.DistrictLoadFailed,
            .cancelled => return error.DistrictLoadCancelled,
            else => return error.UnexpectedDistrictOutcome,
        };
        while (world.pollDistrictEvent() != null) {}
    }
    return error.DistrictWorkerDidNotComplete;
}

fn drainOutputs(world: *simulation.Simulation) void {
    while (world.pollNpcEvent() != null) {}
    while (world.pollNpcNavigationTransition() != null) {}
}

fn admitContentCohort(
    init: std.process.Init,
    root: content.ContentRootPath,
) ![32]u8 {
    var admission = switch (try district_content_catalog.admit(
        init.io,
        init.gpa,
        root,
    )) {
        .admitted => |value| value,
        .failed => return error.S12InstalledContentAdmissionFailed,
    };
    defer admission.deinit();
    if (admission.view().entries.len != 2) {
        return error.S12InstalledContentCohortMismatch;
    }
    return admission.contentCohort().fingerprint();
}

fn parseContentRoot(init: std.process.Init) !content.ContentRootPath {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next() orelse return error.MissingExecutableName;
    const root = args.next() orelse return error.ExpectedInstalledContentRoot;
    if (args.next() != null) return error.TooManyS12MeasurementArguments;
    return content.ContentRootPath.parse(root);
}

fn summarize(samples: []u64) Distribution {
    std.mem.sort(u64, samples, {}, lessThanU64);
    var total: u128 = 0;
    for (samples) |sample| total += sample;
    return .{
        .samples = samples.len,
        .mean_ns = @as(f64, @floatFromInt(total)) /
            @as(f64, @floatFromInt(samples.len)),
        .p50_ns = samples[percentileIndex(samples.len, 50)],
        .p95_ns = samples[percentileIndex(samples.len, 95)],
        .p99_ns = samples[percentileIndex(samples.len, 99)],
        .max_ns = samples[samples.len - 1],
    };
}

fn percentileIndex(len: usize, percentile: usize) usize {
    return (len * percentile + 99) / 100 - 1;
}

fn lessThanU64(_: void, lhs: u64, rhs: u64) bool {
    return lhs < rhs;
}

fn now(io: std.Io) std.Io.Clock.Timestamp {
    return std.Io.Clock.Timestamp.now(io, .awake);
}

fn elapsedNs(start: std.Io.Clock.Timestamp, end: std.Io.Clock.Timestamp) u64 {
    const nanoseconds = start.durationTo(end).raw.nanoseconds;
    if (nanoseconds <= 0) return 0;
    return std.math.cast(u64, nanoseconds) orelse std.math.maxInt(u64);
}

fn writeJson(init: std.process.Init, value: anytype) !void {
    var stdout_buffer: [16 * 1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    try std.json.Stringify.value(value, .{ .whitespace = .indent_2 }, stdout);
    try stdout.writeByte('\n');
    try stdout.flush();
}

test "S12 measurement shapes remain explicit" {
    try std.testing.expectEqual(@as(usize, 64), planner_request_cohort);
    try std.testing.expectEqual(@as(usize, 8), planner_queries_per_wave);
    try std.testing.expectEqual(@as(usize, 6), movement_npcs);
    try std.testing.expectEqual(@as(usize, 2_048), movement_ticks);
    try std.testing.expectEqual(@as(u64, 4_166_000), p99_ceiling_ns);
    var samples = [_]u64{ 5, 1, 3, 2, 4 };
    const distribution = summarize(&samples);
    try std.testing.expectEqual(@as(u64, 3), distribution.p50_ns);
    try std.testing.expectEqual(@as(u64, 5), distribution.p99_ns);
}
