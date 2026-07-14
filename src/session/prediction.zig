//! Bounded local on-foot prediction. This is a disposable horizontal motor,
//! not a second simulation world or a deterministic Jolt replica.

const std = @import("std");
const budgets = @import("session_budgets");
const identity = @import("session_identity");
const protocol = @import("session_protocol");

const move_speed_mps: f32 = 6.0;
const fixed_delta_seconds: f32 = 1.0 /
    @as(f32, @floatFromInt(budgets.authority_tick_hz));
const smoothing_retention_per_tick: f32 = 0.75;
const correction_episode_ticks: u16 = budgets.authority_tick_hz / 2;

const Record = struct {
    input: protocol.InputFrame,
};

pub const Diagnostics = struct {
    initialized: bool,
    history_count: u16,
    history_high_water: u16,
    history_overflows: u64,
    current_error_m: f32,
    maximum_error_m: f32,
    soft_corrections: u64,
    hard_corrections: u64,
    ownership_resets: u64,
};

pub const Prediction = struct {
    initialized: bool = false,
    predicted: protocol.CharacterState = undefined,
    correction_offset: [3]f32 = .{ 0, 0, 0 },
    history: [budgets.input_history_ticks]Record = undefined,
    history_count: u16 = 0,
    history_high_water: u16 = 0,
    history_overflows: u64 = 0,
    current_error_m: f32 = 0,
    maximum_error_m: f32 = 0,
    soft_corrections: u64 = 0,
    hard_corrections: u64 = 0,
    ownership_resets: u64 = 0,
    correction_cooldown: u16 = 0,

    pub fn record(self: *Prediction, frame: protocol.InputFrame) void {
        if (!self.initialized or !std.meta.eql(frame.participant, self.predicted.owner)) return;
        if (self.history_count == self.history.len) {
            std.mem.copyForwards(Record, self.history[0 .. self.history.len - 1], self.history[1..]);
            self.history_count -= 1;
            self.history_overflows +|= 1;
        }
        self.history[self.history_count] = .{ .input = frame };
        self.history_count += 1;
        self.history_high_water = @max(self.history_high_water, self.history_count);
        applyInput(&self.predicted, frame);
        self.correction_cooldown -|= 1;
        for (&self.correction_offset) |*value| value.* *= smoothing_retention_per_tick;
        if (length(self.correction_offset) < 0.001) self.correction_offset = .{ 0, 0, 0 };
    }

    pub fn reconcile(
        self: *Prediction,
        authoritative: protocol.CharacterState,
        acknowledged: identity.InputSequence,
    ) void {
        if (!self.initialized or
            !std.meta.eql(self.predicted.entity, authoritative.entity) or
            !std.meta.eql(self.predicted.owner, authoritative.owner))
        {
            self.predicted = authoritative;
            self.correction_offset = .{ 0, 0, 0 };
            self.history_count = 0;
            self.current_error_m = 0;
            self.initialized = true;
            return;
        }

        const old_predicted = self.predicted;
        const old_presentation = self.presentation();
        self.discardAcknowledged(acknowledged);
        self.predicted = authoritative;
        for (self.history[0..self.history_count]) |item| {
            applyInput(&self.predicted, item.input);
        }
        // Count authoritative divergence in the raw predicted state. The
        // smoothing offset is presentation-only and must not recursively
        // manufacture another correction on every later snapshot.
        self.current_error_m = distance(old_predicted.position, self.predicted.position);
        self.maximum_error_m = @max(self.maximum_error_m, self.current_error_m);
        if (self.current_error_m >= budgets.prediction_thresholds.hard_position_error_m) {
            self.correction_offset = .{ 0, 0, 0 };
            self.hard_corrections +|= 1;
        } else if (self.current_error_m >= budgets.prediction_thresholds.soft_position_error_m) {
            for (&self.correction_offset, old_presentation.position, self.predicted.position) |
                *offset,
                old,
                corrected,
            | offset.* = old - corrected;
            // Multiple authoritative samples may update one visible smoothing
            // episode. Count the episode, not every snapshot inside it.
            if (self.correction_cooldown == 0) {
                self.soft_corrections +|= 1;
                self.correction_cooldown = correction_episode_ticks;
            }
        } else {
            self.correction_offset = .{ 0, 0, 0 };
        }
    }

    pub fn presentation(self: *const Prediction) protocol.CharacterState {
        if (!self.initialized) return undefined;
        var result = self.predicted;
        for (&result.position, self.correction_offset) |*position, offset| {
            position.* += offset;
        }
        return result;
    }

    pub fn clearOwnership(self: *Prediction) void {
        if (self.initialized) self.ownership_resets +|= 1;
        self.initialized = false;
        self.history_count = 0;
        self.correction_offset = .{ 0, 0, 0 };
        self.current_error_m = 0;
        self.correction_cooldown = 0;
    }

    pub fn transportDisconnected(self: *Prediction) void {
        self.history_count = 0;
        self.correction_offset = .{ 0, 0, 0 };
    }

    pub fn diagnostics(self: *const Prediction) Diagnostics {
        return .{
            .initialized = self.initialized,
            .history_count = self.history_count,
            .history_high_water = self.history_high_water,
            .history_overflows = self.history_overflows,
            .current_error_m = self.current_error_m,
            .maximum_error_m = self.maximum_error_m,
            .soft_corrections = self.soft_corrections,
            .hard_corrections = self.hard_corrections,
            .ownership_resets = self.ownership_resets,
        };
    }

    fn discardAcknowledged(self: *Prediction, acknowledged: identity.InputSequence) void {
        var retained: usize = 0;
        for (self.history[0..self.history_count]) |item| {
            if (!item.input.sequence.newerThan(acknowledged)) continue;
            self.history[retained] = item;
            retained += 1;
        }
        self.history_count = @intCast(retained);
    }
};

fn applyInput(predicted_state: *protocol.CharacterState, frame: protocol.InputFrame) void {
    const sin_yaw = @sin(frame.facing_yaw);
    const cos_yaw = @cos(frame.facing_yaw);
    const velocity_x = (frame.move[0] * cos_yaw + frame.move[1] * sin_yaw) * move_speed_mps;
    const velocity_z = (frame.move[0] * sin_yaw - frame.move[1] * cos_yaw) * move_speed_mps;
    predicted_state.position[0] += velocity_x * fixed_delta_seconds;
    predicted_state.position[2] += velocity_z * fixed_delta_seconds;
    predicted_state.velocity[0] = velocity_x;
    predicted_state.velocity[2] = velocity_z;
    predicted_state.facing_yaw = frame.facing_yaw;
}

fn distance(a: [3]f32, b: [3]f32) f32 {
    return length(.{ a[0] - b[0], a[1] - b[1], a[2] - b[2] });
}

fn length(value: [3]f32) f32 {
    return @sqrt(value[0] * value[0] + value[1] * value[1] + value[2] * value[2]);
}

fn makeState() protocol.CharacterState {
    return .{
        .entity = .{ .index = 1, .generation = 1 },
        .owner = .{ .index = 1, .generation = 1 },
        .position = .{ 0, 0, 0 },
        .velocity = .{ 0, 0, 0 },
        .facing_yaw = 0,
    };
}

fn makeInput(sequence: u32) protocol.InputFrame {
    return .{
        .session = .{ .value = 1 },
        .participant = .{ .index = 1, .generation = 1 },
        .sequence = .{ .value = sequence },
        .target_tick = sequence,
        .move = .{ 1, 0 },
        .facing_yaw = 0,
        .jump_pressed = false,
    };
}

test "prediction discards acknowledged input and reapplies the remainder" {
    var prediction = Prediction{};
    prediction.reconcile(makeState(), .{ .value = 0 });
    prediction.record(makeInput(1));
    prediction.record(makeInput(2));
    var authority = makeState();
    authority.position[0] = 0.1;
    prediction.reconcile(authority, .{ .value = 1 });
    try std.testing.expectEqual(@as(u16, 1), prediction.diagnostics().history_count);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), prediction.predicted.position[0], 0.0001);
}

test "hard correction snaps and ownership loss clears disposable state" {
    var prediction = Prediction{};
    prediction.reconcile(makeState(), .{ .value = 0 });
    prediction.record(makeInput(1));
    var far = makeState();
    far.position[0] = 4;
    prediction.reconcile(far, .{ .value = 1 });
    try std.testing.expectEqual(@as(u64, 1), prediction.diagnostics().hard_corrections);
    prediction.clearOwnership();
    try std.testing.expect(!prediction.diagnostics().initialized);
    try std.testing.expectEqual(@as(u64, 1), prediction.diagnostics().ownership_resets);
}
