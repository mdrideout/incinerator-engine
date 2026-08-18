//! Projection from shared session protocol transitions into engine gameplay
//! trace records. Networked and embedded placements use this same mapping;
//! hosts do not re-dispatch protocol unions to invent their own semantics.

const std = @import("std");
const engine = @import("incinerator_engine");
const identity = @import("session_identity");
const protocol = @import("session_protocol");

pub const MovementState = struct {
    initialized: bool = false,
    move: [2]f32 = .{ 0, 0 },
    facing_yaw: f32 = 0,
    jump_pressed: bool = false,

    fn changed(self: *MovementState, value: protocol.InputFrame) bool {
        const move_changed = @abs(self.move[0] - value.move[0]) >= 0.01 or
            @abs(self.move[1] - value.move[1]) >= 0.01;
        const yaw_changed = wrappedAngleDistance(
            self.facing_yaw,
            value.facing_yaw,
        ) >= std.math.degreesToRadians(5.0);
        const result = !self.initialized or move_changed or yaw_changed or
            self.jump_pressed != value.jump_pressed;
        // Compare against the last emitted semantic sample, not the previous
        // raw sample, so small cumulative camera motion eventually produces
        // evidence without consuming one journal record per simulation tick.
        if (result) self.* = .{
            .initialized = true,
            .move = value.move,
            .facing_yaw = value.facing_yaw,
            .jump_pressed = value.jump_pressed,
        };
        return result;
    }
};

fn wrappedAngleDistance(first: f32, second: f32) f32 {
    const tau: f32 = 2.0 * std.math.pi;
    var delta = @mod(second - first + std.math.pi, tau) - std.math.pi;
    if (delta < -std.math.pi) delta += tau;
    return @abs(delta);
}

pub const VehicleState = struct {
    initialized: bool = false,
    throttle: f32 = 0,
    steering: f32 = 0,
    brake: f32 = 0,
    hand_brake: f32 = 0,

    fn changed(self: *VehicleState, value: protocol.VehicleInputFrame) bool {
        const result = !self.initialized or
            self.throttle != value.throttle or
            self.steering != value.steering or
            self.brake != value.brake or
            self.hand_brake != value.hand_brake;
        self.* = .{
            .initialized = true,
            .throttle = value.throttle,
            .steering = value.steering,
            .brake = value.brake,
            .hand_brake = value.hand_brake,
        };
        return result;
    }
};

pub fn clientRecord(
    message: protocol.ClientMessage,
    movement: *MovementState,
    vehicle: *VehicleState,
    tick: u64,
    actor: ?engine.gameplay_trace.EntityRef,
    source: engine.gameplay_trace.Source,
    stage: engine.gameplay_trace.Stage,
) ?engine.gameplay_trace.Record {
    var value = engine.gameplay_trace.Record{
        .authority_tick = tick,
        .actor = actor,
        .source = source,
        .stage = stage,
        .kind = .movement,
        .disposition = .accepted,
    };
    switch (message) {
        .input => |input| {
            if (!movement.changed(input)) return null;
            value.correlation_id = input.sequence.value;
            value.kind = if (input.jump_pressed) .jump else .movement;
        },
        .vehicle_input => |input| {
            if (!vehicle.changed(input)) return null;
            value.correlation_id = input.sequence.value;
            value.kind = .vehicle_control;
            value.target = replicatedEntity(input.vehicle, 0);
        },
        .vehicle_action => |action| {
            value.correlation_id = action.sequence.value;
            value.kind = .vehicle_toggle;
            value.target = replicatedEntity(action.vehicle, 0);
        },
        .interaction_action => |action| {
            value.correlation_id = action.sequence.value;
            value.kind = .carry_toggle;
            value.target = replicatedEntity(action.carryable, 0);
        },
        .melee_action => |action| {
            value.correlation_id = action.sequence.value;
            value.kind = .melee;
        },
        .weapon_action => |action| {
            value.correlation_id = action.sequence.value;
            value.kind = .firearm;
        },
        .respawn_action => |action| {
            value.correlation_id = action.sequence.value;
            value.kind = .respawn;
        },
        .hello, .baseline_ack, .snapshot_ack, .delivery_receipt, .disconnect => return null,
    }
    return value;
}

pub fn appliedServerRecord(
    message: protocol.ServerMessage,
    tick: u64,
    actor: ?engine.gameplay_trace.EntityRef,
) ?engine.gameplay_trace.Record {
    var value = engine.gameplay_trace.Record{
        .authority_tick = tick,
        .actor = actor,
        .source = .client,
        .stage = .client_applied,
        .kind = .replication,
        .disposition = .applied,
    };
    switch (message) {
        .vehicle_action_result => |result| {
            value.correlation_id = result.sequence.value;
            value.kind = .vehicle_toggle;
            value.target = replicatedEntity(result.vehicle, 0);
            value.disposition = switch (result.disposition) {
                .entered, .exited => .applied,
                else => .rejected,
            };
            value.reason = @intFromEnum(result.disposition);
            value.reason_domain = .protocol_disposition;
        },
        .interaction_action_result => |result| {
            value.correlation_id = result.sequence.value;
            value.kind = .carry_toggle;
            value.target = replicatedEntity(result.carryable, 0);
            value.disposition = switch (result.disposition) {
                .collected, .dropped => .applied,
                else => .rejected,
            };
            value.reason = @intFromEnum(result.disposition);
            value.reason_domain = .protocol_disposition;
        },
        .melee_action_result => |result| {
            value.correlation_id = result.sequence.value;
            value.kind = .melee;
            value.target = if (result.target.isValid())
                replicatedEntity(result.target, result.target_incarnation)
            else
                null;
            value.disposition = switch (result.disposition) {
                .hit, .miss => .applied,
                else => .rejected,
            };
            value.reason = @intFromEnum(result.disposition);
            value.reason_domain = .protocol_disposition;
            value.fields.health = result.target.isValid();
            value.health = result.remaining_health;
        },
        .weapon_action_result => |result| {
            value.correlation_id = result.sequence.value;
            value.kind = .firearm;
            value.target = if (result.target.isValid())
                replicatedEntity(result.target, result.target_incarnation)
            else
                null;
            value.disposition = switch (result.disposition) {
                .equipped, .holstered, .reload_started, .fired_hit, .fired_miss => .applied,
                else => .rejected,
            };
            value.reason = @intFromEnum(result.disposition);
            value.reason_domain = .protocol_disposition;
            value.fields.health = result.target.isValid();
            value.health = result.remaining_health;
            value.fields.deadline = result.weapon_ready_tick != 0 or
                result.reload_complete_tick != 0;
            value.deadline_tick = @max(
                result.weapon_ready_tick,
                result.reload_complete_tick,
            );
            value.weapon = .{
                .action = @intFromEnum(result.action),
                .mode = @intFromEnum(result.mode),
                .magazine_ammo = result.magazine_ammo,
                .reserve_ammo = result.reserve_ammo,
                .weapon_ready_tick = result.weapon_ready_tick,
                .reload_complete_tick = result.reload_complete_tick,
                .ray_origin = result.ray_origin,
                .impact_position = result.impact_position,
                .applied_damage = result.applied_damage,
                .killed = result.killed,
            };
        },
        .shot_event => |event| {
            value.correlation_id = event.sequence.value;
            value.kind = .firearm;
            value.target = if (event.target.isValid())
                replicatedEntity(event.target, event.target_incarnation)
            else
                null;
            value.fields.health = event.target.isValid();
            value.health = event.remaining_health;
            value.weapon = .{
                .action = @intFromEnum(protocol.WeaponActionKind.fire),
                .mode = 0,
                .magazine_ammo = 0,
                .reserve_ammo = 0,
                .weapon_ready_tick = 0,
                .reload_complete_tick = 0,
                .ray_origin = event.ray_origin,
                .impact_position = event.impact_position,
                .applied_damage = event.applied_damage,
                .killed = event.killed,
            };
        },
        .respawn_action_result => |result| {
            value.correlation_id = result.sequence.value;
            value.kind = .respawn;
            value.target = if (result.avatar.isValid())
                replicatedEntity(result.avatar, result.incarnation)
            else
                null;
            value.disposition = if (result.disposition == .respawned)
                .applied
            else
                .rejected;
            value.reason = @intFromEnum(result.disposition);
            value.reason_domain = .protocol_disposition;
            value.fields.deadline = result.ready_tick != 0;
            value.deadline_tick = result.ready_tick;
        },
        .life_event => |event| {
            value.kind = if (event.state == .dead) .death else if (event.health < event.maximum_health)
                .damage
            else
                .spawn;
            value.target = replicatedEntity(event.avatar, event.incarnation);
            value.fields.health = true;
            value.fields.state = true;
            value.health = event.health;
            value.maximum_health = event.maximum_health;
            value.state = @intFromEnum(event.state);
            value.fields.deadline = event.respawn_ready_tick != 0;
            value.deadline_tick = event.respawn_ready_tick;
        },
        .rejected => |rejection| {
            value.stage = .authority_rejected;
            value.disposition = .rejected;
            value.reason = @intFromEnum(rejection.reason);
            value.reason_domain = .protocol_disposition;
        },
        .welcome, .snapshot, .relevance_baseline, .disconnected => return null,
    }
    return value;
}

pub fn replicatedEntity(
    entity: identity.ReplicatedEntityId,
    incarnation: u32,
) engine.gameplay_trace.EntityRef {
    return .{
        .namespace = 2,
        .local = (@as(u64, entity.generation) << 32) | @as(u64, entity.index),
        .incarnation = incarnation,
    };
}

test "session trace projection suppresses unchanged continuous input" {
    var movement: MovementState = .{};
    var vehicle: VehicleState = .{};
    const input = protocol.ClientMessage{ .input = .{
        .session = .{ .value = 1 },
        .participant = .{ .index = 1, .generation = 1 },
        .sequence = .{ .value = 7 },
        .target_tick = 2,
        .move = .{ 0, 1 },
        .facing_yaw = 0,
        .jump_pressed = false,
    } };
    try std.testing.expect(clientRecord(
        input,
        &movement,
        &vehicle,
        1,
        null,
        .client,
        .client_submitted,
    ) != null);
    try std.testing.expect(clientRecord(
        input,
        &movement,
        &vehicle,
        1,
        null,
        .client,
        .client_submitted,
    ) == null);
}

test "session trace coalesces small camera increments but retains cumulative turns" {
    var movement: MovementState = .{};
    var vehicle: VehicleState = .{};
    var input = protocol.ClientMessage{ .input = .{
        .session = .{ .value = 1 },
        .participant = .{ .index = 1, .generation = 1 },
        .sequence = .{ .value = 1 },
        .target_tick = 2,
        .move = .{ 0, 0 },
        .facing_yaw = 0,
        .jump_pressed = false,
    } };
    try std.testing.expect(clientRecord(
        input,
        &movement,
        &vehicle,
        1,
        null,
        .client,
        .client_submitted,
    ) != null);
    input.input.facing_yaw = std.math.degreesToRadians(1.0);
    try std.testing.expect(clientRecord(
        input,
        &movement,
        &vehicle,
        2,
        null,
        .client,
        .client_submitted,
    ) == null);
    input.input.facing_yaw = std.math.degreesToRadians(6.0);
    try std.testing.expect(clientRecord(
        input,
        &movement,
        &vehicle,
        3,
        null,
        .client,
        .client_submitted,
    ) != null);
}

test "session trace retains firearm action result and ray correlation" {
    var movement: MovementState = .{};
    var vehicle: VehicleState = .{};
    const action = protocol.ClientMessage{ .weapon_action = .{
        .session = .{ .value = 1 },
        .participant = .{ .index = 1, .generation = 1 },
        .sequence = .{ .value = 19 },
        .avatar_incarnation = 3,
        .target_tick = 80,
        .kind = .fire,
    } };
    const submitted = clientRecord(
        action,
        &movement,
        &vehicle,
        79,
        null,
        .client,
        .client_submitted,
    ) orelse return error.MissingFirearmSubmissionTrace;
    try std.testing.expectEqual(engine.gameplay_trace.Kind.firearm, submitted.kind);
    try std.testing.expectEqual(@as(u64, 19), submitted.correlation_id);

    const result = appliedServerRecord(.{ .weapon_action_result = .{
        .sequence = .{ .value = 19 },
        .authority_tick = 80,
        .action = .fire,
        .disposition = .fired_hit,
        .mode = .equipped,
        .magazine_ammo = 11,
        .reserve_ammo = 36,
        .weapon_ready_tick = 92,
        .reload_complete_tick = 0,
        .target = .{ .index = 22, .generation = 4 },
        .target_incarnation = 7,
        .ray_origin = .{ 1, 2, 3 },
        .impact_position = .{ 1, 2, -3 },
        .applied_damage = 25,
        .remaining_health = 75,
    } }, 80, null) orelse return error.MissingFirearmResultTrace;
    try std.testing.expectEqual(engine.gameplay_trace.Kind.firearm, result.kind);
    try std.testing.expectEqual(@as(u64, 19), result.correlation_id);
    try std.testing.expectEqual(@as(u16, 75), result.health);
    try std.testing.expectEqual(@as(u16, 11), result.weapon.?.magazine_ammo);
    try std.testing.expectEqualDeep([3]f32{ 1, 2, -3 }, result.weapon.?.impact_position);
    try std.testing.expectEqual(@as(u16, 25), result.weapon.?.applied_damage);
}
