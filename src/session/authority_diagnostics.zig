//! Canonical copied diagnostics for one authoritative session placement.
//!
//! This contract contains values only. It does not import the authority
//! implementation, simulation, transport, renderer, editor, or storage.

const engine = @import("incinerator_engine");

pub const CycleStage = enum {
    ingress_freeze,
    admission,
    semantic_work,
    simulation,
    outcome_drain,
    derivative_preparation,
    durable_disposition,
    publication,
};

pub const CycleFault = struct {
    stage: CycleStage,
    target_tick: u64,
    completed_tick: u64,
    error_code: engine.runtime.RuntimeErrorCode,
    error_name: engine.runtime.FaultText,
};

/// Completion-aware evidence for the mutation-bearing authority portion of
/// one fixed tick. Transport and client delivery belong to placement traces.
pub const CycleTrace = struct {
    target_tick: u64 = 0,
    completed_tick_before: u64 = 0,
    completed_tick_after: u64 = 0,
    stages: [8]CycleStage = @splat(.ingress_freeze),
    count: u8 = 0,
    failed_stage: ?CycleStage = null,
};

pub const Diagnostics = struct {
    tick: u64,
    last_cycle: CycleTrace,
    first_cycle_fault: ?CycleFault,
    active_connections: u16,
    active_participants: u16,
    alive_participants: u16,
    dead_participants: u16,
    spawning_participants: u16,
    active_vehicles: u16,
    active_carryables: u16,
    active_npcs: u16,
    connected_participants: u16,
    reconnecting_participants: u16,
    mailbox_occupancy: u16,
    mailbox_high_water: u16,
    mailbox_rejected: u64,
    outbox_occupancy: u16,
    outbox_high_water: u16,
    outbound_lease_active: bool,
    reliable_replay_records: u16,
    delivery_receipts: u64,
    reliable_replays: u64,
    slow_gameplay_consumers_retired: u64,
    accepted_messages: u64,
    rejected_messages: u64,
    malformed_messages: u64,
    snapshots_emitted: u64,
    reconnects: u64,
    stale_inputs: u64,
    quota_violations: u64,
    invalid_control_inputs: u64,
    vehicle_actions_accepted: u64,
    vehicle_actions_rejected: u64,
    stale_vehicle_actions: u64,
    forced_vehicle_cleanup: u64,
    interaction_actions_accepted: u64,
    interaction_actions_rejected: u64,
    stale_interaction_actions: u64,
    forced_interaction_cleanup: u64,
    melee_actions_admitted: u64,
    melee_hits: u64,
    deaths: u64,
    respawns: u64,
    baselines_emitted: u64,
    baselines_acknowledged: u64,
    stale_baseline_acks: u64,
    relevance_transfers: u64,
    npc_state_updates: u64,
    delta_snapshots_emitted: u64,
    full_snapshots_emitted: u64,
    snapshot_acks: u64,
    stale_snapshot_acks: u64,
    snapshot_bytes_emitted: u64,
    npc_updates_deprioritized: u64,
    snapshots_budget_deferred: u64,
    starvation_sends: u64,
    full_snapshot_fallbacks: u64,
    baseline_memory_bytes: usize,
    max_relevant_entities: u16,
    max_reliable_events_per_connection_tick: u16,
    ingress_entries: u16,
    ingress_high_water: u16,
    ingress_overwrites: u64,
    ingress_fingerprint: u64,
};

test "authority diagnostics contract contains no authority implementation" {
    const Module = @This();
    try @import("std").testing.expect(!@hasDecl(Module, "Authority"));
    try @import("std").testing.expect(!@hasDecl(Module, "Simulation"));
}
