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
//! │ Phase 2: AUTHORITY TICK (Fixed 60 Hz)                       │
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
const texture = @import("texture.zig");
const primitives = @import("primitives.zig");
const sandbox_visual_resources = @import("sandbox_visual_resources.zig");
const sandbox_visual_catalog = @import("sandbox_visual_catalog.zig");
const sandbox_visual_composition = @import("sandbox_visual_composition.zig");
const district_contract = @import("district_contract");
const district_feature_contract = @import("district_feature_contract");
const district_streaming_host = @import("hosts/district_streaming_host.zig");
const district_content_catalog = @import("district_content_catalog");
const content = @import("content");
const sandbox_controls = @import("sandbox_controls.zig");
const sandbox_product_character_lifecycle = @import("sandbox_product_character_lifecycle");
const developer_controls = @import("developer_controls");
const developer_diagnostics = @import("developer_diagnostics");
const developer_profile = @import("developer_profile");
const authority_diagnostics = @import("session_authority_diagnostics");
const sandbox_developer_host = @import("hosts/sandbox_developer_host.zig");
const incident_capture = @import("hosts/incident_capture.zig");
const incident_input_replay = @import("hosts/incident_input_replay.zig");
const neural_capture_host = @import("hosts/neural_capture_host.zig");
const neural_capture_camera = @import("hosts/neural_capture_camera.zig");
const neural_evaluation_fixture = @import("hosts/neural_evaluation_fixture.zig");
const neural_target_contract = @import("hosts/neural_target_contract.zig");
const neural_target_fixture = @import("hosts/neural_target_fixture.zig");
const neural_target_frame = @import("hosts/neural_target_frame.zig");
const neural_input_host = @import("hosts/neural_input_host.zig");
const neural_rendering_host = @import("hosts/neural_rendering_host.zig");
const sandbox_invocation = @import("sandbox_invocation");
const sandbox_authoring = @import("sandbox_authoring");
const sandbox_interaction = @import("sandbox_interaction");
const sandbox_persistence = @import("sandbox_persistence");
const camera = @import("camera.zig");
const sdl = @import("sdl.zig");
const shader_assets = @import("shader_assets");
const editor_contract = @import("editor/tool.zig");
const sandbox_host = @import("local_solo_session");
const combat_presentation = @import("combat_presentation");
const product_feedback = @import("sandbox/product_feedback.zig");
const product_presentation_trace = @import("sandbox/product_presentation_trace.zig");
const visibility_oracle = @import("visibility_oracle.zig");
const sandbox_contracts = @import("sandbox_host_contracts");
const session_budgets = @import("session_budgets");
const population = @import("population_contract");
const population_catalog = @import("sandbox_population_catalog");
const DeveloperSnapshot = sandbox_developer_host.Snapshot;
const NpcDiagnostics = @FieldType(sandbox_contracts.Diagnostics, "npc");
const CharacterControllerDiagnostics = @FieldType(
    sandbox_contracts.Diagnostics,
    "character_controllers",
);
// Use shared SDL bindings to avoid opaque type conflicts
const c = sdl.c;

test {
    _ = @import("hosts/incident_capture.zig");
    _ = @import("hosts/incident_input_replay.zig");
    _ = @import("hosts/neural_evaluation_fixture.zig");
    _ = @import("hosts/neural_target_contract.zig");
    _ = @import("hosts/neural_target_fixture.zig");
    _ = @import("hosts/neural_target_frame.zig");
}

const VisualSmokeConfig = sandbox_invocation.VisualSmokeConfig;
const ProgramMode = sandbox_invocation.ProgramMode;
const BootstrapProfile = sandbox_invocation.BootstrapProfile;
const ScriptedScenario = sandbox_invocation.ScriptedScenario;
const smokeExpectation = sandbox_invocation.smokeExpectation;
const parseProgramMode = sandbox_invocation.parseProgramMode;
const parseProductMode = sandbox_invocation.parseProductMode;
const parseContentRootOverride = sandbox_invocation.parseContentRootOverride;
const parseSaveRootOverride = sandbox_invocation.parseSaveRootOverride;
const SaveRootPath = sandbox_invocation.SaveRootPath;

fn authoringRejectionDetail(reason: sandbox_contracts.RejectionReason) []const u8 {
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
    result: sandbox_host.VehicleActionResult,
) bool {
    return switch (result.action) {
        .enter => result.disposition == .too_far or
            result.disposition == .unavailable or
            result.disposition == .invalid_state,
        .exit => result.disposition == .exit_blocked,
    };
}

// ============================================================================
// Configuration
// ============================================================================

const WINDOW_TITLE = "Incinerator Engine";
const INITIAL_WINDOW_WIDTH = 1600;
const INITIAL_WINDOW_HEIGHT = 900;

const diagnostic_interactive_vehicle_rejected: engine.diagnostic_contracts.Code = 0x000b_0003;

const authority_ticks_per_second: u64 = timing.TICK_RATE;
const s1_jump_tick: u64 = authority_ticks_per_second / 2;
const s2_enter_tick: u64 = authority_ticks_per_second * 2;
const s2_steer_tick: u64 = authority_ticks_per_second * 5 + 1;
const s2_brake_tick: u64 = s2_steer_tick - authority_ticks_per_second / 6;
const s2_hand_brake_tick: u64 = s2_brake_tick - authority_ticks_per_second / 6;
const s2_exit_tick: u64 = s2_steer_tick + authority_ticks_per_second / 2;
const s2_required_ticks: u64 = authority_ticks_per_second * 6;

const district_west_coord = sandbox_contracts.navigation_west_coord;
const district_east_coord = sandbox_contracts.navigation_east_coord;
const district_west_slot_index = district_streaming_host.west_slot_index;
const district_east_slot_index = district_streaming_host.east_slot_index;

const sandbox_block = sandbox_contracts.StaticBox{
    .position = .{ 0, 1, -5 },
    .half_extents = .{ 2, 1, 0.5 },
};

const FramePresentation = struct {
    crate_count: usize,
    first_id: ?sandbox_contracts.PersistentId,
    first_position: ?[3]f32,
    first_rotation: ?[4]f32,
    character_count: usize,
    character_id: ?sandbox_host.ReplicatedEntityId,
    character_position: ?[3]f32,
    vehicle_count: usize,
    vehicle_id: ?sandbox_host.ReplicatedEntityId,
    district_count: usize,
    carryable_count: usize,
    carryable_id: ?sandbox_host.ReplicatedEntityId,
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
    zero_tick_frames: u64 = 0,
    multi_tick_frames: u64 = 0,
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
    hand_brake_applied: bool = false,
    steering_observed: bool = false,
    wheel_spin_presented: bool = false,
    wheel_steering_presented: bool = false,
    vehicle_moved: bool = false,
    crate_displaced: bool = false,
    exited: bool = false,
    vehicle_position_before_drive: ?[3]f32 = null,
    crate_position_before_drive: ?[3]f32 = null,
    drive_input_sequence: ?u32 = null,
    steering_input_sequence: ?u32 = null,
    brake_input_sequence: ?u32 = null,
    hand_brake_input_sequence: ?u32 = null,
};

fn observeS2WheelPresentation(
    progress: *S2SmokeProgress,
    vehicle_draws: []const sandbox_host.VehicleDraw,
) void {
    for (vehicle_draws) |draw| {
        const chassis_axle = rotateVectorByQuaternion(
            draw.chassis_pose.rotation,
            .{ 1, 0, 0 },
        );
        const chassis_up = rotateVectorByQuaternion(
            draw.chassis_pose.rotation,
            .{ 0, 1, 0 },
        );
        for (draw.wheels) |wheel| {
            if (wheel.index == .front_left or wheel.index == .front_right) {
                const wheel_axle = rotateVectorByQuaternion(
                    wheel.pose.rotation,
                    .{ 1, 0, 0 },
                );
                progress.wheel_steering_presented =
                    progress.wheel_steering_presented or
                    @abs(dotVector3(chassis_axle, wheel_axle)) < 0.999;
            }
            const wheel_up = rotateVectorByQuaternion(
                wheel.pose.rotation,
                .{ 0, 1, 0 },
            );
            progress.wheel_spin_presented = progress.wheel_spin_presented or
                @abs(dotVector3(chassis_up, wheel_up)) < 0.995;
        }
    }
}

fn rotateVectorByQuaternion(rotation: [4]f32, value: [3]f32) [3]f32 {
    const vector = [3]f32{ rotation[0], rotation[1], rotation[2] };
    const doubled_cross = scaleVector3(crossVector3(vector, value), 2);
    return addVector3(
        addVector3(value, scaleVector3(doubled_cross, rotation[3])),
        crossVector3(vector, doubled_cross),
    );
}

fn addVector3(left: [3]f32, right: [3]f32) [3]f32 {
    return .{ left[0] + right[0], left[1] + right[1], left[2] + right[2] };
}

fn scaleVector3(value: [3]f32, scalar: f32) [3]f32 {
    return .{ value[0] * scalar, value[1] * scalar, value[2] * scalar };
}

fn dotVector3(left: [3]f32, right: [3]f32) f32 {
    return left[0] * right[0] + left[1] * right[1] + left[2] * right[2];
}

fn crossVector3(left: [3]f32, right: [3]f32) [3]f32 {
    return .{
        left[1] * right[2] - left[2] * right[1],
        left[2] * right[0] - left[0] * right[2],
        left[0] * right[1] - left[1] * right[0],
    };
}

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
const s6_fully_outside = [2]f32{ 64, 64 };
// The normal S12 product keeps both neighboring scenes visually warm. The S8
// validation composition needs a deliberately colder client focus so it can
// prove that east-side authority suspension is visually safe without changing
// the product prefetch policy.
const s8_west_only_prefetch = [2]f32{ -24, 0 };

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

    fn observe(self: *S6StreamingSmokeSummary, stats: developer_diagnostics.GpuUsage) void {
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
    east_content_unloaded,
    east_content_reloaded,
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
    physical_after_content_unload: bool = false,
    stable_after_content_reload: bool = false,
    final_entities: u32 = 0,
    final_bodies: u32 = 0,
};

const s7_replica_convergence_timeout_ticks: u64 = timing.TICK_RATE;
/// Drop beyond the east seam so the smoke proves authority ownership transfer
/// and district residency. The bounded carryable cohort itself is continuous
/// across this boundary.
const s7_east_relevance_drop_x: f32 = 9.0;

fn s7ReplicaConverged(
    current_tick: u64,
    wait_started_tick: *?u64,
    ready: bool,
) !bool {
    if (ready) {
        wait_started_tick.* = null;
        return true;
    }
    const started = wait_started_tick.* orelse start: {
        wait_started_tick.* = current_tick;
        break :start current_tick;
    };
    if (current_tick -| started > s7_replica_convergence_timeout_ticks) {
        return error.S7ReplicaConvergenceTimeout;
    }
    return false;
}

/// The installed S8 smoke proves one actor's complete authored-route and
/// district-residency lifecycle. Capacity and density are separate concerns:
/// the fresh-process S8 measurement and the IV2 real-Jolt cohort exercise the
/// complete 64-NPC / 65-controller ceiling without stacking colliding actors
/// on this smoke's single route origin.
const s8_population_count: usize = 1;
const s8_spawn_first_request_id: u64 = 8_000;
const s8_despawn_first_request_id: u64 = 9_000;
const s8_replica_convergence_timeout_ticks: u64 = timing.TICK_RATE;
const s8_west_start = sandbox_contracts.NavigationNodeRef{
    .coord = district_west_coord,
    .index = 2,
};
const s8_east_destination = sandbox_contracts.market_terminal_destination;

comptime {
    if (population.synthetic_command_capacity != sandbox_contracts.npc_capacity) {
        @compileError("the population producer and sandbox NPC budget must match");
    }
}

const S8SmokeStage = enum {
    overlap_resident,
    observer_spawned,
    population_spawned,
    destination_waiting,
    destination_reloaded,
    crossed_east,
    owner_dormant,
    owner_resumed,
    population_despawned,
    observer_despawned,
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

    fn observeGpu(self: *S8PopulationSmokeSummary, stats: developer_diagnostics.GpuUsage) void {
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
        character_count: u32,
    ) !void {
        if (controllers.native_capacity != 128 or
            controllers.native_used != controllers.feature_owned or
            controllers.feature_owned != diagnostics.controller_count + character_count or
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
            self.peak_native_controllers != s8_population_count + 1 or
            self.waiting_events != s8_population_count or
            self.waiting_resume_events != s8_population_count or
            self.transfer_events != s8_population_count or
            self.dormant_events != s8_population_count or
            self.controller_resume_events != s8_population_count or
            self.goal_events != s8_population_count or !self.two_resident_scenes or
            self.peak_live_scenes != 2 or self.peak_resident_scenes != 2 or
            self.peak_active_batches == 0 or self.peak_active_batches > 2 or
            self.peak_staged_cpu_bytes != installed_district_staged_cpu_bytes or
            self.peak_staged_upload_bytes != installed_district_gpu_bytes or
            self.peak_in_flight_upload_bytes == 0 or
            self.peak_in_flight_upload_bytes > 2 * installed_district_gpu_bytes or
            self.peak_in_flight_upload_bytes % installed_district_gpu_bytes != 0 or
            self.peak_resident_gpu_bytes != 2 * installed_district_gpu_bytes or
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

fn s8ReplicaConverged(
    current_tick: u64,
    wait_started_tick: *?u64,
    ready: bool,
) !bool {
    if (ready) {
        wait_started_tick.* = null;
        return true;
    }
    const started = wait_started_tick.* orelse start: {
        wait_started_tick.* = current_tick;
        break :start current_tick;
    };
    if (current_tick -| started > s8_replica_convergence_timeout_ticks) {
        return error.S8ReplicaConvergenceTimeout;
    }
    return false;
}

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
    identities: [s8_population_count]?sandbox_contracts.PersistentId = @splat(null),
    spawned: [s8_population_count]bool = @splat(false),
    first_destination_reached: [s8_population_count]bool = @splat(false),
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
            !allSeen(&self.first_destination_reached) or
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
        id: sandbox_contracts.PersistentId,
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
        outcome: sandbox_contracts.NpcOutcome,
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
        event: sandbox_contracts.NpcEvent,
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
                const index = self.indexForIdentity(reached.id) orelse
                    return error.UnexpectedS8NpcEvent;
                if ((stage != .population_spawned and stage != .destination_waiting) or
                    !sandbox_contracts.DestinationId.eql(
                        reached.destination,
                        sandbox_contracts.south_gate_approach_destination,
                    ) or
                    self.first_destination_reached[index])
                {
                    return error.UnexpectedS8NpcEvent;
                }
                self.first_destination_reached[index] = true;
                summary.goal_events += 1;
            },
        }
    }
};

const s11_hostile_population_member = population.PopulationMemberId{ .value = 1 };

const S11VisibilityCheckpoint = enum {
    contact,
    player_death,
    respawn,
    npc_death,

    fn label(self: S11VisibilityCheckpoint) []const u8 {
        return switch (self) {
            .contact => "contact_windup",
            .player_death => "player_death",
            .respawn => "player_respawn",
            .npc_death => "npc_death",
        };
    }
};

/// Validation-only state for the installed S11 acceptance. Authority results
/// drive the script, while these flags are set only beside the actual Metal
/// draw submissions that consume the extracted combat plans.
const S11CombatSmokeProgress = struct {
    active: bool = false,
    target_selected: bool = false,
    npc_id: ?sandbox_contracts.PersistentId = null,
    initial_incarnation: ?u16 = null,
    dead_incarnation: ?u16 = null,
    player_dead: bool = false,
    player_respawned: bool = false,
    respawn_accepted: bool = false,
    accepted_melee_hits: u8 = 0,
    provocation_hit: bool = false,
    npc_killed: bool = false,
    last_melee_request_tick: u64 = 0,
    last_respawn_request_tick: u64 = 0,

    character_bar_drawn: bool = false,
    npc_bar_drawn: bool = false,
    npc_windup_drawn: bool = false,
    character_hit_flash_drawn: bool = false,
    character_hit_flash_expired: bool = false,
    npc_hit_flash_drawn: bool = false,
    npc_hit_flash_expired: bool = false,
    melee_cooldown_marker_drawn: bool = false,
    respawn_countdown_marker_drawn: bool = false,
    respawn_ready_marker_drawn: bool = false,
    dead_hud_anchor_drawn: bool = false,
    player_death_drawn: bool = false,
    respawned_character_drawn: bool = false,
    npc_death_drawn: bool = false,
    product_hud_health: bool = false,
    product_hud_damage: bool = false,
    product_hud_death: bool = false,
    product_hud_windup: bool = false,
    product_hud_respawn_countdown: bool = false,
    product_hud_respawn_ready: bool = false,
    product_hud_action_feedback: bool = false,
    visibility_contact: bool = false,
    visibility_player_death: bool = false,
    visibility_respawn: bool = false,
    visibility_npc_death: bool = false,
    visibility_bounds_valid: bool = true,
    visibility_observations: u16 = 0,
    character_flash_tick: u64 = 0,
    character_flash_entity: ?sandbox_host.ReplicatedEntityId = null,
    character_flash_incarnation: u16 = 0,
    character_flash_health: u16 = 0,
    npc_flash_tick: u64 = 0,
    npc_flash_entity: ?sandbox_host.ReplicatedEntityId = null,
    npc_flash_incarnation: u16 = 0,
    npc_flash_health: u16 = 0,
    character_flash_overran: bool = false,
    npc_flash_overran: bool = false,
    render_plan_mismatch: bool = false,
    post_respawn_source_samples: u32 = 0,
    post_respawn_source_missing: u32 = 0,
    post_respawn_move_samples: u32 = 0,
    first_source_position: [3]f32 = @splat(0),
    first_npc_position: [3]f32 = @splat(0),
    last_source_position: [3]f32 = @splat(0),
    last_npc_position: [3]f32 = @splat(0),
    last_target_distance_squared: f32 = 0,

    fn expectedHealthBarDrawCalls(plan: combat_presentation.HealthBarPlan) u64 {
        if (!plan.visible) return 0;
        return if (plan.fraction <= 0) 1 else 2;
    }

    fn observeCharacter(
        self: *S11CombatSmokeProgress,
        authority_tick: u64,
        draw: sandbox_host.CharacterDraw,
        health_bar_draw_calls: u64,
    ) void {
        if (!self.active) return;
        const plan = draw.combat;
        if (!std.meta.eql(plan.entity, draw.entity) or
            plan.incarnation != draw.incarnation or plan.health != draw.health or
            plan.maximum_health != draw.maximum_health or
            plan.life_state != draw.life_state or
            health_bar_draw_calls != expectedHealthBarDrawCalls(plan.health_bar))
        {
            self.render_plan_mismatch = true;
        }
        self.character_bar_drawn = self.character_bar_drawn or
            (plan.health_bar.visible and health_bar_draw_calls != 0);
        if (self.initial_incarnation == null and draw.local_player and !plan.dead) {
            self.initial_incarnation = draw.incarnation;
        }
        if (plan.hit_flash and
            std.meta.eql(plan.body_color, combat_presentation.colors.hit_flash))
        {
            self.character_hit_flash_drawn = true;
            if (self.character_flash_entity == null or
                !std.meta.eql(self.character_flash_entity.?, draw.entity) or
                self.character_flash_incarnation != draw.incarnation or
                self.character_flash_health != draw.health)
            {
                self.character_flash_tick = authority_tick;
                self.character_flash_entity = draw.entity;
                self.character_flash_incarnation = draw.incarnation;
                self.character_flash_health = draw.health;
            } else if (authority_tick >= self.character_flash_tick +|
                combat_presentation.hit_flash_ticks)
            {
                self.character_flash_overran = true;
            }
        } else if (self.character_flash_entity) |entity| {
            if (std.meta.eql(entity, draw.entity) and
                self.character_flash_incarnation == draw.incarnation and
                self.character_flash_health == draw.health and
                authority_tick >= self.character_flash_tick +|
                    combat_presentation.hit_flash_ticks)
            {
                self.character_hit_flash_expired = true;
            }
        }
        if (self.player_respawned and draw.local_player and !plan.dead and
            self.dead_incarnation != null and
            draw.incarnation > self.dead_incarnation.?)
        {
            self.respawned_character_drawn = true;
        }
        if (draw.local_player and plan.dead and
            std.meta.eql(plan.body_color, combat_presentation.colors.dead) and
            plan.health_bar.visible and health_bar_draw_calls != 0)
        {
            self.player_death_drawn = true;
        }
    }

    fn observeNpc(
        self: *S11CombatSmokeProgress,
        authority_tick: u64,
        draw: sandbox_host.NpcDraw,
        health_bar_draw_calls: u64,
    ) void {
        if (!self.active) return;
        const plan = draw.combat;
        if (!std.meta.eql(plan.entity.entity, draw.entity) or
            plan.entity.incarnation != draw.incarnation or
            plan.entity.health != draw.health or
            plan.entity.maximum_health != draw.maximum_health or
            plan.entity.life_state != draw.life_state or
            plan.encounter_state != draw.encounter_state or
            health_bar_draw_calls != expectedHealthBarDrawCalls(plan.entity.health_bar))
        {
            self.render_plan_mismatch = true;
        }
        self.npc_bar_drawn = self.npc_bar_drawn or
            (plan.entity.health_bar.visible and health_bar_draw_calls != 0);
        self.npc_windup_drawn = self.npc_windup_drawn or
            (plan.windup and
                std.meta.eql(plan.entity.body_color, combat_presentation.colors.npc_windup));
        if (plan.entity.hit_flash and
            std.meta.eql(plan.entity.body_color, combat_presentation.colors.hit_flash))
        {
            self.npc_hit_flash_drawn = true;
            if (self.npc_flash_entity == null or
                !std.meta.eql(self.npc_flash_entity.?, draw.entity) or
                self.npc_flash_incarnation != draw.incarnation or
                self.npc_flash_health != draw.health)
            {
                self.npc_flash_tick = authority_tick;
                self.npc_flash_entity = draw.entity;
                self.npc_flash_incarnation = draw.incarnation;
                self.npc_flash_health = draw.health;
            } else if (authority_tick >= self.npc_flash_tick +|
                combat_presentation.hit_flash_ticks)
            {
                self.npc_flash_overran = true;
            }
        } else if (self.npc_flash_entity) |entity| {
            if (std.meta.eql(entity, draw.entity) and
                self.npc_flash_incarnation == draw.incarnation and
                self.npc_flash_health == draw.health and
                authority_tick >= self.npc_flash_tick +|
                    combat_presentation.hit_flash_ticks)
            {
                self.npc_hit_flash_expired = true;
            }
        }
        if (plan.entity.dead and
            std.meta.eql(plan.entity.body_color, combat_presentation.colors.dead) and
            plan.entity.health_bar.visible and health_bar_draw_calls != 0)
        {
            self.npc_death_drawn = true;
        }
    }

    fn observeHud(
        self: *S11CombatSmokeProgress,
        hud: sandbox_host.LocalCombatHud,
        marker_draw_calls: u64,
    ) void {
        if (!self.active or !hud.available) return;
        const expected_marker_draw_calls: u64 =
            @intFromBool(hud.melee_cooldown_marker) +
            @intFromBool(hud.respawn_marker != .none);
        if (marker_draw_calls != expected_marker_draw_calls) {
            self.render_plan_mismatch = true;
        }
        if (self.initial_incarnation == null and hud.life_state == .alive) {
            self.initial_incarnation = hud.incarnation;
        }
        if (hud.life_state == .dead) {
            self.player_dead = true;
            self.dead_incarnation = hud.incarnation;
        } else if (self.dead_incarnation) |dead_incarnation| {
            if (hud.incarnation > dead_incarnation) self.player_respawned = true;
        }
        if (hud.melee_cooldown_marker and marker_draw_calls != 0) {
            self.melee_cooldown_marker_drawn = true;
        }
        switch (hud.respawn_marker) {
            .countdown => if (marker_draw_calls != 0) {
                self.respawn_countdown_marker_drawn = true;
            },
            .ready => if (marker_draw_calls != 0) {
                self.respawn_ready_marker_drawn = true;
            },
            .none, .no_safe_spawn => {},
        }
        if (hud.life_state == .dead and hud.anchor_position != null and
            hud.respawn_marker != .none and marker_draw_calls != 0)
        {
            self.dead_hud_anchor_drawn = true;
        }
    }

    fn observeMeleeResult(
        self: *S11CombatSmokeProgress,
        result: sandbox_host.MeleeActionResult,
    ) void {
        if (!self.active or result.disposition != .hit) return;
        self.accepted_melee_hits +|= 1;
        if (!self.player_dead) self.provocation_hit = true;
        self.npc_killed = self.npc_killed or result.killed;
    }

    fn observeRespawnResult(
        self: *S11CombatSmokeProgress,
        result: sandbox_host.RespawnActionResult,
    ) void {
        if (!self.active or result.disposition != .respawned) return;
        self.respawn_accepted = true;
        self.player_respawned = true;
    }

    fn observeProductHud(
        self: *S11CombatSmokeProgress,
        view: *const editor_contract.GameplayView,
    ) void {
        if (!self.active) return;
        self.product_hud_health = self.product_hud_health or
            view.local_maximum_health != 0;
        self.product_hud_damage = self.product_hud_damage or
            view.local_damage_feedback;
        self.product_hud_death = self.product_hud_death or
            view.local_life_state == .dead;
        self.product_hud_respawn_countdown = self.product_hud_respawn_countdown or
            (view.local_life_state == .dead and view.respawn_remaining_ticks != 0);
        self.product_hud_respawn_ready = self.product_hud_respawn_ready or
            view.respawn_instruction_visible;
        self.product_hud_action_feedback = self.product_hud_action_feedback or
            view.last_action.sequence != 0;
        for (view.entitySlice()) |entity| {
            self.product_hud_windup = self.product_hud_windup or entity.attack_windup;
        }
    }

    fn requireComplete(self: S11CombatSmokeProgress) !void {
        if (!self.target_selected or !self.player_dead or !self.player_respawned or
            !self.respawn_accepted or self.accepted_melee_hits < 3 or
            !self.npc_killed or !self.character_bar_drawn or
            !self.npc_bar_drawn or !self.npc_windup_drawn or
            !self.character_hit_flash_drawn or
            !self.character_hit_flash_expired or
            !self.npc_hit_flash_drawn or !self.npc_hit_flash_expired or
            self.character_flash_overran or self.npc_flash_overran or
            self.render_plan_mismatch or
            !self.melee_cooldown_marker_drawn or
            !self.respawn_countdown_marker_drawn or
            !self.respawn_ready_marker_drawn or
            !self.dead_hud_anchor_drawn or
            !self.player_death_drawn or !self.respawned_character_drawn or
            !self.npc_death_drawn or
            !self.product_hud_health or !self.product_hud_damage or
            !self.product_hud_death or !self.product_hud_windup or
            !self.product_hud_respawn_countdown or
            !self.product_hud_respawn_ready or
            !self.product_hud_action_feedback or
            !self.visibility_contact or !self.visibility_player_death or
            !self.visibility_respawn or !self.visibility_npc_death or
            !self.visibility_bounds_valid or self.visibility_observations < 5)
        {
            std.debug.print(
                "S11_COMBAT_SMOKE_MISSING target_selected={} melee_hits={d} " ++
                    "player_dead={} player_respawned={} respawn_accepted={} " ++
                    "npc_killed={} character_bar={} npc_bar={} windup={} " ++
                    "character_flash={} npc_flash={} npc_death_drawn={} " ++
                    "char_flash_overran={} " ++
                    "npc_flash_overran={} render_plan_mismatch={} " ++
                    "char_flash_expired={} npc_flash_expired={} " ++
                    "visibility_contact={} visibility_death={} " ++
                    "visibility_respawn={} visibility_npc_death={} " ++
                    "visibility_bounds={} visibility_observations={d}\n",
                .{
                    self.target_selected,
                    self.accepted_melee_hits,
                    self.player_dead,
                    self.player_respawned,
                    self.respawn_accepted,
                    self.npc_killed,
                    self.character_bar_drawn,
                    self.npc_bar_drawn,
                    self.npc_windup_drawn,
                    self.character_hit_flash_drawn,
                    self.npc_hit_flash_drawn,
                    self.npc_death_drawn,
                    self.character_flash_overran,
                    self.npc_flash_overran,
                    self.render_plan_mismatch,
                    self.character_hit_flash_expired,
                    self.npc_hit_flash_expired,
                    self.visibility_contact,
                    self.visibility_player_death,
                    self.visibility_respawn,
                    self.visibility_npc_death,
                    self.visibility_bounds_valid,
                    self.visibility_observations,
                },
            );
            std.debug.print(
                "S11_COMBAT_SMOKE_TARGET post_respawn_sources={d} missing={d} moves={d} " ++
                    "first_source=({d:.3},{d:.3},{d:.3}) " ++
                    "first_npc=({d:.3},{d:.3},{d:.3}) " ++
                    "last_source=({d:.3},{d:.3},{d:.3}) " ++
                    "last_npc=({d:.3},{d:.3},{d:.3}) " ++
                    "distance_squared={d:.3}\n",
                .{
                    self.post_respawn_source_samples,
                    self.post_respawn_source_missing,
                    self.post_respawn_move_samples,
                    self.first_source_position[0],
                    self.first_source_position[1],
                    self.first_source_position[2],
                    self.first_npc_position[0],
                    self.first_npc_position[1],
                    self.first_npc_position[2],
                    self.last_source_position[0],
                    self.last_source_position[1],
                    self.last_source_position[2],
                    self.last_npc_position[0],
                    self.last_npc_position[1],
                    self.last_npc_position[2],
                    self.last_target_distance_squared,
                },
            );
            return error.S11CombatSmokeEvidenceMissing;
        }
    }
};

/// Installed-Metal evidence for the ordinary authored population. This tracks
/// only immutable client draws and copied diagnostics; it never drives or
/// repairs population authority.
const S13PopulationSmokeProgress = struct {
    active: bool = false,
    member_seen: [population.ordinary_member_count]bool = @splat(false),
    resident_seen: bool = false,
    worker_seen: bool = false,
    visitor_seen: bool = false,
    traveling_seen: bool = false,
    dwelling_seen: bool = false,
    waiting_seen: bool = false,
    full_cohort_reached: bool = false,
    full_cohort_frames: u64 = 0,
    incomplete_after_full_frames: u64 = 0,
    peak_draws: u8 = 0,
    invalid_identity: bool = false,
    district_seen: [sandbox_contracts.installed_district_coords.len]bool = @splat(false),
    four_district_frames: u64 = 0,
    member_seen_south: [population.ordinary_member_count]bool = @splat(false),
    member_seen_north: [population.ordinary_member_count]bool = @splat(false),

    fn observe(
        self: *S13PopulationSmokeProgress,
        draws: []const sandbox_host.NpcDraw,
        district_draws: []const district_feature_contract.DistrictDraw,
    ) void {
        if (!self.active) return;
        var district_frame = [_]bool{false} ** sandbox_contracts.installed_district_coords.len;
        for (district_draws) |draw| {
            for (sandbox_contracts.installed_district_coords, 0..) |coord, index| {
                if (!sandbox_contracts.ChunkCoord.eql(draw.build.coord, coord)) continue;
                district_frame[index] = true;
                self.district_seen[index] = true;
                break;
            }
        }
        var complete_district_frame = district_draws.len == district_frame.len;
        for (district_frame) |present| complete_district_frame = complete_district_frame and present;
        if (complete_district_frame) self.four_district_frames +|= 1;
        self.peak_draws = @max(
            self.peak_draws,
            std.math.cast(u8, draws.len) orelse std.math.maxInt(u8),
        );
        var current: [population.ordinary_member_count]bool = @splat(false);
        for (draws) |draw| {
            if (draw.population_member == 0 or
                draw.population_member > population.ordinary_member_count)
            {
                self.invalid_identity = true;
                continue;
            }
            const member_index = @as(usize, draw.population_member - 1);
            if (current[member_index]) self.invalid_identity = true;
            current[member_index] = true;
            self.member_seen[member_index] = true;
            if (draw.pose.position[2] < 8) {
                self.member_seen_south[member_index] = true;
            } else {
                self.member_seen_north[member_index] = true;
            }
            switch (draw.population_role) {
                .resident => self.resident_seen = true,
                .worker => self.worker_seen = true,
                .visitor => self.visitor_seen = true,
                .unassigned => self.invalid_identity = true,
            }
            switch (draw.activity_state) {
                .traveling => self.traveling_seen = true,
                .dwelling => self.dwelling_seen = true,
                .waiting_for_slot => self.waiting_seen = true,
                else => {},
            }
        }
        var complete = draws.len == population.ordinary_member_count;
        for (current) |present| complete = complete and present;
        if (complete) {
            self.full_cohort_reached = true;
            self.full_cohort_frames +|= 1;
        } else if (self.full_cohort_reached) {
            self.incomplete_after_full_frames +|= 1;
        }
    }

    fn requireComplete(
        self: S13PopulationSmokeProgress,
        diagnostics: ?population.Diagnostics,
        summary: RunSummary,
        config: VisualSmokeConfig,
    ) !void {
        var every_member = true;
        for (self.member_seen) |seen| every_member = every_member and seen;
        var every_district = true;
        for (self.district_seen) |seen| every_district = every_district and seen;
        var cross_axis_member = false;
        for (self.member_seen_south, self.member_seen_north) |south, north| {
            cross_axis_member = cross_axis_member or (south and north);
        }
        const state = diagnostics orelse return error.S13PopulationDiagnosticsMissing;
        if (!every_member or !self.resident_seen or !self.worker_seen or
            !self.visitor_seen or !self.traveling_seen or !self.dwelling_seen or
            !self.waiting_seen or !self.full_cohort_reached or
            self.full_cohort_frames == 0 or self.incomplete_after_full_frames != 0 or
            self.peak_draws != population.ordinary_member_count or
            self.invalid_identity or !every_district or self.four_district_frames == 0 or
            !cross_axis_member or state.live != population.ordinary_member_count or
            state.awaiting_spawn != 0 or state.vacant != 0 or
            state.replacement_pending != 0 or state.slot_contentions == 0 or
            state.intents.occupancy != 0 or state.intents.rejected != 0 or
            (config.virtual_render_hz > timing.TICK_RATE and
                (summary.zero_tick_frames == 0 or summary.multi_tick_frames != 0)) or
            (config.virtual_render_hz < timing.TICK_RATE and
                (summary.multi_tick_frames == 0 or summary.zero_tick_frames != 0)))
        {
            std.debug.print(
                "S13_POPULATION_SMOKE_MISSING members={} roles={}/{}/{} " ++
                    "traveling={} dwelling={} waiting={} full={} full_frames={d} " ++
                    "incomplete_after_full={d} peak_draws={d} invalid_identity={} " ++
                    "live={d} awaiting={d} vacant={d} replacing={d} " ++
                    "contentions={d} intents={d}/{d} districts={} district_frames={d} " ++
                    "cross_axis={} cadence={d}/{d}\n",
                .{
                    every_member,
                    self.resident_seen,
                    self.worker_seen,
                    self.visitor_seen,
                    self.traveling_seen,
                    self.dwelling_seen,
                    self.waiting_seen,
                    self.full_cohort_reached,
                    self.full_cohort_frames,
                    self.incomplete_after_full_frames,
                    self.peak_draws,
                    self.invalid_identity,
                    state.live,
                    state.awaiting_spawn,
                    state.vacant,
                    state.replacement_pending,
                    state.slot_contentions,
                    state.intents.occupancy,
                    state.intents.rejected,
                    every_district,
                    self.four_district_frames,
                    cross_axis_member,
                    summary.zero_tick_frames,
                    summary.multi_tick_frames,
                },
            );
            return error.S13PopulationSmokeEvidenceMissing;
        }
    }
};

const S14RangedCombatSmokeProgress = struct {
    active: bool = false,
    target_selected: bool = false,
    target_member: u16 = 0,
    target_actor: ?engine.PersistentId = null,
    target_entity: ?sandbox_host.ReplicatedEntityId = null,
    target_generation: u16 = 0,
    equipped: bool = false,
    committed_drain_shots: u8 = 0,
    cadence_rejected: bool = false,
    empty_rejected: bool = false,
    reload_started: bool = false,
    reload_completed: bool = false,
    hit_count: u8 = 0,
    target_killed: bool = false,
    target_draw_observed: bool = false,
    target_draw_generation: u16 = 0,
    target_death_drawn: bool = false,
    target_replaced: bool = false,
    weapon_drawn: bool = false,
    tracer_drawn: bool = false,
    ammo_hud_observed: bool = false,
    last_fire_request_tick: u64 = 0,
    last_empty_request_tick: u64 = 0,

    fn observeWeaponResult(
        self: *S14RangedCombatSmokeProgress,
        result: sandbox_host.WeaponActionResult,
    ) void {
        if (!self.active) return;
        switch (result.disposition) {
            .equipped => self.equipped = true,
            .fired_miss => if (!self.reload_completed) {
                self.committed_drain_shots +|= 1;
            },
            .fired_hit => if (self.reload_completed) {
                const target = self.target_entity orelse return;
                if (std.meta.eql(result.target, target) and
                    result.target_incarnation == self.target_generation)
                {
                    self.hit_count +|= 1;
                    self.target_killed = self.target_killed or result.killed;
                }
            } else {
                // The drain phase proves committed ammo consumption. A moving
                // population member can cross the ray before the physical
                // blocker, so both committed outcomes advance the phase.
                self.committed_drain_shots +|= 1;
            },
            .cooldown => self.cadence_rejected = true,
            .empty => self.empty_rejected = true,
            .reload_started => self.reload_started = true,
            else => {},
        }
    }

    fn observeNpc(self: *S14RangedCombatSmokeProgress, draw: sandbox_host.NpcDraw) void {
        if (!self.active or draw.population_member != self.target_member) return;
        if (!self.target_draw_observed and draw.life_state == .alive) {
            self.target_draw_observed = true;
            self.target_draw_generation = draw.incarnation;
        }
        if (draw.incarnation == self.target_generation and draw.life_state == .dead) {
            self.target_death_drawn = true;
        }
        if (self.target_killed and draw.incarnation > self.target_generation and
            draw.life_state == .alive)
        {
            self.target_replaced = true;
        }
    }

    fn observeHud(
        self: *S14RangedCombatSmokeProgress,
        hud: combat_presentation.LocalHud,
    ) void {
        if (!self.active or !hud.available) return;
        self.ammo_hud_observed = self.ammo_hud_observed or
            hud.weapon_mode != .holstered or hud.magazine_ammo != 0 or
            hud.reserve_ammo != 0;
        if (self.reload_started and hud.weapon_mode == .equipped and
            hud.magazine_ammo > 0 and hud.reload_remaining_ticks == 0)
        {
            self.reload_completed = true;
        }
    }

    fn requireComplete(self: S14RangedCombatSmokeProgress) !void {
        if (!self.target_selected or !self.equipped or
            self.committed_drain_shots != 12 or !self.cadence_rejected or
            !self.empty_rejected or !self.reload_started or
            !self.reload_completed or self.hit_count < 4 or
            !self.target_killed or !self.target_death_drawn or
            !self.target_replaced or !self.weapon_drawn or !self.tracer_drawn or
            !self.ammo_hud_observed)
        {
            std.debug.print(
                "S14_RANGED_SMOKE_MISSING target={} equipped={} drain={d} " ++
                    "cadence={} empty={} reload={}/{} hits={d} killed={} " ++
                    "draw={}:{d} death_draw={} replacement={} " ++
                    "weapon_draw={} tracer_draw={} hud={}\n",
                .{
                    self.target_selected,
                    self.equipped,
                    self.committed_drain_shots,
                    self.cadence_rejected,
                    self.empty_rejected,
                    self.reload_started,
                    self.reload_completed,
                    self.hit_count,
                    self.target_killed,
                    self.target_draw_observed,
                    self.target_draw_generation,
                    self.target_death_drawn,
                    self.target_replaced,
                    self.weapon_drawn,
                    self.tracer_drawn,
                    self.ammo_hud_observed,
                },
            );
            return error.S14RangedCombatSmokeEvidenceMissing;
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
const installed_district_meshes: usize = 4;
const installed_district_materials: usize = 4;
const installed_district_instances: usize = 16;
const installed_district_staged_cpu_bytes: u64 = 3_888;
const installed_district_gpu_bytes: u64 = 2_528;
const s4_smoke_pause_frames: u64 = 600;
const s4_smoke_pause_frame_seconds: f64 = 1.0 / 30.0;
const s4_smoke_stream_attempt_limit: u32 = 480;

fn updateS3SmokePeaks(
    summary: *S3StreamingSmokeSummary,
    stats: developer_diagnostics.GpuUsage,
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
    try district_streaming_host.validateCatalogEntries(admitted.view().entries);
}

// ============================================================================
// Application State
// ============================================================================

const IncidentRunMode = enum {
    interactive,
    smoke,
    benchmark,
    journey,
    journey_window,

    fn isJourney(self: IncidentRunMode) bool {
        return self == .journey or self == .journey_window;
    }
};

const incident_benchmark_warmup_frames: u64 = 300;
const incident_benchmark_sample_count: usize = 2_400;

const IncidentBenchmarkProgress = struct {
    samples_ns: [incident_benchmark_sample_count]u64 = undefined,
    count: usize = 0,

    fn observe(self: *IncidentBenchmarkProgress, frame_seconds: f64) void {
        if (self.count == self.samples_ns.len) return;
        const bounded_seconds = @max(frame_seconds, 0);
        self.samples_ns[self.count] = @intFromFloat(@min(
            bounded_seconds * @as(f64, @floatFromInt(std.time.ns_per_s)),
            @as(f64, @floatFromInt(std.math.maxInt(u64))),
        ));
        self.count += 1;
    }

    fn complete(self: *const IncidentBenchmarkProgress) bool {
        return self.count == self.samples_ns.len;
    }

    fn report(
        self: *IncidentBenchmarkProgress,
        snapshot: sandbox_developer_host.Owner.IncidentBenchmarkSnapshot,
    ) void {
        std.mem.sort(u64, self.samples_ns[0..self.count], {}, std.sort.asc(u64));
        const p50 = self.samples_ns[percentileIndex(self.count, 50)];
        const p95 = self.samples_ns[percentileIndex(self.count, 95)];
        const p99 = self.samples_ns[percentileIndex(self.count, 99)];
        const fence_mean = if (snapshot.fence_latency_samples == 0)
            0
        else
            snapshot.fence_latency_total_ns / snapshot.fence_latency_samples;
        std.debug.print(
            "INCIDENT_CAPTURE_BENCHMARK capture={} samples={d} " ++
                "frame_p50_ns={d} frame_p95_ns={d} frame_p99_ns={d} " ++
                "download_bytes={d} queue_high_water={d} dropped={d} " ++
                "artifact_bytes={d} screenshot_misses={d} " ++
                "trail={d}/{d} anchors={d}/{d} " ++
                "fence_samples={d} fence_mean_ns={d} fence_max_ns={d}\n",
            .{
                snapshot.enabled,
                self.count,
                p50,
                p95,
                p99,
                snapshot.bounded_download_bytes,
                snapshot.queue_high_water,
                snapshot.dropped_records,
                snapshot.bytes_written,
                snapshot.screenshot_misses,
                snapshot.trail_completed,
                snapshot.trail_submitted,
                snapshot.anchor_completed,
                snapshot.anchor_submitted,
                snapshot.fence_latency_samples,
                fence_mean,
                snapshot.fence_latency_max_ns,
            },
        );
    }
};

fn percentileIndex(length: usize, percentile: usize) usize {
    std.debug.assert(length != 0 and percentile <= 100);
    return ((length - 1) * percentile) / 100;
}

const IncidentJourneyStage = enum {
    bootstrap,
    collect,
    drop,
    enter_vehicle,
    drive,
    exit_vehicle,
    reenter_vehicle,
    second_exit_vehicle,
    travel_east,
    return_west,
    await_player_death,
    respawn,
    fight_npc,
    complete,
};

const IncidentJourneyNpc = struct {
    entity: sandbox_host.ReplicatedEntityId,
    incarnation: u16,
    population_member: u16,
};

const IncidentJourneyProgress = struct {
    stage: IncidentJourneyStage = .bootstrap,
    stage_enter_tick: u64 = 0,
    resume_after_respawn: ?IncidentJourneyStage = null,
    initial_npc: ?IncidentJourneyNpc = null,
    entered_vehicle: bool = false,
    reentered_vehicle: bool = false,
    saw_east: bool = false,
    saw_returned_west: bool = false,
    saw_player_dead: bool = false,
    saw_player_respawned: bool = false,
    saw_npc_dead: bool = false,
    npc_dead_tick: u64 = 0,
    saw_npc_replacement: bool = false,
    resized: bool = false,
    resize_requested_tick: u64 = 0,
    restored_size: bool = false,
    restore_size_tick: u64 = 0,
    minimize_requested: bool = false,
    minimized_event: bool = false,
    minimized_started_ns: u64 = 0,
    restore_requested: bool = false,
    restored_event: bool = false,
    exercise_window_lifecycle: bool = false,
    flag_count: u8 = 0,
    rapid_flags_completed: bool = false,
    completion_flagged: bool = false,
    last_flag_tick: u64 = 0,
    handoff_requested: bool = false,
    handoff_request_tick: u64 = 0,

    fn enter(self: *IncidentJourneyProgress, stage: IncidentJourneyStage, tick: u64) void {
        self.stage = stage;
        self.stage_enter_tick = tick;
    }
};

const ValidationAppState = if (build_options.validation_mode or builtin.is_test) struct {
    profile: BootstrapProfile = .sandbox,
    s4_physics_debug_evidence: S4PhysicsDebugEvidence = .{},
    s2_smoke: S2SmokeProgress = .{},
    s7_scripted_move: [2]f32 = .{ 0, 0 },
    s7_character_actions_enabled: bool = true,
    s11_combat: S11CombatSmokeProgress = .{},
    s13_population: S13PopulationSmokeProgress = .{},
    s14_ranged_combat: S14RangedCombatSmokeProgress = .{},
    s4_fault_loop_probe: ?*S4FaultLoopProbe = null,
} else void;

const VisibilityOracleState = if (build_options.validation_mode)
    ?visibility_oracle.Owner
else
    void;

const RenderFrameAudit = struct {
    valid: bool = false,
    semantic: engine.neural_rendering.SemanticClass = .background,
    part: engine.neural_rendering.SemanticPart = .whole,
    ordinal: u16 = 0,
    surface: sandbox_visual_catalog.Surface = .ground,
};

fn authoringWallNowMs(io: std.Io) i64 {
    const nanoseconds = std.Io.Clock.Timestamp.now(io, .real).raw.nanoseconds;
    const milliseconds = @divFloor(nanoseconds, std.time.ns_per_ms);
    return std.math.cast(i64, milliseconds) orelse if (milliseconds < 0)
        std.math.minInt(i64)
    else
        std.math.maxInt(i64);
}

fn makeAuthoringRunId(io: std.Io) engine.authoring.RunId {
    const nanoseconds = std.Io.Clock.Timestamp.now(io, .real).raw.nanoseconds;
    const wall_ms = authoringWallNowMs(io);
    const nonce = if (nanoseconds > 0)
        std.math.cast(u64, nanoseconds) orelse @as(u64, @bitCast(wall_ms))
    else
        @as(u64, @bitCast(wall_ms));
    return .{
        .started_wall_unix_ms = wall_ms,
        .nonce = if (nonce == 0) 1 else nonce,
    };
}

const App = struct {
    io: std.Io,
    window: *c.SDL_Window,
    gpu_renderer: renderer.Renderer,
    developer: *sandbox_developer_host.Owner,
    frame_timer: timing.FrameTimer,
    input_buffer: input.InputBuffer,
    neural_rendering: ?neural_rendering_host.Owner = null,
    neural_inputs: ?neural_input_host.Owner = null,
    neural_capture: ?neural_capture_host.Owner = null,
    neural_target_frames: ?neural_target_frame.Owner = null,
    neural_capture_camera_program: ?neural_capture_camera.Program = null,
    neural_evaluation_fixture_enabled: bool = false,
    neural_target_fixture_enabled: bool = false,
    neural_trial_fixture_enabled: bool = false,
    neural_target_fixture_variant: neural_target_fixture.Variant = .urban_day,
    neural_evaluation_resize_frame: ?u64 = null,
    render_frame_audit: RenderFrameAudit = .{},

    simulation: *sandbox_host.Placement,
    initial_crate_id: ?sandbox_contracts.PersistentId,
    initial_character_id: ?sandbox_contracts.PersistentId,
    initial_vehicle_id: ?sandbox_contracts.PersistentId,
    initial_carryable_id: ?sandbox_contracts.PersistentId,
    controlled_vehicle_id: ?sandbox_host.ReplicatedEntityId,
    action_latch: sandbox_controls.ActionLatch,
    authoring_transactions: *sandbox_authoring.TransactionSequencer,
    // This controller owns the visual composition's authoring request buffer.
    // External producers use the M3 transaction-to-owner router instead of
    // sharing and filtering this outcome lane.
    authoring_controller: sandbox_authoring.DefaultController,
    authoring_requests: sandbox_authoring.RequestBuffer,
    authoring_feedback: editor_contract.AuthoringFeedback,
    authoring_run_id: engine.authoring.RunId,
    latest_authoring_change: ?sandbox_authoring.ChangeEvidence,
    interaction_spawn_enabled: bool,
    interaction_spawn_submitted: bool,
    interaction_transactions: sandbox_interaction.TransactionSequencer,
    interaction_requests: sandbox_interaction.RequestBuffer,
    interaction_last_outcome: ?sandbox_contracts.InteractionOutcome,
    interaction_last_player_result: ?sandbox_host.InteractionActionResult,
    interaction_submission_failures: u64,
    navigation_requests: editor_contract.NavigationRequestBuffer = .{},
    navigation_next_request_id: u64 = 0x4e41_5600_0000_0001,
    product_feedback: product_feedback.Owner,
    product_presentation_trace: product_presentation_trace.Owner,
    last_weapon_draw_signature: u64 = 0,
    last_tracer_draw_signature: u64 = 0,
    product_character_lifecycle: sandbox_product_character_lifecycle.Owner,
    validation: ValidationAppState,
    validation_tick_origin: u64 = 0,
    game_camera: camera.Camera,
    // Presentation resources remain owned by the visual host.
    ground_mesh: mesh.Mesh,
    block_mesh: mesh.Mesh,
    visuals: sandbox_visual_resources.SandboxVisualResources,
    visibility_oracle: VisibilityOracleState,
    district_streaming: *district_streaming_host.Owner,
    district_focus_override: ?[2]f32,
    district_prefetch_focus_override: ?[2]f32,

    // The persistence host owns canonical capture and durable commit policy.
    // The editor receives only an immutable feedback projection and a bounded
    // request surface.
    persistence: *sandbox_persistence.Owner,
    persistence_commit_pending: bool = false,

    pub fn init(
        io: std.Io,
        comptime profile: BootstrapProfile,
        content_root: ?content.ContentRootPath,
    ) !App {
        return initWithOptions(io, profile, content_root, null, false, false, null, null, .none);
    }

    pub fn initWithSaveRoot(
        io: std.Io,
        comptime profile: BootstrapProfile,
        content_root: ?content.ContentRootPath,
        save_root: SaveRootPath,
    ) !App {
        return initWithOptions(io, profile, content_root, null, false, false, save_root, null, .none);
    }

    pub fn initProduct(
        io: std.Io,
        content_root: ?content.ContentRootPath,
        save_root: ?SaveRootPath,
        incident_runs_root: ?[]const u8,
        incident_hardening_profile: incident_capture.HardeningProfile,
    ) !App {
        return initWithOptions(
            io,
            .sandbox,
            content_root,
            null,
            false,
            false,
            save_root,
            incident_runs_root,
            incident_hardening_profile,
        );
    }

    fn initForDiagnosticsSmoke(
        io: std.Io,
        comptime profile: BootstrapProfile,
        content_root: ?content.ContentRootPath,
        save_root: ?SaveRootPath,
    ) !App {
        return initWithOptions(io, profile, content_root, null, false, true, save_root, null, .none);
    }

    fn initWithFailurePoint(
        io: std.Io,
        comptime profile: BootstrapProfile,
        content_root: ?content.ContentRootPath,
        comptime failure_point: AppInitFailurePoint,
    ) !App {
        return initWithOptions(io, profile, content_root, failure_point, false, false, null, null, .none);
    }

    fn initWithoutPhysicsDebugPipelinesForTest(
        io: std.Io,
        comptime profile: BootstrapProfile,
        content_root: ?content.ContentRootPath,
    ) !App {
        return initWithOptions(io, profile, content_root, null, true, false, null, null, .none);
    }

    fn initWithOptions(
        io: std.Io,
        comptime profile: BootstrapProfile,
        content_root: ?content.ContentRootPath,
        comptime failure_point: ?AppInitFailurePoint,
        comptime omit_physics_debug_pipelines: bool,
        comptime diagnostic_fault_probe: bool,
        save_root: ?SaveRootPath,
        incident_runs_root: ?[]const u8,
        incident_hardening_profile: incident_capture.HardeningProfile,
    ) !App {
        const authoring_run_id = makeAuthoringRunId(io);
        try authoring_run_id.validate();
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

        const developer = try sandbox_developer_host.Owner.init(
            std.heap.page_allocator,
            io,
            window,
            &gpu_renderer,
            if (build_options.incident_capture_enabled) incident_runs_root else null,
            incident_hardening_profile,
        );
        errdefer developer.deinit();

        try gpu_renderer.setSceneLight(sandbox_visual_catalog.scene_light);

        // Create conventional normal-bearing product geometry.
        var ground_mesh = try primitives.createLitGroundPlane(gpu_renderer.getDevice());
        errdefer ground_mesh.deinit();

        var block_mesh = try primitives.createLitCube(gpu_renderer.getDevice());
        errdefer block_mesh.deinit();

        const character_config = sandbox_contracts.CharacterConfig{
            .assets = .{
                .mesh = sandbox_visual_resources.character_mesh_handle,
                .material = sandbox_visual_resources.character_material_handle,
            },
        };
        if (profile == .sandbox) {
            try sandbox_contracts.validateDefaultCharacterSpawn(character_config);
        }
        const vehicle_config = sandbox_contracts.VehicleConfig{
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
        var validation_visibility: VisibilityOracleState = if (build_options.validation_mode)
            try visibility_oracle.Owner.init(&gpu_renderer)
        else {};
        errdefer if (build_options.validation_mode) {
            if (validation_visibility) |*owner| owner.deinit();
        };
        if (failure_point != null) {
            try injectAppInitFailure(failure_point, .after_visual_resources);
        }

        // Admit the exact content cohort before cold authority construction so
        // developer incident recording can begin at the only honest replay
        // boundary. Streaming remains a separate owner after admission.
        const streams_districts = profile == .sandbox or profile == .s3_smoke;
        const needs_catalog = streams_districts or save_root != null;
        const district_streaming = try district_streaming_host.Owner.init(
            io,
            std.heap.page_allocator,
            gpu_renderer.getDevice(),
            .{
                .stream_content = streams_districts,
                .admit_catalog = needs_catalog,
                .content_root = content_root,
                .pin_route_resident = profile == .sandbox,
            },
        );
        errdefer district_streaming.abortInit();

        // The visual solo product owns an embedded authority session.
        const simulation_config = sandbox_contracts.Config{
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
            .authored_population = profile == .sandbox,
            .block = switch (profile) {
                .s1_smoke => sandbox_block,
                .sandbox => null,
                .s0_smoke, .s2_smoke, .s3_smoke => null,
            },
        };
        const embedded = if (diagnostic_fault_probe)
            try sandbox_host.Placement.initCompositionWithDiagnosticFaultProbe(
                std.heap.page_allocator,
                simulation_config,
            )
        else
            try sandbox_host.Placement.initComposition(
                std.heap.page_allocator,
                simulation_config,
                .{ .recording_content = if (incident_runs_root != null)
                    try district_streaming.contentCohort()
                else
                    null },
            );
        const simulation = embedded.placement;
        const persistence_source = embedded.snapshot_source;
        errdefer simulation.deinit();
        if (failure_point != null) {
            try injectAppInitFailure(failure_point, .after_simulation);
        }

        const authoring_transactions = try std.heap.page_allocator.create(
            sandbox_authoring.TransactionSequencer,
        );
        errdefer std.heap.page_allocator.destroy(authoring_transactions);
        authoring_transactions.* = .{};

        const persistence = if (save_root) |root_path| owner: {
            const authority_cohort = simulation.inspection().persistenceCohort();
            break :owner try sandbox_persistence.Owner.open(
                io,
                std.heap.page_allocator,
                root_path,
                .{
                    .payload_schema = authority_cohort.payload_schema,
                    .simulation_build_digest = authority_cohort.simulation_build_digest,
                    .world_config_digest = authority_cohort.world_config_digest,
                    .content_digest = try district_streaming.contentDigest(),
                },
                persistence_source,
            );
        } else try sandbox_persistence.Owner.withoutStorage(
            std.heap.page_allocator,
            persistence_source,
        );
        errdefer persistence.deinit(io);

        if (profile != .s3_smoke) {
            try simulation.crates().submit(.{ .spawn = .{
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
            try simulation.characters().submit(.{ .spawn = .{
                .request_id = 1,
                .position = switch (profile) {
                    .s2_smoke => .{ 0, 0, 2 },
                    .sandbox => sandbox_contracts.default_character_spawn_position,
                    .s1_smoke => .{ 0, 0, 4 },
                    .s0_smoke, .s3_smoke => unreachable,
                },
            } });
        }
        if (profile == .sandbox or profile == .s2_smoke) {
            try simulation.vehicles().submit(.{ .spawn = .{
                .request_id = 1,
                .chassis = .{ .pose = .{ .position = switch (profile) {
                    .sandbox => sandbox_contracts.default_vehicle_spawn_position,
                    .s2_smoke => .{ 0, 2, 0 },
                    .s0_smoke, .s1_smoke, .s3_smoke => unreachable,
                } } },
            } });
        }

        std.debug.print("===========================================\n", .{});
        std.debug.print(" Incinerator Engine initialized ({s} composition)\n", .{@tagName(profile)});
        std.debug.print(" Window: {d}x{d}\n", .{ INITIAL_WINDOW_WIDTH, INITIAL_WINDOW_HEIGHT });
        std.debug.print(" Tick rate: {d} Hz ({d:.3} ms)\n", .{ timing.TICK_RATE, timing.TICK_DURATION * 1000.0 });
        std.debug.print("===========================================\n", .{});
        std.debug.print(" Controls:\n", .{});
        std.debug.print("   Click playable area - Capture mouse for continuous look\n", .{});
        std.debug.print("   ESC - Release captured mouse / quit while mouse is free\n", .{});
        std.debug.print("   WASD - Move character / drive vehicle\n", .{});
        std.debug.print("   E - Enter / exit vehicle\n", .{});
        std.debug.print("   F - Collect / drop carryable\n", .{});
        std.debug.print("   Q - Authoritative melee\n", .{});
        std.debug.print("   1 - Equip / holster handgun\n", .{});
        std.debug.print("   Left-click - Fire equipped handgun\n", .{});
        std.debug.print("   R - Reload / respawn after death\n", .{});
        std.debug.print("   SPACE - Jump / vehicle brake\n", .{});
        std.debug.print("   LEFT SHIFT - Vehicle hand brake\n", .{});
        std.debug.print("   Right-click + drag - Turn/look without capture\n", .{});
        std.debug.print("   F1 - Toggle editor UI\n", .{});
        std.debug.print("   F2 - Toggle ImGui demo\n", .{});
        std.debug.print("   F3 - Toggle editor input passthrough\n", .{});
        if (developer.incidentRunPath() != null) {
            std.debug.print("   Cmd+Option+I - Flag human-test anomaly\n", .{});
            std.debug.print("   F9 / Fn+F9 - Optional anomaly shortcut\n", .{});
        }
        std.debug.print("===========================================\n\n", .{});

        var input_buffer = input.InputBuffer.init(main_window_id);
        try input_buffer.attachGameplayMouseWindow(window);

        return App{
            .io = io,
            .window = window,
            .gpu_renderer = gpu_renderer,
            .developer = developer,
            .frame_timer = timing.FrameTimer.init(),
            .input_buffer = input_buffer,
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
            .authoring_run_id = authoring_run_id,
            .latest_authoring_change = null,
            .interaction_spawn_enabled = profile == .sandbox,
            .interaction_spawn_submitted = false,
            .interaction_transactions = .{},
            .interaction_requests = .{},
            .interaction_last_outcome = null,
            .interaction_last_player_result = null,
            .interaction_submission_failures = 0,
            .product_feedback = .{},
            .product_presentation_trace = .{},
            .product_character_lifecycle = .{},
            .validation = if (build_options.validation_mode or builtin.is_test)
                .{ .profile = profile }
            else {},
            .ground_mesh = ground_mesh,
            .block_mesh = block_mesh,
            .visuals = visuals,
            .visibility_oracle = validation_visibility,
            .district_streaming = district_streaming,
            .district_focus_override = null,
            .district_prefetch_focus_override = null,
            .persistence = persistence,
            .game_camera = .{
                .position = .{ 0, 3, 10, 1 },
                .yaw = 0,
                .pitch = -0.25,
            },
        };
    }

    pub fn deinit(self: *App) void {
        const completed_ticks = self.simulation.inspection().tickIndex();

        self.input_buffer.detachGameplayMouseWindow();

        // Errors may unwind after external buffers were encoded into a frame
        // but before normal submission. Retire and drain that work before any
        // editor, overlay, mesh, texture, or streamed-GPU owner is released.
        self.gpu_renderer.drainForExternalTeardown();

        if (self.neural_target_frames) |*owner| owner.deinit();
        if (self.neural_capture) |*owner| owner.deinit();
        if (self.neural_inputs) |*owner| owner.deinit();
        if (self.neural_rendering) |*owner| owner.deinit(&self.gpu_renderer);

        if (build_options.validation_mode) {
            if (self.visibility_oracle) |*owner| owner.deinit();
        }

        // The developer owner releases ImGui and optional debug GPU resources
        // while the renderer device is still valid.
        self.developer.deinit();
        self.district_streaming.prepareAuthorityTeardown();
        self.persistence.deinit(self.io);
        self.simulation.deinit();
        std.heap.page_allocator.destroy(self.authoring_transactions);
        self.district_streaming.deinitAfterAuthority();
        self.ground_mesh.deinit();
        self.block_mesh.deinit();
        self.visuals.deinit();
        self.gpu_renderer.deinit();
        c.SDL_DestroyWindow(self.window);
        c.SDL_Quit();

        std.debug.print("\n===========================================\n", .{});
        std.debug.print(" Incinerator Engine shutdown\n", .{});
        std.debug.print(" Total frames: {d}\n", .{self.frame_timer.total_frames});
        std.debug.print(" Total simulation ticks: {d}\n", .{completed_ticks});
        std.debug.print("===========================================\n", .{});
    }

    fn configureNeuralRendering(self: *App, environ_map: anytype) !void {
        const trial_bundle_root = environ_map.get("INCINERATOR_NR_TRIAL_BUNDLE");
        const capture_root = environ_map.get("INCINERATOR_NR_CAPTURE_ROOT");
        const target_frame_root = environ_map.get("INCINERATOR_NR_TARGET_FRAME_ROOT");
        self.neural_target_fixture_variant = if (environ_map.get("INCINERATOR_NR_FIXTURE_VARIANT")) |value|
            try neural_target_fixture.Variant.parse(value)
        else
            .urban_day;
        const lab_requested = if (environ_map.get("INCINERATOR_NR_LAB")) |value|
            std.mem.eql(u8, value, "1") or std.ascii.eqlIgnoreCase(value, "true")
        else
            false;
        const trial_fixture_requested = if (environ_map.get("INCINERATOR_NR_TRIAL_FIXTURE")) |value|
            std.mem.eql(u8, value, "1") or std.ascii.eqlIgnoreCase(value, "true")
        else
            false;
        if (trial_fixture_requested) {
            if (trial_bundle_root == null) return error.NeuralTrialFixtureRequiresBundle;
            if (target_frame_root != null) return error.NeuralTrialFixtureConflictsWithTargetExport;
            self.neural_evaluation_fixture_enabled = false;
            self.neural_target_fixture_enabled = true;
            self.neural_trial_fixture_enabled = true;
        }
        if (target_frame_root != null) {
            if (!build_options.validation_mode) return error.NeuralTargetFrameValidationOnly;
            if (capture_root == null) return error.NeuralTargetFrameRequiresCapture;
            self.neural_evaluation_fixture_enabled = false;
            self.neural_target_fixture_enabled = true;
        }
        if (trial_bundle_root == null and capture_root == null and target_frame_root == null and
            !lab_requested and
            !self.neural_evaluation_fixture_enabled) return;
        if (trial_bundle_root) |path| if (!std.fs.path.isAbsolute(path)) {
            return error.NeuralTrialBundlePathMustBeAbsolute;
        };

        // Fixed scene pixels belong to the explicitly activated experiment,
        // not to the ordinary deterministic product renderer.
        self.gpu_renderer.setFixedSceneExtent(
            renderer.neural_experiment_scene_width,
            renderer.neural_experiment_scene_height,
        );

        var neural: ?neural_rendering_host.Owner = null;
        if (trial_bundle_root) |path| {
            neural = try neural_rendering_host.Owner.init(
                self.io,
                std.heap.page_allocator,
                &self.gpu_renderer,
                path,
            );
            // The interactive comparison keeps the conventional scene in the
            // main window while inference feeds the Neural Input / Output
            // tool. The automated trial fixture explicitly exercises the
            // optional scene-presentation override as part of acceptance.
            if (trial_fixture_requested) {
                _ = neural.?.setPresentationEnabled(true);
            }
        }
        errdefer if (neural) |*owner| owner.deinit(&self.gpu_renderer);
        var neural_inputs = try neural_input_host.Owner.init(
            self.io,
            std.heap.page_allocator,
            &self.gpu_renderer,
        );
        errdefer neural_inputs.deinit();
        var capture: ?neural_capture_host.Owner = null;
        var capture_camera_program: ?neural_capture_camera.Program =
            if (self.neural_evaluation_fixture_enabled or self.neural_target_fixture_enabled)
                .orbit_wide
            else
                null;
        var capture_start: u64 = 0;
        var capture_stride: u64 = 1;
        var capture_count: u64 = 0;
        var capture_sequence: []const u8 = "";
        if (capture_root) |root| {
            const count_text = environ_map.get("INCINERATOR_NR_CAPTURE_FRAMES") orelse
                return error.NeuralCaptureFrameCountRequired;
            const start_text = environ_map.get("INCINERATOR_NR_CAPTURE_START_FRAME") orelse "0";
            const stride_text = environ_map.get("INCINERATOR_NR_CAPTURE_STRIDE") orelse "1";
            const cohort_text = environ_map.get("INCINERATOR_NR_COHORT") orelse
                return error.NeuralCaptureCohortRequired;
            const sequence = environ_map.get("INCINERATOR_NR_SEQUENCE") orelse
                return error.NeuralCaptureSequenceRequired;
            const camera_path = environ_map.get("INCINERATOR_NR_CAMERA_PATH") orelse
                return error.NeuralCaptureCameraPathRequired;
            capture_camera_program = try neural_capture_camera.parse(camera_path);
            capture_start = std.fmt.parseUnsigned(u64, start_text, 10) catch
                return error.InvalidNeuralCaptureStartFrame;
            capture_stride = std.fmt.parseUnsigned(u64, stride_text, 10) catch
                return error.InvalidNeuralCaptureStride;
            capture_count = std.fmt.parseUnsigned(u64, count_text, 10) catch
                return error.InvalidNeuralCaptureFrameCount;
            capture_sequence = sequence;
            capture = try neural_capture_host.Owner.init(self.io, std.heap.page_allocator, &self.gpu_renderer, .{
                .root = root,
                .start_frame = capture_start,
                .frame_stride = capture_stride,
                .frame_count = capture_count,
                .cohort = try neural_capture_host.parseCohort(cohort_text),
                .sequence = sequence,
                .camera_path = neural_capture_camera.name(capture_camera_program.?),
                .content_digest = if (self.neural_target_fixture_enabled)
                    neural_target_fixture.contentDigestFor(self.neural_target_fixture_variant)
                else if (self.neural_evaluation_fixture_enabled)
                    neural_evaluation_fixture.contentDigest()
                else
                    try self.district_streaming.contentDigest(),
            });
        }
        errdefer if (capture) |*owner| owner.deinit();
        var target_frames: ?neural_target_frame.Owner = null;
        if (target_frame_root) |root| {
            target_frames = try neural_target_frame.Owner.init(self.io, std.heap.page_allocator, .{
                .root = root,
                .capture_root = capture_root.?,
                .start_frame = capture_start,
                .frame_stride = capture_stride,
                .frame_count = capture_count,
                .sequence = capture_sequence,
                .camera_path = neural_capture_camera.name(capture_camera_program.?),
                .content_digest = neural_target_fixture.contentDigestFor(self.neural_target_fixture_variant),
                .scene = neural_target_fixture.sceneFor(self.neural_target_fixture_variant),
            });
        }
        self.neural_rendering = neural;
        self.neural_inputs = neural_inputs;
        self.neural_capture = capture;
        self.neural_target_frames = target_frames;
        self.neural_capture_camera_program = capture_camera_program;
        if (self.neural_rendering) |*owner| {
            const diagnostics = owner.diagnostics();
            std.debug.print(
                "RF10_RUNTIME model_loaded={} enabled={} bundle={s} fixture={} paired_capture={s}\n",
                .{
                    diagnostics.model_loaded,
                    diagnostics.enabled,
                    trial_bundle_root.?,
                    self.neural_trial_fixture_enabled,
                    capture_root orelse "none",
                },
            );
            std.debug.print("  N - Toggle neural scene presentation\n", .{});
            if (!diagnostics.model_loaded) {
                std.debug.print("RF10_FALLBACK reason={s}\n", .{diagnostics.last_error});
            }
        } else {
            std.debug.print(
                "NR0_INPUTS schema={s} capture={s}\n",
                .{ engine.neural_rendering.schema_name, capture_root orelse "none" },
            );
            if (target_frame_root) |root| std.debug.print(
                "NR4_TARGET_EXPORT schema={s} root={s}\n",
                .{ neural_target_contract.schema_name, root },
            );
        }
    }

    fn beginHostProfile(
        self: *App,
        phase: developer_profile.Phase,
        frame_index: ?u64,
        tick_index: ?u64,
    ) sandbox_developer_host.ProfileScope {
        return self.developer.beginHostProfile(phase, frame_index, tick_index);
    }

    fn mergeProfileCounts(self: *App, counts: developer_profile.Counts) void {
        self.developer.mergeProfileCounts(counts);
    }

    /// Run the interactive product loop. This surface has no scenario,
    /// cadence-injection, or acceptance-summary input, so validation code is
    /// unreachable from the normal client composition.
    pub fn runProduct(self: *App) !void {
        return self.runProductLoop(.interactive, null);
    }

    pub fn runIncidentCaptureSmoke(self: *App) !void {
        if (!build_options.incident_capture_enabled) return error.IncidentCaptureDisabled;
        return self.runProductLoop(.smoke, null);
    }

    pub fn runIncidentCaptureBenchmark(self: *App) !void {
        return self.runProductLoop(.benchmark, null);
    }

    pub fn runIncidentCaptureJourney(self: *App) !void {
        if (!build_options.incident_capture_enabled) return error.IncidentCaptureDisabled;
        return self.runProductLoop(.journey, null);
    }

    pub fn runIncidentCaptureWindowJourney(self: *App) !void {
        if (!build_options.incident_capture_enabled) return error.IncidentCaptureDisabled;
        return self.runProductLoop(.journey_window, null);
    }

    pub fn runIncidentCaptureHardening(
        self: *App,
        profile: incident_capture.HardeningProfile,
    ) !sandbox_developer_host.Owner.IncidentHardeningSnapshot {
        if (!build_options.incident_capture_enabled) return error.IncidentCaptureDisabled;
        try self.runProductLoop(.journey, null);
        const snapshot = self.developer.incidentHardeningSnapshot();
        try validateIncidentHardening(profile, snapshot);
        return snapshot;
    }

    pub fn runIncidentReplay(
        self: *App,
        run_path: []const u8,
    ) !void {
        var replay = try incident_input_replay.Replay.load(
            self.io,
            std.heap.page_allocator,
            run_path,
        );
        defer replay.deinit();
        std.debug.print(
            "INCIDENT_GRAPHICAL_REPLAY_BEGIN source={s} samples={d} final_tick={d}\n",
            .{ run_path, replay.samples.len, replay.finalTick() },
        );
        try self.runProductLoop(.interactive, &replay);
        std.debug.print(
            "INCIDENT_GRAPHICAL_REPLAY_COMPLETE source={s} final_tick={d}\n",
            .{ run_path, self.simulation.inspection().tickIndex() },
        );
    }

    fn runProductLoop(
        self: *App,
        incident_mode: IncidentRunMode,
        replay: ?*incident_input_replay.Replay,
    ) !void {
        var running = true;
        var retained_runtime_error: ?anyerror = null;
        var incident_flagged = false;
        var handoff_requested = false;
        var handoff_request_tick: u64 = 0;
        var incident_journey = IncidentJourneyProgress{
            .exercise_window_lifecycle = incident_mode == .journey_window,
        };
        var incident_benchmark = IncidentBenchmarkProgress{};

        game_loop: while (running) {
            var input_profile = self.beginHostProfile(
                .input,
                self.frame_timer.total_frames +| 1,
                self.simulation.inspection().tickIndex(),
            );
            defer input_profile.finish(.failure);
            self.input_buffer.beginFrame();
            running = self.pumpInputEvents();
            if (self.input_buffer.isKeyPressed(input.Key.N)) {
                if (self.neural_rendering) |*neural| {
                    const enabled = neural.toggle();
                    const diagnostics = neural.diagnostics();
                    std.debug.print(
                        "RF10_RUNTIME enabled={} model_loaded={} bundle={s} error={s}\n",
                        .{
                            enabled,
                            diagnostics.model_loaded,
                            diagnostics.bundle_root,
                            diagnostics.last_error,
                        },
                    );
                }
            }
            if (incident_mode.isJourney()) {
                try self.advanceIncidentJourneyWindowLifecycle(&incident_journey);
            }
            if (replay == null and !incident_mode.isJourney() and running and
                retained_runtime_error == null and
                !self.developer.paused())
            {
                try self.captureFrameActions();
            }
            input_profile.finish(.success);
            if (!running) break;
            if (self.waitForWindowSuspension()) continue;

            self.developer.beginFrameProfile(
                self.frame_timer.total_frames +| 1,
                self.simulation.inspection().tickIndex(),
            );
            defer self.developer.finishFrameProfile(.failure);
            if (retained_runtime_error != null) {
                self.frame_timer.beginControlledFrame(.paused);
                _ = try self.renderFaultInspectionFrame();
                self.developer.finishFrameProfile(.success);
                continue;
            }

            self.frame_timer.beginControlledFrame(
                self.developer.clockPolicy(),
            );
            var content_profile = self.beginHostProfile(
                .content_pump,
                self.frame_timer.total_frames,
                self.simulation.inspection().tickIndex(),
            );
            defer content_profile.finish(.failure);
            try self.district_streaming.pumpContent(self.districtAuthorityPort(), self.frame_timer.total_frames);
            content_profile.finish(.success);

            if (self.developer.takeSingleStep()) {
                if (replay) |input_replay| try self.action_latch.captureFrame(
                    input_replay.frameForTick(self.simulation.inspection().tickIndex() +| 1),
                );
                if (incident_mode.isJourney()) try self.action_latch.captureFrame(
                    self.incidentJourneyActions(&incident_journey),
                );
                self.simulateTick(false, .none) catch |err| {
                    if (!self.developer.hasRetainedFault(self.developerAuthorityPort())) return err;
                    retained_runtime_error = err;
                    self.applyDeveloperEffects(self.developer.enterFaultInspection(
                        self.developerAuthorityPort(),
                        self.developerStreamingPort(),
                        &self.frame_timer,
                        self.includeDeveloperDistrictStreams(),
                    ));
                    _ = try self.renderFaultInspectionFrame();
                    continue :game_loop;
                };
                if (incident_mode.isJourney()) {
                    try self.observeIncidentJourney(&incident_journey);
                }
                self.frame_timer.recordSingleStep();
            } else if (!self.developer.paused()) {
                while (self.frame_timer.shouldTick()) {
                    if (replay) |input_replay| try self.action_latch.captureFrame(
                        input_replay.frameForTick(self.simulation.inspection().tickIndex() +| 1),
                    );
                    if (incident_mode.isJourney()) try self.action_latch.captureFrame(
                        self.incidentJourneyActions(&incident_journey),
                    );
                    self.simulateTick(false, .none) catch |err| {
                        if (!self.developer.hasRetainedFault(self.developerAuthorityPort())) return err;
                        retained_runtime_error = err;
                        self.applyDeveloperEffects(self.developer.enterFaultInspection(
                            self.developerAuthorityPort(),
                            self.developerStreamingPort(),
                            &self.frame_timer,
                            self.includeDeveloperDistrictStreams(),
                        ));
                        _ = try self.renderFaultInspectionFrame();
                        continue :game_loop;
                    };
                    if (incident_mode.isJourney()) {
                        try self.observeIncidentJourney(&incident_journey);
                    }
                    self.frame_timer.recordCompletedTick();
                }
            }

            _ = try self.render(self.frame_timer.alpha());
            self.developer.finishFrameProfile(.success);
            if (incident_mode == .benchmark and
                self.frame_timer.total_frames > incident_benchmark_warmup_frames)
            {
                incident_benchmark.observe(self.frame_timer.getDeltaTime());
                if (incident_benchmark.complete()) {
                    incident_benchmark.report(
                        self.developer.incidentBenchmarkSnapshot(),
                    );
                    break;
                }
            }
            if (!incident_mode.isJourney()) self.developer.maybePrintFrameStats(
                &self.frame_timer,
                self.simulation.inspection().tickIndex(),
            );
            if (incident_mode == .smoke) {
                const tick = self.simulation.inspection().tickIndex();
                if (!incident_flagged and tick >= 120) {
                    if (!self.developer.queueIncidentHotkeyForAcceptance()) {
                        return error.IncidentSmokeFlagFailed;
                    }
                    incident_flagged = true;
                }
                if (incident_flagged and !handoff_requested and tick >= 480) {
                    if (!self.developer.requestIncidentHandoffWithReplayForAcceptance(
                        self.developerAuthorityPort(),
                    )) {
                        return error.IncidentSmokeHandoffFailed;
                    }
                    handoff_requested = true;
                    handoff_request_tick = tick;
                }
                if (handoff_requested and tick >= handoff_request_tick +| 60) break;
            }
            if (incident_mode.isJourney() and
                try self.advanceIncidentJourneyAfterFrame(&incident_journey)) break;
            if (replay) |input_replay| {
                if (self.simulation.inspection().tickIndex() >= input_replay.finalTick() +| 60) break;
            }
        }

        if (retained_runtime_error) |err| return err;
        if (incident_mode.isJourney() and !incident_journey.handoff_requested) {
            return error.IncidentJourneyInterrupted;
        }
    }

    fn incidentJourneyActions(
        self: *const App,
        progress: *const IncidentJourneyProgress,
    ) sandbox_controls.FrameSample {
        const tick = self.simulation.inspection().tickIndex() +| 1;
        var actions = sandbox_controls.FrameSample{};
        switch (progress.stage) {
            .bootstrap => if (tick >= 60 and tick < 90) {
                actions.look_delta = .{ 0.004, -0.001 };
            },
            .collect => {
                if (self.simulation.player().focusPosition()) |position| {
                    const carryables = self.simulation.presentation().carryables(0);
                    if (carryables.len != 0) {
                        const target = carryables[0].pose.position;
                        const delta = [2]f32{
                            target[0] - position[0],
                            target[2] - position[2],
                        };
                        const horizontal_distance_squared =
                            delta[0] * delta[0] + delta[1] * delta[1];
                        if (horizontal_distance_squared > 4) {
                            const inverse = 1.0 / @sqrt(horizontal_distance_squared);
                            const world_x = delta[0] * inverse;
                            const world_z = delta[1] * inverse;
                            const sine = @sin(self.game_camera.yaw);
                            const cosine = @cos(self.game_camera.yaw);
                            actions.move = .{
                                world_x * cosine + world_z * sine,
                                world_x * sine - world_z * cosine,
                            };
                        } else {
                            actions.carry_pressed =
                                (tick -| progress.stage_enter_tick) % 30 == 1;
                        }
                    }
                }
            },
            .drop => {
                actions.carry_pressed =
                    (tick -| progress.stage_enter_tick) % 30 == 1;
            },
            .enter_vehicle, .reenter_vehicle => {
                if (self.simulation.player().focusPosition()) |position| {
                    const vehicles = self.simulation.presentation().vehicles(0);
                    if (vehicles.len != 0) {
                        const target = vehicles[0].chassis_pose.position;
                        if (tick == progress.stage_enter_tick +| 1) {
                            std.debug.print(
                                "INCIDENT_JOURNEY_VEHICLE_APPROACH tick={d} " ++
                                    "character=[{d},{d},{d}] vehicle=[{d},{d},{d}] occupied={}\n",
                                .{
                                    tick,
                                    position[0],
                                    position[1],
                                    position[2],
                                    target[0],
                                    target[1],
                                    target[2],
                                    vehicles[0].driver != null,
                                },
                            );
                        }
                        const delta = [2]f32{
                            target[0] - position[0],
                            target[2] - position[2],
                        };
                        const horizontal_distance_squared =
                            delta[0] * delta[0] + delta[1] * delta[1];
                        const vertical = target[1] - position[1];
                        const distance_squared = horizontal_distance_squared + vertical * vertical;
                        // The character capsule cannot overlap the vehicle's
                        // chassis. Stop at a reachable point inside the
                        // configured three-metre entry range instead of
                        // walking forever toward the chassis origin.
                        if (distance_squared > 8) {
                            const inverse = 1.0 / @sqrt(horizontal_distance_squared);
                            const world_x = delta[0] * inverse;
                            const world_z = delta[1] * inverse;
                            const sine = @sin(self.game_camera.yaw);
                            const cosine = @cos(self.game_camera.yaw);
                            actions.move = .{
                                world_x * cosine + world_z * sine,
                                world_x * sine - world_z * cosine,
                            };
                        } else {
                            actions.interact_pressed =
                                (tick -| progress.stage_enter_tick) % 30 == 1;
                        }
                    }
                }
            },
            .exit_vehicle, .second_exit_vehicle => {
                // Retain braking while the exit request is admitted so the
                // unoccupied chassis cannot coast beyond the authored support
                // plane during the remainder of this long journey.
                actions.brake = true;
                actions.interact_pressed = (tick -| progress.stage_enter_tick) % 30 == 1;
            },
            .drive => {
                const elapsed = tick -| progress.stage_enter_tick;
                actions.move = .{
                    if (elapsed >= 45 and elapsed < 90) 0.55 else 0,
                    if (elapsed < 90) 0.75 else 0,
                };
                actions.hand_brake = elapsed >= 90 and elapsed < 105;
                actions.brake = elapsed >= 90;
            },
            .travel_east => {
                actions.move = .{ 1, 0 };
                actions.jump_pressed = tick == progress.stage_enter_tick +| 30;
            },
            .return_west => actions.move = .{ -1, 0 },
            .await_player_death => self.approachIncidentHostile(
                &actions,
                tick,
                progress.stage_enter_tick,
                false,
                true,
            ),
            .complete => {},
            .respawn => {
                actions.respawn_pressed = (tick -| progress.stage_enter_tick) % 30 == 1;
            },
            .fight_npc => {
                if (progress.saw_npc_dead) {
                    if (self.simulation.player().focusPosition()) |position| {
                        // The S15 catalog distributes replacement candidates
                        // across all four districts. Move to the open northwest
                        // edge so the player is outside the configured safety
                        // radius and visibility window instead of suppressing
                        // every valid replacement while waiting to observe one.
                        const safe = [2]f32{ -6.5, 22.5 };
                        const delta = [2]f32{
                            safe[0] - position[0],
                            safe[1] - position[2],
                        };
                        const distance_squared = delta[0] * delta[0] + delta[1] * delta[1];
                        if (distance_squared > 1) {
                            const inverse = 1.0 / @sqrt(distance_squared);
                            const world_x = delta[0] * inverse;
                            const world_z = delta[1] * inverse;
                            const sine = @sin(self.game_camera.yaw);
                            const cosine = @cos(self.game_camera.yaw);
                            actions.move = .{
                                world_x * cosine + world_z * sine,
                                world_x * sine - world_z * cosine,
                            };
                        }
                    }
                } else self.approachIncidentHostile(
                    &actions,
                    tick,
                    progress.stage_enter_tick,
                    true,
                    false,
                );
            },
        }
        return actions;
    }

    /// Drive the scripted player toward the explicitly authored hostile P01.
    /// Population activity can move P01 beyond its perception radius while the
    /// earlier carry/vehicle/district stages run. Waiting motionless therefore
    /// tested a coincidental meeting, not the promised combat journey.
    fn approachIncidentHostile(
        self: *const App,
        actions: *sandbox_controls.FrameSample,
        tick: u64,
        stage_enter_tick: u64,
        attack: bool,
        provoke_until_engaged: bool,
    ) void {
        const position = self.simulation.player().focusPosition() orelse return;
        for (self.simulation.presentation().npcs(0)) |npc| {
            if (npc.population_member != s11_hostile_population_member.value or
                npc.life_state != .alive)
            {
                continue;
            }
            const npc_position = npc.pose.position;
            const to_npc = [2]f32{
                npc_position[0] - position[0],
                npc_position[2] - position[2],
            };
            const desired_yaw = std.math.atan2(to_npc[0], -to_npc[1]);
            const yaw_delta = engine.transform.normalizeFacingYaw(
                desired_yaw - self.game_camera.yaw,
            ) catch 0;
            // Convert the exact desired turn into the ordinary mouse-look input
            // domain consumed by Camera.rotate.
            actions.look_delta[0] = yaw_delta / self.game_camera.look_sensitivity;
            const center_distance_squared = to_npc[0] * to_npc[0] + to_npc[1] * to_npc[1];
            const engaged = npc.encounter_state != .patrolling;
            if (attack or (provoke_until_engaged and !engaged and
                center_distance_squared <= 2.25 * 2.25))
            {
                actions.melee_pressed = (tick -| stage_enter_tick) % 30 == 1;
            }

            // Before provoking the hostile, move to the front of its authored
            // sight cone. Direct center-seeking can leave the player parked
            // immediately behind a dwelling NPC forever: that is a blind-spot
            // test, not the promised combat/death journey.
            const npc_facing_yaw = engine.transform.facingYawFromRotation(
                npc.pose.rotation,
            ) catch 0;
            const approach = if (provoke_until_engaged and !engaged)
                [2]f32{
                    npc_position[0] + @sin(npc_facing_yaw) * 1.5,
                    npc_position[2] - @cos(npc_facing_yaw) * 1.5,
                }
            else
                [2]f32{ npc_position[0], npc_position[2] };
            const travel = [2]f32{
                approach[0] - position[0],
                approach[1] - position[2],
            };
            const travel_distance_squared = travel[0] * travel[0] + travel[1] * travel[1];
            const stop_distance_squared: f32 = if (engaged or attack) 2.25 else 0.16;
            if (travel_distance_squared > stop_distance_squared) {
                const inverse = 1.0 / @sqrt(travel_distance_squared);
                const world_x = travel[0] * inverse;
                const world_z = travel[1] * inverse;
                const sine = @sin(self.game_camera.yaw);
                const cosine = @cos(self.game_camera.yaw);
                actions.move = .{
                    world_x * cosine + world_z * sine,
                    world_x * sine - world_z * cosine,
                };
            }
            return;
        }
    }

    fn observeIncidentJourney(
        self: *App,
        progress: *IncidentJourneyProgress,
    ) !void {
        const tick = self.simulation.inspection().tickIndex();
        const hud = self.simulation.presentation().combatHud();
        if (hud.life_state == .dead and progress.stage != .respawn and
            progress.stage != .complete)
        {
            progress.saw_player_dead = true;
            progress.resume_after_respawn = if (progress.stage == .await_player_death)
                .fight_npc
            else
                progress.stage;
            progress.enter(.respawn, tick);
        }

        const npc_draws = self.simulation.presentation().npcs(0);
        if (progress.initial_npc == null) for (npc_draws) |npc| {
            if (npc.life_state != .alive or
                npc.population_member != s11_hostile_population_member.value)
            {
                continue;
            }
            progress.initial_npc = .{
                .entity = npc.entity,
                .incarnation = npc.incarnation,
                .population_member = npc.population_member,
            };
            break;
        };
        if (progress.initial_npc) |initial| for (npc_draws) |npc| {
            const same_incarnation = std.meta.eql(npc.entity, initial.entity) and
                npc.incarnation == initial.incarnation;
            if (same_incarnation and npc.life_state == .dead) {
                if (!progress.saw_npc_dead) progress.npc_dead_tick = tick;
                progress.saw_npc_dead = true;
            }
            if (progress.saw_npc_dead and
                npc.population_member == initial.population_member and
                !same_incarnation and npc.life_state == .alive)
            {
                progress.saw_npc_replacement = true;
            }
        };

        switch (progress.stage) {
            .bootstrap => if (tick >= 120 and self.initial_carryable_id != null and
                progress.initial_npc != null)
            {
                progress.enter(.collect, tick);
            },
            .collect => if (self.interaction_last_player_result) |result| {
                if (result.disposition == .collected) progress.enter(.drop, tick);
            },
            .drop => if (self.interaction_last_player_result) |result| {
                if (result.disposition == .dropped) progress.enter(.enter_vehicle, tick);
            },
            .enter_vehicle => if (self.controlled_vehicle_id != null) {
                progress.entered_vehicle = true;
                progress.enter(.drive, tick);
            },
            .drive => if (tick >= progress.stage_enter_tick +| 240) {
                progress.enter(.exit_vehicle, tick);
            },
            .exit_vehicle => if (progress.entered_vehicle and self.controlled_vehicle_id == null) {
                progress.enter(.reenter_vehicle, tick);
            },
            .reenter_vehicle => if (self.controlled_vehicle_id != null) {
                progress.reentered_vehicle = true;
                progress.enter(.second_exit_vehicle, tick);
            },
            .second_exit_vehicle => if (progress.reentered_vehicle and
                self.controlled_vehicle_id == null)
            {
                progress.enter(.travel_east, tick);
            },
            .travel_east => if (self.simulation.player().focusPosition()) |position| {
                if (position[0] >= 10 and
                    self.simulation.districts().activeTicket(district_east_coord) != null)
                {
                    progress.saw_east = true;
                    progress.enter(.return_west, tick);
                }
            },
            .return_west => if (self.simulation.player().focusPosition()) |position| {
                if (position[0] <= 4 and
                    self.simulation.districts().activeTicket(district_west_coord) != null)
                {
                    progress.saw_returned_west = true;
                    progress.enter(
                        if (progress.saw_player_dead and progress.saw_player_respawned)
                            .fight_npc
                        else
                            .await_player_death,
                        tick,
                    );
                }
            },
            .await_player_death => {},
            .respawn => if (progress.saw_player_dead and hud.life_state == .alive) {
                progress.saw_player_respawned = true;
                const next = progress.resume_after_respawn orelse .fight_npc;
                progress.resume_after_respawn = null;
                progress.enter(next, tick);
            },
            .fight_npc => if (progress.saw_npc_dead and progress.saw_npc_replacement) {
                progress.enter(.complete, tick);
            },
            .complete => {},
        }
    }

    fn advanceIncidentJourneyAfterFrame(
        self: *App,
        progress: *IncidentJourneyProgress,
    ) !bool {
        const tick = self.simulation.inspection().tickIndex();
        // Killing the authored hostile and observing its population replacement
        // are two distinct lifecycle proofs. Once death is observed, measure
        // the remaining fight stage from that transition instead of consuming
        // the replacement window while the scripted player closes and fights.
        const stage_timeout_origin = if (progress.stage == .fight_npc and
            progress.saw_npc_dead)
            progress.npc_dead_tick
        else
            progress.stage_enter_tick;
        if (tick > stage_timeout_origin +| 1_200 or tick > 3_600) {
            const population_diagnostics =
                self.simulation.developer().diagnostics().population orelse
                return error.PopulationDiagnosticsMissing;
            std.debug.print(
                "INCIDENT_JOURNEY_TIMEOUT stage={s} tick={d} stage_enter={d} " ++
                    "population=live:{d},awaiting:{d},vacant:{d},replacement:{d}," ++
                    "traveling:{d},dwelling:{d},waiting:{d},interrupted:{d}," ++
                    "spawn_retries:{d}\n",
                .{
                    @tagName(progress.stage),
                    tick,
                    progress.stage_enter_tick,
                    population_diagnostics.live,
                    population_diagnostics.awaiting_spawn,
                    population_diagnostics.vacant,
                    population_diagnostics.replacement_pending,
                    population_diagnostics.traveling,
                    population_diagnostics.dwelling,
                    population_diagnostics.waiting_for_slot,
                    population_diagnostics.interrupted,
                    population_diagnostics.spawn_retries.total(),
                },
            );
            return error.IncidentJourneyIncomplete;
        }

        if (progress.flag_count == 0 and tick >= 120) {
            if (!self.developer.queueIncidentHotkeyForAcceptance()) {
                return error.IncidentJourneyFlagFailed;
            }
            progress.flag_count = 1;
            progress.last_flag_tick = tick;
        }
        if (progress.exercise_window_lifecycle and
            !progress.minimize_requested and tick >= 600)
        {
            if (!c.SDL_MinimizeWindow(self.window)) {
                return error.IncidentJourneyMinimizeFailed;
            }
            if (!c.SDL_SyncWindow(self.window)) {
                return error.IncidentJourneyMinimizeSyncFailed;
            }
            progress.minimize_requested = true;
            progress.minimized_started_ns = c.SDL_GetTicksNS();
        }
        if (progress.saw_east and !progress.resized) {
            if (!c.SDL_SetWindowSize(self.window, 1024, 640)) {
                return error.IncidentJourneyResizeFailed;
            }
            progress.resized = true;
            progress.resize_requested_tick = tick;
        }
        if (progress.saw_returned_west and progress.resized and !progress.restored_size) {
            if (!c.SDL_SetWindowSize(self.window, INITIAL_WINDOW_WIDTH, INITIAL_WINDOW_HEIGHT)) {
                return error.IncidentJourneyResizeFailed;
            }
            progress.restored_size = true;
            progress.restore_size_tick = tick;
        }
        // Allow the restored drawable generation to accumulate the full
        // five-second screenshot pre-roll before applying overlapping flags.
        // The extra one-second capture interval leaves six completed history
        // samples even when the next sample is in flight.
        // Flagging on the same frame as a resize honestly produces partial
        // evidence, but that belongs in an explicit pressure case rather than
        // making the zero-loss reference journey timing-dependent.
        if (progress.restored_size and !progress.rapid_flags_completed and
            tick >= progress.restore_size_tick +| 360)
        {
            if (!self.developer.queueIncidentHotkeyForAcceptance() or
                !self.developer.queueIncidentHotkeyForAcceptance())
            {
                return error.IncidentJourneyFlagFailed;
            }
            progress.flag_count += 2;
            progress.last_flag_tick = tick;
            progress.rapid_flags_completed = true;
        }
        if (progress.stage == .complete and progress.rapid_flags_completed and
            !progress.completion_flagged)
        {
            if (!self.developer.queueIncidentHotkeyForAcceptance()) {
                return error.IncidentJourneyFlagFailed;
            }
            progress.flag_count += 1;
            progress.last_flag_tick = tick;
            progress.completion_flagged = true;
        }
        if (progress.completion_flagged and !progress.handoff_requested and
            tick >= progress.last_flag_tick +| 300)
        {
            if (!self.developer.requestIncidentHandoffWithReplayForAcceptance(
                self.developerAuthorityPort(),
            )) return error.IncidentJourneyHandoffFailed;
            progress.handoff_requested = true;
            progress.handoff_request_tick = tick;
        }
        if (progress.handoff_requested and tick >= progress.handoff_request_tick +| 60) {
            if (!progress.entered_vehicle or !progress.reentered_vehicle or !progress.saw_east or
                !progress.saw_returned_west or !progress.saw_player_dead or
                !progress.saw_player_respawned or !progress.saw_npc_dead or
                !progress.saw_npc_replacement or !progress.resized or
                !progress.restored_size or
                (progress.exercise_window_lifecycle and
                    (!progress.minimized_event or !progress.restored_event)) or
                progress.flag_count != 4)
            {
                return error.IncidentJourneyIncomplete;
            }
            std.debug.print(
                "INCIDENT_JOURNEY_COMPLETE tick={d} flags={d} " ++
                    "vehicle={}/{} districts={}/{} player={}/{} npc={}/{} " ++
                    "resize={}/{} window_required={} window_observed={}/{}\n",
                .{
                    tick,
                    progress.flag_count,
                    progress.entered_vehicle,
                    progress.reentered_vehicle,
                    progress.saw_east,
                    progress.saw_returned_west,
                    progress.saw_player_dead,
                    progress.saw_player_respawned,
                    progress.saw_npc_dead,
                    progress.saw_npc_replacement,
                    progress.resized,
                    progress.restored_size,
                    progress.exercise_window_lifecycle,
                    progress.minimized_event,
                    progress.restored_event,
                },
            );
            return true;
        }
        return false;
    }

    fn advanceIncidentJourneyWindowLifecycle(
        self: *App,
        progress: *IncidentJourneyProgress,
    ) !void {
        if (self.input_buffer.window_minimized_this_frame) {
            if (!progress.minimize_requested) return error.IncidentJourneyUnexpectedMinimize;
            progress.minimized_event = true;
            progress.minimized_started_ns = c.SDL_GetTicksNS();
        }
        if (self.input_buffer.window_restored_this_frame) {
            if (!progress.restore_requested) return error.IncidentJourneyUnexpectedRestore;
            progress.restored_event = true;
            self.frame_timer.resyncClock();
        }
        if (progress.minimized_event and !progress.restore_requested and
            c.SDL_GetTicksNS() -| progress.minimized_started_ns >=
                750 * std.time.ns_per_ms)
        {
            if (!c.SDL_RestoreWindow(self.window)) {
                return error.IncidentJourneyRestoreFailed;
            }
            if (!c.SDL_SyncWindow(self.window)) {
                return error.IncidentJourneyRestoreSyncFailed;
            }
            progress.restore_requested = true;
        }
    }

    /// Run one validation scenario through the production adapters.
    fn runValidation(
        self: *App,
        smoke: ?VisualSmokeConfig,
        scenario: ScriptedScenario,
    ) !RunSummary {
        self.validation_tick_origin = self.simulation.inspection().tickIndex();
        if (scenario == .s11_combat) {
            self.validation.s11_combat = .{ .active = true };
        } else if (scenario == .s13_population) {
            self.validation.s13_population = .{ .active = true };
        } else if (scenario == .s14_ranged_combat) {
            self.validation.s14_ranged_combat = .{ .active = true };
        }
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
                self.simulation.inspection().tickIndex(),
            );
            defer input_profile.finish(.failure);
            // ================================================================
            // PHASE 1: INPUT PUMP (Per-Frame)
            // ================================================================
            // Clear per-frame input state and poll all SDL events.
            // This runs every frame to ensure responsive input.
            self.input_buffer.beginFrame();
            running = self.pumpInputEvents();
            if (running and
                self.validation.profile == .sandbox and
                scenario == .none and
                retained_runtime_error == null and
                !self.developer.paused())
            {
                try self.captureFrameActions();
            }
            input_profile.finish(.success);
            if (!running) break;
            if (self.waitForWindowSuspension()) continue;

            self.developer.beginFrameProfile(
                self.frame_timer.total_frames +| 1,
                self.simulation.inspection().tickIndex(),
            );
            defer self.developer.finishFrameProfile(.failure);
            if (retained_runtime_error != null) {
                if (self.validation.s4_fault_loop_probe) |probe| {
                    const stream_now = self.district_streaming.developerStreams();
                    const gpu_now = (try self.district_streaming.gpuDiagnostics()).current;
                    if (probe.content_pump_calls != probe.content_pump_calls_at_fault or
                        probe.gpu_pump_calls != probe.gpu_pump_calls_at_fault or
                        self.simulation.inspection().tickIndex() != probe.tick_at_fault or
                        self.frame_timer.total_ticks != probe.completed_ticks_at_fault or
                        !std.meta.eql(probe.stream_at_fault.?, stream_now) or
                        !std.meta.eql(probe.gpu_at_fault.?, gpu_now))
                    {
                        return error.S4DiagnosticsFaultGateProgressed;
                    }
                }
                self.frame_timer.beginControlledFrame(.paused);
                const inspection_ready = try self.renderFaultInspectionFrame();
                self.developer.finishFrameProfile(.success);
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
                    self.developer.clockPolicy(),
                );
            } else if (smoke) |config| {
                try self.frame_timer.beginControlledFrameWithElapsedSeconds(
                    1.0 / @as(f64, @floatFromInt(config.virtual_render_hz)),
                    self.developer.clockPolicy(),
                );
            } else {
                self.frame_timer.beginControlledFrame(
                    self.developer.clockPolicy(),
                );
            }
            if (self.validation.s4_fault_loop_probe) |probe| probe.content_pump_calls += 1;
            var content_profile = self.beginHostProfile(
                .content_pump,
                self.frame_timer.total_frames,
                self.simulation.inspection().tickIndex(),
            );
            defer content_profile.finish(.failure);
            try self.district_streaming.pumpContent(self.districtAuthorityPort(), self.frame_timer.total_frames);
            content_profile.finish(.success);

            // ================================================================
            // PHASE 2: AUTHORITY TICK (Fixed 60 Hz)
            // ================================================================
            // Run simulation at fixed timestep. Multiple ticks may run per frame
            // if we're behind, or zero ticks if we're ahead.
            const ticks_before = self.simulation.inspection().tickIndex();
            if (self.developer.takeSingleStep()) {
                self.simulateTick(true, scenario) catch |err| {
                    if (!self.developer.hasRetainedFault(self.developerAuthorityPort())) return err;
                    if (smoke != null) return err;
                    retained_runtime_error = err;
                    try self.captureS4FaultLoopProbe(err);
                    self.applyDeveloperEffects(self.developer.enterFaultInspection(
                        self.developerAuthorityPort(),
                        self.developerStreamingPort(),
                        &self.frame_timer,
                        self.includeDeveloperDistrictStreams(),
                    ));
                    _ = try self.renderFaultInspectionFrame();
                    summary.attempted_frames += 1;
                    continue :game_loop;
                };
                self.frame_timer.recordSingleStep();
            } else if (!self.developer.paused()) {
                while (self.frame_timer.shouldTick()) {
                    self.simulateTick(true, scenario) catch |err| {
                        if (!self.developer.hasRetainedFault(self.developerAuthorityPort())) return err;
                        if (smoke != null) return err;
                        retained_runtime_error = err;
                        try self.captureS4FaultLoopProbe(err);
                        self.applyDeveloperEffects(self.developer.enterFaultInspection(
                            self.developerAuthorityPort(),
                            self.developerStreamingPort(),
                            &self.frame_timer,
                            self.includeDeveloperDistrictStreams(),
                        ));
                        _ = try self.renderFaultInspectionFrame();
                        summary.attempted_frames += 1;
                        continue :game_loop;
                    };
                    self.frame_timer.recordCompletedTick();
                }
            }
            const ticks_this_frame = self.simulation.inspection().tickIndex() - ticks_before;
            if (ticks_this_frame == 0) summary.zero_tick_frames +|= 1;
            if (ticks_this_frame > 1) summary.multi_tick_frames +|= 1;

            // ================================================================
            // PHASE 3: PRESENTATION (Interpolated)
            // ================================================================
            // Render the current state. The alpha value can be used to
            // interpolate between previous and current state for smoothness.
            const alpha = self.frame_timer.alpha();
            const render_result = try self.render(alpha);
            self.developer.finishFrameProfile(.success);
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
                        .none, .s3_streaming, .s8_population, .s7_interaction, .s11_combat, .s13_population, .s14_ranged_combat => {},
                        .s1_character => if (self.initial_character_id != null) {
                            if (presentation.character_count > 1) {
                                return error.S1VisualSmokeCharacterPresentationMissing;
                            }
                            if (presentation.character_count == 1) {
                                const presented_id = presentation.character_id orelse
                                    return error.S1VisualSmokeCharacterPresentationMissing;
                                const spawned_id = self.initial_character_id orelse
                                    return error.S1VisualSmokeCharacterSpawnMissing;
                                const expected_id = self.simulation.inspection().replicatedId(
                                    spawned_id,
                                ) orelse return error.S1VisualSmokeCharacterSpawnMissing;
                                if (!std.meta.eql(presented_id, expected_id)) {
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
                            }
                        },
                        .s2_vehicle => {
                            if (self.initial_vehicle_id) |spawned_id| {
                                if (presentation.vehicle_count > 1) {
                                    return error.S2VisualSmokeVehiclePresentationMissing;
                                }
                                if (presentation.vehicle_count == 1) {
                                    const presented_id = presentation.vehicle_id orelse
                                        return error.S2VisualSmokeVehiclePresentationMissing;
                                    const expected_id = self.simulation.inspection().replicatedId(
                                        spawned_id,
                                    ) orelse return error.S2VisualSmokeVehicleSpawnMissing;
                                    if (!std.meta.eql(presented_id, expected_id)) {
                                        return error.S2VisualSmokePresentedWrongVehicle;
                                    }
                                    summary.vehicle_presented_frames += 1;
                                }
                            }
                            if (self.initial_character_id) |spawned_id| {
                                if (self.validation.s2_smoke.entered and !self.validation.s2_smoke.exited) {
                                    if (presentation.character_count == 0) {
                                        summary.character_hidden_while_driving = true;
                                    } else if (presentation.character_count > 1) {
                                        return error.S2VisualSmokeDrivingCharacterVisible;
                                    }
                                } else {
                                    if (presentation.character_count > 1) {
                                        return error.S2VisualSmokeCharacterPresentationMissing;
                                    }
                                    if (presentation.character_count == 1) {
                                        const presented_id = presentation.character_id orelse
                                            return error.S2VisualSmokeCharacterPresentationMissing;
                                        const expected_id = self.simulation.inspection().replicatedId(
                                            spawned_id,
                                        ) orelse return error.S2VisualSmokeCharacterSpawnMissing;
                                        if (!std.meta.eql(presented_id, expected_id)) {
                                            return error.S2VisualSmokePresentedWrongCharacter;
                                        }
                                        summary.character_presented_frames += 1;
                                        if (self.validation.s2_smoke.exited) {
                                            summary.character_visible_after_exit = true;
                                        }
                                    }
                                }
                            }
                        },
                        .s4_physics_debug => {
                            if (self.initial_character_id) |spawned_id| {
                                if (presentation.character_count > 1) {
                                    return error.S4PhysicsDebugCharacterPresentationMissing;
                                }
                                if (presentation.character_count == 1) {
                                    const expected_id = self.simulation.inspection().replicatedId(
                                        spawned_id,
                                    ) orelse return error.S4PhysicsDebugCharacterPresentationMissing;
                                    if (!std.meta.eql(
                                        presentation.character_id orelse
                                            return error.S4PhysicsDebugCharacterPresentationMissing,
                                        expected_id,
                                    )) {
                                        return error.S4PhysicsDebugCharacterPresentationMissing;
                                    }
                                    summary.character_presented_frames += 1;
                                }
                            }
                            if (self.initial_vehicle_id) |spawned_id| {
                                if (presentation.vehicle_count > 1) {
                                    return error.S4PhysicsDebugVehiclePresentationMissing;
                                }
                                if (presentation.vehicle_count == 1) {
                                    const expected_id = self.simulation.inspection().replicatedId(
                                        spawned_id,
                                    ) orelse return error.S4PhysicsDebugVehiclePresentationMissing;
                                    if (!std.meta.eql(
                                        presentation.vehicle_id orelse
                                            return error.S4PhysicsDebugVehiclePresentationMissing,
                                        expected_id,
                                    )) {
                                        return error.S4PhysicsDebugVehiclePresentationMissing;
                                    }
                                    summary.vehicle_presented_frames += 1;
                                }
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
            self.developer.maybePrintFrameStats(
                &self.frame_timer,
                self.simulation.inspection().tickIndex(),
            );
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
                .none => if (self.simulation.crates().count() != 1 or
                    self.simulation.characters().count() != 0 or
                    self.simulation.vehicles().count() != 0 or
                    self.simulation.inspection().entityCount() != 1 or
                    self.simulation.inspection().bodyCount() != 2)
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
                    if (self.simulation.crates().count() != 1 or
                        self.simulation.characters().count() != 1 or
                        self.simulation.vehicles().count() != 0 or
                        self.simulation.inspection().entityCount() != 2 or
                        self.simulation.inspection().bodyCount() != 3)
                    {
                        return error.S1VisualSmokeLifecycleInvariant;
                    }
                    const character = try self.simulation.characters().view(self.initial_character_id.?);
                    if (character.position[2] < -4.2 or character.position[2] > -3.5) {
                        return error.S1VisualSmokeBlockCollisionFailed;
                    }
                },
                .s2_vehicle => {
                    if (self.simulation.inspection().tickIndex() <
                        self.validation_tick_origin +| s2_required_ticks)
                    {
                        return error.S2VisualSmokeInsufficientTicks;
                    }
                    if (self.initial_character_id == null or self.initial_vehicle_id == null) {
                        return error.S2VisualSmokeSpawnMissing;
                    }
                    if (summary.vehicle_presented_frames == 0)
                        return error.S2VisualSmokeVehicleNeverPresented;
                    if (!summary.character_hidden_while_driving)
                        return error.S2VisualSmokeCharacterNeverHidden;
                    if (!summary.character_visible_after_exit)
                        return error.S2VisualSmokeCharacterNeverRestored;
                    if (!self.validation.s2_smoke.entered)
                        return error.S2VisualSmokeEnterMissing;
                    if (!self.validation.s2_smoke.drive_applied)
                        return error.S2VisualSmokeDriveAckMissing;
                    if (!self.validation.s2_smoke.steering_applied)
                        return error.S2VisualSmokeSteeringAckMissing;
                    if (!self.validation.s2_smoke.brake_applied)
                        return error.S2VisualSmokeBrakeAckMissing;
                    if (!self.validation.s2_smoke.hand_brake_applied)
                        return error.S2VisualSmokeHandBrakeAckMissing;
                    if (!self.validation.s2_smoke.steering_observed)
                        return error.S2VisualSmokeSteeringMissing;
                    if (!self.validation.s2_smoke.wheel_spin_presented)
                        return error.S2VisualSmokeWheelSpinMissing;
                    if (!self.validation.s2_smoke.wheel_steering_presented)
                        return error.S2VisualSmokeWheelSteeringMissing;
                    if (!self.validation.s2_smoke.vehicle_moved)
                        return error.S2VisualSmokeVehicleDidNotMove;
                    if (!self.validation.s2_smoke.crate_displaced)
                        return error.S2VisualSmokeCrateNotDisplaced;
                    if (!self.validation.s2_smoke.exited)
                        return error.S2VisualSmokeExitMissing;
                    if (self.controlled_vehicle_id != null or
                        self.simulation.crates().count() != 1 or
                        self.simulation.characters().count() != 1 or
                        self.simulation.vehicles().count() != 1 or
                        self.simulation.inspection().entityCount() != 3 or
                        self.simulation.inspection().bodyCount() != 3)
                    {
                        return error.S2VisualSmokeLifecycleInvariant;
                    }
                    const vehicle = try self.simulation.vehicles().view(self.initial_vehicle_id.?);
                    if (vehicle.driver_id != null) {
                        return error.S2VisualSmokeDriverStillActive;
                    }
                },
                .s3_streaming, .s8_population, .s7_interaction => {},
                .s11_combat => try self.validation.s11_combat.requireComplete(),
                .s13_population => try self.validation.s13_population.requireComplete(
                    self.simulation.inspection().populationDiagnostics(),
                    summary,
                    config,
                ),
                .s14_ranged_combat => try self.validation.s14_ranged_combat.requireComplete(),
                .s4_physics_debug => try self.validateS4PhysicsDebugSmoke(summary),
            }
            const expected = try smokeExpectation(config);
            if (self.simulation.inspection().tickIndex() !=
                self.validation_tick_origin +| expected.ticks)
            {
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
        if (self.simulation.crates().count() != 1 or
            self.simulation.characters().count() != 1 or
            self.simulation.vehicles().count() != 1 or
            self.simulation.districts().count() != 1 or
            self.simulation.inspection().entityCount() != 4 or
            self.simulation.inspection().bodyCount() <= 3)
        {
            return error.S4PhysicsDebugLifecycleInvariant;
        }
        if ((try self.district_streaming.slot(district_west_slot_index)).phase != .active) {
            return error.S4PhysicsDebugDistrictNotActive;
        }
        if (!self.validation.s4_physics_debug_evidence.allCategoriesObserved() or
            self.validation.s4_physics_debug_evidence.batches == 0 or
            self.validation.s4_physics_debug_evidence.peak_lines == 0)
        {
            return error.S4PhysicsDebugCategoryEvidenceMissing;
        }

        const gpu = self.developer.physicsDebugStats() orelse
            return error.S4PhysicsDebugGpuUnavailable;
        if (gpu.mode != .enabled or
            gpu.resources.slot_count != sandbox_developer_host.physics_debug_default_slot_count or
            gpu.resources.gpu_buffer_count != sandbox_developer_host.physics_debug_default_slot_count * 2 or
            gpu.resources.transfer_buffer_count != sandbox_developer_host.physics_debug_default_slot_count * 2 or
            gpu.resources.max_owned_fences != sandbox_developer_host.physics_debug_default_slot_count or
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
            gpu.latest_completed_tick > self.simulation.inspection().tickIndex() or
            gpu.failed_uploads != 0 or
            gpu.frame_fence_failures != 0 or
            gpu.slot_retirements != 0)
        {
            return error.S4PhysicsDebugGpuEvidenceMissing;
        }

        var phase_observed = [_]bool{false} ** std.meta.tags(developer_profile.Phase).len;
        const spans = self.developer.profileSpans();
        for (spans.first) |span| phase_observed[@intFromEnum(span.phase)] = true;
        for (spans.second) |span| phase_observed[@intFromEnum(span.phase)] = true;
        for (phase_observed) |observed| {
            if (!observed) return error.S4PhysicsDebugProfilePhaseMissing;
        }

        var frame_counts_observed = false;
        const frames = self.developer.profileFrames();
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
        probe.tick_at_fault = self.simulation.inspection().tickIndex();
        probe.completed_ticks_at_fault = self.frame_timer.total_ticks;
        probe.stream_at_fault = self.district_streaming.developerStreams();
        probe.gpu_at_fault = (try self.district_streaming.gpuDiagnostics()).current;
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
            running = self.pumpInputEvents();
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
    fn pumpInputEvents(self: *App) bool {
        self.developer.setGameplayMouseCaptured(
            self.input_buffer.gameplayMouseLocked(),
        );
        const running = self.input_buffer.pumpEvents(self.developer.eventSink());
        self.developer.setGameplayMouseCaptured(
            self.input_buffer.gameplayMouseLocked(),
        );
        return running;
    }

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
            if (!self.pumpInputEvents()) {
                return error.S3StreamingSmokeInterrupted;
            }
            if (self.waitForWindowSuspension()) continue;
            try self.frame_timer.beginFrameWithElapsedSeconds(
                1.0 / @as(f64, @floatFromInt(config.virtual_render_hz)),
            );
            try self.district_streaming.pumpContent(self.districtAuthorityPort(), self.frame_timer.total_frames);

            var stats = try self.district_streaming.gpuUsage();
            updateS3SmokePeaks(&summary, stats);
            const west = try self.district_streaming.slot(district_west_slot_index);
            switch (stage) {
                .cancel_first_load => switch (west.phase) {
                    .request_submitted => {
                        last_scene = west.scene;
                        self.district_focus_override = s3_smoke_far;
                        stage_started_frame = summary.attempted_frames;
                        stage = .wait_cancel_drain;
                    },
                    else => self.district_focus_override = s3_smoke_near,
                },
                .wait_cancel_drain => {
                    self.district_focus_override = s3_smoke_far;
                    if (west.phase == .idle and
                        std.meta.eql(stats, developer_diagnostics.GpuUsage{}))
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
                    switch (west.phase) {
                        .active => if (try self.district_streaming.sceneResidency(
                            west.scene.?,
                        ) == .resident) {
                            try self.validateS3Resident(west);
                            try self.validateS3ResidentDeveloperSnapshot();
                            summary.diagnostic_resident_snapshot = true;
                            last_scene = west.scene;
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
                    if (west.phase == .idle and
                        std.meta.eql(stats, developer_diagnostics.GpuUsage{}))
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

            const ticks_before = self.simulation.inspection().tickIndex();
            while (self.frame_timer.shouldTick()) {
                try self.simulateTick(true, .s3_streaming);
                self.frame_timer.recordCompletedTick();
                // Below-rate presentation may run two fixed ticks in one
                // frame. Arm the intended first-load cancellation at the
                // completed-tick boundary before a second tick can activate
                // the logical worker completion.
                if (stage == .cancel_first_load) switch ((try self.district_streaming.slot(
                    district_west_slot_index,
                )).phase) {
                    .loading => {
                        last_scene = (try self.district_streaming.slot(
                            district_west_slot_index,
                        )).scene;
                        self.district_focus_override = s3_smoke_far;
                        try self.district_streaming.forceDeparture(
                            self.districtAuthorityPort(),
                            self.frame_timer.total_frames,
                            district_west_slot_index,
                        );
                        stage_started_frame = summary.attempted_frames;
                        stage = .wait_cancel_drain;
                    },
                    else => {},
                };
            }
            const ticks_this_frame = self.simulation.inspection().tickIndex() - ticks_before;
            if (ticks_this_frame == 0) summary.zero_tick_frames += 1;
            if (ticks_this_frame > 1) summary.multi_tick_frames += 1;

            stats = try self.district_streaming.gpuUsage();
            updateS3SmokePeaks(&summary, stats);
            switch (try self.render(self.frame_timer.alpha())) {
                .ready => {},
                .unavailable => return error.S3StreamingSmokeUnavailableFrame,
            }
            summary.attempted_frames += 1;
            stats = try self.district_streaming.gpuUsage();
            updateS3SmokePeaks(&summary, stats);
            const west_after_render = try self.district_streaming.slot(district_west_slot_index);
            switch (west_after_render.phase) {
                .active => switch (try self.district_streaming.sceneResidency(west_after_render.scene.?)) {
                    .resident => summary.resident_frames += 1,
                    .reserved, .staged, .submitted => summary.fallback_frames += 1,
                    .free, .retiring => return error.S3StreamingSmokeResidencyMismatch,
                },
                else => {},
            }
            c.SDL_DelayPrecise(@as(u64, std.time.ns_per_s) / config.virtual_render_hz);
        }

        summary.ticks = self.simulation.inspection().tickIndex();
        if (summary.cancelled_loads != 1 or
            summary.resident_cycles != s3_smoke_resident_cycles or
            summary.unload_cycles != s3_smoke_resident_cycles or
            summary.cancel_to_drained_frames == 0 or
            summary.peak_load_to_resident_frames == 0 or
            summary.peak_unload_to_drained_frames == 0 or
            summary.resident_frames == 0 or
            summary.peak_live_scenes != 1 or
            summary.peak_active_batches != 1 or
            summary.peak_staged_cpu_bytes != installed_district_staged_cpu_bytes or
            summary.peak_staged_upload_bytes != installed_district_gpu_bytes or
            summary.peak_in_flight_upload_bytes != installed_district_gpu_bytes or
            summary.peak_resident_gpu_bytes != installed_district_gpu_bytes or
            (config.virtual_render_hz > timing.TICK_RATE and summary.zero_tick_frames == 0) or
            (config.virtual_render_hz < timing.TICK_RATE and summary.multi_tick_frames == 0))
        {
            return error.S3StreamingSmokeEvidenceMissing;
        }
        try self.validateS3Drained();
        try self.validateS3DrainedDeveloperSnapshot();
        summary.diagnostic_drained_snapshot = true;
        if (!self.district_streaming.workerIdle()) {
            return error.S3StreamingSmokeWorkerNotIdle;
        }
        const diagnostic_evidence = try validateDistrictStreamDiagnostics(
            self.simulation.developer().journal(),
        );
        summary.diagnostic_correlations = diagnostic_evidence.correlations;
        summary.diagnostic_entries = diagnostic_evidence.entries;
        return summary;
    }

    fn districtSlotResident(self: *App, slot_index: usize) !bool {
        return self.district_streaming.slotResident(slot_index);
    }

    fn districtSlotIdle(self: *const App, slot_index: usize) bool {
        return self.district_streaming.slotIdle(slot_index);
    }

    fn validateS6SingleResident(self: *App, slot_index: usize) !void {
        const active = try self.district_streaming.slot(slot_index);
        if (active.phase != .active) return error.S6StreamingSmokeDistrictNotActive;
        if (!try self.districtSlotResident(slot_index) or
            self.simulation.districts().count() != 1 or
            self.simulation.districts().bodyCount() != 3 or
            self.simulation.inspection().entityCount() != 1 or
            self.simulation.inspection().bodyCount() != 4 or
            !std.meta.eql(
                self.simulation.districts().activeTicket(active.coord) orelse
                    return error.S6StreamingSmokeTicketMissing,
                active.ticket.?,
            ))
        {
            return error.S6StreamingSmokeSingleDistrictInvariant;
        }
        const draws = try self.simulation.districts().presentation();
        if (draws.len != 1 or !std.meta.eql(draws[0].ticket, active.ticket.?)) {
            return error.S6StreamingSmokeSinglePresentationInvariant;
        }
        const stats = try self.district_streaming.gpuUsage();
        if (stats.live_scenes != 1 or stats.resident_scenes != 1 or
            stats.resident_gpu_bytes != installed_district_gpu_bytes)
        {
            return error.S6StreamingSmokeSingleGpuInvariant;
        }
    }

    fn validateS6Overlap(self: *App) !void {
        if (!try self.districtSlotResident(district_west_slot_index) or
            !try self.districtSlotResident(district_east_slot_index) or
            self.simulation.districts().count() != 2 or
            self.simulation.districts().bodyCount() != 6 or
            self.simulation.inspection().entityCount() != 2 or
            self.simulation.inspection().bodyCount() != 7)
        {
            return error.S6StreamingSmokeOverlapLogicalInvariant;
        }
        const draws = try self.simulation.districts().presentation();
        if (draws.len != 2 or
            draws[0].build.coord.x != district_west_coord.x or
            draws[0].build.coord.z != district_west_coord.z or
            draws[1].build.coord.x != district_east_coord.x or
            draws[1].build.coord.z != district_east_coord.z)
        {
            return error.S6StreamingSmokeOverlapPresentationInvariant;
        }
        for (draws) |draw| {
            const slot_index = self.district_streaming.slotIndexForCoord(draw.build.coord) orelse
                return error.S6StreamingSmokeOverlapPresentationInvariant;
            const active = try self.district_streaming.slot(slot_index);
            if (active.phase != .active) return error.S6StreamingSmokeDistrictNotActive;
            if (!std.meta.eql(active.ticket.?, draw.ticket)) {
                return error.S6StreamingSmokeOverlapPresentationInvariant;
            }
            const resident = try self.district_streaming.resolve(
                draw.build.coord,
                draw.ticket,
                draw.assets.scene,
            );
            if (resident.meshes().len != installed_district_meshes or
                resident.materials().len != installed_district_materials or
                resident.instances().len != installed_district_instances)
            {
                std.debug.print(
                    "S6_AUTHORED_SCENE_MISMATCH meshes={d} materials={d} instances={d}\n",
                    .{
                        resident.meshes().len,
                        resident.materials().len,
                        resident.instances().len,
                    },
                );
                return error.S6StreamingSmokeAuthoredSceneInvariant;
            }
        }
        const stats = try self.district_streaming.gpuUsage();
        if (stats.live_scenes != 2 or stats.resident_scenes != 2 or
            stats.resident_gpu_bytes != 2 * installed_district_gpu_bytes)
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
            const active = try self.district_streaming.slot(slot_index);
            if (active.phase != .active) return error.S6StreamingSmokeDistrictNotActive;
            if (stream.coord.x != active.coord.x or stream.coord.z != active.coord.z or
                stream.state != .active or !stream.desired_inside or
                stream.generations.content != active.content_generation or
                stream.generations.logical != active.ticket.?.generation or
                stream.correlation_id != active.correlation_id or
                !std.meta.eql(
                    stream.scene orelse
                        return error.S6StreamingSmokeDiagnosticSceneMissing,
                    active.scene.?,
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
            gpu.current.resident_gpu_bytes != 2 * installed_district_gpu_bytes or
            gpu.high_water.live_scenes < 2 or
            gpu.high_water.resident_scenes < 2 or
            gpu.high_water.active_batches < 1 or
            gpu.high_water.staged_cpu_bytes < installed_district_staged_cpu_bytes or
            gpu.high_water.in_flight_upload_bytes < installed_district_gpu_bytes or
            gpu.high_water.resident_gpu_bytes < 2 * installed_district_gpu_bytes)
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
            const slot_view = try self.district_streaming.slot(slot_index);
            if (stream.coord.x != slot_view.coord.x or stream.coord.z != slot_view.coord.z or
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
            gpu.high_water.staged_cpu_bytes < installed_district_staged_cpu_bytes or
            gpu.high_water.in_flight_upload_bytes < installed_district_gpu_bytes or
            gpu.high_water.resident_gpu_bytes < 2 * installed_district_gpu_bytes)
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
            if (!self.pumpInputEvents()) {
                return error.S6StreamingSmokeInterrupted;
            }
            if (self.waitForWindowSuspension()) continue;
            try self.frame_timer.beginFrameWithElapsedSeconds(
                1.0 / @as(f64, @floatFromInt(config.virtual_render_hz)),
            );
            try self.district_streaming.pumpContent(self.districtAuthorityPort(), self.frame_timer.total_frames);
            const ticks_before = self.simulation.inspection().tickIndex();
            while (self.frame_timer.shouldTick()) {
                try self.simulateTick(true, .s8_population);
                self.frame_timer.recordCompletedTick();
            }
            const ticks_this_frame = self.simulation.inspection().tickIndex() - ticks_before;
            if (ticks_this_frame == 0) summary.zero_tick_frames += 1;
            if (ticks_this_frame > 1) summary.multi_tick_frames += 1;
            summary.observe(try self.district_streaming.gpuUsage());
            switch (try self.render(self.frame_timer.alpha())) {
                .ready => {},
                .unavailable => return error.S6StreamingSmokeUnavailableFrame,
            }
            summary.attempted_frames += 1;
            summary.observe(try self.district_streaming.gpuUsage());

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
                        try self.district_streaming.gpuUsage(),
                        developer_diagnostics.GpuUsage{},
                    ))
                {
                    break;
                },
            }
            c.SDL_DelayPrecise(@as(u64, std.time.ns_per_s) / config.virtual_render_hz);
        }

        summary.ticks = self.simulation.inspection().tickIndex();
        if (stage != .final_drain or
            !self.districtSlotIdle(district_west_slot_index) or
            !self.districtSlotIdle(district_east_slot_index) or
            self.district_streaming.contentOwnerActive() or
            self.simulation.districts().count() != 0 or
            self.simulation.districts().bodyCount() != 0 or
            self.simulation.inspection().entityCount() != 0 or
            self.simulation.inspection().bodyCount() != 1 or
            !std.meta.eql(
                try self.district_streaming.gpuUsage(),
                developer_diagnostics.GpuUsage{},
            ))
        {
            return error.S6StreamingSmokeDidNotDrain;
        }
        try self.validateS6DrainedDeveloperSnapshot();
        if (!self.district_streaming.workerIdle() or
            summary.overlap_cycles != s6_required_overlap_cycles or
            summary.forward_overlaps != s6_required_overlap_cycles or
            summary.reverse_overlaps != s6_required_overlap_cycles or
            summary.peak_live_scenes != 2 or
            summary.peak_resident_scenes != 2 or
            summary.peak_staged_cpu_bytes != installed_district_staged_cpu_bytes or
            summary.peak_staged_upload_bytes != installed_district_gpu_bytes or
            summary.peak_in_flight_upload_bytes == 0 or
            summary.peak_in_flight_upload_bytes > 2 * installed_district_gpu_bytes or
            summary.peak_in_flight_upload_bytes % installed_district_gpu_bytes != 0 or
            summary.peak_resident_gpu_bytes != 2 * installed_district_gpu_bytes or
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

    /// Consume every NPC output at each completed-tick boundary while
    /// requiring exact per-request and per-identity lifecycle evidence.
    fn processS8NpcOutputs(
        self: *App,
        summary: *S8PopulationSmokeSummary,
        evidence: *S8PopulationEvidence,
        stage: S8SmokeStage,
    ) !void {
        while (self.simulation.npcs().pollOutcome()) |outcome| {
            try evidence.observeOutcome(stage, summary, outcome);
        }
        while (self.simulation.npcs().pollEvent()) |event| {
            try evidence.observeEvent(stage, summary, event);
        }
        self.recordNpcNavigationTransitions();
    }

    fn requireS8NpcViews(
        self: *App,
        ids: *const [s8_population_count]?sandbox_contracts.PersistentId,
        owner: sandbox_contracts.ChunkCoord,
        state: sandbox_contracts.NpcState,
        controller_present: bool,
    ) !void {
        for (ids) |optional_id| {
            const view = try self.simulation.npcs().view(optional_id orelse
                return error.S8PopulationIdentityMissing);
            if (!std.meta.eql(view.owner, owner) or view.state != state or
                view.controller_present != controller_present)
            {
                return error.S8PopulationViewMismatch;
            }
        }
    }

    fn requireS8ProjectedNpcIdentities(
        self: *App,
        ids: *const [s8_population_count]?sandbox_contracts.PersistentId,
    ) !void {
        const draws = self.simulation.presentation().npcs(0);
        if (draws.len != s8_population_count) {
            return error.S8PopulationProjectionCountMismatch;
        }
        var seen: [s8_population_count]bool = @splat(false);
        for (draws) |draw| {
            var matched = false;
            for (ids, 0..) |optional_id, index| {
                const id = optional_id orelse return error.S8PopulationIdentityMissing;
                const expected = self.simulation.inspection().replicatedId(id) orelse
                    return error.S8PopulationIdentityMissing;
                if (!std.meta.eql(draw.entity, expected)) continue;
                if (seen[index]) return error.S8PopulationProjectionIdentityMismatch;
                seen[index] = true;
                matched = true;
                break;
            }
            if (!matched) return error.S8PopulationProjectionIdentityMismatch;
        }
        for (seen) |value| {
            if (!value) return error.S8PopulationProjectionIdentityMismatch;
        }
    }

    fn s8SimulationQueuesEmpty(diagnostics: sandbox_contracts.Diagnostics) bool {
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
        var replica_wait_started_tick: ?u64 = null;
        self.district_focus_override = s6_overlap;
        self.district_prefetch_focus_override = s6_overlap;

        smoke_loop: while (summary.attempted_frames < config.frames) {
            self.input_buffer.beginFrame();
            if (!self.pumpInputEvents()) {
                return error.S8PopulationSmokeInterrupted;
            }
            if (self.waitForWindowSuspension()) continue;
            try self.frame_timer.beginFrameWithElapsedSeconds(
                1.0 / @as(f64, @floatFromInt(config.virtual_render_hz)),
            );
            try self.district_streaming.pumpContent(self.districtAuthorityPort(), self.frame_timer.total_frames);
            summary.observeGpu(try self.district_streaming.gpuUsage());

            const ticks_before = self.simulation.inspection().tickIndex();
            while (self.frame_timer.shouldTick()) {
                try self.simulateTick(true, .s8_population);
                try self.processS8NpcOutputs(&summary, &evidence, stage);
                self.frame_timer.recordCompletedTick();
            }
            const ticks_this_frame = self.simulation.inspection().tickIndex() - ticks_before;
            if (ticks_this_frame == 0) summary.zero_tick_frames += 1;
            if (ticks_this_frame > 1) summary.multi_tick_frames += 1;

            const simulation_diagnostics = self.simulation.developer().diagnostics();
            const diagnostics = simulation_diagnostics.npc;
            try summary.observeNpc(
                diagnostics,
                simulation_diagnostics.character_controllers,
                simulation_diagnostics.characters.active_count,
            );
            const presentation = switch (try self.render(self.frame_timer.alpha())) {
                .ready => |value| value,
                .unavailable => return error.S8PopulationSmokeUnavailableFrame,
            };
            summary.attempted_frames += 1;
            summary.observeGpu(try self.district_streaming.gpuUsage());
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
                    try self.simulation.characters().submit(.{ .spawn = .{
                        .request_id = 1,
                        .position = sandbox_contracts.default_character_spawn_position,
                    } });
                    stage = .observer_spawned;
                },
                .observer_spawned => if (self.initial_character_id != null and
                    presentation.character_count == 1)
                {
                    const batch = try population.planSynthetic(s8_population_count, .{
                        .first_request_id = s8_spawn_first_request_id,
                        .position = .{ -5, 0, 5 },
                        .facing_yaw = 0,
                        .anchor = s8_west_start,
                        .hostile_to_players = true,
                        .goal = .{ .patrol_between = .{
                            .first = sandbox_contracts.south_gate_approach_destination,
                            .second = s8_east_destination,
                        } },
                    });
                    for (batch.slice()) |command| try self.simulation.npcs().submit(command);
                    summary.planned = @intCast(batch.slice().len);
                    stage = .population_spawned;
                },
                .population_spawned => if (evidence.spawnedComplete()) {
                    if (self.simulation.npcs().count() != s8_population_count or
                        summary.spawned != s8_population_count or
                        diagnostics.active_count != s8_population_count or
                        diagnostics.controller_count != s8_population_count)
                    {
                        return error.S8PopulationSpawnMismatch;
                    }
                    if (try s8ReplicaConverged(
                        self.simulation.inspection().tickIndex(),
                        &replica_wait_started_tick,
                        presentation.npc_count == s8_population_count,
                    )) {
                        try self.requireS8ProjectedNpcIdentities(&evidence.identities);
                        try self.requireS8NpcViews(
                            &evidence.identities,
                            district_west_coord,
                            .active,
                            true,
                        );
                        self.district_focus_override = s6_west_only;
                        self.district_prefetch_focus_override = s8_west_only_prefetch;
                        stage = .destination_waiting;
                    }
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
                    try self.requireS8ProjectedNpcIdentities(&evidence.identities);
                    self.district_focus_override = s6_overlap;
                    self.district_prefetch_focus_override = s6_overlap;
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
                    try self.requireS8ProjectedNpcIdentities(&evidence.identities);
                    stage = .crossed_east;
                },
                .crossed_east => if (evidence.transferComplete() and
                    try self.districtSlotResident(district_west_slot_index) and
                    try self.districtSlotResident(district_east_slot_index))
                {
                    if (summary.transfer_events != s8_population_count or
                        diagnostics.transfers != s8_population_count or
                        diagnostics.active_count != s8_population_count or
                        diagnostics.controller_count != s8_population_count)
                    {
                        return error.S8PopulationTransferMismatch;
                    }
                    if (try s8ReplicaConverged(
                        self.simulation.inspection().tickIndex(),
                        &replica_wait_started_tick,
                        presentation.npc_count == s8_population_count,
                    )) {
                        try self.requireS8ProjectedNpcIdentities(&evidence.identities);
                        try self.requireS8NpcViews(
                            &evidence.identities,
                            district_east_coord,
                            .active,
                            true,
                        );
                        self.district_focus_override = s6_west_only;
                        self.district_prefetch_focus_override = s8_west_only_prefetch;
                        stage = .owner_dormant;
                    }
                },
                .owner_dormant => if (self.districtSlotIdle(
                    district_east_slot_index,
                ) and evidence.dormantComplete() and try s8ReplicaConverged(
                    self.simulation.inspection().tickIndex(),
                    &replica_wait_started_tick,
                    presentation.npc_count == 0,
                )) {
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
                    self.district_prefetch_focus_override = s6_overlap;
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
                        presentation.npc_count != 0)
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
                        try self.simulation.npcs().submit(.{ .despawn = .{
                            .request_id = s8_despawn_first_request_id + index,
                            .id = optional_id orelse
                                return error.S8PopulationIdentityMissing,
                        } });
                    }
                    stage = .population_despawned;
                },
                .population_despawned => if (evidence.despawnedComplete()) {
                    if (self.simulation.npcs().count() != 0 or
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
                    self.district_prefetch_focus_override = s6_fully_outside;
                    try self.simulation.characters().submit(.{ .despawn = .{
                        .id = self.initial_character_id orelse
                            return error.S8PopulationObserverMissing,
                    } });
                    stage = .observer_despawned;
                },
                .observer_despawned => if (self.initial_character_id == null and
                    presentation.character_count == 0)
                {
                    stage = .final_drain;
                },
                .final_drain => if (self.districtSlotIdle(district_west_slot_index) and
                    self.districtSlotIdle(district_east_slot_index) and
                    std.meta.eql(
                        try self.district_streaming.gpuUsage(),
                        developer_diagnostics.GpuUsage{},
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
        summary.observeGpu((try self.district_streaming.gpuDiagnostics()).high_water);
        if (!evidence.complete()) {
            std.debug.print(
                "S8_EVIDENCE_INCOMPLETE stage={s} spawned={any} first_goal={any} " ++
                    "waiting={any} resumed={any} transferred={any} dormant={any} " ++
                    "controller_resumed={any} despawned={any}\n",
                .{
                    @tagName(stage),
                    evidence.spawned,
                    evidence.first_destination_reached,
                    evidence.waiting,
                    evidence.waiting_resumed,
                    evidence.transferred,
                    evidence.dormant,
                    evidence.controller_resumed,
                    evidence.despawned,
                },
            );
        }
        try evidence.requireComplete();
        summary.ticks = self.simulation.inspection().tickIndex();
        const final_diagnostics = self.simulation.developer().diagnostics();
        summary.final_entities = final_diagnostics.entity_count;
        summary.final_bodies = final_diagnostics.body_count;
        summary.final_native_controllers =
            final_diagnostics.character_controllers.native_used;
        summary.final_draws = @intCast(self.simulation.presentation().npcs(0).len);
        if (stage != .final_drain or self.district_streaming.contentOwnerActive() or
            !self.district_streaming.workerIdle() or
            !self.districtSlotIdle(district_west_slot_index) or
            !self.districtSlotIdle(district_east_slot_index) or
            self.simulation.npcs().count() != 0 or
            self.simulation.districts().count() != 0 or
            self.simulation.districts().bodyCount() != 0 or
            !s8SimulationQueuesEmpty(final_diagnostics) or
            !std.meta.eql(
                try self.district_streaming.gpuUsage(),
                developer_diagnostics.GpuUsage{},
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
        if (self.simulation.districts().count() != districts or
            self.simulation.districts().bodyCount() != district_bodies or
            self.simulation.characters().count() != characters or
            self.simulation.interactions().count() != carryables or
            self.simulation.inspection().entityCount() != entities or
            self.simulation.inspection().bodyCount() != bodies)
        {
            std.debug.print(
                "S7_COMPOSITION_MISMATCH expected={d}/{d}/{d}/{d}/{d}/{d} actual={d}/{d}/{d}/{d}/{d}/{d}\n",
                .{
                    districts,
                    district_bodies,
                    characters,
                    carryables,
                    entities,
                    bodies,
                    self.simulation.districts().count(),
                    self.simulation.districts().bodyCount(),
                    self.simulation.characters().count(),
                    self.simulation.interactions().count(),
                    self.simulation.inspection().entityCount(),
                    self.simulation.inspection().bodyCount(),
                },
            );
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
        var replica_wait_started_tick: ?u64 = null;

        while (summary.attempted_frames < config.frames) {
            self.input_buffer.beginFrame();
            if (!self.pumpInputEvents()) {
                return error.S7InteractionSmokeInterrupted;
            }
            if (self.waitForWindowSuspension()) continue;
            try self.frame_timer.beginFrameWithElapsedSeconds(
                1.0 / @as(f64, @floatFromInt(config.virtual_render_hz)),
            );
            try self.district_streaming.pumpContent(self.districtAuthorityPort(), self.frame_timer.total_frames);
            const ticks_before = self.simulation.inspection().tickIndex();
            while (self.frame_timer.shouldTick()) {
                try self.simulateTick(true, .s7_interaction);
                self.frame_timer.recordCompletedTick();
            }
            const ticks_this_frame = self.simulation.inspection().tickIndex() - ticks_before;
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
                const persistent_id = self.initial_carryable_id orelse
                    return error.S7InteractionSmokeUnexpectedCarryableDraw;
                const expected = self.simulation.inspection().replicatedId(
                    persistent_id,
                ) orelse return error.S7InteractionSmokeUnexpectedCarryableDraw;
                if (!std.meta.eql(id, expected)) {
                    return error.S7InteractionSmokeUnexpectedCarryableDraw;
                }
                summary.carryable_draw_frames += 1;
                const view = try self.simulation.interactions().view(persistent_id);
                switch (view.ownership) {
                    .spatially_owned => {},
                    .inventory_held => summary.held_draw_frames += 1,
                }
            } else if (presentation.carryable_id != null) {
                return error.S7InteractionSmokeCarryableDrawCountMismatch;
            }

            switch (stage) {
                .west_resident => if (self.simulation.districts().activeTicket(
                    district_west_coord,
                ) != null and self.simulation.districts().activeTicket(district_east_coord) == null and
                    self.initial_character_id != null)
                {
                    stage = .carryable_spawned;
                },
                .carryable_spawned => if (self.initial_carryable_id) |id| {
                    const view = try self.simulation.interactions().view(id);
                    switch (view.ownership) {
                        .spatially_owned => |owner| {
                            if (!std.meta.eql(owner, district_west_coord) or
                                !view.body_present or
                                presentation.carryable_count != 1 or
                                std.meta.activeTag(self.interaction_last_outcome orelse
                                    return error.S7InteractionSmokeSpawnOutcomeMissing) != .spawned)
                            {
                                return error.S7InteractionSmokeSpawnInvariant;
                            }
                            try self.requireS7Counts(1, 3, 1, 1, 3, 5);
                            const diagnostics = self.simulation.developer().diagnostics().interaction;
                            if (diagnostics.active_count != 1 or
                                diagnostics.spatially_owned_count != 1 or
                                diagnostics.held_count != 0 or
                                diagnostics.dynamic_body_count != 1)
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
                    const view = try self.simulation.interactions().view(id);
                    switch (view.ownership) {
                        .spatially_owned => {},
                        .inventory_held => |holder| {
                            if (!std.meta.eql(holder, self.initial_character_id orelse
                                return error.S7InteractionSmokeCarrierMissing) or
                                view.body_present or presentation.carryable_count != 1 or
                                (self.interaction_last_player_result orelse
                                    return error.S7InteractionSmokeCollectOutcomeMissing).disposition != .collected)
                            {
                                return error.S7InteractionSmokeCollectInvariant;
                            }
                            try self.requireS7Counts(1, 3, 1, 1, 3, 4);
                            const diagnostics = self.simulation.developer().diagnostics().interaction;
                            if (diagnostics.held_count != 1 or
                                diagnostics.dynamic_body_count != 0)
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
                    const view = try self.simulation.interactions().view(id);
                    switch (view.ownership) {
                        .spatially_owned => return error.S7InteractionSmokeOwnershipRegressed,
                        .inventory_held => {},
                    }
                    if (self.simulation.districts().activeTicket(district_west_coord) == null) {
                        summary.source_unloaded_while_held = true;
                    }
                    const character = try self.simulation.characters().view(
                        self.initial_character_id orelse
                            return error.S7InteractionSmokeCarrierMissing,
                    );
                    if (character.position[0] >= s7_east_relevance_drop_x) {
                        self.validation.s7_scripted_move = .{ 0, 0 };
                    }
                    if (character.position[0] >= s7_east_relevance_drop_x and
                        self.simulation.districts().activeTicket(district_west_coord) == null and
                        self.simulation.districts().activeTicket(district_east_coord) != null)
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
                    const view = try self.simulation.interactions().view(id);
                    switch (view.ownership) {
                        .inventory_held => {},
                        .spatially_owned => |owner| {
                            if (!std.meta.eql(owner, district_east_coord) or
                                !view.body_present or presentation.carryable_count != 1 or
                                (self.interaction_last_player_result orelse
                                    return error.S7InteractionSmokeDropOutcomeMissing).disposition != .dropped)
                            {
                                return error.S7InteractionSmokeDropInvariant;
                            }
                            try self.requireS7Counts(1, 3, 1, 1, 3, 5);
                            summary.dropped_east = true;
                            self.district_focus_override = s6_fully_outside;
                            stage = .east_content_unloaded;
                        },
                    }
                },
                .east_content_unloaded => if (self.simulation.districts().count() == 0 and
                    self.district_streaming.workerIdle())
                {
                    const id = self.initial_carryable_id orelse
                        return error.S7InteractionSmokeCarryableMissing;
                    const view = try self.simulation.interactions().view(id);
                    if (!view.body_present) {
                        return error.S7InteractionSmokeSpatialBodyMissing;
                    }
                    try self.requireS7Counts(0, 0, 1, 1, 2, 2);
                    const diagnostics = self.simulation.developer().diagnostics().interaction;
                    if (diagnostics.spatially_owned_count != 1 or
                        diagnostics.dynamic_body_count != 1)
                    {
                        return error.S7InteractionSmokeSpatialDiagnosticsMismatch;
                    }
                    if (!try s7ReplicaConverged(
                        self.simulation.inspection().tickIndex(),
                        &replica_wait_started_tick,
                        presentation.carryable_count == 1,
                    )) continue;
                    summary.physical_after_content_unload = true;
                    self.district_focus_override = s6_east_only;
                    stage = .east_content_reloaded;
                },
                .east_content_reloaded => if (self.simulation.districts().activeTicket(
                    district_west_coord,
                ) == null and self.simulation.districts().activeTicket(district_east_coord) != null) {
                    const id = self.initial_carryable_id orelse
                        return error.S7InteractionSmokeCarryableMissing;
                    const view = try self.simulation.interactions().view(id);
                    if (!view.body_present) {
                        return error.S7InteractionSmokeReloadDrawInvariant;
                    }
                    try self.requireS7Counts(1, 3, 1, 1, 3, 5);
                    const diagnostics = self.simulation.developer().diagnostics().interaction;
                    if (diagnostics.spatially_owned_count != 1 or
                        diagnostics.dynamic_body_count != 1)
                    {
                        return error.S7InteractionSmokeReloadDiagnosticsMismatch;
                    }
                    if (!try s7ReplicaConverged(
                        self.simulation.inspection().tickIndex(),
                        &replica_wait_started_tick,
                        presentation.carryable_count == 1,
                    )) continue;
                    summary.stable_after_content_reload = true;
                    try self.simulation.interactions().submit(.{ .despawn = .{ .id = id } });
                    stage = .carryable_despawned;
                },
                .carryable_despawned => if (self.initial_carryable_id == null) {
                    if (!try s7ReplicaConverged(
                        self.simulation.inspection().tickIndex(),
                        &replica_wait_started_tick,
                        presentation.carryable_count == 0,
                    )) continue;
                    try self.requireS7Counts(1, 3, 1, 0, 2, 4);
                    // Stop the per-tick producer before queuing despawn. Both
                    // commands otherwise target the same next tick, and FIFO
                    // would correctly reject the trailing action after the
                    // character identity has been destroyed.
                    self.validation.s7_character_actions_enabled = false;
                    try self.simulation.characters().submit(.{ .despawn = .{
                        .id = self.initial_character_id orelse
                            return error.S7InteractionSmokeCarrierMissing,
                    } });
                    stage = .character_despawned;
                },
                .character_despawned => if (self.initial_character_id == null) {
                    if (!try s7ReplicaConverged(
                        self.simulation.inspection().tickIndex(),
                        &replica_wait_started_tick,
                        presentation.character_count == 0,
                    )) continue;
                    try self.requireS7Counts(1, 3, 0, 0, 1, 4);
                    self.district_focus_override = s6_fully_outside;
                    stage = .final_drain;
                },
                .final_drain => if (self.districtSlotIdle(district_west_slot_index) and
                    self.districtSlotIdle(district_east_slot_index) and
                    std.meta.eql(
                        try self.district_streaming.gpuUsage(),
                        developer_diagnostics.GpuUsage{},
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

        summary.ticks = self.simulation.inspection().tickIndex();
        const final_diagnostics = self.simulation.developer().diagnostics();
        summary.final_entities = final_diagnostics.entity_count;
        summary.final_bodies = final_diagnostics.body_count;
        if (stage != .final_drain or self.district_streaming.contentOwnerActive() or
            !self.district_streaming.workerIdle() or
            !summary.collected or !summary.crossed_east or !summary.dropped_east or
            !summary.source_unloaded_while_held or !summary.physical_after_content_unload or
            !summary.stable_after_content_reload or summary.carryable_draw_frames == 0 or
            summary.held_draw_frames == 0 or summary.district_draw_frames == 0 or
            summary.final_entities != 0 or summary.final_bodies != 1 or
            self.interaction_submission_failures != 0 or
            self.interaction_requests.rejected != 0 or
            (config.virtual_render_hz > timing.TICK_RATE and
                (summary.zero_tick_frames == 0 or summary.multi_tick_frames != 0)) or
            (config.virtual_render_hz < timing.TICK_RATE and
                (summary.multi_tick_frames == 0 or summary.zero_tick_frames != 0)))
        {
            const west_slot = try self.district_streaming.slot(district_west_slot_index);
            const east_slot = try self.district_streaming.slot(district_east_slot_index);
            std.debug.print(
                "S7_INTERACTION_SMOKE_INCOMPLETE stage={s} west={s}/{} east={s}/{} character={} carryable={} content_owner_active={} worker_idle={} collected={} crossed={} dropped={} source_unloaded={} physical_unloaded={} stable_reloaded={} entities={d} bodies={d} interaction_failures={d} request_rejections={d}\n",
                .{
                    @tagName(stage),
                    @tagName(west_slot.phase),
                    try self.districtSlotResident(district_west_slot_index),
                    @tagName(east_slot.phase),
                    try self.districtSlotResident(district_east_slot_index),
                    self.initial_character_id != null,
                    self.initial_carryable_id != null,
                    self.district_streaming.contentOwnerActive(),
                    self.district_streaming.workerIdle(),
                    summary.collected,
                    summary.crossed_east,
                    summary.dropped_east,
                    summary.source_unloaded_while_held,
                    summary.physical_after_content_unload,
                    summary.stable_after_content_reload,
                    summary.final_entities,
                    summary.final_bodies,
                    self.interaction_submission_failures,
                    self.interaction_requests.rejected,
                },
            );
            return error.S7InteractionSmokeEvidenceMissing;
        }
        return summary;
    }

    fn validateS3Resident(
        self: *App,
        active: district_streaming_host.SlotView,
    ) !void {
        if (self.simulation.districts().count() != 1 or
            self.simulation.districts().bodyCount() != 3 or
            self.simulation.inspection().entityCount() != 1 or
            self.simulation.inspection().bodyCount() != 4)
        {
            return error.S3StreamingSmokeLogicalInvariant;
        }
        const draws = try self.simulation.districts().presentation();
        if (draws.len != 1) return error.S3StreamingSmokePresentationInvariant;
        const resident = try self.district_streaming.resolve(
            active.coord,
            draws[0].ticket,
            active.scene.?,
        );
        if (resident.meshes().len != installed_district_meshes or
            resident.materials().len != installed_district_materials or
            resident.instances().len != installed_district_instances)
        {
            return error.S3StreamingSmokeAuthoredSceneInvariant;
        }
        const stats = try self.district_streaming.gpuUsage();
        // The adjacent district may already be visually prefetched while its
        // logical authority remains inactive. Validate the exact resident
        // scene accounting instead of assuming worker completion order.
        if (stats.resident_scenes == 0 or stats.resident_scenes > 2 or
            stats.live_scenes != stats.resident_scenes or
            stats.resident_gpu_bytes !=
                @as(u64, stats.resident_scenes) * installed_district_gpu_bytes)
        {
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
            gpu.current.resident_scenes == 0 or gpu.current.resident_scenes > 2 or
            gpu.current.live_scenes != gpu.current.resident_scenes or
            gpu.current.active_batches != 0 or
            gpu.current.resident_gpu_bytes !=
                @as(u64, gpu.current.resident_scenes) * installed_district_gpu_bytes or
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
        if (!self.district_streaming.slotIdle(district_west_slot_index) or
            !self.district_streaming.slotIdle(district_east_slot_index) or
            self.simulation.districts().count() != 0 or
            self.simulation.districts().bodyCount() != 0 or
            self.simulation.inspection().entityCount() != 0 or
            self.simulation.inspection().bodyCount() != 1 or
            !std.meta.eql(
                try self.district_streaming.gpuUsage(),
                developer_diagnostics.GpuUsage{},
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
        if (!try self.district_streaming.sceneIsStale(scene)) {
            return error.S3StreamingSmokeSceneStillLive;
        }
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
            if (!self.pumpInputEvents()) {
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
        const route = self.developer.processEditorEvent(&event);
        if (!route.keyboard_reserved or
            self.developer.editorVisible() != expected_visible)
        {
            return error.S5AuthoringEditorToggleFailed;
        }
    }

    fn runS5AuthoringSmoke(self: *App) !S5AuthoringSmokeSummary {
        if (!build_options.editor_enabled) return error.S5AuthoringEditorRequired;
        if (self.validation.profile != .s1_smoke or
            self.persistence.lifecycle() != .ready)
        {
            return error.InvalidS5AuthoringSmokeComposition;
        }
        if (!self.developer.editorVisible()) {
            return error.S5AuthoringEditorNotVisible;
        }

        var summary = S5AuthoringSmokeSummary{};
        try self.simulateTick(true, .none);
        const id = self.initial_crate_id orelse return error.S5AuthoringCrateMissing;
        const initial = try self.simulation.crates().view(id);
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
        const edited = try self.simulation.crates().view(id);
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
        const naturally_advanced = try self.simulation.crates().view(id);
        if (naturally_advanced.authoring_revision != 1) {
            return error.S5AuthoringNaturalPhysicsAdvancedRevision;
        }

        try self.applyS5SmokeRequests(&.{.undo});
        try self.simulateTick(true, .none);
        const undone = try self.simulation.crates().view(id);
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
        const redone = try self.simulation.crates().view(id);
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

        const before_hidden = try self.settlePersistenceObservation();
        const history_before_hidden = self.authoring_controller.snapshot();
        try self.toggleEditorForS5Smoke(false);
        _ = try self.renderS5SmokeFrame(0.25);
        summary.hidden_frames += 1;
        const after_hidden = try self.observePersistenceSnapshot();
        if (!std.meta.eql(before_hidden, after_hidden) or
            !std.meta.eql(history_before_hidden, self.authoring_controller.snapshot()))
        {
            return error.S5AuthoringHiddenEditorMutatedAuthority;
        }
        try self.toggleEditorForS5Smoke(true);
        _ = try self.renderS5SmokeFrame(0.5);
        summary.rendered_frames += 1;

        try self.applyS5SmokeRequests(&.{.save});
        for (0..session_budgets.ticks_per_snapshot + 2) |_| {
            if (!self.persistence_commit_pending) break;
            try self.simulateTick(true, .none);
        }
        if (self.persistence_commit_pending) {
            return error.S5AuthoringSaveDidNotReachDisposition;
        }
        const save_feedback = self.editorSaveFeedback();
        summary.save_status = save_feedback.status;
        summary.save_sequence = save_feedback.sequence;
        switch (save_feedback.status) {
            .committed, .committed_sync_warning => {},
            else => return error.S5AuthoringSaveNotCommitted,
        }
        if (summary.save_sequence == 0 or
            !std.mem.eql(
                u8,
                save_feedback.slot_label,
                sandbox_persistence.slot_label,
            ))
        {
            return error.S5AuthoringSaveFeedbackMissing;
        }

        // Selection/history are session-only; they are not written into the
        // canonical authority payload or allowed to alter the saved revision.
        const final_crate = try self.simulation.crates().view(id);
        if (self.authoring_controller.snapshot().selected == null or
            final_crate.authoring_revision != 3 or
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
        const tick_before_pause = self.simulation.inspection().tickIndex();
        const before_pause = try self.observePersistenceSnapshot();

        self.applyDeveloperControlRequests(&.{.{ .set_paused = true }});
        if (!self.developer.controlSnapshot().paused) {
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
        if (self.simulation.inspection().tickIndex() != tick_before_pause) {
            return error.S4DiagnosticsPauseAdvancedSimulation;
        }
        const after_pause = try self.observePersistenceSnapshot();
        if (!std.meta.eql(before_pause, after_pause)) {
            return error.S4DiagnosticsPauseMutatedSave;
        }

        self.applyDeveloperControlRequests(&.{.single_step});
        if (!self.developer.takeSingleStep()) {
            return error.S4DiagnosticsStepNotQueued;
        }
        try self.simulateTick(true, .none);
        self.frame_timer.recordSingleStep();
        const tick_after_step = self.simulation.inspection().tickIndex();
        if (tick_after_step != tick_before_pause + 1 or
            self.frame_timer.ticks_this_frame != 1 or
            self.developer.takeSingleStep())
        {
            return error.S4DiagnosticsStepCountMismatch;
        }

        // Arm an exact host-control trigger, include the matching record, then
        // prove rejection, disarm/resume, retained counters, and monotonic
        // sequence identity across an explicit clear.
        const before_freeze = self.simulation.developer().journal().stats();
        self.applyDeveloperDiagnosticRequests(&.{.{ .arm_freeze = .{
            .severity = .info,
            .category = .host,
            .code = sandbox_developer_host.diagnostic_codes.host_control_applied,
        } }});
        self.applyDeveloperControlRequests(&.{.{ .set_time_scale = .half }});
        const frozen = self.simulation.developer().journal().stats();
        if (!frozen.frozen or frozen.trigger_armed or
            frozen.count != before_freeze.count + 1)
        {
            return error.S4DiagnosticsFreezeMismatch;
        }
        self.applyDeveloperControlRequests(&.{.{ .set_time_scale = .normal }});
        const rejected = self.simulation.developer().journal().stats();
        if (!rejected.frozen or rejected.count != frozen.count or
            rejected.rejected_while_frozen != frozen.rejected_while_frozen + 1)
        {
            return error.S4DiagnosticsFrozenRejectionMismatch;
        }

        self.applyDeveloperDiagnosticRequests(&.{ .disarm_freeze, .resume_capture });
        const resumed = self.simulation.developer().journal().stats();
        if (resumed.frozen or resumed.trigger_armed or resumed.count != rejected.count or
            resumed.rejected_while_frozen != rejected.rejected_while_frozen)
        {
            return error.S4DiagnosticsResumeMismatch;
        }
        self.applyDeveloperControlRequests(&.{.{ .set_time_scale = .double }});
        const admitted = self.simulation.developer().journal().stats();
        if (admitted.count != resumed.count + 1) {
            return error.S4DiagnosticsResumeAdmissionMissing;
        }
        const admitted_view = self.simulation.developer().journal().borrowedChronological();
        const last_sequence = admitted_view.at(admitted_view.len() - 1).?.sequence;

        self.applyDeveloperDiagnosticRequests(&.{.clear});
        const cleared = self.simulation.developer().journal().stats();
        if (cleared.count != 0 or cleared.frozen or
            cleared.overwritten != admitted.overwritten or
            cleared.rejected_while_frozen != admitted.rejected_while_frozen)
        {
            return error.S4DiagnosticsClearMismatch;
        }
        self.applyDeveloperControlRequests(&.{.{ .set_time_scale = .normal }});
        const after_clear_view = self.simulation.developer().journal().borrowedChronological();
        if (after_clear_view.len() != 1 or
            after_clear_view.at(0).?.sequence != last_sequence + 1)
        {
            return error.S4DiagnosticsClearResetSequence;
        }
        self.applyDeveloperDiagnosticRequests(&.{.clear});
        if (self.simulation.developer().journal().stats().count != 0) {
            return error.S4DiagnosticsSecondClearMismatch;
        }

        self.applyDeveloperControlRequests(&.{.{ .set_paused = false }});
        if (self.developer.paused()) {
            return error.S4DiagnosticsResumeRejected;
        }
        try self.prepareS4ResidentDistrict();

        // M3 correctly made district output pressure a healthy admission
        // rejection, so the old smoke can no longer manufacture a runtime
        // fault by overcommitting that queue. This app instance alone composes
        // a dormant fixed-error system for the retained-fault path. Normal
        // sandbox/headless/replay/save compositions do not register it.
        try self.simulation.developer().armFaultProbe();
        // Drive the failing tick through the validation host's graphical
        // scheduling/catch/retain/inspection/quit path. A consumed opportunity
        // is completed only after the authoritative tick returns successfully.
        const completed_ticks_before_fault = self.frame_timer.total_ticks;
        const committed_tick_before_fault = self.simulation.inspection().tickIndex();
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

        const fault = self.simulation.developer().firstFault() orelse
            return error.S4DiagnosticsFaultMissing;
        if (fault.phase != .commands or fault.tick_index != expected_fault_tick or
            fault.error_code != @intFromError(error.InjectedDeveloperDiagnosticFault) or
            fault.journal_sequence == 0 or
            !std.mem.eql(u8, fault.system_name.slice(), "diagnostics.injected_fault_probe") or
            !std.mem.eql(u8, fault.error_name.slice(), "InjectedDeveloperDiagnosticFault"))
        {
            return error.S4DiagnosticsFaultEvidenceMismatch;
        }
        const fault_journal = self.simulation.developer().journal();
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

        // The first failing lifecycle call propagates the original runtime
        // error so the host can retain it. Once the shared authority latches
        // that failure, its public lifecycle boundary is closed: later
        // operational calls report AuthorityFaulted without reaching the
        // already-faulted simulation.
        var authority_closed = false;
        self.simulation.lifecycle().tick() catch |err| {
            if (err != error.AuthorityFaulted) return err;
            authority_closed = true;
        };
        if (!authority_closed or
            !std.meta.eql(fault, self.simulation.developer().firstFault().?))
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
            if (!self.pumpInputEvents()) {
                return error.S4DiagnosticsSmokeInterrupted;
            }
            if (self.waitForWindowSuspension()) continue;
            try self.frame_timer.beginControlledFrameWithElapsedSeconds(
                1.0 / 60.0,
                .{ .running = .normal },
            );
            try self.district_streaming.pumpContent(self.districtAuthorityPort(), self.frame_timer.total_frames);
            while (self.frame_timer.shouldTick()) {
                try self.simulateTick(true, .s3_streaming);
                self.frame_timer.recordCompletedTick();
            }
            switch (try self.render(self.frame_timer.alpha())) {
                .ready => {},
                .unavailable => continue,
            }
            const west = try self.district_streaming.slot(district_west_slot_index);
            switch (west.phase) {
                .active => if (try self.district_streaming.sceneResidency(
                    west.scene.?,
                ) == .resident) {
                    try self.validateS3Resident(west);
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
        return self.developer.snapshotWithAuthoring(
            self.developerAuthorityPort(),
            self.developerStreamingPort(),
            &self.frame_timer,
            self.includeDeveloperDistrictStreams(),
            if (self.latest_authoring_change) |change| change.record else null,
            self.developerEndpointDiscovery(),
        );
    }

    fn developerEndpointDiscovery(
        self: *const App,
    ) engine.developer_endpoint.Discovery {
        return .{
            .lifecycle = if (build_options.editor_enabled)
                .declared
            else
                .disabled,
            .run_id = self.authoring_run_id,
            .protocol_cohort = 1,
        };
    }

    fn includeDeveloperDistrictStreams(self: *const App) bool {
        return if (build_options.validation_mode or builtin.is_test)
            self.validation.profile == .sandbox or self.validation.profile == .s3_smoke
        else
            true;
    }

    fn applyDeveloperEffects(
        self: *App,
        effects: sandbox_developer_host.Effects,
    ) void {
        if (effects.reset_gameplay_actions) self.action_latch.clear();
        if (effects.toggle_neural_presentation) {
            if (self.neural_rendering) |*neural| _ = neural.toggle();
        }
    }

    fn developerAuthorityPort(self: *App) sandbox_developer_host.AuthorityPort {
        return .{
            .context = self,
            .simulation_diagnostics_fn = developerSimulationDiagnostics,
            .session_diagnostics_fn = developerSessionDiagnostics,
            .journal_fn = developerJournal,
            .record_fn = developerRecord,
            .arm_freeze_fn = developerArmFreeze,
            .disarm_freeze_fn = developerDisarmFreeze,
            .resume_capture_fn = developerResumeCapture,
            .clear_fn = developerClear,
            .gameplay_trace_fn = developerGameplayTrace,
            .freeze_gameplay_trace_fn = developerFreezeGameplayTrace,
            .resume_gameplay_trace_fn = developerResumeGameplayTrace,
            .clear_gameplay_trace_fn = developerClearGameplayTrace,
            .replay_snapshot_fn = developerReplaySnapshot,
            .extract_physics_debug_fn = developerExtractPhysicsDebug,
        };
    }

    fn developerSimulationDiagnostics(
        context: *anyopaque,
    ) sandbox_contracts.Diagnostics {
        const self: *App = @ptrCast(@alignCast(context));
        return self.simulation.developer().diagnostics();
    }

    fn developerSessionDiagnostics(
        context: *anyopaque,
    ) authority_diagnostics.Diagnostics {
        const self: *App = @ptrCast(@alignCast(context));
        return self.simulation.inspection().clientDiagnostics().authority;
    }

    fn developerJournal(
        context: *anyopaque,
    ) *const engine.runtime.DiagnosticJournal {
        const self: *App = @ptrCast(@alignCast(context));
        return self.simulation.developer().journal();
    }

    fn developerRecord(
        context: *anyopaque,
        entry: engine.runtime.DiagnosticEntry,
    ) engine.runtime.DiagnosticAppendResult {
        const self: *App = @ptrCast(@alignCast(context));
        return self.simulation.developer().record(entry);
    }

    fn developerArmFreeze(
        context: *anyopaque,
        condition: engine.runtime.DiagnosticFreezeMatch,
    ) void {
        const self: *App = @ptrCast(@alignCast(context));
        self.simulation.developer().armFreeze(condition);
    }

    fn developerDisarmFreeze(context: *anyopaque) bool {
        const self: *App = @ptrCast(@alignCast(context));
        return self.simulation.developer().disarmFreeze();
    }

    fn developerResumeCapture(context: *anyopaque) bool {
        const self: *App = @ptrCast(@alignCast(context));
        return self.simulation.developer().resumeCapture();
    }

    fn developerClear(context: *anyopaque) void {
        const self: *App = @ptrCast(@alignCast(context));
        self.simulation.developer().clear();
    }

    fn developerGameplayTrace(
        context: *anyopaque,
    ) engine.gameplay_trace.BorrowedView {
        const self: *App = @ptrCast(@alignCast(context));
        return self.simulation.developer().gameplayTrace().borrowedChronological();
    }

    fn developerFreezeGameplayTrace(context: *anyopaque) bool {
        const self: *App = @ptrCast(@alignCast(context));
        return self.simulation.developer().freezeGameplayTrace();
    }

    fn developerResumeGameplayTrace(context: *anyopaque) bool {
        const self: *App = @ptrCast(@alignCast(context));
        return self.simulation.developer().resumeGameplayTrace();
    }

    fn developerClearGameplayTrace(context: *anyopaque) void {
        const self: *App = @ptrCast(@alignCast(context));
        self.simulation.developer().clearGameplayTrace();
    }

    fn developerReplaySnapshot(
        context: *anyopaque,
        allocator: std.mem.Allocator,
    ) ![]u8 {
        const self: *App = @ptrCast(@alignCast(context));
        return self.simulation.developer().snapshotFlightRecording(allocator);
    }

    fn developerExtractPhysicsDebug(
        context: *anyopaque,
        config: engine.physics_debug.Config,
        storage: *engine.physics_debug.Storage,
    ) !engine.physics_debug.Batch {
        const self: *App = @ptrCast(@alignCast(context));
        return self.simulation.developer().extractPhysicsDebug(config, storage);
    }

    fn developerStreamingPort(
        self: *App,
    ) sandbox_developer_host.StreamingDiagnosticsPort {
        return .{
            .context = self,
            .worker_fn = developerStreamingWorker,
            .streams_fn = developerStreamingStreams,
            .gpu_fn = developerStreamingGpu,
        };
    }

    fn developerStreamingWorker(
        context: *anyopaque,
    ) ?developer_diagnostics.ContentWorker {
        const self: *App = @ptrCast(@alignCast(context));
        return self.district_streaming.workerDiagnostics();
    }

    fn developerStreamingStreams(
        context: *anyopaque,
    ) developer_diagnostics.DistrictStreams {
        const self: *App = @ptrCast(@alignCast(context));
        return self.district_streaming.developerStreams();
    }

    fn developerStreamingGpu(
        context: *anyopaque,
    ) !developer_diagnostics.Gpu {
        const self: *App = @ptrCast(@alignCast(context));
        return self.district_streaming.gpuDiagnostics();
    }

    fn applyDeveloperControlRequests(
        self: *App,
        requests: []const developer_controls.Request,
    ) void {
        self.applyDeveloperEffects(self.developer.applyControlRequests(
            self.developerAuthorityPort(),
            self.frame_timer.total_frames,
            requests,
        ));
    }

    fn applyDeveloperDiagnosticRequests(
        self: *App,
        requests: []const developer_diagnostics.Request,
    ) void {
        self.developer.applyDiagnosticRequests(
            self.developerAuthorityPort(),
            self.developerStreamingPort(),
            &self.frame_timer,
            self.includeDeveloperDistrictStreams(),
            self.latest_authoring_change,
            self.developerEndpointDiscovery(),
            requests,
        );
    }

    fn developerDiagnosticsJsonAlloc(
        self: *App,
        allocator: std.mem.Allocator,
    ) ![]u8 {
        return self.developer.diagnosticsJsonAlloc(
            allocator,
            self.developerAuthorityPort(),
            self.developerStreamingPort(),
            &self.frame_timer,
            self.includeDeveloperDistrictStreams(),
            self.latest_authoring_change,
            self.developerEndpointDiscovery(),
        );
    }

    fn captureFrameActions(self: *App) !void {
        var move = [2]f32{ 0, 0 };
        if (self.input_buffer.isKeyDown(input.Key.A)) move[0] -= 1;
        if (self.input_buffer.isKeyDown(input.Key.D)) move[0] += 1;
        if (self.input_buffer.isKeyDown(input.Key.S)) move[1] -= 1;
        if (self.input_buffer.isKeyDown(input.Key.W)) move[1] += 1;
        const looking = self.input_buffer.gameplayMouseLocked() or
            self.input_buffer.isMouseButtonDown(input.MouseButton.RIGHT);
        try self.action_latch.captureFrame(.{
            .move = move,
            .look_delta = if (looking)
                .{ self.input_buffer.mouse_delta_x, self.input_buffer.mouse_delta_y }
            else
                .{ 0, 0 },
            .jump_pressed = self.input_buffer.isKeyPressed(input.Key.SPACE),
            .interact_pressed = self.input_buffer.isKeyPressed(input.Key.E),
            .carry_pressed = self.input_buffer.isKeyPressed(input.Key.F),
            .melee_pressed = self.input_buffer.isKeyPressed(input.Key.Q),
            .weapon_toggle_pressed = self.input_buffer.isKeyPressed(input.Key.NUM_1),
            .fire_pressed = self.input_buffer.isMouseButtonPressed(input.MouseButton.LEFT),
            .reload_pressed = self.input_buffer.isKeyPressed(input.Key.R),
            .respawn_pressed = self.input_buffer.isKeyPressed(input.Key.R),
            .brake = self.input_buffer.isKeyDown(input.Key.SPACE),
            .hand_brake = self.input_buffer.isKeyDown(input.Key.LSHIFT),
            .reset = self.input_buffer.gameplayActionsMustReset(),
        });
    }

    fn districtAuthorityPort(self: *App) district_streaming_host.AuthorityPort {
        return .{
            .context = self,
            .submit_fn = districtSubmit,
            .poll_outcome_fn = districtPollOutcome,
            .poll_event_fn = districtPollEvent,
            .state_fn = districtState,
            .active_ticket_fn = districtActiveTicket,
            .presentation_fn = districtPresentation,
            .tick_index_fn = districtTickIndex,
            .record_fn = districtRecord,
        };
    }

    fn districtSubmit(context: *anyopaque, command: district_feature_contract.Command) !void {
        const self: *App = @ptrCast(@alignCast(context));
        try self.simulation.districts().submit(command);
    }

    fn districtPollOutcome(context: *anyopaque) ?district_feature_contract.Outcome {
        const self: *App = @ptrCast(@alignCast(context));
        return self.simulation.districts().pollOutcome();
    }

    fn districtPollEvent(context: *anyopaque) ?district_feature_contract.Event {
        const self: *App = @ptrCast(@alignCast(context));
        return self.simulation.districts().pollEvent();
    }

    fn districtState(
        context: *anyopaque,
        coord: district_contract.ChunkCoord,
    ) ?district_feature_contract.StateTag {
        const self: *App = @ptrCast(@alignCast(context));
        return self.simulation.districts().state(coord);
    }

    fn districtActiveTicket(
        context: *anyopaque,
        coord: district_contract.ChunkCoord,
    ) ?district_contract.LoadTicket {
        const self: *App = @ptrCast(@alignCast(context));
        return self.simulation.districts().activeTicket(coord);
    }

    fn districtPresentation(
        context: *anyopaque,
    ) ![]const district_feature_contract.DistrictDraw {
        const self: *App = @ptrCast(@alignCast(context));
        return self.simulation.districts().presentation();
    }

    fn districtTickIndex(context: *anyopaque) u64 {
        const self: *App = @ptrCast(@alignCast(context));
        return self.simulation.inspection().tickIndex();
    }

    fn districtRecord(
        context: *anyopaque,
        entry: engine.runtime.DiagnosticEntry,
    ) engine.runtime.DiagnosticAppendResult {
        const self: *App = @ptrCast(@alignCast(context));
        return self.simulation.developer().record(entry);
    }

    /// Client prediction is useful for hiding content latency, but it is never
    /// the source of truth for logical district ownership.
    fn districtPrefetchPosition(self: *App) !?[2]f32 {
        if (build_options.validation_mode or builtin.is_test) {
            if (self.validation.profile == .s3_smoke) {
                return self.district_prefetch_focus_override orelse
                    self.district_focus_override;
            }
            if (self.validation.profile != .sandbox) return null;
        }
        const position = self.simulation.player().focusPosition() orelse return null;
        return .{ position[0], position[2] };
    }

    /// Read the privileged copied authority value used to admit logical
    /// residency. This deliberately bypasses the predicted client projection
    /// without exposing character or vehicle feature views to the host.
    fn districtAuthorityFocusPosition(self: *App) !?[2]f32 {
        if (build_options.validation_mode or builtin.is_test) {
            if (self.validation.profile == .s3_smoke) return self.district_focus_override;
            if (self.validation.profile != .sandbox) return null;
        }
        const position = try self.simulation
            .residency()
            .authoritativeFocusPosition() orelse return null;
        return .{ position[0], position[2] };
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
                .s1_character => sandbox_controls.characterScenarioTick(
                    self.simulation.inspection().tickIndex() -|
                        self.validation_tick_origin,
                    s1_jump_tick,
                ),
                .s2_vehicle, .s3_streaming, .s8_population, .s4_physics_debug, .s13_population => sandbox_controls.idleTickSample(),
                .s7_interaction => blk: {
                    var result = sandbox_controls.idleTickSample();
                    result.move = self.validation.s7_scripted_move;
                    break :blk result;
                },
                .s11_combat => try self.s11ScriptedActions(),
                .s14_ranged_combat => try self.s14ScriptedActions(),
            }
        else
            self.action_latch.takeTick();
        self.game_camera.rotate(actions.look_delta[0], actions.look_delta[1]);

        if (validation_composition) {
            switch (scenario) {
                .none => try self.submitInteractiveActions(actions),
                .s1_character => if (self.initial_character_id != null) {
                    try self.submitCharacterActions(actions);
                },
                .s2_vehicle => try self.submitInteractiveActions(self.s2ScriptedActions()),
                .s3_streaming, .s8_population, .s4_physics_debug => {},
                .s7_interaction => if (self.validation.s7_character_actions_enabled) if (self.initial_character_id != null) {
                    try self.submitCharacterActions(actions);
                },
                .s11_combat => try self.submitInteractiveActions(actions),
                .s13_population => try self.submitInteractiveActions(actions),
                .s14_ranged_combat => try self.submitInteractiveActions(actions),
            }
        } else {
            try self.submitInteractiveActions(actions);
        }
        var runtime_profile = self.developer.runtimeProfile(
            self.frame_timer.total_frames,
        );
        try self.simulation.lifecycle().tickObserved(
            runtime_profile.observer(),
        );
        while (self.simulation.crates().pollOutcome()) |outcome| {
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
                    try self.recordAuthoringOutcome(pending.?, outcome, observed, null);
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
                    try self.recordAuthoringOutcome(
                        pending.?,
                        outcome,
                        observed,
                        rejected.reason,
                    );
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
        while (self.simulation.characters().pollOutcome()) |outcome| {
            if (!validation_composition) {
                switch (outcome) {
                    .spawned => |spawned| {
                        const projected = self.simulation.inspection().replicatedId(
                            spawned.id,
                        ) orelse return error.ProductCharacterProjectionMissing;
                        try self.product_character_lifecycle.observeSpawn(
                            &self.initial_character_id,
                            spawned,
                            self.simulation.presentation().combatHud(),
                            projected,
                        );
                    },
                    .despawned => |id| try self.product_character_lifecycle.observeDespawn(
                        &self.initial_character_id,
                        id,
                        self.simulation.presentation().combatHud(),
                    ),
                    .rejected => return error.UnexpectedProductCharacterCommandRejection,
                }
                continue;
            }
            switch (outcome) {
                .spawned => |spawned| {
                    const s11_respawn = scenario == .s11_combat and
                        self.initial_character_id == null;
                    if ((!s11_respawn and spawned.request_id != 1) or
                        self.initial_character_id != null)
                    {
                        return error.UnexpectedCharacterBootstrapOutcome;
                    }
                    self.initial_character_id = spawned.id;
                },
                .despawned => |id| if ((scenario == .s7_interaction or
                    scenario == .s8_population or
                    scenario == .s11_combat or scenario == .s13_population or
                    scenario == .s14_ranged_combat) and
                    std.meta.eql(id, self.initial_character_id orelse
                        return error.UnexpectedCharacterBootstrapOutcome))
                {
                    self.initial_character_id = null;
                } else return error.UnexpectedCharacterBootstrapOutcome,
                .rejected => return error.UnexpectedCharacterBootstrapOutcome,
            }
        }
        while (self.simulation.characters().pollEvent()) |_| {}
        try self.processVehicleOutcomes(validation_composition, scenario);
        while (self.simulation.vehicles().pollEvent()) |_| {}
        try self.district_streaming.processOutcomes(self.districtAuthorityPort(), self.frame_timer.total_frames);
        try self.processInteractionOutcomes(validation_composition, scenario);
        if (!validation_composition or scenario == .s11_combat or
            scenario == .s13_population or scenario == .s14_ranged_combat)
        {
            try self.processNpcDeveloperObservations();
        }
        try self.processPlayerActionResults(validation_composition, scenario);
        try self.maybeBootstrapCarryable(validation_composition, scenario);
        if (try self.districtPrefetchPosition()) |position_xz| {
            try self.district_streaming.updatePrefetch(
                self.districtAuthorityPort(),
                self.frame_timer.total_frames,
                position_xz,
            );
        }
        if (try self.districtAuthorityFocusPosition()) |position_xz| {
            try self.district_streaming.updateAuthorityResidency(
                self.districtAuthorityPort(),
                self.frame_timer.total_frames,
                position_xz,
            );
        }
        if (validation_composition and scenario == .s2_vehicle) try self.observeS2State();
        try self.pumpPersistenceCommit();
        self.extractPhysicsDebug();
    }

    fn authoringCrateView(
        self: *App,
        id: sandbox_contracts.PersistentId,
    ) !?editor_contract.AuthoringCrateView {
        const view = self.simulation.crates().view(id) catch |err| switch (err) {
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
            .save = self.editorSaveFeedback(),
            .latest_change = self.latest_authoring_change,
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
        if (self.simulation.developer().firstFault() != null) return result;
        if (self.initial_character_id) |id| {
            result.carrier = self.simulation.characters().view(id) catch |err| switch (err) {
                error.CharacterNotFound, error.NotACharacter => null,
                else => return err,
            };
        }
        if (self.initial_carryable_id) |id| {
            result.carryable = self.simulation.interactions().view(id) catch |err| switch (err) {
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
        const Values = struct {
            transaction_id: u64,
            carrier_id: sandbox_contracts.PersistentId,
            carryable_id: sandbox_contracts.PersistentId,
            action: sandbox_host.InteractionActionKind,
        };
        for (requests) |request| {
            const values: Values = switch (request) {
                .collect => |value| .{
                    .transaction_id = value.transaction_id,
                    .carrier_id = value.carrier_id,
                    .carryable_id = value.carryable_id,
                    .action = sandbox_host.InteractionActionKind.collect,
                },
                .drop => |value| .{
                    .transaction_id = value.transaction_id,
                    .carrier_id = value.carrier_id,
                    .carryable_id = value.carryable_id,
                    .action = sandbox_host.InteractionActionKind.drop,
                },
                .spawn, .despawn => {
                    self.interaction_submission_failures +|= 1;
                    continue;
                },
            };
            const expected = self.interaction_transactions.peek() orelse {
                self.interaction_submission_failures +|= 1;
                continue;
            };
            if (values.transaction_id != expected or
                !std.meta.eql(values.carrier_id, self.initial_character_id orelse {
                    self.interaction_submission_failures +|= 1;
                    continue;
                }))
            {
                self.interaction_submission_failures +|= 1;
                continue;
            }
            const carryable = self.simulation.inspection().replicatedId(
                values.carryable_id,
            ) orelse {
                self.interaction_submission_failures +|= 1;
                continue;
            };
            _ = try self.interaction_transactions.take();
            self.simulation.player().requestInteraction(
                values.action,
                carryable,
            ) catch |err| {
                self.interaction_submission_failures +|= 1;
                return err;
            };
        }
    }

    fn applyNavigationRequests(
        self: *App,
        requests: []const editor_contract.NavigationRequest,
    ) !void {
        for (requests) |request| switch (request) {
            .set_destination => |set| {
                const request_id = self.navigation_next_request_id;
                try self.simulation.npcs().submit(.{ .set_goal = .{
                    .request_id = request_id,
                    .id = set.npc,
                    .goal = .{ .navigate_to = set.destination },
                } });
                self.navigation_next_request_id +|= 1;
            },
            .set_gate => |command| {
                _ = try self.simulation.developer().submitNavigationGate(command);
            },
        };
    }

    fn advanceAuthoringFeedback(self: *App) u64 {
        self.authoring_feedback.sequence +|= 1;
        return self.authoring_feedback.sequence;
    }

    fn recordAuthoringOutcome(
        self: *App,
        pending: sandbox_authoring.PendingSummary,
        outcome: sandbox_authoring.CrateOutcome,
        observed: sandbox_authoring.ObserveResult,
        rejection_reason: ?sandbox_contracts.RejectionReason,
    ) !void {
        self.latest_authoring_change = try sandbox_authoring.ChangeEvidence.init(
            pending,
            outcome,
            self.authoringObservationContext(),
        );
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
        id: ?sandbox_contracts.PersistentId,
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
        command: sandbox_contracts.Command,
        operation: sandbox_authoring.OperationKind,
    ) !void {
        self.simulation.crates().submit(command) catch |err| {
            const relocation = command.relocate;
            const pending = self.authoring_controller.snapshot().pending orelse
                return error.AuthoringPendingEvidenceMissing;
            _ = self.authoring_controller.submissionFailed(relocation.transaction_id);
            self.latest_authoring_change =
                try sandbox_authoring.ChangeEvidence.rejectedBeforeOwnerOutcome(
                    pending,
                    .owner_unavailable,
                    self.authoringObservationContext(),
                );
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

    fn authoringObservationContext(
        self: *const App,
    ) sandbox_authoring.ObservationContext {
        return .{
            .run_id = self.authoring_run_id,
            .wall_unix_ms = authoringWallNowMs(self.io),
            .authority_tick = self.simulation.inspection().tickIndex(),
            .presentation_frame = self.frame_timer.total_frames,
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
                const view = self.simulation.crates().view(relocation.id) catch |err| switch (err) {
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
            .save => try self.requestPersistenceCommit(),
        };
    }

    fn editorSaveFeedback(self: *const App) editor_contract.SaveFeedback {
        const feedback = self.persistence.feedback();
        return .{
            .sequence = feedback.sequence,
            .status = switch (feedback.status) {
                .unavailable => .unavailable,
                .idle => .idle,
                .committed => .committed,
                .committed_sync_warning => .committed_sync_warning,
                .not_committed => .not_committed,
            },
            .slot_label = feedback.slot,
            .detail = feedback.detail,
        };
    }

    fn observePersistenceSnapshot(
        self: *App,
    ) !sandbox_persistence.SnapshotObservation {
        return switch (try self.persistence.apply(
            self.io,
            .observe_snapshot,
        )) {
            .observed => |observation| observation,
            .commit => unreachable,
        };
    }

    /// Reach a bounded authority safe point before a validation-only
    /// diagnostic observation. Application snapshots remain strict: callers
    /// never receive a view while ingress, delivery acknowledgements, or
    /// authority outputs are pending.
    fn settlePersistenceObservation(
        self: *App,
    ) !sandbox_persistence.SnapshotObservation {
        for (0..session_budgets.ticks_per_snapshot + 2) |_| {
            return self.observePersistenceSnapshot() catch |err| switch (err) {
                error.SessionWorkPending,
                error.AuthorityOutputsPending,
                error.CommandsPending,
                => {
                    try self.simulateTick(true, .none);
                    continue;
                },
                else => return err,
            };
        }
        return error.PersistenceObservationDidNotQuiesce;
    }

    fn requestPersistenceCommit(self: *App) !void {
        self.persistence_commit_pending = true;
        try self.pumpPersistenceCommit();
    }

    fn pumpPersistenceCommit(self: *App) !void {
        if (!self.persistence_commit_pending) return;
        const result = switch (try self.persistence.apply(
            self.io,
            .{ .commit = .{
                .authoring_transaction_pending = self.authoring_controller.snapshot().pending != null,
            } },
        )) {
            .commit => |result| result,
            .observed => unreachable,
        };
        self.persistence_commit_pending = result == .deferred_capture_pending;
    }

    fn extractPhysicsDebug(self: *App) void {
        const batch = self.developer.extractPhysicsDebug(
            self.developerAuthorityPort(),
            self.frame_timer.total_frames,
            self.simulation.inspection().tickIndex(),
        ) orelse return;
        if (build_options.validation_mode or builtin.is_test) {
            self.validation.s4_physics_debug_evidence.observe(batch);
        }
    }

    fn drawPhysicsDebug(self: *App, view_projection: zm.Mat) void {
        self.developer.drawPhysicsDebug(
            &self.gpu_renderer,
            view_projection,
            self.frame_timer.total_frames,
        );
    }

    /// Submit one renderer frame, then let the developer owner acquire the
    /// optional same-queue fence needed by its retained debug geometry.
    fn submitCurrentFrame(self: *App) !void {
        self.developer.prepareIncidentFrame(
            &self.gpu_renderer,
            self.simulation.inspection().tickIndex(),
            self.frame_timer.total_frames,
        );
        self.developer.requestFrameSubmissionFence(&self.gpu_renderer);
        try self.gpu_renderer.submitFrame();
        self.developer.afterSuccessfulFrameSubmission(&self.gpu_renderer);
        if (self.neural_capture) |*capture| {
            if (capture.wantsFrame(self.frame_timer.total_frames)) {
                const inputs = &self.neural_inputs.?;
                try capture.record(inputs);
            }
        }
        if (self.neural_target_frames) |*target_frames| {
            if (target_frames.wantsFrame(self.frame_timer.total_frames)) {
                const forward = self.game_camera.getForward();
                const up = camera.Camera.getUp();
                const target_state = neural_target_fixture.sequenceStateFor(
                    self.neural_target_fixture_variant,
                    self.neuralTargetFixtureFrame(),
                );
                try target_frames.record(&self.neural_inputs.?, .{
                    .position = .{
                        self.game_camera.position[0],
                        self.game_camera.position[1],
                        self.game_camera.position[2],
                    },
                    .forward = .{ forward[0], forward[1], forward[2] },
                    .up = .{ up[0], up[1], up[2] },
                    .vertical_fov_radians = self.game_camera.fov,
                }, target_state.scene, target_state.event);
            }
        }
        if (self.neural_rendering) |*neural| {
            neural.readbackAndPredict(&self.neural_inputs.?);
            const diagnostics = neural.diagnostics();
            self.developer.recordNeuralRendering(.{
                .enabled = diagnostics.enabled,
                .output_ready = diagnostics.output_ready,
                .manifest_digest = diagnostics.manifest_digest[0..],
                .checkpoint_digest = diagnostics.checkpoint_digest,
                .source_tick = diagnostics.last_source_tick,
                .source_frame = diagnostics.last_source_frame,
                .presented_source_frame = diagnostics.last_presented_source_frame,
                .readbacks = diagnostics.readbacks,
                .predictions = diagnostics.predictions,
                .failures = diagnostics.failures,
                .inference_ms = diagnostics.last_inference_ms,
                .pipeline_mean_ms = diagnostics.mean_staged_pipeline_ms,
                .pipeline_maximum_ms = diagnostics.maximum_staged_pipeline_ms,
                .unknown_semantic_pixels = diagnostics.last_unknown_semantic_pixels,
                .unknown_instance_pixels = diagnostics.last_unknown_instance_pixels,
            });
        }
    }

    /// Capture only semantic S11 checkpoints. The serial readback is kept out
    /// of the normal product and ordinary validation frames; each declared
    /// entity must occupy at least one depth-tested Metal pixel at the exact
    /// contact/death/respawn presentation state.
    fn captureS11Visibility(
        self: *App,
        character_draws: []const sandbox_host.CharacterDraw,
        npc_draws: []const sandbox_host.NpcDraw,
        view_projection: zm.Mat,
    ) !void {
        if (!build_options.validation_mode) return;
        const progress = &self.validation.s11_combat;
        if (!progress.active) return;

        var local_character: ?sandbox_host.CharacterDraw = null;
        var dead_local_character: ?sandbox_host.CharacterDraw = null;
        for (character_draws) |draw| {
            if (draw.local_player and draw.life_state == .alive) {
                local_character = draw;
            } else if (draw.local_player and draw.life_state == .dead) {
                dead_local_character = draw;
            }
        }
        var living_npc: ?sandbox_host.NpcDraw = null;
        var dead_npc: ?sandbox_host.NpcDraw = null;
        for (npc_draws) |draw| {
            if (draw.life_state == .alive and living_npc == null) living_npc = draw;
            if (draw.life_state == .dead and dead_npc == null) dead_npc = draw;
        }

        const checkpoint: S11VisibilityCheckpoint = if (!progress.visibility_contact and
            local_character != null and living_npc != null and
            living_npc.?.combat.windup)
            .contact
        else if (!progress.visibility_player_death and progress.player_dead and
            dead_local_character != null)
            .player_death
        else if (!progress.visibility_npc_death and dead_npc != null)
            .npc_death
        else if (!progress.visibility_respawn and progress.respawned_character_drawn and
            local_character != null and living_npc != null)
            .respawn
        else
            return;

        const selected_npc: ?sandbox_host.NpcDraw = switch (checkpoint) {
            .contact => living_npc.?,
            .npc_death => dead_npc.?,
            .player_death, .respawn => null,
        };
        var draws: [2]visibility_oracle.Draw = undefined;
        var entities: [2]?engine.gameplay_trace.EntityRef = @splat(null);
        var count: usize = 0;
        const selected_character: ?sandbox_host.CharacterDraw = if (checkpoint == .player_death)
            dead_local_character.?
        else
            local_character;
        if (selected_character) |character| {
            const rotation = zm.quatToMat(zm.f32x4(
                character.pose.rotation[0],
                character.pose.rotation[1],
                character.pose.rotation[2],
                character.pose.rotation[3],
            ));
            const translation = zm.translation(
                character.pose.position[0],
                character.pose.position[1],
                character.pose.position[2],
            );
            draws[count] = .{
                .object_id = 1,
                .mesh = try self.visuals.resolve(character.mesh, character.material),
                .model = zm.mul(rotation, translation),
                .view_projection = view_projection,
                .display_color = character.combat.body_color,
            };
            entities[count] = gameplayEntityRef(character.entity, character.incarnation);
            count += 1;
        }
        // Contact declares both actors. Death and respawn checkpoints declare
        // the entity whose semantic state changed, so unrelated projection
        // timing cannot suppress a short-lived but valid visual proof.
        if (selected_npc) |npc| {
            const npc_rotation = zm.quatToMat(zm.f32x4(
                npc.pose.rotation[0],
                npc.pose.rotation[1],
                npc.pose.rotation[2],
                npc.pose.rotation[3],
            ));
            const npc_translation = zm.translation(
                npc.pose.position[0],
                npc.pose.position[1],
                npc.pose.position[2],
            );
            draws[count] = .{
                .object_id = 2,
                .mesh = try self.visuals.resolve(npc.mesh, npc.material),
                .model = zm.mul(npc_rotation, npc_translation),
                .view_projection = view_projection,
                .display_color = npc.combat.entity.body_color,
            };
            entities[count] = gameplayEntityRef(npc.entity, npc.incarnation);
            count += 1;
        }

        const owner = if (self.visibility_oracle) |*value| value else return error.S11VisibilityOracleUnavailable;
        const capture = owner.capture(
            self.io,
            "hostile_npc_approach_contact_death_respawn",
            checkpoint.label(),
            self.simulation.inspection().tickIndex(),
            self.frame_timer.total_frames,
            draws[0..count],
        ) catch |err| {
            const failed_id = owner.last_failed_object_id;
            var failed_entity: ?engine.gameplay_trace.EntityRef = null;
            if (failed_id) |id| {
                for (draws[0..count], 0..) |draw, index| {
                    if (draw.object_id == id) failed_entity = entities[index];
                }
            }
            _ = self.simulation.developer().recordGameplayTrace(.{
                .authority_tick = self.simulation.inspection().tickIndex(),
                .presentation_frame = self.frame_timer.total_frames,
                .actor = failed_entity,
                .source = .visibility_oracle,
                .stage = .visibility_observed,
                .kind = .visibility,
                .disposition = .invisible,
                .reason_domain = .error_code,
                .reason = @intFromError(err),
                .fields = .{ .visibility = true },
            });
            _ = self.simulation.developer().freezeGameplayTrace();
            return err;
        };
        for (capture.slice(), 0..) |observation, index| {
            const bounds = observation.bounds orelse {
                progress.visibility_bounds_valid = false;
                return error.S11VisibilityBoundsMissing;
            };
            if (bounds.min_x > bounds.max_x or bounds.min_y > bounds.max_y or
                bounds.max_x >= visibility_oracle.width or
                bounds.max_y >= visibility_oracle.height)
            {
                progress.visibility_bounds_valid = false;
                return error.S11VisibilityBoundsInvalid;
            }
            if (checkpoint == .player_death and index == 0 and
                observation.pixel_count < visibility_oracle.minimum_meaningful_pixels)
            {
                progress.visibility_bounds_valid = false;
                return error.S11PlayerDeathPresentationTooOccluded;
            }
            progress.visibility_observations +|= 1;
            _ = self.simulation.developer().recordGameplayTrace(.{
                .authority_tick = self.simulation.inspection().tickIndex(),
                .presentation_frame = self.frame_timer.total_frames,
                .actor = entities[index],
                .source = .visibility_oracle,
                .stage = .visibility_observed,
                .kind = .visibility,
                .disposition = .visible,
                .fields = .{ .visibility = true },
                .visible_pixels = observation.pixel_count,
            });
        }
        switch (checkpoint) {
            .contact => progress.visibility_contact = true,
            .player_death => progress.visibility_player_death = true,
            .respawn => progress.visibility_respawn = true,
            .npc_death => progress.visibility_npc_death = true,
        }
    }

    fn noteHostActionRejection(
        self: *App,
        tick: u64,
        kind: engine.gameplay_trace.Kind,
        err: anyerror,
    ) void {
        self.product_feedback.noteRejected(tick, kind, err);
        const hud = self.simulation.presentation().combatHud();
        _ = self.simulation.developer().recordGameplayTrace(.{
            .authority_tick = tick,
            .presentation_frame = self.frame_timer.total_frames,
            .actor = if (hud.avatar.isValid())
                gameplayEntityRef(hud.avatar, hud.incarnation)
            else
                null,
            .source = .input,
            .stage = .local_preflight,
            .kind = kind,
            .disposition = .rejected,
            .reason_domain = .error_code,
            .reason = @intFromError(err),
        });
    }

    fn submitInteractiveActions(
        self: *App,
        actions: sandbox_controls.TickSample,
    ) !void {
        const tick = self.simulation.inspection().tickIndex();
        const hud = self.simulation.presentation().combatHud();
        if (actions.respawn_pressed and hud.life_state == .dead) {
            self.simulation.player().requestRespawn() catch |err| {
                if (!sandbox_controls.isRecoverableSubmissionError(.respawn, err)) return err;
                self.product_feedback.noteRejected(tick, .respawn, err);
                return;
            };
            self.product_feedback.noteSubmitted(tick, .respawn);
            return;
        }
        const weapon_action: ?sandbox_host.WeaponActionKind = if (actions.weapon_toggle_pressed)
            .equip_toggle
        else if (actions.reload_pressed)
            .reload
        else if (actions.fire_pressed)
            .fire
        else
            null;
        if (weapon_action) |action| {
            self.simulation.player().requestWeapon(action) catch |err| {
                if (!sandbox_controls.isRecoverableSubmissionError(.weapon, err)) return err;
                self.product_feedback.noteRejected(tick, .firearm, err);
                return;
            };
            self.product_feedback.noteSubmitted(tick, .firearm);
            return;
        }
        if (actions.melee_pressed) {
            if (self.controlled_vehicle_id == null) {
                self.simulation.player().requestMelee() catch |err| {
                    if (!sandbox_controls.isRecoverableSubmissionError(.melee, err)) return err;
                    self.product_feedback.noteRejected(tick, .melee, err);
                    return;
                };
                self.product_feedback.noteSubmitted(tick, .melee);
            } else {
                self.noteHostActionRejection(
                    tick,
                    .melee,
                    error.CannotMeleeWhileDriving,
                );
            }
            return;
        }
        if (actions.carry_pressed) {
            try self.submitInteractionToggle();
            return;
        }
        if (actions.interact_pressed) {
            if (self.simulation.player().focusPosition() == null) {
                self.noteHostActionRejection(
                    tick,
                    .vehicle_toggle,
                    error.LocalCharacterUnavailable,
                );
                return;
            }
            self.simulation.player().requestVehicleToggle() catch |err| {
                if (!sandbox_controls.isRecoverableSubmissionError(.vehicle_toggle, err)) return err;
                self.product_feedback.noteRejected(tick, .vehicle_toggle, err);
                return;
            };
            self.product_feedback.noteSubmitted(tick, .vehicle_toggle);
            // Authority transitions consume the tick without applying the same
            // frame sample to either locomotion target.
            return;
        }

        if (self.controlled_vehicle_id != null) {
            const control = sandbox_host.VehicleInput{
                .throttle = actions.move[1],
                .steering = actions.move[0],
                .brake = if (actions.brake) 1 else 0,
                .hand_brake = if (actions.hand_brake) 1 else 0,
            };
            const sequence = self.simulation.player().submitVehicleControl(control) catch |err| {
                if (sandbox_controls.isRecoverableSubmissionError(.vehicle_control, err)) return;
                return err;
            };
            if (comptime build_options.validation_mode or builtin.is_test) {
                if (self.validation.s2_smoke.drive_input_sequence == null) {
                    self.validation.s2_smoke.drive_input_sequence = sequence;
                }
                if (@abs(control.steering) > 0.1 and
                    self.validation.s2_smoke.steering_input_sequence == null)
                {
                    self.validation.s2_smoke.steering_input_sequence = sequence;
                }
                if (control.brake > 0.5 and
                    self.validation.s2_smoke.brake_input_sequence == null)
                {
                    self.validation.s2_smoke.brake_input_sequence = sequence;
                }
                if (control.hand_brake > 0.5 and
                    self.validation.s2_smoke.hand_brake_input_sequence == null)
                {
                    self.validation.s2_smoke.hand_brake_input_sequence = sequence;
                }
            }
        } else if (self.simulation.player().focusPosition() != null) {
            self.submitCharacterActions(actions) catch |err| {
                if (!sandbox_controls.isRecoverableSubmissionError(.character_control, err)) return err;
            };
        }
    }

    fn submitInteractionToggle(self: *App) !void {
        const tick = self.simulation.inspection().tickIndex();
        if (self.controlled_vehicle_id != null) {
            self.noteHostActionRejection(
                tick,
                .carry_toggle,
                error.CannotCarryWhileDriving,
            );
            return;
        }
        if (self.simulation.player().focusPosition() == null) {
            self.noteHostActionRejection(
                tick,
                .carry_toggle,
                error.LocalCharacterUnavailable,
            );
            return;
        }
        self.simulation.player().requestInteractionToggle() catch |err| {
            self.interaction_submission_failures +|= 1;
            if (!sandbox_controls.isRecoverableSubmissionError(.carry_toggle, err)) return err;
            self.product_feedback.noteRejected(tick, .carry_toggle, err);
            return;
        };
        self.product_feedback.noteSubmitted(tick, .carry_toggle);
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
                .none, .s7_interaction, .s13_population => {},
                else => return,
            }
        }
        if (self.simulation.districts().activeTicket(district_west_coord) == null) return;
        try self.simulation.interactions().submit(.{ .spawn = .{
            .request_id = 1,
            .pose = .{ .position = if (validation_composition and
                scenario == .s7_interaction)
                .{ 1, 0.5, 0 }
            else
                sandbox_contracts.default_carryable_spawn_position },
        } });
        self.interaction_spawn_submitted = true;
    }

    fn processInteractionOutcomes(
        self: *App,
        comptime validation_composition: bool,
        scenario: ScriptedScenario,
    ) !void {
        while (self.simulation.interactions().pollOutcome()) |outcome| {
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
                .rejected => if (validation_composition and
                    scenario == .s7_interaction)
                {
                    return error.S7InteractionCommandRejected;
                },
            }
        }
        // Raw feature observations are retained solely for developer tooling;
        // product state changes consume the correlated PlayerRole result.
        self.interaction_last_outcome =
            self.simulation.developer().lastInteractionObservation();
    }

    fn bootstrapS7Interaction(self: *App) !void {
        if (self.validation.profile != .s3_smoke or self.simulation.inspection().entityCount() != 0) {
            return error.InvalidS7InteractionSmokeComposition;
        }
        try self.simulation.characters().submit(.{ .spawn = .{
            .request_id = 1,
            .position = .{ 0, 0, 0 },
        } });
        self.interaction_spawn_enabled = true;
        self.district_focus_override = s6_west_only;
    }

    fn processNpcDeveloperObservations(self: *App) !void {
        while (self.simulation.npcs().pollOutcome()) |_| {}
        while (self.simulation.npcs().pollEvent()) |_| {}
        self.recordNpcNavigationTransitions();
        self.recordPopulationTransitions();
    }

    fn recordNpcNavigationTransitions(self: *App) void {
        while (self.simulation.npcs().pollNavigationTransition()) |transition| {
            var navigation_evidence = engine.gameplay_trace.NavigationEvidence{
                .destination_id = if (transition.destination) |destination|
                    destination.value
                else
                    null,
                .route_revision = transition.route_revision,
                .topology_revision = transition.topology_revision,
                .route_digest = transition.route.digest,
                .route_cost = transition.route.total_cost,
                .route_length = transition.route.len,
                .active_prefix_length = transition.route.active_prefix_len,
                .route_index = transition.route_index,
            };
            for (transition.route.slice(), 0..) |node, index| {
                navigation_evidence.nodes[index] = .{
                    .district_x = node.coord.x,
                    .district_z = node.coord.z,
                    .index = node.index,
                };
            }
            _ = self.simulation.developer().recordGameplayTrace(.{
                .authority_tick = transition.tick,
                .presentation_frame = self.frame_timer.total_frames,
                .topology_id = transition.topology_revision,
                .correlation_id = transition.route_revision,
                .actor = .{
                    .namespace = transition.id.namespace,
                    .local = transition.id.local,
                },
                .source = .simulation,
                .stage = .simulation_outcome,
                .kind = .navigation,
                .disposition = .emitted,
                .reason_domain = .navigation_reason,
                .reason = @intFromEnum(transition.reason),
                .fields = .{ .position = true, .state = true },
                .position = transition.position,
                .state = @intFromEnum(transition.kind),
                .navigation = navigation_evidence,
            });
        }
    }

    fn recordPopulationTransitions(self: *App) void {
        while (self.simulation.npcs().pollPopulationTransition()) |transition| {
            const definition = population_catalog.memberDefinition(
                transition.member,
            ) orelse continue;
            _ = self.simulation.developer().recordGameplayTrace(.{
                .authority_tick = transition.tick,
                .presentation_frame = self.frame_timer.total_frames,
                .correlation_id = transition.activity_sequence,
                .actor = if (transition.actor) |actor| .{
                    .namespace = actor.namespace,
                    .local = actor.local,
                    .incarnation = transition.actor_generation,
                } else null,
                .source = .simulation,
                .stage = .simulation_outcome,
                .kind = .population,
                .disposition = switch (transition.reason) {
                    .spawn_deferred, .destination_deferred, .slot_unavailable => .rejected,
                    .spawn_requested, .slot_claimed => .emitted,
                    else => .applied,
                },
                .reason_domain = .population_transition,
                .reason = @intFromEnum(transition.reason),
                .fields = .{
                    .state = true,
                    .deadline = transition.deadline_tick != 0,
                },
                .state = @intFromEnum(transition.current_state),
                .deadline_tick = transition.deadline_tick,
                .population = .{
                    .member_id = transition.member.value,
                    .actor_generation = transition.actor_generation,
                    .role = @intFromEnum(definition.role),
                    .combat_disposition = @intFromEnum(
                        definition.combat_disposition,
                    ),
                    .activity_program = transition.program.value,
                    .activity_sequence = transition.activity_sequence,
                    .activity_kind = @intFromEnum(transition.activity_kind),
                    .previous_state = @intFromEnum(transition.previous_state),
                    .current_state = @intFromEnum(transition.current_state),
                    .transition_reason = @intFromEnum(transition.reason),
                    .activity_site = if (transition.site) |site| site.value else null,
                    .activity_slot = if (transition.slot) |slot| slot.value else null,
                    .deadline_tick = transition.deadline_tick,
                    .retry_reason = @intFromEnum(transition.retry_reason),
                },
            });
        }
    }

    fn submitCharacterActions(
        self: *App,
        actions: sandbox_controls.TickSample,
    ) !void {
        try self.simulation.player().submitMovement(.{
            .move = sandbox_controls.normalizedCharacterMove(actions.move),
            .facing_yaw = self.game_camera.yaw,
            .jump_pressed = actions.jump_pressed,
        });
    }

    fn s2ScriptedActions(self: *const App) sandbox_controls.TickSample {
        const tick = self.simulation.inspection().tickIndex() -|
            self.validation_tick_origin;
        return sandbox_controls.vehicleScenarioTick(tick, .{
            .enter_tick = s2_enter_tick,
            .hand_brake_tick = s2_hand_brake_tick,
            .brake_tick = s2_brake_tick,
            .steer_tick = s2_steer_tick,
            .exit_tick = s2_exit_tick,
        });
    }

    fn s11ScriptedActions(self: *App) !sandbox_controls.TickSample {
        var actions = sandbox_controls.idleTickSample();
        const progress = &self.validation.s11_combat;
        if (!progress.target_selected) {
            if (self.initial_character_id != null) {
                for (self.simulation.inspection().populationMembers()) |member| {
                    if (!population.PopulationMemberId.eql(
                        member.id,
                        s11_hostile_population_member,
                    )) continue;
                    progress.npc_id = member.actor orelse return actions;
                    progress.target_selected = true;
                    break;
                }
            }
            return actions;
        }

        const hud = self.simulation.presentation().combatHud();
        if (!hud.available) return actions;
        const tick = hud.authority_tick;
        if (hud.life_state == .dead) {
            if (progress.respawn_ready_marker_drawn and
                hud.respawn_marker == .ready and
                tick >= progress.last_respawn_request_tick +| 5)
            {
                actions.respawn_pressed = true;
                progress.last_respawn_request_tick = tick;
            }
            return actions;
        }

        if (progress.npc_killed) return actions;
        const npc = try self.simulation.npcs().view(
            progress.npc_id orelse return actions,
        );
        const source = self.simulation.player().focusPosition() orelse {
            if (progress.player_respawned) progress.post_respawn_source_missing +|= 1;
            return actions;
        };
        // Validation control follows authority state so render cadence cannot
        // alter its inputs. Presentation remains independently asserted by the
        // health/death plans and Metal visibility oracle below.
        const delta_x = npc.position[0] - source[0];
        const delta_z = npc.position[2] - source[2];
        const distance_squared = delta_x * delta_x + delta_z * delta_z;
        if (progress.player_respawned) {
            if (progress.post_respawn_source_samples == 0) {
                progress.first_source_position = source;
                progress.first_npc_position = npc.position;
            }
            progress.post_respawn_source_samples +|= 1;
            progress.last_source_position = source;
            progress.last_npc_position = npc.position;
            progress.last_target_distance_squared = distance_squared;
        }
        self.game_camera.yaw = std.math.atan2(delta_x, -delta_z);

        const should_engage = !progress.provocation_hit or progress.player_respawned;
        if (!should_engage) return actions;
        if (distance_squared > 2.4 * 2.4) {
            actions.move = .{ 0, 1 };
            if (progress.player_respawned) progress.post_respawn_move_samples +|= 1;
        } else if (hud.melee_remaining_ticks == 0 and
            tick >= progress.last_melee_request_tick +| 5)
        {
            actions.melee_pressed = true;
            progress.last_melee_request_tick = tick;
        }
        return actions;
    }

    fn s14ScriptedActions(self: *App) !sandbox_controls.TickSample {
        var actions = sandbox_controls.idleTickSample();
        const progress = &self.validation.s14_ranged_combat;
        const hud = self.simulation.presentation().combatHud();
        if (!hud.available or hud.life_state != .alive) return actions;
        const tick = hud.authority_tick;

        if (hud.weapon_mode == .holstered) {
            actions.weapon_toggle_pressed = true;
            return actions;
        }

        if (progress.committed_drain_shots < 12) {
            const source = self.simulation.player().focusPosition() orelse return actions;
            self.game_camera.yaw = try self.s14ClearRayYaw(source);
            const cadence_probe = progress.committed_drain_shots == 1 and
                !progress.cadence_rejected;
            if ((cadence_probe or hud.weapon_remaining_ticks == 0) and
                tick > progress.last_fire_request_tick)
            {
                actions.fire_pressed = true;
                progress.last_fire_request_tick = tick;
            }
            return actions;
        }

        if (!progress.empty_rejected) {
            if (tick > progress.last_empty_request_tick) {
                actions.fire_pressed = true;
                progress.last_empty_request_tick = tick;
            }
            return actions;
        }
        if (!progress.reload_started) {
            actions.reload_pressed = true;
            return actions;
        }
        if (!progress.reload_completed) return actions;

        if (!progress.target_selected) {
            for (self.simulation.inspection().populationMembers()) |member| {
                const definition = population_catalog.memberDefinition(member.id) orelse continue;
                if (definition.combat_disposition != .passive or member.actor == null) continue;
                const actor = member.actor.?;
                const entity = self.simulation.inspection().replicatedId(actor) orelse continue;
                progress.target_member = member.id.value;
                progress.target_actor = actor;
                progress.target_entity = entity;
                progress.target_generation = member.actor_generation;
                progress.target_selected = true;
                break;
            }
            return actions;
        }
        if (progress.target_killed) {
            // Replacement admission suppresses visible pop-in near the player.
            // Move to this target's validated observation point so the proof
            // observes the complete death and replacement lifecycle instead
            // of idling on the defeated actor.
            if (self.simulation.player().focusPosition()) |position| {
                const safe = [2]f32{ 1, -4 };
                const delta = [2]f32{
                    safe[0] - position[0],
                    safe[1] - position[2],
                };
                const distance_squared = delta[0] * delta[0] + delta[1] * delta[1];
                if (distance_squared > 1) {
                    const inverse = 1.0 / @sqrt(distance_squared);
                    const world_x = delta[0] * inverse;
                    const world_z = delta[1] * inverse;
                    const sine = @sin(self.game_camera.yaw);
                    const cosine = @cos(self.game_camera.yaw);
                    actions.move = .{
                        world_x * cosine + world_z * sine,
                        world_x * sine - world_z * cosine,
                    };
                }
            }
            return actions;
        }

        const npc = self.simulation.npcs().view(
            progress.target_actor orelse return actions,
        ) catch return actions;
        const source = self.simulation.player().focusPosition() orelse return actions;
        const delta_x = npc.position[0] - source[0];
        const delta_z = npc.position[2] - source[2];
        const distance_squared = delta_x * delta_x + delta_z * delta_z;
        self.game_camera.yaw = std.math.atan2(delta_x, -delta_z);
        if (distance_squared > 18 * 18) {
            actions.move = .{ 0, 1 };
        } else if (hud.weapon_remaining_ticks == 0 and
            tick > progress.last_fire_request_tick)
        {
            actions.fire_pressed = true;
            progress.last_fire_request_tick = tick;
        }
        return actions;
    }

    fn s14ClearRayYaw(self: *App, source: [3]f32) !f32 {
        // The empty/reload acceptance phase must not provoke the population.
        // Find a deterministic horizontal ray whose full handgun range clears
        // every live authored NPC instead of relying on a particular fixture
        // object to happen to occlude them.
        const sample_count = 128;
        const range: f32 = 60;
        candidate: for (0..sample_count) |sample| {
            const yaw = -std.math.pi +
                std.math.tau * @as(f32, @floatFromInt(sample)) / sample_count;
            const forward = [2]f32{ @sin(yaw), -@cos(yaw) };
            for (self.simulation.inspection().populationMembers()) |member| {
                const actor = member.actor orelse continue;
                const npc = self.simulation.npcs().view(actor) catch continue;
                const delta = [2]f32{
                    npc.position[0] - source[0],
                    npc.position[2] - source[2],
                };
                const along = delta[0] * forward[0] + delta[1] * forward[1];
                if (along <= 0 or along > range) continue;
                const distance_squared = delta[0] * delta[0] + delta[1] * delta[1];
                const perpendicular_squared = @max(
                    @as(f32, 0),
                    distance_squared - along * along,
                );
                const clearance = npc.radius + 0.25;
                if (perpendicular_squared <= clearance * clearance) continue :candidate;
            }
            return yaw;
        }
        return error.S14ClearRayUnavailable;
    }

    fn processVehicleOutcomes(
        self: *App,
        comptime validation_composition: bool,
        scenario: ScriptedScenario,
    ) !void {
        while (self.simulation.vehicles().pollOutcome()) |outcome| {
            switch (outcome) {
                .spawned => |spawned| {
                    if (spawned.request_id != 1 or self.initial_vehicle_id != null) {
                        return error.UnexpectedVehicleBootstrapOutcome;
                    }
                    self.initial_vehicle_id = spawned.id;
                },
                .rejected => if (validation_composition) switch (scenario) {
                    .none, .s1_character, .s2_vehicle, .s3_streaming, .s8_population, .s4_physics_debug, .s7_interaction, .s11_combat, .s13_population, .s14_ranged_combat => return error.ScriptedVehicleCommandRejected,
                } else return error.UnexpectedVehicleCommandRejection,
                .despawned => return error.UnexpectedVehicleBootstrapOutcome,
            }
        }
    }

    fn processPlayerActionResults(
        self: *App,
        comptime validation_composition: bool,
        scenario: ScriptedScenario,
    ) !void {
        const action_tick = self.simulation.inspection().tickIndex();
        while (self.simulation.player().pollVehicleActionResult()) |result| {
            switch (result.disposition) {
                .entered => {
                    self.product_feedback.noteApplied(action_tick, .vehicle_toggle);
                    if (result.action != .enter or self.controlled_vehicle_id != null) {
                        return error.UnexpectedVehicleClientResult;
                    }
                    self.controlled_vehicle_id = result.vehicle;
                    if (validation_composition and scenario == .s2_vehicle) {
                        self.validation.s2_smoke.entered = true;
                        self.validation.s2_smoke.vehicle_position_before_drive =
                            (try self.simulation.vehicles().view(self.initial_vehicle_id.?)).state.chassis.pose.position;
                        const crate_id = self.initial_crate_id orelse
                            return error.S2VisualSmokeCrateSpawnMissing;
                        self.validation.s2_smoke.crate_position_before_drive =
                            (try self.simulation.crates().view(crate_id)).state.pose.position;
                    }
                },
                .exited => {
                    self.product_feedback.noteApplied(action_tick, .vehicle_toggle);
                    if (result.action != .exit or
                        !std.meta.eql(result.vehicle, self.controlled_vehicle_id orelse
                            return error.UnexpectedVehicleClientResult))
                    {
                        return error.UnexpectedVehicleClientResult;
                    }
                    self.controlled_vehicle_id = null;
                    if (validation_composition and scenario == .s2_vehicle) {
                        self.validation.s2_smoke.exited = true;
                    }
                },
                else => if (validation_composition and scenario != .none) {
                    return error.ScriptedVehicleCommandRejected;
                } else if (interactiveVehicleRejectionExpected(result)) {
                    self.product_feedback.noteAuthorityRejected(
                        action_tick,
                        .vehicle_toggle,
                        result.disposition,
                    );
                    _ = self.simulation.developer().record(.{
                        .severity = .info,
                        .category = .command,
                        .code = diagnostic_interactive_vehicle_rejected,
                        .tick_index = self.simulation.inspection().tickIndex(),
                        .frame_index = self.frame_timer.total_frames,
                        .thread_role = .host,
                        .thread_id = engine.diagnostics.currentThreadId(),
                        .persistent_id = null,
                        .correlation_id = @as(u64, @intFromEnum(result.disposition)) + 1,
                    });
                } else return error.UnexpectedVehicleClientRejection,
            }
        }

        while (self.simulation.player().pollInteractionActionResult()) |result| {
            self.interaction_last_player_result = result;
            switch (result.disposition) {
                .collected => {
                    if (result.action != .collect) {
                        return error.UnexpectedInteractionClientResult;
                    }
                    self.product_feedback.noteApplied(action_tick, .carry_toggle);
                },
                .dropped => {
                    if (result.action != .drop) {
                        return error.UnexpectedInteractionClientResult;
                    }
                    self.product_feedback.noteApplied(action_tick, .carry_toggle);
                },
                else => {
                    self.interaction_submission_failures +|= 1;
                    self.product_feedback.noteAuthorityRejected(
                        action_tick,
                        .carry_toggle,
                        result.disposition,
                    );
                    if (validation_composition and scenario == .s7_interaction) {
                        return error.S7InteractionCommandRejected;
                    }
                },
            }
        }
        while (self.simulation.player().pollMeleeActionResult()) |result| {
            switch (result.disposition) {
                .hit, .miss => self.product_feedback.noteApplied(action_tick, .melee),
                .cooldown, .dead, .wrong_incarnation, .invalid_state => self.product_feedback.noteAuthorityRejected(
                    action_tick,
                    .melee,
                    result.disposition,
                ),
            }
            if (validation_composition and scenario == .s11_combat) {
                self.validation.s11_combat.observeMeleeResult(result);
            }
            std.debug.print(
                "S11_SOLO_MELEE result={s} damage={d} health={d} killed={} ready_tick={d}\n",
                .{
                    @tagName(result.disposition),
                    result.applied_damage,
                    result.remaining_health,
                    result.killed,
                    result.ready_tick,
                },
            );
        }
        while (self.simulation.player().pollWeaponActionResult()) |result| {
            switch (result.disposition) {
                .equipped, .holstered, .fired_hit, .fired_miss, .reload_started => self.product_feedback.noteApplied(action_tick, .firearm),
                else => self.product_feedback.noteAuthorityRejected(
                    action_tick,
                    .firearm,
                    result.disposition,
                ),
            }
            if (validation_composition and scenario == .s14_ranged_combat) {
                self.validation.s14_ranged_combat.observeWeaponResult(result);
            }
            std.debug.print(
                "S14_SOLO_WEAPON action={s} result={s} ammo={d}/{d} damage={d} health={d} killed={} ready_tick={d} reload_tick={d}\n",
                .{
                    @tagName(result.action),
                    @tagName(result.disposition),
                    result.magazine_ammo,
                    result.reserve_ammo,
                    result.applied_damage,
                    result.remaining_health,
                    result.killed,
                    result.weapon_ready_tick,
                    result.reload_complete_tick,
                },
            );
        }
        while (self.simulation.player().pollShotEvent()) |event| {
            std.debug.print(
                "S14_SOLO_SHOT shooter={d}:{d} sequence={d} result={s} target={d}:{d} damage={d}\n",
                .{
                    event.shooter.index,
                    event.shooter.generation,
                    event.sequence.value,
                    @tagName(event.disposition),
                    event.target.index,
                    event.target.generation,
                    event.applied_damage,
                },
            );
        }
        while (self.simulation.player().pollRespawnActionResult()) |result| {
            switch (result.disposition) {
                .respawned => self.product_feedback.noteApplied(action_tick, .respawn),
                .alive,
                .cooldown,
                .cleanup_pending,
                .no_safe_spawn,
                .wrong_incarnation,
                .invalid_state,
                => self.product_feedback.noteAuthorityRejected(
                    action_tick,
                    .respawn,
                    result.disposition,
                ),
            }
            if (!validation_composition) {
                try self.product_character_lifecycle.observeRespawnResult(
                    &self.initial_character_id,
                    self.simulation.presentation().combatHud(),
                    result,
                );
            }
            if (validation_composition and scenario == .s11_combat) {
                self.validation.s11_combat.observeRespawnResult(result);
            }
            std.debug.print(
                "S11_SOLO_RESPAWN result={s} incarnation={d} ready_tick={d}\n",
                .{ @tagName(result.disposition), result.incarnation, result.ready_tick },
            );
        }
        while (self.simulation.player().pollLifeEvent()) |event| {
            if (!validation_composition) {
                const hud = self.simulation.presentation().combatHud();
                if (std.meta.eql(event.avatar, hud.avatar)) {
                    const current = self.initial_character_id orelse
                        return error.ProductCharacterIdentityMissingForLifeEvent;
                    const projected = self.simulation.inspection().replicatedId(
                        current,
                    ) orelse return error.ProductCharacterProjectionMissingForLifeEvent;
                    try self.product_character_lifecycle.observeLocalLife(
                        current,
                        projected,
                        hud,
                        event,
                    );
                }
            }
            if (validation_composition and scenario == .s11_combat) {
                if (event.state == .dead) {
                    self.validation.s11_combat.player_dead = true;
                    self.validation.s11_combat.dead_incarnation = event.incarnation;
                } else if (self.validation.s11_combat.dead_incarnation) |dead_incarnation| {
                    if (event.incarnation > dead_incarnation) {
                        self.validation.s11_combat.player_respawned = true;
                    }
                }
            }
            std.debug.print(
                "S11_SOLO_LIFE entity={d}:{d} state={s} health={d}/{d} respawn_ready_tick={d}\n",
                .{
                    event.avatar.index,
                    event.avatar.generation,
                    @tagName(event.state),
                    event.health,
                    event.maximum_health,
                    event.respawn_ready_tick,
                },
            );
        }
    }

    fn observeS2State(self: *App) !void {
        if (!self.validation.s2_smoke.entered or self.validation.s2_smoke.exited) return;
        const acknowledged = self.simulation.player().lastAcknowledgedInput();
        if (self.validation.s2_smoke.drive_input_sequence) |sequence| {
            self.validation.s2_smoke.drive_applied = acknowledged >= sequence;
        }
        if (self.validation.s2_smoke.steering_input_sequence) |sequence| {
            self.validation.s2_smoke.steering_applied = acknowledged >= sequence;
        }
        if (self.validation.s2_smoke.brake_input_sequence) |sequence| {
            self.validation.s2_smoke.brake_applied = acknowledged >= sequence;
        }
        if (self.validation.s2_smoke.hand_brake_input_sequence) |sequence| {
            self.validation.s2_smoke.hand_brake_applied = acknowledged >= sequence;
        }
        const vehicle_id = self.initial_vehicle_id orelse
            return error.S2VisualSmokeVehicleSpawnMissing;
        const vehicle = try self.simulation.vehicles().view(vehicle_id);
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
            const position = (try self.simulation.crates().view(crate_id)).state.pose.position;
            self.validation.s2_smoke.crate_displaced = self.validation.s2_smoke.crate_displaced or
                distanceSquared(before, position) > 0.04;
        }
    }

    fn drawCombatHealthBar(
        self: *App,
        position: [3]f32,
        y_offset: f32,
        plan: combat_presentation.HealthBarPlan,
        view_projection: zm.Mat,
    ) u64 {
        if (!plan.visible) return 0;
        const width: f32 = 1;
        const height: f32 = 0.08;
        const depth: f32 = 0.05;
        const geometry = combat_presentation.healthBarGeometry(plan, width);
        const y = position[1] + y_offset;
        const rotation = zm.rotationY(-self.game_camera.yaw);
        const right = self.game_camera.getRight();
        self.gpu_renderer.drawMeshWithMaterial(
            &self.block_mesh,
            null,
            sandbox_visual_catalog.materialTinted(.health_marker, plan.empty_color),
            zm.mul(
                zm.mul(zm.scaling(width, height, depth), rotation),
                zm.translation(position[0], y, position[2]),
            ),
            view_projection,
        );
        if (geometry.fill_width <= 0) return 1;
        self.gpu_renderer.drawMeshWithMaterial(
            &self.block_mesh,
            null,
            sandbox_visual_catalog.materialTinted(.health_marker, plan.fill_color),
            zm.mul(
                zm.mul(
                    zm.scaling(geometry.fill_width, height * 1.15, depth * 1.15),
                    rotation,
                ),
                zm.translation(
                    position[0] + right[0] * geometry.fill_center_offset,
                    y,
                    position[2] + right[2] * geometry.fill_center_offset,
                ),
            ),
            view_projection,
        );
        return 2;
    }

    /// Submit one product-scene draw and mirror the exact immutable draw plan
    /// into the optional NR0 auxiliary adapter. UI/debug calls continue using
    /// Renderer directly and therefore never enter model input.
    fn drawPresentationMesh(
        self: *App,
        identity: engine.neural_rendering.DrawIdentity,
        gpu_mesh: *const mesh.Mesh,
        diffuse_texture: ?texture.Texture,
        surface: sandbox_visual_catalog.Surface,
        material: renderer.SurfaceMaterial,
        model: zm.Mat,
        view_projection: zm.Mat,
    ) !void {
        // NR4 is an explicitly isolated validation capture. Its fixture is
        // submitted below with adapter-local target provenance; ordinary
        // sandbox draws must not leak into only one side of the paired frame.
        if (self.neural_target_fixture_enabled) return;
        self.gpu_renderer.drawMeshWithMaterial(
            gpu_mesh,
            diffuse_texture,
            material,
            model,
            view_projection,
        );
        if (self.neural_inputs) |*inputs| try inputs.record(.{
            .identity = identity,
            .mesh = gpu_mesh,
            .diffuse_texture = diffuse_texture,
            .base_color = material.base_color,
            .model = model,
            .view_projection = view_projection,
        });
        self.render_frame_audit = .{
            .valid = true,
            .semantic = identity.semantic,
            .part = identity.part,
            .ordinal = identity.ordinal,
            .surface = surface,
        };
    }

    fn drawNeuralEvaluationFixture(
        self: *App,
        view_projection: zm.Mat,
    ) !u64 {
        if (!self.neural_evaluation_fixture_enabled) return 0;
        const plans = neural_evaluation_fixture.plans(self.frame_timer.total_frames);
        for (plans) |plan| {
            const gpu_mesh: *const mesh.Mesh = switch (plan.mesh) {
                .cube => &self.block_mesh,
                .checker_cube => &self.visuals.crate_mesh,
                .wheel => &self.visuals.vehicle_wheel_mesh,
                .capsule => &self.visuals.character_mesh,
            };
            const diffuse_texture = switch (plan.mesh) {
                .checker_cube => gpu_mesh.diffuse_texture,
                else => null,
            };
            const scale = zm.scaling(plan.scale[0], plan.scale[1], plan.scale[2]);
            const rotation = zm.mul(
                zm.mul(zm.rotationX(plan.rotation[0]), zm.rotationY(plan.rotation[1])),
                zm.rotationZ(plan.rotation[2]),
            );
            const translation = zm.translation(
                plan.position[0],
                plan.position[1],
                plan.position[2],
            );
            try self.drawPresentationMesh(
                plan.identity,
                gpu_mesh,
                diffuse_texture,
                .obstacle,
                sandbox_visual_catalog.materialTinted(.obstacle, plan.base_color),
                zm.mul(zm.mul(scale, rotation), translation),
                view_projection,
            );
        }
        return @intCast(plans.len);
    }

    fn drawNeuralTargetFixture(self: *App, view_projection: zm.Mat) !u64 {
        if (!self.neural_target_fixture_enabled) return 0;
        const plans = neural_target_fixture.plansFor(
            self.neural_target_fixture_variant,
            self.neuralTargetFixtureFrame(),
        );
        for (plans) |plan| {
            const gpu_mesh: *const mesh.Mesh = switch (plan.mesh) {
                .cube => &self.visuals.visual_part_mesh,
                .wheel => &self.visuals.vehicle_wheel_mesh,
                .capsule => &self.visuals.character_mesh,
            };
            const source = plan.target_source;
            const scale = zm.scaling(
                source.transform.scale[0],
                source.transform.scale[1],
                source.transform.scale[2],
            );
            const rotation = zm.mul(
                zm.mul(
                    zm.rotationX(source.transform.rotation_xyz[0]),
                    zm.rotationY(source.transform.rotation_xyz[1]),
                ),
                zm.rotationZ(source.transform.rotation_xyz[2]),
            );
            const translation = zm.translation(
                source.transform.translation[0],
                source.transform.translation[1],
                source.transform.translation[2],
            );
            const model = zm.mul(zm.mul(scale, rotation), translation);
            self.gpu_renderer.drawMeshWithMaterial(
                gpu_mesh,
                null,
                renderer.SurfaceMaterial.unlit(plan.base_color),
                model,
                view_projection,
            );
            if (self.neural_inputs) |*inputs| try inputs.record(.{
                .identity = plan.identity,
                .mesh = gpu_mesh,
                .diffuse_texture = null,
                .base_color = plan.base_color,
                .model = model,
                .view_projection = view_projection,
                .target_source = source,
            });
        }
        return @intCast(plans.len);
    }

    fn neuralTargetFixtureFrame(self: *const App) u64 {
        if (!self.neural_trial_fixture_enabled) return self.frame_timer.total_frames;
        const sequence_frames = neural_target_fixture.segment_frame_span *
            neural_target_fixture.segment_count;
        return neural_target_fixture.sequence_start_frame +
            self.frame_timer.total_frames % sequence_frames;
    }

    fn applyNeuralEvaluationResize(self: *App) !void {
        if (!self.neural_evaluation_fixture_enabled) return;
        const program = self.neural_capture_camera_program orelse return;
        const frame = self.frame_timer.total_frames;
        const request = neural_capture_camera.resizeRequest(program, frame) orelse return;
        if (self.neural_evaluation_resize_frame == frame) return;
        if (!c.SDL_SetWindowSize(self.window, request.width, request.height)) {
            return error.NeuralEvaluationWindowResizeFailed;
        }
        if (!c.SDL_SyncWindow(self.window)) {
            return error.NeuralEvaluationWindowResizeSyncFailed;
        }
        self.neural_evaluation_resize_frame = frame;
        std.debug.print(
            "NR0_EVALUATION_RESIZE frame={d} width={d} height={d}\n",
            .{ frame, request.width, request.height },
        );
    }

    fn persistentNeuralIdentity(
        persistent_id: engine.PersistentId,
        semantic: engine.neural_rendering.SemanticClass,
        part: engine.neural_rendering.SemanticPart,
        ordinal: u16,
    ) engine.neural_rendering.DrawIdentity {
        return .{
            .identity = .{ .persistent = .{
                .namespace = persistent_id.namespace,
                .local = persistent_id.local,
            } },
            .semantic = semantic,
            .part = part,
            .ordinal = ordinal,
        };
    }

    fn replicatedNeuralIdentity(
        entity: sandbox_host.ReplicatedEntityId,
        semantic: engine.neural_rendering.SemanticClass,
        part: engine.neural_rendering.SemanticPart,
    ) engine.neural_rendering.DrawIdentity {
        return .{
            .identity = .{ .replicated = .{
                .index = entity.index,
                .generation = entity.generation,
            } },
            .semantic = semantic,
            .part = part,
        };
    }

    fn replicatedNeuralPartIdentity(
        entity: sandbox_host.ReplicatedEntityId,
        semantic: engine.neural_rendering.SemanticClass,
        part: engine.neural_rendering.SemanticPart,
        ordinal: u16,
    ) engine.neural_rendering.DrawIdentity {
        var result = replicatedNeuralIdentity(entity, semantic, part);
        result.ordinal = ordinal;
        return result;
    }

    fn fixtureNeuralIdentity(
        fixture: u64,
        semantic: engine.neural_rendering.SemanticClass,
        ordinal: u16,
    ) engine.neural_rendering.DrawIdentity {
        return .{
            .identity = .{ .fixture = fixture },
            .semantic = semantic,
            .ordinal = ordinal,
        };
    }

    /// Authored district decoration has one visual identity before and after
    /// logical activation. Streaming slots are transient storage and must not
    /// become temporal model identity.
    fn districtSceneNeuralIdentity(
        coord: district_contract.ChunkCoord,
    ) engine.neural_rendering.Identity {
        const x_bits: u32 = @bitCast(coord.x);
        const z_bits: u32 = @bitCast(coord.z);
        return .{ .fixture = 0x4449_0000_0000_0000 ^
            (@as(u64, x_bits) << 32) ^ @as(u64, z_bits) };
    }

    fn drawCombatHudMarkers(
        self: *App,
        position: [3]f32,
        y_offset: f32,
        hud: combat_presentation.LocalHud,
        view_projection: zm.Mat,
    ) u64 {
        var marker_count: u64 = 0;
        if (hud.melee_cooldown_marker) {
            self.drawCombatHudMarker(
                position,
                y_offset,
                @intCast(marker_count),
                combat_presentation.colors.melee_cooldown,
                view_projection,
            );
            marker_count += 1;
        }
        const respawn_color = combat_presentation.respawnMarkerColor(
            hud.respawn_marker,
        );
        if (respawn_color) |color| {
            self.drawCombatHudMarker(
                position,
                y_offset,
                @intCast(marker_count),
                color,
                view_projection,
            );
            marker_count += 1;
        }
        return marker_count;
    }

    fn drawCombatHudMarker(
        self: *App,
        position: [3]f32,
        y_offset: f32,
        marker_index: u8,
        color: combat_presentation.Color,
        view_projection: zm.Mat,
    ) void {
        const x_offset = (@as(f32, @floatFromInt(marker_index)) - 0.5) * 0.22;
        self.gpu_renderer.drawMeshWithMaterial(
            &self.block_mesh,
            null,
            sandbox_visual_catalog.materialTinted(.health_marker, color),
            zm.mul(
                zm.scaling(0.16, 0.16, 0.16),
                zm.translation(
                    position[0] + x_offset,
                    position[1] + y_offset,
                    position[2],
                ),
            ),
            view_projection,
        );
    }

    fn drawAuthoredDistrictScene(
        self: *App,
        scene: anytype,
        identity: engine.neural_rendering.Identity,
        view_projection: zm.Mat,
    ) !u64 {
        var draw_calls: u64 = 0;
        for (scene.instances(), 0..) |instance, instance_index| {
            if (instance.mesh_index >= scene.meshes().len) {
                return error.DistrictResidentInstanceInvalid;
            }
            const resident_mesh = scene.meshes()[instance.mesh_index];
            try self.drawPresentationMesh(
                .{
                    .identity = identity,
                    .semantic = .district,
                    .ordinal = std.math.cast(u16, instance_index) orelse
                        return error.DistrictResidentInstanceOrdinalOverflow,
                },
                resident_mesh.mesh,
                scene.materialTexture(resident_mesh.material_index),
                .building_primary,
                sandbox_visual_catalog.materialTinted(
                    .building_primary,
                    scene.materialBaseColor(resident_mesh.material_index),
                ),
                zm.loadMat(instance.transform[0..]),
                view_projection,
            );
            draw_calls +|= 1;
        }
        return draw_calls;
    }

    fn prepareIncidentSemanticEvidence(
        self: *App,
        character_draws: []const sandbox_host.CharacterDraw,
        vehicle_draws: []const sandbox_host.VehicleDraw,
        carryable_draws: []const sandbox_host.CarryableDraw,
        npc_draws: []const sandbox_host.NpcDraw,
        view_projection: zm.Mat,
    ) !void {
        var draws: [sandbox_developer_host.incident_semantic_maximum_draws]sandbox_developer_host.IncidentSemanticDraw = undefined;
        var count: usize = 0;
        for (character_draws) |draw| {
            if (count == draws.len) break;
            const rotation = zm.quatToMat(zm.f32x4(
                draw.pose.rotation[0],
                draw.pose.rotation[1],
                draw.pose.rotation[2],
                draw.pose.rotation[3],
            ));
            draws[count] = .{
                .entity = gameplayEntityRef(draw.entity, draw.incarnation),
                .mesh = try self.visuals.resolve(draw.mesh, draw.material),
                .model = zm.mul(rotation, zm.translation(
                    draw.pose.position[0],
                    draw.pose.position[1],
                    draw.pose.position[2],
                )),
                .view_projection = view_projection,
            };
            count += 1;
        }
        for (vehicle_draws) |draw| {
            if (count == draws.len) break;
            const entity = gameplayEntityRef(draw.entity, draw.entity.generation);
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
            draws[count] = .{
                .entity = entity,
                .mesh = try self.visuals.resolve(
                    draw.chassis_mesh,
                    draw.chassis_material,
                ),
                .model = zm.mul(zm.mul(chassis_scale, chassis_rotation), zm.translation(
                    draw.chassis_pose.position[0],
                    draw.chassis_pose.position[1],
                    draw.chassis_pose.position[2],
                )),
                .view_projection = view_projection,
            };
            count += 1;
            for (draw.wheels) |wheel| {
                if (count == draws.len) break;
                const scale = zm.scaling(wheel.width, wheel.radius * 2, wheel.radius * 2);
                const rotation = zm.quatToMat(zm.f32x4(
                    wheel.pose.rotation[0],
                    wheel.pose.rotation[1],
                    wheel.pose.rotation[2],
                    wheel.pose.rotation[3],
                ));
                draws[count] = .{
                    .entity = entity,
                    .mesh = try self.visuals.resolve(wheel.mesh, wheel.material),
                    .model = zm.mul(zm.mul(scale, rotation), zm.translation(
                        wheel.pose.position[0],
                        wheel.pose.position[1],
                        wheel.pose.position[2],
                    )),
                    .view_projection = view_projection,
                };
                count += 1;
            }
        }
        for (carryable_draws) |draw| {
            if (count == draws.len) break;
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
            draws[count] = .{
                .entity = gameplayEntityRef(draw.entity, draw.entity.generation),
                .mesh = &self.block_mesh,
                .model = zm.mul(zm.mul(scale, rotation), zm.translation(
                    draw.pose.position[0],
                    draw.pose.position[1],
                    draw.pose.position[2],
                )),
                .view_projection = view_projection,
            };
            count += 1;
        }
        for (npc_draws) |draw| {
            if (count == draws.len) break;
            const rotation = zm.quatToMat(zm.f32x4(
                draw.pose.rotation[0],
                draw.pose.rotation[1],
                draw.pose.rotation[2],
                draw.pose.rotation[3],
            ));
            draws[count] = .{
                .entity = gameplayEntityRef(draw.entity, draw.incarnation),
                .mesh = try self.visuals.resolve(draw.mesh, draw.material),
                .model = zm.mul(rotation, zm.translation(
                    draw.pose.position[0],
                    draw.pose.position[1],
                    draw.pose.position[2],
                )),
                .view_projection = view_projection,
            };
            count += 1;
        }
        self.developer.prepareIncidentSemanticFrame(
            &self.gpu_renderer,
            self.simulation.inspection().tickIndex(),
            self.frame_timer.total_frames,
            draws[0..count],
        );
    }

    /// Render the current frame using SDL3 GPU API
    /// `alpha` is the interpolation factor (0.0 to 1.0) for smooth visuals.
    fn render(self: *App, alpha: f32) !RenderResult {
        self.render_frame_audit = .{};
        if (self.neural_rendering) |*neural| neural.prepareFrame(&self.gpu_renderer);
        // Streamed submissions are independent of the frame command buffer.
        // Poll fences without waiting, then submit at most one bounded batch.
        var stream_gpu_profile = self.beginHostProfile(
            .stream_gpu_pump,
            self.frame_timer.total_frames,
            self.simulation.inspection().tickIndex(),
        );
        defer stream_gpu_profile.finish(.failure);
        if (build_options.validation_mode or builtin.is_test) {
            if (self.validation.s4_fault_loop_probe) |probe| probe.gpu_pump_calls += 1;
        }
        const district_gpu_progress = try self.district_streaming.pumpGpu(
            self.districtAuthorityPort(),
            self.frame_timer.total_frames,
        );
        const district_gpu_stats = district_gpu_progress.usage;
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
        self.developer.preparePhysicsDebugFrame(self.frame_timer.total_frames);
        try self.applyNeuralEvaluationResize();

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

        // Gameplay projection follows the fixed product scene, not the
        // resizable window surrounding it.
        const scene_extent = self.gpu_renderer.getProductSceneExtent();
        const aspect_ratio = @as(f32, @floatFromInt(scene_extent.width)) /
            @as(f32, @floatFromInt(scene_extent.height));

        var scene_extraction_profile = self.beginHostProfile(
            .scene_extraction,
            self.frame_timer.total_frames,
            self.simulation.inspection().tickIndex(),
        );
        defer scene_extraction_profile.finish(.failure);
        const character_draws = self.simulation.presentation().characters(alpha);
        const vehicle_draws = self.simulation.presentation().vehicles(alpha);
        const district_draws = try self.simulation.districts().presentation();
        const crate_draws = try self.simulation.crates().presentation(alpha);
        const carryable_draws = self.simulation.presentation().carryables(alpha);
        const npc_draws = self.simulation.presentation().npcs(alpha);
        const combat_hud = self.simulation.presentation().combatHud();
        const shot_tracers = self.simulation.presentation().shotTracers();
        try self.tracePresentationPlan(
            character_draws,
            vehicle_draws,
            carryable_draws,
            npc_draws,
            combat_hud.authority_tick,
        );
        if (build_options.validation_mode or builtin.is_test) {
            if (self.validation.profile == .s2_smoke and self.validation.s2_smoke.entered) {
                observeS2WheelPresentation(&self.validation.s2_smoke, vehicle_draws);
            }
            self.validation.s13_population.observe(npc_draws, district_draws);
        }
        var follow_target: ?[3]f32 = null;
        var follow_distance: f32 = 0;
        if (self.controlled_vehicle_id) |controlled_id| {
            for (vehicle_draws) |draw| {
                if (std.meta.eql(draw.entity, controlled_id)) {
                    const target = [3]f32{
                        draw.chassis_pose.position[0],
                        draw.chassis_pose.position[1] + 1,
                        draw.chassis_pose.position[2],
                    };
                    follow_target = target;
                    follow_distance = 12.0;
                    self.game_camera.followTarget(target, follow_distance);
                    break;
                }
            }
            // A reliable action result can precede the corresponding
            // replication lane on a reordered transport. Keep the previous
            // camera target until the controlled vehicle becomes visible.
        } else {
            for (character_draws) |draw| {
                if (draw.local_player) {
                    follow_target = draw.camera_target;
                    follow_distance = 9.0;
                    self.game_camera.followTarget(draw.camera_target, follow_distance);
                    break;
                }
            }
            // Initial admission/admin outcomes may precede the first client
            // projection. Keep the previous target until presentation catches
            // up; validation scenarios require eventual evidence separately.
        }
        if (follow_target) |target| {
            const desired_position = [3]f32{
                self.game_camera.position[0],
                self.game_camera.position[1],
                self.game_camera.position[2],
            };
            if (try self.simulation.presentation().lineHitFraction(
                target,
                desired_position,
            )) |hit_fraction| {
                self.game_camera.clampFollowObstruction(
                    target,
                    follow_distance,
                    hit_fraction,
                    0.2,
                );
            }
        }
        var neural_history_reset: engine.neural_rendering.ResetReason = .none;
        if (self.neural_capture_camera_program) |program| {
            if (self.neural_target_fixture_enabled) {
                neural_history_reset = neural_capture_camera.apply(
                    program,
                    &self.game_camera,
                    neural_target_fixture.center,
                    self.frame_timer.total_frames,
                );
            } else if (self.neural_evaluation_fixture_enabled) {
                neural_history_reset = neural_capture_camera.apply(
                    program,
                    &self.game_camera,
                    neural_evaluation_fixture.center,
                    self.frame_timer.total_frames,
                );
            } else if (follow_target) |target| {
                neural_history_reset = neural_capture_camera.apply(
                    program,
                    &self.game_camera,
                    target,
                    self.frame_timer.total_frames,
                );
            }
        }

        // Get view-projection matrix from camera
        const view_proj = self.game_camera.getViewProjectionMatrix(aspect_ratio);
        if (self.neural_inputs) |*inputs| {
            try inputs.beginFrame(.{
                .authority_tick = self.simulation.inspection().tickIndex(),
                .presentation_frame = self.frame_timer.total_frames,
                .interpolation_alpha = alpha,
                .target_width = engine.neural_rendering.target_width,
                .target_height = engine.neural_rendering.target_height,
                .global_controls = if (self.neural_target_fixture_enabled)
                    neural_target_fixture.sequenceStateFor(
                        self.neural_target_fixture_variant,
                        self.neuralTargetFixtureFrame(),
                    ).global_controls
                else
                    .{},
                .history_reset = if (inputs.diagnostics().rendered_frames == 0)
                    .first_frame
                else
                    neural_history_reset,
            }, self.game_camera.getViewMatrix());
        }
        scene_extraction_profile.finish(.success);

        var scene_draw_profile = self.beginHostProfile(
            .scene_draw,
            self.frame_timer.total_frames,
            self.simulation.inspection().tickIndex(),
        );
        defer scene_draw_profile.finish(.failure);
        var scene_draw_calls: u64 = 0;

        // The ground is a visual-host fixture matching the simulation-owned
        // static body. Feature-owned entities arrive through extraction below.
        try self.drawPresentationMesh(
            fixtureNeuralIdentity(1, .environment, 0),
            &self.ground_mesh,
            self.ground_mesh.diffuse_texture,
            .ground,
            sandbox_visual_catalog.material(.ground),
            zm.identity(),
            view_proj,
        );
        scene_draw_calls +|= 1;
        for (sandbox_visual_composition.environmentPlans()) |part| {
            try self.drawPresentationMesh(
                fixtureNeuralIdentity(100 + part.ordinal, .environment, part.ordinal),
                &self.block_mesh,
                null,
                part.surface,
                part.material,
                part.model,
                view_proj,
            );
            scene_draw_calls +|= 1;
        }
        scene_draw_calls +|= try self.drawNeuralEvaluationFixture(view_proj);
        scene_draw_calls +|= try self.drawNeuralTargetFixture(view_proj);
        const draws_block = if (build_options.validation_mode or builtin.is_test)
            self.validation.profile == .s1_smoke
        else
            false;
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
            try self.drawPresentationMesh(
                fixtureNeuralIdentity(2, .environment, 0),
                &self.block_mesh,
                self.block_mesh.diffuse_texture,
                .obstacle,
                sandbox_visual_catalog.material(.obstacle),
                zm.mul(block_scale, block_translation),
                view_proj,
            );
            scene_draw_calls +|= 1;
        }
        const gate_state = self.simulation.developer().navigationGateState();
        const gate_positions = [_][3]f32{
            .{ 8, 1, 12 },
            .{ 8, 1, 4 },
        };
        const gate_open = [_]bool{
            gate_state.north_open,
            gate_state.south_open,
        };
        for (gate_positions, gate_open, 0..) |position, open, gate_index| {
            if (open) continue;
            const gate_scale = zm.scaling(0.4, 2.0, 2.0);
            const gate_translation = zm.translation(
                position[0],
                position[1],
                position[2],
            );
            try self.drawPresentationMesh(
                fixtureNeuralIdentity(10 + gate_index, .environment, 0),
                &self.block_mesh,
                self.block_mesh.diffuse_texture,
                .route_landmark,
                sandbox_visual_catalog.material(.route_landmark),
                zm.mul(gate_scale, gate_translation),
                view_proj,
            );
            scene_draw_calls +|= 1;
        }

        // Authored decoration may become visible from the adjacent district
        // once its bounded prefetch reaches GPU residency. Logical collision
        // and blocker proxies remain exclusively authority-ticketed below.
        for (0..district_streaming_host.slot_count) |slot_index| {
            if (try self.district_streaming.prefetchedVisual(slot_index)) |scene| {
                const slot = try self.district_streaming.slot(slot_index);
                scene_draw_calls +|= try self.drawAuthoredDistrictScene(
                    scene,
                    districtSceneNeuralIdentity(slot.coord),
                    view_proj,
                );
            }
        }

        for (district_draws) |draw| {
            const scene = try self.district_streaming.resolve(
                draw.build.coord,
                draw.ticket,
                draw.assets.scene,
            );
            const district_plan = try sandbox_contracts.districtPresentationPlan(
                &draw.build,
                scene.meshes().len != 0,
            );
            if (district_plan.authored_scene_resident) {
                scene_draw_calls +|= try self.drawAuthoredDistrictScene(
                    scene,
                    districtSceneNeuralIdentity(draw.build.coord),
                    view_proj,
                );
            }
            // Cooked meshes are currently decoration, not proof that a
            // collision primitive is represented. Mandatory blocker proxies
            // remain visible before and after GPU residency.
            for (district_plan.proxyBoxIndices()) |box_index| {
                const index: usize = box_index;
                if (index >= draw.build.boxes().len) {
                    return error.DistrictPresentationProxyInvalid;
                }
                const box = draw.build.boxes()[index];
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
                try self.drawPresentationMesh(
                    persistentNeuralIdentity(
                        draw.persistent_id,
                        .district,
                        .whole,
                        std.math.cast(u16, box_index) orelse
                            return error.DistrictProxyOrdinalOverflow,
                    ),
                    &self.block_mesh,
                    self.block_mesh.diffuse_texture,
                    .obstacle,
                    sandbox_visual_catalog.material(.obstacle),
                    zm.mul(zm.mul(scale, rotation), translation),
                    view_proj,
                );
                scene_draw_calls +|= 1;
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
            try self.drawPresentationMesh(
                persistentNeuralIdentity(draw.persistent_id, .crate, .whole, 0),
                crate_mesh,
                crate_mesh.diffuse_texture,
                .carryable,
                sandbox_visual_catalog.material(.carryable),
                model_matrix,
                view_proj,
            );
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
            try self.drawPresentationMesh(
                replicatedNeuralIdentity(draw.entity, .carryable, .whole),
                &self.block_mesh,
                self.block_mesh.diffuse_texture,
                .carryable,
                sandbox_visual_catalog.material(.carryable),
                zm.mul(zm.mul(scale, rotation), translation),
                view_proj,
            );
            scene_draw_calls +|= 1;
        }

        for (vehicle_draws) |draw| {
            _ = try self.visuals.resolve(
                draw.chassis_mesh,
                draw.chassis_material,
            );
            for (sandbox_visual_composition.vehicleBodyPlans(
                draw.chassis_half_extents,
                draw.chassis_pose,
            )) |part| {
                try self.drawPresentationMesh(
                    replicatedNeuralPartIdentity(
                        draw.entity,
                        .vehicle,
                        .vehicle_chassis,
                        part.ordinal,
                    ),
                    &self.visuals.visual_part_mesh,
                    null,
                    part.surface,
                    part.material,
                    part.model,
                    view_proj,
                );
                scene_draw_calls +|= 1;
            }

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
                const wheel_part: engine.neural_rendering.SemanticPart = switch (wheel.index) {
                    .front_left => .vehicle_wheel_front_left,
                    .front_right => .vehicle_wheel_front_right,
                    .rear_left => .vehicle_wheel_rear_left,
                    .rear_right => .vehicle_wheel_rear_right,
                };
                try self.drawPresentationMesh(
                    replicatedNeuralIdentity(draw.entity, .vehicle, wheel_part),
                    wheel_mesh,
                    wheel_mesh.diffuse_texture,
                    .tire,
                    sandbox_visual_catalog.material(.tire),
                    zm.mul(zm.mul(wheel_scale, wheel_rotation), wheel_translation),
                    view_proj,
                );
                scene_draw_calls +|= 1;
                try self.drawPresentationMesh(
                    replicatedNeuralPartIdentity(
                        draw.entity,
                        .vehicle,
                        wheel_part,
                        1,
                    ),
                    &self.visuals.visual_part_mesh,
                    null,
                    .wheel_marker,
                    sandbox_visual_catalog.material(.wheel_marker),
                    sandbox_visual_composition.wheelMarkerModel(
                        wheel.width,
                        wheel.radius,
                        wheel.pose,
                    ),
                    view_proj,
                );
                scene_draw_calls +|= 1;
            }
        }

        for (character_draws) |draw| {
            _ = try self.visuals.resolve(draw.mesh, draw.material);
            for (sandbox_visual_composition.characterPlans(
                draw.radius,
                draw.half_height,
                draw.pose,
                draw.combat.body_color,
            )) |part| {
                try self.drawPresentationMesh(
                    replicatedNeuralPartIdentity(
                        draw.entity,
                        .character,
                        .whole,
                        part.ordinal,
                    ),
                    &self.visuals.visual_part_mesh,
                    null,
                    part.surface,
                    part.material,
                    part.model,
                    view_proj,
                );
                scene_draw_calls +|= 1;
            }
            const health_bar_draw_calls = self.drawCombatHealthBar(
                draw.pose.position,
                draw.radius + draw.half_height + 0.25,
                draw.combat.health_bar,
                view_proj,
            );
            scene_draw_calls +|= health_bar_draw_calls;
            if (draw.weapon_mode != .holstered and draw.life_state == .alive) {
                const weapon = sandbox_visual_composition.handgunPlan(
                    draw.radius,
                    draw.half_height,
                    draw.pose,
                );
                try self.drawPresentationMesh(
                    replicatedNeuralPartIdentity(
                        draw.entity,
                        .character,
                        .whole,
                        weapon.ordinal,
                    ),
                    &self.visuals.visual_part_mesh,
                    null,
                    weapon.surface,
                    weapon.material,
                    weapon.model,
                    view_proj,
                );
                scene_draw_calls +|= 1;
                if ((build_options.validation_mode or builtin.is_test) and
                    draw.local_player)
                {
                    self.validation.s14_ranged_combat.weapon_drawn = true;
                }
                const signature = (@as(u64, draw.entity.index) << 32) |
                    (@as(u64, draw.entity.generation) << 16) |
                    @intFromEnum(draw.weapon_mode);
                if (signature != self.last_weapon_draw_signature) {
                    self.last_weapon_draw_signature = signature;
                    _ = self.simulation.developer().recordGameplayTrace(.{
                        .authority_tick = combat_hud.authority_tick,
                        .presentation_frame = self.frame_timer.total_frames,
                        .actor = gameplayEntityRef(draw.entity, draw.incarnation),
                        .source = .renderer,
                        .stage = .draw_submitted,
                        .kind = .firearm,
                        .disposition = .visible,
                        .fields = .{ .position = true, .state = true },
                        .position = draw.pose.position,
                        .state = @intFromEnum(draw.weapon_mode),
                        .weapon = .{
                            .action = 0,
                            .mode = @intFromEnum(draw.weapon_mode),
                            .magazine_ammo = combat_hud.magazine_ammo,
                            .reserve_ammo = combat_hud.reserve_ammo,
                            .weapon_ready_tick = combat_hud.authority_tick +|
                                combat_hud.weapon_remaining_ticks,
                            .reload_complete_tick = combat_hud.authority_tick +|
                                combat_hud.reload_remaining_ticks,
                        },
                    });
                }
            }
            if (build_options.validation_mode or builtin.is_test) {
                self.validation.s11_combat.observeCharacter(
                    combat_hud.authority_tick,
                    draw,
                    health_bar_draw_calls,
                );
            }
        }
        // NPC authority exposes the same immutable typed resource contract as
        // the player character. This loop submits only extracted poses; the
        // optional sight/range/leash/route overlay arrives separately through
        // the bounded developer-debug geometry path.
        for (npc_draws) |draw| {
            _ = try self.visuals.resolve(draw.mesh, draw.material);
            for (sandbox_visual_composition.characterPlans(
                draw.radius,
                draw.half_height,
                draw.pose,
                draw.combat.entity.body_color,
            )) |part| {
                try self.drawPresentationMesh(
                    replicatedNeuralPartIdentity(
                        draw.entity,
                        .npc,
                        .whole,
                        part.ordinal,
                    ),
                    &self.visuals.visual_part_mesh,
                    null,
                    part.surface,
                    part.material,
                    part.model,
                    view_proj,
                );
                scene_draw_calls +|= 1;
            }
            const health_bar_draw_calls = self.drawCombatHealthBar(
                draw.pose.position,
                draw.radius + draw.half_height + 0.25,
                draw.combat.entity.health_bar,
                view_proj,
            );
            scene_draw_calls +|= health_bar_draw_calls;
            if (build_options.validation_mode or builtin.is_test) {
                self.validation.s11_combat.observeNpc(
                    combat_hud.authority_tick,
                    draw,
                    health_bar_draw_calls,
                );
                self.validation.s14_ranged_combat.observeNpc(draw);
            }
        }
        for (shot_tracers) |tracer| {
            const plan = sandbox_visual_composition.tracerPlan(
                tracer.origin,
                tracer.impact,
                tracer.hit,
            ) orelse continue;
            try self.drawPresentationMesh(
                replicatedNeuralPartIdentity(
                    tracer.shooter,
                    .character,
                    .whole,
                    @intCast(200 + tracer.sequence.value % 32),
                ),
                &self.visuals.visual_part_mesh,
                null,
                plan.surface,
                plan.material,
                plan.model,
                view_proj,
            );
            scene_draw_calls +|= 1;
            if (build_options.validation_mode or builtin.is_test) {
                self.validation.s14_ranged_combat.tracer_drawn = true;
            }
            const signature = (@as(u64, tracer.shooter.index) << 32) |
                @as(u64, tracer.sequence.value);
            if (signature != self.last_tracer_draw_signature) {
                self.last_tracer_draw_signature = signature;
                _ = self.simulation.developer().recordGameplayTrace(.{
                    .authority_tick = combat_hud.authority_tick,
                    .presentation_frame = self.frame_timer.total_frames,
                    .actor = gameplayEntityRef(
                        tracer.shooter,
                        tracer.shooter.generation,
                    ),
                    .source = .renderer,
                    .stage = .draw_submitted,
                    .kind = .firearm,
                    .disposition = .visible,
                    .correlation_id = tracer.sequence.value,
                    .fields = .{ .position = true },
                    .position = tracer.impact,
                    .weapon = .{
                        .action = @intFromEnum(sandbox_host.WeaponActionKind.fire),
                        .mode = 0,
                        .magazine_ammo = combat_hud.magazine_ammo,
                        .reserve_ammo = combat_hud.reserve_ammo,
                        .weapon_ready_tick = combat_hud.authority_tick +|
                            combat_hud.weapon_remaining_ticks,
                        .reload_complete_tick = combat_hud.authority_tick +|
                            combat_hud.reload_remaining_ticks,
                        .ray_origin = tracer.origin,
                        .impact_position = tracer.impact,
                    },
                });
            }
        }
        var combat_hud_marker_draw_calls: u64 = 0;
        if (combat_hud.anchor_position) |position| {
            combat_hud_marker_draw_calls = self.drawCombatHudMarkers(
                position,
                1.45,
                combat_hud,
                view_proj,
            );
            scene_draw_calls +|= combat_hud_marker_draw_calls;
        }
        if (build_options.validation_mode or builtin.is_test) {
            self.validation.s11_combat.observeHud(
                combat_hud,
                combat_hud_marker_draw_calls,
            );
            self.validation.s14_ranged_combat.observeHud(combat_hud);
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
        if (self.neural_inputs) |*inputs| try inputs.render(&self.gpu_renderer);
        self.developer.prepareIncidentProductFrame(
            &self.gpu_renderer,
            self.simulation.inspection().tickIndex(),
            self.frame_timer.total_frames,
        );

        // Draw editor overlay (ImGui debug UI), then apply its fixed typed
        // request mailboxes only after the borrowed snapshot/view is unused.
        var editor_profile = self.beginHostProfile(
            .editor,
            self.frame_timer.total_frames,
            self.simulation.inspection().tickIndex(),
        );
        defer editor_profile.finish(.failure);
        const gameplay_view = self.gameplayEditorView(
            character_draws,
            vehicle_draws,
            carryable_draws,
            npc_draws,
            combat_hud,
        );
        if (build_options.validation_mode or builtin.is_test) {
            self.validation.s11_combat.observeProductHud(&gameplay_view);
        }
        self.updateProductTitle(character_draws, npc_draws, combat_hud);
        try self.drawDeveloperOverlay(&gameplay_view);
        try self.prepareIncidentSemanticEvidence(
            character_draws,
            vehicle_draws,
            carryable_draws,
            npc_draws,
            view_proj,
        );
        editor_profile.finish(.success);

        // Submit the frame (both scene and editor render passes)
        var submission_profile = self.beginHostProfile(
            .submission,
            self.frame_timer.total_frames,
            self.simulation.inspection().tickIndex(),
        );
        defer submission_profile.finish(.failure);
        try self.submitCurrentFrame();
        if (build_options.validation_mode) {
            try self.captureS11Visibility(character_draws, npc_draws, view_proj);
        }
        submission_profile.finish(.success);
        return .{ .ready = .{
            .crate_count = crate_draws.len,
            .first_id = if (crate_draws.len > 0) crate_draws[0].persistent_id else null,
            .first_position = if (crate_draws.len > 0) crate_draws[0].pose.position else null,
            .first_rotation = if (crate_draws.len > 0) crate_draws[0].pose.rotation else null,
            .character_count = character_draws.len,
            .character_id = if (character_draws.len > 0)
                character_draws[0].entity
            else
                null,
            .character_position = if (character_draws.len > 0)
                character_draws[0].pose.position
            else
                null,
            .vehicle_count = vehicle_draws.len,
            .vehicle_id = if (vehicle_draws.len > 0)
                vehicle_draws[0].entity
            else
                null,
            .district_count = district_draws.len,
            .carryable_count = carryable_draws.len,
            .carryable_id = if (carryable_draws.len > 0)
                carryable_draws[0].entity
            else
                null,
            .npc_count = npc_draws.len,
        } };
    }

    fn gameplayEntityRef(
        entity: sandbox_host.ReplicatedEntityId,
        incarnation: u16,
    ) engine.gameplay_trace.EntityRef {
        return .{
            .namespace = 2,
            .local = (@as(u64, entity.generation) << 32) | @as(u64, entity.index),
            .incarnation = incarnation,
        };
    }

    fn gameplayViewContains(
        view: *const editor_contract.GameplayView,
        entity: engine.gameplay_trace.EntityRef,
    ) bool {
        for (view.entitySlice()) |candidate| {
            if (std.meta.eql(candidate.entity, entity)) return true;
        }
        return false;
    }

    fn tracePresentationPlan(
        self: *App,
        character_draws: []const sandbox_host.CharacterDraw,
        vehicle_draws: []const sandbox_host.VehicleDraw,
        carryable_draws: []const sandbox_host.CarryableDraw,
        npc_draws: []const sandbox_host.NpcDraw,
        authority_tick: u64,
    ) !void {
        var observations: [product_presentation_trace.capacity]product_presentation_trace.Observation = undefined;
        var count: usize = 0;
        for (character_draws) |draw| {
            if (count == observations.len) return error.PresentationTraceCapacityExceeded;
            observations[count] = .{
                .entity = gameplayEntityRef(draw.entity, draw.incarnation),
                .position = draw.pose.position,
                .health = draw.health,
                .maximum_health = draw.maximum_health,
                .life_state = @intFromEnum(draw.life_state),
                .kind = if (draw.local_player) .local_player else .remote_player,
                .radius = draw.radius,
                .half_height = draw.half_height,
            };
            count += 1;
        }
        for (vehicle_draws) |draw| {
            if (count == observations.len) return error.PresentationTraceCapacityExceeded;
            observations[count] = .{
                .entity = gameplayEntityRef(draw.entity, draw.entity.generation),
                .position = draw.chassis_pose.position,
                .health = 0,
                .maximum_health = 0,
                .life_state = 0,
                .kind = .vehicle,
                .radius = @max(draw.chassis_half_extents[0], draw.chassis_half_extents[2]),
                .half_height = draw.chassis_half_extents[1],
            };
            count += 1;
        }
        for (carryable_draws) |draw| {
            if (count == observations.len) return error.PresentationTraceCapacityExceeded;
            observations[count] = .{
                .entity = gameplayEntityRef(draw.entity, draw.entity.generation),
                .position = draw.pose.position,
                .health = 0,
                .maximum_health = 0,
                .life_state = 0,
                .kind = .carryable,
                .radius = @max(draw.half_extents[0], draw.half_extents[2]),
                .half_height = draw.half_extents[1],
            };
            count += 1;
        }
        for (npc_draws) |draw| {
            if (count == observations.len) return error.PresentationTraceCapacityExceeded;
            observations[count] = .{
                .entity = gameplayEntityRef(draw.entity, draw.incarnation),
                .position = draw.pose.position,
                .health = draw.health,
                .maximum_health = draw.maximum_health,
                .life_state = @intFromEnum(draw.life_state),
                .kind = .npc,
                .radius = draw.radius,
                .half_height = draw.half_height,
                .encounter_state = @intFromEnum(draw.encounter_state),
                .attack_windup = draw.combat.windup,
                .deadline_tick = if (draw.encounter_state == .attack_windup)
                    draw.attack_impact_tick
                else
                    draw.attack_ready_tick,
            };
            count += 1;
        }
        const batch = try self.product_presentation_trace.observe(
            authority_tick,
            self.frame_timer.total_frames,
            observations[0..count],
        );
        for (batch.slice()) |record| {
            _ = self.simulation.developer().recordGameplayTrace(record);
        }
    }

    fn gameplayLifeState(value: anytype) editor_contract.GameplayLifeState {
        return switch (value) {
            .alive => .alive,
            .dead => .dead,
        };
    }

    fn applyNpcInterestEvidence(
        target: *editor_contract.GameplayEntityView,
        evidence: ?sandbox_host.NpcInterestView,
    ) void {
        const value = evidence orelse return;
        target.relevance_included = value.included;
        target.relevance_reason = switch (value.reason) {
            .excluded => .excluded,
            .full_world => .full_world,
            .same_district => .same_district,
            .encounter => .encounter,
            .proximity_enter => .proximity_enter,
            .proximity_retained => .proximity_retained,
            .grace => .grace,
        };
        target.relevance_evaluated_tick = value.evaluated_tick;
        target.relevance_grace_until_tick = value.grace_until_tick;
        target.relevance_observer_position = value.observer_position;
        target.relevance_observer_district = .{
            value.observer_district.x,
            value.observer_district.z,
        };
        target.relevance_owner_district = .{
            value.owner_district.x,
            value.owner_district.z,
        };
        target.relevance_distance_squared_xz = value.distance_squared_xz;
        target.relevance_encounter = value.encounter_relevant;
    }

    fn applyObjectInterestEvidence(
        target: *editor_contract.GameplayEntityView,
        evidence: ?sandbox_host.ObjectInterestView,
    ) void {
        const value = evidence orelse return;
        target.relevance_included = value.included;
        target.relevance_reason = switch (value.reason) {
            .bounded_world => .bounded_world,
            .controlled => .controlled,
            .held => .held,
            .district_dormant => .district_dormant,
        };
        target.relevance_evaluated_tick = value.evaluated_tick;
        target.relevance_baseline_id = value.baseline_id;
        target.relevance_snapshot_sequence = value.snapshot_sequence;
        target.relevance_observer_position = value.observer_position;
        target.relevance_observer_district = .{
            value.observer_district.x,
            value.observer_district.z,
        };
        target.relevance_owner_district = .{
            value.owner_district.x,
            value.owner_district.z,
        };
        target.relevance_distance_squared_xz = value.distance_squared_xz;
    }

    fn gameplayEditorView(
        self: *App,
        character_draws: []const sandbox_host.CharacterDraw,
        vehicle_draws: []const sandbox_host.VehicleDraw,
        carryable_draws: []const sandbox_host.CarryableDraw,
        npc_draws: []const sandbox_host.NpcDraw,
        hud: combat_presentation.LocalHud,
    ) editor_contract.GameplayView {
        var result = editor_contract.GameplayView{
            .authority_tick = hud.authority_tick,
            .presentation_frame = self.frame_timer.total_frames,
            .local_health = hud.health,
            .local_maximum_health = hud.maximum_health,
            .local_life_state = gameplayLifeState(hud.life_state),
            .melee_remaining_ticks = hud.melee_remaining_ticks,
            .weapon_mode = switch (hud.weapon_mode) {
                .holstered => .holstered,
                .equipped => .equipped,
                .reloading => .reloading,
            },
            .magazine_ammo = hud.magazine_ammo,
            .reserve_ammo = hud.reserve_ammo,
            .weapon_remaining_ticks = hud.weapon_remaining_ticks,
            .reload_remaining_ticks = hud.reload_remaining_ticks,
            .respawn_remaining_ticks = hud.respawn_remaining_ticks,
            .respawn_instruction_visible = hud.life_state == .dead and
                hud.respawn_remaining_ticks == 0,
        };
        if (self.product_feedback.current(hud.authority_tick)) |feedback| {
            result.last_action = .{
                .sequence = feedback.sequence,
                .action = feedback.kind,
                .disposition = feedback.disposition,
                .reason_domain = feedback.reason_domain,
                .reason = feedback.reason,
                .observed_tick = feedback.observed_tick,
            };
            const reason_text = actionFeedbackReason(
                feedback.kind,
                feedback.reason_domain,
                feedback.reason,
            );
            if (reason_text.len > result.last_action.reason_text.len) unreachable;
            @memcpy(
                result.last_action.reason_text[0..reason_text.len],
                reason_text,
            );
            result.last_action.reason_text_len = @intCast(reason_text.len);
        }

        const inspection = self.simulation.inspection();
        for (character_draws) |draw| {
            if (result.entity_count == editor_contract.gameplay_entity_capacity) break;
            const persistent = inspection.persistentId(draw.entity);
            var authority_present = false;
            var authority_position = draw.pose.position;
            var velocity: [3]f32 = .{ 0, 0, 0 };
            var facing_yaw: f32 = 0;
            var radius = draw.radius;
            var half_height = draw.half_height;
            if (persistent) |id| {
                if (self.simulation.characters().view(id) catch null) |view| {
                    authority_present = true;
                    authority_position = view.position;
                    velocity = view.velocity;
                    facing_yaw = view.facing_yaw;
                    radius = view.radius;
                    half_height = view.half_height;
                }
            }
            result.entities[result.entity_count] = .{
                .entity = gameplayEntityRef(draw.entity, draw.incarnation),
                .persistent_id = persistent,
                .kind = if (draw.local_player) .local_player else .remote_player,
                .authority_presence = if (authority_present) .present else .absent,
                .replication_presence = .present,
                .presentation_presence = .present,
                .draw_presence = .present,
                .authority_position = authority_position,
                .presentation_position = draw.pose.position,
                .velocity = velocity,
                .facing_yaw = facing_yaw,
                .radius = radius,
                .half_height = half_height,
                .health = draw.health,
                .maximum_health = draw.maximum_health,
                .life_state = gameplayLifeState(draw.life_state),
            };
            if (draw.local_player and draw.combat.hit_flash) {
                result.local_damage_feedback = true;
            }
            result.entity_count += 1;
        }
        for (vehicle_draws) |draw| {
            if (result.entity_count == editor_contract.gameplay_entity_capacity) break;
            const persistent = inspection.persistentId(draw.entity);
            var authority_present = false;
            var authority_position = draw.chassis_pose.position;
            var velocity: [3]f32 = .{ 0, 0, 0 };
            if (persistent) |id| {
                if (self.simulation.vehicles().view(id) catch null) |view| {
                    authority_present = true;
                    authority_position = view.state.chassis.pose.position;
                    velocity = view.state.chassis.velocity.linear;
                }
            }
            var projected = editor_contract.GameplayEntityView{
                .entity = gameplayEntityRef(draw.entity, draw.entity.generation),
                .persistent_id = persistent,
                .kind = .vehicle,
                .authority_presence = if (authority_present) .present else .absent,
                .replication_presence = .present,
                .presentation_presence = .present,
                .draw_presence = .present,
                .authority_position = authority_position,
                .presentation_position = draw.chassis_pose.position,
                .velocity = velocity,
                .radius = @max(draw.chassis_half_extents[0], draw.chassis_half_extents[2]),
                .half_height = draw.chassis_half_extents[1],
                .health = 0,
                .maximum_health = 0,
                .life_state = .unknown,
            };
            applyObjectInterestEvidence(&projected, inspection.vehicleInterest(draw.entity));
            result.entities[result.entity_count] = projected;
            result.entity_count += 1;
        }
        for (carryable_draws) |draw| {
            if (result.entity_count == editor_contract.gameplay_entity_capacity) break;
            const persistent = inspection.persistentId(draw.entity);
            var authority_present = false;
            var authority_position = draw.pose.position;
            var velocity: [3]f32 = .{ 0, 0, 0 };
            if (persistent) |id| {
                if (self.simulation.interactions().view(id) catch null) |view| {
                    authority_present = true;
                    if (draw.holder == null) {
                        authority_position = view.state.pose.position;
                        velocity = view.state.velocity.linear;
                    }
                }
            }
            var projected = editor_contract.GameplayEntityView{
                .entity = gameplayEntityRef(draw.entity, draw.entity.generation),
                .persistent_id = persistent,
                .kind = .carryable,
                .authority_presence = if (authority_present) .present else .absent,
                .replication_presence = .present,
                .presentation_presence = .present,
                .draw_presence = .present,
                .authority_position = authority_position,
                .presentation_position = draw.pose.position,
                .velocity = velocity,
                .radius = @max(draw.half_extents[0], draw.half_extents[2]),
                .half_height = draw.half_extents[1],
                .health = 0,
                .maximum_health = 0,
                .life_state = .unknown,
            };
            applyObjectInterestEvidence(&projected, inspection.carryableInterest(draw.entity));
            result.entities[result.entity_count] = projected;
            result.entity_count += 1;
        }
        for (npc_draws) |draw| {
            if (result.entity_count == editor_contract.gameplay_entity_capacity) break;
            const persistent = inspection.persistentId(draw.entity);
            var authority_present = false;
            var authority_position = draw.pose.position;
            var velocity: [3]f32 = .{ 0, 0, 0 };
            var facing_yaw: f32 = 0;
            var navigation_progress: editor_contract.GameplayNavigationProgress = .unavailable;
            var navigation_target: ?[3]f32 = null;
            var navigation_no_progress_ticks: u16 = 0;
            var navigation_last_progress_tick: u64 = 0;
            var navigation_destination: ?sandbox_contracts.DestinationId = null;
            var navigation_status: ?sandbox_contracts.NpcNavigationStatus = null;
            var navigation_reason: ?sandbox_contracts.NpcNavigationReason = null;
            var navigation_trigger: ?sandbox_contracts.NpcPlanTrigger = null;
            var navigation_result: ?sandbox_contracts.NpcPlanResult = null;
            var navigation_route_revision: u64 = 0;
            var navigation_topology_revision: u64 = 0;
            var navigation_route_digest: u64 = 0;
            var navigation_route_cost: u32 = 0;
            var navigation_route_length: u8 = 0;
            var navigation_active_prefix_length: u8 = 0;
            var navigation_route_index: u8 = 0;
            var navigation_replan_count: u64 = 0;
            var navigation_arrival_tick: ?u64 = null;
            var navigation_physical_exclusion_count: u8 = 0;
            var navigation_physical_block_retry_tick: u64 = 0;
            const radius = draw.radius;
            const half_height = draw.half_height;
            if (persistent) |id| {
                if (self.simulation.npcs().view(id) catch null) |view| {
                    authority_present = true;
                    authority_position = view.position;
                    velocity = view.velocity;
                    facing_yaw = view.facing_yaw;
                    navigation_progress = switch (view.navigation_progress.state) {
                        .idle => .idle,
                        .moving => .moving,
                        .waiting_for_content => .waiting_for_content,
                        .dormant => .dormant,
                        .potentially_stalled => .potentially_stalled,
                    };
                    navigation_target = view.navigation_progress.target;
                    navigation_no_progress_ticks = view.navigation_progress.no_progress_ticks;
                    navigation_last_progress_tick = view.navigation_progress.last_progress_tick;
                    navigation_destination = switch (view.goal) {
                        .hold => null,
                        .navigate_to => |destination| destination,
                        .patrol_between => |patrol| switch (view.route.patrol_leg) {
                            .toward_second => patrol.second,
                            .none, .toward_first => patrol.first,
                        },
                    };
                    navigation_status = view.navigation_status;
                    navigation_reason = view.navigation_reason;
                    navigation_trigger = view.navigation_lineage.last_trigger;
                    navigation_result = view.navigation_lineage.last_result;
                    navigation_route_revision = view.navigation_lineage.route_revision;
                    navigation_topology_revision = view.navigation_lineage.topology_revision;
                    navigation_route_digest = view.route.plan.digest;
                    navigation_route_cost = view.route.plan.total_cost;
                    navigation_route_length = view.route.plan.len;
                    navigation_active_prefix_length = view.route.plan.active_prefix_len;
                    navigation_route_index = view.route.index;
                    navigation_replan_count = view.navigation_lineage.replan_count;
                    navigation_arrival_tick = view.navigation_lineage.arrival_tick;
                    navigation_physical_exclusion_count =
                        view.physical_edge_exclusion_count;
                    navigation_physical_block_retry_tick =
                        view.physical_block_retry_tick;
                }
            }
            var projected = editor_contract.GameplayEntityView{
                .entity = gameplayEntityRef(draw.entity, draw.incarnation),
                .persistent_id = persistent,
                .kind = .npc,
                .authority_presence = if (authority_present) .present else .absent,
                .replication_presence = .present,
                .presentation_presence = .present,
                .draw_presence = .present,
                .authority_position = authority_position,
                .presentation_position = draw.pose.position,
                .velocity = velocity,
                .facing_yaw = facing_yaw,
                .radius = radius,
                .half_height = half_height,
                .health = draw.health,
                .maximum_health = draw.maximum_health,
                .life_state = gameplayLifeState(draw.life_state),
                .encounter_state = @intFromEnum(draw.encounter_state),
                .attack_windup = draw.combat.windup,
                .deadline_tick = if (draw.encounter_state == .attack_windup)
                    draw.attack_impact_tick
                else
                    draw.attack_ready_tick,
                .navigation_progress = navigation_progress,
                .navigation_target = navigation_target,
                .navigation_no_progress_ticks = navigation_no_progress_ticks,
                .navigation_last_progress_tick = navigation_last_progress_tick,
                .navigation_destination = navigation_destination,
                .navigation_status = navigation_status,
                .navigation_reason = navigation_reason,
                .navigation_trigger = navigation_trigger,
                .navigation_result = navigation_result,
                .navigation_route_revision = navigation_route_revision,
                .navigation_topology_revision = navigation_topology_revision,
                .navigation_route_digest = navigation_route_digest,
                .navigation_route_cost = navigation_route_cost,
                .navigation_route_length = navigation_route_length,
                .navigation_active_prefix_length = navigation_active_prefix_length,
                .navigation_route_index = navigation_route_index,
                .navigation_replan_count = navigation_replan_count,
                .navigation_arrival_tick = navigation_arrival_tick,
                .navigation_physical_exclusion_count = navigation_physical_exclusion_count,
                .navigation_physical_block_retry_tick = navigation_physical_block_retry_tick,
                .population_member = if (draw.population_member == 0)
                    null
                else
                    .{ .value = draw.population_member },
                .population_role = switch (draw.population_role) {
                    .unassigned => null,
                    .resident => .resident,
                    .worker => .worker,
                    .visitor => .visitor,
                },
                .population_disposition = switch (draw.combat_disposition) {
                    .unassigned => null,
                    .passive => .passive,
                    .hostile_to_players => .hostile_to_players,
                },
                .population_activity_kind = switch (draw.activity_kind) {
                    .none => null,
                    .commute => .commute,
                    .shop => .shop,
                    .visit => .visit,
                    .idle => .idle,
                },
                .population_activity_state = switch (draw.activity_state) {
                    .unassigned => null,
                    .selecting => .selecting,
                    .waiting_for_slot => .waiting_for_slot,
                    .traveling => .traveling,
                    .dwelling => .dwelling,
                    .completing => .completing,
                    .interrupted => .interrupted,
                    .vacant => .vacant,
                    .replacement_pending => .replacement_pending,
                },
            };
            applyNpcInterestEvidence(&projected, inspection.npcInterest(draw.entity));
            result.entities[result.entity_count] = projected;
            result.entity_count += 1;
        }

        for (self.product_presentation_trace.tombstoneSlice()) |tombstone| {
            if (result.entity_count == editor_contract.gameplay_entity_capacity) break;
            const prior = tombstone.observation;
            const replicated = sandbox_host.ReplicatedEntityId{
                .index = @truncate(prior.entity.local),
                .generation = @truncate(prior.entity.local >> 32),
            };
            const persistent = inspection.persistentId(replicated);
            var authority_presence: editor_contract.GameplayPresence = .absent;
            var authority_position = prior.position;
            var velocity = prior.velocity;
            var facing_yaw = prior.facing_yaw;
            if (persistent) |id| switch (prior.kind) {
                .local_player, .remote_player => if (self.simulation.characters().view(id) catch null) |view| {
                    authority_presence = .present;
                    authority_position = view.position;
                    velocity = view.velocity;
                    facing_yaw = view.facing_yaw;
                },
                .npc => if (self.simulation.npcs().view(id) catch null) |view| {
                    authority_presence = .present;
                    authority_position = view.position;
                    velocity = view.velocity;
                    facing_yaw = view.facing_yaw;
                },
                .vehicle => if (self.simulation.vehicles().view(id) catch null) |view| {
                    authority_presence = .present;
                    authority_position = view.state.chassis.pose.position;
                    velocity = view.state.chassis.velocity.linear;
                },
                .carryable => if (self.simulation.interactions().view(id) catch null) |view| {
                    authority_presence = .present;
                    authority_position = view.state.pose.position;
                    velocity = view.state.velocity.linear;
                },
            };
            var projected = editor_contract.GameplayEntityView{
                .entity = prior.entity,
                .persistent_id = persistent,
                .kind = switch (prior.kind) {
                    .local_player => .local_player,
                    .remote_player => .remote_player,
                    .npc => .npc,
                    .vehicle => .vehicle,
                    .carryable => .carryable,
                },
                .authority_presence = authority_presence,
                .replication_presence = .absent,
                .presentation_presence = .absent,
                .draw_presence = .absent,
                .removal_reason = if (authority_presence == .present)
                    .replication_removed
                else
                    .authority_removed,
                .removed_tick = tombstone.removed_tick,
                .removed_frame = tombstone.removed_frame,
                .authority_position = authority_position,
                .presentation_position = prior.position,
                .velocity = velocity,
                .facing_yaw = facing_yaw,
                .radius = prior.radius,
                .half_height = prior.half_height,
                .health = prior.health,
                .maximum_health = prior.maximum_health,
                .life_state = @enumFromInt(prior.life_state),
                .encounter_state = prior.encounter_state,
                .attack_windup = prior.attack_windup,
                .deadline_tick = prior.deadline_tick,
            };
            if (prior.kind == .npc) {
                applyNpcInterestEvidence(&projected, inspection.npcInterest(replicated));
                if (projected.relevance_included == false) {
                    projected.removal_reason = .relevance;
                }
            } else if (prior.kind == .vehicle) {
                applyObjectInterestEvidence(&projected, inspection.vehicleInterest(replicated));
                if (projected.relevance_included == false) {
                    projected.removal_reason = .relevance;
                }
            } else if (prior.kind == .carryable) {
                applyObjectInterestEvidence(&projected, inspection.carryableInterest(replicated));
                if (projected.relevance_included == false) {
                    projected.removal_reason = .relevance;
                }
            }
            result.entities[result.entity_count] = projected;
            result.entity_count += 1;
        }

        // Complete the causal union with bounded authority identities that
        // have not reached the local client/presentation projection. This is
        // the evidence that the original seam disappearance was missing.
        for (0..session_budgets.max_vehicles) |slot_index| {
            if (result.entity_count == editor_contract.gameplay_entity_capacity) break;
            const identity = inspection.vehicleIdentity(slot_index) orelse continue;
            const entity = gameplayEntityRef(
                identity.replicated,
                identity.replicated.generation,
            );
            if (gameplayViewContains(&result, entity)) continue;
            const authority_view = self.simulation.vehicles().view(identity.persistent) catch
                continue;
            const interest = inspection.vehicleInterest(identity.replicated);
            const half_extents = (sandbox_contracts.VehicleConfig{})
                .tuning.chassis_half_extents;
            var projected = editor_contract.GameplayEntityView{
                .entity = entity,
                .persistent_id = identity.persistent,
                .kind = .vehicle,
                .authority_presence = .present,
                .replication_presence = .absent,
                .presentation_presence = .absent,
                .draw_presence = .absent,
                .removal_reason = if (interest) |value|
                    if (value.included) .replication_removed else .relevance
                else
                    .unknown,
                .removed_tick = if (interest) |value| value.evaluated_tick else 0,
                .authority_position = authority_view.state.chassis.pose.position,
                .presentation_position = if (interest) |value|
                    value.object_position
                else
                    authority_view.state.chassis.pose.position,
                .velocity = authority_view.state.chassis.velocity.linear,
                .radius = @max(half_extents[0], half_extents[2]),
                .half_height = half_extents[1],
                .health = 0,
                .maximum_health = 0,
                .life_state = .unknown,
            };
            applyObjectInterestEvidence(&projected, interest);
            result.entities[result.entity_count] = projected;
            result.entity_count += 1;
        }
        for (0..session_budgets.max_carryables) |slot_index| {
            if (result.entity_count == editor_contract.gameplay_entity_capacity) break;
            const identity = inspection.carryableIdentity(slot_index) orelse continue;
            const entity = gameplayEntityRef(
                identity.replicated,
                identity.replicated.generation,
            );
            if (gameplayViewContains(&result, entity)) continue;
            const authority_view = self.simulation.interactions().view(identity.persistent) catch
                continue;
            const interest = inspection.carryableInterest(identity.replicated);
            const position = if (interest) |value|
                value.object_position
            else
                authority_view.state.pose.position;
            var projected = editor_contract.GameplayEntityView{
                .entity = entity,
                .persistent_id = identity.persistent,
                .kind = .carryable,
                .authority_presence = .present,
                .replication_presence = .absent,
                .presentation_presence = .absent,
                .draw_presence = .absent,
                .removal_reason = if (interest) |value|
                    if (value.included) .replication_removed else .relevance
                else
                    .unknown,
                .removed_tick = if (interest) |value| value.evaluated_tick else 0,
                .authority_position = position,
                .presentation_position = position,
                .velocity = authority_view.state.velocity.linear,
                .radius = @max(
                    authority_view.half_extents[0],
                    authority_view.half_extents[2],
                ),
                .half_height = authority_view.half_extents[1],
                .health = 0,
                .maximum_health = 0,
                .life_state = .unknown,
            };
            applyObjectInterestEvidence(&projected, interest);
            result.entities[result.entity_count] = projected;
            result.entity_count += 1;
        }

        const entities = result.entitySlice();
        for (0..entities.len) |first_index| {
            var nearest: ?f32 = null;
            for (entities, 0..) |second, second_index| {
                if (first_index == second_index) continue;
                const first = result.entities[first_index];
                const dx = first.presentation_position[0] - second.presentation_position[0];
                const dz = first.presentation_position[2] - second.presentation_position[2];
                const separation = @sqrt(dx * dx + dz * dz);
                nearest = if (nearest) |value| @min(value, separation) else separation;
            }
            result.entities[first_index].nearest_actor_separation = nearest;
        }
        return result;
    }

    fn actionFeedbackReason(
        kind: engine.gameplay_trace.Kind,
        domain: engine.gameplay_trace.ReasonDomain,
        reason: u32,
    ) []const u8 {
        return switch (domain) {
            .none => "none",
            .error_code => if (reason == 0 or reason > std.math.maxInt(u16))
                "unknown_error"
            else
                @errorName(@errorFromInt(@as(u16, @intCast(reason)))),
            .protocol_disposition => switch (kind) {
                .vehicle_toggle => enumFeedbackReasonName(
                    sandbox_host.VehicleActionDisposition,
                    reason,
                    "unknown_vehicle_disposition",
                ),
                .carry_toggle => enumFeedbackReasonName(
                    sandbox_host.InteractionActionDisposition,
                    reason,
                    "unknown_interaction_disposition",
                ),
                .melee => enumFeedbackReasonName(
                    sandbox_host.MeleeActionDisposition,
                    reason,
                    "unknown_melee_disposition",
                ),
                .firearm => enumFeedbackReasonName(
                    sandbox_host.WeaponActionDisposition,
                    reason,
                    "unknown_weapon_disposition",
                ),
                .respawn => enumFeedbackReasonName(
                    sandbox_host.RespawnActionDisposition,
                    reason,
                    "unknown_respawn_disposition",
                ),
                else => "protocol_disposition",
            },
            .navigation_reason => if (std.enums.fromInt(
                sandbox_contracts.NpcNavigationReason,
                reason,
            )) |value|
                @tagName(value)
            else
                "unknown_navigation_reason",
            .population_transition => if (std.enums.fromInt(
                population.TransitionReason,
                reason,
            )) |value|
                @tagName(value)
            else
                "unknown_population_transition",
            .validation_code => "validation_code",
        };
    }

    fn enumFeedbackReasonName(
        comptime E: type,
        reason: u32,
        fallback: []const u8,
    ) []const u8 {
        const value = std.enums.fromInt(E, reason) orelse return fallback;
        return @tagName(value);
    }

    fn updateProductTitle(
        self: *App,
        character_draws: []const sandbox_host.CharacterDraw,
        npc_draws: []const sandbox_host.NpcDraw,
        hud: combat_presentation.LocalHud,
    ) void {
        var local_hurt = false;
        for (character_draws) |draw| {
            if (draw.local_player and draw.combat.hit_flash) local_hurt = true;
        }
        var npc_state: []const u8 = "none";
        var npc_health: u16 = 0;
        var npc_maximum_health: u16 = 0;
        var attack_remaining: u64 = 0;
        for (npc_draws) |draw| {
            if (draw.life_state == .dead) {
                npc_state = "DEAD - REPLACEMENT PENDING";
                npc_health = draw.health;
                npc_maximum_health = draw.maximum_health;
                break;
            }
            if (draw.encounter_state == .patrolling and draw.life_state == .alive) continue;
            npc_state = @tagName(draw.encounter_state);
            npc_health = draw.health;
            npc_maximum_health = draw.maximum_health;
            attack_remaining = draw.attack_impact_tick -| hud.authority_tick;
            break;
        }
        if (std.mem.eql(u8, npc_state, "none")) {
            if (self.simulation.developer().diagnostics().population) |population_diagnostics| {
                if (population_diagnostics.replacement_pending != 0 or
                    population_diagnostics.awaiting_spawn != 0)
                {
                    npc_state = "REPLACEMENT PENDING";
                }
            }
        }
        const feedback = self.product_feedback.current(hud.authority_tick);
        const action = if (feedback) |value| @tagName(value.kind) else "none";
        const disposition = if (feedback) |value|
            @tagName(value.disposition)
        else
            "none";
        const reason = if (feedback) |value|
            actionFeedbackReason(value.kind, value.reason_domain, value.reason)
        else
            "none";
        const respawn = if (hud.life_state == .dead)
            if (hud.respawn_remaining_ticks == 0) "PRESS R TO RESPAWN" else "respawn cooling down"
        else
            "alive";
        const damage = if (hud.life_state == .dead)
            "DEAD"
        else if (local_hurt)
            "DAMAGE RECEIVED"
        else
            "healthy";
        const melee_result = if (hud.latest_melee_disposition) |value|
            @tagName(value)
        else
            "none";
        const respawn_result = if (hud.latest_respawn_disposition) |value|
            @tagName(value)
        else
            "none";
        const weapon_result = if (hud.latest_weapon_disposition) |value|
            @tagName(value)
        else
            "none";
        var storage: [512]u8 = undefined;
        const title = std.fmt.bufPrintZ(
            &storage,
            "Incinerator | HP {d}/{d} {s} | handgun {s} {d}/{d} fire {d}t reload {d}t/{s} | {s} {d}t | melee {d}t/{s} | NPC {s} HP {d}/{d} attack {d}t | action {s}/{s}/{s} | respawn-result {s}",
            .{
                hud.health,
                hud.maximum_health,
                damage,
                @tagName(hud.weapon_mode),
                hud.magazine_ammo,
                hud.reserve_ammo,
                hud.weapon_remaining_ticks,
                hud.reload_remaining_ticks,
                weapon_result,
                respawn,
                hud.respawn_remaining_ticks,
                hud.melee_remaining_ticks,
                melee_result,
                npc_state,
                npc_health,
                npc_maximum_health,
                attack_remaining,
                action,
                disposition,
                reason,
                respawn_result,
            },
        ) catch return;
        _ = c.SDL_SetWindowTitle(self.window, title.ptr);
    }

    fn drawDeveloperOverlay(
        self: *App,
        gameplay_view: *const editor_contract.GameplayView,
    ) !void {
        self.authoring_requests.clear();
        self.interaction_requests.clear();
        self.navigation_requests.clear();
        defer {
            self.authoring_requests.clear();
            self.interaction_requests.clear();
            self.navigation_requests.clear();
        }
        const authoring_view = try self.crateAuthoringView();
        const interaction_view = try self.interactionEditorView();
        const gates = self.simulation.developer().navigationGateState();
        const navigation_view = editor_contract.NavigationLabView{
            .north_gate_open = gates.north_open,
            .south_gate_open = gates.south_open,
            .topology_revision = gates.topology_revision,
        };
        const inspection = self.simulation.inspection();
        const population_view = editor_contract.PopulationView{
            .catalog = inspection.populationCatalog(),
            .members = inspection.populationMembers(),
            .slots = inspection.populationSlots(),
            .diagnostics = inspection.populationDiagnostics(),
        };
        const render_stats = self.gpu_renderer.frameStats();
        const render_view = editor_contract.RenderView{
            .scene_light = self.gpu_renderer.sceneLight(),
            .frame_stats = render_stats,
            .last_semantic = if (self.render_frame_audit.valid)
                @tagName(self.render_frame_audit.semantic)
            else
                "none",
            .last_part = if (self.render_frame_audit.valid)
                @tagName(self.render_frame_audit.part)
            else
                "none",
            .last_ordinal = self.render_frame_audit.ordinal,
            .last_surface = if (self.render_frame_audit.valid)
                @tagName(self.render_frame_audit.surface)
            else
                "none",
        };
        var neural_view = editor_contract.NeuralView{};
        if (self.neural_inputs) |*inputs| {
            const diagnostics = inputs.diagnostics();
            neural_view = .{
                .available = diagnostics.available,
                .schema_version = diagnostics.schema_version,
                .schema_name = diagnostics.schema_name,
                .schema_fingerprint = diagnostics.schema_fingerprint,
                .shader_fingerprint = diagnostics.shader_fingerprint,
                .authority_tick = diagnostics.authority_tick,
                .presentation_frame = diagnostics.presentation_frame,
                .draw_count = diagnostics.draw_count,
                .history_valid_draws = diagnostics.history_valid_draws,
                .history_reset_draws = diagnostics.history_reset_draws,
                .global_controls = diagnostics.global_controls,
                .compact_id_collisions = diagnostics.compact_id_collisions,
                .rendered_frames = diagnostics.rendered_frames,
                .render_failures = diagnostics.render_failures,
                .last_error = diagnostics.last_error,
            };
            for (diagnostics.views, 0..) |view, index| {
                neural_view.textures[index] = .{
                    .channel = view.channel,
                    .binding = view.binding,
                    .width = view.width,
                    .height = view.height,
                };
            }
        }
        if (self.neural_rendering) |*neural| {
            const diagnostics = neural.diagnostics();
            neural_view.model_loaded = diagnostics.model_loaded;
            neural_view.model_enabled = diagnostics.enabled;
            neural_view.model_output_ready = diagnostics.output_ready;
            neural_view.model_bundle_root = diagnostics.bundle_root;
            neural_view.model_checkpoint_digest = diagnostics.checkpoint_digest;
            neural_view.model_manifest_digest = diagnostics.manifest_digest;
            neural_view.model_readbacks = diagnostics.readbacks;
            neural_view.model_predictions = diagnostics.predictions;
            neural_view.model_failures = diagnostics.failures;
            neural_view.model_last_source_tick = diagnostics.last_source_tick;
            neural_view.model_last_source_frame = diagnostics.last_source_frame;
            neural_view.model_last_presented_source_frame = diagnostics.last_presented_source_frame;
            neural_view.model_unknown_semantic_pixels = diagnostics.last_unknown_semantic_pixels;
            neural_view.model_unknown_instance_pixels = diagnostics.last_unknown_instance_pixels;
            neural_view.model_inference_ms = diagnostics.last_inference_ms;
            neural_view.model_pipeline_mean_ms = diagnostics.mean_staged_pipeline_ms;
            neural_view.model_pipeline_maximum_ms = diagnostics.maximum_staged_pipeline_ms;
            if (diagnostics.output_ready) neural_view.model_output = .{
                .binding = diagnostics.output.binding,
                .width = diagnostics.output.width,
                .height = diagnostics.output.height,
            };
            if (neural_view.last_error.len == 0) {
                neural_view.last_error = diagnostics.last_error;
            }
        }
        if (self.neural_capture) |*capture| {
            const diagnostics = capture.diagnostics();
            neural_view.capture_active = true;
            neural_view.capture_root = diagnostics.root;
            neural_view.capture_cohort = @tagName(diagnostics.cohort);
            neural_view.capture_sequence = diagnostics.sequence;
            neural_view.capture_camera_path = diagnostics.camera_path;
            neural_view.capture_recorded_frames = diagnostics.recorded_frames;
            neural_view.capture_requested_frames = diagnostics.requested_frames;
            neural_view.capture_failures = diagnostics.capture_failures;
        }
        self.applyDeveloperEffects(try self.developer.drawEditor(
            &self.gpu_renderer,
            self.developerAuthorityPort(),
            self.developerStreamingPort(),
            .{
                .camera = &self.game_camera,
                .frame_timer = &self.frame_timer,
                .include_district_streams = self.includeDeveloperDistrictStreams(),
                .authoring = .{
                    .view = &authoring_view,
                    .requests = &self.authoring_requests,
                },
                .interaction = .{
                    .view = &interaction_view,
                    .requests = &self.interaction_requests,
                },
                .navigation = .{
                    .view = &navigation_view,
                    .gameplay = gameplay_view,
                    .requests = &self.navigation_requests,
                },
                .population_view = &population_view,
                .render_view = &render_view,
                .gameplay_view = gameplay_view,
                .neural_view = &neural_view,
                .authored_change = self.latest_authoring_change,
                .developer_endpoint = self.developerEndpointDiscovery(),
                .incident_input = .{
                    .move_forward = self.input_buffer.isKeyDown(input.Key.W),
                    .move_backward = self.input_buffer.isKeyDown(input.Key.S),
                    .move_left = self.input_buffer.isKeyDown(input.Key.A),
                    .move_right = self.input_buffer.isKeyDown(input.Key.D),
                    .interact = self.input_buffer.isKeyDown(input.Key.E),
                    .carry = self.input_buffer.isKeyDown(input.Key.F),
                    .attack = self.input_buffer.isKeyDown(input.Key.Q),
                    .respawn = self.input_buffer.isKeyDown(input.Key.R),
                    .jump_or_brake = self.input_buffer.isKeyDown(input.Key.SPACE),
                    .interact_pressed = self.input_buffer.isKeyPressed(input.Key.E),
                    .carry_pressed = self.input_buffer.isKeyPressed(input.Key.F),
                    .attack_pressed = self.input_buffer.isKeyPressed(input.Key.Q),
                    .weapon_toggle_pressed = self.input_buffer.isKeyPressed(input.Key.NUM_1),
                    .fire_pressed = self.input_buffer.isMouseButtonPressed(input.MouseButton.LEFT),
                    .reload_pressed = self.input_buffer.isKeyPressed(input.Key.R) and
                        gameplay_view.local_life_state != .dead,
                    .respawn_pressed = self.input_buffer.isKeyPressed(input.Key.R),
                    .jump_pressed = self.input_buffer.isKeyPressed(input.Key.SPACE),
                    .hand_brake = self.input_buffer.isKeyDown(input.Key.LSHIFT),
                    .right_mouse = self.input_buffer.isMouseButtonDown(2),
                    .mouse_delta_x = self.input_buffer.mouse_delta_x,
                    .mouse_delta_y = self.input_buffer.mouse_delta_y,
                    .keyboard_captured = self.input_buffer.keyboard_captured,
                    .mouse_captured = self.input_buffer.mouse_captured,
                    .window_minimized = self.input_buffer.window_minimized,
                },
            },
        ));
        try self.applyAuthoringRequests(self.authoring_requests.slice());
        try self.applyInteractionRequests(self.interaction_requests.slice());
        try self.applyNavigationRequests(self.navigation_requests.slice());
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
        const gameplay_view = editor_contract.GameplayView{
            .authority_tick = self.simulation.inspection().tickIndex(),
            .presentation_frame = self.frame_timer.total_frames,
        };
        try self.drawDeveloperOverlay(&gameplay_view);
        try self.submitCurrentFrame();
        return true;
    }
};

fn validateIncidentHardening(
    profile: incident_capture.HardeningProfile,
    snapshot: sandbox_developer_host.Owner.IncidentHardeningSnapshot,
) !void {
    if (profile == .none or snapshot.clipboard_publications == 0) {
        return error.IncidentHardeningClipboardMissing;
    }
    switch (profile) {
        .none => unreachable,
        .queue_pressure => {
            if (snapshot.queue_high_water != incident_capture.writer_queue_capacity or
                snapshot.dropped_records == 0 or snapshot.writer_failed or
                !snapshot.handoff_persisted)
            {
                return error.IncidentQueuePressureContractFailed;
            }
        },
        .visual_budget => {
            if (!snapshot.visual_budget_exhausted or
                snapshot.visual_budget_rejections == 0 or
                snapshot.writer_failed or !snapshot.handoff_persisted)
            {
                return error.IncidentVisualBudgetContractFailed;
            }
        },
        .writer_budget => {
            if (!snapshot.writer_failed or snapshot.handoff_persisted) {
                return error.IncidentWriterBudgetContractFailed;
            }
        },
        .screenshot_submission => {
            if (snapshot.screenshot_misses == 0 or
                snapshot.screenshot_fence_failures != 0 or
                snapshot.writer_failed or !snapshot.handoff_persisted)
            {
                return error.IncidentScreenshotSubmissionContractFailed;
            }
        },
        .screenshot_fence => {
            if (snapshot.screenshot_misses == 0 or
                snapshot.screenshot_fence_failures == 0 or
                snapshot.writer_failed or !snapshot.handoff_persisted)
            {
                return error.IncidentScreenshotFenceContractFailed;
            }
        },
    }
}

fn captureHardeningProfile(
    profile: sandbox_invocation.IncidentHardeningProfile,
) incident_capture.HardeningProfile {
    return switch (profile) {
        .queue_pressure => .queue_pressure,
        .visual_budget => .visual_budget,
        .writer_budget => .writer_budget,
        .screenshot_submission => .screenshot_submission,
        .screenshot_fence => .screenshot_fence,
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
            without_debug_pipelines.developer.physicsDebugAvailable())
        {
            return error.OptionalPhysicsDebugPipelineIsolationFailed;
        }
        const tick_before = without_debug_pipelines.simulation.inspection().tickIndex();
        try without_debug_pipelines.simulation.lifecycle().tick();
        const tick_after = without_debug_pipelines.simulation.inspection().tickIndex();
        if (tick_after != tick_before +| 1) {
            return error.OptionalPhysicsDebugPipelineAuthorityDidNotAdvance;
        }
        std.debug.print(
            "INIT_OPTIONAL_PHYSICS_DEBUG_PIPELINES authority_tick={d} overlay_available=false\n",
            .{tick_after},
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
    const editor_startup = try sandbox_invocation.parseEditorStartup(args);
    const configured_content_root = try parseContentRootOverride(args);
    const resolved_content_root = try sandbox_invocation.resolveContentRoot(
        init.io,
        init.arena.allocator(),
        configured_content_root orelse if (init.environ_map.get(
            "INCINERATOR_CONTENT_ROOT",
        )) |environment_root|
            try content.ContentRootPath.parse(environment_root)
        else
            null,
        .product,
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
    const hardening_profile: incident_capture.HardeningProfile = switch (mode) {
        .incident_hardening => |profile| captureHardeningProfile(profile),
        else => .none,
    };
    const incident_runs_root = if (build_options.incident_capture_enabled) root: {
        if (init.environ_map.get("INCINERATOR_INCIDENT_ROOT")) |override| {
            break :root override;
        }
        const home = init.environ_map.get("HOME") orelse return error.HomeDirectoryUnavailable;
        break :root try std.fmt.allocPrint(
            init.arena.allocator(),
            "{s}/Library/Logs/Incinerator/runs",
            .{home},
        );
    } else null;
    var app = try App.initProduct(
        init.io,
        resolved_content_root,
        configured_save_root,
        incident_runs_root,
        hardening_profile,
    );
    app.developer.configureEditor(editor_startup);
    var app_deinitialized = false;
    defer if (!app_deinitialized) app.deinit();
    try app.configureNeuralRendering(init.environ_map);
    switch (mode) {
        .incident_smoke => {
            try app.runIncidentCaptureSmoke();
            std.debug.print(
                "INCIDENT_CAPTURE_SMOKE_RESULT run={s}\n",
                .{app.developer.incidentRunPath() orelse "unavailable"},
            );
        },
        .incident_benchmark => {
            try app.runIncidentCaptureBenchmark();
            const shutdown_started_ns = std.Io.Clock.Timestamp.now(
                init.io,
                .awake,
            ).raw.nanoseconds;
            app.deinit();
            app_deinitialized = true;
            const shutdown_finished_ns = std.Io.Clock.Timestamp.now(
                init.io,
                .awake,
            ).raw.nanoseconds;
            std.debug.print(
                "INCIDENT_CAPTURE_BENCHMARK_SHUTDOWN capture={} latency_ns={d}\n",
                .{
                    build_options.incident_capture_enabled,
                    @max(shutdown_finished_ns - shutdown_started_ns, 0),
                },
            );
        },
        .incident_journey => {
            try app.runIncidentCaptureJourney();
            std.debug.print(
                "INCIDENT_CAPTURE_JOURNEY_RESULT run={s}\n",
                .{app.developer.incidentRunPath() orelse "unavailable"},
            );
        },
        .incident_journey_window => {
            try app.runIncidentCaptureWindowJourney();
            std.debug.print(
                "INCIDENT_CAPTURE_WINDOW_JOURNEY_RESULT run={s}\n",
                .{app.developer.incidentRunPath() orelse "unavailable"},
            );
        },
        .incident_hardening => {
            const snapshot = try app.runIncidentCaptureHardening(hardening_profile);
            std.debug.print(
                "INCIDENT_HARDENING_RESULT profile={s} run={s} " ++
                    "writer_failed={} visual_budget_exhausted={} " ++
                    "handoff_persisted={} queue_high_water={d} dropped={d} " ++
                    "visual_rejections={d} screenshot_misses={d} " ++
                    "fence_failures={d} clipboard_publications={d}\n",
                .{
                    @tagName(hardening_profile),
                    app.developer.incidentRunPath() orelse "unavailable",
                    snapshot.writer_failed,
                    snapshot.visual_budget_exhausted,
                    snapshot.handoff_persisted,
                    snapshot.queue_high_water,
                    snapshot.dropped_records,
                    snapshot.visual_budget_rejections,
                    snapshot.screenshot_misses,
                    snapshot.screenshot_fence_failures,
                    snapshot.clipboard_publications,
                },
            );
        },
        .incident_replay => |run_path| try app.runIncidentReplay(run_path),
        .normal => try app.runProduct(),
        .verify_install => unreachable,
    }
}

fn initValidationApp(
    io: std.Io,
    mode: ProgramMode,
    content_root: ?content.ContentRootPath,
    save_root: ?SaveRootPath,
) !App {
    return switch (mode) {
        .normal,
        .s4_physics_debug_smoke,
        .s11_combat_smoke,
        .s13_population_smoke,
        .s14_ranged_combat_smoke,
        => initValidationAppWithProfile(
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
        .nr0_evaluation_smoke => initValidationAppWithProfile(
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
    save_root: ?SaveRootPath,
) !App {
    if (save_root) |root| {
        return App.initWithSaveRoot(io, profile, content_root, root);
    }
    return App.init(io, profile, content_root);
}

fn validationMain(init: std.process.Init, args: anytype) !void {
    const mode = try parseProgramMode(args);
    const editor_startup = try sandbox_invocation.parseEditorStartup(args);
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
        .s11_combat_smoke,
        .s13_population_smoke,
        .s14_ranged_combat_smoke,
        .nr0_evaluation_smoke,
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
        .s11_combat_smoke,
        .s13_population_smoke,
        .s14_ranged_combat_smoke,
        .nr0_evaluation_smoke,
        .s4_diagnostics_smoke,
        .s4_physics_debug_smoke,
        .s5_authoring_smoke,
        => try sandbox_invocation.resolveContentRoot(
            init.io,
            init.arena.allocator(),
            configured_content_root,
            .validation,
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
    app.developer.configureEditor(editor_startup);
    if (mode == .nr0_evaluation_smoke) {
        app.neural_evaluation_fixture_enabled = true;
    }
    try app.configureNeuralRendering(init.environ_map);
    var visual_smoke_succeeded = false;
    var s1_visual_smoke_succeeded = false;
    var s2_visual_smoke_succeeded = false;
    var s3_streaming_smoke_succeeded = false;
    var s6_streaming_smoke_succeeded = false;
    var s7_interaction_smoke_succeeded = false;
    var s8_population_smoke_succeeded = false;
    var s11_combat_smoke_succeeded = false;
    var s13_population_smoke_succeeded = false;
    var s14_ranged_combat_smoke_succeeded = false;
    var nr0_evaluation_smoke_succeeded = false;
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
        if (s11_combat_smoke_succeeded) {
            std.debug.print("S11_COMBAT_SMOKE_SHUTDOWN status=clean\n", .{});
        }
        if (s13_population_smoke_succeeded) {
            std.debug.print("S13_POPULATION_SMOKE_SHUTDOWN status=clean\n", .{});
        }
        if (s14_ranged_combat_smoke_succeeded) {
            std.debug.print("S14_RANGED_COMBAT_SMOKE_SHUTDOWN status=clean\n", .{});
        }
        if (nr0_evaluation_smoke_succeeded) {
            std.debug.print("NR0_EVALUATION_SMOKE_SHUTDOWN status=clean\n", .{});
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
                    app.simulation.inspection().tickIndex(),
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
                    app.simulation.inspection().tickIndex(),
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
                    "steering_observed={} wheel_spin={} wheel_steering={} " ++
                    "brake_applied={} hand_brake_applied={} " ++
                    "crate_displaced={} character_hidden={} " ++
                    "character_restored={} exited={} ticks={d} alpha_min={d:.6} " ++
                    "alpha_max={d:.6} virtual_render_hz={d} gpu_driver={s}\n",
                .{
                    summary.ready_frames,
                    summary.unavailable_frames,
                    summary.attempted_frames,
                    summary.vehicle_presented_frames,
                    app.validation.s2_smoke.vehicle_moved,
                    app.validation.s2_smoke.steering_observed,
                    app.validation.s2_smoke.wheel_spin_presented,
                    app.validation.s2_smoke.wheel_steering_presented,
                    app.validation.s2_smoke.brake_applied,
                    app.validation.s2_smoke.hand_brake_applied,
                    app.validation.s2_smoke.crate_displaced,
                    summary.character_hidden_while_driving,
                    summary.character_visible_after_exit,
                    app.validation.s2_smoke.exited,
                    app.simulation.inspection().tickIndex(),
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
                    "physical_after_content_unload={} stable_after_content_reload={} " ++
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
                    summary.physical_after_content_unload,
                    summary.stable_after_content_reload,
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
            const npc = app.simulation.developer().diagnostics().npc;
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
        .s11_combat_smoke => |config| {
            const summary = try app.runValidation(config, .s11_combat);
            const evidence = app.validation.s11_combat;
            std.debug.print(
                "S11_COMBAT_SMOKE_RESULT frames={d} ticks={d} target_selected={} " ++
                    "melee_hits={d} player_dead={} respawned={} npc_killed={} " ++
                    "character_bar={} npc_bar={} character_flash={} " ++
                    "character_flash_expired={} npc_flash={} npc_flash_expired={} " ++
                    "windup={} cooldown_marker={} respawn_countdown={} " ++
                    "respawn_ready={} retained_anchor={} player_death_body={} " ++
                    "respawned_character={} " ++
                    "npc_death={} product_hud_health={} product_hud_damage={} " ++
                    "product_hud_death={} product_hud_windup={} " ++
                    "product_hud_respawn_countdown={} product_hud_respawn_ready={} " ++
                    "product_hud_action={} virtual_render_hz={d} gpu_driver={s}\n",
                .{
                    summary.ready_frames,
                    app.simulation.inspection().tickIndex() -| app.validation_tick_origin,
                    evidence.target_selected,
                    evidence.accepted_melee_hits,
                    evidence.player_dead,
                    evidence.respawn_accepted,
                    evidence.npc_killed,
                    evidence.character_bar_drawn,
                    evidence.npc_bar_drawn,
                    evidence.character_hit_flash_drawn,
                    evidence.character_hit_flash_expired,
                    evidence.npc_hit_flash_drawn,
                    evidence.npc_hit_flash_expired,
                    evidence.npc_windup_drawn,
                    evidence.melee_cooldown_marker_drawn,
                    evidence.respawn_countdown_marker_drawn,
                    evidence.respawn_ready_marker_drawn,
                    evidence.dead_hud_anchor_drawn,
                    evidence.player_death_drawn,
                    evidence.respawned_character_drawn,
                    evidence.npc_death_drawn,
                    evidence.product_hud_health,
                    evidence.product_hud_damage,
                    evidence.product_hud_death,
                    evidence.product_hud_windup,
                    evidence.product_hud_respawn_countdown,
                    evidence.product_hud_respawn_ready,
                    evidence.product_hud_action_feedback,
                    config.virtual_render_hz,
                    shader_assets.driver,
                },
            );
            std.debug.print(
                "S11_VISIBILITY_RESULT contact={} player_death={} respawn={} " ++
                    "npc_death={} observations={d} bounds={} captures={d}\n",
                .{
                    evidence.visibility_contact,
                    evidence.visibility_player_death,
                    evidence.visibility_respawn,
                    evidence.visibility_npc_death,
                    evidence.visibility_observations,
                    evidence.visibility_bounds_valid,
                    if (build_options.validation_mode)
                        app.visibility_oracle.?.captures
                    else
                        0,
                },
            );
            s11_combat_smoke_succeeded = true;
        },
        .s13_population_smoke => |config| {
            const summary = try app.runValidation(config, .s13_population);
            const evidence = app.validation.s13_population;
            const diagnostics = app.simulation.inspection().populationDiagnostics().?;
            std.debug.print(
                "S13_POPULATION_SMOKE_RESULT frames={d} ticks={d} " ++
                    "zero_tick_frames={d} multi_tick_frames={d} " ++
                    "full_cohort_frames={d} incomplete_after_full={d} " ++
                    "peak_draws={d} roles={}/{}/{} traveling={} dwelling={} " ++
                    "waiting={} live={d} contentions={d} decisions={d} " ++
                    "virtual_render_hz={d} gpu_driver={s}\n",
                .{
                    summary.ready_frames,
                    app.simulation.inspection().tickIndex() -| app.validation_tick_origin,
                    summary.zero_tick_frames,
                    summary.multi_tick_frames,
                    evidence.full_cohort_frames,
                    evidence.incomplete_after_full_frames,
                    evidence.peak_draws,
                    evidence.resident_seen,
                    evidence.worker_seen,
                    evidence.visitor_seen,
                    evidence.traveling_seen,
                    evidence.dwelling_seen,
                    evidence.waiting_seen,
                    diagnostics.live,
                    diagnostics.slot_contentions,
                    diagnostics.decisions,
                    config.virtual_render_hz,
                    shader_assets.driver,
                },
            );
            s13_population_smoke_succeeded = true;
        },
        .s14_ranged_combat_smoke => |config| {
            const summary = try app.runValidation(config, .s14_ranged_combat);
            const evidence = app.validation.s14_ranged_combat;
            std.debug.print(
                "S14_RANGED_COMBAT_SMOKE_RESULT frames={d} ticks={d} " ++
                    "target={} equipped={} drain={d} cadence={} empty={} " ++
                    "reload={}/{} hits={d} killed={} death_draw={} " ++
                    "replacement={} weapon_draw={} tracer_draw={} hud={} " ++
                    "virtual_render_hz={d} gpu_driver={s}\n",
                .{
                    summary.ready_frames,
                    app.simulation.inspection().tickIndex() -| app.validation_tick_origin,
                    evidence.target_selected,
                    evidence.equipped,
                    evidence.committed_drain_shots,
                    evidence.cadence_rejected,
                    evidence.empty_rejected,
                    evidence.reload_started,
                    evidence.reload_completed,
                    evidence.hit_count,
                    evidence.target_killed,
                    evidence.target_death_drawn,
                    evidence.target_replaced,
                    evidence.weapon_drawn,
                    evidence.tracer_drawn,
                    evidence.ammo_hud_observed,
                    config.virtual_render_hz,
                    shader_assets.driver,
                },
            );
            s14_ranged_combat_smoke_succeeded = true;
        },
        .nr0_evaluation_smoke => |config| {
            const summary = try app.runValidation(config, .none);
            const diagnostics = if (app.neural_inputs) |*inputs|
                inputs.diagnostics()
            else
                return error.NeuralEvaluationInputHostUnavailable;
            if (app.neural_trial_fixture_enabled) {
                const model_diagnostics = if (app.neural_rendering) |*neural|
                    neural.diagnostics()
                else
                    return error.NeuralTrialModelHostUnavailable;
                if (!model_diagnostics.model_loaded or
                    !model_diagnostics.output_ready or
                    model_diagnostics.predictions == 0 or
                    model_diagnostics.failures != 0 or
                    model_diagnostics.last_source_frame <
                        model_diagnostics.last_presented_source_frame)
                {
                    return error.NeuralTrialRuntimeAcceptanceFailed;
                }
                if (init.environ_map.get("INCINERATOR_NR_TRIAL_EVIDENCE_ROOT")) |root| {
                    try app.neural_rendering.?.writeEvaluationEvidence(root);
                }
                std.debug.print(
                    "RF10_TRIAL_SMOKE_RESULT frames={d} ticks={d} " ++
                        "fixture_draws={d} neural_draws={d} readbacks={d} " ++
                        "predictions={d} failures={d} inference_ms={d:.3} " ++
                        "pipeline_mean_ms={d:.3} pipeline_max_ms={d:.3} " ++
                        "source_frame={d} presented_source_frame={d} " ++
                        "unknown_semantic={d} unknown_instance={d} " ++
                        "fixture_fingerprint={s} virtual_render_hz={d} gpu_driver={s}\n",
                    .{
                        summary.ready_frames,
                        app.simulation.inspection().tickIndex() -| app.validation_tick_origin,
                        neural_target_fixture.draw_count,
                        diagnostics.draw_count,
                        model_diagnostics.readbacks,
                        model_diagnostics.predictions,
                        model_diagnostics.failures,
                        model_diagnostics.last_inference_ms,
                        model_diagnostics.mean_staged_pipeline_ms,
                        model_diagnostics.maximum_staged_pipeline_ms,
                        model_diagnostics.last_source_frame,
                        model_diagnostics.last_presented_source_frame,
                        model_diagnostics.last_unknown_semantic_pixels,
                        model_diagnostics.last_unknown_instance_pixels,
                        neural_target_fixture.source_fingerprint,
                        config.virtual_render_hz,
                        shader_assets.driver,
                    },
                );
            } else if (app.neural_target_fixture_enabled) {
                const target_diagnostics = app.neural_target_frames.?.diagnostics();
                std.debug.print(
                    "NR4_TARGET_SMOKE_RESULT frames={d} ticks={d} " ++
                        "fixture_draws={d} neural_draws={d} exported={d}/{d} " ++
                        "export_failures={d} fixture_fingerprint={s} " ++
                        "virtual_render_hz={d} gpu_driver={s}\n",
                    .{
                        summary.ready_frames,
                        app.simulation.inspection().tickIndex() -| app.validation_tick_origin,
                        neural_target_fixture.draw_count,
                        diagnostics.draw_count,
                        target_diagnostics.recorded_frames,
                        target_diagnostics.requested_frames,
                        target_diagnostics.failures,
                        neural_target_fixture.source_fingerprint,
                        config.virtual_render_hz,
                        shader_assets.driver,
                    },
                );
            } else {
                std.debug.print(
                    "NR0_EVALUATION_SMOKE_RESULT frames={d} ticks={d} " ++
                        "fixture_draws={d} neural_draws={d} history_valid={d} " ++
                        "history_reset={d} fixture_fingerprint={s} " ++
                        "virtual_render_hz={d} gpu_driver={s}\n",
                    .{
                        summary.ready_frames,
                        app.simulation.inspection().tickIndex() -| app.validation_tick_origin,
                        neural_evaluation_fixture.draw_count,
                        diagnostics.draw_count,
                        diagnostics.history_valid_draws,
                        diagnostics.history_reset_draws,
                        neural_evaluation_fixture.source_fingerprint,
                        config.virtual_render_hz,
                        shader_assets.driver,
                    },
                );
            }
            nr0_evaluation_smoke_succeeded = true;
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
            app.developer.applyVisualizationRequests(
                &.{.{ .set_enabled = true }},
            );
            if (!app.developer.physicsDebugAvailable()) {
                return error.S4PhysicsDebugGpuUnavailable;
            }
            const summary = try app.runValidation(config, .s4_physics_debug);
            const gpu = app.developer.physicsDebugStats() orelse
                return error.S4PhysicsDebugGpuUnavailable;
            const profile_stats = app.developer.profileStats();
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
                    app.simulation.inspection().tickIndex(),
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

test "S8 population smoke summary requires exact bounded lifecycle evidence" {
    var summary = S8PopulationSmokeSummary{
        .attempted_frames = 100,
        .ticks = 25,
        .zero_tick_frames = 75,
        .planned = s8_population_count,
        .spawned = s8_population_count,
        .despawned = s8_population_count,
        .npc_draw_frames = 20,
        .peak_npc_draws = s8_population_count,
        .peak_active = s8_population_count,
        .peak_waiting = s8_population_count,
        .peak_dormant = s8_population_count,
        .peak_native_controllers = s8_population_count + 1,
        .waiting_events = s8_population_count,
        .waiting_resume_events = s8_population_count,
        .transfer_events = s8_population_count,
        .dormant_events = s8_population_count,
        .controller_resume_events = s8_population_count,
        .goal_events = s8_population_count,
        .two_resident_scenes = true,
        .peak_live_scenes = 2,
        .peak_resident_scenes = 2,
        .peak_active_batches = 1,
        .peak_staged_cpu_bytes = installed_district_staged_cpu_bytes,
        .peak_staged_upload_bytes = installed_district_gpu_bytes,
        .peak_in_flight_upload_bytes = installed_district_gpu_bytes,
        .peak_resident_gpu_bytes = 2 * installed_district_gpu_bytes,
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
        .navigation_transitions = .{},
        .replans = 0,
        .deferred_replans = 0,
        .teleport_rollbacks = 0,
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
    summary.ticks = 150;
    try summary.validate(
        .{ .frames = 100, .virtual_render_hz = 40 },
        diagnostics,
        controllers,
    );

    var leaked = controllers;
    leaked.native_used = 1;
    leaked.authority_consistent = false;
    try std.testing.expectError(
        error.S8PopulationSmokeEvidenceMissing,
        summary.validate(
            .{ .frames = 100, .virtual_render_hz = 40 },
            diagnostics,
            leaked,
        ),
    );
}

fn s8TestIdentity(index: usize) sandbox_contracts.PersistentId {
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
        try evidence.observeEvent(.population_spawned, &summary, .{ .goal_reached = .{
            .id = id,
            .destination = sandbox_contracts.south_gate_approach_destination,
        } });
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
    missing.transferred[0] = false;
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
    const first_waiting = sandbox_contracts.NpcEvent{ .state_changed = .{
        .id = first,
        .previous = .active,
        .current = .waiting_at_boundary,
    } };
    try evidence.observeEvent(.destination_waiting, &summary, first_waiting);
    try std.testing.expectError(
        error.UnexpectedS8NpcEvent,
        evidence.observeEvent(.destination_waiting, &summary, first_waiting),
    );
    const second_waiting = sandbox_contracts.NpcEvent{ .state_changed = .{
        .id = second,
        .previous = .active,
        .current = .waiting_at_boundary,
    } };
    try std.testing.expectError(
        error.UnexpectedS8NpcEvent,
        evidence.observeEvent(.destination_reloaded, &summary, second_waiting),
    );
    try std.testing.expectError(
        error.UnexpectedS8NpcEvent,
        evidence.observeEvent(.destination_waiting, &summary, second_waiting),
    );
    try std.testing.expectError(
        error.UnexpectedS8NpcEvent,
        evidence.observeEvent(.crossed_east, &summary, .{ .goal_reached = .{
            .id = first,
            .destination = sandbox_contracts.market_terminal_destination,
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
    try std.testing.expectEqual(@as(u8, 1), summary.spawned);
    try std.testing.expectEqual(@as(u8, 1), summary.despawned);
    try std.testing.expectEqual(@as(u16, 1), summary.waiting_events);
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

test "incident benchmark percentile indices are bounded samples" {
    try std.testing.expectEqual(@as(usize, 0), percentileIndex(1, 99));
    try std.testing.expectEqual(@as(usize, 4), percentileIndex(10, 50));
    try std.testing.expectEqual(@as(usize, 8), percentileIndex(10, 95));
    try std.testing.expectEqual(@as(usize, 8), percentileIndex(10, 99));
}

test "interactive vehicle rejections keep normal play healthy while carrying" {
    const vehicle = sandbox_host.ReplicatedEntityId{ .index = 9, .generation = 1 };
    try std.testing.expect(interactiveVehicleRejectionExpected(.{
        .sequence = 1,
        .vehicle = vehicle,
        .action = .enter,
        .disposition = .invalid_state,
    }));
    try std.testing.expect(interactiveVehicleRejectionExpected(.{
        .sequence = 2,
        .vehicle = vehicle,
        .action = .enter,
        .disposition = .too_far,
    }));
    try std.testing.expect(interactiveVehicleRejectionExpected(.{
        .sequence = 3,
        .vehicle = vehicle,
        .action = .exit,
        .disposition = .exit_blocked,
    }));

    // Authority failures remain fatal to the host; only the typed interactive
    // domain outcomes above are converted into structured diagnostics.
    try std.testing.expect(!interactiveVehicleRejectionExpected(.{
        .sequence = 4,
        .vehicle = vehicle,
        .action = .enter,
        .disposition = .vehicle_not_found,
    }));
    try std.testing.expect(!interactiveVehicleRejectionExpected(.{
        .sequence = 5,
        .vehicle = vehicle,
        .action = .exit,
        .disposition = .invalid_state,
    }));
}

test "all engine module tests are discovered" {
    // Zig 0.16 analyzes declarations lazily. Explicitly reference each module
    // so its test blocks remain part of the engine test contract.
    std.testing.refAllDecls(@import("camera.zig"));
    std.testing.refAllDecls(@import("sandbox_controls.zig"));
    std.testing.refAllDecls(@import("sandbox_visual_resources.zig"));
    std.testing.refAllDecls(@import("sandbox_visual_catalog.zig"));
    std.testing.refAllDecls(@import("sandbox_visual_composition.zig"));
    std.testing.refAllDecls(@import("editor/tool.zig"));
    std.testing.refAllDecls(district_streaming_host);
    std.testing.refAllDecls(@import("input.zig"));
    std.testing.refAllDecls(@import("incident_screenshot.zig"));
    std.testing.refAllDecls(@import("mesh.zig"));
    std.testing.refAllDecls(@import("renderer.zig"));
    std.testing.refAllDecls(@import("texture.zig"));
    std.testing.refAllDecls(@import("timing.zig"));
}
