//! Intentional public surface for Incinerator's thin simulation kernel.
//!
//! Backend adapters, SDL, renderer objects, editor state, Flecs identifiers,
//! and gameplay feature implementations are deliberately not re-exported.

const std = @import("std");

pub const contracts = @import("engine_contracts");
pub const identity = contracts.identity;
pub const transform = contracts.transform;
pub const physics = contracts.physics;
pub const rendering = contracts.rendering;
pub const runtime = @import("engine/runtime.zig");

pub const PersistentId = identity.PersistentId;
pub const Pose = transform.Pose;
pub const Runtime = runtime.Runtime;
pub const RuntimeConfig = runtime.Config;
pub const RuntimeId = runtime.RuntimeId;
pub const FeatureRegistry = runtime.FeatureRegistry;
pub const Phase = runtime.Phase;
pub const TickContext = runtime.TickContext;

test "public engine surface remains coherent" {
    std.testing.refAllDecls(identity);
    std.testing.refAllDecls(transform);
    std.testing.refAllDecls(physics);
    std.testing.refAllDecls(rendering);
    std.testing.refAllDecls(runtime);
}
