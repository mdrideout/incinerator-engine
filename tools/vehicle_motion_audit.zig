//! Real-Jolt driving schedules and physics-to-replication wheel alignment.
//! Durations define repeatable experiments, never execution timeouts.
const std = @import("std");
const rig = @import("vehicle_dynamics.zig");
const engine = @import("engine_contracts");
const vehicle = @import("vehicle_contract");
const protocol = @import("session_protocol");
const world = @import("replicated_world");
const summary = @import("vehicle_motion_summary.zig");
const dt: f32 = 1.0 / 60.0;
const Segment = struct { ticks: usize, input: engine.physics.VehicleInput };
const Spec = struct {
    name: []const u8,
    entry_mps: f32 = 0,
    segments: []const Segment,
};
const specs = [_]Spec{
    .{ .name = "matched_coast_turn", .entry_mps = 8, .segments = &.{ .{ .ticks = 30, .input = .{ .throttle = 0.4, .steering = 0.5 } }, .{ .ticks = 60, .input = .{ .steering = 0.5 } }, .{ .ticks = 180, .input = .{ .throttle = 0.2 } } } },
    .{ .name = "matched_power_turn", .entry_mps = 8, .segments = &.{ .{ .ticks = 30, .input = .{ .throttle = 0.4, .steering = 0.5 } }, .{ .ticks = 60, .input = .{ .throttle = 1, .steering = 0.5 } }, .{ .ticks = 180, .input = .{ .throttle = 0.2 } } } },
    .{ .name = "matched_service_turn", .entry_mps = 8, .segments = &.{ .{ .ticks = 30, .input = .{ .throttle = 0.4, .steering = 0.5 } }, .{ .ticks = 60, .input = .{ .brake = 1, .steering = 0.5 } }, .{ .ticks = 180, .input = .{ .throttle = 0.2 } } } },
    .{ .name = "matched_handbrake_turn", .entry_mps = 8, .segments = &.{ .{ .ticks = 30, .input = .{ .throttle = 0.4, .steering = 0.5 } }, .{ .ticks = 60, .input = .{ .hand_brake = 1, .steering = 0.5 } }, .{ .ticks = 180, .input = .{ .throttle = 0.2 } } } },
    .{ .name = "straight_handbrake", .entry_mps = 8, .segments = &.{ .{ .ticks = 60, .input = .{ .hand_brake = 1 } }, .{ .ticks = 180, .input = .{ .throttle = 0.2 } } } },
    .{ .name = "power_handbrake", .entry_mps = 8, .segments = &.{ .{ .ticks = 60, .input = .{ .throttle = 1, .hand_brake = 1 } }, .{ .ticks = 180, .input = .{ .throttle = 0.2 } } } },
    .{ .name = "forward_coast_stop", .segments = &.{ .{ .ticks = 360, .input = .{ .throttle = 1 } }, .{ .ticks = 120, .input = .{} }, .{ .ticks = 240, .input = .{ .brake = 1 } } } },
    .{ .name = "reverse_coast_stop", .segments = &.{ .{ .ticks = 360, .input = .{ .throttle = -1 } }, .{ .ticks = 120, .input = .{} }, .{ .ticks = 240, .input = .{ .brake = 1 } } } },
    .{ .name = "forward_to_reverse", .entry_mps = 8, .segments = &.{.{ .ticks = 600, .input = .{ .throttle = -1 } }} },
    .{ .name = "reverse_to_forward", .entry_mps = -8, .segments = &.{.{ .ticks = 600, .input = .{ .throttle = 1 } }} },
    .{ .name = "forward_to_reverse_steering", .entry_mps = 8, .segments = &.{.{ .ticks = 600, .input = .{ .throttle = -1, .steering = 0.5 } }} },
    .{ .name = "reverse_to_forward_steering", .entry_mps = -8, .segments = &.{.{ .ticks = 600, .input = .{ .throttle = 1, .steering = -0.5 } }} },
    .{ .name = "forward_service_brake", .entry_mps = 16, .segments = &.{.{ .ticks = 240, .input = .{ .brake = 1 } }} },
    .{ .name = "reverse_service_brake", .entry_mps = -8, .segments = &.{.{ .ticks = 240, .input = .{ .brake = 1 } }} },
    .{ .name = "forward_handbrake_countersteer", .entry_mps = 16, .segments = &.{ .{ .ticks = 75, .input = .{ .hand_brake = 1, .steering = 0.8 } }, .{ .ticks = 60, .input = .{ .throttle = 0.2, .steering = -0.5 } }, .{ .ticks = 300, .input = .{ .throttle = 0.2 } } } },
    .{ .name = "reverse_handbrake_countersteer", .entry_mps = -8, .segments = &.{ .{ .ticks = 75, .input = .{ .hand_brake = 1, .steering = 0.8 } }, .{ .ticks = 60, .input = .{ .throttle = -0.2, .steering = -0.5 } }, .{ .ticks = 300, .input = .{ .throttle = -0.2 } } } },
};
const Sample = struct {
    tick: usize,
    input: engine.physics.VehicleInput,
    conditioned_steering: f32,
    applied_input: engine.physics.VehicleInput,
    authority: engine.physics.VehicleState,
    replicated: protocol.VehicleState,
    composed_wheels: [4]world.WheelPose,
    forward_mps: f32,
    lateral_mps: f32,
    sideslip_deg: ?f32,
    wheel_position_error_m: f32,
    wheel_axis_error: f32,
};
const Result = struct {
    specification: Spec,
    heading_deg: f32,
    entry_reached: bool,
    entry_forward_mps: f32,
    final_forward_mps: f32 = 0,
    peak_forward_mps: f32 = 0,
    peak_reverse_mps: f32 = 0,
    peak_lateral_mps: f32 = 0,
    peak_sideslip_deg: f32 = 0,
    wheel_position_error_m: f32 = 0,
    wheel_axis_error: f32 = 0,
    opposing_gear_at_speed_ticks: usize = 0,
    initial_turn_yaw_deg: f32 = 0,
    sample_count: usize = 0,
    axle_phases: []const summary.Phase = &.{},
    samples: []const Sample = &.{},
};
pub fn components(state: engine.physics.VehicleState) [2]f32 {
    const f = rig.rotate(state.chassis.pose.rotation, .{ 0, 0, -1 });
    const r = rig.rotate(state.chassis.pose.rotation, .{ 1, 0, 0 });
    const v = state.chassis.velocity.linear;
    return .{ dot(f, v), dot(r, v) };
}
fn dot(a: [3]f32, b: [3]f32) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}
fn distance(a: [3]f32, b: [3]f32) f32 {
    const d = [3]f32{ a[0] - b[0], a[1] - b[1], a[2] - b[2] };
    return @sqrt(dot(d, d));
}
pub fn projected(definition: protocol.VehicleDefinition, state: engine.physics.VehicleState) protocol.VehicleState {
    var result = protocol.VehicleState{ .definition = definition, .entity = .{ .index = 1, .generation = 1 }, .driver = null, .position = state.chassis.pose.position, .rotation = state.chassis.pose.rotation, .linear_velocity = state.chassis.velocity.linear, .angular_velocity = state.chassis.velocity.angular };
    for (&result.wheels, state.wheels) |*out, wheel| out.* = .{ .spin_phase = wheel.rotation_angle, .angular_velocity = wheel.angular_velocity, .steer_angle = wheel.steer_angle, .suspension_length = wheel.suspension_length, .has_contact = wheel.has_contact };
    return result;
}
fn measure(allocator: std.mem.Allocator, definition: vehicle.asset.Definition, spec: Spec, heading: f32, trace: bool) !Result {
    var scenario = try rig.Scenario.initWithHeading(allocator, try definition.tuning.toTuning(), dt, std.math.degreesToRadians(heading));
    defer scenario.deinit();
    var state = try scenario.state();
    const direction: f32 = if (spec.entry_mps < 0) -1 else 1;
    for (0..1800) |_| {
        if (components(state)[0] * direction >= @abs(spec.entry_mps)) break;
        state = try scenario.tick(.{ .throttle = direction });
    }
    var result = Result{ .specification = spec, .heading_deg = heading, .entry_reached = components(state)[0] * direction >= @abs(spec.entry_mps), .entry_forward_mps = components(state)[0] };
    if (!result.entry_reached) return result;
    const entry_yaw = rig.yaw(state);
    const admitted = vehicle.presentation.Definition.fromDefinition(definition, try definition.digest(allocator));
    var samples: std.ArrayList(Sample) = .empty;
    const phases = try allocator.alloc(summary.Phase, spec.segments.len);
    const wheelbase = @abs(definition.tuning.wheel_attachment_positions[0][2] - definition.tuning.wheel_attachment_positions[2][2]);
    for (spec.segments, phases) |segment, *phase| {
        phase.* = .{ .input = segment.input };
        for (0..segment.ticks) |_| {
            state = try scenario.tick(segment.input);
            const c = components(state);
            const replicated = projected(admitted, state);
            const poses = try world.composeVehicleWheelPoses(replicated, world.vehicleWheelLayout(admitted));
            var position_error: f32 = 0;
            var axis_error: f32 = 0;
            for (state.wheels, poses) |wheel, pose| {
                position_error = @max(position_error, distance(wheel.pose.position, pose.position));
                for ([_][3]f32{ .{ 1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, 0, 1 } }) |axis| axis_error = @max(axis_error, distance(rig.rotate(wheel.pose.rotation, axis), rig.rotate(pose.rotation, axis)));
            }
            // Below 0.5 m/s sideslip is poorly conditioned; retain signed velocities
            // and represent the angle as unavailable rather than a 90-degree skid.
            const slip: ?f32 = if (rig.horizontalSpeed(state) >= 0.5) std.math.radiansToDegrees(std.math.atan2(c[1], @abs(c[0]))) else null;
            result.sample_count += 1;
            phase.add(state, c[0], c[1], slip, scenario.conditioned_steering, dt, wheelbase);
            if (trace) try samples.append(allocator, .{ .tick = result.sample_count, .input = segment.input, .conditioned_steering = scenario.conditioned_steering, .applied_input = scenario.applied_input, .authority = state, .replicated = replicated, .composed_wheels = poses, .forward_mps = c[0], .lateral_mps = c[1], .sideslip_deg = slip, .wheel_position_error_m = position_error, .wheel_axis_error = axis_error });
            result.final_forward_mps = c[0];
            result.peak_forward_mps = @max(result.peak_forward_mps, c[0]);
            result.peak_reverse_mps = @max(result.peak_reverse_mps, -c[0]);
            result.peak_lateral_mps = @max(result.peak_lateral_mps, @abs(c[1]));
            result.peak_sideslip_deg = @max(result.peak_sideslip_deg, @abs(slip orelse 0));
            result.wheel_position_error_m = @max(result.wheel_position_error_m, position_error);
            result.wheel_axis_error = @max(result.wheel_axis_error, axis_error);
            result.opposing_gear_at_speed_ticks += @intFromBool(@abs(c[0]) > 1 and c[0] * @as(f32, @floatFromInt(state.current_gear)) < 0);
            if (result.sample_count == 30) result.initial_turn_yaw_deg = std.math.radiansToDegrees(rig.wrappedAngleDelta(rig.yaw(state), entry_yaw));
        }
        phase.finish();
    }
    result.axle_phases = phases;
    result.samples = try samples.toOwnedSlice(allocator);
    return result;
}
pub fn run(init: std.process.Init, definition: vehicle.asset.Definition, trace: bool, selected_heading: ?u16) !void {
    const allocator = init.arena.allocator();
    var results: std.ArrayList(Result) = .empty;
    for ([_]f32{ 0, 90, 180, 270 }) |heading| {
        if (selected_heading) |selected| if (heading != @as(f32, @floatFromInt(selected))) continue;
        for (specs) |spec| try results.append(allocator, try measure(allocator, definition, spec, heading, trace));
        for ([_]f32{ 2, 8, 16, 24, -2, -8, -12 }) |speed| for ([_]f32{ -0.5, 0.5 }) |steer| {
            const segments = try allocator.alloc(Segment, 1);
            segments[0] = .{ .ticks = 180, .input = .{ .throttle = if (speed < 0) -0.4 else 0.4, .steering = steer } };
            const name = try std.fmt.allocPrint(allocator, "{s}_{s}_{d}", .{ if (speed < 0) "reverse" else "forward", if (steer < 0) "left" else "right", @abs(speed) });
            try results.append(allocator, try measure(allocator, definition, .{ .name = name, .entry_mps = speed, .segments = segments }, heading, trace));
        };
    }
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &buffer);
    try std.json.Stringify.value(.{ .schema = 2, .trace_retained = trace, .build = rig.build_identity, .definition = definition, .definition_digest = try definition.digest(allocator), .timestep_s = dt, .surface = .{ .friction = @as(f32, 0.2), .top_y_m = @as(f32, 0), .kind = "static_box_shared_with_industrial_ground" }, .results = results.items }, .{}, &output.interface);
    try output.interface.writeByte('\n');
    try output.interface.flush();
    for (results.items) |r| {
        if (!r.entry_reached) return error.MotionAuditEntryNotReached;
        const name = r.specification.name;
        if (std.mem.endsWith(u8, name, "stop") or std.mem.endsWith(u8, name, "service_brake")) {
            if (@abs(r.final_forward_mps) > 0.1) return error.MotionAuditDidNotStop;
        }
        if (std.mem.startsWith(u8, name, "forward_to_reverse") and r.final_forward_mps >= -0.5) return error.MotionAuditDidNotReverse;
        if (std.mem.startsWith(u8, name, "reverse_to_forward") and r.final_forward_mps <= 0.5) return error.MotionAuditDidNotDriveForward;
        const left = std.mem.indexOf(u8, name, "_left_") != null;
        const right = std.mem.indexOf(u8, name, "_right_") != null;
        if (left or right) {
            const turn_sign: f32 = (if (left) @as(f32, -1) else 1) * (if (r.specification.entry_mps < 0) @as(f32, -1) else 1);
            if (r.initial_turn_yaw_deg * turn_sign <= 0) return error.MotionAuditSteeringDirection;
        }
        if (r.wheel_position_error_m > 0.001 or r.wheel_axis_error > 0.001) return error.MotionAuditWheelAlignment;
    }
}

/// Product road-car expectations, independent of named drivetrain branches.
/// Ten degrees separates a composed road turn from the original 84-degree spin.
pub fn verifyHandling(backing: std.mem.Allocator, definition: vehicle.asset.Definition) !void {
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const allocator = arena.allocator();
    const coast = try measure(allocator, definition, specs[0], 0, true);
    const power = try measure(allocator, definition, specs[1], 0, true);
    const service = try measure(allocator, definition, specs[2], 0, true);
    const handbrake = try measure(allocator, definition, specs[3], 0, true);
    const straight = try measure(allocator, definition, specs[4], 0, true);
    for ([_]Result{ coast, power, service, handbrake, straight }) |result| {
        try std.testing.expect(result.entry_reached);
        try std.testing.expect(result.wheel_position_error_m < 0.001 and result.wheel_axis_error < 0.001);
    }
    try std.testing.expect(coast.peak_sideslip_deg < 10);
    try std.testing.expect(power.peak_sideslip_deg < 10);
    try std.testing.expect(service.peak_sideslip_deg < 10);
    try std.testing.expect(handbrake.peak_sideslip_deg > coast.peak_sideslip_deg);
    try std.testing.expect(straight.samples[59].forward_mps < straight.entry_forward_mps);
    try std.testing.expect(straight.peak_sideslip_deg < 1);
    var rear_locked: usize = 0;
    for (straight.samples[0..60]) |sample| {
        for (sample.authority.wheels[0..2]) |wheel| try std.testing.expect(@abs(wheel.angular_velocity) > 0.001);
        for (sample.authority.wheels[2..4]) |wheel| if (@abs(wheel.angular_velocity) < 0.001) {
            rear_locked += 1;
        };
    }
    try std.testing.expect(rear_locked > 0);
    // High-grip road tuning may remain composed under power at 8 m/s, including
    // RWD. Intentional handbrake breakaway remains required above.
}

/// The compact accumulator must observe exactly the same ticks as a full trace.
pub fn verifySummary(backing: std.mem.Allocator, definition: vehicle.asset.Definition) !void {
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const allocator = arena.allocator();
    var trace = try measure(allocator, definition, specs[3], 90, true);
    const compact = try measure(allocator, definition, specs[3], 90, false);
    try std.testing.expectEqual(@as(usize, 270), trace.samples.len);
    try std.testing.expectEqual(trace.samples.len, compact.sample_count);
    try std.testing.expectEqual(@as(usize, 0), compact.samples.len);
    trace.samples = &.{};
    try std.testing.expectEqualDeep(trace, compact);
}
