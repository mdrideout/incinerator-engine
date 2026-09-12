//! Vehicle Lab owns an editable copy. Controls never mutate authority directly.
const std = @import("std");
const zgui = @import("zgui");
const tool = @import("../tool.zig");
const contract = @import("vehicle_authoring_contract");
const vehicle = contract.vehicle;
const engine = @import("incinerator_engine");
pub const descriptor = tool.Descriptor{
    .id = .vehicle_lab,
    .name = "Vehicle Lab",
    .category = .authoring,
    .default_region = .right,
    .purpose = "Author, measure, drive and commit a selected vehicle archetype.",
    .reads = "Admitted and saved definitions, revision lineage, live wheel and powertrain telemetry, and correlated results.",
    .requests = "Apply automatically selects live update or physics reconstruction, plus revert, atomic archetype commit and isolated candidate measurement.",
    .examples = &.{ "adjust sedan roll", "measure a torque curve", "commit a road car" },
    .audit_fields = &.{ "archetype_id", "definition_digest", "instance_revision", "asset_revision", "transaction_id", "authority_tick" },
};
pub const AcceptanceItem = enum { torque, apply, revert, commit, measure, mass, preset };
pub var acceptance_rects: if (@import("builtin").is_test) [std.meta.fields(AcceptanceItem).len][2][2]f32 else void = if (@import("builtin").is_test) @splat(@splat(@splat(0))) else {};
fn observe(item: AcceptanceItem) void {
    if (comptime @import("builtin").is_test) acceptance_rects[@intFromEnum(item)] = .{ zgui.getItemRectMin(), zgui.getItemRectMax() };
}

pub const State = struct {
    target: ?engine.PersistentId = null,
    draft: ?vehicle.asset.Owned = null,
    revision: u64 = 0,
    asset_revision: u64 = 0,
    dirty: bool = false,
    preset_index: usize = 0,
    pending: ?u64 = null,
    observed_transaction: u64 = 0,
    error_text: ?[]const u8 = null,
    active_start: ?struct { field: *f32, before: f32, dirty: bool } = null,
    cancelled_until_release: bool = false,

    pub fn loadPreset(self: *State, allocator: std.mem.Allocator, preset: contract.HandlingPreset) !void {
        var replacement = try preset.candidate.clone(allocator);
        errdefer replacement.deinit();
        _ = self.cancelControl();
        if (self.draft) |*old| old.deinit();
        self.draft = replacement;
        self.dirty = true;
        self.error_text = null;
    }

    pub fn deinit(self: *State) void {
        _ = self.cancelControl();
        if (self.draft) |*draft| draft.deinit();
        self.* = .{};
    }
    pub fn cancelControl(self: *State) bool {
        const start = self.active_start orelse return false;
        start.field.* = start.before;
        self.dirty = start.dirty;
        self.active_start = null;
        self.cancelled_until_release = true;
        return true;
    }
    pub fn deactivate(self: *State) void {
        _ = self.cancelControl();
    }
    pub fn synchronize(self: *State, allocator: std.mem.Allocator, inspection: contract.Inspection, result: ?contract.Result) !void {
        const changed = self.target == null or !std.meta.eql(self.target.?, inspection.live.id);
        if (changed) self.pending = null;
        var own_completed = false;
        if (result) |value| if (std.meta.eql(value.target, inspection.live.id)) {
            if (value.disposition == .pending) self.pending = value.transaction_id else if (self.observed_transaction != value.transaction_id) {
                self.pending = null;
                self.observed_transaction = value.transaction_id;
                self.error_text = value.rejection;
                own_completed = value.disposition == .accepted and switch (value.action) {
                    .apply, .rebuild, .revert, .commit => true,
                    else => false,
                };
            }
        };
        if (changed or own_completed or (!self.dirty and self.active_start == null and self.pending == null and (self.revision != inspection.live.revision or self.asset_revision != inspection.asset_revision))) {
            var replacement = try inspection.live.definition.clone(allocator);
            replacement.value.revision = inspection.asset_revision;
            _ = self.cancelControl();
            if (self.draft) |*draft| draft.deinit();
            self.draft = replacement;
            self.target = inspection.live.id;
            self.revision = inspection.live.revision;
            self.asset_revision = inspection.asset_revision;
            self.dirty = false;
        }
    }
    fn submit(self: *State, input: contract.Input, action: contract.Action) void {
        input.requests.submit(.{ .target = self.target orelse return, .expected_revision = self.revision, .expected_asset_revision = self.asset_revision, .action = action }) catch |err| {
            self.error_text = @errorName(err);
        };
    }
    pub fn applyDraft(self: *State, input: contract.Input) void {
        const inspection = input.inspection orelse return;
        const draft = &(self.draft orelse return).value;
        const effect = vehicle.reconfigurationEffect(inspection.live.definition.tuning, draft.tuning);
        self.submit(input, if (effect == .rebuild) .{ .rebuild = draft.* } else .{ .apply = draft.* });
    }
    fn scalar(self: *State, label: [:0]const u8, value: *f32) void {
        const before = value.*;
        const was_dirty = self.dirty;
        zgui.pushStrId(label);
        defer zgui.popId();
        zgui.pushTextWrapPos(0);
        zgui.textUnformatted(label);
        zgui.popTextWrapPos();
        zgui.setNextItemWidth(zgui.getContentRegionAvail()[0]);
        const changed = zgui.dragFloat("##value", .{ .v = value, .speed = 0.1 });
        if (zgui.isItemActivated()) self.active_start = .{ .field = value, .before = before, .dirty = was_dirty };
        if (changed) self.dirty = true;
        if (zgui.isItemDeactivated()) self.active_start = null;
    }
    fn vector(self: *State, label: []const u8, values: []f32) void {
        zgui.text("{s}", .{label});
        for (values, 0..) |*value, i| {
            zgui.pushIntId(@intCast(i));
            self.scalar(zgui.formatZ("{s} {d}", .{ label, i }), value);
            zgui.popId();
        }
    }
};

pub fn draw(state: *State, maybe_input: ?contract.Input) void {
    defer zgui.end();
    if (!zgui.begin("Vehicle Lab", .{})) {
        state.deactivate();
        return;
    }
    const input = maybe_input orelse {
        zgui.textDisabled("Vehicle authoring is unavailable.", .{});
        return;
    };
    const inspection = input.inspection orelse {
        state.deactivate();
        zgui.textWrapped("Select a car in World Outliner or the scene to author its handling.", .{});
        return;
    };
    state.synchronize(input.allocator, inspection, input.result) catch |err| {
        state.error_text = @errorName(err);
        return;
    };
    if (inspection.presets.len != 0) {
        if (state.preset_index >= inspection.presets.len) state.preset_index = 0;
        zgui.beginDisabled(.{ .disabled = state.pending != null or state.revision != inspection.live.revision or state.asset_revision != inspection.asset_revision });
        if (zgui.beginCombo("Handling preset", .{ .preview_value = zgui.formatZ("{s}", .{inspection.presets[state.preset_index].source_label}) })) {
            for (inspection.presets, 0..) |preset, i| {
                if (zgui.selectable(zgui.formatZ("{s}", .{preset.source_label}), .{ .selected = state.preset_index == i })) state.preset_index = i;
            }
            zgui.endCombo();
        }
        const load = zgui.button("Load Into Draft", .{});
        observe(.preset);
        zgui.endDisabled();
        if (load) {
            state.loadPreset(input.allocator, inspection.presets[state.preset_index]) catch |err| {
                state.error_text = @errorName(err);
            };
            return;
        }
        zgui.textDisabled("Copies handling only. Measure and apply the candidate separately.", .{});
    }
    const draft = &state.draft.?.value;
    const tuning = &draft.tuning;
    zgui.text("{s}", .{draft.label});
    zgui.textDisabled("Instance r{d} | Saved asset r{d}", .{ inspection.live.revision, inspection.asset_revision });
    zgui.text("{s}", .{if (state.dirty) "Draft has unapplied changes" else "Draft matches admitted handling"});
    if (inspection.preview) |preview| zgui.textWrapped("Visual preview active · {s} transaction {d}. Handling remains at instance r{d}.", .{ @tagName(preview.source), preview.transaction_id, inspection.live.revision });
    if (state.revision != inspection.live.revision or state.asset_revision != inspection.asset_revision) zgui.textWrapped("This draft is stale. Discard it to inspect the current revision.", .{});
    if (input.result) |result| {
        zgui.text("{s}: {s} (transaction {d})", .{ @tagName(result.action), @tagName(result.disposition), result.transaction_id });
        if (result.disposition == .accepted) switch (result.action) {
            .apply => zgui.textDisabled("Applied without rebuilding physics.", .{}),
            .rebuild => zgui.textDisabled("Applied by rebuilding vehicle physics.", .{}),
            else => {},
        };
        if (result.artifact_path) |path| zgui.textWrapped("Report: {s}", .{path});
    }
    if (state.error_text) |err| zgui.textColored(.{ 1, 0.55, 0.25, 1 }, "{s}", .{err});
    if (state.pending != null) zgui.textDisabled("Waiting for the owner result…", .{});
    var valid = true;
    draft.validate() catch |err| {
        valid = false;
        zgui.textColored(.{ 1, 0.55, 0.25, 1 }, "Draft: {s}", .{@errorName(err)});
    };
    const effect = vehicle.reconfigurationEffect(inspection.live.definition.tuning, tuning.*);
    zgui.textDisabled("Apply will: {s}", .{switch (effect) {
        .rebuild => "rebuild vehicle physics",
        .live => "update handling live",
        .presentation => "update presentation",
    }});
    zgui.beginDisabled(.{ .disabled = !valid or state.pending != null });
    if (zgui.button("Measure Candidate", .{})) state.submit(input, .{ .measure = draft.* });
    observe(.measure);
    zgui.sameLine(.{});
    if (zgui.button("Apply", .{})) state.applyDraft(input);
    observe(.apply);

    if (zgui.button("Preview Visuals", .{})) state.submit(input, .{ .preview = draft.* });
    zgui.sameLine(.{});
    if (zgui.button("Clear Preview", .{})) state.submit(input, .clear_preview);
    zgui.textDisabled("Visual preview leaves admitted handling active.", .{});
    zgui.endDisabled();
    zgui.beginDisabled(.{ .disabled = state.pending != null });
    if (zgui.button("Revert to Saved", .{})) state.submit(input, .revert);
    observe(.revert);
    zgui.sameLine(.{});
    zgui.beginDisabled(.{ .disabled = !input.persistence_available });
    if (zgui.button("Commit Admitted Car", .{})) state.submit(input, .commit);
    observe(.commit);
    zgui.endDisabled();
    if (!input.persistence_available) zgui.textWrapped("Commit requires INCINERATOR_VEHICLE_ROOT to name the game vehicle asset directory.", .{});
    zgui.endDisabled();
    if (zgui.button("Discard Draft", .{})) {
        state.deactivate();
        state.dirty = false;
        state.target = null;
    }
    zgui.separator();
    if (!zgui.isMouseDown(.left)) state.cancelled_until_release = false;
    zgui.beginDisabled(.{ .disabled = state.cancelled_until_release or state.pending != null });
    defer zgui.endDisabled();
    if (zgui.collapsingHeader("Chassis and wheel layout · metres / kg", .{ .default_open = true })) {
        state.scalar("Mass (kg)", &tuning.mass);
        observe(.mass);
        state.vector("Collision half extents (m)", &tuning.chassis_half_extents);
        state.vector("Center of mass offset (m)", &tuning.center_of_mass_offset);
        for (&tuning.wheel_attachment_positions, 0..) |*position, index| {
            zgui.pushIntId(@intCast(index));
            state.vector(([_][]const u8{ "Front left", "Front right", "Rear left", "Rear right" })[index], position);
            zgui.popId();
        }
        state.scalar("Wheel radius (m)", &tuning.wheel_radius);
        state.scalar("Wheel width (m)", &tuning.wheel_width);
    }
    if (zgui.collapsingHeader("Suspension and anti-roll", .{})) {
        inline for (.{ "suspension_min_length", "suspension_max_length", "suspension_frequency", "suspension_damping" }) |field| {
            state.scalar("Front " ++ field, &@field(tuning, field));
            state.scalar("Rear " ++ field, &@field(tuning.rear_axle, field));
        }
        state.scalar("Front anti-roll (N/m)", &tuning.front_anti_roll_stiffness);
        state.scalar("Rear anti-roll (N/m)", &tuning.rear_axle.anti_roll_stiffness);
        zgui.textDisabled("Travel in metres; frequency in Hz; damping is a ratio.", .{});
    }
    if (zgui.collapsingHeader("Tires and brakes", .{})) {
        inline for (std.meta.fields(engine.physics.VehicleTireFriction)) |field| {
            state.scalar("Front " ++ field.name, &@field(tuning.tire_friction, field.name));
            state.scalar("Rear " ++ field.name, &@field(tuning.rear_axle.tire_friction, field.name));
        }
        state.scalar("Front service brake (N m)", &tuning.max_brake_torque);
        state.scalar("Rear service brake (N m)", &tuning.rear_axle.brake_torque_nm);
        state.scalar("Rear handbrake (N m)", &tuning.max_hand_brake_torque);
        zgui.textDisabled("Lateral angles are radians; longitudinal slip is a ratio.", .{});
    }
    if (zgui.collapsingHeader("Engine, transmission and driven axles", .{ .default_open = true })) {
        inline for (std.meta.fields(engine.physics.VehiclePowertrain)) |field| {
            if (field.type == f32) {
                state.scalar(field.name, &@field(tuning.powertrain, field.name));
                if (comptime std.mem.eql(u8, field.name, "max_torque_nm")) observe(.torque);
            }
        }
        state.scalar("Front differential ratio", &tuning.front_differential_ratio);
        state.scalar("Front limited slip ratio", &tuning.front_limited_slip_ratio);
        zgui.textWrapped("Front torque fraction: 0 = rear drive, 1 = front drive. Intermediate values drive both axles.", .{});
        state.vector("Forward gears", @constCast(tuning.powertrain.forward_gears));
        state.vector("Reverse gears", @constCast(tuning.powertrain.reverse_gears));
        for (@constCast(tuning.powertrain.torque_curve), 0..) |*point, i| {
            zgui.pushIntId(@intCast(i));
            state.scalar("Normalized RPM", &point.rpm_fraction);
            state.scalar("Torque fraction", &point.torque_fraction);
            zgui.popId();
        }
        if (zgui.button("Add forward gear", .{})) appendGear(state, false) catch |err| {
            state.error_text = @errorName(err);
        };
        zgui.sameLine(.{});
        if (zgui.button("Remove final gear", .{}) and tuning.powertrain.forward_gears.len > 1) {
            tuning.powertrain.forward_gears = tuning.powertrain.forward_gears[0 .. tuning.powertrain.forward_gears.len - 1];
            state.dirty = true;
        }
        if (zgui.button("Add torque point", .{})) appendTorquePoint(state) catch |err| {
            state.error_text = @errorName(err);
        };
        zgui.sameLine(.{});
        if (zgui.button("Remove last interior torque point", .{}) and tuning.powertrain.torque_curve.len > 2) {
            const points = @constCast(tuning.powertrain.torque_curve);
            points[points.len - 2] = points[points.len - 1];
            tuning.powertrain.torque_curve = points[0 .. points.len - 1];
            state.dirty = true;
        }
        if (zgui.button("Add reverse gear", .{})) appendGear(state, true) catch |err| {
            state.error_text = @errorName(err);
        };
        zgui.sameLine(.{});
        if (zgui.button("Remove final reverse gear", .{}) and tuning.powertrain.reverse_gears.len > 1) {
            tuning.powertrain.reverse_gears = tuning.powertrain.reverse_gears[0 .. tuning.powertrain.reverse_gears.len - 1];
            state.dirty = true;
        }
        plotCurves("Torque / normalized RPM", engine.physics.VehicleTorquePoint, inspection.committed.tuning.powertrain.torque_curve, inspection.live.definition.tuning.powertrain.torque_curve, tuning.powertrain.torque_curve, "rpm_fraction", "torque_fraction");
    }
    if (zgui.collapsingHeader("Steering", .{})) {
        state.scalar("Steering lock (rad)", &tuning.max_steer_radians);
        state.scalar("Rise rate (1/s)", &tuning.steering.rise_per_second);
        state.scalar("Return rate (1/s)", &tuning.steering.return_per_second);
        for (@constCast(tuning.steering.speed_curve), 0..) |*point, i| {
            zgui.pushIntId(@intCast(i));
            state.scalar("Speed (m/s)", &point.speed_mps);
            state.scalar("Lock fraction", &point.lock_fraction);
            zgui.popId();
        }
        if (zgui.button("Add speed point", .{})) appendSpeedPoint(state) catch |err| {
            state.error_text = @errorName(err);
        };
        zgui.sameLine(.{});
        if (zgui.button("Remove final speed point", .{}) and tuning.steering.speed_curve.len > 1) {
            tuning.steering.speed_curve = tuning.steering.speed_curve[0 .. tuning.steering.speed_curve.len - 1];
            state.dirty = true;
        }
        plotCurves("Steering lock fraction / m/s", vehicle.steering.SpeedPoint, inspection.committed.tuning.steering.speed_curve, inspection.live.definition.tuning.steering.speed_curve, tuning.steering.speed_curve, "speed_mps", "lock_fraction");
    }
    if (zgui.collapsingHeader("Assists", .{})) {
        state.scalar("Pitch / roll limiter (rad)", &tuning.max_pitch_roll_radians);
        if (zgui.button("Unassisted rollover", .{})) {
            tuning.max_pitch_roll_radians = std.math.pi;
            state.dirty = true;
        }
        state.scalar("Wheel contact maximum slope (rad)", &tuning.wheel_collision_max_slope_radians);
    }
    if (zgui.collapsingHeader("Visual bindings", .{})) {
        drawVisual(state, input, "Chassis", &draft.visuals.chassis);
        for (&draft.visuals.wheels, 0..) |*part, i| {
            zgui.pushIntId(@intCast(i));
            drawVisual(state, input, "Wheel", part);
            zgui.popId();
        }
    }
    if (zgui.collapsingHeader("Live telemetry", .{})) {
        zgui.text("RPM {d:.0} | Gear {d} | Conditioned steer {d:.3}", .{ inspection.live.state.engine_rpm, inspection.live.state.current_gear, inspection.live.conditioned_steering });
        for (inspection.live.state.wheels, 0..) |wheel, i| zgui.text("Wheel {d}: contact={} travel={d:.3} m slip={d:.3} rad load impulse={d:.2} N s", .{ i, wheel.has_contact, wheel.suspension_length, wheel.lateral_slip_radians, wheel.suspension_impulse_ns });
    }
    if (zgui.collapsingHeader("Field guide", .{})) for (contract.fields) |field| {
        zgui.text("{s} · {s} · {s}", .{ field.path, field.unit, @tagName(field.effect) });
        zgui.textWrapped("{s}", .{field.description});
    };
    if (zgui.collapsingHeader("Compare complete values", .{})) {
        inline for (.{ "Saved", "Admitted", "Candidate" }, .{ inspection.committed, inspection.live.definition, draft.* }) |label, definition| {
            if (zgui.treeNode(label)) {
                defer zgui.treePop();
                const json = std.json.Stringify.valueAlloc(input.allocator, definition, .{ .whitespace = .indent_2 }) catch return;
                defer input.allocator.free(json);
                zgui.textUnformatted(json);
            }
        }
    }
}

fn plotCurves(label: []const u8, comptime Point: type, saved: []const Point, admitted: []const Point, candidate: []const Point, comptime x_field: []const u8, comptime y_field: []const u8) void {
    var max_x: f32 = 1;
    var max_y: f32 = 1;
    for ([_][]const Point{ saved, admitted, candidate }) |points| for (points) |point| {
        if (!std.math.isFinite(@field(point, x_field)) or !std.math.isFinite(@field(point, y_field))) return;
        max_x = @max(max_x, @field(point, x_field));
        max_y = @max(max_y, @field(point, y_field));
    };
    zgui.text("{s} · x 0…{d:.2}, y 0…{d:.2}", .{ label, max_x, max_y });
    const origin = zgui.getCursorScreenPos();
    const width = @max(zgui.getContentRegionAvail()[0], 1);
    const height: f32 = 100;
    const draw_list = zgui.getWindowDrawList();
    const colors = [_]u32{ 0xff999999, 0xff70c070, 0xff50bfff };
    for ([_][]const Point{ saved, admitted, candidate }, colors) |points, color| {
        for (1..points.len) |i| draw_list.addLine(.{
            .p1 = .{ origin[0] + @field(points[i - 1], x_field) / max_x * width, origin[1] + height * (1 - @field(points[i - 1], y_field) / max_y) },
            .p2 = .{ origin[0] + @field(points[i], x_field) / max_x * width, origin[1] + height * (1 - @field(points[i], y_field) / max_y) },
            .col = color,
            .thickness = 2,
        });
    }
    zgui.dummy(.{ .w = width, .h = height });
    zgui.textDisabled("Gray: saved · Green: admitted · Amber: candidate", .{});
}
fn drawVisual(state: *State, input: contract.Input, label: []const u8, part: *vehicle.asset.VisualPart) void {
    zgui.text("{s}", .{label});
    inline for (.{ "mesh", "material" }) |field| {
        const id = &@field(part, field);
        zgui.pushStrId(label);
        defer zgui.popId();
        zgui.pushStrId(field);
        defer zgui.popId();
        zgui.textUnformatted(field);
        if (zgui.beginCombo("##asset", .{ .preview_value = zgui.formatZ("{x}:{x}", .{ id.namespace, id.local }) })) {
            for (input.catalog) |entry| if (entry.kind == @field(engine.assets.Kind, field)) {
                if (zgui.selectable(zgui.formatZ("{s}", .{entry.label}), .{ .selected = std.meta.eql(id.*, entry.id) })) {
                    id.* = entry.id;
                    state.dirty = true;
                }
            };
            zgui.endCombo();
        }
    }
    state.vector("Visual origin (m)", &part.local_pose.position);
    state.vector("Visual rotation (quaternion)", &part.local_pose.rotation);
    state.vector("Visual scale", &part.scale);
}
fn appendGear(state: *State, reverse: bool) !void {
    const p = &state.draft.?.value.tuning.powertrain;
    const old = if (reverse) p.reverse_gears else p.forward_gears;
    const values = try state.draft.?.arena.allocator().alloc(f32, old.len + 1);
    @memcpy(values[0..old.len], old);
    values[old.len] = old[old.len - 1] * 0.8;
    if (reverse) p.reverse_gears = values else p.forward_gears = values;
    state.dirty = true;
}
fn appendTorquePoint(state: *State) !void {
    const p = &state.draft.?.value.tuning.powertrain;
    const old = p.torque_curve;
    const values = try state.draft.?.arena.allocator().alloc(engine.physics.VehicleTorquePoint, old.len + 1);
    @memcpy(values[0 .. old.len - 1], old[0 .. old.len - 1]);
    values[old.len - 1] = .{ .rpm_fraction = (old[old.len - 2].rpm_fraction + 1) / 2, .torque_fraction = (old[old.len - 2].torque_fraction + old[old.len - 1].torque_fraction) / 2 };
    values[old.len] = old[old.len - 1];
    p.torque_curve = values;
    state.dirty = true;
}
fn appendSpeedPoint(state: *State) !void {
    const p = &state.draft.?.value.tuning.steering;
    const old = p.speed_curve;
    const values = try state.draft.?.arena.allocator().alloc(vehicle.steering.SpeedPoint, old.len + 1);
    @memcpy(values[0..old.len], old);
    values[old.len] = .{ .speed_mps = old[old.len - 1].speed_mps + 10, .lock_fraction = old[old.len - 1].lock_fraction };
    p.speed_curve = values;
    state.dirty = true;
}
