//! Semantic delivery classes shared by hosts, authorities, and test adapters.
//! This is intentionally smaller than a transport interface: it prevents lane
//! policy drift without abstracting GameNetworkingSockets itself.

const std = @import("std");
const protocol = @import("session_protocol");

pub const Delivery = enum { unreliable, reliable };
pub const Lane = enum(u16) { input = 0, snapshot = 1, gameplay = 2, control = 3 };

pub const Class = struct {
    delivery: Delivery,
    lane: Lane,
};

pub fn clientClass(message: protocol.ClientMessage) Class {
    return switch (message) {
        .hello, .baseline_ack, .delivery_receipt, .disconnect => .{
            .delivery = .reliable,
            .lane = .control,
        },
        .input, .vehicle_input, .snapshot_ack => .{
            .delivery = .unreliable,
            .lane = .input,
        },
        .vehicle_action, .interaction_action, .melee_action, .respawn_action => .{
            .delivery = .reliable,
            .lane = .gameplay,
        },
    };
}

pub fn isClientInputSample(message: protocol.ClientMessage) bool {
    return switch (message) {
        .input, .vehicle_input => true,
        else => false,
    };
}

/// Transport adapters may receive a wall-clock backlog in one pump after the
/// authority was stalled. Leave excess GNS messages queued for the next
/// authority tick instead of turning ordinary catch-up into a quota violation.
/// The authority keeps its own quota as the untrusted-ingress safety boundary.
pub fn InputIngressBudget(
    comptime connection_capacity: usize,
    comptime max_inputs_per_tick: u16,
) type {
    if (connection_capacity == 0) @compileError("input ingress needs a connection slot");
    if (max_inputs_per_tick == 0) @compileError("input ingress budget must be nonzero");
    return struct {
        const Self = @This();

        tick: u64 = 0,
        initialized: bool = false,
        consumed: [connection_capacity]u16 = @splat(0),

        pub fn beginTick(self: *Self, tick: u64) void {
            if (self.initialized and self.tick == tick) return;
            self.tick = tick;
            self.initialized = true;
            self.consumed = @splat(0);
        }

        pub fn available(self: *const Self, connection_index: usize) bool {
            std.debug.assert(connection_index < connection_capacity);
            return self.consumed[connection_index] < max_inputs_per_tick;
        }

        pub fn consume(self: *Self, connection_index: usize) bool {
            if (!self.available(connection_index)) return false;
            self.consumed[connection_index] += 1;
            return true;
        }
    };
}

pub fn serverClass(message: protocol.ServerMessage) Class {
    return switch (message) {
        .snapshot => .{ .delivery = .unreliable, .lane = .snapshot },
        .vehicle_action_result,
        .interaction_action_result,
        .melee_action_result,
        .respawn_action_result,
        .life_event,
        => .{
            .delivery = .reliable,
            .lane = .gameplay,
        },
        .welcome, .relevance_baseline, .rejected, .disconnected => .{
            .delivery = .reliable,
            .lane = .control,
        },
    };
}

pub fn matches(expected: Class, delivery: Delivery, lane: Lane) bool {
    return expected.delivery == delivery and expected.lane == lane;
}

test "semantic message classes have one explicit policy" {
    try std.testing.expect(matches(
        clientClass(.{ .hello = .{ .account = .{ .value = 1 } } }),
        .reliable,
        .control,
    ));
    try std.testing.expect(matches(
        serverClass(.{ .snapshot = protocol.Snapshot.empty() }),
        .unreliable,
        .snapshot,
    ));
    try std.testing.expect(!matches(
        clientClass(.{ .input = .{
            .session = .{ .value = 1 },
            .participant = .{ .index = 1, .generation = 1 },
            .sequence = .{ .value = 1 },
            .target_tick = 1,
            .move = .{ 0, 0 },
            .facing_yaw = 0,
            .jump_pressed = false,
        } }),
        .reliable,
        .input,
    ));
}

test "transport input ingress defers a backlog until the next authority tick" {
    const limit: u16 = 8;
    var budget = InputIngressBudget(2, limit){};
    budget.beginTick(7);
    for (0..limit) |_| {
        try std.testing.expect(budget.consume(1));
    }
    try std.testing.expect(!budget.available(1));
    try std.testing.expect(!budget.consume(1));
    try std.testing.expect(budget.available(0));

    budget.beginTick(7);
    try std.testing.expect(!budget.available(1));
    budget.beginTick(8);
    try std.testing.expect(budget.available(1));
    try std.testing.expect(budget.consume(1));
}
