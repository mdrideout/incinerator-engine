//! Small fixed-capacity FIFO primitive for feature-owned queues.
//!
//! This type owns only ring-buffer mechanics. Features retain their own
//! admission errors, reservations, rejection counters, and diagnostics.

const std = @import("std");

pub fn BoundedQueue(comptime T: type, comptime capacity: usize) type {
    if (capacity == 0) @compileError("bounded queue capacity must be nonzero");

    return struct {
        const Self = @This();

        storage: [capacity]T = undefined,
        head: usize = 0,
        len: usize = 0,

        pub fn push(self: *Self, value: T) error{QueueFull}!void {
            if (self.isFull()) return error.QueueFull;
            self.pushAssumeCapacity(value);
        }

        pub fn pushAssumeCapacity(self: *Self, value: T) void {
            std.debug.assert(!self.isFull());
            self.storage[(self.head + self.len) % capacity] = value;
            self.len += 1;
        }

        pub fn pop(self: *Self) ?T {
            if (self.isEmpty()) return null;
            const value = self.storage[self.head];
            self.head = (self.head + 1) % capacity;
            self.len -= 1;
            if (self.len == 0) self.head = 0;
            return value;
        }

        pub fn peek(self: *const Self) ?T {
            return self.at(0);
        }

        pub fn at(self: *const Self, index: usize) ?T {
            if (index >= self.len) return null;
            return self.storage[(self.head + index) % capacity];
        }

        pub fn atAssumeValid(self: *const Self, index: usize) T {
            return self.at(index) orelse unreachable;
        }

        pub fn clear(self: *Self) void {
            self.head = 0;
            self.len = 0;
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.len == 0;
        }

        pub fn isFull(self: *const Self) bool {
            return self.len == capacity;
        }
    };
}

test "bounded queue preserves FIFO order across wraparound" {
    var queue = BoundedQueue(u8, 3){};
    try queue.push(1);
    try queue.push(2);
    try std.testing.expectEqual(@as(?u8, 1), queue.pop());
    try queue.push(3);
    try queue.push(4);
    try std.testing.expectError(error.QueueFull, queue.push(5));
    try std.testing.expectEqual(@as(?u8, 2), queue.at(0));
    try std.testing.expectEqual(@as(?u8, 4), queue.at(2));
    try std.testing.expectEqual(@as(?u8, 2), queue.pop());
    try std.testing.expectEqual(@as(?u8, 3), queue.pop());
    try std.testing.expectEqual(@as(?u8, 4), queue.pop());
    try std.testing.expect(queue.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), queue.head);
}
