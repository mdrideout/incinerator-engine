//! Canonical logical snapshot and compatibility contract for the sandbox world.
//!
//! This module owns durable snapshot values, canonical JSON encoding, cold
//! preflight, and the exact build/world fingerprints bound into save and replay
//! envelopes. It owns no Runtime, Flecs world, Jolt object, feature instance,
//! storage adapter, or mutable authority state.

const std = @import("std");
const engine = @import("engine_contracts");
const crates = @import("crate_contract");
const characters = @import("character_contract");
const vehicles = @import("vehicle_contract");
const districts = @import("district_feature_contract");
const district_contract = @import("district_contract");
const interactions = @import("interaction_feature_contract");
const npcs = @import("npc_contract");
const vitals = @import("vitals_contract");
const npc_encounters = @import("npc_encounter_contract");
const population = @import("population_contract");
const population_catalog = @import("sandbox_population_catalog");
const sandbox_district_recipe = @import("sandbox_district_recipe");
const sandbox_navigation = @import("sandbox_navigation");
const sandbox_replay = @import("sandbox_replay");
const sandbox_host_contracts = @import("sandbox_host_contracts");
const simulation_cohort_options = @import("simulation_cohort_options");
const npc_snapshot_validation = @import("npc_snapshot_validation");

pub const schema_version = sandbox_host_contracts.snapshot_schema;
pub const max_bytes: usize = 8 * 1024 * 1024;
pub const NpcEncounterConfigV1 = npc_encounters.ConfigV1;
pub const initial_navigation_gates = sandbox_navigation.initial_gate_state;

pub const Limits = struct {
    max_crates: usize = 1024,
    max_characters: usize = 1,
    max_vehicles: usize = 1,
    max_npcs: usize = npcs.max_npcs,
};

pub const SnapshotV14 = struct {
    schema_version: u16,
    completed_ticks: u64,
    fixed_delta_seconds: f32,
    namespace: u64,
    next_local_id: u64,
    character_config: characters.CharacterConfigV1,
    vehicle_config: vehicles.VehicleConfigV1,
    interaction_config: interactions.InteractionConfigV1,
    npc_config: npcs.NpcConfigV1,
    npc_encounter_config: npc_encounters.ConfigV1,
    authored_population: bool,
    navigation_gates: sandbox_navigation.GateState,
    crates: []const crates.CrateV1,
    characters: []const characters.CharacterV1,
    vehicles: []const vehicles.VehicleV1,
    districts: []const districts.DistrictV1,
    interactions: []const interactions.InteractionV1,
    npcs: []const npcs.NpcV1,
    vitals: []const vitals.VitalsV1 = &.{},
    npc_encounters: []const npc_encounters.RecordV1,
    population: ?population.SnapshotV1,
};

pub const CharacterRestoreOptions = struct {
    max_characters: usize = 1,
    assets: characters.Assets = .{},
};

pub const VehicleRestoreOptions = struct {
    max_vehicles: usize = 1,
    assets: vehicles.Assets = .{},
};

pub const NpcRestoreOptions = struct {
    /// The current authority admits one exact bounded NPC cohort. Host-provided
    /// capacities are rejected before native authority is acquired.
    max_npcs: usize = npcs.max_npcs,
    assets: npcs.Assets = .{},
};

pub const RestoreConfig = struct {
    max_crates: usize = 1024,
    assets: crates.Assets = .{},
    create_ground: bool = true,
    character: CharacterRestoreOptions = .{},
    vehicle: VehicleRestoreOptions = .{},
    npc: NpcRestoreOptions = .{},
    district_assets: districts.Assets = .{},
    block: ?sandbox_host_contracts.StaticBox = null,
};

/// Exact cold construction identity shared by replay and durable-save
/// admission. Presentation assets are deliberately stripped by `WorldConfig`.
pub fn worldConfig(config: sandbox_host_contracts.Config) !sandbox_replay.WorldConfig {
    return sandbox_replay.WorldConfig.fromFeatureConfigs(
        config.namespace,
        config.fixed_delta_seconds,
        config.max_crates,
        config.character,
        config.vehicle,
        config.interaction,
        config.npc,
        config.npc_encounter,
        config.create_ground,
        config.authored_population,
        if (config.block) |block| .{
            .position = block.position,
            .half_extents = block.half_extents,
        } else null,
    );
}

pub fn currentSimulationBuildFingerprint() !sandbox_replay.Digest {
    return sandbox_replay.current_simulation_cohort.fingerprint();
}

pub fn worldConfigFingerprint(
    config: sandbox_host_contracts.Config,
) !sandbox_replay.Digest {
    return (try worldConfig(config)).fingerprint();
}

/// Validate first and return only bytes that this exact cohort can parse.
/// Hostile/noncanonical fixtures should mutate checked bytes rather than gain
/// a second public serialization path.
pub fn encode(
    allocator: std.mem.Allocator,
    value: SnapshotV14,
    limits: Limits,
) ![]u8 {
    try validate(
        value,
        limits.max_crates,
        limits.max_characters,
        limits.max_vehicles,
        limits.max_npcs,
    );
    const bytes = try std.json.Stringify.valueAlloc(allocator, value, .{});
    errdefer allocator.free(bytes);
    try ensureEncodedSize(bytes.len);
    return bytes;
}

fn ensureEncodedSize(byte_count: usize) !void {
    if (byte_count > max_bytes) return error.SnapshotTooLarge;
}

pub fn parse(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    max_crates: usize,
    max_characters: usize,
    max_vehicles: usize,
    max_npcs: usize,
) !std.json.Parsed(SnapshotV14) {
    if (bytes.len > max_bytes) return error.SnapshotTooLarge;
    var parsed = try std.json.parseFromSlice(SnapshotV14, allocator, bytes, .{});
    errdefer parsed.deinit();
    try validate(
        parsed.value,
        max_crates,
        max_characters,
        max_vehicles,
        max_npcs,
    );
    return parsed;
}

/// Bind construction fields persisted inside a snapshot to the exact world
/// admitted by its enclosing save envelope. Host-owned capacities and assets
/// are inputs; logical tuning must reproduce the same canonical fingerprint.
pub fn validateWorldConfig(
    snapshot: SnapshotV14,
    expected: sandbox_host_contracts.Config,
) !void {
    const snapshot_character = try snapshot.character_config.toConfig(
        expected.character.max_characters,
        expected.character.assets,
    );
    const snapshot_vehicle = try snapshot.vehicle_config.toConfig(
        expected.vehicle.max_vehicles,
        expected.vehicle.assets,
    );
    const snapshot_interaction = try snapshot.interaction_config.toConfig();
    const snapshot_npc = try snapshot.npc_config.toConfig(expected.npc.assets);
    const snapshot_npc_encounter = try snapshot.npc_encounter_config.toConfig();
    const embedded = try worldConfig(.{
        .namespace = snapshot.namespace,
        .fixed_delta_seconds = snapshot.fixed_delta_seconds,
        .max_crates = expected.max_crates,
        .assets = expected.assets,
        .create_ground = expected.create_ground,
        .character = snapshot_character,
        .vehicle = snapshot_vehicle,
        .interaction = snapshot_interaction,
        .npc = snapshot_npc,
        .npc_encounter = snapshot_npc_encounter,
        .authored_population = snapshot.authored_population,
        .block = expected.block,
    });
    const embedded_digest = try embedded.fingerprint();
    const expected_digest = try worldConfigFingerprint(expected);
    if (!std.mem.eql(u8, &embedded_digest, &expected_digest)) {
        return error.SnapshotWorldConfigMismatch;
    }
}

pub fn validate(
    snapshot: SnapshotV14,
    max_crates: usize,
    max_characters: usize,
    max_vehicles: usize,
    max_npcs: usize,
) !void {
    if (snapshot.schema_version != schema_version) return error.UnsupportedSchemaVersion;
    if (snapshot.namespace == 0) return error.InvalidIdentityNamespace;
    if (snapshot.next_local_id == 0) return error.InvalidIdentityCursor;
    if (!std.math.isFinite(snapshot.fixed_delta_seconds) or
        snapshot.fixed_delta_seconds <= 0)
    {
        return error.InvalidFixedDelta;
    }
    try snapshot.character_config.validate();
    try snapshot.vehicle_config.validate();
    try snapshot.interaction_config.validate();
    try snapshot.npc_config.validate();
    _ = try snapshot.npc_encounter_config.toConfig();
    try snapshot.navigation_gates.validate();
    try validateNpcLimit(max_npcs);
    try validateVirtualCharacterBudget(max_characters, max_npcs);
    try crates.validateRecords(snapshot.crates, max_crates);
    if (snapshot.characters.len > max_characters) return error.TooManyCharacters;
    try vehicles.validateRecords(snapshot.vehicles, max_vehicles);
    try districts.validateRecords(sandbox_district_recipe, snapshot.districts);
    try interactions.validateRecords(snapshot.interactions);
    var canonical_navigation = sandbox_navigation.CanonicalAccess{};
    try npc_snapshot_validation.validateRecords(
        &canonical_navigation,
        snapshot.npcs,
    );
    try vitals.validateRecords(snapshot.vitals);
    if (snapshot.npc_encounters.len > npc_encounters.max_records) {
        return error.TooManyNpcEncounterRecords;
    }
    for (snapshot.npc_encounters, 0..) |record, index| {
        try npc_encounters.validateRecord(record);
        if (index != 0 and !npc_encounters.lessThanTarget(
            {},
            snapshot.npc_encounters[index - 1].npc,
            record.npc,
        )) return error.NpcEncounterRecordsNotCanonical;
    }
    for (snapshot.crates) |record| {
        try validateIdentity(record.id, snapshot);
    }
    for (snapshot.characters, 0..) |record, index| {
        try characters.validateRecord(record);
        try validateIdentity(record.id, snapshot);
        for (snapshot.characters[0..index]) |earlier| {
            if (std.meta.eql(earlier.id, record.id)) return error.DuplicatePersistentId;
        }
        for (snapshot.crates) |crate_record| {
            if (std.meta.eql(crate_record.id, record.id)) {
                return error.DuplicatePersistentId;
            }
        }
    }
    for (snapshot.vitals) |record| {
        try validateIdentity(record.target.id, snapshot);
        const present = switch (record.target.kind) {
            .player => for (snapshot.characters) |character_record| {
                if (std.meta.eql(character_record.id, record.target.id)) break true;
            } else false,
            .npc => for (snapshot.npcs) |npc_record| {
                if (std.meta.eql(npc_record.id, record.target.id)) break true;
            } else false,
        };
        if (!present) return error.VitalsTargetNotFound;
    }
    for (snapshot.npc_encounters) |encounter| {
        const npc_present = for (snapshot.npcs) |npc_record| {
            if (std.meta.eql(npc_record.id, encounter.npc.id)) break true;
        } else false;
        const vitals_present = for (snapshot.vitals) |vital_record| {
            if (std.meta.eql(vital_record.target, encounter.npc)) break true;
        } else false;
        if (!npc_present or !vitals_present) return error.NpcEncounterOwnerNotFound;
    }
    for (snapshot.vehicles, 0..) |record, index| {
        try validateIdentity(record.id, snapshot);
        for (snapshot.crates) |crate_record| {
            if (std.meta.eql(crate_record.id, record.id)) {
                return error.DuplicatePersistentId;
            }
        }
        for (snapshot.characters) |character_record| {
            if (std.meta.eql(character_record.id, record.id)) {
                return error.DuplicatePersistentId;
            }
        }
        if (record.driver_id) |driver_id| {
            try validateIdentity(driver_id, snapshot);
            var found = false;
            for (snapshot.characters) |character_record| {
                if (std.meta.eql(character_record.id, driver_id)) {
                    found = true;
                    break;
                }
            }
            if (!found) return error.VehicleDriverNotFound;
            for (snapshot.vehicles[0..index]) |earlier| {
                if (earlier.driver_id) |earlier_driver| {
                    if (std.meta.eql(earlier_driver, driver_id)) {
                        return error.DuplicateVehicleDriver;
                    }
                }
            }
        }
    }
    for (snapshot.districts) |record| {
        try validateIdentity(record.id, snapshot);
        for (snapshot.crates) |crate_record| {
            if (std.meta.eql(crate_record.id, record.id)) return error.DuplicatePersistentId;
        }
        for (snapshot.characters) |character_record| {
            if (std.meta.eql(character_record.id, record.id)) {
                return error.DuplicatePersistentId;
            }
        }
        for (snapshot.vehicles) |vehicle_record| {
            if (std.meta.eql(vehicle_record.id, record.id)) {
                return error.DuplicatePersistentId;
            }
        }
    }
    for (snapshot.interactions, 0..) |record, index| {
        try validateIdentity(record.id, snapshot);
        for (snapshot.crates) |crate_record| {
            if (std.meta.eql(crate_record.id, record.id)) {
                return error.DuplicatePersistentId;
            }
        }
        for (snapshot.characters) |character_record| {
            if (std.meta.eql(character_record.id, record.id)) {
                return error.DuplicatePersistentId;
            }
        }
        for (snapshot.vehicles) |vehicle_record| {
            if (std.meta.eql(vehicle_record.id, record.id)) {
                return error.DuplicatePersistentId;
            }
        }
        for (snapshot.districts) |district_record| {
            if (std.meta.eql(district_record.id, record.id)) {
                return error.DuplicatePersistentId;
            }
        }
        for (snapshot.interactions[0..index]) |earlier| {
            if (std.meta.eql(earlier.id, record.id)) {
                return error.DuplicatePersistentId;
            }
        }

        switch (record.ownership) {
            .spatially_owned => {},
            .inventory_held => |holder| {
                try validateIdentity(holder, snapshot);
                var holder_found = false;
                for (snapshot.characters) |character_record| {
                    if (std.meta.eql(character_record.id, holder)) {
                        holder_found = true;
                        break;
                    }
                }
                if (!holder_found) return error.InteractionHolderNotFound;
                for (snapshot.vehicles) |vehicle_record| {
                    if (vehicle_record.driver_id) |driver_id| {
                        if (std.meta.eql(driver_id, holder)) {
                            return error.InteractionHolderDriving;
                        }
                    }
                }
                for (snapshot.interactions[0..index]) |earlier| {
                    switch (earlier.ownership) {
                        .spatially_owned => {},
                        .inventory_held => |earlier_holder| {
                            if (std.meta.eql(earlier_holder, holder)) {
                                return error.DuplicateInteractionHolder;
                            }
                        },
                    }
                }
            },
        }
    }
    for (snapshot.npcs) |record| {
        try validateIdentity(record.id, snapshot);
        for (snapshot.crates) |crate_record| {
            if (std.meta.eql(crate_record.id, record.id)) {
                return error.DuplicatePersistentId;
            }
        }
        for (snapshot.characters) |character_record| {
            if (std.meta.eql(character_record.id, record.id)) {
                return error.DuplicatePersistentId;
            }
        }
        for (snapshot.vehicles) |vehicle_record| {
            if (std.meta.eql(vehicle_record.id, record.id)) {
                return error.DuplicatePersistentId;
            }
        }
        for (snapshot.districts) |district_record| {
            if (std.meta.eql(district_record.id, record.id)) {
                return error.DuplicatePersistentId;
            }
        }
        for (snapshot.interactions) |interaction_record| {
            if (std.meta.eql(interaction_record.id, record.id)) {
                return error.DuplicatePersistentId;
            }
        }
    }
    try validatePopulation(snapshot);
}

fn validatePopulation(snapshot: SnapshotV14) !void {
    if (!snapshot.authored_population) {
        if (snapshot.population != null) {
            return error.UnexpectedPopulationSnapshot;
        }
        return;
    }
    const value = snapshot.population orelse return error.PopulationSnapshotMissing;
    try value.config.validate();
    try population_catalog.validate();
    if (value.catalog_version != population_catalog.catalog_version) {
        return error.PopulationCatalogVersionMismatch;
    }
    if (value.last_step_tick > snapshot.completed_ticks) {
        return error.PopulationTickAheadOfSnapshot;
    }
    const expected_members: usize = switch (value.config.cohort) {
        .ordinary => population.ordinary_member_count,
        .physical_stress => population.max_members,
    };
    if (value.members.len != expected_members or
        value.slots.len != population.max_activity_slots)
    {
        return error.InvalidPopulationSnapshotCapacity;
    }

    for (value.members, 0..) |member, index| {
        const definition = population_catalog.members[index];
        if (!population.PopulationMemberId.eql(member.id, definition.id) or
            member.actor_generation == 0 or member.spawn_in_flight or
            member.last_transition_tick > snapshot.completed_ticks)
        {
            return error.InvalidPopulationMemberRecord;
        }
        const program = population_catalog.programDefinition(
            definition.program,
        ) orelse return error.InvalidPopulationProgramReference;
        if (member.program_cursor >= program.stepSlice().len) {
            return error.InvalidPopulationProgramCursor;
        }
        for (value.members[0..index]) |earlier| {
            if (earlier.actor != null and member.actor != null and
                std.meta.eql(earlier.actor.?, member.actor.?))
            {
                return error.DuplicatePopulationActor;
            }
        }

        switch (member.lifecycle) {
            .live => {
                const actor = member.actor orelse return error.PopulationLiveActorMissing;
                const npc_record = for (snapshot.npcs) |candidate| {
                    if (std.meta.eql(candidate.id, actor)) break candidate;
                } else return error.PopulationActorNotFound;
                const expected_hostile =
                    definition.combat_disposition == .hostile_to_players;
                if (npc_record.hostile_to_players != expected_hostile) {
                    return error.PopulationCombatDispositionMismatch;
                }
                const target = vitals.Target{
                    .kind = .npc,
                    .id = actor,
                    .incarnation = .{ .value = member.actor_generation },
                };
                const vital_present = for (snapshot.vitals) |record| {
                    if (std.meta.eql(record.target, target)) break true;
                } else false;
                const encounter_present = for (snapshot.npc_encounters) |record| {
                    if (std.meta.eql(record.npc, target)) break true;
                } else false;
                try validatePopulationActorLifecycle(
                    expected_hostile,
                    vital_present,
                    encounter_present,
                );
            },
            .awaiting_spawn, .vacant, .replacement_pending => {
                if (member.actor != null) return error.PopulationInactiveActorPresent;
            },
        }

        const step = program.stepSlice()[member.program_cursor];
        try validatePopulationMemberActivity(member, step);
        switch (member.lifecycle) {
            .awaiting_spawn => if (member.activity_state != .replacement_pending)
                return error.InvalidPopulationLifecycleState,
            .live => if (member.activity_state == .vacant or
                member.activity_state == .replacement_pending)
                return error.InvalidPopulationLifecycleState,
            .vacant => if (member.activity_state != .vacant)
                return error.InvalidPopulationLifecycleState,
            .replacement_pending => if (member.activity_state != .replacement_pending)
                return error.InvalidPopulationLifecycleState,
        }
    }

    for (value.slots, 0..) |slot, index| {
        if (!population.ActivitySlotId.eql(
            slot.id,
            population_catalog.activity_slots[index].id,
        )) return error.InvalidPopulationSlotRecord;
        switch (slot.state) {
            .free => {
                if (slot.member != null or slot.lease_deadline_tick != 0) {
                    return error.InvalidFreePopulationSlot;
                }
            },
            .claimed, .occupied => {
                const member_id = slot.member orelse
                    return error.PopulationSlotMemberMissing;
                const member = for (value.members) |candidate| {
                    if (population.PopulationMemberId.eql(
                        candidate.id,
                        member_id,
                    )) break candidate;
                } else return error.PopulationSlotMemberNotFound;
                if (member.lifecycle != .live or member.activity_slot == null or
                    !population.ActivitySlotId.eql(member.activity_slot.?, slot.id) or
                    (slot.state == .claimed and member.activity_state != .traveling) or
                    (slot.state == .occupied and member.activity_state != .dwelling))
                {
                    return error.PopulationSlotClaimMismatch;
                }
            },
        }
    }
}

fn validatePopulationActorLifecycle(
    hostile_to_players: bool,
    vital_present: bool,
    encounter_present: bool,
) !void {
    // Every live authored actor owns vitals. Only hostile actors participate
    // in the NPC encounter feature; passive authored actors are deliberately
    // absent from that feature's canonical records.
    if (!vital_present or encounter_present != hostile_to_players) {
        return error.PopulationActorLifecycleIncomplete;
    }
}

fn validatePopulationMemberActivity(
    member: population.MemberRecordV1,
    step: population.ActivityStep,
) !void {
    switch (member.activity_state) {
        .traveling, .dwelling => {
            const site_id = member.activity_site orelse
                return error.PopulationActivitySiteMissing;
            const slot_id = member.activity_slot orelse
                return error.PopulationActivitySlotMissing;
            const slot = population_catalog.activitySlotDefinition(slot_id) orelse
                return error.InvalidPopulationActivitySlot;
            if (!population.ActivitySiteId.eql(site_id, step.site) or
                !population.ActivitySiteId.eql(slot.site, site_id) or
                !slot.activities.accepts(step.kind))
            {
                return error.PopulationActivityCatalogMismatch;
            }
        },
        .selecting, .waiting_for_slot => {
            if (member.activity_slot != null) {
                return error.UnexpectedPopulationActivityClaim;
            }
            if (member.activity_site) |site_id| {
                if (!population.ActivitySiteId.eql(site_id, step.site)) {
                    return error.PopulationActivityCatalogMismatch;
                }
            }
        },
        .completing, .interrupted, .vacant, .replacement_pending => {
            if (member.activity_site != null or member.activity_slot != null) {
                return error.UnexpectedPopulationActivityClaim;
            }
        },
    }
}

/// Convert a fully validated replay construction record into the one concrete
/// sandbox authority configuration. This remains a value conversion and does
/// not acquire native authority.
pub fn configFromReplayWorld(
    world: sandbox_replay.WorldConfig,
) !sandbox_host_contracts.Config {
    try world.validate();
    const max_characters = std.math.cast(usize, world.max_characters) orelse
        return error.WorldCapacityOutOfRange;
    const max_vehicles = std.math.cast(usize, world.max_vehicles) orelse
        return error.WorldCapacityOutOfRange;
    return .{
        .namespace = world.namespace,
        .fixed_delta_seconds = world.fixed_delta_seconds,
        .max_crates = std.math.cast(usize, world.max_crates) orelse
            return error.WorldCapacityOutOfRange,
        .create_ground = world.ground != null,
        .character = try world.character.toConfig(max_characters, .{}),
        .vehicle = try world.vehicle.toConfig(max_vehicles, .{}),
        .interaction = try world.interaction.toConfig(),
        .npc = try world.npc.toConfig(.{}),
        .npc_encounter = try world.npc_encounter.toConfig(),
        .authored_population = world.authored_population,
        .block = if (world.block) |block| .{
            .position = block.position,
            .half_extents = block.half_extents,
        } else null,
    };
}

fn validateIdentity(id: engine.PersistentId, snapshot: SnapshotV14) !void {
    if (id.namespace != snapshot.namespace) return error.ForeignIdentityNamespace;
    if (id.local >= snapshot.next_local_id) return error.IdentityCursorWouldCollide;
}

fn validateNpcLimit(max_npcs: usize) !void {
    if (max_npcs != npcs.max_npcs) return error.InvalidNpcLimit;
}

fn validateVirtualCharacterBudget(max_characters: usize, max_npcs: usize) !void {
    const required = std.math.add(usize, max_characters, max_npcs) catch
        return error.VirtualCharacterCapacityExceeded;
    if (required > simulation_cohort_options.jolt_max_virtual_characters) {
        return error.VirtualCharacterCapacityExceeded;
    }
}

fn emptySnapshot() SnapshotV14 {
    return .{
        .schema_version = schema_version,
        .completed_ticks = 0,
        .fixed_delta_seconds = 1.0 / 60.0,
        .namespace = 91,
        .next_local_id = 1,
        .character_config = characters.CharacterConfigV1.fromConfig(.{}),
        .vehicle_config = vehicles.VehicleConfigV1.fromConfig(.{}),
        .interaction_config = interactions.InteractionConfigV1.fromConfig(.{}),
        .npc_config = npcs.NpcConfigV1.fromConfig(.{}),
        .npc_encounter_config = npc_encounters.ConfigV1.fromConfig(.{}),
        .authored_population = false,
        .navigation_gates = initial_navigation_gates,
        .crates = &.{},
        .characters = &.{},
        .vehicles = &.{},
        .districts = &.{},
        .interactions = &.{},
        .npcs = &.{},
        .vitals = &.{},
        .npc_encounters = &.{},
        .population = null,
    };
}

test "canonical V14 snapshot round trips without native authority" {
    const expected = emptySnapshot();
    const bytes = try encode(std.testing.allocator, expected, .{});
    defer std.testing.allocator.free(bytes);

    var parsed = try parse(std.testing.allocator, bytes, 1, 1, 1, npcs.max_npcs);
    defer parsed.deinit();
    try std.testing.expectEqual(expected.schema_version, parsed.value.schema_version);
    try std.testing.expectEqual(expected.namespace, parsed.value.namespace);
    try std.testing.expectEqual(expected.next_local_id, parsed.value.next_local_id);
}

test "snapshot codec enforces size schema and exact world identity" {
    var hostile = emptySnapshot();
    hostile.schema_version += 1;
    try std.testing.expectError(
        error.UnsupportedSchemaVersion,
        validate(hostile, 1, 1, 1, npcs.max_npcs),
    );
    try std.testing.expectError(
        error.UnsupportedSchemaVersion,
        encode(std.testing.allocator, hostile, .{}),
    );
    try std.testing.expectError(
        error.SnapshotTooLarge,
        ensureEncodedSize(max_bytes + 1),
    );

    const duplicate_id = engine.PersistentId{ .namespace = 91, .local = 1 };
    const duplicate_characters = [_]characters.CharacterV1{
        .{
            .id = duplicate_id,
            .position = .{ 0, 0, 0 },
            .velocity = .{ 0, 0, 0 },
            .facing_yaw = 0,
        },
        .{
            .id = duplicate_id,
            .position = .{ 1, 0, 0 },
            .velocity = .{ 0, 0, 0 },
            .facing_yaw = 0,
        },
    };
    var duplicate = emptySnapshot();
    duplicate.next_local_id = 2;
    duplicate.characters = &duplicate_characters;
    try std.testing.expectError(
        error.DuplicatePersistentId,
        encode(std.testing.allocator, duplicate, .{ .max_characters = 2 }),
    );

    const config = sandbox_host_contracts.Config{ .namespace = 91 };
    try validateWorldConfig(emptySnapshot(), config);
    var drifted = emptySnapshot();
    drifted.fixed_delta_seconds = 1.0 / 30.0;
    try std.testing.expectError(
        error.SnapshotWorldConfigMismatch,
        validateWorldConfig(drifted, config),
    );
}

test "population preflight rejects catalog and claim drift before native authority" {
    var members: [population.ordinary_member_count]population.MemberRecordV1 = undefined;
    for (&members, population_catalog.members[0..members.len]) |*record, definition| {
        record.* = .{
            .id = definition.id,
            .lifecycle = .awaiting_spawn,
            .actor_generation = 1,
            .spawn_in_flight = false,
            .program_cursor = definition.phase_offset,
            .activity_sequence = 0,
            .activity_state = .replacement_pending,
            .deadline_tick = 0,
            .retry_tick = 1,
            .spawn_retry_reason = .none,
            .spawn_candidate_cursor = 0,
            .last_transition_tick = 0,
            .last_transition_reason = .cold_bootstrap,
        };
    }
    var slots: [population.max_activity_slots]population.ActivitySlotRecordV1 =
        undefined;
    for (&slots, population_catalog.activity_slots) |*record, definition| {
        record.* = .{
            .id = definition.id,
            .state = .free,
            .lease_deadline_tick = 0,
        };
    }
    var population_snapshot = population.SnapshotV1{
        .catalog_version = population_catalog.catalog_version,
        .config = .{},
        .last_step_tick = 0,
        .stats = .{},
        .members = &members,
        .slots = &slots,
    };
    var snapshot = emptySnapshot();
    snapshot.authored_population = true;
    snapshot.population = population_snapshot;
    try validate(snapshot, 1, 1, 1, npcs.max_npcs);

    members[0].id = .{ .value = 99 };
    try std.testing.expectError(
        error.InvalidPopulationMemberRecord,
        validate(snapshot, 1, 1, 1, npcs.max_npcs),
    );
    members[0].id = population_catalog.members[0].id;

    slots[0].state = .claimed;
    slots[0].member = members[0].id;
    slots[0].lease_deadline_tick = 10;
    try std.testing.expectError(
        error.PopulationSlotClaimMismatch,
        validate(snapshot, 1, 1, 1, npcs.max_npcs),
    );

    slots[0] = .{
        .id = population_catalog.activity_slots[0].id,
        .state = .free,
        .lease_deadline_tick = 0,
    };
    population_snapshot.catalog_version +%= 1;
    snapshot.population = population_snapshot;
    try std.testing.expectError(
        error.PopulationCatalogVersionMismatch,
        validate(snapshot, 1, 1, 1, npcs.max_npcs),
    );
}

test "population preflight distinguishes waiting intent from an activity claim" {
    const definition = population_catalog.members[0];
    const program = population_catalog.programDefinition(definition.program) orelse
        return error.MissingPopulationProgram;
    const step = program.stepSlice()[definition.phase_offset];
    var member = population.MemberRecordV1{
        .id = definition.id,
        .lifecycle = .live,
        .actor_generation = 1,
        .spawn_in_flight = false,
        .program_cursor = definition.phase_offset,
        .activity_sequence = 1,
        .activity_state = .waiting_for_slot,
        .activity_site = step.site,
        .deadline_tick = 0,
        .retry_tick = 1,
        .spawn_retry_reason = .none,
        .spawn_candidate_cursor = 0,
        .last_transition_tick = 1,
        .last_transition_reason = .slot_unavailable,
    };

    try validatePopulationMemberActivity(member, step);
    member.activity_state = .selecting;
    try validatePopulationMemberActivity(member, step);

    member.activity_state = .waiting_for_slot;
    member.activity_slot = population_catalog.activity_slots[0].id;
    try std.testing.expectError(
        error.UnexpectedPopulationActivityClaim,
        validatePopulationMemberActivity(member, step),
    );

    member.activity_slot = null;
    member.activity_site = population_catalog.sites[
        if (step.site.value == population_catalog.sites[0].id.value) 1 else 0
    ].id;
    try std.testing.expectError(
        error.PopulationActivityCatalogMismatch,
        validatePopulationMemberActivity(member, step),
    );
}

test "population actor lifecycle requires encounters only for hostile actors" {
    try validatePopulationActorLifecycle(false, true, false);
    try validatePopulationActorLifecycle(true, true, true);

    try std.testing.expectError(
        error.PopulationActorLifecycleIncomplete,
        validatePopulationActorLifecycle(false, false, false),
    );
    try std.testing.expectError(
        error.PopulationActorLifecycleIncomplete,
        validatePopulationActorLifecycle(false, true, true),
    );
    try std.testing.expectError(
        error.PopulationActorLifecycleIncomplete,
        validatePopulationActorLifecycle(true, true, false),
    );
}
