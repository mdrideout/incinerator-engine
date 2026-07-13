//! Minimal macOS SIGINT/SIGTERM adapter for graceful host shutdown.
//!
//! The signal handler performs one lock-free atomic store and nothing else.
//! Allocation, logging, I/O, world access, and cleanup remain on the owning
//! host thread after it observes the flag.

const std = @import("std");
const builtin = @import("builtin");

var stop_requested = std.atomic.Value(u8).init(0);
var install_claimed = std.atomic.Value(u8).init(0);

pub const Guard = struct {
    old_term: std.posix.Sigaction,
    old_int: std.posix.Sigaction,
    live: bool = true,

    pub fn install() !Guard {
        if (builtin.os.tag != .macos) return error.UnsupportedPlatform;
        if (install_claimed.cmpxchgStrong(0, 1, .acq_rel, .acquire) != null) {
            return error.SignalHandlerAlreadyInstalled;
        }
        errdefer install_claimed.store(0, .release);
        stop_requested.store(0, .release);

        const action = std.posix.Sigaction{
            .handler = .{ .handler = signalHandler },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        var old_term: std.posix.Sigaction = undefined;
        var old_int: std.posix.Sigaction = undefined;
        std.posix.sigaction(.TERM, &action, &old_term);
        std.posix.sigaction(.INT, &action, &old_int);
        return .{ .old_term = old_term, .old_int = old_int };
    }

    pub fn deinit(self: *Guard) void {
        if (!self.live) return;
        std.posix.sigaction(.TERM, &self.old_term, null);
        std.posix.sigaction(.INT, &self.old_int, null);
        stop_requested.store(0, .release);
        install_claimed.store(0, .release);
        self.live = false;
    }
};

pub fn requested() bool {
    return stop_requested.load(.acquire) != 0;
}

fn signalHandler(_: std.posix.SIG) callconv(.c) void {
    stop_requested.store(1, .release);
}

fn requestForTest() void {
    signalHandler(.TERM);
}

test "handler publishes only a stop flag and guard restores ownership" {
    var guard = try Guard.install();
    try std.testing.expect(!requested());
    requestForTest();
    try std.testing.expect(requested());
    try std.testing.expectError(error.SignalHandlerAlreadyInstalled, Guard.install());
    guard.deinit();
    try std.testing.expect(!requested());

    var second = try Guard.install();
    defer second.deinit();
    try std.testing.expect(!requested());
}
