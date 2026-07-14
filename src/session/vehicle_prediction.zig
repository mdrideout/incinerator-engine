//! Bounded client-side prediction for the locally owned vehicle.
//!
//! This is a disposable presentation motor, not a Jolt replica or a source of
//! gameplay truth. It predicts only a short input horizon, preserves a bounded
//! input history for reconciliation, and always yields to authoritative
//! chassis snapshots.

const std = @import("std");
const budgets = @import("session_budgets");
const identity = @import("session_identity");
const protocol = @import("session_protocol");

const fixed_delta_seconds: f32 = 1.0 /
    @as(f32, @floatFromInt(budgets.authority_tick_hz));
const engine_acceleration_mps2: f32 = 10.0;
const rolling_deceleration_mps2: f32 = 1.25;
const brake_deceleration_mps2: f32 = 18.0;
const hand_brake_deceleration_mps2: f32 = 28.0;
const maximum_forward_speed_mps: f32 = 28.0;
const maximum_reverse_speed_mps: f32 = 10.0;
const maximum_yaw_rate_radians: f32 = 1.35;
const correction_retention_per_tick: f32 = 0.78;
const correction_episode_ticks: u16 = budgets.authority_tick_hz / 2;

const Record = struct {
    input: protocol.VehicleInputFrame,
};

pub const Diagnostics = struct {
    initialized: bool,
    history_count: u16,
    history_high_water: u16,
    history_overflows: u64,
    horizon_clamps: u64,
    maximum_prediction_lead_ticks: u16,
    current_position_error_m: f32,
    maximum_position_error_m: f32,
    current_orientation_error_degrees: f32,
    maximum_orientation_error_degrees: f32,
    current_velocity_error_mps: f32,
    maximum_velocity_error_mps: f32,
    correction_offset_m: f32,
    soft_corrections: u64,
    hard_corrections: u64,
    ownership_resets: u64,
    transport_resets: u64,
};

pub const Prediction = struct {
    initialized: bool = false,
    predicted: protocol.VehicleState = undefined,
    authoritative_tick: u64 = 0,
    position_offset: [3]f32 = .{ 0, 0, 0 },
    rotation_offset: [4]f32 = identity_quaternion,
    history: [budgets.input_history_ticks]Record = undefined,
    history_count: u16 = 0,
    history_high_water: u16 = 0,
    history_overflows: u64 = 0,
    horizon_clamps: u64 = 0,
    maximum_prediction_lead_ticks: u16 = 0,
    current_position_error_m: f32 = 0,
    maximum_position_error_m: f32 = 0,
    current_orientation_error_degrees: f32 = 0,
    maximum_orientation_error_degrees: f32 = 0,
    current_velocity_error_mps: f32 = 0,
    maximum_velocity_error_mps: f32 = 0,
    soft_corrections: u64 = 0,
    hard_corrections: u64 = 0,
    ownership_resets: u64 = 0,
    transport_resets: u64 = 0,
    correction_cooldown: u16 = 0,

    pub fn record(self: *Prediction, frame: protocol.VehicleInputFrame) void {
        if (!self.initialized or
            !std.meta.eql(frame.vehicle, self.predicted.entity) or
            self.predicted.driver == null or
            !std.meta.eql(frame.participant, self.predicted.driver.?)) return;

        if (self.history_count == self.history.len) {
            std.mem.copyForwards(Record, self.history[0 .. self.history.len - 1], self.history[1..]);
            self.history_count -= 1;
            self.history_overflows +|= 1;
        }
        self.history[self.history_count] = .{ .input = frame };
        self.history_count += 1;
        self.history_high_water = @max(self.history_high_water, self.history_count);

        self.decayCorrection();
        const lead = frame.target_tick -| self.authoritative_tick;
        self.maximum_prediction_lead_ticks = @max(
            self.maximum_prediction_lead_ticks,
            std.math.cast(u16, @min(lead, std.math.maxInt(u16))) orelse
                std.math.maxInt(u16),
        );
        if (lead > budgets.vehicle_prediction_horizon_ticks) {
            self.horizon_clamps +|= 1;
            return;
        }
        applyInput(&self.predicted, frame);
    }

    pub fn reconcile(
        self: *Prediction,
        authoritative: protocol.VehicleState,
        acknowledged: identity.InputSequence,
        server_tick: u64,
    ) void {
        if (!self.initialized or
            !std.meta.eql(self.predicted.entity, authoritative.entity) or
            self.predicted.driver == null or authoritative.driver == null or
            !std.meta.eql(self.predicted.driver.?, authoritative.driver.?))
        {
            self.initialize(authoritative, server_tick);
            return;
        }

        const old_predicted = self.predicted;
        const old_presentation = self.presentation();
        self.discardAcknowledged(acknowledged);
        self.predicted = authoritative;
        self.authoritative_tick = server_tick;
        for (self.history[0..self.history_count]) |item| {
            if (item.input.target_tick -| server_tick >
                budgets.vehicle_prediction_horizon_ticks) continue;
            applyInput(&self.predicted, item.input);
        }

        self.current_position_error_m = distance(
            old_predicted.position,
            self.predicted.position,
        );
        self.current_orientation_error_degrees = quaternionErrorDegrees(
            old_predicted.rotation,
            self.predicted.rotation,
        );
        self.current_velocity_error_mps = distance(
            old_predicted.linear_velocity,
            self.predicted.linear_velocity,
        );
        self.maximum_position_error_m = @max(
            self.maximum_position_error_m,
            self.current_position_error_m,
        );
        self.maximum_orientation_error_degrees = @max(
            self.maximum_orientation_error_degrees,
            self.current_orientation_error_degrees,
        );
        self.maximum_velocity_error_mps = @max(
            self.maximum_velocity_error_mps,
            self.current_velocity_error_mps,
        );

        const thresholds = budgets.vehicle_prediction_thresholds;
        if (self.current_position_error_m >= thresholds.hard_position_error_m or
            self.current_orientation_error_degrees >= thresholds.hard_orientation_error_degrees)
        {
            self.position_offset = .{ 0, 0, 0 };
            self.rotation_offset = identity_quaternion;
            self.hard_corrections +|= 1;
        } else if (self.current_position_error_m >= thresholds.soft_position_error_m or
            self.current_orientation_error_degrees >= thresholds.soft_orientation_error_degrees)
        {
            for (&self.position_offset, old_presentation.position, self.predicted.position) |
                *offset,
                old,
                corrected,
            | offset.* = old - corrected;
            self.rotation_offset = normalizedQuaternion(quaternionMultiply(
                old_presentation.rotation,
                quaternionConjugate(self.predicted.rotation),
            ));
            if (self.correction_cooldown == 0) {
                self.soft_corrections +|= 1;
                self.correction_cooldown = correction_episode_ticks;
            }
        } else {
            self.position_offset = .{ 0, 0, 0 };
            self.rotation_offset = identity_quaternion;
        }
    }

    pub fn presentation(self: *const Prediction) protocol.VehicleState {
        if (!self.initialized) return undefined;
        var result = self.predicted;
        for (&result.position, self.position_offset) |*position, offset| {
            position.* += offset;
        }
        result.rotation = normalizedQuaternion(quaternionMultiply(
            self.rotation_offset,
            result.rotation,
        ));
        return result;
    }

    pub fn clearOwnership(self: *Prediction) void {
        if (self.initialized) self.ownership_resets +|= 1;
        self.resetDisposableState();
    }

    pub fn transportDisconnected(self: *Prediction) void {
        if (self.initialized) self.transport_resets +|= 1;
        self.resetDisposableState();
    }

    pub fn diagnostics(self: *const Prediction) Diagnostics {
        return .{
            .initialized = self.initialized,
            .history_count = self.history_count,
            .history_high_water = self.history_high_water,
            .history_overflows = self.history_overflows,
            .horizon_clamps = self.horizon_clamps,
            .maximum_prediction_lead_ticks = self.maximum_prediction_lead_ticks,
            .current_position_error_m = self.current_position_error_m,
            .maximum_position_error_m = self.maximum_position_error_m,
            .current_orientation_error_degrees = self.current_orientation_error_degrees,
            .maximum_orientation_error_degrees = self.maximum_orientation_error_degrees,
            .current_velocity_error_mps = self.current_velocity_error_mps,
            .maximum_velocity_error_mps = self.maximum_velocity_error_mps,
            .correction_offset_m = length(self.position_offset),
            .soft_corrections = self.soft_corrections,
            .hard_corrections = self.hard_corrections,
            .ownership_resets = self.ownership_resets,
            .transport_resets = self.transport_resets,
        };
    }

    fn initialize(
        self: *Prediction,
        authoritative: protocol.VehicleState,
        server_tick: u64,
    ) void {
        self.predicted = authoritative;
        self.authoritative_tick = server_tick;
        self.position_offset = .{ 0, 0, 0 };
        self.rotation_offset = identity_quaternion;
        self.history_count = 0;
        self.current_position_error_m = 0;
        self.current_orientation_error_degrees = 0;
        self.current_velocity_error_mps = 0;
        self.correction_cooldown = 0;
        self.initialized = true;
    }

    fn resetDisposableState(self: *Prediction) void {
        self.initialized = false;
        self.history_count = 0;
        self.position_offset = .{ 0, 0, 0 };
        self.rotation_offset = identity_quaternion;
        self.current_position_error_m = 0;
        self.current_orientation_error_degrees = 0;
        self.current_velocity_error_mps = 0;
        self.correction_cooldown = 0;
    }

    fn discardAcknowledged(
        self: *Prediction,
        acknowledged: identity.InputSequence,
    ) void {
        var retained: usize = 0;
        for (self.history[0..self.history_count]) |item| {
            if (!item.input.sequence.newerThan(acknowledged)) continue;
            self.history[retained] = item;
            retained += 1;
        }
        self.history_count = @intCast(retained);
    }

    fn decayCorrection(self: *Prediction) void {
        self.correction_cooldown -|= 1;
        for (&self.position_offset) |*value| value.* *= correction_retention_per_tick;
        if (length(self.position_offset) < 0.001) self.position_offset = .{ 0, 0, 0 };
        self.rotation_offset = normalizedQuaternion(.{
            self.rotation_offset[0] * correction_retention_per_tick,
            self.rotation_offset[1] * correction_retention_per_tick,
            self.rotation_offset[2] * correction_retention_per_tick,
            1 + (self.rotation_offset[3] - 1) * correction_retention_per_tick,
        });
        if (quaternionErrorDegrees(self.rotation_offset, identity_quaternion) < 0.05) {
            self.rotation_offset = identity_quaternion;
        }
    }
};

fn applyInput(state: *protocol.VehicleState, frame: protocol.VehicleInputFrame) void {
    var forward = horizontalForward(state.rotation);
    var speed = state.linear_velocity[0] * forward[0] +
        state.linear_velocity[2] * forward[2];
    speed += frame.throttle * engine_acceleration_mps2 * fixed_delta_seconds;

    const passive = rolling_deceleration_mps2 +
        frame.brake * brake_deceleration_mps2 +
        frame.hand_brake * hand_brake_deceleration_mps2;
    speed = moveTowardZero(speed, passive * fixed_delta_seconds);
    speed = std.math.clamp(speed, -maximum_reverse_speed_mps, maximum_forward_speed_mps);

    const speed_factor = std.math.clamp(@abs(speed) / 8.0, 0, 1);
    const direction: f32 = if (speed < 0) -1 else 1;
    const yaw_rate = -frame.steering * maximum_yaw_rate_radians * speed_factor * direction;
    const yaw_delta = yaw_rate * fixed_delta_seconds;
    const half_yaw = yaw_delta * 0.5;
    state.rotation = normalizedQuaternion(quaternionMultiply(
        .{ 0, @sin(half_yaw), 0, @cos(half_yaw) },
        state.rotation,
    ));
    forward = horizontalForward(state.rotation);

    state.linear_velocity[0] = forward[0] * speed;
    state.linear_velocity[2] = forward[2] * speed;
    state.angular_velocity[1] = yaw_rate;
    state.position[0] += state.linear_velocity[0] * fixed_delta_seconds;
    state.position[2] += state.linear_velocity[2] * fixed_delta_seconds;
}

fn moveTowardZero(value: f32, amount: f32) f32 {
    if (value > amount) return value - amount;
    if (value < -amount) return value + amount;
    return 0;
}

const identity_quaternion = [4]f32{ 0, 0, 0, 1 };

fn horizontalForward(rotation: [4]f32) [3]f32 {
    const q = normalizedQuaternion(rotation);
    // Rotate local -Z by q, then remove pitch so this deliberately small
    // predictor never invents airborne or suspension authority.
    const forward = [3]f32{
        -2 * (q[0] * q[2] + q[3] * q[1]),
        0,
        -(1 - 2 * (q[0] * q[0] + q[1] * q[1])),
    };
    const horizontal_length = @sqrt(forward[0] * forward[0] + forward[2] * forward[2]);
    if (horizontal_length < 0.0001) return .{ 0, 0, -1 };
    return .{ forward[0] / horizontal_length, 0, forward[2] / horizontal_length };
}

fn quaternionMultiply(a: [4]f32, b: [4]f32) [4]f32 {
    return .{
        a[3] * b[0] + a[0] * b[3] + a[1] * b[2] - a[2] * b[1],
        a[3] * b[1] - a[0] * b[2] + a[1] * b[3] + a[2] * b[0],
        a[3] * b[2] + a[0] * b[1] - a[1] * b[0] + a[2] * b[3],
        a[3] * b[3] - a[0] * b[0] - a[1] * b[1] - a[2] * b[2],
    };
}

fn quaternionConjugate(value: [4]f32) [4]f32 {
    const normalized = normalizedQuaternion(value);
    return .{ -normalized[0], -normalized[1], -normalized[2], normalized[3] };
}

fn normalizedQuaternion(value: [4]f32) [4]f32 {
    const magnitude = @sqrt(value[0] * value[0] + value[1] * value[1] +
        value[2] * value[2] + value[3] * value[3]);
    if (magnitude < 0.000001 or !std.math.isFinite(magnitude)) return identity_quaternion;
    return .{
        value[0] / magnitude,
        value[1] / magnitude,
        value[2] / magnitude,
        value[3] / magnitude,
    };
}

fn quaternionErrorDegrees(a: [4]f32, b: [4]f32) f32 {
    const left = normalizedQuaternion(a);
    const right = normalizedQuaternion(b);
    const dot = @abs(left[0] * right[0] + left[1] * right[1] +
        left[2] * right[2] + left[3] * right[3]);
    return std.math.radiansToDegrees(2 * std.math.acos(std.math.clamp(dot, 0, 1)));
}

fn distance(a: [3]f32, b: [3]f32) f32 {
    return length(.{ a[0] - b[0], a[1] - b[1], a[2] - b[2] });
}

fn length(value: [3]f32) f32 {
    return @sqrt(value[0] * value[0] + value[1] * value[1] + value[2] * value[2]);
}

fn makeState() protocol.VehicleState {
    return .{
        .entity = .{ .index = 17, .generation = 1 },
        .position = .{ 0, 1, 0 },
        .rotation = identity_quaternion,
        .linear_velocity = .{ 0, 0, 0 },
        .angular_velocity = .{ 0, 0, 0 },
        .driver = .{ .index = 1, .generation = 1 },
    };
}

fn makeInput(sequence: u32, target_tick: u64) protocol.VehicleInputFrame {
    return .{
        .session = .{ .value = 1 },
        .participant = .{ .index = 1, .generation = 1 },
        .sequence = .{ .value = sequence },
        .target_tick = target_tick,
        .vehicle = .{ .index = 17, .generation = 1 },
        .throttle = 1,
        .steering = 0,
        .brake = 0,
        .hand_brake = 0,
    };
}

test "owned vehicle input changes presentation immediately" {
    var prediction = Prediction{};
    prediction.reconcile(makeState(), .{ .value = 0 }, 100);
    const before = prediction.presentation();
    prediction.record(makeInput(1, 101));
    const after = prediction.presentation();
    try std.testing.expect(after.position[2] < before.position[2]);
    try std.testing.expect(after.linear_velocity[2] < 0);
}

test "vehicle prediction discards acknowledged input and reapplies remainder" {
    var prediction = Prediction{};
    prediction.reconcile(makeState(), .{ .value = 0 }, 100);
    prediction.record(makeInput(1, 101));
    prediction.record(makeInput(2, 102));
    var authority = makeState();
    authority.position[2] = -0.002;
    prediction.reconcile(authority, .{ .value = 1 }, 101);
    try std.testing.expectEqual(@as(u16, 1), prediction.diagnostics().history_count);
    try std.testing.expect(prediction.predicted.position[2] < authority.position[2]);
}

test "prediction horizon clamps prolonged blackout motion" {
    var prediction = Prediction{};
    prediction.reconcile(makeState(), .{ .value = 0 }, 100);
    var sequence: u32 = 1;
    while (sequence <= budgets.vehicle_prediction_horizon_ticks + 8) : (sequence += 1) {
        prediction.record(makeInput(sequence, 100 + sequence));
    }
    const diagnostics = prediction.diagnostics();
    try std.testing.expectEqual(@as(u64, 8), diagnostics.horizon_clamps);
    try std.testing.expectEqual(
        @as(u16, budgets.vehicle_prediction_horizon_ticks + 8),
        diagnostics.maximum_prediction_lead_ticks,
    );
}

test "authoritative collision stop reconciles without a visible discontinuity" {
    var moving = makeState();
    moving.linear_velocity[2] = -12;
    var prediction = Prediction{};
    prediction.reconcile(moving, .{ .value = 0 }, 100);
    prediction.record(makeInput(1, 101));
    prediction.record(makeInput(2, 102));
    const before_collision = prediction.presentation();

    var stopped = moving;
    stopped.linear_velocity = .{ 0, 0, 0 };
    prediction.reconcile(stopped, .{ .value = 2 }, 102);
    const after_collision = prediction.presentation();
    try std.testing.expectEqual(@as(u64, 1), prediction.diagnostics().soft_corrections);
    try std.testing.expectEqual(@as(u64, 0), prediction.diagnostics().hard_corrections);
    try std.testing.expect(distance(before_collision.position, after_collision.position) < 0.001);

    var neutral = makeInput(3, 103);
    neutral.throttle = 0;
    for (0..20) |index| {
        neutral.sequence.value = @intCast(index + 3);
        neutral.target_tick = 103 + index;
        prediction.record(neutral);
    }
    try std.testing.expect(prediction.diagnostics().correction_offset_m < 0.01);
}

test "dynamic-impact hard correction and lifecycle loss discard disposable vehicle state" {
    var prediction = Prediction{};
    prediction.reconcile(makeState(), .{ .value = 0 }, 100);
    prediction.record(makeInput(1, 101));
    var far = makeState();
    far.position[0] = 8;
    prediction.reconcile(far, .{ .value = 1 }, 101);
    try std.testing.expectEqual(@as(u64, 1), prediction.diagnostics().hard_corrections);
    prediction.transportDisconnected();
    try std.testing.expect(!prediction.diagnostics().initialized);
    try std.testing.expectEqual(@as(u64, 1), prediction.diagnostics().transport_resets);

    prediction.reconcile(makeState(), .{ .value = 1 }, 102);
    prediction.clearOwnership();
    try std.testing.expectEqual(@as(u64, 1), prediction.diagnostics().ownership_resets);
}
