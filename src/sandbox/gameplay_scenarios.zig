//! Product-owned semantic gameplay scenario catalog.
//!
//! Graphical, renderer-free, local-session, listen, dedicated, fault, and
//! soak adapters share these names, actions, conditions, invariants, seeds,
//! and deadlines. Each adapter still owns its fixture and observations.

const gameplay_scenario = @import("incinerator_engine").gameplay_scenario;

pub const Action = enum {
    move_forward,
    jump,
    vehicle_toggle,
    steer_right,
    brake,
    hand_brake,
    carry_toggle,
    melee,
    respawn,
};

pub const Predicate = enum {
    blocker_contact,
    grounded_after_jump,
    vehicle_entered,
    vehicle_moved,
    vehicle_exited,
    carryable_collected,
    carryable_dropped,
    hostile_contact,
    player_dead,
    respawn_ready,
    player_respawned,
};

pub const Invariant = enum {
    finite_pose,
    expected_identity,
    continuous_living_presentation,
    physical_separation,
    terminal_action_disposition,
};

pub const Checkpoint = enum {
    blocker,
    vehicle_motion,
    carry_state,
    hostile_contact,
    player_death,
    player_respawn,
};

pub const Model = gameplay_scenario.Model(Action, Predicate, Invariant, Checkpoint);

pub const Named = enum {
    character_blocker_and_facing,
    vehicle_drive_wheel_and_exit,
    carry_collect_drop,
    hostile_npc_approach_contact_death_respawn,
};

const character_steps = [_]Model.Step{
    .{ .hold = .{
        .action = .move_forward,
        .until = .blocker_contact,
        .within_ticks = 240,
    } },
    .{ .release = .move_forward },
    .{ .checkpoint = .blocker },
    .{ .press = .jump },
    .{ .await = .{ .predicate = .grounded_after_jump, .within_ticks = 180 } },
};

const vehicle_steps = [_]Model.Step{
    .{ .press = .vehicle_toggle },
    .{ .await = .{ .predicate = .vehicle_entered, .within_ticks = 120 } },
    .{ .hold = .{
        .action = .move_forward,
        .until = .vehicle_moved,
        .within_ticks = 240,
    } },
    .{ .press = .steer_right },
    .{ .checkpoint = .vehicle_motion },
    .{ .release = .steer_right },
    .{ .release = .move_forward },
    .{ .press = .vehicle_toggle },
    .{ .await = .{ .predicate = .vehicle_exited, .within_ticks = 120 } },
};

const carry_steps = [_]Model.Step{
    .{ .press = .carry_toggle },
    .{ .await = .{ .predicate = .carryable_collected, .within_ticks = 120 } },
    .{ .checkpoint = .carry_state },
    .{ .press = .carry_toggle },
    .{ .await = .{ .predicate = .carryable_dropped, .within_ticks = 120 } },
};

const hostile_steps = [_]Model.Step{
    .{ .hold = .{
        .action = .move_forward,
        .until = .hostile_contact,
        .within_ticks = 600,
    } },
    .{ .release = .move_forward },
    .{ .checkpoint = .hostile_contact },
    .{ .press = .melee },
    .{ .await = .{ .predicate = .player_dead, .within_ticks = 1_800 } },
    .{ .checkpoint = .player_death },
    .{ .await = .{ .predicate = .respawn_ready, .within_ticks = 600 } },
    .{ .press = .respawn },
    .{ .await = .{ .predicate = .player_respawned, .within_ticks = 600 } },
    .{ .checkpoint = .player_respawn },
};

const common_invariants = [_]Invariant{
    .finite_pose,
    .expected_identity,
    .terminal_action_disposition,
};

const contact_invariants = [_]Invariant{
    .finite_pose,
    .expected_identity,
    .continuous_living_presentation,
    .physical_separation,
    .terminal_action_disposition,
};

pub fn get(named: Named) Model.Scenario {
    return switch (named) {
        .character_blocker_and_facing => .{
            .id = 1,
            .name = "character_blocker_and_facing",
            .seed = 0x51_01,
            .steps = &character_steps,
            .invariants = &common_invariants,
            .deadline_ticks = 720,
        },
        .vehicle_drive_wheel_and_exit => .{
            .id = 2,
            .name = "vehicle_drive_wheel_and_exit",
            .seed = 0x51_02,
            .steps = &vehicle_steps,
            .invariants = &common_invariants,
            .deadline_ticks = 1_200,
        },
        .carry_collect_drop => .{
            .id = 7,
            .name = "carry_collect_drop",
            .seed = 0x51_07,
            .steps = &carry_steps,
            .invariants = &common_invariants,
            .deadline_ticks = 720,
        },
        .hostile_npc_approach_contact_death_respawn => .{
            .id = 11,
            .name = "hostile_npc_approach_contact_death_respawn",
            .seed = 0x51_11,
            .steps = &hostile_steps,
            .invariants = &contact_invariants,
            .deadline_ticks = 4_800,
        },
    };
}

test "catalog scenarios initialize the shared condition runner" {
    const std = @import("std");
    inline for (std.meta.tags(Named)) |named| {
        const definition = get(named);
        _ = try Model.Runner.init(definition);
        try std.testing.expect(definition.steps.len != 0);
        try std.testing.expect(definition.invariants.len != 0);
        try std.testing.expect(definition.deadline_ticks != 0);
    }
}
