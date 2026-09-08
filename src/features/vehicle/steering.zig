//! Shared pure steering conditioning; its accumulator belongs to each authority car.
const std = @import("std");
pub const SpeedPoint = struct { speed_mps: f32, lock_fraction: f32 };
pub const Settings = struct {
    rise_per_second: f32 = 120,
    return_per_second: f32 = 120,
    speed_curve: []const SpeedPoint = &.{.{ .speed_mps = 0, .lock_fraction = 1 }},

    pub fn validate(self: Settings) !void {
        for ([_]f32{ self.rise_per_second, self.return_per_second }) |v| if (!std.math.isFinite(v) or v <= 0) return error.InvalidVehicleSteeringRate;
        if (self.speed_curve.len == 0 or self.speed_curve[0].speed_mps != 0) return error.InvalidVehicleSteeringCurve;
        for (self.speed_curve, 0..) |p, i| {
            if (!std.math.isFinite(p.speed_mps) or !std.math.isFinite(p.lock_fraction) or p.lock_fraction <= 0 or p.lock_fraction > 1) return error.InvalidVehicleSteeringCurve;
            if (i > 0 and p.speed_mps <= self.speed_curve[i - 1].speed_mps) return error.InvalidVehicleSteeringCurve;
        }
    }

    pub fn scale(self: Settings, speed_mps: f32) f32 {
        const speed = @abs(speed_mps);
        for (self.speed_curve[1..], self.speed_curve[0 .. self.speed_curve.len - 1]) |b, a| {
            if (speed < b.speed_mps) return a.lock_fraction + (b.lock_fraction - a.lock_fraction) * (speed - a.speed_mps) / (b.speed_mps - a.speed_mps);
        }
        return self.speed_curve[self.speed_curve.len - 1].lock_fraction;
    }

    pub fn update(self: Settings, previous: f32, raw: f32, speed_mps: f32, dt: f32) f32 {
        const target = raw * self.scale(speed_mps);
        const returning = (previous != 0 and previous * target <= 0) or @abs(target) < @abs(previous);
        const step = (if (returning) self.return_per_second else self.rise_per_second) * dt;
        return previous + std.math.clamp(target - previous, -step, step);
    }

    pub fn eql(a: Settings, b: Settings) bool {
        if (a.rise_per_second != b.rise_per_second or a.return_per_second != b.return_per_second or a.speed_curve.len != b.speed_curve.len) return false;
        for (a.speed_curve, b.speed_curve) |x, y| if (!std.meta.eql(x, y)) return false;
        return true;
    }
};

test "steering lock interpolates speed and retains a rate limited return" {
    const settings = Settings{ .rise_per_second = 2, .return_per_second = 4, .speed_curve = &.{ .{ .speed_mps = 0, .lock_fraction = 1 }, .{ .speed_mps = 20, .lock_fraction = 0.4 } } };
    try settings.validate();
    try std.testing.expectApproxEqAbs(@as(f32, 0.7), settings.scale(10), 0.00001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.1), settings.update(0, 1, 10, 0.05), 0.00001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.3), settings.update(0.5, 0, 10, 0.05), 0.00001);
}
