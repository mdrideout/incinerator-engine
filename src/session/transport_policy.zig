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
