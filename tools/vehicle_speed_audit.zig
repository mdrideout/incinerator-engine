//! Long-run speed and braking on the same real-Jolt support as production.
const std = @import("std");
const rig = @import("vehicle_dynamics.zig");
const vehicle = @import("vehicle_contract");
const motion = @import("vehicle_motion_audit.zig");
const dt: f32 = 1.0 / 60.0;
const Checkpoint = struct { seconds: u32, speed_mps: f32, gear: i32, rpm: f32, distance_m: f32 };
pub fn run(init: std.process.Init, definition: vehicle.asset.Definition) !void {
    var scenario = try rig.Scenario.initSurface(init.gpa, try definition.tuning.toTuning(), dt, 0, 0.2, 20000);
    defer scenario.deinit();
    var points: std.ArrayList(Checkpoint) = .empty;
    defer points.deinit(init.gpa);
    var state = try scenario.state();
    var speed_at_170: f32 = 0;
    for (0..180 * 60) |tick| {
        state = try scenario.tick(.{ .throttle = 1 });
        if (tick == 170 * 60 - 1) speed_at_170 = motion.components(state)[0];
        if ((tick + 1) % (30 * 60) == 0) try points.append(init.gpa, .{ .seconds = @intCast((tick + 1) / 60), .speed_mps = motion.components(state)[0], .gear = state.current_gear, .rpm = state.engine_rpm, .distance_m = -state.chassis.pose.position[2] });
    }
    const final_speed = motion.components(state)[0];
    const brake_start = state.chassis.pose.position[2];
    var braking_ticks: usize = 0;
    while (braking_ticks < 20 * 60 and rig.horizontalSpeed(state) >= 0.25) : (braking_ticks += 1) state = try scenario.tick(.{ .brake = 1 });
    try rig.writeJson(init, .{ .schema = 1, .build = rig.build_identity, .definition = definition, .definition_digest = try definition.digest(init.gpa), .surface_friction = @as(f32, 0.2), .timestep_s = dt, .acceleration_seconds = 180, .checkpoints = points.items, .final_speed_mps = final_speed, .last_ten_seconds_acceleration_mps2 = (final_speed - speed_at_170) / 10, .brake_entry_mps = final_speed, .brake_distance_m = @abs(state.chassis.pose.position[2] - brake_start), .brake_seconds = @as(f32, @floatFromInt(braking_ticks)) * dt, .stopped = rig.horizontalSpeed(state) < 0.25 });
}

/// Product requirement: approximately double the measured previous terminal
/// speeds, with real acceleration, stable support and a complete high-speed stop.
pub fn verifyFleet(allocator: std.mem.Allocator) !void {
    const catalog = @import("game_vehicles");
    const cases = .{
        .{ catalog.courier_bytes, @as(f32, 25.866991) },
        .{ catalog.meridian_bytes, @as(f32, 28.124918) },
        .{ catalog.courier_awd_bytes, @as(f32, 27.286333) },
    };
    inline for (cases) |case| {
        var definition = try vehicle.asset.decode(allocator, case[0]);
        defer definition.deinit();
        var scenario = try rig.Scenario.initSurface(allocator, try definition.value.tuning.toTuning(), dt, 0, 0.2, 20000);
        defer scenario.deinit();
        var state = try scenario.state();
        for (0..180 * 60) |_| state = try scenario.tick(.{ .throttle = 1 });
        try std.testing.expect(motion.components(state)[0] >= case[1] * 1.95);
        for (state.wheels) |wheel| try std.testing.expect(wheel.has_contact);
        for (0..20 * 60) |_| state = try scenario.tick(.{ .brake = 1 });
        try std.testing.expect(rig.horizontalSpeed(state) < 0.25);
    }
}
