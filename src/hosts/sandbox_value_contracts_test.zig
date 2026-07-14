//! Focused type-identity and implementation-closure proof for sandbox values.

const std = @import("std");
const crates = @import("crate_contract");
const characters = @import("character_contract");
const vehicles = @import("vehicle_contract");
const districts = @import("district_feature_contract");
const interactions = @import("interaction_feature_contract");
const npcs = @import("npc_contract");
const district_worker = @import("district_worker_contract");
const diagnostics = @import("sandbox_diagnostics_contract");
const sandbox = @import("sandbox_host_contracts");

test "host vocabulary preserves canonical feature type identity" {
    comptime {
        if (sandbox.Command != crates.Command) @compileError("crate command type drift");
        if (sandbox.CharacterConfig != characters.Config) {
            @compileError("character config type drift");
        }
        if (sandbox.VehicleCommandRejected != vehicles.CommandRejected) {
            @compileError("vehicle rejection type drift");
        }
        if (sandbox.InteractionCommand != interactions.Command) {
            @compileError("interaction command type drift");
        }
        if (sandbox.NpcOutcome != npcs.Outcome) @compileError("NPC outcome type drift");
        if (@FieldType(diagnostics.Diagnostics, "district") != districts.Diagnostics) {
            @compileError("district diagnostic type drift");
        }
        if (@FieldType(diagnostics.Diagnostics, "district_worker") != district_worker.Diagnostics) {
            @compileError("district worker diagnostic type drift");
        }
        if (sandbox.Diagnostics != diagnostics.Diagnostics) {
            @compileError("sandbox diagnostic type drift");
        }
    }

    std.testing.refAllDecls(crates);
    std.testing.refAllDecls(characters);
    std.testing.refAllDecls(vehicles);
    std.testing.refAllDecls(districts);
    std.testing.refAllDecls(interactions);
    std.testing.refAllDecls(npcs);
    std.testing.refAllDecls(district_worker);
    std.testing.refAllDecls(diagnostics);
}
