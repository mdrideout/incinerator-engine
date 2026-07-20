//! Versioned SDL-free S8 population scale and persistence measurement.
//!
//! The public mode launches a replay proof plus three fresh baseline/scale
//! process pairs. Child modes are deliberately undocumented implementation
//! details so RSS is measured from genuinely independent processes.

const std = @import("std");
const builtin = @import("builtin");
const simulation = @import("sandbox_simulation");
const simulation_snapshot = @import("simulation_snapshot");
const district_feature_contract = @import("district_feature_contract");
const npc_contract = @import("npc_contract");
const sandbox_contracts = @import("sandbox_host_contracts");
const sandbox_diagnostics = @import("sandbox_diagnostics_contract");
const sandbox_replay = @import("sandbox_replay");
const sandbox_save = @import("sandbox_save");
const population = @import("population_contract");
const district_contract = @import("district_contract");
const jolt = @import("jolt_physics");
const content = @import("content");
const district_content_catalog = @import("district_content_catalog");

const schema_version: u32 = 1;
const fixed_delta_seconds: f32 = 1.0 / 120.0;
const measured_ticks: usize = 16_384;
const measured_cycles: usize = 32;
const ticks_per_cycle: usize = measured_ticks / measured_cycles;
const warmup_cycles: usize = 1;
const trial_count: usize = 3;
const replay_ticks: u64 = 4_096;
const replay_ceiling_bytes: usize = 2 * 1024 * 1024;

const npc_ceiling: u32 = 64;
const entity_ceiling: u32 = 68;
const controller_ceiling: u32 = 65;
const controller_capacity: u32 = 128;
const held_body_ceiling: u32 = 7;
const dropped_body_ceiling: u32 = 8;
const snapshot_ceiling_bytes: usize = 128 * 1024;
const envelope_ceiling_bytes: usize = 131_264;
const allocation_delta_ceiling_bytes: usize = 2 * 1024 * 1024;
const rss_delta_ceiling_bytes: usize = 32 * 1024 * 1024;
const p99_ceiling_ns: u64 = 4_166_000;
const worker_progress_limit: usize = 10_000;

const west = sandbox_contracts.navigation_west_coord;
const east = sandbox_contracts.navigation_east_coord;
const west_node = npc_contract.NodeRef{ .coord = west, .index = 0 };
const east_node = npc_contract.NodeRef{ .coord = east, .index = 2 };
const west_x: f32 = 6;
const east_x: f32 = 10;
const route_z: f32 = 3;
const district_assets = district_feature_contract.Assets{
    .scene = .{ .index = 17, .generation = 2 },
};

comptime {
    if (measured_ticks % measured_cycles != 0) {
        @compileError("S8 measured ticks must divide exactly into cycles");
    }
    if (npc_contract.max_npcs != npc_ceiling) {
        @compileError("S8 measurement and simulation NPC cohorts differ");
    }
    if (population.max_population_commands != npc_ceiling) {
        @compileError("S8 population producer must emit the exact cohort");
    }
    if (jolt.max_virtual_characters != controller_capacity) {
        @compileError("S8 measurement and Jolt controller cohorts differ");
    }
}

const Mode = enum {
    aggregate,
    proof_child,
    baseline_child,
    scale_child,
};

const Invocation = struct {
    mode: Mode,
    content_root: content.ContentRootPath,
};

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
    measured_cycles: usize,
    ticks_per_cycle: usize,
    warmup_cycles: usize,
    tick: Distribution,
    zig_allocator_peak_bytes: usize,
    zig_allocator_live_bytes: usize,
    max_rss_bytes: usize,
    peak_entities: u32,
    peak_native_bodies: u32,
    peak_native_controllers: u32,
    peak_npcs: u32,
    peak_npc_draws: u32,
    npc_command_capacity: u32,
    npc_outcome_capacity: u32,
    npc_event_capacity: u32,
    npc_command_high_water: u32,
    npc_outcome_high_water: u32,
    npc_event_high_water: u32,
    npc_event_drops: u64,
    npc_state_events: u64,
    npc_transfer_events: u64,
    npc_goal_events: u64,
    navigation_decoded_bytes: u32,
    navigation_cooked_wire_bytes: u32,
    snapshot_payload_bytes: usize,
    save_envelope_bytes: usize,
    held_body_count_proved: bool,
    capacity_rejection_proved: bool,
    final_entities: u32,
    final_native_bodies: u32,
    final_native_controllers: u32,
    final_npcs: u32,
    final_npc_draws: u32,
    final_npc_queue_occupancy: u32,
};

const TrialData = struct {
    tick: Distribution,
    zig_allocator_peak_bytes: usize,
    zig_allocator_live_bytes: usize,
    max_rss_bytes: usize,
    peak_entities: u32,
    peak_native_bodies: u32,
    peak_native_controllers: u32,
    peak_npcs: u32,
    peak_npc_draws: u32,
    npc_command_high_water: u32,
    npc_outcome_high_water: u32,
    npc_event_high_water: u32,
    npc_command_capacity: u32,
    npc_outcome_capacity: u32,
    npc_event_capacity: u32,
    npc_event_drops: u64,
    npc_transfer_events: u64,
    npc_goal_events: u64,
    navigation_decoded_bytes: u32,
    navigation_cooked_wire_bytes: u32,
    snapshot_payload_bytes: usize,
    save_envelope_bytes: usize,
    held_body_count_proved: bool,
    capacity_rejection_proved: bool,
    final_entities: u32,
    final_native_bodies: u32,
    final_native_controllers: u32,
    final_npcs: u32,
    final_npc_draws: u32,
    final_npc_queue_occupancy: u32,
};

const ProofReport = struct {
    schema_version: u32,
    kind: []const u8,
    completed_ticks: u64,
    replay_envelope_bytes: usize,
    bootstrap_commands: usize,
    recorded_commands: usize,
    district_ingress: usize,
    tick_digests: usize,
    replay_matched: bool,
};

const Ceilings = struct {
    npcs_and_draws: u32 = npc_ceiling,
    entities: u32 = entity_ceiling,
    controllers_used: u32 = controller_ceiling,
    controllers_global: u32 = controller_capacity,
    bodies_held: u32 = held_body_ceiling,
    bodies_dropped: u32 = dropped_body_ceiling,
    npc_commands: u32 = 128,
    npc_outcomes: u32 = 128,
    npc_events: u32 = 256,
    navigation_bytes: usize = 640,
    replay_envelope_bytes: usize = replay_ceiling_bytes,
    snapshot_bytes: usize = snapshot_ceiling_bytes,
    envelope_bytes: usize = envelope_ceiling_bytes,
    allocation_delta_bytes: usize = allocation_delta_ceiling_bytes,
    rss_delta_bytes: usize = rss_delta_ceiling_bytes,
    p99_ns: u64 = p99_ceiling_ns,
};

const AggregateReport = struct {
    schema_version: u32,
    benchmark: []const u8,
    zig_version: []const u8,
    optimize: []const u8,
    target_arch: []const u8,
    target_os: []const u8,
    content_cohort_fingerprint: []const u8,
    methodology: []const u8,
    measured_ticks_per_trial: usize,
    measured_cycles_per_trial: usize,
    warmup_cycles_per_trial: usize,
    fresh_trial_pairs: usize,
    proof: ProofReport,
    baseline_trials: [trial_count]TrialData,
    scale_trials: [trial_count]TrialData,
    paired_allocation_delta_bytes: [trial_count]usize,
    paired_rss_delta_bytes: [trial_count]usize,
    worst_scale_p99_ns: u64,
    worst_paired_allocation_delta_bytes: usize,
    worst_paired_rss_delta_bytes: usize,
    ceilings: Ceilings,
};

pub fn main(init: std.process.Init) !void {
    const invocation = try parseInvocation(init) orelse return;
    if (builtin.mode != .ReleaseFast) return error.S8MeasurementRequiresReleaseFast;
    switch (invocation.mode) {
        .aggregate => try runAggregate(init, invocation.content_root),
        .proof_child => try writeJson(init, try runProof(init, invocation.content_root)),
        .baseline_child => try writeJson(init, try runTrial(init, false, invocation.content_root)),
        .scale_child => try writeJson(init, try runTrial(init, true, invocation.content_root)),
    }
}

fn runAggregate(init: std.process.Init, content_root: content.ContentRootPath) !void {
    const admitted_cohort = try admitContentCohort(init, content_root);
    const content_fingerprint = try admitted_cohort.fingerprint();
    const content_fingerprint_hex = std.fmt.bytesToHex(content_fingerprint, .lower);
    const executable = try std.process.executablePathAlloc(init.io, init.gpa);
    defer init.gpa.free(executable);

    const root_bytes = content_root.bytes();
    const proof = try runProofProcess(init, executable, root_bytes);
    var baseline_trials: [trial_count]TrialData = undefined;
    var scale_trials: [trial_count]TrialData = undefined;
    var allocation_deltas: [trial_count]usize = undefined;
    var rss_deltas: [trial_count]usize = undefined;
    var worst_p99: u64 = 0;
    var worst_allocation_delta: usize = 0;
    var worst_rss_delta: usize = 0;

    for (0..trial_count) |index| {
        const baseline = try runTrialProcess(
            init,
            executable,
            "baseline-child",
            root_bytes,
            false,
        );
        const scale = try runTrialProcess(
            init,
            executable,
            "scale-child",
            root_bytes,
            true,
        );
        baseline_trials[index] = trialData(baseline);
        scale_trials[index] = trialData(scale);
        allocation_deltas[index] = positiveDelta(
            scale.zig_allocator_peak_bytes,
            baseline.zig_allocator_peak_bytes,
        );
        rss_deltas[index] = positiveDelta(scale.max_rss_bytes, baseline.max_rss_bytes);
        worst_p99 = @max(worst_p99, scale.tick.p99_ns);
        worst_allocation_delta = @max(worst_allocation_delta, allocation_deltas[index]);
        worst_rss_delta = @max(worst_rss_delta, rss_deltas[index]);
    }

    if (worst_p99 > p99_ceiling_ns) return error.S8TickP99CeilingExceeded;
    if (worst_allocation_delta > allocation_delta_ceiling_bytes) {
        return error.S8AllocationDeltaCeilingExceeded;
    }
    if (worst_rss_delta > rss_delta_ceiling_bytes) return error.S8RssDeltaCeilingExceeded;

    try writeJson(init, AggregateReport{
        .schema_version = schema_version,
        .benchmark = "s8-navigation-population-scale",
        .zig_version = builtin.zig_version_string,
        .optimize = @tagName(builtin.mode),
        .target_arch = @tagName(builtin.target.cpu.arch),
        .target_os = @tagName(builtin.target.os.tag),
        .content_cohort_fingerprint = &content_fingerprint_hex,
        .methodology = "three fresh baseline/scale process pairs; one unmeasured warmup lifecycle per child; nearest-rank percentiles over exactly 32x512 measured ticks",
        .measured_ticks_per_trial = measured_ticks,
        .measured_cycles_per_trial = measured_cycles,
        .warmup_cycles_per_trial = warmup_cycles,
        .fresh_trial_pairs = trial_count,
        .proof = proof,
        .baseline_trials = baseline_trials,
        .scale_trials = scale_trials,
        .paired_allocation_delta_bytes = allocation_deltas,
        .paired_rss_delta_bytes = rss_deltas,
        .worst_scale_p99_ns = worst_p99,
        .worst_paired_allocation_delta_bytes = worst_allocation_delta,
        .worst_paired_rss_delta_bytes = worst_rss_delta,
        .ceilings = .{},
    });
}

fn runTrialProcess(
    init: std.process.Init,
    executable: []const u8,
    child_mode: []const u8,
    content_root: []const u8,
    expected_scale: bool,
) !TrialReport {
    const result = try std.process.run(init.gpa, init.io, .{
        .argv = &.{ executable, child_mode, content_root },
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });
    defer init.gpa.free(result.stdout);
    defer init.gpa.free(result.stderr);
    try requireChildSuccess(result.term, result.stderr);
    var parsed = try std.json.parseFromSlice(TrialReport, init.gpa, result.stdout, .{});
    defer parsed.deinit();
    const report = parsed.value;
    const expected_kind: TrialKind = if (expected_scale) .scale else .baseline;
    if (report.schema_version != schema_version or
        report.measured_ticks != measured_ticks or
        report.measured_cycles != measured_cycles or
        report.ticks_per_cycle != ticks_per_cycle or
        report.warmup_cycles != warmup_cycles or
        report.tick.samples != measured_ticks or
        report.kind != expected_kind)
    {
        return error.InvalidS8TrialReport;
    }
    try validateTrialReport(report, expected_scale);
    return report;
}

fn validateTrialReport(report: TrialReport, scale: bool) !void {
    const expected_entities: u32 = if (scale) entity_ceiling else 4;
    const expected_controllers: u32 = if (scale) controller_ceiling else 1;
    const expected_npcs: u32 = if (scale) npc_ceiling else 0;
    if (report.zig_allocator_live_bytes != 0 or
        report.peak_entities != expected_entities or
        report.peak_native_bodies != dropped_body_ceiling or
        report.peak_native_controllers != expected_controllers or
        report.peak_npcs != expected_npcs or report.peak_npc_draws != expected_npcs or
        report.npc_command_capacity != 128 or report.npc_outcome_capacity != 128 or
        report.npc_event_capacity != 256 or report.npc_event_drops != 0 or
        report.npc_command_high_water > report.npc_command_capacity or
        report.npc_outcome_high_water > report.npc_outcome_capacity or
        report.npc_event_high_water > report.npc_event_capacity or
        report.navigation_decoded_bytes > 640 or
        report.navigation_cooked_wire_bytes > 640 or
        report.snapshot_payload_bytes > snapshot_ceiling_bytes or
        report.save_envelope_bytes > envelope_ceiling_bytes or
        !report.held_body_count_proved or
        report.capacity_rejection_proved != scale or
        (scale and (report.npc_transfer_events == 0 or report.npc_goal_events == 0)) or
        report.final_entities != 0 or report.final_native_bodies != 1 or
        report.final_native_controllers != 0 or report.final_npcs != 0 or
        report.final_npc_draws != 0 or report.final_npc_queue_occupancy != 0)
    {
        return error.InvalidS8TrialEvidence;
    }
}

fn runProofProcess(
    init: std.process.Init,
    executable: []const u8,
    content_root: []const u8,
) !ProofReport {
    const result = try std.process.run(init.gpa, init.io, .{
        .argv = &.{ executable, "proof-child", content_root },
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });
    defer init.gpa.free(result.stdout);
    defer init.gpa.free(result.stderr);
    try requireChildSuccess(result.term, result.stderr);
    var parsed = try std.json.parseFromSlice(ProofReport, init.gpa, result.stdout, .{});
    defer parsed.deinit();
    const report = parsed.value;
    if (report.schema_version != schema_version or
        !std.mem.eql(u8, report.kind, "replay-proof") or
        report.completed_ticks != replay_ticks or
        report.tick_digests != replay_ticks or
        report.replay_envelope_bytes > replay_ceiling_bytes or
        !report.replay_matched)
    {
        return error.InvalidS8ReplayProof;
    }
    return .{
        .schema_version = report.schema_version,
        .kind = "replay-proof",
        .completed_ticks = report.completed_ticks,
        .replay_envelope_bytes = report.replay_envelope_bytes,
        .bootstrap_commands = report.bootstrap_commands,
        .recorded_commands = report.recorded_commands,
        .district_ingress = report.district_ingress,
        .tick_digests = report.tick_digests,
        .replay_matched = report.replay_matched,
    };
}

fn requireChildSuccess(term: std.process.Child.Term, stderr: []const u8) !void {
    switch (term) {
        .exited => |code| if (code == 0) return,
        else => {},
    }
    if (stderr.len != 0) std.debug.print("{s}", .{stderr});
    return error.S8MeasurementChildFailed;
}

fn trialData(report: TrialReport) TrialData {
    return .{
        .tick = report.tick,
        .zig_allocator_peak_bytes = report.zig_allocator_peak_bytes,
        .zig_allocator_live_bytes = report.zig_allocator_live_bytes,
        .max_rss_bytes = report.max_rss_bytes,
        .peak_entities = report.peak_entities,
        .peak_native_bodies = report.peak_native_bodies,
        .peak_native_controllers = report.peak_native_controllers,
        .peak_npcs = report.peak_npcs,
        .peak_npc_draws = report.peak_npc_draws,
        .npc_command_high_water = report.npc_command_high_water,
        .npc_outcome_high_water = report.npc_outcome_high_water,
        .npc_event_high_water = report.npc_event_high_water,
        .npc_command_capacity = report.npc_command_capacity,
        .npc_outcome_capacity = report.npc_outcome_capacity,
        .npc_event_capacity = report.npc_event_capacity,
        .npc_event_drops = report.npc_event_drops,
        .npc_transfer_events = report.npc_transfer_events,
        .npc_goal_events = report.npc_goal_events,
        .navigation_decoded_bytes = report.navigation_decoded_bytes,
        .navigation_cooked_wire_bytes = report.navigation_cooked_wire_bytes,
        .snapshot_payload_bytes = report.snapshot_payload_bytes,
        .save_envelope_bytes = report.save_envelope_bytes,
        .held_body_count_proved = report.held_body_count_proved,
        .capacity_rejection_proved = report.capacity_rejection_proved,
        .final_entities = report.final_entities,
        .final_native_bodies = report.final_native_bodies,
        .final_native_controllers = report.final_native_controllers,
        .final_npcs = report.final_npcs,
        .final_npc_draws = report.final_npc_draws,
        .final_npc_queue_occupancy = report.final_npc_queue_occupancy,
    };
}

const TrackingAllocator = struct {
    child: std.mem.Allocator,
    live: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    peak: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    fn init(child: std.mem.Allocator) TrackingAllocator {
        return .{ .child = child };
    }

    fn allocator(self: *TrackingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn liveBytes(self: *const TrackingAllocator) usize {
        return self.live.load(.acquire);
    }

    fn peakBytes(self: *const TrackingAllocator) usize {
        return self.peak.load(.acquire);
    }

    fn add(self: *TrackingAllocator, amount: usize) void {
        const old = self.live.fetchAdd(amount, .acq_rel);
        const value = old +| amount;
        var observed = self.peak.load(.acquire);
        while (value > observed) {
            observed = self.peak.cmpxchgWeak(
                observed,
                value,
                .acq_rel,
                .acquire,
            ) orelse break;
        }
    }

    fn subtract(self: *TrackingAllocator, amount: usize) void {
        const old = self.live.fetchSub(amount, .acq_rel);
        std.debug.assert(old >= amount);
    }

    fn alloc(
        context: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const self: *TrackingAllocator = @ptrCast(@alignCast(context));
        const result = self.child.rawAlloc(len, alignment, return_address) orelse return null;
        self.add(len);
        return result;
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) bool {
        const self: *TrackingAllocator = @ptrCast(@alignCast(context));
        if (!self.child.rawResize(memory, alignment, new_len, return_address)) return false;
        if (new_len > memory.len) self.add(new_len - memory.len) else self.subtract(memory.len - new_len);
        return true;
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        const self: *TrackingAllocator = @ptrCast(@alignCast(context));
        const result = self.child.rawRemap(memory, alignment, new_len, return_address) orelse return null;
        if (new_len > memory.len) self.add(new_len - memory.len) else self.subtract(memory.len - new_len);
        return result;
    }

    fn free(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) void {
        const self: *TrackingAllocator = @ptrCast(@alignCast(context));
        self.child.rawFree(memory, alignment, return_address);
        self.subtract(memory.len);
    }
};

const Metrics = struct {
    peak_entities: u32 = 0,
    peak_bodies: u32 = 0,
    peak_native_controllers: u32 = 0,
    peak_npcs: u32 = 0,
    peak_npc_draws: u32 = 0,
    npc_command_capacity: u32 = 0,
    npc_outcome_capacity: u32 = 0,
    npc_event_capacity: u32 = 0,
    npc_command_high_water: u32 = 0,
    npc_outcome_high_water: u32 = 0,
    npc_event_high_water: u32 = 0,
    npc_event_drops: u64 = 0,
    npc_state_events: u64 = 0,
    npc_transfer_events: u64 = 0,
    npc_goal_events: u64 = 0,
    navigation_decoded_bytes: u32 = 0,
    navigation_cooked_wire_bytes: u32 = 0,
    snapshot_payload_bytes: usize = 0,
    save_envelope_bytes: usize = 0,
    capacity_rejection_proved: bool = false,

    fn observe(self: *Metrics, world: *simulation.Simulation) !void {
        const value = world.diagnostics();
        const feature_owned_controllers = std.math.add(
            u32,
            value.characters.active_count,
            value.npc.controller_count,
        ) catch return error.S8FeatureControllerCountOverflow;
        const controllers = value.character_controllers;
        const draws: u32 = @intCast((try world.npcPresentation(0)).len);
        if (controllers.native_capacity != controller_capacity or
            controllers.native_used > controllers.native_capacity or
            controllers.feature_owned != feature_owned_controllers or
            controllers.native_used != feature_owned_controllers or
            !controllers.authority_consistent)
        {
            return error.S8NativeControllerAuthorityMismatch;
        }
        self.peak_entities = @max(self.peak_entities, value.entity_count);
        self.peak_bodies = @max(self.peak_bodies, value.body_count);
        self.peak_native_controllers = @max(
            self.peak_native_controllers,
            controllers.native_used,
        );
        self.peak_npcs = @max(
            self.peak_npcs,
            value.npc.active_count + value.npc.waiting_count + value.npc.dormant_count,
        );
        self.peak_npc_draws = @max(self.peak_npc_draws, draws);
        self.npc_command_capacity = value.npc.commands.capacity orelse
            return error.UnboundedNpcCommandQueue;
        self.npc_outcome_capacity = value.npc.outcomes.capacity orelse
            return error.UnboundedNpcOutcomeQueue;
        self.npc_event_capacity = value.npc.events.capacity orelse
            return error.UnboundedNpcEventQueue;
        self.npc_command_high_water = @max(
            self.npc_command_high_water,
            value.npc.commands.high_water,
        );
        self.npc_outcome_high_water = @max(
            self.npc_outcome_high_water,
            value.npc.outcomes.high_water,
        );
        self.npc_event_high_water = @max(
            self.npc_event_high_water,
            value.npc.events.high_water,
        );
        self.npc_event_drops = value.npc.event_drops.total();
        if (value.entity_count > entity_ceiling or value.body_count > dropped_body_ceiling or
            controllers.native_used > controller_ceiling or draws > npc_ceiling or
            self.npc_command_capacity != 128 or self.npc_outcome_capacity != 128 or
            self.npc_event_capacity != 256 or self.npc_event_drops != 0)
        {
            return error.S8ResourceCeilingExceeded;
        }
    }
};

const Identities = struct {
    character: sandbox_contracts.PersistentId,
    carryable: sandbox_contracts.PersistentId,
};

const Harness = struct {
    io: std.Io,
    world: *simulation.Simulation,
    metrics: *Metrics,
    samples: ?[]u64 = null,
    sample_cursor: usize = 0,
    npc_ids: [npc_ceiling]sandbox_contracts.PersistentId = undefined,
    npc_count: usize = 0,

    fn tick(self: *Harness, measured: bool) !void {
        if (measured) {
            const samples = self.samples orelse return error.MissingMeasurementStorage;
            if (self.sample_cursor >= samples.len) return error.TooManyMeasuredTicks;
            const start = now(self.io);
            try self.world.tick();
            samples[self.sample_cursor] = elapsedNs(start, now(self.io));
            self.sample_cursor += 1;
        } else {
            try self.world.tick();
        }
        try self.metrics.observe(self.world);
    }

    fn drainAmbient(self: *Harness) !void {
        while (self.world.pollNpcEvent()) |event| try self.recordNpcEvent(event);
        while (self.world.pollCharacterEvent() != null) {}
        while (self.world.pollVehicleEvent() != null) {}
        while (self.world.pollDistrictEvent() != null) {}
        if (self.world.pollOutcome() != null or
            self.world.pollCharacterOutcome() != null or
            self.world.pollVehicleOutcome() != null or
            self.world.pollDistrictOutcome() != null or
            self.world.pollInteractionOutcome() != null or
            self.world.pollNpcOutcome() != null)
        {
            return error.UnexpectedS8Output;
        }
        try self.metrics.observe(self.world);
    }

    fn recordNpcEvent(self: *Harness, event: npc_contract.Event) !void {
        switch (event) {
            .state_changed => |value| {
                try self.requireNpcId(value.id);
                if (value.previous == value.current) return error.InvalidNpcStateTransition;
                self.metrics.npc_state_events += 1;
            },
            .owner_transferred => |value| {
                try self.requireNpcId(value.id);
                if (sandbox_contracts.ChunkCoord.eql(value.previous, value.current) or
                    (!sandbox_contracts.ChunkCoord.eql(value.previous, west) and
                        !sandbox_contracts.ChunkCoord.eql(value.previous, east)) or
                    (!sandbox_contracts.ChunkCoord.eql(value.current, west) and
                        !sandbox_contracts.ChunkCoord.eql(value.current, east)))
                {
                    return error.InvalidNpcOwnerTransfer;
                }
                self.metrics.npc_transfer_events += 1;
            },
            .goal_reached => |value| {
                try self.requireNpcId(value.id);
                if (!npc_contract.NodeRef.eql(value.node, west_node) and
                    !npc_contract.NodeRef.eql(value.node, east_node))
                {
                    return error.InvalidNpcGoalEvent;
                }
                self.metrics.npc_goal_events += 1;
            },
        }
    }

    fn requireNpcId(self: *const Harness, id: sandbox_contracts.PersistentId) !void {
        for (self.npc_ids[0..self.npc_count]) |known| {
            if (std.meta.eql(known, id)) return;
        }
        return error.UnknownNpcEventIdentity;
    }
};

fn runTrial(
    init: std.process.Init,
    scale: bool,
    content_root: content.ContentRootPath,
) !TrialReport {
    const samples = try init.gpa.alloc(u64, measured_ticks);
    defer init.gpa.free(samples);
    var tracker = TrackingAllocator.init(init.gpa);
    const allocator = tracker.allocator();
    const config = trialConfig(if (scale) 80_008 else 80_007);
    const content_cohort = try admitContentCohort(init, content_root);
    var metrics = Metrics{};
    setNavigationAccounting(&metrics);
    var payload: []u8 = undefined;
    var envelope: []u8 = undefined;

    {
        var world = try simulation.Simulation.init(allocator, config);
        defer world.deinit();
        var harness = Harness{
            .io = init.io,
            .world = &world,
            .metrics = &metrics,
            .samples = samples,
        };
        _ = try activateDistrict(&harness, 1, west);
        _ = try activateDistrict(&harness, 2, east);
        const identities = try spawnActors(&harness);
        if (scale) try spawnPopulation(&harness);
        try requireActiveScaleState(&harness, scale, false);

        var owner = west;
        try carryCycle(&harness, identities, &owner, east, 10, false, null);
        try requireActiveScaleState(&harness, scale, false);
        for (0..measured_cycles) |cycle| {
            const destination = if (sandbox_contracts.ChunkCoord.eql(owner, west)) east else west;
            const target_x = if (sandbox_contracts.ChunkCoord.eql(destination, east)) east_x else west_x;
            const cycle_start = harness.sample_cursor;
            try carryCycle(
                &harness,
                identities,
                &owner,
                destination,
                100 + cycle,
                true,
                target_x,
            );
            while (harness.sample_cursor - cycle_start < ticks_per_cycle) {
                try harness.tick(true);
                try harness.drainAmbient();
            }
            if (harness.sample_cursor - cycle_start != ticks_per_cycle) {
                return error.S8CycleTickCountMismatch;
            }
        }
        if (harness.sample_cursor != measured_ticks) return error.S8MeasuredTickCountMismatch;
        try requireActiveScaleState(&harness, scale, false);
        if (scale and (metrics.npc_transfer_events == 0 or metrics.npc_goal_events == 0)) {
            return error.NpcPatrolEventsMissing;
        }

        payload = try world.save(allocator);
        const canonical = try world.save(allocator);
        defer allocator.free(canonical);
        if (!std.mem.eql(u8, payload, canonical)) return error.NonCanonicalS8Snapshot;
        metrics.snapshot_payload_bytes = payload.len;
        if (payload.len > snapshot_ceiling_bytes) return error.S8SnapshotCeilingExceeded;

        const metadata = try saveMetadata(config, content_cohort);
        envelope = try sandbox_save.encode(allocator, metadata, payload);
        const canonical_envelope = try sandbox_save.encode(allocator, metadata, payload);
        defer allocator.free(canonical_envelope);
        if (!std.mem.eql(u8, envelope, canonical_envelope)) {
            return error.NonCanonicalS8Envelope;
        }
        _ = try sandbox_save.parseCompatible(envelope, metadata);
        metrics.save_envelope_bytes = envelope.len;
        if (envelope.len > envelope_ceiling_bytes) return error.S8EnvelopeCeilingExceeded;
    }

    var final_diagnostics: sandbox_diagnostics.Diagnostics = undefined;
    var final_draw_count: u32 = undefined;
    {
        var restored = try simulation.Simulation.fromSnapshotForWorld(
            allocator,
            payload,
            config,
            district_assets,
        );
        defer restored.deinit();
        var harness = Harness{
            .io = init.io,
            .world = &restored,
            .metrics = &metrics,
        };
        if (scale) {
            harness.npc_count = npc_ceiling;
            const draws = try restored.npcPresentation(0);
            if (draws.len != npc_ceiling) return error.RestoredNpcDrawCountMismatch;
            for (draws, 0..) |draw, index| harness.npc_ids[index] = draw.persistent_id;
        }
        try requireActiveScaleState(&harness, scale, true);
        const restored_payload = try restored.save(allocator);
        defer allocator.free(restored_payload);
        if (!std.mem.eql(u8, payload, restored_payload)) return error.S8ColdRestoreMismatch;
        try cleanup(&harness, scale);
        final_diagnostics = restored.diagnostics();
        final_draw_count = @intCast((try restored.npcPresentation(0)).len);
        if (final_diagnostics.entity_count != 0 or final_diagnostics.body_count != 1 or
            final_diagnostics.character_controllers.native_used != 0 or
            final_diagnostics.character_controllers.feature_owned != 0 or
            !final_diagnostics.character_controllers.authority_consistent or
            final_draw_count != 0 or npcQueueOccupancy(final_diagnostics) != 0)
        {
            return error.S8FinalCleanupMismatch;
        }
    }
    allocator.free(envelope);
    allocator.free(payload);
    const live_bytes = tracker.liveBytes();
    if (live_bytes != 0) return error.S8TrackedAllocationLeak;

    const tick_distribution = summarize(samples);
    return .{
        .schema_version = schema_version,
        .kind = if (scale) .scale else .baseline,
        .measured_ticks = measured_ticks,
        .measured_cycles = measured_cycles,
        .ticks_per_cycle = ticks_per_cycle,
        .warmup_cycles = warmup_cycles,
        .tick = tick_distribution,
        .zig_allocator_peak_bytes = tracker.peakBytes(),
        .zig_allocator_live_bytes = live_bytes,
        .max_rss_bytes = maxRssBytes(),
        .peak_entities = metrics.peak_entities,
        .peak_native_bodies = metrics.peak_bodies,
        .peak_native_controllers = metrics.peak_native_controllers,
        .peak_npcs = metrics.peak_npcs,
        .peak_npc_draws = metrics.peak_npc_draws,
        .npc_command_capacity = metrics.npc_command_capacity,
        .npc_outcome_capacity = metrics.npc_outcome_capacity,
        .npc_event_capacity = metrics.npc_event_capacity,
        .npc_command_high_water = metrics.npc_command_high_water,
        .npc_outcome_high_water = metrics.npc_outcome_high_water,
        .npc_event_high_water = metrics.npc_event_high_water,
        .npc_event_drops = metrics.npc_event_drops,
        .npc_state_events = metrics.npc_state_events,
        .npc_transfer_events = metrics.npc_transfer_events,
        .npc_goal_events = metrics.npc_goal_events,
        .navigation_decoded_bytes = metrics.navigation_decoded_bytes,
        .navigation_cooked_wire_bytes = metrics.navigation_cooked_wire_bytes,
        .snapshot_payload_bytes = metrics.snapshot_payload_bytes,
        .save_envelope_bytes = metrics.save_envelope_bytes,
        .held_body_count_proved = true,
        .capacity_rejection_proved = metrics.capacity_rejection_proved,
        .final_entities = final_diagnostics.entity_count,
        .final_native_bodies = final_diagnostics.body_count,
        .final_native_controllers = final_diagnostics.character_controllers.native_used,
        .final_npcs = final_diagnostics.npc.active_count +
            final_diagnostics.npc.waiting_count + final_diagnostics.npc.dormant_count,
        .final_npc_draws = final_draw_count,
        .final_npc_queue_occupancy = npcQueueOccupancy(final_diagnostics),
    };
}

fn trialConfig(namespace: u64) sandbox_contracts.Config {
    return .{
        .namespace = namespace,
        .fixed_delta_seconds = fixed_delta_seconds,
        .npc = .{ .move_speed = 12 },
    };
}

fn activateDistrict(
    harness: *Harness,
    request_id: u64,
    coord: sandbox_contracts.ChunkCoord,
) !sandbox_contracts.LoadTicket {
    try harness.world.submitDistrict(.{ .request_load = .{
        .request_id = request_id,
        .coord = coord,
        .assets = district_assets,
    } });
    try harness.metrics.observe(harness.world);
    try harness.tick(false);
    const ticket = switch (harness.world.pollDistrictOutcome() orelse
        return error.DistrictRequestOutcomeMissing) {
        .load_requested => |value| value.ticket,
        else => return error.UnexpectedDistrictOutcome,
    };
    try harness.drainAmbient();

    for (0..worker_progress_limit) |_| {
        std.Thread.yield() catch {};
        try harness.tick(false);
        var activated = false;
        while (harness.world.pollDistrictOutcome()) |outcome| switch (outcome) {
            .activated => |value| {
                if (!sandbox_contracts.LoadTicket.eql(ticket, value.ticket)) {
                    return error.UnexpectedDistrictTicket;
                }
                activated = true;
            },
            .load_failed => return error.DistrictLoadFailed,
            .cancelled => return error.DistrictLoadCancelled,
            else => return error.UnexpectedDistrictOutcome,
        };
        try harness.drainAmbient();
        if (activated) return ticket;
    }
    return error.DistrictWorkerDidNotComplete;
}

fn unloadDistrict(
    harness: *Harness,
    request_id: u64,
    ticket: sandbox_contracts.LoadTicket,
) !void {
    try harness.world.submitDistrict(.{ .unload = .{
        .request_id = request_id,
        .ticket = ticket,
    } });
    try harness.metrics.observe(harness.world);
    try harness.tick(false);
    switch (harness.world.pollDistrictOutcome() orelse
        return error.DistrictUnloadOutcomeMissing) {
        .unloaded => |value| if (!sandbox_contracts.LoadTicket.eql(ticket, value.ticket)) {
            return error.UnexpectedDistrictTicket;
        },
        else => return error.UnexpectedDistrictOutcome,
    }
    try harness.drainAmbient();
}

fn spawnActors(harness: *Harness) !Identities {
    try harness.world.submitCharacter(.{ .spawn = .{
        .request_id = 3,
        .position = .{ west_x, 0, route_z },
    } });
    try harness.world.submitInteraction(.{ .spawn = .{
        .request_id = 4,
        .pose = .{ .position = .{ west_x, 0.75, route_z } },
    } });
    try harness.metrics.observe(harness.world);
    try harness.tick(false);
    const character = switch (harness.world.pollCharacterOutcome() orelse
        return error.CharacterSpawnOutcomeMissing) {
        .spawned => |value| value.id,
        else => return error.UnexpectedCharacterOutcome,
    };
    const carryable = switch (harness.world.pollInteractionOutcome() orelse
        return error.InteractionSpawnOutcomeMissing) {
        .spawned => |value| value.id,
        else => return error.UnexpectedInteractionOutcome,
    };
    try harness.drainAmbient();
    return .{ .character = character, .carryable = carryable };
}

fn spawnPopulation(harness: *Harness) !void {
    const first_request_id: u64 = 1_000;
    const batch = try population.plan(npc_ceiling, .{
        .first_request_id = first_request_id,
        .start_node = west_node,
        .goal = .{ .patrol_between = .{ .first = west_node, .second = east_node } },
    });
    for (batch.slice()) |command| try harness.world.submitNpc(command);
    try harness.metrics.observe(harness.world);
    try harness.tick(false);
    var seen: [npc_ceiling]bool = [_]bool{false} ** npc_ceiling;
    for (0..npc_ceiling) |_| {
        const spawned = switch (harness.world.pollNpcOutcome() orelse
            return error.NpcSpawnOutcomeMissing) {
            .spawned => |value| value,
            else => return error.UnexpectedNpcSpawnOutcome,
        };
        if (spawned.request_id < first_request_id or
            spawned.request_id >= first_request_id + npc_ceiling or
            !sandbox_contracts.ChunkCoord.eql(spawned.owner, west))
        {
            return error.NpcSpawnOutcomeMismatch;
        }
        const index: usize = @intCast(spawned.request_id - first_request_id);
        if (seen[index]) return error.DuplicateNpcSpawnOutcome;
        for (harness.npc_ids[0..harness.npc_count]) |id| {
            if (std.meta.eql(id, spawned.id)) return error.DuplicateNpcIdentity;
        }
        seen[index] = true;
        harness.npc_ids[index] = spawned.id;
        harness.npc_count += 1;
    }
    for (seen) |value| if (!value) return error.NpcSpawnOutcomeMissing;
    try harness.drainAmbient();

    const before = harness.world.diagnostics();
    try harness.world.submitNpc(.{ .spawn = .{
        .request_id = 2_000,
        .node = west_node,
        .goal = .{ .patrol_between = .{ .first = west_node, .second = east_node } },
    } });
    try harness.metrics.observe(harness.world);
    try harness.tick(false);
    switch (harness.world.pollNpcOutcome() orelse return error.NpcCapacityOutcomeMissing) {
        .rejected => |value| {
            if (value.command != .spawn or value.reason != .capacity_reached or
                value.request_id != 2_000 or value.id != null)
            {
                return error.NpcCapacityOutcomeMismatch;
            }
        },
        else => return error.NpcCapacityWasNotRejected,
    }
    try harness.drainAmbient();
    const after = harness.world.diagnostics();
    if (after.entity_count != before.entity_count or
        after.npc.active_count + after.npc.waiting_count + after.npc.dormant_count != npc_ceiling or
        after.npc.controller_count != before.npc.controller_count or harness.npc_count != npc_ceiling)
    {
        return error.NpcCapacityPartialCommit;
    }
    for (harness.npc_ids[0..harness.npc_count]) |id| _ = try harness.world.npc(id);
    harness.metrics.capacity_rejection_proved = true;
}

fn carryCycle(
    harness: *Harness,
    identities: Identities,
    owner: *sandbox_contracts.ChunkCoord,
    destination: sandbox_contracts.ChunkCoord,
    transaction_id: u64,
    measured: bool,
    explicit_target_x: ?f32,
) !void {
    try collect(harness, transaction_id, identities, owner.*, measured);
    if (harness.world.bodyCount() != held_body_ceiling) return error.HeldBodyCountMismatch;
    const target_x = explicit_target_x orelse
        if (sandbox_contracts.ChunkCoord.eql(destination, east)) east_x else west_x;
    try moveCharacter(harness, identities.character, target_x, measured);
    try drop(harness, transaction_id, identities, destination, measured);
    if (harness.world.bodyCount() != dropped_body_ceiling) return error.DroppedBodyCountMismatch;
    owner.* = destination;
}

fn collect(
    harness: *Harness,
    transaction_id: u64,
    identities: Identities,
    previous_owner: sandbox_contracts.ChunkCoord,
    measured: bool,
) !void {
    try harness.world.submitInteraction(.{ .collect = .{
        .transaction_id = transaction_id,
        .carrier_id = identities.character,
        .carryable_id = identities.carryable,
    } });
    try harness.metrics.observe(harness.world);
    try harness.tick(measured);
    switch (harness.world.pollInteractionOutcome() orelse
        return error.InteractionOutcomeMissing) {
        .collected => |value| {
            if (value.transaction_id != transaction_id or
                !std.meta.eql(value.carrier_id, identities.character) or
                !std.meta.eql(value.carryable_id, identities.carryable) or
                !sandbox_contracts.ChunkCoord.eql(value.previous_owner, previous_owner))
            {
                return error.CollectOutcomeMismatch;
            }
        },
        else => return error.UnexpectedInteractionOutcome,
    }
    try harness.drainAmbient();
    const view = try harness.world.carryable(identities.carryable);
    if (view.body_present or !std.meta.eql(view.ownership, .{
        .inventory_held = identities.character,
    })) return error.HeldOwnershipMismatch;
}

fn drop(
    harness: *Harness,
    transaction_id: u64,
    identities: Identities,
    owner: sandbox_contracts.ChunkCoord,
    measured: bool,
) !void {
    try harness.world.submitInteraction(.{ .drop = .{
        .transaction_id = transaction_id,
        .carrier_id = identities.character,
        .carryable_id = identities.carryable,
        .purpose = .player_requested,
    } });
    try harness.metrics.observe(harness.world);
    try harness.tick(measured);
    switch (harness.world.pollInteractionOutcome() orelse
        return error.InteractionOutcomeMissing) {
        .dropped => |value| {
            if (value.transaction_id != transaction_id or
                !std.meta.eql(value.carrier_id, identities.character) or
                !std.meta.eql(value.carryable_id, identities.carryable) or
                !sandbox_contracts.ChunkCoord.eql(value.owner, owner))
            {
                return error.DropOutcomeMismatch;
            }
        },
        else => return error.UnexpectedInteractionOutcome,
    }
    try harness.drainAmbient();
    const view = try harness.world.carryable(identities.carryable);
    if (!view.body_present or !std.meta.eql(view.ownership, .{
        .spatially_owned = owner,
    })) return error.DropOwnershipMismatch;
}

fn moveCharacter(
    harness: *Harness,
    character_id: sandbox_contracts.PersistentId,
    target_x: f32,
    measured: bool,
) !void {
    for (0..256) |_| {
        const current = try harness.world.character(character_id);
        const delta = target_x - current.position[0];
        if (@abs(delta) <= 0.05) break;
        try harness.world.submitCharacter(.{ .actions = .{
            .id = character_id,
            .move = .{ if (delta > 0) 1 else -1, 0 },
            .facing_yaw = 0,
        } });
        try harness.metrics.observe(harness.world);
        try harness.tick(measured);
        try harness.drainAmbient();
    } else return error.CharacterDidNotReachDestination;

    try harness.world.submitCharacter(.{ .actions = .{
        .id = character_id,
        .move = .{ 0, 0 },
        .facing_yaw = 0,
    } });
    try harness.metrics.observe(harness.world);
    try harness.tick(measured);
    try harness.drainAmbient();
    if (@abs((try harness.world.character(character_id)).position[0] - target_x) > 0.11) {
        return error.CharacterTargetMismatch;
    }
}

fn requireActiveScaleState(
    harness: *Harness,
    scale: bool,
    restored: bool,
) !void {
    _ = restored;
    const value = harness.world.diagnostics();
    const expected_entities: u32 = if (scale) entity_ceiling else 4;
    const expected_controllers: u32 = if (scale) controller_ceiling else 1;
    const expected_npcs: u32 = if (scale) npc_ceiling else 0;
    const draws = try harness.world.npcPresentation(0);
    if (value.entity_count != expected_entities or harness.world.districtCount() != 2 or
        value.body_count != dropped_body_ceiling or
        value.character_controllers.native_used != expected_controllers or
        value.character_controllers.feature_owned != expected_controllers or
        value.character_controllers.native_capacity != controller_capacity or
        !value.character_controllers.authority_consistent or
        value.npc.active_count != expected_npcs or value.npc.waiting_count != 0 or
        value.npc.dormant_count != 0 or draws.len != expected_npcs or
        value.npc.event_drops.total() != 0)
    {
        return error.S8ActiveStateMismatch;
    }
    if (!scale) return;
    for (harness.npc_ids[0..harness.npc_count]) |id| {
        const view = try harness.world.npc(id);
        if (!view.controller_present or view.state != .active or
            (!sandbox_contracts.ChunkCoord.eql(view.owner, west) and
                !sandbox_contracts.ChunkCoord.eql(view.owner, east)))
        {
            return error.S8NpcAuthorityMismatch;
        }
        switch (view.goal) {
            .patrol_between => |goal| {
                if (!npc_contract.NodeRef.eql(goal.first, west_node) or
                    !npc_contract.NodeRef.eql(goal.second, east_node))
                {
                    return error.S8NpcGoalMismatch;
                }
            },
            else => return error.S8NpcGoalMismatch,
        }
    }
}

fn cleanup(harness: *Harness, scale: bool) !void {
    const west_ticket = harness.world.activeDistrictTicketFor(west) orelse
        return error.WestTicketMissingAtCleanup;
    const east_ticket = harness.world.activeDistrictTicketFor(east) orelse
        return error.EastTicketMissingAtCleanup;
    if (scale) {
        for (harness.npc_ids[0..harness.npc_count], 0..) |id, index| {
            try harness.world.submitNpc(.{ .despawn = .{
                .request_id = 10_000 + index,
                .id = id,
            } });
        }
    }
    const character_draws = try harness.world.characterPresentation(0);
    const interaction_draws = try harness.world.interactionPresentation();
    if (character_draws.len != 1 or interaction_draws.len != 1) {
        return error.S8CleanupIdentityMissing;
    }
    const character_id = character_draws[0].persistent_id;
    const carryable_id = interaction_draws[0].persistent_id;
    try harness.world.submitCharacter(.{ .despawn = .{ .id = character_id } });
    try harness.world.submitInteraction(.{ .despawn = .{ .id = carryable_id } });
    try harness.metrics.observe(harness.world);
    try harness.tick(false);

    if (scale) {
        var seen: [npc_ceiling]bool = [_]bool{false} ** npc_ceiling;
        for (0..npc_ceiling) |_| switch (harness.world.pollNpcOutcome() orelse
            return error.NpcDespawnOutcomeMissing) {
            .despawned => |value| {
                if (value.request_id < 10_000 or value.request_id >= 10_000 + npc_ceiling) {
                    return error.NpcDespawnOutcomeMismatch;
                }
                const index: usize = @intCast(value.request_id - 10_000);
                if (seen[index] or !std.meta.eql(value.id, harness.npc_ids[index])) {
                    return error.NpcDespawnOutcomeMismatch;
                }
                seen[index] = true;
            },
            else => return error.UnexpectedNpcDespawnOutcome,
        };
        for (seen) |value| if (!value) return error.NpcDespawnOutcomeMissing;
    }
    switch (harness.world.pollCharacterOutcome() orelse
        return error.CharacterDespawnOutcomeMissing) {
        .despawned => |id| if (!std.meta.eql(id, character_id)) {
            return error.CharacterDespawnMismatch;
        },
        else => return error.UnexpectedCharacterOutcome,
    }
    switch (harness.world.pollInteractionOutcome() orelse
        return error.InteractionDespawnOutcomeMissing) {
        .despawned => |id| if (!std.meta.eql(id, carryable_id)) {
            return error.InteractionDespawnMismatch;
        },
        else => return error.UnexpectedInteractionOutcome,
    }
    try harness.drainAmbient();
    if (harness.world.diagnostics().entity_count != 2 or harness.world.bodyCount() != 7) {
        return error.S8ActorCleanupMismatch;
    }
    try unloadDistrict(harness, 20_000, west_ticket);
    try unloadDistrict(harness, 20_001, east_ticket);
}

fn runProof(init: std.process.Init, content_root: content.ContentRootPath) !ProofReport {
    const config = trialConfig(80_009);
    const content_cohort = try admitContentCohort(init, content_root);
    const limits = sandbox_replay.Limits{
        .max_file_bytes = replay_ceiling_bytes,
        .max_bootstrap = 128,
        .max_commands = 1_024,
        .max_ingress = 16,
        .max_digests = replay_ticks,
    };
    var metrics = Metrics{};
    setNavigationAccounting(&metrics);
    var capture_bytes: []u8 = undefined;
    {
        var world = try simulation.Simulation.init(init.gpa, config);
        defer world.deinit();
        switch (try world.beginFlightRecording(content_cohort, limits)) {
            .admitted => {},
            .rejected => return error.S8ReplayCaptureNotAdmitted,
        }
        var harness = Harness{ .io = init.io, .world = &world, .metrics = &metrics };
        _ = try activateDistrict(&harness, 1, west);
        _ = try activateDistrict(&harness, 2, east);
        const identities = try spawnActors(&harness);
        try spawnPopulation(&harness);
        var owner = west;
        try carryCycle(&harness, identities, &owner, east, 10, false, east_x);
        while (world.tickIndex() < replay_ticks) {
            try harness.tick(false);
            try harness.drainAmbient();
        }
        if (world.tickIndex() != replay_ticks) return error.S8ReplayTickCountMismatch;
        capture_bytes = try world.finishFlightRecording(init.gpa);
    }
    defer init.gpa.free(capture_bytes);
    if (capture_bytes.len > replay_ceiling_bytes) return error.S8ReplayEnvelopeCeilingExceeded;
    var parsed = try sandbox_replay.parseCompatible(
        init.gpa,
        capture_bytes,
        content_cohort,
    );
    defer parsed.deinit();
    if (parsed.tick_digests.len != replay_ticks) return error.S8ReplayDigestCountMismatch;
    const replay_result = try simulation.replayCapture(
        init.gpa,
        parsed.view(),
        content_cohort,
    );
    const matched = switch (replay_result) {
        .matched => |value| value.completed_ticks == replay_ticks,
        .divergent => false,
    };
    if (!matched) return error.S8ReplayDidNotMatch;
    return .{
        .schema_version = schema_version,
        .kind = "replay-proof",
        .completed_ticks = replay_ticks,
        .replay_envelope_bytes = capture_bytes.len,
        .bootstrap_commands = parsed.bootstrap_commands.len,
        .recorded_commands = parsed.commands.len,
        .district_ingress = parsed.district_ingress.len,
        .tick_digests = parsed.tick_digests.len,
        .replay_matched = true,
    };
}

fn admitContentCohort(
    init: std.process.Init,
    content_root: content.ContentRootPath,
) !sandbox_replay.ContentCohort {
    // Admission loads both installed bundles, validates their identities and
    // complete cooked/logical navigation fragments, and validates the joined
    // route before any Flecs world or Jolt authority is constructed.
    var admission = switch (try district_content_catalog.admit(
        init.io,
        init.gpa,
        content_root,
    )) {
        .admitted => |value| value,
        .failed => |failure| {
            std.debug.print("installed S8 catalog admission failed: {any}\n", .{failure});
            return error.InstalledS8CatalogAdmissionFailed;
        },
    };
    defer admission.deinit();
    const view = admission.view();
    if (view.entries.len != 2 or
        admission.entryForCoordinate(west) == null or
        admission.entryForCoordinate(east) == null)
    {
        return error.InstalledS8CatalogSemanticsInvalid;
    }
    inline for (.{ west, east }) |coord| {
        const build = try sandbox_contracts.proceduralDistrictBuild(coord);
        try admission.validateLogicalRecord(coord, build.recipe_version, build.checksum);
    }
    return admission.contentCohort();
}

fn saveMetadata(
    config: sandbox_contracts.Config,
    content_cohort: sandbox_replay.ContentCohort,
) !sandbox_save.Metadata {
    return .{
        .payload_schema = sandbox_contracts.snapshot_schema,
        .simulation_build_digest = try simulation_snapshot.currentSimulationBuildFingerprint(),
        .world_config_digest = try simulation_snapshot.worldConfigFingerprint(config),
        .content_digest = try content_cohort.fingerprint(),
    };
}

fn setNavigationAccounting(metrics: *Metrics) void {
    const node_bytes = 2 * 3 * district_contract.decoded_bytes_per_navigation_node;
    const edge_bytes = 2 * 5 * district_contract.decoded_bytes_per_navigation_edge;
    metrics.navigation_decoded_bytes = node_bytes + edge_bytes;
    metrics.navigation_cooked_wire_bytes = node_bytes + edge_bytes;
    std.debug.assert(metrics.navigation_decoded_bytes <= 640);
    std.debug.assert(metrics.navigation_cooked_wire_bytes <= 640);
}

fn npcQueueOccupancy(value: sandbox_diagnostics.Diagnostics) u32 {
    return value.npc.commands.occupancy + value.npc.outcomes.occupancy + value.npc.events.occupancy;
}

fn parseInvocation(init: std.process.Init) !?Invocation {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next() orelse return error.MissingExecutableName;
    const first = args.next() orelse return error.ExpectedInstalledContentRoot;
    if (std.mem.eql(u8, first, "--help")) {
        std.debug.print("usage: incinerator_s8_measure [child-mode] /absolute/content/root\n", .{});
        return null;
    }
    var mode: Mode = .aggregate;
    const raw_root = if (std.mem.eql(u8, first, "proof-child")) blk: {
        mode = .proof_child;
        break :blk args.next() orelse return error.ExpectedInstalledContentRoot;
    } else if (std.mem.eql(u8, first, "baseline-child")) blk: {
        mode = .baseline_child;
        break :blk args.next() orelse return error.ExpectedInstalledContentRoot;
    } else if (std.mem.eql(u8, first, "scale-child")) blk: {
        mode = .scale_child;
        break :blk args.next() orelse return error.ExpectedInstalledContentRoot;
    } else first;
    if (args.next() != null) return error.TooManyS8MeasurementArguments;
    return .{
        .mode = mode,
        .content_root = try content.ContentRootPath.parse(raw_root),
    };
}

fn writeJson(init: std.process.Init, value: anytype) !void {
    var stdout_buffer: [16 * 1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    try std.json.Stringify.value(value, .{ .whitespace = .indent_2 }, stdout);
    try stdout.writeByte('\n');
    try stdout.flush();
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

fn maxRssBytes() usize {
    const value = std.posix.getrusage(std.posix.rusage.SELF).maxrss;
    if (value <= 0) return 0;
    return @intCast(value);
}

fn positiveDelta(lhs: usize, rhs: usize) usize {
    return lhs -| rhs;
}

test "S8 methodology is the declared exact bounded workload" {
    try std.testing.expectEqual(@as(usize, 16_384), measured_ticks);
    try std.testing.expectEqual(@as(usize, 32), measured_cycles);
    try std.testing.expectEqual(@as(usize, 512), ticks_per_cycle);
    try std.testing.expectEqual(@as(usize, 1), warmup_cycles);
    try std.testing.expectEqual(@as(usize, 3), trial_count);
}

test "S8 percentiles use nearest rank" {
    var samples = [_]u64{ 5, 1, 4, 2, 3 };
    const distribution = summarize(&samples);
    try std.testing.expectEqual(@as(u64, 3), distribution.p50_ns);
    try std.testing.expectEqual(@as(u64, 5), distribution.p95_ns);
    try std.testing.expectEqual(@as(u64, 5), distribution.p99_ns);
}

test "S8 positive deltas never underflow" {
    try std.testing.expectEqual(@as(usize, 3), positiveDelta(8, 5));
    try std.testing.expectEqual(@as(usize, 0), positiveDelta(5, 8));
}
