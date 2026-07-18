//! Backend-neutral developer snapshot and export envelope.
//!
//! Feature and adapter owners expose their own typed diagnostic values. Hosts
//! normalize only host-private streaming/GPU/time state here, then text, JSON,
//! headless tests, and ImGui consume the same immutable envelope.

const std = @import("std");
const engine = @import("incinerator_engine");
const developer_controls = @import("developer_controls");
const authority_diagnostics = @import("session_authority_diagnostics");

/// V5 adds completion-aware authoritative-session diagnostics so failures
/// after simulation execution remain visible to the same text, JSON, and UI
/// consumers as runtime-system faults.
pub const schema_version: u16 = 5;
pub const district_stream_slot_count: usize = 2;

pub const ContentWorkerStage = enum {
    idle,
    queued,
    working,
    cancelling,
    completion_ready,
};

pub const ContentCompletionKind = enum {
    ready,
    cancelled,
    failed,
};

pub const ContentWorker = struct {
    stage: ContentWorkerStage,
    generation: u64 = 0,
    thread_started: bool = false,
    cancellation_requested: bool = false,
    completion_kind: ?ContentCompletionKind = null,
};

pub const DistrictStreamState = enum {
    idle,
    reading,
    cancelling_content,
    /// Decode is retained by this slot while the one logical loader finishes
    /// another slot's transition.
    content_ready,
    prefetched,
    request_submitted,
    request_submitted_cancel,
    loading,
    cancelling_logical,
    active,
    unloading,
    draining,
};

pub const DistrictStreamCoord = struct {
    x: i32,
    z: i32,
};

pub const DistrictStreamGenerations = struct {
    /// Exact cooked-content worker generation, absent before a read is owned.
    content: ?u64 = null,
    /// Exact logical district ticket generation, absent before admission.
    logical: ?u64 = null,
};

pub const DistrictStreamSlot = struct {
    coord: DistrictStreamCoord,
    state: DistrictStreamState,
    desired_inside: bool,
    generations: DistrictStreamGenerations = .{},
    /// Host-global lifecycle correlation. Null means the fixed slot does not
    /// currently own a streaming attempt.
    correlation_id: ?u64 = null,
    /// Renderer-owned identity while the slot has a reserved/live/retiring
    /// scene. Null is distinct from any valid generational handle.
    scene: ?engine.rendering.SceneHandle = null,
    pending_decoded_scene: bool = false,
};

pub const DistrictStreamAggregates = struct {
    desired_count: u8 = 0,
    transitioning_count: u8 = 0,
    active_count: u8 = 0,
    draining_count: u8 = 0,
    pending_decoded_scene_count: u8 = 0,
    scene_count: u8 = 0,
};

/// The macOS S6 host has exactly two catalog-backed stream slots. Gathering
/// this value is allocation-free; aggregate counts are derived from the same
/// immutable slot values so every consumer sees one coherent truth.
pub const DistrictStreams = struct {
    slots: [district_stream_slot_count]DistrictStreamSlot,
    aggregates: DistrictStreamAggregates,

    pub fn init(slots: [district_stream_slot_count]DistrictStreamSlot) DistrictStreams {
        var aggregates = DistrictStreamAggregates{};
        for (slots) |slot| {
            if (slot.desired_inside) aggregates.desired_count += 1;
            switch (slot.state) {
                .idle => {},
                .active => aggregates.active_count += 1,
                .draining => {
                    aggregates.transitioning_count += 1;
                    aggregates.draining_count += 1;
                },
                else => aggregates.transitioning_count += 1,
            }
            if (slot.pending_decoded_scene) {
                aggregates.pending_decoded_scene_count += 1;
            }
            if (slot.scene != null) aggregates.scene_count += 1;
        }
        return .{ .slots = slots, .aggregates = aggregates };
    }
};

pub const GpuUsage = struct {
    staged_cpu_bytes: u64 = 0,
    staged_upload_bytes: u64 = 0,
    in_flight_upload_bytes: u64 = 0,
    resident_gpu_bytes: u64 = 0,
    live_scenes: u8 = 0,
    reserved_scenes: u8 = 0,
    staged_scenes: u8 = 0,
    submitted_scenes: u8 = 0,
    retiring_scenes: u8 = 0,
    resident_scenes: u8 = 0,
    active_batches: u8 = 0,
};

pub const GpuLimits = struct {
    scene_capacity: u8,
    batch_capacity: u8,
    scenes_per_batch: u8,
    max_staged_cpu_bytes: u64,
    max_in_flight_upload_bytes: u64,
    max_resident_gpu_bytes: u64,
    max_submit_bytes_per_pump: u64,
};

pub const Gpu = struct {
    current: GpuUsage,
    high_water: GpuUsage,
    limits: GpuLimits,
};

pub const HostTime = struct {
    paused: bool,
    time_scale: developer_controls.TimeScale,
    single_step_pending: bool,
    raw_frame_seconds: f64,
    simulation_frame_seconds: f64,
    ticks_this_frame: u32,
    control_requests_rejected: u64 = 0,
    diagnostic_requests_rejected: u64 = 0,
};

pub const JournalSummary = struct {
    count: u32,
    capacity: u32,
    overwritten: u64,
    rejected_while_frozen: u64,
    rejected_sequence_exhausted: u64,
    sequence_exhausted: bool,
    frozen: bool,
    trigger_armed: bool,
};

pub const Request = union(enum) {
    arm_freeze: engine.diagnostics.FreezeMatch,
    disarm_freeze,
    resume_capture,
    clear,
    export_json,
};

pub const max_frame_requests: usize = 8;

pub const RequestBuffer = struct {
    items: [max_frame_requests]Request = undefined,
    count: u8 = 0,
    rejected: u64 = 0,

    pub fn push(self: *RequestBuffer, request: Request) bool {
        if (self.count == max_frame_requests) {
            self.rejected +|= 1;
            return false;
        }
        self.items[self.count] = request;
        self.count += 1;
        return true;
    }

    pub fn slice(self: *const RequestBuffer) []const Request {
        return self.items[0..self.count];
    }

    pub fn clear(self: *RequestBuffer) void {
        self.count = 0;
    }
};

/// Simulation diagnostics remain feature-owned. The generic parameter keeps
/// this host contract independent of concrete feature modules while producing
/// one concrete type in each composed host.
pub fn Snapshot(comptime SimulationDiagnostics: type) type {
    return struct {
        schema: u16 = schema_version,
        frame_index: ?u64,
        simulation: SimulationDiagnostics,
        /// Null for a raw simulation-only host. Session compositions publish
        /// the canonical copied authority-cycle diagnostics here.
        authority_session: ?authority_diagnostics.Diagnostics,
        content_worker: ?ContentWorker,
        district_streams: ?DistrictStreams,
        gpu: ?Gpu,
        /// Presentation-clock and developer-control state exists only on a
        /// host that owns those capabilities. Headless must report null rather
        /// than fabricate a zero-time visual frame.
        host_time: ?HostTime,
        journal: JournalSummary,
    };
}

pub fn Export(comptime SimulationDiagnostics: type) type {
    return struct {
        schema: u16 = schema_version,
        snapshot: Snapshot(SimulationDiagnostics),
        entries: []const engine.diagnostic_contracts.Entry,
    };
}

fn formatDistrictStreamsAlloc(
    allocator: std.mem.Allocator,
    district_streams: ?DistrictStreams,
) ![]u8 {
    const streams = district_streams orelse
        return allocator.dupe(u8, "district_streams=absent");
    const west = streams.slots[0];
    const east = streams.slots[1];
    const west_scene_index: ?u32 = if (west.scene) |scene| scene.index else null;
    const west_scene_generation: ?u64 = if (west.scene) |scene| scene.generation else null;
    const east_scene_index: ?u32 = if (east.scene) |scene| scene.index else null;
    const east_scene_generation: ?u64 = if (east.scene) |scene| scene.generation else null;
    return std.fmt.allocPrint(
        allocator,
        "district_streams={d} desired={d} transitioning={d} active={d} " ++
            "draining={d} pending={d} scenes={d} " ++
            "stream0=({d},{d})/{s} desired={} correlation={?d} " ++
            "content_gen={?d} logical_gen={?d} scene={?d}:{?d} pending={} " ++
            "stream1=({d},{d})/{s} desired={} correlation={?d} " ++
            "content_gen={?d} logical_gen={?d} scene={?d}:{?d} pending={}",
        .{
            district_stream_slot_count,
            streams.aggregates.desired_count,
            streams.aggregates.transitioning_count,
            streams.aggregates.active_count,
            streams.aggregates.draining_count,
            streams.aggregates.pending_decoded_scene_count,
            streams.aggregates.scene_count,
            west.coord.x,
            west.coord.z,
            @tagName(west.state),
            west.desired_inside,
            west.correlation_id,
            west.generations.content,
            west.generations.logical,
            west_scene_index,
            west_scene_generation,
            west.pending_decoded_scene,
            east.coord.x,
            east.coord.z,
            @tagName(east.state),
            east.desired_inside,
            east.correlation_id,
            east.generations.content,
            east.generations.logical,
            east_scene_index,
            east_scene_generation,
            east.pending_decoded_scene,
        },
    );
}

fn formatNpcDiagnosticsAlloc(allocator: std.mem.Allocator, simulation: anytype) ![]u8 {
    const SimulationDiagnostics = @TypeOf(simulation);
    if (!@hasField(SimulationDiagnostics, "npc")) {
        return allocator.dupe(u8, "npc=absent");
    }

    const npc = simulation.npc;
    const drops = npc.event_drops;
    const total_drops = drops.state_changed +|
        drops.owner_transferred +|
        drops.goal_reached;
    return std.fmt.allocPrint(
        allocator,
        "npc active={d} waiting={d} dormant={d} controllers={d} " ++
            "transfers={d} suspended={d} resumed={d} " ++
            "npc_commands={d}/{?d} peak={d} rejected={d} " ++
            "npc_outcomes={d}/{?d} peak={d} rejected={d} " ++
            "npc_events={d}/{?d} peak={d} rejected={d} " ++
            "npc_event_drops=state:{d} owner:{d} goal:{d} total:{d}",
        .{
            npc.active_count,
            npc.waiting_count,
            npc.dormant_count,
            npc.controller_count,
            npc.transfers,
            npc.controllers_suspended,
            npc.controllers_resumed,
            npc.commands.occupancy,
            npc.commands.capacity,
            npc.commands.high_water,
            npc.commands.rejected,
            npc.outcomes.occupancy,
            npc.outcomes.capacity,
            npc.outcomes.high_water,
            npc.outcomes.rejected,
            npc.events.occupancy,
            npc.events.capacity,
            npc.events.high_water,
            npc.events.rejected,
            drops.state_changed,
            drops.owner_transferred,
            drops.goal_reached,
            total_drops,
        },
    );
}

fn formatNpcEncounterDiagnosticsAlloc(
    allocator: std.mem.Allocator,
    simulation: anytype,
) ![]u8 {
    const SimulationDiagnostics = @TypeOf(simulation);
    if (!@hasField(SimulationDiagnostics, "npc_encounter") or
        !@hasField(SimulationDiagnostics, "npc_replacement"))
    {
        return allocator.dupe(u8, "npc_encounter=absent");
    }
    const encounter = simulation.npc_encounter;
    const replacement = simulation.npc_replacement;
    return std.fmt.allocPrint(
        allocator,
        "npc_encounter records={d} patrol={d} pursue={d} windup={d} recovery={d} " ++
            "search={d} return={d} los={d} deferred={d} acquired={d} switched={d} " ++
            "lost={d} attacks={d}/{d}/{d} reactions={d} trace={d} " ++
            "replacement pending={d} spawning={d} attempts={d} ready={d} retries={d} " ++
            "retry_reasons=inactive:{d} occupied:{d} near:{d} visible:{d}",
        .{
            encounter.records,
            encounter.patrolling,
            encounter.pursuing,
            encounter.attack_windup,
            encounter.attack_recovery,
            encounter.searching,
            encounter.returning,
            encounter.los_queries,
            encounter.los_deferred,
            encounter.targets_acquired,
            encounter.targets_switched,
            encounter.targets_lost,
            encounter.attacks_started,
            encounter.attacks_committed,
            encounter.attacks_cancelled,
            encounter.hit_reactions,
            encounter.transition_history,
            replacement.pending,
            replacement.awaiting_spawn,
            replacement.attempts,
            replacement.replacements_ready,
            replacement.retries,
            replacement.district_inactive,
            replacement.occupied,
            replacement.too_close_to_player,
            replacement.visible_to_player,
        },
    );
}

fn formatCompletedAuthorityStagesAlloc(
    allocator: std.mem.Allocator,
    trace: authority_diagnostics.CycleTrace,
) ![]u8 {
    return switch (trace.count) {
        0 => allocator.dupe(u8, "none"),
        1 => std.fmt.allocPrint(allocator, "{s}", .{@tagName(trace.stages[0])}),
        2 => std.fmt.allocPrint(
            allocator,
            "{s},{s}",
            .{ @tagName(trace.stages[0]), @tagName(trace.stages[1]) },
        ),
        3 => std.fmt.allocPrint(
            allocator,
            "{s},{s},{s}",
            .{
                @tagName(trace.stages[0]),
                @tagName(trace.stages[1]),
                @tagName(trace.stages[2]),
            },
        ),
        4 => std.fmt.allocPrint(
            allocator,
            "{s},{s},{s},{s}",
            .{
                @tagName(trace.stages[0]),
                @tagName(trace.stages[1]),
                @tagName(trace.stages[2]),
                @tagName(trace.stages[3]),
            },
        ),
        5 => std.fmt.allocPrint(
            allocator,
            "{s},{s},{s},{s},{s}",
            .{
                @tagName(trace.stages[0]), @tagName(trace.stages[1]),
                @tagName(trace.stages[2]), @tagName(trace.stages[3]),
                @tagName(trace.stages[4]),
            },
        ),
        6 => std.fmt.allocPrint(
            allocator,
            "{s},{s},{s},{s},{s},{s}",
            .{
                @tagName(trace.stages[0]), @tagName(trace.stages[1]),
                @tagName(trace.stages[2]), @tagName(trace.stages[3]),
                @tagName(trace.stages[4]), @tagName(trace.stages[5]),
            },
        ),
        7 => std.fmt.allocPrint(
            allocator,
            "{s},{s},{s},{s},{s},{s},{s}",
            .{
                @tagName(trace.stages[0]), @tagName(trace.stages[1]),
                @tagName(trace.stages[2]), @tagName(trace.stages[3]),
                @tagName(trace.stages[4]), @tagName(trace.stages[5]),
                @tagName(trace.stages[6]),
            },
        ),
        8 => std.fmt.allocPrint(
            allocator,
            "{s},{s},{s},{s},{s},{s},{s},{s}",
            .{
                @tagName(trace.stages[0]), @tagName(trace.stages[1]),
                @tagName(trace.stages[2]), @tagName(trace.stages[3]),
                @tagName(trace.stages[4]), @tagName(trace.stages[5]),
                @tagName(trace.stages[6]), @tagName(trace.stages[7]),
            },
        ),
        else => error.InvalidAuthorityCycleTrace,
    };
}

fn formatAuthoritySessionAlloc(
    allocator: std.mem.Allocator,
    diagnostics: ?authority_diagnostics.Diagnostics,
) ![]u8 {
    const session = diagnostics orelse
        return allocator.dupe(u8, "authority_session=absent");
    const trace = session.last_cycle;
    const stages = try formatCompletedAuthorityStagesAlloc(allocator, trace);
    defer allocator.free(stages);
    const failed_stage = if (trace.failed_stage) |stage| @tagName(stage) else "none";
    if (session.first_cycle_fault) |fault| {
        return std.fmt.allocPrint(
            allocator,
            "authority_tick={d} authority_cycle=target:{d} completed:{d}->{d} " ++
                "stages:{d}/8[{s}] failed:{s} authority_fault={s}/{s} " ++
                "fault_target={d} fault_completed={d} fault_code={d}",
            .{
                session.tick,
                trace.target_tick,
                trace.completed_tick_before,
                trace.completed_tick_after,
                trace.count,
                stages,
                failed_stage,
                @tagName(fault.stage),
                fault.error_name.slice(),
                fault.target_tick,
                fault.completed_tick,
                fault.error_code,
            },
        );
    }
    return std.fmt.allocPrint(
        allocator,
        "authority_tick={d} authority_cycle=target:{d} completed:{d}->{d} " ++
            "stages:{d}/8[{s}] failed:{s} authority_fault=none",
        .{
            session.tick,
            trace.target_tick,
            trace.completed_tick_before,
            trace.completed_tick_after,
            trace.count,
            stages,
            failed_stage,
        },
    );
}

/// Text is intentionally compact enough for stderr and CI logs. Detailed
/// tools consume the typed value rather than reparsing this rendering.
pub fn formatTextAlloc(
    allocator: std.mem.Allocator,
    snapshot: anytype,
) ![]u8 {
    const paused_text = if (snapshot.host_time) |host_time|
        if (host_time.paused) "true" else "false"
    else
        "absent";
    const scale_text = if (snapshot.host_time) |host_time|
        @tagName(host_time.time_scale)
    else
        "absent";
    const control_requests_rejected: ?u64 = if (snapshot.host_time) |host_time|
        host_time.control_requests_rejected
    else
        null;
    const diagnostic_requests_rejected: ?u64 = if (snapshot.host_time) |host_time|
        host_time.diagnostic_requests_rejected
    else
        null;
    const district_streams_text = try formatDistrictStreamsAlloc(
        allocator,
        snapshot.district_streams,
    );
    defer allocator.free(district_streams_text);
    const npc_text = try formatNpcDiagnosticsAlloc(allocator, snapshot.simulation);
    defer allocator.free(npc_text);
    const npc_encounter_text = try formatNpcEncounterDiagnosticsAlloc(
        allocator,
        snapshot.simulation,
    );
    defer allocator.free(npc_encounter_text);
    const authority_text = try formatAuthoritySessionAlloc(
        allocator,
        snapshot.authority_session,
    );
    defer allocator.free(authority_text);
    const subsystem_text = try std.fmt.allocPrint(
        allocator,
        "{s} {s} {s} {s}",
        .{ district_streams_text, npc_text, npc_encounter_text, authority_text },
    );
    defer allocator.free(subsystem_text);
    if (snapshot.simulation.first_fault) |fault| {
        return std.fmt.allocPrint(
            allocator,
            "diagnostics_v{d} frame={?d} tick={d} fault={s}/{s} " ++
                "fault_system_truncated={} fault_error_truncated={} " ++
                "fault_phase={s} fault_tick={d} fault_code={d} fault_sequence={d} " ++
                "entities={d} bodies={d} active_bodies={d} " ++
                "character_virtual={d}/{d} feature_owned={d} consistent={} " ++
                "journal={d}/{d} " ++
                "overwritten={d} rejected_frozen={d} rejected_exhausted={d} " ++
                "sequence_exhausted={} frozen={} trigger_armed={} paused={s} scale={s} " ++
                "ui_control_rejected={?d} ui_diagnostic_rejected={?d} {s}",
            .{
                snapshot.schema,
                snapshot.frame_index,
                snapshot.simulation.tick_index,
                fault.system_name.slice(),
                fault.error_name.slice(),
                fault.system_name.truncated,
                fault.error_name.truncated,
                @tagName(fault.phase),
                fault.tick_index,
                fault.error_code,
                fault.journal_sequence,
                snapshot.simulation.entity_count,
                snapshot.simulation.body_count,
                snapshot.simulation.active_body_count,
                snapshot.simulation.character_controllers.native_used,
                snapshot.simulation.character_controllers.native_capacity,
                snapshot.simulation.character_controllers.feature_owned,
                snapshot.simulation.character_controllers.authority_consistent,
                snapshot.journal.count,
                snapshot.journal.capacity,
                snapshot.journal.overwritten,
                snapshot.journal.rejected_while_frozen,
                snapshot.journal.rejected_sequence_exhausted,
                snapshot.journal.sequence_exhausted,
                snapshot.journal.frozen,
                snapshot.journal.trigger_armed,
                paused_text,
                scale_text,
                control_requests_rejected,
                diagnostic_requests_rejected,
                subsystem_text,
            },
        );
    }
    return std.fmt.allocPrint(
        allocator,
        "diagnostics_v{d} frame={?d} tick={d} fault=none entities={d} " ++
            "bodies={d} active_bodies={d} " ++
            "character_virtual={d}/{d} feature_owned={d} consistent={} " ++
            "journal={d}/{d} overwritten={d} " ++
            "rejected_frozen={d} rejected_exhausted={d} sequence_exhausted={} " ++
            "frozen={} trigger_armed={} paused={s} scale={s} " ++
            "ui_control_rejected={?d} ui_diagnostic_rejected={?d} {s}",
        .{
            snapshot.schema,
            snapshot.frame_index,
            snapshot.simulation.tick_index,
            snapshot.simulation.entity_count,
            snapshot.simulation.body_count,
            snapshot.simulation.active_body_count,
            snapshot.simulation.character_controllers.native_used,
            snapshot.simulation.character_controllers.native_capacity,
            snapshot.simulation.character_controllers.feature_owned,
            snapshot.simulation.character_controllers.authority_consistent,
            snapshot.journal.count,
            snapshot.journal.capacity,
            snapshot.journal.overwritten,
            snapshot.journal.rejected_while_frozen,
            snapshot.journal.rejected_sequence_exhausted,
            snapshot.journal.sequence_exhausted,
            snapshot.journal.frozen,
            snapshot.journal.trigger_armed,
            paused_text,
            scale_text,
            control_requests_rejected,
            diagnostic_requests_rejected,
            subsystem_text,
        },
    );
}

/// JSON allocation occurs only on an explicit export path, never while
/// gathering the fixed diagnostic snapshot.
pub fn formatJsonAlloc(
    allocator: std.mem.Allocator,
    value: anytype,
) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, value, .{});
}

const TestNpcEventDrops = struct {
    state_changed: u64 = 0,
    owner_transferred: u64 = 0,
    goal_reached: u64 = 0,
};

const TestNpcDiagnostics = struct {
    active_count: u32 = 0,
    waiting_count: u32 = 0,
    dormant_count: u32 = 0,
    controller_count: u32 = 0,
    transfers: u64 = 0,
    controllers_suspended: u64 = 0,
    controllers_resumed: u64 = 0,
    commands: engine.diagnostic_contracts.QueueStats = .{},
    outcomes: engine.diagnostic_contracts.QueueStats = .{},
    events: engine.diagnostic_contracts.QueueStats = .{},
    event_drops: TestNpcEventDrops = .{},
};

const TestCharacterControllerDiagnostics = struct {
    native_used: u32 = 0,
    native_capacity: u32 = 128,
    feature_owned: u32 = 0,
    authority_consistent: bool = true,
};

const TestSimulationDiagnostics = struct {
    tick_index: u64,
    fixed_delta_seconds: f32,
    first_fault: ?engine.runtime.RuntimeFault,
    entity_count: u32,
    body_count: u32,
    active_body_count: u32,
    character_controllers: TestCharacterControllerDiagnostics = .{},
    npc: TestNpcDiagnostics = .{},
};

test "one typed snapshot feeds compact text and structured JSON" {
    const SnapshotV5 = Snapshot(TestSimulationDiagnostics);
    const value = SnapshotV5{
        .frame_index = 9,
        .simulation = .{
            .tick_index = 17,
            .fixed_delta_seconds = 1.0 / 120.0,
            .first_fault = null,
            .entity_count = 3,
            .body_count = 4,
            .active_body_count = 2,
            .character_controllers = .{
                .native_used = 3,
                .feature_owned = 3,
            },
            .npc = .{
                .active_count = 2,
                .waiting_count = 1,
                .dormant_count = 1,
                .controller_count = 3,
                .transfers = 4,
                .controllers_suspended = 5,
                .controllers_resumed = 6,
                .commands = .{
                    .occupancy = 7,
                    .high_water = 8,
                    .capacity = 128,
                    .rejected = 9,
                },
                .outcomes = .{
                    .occupancy = 10,
                    .high_water = 11,
                    .capacity = 128,
                },
                .events = .{
                    .occupancy = 12,
                    .high_water = 13,
                    .capacity = 256,
                    .rejected = 60,
                },
                .event_drops = .{
                    .state_changed = 10,
                    .owner_transferred = 20,
                    .goal_reached = 30,
                },
            },
        },
        .authority_session = null,
        .content_worker = null,
        .district_streams = DistrictStreams.init(.{
            .{
                .coord = .{ .x = 0, .z = 0 },
                .state = .active,
                .desired_inside = true,
                .generations = .{ .content = 21, .logical = 22 },
                .correlation_id = 23,
                .scene = .{ .index = 1, .generation = 24 },
            },
            .{
                .coord = .{ .x = 1, .z = 0 },
                .state = .content_ready,
                .desired_inside = true,
                .generations = .{ .content = 25 },
                .correlation_id = 26,
                .scene = .{ .index = 2, .generation = 27 },
                .pending_decoded_scene = true,
            },
        }),
        .gpu = null,
        .host_time = .{
            .paused = false,
            .time_scale = .normal,
            .single_step_pending = false,
            .raw_frame_seconds = 1.0 / 240.0,
            .simulation_frame_seconds = 1.0 / 240.0,
            .ticks_this_frame = 0,
        },
        .journal = .{
            .count = 2,
            .capacity = 256,
            .overwritten = 0,
            .rejected_while_frozen = 0,
            .rejected_sequence_exhausted = 0,
            .sequence_exhausted = false,
            .frozen = false,
            .trigger_armed = false,
        },
    };

    const text_value = try formatTextAlloc(std.testing.allocator, value);
    defer std.testing.allocator.free(text_value);
    try std.testing.expect(std.mem.indexOf(u8, text_value, "diagnostics_v5") != null);
    try std.testing.expect(std.mem.indexOf(u8, text_value, "tick=17") != null);
    try std.testing.expect(std.mem.indexOf(u8, text_value, "entities=3") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        text_value,
        "character_virtual=3/128 feature_owned=3 consistent=true",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        text_value,
        "district_streams=2 desired=2 transitioning=1 active=1",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        text_value,
        "stream1=(1,0)/content_ready",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        text_value,
        "npc active=2 waiting=1 dormant=1 controllers=3 transfers=4 suspended=5 resumed=6",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        text_value,
        "npc_commands=7/128 peak=8 rejected=9",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        text_value,
        "npc_outcomes=10/128 peak=11 rejected=0",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        text_value,
        "npc_events=12/256 peak=13 rejected=60",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        text_value,
        "npc_event_drops=state:10 owner:20 goal:30 total:60",
    ) != null);

    const json = try formatJsonAlloc(std.testing.allocator, value);
    defer std.testing.allocator.free(json);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(
        @as(i64, schema_version),
        parsed.value.object.get("schema").?.integer,
    );
    try std.testing.expectEqual(
        @as(i64, 17),
        parsed.value.object.get("simulation").?.object.get("tick_index").?.integer,
    );
    const character_controllers = parsed.value.object.get("simulation").?.object
        .get("character_controllers").?.object;
    try std.testing.expectEqual(
        @as(i64, 3),
        character_controllers.get("native_used").?.integer,
    );
    try std.testing.expectEqual(
        @as(i64, 128),
        character_controllers.get("native_capacity").?.integer,
    );
    try std.testing.expectEqual(
        @as(i64, 3),
        character_controllers.get("feature_owned").?.integer,
    );
    try std.testing.expect(character_controllers.get("authority_consistent").?.bool);
    const npc = parsed.value.object.get("simulation").?.object.get("npc").?.object;
    try std.testing.expectEqual(@as(i64, 2), npc.get("active_count").?.integer);
    try std.testing.expectEqual(@as(i64, 1), npc.get("waiting_count").?.integer);
    try std.testing.expectEqual(@as(i64, 1), npc.get("dormant_count").?.integer);
    try std.testing.expectEqual(@as(i64, 3), npc.get("controller_count").?.integer);
    try std.testing.expectEqual(@as(i64, 4), npc.get("transfers").?.integer);
    try std.testing.expectEqual(@as(i64, 5), npc.get("controllers_suspended").?.integer);
    try std.testing.expectEqual(@as(i64, 6), npc.get("controllers_resumed").?.integer);
    const npc_commands = npc.get("commands").?.object;
    try std.testing.expectEqual(@as(i64, 7), npc_commands.get("occupancy").?.integer);
    try std.testing.expectEqual(@as(i64, 8), npc_commands.get("high_water").?.integer);
    try std.testing.expectEqual(@as(i64, 128), npc_commands.get("capacity").?.integer);
    try std.testing.expectEqual(@as(i64, 9), npc_commands.get("rejected").?.integer);
    const npc_outcomes = npc.get("outcomes").?.object;
    try std.testing.expectEqual(@as(i64, 10), npc_outcomes.get("occupancy").?.integer);
    try std.testing.expectEqual(@as(i64, 11), npc_outcomes.get("high_water").?.integer);
    try std.testing.expectEqual(@as(i64, 128), npc_outcomes.get("capacity").?.integer);
    try std.testing.expectEqual(@as(i64, 0), npc_outcomes.get("rejected").?.integer);
    const npc_events = npc.get("events").?.object;
    try std.testing.expectEqual(@as(i64, 12), npc_events.get("occupancy").?.integer);
    try std.testing.expectEqual(@as(i64, 13), npc_events.get("high_water").?.integer);
    try std.testing.expectEqual(@as(i64, 256), npc_events.get("capacity").?.integer);
    try std.testing.expectEqual(@as(i64, 60), npc_events.get("rejected").?.integer);
    const npc_event_drops = npc.get("event_drops").?.object;
    try std.testing.expectEqual(@as(i64, 10), npc_event_drops.get("state_changed").?.integer);
    try std.testing.expectEqual(@as(i64, 20), npc_event_drops.get("owner_transferred").?.integer);
    try std.testing.expectEqual(@as(i64, 30), npc_event_drops.get("goal_reached").?.integer);
    const streams = parsed.value.object.get("district_streams").?.object;
    try std.testing.expectEqual(
        @as(usize, district_stream_slot_count),
        streams.get("slots").?.array.items.len,
    );
    try std.testing.expectEqual(
        @as(i64, 1),
        streams.get("aggregates").?.object.get("active_count").?.integer,
    );
    try std.testing.expectEqual(
        @as(i64, 26),
        streams.get("slots").?.array.items[1].object.get("correlation_id").?.integer,
    );
    try std.testing.expectEqualStrings(
        "content_ready",
        streams.get("slots").?.array.items[1].object.get("state").?.string,
    );
}

test "authority-only cycle fault is truthful in text and JSON" {
    var session = std.mem.zeroes(authority_diagnostics.Diagnostics);
    session.tick = 7;
    session.last_cycle = .{
        .target_tick = 8,
        .completed_tick_before = 7,
        .completed_tick_after = 8,
        .stages = .{
            .ingress_freeze,
            .admission,
            .semantic_work,
            .simulation,
            .ingress_freeze,
            .ingress_freeze,
            .ingress_freeze,
            .ingress_freeze,
        },
        .count = 4,
        .failed_stage = .outcome_drain,
    };
    session.first_cycle_fault = .{
        .stage = .outcome_drain,
        .target_tick = 8,
        .completed_tick = 8,
        .error_code = @intFromError(error.AuthorityOutcomeDrainFailed),
        .error_name = engine.runtime.FaultText.copy("AuthorityOutcomeDrainFailed"),
    };
    const value = Snapshot(TestSimulationDiagnostics){
        .frame_index = 12,
        .simulation = .{
            .tick_index = 8,
            .fixed_delta_seconds = 1.0 / 60.0,
            .first_fault = null,
            .entity_count = 1,
            .body_count = 1,
            .active_body_count = 1,
        },
        .authority_session = session,
        .content_worker = null,
        .district_streams = null,
        .gpu = null,
        .host_time = null,
        .journal = .{
            .count = 0,
            .capacity = 256,
            .overwritten = 0,
            .rejected_while_frozen = 0,
            .rejected_sequence_exhausted = 0,
            .sequence_exhausted = false,
            .frozen = false,
            .trigger_armed = false,
        },
    };

    const text_value = try formatTextAlloc(std.testing.allocator, value);
    defer std.testing.allocator.free(text_value);
    try std.testing.expect(std.mem.indexOf(
        u8,
        text_value,
        "stages:4/8[ingress_freeze,admission,semantic_work,simulation] failed:outcome_drain",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        text_value,
        "authority_fault=outcome_drain/AuthorityOutcomeDrainFailed",
    ) != null);

    const export_value = Export(TestSimulationDiagnostics){
        .snapshot = value,
        .entries = &.{},
    };
    const json = try formatJsonAlloc(std.testing.allocator, export_value);
    defer std.testing.allocator.free(json);
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        json,
        .{},
    );
    defer parsed.deinit();
    const authority = parsed.value.object.get("snapshot").?.object
        .get("authority_session").?.object;
    try std.testing.expectEqual(
        @as(i64, 4),
        authority.get("last_cycle").?.object.get("count").?.integer,
    );
    try std.testing.expectEqualStrings(
        "outcome_drain",
        authority.get("first_cycle_fault").?.object.get("stage").?.string,
    );
}

test "compact text retains actionable first-fault context and visible truncation" {
    var value = Snapshot(TestSimulationDiagnostics){
        .frame_index = null,
        .simulation = .{
            .tick_index = 8,
            .fixed_delta_seconds = 1.0 / 120.0,
            .first_fault = .{
                .phase = .post_physics,
                .tick_index = 8,
                .journal_sequence = 12,
                .error_code = @intFromError(error.TestDiagnosticFault),
                .system_name = engine.runtime.FaultText.copy("district_apply"),
                .error_name = engine.runtime.FaultText.copy("TestDiagnosticFault"),
            },
            .entity_count = 2,
            .body_count = 3,
            .active_body_count = 1,
        },
        .authority_session = null,
        .content_worker = null,
        .district_streams = null,
        .gpu = null,
        .host_time = .{
            .paused = true,
            .time_scale = .normal,
            .single_step_pending = false,
            .raw_frame_seconds = 0,
            .simulation_frame_seconds = 0,
            .ticks_this_frame = 0,
        },
        .journal = .{
            .count = 1,
            .capacity = 256,
            .overwritten = 0,
            .rejected_while_frozen = 2,
            .rejected_sequence_exhausted = 0,
            .sequence_exhausted = false,
            .frozen = true,
            .trigger_armed = false,
        },
    };
    const text_value = try formatTextAlloc(std.testing.allocator, value);
    defer std.testing.allocator.free(text_value);
    try std.testing.expect(std.mem.indexOf(u8, text_value, "district_apply") != null);
    try std.testing.expect(std.mem.indexOf(u8, text_value, "TestDiagnosticFault") != null);
    try std.testing.expect(std.mem.indexOf(u8, text_value, "fault_phase=post_physics") != null);
    try std.testing.expect(std.mem.indexOf(u8, text_value, "fault_sequence=12") != null);
    try std.testing.expect(std.mem.indexOf(u8, text_value, "rejected_frozen=2") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        text_value,
        "district_streams=absent",
    ) != null);

    const long_system_name = [_]u8{'s'} ** (engine.runtime.max_fault_name_bytes + 1);
    const long_error_name = [_]u8{'e'} ** (engine.runtime.max_fault_name_bytes + 1);
    var truncated_fault = value.simulation.first_fault.?;
    truncated_fault.system_name = engine.runtime.FaultText.copy(&long_system_name);
    truncated_fault.error_name = engine.runtime.FaultText.copy(&long_error_name);
    value.simulation.first_fault = truncated_fault;
    const truncated_text = try formatTextAlloc(std.testing.allocator, value);
    defer std.testing.allocator.free(truncated_text);
    try std.testing.expect(std.mem.indexOf(
        u8,
        truncated_text,
        "fault_system_truncated=true fault_error_truncated=true",
    ) != null);
}

test "diagnostic request mailbox is fixed and visibly saturates" {
    var requests = RequestBuffer{};
    for (0..max_frame_requests) |_| {
        try std.testing.expect(requests.push(.resume_capture));
    }
    try std.testing.expect(!requests.push(.clear));
    try std.testing.expectEqual(@as(u64, 1), requests.rejected);
    try std.testing.expectEqual(max_frame_requests, requests.slice().len);
    requests.clear();
    try std.testing.expectEqual(@as(usize, 0), requests.slice().len);
    try std.testing.expectEqual(@as(u64, 1), requests.rejected);
}
