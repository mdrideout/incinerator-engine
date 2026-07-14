//! Canonical value contract for the player-character gameplay slice.

const std = @import("std");
const engine = @import("engine_contracts");
const driver_contract = @import("driver_contract");

pub const max_pending_commands: usize = 128;
pub const max_outcomes: usize = 128;
pub const max_events: usize = 256;

pub const Budget = struct {
    commands: u32 = max_pending_commands,
    outcomes: u32 = max_outcomes,
    events: u32 = max_events,
};

pub const declared_budget = Budget{};

pub const Assets = struct {
    mesh: engine.rendering.MeshHandle = .invalid,
    material: engine.rendering.MaterialHandle = .invalid,
};

pub const Config = struct {
    radius: f32 = 0.4,
    half_height: f32 = 0.5,
    move_speed: f32 = 6.0,
    jump_speed: f32 = 6.0,
    gravity: f32 = -20.0,
    terminal_fall_speed: f32 = 55.0,
    max_slope_radians: f32 = std.math.degreesToRadians(50.0),
    mass: f32 = 70.0,
    max_strength: f32 = 100.0,
    stick_to_floor_distance: f32 = 0.5,
    step_up_height: f32 = 0.4,
    max_characters: usize = 1,
    assets: Assets = .{},

    pub fn validate(self: Config) !void {
        if (self.max_characters == 0) return error.InvalidCharacterLimit;
        try (engine.physics.CharacterDesc{
            .position = .{ 0, 0, 0 },
            .radius = self.radius,
            .half_height = self.half_height,
            .max_slope_radians = self.max_slope_radians,
            .mass = self.mass,
            .max_strength = self.max_strength,
        }).validate();
        for ([_]f32{
            self.move_speed,
            self.jump_speed,
            self.terminal_fall_speed,
            self.stick_to_floor_distance,
            self.step_up_height,
        }) |value| {
            if (!std.math.isFinite(value) or value < 0) {
                return error.InvalidCharacterConfiguration;
            }
        }
        if (!std.math.isFinite(self.gravity) or self.gravity >= 0) {
            return error.InvalidCharacterGravity;
        }
        if (self.terminal_fall_speed == 0) return error.InvalidTerminalFallSpeed;
        if (!combinedCharacterSpeedFits(self.move_speed, self.jump_speed) or
            !combinedCharacterSpeedFits(self.move_speed, self.terminal_fall_speed))
        {
            return error.CharacterSpeedOutOfRange;
        }
    }
};

/// Feature-owned, simulation-relevant character tuning. Presentation handles
/// and host capacity are deliberately excluded.
pub const CharacterConfigV1 = struct {
    radius: f32,
    half_height: f32,
    move_speed: f32,
    jump_speed: f32,
    gravity: f32,
    terminal_fall_speed: f32,
    max_slope_radians: f32,
    mass: f32,
    max_strength: f32,
    stick_to_floor_distance: f32,
    step_up_height: f32,

    pub fn fromConfig(config: Config) CharacterConfigV1 {
        return .{
            .radius = config.radius,
            .half_height = config.half_height,
            .move_speed = config.move_speed,
            .jump_speed = config.jump_speed,
            .gravity = config.gravity,
            .terminal_fall_speed = config.terminal_fall_speed,
            .max_slope_radians = config.max_slope_radians,
            .mass = config.mass,
            .max_strength = config.max_strength,
            .stick_to_floor_distance = config.stick_to_floor_distance,
            .step_up_height = config.step_up_height,
        };
    }

    pub fn toConfig(
        self: CharacterConfigV1,
        max_characters: usize,
        assets: Assets,
    ) !Config {
        const config = Config{
            .radius = self.radius,
            .half_height = self.half_height,
            .move_speed = self.move_speed,
            .jump_speed = self.jump_speed,
            .gravity = self.gravity,
            .terminal_fall_speed = self.terminal_fall_speed,
            .max_slope_radians = self.max_slope_radians,
            .mass = self.mass,
            .max_strength = self.max_strength,
            .stick_to_floor_distance = self.stick_to_floor_distance,
            .step_up_height = self.step_up_height,
            .max_characters = max_characters,
            .assets = assets,
        };
        try config.validate();
        return config;
    }

    pub fn validate(self: CharacterConfigV1) !void {
        _ = try self.toConfig(1, .{});
    }
};

pub const SpawnCharacter = struct {
    request_id: u64,
    position: [3]f32,
    velocity: [3]f32 = .{ 0, 0, 0 },
    facing_yaw: f32 = 0,
};

/// High-level action state for one simulation tick. No SDL key or mouse code
/// crosses this feature boundary.
pub const ApplyActions = struct {
    id: engine.PersistentId,
    move: [2]f32 = .{ 0, 0 },
    facing_yaw: f32,
    jump_pressed: bool = false,
};

pub const DespawnCharacter = struct { id: engine.PersistentId };

pub const Command = union(enum) {
    spawn: SpawnCharacter,
    actions: ApplyActions,
    despawn: DespawnCharacter,
};

pub const Spawned = struct {
    request_id: u64,
    id: engine.PersistentId,
};

pub const GroundStateChanged = struct {
    id: engine.PersistentId,
    previous: engine.physics.GroundState,
    current: engine.physics.GroundState,
};

pub const CommandKind = enum { spawn, actions, despawn };
pub const RejectionReason = enum {
    capacity_reached,
    character_not_found,
    not_owned,
    driving,
    carrying,
};
pub const CommandRejected = struct {
    command: CommandKind,
    reason: RejectionReason,
    request_id: ?u64 = null,
    id: ?engine.PersistentId = null,
};

pub const Outcome = union(enum) {
    spawned: Spawned,
    despawned: engine.PersistentId,
    rejected: CommandRejected,
};

pub const Event = union(enum) {
    ground_state_changed: GroundStateChanged,
};

pub const CharacterView = struct {
    id: engine.PersistentId,
    position: [3]f32,
    velocity: [3]f32,
    facing_yaw: f32,
    ground_state: engine.physics.GroundState,
    radius: f32,
    half_height: f32,
    driver_mode: driver_contract.DriverMode,
};

pub const CharacterDraw = struct {
    persistent_id: engine.PersistentId,
    pose: engine.physics.Pose,
    radius: f32,
    half_height: f32,
    camera_target: [3]f32,
    mesh: engine.rendering.MeshHandle,
    material: engine.rendering.MaterialHandle,
};

pub const Diagnostics = struct {
    active_count: u32,
    commands: engine.diagnostics.QueueStats,
    outcomes: engine.diagnostics.QueueStats,
    events: engine.diagnostics.QueueStats,
    events_dropped: u64,
};

/// Feature-owned persistence payload. The composition root owns the enclosing
/// world schema, clock, identity cursor, and records from other features.
pub const CharacterV1 = struct {
    id: engine.PersistentId,
    position: [3]f32,
    velocity: [3]f32,
    facing_yaw: f32,
};

pub fn validateRecord(record: CharacterV1) !void {
    try record.id.validate();
    try validateFinite(record.position);
    try validateFinite(record.velocity);
    if (!std.math.isFinite(record.facing_yaw)) return error.InvalidFacingYaw;
    const pi: f32 = std.math.pi;
    if (record.facing_yaw < -pi or record.facing_yaw >= pi or
        @as(u32, @bitCast(record.facing_yaw)) == 0x8000_0000)
    {
        return error.NonCanonicalFacingYaw;
    }
    try (engine.physics.Velocity{ .linear = record.velocity }).validate();
}

const character_velocity_limit_margin: f64 = 0.01;

fn combinedCharacterSpeedFits(horizontal: f32, vertical: f32) bool {
    const horizontal_wide: f64 = horizontal;
    const vertical_wide: f64 = vertical;
    const safe_limit: f64 = @as(f64, engine.physics.max_linear_velocity) -
        character_velocity_limit_margin;
    return horizontal_wide * horizontal_wide + vertical_wide * vertical_wide <=
        safe_limit * safe_limit;
}

fn validateFinite(values: anytype) !void {
    for (values) |value| {
        if (!std.math.isFinite(value)) return error.NonFiniteCharacterValue;
    }
}

test "character contract validates canonical persisted values" {
    try validateRecord(.{
        .id = .{ .namespace = 1, .local = 1 },
        .position = .{ 0, 1, 2 },
        .velocity = .{ 0, 0, 0 },
        .facing_yaw = 0,
    });
}
