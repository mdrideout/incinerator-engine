//! Fixed host/editor producer mailbox for S7 interaction commands.
//!
//! The mailbox stores the exact authoritative semantic command. UI code never
//! receives a Simulation pointer and the host performs the only submission
//! after immutable editor borrows have ended.

const std = @import("std");
const interaction = @import("interaction_feature_contract");

pub const Request = interaction.Command;
pub const request_capacity: usize = 8;

pub const RequestBuffer = struct {
    items: [request_capacity]Request = undefined,
    len: u8 = 0,
    rejected: u64 = 0,

    pub fn push(self: *RequestBuffer, request: Request) bool {
        if (self.len == request_capacity) {
            self.rejected +|= 1;
            return false;
        }
        self.items[self.len] = request;
        self.len += 1;
        return true;
    }

    pub fn slice(self: *const RequestBuffer) []const Request {
        return self.items[0..self.len];
    }

    pub fn clear(self: *RequestBuffer) void {
        self.len = 0;
    }
};

/// Zero is reserved. One composition-owned source is shared by manual,
/// scripted, and editor producers so correlation IDs never alias.
pub const TransactionSequencer = struct {
    next_id: u64 = 1,

    pub fn take(self: *TransactionSequencer) !u64 {
        const result = self.next_id;
        if (result == 0) return error.InteractionTransactionIdExhausted;
        self.next_id +%= 1;
        return result;
    }

    pub fn peek(self: *const TransactionSequencer) ?u64 {
        return if (self.next_id == 0) null else self.next_id;
    }
};

test "interaction request mailbox is bounded and visibly rejects overflow" {
    var buffer = RequestBuffer{};
    const id = @FieldType(interaction.Collect, "carrier_id"){
        .namespace = 1,
        .local = 1,
    };
    for (0..request_capacity) |index| {
        try std.testing.expect(buffer.push(.{ .collect = .{
            .transaction_id = index + 1,
            .carrier_id = id,
            .carryable_id = id,
        } }));
    }
    try std.testing.expect(!buffer.push(.{ .drop = .{
        .transaction_id = 99,
        .carrier_id = id,
        .carryable_id = id,
        .purpose = .player_requested,
    } }));
    try std.testing.expectEqual(@as(u64, 1), buffer.rejected);
    try std.testing.expectEqual(request_capacity, buffer.slice().len);
    buffer.clear();
    try std.testing.expectEqual(@as(usize, 0), buffer.slice().len);
}

test "interaction transaction IDs are monotonic and fail closed" {
    var sequencer = TransactionSequencer{};
    try std.testing.expectEqual(@as(?u64, 1), sequencer.peek());
    try std.testing.expectEqual(@as(u64, 1), try sequencer.take());
    try std.testing.expectEqual(@as(u64, 2), try sequencer.take());
    sequencer.next_id = std.math.maxInt(u64);
    try std.testing.expectEqual(std.math.maxInt(u64), try sequencer.take());
    try std.testing.expectEqual(@as(?u64, null), sequencer.peek());
    try std.testing.expectError(
        error.InteractionTransactionIdExhausted,
        sequencer.take(),
    );
}
