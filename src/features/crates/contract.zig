//! Canonical value contract for the crate gameplay slice.
//!
//! This module owns every value that crosses the crate implementation
//! boundary. It contains no ECS components, runtime state, physics backend, or
//! feature systems; the implementation and every host import this same module
//! instance so Zig type identity cannot drift.

const std = @import("std");
const engine = @import("engine_contracts");

/// Per-world authority budgets. Every accepted command retains one outcome
/// reservation until it is applied (or, for relocation, post-physics commit).
pub const max_pending_commands: usize = 128;
pub const max_outcomes: usize = 128;

pub const Budget = struct {
    commands: u32 = max_pending_commands,
    outcomes: u32 = max_outcomes,
};

pub const declared_budget = Budget{};

pub const Assets = struct {
    mesh: engine.rendering.MeshHandle = .invalid,
    material: engine.rendering.MaterialHandle = .invalid,
};

pub const SpawnCrate = struct {
    request_id: u64,
    pose: engine.physics.Pose,
    velocity: engine.physics.Velocity = .{},
    half_extents: [3]f32 = .{ 0.5, 0.5, 0.5 },
};

pub const DespawnEntity = struct { id: engine.PersistentId };
pub const ApplyImpulse = struct {
    id: engine.PersistentId,
    impulse: [3]f32,
};

/// How a relocation derives the authoritative velocity installed with its
/// target pose. `preserve` samples the body at the commit boundary, `zero`
/// deliberately stops it, and `exact` supports precise undo/redo change sets.
pub const RelocationVelocity = union(enum) {
    preserve,
    zero,
    exact: engine.physics.Velocity,
};

pub const RelocateCrate = struct {
    transaction_id: u64,
    id: engine.PersistentId,
    target_pose: engine.physics.Pose,
    velocity: RelocationVelocity = .zero,
    /// Optimistic authoring concurrency, intentionally independent of ordinary
    /// physics motion. Revision zero is the initial/restored crate revision.
    expected_revision: ?u64 = null,
};

pub const Command = union(enum) {
    spawn: SpawnCrate,
    despawn: DespawnEntity,
    impulse: ApplyImpulse,
    relocate: RelocateCrate,
};

pub const Spawned = struct {
    request_id: u64,
    id: engine.PersistentId,
};

pub const Relocated = struct {
    transaction_id: u64,
    id: engine.PersistentId,
    before: engine.physics.BodyState,
    after: engine.physics.BodyState,
    committed_revision: u64,
};

pub const CommandKind = enum { spawn, despawn, impulse, relocate };
pub const RejectionReason = enum {
    capacity_reached,
    crate_not_found,
    not_owned,
    state_conflict,
};
pub const CommandRejected = struct {
    command: CommandKind,
    reason: RejectionReason,
    request_id: ?u64 = null,
    transaction_id: ?u64 = null,
    id: ?engine.PersistentId = null,
    expected_revision: ?u64 = null,
    actual_revision: ?u64 = null,
};

pub const Outcome = union(enum) {
    spawned: Spawned,
    despawned: engine.PersistentId,
    impulse_applied: engine.PersistentId,
    relocated: Relocated,
    rejected: CommandRejected,
};

pub const CrateView = struct {
    id: engine.PersistentId,
    half_extents: [3]f32,
    state: engine.physics.BodyState,
    authoring_revision: u64,
};

/// Immutable feature-owned presentation record. It contains no backend
/// pointers and transfers no resource ownership.
pub const CrateDraw = struct {
    persistent_id: engine.PersistentId,
    pose: engine.physics.Pose,
    half_extents: [3]f32,
    mesh: engine.rendering.MeshHandle,
    material: engine.rendering.MaterialHandle,
};

pub const Diagnostics = struct {
    active_count: u32,
    commands: engine.diagnostics.QueueStats,
    outcomes: engine.diagnostics.QueueStats,
};

pub const CrateV1 = struct {
    id: engine.PersistentId,
    half_extents: [3]f32,
    pose: engine.physics.Pose,
    linear_velocity: [3]f32,
    angular_velocity: [3]f32,
};

/// Validate only the crate-owned portion of a composed snapshot. World schema,
/// clock, namespace, identity-cursor, and cross-feature identity validation
/// belong to the composition that owns the complete persistence envelope.
pub fn validateRecords(records: []const CrateV1, max_crates: usize) !void {
    if (records.len > max_crates) return error.TooManyCrates;

    for (records, 0..) |record, index| {
        try record.id.validate();
        try (engine.physics.DynamicBoxDesc{
            .pose = record.pose,
            .velocity = .{
                .linear = record.linear_velocity,
                .angular = record.angular_velocity,
            },
            .half_extents = record.half_extents,
        }).validate();
        for (records[0..index]) |earlier| {
            if (std.meta.eql(earlier.id, record.id)) return error.DuplicatePersistentId;
        }
    }
}

test "crate contract is backend-handle free value vocabulary" {
    const command = Command{ .spawn = .{ .request_id = 1, .pose = .{} } };
    try std.testing.expectEqual(@as(u64, 1), command.spawn.request_id);
    try std.testing.expectEqual(@as(usize, 128), max_outcomes);
}
