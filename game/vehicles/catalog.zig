//! Game-owned initial fleet. Runtime authoring writes explicitly configured project assets;
//! embedded definitions are explicit validation/bootstrap content, never a missing-file fallback.
const std = @import("std");
const vehicle = @import("vehicle_contract");
pub const asset = vehicle.asset;
pub const meridian_id = asset.VehicleArchetypeId{ .asset = .{ .namespace = 5282233395077009985, .local = 9691434977271591166 } };
pub const meridian_bytes = @embedFile("494e43494e455241-867ee4c3b011b0fe.icvehicle");
pub const courier_id = asset.VehicleArchetypeId{ .asset = .{ .namespace = 5282233395077009985, .local = 2346745979227719430 } };
pub const courier_bytes = @embedFile("494e43494e455241-20915108d5f1c706.icvehicle");
pub const courier_awd_id = asset.VehicleArchetypeId{ .asset = .{ .namespace = 5282233395077009985, .local = 4096010698570253437 } };
pub const courier_awd_bytes = @embedFile("494e43494e455241-38d7f4075c7ac47d.icvehicle");
pub fn embeddedSedan(allocator: std.mem.Allocator) !asset.Owned {
    return asset.decode(allocator, meridian_bytes);
}
pub fn readSedan(allocator: std.mem.Allocator, io: std.Io, content_directory: std.Io.Dir) !asset.Owned {
    var directory = try content_directory.openDir(io, "vehicle", .{});
    defer directory.close(io);
    return asset.read(allocator, io, directory, meridian_id);
}
test "game archetypes have distinct admitted dimensions and drivetrain" {
    var sedan = try asset.decode(std.testing.allocator, meridian_bytes);
    defer sedan.deinit();
    var compact = try asset.decode(std.testing.allocator, courier_bytes);
    defer compact.deinit();
    try std.testing.expect(sedan.value.tuning.mass != compact.value.tuning.mass);
    try std.testing.expect(sedan.value.tuning.wheel_attachment_positions[0][2] != compact.value.tuning.wheel_attachment_positions[0][2]);
    try std.testing.expectEqual(@as(f32, 0), sedan.value.tuning.powertrain.front_torque_fraction);
    try std.testing.expectEqual(@as(f32, 1), compact.value.tuning.powertrain.front_torque_fraction);
}

pub const lighting_mount_ids = [_]@TypeOf(meridian_id.asset){ meridian_id.asset, courier_id.asset, courier_awd_id.asset };
pub const bundle_keys = [_][]const u8{ "vehicle/meridian", "vehicle/courier", "vehicle/courier-awd" };
pub const initial_fleet = [_]struct { id: asset.VehicleArchetypeId, position: [3]f32 }{
    .{ .id = meridian_id, .position = .{ 4, 1, -8 } },
    .{ .id = courier_id, .position = .{ 0, 1, -8 } },
    .{ .id = courier_awd_id, .position = .{ -4, 1, -8 } },
};
pub fn readCompact(allocator: std.mem.Allocator, io: std.Io, content_directory: std.Io.Dir) !asset.Owned {
    var directory = try content_directory.openDir(io, "vehicle", .{});
    defer directory.close(io);
    return asset.read(allocator, io, directory, courier_id);
}

pub fn read(allocator: std.mem.Allocator, io: std.Io, content_directory: std.Io.Dir, id: asset.VehicleArchetypeId) !asset.Owned {
    var directory = try content_directory.openDir(io, "vehicle", .{});
    defer directory.close(io);
    return asset.read(allocator, io, directory, id);
}

test "three game handling baselines have independent durable identity" {
    var awd = try asset.decode(std.testing.allocator, courier_awd_bytes);
    defer awd.deinit();
    try std.testing.expectEqual(courier_awd_id, awd.value.id);
    try std.testing.expect(!std.meta.eql(courier_id, awd.value.id));
    try std.testing.expect(awd.value.tuning.powertrain.front_torque_fraction > 0 and awd.value.tuning.powertrain.front_torque_fraction < 1);
    try std.testing.expectEqual(std.math.floatMax(f32), awd.value.tuning.powertrain.center_limited_slip_ratio);
}

test "coupe sedan and SUV have distinct body dependencies and admitted dimensions" {
    var coupe = try asset.decode(std.testing.allocator, meridian_bytes);
    defer coupe.deinit();
    var sedan = try asset.decode(std.testing.allocator, courier_bytes);
    defer sedan.deinit();
    var suv = try asset.decode(std.testing.allocator, courier_awd_bytes);
    defer suv.deinit();
    try std.testing.expectEqualStrings("Meridian coupe", coupe.value.label);
    try std.testing.expectEqualStrings("Courier sedan", sedan.value.label);
    try std.testing.expectEqualStrings("Courier AWD SUV", suv.value.label);
    try std.testing.expect(!std.meta.eql(sedan.value.visuals.chassis.mesh, suv.value.visuals.chassis.mesh));
    try std.testing.expect(suv.value.tuning.chassis_half_extents[1] > sedan.value.tuning.chassis_half_extents[1]);
    try std.testing.expect(suv.value.tuning.wheel_radius > sedan.value.tuning.wheel_radius);
    for (suv.value.visuals.wheels) |wheel| {
        try std.testing.expectApproxEqAbs(suv.value.tuning.wheel_radius * 2, wheel.scale[1], 0.0001);
        try std.testing.expectApproxEqAbs(suv.value.tuning.wheel_width, wheel.scale[0], 0.0001);
    }
}
