//! Fresh-process S11 encounter feature characterization.
//!
//! The aggregate mode runs paired baseline and fully engaged 64-NPC / 16-
//! participant trials. The workload includes frame validation, deterministic
//! perception, target selection, behavior advancement, and complete output
//! draining. The feature accepts no allocator and owns fixed-capacity storage,
//! so workload heap allocations are zero by construction.

const std = @import("std");
const builtin = @import("builtin");
const encounter = @import("npc_encounter_feature");
const contract = @import("npc_encounter_contract");
const vitals = @import("vitals_contract");

const schema_version: u32 = 1;
const measured_ticks: usize = 16_384;
const warmup_ticks: usize = 64;
const trial_count: usize = 3;
const p99_ceiling_ns: u64 = 4_166_000;
const rss_delta_ceiling_bytes: usize = 8 * 1024 * 1024;

const Mode = enum { aggregate, baseline_child, scale_child };
const TrialKind = enum { baseline, scale };

const Distribution = struct {
    samples: usize,
    mean_ns: f64,
    p50_ns: u64,
    p95_ns: u64,
    p99_ns: u64,
    max_ns: u64,
};

const TrialReport = struct {
    schema_version: u32,
    kind: TrialKind,
    measured_ticks: usize,
    warmup_ticks: usize,
    tick: Distribution,
    max_rss_bytes: usize,
    feature_fixed_bytes: usize,
    workload_heap_allocations: usize,
    participants: usize,
    npcs: usize,
    final_records: u16,
    final_pursuing: u16,
    los_queries: u64,
    los_deferrals: u64,
    directives_drained: u64,
    cues_drained: u64,
    damage_proposals_drained: u64,
};

const AggregateReport = struct {
    schema_version: u32,
    benchmark: []const u8,
    zig_version: []const u8,
    optimize: []const u8,
    target_arch: []const u8,
    target_os: []const u8,
    methodology: []const u8,
    baseline_trials: [trial_count]TrialReport,
    scale_trials: [trial_count]TrialReport,
    paired_rss_delta_bytes: [trial_count]usize,
    worst_scale_p99_ns: u64,
    worst_paired_rss_delta_bytes: usize,
    ceilings: struct {
        scale_p99_ns: u64 = p99_ceiling_ns,
        paired_rss_delta_bytes: usize = rss_delta_ceiling_bytes,
        workload_heap_allocations: usize = 0,
    } = .{},
};

const Visibility = struct {
    queries: u64 = 0,

    pub fn lineClear(self: *Visibility, _: [3]f32, _: [3]f32) !bool {
        self.queries +|= 1;
        return true;
    }
};

const Feature = encounter.Feature(Visibility);

pub fn main(init: std.process.Init) !void {
    if (builtin.mode != .ReleaseFast) return error.S11MeasurementRequiresReleaseFast;
    switch (try parseMode(init)) {
        .aggregate => try runAggregate(init),
        .baseline_child => try writeJson(init, try runTrial(init, false)),
        .scale_child => try writeJson(init, try runTrial(init, true)),
    }
}

fn runAggregate(init: std.process.Init) !void {
    const executable = try std.process.executablePathAlloc(init.io, init.gpa);
    defer init.gpa.free(executable);
    var baseline_trials: [trial_count]TrialReport = undefined;
    var scale_trials: [trial_count]TrialReport = undefined;
    var rss_deltas: [trial_count]usize = undefined;
    var worst_p99: u64 = 0;
    var worst_rss_delta: usize = 0;

    for (0..trial_count) |index| {
        baseline_trials[index] = try runTrialProcess(init, executable, "baseline-child", .baseline);
        scale_trials[index] = try runTrialProcess(init, executable, "scale-child", .scale);
        rss_deltas[index] = scale_trials[index].max_rss_bytes -|
            baseline_trials[index].max_rss_bytes;
        worst_p99 = @max(worst_p99, scale_trials[index].tick.p99_ns);
        worst_rss_delta = @max(worst_rss_delta, rss_deltas[index]);
    }

    if (worst_p99 > p99_ceiling_ns) return error.S11EncounterP99CeilingExceeded;
    if (worst_rss_delta > rss_delta_ceiling_bytes) return error.S11EncounterRssCeilingExceeded;

    try writeJson(init, AggregateReport{
        .schema_version = schema_version,
        .benchmark = "s11-npc-encounter-fully-engaged",
        .zig_version = builtin.zig_version_string,
        .optimize = @tagName(builtin.mode),
        .target_arch = @tagName(builtin.target.cpu.arch),
        .target_os = @tagName(builtin.target.os.tag),
        .methodology = "three fresh baseline/scale process pairs; 64 unmeasured warmup ticks; nearest-rank percentiles over 16384 feature steps; scale is 64 pursuing NPCs, 16 eligible participants, clear LOS, and complete output drain",
        .baseline_trials = baseline_trials,
        .scale_trials = scale_trials,
        .paired_rss_delta_bytes = rss_deltas,
        .worst_scale_p99_ns = worst_p99,
        .worst_paired_rss_delta_bytes = worst_rss_delta,
    });
}

fn runTrialProcess(
    init: std.process.Init,
    executable: []const u8,
    child_mode: []const u8,
    expected_kind: TrialKind,
) !TrialReport {
    const result = try std.process.run(init.gpa, init.io, .{
        .argv = &.{ executable, child_mode },
        .stdout_limit = .limited(256 * 1024),
        .stderr_limit = .limited(256 * 1024),
    });
    defer init.gpa.free(result.stdout);
    defer init.gpa.free(result.stderr);
    try requireChildSuccess(result.term, result.stderr);
    var parsed = try std.json.parseFromSlice(TrialReport, init.gpa, result.stdout, .{});
    defer parsed.deinit();
    const report = parsed.value;
    if (report.schema_version != schema_version or report.kind != expected_kind or
        report.measured_ticks != measured_ticks or report.warmup_ticks != warmup_ticks or
        report.tick.samples != measured_ticks or report.workload_heap_allocations != 0 or
        report.feature_fixed_bytes != @sizeOf(Feature))
    {
        return error.InvalidS11MeasurementReport;
    }
    if (expected_kind == .scale and
        (report.participants != contract.max_combatants or
            report.npcs != contract.max_records or
            report.final_records != contract.max_records or
            report.final_pursuing != contract.max_records or
            report.los_queries == 0 or report.los_deferrals == 0))
    {
        return error.InvalidS11ScaleEvidence;
    }
    return report;
}

fn runTrial(init: std.process.Init, scale: bool) !TrialReport {
    var samples: [measured_ticks]u64 = undefined;
    var players: [contract.max_combatants]contract.CombatantObservation = undefined;
    for (&players, 0..) |*player, index| player.* = .{
        .target = target(.player, @intCast(index + 1)),
        .position = .{ @as(f32, @floatFromInt(index % 4)) * 0.25, 0, -5 },
        .facing_yaw = 0,
        .alive = true,
    };
    var npcs: [contract.max_records]contract.NpcObservation = undefined;
    for (&npcs, 0..) |*npc, index| npc.* = .{
        .target = target(.npc, @intCast(index + 100)),
        .position = .{ @as(f32, @floatFromInt(index % 8)) * 0.1, 0, 0 },
        .facing_yaw = 0,
        .alive = true,
        .hostile_to_players = true,
    };

    var visibility = Visibility{};
    var feature = try Feature.init(&visibility, .{
        .ambient_perception_interval_ticks = 1,
        .engaged_perception_interval_ticks = 1,
        .los_queries_per_tick = 16,
        .los_queries_per_npc = 4,
    });
    defer feature.deinit();
    const observed_npcs = if (scale) npcs[0..] else npcs[0..0];
    var directives_drained: u64 = 0;
    var cues_drained: u64 = 0;
    var damage_drained: u64 = 0;

    for (1..warmup_ticks + 1) |tick| {
        try feature.step(.{
            .tick = tick,
            .players = &players,
            .npcs = observed_npcs,
            .damage_facts = &.{},
        });
        drain(&feature, &directives_drained, &cues_drained, &damage_drained);
    }
    if (scale and feature.diagnostics().pursuing != contract.max_records) {
        return error.S11EncounterWarmupIncomplete;
    }

    for (&samples, 0..) |*sample, index| {
        const start = now(init.io);
        try feature.step(.{
            .tick = warmup_ticks + index + 1,
            .players = &players,
            .npcs = observed_npcs,
            .damage_facts = &.{},
        });
        drain(&feature, &directives_drained, &cues_drained, &damage_drained);
        sample.* = elapsedNs(start, now(init.io));
    }
    const diagnostics = feature.diagnostics();
    return .{
        .schema_version = schema_version,
        .kind = if (scale) .scale else .baseline,
        .measured_ticks = measured_ticks,
        .warmup_ticks = warmup_ticks,
        .tick = summarize(&samples),
        .max_rss_bytes = maxRssBytes(),
        .feature_fixed_bytes = @sizeOf(Feature),
        .workload_heap_allocations = 0,
        .participants = players.len,
        .npcs = observed_npcs.len,
        .final_records = diagnostics.records,
        .final_pursuing = diagnostics.pursuing,
        .los_queries = diagnostics.los_queries,
        .los_deferrals = diagnostics.los_deferred,
        .directives_drained = directives_drained,
        .cues_drained = cues_drained,
        .damage_proposals_drained = damage_drained,
    };
}

fn drain(
    feature: *Feature,
    directives: *u64,
    cues: *u64,
    damage: *u64,
) void {
    while (feature.pollDirective() != null) directives.* +|= 1;
    while (feature.pollCue() != null) cues.* +|= 1;
    while (feature.pollDamage() != null) damage.* +|= 1;
}

fn target(kind: vitals.TargetKind, local: u64) vitals.Target {
    return .{
        .kind = kind,
        .id = .{ .namespace = 91, .local = local },
        .incarnation = .{ .value = 1 },
    };
}

fn parseMode(init: std.process.Init) !Mode {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next() orelse return error.MissingExecutableName;
    const value = args.next() orelse return .aggregate;
    if (args.next() != null) return error.TooManyS11MeasurementArguments;
    if (std.mem.eql(u8, value, "baseline-child")) return .baseline_child;
    if (std.mem.eql(u8, value, "scale-child")) return .scale_child;
    return error.InvalidS11MeasurementMode;
}

fn requireChildSuccess(term: std.process.Child.Term, stderr: []const u8) !void {
    switch (term) {
        .exited => |code| if (code == 0) return,
        else => {},
    }
    if (stderr.len != 0) std.debug.print("{s}", .{stderr});
    return error.S11MeasurementChildFailed;
}

fn writeJson(init: std.process.Init, value: anytype) !void {
    var stdout_buffer: [32 * 1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    try std.json.Stringify.value(value, .{ .whitespace = .indent_2 }, stdout);
    try stdout.writeByte('\n');
    try stdout.flush();
}

fn summarize(samples: []u64) Distribution {
    std.debug.assert(samples.len != 0);
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

fn maxRssBytes() usize {
    const value = std.posix.getrusage(std.posix.rusage.SELF).maxrss;
    if (value <= 0) return 0;
    return @intCast(value);
}

test "S11 measurement preserves the declared workload and ceiling" {
    try std.testing.expectEqual(@as(usize, 16_384), measured_ticks);
    try std.testing.expectEqual(@as(usize, 64), warmup_ticks);
    try std.testing.expectEqual(@as(usize, 3), trial_count);
    try std.testing.expectEqual(@as(u64, 4_166_000), p99_ceiling_ns);
    try std.testing.expectEqual(@as(usize, 64), contract.max_records);
    try std.testing.expectEqual(@as(usize, 16), contract.max_combatants);
    try std.testing.expect(percentileIndex(100, 99) == 98);
}
