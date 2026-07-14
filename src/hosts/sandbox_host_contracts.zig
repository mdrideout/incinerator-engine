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
pub const navigation_east_coord = sandbox_district_recipe.navigation_east_coord;
pub const navigation_west_coord = sandbox_district_recipe.navigation_west_coord;
pub const npc_capacity = npcs.max_npcs;
pub const snapshot_schema: u16 = 7;

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

test "graphical sandbox contracts publish values without mutable authority" {
    const Module = @This();
    try std.testing.expect(!@hasDecl(Module, "Simulation"));
    try std.testing.expect(!@hasDecl(Module, "save"));
    try std.testing.expect(!@hasDecl(Module, "tick"));

    const config = Config{ .namespace = 42 };
    try std.testing.expectEqual(@as(u64, 42), config.namespace);
    try std.testing.expectEqual(snapshot_schema, @as(u16, 7));
}
