//! Stable DTO and construction vocabulary shared by sandbox hosts.
//!
//! This is a contract boundary, not a façade over the mutable simulation. Visual
//! composition, editor tooling, persistence policy, and authority internals
//! may all depend on these value types without gaining access to `Simulation`.

const std = @import("std");
const engine = @import("engine_contracts");
const crates = @import("crate_contract");
const characters = @import("character_contract");
const vehicles = @import("vehicle_contract");
const districts = @import("district_contract");
const interactions = @import("interaction_feature_contract");
const npcs = @import("npc_contract");
const npc_encounters = @import("npc_encounter_contract");
const sandbox_district_recipe = @import("sandbox_district_recipe");
const sandbox_diagnostics = @import("sandbox_diagnostics_contract");

pub const CharacterConfig = characters.Config;
pub const CharacterView = characters.CharacterView;
pub const CarryableView = interactions.CarryableView;
pub const ChunkCoord = districts.ChunkCoord;
pub const Command = crates.Command;
pub const Diagnostics = sandbox_diagnostics.Diagnostics;
pub const InteractionCommand = interactions.Command;
pub const InteractionOutcome = interactions.Outcome;
pub const LoadTicket = districts.LoadTicket;
pub const NavigationNodeRef = npcs.NodeRef;
pub const NpcEvent = npcs.Event;
pub const NpcOutcome = npcs.Outcome;
pub const NpcState = npcs.State;
pub const PersistentId = engine.PersistentId;
pub const RejectionReason = crates.RejectionReason;
pub const VehicleCommandRejected = vehicles.CommandRejected;
pub const VehicleConfig = vehicles.Config;

pub const district_presentation_policies = sandbox_district_recipe.presentation_policies;
pub const district_static_box_count: u32 = sandbox_district_recipe.static_box_count;
pub const district_blocking_proxy_count: u8 = sandbox_district_recipe.blocking_proxy_count;
pub const navigation_east_coord = sandbox_district_recipe.navigation_east_coord;
pub const navigation_west_coord = sandbox_district_recipe.navigation_west_coord;
pub const npc_capacity = npcs.max_npcs;
pub const snapshot_schema: u16 = 11;
pub const DistrictPresentationPlan = sandbox_district_recipe.PresentationPlan;

/// Default playable product spawn and the local movement envelope guaranteed
/// clear before the asynchronous west district is admitted to authority.
pub const default_character_spawn_position = [3]f32{ -2, 0, 4 };
pub const default_character_spawn_clearance: f32 = 0.5;
pub const default_character_initial_traversal: f32 = 1.0;

/// Renderer-neutral optional collision primitive in the sandbox recipe.
pub const StaticBox = struct {
    position: [3]f32,
    half_extents: [3]f32,
};

/// Cold construction identity shared by every sandbox authority placement.
///
/// This record intentionally contains only value configuration. In
/// particular, it does not expose a simulation handle or host lifecycle.
pub const Config = struct {
    namespace: u64,
    fixed_delta_seconds: f32 = 1.0 / 60.0,
    max_crates: usize = 1024,
    assets: crates.Assets = .{},
    create_ground: bool = true,
    character: CharacterConfig = .{},
    vehicle: VehicleConfig = .{},
    interaction: interactions.Config = .{},
    npc: npcs.Config = .{},
    npc_encounter: npc_encounters.Config = .{},
    block: ?StaticBox = null,
};

/// Renderer-neutral logical recipe used to reject cooked visual/collision
/// drift before the visual host submits a production district request.
pub fn proceduralDistrictBuild(coord: ChunkCoord) !districts.DistrictBuild {
    return switch (sandbox_district_recipe.build(
        coord,
        sandbox_district_recipe.current_recipe_version,
    )) {
        .ready => |build| build,
        .failed => error.InvalidDistrictRecipe,
    };
}

/// Keep the renderer's authored scene and mandatory collision proxies under
/// one renderer-neutral product contract.
pub fn districtPresentationPlan(
    build: *const districts.DistrictBuild,
    authored_scene_resident: bool,
) !DistrictPresentationPlan {
    return sandbox_district_recipe.presentationPlan(build, authored_scene_resident);
}

/// Reject product bootstrap if a recipe change makes the default capsule or
/// its first metre of camera-relative movement intersect a blocking box.
pub fn validateDefaultCharacterSpawn(config: CharacterConfig) !void {
    try config.validate();
    const west = try proceduralDistrictBuild(navigation_west_coord);
    const clearance = sandbox_district_recipe.CapsuleClearance{
        .radius = config.radius,
        .half_height = config.half_height,
        .margin = default_character_spawn_clearance,
    };
    if (!sandbox_district_recipe.capsuleTraversalClear(
        &west,
        default_character_spawn_position,
        default_character_spawn_position,
        clearance,
    )) return error.DefaultCharacterSpawnBlocked;

    const diagonal = default_character_initial_traversal * 0.70710677;
    for ([_][2]f32{
        .{ -default_character_initial_traversal, 0 },
        .{ default_character_initial_traversal, 0 },
        .{ 0, -default_character_initial_traversal },
        .{ 0, default_character_initial_traversal },
        .{ -diagonal, -diagonal },
        .{ -diagonal, diagonal },
        .{ diagonal, -diagonal },
        .{ diagonal, diagonal },
    }) |offset| {
        const destination = [3]f32{
            default_character_spawn_position[0] + offset[0],
            default_character_spawn_position[1],
            default_character_spawn_position[2] + offset[1],
        };
        if (!sandbox_district_recipe.capsuleTraversalClear(
            &west,
            default_character_spawn_position,
            destination,
            clearance,
        )) return error.DefaultCharacterInitialTraversalBlocked;
    }
}

/// Validate every installed route edge with the canonical NPC capsule against
/// every blocker it can cross. Topology alone cannot guarantee a traversable
/// route after either collision geometry or NPC dimensions change.
pub fn validateCanonicalNavigationClearance(config: npcs.Config) !void {
    try config.validate();
    const builds = [_]districts.DistrictBuild{
        try proceduralDistrictBuild(navigation_west_coord),
        try proceduralDistrictBuild(navigation_east_coord),
    };
    try sandbox_district_recipe.validateRoute(&builds);
    const clearance = sandbox_district_recipe.CapsuleClearance{
        .radius = config.radius,
        .half_height = config.half_height,
        .margin = config.arrival_distance,
    };
    for (builds) |source_build| {
        for (source_build.navigationNodes()) |source| {
            const first: usize = source.first_edge;
            const end = first + source.edge_count;
            for (source_build.navigationEdges()[first..end]) |edge| {
                const target_build = if (districts.ChunkCoord.eql(
                    edge.target.coord,
                    navigation_west_coord,
                ))
                    &builds[0]
                else if (districts.ChunkCoord.eql(
                    edge.target.coord,
                    navigation_east_coord,
                ))
                    &builds[1]
                else
                    return error.CanonicalNavigationTargetMissing;
                if (edge.target.index >= target_build.navigation_node_count) {
                    return error.CanonicalNavigationTargetMissing;
                }
                const target = target_build.navigation_nodes[edge.target.index];
                for (builds) |collision_build| {
                    if (!sandbox_district_recipe.capsuleTraversalClear(
                        &collision_build,
                        source.position,
                        target.position,
                        clearance,
                    )) return error.CanonicalNavigationEdgeBlocked;
                }
            }
        }
    }
}

test "graphical sandbox contracts publish values without mutable authority" {
    const Module = @This();
    try std.testing.expect(!@hasDecl(Module, "Simulation"));
    try std.testing.expect(!@hasDecl(Module, "save"));
    try std.testing.expect(!@hasDecl(Module, "tick"));

    const config = Config{ .namespace = 42 };
    try std.testing.expectEqual(@as(u64, 42), config.namespace);
    try std.testing.expectEqual(snapshot_schema, @as(u16, 11));
}

test "default playable spawn and initial traversal clear canonical blockers" {
    try validateDefaultCharacterSpawn(.{});
    try validateCanonicalNavigationClearance(.{});

    const west = try proceduralDistrictBuild(navigation_west_coord);
    const staged = try districtPresentationPlan(&west, false);
    const resident = try districtPresentationPlan(&west, true);
    try std.testing.expectEqual(district_blocking_proxy_count, staged.proxy_box_count);
    try std.testing.expectEqualSlices(u8, staged.proxyBoxIndices(), resident.proxyBoxIndices());
}
