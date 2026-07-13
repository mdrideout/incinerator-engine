//! Allocation-free fixed-tick scheduling for the server-shaped host.
//!
//! Real time is converted to a rational 120 Hz due-tick count. Ticks are never
//! skipped: bounded catch-up grants work, soft lag sheds new external ingress,
//! and hard lag requests an orderly stop. Virtual time grants the same bounded
//! batches until its exact configured target is complete.

const std = @import("std");

pub const tick_rate: u64 = 120;
pub const nanoseconds_per_second: u64 = std.time.ns_per_s;

pub const Policy = struct {
    max_catch_up_ticks: u16,
    soft_lag_ticks: u16,
    hard_lag_ticks: u16,

    pub fn validate(self: Policy) !void {
        if (self.max_catch_up_ticks == 0 or self.soft_lag_ticks == 0 or
            self.hard_lag_ticks == 0 or
            self.max_catch_up_ticks > self.soft_lag_ticks or
            self.soft_lag_ticks > self.hard_lag_ticks)
        {
            return error.InvalidHeadlessClockPolicy;
        }
    }
};

pub const Mode = union(enum) {
    real_time: struct { start_ns: u64 },
    virtual: struct { target_ticks: u64 },
};

pub const Decision = struct {
    granted_ticks: u16,
    lag_ticks: u64,
    shed_ingress: bool,
    hard_lag: bool,
    complete: bool,
};

pub const Scheduler = struct {
    mode: Mode,
    policy: Policy,
    completed_ticks: u64 = 0,
    last_now_ns: u64 = 0,

    pub fn init(mode: Mode, policy: Policy) !Scheduler {
        try policy.validate();
        return .{
            .mode = mode,
            .policy = policy,
            .last_now_ns = switch (mode) {
                .real_time => |value| value.start_ns,
                .virtual => 0,
            },
        };
    }

    pub fn sample(self: *Scheduler, now_ns: u64) !Decision {
        return switch (self.mode) {
            .virtual => |value| self.sampleVirtual(value.target_ticks),
            .real_time => |value| self.sampleReal(value.start_ns, now_ns),
        };
    }

    pub fn recordCompletedTick(self: *Scheduler) !void {
        self.completed_ticks = std.math.add(u64, self.completed_ticks, 1) catch
            return error.HeadlessTickCounterExhausted;
        switch (self.mode) {
            .virtual => |value| if (self.completed_ticks > value.target_ticks) {
                return error.HeadlessVirtualTickTargetExceeded;
            },
            .real_time => {},
        }
    }

    fn sampleVirtual(self: *const Scheduler, target_ticks: u64) Decision {
        const remaining = target_ticks - self.completed_ticks;
        if (remaining == 0) return .{
            .granted_ticks = 0,
            .lag_ticks = 0,
            .shed_ingress = false,
            .hard_lag = false,
            .complete = true,
        };
        return .{
            .granted_ticks = @intCast(@min(
                remaining,
                @as(u64, self.policy.max_catch_up_ticks),
            )),
            .lag_ticks = remaining,
            .shed_ingress = false,
            .hard_lag = false,
            .complete = false,
        };
    }

    fn sampleReal(
        self: *Scheduler,
        start_ns: u64,
        now_ns: u64,
    ) !Decision {
        if (now_ns < self.last_now_ns or now_ns < start_ns) {
            return error.HeadlessClockMovedBackwards;
        }
        self.last_now_ns = now_ns;
        const elapsed = now_ns - start_ns;
        const due_u128 = (@as(u128, elapsed) * tick_rate) / nanoseconds_per_second;
        const due = std.math.cast(u64, due_u128) orelse
            return error.HeadlessClockRangeExceeded;
        const lag = due -| self.completed_ticks;
        const hard_lag = lag >= self.policy.hard_lag_ticks;
        return .{
            .granted_ticks = if (hard_lag) 0 else @intCast(@min(
                lag,
                @as(u64, self.policy.max_catch_up_ticks),
            )),
            .lag_ticks = lag,
            .shed_ingress = lag >= self.policy.soft_lag_ticks,
            .hard_lag = hard_lag,
            .complete = false,
        };
    }
};

test "virtual time grants bounded batches and completes at the exact target" {
    var scheduler = try Scheduler.init(
        .{ .virtual = .{ .target_ticks = 10 } },
        .{ .max_catch_up_ticks = 8, .soft_lag_ticks = 8, .hard_lag_ticks = 120 },
    );
    var decision = try scheduler.sample(0);
    try std.testing.expectEqual(@as(u16, 8), decision.granted_ticks);
    for (0..decision.granted_ticks) |_| try scheduler.recordCompletedTick();
    decision = try scheduler.sample(0);
    try std.testing.expectEqual(@as(u16, 2), decision.granted_ticks);
    for (0..decision.granted_ticks) |_| try scheduler.recordCompletedTick();
    decision = try scheduler.sample(0);
    try std.testing.expect(decision.complete);
    try std.testing.expectEqual(@as(u64, 10), scheduler.completed_ticks);
}

test "real time never skips ticks and escalates soft then hard lag" {
    var scheduler = try Scheduler.init(
        .{ .real_time = .{ .start_ns = 1_000 } },
        .{ .max_catch_up_ticks = 8, .soft_lag_ticks = 8, .hard_lag_ticks = 120 },
    );
    var decision = try scheduler.sample(100_001_000);
    try std.testing.expectEqual(@as(u64, 12), decision.lag_ticks);
    try std.testing.expectEqual(@as(u16, 8), decision.granted_ticks);
    try std.testing.expect(decision.shed_ingress);
    try std.testing.expect(!decision.hard_lag);
    for (0..decision.granted_ticks) |_| try scheduler.recordCompletedTick();

    decision = try scheduler.sample(100_001_000);
    try std.testing.expectEqual(@as(u64, 4), decision.lag_ticks);
    try std.testing.expectEqual(@as(u16, 4), decision.granted_ticks);
    try std.testing.expect(!decision.shed_ingress);
    // No completed-tick mutation occurred merely by sampling twice.
    try std.testing.expectEqual(@as(u64, 8), scheduler.completed_ticks);

    decision = try scheduler.sample(2_000_001_000);
    try std.testing.expect(decision.hard_lag);
    try std.testing.expect(decision.shed_ingress);
    try std.testing.expectEqual(@as(u16, 0), decision.granted_ticks);
    try std.testing.expectEqual(@as(u64, 232), decision.lag_ticks);
}

test "backwards clocks and invalid policies fail structurally" {
    try std.testing.expectError(
        error.InvalidHeadlessClockPolicy,
        Scheduler.init(
            .{ .virtual = .{ .target_ticks = 1 } },
            .{ .max_catch_up_ticks = 9, .soft_lag_ticks = 8, .hard_lag_ticks = 120 },
        ),
    );
    var scheduler = try Scheduler.init(
        .{ .real_time = .{ .start_ns = 10 } },
        .{ .max_catch_up_ticks = 1, .soft_lag_ticks = 1, .hard_lag_ticks = 2 },
    );
    _ = try scheduler.sample(20);
    try std.testing.expectError(error.HeadlessClockMovedBackwards, scheduler.sample(19));
}
