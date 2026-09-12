//! Low-speed handbrake experiments on the product control policy and real Jolt.
//! Observe eight seconds held, then three seconds released; never substitute
//! chassis-forward velocity for horizontal stopping speed during a sideways skid.
const std = @import("std");
const rig = @import("vehicle_dynamics.zig");
const vehicle = @import("vehicle_contract");
const dt: f32 = 1.0 / 60.0;
pub const Result = struct {
    requested_entry_mps: f32,
    entry_mps: f32,
    entry_reached: bool,
    steering: f32,
    throttle: f32,
    stopping_time_s: ?f32 = null,
    stopping_distance_m: ?f32 = null,
    held_distance_m: f32 = 0,
    held_final_speed_mps: f32 = 0,
    held_peak_speed_mps: f32 = 0,
    held_peak_sideslip_deg: f32 = 0,
    held_peak_yaw_rate_deg_s: f32 = 0,
    held_yaw_travel_deg: f32 = 0,
    recovery_peak_sideslip_deg: f32 = 0,
    released_final_speed_mps: f32 = 0,
};

pub fn measure(allocator: std.mem.Allocator, definition: vehicle.asset.Definition, speed: f32, steering: f32, throttle: f32) !Result {
    var scenario = try rig.Scenario.initWithTimestep(allocator, try definition.tuning.toTuning(), dt);
    defer scenario.deinit();
    var state = try scenario.state();
    const direction: f32 = if (speed < 0) -1 else 1;
    for (0..1800) |_| {
        if (vehicle.control.forwardSpeed(state.chassis) * direction >= @abs(speed)) break;
        state = try scenario.tick(.{ .throttle = direction });
    }
    var result = Result{ .requested_entry_mps = speed, .entry_mps = rig.horizontalSpeed(state), .entry_reached = vehicle.control.forwardSpeed(state.chassis) * direction >= @abs(speed), .steering = steering, .throttle = throttle };
    if (!result.entry_reached) return result;
    var stable_ticks: usize = 0;
    var stop_time: f32 = 0;
    var stop_distance: f32 = 0;
    for (0..480) |tick| {
        const previous = state;
        state = try scenario.tick(.{ .throttle = throttle, .steering = steering, .hand_brake = 1 });
        const dx = state.chassis.pose.position[0] - previous.chassis.pose.position[0];
        const dz = state.chassis.pose.position[2] - previous.chassis.pose.position[2];
        result.held_distance_m += @sqrt(dx * dx + dz * dz);
        result.held_final_speed_mps = rig.horizontalSpeed(state);
        result.held_peak_speed_mps = @max(result.held_peak_speed_mps, result.held_final_speed_mps);
        result.held_peak_sideslip_deg = @max(result.held_peak_sideslip_deg, sideslip(state));
        result.held_peak_yaw_rate_deg_s = @max(result.held_peak_yaw_rate_deg_s, std.math.radiansToDegrees(@abs(state.chassis.velocity.angular[1])));
        result.held_yaw_travel_deg += std.math.radiansToDegrees(@abs(rig.wrappedAngleDelta(rig.yaw(state), rig.yaw(previous))));
        if (result.held_final_speed_mps < 0.25) {
            if (stable_ticks == 0) {
                stop_time = @as(f32, @floatFromInt(tick + 1)) * dt;
                stop_distance = result.held_distance_m;
            }
            stable_ticks += 1;
            if (stable_ticks == 15 and result.stopping_time_s == null) {
                result.stopping_time_s = stop_time;
                result.stopping_distance_m = stop_distance;
            }
        } else stable_ticks = 0;
    }
    for (0..180) |_| {
        state = try scenario.tick(.{ .throttle = direction * 0.2 });
        result.recovery_peak_sideslip_deg = @max(result.recovery_peak_sideslip_deg, sideslip(state));
    }
    result.released_final_speed_mps = rig.horizontalSpeed(state);
    return result;
}

fn sideslip(state: @import("engine_contracts").physics.VehicleState) f32 {
    // Angle is ill-conditioned at standstill. Report rotation separately.
    if (rig.horizontalSpeed(state) < 0.5) return 0;
    const c = @import("vehicle_motion_audit.zig").components(state);
    return std.math.radiansToDegrees(std.math.atan2(@abs(c[1]), @abs(c[0])));
}

pub fn run(init: std.process.Init, definition: vehicle.asset.Definition) !void {
    var results: std.ArrayList(Result) = .empty;
    for ([_]f32{ 0, 2, 4, 8, -2, -4, -8 }) |speed| {
        for ([_]f32{ -0.5, 0, 0.5 }) |steering| {
            for ([_]f32{ 0, if (speed < 0) -1 else 1 }) |throttle| {
                try results.append(init.arena.allocator(), try measure(init.arena.allocator(), definition, speed, steering, throttle));
            }
        }
    }
    try rig.writeJson(init, .{ .schema = 1, .build = rig.build_identity, .definition = definition, .definition_digest = try definition.digest(init.arena.allocator()), .timestep_s = dt, .surface_friction = @as(f32, 0.2), .held_seconds = 8, .release_seconds = 3, .stop_speed_mps = @as(f32, 0.25), .stop_dwell_seconds = @as(f32, 0.25), .results = results.items });
    for (results.items) |r| if (!r.entry_reached) return error.HandbrakeEntryNotReached;
}

pub fn verifyFleet(allocator: std.mem.Allocator) !void {
    const catalog = @import("game_vehicles");
    // Captured pre-fix 8 m/s straight handbrake distances. Require at least
    // 25% less travel, and guard the reported low-speed spin/propulsion bugs.
    const cases = .{
        .{ catalog.courier_bytes, @as(f32, 17.344027) },
        .{ catalog.meridian_bytes, @as(f32, 7.940992) },
        .{ catalog.courier_awd_bytes, @as(f32, 13.640716) },
    };
    inline for (cases) |case| {
        var definition = try vehicle.asset.decode(allocator, case[0]);
        defer definition.deinit();
        for ([_]f32{ 0, 2, 4, 8, -2, -4, -8 }) |speed| {
            for ([_]f32{ -0.5, 0, 0.5 }) |steering| {
                for ([_]f32{ 0, if (speed < 0) -1 else 1 }) |throttle| {
                    const r = try measure(allocator, definition.value, speed, steering, throttle);
                    try std.testing.expect(r.entry_reached);
                    try std.testing.expect(r.stopping_time_s != null);
                    try std.testing.expect(r.held_final_speed_mps < 0.25);
                    // A low-speed e-brake stop must not become the observed
                    // near-sideways SUV slide or a half-turn spin.
                    try std.testing.expect(r.held_peak_sideslip_deg < 20);
                    try std.testing.expect(r.held_yaw_travel_deg < 90);
                    try std.testing.expect(r.recovery_peak_sideslip_deg < 20);
                    try std.testing.expect(r.released_final_speed_mps > 0.5);
                    if (speed == 0) try std.testing.expect(r.held_distance_m < 0.1);
                    if (speed == 8 and steering == 0) try std.testing.expect(r.stopping_distance_m.? < case[1] * 0.75);
                }
            }
        }
    }
}
