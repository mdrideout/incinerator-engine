//! Backend-neutral observations and temporal gameplay invariant checks.
//!
//! Scenario adapters copy their authority, replication, presentation, camera,
//! and action state into these small values. The checks never reach back into
//! a feature or renderer and therefore remain identical across placements.

const std = @import("std");
const trace = @import("gameplay_trace.zig");

pub const Actor = struct {
    entity: trace.EntityRef,
    alive: bool,
    authority_present: bool,
    replication_present: bool,
    presentation_present: bool,
    position: [3]f32,
    facing_yaw: f32,
    radius: f32,

    pub fn validate(self: Actor) !void {
        for (self.position) |component| {
            if (!std.math.isFinite(component)) return error.NonFiniteActorPose;
        }
        if (!std.math.isFinite(self.facing_yaw)) return error.NonFiniteActorPose;
        if (!std.math.isFinite(self.radius) or self.radius <= 0) {
            return error.InvalidActorRadius;
        }
        if (self.alive and !self.authority_present) {
            return error.LivingActorMissingFromAuthority;
        }
        if (self.alive and !self.replication_present) {
            return error.LivingActorMissingFromReplication;
        }
        if (self.alive and !self.presentation_present) {
            return error.LivingActorMissingFromPresentation;
        }
    }
};

pub const Camera = struct {
    position: [3]f32,
    near_plane: f32,

    pub fn validate(self: Camera) !void {
        for (self.position) |component| {
            if (!std.math.isFinite(component)) return error.NonFiniteCameraPose;
        }
        if (!std.math.isFinite(self.near_plane) or self.near_plane <= 0) {
            return error.InvalidCameraNearPlane;
        }
    }
};

pub const ActionState = enum { pending, accepted, rejected };

pub const Action = struct {
    correlation_id: u64,
    submitted_tick: u64,
    deadline_tick: u64,
    state: ActionState,

    pub fn validateAt(self: Action, tick: u64) !void {
        if (self.correlation_id == 0 or self.submitted_tick == 0 or
            self.deadline_tick < self.submitted_tick)
        {
            return error.InvalidActionObservation;
        }
        if (self.state == .pending and tick >= self.deadline_tick) {
            return error.ActionDispositionDeadlineExceeded;
        }
    }
};

pub fn requireStableIdentity(previous: trace.EntityRef, current: trace.EntityRef) !void {
    if (previous.namespace != current.namespace or previous.local != current.local or
        previous.incarnation != current.incarnation)
    {
        return error.UnexplainedActorIdentityChange;
    }
}

pub fn requireHorizontalSeparation(
    first: Actor,
    second: Actor,
    penetration_tolerance: f32,
) !f32 {
    if (!std.math.isFinite(penetration_tolerance) or penetration_tolerance < 0) {
        return error.InvalidSeparationTolerance;
    }
    const dx = first.position[0] - second.position[0];
    const dz = first.position[2] - second.position[2];
    const separation = @sqrt(dx * dx + dz * dz);
    if (separation + penetration_tolerance < first.radius + second.radius) {
        return error.ActorPenetrationExceeded;
    }
    return separation;
}

pub fn requireFacingTarget(
    source: Actor,
    target_position: [3]f32,
    minimum_cos: f32,
) !void {
    if (!std.math.isFinite(minimum_cos) or minimum_cos < -1 or minimum_cos > 1) {
        return error.InvalidFacingTolerance;
    }
    for (target_position) |component| {
        if (!std.math.isFinite(component)) return error.NonFiniteFacingTarget;
    }
    const dx = target_position[0] - source.position[0];
    const dz = target_position[2] - source.position[2];
    const length_squared = dx * dx + dz * dz;
    if (length_squared <= std.math.floatEps(f32)) return;
    const inverse_length = 1.0 / @sqrt(length_squared);
    const dot = (@sin(source.facing_yaw) * dx - @cos(source.facing_yaw) * dz) *
        inverse_length;
    if (dot < minimum_cos) return error.ActorFacingOutsideTolerance;
}

pub fn requireCameraOutsideActor(camera: Camera, actor: Actor, margin: f32) !void {
    try camera.validate();
    if (!std.math.isFinite(margin) or margin < 0) return error.InvalidCameraMargin;
    const dx = camera.position[0] - actor.position[0];
    const dz = camera.position[2] - actor.position[2];
    const protected_radius = actor.radius + camera.near_plane + margin;
    if (dx * dx + dz * dz < protected_radius * protected_radius) {
        return error.CameraInsideProtectedActorVolume;
    }
}

fn testActor(local: u64, position: [3]f32) Actor {
    return .{
        .entity = .{ .namespace = 1, .local = local, .incarnation = 1 },
        .alive = true,
        .authority_present = true,
        .replication_present = true,
        .presentation_present = true,
        .position = position,
        .facing_yaw = 0,
        .radius = 0.4,
    };
}

test "living continuity and identity changes are explicit" {
    var actor = testActor(1, .{ 0, 0, 0 });
    try actor.validate();
    actor.presentation_present = false;
    try std.testing.expectError(error.LivingActorMissingFromPresentation, actor.validate());
    try std.testing.expectError(
        error.UnexplainedActorIdentityChange,
        requireStableIdentity(
            .{ .namespace = 1, .local = 1, .incarnation = 1 },
            .{ .namespace = 1, .local = 1, .incarnation = 2 },
        ),
    );
}

test "contact facing camera and action deadlines are temporal invariants" {
    const first = testActor(1, .{ 0, 0, 0 });
    const second = testActor(2, .{ 0, 0, -0.8 });
    try std.testing.expectApproxEqAbs(
        @as(f32, 0.8),
        try requireHorizontalSeparation(first, second, 0.001),
        0.0001,
    );
    try requireFacingTarget(first, second.position, 0.99);
    try requireCameraOutsideActor(
        .{ .position = .{ 0, 1, 2 }, .near_plane = 0.1 },
        first,
        0.05,
    );
    try std.testing.expectError(
        error.ActionDispositionDeadlineExceeded,
        (Action{
            .correlation_id = 1,
            .submitted_tick = 5,
            .deadline_tick = 8,
            .state = .pending,
        }).validateAt(8),
    );
}
