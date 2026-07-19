//! Versioned SDL-free measurement for the S7 interaction/ownership slice.

const std = @import("std");
const builtin = @import("builtin");
const simulation = @import("sandbox_simulation");
const character_contract = @import("character_contract");
const district_feature_contract = @import("district_feature_contract");
const interaction_contract = @import("interaction_feature_contract");
const sandbox_contracts = @import("sandbox_host_contracts");
const sandbox_diagnostics = @import("sandbox_diagnostics_contract");

const fixed_delta_seconds: f32 = 1.0 / 120.0;
const west = sandbox_contracts.navigation_west_coord;
const east = sandbox_contracts.navigation_east_coord;
const west_x: f32 = 6;
const east_x: f32 = 10;
const route_z: f32 = 3;
const district_assets = district_feature_contract.Assets{
    .scene = .{ .index = 17, .generation = 2 },
};
const worker_progress_limit: usize = 10_000;
const max_cycles: usize = 4_096;

const Config = struct {
    cycles: usize = 128,
};

const Distribution = struct {
    samples: usize,
    mean_ns: f64,
    p50_ns: u64,
    p95_ns: u64,
    p99_ns: u64,
    max_ns: u64,
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
    workload: []const u8,
    cycles_requested: usize,
    cycles_completed: usize,
    cycle_wall: Distribution,
    total_wall_ns: u64,
    completed_ticks: u64,
    commands_submitted: u64,
    outcomes_observed: u64,
    events_observed: u64,
    cancellation_while_held_completed: bool,
    peak_entities: u32,
    peak_bodies: u32,
    peak_active_bodies: u32,
    peak_command_queue_occupancy: u64,
    peak_outcome_queue_occupancy: u64,
    peak_event_queue_occupancy: u64,
    queue_rejections: u64,
    persistence_snapshots: u64,
    active_persistence_min_bytes: usize,
    active_persistence_max_bytes: usize,
    dormant_persistence_min_bytes: usize,
    dormant_persistence_max_bytes: usize,
    persistence_bytes_total: u64,
    final_entities: u32,
    final_bodies: u32,
    final_active_bodies: u32,
    final_command_queue_occupancy: u64,
    final_outcome_queue_occupancy: u64,
    final_event_queue_occupancy: u64,
};

const Metrics = struct {
    commands_submitted: u64 = 0,
    outcomes_observed: u64 = 0,
    events_observed: u64 = 0,
    peak_entities: u32 = 0,
    peak_bodies: u32 = 0,
    peak_active_bodies: u32 = 0,
    peak_command_queue_occupancy: u64 = 0,
    peak_outcome_queue_occupancy: u64 = 0,
    peak_event_queue_occupancy: u64 = 0,
    queue_rejections: u64 = 0,
    persistence_snapshots: u64 = 0,
    active_persistence_min_bytes: usize = std.math.maxInt(usize),
    active_persistence_max_bytes: usize = 0,
    dormant_persistence_min_bytes: usize = std.math.maxInt(usize),
    dormant_persistence_max_bytes: usize = 0,
    persistence_bytes_total: u64 = 0,

    fn observe(self: *Metrics, world: *simulation.Simulation) void {
        const value = world.diagnostics();
        const command_occupancy = queueOccupancy(&.{
            value.crates.commands,
            value.characters.commands,
            value.vehicles.commands,
            value.district.commands,
            value.interaction.commands,
        });
        const outcome_occupancy = queueOccupancy(&.{
            value.crates.outcomes,
            value.characters.outcomes,
            value.vehicles.outcomes,
            value.district.outcomes,
            value.interaction.outcomes,
        });
        const event_occupancy = queueOccupancy(&.{
            value.characters.events,
            value.vehicles.events,
            value.district.events,
        });
        self.peak_entities = @max(self.peak_entities, value.entity_count);
        self.peak_bodies = @max(self.peak_bodies, value.body_count);
        self.peak_active_bodies = @max(
            self.peak_active_bodies,
            value.active_body_count,
        );
        self.peak_command_queue_occupancy = @max(
            self.peak_command_queue_occupancy,
            command_occupancy,
        );
        self.peak_outcome_queue_occupancy = @max(
            self.peak_outcome_queue_occupancy,
            outcome_occupancy,
        );
        self.peak_event_queue_occupancy = @max(
            self.peak_event_queue_occupancy,
            event_occupancy,
        );
        self.queue_rejections = queueRejections(value);
    }

    fn recordPersistence(self: *Metrics, dormant: bool, byte_count: usize) !void {
        self.persistence_snapshots += 1;
        self.persistence_bytes_total = try std.math.add(
            u64,
            self.persistence_bytes_total,
            byte_count,
        );
        if (dormant) {
            self.dormant_persistence_min_bytes = @min(
                self.dormant_persistence_min_bytes,
                byte_count,
            );
            self.dormant_persistence_max_bytes = @max(
                self.dormant_persistence_max_bytes,
                byte_count,
            );
        } else {
            self.active_persistence_min_bytes = @min(
                self.active_persistence_min_bytes,
                byte_count,
            );
            self.active_persistence_max_bytes = @max(
                self.active_persistence_max_bytes,
                byte_count,
            );
        }
    }
};

pub fn main(init: std.process.Init) !void {
    const config = try parseArgs(init) orelse return;
    try validateConfig(config);
    const cycle_samples = try init.gpa.alloc(u64, config.cycles);
    defer init.gpa.free(cycle_samples);

    var metrics = Metrics{};
    const total_start = now(init.io);
    var world = try simulation.Simulation.init(init.gpa, .{
        .namespace = 70_007,
        .fixed_delta_seconds = fixed_delta_seconds,
    });
    defer world.deinit();
    metrics.observe(&world);

    const west_ticket = try activateDistrict(&world, &metrics, 1, west);
    const east_ticket = try activateDistrict(&world, &metrics, 2, east);
    try requireCounts(&world, 2, 2, 7);

    const identities = try spawnActors(&world, &metrics);
    try requireCounts(&world, 4, 2, 8);

    var cycle_start = now(init.io);
    try collect(
        &world,
        &metrics,
        10,
        identities.character,
        identities.carryable,
        west,
    );
    try requireCounts(&world, 4, 2, 7);
    try unloadDistrict(&world, &metrics, 11, west_ticket);
    try requireCounts(&world, 3, 1, 4);

    // S7-specific cancellation: the source owner is requested again while
    // the object is logically held. Cancellation must leave holder, object,
    // destination residency, entity count, and body count unchanged, and a
    // later load of that coordinate must still succeed in a repeated cycle.
    try cancelDistrictLoad(&world, &metrics, 12, 13, west);
    try requireHeld(&world, identities.character, identities.carryable);
    try requireCounts(&world, 3, 1, 4);

    try moveCharacter(&world, &metrics, identities.character, east_x);
    try drop(
        &world,
        &metrics,
        14,
        identities.character,
        identities.carryable,
        east,
    );
    try requireCounts(&world, 3, 1, 5);
    try recordCanonicalPersistence(init.gpa, &world, &metrics, false);
    try unloadDistrict(&world, &metrics, 15, east_ticket);
    try requireCounts(&world, 2, 0, 1);
    try recordCanonicalPersistence(init.gpa, &world, &metrics, true);
    var active_ticket = try activateDistrict(&world, &metrics, 16, east);
    try requireCounts(&world, 3, 1, 5);
    cycle_samples[0] = elapsedNs(cycle_start, now(init.io));

    var active_coord = east;
    for (1..config.cycles) |cycle_index| {
        cycle_start = now(init.io);
        const destination = if (sandbox_contracts.ChunkCoord.eql(active_coord, east))
            west
        else
            east;
        const destination_x = if (sandbox_contracts.ChunkCoord.eql(destination, west))
            west_x
        else
            east_x;
        const request_base: u64 = 100 + @as(u64, @intCast(cycle_index)) * 10;

        try collect(
            &world,
            &metrics,
            request_base,
            identities.character,
            identities.carryable,
            active_coord,
        );
        try unloadDistrict(&world, &metrics, request_base + 1, active_ticket);
        try requireCounts(&world, 2, 0, 1);
        active_ticket = try activateDistrict(
            &world,
            &metrics,
            request_base + 2,
            destination,
        );
        try moveCharacter(
            &world,
            &metrics,
            identities.character,
            destination_x,
        );
        try drop(
            &world,
            &metrics,
            request_base + 3,
            identities.character,
            identities.carryable,
            destination,
        );
        try recordCanonicalPersistence(init.gpa, &world, &metrics, false);
        try unloadDistrict(&world, &metrics, request_base + 4, active_ticket);
        try requireCounts(&world, 2, 0, 1);
        try recordCanonicalPersistence(init.gpa, &world, &metrics, true);
        active_ticket = try activateDistrict(
            &world,
            &metrics,
            request_base + 5,
            destination,
        );
        try requireCounts(&world, 3, 1, 5);
        active_coord = destination;
        cycle_samples[cycle_index] = elapsedNs(cycle_start, now(init.io));
    }

    try cleanup(
        &world,
        &metrics,
        90_000,
        identities.character,
        identities.carryable,
        active_ticket,
    );
    const total_wall_ns = elapsedNs(total_start, now(init.io));
    const final = world.diagnostics();
    const final_command_occupancy = commandOccupancy(final);
    const final_outcome_occupancy = outcomeOccupancy(final);
    const final_event_occupancy = eventOccupancy(final);
    if (final.entity_count != 0 or final.body_count != 1 or
        final.active_body_count != 0 or final_command_occupancy != 0 or
        final_outcome_occupancy != 0 or final_event_occupancy != 0 or
        metrics.queue_rejections != 0 or
        metrics.active_persistence_min_bytes == std.math.maxInt(usize) or
        metrics.dormant_persistence_min_bytes == std.math.maxInt(usize))
    {
        return error.FinalMeasurementInvariantFailed;
    }

    const resolution = std.Io.Clock.resolution(.awake, init.io) catch
        std.Io.Duration.zero;
    const report = Report{
        .schema_version = 1,
        .benchmark = "s7_interaction_cross_district_ownership",
        .zig_version = builtin.zig_version_string,
        .optimize = @tagName(builtin.mode),
        .target_arch = @tagName(builtin.target.cpu.arch),
        .target_os = @tagName(builtin.target.os.tag),
        .target_abi = @tagName(builtin.target.abi),
        .cpu_count = try std.Thread.getCpuCount(),
        .clock = "awake",
        .clock_resolution_ns = durationNs(resolution),
        .fixed_delta_seconds = fixed_delta_seconds,
        .workload = "one_world_two_districts_one_character_one_carryable_real_jolt_collect_cross_drop_unload_cancel_reload",
        .cycles_requested = config.cycles,
        .cycles_completed = config.cycles,
        .cycle_wall = summarize(cycle_samples),
        .total_wall_ns = total_wall_ns,
        .completed_ticks = world.tickIndex(),
        .commands_submitted = metrics.commands_submitted,
        .outcomes_observed = metrics.outcomes_observed,
        .events_observed = metrics.events_observed,
        .cancellation_while_held_completed = true,
        .peak_entities = metrics.peak_entities,
        .peak_bodies = metrics.peak_bodies,
        .peak_active_bodies = metrics.peak_active_bodies,
        .peak_command_queue_occupancy = metrics.peak_command_queue_occupancy,
        .peak_outcome_queue_occupancy = metrics.peak_outcome_queue_occupancy,
        .peak_event_queue_occupancy = metrics.peak_event_queue_occupancy,
        .queue_rejections = metrics.queue_rejections,
        .persistence_snapshots = metrics.persistence_snapshots,
        .active_persistence_min_bytes = metrics.active_persistence_min_bytes,
        .active_persistence_max_bytes = metrics.active_persistence_max_bytes,
        .dormant_persistence_min_bytes = metrics.dormant_persistence_min_bytes,
        .dormant_persistence_max_bytes = metrics.dormant_persistence_max_bytes,
        .persistence_bytes_total = metrics.persistence_bytes_total,
        .final_entities = final.entity_count,
        .final_bodies = final.body_count,
        .final_active_bodies = final.active_body_count,
        .final_command_queue_occupancy = final_command_occupancy,
        .final_outcome_queue_occupancy = final_outcome_occupancy,
        .final_event_queue_occupancy = final_event_occupancy,
    };

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    try std.json.Stringify.value(report, .{ .whitespace = .indent_2 }, stdout);
    try stdout.writeByte('\n');
    try stdout.flush();
}

const Identities = struct {
    character: sandbox_contracts.PersistentId,
    carryable: sandbox_contracts.PersistentId,
};

fn spawnActors(world: *simulation.Simulation, metrics: *Metrics) !Identities {
    try submitCharacter(world, metrics, .{ .spawn = .{
        .request_id = 3,
        .position = .{ west_x, 0, route_z },
    } });
    try submitInteraction(world, metrics, .{ .spawn = .{
        .request_id = 4,
        .pose = .{ .position = .{ west_x, 0.75, route_z } },
    } });
    try tick(world, metrics);
    const character = switch (world.pollCharacterOutcome() orelse
        return error.CharacterSpawnOutcomeMissing) {
        .spawned => |value| value.id,
        else => return error.UnexpectedCharacterOutcome,
    };
    metrics.outcomes_observed += 1;
    const carryable = switch (world.pollInteractionOutcome() orelse
        return error.InteractionSpawnOutcomeMissing) {
        .spawned => |value| value.id,
        else => return error.UnexpectedInteractionOutcome,
    };
    metrics.outcomes_observed += 1;
    try drainAmbient(world, metrics);
    return .{ .character = character, .carryable = carryable };
}

fn activateDistrict(
    world: *simulation.Simulation,
    metrics: *Metrics,
    request_id: u64,
    coord: sandbox_contracts.ChunkCoord,
) !sandbox_contracts.LoadTicket {
    try submitDistrict(world, metrics, .{ .request_load = .{
        .request_id = request_id,
        .coord = coord,
        .assets = district_assets,
    } });
    try tick(world, metrics);
    const ticket = switch (world.pollDistrictOutcome() orelse
        return error.DistrictRequestOutcomeMissing) {
        .load_requested => |value| value.ticket,
        else => return error.UnexpectedDistrictOutcome,
    };
    metrics.outcomes_observed += 1;
    try drainAmbient(world, metrics);

    for (0..worker_progress_limit) |_| {
        std.Thread.yield() catch {};
        try tick(world, metrics);
        var activated = false;
        while (world.pollDistrictOutcome()) |outcome| {
            metrics.outcomes_observed += 1;
            switch (outcome) {
                .activated => |value| {
                    if (!sandbox_contracts.LoadTicket.eql(ticket, value.ticket)) {
                        return error.UnexpectedDistrictTicket;
                    }
                    activated = true;
                },
                .load_failed => return error.DistrictLoadFailed,
                .cancelled => return error.DistrictLoadCancelled,
                else => return error.UnexpectedDistrictOutcome,
            }
        }
        try drainAmbient(world, metrics);
        if (activated) return ticket;
    }
    return error.DistrictWorkerDidNotComplete;
}

fn cancelDistrictLoad(
    world: *simulation.Simulation,
    metrics: *Metrics,
    request_id: u64,
    cancel_request_id: u64,
    coord: sandbox_contracts.ChunkCoord,
) !void {
    try submitDistrict(world, metrics, .{ .request_load = .{
        .request_id = request_id,
        .coord = coord,
        .assets = district_assets,
    } });
    try tick(world, metrics);
    const ticket = switch (world.pollDistrictOutcome() orelse
        return error.DistrictRequestOutcomeMissing) {
        .load_requested => |value| value.ticket,
        else => return error.UnexpectedDistrictOutcome,
    };
    metrics.outcomes_observed += 1;
    try drainAmbient(world, metrics);

    try submitDistrict(world, metrics, .{ .cancel_load = .{
        .request_id = cancel_request_id,
        .ticket = ticket,
    } });
    var cancellation_requested = false;
    var cancelled = false;
    for (0..worker_progress_limit) |_| {
        std.Thread.yield() catch {};
        try tick(world, metrics);
        while (world.pollDistrictOutcome()) |outcome| {
            metrics.outcomes_observed += 1;
            switch (outcome) {
                .cancellation_requested => |value| {
                    if (!sandbox_contracts.LoadTicket.eql(ticket, value.ticket)) {
                        return error.UnexpectedDistrictTicket;
                    }
                    cancellation_requested = true;
                },
                .cancelled => |value| {
                    if (!sandbox_contracts.LoadTicket.eql(ticket, value.ticket)) {
                        return error.UnexpectedDistrictTicket;
                    }
                    cancelled = true;
                },
                else => return error.UnexpectedDistrictOutcome,
            }
        }
        try drainAmbient(world, metrics);
        if (cancelled) {
            if (!cancellation_requested) return error.CancellationOutcomeMissing;
            return;
        }
    }
    return error.DistrictWorkerDidNotCancel;
}

fn unloadDistrict(
    world: *simulation.Simulation,
    metrics: *Metrics,
    request_id: u64,
    ticket: sandbox_contracts.LoadTicket,
) !void {
    try submitDistrict(world, metrics, .{ .unload = .{
        .request_id = request_id,
        .ticket = ticket,
    } });
    try tick(world, metrics);
    const outcome = world.pollDistrictOutcome() orelse
        return error.DistrictUnloadOutcomeMissing;
    metrics.outcomes_observed += 1;
    switch (outcome) {
        .unloaded => |value| if (!sandbox_contracts.LoadTicket.eql(ticket, value.ticket)) {
            return error.UnexpectedDistrictTicket;
        },
        else => return error.UnexpectedDistrictOutcome,
    }
    try drainAmbient(world, metrics);
}

fn collect(
    world: *simulation.Simulation,
    metrics: *Metrics,
    transaction_id: u64,
    character_id: sandbox_contracts.PersistentId,
    carryable_id: sandbox_contracts.PersistentId,
    previous_owner: sandbox_contracts.ChunkCoord,
) !void {
    try submitInteraction(world, metrics, .{ .collect = .{
        .transaction_id = transaction_id,
        .carrier_id = character_id,
        .carryable_id = carryable_id,
    } });
    try tick(world, metrics);
    const outcome = world.pollInteractionOutcome() orelse
        return error.InteractionOutcomeMissing;
    metrics.outcomes_observed += 1;
    switch (outcome) {
        .collected => |value| {
            if (value.transaction_id != transaction_id or
                !std.meta.eql(value.carrier_id, character_id) or
                !std.meta.eql(value.carryable_id, carryable_id) or
                !sandbox_contracts.ChunkCoord.eql(value.previous_owner, previous_owner))
            {
                return error.CollectOutcomeMismatch;
            }
        },
        else => return error.UnexpectedInteractionOutcome,
    }
    try drainAmbient(world, metrics);
    try requireHeld(world, character_id, carryable_id);
}

fn drop(
    world: *simulation.Simulation,
    metrics: *Metrics,
    transaction_id: u64,
    character_id: sandbox_contracts.PersistentId,
    carryable_id: sandbox_contracts.PersistentId,
    owner: sandbox_contracts.ChunkCoord,
) !void {
    try submitInteraction(world, metrics, .{ .drop = .{
        .transaction_id = transaction_id,
        .carrier_id = character_id,
        .carryable_id = carryable_id,
        .purpose = .player_requested,
    } });
    try tick(world, metrics);
    const outcome = world.pollInteractionOutcome() orelse
        return error.InteractionOutcomeMissing;
    metrics.outcomes_observed += 1;
    switch (outcome) {
        .dropped => |value| {
            if (value.transaction_id != transaction_id or
                !std.meta.eql(value.carrier_id, character_id) or
                !std.meta.eql(value.carryable_id, carryable_id) or
                !sandbox_contracts.ChunkCoord.eql(value.owner, owner))
            {
                return error.DropOutcomeMismatch;
            }
        },
        else => return error.UnexpectedInteractionOutcome,
    }
    try drainAmbient(world, metrics);
    const view = try world.carryable(carryable_id);
    if (!view.body_present or !std.meta.eql(view.ownership, .{
        .district_owned = owner,
    })) return error.DropOwnershipMismatch;
}

fn moveCharacter(
    world: *simulation.Simulation,
    metrics: *Metrics,
    character_id: sandbox_contracts.PersistentId,
    target_x: f32,
) !void {
    for (0..256) |_| {
        const current = try world.character(character_id);
        const delta = target_x - current.position[0];
        if (@abs(delta) <= 0.05) break;
        try submitCharacter(world, metrics, .{ .actions = .{
            .id = character_id,
            .move = .{ if (delta > 0) 1 else -1, 0 },
            .facing_yaw = 0,
        } });
        try tick(world, metrics);
        try drainAmbient(world, metrics);
    } else return error.CharacterDidNotReachDestination;

    try submitCharacter(world, metrics, .{ .actions = .{
        .id = character_id,
        .move = .{ 0, 0 },
        .facing_yaw = 0,
    } });
    try tick(world, metrics);
    try drainAmbient(world, metrics);
    if (@abs((try world.character(character_id)).position[0] - target_x) > 0.11) {
        return error.CharacterTargetMismatch;
    }
}

fn recordCanonicalPersistence(
    allocator: std.mem.Allocator,
    world: *simulation.Simulation,
    metrics: *Metrics,
    dormant: bool,
) !void {
    const first = try world.save(allocator);
    defer allocator.free(first);
    const second = try world.save(allocator);
    defer allocator.free(second);
    if (!std.mem.eql(u8, first, second)) return error.NonCanonicalPersistence;
    try metrics.recordPersistence(dormant, first.len);
    try metrics.recordPersistence(dormant, second.len);
}

fn cleanup(
    world: *simulation.Simulation,
    metrics: *Metrics,
    request_id: u64,
    character_id: sandbox_contracts.PersistentId,
    carryable_id: sandbox_contracts.PersistentId,
    district_ticket: sandbox_contracts.LoadTicket,
) !void {
    try submitCharacter(world, metrics, .{ .despawn = .{ .id = character_id } });
    try submitInteraction(world, metrics, .{ .despawn = .{ .id = carryable_id } });
    try tick(world, metrics);
    switch (world.pollCharacterOutcome() orelse
        return error.CharacterDespawnOutcomeMissing) {
        .despawned => |id| if (!std.meta.eql(id, character_id)) {
            return error.CharacterDespawnMismatch;
        },
        else => return error.UnexpectedCharacterOutcome,
    }
    metrics.outcomes_observed += 1;
    switch (world.pollInteractionOutcome() orelse
        return error.InteractionDespawnOutcomeMissing) {
        .despawned => |id| if (!std.meta.eql(id, carryable_id)) {
            return error.InteractionDespawnMismatch;
        },
        else => return error.UnexpectedInteractionOutcome,
    }
    metrics.outcomes_observed += 1;
    try drainAmbient(world, metrics);
    try unloadDistrict(world, metrics, request_id, district_ticket);
    try requireCounts(world, 0, 0, 1);
}

fn requireHeld(
    world: *simulation.Simulation,
    character_id: sandbox_contracts.PersistentId,
    carryable_id: sandbox_contracts.PersistentId,
) !void {
    const view = try world.carryable(carryable_id);
    if (view.body_present or !std.meta.eql(view.ownership, .{
        .inventory_held = character_id,
    })) return error.HeldOwnershipMismatch;
}

fn requireCounts(
    world: *simulation.Simulation,
    entities: usize,
    districts: usize,
    bodies: u32,
) !void {
    if (world.entityCount() != entities or world.districtCount() != districts or
        world.bodyCount() != bodies)
    {
        return error.LifecycleCountMismatch;
    }
}

fn submitCharacter(
    world: *simulation.Simulation,
    metrics: *Metrics,
    command: character_contract.Command,
) !void {
    try world.submitCharacter(command);
    metrics.commands_submitted += 1;
    metrics.observe(world);
}

fn submitInteraction(
    world: *simulation.Simulation,
    metrics: *Metrics,
    command: interaction_contract.Command,
) !void {
    try world.submitInteraction(command);
    metrics.commands_submitted += 1;
    metrics.observe(world);
}

fn submitDistrict(
    world: *simulation.Simulation,
    metrics: *Metrics,
    command: district_feature_contract.Command,
) !void {
    try world.submitDistrict(command);
    metrics.commands_submitted += 1;
    metrics.observe(world);
}

fn tick(world: *simulation.Simulation, metrics: *Metrics) !void {
    try world.tick();
    metrics.observe(world);
}

fn drainAmbient(world: *simulation.Simulation, metrics: *Metrics) !void {
    while (world.pollCharacterEvent() != null) metrics.events_observed += 1;
    while (world.pollVehicleEvent() != null) metrics.events_observed += 1;
    while (world.pollDistrictEvent() != null) metrics.events_observed += 1;
    if (world.pollOutcome() != null or world.pollCharacterOutcome() != null or
        world.pollVehicleOutcome() != null or world.pollDistrictOutcome() != null or
        world.pollInteractionOutcome() != null)
    {
        return error.UnexpectedOutput;
    }
    metrics.observe(world);
}

fn commandOccupancy(value: sandbox_diagnostics.Diagnostics) u64 {
    return queueOccupancy(&.{
        value.crates.commands,
        value.characters.commands,
        value.vehicles.commands,
        value.district.commands,
        value.interaction.commands,
    });
}

fn outcomeOccupancy(value: sandbox_diagnostics.Diagnostics) u64 {
    return queueOccupancy(&.{
        value.crates.outcomes,
        value.characters.outcomes,
        value.vehicles.outcomes,
        value.district.outcomes,
        value.interaction.outcomes,
    });
}

fn eventOccupancy(value: sandbox_diagnostics.Diagnostics) u64 {
    return queueOccupancy(&.{
        value.characters.events,
        value.vehicles.events,
        value.district.events,
    });
}

fn queueOccupancy(values: []const @TypeOf(
    @as(sandbox_diagnostics.Diagnostics, undefined).crates.commands,
)) u64 {
    var total: u64 = 0;
    for (values) |value| total += value.occupancy;
    return total;
}

fn queueRejections(value: sandbox_diagnostics.Diagnostics) u64 {
    var total: u64 = 0;
    for ([_]@TypeOf(value.crates.commands){
        value.crates.commands,
        value.crates.outcomes,
        value.characters.commands,
        value.characters.outcomes,
        value.characters.events,
        value.vehicles.commands,
        value.vehicles.outcomes,
        value.vehicles.events,
        value.district.commands,
        value.district.outcomes,
        value.district.events,
        value.interaction.commands,
        value.interaction.outcomes,
    }) |queue| total += queue.rejected;
    return total;
}

fn parseArgs(init: std.process.Init) !?Config {
    var config = Config{};
    var args = try std.process.Args.Iterator.initAllocator(
        init.minimal.args,
        init.gpa,
    );
    defer args.deinit();
    _ = args.next() orelse return error.MissingExecutableName;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help")) {
            std.debug.print("usage: s7_measure [--cycles=N]\n", .{});
            return null;
        }
        if (std.mem.startsWith(u8, arg, "--cycles=")) {
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
    if (config.cycles == 0) return error.CyclesMustBePositive;
    if (config.cycles > max_cycles) return error.MeasurementWorkloadTooLarge;
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

test "S7 measurement defaults to the declared 128-cycle bounded workload" {
    try validateConfig(.{});
    try std.testing.expectEqual(@as(usize, 128), (Config{}).cycles);
    try std.testing.expectError(error.CyclesMustBePositive, validateConfig(.{
        .cycles = 0,
    }));
    try std.testing.expectError(
        error.MeasurementWorkloadTooLarge,
        validateConfig(.{ .cycles = max_cycles + 1 }),
    );
}

test "S7 measurement distributions use nearest-rank percentiles" {
    var samples = [_]u64{ 5, 1, 4, 2, 3 };
    const distribution = summarize(&samples);
    try std.testing.expectEqual(@as(u64, 3), distribution.p50_ns);
    try std.testing.expectEqual(@as(u64, 5), distribution.p95_ns);
    try std.testing.expectEqual(@as(u64, 5), distribution.p99_ns);
}
