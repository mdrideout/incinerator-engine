//! Intentional public surface for Incinerator's thin simulation kernel.
//!
//! Backend adapters, SDL, renderer objects, editor state, Flecs identifiers,
//! and gameplay feature implementations are deliberately not re-exported.

const std = @import("std");

pub const contracts = @import("engine_contracts");
pub const identity = contracts.identity;
pub const transform = contracts.transform;
pub const diagnostic_contracts = contracts.diagnostics;
pub const physics = contracts.physics;
pub const physics_debug = contracts.physics_debug;
pub const rendering = contracts.rendering;
pub const fixed_step = @import("engine/fixed_step.zig");
pub const bounded_queue = @import("engine/bounded_queue.zig");
pub const diagnostics = @import("engine/diagnostics.zig");
pub const runtime = @import("engine/runtime.zig");

pub const PersistentId = identity.PersistentId;
pub const Pose = transform.Pose;
pub const Runtime = runtime.Runtime;
pub const RuntimeConfig = runtime.Config;
pub const RuntimeId = runtime.RuntimeId;
pub const FeatureRegistry = runtime.FeatureRegistry;
pub const Phase = runtime.Phase;
pub const PhaseOutcome = runtime.PhaseOutcome;
pub const PhaseObserver = runtime.PhaseObserver;
pub const TickContext = runtime.TickContext;
pub const BoundedQueue = bounded_queue.BoundedQueue;

test "public engine surface remains coherent" {
    std.testing.refAllDecls(identity);
    std.testing.refAllDecls(transform);
    std.testing.refAllDecls(diagnostic_contracts);
    std.testing.refAllDecls(physics);
    std.testing.refAllDecls(physics_debug);
    std.testing.refAllDecls(rendering);
    std.testing.refAllDecls(fixed_step);
    std.testing.refAllDecls(bounded_queue);
    std.testing.refAllDecls(diagnostics);
    std.testing.refAllDecls(runtime);
}
