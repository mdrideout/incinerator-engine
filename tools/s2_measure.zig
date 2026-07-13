//! Reproducible SDL-free measurement for the S2 vehicle slice.

const std = @import("std");
const builtin = @import("builtin");
const simulation = @import("sandbox_simulation");

const fixed_delta_seconds: f32 = 1.0 / 120.0;

const Config = struct {
    warmup: usize = 120,
    samples: usize = 512,
    trials: usize = 3,
};

const Distribution = struct {
    samples: usize,
    mean_ns: f64,
    p50_ns: u64,
    p95_ns: u64,
    p99_ns: u64,
    max_ns: u64,
};

const TrialResult = struct {
    trial: usize,
    init_ns: u64,
    spawn_tick_ns: u64,
    enter_tick_ns: u64,
    drive_submit: Distribution,
    steady_tick: Distribution,
    presentation: Distribution,
    final_vehicle_position: [3]f32,
    vehicle_displacement: f32,
    active_crates: usize,
    active_characters: usize,
    active_vehicles: usize,
    active_entities: usize,
    physics_bodies: u32,
    exit_tick_ns: u64,
    despawn_tick_ns: u64,
    post_despawn_crates: usize,
    post_despawn_characters: usize,
    post_despawn_vehicles: usize,
    post_despawn_entities: usize,
    post_despawn_bodies: u32,
    post_despawn_active_bodies: u32,
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
    workload: []const u8,
    results: []const TrialResult,
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
            @intCast(20_000 + trial_index),
            trial_index + 1,
            config,
        );
    }

    const resolution = std.Io.Clock.resolution(.awake, init.io) catch std.Io.Duration.zero;
    const report = Report{
        .schema_version = 1,
        .benchmark = "s2_vehicle_slice",
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
        .workload = "one_occupied_four_wheel_vehicle_one_virtual_character_one_dynamic_crate_and_ground",
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
    const submit_samples = try allocator.alloc(u64, config.samples);
    defer allocator.free(submit_samples);
    const tick_samples = try allocator.alloc(u64, config.samples);
    defer allocator.free(tick_samples);
    const presentation_samples = try allocator.alloc(u64, config.samples);
    defer allocator.free(presentation_samples);

    const init_start = now(io);
    var world = try simulation.Simulation.init(allocator, .{
        .namespace = namespace,
        .fixed_delta_seconds = fixed_delta_seconds,
    });
    var world_live = true;
    errdefer if (world_live) world.deinit();
    const init_ns = elapsedNs(init_start, now(io));

    try world.submit(.{ .spawn = .{
        .request_id = 1,
        .pose = .{ .position = .{ 6, 8, 0 } },
    } });
    try world.submitCharacter(.{ .spawn = .{
        .request_id = 2,
        .position = .{ 0, 0, 2.5 },
    } });
    try world.submitVehicle(.{ .spawn = .{
        .request_id = 3,
        .chassis = .{ .pose = .{ .position = .{ 0, 2, 0 } } },
    } });
    const spawn_start = now(io);
    try world.tick();
    const spawn_tick_ns = elapsedNs(spawn_start, now(io));
    const crate_id = switch (world.pollOutcome() orelse return error.MissingCrateSpawn) {
        .spawned => |spawned| spawned.id,
        else => return error.UnexpectedCrateOutcome,
    };
    const character_id = switch (world.pollCharacterOutcome() orelse
        return error.MissingCharacterSpawn) {
        .spawned => |spawned| spawned.id,
        else => return error.UnexpectedCharacterOutcome,
    };
    const vehicle_id = switch (world.pollVehicleOutcome() orelse
        return error.MissingVehicleSpawn) {
        .spawned => |spawned| spawned.id,
        else => return error.UnexpectedVehicleOutcome,
    };
    drainEvents(&world);

    // Let the chassis and crate reach the ground before timing occupied driving.
    for (0..240) |_| try world.tick();
    try world.submitVehicle(.{ .enter = .{
        .vehicle_id = vehicle_id,
        .driver_id = character_id,
    } });
    const enter_start = now(io);
    try world.tick();
    const enter_tick_ns = elapsedNs(enter_start, now(io));
    switch (world.pollVehicleOutcome() orelse return error.MissingEnterOutcome) {
        .entered => {},
        else => return error.UnexpectedVehicleOutcome,
    }
    drainEvents(&world);
    if ((try world.characterPresentation(0.5)).len != 0) {
        return error.OccupiedCharacterPresentationMismatch;
    }
    const vehicle_position_before_drive =
        (try world.vehicle(vehicle_id)).state.chassis.pose.position;

    for (0..config.warmup) |index| {
        const steering = try submitDrive(&world, vehicle_id, character_id, index);
        try world.tick();
        try requireDriveApplied(&world, vehicle_id, character_id, steering);
    }

    for (0..config.samples) |sample_index| {
        const submit_start = now(io);
        const steering = try submitDrive(
            &world,
            vehicle_id,
            character_id,
            config.warmup + sample_index,
        );
        submit_samples[sample_index] = elapsedNs(submit_start, now(io));

        const tick_start = now(io);
        try world.tick();
        tick_samples[sample_index] = elapsedNs(tick_start, now(io));

        const presentation_start = now(io);
        const crates = try world.presentation(0.5);
        const characters = try world.characterPresentation(0.5);
        const vehicles = try world.vehiclePresentation(0.5);
        presentation_samples[sample_index] = elapsedNs(presentation_start, now(io));
        if (crates.len != 1 or characters.len != 0 or vehicles.len != 1) {
            return error.PresentationCountMismatch;
        }
        try requireDriveApplied(&world, vehicle_id, character_id, steering);
    }

    const final_vehicle = try world.vehicle(vehicle_id);
    const vehicle_displacement = distance(
        vehicle_position_before_drive,
        final_vehicle.state.chassis.pose.position,
    );
    if (vehicle_displacement <= 0.1) return error.VehicleDidNotMove;
    const active_crates = world.crateCount();
    const active_characters = world.characterCount();
    const active_vehicles = world.vehicleCount();
    const active_entities = world.entityCount();
    const physics_bodies = world.bodyCount();
    if (active_crates != 1 or active_characters != 1 or active_vehicles != 1 or
        active_entities != 3 or physics_bodies != 3)
    {
        return error.LifecycleCountMismatch;
    }

    try world.submitVehicle(.{ .exit = .{
        .vehicle_id = vehicle_id,
        .driver_id = character_id,
    } });
    const exit_start = now(io);
    try world.tick();
    const exit_tick_ns = elapsedNs(exit_start, now(io));
    switch (world.pollVehicleOutcome() orelse return error.MissingExitOutcome) {
        .exited => {},
        else => return error.UnexpectedVehicleOutcome,
    }
    drainEvents(&world);
    if ((try world.characterPresentation(0.5)).len != 1) {
        return error.ExitedCharacterPresentationMismatch;
    }

    try world.submit(.{ .despawn = .{ .id = crate_id } });
    try world.submitCharacter(.{ .despawn = .{ .id = character_id } });
    try world.submitVehicle(.{ .despawn = .{ .id = vehicle_id } });
    const despawn_start = now(io);
    try world.tick();
    const despawn_tick_ns = elapsedNs(despawn_start, now(io));
    const post_despawn_crates = world.crateCount();
    const post_despawn_characters = world.characterCount();
    const post_despawn_vehicles = world.vehicleCount();
    const post_despawn_entities = world.entityCount();
    const post_despawn_bodies = world.bodyCount();
    const post_despawn_active_bodies = world.activeBodyCount();
    if (post_despawn_crates != 0 or post_despawn_characters != 0 or
        post_despawn_vehicles != 0 or post_despawn_entities != 0 or
        post_despawn_bodies != 1 or post_despawn_active_bodies != 0)
    {
        return error.DespawnCountMismatch;
    }

    const teardown_start = now(io);
    world.deinit();
    world_live = false;
    const teardown_ns = elapsedNs(teardown_start, now(io));

    return .{
        .trial = trial,
        .init_ns = init_ns,
        .spawn_tick_ns = spawn_tick_ns,
        .enter_tick_ns = enter_tick_ns,
        .drive_submit = summarize(submit_samples),
        .steady_tick = summarize(tick_samples),
        .presentation = summarize(presentation_samples),
        .final_vehicle_position = final_vehicle.state.chassis.pose.position,
        .vehicle_displacement = vehicle_displacement,
        .active_crates = active_crates,
        .active_characters = active_characters,
        .active_vehicles = active_vehicles,
        .active_entities = active_entities,
        .physics_bodies = physics_bodies,
        .exit_tick_ns = exit_tick_ns,
        .despawn_tick_ns = despawn_tick_ns,
        .post_despawn_crates = post_despawn_crates,
        .post_despawn_characters = post_despawn_characters,
        .post_despawn_vehicles = post_despawn_vehicles,
        .post_despawn_entities = post_despawn_entities,
        .post_despawn_bodies = post_despawn_bodies,
        .post_despawn_active_bodies = post_despawn_active_bodies,
        .teardown_ns = teardown_ns,
    };
}

fn submitDrive(
    world: *simulation.Simulation,
    vehicle_id: simulation.PersistentId,
    character_id: simulation.PersistentId,
    tick_index: usize,
) !f32 {
    const steering: f32 = if ((tick_index / 120) % 2 == 0) 0.2 else -0.2;
    try world.submitVehicle(.{ .drive = .{
        .vehicle_id = vehicle_id,
        .driver_id = character_id,
        .input = .{ .throttle = 0.65, .steering = steering },
    } });
    return steering;
}

fn requireDriveApplied(
    world: *simulation.Simulation,
    vehicle_id: simulation.PersistentId,
    character_id: simulation.PersistentId,
    steering: f32,
) !void {
    const outcome = world.pollVehicleOutcome() orelse return error.MissingDriveOutcome;
    switch (outcome) {
        .drive_applied => |applied| {
            if (!std.meta.eql(applied.vehicle_id, vehicle_id) or
                !std.meta.eql(applied.driver_id, character_id) or
                applied.input.throttle != 0.65 or
                applied.input.steering != steering or
                applied.input.brake != 0 or
                applied.input.hand_brake != 0)
            {
                return error.DriveOutcomeMismatch;
            }
        },
        else => return error.UnexpectedVehicleOutcome,
    }
    if (world.pollVehicleOutcome() != null) return error.ExtraVehicleOutcome;
    while (world.pollVehicleEvent() != null) {}
}

fn drainEvents(world: *simulation.Simulation) void {
    while (world.pollCharacterEvent() != null) {}
    while (world.pollVehicleEvent() != null) {}
}

fn distance(first: [3]f32, second: [3]f32) f32 {
    var squared: f32 = 0;
    for (first, second) |a, b| {
        const delta = b - a;
        squared += delta * delta;
    }
    return @sqrt(squared);
}

fn parseArgs(init: std.process.Init) !?Config {
    var config = Config{};
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next() orelse return error.MissingExecutableName;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help")) {
            std.debug.print(
                "usage: s2_measure [--warmup=N] [--samples=N] [--trials=N]\n",
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
    const ticks = std.math.add(usize, config.samples, config.warmup) catch
        return error.MeasurementWorkloadTooLarge;
    const total = std.math.mul(usize, ticks, config.trials) catch
        return error.MeasurementWorkloadTooLarge;
    if (total > 10_000_000) return error.MeasurementWorkloadTooLarge;
}

fn summarize(samples: []u64) Distribution {
    std.debug.assert(samples.len > 0);
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

fn durationNs(duration: std.Io.Duration) u64 {
    if (duration.nanoseconds <= 0) return 0;
    return std.math.cast(u64, duration.nanoseconds) orelse std.math.maxInt(u64);
}

test "measurement distributions use nearest-rank percentiles" {
    var samples = [_]u64{ 5, 1, 4, 2, 3 };
    const distribution = summarize(&samples);
    try std.testing.expectEqual(@as(u64, 3), distribution.p50_ns);
    try std.testing.expectEqual(@as(u64, 5), distribution.p95_ns);
    try std.testing.expectEqual(@as(u64, 5), distribution.p99_ns);
}
