//! main.zig - Incinerator Engine Entry Point
//!
//! DOMAIN: Application Layer (top-level orchestration)
//!
//! This module is the entry point and main orchestrator for the engine.
//! It owns the game loop and coordinates between all other systems.
//!
//! Responsibilities:
//! - Application lifecycle (init, run, shutdown)
//! - Game loop orchestration (input → simulation → render)
//! - Owning and wiring together engine systems
//!
//! This module does NOT:
//! - Contain character/crate simulation policy (features own that behavior)
//! - Perform low-level rendering (that's renderer.zig)
//! - Define simulation feature behavior
//!
//! The Canonical Game Loop:
//!
//! ┌─────────────────────────────────────────────────────────────┐
//! │ Phase 1: INPUT PUMP (Per-Frame / Uncapped)                  │
//! │ - Drains OS events, latches actions to the Input Buffer     │
//! ├─────────────────────────────────────────────────────────────┤
//! │ Phase 2: SIMULATION TICK (Fixed 120Hz)                      │
//! │ - Physics, gameplay logic, consume buffered input           │
//! ├─────────────────────────────────────────────────────────────┤
//! │ Phase 3: PRESENTATION (Interpolated)                        │
//! │ - Renders visual state via SDL3 GPU API                     │
//! └─────────────────────────────────────────────────────────────┘

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const engine = @import("incinerator_engine");
const zm = @import("zmath");
const timing = @import("timing.zig");
const input = @import("input.zig");
const renderer = @import("renderer.zig");
const mesh = @import("mesh.zig");
const primitives = @import("primitives.zig");
const sandbox_visual_resources = @import("sandbox_visual_resources.zig");
const district_gpu_registry = @import("district_gpu_registry.zig");
const district_scene_adapter = @import("district_scene_adapter.zig");
const district_presentation = @import("district_presentation");
const district_content_catalog = @import("district_content_catalog");
const content = @import("content");
const sandbox_controls = @import("sandbox_controls.zig");
const developer_controls = @import("developer_controls");
const developer_diagnostics = @import("developer_diagnostics");
const developer_profile = @import("developer_profile");
const developer_visualization = @import("developer_visualization");
const sandbox_authoring = @import("sandbox_authoring");
const sandbox_interaction = @import("sandbox_interaction");
const sandbox_replay = @import("sandbox_replay");
const sandbox_save = @import("sandbox_save");
const save_slots = @import("save_slots");
const physics_debug_gpu = @import("physics_debug_gpu.zig");
const camera = @import("camera.zig");
const sdl = @import("sdl.zig");
const shader_assets = @import("shader_assets");
const editor = if (build_options.editor_enabled)
    @import("editor/editor.zig")
else
    @import("editor/disabled.zig");
const editor_contract = @import("editor/tool.zig");
const sandbox_host = @import("local_solo_session");
const population = @import("population_feature");
const DeveloperSnapshot = developer_diagnostics.Snapshot(sandbox_host.Diagnostics);
const DeveloperExport = developer_diagnostics.Export(sandbox_host.Diagnostics);
const NpcDiagnostics = @FieldType(sandbox_host.Diagnostics, "npc");
const CharacterControllerDiagnostics = @FieldType(
    sandbox_host.Diagnostics,
    "character_controllers",
);
// Use shared SDL bindings to avoid opaque type conflicts
const c = sdl.c;

fn profileNowNs() u64 {
    return c.SDL_GetTicksNS();
}

fn profilePhase(phase: engine.Phase) developer_profile.Phase {
    return switch (phase) {
        .commands => .runtime_commands,
        .pre_physics => .runtime_pre_physics,
        .physics => .physics,
        .post_physics => .runtime_post_physics,
    };
}

/// Return only an explicit overlay authorization request. Merely observing the
/// controller's retained `enabled=true` state must not clear a GPU failure
/// latch on every editor frame.
fn requestedVisualizationEnable(
    requests: []const developer_visualization.Request,
) ?bool {
    var requested: ?bool = null;
    for (requests) |request| switch (request) {
        .set_enabled => |enabled| requested = enabled,
        else => {},
    };
    return requested;
}

fn saveDeferralDetail(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.CommandsPending => "simulation commands pending",
        error.DistrictTransitionPending => "district transition pending",
        else => null,
    };
}

fn authoringRejectionDetail(reason: sandbox_host.RejectionReason) []const u8 {
    return switch (reason) {
        .capacity_reached => "crate authority capacity reached",
        .crate_not_found => "crate no longer exists",
        .not_owned => "persistent ID is not owned by the crate feature",
        .state_conflict => "authoring revision conflict",
    };
}

/// Classify only the ordinary, recoverable domain outcomes produced by the
/// interactive host. Scripted smoke modes retain their stricter fail-fast
/// contract, while normal play must remain usable after a rejected action.
fn interactiveVehicleRejectionExpected(
    rejected: sandbox_host.VehicleCommandRejected,
) bool {
    return switch (rejected.command) {
        .enter => rejected.reason == .too_far or
            rejected.reason == .driver_carrying,
        .exit => rejected.reason == .exit_blocked,
        .spawn, .drive, .abandon, .despawn => false,
    };
}

const RuntimeProfileBridge = struct {
    recorder: *developer_profile.DefaultRecorder,
    frame_index: u64,
    open: [std.meta.tags(engine.Phase).len]?developer_profile.SpanToken =
        @splat(null),

    fn observer(self: *RuntimeProfileBridge) engine.PhaseObserver {
        return .{
            .context = self,
            .begin_fn = begin,
            .end_fn = end,
        };
    }

    fn begin(raw: *anyopaque, phase: engine.Phase, tick: engine.TickContext) void {
        const self: *RuntimeProfileBridge = @ptrCast(@alignCast(raw));
        const index: usize = @intFromEnum(phase);
        if (self.open[index]) |stale| {
            _ = self.recorder.spans.finish(stale, profileNowNs(), .failure);
        }
        self.open[index] = self.recorder.spans.begin(
            profilePhase(phase),
            self.frame_index,
            tick.tick_index,
            profileNowNs(),
        );
    }

    fn end(
        raw: *anyopaque,
        phase: engine.Phase,
        _: engine.TickContext,
        outcome: engine.PhaseOutcome,
    ) void {
        const self: *RuntimeProfileBridge = @ptrCast(@alignCast(raw));
        const index: usize = @intFromEnum(phase);
        const token = self.open[index] orelse return;
        self.open[index] = null;
        _ = self.recorder.spans.finish(
            token,
            profileNowNs(),
            switch (outcome) {
                .succeeded => .success,
                .failed => .failure,
            },
        );
    }
};

const HostProfileScope = struct {
    recorder: *developer_profile.DefaultRecorder,
    token: ?developer_profile.SpanToken,

    fn finish(self: *HostProfileScope, outcome: developer_profile.Outcome) void {
        const token = self.token orelse return;
        self.token = null;
        _ = self.recorder.spans.finish(token, profileNowNs(), outcome);
    }
};

const HostFrameProfile = struct {
    recorder: *developer_profile.DefaultRecorder,
    token: ?developer_profile.FrameToken,
    counts: developer_profile.Counts = .{},

    fn finish(self: *HostFrameProfile, outcome: developer_profile.Outcome) void {
        const token = self.token orelse return;
        self.token = null;
        _ = self.recorder.frames.finish(token, profileNowNs(), outcome, self.counts);
    }
};

// ============================================================================
// Configuration
// ============================================================================

const WINDOW_TITLE = "Incinerator Engine";
const INITIAL_WINDOW_WIDTH = 1280;
const INITIAL_WINDOW_HEIGHT = 720;

/// How often to print debug stats (in frames)
const DEBUG_PRINT_INTERVAL = 120; // Every ~1 second at 120 FPS
const diagnostic_host_control_applied: engine.diagnostic_contracts.Code = 0x000b_0001;
const diagnostic_host_control_rejected: engine.diagnostic_contracts.Code = 0x000b_0002;
const diagnostic_interactive_vehicle_rejected: engine.diagnostic_contracts.Code = 0x000b_0003;
const physics_debug_line_capacity: usize = 32_768;
const physics_debug_triangle_capacity: usize = 16_384;

/// Best-effort CPU evidence storage. This owner is deliberately optional:
/// failing to reserve debug geometry may remove diagnostics, but must never
/// prevent the visual host or simulation authority from constructing.
const PhysicsDebugCpuStorage = struct {
    allocator: std.mem.Allocator,
    lines: []engine.physics_debug.Line,
    triangles: []engine.physics_debug.Triangle,
    storage: engine.physics_debug.Storage,

    fn init() ?PhysicsDebugCpuStorage {
        return initWithAllocator(std.heap.page_allocator);
    }

    fn initWithAllocator(allocator: std.mem.Allocator) ?PhysicsDebugCpuStorage {
        const lines = allocator.alloc(
            engine.physics_debug.Line,
            physics_debug_line_capacity,
        ) catch |err| {
            std.debug.print(
                "Physics debug CPU line storage unavailable: {s}\n",
                .{@errorName(err)},
            );
            return null;
        };
        const triangles = allocator.alloc(
            engine.physics_debug.Triangle,
            physics_debug_triangle_capacity,
        ) catch |err| {
            allocator.free(lines);
            std.debug.print(
                "Physics debug CPU triangle storage unavailable: {s}\n",
                .{@errorName(err)},
            );
            return null;
        };
        return .{
            .allocator = allocator,
            .lines = lines,
            .triangles = triangles,
            .storage = engine.physics_debug.Storage.init(lines, triangles),
        };
    }

    fn deinit(self: *PhysicsDebugCpuStorage) void {
        self.allocator.free(self.triangles);
        self.allocator.free(self.lines);
        self.* = undefined;
    }
};

const VisualSmokeConfig = struct {
    frames: u64 = 480,
    virtual_render_hz: u32 = 240,
};

const ProgramMode = union(enum) {
    normal,
    verify_install,
    visual_smoke: VisualSmokeConfig,
    s1_visual_smoke: VisualSmokeConfig,
    s2_visual_smoke: VisualSmokeConfig,
    s3_streaming_smoke: VisualSmokeConfig,
    s6_streaming_smoke: VisualSmokeConfig,
    s7_interaction_smoke: VisualSmokeConfig,
    s8_population_smoke: VisualSmokeConfig,
    s4_diagnostics_smoke,
    s4_physics_debug_smoke: VisualSmokeConfig,
    s5_authoring_smoke,
    window_lifecycle_smoke,
    init_failure_smoke,
};

const ProductMode = enum { normal, verify_install };

const BootstrapProfile = enum { sandbox, s0_smoke, s1_smoke, s2_smoke, s3_smoke };

const ScriptedScenario = enum {
    none,
    s1_character,
    s2_vehicle,
    s3_streaming,
    s4_physics_debug,
    s7_interaction,
};

const s2_enter_tick: u64 = 240;
const s2_brake_tick: u64 = 581;
const s2_steer_tick: u64 = 601;
const s2_exit_tick: u64 = 661;
const s2_required_ticks: u64 = 720;

const sandbox_save_slot_id = "sandbox";
const district_stream_slot_count = sandbox_host.district_presentation_policies.len;
const district_west_coord = sandbox_host.navigation_west_coord;
const district_east_coord = sandbox_host.navigation_east_coord;
const district_stream_coords = [district_stream_slot_count]sandbox_host.ChunkCoord{
    sandbox_host.district_presentation_policies[0].coord,
    sandbox_host.district_presentation_policies[1].coord,
};
const district_west_slot_index: usize = 0;
const district_east_slot_index: usize = 1;
const district_proximity_configs = [district_stream_slot_count]district_presentation.ProximityConfig{
    .{
        .center_xz = sandbox_host.district_presentation_policies[0].center_xz,
        .half_extent_xz = sandbox_host.district_presentation_policies[0].half_extent_xz,
        .load_margin = sandbox_host.district_presentation_policies[0].load_margin,
        .unload_margin = sandbox_host.district_presentation_policies[0].unload_margin,
    },
    .{
        .center_xz = sandbox_host.district_presentation_policies[1].center_xz,
        .half_extent_xz = sandbox_host.district_presentation_policies[1].half_extent_xz,
        .load_margin = sandbox_host.district_presentation_policies[1].load_margin,
        .unload_margin = sandbox_host.district_presentation_policies[1].unload_margin,
    },
};
const DistrictPresentation = district_presentation.Coordinator(
    district_gpu_registry.DistrictGpuRegistry,
    sandbox_host.LoadTicket,
);

const DistrictStreamBound = struct {
    scene: engine.rendering.SceneHandle,
    ticket: sandbox_host.LoadTicket,
    load_request_id: u64,
    content_generation: u64,
};

const DistrictStreamReading = struct {
    scene: engine.rendering.SceneHandle,
    generation: u64,
};

const DistrictStreamSubmitted = struct {
    scene: engine.rendering.SceneHandle,
    request_id: u64,
    content_generation: u64,
};

const DistrictStreamCancelling = struct {
    bound: DistrictStreamBound,
    request_id: u64,
};

const DistrictStreamUnloading = struct {
    bound: DistrictStreamBound,
    request_id: u64,
};

const DistrictStreamDraining = struct {
    scene: engine.rendering.SceneHandle,
    content_generation: ?u64,
};

const DistrictContentJob = struct {
    value: DistrictStreamReading,
    cancelling: bool,
};

const DistrictAdmission = struct {
    scene: engine.rendering.SceneHandle,
    request_id: u64,
    content_generation: u64,
    cancel: bool,
};

const DistrictStreamState = union(enum) {
    idle,
    reading: DistrictStreamReading,
    cancelling_content: DistrictStreamReading,
    content_ready: DistrictStreamReading,
    request_submitted: DistrictStreamSubmitted,
    request_submitted_cancel: DistrictStreamSubmitted,
    loading: DistrictStreamBound,
    cancelling_logical: DistrictStreamCancelling,
    active: DistrictStreamBound,
    unloading: DistrictStreamUnloading,
    draining: DistrictStreamDraining,
};

const DistrictStreamSlot = struct {
    coord: sandbox_host.ChunkCoord,
    presentation: DistrictPresentation,
    state: DistrictStreamState = .idle,
    proximity: district_presentation.ProximityHysteresis,
    pending_scene: ?content.bundle.OwnedBundle = null,
    correlation: u64 = 0,
};

const sandbox_block = sandbox_host.StaticBox{
    .position = .{ 0, 1, -5 },
    .half_extents = .{ 2, 1, 0.5 },
};

const FramePresentation = struct {
    crate_count: usize,
    first_id: ?sandbox_host.PersistentId,
    first_position: ?[3]f32,
    first_rotation: ?[4]f32,
    character_count: usize,
    character_id: ?sandbox_host.PersistentId,
    character_position: ?[3]f32,
    vehicle_count: usize,
    vehicle_id: ?sandbox_host.PersistentId,
    district_count: usize,
    carryable_count: usize,
    carryable_id: ?sandbox_host.PersistentId,
    npc_count: usize,
};

const RenderResult = union(enum) {
    ready: FramePresentation,
    unavailable,
};

const RunSummary = struct {
    attempted_frames: u64 = 0,
    ready_frames: u64 = 0,
    unavailable_frames: u64 = 0,
    crate_presented_frames: u64 = 0,
    position_changed: bool = false,
    rotation_changed: bool = false,
    character_presented_frames: u64 = 0,
    character_position_changed: bool = false,
    character_jump_observed: bool = false,
    vehicle_presented_frames: u64 = 0,
    character_hidden_while_driving: bool = false,
    character_visible_after_exit: bool = false,
    min_alpha: f32 = 1.0,
    max_alpha: f32 = 0.0,
};

const S2SmokeProgress = struct {
    entered: bool = false,
    drive_applied: bool = false,
    steering_applied: bool = false,
    brake_applied: bool = false,
    steering_observed: bool = false,
    vehicle_moved: bool = false,
    crate_displaced: bool = false,
    exited: bool = false,
    vehicle_position_before_drive: ?[3]f32 = null,
    crate_position_before_drive: ?[3]f32 = null,
};

const WindowLifecycleSummary = struct {
    warmup_ready_frames: u64 = 0,
    restored_ready_frames: u64 = 0,
    unavailable_frames: u64 = 0,
    minimized_wait_iterations: u64 = 0,
    minimized_dwell_ns: u64 = 0,
};

const S3SmokeStage = enum {
    cancel_first_load,
    wait_cancel_drain,
    load_to_resident,
    wait_unload_drain,
};

const S3StreamingSmokeSummary = struct {
    attempted_frames: u64 = 0,
    ticks: u64 = 0,
    zero_tick_frames: u64 = 0,
    multi_tick_frames: u64 = 0,
    cancelled_loads: u8 = 0,
    resident_cycles: u8 = 0,
    unload_cycles: u8 = 0,
    cancel_to_drained_frames: u64 = 0,
    peak_load_to_resident_frames: u64 = 0,
    peak_unload_to_drained_frames: u64 = 0,
    fallback_frames: u64 = 0,
    resident_frames: u64 = 0,
    peak_live_scenes: u8 = 0,
    peak_active_batches: u8 = 0,
    peak_staged_cpu_bytes: u64 = 0,
    peak_staged_upload_bytes: u64 = 0,
    peak_in_flight_upload_bytes: u64 = 0,
    peak_resident_gpu_bytes: u64 = 0,
    diagnostic_correlations: u8 = 0,
    diagnostic_entries: u16 = 0,
    diagnostic_resident_snapshot: bool = false,
    diagnostic_drained_snapshot: bool = false,
};

const s6_required_overlap_cycles: u8 = 3;
const s6_west_only = [2]f32{ 0, 0 };
const s6_overlap = [2]f32{ 8, 0 };
const s6_east_only = [2]f32{ 24, 0 };
const s6_fully_outside = [2]f32{ 40, 32 };

const S6SmokeStage = enum {
    west_resident,
    forward_overlap,
    east_resident,
    reverse_overlap,
    west_cycle_resident,
    final_drain,
};

const S6StreamingSmokeSummary = struct {
    attempted_frames: u64 = 0,
    ticks: u64 = 0,
    zero_tick_frames: u64 = 0,
    multi_tick_frames: u64 = 0,
    overlap_cycles: u8 = 0,
    forward_overlaps: u8 = 0,
    reverse_overlaps: u8 = 0,
    peak_live_scenes: u8 = 0,
    peak_resident_scenes: u8 = 0,
    peak_active_batches: u8 = 0,
    peak_staged_cpu_bytes: u64 = 0,
    peak_staged_upload_bytes: u64 = 0,
    peak_in_flight_upload_bytes: u64 = 0,
    peak_resident_gpu_bytes: u64 = 0,

    fn observe(self: *S6StreamingSmokeSummary, stats: district_gpu_registry.Stats) void {
        self.peak_live_scenes = @max(self.peak_live_scenes, stats.live_scenes);
        self.peak_resident_scenes = @max(
            self.peak_resident_scenes,
            stats.resident_scenes,
        );
        self.peak_active_batches = @max(self.peak_active_batches, stats.active_batches);
        self.peak_staged_cpu_bytes = @max(
            self.peak_staged_cpu_bytes,
            stats.staged_cpu_bytes,
        );
        self.peak_staged_upload_bytes = @max(
            self.peak_staged_upload_bytes,
            stats.staged_upload_bytes,
        );
        self.peak_in_flight_upload_bytes = @max(
            self.peak_in_flight_upload_bytes,
            stats.in_flight_upload_bytes,
        );
        self.peak_resident_gpu_bytes = @max(
            self.peak_resident_gpu_bytes,
            stats.resident_gpu_bytes,
        );
    }
};

const S7SmokeStage = enum {
    west_resident,
    carryable_spawned,
    collected,
    crossed_east,
    dropped,
    east_unloaded,
    east_reloaded,
    carryable_despawned,
    character_despawned,
    final_drain,
};

const S7InteractionSmokeSummary = struct {
    attempted_frames: u64 = 0,
    ticks: u64 = 0,
    zero_tick_frames: u64 = 0,
    multi_tick_frames: u64 = 0,
    carryable_draw_frames: u64 = 0,
    held_draw_frames: u64 = 0,
    district_draw_frames: u64 = 0,
    collected: bool = false,
    crossed_east: bool = false,
    dropped_east: bool = false,
    source_unloaded_while_held: bool = false,
    dormant_after_unload: bool = false,
    resumed_after_reload: bool = false,
    final_entities: u32 = 0,
    final_bodies: u32 = 0,
};

const s8_population_count: usize = population.max_population_commands;
const s8_spawn_first_request_id: u64 = 8_000;
const s8_despawn_first_request_id: u64 = 9_000;
const s8_west_seam = sandbox_host.NavigationNodeRef{
    .coord = district_west_coord,
    .index = 2,
};
const s8_east_end = sandbox_host.NavigationNodeRef{
    .coord = district_east_coord,
    .index = 2,
};

comptime {
    if (s8_population_count != sandbox_host.npc_capacity) {
        @compileError("the S8 population proof must exercise the complete NPC budget");
    }
}

const S8SmokeStage = enum {
    overlap_resident,
    population_spawned,
    destination_waiting,
    destination_reloaded,
    crossed_east,
    owner_dormant,
    owner_resumed,
    population_despawned,
    final_drain,
};

const S8PopulationSmokeSummary = struct {
    attempted_frames: u64 = 0,
    ticks: u64 = 0,
    zero_tick_frames: u64 = 0,
    multi_tick_frames: u64 = 0,
    planned: u8 = 0,
    spawned: u8 = 0,
    despawned: u8 = 0,
    npc_draw_frames: u64 = 0,
    peak_npc_draws: u8 = 0,
    peak_active: u32 = 0,
    peak_waiting: u32 = 0,
    peak_dormant: u32 = 0,
    peak_native_controllers: u32 = 0,
    waiting_events: u16 = 0,
    waiting_resume_events: u16 = 0,
    transfer_events: u16 = 0,
    dormant_events: u16 = 0,
    controller_resume_events: u16 = 0,
    goal_events: u16 = 0,
    two_resident_scenes: bool = false,
    peak_live_scenes: u8 = 0,
    peak_resident_scenes: u8 = 0,
    peak_active_batches: u8 = 0,
    peak_staged_cpu_bytes: u64 = 0,
    peak_staged_upload_bytes: u64 = 0,
    peak_in_flight_upload_bytes: u64 = 0,
    peak_resident_gpu_bytes: u64 = 0,
    final_entities: u32 = 0,
    final_bodies: u32 = 0,
    final_native_controllers: u32 = 0,
    final_draws: u8 = 0,

    fn observeGpu(self: *S8PopulationSmokeSummary, stats: district_gpu_registry.Stats) void {
        self.peak_live_scenes = @max(self.peak_live_scenes, stats.live_scenes);
        self.peak_resident_scenes = @max(
            self.peak_resident_scenes,
            stats.resident_scenes,
        );
        self.peak_active_batches = @max(self.peak_active_batches, stats.active_batches);
        self.peak_staged_cpu_bytes = @max(
            self.peak_staged_cpu_bytes,
            stats.staged_cpu_bytes,
        );
        self.peak_staged_upload_bytes = @max(
            self.peak_staged_upload_bytes,
            stats.staged_upload_bytes,
        );
        self.peak_in_flight_upload_bytes = @max(
            self.peak_in_flight_upload_bytes,
            stats.in_flight_upload_bytes,
        );
        self.peak_resident_gpu_bytes = @max(
            self.peak_resident_gpu_bytes,
            stats.resident_gpu_bytes,
        );
    }

    fn observeNpc(
        self: *S8PopulationSmokeSummary,
        diagnostics: NpcDiagnostics,
        controllers: CharacterControllerDiagnostics,
    ) !void {
        // This isolated smoke owns no player CharacterVirtual. Require the
        // direct Physics-registry count, the independently summed feature
        // count, and NPC feature ownership to agree on every rendered frame.
        // That makes a leaked, duplicated, or untracked native controller a
        // native closeout failure instead of an invisible feature-only count.
        if (controllers.native_capacity != 128 or
            controllers.native_used != controllers.feature_owned or
            controllers.feature_owned != diagnostics.controller_count or
            !controllers.authority_consistent)
        {
            return error.S8PopulationNativeControllerMismatch;
        }
        self.peak_active = @max(self.peak_active, diagnostics.active_count);
        self.peak_waiting = @max(self.peak_waiting, diagnostics.waiting_count);
        self.peak_dormant = @max(self.peak_dormant, diagnostics.dormant_count);
        self.peak_native_controllers = @max(
            self.peak_native_controllers,
            controllers.native_used,
        );
    }

    fn validate(
        self: S8PopulationSmokeSummary,
        config: VisualSmokeConfig,
        diagnostics: NpcDiagnostics,
        controllers: CharacterControllerDiagnostics,
    ) !void {
        if (self.attempted_frames == 0 or self.ticks == 0 or
            self.planned != s8_population_count or
            self.spawned != s8_population_count or
            self.despawned != s8_population_count or
            self.npc_draw_frames == 0 or
            self.peak_npc_draws != s8_population_count or
            self.peak_active != s8_population_count or
            self.peak_waiting != s8_population_count or
            self.peak_dormant != s8_population_count or
            self.peak_native_controllers != s8_population_count or
            self.waiting_events != s8_population_count or
            self.waiting_resume_events != s8_population_count or
            self.transfer_events != s8_population_count or
            self.dormant_events != s8_population_count or
            self.controller_resume_events != s8_population_count or
            self.goal_events != 0 or !self.two_resident_scenes or
            self.peak_live_scenes != 2 or self.peak_resident_scenes != 2 or
            self.peak_active_batches == 0 or self.peak_active_batches > 2 or
            self.peak_staged_cpu_bytes != 344 or
            self.peak_staged_upload_bytes != 116 or
            self.peak_in_flight_upload_bytes == 0 or
            self.peak_in_flight_upload_bytes > 232 or
            self.peak_in_flight_upload_bytes % 116 != 0 or
            self.peak_resident_gpu_bytes != 232 or
            diagnostics.transfers != s8_population_count or
            diagnostics.controllers_suspended != s8_population_count or
            diagnostics.controllers_resumed != s8_population_count or
            diagnostics.commands.high_water != s8_population_count or
            diagnostics.outcomes.high_water != s8_population_count or
            diagnostics.events.high_water != s8_population_count or
            diagnostics.commands.occupancy != 0 or
            diagnostics.outcomes.occupancy != 0 or
            diagnostics.events.occupancy != 0 or
            diagnostics.commands.rejected != 0 or
            diagnostics.event_drops.total() != 0 or
            self.final_entities != 0 or self.final_bodies != 1 or
            controllers.native_capacity != 128 or
            controllers.native_used != 0 or controllers.feature_owned != 0 or
            !controllers.authority_consistent or
            self.final_native_controllers != 0 or self.final_draws != 0 or
            (config.virtual_render_hz > timing.TICK_RATE and
                (self.zero_tick_frames == 0 or self.multi_tick_frames != 0)) or
            (config.virtual_render_hz < timing.TICK_RATE and
                (self.multi_tick_frames == 0 or self.zero_tick_frames != 0)))
        {
            return error.S8PopulationSmokeEvidenceMissing;
        }
    }
};

fn s8RequestIndex(request_id: u64, first_request_id: u64) !usize {
    if (request_id < first_request_id) return error.UnexpectedS8NpcOutcome;
    const offset = request_id - first_request_id;
    if (offset >= s8_population_count) return error.UnexpectedS8NpcOutcome;
    return @intCast(offset);
}

/// Fixed, allocation-free proof that each request slot and persistent NPC
/// contributes exactly one expected lifecycle transition. Aggregate counters
/// remain useful report values, while these per-identity sets prevent one NPC's
/// duplicate output from masking another NPC's missing output.
const S8PopulationEvidence = struct {
    identities: [s8_population_count]?sandbox_host.PersistentId = @splat(null),
    spawned: [s8_population_count]bool = @splat(false),
    waiting: [s8_population_count]bool = @splat(false),
    waiting_resumed: [s8_population_count]bool = @splat(false),
    transferred: [s8_population_count]bool = @splat(false),
    dormant: [s8_population_count]bool = @splat(false),
    controller_resumed: [s8_population_count]bool = @splat(false),
    despawned: [s8_population_count]bool = @splat(false),

    fn allSeen(values: *const [s8_population_count]bool) bool {
        for (values) |seen| if (!seen) return false;
        return true;
    }

    fn spawnedComplete(self: *const S8PopulationEvidence) bool {
        return allSeen(&self.spawned);
    }

    fn waitingComplete(self: *const S8PopulationEvidence) bool {
        return allSeen(&self.waiting);
    }

    fn waitingResumeComplete(self: *const S8PopulationEvidence) bool {
        return allSeen(&self.waiting_resumed);
    }

    fn transferComplete(self: *const S8PopulationEvidence) bool {
        return allSeen(&self.transferred);
    }

    fn dormantComplete(self: *const S8PopulationEvidence) bool {
        return allSeen(&self.dormant);
    }

    fn controllerResumeComplete(self: *const S8PopulationEvidence) bool {
        return allSeen(&self.controller_resumed);
    }

    fn despawnedComplete(self: *const S8PopulationEvidence) bool {
        return allSeen(&self.despawned);
    }

    fn complete(self: *const S8PopulationEvidence) bool {
        if (!self.spawnedComplete() or
            !self.waitingComplete() or
            !self.waitingResumeComplete() or
            !self.transferComplete() or
            !self.dormantComplete() or
            !self.controllerResumeComplete() or
            !self.despawnedComplete())
        {
            return false;
        }
        for (self.identities) |identity| if (identity == null) return false;
        return true;
    }

    fn requireComplete(self: *const S8PopulationEvidence) !void {
        if (!self.complete()) return error.S8PopulationSmokeEvidenceMissing;
    }

    fn indexForIdentity(
        self: *const S8PopulationEvidence,
        id: sandbox_host.PersistentId,
    ) ?usize {
        for (self.identities, 0..) |candidate, index| {
            if (candidate != null and std.meta.eql(candidate.?, id)) return index;
        }
        return null;
    }

    fn observeOutcome(
        self: *S8PopulationEvidence,
        stage: S8SmokeStage,
        summary: *S8PopulationSmokeSummary,
        outcome: sandbox_host.NpcOutcome,
    ) !void {
        switch (outcome) {
            .spawned => |value| {
                if (stage != .population_spawned) return error.UnexpectedS8NpcOutcome;
                const index = try s8RequestIndex(value.request_id, s8_spawn_first_request_id);
                if (self.spawned[index] or self.identities[index] != null or
                    self.indexForIdentity(value.id) != null or
                    !std.meta.eql(value.owner, district_west_coord))
                {
                    return error.UnexpectedS8NpcOutcome;
                }
                self.identities[index] = value.id;
                self.spawned[index] = true;
                summary.spawned += 1;
            },
            .despawned => |value| {
                if (stage != .population_despawned) return error.UnexpectedS8NpcOutcome;
                const index = try s8RequestIndex(value.request_id, s8_despawn_first_request_id);
                if (!self.spawned[index] or self.despawned[index] or
                    !std.meta.eql(self.identities[index] orelse
                        return error.UnexpectedS8NpcOutcome, value.id))
                {
                    return error.UnexpectedS8NpcOutcome;
                }
                self.despawned[index] = true;
                summary.despawned += 1;
            },
            .goal_set, .rejected => return error.UnexpectedS8NpcOutcome,
        }
    }

    fn recordEvent(
        stage: S8SmokeStage,
        expected_stage: S8SmokeStage,
        seen: *[s8_population_count]bool,
        index: usize,
        count: *u16,
    ) !void {
        if (stage != expected_stage or seen[index]) return error.UnexpectedS8NpcEvent;
        seen[index] = true;
        count.* += 1;
    }

    fn observeEvent(
        self: *S8PopulationEvidence,
        stage: S8SmokeStage,
        summary: *S8PopulationSmokeSummary,
        event: sandbox_host.NpcEvent,
    ) !void {
        switch (event) {
            .state_changed => |changed| {
                const index = self.indexForIdentity(changed.id) orelse
                    return error.UnexpectedS8NpcEvent;
                if (changed.previous == .active and
                    changed.current == .waiting_at_boundary)
                {
                    try recordEvent(
                        stage,
                        .destination_waiting,
                        &self.waiting,
                        index,
                        &summary.waiting_events,
                    );
                } else if (changed.previous == .waiting_at_boundary and
                    changed.current == .active)
                {
                    try recordEvent(
                        stage,
                        .destination_reloaded,
                        &self.waiting_resumed,
                        index,
                        &summary.waiting_resume_events,
                    );
                } else if (changed.previous == .active and
                    changed.current == .dormant)
                {
                    try recordEvent(
                        stage,
                        .owner_dormant,
                        &self.dormant,
                        index,
                        &summary.dormant_events,
                    );
                } else if (changed.previous == .dormant and
                    changed.current == .active)
                {
                    try recordEvent(
                        stage,
                        .owner_resumed,
                        &self.controller_resumed,
                        index,
                        &summary.controller_resume_events,
                    );
                } else {
                    return error.UnexpectedS8NpcEvent;
                }
            },
            .owner_transferred => |transferred| {
                const index = self.indexForIdentity(transferred.id) orelse
                    return error.UnexpectedS8NpcEvent;
                if (!std.meta.eql(transferred.previous, district_west_coord) or
                    !std.meta.eql(transferred.current, district_east_coord))
                {
                    return error.UnexpectedS8NpcEvent;
                }
                try recordEvent(
                    stage,
                    .crossed_east,
                    &self.transferred,
                    index,
                    &summary.transfer_events,
                );
            },
            .goal_reached => |reached| {
                _ = self.indexForIdentity(reached.id) orelse
                    return error.UnexpectedS8NpcEvent;
                // This smoke unloads the east owner immediately after transfer,
                // before the east terminal can be reached. Any goal event is an
                // unexpected lifecycle class, not evidence to aggregate later.
                return error.UnexpectedS8NpcEvent;
            },
        }
    }
};

const DistrictStreamEvidence = struct {
    correlation: u64 = 0,
    gpu_reserved: ?u64 = null,
    content_requested: ?u64 = null,
    content_ready: ?u64 = null,
    logical_submitted: ?u64 = null,
    gpu_staged: ?u64 = null,
    gpu_submitted: ?u64 = null,
    gpu_resident: ?u64 = null,
    logical_admitted: ?u64 = null,
    logical_cancel_submitted: ?u64 = null,
    logical_cancelled: ?u64 = null,
    logical_activated: ?u64 = null,
    logical_unload_submitted: ?u64 = null,
    logical_unloaded: ?u64 = null,
    gpu_release_requested: ?u64 = null,
    gpu_drained: ?u64 = null,
};

const S4DiagnosticsSmokeSummary = struct {
    paused_frames: u64,
    paused_seconds: f64,
    tick_before_pause: u64,
    tick_after_step: u64,
    failed_tick_counted: bool,
    frozen_rejections: u64,
    fault_journal_entries: usize,
    inspection_ready_frames: u64,
    json_bytes: usize,
    fault: engine.runtime.RuntimeFault,
};

const S4PhysicsDebugEvidence = struct {
    category_observed: [engine.physics_debug.category_count]bool =
        [_]bool{false} ** engine.physics_debug.category_count,
    peak_lines: u32 = 0,
    peak_triangles: u32 = 0,
    dropped_primitives: u64 = 0,
    batches: u64 = 0,

    fn observe(self: *S4PhysicsDebugEvidence, batch: engine.physics_debug.Batch) void {
        self.batches +|= 1;
        self.peak_lines = @max(self.peak_lines, std.math.cast(u32, batch.lines.len) orelse
            std.math.maxInt(u32));
        self.peak_triangles = @max(
            self.peak_triangles,
            std.math.cast(u32, batch.triangles.len) orelse std.math.maxInt(u32),
        );
        for (std.meta.tags(engine.physics_debug.Category)) |category| {
            const stats = batch.statsFor(category);
            self.category_observed[@intFromEnum(category)] =
                self.category_observed[@intFromEnum(category)] or
                stats.lines.admitted != 0 or
                stats.triangles.admitted != 0;
            self.dropped_primitives +|= stats.lines.dropped;
            self.dropped_primitives +|= stats.triangles.dropped;
        }
    }

    fn allCategoriesObserved(self: S4PhysicsDebugEvidence) bool {
        for (self.category_observed) |observed| {
            if (!observed) return false;
        }
        return true;
    }
};

const S5AuthoringSmokeSummary = struct {
    rendered_frames: u8 = 0,
    hidden_frames: u8 = 0,
    edit_revision: u64 = 0,
    undo_revision: u64 = 0,
    redo_revision: u64 = 0,
    save_status: editor_contract.SaveFeedbackStatus = .unavailable,
    save_sequence: u64 = 0,
};

/// Installed-smoke-only observation seam for the production fault-retention
/// branch. It never changes simulation behavior; it supplies a deterministic
/// frame delta, counts the normal content/GPU pump call sites, and requests a
/// real SDL quit only after a retained-fault Metal frame succeeds.
const S4FaultLoopProbe = struct {
    expected_error: anyerror,
    content_pump_calls: u64 = 0,
    gpu_pump_calls: u64 = 0,
    content_pump_calls_at_fault: u64 = 0,
    gpu_pump_calls_at_fault: u64 = 0,
    tick_at_fault: u64 = 0,
    completed_ticks_at_fault: u64 = 0,
    stream_at_fault: ?developer_diagnostics.DistrictStreams = null,
    gpu_at_fault: ?developer_diagnostics.GpuUsage = null,
    retained_ready_frames: u64 = 0,
    quit_injected: bool = false,
};

const s3_smoke_resident_cycles: u8 = 3;
const s3_smoke_near = [2]f32{ 0, 0 };
const s3_smoke_far = [2]f32{ 32, 32 };
const s4_smoke_pause_frames: u64 = 600;
const s4_smoke_pause_frame_seconds: f64 = 1.0 / 30.0;
const s4_smoke_stream_attempt_limit: u32 = 480;

fn districtRecycleComplete(
    registry: anytype,
    scene: engine.rendering.SceneHandle,
) !bool {
    return registry.recycleComplete(scene);
}

fn updateS3SmokePeaks(
    summary: *S3StreamingSmokeSummary,
    stats: district_gpu_registry.Stats,
) void {
    summary.peak_live_scenes = @max(summary.peak_live_scenes, stats.live_scenes);
    summary.peak_active_batches = @max(
        summary.peak_active_batches,
        stats.active_batches,
    );
    summary.peak_staged_cpu_bytes = @max(
        summary.peak_staged_cpu_bytes,
        stats.staged_cpu_bytes,
    );
    summary.peak_staged_upload_bytes = @max(
        summary.peak_staged_upload_bytes,
        stats.staged_upload_bytes,
    );
    summary.peak_in_flight_upload_bytes = @max(
        summary.peak_in_flight_upload_bytes,
        stats.in_flight_upload_bytes,
    );
    summary.peak_resident_gpu_bytes = @max(
        summary.peak_resident_gpu_bytes,
        stats.resident_gpu_bytes,
    );
}

fn setDistrictEvidenceSequence(field: *?u64, sequence: u64) !void {
    if (field.* != null) return error.DuplicateDistrictDiagnosticTransition;
    field.* = sequence;
}

fn requireDistrictEvidenceOrder(values: []const ?u64) !void {
    var prior: u64 = 0;
    for (values) |optional| {
        const value = optional orelse return error.MissingDistrictDiagnosticTransition;
        if (value <= prior) return error.InvalidDistrictDiagnosticOrder;
        prior = value;
    }
}

fn validateDistrictStreamDiagnostics(
    journal: *const engine.runtime.DiagnosticJournal,
) !struct { correlations: u8, entries: u16 } {
    var records: [8]DistrictStreamEvidence = @splat(.{});
    var record_count: u8 = 0;
    const entries = journal.borrowedChronological();

    for (0..entries.len()) |index| {
        const entry = entries.at(index).?.*;
        const is_stream_transition = switch (entry.code) {
            engine.diagnostic_contracts.codes.district_stream_content_requested,
            engine.diagnostic_contracts.codes.district_stream_content_ready,
            engine.diagnostic_contracts.codes.district_stream_logical_submitted,
            engine.diagnostic_contracts.codes.district_stream_logical_cancel_submitted,
            engine.diagnostic_contracts.codes.district_stream_logical_unload_submitted,
            engine.diagnostic_contracts.codes.district_stream_logical_admitted,
            engine.diagnostic_contracts.codes.district_stream_logical_activated,
            engine.diagnostic_contracts.codes.district_stream_logical_cancelled,
            engine.diagnostic_contracts.codes.district_stream_logical_unloaded,
            engine.diagnostic_contracts.codes.district_stream_gpu_reserved,
            engine.diagnostic_contracts.codes.district_stream_gpu_staged,
            engine.diagnostic_contracts.codes.district_stream_gpu_submitted,
            engine.diagnostic_contracts.codes.district_stream_gpu_resident,
            engine.diagnostic_contracts.codes.district_stream_gpu_release_requested,
            engine.diagnostic_contracts.codes.district_stream_gpu_drained,
            => true,
            else => false,
        };
        if (!is_stream_transition) continue;
        if (entry.correlation_id == 0) return error.InvalidDistrictDiagnosticCorrelation;

        var record: *DistrictStreamEvidence = blk: {
            for (records[0..record_count]) |*candidate| {
                if (candidate.correlation == entry.correlation_id) break :blk candidate;
            }
            if (record_count == records.len) return error.TooManyDistrictDiagnosticCorrelations;
            const created = &records[record_count];
            record_count += 1;
            created.correlation = entry.correlation_id;
            break :blk created;
        };
        const sequence = entry.sequence;
        switch (entry.code) {
            engine.diagnostic_contracts.codes.district_stream_content_requested => try setDistrictEvidenceSequence(&record.content_requested, sequence),
            engine.diagnostic_contracts.codes.district_stream_content_ready => try setDistrictEvidenceSequence(&record.content_ready, sequence),
            engine.diagnostic_contracts.codes.district_stream_logical_submitted => try setDistrictEvidenceSequence(&record.logical_submitted, sequence),
            engine.diagnostic_contracts.codes.district_stream_logical_cancel_submitted => try setDistrictEvidenceSequence(&record.logical_cancel_submitted, sequence),
            engine.diagnostic_contracts.codes.district_stream_logical_unload_submitted => try setDistrictEvidenceSequence(&record.logical_unload_submitted, sequence),
            engine.diagnostic_contracts.codes.district_stream_logical_admitted => try setDistrictEvidenceSequence(&record.logical_admitted, sequence),
            engine.diagnostic_contracts.codes.district_stream_logical_activated => try setDistrictEvidenceSequence(&record.logical_activated, sequence),
            engine.diagnostic_contracts.codes.district_stream_logical_cancelled => try setDistrictEvidenceSequence(&record.logical_cancelled, sequence),
            engine.diagnostic_contracts.codes.district_stream_logical_unloaded => try setDistrictEvidenceSequence(&record.logical_unloaded, sequence),
            engine.diagnostic_contracts.codes.district_stream_gpu_reserved => try setDistrictEvidenceSequence(&record.gpu_reserved, sequence),
            engine.diagnostic_contracts.codes.district_stream_gpu_staged => try setDistrictEvidenceSequence(&record.gpu_staged, sequence),
            engine.diagnostic_contracts.codes.district_stream_gpu_submitted => try setDistrictEvidenceSequence(&record.gpu_submitted, sequence),
            engine.diagnostic_contracts.codes.district_stream_gpu_resident => try setDistrictEvidenceSequence(&record.gpu_resident, sequence),
            engine.diagnostic_contracts.codes.district_stream_gpu_release_requested => try setDistrictEvidenceSequence(&record.gpu_release_requested, sequence),
            engine.diagnostic_contracts.codes.district_stream_gpu_drained => try setDistrictEvidenceSequence(&record.gpu_drained, sequence),
            else => unreachable,
        }
    }

    if (record_count != 1 + s3_smoke_resident_cycles) {
        return error.MissingDistrictDiagnosticCorrelation;
    }
    var cancelled_count: u8 = 0;
    var active_count: u8 = 0;
    for (records[0..record_count]) |record| {
        try requireDistrictEvidenceOrder(&.{
            record.gpu_reserved,
            record.content_requested,
            record.content_ready,
            record.logical_submitted,
        });
        try requireDistrictEvidenceOrder(&.{
            record.logical_submitted,
            record.gpu_staged,
        });
        try requireDistrictEvidenceOrder(&.{
            record.logical_submitted,
            record.logical_admitted,
        });
        if (record.logical_cancelled != null) {
            cancelled_count += 1;
            try requireDistrictEvidenceOrder(&.{
                record.logical_admitted,
                record.logical_cancel_submitted,
                record.logical_cancelled,
                record.gpu_release_requested,
                record.gpu_drained,
            });
            if (record.gpu_submitted) |submitted| {
                const staged = record.gpu_staged orelse
                    return error.MissingDistrictDiagnosticTransition;
                const released = record.gpu_release_requested orelse
                    return error.MissingDistrictDiagnosticTransition;
                if (staged >= submitted or submitted >= released) {
                    return error.InvalidDistrictDiagnosticOrder;
                }
            }
            if (record.gpu_resident) |resident| {
                const submitted = record.gpu_submitted orelse
                    return error.MissingDistrictDiagnosticTransition;
                const released = record.gpu_release_requested orelse
                    return error.MissingDistrictDiagnosticTransition;
                if (submitted >= resident or resident >= released) {
                    return error.InvalidDistrictDiagnosticOrder;
                }
            }
            if (record.logical_activated != null or record.logical_unloaded != null) {
                return error.InvalidDistrictDiagnosticBranch;
            }
        } else {
            active_count += 1;
            try requireDistrictEvidenceOrder(&.{
                record.logical_admitted,
                record.logical_activated,
                record.logical_unload_submitted,
                record.logical_unloaded,
                record.gpu_release_requested,
                record.gpu_drained,
            });
            try requireDistrictEvidenceOrder(&.{
                record.gpu_submitted,
                record.gpu_resident,
                record.logical_unload_submitted,
            });
        }
    }
    if (cancelled_count != 1 or active_count != s3_smoke_resident_cycles) {
        return error.InvalidDistrictDiagnosticBranchCount;
    }
    return .{
        .correlations = record_count,
        .entries = @intCast(entries.len()),
    };
}

const AppInitFailurePoint = enum {
    renderer_after_window_claim,
    renderer_after_pipelines,
    renderer_after_placeholder_resources,
    after_renderer,
    after_visual_resources,
    after_simulation,
};

fn rendererFailurePoint(
    comptime point: ?AppInitFailurePoint,
) ?renderer.InitFailurePoint {
    return switch (point orelse return null) {
        .renderer_after_window_claim => .after_window_claim,
        .renderer_after_pipelines => .after_pipelines,
        .renderer_after_placeholder_resources => .after_placeholder_resources,
        .after_renderer, .after_visual_resources, .after_simulation => null,
    };
}

fn injectAppInitFailure(
    configured: ?AppInitFailurePoint,
    reached: AppInitFailurePoint,
) !void {
    if (configured == reached) return error.InjectedAppInitFailure;
}

fn suspendGameplayForWindowState(
    input_buffer: *const input.InputBuffer,
    action_latch: *sandbox_controls.ActionLatch,
) bool {
    if (!input_buffer.window_minimized) return false;
    // A focus-loss reset can arrive while the render/simulation loop is
    // suspended. Clear unconsumed frame edges and deltas here so they cannot
    // replay when the window is restored.
    action_latch.clear();
    return true;
}

const SmokeExpectation = struct {
    ticks: u64,
    min_alpha: f32,
    max_alpha: f32,
};

fn smokeExpectation(config: VisualSmokeConfig) !SmokeExpectation {
    var accumulator = timing.FixedStepAccumulator.init();
    var result = SmokeExpectation{ .ticks = 0, .min_alpha = 1, .max_alpha = 0 };
    for (0..config.frames) |_| {
        _ = try accumulator.addElapsedSeconds(
            1.0 / @as(f64, @floatFromInt(config.virtual_render_hz)),
        );
        while (accumulator.consumeTick()) result.ticks += 1;
        const alpha = accumulator.alpha();
        result.min_alpha = @min(result.min_alpha, alpha);
        result.max_alpha = @max(result.max_alpha, alpha);
    }
    return result;
}

fn vectorChanged(comptime count: usize, first: [count]f32, current: [count]f32) bool {
    for (first, current) |a, b| {
        if (@abs(a - b) > 0.00001) return true;
    }
    return false;
}

fn distanceSquared(first: [3]f32, current: [3]f32) f32 {
    var result: f32 = 0;
    for (first, current) |a, b| {
        const delta = b - a;
        result += delta * delta;
    }
    return result;
}

fn parseProgramMode(args: anytype) !ProgramMode {
    var verify_install = false;
    var visual_smoke = false;
    var s1_visual_smoke = false;
    var s2_visual_smoke = false;
    var s3_streaming_smoke = false;
    var s6_streaming_smoke = false;
    var s7_interaction_smoke = false;
    var s8_population_smoke = false;
    var s4_diagnostics_smoke = false;
    var s4_physics_debug_smoke = false;
    var s5_authoring_smoke = false;
    var window_lifecycle_smoke = false;
    var init_failure_smoke = false;
    var frames: ?u64 = null;
    var virtual_render_hz: ?u32 = null;
    var content_root_seen = false;
    var save_root_seen = false;

    for (args[1..args.len]) |raw_arg| {
        const arg: []const u8 = raw_arg;
        if (std.mem.eql(u8, arg, "--verify-install")) {
            if (verify_install) return error.DuplicateArgument;
            verify_install = true;
        } else if (std.mem.eql(u8, arg, "--visual-smoke")) {
            if (visual_smoke) return error.DuplicateArgument;
            visual_smoke = true;
        } else if (std.mem.eql(u8, arg, "--s1-visual-smoke")) {
            if (s1_visual_smoke) return error.DuplicateArgument;
            s1_visual_smoke = true;
        } else if (std.mem.eql(u8, arg, "--s2-visual-smoke")) {
            if (s2_visual_smoke) return error.DuplicateArgument;
            s2_visual_smoke = true;
        } else if (std.mem.eql(u8, arg, "--s3-streaming-smoke")) {
            if (s3_streaming_smoke) return error.DuplicateArgument;
            s3_streaming_smoke = true;
        } else if (std.mem.eql(u8, arg, "--s6-streaming-smoke")) {
            if (s6_streaming_smoke) return error.DuplicateArgument;
            s6_streaming_smoke = true;
        } else if (std.mem.eql(u8, arg, "--s7-interaction-smoke")) {
            if (s7_interaction_smoke) return error.DuplicateArgument;
            s7_interaction_smoke = true;
        } else if (std.mem.eql(u8, arg, "--s8-population-smoke")) {
            if (s8_population_smoke) return error.DuplicateArgument;
            s8_population_smoke = true;
        } else if (std.mem.eql(u8, arg, "--s4-diagnostics-smoke")) {
            if (s4_diagnostics_smoke) return error.DuplicateArgument;
            s4_diagnostics_smoke = true;
        } else if (std.mem.eql(u8, arg, "--s4-physics-debug-smoke")) {
            if (s4_physics_debug_smoke) return error.DuplicateArgument;
            s4_physics_debug_smoke = true;
        } else if (std.mem.eql(u8, arg, "--s5-authoring-smoke")) {
            if (s5_authoring_smoke) return error.DuplicateArgument;
            s5_authoring_smoke = true;
        } else if (std.mem.eql(u8, arg, "--window-lifecycle-smoke")) {
            if (window_lifecycle_smoke) return error.DuplicateArgument;
            window_lifecycle_smoke = true;
        } else if (std.mem.eql(u8, arg, "--init-failure-smoke")) {
            if (init_failure_smoke) return error.DuplicateArgument;
            init_failure_smoke = true;
        } else if (std.mem.startsWith(u8, arg, "--frames=")) {
            if (frames != null) return error.DuplicateArgument;
            const value = arg["--frames=".len..];
            frames = std.fmt.parseUnsigned(u64, value, 10) catch
                return error.InvalidFrameCount;
            if (frames.? == 0) return error.InvalidFrameCount;
        } else if (std.mem.startsWith(u8, arg, "--virtual-render-hz=")) {
            if (virtual_render_hz != null) return error.DuplicateArgument;
            const value = arg["--virtual-render-hz=".len..];
            virtual_render_hz = std.fmt.parseUnsigned(u32, value, 10) catch
                return error.InvalidVirtualRenderRate;
            if (virtual_render_hz.? == 0 or virtual_render_hz.? > 10_000) {
                return error.InvalidVirtualRenderRate;
            }
        } else if (std.mem.startsWith(u8, arg, "--content-root=")) {
            if (content_root_seen) return error.DuplicateArgument;
            _ = try content.ContentRootPath.parse(arg["--content-root=".len..]);
            content_root_seen = true;
        } else if (std.mem.startsWith(u8, arg, "--save-root=")) {
            if (save_root_seen) return error.DuplicateArgument;
            _ = try save_slots.RootPath.parse(arg["--save-root=".len..]);
            save_root_seen = true;
        } else {
            return error.UnknownArgument;
        }
    }

    if (verify_install) {
        if (visual_smoke or s1_visual_smoke or s2_visual_smoke or
            s3_streaming_smoke or s6_streaming_smoke or s7_interaction_smoke or
            s8_population_smoke or
            window_lifecycle_smoke or init_failure_smoke or
            s4_diagnostics_smoke or s4_physics_debug_smoke or
            s5_authoring_smoke or save_root_seen or
            frames != null or virtual_render_hz != null)
        {
            return error.ConflictingProgramModes;
        }
        return .verify_install;
    }
    const explicit_mode_count = @as(u8, @intFromBool(visual_smoke)) +
        @as(u8, @intFromBool(s1_visual_smoke)) +
        @as(u8, @intFromBool(s2_visual_smoke)) +
        @as(u8, @intFromBool(s3_streaming_smoke)) +
        @as(u8, @intFromBool(s6_streaming_smoke)) +
        @as(u8, @intFromBool(s7_interaction_smoke)) +
        @as(u8, @intFromBool(s8_population_smoke)) +
        @as(u8, @intFromBool(s4_diagnostics_smoke)) +
        @as(u8, @intFromBool(s4_physics_debug_smoke)) +
        @as(u8, @intFromBool(s5_authoring_smoke)) +
        @as(u8, @intFromBool(window_lifecycle_smoke)) +
        @as(u8, @intFromBool(init_failure_smoke));
    if (explicit_mode_count > 1) return error.ConflictingProgramModes;
    if (content_root_seen and explicit_mode_count != 0) return error.ConflictingProgramModes;
    if (save_root_seen and explicit_mode_count != 0 and !s5_authoring_smoke) {
        return error.ConflictingProgramModes;
    }
    if (!visual_smoke and !s1_visual_smoke and !s2_visual_smoke and
        !s3_streaming_smoke and !s6_streaming_smoke and !s7_interaction_smoke and
        !s8_population_smoke and
        !s4_physics_debug_smoke and
        (frames != null or virtual_render_hz != null))
    {
        return error.VisualSmokeOptionWithoutMode;
    }
    if (window_lifecycle_smoke) return .window_lifecycle_smoke;
    if (init_failure_smoke) return .init_failure_smoke;
    if (s4_diagnostics_smoke) return .s4_diagnostics_smoke;
    if (s5_authoring_smoke) {
        if (!save_root_seen) return error.SaveRootRequired;
        if (frames != null or virtual_render_hz != null) {
            return error.VisualSmokeOptionWithoutMode;
        }
        return .s5_authoring_smoke;
    }
    if (s4_physics_debug_smoke) {
        const config = VisualSmokeConfig{
            .frames = frames orelse 600,
            .virtual_render_hz = virtual_render_hz orelse 80,
        };
        const scaled = std.math.mul(u64, config.frames, 4) catch
            return error.InvalidFrameCount;
        _ = std.math.add(u64, scaled, 120) catch return error.InvalidFrameCount;
        return .{ .s4_physics_debug_smoke = config };
    }
    if (!visual_smoke and !s1_visual_smoke and !s2_visual_smoke and
        !s3_streaming_smoke and !s6_streaming_smoke and !s7_interaction_smoke and
        !s8_population_smoke)
    {
        return .normal;
    }

    const config = VisualSmokeConfig{
        .frames = frames orelse if (s2_visual_smoke)
            1_440
        else if (s8_population_smoke)
            3_600
        else if (s3_streaming_smoke or s6_streaming_smoke or s7_interaction_smoke)
            1_200
        else
            480,
        .virtual_render_hz = virtual_render_hz orelse 240,
    };
    const scaled = std.math.mul(u64, config.frames, 4) catch
        return error.InvalidFrameCount;
    _ = std.math.add(u64, scaled, 120) catch return error.InvalidFrameCount;
    return if (s8_population_smoke)
        .{ .s8_population_smoke = config }
    else if (s7_interaction_smoke)
        .{ .s7_interaction_smoke = config }
    else if (s6_streaming_smoke)
        .{ .s6_streaming_smoke = config }
    else if (s3_streaming_smoke)
        .{ .s3_streaming_smoke = config }
    else if (s2_visual_smoke)
        .{ .s2_visual_smoke = config }
    else if (s1_visual_smoke)
        .{ .s1_visual_smoke = config }
    else
        .{ .visual_smoke = config };
}

fn parseProductMode(args: anytype) !ProductMode {
    var verify_install = false;
    var content_root_seen = false;
    var save_root_seen = false;
    for (args[1..args.len]) |raw_arg| {
        const arg: []const u8 = raw_arg;
        if (std.mem.eql(u8, arg, "--verify-install")) {
            if (verify_install) return error.DuplicateArgument;
            verify_install = true;
        } else if (std.mem.startsWith(u8, arg, "--content-root=")) {
            if (content_root_seen) return error.DuplicateArgument;
            _ = try content.ContentRootPath.parse(arg["--content-root=".len..]);
            content_root_seen = true;
        } else if (std.mem.startsWith(u8, arg, "--save-root=")) {
            if (save_root_seen) return error.DuplicateArgument;
            _ = try save_slots.RootPath.parse(arg["--save-root=".len..]);
            save_root_seen = true;
        } else {
            return error.UnknownArgument;
        }
    }
    if (verify_install and save_root_seen) return error.ConflictingProgramModes;
    return if (verify_install) .verify_install else .normal;
}

fn parseContentRootOverride(args: anytype) !?content.ContentRootPath {
    var result: ?content.ContentRootPath = null;
    for (args[1..args.len]) |raw_arg| {
        const arg: []const u8 = raw_arg;
        if (!std.mem.startsWith(u8, arg, "--content-root=")) continue;
        if (result != null) return error.DuplicateArgument;
        result = try content.ContentRootPath.parse(arg["--content-root=".len..]);
    }
    return result;
}

fn parseSaveRootOverride(args: anytype) !?save_slots.RootPath {
    var result: ?save_slots.RootPath = null;
    for (args[1..args.len]) |raw_arg| {
        const arg: []const u8 = raw_arg;
        if (!std.mem.startsWith(u8, arg, "--save-root=")) continue;
        if (result != null) return error.DuplicateArgument;
        result = try save_slots.RootPath.parse(arg["--save-root=".len..]);
    }
    return result;
}

fn resolveContentRoot(
    io: std.Io,
    allocator: std.mem.Allocator,
    configured: ?content.ContentRootPath,
) !content.ContentRootPath {
    if (configured) |root| return root;
    var executable_dir_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const executable_dir_len = try std.process.executableDirPath(io, &executable_dir_buffer);
    const resolved = try std.fs.path.resolve(
        allocator,
        &.{
            executable_dir_buffer[0..executable_dir_len],
            defaultContentRootRelative(build_options.validation_mode),
        },
    );
    defer allocator.free(resolved);
    return content.ContentRootPath.parse(resolved);
}

fn defaultContentRootRelative(comptime validation_mode: bool) []const u8 {
    return if (validation_mode)
        "../../share/incinerator/content"
    else
        "../share/incinerator/content";
}

fn validateCookedLogicalDistrict(
    view: content.bundle.BundleView,
    coord: sandbox_host.ChunkCoord,
) !void {
    const expected = try sandbox_host.proceduralDistrictBuild(coord);
    if (view.static_boxes.len != expected.boxes().len) {
        return error.CookedDistrictLogicalShapeMismatch;
    }
    for (view.static_boxes, expected.boxes()) |cooked, logical| {
        if (!std.meta.eql(cooked.position, logical.pose.position) or
            !std.meta.eql(cooked.rotation, logical.pose.rotation) or
            !std.meta.eql(cooked.half_extents, logical.half_extents))
        {
            return error.CookedDistrictLogicalShapeMismatch;
        }
    }
}

fn isRetryableDistrictStageError(err: anyerror) bool {
    return err == error.DistrictStagingBudgetExceeded or
        err == error.DistrictResidentBudgetExceeded;
}

fn submitLogicalBeforeStage(
    context: anytype,
    comptime submit_logical: anytype,
    comptime stage_visual: anytype,
) !bool {
    try submit_logical(context);
    return try stage_visual(context);
}

fn takeMonotonicId(next: *u64) !u64 {
    if (next.* == 0 or next.* == std.math.maxInt(u64)) {
        return error.DistrictSequenceExhausted;
    }
    const result = next.*;
    next.* += 1;
    return result;
}

fn validateDistrictStreamCatalogEntries(entries: anytype) !void {
    if (entries.len != district_stream_slot_count) {
        return error.DistrictCatalogSlotMismatch;
    }
    var west_present = false;
    var east_present = false;
    for (entries) |entry| {
        if (entry.coord.x == district_west_coord.x and
            entry.coord.z == district_west_coord.z)
        {
            if (west_present) return error.DistrictCatalogSlotMismatch;
            west_present = true;
        } else if (entry.coord.x == district_east_coord.x and
            entry.coord.z == district_east_coord.z)
        {
            if (east_present) return error.DistrictCatalogSlotMismatch;
            east_present = true;
        } else {
            return error.DistrictCatalogSlotMismatch;
        }
    }
    if (!west_present or !east_present) return error.DistrictCatalogSlotMismatch;
}

fn verifyInstalledContent(
    io: std.Io,
    allocator: std.mem.Allocator,
    root_path: content.ContentRootPath,
) !void {
    var admitted = switch (try district_content_catalog.admit(
        io,
        allocator,
        root_path,
    )) {
        .admitted => |value| value,
        .failed => |failure| {
            std.debug.print("Installed content catalog failed admission: {any}\n", .{failure});
            return error.InstalledContentInvalid;
        },
    };
    defer admitted.deinit();
    try validateDistrictStreamCatalogEntries(admitted.view().entries);
}

// ============================================================================
// Application State
// ============================================================================

const ValidationAppState = if (build_options.validation_mode or builtin.is_test) struct {
    profile: BootstrapProfile = .sandbox,
    s4_physics_debug_evidence: S4PhysicsDebugEvidence = .{},
    s2_smoke: S2SmokeProgress = .{},
    s7_scripted_move: [2]f32 = .{ 0, 0 },
    s7_character_actions_enabled: bool = true,
    s4_fault_loop_probe: ?*S4FaultLoopProbe = null,
} else void;

const App = struct {
    io: std.Io,
    window: *c.SDL_Window,
    gpu_renderer: renderer.Renderer,
    developer_editor: editor.Editor,
    frame_timer: timing.FrameTimer,
    input_buffer: input.InputBuffer,

    simulation: sandbox_host.Session,
    initial_crate_id: ?sandbox_host.PersistentId,
    initial_character_id: ?sandbox_host.PersistentId,
    initial_vehicle_id: ?sandbox_host.PersistentId,
    initial_carryable_id: ?sandbox_host.PersistentId,
    controlled_vehicle_id: ?sandbox_host.PersistentId,
    action_latch: sandbox_controls.ActionLatch,
    authoring_transactions: *sandbox_authoring.TransactionSequencer,
    // This controller owns the visual composition's authoring request buffer.
    // External producers use the M3 transaction-to-owner router instead of
    // sharing and filtering this outcome lane.
    authoring_controller: sandbox_authoring.DefaultController,
    authoring_requests: sandbox_authoring.RequestBuffer,
    authoring_feedback: editor_contract.AuthoringFeedback,
    interaction_spawn_enabled: bool,
    interaction_spawn_submitted: bool,
    interaction_transactions: sandbox_interaction.TransactionSequencer,
    interaction_requests: sandbox_interaction.RequestBuffer,
    interaction_last_outcome: ?sandbox_host.InteractionOutcome,
    interaction_submission_failures: u64,
    developer_controller: developer_controls.Controller,
    developer_control_requests: developer_controls.RequestBuffer,
    developer_diagnostic_requests: developer_diagnostics.RequestBuffer,
    developer_profiler: developer_profile.DefaultRecorder,
    developer_visualization_controller: developer_visualization.Controller,
    developer_visualization_requests: developer_visualization.RequestBuffer,
    active_frame_profile: ?*HostFrameProfile,
    physics_debug_cpu: ?PhysicsDebugCpuStorage,
    physics_debug_batch_summary: ?developer_visualization.BatchSummary,
    physics_debug_overlay: ?physics_debug_gpu.Overlay,
    validation: ValidationAppState,
    game_camera: camera.Camera,
    // Presentation resources remain owned by the visual host.
    ground_mesh: mesh.Mesh,
    block_mesh: mesh.Mesh,
    visuals: sandbox_visual_resources.SandboxVisualResources,
    district_registry: *district_gpu_registry.DistrictGpuRegistry,
    district_stream_slots: [district_stream_slot_count]DistrictStreamSlot,
    district_catalog: ?district_content_catalog.AdmittedCatalog,
    district_content_worker: ?*content.SceneWorker,
    district_content_owner: ?u8,
    district_next_content_generation: u64,
    district_next_request_id: u64,
    district_next_stream_correlation: u64,
    district_focus_override: ?[2]f32,

    // Durable storage remains an explicit visual-host capability. The editor
    // receives only immutable status and a bounded `save` request.
    save_store: ?save_slots.SaveSlots,
    save_metadata: ?sandbox_save.Metadata,
    save_feedback: editor_contract.SaveFeedback,

    // Debug counters
    debug_frame_counter: u32,

    pub fn init(
        io: std.Io,
        comptime profile: BootstrapProfile,
        content_root: ?content.ContentRootPath,
    ) !App {
        return initWithOptions(io, profile, content_root, null, false, false, null);
    }

    pub fn initWithSaveRoot(
        io: std.Io,
        comptime profile: BootstrapProfile,
        content_root: ?content.ContentRootPath,
        save_root: save_slots.RootPath,
    ) !App {
        return initWithOptions(io, profile, content_root, null, false, false, save_root);
    }

    fn initForDiagnosticsSmoke(
        io: std.Io,
        comptime profile: BootstrapProfile,
        content_root: ?content.ContentRootPath,
        save_root: ?save_slots.RootPath,
    ) !App {
        return initWithOptions(io, profile, content_root, null, false, true, save_root);
    }

    fn initWithFailurePoint(
        io: std.Io,
        comptime profile: BootstrapProfile,
        content_root: ?content.ContentRootPath,
        comptime failure_point: AppInitFailurePoint,
    ) !App {
        return initWithOptions(io, profile, content_root, failure_point, false, false, null);
    }

    fn initWithoutPhysicsDebugPipelinesForTest(
        io: std.Io,
        comptime profile: BootstrapProfile,
        content_root: ?content.ContentRootPath,
    ) !App {
        return initWithOptions(io, profile, content_root, null, true, false, null);
    }

    fn initWithOptions(
        io: std.Io,
        comptime profile: BootstrapProfile,
        content_root: ?content.ContentRootPath,
        comptime failure_point: ?AppInitFailurePoint,
        comptime omit_physics_debug_pipelines: bool,
        comptime diagnostic_fault_probe: bool,
        save_root: ?save_slots.RootPath,
    ) !App {
        // Initialize SDL3 with video subsystem
        if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
            std.debug.print("SDL_Init failed: {s}\n", .{c.SDL_GetError()});
            return error.SDLInitFailed;
        }
        errdefer c.SDL_Quit();

        // Create the window
        const window = c.SDL_CreateWindow(
            WINDOW_TITLE,
            INITIAL_WINDOW_WIDTH,
            INITIAL_WINDOW_HEIGHT,
            c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_HIGH_PIXEL_DENSITY,
        ) orelse {
            std.debug.print("SDL_CreateWindow failed: {s}\n", .{c.SDL_GetError()});
            return error.SDLWindowFailed;
        };
        errdefer c.SDL_DestroyWindow(window);

        const main_window_id = c.SDL_GetWindowID(window);
        if (main_window_id == 0) {
            std.debug.print("SDL_GetWindowID failed: {s}\n", .{c.SDL_GetError()});
            return error.SDLWindowIdFailed;
        }

        // Create GPU renderer
        var gpu_renderer = if (omit_physics_debug_pipelines)
            try renderer.Renderer.initWithoutPhysicsDebugPipelinesForTest(window)
        else if (failure_point == null)
            try renderer.Renderer.init(window)
        else switch (failure_point.?) {
            .renderer_after_window_claim => try renderer.Renderer.initWithFailurePoint(
                window,
                .after_window_claim,
            ),
            .renderer_after_pipelines => try renderer.Renderer.initWithFailurePoint(
                window,
                .after_pipelines,
            ),
            .renderer_after_placeholder_resources => try renderer.Renderer.initWithFailurePoint(
                window,
                .after_placeholder_resources,
            ),
            .after_renderer, .after_visual_resources, .after_simulation => try renderer.Renderer.init(window),
        };
        errdefer gpu_renderer.deinit();
        if (failure_point != null) {
            try injectAppInitFailure(failure_point, .after_renderer);
        }

        var physics_debug_cpu = PhysicsDebugCpuStorage.init();
        errdefer if (physics_debug_cpu) |*owner| owner.deinit();
        var physics_debug_overlay: ?physics_debug_gpu.Overlay = if (physics_debug_cpu != null)
            physics_debug_gpu.Overlay.init(&gpu_renderer, .{
                .line_capacity = @intCast(physics_debug_line_capacity),
                .triangle_capacity = @intCast(physics_debug_triangle_capacity),
                .initially_enabled = false,
            }) catch |err| blk: {
                std.debug.print(
                    "Physics debug GPU overlay unavailable: {s}\n",
                    .{@errorName(err)},
                );
                break :blk null;
            }
        else
            null;
        errdefer if (physics_debug_overlay) |*overlay| overlay.deinit();

        // Create ground plane mesh
        var ground_mesh = try primitives.createGroundPlane(gpu_renderer.getDevice());
        errdefer ground_mesh.deinit();

        var block_mesh = try primitives.createCube(gpu_renderer.getDevice());
        errdefer block_mesh.deinit();

        const district_registry = try std.heap.page_allocator.create(
            district_gpu_registry.DistrictGpuRegistry,
        );
        errdefer std.heap.page_allocator.destroy(district_registry);
        district_registry.* = try district_gpu_registry.DistrictGpuRegistry.init(
            std.heap.page_allocator,
            .{ .device = gpu_renderer.getDevice() },
            .{},
            .{},
        );
        errdefer district_registry.deinit();
        const district_stream_slots = [district_stream_slot_count]DistrictStreamSlot{
            .{
                .coord = district_west_coord,
                .presentation = DistrictPresentation.init(district_registry),
                .proximity = try district_presentation.ProximityHysteresis.init(
                    district_proximity_configs[0],
                ),
            },
            .{
                .coord = district_east_coord,
                .presentation = DistrictPresentation.init(district_registry),
                .proximity = try district_presentation.ProximityHysteresis.init(
                    district_proximity_configs[1],
                ),
            },
        };

        const character_config = sandbox_host.CharacterConfig{
            .assets = .{
                .mesh = sandbox_visual_resources.character_mesh_handle,
                .material = sandbox_visual_resources.character_material_handle,
            },
        };
        const vehicle_config = sandbox_host.VehicleConfig{
            .assets = .{
                .chassis_mesh = sandbox_visual_resources.vehicle_chassis_mesh_handle,
                .chassis_material = sandbox_visual_resources.vehicle_chassis_material_handle,
                .wheel_mesh = sandbox_visual_resources.vehicle_wheel_mesh_handle,
                .wheel_material = sandbox_visual_resources.vehicle_wheel_material_handle,
            },
        };
        var visuals = try sandbox_visual_resources.SandboxVisualResources.init(
            gpu_renderer.getDevice(),
            character_config.radius,
            character_config.half_height,
        );
        errdefer visuals.deinit();
        if (failure_point != null) {
            try injectAppInitFailure(failure_point, .after_visual_resources);
        }

        // The visual solo product owns an embedded authority session.
        const simulation_config = sandbox_host.Config{
            .namespace = 1,
            .fixed_delta_seconds = @floatCast(timing.TICK_DURATION),
            .assets = .{
                .mesh = sandbox_visual_resources.crate_mesh_handle,
                .material = sandbox_visual_resources.crate_material_handle,
            },
            .create_ground = true,
            .character = character_config,
            .vehicle = vehicle_config,
            .interaction = .{},
            .npc = .{ .assets = .{
                .mesh = sandbox_visual_resources.character_mesh_handle,
                .material = sandbox_visual_resources.character_material_handle,
            } },
            .block = switch (profile) {
                .sandbox, .s1_smoke => sandbox_block,
                .s0_smoke, .s2_smoke, .s3_smoke => null,
            },
        };
        var simulation = if (diagnostic_fault_probe)
            try sandbox_host.Session.initWithDiagnosticFaultProbe(
                std.heap.page_allocator,
                simulation_config,
            )
        else
            try sandbox_host.Session.init(
                std.heap.page_allocator,
                simulation_config,
            );
        errdefer simulation.deinit();
        if (failure_point != null) {
            try injectAppInitFailure(failure_point, .after_simulation);
        }

        const authoring_transactions = try std.heap.page_allocator.create(
            sandbox_authoring.TransactionSequencer,
        );
        errdefer std.heap.page_allocator.destroy(authoring_transactions);
        authoring_transactions.* = .{};

        var save_store: ?save_slots.SaveSlots = null;
        errdefer if (save_store) |*store| store.deinit(io);
        var save_metadata: ?sandbox_save.Metadata = null;
        const streams_districts = profile == .sandbox or profile == .s3_smoke;
        const needs_catalog = streams_districts or save_root != null;
        var admitted_catalog: ?district_content_catalog.AdmittedCatalog = null;
        errdefer if (admitted_catalog) |*catalog_owner| catalog_owner.deinit();
        if (needs_catalog) {
            const content_root_path = content_root orelse
                return error.ContentRootRequired;
            admitted_catalog = switch (try district_content_catalog.admit(
                io,
                std.heap.page_allocator,
                content_root_path,
            )) {
                .admitted => |value| value,
                .failed => |failure| {
                    std.debug.print("District catalog admission failed: {any}\n", .{failure});
                    return error.DistrictCatalogAdmissionFailed;
                },
            };
            try validateDistrictStreamCatalogEntries(
                admitted_catalog.?.view().entries,
            );
        }
        if (save_root) |root_path| {
            const content_cohort = admitted_catalog.?.contentCohort();
            save_store = try save_slots.SaveSlots.open(io, root_path);
            switch (save_store.?.recover(
                io,
                try save_slots.SlotId.parse(sandbox_save_slot_id),
            )) {
                .clean, .discarded_stale_candidate => {},
                .failed => |failure| {
                    std.debug.print("Save candidate recovery failed: {any}\n", .{failure});
                    return error.SaveRecoveryFailed;
                },
            }
            save_metadata = .{
                .payload_schema = sandbox_host.snapshot_schema,
                .simulation_build_digest = try sandbox_host.currentSimulationBuildFingerprint(),
                .world_config_digest = try sandbox_host.worldConfigFingerprint(simulation_config),
                .content_digest = try content_cohort.fingerprint(),
            };
        }

        var district_content_worker: ?*content.SceneWorker = null;
        if (streams_districts) {
            const worker = try std.heap.page_allocator.create(content.SceneWorker);
            errdefer std.heap.page_allocator.destroy(worker);
            worker.* = content.SceneWorker.init(io, std.heap.page_allocator);
            errdefer worker.deinit();
            district_content_worker = worker;
        }
        if (profile != .s3_smoke) {
            try simulation.submit(.{ .spawn = .{
                .request_id = 1,
                .pose = .{ .position = switch (profile) {
                    .s2_smoke => .{ 0, 0.5, -9 },
                    .sandbox, .s0_smoke, .s1_smoke => .{ 0, 12, 0 },
                    .s3_smoke => unreachable,
                } },
                .velocity = .{ .angular = .{ 0.2, 0.35, 0.1 } },
            } });
        }
        if (profile != .s0_smoke and profile != .s3_smoke) {
            try simulation.submitCharacter(.{ .spawn = .{
                .request_id = 1,
                .position = switch (profile) {
                    .s2_smoke => .{ 0, 0, 2 },
                    .sandbox, .s1_smoke => .{ 0, 0, 4 },
                    .s0_smoke, .s3_smoke => unreachable,
                },
            } });
        }
        if (profile == .sandbox or profile == .s2_smoke) {
            try simulation.submitVehicle(.{ .spawn = .{
                .request_id = 1,
                .chassis = .{ .pose = .{ .position = switch (profile) {
                    .sandbox => .{ 0, 2, 2 },
                    .s2_smoke => .{ 0, 2, 0 },
                    .s0_smoke, .s1_smoke, .s3_smoke => unreachable,
                } } },
            } });
        }

        // Initialize editor (ImGui debug UI)
        // This sets up ImGui with our SDL3 GPU device
        const developer_editor = editor.Editor.init(
            window,
            gpu_renderer.getDevice(),
            gpu_renderer.getSwapchainFormat(),
        );

        std.debug.print("===========================================\n", .{});
        std.debug.print(" Incinerator Engine initialized ({s} composition)\n", .{@tagName(profile)});
        std.debug.print(" Window: {d}x{d}\n", .{ INITIAL_WINDOW_WIDTH, INITIAL_WINDOW_HEIGHT });
        std.debug.print(" Tick rate: {d} Hz ({d:.3} ms)\n", .{ timing.TICK_RATE, timing.TICK_DURATION * 1000.0 });
        std.debug.print("===========================================\n", .{});
        std.debug.print(" Controls:\n", .{});
        std.debug.print("   ESC - Quit\n", .{});
        std.debug.print("   WASD - Move character / drive vehicle\n", .{});
        std.debug.print("   E - Enter / exit vehicle\n", .{});
        std.debug.print("   F - Collect / drop carryable\n", .{});
        std.debug.print("   SPACE - Jump / vehicle brake\n", .{});
        std.debug.print("   LEFT SHIFT - Vehicle hand brake\n", .{});
        std.debug.print("   Right-click + drag - Turn/look\n", .{});
        std.debug.print("   F1 - Toggle editor UI\n", .{});
        std.debug.print("   F2 - Toggle ImGui demo\n", .{});
        std.debug.print("   F3 - Toggle editor input passthrough\n", .{});
        std.debug.print("===========================================\n\n", .{});

        return App{
            .io = io,
            .window = window,
            .gpu_renderer = gpu_renderer,
            .developer_editor = developer_editor,
            .frame_timer = timing.FrameTimer.init(),
            .input_buffer = input.InputBuffer.init(main_window_id),
            .simulation = simulation,
            .initial_crate_id = null,
            .initial_character_id = null,
            .initial_vehicle_id = null,
            .initial_carryable_id = null,
            .controlled_vehicle_id = null,
            .action_latch = .{},
            .authoring_transactions = authoring_transactions,
            .authoring_controller = sandbox_authoring.DefaultController.init(
                authoring_transactions,
            ),
            .authoring_requests = .{},
            .authoring_feedback = .{},
            .interaction_spawn_enabled = profile == .sandbox,
            .interaction_spawn_submitted = false,
            .interaction_transactions = .{},
            .interaction_requests = .{},
            .interaction_last_outcome = null,
            .interaction_submission_failures = 0,
            .developer_controller = .{},
            .developer_control_requests = .{},
            .developer_diagnostic_requests = .{},
            .developer_profiler = .{},
            .developer_visualization_controller = .{},
            .developer_visualization_requests = .{},
            .active_frame_profile = null,
            .physics_debug_cpu = physics_debug_cpu,
            .physics_debug_batch_summary = null,
            .physics_debug_overlay = physics_debug_overlay,
            .validation = if (build_options.validation_mode or builtin.is_test)
                .{ .profile = profile }
            else {},
            .ground_mesh = ground_mesh,
            .block_mesh = block_mesh,
            .visuals = visuals,
            .district_registry = district_registry,
            .district_stream_slots = district_stream_slots,
            .district_catalog = admitted_catalog,
            .district_content_worker = district_content_worker,
            .district_content_owner = null,
            .district_next_content_generation = 1,
            .district_next_request_id = 1,
            .district_next_stream_correlation = 1,
            .district_focus_override = null,
            .save_store = save_store,
            .save_metadata = save_metadata,
            .save_feedback = if (save_store != null) .{
                .status = .idle,
                .slot_label = sandbox_save_slot_id,
                .detail = "ready",
            } else .{
                .status = .unavailable,
                .slot_label = sandbox_save_slot_id,
                .detail = "start with --save-root=<absolute-existing-directory>",
            },
            .game_camera = .{
                .position = .{ 0, 3, 10, 1 },
                .yaw = 0,
                .pitch = -0.25,
            },
            .debug_frame_counter = 0,
        };
    }

    pub fn deinit(self: *App) void {
        const completed_ticks = self.simulation.tickIndex();

        // Errors may unwind after external buffers were encoded into a frame
        // but before normal submission. Retire and drain that work before any
        // editor, overlay, mesh, texture, or streamed-GPU owner is released.
        self.gpu_renderer.drainForExternalTeardown();

        // Clean up editor first (needs GPU device to still be valid)
        self.developer_editor.deinit();
        if (self.physics_debug_overlay) |*overlay| overlay.deinit();
        self.physics_debug_overlay = null;
        if (self.district_content_worker) |worker| {
            worker.deinit();
            std.heap.page_allocator.destroy(worker);
            self.district_content_worker = null;
        }
        for (0..district_stream_slot_count) |slot_index| {
            self.clearPendingDistrictScene(slot_index);
        }
        self.simulation.deinit();
        if (self.save_store) |*store| store.deinit(self.io);
        self.save_store = null;
        std.heap.page_allocator.destroy(self.authoring_transactions);
        for (&self.district_stream_slots) |*slot| {
            slot.presentation.releaseAfterSimulationTeardown() catch |err| {
                std.debug.panic("district presentation teardown failed: {s}", .{@errorName(err)});
            };
        }
        self.district_registry.deinit();
        std.heap.page_allocator.destroy(self.district_registry);
        if (self.district_catalog) |*catalog_owner| catalog_owner.deinit();
        self.district_catalog = null;
        self.ground_mesh.deinit();
        self.block_mesh.deinit();
        self.visuals.deinit();
        self.gpu_renderer.deinit();
        if (self.physics_debug_cpu) |*owner| owner.deinit();
        self.physics_debug_cpu = null;
        c.SDL_DestroyWindow(self.window);
        c.SDL_Quit();

        std.debug.print("\n===========================================\n", .{});
        std.debug.print(" Incinerator Engine shutdown\n", .{});
        std.debug.print(" Total frames: {d}\n", .{self.frame_timer.total_frames});
        std.debug.print(" Total simulation ticks: {d}\n", .{completed_ticks});
        std.debug.print("===========================================\n", .{});
    }

    fn beginHostProfile(
        self: *App,
        phase: developer_profile.Phase,
        frame_index: ?u64,
        tick_index: ?u64,
    ) HostProfileScope {
        return .{
            .recorder = &self.developer_profiler,
            .token = if (self.developer_visualization_controller.profiling_enabled)
                self.developer_profiler.spans.begin(
                    phase,
                    frame_index,
                    tick_index,
                    profileNowNs(),
                )
            else
                null,
        };
    }

    fn beginFrameProfile(self: *App, frame_index: u64) HostFrameProfile {
        return .{
            .recorder = &self.developer_profiler,
            .token = if (self.developer_visualization_controller.profiling_enabled)
                self.developer_profiler.frames.begin(
                    frame_index,
                    self.simulation.tickIndex(),
                    profileNowNs(),
                )
            else
                null,
        };
    }

    fn mergeProfileCounts(self: *App, counts: developer_profile.Counts) void {
        if (self.active_frame_profile) |frame| frame.counts.merge(counts);
    }

    /// Run the interactive product loop. This surface has no scenario,
    /// cadence-injection, or acceptance-summary input, so validation code is
    /// unreachable from the normal client composition.
    pub fn runProduct(self: *App) !void {
        var running = true;
        var retained_runtime_error: ?anyerror = null;

        game_loop: while (running) {
            var input_profile = self.beginHostProfile(
                .input,
                self.frame_timer.total_frames +| 1,
                self.simulation.tickIndex(),
            );
            defer input_profile.finish(.failure);
            self.input_buffer.beginFrame();
            running = self.input_buffer.pumpEvents(self.developer_editor.eventSink());
            if (running and retained_runtime_error == null and
                !self.developer_controller.paused)
            {
                try self.captureFrameActions();
            }
            input_profile.finish(.success);
            if (!running) break;
            if (self.waitForWindowSuspension()) continue;

            var frame_profile = self.beginFrameProfile(self.frame_timer.total_frames +| 1);
            self.active_frame_profile = &frame_profile;
            defer {
                self.active_frame_profile = null;
                frame_profile.finish(.failure);
            }
            if (retained_runtime_error != null) {
                self.frame_timer.beginControlledFrame(.paused);
                _ = try self.renderFaultInspectionFrame();
                frame_profile.finish(.success);
                continue;
            }

            self.frame_timer.beginControlledFrame(
                self.developer_controller.clockPolicy(),
            );
            var content_profile = self.beginHostProfile(
                .content_pump,
                self.frame_timer.total_frames,
                self.simulation.tickIndex(),
            );
            defer content_profile.finish(.failure);
            try self.pumpDistrictContent();
            content_profile.finish(.success);

            if (self.developer_controller.takeSingleStep()) {
                self.simulateTick(false, .none) catch |err| {
                    if (self.simulation.firstFault() == null) return err;
                    retained_runtime_error = err;
                    self.enterFaultInspection();
                    _ = try self.renderFaultInspectionFrame();
                    continue :game_loop;
                };
                self.frame_timer.recordSingleStep();
            } else if (!self.developer_controller.paused) {
                while (self.frame_timer.shouldTick()) {
                    self.simulateTick(false, .none) catch |err| {
                        if (self.simulation.firstFault() == null) return err;
                        retained_runtime_error = err;
                        self.enterFaultInspection();
                        _ = try self.renderFaultInspectionFrame();
                        continue :game_loop;
                    };
                    self.frame_timer.recordCompletedTick();
                }
            }

            _ = try self.render(self.frame_timer.alpha());
            frame_profile.finish(.success);
            self.debug_frame_counter += 1;
            if (self.debug_frame_counter >= DEBUG_PRINT_INTERVAL) {
                self.debug_frame_counter = 0;
                self.printDebugStats();
            }
        }

        if (retained_runtime_error) |err| return err;
    }

    /// Run one validation scenario through the production adapters.
    fn runValidation(
        self: *App,
        smoke: ?VisualSmokeConfig,
        scenario: ScriptedScenario,
    ) !RunSummary {
        var running = true;
        var retained_runtime_error: ?anyerror = null;
        var summary = RunSummary{};
        var smoke_quit_injected = false;
        var first_presented_position: ?[3]f32 = null;
        var first_presented_rotation: ?[4]f32 = null;
        var first_character_position: ?[3]f32 = null;
        const smoke_attempt_limit = if (smoke) |config|
            (std.math.mul(u64, config.frames, 4) catch unreachable) + 120
        else
            0;

        game_loop: while (running) {
            var input_profile = self.beginHostProfile(
                .input,
                self.frame_timer.total_frames +| 1,
                self.simulation.tickIndex(),
            );
            defer input_profile.finish(.failure);
            // ================================================================
            // PHASE 1: INPUT PUMP (Per-Frame)
            // ================================================================
            // Clear per-frame input state and poll all SDL events.
            // This runs every frame to ensure responsive input.
            self.input_buffer.beginFrame();
            running = self.input_buffer.pumpEvents(self.developer_editor.eventSink());
            if (running and
                self.validation.profile == .sandbox and
                scenario == .none and
                retained_runtime_error == null and
                !self.developer_controller.paused)
            {
                try self.captureFrameActions();
            }
            input_profile.finish(.success);
            if (!running) break;
            if (self.waitForWindowSuspension()) continue;

            var frame_profile = self.beginFrameProfile(self.frame_timer.total_frames +| 1);
            self.active_frame_profile = &frame_profile;
            defer {
                self.active_frame_profile = null;
                frame_profile.finish(.failure);
            }
            if (retained_runtime_error != null) {
                if (self.validation.s4_fault_loop_probe) |probe| {
                    const stream_now = self.developerDistrictStreamsSnapshot();
                    const gpu_now = developerGpuUsage(
                        (try self.district_registry.diagnostics()).current,
                    );
                    if (probe.content_pump_calls != probe.content_pump_calls_at_fault or
                        probe.gpu_pump_calls != probe.gpu_pump_calls_at_fault or
                        self.simulation.tickIndex() != probe.tick_at_fault or
                        self.frame_timer.total_ticks != probe.completed_ticks_at_fault or
                        !std.meta.eql(probe.stream_at_fault.?, stream_now) or
                        !std.meta.eql(probe.gpu_at_fault.?, gpu_now))
                    {
                        return error.S4DiagnosticsFaultGateProgressed;
                    }
                }
                self.frame_timer.beginControlledFrame(.paused);
                const inspection_ready = try self.renderFaultInspectionFrame();
                frame_profile.finish(.success);
                if (inspection_ready) summary.ready_frames += 1;
                summary.attempted_frames += 1;
                if (self.validation.s4_fault_loop_probe) |probe| {
                    if (inspection_ready) {
                        probe.retained_ready_frames += 1;
                        if (!probe.quit_injected) {
                            var quit_event = std.mem.zeroes(c.SDL_Event);
                            quit_event.type = c.SDL_EVENT_QUIT;
                            if (!c.SDL_PushEvent(&quit_event)) {
                                return error.SDLQuitEventFailed;
                            }
                            probe.quit_injected = true;
                        }
                    }
                }
                continue;
            }

            // Smoke mode feeds an explicit cadence through the same fixed-step
            // policy; normal execution adapts the SDL performance clock.
            if (self.validation.s4_fault_loop_probe != null) {
                try self.frame_timer.beginControlledFrameWithElapsedSeconds(
                    timing.TICK_DURATION,
                    self.developer_controller.clockPolicy(),
                );
            } else if (smoke) |config| {
                try self.frame_timer.beginControlledFrameWithElapsedSeconds(
                    1.0 / @as(f64, @floatFromInt(config.virtual_render_hz)),
                    self.developer_controller.clockPolicy(),
                );
            } else {
                self.frame_timer.beginControlledFrame(
                    self.developer_controller.clockPolicy(),
                );
            }
            if (self.validation.s4_fault_loop_probe) |probe| probe.content_pump_calls += 1;
            var content_profile = self.beginHostProfile(
                .content_pump,
                self.frame_timer.total_frames,
                self.simulation.tickIndex(),
            );
            defer content_profile.finish(.failure);
            try self.pumpDistrictContent();
            content_profile.finish(.success);

            // ================================================================
            // PHASE 2: SIMULATION TICK (Fixed 120Hz)
            // ================================================================
            // Run simulation at fixed timestep. Multiple ticks may run per frame
            // if we're behind, or zero ticks if we're ahead.
            if (self.developer_controller.takeSingleStep()) {
                self.simulateTick(true, scenario) catch |err| {
                    if (self.simulation.firstFault() == null) return err;
                    if (smoke != null) return err;
                    retained_runtime_error = err;
                    try self.captureS4FaultLoopProbe(err);
                    self.enterFaultInspection();
                    _ = try self.renderFaultInspectionFrame();
                    summary.attempted_frames += 1;
                    continue :game_loop;
                };
                self.frame_timer.recordSingleStep();
            } else if (!self.developer_controller.paused) {
                while (self.frame_timer.shouldTick()) {
                    self.simulateTick(true, scenario) catch |err| {
                        if (self.simulation.firstFault() == null) return err;
                        if (smoke != null) return err;
                        retained_runtime_error = err;
                        try self.captureS4FaultLoopProbe(err);
                        self.enterFaultInspection();
                        _ = try self.renderFaultInspectionFrame();
                        summary.attempted_frames += 1;
                        continue :game_loop;
                    };
                    self.frame_timer.recordCompletedTick();
                }
            }

            // ================================================================
            // PHASE 3: PRESENTATION (Interpolated)
            // ================================================================
            // Render the current state. The alpha value can be used to
            // interpolate between previous and current state for smoothness.
            const alpha = self.frame_timer.alpha();
            const render_result = try self.render(alpha);
            frame_profile.finish(.success);
            const render_ready = switch (render_result) {
                .ready => true,
                .unavailable => false,
            };
            summary.attempted_frames += 1;
            summary.min_alpha = @min(summary.min_alpha, alpha);
            summary.max_alpha = @max(summary.max_alpha, alpha);
            switch (render_result) {
                .ready => |presentation| {
                    summary.ready_frames += 1;
                    if (presentation.crate_count == 1) {
                        const presented_id = presentation.first_id orelse
                            return error.VisualSmokePresentationInvariant;
                        if (self.initial_crate_id) |spawned_id| {
                            if (!std.meta.eql(spawned_id, presented_id)) {
                                return error.VisualSmokePresentedWrongCrate;
                            }
                        }
                        summary.crate_presented_frames += 1;
                        const position = presentation.first_position orelse
                            return error.VisualSmokePresentationInvariant;
                        const rotation = presentation.first_rotation orelse
                            return error.VisualSmokePresentationInvariant;
                        if (first_presented_position) |first| {
                            summary.position_changed = summary.position_changed or
                                vectorChanged(3, first, position);
                        } else {
                            first_presented_position = position;
                        }
                        if (first_presented_rotation) |first| {
                            summary.rotation_changed = summary.rotation_changed or
                                vectorChanged(4, first, rotation);
                        } else {
                            first_presented_rotation = rotation;
                        }
                    } else if (self.initial_crate_id != null) {
                        return error.VisualSmokeCratePresentationMissing;
                    }
                    switch (scenario) {
                        .none, .s3_streaming, .s7_interaction => {},
                        .s1_character => if (self.initial_character_id != null) {
                            if (presentation.character_count != 1) {
                                return error.S1VisualSmokeCharacterPresentationMissing;
                            }
                            const presented_id = presentation.character_id orelse
                                return error.S1VisualSmokeCharacterPresentationMissing;
                            const spawned_id = self.initial_character_id orelse
                                return error.S1VisualSmokeCharacterSpawnMissing;
                            if (!std.meta.eql(presented_id, spawned_id)) {
                                return error.S1VisualSmokePresentedWrongCharacter;
                            }
                            const position = presentation.character_position orelse
                                return error.S1VisualSmokeCharacterPresentationMissing;
                            summary.character_presented_frames += 1;
                            if (first_character_position) |first| {
                                summary.character_position_changed =
                                    summary.character_position_changed or
                                    vectorChanged(3, first, position);
                                summary.character_jump_observed =
                                    summary.character_jump_observed or
                                    position[1] > first[1] + 0.1;
                            } else {
                                first_character_position = position;
                            }
                        },
                        .s2_vehicle => {
                            if (self.initial_vehicle_id) |spawned_id| {
                                if (presentation.vehicle_count != 1) {
                                    return error.S2VisualSmokeVehiclePresentationMissing;
                                }
                                const presented_id = presentation.vehicle_id orelse
                                    return error.S2VisualSmokeVehiclePresentationMissing;
                                if (!std.meta.eql(presented_id, spawned_id)) {
                                    return error.S2VisualSmokePresentedWrongVehicle;
                                }
                                summary.vehicle_presented_frames += 1;
                            }
                            if (self.initial_character_id) |spawned_id| {
                                if (self.validation.s2_smoke.entered and !self.validation.s2_smoke.exited) {
                                    if (presentation.character_count != 0) {
                                        return error.S2VisualSmokeDrivingCharacterVisible;
                                    }
                                    summary.character_hidden_while_driving = true;
                                } else {
                                    if (presentation.character_count != 1) {
                                        return error.S2VisualSmokeCharacterPresentationMissing;
                                    }
                                    const presented_id = presentation.character_id orelse
                                        return error.S2VisualSmokeCharacterPresentationMissing;
                                    if (!std.meta.eql(presented_id, spawned_id)) {
                                        return error.S2VisualSmokePresentedWrongCharacter;
                                    }
                                    summary.character_presented_frames += 1;
                                    if (self.validation.s2_smoke.exited) {
                                        summary.character_visible_after_exit = true;
                                    }
                                }
                            }
                        },
                        .s4_physics_debug => {
                            if (self.initial_character_id) |spawned_id| {
                                if (presentation.character_count != 1 or
                                    !std.meta.eql(
                                        presentation.character_id orelse
                                            return error.S4PhysicsDebugCharacterPresentationMissing,
                                        spawned_id,
                                    ))
                                {
                                    return error.S4PhysicsDebugCharacterPresentationMissing;
                                }
                                summary.character_presented_frames += 1;
                            }
                            if (self.initial_vehicle_id) |spawned_id| {
                                if (presentation.vehicle_count != 1 or
                                    !std.meta.eql(
                                        presentation.vehicle_id orelse
                                            return error.S4PhysicsDebugVehiclePresentationMissing,
                                        spawned_id,
                                    ))
                                {
                                    return error.S4PhysicsDebugVehiclePresentationMissing;
                                }
                                summary.vehicle_presented_frames += 1;
                            }
                        },
                    }
                },
                .unavailable => summary.unavailable_frames += 1,
            }

            if (smoke) |config| {
                if (render_ready) {
                    c.SDL_DelayPrecise(
                        @as(u64, std.time.ns_per_s) / config.virtual_render_hz,
                    );
                }
                if (summary.ready_frames == config.frames and !smoke_quit_injected) {
                    var quit_event = std.mem.zeroes(c.SDL_Event);
                    quit_event.type = c.SDL_EVENT_QUIT;
                    if (!c.SDL_PushEvent(&quit_event)) return error.SDLQuitEventFailed;
                    smoke_quit_injected = true;
                }
                if (summary.attempted_frames >= smoke_attempt_limit and
                    !smoke_quit_injected)
                {
                    return error.VisualSmokeFrameLimit;
                }
            }

            // ================================================================
            // DEBUG OUTPUT
            // ================================================================
            self.debug_frame_counter += 1;
            if (self.debug_frame_counter >= DEBUG_PRINT_INTERVAL) {
                self.debug_frame_counter = 0;
                self.printDebugStats();
            }
        }

        if (retained_runtime_error) |err| return err;

        if (smoke != null and !smoke_quit_injected) {
            return error.VisualSmokeInterrupted;
        }
        if (smoke) |config| {
            if (summary.unavailable_frames != 0) return error.VisualSmokeUnavailableFrame;
            if (self.initial_crate_id == null) return error.VisualSmokeSpawnMissing;
            if (summary.crate_presented_frames == 0) {
                return error.VisualSmokeCratePresentationMissing;
            }
            if (!summary.position_changed) return error.VisualSmokePositionDidNotChange;
            if (!summary.rotation_changed) return error.VisualSmokeRotationDidNotChange;
            switch (scenario) {
                .none => if (self.simulation.crateCount() != 1 or
                    self.simulation.characterCount() != 0 or
                    self.simulation.vehicleCount() != 0 or
                    self.simulation.entityCount() != 1 or
                    self.simulation.bodyCount() != 2)
                {
                    return error.VisualSmokeLifecycleInvariant;
                },
                .s1_character => {
                    if (self.initial_character_id == null) {
                        return error.S1VisualSmokeCharacterSpawnMissing;
                    }
                    if (summary.character_presented_frames == 0 or
                        !summary.character_position_changed or
                        !summary.character_jump_observed)
                    {
                        return error.S1VisualSmokeCharacterDidNotMove;
                    }
                    if (self.simulation.crateCount() != 1 or
                        self.simulation.characterCount() != 1 or
                        self.simulation.vehicleCount() != 0 or
                        self.simulation.entityCount() != 2 or
                        self.simulation.bodyCount() != 3)
                    {
                        return error.S1VisualSmokeLifecycleInvariant;
                    }
                    const character = try self.simulation.character(self.initial_character_id.?);
                    if (character.position[2] < -4.2 or character.position[2] > -3.5) {
                        return error.S1VisualSmokeBlockCollisionFailed;
                    }
                },
                .s2_vehicle => {
                    if (self.simulation.tickIndex() < s2_required_ticks) {
                        return error.S2VisualSmokeInsufficientTicks;
                    }
                    if (self.initial_character_id == null or self.initial_vehicle_id == null) {
                        return error.S2VisualSmokeSpawnMissing;
                    }
                    if (summary.vehicle_presented_frames == 0 or
                        !summary.character_hidden_while_driving or
                        !summary.character_visible_after_exit or
                        !self.validation.s2_smoke.entered or
                        !self.validation.s2_smoke.drive_applied or
                        !self.validation.s2_smoke.steering_applied or
                        !self.validation.s2_smoke.brake_applied or
                        !self.validation.s2_smoke.steering_observed or
                        !self.validation.s2_smoke.vehicle_moved or
                        !self.validation.s2_smoke.crate_displaced or
                        !self.validation.s2_smoke.exited)
                    {
                        return error.S2VisualSmokeLifecycleEvidenceMissing;
                    }
                    if (self.controlled_vehicle_id != null or
                        self.simulation.crateCount() != 1 or
                        self.simulation.characterCount() != 1 or
                        self.simulation.vehicleCount() != 1 or
                        self.simulation.entityCount() != 3 or
                        self.simulation.bodyCount() != 3)
                    {
                        return error.S2VisualSmokeLifecycleInvariant;
                    }
                    const vehicle = try self.simulation.vehicle(self.initial_vehicle_id.?);
                    if (vehicle.driver_id != null) {
                        return error.S2VisualSmokeDriverStillActive;
                    }
                },
                .s3_streaming, .s7_interaction => {},
                .s4_physics_debug => try self.validateS4PhysicsDebugSmoke(summary),
            }
            const expected = try smokeExpectation(config);
            if (self.simulation.tickIndex() != expected.ticks) {
                return error.VisualSmokeTickCountMismatch;
            }
            if (@abs(summary.min_alpha - expected.min_alpha) > 0.00001 or
                @abs(summary.max_alpha - expected.max_alpha) > 0.00001)
            {
                return error.VisualSmokeAlphaMismatch;
            }
        }
        return summary;
    }

    fn validateS4PhysicsDebugSmoke(self: *App, summary: RunSummary) !void {
        if (self.initial_character_id == null or self.initial_vehicle_id == null or
            summary.character_presented_frames == 0 or
            summary.vehicle_presented_frames == 0)
        {
            return error.S4PhysicsDebugPresentationEvidenceMissing;
        }
        if (self.simulation.crateCount() != 1 or
            self.simulation.characterCount() != 1 or
            self.simulation.vehicleCount() != 1 or
            self.simulation.districtCount() != 1 or
            self.simulation.entityCount() != 4 or
            self.simulation.bodyCount() <= 3)
        {
            return error.S4PhysicsDebugLifecycleInvariant;
        }
        switch (self.district_stream_slots[district_west_slot_index].state) {
            .active => {},
            else => return error.S4PhysicsDebugDistrictNotActive,
        }
        if (!self.validation.s4_physics_debug_evidence.allCategoriesObserved() or
            self.validation.s4_physics_debug_evidence.batches == 0 or
            self.validation.s4_physics_debug_evidence.peak_lines == 0)
        {
            return error.S4PhysicsDebugCategoryEvidenceMissing;
        }

        const overlay = if (self.physics_debug_overlay) |*value| value else return error.S4PhysicsDebugGpuUnavailable;
        _ = overlay.poll();
        const gpu = overlay.stats();
        if (gpu.mode != .enabled or
            gpu.resources.slot_count != physics_debug_gpu.default_slot_count or
            gpu.resources.gpu_buffer_count != physics_debug_gpu.default_slot_count * 2 or
            gpu.resources.transfer_buffer_count != physics_debug_gpu.default_slot_count * 2 or
            gpu.resources.max_owned_fences != physics_debug_gpu.default_slot_count or
            gpu.resources.peak_owned_fences > gpu.resources.max_owned_fences or
            gpu.resources.live_owned_fences > gpu.resources.max_owned_fences or
            gpu.resources.retired_slots != 0 or
            gpu.successful_uploads == 0 or
            gpu.copy_submissions == 0 or
            gpu.copy_completions == 0 or
            gpu.draw_calls == 0 or
            gpu.frame_fences_accepted != gpu.draw_calls or
            gpu.latest_uploaded_generation == 0 or
            gpu.latest_completed_tick == 0 or
            gpu.latest_completed_tick > self.simulation.tickIndex() or
            gpu.failed_uploads != 0 or
            gpu.frame_fence_failures != 0 or
            gpu.slot_retirements != 0)
        {
            return error.S4PhysicsDebugGpuEvidenceMissing;
        }

        var phase_observed = [_]bool{false} ** std.meta.tags(developer_profile.Phase).len;
        const spans = self.developer_profiler.spans.view();
        for (spans.first) |span| phase_observed[@intFromEnum(span.phase)] = true;
        for (spans.second) |span| phase_observed[@intFromEnum(span.phase)] = true;
        for (phase_observed) |observed| {
            if (!observed) return error.S4PhysicsDebugProfilePhaseMissing;
        }

        var frame_counts_observed = false;
        const frames = self.developer_profiler.frames.view();
        for (frames.first) |frame| {
            frame_counts_observed = frame_counts_observed or
                (frame.counts.draw_calls != 0 and
                    frame.counts.debug_primitives != 0 and
                    frame.counts.debug_upload_bytes != 0 and
                    frame.counts.live_resources != 0 and
                    frame.counts.live_resource_bytes != 0);
        }
        for (frames.second) |frame| {
            frame_counts_observed = frame_counts_observed or
                (frame.counts.draw_calls != 0 and
                    frame.counts.debug_primitives != 0 and
                    frame.counts.debug_upload_bytes != 0 and
                    frame.counts.live_resources != 0 and
                    frame.counts.live_resource_bytes != 0);
        }
        if (!frame_counts_observed) return error.S4PhysicsDebugFrameCountsMissing;
    }

    fn captureS4FaultLoopProbe(self: *App, err: anyerror) !void {
        const probe = self.validation.s4_fault_loop_probe orelse return;
        if (err != probe.expected_error or probe.stream_at_fault != null or
            probe.gpu_at_fault != null)
        {
            return error.S4DiagnosticsUnexpectedRetainedFault;
        }
        probe.content_pump_calls_at_fault = probe.content_pump_calls;
        probe.gpu_pump_calls_at_fault = probe.gpu_pump_calls;
        probe.tick_at_fault = self.simulation.tickIndex();
        probe.completed_ticks_at_fault = self.frame_timer.total_ticks;
        probe.stream_at_fault = self.developerDistrictStreamsSnapshot();
        probe.gpu_at_fault = developerGpuUsage(
            (try self.district_registry.diagnostics()).current,
        );
    }

    /// Exercise the production window-suspension path against a real SDL/Metal
    /// window. This is deliberately real-clock and event-driven: a synthetic
    /// flag would not prove that the platform emits the lifecycle transitions
    /// the host relies on.
    pub fn runWindowLifecycleSmoke(self: *App) !WindowLifecycleSummary {
        const Phase = enum {
            warmup,
            await_minimized,
            dwell,
            await_restored,
            restored,
        };
        const ready_frames_per_side = 8;
        const required_dwell_ns = 750 * std.time.ns_per_ms;
        const overall_timeout_ns = 10 * std.time.ns_per_s;
        const max_minimized_wait_iterations = 512;

        var phase: Phase = .warmup;
        var summary = WindowLifecycleSummary{};
        var running = true;
        var quit_injected = false;
        var saw_minimized_event = false;
        var saw_restored_event = false;
        var minimized_started_ns: u64 = 0;
        const smoke_started_ns = c.SDL_GetTicksNS();

        while (running) {
            self.input_buffer.beginFrame();
            running = self.input_buffer.pumpEvents(self.developer_editor.eventSink());
            if (!running) break;

            const now_ns = c.SDL_GetTicksNS();
            if (now_ns - smoke_started_ns > overall_timeout_ns) {
                return error.WindowLifecycleSmokeTimeout;
            }

            if (self.input_buffer.window_minimized_this_frame) {
                if (phase != .await_minimized) {
                    return error.UnexpectedWindowMinimizedEvent;
                }
                saw_minimized_event = true;
                minimized_started_ns = now_ns;
                phase = .dwell;
            }
            if (self.input_buffer.window_restored_this_frame) {
                if (phase != .await_restored) {
                    return error.UnexpectedWindowRestoredEvent;
                }
                saw_restored_event = true;
                phase = .restored;
                self.frame_timer.resyncClock();
            }

            if (phase == .dwell and now_ns - minimized_started_ns >= required_dwell_ns) {
                summary.minimized_dwell_ns = now_ns - minimized_started_ns;
                if (!c.SDL_RestoreWindow(self.window)) {
                    std.debug.print("SDL_RestoreWindow failed: {s}\n", .{c.SDL_GetError()});
                    return error.WindowRestoreFailed;
                }
                if (!c.SDL_SyncWindow(self.window)) {
                    std.debug.print("SDL_SyncWindow after restore failed: {s}\n", .{c.SDL_GetError()});
                    return error.WindowRestoreSyncFailed;
                }
                phase = .await_restored;
            }

            if (phase == .await_minimized or phase == .dwell or phase == .await_restored) {
                summary.minimized_wait_iterations += 1;
                if (summary.minimized_wait_iterations > max_minimized_wait_iterations) {
                    return error.WindowLifecycleBusyLoop;
                }
                if (self.waitForWindowSuspension()) continue;
                _ = c.SDL_WaitEventTimeout(null, 16);
                self.frame_timer.resyncClock();
                continue;
            }

            self.frame_timer.beginFrame();
            while (self.frame_timer.shouldTick()) {
                try self.simulateTick(true, .s1_character);
                self.frame_timer.recordCompletedTick();
            }

            switch (try self.render(self.frame_timer.alpha())) {
                .ready => {
                    switch (phase) {
                        .warmup => {
                            summary.warmup_ready_frames += 1;
                            if (summary.warmup_ready_frames == ready_frames_per_side) {
                                if (!c.SDL_MinimizeWindow(self.window)) {
                                    std.debug.print("SDL_MinimizeWindow failed: {s}\n", .{c.SDL_GetError()});
                                    return error.WindowMinimizeFailed;
                                }
                                if (!c.SDL_SyncWindow(self.window)) {
                                    std.debug.print("SDL_SyncWindow after minimize failed: {s}\n", .{c.SDL_GetError()});
                                    return error.WindowMinimizeSyncFailed;
                                }
                                phase = .await_minimized;
                            }
                        },
                        .restored => {
                            summary.restored_ready_frames += 1;
                            if (summary.restored_ready_frames == ready_frames_per_side and
                                !quit_injected)
                            {
                                var quit_event = std.mem.zeroes(c.SDL_Event);
                                quit_event.type = c.SDL_EVENT_QUIT;
                                if (!c.SDL_PushEvent(&quit_event)) {
                                    return error.SDLQuitEventFailed;
                                }
                                quit_injected = true;
                            }
                        },
                        .await_minimized, .dwell, .await_restored => unreachable,
                    }
                },
                .unavailable => summary.unavailable_frames += 1,
            }
        }

        if (!quit_injected or !saw_minimized_event or !saw_restored_event) {
            return error.WindowLifecycleSmokeInterrupted;
        }
        if (summary.minimized_dwell_ns < required_dwell_ns or
            summary.warmup_ready_frames < ready_frames_per_side or
            summary.restored_ready_frames < ready_frames_per_side)
        {
            return error.WindowLifecycleSmokeInvariant;
        }
        return summary;
    }

    /// Apply the canonical main-window suspension policy. Both the normal loop
    /// and the native lifecycle smoke use this path.
    fn waitForWindowSuspension(self: *App) bool {
        if (!suspendGameplayForWindowState(&self.input_buffer, &self.action_latch)) {
            return false;
        }
        // Do not advance simulation or request a GPU frame. Waiting without an
        // output event preserves SDL's queue for the next input-pump phase.
        _ = c.SDL_WaitEventTimeout(null, 16);
        self.frame_timer.resyncClock();
        return true;
    }

    fn runS3StreamingSmoke(
        self: *App,
        config: VisualSmokeConfig,
    ) !S3StreamingSmokeSummary {
        if (self.validation.profile != .s3_smoke) return error.InvalidS3SmokeProfile;
        var summary = S3StreamingSmokeSummary{};
        var stage: S3SmokeStage = .cancel_first_load;
        var stage_started_frame: u64 = 0;
        var last_scene: ?engine.rendering.SceneHandle = null;
        self.district_focus_override = s3_smoke_near;

        while (summary.attempted_frames < config.frames) {
            self.input_buffer.beginFrame();
            if (!self.input_buffer.pumpEvents(self.developer_editor.eventSink())) {
                return error.S3StreamingSmokeInterrupted;
            }
            if (self.waitForWindowSuspension()) continue;
            try self.frame_timer.beginFrameWithElapsedSeconds(
                1.0 / @as(f64, @floatFromInt(config.virtual_render_hz)),
            );
            try self.pumpDistrictContent();

            var stats = try self.district_registry.stats();
            updateS3SmokePeaks(&summary, stats);
            const west_state = self.district_stream_slots[district_west_slot_index].state;
            switch (stage) {
                .cancel_first_load => switch (west_state) {
                    .request_submitted => |submitted| {
                        last_scene = submitted.scene;
                        self.district_focus_override = s3_smoke_far;
                        stage_started_frame = summary.attempted_frames;
                        stage = .wait_cancel_drain;
                    },
                    else => self.district_focus_override = s3_smoke_near,
                },
                .wait_cancel_drain => {
                    self.district_focus_override = s3_smoke_far;
                    if (std.meta.activeTag(west_state) == .idle and
                        std.meta.eql(stats, district_gpu_registry.Stats{}))
                    {
                        try self.requireStaleDistrictScene(last_scene orelse
                            return error.S3StreamingSmokeSceneMissing);
                        summary.cancelled_loads += 1;
                        summary.cancel_to_drained_frames =
                            summary.attempted_frames - stage_started_frame + 1;
                        last_scene = null;
                        self.district_focus_override = s3_smoke_near;
                        stage_started_frame = summary.attempted_frames;
                        stage = .load_to_resident;
                    }
                },
                .load_to_resident => {
                    self.district_focus_override = s3_smoke_near;
                    switch (west_state) {
                        .active => |active| if (try self.district_registry.residency(
                            active.scene,
                        ) == .resident) {
                            try self.validateS3Resident(active);
                            try self.validateS3ResidentDeveloperSnapshot();
                            summary.diagnostic_resident_snapshot = true;
                            last_scene = active.scene;
                            summary.resident_cycles += 1;
                            summary.peak_load_to_resident_frames = @max(
                                summary.peak_load_to_resident_frames,
                                summary.attempted_frames - stage_started_frame + 1,
                            );
                            self.district_focus_override = s3_smoke_far;
                            stage_started_frame = summary.attempted_frames;
                            stage = .wait_unload_drain;
                        },
                        else => {},
                    }
                },
                .wait_unload_drain => {
                    self.district_focus_override = s3_smoke_far;
                    if (std.meta.activeTag(west_state) == .idle and
                        std.meta.eql(stats, district_gpu_registry.Stats{}))
                    {
                        try self.requireStaleDistrictScene(last_scene orelse
                            return error.S3StreamingSmokeSceneMissing);
                        try self.validateS3Drained();
                        summary.unload_cycles += 1;
                        summary.peak_unload_to_drained_frames = @max(
                            summary.peak_unload_to_drained_frames,
                            summary.attempted_frames - stage_started_frame + 1,
                        );
                        last_scene = null;
                        if (summary.unload_cycles == s3_smoke_resident_cycles) break;
                        self.district_focus_override = s3_smoke_near;
                        stage_started_frame = summary.attempted_frames;
                        stage = .load_to_resident;
                    }
                },
            }

            const ticks_before = self.simulation.tickIndex();
            while (self.frame_timer.shouldTick()) {
                try self.simulateTick(true, .s3_streaming);
                self.frame_timer.recordCompletedTick();
                // Below-rate presentation may run two fixed ticks in one
                // frame. Arm the intended first-load cancellation at the
                // completed-tick boundary before a second tick can activate
                // the logical worker completion.
                if (stage == .cancel_first_load) switch (self.district_stream_slots[district_west_slot_index].state) {
                    .loading => |loading| {
                        last_scene = loading.scene;
                        self.district_focus_override = s3_smoke_far;
                        self.district_stream_slots[district_west_slot_index]
                            .proximity.inside = false;
                        try self.requestDistrictDeparture(district_west_slot_index);
                        stage_started_frame = summary.attempted_frames;
                        stage = .wait_cancel_drain;
                    },
                    else => {},
                };
            }
            const ticks_this_frame = self.simulation.tickIndex() - ticks_before;
            if (ticks_this_frame == 0) summary.zero_tick_frames += 1;
            if (ticks_this_frame > 1) summary.multi_tick_frames += 1;

            stats = try self.district_registry.stats();
            updateS3SmokePeaks(&summary, stats);
            switch (try self.render(self.frame_timer.alpha())) {
                .ready => {},
                .unavailable => return error.S3StreamingSmokeUnavailableFrame,
            }
            summary.attempted_frames += 1;
            stats = try self.district_registry.stats();
            updateS3SmokePeaks(&summary, stats);
            switch (self.district_stream_slots[district_west_slot_index].state) {
                .active => |active| switch (try self.district_registry.residency(active.scene)) {
                    .resident => summary.resident_frames += 1,
                    .reserved, .staged, .submitted => summary.fallback_frames += 1,
                    .free, .retiring => return error.S3StreamingSmokeResidencyMismatch,
                },
                else => {},
            }
            c.SDL_DelayPrecise(@as(u64, std.time.ns_per_s) / config.virtual_render_hz);
        }

        summary.ticks = self.simulation.tickIndex();
        if (summary.cancelled_loads != 1 or
            summary.resident_cycles != s3_smoke_resident_cycles or
            summary.unload_cycles != s3_smoke_resident_cycles or
            summary.cancel_to_drained_frames == 0 or
            summary.peak_load_to_resident_frames == 0 or
            summary.peak_unload_to_drained_frames == 0 or
            summary.resident_frames == 0 or
            summary.peak_live_scenes != 1 or
            summary.peak_active_batches != 1 or
            summary.peak_staged_cpu_bytes != 344 or
            summary.peak_staged_upload_bytes != 116 or
            summary.peak_in_flight_upload_bytes != 116 or
            summary.peak_resident_gpu_bytes != 116 or
            (config.virtual_render_hz > timing.TICK_RATE and summary.zero_tick_frames == 0) or
            (config.virtual_render_hz < timing.TICK_RATE and summary.multi_tick_frames == 0))
        {
            return error.S3StreamingSmokeEvidenceMissing;
        }
        try self.validateS3Drained();
        try self.validateS3DrainedDeveloperSnapshot();
        summary.diagnostic_drained_snapshot = true;
        const worker = self.district_content_worker orelse
            return error.DistrictContentWorkerMissing;
        const last_generation = self.district_next_content_generation - 1;
        if (last_generation != 0) {
            switch (worker.poll(last_generation)) {
                .idle => {},
                else => return error.S3StreamingSmokeWorkerNotIdle,
            }
        }
        const diagnostic_evidence = try validateDistrictStreamDiagnostics(
            self.simulation.diagnosticJournal(),
        );
        summary.diagnostic_correlations = diagnostic_evidence.correlations;
        summary.diagnostic_entries = diagnostic_evidence.entries;
        return summary;
    }

    fn districtSlotResident(self: *App, slot_index: usize) !bool {
        const active = switch (self.district_stream_slots[slot_index].state) {
            .active => |value| value,
            else => return false,
        };
        return (try self.district_registry.residency(active.scene)) == .resident;
    }

    fn districtSlotIdle(self: *const App, slot_index: usize) bool {
        const slot = self.district_stream_slots[slot_index];
        return std.meta.activeTag(slot.state) == .idle and
            slot.presentation.stateTag() == .idle and
            slot.pending_scene == null;
    }

    fn validateS6SingleResident(self: *App, slot_index: usize) !void {
        const slot = self.district_stream_slots[slot_index];
        const active = switch (slot.state) {
            .active => |value| value,
            else => return error.S6StreamingSmokeDistrictNotActive,
        };
        if (!try self.districtSlotResident(slot_index) or
            self.simulation.districtCount() != 1 or
            self.simulation.districtBodyCount() != 3 or
            self.simulation.entityCount() != 1 or
            self.simulation.bodyCount() != 4 or
            !std.meta.eql(
                self.simulation.activeDistrictTicketFor(slot.coord) orelse
                    return error.S6StreamingSmokeTicketMissing,
                active.ticket,
            ))
        {
            return error.S6StreamingSmokeSingleDistrictInvariant;
        }
        const draws = try self.simulation.districtPresentation();
        if (draws.len != 1 or !std.meta.eql(draws[0].ticket, active.ticket)) {
            return error.S6StreamingSmokeSinglePresentationInvariant;
        }
        const stats = try self.district_registry.stats();
        if (stats.live_scenes != 1 or stats.resident_scenes != 1 or
            stats.resident_gpu_bytes != 116)
        {
            return error.S6StreamingSmokeSingleGpuInvariant;
        }
    }

    fn validateS6Overlap(self: *App) !void {
        if (!try self.districtSlotResident(district_west_slot_index) or
            !try self.districtSlotResident(district_east_slot_index) or
            self.simulation.districtCount() != 2 or
            self.simulation.districtBodyCount() != 6 or
            self.simulation.entityCount() != 2 or
            self.simulation.bodyCount() != 7)
        {
            return error.S6StreamingSmokeOverlapLogicalInvariant;
        }
        const draws = try self.simulation.districtPresentation();
        if (draws.len != 2 or
            draws[0].build.coord.x != district_west_coord.x or
            draws[0].build.coord.z != district_west_coord.z or
            draws[1].build.coord.x != district_east_coord.x or
            draws[1].build.coord.z != district_east_coord.z)
        {
            return error.S6StreamingSmokeOverlapPresentationInvariant;
        }
        for (draws) |draw| {
            const slot_index = self.districtSlotIndexForCoord(draw.build.coord) orelse
                return error.S6StreamingSmokeOverlapPresentationInvariant;
            const active = switch (self.district_stream_slots[slot_index].state) {
                .active => |value| value,
                else => return error.S6StreamingSmokeDistrictNotActive,
            };
            if (!std.meta.eql(active.ticket, draw.ticket)) {
                return error.S6StreamingSmokeOverlapPresentationInvariant;
            }
            const resident = try self.district_stream_slots[slot_index].presentation.resolve(
                draw.ticket,
                draw.assets.scene,
            );
            if (resident.meshes().len != 1 or resident.materials().len != 1 or
                resident.instances().len != 2)
            {
                return error.S6StreamingSmokeAuthoredSceneInvariant;
            }
        }
        const stats = try self.district_registry.stats();
        if (stats.live_scenes != 2 or stats.resident_scenes != 2 or
            stats.resident_gpu_bytes != 232)
        {
            return error.S6StreamingSmokeOverlapGpuInvariant;
        }
    }

    fn validateS6OverlapDeveloperSnapshot(self: *App) !void {
        const snapshot = try self.developerSnapshot();
        const worker = snapshot.content_worker orelse
            return error.S6StreamingSmokeDiagnosticWorkerMissing;
        const streams = snapshot.district_streams orelse
            return error.S6StreamingSmokeDiagnosticStreamsMissing;
        const gpu = snapshot.gpu orelse
            return error.S6StreamingSmokeDiagnosticGpuMissing;
        const aggregates = streams.aggregates;
        if (worker.stage != .idle or worker.generation != 0 or
            aggregates.desired_count != 2 or
            aggregates.transitioning_count != 0 or
            aggregates.active_count != 2 or
            aggregates.draining_count != 0 or
            aggregates.pending_decoded_scene_count != 0 or
            aggregates.scene_count != 2)
        {
            return error.S6StreamingSmokeOverlapDiagnosticAggregateMismatch;
        }

        for (streams.slots, 0..) |stream, slot_index| {
            const slot = self.district_stream_slots[slot_index];
            const active = switch (slot.state) {
                .active => |value| value,
                else => return error.S6StreamingSmokeDistrictNotActive,
            };
            if (stream.coord.x != slot.coord.x or stream.coord.z != slot.coord.z or
                stream.state != .active or !stream.desired_inside or
                stream.generations.content != active.content_generation or
                stream.generations.logical != active.ticket.generation or
                stream.correlation_id != slot.correlation or
                !std.meta.eql(
                    stream.scene orelse
                        return error.S6StreamingSmokeDiagnosticSceneMissing,
                    active.scene,
                ) or
                stream.pending_decoded_scene)
            {
                return error.S6StreamingSmokeOverlapDiagnosticSlotMismatch;
            }
        }
        if (streams.slots[0].correlation_id == streams.slots[1].correlation_id or
            gpu.current.live_scenes != 2 or
            gpu.current.reserved_scenes != 0 or
            gpu.current.staged_scenes != 0 or
            gpu.current.submitted_scenes != 0 or
            gpu.current.retiring_scenes != 0 or
            gpu.current.resident_scenes != 2 or
            gpu.current.active_batches != 0 or
            gpu.current.staged_cpu_bytes != 0 or
            gpu.current.staged_upload_bytes != 0 or
            gpu.current.in_flight_upload_bytes != 0 or
            gpu.current.resident_gpu_bytes != 232 or
            gpu.high_water.live_scenes < 2 or
            gpu.high_water.resident_scenes < 2 or
            gpu.high_water.active_batches < 1 or
            gpu.high_water.staged_cpu_bytes < 344 or
            gpu.high_water.in_flight_upload_bytes < 116 or
            gpu.high_water.resident_gpu_bytes < 232)
        {
            return error.S6StreamingSmokeOverlapDiagnosticGpuMismatch;
        }
    }

    fn validateS6DrainedDeveloperSnapshot(self: *App) !void {
        const snapshot = try self.developerSnapshot();
        const worker = snapshot.content_worker orelse
            return error.S6StreamingSmokeDiagnosticWorkerMissing;
        const streams = snapshot.district_streams orelse
            return error.S6StreamingSmokeDiagnosticStreamsMissing;
        const gpu = snapshot.gpu orelse
            return error.S6StreamingSmokeDiagnosticGpuMissing;
        if (worker.stage != .idle or worker.generation != 0 or
            !std.meta.eql(
                streams.aggregates,
                developer_diagnostics.DistrictStreamAggregates{},
            ) or
            !std.meta.eql(gpu.current, developer_diagnostics.GpuUsage{}))
        {
            return error.S6StreamingSmokeDrainedDiagnosticAggregateMismatch;
        }
        for (streams.slots, 0..) |stream, slot_index| {
            const slot = self.district_stream_slots[slot_index];
            if (stream.coord.x != slot.coord.x or stream.coord.z != slot.coord.z or
                stream.state != .idle or stream.desired_inside or
                stream.generations.content != null or
                stream.generations.logical != null or
                stream.correlation_id != null or stream.scene != null or
                stream.pending_decoded_scene)
            {
                return error.S6StreamingSmokeDrainedDiagnosticSlotMismatch;
            }
        }
        if (gpu.high_water.live_scenes < 2 or
            gpu.high_water.resident_scenes < 2 or
            gpu.high_water.active_batches < 1 or
            gpu.high_water.staged_cpu_bytes < 344 or
            gpu.high_water.in_flight_upload_bytes < 116 or
            gpu.high_water.resident_gpu_bytes < 232)
        {
            return error.S6StreamingSmokeDrainedDiagnosticGpuMismatch;
        }
    }

    fn runS6StreamingSmoke(
        self: *App,
        config: VisualSmokeConfig,
    ) !S6StreamingSmokeSummary {
        if (self.validation.profile != .s3_smoke) return error.InvalidS6SmokeProfile;
        var summary = S6StreamingSmokeSummary{};
        var stage: S6SmokeStage = .west_resident;
        self.district_focus_override = s6_west_only;

        while (summary.attempted_frames < config.frames) {
            self.input_buffer.beginFrame();
            if (!self.input_buffer.pumpEvents(self.developer_editor.eventSink())) {
                return error.S6StreamingSmokeInterrupted;
            }
            if (self.waitForWindowSuspension()) continue;
            try self.frame_timer.beginFrameWithElapsedSeconds(
                1.0 / @as(f64, @floatFromInt(config.virtual_render_hz)),
            );
            try self.pumpDistrictContent();
            const ticks_before = self.simulation.tickIndex();
            while (self.frame_timer.shouldTick()) {
                try self.simulateTick(true, .s3_streaming);
                self.frame_timer.recordCompletedTick();
            }
            const ticks_this_frame = self.simulation.tickIndex() - ticks_before;
            if (ticks_this_frame == 0) summary.zero_tick_frames += 1;
            if (ticks_this_frame > 1) summary.multi_tick_frames += 1;
            summary.observe(try self.district_registry.stats());
            switch (try self.render(self.frame_timer.alpha())) {
                .ready => {},
                .unavailable => return error.S6StreamingSmokeUnavailableFrame,
            }
            summary.attempted_frames += 1;
            summary.observe(try self.district_registry.stats());

            switch (stage) {
                .west_resident => if (try self.districtSlotResident(
                    district_west_slot_index,
                ) and self.districtSlotIdle(district_east_slot_index)) {
                    try self.validateS6SingleResident(district_west_slot_index);
                    self.district_focus_override = s6_overlap;
                    stage = .forward_overlap;
                },
                .forward_overlap => if (try self.districtSlotResident(
                    district_west_slot_index,
                ) and try self.districtSlotResident(district_east_slot_index)) {
                    try self.validateS6Overlap();
                    try self.validateS6OverlapDeveloperSnapshot();
                    summary.forward_overlaps += 1;
                    self.district_focus_override = s6_east_only;
                    stage = .east_resident;
                },
                .east_resident => if (self.districtSlotIdle(district_west_slot_index) and
                    try self.districtSlotResident(district_east_slot_index))
                {
                    try self.validateS6SingleResident(district_east_slot_index);
                    self.district_focus_override = s6_overlap;
                    stage = .reverse_overlap;
                },
                .reverse_overlap => if (try self.districtSlotResident(
                    district_west_slot_index,
                ) and try self.districtSlotResident(district_east_slot_index)) {
                    try self.validateS6Overlap();
                    try self.validateS6OverlapDeveloperSnapshot();
                    summary.reverse_overlaps += 1;
                    self.district_focus_override = s6_west_only;
                    stage = .west_cycle_resident;
                },
                .west_cycle_resident => if (try self.districtSlotResident(
                    district_west_slot_index,
                ) and self.districtSlotIdle(district_east_slot_index)) {
                    try self.validateS6SingleResident(district_west_slot_index);
                    summary.overlap_cycles += 1;
                    if (summary.overlap_cycles == s6_required_overlap_cycles) {
                        self.district_focus_override = s6_fully_outside;
                        stage = .final_drain;
                    } else {
                        self.district_focus_override = s6_overlap;
                        stage = .forward_overlap;
                    }
                },
                .final_drain => if (self.districtSlotIdle(district_west_slot_index) and
                    self.districtSlotIdle(district_east_slot_index) and
                    std.meta.eql(
                        try self.district_registry.stats(),
                        district_gpu_registry.Stats{},
                    ))
                {
                    break;
                },
            }
            c.SDL_DelayPrecise(@as(u64, std.time.ns_per_s) / config.virtual_render_hz);
        }

        summary.ticks = self.simulation.tickIndex();
        if (stage != .final_drain or
            !self.districtSlotIdle(district_west_slot_index) or
            !self.districtSlotIdle(district_east_slot_index) or
            self.district_content_owner != null or
            self.simulation.districtCount() != 0 or
            self.simulation.districtBodyCount() != 0 or
            self.simulation.entityCount() != 0 or
            self.simulation.bodyCount() != 1 or
            !std.meta.eql(
                try self.district_registry.stats(),
                district_gpu_registry.Stats{},
            ))
        {
            return error.S6StreamingSmokeDidNotDrain;
        }
        try self.validateS6DrainedDeveloperSnapshot();
        const worker = self.district_content_worker orelse
            return error.DistrictContentWorkerMissing;
        if (worker.diagnostics().state != .idle or
            summary.overlap_cycles != s6_required_overlap_cycles or
            summary.forward_overlaps != s6_required_overlap_cycles or
            summary.reverse_overlaps != s6_required_overlap_cycles or
            summary.peak_live_scenes != 2 or
            summary.peak_resident_scenes != 2 or
            summary.peak_staged_cpu_bytes != 344 or
            summary.peak_staged_upload_bytes != 116 or
            summary.peak_in_flight_upload_bytes == 0 or
            summary.peak_in_flight_upload_bytes > 232 or
            summary.peak_in_flight_upload_bytes % 116 != 0 or
            summary.peak_resident_gpu_bytes != 232 or
            summary.peak_active_batches == 0 or summary.peak_active_batches > 2 or
            (config.virtual_render_hz > timing.TICK_RATE and
                (summary.zero_tick_frames == 0 or summary.multi_tick_frames != 0)) or
            (config.virtual_render_hz < timing.TICK_RATE and
                (summary.multi_tick_frames == 0 or summary.zero_tick_frames != 0)))
        {
            return error.S6StreamingSmokeEvidenceMissing;
        }
        return summary;
    }

    /// Consume every NPC output at each completed-tick boundary. This keeps
    /// the 64-wide smoke well below its bounded output capacities while also
    /// requiring exact per-request and per-identity lifecycle evidence.
    fn processS8NpcOutputs(
        self: *App,
        summary: *S8PopulationSmokeSummary,
        evidence: *S8PopulationEvidence,
        stage: S8SmokeStage,
    ) !void {
        while (self.simulation.pollNpcOutcome()) |outcome| {
            try evidence.observeOutcome(stage, summary, outcome);
        }
        while (self.simulation.pollNpcEvent()) |event| {
            try evidence.observeEvent(stage, summary, event);
        }
    }

    fn requireS8NpcViews(
        self: *App,
        ids: *const [s8_population_count]?sandbox_host.PersistentId,
        owner: sandbox_host.ChunkCoord,
        state: sandbox_host.NpcState,
        controller_present: bool,
    ) !void {
        for (ids) |optional_id| {
            const view = try self.simulation.npc(optional_id orelse
                return error.S8PopulationIdentityMissing);
            if (!std.meta.eql(view.owner, owner) or view.state != state or
                view.controller_present != controller_present)
            {
                return error.S8PopulationViewMismatch;
            }
        }
    }

    fn s8SimulationQueuesEmpty(diagnostics: sandbox_host.Diagnostics) bool {
        return diagnostics.crates.commands.occupancy == 0 and
            diagnostics.crates.outcomes.occupancy == 0 and
            diagnostics.characters.commands.occupancy == 0 and
            diagnostics.characters.outcomes.occupancy == 0 and
            diagnostics.characters.events.occupancy == 0 and
            diagnostics.vehicles.commands.occupancy == 0 and
            diagnostics.vehicles.outcomes.occupancy == 0 and
            diagnostics.vehicles.events.occupancy == 0 and
            diagnostics.district.commands.occupancy == 0 and
            diagnostics.district.outcomes.occupancy == 0 and
            diagnostics.district.events.occupancy == 0 and
            diagnostics.interaction.commands.occupancy == 0 and
            diagnostics.interaction.outcomes.occupancy == 0 and
            diagnostics.npc.commands.occupancy == 0 and
            diagnostics.npc.outcomes.occupancy == 0 and
            diagnostics.npc.events.occupancy == 0;
    }

    /// Installed macOS/Metal population proof. Normal gameplay never invokes
    /// this planner: population remains an explicit host capability selected
    /// only by `--s8-population-smoke`.
    fn runS8PopulationSmoke(
        self: *App,
        config: VisualSmokeConfig,
    ) !S8PopulationSmokeSummary {
        if (self.validation.profile != .s3_smoke) return error.InvalidS8SmokeProfile;
        var summary = S8PopulationSmokeSummary{};
        var stage: S8SmokeStage = .overlap_resident;
        var evidence = S8PopulationEvidence{};
        self.district_focus_override = s6_overlap;

        smoke_loop: while (summary.attempted_frames < config.frames) {
            self.input_buffer.beginFrame();
            if (!self.input_buffer.pumpEvents(self.developer_editor.eventSink())) {
                return error.S8PopulationSmokeInterrupted;
            }
            if (self.waitForWindowSuspension()) continue;
            try self.frame_timer.beginFrameWithElapsedSeconds(
                1.0 / @as(f64, @floatFromInt(config.virtual_render_hz)),
            );
            try self.pumpDistrictContent();
            summary.observeGpu(try self.district_registry.stats());

            const ticks_before = self.simulation.tickIndex();
            while (self.frame_timer.shouldTick()) {
                try self.simulateTick(true, .s3_streaming);
                try self.processS8NpcOutputs(&summary, &evidence, stage);
                self.frame_timer.recordCompletedTick();
            }
            const ticks_this_frame = self.simulation.tickIndex() - ticks_before;
            if (ticks_this_frame == 0) summary.zero_tick_frames += 1;
            if (ticks_this_frame > 1) summary.multi_tick_frames += 1;

            const simulation_diagnostics = self.simulation.diagnostics();
            const diagnostics = simulation_diagnostics.npc;
            try summary.observeNpc(
                diagnostics,
                simulation_diagnostics.character_controllers,
            );
            const presentation = switch (try self.render(self.frame_timer.alpha())) {
                .ready => |value| value,
                .unavailable => return error.S8PopulationSmokeUnavailableFrame,
            };
            summary.attempted_frames += 1;
            summary.observeGpu(try self.district_registry.stats());
            if (presentation.npc_count != 0 and
                presentation.npc_count != s8_population_count)
            {
                return error.S8PopulationDrawCountMismatch;
            }
            if (presentation.npc_count == s8_population_count) {
                summary.npc_draw_frames += 1;
                summary.peak_npc_draws = @intCast(presentation.npc_count);
            }

            switch (stage) {
                .overlap_resident => if (try self.districtSlotResident(
                    district_west_slot_index,
                ) and try self.districtSlotResident(district_east_slot_index)) {
                    if (presentation.district_count != 2 or presentation.npc_count != 0) {
                        return error.S8PopulationInitialPresentationMismatch;
                    }
                    try self.validateS6Overlap();
                    try self.validateS6OverlapDeveloperSnapshot();
                    summary.two_resident_scenes = true;
                    const batch = try population.plan(s8_population_count, .{
                        .first_request_id = s8_spawn_first_request_id,
                        .start_node = s8_west_seam,
                        .goal = .{ .patrol_between = .{
                            .first = s8_west_seam,
                            .second = s8_east_end,
                        } },
                    });
                    for (batch.slice()) |command| try self.simulation.submitNpc(command);
                    summary.planned = @intCast(batch.slice().len);
                    stage = .population_spawned;
                },
                .population_spawned => if (evidence.spawnedComplete()) {
                    if (self.simulation.npcCount() != s8_population_count or
                        summary.spawned != s8_population_count or
                        diagnostics.active_count != s8_population_count or
                        diagnostics.controller_count != s8_population_count or
                        presentation.npc_count != s8_population_count)
                    {
                        return error.S8PopulationSpawnMismatch;
                    }
                    try self.requireS8NpcViews(
                        &evidence.identities,
                        district_west_coord,
                        .active,
                        true,
                    );
                    self.district_focus_override = s6_west_only;
                    stage = .destination_waiting;
                },
                .destination_waiting => if (self.districtSlotIdle(
                    district_east_slot_index,
                ) and evidence.waitingComplete()) {
                    if (!try self.districtSlotResident(district_west_slot_index) or
                        diagnostics.waiting_count != s8_population_count or
                        diagnostics.controller_count != s8_population_count or
                        summary.waiting_events != s8_population_count or
                        presentation.npc_count != s8_population_count)
                    {
                        return error.S8PopulationWaitingMismatch;
                    }
                    try self.requireS8NpcViews(
                        &evidence.identities,
                        district_west_coord,
                        .waiting_at_boundary,
                        true,
                    );
                    self.district_focus_override = s6_overlap;
                    stage = .destination_reloaded;
                },
                .destination_reloaded => if (evidence.waitingResumeComplete()) {
                    if (summary.waiting_resume_events != s8_population_count or
                        diagnostics.active_count != s8_population_count or
                        diagnostics.controller_count != s8_population_count or
                        presentation.npc_count != s8_population_count)
                    {
                        return error.S8PopulationWaitingResumeMismatch;
                    }
                    stage = .crossed_east;
                },
                .crossed_east => if (evidence.transferComplete() and
                    try self.districtSlotResident(district_west_slot_index) and
                    try self.districtSlotResident(district_east_slot_index))
                {
                    if (summary.transfer_events != s8_population_count or
                        diagnostics.transfers != s8_population_count or
                        diagnostics.active_count != s8_population_count or
                        diagnostics.controller_count != s8_population_count or
                        presentation.npc_count != s8_population_count)
                    {
                        return error.S8PopulationTransferMismatch;
                    }
                    try self.requireS8NpcViews(
                        &evidence.identities,
                        district_east_coord,
                        .active,
                        true,
                    );
                    self.district_focus_override = s6_west_only;
                    stage = .owner_dormant;
                },
                .owner_dormant => if (self.districtSlotIdle(
                    district_east_slot_index,
                ) and evidence.dormantComplete()) {
                    if (summary.dormant_events != s8_population_count or
                        diagnostics.dormant_count != s8_population_count or
                        diagnostics.controller_count != 0 or
                        diagnostics.controllers_suspended != s8_population_count or
                        presentation.npc_count != 0)
                    {
                        return error.S8PopulationDormantMismatch;
                    }
                    try self.requireS8NpcViews(
                        &evidence.identities,
                        district_east_coord,
                        .dormant,
                        false,
                    );
                    self.district_focus_override = s6_overlap;
                    stage = .owner_resumed;
                },
                .owner_resumed => if (try self.districtSlotResident(
                    district_west_slot_index,
                ) and try self.districtSlotResident(district_east_slot_index) and
                    evidence.controllerResumeComplete())
                {
                    if (summary.controller_resume_events != s8_population_count or
                        diagnostics.active_count != s8_population_count or
                        diagnostics.controller_count != s8_population_count or
                        diagnostics.controllers_resumed != s8_population_count or
                        presentation.npc_count != s8_population_count)
                    {
                        return error.S8PopulationControllerResumeMismatch;
                    }
                    try self.requireS8NpcViews(
                        &evidence.identities,
                        district_east_coord,
                        .active,
                        true,
                    );
                    for (evidence.identities, 0..) |optional_id, index| {
                        try self.simulation.submitNpc(.{ .despawn = .{
                            .request_id = s8_despawn_first_request_id + index,
                            .id = optional_id orelse
                                return error.S8PopulationIdentityMissing,
                        } });
                    }
                    stage = .population_despawned;
                },
                .population_despawned => if (evidence.despawnedComplete()) {
                    if (self.simulation.npcCount() != 0 or
                        summary.despawned != s8_population_count or
                        diagnostics.active_count != 0 or
                        diagnostics.waiting_count != 0 or
                        diagnostics.dormant_count != 0 or
                        diagnostics.controller_count != 0 or
                        presentation.npc_count != 0)
                    {
                        return error.S8PopulationDespawnMismatch;
                    }
                    self.district_focus_override = s6_fully_outside;
                    stage = .final_drain;
                },
                .final_drain => if (self.districtSlotIdle(district_west_slot_index) and
                    self.districtSlotIdle(district_east_slot_index) and
                    std.meta.eql(
                        try self.district_registry.stats(),
                        district_gpu_registry.Stats{},
                    ))
                {
                    if (presentation.npc_count != 0 or
                        presentation.district_count != 0)
                    {
                        return error.S8PopulationFinalDrawMismatch;
                    }
                    break :smoke_loop;
                },
            }
            c.SDL_DelayPrecise(@as(u64, std.time.ns_per_s) / config.virtual_render_hz);
        }

        // Staging can be submitted within one render call. Fold the registry's
        // retained high-water sample into the smoke summary so the proof is
        // cadence-independent rather than relying on catching an ephemeral
        // staged state between host pumps.
        summary.observeGpu((try self.district_registry.diagnostics()).high_water);
        try evidence.requireComplete();
        summary.ticks = self.simulation.tickIndex();
        const final_diagnostics = self.simulation.diagnostics();
        summary.final_entities = final_diagnostics.entity_count;
        summary.final_bodies = final_diagnostics.body_count;
        summary.final_native_controllers =
            final_diagnostics.character_controllers.native_used;
        summary.final_draws = @intCast((try self.simulation.npcPresentation(0)).len);
        const worker = self.district_content_worker orelse
            return error.DistrictContentWorkerMissing;
        if (stage != .final_drain or self.district_content_owner != null or
            worker.diagnostics().state != .idle or
            !self.districtSlotIdle(district_west_slot_index) or
            !self.districtSlotIdle(district_east_slot_index) or
            self.simulation.npcCount() != 0 or
            self.simulation.districtCount() != 0 or
            self.simulation.districtBodyCount() != 0 or
            !s8SimulationQueuesEmpty(final_diagnostics) or
            !std.meta.eql(
                try self.district_registry.stats(),
                district_gpu_registry.Stats{},
            ))
        {
            return error.S8PopulationSmokeDidNotDrain;
        }
        try self.validateS6DrainedDeveloperSnapshot();
        try summary.validate(
            config,
            final_diagnostics.npc,
            final_diagnostics.character_controllers,
        );
        return summary;
    }

    fn requireS7Counts(
        self: *App,
        districts: usize,
        district_bodies: usize,
        characters: usize,
        carryables: usize,
        entities: usize,
        bodies: usize,
    ) !void {
        if (self.simulation.districtCount() != districts or
            self.simulation.districtBodyCount() != district_bodies or
            self.simulation.characterCount() != characters or
            self.simulation.interactionCount() != carryables or
            self.simulation.entityCount() != entities or
            self.simulation.bodyCount() != bodies)
        {
            return error.S7InteractionSmokeCompositionMismatch;
        }
    }

    /// Installed visual-host proof of the complete first interaction slice.
    /// The state machine drives only public semantic commands and host-owned
    /// district focus; every observation comes back through immutable views,
    /// presentation extraction, diagnostics, and centralized outcome polling.
    fn runS7InteractionSmoke(
        self: *App,
        config: VisualSmokeConfig,
    ) !S7InteractionSmokeSummary {
        if (self.validation.profile != .s3_smoke) return error.InvalidS7SmokeProfile;
        var summary = S7InteractionSmokeSummary{};
        var stage: S7SmokeStage = .west_resident;

        while (summary.attempted_frames < config.frames) {
            self.input_buffer.beginFrame();
            if (!self.input_buffer.pumpEvents(self.developer_editor.eventSink())) {
                return error.S7InteractionSmokeInterrupted;
            }
            if (self.waitForWindowSuspension()) continue;
            try self.frame_timer.beginFrameWithElapsedSeconds(
                1.0 / @as(f64, @floatFromInt(config.virtual_render_hz)),
            );
            try self.pumpDistrictContent();
            const ticks_before = self.simulation.tickIndex();
            while (self.frame_timer.shouldTick()) {
                try self.simulateTick(true, .s7_interaction);
                self.frame_timer.recordCompletedTick();
            }
            const ticks_this_frame = self.simulation.tickIndex() - ticks_before;
            if (ticks_this_frame == 0) summary.zero_tick_frames += 1;
            if (ticks_this_frame > 1) summary.multi_tick_frames += 1;

            const presentation = switch (try self.render(self.frame_timer.alpha())) {
                .ready => |value| value,
                .unavailable => return error.S7InteractionSmokeUnavailableFrame,
            };
            summary.attempted_frames += 1;
            if (presentation.district_count > 0) summary.district_draw_frames += 1;
            if (presentation.carryable_count > 1) {
                return error.S7InteractionSmokeCarryableDrawCountMismatch;
            }
            if (presentation.carryable_count == 1) {
                const id = presentation.carryable_id orelse
                    return error.S7InteractionSmokeCarryableDrawMissingIdentity;
                if (!std.meta.eql(id, self.initial_carryable_id orelse
                    return error.S7InteractionSmokeUnexpectedCarryableDraw))
                {
                    return error.S7InteractionSmokeUnexpectedCarryableDraw;
                }
                summary.carryable_draw_frames += 1;
                const view = try self.simulation.carryable(id);
                switch (view.ownership) {
                    .district_owned => {},
                    .inventory_held => summary.held_draw_frames += 1,
                }
            } else if (presentation.carryable_id != null) {
                return error.S7InteractionSmokeCarryableDrawCountMismatch;
            }

            switch (stage) {
                .west_resident => if (try self.districtSlotResident(
                    district_west_slot_index,
                ) and self.districtSlotIdle(district_east_slot_index) and
                    self.initial_character_id != null)
                {
                    stage = .carryable_spawned;
                },
                .carryable_spawned => if (self.initial_carryable_id) |id| {
                    const view = try self.simulation.carryable(id);
                    switch (view.ownership) {
                        .district_owned => |owner| {
                            if (!std.meta.eql(owner, district_west_coord) or
                                !view.body_present or
                                presentation.carryable_count != 1 or
                                std.meta.activeTag(self.interaction_last_outcome orelse
                                    return error.S7InteractionSmokeSpawnOutcomeMissing) != .spawned)
                            {
                                return error.S7InteractionSmokeSpawnInvariant;
                            }
                            try self.requireS7Counts(1, 3, 1, 1, 3, 5);
                            const diagnostics = self.simulation.diagnostics().interaction;
                            if (diagnostics.active_count != 1 or
                                diagnostics.district_owned_count != 1 or
                                diagnostics.held_count != 0 or
                                diagnostics.dynamic_body_count != 1 or
                                diagnostics.dormant_count != 0)
                            {
                                return error.S7InteractionSmokeSpawnDiagnosticsMismatch;
                            }
                            try self.submitInteractionToggle();
                            stage = .collected;
                        },
                        .inventory_held => return error.S7InteractionSmokeCollectedTooEarly,
                    }
                },
                .collected => {
                    const id = self.initial_carryable_id orelse
                        return error.S7InteractionSmokeCarryableMissing;
                    const view = try self.simulation.carryable(id);
                    switch (view.ownership) {
                        .district_owned => {},
                        .inventory_held => |holder| {
                            if (!std.meta.eql(holder, self.initial_character_id orelse
                                return error.S7InteractionSmokeCarrierMissing) or
                                view.body_present or presentation.carryable_count != 1 or
                                std.meta.activeTag(self.interaction_last_outcome orelse
                                    return error.S7InteractionSmokeCollectOutcomeMissing) != .collected)
                            {
                                return error.S7InteractionSmokeCollectInvariant;
                            }
                            try self.requireS7Counts(1, 3, 1, 1, 3, 4);
                            const diagnostics = self.simulation.diagnostics().interaction;
                            if (diagnostics.held_count != 1 or
                                diagnostics.dynamic_body_count != 0 or
                                diagnostics.dormant_count != 0)
                            {
                                return error.S7InteractionSmokeCollectDiagnosticsMismatch;
                            }
                            summary.collected = true;
                            self.district_focus_override = s6_east_only;
                            self.validation.s7_scripted_move = .{ 1, 0 };
                            stage = .crossed_east;
                        },
                    }
                },
                .crossed_east => {
                    const id = self.initial_carryable_id orelse
                        return error.S7InteractionSmokeCarryableMissing;
                    const view = try self.simulation.carryable(id);
                    switch (view.ownership) {
                        .district_owned => return error.S7InteractionSmokeOwnershipRegressed,
                        .inventory_held => {},
                    }
                    if (self.districtSlotIdle(district_west_slot_index)) {
                        summary.source_unloaded_while_held = true;
                    }
                    const character = try self.simulation.character(
                        self.initial_character_id orelse
                            return error.S7InteractionSmokeCarrierMissing,
                    );
                    if (character.position[0] >= 8.25) self.validation.s7_scripted_move = .{ 0, 0 };
                    if (character.position[0] >= 8.25 and
                        self.districtSlotIdle(district_west_slot_index) and
                        try self.districtSlotResident(district_east_slot_index))
                    {
                        try self.requireS7Counts(1, 3, 1, 1, 3, 4);
                        summary.crossed_east = true;
                        try self.submitInteractionToggle();
                        stage = .dropped;
                    }
                },
                .dropped => {
                    const id = self.initial_carryable_id orelse
                        return error.S7InteractionSmokeCarryableMissing;
                    const view = try self.simulation.carryable(id);
                    switch (view.ownership) {
                        .inventory_held => {},
                        .district_owned => |owner| {
                            if (!std.meta.eql(owner, district_east_coord) or
                                !view.body_present or presentation.carryable_count != 1 or
                                std.meta.activeTag(self.interaction_last_outcome orelse
                                    return error.S7InteractionSmokeDropOutcomeMissing) != .dropped)
                            {
                                return error.S7InteractionSmokeDropInvariant;
                            }
                            try self.requireS7Counts(1, 3, 1, 1, 3, 5);
                            summary.dropped_east = true;
                            self.district_focus_override = s6_fully_outside;
                            stage = .east_unloaded;
                        },
                    }
                },
                .east_unloaded => if (self.districtSlotIdle(district_west_slot_index) and
                    self.districtSlotIdle(district_east_slot_index))
                {
                    const id = self.initial_carryable_id orelse
                        return error.S7InteractionSmokeCarryableMissing;
                    const view = try self.simulation.carryable(id);
                    if (view.body_present or presentation.carryable_count != 0) {
                        return error.S7InteractionSmokeDormantDrawInvariant;
                    }
                    try self.requireS7Counts(0, 0, 1, 1, 2, 1);
                    const diagnostics = self.simulation.diagnostics().interaction;
                    if (diagnostics.dormant_count != 1 or
                        diagnostics.dynamic_body_count != 0 or
                        diagnostics.bodies_suspended == 0)
                    {
                        return error.S7InteractionSmokeDormantDiagnosticsMismatch;
                    }
                    summary.dormant_after_unload = true;
                    self.district_focus_override = s6_east_only;
                    stage = .east_reloaded;
                },
                .east_reloaded => if (self.districtSlotIdle(district_west_slot_index) and
                    try self.districtSlotResident(district_east_slot_index))
                {
                    const id = self.initial_carryable_id orelse
                        return error.S7InteractionSmokeCarryableMissing;
                    const view = try self.simulation.carryable(id);
                    if (!view.body_present or presentation.carryable_count != 1) {
                        return error.S7InteractionSmokeReloadDrawInvariant;
                    }
                    try self.requireS7Counts(1, 3, 1, 1, 3, 5);
                    const diagnostics = self.simulation.diagnostics().interaction;
                    if (diagnostics.dormant_count != 0 or
                        diagnostics.dynamic_body_count != 1 or
                        diagnostics.bodies_resumed == 0)
                    {
                        return error.S7InteractionSmokeReloadDiagnosticsMismatch;
                    }
                    summary.resumed_after_reload = true;
                    try self.simulation.submitInteraction(.{ .despawn = .{ .id = id } });
                    stage = .carryable_despawned;
                },
                .carryable_despawned => if (self.initial_carryable_id == null) {
                    if (presentation.carryable_count != 0) {
                        return error.S7InteractionSmokeCarryableCleanupDrawMismatch;
                    }
                    try self.requireS7Counts(1, 3, 1, 0, 2, 4);
                    // Stop the per-tick producer before queuing despawn. Both
                    // commands otherwise target the same next tick, and FIFO
                    // would correctly reject the trailing action after the
                    // character identity has been destroyed.
                    self.validation.s7_character_actions_enabled = false;
                    try self.simulation.submitCharacter(.{ .despawn = .{
                        .id = self.initial_character_id orelse
                            return error.S7InteractionSmokeCarrierMissing,
                    } });
                    stage = .character_despawned;
                },
                .character_despawned => if (self.initial_character_id == null) {
                    try self.requireS7Counts(1, 3, 0, 0, 1, 4);
                    self.district_focus_override = s6_fully_outside;
                    stage = .final_drain;
                },
                .final_drain => if (self.districtSlotIdle(district_west_slot_index) and
                    self.districtSlotIdle(district_east_slot_index) and
                    std.meta.eql(
                        try self.district_registry.stats(),
                        district_gpu_registry.Stats{},
                    ))
                {
                    if (presentation.carryable_count != 0 or
                        presentation.character_count != 0 or
                        presentation.district_count != 0)
                    {
                        return error.S7InteractionSmokeFinalDrawMismatch;
                    }
                    try self.requireS7Counts(0, 0, 0, 0, 0, 1);
                    break;
                },
            }
            c.SDL_DelayPrecise(@as(u64, std.time.ns_per_s) / config.virtual_render_hz);
        }

        summary.ticks = self.simulation.tickIndex();
        const final_diagnostics = self.simulation.diagnostics();
        summary.final_entities = final_diagnostics.entity_count;
        summary.final_bodies = final_diagnostics.body_count;
        const worker = self.district_content_worker orelse
            return error.DistrictContentWorkerMissing;
        if (stage != .final_drain or self.district_content_owner != null or
            worker.diagnostics().state != .idle or
            !summary.collected or !summary.crossed_east or !summary.dropped_east or
            !summary.source_unloaded_while_held or !summary.dormant_after_unload or
            !summary.resumed_after_reload or summary.carryable_draw_frames == 0 or
            summary.held_draw_frames == 0 or summary.district_draw_frames == 0 or
            summary.final_entities != 0 or summary.final_bodies != 1 or
            self.interaction_submission_failures != 0 or
            self.interaction_requests.rejected != 0 or
            (config.virtual_render_hz > timing.TICK_RATE and
                (summary.zero_tick_frames == 0 or summary.multi_tick_frames != 0)) or
            (config.virtual_render_hz < timing.TICK_RATE and
                (summary.multi_tick_frames == 0 or summary.zero_tick_frames != 0)))
        {
            return error.S7InteractionSmokeEvidenceMissing;
        }
        return summary;
    }

    fn validateS3Resident(self: *App, active: DistrictStreamBound) !void {
        if (self.simulation.districtCount() != 1 or
            self.simulation.districtBodyCount() != 3 or
            self.simulation.entityCount() != 1 or
            self.simulation.bodyCount() != 4)
        {
            return error.S3StreamingSmokeLogicalInvariant;
        }
        const draws = try self.simulation.districtPresentation();
        if (draws.len != 1) return error.S3StreamingSmokePresentationInvariant;
        const resident = try self.district_stream_slots[district_west_slot_index].presentation.resolve(
            draws[0].ticket,
            active.scene,
        );
        if (resident.meshes().len != 1 or
            resident.materials().len != 1 or
            resident.instances().len != 2)
        {
            return error.S3StreamingSmokeAuthoredSceneInvariant;
        }
        const stats = try self.district_registry.stats();
        if (stats.resident_scenes != 1 or stats.resident_gpu_bytes != 116) {
            return error.S3StreamingSmokeGpuInvariant;
        }
    }

    fn validateS3ResidentDeveloperSnapshot(self: *App) !void {
        const snapshot = try self.developerSnapshot();
        const streams = snapshot.district_streams orelse
            return error.S3StreamingSmokeDiagnosticStreamMissing;
        const stream = streams.slots[district_west_slot_index];
        const gpu = snapshot.gpu orelse
            return error.S3StreamingSmokeDiagnosticGpuMissing;
        if (stream.state != .active or !stream.desired_inside or
            gpu.current.live_scenes != 1 or gpu.current.resident_scenes != 1 or
            gpu.current.active_batches != 0 or gpu.current.resident_gpu_bytes != 116 or
            gpu.high_water.active_batches != 1)
        {
            std.debug.print(
                "S3_RESIDENT_DIAGNOSTIC_MISMATCH stream={s} desired_inside={} " ++
                    "live={d} resident={d} batches={d} bytes={d}\n",
                .{
                    @tagName(stream.state),
                    stream.desired_inside,
                    gpu.current.live_scenes,
                    gpu.current.resident_scenes,
                    gpu.current.active_batches,
                    gpu.current.resident_gpu_bytes,
                },
            );
            return error.S3StreamingSmokeResidentDiagnosticMismatch;
        }
    }

    fn validateS3Drained(self: *App) !void {
        const west = self.district_stream_slots[district_west_slot_index];
        const east = self.district_stream_slots[district_east_slot_index];
        if (std.meta.activeTag(west.state) != .idle or
            west.presentation.stateTag() != .idle or
            west.pending_scene != null or
            std.meta.activeTag(east.state) != .idle or
            east.presentation.stateTag() != .idle or
            east.pending_scene != null or
            self.simulation.districtCount() != 0 or
            self.simulation.districtBodyCount() != 0 or
            self.simulation.entityCount() != 0 or
            self.simulation.bodyCount() != 1 or
            !std.meta.eql(
                try self.district_registry.stats(),
                district_gpu_registry.Stats{},
            ))
        {
            return error.S3StreamingSmokeDrainInvariant;
        }
    }

    fn validateS3DrainedDeveloperSnapshot(self: *App) !void {
        const snapshot = try self.developerSnapshot();
        const worker = snapshot.content_worker orelse
            return error.S3StreamingSmokeDiagnosticWorkerMissing;
        const streams = snapshot.district_streams orelse
            return error.S3StreamingSmokeDiagnosticStreamMissing;
        const stream = streams.slots[district_west_slot_index];
        const gpu = snapshot.gpu orelse
            return error.S3StreamingSmokeDiagnosticGpuMissing;
        if (worker.stage != .idle or stream.state != .idle or
            stream.pending_decoded_scene or gpu.current.live_scenes != 0 or
            gpu.current.reserved_scenes != 0 or gpu.current.staged_scenes != 0 or
            gpu.current.submitted_scenes != 0 or gpu.current.retiring_scenes != 0 or
            gpu.current.resident_scenes != 0 or gpu.current.active_batches != 0 or
            gpu.current.staged_cpu_bytes != 0 or gpu.current.staged_upload_bytes != 0 or
            gpu.current.in_flight_upload_bytes != 0 or
            gpu.current.resident_gpu_bytes != 0)
        {
            return error.S3StreamingSmokeDrainedDiagnosticMismatch;
        }
    }

    fn requireStaleDistrictScene(
        self: *App,
        scene: engine.rendering.SceneHandle,
    ) !void {
        _ = self.district_registry.residency(scene) catch |err| {
            if (err == error.StaleSceneHandle) return;
            return err;
        };
        return error.S3StreamingSmokeSceneStillLive;
    }

    fn applyS5SmokeRequests(
        self: *App,
        requests: []const sandbox_authoring.Request,
    ) !void {
        self.authoring_requests.clear();
        for (requests) |request| {
            if (!self.authoring_requests.push(request)) {
                return error.S5AuthoringRequestBufferRejected;
            }
        }
        try self.applyAuthoringRequests(self.authoring_requests.slice());
        self.authoring_requests.clear();
    }

    fn renderS5SmokeFrame(self: *App, alpha: f32) !FramePresentation {
        for (0..120) |_| {
            self.input_buffer.beginFrame();
            if (!self.input_buffer.pumpEvents(self.developer_editor.eventSink())) {
                return error.S5AuthoringSmokeInterrupted;
            }
            switch (try self.render(alpha)) {
                .ready => |presentation| return presentation,
                .unavailable => c.SDL_DelayPrecise(std.time.ns_per_ms),
            }
        }
        return error.S5AuthoringRenderUnavailable;
    }

    fn toggleEditorForS5Smoke(self: *App, expected_visible: bool) !void {
        var event = std.mem.zeroes(c.SDL_Event);
        event.type = c.SDL_EVENT_KEY_DOWN;
        event.key.windowID = c.SDL_GetWindowID(self.window);
        event.key.scancode = c.SDL_SCANCODE_F1;
        event.key.repeat = false;
        const route = self.developer_editor.processEvent(&event);
        if (!route.keyboard_reserved or
            self.developer_editor.isVisible() != expected_visible)
        {
            return error.S5AuthoringEditorToggleFailed;
        }
    }

    fn runS5AuthoringSmoke(self: *App) !S5AuthoringSmokeSummary {
        if (!build_options.editor_enabled) return error.S5AuthoringEditorRequired;
        if (self.validation.profile != .s1_smoke or self.save_store == null or
            self.save_metadata == null)
        {
            return error.InvalidS5AuthoringSmokeComposition;
        }
        if (!self.developer_editor.isVisible()) {
            return error.S5AuthoringEditorNotVisible;
        }

        var summary = S5AuthoringSmokeSummary{};
        try self.simulateTick(true, .none);
        const id = self.initial_crate_id orelse return error.S5AuthoringCrateMissing;
        const initial = try self.simulation.crate(id);
        const initial_frame = try self.renderS5SmokeFrame(0.5);
        if (initial_frame.crate_count != 1 or
            !std.meta.eql(initial_frame.first_id.?, id))
        {
            return error.S5AuthoringInitialPresentationMissing;
        }
        summary.rendered_frames += 1;

        const target_pose = engine.physics.Pose{
            .position = .{ 6, 5, -2 },
            .rotation = .{ 0, 0, 0, 1 },
        };
        try self.applyS5SmokeRequests(&.{
            .{ .select = id },
            .{ .relocate = .{
                .id = id,
                .target_pose = target_pose,
                .velocity = .zero,
            } },
        });
        if (self.authoring_controller.snapshot().pending == null) {
            return error.S5AuthoringEditNotPending;
        }
        try self.simulateTick(true, .none);
        const edited = try self.simulation.crate(id);
        const edit_session = self.authoring_controller.snapshot();
        if (!std.meta.eql(edited.state.pose, target_pose) or
            !std.meta.eql(edited.state.velocity, engine.physics.Velocity{}) or
            edited.authoring_revision != 1 or edit_session.pending != null or
            edit_session.undo_count != 1 or edit_session.redo_count != 0)
        {
            return error.S5AuthoringEditMismatch;
        }
        summary.edit_revision = edited.authoring_revision;
        const edited_frame = try self.renderS5SmokeFrame(0.5);
        if (!std.meta.eql(edited_frame.first_position.?, target_pose.position) or
            !std.meta.eql(edited_frame.first_rotation.?, target_pose.rotation))
        {
            return error.S5AuthoringInterpolationSmear;
        }
        summary.rendered_frames += 1;

        // Ordinary physics may change the state but never the optimistic
        // authoring revision used by the next history operation.
        try self.simulateTick(true, .none);
        const naturally_advanced = try self.simulation.crate(id);
        if (naturally_advanced.authoring_revision != 1) {
            return error.S5AuthoringNaturalPhysicsAdvancedRevision;
        }

        try self.applyS5SmokeRequests(&.{.undo});
        try self.simulateTick(true, .none);
        const undone = try self.simulation.crate(id);
        const undo_session = self.authoring_controller.snapshot();
        if (undone.authoring_revision != 2 or
            std.meta.eql(undone.state.pose, target_pose) or
            undo_session.undo_count != 0 or undo_session.redo_count != 1)
        {
            return error.S5AuthoringUndoMismatch;
        }
        summary.undo_revision = undone.authoring_revision;

        try self.applyS5SmokeRequests(&.{.redo});
        try self.simulateTick(true, .none);
        const redone = try self.simulation.crate(id);
        const redo_session = self.authoring_controller.snapshot();
        if (!std.meta.eql(redone.state.pose, target_pose) or
            redone.authoring_revision != 3 or redo_session.undo_count != 1 or
            redo_session.redo_count != 0)
        {
            return error.S5AuthoringRedoMismatch;
        }
        summary.redo_revision = redone.authoring_revision;
        _ = try self.renderS5SmokeFrame(0.75);
        summary.rendered_frames += 1;

        const before_hidden = try self.simulation.save(std.heap.page_allocator);
        defer std.heap.page_allocator.free(before_hidden);
        const history_before_hidden = self.authoring_controller.snapshot();
        try self.toggleEditorForS5Smoke(false);
        _ = try self.renderS5SmokeFrame(0.25);
        summary.hidden_frames += 1;
        const after_hidden = try self.simulation.save(std.heap.page_allocator);
        defer std.heap.page_allocator.free(after_hidden);
        if (!std.mem.eql(u8, before_hidden, after_hidden) or
            !std.meta.eql(history_before_hidden, self.authoring_controller.snapshot()))
        {
            return error.S5AuthoringHiddenEditorMutatedAuthority;
        }
        try self.toggleEditorForS5Smoke(true);
        _ = try self.renderS5SmokeFrame(0.5);
        summary.rendered_frames += 1;

        try self.applyS5SmokeRequests(&.{.save});
        summary.save_status = self.save_feedback.status;
        summary.save_sequence = self.save_feedback.sequence;
        switch (self.save_feedback.status) {
            .committed, .committed_sync_warning => {},
            else => return error.S5AuthoringSaveNotCommitted,
        }
        if (summary.save_sequence == 0 or
            !std.mem.eql(u8, self.save_feedback.slot_label, sandbox_save_slot_id))
        {
            return error.S5AuthoringSaveFeedbackMissing;
        }

        // Selection/history are session-only; they are not written into the
        // canonical authority payload or allowed to alter the saved revision.
        if (self.authoring_controller.snapshot().selected == null or
            !std.meta.eql((try self.simulation.crate(id)).state.pose, target_pose) or
            initial.authoring_revision != 0)
        {
            return error.S5AuthoringFinalStateMismatch;
        }
        return summary;
    }

    fn runS4DiagnosticsSmoke(self: *App) !S4DiagnosticsSmokeSummary {
        if (self.validation.profile != .s3_smoke) return error.InvalidS4DiagnosticsSmokeProfile;

        // Establish an authoritative baseline before the smoke controls every
        // later tick. The S3 composition keeps real content/stream/GPU owners
        // present while avoiding unrelated sandbox feature bootstrap work.
        try self.simulateTick(true, .none);
        const tick_before_pause = self.simulation.tickIndex();
        const before_pause = try self.simulation.save(std.heap.page_allocator);
        defer std.heap.page_allocator.free(before_pause);

        self.applyDeveloperControlRequests(&.{.{ .set_paused = true }});
        if (!self.developer_controller.snapshot().paused) {
            return error.S4DiagnosticsPauseRejected;
        }
        for (0..s4_smoke_pause_frames) |_| {
            try self.frame_timer.beginControlledFrameWithElapsedSeconds(
                s4_smoke_pause_frame_seconds,
                .paused,
            );
            if (self.frame_timer.shouldTick()) return error.S4DiagnosticsPausedTick;
            if (self.frame_timer.getSimulationDeltaTime() != 0) {
                return error.S4DiagnosticsPausedTimeContribution;
            }
        }
        if (self.simulation.tickIndex() != tick_before_pause) {
            return error.S4DiagnosticsPauseAdvancedSimulation;
        }
        const after_pause = try self.simulation.save(std.heap.page_allocator);
        defer std.heap.page_allocator.free(after_pause);
        if (!std.mem.eql(u8, before_pause, after_pause)) {
            return error.S4DiagnosticsPauseMutatedSave;
        }

        self.applyDeveloperControlRequests(&.{.single_step});
        if (!self.developer_controller.takeSingleStep()) {
            return error.S4DiagnosticsStepNotQueued;
        }
        try self.simulateTick(true, .none);
        self.frame_timer.recordSingleStep();
        const tick_after_step = self.simulation.tickIndex();
        if (tick_after_step != tick_before_pause + 1 or
            self.frame_timer.ticks_this_frame != 1 or
            self.developer_controller.takeSingleStep())
        {
            return error.S4DiagnosticsStepCountMismatch;
        }

        // Arm an exact host-control trigger, include the matching record, then
        // prove rejection, disarm/resume, retained counters, and monotonic
        // sequence identity across an explicit clear.
        const before_freeze = self.simulation.diagnosticJournal().stats();
        self.applyDeveloperDiagnosticRequests(&.{.{ .arm_freeze = .{
            .severity = .info,
            .category = .host,
            .code = diagnostic_host_control_applied,
        } }});
        self.applyDeveloperControlRequests(&.{.{ .set_time_scale = .half }});
        const frozen = self.simulation.diagnosticJournal().stats();
        if (!frozen.frozen or frozen.trigger_armed or
            frozen.count != before_freeze.count + 1)
        {
            return error.S4DiagnosticsFreezeMismatch;
        }
        self.applyDeveloperControlRequests(&.{.{ .set_time_scale = .normal }});
        const rejected = self.simulation.diagnosticJournal().stats();
        if (!rejected.frozen or rejected.count != frozen.count or
            rejected.rejected_while_frozen != frozen.rejected_while_frozen + 1)
        {
            return error.S4DiagnosticsFrozenRejectionMismatch;
        }

        self.applyDeveloperDiagnosticRequests(&.{ .disarm_freeze, .resume_capture });
        const resumed = self.simulation.diagnosticJournal().stats();
        if (resumed.frozen or resumed.trigger_armed or resumed.count != rejected.count or
            resumed.rejected_while_frozen != rejected.rejected_while_frozen)
        {
            return error.S4DiagnosticsResumeMismatch;
        }
        self.applyDeveloperControlRequests(&.{.{ .set_time_scale = .double }});
        const admitted = self.simulation.diagnosticJournal().stats();
        if (admitted.count != resumed.count + 1) {
            return error.S4DiagnosticsResumeAdmissionMissing;
        }
        const admitted_view = self.simulation.diagnosticJournal().borrowedChronological();
        const last_sequence = admitted_view.at(admitted_view.len() - 1).?.sequence;

        self.applyDeveloperDiagnosticRequests(&.{.clear});
        const cleared = self.simulation.diagnosticJournal().stats();
        if (cleared.count != 0 or cleared.frozen or
            cleared.overwritten != admitted.overwritten or
            cleared.rejected_while_frozen != admitted.rejected_while_frozen)
        {
            return error.S4DiagnosticsClearMismatch;
        }
        self.applyDeveloperControlRequests(&.{.{ .set_time_scale = .normal }});
        const after_clear_view = self.simulation.diagnosticJournal().borrowedChronological();
        if (after_clear_view.len() != 1 or
            after_clear_view.at(0).?.sequence != last_sequence + 1)
        {
            return error.S4DiagnosticsClearResetSequence;
        }
        self.applyDeveloperDiagnosticRequests(&.{.clear});
        if (self.simulation.diagnosticJournal().stats().count != 0) {
            return error.S4DiagnosticsSecondClearMismatch;
        }

        self.applyDeveloperControlRequests(&.{.{ .set_paused = false }});
        if (self.developer_controller.paused) {
            return error.S4DiagnosticsResumeRejected;
        }
        try self.prepareS4ResidentDistrict();

        // M3 correctly made district output pressure a healthy admission
        // rejection, so the old smoke can no longer manufacture a runtime
        // fault by overcommitting that queue. This app instance alone composes
        // a dormant fixed-error system for the retained-fault path. Normal
        // sandbox/headless/replay/save compositions do not register it.
        try self.simulation.armDiagnosticFaultProbe();
        // Drive the failing tick through the validation host's graphical
        // scheduling/catch/retain/inspection/quit path. A consumed opportunity
        // is completed only after the authoritative tick returns successfully.
        const completed_ticks_before_fault = self.frame_timer.total_ticks;
        const committed_tick_before_fault = self.simulation.tickIndex();
        const expected_fault_tick = committed_tick_before_fault + 1;
        var fault_loop_probe = S4FaultLoopProbe{
            .expected_error = error.InjectedDeveloperDiagnosticFault,
        };
        self.validation.s4_fault_loop_probe = &fault_loop_probe;
        const run_result = self.runValidation(null, .s3_streaming);
        const returned_error: ?anyerror = if (run_result) |_| null else |err| err;
        self.validation.s4_fault_loop_probe = null;
        if (returned_error == null or
            returned_error.? != error.InjectedDeveloperDiagnosticFault)
        {
            return error.S4DiagnosticsOriginalFaultNotReturned;
        }
        const failed_tick_counted = self.frame_timer.total_ticks !=
            completed_ticks_before_fault or self.frame_timer.ticks_this_frame != 0;
        if (failed_tick_counted) return error.S4DiagnosticsFailedTickCounted;
        const fault_stream = fault_loop_probe.stream_at_fault orelse
            return error.S4DiagnosticsFaultStreamSnapshotMissing;
        const fault_gpu = fault_loop_probe.gpu_at_fault orelse
            return error.S4DiagnosticsFaultGpuSnapshotMissing;
        std.debug.print(
            "S4_FAULT_LOOP_PROBE content_pumps={d}/{d} gpu_pumps={d}/{d} " ++
                "committed_tick={d}/{d} completed_ticks={d}/{d} " ++
                "retained_ready_frames={d} quit_injected={} stream_stage={s} " ++
                "gpu_live_scenes={d}\n",
            .{
                fault_loop_probe.content_pump_calls_at_fault,
                fault_loop_probe.content_pump_calls,
                fault_loop_probe.gpu_pump_calls_at_fault,
                fault_loop_probe.gpu_pump_calls,
                fault_loop_probe.tick_at_fault,
                committed_tick_before_fault,
                fault_loop_probe.completed_ticks_at_fault,
                completed_ticks_before_fault,
                fault_loop_probe.retained_ready_frames,
                fault_loop_probe.quit_injected,
                @tagName(fault_stream.slots[district_west_slot_index].state),
                fault_gpu.live_scenes,
            },
        );
        if (fault_loop_probe.content_pump_calls_at_fault != 1 or
            fault_loop_probe.content_pump_calls != 1 or
            fault_loop_probe.gpu_pump_calls_at_fault != 0 or
            fault_loop_probe.gpu_pump_calls != 0 or
            fault_loop_probe.tick_at_fault != committed_tick_before_fault or
            fault_loop_probe.completed_ticks_at_fault != completed_ticks_before_fault or
            fault_loop_probe.retained_ready_frames != 1 or
            !fault_loop_probe.quit_injected or fault_gpu.live_scenes == 0)
        {
            return error.S4DiagnosticsProductionFaultLoopEvidenceMissing;
        }

        const fault = self.simulation.firstFault() orelse
            return error.S4DiagnosticsFaultMissing;
        if (fault.phase != .commands or fault.tick_index != expected_fault_tick or
            fault.error_code != @intFromError(error.InjectedDeveloperDiagnosticFault) or
            fault.journal_sequence == 0 or
            !std.mem.eql(u8, fault.system_name.slice(), "diagnostics.injected_fault_probe") or
            !std.mem.eql(u8, fault.error_name.slice(), "InjectedDeveloperDiagnosticFault"))
        {
            return error.S4DiagnosticsFaultEvidenceMismatch;
        }
        const fault_journal = self.simulation.diagnosticJournal();
        if (!fault_journal.stats().frozen) return error.S4DiagnosticsFaultDidNotFreeze;
        var found_fault_entry = false;
        const fault_entries = fault_journal.borrowedChronological();
        const fault_journal_entry_count = fault_entries.len();
        for (0..fault_entries.len()) |index| {
            const entry = fault_entries.at(index).?.*;
            if (entry.sequence == fault.journal_sequence) {
                if (entry.severity != .fatal or entry.category != .runtime or
                    entry.code != engine.diagnostic_contracts.codes.runtime_system_fault)
                {
                    return error.S4DiagnosticsFaultJournalMismatch;
                }
                found_fault_entry = true;
                break;
            }
        }
        if (!found_fault_entry) return error.S4DiagnosticsFaultJournalMissing;

        // The validation loop already exercised the normal compact fault-entry
        // path and a retained minimal Metal frame without touching invalid
        // feature state.
        const compact_snapshot = try self.developerSnapshot();
        const compact_text = try developer_diagnostics.formatTextAlloc(
            std.heap.page_allocator,
            compact_snapshot,
        );
        defer std.heap.page_allocator.free(compact_text);
        if (std.mem.indexOf(
            u8,
            compact_text,
            "fault=diagnostics.injected_fault_probe/InjectedDeveloperDiagnosticFault",
        ) == null or
            std.mem.indexOf(u8, compact_text, "fault_phase=commands") == null)
        {
            return error.S4DiagnosticsCompactTextMissingFault;
        }
        std.debug.print("S4_DIAGNOSTICS_SMOKE_TEXT {s}\n", .{compact_text});

        const inspection_ready_frames = fault_loop_probe.retained_ready_frames;

        const json = try self.developerDiagnosticsJsonAlloc(std.heap.page_allocator);
        defer std.heap.page_allocator.free(json);
        var parsed = try std.json.parseFromSlice(
            std.json.Value,
            std.heap.page_allocator,
            json,
            .{},
        );
        defer parsed.deinit();
        const exported_entries = parsed.value.object.get("entries") orelse
            return error.S4DiagnosticsJsonEntriesMissing;
        switch (exported_entries) {
            .array => |array| if (array.items.len == 0) {
                return error.S4DiagnosticsJsonEntriesEmpty;
            },
            else => return error.S4DiagnosticsJsonEntriesInvalid,
        }
        std.debug.print("S4_DIAGNOSTICS_JSON {s}\n", .{json});

        var terminal_rejected = false;
        self.simulation.tick() catch |err| {
            if (err != error.RuntimeFaulted) return err;
            terminal_rejected = true;
        };
        if (!terminal_rejected or
            !std.meta.eql(fault, self.simulation.firstFault().?))
        {
            return error.S4DiagnosticsFaultWasReplaced;
        }

        return .{
            .paused_frames = s4_smoke_pause_frames,
            .paused_seconds = @as(f64, @floatFromInt(s4_smoke_pause_frames)) *
                s4_smoke_pause_frame_seconds,
            .tick_before_pause = tick_before_pause,
            .tick_after_step = tick_after_step,
            .failed_tick_counted = failed_tick_counted,
            .frozen_rejections = rejected.rejected_while_frozen -
                frozen.rejected_while_frozen,
            .fault_journal_entries = fault_journal_entry_count,
            .inspection_ready_frames = inspection_ready_frames,
            .json_bytes = json.len,
            .fault = fault,
        };
    }

    fn prepareS4ResidentDistrict(self: *App) !void {
        self.district_focus_override = s3_smoke_near;
        for (0..s4_smoke_stream_attempt_limit) |_| {
            self.input_buffer.beginFrame();
            if (!self.input_buffer.pumpEvents(self.developer_editor.eventSink())) {
                return error.S4DiagnosticsSmokeInterrupted;
            }
            if (self.waitForWindowSuspension()) continue;
            try self.frame_timer.beginControlledFrameWithElapsedSeconds(
                1.0 / 60.0,
                .{ .running = .normal },
            );
            try self.pumpDistrictContent();
            while (self.frame_timer.shouldTick()) {
                try self.simulateTick(true, .s3_streaming);
                self.frame_timer.recordCompletedTick();
            }
            switch (try self.render(self.frame_timer.alpha())) {
                .ready => {},
                .unavailable => continue,
            }
            switch (self.district_stream_slots[district_west_slot_index].state) {
                .active => |active| if (try self.district_registry.residency(
                    active.scene,
                ) == .resident) {
                    try self.validateS3Resident(active);
                    try self.validateS3ResidentDeveloperSnapshot();
                    return;
                },
                else => {},
            }
            c.SDL_DelayPrecise(std.time.ns_per_ms);
        }
        return error.S4DiagnosticsResidentDistrictUnavailable;
    }

    fn developerSnapshot(self: *App) !DeveloperSnapshot {
        const controller = self.developer_controller.snapshot();
        const journal_stats = self.simulation.diagnosticJournal().stats();
        const gpu_diagnostics = try self.district_registry.diagnostics();
        return .{
            .frame_index = self.frame_timer.total_frames,
            .simulation = self.simulation.diagnostics(),
            .content_worker = if (self.district_content_worker) |worker| blk: {
                const worker_diagnostics = worker.diagnostics();
                break :blk .{
                    .stage = switch (worker_diagnostics.state) {
                        .idle => .idle,
                        .queued => .queued,
                        .working => .working,
                        .cancelling => .cancelling,
                        .completion_ready => .completion_ready,
                    },
                    .generation = worker_diagnostics.generation orelse 0,
                    .thread_started = worker_diagnostics.started,
                    .cancellation_requested = worker_diagnostics.cancellation_requested,
                    .completion_kind = if (worker_diagnostics.completion_kind) |kind|
                        switch (kind) {
                            .ready => .ready,
                            .cancelled => .cancelled,
                            .failed => .failed,
                        }
                    else
                        null,
                };
            } else null,
            .district_streams = if (if (build_options.validation_mode or builtin.is_test)
                self.validation.profile == .sandbox or self.validation.profile == .s3_smoke
            else
                true)
                self.developerDistrictStreamsSnapshot()
            else
                null,
            .gpu = .{
                .current = developerGpuUsage(gpu_diagnostics.current),
                .high_water = developerGpuUsage(gpu_diagnostics.high_water),
                .limits = .{
                    .scene_capacity = gpu_diagnostics.limits.scene_capacity,
                    .batch_capacity = gpu_diagnostics.limits.batch_capacity,
                    .scenes_per_batch = gpu_diagnostics.limits.scenes_per_batch,
                    .max_staged_cpu_bytes = gpu_diagnostics.limits.max_staged_cpu_bytes,
                    .max_in_flight_upload_bytes = gpu_diagnostics.limits.max_in_flight_upload_bytes,
                    .max_resident_gpu_bytes = gpu_diagnostics.limits.max_resident_gpu_bytes,
                    .max_submit_bytes_per_pump = gpu_diagnostics.limits.max_submit_bytes_per_pump,
                },
            },
            .host_time = .{
                .paused = controller.paused,
                .time_scale = controller.time_scale,
                .single_step_pending = controller.single_step_pending,
                .raw_frame_seconds = self.frame_timer.getDeltaTime(),
                .simulation_frame_seconds = self.frame_timer.getSimulationDeltaTime(),
                .ticks_this_frame = self.frame_timer.ticks_this_frame,
                .control_requests_rejected = self.developer_control_requests.rejected,
                .diagnostic_requests_rejected = self.developer_diagnostic_requests.rejected,
            },
            .journal = .{
                .count = @intCast(journal_stats.count),
                .capacity = @intCast(journal_stats.capacity),
                .overwritten = journal_stats.overwritten,
                .rejected_while_frozen = journal_stats.rejected_while_frozen,
                .rejected_sequence_exhausted = journal_stats.rejected_sequence_exhausted,
                .sequence_exhausted = journal_stats.sequence_exhausted,
                .frozen = journal_stats.frozen,
                .trigger_armed = journal_stats.trigger_armed,
            },
        };
    }

    fn developerDistrictStreamsSnapshot(self: *const App) developer_diagnostics.DistrictStreams {
        var result: [district_stream_slot_count]developer_diagnostics.DistrictStreamSlot = undefined;
        for (self.district_stream_slots, 0..) |slot, index| {
            result[index] = .{
                .coord = .{ .x = slot.coord.x, .z = slot.coord.z },
                .state = switch (std.meta.activeTag(slot.state)) {
                    .idle => .idle,
                    .reading => .reading,
                    .cancelling_content => .cancelling_content,
                    .content_ready => .content_ready,
                    .request_submitted => .request_submitted,
                    .request_submitted_cancel => .request_submitted_cancel,
                    .loading => .loading,
                    .cancelling_logical => .cancelling_logical,
                    .active => .active,
                    .unloading => .unloading,
                    .draining => .draining,
                },
                .desired_inside = slot.proximity.inside,
                .correlation_id = if (slot.correlation == 0) null else slot.correlation,
                .pending_decoded_scene = slot.pending_scene != null,
            };
            switch (slot.state) {
                .idle => {},
                .reading, .cancelling_content, .content_ready => |reading| {
                    result[index].generations.content = reading.generation;
                    result[index].scene = reading.scene;
                },
                .request_submitted, .request_submitted_cancel => |submitted| {
                    result[index].generations.content = submitted.content_generation;
                    result[index].scene = submitted.scene;
                },
                .loading, .active => |bound| {
                    result[index].generations.content = bound.content_generation;
                    result[index].generations.logical = bound.ticket.generation;
                    result[index].scene = bound.scene;
                },
                .cancelling_logical => |cancelling| {
                    result[index].generations.content =
                        cancelling.bound.content_generation;
                    result[index].generations.logical = cancelling.bound.ticket.generation;
                    result[index].scene = cancelling.bound.scene;
                },
                .unloading => |unloading| {
                    result[index].generations.content = unloading.bound.content_generation;
                    result[index].generations.logical = unloading.bound.ticket.generation;
                    result[index].scene = unloading.bound.scene;
                },
                .draining => |draining| {
                    result[index].generations.content = draining.content_generation;
                    result[index].scene = draining.scene;
                },
            }
        }
        return developer_diagnostics.DistrictStreams.init(result);
    }

    fn applyDeveloperControlRequests(
        self: *App,
        requests: []const developer_controls.Request,
    ) void {
        for (requests) |request| {
            if (self.simulation.firstFault() != null) switch (request) {
                .set_paused => |paused| if (!paused) {
                    self.recordRejectedDeveloperControl(error.RuntimeFaulted);
                    continue;
                },
                .single_step => {
                    self.recordRejectedDeveloperControl(error.RuntimeFaulted);
                    continue;
                },
                .set_time_scale => {},
            };
            const result = self.developer_controller.apply(request) catch |err| {
                self.recordRejectedDeveloperControl(err);
                continue;
            };
            if (result.entered_pause) self.action_latch.clear();
            _ = self.simulation.recordDiagnostic(.{
                .severity = .info,
                .category = .host,
                .code = diagnostic_host_control_applied,
                .frame_index = self.frame_timer.total_frames,
                .thread_role = .host,
                .thread_id = engine.diagnostics.currentThreadId(),
                .correlation_id = @intFromEnum(std.meta.activeTag(request)),
            });
        }
    }

    fn recordRejectedDeveloperControl(self: *App, err: anyerror) void {
        _ = self.simulation.recordDiagnostic(.{
            .severity = .warning,
            .category = .host,
            .code = diagnostic_host_control_rejected,
            .frame_index = self.frame_timer.total_frames,
            .thread_role = .host,
            .thread_id = engine.diagnostics.currentThreadId(),
            .correlation_id = @intFromError(err),
        });
    }

    fn enterFaultInspection(self: *App) void {
        self.developer_controller.single_step_pending = false;
        self.developer_controller.paused = true;
        self.action_latch.clear();
        const snapshot = self.developerSnapshot() catch |err| {
            self.printFaultInspectionFallback(err);
            return;
        };
        const text_value = developer_diagnostics.formatTextAlloc(
            std.heap.page_allocator,
            snapshot,
        ) catch |err| {
            self.printFaultInspectionFallback(err);
            return;
        };
        defer std.heap.page_allocator.free(text_value);
        std.debug.print("RUNTIME_FAULT_INSPECTION {s}\n", .{text_value});
    }

    fn printFaultInspectionFallback(self: *App, reporting_error: anyerror) void {
        if (self.simulation.firstFault()) |fault| {
            std.debug.print(
                "RUNTIME_FAULT_INSPECTION_FALLBACK phase={s} tick={d} " ++
                    "system={s}{s} error={s}{s} code={d} sequence={d} reporting_error={s}\n",
                .{
                    @tagName(fault.phase),
                    fault.tick_index,
                    fault.system_name.slice(),
                    if (fault.system_name.truncated) "[truncated]" else "",
                    fault.error_name.slice(),
                    if (fault.error_name.truncated) "[truncated]" else "",
                    fault.error_code,
                    fault.journal_sequence,
                    @errorName(reporting_error),
                },
            );
        } else {
            std.debug.print(
                "RUNTIME_FAULT_INSPECTION_FALLBACK retained_fault=missing reporting_error={s}\n",
                .{@errorName(reporting_error)},
            );
        }
    }

    fn applyDeveloperDiagnosticRequests(
        self: *App,
        requests: []const developer_diagnostics.Request,
    ) void {
        for (requests) |request| switch (request) {
            .arm_freeze => |condition| {
                self.simulation.armDiagnosticFreeze(condition);
            },
            .disarm_freeze => _ = self.simulation.disarmDiagnosticFreeze(),
            .resume_capture => _ = self.simulation.resumeDiagnosticCapture(),
            .clear => self.simulation.clearDiagnostics(),
            .export_json => self.exportDeveloperDiagnostics() catch |err| {
                _ = self.simulation.recordDiagnostic(.{
                    .severity = .warning,
                    .category = .host,
                    .code = diagnostic_host_control_rejected,
                    .frame_index = self.frame_timer.total_frames,
                    .thread_role = .host,
                    .thread_id = engine.diagnostics.currentThreadId(),
                    .correlation_id = @intFromError(err),
                });
            },
        };
    }

    fn exportDeveloperDiagnostics(self: *App) !void {
        const json = try self.developerDiagnosticsJsonAlloc(std.heap.page_allocator);
        defer std.heap.page_allocator.free(json);
        std.debug.print("S4_DIAGNOSTICS_JSON {s}\n", .{json});
    }

    fn developerDiagnosticsJsonAlloc(
        self: *App,
        allocator: std.mem.Allocator,
    ) ![]u8 {
        var entry_storage: [engine.runtime.DiagnosticJournal.capacity]engine.diagnostic_contracts.Entry = undefined;
        const entries = self.simulation
            .diagnosticJournal()
            .copyChronological(&entry_storage);
        const export_value = DeveloperExport{
            .snapshot = try self.developerSnapshot(),
            .entries = entries,
        };
        return developer_diagnostics.formatJsonAlloc(
            allocator,
            export_value,
        );
    }

    fn captureFrameActions(self: *App) !void {
        var move = [2]f32{ 0, 0 };
        if (self.input_buffer.isKeyDown(input.Key.A)) move[0] -= 1;
        if (self.input_buffer.isKeyDown(input.Key.D)) move[0] += 1;
        if (self.input_buffer.isKeyDown(input.Key.S)) move[1] -= 1;
        if (self.input_buffer.isKeyDown(input.Key.W)) move[1] += 1;
        const looking = self.input_buffer.isMouseButtonDown(input.MouseButton.RIGHT);
        try self.action_latch.captureFrame(.{
            .move = move,
            .look_delta = if (looking)
                .{ self.input_buffer.mouse_delta_x, self.input_buffer.mouse_delta_y }
            else
                .{ 0, 0 },
            .jump_pressed = self.input_buffer.isKeyPressed(input.Key.SPACE),
            .interact_pressed = self.input_buffer.isKeyPressed(input.Key.E),
            .carry_pressed = self.input_buffer.isKeyPressed(input.Key.F),
            .brake = self.input_buffer.isKeyDown(input.Key.SPACE),
            .hand_brake = self.input_buffer.isKeyDown(input.Key.LSHIFT),
            .reset = self.input_buffer.gameplayActionsMustReset(),
        });
    }

    /// Record one visual-host orchestration transition against the exact fixed
    /// slot that owns it. Correlations never bleed across adjacent districts.
    fn recordDistrictStreamTransition(
        self: *App,
        slot_index: usize,
        severity: engine.diagnostic_contracts.Severity,
        category: engine.diagnostic_contracts.Category,
        code: engine.diagnostic_contracts.Code,
        persistent_id: ?engine.PersistentId,
    ) void {
        const correlation = self.district_stream_slots[slot_index].correlation;
        if (correlation == 0) return;
        _ = self.simulation.recordDiagnostic(.{
            .severity = severity,
            .category = category,
            .code = code,
            .tick_index = self.simulation.tickIndex(),
            .frame_index = self.frame_timer.total_frames,
            .thread_role = .host,
            .thread_id = engine.diagnostics.currentThreadId(),
            .persistent_id = persistent_id,
            .correlation_id = correlation,
        });
    }

    fn districtSlotIndexForCoord(self: *const App, coord: sandbox_host.ChunkCoord) ?usize {
        for (self.district_stream_slots, 0..) |slot, index| {
            if (slot.coord.x == coord.x and slot.coord.z == coord.z) return index;
        }
        return null;
    }

    fn districtSceneHandle(state: DistrictStreamState) ?engine.rendering.SceneHandle {
        return switch (state) {
            .idle => null,
            .reading, .cancelling_content, .content_ready => |value| value.scene,
            .request_submitted, .request_submitted_cancel => |value| value.scene,
            .loading, .active => |value| value.scene,
            .cancelling_logical => |value| value.bound.scene,
            .unloading => |value| value.bound.scene,
            .draining => |value| value.scene,
        };
    }

    fn districtResidency(
        self: *App,
        scene: engine.rendering.SceneHandle,
    ) !?district_gpu_registry.Residency {
        return self.district_registry.residency(scene) catch |err| {
            if (err == error.StaleSceneHandle) return null;
            return err;
        };
    }

    fn districtSlotIndexForLoadRequest(self: *const App, request_id: u64) ?usize {
        for (self.district_stream_slots, 0..) |slot, index| switch (slot.state) {
            .request_submitted, .request_submitted_cancel => |submitted| {
                if (submitted.request_id == request_id) return index;
            },
            else => {},
        };
        return null;
    }

    fn districtSlotIndexForTicket(self: *const App, ticket: sandbox_host.LoadTicket) ?usize {
        for (self.district_stream_slots, 0..) |slot, index| {
            const owned_ticket: ?sandbox_host.LoadTicket = switch (slot.state) {
                .loading, .active => |bound| bound.ticket,
                .cancelling_logical => |value| value.bound.ticket,
                .unloading => |value| value.bound.ticket,
                else => null,
            };
            if (owned_ticket) |candidate| {
                if (std.meta.eql(candidate, ticket)) return index;
            }
        }
        return null;
    }

    fn districtLogicalTransitionInFlight(self: *const App) bool {
        for (self.district_stream_slots) |slot| switch (slot.state) {
            .request_submitted,
            .request_submitted_cancel,
            .loading,
            .cancelling_logical,
            .unloading,
            => return true,
            else => {},
        };
        return false;
    }

    fn districtFocusPosition(self: *App) !?[2]f32 {
        if (build_options.validation_mode or builtin.is_test) {
            if (self.validation.profile == .s3_smoke) return self.district_focus_override;
            if (self.validation.profile != .sandbox) return null;
        }
        if (self.controlled_vehicle_id) |vehicle_id| {
            const position = (try self.simulation.vehicle(vehicle_id)).state.chassis.pose.position;
            return .{ position[0], position[2] };
        }
        const character_id = self.initial_character_id orelse return null;
        const position = (try self.simulation.character(character_id)).position;
        return .{ position[0], position[2] };
    }

    /// Evaluate both host-owned hysteresis regions exactly once per fixed tick,
    /// then admit at most one new operation in canonical catalog order.
    fn updateDistrictProximity(self: *App, position_xz: [2]f32) !void {
        for (&self.district_stream_slots, 0..) |*slot, slot_index| {
            if (try slot.proximity.observe(position_xz) == .exit) {
                try self.requestDistrictDeparture(slot_index);
            }
        }
        try self.reconcileDistrictDesire();
    }

    fn reconcileDistrictDesire(self: *App) !void {
        for (&self.district_stream_slots, 0..) |*slot, slot_index| {
            const draining = switch (slot.state) {
                .draining => |value| value,
                else => continue,
            };
            if (!try districtRecycleComplete(self.district_registry, draining.scene)) continue;
            self.recordDistrictStreamTransition(
                slot_index,
                .info,
                .rendering,
                engine.diagnostic_contracts.codes.district_stream_gpu_drained,
                null,
            );
            slot.state = .idle;
            slot.correlation = 0;
        }

        const catalog_owner = if (self.district_catalog) |*value| value else return;
        for (catalog_owner.view().entries) |entry| {
            const coord = sandbox_host.ChunkCoord{ .x = entry.coord.x, .z = entry.coord.z };
            const slot_index = self.districtSlotIndexForCoord(coord) orelse
                return error.DistrictCatalogSlotMismatch;
            const slot = &self.district_stream_slots[slot_index];
            if (!slot.proximity.inside) continue;
            switch (slot.state) {
                .content_ready => {
                    if (self.districtLogicalTransitionInFlight()) continue;
                    try self.submitPreparedDistrict(slot_index);
                    return;
                },
                .idle => {
                    if (self.district_content_owner != null) continue;
                    try self.beginDistrictContentRequest(slot_index);
                    return;
                },
                else => {},
            }
        }
    }

    fn rejectReservedDistrict(
        self: *App,
        slot_index: usize,
        scene: engine.rendering.SceneHandle,
        content_generation: ?u64,
    ) !void {
        const slot = &self.district_stream_slots[slot_index];
        try slot.presentation.loadRejected(scene);
        self.recordDistrictStreamTransition(
            slot_index,
            .warning,
            .rendering,
            engine.diagnostic_contracts.codes.district_stream_gpu_release_requested,
            null,
        );
        slot.state = .{ .draining = .{
            .scene = scene,
            .content_generation = content_generation,
        } };
    }

    fn beginDistrictContentRequest(self: *App, slot_index: usize) !void {
        const slot = &self.district_stream_slots[slot_index];
        if (std.meta.activeTag(slot.state) != .idle) {
            return error.DistrictContentRequestWhileBusy;
        }
        if (self.district_content_owner != null) return error.DistrictContentWorkerBusy;
        if (self.simulation.districtStateFor(slot.coord) != null) {
            return error.DistrictLogicalStateMismatch;
        }
        const worker = self.district_content_worker orelse
            return error.DistrictContentWorkerMissing;
        const catalog_owner = if (self.district_catalog) |*value| value else return error.DistrictCatalogMissing;
        const scene = slot.presentation.beginRequest() catch |err| {
            if (err == error.DistrictSceneRegistryFull) return;
            return err;
        };
        slot.correlation = takeMonotonicId(
            &self.district_next_stream_correlation,
        ) catch |err| {
            try self.rejectReservedDistrict(slot_index, scene, null);
            return err;
        };
        self.recordDistrictStreamTransition(
            slot_index,
            .debug,
            .rendering,
            engine.diagnostic_contracts.codes.district_stream_gpu_reserved,
            null,
        );
        const generation = takeMonotonicId(&self.district_next_content_generation) catch |err| {
            try self.rejectReservedDistrict(slot_index, scene, null);
            return err;
        };
        const request = catalog_owner.sceneRequest(slot.coord, generation) catch |err| {
            try self.rejectReservedDistrict(slot_index, scene, generation);
            return err;
        };
        const disposition = worker.request(request) catch |err| {
            self.recordDistrictStreamTransition(
                slot_index,
                .err,
                .content,
                engine.diagnostic_contracts.codes.district_stream_content_failed,
                null,
            );
            try self.rejectReservedDistrict(slot_index, scene, generation);
            return err;
        };
        switch (disposition) {
            .accepted => {
                slot.state = .{ .reading = .{
                    .scene = scene,
                    .generation = generation,
                } };
                self.district_content_owner = @intCast(slot_index);
                self.recordDistrictStreamTransition(
                    slot_index,
                    .info,
                    .content,
                    engine.diagnostic_contracts.codes.district_stream_content_requested,
                    null,
                );
            },
            .busy, .stale, .invalid => {
                self.recordDistrictStreamTransition(
                    slot_index,
                    .err,
                    .content,
                    engine.diagnostic_contracts.codes.district_stream_content_failed,
                    null,
                );
                try self.rejectReservedDistrict(slot_index, scene, generation);
                return error.DistrictContentWorkerAdmissionFailed;
            },
        }
    }

    fn requestDistrictDeparture(self: *App, slot_index: usize) !void {
        const slot = &self.district_stream_slots[slot_index];
        switch (slot.state) {
            .idle,
            .draining,
            .cancelling_content,
            .request_submitted_cancel,
            .cancelling_logical,
            .unloading,
            => {},
            .reading => |reading| {
                if (self.district_content_owner != @as(u8, @intCast(slot_index))) {
                    return error.DistrictContentOwnerMismatch;
                }
                const worker = self.district_content_worker orelse
                    return error.DistrictContentWorkerMissing;
                switch (worker.cancel(reading.generation)) {
                    .requested => {
                        slot.state = .{ .cancelling_content = reading };
                        self.recordDistrictStreamTransition(
                            slot_index,
                            .info,
                            .content,
                            engine.diagnostic_contracts.codes.district_stream_content_cancel_requested,
                            null,
                        );
                    },
                    .idle, .stale, .invalid => return error.DistrictContentWorkerStateMismatch,
                }
            },
            .content_ready => |ready| {
                self.clearPendingDistrictScene(slot_index);
                try self.rejectReservedDistrict(
                    slot_index,
                    ready.scene,
                    ready.generation,
                );
            },
            .request_submitted => |submitted| {
                self.clearPendingDistrictScene(slot_index);
                slot.state = .{ .request_submitted_cancel = submitted };
            },
            .loading => |loading| {
                self.clearPendingDistrictScene(slot_index);
                const request_id = try takeMonotonicId(&self.district_next_request_id);
                try self.simulation.submitDistrict(.{ .cancel_load = .{
                    .request_id = request_id,
                    .ticket = loading.ticket,
                } });
                slot.state = .{ .cancelling_logical = .{
                    .bound = loading,
                    .request_id = request_id,
                } };
                self.recordDistrictStreamTransition(
                    slot_index,
                    .info,
                    .streaming,
                    engine.diagnostic_contracts.codes.district_stream_logical_cancel_submitted,
                    null,
                );
            },
            .active => |active| {
                self.clearPendingDistrictScene(slot_index);
                const request_id = try takeMonotonicId(&self.district_next_request_id);
                try self.simulation.submitDistrict(.{ .unload = .{
                    .request_id = request_id,
                    .ticket = active.ticket,
                } });
                slot.state = .{ .unloading = .{
                    .bound = active,
                    .request_id = request_id,
                } };
                self.recordDistrictStreamTransition(
                    slot_index,
                    .info,
                    .streaming,
                    engine.diagnostic_contracts.codes.district_stream_logical_unload_submitted,
                    null,
                );
            },
        }
    }

    fn pumpDistrictContent(self: *App) !void {
        for (0..district_stream_slot_count) |slot_index| {
            try self.retryPendingDistrictScene(slot_index);
        }
        const slot_index: usize = self.district_content_owner orelse return;
        const slot = &self.district_stream_slots[slot_index];
        const job: DistrictContentJob = switch (slot.state) {
            .reading => |value| .{ .value = value, .cancelling = false },
            .cancelling_content => |value| .{ .value = value, .cancelling = true },
            else => return error.DistrictContentOwnerMismatch,
        };
        const worker = self.district_content_worker orelse
            return error.DistrictContentWorkerMissing;
        switch (worker.poll(job.value.generation)) {
            .pending => {},
            .idle, .stale => return error.DistrictContentWorkerStateMismatch,
            .completion => |completion| {
                self.district_content_owner = null;
                switch (completion) {
                    .cancelled => |generation| {
                        if (!job.cancelling or generation != job.value.generation) {
                            return error.DistrictContentLoadCancelled;
                        }
                        self.recordDistrictStreamTransition(
                            slot_index,
                            .info,
                            .content,
                            engine.diagnostic_contracts.codes.district_stream_content_cancelled,
                            null,
                        );
                        try self.rejectReservedDistrict(
                            slot_index,
                            job.value.scene,
                            job.value.generation,
                        );
                    },
                    .failed => |failed| {
                        self.recordDistrictStreamTransition(
                            slot_index,
                            .err,
                            .content,
                            engine.diagnostic_contracts.codes.district_stream_content_failed,
                            null,
                        );
                        try self.rejectReservedDistrict(
                            slot_index,
                            job.value.scene,
                            job.value.generation,
                        );
                        std.debug.print(
                            "Cooked district load failed for ({d},{d}): {any}\n",
                            .{ slot.coord.x, slot.coord.z, failed.failure },
                        );
                        return error.DistrictContentLoadFailed;
                    },
                    .ready => |ready_value| {
                        if (ready_value.generation != job.value.generation) {
                            var stale_scene = ready_value.scene;
                            stale_scene.deinit();
                            return error.DistrictContentGenerationMismatch;
                        }
                        var scene = ready_value.scene;
                        errdefer scene.deinit();
                        self.recordDistrictStreamTransition(
                            slot_index,
                            .info,
                            .content,
                            engine.diagnostic_contracts.codes.district_stream_content_ready,
                            null,
                        );
                        if (job.cancelling or !slot.proximity.inside) {
                            scene.deinit();
                            try self.rejectReservedDistrict(
                                slot_index,
                                job.value.scene,
                                job.value.generation,
                            );
                            return;
                        }
                        try validateCookedLogicalDistrict(scene.view(), slot.coord);
                        slot.pending_scene = scene;
                        slot.state = .{ .content_ready = job.value };
                    },
                }
            },
        }
    }

    fn submitPreparedDistrict(self: *App, slot_index: usize) !void {
        const slot = &self.district_stream_slots[slot_index];
        const ready = switch (slot.state) {
            .content_ready => |value| value,
            else => return error.DistrictPreparedSceneStateMismatch,
        };
        const pending = if (slot.pending_scene) |*scene| scene else return error.DistrictPreparedSceneMissing;
        if (self.simulation.districtStateFor(slot.coord) != null) {
            return error.DistrictLogicalStateMismatch;
        }
        const request_id = try takeMonotonicId(&self.district_next_request_id);
        var upload_plan = try district_scene_adapter.build(pending.view());
        try self.simulation.submitDistrict(.{ .request_load = .{
            .request_id = request_id,
            .coord = slot.coord,
            .assets = .{ .scene = ready.scene },
        } });
        slot.state = .{ .request_submitted = .{
            .scene = ready.scene,
            .request_id = request_id,
            .content_generation = ready.generation,
        } };
        self.recordDistrictStreamTransition(
            slot_index,
            .info,
            .streaming,
            engine.diagnostic_contracts.codes.district_stream_logical_submitted,
            null,
        );
        if (!try self.stageDistrictUpload(slot_index, ready.scene, &upload_plan)) return;
        pending.deinit();
        slot.pending_scene = null;
    }

    fn stageDistrictUpload(
        self: *App,
        slot_index: usize,
        scene_handle: engine.rendering.SceneHandle,
        upload_plan: *district_scene_adapter.UploadPlan,
    ) !bool {
        self.district_registry.stage(scene_handle, upload_plan.sceneUpload()) catch |err| {
            if (isRetryableDistrictStageError(err)) return false;
            return err;
        };
        const staged_stats = try self.district_registry.stats();
        self.recordDistrictStreamTransition(
            slot_index,
            .info,
            .rendering,
            engine.diagnostic_contracts.codes.district_stream_gpu_staged,
            null,
        );
        std.debug.print(
            "Cooked district ({d},{d}) staged: primitives={d} textures={d} cpu_bytes={d}\n",
            .{
                self.district_stream_slots[slot_index].coord.x,
                self.district_stream_slots[slot_index].coord.z,
                upload_plan.mesh_count,
                upload_plan.texture_count,
                staged_stats.staged_cpu_bytes,
            },
        );
        return true;
    }

    fn retryPendingDistrictScene(self: *App, slot_index: usize) !void {
        const slot = &self.district_stream_slots[slot_index];
        const pending = if (slot.pending_scene) |*scene| scene else return;
        const scene_handle = switch (slot.state) {
            .request_submitted => |value| value.scene,
            .loading, .active => |value| value.scene,
            .content_ready => return,
            else => return error.DistrictPendingSceneStateMismatch,
        };
        var upload_plan = try district_scene_adapter.build(pending.view());
        if (!try self.stageDistrictUpload(slot_index, scene_handle, &upload_plan)) return;
        pending.deinit();
        slot.pending_scene = null;
    }

    fn clearPendingDistrictScene(self: *App, slot_index: usize) void {
        const slot = &self.district_stream_slots[slot_index];
        if (slot.pending_scene) |*scene| scene.deinit();
        slot.pending_scene = null;
    }

    fn processDistrictOutcomes(self: *App) !void {
        while (self.simulation.pollDistrictOutcome()) |outcome| {
            switch (outcome) {
                .load_requested => |requested| {
                    const slot_index = self.districtSlotIndexForLoadRequest(
                        requested.request_id,
                    ) orelse return error.UnexpectedDistrictOutcome;
                    const slot = &self.district_stream_slots[slot_index];
                    if (requested.ticket.coord.x != slot.coord.x or
                        requested.ticket.coord.z != slot.coord.z)
                    {
                        return error.UnexpectedDistrictOutcome;
                    }
                    const admission: DistrictAdmission = switch (slot.state) {
                        .request_submitted => |submitted| .{
                            .scene = submitted.scene,
                            .request_id = submitted.request_id,
                            .content_generation = submitted.content_generation,
                            .cancel = false,
                        },
                        .request_submitted_cancel => |submitted| .{
                            .scene = submitted.scene,
                            .request_id = submitted.request_id,
                            .content_generation = submitted.content_generation,
                            .cancel = true,
                        },
                        else => return error.UnexpectedDistrictOutcome,
                    };
                    try slot.presentation.loadAdmitted(admission.scene, requested.ticket);
                    self.recordDistrictStreamTransition(
                        slot_index,
                        .info,
                        .streaming,
                        engine.diagnostic_contracts.codes.district_stream_logical_admitted,
                        null,
                    );
                    const bound = DistrictStreamBound{
                        .scene = admission.scene,
                        .ticket = requested.ticket,
                        .load_request_id = admission.request_id,
                        .content_generation = admission.content_generation,
                    };
                    if (admission.cancel) {
                        const cancel_request_id = try takeMonotonicId(
                            &self.district_next_request_id,
                        );
                        try self.simulation.submitDistrict(.{ .cancel_load = .{
                            .request_id = cancel_request_id,
                            .ticket = requested.ticket,
                        } });
                        slot.state = .{ .cancelling_logical = .{
                            .bound = bound,
                            .request_id = cancel_request_id,
                        } };
                        self.recordDistrictStreamTransition(
                            slot_index,
                            .info,
                            .streaming,
                            engine.diagnostic_contracts.codes.district_stream_logical_cancel_submitted,
                            null,
                        );
                    } else {
                        slot.state = .{ .loading = bound };
                    }
                },
                .activated => |activated| {
                    const slot_index = self.districtSlotIndexForTicket(activated.ticket) orelse
                        return error.UnexpectedDistrictOutcome;
                    const slot = &self.district_stream_slots[slot_index];
                    const loading = switch (slot.state) {
                        .loading => |value| value,
                        else => return error.UnexpectedDistrictOutcome,
                    };
                    if (loading.load_request_id != activated.request_id or
                        activated.coord.x != slot.coord.x or activated.coord.z != slot.coord.z)
                    {
                        return error.UnexpectedDistrictOutcome;
                    }
                    try slot.presentation.logicalActivated(activated.ticket);
                    slot.state = .{ .active = loading };
                    const active_ticket = self.simulation.activeDistrictTicketFor(slot.coord) orelse
                        return error.DistrictLogicalStateMismatch;
                    if (!std.meta.eql(active_ticket, activated.ticket)) {
                        return error.DistrictLogicalStateMismatch;
                    }
                    self.recordDistrictStreamTransition(
                        slot_index,
                        .info,
                        .streaming,
                        engine.diagnostic_contracts.codes.district_stream_logical_activated,
                        activated.id,
                    );
                },
                .rejected => |rejected| switch (rejected.command) {
                    .request_load => {
                        const slot_index = self.districtSlotIndexForLoadRequest(
                            rejected.request_id,
                        ) orelse return error.UnexpectedDistrictOutcome;
                        const slot = &self.district_stream_slots[slot_index];
                        const submitted = switch (slot.state) {
                            .request_submitted, .request_submitted_cancel => |value| value,
                            else => return error.UnexpectedDistrictOutcome,
                        };
                        self.clearPendingDistrictScene(slot_index);
                        self.recordDistrictStreamTransition(
                            slot_index,
                            .err,
                            .streaming,
                            engine.diagnostic_contracts.codes.district_stream_logical_failed,
                            null,
                        );
                        try self.rejectReservedDistrict(
                            slot_index,
                            submitted.scene,
                            submitted.content_generation,
                        );
                        return error.DistrictLoadRejected;
                    },
                    .cancel_load => {
                        const ticket = rejected.ticket orelse
                            return error.UnexpectedDistrictOutcome;
                        const slot_index = self.districtSlotIndexForTicket(ticket) orelse
                            return error.UnexpectedDistrictOutcome;
                        const cancelling = switch (self.district_stream_slots[slot_index].state) {
                            .cancelling_logical => |value| value,
                            else => return error.UnexpectedDistrictOutcome,
                        };
                        if (cancelling.request_id != rejected.request_id) {
                            return error.UnexpectedDistrictOutcome;
                        }
                        return error.DistrictCancelRejected;
                    },
                    .unload => {
                        const ticket = rejected.ticket orelse
                            return error.UnexpectedDistrictOutcome;
                        const slot_index = self.districtSlotIndexForTicket(ticket) orelse
                            return error.UnexpectedDistrictOutcome;
                        const unloading = switch (self.district_stream_slots[slot_index].state) {
                            .unloading => |value| value,
                            else => return error.UnexpectedDistrictOutcome,
                        };
                        if (unloading.request_id != rejected.request_id) {
                            return error.UnexpectedDistrictOutcome;
                        }
                        return error.DistrictUnloadRejected;
                    },
                },
                .cancelled => |cancelled| {
                    const slot_index = self.districtSlotIndexForTicket(cancelled.ticket) orelse
                        return error.UnexpectedDistrictOutcome;
                    const slot = &self.district_stream_slots[slot_index];
                    const cancelling = switch (slot.state) {
                        .cancelling_logical => |value| value,
                        else => return error.UnexpectedDistrictOutcome,
                    };
                    self.clearPendingDistrictScene(slot_index);
                    try slot.presentation.loadTerminated(cancelled.ticket);
                    self.recordDistrictStreamTransition(
                        slot_index,
                        .info,
                        .streaming,
                        engine.diagnostic_contracts.codes.district_stream_logical_cancelled,
                        null,
                    );
                    self.recordDistrictStreamTransition(
                        slot_index,
                        .warning,
                        .rendering,
                        engine.diagnostic_contracts.codes.district_stream_gpu_release_requested,
                        null,
                    );
                    slot.state = .{ .draining = .{
                        .scene = cancelling.bound.scene,
                        .content_generation = cancelling.bound.content_generation,
                    } };
                },
                .load_failed => |failed| {
                    const slot_index = self.districtSlotIndexForTicket(failed.ticket) orelse
                        return error.UnexpectedDistrictOutcome;
                    const slot = &self.district_stream_slots[slot_index];
                    const loading = switch (slot.state) {
                        .loading => |value| value,
                        .cancelling_logical => |value| value.bound,
                        else => return error.UnexpectedDistrictOutcome,
                    };
                    if (loading.load_request_id != failed.request_id) {
                        return error.UnexpectedDistrictOutcome;
                    }
                    self.clearPendingDistrictScene(slot_index);
                    try slot.presentation.loadTerminated(failed.ticket);
                    self.recordDistrictStreamTransition(
                        slot_index,
                        .err,
                        .streaming,
                        engine.diagnostic_contracts.codes.district_stream_logical_failed,
                        null,
                    );
                    self.recordDistrictStreamTransition(
                        slot_index,
                        .warning,
                        .rendering,
                        engine.diagnostic_contracts.codes.district_stream_gpu_release_requested,
                        null,
                    );
                    slot.state = .{ .draining = .{
                        .scene = loading.scene,
                        .content_generation = loading.content_generation,
                    } };
                    return error.DistrictLogicalLoadFailed;
                },
                .unloaded => |unloaded| {
                    const slot_index = self.districtSlotIndexForTicket(unloaded.ticket) orelse
                        return error.UnexpectedDistrictOutcome;
                    const slot = &self.district_stream_slots[slot_index];
                    const unloading = switch (slot.state) {
                        .unloading => |value| value,
                        else => return error.UnexpectedDistrictOutcome,
                    };
                    if (unloading.request_id != unloaded.request_id) {
                        return error.UnexpectedDistrictOutcome;
                    }
                    self.clearPendingDistrictScene(slot_index);
                    try slot.presentation.logicalUnloaded(unloaded.ticket);
                    self.recordDistrictStreamTransition(
                        slot_index,
                        .info,
                        .streaming,
                        engine.diagnostic_contracts.codes.district_stream_logical_unloaded,
                        unloaded.id,
                    );
                    self.recordDistrictStreamTransition(
                        slot_index,
                        .warning,
                        .rendering,
                        engine.diagnostic_contracts.codes.district_stream_gpu_release_requested,
                        null,
                    );
                    const draws = try self.simulation.districtPresentation();
                    for (draws) |draw| {
                        if (std.meta.eql(draw.ticket, unloaded.ticket)) {
                            return error.DistrictPresentationStillExtracted;
                        }
                    }
                    try slot.presentation.presentationAbsent(0);
                    if (self.simulation.districtStateFor(slot.coord) != null) {
                        return error.DistrictLogicalStateMismatch;
                    }
                    slot.state = .{ .draining = .{
                        .scene = unloading.bound.scene,
                        .content_generation = unloading.bound.content_generation,
                    } };
                },
                .cancellation_requested => |requested| {
                    const slot_index = self.districtSlotIndexForTicket(requested.ticket) orelse
                        return error.UnexpectedDistrictOutcome;
                    const cancelling = switch (self.district_stream_slots[slot_index].state) {
                        .cancelling_logical => |value| value,
                        else => return error.UnexpectedDistrictOutcome,
                    };
                    if (cancelling.request_id != requested.request_id) {
                        return error.UnexpectedDistrictOutcome;
                    }
                },
            }
        }
        while (self.simulation.pollDistrictEvent()) |_| {}
    }

    /// Submit one device-independent action sample before each fixed tick.
    fn simulateTick(
        self: *App,
        comptime validation_composition: bool,
        scenario: ScriptedScenario,
    ) !void {
        const actions: sandbox_controls.TickSample = if (validation_composition)
            switch (scenario) {
                .none => self.action_latch.takeTick(),
                .s1_character => sandbox_controls.TickSample{
                    .move = .{ 0, 1 },
                    .look_delta = .{ 0, 0 },
                    .jump_pressed = self.simulation.tickIndex() == 60,
                    .interact_pressed = false,
                    .brake = false,
                    .hand_brake = false,
                },
                .s2_vehicle => sandbox_controls.TickSample{
                    .move = .{ 0, 0 },
                    .look_delta = .{ 0, 0 },
                    .jump_pressed = false,
                    .interact_pressed = false,
                    .brake = false,
                    .hand_brake = false,
                },
                .s3_streaming => sandbox_controls.TickSample{
                    .move = .{ 0, 0 },
                    .look_delta = .{ 0, 0 },
                    .jump_pressed = false,
                    .interact_pressed = false,
                    .brake = false,
                    .hand_brake = false,
                },
                .s4_physics_debug => sandbox_controls.TickSample{
                    .move = .{ 0, 0 },
                    .look_delta = .{ 0, 0 },
                    .jump_pressed = false,
                    .interact_pressed = false,
                    .brake = false,
                    .hand_brake = false,
                },
                .s7_interaction => sandbox_controls.TickSample{
                    .move = self.validation.s7_scripted_move,
                    .look_delta = .{ 0, 0 },
                    .jump_pressed = false,
                    .interact_pressed = false,
                    .brake = false,
                    .hand_brake = false,
                },
            }
        else
            self.action_latch.takeTick();
        self.game_camera.rotate(actions.look_delta[0], actions.look_delta[1]);

        if (validation_composition) {
            switch (scenario) {
                .none => try self.submitInteractiveActions(actions),
                .s1_character => if (self.initial_character_id) |id| {
                    try self.submitCharacterActions(id, actions);
                },
                .s2_vehicle => try self.submitInteractiveActions(self.s2ScriptedActions()),
                .s3_streaming, .s4_physics_debug => {},
                .s7_interaction => if (self.validation.s7_character_actions_enabled) if (self.initial_character_id) |id| {
                    try self.submitCharacterActions(id, actions);
                },
            }
        } else {
            try self.submitInteractiveActions(actions);
        }
        var runtime_profile = RuntimeProfileBridge{
            .recorder = &self.developer_profiler,
            .frame_index = self.frame_timer.total_frames,
        };
        try self.simulation.tickObserved(
            if (self.developer_visualization_controller.profiling_enabled)
                runtime_profile.observer()
            else
                null,
        );
        while (self.simulation.pollOutcome()) |outcome| {
            switch (outcome) {
                .spawned => |spawned| {
                    if (spawned.request_id != 1 or self.initial_crate_id != null) {
                        return error.UnexpectedBootstrapOutcome;
                    }
                    self.initial_crate_id = spawned.id;
                },
                .relocated => {
                    const pending = self.authoring_controller.snapshot().pending;
                    const observed = try self.authoring_controller.observe(outcome);
                    if (observed == .unrelated or pending == null) {
                        return error.UnexpectedAuthoringOutcome;
                    }
                    self.recordAuthoringOutcome(pending.?, observed, null);
                },
                .rejected => |rejected| {
                    if (rejected.command != .relocate) {
                        return error.UnexpectedBootstrapOutcome;
                    }
                    const pending = self.authoring_controller.snapshot().pending;
                    const observed = try self.authoring_controller.observe(outcome);
                    if (observed == .unrelated or pending == null) {
                        return error.UnexpectedAuthoringOutcome;
                    }
                    self.recordAuthoringOutcome(pending.?, observed, rejected.reason);
                },
                .despawned => |id| {
                    self.authoring_controller.invalidateIdentity(id);
                    if (self.initial_crate_id != null and
                        std.meta.eql(self.initial_crate_id.?, id))
                    {
                        self.initial_crate_id = null;
                    }
                },
                .impulse_applied => return error.UnexpectedBootstrapOutcome,
            }
        }
        while (self.simulation.pollCharacterOutcome()) |outcome| {
            switch (outcome) {
                .spawned => |spawned| {
                    if (spawned.request_id != 1 or self.initial_character_id != null) {
                        return error.UnexpectedCharacterBootstrapOutcome;
                    }
                    self.initial_character_id = spawned.id;
                },
                .despawned => |id| if (validation_composition and
                    scenario == .s7_interaction and
                    std.meta.eql(id, self.initial_character_id orelse
                        return error.UnexpectedCharacterBootstrapOutcome))
                {
                    self.initial_character_id = null;
                } else return error.UnexpectedCharacterBootstrapOutcome,
                .rejected => return error.UnexpectedCharacterBootstrapOutcome,
            }
        }
        while (self.simulation.pollCharacterEvent()) |_| {}
        try self.processVehicleOutcomes(validation_composition, scenario);
        while (self.simulation.pollVehicleEvent()) |_| {}
        try self.processDistrictOutcomes();
        try self.processInteractionOutcomes(validation_composition, scenario);
        try self.maybeBootstrapCarryable(validation_composition, scenario);
        if (try self.districtFocusPosition()) |position_xz| {
            try self.updateDistrictProximity(position_xz);
        }
        if (validation_composition and scenario == .s2_vehicle) try self.observeS2State();
        self.extractPhysicsDebug();
    }

    fn authoringCrateView(
        self: *App,
        id: sandbox_host.PersistentId,
    ) !?editor_contract.AuthoringCrateView {
        const view = self.simulation.crate(id) catch |err| switch (err) {
            error.CrateNotFound, error.NotACrate => return null,
            else => return err,
        };
        return .{
            .id = view.id,
            .state = view.state,
            .authoring_revision = view.authoring_revision,
        };
    }

    fn crateAuthoringView(self: *App) !editor_contract.CrateAuthoringView {
        var session = self.authoring_controller.snapshot();
        var selected: ?editor_contract.AuthoringCrateView = null;
        if (session.selected) |id| {
            selected = try self.authoringCrateView(id);
            if (selected == null) {
                self.authoring_controller.invalidateIdentity(id);
                session = self.authoring_controller.snapshot();
            }
        }
        const available = if (self.initial_crate_id) |id|
            try self.authoringCrateView(id)
        else
            null;
        return .{
            .session = session,
            .available_crate = available,
            .selected_crate = selected,
            .feedback = self.authoring_feedback,
            .save = self.save_feedback,
            .request_rejections = self.authoring_requests.rejected,
        };
    }

    fn interactionEditorView(self: *App) !editor_contract.InteractionView {
        var result = editor_contract.InteractionView{
            .next_transaction_id = self.interaction_transactions.peek(),
            .last_outcome = self.interaction_last_outcome,
            .submission_failures = self.interaction_submission_failures,
            .request_rejections = self.interaction_requests.rejected,
        };
        // Fault inspection intentionally avoids feature/backend extraction.
        if (self.simulation.firstFault() != null) return result;
        if (self.initial_character_id) |id| {
            result.carrier = self.simulation.character(id) catch |err| switch (err) {
                error.CharacterNotFound, error.NotACharacter => null,
                else => return err,
            };
        }
        if (self.initial_carryable_id) |id| {
            result.carryable = self.simulation.carryable(id) catch |err| switch (err) {
                error.InteractionCarryableNotFound,
                error.InteractionCarryableNotOwned,
                => null,
                else => return err,
            };
        }
        return result;
    }

    fn applyInteractionRequests(
        self: *App,
        requests: []const sandbox_interaction.Request,
    ) !void {
        for (requests) |request| {
            const transaction_id = switch (request) {
                .collect => |value| value.transaction_id,
                .drop => |value| value.transaction_id,
                .spawn, .despawn => {
                    self.interaction_submission_failures +|= 1;
                    continue;
                },
            };
            const expected = self.interaction_transactions.peek() orelse {
                self.interaction_submission_failures +|= 1;
                continue;
            };
            if (transaction_id != expected) {
                self.interaction_submission_failures +|= 1;
                continue;
            }
            _ = try self.interaction_transactions.take();
            self.simulation.submitInteraction(request) catch |err| {
                self.interaction_submission_failures +|= 1;
                return err;
            };
        }
    }

    fn advanceAuthoringFeedback(self: *App) u64 {
        self.authoring_feedback.sequence +|= 1;
        return self.authoring_feedback.sequence;
    }

    fn recordAuthoringOutcome(
        self: *App,
        pending: sandbox_authoring.PendingSummary,
        observed: sandbox_authoring.ObserveResult,
        rejection_reason: ?sandbox_host.RejectionReason,
    ) void {
        _ = self.advanceAuthoringFeedback();
        self.authoring_feedback = .{
            .sequence = self.authoring_feedback.sequence,
            .status = switch (observed) {
                .applied => .applied,
                .rejected => .rejected,
                .unrelated => unreachable,
            },
            .operation = pending.kind,
            .transaction_id = pending.transaction_id,
            .id = pending.id,
            .rejection_reason = switch (observed) {
                .applied => null,
                .rejected => rejection_reason orelse unreachable,
                .unrelated => unreachable,
            },
            .detail = switch (observed) {
                .applied => "authoritative relocation committed",
                .rejected => authoringRejectionDetail(rejection_reason orelse unreachable),
                .unrelated => unreachable,
            },
        };
    }

    fn recordAuthoringRequestRejection(
        self: *App,
        operation: ?sandbox_authoring.OperationKind,
        id: ?sandbox_host.PersistentId,
        err: anyerror,
    ) void {
        _ = self.advanceAuthoringFeedback();
        self.authoring_feedback = .{
            .sequence = self.authoring_feedback.sequence,
            .status = .rejected,
            .operation = operation,
            .id = id,
            .detail = @errorName(err),
        };
    }

    fn submitAuthoringCommand(
        self: *App,
        command: sandbox_host.Command,
        operation: sandbox_authoring.OperationKind,
    ) !void {
        self.simulation.submit(command) catch |err| {
            const relocation = command.relocate;
            _ = self.authoring_controller.submissionFailed(relocation.transaction_id);
            _ = self.advanceAuthoringFeedback();
            self.authoring_feedback = .{
                .sequence = self.authoring_feedback.sequence,
                .status = .submission_failed,
                .operation = operation,
                .transaction_id = relocation.transaction_id,
                .id = relocation.id,
                .detail = @errorName(err),
            };
            return err;
        };
    }

    fn applyAuthoringRequests(
        self: *App,
        requests: []const sandbox_authoring.Request,
    ) !void {
        for (requests) |request| switch (request) {
            .select => |id| self.authoring_controller.select(id) catch |err| {
                self.recordAuthoringRequestRejection(null, id, err);
                continue;
            },
            .clear_selection => self.authoring_controller.clearSelection(),
            .relocate => |relocation| {
                const view = self.simulation.crate(relocation.id) catch |err| switch (err) {
                    error.CrateNotFound, error.NotACrate => {
                        self.authoring_controller.invalidateIdentity(relocation.id);
                        self.recordAuthoringRequestRejection(.edit, relocation.id, err);
                        continue;
                    },
                    else => return err,
                };
                const command = self.authoring_controller.beginEdit(
                    relocation,
                    view.authoring_revision,
                ) catch |err| {
                    self.recordAuthoringRequestRejection(.edit, relocation.id, err);
                    continue;
                };
                try self.submitAuthoringCommand(command, .edit);
            },
            .undo => {
                const command = self.authoring_controller.beginUndo() catch |err| {
                    self.recordAuthoringRequestRejection(.undo, null, err);
                    continue;
                };
                try self.submitAuthoringCommand(command, .undo);
            },
            .redo => {
                const command = self.authoring_controller.beginRedo() catch |err| {
                    self.recordAuthoringRequestRejection(.redo, null, err);
                    continue;
                };
                try self.submitAuthoringCommand(command, .redo);
            },
            .save => try self.commitAuthoringSave(),
        };
    }

    fn advanceSaveFeedback(self: *App) u64 {
        self.save_feedback.sequence +|= 1;
        return self.save_feedback.sequence;
    }

    fn setSaveFeedback(
        self: *App,
        status: editor_contract.SaveFeedbackStatus,
        detail: []const u8,
    ) void {
        _ = self.advanceSaveFeedback();
        self.save_feedback = .{
            .sequence = self.save_feedback.sequence,
            .status = status,
            .slot_label = sandbox_save_slot_id,
            .detail = detail,
        };
    }

    fn commitAuthoringSave(self: *App) !void {
        const store = if (self.save_store) |*value| value else {
            self.setSaveFeedback(.unavailable, "start with --save-root=<absolute-existing-directory>");
            return;
        };
        const metadata = self.save_metadata orelse return error.SaveMetadataMissing;
        if (self.authoring_controller.snapshot().pending != null) {
            self.setSaveFeedback(.not_committed, "authoring transaction pending");
            return;
        }
        const payload = self.simulation.save(std.heap.page_allocator) catch |err| {
            if (saveDeferralDetail(err)) |detail| {
                self.setSaveFeedback(.not_committed, detail);
                return;
            }
            return err;
        };
        defer std.heap.page_allocator.free(payload);
        const envelope = try sandbox_save.encode(
            std.heap.page_allocator,
            metadata,
            payload,
        );
        defer std.heap.page_allocator.free(envelope);
        const result = store.commit(
            self.io,
            try save_slots.SlotId.parse(sandbox_save_slot_id),
            envelope,
            .{ .max_file_bytes = sandbox_save.max_envelope_bytes },
        );
        switch (result) {
            .committed => self.setSaveFeedback(.committed, "atomic replace and sync complete"),
            .committed_sync_warning => self.setSaveFeedback(
                .committed_sync_warning,
                "atomic replace committed; directory sync uncertain",
            ),
            .not_committed => self.setSaveFeedback(
                .not_committed,
                "previous committed slot retained",
            ),
        }
    }

    fn extractPhysicsDebug(self: *App) void {
        const config = self.developer_visualization_controller.config;
        if (!config.enabled) return;
        const cpu = if (self.physics_debug_cpu) |*owner| owner else {
            self.physics_debug_batch_summary = null;
            return;
        };

        var profile_scope = self.beginHostProfile(
            .debug_extraction,
            self.frame_timer.total_frames,
            self.simulation.tickIndex(),
        );
        const batch = self.simulation.extractPhysicsDebug(.{
            .shapes = config.shapes,
            .bounds = config.bounds,
            .contacts = config.contacts,
            .centers_of_mass = config.centers_of_mass,
            .velocities = config.velocities,
        }, &cpu.storage) catch {
            profile_scope.finish(.failure);
            self.developer_visualization_controller.config.enabled = false;
            if (self.physics_debug_overlay) |*overlay| _ = overlay.setEnabled(false);
            return;
        };
        self.physics_debug_batch_summary = developer_visualization.BatchSummary.fromBatch(batch);
        if (build_options.validation_mode or builtin.is_test) {
            self.validation.s4_physics_debug_evidence.observe(batch);
        }
        profile_scope.finish(.success);
    }

    fn uploadPhysicsDebug(self: *App) void {
        const config = self.developer_visualization_controller.config;
        if (!config.enabled) return;
        const cpu = if (self.physics_debug_cpu) |*owner| owner else return;
        const batch = cpu.storage.batch() orelse return;
        const overlay = if (self.physics_debug_overlay) |*value| value else return;
        const before = overlay.stats();
        if (before.latest_attempted_generation == batch.generation) return;

        var profile_scope = self.beginHostProfile(
            .debug_upload,
            self.frame_timer.total_frames,
            batch.completed_tick,
        );
        const result = overlay.upload(batch);
        if (result.status == .copy_submitted) {
            self.mergeProfileCounts(.{
                .debug_primitives = @as(u64, result.plan.admitted_lines) +
                    result.plan.admitted_triangles,
                .debug_upload_bytes = result.plan.totalBytes(),
            });
        }
        profile_scope.finish(if (result.status.isFailure()) .failure else .success);
    }

    fn drawPhysicsDebug(self: *App, view_projection: zm.Mat) void {
        if (!self.developer_visualization_controller.config.enabled) return;
        const cpu = if (self.physics_debug_cpu) |*owner| owner else return;
        _ = cpu.storage.batch() orelse return;
        const overlay = if (self.physics_debug_overlay) |*value| value else return;

        // The asynchronous retained GPU generation may lag the newest CPU
        // batch. Keep this host span frame-scoped rather than attributing its
        // work to a simulation tick it may not actually visualize.
        var profile_scope = self.beginHostProfile(
            .debug_draw,
            self.frame_timer.total_frames,
            null,
        );
        const before = overlay.stats();
        const result = overlay.drawLatest(&self.gpu_renderer, view_projection);
        const after = overlay.stats();
        self.mergeProfileCounts(.{
            .draw_calls = (after.line_draw_calls -| before.line_draw_calls) +
                (after.triangle_draw_calls -| before.triangle_draw_calls),
        });
        profile_scope.finish(switch (result.status) {
            .drawn, .empty => .success,
            else => .failure,
        });
    }

    /// Submit one renderer frame while transferring an optional debug-slot
    /// read fence to the bounded overlay owner.
    fn submitCurrentFrame(self: *App) !void {
        const needs_debug_fence = if (self.physics_debug_overlay) |*overlay|
            overlay.needsFrameFence()
        else
            false;
        if (!needs_debug_fence) return self.gpu_renderer.submitFrame();

        // First submit the real frame through the ordinary fallible path. A
        // renderer/device failure remains a renderer failure and propagates.
        try self.gpu_renderer.submitFrame();

        // Then enqueue an empty same-queue command whose fence covers that
        // already-successful frame. Losing only this optional fence retires
        // debug evidence without hiding frame-submission failure.
        const fence = self.gpu_renderer.acquirePostSubmissionFence() catch {
            if (self.physics_debug_overlay) |*overlay| {
                overlay.noteFrameFenceFailed();
            }
            return;
        };
        if (self.physics_debug_overlay) |*overlay| {
            _ = overlay.noteFrameSubmitted(fence);
        } else {
            c.SDL_ReleaseGPUFence(self.gpu_renderer.getDevice(), fence);
        }
    }

    fn submitInteractiveActions(
        self: *App,
        actions: sandbox_controls.TickSample,
    ) !void {
        if (actions.carry_pressed) {
            try self.submitInteractionToggle();
            return;
        }
        if (actions.interact_pressed) {
            const character_id = self.initial_character_id orelse return;
            const vehicle_id = self.initial_vehicle_id orelse return;
            if (self.controlled_vehicle_id) |controlled_id| {
                try self.simulation.submitVehicle(.{ .exit = .{
                    .vehicle_id = controlled_id,
                    .driver_id = character_id,
                } });
            } else {
                try self.simulation.submitVehicle(.{ .enter = .{
                    .vehicle_id = vehicle_id,
                    .driver_id = character_id,
                } });
            }
            // Authority transitions consume the tick without applying the same
            // frame sample to either locomotion target.
            return;
        }

        if (self.controlled_vehicle_id) |vehicle_id| {
            const character_id = self.initial_character_id orelse
                return error.ControlledVehicleMissingCharacter;
            try self.simulation.submitVehicle(.{ .drive = .{
                .vehicle_id = vehicle_id,
                .driver_id = character_id,
                .input = .{
                    .throttle = actions.move[1],
                    .steering = actions.move[0],
                    .brake = if (actions.brake) 1 else 0,
                    .hand_brake = if (actions.hand_brake) 1 else 0,
                },
            } });
        } else if (self.initial_character_id) |character_id| {
            try self.submitCharacterActions(character_id, actions);
        }
    }

    fn submitInteractionToggle(self: *App) !void {
        if (self.controlled_vehicle_id != null) return;
        const carrier_id = self.initial_character_id orelse return;
        const carryable_id = self.initial_carryable_id orelse return;
        const view = try self.simulation.carryable(carryable_id);
        const transaction_id = try self.interaction_transactions.take();
        const command: sandbox_host.InteractionCommand = switch (view.ownership) {
            .district_owned => .{ .collect = .{
                .transaction_id = transaction_id,
                .carrier_id = carrier_id,
                .carryable_id = carryable_id,
            } },
            .inventory_held => |holder| if (std.meta.eql(holder, carrier_id))
                .{ .drop = .{
                    .transaction_id = transaction_id,
                    .carrier_id = carrier_id,
                    .carryable_id = carryable_id,
                } }
            else
                return error.InteractionCarryableHeldByAnotherCarrier,
        };
        self.simulation.submitInteraction(command) catch |err| {
            self.interaction_submission_failures +|= 1;
            return err;
        };
    }

    fn maybeBootstrapCarryable(
        self: *App,
        comptime validation_composition: bool,
        scenario: ScriptedScenario,
    ) !void {
        if (!self.interaction_spawn_enabled or self.interaction_spawn_submitted or
            self.initial_carryable_id != null or self.initial_character_id == null)
        {
            return;
        }
        if (validation_composition) {
            switch (scenario) {
                .none, .s7_interaction => {},
                else => return,
            }
        }
        if (self.simulation.activeDistrictTicketFor(district_west_coord) == null) return;
        try self.simulation.submitInteraction(.{ .spawn = .{
            .request_id = 1,
            .pose = .{ .position = if (validation_composition and
                scenario == .s7_interaction)
                .{ 1, 0.5, 0 }
            else
                .{ 0, 0.5, 3 } },
        } });
        self.interaction_spawn_submitted = true;
    }

    fn processInteractionOutcomes(
        self: *App,
        comptime validation_composition: bool,
        scenario: ScriptedScenario,
    ) !void {
        while (self.simulation.pollInteractionOutcome()) |outcome| {
            switch (outcome) {
                .spawned => |spawned| {
                    if (spawned.request_id != 1 or self.initial_carryable_id != null) {
                        return error.UnexpectedInteractionSpawnOutcome;
                    }
                    self.initial_carryable_id = spawned.id;
                },
                .despawned => |id| {
                    if (!std.meta.eql(id, self.initial_carryable_id orelse
                        return error.UnexpectedInteractionDespawnOutcome))
                    {
                        return error.UnexpectedInteractionDespawnOutcome;
                    }
                    self.initial_carryable_id = null;
                },
                .collected => |collected| {
                    if (!std.meta.eql(collected.carrier_id, self.initial_character_id orelse
                        return error.UnexpectedInteractionAuthorityOutcome) or
                        !std.meta.eql(collected.carryable_id, self.initial_carryable_id orelse
                            return error.UnexpectedInteractionAuthorityOutcome))
                    {
                        return error.UnexpectedInteractionAuthorityOutcome;
                    }
                },
                .dropped => |dropped| {
                    if (!std.meta.eql(dropped.carrier_id, self.initial_character_id orelse
                        return error.UnexpectedInteractionAuthorityOutcome) or
                        !std.meta.eql(dropped.carryable_id, self.initial_carryable_id orelse
                            return error.UnexpectedInteractionAuthorityOutcome))
                    {
                        return error.UnexpectedInteractionAuthorityOutcome;
                    }
                },
                .rejected => if (validation_composition and
                    scenario == .s7_interaction)
                {
                    return error.S7InteractionCommandRejected;
                },
            }
            // Centralized polling observes every producer outcome. The editor
            // receives the retained value without draining another lane.
            self.interaction_last_outcome = outcome;
        }
    }

    fn bootstrapS7Interaction(self: *App) !void {
        if (self.validation.profile != .s3_smoke or self.simulation.entityCount() != 0) {
            return error.InvalidS7InteractionSmokeComposition;
        }
        try self.simulation.submitCharacter(.{ .spawn = .{
            .request_id = 1,
            .position = .{ 0, 0, 0 },
        } });
        self.interaction_spawn_enabled = true;
        self.district_focus_override = s6_west_only;
    }

    fn submitCharacterActions(
        self: *App,
        character_id: sandbox_host.PersistentId,
        actions: sandbox_controls.TickSample,
    ) !void {
        if (!std.meta.eql(character_id, self.initial_character_id orelse
            return error.LocalPlayerCharacterMissing))
        {
            return error.LocalPlayerCharacterMismatch;
        }
        try self.simulation.submitPlayerInput(.{
            .move = actions.move,
            .facing_yaw = self.game_camera.yaw,
            .jump_pressed = actions.jump_pressed,
        });
    }

    fn s2ScriptedActions(self: *const App) sandbox_controls.TickSample {
        const tick = self.simulation.tickIndex();
        var actions = sandbox_controls.TickSample{
            .move = .{ 0, 0 },
            .look_delta = .{ 0, 0 },
            .jump_pressed = false,
            .interact_pressed = tick == s2_enter_tick or tick == s2_exit_tick,
            .brake = false,
            .hand_brake = false,
        };
        if (tick > s2_enter_tick and tick < s2_exit_tick) {
            actions.move = .{
                if (tick >= s2_steer_tick) 0.65 else 0,
                1,
            };
            actions.brake = tick >= s2_brake_tick and tick < s2_steer_tick;
        }
        return actions;
    }

    fn processVehicleOutcomes(
        self: *App,
        comptime validation_composition: bool,
        scenario: ScriptedScenario,
    ) !void {
        while (self.simulation.pollVehicleOutcome()) |outcome| {
            switch (outcome) {
                .spawned => |spawned| {
                    if (spawned.request_id != 1 or self.initial_vehicle_id != null) {
                        return error.UnexpectedVehicleBootstrapOutcome;
                    }
                    self.initial_vehicle_id = spawned.id;
                },
                .entered => |entered| {
                    if (self.controlled_vehicle_id != null or
                        !std.meta.eql(entered.vehicle_id, self.initial_vehicle_id orelse
                            return error.UnexpectedVehicleAuthorityOutcome) or
                        !std.meta.eql(entered.driver_id, self.initial_character_id orelse
                            return error.UnexpectedVehicleAuthorityOutcome))
                    {
                        return error.UnexpectedVehicleAuthorityOutcome;
                    }
                    self.controlled_vehicle_id = entered.vehicle_id;
                    if (validation_composition and scenario == .s2_vehicle) {
                        self.validation.s2_smoke.entered = true;
                        self.validation.s2_smoke.vehicle_position_before_drive =
                            (try self.simulation.vehicle(entered.vehicle_id)).state.chassis.pose.position;
                        const crate_id = self.initial_crate_id orelse
                            return error.S2VisualSmokeCrateSpawnMissing;
                        self.validation.s2_smoke.crate_position_before_drive =
                            (try self.simulation.crate(crate_id)).state.pose.position;
                    }
                },
                .drive_applied => |applied| {
                    if (!std.meta.eql(applied.vehicle_id, self.controlled_vehicle_id orelse
                        return error.UnexpectedVehicleDriveOutcome) or
                        !std.meta.eql(applied.driver_id, self.initial_character_id orelse
                            return error.UnexpectedVehicleDriveOutcome))
                    {
                        return error.UnexpectedVehicleDriveOutcome;
                    }
                    if (validation_composition and scenario == .s2_vehicle) {
                        self.validation.s2_smoke.drive_applied = true;
                        self.validation.s2_smoke.steering_applied = self.validation.s2_smoke.steering_applied or
                            @abs(applied.input.steering) > 0.1;
                        self.validation.s2_smoke.brake_applied = self.validation.s2_smoke.brake_applied or
                            applied.input.brake > 0.5;
                    }
                },
                .exited => |exited| {
                    if (!std.meta.eql(exited.vehicle_id, self.controlled_vehicle_id orelse
                        return error.UnexpectedVehicleAuthorityOutcome) or
                        !std.meta.eql(exited.driver_id, self.initial_character_id orelse
                            return error.UnexpectedVehicleAuthorityOutcome))
                    {
                        return error.UnexpectedVehicleAuthorityOutcome;
                    }
                    self.controlled_vehicle_id = null;
                    if (validation_composition and scenario == .s2_vehicle) {
                        self.validation.s2_smoke.exited = true;
                    }
                },
                .abandoned => return error.UnexpectedVehicleAbandonOutcome,
                .rejected => |rejected| if (validation_composition) switch (scenario) {
                    .s1_character, .s2_vehicle, .s3_streaming, .s4_physics_debug, .s7_interaction => return error.ScriptedVehicleCommandRejected,
                    .none => if (interactiveVehicleRejectionExpected(rejected)) {
                        // Interactive domain rejections are healthy outcomes,
                        // not host failures. Preserve them in the bounded
                        // diagnostic journal so the editor/JSON consumer can
                        // explain why the attempted transition did not occur.
                        _ = self.simulation.recordDiagnostic(.{
                            .severity = .info,
                            .category = .command,
                            .code = diagnostic_interactive_vehicle_rejected,
                            .tick_index = self.simulation.tickIndex(),
                            .frame_index = self.frame_timer.total_frames,
                            .thread_role = .host,
                            .thread_id = engine.diagnostics.currentThreadId(),
                            .persistent_id = rejected.vehicle_id,
                            .correlation_id = @as(u64, @intFromEnum(rejected.reason)) + 1,
                        });
                    } else return error.UnexpectedVehicleCommandRejection,
                } else if (interactiveVehicleRejectionExpected(rejected)) {
                    _ = self.simulation.recordDiagnostic(.{
                        .severity = .info,
                        .category = .command,
                        .code = diagnostic_interactive_vehicle_rejected,
                        .tick_index = self.simulation.tickIndex(),
                        .frame_index = self.frame_timer.total_frames,
                        .thread_role = .host,
                        .thread_id = engine.diagnostics.currentThreadId(),
                        .persistent_id = rejected.vehicle_id,
                        .correlation_id = @as(u64, @intFromEnum(rejected.reason)) + 1,
                    });
                } else return error.UnexpectedVehicleCommandRejection,
                .despawned => return error.UnexpectedVehicleBootstrapOutcome,
            }
        }
    }

    fn observeS2State(self: *App) !void {
        if (!self.validation.s2_smoke.entered or self.validation.s2_smoke.exited) return;
        const vehicle_id = self.initial_vehicle_id orelse
            return error.S2VisualSmokeVehicleSpawnMissing;
        const vehicle = try self.simulation.vehicle(vehicle_id);
        if (self.validation.s2_smoke.vehicle_position_before_drive) |before| {
            self.validation.s2_smoke.vehicle_moved = self.validation.s2_smoke.vehicle_moved or
                distanceSquared(before, vehicle.state.chassis.pose.position) > 1;
        }
        self.validation.s2_smoke.steering_observed = self.validation.s2_smoke.steering_observed or
            @abs(vehicle.state.wheels[0].steer_angle) > 0.05 or
            @abs(vehicle.state.wheels[1].steer_angle) > 0.05;
        if (self.validation.s2_smoke.crate_position_before_drive) |before| {
            const crate_id = self.initial_crate_id orelse
                return error.S2VisualSmokeCrateSpawnMissing;
            const position = (try self.simulation.crate(crate_id)).state.pose.position;
            self.validation.s2_smoke.crate_displaced = self.validation.s2_smoke.crate_displaced or
                distanceSquared(before, position) > 0.04;
        }
    }

    /// Render the current frame using SDL3 GPU API
    /// `alpha` is the interpolation factor (0.0 to 1.0) for smooth visuals.
    fn render(self: *App, alpha: f32) !RenderResult {
        // Streamed submissions are independent of the frame command buffer.
        // Poll fences without waiting, then submit at most one bounded batch.
        var stream_gpu_profile = self.beginHostProfile(
            .stream_gpu_pump,
            self.frame_timer.total_frames,
            self.simulation.tickIndex(),
        );
        defer stream_gpu_profile.finish(.failure);
        if (build_options.validation_mode or builtin.is_test) {
            if (self.validation.s4_fault_loop_probe) |probe| probe.gpu_pump_calls += 1;
        }
        var residency_before: [district_stream_slot_count]?district_gpu_registry.Residency =
            @splat(null);
        for (self.district_stream_slots, 0..) |slot, slot_index| {
            if (districtSceneHandle(slot.state)) |scene| {
                residency_before[slot_index] = try self.districtResidency(scene);
            }
        }
        const district_gpu_progress = try self.district_registry.pump();
        for (self.district_stream_slots, 0..) |slot, slot_index| {
            const scene = districtSceneHandle(slot.state) orelse continue;
            const after = try self.districtResidency(scene) orelse continue;
            if (after == .submitted and residency_before[slot_index] != .submitted) {
                self.recordDistrictStreamTransition(
                    slot_index,
                    .info,
                    .rendering,
                    engine.diagnostic_contracts.codes.district_stream_gpu_submitted,
                    null,
                );
            }
            if (after == .resident and residency_before[slot_index] != .resident) {
                self.recordDistrictStreamTransition(
                    slot_index,
                    .info,
                    .rendering,
                    engine.diagnostic_contracts.codes.district_stream_gpu_resident,
                    null,
                );
            }
        }
        if (district_gpu_progress.published_scenes > 0) {
            std.debug.print(
                "Cooked district GPU resident: scenes={d} bytes={d}\n",
                .{
                    district_gpu_progress.published_scenes,
                    (try self.district_registry.stats()).resident_gpu_bytes,
                },
            );
        }
        const district_gpu_stats = try self.district_registry.stats();
        self.mergeProfileCounts(.{
            .streaming_submissions = district_gpu_progress.submitted_scenes,
            .streaming_publishes = district_gpu_progress.published_scenes,
            .live_resources = district_gpu_stats.live_scenes,
            .live_resource_bytes = district_gpu_stats.staged_cpu_bytes +|
                district_gpu_stats.staged_upload_bytes +|
                district_gpu_stats.in_flight_upload_bytes +|
                district_gpu_stats.resident_gpu_bytes,
        });
        stream_gpu_profile.finish(.success);
        if (self.physics_debug_overlay) |*overlay| {
            _ = overlay.poll();
            const debug_resources = overlay.stats().resources;
            self.mergeProfileCounts(.{
                .live_resources = @as(u64, debug_resources.gpu_buffer_count) +
                    debug_resources.transfer_buffer_count +
                    debug_resources.live_owned_fences,
                .live_resource_bytes = debug_resources.gpu_bytes +|
                    debug_resources.transfer_bytes,
            });
        }
        self.uploadPhysicsDebug();

        // Begin the frame (clears screen)
        switch (try self.gpu_renderer.beginFrame(renderer.Colors.CORNFLOWER_BLUE)) {
            .ready => {},
            .unavailable => {
                // Wait briefly without removing the next event from SDL's
                // queue. This keeps minimized windows responsive without
                // turning the main loop into a busy spin.
                _ = c.SDL_WaitEventTimeout(null, 16);
                return .unavailable;
            },
        }

        // Calculate aspect ratio from window dimensions
        const window_size = self.gpu_renderer.getWindowSize();
        const aspect_ratio = @as(f32, @floatFromInt(window_size.width)) /
            @as(f32, @floatFromInt(window_size.height));

        var scene_extraction_profile = self.beginHostProfile(
            .scene_extraction,
            self.frame_timer.total_frames,
            self.simulation.tickIndex(),
        );
        defer scene_extraction_profile.finish(.failure);
        const character_draws = try self.simulation.characterPresentation(alpha);
        const vehicle_draws = try self.simulation.vehiclePresentation(alpha);
        const district_draws = try self.simulation.districtPresentation();
        const crate_draws = try self.simulation.presentation(alpha);
        const carryable_draws = try self.simulation.interactionPresentation();
        const npc_draws = try self.simulation.npcPresentation(alpha);
        if (self.controlled_vehicle_id) |controlled_id| {
            var vehicle_found = false;
            for (vehicle_draws) |draw| {
                if (std.meta.eql(draw.persistent_id, controlled_id)) {
                    self.game_camera.followTarget(.{
                        draw.chassis_pose.position[0],
                        draw.chassis_pose.position[1] + 1,
                        draw.chassis_pose.position[2],
                    }, 8.0);
                    vehicle_found = true;
                    break;
                }
            }
            if (!vehicle_found) return error.ControlledVehiclePresentationMissing;
        } else if (self.initial_character_id) |player_id| {
            var player_found = false;
            for (character_draws) |draw| {
                if (std.meta.eql(draw.persistent_id, player_id)) {
                    self.game_camera.followTarget(draw.camera_target, 6.0);
                    player_found = true;
                    break;
                }
            }
            if (!player_found) return error.PlayerPresentationMissing;
        }

        // Get view-projection matrix from camera
        const view_proj = self.game_camera.getViewProjectionMatrix(aspect_ratio);
        scene_extraction_profile.finish(.success);

        var scene_draw_profile = self.beginHostProfile(
            .scene_draw,
            self.frame_timer.total_frames,
            self.simulation.tickIndex(),
        );
        defer scene_draw_profile.finish(.failure);
        var scene_draw_calls: u64 = 0;

        // The ground is a visual-host fixture matching the simulation-owned
        // static body. Feature-owned entities arrive through extraction below.
        self.gpu_renderer.drawMesh(&self.ground_mesh, zm.identity(), view_proj);
        scene_draw_calls +|= 1;
        const draws_block = if (build_options.validation_mode or builtin.is_test)
            self.validation.profile == .sandbox or self.validation.profile == .s1_smoke
        else
            true;
        if (draws_block) {
            const block_scale = zm.scaling(
                sandbox_block.half_extents[0] * 2,
                sandbox_block.half_extents[1] * 2,
                sandbox_block.half_extents[2] * 2,
            );
            const block_translation = zm.translation(
                sandbox_block.position[0],
                sandbox_block.position[1],
                sandbox_block.position[2],
            );
            self.gpu_renderer.drawMesh(
                &self.block_mesh,
                zm.mul(block_scale, block_translation),
                view_proj,
            );
            scene_draw_calls +|= 1;
        }

        for (district_draws) |draw| {
            const slot_index = self.districtSlotIndexForCoord(draw.build.coord) orelse
                return error.DistrictPresentationSlotMissing;
            const scene = try self.district_stream_slots[slot_index].presentation.resolve(
                draw.ticket,
                draw.assets.scene,
            );
            if (scene.meshes().len == 0) {
                // Logical activation is visible immediately, even while a
                // cooked scene is staged or its Metal fence is unsignaled.
                for (draw.build.boxes()) |box| {
                    const scale = zm.scaling(
                        box.half_extents[0] * 2,
                        box.half_extents[1] * 2,
                        box.half_extents[2] * 2,
                    );
                    const rotation = zm.quatToMat(zm.f32x4(
                        box.pose.rotation[0],
                        box.pose.rotation[1],
                        box.pose.rotation[2],
                        box.pose.rotation[3],
                    ));
                    const translation = zm.translation(
                        box.pose.position[0],
                        box.pose.position[1],
                        box.pose.position[2],
                    );
                    self.gpu_renderer.drawMesh(
                        &self.block_mesh,
                        zm.mul(zm.mul(scale, rotation), translation),
                        view_proj,
                    );
                    scene_draw_calls +|= 1;
                }
            } else {
                for (scene.instances()) |instance| {
                    if (instance.mesh_index >= scene.meshes().len) {
                        return error.DistrictResidentInstanceInvalid;
                    }
                    const resident_mesh = scene.meshes()[instance.mesh_index];
                    const texture_view = scene.materialTexture(resident_mesh.material_index);
                    const base_color = scene.materialBaseColor(resident_mesh.material_index);
                    const authored_transform = zm.loadMat(instance.transform[0..]);
                    self.gpu_renderer.drawMeshWithMaterial(
                        resident_mesh.mesh,
                        texture_view,
                        base_color,
                        authored_transform,
                        view_proj,
                    );
                    scene_draw_calls +|= 1;
                }
            }
        }

        // CrateFeature extraction is immutable plain data. The visual host is
        // the only layer that resolves its typed handles to GPU resources.
        for (crate_draws) |draw| {
            const crate_mesh = try self.visuals.resolve(draw.mesh, draw.material);
            const scale = zm.scaling(
                draw.half_extents[0] * 2,
                draw.half_extents[1] * 2,
                draw.half_extents[2] * 2,
            );
            const rotation = zm.quatToMat(zm.f32x4(
                draw.pose.rotation[0],
                draw.pose.rotation[1],
                draw.pose.rotation[2],
                draw.pose.rotation[3],
            ));
            const translation = zm.translation(
                draw.pose.position[0],
                draw.pose.position[1],
                draw.pose.position[2],
            );
            const model_matrix = zm.mul(zm.mul(scale, rotation), translation);
            self.gpu_renderer.drawMesh(crate_mesh, model_matrix, view_proj);
            scene_draw_calls +|= 1;
        }

        // InteractionFeature owns semantic identity and pose extraction; this
        // host supplies only a reusable cube mesh and frame submission.
        for (carryable_draws) |draw| {
            const scale = zm.scaling(
                draw.half_extents[0] * 2,
                draw.half_extents[1] * 2,
                draw.half_extents[2] * 2,
            );
            const rotation = zm.quatToMat(zm.f32x4(
                draw.pose.rotation[0],
                draw.pose.rotation[1],
                draw.pose.rotation[2],
                draw.pose.rotation[3],
            ));
            const translation = zm.translation(
                draw.pose.position[0],
                draw.pose.position[1],
                draw.pose.position[2],
            );
            self.gpu_renderer.drawMesh(
                &self.block_mesh,
                zm.mul(zm.mul(scale, rotation), translation),
                view_proj,
            );
            scene_draw_calls +|= 1;
        }

        for (vehicle_draws) |draw| {
            const chassis_mesh = try self.visuals.resolve(
                draw.chassis_mesh,
                draw.chassis_material,
            );
            const chassis_scale = zm.scaling(
                draw.chassis_half_extents[0] * 2,
                draw.chassis_half_extents[1] * 2,
                draw.chassis_half_extents[2] * 2,
            );
            const chassis_rotation = zm.quatToMat(zm.f32x4(
                draw.chassis_pose.rotation[0],
                draw.chassis_pose.rotation[1],
                draw.chassis_pose.rotation[2],
                draw.chassis_pose.rotation[3],
            ));
            const chassis_translation = zm.translation(
                draw.chassis_pose.position[0],
                draw.chassis_pose.position[1],
                draw.chassis_pose.position[2],
            );
            self.gpu_renderer.drawMesh(
                chassis_mesh,
                zm.mul(zm.mul(chassis_scale, chassis_rotation), chassis_translation),
                view_proj,
            );
            scene_draw_calls +|= 1;

            for (draw.wheels) |wheel| {
                const wheel_mesh = try self.visuals.resolve(wheel.mesh, wheel.material);
                const wheel_scale = zm.scaling(
                    wheel.width,
                    wheel.radius * 2,
                    wheel.radius * 2,
                );
                const wheel_rotation = zm.quatToMat(zm.f32x4(
                    wheel.pose.rotation[0],
                    wheel.pose.rotation[1],
                    wheel.pose.rotation[2],
                    wheel.pose.rotation[3],
                ));
                const wheel_translation = zm.translation(
                    wheel.pose.position[0],
                    wheel.pose.position[1],
                    wheel.pose.position[2],
                );
                self.gpu_renderer.drawMesh(
                    wheel_mesh,
                    zm.mul(zm.mul(wheel_scale, wheel_rotation), wheel_translation),
                    view_proj,
                );
                scene_draw_calls +|= 1;
            }
        }

        for (character_draws) |draw| {
            const character_mesh = try self.visuals.resolve(draw.mesh, draw.material);
            const rotation = zm.quatToMat(zm.f32x4(
                draw.pose.rotation[0],
                draw.pose.rotation[1],
                draw.pose.rotation[2],
                draw.pose.rotation[3],
            ));
            const translation = zm.translation(
                draw.pose.position[0],
                draw.pose.position[1],
                draw.pose.position[2],
            );
            self.gpu_renderer.drawMesh(
                character_mesh,
                zm.mul(rotation, translation),
                view_proj,
            );
            scene_draw_calls +|= 1;
        }
        // NPC authority exposes the same immutable typed resource contract as
        // the player character. Navigation and population policy remain
        // entirely outside the renderer; this loop submits only extracted
        // poses and deliberately adds no navigation/crowd overlay.
        for (npc_draws) |draw| {
            const npc_mesh = try self.visuals.resolve(draw.mesh, draw.material);
            const rotation = zm.quatToMat(zm.f32x4(
                draw.pose.rotation[0],
                draw.pose.rotation[1],
                draw.pose.rotation[2],
                draw.pose.rotation[3],
            ));
            const translation = zm.translation(
                draw.pose.position[0],
                draw.pose.position[1],
                draw.pose.position[2],
            );
            self.gpu_renderer.drawMesh(
                npc_mesh,
                zm.mul(rotation, translation),
                view_proj,
            );
            scene_draw_calls +|= 1;
        }
        self.mergeProfileCounts(.{ .draw_calls = scene_draw_calls });
        scene_draw_profile.finish(.success);
        self.drawPhysicsDebug(view_proj);

        // ================================================================
        // End scene render pass BEFORE editor drawing
        // ================================================================
        // ImGui needs to upload vertex data via a copy pass, which can't
        // happen inside a render pass. So we split the frame:
        // 1. End the scene render pass
        // 2. Let editor do its thing (copy pass + its own render pass)
        // 3. Submit everything together
        self.gpu_renderer.endRenderPass();

        // Draw editor overlay (ImGui debug UI), then apply its fixed typed
        // request mailboxes only after the borrowed snapshot/view is unused.
        var editor_profile = self.beginHostProfile(
            .editor,
            self.frame_timer.total_frames,
            self.simulation.tickIndex(),
        );
        defer editor_profile.finish(.failure);
        try self.drawDeveloperOverlay();
        editor_profile.finish(.success);

        // Submit the frame (both scene and editor render passes)
        var submission_profile = self.beginHostProfile(
            .submission,
            self.frame_timer.total_frames,
            self.simulation.tickIndex(),
        );
        defer submission_profile.finish(.failure);
        try self.submitCurrentFrame();
        submission_profile.finish(.success);
        return .{ .ready = .{
            .crate_count = crate_draws.len,
            .first_id = if (crate_draws.len > 0) crate_draws[0].persistent_id else null,
            .first_position = if (crate_draws.len > 0) crate_draws[0].pose.position else null,
            .first_rotation = if (crate_draws.len > 0) crate_draws[0].pose.rotation else null,
            .character_count = character_draws.len,
            .character_id = if (character_draws.len > 0)
                character_draws[0].persistent_id
            else
                null,
            .character_position = if (character_draws.len > 0)
                character_draws[0].pose.position
            else
                null,
            .vehicle_count = vehicle_draws.len,
            .vehicle_id = if (vehicle_draws.len > 0)
                vehicle_draws[0].persistent_id
            else
                null,
            .district_count = district_draws.len,
            .carryable_count = carryable_draws.len,
            .carryable_id = if (carryable_draws.len > 0)
                carryable_draws[0].persistent_id
            else
                null,
            .npc_count = npc_draws.len,
        } };
    }

    fn drawDeveloperOverlay(self: *App) !void {
        self.developer_control_requests.clear();
        self.developer_diagnostic_requests.clear();
        self.developer_visualization_requests.clear();
        self.authoring_requests.clear();
        self.interaction_requests.clear();
        const developer_snapshot = try self.developerSnapshot();
        const visualization_snapshot = self.developerVisualizationSnapshot();
        const authoring_view = try self.crateAuthoringView();
        const interaction_view = try self.interactionEditorView();
        const diagnostic_entries = self.simulation
            .diagnosticJournal()
            .borrowedChronological();
        self.developer_editor.draw(
            &self.gpu_renderer,
            .{
                .camera = &self.game_camera,
                .frame_timer = &self.frame_timer,
                .developer = .{
                    .snapshot = &developer_snapshot,
                    .journal = diagnostic_entries,
                    .control_requests = &self.developer_control_requests,
                    .diagnostic_requests = &self.developer_diagnostic_requests,
                },
                .visualization = .{
                    .snapshot = &visualization_snapshot,
                    .profile_spans = self.developer_profiler.spans.view(),
                    .profile_frames = self.developer_profiler.frames.view(),
                    .profile_stats = self.developer_profiler.stats(),
                    .visualization_requests = &self.developer_visualization_requests,
                },
                .authoring = .{
                    .view = &authoring_view,
                    .requests = &self.authoring_requests,
                },
                .interaction = .{
                    .view = &interaction_view,
                    .requests = &self.interaction_requests,
                },
            },
        );
        self.applyDeveloperControlRequests(self.developer_control_requests.slice());
        self.applyDeveloperDiagnosticRequests(self.developer_diagnostic_requests.slice());
        self.applyDeveloperVisualizationRequests(
            self.developer_visualization_requests.slice(),
        );
        try self.applyAuthoringRequests(self.authoring_requests.slice());
        try self.applyInteractionRequests(self.interaction_requests.slice());
        self.developer_control_requests.clear();
        self.developer_diagnostic_requests.clear();
        self.developer_visualization_requests.clear();
        self.authoring_requests.clear();
        self.interaction_requests.clear();
    }

    fn developerVisualizationSnapshot(self: *const App) developer_visualization.Snapshot {
        return .{
            .config = self.developer_visualization_controller.config,
            .profiling_enabled = self.developer_visualization_controller.profiling_enabled,
            .rejected_requests = self.developer_visualization_requests.rejected,
            .cpu_available = self.physics_debug_cpu != null,
            .batch = self.physics_debug_batch_summary,
            .gpu = if (self.physics_debug_overlay) |*overlay| blk: {
                const stats = overlay.stats();
                const resources = stats.resources;
                const uploaded = stats.latest_uploaded_generation != 0;
                break :blk developer_visualization.GpuSummary{
                    .available = true,
                    .enabled = stats.mode == .enabled,
                    .uploaded_generation = stats.latest_uploaded_generation,
                    .line_vertices = if (uploaded) stats.retained_line_vertices else 0,
                    .triangle_vertices = if (uploaded) stats.retained_triangle_vertices else 0,
                    .upload_bytes = if (uploaded) stats.retained_upload_bytes else 0,
                    .uploads = stats.successful_uploads,
                    .draws = stats.draw_calls,
                    .dropped_batches = stats.failed_uploads +| stats.skipped_uploads,
                    .failures = stats.failed_uploads,
                    .backpressure_drops = stats.backpressure_drops,
                    .slot_count = resources.slot_count,
                    .free_slots = resources.free_slots,
                    .busy_slots = resources.busy_slots,
                    .copy_pending_slots = resources.copy_pending_slots,
                    .retired_slots = resources.retired_slots,
                    .live_fences = resources.live_owned_fences,
                    .peak_fences = resources.peak_owned_fences,
                    .max_fences = resources.max_owned_fences,
                    .frame_fence_failures = stats.frame_fence_failures,
                    .slot_retirements = stats.slot_retirements,
                };
            } else developer_visualization.GpuSummary{
                .available = false,
                .enabled = false,
                .uploaded_generation = 0,
                .line_vertices = 0,
                .triangle_vertices = 0,
                .upload_bytes = 0,
                .uploads = 0,
                .draws = 0,
                .dropped_batches = 0,
                .failures = 0,
                .backpressure_drops = 0,
                .slot_count = 0,
                .free_slots = 0,
                .busy_slots = 0,
                .copy_pending_slots = 0,
                .retired_slots = 0,
                .live_fences = 0,
                .peak_fences = 0,
                .max_fences = 0,
                .frame_fence_failures = 0,
                .slot_retirements = 0,
            },
        };
    }

    fn applyDeveloperVisualizationRequests(
        self: *App,
        requests: []const developer_visualization.Request,
    ) void {
        var clear_profile_history = false;
        const overlay_enable_request = requestedVisualizationEnable(requests);
        for (requests) |request| {
            clear_profile_history = self.developer_visualization_controller.apply(request) or
                clear_profile_history;
        }
        if (overlay_enable_request) |enabled| {
            if (self.physics_debug_overlay) |*overlay| {
                _ = overlay.setEnabled(enabled);
            }
        }
        if (clear_profile_history) self.developer_profiler.clearRetained();
    }

    /// Minimal frame used after a retained Runtime system fault. It deliberately
    /// performs no feature extraction, content polling, or streamed GPU pump.
    fn renderFaultInspectionFrame(self: *App) !bool {
        switch (try self.gpu_renderer.beginFrame(renderer.Colors.CORNFLOWER_BLUE)) {
            .ready => {},
            .unavailable => {
                _ = c.SDL_WaitEventTimeout(null, 16);
                return false;
            },
        }
        self.gpu_renderer.endRenderPass();
        try self.drawDeveloperOverlay();
        try self.submitCurrentFrame();
        return true;
    }

    /// Print debug statistics
    fn printDebugStats(self: *App) void {
        std.debug.print("FPS: {d:.1} | Frame time: {d:.2}ms | Sim ticks: {d} | Ticks/frame: {d}\n", .{
            self.frame_timer.getFps(),
            self.frame_timer.getDeltaTime() * 1000.0,
            self.simulation.tickIndex(),
            self.frame_timer.ticks_this_frame,
        });
    }
};

fn developerGpuUsage(stats: district_gpu_registry.Stats) developer_diagnostics.GpuUsage {
    return .{
        .staged_cpu_bytes = stats.staged_cpu_bytes,
        .staged_upload_bytes = stats.staged_upload_bytes,
        .in_flight_upload_bytes = stats.in_flight_upload_bytes,
        .resident_gpu_bytes = stats.resident_gpu_bytes,
        .live_scenes = stats.live_scenes,
        .reserved_scenes = stats.reserved_scenes,
        .staged_scenes = stats.staged_scenes,
        .submitted_scenes = stats.submitted_scenes,
        .retiring_scenes = stats.retiring_scenes,
        .resident_scenes = stats.resident_scenes,
        .active_batches = stats.active_batches,
    };
}

// ============================================================================
// Entry Point
// ============================================================================

fn runInitFailureSmoke(io: std.Io) !RunSummary {
    const failure_points = [_]AppInitFailurePoint{
        .renderer_after_window_claim,
        .renderer_after_pipelines,
        .renderer_after_placeholder_resources,
        .after_renderer,
        .after_visual_resources,
        .after_simulation,
    };

    inline for (failure_points) |failure_point| {
        const failed_as_expected = failed: {
            var unexpected = App.initWithFailurePoint(
                io,
                .s1_smoke,
                null,
                failure_point,
            ) catch |err| {
                const expected: anyerror = if (rendererFailurePoint(failure_point) != null)
                    error.InjectedRendererInitFailure
                else
                    error.InjectedAppInitFailure;
                if (err != expected) return err;
                break :failed true;
            };
            unexpected.deinit();
            break :failed false;
        };
        if (!failed_as_expected) return error.InitFailureInjectionMissed;
    }

    // Diagnostic-only shader/pipeline loss must still construct and advance a
    // real visual-host simulation authority. The overlay reports unavailable
    // and normal renderer ownership remains healthy for teardown/restart.
    {
        var without_debug_pipelines = try App.initWithoutPhysicsDebugPipelinesForTest(
            io,
            .s1_smoke,
            null,
        );
        defer without_debug_pipelines.deinit();
        if (without_debug_pipelines.gpu_renderer.physicsDebugPipelinesAvailable() or
            without_debug_pipelines.physics_debug_overlay != null)
        {
            return error.OptionalPhysicsDebugPipelineIsolationFailed;
        }
        try without_debug_pipelines.simulation.tick();
        if (without_debug_pipelines.simulation.tickIndex() != 1) {
            return error.OptionalPhysicsDebugPipelineAuthorityDidNotAdvance;
        }
        std.debug.print(
            "INIT_OPTIONAL_PHYSICS_DEBUG_PIPELINES authority_tick=1 overlay_available=false\n",
            .{},
        );
    }

    // A successful lifecycle in the same process proves that each injected
    // unwind released the SDL video runtime, window, Metal device, Jolt world,
    // and all intermediate resources needed by a later initialization.
    var healthy = try App.init(io, .s1_smoke, null);
    defer healthy.deinit();
    return healthy.runValidation(.{ .frames = 160, .virtual_render_hz = 80 }, .s1_character);
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (build_options.validation_mode) {
        return validationMain(init, args);
    }
    return productMain(init, args);
}

fn productMain(init: std.process.Init, args: anytype) !void {
    const mode = try parseProductMode(args);
    const configured_content_root = try parseContentRootOverride(args);
    const resolved_content_root = try resolveContentRoot(
        init.io,
        init.arena.allocator(),
        configured_content_root orelse if (init.environ_map.get(
            "INCINERATOR_CONTENT_ROOT",
        )) |environment_root|
            try content.ContentRootPath.parse(environment_root)
        else
            null,
    );
    if (mode == .verify_install) {
        try verifyInstalledContent(
            init.io,
            init.arena.allocator(),
            resolved_content_root,
        );
        std.debug.print(
            "Incinerator install verified (content: canonical district catalog, " ++
                "shader format: {s}, GPU driver: {s}, editor: {})\n",
            .{
                @tagName(shader_assets.format),
                shader_assets.driver,
                build_options.editor_enabled,
            },
        );
        return;
    }

    const configured_save_root = try parseSaveRootOverride(args);
    var app = if (configured_save_root) |save_root|
        try App.initWithSaveRoot(
            init.io,
            .sandbox,
            resolved_content_root,
            save_root,
        )
    else
        try App.init(init.io, .sandbox, resolved_content_root);
    defer app.deinit();
    try app.runProduct();
}

fn initValidationApp(
    io: std.Io,
    mode: ProgramMode,
    content_root: ?content.ContentRootPath,
    save_root: ?save_slots.RootPath,
) !App {
    return switch (mode) {
        .normal, .s4_physics_debug_smoke => initValidationAppWithProfile(
            io,
            .sandbox,
            content_root,
            save_root,
        ),
        .visual_smoke => initValidationAppWithProfile(
            io,
            .s0_smoke,
            content_root,
            save_root,
        ),
        .s1_visual_smoke, .window_lifecycle_smoke => initValidationAppWithProfile(
            io,
            .s1_smoke,
            content_root,
            save_root,
        ),
        .s2_visual_smoke => initValidationAppWithProfile(
            io,
            .s2_smoke,
            content_root,
            save_root,
        ),
        .s3_streaming_smoke,
        .s6_streaming_smoke,
        .s7_interaction_smoke,
        .s8_population_smoke,
        => initValidationAppWithProfile(
            io,
            .s3_smoke,
            content_root,
            save_root,
        ),
        .s4_diagnostics_smoke => App.initForDiagnosticsSmoke(
            io,
            .s3_smoke,
            content_root,
            save_root,
        ),
        .s5_authoring_smoke => initValidationAppWithProfile(
            io,
            .s1_smoke,
            content_root,
            save_root,
        ),
        .init_failure_smoke, .verify_install => unreachable,
    };
}

fn initValidationAppWithProfile(
    io: std.Io,
    comptime profile: BootstrapProfile,
    content_root: ?content.ContentRootPath,
    save_root: ?save_slots.RootPath,
) !App {
    if (save_root) |root| {
        return App.initWithSaveRoot(io, profile, content_root, root);
    }
    return App.init(io, profile, content_root);
}

fn validationMain(init: std.process.Init, args: anytype) !void {
    const mode = try parseProgramMode(args);
    // Content configuration is outside every non-content smoke's capability
    // boundary. Inherited development-shell values, including malformed ones,
    // must not prevent diagnostics/window/init-only installed gates from
    // starting.
    const configured_content_root = switch (mode) {
        .normal,
        .verify_install,
        .s3_streaming_smoke,
        .s6_streaming_smoke,
        .s7_interaction_smoke,
        .s8_population_smoke,
        .s4_diagnostics_smoke,
        .s4_physics_debug_smoke,
        .s5_authoring_smoke,
        => blk: {
            const cli_content_root = try parseContentRootOverride(args);
            break :blk cli_content_root orelse if (init.environ_map.get(
                "INCINERATOR_CONTENT_ROOT",
            )) |environment_root|
                try content.ContentRootPath.parse(environment_root)
            else
                null;
        },
        else => null,
    };
    const resolved_content_root = switch (mode) {
        .normal,
        .verify_install,
        .s3_streaming_smoke,
        .s6_streaming_smoke,
        .s7_interaction_smoke,
        .s8_population_smoke,
        .s4_diagnostics_smoke,
        .s4_physics_debug_smoke,
        .s5_authoring_smoke,
        => try resolveContentRoot(
            init.io,
            init.arena.allocator(),
            configured_content_root,
        ),
        else => null,
    };
    if (mode == .verify_install) {
        try verifyInstalledContent(
            init.io,
            init.arena.allocator(),
            resolved_content_root.?,
        );
        std.debug.print(
            "Incinerator install verified (content: canonical district catalog, shader format: {s}, GPU driver: {s}, editor: {})\n",
            .{
                @tagName(shader_assets.format),
                shader_assets.driver,
                build_options.editor_enabled,
            },
        );
        return;
    }

    if (mode == .init_failure_smoke) {
        const summary = try runInitFailureSmoke(init.io);
        const expected = try smokeExpectation(.{
            .frames = 160,
            .virtual_render_hz = 80,
        });
        std.debug.print(
            "INIT_FAILURE_SMOKE_RESULT checkpoints=6 ready_frames={d} " ++
                "ticks={d} gpu_driver={s}\n",
            .{
                summary.ready_frames,
                expected.ticks,
                shader_assets.driver,
            },
        );
        std.debug.print("INIT_FAILURE_SMOKE_SHUTDOWN status=clean\n", .{});
        return;
    }
    const configured_save_root = try parseSaveRootOverride(args);
    var app = try initValidationApp(
        init.io,
        mode,
        resolved_content_root,
        configured_save_root,
    );
    var visual_smoke_succeeded = false;
    var s1_visual_smoke_succeeded = false;
    var s2_visual_smoke_succeeded = false;
    var s3_streaming_smoke_succeeded = false;
    var s6_streaming_smoke_succeeded = false;
    var s7_interaction_smoke_succeeded = false;
    var s8_population_smoke_succeeded = false;
    var s4_physics_debug_smoke_succeeded = false;
    var s5_authoring_smoke_succeeded = false;
    var window_lifecycle_smoke_succeeded = false;
    var s4_diagnostics_summary: ?S4DiagnosticsSmokeSummary = null;
    defer {
        app.deinit();
        if (visual_smoke_succeeded) {
            std.debug.print("S0_VISUAL_SMOKE_SHUTDOWN status=clean\n", .{});
        }
        if (s1_visual_smoke_succeeded) {
            std.debug.print("S1_VISUAL_SMOKE_SHUTDOWN status=clean\n", .{});
        }
        if (s2_visual_smoke_succeeded) {
            std.debug.print("S2_VISUAL_SMOKE_SHUTDOWN status=clean\n", .{});
        }
        if (s3_streaming_smoke_succeeded) {
            std.debug.print("S3_STREAMING_SMOKE_SHUTDOWN status=clean\n", .{});
        }
        if (s6_streaming_smoke_succeeded) {
            std.debug.print("S6_STREAMING_SMOKE_SHUTDOWN status=clean\n", .{});
        }
        if (s7_interaction_smoke_succeeded) {
            std.debug.print("S7_INTERACTION_SMOKE_SHUTDOWN status=clean\n", .{});
        }
        if (s8_population_smoke_succeeded) {
            std.debug.print("S8_POPULATION_SMOKE_SHUTDOWN status=clean\n", .{});
        }
        if (s4_physics_debug_smoke_succeeded) {
            std.debug.print("S4_PHYSICS_DEBUG_SMOKE_SHUTDOWN status=clean\n", .{});
        }
        if (s5_authoring_smoke_succeeded) {
            std.debug.print("S5_AUTHORING_SMOKE_SHUTDOWN status=clean\n", .{});
        }
        if (window_lifecycle_smoke_succeeded) {
            std.debug.print("WINDOW_LIFECYCLE_SMOKE_SHUTDOWN status=clean\n", .{});
        }
        if (s4_diagnostics_summary) |summary| {
            std.debug.print(
                "S4_DIAGNOSTICS_SMOKE_SHUTDOWN status=clean fault_phase={s} " ++
                    "fault_tick={d} fault_error={s} fault_error_code={d} " ++
                    "journal_sequence={d}\n",
                .{
                    @tagName(summary.fault.phase),
                    summary.fault.tick_index,
                    summary.fault.error_name.slice(),
                    summary.fault.error_code,
                    summary.fault.journal_sequence,
                },
            );
        }
    }

    switch (mode) {
        .normal => _ = try app.runValidation(null, .none),
        .verify_install => unreachable,
        .visual_smoke => |config| {
            const summary = try app.runValidation(config, .none);
            std.debug.print(
                "S0_VISUAL_SMOKE_RESULT ready_frames={d} unavailable_frames={d} " ++
                    "attempted_frames={d} crate_frames={d} position_changed={} " ++
                    "rotation_changed={} ticks={d} alpha_min={d:.6} alpha_max={d:.6} " ++
                    "virtual_render_hz={d} gpu_driver={s}\n",
                .{
                    summary.ready_frames,
                    summary.unavailable_frames,
                    summary.attempted_frames,
                    summary.crate_presented_frames,
                    summary.position_changed,
                    summary.rotation_changed,
                    app.simulation.tickIndex(),
                    summary.min_alpha,
                    summary.max_alpha,
                    config.virtual_render_hz,
                    shader_assets.driver,
                },
            );
            visual_smoke_succeeded = true;
        },
        .s1_visual_smoke => |config| {
            const summary = try app.runValidation(config, .s1_character);
            std.debug.print(
                "S1_VISUAL_SMOKE_RESULT ready_frames={d} unavailable_frames={d} " ++
                    "attempted_frames={d} character_frames={d} character_moved={} " ++
                    "jump_observed={} " ++
                    "ticks={d} alpha_min={d:.6} alpha_max={d:.6} " ++
                    "virtual_render_hz={d} gpu_driver={s}\n",
                .{
                    summary.ready_frames,
                    summary.unavailable_frames,
                    summary.attempted_frames,
                    summary.character_presented_frames,
                    summary.character_position_changed,
                    summary.character_jump_observed,
                    app.simulation.tickIndex(),
                    summary.min_alpha,
                    summary.max_alpha,
                    config.virtual_render_hz,
                    shader_assets.driver,
                },
            );
            s1_visual_smoke_succeeded = true;
        },
        .s2_visual_smoke => |config| {
            const summary = try app.runValidation(config, .s2_vehicle);
            std.debug.print(
                "S2_VISUAL_SMOKE_RESULT ready_frames={d} unavailable_frames={d} " ++
                    "attempted_frames={d} vehicle_frames={d} vehicle_moved={} " ++
                    "steering_observed={} brake_applied={} crate_displaced={} character_hidden={} " ++
                    "character_restored={} exited={} ticks={d} alpha_min={d:.6} " ++
                    "alpha_max={d:.6} virtual_render_hz={d} gpu_driver={s}\n",
                .{
                    summary.ready_frames,
                    summary.unavailable_frames,
                    summary.attempted_frames,
                    summary.vehicle_presented_frames,
                    app.validation.s2_smoke.vehicle_moved,
                    app.validation.s2_smoke.steering_observed,
                    app.validation.s2_smoke.brake_applied,
                    app.validation.s2_smoke.crate_displaced,
                    summary.character_hidden_while_driving,
                    summary.character_visible_after_exit,
                    app.validation.s2_smoke.exited,
                    app.simulation.tickIndex(),
                    summary.min_alpha,
                    summary.max_alpha,
                    config.virtual_render_hz,
                    shader_assets.driver,
                },
            );
            s2_visual_smoke_succeeded = true;
        },
        .s3_streaming_smoke => |config| {
            const summary = try app.runS3StreamingSmoke(config);
            std.debug.print(
                "S3_STREAMING_SMOKE_RESULT frames={d} ticks={d} zero_tick_frames={d} " ++
                    "multi_tick_frames={d} cancelled_loads={d} resident_cycles={d} " ++
                    "unload_cycles={d} cancel_to_drained_frames={d} " ++
                    "peak_load_to_resident_frames={d} peak_unload_to_drained_frames={d} " ++
                    "fallback_frames={d} resident_frames={d} " ++
                    "peak_live_scenes={d} peak_active_batches={d} " ++
                    "peak_staged_cpu_bytes={d} " ++
                    "peak_staged_upload_bytes={d} peak_in_flight_upload_bytes={d} " ++
                    "peak_resident_gpu_bytes={d} diagnostic_correlations={d} " ++
                    "diagnostic_entries={d} diagnostic_resident_snapshot={} " ++
                    "diagnostic_drained_snapshot={} virtual_render_hz={d} gpu_driver={s}\n",
                .{
                    summary.attempted_frames,
                    summary.ticks,
                    summary.zero_tick_frames,
                    summary.multi_tick_frames,
                    summary.cancelled_loads,
                    summary.resident_cycles,
                    summary.unload_cycles,
                    summary.cancel_to_drained_frames,
                    summary.peak_load_to_resident_frames,
                    summary.peak_unload_to_drained_frames,
                    summary.fallback_frames,
                    summary.resident_frames,
                    summary.peak_live_scenes,
                    summary.peak_active_batches,
                    summary.peak_staged_cpu_bytes,
                    summary.peak_staged_upload_bytes,
                    summary.peak_in_flight_upload_bytes,
                    summary.peak_resident_gpu_bytes,
                    summary.diagnostic_correlations,
                    summary.diagnostic_entries,
                    summary.diagnostic_resident_snapshot,
                    summary.diagnostic_drained_snapshot,
                    config.virtual_render_hz,
                    shader_assets.driver,
                },
            );
            s3_streaming_smoke_succeeded = true;
        },
        .s6_streaming_smoke => |config| {
            const summary = try app.runS6StreamingSmoke(config);
            std.debug.print(
                "S6_STREAMING_SMOKE_RESULT frames={d} ticks={d} " ++
                    "zero_tick_frames={d} multi_tick_frames={d} overlap_cycles={d} " ++
                    "forward_overlaps={d} reverse_overlaps={d} peak_live_scenes={d} " ++
                    "peak_resident_scenes={d} peak_active_batches={d} " ++
                    "peak_staged_cpu_bytes={d} peak_in_flight_upload_bytes={d} " ++
                    "peak_resident_gpu_bytes={d} final_drain=true " ++
                    "virtual_render_hz={d} gpu_driver={s}\n",
                .{
                    summary.attempted_frames,
                    summary.ticks,
                    summary.zero_tick_frames,
                    summary.multi_tick_frames,
                    summary.overlap_cycles,
                    summary.forward_overlaps,
                    summary.reverse_overlaps,
                    summary.peak_live_scenes,
                    summary.peak_resident_scenes,
                    summary.peak_active_batches,
                    summary.peak_staged_cpu_bytes,
                    summary.peak_in_flight_upload_bytes,
                    summary.peak_resident_gpu_bytes,
                    config.virtual_render_hz,
                    shader_assets.driver,
                },
            );
            s6_streaming_smoke_succeeded = true;
        },
        .s7_interaction_smoke => |config| {
            try app.bootstrapS7Interaction();
            const summary = try app.runS7InteractionSmoke(config);
            std.debug.print(
                "S7_INTERACTION_SMOKE_RESULT frames={d} ticks={d} " ++
                    "zero_tick_frames={d} multi_tick_frames={d} " ++
                    "carryable_draw_frames={d} held_draw_frames={d} " ++
                    "district_draw_frames={d} collected={} crossed_east={} " ++
                    "dropped_east={} source_unloaded_while_held={} " ++
                    "dormant_after_unload={} resumed_after_reload={} " ++
                    "final_entities={d} final_bodies={d} final_draws=0 " ++
                    "virtual_render_hz={d} gpu_driver={s}\n",
                .{
                    summary.attempted_frames,
                    summary.ticks,
                    summary.zero_tick_frames,
                    summary.multi_tick_frames,
                    summary.carryable_draw_frames,
                    summary.held_draw_frames,
                    summary.district_draw_frames,
                    summary.collected,
                    summary.crossed_east,
                    summary.dropped_east,
                    summary.source_unloaded_while_held,
                    summary.dormant_after_unload,
                    summary.resumed_after_reload,
                    summary.final_entities,
                    summary.final_bodies,
                    config.virtual_render_hz,
                    shader_assets.driver,
                },
            );
            s7_interaction_smoke_succeeded = true;
        },
        .s8_population_smoke => |config| {
            const summary = try app.runS8PopulationSmoke(config);
            const npc = app.simulation.diagnostics().npc;
            std.debug.print(
                "S8_POPULATION_SMOKE_RESULT frames={d} ticks={d} " ++
                    "zero_tick_frames={d} multi_tick_frames={d} " ++
                    "planned={d} spawned={d} despawned={d} " ++
                    "npc_draw_frames={d} peak_npc_draws={d} " ++
                    "peak_native_controllers={d} waiting_events={d} " ++
                    "waiting_resume_events={d} transfers={d} " ++
                    "dormant_events={d} controller_resume_events={d} " ++
                    "controllers_suspended={d} controllers_resumed={d} " ++
                    "two_resident_scenes={} peak_live_scenes={d} " ++
                    "peak_resident_scenes={d} peak_staged_cpu_bytes={d} " ++
                    "peak_staged_upload_bytes={d} " ++
                    "peak_in_flight_upload_bytes={d} " ++
                    "peak_resident_gpu_bytes={d} final_entities={d} " ++
                    "final_bodies={d} final_native_controllers={d} final_draws={d} " ++
                    "queues_empty=true final_drain=true " ++
                    "virtual_render_hz={d} gpu_driver={s}\n",
                .{
                    summary.attempted_frames,
                    summary.ticks,
                    summary.zero_tick_frames,
                    summary.multi_tick_frames,
                    summary.planned,
                    summary.spawned,
                    summary.despawned,
                    summary.npc_draw_frames,
                    summary.peak_npc_draws,
                    summary.peak_native_controllers,
                    summary.waiting_events,
                    summary.waiting_resume_events,
                    summary.transfer_events,
                    summary.dormant_events,
                    summary.controller_resume_events,
                    npc.controllers_suspended,
                    npc.controllers_resumed,
                    summary.two_resident_scenes,
                    summary.peak_live_scenes,
                    summary.peak_resident_scenes,
                    summary.peak_staged_cpu_bytes,
                    summary.peak_staged_upload_bytes,
                    summary.peak_in_flight_upload_bytes,
                    summary.peak_resident_gpu_bytes,
                    summary.final_entities,
                    summary.final_bodies,
                    summary.final_native_controllers,
                    summary.final_draws,
                    config.virtual_render_hz,
                    shader_assets.driver,
                },
            );
            s8_population_smoke_succeeded = true;
        },
        .s4_diagnostics_smoke => {
            const summary = try app.runS4DiagnosticsSmoke();
            std.debug.print(
                "S4_DIAGNOSTICS_SMOKE_RESULT paused_frames={d} paused_seconds={d:.3} " ++
                    "tick_before_pause={d} tick_after_step={d} step_ticks=1 " ++
                    "failed_tick_counted={} " ++
                    "save_unchanged=true freeze_resume_clear=true frozen_rejections={d} " ++
                    "fault_journal_entries={d} inspection_ready_frames={d} " ++
                    "json_bytes={d} fault_phase={s} fault_tick={d} fault_error={s} " ++
                    "fault_error_code={d} journal_sequence={d} gpu_driver={s}\n",
                .{
                    summary.paused_frames,
                    summary.paused_seconds,
                    summary.tick_before_pause,
                    summary.tick_after_step,
                    summary.failed_tick_counted,
                    summary.frozen_rejections,
                    summary.fault_journal_entries,
                    summary.inspection_ready_frames,
                    summary.json_bytes,
                    @tagName(summary.fault.phase),
                    summary.fault.tick_index,
                    summary.fault.error_name.slice(),
                    summary.fault.error_code,
                    summary.fault.journal_sequence,
                    shader_assets.driver,
                },
            );
            s4_diagnostics_summary = summary;
        },
        .s4_physics_debug_smoke => |config| {
            app.developer_visualization_controller.config.enabled = true;
            if (app.physics_debug_overlay) |*overlay| {
                _ = overlay.setEnabled(true);
            } else {
                return error.S4PhysicsDebugGpuUnavailable;
            }
            const summary = try app.runValidation(config, .s4_physics_debug);
            const gpu = app.physics_debug_overlay.?.stats();
            const profile_stats = app.developer_profiler.stats();
            std.debug.print(
                "S4_PHYSICS_DEBUG_SMOKE_RESULT ready_frames={d} ticks={d} " ++
                    "batches={d} peak_lines={d} peak_triangles={d} dropped={d} " ++
                    "shapes={} bounds={} contacts={} centers={} velocities={} " ++
                    "uploads={d} copy_submissions={d} copy_completions={d} " ++
                    "upload_bytes={d} backpressure_drops={d} draws={d} post_fences={d} " ++
                    "gpu_buffers={d} transfer_buffers={d} slots={d} peak_fences={d} " ++
                    "profile_spans={d} profile_frames={d} " ++
                    "profile_overwrites={d} virtual_render_hz={d} gpu_driver={s}\n",
                .{
                    summary.ready_frames,
                    app.simulation.tickIndex(),
                    app.validation.s4_physics_debug_evidence.batches,
                    app.validation.s4_physics_debug_evidence.peak_lines,
                    app.validation.s4_physics_debug_evidence.peak_triangles,
                    app.validation.s4_physics_debug_evidence.dropped_primitives,
                    app.validation.s4_physics_debug_evidence.category_observed[@intFromEnum(engine.physics_debug.Category.shape)],
                    app.validation.s4_physics_debug_evidence.category_observed[@intFromEnum(engine.physics_debug.Category.bounds)],
                    app.validation.s4_physics_debug_evidence.category_observed[@intFromEnum(engine.physics_debug.Category.contact)],
                    app.validation.s4_physics_debug_evidence.category_observed[@intFromEnum(engine.physics_debug.Category.center_of_mass)],
                    app.validation.s4_physics_debug_evidence.category_observed[@intFromEnum(engine.physics_debug.Category.velocity)],
                    gpu.successful_uploads,
                    gpu.copy_submissions,
                    gpu.copy_completions,
                    gpu.total_upload_bytes,
                    gpu.backpressure_drops,
                    gpu.draw_calls,
                    gpu.frame_fences_accepted,
                    gpu.resources.gpu_buffer_count,
                    gpu.resources.transfer_buffer_count,
                    gpu.resources.slot_count,
                    gpu.resources.peak_owned_fences,
                    profile_stats.spans.count,
                    profile_stats.frames.count,
                    profile_stats.spans.overwritten,
                    config.virtual_render_hz,
                    shader_assets.driver,
                },
            );
            s4_physics_debug_smoke_succeeded = true;
        },
        .s5_authoring_smoke => {
            const summary = try app.runS5AuthoringSmoke();
            std.debug.print(
                "S5_AUTHORING_SMOKE_RESULT rendered_frames={d} hidden_frames={d} " ++
                    "edit_revision={d} undo_revision={d} redo_revision={d} " ++
                    "save_status={s} save_sequence={d} gpu_driver={s}\n",
                .{
                    summary.rendered_frames,
                    summary.hidden_frames,
                    summary.edit_revision,
                    summary.undo_revision,
                    summary.redo_revision,
                    @tagName(summary.save_status),
                    summary.save_sequence,
                    shader_assets.driver,
                },
            );
            s5_authoring_smoke_succeeded = true;
        },
        .window_lifecycle_smoke => {
            const summary = try app.runWindowLifecycleSmoke();
            std.debug.print(
                "WINDOW_LIFECYCLE_SMOKE_RESULT warmup_ready={d} restored_ready={d} " ++
                    "unavailable_frames={d} minimized_wait_iterations={d} " ++
                    "minimized_dwell_ms={d:.3} gpu_driver={s}\n",
                .{
                    summary.warmup_ready_frames,
                    summary.restored_ready_frames,
                    summary.unavailable_frames,
                    summary.minimized_wait_iterations,
                    @as(f64, @floatFromInt(summary.minimized_dwell_ns)) /
                        std.time.ns_per_ms,
                    shader_assets.driver,
                },
            );
            window_lifecycle_smoke_succeeded = true;
        },
        .init_failure_smoke => unreachable,
    }
}

// ============================================================================
// Tests
// ============================================================================

test "app structure exists" {
    // Basic compile-time check that App struct is valid
    _ = App;
}

test "installed product compositions derive content from their own layout" {
    try std.testing.expectEqualStrings(
        "../share/incinerator/content",
        defaultContentRootRelative(false),
    );
    try std.testing.expectEqualStrings(
        "../../share/incinerator/content",
        defaultContentRootRelative(true),
    );
}

test "window suspension discards pending and held gameplay actions" {
    var input_buffer = input.InputBuffer.init(1);
    input_buffer.window_minimized = true;
    var action_latch = sandbox_controls.ActionLatch{};
    try action_latch.captureFrame(.{
        .move = .{ 1, -1 },
        .look_delta = .{ 3, -2 },
        .jump_pressed = true,
        .interact_pressed = true,
        .brake = true,
        .hand_brake = true,
    });

    try std.testing.expect(suspendGameplayForWindowState(
        &input_buffer,
        &action_latch,
    ));
    const after_restore = action_latch.takeTick();
    try std.testing.expectEqual([2]f32{ 0, 0 }, after_restore.move);
    try std.testing.expectEqual([2]f32{ 0, 0 }, after_restore.look_delta);
    try std.testing.expect(!after_restore.jump_pressed);
    try std.testing.expect(!after_restore.interact_pressed);
    try std.testing.expect(!after_restore.brake);
    try std.testing.expect(!after_restore.hand_brake);
}

test "program mode parsing keeps visual smoke explicit and bounded" {
    const normal_args = [_][]const u8{"incinerator"};
    const normal = try parseProgramMode(&normal_args);
    try std.testing.expect(normal == .normal);
    const configured_root_args = [_][]const u8{
        "incinerator",
        "--content-root=/tmp/incinerator-content",
    };
    try std.testing.expect((try parseProgramMode(&configured_root_args)) == .normal);
    const configured_root = (try parseContentRootOverride(&configured_root_args)).?;
    try std.testing.expectEqualStrings("/tmp/incinerator-content", configured_root.bytes());
    const configured_save_args = [_][]const u8{
        "incinerator",
        "--save-root=/tmp/incinerator-saves",
    };
    try std.testing.expect((try parseProgramMode(&configured_save_args)) == .normal);
    const configured_save = (try parseSaveRootOverride(&configured_save_args)).?;
    try std.testing.expectEqualStrings("/tmp/incinerator-saves", configured_save.bytes());
    const smoke_args = [_][]const u8{
        "incinerator",
        "--visual-smoke",
        "--frames=160",
        "--virtual-render-hz=80",
    };
    const smoke = try parseProgramMode(&smoke_args);
    try std.testing.expectEqual(@as(u64, 160), smoke.visual_smoke.frames);
    try std.testing.expectEqual(@as(u32, 80), smoke.visual_smoke.virtual_render_hz);
    const s1_smoke = try parseProgramMode(&[_][]const u8{
        "incinerator",
        "--s1-visual-smoke",
        "--frames=240",
        "--virtual-render-hz=120",
    });
    try std.testing.expectEqual(@as(u64, 240), s1_smoke.s1_visual_smoke.frames);
    const s2_smoke = try parseProgramMode(&[_][]const u8{
        "incinerator",
        "--s2-visual-smoke",
    });
    try std.testing.expectEqual(@as(u64, 1_440), s2_smoke.s2_visual_smoke.frames);
    try std.testing.expectEqual(@as(u32, 240), s2_smoke.s2_visual_smoke.virtual_render_hz);
    const s2_expected = try smokeExpectation(s2_smoke.s2_visual_smoke);
    try std.testing.expectEqual(s2_required_ticks, s2_expected.ticks);
    const s3_smoke = try parseProgramMode(&[_][]const u8{
        "incinerator",
        "--s3-streaming-smoke",
        "--virtual-render-hz=80",
    });
    try std.testing.expectEqual(@as(u64, 1_200), s3_smoke.s3_streaming_smoke.frames);
    try std.testing.expectEqual(@as(u32, 80), s3_smoke.s3_streaming_smoke.virtual_render_hz);
    const s6_smoke = try parseProgramMode(&[_][]const u8{
        "incinerator",
        "--s6-streaming-smoke",
        "--frames=120",
        "--virtual-render-hz=240",
    });
    try std.testing.expectEqual(@as(u64, 120), s6_smoke.s6_streaming_smoke.frames);
    try std.testing.expectEqual(@as(u32, 240), s6_smoke.s6_streaming_smoke.virtual_render_hz);
    const s7_smoke = try parseProgramMode(&[_][]const u8{
        "incinerator",
        "--s7-interaction-smoke",
        "--virtual-render-hz=80",
    });
    try std.testing.expectEqual(@as(u64, 1_200), s7_smoke.s7_interaction_smoke.frames);
    try std.testing.expectEqual(@as(u32, 80), s7_smoke.s7_interaction_smoke.virtual_render_hz);
    const s8_smoke = try parseProgramMode(&[_][]const u8{
        "incinerator",
        "--s8-population-smoke",
    });
    try std.testing.expectEqual(@as(u64, 3_600), s8_smoke.s8_population_smoke.frames);
    try std.testing.expectEqual(@as(u32, 240), s8_smoke.s8_population_smoke.virtual_render_hz);
    const window_smoke = try parseProgramMode(&[_][]const u8{
        "incinerator",
        "--window-lifecycle-smoke",
    });
    try std.testing.expect(window_smoke == .window_lifecycle_smoke);
    const init_failure_smoke = try parseProgramMode(&[_][]const u8{
        "incinerator",
        "--init-failure-smoke",
    });
    try std.testing.expect(init_failure_smoke == .init_failure_smoke);
    const s4_diagnostics_smoke = try parseProgramMode(&[_][]const u8{
        "incinerator",
        "--s4-diagnostics-smoke",
    });
    try std.testing.expect(s4_diagnostics_smoke == .s4_diagnostics_smoke);
    const s4_physics_debug_smoke = try parseProgramMode(&[_][]const u8{
        "incinerator",
        "--s4-physics-debug-smoke",
    });
    try std.testing.expectEqual(
        @as(u64, 600),
        s4_physics_debug_smoke.s4_physics_debug_smoke.frames,
    );
    try std.testing.expectEqual(
        @as(u32, 80),
        s4_physics_debug_smoke.s4_physics_debug_smoke.virtual_render_hz,
    );
    const s5_authoring_smoke = try parseProgramMode(&[_][]const u8{
        "incinerator",
        "--s5-authoring-smoke",
        "--save-root=/tmp/incinerator-s5",
    });
    try std.testing.expect(s5_authoring_smoke == .s5_authoring_smoke);
    const above = try smokeExpectation(.{ .frames = 480, .virtual_render_hz = 240 });
    try std.testing.expectEqual(@as(u64, 240), above.ticks);
    try std.testing.expectEqual(@as(f32, 0), above.min_alpha);
    try std.testing.expectEqual(@as(f32, 0.5), above.max_alpha);
    const below = try smokeExpectation(.{ .frames = 160, .virtual_render_hz = 80 });
    try std.testing.expectEqual(@as(u64, 240), below.ticks);
    try std.testing.expectEqual(@as(f32, 0), below.min_alpha);
    try std.testing.expectEqual(@as(f32, 0.5), below.max_alpha);
    try std.testing.expectError(
        error.VisualSmokeOptionWithoutMode,
        parseProgramMode(&[_][]const u8{ "incinerator", "--frames=1" }),
    );
    try std.testing.expectError(
        error.ConflictingProgramModes,
        parseProgramMode(&[_][]const u8{ "incinerator", "--verify-install", "--visual-smoke" }),
    );
    try std.testing.expectError(
        error.ConflictingProgramModes,
        parseProgramMode(&[_][]const u8{
            "incinerator",
            "--visual-smoke",
            "--s1-visual-smoke",
        }),
    );
    try std.testing.expectError(
        error.ConflictingProgramModes,
        parseProgramMode(&[_][]const u8{
            "incinerator",
            "--s1-visual-smoke",
            "--s2-visual-smoke",
        }),
    );
    try std.testing.expectError(
        error.ConflictingProgramModes,
        parseProgramMode(&[_][]const u8{
            "incinerator",
            "--s3-streaming-smoke",
            "--s6-streaming-smoke",
        }),
    );
    try std.testing.expectError(
        error.ConflictingProgramModes,
        parseProgramMode(&[_][]const u8{
            "incinerator",
            "--s6-streaming-smoke",
            "--s7-interaction-smoke",
        }),
    );
    try std.testing.expectError(
        error.ConflictingProgramModes,
        parseProgramMode(&[_][]const u8{
            "incinerator",
            "--s7-interaction-smoke",
            "--s8-population-smoke",
        }),
    );
    try std.testing.expectError(
        error.DuplicateArgument,
        parseProgramMode(&[_][]const u8{
            "incinerator",
            "--s8-population-smoke",
            "--s8-population-smoke",
        }),
    );
    try std.testing.expectError(
        error.ConflictingProgramModes,
        parseProgramMode(&[_][]const u8{
            "incinerator",
            "--window-lifecycle-smoke",
            "--init-failure-smoke",
        }),
    );
    try std.testing.expectError(
        error.ConflictingProgramModes,
        parseProgramMode(&[_][]const u8{
            "incinerator",
            "--s4-diagnostics-smoke",
            "--window-lifecycle-smoke",
        }),
    );
    try std.testing.expectError(
        error.ConflictingProgramModes,
        parseProgramMode(&[_][]const u8{
            "incinerator",
            "--s4-diagnostics-smoke",
            "--s4-physics-debug-smoke",
        }),
    );
    try std.testing.expectError(
        error.VisualSmokeOptionWithoutMode,
        parseProgramMode(&[_][]const u8{
            "incinerator",
            "--s4-diagnostics-smoke",
            "--frames=8",
        }),
    );
    try std.testing.expectError(
        error.VisualSmokeOptionWithoutMode,
        parseProgramMode(&[_][]const u8{
            "incinerator",
            "--window-lifecycle-smoke",
            "--frames=8",
        }),
    );
    try std.testing.expectError(
        error.InvalidVirtualRenderRate,
        parseProgramMode(&[_][]const u8{ "incinerator", "--visual-smoke", "--virtual-render-hz=0" }),
    );
    try std.testing.expectError(
        error.InvalidContentRoot,
        parseProgramMode(&[_][]const u8{ "incinerator", "--content-root=relative" }),
    );
    try std.testing.expectError(
        error.InvalidSaveRoot,
        parseProgramMode(&[_][]const u8{ "incinerator", "--save-root=relative" }),
    );
    try std.testing.expectError(
        error.SaveRootRequired,
        parseProgramMode(&[_][]const u8{ "incinerator", "--s5-authoring-smoke" }),
    );
    try std.testing.expectError(
        error.ConflictingProgramModes,
        parseProgramMode(&[_][]const u8{
            "incinerator",
            "--s2-visual-smoke",
            "--content-root=/tmp/incinerator-content",
        }),
    );
    try std.testing.expectError(
        error.ConflictingProgramModes,
        parseProgramMode(&[_][]const u8{
            "incinerator",
            "--s4-physics-debug-smoke",
            "--content-root=/tmp/incinerator-content",
        }),
    );
    try std.testing.expectError(
        error.ConflictingProgramModes,
        parseProgramMode(&[_][]const u8{
            "incinerator",
            "--visual-smoke",
            "--save-root=/tmp/incinerator-saves",
        }),
    );
}

test "S8 population smoke summary requires exact bounded lifecycle evidence" {
    var summary = S8PopulationSmokeSummary{
        .attempted_frames = 100,
        .ticks = 50,
        .zero_tick_frames = 50,
        .planned = s8_population_count,
        .spawned = s8_population_count,
        .despawned = s8_population_count,
        .npc_draw_frames = 20,
        .peak_npc_draws = s8_population_count,
        .peak_active = s8_population_count,
        .peak_waiting = s8_population_count,
        .peak_dormant = s8_population_count,
        .peak_native_controllers = s8_population_count,
        .waiting_events = s8_population_count,
        .waiting_resume_events = s8_population_count,
        .transfer_events = s8_population_count,
        .dormant_events = s8_population_count,
        .controller_resume_events = s8_population_count,
        .two_resident_scenes = true,
        .peak_live_scenes = 2,
        .peak_resident_scenes = 2,
        .peak_active_batches = 1,
        .peak_staged_cpu_bytes = 344,
        .peak_staged_upload_bytes = 116,
        .peak_in_flight_upload_bytes = 116,
        .peak_resident_gpu_bytes = 232,
        .final_entities = 0,
        .final_bodies = 1,
        .final_native_controllers = 0,
        .final_draws = 0,
    };
    const diagnostics = NpcDiagnostics{
        .active_count = 0,
        .waiting_count = 0,
        .dormant_count = 0,
        .controller_count = 0,
        .transfers = s8_population_count,
        .controllers_suspended = s8_population_count,
        .controllers_resumed = s8_population_count,
        .commands = .{ .high_water = s8_population_count },
        .outcomes = .{ .high_water = s8_population_count },
        .events = .{ .high_water = s8_population_count },
        .event_drops = .{},
    };
    const controllers = CharacterControllerDiagnostics{
        .native_used = 0,
        .native_capacity = 128,
        .feature_owned = 0,
        .authority_consistent = true,
    };
    try summary.validate(
        .{ .frames = 100, .virtual_render_hz = 240 },
        diagnostics,
        controllers,
    );

    summary.peak_npc_draws -= 1;
    try std.testing.expectError(
        error.S8PopulationSmokeEvidenceMissing,
        summary.validate(
            .{ .frames = 100, .virtual_render_hz = 240 },
            diagnostics,
            controllers,
        ),
    );
    summary.peak_npc_draws += 1;
    summary.zero_tick_frames = 0;
    summary.multi_tick_frames = 1;
    try summary.validate(
        .{ .frames = 100, .virtual_render_hz = 80 },
        diagnostics,
        controllers,
    );

    var leaked = controllers;
    leaked.native_used = 1;
    leaked.authority_consistent = false;
    try std.testing.expectError(
        error.S8PopulationSmokeEvidenceMissing,
        summary.validate(
            .{ .frames = 100, .virtual_render_hz = 80 },
            diagnostics,
            leaked,
        ),
    );
}

fn s8TestIdentity(index: usize) sandbox_host.PersistentId {
    return .{ .namespace = 88, .local = @intCast(index + 1) };
}

test "S8 per-identity evidence requires every exact lifecycle slot" {
    var summary = S8PopulationSmokeSummary{};
    var evidence = S8PopulationEvidence{};

    for (0..s8_population_count) |index| {
        try evidence.observeOutcome(.population_spawned, &summary, .{ .spawned = .{
            .request_id = s8_spawn_first_request_id + index,
            .id = s8TestIdentity(index),
            .owner = district_west_coord,
        } });
    }
    try std.testing.expect(evidence.spawnedComplete());

    for (0..s8_population_count) |index| {
        const id = s8TestIdentity(index);
        try evidence.observeEvent(.destination_waiting, &summary, .{ .state_changed = .{
            .id = id,
            .previous = .active,
            .current = .waiting_at_boundary,
        } });
        try evidence.observeEvent(.destination_reloaded, &summary, .{ .state_changed = .{
            .id = id,
            .previous = .waiting_at_boundary,
            .current = .active,
        } });
        try evidence.observeEvent(.crossed_east, &summary, .{ .owner_transferred = .{
            .id = id,
            .previous = district_west_coord,
            .current = district_east_coord,
        } });
        try evidence.observeEvent(.owner_dormant, &summary, .{ .state_changed = .{
            .id = id,
            .previous = .active,
            .current = .dormant,
        } });
        try evidence.observeEvent(.owner_resumed, &summary, .{ .state_changed = .{
            .id = id,
            .previous = .dormant,
            .current = .active,
        } });
        try evidence.observeOutcome(.population_despawned, &summary, .{ .despawned = .{
            .request_id = s8_despawn_first_request_id + index,
            .id = id,
        } });
    }

    try evidence.requireComplete();
    try std.testing.expectEqual(@as(u8, s8_population_count), summary.spawned);
    try std.testing.expectEqual(@as(u8, s8_population_count), summary.despawned);
    try std.testing.expectEqual(@as(u16, s8_population_count), summary.waiting_events);
    try std.testing.expectEqual(@as(u16, s8_population_count), summary.waiting_resume_events);
    try std.testing.expectEqual(@as(u16, s8_population_count), summary.transfer_events);
    try std.testing.expectEqual(@as(u16, s8_population_count), summary.dormant_events);
    try std.testing.expectEqual(@as(u16, s8_population_count), summary.controller_resume_events);

    var missing = evidence;
    missing.transferred[17] = false;
    try std.testing.expectError(
        error.S8PopulationSmokeEvidenceMissing,
        missing.requireComplete(),
    );
}

test "S8 per-identity evidence rejects duplicate missing and swapped outputs" {
    var summary = S8PopulationSmokeSummary{};
    var evidence = S8PopulationEvidence{};
    const first = s8TestIdentity(0);
    const second = s8TestIdentity(1);

    try evidence.observeOutcome(.population_spawned, &summary, .{ .spawned = .{
        .request_id = s8_spawn_first_request_id,
        .id = first,
        .owner = district_west_coord,
    } });
    try std.testing.expectError(
        error.UnexpectedS8NpcOutcome,
        evidence.observeOutcome(.population_spawned, &summary, .{ .spawned = .{
            .request_id = s8_spawn_first_request_id,
            .id = second,
            .owner = district_west_coord,
        } }),
    );
    try std.testing.expectError(
        error.UnexpectedS8NpcOutcome,
        evidence.observeOutcome(.population_spawned, &summary, .{ .spawned = .{
            .request_id = s8_spawn_first_request_id + 1,
            .id = first,
            .owner = district_west_coord,
        } }),
    );
    try evidence.observeOutcome(.population_spawned, &summary, .{ .spawned = .{
        .request_id = s8_spawn_first_request_id + 1,
        .id = second,
        .owner = district_west_coord,
    } });

    const first_waiting = sandbox_host.NpcEvent{ .state_changed = .{
        .id = first,
        .previous = .active,
        .current = .waiting_at_boundary,
    } };
    try evidence.observeEvent(.destination_waiting, &summary, first_waiting);
    try std.testing.expectError(
        error.UnexpectedS8NpcEvent,
        evidence.observeEvent(.destination_waiting, &summary, first_waiting),
    );
    const second_waiting = sandbox_host.NpcEvent{ .state_changed = .{
        .id = second,
        .previous = .active,
        .current = .waiting_at_boundary,
    } };
    try std.testing.expectError(
        error.UnexpectedS8NpcEvent,
        evidence.observeEvent(.destination_reloaded, &summary, second_waiting),
    );
    try evidence.observeEvent(.destination_waiting, &summary, second_waiting);
    try std.testing.expectError(
        error.UnexpectedS8NpcEvent,
        evidence.observeEvent(.destination_waiting, &summary, .{ .state_changed = .{
            .id = s8TestIdentity(2),
            .previous = .active,
            .current = .waiting_at_boundary,
        } }),
    );
    try std.testing.expectError(
        error.UnexpectedS8NpcEvent,
        evidence.observeEvent(.crossed_east, &summary, .{ .goal_reached = .{
            .id = first,
            .node = s8_east_end,
        } }),
    );

    try std.testing.expectError(
        error.UnexpectedS8NpcOutcome,
        evidence.observeOutcome(.population_despawned, &summary, .{ .despawned = .{
            .request_id = s8_despawn_first_request_id,
            .id = second,
        } }),
    );
    try evidence.observeOutcome(.population_despawned, &summary, .{ .despawned = .{
        .request_id = s8_despawn_first_request_id,
        .id = first,
    } });
    try std.testing.expectError(
        error.UnexpectedS8NpcOutcome,
        evidence.observeOutcome(.population_despawned, &summary, .{ .despawned = .{
            .request_id = s8_despawn_first_request_id,
            .id = first,
        } }),
    );
    try std.testing.expectError(
        error.S8PopulationSmokeEvidenceMissing,
        evidence.requireComplete(),
    );
    try std.testing.expectEqual(@as(u8, 2), summary.spawned);
    try std.testing.expectEqual(@as(u8, 1), summary.despawned);
    try std.testing.expectEqual(@as(u16, 2), summary.waiting_events);
}

test "expected save quiescence errors map to truthful non-commit feedback" {
    try std.testing.expectEqualStrings(
        "simulation commands pending",
        saveDeferralDetail(error.CommandsPending).?,
    );
    try std.testing.expectEqualStrings(
        "district transition pending",
        saveDeferralDetail(error.DistrictTransitionPending).?,
    );
    try std.testing.expect(saveDeferralDetail(error.OutOfMemory) == null);
    try std.testing.expect(saveDeferralDetail(error.DistrictComponentInvariantBroken) == null);
}

test "authoring rejection reasons retain authority-level meaning" {
    try std.testing.expectEqualStrings(
        "crate authority capacity reached",
        authoringRejectionDetail(.capacity_reached),
    );
    try std.testing.expectEqualStrings(
        "crate no longer exists",
        authoringRejectionDetail(.crate_not_found),
    );
    try std.testing.expectEqualStrings(
        "persistent ID is not owned by the crate feature",
        authoringRejectionDetail(.not_owned),
    );
    try std.testing.expectEqualStrings(
        "authoring revision conflict",
        authoringRejectionDetail(.state_conflict),
    );
}

test "district GPU budget backpressure is retryable without blocking logical activation" {
    try std.testing.expect(isRetryableDistrictStageError(error.DistrictStagingBudgetExceeded));
    try std.testing.expect(isRetryableDistrictStageError(error.DistrictResidentBudgetExceeded));
    try std.testing.expect(!isRetryableDistrictStageError(error.OutOfMemory));
    try std.testing.expect(!isRetryableDistrictStageError(error.InvalidSceneMaterial));

    const FakeAdmission = struct {
        events: [2]u8 = undefined,
        count: usize = 0,
        logical_submitted: bool = false,

        fn submitLogical(self: *@This()) !void {
            self.events[self.count] = 1;
            self.count += 1;
            self.logical_submitted = true;
        }

        fn stageBackpressured(self: *@This()) !bool {
            if (!self.logical_submitted) return error.StageRanBeforeLogicalSubmit;
            self.events[self.count] = 2;
            self.count += 1;
            return false;
        }
    };
    var admission = FakeAdmission{};
    try std.testing.expect(!try submitLogicalBeforeStage(
        &admission,
        FakeAdmission.submitLogical,
        FakeAdmission.stageBackpressured,
    ));
    try std.testing.expect(admission.logical_submitted);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, admission.events[0..admission.count]);
}

test "district host sequence IDs are monotonic and fail closed at exhaustion" {
    var next: u64 = 1;
    try std.testing.expectEqual(@as(u64, 1), try takeMonotonicId(&next));
    try std.testing.expectEqual(@as(u64, 2), try takeMonotonicId(&next));
    try std.testing.expectEqual(@as(u64, 3), next);

    var invalid: u64 = 0;
    try std.testing.expectError(error.DistrictSequenceExhausted, takeMonotonicId(&invalid));
    try std.testing.expectEqual(@as(u64, 0), invalid);

    var exhausted: u64 = std.math.maxInt(u64);
    try std.testing.expectError(error.DistrictSequenceExhausted, takeMonotonicId(&exhausted));
    try std.testing.expectEqual(std.math.maxInt(u64), exhausted);
}

test "visual host requires exactly the fixed west and east catalog coordinates" {
    const Entry = struct { coord: sandbox_host.ChunkCoord };
    try validateDistrictStreamCatalogEntries(&[_]Entry{
        .{ .coord = district_west_coord },
        .{ .coord = district_east_coord },
    });
    try validateDistrictStreamCatalogEntries(&[_]Entry{
        .{ .coord = district_east_coord },
        .{ .coord = district_west_coord },
    });
    try std.testing.expectError(
        error.DistrictCatalogSlotMismatch,
        validateDistrictStreamCatalogEntries(&[_]Entry{
            .{ .coord = district_west_coord },
        }),
    );
    try std.testing.expectError(
        error.DistrictCatalogSlotMismatch,
        validateDistrictStreamCatalogEntries(&[_]Entry{
            .{ .coord = district_west_coord },
            .{ .coord = district_west_coord },
        }),
    );
    try std.testing.expectError(
        error.DistrictCatalogSlotMismatch,
        validateDistrictStreamCatalogEntries(&[_]Entry{
            .{ .coord = district_west_coord },
            .{ .coord = district_east_coord },
            .{ .coord = .{ .x = 2, .z = 0 } },
        }),
    );
}

test "district drain completion is exact per scene generation" {
    const FakeRegistry = struct {
        handles: [2]engine.rendering.SceneHandle,
        complete: [2]bool = .{ false, false },
        calls: [2]u8 = .{ 0, 0 },

        fn recycleComplete(
            self: *@This(),
            scene: engine.rendering.SceneHandle,
        ) !bool {
            for (self.handles, 0..) |handle, index| {
                if (!std.meta.eql(handle, scene)) continue;
                self.calls[index] += 1;
                return self.complete[index];
            }
            return error.StaleSceneHandle;
        }
    };
    const west = engine.rendering.SceneHandle{ .index = 0, .generation = 7 };
    const east = engine.rendering.SceneHandle{ .index = 1, .generation = 3 };
    var registry = FakeRegistry{ .handles = .{ west, east } };

    registry.complete[0] = true;
    try std.testing.expect(try districtRecycleComplete(&registry, west));
    try std.testing.expect(!try districtRecycleComplete(&registry, east));
    try std.testing.expectEqual([2]u8{ 1, 1 }, registry.calls);

    registry.complete[1] = true;
    try std.testing.expect(try districtRecycleComplete(&registry, east));
    try std.testing.expectError(
        error.StaleSceneHandle,
        districtRecycleComplete(&registry, .{ .index = 0, .generation = 8 }),
    );
}

test "optional physics debug CPU storage failure remains non-fatal" {
    var fail_first = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );
    try std.testing.expect(
        PhysicsDebugCpuStorage.initWithAllocator(fail_first.allocator()) == null,
    );

    // The first reservation succeeds and the second fails. The helper must
    // release the partial owner and still report ordinary unavailability.
    var fail_second = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 1 },
    );
    try std.testing.expect(
        PhysicsDebugCpuStorage.initWithAllocator(fail_second.allocator()) == null,
    );
}

test "only an explicit visualization enable request retries the GPU overlay" {
    try std.testing.expectEqual(
        @as(?bool, null),
        requestedVisualizationEnable(&.{}),
    );
    try std.testing.expectEqual(
        @as(?bool, null),
        requestedVisualizationEnable(&.{.{ .set_category = .{
            .category = .shape,
            .enabled = false,
        } }}),
    );
    try std.testing.expectEqual(
        @as(?bool, false),
        requestedVisualizationEnable(&.{
            .{ .set_enabled = true },
            .{ .set_profiling_enabled = false },
            .{ .set_enabled = false },
        }),
    );
}

test "interactive vehicle rejections keep normal play healthy while carrying" {
    const vehicle_id = engine.PersistentId{ .namespace = 9, .local = 1 };
    const driver_id = engine.PersistentId{ .namespace = 9, .local = 2 };
    try std.testing.expect(interactiveVehicleRejectionExpected(.{
        .command = .enter,
        .reason = .driver_carrying,
        .vehicle_id = vehicle_id,
        .driver_id = driver_id,
    }));
    try std.testing.expect(interactiveVehicleRejectionExpected(.{
        .command = .enter,
        .reason = .too_far,
        .vehicle_id = vehicle_id,
        .driver_id = driver_id,
    }));
    try std.testing.expect(interactiveVehicleRejectionExpected(.{
        .command = .exit,
        .reason = .exit_blocked,
        .vehicle_id = vehicle_id,
        .driver_id = driver_id,
    }));

    // Authority failures remain fatal to the host; only the typed interactive
    // domain outcomes above are converted into structured diagnostics.
    try std.testing.expect(!interactiveVehicleRejectionExpected(.{
        .command = .enter,
        .reason = .not_owned,
        .vehicle_id = vehicle_id,
        .driver_id = driver_id,
    }));
    try std.testing.expect(!interactiveVehicleRejectionExpected(.{
        .command = .drive,
        .reason = .wrong_driver,
        .vehicle_id = vehicle_id,
        .driver_id = driver_id,
    }));
}

test "all engine module tests are discovered" {
    // Zig 0.16 analyzes declarations lazily. Explicitly reference each module
    // so its test blocks remain part of the engine test contract.
    std.testing.refAllDecls(@import("camera.zig"));
    std.testing.refAllDecls(@import("sandbox_controls.zig"));
    std.testing.refAllDecls(@import("sandbox_visual_resources.zig"));
    std.testing.refAllDecls(@import("editor/tool.zig"));
    std.testing.refAllDecls(@import("district_gpu_registry.zig"));
    std.testing.refAllDecls(@import("district_scene_adapter.zig"));
    std.testing.refAllDecls(@import("district_presentation"));
    std.testing.refAllDecls(@import("input.zig"));
    std.testing.refAllDecls(@import("mesh.zig"));
    std.testing.refAllDecls(@import("renderer.zig"));
    std.testing.refAllDecls(@import("texture.zig"));
    std.testing.refAllDecls(@import("timing.zig"));
}
