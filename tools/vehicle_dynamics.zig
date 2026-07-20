//! Deterministic, renderer-free vehicle handling characterization on real Jolt.

const std = @import("std");
const engine = @import("engine_contracts");
const jolt = @import("jolt_physics");
const vehicle_contract = @import("vehicle_contract");

const dt: f32 = 1.0 / 120.0;
const settle_ticks = 240;

const Metrics = struct {
    stopping_entry_speed_mps: f32,
    stopping_distance_m: f32,
    stopping_time_s: f32,
    steady_turn_radius_m: f32,
    steady_turn_mean_slip_deg: f32,
    slalom_lateral_excursion_m: f32,
    slalom_peak_yaw_rate_deg_s: f32,
    slalom_peak_slip_deg: f32,
    skid_peak_slip_deg: f32,
    skid_recovery_s: f32,
    rollover_max_tilt_deg: f32,
    rollover_occurred: bool,
};

const Scenario = struct {
    allocator: std.mem.Allocator,
    physics: *jolt.Physics,
    ground: jolt.BodyId,
    vehicle: jolt.VehicleId,

    fn init(allocator: std.mem.Allocator, tuning: vehicle_contract.VehicleTuning) !Scenario {
        const physics = try allocator.create(jolt.Physics);
        errdefer allocator.destroy(physics);
        physics.* = try jolt.Physics.init();
        errdefer physics.deinit();
        const ground = try physics.createStaticBox(.{ 0, -1, 0 }, .{ 500, 1, 500 });
        errdefer _ = physics.removeBody(ground);
        var vehicles = physics.vehicles();
        const vehicle = try vehicles.createVehicle(tuning.physicsDescriptor(
            .{ .pose = .{ .position = .{ 0, 2, 0 } } },
            zeroWheelDynamics(),
        ));
        errdefer vehicles.destroyVehicle(vehicle) catch {};
        var result = Scenario{
            .allocator = allocator,
            .physics = physics,
            .ground = ground,
            .vehicle = vehicle,
        };
        try result.step(.{}, settle_ticks);
        return result;
    }

    fn deinit(self: *Scenario) void {
        var vehicles = self.physics.vehicles();
        vehicles.destroyVehicle(self.vehicle) catch {};
        _ = self.physics.removeBody(self.ground);
        self.physics.deinit();
        self.allocator.destroy(self.physics);
        self.* = undefined;
    }

    fn step(self: *Scenario, input: engine.physics.VehicleInput, ticks: usize) !void {
        var vehicles = self.physics.vehicles();
        try vehicles.setVehicleInput(self.vehicle, input);
        for (0..ticks) |_| try self.physics.update(dt);
    }

    fn tick(self: *Scenario, input: engine.physics.VehicleInput) !engine.physics.VehicleState {
        try self.step(input, 1);
        var vehicles = self.physics.vehicles();
        return vehicles.vehicleState(self.vehicle);
    }

    fn state(self: *Scenario) !engine.physics.VehicleState {
        var vehicles = self.physics.vehicles();
        return vehicles.vehicleState(self.vehicle);
    }
};

fn zeroWheelDynamics() [engine.physics.vehicle_wheel_count]engine.physics.VehicleWheelDynamics {
    return .{ .{}, .{}, .{}, .{} };
}

fn legacyTuning() vehicle_contract.VehicleTuning {
    var tuning = vehicle_contract.VehicleTuning{};
    tuning.center_of_mass_offset = .{ 0, -0.25, 0 };
    tuning.suspension_frequency = 1.5;
    tuning.suspension_damping = 0.5;
    tuning.max_steer_radians = std.math.degreesToRadians(30.0);
    tuning.max_brake_torque = 1_500;
    tuning.tire_friction = .{
        .longitudinal_peak_slip = 0.06,
        .longitudinal_peak_friction = 1.2,
        .longitudinal_slide_slip = 0.2,
        .longitudinal_slide_friction = 1.0,
        .lateral_peak_angle_radians = std.math.degreesToRadians(3.0),
        .lateral_peak_friction = 1.2,
        .lateral_slide_angle_radians = std.math.degreesToRadians(20.0),
        .lateral_slide_friction = 1.0,
    };
    return tuning;
}

fn horizontalSpeed(state: engine.physics.VehicleState) f32 {
    return @sqrt(
        state.chassis.velocity.linear[0] * state.chassis.velocity.linear[0] +
            state.chassis.velocity.linear[2] * state.chassis.velocity.linear[2],
    );
}

fn horizontalDistance(a: [3]f32, b: [3]f32) f32 {
    const dx = b[0] - a[0];
    const dz = b[2] - a[2];
    return @sqrt(dx * dx + dz * dz);
}

fn rotate(rotation: [4]f32, value: [3]f32) [3]f32 {
    const q = [3]f32{ rotation[0], rotation[1], rotation[2] };
    const uv = cross(q, value);
    const uuv = cross(q, uv);
    return .{
        value[0] + 2 * (rotation[3] * uv[0] + uuv[0]),
        value[1] + 2 * (rotation[3] * uv[1] + uuv[1]),
        value[2] + 2 * (rotation[3] * uv[2] + uuv[2]),
    };
}

fn cross(a: [3]f32, b: [3]f32) [3]f32 {
    return .{
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    };
}

fn yaw(state: engine.physics.VehicleState) f32 {
    const forward = rotate(state.chassis.pose.rotation, .{ 0, 0, -1 });
    return std.math.atan2(forward[0], -forward[2]);
}

fn wrappedAngleDelta(current: f32, previous: f32) f32 {
    var result = current - previous;
    while (result > std.math.pi) result -= std.math.tau;
    while (result < -std.math.pi) result += std.math.tau;
    return result;
}

fn slipDegrees(state: engine.physics.VehicleState) f32 {
    const right = rotate(state.chassis.pose.rotation, .{ 1, 0, 0 });
    const forward = rotate(state.chassis.pose.rotation, .{ 0, 0, -1 });
    const velocity = state.chassis.velocity.linear;
    const lateral = velocity[0] * right[0] + velocity[2] * right[2];
    const longitudinal = velocity[0] * forward[0] + velocity[2] * forward[2];
    if (@abs(lateral) < 0.0001 and @abs(longitudinal) < 0.0001) return 0;
    return std.math.radiansToDegrees(@abs(std.math.atan2(lateral, @abs(longitudinal))));
}

fn measureStopping(allocator: std.mem.Allocator, tuning: vehicle_contract.VehicleTuning) !struct { f32, f32, f32 } {
    var scenario = try Scenario.init(allocator, tuning);
    defer scenario.deinit();
    var state = try scenario.state();
    for (0..2_400) |_| {
        state = try scenario.tick(.{ .throttle = 1 });
        if (horizontalSpeed(state) >= 15) break;
    }
    const entry_speed = horizontalSpeed(state);
    const start = state.chassis.pose.position;
    var elapsed_ticks: usize = 0;
    for (0..1_200) |_| {
        state = try scenario.tick(.{ .brake = 1 });
        elapsed_ticks += 1;
        if (horizontalSpeed(state) < 0.25) break;
    }
    return .{ entry_speed, horizontalDistance(start, state.chassis.pose.position), @as(f32, @floatFromInt(elapsed_ticks)) * dt };
}

fn measureTurn(allocator: std.mem.Allocator, tuning: vehicle_contract.VehicleTuning) !struct { f32, f32 } {
    var scenario = try Scenario.init(allocator, tuning);
    defer scenario.deinit();
    try scenario.step(.{ .throttle = 0.4, .steering = 0.5 }, 720);
    var previous = try scenario.state();
    var path: f32 = 0;
    var yaw_change: f32 = 0;
    var slip_sum: f32 = 0;
    const sample_ticks: usize = 720;
    for (0..sample_ticks) |_| {
        const state = try scenario.tick(.{ .throttle = 0.4, .steering = 0.5 });
        path += horizontalDistance(previous.chassis.pose.position, state.chassis.pose.position);
        yaw_change += @abs(wrappedAngleDelta(yaw(state), yaw(previous)));
        slip_sum += slipDegrees(state);
        previous = state;
    }
    return .{
        if (yaw_change > 0.001) path / yaw_change else std.math.inf(f32),
        slip_sum / @as(f32, @floatFromInt(sample_ticks)),
    };
}

fn measureSlalom(allocator: std.mem.Allocator, tuning: vehicle_contract.VehicleTuning) !struct { f32, f32, f32 } {
    var scenario = try Scenario.init(allocator, tuning);
    defer scenario.deinit();
    try scenario.step(.{ .throttle = 0.75 }, 360);
    var previous = try scenario.state();
    var min_x = previous.chassis.pose.position[0];
    var max_x = min_x;
    var peak_yaw_rate: f32 = 0;
    var peak_slip: f32 = 0;
    for (0..1_200) |tick_index| {
        const phase = (tick_index / 96) & 1;
        const steering: f32 = if (phase == 0) 0.7 else -0.7;
        const state = try scenario.tick(.{ .throttle = 0.65, .steering = steering });
        min_x = @min(min_x, state.chassis.pose.position[0]);
        max_x = @max(max_x, state.chassis.pose.position[0]);
        peak_yaw_rate = @max(
            peak_yaw_rate,
            std.math.radiansToDegrees(@abs(wrappedAngleDelta(yaw(state), yaw(previous))) / dt),
        );
        peak_slip = @max(peak_slip, slipDegrees(state));
        previous = state;
    }
    return .{ max_x - min_x, peak_yaw_rate, peak_slip };
}

fn measureSkidRecovery(allocator: std.mem.Allocator, tuning: vehicle_contract.VehicleTuning) !struct { f32, f32 } {
    var scenario = try Scenario.init(allocator, tuning);
    defer scenario.deinit();
    try scenario.step(.{ .throttle = 1 }, 600);
    var peak_slip: f32 = 0;
    for (0..150) |_| {
        const state = try scenario.tick(.{ .throttle = 0.25, .steering = 0.8, .hand_brake = 1 });
        peak_slip = @max(peak_slip, slipDegrees(state));
    }
    var stable_ticks: usize = 0;
    var recovery_ticks: usize = 0;
    for (0..1_200) |_| {
        const state = try scenario.tick(.{ .throttle = 0.25 });
        peak_slip = @max(peak_slip, slipDegrees(state));
        recovery_ticks += 1;
        stable_ticks = if (slipDegrees(state) < 3.0) stable_ticks + 1 else 0;
        if (stable_ticks >= 60) break;
    }
    const effective_ticks = recovery_ticks -| stable_ticks;
    return .{ peak_slip, @as(f32, @floatFromInt(effective_ticks)) * dt };
}

fn measureRollover(allocator: std.mem.Allocator, tuning: vehicle_contract.VehicleTuning) !struct { f32, bool } {
    var scenario = try Scenario.init(allocator, tuning);
    defer scenario.deinit();
    try scenario.step(.{ .throttle = 1 }, 720);
    var maximum_tilt: f32 = 0;
    var rolled = false;
    for (0..1_200) |_| {
        const state = try scenario.tick(.{ .throttle = 0.75, .steering = 1 });
        const up = rotate(state.chassis.pose.rotation, .{ 0, 1, 0 });
        const up_y = std.math.clamp(up[1], -1, 1);
        maximum_tilt = @max(maximum_tilt, std.math.radiansToDegrees(std.math.acos(up_y)));
        rolled = rolled or up_y <= 0;
    }
    return .{ maximum_tilt, rolled };
}

fn measure(allocator: std.mem.Allocator, tuning: vehicle_contract.VehicleTuning) !Metrics {
    try tuning.validate();
    const stopping = try measureStopping(allocator, tuning);
    const turn = try measureTurn(allocator, tuning);
    const slalom = try measureSlalom(allocator, tuning);
    const skid = try measureSkidRecovery(allocator, tuning);
    const rollover = try measureRollover(allocator, tuning);
    return .{
        .stopping_entry_speed_mps = stopping[0],
        .stopping_distance_m = stopping[1],
        .stopping_time_s = stopping[2],
        .steady_turn_radius_m = turn[0],
        .steady_turn_mean_slip_deg = turn[1],
        .slalom_lateral_excursion_m = slalom[0],
        .slalom_peak_yaw_rate_deg_s = slalom[1],
        .slalom_peak_slip_deg = slalom[2],
        .skid_peak_slip_deg = skid[0],
        .skid_recovery_s = skid[1],
        .rollover_max_tilt_deg = rollover[0],
        .rollover_occurred = rollover[1],
    };
}

fn printMetrics(label: []const u8, value: Metrics) void {
    std.debug.print(
        "{s} stop_entry={d:.3}mps stop_distance={d:.3}m stop_time={d:.3}s turn_radius={d:.3}m turn_slip={d:.3}deg slalom_excursion={d:.3}m slalom_yaw_rate={d:.3}deg_s slalom_slip={d:.3}deg skid_peak={d:.3}deg skid_recovery={d:.3}s rollover_tilt={d:.3}deg rollover={}\n",
        .{ label, value.stopping_entry_speed_mps, value.stopping_distance_m, value.stopping_time_s, value.steady_turn_radius_m, value.steady_turn_mean_slip_deg, value.slalom_lateral_excursion_m, value.slalom_peak_yaw_rate_deg_s, value.slalom_peak_slip_deg, value.skid_peak_slip_deg, value.skid_recovery_s, value.rollover_max_tilt_deg, value.rollover_occurred },
    );
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const legacy = try measure(allocator, legacyTuning());
    const current = try measure(allocator, .{});
    printMetrics("legacy", legacy);
    printMetrics("current", current);
    if (current.rollover_occurred) return error.VehicleDynamicsRollover;
    if (current.stopping_distance_m >= legacy.stopping_distance_m) {
        return error.VehicleDynamicsStoppingDidNotImprove;
    }
    if (current.slalom_peak_slip_deg >= legacy.slalom_peak_slip_deg) {
        return error.VehicleDynamicsSlalomSlipDidNotImprove;
    }
    if (current.skid_recovery_s > legacy.skid_recovery_s) {
        return error.VehicleDynamicsSkidRecoveryDidNotImprove;
    }
}

test "vehicle dynamics angle wrapping is canonical" {
    try std.testing.expectApproxEqAbs(
        @as(f32, std.math.degreesToRadians(2.0)),
        wrappedAngleDelta(std.math.degreesToRadians(-179.0), std.math.degreesToRadians(179.0)),
        0.0001,
    );
}
