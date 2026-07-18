//! Semantic presentation-membership evidence for the graphical sandbox.
//!
//! Per-frame transforms belong in immutable observations, not in the causal
//! journal. This owner records only membership, health, and lifecycle changes,
//! making a body that vanishes or changes to dead state explainable without
//! flooding the bounded trace with continuous movement.

const std = @import("std");
const engine = @import("incinerator_engine");

pub const capacity: usize = 88;
pub const max_transition_records: usize = capacity * 2;
pub const tombstone_retention_ticks: u64 = 5 * 60;

pub const Kind = enum {
    local_player,
    remote_player,
    npc,
    vehicle,
    carryable,
};

pub const Observation = struct {
    entity: engine.gameplay_trace.EntityRef,
    position: [3]f32,
    health: u16,
    maximum_health: u16,
    life_state: u16,
    kind: Kind,
    velocity: [3]f32 = .{ 0, 0, 0 },
    facing_yaw: f32 = 0,
    radius: f32,
    half_height: f32,
    encounter_state: u16 = 0,
    attack_windup: bool = false,
    deadline_tick: u64 = 0,
};

pub const Tombstone = struct {
    observation: Observation,
    removed_tick: u64,
    removed_frame: u64,
};

pub const Batch = struct {
    records: [max_transition_records]engine.gameplay_trace.Record = undefined,
    count: usize = 0,

    pub fn slice(self: *const Batch) []const engine.gameplay_trace.Record {
        return self.records[0..self.count];
    }

    fn append(self: *Batch, record: engine.gameplay_trace.Record) !void {
        if (self.count == self.records.len) return error.PresentationTraceBatchFull;
        self.records[self.count] = record;
        self.count += 1;
    }
};

pub const Owner = struct {
    previous: [capacity]Observation = undefined,
    previous_count: usize = 0,
    tombstones: [capacity]Tombstone = undefined,
    tombstone_count: usize = 0,

    pub fn tombstoneSlice(self: *const Owner) []const Tombstone {
        return self.tombstones[0..self.tombstone_count];
    }

    pub fn observe(
        self: *Owner,
        authority_tick: u64,
        presentation_frame: u64,
        current: []const Observation,
    ) !Batch {
        if (current.len > capacity) return error.PresentationTraceCapacityExceeded;
        var batch = Batch{};
        self.expireTombstones(authority_tick);

        for (current) |observation| {
            self.removeTombstone(observation.entity);
            const prior = find(self.previous[0..self.previous_count], observation.entity);
            if (prior) |value| {
                if (value.health == observation.health and
                    value.maximum_health == observation.maximum_health and
                    value.life_state == observation.life_state)
                {
                    continue;
                }
                try batch.append(presentRecord(
                    authority_tick,
                    presentation_frame,
                    observation,
                    if (observation.life_state == 2)
                        .death
                    else if (observation.health < value.health)
                        .damage
                    else
                        .presentation,
                ));
            } else {
                try batch.append(presentRecord(
                    authority_tick,
                    presentation_frame,
                    observation,
                    if (observation.life_state == 2) .death else .spawn,
                ));
            }
        }

        for (self.previous[0..self.previous_count]) |prior| {
            if (find(current, prior.entity) != null) continue;
            var record = presentRecord(
                authority_tick,
                presentation_frame,
                prior,
                .despawn,
            );
            record.disposition = .invisible;
            try batch.append(record);
            self.addTombstone(.{
                .observation = prior,
                .removed_tick = authority_tick,
                .removed_frame = presentation_frame,
            });
        }

        for (current, 0..) |observation, index| self.previous[index] = observation;
        self.previous_count = current.len;
        return batch;
    }

    fn expireTombstones(self: *Owner, authority_tick: u64) void {
        var write: usize = 0;
        for (self.tombstones[0..self.tombstone_count]) |value| {
            if (authority_tick > value.removed_tick +| tombstone_retention_ticks) continue;
            self.tombstones[write] = value;
            write += 1;
        }
        self.tombstone_count = write;
    }

    fn removeTombstone(self: *Owner, entity: engine.gameplay_trace.EntityRef) void {
        var write: usize = 0;
        for (self.tombstones[0..self.tombstone_count]) |value| {
            if (sameEntity(value.observation.entity, entity)) continue;
            self.tombstones[write] = value;
            write += 1;
        }
        self.tombstone_count = write;
    }

    fn addTombstone(self: *Owner, value: Tombstone) void {
        self.removeTombstone(value.observation.entity);
        if (self.tombstone_count == self.tombstones.len) {
            for (self.tombstones[1..], 0..) |item, index| self.tombstones[index] = item;
            self.tombstone_count -= 1;
        }
        self.tombstones[self.tombstone_count] = value;
        self.tombstone_count += 1;
    }
};

fn find(
    observations: []const Observation,
    entity: engine.gameplay_trace.EntityRef,
) ?Observation {
    for (observations) |observation| {
        if (sameEntity(observation.entity, entity)) return observation;
    }
    return null;
}

fn sameEntity(
    first: engine.gameplay_trace.EntityRef,
    second: engine.gameplay_trace.EntityRef,
) bool {
    return first.namespace == second.namespace and first.local == second.local and
        first.incarnation == second.incarnation;
}

fn presentRecord(
    authority_tick: u64,
    presentation_frame: u64,
    observation: Observation,
    kind: engine.gameplay_trace.Kind,
) engine.gameplay_trace.Record {
    return .{
        .authority_tick = authority_tick,
        .presentation_frame = presentation_frame,
        .actor = observation.entity,
        .source = .presentation,
        .stage = .presentation_planned,
        .kind = kind,
        .disposition = .emitted,
        .fields = .{
            .position = true,
            .health = true,
            .state = true,
            .visibility = true,
        },
        .position = observation.position,
        .health = observation.health,
        .maximum_health = observation.maximum_health,
        .state = observation.life_state,
    };
}

test "presentation trace retains spawn death and disappearance without movement noise" {
    var owner = Owner{};
    const alive = Observation{
        .entity = .{ .namespace = 2, .local = 7, .incarnation = 1 },
        .position = .{ 1, 2, 3 },
        .health = 100,
        .maximum_health = 100,
        .life_state = 1,
        .kind = .npc,
        .radius = 0.5,
        .half_height = 0.9,
    };
    const spawned = try owner.observe(1, 10, &.{alive});
    try std.testing.expectEqual(@as(usize, 1), spawned.count);
    try std.testing.expectEqual(engine.gameplay_trace.Kind.spawn, spawned.records[0].kind);
    try std.testing.expectEqual(@as(usize, 0), (try owner.observe(2, 11, &.{alive})).count);

    var dead = alive;
    dead.health = 0;
    dead.life_state = 2;
    const death = try owner.observe(3, 12, &.{dead});
    try std.testing.expectEqual(@as(usize, 1), death.count);
    try std.testing.expectEqual(engine.gameplay_trace.Kind.death, death.records[0].kind);
    try std.testing.expectEqual(engine.gameplay_trace.Disposition.emitted, death.records[0].disposition);

    const absent = try owner.observe(4, 13, &.{});
    try std.testing.expectEqual(@as(usize, 1), absent.count);
    try std.testing.expectEqual(engine.gameplay_trace.Kind.despawn, absent.records[0].kind);
    try std.testing.expectEqual(engine.gameplay_trace.Disposition.invisible, absent.records[0].disposition);
}

test "bounded vehicle movement across an interest seam does not despawn or respawn" {
    var owner = Owner{};
    var vehicle = Observation{
        .entity = .{ .namespace = 2, .local = 0x1_0000_0011, .incarnation = 1 },
        .position = .{ 7.5, 1, 2 },
        .health = 0,
        .maximum_health = 0,
        .life_state = 0,
        .kind = .vehicle,
        .radius = 2,
        .half_height = 0.25,
    };
    const spawned = try owner.observe(100, 200, &.{vehicle});
    try std.testing.expectEqual(@as(usize, 1), spawned.count);
    try std.testing.expectEqual(engine.gameplay_trace.Kind.spawn, spawned.records[0].kind);

    for (0..120) |offset| {
        vehicle.position[0] = 7.5 + @as(f32, @floatFromInt(offset)) * 0.05;
        const batch = try owner.observe(101 + offset, 201 + offset, &.{vehicle});
        try std.testing.expectEqual(@as(usize, 0), batch.count);
        try std.testing.expectEqual(@as(usize, 0), owner.tombstoneSlice().len);
    }
}
