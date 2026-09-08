//! Immutable renderer/predictor projection admitted through reliable session state.
//! The authority retains the complete simulation definition and its digest.
const std = @import("std");
const engine = @import("engine_contracts");
const contract = @import("contract.zig");

pub const Response = struct {
    acceleration_mps2: f32,
    brake_deceleration_mps2: f32,
    hand_brake_deceleration_mps2: f32,
    maximum_forward_speed_mps: f32,
    maximum_reverse_speed_mps: f32,
    yaw_rate_at_eight_mps: f32,
};

pub const Definition = struct {
    archetype: contract.VehicleArchetypeId,
    asset_revision: u64,
    digest: engine.assets.Digest,
    chassis_half_extents: [3]f32,
    attachment_positions: [4][3]f32,
    wheel_radius: f32,
    wheel_width: f32,
    suspension_max_lengths: [4]f32,
    max_steer_radians: f32,
    visuals: contract.asset.Visuals,
    response: Response,

    pub fn fromDefinition(definition: contract.asset.Definition, digest: engine.assets.Digest) Definition {
        const t = definition.tuning;
        const p = t.powertrain;
        const ratio = t.front_differential_ratio * p.front_torque_fraction + p.rear_differential_ratio * (1 - p.front_torque_fraction);
        const wheelbase = @abs(t.wheel_attachment_positions[2][2] - t.wheel_attachment_positions[0][2]);
        return .{
            .archetype = definition.id,
            .asset_revision = definition.revision,
            .digest = digest,
            .chassis_half_extents = t.chassis_half_extents,
            .attachment_positions = t.wheel_attachment_positions,
            .wheel_radius = t.wheel_radius,
            .wheel_width = t.wheel_width,
            .suspension_max_lengths = .{ t.suspension_max_length, t.suspension_max_length, t.rear_axle.suspension_max_length, t.rear_axle.suspension_max_length },
            .max_steer_radians = t.max_steer_radians,
            .visuals = definition.visuals,
            .response = .{
                .acceleration_mps2 = p.max_torque_nm * p.forward_gears[0] * ratio / (t.wheel_radius * t.mass),
                .brake_deceleration_mps2 = 2 * (t.max_brake_torque + t.rear_axle.brake_torque_nm) / (t.wheel_radius * t.mass),
                .hand_brake_deceleration_mps2 = 2 * t.max_hand_brake_torque / (t.wheel_radius * t.mass),
                .maximum_forward_speed_mps = p.max_rpm * (2.0 * std.math.pi / 60.0) * t.wheel_radius / (ratio * p.forward_gears[p.forward_gears.len - 1]),
                .maximum_reverse_speed_mps = p.max_rpm * (2.0 * std.math.pi / 60.0) * t.wheel_radius / (ratio * @abs(p.reverse_gears[0])),
                .yaw_rate_at_eight_mps = 8 * @tan(t.max_steer_radians) / wheelbase,
            },
        };
    }

    pub fn validate(self: Definition) !void {
        try self.archetype.validate();
        if (self.asset_revision == 0 or std.mem.allEqual(u8, &self.digest, 0)) return error.InvalidVehicleDefinitionIdentity;
        for (self.chassis_half_extents) |v| if (!std.math.isFinite(v) or v <= 0) return error.InvalidVehicleDimensions;
        for (self.attachment_positions) |p| try engine.transform.validateFiniteVector(p);
        for (self.suspension_max_lengths) |v| if (!std.math.isFinite(v) or v < 0) return error.InvalidVehicleSuspensionRange;
        for ([_]f32{ self.wheel_radius, self.wheel_width, self.max_steer_radians }) |v| if (!std.math.isFinite(v) or v <= 0) return error.InvalidVehicleDimensions;
        inline for (std.meta.fields(Response)) |field| {
            const v = @field(self.response, field.name);
            if (!std.math.isFinite(v) or v < 0) return error.InvalidVehicleResponse;
        }
        try self.visuals.chassis.validate();
        for (self.visuals.wheels) |part| try part.validate();
    }
};

/// Explicit synthetic projection for protocol and renderer-free tests.
pub fn validationFixture() Definition {
    return Definition.fromDefinition(contract.asset.validationFixture(), @splat(1));
}
