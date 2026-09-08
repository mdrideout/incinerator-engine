//! Online segment statistics: every tick contributes, with no trace retention.
const std = @import("std");
const physics = @import("engine_contracts").physics;

pub const Axle = struct {
    contact_samples: usize = 0,
    moving_contact_samples: usize = 0,
    locked_moving_samples: usize = 0,
    mean_longitudinal_slip: f64 = 0,
    mean_lateral_slip_deg: f64 = 0,
    mean_estimated_load_n: f64 = 0,
    mean_abs_longitudinal_force_n: f64 = 0,
    mean_abs_lateral_force_n: f64 = 0,
    mean_signed_longitudinal_force_n: f64 = 0,
    mean_abs_wheel_angular_speed_rad_s: f64 = 0,

    fn add(self: *Axle, wheels: []const physics.WheelState, speed: f32, dt: f32) void {
        for (wheels) |wheel| {
            if (!wheel.has_contact) continue;
            self.contact_samples += 1;
            if (@abs(speed) > 1) {
                self.moving_contact_samples += 1;
                self.locked_moving_samples += @intFromBool(@abs(wheel.angular_velocity) < 0.001);
            }
            self.mean_longitudinal_slip += @abs(wheel.longitudinal_slip);
            self.mean_lateral_slip_deg += @as(f64, @abs(wheel.lateral_slip_radians)) * 180 / std.math.pi;
            self.mean_estimated_load_n += @as(f64, @abs(wheel.suspension_impulse_ns)) / dt;
            self.mean_abs_longitudinal_force_n += @as(f64, @abs(wheel.longitudinal_impulse_ns)) / dt;
            self.mean_abs_lateral_force_n += @as(f64, @abs(wheel.lateral_impulse_ns)) / dt;
            self.mean_signed_longitudinal_force_n += @as(f64, wheel.longitudinal_impulse_ns) / dt;
            self.mean_abs_wheel_angular_speed_rad_s += @abs(wheel.angular_velocity);
        }
    }
    fn finish(self: *Axle) void {
        if (self.contact_samples == 0) return;
        inline for (std.meta.fields(Axle)) |field| {
            if (field.type == f64) @field(self, field.name) /= @floatFromInt(self.contact_samples);
        }
    }
};

pub const Phase = struct {
    input: physics.VehicleInput,
    samples: usize = 0,
    moving_samples: usize = 0,
    entry_mps: f32 = 0,
    exit_mps: f32 = 0,
    peak_sideslip_deg: f32 = 0,
    final_sideslip_deg: ?f32 = null,
    mean_abs_conditioned_steering: f64 = 0,
    mean_abs_front_steer_radians: f64 = 0,
    mean_abs_yaw_rate_rad_s: f64 = 0,
    mean_abs_path_curvature_per_m: f64 = 0,
    mean_abs_kinematic_curvature_per_m: f64 = 0,
    mean_abs_yaw_lateral_acceleration_mps2: f64 = 0,
    front: Axle = .{},
    rear: Axle = .{},

    pub fn add(self: *Phase, state: physics.VehicleState, forward: f32, lateral: f32, slip: ?f32, steer: f32, dt: f32, wheelbase: f32) void {
        if (self.samples == 0) self.entry_mps = forward;
        self.samples += 1;
        self.exit_mps = forward;
        self.peak_sideslip_deg = @max(self.peak_sideslip_deg, @abs(slip orelse 0));
        self.final_sideslip_deg = slip;
        if (@abs(forward) > 1) {
            self.moving_samples += 1;
            const yaw_rate: f64 = @abs(state.chassis.velocity.angular[1]);
            self.mean_abs_conditioned_steering += @abs(steer);
            self.mean_abs_front_steer_radians += (@as(f64, @abs(state.wheels[0].steer_angle)) + @abs(state.wheels[1].steer_angle)) / 2;
            self.mean_abs_yaw_rate_rad_s += yaw_rate;
            self.mean_abs_path_curvature_per_m += yaw_rate / @sqrt(@as(f64, forward) * forward + @as(f64, lateral) * lateral);
            self.mean_abs_kinematic_curvature_per_m += @abs(@tan((@as(f64, state.wheels[0].steer_angle) + state.wheels[1].steer_angle) / 2)) / wheelbase;
            self.mean_abs_yaw_lateral_acceleration_mps2 += @abs(forward) * yaw_rate;
        }
        self.front.add(state.wheels[0..2], forward, dt);
        self.rear.add(state.wheels[2..4], forward, dt);
    }
    pub fn finish(self: *Phase) void {
        if (self.moving_samples != 0) inline for (std.meta.fields(Phase)) |field| {
            if (field.type == f64) @field(self, field.name) /= @floatFromInt(self.moving_samples);
        };
        self.front.finish();
        self.rear.finish();
    }
};
