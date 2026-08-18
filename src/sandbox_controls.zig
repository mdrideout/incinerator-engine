//! Sandbox-owned bridge from render-frame input to fixed-tick actions.
//!
//! Held movement is sampled once per frame and repeated for every fixed tick.
//! Edges and deltas remain latched across zero-tick frames and are consumed by
//! exactly one tick when a slow frame produces multiple simulation steps.

const std = @import("std");
const gameplay_scenarios = @import("sandbox_gameplay_scenarios");

pub const FrameSample = struct {
    move: [2]f32 = .{ 0, 0 },
    look_delta: [2]f32 = .{ 0, 0 },
    jump_pressed: bool = false,
    interact_pressed: bool = false,
    carry_pressed: bool = false,
    melee_pressed: bool = false,
    weapon_toggle_pressed: bool = false,
    fire_pressed: bool = false,
    reload_pressed: bool = false,
    respawn_pressed: bool = false,
    brake: bool = false,
    hand_brake: bool = false,
    reset: bool = false,
};

pub const TickSample = struct {
    move: [2]f32,
    look_delta: [2]f32,
    jump_pressed: bool,
    interact_pressed: bool,
    carry_pressed: bool = false,
    melee_pressed: bool = false,
    weapon_toggle_pressed: bool = false,
    fire_pressed: bool = false,
    reload_pressed: bool = false,
    respawn_pressed: bool = false,
    brake: bool,
    hand_brake: bool,
};

pub const ScenarioAction = gameplay_scenarios.Action;
pub const ScenarioPredicate = gameplay_scenarios.Predicate;
pub const ScenarioInvariant = gameplay_scenarios.Invariant;
pub const ScenarioCheckpoint = gameplay_scenarios.Checkpoint;
pub const ScenarioModel = gameplay_scenarios.Model;
pub const NamedScenario = gameplay_scenarios.Named;
pub const scenario = gameplay_scenarios.get;

pub const VehicleScenarioSchedule = struct {
    enter_tick: u64,
    hand_brake_tick: u64,
    brake_tick: u64,
    steer_tick: u64,
    exit_tick: u64,
};

pub fn idleTickSample() TickSample {
    return .{
        .move = .{ 0, 0 },
        .look_delta = .{ 0, 0 },
        .jump_pressed = false,
        .interact_pressed = false,
        .brake = false,
        .hand_brake = false,
    };
}

/// Legacy fixed-frame graphical adapter for the typed S1 intent. The scenario
/// catalog is canonical; this function exists only until graphical validation
/// consumes condition observations directly.
pub fn characterScenarioTick(tick: u64, jump_tick: u64) TickSample {
    var result = idleTickSample();
    result.move = .{ 0, 1 };
    result.jump_pressed = tick == jump_tick;
    return result;
}

/// Legacy graphical timing adapter for the typed S2 intent.
pub fn vehicleScenarioTick(tick: u64, schedule: VehicleScenarioSchedule) TickSample {
    var result = idleTickSample();
    result.interact_pressed = tick == schedule.enter_tick or tick == schedule.exit_tick;
    if (tick > schedule.enter_tick and tick < schedule.exit_tick) {
        result.move = .{ if (tick >= schedule.steer_tick) 0.65 else 0, 1 };
        result.brake = tick >= schedule.brake_tick and tick < schedule.steer_tick;
        result.hand_brake = tick >= schedule.hand_brake_tick and tick < schedule.brake_tick;
    }
    return result;
}

/// Converts independent digital/controller axes into the unit-length movement
/// contract consumed by character authority. Vehicle throttle and steering
/// remain independent axes and must not use this mapping.
pub fn normalizedCharacterMove(move: [2]f32) [2]f32 {
    const length_squared = move[0] * move[0] + move[1] * move[1];
    if (length_squared <= 1) return move;
    const scale = 1.0 / @sqrt(length_squared);
    return .{ move[0] * scale, move[1] * scale };
}

pub const InteractiveSubmission = enum {
    character_control,
    vehicle_control,
    vehicle_toggle,
    carry_toggle,
    melee,
    weapon,
    respawn,
};

/// Classifies only expected player-state rejections. Contract, queue, link,
/// and authority failures remain fatal to the graphical composition.
pub fn isRecoverableSubmissionError(
    submission: InteractiveSubmission,
    err: anyerror,
) bool {
    return switch (submission) {
        .character_control => err == error.ClientNotJoined or
            err == error.CharacterControlUnavailable,
        .vehicle_control => err == error.ClientNotJoined or
            err == error.VehicleControlUnavailable,
        .vehicle_toggle => err == error.ClientNotJoined or
            err == error.LocalCharacterUnavailable or
            err == error.NoVehicleInRange or
            err == error.VehicleActionPending or
            err == error.VehicleActionResultsPending or
            err == error.AlreadyDriving or
            err == error.CannotDriveWhileCarrying or
            err == error.NotDriving,
        .carry_toggle => err == error.ClientNotJoined or
            err == error.LocalCharacterUnavailable or
            err == error.NoCarryableInRange or
            err == error.InteractionActionPending or
            err == error.InteractionActionResultsPending or
            err == error.CannotCarryWhileDriving or
            err == error.AlreadyCarrying or
            err == error.NotCarrying,
        .melee => err == error.ClientNotJoined or
            err == error.MeleeActionPending or
            err == error.MeleeActionResultsPending or
            err == error.AvatarDead or
            err == error.AvatarUnavailable or
            err == error.CannotMeleeWhileDriving,
        .weapon => err == error.ClientNotJoined or
            err == error.WeaponActionPending or
            err == error.WeaponActionResultsPending or
            err == error.AvatarDead or
            err == error.AvatarUnavailable or
            err == error.CannotUseWeaponWhileDriving or
            err == error.CannotUseWeaponWhileCarrying,
        .respawn => err == error.ClientNotJoined or
            err == error.RespawnActionPending or
            err == error.RespawnResultsPending or
            err == error.AvatarAlive or
            err == error.AvatarLifecycleUnavailable,
    };
}

pub const ActionLatch = struct {
    held_move: [2]f32 = .{ 0, 0 },
    pending_look: [2]f32 = .{ 0, 0 },
    pending_jump: bool = false,
    pending_interact: bool = false,
    pending_carry: bool = false,
    pending_melee: bool = false,
    pending_weapon_toggle: bool = false,
    pending_fire: bool = false,
    pending_reload: bool = false,
    pending_respawn: bool = false,
    held_brake: bool = false,
    held_hand_brake: bool = false,

    pub fn captureFrame(self: *ActionLatch, sample: FrameSample) !void {
        try validateFinite(sample.move);
        try validateFinite(sample.look_delta);
        if (sample.reset) {
            self.clear();
            return;
        }
        self.held_move = sample.move;
        self.pending_look[0] += sample.look_delta[0];
        self.pending_look[1] += sample.look_delta[1];
        if (!std.math.isFinite(self.pending_look[0]) or
            !std.math.isFinite(self.pending_look[1]))
        {
            self.clear();
            return error.LookDeltaOverflow;
        }
        self.pending_jump = self.pending_jump or sample.jump_pressed;
        self.pending_interact = self.pending_interact or sample.interact_pressed;
        self.pending_carry = self.pending_carry or sample.carry_pressed;
        self.pending_melee = self.pending_melee or sample.melee_pressed;
        self.pending_weapon_toggle = self.pending_weapon_toggle or sample.weapon_toggle_pressed;
        self.pending_fire = self.pending_fire or sample.fire_pressed;
        self.pending_reload = self.pending_reload or sample.reload_pressed;
        self.pending_respawn = self.pending_respawn or sample.respawn_pressed;
        self.held_brake = sample.brake;
        self.held_hand_brake = sample.hand_brake;
    }

    pub fn takeTick(self: *ActionLatch) TickSample {
        const result = TickSample{
            .move = self.held_move,
            .look_delta = self.pending_look,
            .jump_pressed = self.pending_jump,
            .interact_pressed = self.pending_interact,
            .carry_pressed = self.pending_carry,
            .melee_pressed = self.pending_melee,
            .weapon_toggle_pressed = self.pending_weapon_toggle,
            .fire_pressed = self.pending_fire,
            .reload_pressed = self.pending_reload,
            .respawn_pressed = self.pending_respawn,
            .brake = self.held_brake,
            .hand_brake = self.held_hand_brake,
        };
        self.pending_look = .{ 0, 0 };
        self.pending_jump = false;
        self.pending_interact = false;
        self.pending_carry = false;
        self.pending_melee = false;
        self.pending_weapon_toggle = false;
        self.pending_fire = false;
        self.pending_reload = false;
        self.pending_respawn = false;
        return result;
    }

    pub fn clear(self: *ActionLatch) void {
        self.* = .{};
    }
};

fn validateFinite(values: anytype) !void {
    for (values) |value| {
        if (!std.math.isFinite(value)) return error.NonFiniteActionSample;
    }
}

test "driving melee preflight is a recoverable interactive rejection" {
    try std.testing.expect(isRecoverableSubmissionError(
        .melee,
        error.CannotMeleeWhileDriving,
    ));
    try std.testing.expect(!isRecoverableSubmissionError(
        .melee,
        error.UnexpectedMeleeActionResult,
    ));
}

test "zero-tick frames retain edges and deltas" {
    var latch = ActionLatch{};
    try latch.captureFrame(.{
        .move = .{ 1, 0 },
        .look_delta = .{ 3, -2 },
        .jump_pressed = true,
        .interact_pressed = true,
        .carry_pressed = true,
        .melee_pressed = true,
        .respawn_pressed = true,
        .brake = true,
        .hand_brake = true,
    });
    // No call to takeTick: the next frame must accumulate rather than clear.
    try latch.captureFrame(.{
        .move = .{ 0, 1 },
        .look_delta = .{ 4, 1 },
    });
    const tick = latch.takeTick();
    try std.testing.expectEqual([2]f32{ 0, 1 }, tick.move);
    try std.testing.expectEqual([2]f32{ 7, -1 }, tick.look_delta);
    try std.testing.expect(tick.jump_pressed);
    try std.testing.expect(tick.interact_pressed);
    try std.testing.expect(tick.carry_pressed);
    try std.testing.expect(tick.melee_pressed);
    try std.testing.expect(tick.respawn_pressed);
    try std.testing.expect(!tick.brake);
    try std.testing.expect(!tick.hand_brake);
}

test "multi-tick frames consume edges once while movement remains held" {
    var latch = ActionLatch{};
    try latch.captureFrame(.{
        .move = .{ -1, 1 },
        .look_delta = .{ 2, 5 },
        .jump_pressed = true,
        .interact_pressed = true,
        .carry_pressed = true,
        .melee_pressed = true,
        .respawn_pressed = true,
        .brake = true,
        .hand_brake = true,
    });
    const first = latch.takeTick();
    const second = latch.takeTick();
    try std.testing.expectEqual(first.move, second.move);
    try std.testing.expectEqual([2]f32{ 2, 5 }, first.look_delta);
    try std.testing.expect(first.jump_pressed);
    try std.testing.expect(first.interact_pressed);
    try std.testing.expect(first.carry_pressed);
    try std.testing.expect(first.melee_pressed);
    try std.testing.expect(first.respawn_pressed);
    try std.testing.expect(first.brake);
    try std.testing.expect(first.hand_brake);
    try std.testing.expectEqual([2]f32{ 0, 0 }, second.look_delta);
    try std.testing.expect(!second.jump_pressed);
    try std.testing.expect(!second.interact_pressed);
    try std.testing.expect(!second.carry_pressed);
    try std.testing.expect(!second.melee_pressed);
    try std.testing.expect(!second.respawn_pressed);
    try std.testing.expect(second.brake);
    try std.testing.expect(second.hand_brake);
}

test "capture or focus reset discards pending gameplay actions" {
    var latch = ActionLatch{};
    try latch.captureFrame(.{
        .move = .{ 1, 0 },
        .look_delta = .{ 2, 3 },
        .jump_pressed = true,
        .interact_pressed = true,
        .carry_pressed = true,
        .melee_pressed = true,
        .respawn_pressed = true,
        .brake = true,
        .hand_brake = true,
    });
    try latch.captureFrame(.{ .reset = true });
    const tick = latch.takeTick();
    try std.testing.expectEqual([2]f32{ 0, 0 }, tick.move);
    try std.testing.expectEqual([2]f32{ 0, 0 }, tick.look_delta);
    try std.testing.expect(!tick.jump_pressed);
    try std.testing.expect(!tick.interact_pressed);
    try std.testing.expect(!tick.carry_pressed);
    try std.testing.expect(!tick.melee_pressed);
    try std.testing.expect(!tick.respawn_pressed);
    try std.testing.expect(!tick.brake);
    try std.testing.expect(!tick.hand_brake);
}

test "diagonal character movement satisfies the session unit-vector contract" {
    const move = normalizedCharacterMove(.{ 1, 1 });
    try std.testing.expectApproxEqAbs(
        @as(f32, 1.0 / @sqrt(2.0)),
        move[0],
        0.000001,
    );
    try std.testing.expectApproxEqAbs(move[0], move[1], 0.000001);
    try std.testing.expect(move[0] * move[0] + move[1] * move[1] <= 1.0001);
    try std.testing.expectEqual(
        [2]f32{ 0.25, -0.5 },
        normalizedCharacterMove(.{ 0.25, -0.5 }),
    );
}

test "interactive controls recover only from expected player-state rejections" {
    try std.testing.expect(isRecoverableSubmissionError(
        .character_control,
        error.CharacterControlUnavailable,
    ));
    try std.testing.expect(isRecoverableSubmissionError(
        .vehicle_control,
        error.VehicleControlUnavailable,
    ));
    try std.testing.expect(isRecoverableSubmissionError(
        .vehicle_toggle,
        error.NoVehicleInRange,
    ));
    try std.testing.expect(isRecoverableSubmissionError(
        .carry_toggle,
        error.NoCarryableInRange,
    ));
    try std.testing.expect(isRecoverableSubmissionError(.melee, error.AvatarDead));
    try std.testing.expect(isRecoverableSubmissionError(.respawn, error.AvatarAlive));

    inline for (std.meta.tags(InteractiveSubmission)) |submission| {
        try std.testing.expect(!isRecoverableSubmissionError(
            submission,
            error.LocalLinkClientQueueFull,
        ));
    }
    try std.testing.expect(!isRecoverableSubmissionError(
        .character_control,
        error.InvalidMovementInput,
    ));
}

test "shared gameplay scenario catalog is typed and deadline bounded" {
    inline for (std.meta.tags(NamedScenario)) |named| {
        const definition = scenario(named);
        _ = try ScenarioModel.Runner.init(definition);
        try std.testing.expect(definition.steps.len != 0);
        try std.testing.expect(definition.invariants.len != 0);
        try std.testing.expect(definition.deadline_ticks != 0);
    }
    try std.testing.expectEqualStrings(
        "hostile_npc_approach_contact_death_respawn",
        scenario(.hostile_npc_approach_contact_death_respawn).name,
    );
}

test "legacy graphical scenario adapters retain typed S1 and S2 action intent" {
    const character = characterScenarioTick(30, 30);
    try std.testing.expectEqual([2]f32{ 0, 1 }, character.move);
    try std.testing.expect(character.jump_pressed);

    const schedule = VehicleScenarioSchedule{
        .enter_tick = 10,
        .hand_brake_tick = 20,
        .brake_tick = 30,
        .steer_tick = 40,
        .exit_tick = 50,
    };
    try std.testing.expect(vehicleScenarioTick(10, schedule).interact_pressed);
    try std.testing.expect(vehicleScenarioTick(25, schedule).hand_brake);
    try std.testing.expect(vehicleScenarioTick(35, schedule).brake);
    try std.testing.expect(vehicleScenarioTick(45, schedule).move[0] != 0);
    try std.testing.expect(vehicleScenarioTick(50, schedule).interact_pressed);
}
