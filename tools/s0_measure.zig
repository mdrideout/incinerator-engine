//! Reproducible, SDL-free measurements for the S0 crate lifecycle slice.
//!
//! The build graph supplies the concrete `crate_simulation` module. This tool
//! intentionally writes only one versioned JSON document to stdout so callers
//! can archive or compare results without scraping human-readable logs.

const std = @import("std");
const builtin = @import("builtin");
const simulation = @import("crate_simulation");

const schema_version: u32 = 1;
const fixed_delta_seconds: f32 = 1.0 / 120.0;
const max_crates: usize = 1024;
const max_weighted_body_ticks: u128 = 100_000_000;
const default_counts = [_]usize{ 0, 1, 128, 1024 };

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
    crate_count: usize,
    trial: usize,
    init_ns: u64,
    enqueue_spawn_ns: u64,
    spawn_tick_ns: u64,
    drain_spawn_outcomes_ns: u64,
    steady_tick: Distribution,
    presentation: Distribution,
    post_spawn_crates: usize,
    post_spawn_entities: usize,
    post_spawn_bodies: u32,
    post_spawn_active_bodies: u32,
    enqueue_despawn_ns: u64,
    despawn_tick_ns: u64,
    drain_despawn_outcomes_ns: u64,
    post_despawn_crates: usize,
    post_despawn_entities: usize,
    post_despawn_bodies: u32,
    post_despawn_active_bodies: u32,
    teardown_ns: u64,
};

const ReportConfig = struct {
    counts: []const usize,
    warmup: usize,
    samples: usize,
    trials: usize,
    fixed_delta_seconds: f32,
    create_ground: bool,
    layout: []const u8,
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
    config: ReportConfig,
    results: []const TrialResult,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    var counts: std.ArrayListUnmanaged(usize) = .empty;
    defer counts.deinit(allocator);
    try counts.appendSlice(allocator, &default_counts);

    const config = try parseArgs(init, allocator, &counts);
    if (config == null) return;
    try validateWorkload(counts.items, config.?);

    const result_count = try std.math.mul(usize, counts.items.len, config.?.trials);
    var results: std.ArrayListUnmanaged(TrialResult) = .empty;
    defer results.deinit(allocator);
    try results.ensureTotalCapacity(allocator, result_count);

    var result_index: usize = 0;
    for (counts.items) |crate_count| {
        for (0..config.?.trials) |trial_index| {
            const namespace = std.math.cast(u64, result_index + 1) orelse
                return error.NamespaceExhausted;
            results.appendAssumeCapacity(try measureTrial(
                init.io,
                allocator,
                namespace,
                crate_count,
                trial_index + 1,
                config.?,
            ));
            result_index += 1;
        }
    }

    const resolution = std.Io.Clock.resolution(.awake, init.io) catch std.Io.Duration.zero;
    const report = Report{
        .schema_version = schema_version,
        .benchmark = "s0_crate_lifecycle",
        .zig_version = builtin.zig_version_string,
        .optimize = @tagName(builtin.mode),
        .target_arch = @tagName(builtin.target.cpu.arch),
        .target_os = @tagName(builtin.target.os.tag),
        .target_abi = @tagName(builtin.target.abi),
        .cpu_count = try std.Thread.getCpuCount(),
        .clock = "awake",
        .clock_resolution_ns = durationNs(resolution),
        .config = .{
            .counts = counts.items,
            .warmup = config.?.warmup,
            .samples = config.?.samples,
            .trials = config.?.trials,
            .fixed_delta_seconds = fixed_delta_seconds,
            .create_ground = true,
            .layout = "sparse_32x32_grid_y1000_spacing2.5",
        },
        .results = results.items,
    };

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    try std.json.Stringify.value(report, .{ .whitespace = .indent_2 }, stdout);
    try stdout.writeByte('\n');
    try stdout.flush();
}

fn parseArgs(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    counts: *std.ArrayListUnmanaged(usize),
) !?Config {
    var config: Config = .{};
    var saw_counts = false;
    var saw_warmup = false;
    var saw_samples = false;
    var saw_trials = false;

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.next() orelse return error.MissingExecutableName;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help")) {
            printUsage();
            return null;
        }
        if (std.mem.startsWith(u8, arg, "--counts=")) {
            if (saw_counts) return error.DuplicateOption;
            saw_counts = true;
            counts.clearRetainingCapacity();
            try parseCounts(allocator, counts, arg["--counts=".len..]);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--warmup=")) {
            if (saw_warmup) return error.DuplicateOption;
            saw_warmup = true;
            config.warmup = try parseUsize(arg["--warmup=".len..]);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--samples=")) {
            if (saw_samples) return error.DuplicateOption;
            saw_samples = true;
            config.samples = try parseUsize(arg["--samples=".len..]);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--trials=")) {
            if (saw_trials) return error.DuplicateOption;
            saw_trials = true;
            config.trials = try parseUsize(arg["--trials=".len..]);
            continue;
        }

        std.debug.print("unknown S0 measurement option: {s}\n", .{arg});
        printUsage();
        return error.UnknownOption;
    }
    return config;
}

fn parseCounts(
    allocator: std.mem.Allocator,
    counts: *std.ArrayListUnmanaged(usize),
    text: []const u8,
) !void {
    if (text.len == 0) return error.EmptyCounts;
    var parts = std.mem.splitScalar(u8, text, ',');
    while (parts.next()) |part| {
        if (part.len == 0) return error.InvalidCount;
        const count = try parseUsize(part);
        if (count > max_crates) return error.CountExceedsS0Limit;
        for (counts.items) |existing| {
            if (existing == count) return error.DuplicateCount;
        }
        try counts.append(allocator, count);
    }
    if (counts.items.len == 0) return error.EmptyCounts;
}

fn parseUsize(text: []const u8) !usize {
    if (text.len == 0) return error.MissingOptionValue;
    return std.fmt.parseInt(usize, text, 10) catch error.InvalidInteger;
}

fn validateWorkload(counts: []const usize, config: Config) !void {
    if (counts.len == 0) return error.EmptyCounts;
    if (config.samples == 0) return error.SamplesMustBePositive;
    if (config.trials == 0) return error.TrialsMustBePositive;

    const ticks_per_trial = try std.math.add(usize, config.warmup, config.samples);
    var weighted_body_ticks: u128 = 0;
    for (counts) |count| {
        if (count > max_crates) return error.CountExceedsS0Limit;
        const bodies: u128 = @max(count, 1);
        const per_trial = std.math.mul(
            u128,
            bodies,
            @as(u128, ticks_per_trial),
        ) catch return error.MeasurementWorkloadTooLarge;
        const all_trials = std.math.mul(
            u128,
            per_trial,
            @as(u128, config.trials),
        ) catch return error.MeasurementWorkloadTooLarge;
        weighted_body_ticks = std.math.add(
            u128,
            weighted_body_ticks,
            all_trials,
        ) catch return error.MeasurementWorkloadTooLarge;
        if (weighted_body_ticks > max_weighted_body_ticks) {
            return error.MeasurementWorkloadTooLarge;
        }
    }
}

fn measureTrial(
    io: std.Io,
    allocator: std.mem.Allocator,
    namespace: u64,
    crate_count: usize,
    trial: usize,
    config: Config,
) !TrialResult {
    const ids = try allocator.alloc(simulation.PersistentId, crate_count);
    defer allocator.free(ids);
    const seen = try allocator.alloc(bool, crate_count);
    defer allocator.free(seen);
    @memset(seen, false);
    const tick_samples = try allocator.alloc(u64, config.samples);
    defer allocator.free(tick_samples);
    const presentation_samples = try allocator.alloc(u64, config.samples);
    defer allocator.free(presentation_samples);

    const init_start = now(io);
    var world = try simulation.Simulation.init(allocator, .{
        .namespace = namespace,
        .fixed_delta_seconds = fixed_delta_seconds,
        .max_crates = @max(crate_count, 1),
        .create_ground = true,
    });
    var world_live = true;
    errdefer if (world_live) world.deinit();
    const init_ns = elapsedNs(init_start, now(io));

    const enqueue_spawn_start = now(io);
    for (0..crate_count) |index| {
        try world.submit(.{ .spawn = .{
            .request_id = @intCast(index),
            .pose = .{ .position = sparsePosition(index) },
        } });
    }
    const enqueue_spawn_ns = elapsedNs(enqueue_spawn_start, now(io));

    const spawn_tick_start = now(io);
    try world.tick();
    const spawn_tick_ns = elapsedNs(spawn_tick_start, now(io));

    const drain_spawn_start = now(io);
    var spawned: usize = 0;
    while (world.pollOutcome()) |outcome| {
        switch (outcome) {
            .spawned => |value| {
                const request_index = std.math.cast(usize, value.request_id) orelse
                    return error.InvalidSpawnRequestId;
                if (request_index >= crate_count) return error.InvalidSpawnRequestId;
                if (seen[request_index]) return error.DuplicateSpawnOutcome;
                seen[request_index] = true;
                ids[request_index] = value.id;
                spawned += 1;
            },
            else => return error.UnexpectedSpawnOutcome,
        }
    }
    const drain_spawn_outcomes_ns = elapsedNs(drain_spawn_start, now(io));
    if (spawned != crate_count) return error.MissingSpawnOutcome;
    for (seen) |was_seen| {
        if (!was_seen) return error.MissingSpawnOutcome;
    }

    try expectCounts(&world, crate_count, crate_count, try expectedBodies(crate_count));

    for (0..config.warmup) |_| try world.tick();
    const primed_draws = try world.presentation(0.5);
    if (primed_draws.len != crate_count) return error.PresentationCountMismatch;

    for (0..config.samples) |sample_index| {
        const tick_start = now(io);
        try world.tick();
        tick_samples[sample_index] = elapsedNs(tick_start, now(io));

        const presentation_start = now(io);
        const draws = try world.presentation(0.5);
        presentation_samples[sample_index] = elapsedNs(presentation_start, now(io));
        if (draws.len != crate_count) return error.PresentationCountMismatch;
    }

    const steady_tick = summarize(tick_samples);
    const presentation = summarize(presentation_samples);
    const post_spawn_crates = world.crateCount();
    const post_spawn_entities = world.entityCount();
    const post_spawn_bodies = world.bodyCount();
    const post_spawn_active_bodies = world.activeBodyCount();
    if (post_spawn_active_bodies != crate_count) return error.ActiveBodyCountMismatch;

    const enqueue_despawn_start = now(io);
    for (ids) |id| try world.submit(.{ .despawn = .{ .id = id } });
    const enqueue_despawn_ns = elapsedNs(enqueue_despawn_start, now(io));

    const despawn_tick_start = now(io);
    try world.tick();
    const despawn_tick_ns = elapsedNs(despawn_tick_start, now(io));

    const drain_despawn_start = now(io);
    var despawned: usize = 0;
    while (world.pollOutcome()) |outcome| {
        switch (outcome) {
            .despawned => |id| {
                if (despawned >= ids.len or !std.meta.eql(id, ids[despawned])) {
                    return error.UnexpectedDespawnId;
                }
                despawned += 1;
            },
            else => return error.UnexpectedDespawnOutcome,
        }
    }
    const drain_despawn_outcomes_ns = elapsedNs(drain_despawn_start, now(io));
    if (despawned != crate_count) return error.MissingDespawnOutcome;

    try expectCounts(&world, 0, 0, 1);
    const post_despawn_crates = world.crateCount();
    const post_despawn_entities = world.entityCount();
    const post_despawn_bodies = world.bodyCount();
    const post_despawn_active_bodies = world.activeBodyCount();
    if (post_despawn_active_bodies != 0) return error.ActiveBodyCountMismatch;

    const teardown_start = now(io);
    world.deinit();
    world_live = false;
    const teardown_ns = elapsedNs(teardown_start, now(io));

    return .{
        .crate_count = crate_count,
        .trial = trial,
        .init_ns = init_ns,
        .enqueue_spawn_ns = enqueue_spawn_ns,
        .spawn_tick_ns = spawn_tick_ns,
        .drain_spawn_outcomes_ns = drain_spawn_outcomes_ns,
        .steady_tick = steady_tick,
        .presentation = presentation,
        .post_spawn_crates = post_spawn_crates,
        .post_spawn_entities = post_spawn_entities,
        .post_spawn_bodies = post_spawn_bodies,
        .post_spawn_active_bodies = post_spawn_active_bodies,
        .enqueue_despawn_ns = enqueue_despawn_ns,
        .despawn_tick_ns = despawn_tick_ns,
        .drain_despawn_outcomes_ns = drain_despawn_outcomes_ns,
        .post_despawn_crates = post_despawn_crates,
        .post_despawn_entities = post_despawn_entities,
        .post_despawn_bodies = post_despawn_bodies,
        .post_despawn_active_bodies = post_despawn_active_bodies,
        .teardown_ns = teardown_ns,
    };
}

fn expectCounts(
    world: *simulation.Simulation,
    crates: usize,
    entities: usize,
    bodies: u32,
) !void {
    if (world.crateCount() != crates) return error.CrateCountMismatch;
    if (world.entityCount() != entities) return error.EntityCountMismatch;
    if (world.bodyCount() != bodies) return error.BodyCountMismatch;
}

fn expectedBodies(crate_count: usize) !u32 {
    return std.math.cast(u32, crate_count + 1) orelse error.BodyCountOverflow;
}

fn sparsePosition(index: usize) [3]f32 {
    const column: i32 = @intCast(index % 32);
    const row: i32 = @intCast(index / 32);
    return .{
        (@as(f32, @floatFromInt(column)) - 15.5) * 2.5,
        1000.0 + @as(f32, @floatFromInt(index % 7)) * 0.125,
        (@as(f32, @floatFromInt(row)) - 15.5) * 2.5,
    };
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
    std.debug.assert(len > 0 and percentile > 0 and percentile <= 100);
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

fn printUsage() void {
    std.debug.print(
        \\usage: s0_measure [--counts=0,1,128,1024] [--warmup=N] [--samples=N] [--trials=N]
        \\       s0_measure --help
        \\
        \\Results are emitted as one versioned JSON document on stdout.
        \\
    , .{});
}
