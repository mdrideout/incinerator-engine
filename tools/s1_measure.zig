//! Reproducible SDL-free measurement for the S1 character slice.

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
    action_submit: Distribution,
    steady_tick: Distribution,
    presentation: Distribution,
    final_character_position: [3]f32,
    active_crates: usize,
    active_characters: usize,
    active_entities: usize,
    physics_bodies: u32,
    despawn_tick_ns: u64,
    post_despawn_crates: usize,
    post_despawn_characters: usize,
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
    const config = try parseArgs(init);
    if (config == null) return;
    try validateConfig(config.?);
    const results = try init.gpa.alloc(TrialResult, config.?.trials);
    defer init.gpa.free(results);
    for (results, 0..) |*result, trial_index| {
        result.* = try measureTrial(
            init.io,
            init.gpa,
            @intCast(10_000 + trial_index),
            trial_index + 1,
            config.?,
        );
    }

    const resolution = std.Io.Clock.resolution(.awake, init.io) catch std.Io.Duration.zero;
    const report = Report{
        .schema_version = 1,
        .benchmark = "s1_character_slice",
        .zig_version = builtin.zig_version_string,
        .optimize = @tagName(builtin.mode),
        .target_arch = @tagName(builtin.target.cpu.arch),
        .target_os = @tagName(builtin.target.os.tag),
        .target_abi = @tagName(builtin.target.abi),
        .cpu_count = try std.Thread.getCpuCount(),
        .clock = "awake",
        .clock_resolution_ns = durationNs(resolution),
        .fixed_delta_seconds = fixed_delta_seconds,
        .warmup = config.?.warmup,
        .samples = config.?.samples,
        .trials = config.?.trials,
        .workload = "one_virtual_character_one_dynamic_crate_ground_and_static_block",
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
        .block = .{
            .position = .{ 0, 1, -5 },
            .half_extents = .{ 2, 1, 0.5 },
        },
    });
    var world_live = true;
    errdefer if (world_live) world.deinit();
    const init_ns = elapsedNs(init_start, now(io));

    try world.submit(.{ .spawn = .{
        .request_id = 1,
        .pose = .{ .position = .{ 3, 12, 0 } },
        .velocity = .{ .angular = .{ 0.2, 0.4, 0.1 } },
    } });
    try world.submitCharacter(.{ .spawn = .{
        .request_id = 2,
        .position = .{ 0, 0, 4 },
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
    while (world.pollCharacterOutcome() != null) {}
    while (world.pollCharacterEvent() != null) {}

    for (0..config.warmup) |_| {
        try submitAction(&world, character_id);
        try world.tick();
        while (world.pollCharacterOutcome() != null) {}
        while (world.pollCharacterEvent() != null) {}
    }

    for (0..config.samples) |sample_index| {
        const submit_start = now(io);
        try submitAction(&world, character_id);
        submit_samples[sample_index] = elapsedNs(submit_start, now(io));

        const tick_start = now(io);
        try world.tick();
        tick_samples[sample_index] = elapsedNs(tick_start, now(io));

        const presentation_start = now(io);
        const crates = try world.presentation(0.5);
        const characters = try world.characterPresentation(0.5);
        presentation_samples[sample_index] = elapsedNs(presentation_start, now(io));
        if (crates.len != 1 or characters.len != 1) {
            return error.PresentationCountMismatch;
        }
        while (world.pollCharacterOutcome() != null) {}
        while (world.pollCharacterEvent() != null) {}
    }

    const final_character = try world.character(character_id);
    const active_crates = world.crateCount();
    const active_characters = world.characterCount();
    const active_entities = world.entityCount();
    const physics_bodies = world.bodyCount();
    if (active_crates != 1 or active_characters != 1 or
        active_entities != 2 or physics_bodies != 3)
    {
        return error.LifecycleCountMismatch;
    }

    try world.submit(.{ .despawn = .{ .id = crate_id } });
    try world.submitCharacter(.{ .despawn = .{ .id = character_id } });
    const despawn_start = now(io);
    try world.tick();
    const despawn_tick_ns = elapsedNs(despawn_start, now(io));
    const post_despawn_crates = world.crateCount();
    const post_despawn_characters = world.characterCount();
    const post_despawn_entities = world.entityCount();
    const post_despawn_bodies = world.bodyCount();
    const post_despawn_active_bodies = world.activeBodyCount();
    if (post_despawn_crates != 0 or post_despawn_characters != 0 or
        post_despawn_entities != 0 or post_despawn_bodies != 2 or
        post_despawn_active_bodies != 0)
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
        .action_submit = summarize(submit_samples),
        .steady_tick = summarize(tick_samples),
        .presentation = summarize(presentation_samples),
        .final_character_position = final_character.position,
        .active_crates = active_crates,
        .active_characters = active_characters,
        .active_entities = active_entities,
        .physics_bodies = physics_bodies,
        .despawn_tick_ns = despawn_tick_ns,
        .post_despawn_crates = post_despawn_crates,
        .post_despawn_characters = post_despawn_characters,
        .post_despawn_entities = post_despawn_entities,
        .post_despawn_bodies = post_despawn_bodies,
        .post_despawn_active_bodies = post_despawn_active_bodies,
        .teardown_ns = teardown_ns,
    };
}

fn submitAction(
    world: *simulation.Simulation,
    character_id: simulation.PersistentId,
) !void {
    try world.submitCharacter(.{ .actions = .{
        .id = character_id,
        .move = .{ 0, 1 },
        .facing_yaw = 0,
    } });
}

fn parseArgs(init: std.process.Init) !?Config {
    var config = Config{};
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next() orelse return error.MissingExecutableName;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help")) {
            std.debug.print(
                "usage: s1_measure [--warmup=N] [--samples=N] [--trials=N]\n",
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

fn parseUsize(text: []const u8) !usize {
    if (text.len == 0) return error.MissingOptionValue;
    return std.fmt.parseInt(usize, text, 10) catch error.InvalidInteger;
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
