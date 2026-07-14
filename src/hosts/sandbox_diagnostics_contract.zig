//! Canonical immutable diagnostics returned by sandbox authority placements.
//!
//! This module contains copied values only. It cannot gather runtime state and
//! has no dependency on feature implementations, physics adapters, replay, or
//! storage.

const engine = @import("incinerator_engine");
const crates = @import("crate_contract");
const characters = @import("character_contract");
const vehicles = @import("vehicle_contract");
const districts = @import("district_feature_contract");
const interactions = @import("interaction_feature_contract");
const npcs = @import("npc_contract");
const district_worker = @import("district_worker_contract");

pub const CharacterControllerDiagnostics = struct {
    /// Physics-global CharacterVirtual handles owned by the shared world.
    native_used: u32,
    native_capacity: u32,
    /// Controllers currently attached to character and NPC feature authority.
    feature_owned: u32,
    /// False exposes a leaked, duplicated, untracked, or over-capacity handle.
    authority_consistent: bool,
};

pub const Diagnostics = struct {
    tick_index: u64,
    fixed_delta_seconds: f32,
    first_fault: ?engine.runtime.RuntimeFault,
    entity_count: u32,
    body_count: u32,
    active_body_count: u32,
    character_controllers: CharacterControllerDiagnostics,
    crates: crates.Diagnostics,
    characters: characters.Diagnostics,
    vehicles: vehicles.Diagnostics,
    district: districts.Diagnostics,
    interaction: interactions.Diagnostics,
    npc: npcs.Diagnostics,
    district_worker: district_worker.Diagnostics,
};

test "sandbox diagnostics expose no mutable authority" {
    const Module = @This();
    try @import("std").testing.expect(!@hasDecl(Module, "Simulation"));
    try @import("std").testing.expect(!@hasDecl(Module, "tick"));
}
