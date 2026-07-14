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

// Forward declarations for engine types
const Camera = @import("../camera.zig").Camera;
const FrameTimer = @import("../timing.zig").FrameTimer;
const engine = @import("incinerator_engine");
const sandbox_host = @import("sandbox_host_contracts");
const developer_controls = @import("developer_controls");
const developer_diagnostics = @import("developer_diagnostics");
const developer_profile = @import("developer_profile");
const developer_visualization = @import("developer_visualization");
const sandbox_authoring = @import("sandbox_authoring");
const sandbox_interaction = @import("sandbox_interaction");

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
    state: engine.physics.BodyState,
    authoring_revision: u64,
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
    available_crate: ?AuthoringCrateView = null,
    selected_crate: ?AuthoringCrateView = null,
    feedback: AuthoringFeedback = .{},
    save: SaveFeedback = .{},
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

/// One-frame observations and fixed request sinks, grouped by concern. This is
/// the composition/editor boundary; tools never receive App or Simulation.
pub const FrameInput = struct {
    camera: *const Camera,
    frame_timer: *const FrameTimer,
    developer: DeveloperInput,
    visualization: VisualizationInput,
    authoring: AuthoringInput,
    interaction: InteractionInput,
};

// ============================================================================
// Tool Interface
// ============================================================================

/// Explicit identity for the statically composed sandbox editor tools. Draw
/// dispatch remains in editor.zig so state is owned by an Editor value instead
/// of hidden behind module globals or self-referential pointers.
pub const ToolId = enum {
    stats,
    camera,
    render,
    diagnostics,
    physics_debug,
    crate_authoring,
    interaction,
};

pub const Descriptor = struct {
    id: ToolId,
    name: [:0]const u8,
    enabled_by_default: bool = true,
};

/// Runtime visibility state for one statically registered tool.
pub const Tool = struct {
    id: ToolId,
    name: [:0]const u8,
    enabled: bool = true,

    pub fn init(descriptor: Descriptor) Tool {
        return .{
            .id = descriptor.id,
            .name = descriptor.name,
            .enabled = descriptor.enabled_by_default,
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
        .id = .stats,
        .name = "Test Tool",
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
        .enabled_by_default = false,
    });
    try std.testing.expectEqual(ToolId.camera, registered_tool.id);
    try std.testing.expectEqualStrings("Camera", registered_tool.name);
    try std.testing.expect(!registered_tool.enabled);
}
