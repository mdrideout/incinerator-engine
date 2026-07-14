//! Monotonic reconnect scheduling independent of render cadence.

const std = @import("std");

pub const base_delay_ns: u64 = 250 * std.time.ns_per_ms;
pub const maximum_delay_ns: u64 = 8 * std.time.ns_per_s;
pub const maximum_attempts: u8 = 10;

pub const Diagnostics = struct {
    attempts: u8,
    scheduled: bool,
    exhausted: bool,
    next_attempt_ns: u64,
    last_delay_ns: u64,
};

pub const Policy = struct {
    jitter_key: u64,
    attempts: u8 = 0,
    next_attempt_ns: u64 = 0,
    last_delay_ns: u64 = 0,
    scheduled: bool = false,
    exhausted: bool = false,

    pub fn init(jitter_key: u64) Policy {
        return .{ .jitter_key = jitter_key };
    }

    pub fn schedule(self: *Policy, now_ns: u64) ?u64 {
        if (self.exhausted) return null;
        if (self.attempts >= maximum_attempts) {
            self.scheduled = false;
            self.exhausted = true;
            return null;
        }
        const shift: u6 = @intCast(@min(self.attempts, 5));
        const exponential = base_delay_ns << shift;
        const capped = @min(exponential, maximum_delay_ns);
        const hash = std.hash.Wyhash.hash(
            self.jitter_key ^ @as(u64, self.attempts),
            std.mem.asBytes(&self.jitter_key),
        );
        // Deterministic 80%-120% jitter avoids synchronized retries while
        // keeping lifecycle tests exactly reproducible.
        const percent = 80 + hash % 41;
        const delay = @min(maximum_delay_ns, (capped * percent) / 100);
        self.attempts += 1;
        self.last_delay_ns = delay;
        self.next_attempt_ns = now_ns +| delay;
        self.scheduled = true;
        return delay;
    }

    pub fn due(self: *const Policy, now_ns: u64) bool {
        return self.scheduled and !self.exhausted and now_ns >= self.next_attempt_ns;
    }

    pub fn consume(self: *Policy) void {
        self.scheduled = false;
    }

    pub fn reset(self: *Policy) void {
        self.attempts = 0;
        self.next_attempt_ns = 0;
        self.last_delay_ns = 0;
        self.scheduled = false;
        self.exhausted = false;
    }

    pub fn diagnostics(self: *const Policy) Diagnostics {
        return .{
            .attempts = self.attempts,
            .scheduled = self.scheduled,
            .exhausted = self.exhausted,
            .next_attempt_ns = self.next_attempt_ns,
            .last_delay_ns = self.last_delay_ns,
        };
    }
};

test "retry delays are deterministic monotonic and capped" {
    var first = Policy.init(42);
    var second = Policy.init(42);
    var now: u64 = 100;
    for (0..maximum_attempts) |_| {
        const a = first.schedule(now).?;
        const b = second.schedule(now).?;
        try std.testing.expectEqual(a, b);
        try std.testing.expect(a <= maximum_delay_ns);
        try std.testing.expect(first.due(now + a));
        first.consume();
        second.consume();
        now +|= a;
    }
    try std.testing.expect(first.schedule(now) == null);
    try std.testing.expect(first.diagnostics().exhausted);
}

test "successful welcome resets retry history" {
    var policy = Policy.init(7);
    _ = policy.schedule(10);
    policy.reset();
    try std.testing.expectEqual(@as(u8, 0), policy.diagnostics().attempts);
    try std.testing.expect(!policy.diagnostics().scheduled);
}
