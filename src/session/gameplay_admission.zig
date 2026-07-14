//! Shared semantic admission policy for embedded and dedicated authorities.
//!
//! Placement-specific session orchestrators still own connection lifecycle,
//! routing, and rejection transport. This module owns the rules that must not
//! drift between those orchestrators: identity matching, bounded input
//! freshness, per-tick input quotas, and monotonic gameplay action sequences.

const std = @import("std");
const budgets = @import("session_budgets");
const identity = @import("session_identity");

pub const InputDecision = enum {
    accepted,
    stale_sequence,
    outside_tick_window,
};

pub fn identitiesMatch(
    expected_session: identity.SessionId,
    expected_participant: identity.ParticipantId,
    actual_session: identity.SessionId,
    actual_participant: identity.ParticipantId,
) bool {
    return std.meta.eql(expected_session, actual_session) and
        std.meta.eql(expected_participant, actual_participant);
}

pub fn classifyInput(
    last_sequence: identity.InputSequence,
    authority_tick: u64,
    sequence: identity.InputSequence,
    target_tick: u64,
) InputDecision {
    if (!sequence.newerThan(last_sequence)) return .stale_sequence;

    const oldest_tick = authority_tick -| budgets.input_history_ticks;
    const newest_tick = authority_tick +| budgets.max_future_input_ticks;
    if (target_tick < oldest_tick or target_tick > newest_tick) {
        return .outside_tick_window;
    }
    return .accepted;
}

/// Consumes one message from a quota counter shared by all input kinds on a
/// connection. Returns false without incrementing when the quota is exhausted.
pub fn consumeInputQuota(
    authority_tick: u64,
    quota_tick: *u64,
    messages_this_tick: *u16,
) bool {
    if (quota_tick.* != authority_tick) {
        quota_tick.* = authority_tick;
        messages_this_tick.* = 0;
    }
    if (messages_this_tick.* >= budgets.max_input_messages_per_tick) return false;
    messages_this_tick.* += 1;
    return true;
}

pub fn actionIsNewer(
    last_sequence: identity.ActionSequence,
    sequence: identity.ActionSequence,
) bool {
    return sequence.newerThan(last_sequence);
}

test "input classification is monotonic and overflow safe" {
    const last = identity.InputSequence{ .value = 10 };
    try std.testing.expectEqual(
        InputDecision.stale_sequence,
        classifyInput(last, 100, .{ .value = 10 }, 101),
    );
    try std.testing.expectEqual(
        InputDecision.accepted,
        classifyInput(last, 100, .{ .value = 11 }, 101),
    );
    try std.testing.expectEqual(
        InputDecision.outside_tick_window,
        classifyInput(last, 100, .{ .value = 11 }, 100 + budgets.max_future_input_ticks + 1),
    );
    try std.testing.expectEqual(
        InputDecision.accepted,
        classifyInput(last, std.math.maxInt(u64), .{ .value = 11 }, std.math.maxInt(u64)),
    );
    try std.testing.expectEqual(
        InputDecision.outside_tick_window,
        classifyInput(last, std.math.maxInt(u64), .{ .value = 11 }, 0),
    );
}

test "input quota resets only when the authority tick advances" {
    var quota_tick: u64 = 0;
    var count: u16 = 0;
    var accepted: usize = 0;
    for (0..budgets.max_input_messages_per_tick + 2) |_| {
        accepted += @intFromBool(consumeInputQuota(7, &quota_tick, &count));
    }
    try std.testing.expectEqual(
        @as(usize, budgets.max_input_messages_per_tick),
        accepted,
    );
    try std.testing.expect(consumeInputQuota(8, &quota_tick, &count));
    try std.testing.expectEqual(@as(u16, 1), count);
}

test "identity and action helpers preserve generational semantics" {
    const session = identity.SessionId{ .value = 4 };
    const participant = identity.ParticipantId{ .index = 2, .generation = 7 };
    try std.testing.expect(identitiesMatch(session, participant, session, participant));
    try std.testing.expect(!identitiesMatch(
        session,
        participant,
        session,
        .{ .index = 2, .generation = 8 },
    ));
    try std.testing.expect(actionIsNewer(.{ .value = 8 }, .{ .value = 9 }));
    try std.testing.expect(!actionIsNewer(.{ .value = 9 }, .{ .value = 9 }));
}
