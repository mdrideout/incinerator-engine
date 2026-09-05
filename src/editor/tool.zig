//! tool.zig - Editor Tool Interface
//!
//! DOMAIN: Editor Layer
//!
//! Defines the interface that all editor tools must implement. Tools are
//! self-contained UI panels/windows that provide debugging, inspection,
//! or manipulation capabilities.
//!
//! Design Philosophy:
//! - Tools are composable: each tool is independent and focused
//! - Tools are toggleable: can be enabled/disabled at runtime
//! - Tools receive only the concern-specific frame input they need
//! - Tools are explicit: manually registered, not auto-discovered
//!
//! Every tool publishes immutable metadata plus a draw function. The editor
//! owns runtime visibility and state, and dispatches the statically registered
//! tool identities explicitly.

const std = @import("std");
const workspace = @import("editor_workspace");
pub const viewport = @import("viewport.zig");
pub const selection = @import("selection.zig");

const engine = @import("incinerator_engine");
const sandbox_host = @import("sandbox_host_contracts");
const sandbox_replay = @import("sandbox_replay");
const developer_controls = @import("developer_controls");
const developer_diagnostics = @import("developer_diagnostics");
const developer_profile = @import("developer_profile");
const developer_visualization = @import("developer_visualization");
const sandbox_authoring = @import("sandbox_authoring");
const sandbox_interaction = @import("sandbox_interaction");
const population = @import("population_contract");
const incident = @import("../engine/incident.zig");
const render_contract = @import("../render_contract.zig");

pub const AuthoringChangeEvidence = sandbox_authoring.ChangeEvidence;

pub const CameraView = struct {
    position: [3]f32,
    yaw: f32,
    pitch: f32,
    fov: f32,
    near: f32,
    far: f32,
    move_speed: f32,
    look_sensitivity: f32,
    forward: [3]f32,
    right: [3]f32,
};

pub const FrameTimingView = struct {
    fps: f64,
    delta_seconds: f64,
    ticks_this_frame: u32,
    total_frames: u64,
};

pub const DeveloperSnapshot = developer_diagnostics.Snapshot(sandbox_host.Diagnostics);
pub const ProfileSpanView = developer_profile.SpanRing(
    developer_profile.default_span_capacity,
).BorrowedView;
pub const ProfileFrameView = developer_profile.FrameRing(
    developer_profile.default_frame_capacity,
).BorrowedView;

// ============================================================================
// Host-neutral authoring views
// ============================================================================

/// Immutable crate record borrowed for one editor draw. The editor sees only
/// engine-owned values; it never receives a Simulation, ECS entity, or physics
/// body handle.
pub const AuthoringCrateView = struct {
    id: engine.PersistentId,
    half_extents: [3]f32,
    state: engine.physics.BodyState,
    authoring_revision: u64,
    collider: CrateColliderStatus = .active_dynamic_box,
};

pub const CrateColliderStatus = enum {
    active_dynamic_box,
};

/// Game-composition-owned exploration range for the crate position controls.
/// Exact numeric edits deliberately remain unbounded; the crate owner is the
/// final validator for every submitted pose.
pub const CratePositionHint = struct {
    minimum: [3]f32,
    maximum: [3]f32,

    pub fn validate(self: CratePositionHint) !void {
        for (0..3) |axis| {
            if (!std.math.isFinite(self.minimum[axis]) or
                !std.math.isFinite(self.maximum[axis]) or
                self.minimum[axis] >= self.maximum[axis])
            {
                return error.InvalidCratePositionHint;
            }
        }
    }
};

pub const AuthoringFeedbackStatus = enum {
    none,
    applied,
    rejected,
    submission_failed,
};

/// Latest correlated authoring result retained by the composition. `sequence`
/// advances for every update so an optional editor can distinguish a new
/// result from an unchanged snapshot without owning outcome history.
pub const AuthoringFeedback = struct {
    sequence: u64 = 0,
    status: AuthoringFeedbackStatus = .none,
    operation: ?sandbox_authoring.OperationKind = null,
    transaction_id: ?u64 = null,
    id: ?engine.PersistentId = null,
    rejection_reason: ?sandbox_host.RejectionReason = null,
    detail: []const u8 = "",
};

pub const SaveFeedbackStatus = enum {
    unavailable,
    idle,
    queued,
    committing,
    committed,
    committed_sync_warning,
    not_committed,
};

/// Latest save-slot result. Strings are immutable frame borrows owned by the
/// composition; the editor neither stores them nor reaches the filesystem.
pub const SaveFeedback = struct {
    sequence: u64 = 0,
    status: SaveFeedbackStatus = .unavailable,
    slot_label: []const u8 = "",
    detail: []const u8 = "",
};

/// Complete immutable authoring input for one editor frame. S5 deliberately
/// exposes one sandbox candidate; adding a bounded catalogue later does not
/// change the request or authority boundary.
pub const CrateAuthoringView = struct {
    session: sandbox_authoring.Snapshot,
    position_hint: CratePositionHint,
    available_crate: ?AuthoringCrateView = null,
    selected_crate: ?AuthoringCrateView = null,
    feedback: AuthoringFeedback = .{},
    save: SaveFeedback = .{},
    latest_change: ?AuthoringChangeEvidence = null,
    request_rejections: u64 = 0,
};

/// Immutable S7 carrier/carryable authority presented to the optional editor.
/// Outcomes are retained by value so polling remains centralized in the host;
/// the tool cannot drain or reorder another producer's result.
pub const InteractionView = struct {
    carrier: ?sandbox_host.CharacterView = null,
    carryable: ?sandbox_host.CarryableView = null,
    next_transaction_id: ?u64 = null,
    last_outcome: ?sandbox_host.InteractionOutcome = null,
    submission_failures: u64 = 0,
    request_rejections: u64 = 0,
};

// ============================================================================
// Gameplay observability views
// ============================================================================

/// Complete bounded live session cohort plus one retained tombstone cohort.
/// Generation replacement can temporarily keep both identities observable.
pub const gameplay_entity_capacity: usize = 176;

pub const GameplayEntityKind = enum {
    local_player,
    remote_player,
    npc,
    vehicle,
    carryable,
};

pub const GameplayLifeState = enum {
    unknown,
    alive,
    dead,
};

pub const GameplayPresence = enum {
    unavailable,
    absent,
    present,
};

pub const GameplayRemovalReason = enum {
    none,
    relevance,
    replication_removed,
    authority_removed,
    presentation_removed,
    unknown,
};

pub const GameplayRelevanceReason = enum {
    unavailable,
    excluded,
    full_world,
    same_district,
    encounter,
    proximity_enter,
    proximity_retained,
    grace,
    bounded_world,
    controlled,
    held,
    district_dormant,
};

pub const GameplayNavigationProgress = enum {
    unavailable,
    idle,
    moving,
    waiting_for_content,
    dormant,
    potentially_stalled,
};

pub const GameplayEntityView = struct {
    entity: engine.gameplay_trace.EntityRef,
    persistent_id: ?engine.PersistentId = null,
    kind: GameplayEntityKind,
    authority_presence: GameplayPresence,
    replication_presence: GameplayPresence,
    presentation_presence: GameplayPresence,
    draw_presence: GameplayPresence,
    removal_reason: GameplayRemovalReason = .none,
    removed_tick: u64 = 0,
    removed_frame: u64 = 0,
    relevance_included: ?bool = null,
    relevance_reason: GameplayRelevanceReason = .unavailable,
    relevance_evaluated_tick: u64 = 0,
    relevance_baseline_id: u32 = 0,
    relevance_snapshot_sequence: u32 = 0,
    relevance_grace_until_tick: u64 = 0,
    relevance_observer_position: [3]f32 = .{ 0, 0, 0 },
    relevance_observer_district: [2]i32 = .{ 0, 0 },
    relevance_owner_district: [2]i32 = .{ 0, 0 },
    relevance_distance_squared_xz: f32 = 0,
    relevance_encounter: bool = false,
    authority_position: [3]f32,
    presentation_position: [3]f32,
    velocity: [3]f32 = .{ 0, 0, 0 },
    facing_yaw: f32 = 0,
    radius: f32,
    half_height: f32,
    health: u16,
    maximum_health: u16,
    life_state: GameplayLifeState,
    encounter_state: u16 = 0,
    attack_windup: bool = false,
    target: ?engine.gameplay_trace.EntityRef = null,
    deadline_tick: u64 = 0,
    nearest_actor_separation: ?f32 = null,
    navigation_progress: GameplayNavigationProgress = .unavailable,
    navigation_target: ?[3]f32 = null,
    navigation_no_progress_ticks: u16 = 0,
    navigation_last_progress_tick: u64 = 0,
    navigation_destination: ?sandbox_host.DestinationId = null,
    navigation_status: ?sandbox_host.NpcNavigationStatus = null,
    navigation_reason: ?sandbox_host.NpcNavigationReason = null,
    navigation_trigger: ?sandbox_host.NpcPlanTrigger = null,
    navigation_result: ?sandbox_host.NpcPlanResult = null,
    navigation_route_revision: u64 = 0,
    navigation_topology_revision: u64 = 0,
    navigation_route_digest: u64 = 0,
    navigation_route_cost: u32 = 0,
    navigation_route_length: u8 = 0,
    navigation_active_prefix_length: u8 = 0,
    navigation_route_index: u8 = 0,
    navigation_replan_count: u64 = 0,
    navigation_arrival_tick: ?u64 = null,
    navigation_physical_exclusion_count: u8 = 0,
    navigation_physical_block_retry_tick: u64 = 0,
    population_member: ?population.PopulationMemberId = null,
    population_role: ?population.Role = null,
    population_disposition: ?population.CombatDisposition = null,
    population_activity_kind: ?population.ActivityKind = null,
    population_activity_state: ?population.ActivityState = null,
};

pub const GameplayActionFeedback = struct {
    pub const reason_text_capacity: usize = 48;

    sequence: u64 = 0,
    action: engine.gameplay_trace.Kind = .movement,
    disposition: engine.gameplay_trace.Disposition = .observed,
    reason_domain: engine.gameplay_trace.ReasonDomain = .none,
    reason: u32 = 0,
    reason_text: [reason_text_capacity]u8 = @splat(0),
    reason_text_len: u8 = 0,
    observed_tick: u64 = 0,

    pub fn reasonText(self: *const GameplayActionFeedback) []const u8 {
        return self.reason_text[0..@min(
            @as(usize, self.reason_text_len),
            self.reason_text.len,
        )];
    }
};

/// Immutable per-frame projection assembled by the visual composition. It
/// contains values only; the editor receives no feature, session, or physics
/// authority handle.
pub const GameplayView = struct {
    authority_tick: u64,
    presentation_frame: u64,
    entities: [gameplay_entity_capacity]GameplayEntityView = undefined,
    entity_count: u8 = 0,
    local_health: u16 = 0,
    local_maximum_health: u16 = 0,
    local_life_state: GameplayLifeState = .unknown,
    melee_remaining_ticks: u64 = 0,
    weapon_mode: enum { holstered, equipped, reloading } = .holstered,
    magazine_ammo: u16 = 0,
    reserve_ammo: u16 = 0,
    weapon_remaining_ticks: u64 = 0,
    reload_remaining_ticks: u64 = 0,
    respawn_remaining_ticks: u64 = 0,
    respawn_instruction_visible: bool = false,
    local_damage_feedback: bool = false,
    last_action: GameplayActionFeedback = .{},

    pub fn entitySlice(self: *const GameplayView) []const GameplayEntityView {
        return self.entities[0..@min(
            @as(usize, self.entity_count),
            gameplay_entity_capacity,
        )];
    }
};

pub const GameplayInput = struct {
    view: *const GameplayView,
    trace: engine.gameplay_trace.BorrowedView,
    requests: *engine.gameplay_trace.RequestBuffer,
};

pub const IncidentInput = struct {
    view: *const incident.View,
    requests: *incident.RequestBuffer,
};

pub const NeuralTextureView = struct {
    channel: engine.neural_rendering.Channel,
    binding: *const anyopaque,
    width: u32,
    height: u32,
};

pub const NeuralOutputView = struct {
    binding: *const anyopaque,
    width: u32,
    height: u32,
};

pub const NeuralView = struct {
    available: bool = false,
    schema_version: u16 = 0,
    schema_name: []const u8 = "unavailable",
    schema_fingerprint: []const u8 = "",
    shader_fingerprint: []const u8 = "",
    authority_tick: u64 = 0,
    presentation_frame: u64 = 0,
    draw_count: usize = 0,
    history_valid_draws: usize = 0,
    history_reset_draws: usize = 0,
    global_controls: engine.neural_rendering.FrameGlobalControls = .{},
    compact_id_collisions: u64 = 0,
    rendered_frames: u64 = 0,
    render_failures: u64 = 0,
    model_loaded: bool = false,
    model_enabled: bool = false,
    model_output_ready: bool = false,
    model_bundle_root: []const u8 = "",
    model_checkpoint_digest: []const u8 = "",
    model_manifest_digest: [64]u8 = @splat(0),
    model_readbacks: u64 = 0,
    model_predictions: u64 = 0,
    model_failures: u64 = 0,
    model_last_source_tick: u64 = 0,
    model_last_source_frame: u64 = 0,
    model_last_presented_source_frame: u64 = 0,
    model_unknown_semantic_pixels: u64 = 0,
    model_unknown_instance_pixels: u64 = 0,
    model_inference_ms: f64 = 0,
    model_pipeline_mean_ms: f64 = 0,
    model_pipeline_maximum_ms: f64 = 0,
    model_output: ?NeuralOutputView = null,
    capture_active: bool = false,
    capture_root: []const u8 = "",
    capture_cohort: []const u8 = "",
    capture_sequence: []const u8 = "",
    capture_camera_path: []const u8 = "",
    capture_recorded_frames: u64 = 0,
    capture_requested_frames: u64 = 0,
    capture_failures: u64 = 0,
    last_error: []const u8 = "",
    textures: [engine.neural_rendering.channels.len]NeuralTextureView = undefined,
};

pub const NeuralRequests = struct {
    toggle_model: bool = false,

    pub fn toggleModel(self: *NeuralRequests) void {
        self.toggle_model = !self.toggle_model;
    }

    pub fn clear(self: *NeuralRequests) void {
        self.toggle_model = false;
    }
};

pub const NeuralInput = struct {
    view: *const NeuralView,
    requests: *NeuralRequests,
};

pub const DeveloperInput = struct {
    snapshot: *const DeveloperSnapshot,
    journal: engine.runtime.DiagnosticJournal.BorrowedView,
    control_requests: *developer_controls.RequestBuffer,
    diagnostic_requests: *developer_diagnostics.RequestBuffer,
};

pub const VisualizationInput = struct {
    snapshot: *const developer_visualization.Snapshot,
    profile_spans: ProfileSpanView,
    profile_frames: ProfileFrameView,
    profile_stats: developer_profile.RecorderStats,
    visualization_requests: *developer_visualization.RequestBuffer,
};

pub const AuthoringInput = struct {
    view: *const CrateAuthoringView,
    requests: *sandbox_authoring.RequestBuffer,
};

pub const InteractionInput = struct {
    view: *const InteractionView,
    requests: *sandbox_interaction.RequestBuffer,
};

pub const NavigationRequest = union(enum) {
    set_destination: struct {
        npc: sandbox_host.PersistentId,
        destination: sandbox_host.DestinationId,
    },
    set_gate: sandbox_replay.NavigationGateCommand,
};

pub const NavigationRequestBuffer = struct {
    pub const capacity: usize = 16;

    items: [capacity]NavigationRequest = undefined,
    count: u8 = 0,
    rejected: u64 = 0,

    pub fn push(self: *NavigationRequestBuffer, request: NavigationRequest) bool {
        if (self.count == capacity) {
            self.rejected +|= 1;
            return false;
        }
        self.items[self.count] = request;
        self.count += 1;
        return true;
    }

    pub fn slice(self: *const NavigationRequestBuffer) []const NavigationRequest {
        return self.items[0..self.count];
    }

    pub fn clear(self: *NavigationRequestBuffer) void {
        self.count = 0;
    }
};

pub const NavigationLabView = struct {
    north_gate_open: bool,
    south_gate_open: bool,
    topology_revision: u64,
};

pub const NavigationInput = struct {
    view: *const NavigationLabView,
    gameplay: *const GameplayView,
    requests: *NavigationRequestBuffer,
};

/// Immutable population-owner projection for one editor frame. Definitions
/// and records remain borrowed values; the optional editor receives neither
/// the population owner nor a mutation path.
pub const PopulationView = struct {
    catalog: population.Catalog,
    members: []const population.MemberRecordV1,
    slots: []const population.ActivitySlotRecordV1,
    diagnostics: ?population.Diagnostics,
};

pub const PopulationInput = struct {
    view: *const PopulationView,
    gameplay: *const GameplayView,
    visualization: *const developer_visualization.Snapshot,
    visualization_requests: *developer_visualization.RequestBuffer,
};

pub const RenderView = struct {
    mode: []const u8 = render_contract.mode_name,
    visual_schema: u16 = render_contract.visual_schema_version,
    scene_light: render_contract.SceneLight,
    frame_stats: render_contract.FrameStats,
    last_semantic: []const u8 = "none",
    last_part: []const u8 = "none",
    last_ordinal: u16 = 0,
    last_surface: []const u8 = "none",
    selected_object_kind: []const u8 = "none",
    selected_identity_kind: []const u8 = "none",
    selected_namespace: u64 = 0,
    selected_local: u64 = 0,
    selected_incarnation: u32 = 0,
};

pub const RenderInput = struct {
    view: *const RenderView,
};

pub const ViewportInput = struct {
    view: *const viewport.View,
    requests: *viewport.Requests,
};

pub const SelectionInput = struct {
    view: selection.View,
    requests: *selection.Requests,
};

/// One-frame observations and fixed request sinks, grouped by concern. This is
/// the composition/editor boundary; tools never receive App or Simulation.
pub const FrameInput = struct {
    wall_unix_ms: i64,
    camera: *const CameraView,
    viewport: ViewportInput,
    selection: SelectionInput,
    content_assets: []const engine.assets.Entry,
    frame_timing: *const FrameTimingView,
    developer: DeveloperInput,
    visualization: VisualizationInput,
    authoring: AuthoringInput,
    interaction: InteractionInput,
    navigation: NavigationInput,
    population: PopulationInput,
    render: RenderInput,
    gameplay: GameplayInput,
    incident: IncidentInput,
    neural: NeuralInput,
};

// ============================================================================
// Tool Interface
// ============================================================================

/// Explicit identity for the statically composed sandbox editor tools. Draw
/// dispatch remains in editor.zig so state is owned by an Editor value instead
/// of hidden behind module globals or self-referential pointers.
pub const ToolId = workspace.ToolId;
pub const Descriptor = workspace.Descriptor;

/// Runtime visibility state for one statically registered tool.
pub const Tool = struct {
    descriptor: Descriptor,
    enabled: bool = true,

    pub fn init(descriptor: Descriptor) Tool {
        return .{
            .descriptor = descriptor,
            .enabled = workspace.PanelMask.fromPreset(.gameplay).contains(descriptor.id),
        };
    }

    pub fn toggle(self: *Tool) void {
        self.enabled = !self.enabled;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Tool toggle works" {
    var registered_tool = Tool{
        .descriptor = .{
            .id = .stats,
            .name = "Test Tool",
            .category = .performance,
            .default_region = .bottom,
            .purpose = "Test purpose",
            .reads = "Test input",
            .requests = "No requests",
            .examples = &.{"fps=120"},
            .audit_fields = &.{"presentation_frame"},
        },
        .enabled = true,
    };

    try std.testing.expect(registered_tool.enabled == true);
    registered_tool.toggle();
    try std.testing.expect(registered_tool.enabled == false);
    registered_tool.toggle();
    try std.testing.expect(registered_tool.enabled == true);
}

test "Tool initializes from immutable descriptor" {
    const registered_tool = Tool.init(.{
        .id = .camera,
        .name = "Camera",
        .category = .rendering,
        .default_region = .right,
        .purpose = "Inspect the product camera",
        .reads = "Camera frame projection",
        .requests = "No requests",
        .examples = &.{"yaw=0.5"},
        .audit_fields = &.{"presentation_frame"},
    });
    try std.testing.expectEqual(ToolId.camera, registered_tool.descriptor.id);
    try std.testing.expectEqualStrings("Camera", registered_tool.descriptor.name);
    try std.testing.expect(!registered_tool.enabled);
}
