//! Game-tooling preset projection. Canonical vehicle assets own all values.
const std = @import("std");
const vehicle = @import("vehicle_contract");

/// Borrowed candidate; consumers retaining it must clone the complete definition.
/// Preserve target identity and geometry so preset selection cannot resize a mesh.
pub fn candidate(target: vehicle.asset.Definition, source: vehicle.asset.Definition) !vehicle.asset.Definition {
    var result = target;
    inline for (.{ "mass", "center_of_mass_offset", "suspension_min_length", "suspension_max_length", "suspension_frequency", "suspension_damping", "rear_axle", "front_anti_roll_stiffness", "tire_friction", "max_brake_torque", "max_hand_brake_torque", "powertrain", "front_differential_ratio", "front_limited_slip_ratio", "steering", "max_steer_radians", "max_pitch_roll_radians" }) |field| {
        @field(result.tuning, field) = @field(source.tuning, field);
    }
    try result.validate();
    return result;
}

test "handling preset preserves target identity visuals and physical geometry" {
    const target = vehicle.asset.validationFixture();
    var source = target;
    source.tuning.mass = 1800;
    source.tuning.powertrain.front_torque_fraction = 0.4;
    source.tuning.chassis_half_extents = .{ 2, 2, 3 };
    const result = try candidate(target, source);
    try std.testing.expectEqualDeep(target.id, result.id);
    try std.testing.expectEqual(target.revision, result.revision);
    try std.testing.expectEqualDeep(target.visuals, result.visuals);
    try std.testing.expectEqualDeep(target.tuning.chassis_half_extents, result.tuning.chassis_half_extents);
    try std.testing.expectEqualDeep(target.tuning.wheel_attachment_positions, result.tuning.wheel_attachment_positions);
    try std.testing.expectEqual(source.tuning.mass, result.tuning.mass);
    try std.testing.expectEqual(source.tuning.powertrain.front_torque_fraction, result.tuning.powertrain.front_torque_fraction);
}
