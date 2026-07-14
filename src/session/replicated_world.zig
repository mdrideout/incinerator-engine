//! Lightweight non-authoritative client state. It owns no Flecs world, Jolt
//! body, durable state, or gameplay decision.

const std = @import("std");
const budgets = @import("session_budgets");
const identity = @import("session_identity");
const protocol = @import("session_protocol");

pub const Entry = struct {
    previous: protocol.CharacterState,
    current: protocol.CharacterState,
};

pub const World = struct {
    entries: [budgets.max_participants]Entry = undefined,
    count: u8 = 0,
    server_tick: u64 = 0,
    sequence: identity.SnapshotSequence = .{ .value = 0 },
    initialized: bool = false,
    stale_snapshots: u64 = 0,

    pub fn apply(self: *World, snapshot: protocol.Snapshot) !void {
        if (snapshot.count > budgets.max_participants) return error.TooManyCharacters;
        if (self.initialized and !snapshot.sequence.newerThan(self.sequence)) {
            self.stale_snapshots +|= 1;
            return error.StaleSnapshot;
        }

        var next: [budgets.max_participants]Entry = undefined;
        for (snapshot.slice(), 0..) |character, index| {
            try character.entity.validate();
            try character.owner.validate();
            try validateFinite(character);
            const previous = self.find(character.entity) orelse character;
            next[index] = .{ .previous = previous, .current = character };
        }
        self.entries = next;
        self.count = snapshot.count;
        self.server_tick = snapshot.server_tick;
        self.sequence = snapshot.sequence;
        self.initialized = true;
    }

    pub fn slice(self: *const World) []const Entry {
        return self.entries[0..self.count];
    }

    pub fn find(self: *const World, id: identity.ReplicatedEntityId) ?protocol.CharacterState {
        for (self.slice()) |entry| {
            if (std.meta.eql(entry.current.entity, id)) return entry.current;
        }
        return null;
    }

    pub fn interpolate(entry: Entry, alpha: f32) protocol.CharacterState {
        const t = std.math.clamp(alpha, 0, 1);
        var result = entry.current;
        for (&result.position, entry.previous.position, entry.current.position) |
            *out,
            previous,
            current,
        | out.* = previous + (current - previous) * t;
        for (&result.velocity, entry.previous.velocity, entry.current.velocity) |
            *out,
            previous,
            current,
        | out.* = previous + (current - previous) * t;
        result.facing_yaw = entry.previous.facing_yaw +
            (entry.current.facing_yaw - entry.previous.facing_yaw) * t;
        return result;
    }
};

fn validateFinite(character: protocol.CharacterState) !void {
    for (character.position ++ character.velocity ++ .{character.facing_yaw}) |value| {
        if (!std.math.isFinite(value)) return error.NonFiniteReplicatedState;
    }
}

test "replicated world replaces membership and retains interpolation history" {
    var world = World{};
    var first = protocol.Snapshot.empty();
    first.sequence.value = 1;
    first.server_tick = 3;
    first.count = 1;
    first.characters[0] = .{
        .entity = .{ .index = 1, .generation = 1 },
        .owner = .{ .index = 1, .generation = 1 },
        .position = .{ 0, 0, 0 },
        .velocity = .{ 1, 0, 0 },
        .facing_yaw = 0,
    };
    try world.apply(first);
    var second = first;
    second.sequence.value = 2;
    second.server_tick = 6;
    second.characters[0].position[0] = 2;
    try world.apply(second);
    const midpoint = World.interpolate(world.slice()[0], 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 1), midpoint.position[0], 0.0001);
    try std.testing.expectError(error.StaleSnapshot, world.apply(first));
}
