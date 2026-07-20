//! Canonical value contract for the carry-interaction gameplay slice.

const std = @import("std");
const engine = @import("engine_contracts");
const district_contract = @import("district_contract");

pub const max_carryables: usize = 1;
pub const max_pending_commands: usize = 16;
pub const max_outcomes: usize = 16;

pub const Budget = struct {
    carryables: u32 = max_carryables,
    dynamic_bodies: u32 = max_carryables,
    commands: u32 = max_pending_commands,
    outcomes: u32 = max_outcomes,
};

pub const declared_budget = Budget{};

pub const Config = struct {
    collect_range: f32 = 2.5,
    /// One deterministic local-space offset from the authoritative carrier
    /// pose. Spatial ownership is independent of streamed district residency.
    drop_offset: [3]f32 = .{ 0, 0.75, -1.5 },

    pub fn validate(self: Config) !void {
        if (!std.math.isFinite(self.collect_range) or self.collect_range <= 0) {
            return error.InvalidCollectRange;
        }
        for (self.drop_offset) |component| {
            if (!std.math.isFinite(component)) return error.InvalidDropOffset;
        }
    }
};

/// Simulation-relevant cold configuration persisted/fingerprinted by the
/// composition root. It is separate from Config so future presentation-only
/// fields cannot accidentally enter the world cohort.
pub const InteractionConfigV1 = struct {
    collect_range: f32,
    drop_offset: [3]f32,

    pub fn fromConfig(config: Config) InteractionConfigV1 {
        return .{
            .collect_range = config.collect_range,
            .drop_offset = config.drop_offset,
        };
    }

    pub fn toConfig(self: InteractionConfigV1) !Config {
        const config = Config{
            .collect_range = self.collect_range,
            .drop_offset = self.drop_offset,
        };
        try config.validate();
        return config;
    }

    pub fn validate(self: InteractionConfigV1) !void {
        _ = try self.toConfig();
    }
};

/// Durable ownership is closed over a live spatial world object and an
/// inventory-held object. The coordinate indexes the world object; authored
/// district residency never controls whether it exists or may be dropped.
pub const Ownership = union(enum) {
    spatially_owned: district_contract.ChunkCoord,
    inventory_held: engine.PersistentId,
};

pub const SpawnCarryable = struct {
    request_id: u64,
    pose: engine.physics.Pose,
    velocity: engine.physics.Velocity = .{},
    half_extents: [3]f32 = .{ 0.35, 0.35, 0.35 },
};

pub const DespawnCarryable = struct { id: engine.PersistentId };

pub const Collect = struct {
    transaction_id: u64,
    carrier_id: engine.PersistentId,
    carryable_id: engine.PersistentId,
};

pub const DropPurpose = enum(u8) {
    player_requested = 1,
    forced_cleanup = 2,
};

pub const Drop = struct {
    transaction_id: u64,
    carrier_id: engine.PersistentId,
    carryable_id: engine.PersistentId,
    purpose: DropPurpose,
};

pub const Command = union(enum) {
    spawn: SpawnCarryable,
    despawn: DespawnCarryable,
    collect: Collect,
    drop: Drop,
};

pub const CommandKind = enum { spawn, despawn, collect, drop };

pub const RejectionReason = enum {
    capacity_reached,
    carryable_not_found,
    not_owned,
    carryable_already_held,
    carryable_held,
    carrier_not_found,
    carrier_not_on_foot,
    carrier_not_empty,
    carrier_not_holding,
    wrong_holder,
    too_far,
};

pub const CommandRejected = struct {
    command: CommandKind,
    reason: RejectionReason,
    request_id: ?u64 = null,
    transaction_id: ?u64 = null,
    carrier_id: ?engine.PersistentId = null,
    carryable_id: ?engine.PersistentId = null,
};

pub const Spawned = struct {
    request_id: u64,
    id: engine.PersistentId,
    owner: district_contract.ChunkCoord,
};

pub const Collected = struct {
    transaction_id: u64,
    carrier_id: engine.PersistentId,
    carryable_id: engine.PersistentId,
    previous_owner: district_contract.ChunkCoord,
};

pub const Dropped = struct {
    transaction_id: u64,
    carrier_id: engine.PersistentId,
    carryable_id: engine.PersistentId,
    owner: district_contract.ChunkCoord,
    pose: engine.physics.Pose,
    placement: DropPlacement,
};

/// Explains the deterministic placement choice without changing the action's
/// terminal success semantics.
pub const DropPlacement = enum {
    configured_offset,
};

pub const Outcome = union(enum) {
    spawned: Spawned,
    despawned: engine.PersistentId,
    collected: Collected,
    dropped: Dropped,
    rejected: CommandRejected,
};

pub const CarryableView = struct {
    id: engine.PersistentId,
    half_extents: [3]f32,
    ownership: Ownership,
    state: engine.physics.BodyState,
    body_present: bool,
};

/// Renderer-neutral extraction. For a held object, `pose` follows the carrier
/// at a fixed cohort-local attachment offset while `CarryableView.state`
/// continues to expose the durable last world-body state used by save/replay.
pub const CarryableDraw = struct {
    persistent_id: engine.PersistentId,
    pose: engine.physics.Pose,
    half_extents: [3]f32,
    ownership: Ownership,
};

pub const Diagnostics = struct {
    active_count: u32,
    spatially_owned_count: u32,
    held_count: u32,
    dynamic_body_count: u32,
    commands: engine.diagnostics.QueueStats,
    outcomes: engine.diagnostics.QueueStats,
};

/// Feature-owned persistence record. The host owns world schema, clock,
/// identity cursor, and cross-feature validation/order.
pub const InteractionV1 = struct {
    id: engine.PersistentId,
    half_extents: [3]f32,
    ownership: Ownership,
    pose: engine.physics.Pose,
    linear_velocity: [3]f32,
    angular_velocity: [3]f32,
};

pub fn validateRecords(records: []const InteractionV1) !void {
    if (records.len > max_carryables) return error.TooManyCarryables;
    for (records) |record| {
        try record.id.validate();
        switch (record.ownership) {
            .spatially_owned => {},
            .inventory_held => |holder| try holder.validate(),
        }
        try (engine.physics.DynamicBoxDesc{
            .pose = record.pose,
            .velocity = .{
                .linear = record.linear_velocity,
                .angular = record.angular_velocity,
            },
            .half_extents = record.half_extents,
        }).validate();
    }
}

test "interaction contract validates its default configuration" {
    try (Config{}).validate();
}
