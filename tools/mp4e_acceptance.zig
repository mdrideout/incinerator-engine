//! MP4-E intentional saturation acceptance for acknowledged deltas, bounded
//! history, semantic degradation, and starvation recovery.

const std = @import("std");
const budgets = @import("session_budgets");
const session_client = @import("session_client");
const authority_module = @import("session_authority");

const total_ticks: u64 = 420;

pub fn main(init: std.process.Init) !void {
    _ = init;
    const authority = try authority_module.DedicatedAuthority.initWithOptions(
        std.heap.page_allocator,
        .{
            .downstream_bytes_per_second = 1_024,
            .full_snapshot_interval_ticks = 30,
        },
    );
    defer authority.deinit();
    var client = try session_client.Client.init(.{ .value = 40_005 });
    const connection = authority_module.TransportConnection{ .value = 1 };
    _ = try authority.openConnection(connection);
    try authority.ingest(connection, try client.begin());

    for (0..total_ticks) |_| {
        if (client.state == .joined and client.world.initialized and
            client.ownedVehicle() == null)
        {
            const target_tick = authority.diagnostics().tick + 1;
            try authority.ingest(connection, try client.input(
                target_tick,
                .{ 0, 1 },
                0,
                false,
            ));
        }
        try authority.tick();
        while (authority.pollOutbound()) |outbound| {
            if (outbound.close_after_send) return error.UnexpectedSessionClose;
            try client.receive(outbound.message);
            if (client.takeBaselineAck()) |ack| try authority.ingest(connection, ack);
            if (client.takeSnapshotAck()) |ack| try authority.ingest(connection, ack);
        }
    }

    const server = authority.diagnostics();
    const remote = client.diagnostics();
    if (server.active_npcs != budgets.product_npcs or client.world.npc_count == 0) {
        return error.SaturatedNpcProjectionNeverRecovered;
    }
    if (server.delta_snapshots_emitted == 0 or server.full_snapshot_fallbacks == 0 or
        server.snapshot_acks == 0 or remote.delta_snapshots_applied == 0 or
        remote.full_snapshots_applied == 0)
    {
        return error.DeltaLifecycleNotExercised;
    }
    if (server.npc_updates_deprioritized == 0 or
        server.snapshots_budget_deferred == 0 or server.starvation_sends == 0)
    {
        return error.OverloadDegradationNotExercised;
    }
    if (remote.delta_base_misses != 0 or server.stale_snapshot_acks != 0) {
        return error.DeltaBaselineDiverged;
    }
    if (server.baseline_memory_bytes > budgets.max_baseline_bytes_per_client or
        server.max_relevant_entities > budgets.max_relevant_entities_per_client or
        server.max_reliable_events_per_connection_tick > budgets.max_reliable_events_per_tick)
    {
        return error.ReplicationMemoryBudgetExceeded;
    }
    if (server.outbox_high_water >= budgets.outbound_message_capacity) {
        return error.OverloadQueueWasNotBounded;
    }

    std.debug.print(
        "MP4E_SATURATION_PASS deltas={d} full_fallbacks={d} acks={d} " ++
            "npc_deprioritized={d} deferred={d} starvation={d} bytes={d} " ++
            "baseline_memory={d} relevant_max={d} client_npcs={d}\n",
        .{
            server.delta_snapshots_emitted,
            server.full_snapshot_fallbacks,
            server.snapshot_acks,
            server.npc_updates_deprioritized,
            server.snapshots_budget_deferred,
            server.starvation_sends,
            server.snapshot_bytes_emitted,
            server.baseline_memory_bytes,
            server.max_relevant_entities,
            client.world.npc_count,
        },
    );
}
