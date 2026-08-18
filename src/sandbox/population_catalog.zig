//! Exact authored population catalog for the four-district sandbox.
//!
//! This module owns static game content and cold admission only. It owns no
//! population lifecycle, NPC movement, physics query, session, or rendering.

const std = @import("std");
const district = @import("district_contract");
const npc = @import("npc_contract");
const population = @import("population_contract");
const recipe = @import("sandbox_district_recipe");

pub const catalog_version: u16 = 2;
pub const ordinary_member_count: usize = 12;
pub const physical_member_count: usize = 16;
pub const spawn_separation: f32 = 0.9;
pub const activity_separation: f32 = 0.9;
const pi: f32 = std.math.pi;
const half_pi: f32 = pi / 2.0;
const backward_yaw: f32 = pi - 0.0001;
pub const placement_clearance = recipe.CapsuleClearance{
    .radius = 0.35,
    .half_height = 0.45,
    .margin = 0.08,
};

pub const roles = [_]population.RoleDefinition{
    .{
        .role = .resident,
        .label = "resident",
        .base_color = .{ 0.22, 0.72, 0.34, 1 },
    },
    .{
        .role = .worker,
        .label = "worker",
        .base_color = .{ 0.18, 0.48, 0.92, 1 },
    },
    .{
        .role = .visitor,
        .label = "visitor",
        .base_color = .{ 0.76, 0.34, 0.88, 1 },
    },
};

const empty_step = population.ActivityStep{
    .site = .{},
    .kind = .idle,
    .dwell_ticks = 0,
};

pub const programs = [_]population.ActivityProgramDefinition{
    .{
        .id = programId(1),
        .label = "resident-local",
        .steps = .{
            step(1, .visit, 240),
            step(9, .visit, 180),
            step(10, .visit, 180),
            step(5, .shop, 300),
            step(1, .idle, 180),
            empty_step,
        },
        .step_count = 5,
    },
    .{
        .id = programId(2),
        .label = "resident-east",
        .steps = .{
            step(8, .idle, 240),
            step(5, .shop, 300),
            step(11, .visit, 180),
            step(12, .visit, 180),
            empty_step,
            empty_step,
        },
        .step_count = 4,
    },
    .{
        .id = programId(3),
        .label = "worker-cross-district",
        .steps = .{
            step(2, .commute, 180),
            step(11, .commute, 240),
            step(9, .visit, 180),
            step(7, .commute, 240),
            step(2, .commute, 240),
            empty_step,
        },
        .step_count = 5,
    },
    .{
        .id = programId(4),
        .label = "visitor-loop",
        .steps = .{
            step(1, .visit, 180),
            step(9, .idle, 180),
            step(11, .visit, 240),
            step(12, .visit, 180),
            step(5, .visit, 240),
            step(7, .visit, 180),
        },
        .step_count = 6,
    },
};

pub const sites = [_]population.ActivitySiteDefinition{
    site(1, "Player Plaza", recipe.navigation_west_coord, .{ 1, 2, 0 }, 2),
    site(2, "Depot Forecourt", recipe.navigation_west_coord, .{ 3, 4, 0 }, 2),
    site(3, "South Gate Approach", recipe.navigation_west_coord, .{ 5, 6, 0 }, 2),
    site(4, "North Walk", recipe.navigation_west_coord, .{ 7, 8, 0 }, 2),
    site(5, "Market Terminal", recipe.navigation_east_coord, .{ 9, 10, 11 }, 3),
    site(6, "Alley Junction", recipe.navigation_east_coord, .{ 12, 13, 0 }, 2),
    site(7, "Transit Yard", recipe.navigation_east_coord, .{ 14, 15, 0 }, 2),
    site(8, "East Court", recipe.navigation_east_coord, .{ 16, 0, 0 }, 1),
    site(9, "North Plaza", recipe.navigation_northwest_coord, .{ 17, 18, 0 }, 2),
    site(10, "Civic Court", recipe.navigation_northwest_coord, .{ 19, 20, 0 }, 2),
    site(11, "Station Concourse", recipe.navigation_northeast_coord, .{ 21, 22, 0 }, 2),
    site(12, "North Alley", recipe.navigation_northeast_coord, .{ 23, 24, 0 }, 2),
};

pub const activity_slots = [_]population.ActivitySlotDefinition{
    activitySlot(1, "plaza-a", 1, 1, .{ -6.5, 0, 6.2 }, 0, .{ .visit = true, .idle = true }),
    activitySlot(2, "plaza-b", 1, 7, .{ -3.5, 0, 6.2 }, backward_yaw, .{ .visit = true, .idle = true }),
    activitySlot(3, "depot-a", 2, 2, .{ 4.0, 0, 6.3 }, -half_pi, .{ .commute = true, .visit = true }),
    activitySlot(4, "depot-b", 2, 8, .{ 5.8, 0, 5.2 }, backward_yaw, .{ .commute = true, .visit = true }),
    activitySlot(5, "south-a", 3, 3, .{ 3.0, 0, -5.8 }, 0, .{ .visit = true }),
    activitySlot(6, "south-b", 3, 9, .{ 5.3, 0, -4.8 }, half_pi, .{ .visit = true }),
    activitySlot(7, "north-a", 4, 10, .{ 2.0, 0, 1.5 }, 0, .{ .commute = true, .idle = true }),
    activitySlot(8, "north-b", 4, 11, .{ 4.5, 0, 2.5 }, backward_yaw, .{ .commute = true, .idle = true }),
    activitySlot(9, "market-a", 5, 4, .{ 18.5, 0, 6.3 }, 0, .{ .shop = true, .visit = true }),
    activitySlot(10, "market-b", 5, 12, .{ 20.5, 0, 6.3 }, backward_yaw, .{ .shop = true, .visit = true }),
    activitySlot(11, "market-c", 5, 13, .{ 22.5, 0, 5.3 }, backward_yaw, .{ .shop = true, .visit = true }),
    activitySlot(12, "alley-a", 6, 5, .{ 13.0, 0, -0.8 }, 0, .{ .visit = true, .idle = true }),
    activitySlot(13, "alley-b", 6, 14, .{ 14.5, 0, 0.6 }, backward_yaw, .{ .visit = true, .idle = true }),
    activitySlot(14, "transit-a", 7, 6, .{ 19.0, 0, -5.7 }, 0, .{ .commute = true, .visit = true }),
    activitySlot(15, "transit-b", 7, 15, .{ 21.5, 0, -5.5 }, backward_yaw, .{ .commute = true, .visit = true }),
    activitySlot(16, "court-a", 8, 16, .{ 12.5, 0, 5.8 }, 0, .{ .idle = true, .visit = true }),
    activitySlot(17, "north-plaza-a", 9, 17, .{ -6.5, 0, 17.5 }, 0, .{ .visit = true, .idle = true }),
    activitySlot(18, "north-plaza-b", 9, 18, .{ -4.0, 0, 19.5 }, backward_yaw, .{ .visit = true, .idle = true }),
    activitySlot(19, "civic-a", 10, 19, .{ 3.5, 0, 20.5 }, 0, .{ .visit = true, .idle = true }),
    activitySlot(20, "civic-b", 10, 20, .{ 5.8, 0, 19.2 }, backward_yaw, .{ .visit = true, .idle = true }),
    activitySlot(21, "station-a", 11, 21, .{ 19.5, 0, 17.0 }, 0, .{ .commute = true, .visit = true }),
    activitySlot(22, "station-b", 11, 22, .{ 21.0, 0, 19.0 }, backward_yaw, .{ .commute = true, .visit = true }),
    activitySlot(23, "north-alley-a", 12, 23, .{ 13.0, 0, 14.8 }, 0, .{ .shop = true, .visit = true, .idle = true }),
    activitySlot(24, "north-alley-b", 12, 24, .{ 14.8, 0, 16.5 }, backward_yaw, .{ .shop = true, .visit = true, .idle = true }),
};

const every_role = population.RoleMask{
    .resident = true,
    .worker = true,
    .visitor = true,
};

pub const spawn_slots = [_]population.SpawnSlotDefinition{
    spawnSlot(1, "west-01", .{ -6.5, 0, -6.5 }, 0, recipe.navigation_west_coord, 2),
    spawnSlot(2, "west-02", .{ -4.5, 0, -6.5 }, 0, recipe.navigation_west_coord, 2),
    spawnSlot(3, "west-03", .{ -2.5, 0, -6.5 }, 0, recipe.navigation_west_coord, 2),
    spawnSlot(4, "west-04", .{ 2.0, 0, -7.0 }, 0, recipe.navigation_west_coord, 3),
    spawnSlot(5, "west-05", .{ 4.5, 0, -6.5 }, 0, recipe.navigation_west_coord, 3),
    spawnSlot(6, "west-06", .{ 6.5, 0, -6.5 }, 0, recipe.navigation_west_coord, 7),
    spawnSlot(7, "west-07", .{ -6.5, 0, 0.0 }, half_pi, recipe.navigation_west_coord, 1),
    spawnSlot(8, "west-08", .{ -3.5, 0, 0.0 }, half_pi, recipe.navigation_west_coord, 1),
    spawnSlot(9, "west-09", .{ 2.5, 0, 0.0 }, -half_pi, recipe.navigation_west_coord, 4),
    spawnSlot(10, "west-10", .{ 5.5, 0, 0.0 }, -half_pi, recipe.navigation_west_coord, 4),
    spawnSlot(11, "west-11", .{ -6.5, 0, 2.0 }, half_pi, recipe.navigation_west_coord, 1),
    spawnSlot(12, "west-12", .{ -3.5, 0, 2.0 }, half_pi, recipe.navigation_west_coord, 1),
    spawnSlot(13, "east-01", .{ 9.5, 0, 6.5 }, backward_yaw, recipe.navigation_east_coord, 0),
    spawnSlot(14, "east-02", .{ 11.5, 0, 3.5 }, backward_yaw, recipe.navigation_east_coord, 1),
    spawnSlot(15, "east-03", .{ 15.0, 0, 6.5 }, backward_yaw, recipe.navigation_east_coord, 1),
    spawnSlot(16, "east-04", .{ 17.5, 0, 4.5 }, backward_yaw, recipe.navigation_east_coord, 2),
    spawnSlot(17, "east-05", .{ 21.0, 0, 3.5 }, backward_yaw, recipe.navigation_east_coord, 2),
    spawnSlot(18, "east-06", .{ 23.0, 0, 6.5 }, backward_yaw, recipe.navigation_east_coord, 2),
    spawnSlot(19, "east-07", .{ 9.5, 0, 0.0 }, -half_pi, recipe.navigation_east_coord, 0),
    spawnSlot(20, "east-08", .{ 12.0, 0, 0.0 }, -half_pi, recipe.navigation_east_coord, 7),
    spawnSlot(21, "east-09", .{ 20.0, 0, 1.5 }, half_pi, recipe.navigation_east_coord, 3),
    spawnSlot(22, "east-10", .{ 22.5, 0, 1.5 }, half_pi, recipe.navigation_east_coord, 3),
    spawnSlot(23, "east-11", .{ 10.0, 0, -6.5 }, 0, recipe.navigation_east_coord, 6),
    spawnSlot(24, "east-12", .{ 13.0, 0, -6.5 }, 0, recipe.navigation_east_coord, 5),
    spawnSlot(25, "northwest-01", .{ -6.5, 0, 10.0 }, 0, recipe.navigation_northwest_coord, 0),
    spawnSlot(26, "northwest-02", .{ -3.5, 0, 10.5 }, 0, recipe.navigation_northwest_coord, 0),
    spawnSlot(27, "northwest-03", .{ 2.0, 0, 22.5 }, backward_yaw, recipe.navigation_northwest_coord, 3),
    spawnSlot(28, "northwest-04", .{ 6.5, 0, 22.5 }, backward_yaw, recipe.navigation_northwest_coord, 7),
    spawnSlot(29, "northeast-01", .{ 9.5, 0, 10.0 }, 0, recipe.navigation_northeast_coord, 0),
    spawnSlot(30, "northeast-02", .{ 12.5, 0, 10.0 }, 0, recipe.navigation_northeast_coord, 1),
    spawnSlot(31, "northeast-03", .{ 20.0, 0, 23.0 }, backward_yaw, recipe.navigation_northeast_coord, 4),
    spawnSlot(32, "northeast-04", .{ 22.5, 0, 22.5 }, backward_yaw, recipe.navigation_northeast_coord, 4),
};

pub const members = [_]population.PopulationMemberDefinition{
    member(1, "P01", .resident, 1, 0, .hostile_to_players, 1, .{ 1, 2, 4, 13, 14, 19, 0, 0 }, 6),
    member(2, "P02", .resident, 1, 1, .passive, 4, .{ 4, 5, 7, 15, 16, 20, 0, 0 }, 6),
    member(3, "P03", .resident, 1, 2, .passive, 25, .{ 25, 26, 7, 13, 19, 29, 0, 0 }, 6),
    member(4, "P04", .resident, 2, 0, .passive, 14, .{ 14, 20, 24, 9, 27, 31, 0, 0 }, 6),
    member(5, "P05", .resident, 2, 1, .passive, 27, .{ 27, 28, 11, 15, 18, 31, 0, 0 }, 6),
    member(6, "P06", .worker, 3, 0, .passive, 2, .{ 2, 5, 6, 16, 17, 24, 0, 0 }, 6),
    member(7, "P07", .worker, 3, 1, .passive, 26, .{ 26, 28, 5, 13, 17, 29, 0, 0 }, 6),
    member(8, "P08", .worker, 3, 2, .passive, 29, .{ 29, 30, 13, 2, 6, 25, 0, 0 }, 6),
    member(9, "P09", .worker, 3, 3, .passive, 16, .{ 16, 17, 23, 3, 5, 10, 0, 0 }, 6),
    member(10, "P10", .visitor, 4, 0, .passive, 19, .{ 19, 20, 23, 1, 7, 11, 0, 0 }, 6),
    member(11, "P11", .visitor, 4, 1, .passive, 31, .{ 31, 32, 21, 4, 8, 27, 0, 0 }, 6),
    member(12, "P12", .visitor, 4, 2, .passive, 32, .{ 32, 30, 23, 3, 6, 25, 0, 0 }, 6),
    member(13, "P13", .resident, 1, 4, .passive, 3, .{ 3, 14, 18, 27, 30, 12, 0, 0 }, 6),
    member(14, "P14", .resident, 2, 2, .passive, 15, .{ 15, 18, 20, 4, 10, 11, 0, 0 }, 6),
    member(15, "P15", .worker, 3, 0, .passive, 17, .{ 17, 18, 24, 3, 6, 12, 0, 0 }, 6),
    member(16, "P16", .visitor, 4, 3, .passive, 24, .{ 24, 22, 14, 6, 8, 10, 0, 0 }, 6),
};

pub const catalog = population.Catalog{
    .roles = &roles,
    .programs = &programs,
    .members = &members,
    .sites = &sites,
    .activity_slots = &activity_slots,
    .spawn_slots = &spawn_slots,
};

pub fn validate() !void {
    if (roles.len != population.max_roles or
        programs.len != population.max_programs or
        members.len != population.max_members or
        sites.len != population.max_sites or
        activity_slots.len != population.max_activity_slots or
        spawn_slots.len != population.max_spawn_slots)
    {
        return error.InvalidPopulationCatalogCapacity;
    }
    try validateRoles();
    try validateSitesAndSlots();
    try validateSpawnSlots();
    try validatePrograms();
    try validateMembers();
}

pub fn roleDefinition(role: population.Role) ?population.RoleDefinition {
    for (roles) |definition| {
        if (definition.role == role) return definition;
    }
    return null;
}

pub fn programDefinition(
    id: population.ActivityProgramId,
) ?population.ActivityProgramDefinition {
    for (programs) |definition| {
        if (population.ActivityProgramId.eql(definition.id, id)) return definition;
    }
    return null;
}

pub fn memberDefinition(
    id: population.PopulationMemberId,
) ?population.PopulationMemberDefinition {
    for (members) |definition| {
        if (population.PopulationMemberId.eql(definition.id, id)) return definition;
    }
    return null;
}

pub fn siteDefinition(
    id: population.ActivitySiteId,
) ?population.ActivitySiteDefinition {
    for (sites) |definition| {
        if (population.ActivitySiteId.eql(definition.id, id)) return definition;
    }
    return null;
}

pub fn activitySlotDefinition(
    id: population.ActivitySlotId,
) ?population.ActivitySlotDefinition {
    for (activity_slots) |definition| {
        if (population.ActivitySlotId.eql(definition.id, id)) return definition;
    }
    return null;
}

pub fn spawnSlotDefinition(
    id: population.SpawnSlotId,
) ?population.SpawnSlotDefinition {
    for (spawn_slots) |definition| {
        if (population.SpawnSlotId.eql(definition.id, id)) return definition;
    }
    return null;
}

fn validateRoles() !void {
    var seen = [_]bool{false} ** population.max_roles;
    for (roles) |definition| {
        const index = @intFromEnum(definition.role) - 1;
        if (index >= seen.len or seen[index]) return error.DuplicatePopulationRole;
        seen[index] = true;
        if (!population.validLabel(definition.label)) return error.InvalidPopulationLabel;
        for (definition.base_color) |component| {
            if (!std.math.isFinite(component) or component < 0 or component > 1) {
                return error.InvalidPopulationRoleColor;
            }
        }
    }
    for (seen) |value| if (!value) return error.MissingPopulationRole;
}

fn validateSitesAndSlots() !void {
    var slot_membership = [_]u8{0} ** population.max_activity_slots;
    for (sites, 0..) |definition, index| {
        try definition.id.validate();
        if (definition.id.value > sites.len or
            definition.id.value != index + 1 or
            !population.validLabel(definition.label) or
            definition.slot_count == 0 or
            definition.slot_count > population.max_site_slots)
        {
            return error.InvalidActivitySiteDefinition;
        }
        if (!knownOwner(definition.owner)) return error.InvalidActivitySiteOwner;
        for (definition.slotSlice(), 0..) |slot_id, slot_index| {
            try slot_id.validate();
            if (slot_id.value > activity_slots.len) return error.UnknownActivitySlot;
            for (definition.slotSlice()[0..slot_index]) |earlier| {
                if (population.ActivitySlotId.eql(earlier, slot_id)) {
                    return error.DuplicateActivitySiteSlot;
                }
            }
            slot_membership[slot_id.value - 1] += 1;
            const slot_definition = activitySlotDefinition(slot_id) orelse
                return error.UnknownActivitySlot;
            if (!population.ActivitySiteId.eql(slot_definition.site, definition.id)) {
                return error.ActivitySlotSiteMismatch;
            }
        }
    }

    for (activity_slots, 0..) |definition, index| {
        try definition.id.validate();
        try definition.site.validate();
        try definition.destination.validate();
        try definition.activities.validate();
        if (definition.id.value != index + 1 or
            !population.validLabel(definition.label) or
            !population.validPose(definition.position, definition.facing_yaw) or
            slot_membership[index] != 1)
        {
            return error.InvalidActivitySlotDefinition;
        }
        const site_definition = siteDefinition(definition.site) orelse
            return error.UnknownActivitySite;
        const owner = district.chunkCoordForWorldPosition(definition.position) catch
            return error.InvalidActivitySlotOwner;
        if (!district.ChunkCoord.eql(owner, site_definition.owner)) {
            return error.ActivitySlotOwnerMismatch;
        }
        const destination = recipe.resolveDestination(definition.destination) orelse
            return error.UnknownActivityDestination;
        if (!std.meta.eql(destination.position, definition.position)) {
            return error.ActivityDestinationPoseMismatch;
        }
        const build = buildFor(site_definition.owner);
        if (!recipe.capsuleTraversalClear(
            &build,
            definition.position,
            definition.position,
            placement_clearance,
        )) return error.ActivitySlotBlocked;
        for (destination.anchorSlice()) |anchor| {
            const anchor_position = nodePosition(anchor) orelse
                return error.InvalidActivityDestinationAnchor;
            if (!district.ChunkCoord.eql(anchor.coord, site_definition.owner) or
                !recipe.capsuleTraversalClear(
                    &build,
                    anchor_position,
                    definition.position,
                    placement_clearance,
                ))
            {
                return error.ActivityDestinationTraversalBlocked;
            }
        }
        for (activity_slots[0..index]) |earlier| {
            if (distanceSquaredXZ(earlier.position, definition.position) <
                activity_separation * activity_separation)
            {
                return error.ActivitySlotsOverlap;
            }
        }
    }
}

fn validateSpawnSlots() !void {
    for (spawn_slots, 0..) |definition, index| {
        try definition.id.validate();
        try definition.roles.validate();
        if (definition.id.value != index + 1 or
            !population.validLabel(definition.label) or
            !population.validPose(definition.position, definition.facing_yaw))
        {
            return error.InvalidSpawnSlotDefinition;
        }
        const owner = district.chunkCoordForWorldPosition(definition.position) catch
            return error.InvalidSpawnSlotOwner;
        if (!knownOwner(owner) or !district.ChunkCoord.eql(owner, definition.anchor.coord)) {
            return error.SpawnSlotOwnerMismatch;
        }
        const anchor_position = nodePosition(definition.anchor) orelse
            return error.InvalidSpawnSlotAnchor;
        const build = buildFor(owner);
        if (!recipe.capsuleTraversalClear(
            &build,
            definition.position,
            definition.position,
            placement_clearance,
        ) or !recipe.capsuleTraversalClear(
            &build,
            definition.position,
            anchor_position,
            placement_clearance,
        )) return error.SpawnSlotBlocked;

        for (spawn_slots[0..index]) |earlier| {
            if (distanceSquaredXZ(earlier.position, definition.position) <
                spawn_separation * spawn_separation)
            {
                return error.SpawnSlotsOverlap;
            }
        }
        for (activity_slots) |activity_slot| {
            if (distanceSquaredXZ(activity_slot.position, definition.position) <
                spawn_separation * spawn_separation)
            {
                return error.SpawnAndActivitySlotsOverlap;
            }
        }
    }
}

fn validatePrograms() !void {
    for (programs, 0..) |definition, index| {
        try definition.id.validate();
        if (definition.id.value != index + 1 or
            !population.validLabel(definition.label) or
            definition.step_count == 0 or
            definition.step_count > population.max_program_steps)
        {
            return error.InvalidActivityProgramDefinition;
        }
        for (definition.stepSlice()) |program_step| {
            try program_step.site.validate();
            if (program_step.dwell_ticks == 0) return error.InvalidActivityDwell;
            const site_definition = siteDefinition(program_step.site) orelse
                return error.UnknownActivitySite;
            var accepted = false;
            for (site_definition.slotSlice()) |slot_id| {
                const slot_definition = activitySlotDefinition(slot_id) orelse
                    return error.UnknownActivitySlot;
                accepted = accepted or slot_definition.activities.accepts(program_step.kind);
            }
            if (!accepted) return error.ActivityKindUnsupportedBySite;
        }
    }
}

fn validateMembers() !void {
    var ordinary_role_counts = [_]u8{ 0, 0, 0 };
    var ordinary_count: u8 = 0;
    var hostile_count: u8 = 0;
    var initial_slots = [_]bool{false} ** population.max_spawn_slots;
    for (members, 0..) |definition, index| {
        try definition.id.validate();
        try definition.program.validate();
        try definition.initial_spawn_slot.validate();
        if (definition.id.value != index + 1 or
            !population.validLabel(definition.label) or
            definition.replacement_spawn_slot_count < 4 or
            definition.replacement_spawn_slot_count >
                population.max_member_spawn_candidates)
        {
            return error.InvalidPopulationMemberDefinition;
        }
        const program_definition = programDefinition(definition.program) orelse
            return error.UnknownActivityProgram;
        if (definition.phase_offset >= program_definition.step_count) {
            return error.InvalidPopulationMemberPhase;
        }
        const initial = spawnSlotDefinition(definition.initial_spawn_slot) orelse
            return error.UnknownSpawnSlot;
        if (!initial.roles.accepts(definition.role)) {
            return error.SpawnSlotRejectsMemberRole;
        }
        const initial_index = definition.initial_spawn_slot.value - 1;
        if (initial_slots[initial_index]) return error.DuplicateInitialSpawnSlot;
        initial_slots[initial_index] = true;

        var has_cross_district_candidate = false;
        for (definition.replacementSpawnSlots(), 0..) |slot_id, candidate_index| {
            try slot_id.validate();
            for (definition.replacementSpawnSlots()[0..candidate_index]) |earlier| {
                if (population.SpawnSlotId.eql(earlier, slot_id)) {
                    return error.DuplicateMemberSpawnCandidate;
                }
            }
            const candidate = spawnSlotDefinition(slot_id) orelse
                return error.UnknownSpawnSlot;
            if (!candidate.roles.accepts(definition.role)) {
                return error.SpawnSlotRejectsMemberRole;
            }
            has_cross_district_candidate = has_cross_district_candidate or
                !district.ChunkCoord.eql(candidate.anchor.coord, initial.anchor.coord);
        }
        if (!population.SpawnSlotId.eql(
            definition.replacementSpawnSlots()[0],
            definition.initial_spawn_slot,
        )) {
            return error.InitialSpawnSlotMustLeadCandidateOrder;
        }
        if (!has_cross_district_candidate) {
            return error.MemberMissingCrossDistrictSpawnCandidate;
        }
        if (definition.ordinary_product) {
            ordinary_count += 1;
            ordinary_role_counts[@intFromEnum(definition.role) - 1] += 1;
        }
        hostile_count += @intFromBool(
            definition.combat_disposition == .hostile_to_players,
        );
    }
    if (ordinary_count != ordinary_member_count or
        !std.meta.eql(ordinary_role_counts, [3]u8{ 5, 4, 3 }) or
        hostile_count != 1)
    {
        return error.InvalidPopulationRosterDistribution;
    }
}

fn knownOwner(owner: npc.ChunkCoord) bool {
    for (recipe.installed_coords) |coord| {
        if (district.ChunkCoord.eql(owner, coord)) return true;
    }
    return false;
}

fn buildFor(owner: npc.ChunkCoord) district.DistrictBuild {
    return recipe.build(owner, recipe.current_recipe_version).ready;
}

fn nodePosition(reference: npc.NodeRef) ?[3]f32 {
    if (!knownOwner(reference.coord)) return null;
    const build = buildFor(reference.coord);
    if (reference.index >= build.navigation_node_count) return null;
    return build.navigationNodes()[reference.index].position;
}

fn distanceSquaredXZ(a: [3]f32, b: [3]f32) f32 {
    const dx = a[0] - b[0];
    const dz = a[2] - b[2];
    return dx * dx + dz * dz;
}

fn programId(value: u8) population.ActivityProgramId {
    return .{ .value = value };
}

fn step(
    site_value: u16,
    kind: population.ActivityKind,
    dwell_ticks: u16,
) population.ActivityStep {
    return .{
        .site = .{ .value = site_value },
        .kind = kind,
        .dwell_ticks = dwell_ticks,
    };
}

fn site(
    id_value: u16,
    label: []const u8,
    owner: npc.ChunkCoord,
    slot_values: [population.max_site_slots]u16,
    slot_count: u8,
) population.ActivitySiteDefinition {
    var result = population.ActivitySiteDefinition{
        .id = .{ .value = id_value },
        .label = label,
        .owner = owner,
        .slot_count = slot_count,
    };
    for (slot_values, 0..) |value, index| {
        result.slots[index] = .{ .value = value };
    }
    return result;
}

fn activitySlot(
    id_value: u16,
    label: []const u8,
    site_value: u16,
    destination_value: u16,
    position: [3]f32,
    facing_yaw: f32,
    activities: population.ActivityKindMask,
) population.ActivitySlotDefinition {
    return .{
        .id = .{ .value = id_value },
        .label = label,
        .site = .{ .value = site_value },
        .destination = .{ .value = destination_value },
        .position = position,
        .facing_yaw = facing_yaw,
        .activities = activities,
    };
}

fn spawnSlot(
    id_value: u16,
    label: []const u8,
    position: [3]f32,
    facing_yaw: f32,
    owner: npc.ChunkCoord,
    anchor_index: u8,
) population.SpawnSlotDefinition {
    return .{
        .id = .{ .value = id_value },
        .label = label,
        .position = position,
        .facing_yaw = facing_yaw,
        .anchor = .{ .coord = owner, .index = anchor_index },
        .roles = every_role,
    };
}

fn member(
    id_value: u16,
    label: []const u8,
    role: population.Role,
    program_value: u8,
    phase_offset: u8,
    disposition: population.CombatDisposition,
    initial_spawn_value: u16,
    candidates: [population.max_member_spawn_candidates]u16,
    candidate_count: u8,
) population.PopulationMemberDefinition {
    var result = population.PopulationMemberDefinition{
        .id = .{ .value = id_value },
        .label = label,
        .ordinary_product = id_value <= ordinary_member_count,
        .role = role,
        .program = .{ .value = program_value },
        .phase_offset = phase_offset,
        .combat_disposition = disposition,
        .initial_spawn_slot = .{ .value = initial_spawn_value },
        .replacement_spawn_slot_count = candidate_count,
    };
    for (candidates, 0..) |value, index| {
        result.replacement_spawn_slots[index] = .{ .value = value };
    }
    return result;
}

test "canonical population catalog is exact and cold-valid" {
    try validate();
    try std.testing.expectEqual(population.max_members, catalog.members.len);
    try std.testing.expectEqual(population.max_activity_slots, catalog.activity_slots.len);
    try std.testing.expectEqual(population.max_spawn_slots, catalog.spawn_slots.len);
}

test "authored physical placements are unique and balanced across districts" {
    var counts = [_]usize{0} ** recipe.installed_coords.len;
    for (spawn_slots) |slot_definition| {
        var found = false;
        for (recipe.installed_coords, 0..) |coord, index| {
            if (!district.ChunkCoord.eql(slot_definition.anchor.coord, coord)) continue;
            counts[index] += 1;
            found = true;
            break;
        }
        if (!found) return error.UnknownSpawnSlotDistrict;
    }
    try std.testing.expectEqualSlices(usize, &.{ 12, 12, 4, 4 }, &counts);

    var unique_initial = [_]bool{false} ** population.max_spawn_slots;
    var ordinary_counts = [_]usize{0} ** recipe.installed_coords.len;
    for (members) |definition| {
        const index = definition.initial_spawn_slot.value - 1;
        try std.testing.expect(!unique_initial[index]);
        unique_initial[index] = true;
        if (!definition.ordinary_product) continue;
        const slot_definition = spawn_slots[index];
        for (recipe.installed_coords, 0..) |coord, district_index| {
            if (district.ChunkCoord.eql(slot_definition.anchor.coord, coord)) {
                ordinary_counts[district_index] += 1;
                break;
            }
        }
    }
    try std.testing.expectEqualSlices(usize, &.{ 3, 3, 3, 3 }, &ordinary_counts);
}

test "only authored P01 is hostile and identity rank is irrelevant" {
    var hostile: ?population.PopulationMemberId = null;
    for (members) |definition| {
        if (definition.combat_disposition != .hostile_to_players) continue;
        try std.testing.expect(hostile == null);
        hostile = definition.id;
    }
    try std.testing.expect(population.PopulationMemberId.eql(
        hostile orelse return error.MissingHostilePopulationMember,
        .{ .value = 1 },
    ));
}
