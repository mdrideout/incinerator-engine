//! Immutable contract for the sandbox's bounded hostile-NPC replacement policy.

const std = @import("std");
const npc = @import("npc_contract");

pub const max_records: usize = npc.max_npcs;
pub const max_candidates: usize = 3;
pub const max_outcomes: usize = max_records * 2;

pub const Config = struct {
    retry_ticks: u16,
    minimum_player_distance: f32,
    visibility_radius: f32,

    pub fn validate(self: Config) !void {
        if (self.retry_ticks == 0 or !positiveFinite(self.minimum_player_distance) or
            !positiveFinite(self.visibility_radius) or
            self.minimum_player_distance >= self.visibility_radius)
        {
            return error.InvalidNpcReplacementConfiguration;
        }
    }
};

pub const Status = enum(u8) { pending = 1, awaiting_spawn = 2 };

pub const RecordV1 = struct {
    slot: u8,
    generation: u16,
    available_tick: u64,
    next_attempt_tick: u64,
    status: Status,
    candidate_count: u8,
    candidates: [max_candidates]npc.NodeRef,
};

pub const Schedule = struct {
    slot: u8,
    generation: u16,
    available_tick: u64,
    candidates: []const npc.NodeRef,
};

pub const RetryReason = enum(u8) {
    district_inactive = 1,
    occupied = 2,
    too_close_to_player = 3,
    visible_to_player = 4,
};

pub const Ready = struct { slot: u8, generation: u16, node: npc.NodeRef };

pub const Deferred = struct {
    slot: u8,
    generation: u16,
    reason: RetryReason,
    next_attempt_tick: u64,
};

pub const Outcome = union(enum) { ready: Ready, deferred: Deferred };

pub const Diagnostics = struct {
    pending: u16,
    awaiting_spawn: u16,
    attempts: u64,
    replacements_ready: u64,
    retries: u64,
    district_inactive: u64,
    occupied: u64,
    too_close_to_player: u64,
    visible_to_player: u64,
    outcomes_pending: u16,
    outcomes_high_water: u16,
};

pub fn validateRecord(record: RecordV1) !void {
    if (record.slot >= max_records or record.generation == 0 or
        record.available_tick == 0 or record.next_attempt_tick < record.available_tick or
        record.candidate_count == 0 or record.candidate_count > max_candidates)
    {
        return error.InvalidNpcReplacementRecord;
    }
    for (record.candidates[0..record.candidate_count], 0..) |candidate, index| {
        try validateNode(candidate);
        for (record.candidates[0..index]) |earlier| {
            if (npc.NodeRef.eql(earlier, candidate)) {
                return error.DuplicateNpcReplacementCandidate;
            }
        }
    }
}

pub fn validateNode(node: npc.NodeRef) !void {
    if (node.index >= 64) return error.InvalidNpcReplacementNode;
}

fn positiveFinite(value: f32) bool {
    return std.math.isFinite(value) and value > 0;
}

test "replacement records require canonical bounded candidates" {
    var record = RecordV1{
        .slot = 0,
        .generation = 1,
        .available_tick = 10,
        .next_attempt_tick = 10,
        .status = .pending,
        .candidate_count = 1,
        .candidates = @splat(.{}),
    };
    record.candidates[0] = .{ .coord = .{ .x = 0, .z = 0 }, .index = 1 };
    try validateRecord(record);
    record.candidate_count = 2;
    record.candidates[1] = record.candidates[0];
    try std.testing.expectError(error.DuplicateNpcReplacementCandidate, validateRecord(record));
}
