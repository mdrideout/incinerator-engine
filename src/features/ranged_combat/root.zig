//! Deterministic handgun state rules. World queries and damage stay outside.

const std = @import("std");
const contract = @import("ranged_combat_contract");

pub fn initialState(config: contract.Config) !contract.State {
    try config.validate();
    return .{
        .magazine = config.magazine_capacity,
        .reserve = config.starting_reserve,
    };
}

pub fn advance(
    state: *contract.State,
    config: contract.Config,
    authority_tick: u64,
) !contract.Advance {
    try state.validate(config);
    if (state.mode != .reloading or authority_tick < state.reload_complete_tick) {
        return .{ .completed_reload = false, .state = state.* };
    }
    const needed = config.magazine_capacity - state.magazine;
    const loaded = @min(needed, state.reserve);
    state.magazine += loaded;
    state.reserve -= loaded;
    state.mode = .equipped;
    state.reload_complete_tick = 0;
    try state.validate(config);
    return .{ .completed_reload = true, .state = state.* };
}

pub fn apply(
    state: *contract.State,
    config: contract.Config,
    action: contract.Action,
    context: contract.Context,
    authority_tick: u64,
) !contract.Decision {
    _ = try advance(state, config, authority_tick);
    const disposition: contract.Disposition = switch (action) {
        .equip_toggle => if (state.mode != .holstered) blk: {
            holster(state);
            break :blk .holstered;
        } else if (!context.permitsWeapon())
            .invalid_state
        else blk: {
            state.mode = .equipped;
            break :blk .equipped;
        },
        .fire => if (!context.permitsWeapon())
            .invalid_state
        else switch (state.mode) {
            .holstered => .not_equipped,
            .reloading => .reloading,
            .equipped => if (authority_tick < state.next_fire_tick)
                .cooldown
            else if (state.magazine == 0)
                .empty
            else blk: {
                state.magazine -= 1;
                state.next_fire_tick = authority_tick +| config.fire_interval_ticks;
                if (state.magazine == 0 and state.reserve != 0) {
                    state.mode = .reloading;
                    state.reload_complete_tick = authority_tick +| config.reload_ticks;
                }
                break :blk .shot_admitted;
            },
        },
        .reload => if (!context.permitsWeapon())
            .invalid_state
        else switch (state.mode) {
            .holstered => .not_equipped,
            .reloading => .reloading,
            .equipped => if (state.magazine == config.magazine_capacity)
                .already_full
            else if (state.reserve == 0)
                .no_reserve
            else blk: {
                state.mode = .reloading;
                state.reload_complete_tick = authority_tick +| config.reload_ticks;
                break :blk .reload_started;
            },
        },
    };
    try state.validate(config);
    return .{ .disposition = disposition, .state = state.* };
}

pub fn holster(state: *contract.State) void {
    state.mode = .holstered;
    state.reload_complete_tick = 0;
}

pub fn reset(state: *contract.State, config: contract.Config) !void {
    state.* = try initialState(config);
}

test "final admitted shot starts and completes the ordinary timed reload" {
    const config = contract.Config{
        .magazine_capacity = 2,
        .starting_reserve = 3,
        .damage = 25,
        .range = 60,
        .fire_interval_ticks = 3,
        .reload_ticks = 5,
    };
    var state = try initialState(config);
    const context = contract.Context{ .alive = true, .on_foot = true, .hands_free = true };
    try std.testing.expectEqual(
        contract.Disposition.equipped,
        (try apply(&state, config, .equip_toggle, context, 1)).disposition,
    );
    try std.testing.expectEqual(
        contract.Disposition.shot_admitted,
        (try apply(&state, config, .fire, context, 2)).disposition,
    );
    try std.testing.expectEqual(
        contract.Disposition.cooldown,
        (try apply(&state, config, .fire, context, 3)).disposition,
    );
    try std.testing.expectEqual(
        contract.Disposition.shot_admitted,
        (try apply(&state, config, .fire, context, 5)).disposition,
    );
    try std.testing.expectEqual(contract.Mode.reloading, state.mode);
    try std.testing.expectEqual(@as(u16, 0), state.magazine);
    try std.testing.expectEqual(@as(u16, 3), state.reserve);
    try std.testing.expectEqual(@as(u64, 10), state.reload_complete_tick);
    try std.testing.expectEqual(
        contract.Disposition.reloading,
        (try apply(&state, config, .fire, context, 8)).disposition,
    );
    try std.testing.expect(!(try advance(&state, config, 9)).completed_reload);
    try std.testing.expect((try advance(&state, config, 10)).completed_reload);
    try std.testing.expectEqual(@as(u16, 2), state.magazine);
    try std.testing.expectEqual(@as(u16, 1), state.reserve);
}

test "final admitted shot without reserve remains genuinely empty" {
    const config = contract.Config{
        .magazine_capacity = 1,
        .starting_reserve = 0,
        .fire_interval_ticks = 3,
    };
    var state = try initialState(config);
    const context = contract.Context{ .alive = true, .on_foot = true, .hands_free = true };
    _ = try apply(&state, config, .equip_toggle, context, 1);
    try std.testing.expectEqual(
        contract.Disposition.shot_admitted,
        (try apply(&state, config, .fire, context, 2)).disposition,
    );
    try std.testing.expectEqual(contract.Mode.equipped, state.mode);
    try std.testing.expectEqual(@as(u16, 0), state.magazine);
    try std.testing.expectEqual(@as(u64, 0), state.reload_complete_tick);
    try std.testing.expectEqual(
        contract.Disposition.empty,
        (try apply(&state, config, .fire, context, 5)).disposition,
    );
    try std.testing.expectEqual(
        contract.Disposition.no_reserve,
        (try apply(&state, config, .reload, context, 5)).disposition,
    );
}

test "manual tactical reload remains available for a partial magazine" {
    const config = contract.Config{
        .magazine_capacity = 4,
        .starting_reserve = 3,
        .reload_ticks = 5,
    };
    var state = try initialState(config);
    const context = contract.Context{ .alive = true, .on_foot = true, .hands_free = true };
    _ = try apply(&state, config, .equip_toggle, context, 1);
    _ = try apply(&state, config, .fire, context, 2);
    try std.testing.expectEqual(
        contract.Disposition.reload_started,
        (try apply(&state, config, .reload, context, 3)).disposition,
    );
    try std.testing.expectEqual(contract.Mode.reloading, state.mode);
    try std.testing.expectEqual(@as(u64, 8), state.reload_complete_tick);
    try std.testing.expect(!(try advance(&state, config, 7)).completed_reload);
    try std.testing.expect((try advance(&state, config, 8)).completed_reload);
    try std.testing.expectEqual(@as(u16, 4), state.magazine);
    try std.testing.expectEqual(@as(u16, 2), state.reserve);
}

test "holster cancels reload and death reset restores authored loadout" {
    const config = contract.Config{};
    var state = try initialState(config);
    const permitted = contract.Context{ .alive = true, .on_foot = true, .hands_free = true };
    _ = try apply(&state, config, .equip_toggle, permitted, 1);
    state.magazine = 4;
    _ = try apply(&state, config, .reload, permitted, 2);
    try std.testing.expectEqual(
        contract.Disposition.holstered,
        (try apply(&state, config, .equip_toggle, permitted, 3)).disposition,
    );
    try std.testing.expectEqual(@as(u64, 0), state.reload_complete_tick);
    try reset(&state, config);
    try std.testing.expectEqual(contract.Mode.holstered, state.mode);
    try std.testing.expectEqual(config.magazine_capacity, state.magazine);
    try std.testing.expectEqual(config.starting_reserve, state.reserve);
}

test "invalid avatar context never mutates state" {
    const config = contract.Config{};
    var state = try initialState(config);
    const before = state;
    const blocked = contract.Context{ .alive = true, .on_foot = false, .hands_free = true };
    try std.testing.expectEqual(
        contract.Disposition.invalid_state,
        (try apply(&state, config, .equip_toggle, blocked, 1)).disposition,
    );
    try std.testing.expectEqualDeep(before, state);
}
