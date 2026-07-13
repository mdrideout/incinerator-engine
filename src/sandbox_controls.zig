//! Sandbox-owned bridge from render-frame input to fixed-tick actions.
//!
//! Held movement is sampled once per frame and repeated for every fixed tick.
//! Edges and deltas remain latched across zero-tick frames and are consumed by
//! exactly one tick when a slow frame produces multiple simulation steps.

const std = @import("std");

pub const FrameSample = struct {
    move: [2]f32 = .{ 0, 0 },
    look_delta: [2]f32 = .{ 0, 0 },
    jump_pressed: bool = false,
    interact_pressed: bool = false,
    brake: bool = false,
    hand_brake: bool = false,
    reset: bool = false,
};

pub const TickSample = struct {
    move: [2]f32,
    look_delta: [2]f32,
    jump_pressed: bool,
    interact_pressed: bool,
    brake: bool,
    hand_brake: bool,
};

pub const ActionLatch = struct {
    held_move: [2]f32 = .{ 0, 0 },
    pending_look: [2]f32 = .{ 0, 0 },
    pending_jump: bool = false,
    pending_interact: bool = false,
    held_brake: bool = false,
    held_hand_brake: bool = false,

    pub fn captureFrame(self: *ActionLatch, sample: FrameSample) !void {
        try validateFinite(sample.move);
        try validateFinite(sample.look_delta);
        if (sample.reset) {
            self.clear();
            return;
        }
        self.held_move = sample.move;
        self.pending_look[0] += sample.look_delta[0];
        self.pending_look[1] += sample.look_delta[1];
        if (!std.math.isFinite(self.pending_look[0]) or
            !std.math.isFinite(self.pending_look[1]))
        {
            self.clear();
            return error.LookDeltaOverflow;
        }
        self.pending_jump = self.pending_jump or sample.jump_pressed;
        self.pending_interact = self.pending_interact or sample.interact_pressed;
        self.held_brake = sample.brake;
        self.held_hand_brake = sample.hand_brake;
    }

    pub fn takeTick(self: *ActionLatch) TickSample {
        const result = TickSample{
            .move = self.held_move,
            .look_delta = self.pending_look,
            .jump_pressed = self.pending_jump,
            .interact_pressed = self.pending_interact,
            .brake = self.held_brake,
            .hand_brake = self.held_hand_brake,
        };
        self.pending_look = .{ 0, 0 };
        self.pending_jump = false;
        self.pending_interact = false;
        return result;
    }

    pub fn clear(self: *ActionLatch) void {
        self.* = .{};
    }
};

fn validateFinite(values: anytype) !void {
    for (values) |value| {
        if (!std.math.isFinite(value)) return error.NonFiniteActionSample;
    }
}

test "zero-tick frames retain edges and deltas" {
    var latch = ActionLatch{};
    try latch.captureFrame(.{
        .move = .{ 1, 0 },
        .look_delta = .{ 3, -2 },
        .jump_pressed = true,
        .interact_pressed = true,
        .brake = true,
        .hand_brake = true,
    });
    // No call to takeTick: the next frame must accumulate rather than clear.
    try latch.captureFrame(.{
        .move = .{ 0, 1 },
        .look_delta = .{ 4, 1 },
    });
    const tick = latch.takeTick();
    try std.testing.expectEqual([2]f32{ 0, 1 }, tick.move);
    try std.testing.expectEqual([2]f32{ 7, -1 }, tick.look_delta);
    try std.testing.expect(tick.jump_pressed);
    try std.testing.expect(tick.interact_pressed);
    try std.testing.expect(!tick.brake);
    try std.testing.expect(!tick.hand_brake);
}

test "multi-tick frames consume edges once while movement remains held" {
    var latch = ActionLatch{};
    try latch.captureFrame(.{
        .move = .{ -1, 1 },
        .look_delta = .{ 2, 5 },
        .jump_pressed = true,
        .interact_pressed = true,
        .brake = true,
        .hand_brake = true,
    });
    const first = latch.takeTick();
    const second = latch.takeTick();
    try std.testing.expectEqual(first.move, second.move);
    try std.testing.expectEqual([2]f32{ 2, 5 }, first.look_delta);
    try std.testing.expect(first.jump_pressed);
    try std.testing.expect(first.interact_pressed);
    try std.testing.expect(first.brake);
    try std.testing.expect(first.hand_brake);
    try std.testing.expectEqual([2]f32{ 0, 0 }, second.look_delta);
    try std.testing.expect(!second.jump_pressed);
    try std.testing.expect(!second.interact_pressed);
    try std.testing.expect(second.brake);
    try std.testing.expect(second.hand_brake);
}

test "capture or focus reset discards pending gameplay actions" {
    var latch = ActionLatch{};
    try latch.captureFrame(.{
        .move = .{ 1, 0 },
        .look_delta = .{ 2, 3 },
        .jump_pressed = true,
        .interact_pressed = true,
        .brake = true,
        .hand_brake = true,
    });
    try latch.captureFrame(.{ .reset = true });
    const tick = latch.takeTick();
    try std.testing.expectEqual([2]f32{ 0, 0 }, tick.move);
    try std.testing.expectEqual([2]f32{ 0, 0 }, tick.look_delta);
    try std.testing.expect(!tick.jump_pressed);
    try std.testing.expect(!tick.interact_pressed);
    try std.testing.expect(!tick.brake);
    try std.testing.expect(!tick.hand_brake);
}
