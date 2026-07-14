//! Backend-neutral authoritative vitals contract shared by players and NPCs.

const std = @import("std");
const engine = @import("engine_contracts");

pub const max_records: usize = 80;
pub const max_pending_commands: usize = 256;
pub const max_outcomes: usize = 256;
pub const max_events: usize = 128;
pub const default_max_health: u16 = 100;

pub const Incarnation = struct {
    value: u16,

    pub fn validate(self: Incarnation) !void {
        if (self.value == 0) return error.InvalidAvatarIncarnation;
    }

    pub fn next(self: Incarnation) Incarnation {
        const candidate = self.value +% 1;
        return .{ .value = if (candidate == 0) 1 else candidate };
    }
};

pub const LifeState = enum(u8) {
    alive = 1,
    dead = 2,
};

pub const TargetKind = enum(u8) {
    player = 1,
    npc = 2,
};

pub const Cause = enum(u8) {
    melee = 1,
    scripted_npc = 2,

    pub fn priority(self: Cause) u8 {
        return @intFromEnum(self);
    }
};

pub const Source = struct {
    kind: TargetKind,
    id: engine.PersistentId,
    incarnation: Incarnation,
    action_sequence: u32,

    pub fn validate(self: Source) !void {
        try self.id.validate();
        try self.incarnation.validate();
        if (self.action_sequence == 0) return error.InvalidDamageActionSequence;
    }
};

pub const Target = struct {
    kind: TargetKind,
    id: engine.PersistentId,
    incarnation: Incarnation,

    pub fn validate(self: Target) !void {
        try self.id.validate();
        try self.incarnation.validate();
    }
};

pub const Register = struct {
    target: Target,
    maximum_health: u16 = default_max_health,
    current_health: u16 = default_max_health,
    life_state: LifeState = .alive,
    death_tick: u64 = 0,
};

pub const DamageProposal = struct {
    source: Source,
    target: Target,
    cause: Cause,
    authority_tick: u64,
    correlation: u64,
    base_amount: u16,
    ordinal: u16,

    pub fn validate(self: DamageProposal) !void {
        try self.source.validate();
        try self.target.validate();
        if (self.authority_tick == 0) return error.InvalidDamageTick;
        if (self.correlation == 0) return error.InvalidDamageCorrelation;
        if (self.base_amount == 0) return error.InvalidDamageAmount;
    }
};

pub const Command = union(enum) {
    register: Register,
    remove: Target,
    damage: DamageProposal,
};

pub const DamageDisposition = enum(u8) {
    applied = 1,
    target_missing = 2,
    stale_incarnation = 3,
    already_dead = 4,
};

pub const DamageOutcome = struct {
    proposal: DamageProposal,
    disposition: DamageDisposition,
    applied_amount: u16 = 0,
    remaining_health: u16 = 0,
    killed: bool = false,
};

pub const RejectionReason = enum(u8) {
    capacity_reached = 1,
    duplicate_target = 2,
    target_missing = 3,
    stale_incarnation = 4,
    invalid_initial_state = 5,
};

pub const Rejected = struct {
    target: Target,
    reason: RejectionReason,
};

pub const Outcome = union(enum) {
    registered: Target,
    removed: Target,
    damage: DamageOutcome,
    rejected: Rejected,
};

pub const DeathEvent = struct {
    target: Target,
    source: Source,
    cause: Cause,
    authority_tick: u64,
    correlation: u64,
};

pub const Event = union(enum) {
    died: DeathEvent,
};

pub const View = struct {
    target: Target,
    current_health: u16,
    maximum_health: u16,
    life_state: LifeState,
    death_tick: u64,
};

pub const VitalsV1 = struct {
    target: Target,
    current_health: u16,
    maximum_health: u16,
    life_state: LifeState,
    death_tick: u64,
};

pub const Diagnostics = struct {
    active_records: u16,
    alive_records: u16,
    pending_commands: u16,
    outcomes: u16,
    events: u16,
    proposals_applied: u64,
    proposals_rejected: u64,
    deaths: u64,
};

pub fn validateRegister(value: Register) !void {
    try value.target.validate();
    if (value.maximum_health == 0 or value.current_health > value.maximum_health) {
        return error.InvalidInitialHealth;
    }
    switch (value.life_state) {
        .alive => if (value.current_health == 0 or value.death_tick != 0) {
            return error.InvalidAliveState;
        },
        .dead => if (value.current_health != 0 or value.death_tick == 0) {
            return error.InvalidDeadState;
        },
    }
}

pub fn validateRecord(value: VitalsV1) !void {
    try validateRegister(.{
        .target = value.target,
        .maximum_health = value.maximum_health,
        .current_health = value.current_health,
        .life_state = value.life_state,
        .death_tick = value.death_tick,
    });
}

pub fn validateRecords(records: []const VitalsV1) !void {
    if (records.len > max_records) return error.TooManyVitalsRecords;
    for (records, 0..) |record, index| {
        try validateRecord(record);
        for (records[0..index]) |earlier| {
            if (std.meta.eql(earlier.target, record.target)) {
                return error.DuplicateVitalsTarget;
            }
        }
    }
}

test "vitals contract rejects impossible alive and dead records" {
    const target = Target{
        .kind = .player,
        .id = .{ .namespace = 1, .local = 1 },
        .incarnation = .{ .value = 1 },
    };
    try std.testing.expectError(error.InvalidAliveState, validateRegister(.{
        .target = target,
        .current_health = 0,
    }));
    try std.testing.expectError(error.InvalidDeadState, validateRegister(.{
        .target = target,
        .current_health = 0,
        .life_state = .dead,
    }));
}
