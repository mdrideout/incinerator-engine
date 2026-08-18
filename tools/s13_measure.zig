//! ReleaseFast S13 authored-population measurement.
//!
//! The three cohorts deliberately make different claims:
//! - 12/16-member owner trials measure deterministic activity work with no
//!   allocator in the decision path;
//! - the 16-member Jolt trial measures unique physical controllers and exact
//!   authored placement; and
//! - the 64-NPC trial measures only bounded synthetic command production.

const std = @import("std");
const builtin = @import("builtin");
const district = @import("district_contract");
const engine = @import("incinerator_engine");
const npc = @import("npc_contract");
const physics_adapter = @import("jolt_physics");
const population = @import("population_contract");
const owner_module = @import("sandbox_population");
const catalog = @import("sandbox_population_catalog");
const recipe = @import("sandbox_district_recipe");
const budgets = @import("session_budgets");
const protocol = @import("session_protocol");

const schema_version: u16 = 1;
const owner_ticks: usize = 8_192;
const physical_ticks: usize = 2_048;
const physical_warmup_ticks: usize = 120;
const synthetic_waves: usize = 4_096;
const persistence_samples: usize = 256;
const p99_ceiling_ns: u64 = 4_166_000;

const Distribution = struct {
    samples: usize,
    mean_ns: f64,
    p50_ns: u64,
    p95_ns: u64,
    p99_ns: u64,
    max_ns: u64,
};

const OwnerReport = struct {
    cohort: population.Cohort,
    members: usize,
    ticks: usize,
    timing: Distribution,
    fixed_owner_bytes: usize,
    workload_heap_allocations: usize,
    decisions: u64,
    transitions_drained: u64,
    slot_contentions: u64,
    lease_expirations: u64,
    intent_queue_high_water: u32,
    transition_queue_high_water: u32,
    transition_drops: u64,
    logical_digest: u64,
    snapshot_json_bytes: usize,
    snapshot_encode: Distribution,
    snapshot_parse_restore: Distribution,
};

const PhysicalReport = struct {
    actors: usize,
    warmup_ticks: usize,
    measured_ticks: usize,
    timing: Distribution,
    static_bodies: usize,
    character_virtual_controllers: usize,
    placement_queries: usize,
    placement_rejections: usize,
    separation_violations: usize,
    max_rss_bytes: usize,
};

const SyntheticReport = struct {
    npcs: usize,
    waves: usize,
    commands: usize,
    timing: Distribution,
    workload_heap_allocations: usize,
    digest: u64,
};

const ProjectionCohort = struct {
    npcs: usize,
    full_snapshot_wire_bytes: usize,
    full_snapshot_bytes_per_second_at_npc_rate: usize,
};

const ProjectionReport = struct {
    npc_state_fixed_bytes: usize,
    empty_snapshot_wire_bytes: usize,
    ordinary: ProjectionCohort,
    physical: ProjectionCohort,
    synthetic: ProjectionCohort,
};

const Report = struct {
    schema_version: u16,
    benchmark: []const u8,
    zig_version: []const u8,
    optimize: []const u8,
    target_arch: []const u8,
    target_os: []const u8,
    methodology: []const u8,
    ordinary: OwnerReport,
    physical_owner: OwnerReport,
    physical_jolt: PhysicalReport,
    synthetic: SyntheticReport,
    projection: ProjectionReport,
    ceilings: struct {
        owner_p99_ns: u64 = p99_ceiling_ns,
        physical_p99_ns: u64 = p99_ceiling_ns,
        synthetic_p99_ns: u64 = p99_ceiling_ns,
        population_workload_heap_allocations: usize = 0,
    } = .{},
};

pub fn main(init: std.process.Init) !void {
    if (builtin.mode != .ReleaseFast) return error.S13MeasurementRequiresReleaseFast;
    try catalog.validate();
    const ordinary = try measureOwner(init, .ordinary);
    const physical_owner = try measureOwner(init, .physical_stress);
    const physical_jolt = try measurePhysical(init);
    const synthetic = try measureSynthetic(init);
    const projection = try measureProjection();
    if (ordinary.timing.p99_ns > p99_ceiling_ns or
        physical_owner.timing.p99_ns > p99_ceiling_ns)
    {
        return error.S13PopulationOwnerP99CeilingExceeded;
    }
    if (physical_jolt.timing.p99_ns > p99_ceiling_ns) {
        return error.S13PhysicalP99CeilingExceeded;
    }
    if (synthetic.timing.p99_ns > p99_ceiling_ns) {
        return error.S13SyntheticP99CeilingExceeded;
    }
    try writeJson(init, Report{
        .schema_version = schema_version,
        .benchmark = "s13-authored-population",
        .zig_version = builtin.zig_version_string,
        .optimize = @tagName(builtin.mode),
        .target_arch = @tagName(builtin.target.cpu.arch),
        .target_os = @tagName(builtin.target.os.tag),
        .methodology = "8192 fixed owner ticks for separate 12/16 authored cohorts with immediate deterministic host acknowledgements; 2048 measured real-Jolt ticks for 24 uniquely placed activity-slot CharacterVirtual actors after 120 warmup ticks; 4096 bounded 64-command synthetic planning waves; exact protocol-17 full-snapshot wire sizes",
        .ordinary = ordinary,
        .physical_owner = physical_owner,
        .physical_jolt = physical_jolt,
        .synthetic = synthetic,
        .projection = projection,
    });
}

fn measureOwner(init: std.process.Init, cohort: population.Cohort) !OwnerReport {
    var owner = try owner_module.Owner.init(.{ .cohort = cohort });
    var samples: [owner_ticks]u64 = undefined;
    var transitions: u64 = 0;
    for (&samples, 0..) |*sample, index| {
        const tick: u64 = @intCast(index + 1);
        const started = now(init.io);
        try owner.step(tick);
        while (owner.pollIntent()) |intent| switch (intent) {
            .spawn => |spawn| try owner.bindActor(
                spawn.member,
                spawn.actor_generation,
                .{ .namespace = 13_013, .local = spawn.member.value },
                tick,
            ),
            .set_destination => |destination| try owner.arrive(
                destination.member,
                destination.actor,
                tick,
            ),
        };
        while (owner.pollTransition() != null) transitions +|= 1;
        sample.* = elapsedNs(started, now(init.io));
    }
    const diagnostics = owner.diagnostics();
    const member_count = switch (cohort) {
        .ordinary => population.ordinary_member_count,
        .physical_stress => population.max_members,
    };
    if (diagnostics.live != member_count or diagnostics.awaiting_spawn != 0 or
        diagnostics.vacant != 0 or diagnostics.replacement_pending != 0 or
        diagnostics.intents.occupancy != 0 or diagnostics.transitions.occupancy != 0 or
        diagnostics.transitions.rejected != 0)
    {
        return error.InvalidS13OwnerEvidence;
    }

    const saved = try owner.snapshot();
    var encode_samples: [persistence_samples]u64 = undefined;
    var restore_samples: [persistence_samples]u64 = undefined;
    var encoded_bytes: usize = 0;
    for (0..persistence_samples) |index| {
        const encode_started = now(init.io);
        const bytes = try std.json.Stringify.valueAlloc(init.gpa, saved, .{});
        encode_samples[index] = elapsedNs(encode_started, now(init.io));
        defer init.gpa.free(bytes);
        if (encoded_bytes == 0) encoded_bytes = bytes.len;
        if (bytes.len != encoded_bytes) return error.UnstableS13PopulationSnapshotSize;

        const restore_started = now(init.io);
        var parsed = try std.json.parseFromSlice(
            population.SnapshotV1,
            init.gpa,
            bytes,
            .{},
        );
        defer parsed.deinit();
        const restored = try owner_module.Owner.restore(parsed.value);
        restore_samples[index] = elapsedNs(restore_started, now(init.io));
        if (restored.logicalDigest() != owner.logicalDigest()) {
            return error.S13PopulationRestoreDigestMismatch;
        }
    }
    return .{
        .cohort = cohort,
        .members = member_count,
        .ticks = owner_ticks,
        .timing = summarize(&samples),
        .fixed_owner_bytes = @sizeOf(owner_module.Owner),
        .workload_heap_allocations = 0,
        .decisions = diagnostics.decisions,
        .transitions_drained = transitions,
        .slot_contentions = diagnostics.slot_contentions,
        .lease_expirations = diagnostics.lease_expirations,
        .intent_queue_high_water = diagnostics.intents.high_water,
        .transition_queue_high_water = diagnostics.transitions.high_water,
        .transition_drops = diagnostics.transitions.rejected,
        .logical_digest = owner.logicalDigest(),
        .snapshot_json_bytes = encoded_bytes,
        .snapshot_encode = summarize(&encode_samples),
        .snapshot_parse_restore = summarize(&restore_samples),
    };
}

fn measurePhysical(init: std.process.Init) !PhysicalReport {
    var physics = try physics_adapter.Physics.init();
    defer physics.deinit();

    var builds: [recipe.installed_coords.len]district.DistrictBuild = undefined;
    for (recipe.installed_coords, 0..) |coord, index| {
        builds[index] = recipe.build(coord, recipe.current_recipe_version).ready;
    }
    var body_count: usize = 0;
    var bodies: [1 + recipe.installed_coords.len * district.max_static_boxes]physics_adapter.BodyId = undefined;
    bodies[body_count] = try physics.createStaticBox(.{ 0, -1, 0 }, .{ 50, 1, 50 });
    body_count += 1;
    for (builds) |build| for (build.boxes()) |box| {
        bodies[body_count] = try physics.createStaticBox(box.pose.position, box.half_extents);
        body_count += 1;
    };
    defer {
        for (bodies[0..body_count]) |body| _ = physics.removeBody(body);
    }

    var controllers = physics.characterControllers();
    var handles: [population.max_activity_slots]physics_adapter.CharacterId = undefined;
    var positions: [population.max_activity_slots][3]f32 = undefined;
    var placement_rejections: usize = 0;
    for (catalog.activity_slots, 0..) |slot, index| {
        const desc = engine.physics.CharacterDesc{
            .position = slot.position,
            .radius = catalog.placement_clearance.radius,
            .half_height = catalog.placement_clearance.half_height,
        };
        if (!try controllers.placementClear(desc, 0.05)) {
            placement_rejections += 1;
            continue;
        }
        handles[index] = try controllers.createCharacter(desc);
        positions[index] = slot.position;
    }
    if (placement_rejections != 0 or
        controllers.controllerCount() != population.max_activity_slots)
    {
        return error.InvalidS13PhysicalPlacement;
    }
    defer for (handles) |handle| controllers.destroyCharacter(handle) catch unreachable;

    for (0..physical_warmup_ticks) |_| try stepCharacters(&physics, &controllers, &handles);
    var samples: [physical_ticks]u64 = undefined;
    for (&samples) |*sample| {
        const started = now(init.io);
        try stepCharacters(&physics, &controllers, &handles);
        sample.* = elapsedNs(started, now(init.io));
    }

    var separation_violations: usize = 0;
    for (handles, 0..) |handle, index| {
        positions[index] = (try controllers.characterState(handle)).position;
        for (positions[0..index]) |earlier| {
            if (horizontalDistanceSquared(positions[index], earlier) <
                catalog.activity_separation * catalog.activity_separation)
            {
                separation_violations += 1;
            }
        }
    }
    if (separation_violations != 0) return error.S13PhysicalSeparationViolation;
    return .{
        .actors = population.max_activity_slots,
        .warmup_ticks = physical_warmup_ticks,
        .measured_ticks = physical_ticks,
        .timing = summarize(&samples),
        .static_bodies = body_count,
        .character_virtual_controllers = controllers.controllerCount(),
        .placement_queries = population.max_activity_slots,
        .placement_rejections = placement_rejections,
        .separation_violations = separation_violations,
        .max_rss_bytes = maxRssBytes(),
    };
}

fn stepCharacters(
    physics: *physics_adapter.Physics,
    controllers: *physics_adapter.CharacterControllers,
    handles: *const [population.max_activity_slots]physics_adapter.CharacterId,
) !void {
    try physics.update(1.0 / 120.0);
    for (handles) |handle| {
        const before = try controllers.characterState(handle);
        var velocity = before.velocity;
        velocity[1] = @max(velocity[1] - 20.0 / 120.0, -55.0);
        _ = try controllers.updateCharacter(handle, .{ .velocity = velocity }, 1.0 / 120.0);
    }
}

fn measureSynthetic(init: std.process.Init) !SyntheticReport {
    var samples: [synthetic_waves]u64 = undefined;
    var digest: u64 = 0;
    const template = population.SyntheticTemplate{
        .first_request_id = 1,
        .position = .{ 0, 0, 0 },
        .facing_yaw = 0,
        .anchor = .{ .coord = recipe.navigation_west_coord, .index = 0 },
        .hostile_to_players = false,
        .goal = .hold,
    };
    for (&samples, 0..) |*sample, wave| {
        var current = template;
        current.first_request_id = 1 + wave * npc.max_npcs;
        const started = now(init.io);
        const batch = try population.planSynthetic(npc.max_npcs, current);
        for (batch.slice()) |command| switch (command) {
            .spawn => |spawn| digest +%= spawn.request_id,
            else => return error.InvalidS13SyntheticCommand,
        };
        sample.* = elapsedNs(started, now(init.io));
    }
    if (digest == 0) return error.InvalidS13SyntheticDigest;
    return .{
        .npcs = npc.max_npcs,
        .waves = synthetic_waves,
        .commands = synthetic_waves * npc.max_npcs,
        .timing = summarize(&samples),
        .workload_heap_allocations = 0,
        .digest = digest,
    };
}

fn measureProjection() !ProjectionReport {
    const empty_bytes = try projectionBytes(0);
    return .{
        .npc_state_fixed_bytes = @sizeOf(protocol.NpcState),
        .empty_snapshot_wire_bytes = empty_bytes,
        .ordinary = try projectionCohort(population.ordinary_member_count),
        .physical = try projectionCohort(population.max_members),
        .synthetic = try projectionCohort(npc.max_npcs),
    };
}

fn projectionCohort(count: usize) !ProjectionCohort {
    const bytes = try projectionBytes(count);
    return .{
        .npcs = count,
        .full_snapshot_wire_bytes = bytes,
        .full_snapshot_bytes_per_second_at_npc_rate = bytes * budgets.npc_snapshot_hz,
    };
}

fn projectionBytes(count: usize) !usize {
    var snapshot = protocol.Snapshot.empty();
    snapshot.sequence.value = 1;
    snapshot.server_tick = 1;
    snapshot.npc_update = true;
    snapshot.npc_count = @intCast(count);
    for (snapshot.npcs[0..count], 0..) |*value, index| value.* = .{
        .entity = .{ .index = @intCast(index + 1), .generation = 1 },
        .position = .{ @floatFromInt(index), 0, 0 },
        .velocity = .{ 0, 0, 0 },
        .facing_yaw = 0,
        .state = .active,
        .population_member = if (index < population.max_members)
            @intCast(index + 1)
        else
            0,
        .population_role = if (index < population.max_members) .resident else .unassigned,
        .combat_disposition = if (index < population.max_members) .passive else .unassigned,
        .activity_kind = if (index < population.max_members) .visit else .none,
        .activity_state = if (index < population.max_members) .traveling else .unassigned,
    };
    var storage: [budgets.max_wire_message_bytes]u8 = undefined;
    return (try protocol.encodeServer(.{ .snapshot = snapshot }, &storage)).len;
}

fn horizontalDistanceSquared(lhs: [3]f32, rhs: [3]f32) f32 {
    const dx = lhs[0] - rhs[0];
    const dz = lhs[2] - rhs[2];
    return dx * dx + dz * dz;
}

fn summarize(samples: []u64) Distribution {
    std.mem.sort(u64, samples, {}, std.sort.asc(u64));
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

fn writeJson(init: std.process.Init, value: anytype) !void {
    var stdout_buffer: [32 * 1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    try std.json.Stringify.value(value, .{ .whitespace = .indent_2 }, stdout);
    try stdout.writeByte('\n');
    try stdout.flush();
}

test "S13 measurement cohorts and ceilings remain explicit" {
    try std.testing.expectEqual(@as(usize, 12), population.ordinary_member_count);
    try std.testing.expectEqual(@as(usize, 16), population.max_members);
    try std.testing.expectEqual(@as(usize, 64), npc.max_npcs);
    try std.testing.expectEqual(@as(usize, 8_192), owner_ticks);
    try std.testing.expectEqual(@as(usize, 2_048), physical_ticks);
    try std.testing.expectEqual(@as(u64, 4_166_000), p99_ceiling_ns);
    var samples = [_]u64{ 5, 1, 3, 2, 4 };
    const distribution = summarize(&samples);
    try std.testing.expectEqual(@as(u64, 3), distribution.p50_ns);
    try std.testing.expectEqual(@as(u64, 5), distribution.p99_ns);
}
