//! Vehicle-specific authoring values shared by the Lab and canonical CLI.
const std = @import("std");
const engine = @import("engine_contracts");
pub const vehicle = @import("vehicle_contract");
pub const Definition = vehicle.asset.Definition;
pub const Action = union(enum) { apply: Definition, rebuild: Definition, revert, commit, measure: Definition, preview: Definition, clear_preview };
pub const Request = struct {
    target: engine.PersistentId,
    expected_revision: u64,
    expected_asset_revision: u64,
    action: Action,
};
pub const Disposition = enum { pending, accepted, rejected };
pub const Result = struct {
    transaction_id: u64,
    source: engine.authoring.Source,
    target: engine.PersistentId,
    action: std.meta.Tag(Action),
    disposition: Disposition,
    revision: u64,
    asset_revision: u64,
    definition_digest: engine.assets.Digest,
    authority_tick: ?u64 = null,
    rejection: ?[]const u8 = null,
    artifact_path: ?[]const u8 = null,
};
pub const Inspection = struct {
    live: vehicle.VehicleView,
    committed: Definition,
    asset_revision: u64,
    presets: []const HandlingPreset = &.{},
    preview: ?struct { source: engine.authoring.Source, transaction_id: u64, visuals: vehicle.asset.Visuals } = null,
};
pub const HandlingPreset = struct {
    source_id: vehicle.VehicleArchetypeId,
    source_label: []const u8,
    source_revision: u64,
    source_digest: engine.assets.Digest,
    candidate: Definition,
};
pub const Evidence = struct {
    run_id: engine.authoring.RunId,
    result: Result,
    before: Definition,
    candidate: ?Definition,
};
pub const AssetSummary = struct { id: vehicle.VehicleArchetypeId, label: []const u8, revision: u64, digest: engine.assets.Digest };
pub const OwnedRequest = struct {
    value: Request,
    definition: ?vehicle.asset.Owned = null,
    pub fn init(allocator: std.mem.Allocator, value: Request) !OwnedRequest {
        var result = OwnedRequest{ .value = value };
        switch (value.action) {
            .apply, .rebuild, .measure, .preview => |candidate| {
                result.definition = try candidate.clone(allocator);
                result.value.action = switch (value.action) {
                    .apply => .{ .apply = result.definition.?.value },
                    .rebuild => .{ .rebuild = result.definition.?.value },
                    .measure => .{ .measure = result.definition.?.value },
                    .preview => .{ .preview = result.definition.?.value },
                    else => unreachable,
                };
            },
            .revert, .commit, .clear_preview => {},
        }
        return result;
    }
    pub fn deinit(self: *OwnedRequest) void {
        if (self.definition) |*definition| definition.deinit();
    }
};
pub const Requests = struct {
    allocator: std.mem.Allocator,
    pending: std.ArrayList(OwnedRequest) = .empty,
    pub fn submit(self: *Requests, request: Request) !void {
        var owned = try OwnedRequest.init(self.allocator, request);
        errdefer owned.deinit();
        try self.pending.append(self.allocator, owned);
    }
    pub fn clear(self: *Requests) void {
        for (self.pending.items) |*request| request.deinit();
        self.pending.clearRetainingCapacity();
    }
    pub fn deinit(self: *Requests) void {
        self.clear();
        self.pending.deinit(self.allocator);
    }
};
pub const Input = struct {
    persistence_available: bool = false,
    catalog: []const engine.assets.Entry = &.{},
    allocator: std.mem.Allocator,
    inspection: ?Inspection,
    result: ?Result,
    requests: *Requests,
};

pub const Group = enum { chassis, suspension, tires_brakes, drivetrain, steering, assists, visuals };
pub const Field = struct { path: []const u8, group: Group, unit: []const u8, effect: vehicle.ReconfigurationEffect, description: []const u8 };
pub const fields = [_]Field{
    .{ .path = "chassis_half_extents", .group = .chassis, .unit = "m", .effect = .rebuild, .description = "Collision half dimensions about the chassis origin; rebuilding an occupied layout is rejected." },
    .{ .path = "mass", .group = .chassis, .unit = "kg", .effect = .rebuild, .description = "Rigid chassis mass. Rebuild retains velocity, wheel motion and compatible drivetrain state." },
    .{ .path = "center_of_mass_offset", .group = .chassis, .unit = "m", .effect = .rebuild, .description = "Center of mass relative to the chassis origin; lowering it reduces physical roll moment." },
    .{ .path = "wheel_attachment_positions", .group = .chassis, .unit = "m", .effect = .rebuild, .description = "Front left, front right, rear left, rear right; +Y up, -Z forward, +X right." },
    .{ .path = "wheel_radius", .group = .chassis, .unit = "m", .effect = .rebuild, .description = "Physical tire radius; visual wheel scale is authored separately." },
    .{ .path = "wheel_width", .group = .chassis, .unit = "m", .effect = .rebuild, .description = "Physical wheel width along the +X axle." },
    .{ .path = "suspension", .group = .suspension, .unit = "m, Hz, damping ratio", .effect = .rebuild, .description = "Front axle travel, spring frequency and damping. rear_axle owns the corresponding rear values." },
    .{ .path = "anti_roll_stiffness", .group = .suspension, .unit = "N/m", .effect = .rebuild, .description = "Front and rear anti-roll coupling. Zero disables coupling without disabling suspension." },
    .{ .path = "tire_friction", .group = .tires_brakes, .unit = "ratio, rad, coefficient", .effect = .rebuild, .description = "Front tire longitudinal slip and lateral slip angle peak/slide curves. The adapter converts lateral radians to Jolt degrees and couples grip through the authored sliding-slip coordinates." },
    .{ .path = "rear_axle.tire_friction", .group = .tires_brakes, .unit = "ratio, rad, coefficient", .effect = .rebuild, .description = "Rear tire response; independent from front axle and visual material roughness." },
    .{ .path = "brakes", .group = .tires_brakes, .unit = "N m", .effect = .rebuild, .description = "Front service torque, rear service torque and rear handbrake torque per wheel." },
    .{ .path = "powertrain.engine", .group = .drivetrain, .unit = "N m, RPM, kg m²", .effect = .live, .description = "Torque, idle/redline, engine inertia and damping use supported runtime engine coefficients. RPM bounds must retain current RPM." },
    .{ .path = "powertrain.torque_curve", .group = .drivetrain, .unit = "normalized RPM, torque fraction", .effect = .rebuild, .description = "Ordered curve from 0 through 1 normalized engine speed; count follows authored content." },
    .{ .path = "powertrain.gears", .group = .drivetrain, .unit = "ratio, s, RPM", .effect = .rebuild, .description = "Explicit forward/reverse ratios, automatic shift thresholds, timing and clutch strength." },
    .{ .path = "powertrain.drive_distribution", .group = .drivetrain, .unit = "fraction, ratio", .effect = .rebuild, .description = "Front torque fraction 0 is RWD, 1 FWD, intermediate AWD. Unpowered differentials are omitted. Axle and center limited-slip ratios are explicit; f32 max selects open center coupling." },
    .{ .path = "steering", .group = .steering, .unit = "1/s, m/s, lock fraction", .effect = .live, .description = "Authority-owned rise/return rates and speed curve. The conditioned steering accumulator survives save/replay and edits." },
    .{ .path = "max_steer_radians", .group = .steering, .unit = "rad", .effect = .rebuild, .description = "Mechanical steering lock. Input response scales the fraction of this lock." },
    .{ .path = "max_pitch_roll_radians", .group = .assists, .unit = "rad", .effect = .live, .description = "Explicit pitch/roll limiter assist. Pi allows an unassisted full rollover." },
    .{ .path = "wheel_collision_max_slope_radians", .group = .assists, .unit = "rad", .effect = .rebuild, .description = "Maximum surface slope accepted by wheel contact queries." },
    .{ .path = "visuals", .group = .visuals, .unit = "AssetId, m, scale", .effect = .presentation, .description = "Cooked chassis/wheel mesh and material IDs, local origins and scales. Missing dependencies reject; PBR values do not tune grip." },
};
