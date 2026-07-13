//! Reproducible SDL-free measurement for the S3-A district streaming slice.

const std = @import("std");
const builtin = @import("builtin");
const simulation = @import("sandbox_simulation");

const fixed_delta_seconds: f32 = 1.0 / 120.0;
const test_coord = simulation.ChunkCoord{ .x = 0, .z = -4 };
const expected_static_boxes: u8 = 3;
const expected_decoded_bytes: u32 = 120;
const worker_progress_limit: usize = 1_000_000;

const Config = struct {
    warmup: usize = 120,
    samples: usize = 512,
    trials: usize = 3,
    cycles: usize = 8,
};

const Distribution = struct {
    samples: usize,
    mean_ns: f64,
    p50_ns: u64,
    p95_ns: u64,
    p99_ns: u64,
    max_ns: u64,
};

const TickDistribution = struct {
    samples: usize,
    mean_ticks: f64,
    p50_ticks: u64,
    p95_ticks: u64,
    p99_ticks: u64,
    max_ticks: u64,
};

const TrialResult = struct {
    trial: usize,
    init_ns: u64,
    cancellation_request_tick_ns: u64,
    cancellation_wall_ns: u64,
    request_to_cancellation_ticks: u64,
    cancellation_completion_ticks: u64,
    cancelled_districts: usize,
    cancelled_district_bodies: usize,
    cancelled_entities: usize,
    cancelled_physics_bodies: u32,
    cancelled_active_bodies: u32,
    request_to_activation_wall: Distribution,
    request_to_activation_ticks: TickDistribution,
    activation_tick: Distribution,
    unload_tick: Distribution,
    steady_tick: Distribution,
    district_extraction: Distribution,
    active_districts: usize,
    active_district_bodies: usize,
    active_static_boxes: u8,
    active_decoded_bytes: u32,
    active_entities: usize,
    active_physics_bodies: u32,
    active_awake_bodies: u32,
    cleanup_cycles_requested: usize,
    cleanup_cycles_completed: usize,
    clean_cleanup_cycles: usize,
    post_cleanup_districts: usize,
    post_cleanup_district_bodies: usize,
    post_cleanup_entities: usize,
    post_cleanup_physics_bodies: u32,
    post_cleanup_active_bodies: u32,
    teardown_ns: u64,
};

const Report = struct {
    schema_version: u32,
    benchmark: []const u8,
    zig_version: []const u8,
    optimize: []const u8,
    target_arch: []const u8,
    target_os: []const u8,
    target_abi: []const u8,
    cpu_count: usize,
    clock: []const u8,
    clock_resolution_ns: u64,
    fixed_delta_seconds: f32,
    warmup: usize,
    samples: usize,
    trials: usize,
    cycles: usize,
    workload: []const u8,
    results: []const TrialResult,
};

const ActivationMeasurement = struct {
    ticket: simulation.LoadTicket,
    wall_ns: u64,
    ticks: u64,
    activation_tick_ns: u64,
};

const CancellationMeasurement = struct {
    request_tick_ns: u64,
    wall_ns: u64,
    request_to_completion_ticks: u64,
    completion_ticks: u64,
};

pub fn main(init: std.process.Init) !void {
    const config = try parseArgs(init) orelse return;
    try validateConfig(config);
    const results = try init.gpa.alloc(TrialResult, config.trials);
    defer init.gpa.free(results);
    for (results, 0..) |*result, trial_index| {
        result.* = try measureTrial(
            init.io,
            init.gpa,
            @intCast(30_000 + trial_index),
            trial_index + 1,
            config,
        );
    }

    const resolution = std.Io.Clock.resolution(.awake, init.io) catch std.Io.Duration.zero;
    const report = Report{
        .schema_version = 1,
        .benchmark = "s3a_district_streaming",
        .zig_version = builtin.zig_version_string,
        .optimize = @tagName(builtin.mode),
        .target_arch = @tagName(builtin.target.cpu.arch),
        .target_os = @tagName(builtin.target.os.tag),
        .target_abi = @tagName(builtin.target.abi),
        .cpu_count = try std.Thread.getCpuCount(),
        .clock = "awake",
        .clock_resolution_ns = durationNs(resolution),
        .fixed_delta_seconds = fixed_delta_seconds,
        .warmup = config.warmup,
        .samples = config.samples,
        .trials = config.trials,
        .cycles = config.cycles,
        .workload = "one_bounded_worker_one_procedural_district_three_static_boxes_and_ground",
        .results = results,
    };

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    try std.json.Stringify.value(report, .{ .whitespace = .indent_2 }, stdout);
    try stdout.writeByte('\n');
    try stdout.flush();
}

fn measureTrial(
    io: std.Io,
    allocator: std.mem.Allocator,
    namespace: u64,
    trial: usize,
    config: Config,
) !TrialResult {
    const activation_wall_samples = try allocator.alloc(u64, config.cycles);
    defer allocator.free(activation_wall_samples);
    const activation_tick_count_samples = try allocator.alloc(u64, config.cycles);
    defer allocator.free(activation_tick_count_samples);
    const activation_tick_samples = try allocator.alloc(u64, config.cycles);
    defer allocator.free(activation_tick_samples);
    const unload_samples = try allocator.alloc(u64, config.cycles);
    defer allocator.free(unload_samples);
    const tick_samples = try allocator.alloc(u64, config.samples);
    defer allocator.free(tick_samples);
    const extraction_samples = try allocator.alloc(u64, config.samples);
    defer allocator.free(extraction_samples);

    const init_start = now(io);
    var world = try simulation.Simulation.init(allocator, .{
        .namespace = namespace,
        .fixed_delta_seconds = fixed_delta_seconds,
    });
    var world_live = true;
    errdefer if (world_live) world.deinit();
    const init_ns = elapsedNs(init_start, now(io));

    const cancellation = try measureCancellation(io, &world);
    const cancelled_districts = world.districtCount();
    const cancelled_district_bodies = world.districtBodyCount();
    const cancelled_entities = world.entityCount();
    const cancelled_physics_bodies = world.bodyCount();
    const cancelled_active_bodies = world.activeBodyCount();
    if (cancelled_districts != 0 or cancelled_district_bodies != 0 or
        cancelled_entities != 0 or cancelled_physics_bodies != 1 or
        cancelled_active_bodies != 0 or world.districtState() != .absent)
    {
        return error.CancellationCleanupMismatch;
    }

    var active_districts: usize = 0;
    var active_district_bodies: usize = 0;
    var active_static_boxes: u8 = 0;
    var active_decoded_bytes: u32 = 0;
    var active_entities: usize = 0;
    var active_physics_bodies: u32 = 0;
    var active_awake_bodies: u32 = 0;
    var cleanup_cycles_completed: usize = 0;
    var clean_cleanup_cycles: usize = 0;

    for (0..config.cycles) |cycle_index| {
        const activation = try activateDistrict(
            io,
            &world,
            @intCast(100 + cycle_index * 2),
        );
        activation_wall_samples[cycle_index] = activation.wall_ns;
        activation_tick_count_samples[cycle_index] = activation.ticks;
        activation_tick_samples[cycle_index] = activation.activation_tick_ns;

        const draws = try world.districtPresentation();
        if (draws.len != 1) return error.DistrictExtractionCountMismatch;
        const draw = draws[0];
        if (!simulation.LoadTicket.eql(draw.ticket, activation.ticket)) {
            return error.ActiveDistrictTicketMismatch;
        }
        if (draw.build.static_box_count != expected_static_boxes or
            draw.build.decoded_bytes != expected_decoded_bytes or
            draw.build.boxes().len != expected_static_boxes)
        {
            return error.ActiveDistrictBudgetMismatch;
        }

        if (cycle_index == 0) {
            active_districts = world.districtCount();
            active_district_bodies = world.districtBodyCount();
            active_static_boxes = draw.build.static_box_count;
            active_decoded_bytes = draw.build.decoded_bytes;
            active_entities = world.entityCount();
            active_physics_bodies = world.bodyCount();
            active_awake_bodies = world.activeBodyCount();
            if (active_districts != 1 or active_district_bodies != 3 or
                active_entities != 1 or active_physics_bodies != 4 or
                active_awake_bodies != 0)
            {
                return error.ActiveLifecycleCountMismatch;
            }

            for (0..config.warmup) |_| {
                try world.tick();
                const warmup_draws = try world.districtPresentation();
                if (warmup_draws.len != 1) return error.DistrictExtractionCountMismatch;
                drainDistrictSignals(&world);
            }
            for (0..config.samples) |sample_index| {
                const tick_start = now(io);
                try world.tick();
                tick_samples[sample_index] = elapsedNs(tick_start, now(io));

                const extraction_start = now(io);
                const sample_draws = try world.districtPresentation();
                extraction_samples[sample_index] = elapsedNs(extraction_start, now(io));
                if (sample_draws.len != 1 or
                    sample_draws[0].build.static_box_count != expected_static_boxes or
                    sample_draws[0].build.decoded_bytes != expected_decoded_bytes)
                {
                    return error.DistrictExtractionCountMismatch;
                }
                drainDistrictSignals(&world);
            }
        }

        try world.submitDistrict(.{ .unload = .{
            .request_id = @intCast(101 + cycle_index * 2),
            .ticket = activation.ticket,
        } });
        const unload_start = now(io);
        try world.tick();
        unload_samples[cycle_index] = elapsedNs(unload_start, now(io));
        try requireUnloaded(&world, activation.ticket);
        cleanup_cycles_completed += 1;
        if (world.districtCount() == 0 and world.districtBodyCount() == 0 and
            world.entityCount() == 0 and world.bodyCount() == 1 and
            world.activeBodyCount() == 0 and world.districtState() == .absent)
        {
            clean_cleanup_cycles += 1;
        }
    }

    const post_cleanup_districts = world.districtCount();
    const post_cleanup_district_bodies = world.districtBodyCount();
    const post_cleanup_entities = world.entityCount();
    const post_cleanup_physics_bodies = world.bodyCount();
    const post_cleanup_active_bodies = world.activeBodyCount();
    if (cleanup_cycles_completed != config.cycles or clean_cleanup_cycles != config.cycles or
        post_cleanup_districts != 0 or post_cleanup_district_bodies != 0 or
        post_cleanup_entities != 0 or post_cleanup_physics_bodies != 1 or
        post_cleanup_active_bodies != 0)
    {
        return error.RepeatedCleanupMismatch;
    }

    const teardown_start = now(io);
    world.deinit();
    world_live = false;
    const teardown_ns = elapsedNs(teardown_start, now(io));

    return .{
        .trial = trial,
        .init_ns = init_ns,
        .cancellation_request_tick_ns = cancellation.request_tick_ns,
        .cancellation_wall_ns = cancellation.wall_ns,
        .request_to_cancellation_ticks = cancellation.request_to_completion_ticks,
        .cancellation_completion_ticks = cancellation.completion_ticks,
        .cancelled_districts = cancelled_districts,
        .cancelled_district_bodies = cancelled_district_bodies,
        .cancelled_entities = cancelled_entities,
        .cancelled_physics_bodies = cancelled_physics_bodies,
        .cancelled_active_bodies = cancelled_active_bodies,
        .request_to_activation_wall = summarize(activation_wall_samples),
        .request_to_activation_ticks = summarizeTicks(activation_tick_count_samples),
        .activation_tick = summarize(activation_tick_samples),
        .unload_tick = summarize(unload_samples),
        .steady_tick = summarize(tick_samples),
        .district_extraction = summarize(extraction_samples),
        .active_districts = active_districts,
        .active_district_bodies = active_district_bodies,
        .active_static_boxes = active_static_boxes,
        .active_decoded_bytes = active_decoded_bytes,
        .active_entities = active_entities,
        .active_physics_bodies = active_physics_bodies,
        .active_awake_bodies = active_awake_bodies,
        .cleanup_cycles_requested = config.cycles,
        .cleanup_cycles_completed = cleanup_cycles_completed,
        .clean_cleanup_cycles = clean_cleanup_cycles,
        .post_cleanup_districts = post_cleanup_districts,
        .post_cleanup_district_bodies = post_cleanup_district_bodies,
        .post_cleanup_entities = post_cleanup_entities,
        .post_cleanup_physics_bodies = post_cleanup_physics_bodies,
        .post_cleanup_active_bodies = post_cleanup_active_bodies,
        .teardown_ns = teardown_ns,
    };
}

fn measureCancellation(io: std.Io, world: *simulation.Simulation) !CancellationMeasurement {
    try world.submitDistrict(.{ .request_load = .{
        .request_id = 1,
        .coord = test_coord,
        .assets = .{},
    } });
    try world.tick();
    const ticket = switch (world.pollDistrictOutcome() orelse
        return error.MissingDistrictRequestOutcome) {
        .load_requested => |requested| requested.ticket,
        else => return error.UnexpectedDistrictOutcome,
    };
    if (world.pollDistrictOutcome() != null) return error.ExtraDistrictOutcome;
    drainDistrictEvents(world);
    const request_completed_tick = world.tickIndex();

    try world.submitDistrict(.{ .cancel_load = .{
        .request_id = 2,
        .ticket = ticket,
    } });
    const cancellation_start = now(io);
    const cancel_tick_start = now(io);
    try world.tick();
    const request_tick_ns = elapsedNs(cancel_tick_start, now(io));
    const cancel_completed_tick = world.tickIndex();
    var cancellation_requested = false;
    var cancelled = false;
    while (world.pollDistrictOutcome()) |outcome| switch (outcome) {
        .cancellation_requested => |requested| {
            if (!simulation.LoadTicket.eql(requested.ticket, ticket)) {
                return error.CancellationTicketMismatch;
            }
            cancellation_requested = true;
        },
        .cancelled => |completed| {
            if (!simulation.LoadTicket.eql(completed.ticket, ticket)) {
                return error.CancellationTicketMismatch;
            }
            cancelled = true;
        },
        else => return error.UnexpectedDistrictOutcome,
    };
    if (!cancellation_requested) return error.MissingCancellationRequestOutcome;
    drainDistrictEvents(world);

    var progress_ticks: usize = 0;
    while (!cancelled) : (progress_ticks += 1) {
        if (progress_ticks == worker_progress_limit) return error.DistrictWorkerDidNotComplete;
        std.Thread.yield() catch {};
        try world.tick();
        while (world.pollDistrictOutcome()) |outcome| switch (outcome) {
            .cancelled => |completed| {
                if (!simulation.LoadTicket.eql(completed.ticket, ticket)) {
                    return error.CancellationTicketMismatch;
                }
                cancelled = true;
            },
            else => return error.UnexpectedDistrictOutcome,
        };
        drainDistrictEvents(world);
    }
    return .{
        .request_tick_ns = request_tick_ns,
        .wall_ns = elapsedNs(cancellation_start, now(io)),
        .request_to_completion_ticks = world.tickIndex() - request_completed_tick,
        .completion_ticks = world.tickIndex() - cancel_completed_tick,
    };
}

fn activateDistrict(
    io: std.Io,
    world: *simulation.Simulation,
    request_id: u64,
) !ActivationMeasurement {
    const activation_start = now(io);
    try world.submitDistrict(.{ .request_load = .{
        .request_id = request_id,
        .coord = test_coord,
        .assets = .{},
    } });
    try world.tick();
    const ticket = switch (world.pollDistrictOutcome() orelse
        return error.MissingDistrictRequestOutcome) {
        .load_requested => |requested| requested.ticket,
        else => return error.UnexpectedDistrictOutcome,
    };
    if (world.pollDistrictOutcome() != null) return error.ExtraDistrictOutcome;
    drainDistrictEvents(world);
    const request_completed_tick = world.tickIndex();

    var progress_ticks: usize = 0;
    while (progress_ticks < worker_progress_limit) : (progress_ticks += 1) {
        std.Thread.yield() catch {};
        const tick_start = now(io);
        try world.tick();
        const tick_ns = elapsedNs(tick_start, now(io));
        var activated = false;
        while (world.pollDistrictOutcome()) |outcome| switch (outcome) {
            .activated => |completed| {
                if (!simulation.LoadTicket.eql(completed.ticket, ticket) or
                    completed.static_box_count != expected_static_boxes)
                {
                    return error.ActivationOutcomeMismatch;
                }
                activated = true;
            },
            else => return error.UnexpectedDistrictOutcome,
        };
        drainDistrictEvents(world);
        if (activated) return .{
            .ticket = ticket,
            .wall_ns = elapsedNs(activation_start, now(io)),
            .ticks = world.tickIndex() - request_completed_tick,
            .activation_tick_ns = tick_ns,
        };
    }
    return error.DistrictWorkerDidNotComplete;
}

fn requireUnloaded(world: *simulation.Simulation, ticket: simulation.LoadTicket) !void {
    var unloaded = false;
    while (world.pollDistrictOutcome()) |outcome| switch (outcome) {
        .unloaded => |completed| {
            if (!simulation.LoadTicket.eql(completed.ticket, ticket)) {
                return error.UnloadTicketMismatch;
            }
            unloaded = true;
        },
        else => return error.UnexpectedDistrictOutcome,
    };
    if (!unloaded) return error.MissingUnloadOutcome;
    drainDistrictEvents(world);
}

fn drainDistrictSignals(world: *simulation.Simulation) void {
    while (world.pollDistrictOutcome() != null) {}
    drainDistrictEvents(world);
}

fn drainDistrictEvents(world: *simulation.Simulation) void {
    while (world.pollDistrictEvent() != null) {}
}

fn parseArgs(init: std.process.Init) !?Config {
    var config = Config{};
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next() orelse return error.MissingExecutableName;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help")) {
            std.debug.print(
                "usage: s3_measure [--warmup=N] [--samples=N] [--trials=N] [--cycles=N]\n",
                .{},
            );
            return null;
        }
        if (std.mem.startsWith(u8, arg, "--warmup=")) {
            config.warmup = try parseUsize(arg["--warmup=".len..]);
        } else if (std.mem.startsWith(u8, arg, "--samples=")) {
            config.samples = try parseUsize(arg["--samples=".len..]);
        } else if (std.mem.startsWith(u8, arg, "--trials=")) {
            config.trials = try parseUsize(arg["--trials=".len..]);
        } else if (std.mem.startsWith(u8, arg, "--cycles=")) {
            config.cycles = try parseUsize(arg["--cycles=".len..]);
        } else {
            return error.UnknownOption;
        }
    }
    return config;
}

fn parseUsize(value: []const u8) !usize {
    if (value.len == 0) return error.MissingOptionValue;
    return std.fmt.parseInt(usize, value, 10) catch error.InvalidInteger;
}

fn validateConfig(config: Config) !void {
    if (config.samples == 0) return error.SamplesMustBePositive;
    if (config.trials == 0) return error.TrialsMustBePositive;
    if (config.cycles == 0) return error.CyclesMustBePositive;
    const timed_ticks = std.math.add(usize, config.samples, config.warmup) catch
        return error.MeasurementWorkloadTooLarge;
    const per_trial = std.math.add(usize, timed_ticks, config.cycles) catch
        return error.MeasurementWorkloadTooLarge;
    const total = std.math.mul(usize, per_trial, config.trials) catch
        return error.MeasurementWorkloadTooLarge;
    if (total > 10_000_000) return error.MeasurementWorkloadTooLarge;
}

fn summarize(samples: []u64) Distribution {
    std.debug.assert(samples.len > 0);
    std.mem.sort(u64, samples, {}, lessThanU64);
    const total = sum(samples);
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

fn summarizeTicks(samples: []u64) TickDistribution {
    std.debug.assert(samples.len > 0);
    std.mem.sort(u64, samples, {}, lessThanU64);
    const total = sum(samples);
    return .{
        .samples = samples.len,
        .mean_ticks = @as(f64, @floatFromInt(total)) /
            @as(f64, @floatFromInt(samples.len)),
        .p50_ticks = samples[percentileIndex(samples.len, 50)],
        .p95_ticks = samples[percentileIndex(samples.len, 95)],
        .p99_ticks = samples[percentileIndex(samples.len, 99)],
        .max_ticks = samples[samples.len - 1],
    };
}

fn sum(samples: []const u64) u128 {
    var total: u128 = 0;
    for (samples) |sample| total += sample;
    return total;
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

fn durationNs(duration: std.Io.Duration) u64 {
    if (duration.nanoseconds <= 0) return 0;
    return std.math.cast(u64, duration.nanoseconds) orelse std.math.maxInt(u64);
}

test "measurement distributions use nearest-rank percentiles" {
    var timing_samples = [_]u64{ 5, 1, 4, 2, 3 };
    const timing = summarize(&timing_samples);
    try std.testing.expectEqual(@as(u64, 3), timing.p50_ns);
    try std.testing.expectEqual(@as(u64, 5), timing.p95_ns);
    try std.testing.expectEqual(@as(u64, 5), timing.p99_ns);

    var tick_samples = [_]u64{ 5, 1, 4, 2, 3 };
    const ticks = summarizeTicks(&tick_samples);
    try std.testing.expectEqual(@as(u64, 3), ticks.p50_ticks);
    try std.testing.expectEqual(@as(u64, 5), ticks.p95_ticks);
    try std.testing.expectEqual(@as(u64, 5), ticks.p99_ticks);
}
