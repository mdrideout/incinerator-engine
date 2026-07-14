//! Client estimate of authority time anchored only by admitted server samples.

const std = @import("std");
const budgets = @import("session_budgets");

pub const Clock = struct {
    anchored: bool = false,
    authority_tick: u64 = 0,
    local_ns: u64 = 0,
    latest_observed_tick: u64 = 0,

    pub fn synchronize(self: *Clock, authority_tick: u64, local_ns: u64) void {
        self.anchored = true;
        self.authority_tick = authority_tick;
        self.latest_observed_tick = authority_tick;
        self.local_ns = local_ns;
    }

    pub fn observe(self: *Clock, authority_tick: u64) void {
        if (!self.anchored) return;
        self.latest_observed_tick = @max(self.latest_observed_tick, authority_tick);
    }

    pub fn estimate(self: *const Clock, local_ns: u64) u64 {
        if (!self.anchored) return 0;
        const elapsed = local_ns -| self.local_ns;
        const advanced: u64 = @intCast(
            (@as(u128, elapsed) * budgets.authority_tick_hz) / std.time.ns_per_s,
        );
        return @max(self.authority_tick +| advanced, self.latest_observed_tick);
    }

    pub fn inputTick(self: *const Clock, local_ns: u64) u64 {
        return self.estimate(local_ns) +| 1;
    }

    pub fn snapshotAgeTicks(
        self: *const Clock,
        snapshot_tick: u64,
        local_ns: u64,
    ) u64 {
        return self.estimate(local_ns) -| snapshot_tick;
    }

    pub fn reset(self: *Clock) void {
        self.* = .{};
    }
};

test "welcome reanchors time and disconnected wall time cannot catch up" {
    var clock = Clock{};
    clock.synchronize(100, 1 * std.time.ns_per_s);
    try std.testing.expectEqual(
        @as(u64, 161),
        clock.inputTick(2 * std.time.ns_per_s),
    );
    clock.synchronize(7, 10 * std.time.ns_per_s);
    try std.testing.expectEqual(@as(u64, 8), clock.inputTick(10 * std.time.ns_per_s));
}
