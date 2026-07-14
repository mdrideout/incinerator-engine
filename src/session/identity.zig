//! Explicit identities for transport, session, participant, and replication
//! lifetimes. None of these values is a Flecs entity, Jolt handle, or durable
//! persistent identity.

const std = @import("std");

pub const SessionId = struct {
    value: u64,

    pub fn validate(self: SessionId) !void {
        if (self.value == 0) return error.InvalidSessionId;
    }
};

pub const AccountId = struct {
    value: u64,

    pub fn validate(self: AccountId) !void {
        if (self.value == 0) return error.InvalidAccountId;
    }
};

pub const ParticipantId = GenerationalId(u16, "participant");
pub const ConnectionId = GenerationalId(u16, "connection");
pub const ReplicatedEntityId = GenerationalId(u32, "replicated entity");

pub const InputSequence = struct {
    value: u32,

    pub fn next(self: InputSequence) InputSequence {
        return .{ .value = self.value +% 1 };
    }

    pub fn newerThan(self: InputSequence, other: InputSequence) bool {
        const delta = self.value -% other.value;
        return delta != 0 and delta < 0x8000_0000;
    }
};

pub const ActionSequence = struct {
    value: u32,

    pub fn validate(self: ActionSequence) !void {
        if (self.value == 0) return error.InvalidActionSequence;
    }

    /// Zero is the uninitialized sentinel retained by authority state, so the
    /// generated sequence space wraps directly from the maximum value to one.
    pub fn next(self: ActionSequence) ActionSequence {
        const candidate = self.value +% 1;
        return .{ .value = if (candidate == 0) 1 else candidate };
    }

    pub fn newerThan(self: ActionSequence, other: ActionSequence) bool {
        const delta = self.value -% other.value;
        return delta != 0 and delta < 0x8000_0000;
    }
};

pub const SnapshotSequence = struct {
    value: u32,

    pub fn next(self: SnapshotSequence) SnapshotSequence {
        return .{ .value = self.value +% 1 };
    }

    pub fn newerThan(self: SnapshotSequence, other: SnapshotSequence) bool {
        const delta = self.value -% other.value;
        return delta != 0 and delta < 0x8000_0000;
    }
};

pub const ReconnectToken = struct {
    high: u64,
    low: u64,

    pub const invalid = ReconnectToken{ .high = 0, .low = 0 };

    pub fn isValid(self: ReconnectToken) bool {
        return self.high != 0 or self.low != 0;
    }
};

fn GenerationalId(comptime Index: type, comptime label: []const u8) type {
    return struct {
        index: Index,
        generation: u16,

        const Self = @This();
        pub const invalid = Self{ .index = 0, .generation = 0 };

        pub fn validate(self: Self) !void {
            if (self.index == 0 or self.generation == 0) {
                _ = label;
                return error.InvalidGenerationalId;
            }
        }

        pub fn isValid(self: Self) bool {
            self.validate() catch return false;
            return true;
        }
    };
}

test "identity layers reject zero and retain independent generations" {
    try std.testing.expectError(error.InvalidSessionId, (SessionId{ .value = 0 }).validate());
    try std.testing.expect(!(ParticipantId.invalid).isValid());
    const participant = ParticipantId{ .index = 1, .generation = 2 };
    try std.testing.expect(participant.isValid());
    try std.testing.expect(!std.meta.eql(
        participant,
        ParticipantId{ .index = 1, .generation = 3 },
    ));
}

test "wrapping sequences use a bounded half-range ordering" {
    const before_wrap = InputSequence{ .value = std.math.maxInt(u32) };
    const after_wrap = before_wrap.next();
    try std.testing.expect(after_wrap.newerThan(before_wrap));
    try std.testing.expect(!before_wrap.newerThan(after_wrap));
    try std.testing.expect(!(SnapshotSequence{ .value = 7 }).newerThan(.{ .value = 7 }));
}
