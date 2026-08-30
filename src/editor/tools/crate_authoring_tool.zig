//! Selection-driven Inspector for the sandbox's authorable crate proof.
//!
//! The Inspector owns one local XYZ draft. Numeric controls and the viewport
//! translate gizmo edit that same draft; only the explicit Apply Position
//! request can cross the existing typed sandbox-authoring boundary.

const std = @import("std");
const zgui = @import("zgui");
const engine = @import("incinerator_engine");
const sandbox_authoring = @import("sandbox_authoring");
const tool_module = @import("../tool.zig");

const AuthoringInput = tool_module.AuthoringInput;
const SelectionInput = tool_module.SelectionInput;
const viewport = tool_module.viewport;

pub const descriptor = tool_module.Descriptor{
    .id = .crate_authoring,
    .name = "Inspector",
    .category = .authoring,
    .default_region = .right,
    .purpose = "Inspect the selected runtime crate, edit one position draft, and write a restorable sandbox world snapshot.",
    .reads = "Shared selection plus immutable crate authoring, transaction, evidence, and save projections.",
    .requests = "Emits typed relocate, undo, redo, and world-snapshot requests through the authoring boundary.",
    .examples = &.{ "crate=1:4 revision=7", "draft=(2.000, 1.000, 5.000)", "snapshot=committed slot=sandbox" },
    .audit_fields = &.{ "authority_tick", "persistent_id", "transaction_id", "authoring_revision" },
};

pub const Axis = enum(u2) { x, y, z };
const axis_names = [_][]const u8{ "X", "Y", "Z" };
const axis_slider_labels = [_][:0]const u8{ "##x_slider", "##y_slider", "##z_slider" };
const axis_exact_labels = [_][:0]const u8{ "##x_exact", "##y_exact", "##z_exact" };
const axis_gizmo_labels = [_][:0]const u8{ "##crate_gizmo_x", "##crate_gizmo_y", "##crate_gizmo_z" };
const gizmo_handle_radius: f32 = 12;
const axis_colors = [_][4]f32{
    .{ 0.95, 0.18, 0.14, 1 },
    .{ 0.20, 0.88, 0.30, 1 },
    .{ 0.18, 0.42, 1.00, 1 },
};

pub const GizmoHandleRegion = struct {
    minimum: [2]f32,
    maximum: [2]f32,

    fn centered(point: [2]f32) GizmoHandleRegion {
        return .{
            .minimum = .{ point[0] - gizmo_handle_radius, point[1] - gizmo_handle_radius },
            .maximum = .{ point[0] + gizmo_handle_radius, point[1] + gizmo_handle_radius },
        };
    }

    fn contains(self: GizmoHandleRegion, point: [2]f32) bool {
        return point[0] >= self.minimum[0] and point[0] < self.maximum[0] and
            point[1] >= self.minimum[1] and point[1] < self.maximum[1];
    }
};

const GizmoDragMapping = struct {
    projection: ScreenProjection,
    axis: Axis,
    world_origin: [3]f32,
    screen_origin: [2]f32,
    screen_direction: [2]f32,
    pointer_origin: [2]f32,

    fn init(
        projection: ScreenProjection,
        axis: Axis,
        world_origin: [3]f32,
        screen_origin: [2]f32,
        axis_projection: AxisProjection,
        pointer_origin: [2]f32,
    ) ?GizmoDragMapping {
        for (world_origin ++ screen_origin ++ axis_projection.direction ++ pointer_origin) |value| {
            if (!std.math.isFinite(value)) return null;
        }
        const direction_length = @sqrt(
            axis_projection.direction[0] * axis_projection.direction[0] +
                axis_projection.direction[1] * axis_projection.direction[1],
        );
        if (!std.math.isFinite(direction_length) or direction_length <= 0) return null;
        return .{
            .projection = projection,
            .axis = axis,
            .world_origin = world_origin,
            .screen_origin = screen_origin,
            .screen_direction = .{
                axis_projection.direction[0] / direction_length,
                axis_projection.direction[1] / direction_length,
            },
            .pointer_origin = pointer_origin,
        };
    }

    fn worldDisplacement(self: GizmoDragMapping, pointer: [2]f32) ?f32 {
        if (!std.math.isFinite(pointer[0]) or !std.math.isFinite(pointer[1])) return null;
        const pointer_delta = [2]f32{
            pointer[0] - self.pointer_origin[0],
            pointer[1] - self.pointer_origin[1],
        };
        const screen_distance = pointer_delta[0] * self.screen_direction[0] +
            pointer_delta[1] * self.screen_direction[1];
        const target_screen = [2]f32{
            self.screen_origin[0] + self.screen_direction[0] * screen_distance,
            self.screen_origin[1] + self.screen_direction[1] * screen_distance,
        };
        const ray_direction = self.projection.rayDirection(target_screen) orelse return null;
        var world_axis = [3]f32{ 0, 0, 0 };
        world_axis[@intFromEnum(self.axis)] = 1;
        const camera_to_axis = sub3(self.projection.camera.position, self.world_origin);
        const ray_axis_dot = dot3(ray_direction, world_axis);
        const denominator = 1 - ray_axis_dot * ray_axis_dot;
        if (!std.math.isFinite(denominator) or denominator <= std.math.floatEps(f32)) return null;
        const displacement = (dot3(world_axis, camera_to_axis) -
            ray_axis_dot * dot3(ray_direction, camera_to_axis)) / denominator;
        return if (std.math.isFinite(displacement)) displacement else null;
    }
};

pub const State = struct {
    id: ?engine.PersistentId = null,
    position: [3]f32 = .{ 0, 0, 0 },
    /// Revision observed when this draft was clean. Once the draft becomes
    /// dirty it remains fixed so Apply cannot silently rebase across another
    /// producer's committed change.
    draft_base_revision: u64 = 0,
    dirty: bool = false,
    observed_feedback_sequence: u64 = 0,
    gizmo_axis: ?Axis = null,
    gizmo_start_position: [3]f32 = .{ 0, 0, 0 },
    gizmo_start_dirty: bool = false,
    gizmo_drag_mapping: ?GizmoDragMapping = null,
    gizmo_handle_regions: [3]?GizmoHandleRegion = .{ null, null, null },

    fn reset(self: *State) void {
        self.* = .{};
    }

    fn synchronize(self: *State, view: *const tool_module.CrateAuthoringView) void {
        const selected = coherentSelection(view) orelse {
            self.reset();
            self.observed_feedback_sequence = view.feedback.sequence;
            return;
        };

        if (self.id == null or !std.meta.eql(self.id.?, selected.id)) {
            self.* = .{
                .id = selected.id,
                .position = selected.state.pose.position,
                .draft_base_revision = selected.authoring_revision,
                .observed_feedback_sequence = view.feedback.sequence,
            };
            return;
        }

        if (view.feedback.sequence != self.observed_feedback_sequence) {
            self.observed_feedback_sequence = view.feedback.sequence;
            if (view.feedback.id) |feedback_id| {
                if (std.meta.eql(feedback_id, selected.id)) {
                    switch (view.feedback.status) {
                        .applied => {
                            self.dirty = false;
                            self.endGizmoDrag();
                        },
                        .none, .rejected, .submission_failed => {},
                    }
                }
            }
        }

        // A clean draft follows ordinary physics publication every frame. A
        // dirty draft remains stable while the dynamic crate keeps simulating.
        if (!self.dirty) {
            self.position = selected.state.pose.position;
            self.draft_base_revision = selected.authoring_revision;
        }
    }

    fn revert(
        self: *State,
        authority_position: [3]f32,
        authority_revision: u64,
    ) void {
        self.position = authority_position;
        self.draft_base_revision = authority_revision;
        self.dirty = false;
        self.endGizmoDrag();
    }

    fn draftIssue(self: *const State) ?[]const u8 {
        for (self.position, 0..) |component, axis| {
            if (!std.math.isFinite(component)) return switch (axis) {
                0 => "X must be a finite number",
                1 => "Y must be a finite number",
                else => "Z must be a finite number",
            };
        }
        return null;
    }

    pub fn beginGizmoDrag(self: *State, axis: Axis) void {
        self.gizmo_axis = axis;
        self.gizmo_start_position = self.position;
        self.gizmo_start_dirty = self.dirty;
        self.gizmo_drag_mapping = null;
    }

    fn beginProjectedGizmoDrag(
        self: *State,
        axis: Axis,
        projection: ScreenProjection,
        screen_origin: [2]f32,
        axis_projection: AxisProjection,
        pointer_origin: [2]f32,
    ) bool {
        const mapping = GizmoDragMapping.init(
            projection,
            axis,
            self.position,
            screen_origin,
            axis_projection,
            pointer_origin,
        ) orelse return false;
        self.beginGizmoDrag(axis);
        self.gizmo_drag_mapping = mapping;
        return true;
    }

    pub fn endGizmoDrag(self: *State) void {
        self.gizmo_axis = null;
        self.gizmo_drag_mapping = null;
    }

    /// Cancel only the active gesture. Draft edits that existed before the
    /// press remain intact, including their dirty state.
    pub fn cancelGizmoDrag(self: *State) bool {
        if (self.gizmo_axis == null) return false;
        self.position = self.gizmo_start_position;
        self.dirty = self.gizmo_start_dirty;
        self.endGizmoDrag();
        return true;
    }

    pub fn gizmoDragActive(self: *const State) bool {
        return self.gizmo_axis != null;
    }

    fn setAxisDraft(self: *State, axis: Axis, value: f32) void {
        self.position[@intFromEnum(axis)] = value;
        self.dirty = true;
    }

    pub fn applyGizmoDisplacement(self: *State, axis: Axis, meters: f32) bool {
        if (self.id == null or !std.math.isFinite(meters)) return false;
        const index = @intFromEnum(axis);
        const value = self.gizmo_start_position[index] + meters;
        if (!std.math.isFinite(value)) return false;
        self.position[index] = value;
        self.dirty = true;
        return true;
    }

    fn applyGizmoPointer(self: *State, axis: Axis, pointer: [2]f32) bool {
        if (self.gizmo_axis != axis) return false;
        const mapping = self.gizmo_drag_mapping orelse return false;
        const displacement = mapping.worldDisplacement(pointer) orelse return false;
        return self.applyGizmoDisplacement(axis, displacement);
    }

    fn clearGizmoPointerClaims(self: *State) void {
        self.gizmo_handle_regions = .{ null, null, null };
    }

    /// Remove both halves of the projected gizmo affordance. Mode, panel, or
    /// editor visibility transitions call this even when no drag is active so
    /// a later transition cannot revive stale last-frame handle regions.
    pub fn deactivateGizmo(self: *State) void {
        _ = self.cancelGizmoDrag();
        self.clearGizmoPointerClaims();
    }

    pub fn claimsGizmoPointer(self: *const State, point: [2]f32) bool {
        for (self.gizmo_handle_regions) |region| {
            if (region) |active| {
                if (active.contains(point)) return true;
            }
        }
        return false;
    }
};

fn coherentSelection(view: *const tool_module.CrateAuthoringView) ?tool_module.AuthoringCrateView {
    const selected_id = view.session.selected orelse return null;
    const selected = view.selected_crate orelse return null;
    if (!std.meta.eql(selected_id, selected.id)) return null;
    return selected;
}

fn push(ctx: *const AuthoringInput, request: sandbox_authoring.Request) bool {
    return ctx.requests.push(request);
}

fn relocationRequest(
    state: *const State,
    crate: tool_module.AuthoringCrateView,
) ?sandbox_authoring.Request {
    if (state.id == null or !std.meta.eql(state.id.?, crate.id) or
        !state.dirty or state.draftIssue() != null)
    {
        return null;
    }
    return .{ .relocate = .{
        .id = crate.id,
        .expected_revision = state.draft_base_revision,
        .target_pose = .{
            .position = state.position,
            .rotation = crate.state.pose.rotation,
        },
        .velocity = .zero,
    } };
}

fn drawIdentity(label: []const u8, id: engine.PersistentId) void {
    zgui.text("{s}: namespace={d}, local={d}", .{ label, id.namespace, id.local });
}

fn drawSelectionCapabilities(selection: *const SelectionInput, selected_id: engine.PersistentId) void {
    const active = selection.view.activeEntry() orelse {
        zgui.textColored(.{ 1, 0.75, 0.2, 1 }, "Shared selection is unavailable", .{});
        return;
    };
    const matches = switch (active.id) {
        .persistent_entity => |id| std.meta.eql(id, selected_id),
        else => false,
    };
    if (!matches) {
        zgui.textColored(.{ 1, 0.75, 0.2, 1 }, "Shared selection is synchronizing", .{});
        return;
    }
    zgui.text("Kind/owner: {s} / {s}", .{ @tagName(active.kind), @tagName(active.owner) });
    zgui.text(
        "Availability/authoring: {s} / {s}",
        .{ @tagName(active.availability), if (active.authorable) "authorable" else "read-only" },
    );
}

fn drawOperationSummary(feedback: tool_module.AuthoringFeedback) void {
    zgui.separatorText("Last Authority Result");
    if (feedback.sequence == 0 or feedback.status == .none) {
        zgui.text("No authoring result yet", .{});
        return;
    }

    const color: [4]f32 = switch (feedback.status) {
        .applied => .{ 0.25, 0.9, 0.35, 1 },
        .rejected, .submission_failed => .{ 1, 0.35, 0.25, 1 },
        .none => .{ 0.7, 0.7, 0.7, 1 },
    };
    zgui.textColored(color, "#{d} {s}", .{ feedback.sequence, @tagName(feedback.status) });
    if (feedback.operation) |operation| zgui.text("Operation: {s}", .{@tagName(operation)});
    if (feedback.rejection_reason) |reason| zgui.text("Reason: {s}", .{@tagName(reason)});
    if (feedback.detail.len != 0) zgui.textWrapped("{s}", .{feedback.detail});
}

fn drawOperationAudit(feedback: tool_module.AuthoringFeedback) void {
    if (feedback.sequence == 0 or feedback.status == .none) {
        zgui.text("No correlated transaction has completed.", .{});
        return;
    }
    if (feedback.transaction_id) |transaction_id| zgui.text("Transaction: {d}", .{transaction_id});
    if (feedback.id) |id| drawIdentity("Crate", id);
}

fn drawChangeEvidence(evidence: ?sandbox_authoring.ChangeEvidence) void {
    const value = evidence orelse {
        zgui.text("No authored transaction recorded yet", .{});
        return;
    };
    zgui.text("Run: {d}:{d}", .{ value.record.run_id.started_wall_unix_ms, value.record.run_id.nonce });
    zgui.text(
        "Source/scope: {s}/{s}",
        .{ @tagName(value.record.request.source), @tagName(value.record.request.scope) },
    );
    zgui.text(
        "Transaction/revision: {d} expected {d} committed {?d}",
        .{ value.record.request.transaction_id, value.record.request.expected_revision, value.record.committed_revision },
    );
    zgui.text(
        "Time: wall {d} ms, tick {?d}, frame {?d}",
        .{ value.record.wall_unix_ms, value.record.authority_tick, value.record.presentation_frame },
    );
    zgui.text("Disposition: {s}", .{@tagName(value.record.disposition)});
    if (value.record.rejection) |rejection| switch (rejection) {
        .common => |common| zgui.text("Rejection: {s}", .{@tagName(common)}),
        .owner => |owner| zgui.text("Rejection: owner {d}:{d}", .{ owner.domain, owner.code }),
    };
    if (value.before) |before| zgui.text(
        "Before: ({d:.3}, {d:.3}, {d:.3})",
        .{ before.pose.position[0], before.pose.position[1], before.pose.position[2] },
    );
    zgui.text(
        "Requested: ({d:.3}, {d:.3}, {d:.3})",
        .{ value.requested.target_pose.position[0], value.requested.target_pose.position[1], value.requested.target_pose.position[2] },
    );
    if (value.committed) |committed| zgui.text(
        "Committed: ({d:.3}, {d:.3}, {d:.3})",
        .{ committed.pose.position[0], committed.pose.position[1], committed.pose.position[2] },
    );
}

fn saveBusy(status: tool_module.SaveFeedbackStatus) bool {
    return switch (status) {
        .queued, .committing => true,
        else => false,
    };
}

const ActionAvailability = struct { apply: bool, undo: bool, redo: bool, save: bool };

fn actionAvailability(
    state: *const State,
    view: *const tool_module.CrateAuthoringView,
    request_emitted: bool,
) ActionAvailability {
    const pending = view.session.pending != null or request_emitted;
    return .{
        .apply = !pending and state.dirty and state.draftIssue() == null,
        .undo = !pending and !state.dirty and view.session.canUndo(),
        .redo = !pending and !state.dirty and view.session.canRedo(),
        .save = !pending and !state.dirty and !saveBusy(view.save.status) and view.save.status != .unavailable,
    };
}

fn drawAxisControls(state: *State, hint: tool_module.CratePositionHint) void {
    zgui.textDisabled("Slider = installed world range | exact input = unbounded meters", .{});
    const available_width = zgui.getContentRegionAvail()[0];
    const slider_width = @max(@as(f32, 90), available_width * 0.52);
    const exact_width = @max(@as(f32, 72), available_width - slider_width - 58);
    for (std.meta.tags(Axis)) |axis| {
        const index = @intFromEnum(axis);
        var slider_value = state.position[index];
        var exact_value = state.position[index];
        zgui.pushIntId(@intCast(index));
        defer zgui.popId();

        zgui.textColored(axis_colors[index], "{s}", .{axis_names[index]});
        zgui.sameLine(.{});
        zgui.setNextItemWidth(slider_width);
        if (zgui.sliderFloat(axis_slider_labels[index], .{
            .v = &slider_value,
            .min = hint.minimum[index],
            .max = hint.maximum[index],
            .cfmt = "%.3f",
        })) state.setAxisDraft(axis, slider_value);
        zgui.sameLine(.{});
        zgui.setNextItemWidth(exact_width);
        if (zgui.inputFloat(axis_exact_labels[index], .{
            .v = &exact_value,
            .step = 0.01,
            .step_fast = 1,
            .cfmt = "%.3f",
        })) state.setAxisDraft(axis, exact_value);
        zgui.sameLine(.{});
        zgui.textDisabled("m", .{});
    }
}

fn drawWorldSnapshot(state: *const State, ctx: *const AuthoringInput, request_emitted: bool) void {
    const feedback = ctx.view.save;
    zgui.separatorText("World Snapshot");
    const color: [4]f32 = switch (feedback.status) {
        .committed => .{ 0.25, 0.9, 0.35, 1 },
        .committed_sync_warning => .{ 1, 0.75, 0.2, 1 },
        .not_committed => .{ 1, 0.35, 0.25, 1 },
        .unavailable, .idle, .queued, .committing => .{ 0.75, 0.75, 0.75, 1 },
    };
    zgui.textColored(color, "State: {s} (result #{d})", .{ @tagName(feedback.status), feedback.sequence });
    if (feedback.slot_label.len != 0) zgui.text("Slot: {s}", .{feedback.slot_label});
    zgui.textDisabled("Root: the absolute directory supplied by --save-root", .{});
    if (feedback.detail.len != 0) zgui.textWrapped("{s}", .{feedback.detail});

    const actions = actionAvailability(state, ctx.view, request_emitted);
    zgui.beginDisabled(.{ .disabled = !actions.save });
    if (zgui.button("Save World Snapshot", .{})) _ = push(ctx, .save);
    zgui.endDisabled();
    if (state.dirty) {
        zgui.sameLine(.{});
        zgui.textDisabled("Apply or Revert Draft first", .{});
    }
}

pub fn draw(state: *State, ctx: *const AuthoringInput, selection: *const SelectionInput) void {
    const view = ctx.view;
    state.synchronize(view);

    if (zgui.begin("Inspector", .{})) {
        const session = view.session;
        var request_emitted = false;

        zgui.textDisabled("Selected object inspection and explicit typed authoring", .{});
        zgui.separatorText("Selection");
        const selected = coherentSelection(view);
        if (selected) |crate| {
            drawIdentity("Runtime crate", crate.id);
            drawSelectionCapabilities(selection, crate.id);
            zgui.text("Authoring revision: {d}", .{crate.authoring_revision});
            zgui.text(
                "Authority position: ({d:.3}, {d:.3}, {d:.3}) m",
                .{ crate.state.pose.position[0], crate.state.pose.position[1], crate.state.pose.position[2] },
            );
            zgui.text(
                "Fixed size: ({d:.3}, {d:.3}, {d:.3}) m",
                .{ crate.half_extents[0] * 2, crate.half_extents[1] * 2, crate.half_extents[2] * 2 },
            );
            zgui.text("Collider: {s} (read-only)", .{@tagName(crate.collider)});

            if (session.pending) |pending| {
                zgui.textColored(
                    .{ 1, 0.75, 0.2, 1 },
                    "Pending: {s} transaction {d}",
                    .{ @tagName(pending.kind), pending.transaction_id },
                );
            } else {
                zgui.textColored(.{ 0.25, 0.9, 0.35, 1 }, "Transaction state: idle", .{});
            }

            zgui.separatorText("Position Draft");
            const pending = session.pending != null;
            zgui.beginDisabled(.{ .disabled = pending });
            drawAxisControls(state, view.position_hint);
            if (zgui.button("Revert Draft", .{})) {
                state.revert(crate.state.pose.position, crate.authoring_revision);
            }
            zgui.sameLine(.{});
            if (zgui.button("Clear Selection", .{})) selection.requests.submit(.clear);
            zgui.endDisabled();

            if (state.draftIssue()) |issue| {
                zgui.textColored(.{ 1, 0.35, 0.25, 1 }, "Invalid draft: {s}", .{issue});
            } else if (state.dirty) {
                zgui.textColored(.{ 1, 0.75, 0.2, 1 }, "Unapplied draft; gameplay and crate physics continue", .{});
            } else {
                zgui.text("Clean draft follows the live authority pose", .{});
            }

            var actions = actionAvailability(state, view, request_emitted);
            zgui.beginDisabled(.{ .disabled = !actions.apply });
            if (zgui.button("Apply Position", .{})) {
                request_emitted = push(ctx, relocationRequest(state, crate).?);
            }
            zgui.endDisabled();

            actions = actionAvailability(state, view, request_emitted);
            zgui.sameLine(.{});
            zgui.beginDisabled(.{ .disabled = !actions.undo });
            if (zgui.button("Undo", .{})) request_emitted = push(ctx, .undo);
            zgui.endDisabled();

            actions = actionAvailability(state, view, request_emitted);
            zgui.sameLine(.{});
            zgui.beginDisabled(.{ .disabled = !actions.redo });
            if (zgui.button("Redo", .{})) request_emitted = push(ctx, .redo);
            zgui.endDisabled();
        } else if (session.selected) |stale_id| {
            zgui.textColored(.{ 1, 0.35, 0.25, 1 }, "Selected crate is unavailable", .{});
            drawIdentity("Stale selection", stale_id);
            if (zgui.button("Clear Selection", .{})) selection.requests.submit(.clear);
        } else {
            zgui.textWrapped(
                "No authorable crate selected. In Free Camera, click the crate in the viewport or select Runtime crate in World Outliner.",
                .{},
            );
        }

        drawOperationSummary(view.feedback);
        drawWorldSnapshot(state, ctx, request_emitted);

        zgui.setNextItemOpen(.{ .is_open = false, .cond = .once });
        if (zgui.collapsingHeader("Transaction & History Details", .{})) {
            zgui.text("History: undo {d}, redo {d}, capacity {d}", .{ session.undo_count, session.redo_count, session.history_capacity });
            zgui.text(
                "Loss: capacity {d}, stale {d}, rejected {d}, invalidated selections {d}",
                .{ session.dropped_history, session.invalidated_history, session.rejected_operations, session.invalidated_selections },
            );
            zgui.text("UI mailbox rejections: {d}", .{@max(view.request_rejections, ctx.requests.rejected)});
            drawOperationAudit(view.feedback);
        }

        zgui.setNextItemOpen(.{ .is_open = false, .cond = .once });
        if (zgui.collapsingHeader("Authored-change Evidence", .{})) drawChangeEvidence(view.latest_change);
    }
    zgui.end();
}

const ScreenProjection = struct {
    camera: tool_module.CameraView,
    screen_extent: [2]f32,

    fn rayDirection(self: ScreenProjection, screen: [2]f32) ?[3]f32 {
        for (self.camera.forward ++ self.camera.right ++ self.screen_extent ++ screen) |value| {
            if (!std.math.isFinite(value)) return null;
        }
        if (self.screen_extent[0] <= 0 or self.screen_extent[1] <= 0 or
            self.camera.fov <= 0 or self.camera.fov >= std.math.pi)
        {
            return null;
        }
        const forward = normalize3(self.camera.forward) orelse return null;
        const right = normalize3(self.camera.right) orelse return null;
        const up = normalize3(cross3(right, forward)) orelse return null;
        const tangent = @tan(self.camera.fov * 0.5);
        const aspect = self.screen_extent[0] / self.screen_extent[1];
        if (!std.math.isFinite(tangent) or tangent <= 0 or !std.math.isFinite(aspect) or aspect <= 0) return null;
        const ndc_x = screen[0] * 2 / self.screen_extent[0] - 1;
        const ndc_y = 1 - screen[1] * 2 / self.screen_extent[1];
        return normalize3(.{
            forward[0] + right[0] * ndc_x * tangent * aspect + up[0] * ndc_y * tangent,
            forward[1] + right[1] * ndc_x * tangent * aspect + up[1] * ndc_y * tangent,
            forward[2] + right[2] * ndc_x * tangent * aspect + up[2] * ndc_y * tangent,
        });
    }

    fn project(self: ScreenProjection, world: [3]f32) ?[2]f32 {
        for (self.camera.position ++ self.camera.forward ++ self.camera.right ++ world ++ self.screen_extent) |value| {
            if (!std.math.isFinite(value)) return null;
        }
        if (self.screen_extent[0] <= 0 or self.screen_extent[1] <= 0 or
            self.camera.fov <= 0 or self.camera.fov >= std.math.pi)
        {
            return null;
        }
        const forward = normalize3(self.camera.forward) orelse return null;
        const right = normalize3(self.camera.right) orelse return null;
        const up = normalize3(cross3(right, forward)) orelse return null;
        const relative = sub3(world, self.camera.position);
        const depth = dot3(relative, forward);
        if (!std.math.isFinite(depth) or depth <= @max(self.camera.near, @as(f32, 0.0001)) or depth >= self.camera.far) return null;
        const tangent = @tan(self.camera.fov * 0.5);
        const aspect = self.screen_extent[0] / self.screen_extent[1];
        if (!std.math.isFinite(tangent) or tangent <= 0 or !std.math.isFinite(aspect) or aspect <= 0) return null;
        const ndc_x = dot3(relative, right) / (depth * tangent * aspect);
        const ndc_y = dot3(relative, up) / (depth * tangent);
        if (!std.math.isFinite(ndc_x) or !std.math.isFinite(ndc_y)) return null;
        return .{
            (ndc_x + 1) * 0.5 * self.screen_extent[0],
            (1 - ndc_y) * 0.5 * self.screen_extent[1],
        };
    }
};

const AxisProjection = struct { endpoint: [2]f32, direction: [2]f32, pixels_per_meter: f32 };

fn projectAxis(
    projection: ScreenProjection,
    origin_world: [3]f32,
    origin_screen: [2]f32,
    axis: Axis,
) ?AxisProjection {
    var unit_world = origin_world;
    unit_world[@intFromEnum(axis)] += 1;
    const unit_screen = projection.project(unit_world) orelse return null;
    const delta = [2]f32{ unit_screen[0] - origin_screen[0], unit_screen[1] - origin_screen[1] };
    const length = @sqrt(delta[0] * delta[0] + delta[1] * delta[1]);
    if (!std.math.isFinite(length) or length < 0.5) return null;
    const direction = [2]f32{ delta[0] / length, delta[1] / length };
    return .{
        .endpoint = .{ origin_screen[0] + direction[0] * 68, origin_screen[1] + direction[1] * 68 },
        .direction = direction,
        .pixels_per_meter = length,
    };
}

fn pointInsideInset(scene: viewport.SceneRect, point: [2]f32, inset: f32) bool {
    return point[0] >= scene.minimum[0] + inset and point[0] < scene.maximum[0] - inset and
        point[1] >= scene.minimum[1] + inset and point[1] < scene.maximum[1] - inset;
}

/// The gizmo receives no authoring request sink, making a drag structurally
/// incapable of applying or saving authority.
pub fn drawGizmo(
    state: *State,
    view: *const tool_module.CrateAuthoringView,
    camera: tool_module.CameraView,
    scene: viewport.SceneRect,
    screen_extent: [2]f32,
) void {
    state.clearGizmoPointerClaims();
    state.synchronize(view);
    if (view.session.pending != null or coherentSelection(view) == null or state.draftIssue() != null) return;

    const projection = ScreenProjection{ .camera = camera, .screen_extent = screen_extent };
    const origin = projection.project(state.position) orelse return;
    if (!pointInsideInset(scene, origin, gizmo_handle_radius)) return;

    var axes: [3]?AxisProjection = .{ null, null, null };
    var minimum = [2]f32{ origin[0] - gizmo_handle_radius, origin[1] - gizmo_handle_radius };
    var maximum = [2]f32{ origin[0] + gizmo_handle_radius, origin[1] + gizmo_handle_radius };
    for (std.meta.tags(Axis)) |axis| {
        const index = @intFromEnum(axis);
        const projected = projectAxis(projection, state.position, origin, axis) orelse continue;
        if (!pointInsideInset(scene, projected.endpoint, gizmo_handle_radius)) continue;
        axes[index] = projected;
        minimum[0] = @min(minimum[0], projected.endpoint[0] - gizmo_handle_radius);
        minimum[1] = @min(minimum[1], projected.endpoint[1] - gizmo_handle_radius);
        maximum[0] = @max(maximum[0], projected.endpoint[0] + gizmo_handle_radius);
        maximum[1] = @max(maximum[1], projected.endpoint[1] + gizmo_handle_radius);
    }
    if (axes[0] == null and axes[1] == null and axes[2] == null) return;

    zgui.setNextWindowPos(.{ .x = minimum[0], .y = minimum[1], .cond = .always });
    zgui.setNextWindowSize(.{ .w = maximum[0] - minimum[0], .h = maximum[1] - minimum[1], .cond = .always });
    zgui.pushStyleVar2f(.{ .idx = .window_padding, .v = .{ 0, 0 } });
    defer zgui.popStyleVar(.{});
    if (zgui.begin("##crate_translate_gizmo", .{ .flags = .{
        .no_title_bar = true,
        .no_resize = true,
        .no_move = true,
        .no_collapse = true,
        .no_background = true,
        .no_saved_settings = true,
        .no_focus_on_appearing = true,
        .no_bring_to_front_on_focus = true,
        .no_nav_focus = true,
        .no_docking = true,
        .no_scrollbar = true,
        .no_scroll_with_mouse = true,
    } })) {
        const draw_list = zgui.getWindowDrawList();
        draw_list.addCircleFilled(.{
            .p = origin,
            .r = 5,
            .col = zgui.colorConvertFloat4ToU32(.{ 0.95, 0.95, 0.95, 1 }),
        });

        for (std.meta.tags(Axis)) |axis| {
            const index = @intFromEnum(axis);
            const projected = axes[index] orelse continue;
            const color = zgui.colorConvertFloat4ToU32(axis_colors[index]);
            draw_list.addLine(.{
                .p1 = origin,
                .p2 = projected.endpoint,
                .col = color,
                .thickness = if (state.gizmo_axis == axis) 5 else 3,
            });
            const base = [2]f32{
                projected.endpoint[0] - projected.direction[0] * 13,
                projected.endpoint[1] - projected.direction[1] * 13,
            };
            const perpendicular = [2]f32{ -projected.direction[1] * 6, projected.direction[0] * 6 };
            draw_list.addTriangleFilled(.{
                .p1 = projected.endpoint,
                .p2 = .{ base[0] + perpendicular[0], base[1] + perpendicular[1] },
                .p3 = .{ base[0] - perpendicular[0], base[1] - perpendicular[1] },
                .col = color,
            });

            state.gizmo_handle_regions[index] = GizmoHandleRegion.centered(projected.endpoint);
            zgui.setCursorPos(.{
                projected.endpoint[0] - minimum[0] - gizmo_handle_radius,
                projected.endpoint[1] - minimum[1] - gizmo_handle_radius,
            });
            _ = zgui.invisibleButton(axis_gizmo_labels[index], .{
                .w = gizmo_handle_radius * 2,
                .h = gizmo_handle_radius * 2,
            });
            if (zgui.isItemHovered(.{})) zgui.setMouseCursor(.resize_all);
            if (zgui.isItemActive()) {
                if (state.gizmo_axis != axis or state.gizmo_drag_mapping == null) {
                    if (!state.beginProjectedGizmoDrag(
                        axis,
                        projection,
                        origin,
                        projected,
                        zgui.getMousePos(),
                    )) continue;
                }
                _ = state.applyGizmoPointer(axis, zgui.getMousePos());
            }
        }
        if (!zgui.isMouseDown(.left)) state.endGizmoDrag();
    }
    zgui.end();
}

fn dot3(first: [3]f32, second: [3]f32) f32 {
    return first[0] * second[0] + first[1] * second[1] + first[2] * second[2];
}

fn sub3(first: [3]f32, second: [3]f32) [3]f32 {
    return .{ first[0] - second[0], first[1] - second[1], first[2] - second[2] };
}

fn cross3(first: [3]f32, second: [3]f32) [3]f32 {
    return .{
        first[1] * second[2] - first[2] * second[1],
        first[2] * second[0] - first[0] * second[2],
        first[0] * second[1] - first[1] * second[0],
    };
}

fn normalize3(value: [3]f32) ?[3]f32 {
    const length = @sqrt(dot3(value, value));
    if (!std.math.isFinite(length) or length <= 0.000001) return null;
    return .{ value[0] / length, value[1] / length, value[2] / length };
}

const test_position_hint = tool_module.CratePositionHint{
    .minimum = .{ -8, 0, -8 },
    .maximum = .{ 24, 16, 24 },
};

fn testSession(selected: ?engine.PersistentId) sandbox_authoring.Snapshot {
    return .{
        .selected = selected,
        .pending = null,
        .undo_count = 0,
        .redo_count = 0,
        .history_capacity = 64,
        .dropped_history = 0,
        .rejected_operations = 0,
        .invalidated_selections = 0,
    };
}

fn testCrate(id: engine.PersistentId, position: [3]f32) tool_module.AuthoringCrateView {
    return .{
        .id = id,
        .half_extents = .{ 0.5, 0.5, 0.5 },
        .state = .{ .pose = .{ .position = position } },
        .authoring_revision = 0,
    };
}

test "clean Inspector draft follows physics while dirty draft remains stable" {
    const id = engine.PersistentId{ .namespace = 9, .local = 3 };
    var view = tool_module.CrateAuthoringView{
        .session = testSession(id),
        .position_hint = test_position_hint,
        .selected_crate = testCrate(id, .{ 1, 2, 3 }),
    };
    var state = State{};
    state.synchronize(&view);
    try std.testing.expectEqual([3]f32{ 1, 2, 3 }, state.position);

    view.selected_crate.?.state.pose.position = .{ 4, 5, 6 };
    state.synchronize(&view);
    try std.testing.expectEqual([3]f32{ 4, 5, 6 }, state.position);

    state.position = .{ 20, 21, 22 };
    state.dirty = true;
    view.selected_crate.?.state.pose.position = .{ 7, 8, 9 };
    state.synchronize(&view);
    try std.testing.expectEqual([3]f32{ 20, 21, 22 }, state.position);
    try std.testing.expect(state.dirty);
}

test "Inspector draft retains its optimistic base revision until revert or apply" {
    const id = engine.PersistentId{ .namespace = 9, .local = 5 };
    var selected = testCrate(id, .{ 1, 2, 3 });
    selected.authoring_revision = 4;
    var view = tool_module.CrateAuthoringView{
        .session = testSession(id),
        .position_hint = test_position_hint,
        .selected_crate = selected,
    };
    var state = State{};
    state.synchronize(&view);
    try std.testing.expectEqual(@as(u64, 4), state.draft_base_revision);

    state.setAxisDraft(.x, 8);
    view.selected_crate.?.authoring_revision = 5;
    view.selected_crate.?.state.pose.position = .{ 6, 2, 3 };
    state.synchronize(&view);
    try std.testing.expectEqual(@as(u64, 4), state.draft_base_revision);
    try std.testing.expectEqual(@as(u64, 4), relocationRequest(&state, view.selected_crate.?).?.relocate.expected_revision);

    state.revert(
        view.selected_crate.?.state.pose.position,
        view.selected_crate.?.authoring_revision,
    );
    try std.testing.expectEqual(@as(u64, 5), state.draft_base_revision);
    try std.testing.expect(!state.dirty);
}

test "selection change replaces draft and selection loss clears it" {
    const first = engine.PersistentId{ .namespace = 9, .local = 3 };
    const second = engine.PersistentId{ .namespace = 9, .local = 4 };
    var view = tool_module.CrateAuthoringView{
        .session = testSession(first),
        .position_hint = test_position_hint,
        .selected_crate = testCrate(first, .{ 1, 2, 3 }),
    };
    var state = State{};
    state.synchronize(&view);
    state.position = .{ 90, 91, 92 };
    state.dirty = true;

    view.session.selected = second;
    view.selected_crate = testCrate(second, .{ 4, 5, 6 });
    state.synchronize(&view);
    try std.testing.expectEqual(second, state.id.?);
    try std.testing.expectEqual([3]f32{ 4, 5, 6 }, state.position);
    try std.testing.expect(!state.dirty);

    view.session.selected = null;
    view.selected_crate = null;
    state.synchronize(&view);
    try std.testing.expectEqual(@as(?engine.PersistentId, null), state.id);
    try std.testing.expect(!state.dirty);
}

test "correlated applied feedback refreshes draft and rejection preserves it" {
    const id = engine.PersistentId{ .namespace = 11, .local = 8 };
    var view = tool_module.CrateAuthoringView{
        .session = testSession(id),
        .position_hint = test_position_hint,
        .selected_crate = testCrate(id, .{ 1, 1, 1 }),
    };
    var state = State{};
    state.synchronize(&view);
    state.position = .{ 9, 9, 9 };
    state.dirty = true;

    view.feedback = .{
        .sequence = 1,
        .status = .rejected,
        .operation = .edit,
        .transaction_id = 4,
        .id = id,
        .detail = "state_conflict",
    };
    state.synchronize(&view);
    try std.testing.expect(state.dirty);
    try std.testing.expectEqual([3]f32{ 9, 9, 9 }, state.position);

    view.selected_crate.?.state.pose.position = .{ 5, 6, 7 };
    view.feedback = .{ .sequence = 2, .status = .applied, .operation = .edit, .transaction_id = 5, .id = id };
    state.synchronize(&view);
    try std.testing.expect(!state.dirty);
    try std.testing.expectEqual([3]f32{ 5, 6, 7 }, state.position);
}

test "non-finite exact drafts are rejected while finite values beyond slider hints remain valid" {
    var state = State{ .id = .{ .namespace = 1, .local = 1 }, .dirty = true };
    state.setAxisDraft(.y, std.math.inf(f32));
    try std.testing.expectEqualStrings("Y must be a finite number", state.draftIssue().?);

    state.setAxisDraft(.x, 250);
    state.setAxisDraft(.y, -40);
    state.setAxisDraft(.z, 900);
    try std.testing.expectEqual(@as(?[]const u8, null), state.draftIssue());
    try std.testing.expect(state.position[0] > test_position_hint.maximum[0]);
    try std.testing.expect(state.position[1] < test_position_hint.minimum[1]);
}

test "slider and exact controls update the same axis draft" {
    var state = State{ .id = .{ .namespace = 1, .local = 1 } };
    state.setAxisDraft(.x, test_position_hint.maximum[0]);
    try std.testing.expectEqual(@as(f32, 24), state.position[0]);
    state.setAxisDraft(.x, -12.375);
    try std.testing.expectEqual(@as(f32, -12.375), state.position[0]);
    try std.testing.expect(state.dirty);
}

test "translate gizmo drag and drop edits only the shared local draft" {
    const id = engine.PersistentId{ .namespace = 3, .local = 7 };
    var state = State{ .id = id, .position = .{ 1, 2, 3 } };
    state.beginGizmoDrag(.x);
    try std.testing.expect(state.applyGizmoDisplacement(.x, 4.5));
    try std.testing.expectEqual([3]f32{ 5.5, 2, 3 }, state.position);
    try std.testing.expect(state.dirty);
    try std.testing.expect(state.gizmoDragActive());
    state.endGizmoDrag();
    try std.testing.expect(!state.gizmoDragActive());
    try std.testing.expect(!state.applyGizmoDisplacement(.y, std.math.nan(f32)));
}

test "editor Escape acceptance restores the pre-drag gizmo draft and dirty state" {
    const id = engine.PersistentId{ .namespace = 3, .local = 7 };
    var state = State{
        .id = id,
        .position = .{ 8, 2, 3 },
        .dirty = true,
    };
    state.beginGizmoDrag(.y);
    try std.testing.expect(state.applyGizmoDisplacement(.y, 6));
    try std.testing.expectEqual([3]f32{ 8, 8, 3 }, state.position);

    try std.testing.expect(state.cancelGizmoDrag());
    try std.testing.expectEqual([3]f32{ 8, 2, 3 }, state.position);
    try std.testing.expect(state.dirty);
    try std.testing.expect(!state.gizmoDragActive());
    try std.testing.expect(!state.cancelGizmoDrag());
}

test "gizmo drop stays local until Apply emits one exact relocate request" {
    const id = engine.PersistentId{ .namespace = 3, .local = 7 };
    var crate = testCrate(id, .{ 1, 2, 3 });
    crate.authoring_revision = 12;
    var state = State{
        .id = id,
        .position = crate.state.pose.position,
        .draft_base_revision = crate.authoring_revision,
    };
    var requests = sandbox_authoring.RequestBuffer{};

    state.beginGizmoDrag(.z);
    try std.testing.expect(state.applyGizmoDisplacement(.z, 4.5));
    state.endGizmoDrag();
    try std.testing.expectEqual(@as(u8, 0), requests.len);

    try std.testing.expect(requests.push(relocationRequest(&state, crate).?));
    try std.testing.expectEqual(@as(u8, 1), requests.len);
    const relocate = switch (requests.slice()[0]) {
        .relocate => |request| request,
        else => return error.ExpectedRelocateRequest,
    };
    try std.testing.expectEqual(id, relocate.id);
    try std.testing.expectEqual(@as(u64, 12), relocate.expected_revision);
    try std.testing.expectEqual([3]f32{ 1, 2, 7.5 }, relocate.target_pose.position);
    try std.testing.expectEqual(crate.state.pose.rotation, relocate.target_pose.rotation);
    try std.testing.expectEqual(sandbox_authoring.RelocateRequest{
        .id = id,
        .expected_revision = 12,
        .target_pose = relocate.target_pose,
        .velocity = .zero,
    }, relocate);
}

test "gizmo pointer claims cover only current handle regions" {
    var state = State{};
    state.gizmo_handle_regions[0] = GizmoHandleRegion.centered(.{ 100, 200 });

    try std.testing.expect(state.claimsGizmoPointer(.{ 100, 200 }));
    try std.testing.expect(state.claimsGizmoPointer(.{ 88, 188 }));
    try std.testing.expect(!state.claimsGizmoPointer(.{ 112, 200 }));
    try std.testing.expect(!state.claimsGizmoPointer(.{ 140, 200 }));

    state.clearGizmoPointerClaims();
    try std.testing.expect(!state.claimsGizmoPointer(.{ 100, 200 }));
}

test "dirty drafts and pending transactions defer undo redo and world snapshot" {
    const id = engine.PersistentId{ .namespace = 4, .local = 2 };
    var view = tool_module.CrateAuthoringView{
        .session = testSession(id),
        .position_hint = test_position_hint,
        .selected_crate = testCrate(id, .{ 0, 1, 0 }),
        .save = .{ .status = .idle },
    };
    view.session.undo_count = 1;
    view.session.redo_count = 1;
    var state = State{ .id = id, .position = .{ 2, 2, 2 }, .dirty = true };
    var actions = actionAvailability(&state, &view, false);
    try std.testing.expect(actions.apply);
    try std.testing.expect(!actions.undo and !actions.redo and !actions.save);

    state.dirty = false;
    actions = actionAvailability(&state, &view, false);
    try std.testing.expect(!actions.apply and actions.undo and actions.redo and actions.save);

    view.session.pending = .{
        .kind = .edit,
        .transaction_id = 9,
        .id = id,
        .request = .{
            .transaction_id = 9,
            .source = .ui,
            .scope = .session,
            .target = .{ .persistent_entity = id },
            .expected_revision = 0,
        },
        .requested = .{
            .id = id,
            .expected_revision = 0,
            .target_pose = .{ .position = .{ 2, 2, 2 } },
        },
    };
    actions = actionAvailability(&state, &view, false);
    try std.testing.expect(!actions.apply and !actions.undo and !actions.redo and !actions.save);
}

test "screen projection and axis scale preserve world-meter direction" {
    const projection = ScreenProjection{
        .camera = .{
            .position = .{ 0, 0, 0 },
            .yaw = 0,
            .pitch = 0,
            .fov = @as(f32, std.math.pi) / 2,
            .near = 0.1,
            .far = 100,
            .move_speed = 1,
            .look_sensitivity = 1,
            .forward = .{ 0, 0, 1 },
            .right = .{ 1, 0, 0 },
        },
        .screen_extent = .{ 1_000, 500 },
    };
    const origin = projection.project(.{ 0, 0, 10 }).?;
    try std.testing.expectApproxEqAbs(@as(f32, 500), origin[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 250), origin[1], 0.001);
    const x_axis = projectAxis(projection, .{ 0, 0, 10 }, origin, .x).?;
    try std.testing.expect(x_axis.direction[0] > 0.99);
    try std.testing.expectApproxEqAbs(@as(f32, 25), x_axis.pixels_per_meter, 0.001);
}

test "gizmo drag retains its mouse-down axis mapping and tracks the pointer in perspective" {
    const diagonal: f32 = 0.70710677;
    const projection = ScreenProjection{
        .camera = .{
            .position = .{ 0, 0, 0 },
            .yaw = 0,
            .pitch = 0,
            .fov = @as(f32, std.math.pi) / 2,
            .near = 0.1,
            .far = 100,
            .move_speed = 1,
            .look_sensitivity = 1,
            .forward = .{ diagonal, 0, diagonal },
            .right = .{ diagonal, 0, -diagonal },
        },
        .screen_extent = .{ 1_000, 500 },
    };
    const start = [3]f32{ 0, 0, 10 };
    const start_screen = projection.project(start).?;
    const mouse_down_projection = projectAxis(projection, start, start_screen, .x).?;
    const pointer_down = mouse_down_projection.endpoint;
    var state = State{ .id = .{ .namespace = 3, .local = 7 }, .position = start };
    try std.testing.expect(state.beginProjectedGizmoDrag(
        .x,
        projection,
        start_screen,
        mouse_down_projection,
        pointer_down,
    ));

    const pointer_after_long_drag = [2]f32{
        pointer_down[0] + mouse_down_projection.direction[0] * 100,
        pointer_down[1] + mouse_down_projection.direction[1] * 100,
    };
    try std.testing.expect(state.applyGizmoPointer(.x, pointer_after_long_drag));

    const moved_screen = projection.project(state.position).?;
    const moved_projection = projectAxis(projection, state.position, moved_screen, .x).?;
    try std.testing.expect(@abs(moved_projection.pixels_per_meter - mouse_down_projection.pixels_per_meter) > 1);
    try std.testing.expectApproxEqAbs(pointer_after_long_drag[0], moved_projection.endpoint[0], 0.01);
    try std.testing.expectApproxEqAbs(pointer_after_long_drag[1], moved_projection.endpoint[1], 0.01);

    const pointer_after_one_more_pixel = [2]f32{
        pointer_after_long_drag[0] + mouse_down_projection.direction[0],
        pointer_after_long_drag[1] + mouse_down_projection.direction[1],
    };
    try std.testing.expect(state.applyGizmoPointer(.x, pointer_after_one_more_pixel));
    const final_screen = projection.project(state.position).?;
    const final_projection = projectAxis(projection, state.position, final_screen, .x).?;
    try std.testing.expectApproxEqAbs(pointer_after_one_more_pixel[0], final_projection.endpoint[0], 0.01);
    try std.testing.expectApproxEqAbs(pointer_after_one_more_pixel[1], final_projection.endpoint[1], 0.01);

    state.endGizmoDrag();
    try std.testing.expect(!state.applyGizmoPointer(.x, pointer_after_one_more_pixel));
}

test "incoherent immutable selection cannot produce a draft target" {
    const selected_id = engine.PersistentId{ .namespace = 2, .local = 4 };
    const different_id = engine.PersistentId{ .namespace = 2, .local = 5 };
    const view = tool_module.CrateAuthoringView{
        .session = testSession(selected_id),
        .position_hint = test_position_hint,
        .selected_crate = testCrate(different_id, .{ 0, 0, 0 }),
    };
    var state = State{ .id = selected_id, .position = .{ 9, 9, 9 }, .dirty = true };
    state.synchronize(&view);
    try std.testing.expectEqual(@as(?engine.PersistentId, null), state.id);
    try std.testing.expect(!state.dirty);
}
