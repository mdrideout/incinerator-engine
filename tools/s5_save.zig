//! SDL/editor/GPU-free S5 durable authoring and restart verifier.

const std = @import("std");
const authoring = @import("sandbox_authoring");
const content = @import("content");
const district_content_catalog = @import("district_content_catalog");
const engine = @import("incinerator_engine");
const replay = @import("sandbox_replay");
const save = @import("sandbox_save");
const slots = @import("save_slots");
const sandbox = @import("sandbox_simulation");
const simulation_snapshot = @import("simulation_snapshot");
const crate_contract = @import("crate_contract");
const npc_contract = @import("npc_contract");
const sandbox_contracts = @import("sandbox_host_contracts");

const fixture_coord = sandbox_contracts.ChunkCoord{ .x = 0, .z = 0 };
const smoke_slot_id = "s5-smoke";
const smoke_boundary_slot_id = "s8-npc-waiting";
const smoke_dormant_slot_id = "s7-dormant";
const app_slot_id = "sandbox";
const smoke_namespace: u64 = 0x5335_5341_5645;
const smoke_target_pose = engine.physics.Pose{
    .position = .{ 6, 3, -2 },
    .rotation = .{ 0, 0.70710677, 0, 0.70710677 },
};
const app_target_pose = engine.physics.Pose{
    .position = .{ 6, 5, -2 },
    .rotation = .{ 0, 0, 0, 1 },
};

const NpcEvidence = struct {
    id: ?sandbox_contracts.PersistentId = null,
    spawned: bool = false,
    goal_set: bool = false,
    became_waiting: bool = false,
    resumed_active: bool = false,
    became_dormant: bool = false,
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

    if (std.mem.eql(u8, args[1], "write-smoke")) {
        try writeSmoke(init, args[2], args[3]);
    } else if (std.mem.eql(u8, args[1], "verify-smoke")) {
        try verifySmoke(init, args[2], args[3]);
    } else if (std.mem.eql(u8, args[1], "verify-authoring-smoke")) {
        try verifyAuthoringSmoke(init, args[2], args[3]);
    } else {
        printUsage();
        return error.UnknownCommand;
    }
}

fn printUsage() void {
    std.debug.print(
        \\usage:
        \\  incinerator_save write-smoke  <absolute-save-root> <installed-content-root>
        \\  incinerator_save verify-smoke <absolute-save-root> <installed-content-root>
        \\  incinerator_save verify-authoring-smoke <absolute-save-root> <installed-content-root>
        \\
    , .{});
}

fn smokeConfig() sandbox_contracts.Config {
    return .{
        .namespace = smoke_namespace,
        .max_crates = 8,
        .interaction = .{ .drop_offset = .{ 0, 0.75, 0 } },
        .npc = .{ .move_speed = 12 },
    };
}

fn appAuthoringConfig() sandbox_contracts.Config {
    return .{
        .namespace = 1,
        .block = .{
            .position = .{ 0, 1, -5 },
            .half_extents = .{ 2, 1, 0.5 },
        },
    };
}

fn metadataFor(
    content_cohort: replay.ContentCohort,
    config: sandbox_contracts.Config,
) !save.Metadata {
    return .{
        .payload_schema = sandbox_contracts.snapshot_schema,
        .simulation_build_digest = try simulation_snapshot.currentSimulationBuildFingerprint(),
        .world_config_digest = try simulation_snapshot.worldConfigFingerprint(config),
        .content_digest = try content_cohort.fingerprint(),
    };
}

fn writeSmoke(init: std.process.Init, raw_save_root: []const u8, raw_content_root: []const u8) !void {
    const content_cohort = try loadFixtureCohort(init, raw_content_root);
    const metadata = try metadataFor(content_cohort, smokeConfig());
    const slot = try slots.SlotId.parse(smoke_slot_id);
    const boundary_slot = try slots.SlotId.parse(smoke_boundary_slot_id);
    const dormant_slot = try slots.SlotId.parse(smoke_dormant_slot_id);
    var store = try slots.SaveSlots.open(init.io, try slots.RootPath.parse(raw_save_root));
    defer store.deinit(init.io);
    try recoverSlot(init.io, &store, slot);
    try recoverSlot(init.io, &store, boundary_slot);
    try recoverSlot(init.io, &store, dormant_slot);

    var world = try sandbox.Simulation.init(init.gpa, smokeConfig());
    defer world.deinit();
    try world.submit(.{ .spawn = .{
        .request_id = 1,
        .pose = .{ .position = .{ 0, 2, 0 } },
        .velocity = .{ .linear = .{ 1, 0, 0 } },
    } });
    try world.tick();
    const id = switch (world.pollOutcome() orelse return error.MissingSpawnOutcome) {
        .spawned => |spawned| spawned.id,
        else => return error.UnexpectedCrateOutcome,
    };

    const west_ticket = try loadDistrict(init.io, &world, 10, .{ .x = 0, .z = 0 });
    var east_ticket = try loadDistrict(init.io, &world, 11, .{ .x = 1, .z = 0 });
    if (world.districtCount() != 2 or world.districtBodyCount() != 6) {
        return error.MultiDistrictSaveAuthorityMissing;
    }

    var authoring_transactions = authoring.TransactionSequencer{};
    var controller = authoring.DefaultController.init(&authoring_transactions);
    try controller.select(id);
    const initial = try world.crate(id);
    const edit = try controller.beginEdit(.{
        .id = id,
        .target_pose = smoke_target_pose,
        .velocity = .zero,
    }, initial.authoring_revision);
    try applyAuthoring(&world, &controller, edit);
    try applyAuthoring(&world, &controller, try controller.beginUndo());
    try applyAuthoring(&world, &controller, try controller.beginRedo());

    const final = try world.crate(id);
    if (!std.meta.eql(final.state.pose, smoke_target_pose) or
        !std.meta.eql(final.state.velocity, engine.physics.Velocity{}) or
        final.authoring_revision != 3)
    {
        return error.AuthoringScenarioMismatch;
    }

    try world.submitCharacter(.{ .spawn = .{
        .request_id = 20,
        .position = .{ 0, 0, 0 },
    } });
    try world.submitInteraction(.{ .spawn = .{
        .request_id = 21,
        .pose = .{ .position = .{ 0, 1.75, 0 } },
    } });
    try world.tick();
    const character_id = switch (world.pollCharacterOutcome() orelse
        return error.MissingCharacterSpawnOutcome) {
        .spawned => |spawned| spawned.id,
        else => return error.UnexpectedCharacterOutcome,
    };
    while (world.pollCharacterEvent() != null) {}
    const carryable_id = switch (world.pollInteractionOutcome() orelse
        return error.MissingCarryableSpawnOutcome) {
        .spawned => |spawned| blk: {
            if (!sandbox_contracts.ChunkCoord.eql(spawned.owner, fixture_coord)) {
                return error.UnexpectedCarryableOwner;
            }
            break :blk spawned.id;
        },
        else => return error.UnexpectedInteractionOutcome,
    };

    try world.submitInteraction(.{ .collect = .{
        .transaction_id = 22,
        .carrier_id = character_id,
        .carryable_id = carryable_id,
    } });
    try world.tick();
    switch (world.pollInteractionOutcome() orelse return error.MissingCollectOutcome) {
        .collected => |collected| {
            if (!std.meta.eql(collected.carrier_id, character_id) or
                !std.meta.eql(collected.carryable_id, carryable_id) or
                !sandbox_contracts.ChunkCoord.eql(collected.previous_owner, fixture_coord))
            {
                return error.UnexpectedInteractionOutcome;
            }
        },
        else => return error.UnexpectedInteractionOutcome,
    }
    const held = try world.carryable(carryable_id);
    if (!std.meta.eql(held.ownership, .{ .inventory_held = character_id }) or
        held.body_present)
    {
        return error.HeldCarryableStateMismatch;
    }

    var npc_evidence = NpcEvidence{};
    try world.submitNpc(.{ .spawn = .{
        .request_id = 30,
        .node = .{ .coord = sandbox_contracts.navigation_west_coord, .index = 0 },
        .goal = .hold,
    } });
    try world.tick();
    try drainNpcOutputs(&world, &npc_evidence);
    const npc_id = npc_evidence.id orelse return error.MissingNpcSpawnOutcome;
    const active_npc = try world.npc(npc_id);
    if (!npc_evidence.spawned or
        active_npc.state != .active or
        !active_npc.controller_present or
        !sandbox_contracts.ChunkCoord.eql(active_npc.owner, sandbox_contracts.navigation_west_coord))
    {
        return error.ActiveNpcStateMismatch;
    }

    const pre_held_save = try world.crate(id);
    try applyAuthoring(&world, &controller, try controller.beginEdit(.{
        .id = id,
        .target_pose = smoke_target_pose,
        .velocity = .zero,
    }, pre_held_save.authoring_revision));

    const held_payload = try world.save(init.gpa);
    defer init.gpa.free(held_payload);
    const held_envelope = try save.encode(init.gpa, metadata, held_payload);
    defer init.gpa.free(held_envelope);
    try requireEnvelopeBudgets(held_payload, held_envelope);
    try commitSlot(init.io, &store, slot, held_envelope);

    try world.submitNpc(.{ .set_goal = .{
        .request_id = 31,
        .id = npc_id,
        .goal = .{ .navigate_to = .{
            .coord = sandbox_contracts.navigation_east_coord,
            .index = 2,
        } },
    } });
    try world.tick();
    try drainNpcOutputs(&world, &npc_evidence);
    if (!npc_evidence.goal_set) return error.MissingNpcGoalSetOutcome;

    try world.submitDistrict(.{ .unload = .{
        .request_id = 32,
        .ticket = east_ticket,
    } });
    try world.tick();
    switch (world.pollDistrictOutcome() orelse return error.MissingDistrictUnloadOutcome) {
        .unloaded => |unloaded| if (!sandbox_contracts.LoadTicket.eql(unloaded.ticket, east_ticket)) {
            return error.UnexpectedDistrictTicket;
        },
        else => return error.UnexpectedDistrictOutcome,
    }
    while (world.pollDistrictEvent() != null) {}
    try drainNpcOutputs(&world, &npc_evidence);
    for (0..300) |_| {
        if ((try world.npc(npc_id)).state == .waiting_at_boundary) break;
        try world.tick();
        try drainNpcOutputs(&world, &npc_evidence);
    }
    const waiting_npc = try world.npc(npc_id);
    if (!npc_evidence.became_waiting or
        waiting_npc.state != .waiting_at_boundary or
        !waiting_npc.controller_present or
        !sandbox_contracts.ChunkCoord.eql(waiting_npc.owner, sandbox_contracts.navigation_west_coord))
    {
        return error.WaitingNpcStateMismatch;
    }

    const pre_boundary_save = try world.crate(id);
    try applyAuthoring(&world, &controller, try controller.beginEdit(.{
        .id = id,
        .target_pose = smoke_target_pose,
        .velocity = .zero,
    }, pre_boundary_save.authoring_revision));

    const boundary_payload = try world.save(init.gpa);
    defer init.gpa.free(boundary_payload);
    const boundary_envelope = try save.encode(init.gpa, metadata, boundary_payload);
    defer init.gpa.free(boundary_envelope);
    try requireEnvelopeBudgets(boundary_payload, boundary_envelope);
    try commitSlot(init.io, &store, boundary_slot, boundary_envelope);

    east_ticket = try loadDistrict(
        init.io,
        &world,
        33,
        sandbox_contracts.navigation_east_coord,
    );
    try drainNpcOutputs(&world, &npc_evidence);
    const resumed_npc = try world.npc(npc_id);
    if (!npc_evidence.resumed_active or
        resumed_npc.state != .active or
        !resumed_npc.controller_present)
    {
        return error.ResumedNpcStateMismatch;
    }

    try world.submitInteraction(.{ .drop = .{
        .transaction_id = 23,
        .carrier_id = character_id,
        .carryable_id = carryable_id,
        .purpose = .player_requested,
    } });
    try world.tick();
    switch (world.pollInteractionOutcome() orelse return error.MissingDropOutcome) {
        .dropped => |dropped| if (!sandbox_contracts.ChunkCoord.eql(dropped.owner, fixture_coord)) {
            return error.UnexpectedCarryableOwner;
        },
        else => return error.UnexpectedInteractionOutcome,
    }
    try world.submitDistrict(.{ .unload = .{
        .request_id = 24,
        .ticket = west_ticket,
    } });
    try world.tick();
    switch (world.pollDistrictOutcome() orelse return error.MissingDistrictUnloadOutcome) {
        .unloaded => |unloaded| if (!sandbox_contracts.LoadTicket.eql(unloaded.ticket, west_ticket)) {
            return error.UnexpectedDistrictTicket;
        },
        else => return error.UnexpectedDistrictOutcome,
    }
    while (world.pollDistrictEvent() != null) {}
    try drainNpcOutputs(&world, &npc_evidence);
    const dormant_npc = try world.npc(npc_id);
    if (!npc_evidence.became_dormant or
        dormant_npc.state != .dormant or
        dormant_npc.controller_present or
        !sandbox_contracts.ChunkCoord.eql(dormant_npc.owner, sandbox_contracts.navigation_west_coord))
    {
        return error.DormantNpcStateMismatch;
    }
    const dormant = try world.carryable(carryable_id);
    if (!std.meta.eql(dormant.ownership, .{ .district_owned = fixture_coord }) or
        dormant.body_present)
    {
        return error.DormantCarryableStateMismatch;
    }

    const pre_dormant_save = try world.crate(id);
    try applyAuthoring(&world, &controller, try controller.beginEdit(.{
        .id = id,
        .target_pose = smoke_target_pose,
        .velocity = .zero,
    }, pre_dormant_save.authoring_revision));
    const dormant_final = try world.crate(id);

    const dormant_payload = try world.save(init.gpa);
    defer init.gpa.free(dormant_payload);
    const dormant_envelope = try save.encode(init.gpa, metadata, dormant_payload);
    defer init.gpa.free(dormant_envelope);
    try requireEnvelopeBudgets(dormant_payload, dormant_envelope);
    try commitSlot(init.io, &store, dormant_slot, dormant_envelope);
    std.debug.print(
        "S5_SAVE_WRITTEN id={d}:{d} character={d}:{d} carryable={d}:{d} " ++
            "npc={d}:{d} tick={d} held_payload={d} held_envelope={d} " ++
            "waiting_payload={d} waiting_envelope={d} dormant_payload={d} " ++
            "dormant_envelope={d} revision={d}\n",
        .{
            id.namespace,
            id.local,
            character_id.namespace,
            character_id.local,
            carryable_id.namespace,
            carryable_id.local,
            npc_id.namespace,
            npc_id.local,
            world.tickIndex(),
            held_payload.len,
            held_envelope.len,
            boundary_payload.len,
            boundary_envelope.len,
            dormant_payload.len,
            dormant_envelope.len,
            dormant_final.authoring_revision,
        },
    );
}

fn verifySmoke(init: std.process.Init, raw_save_root: []const u8, raw_content_root: []const u8) !void {
    const content_cohort = try loadFixtureCohort(init, raw_content_root);
    const metadata = try metadataFor(content_cohort, smokeConfig());
    const slot = try slots.SlotId.parse(smoke_slot_id);
    const boundary_slot = try slots.SlotId.parse(smoke_boundary_slot_id);
    const dormant_slot = try slots.SlotId.parse(smoke_dormant_slot_id);
    var store = try slots.SaveSlots.open(init.io, try slots.RootPath.parse(raw_save_root));
    defer store.deinit(init.io);
    const held = try verifySmokeOwnershipSlot(
        init,
        &store,
        slot,
        raw_content_root,
        metadata,
        .held_active,
    );
    const waiting = try verifySmokeOwnershipSlot(
        init,
        &store,
        boundary_slot,
        raw_content_root,
        metadata,
        .held_waiting,
    );
    const dormant = try verifySmokeOwnershipSlot(
        init,
        &store,
        dormant_slot,
        raw_content_root,
        metadata,
        .dormant,
    );

    std.debug.print(
        "S5_SAVE_VERIFIED id={d}:{d} held_tick={d} held_payload={d} " ++
            "held_envelope={d} waiting_tick={d} waiting_payload={d} " ++
            "waiting_envelope={d} dormant_tick={d} dormant_payload={d} " ++
            "dormant_envelope={d} canonical=true active_restart=true " ++
            "waiting_restart=true dormant_restart=true\n",
        .{
            smoke_namespace,
            1,
            held.tick,
            held.payload_bytes,
            held.envelope_bytes,
            waiting.tick,
            waiting.payload_bytes,
            waiting.envelope_bytes,
            dormant.tick,
            dormant.payload_bytes,
            dormant.envelope_bytes,
        },
    );
}

const SmokeOwnership = enum { held_active, held_waiting, dormant };

const SmokeVerification = struct {
    tick: u64,
    payload_bytes: usize,
    envelope_bytes: usize,
};

fn verifySmokeOwnershipSlot(
    init: std.process.Init,
    store: *slots.SaveSlots,
    slot: slots.SlotId,
    raw_content_root: []const u8,
    metadata: save.Metadata,
    expected: SmokeOwnership,
) !SmokeVerification {
    const loaded = try store.load(
        init.io,
        init.gpa,
        slot,
        .{ .max_file_bytes = save.max_envelope_bytes },
    );
    const envelope = switch (loaded) {
        .loaded => |bytes| bytes,
        .failed => |failure| {
            std.debug.print("committed save load failed: {any}\n", .{failure});
            return error.SaveLoadFailed;
        },
    };
    defer init.gpa.free(envelope);

    const view = try save.parseCompatible(envelope, metadata);
    try requireEnvelopeBudgets(view.payload, envelope);
    try preflightSnapshotCatalog(init, raw_content_root, view.payload, smokeConfig());
    try verifyCompactNpcSnapshot(init.gpa, view.payload, expected);
    if (expected == .held_active) try requireHostileNpcRestoreRejections(
        init.gpa,
        view.payload,
    );
    var world = try sandbox.Simulation.fromSnapshotForWorld(
        init.gpa,
        view.payload,
        smokeConfig(),
        .{},
    );
    defer world.deinit();

    const crate_id = sandbox_contracts.PersistentId{ .namespace = smoke_namespace, .local = 1 };
    const character_id = sandbox_contracts.PersistentId{ .namespace = smoke_namespace, .local = 4 };
    const carryable_id = sandbox_contracts.PersistentId{ .namespace = smoke_namespace, .local = 5 };
    const npc_id = sandbox_contracts.PersistentId{ .namespace = smoke_namespace, .local = 6 };
    const restored = try world.crate(crate_id);
    if (!std.meta.eql(restored.state.pose, smoke_target_pose) or
        !std.meta.eql(restored.state.velocity, engine.physics.Velocity{}) or
        restored.authoring_revision != 0)
    {
        return error.RestoredAuthoringStateMismatch;
    }
    _ = try world.character(character_id);
    const carryable = try world.carryable(carryable_id);
    const npc = try world.npc(npc_id);
    if (world.npcCount() != 1) return error.RestoredNpcCountMismatch;
    switch (expected) {
        .held_active => {
            if (!std.meta.eql(carryable.ownership, .{ .inventory_held = character_id }) or
                carryable.body_present or
                npc.state != .active or
                !npc.controller_present or
                world.districtCount() != 2 or
                world.districtBodyCount() != 6 or
                world.entityCount() != 6 or
                world.bodyCount() != 8)
            {
                return error.RestoredHeldInteractionStateMismatch;
            }
        },
        .held_waiting => {
            if (!std.meta.eql(carryable.ownership, .{ .inventory_held = character_id }) or
                carryable.body_present or
                npc.state != .waiting_at_boundary or
                !npc.controller_present or
                world.districtCount() != 1 or
                world.districtBodyCount() != 3 or
                world.entityCount() != 5 or
                world.bodyCount() != 5)
            {
                return error.RestoredWaitingNpcStateMismatch;
            }
        },
        .dormant => {
            if (!std.meta.eql(carryable.ownership, .{ .district_owned = fixture_coord }) or
                carryable.body_present or
                npc.state != .dormant or
                npc.controller_present or
                world.districtCount() != 1 or
                world.districtBodyCount() != 3 or
                world.entityCount() != 5 or
                world.bodyCount() != 5)
            {
                return error.RestoredDormantInteractionStateMismatch;
            }
        },
    }
    const expected_controller_count: u32 = if (expected == .dormant) 0 else 1;
    const npc_diagnostics = world.diagnostics().npc;
    const expected_active_count: u32 = if (expected == .held_active) 1 else 0;
    const expected_waiting_count: u32 = if (expected == .held_waiting) 1 else 0;
    const expected_dormant_count: u32 = if (expected == .dormant) 1 else 0;
    if (npc_diagnostics.active_count != expected_active_count or
        npc_diagnostics.waiting_count != expected_waiting_count or
        npc_diagnostics.dormant_count != expected_dormant_count or
        npc_diagnostics.controller_count != expected_controller_count or
        npc_diagnostics.commands.occupancy != 0 or
        npc_diagnostics.outcomes.occupancy != 0 or
        npc_diagnostics.events.occupancy != 0 or
        npc_diagnostics.event_drops.total() != 0)
    {
        return error.RestoredNpcControllerMismatch;
    }

    const canonical_payload = try world.save(init.gpa);
    defer init.gpa.free(canonical_payload);
    if (!std.mem.eql(u8, view.payload, canonical_payload)) {
        return error.NonCanonicalRestoredPayload;
    }
    const canonical_envelope = try save.encode(init.gpa, metadata, canonical_payload);
    defer init.gpa.free(canonical_envelope);
    if (!std.mem.eql(u8, envelope, canonical_envelope)) {
        return error.NonCanonicalRestoredEnvelope;
    }
    return .{
        .tick = world.tickIndex(),
        .payload_bytes = canonical_payload.len,
        .envelope_bytes = canonical_envelope.len,
    };
}

fn verifyAuthoringSmoke(
    init: std.process.Init,
    raw_save_root: []const u8,
    raw_content_root: []const u8,
) !void {
    const config = appAuthoringConfig();
    const content_cohort = try loadFixtureCohort(init, raw_content_root);
    const metadata = try metadataFor(content_cohort, config);
    const slot = try slots.SlotId.parse(app_slot_id);
    var store = try slots.SaveSlots.open(init.io, try slots.RootPath.parse(raw_save_root));
    defer store.deinit(init.io);
    const loaded = try store.load(
        init.io,
        init.gpa,
        slot,
        .{ .max_file_bytes = save.max_envelope_bytes },
    );
    const envelope = switch (loaded) {
        .loaded => |bytes| bytes,
        .failed => |failure| {
            std.debug.print("authoring smoke save load failed: {any}\n", .{failure});
            return error.SaveLoadFailed;
        },
    };
    defer init.gpa.free(envelope);

    const view = try save.parseCompatible(envelope, metadata);
    try preflightSnapshotCatalog(init, raw_content_root, view.payload, config);
    var world = try sandbox.Simulation.fromSnapshotForWorld(
        init.gpa,
        view.payload,
        config,
        .{},
    );
    defer world.deinit();
    const id = sandbox_contracts.PersistentId{ .namespace = 1, .local = 1 };
    const restored = try world.crate(id);
    // M6 captures durable state at stage seven of the next authoritative
    // cycle. The edited dynamic crate can therefore advance under physics
    // between the UI request and its durable disposition; preserve the edited
    // horizontal placement and orientation without pinning the verifier to an
    // obsolete synchronous tick or vertical pose.
    if (restored.state.pose.position[0] != app_target_pose.position[0] or
        restored.state.pose.position[2] != app_target_pose.position[2] or
        restored.state.pose.position[1] > app_target_pose.position[1] or
        !std.meta.eql(restored.state.pose.rotation, app_target_pose.rotation) or
        restored.authoring_revision != 0 or world.tickIndex() < 5 or
        world.crateCount() != 1 or world.characterCount() != 1 or
        world.vehicleCount() != 0 or world.entityCount() != 2)
    {
        return error.RestoredAppAuthoringStateMismatch;
    }

    const canonical_payload = try world.save(init.gpa);
    defer init.gpa.free(canonical_payload);
    if (!std.mem.eql(u8, view.payload, canonical_payload)) {
        return error.NonCanonicalRestoredPayload;
    }
    const canonical_envelope = try save.encode(init.gpa, metadata, canonical_payload);
    defer init.gpa.free(canonical_envelope);
    if (!std.mem.eql(u8, envelope, canonical_envelope)) {
        return error.NonCanonicalRestoredEnvelope;
    }

    std.debug.print(
        "S5_AUTHORING_SAVE_VERIFIED id={d}:{d} tick={d} payload={d} " ++
            "envelope={d} canonical=true editor_free=true\n",
        .{ id.namespace, id.local, world.tickIndex(), canonical_payload.len, envelope.len },
    );
}

fn drainNpcOutputs(world: *sandbox.Simulation, evidence: *NpcEvidence) !void {
    while (world.pollNpcOutcome()) |outcome| switch (outcome) {
        .spawned => |spawned| {
            if (spawned.request_id != 30 or
                evidence.id != null or
                !sandbox_contracts.ChunkCoord.eql(spawned.owner, sandbox_contracts.navigation_west_coord))
            {
                return error.UnexpectedNpcOutcome;
            }
            evidence.id = spawned.id;
            evidence.spawned = true;
        },
        .goal_set => |set| {
            const id = evidence.id orelse return error.UnexpectedNpcOutcome;
            const expected_goal = npc_contract.Goal{ .navigate_to = .{
                .coord = sandbox_contracts.navigation_east_coord,
                .index = 2,
            } };
            if (set.request_id != 31 or
                !std.meta.eql(set.id, id) or
                !std.meta.eql(set.goal, expected_goal) or
                evidence.goal_set)
            {
                return error.UnexpectedNpcOutcome;
            }
            evidence.goal_set = true;
        },
        .despawned, .rejected => return error.UnexpectedNpcOutcome,
    };
    while (world.pollNpcEvent()) |event| switch (event) {
        .state_changed => |changed| {
            const id = evidence.id orelse return error.UnexpectedNpcEvent;
            if (!std.meta.eql(changed.id, id)) return error.UnexpectedNpcEvent;
            if (changed.previous == .active and changed.current == .waiting_at_boundary) {
                if (evidence.became_waiting) return error.UnexpectedNpcEvent;
                evidence.became_waiting = true;
            } else if (changed.previous == .waiting_at_boundary and
                changed.current == .active)
            {
                if (evidence.resumed_active) return error.UnexpectedNpcEvent;
                evidence.resumed_active = true;
            } else if ((changed.previous == .active or
                changed.previous == .waiting_at_boundary) and
                changed.current == .dormant)
            {
                if (evidence.became_dormant) return error.UnexpectedNpcEvent;
                evidence.became_dormant = true;
            } else {
                return error.UnexpectedNpcEvent;
            }
        },
        .owner_transferred, .goal_reached => return error.UnexpectedNpcEvent,
    };

    const diagnostics = world.diagnostics().npc;
    if (diagnostics.commands.occupancy != 0 or
        diagnostics.outcomes.occupancy != 0 or
        diagnostics.events.occupancy != 0 or
        diagnostics.event_drops.total() != 0)
    {
        return error.NpcAuthorityOutputNotDrained;
    }
}

fn verifyCompactNpcSnapshot(
    allocator: std.mem.Allocator,
    payload: []const u8,
    expected: SmokeOwnership,
) !void {
    var parsed = try simulation_snapshot.parse(
        allocator,
        payload,
        smokeConfig().max_crates,
        smokeConfig().character.max_characters,
        smokeConfig().vehicle.max_vehicles,
        replay.max_world_npcs,
    );
    defer parsed.deinit();
    if (parsed.value.schema_version != sandbox_contracts.snapshot_schema or
        parsed.value.npcs.len != 1 or
        std.mem.indexOf(u8, payload, "controller_present") != null or
        std.mem.indexOf(u8, payload, "owner_ticket") != null)
    {
        return error.NonCompactNpcSnapshot;
    }
    const record = parsed.value.npcs[0];
    if (!std.meta.eql(
        record.id,
        sandbox_contracts.PersistentId{ .namespace = smoke_namespace, .local = 6 },
    ) or
        !sandbox_contracts.ChunkCoord.eql(record.owner, sandbox_contracts.navigation_west_coord) or
        record.route.route_index != 0 or
        record.route.mode != .exact_prefix or
        !sandbox_contracts.ChunkCoord.eql(record.route.current.coord, sandbox_contracts.navigation_west_coord))
    {
        return error.UnexpectedNpcSnapshotRecord;
    }
    switch (expected) {
        .held_active => {
            if (record.goal != .hold or
                record.route.current.index != 0 or
                record.route.next != null)
            {
                return error.UnexpectedNpcSnapshotRecord;
            }
        },
        .held_waiting, .dormant => {
            const target = switch (record.goal) {
                .navigate_to => |value| value,
                else => return error.UnexpectedNpcSnapshotRecord,
            };
            const next = record.route.next orelse return error.UnexpectedNpcSnapshotRecord;
            if (!sandbox_contracts.ChunkCoord.eql(target.coord, sandbox_contracts.navigation_east_coord) or
                target.index != 2 or
                !sandbox_contracts.ChunkCoord.eql(next.coord, sandbox_contracts.navigation_east_coord) or
                next.index != 0)
            {
                return error.UnexpectedNpcSnapshotRecord;
            }
        },
    }
}

fn requireHostileNpcRestoreRejections(
    allocator: std.mem.Allocator,
    payload: []const u8,
) !void {
    if (sandbox.Simulation.fromSnapshot(allocator, payload, .{
        .max_crates = smokeConfig().max_crates,
        .character = .{ .max_characters = smokeConfig().character.max_characters },
        .vehicle = .{ .max_vehicles = smokeConfig().vehicle.max_vehicles },
        .npc = .{ .max_npcs = replay.max_world_npcs - 1 },
    })) |unexpected| {
        var world = unexpected;
        world.deinit();
        return error.InvalidNpcCapacityWasAccepted;
    } else |err| {
        if (err != error.InvalidNpcLimit) return err;
    }

    var parsed = try simulation_snapshot.parse(
        allocator,
        payload,
        smokeConfig().max_crates,
        smokeConfig().character.max_characters,
        smokeConfig().vehicle.max_vehicles,
        replay.max_world_npcs,
    );
    defer parsed.deinit();
    if (parsed.value.npcs.len != 1) return error.UnexpectedNpcSnapshotRecord;
    var hostile_records = [1]npc_contract.NpcV1{parsed.value.npcs[0]};
    hostile_records[0].route.route_index = 1;
    var hostile_snapshot = parsed.value;
    hostile_snapshot.npcs = &hostile_records;
    const hostile_payload = try std.json.Stringify.valueAlloc(
        allocator,
        hostile_snapshot,
        .{},
    );
    defer allocator.free(hostile_payload);
    if (sandbox.Simulation.fromSnapshotForWorld(
        allocator,
        hostile_payload,
        smokeConfig(),
        .{},
    )) |unexpected| {
        var world = unexpected;
        world.deinit();
        return error.HostileNpcSnapshotWasAccepted;
    } else |err| {
        if (err != error.NonCanonicalNpcRouteIndex) return err;
    }

    hostile_records[0].route.route_index = 0;
    hostile_records[0].route.mode = .deferred_rebuild;
    const hostile_mode_payload = try std.json.Stringify.valueAlloc(
        allocator,
        hostile_snapshot,
        .{},
    );
    defer allocator.free(hostile_mode_payload);
    if (sandbox.Simulation.fromSnapshotForWorld(
        allocator,
        hostile_mode_payload,
        smokeConfig(),
        .{},
    )) |unexpected| {
        var world = unexpected;
        world.deinit();
        return error.HostileNpcSnapshotWasAccepted;
    } else |err| {
        if (err != error.NpcHoldCursorMismatch) return err;
    }
}

fn requireEnvelopeBudgets(payload: []const u8, envelope: []const u8) !void {
    if (payload.len > simulation_snapshot.max_bytes) return error.SnapshotTooLarge;
    if (envelope.len > save.max_envelope_bytes) return error.SaveEnvelopeTooLarge;
}

fn applyAuthoring(
    world: *sandbox.Simulation,
    controller: *authoring.DefaultController,
    command: crate_contract.Command,
) !void {
    world.submit(command) catch |err| {
        _ = controller.submissionFailed(command.relocate.transaction_id);
        return err;
    };
    try world.tick();
    const outcome = world.pollOutcome() orelse return error.MissingAuthoringOutcome;
    if ((try controller.observe(outcome)) != .applied) {
        return error.AuthoringOperationRejected;
    }
}

fn loadDistrict(
    io: std.Io,
    world: *sandbox.Simulation,
    request_id: u64,
    coord: sandbox_contracts.ChunkCoord,
) !sandbox_contracts.LoadTicket {
    try world.submitDistrict(.{ .request_load = .{
        .request_id = request_id,
        .coord = coord,
        .assets = .{},
    } });
    try world.tick();
    const ticket = switch (world.pollDistrictOutcome() orelse
        return error.MissingDistrictLoadOutcome) {
        .load_requested => |requested| requested.ticket,
        else => return error.UnexpectedDistrictOutcome,
    };
    while (world.pollDistrictEvent() != null) {}
    for (0..2_000) |_| {
        try io.sleep(.fromMilliseconds(1), .awake);
        try world.tick();
        while (world.pollDistrictOutcome()) |outcome| switch (outcome) {
            .activated => |activated| {
                if (!sandbox_contracts.LoadTicket.eql(ticket, activated.ticket)) {
                    return error.UnexpectedDistrictTicket;
                }
                while (world.pollDistrictEvent() != null) {}
                return ticket;
            },
            .load_failed => return error.DistrictLoadFailed,
            else => return error.UnexpectedDistrictOutcome,
        };
        while (world.pollDistrictEvent() != null) {}
    }
    return error.DistrictWorkerDidNotComplete;
}

fn preflightSnapshotCatalog(
    init: std.process.Init,
    raw_content_root: []const u8,
    payload: []const u8,
    config: sandbox_contracts.Config,
) !void {
    var parsed = try simulation_snapshot.parse(
        init.gpa,
        payload,
        config.max_crates,
        config.character.max_characters,
        config.vehicle.max_vehicles,
        replay.max_world_npcs,
    );
    defer parsed.deinit();
    var admission = switch (try district_content_catalog.admit(
        init.io,
        init.gpa,
        try content.ContentRootPath.parse(raw_content_root),
    )) {
        .admitted => |value| value,
        .failed => return error.InstalledContentAdmissionFailed,
    };
    defer admission.deinit();
    try admission.validateLogicalRecords(parsed.value.districts);
    for (parsed.value.interactions) |record| switch (record.ownership) {
        .district_owned => |coord| if (admission.entryForCoordinate(coord) == null) {
            return error.InteractionDistrictCoordinateNotInCatalog;
        },
        .inventory_held => {},
    };
    for (parsed.value.npcs) |record| {
        if (admission.entryForCoordinate(record.owner) == null or
            admission.entryForCoordinate(record.route.current.coord) == null or
            (record.route.next != null and
                admission.entryForCoordinate(record.route.next.?.coord) == null))
        {
            return error.NpcDistrictCoordinateNotInCatalog;
        }
        switch (record.goal) {
            .hold => {},
            .navigate_to => |target| if (admission.entryForCoordinate(target.coord) == null) {
                return error.NpcDistrictCoordinateNotInCatalog;
            },
            .patrol_between => |patrol| if (admission.entryForCoordinate(patrol.first.coord) == null or
                admission.entryForCoordinate(patrol.second.coord) == null)
            {
                return error.NpcDistrictCoordinateNotInCatalog;
            },
        }
    }
}

fn recoverSlot(io: std.Io, store: *slots.SaveSlots, slot: slots.SlotId) !void {
    switch (store.recover(io, slot)) {
        .clean, .discarded_stale_candidate => {},
        .failed => |failure| {
            std.debug.print("save candidate recovery failed: {any}\n", .{failure});
            return error.SaveRecoveryFailed;
        },
    }
}

fn commitSlot(
    io: std.Io,
    store: *slots.SaveSlots,
    slot: slots.SlotId,
    envelope: []const u8,
) !void {
    switch (store.commit(io, slot, envelope, .{ .max_file_bytes = save.max_envelope_bytes })) {
        .committed => {},
        .committed_sync_warning => |warning| {
            std.debug.print("save committed with sync warning: {any}\n", .{warning});
            return error.SaveDirectorySyncUncertain;
        },
        .not_committed => |failure| {
            std.debug.print("save was not committed: {any}\n", .{failure});
            return error.SaveCommitFailed;
        },
    }
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
