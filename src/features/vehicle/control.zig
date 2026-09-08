//! Gameplay pedal policy. Physics receives explicit throttle and service brake.
const std = @import("std");
const engine = @import("engine_contracts");

pub fn forwardSpeed(state: engine.physics.BodyState) f32 {
    const q = state.pose.rotation;
    const forward = [3]f32{ -2 * (q[0] * q[2] + q[3] * q[1]), -2 * (q[1] * q[2] - q[3] * q[0]), -(1 - 2 * (q[0] * q[0] + q[1] * q[1])) };
    const v = state.velocity.linear;
    return forward[0] * v[0] + forward[1] * v[1] + forward[2] * v[2];
}

/// Opposite pedal means service braking until horizontal motion has stopped.
/// Gear direction keeps a sideways skid from engaging the opposite gear. The 0.1 m/s standstill tolerance avoids gear chatter from solver
/// residual velocity; it is not a maximum driving speed or a stopping assist.
pub fn resolve(input: engine.physics.VehicleInput, forward_mps: f32, horizontal_mps: f32, gear: i32) engine.physics.VehicleInput {
    var result = input;
    if ((input.throttle * forward_mps < 0 and @abs(forward_mps) > 0.1) or
        (input.throttle * @as(f32, @floatFromInt(gear)) < 0 and horizontal_mps > 0.1))
    {
        result.throttle = 0;
        result.brake = @max(input.brake, @abs(input.throttle));
    }
    return result;
}

test "opposite pedal brakes in both directions and only engages drive at standstill" {
    for ([_]f32{ -1, 1 }) |direction| {
        const raw = engine.physics.VehicleInput{ .throttle = -direction, .steering = 0.5, .hand_brake = 1 };
        const braking = resolve(raw, direction * 8, 8, @intFromFloat(direction));
        try std.testing.expectEqual(@as(f32, 0), braking.throttle);
        try std.testing.expectEqual(@as(f32, 1), braking.brake);
        try std.testing.expectEqual(raw.steering, braking.steering);
        try std.testing.expectEqual(raw.hand_brake, braking.hand_brake);
        try std.testing.expectEqualDeep(raw, resolve(raw, direction * 0.05, 0.05, @intFromFloat(direction)));
        try std.testing.expectEqualDeep(raw, resolve(raw, -direction * 8, 8, @intFromFloat(-direction)));
        try std.testing.expectEqualDeep(engine.physics.VehicleInput{ .brake = 1 }, resolve(.{ .brake = 1 }, direction * 8, 8, @intFromFloat(direction)));
    }
}

// A car skidding sideways has near-zero forward speed without being stopped.
test "direction change waits for sideways motion to stop before shifting" {
    for ([_]i32{ -1, 1 }) |gear| {
        const demand = engine.physics.VehicleInput{ .throttle = -@as(f32, @floatFromInt(gear)), .steering = 0.5 };
        const braking = resolve(demand, 0, 6, gear);
        try std.testing.expect(braking.throttle == 0 and braking.brake == 1);
        try std.testing.expectEqualDeep(demand, resolve(demand, 0, 0.05, gear));
    }
}
