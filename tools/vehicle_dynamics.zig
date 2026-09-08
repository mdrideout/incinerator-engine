//! Deterministic, renderer-free vehicle handling characterization on real Jolt.

const std = @import("std");
const engine = @import("engine_contracts");
const jolt = @import("jolt_physics");
const vehicle_contract = @import("vehicle_contract");
const cohort = @import("network_cohort_options");
const protocol = @import("session_protocol");
const vehicle_prediction = @import("vehicle_prediction");
const product_dt: f32 = 1.0 / @as(f32, @floatFromInt(@import("session_budgets").authority_tick_hz));
const physics_cohort = @import("simulation_cohort_options");

pub const dt: f32 = 1.0 / 120.0;
const settle_ticks = 240;

pub const Metrics = struct {
    stopping_status: StoppingStatus,
    skid_status: RecoveryStatus,
    stopping_entry_speed_mps: f32,
    stopping_distance_m: ?f32,
    stopping_time_s: ?f32,
    steady_turn_radius_m: ?f32,
    steady_turn_mean_slip_deg: f32,
    slalom_lateral_excursion_m: f32,
    slalom_peak_yaw_rate_deg_s: f32,
    slalom_peak_slip_deg: f32,
    skid_peak_slip_deg: f32,
    skid_recovery_s: ?f32,
    rollover_max_tilt_deg: f32,
    rollover_occurred: bool,
};

pub const StoppingStatus = enum { complete, entry_speed_not_reached, stop_not_reached };
pub const RecoveryStatus = enum { complete, breakaway_not_reached, recovery_not_reached };
const Recovery = struct { peak_slip_deg: f32, time_s: ?f32, status: RecoveryStatus };

pub const Stopping = struct {
    status: StoppingStatus,
    entry_speed_mps: f32,
    distance_m: ?f32,
    time_s: ?f32,
};

pub const Scenario = struct {
    allocator: std.mem.Allocator,
    physics: *jolt.Physics,
    ground: jolt.BodyId,
    vehicle: jolt.VehicleId,
    steering: vehicle_contract.steering.Settings,
    conditioned_steering: f32 = 0,
    applied_input: engine.physics.VehicleInput = .{},
    timestep_s: f32 = dt,

    fn init(allocator: std.mem.Allocator, tuning: vehicle_contract.VehicleTuning) !Scenario {
        return initWithTimestep(allocator, tuning, dt);
    }
    pub fn initWithTimestep(allocator: std.mem.Allocator, tuning: vehicle_contract.VehicleTuning, timestep_s: f32) !Scenario {
        return initWithHeading(allocator, tuning, timestep_s, 0);
    }
    pub fn initWithHeading(allocator: std.mem.Allocator, tuning: vehicle_contract.VehicleTuning, timestep_s: f32, heading: f32) !Scenario {
        const physics = try allocator.create(jolt.Physics);
        errdefer allocator.destroy(physics);
        physics.* = try jolt.Physics.init();
        errdefer physics.deinit();
        const ground = try physics.createStaticBox(.{ 0, -1, 0 }, .{ 500, 1, 500 });
        errdefer _ = physics.removeBody(ground);
        var vehicles = physics.vehicles();
        const vehicle = try vehicles.createVehicle(tuning.physicsDescriptor(
            .{ .pose = .{ .position = .{ 0, 2, 0 }, .rotation = .{ 0, @sin(heading / 2), 0, @cos(heading / 2) } } },
            zeroWheelDynamics(),
        ));
        errdefer vehicles.destroyVehicle(vehicle) catch {};
        var result = Scenario{
            .allocator = allocator,
            .physics = physics,
            .ground = ground,
            .vehicle = vehicle,
            .steering = tuning.steering,
            .timestep_s = timestep_s,
        };
        try result.step(.{}, @intFromFloat(@round(@as(f32, settle_ticks) * dt / timestep_s)));
        return result;
    }

    pub fn deinit(self: *Scenario) void {
        var vehicles = self.physics.vehicles();
        vehicles.destroyVehicle(self.vehicle) catch {};
        _ = self.physics.removeBody(self.ground);
        self.physics.deinit();
        self.allocator.destroy(self.physics);
        self.* = undefined;
    }

    fn step(self: *Scenario, input: engine.physics.VehicleInput, ticks: usize) !void {
        var vehicles = self.physics.vehicles();
        for (0..ticks) |_| {
            const current = try vehicles.vehicleState(self.vehicle);
            self.conditioned_steering = self.steering.update(self.conditioned_steering, input.steering, horizontalSpeed(current), self.timestep_s);
            var conditioned = vehicle_contract.control.resolve(input, vehicle_contract.control.forwardSpeed(current.chassis), horizontalSpeed(current), current.current_gear);
            conditioned.steering = self.conditioned_steering;
            try vehicles.setVehicleInput(self.vehicle, conditioned);
            self.applied_input = conditioned;
            try self.physics.update(self.timestep_s);
        }
    }

    pub fn tick(self: *Scenario, input: engine.physics.VehicleInput) !engine.physics.VehicleState {
        try self.step(input, 1);
        var vehicles = self.physics.vehicles();
        return vehicles.vehicleState(self.vehicle);
    }

    pub fn state(self: *Scenario) !engine.physics.VehicleState {
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
    tuning.rear_axle = .{ .suspension_frequency = tuning.suspension_frequency, .suspension_damping = tuning.suspension_damping, .brake_torque_nm = tuning.max_brake_torque, .tire_friction = tuning.tire_friction };
    return tuning;
}

pub fn horizontalSpeed(state: engine.physics.VehicleState) f32 {
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

pub fn rotate(rotation: [4]f32, value: [3]f32) [3]f32 {
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

pub fn yaw(state: engine.physics.VehicleState) f32 {
    const forward = rotate(state.chassis.pose.rotation, .{ 0, 0, -1 });
    return std.math.atan2(forward[0], -forward[2]);
}

pub fn wrappedAngleDelta(current: f32, previous: f32) f32 {
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

fn measureStopping(allocator: std.mem.Allocator, tuning: vehicle_contract.VehicleTuning) !Stopping {
    const spec = scenario_specification.stopping;
    var scenario = try Scenario.init(allocator, tuning);
    defer scenario.deinit();
    var state = try scenario.state();
    for (0..spec.approach_ticks) |_| {
        state = try scenario.tick(spec.approach_input);
        if (horizontalSpeed(state) >= spec.entry_speed_mps) break;
    }
    const entry_speed = horizontalSpeed(state);
    if (entry_speed < spec.entry_speed_mps) return .{ .status = .entry_speed_not_reached, .entry_speed_mps = entry_speed, .distance_m = null, .time_s = null };
    const start = state.chassis.pose.position;
    var elapsed_ticks: usize = 0;
    for (0..spec.brake_ticks) |_| {
        state = try scenario.tick(spec.brake_input);
        elapsed_ticks += 1;
        if (horizontalSpeed(state) < spec.terminal_speed_mps) break;
    }
    const complete = horizontalSpeed(state) < spec.terminal_speed_mps;
    return .{ .status = if (complete) .complete else .stop_not_reached, .entry_speed_mps = entry_speed, .distance_m = if (complete) horizontalDistance(start, state.chassis.pose.position) else null, .time_s = if (complete) @as(f32, @floatFromInt(elapsed_ticks)) * dt else null };
}

fn measureTurn(allocator: std.mem.Allocator, tuning: vehicle_contract.VehicleTuning) !struct { ?f32, f32 } {
    const spec = scenario_specification.turn;
    var scenario = try Scenario.init(allocator, tuning);
    defer scenario.deinit();
    try scenario.step(spec.input, spec.settle_ticks);
    var previous = try scenario.state();
    var path: f32 = 0;
    var yaw_change: f32 = 0;
    var slip_sum: f32 = 0;
    const sample_ticks: usize = spec.sample_ticks;
    for (0..sample_ticks) |_| {
        const state = try scenario.tick(spec.input);
        path += horizontalDistance(previous.chassis.pose.position, state.chassis.pose.position);
        yaw_change += @abs(wrappedAngleDelta(yaw(state), yaw(previous)));
        slip_sum += slipDegrees(state);
        previous = state;
    }
    return .{
        if (yaw_change > 0.001) path / yaw_change else null,
        slip_sum / @as(f32, @floatFromInt(sample_ticks)),
    };
}

fn measureSlalom(allocator: std.mem.Allocator, tuning: vehicle_contract.VehicleTuning) !struct { f32, f32, f32 } {
    const spec = scenario_specification.slalom;
    var scenario = try Scenario.init(allocator, tuning);
    defer scenario.deinit();
    try scenario.step(spec.approach_input, spec.approach_ticks);
    var previous = try scenario.state();
    var min_x = previous.chassis.pose.position[0];
    var max_x = min_x;
    var peak_yaw_rate: f32 = 0;
    var peak_slip: f32 = 0;
    for (0..spec.sample_ticks) |tick_index| {
        const phase = (tick_index / spec.phase_ticks) & 1;
        const steering: f32 = if (phase == 0) spec.steering_amplitude else -spec.steering_amplitude;
        const state = try scenario.tick(.{ .throttle = spec.throttle, .steering = steering });
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

fn measureSkidRecovery(allocator: std.mem.Allocator, tuning: vehicle_contract.VehicleTuning) !Recovery {
    const spec = scenario_specification.skid;
    var scenario = try Scenario.init(allocator, tuning);
    defer scenario.deinit();
    try scenario.step(spec.approach_input, spec.approach_ticks);
    var peak_slip: f32 = 0;
    for (0..spec.breakaway_ticks) |_| {
        const state = try scenario.tick(spec.breakaway_input);
        peak_slip = @max(peak_slip, slipDegrees(state));
    }
    if (peak_slip <= spec.stable_slip_degrees) return .{ .peak_slip_deg = peak_slip, .time_s = null, .status = .breakaway_not_reached };
    var stable_ticks: usize = 0;
    var recovery_ticks: usize = 0;
    for (0..spec.recovery_ticks) |_| {
        const state = try scenario.tick(spec.recovery_input);
        peak_slip = @max(peak_slip, slipDegrees(state));
        recovery_ticks += 1;
        stable_ticks = if (slipDegrees(state) < spec.stable_slip_degrees) stable_ticks + 1 else 0;
        if (stable_ticks >= spec.stable_ticks) break;
    }
    const effective_ticks = recovery_ticks -| stable_ticks;
    const complete = stable_ticks >= spec.stable_ticks;
    return .{ .peak_slip_deg = peak_slip, .time_s = if (complete) @as(f32, @floatFromInt(effective_ticks)) * dt else null, .status = if (complete) .complete else .recovery_not_reached };
}

fn measureRollover(allocator: std.mem.Allocator, tuning: vehicle_contract.VehicleTuning) !struct { f32, bool } {
    const spec = scenario_specification.rollover;
    var scenario = try Scenario.init(allocator, tuning);
    defer scenario.deinit();
    try scenario.step(spec.approach_input, spec.approach_ticks);
    var maximum_tilt: f32 = 0;
    var rolled = false;
    for (0..spec.sample_ticks) |_| {
        const state = try scenario.tick(spec.input);
        const up = rotate(state.chassis.pose.rotation, .{ 0, 1, 0 });
        const up_y = std.math.clamp(up[1], -1, 1);
        maximum_tilt = @max(maximum_tilt, std.math.radiansToDegrees(std.math.acos(up_y)));
        rolled = rolled or up_y <= 0;
    }
    return .{ maximum_tilt, rolled };
}

pub fn measure(allocator: std.mem.Allocator, tuning: vehicle_contract.VehicleTuning) !Metrics {
    try tuning.validate();
    const stopping = try measureStopping(allocator, tuning);
    const turn = try measureTurn(allocator, tuning);
    const slalom = try measureSlalom(allocator, tuning);
    const skid = try measureSkidRecovery(allocator, tuning);
    const rollover = try measureRollover(allocator, tuning);
    return .{
        .stopping_status = stopping.status,
        .skid_status = skid.status,
        .stopping_entry_speed_mps = stopping.entry_speed_mps,
        .stopping_distance_m = stopping.distance_m,
        .stopping_time_s = stopping.time_s,
        .steady_turn_radius_m = turn[0],
        .steady_turn_mean_slip_deg = turn[1],
        .slalom_lateral_excursion_m = slalom[0],
        .slalom_peak_yaw_rate_deg_s = slalom[1],
        .slalom_peak_slip_deg = slalom[2],
        .skid_peak_slip_deg = skid.peak_slip_deg,
        .skid_recovery_s = skid.time_s,
        .rollover_max_tilt_deg = rollover[0],
        .rollover_occurred = rollover[1],
    };
}

fn printMetrics(label: []const u8, value: Metrics) void {
    std.debug.print(
        "{s} stop_entry={d:.3}mps stop_distance={?d:.3}m stop_time={?d:.3}s turn_radius={?d:.3}m turn_slip={d:.3}deg slalom_excursion={d:.3}m slalom_yaw_rate={d:.3}deg_s slalom_slip={d:.3}deg skid_peak={d:.3}deg skid_recovery={?d:.3}s rollover_tilt={d:.3}deg rollover={}\n",
        .{ label, value.stopping_entry_speed_mps, value.stopping_distance_m, value.stopping_time_s, value.steady_turn_radius_m, value.steady_turn_mean_slip_deg, value.slalom_lateral_excursion_m, value.slalom_peak_yaw_rate_deg_s, value.slalom_peak_slip_deg, value.skid_peak_slip_deg, value.skid_recovery_s, value.rollover_max_tilt_deg, value.rollover_occurred },
    );
}

const scenario_specification = .{
    .revision = "flat-rig-2-degree-curves",
    .timestep_s = dt,
    .settle_ticks = settle_ticks,
    .surface = .{ .half_extents_m = [3]f32{ 500, 1, 500 }, .top_y_m = 0, .friction = @as(f32, 0.2) },
    .initial_position_m = [3]f32{ 0, 2, 0 },
    .stopping = .{ .approach_ticks = 2400, .approach_input = engine.physics.VehicleInput{ .throttle = 1 }, .entry_speed_mps = @as(f32, 15), .brake_ticks = 1200, .brake_input = engine.physics.VehicleInput{ .brake = 1 }, .terminal_speed_mps = @as(f32, 0.25) },
    .turn = .{ .settle_ticks = 720, .sample_ticks = 720, .input = engine.physics.VehicleInput{ .throttle = 0.4, .steering = 0.5 } },
    .slalom = .{ .approach_ticks = 360, .approach_input = engine.physics.VehicleInput{ .throttle = 0.75 }, .sample_ticks = 1200, .phase_ticks = 96, .throttle = @as(f32, 0.65), .steering_amplitude = @as(f32, 0.7) },
    .skid = .{ .approach_ticks = 600, .approach_input = engine.physics.VehicleInput{ .throttle = 1 }, .breakaway_ticks = 150, .breakaway_input = engine.physics.VehicleInput{ .throttle = 0.25, .steering = 0.8, .hand_brake = 1 }, .recovery_ticks = 1200, .recovery_input = engine.physics.VehicleInput{ .throttle = 0.25 }, .stable_ticks = 60, .stable_slip_degrees = @as(f32, 3) },
    .rollover = .{ .approach_ticks = 720, .approach_input = engine.physics.VehicleInput{ .throttle = 1 }, .sample_ticks = 1200, .input = engine.physics.VehicleInput{ .throttle = 0.75, .steering = 1 } },
};

// Input schedules are experiment definitions, not engine limits or worker timeouts.
const Segment = struct { ticks: usize, input: engine.physics.VehicleInput };
const Obstacle = enum { none, bump, left_curb, rollover_curb };
const ManeuverSpec = struct {
    name: []const u8,
    entry_speed_mps: f32 = 0,
    approach_ticks: usize = 3600,
    obstacle: Obstacle = .none,
    segments: []const Segment,
};
const maneuvers = [_]ManeuverSpec{
    .{ .name = "acceleration_and_lift", .segments = &.{ .{ .ticks = 2400, .input = .{ .throttle = 1 } }, .{ .ticks = 480, .input = .{} } } },
    .{ .name = "left_turn_8", .entry_speed_mps = 8, .segments = &.{.{ .ticks = 720, .input = .{ .throttle = 0.4, .steering = -0.5 } }} },
    .{ .name = "right_turn_8", .entry_speed_mps = 8, .segments = &.{.{ .ticks = 720, .input = .{ .throttle = 0.4, .steering = 0.5 } }} },
    .{ .name = "left_turn_16", .entry_speed_mps = 16, .segments = &.{.{ .ticks = 720, .input = .{ .throttle = 0.4, .steering = -0.5 } }} },
    .{ .name = "right_turn_16", .entry_speed_mps = 16, .segments = &.{.{ .ticks = 720, .input = .{ .throttle = 0.4, .steering = 0.5 } }} },
    .{ .name = "left_turn_24", .entry_speed_mps = 24, .segments = &.{.{ .ticks = 720, .input = .{ .throttle = 0.4, .steering = -0.5 } }} },
    .{ .name = "right_turn_24", .entry_speed_mps = 24, .segments = &.{.{ .ticks = 720, .input = .{ .throttle = 0.4, .steering = 0.5 } }} },
    .{ .name = "braking_turn", .entry_speed_mps = 16, .segments = &.{ .{ .ticks = 240, .input = .{ .throttle = 0.4, .steering = 0.5 } }, .{ .ticks = 360, .input = .{ .brake = 0.65, .steering = 0.5 } }, .{ .ticks = 240, .input = .{} } } },
    .{ .name = "lift_off_turn", .entry_speed_mps = 16, .segments = &.{ .{ .ticks = 240, .input = .{ .throttle = 0.4, .steering = 0.5 } }, .{ .ticks = 600, .input = .{ .steering = 0.5 } } } },
    .{ .name = "steering_step_and_release", .entry_speed_mps = 16, .segments = &.{ .{ .ticks = 360, .input = .{ .throttle = 0.4, .steering = 0.7 } }, .{ .ticks = 600, .input = .{} } } },
    .{ .name = "throttle_breakaway", .entry_speed_mps = 8, .segments = &.{ .{ .ticks = 360, .input = .{ .throttle = 1, .steering = 0.9 } }, .{ .ticks = 600, .input = .{ .throttle = 0.2 } } } },
    .{ .name = "handbrake_breakaway", .entry_speed_mps = 16, .segments = &.{ .{ .ticks = 150, .input = .{ .hand_brake = 1, .steering = 0.8 } }, .{ .ticks = 600, .input = .{ .throttle = 0.2 } } } },
    .{ .name = "full_width_bump", .entry_speed_mps = 8, .obstacle = .bump, .segments = &.{.{ .ticks = 480, .input = .{} }} },
    .{ .name = "left_wheel_curb", .entry_speed_mps = 8, .obstacle = .left_curb, .segments = &.{.{ .ticks = 480, .input = .{} }} },
    .{ .name = "severe_turn_and_curb", .entry_speed_mps = 16, .obstacle = .rollover_curb, .segments = &.{.{ .ticks = 720, .input = .{ .throttle = 0.5, .steering = 1 } }} },
};
const WheelSample = struct {
    contact_valid: bool,
    suspension_length_m: f32,
    estimated_normal_load_n: ?f32,
    longitudinal_slip_ratio: ?f32,
    lateral_slip_rad: ?f32,
};
const Sample = struct {
    time_s: f32,
    input: engine.physics.VehicleInput,
    conditioned_steering: f32,
    pose: engine.physics.Pose,
    velocity: engine.physics.Velocity,
    speed_mps: f32,
    acceleration_mps2: [3]f32,
    chassis_sideslip_deg: f32,
    pitch_deg: f32,
    roll_deg: f32,
    yaw_rate_deg_s: f32,
    engine_rpm: f32,
    gear: i32,
    wheels: [4]WheelSample,
};
const Maneuver = struct {
    specification: ManeuverSpec,
    entry_reached: bool,
    actual_entry_speed_mps: f32,
    obstacle_box: ?struct { position: [3]f32, half_extents: [3]f32 } = null,
    settled: engine.physics.VehicleState,
    peak_speed_mps: f32 = 0,
    peak_pitch_deg: f32 = 0,
    peak_roll_deg: f32 = 0,
    peak_chassis_sideslip_deg: f32 = 0,
    peak_yaw_rate_deg_s: f32 = 0,
    gear_changes: usize = 0,
    wheel_contact_loss_ticks: [4]usize = @splat(0),
    minimum_travel_m: [4]?f32 = @splat(null),
    maximum_travel_m: [4]f32 = @splat(0),
    peak_estimated_load_n: [4]f32 = @splat(0),
    samples: []const Sample = &.{},
    prediction: ?vehicle_prediction.Diagnostics = null,
};
fn productTicks(reference_ticks: usize) usize {
    return @intFromFloat(@round(@as(f32, @floatFromInt(reference_ticks)) * dt / product_dt));
}
fn characterize(allocator: std.mem.Allocator, tuning: vehicle_contract.VehicleTuning) ![]Maneuver {
    const results = try allocator.alloc(Maneuver, maneuvers.len);
    for (maneuvers, results) |spec, *result| {
        var scenario = try Scenario.initWithTimestep(allocator, tuning, product_dt);
        defer scenario.deinit();
        const settled = try scenario.state();
        var previous = settled;
        for (0..productTicks(spec.approach_ticks)) |_| {
            if (horizontalSpeed(previous) >= spec.entry_speed_mps) break;
            previous = try scenario.tick(.{ .throttle = 1 });
        }
        result.* = .{ .specification = spec, .entry_reached = horizontalSpeed(previous) >= spec.entry_speed_mps, .actual_entry_speed_mps = horizontalSpeed(previous), .settled = settled };
        if (!result.entry_reached) continue;
        var obstacle_body: ?jolt.BodyId = null;
        defer if (obstacle_body) |body| {
            _ = scenario.physics.removeBody(body);
        };
        if (spec.obstacle != .none) {
            const height: f32 = switch (spec.obstacle) {
                .bump => 0.10,
                .left_curb => 0.14,
                .rollover_curb => 0.22,
                .none => unreachable,
            };
            const half_width = if (spec.obstacle == .bump) tuning.chassis_half_extents[0] * 2 else tuning.wheel_width;
            const x = if (spec.obstacle == .bump) @as(f32, 0) else tuning.wheel_attachment_positions[0][0];
            const box = .{ .position = [3]f32{ previous.chassis.pose.position[0] + x, height / 2, previous.chassis.pose.position[2] - 8 }, .half_extents = [3]f32{ half_width, height / 2, 0.25 } };
            result.obstacle_box = .{ .position = box.position, .half_extents = box.half_extents };
            obstacle_body = try scenario.physics.createStaticBox(box.position, box.half_extents);
        }
        var samples: std.ArrayList(Sample) = .empty;
        for (spec.segments) |segment| for (0..productTicks(segment.ticks)) |_| {
            const state = try scenario.tick(segment.input);
            const forward = rotate(state.chassis.pose.rotation, .{ 0, 0, -1 });
            const right = rotate(state.chassis.pose.rotation, .{ 1, 0, 0 });
            const pitch = std.math.radiansToDegrees(std.math.asin(std.math.clamp(forward[1], -1, 1)));
            const roll = std.math.radiansToDegrees(std.math.asin(std.math.clamp(right[1], -1, 1)));
            var sample = Sample{ .time_s = @as(f32, @floatFromInt(samples.items.len + 1)) * product_dt, .input = segment.input, .conditioned_steering = scenario.conditioned_steering, .pose = state.chassis.pose, .velocity = state.chassis.velocity, .speed_mps = horizontalSpeed(state), .acceleration_mps2 = undefined, .chassis_sideslip_deg = slipDegrees(state), .pitch_deg = pitch, .roll_deg = roll, .yaw_rate_deg_s = std.math.radiansToDegrees(wrappedAngleDelta(yaw(state), yaw(previous))) / product_dt, .engine_rpm = state.engine_rpm, .gear = state.current_gear, .wheels = undefined };
            for (&sample.acceleration_mps2, state.chassis.velocity.linear, previous.chassis.velocity.linear) |*accel, current, prior| accel.* = (current - prior) / product_dt;
            for (state.wheels, &sample.wheels, 0..) |wheel, *out, index| {
                out.* = .{ .contact_valid = wheel.has_contact, .suspension_length_m = wheel.suspension_length, .estimated_normal_load_n = if (wheel.has_contact) wheel.suspension_impulse_ns / product_dt else null, .longitudinal_slip_ratio = if (wheel.has_contact) wheel.longitudinal_slip else null, .lateral_slip_rad = if (wheel.has_contact) wheel.lateral_slip_radians else null };
                result.wheel_contact_loss_ticks[index] += @intFromBool(!wheel.has_contact);
                result.minimum_travel_m[index] = @min(result.minimum_travel_m[index] orelse wheel.suspension_length, wheel.suspension_length);
                result.maximum_travel_m[index] = @max(result.maximum_travel_m[index], wheel.suspension_length);
                result.peak_estimated_load_n[index] = @max(result.peak_estimated_load_n[index], out.estimated_normal_load_n orelse 0);
            }
            result.peak_speed_mps = @max(result.peak_speed_mps, sample.speed_mps);
            result.peak_pitch_deg = @max(result.peak_pitch_deg, @abs(pitch));
            result.peak_roll_deg = @max(result.peak_roll_deg, @abs(roll));
            result.peak_chassis_sideslip_deg = @max(result.peak_chassis_sideslip_deg, sample.chassis_sideslip_deg);
            result.peak_yaw_rate_deg_s = @max(result.peak_yaw_rate_deg_s, @abs(sample.yaw_rate_deg_s));
            result.gear_changes += @intFromBool(state.current_gear != previous.current_gear);
            try samples.append(allocator, sample);
            previous = state;
        };
        result.samples = try samples.toOwnedSlice(allocator);
    }
    return results;
}

fn characterizePrediction(definition: protocol.VehicleDefinition, samples: []const Sample) ?vehicle_prediction.Diagnostics {
    if (samples.len == 0) return null;
    var prediction = vehicle_prediction.Prediction{};
    prediction.reconcile(predictionState(definition, samples[0]), .{ .value = 1 }, 1);
    for (samples[1..], 2..) |sample, tick| {
        prediction.record(.{ .session = .{ .value = 1 }, .participant = .{ .index = 1, .generation = 1 }, .vehicle = .{ .index = 1, .generation = 1 }, .sequence = .{ .value = @intCast(tick) }, .target_tick = tick, .throttle = sample.input.throttle, .steering = sample.input.steering, .brake = sample.input.brake, .hand_brake = sample.input.hand_brake });
        if (tick % 6 == 0) {
            const snapshot_tick = tick - 3;
            prediction.reconcile(predictionState(definition, samples[snapshot_tick - 1]), .{ .value = @intCast(snapshot_tick) }, snapshot_tick);
        }
    }
    return prediction.diagnostics();
}
fn predictionState(definition: protocol.VehicleDefinition, sample: Sample) protocol.VehicleState {
    return .{ .definition = definition, .entity = .{ .index = 1, .generation = 1 }, .driver = .{ .index = 1, .generation = 1 }, .position = sample.pose.position, .rotation = sample.pose.rotation, .linear_velocity = sample.velocity.linear, .angular_velocity = sample.velocity.angular };
}

pub const build_identity = .{
    .tire_response = engine.physics.vehicle_tire_response,
    .source_cohort = cohort.build_cohort,
    .jolt_revision = physics_cohort.jolt_revision,
    .joltc_revision = physics_cohort.joltc_revision,
    .zig_version = @import("builtin").zig_version_string,
    .optimize = @tagName(@import("builtin").mode),
    .architecture = @tagName(@import("builtin").cpu.arch),
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 1) {
        const motion = std.mem.eql(u8, args[1], "--motion-audit") or std.mem.eql(u8, args[1], "--motion-summary");
        if ((args.len != 3 and !(motion and args.len == 5)) or (!motion and !std.mem.eql(u8, args[1], "--definition"))) return error.ExpectedVehicleDefinitionPath;
        var heading: ?u16 = null;
        if (args.len == 5) {
            if (!std.mem.eql(u8, args[3], "--heading")) return error.ExpectedHeading;
            const value = try std.fmt.parseInt(u16, args[4], 10);
            if (value != 0 and value != 90 and value != 180 and value != 270) return error.InvalidAuditHeading;
            heading = value;
        }
        const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, args[2], allocator, .unlimited);
        defer allocator.free(bytes);
        var candidate = try vehicle_contract.asset.decode(allocator, bytes);
        defer candidate.deinit();
        if (motion) return @import("vehicle_motion_audit.zig").run(init, candidate.value, std.mem.eql(u8, args[1], "--motion-audit"), heading);
        const tuning = try candidate.value.tuning.toTuning();
        const metrics = try measure(allocator, tuning);
        const characterization = try characterize(init.arena.allocator(), tuning);
        const admitted = vehicle_contract.presentation.Definition.fromDefinition(candidate.value, try candidate.value.digest(allocator));
        for (characterization) |*maneuver| maneuver.prediction = characterizePrediction(admitted, maneuver.samples);
        printMetrics(candidate.value.label, metrics);
        try writeJson(init, .{
            .schema = 2,
            .build = build_identity,
            .definition_digest = try candidate.value.digest(allocator),
            .definition = candidate.value,
            .scenario = scenario_specification,
            .metrics = metrics,
            .characterization = characterization,
            .characterization_timestep_s = product_dt,
            .schedule_tick_unit_s = dt,
            .prediction_schedule = .{ .snapshot_every_ticks = 6, .snapshot_delay_ticks = 3, .packet_loss = false },
            .telemetry = "Loads are contact-valid solver suspension impulses / fixed timestep; tire slip and chassis sideslip are distinct. Turn sweeps specify entry speed and open-loop inputs, not a speed-hold assist.",
        });
        try requireComplete(metrics);
        for (characterization) |result| if (!result.entry_reached) return error.VehicleDynamicsScenarioIncomplete;
        return;
    }
    const legacy = try measure(allocator, legacyTuning());
    const current = try measure(allocator, .{});
    printMetrics("legacy", legacy);
    printMetrics("current", current);
    // Relative slip and rollover are reported handling choices. Incomplete
    // experiments cannot masquerade as measured distances or recovery times.
    try writeJson(init, .{
        .schema = 1,
        .build = build_identity,
        .scenario = scenario_specification,
        .legacy_definition = vehicle_contract.VehicleTuningV1.fromTuning(legacyTuning()),
        .current_definition = vehicle_contract.VehicleTuningV1.fromTuning(.{}),
        .legacy = legacy,
        .current = current,
    });
    try requireComplete(legacy);
    try requireComplete(current);
}

pub fn writeJson(init: std.process.Init, value: anytype) !void {
    var buffer: [4096]u8 = undefined;
    var file_writer = std.Io.File.stdout().writer(init.io, &buffer);
    try std.json.Stringify.value(value, .{ .whitespace = .indent_2 }, &file_writer.interface);
    try file_writer.interface.writeByte('\n');
    try file_writer.interface.flush();
}

fn requireComplete(metrics: Metrics) !void {
    if (metrics.stopping_status != .complete or metrics.skid_status != .complete or metrics.steady_turn_radius_m == null)
        return error.VehicleDynamicsScenarioIncomplete;
}

test "vehicle dynamics angle wrapping is canonical" {
    try std.testing.expectApproxEqAbs(
        @as(f32, std.math.degreesToRadians(2.0)),
        wrappedAngleDelta(std.math.degreesToRadians(-179.0), std.math.degreesToRadians(179.0)),
        0.0001,
    );
}

test "underpowered candidate reports incomplete entry and no stopping measurement" {
    var tuning = vehicle_contract.VehicleTuning{};
    tuning.powertrain.max_torque_nm = 0.001;
    const result = try measureStopping(std.testing.allocator, tuning);
    try std.testing.expectEqual(StoppingStatus.entry_speed_not_reached, result.status);
    try std.testing.expect(result.distance_m == null and result.time_s == null);
}

test "no measured breakaway never becomes zero recovery time" {
    var tuning = vehicle_contract.VehicleTuning{};
    tuning.max_steer_radians = 0.0001;
    const result = try measureSkidRecovery(std.testing.allocator, tuning);
    try std.testing.expectEqual(RecoveryStatus.breakaway_not_reached, result.status);
    try std.testing.expect(result.time_s == null);
}

test "authored FWD RWD and AWD baselines stop break away and recover on real Jolt" {
    const catalog = @import("game_vehicles");
    for ([_][]const u8{ catalog.courier_bytes, catalog.meridian_bytes, catalog.courier_awd_bytes }) |bytes| {
        var definition = try vehicle_contract.asset.decode(std.testing.allocator, bytes);
        defer definition.deinit();
        const metrics = try measure(std.testing.allocator, try definition.value.tuning.toTuning());
        printMetrics(definition.value.label, metrics);
        try requireComplete(metrics);
        try std.testing.expect(!metrics.rollover_occurred);
        try @import("vehicle_motion_audit.zig").verifyHandling(std.testing.allocator, definition.value);
    }
}

test "compact motion reports preserve full-trace measurements" {
    var definition = try @import("game_vehicles").embeddedSedan(std.testing.allocator);
    defer definition.deinit();
    try @import("vehicle_motion_audit.zig").verifySummary(std.testing.allocator, definition.value);
}
