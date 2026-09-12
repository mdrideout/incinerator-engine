//! Matched-entry steering experiments. Surface and throttle are explicit independent axes.
const std = @import("std");
const rig = @import("vehicle_dynamics.zig");
const vehicle = @import("vehicle_contract");
const motion = @import("vehicle_motion_audit.zig");
const summary = @import("vehicle_motion_summary.zig");
const dt: f32 = 1.0 / 60.0;
const Result = struct {
    surface_friction: f32,
    requested_entry_mps: f32,
    actual_entry_mps: f32,
    entry_reached: bool,
    throttle: f32,
    steering: f32,
    heading_deg: f32,
    runup_distance_m: f32,
    turn_in_yaw_deg_at_half_second: ?f32 = null,
    maximum_tilt_degrees: f32 = 0,
    first_second: summary.Phase,
    second_second: summary.Phase,
};
fn measure(allocator: std.mem.Allocator, definition: vehicle.asset.Definition, speed: f32, throttle: f32, steer: f32, friction: f32, heading: f32) !Result {
    var scenario = try rig.Scenario.initSurface(allocator, try definition.tuning.toTuning(), dt, std.math.degreesToRadians(heading), friction, 6000);
    defer scenario.deinit();
    const start = (try scenario.state()).chassis.pose.position;
    var state = try scenario.state();
    // A 45-second acceleration experiment reports unavailable entry honestly.
    // No teleport, injected velocity, gear or wheel-speed reset is used.
    for (0..2700) |_| {
        if (motion.components(state)[0] >= speed) break;
        state = try scenario.tick(.{ .throttle = 1 });
    }
    const input = @import("engine_contracts").physics.VehicleInput{ .throttle = throttle, .steering = steer };
    const p = state.chassis.pose.position;
    var result = Result{ .surface_friction = friction, .requested_entry_mps = speed, .actual_entry_mps = motion.components(state)[0], .entry_reached = motion.components(state)[0] >= speed, .throttle = throttle, .steering = steer, .heading_deg = heading, .runup_distance_m = @sqrt((p[0] - start[0]) * (p[0] - start[0]) + (p[2] - start[2]) * (p[2] - start[2])), .first_second = .{ .input = input }, .second_second = .{ .input = input } };
    if (!result.entry_reached) return result;
    const entry_yaw = rig.yaw(state);
    const wheelbase = @abs(definition.tuning.wheel_attachment_positions[0][2] - definition.tuning.wheel_attachment_positions[2][2]);
    for (0..120) |tick| {
        state = try scenario.tick(input);
        const up = rig.rotate(state.chassis.pose.rotation, .{ 0, 1, 0 });
        result.maximum_tilt_degrees = @max(result.maximum_tilt_degrees, std.math.radiansToDegrees(std.math.acos(std.math.clamp(up[1], -1, 1))));
        const c = motion.components(state);
        const phase = if (tick < 60) &result.first_second else &result.second_second;
        phase.add(state, c[0], c[1], std.math.radiansToDegrees(std.math.atan2(c[1], @abs(c[0]))), scenario.conditioned_steering, dt, wheelbase);
        if (tick == 29) result.turn_in_yaw_deg_at_half_second = std.math.radiansToDegrees(rig.wrappedAngleDelta(rig.yaw(state), entry_yaw));
    }
    result.first_second.finish();
    result.second_second.finish();
    return result;
}
pub fn run(init: std.process.Init, definition: vehicle.asset.Definition) !void {
    var rows: std.ArrayList(Result) = .empty;
    const allocator = init.arena.allocator();
    for ([_]f32{ 0.2, 0.6, 1.0 }) |friction| for ([_]f32{ 8, 18, 24, 30, 48, 56 }) |speed| for ([_]f32{ 0, 1 }) |throttle| for ([_]f32{ 0.1, 0.5, 1 }) |steer| for ([_]f32{ 0, 90 }) |heading| {
        try rows.append(allocator, try measure(allocator, definition, speed, throttle, steer, friction, heading));
    };
    try rig.writeJson(init, .{ .schema = 1, .source_cohort = @import("network_cohort_options").build_cohort, .definition = definition, .definition_digest = try definition.digest(allocator), .timestep_s = dt, .acceleration_seconds = 45, .turn_seconds = 2, .results = rows.items });
}

pub fn verifySurfaceExperiment(allocator: std.mem.Allocator) !void {
    var definition = try vehicle.asset.decode(allocator, @import("game_vehicles").courier_awd_bytes);
    defer definition.deinit();
    const low = try measure(allocator, definition.value, 18, 1, 0.1, 0.2, 0);
    const high = try measure(allocator, definition.value, 18, 1, 0.1, 1, 0);
    try std.testing.expect(low.entry_reached and high.entry_reached);
    try std.testing.expectEqual(@as(usize, 60), high.first_second.samples);
    try std.testing.expectEqual(@as(usize, 60), high.second_second.samples);
    try std.testing.expect(high.first_second.front.mean_abs_lateral_force_n > low.first_second.front.mean_abs_lateral_force_n);
    try std.testing.expect(high.first_second.front.mean_lateral_slip_deg < low.first_second.front.mean_lateral_slip_deg);
}
