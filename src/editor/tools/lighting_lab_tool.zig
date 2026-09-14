//! Lighting Lab submits typed values; the game host owns revisions and disk.
const std = @import("std");
const zgui = @import("zgui");
const contract = @import("lighting_authoring_contract");
const engine = @import("engine_contracts");
const selection = @import("../content_selection.zig");
const projection_math = @import("../gizmo_projection.zig");
const tool = @import("../tool.zig");
pub const descriptor = tool.Descriptor{
    .id = .lighting_lab,
    .name = "Lighting Lab",
    .category = .authoring,
    .default_region = .right,
    .purpose = "Author sun, local fixtures, exposure and bloom with exact units and durable presets.",
    .reads = "Lighting assets, active preset, saved/session/preview values and revisions.",
    .requests = "Preview, apply, undo, redo, revert, activate and commit through the shared lighting owner.",
    .examples = &.{ "illuminate a shop", "aim paired headlights", "save a night preset" },
    .audit_fields = &.{ "target", "revision", "asset_revision", "transaction_id", "source", "rejection" },
};
pub const State = struct {
    gizmo: ?projection_math.GizmoDragMapping = null,
    handles: [3]?tool.viewport.SceneRect = @splat(null),
    target: ?engine.assets.AssetId = null,
    revision: u64 = 0,
    draft: contract.Value = .{ .environment = .{} },
    dirty: bool = false,
    preview_active: bool = false,
    preview_changed: bool = false,
    active_start: ?struct { draft: contract.Value, dirty: bool } = null,
    cancelled_until_release: bool = false,
    observed_transaction: u64 = 0,
    error_text: ?[]const u8 = null,

    pub fn cancelControl(self: *State) bool {
        const start = self.active_start orelse return false;
        self.draft = start.draft;
        self.dirty = start.dirty;
        self.active_start = null;
        self.gizmo = null;
        self.cancelled_until_release = true;
        self.preview_changed = self.preview_active;
        return true;
    }
    pub fn deactivate(self: *State, input: ?contract.Input) void {
        _ = self.cancelControl();
        if (input) |value| if (self.preview_active) self.submit(value, .clear_preview);
        self.preview_changed = false;
        self.handles = @splat(null);
    }
    pub fn deactivateGizmo(self: *State) void {
        if (self.gizmo != null) _ = self.cancelControl();
        self.handles = @splat(null);
    }
    pub fn claimsPointer(self: *const State, point: [2]f32) bool {
        for (self.handles) |region| if (region) |rect| if (point[0] >= rect.minimum[0] and point[0] < rect.maximum[0] and point[1] >= rect.minimum[1] and point[1] < rect.maximum[1]) return true;
        return false;
    }
    fn submit(self: *State, input: contract.Input, action: contract.Action) void {
        input.requests.submit(.{ .target = self.target orelse return, .expected_revision = self.revision, .action = action }) catch |err| {
            self.error_text = @errorName(err);
            return;
        };
        if (action == .preview) self.preview_active = true;
        if (action == .clear_preview) self.preview_active = false;
    }
    fn control(self: *State, before: contract.Value, was_dirty: bool, changed: bool) void {
        if (zgui.isItemActivated()) self.active_start = .{ .draft = before, .dirty = was_dirty };
        if (changed) {
            self.dirty = true;
            self.preview_changed = true;
        }
        if (zgui.isItemDeactivated()) self.active_start = null;
    }
    fn scalar(self: *State, label: [:0]const u8, value: *f32) void {
        const before = self.draft;
        const dirty = self.dirty;
        self.control(before, dirty, zgui.inputFloat(label, .{ .v = value }));
    }
    fn vector(self: *State, label: [:0]const u8, value: *[3]f32) void {
        const before = self.draft;
        const dirty = self.dirty;
        self.control(before, dirty, zgui.inputFloat3(label, .{ .v = value }));
    }
    fn toggle(self: *State, label: [:0]const u8, value: *bool) void {
        const before = self.draft;
        const dirty = self.dirty;
        self.control(before, dirty, zgui.checkbox(label, .{ .v = value }));
    }
};
pub fn draw(state: *State, maybe_input: ?contract.Input, content_view: selection.View, selection_requests: *selection.Requests) void {
    defer zgui.end();
    if (!zgui.begin("Lighting Lab", .{})) return;
    const input = maybe_input orelse {
        zgui.textDisabled("Lighting authoring is unavailable in this composition.", .{});
        return;
    };
    const selected = content_view.activeEntry();
    const id = if (selected) |entry| if (entry.kind == .lighting) entry.id else input.view.active_environment else input.view.active_environment;
    var active: ?contract.Record = null;
    for (input.view.records) |record| if (std.meta.eql(record.id, id)) {
        active = record;
        break;
    };
    const record = active orelse {
        state.deactivate(input);
        return;
    };
    if (zgui.beginCombo("Asset", .{ .preview_value = zgui.formatZ("{s}", .{record.label}) })) {
        for (input.view.records) |other| if (zgui.selectable(zgui.formatZ("{s}", .{other.label}), .{ .selected = std.meta.eql(record.id, other.id) })) {
            state.deactivate(input);
            selection_requests.submit(.{ .select = other.id });
        };
        zgui.endCombo();
    }
    const changed_target = state.target == null or !std.meta.eql(state.target.?, record.id);
    var own_change = false;
    if (input.view.last_ui_outcome) |outcome| if (outcome.transaction_id != state.observed_transaction) {
        state.observed_transaction = outcome.transaction_id;
        if (std.meta.eql(record.id, outcome.target)) {
            state.error_text = if (outcome.rejection) |reason| @tagName(reason) else null;
            own_change = outcome.rejection == null and outcome.action != .preview and outcome.action != .clear_preview and outcome.action != .activate;
        }
    };
    if (changed_target) state.deactivate(input);
    if (changed_target or own_change or (!state.dirty and state.active_start == null and !state.preview_active)) {
        state.target = record.id;
        state.revision = record.revision;
        state.draft = record.session;
        state.dirty = false;
        state.active_start = null;
    }
    state.preview_active = if (record.preview) |preview| preview.source == .ui else false;
    zgui.textDisabled("Session r{d} | Asset r{d}", .{ record.revision, record.asset_revision });
    if (state.revision != record.revision) zgui.textWrapped("Changed elsewhere: draft retains r{d}. Re-select to discard it.", .{state.revision});
    if (!zgui.isMouseDown(.left)) state.cancelled_until_release = false;
    zgui.beginDisabled(.{ .disabled = state.cancelled_until_release });
    switch (state.draft) {
        .environment => |*environment| {
            zgui.text("Sun (lux), linear color; ray direction points from sun to ground.", .{});
            state.scalar("Sun lux", &environment.sun.intensity);
            state.vector("Sun color", &environment.sun.color);
            const before = state.draft;
            const dirty = state.dirty;
            var direction = environment.sun_direction;
            if (zgui.inputFloat3("Sun ray direction", .{ .v = &direction })) {
                const length = @sqrt(direction[0] * direction[0] + direction[1] * direction[1] + direction[2] * direction[2]);
                if (length > 1e-6) {
                    for (&direction) |*v| v.* /= length;
                    environment.sun_direction = direction;
                    state.control(before, dirty, true);
                }
            } else state.control(before, dirty, false);
            state.vector("Ambient irradiance", &environment.ambient);
            state.vector("Background radiance", &environment.background);
            state.scalar("Exposure multiplier", &environment.display.exposure);
            state.scalar("Bloom strength", &environment.display.bloom_strength);
            state.scalar("Bloom threshold (exposed)", &environment.display.bloom_threshold);
            state.scalar("Bloom radius (pixels)", &environment.display.bloom_radius);
            state.toggle("Artificial fixtures enabled", &environment.artificial_lights_enabled);
            state.toggle("Vehicle headlights enabled", &environment.headlights_enabled);
            state.toggle("Sun shadows", &environment.sun.casts_shadows);
            state.scalar("Shadow depth bias", &environment.shadow_bias);
            const previous = state.draft;
            const previous_dirty = state.dirty;
            state.control(previous, previous_dirty, zgui.inputScalar("Shadow resolution (pixels)", u32, .{ .v = &environment.shadow_resolution }));
        },
        .fixture => |*fixture| {
            zgui.text("Mount: {s} | Local forward is -Z", .{@tagName(fixture.mount)});
            if (zgui.beginCombo("Light type", .{ .preview_value = @tagName(fixture.light.kind) })) {
                inline for (std.meta.tags(engine.lighting.Kind)) |kind| if (zgui.selectable(@tagName(kind), .{ .selected = fixture.light.kind == kind })) {
                    fixture.light.kind = kind;
                    state.dirty = true;
                    state.preview_changed = true;
                };
                zgui.endCombo();
            }
            state.toggle("Enabled", &fixture.light.enabled);
            state.toggle("Follow artificial-light preset", &fixture.follows_night);
            state.scalar(if (fixture.light.kind == .directional) "Intensity (lux)" else "Intensity (candela)", &fixture.light.intensity);
            state.vector("Linear color", &fixture.light.color);
            state.vector("Mount position (metres)", &fixture.pose.position);
            const before = state.draft;
            const dirty = state.dirty;
            state.control(before, dirty, zgui.inputFloat4("Mount rotation (quaternion)", .{ .v = &fixture.pose.rotation }));
            var bounded = fixture.light.range != null;
            const range_before = state.draft;
            const range_dirty = state.dirty;
            if (zgui.checkbox("Finite distance cutoff", .{ .v = &bounded })) {
                fixture.light.range = if (bounded) 24 else null;
                state.control(range_before, range_dirty, true);
            } else state.control(range_before, range_dirty, false);
            if (fixture.light.range) |*range| state.scalar("Range (metres)", range);
            state.scalar("Source radius (metres)", &fixture.light.source_radius);
            if (fixture.light.kind == .spot) {
                inline for (.{ .{ "Inner half angle (degrees)", "inner_angle" }, .{ "Outer half angle (degrees)", "outer_angle" } }) |angle| {
                    const angle_before = state.draft;
                    const angle_dirty = state.dirty;
                    var degrees = @field(fixture.light, angle[1]) * 180 / std.math.pi;
                    const changed = zgui.inputFloat(angle[0], .{ .v = &degrees });
                    if (changed) @field(fixture.light, angle[1]) = degrees * std.math.pi / 180;
                    state.control(angle_before, angle_dirty, changed);
                }
            }
            state.toggle("Cast shadows", &fixture.light.casts_shadows);
            if (fixture.surface) |*surface| state.scalar("Surface emission scale", &surface.emissive_scale);
            if (fixture.visual) |*visual| {
                state.scalar("Lens emission scale", &visual.emissive_scale);
                state.vector("Lens local offset (metres)", &visual.local_pose.position);
                state.vector("Lens dimensions (metres)", &visual.scale);
            }
            zgui.textWrapped("Source radius regularizes near-source intensity; it does not simulate an area light. Brightness and surface emission are independent.", .{});
        },
    }
    zgui.endDisabled();
    if (state.preview_changed) {
        state.preview_changed = false;
        state.submit(input, .{ .preview = state.draft });
    }
    if (zgui.button("Apply", .{})) state.submit(input, .{ .apply = state.draft });
    zgui.sameLine(.{});
    if (zgui.button("Clear Preview", .{})) state.submit(input, .clear_preview);
    if (zgui.button("Undo", .{})) state.submit(input, .undo);
    zgui.sameLine(.{});
    if (zgui.button("Redo", .{})) state.submit(input, .redo);
    zgui.sameLine(.{});
    if (zgui.button("Revert", .{})) state.submit(input, .revert);
    if (record.session == .environment and !std.meta.eql(record.id, input.view.active_environment)) if (zgui.button("Activate Preset", .{})) state.submit(input, .activate);
    zgui.beginDisabled(.{ .disabled = !input.view.persistence_available });
    if (zgui.button("Commit Asset", .{})) state.submit(input, .commit);
    zgui.endDisabled();
    if (input.view.installed_root) |root| zgui.textWrapped("Installed content: {s}", .{root});
    if (input.view.project_root) |root| zgui.textWrapped("Commit destination: {s}/lighting.iclight", .{root});
    if (!input.view.persistence_available) zgui.textWrapped("Commit requires an explicit lighting project root. Session edits remain available.", .{});
    if (zgui.collapsingHeader("Units and field meanings", .{})) for (contract.fields) |field| {
        zgui.textWrapped("{s} [{s}]: {s}", .{ field.path, field.unit, field.description });
    };
    if (state.error_text) |error_text| zgui.textColored(.{ 1, 0.4, 0.2, 1 }, "{s}", .{error_text});
}

/// Bounded handles only. A drag previews the same draft as numeric controls;
/// release retains it and Apply remains the only session transaction.
pub fn drawGizmo(state: *State, input: ?contract.Input, camera: tool.CameraView, scene: tool.viewport.SceneRect, extent: [2]f32) void {
    state.handles = @splat(null);
    if (state.draft != .fixture or state.draft.fixture.mount != .world or state.target == null) return;
    const projection = projection_math.ScreenProjection{ .camera = camera, .screen_extent = extent };
    const position = state.draft.fixture.pose.position;
    const origin = projection.project(position) orelse return;
    if (!projection_math.pointInsideInset(scene, origin, 12)) return;
    const colors = [_][4]f32{ .{ 1, 0.2, 0.15, 1 }, .{ 0.2, 1, 0.3, 1 }, .{ 0.2, 0.4, 1, 1 } };
    for (std.meta.tags(projection_math.Axis)) |axis| {
        const i = @intFromEnum(axis);
        const projected = projection_math.projectAxis(projection, position, origin, axis) orelse continue;
        if (!projection_math.pointInsideInset(scene, projected.endpoint, 12)) continue;
        const region = tool.viewport.SceneRect{ .minimum = .{ projected.endpoint[0] - 12, projected.endpoint[1] - 12 }, .maximum = .{ projected.endpoint[0] + 12, projected.endpoint[1] + 12 } };
        state.handles[i] = region;
        zgui.getBackgroundDrawList().addLine(.{ .p1 = origin, .p2 = projected.endpoint, .col = zgui.colorConvertFloat4ToU32(colors[i]), .thickness = 3 });
        zgui.setNextWindowPos(.{ .x = region.minimum[0], .y = region.minimum[1], .cond = .always });
        zgui.setNextWindowSize(.{ .w = 24, .h = 24, .cond = .always });
        zgui.pushStyleVar2f(.{ .idx = .window_padding, .v = .{ 0, 0 } });
        defer zgui.popStyleVar(.{});
        if (zgui.begin(zgui.formatZ("##lighting_handle_{d}", .{i}), .{ .flags = .{ .no_title_bar = true, .no_resize = true, .no_move = true, .no_collapse = true, .no_background = true, .no_saved_settings = true, .no_focus_on_appearing = true, .no_bring_to_front_on_focus = true, .no_nav_focus = true, .no_docking = true, .no_scrollbar = true, .no_scroll_with_mouse = true } })) {
            zgui.getWindowDrawList().addCircleFilled(.{ .p = projected.endpoint, .r = 9, .col = zgui.colorConvertFloat4ToU32(colors[i]) });
            _ = zgui.invisibleButton("##drag", .{ .w = 24, .h = 24 });
            if (zgui.isItemActive() and !state.cancelled_until_release) {
                if (state.gizmo == null) {
                    state.active_start = .{ .draft = state.draft, .dirty = state.dirty };
                    state.gizmo = projection_math.GizmoDragMapping.init(projection, axis, position, origin, projected, zgui.getMousePos());
                }
                if (state.gizmo) |mapping| if (mapping.axis == axis) if (mapping.worldDisplacement(zgui.getMousePos())) |meters| {
                    state.draft.fixture.pose.position[i] = state.active_start.?.draft.fixture.pose.position[i] + meters;
                    state.dirty = true;
                    if (input) |value| state.submit(value, .{ .preview = state.draft });
                };
            }
        }
        zgui.end();
    }
    if (!zgui.isMouseDown(.left) and state.gizmo != null) {
        state.gizmo = null;
        state.active_start = null;
    }
}
