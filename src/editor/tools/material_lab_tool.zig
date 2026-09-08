//! Material Lab edits one game-owned material through the shared typed owner.
const std = @import("std");
const zgui = @import("zgui");
const tool = @import("../tool.zig");
const selection = @import("../content_selection.zig");
const engine = @import("incinerator_engine");
const contract = @import("material_authoring_contract");
const assets = engine.assets;

pub const descriptor = tool.Descriptor{
    .id = .material_lab,
    .name = "Material Lab",
    .category = .authoring,
    .default_region = .right,
    .purpose = "Preview, edit, revert, and commit game materials in the scene and a neutral preview.",
    .reads = "Selected material identity, committed/session values, revisions, texture dependencies and producer outcomes.",
    .requests = "Typed material preview, apply, revert, and durable asset commit through the same owner as the CLI.",
    .examples = &.{ "weather the warehouse brick", "adjust painted metal roughness", "commit and relaunch" },
    .audit_fields = &.{ "material_id", "revision", "asset_revision", "transaction_id", "source", "rejection" },
};

// Native acceptance reads the actual ImGui item rectangles; no product input
// or mutation API is introduced by this test-only observation.
pub const AcceptanceItem = enum { roughness, preview, apply, revert, commit };
pub var acceptance_rects: if (@import("builtin").is_test) [5][2][2]f32 else void = if (@import("builtin").is_test) @splat(@splat(@splat(0))) else {};
fn observeAcceptanceItem(item: AcceptanceItem) void {
    if (comptime @import("builtin").is_test) acceptance_rects[@intFromEnum(item)] = .{ zgui.getItemRectMin(), zgui.getItemRectMax() };
}

pub const State = struct {
    target: ?assets.AssetId = null,
    revision: u64 = 0,
    draft: assets.MaterialMetadata = .{ .base_color = .{ 1, 1, 1, 1 }, .base_color_texture = null, .base_color_texcoord = 0 },
    dirty: bool = false,
    preview_active: bool = false,
    observed_ui_transaction: u64 = 0,
    active_start: ?struct { draft: assets.MaterialMetadata, dirty: bool } = null,
    preview_changed: bool = false,
    cancelled_until_release: bool = false,
    error_text: ?[]const u8 = null,
    binding_target: ?assets.AssetId = null,
    binding_revision: u64 = 0,
    binding_preview_active: bool = false,

    pub fn cancelControl(self: *State) bool {
        const start = self.active_start orelse return false;
        self.draft = start.draft;
        self.dirty = start.dirty;
        self.active_start = null;
        self.cancelled_until_release = true;
        self.preview_changed = self.preview_active;
        return true;
    }

    pub fn synchronize(self: *State, record: contract.Record, outcome: ?contract.Outcome) void {
        const changed_target = self.target == null or !std.meta.eql(self.target.?, record.id);
        var own_change = false;
        if (outcome) |value| {
            if (value.transaction_id != self.observed_ui_transaction) {
                self.observed_ui_transaction = value.transaction_id;
                if (std.meta.eql(value.target, record.id)) {
                    if (value.rejection) |reason| self.error_text = @tagName(reason) else {
                        self.error_text = null;
                        own_change = value.action == .apply or value.action == .revert or value.action == .commit;
                    }
                }
            }
        }
        if (changed_target or own_change or (!self.dirty and self.active_start == null and !self.preview_active)) {
            self.target = record.id;
            self.revision = record.revision;
            self.draft = record.session;
            self.dirty = false;
            self.active_start = null;
            if (changed_target or own_change) self.preview_active = false;
        }
        self.preview_active = if (record.preview) |preview| preview.source == .ui else false;
    }

    fn submit(self: *State, input: contract.Input, action: contract.Action) void {
        const target = self.target orelse return;
        input.requests.submit(.{ .target = target, .expected_revision = self.revision, .action = action }) catch |err| {
            self.error_text = @errorName(err);
            return;
        };
        if (action == .preview) self.preview_active = true;
        if (action == .clear_preview) self.preview_active = false;
    }

    pub fn deactivate(self: *State, input: ?contract.Input) void {
        _ = self.cancelControl();
        if (input) |value| {
            if (self.preview_active) self.submit(value, .clear_preview);
            if (self.binding_preview_active) if (self.binding_target) |mesh_id| {
                value.requests.submit(.{ .target = mesh_id, .expected_revision = self.binding_revision, .action = .clear_preview }) catch {};
            };
            value.preview_material.* = null;
        }
        self.binding_target = null;
        self.binding_preview_active = false;
    }

    fn control(self: *State, before: assets.MaterialMetadata, before_dirty: bool, changed: bool) void {
        if (zgui.isItemActivated()) self.active_start = .{ .draft = before, .dirty = before_dirty };
        if (changed) {
            self.dirty = true;
            self.preview_changed = self.preview_active;
        }
        if (zgui.isItemDeactivated()) self.active_start = null;
    }
};

pub fn draw(state: *State, maybe_input: ?contract.Input, content_view: selection.View, selection_requests: *selection.Requests) void {
    defer zgui.end();
    if (!zgui.begin("Material Lab", .{})) return;
    const input = maybe_input orelse {
        zgui.textDisabled("Material authoring is unavailable in this composition.", .{});
        return;
    };
    const selected = content_view.activeEntry();
    var active: ?contract.Record = null;
    if (selected) |entry| {
        var material_id = entry.id;
        if (entry.kind == .mesh) {
            for (input.view.bindings) |binding| if (std.meta.eql(binding.mesh, entry.id)) {
                if (state.binding_target) |old| if (!std.meta.eql(old, binding.mesh)) state.deactivate(input);
                state.binding_target = binding.mesh;
                state.binding_revision = binding.revision;
                state.binding_preview_active = if (binding.preview) |preview| preview.source == .ui else false;
                drawBinding(state, input, binding, entry.label);
                material_id = binding.presented();
                break;
            };
        } else if (state.binding_target != null) state.deactivate(input);
        for (input.view.records) |record| if (std.meta.eql(record.id, material_id)) {
            active = record;
            break;
        };
    }
    if (active == null) {
        state.deactivate(input);
        zgui.textWrapped("Select a material in Content Browser or choose one below.", .{});
    }
    zgui.setNextItemWidth(-1);
    if (zgui.beginCombo("##Material", .{ .preview_value = if (active) |value| zgui.formatZ("{s}", .{value.label}) else "Choose material" })) {
        for (input.view.records, 0..) |record, index| {
            zgui.pushIntId(@intCast(index));
            if (zgui.selectable(zgui.formatZ("{s}", .{record.label}), .{ .selected = if (active) |value| std.meta.eql(value.id, record.id) else false })) {
                state.deactivate(input);
                selection_requests.submit(.{ .select = record.id });
            }
            zgui.popId();
        }
        zgui.endCombo();
    }
    const record = active orelse return;
    if (state.target) |target| {
        if (!std.meta.eql(target, record.id) and state.preview_active) state.submit(input, .clear_preview);
    }
    state.synchronize(record, input.view.last_ui_outcome);
    input.preview_material.* = record.id;
    zgui.textDisabled("Session r{d} | Asset r{d}", .{ record.revision, record.asset_revision });
    if (state.dirty and state.revision != record.revision) {
        zgui.textColored(.{ 1, 0.65, 0.2, 1 }, "Material changed elsewhere; draft retains r{d}.", .{state.revision});
    }
    if (zgui.radioButton("In World", .{ .active = input.preview_mode.* == .world })) input.preview_mode.* = .world;
    zgui.sameLine(.{});
    if (zgui.radioButton("Neutral Preview", .{ .active = input.preview_mode.* == .neutral })) input.preview_mode.* = .neutral;
    if (input.preview_mode.* == .neutral) {
        const width = zgui.getContentRegionAvail()[0];
        if (width > 0 and std.math.isFinite(width)) input.preview_extent.* = @intFromFloat(@ceil(width));
        if (input.preview_image) |preview| zgui.image(.{ .tex_data = null, .tex_id = @enumFromInt(@intFromPtr(preview.binding)) }, .{ .w = width, .h = width });
        zgui.textDisabled("Neutral lighting", .{});
    }
    zgui.separator();
    if (!zgui.isMouseDown(.left)) state.cancelled_until_release = false;
    zgui.beginDisabled(.{ .disabled = state.cancelled_until_release });
    defer zgui.endDisabled();

    inline for (.{ "base_color", "emissive" }) |field| {
        const before = state.draft;
        const dirty = state.dirty;
        zgui.text(if (comptime std.mem.eql(u8, field, "base_color")) "Base Color (linear factor)" else "Emission (linear)", .{});
        zgui.setNextItemWidth(-1);
        const changed = if (comptime std.mem.eql(u8, field, "base_color"))
            zgui.inputFloat4("##BaseColor", .{ .v = &state.draft.base_color })
        else
            zgui.inputFloat3("##Emission", .{ .v = &state.draft.emissive });
        state.control(before, dirty, changed);
    }
    inline for (.{ .{ "metallic", "Metallic Factor" }, .{ "roughness", "Roughness Factor" }, .{ "occlusion_strength", "Occlusion Strength" } }) |field| {
        const before = state.draft;
        const dirty = state.dirty;
        zgui.text("{s}", .{field[1]});
        zgui.setNextItemWidth(-1);
        const changed = zgui.sliderFloat("##" ++ field[1], .{ .v = &@field(state.draft, field[0]), .min = 0, .max = 1 });
        state.control(before, dirty, changed);
        if (comptime std.mem.eql(u8, field[0], "roughness")) observeAcceptanceItem(.roughness);
    }
    {
        const before = state.draft;
        const dirty = state.dirty;
        zgui.text("Normal Scale", .{});
        zgui.setNextItemWidth(-1);
        const changed = zgui.inputFloat("##NormalScale", .{ .v = &state.draft.normal_scale });
        state.control(before, dirty, changed);
    }
    if (zgui.collapsingHeader("Texture Maps", .{})) {
        inline for (.{ .{ "base_color_texture", "Base Color Map", true }, .{ "metallic_roughness_texture", "Metallic / Roughness Map", false }, .{ "normal_texture", "Normal Map", false }, .{ "occlusion_texture", "Occlusion Map", false }, .{ "emissive_texture", "Emissive Map", true } }) |slot| {
            const current = @field(state.draft, slot[0]);
            var label: []const u8 = "None";
            for (content_view.entries) |entry| {
                if (current) |id| if (std.meta.eql(entry.id, id)) {
                    label = entry.label;
                    break;
                };
            }
            zgui.text("{s}", .{slot[1]});
            zgui.setNextItemWidth(-1);
            if (zgui.beginCombo("##" ++ slot[1], .{ .preview_value = zgui.formatZ("{s}", .{label}) })) {
                if (zgui.selectable("None", .{ .selected = current == null })) {
                    @field(state.draft, slot[0]) = null;
                    state.dirty = true;
                    state.preview_changed = state.preview_active;
                }
                for (content_view.entries, 0..) |entry, index| {
                    if (entry.kind != .texture or entry.details.texture.color_space != (if (slot[2]) assets.ColorSpace.srgb else .linear)) continue;
                    zgui.pushIntId(@intCast(index));
                    if (zgui.selectable(zgui.formatZ("{s}", .{entry.label}), .{ .selected = if (current) |id| std.meta.eql(id, entry.id) else false })) {
                        @field(state.draft, slot[0]) = entry.id;
                        state.dirty = true;
                        state.preview_changed = state.preview_active;
                    }
                    zgui.popId();
                }
                zgui.endCombo();
            }
        }
    }
    zgui.separator();
    if (zgui.button(if (state.preview_active) "Stop Preview" else "Preview Draft", .{})) {
        if (state.preview_active) state.submit(input, .clear_preview) else state.submit(input, .{ .preview = state.draft });
    }
    observeAcceptanceItem(.preview);
    zgui.sameLine(.{});
    if (zgui.button("Discard Draft", .{})) {
        state.submit(input, .clear_preview);
        state.draft = record.session;
        state.revision = record.revision;
        state.dirty = false;
        state.error_text = null;
    }
    if (state.preview_changed and state.preview_active) state.submit(input, .{ .preview = state.draft });
    state.preview_changed = false;
    if (zgui.button("Apply to Session", .{})) state.submit(input, .{ .apply = state.draft });
    observeAcceptanceItem(.apply);
    zgui.sameLine(.{});
    if (zgui.button("Revert to Asset", .{})) state.submit(input, .revert);
    observeAcceptanceItem(.revert);
    zgui.beginDisabled(.{ .disabled = state.dirty or state.preview_active or !input.view.persistence_available });
    if (zgui.button("Commit Material Asset", .{})) state.submit(input, .commit);
    observeAcceptanceItem(.commit);
    zgui.endDisabled();
    if (!input.view.persistence_available) zgui.textWrapped("Commit requires a game project. Launch with INCINERATOR_MATERIAL_ROOT set to its material asset directory.", .{});
    if (state.dirty) zgui.textColored(.{ 1, 0.75, 0.25, 1 }, "Unapplied draft", .{});
    if (record.dirty()) zgui.textDisabled("Session differs from the saved game asset.", .{});
    if (state.error_text) |message| zgui.textColored(.{ 1, 0.4, 0.3, 1 }, "{s}", .{message});
}

fn drawBinding(state: *State, input: contract.Input, binding: contract.BindingRecord, label: []const u8) void {
    zgui.textWrapped("Surface: {s}", .{label});
    zgui.textDisabled("Assignment r{d} | Saved r{d}", .{ binding.revision, binding.asset_revision });
    const current = binding.presented();
    var current_label: []const u8 = "Missing material";
    for (input.view.records) |record| if (std.meta.eql(record.id, current)) {
        current_label = record.label;
        break;
    };
    zgui.text("Assign Material", .{});
    zgui.setNextItemWidth(-1);
    if (zgui.beginCombo("##AssignMaterial", .{ .preview_value = zgui.formatZ("{s}", .{current_label}) })) {
        for (input.view.records, 0..) |record, index| {
            zgui.pushIntId(@intCast(index));
            if (zgui.selectable(zgui.formatZ("{s}", .{record.label}), .{ .selected = std.meta.eql(current, record.id) })) {
                submitBinding(state, input, binding, .{ .preview_assignment = record.id });
            }
            zgui.popId();
        }
        zgui.endCombo();
    }
    if (zgui.button("Apply Assignment", .{})) submitBinding(state, input, binding, .{ .assign = current });
    if (zgui.button("Revert Assignment", .{})) submitBinding(state, input, binding, .revert);
    if (binding.preview != null) {
        if (zgui.button("Stop Assignment Preview", .{})) submitBinding(state, input, binding, .clear_preview);
    }
    zgui.beginDisabled(.{ .disabled = binding.preview != null or !input.view.persistence_available });
    if (zgui.button("Commit Assignment", .{})) submitBinding(state, input, binding, .commit);
    zgui.endDisabled();
    if (input.view.last_ui_outcome) |outcome| if (std.meta.eql(outcome.target, binding.mesh)) {
        if (outcome.rejection) |reason| zgui.textColored(.{ 1, 0.4, 0.3, 1 }, "{s}", .{@tagName(reason)});
    };
    zgui.separator();
}

fn submitBinding(state: *State, input: contract.Input, binding: contract.BindingRecord, action: contract.Action) void {
    input.requests.submit(.{ .target = binding.mesh, .expected_revision = binding.revision, .action = action }) catch |err| {
        state.error_text = @errorName(err);
    };
}

test "material draft survives external edits and cancellation restores the complete control start" {
    const id = assets.AssetId{ .namespace = 1, .local = 1 };
    var record = contract.Record{ .id = id, .label = "Brick", .revision = 1, .asset_revision = 1, .committed = .{ .base_color = .{ 1, 1, 1, 1 }, .base_color_texture = null, .base_color_texcoord = 0 }, .session = .{ .base_color = .{ 1, 1, 1, 1 }, .base_color_texture = null, .base_color_texcoord = 0 } };
    var state = State{};
    state.synchronize(record, null);
    state.draft.roughness = 0.4;
    state.dirty = true;
    const before = state.draft;
    state.active_start = .{ .draft = before, .dirty = true };
    state.draft.metallic = 1;
    try std.testing.expect(state.cancelControl());
    try std.testing.expectEqualDeep(before, state.draft);
    try std.testing.expect(state.dirty);
    record.revision = 2;
    record.session.roughness = 0.8;
    state.synchronize(record, null);
    try std.testing.expectEqual(@as(u64, 1), state.revision);
    try std.testing.expectEqualDeep(before, state.draft);
}
