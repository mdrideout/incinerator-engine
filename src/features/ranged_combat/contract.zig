//! Backend-neutral contract for the first authoritative handgun slice.

const std = @import("std");

pub const Config = struct {
    magazine_capacity: u16 = 12,
    starting_reserve: u16 = 36,
    damage: u16 = 25,
    range: f32 = 60,
    fire_interval_ticks: u16 = 12,
    reload_ticks: u16 = 90,

    pub fn validate(self: Config) !void {
        if (self.magazine_capacity == 0) return error.InvalidMagazineCapacity;
        if (self.damage == 0) return error.InvalidFirearmDamage;
        if (!std.math.isFinite(self.range) or self.range <= 0) {
            return error.InvalidFirearmRange;
        }
        if (self.fire_interval_ticks == 0) return error.InvalidFireInterval;
        if (self.reload_ticks == 0) return error.InvalidReloadDuration;
    }
};

pub const Mode = enum(u8) {
    holstered = 1,
    equipped = 2,
    reloading = 3,
};

pub const State = struct {
    mode: Mode = .holstered,
    magazine: u16 = 0,
    reserve: u16 = 0,
    next_fire_tick: u64 = 0,
    reload_complete_tick: u64 = 0,

    pub fn validate(self: State, config: Config) !void {
        try config.validate();
        if (self.magazine > config.magazine_capacity) return error.InvalidMagazineAmmo;
        switch (self.mode) {
            .holstered, .equipped => if (self.reload_complete_tick != 0) {
                return error.InvalidReloadDeadline;
            },
            .reloading => if (self.reload_complete_tick == 0) {
                return error.InvalidReloadDeadline;
            },
        }
    }
};

pub const Context = struct {
    alive: bool,
    on_foot: bool,
    hands_free: bool,

    pub fn permitsWeapon(self: Context) bool {
        return self.alive and self.on_foot and self.hands_free;
    }
};

pub const Action = enum(u8) {
    equip_toggle = 1,
    fire = 2,
    reload = 3,
};

pub const Disposition = enum(u8) {
    equipped = 1,
    holstered = 2,
    shot_admitted = 3,
    reload_started = 4,
    cooldown = 5,
    empty = 6,
    already_full = 7,
    no_reserve = 8,
    reloading = 9,
    not_equipped = 10,
    invalid_state = 11,
};

pub const Decision = struct {
    disposition: Disposition,
    state: State,

    pub fn admittedShot(self: Decision) bool {
        return self.disposition == .shot_admitted;
    }
};

pub const Advance = struct {
    completed_reload: bool,
    state: State,
};
