//! Deterministic, SDL-free M3 pre-server-readiness soak gate.
//!
//! This is deliberately not a server or transport simulation. It drives the
//! real one-world headless authority through the bounded producer seam, proves
//! exact internal/router saturation, recovery, and completion ownership, and
//! inventories feature queue peaks. The product test cohort separately proves
//! every feature queue's full-capacity behavior. This gate then exercises the
//! durable restart boundary after destroying the original authority.

const std = @import("std");
const builtin = @import("builtin");
const simulation = @import("sandbox_simulation");
const simulation_snapshot = @import("simulation_snapshot");
const sandbox_contracts = @import("sandbox_host_contracts");
const sandbox_diagnostics = @import("sandbox_diagnostics_contract");
const crate_feature = @import("crate_contract");
const headless_authority = @import("headless_authority");
const external_producers = @import("external_producers");
const sandbox_save = @import("sandbox_save");

const schema_version: u16 = 2;
const routine_ticks: u64 = 32_768;
const long_ticks: u64 = 131_072;
const workload_period_ticks: u64 = 64;
const district_progress_limit: usize = 10_000;
const namespace: u64 = 93_001;
const producer_count: usize = 2;
const expected_internal_non_relocation_handbacks: u64 =
    headless_authority.internal_outcome_capacity + 1;
const config_cohort = "m3-config-v1:namespace=93001,crates=8,characters=1,vehicles=1,npcs=64,ground=true,producers=2,quota=8,ingress=16,transactions=16,results=8";
const scenario_cohort = "m3-scenario-v3:district-cancel-activate-unload-reload,s2-live-vehicle,s7-collect-drop,s8-64-npcs,two-producer-relocation-saturation,draining-stop,canonical-cold-restore";
const content_cohort = "incinerator.m3.logical-content.v1";

const p99_ceiling_ns: u64 = std.time.ns_per_s / 120;
const snapshot_ceiling_bytes: usize = 128 * 1024;
const envelope_ceiling_bytes: usize = 128 * 1024;
const allocator_peak_ceiling_bytes: usize = 64 * 1024 * 1024;
const rss_ceiling_bytes: usize = 128 * 1024 * 1024;

const CrateId = @FieldType(crate_feature.RelocateCrate, "id");
const west = sandbox_contracts.navigation_west_coord;
const east = sandbox_contracts.navigation_east_coord;
const west_node = sandbox_contracts.NavigationNodeRef{ .coord = west, .index = 0 };
const east_node = sandbox_contracts.NavigationNodeRef{ .coord = east, .index = 2 };

const Mode = enum { routine, long };

const Invocation = union(enum) {
    help,
    run: Mode,
};

const Distribution = struct {
    samples: u64,
    total_ns: u64,
    mean_ns: f64,
    p50_ns: u64,
    p95_ns: u64,
    p99_ns: u64,
    max_ns: u64,
};

const CohortProof = struct {
    digest_encoding: []const u8 = "sha256_raw_bytes",
    zig_version: []const u8,
    optimize: []const u8,
    target_arch: []const u8,
    target_os: []const u8,
    target_abi: []const u8,
    simulation_build_digest: sandbox_save.Digest,
    world_config_digest: sandbox_save.Digest,
    content_digest: sandbox_save.Digest,
    config_cohort: []const u8,
    config_cohort_digest: sandbox_save.Digest,
    scenario_cohort: []const u8,
    scenario_cohort_digest: sandbox_save.Digest,
    world_namespace: u64,
    max_crates: u32,
    max_characters: u32,
    max_vehicles: u32,
    max_npcs: u32,
    create_ground: bool,
};

const PerformanceProof = struct {
    clock: []const u8 = "awake",
    authority_tick: Distribution,
    authority_ticks_per_second: f64,
    whole_run_elapsed_ns: u64,
    whole_run_ticks_per_second: f64,
};

const ResourceProof = struct {
    allocator: []const u8 = "tracking_allocator_over_process_gpa",
    allocator_peak_bytes: usize,
    allocator_final_live_bytes: usize,
    rss: []const u8 = "fresh_workload_process_getrusage_maxrss",
    max_rss_bytes: usize,
};

const CeilingProof = struct {
    p99_authority_tick_ns: u64 = p99_ceiling_ns,
    snapshot_payload_bytes: usize = snapshot_ceiling_bytes,
    save_envelope_bytes: usize = envelope_ceiling_bytes,
    allocator_peak_bytes: usize = allocator_peak_ceiling_bytes,
    max_rss_bytes: usize = rss_ceiling_bytes,
    all_passed: bool,
};

const QueueSummary = struct {
    capacity: u32,
    high_water: u32,
    rejected: u64,
    final_occupancy: u32,
};

const FeatureQueueInventory = struct {
    crate_commands: QueueSummary,
    crate_outcomes: QueueSummary,
    character_commands: QueueSummary,
    character_outcomes: QueueSummary,
    character_events: QueueSummary,
    character_event_drops: u64,
    vehicle_commands: QueueSummary,
    vehicle_outcomes: QueueSummary,
    vehicle_events: QueueSummary,
    vehicle_event_drops: u64,
    district_commands: QueueSummary,
    district_outcomes: QueueSummary,
    district_outcome_reservation_high_water: u32,
    district_outcome_final_reservations: u32,
    district_events: QueueSummary,
    interaction_commands: QueueSummary,
    interaction_outcomes: QueueSummary,
    npc_commands: QueueSummary,
    npc_outcomes: QueueSummary,
    npc_events: QueueSummary,
    npc_event_drop_state_changed: u64,
    npc_event_drop_owner_transferred: u64,
    npc_event_drop_goal_reached: u64,
};

const ProducerSlotInventory = struct {
    result_queue: QueueSummary,
    delivery_queue: QueueSummary,
    pending_high_water: u32,
    admission_rejected: u64,
    final_pending: u32,
    final_unread_results: u32,
};

const ProducerInventory = struct {
    registration_attempts: u64,
    registrations_succeeded: u64,
    registrations_rejected: u64,
    accepted_transactions: u64,
    retry_later_transactions: u64,
    rejected_transactions: u64,
    completed_transactions: u64,
    terminal_submission_rejections: u64,
    outcomes_handed_back: u64,
    expected_internal_non_relocation_handbacks: u64,
    protocol_fault_handbacks: u64,
    final_registered: u32,
    final_unread_results: u32,
    producer_slots: [producer_count]ProducerSlotInventory,
    producers: QueueSummary,
    ingress: QueueSummary,
    transactions: QueueSummary,
    delivery: QueueSummary,
    rejection_counters: external_producers.RejectionCounters,
};

const FinalOwnershipProof = struct {
    entities: u32,
    rigid_bodies: u32,
    active_rigid_bodies: u32,
    character_virtual_used: u32,
    character_virtual_capacity: u32,
    feature_owned_controllers: u32,
    vehicles: u32,
    district_worker_state: []const u8,
    district_worker_generation: ?u64,
    district_worker_started: bool,
    presentation_extractions: u32,
    renderer_or_gpu_resources: u32,
    live_worlds_after_cleanup: u32,
    live_authorities_after_cleanup: u32,
    native_ownership_released: bool,
};

const OperationalProof = struct {
    healthy_backpressure: []const u8 = "bounded_internal_outcome_saturation",
    healthy_backpressure_recovered: bool,
    injected_failure: []const u8 = "none_in_logical_soak",
    injected_failure_recovered: bool,
    runtime_first_fault: bool,
    failure_recovery_result: []const u8 = "covered_by_installed_lifecycle_gate",
    drain_result: []const u8 = "accepted_work_drained",
    signal_result: []const u8 = "covered_by_installed_lifecycle_gate",
    durable_save_result: []const u8 = "covered_by_installed_lifecycle_gate",
    logical_save_disposition: []const u8 = "canonical_in_memory_envelope",
};

const ProducerProof = struct {
    registered: u32,
    registration_capacity_rejection: bool,
    submitted: [producer_count]u64,
    completed: [producer_count]u64,
    completion_isolation: bool,
    shutdown_admission_rejection: bool,
};

const SaturationProof = struct {
    internal_admission_capacity: u32,
    emergency_evidence_slots: u32,
    internal_outcome_queue_full: bool,
    internal_outcome_peak: u32,
    internal_recovered: bool,
    producer_pending_quota: u32,
    producer_quota_full: bool,
    producer_ingress_capacity: u32,
    producer_ingress_full: bool,
    producer_transaction_capacity: u32,
    producer_transaction_table_full: bool,
    producer_delivery_capacity: u32,
    producer_result_capacity_full: bool,
    producer_recovered: bool,
};

const QueueProof = struct {
    post_warmup_observations: u64,
    all_world_queues_declared_capacity: bool,
    capacities_stable: bool,
    producer_capacity: u32,
    ingress_capacity: u32,
    ingress_high_water: u32,
    post_warmup_ingress_peak: u32,
    transaction_capacity: u32,
    transaction_high_water: u32,
    post_warmup_transaction_peak: u32,
    delivery_capacity: u32,
    delivery_high_water: u32,
    post_warmup_delivery_peak: u32,
    internal_outcome_capacity: u32,
    internal_outcome_high_water: u32,
    internal_outcome_reservation_high_water: u32,
    internal_outcome_admission_rejections: u64,
    post_warmup_internal_outcome_peak: u32,
    final_ingress_occupancy: u32,
    final_transaction_occupancy: u32,
    final_delivery_occupancy: u32,
    final_internal_outcome_occupancy: u32,
    final_internal_outcome_reservations: u32,
    final_district_outcome_reservations: u32,
};

const IntegratedSlicesProof = struct {
    cancellation_completed: bool,
    unload_reload_completed: bool,
    active_districts: u32,
    district_bodies: u32,
    active_characters: u32,
    active_vehicles: u32,
    active_carryables: u32,
    carryable_dynamic_bodies: u32,
    active_npcs: u32,
    native_physics_bodies: u32,
    native_character_controllers: u32,
    native_character_controller_capacity: u32,
    collect_completed: bool,
    drop_completed: bool,
    typed_events_drained: u64,
    restored_districts: u32,
    restored_district_bodies: u32,
    restored_characters: u32,
    restored_vehicles: u32,
    restored_carryables: u32,
    restored_carryable_dynamic_bodies: u32,
    restored_npcs: u32,
    restored_native_physics_bodies: u32,
    restored_native_character_controllers: u32,
    restored_ownership_exact: bool,
    final_and_restored_queues_empty: bool,
};

const ShutdownProof = struct {
    accepted_work_drained: bool,
    producers_unregistered: bool,
    lifecycle_stopped: bool,
    save_boundary_ready: bool,
};

const PersistenceProof = struct {
    snapshot_payload_bytes: usize,
    envelope_bytes: usize,
    canonical_before_restart: bool,
    original_deinitialized_before_restore: bool,
    compatible_envelope_admitted: bool,
    durable_restart_count: u32,
    restored_world_tick_matches: bool,
    restored_crates: u32,
    canonical_after_restore: bool,
    committed_save_disposition: []const u8,
};

const Report = struct {
    schema_version: u16 = schema_version,
    gate: []const u8 = "m3-pre-server-readiness",
    mode: Mode,
    fixed_delta_hz: u16 = 120,
    required_ticks: u64,
    completed_ticks: u64,
    cohorts: CohortProof,
    performance: PerformanceProof,
    resources: ResourceProof,
    ceilings: CeilingProof,
    crate_count: u32,
    producer: ProducerProof,
    saturation: SaturationProof,
    integrated_slices: IntegratedSlicesProof,
    queues: QueueProof,
    feature_queue_inventory: FeatureQueueInventory,
    producer_inventory: ProducerInventory,
    final_ownership: FinalOwnershipProof,
    operational: OperationalProof,
    shutdown: ShutdownProof,
    persistence: PersistenceProof,
};

const Metrics = struct {
    submitted: [producer_count]u64 = .{ 0, 0 },
    completed: [producer_count]u64 = .{ 0, 0 },
    post_warmup_observations: u64 = 0,
    post_warmup_ingress_peak: u32 = 0,
    post_warmup_transaction_peak: u32 = 0,
    post_warmup_delivery_peak: u32 = 0,
    post_warmup_internal_outcome_peak: u32 = 0,
    internal_outcome_reservation_peak: u32 = 0,
    internal_outcome_admission_rejections: u64 = 0,
    district_outcome_reservation_peak: u32 = 0,
    character_events_drained: u64 = 0,
    vehicle_events_drained: u64 = 0,
    district_events_drained: u64 = 0,
    npc_events_drained: u64 = 0,
};

const IntegratedState = struct {
    character: sandbox_contracts.PersistentId,
    vehicle: sandbox_contracts.PersistentId,
    carryable: sandbox_contracts.PersistentId,
    npcs: [sandbox_contracts.npc_capacity]sandbox_contracts.PersistentId,
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    switch (try parseInvocation(args)) {
        .help => {
            try writeUsage(init.io);
            return;
        },
        .run => |mode| {
            if (builtin.os.tag != .macos or builtin.cpu.arch != .aarch64) {
                return error.M3SoakRequiresAppleSiliconMacOS;
            }
            if (builtin.mode != .ReleaseFast) {
                return error.M3SoakRequiresReleaseFast;
            }
            var tracker = TrackingAllocator.init(init.gpa);
            const total_start = now(init.io);
            var report = try run(tracker.allocator(), init.io, mode);
            report.performance.whole_run_elapsed_ns = elapsedNs(total_start, now(init.io));
            report.performance.whole_run_ticks_per_second = throughput(
                report.completed_ticks,
                report.performance.whole_run_elapsed_ns,
            );
            report.resources.allocator_peak_bytes = tracker.peakBytes();
            report.resources.allocator_final_live_bytes = tracker.liveBytes();
            report.resources.max_rss_bytes = maxRssBytes();
            if (report.resources.allocator_final_live_bytes != 0) {
                return error.M3TrackedAllocationLeak;
            }
            try validateCeilings(&report);
            report.ceilings.all_passed = true;
            report.final_ownership.native_ownership_released = true;
            try writeJson(init.io, report);
        },
    }
}

fn run(allocator: std.mem.Allocator, io: std.Io, mode: Mode) !Report {
    const required_ticks = modeTicks(mode);
    const sample_count = std.math.cast(usize, required_ticks) orelse
        return error.M3TickCohortTooLarge;
    const tick_samples = try allocator.alloc(u64, sample_count);
    defer allocator.free(tick_samples);
    var sample_cursor: usize = 0;
    const config = worldConfig();
    const metadata = try saveMetadata(config);
    var metrics = Metrics{};
    var envelope: []u8 = undefined;
    var original_deinitialized = false;
    var final_diagnostics: headless_authority.Diagnostics = undefined;
    var integrated_state: IntegratedState = undefined;
    var saved_world_tick: u64 = undefined;
    var snapshot_payload_bytes: usize = undefined;
    var producer_before_unregister: headless_authority.ProducerDiagnostics = undefined;

    {
        var authority = try headless_authority.Authority.initFresh(allocator, config);
        defer {
            authority.deinit();
            original_deinitialized = true;
        }

        const crate_id = try spawnCrate(&authority, &metrics);
        try proveInternalSaturation(&authority, crate_id, &metrics);
        integrated_state = try setupIntegratedSlices(&authority, &metrics);

        var handles: [producer_count]headless_authority.ProducerHandle = undefined;
        for (&handles) |*handle| {
            handle.* = switch (authority.registerProducer()) {
                .registered => |registered| registered,
                else => return error.M3ProducerRegistrationFailed,
            };
        }
        if (authority.registerProducer() != .producer_capacity_full) {
            return error.M3ProducerCapacityNotEnforced;
        }

        try proveProducerSaturation(&authority, handles, crate_id, &metrics);
        try observe(&authority, &metrics, true);

        // Leave exactly one tick for a shutdown batch that is accepted before
        // ingress closes and completed while the router is draining.
        var completed_ticks: u64 = 0;
        while (completed_ticks + 1 < required_ticks) : (completed_ticks += 1) {
            if (completed_ticks % workload_period_ticks == 0) {
                for (handles, 0..) |handle, producer_index| {
                    try submitRelocation(
                        &authority,
                        handle,
                        producer_index,
                        nextSequence(metrics.submitted[producer_index]),
                        crate_id,
                        &metrics,
                    );
                }
                try observe(&authority, &metrics, true);
            }
            _ = try timedAuthorityTick(
                &authority,
                headless_authority.producer_limits.ingress_capacity,
                tick_samples,
                &sample_cursor,
                io,
            );
            try drainAvailableResults(&authority, handles, crate_id, &metrics);
            try drainAmbientEvents(&authority.world, &metrics);
            try requireNoTypedOutcomes(&authority);
            try observe(&authority, &metrics, true);
        }
        if (completed_ticks + 1 != required_ticks) {
            return error.M3TickCohortBoundaryMismatch;
        }

        const shutdown_batch_per_producer: usize = 4;
        for (0..shutdown_batch_per_producer) |_| {
            for (handles, 0..) |handle, producer_index| {
                try submitRelocation(
                    &authority,
                    handle,
                    producer_index,
                    nextSequence(metrics.submitted[producer_index]),
                    crate_id,
                    &metrics,
                );
            }
        }
        try observe(&authority, &metrics, true);
        if (authority.beginShutdown() != .draining or authority.isDrained()) {
            return error.M3ShutdownDidNotRetainAcceptedWork;
        }
        if (authority.submitExternal(handles[0], relocation(
            1,
            nextSequence(metrics.submitted[0]),
            crate_id,
            0,
        )) != .shutting_down) {
            return error.M3ShutdownIngressNotClosed;
        }

        _ = try timedAuthorityTick(
            &authority,
            headless_authority.producer_limits.ingress_capacity,
            tick_samples,
            &sample_cursor,
            io,
        );
        try drainAvailableResults(&authority, handles, crate_id, &metrics);
        try drainAmbientEvents(&authority.world, &metrics);
        try requireNoTypedOutcomes(&authority);
        try observe(&authority, &metrics, true);
        completed_ticks += 1;
        if (!authority.isDrained()) return error.M3ShutdownWorkNotDrained;
        producer_before_unregister = authority.diagnostics().producers;
        for (handles) |handle| {
            if (authority.unregisterProducer(handle) != .unregistered) {
                return error.M3ProducerUnregisterFailed;
            }
        }
        if (authority.finishShutdown() != .stopped) {
            return error.M3ProducerRouterDidNotStop;
        }
        try observe(&authority, &metrics, true);
        if (!authority.canCommitSave()) return error.M3SaveBoundaryNotReady;
        if (completed_ticks != required_ticks) {
            return error.M3CompletedTickCountMismatch;
        }
        try requireIntegratedState(&authority.world, &integrated_state);
        try requireAllTypedOutputsEmpty(&authority);

        const snapshot_payload = try authority.world.save(allocator);
        snapshot_payload_bytes = snapshot_payload.len;
        allocator.free(snapshot_payload);

        envelope = try authority.saveEnvelope(allocator, metadata);
        errdefer allocator.free(envelope);
        const canonical = try authority.saveEnvelope(allocator, metadata);
        defer allocator.free(canonical);
        if (!std.mem.eql(u8, envelope, canonical)) {
            return error.M3NonCanonicalEnvelopeBeforeRestart;
        }
        final_diagnostics = authority.diagnostics();
        saved_world_tick = final_diagnostics.world.tick_index;
    }

    if (!original_deinitialized) return error.M3OriginalAuthorityStillLive;
    defer allocator.free(envelope);
    const saved_view = try sandbox_save.parseCompatible(envelope, metadata);

    var restored = try headless_authority.Authority.initRestored(
        allocator,
        saved_view.payload,
        config,
    );
    defer restored.deinit();
    const restored_diagnostics = restored.diagnostics();
    try validateDiagnostics(restored_diagnostics);
    if (restored_diagnostics.world.tick_index != saved_world_tick or
        restored_diagnostics.world.crates.active_count != 1)
    {
        return error.M3RestoredWorldMismatch;
    }
    try requireIntegratedState(&restored.world, &integrated_state);
    try requireAllTypedOutputsEmpty(&restored);
    if (restored.beginShutdown() != .draining or
        restored.finishShutdown() != .stopped or
        !restored.canCommitSave())
    {
        return error.M3RestoredShutdownBoundaryMismatch;
    }
    const restored_envelope = try restored.saveEnvelope(allocator, metadata);
    defer allocator.free(restored_envelope);
    if (!std.mem.eql(u8, envelope, restored_envelope)) {
        const limit = @min(envelope.len, restored_envelope.len);
        var mismatch: usize = 0;
        while (mismatch < limit and envelope[mismatch] == restored_envelope[mismatch]) {
            mismatch += 1;
        }
        const start = mismatch -| 80;
        const original_end = @min(envelope.len, mismatch + 160);
        const restored_end = @min(restored_envelope.len, mismatch + 160);
        std.debug.print(
            "M3 restore mismatch offset={d} original_len={d} restored_len={d}\noriginal={s}\nrestored={s}\n",
            .{
                mismatch,
                envelope.len,
                restored_envelope.len,
                envelope[start..original_end],
                restored_envelope[start..restored_end],
            },
        );
        return error.M3ColdRestoreNotCanonical;
    }

    if (sample_cursor != tick_samples.len) return error.M3TimingSampleCountMismatch;
    const tick_distribution = summarize(tick_samples);
    const queues = final_diagnostics.producers;
    if (queues.outcomes_handed_back != expected_internal_non_relocation_handbacks) {
        return error.M3UnexpectedProducerProtocolHandback;
    }
    return .{
        .mode = mode,
        .required_ticks = required_ticks,
        .completed_ticks = required_ticks,
        .cohorts = .{
            .zig_version = builtin.zig_version_string,
            .optimize = @tagName(builtin.mode),
            .target_arch = @tagName(builtin.target.cpu.arch),
            .target_os = @tagName(builtin.target.os.tag),
            .target_abi = @tagName(builtin.target.abi),
            .simulation_build_digest = metadata.simulation_build_digest,
            .world_config_digest = metadata.world_config_digest,
            .content_digest = metadata.content_digest,
            .config_cohort = config_cohort,
            .config_cohort_digest = cohortDigest(config_cohort),
            .scenario_cohort = scenario_cohort,
            .scenario_cohort_digest = cohortDigest(scenario_cohort),
            .world_namespace = namespace,
            .max_crates = @intCast(config.max_crates),
            .max_characters = @intCast(config.character.max_characters),
            .max_vehicles = @intCast(config.vehicle.max_vehicles),
            .max_npcs = sandbox_contracts.npc_capacity,
            .create_ground = config.create_ground,
        },
        .performance = .{
            .authority_tick = tick_distribution,
            .authority_ticks_per_second = throughput(
                required_ticks,
                tick_distribution.total_ns,
            ),
            .whole_run_elapsed_ns = 0,
            .whole_run_ticks_per_second = 0,
        },
        .resources = .{
            .allocator_peak_bytes = 0,
            .allocator_final_live_bytes = 0,
            .max_rss_bytes = 0,
        },
        .ceilings = .{ .all_passed = false },
        .crate_count = final_diagnostics.world.crates.active_count,
        .producer = .{
            .registered = producer_count,
            .registration_capacity_rejection = queues.rejections.producer_capacity_full == 1,
            .submitted = metrics.submitted,
            .completed = metrics.completed,
            .completion_isolation = std.meta.eql(metrics.submitted, metrics.completed),
            .shutdown_admission_rejection = queues.rejections.shutting_down == 1,
        },
        .saturation = .{
            .internal_admission_capacity = headless_authority.internal_outcome_capacity - 1,
            .emergency_evidence_slots = 1,
            .internal_outcome_queue_full = true,
            .internal_outcome_peak = final_diagnostics.internal_outcomes.high_water,
            .internal_recovered = final_diagnostics.internal_outcomes.occupancy == 0 and
                final_diagnostics.internal_outcomes.reservations == 0,
            .producer_pending_quota = headless_authority.producer_limits.pending_quota_per_producer,
            .producer_quota_full = queues.rejections.producer_quota_full == 1,
            .producer_ingress_capacity = headless_authority.producer_limits.ingress_capacity,
            .producer_ingress_full = queues.rejections.ingress_full == 1,
            .producer_transaction_capacity = headless_authority.producer_limits.transaction_capacity,
            .producer_transaction_table_full = queues.rejections.transaction_table_full == 1,
            .producer_delivery_capacity = headless_authority.producer_limits.result_capacity_per_producer,
            .producer_result_capacity_full = queues.rejections.result_capacity_full == 1,
            .producer_recovered = queues.ingress.occupancy == 0 and
                queues.transactions.occupancy == 0 and queues.delivery.occupancy == 0,
        },
        .integrated_slices = .{
            .cancellation_completed = true,
            .unload_reload_completed = true,
            .active_districts = final_diagnostics.world.district.active_count,
            .district_bodies = final_diagnostics.world.district.body_count,
            .active_characters = final_diagnostics.world.characters.active_count,
            .active_vehicles = final_diagnostics.world.vehicles.active_count,
            .active_carryables = final_diagnostics.world.interaction.active_count,
            .carryable_dynamic_bodies = final_diagnostics.world.interaction.dynamic_body_count,
            .active_npcs = npcCount(final_diagnostics.world),
            .native_physics_bodies = final_diagnostics.world.body_count,
            .native_character_controllers = final_diagnostics.world.character_controllers.native_used,
            .native_character_controller_capacity = final_diagnostics.world.character_controllers.native_capacity,
            .collect_completed = true,
            .drop_completed = true,
            .typed_events_drained = metrics.character_events_drained +
                metrics.vehicle_events_drained + metrics.district_events_drained +
                metrics.npc_events_drained,
            .restored_districts = restored_diagnostics.world.district.active_count,
            .restored_district_bodies = restored_diagnostics.world.district.body_count,
            .restored_characters = restored_diagnostics.world.characters.active_count,
            .restored_vehicles = restored_diagnostics.world.vehicles.active_count,
            .restored_carryables = restored_diagnostics.world.interaction.active_count,
            .restored_carryable_dynamic_bodies = restored_diagnostics.world.interaction.dynamic_body_count,
            .restored_npcs = npcCount(restored_diagnostics.world),
            .restored_native_physics_bodies = restored_diagnostics.world.body_count,
            .restored_native_character_controllers = restored_diagnostics.world.character_controllers.native_used,
            .restored_ownership_exact = true,
            .final_and_restored_queues_empty = true,
        },
        .queues = .{
            .post_warmup_observations = metrics.post_warmup_observations,
            .all_world_queues_declared_capacity = true,
            .capacities_stable = true,
            .producer_capacity = queues.producers.capacity,
            .ingress_capacity = queues.ingress.capacity,
            .ingress_high_water = queues.ingress.high_water,
            .post_warmup_ingress_peak = metrics.post_warmup_ingress_peak,
            .transaction_capacity = queues.transactions.capacity,
            .transaction_high_water = queues.transactions.high_water,
            .post_warmup_transaction_peak = metrics.post_warmup_transaction_peak,
            .delivery_capacity = queues.delivery.capacity,
            .delivery_high_water = queues.delivery.high_water,
            .post_warmup_delivery_peak = metrics.post_warmup_delivery_peak,
            .internal_outcome_capacity = final_diagnostics.internal_outcomes.capacity,
            .internal_outcome_high_water = final_diagnostics.internal_outcomes.high_water,
            .internal_outcome_reservation_high_water = metrics.internal_outcome_reservation_peak,
            .internal_outcome_admission_rejections = metrics.internal_outcome_admission_rejections,
            .post_warmup_internal_outcome_peak = metrics.post_warmup_internal_outcome_peak,
            .final_ingress_occupancy = queues.ingress.occupancy,
            .final_transaction_occupancy = queues.transactions.occupancy,
            .final_delivery_occupancy = queues.delivery.occupancy,
            .final_internal_outcome_occupancy = final_diagnostics.internal_outcomes.occupancy,
            .final_internal_outcome_reservations = final_diagnostics.internal_outcomes.reservations,
            .final_district_outcome_reservations = final_diagnostics.world.district.outcome_reservations,
        },
        .feature_queue_inventory = featureQueueInventory(
            final_diagnostics.world,
            metrics,
        ),
        .producer_inventory = producerInventory(
            queues,
            producer_before_unregister,
            metrics,
        ),
        .final_ownership = .{
            .entities = final_diagnostics.world.entity_count,
            .rigid_bodies = final_diagnostics.world.body_count,
            .active_rigid_bodies = final_diagnostics.world.active_body_count,
            .character_virtual_used = final_diagnostics.world.character_controllers.native_used,
            .character_virtual_capacity = final_diagnostics.world.character_controllers.native_capacity,
            .feature_owned_controllers = final_diagnostics.world.character_controllers.feature_owned,
            .vehicles = final_diagnostics.world.vehicles.active_count,
            .district_worker_state = @tagName(final_diagnostics.world.district_worker.state),
            .district_worker_generation = final_diagnostics.world.district_worker.generation,
            .district_worker_started = final_diagnostics.world.district_worker.started,
            .presentation_extractions = 0,
            .renderer_or_gpu_resources = 0,
            .live_worlds_after_cleanup = 0,
            .live_authorities_after_cleanup = 0,
            .native_ownership_released = false,
        },
        .operational = .{
            .healthy_backpressure_recovered = true,
            .injected_failure_recovered = false,
            .runtime_first_fault = final_diagnostics.world.first_fault != null,
        },
        .shutdown = .{
            .accepted_work_drained = queues.ingress.occupancy == 0 and
                queues.transactions.occupancy == 0,
            .producers_unregistered = queues.producers.occupancy == 0,
            .lifecycle_stopped = queues.lifecycle == .stopped,
            .save_boundary_ready = true,
        },
        .persistence = .{
            .snapshot_payload_bytes = snapshot_payload_bytes,
            .envelope_bytes = envelope.len,
            .canonical_before_restart = true,
            .original_deinitialized_before_restore = original_deinitialized,
            .compatible_envelope_admitted = true,
            .durable_restart_count = 1,
            .restored_world_tick_matches = true,
            .restored_crates = restored_diagnostics.world.crates.active_count,
            .canonical_after_restore = true,
            .committed_save_disposition = "not_applicable_installed_lifecycle_gate_owns_durable_commit",
        },
    };
}

fn spawnCrate(
    authority: *headless_authority.Authority,
    metrics: *Metrics,
) !CrateId {
    try authority.submitInternal(.{ .spawn = .{
        .request_id = 1,
        .pose = .{ .position = .{ 0, 2, 0 } },
    } });
    const tick_report = try authority.tick(
        headless_authority.producer_limits.ingress_capacity,
    );
    if (tick_report.internal_outcomes != 1) return error.M3SpawnOutcomeCountMismatch;
    try observe(authority, metrics, false);
    return switch (authority.pollInternalOutcome() orelse
        return error.M3SpawnOutcomeMissing) {
        .spawned => |spawned| if (spawned.request_id == 1)
            spawned.id
        else
            return error.M3SpawnRequestMismatch,
        else => return error.M3UnexpectedSpawnOutcome,
    };
}

fn setupIntegratedSlices(
    authority: *headless_authority.Authority,
    metrics: *Metrics,
) !IntegratedState {
    try proveDistrictCancellation(authority, metrics, 90, west);
    _ = try activateDistrict(authority, metrics, 100, west);
    const first_east_ticket = try activateDistrict(authority, metrics, 101, east);
    try unloadDistrict(authority, metrics, 102, first_east_ticket);
    _ = try activateDistrict(authority, metrics, 103, east);

    try authority.world.submitCharacter(.{ .spawn = .{
        .request_id = 200,
        .position = .{ 6, 0, 3 },
    } });
    try authority.world.submitInteraction(.{ .spawn = .{
        .request_id = 201,
        .pose = .{ .position = .{ 6, 0.75, 3 } },
    } });
    try authority.world.submitVehicle(.{ .spawn = .{
        .request_id = 202,
        .chassis = .{ .pose = .{ .position = .{ 20, 2, -5 } } },
    } });
    try tickWithoutCrateWork(authority);
    const character = switch (authority.world.pollCharacterOutcome() orelse
        return error.M3CharacterSpawnOutcomeMissing) {
        .spawned => |spawned| if (spawned.request_id == 200)
            spawned.id
        else
            return error.M3CharacterSpawnRequestMismatch,
        else => return error.M3UnexpectedCharacterSpawnOutcome,
    };
    const carryable = switch (authority.world.pollInteractionOutcome() orelse
        return error.M3CarryableSpawnOutcomeMissing) {
        .spawned => |spawned| if (spawned.request_id == 201 and
            sandbox_contracts.ChunkCoord.eql(spawned.owner, west))
            spawned.id
        else
            return error.M3CarryableSpawnOwnerMismatch,
        else => return error.M3UnexpectedCarryableSpawnOutcome,
    };
    const vehicle = switch (authority.world.pollVehicleOutcome() orelse
        return error.M3VehicleSpawnOutcomeMissing) {
        .spawned => |spawned| if (spawned.request_id == 202)
            spawned.id
        else
            return error.M3VehicleSpawnRequestMismatch,
        else => return error.M3UnexpectedVehicleSpawnOutcome,
    };
    try drainAmbientEvents(&authority.world, metrics);
    try requireNoTypedOutcomes(authority);
    try observe(authority, metrics, false);

    try authority.world.submitInteraction(.{ .collect = .{
        .transaction_id = 300,
        .carrier_id = character,
        .carryable_id = carryable,
    } });
    try tickWithoutCrateWork(authority);
    switch (authority.world.pollInteractionOutcome() orelse
        return error.M3CollectOutcomeMissing) {
        .collected => |collected| {
            if (collected.transaction_id != 300 or
                !std.meta.eql(collected.carrier_id, character) or
                !std.meta.eql(collected.carryable_id, carryable) or
                !sandbox_contracts.ChunkCoord.eql(collected.previous_owner, west))
            {
                return error.M3CollectOutcomeMismatch;
            }
        },
        else => return error.M3UnexpectedCollectOutcome,
    }
    const held = try authority.world.carryable(carryable);
    if (held.body_present or !std.meta.eql(held.ownership, .{
        .inventory_held = character,
    })) return error.M3CollectOwnershipMismatch;
    try drainAmbientEvents(&authority.world, metrics);
    try requireNoTypedOutcomes(authority);
    try observe(authority, metrics, false);

    try authority.world.submitInteraction(.{ .drop = .{
        .transaction_id = 301,
        .carrier_id = character,
        .carryable_id = carryable,
        .purpose = .player_requested,
    } });
    try tickWithoutCrateWork(authority);
    switch (authority.world.pollInteractionOutcome() orelse
        return error.M3DropOutcomeMissing) {
        .dropped => |dropped| {
            if (dropped.transaction_id != 301 or
                !std.meta.eql(dropped.carrier_id, character) or
                !std.meta.eql(dropped.carryable_id, carryable) or
                !sandbox_contracts.ChunkCoord.eql(dropped.owner, west))
            {
                return error.M3DropOutcomeMismatch;
            }
        },
        else => return error.M3UnexpectedDropOutcome,
    }
    const dropped = try authority.world.carryable(carryable);
    if (!dropped.body_present or !std.meta.eql(dropped.ownership, .{
        .spatially_owned = west,
    })) return error.M3DropOwnershipMismatch;
    try drainAmbientEvents(&authority.world, metrics);
    try requireNoTypedOutcomes(authority);
    try observe(authority, metrics, false);

    var npc_ids: [sandbox_contracts.npc_capacity]sandbox_contracts.PersistentId = undefined;
    const first_npc_request_id: u64 = 1_000;
    for (0..sandbox_contracts.npc_capacity) |index| {
        try authority.world.submitNpc(.{ .spawn = .{
            .request_id = first_npc_request_id + index,
            .position = .{ -5, 0, 5 },
            .facing_yaw = 0,
            .anchor = west_node,
            .hostile_to_players = true,
            .goal = .{ .patrol_between = .{
                .first = west_node,
                .second = east_node,
            } },
        } });
    }
    try tickWithoutCrateWork(authority);
    var seen = [_]bool{false} ** sandbox_contracts.npc_capacity;
    for (0..sandbox_contracts.npc_capacity) |_| {
        const spawned = switch (authority.world.pollNpcOutcome() orelse
            return error.M3NpcSpawnOutcomeMissing) {
            .spawned => |spawned| spawned,
            else => return error.M3UnexpectedNpcSpawnOutcome,
        };
        if (spawned.request_id < first_npc_request_id or
            spawned.request_id >= first_npc_request_id + sandbox_contracts.npc_capacity or
            !sandbox_contracts.ChunkCoord.eql(spawned.owner, west))
        {
            return error.M3NpcSpawnOutcomeMismatch;
        }
        const index: usize = @intCast(spawned.request_id - first_npc_request_id);
        if (seen[index]) return error.M3DuplicateNpcSpawnOutcome;
        seen[index] = true;
        npc_ids[index] = spawned.id;
    }
    for (seen) |was_seen| if (!was_seen) return error.M3NpcSpawnOutcomeMissing;
    try drainAmbientEvents(&authority.world, metrics);
    try requireNoTypedOutcomes(authority);
    try observe(authority, metrics, false);

    // The exact S8 cohort is retained, and the next valid request must produce
    // one typed capacity rejection without a partial entity/controller commit.
    try authority.world.submitNpc(.{ .spawn = .{
        .request_id = 2_000,
        .position = .{ -5, 0, 5 },
        .facing_yaw = 0,
        .anchor = west_node,
        .hostile_to_players = true,
        .goal = .hold,
    } });
    try tickWithoutCrateWork(authority);
    switch (authority.world.pollNpcOutcome() orelse
        return error.M3NpcCapacityOutcomeMissing) {
        .rejected => |rejected| {
            if (rejected.command != .spawn or rejected.reason != .capacity_reached or
                rejected.request_id != 2_000 or rejected.id != null)
            {
                return error.M3NpcCapacityOutcomeMismatch;
            }
        },
        else => return error.M3NpcCapacityWasNotRejected,
    }
    try drainAmbientEvents(&authority.world, metrics);
    try requireNoTypedOutcomes(authority);
    try observe(authority, metrics, false);

    const state = IntegratedState{
        .character = character,
        .vehicle = vehicle,
        .carryable = carryable,
        .npcs = npc_ids,
    };
    try requireIntegratedState(&authority.world, &state);
    return state;
}

fn proveDistrictCancellation(
    authority: *headless_authority.Authority,
    metrics: *Metrics,
    request_id: u64,
    coord: sandbox_contracts.ChunkCoord,
) !void {
    try authority.world.submitDistrict(.{ .request_load = .{
        .request_id = request_id,
        .coord = coord,
        .assets = .{},
    } });
    try observe(authority, metrics, false);
    try tickWithoutCrateWork(authority);
    const ticket = switch (authority.world.pollDistrictOutcome() orelse
        return error.M3DistrictCancellationRequestMissing) {
        .load_requested => |requested| if (requested.request_id == request_id)
            requested.ticket
        else
            return error.M3DistrictCancellationRequestMismatch,
        else => return error.M3UnexpectedDistrictCancellationRequestOutcome,
    };
    try drainAmbientEvents(&authority.world, metrics);
    try requireNoTypedOutcomes(authority);
    try observe(authority, metrics, false);

    try authority.world.submitDistrict(.{ .cancel_load = .{
        .request_id = request_id + 1,
        .ticket = ticket,
    } });
    try observe(authority, metrics, false);
    var cancellation_requested = false;
    var cancelled = false;
    for (0..district_progress_limit) |_| {
        try tickWithoutCrateWork(authority);
        while (authority.world.pollDistrictOutcome()) |outcome| switch (outcome) {
            .cancellation_requested => |requested| {
                if (requested.request_id != request_id + 1 or
                    !sandbox_contracts.LoadTicket.eql(requested.ticket, ticket))
                {
                    return error.M3DistrictCancellationRequestMismatch;
                }
                cancellation_requested = true;
            },
            .cancelled => |completed| {
                if (!sandbox_contracts.LoadTicket.eql(completed.ticket, ticket)) {
                    return error.M3DistrictCancellationTicketMismatch;
                }
                cancelled = true;
            },
            else => return error.M3UnexpectedDistrictCancellationOutcome,
        };
        try drainAmbientEvents(&authority.world, metrics);
        try requireNoTypedOutcomes(authority);
        try observe(authority, metrics, false);
        if (cancelled) break;
        std.Thread.yield() catch {};
    }
    if (!cancellation_requested or !cancelled or
        authority.world.districtStateFor(coord) != null)
    {
        return error.M3DistrictCancellationDidNotComplete;
    }
}

fn unloadDistrict(
    authority: *headless_authority.Authority,
    metrics: *Metrics,
    request_id: u64,
    ticket: sandbox_contracts.LoadTicket,
) !void {
    try authority.world.submitDistrict(.{ .unload = .{
        .request_id = request_id,
        .ticket = ticket,
    } });
    try observe(authority, metrics, false);
    try tickWithoutCrateWork(authority);
    switch (authority.world.pollDistrictOutcome() orelse
        return error.M3DistrictUnloadOutcomeMissing) {
        .unloaded => |unloaded| {
            if (unloaded.request_id != request_id or
                !sandbox_contracts.LoadTicket.eql(unloaded.ticket, ticket))
            {
                return error.M3DistrictUnloadOutcomeMismatch;
            }
        },
        else => return error.M3UnexpectedDistrictUnloadOutcome,
    }
    try drainAmbientEvents(&authority.world, metrics);
    try requireNoTypedOutcomes(authority);
    try observe(authority, metrics, false);
    if (authority.world.districtStateFor(ticket.coord) != null) {
        return error.M3DistrictUnloadDidNotRemoveAuthority;
    }
}

fn activateDistrict(
    authority: *headless_authority.Authority,
    metrics: *Metrics,
    request_id: u64,
    coord: sandbox_contracts.ChunkCoord,
) !sandbox_contracts.LoadTicket {
    try authority.world.submitDistrict(.{ .request_load = .{
        .request_id = request_id,
        .coord = coord,
        .assets = .{},
    } });
    try observe(authority, metrics, false);
    try tickWithoutCrateWork(authority);
    const ticket = switch (authority.world.pollDistrictOutcome() orelse
        return error.M3DistrictRequestOutcomeMissing) {
        .load_requested => |requested| if (requested.request_id == request_id)
            requested.ticket
        else
            return error.M3DistrictRequestIdentityMismatch,
        else => return error.M3UnexpectedDistrictRequestOutcome,
    };
    try drainAmbientEvents(&authority.world, metrics);
    try requireNoTypedOutcomes(authority);
    try observe(authority, metrics, false);

    for (0..district_progress_limit) |_| {
        std.Thread.yield() catch {};
        try tickWithoutCrateWork(authority);
        var activated = false;
        while (authority.world.pollDistrictOutcome()) |outcome| switch (outcome) {
            .activated => |value| {
                if (value.request_id != request_id or
                    !sandbox_contracts.LoadTicket.eql(value.ticket, ticket) or
                    !sandbox_contracts.ChunkCoord.eql(value.coord, coord))
                {
                    return error.M3DistrictActivationMismatch;
                }
                activated = true;
            },
            .load_failed => return error.M3DistrictLoadFailed,
            .cancelled => return error.M3DistrictLoadCancelled,
            else => return error.M3UnexpectedDistrictProgressOutcome,
        };
        try drainAmbientEvents(&authority.world, metrics);
        try requireNoTypedOutcomes(authority);
        try observe(authority, metrics, false);
        if (activated) return ticket;
    }
    return error.M3DistrictWorkerDidNotComplete;
}

fn tickWithoutCrateWork(authority: *headless_authority.Authority) !void {
    const report = try authority.tick(headless_authority.producer_limits.ingress_capacity);
    if (report.transferred_commands != 0 or report.terminal_submission_rejections != 0 or
        report.routed_results != 0 or report.internal_outcomes != 0 or
        authority.pollInternalOutcome() != null)
    {
        return error.M3UnexpectedCrateWorkDuringIntegratedSetup;
    }
}

fn proveInternalSaturation(
    authority: *headless_authority.Authority,
    crate_id: CrateId,
    metrics: *Metrics,
) !void {
    const admission_capacity = headless_authority.internal_outcome_capacity - 1;
    for (0..admission_capacity) |_| {
        try authority.submitInternal(.{ .impulse = .{
            .id = crate_id,
            .impulse = .{ 0, 0, 0 },
        } });
    }
    const admitted = authority.diagnostics();
    if (admitted.internal_outcomes.occupancy != 0 or
        admitted.internal_outcomes.reservations != admission_capacity or
        admitted.world.crates.commands.occupancy != admission_capacity)
    {
        return error.M3InternalAdmissionSaturationMismatch;
    }
    try observe(authority, metrics, false);
    if (authority.submitInternal(.{
        .impulse = .{ .id = crate_id, .impulse = .{ 0, 0, 0 } },
    })) |_| {
        return error.M3InternalOutcomeCapacityNotEnforced;
    } else |err| switch (err) {
        error.InternalOutcomeQueueFull => metrics.internal_outcome_admission_rejections += 1,
        else => return err,
    }
    const tick_report = try authority.tick(
        headless_authority.producer_limits.ingress_capacity,
    );
    if (tick_report.internal_outcomes != admission_capacity) {
        return error.M3InternalSaturationOutcomeCountMismatch;
    }
    const published = authority.diagnostics();
    if (published.internal_outcomes.occupancy != admission_capacity or
        published.internal_outcomes.reservations != 0)
    {
        return error.M3InternalOutcomeSaturationMismatch;
    }
    try observe(authority, metrics, false);
    for (0..admission_capacity) |_| {
        switch (authority.pollInternalOutcome() orelse
            return error.M3InternalSaturationOutcomeMissing) {
            .impulse_applied => |id| if (!std.meta.eql(id, crate_id))
                return error.M3InternalSaturationIdentityMismatch,
            else => return error.M3InternalSaturationUnexpectedOutcome,
        }
    }
    if (authority.pollInternalOutcome() != null) {
        return error.M3InternalSaturationExtraOutcome;
    }
    if (authority.diagnostics().internal_outcomes.reservations != 0) {
        return error.M3InternalReservationLeak;
    }

    // One successful admission after draining proves the saturated boundary is
    // reusable and did not poison the world.
    try authority.submitInternal(.{ .impulse = .{
        .id = crate_id,
        .impulse = .{ 0, 0, 0 },
    } });
    _ = try authority.tick(headless_authority.producer_limits.ingress_capacity);
    switch (authority.pollInternalOutcome() orelse
        return error.M3InternalRecoveryOutcomeMissing) {
        .impulse_applied => |id| if (!std.meta.eql(id, crate_id))
            return error.M3InternalRecoveryIdentityMismatch,
        else => return error.M3InternalRecoveryUnexpectedOutcome,
    }
    const recovered = authority.diagnostics().internal_outcomes;
    if (recovered.occupancy != 0 or recovered.reservations != 0) {
        return error.M3InternalBoundaryDidNotRecover;
    }
    try observe(authority, metrics, false);
}

fn proveProducerSaturation(
    authority: *headless_authority.Authority,
    handles: [producer_count]headless_authority.ProducerHandle,
    crate_id: CrateId,
    metrics: *Metrics,
) !void {
    const quota = headless_authority.producer_limits.pending_quota_per_producer;

    // Per-producer limits remain distinct from the exact two-producer global
    // limits. Fill only one producer first so quota and reserved delivery
    // capacity are independently observable.
    for (0..quota) |_| {
        try submitRelocation(
            authority,
            handles[0],
            0,
            nextSequence(metrics.submitted[0]),
            crate_id,
            metrics,
        );
    }
    const quota_admitted = authority.diagnostics().producers;
    if (quota_admitted.ingress.occupancy != quota or
        quota_admitted.transactions.occupancy != quota or
        quota_admitted.slots[0].pending != quota or
        quota_admitted.slots[1].pending != 0)
    {
        return error.M3ProducerQuotaSaturationMismatch;
    }
    try observe(authority, metrics, false);
    if (authority.submitExternal(handles[0], relocation(
        0,
        nextSequence(metrics.submitted[0]),
        crate_id,
        0,
    )) != .producer_quota_full) {
        return error.M3ProducerQuotaNotEnforced;
    }

    _ = try authority.tick(headless_authority.producer_limits.ingress_capacity);
    try drainAmbientEvents(&authority.world, metrics);
    try requireNoTypedOutcomes(authority);
    const quota_published = authority.diagnostics().producers;
    if (quota_published.ingress.occupancy != 0 or
        quota_published.transactions.occupancy != quota or
        quota_published.slots[0].pending != 0 or
        quota_published.slots[0].unread_results != quota)
    {
        return error.M3ProducerDeliverySaturationMismatch;
    }
    try observe(authority, metrics, false);
    if (authority.submitExternal(handles[0], relocation(
        0,
        nextSequence(metrics.submitted[0]),
        crate_id,
        0,
    )) != .result_capacity_full) {
        return error.M3ProducerDeliveryReservationNotEnforced;
    }
    for (0..quota) |_| {
        try consumeProducerResult(authority, handles[0], 0, crate_id, metrics);
    }
    if (authority.pollProducerResult(handles[0]) != .empty or
        authority.pollProducerResult(handles[1]) != .empty)
    {
        return error.M3UnexpectedExtraProducerResult;
    }

    // Now fill the exact global 2 x quota cohort. Global ingress is reported
    // while queued; after pumping, the still-live transaction table is the
    // limiting resource until owners consume their reserved results.
    for (0..quota) |_| {
        for (handles, 0..) |handle, producer_index| {
            try submitRelocation(
                authority,
                handle,
                producer_index,
                nextSequence(metrics.submitted[producer_index]),
                crate_id,
                metrics,
            );
        }
    }
    const admitted = authority.diagnostics().producers;
    if (admitted.ingress.occupancy != producer_count * quota or
        admitted.transactions.occupancy != producer_count * quota or
        admitted.delivery.occupancy != producer_count * quota)
    {
        return error.M3ProducerSaturationOccupancyMismatch;
    }
    for (admitted.slots) |slot| {
        if (slot.pending != quota or slot.unread_results != 0 or
            slot.delivery.occupancy != quota)
        {
            return error.M3ProducerSlotSaturationMismatch;
        }
    }
    try observe(authority, metrics, false);
    if (authority.submitExternal(handles[0], relocation(
        0,
        nextSequence(metrics.submitted[0]),
        crate_id,
        0,
    )) != .ingress_full) {
        return error.M3ProducerIngressCapacityNotEnforced;
    }

    _ = try authority.tick(headless_authority.producer_limits.ingress_capacity);
    try drainAmbientEvents(&authority.world, metrics);
    try requireNoTypedOutcomes(authority);
    const published = authority.diagnostics().producers;
    if (published.ingress.occupancy != 0 or
        published.transactions.occupancy != producer_count * quota or
        published.delivery.occupancy != producer_count * quota)
    {
        return error.M3ProducerResultSaturationMismatch;
    }
    for (published.slots) |slot| {
        if (slot.pending != 0 or slot.unread_results != quota or
            slot.results.occupancy != quota or slot.delivery.occupancy != quota)
        {
            return error.M3ProducerResultSlotSaturationMismatch;
        }
    }
    try observe(authority, metrics, false);
    if (authority.submitExternal(handles[0], relocation(
        0,
        nextSequence(metrics.submitted[0]),
        crate_id,
        0,
    )) != .transaction_table_full) {
        return error.M3ProducerTransactionCapacityNotEnforced;
    }
    try drainExactResults(authority, handles, crate_id, metrics, quota);

    for (handles, 0..) |handle, producer_index| {
        try submitRelocation(
            authority,
            handle,
            producer_index,
            nextSequence(metrics.submitted[producer_index]),
            crate_id,
            metrics,
        );
    }
    _ = try authority.tick(headless_authority.producer_limits.ingress_capacity);
    try drainAmbientEvents(&authority.world, metrics);
    try requireNoTypedOutcomes(authority);
    try drainExactResults(authority, handles, crate_id, metrics, 1);
    const recovered = authority.diagnostics().producers;
    if (recovered.ingress.occupancy != 0 or recovered.transactions.occupancy != 0 or
        recovered.delivery.occupancy != 0)
    {
        return error.M3ProducerBoundaryDidNotRecover;
    }
    try observe(authority, metrics, false);
}

fn submitRelocation(
    authority: *headless_authority.Authority,
    handle: headless_authority.ProducerHandle,
    producer_index: usize,
    sequence: u64,
    crate_id: CrateId,
    metrics: *Metrics,
) !void {
    const status = authority.submitExternal(
        handle,
        relocation(
            producer_index,
            sequence,
            crate_id,
            metrics.submitted[0] + metrics.submitted[1],
        ),
    );
    if (status != .accepted) return error.M3ExpectedProducerAdmission;
    metrics.submitted[producer_index] += 1;
}

fn relocation(
    producer_index: usize,
    sequence: u64,
    crate_id: CrateId,
    expected_revision: u64,
) crate_feature.RelocateCrate {
    const offset: f32 = @floatFromInt(sequence % 17);
    return .{
        .transaction_id = transactionId(producer_index, sequence),
        .source = .scripted_validation,
        .scope = .session,
        .id = crate_id,
        .target_pose = .{ .position = .{
            offset - 8,
            2,
            if (producer_index == 0) -2 else 2,
        } },
        .velocity = .zero,
        .expected_revision = expected_revision,
    };
}

fn drainExactResults(
    authority: *headless_authority.Authority,
    handles: [producer_count]headless_authority.ProducerHandle,
    crate_id: CrateId,
    metrics: *Metrics,
    expected_per_producer: usize,
) !void {
    for (handles, 0..) |handle, producer_index| {
        for (0..expected_per_producer) |_| {
            try consumeProducerResult(authority, handle, producer_index, crate_id, metrics);
        }
        if (authority.pollProducerResult(handle) != .empty) {
            return error.M3UnexpectedExtraProducerResult;
        }
    }
}

fn drainAvailableResults(
    authority: *headless_authority.Authority,
    handles: [producer_count]headless_authority.ProducerHandle,
    crate_id: CrateId,
    metrics: *Metrics,
) !void {
    for (handles, 0..) |handle, producer_index| {
        while (true) switch (authority.pollProducerResult(handle)) {
            .empty => break,
            .stale_handle => return error.M3ProducerHandleBecameStale,
            .result => |result| try consumeResultValue(
                result,
                producer_index,
                crate_id,
                metrics,
            ),
        };
    }
}

fn consumeProducerResult(
    authority: *headless_authority.Authority,
    handle: headless_authority.ProducerHandle,
    producer_index: usize,
    crate_id: CrateId,
    metrics: *Metrics,
) !void {
    switch (authority.pollProducerResult(handle)) {
        .result => |result| try consumeResultValue(result, producer_index, crate_id, metrics),
        .empty => return error.M3ProducerResultMissing,
        .stale_handle => return error.M3ProducerHandleBecameStale,
    }
}

fn consumeResultValue(
    result: headless_authority.ProducerResult,
    producer_index: usize,
    crate_id: CrateId,
    metrics: *Metrics,
) !void {
    const outcome = switch (result) {
        .outcome => |outcome| outcome,
        .submission_rejected => return error.M3ProducerSubmissionTerminallyRejected,
    };
    const relocated = switch (outcome) {
        .relocated => |relocated| relocated,
        else => return error.M3UnexpectedProducerOutcome,
    };
    if (!std.meta.eql(relocated.id, crate_id) or
        producerForTransaction(relocated.transaction_id) != producer_index)
    {
        return error.M3ProducerCompletionIsolationFailed;
    }
    metrics.completed[producer_index] += 1;
}

fn drainAmbientEvents(world: *simulation.Simulation, metrics: *Metrics) !void {
    while (world.pollCharacterEvent() != null) metrics.character_events_drained += 1;
    while (world.pollVehicleEvent() != null) metrics.vehicle_events_drained += 1;
    while (world.pollDistrictEvent() != null) metrics.district_events_drained += 1;
    while (world.pollNpcEvent() != null) metrics.npc_events_drained += 1;
}

fn requireNoTypedOutcomes(authority: *headless_authority.Authority) !void {
    if (authority.pollInternalOutcome() != null or
        authority.world.pollCharacterOutcome() != null or
        authority.world.pollVehicleOutcome() != null or
        authority.world.pollDistrictOutcome() != null or
        authority.world.pollInteractionOutcome() != null or
        authority.world.pollNpcOutcome() != null)
    {
        return error.M3UnexpectedTypedOutcome;
    }
    if (authority.diagnostics().internal_outcomes.reservations != 0) {
        return error.M3UnexpectedInternalOutcomeReservation;
    }
}

fn requireAllTypedOutputsEmpty(authority: *headless_authority.Authority) !void {
    const diagnostics = authority.diagnostics();
    if (diagnostics.internal_outcomes.occupancy != 0 or
        diagnostics.internal_outcomes.reservations != 0 or
        diagnostics.producers.ingress.occupancy != 0 or
        diagnostics.producers.transactions.occupancy != 0 or
        diagnostics.producers.delivery.occupancy != 0 or
        diagnostics.world.crates.outcomes.occupancy != 0 or
        diagnostics.world.characters.outcomes.occupancy != 0 or
        diagnostics.world.characters.events.occupancy != 0 or
        diagnostics.world.vehicles.outcomes.occupancy != 0 or
        diagnostics.world.vehicles.events.occupancy != 0 or
        diagnostics.world.district.outcomes.occupancy != 0 or
        diagnostics.world.district.outcome_reservations != 0 or
        diagnostics.world.district.events.occupancy != 0 or
        diagnostics.world.interaction.outcomes.occupancy != 0 or
        diagnostics.world.npc.outcomes.occupancy != 0 or
        diagnostics.world.npc.events.occupancy != 0)
    {
        return error.M3TypedOutputBoundaryNotEmpty;
    }
}

fn requireIntegratedState(
    world: *simulation.Simulation,
    state: *const IntegratedState,
) !void {
    const diagnostics = world.diagnostics();
    if (diagnostics.district.active_count != 2 or
        diagnostics.district.body_count != 6 or
        diagnostics.characters.active_count != 1 or
        diagnostics.vehicles.active_count != 1 or
        diagnostics.interaction.active_count != 1 or
        diagnostics.interaction.dynamic_body_count != 1 or
        npcCount(diagnostics) != sandbox_contracts.npc_capacity or
        diagnostics.npc.controller_count != sandbox_contracts.npc_capacity or
        diagnostics.body_count != 10 or
        diagnostics.character_controllers.native_used != sandbox_contracts.npc_capacity + 1 or
        diagnostics.character_controllers.native_capacity != 128 or
        diagnostics.character_controllers.feature_owned != sandbox_contracts.npc_capacity + 1 or
        !diagnostics.character_controllers.authority_consistent)
    {
        return error.M3IntegratedSliceCountMismatch;
    }
    if (world.districtStateFor(west) != .active or
        world.districtStateFor(east) != .active)
    {
        return error.M3IntegratedDistrictStateMismatch;
    }
    _ = try world.character(state.character);
    _ = try world.vehicle(state.vehicle);
    const carryable = try world.carryable(state.carryable);
    if (!carryable.body_present or !std.meta.eql(carryable.ownership, .{
        .spatially_owned = west,
    })) return error.M3IntegratedCarryableOwnershipMismatch;
    for (state.npcs) |id| _ = try world.npc(id);
    if (diagnostics.characters.events.rejected != 0 or
        diagnostics.vehicles.events.rejected != 0 or
        diagnostics.district.events.rejected != 0 or
        diagnostics.npc.events.rejected != 0)
    {
        return error.M3IntegratedEventDropDetected;
    }
}

fn npcCount(diagnostics: sandbox_diagnostics.Diagnostics) u32 {
    return diagnostics.npc.active_count + diagnostics.npc.waiting_count +
        diagnostics.npc.dormant_count;
}

fn featureQueueInventory(
    diagnostics: sandbox_diagnostics.Diagnostics,
    metrics: Metrics,
) FeatureQueueInventory {
    return .{
        .crate_commands = featureQueueSummary(diagnostics.crates.commands),
        .crate_outcomes = featureQueueSummary(diagnostics.crates.outcomes),
        .character_commands = featureQueueSummary(diagnostics.characters.commands),
        .character_outcomes = featureQueueSummary(diagnostics.characters.outcomes),
        .character_events = featureQueueSummary(diagnostics.characters.events),
        .character_event_drops = diagnostics.characters.events_dropped,
        .vehicle_commands = featureQueueSummary(diagnostics.vehicles.commands),
        .vehicle_outcomes = featureQueueSummary(diagnostics.vehicles.outcomes),
        .vehicle_events = featureQueueSummary(diagnostics.vehicles.events),
        .vehicle_event_drops = diagnostics.vehicles.events_dropped,
        .district_commands = featureQueueSummary(diagnostics.district.commands),
        .district_outcomes = featureQueueSummary(diagnostics.district.outcomes),
        .district_outcome_reservation_high_water = metrics.district_outcome_reservation_peak,
        .district_outcome_final_reservations = diagnostics.district.outcome_reservations,
        .district_events = featureQueueSummary(diagnostics.district.events),
        .interaction_commands = featureQueueSummary(diagnostics.interaction.commands),
        .interaction_outcomes = featureQueueSummary(diagnostics.interaction.outcomes),
        .npc_commands = featureQueueSummary(diagnostics.npc.commands),
        .npc_outcomes = featureQueueSummary(diagnostics.npc.outcomes),
        .npc_events = featureQueueSummary(diagnostics.npc.events),
        .npc_event_drop_state_changed = diagnostics.npc.event_drops.state_changed,
        .npc_event_drop_owner_transferred = diagnostics.npc.event_drops.owner_transferred,
        .npc_event_drop_goal_reached = diagnostics.npc.event_drops.goal_reached,
    };
}

fn featureQueueSummary(queue: anytype) QueueSummary {
    return .{
        .capacity = queue.capacity.?,
        .high_water = queue.high_water,
        .rejected = queue.rejected,
        .final_occupancy = queue.occupancy,
    };
}

fn externalQueueSummary(queue: external_producers.QueueStats) QueueSummary {
    return .{
        .capacity = queue.capacity,
        .high_water = queue.high_water,
        .rejected = queue.rejected,
        .final_occupancy = queue.occupancy,
    };
}

fn producerInventory(
    final: headless_authority.ProducerDiagnostics,
    before_unregister: headless_authority.ProducerDiagnostics,
    metrics: Metrics,
) ProducerInventory {
    var slots: [producer_count]ProducerSlotInventory = undefined;
    var final_unread: u32 = 0;
    for (&slots, 0..) |*output, index| {
        const before = before_unregister.slots[index];
        const final_slot = final.slots[index];
        final_unread +|= final_slot.unread_results;
        output.* = .{
            .result_queue = .{
                .capacity = before.results.capacity,
                .high_water = before.results.high_water,
                .rejected = before.results.rejected,
                .final_occupancy = final_slot.results.occupancy,
            },
            .delivery_queue = .{
                .capacity = before.delivery.capacity,
                .high_water = before.delivery.high_water,
                .rejected = before.delivery.rejected,
                .final_occupancy = final_slot.delivery.occupancy,
            },
            .pending_high_water = before.pending_high_water,
            .admission_rejected = before.admission_rejected,
            .final_pending = final_slot.pending,
            .final_unread_results = final_slot.unread_results,
        };
    }
    const accepted = metrics.submitted[0] + metrics.submitted[1];
    const completed = metrics.completed[0] + metrics.completed[1];
    const rejected = final.rejections.shutting_down +
        final.rejections.stale_handle + final.rejections.invalid_transaction_id +
        final.rejections.duplicate_transaction_id +
        final.rejections.producer_quota_full +
        final.rejections.result_capacity_full + final.rejections.ingress_full +
        final.rejections.transaction_table_full;
    return .{
        .registration_attempts = 3,
        .registrations_succeeded = producer_count,
        .registrations_rejected = final.rejections.registration,
        .accepted_transactions = accepted,
        .retry_later_transactions = 0,
        .rejected_transactions = rejected,
        .completed_transactions = completed,
        .terminal_submission_rejections = final.rejections.terminal_submission_rejected,
        .outcomes_handed_back = final.outcomes_handed_back,
        .expected_internal_non_relocation_handbacks = expected_internal_non_relocation_handbacks,
        .protocol_fault_handbacks = final.outcomes_handed_back -|
            expected_internal_non_relocation_handbacks,
        .final_registered = final.producers.occupancy,
        .final_unread_results = final_unread,
        .producer_slots = slots,
        .producers = externalQueueSummary(final.producers),
        .ingress = externalQueueSummary(final.ingress),
        .transactions = externalQueueSummary(final.transactions),
        .delivery = externalQueueSummary(final.delivery),
        .rejection_counters = final.rejections,
    };
}

fn timedAuthorityTick(
    authority: *headless_authority.Authority,
    transfer_budget: usize,
    samples: []u64,
    cursor: *usize,
    io: std.Io,
) !headless_authority.TickReport {
    if (cursor.* >= samples.len) return error.M3TooManyTimingSamples;
    const start = now(io);
    const report = try authority.tick(transfer_budget);
    samples[cursor.*] = elapsedNs(start, now(io));
    cursor.* += 1;
    return report;
}

fn summarize(samples: []u64) Distribution {
    std.debug.assert(samples.len > 0);
    std.mem.sort(u64, samples, {}, lessThanU64);
    var total: u128 = 0;
    for (samples) |sample| total += sample;
    const total_ns = std.math.cast(u64, total) orelse std.math.maxInt(u64);
    return .{
        .samples = @intCast(samples.len),
        .total_ns = total_ns,
        .mean_ns = @as(f64, @floatFromInt(total)) /
            @as(f64, @floatFromInt(samples.len)),
        .p50_ns = samples[percentileIndex(samples.len, 50)],
        .p95_ns = samples[percentileIndex(samples.len, 95)],
        .p99_ns = samples[percentileIndex(samples.len, 99)],
        .max_ns = samples[samples.len - 1],
    };
}

fn percentileIndex(len: usize, percentile: usize) usize {
    return (len * percentile + 99) / 100 - 1;
}

fn lessThanU64(_: void, lhs: u64, rhs: u64) bool {
    return lhs < rhs;
}

fn now(io: std.Io) std.Io.Clock.Timestamp {
    return std.Io.Clock.Timestamp.now(io, .awake);
}

fn elapsedNs(start: std.Io.Clock.Timestamp, end: std.Io.Clock.Timestamp) u64 {
    const nanoseconds = start.durationTo(end).raw.nanoseconds;
    if (nanoseconds <= 0) return 0;
    return std.math.cast(u64, nanoseconds) orelse std.math.maxInt(u64);
}

fn throughput(ticks: u64, elapsed_ns: u64) f64 {
    if (elapsed_ns == 0) return 0;
    return @as(f64, @floatFromInt(ticks)) *
        @as(f64, std.time.ns_per_s) / @as(f64, @floatFromInt(elapsed_ns));
}

fn maxRssBytes() usize {
    const value = std.posix.getrusage(std.posix.rusage.SELF).maxrss;
    if (value <= 0) return 0;
    return @intCast(value);
}

fn cohortDigest(bytes: []const u8) sandbox_save.Digest {
    var digest: sandbox_save.Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return digest;
}

fn validateCeilings(report: *const Report) !void {
    if (report.performance.authority_tick.p99_ns > p99_ceiling_ns) {
        return error.M3AuthorityTickP99CeilingExceeded;
    }
    if (report.persistence.snapshot_payload_bytes > snapshot_ceiling_bytes) {
        return error.M3SnapshotPayloadCeilingExceeded;
    }
    if (report.persistence.envelope_bytes > envelope_ceiling_bytes) {
        return error.M3SaveEnvelopeCeilingExceeded;
    }
    if (report.resources.allocator_peak_bytes > allocator_peak_ceiling_bytes) {
        return error.M3AllocatorPeakCeilingExceeded;
    }
    if (report.resources.max_rss_bytes == 0 or
        report.resources.max_rss_bytes > rss_ceiling_bytes)
    {
        return error.M3RssCeilingExceeded;
    }
}

const TrackingAllocator = struct {
    child: std.mem.Allocator,
    live: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    peak: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    fn init(child: std.mem.Allocator) TrackingAllocator {
        return .{ .child = child };
    }

    fn allocator(self: *TrackingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn liveBytes(self: *const TrackingAllocator) usize {
        return self.live.load(.acquire);
    }

    fn peakBytes(self: *const TrackingAllocator) usize {
        return self.peak.load(.acquire);
    }

    fn add(self: *TrackingAllocator, amount: usize) void {
        const old = self.live.fetchAdd(amount, .acq_rel);
        const value = old +| amount;
        var observed = self.peak.load(.acquire);
        while (value > observed) {
            observed = self.peak.cmpxchgWeak(
                observed,
                value,
                .acq_rel,
                .acquire,
            ) orelse break;
        }
    }

    fn subtract(self: *TrackingAllocator, amount: usize) void {
        const old = self.live.fetchSub(amount, .acq_rel);
        std.debug.assert(old >= amount);
    }

    fn alloc(
        context: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const self: *TrackingAllocator = @ptrCast(@alignCast(context));
        const result = self.child.rawAlloc(len, alignment, return_address) orelse
            return null;
        self.add(len);
        return result;
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) bool {
        const self: *TrackingAllocator = @ptrCast(@alignCast(context));
        if (!self.child.rawResize(memory, alignment, new_len, return_address)) return false;
        if (new_len > memory.len) self.add(new_len - memory.len) else self.subtract(memory.len - new_len);
        return true;
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        const self: *TrackingAllocator = @ptrCast(@alignCast(context));
        const result = self.child.rawRemap(
            memory,
            alignment,
            new_len,
            return_address,
        ) orelse return null;
        if (new_len > memory.len) self.add(new_len - memory.len) else self.subtract(memory.len - new_len);
        return result;
    }

    fn free(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) void {
        const self: *TrackingAllocator = @ptrCast(@alignCast(context));
        self.child.rawFree(memory, alignment, return_address);
        self.subtract(memory.len);
    }
};

fn observe(
    authority: *headless_authority.Authority,
    metrics: *Metrics,
    post_warmup: bool,
) !void {
    const diagnostics = authority.diagnostics();
    try validateDiagnostics(diagnostics);
    metrics.internal_outcome_reservation_peak = @max(
        metrics.internal_outcome_reservation_peak,
        diagnostics.internal_outcomes.reservations,
    );
    metrics.district_outcome_reservation_peak = @max(
        metrics.district_outcome_reservation_peak,
        diagnostics.world.district.outcome_reservations,
    );
    if (!post_warmup) return;
    metrics.post_warmup_observations += 1;
    metrics.post_warmup_ingress_peak = @max(
        metrics.post_warmup_ingress_peak,
        diagnostics.producers.ingress.occupancy,
    );
    metrics.post_warmup_transaction_peak = @max(
        metrics.post_warmup_transaction_peak,
        diagnostics.producers.transactions.occupancy,
    );
    metrics.post_warmup_delivery_peak = @max(
        metrics.post_warmup_delivery_peak,
        diagnostics.producers.delivery.occupancy,
    );
    metrics.post_warmup_internal_outcome_peak = @max(
        metrics.post_warmup_internal_outcome_peak,
        diagnostics.internal_outcomes.occupancy,
    );
}

fn validateDiagnostics(diagnostics: headless_authority.Diagnostics) !void {
    if (!diagnostics.healthy or diagnostics.world.first_fault != null or
        !diagnostics.world.character_controllers.authority_consistent)
    {
        return error.M3AuthorityDiagnosticsUnhealthy;
    }
    const producers = diagnostics.producers;
    if (producers.producers.capacity != headless_authority.producer_limits.producer_capacity or
        producers.ingress.capacity != headless_authority.producer_limits.ingress_capacity or
        producers.transactions.capacity != headless_authority.producer_limits.transaction_capacity or
        producers.delivery.capacity != producer_count *
            headless_authority.producer_limits.result_capacity_per_producer or
        diagnostics.internal_outcomes.capacity != headless_authority.internal_outcome_capacity)
    {
        return error.M3AuthorityQueueCapacityChanged;
    }
    try validateExternalQueue(producers.producers);
    try validateExternalQueue(producers.ingress);
    try validateExternalQueue(producers.transactions);
    try validateExternalQueue(producers.delivery);
    try validateInternalQueue(diagnostics.internal_outcomes);
    for (producers.slots) |slot| {
        try validateExternalQueue(slot.results);
        try validateExternalQueue(slot.delivery);
        if (slot.pending > slot.delivery.capacity or
            slot.unread_results > slot.results.capacity)
        {
            return error.M3ProducerSlotCapacityExceeded;
        }
    }

    const world = diagnostics.world;
    try validateWorldQueue(world.crates.commands);
    try validateWorldQueue(world.crates.outcomes);
    try validateWorldQueue(world.characters.commands);
    try validateWorldQueue(world.characters.outcomes);
    try validateWorldQueue(world.characters.events);
    try validateWorldQueue(world.vehicles.commands);
    try validateWorldQueue(world.vehicles.outcomes);
    try validateWorldQueue(world.vehicles.events);
    try validateWorldQueue(world.district.commands);
    try validateWorldQueue(world.district.outcomes);
    try validateWorldQueue(world.district.events);
    try validateWorldQueue(world.interaction.commands);
    try validateWorldQueue(world.interaction.outcomes);
    try validateWorldQueue(world.npc.commands);
    try validateWorldQueue(world.npc.outcomes);
    try validateWorldQueue(world.npc.events);
    const district_outcome_capacity = world.district.outcomes.capacity.?;
    if (@as(u64, world.district.outcomes.occupancy) +
        world.district.outcome_reservations > district_outcome_capacity)
    {
        return error.M3DistrictOutcomeReservationCapacityExceeded;
    }
}

fn validateExternalQueue(queue: external_producers.QueueStats) !void {
    if (queue.occupancy > queue.capacity or queue.high_water > queue.capacity) {
        return error.M3ExternalQueueCapacityExceeded;
    }
}

fn validateInternalQueue(queue: headless_authority.QueueDiagnostics) !void {
    if (queue.occupancy > queue.capacity or queue.high_water > queue.capacity or
        @as(u64, queue.occupancy) + queue.reservations > queue.capacity)
    {
        return error.M3InternalQueueCapacityExceeded;
    }
}

fn validateWorldQueue(queue: anytype) !void {
    const capacity = queue.capacity orelse return error.M3WorldQueueHasNoDeclaredCapacity;
    if (queue.occupancy > capacity or queue.high_water > capacity) {
        return error.M3WorldQueueCapacityExceeded;
    }
}

fn worldConfig() sandbox_contracts.Config {
    return .{
        .namespace = namespace,
        .max_crates = 8,
        .create_ground = true,
        .character = .{ .max_characters = 1 },
        .vehicle = .{ .max_vehicles = 1 },
        .npc = .{},
    };
}

fn saveMetadata(config: sandbox_contracts.Config) !sandbox_save.Metadata {
    var content_digest: sandbox_save.Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(
        content_cohort,
        &content_digest,
        .{},
    );
    return .{
        .payload_schema = sandbox_contracts.snapshot_schema,
        .simulation_build_digest = try simulation_snapshot.currentSimulationBuildFingerprint(),
        .world_config_digest = try simulation_snapshot.worldConfigFingerprint(config),
        .content_digest = content_digest,
    };
}

fn nextSequence(submitted_count: u64) u64 {
    return submitted_count + 1;
}

fn transactionId(producer_index: usize, sequence: u64) u64 {
    std.debug.assert(producer_index < producer_count);
    std.debug.assert(sequence != 0 and sequence <= std.math.maxInt(u64) >> 1);
    return (sequence << 1) | @as(u64, @intCast(producer_index));
}

fn producerForTransaction(transaction_id: u64) usize {
    return @intCast(transaction_id & 1);
}

fn modeTicks(mode: Mode) u64 {
    return switch (mode) {
        .routine => routine_ticks,
        .long => long_ticks,
    };
}

fn parseInvocation(args: []const []const u8) !Invocation {
    if (args.len < 2) return error.MissingM3SoakMode;
    if (args.len > 2) return error.TooManyM3SoakArguments;
    const raw = args[1];
    if (std.mem.eql(u8, raw, "--help") or std.mem.eql(u8, raw, "-h")) {
        return .help;
    }
    if (std.mem.eql(u8, raw, "routine")) return .{ .run = .routine };
    if (std.mem.eql(u8, raw, "long")) return .{ .run = .long };
    return error.InvalidM3SoakMode;
}

fn writeUsage(io: std.Io) !void {
    var buffer: [512]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buffer);
    try writer.interface.writeAll(
        "usage: incinerator_m3_soak <routine|long>\n" ++
            "  routine  deterministic 32,768-tick readiness gate\n" ++
            "  long     deterministic 131,072-tick readiness gate\n",
    );
    try writer.interface.flush();
}

fn writeJson(io: std.Io, report: Report) !void {
    var buffer: [16 * 1024]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buffer);
    try std.json.Stringify.value(
        report,
        .{ .whitespace = .indent_2 },
        &writer.interface,
    );
    try writer.interface.writeByte('\n');
    try writer.interface.flush();
}

test "M3 soak invocation accepts only the two public cohorts and help" {
    const routine = try parseInvocation(&.{ "m3", "routine" });
    try std.testing.expect(routine == .run and routine.run == .routine);
    const long = try parseInvocation(&.{ "m3", "long" });
    try std.testing.expect(long == .run and long.run == .long);
    try std.testing.expect((try parseInvocation(&.{ "m3", "--help" })) == .help);
    try std.testing.expect((try parseInvocation(&.{ "m3", "-h" })) == .help);
    try std.testing.expectError(error.MissingM3SoakMode, parseInvocation(&.{"m3"}));
    try std.testing.expectError(
        error.InvalidM3SoakMode,
        parseInvocation(&.{ "m3", "overnight" }),
    );
    try std.testing.expectError(
        error.TooManyM3SoakArguments,
        parseInvocation(&.{ "m3", "routine", "extra" }),
    );
}

test "M3 cohorts and transaction namespaces are exact" {
    try std.testing.expectEqual(@as(u64, 32_768), modeTicks(.routine));
    try std.testing.expectEqual(@as(u64, 131_072), modeTicks(.long));
    try std.testing.expectEqual(@as(u64, 14), transactionId(0, 7));
    try std.testing.expectEqual(@as(u64, 19), transactionId(1, 9));
    try std.testing.expectEqual(@as(usize, 0), producerForTransaction(14));
    try std.testing.expectEqual(@as(usize, 1), producerForTransaction(19));
}

test "M3 timing distribution uses nearest-rank percentiles" {
    var samples = [_]u64{ 9, 1, 5, 3, 7, 2, 8, 4, 6, 10 };
    const distribution = summarize(&samples);
    try std.testing.expectEqual(@as(u64, 10), distribution.samples);
    try std.testing.expectEqual(@as(u64, 55), distribution.total_ns);
    try std.testing.expectEqual(@as(f64, 5.5), distribution.mean_ns);
    try std.testing.expectEqual(@as(u64, 5), distribution.p50_ns);
    try std.testing.expectEqual(@as(u64, 10), distribution.p95_ns);
    try std.testing.expectEqual(@as(u64, 10), distribution.p99_ns);
    try std.testing.expectEqual(@as(u64, 10), distribution.max_ns);
}

test "M3 cohort identities are fixed and domain separated" {
    try std.testing.expectEqualStrings(
        "m3-config-v1:namespace=93001,crates=8,characters=1,vehicles=1,npcs=64,ground=true,producers=2,quota=8,ingress=16,transactions=16,results=8",
        config_cohort,
    );
    try std.testing.expectEqualStrings(
        "m3-scenario-v3:district-cancel-activate-unload-reload,s2-live-vehicle,s7-collect-drop,s8-64-npcs,two-producer-relocation-saturation,draining-stop,canonical-cold-restore",
        scenario_cohort,
    );
    const config_digest = cohortDigest(config_cohort);
    const scenario_digest = cohortDigest(scenario_cohort);
    const content_digest = cohortDigest(content_cohort);
    try std.testing.expect(!std.mem.allEqual(u8, &config_digest, 0));
    try std.testing.expect(!std.mem.allEqual(u8, &scenario_digest, 0));
    try std.testing.expect(!std.mem.allEqual(u8, &content_digest, 0));
    try std.testing.expect(!std.mem.eql(u8, &config_digest, &scenario_digest));
    try std.testing.expect(!std.mem.eql(u8, &config_digest, &content_digest));
    try std.testing.expect(!std.mem.eql(u8, &scenario_digest, &content_digest));
    try std.testing.expectEqual(content_digest, (try saveMetadata(worldConfig())).content_digest);
}
