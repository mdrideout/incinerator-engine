//! Type-erased, authority-owned source of canonical durable snapshot bytes.
//!
//! The source is handed to the persistence owner at composition time. Runtime
//! graphical code receives only typed observations and commit feedback.

const std = @import("std");

pub const Source = struct {
    context: *anyopaque,
    capture_fn: *const fn (*anyopaque, std.mem.Allocator) anyerror![]u8,

    pub fn capture(self: Source, allocator: std.mem.Allocator) anyerror![]u8 {
        return self.capture_fn(self.context, allocator);
    }
};

test "source transfers capture through an opaque authority context" {
    const Fixture = struct {
        value: []const u8,

        fn capture(context: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            return allocator.dupe(u8, self.value);
        }
    };
    var fixture = Fixture{ .value = "canonical" };
    const source = Source{ .context = &fixture, .capture_fn = Fixture.capture };
    const bytes = try source.capture(std.testing.allocator);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("canonical", bytes);
}
