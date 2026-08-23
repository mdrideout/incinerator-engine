//! camera.zig - 3D Camera System
//!
//! DOMAIN: Scene Layer (view management)
//!
//! This module provides a first-person style camera for navigating 3D scenes.
//! It handles view and projection matrix generation, as well as movement controls.
//!
//! Responsibilities:
//! - Camera position and orientation (yaw/pitch)
//! - View matrix generation (lookAt)
//! - Projection matrix generation (perspective)
//! - Movement helpers (forward, strafe, vertical)
//!
//! The camera uses a right-handed coordinate system:
//! - +X is right
//! - +Y is up
//! - -Z is forward (into the screen)
//!
//! Yaw rotates around Y axis (looking left/right)
//! Pitch rotates around X axis (looking up/down)

const std = @import("std");
const zm = @import("zmath");

/// First-person camera with position and orientation
pub const Camera = struct {
    /// Camera position in world space
    position: zm.Vec = zm.f32x4(0.0, 0.0, 3.0, 1.0),

    /// Horizontal rotation in radians (around Y axis)
    /// 0 = looking toward -Z, positive = looking right
    yaw: f32 = 0.0,

    /// Vertical rotation in radians (around X axis)
    /// 0 = looking straight, positive = looking up
    /// Clamped to avoid gimbal lock
    pitch: f32 = 0.0,

    /// Vertical field of view in radians
    fov: f32 = std.math.pi / 4.0, // 45 degrees

    /// Near clipping plane distance
    near: f32 = 0.1,

    /// Far clipping plane distance
    far: f32 = 1000.0,

    /// Movement speed in units per second
    move_speed: f32 = 5.0,

    /// Mouse sensitivity (radians per pixel)
    look_sensitivity: f32 = 0.002,

    // ========================================================================
    // Matrix Generation
    // ========================================================================

    /// Get the camera's forward direction vector (normalized)
    pub fn getForward(self: *const Camera) zm.Vec {
        // Forward direction from yaw and pitch
        // In our coordinate system, forward is -Z when yaw=0, pitch=0
        const cos_pitch = @cos(self.pitch);
        return zm.normalize3(.{
            @sin(self.yaw) * cos_pitch,
            @sin(self.pitch),
            -@cos(self.yaw) * cos_pitch,
            0.0,
        });
    }

    /// Get the camera's right direction vector (normalized)
    pub fn getRight(self: *const Camera) zm.Vec {
        // Right is perpendicular to forward on the XZ plane
        return zm.normalize3(.{
            @cos(self.yaw),
            0.0,
            @sin(self.yaw),
            0.0,
        });
    }

    /// Get the world up vector
    pub fn getUp() zm.Vec {
        return zm.f32x4(0.0, 1.0, 0.0, 0.0);
    }

    /// Generate the view matrix (world space → camera space)
    ///
    /// The view matrix transforms world coordinates to camera-relative coordinates.
    /// This is the inverse of the camera's world transform.
    pub fn getViewMatrix(self: *const Camera) zm.Mat {
        const forward = self.getForward();
        const target = self.position + forward;
        return zm.lookAtRh(self.position, target, getUp());
    }

    /// Generate the projection matrix (camera space → clip space)
    ///
    /// Uses perspective projection with the camera's FOV settings.
    /// Aspect ratio should be window_width / window_height.
    pub fn getProjectionMatrix(self: *const Camera, aspect_ratio: f32) zm.Mat {
        return zm.perspectiveFovRh(self.fov, aspect_ratio, self.near, self.far);
    }

    /// Generate the combined view-projection matrix
    ///
    /// For a complete MVP, multiply by the model matrix:
    ///   mvp = model * view_projection
    pub fn getViewProjectionMatrix(self: *const Camera, aspect_ratio: f32) zm.Mat {
        const view = self.getViewMatrix();
        const proj = self.getProjectionMatrix(aspect_ratio);
        return zm.mul(view, proj);
    }

    /// Rotate the camera based on mouse delta
    ///
    /// dx = horizontal mouse movement (pixels)
    /// dy = vertical mouse movement (pixels)
    pub fn rotate(self: *Camera, dx: f32, dy: f32) void {
        if (!std.math.isFinite(dx) or !std.math.isFinite(dy) or
            !std.math.isFinite(self.yaw) or !std.math.isFinite(self.pitch) or
            !std.math.isFinite(self.look_sensitivity)) return;
        var yaw = self.yaw + dx * self.look_sensitivity;
        var pitch = self.pitch - dy * self.look_sensitivity;
        if (!std.math.isFinite(yaw) or !std.math.isFinite(pitch)) return;

        // Clamp pitch to prevent flipping (just under 90 degrees)
        const max_pitch = std.math.pi / 2.0 - 0.01;
        pitch = std.math.clamp(pitch, -max_pitch, max_pitch);

        // Keep yaw in reasonable range to avoid floating point issues
        if (yaw > std.math.pi) {
            yaw -= std.math.pi * 2.0;
        } else if (yaw < -std.math.pi) {
            yaw += std.math.pi * 2.0;
        }
        if (!std.math.isFinite(yaw)) return;
        self.yaw = yaw;
        self.pitch = pitch;
    }

    /// Move an editor camera in local right/up/forward space. This mutates
    /// presentation only; the caller decides whether gameplay receives input.
    pub fn moveFree(
        self: *Camera,
        local_move: [3]f32,
        delta_seconds: f32,
        fast: bool,
    ) void {
        if (!std.math.isFinite(delta_seconds) or delta_seconds <= 0 or
            !std.math.isFinite(self.move_speed) or self.move_speed <= 0) return;
        for (local_move) |value| {
            if (!std.math.isFinite(value)) return;
        }

        const forward = self.getForward();
        const right = self.getRight();
        var direction = [3]f32{
            right[0] * local_move[0] + forward[0] * local_move[2],
            local_move[1] + forward[1] * local_move[2],
            right[2] * local_move[0] + forward[2] * local_move[2],
        };
        const magnitude_squared = direction[0] * direction[0] +
            direction[1] * direction[1] + direction[2] * direction[2];
        if (!std.math.isFinite(magnitude_squared) or magnitude_squared <= 0) return;
        if (magnitude_squared > 1) {
            const inverse_magnitude = 1 / @sqrt(magnitude_squared);
            for (&direction) |*value| value.* *= inverse_magnitude;
        }

        const fast_multiplier: f32 = if (fast) 4 else 1;
        const distance = self.move_speed * fast_multiplier * delta_seconds;
        const candidate = [3]f32{
            self.position[0] + direction[0] * distance,
            self.position[1] + direction[1] * distance,
            self.position[2] + direction[2] * distance,
        };
        for (candidate) |value| {
            if (!std.math.isFinite(value)) return;
        }
        self.position = zm.f32x4(candidate[0], candidate[1], candidate[2], 1);
    }

    /// Scale editor navigation speed smoothly from wheel steps. Invalid or
    /// unrepresentable results leave the last valid authored speed unchanged.
    pub fn adjustMoveSpeed(self: *Camera, wheel_steps: f32) void {
        if (!std.math.isFinite(wheel_steps) or wheel_steps == 0 or
            !std.math.isFinite(self.move_speed) or self.move_speed <= 0) return;
        const candidate = self.move_speed * std.math.exp2(wheel_steps * 0.25);
        if (std.math.isFinite(candidate) and candidate > 0) {
            self.move_speed = candidate;
        }
    }

    /// Position this camera on an orbit behind its current yaw/pitch while
    /// continuing to look at the supplied world-space target.
    pub fn followTarget(self: *Camera, target: [3]f32, distance: f32) void {
        std.debug.assert(std.math.isFinite(distance) and distance > 0);
        const forward = self.getForward();
        self.position = zm.f32x4(
            target[0] - forward[0] * distance,
            target[1] - forward[1] * distance,
            target[2] - forward[2] * distance,
            1.0,
        );
    }

    /// Pull an already-positioned follow camera toward its target so it stays
    /// in front of the first world obstruction. `hit_fraction` is measured
    /// along target -> desired camera and is supplied by the simulation host.
    pub fn clampFollowObstruction(
        self: *Camera,
        target: [3]f32,
        desired_distance: f32,
        hit_fraction: f32,
        surface_clearance: f32,
    ) void {
        std.debug.assert(std.math.isFinite(desired_distance) and desired_distance > 0);
        std.debug.assert(std.math.isFinite(hit_fraction) and
            hit_fraction >= 0 and hit_fraction <= 1);
        std.debug.assert(std.math.isFinite(surface_clearance) and surface_clearance >= 0);
        const minimum_distance = self.near + 0.05;
        const clear_distance = @max(
            minimum_distance,
            desired_distance * hit_fraction - surface_clearance,
        );
        self.followTarget(target, @min(desired_distance, clear_distance));
    }
};

/// Shared right-button drag policy for graphical products. SDL event decoding
/// remains host-owned; camera mutation and focus-loss cancellation do not.
pub const DragLook = struct {
    active: bool = false,

    pub fn setActive(self: *DragLook, active: bool) void {
        self.active = active;
    }

    pub fn reset(self: *DragLook) void {
        self.active = false;
    }

    pub fn apply(self: *const DragLook, camera: *Camera, dx: f32, dy: f32) void {
        if (self.active) camera.rotate(dx, dy);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "camera defaults" {
    const cam = Camera{};
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), cam.yaw, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), cam.pitch, 0.001);
}

test "forward direction at yaw=0" {
    const cam = Camera{ .yaw = 0.0, .pitch = 0.0 };
    const forward = cam.getForward();
    // At yaw=0, pitch=0, forward should be -Z
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), forward[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), forward[1], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), forward[2], 0.001);
}

test "pitch clamp" {
    var cam = Camera{};
    cam.rotate(0.0, 10000.0); // Try to look way down
    try std.testing.expect(cam.pitch > -std.math.pi / 2.0);
    try std.testing.expect(cam.pitch < std.math.pi / 2.0);
}

test "free movement validates state and wheel adjusts speed" {
    var cam = Camera{ .yaw = 0, .pitch = 0, .move_speed = 5 };
    cam.moveFree(.{ 0, 0, 1 }, 1, false);
    try std.testing.expectApproxEqAbs(@as(f32, -2), cam.position[2], 0.0001);
    cam.moveFree(.{ 0, 1, 0 }, 0.5, true);
    try std.testing.expectApproxEqAbs(@as(f32, 10), cam.position[1], 0.0001);

    cam.adjustMoveSpeed(4);
    try std.testing.expectApproxEqAbs(@as(f32, 10), cam.move_speed, 0.0001);
    cam.adjustMoveSpeed(-4);
    try std.testing.expectApproxEqAbs(@as(f32, 5), cam.move_speed, 0.0001);
}

test "drag look rotates only while active and cancels cleanly" {
    var camera = Camera{};
    var look = DragLook{};
    look.apply(&camera, 100, -50);
    try std.testing.expectEqual(@as(f32, 0), camera.yaw);
    try std.testing.expectEqual(@as(f32, 0), camera.pitch);

    look.setActive(true);
    look.apply(&camera, 100, -50);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), camera.yaw, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.1), camera.pitch, 0.0001);

    look.reset();
    look.apply(&camera, 100, -50);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), camera.yaw, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.1), camera.pitch, 0.0001);
}

test "follow camera orbits behind and above its target" {
    var cam = Camera{ .yaw = 0, .pitch = -0.25 };
    cam.followTarget(.{ 2, 1, -3 }, 6);
    try std.testing.expectApproxEqAbs(@as(f32, 2), cam.position[0], 0.0001);
    try std.testing.expect(cam.position[1] > 1);
    try std.testing.expect(cam.position[2] > -3);
    const target = cam.position + cam.getForward() * zm.splat(zm.Vec, 6);
    try std.testing.expectApproxEqAbs(@as(f32, 2), target[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1), target[1], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, -3), target[2], 0.0001);
}

test "follow camera stays on target side of an obstruction" {
    var cam = Camera{ .yaw = 0, .pitch = 0 };
    const target = [3]f32{ 2, 1, -3 };
    cam.followTarget(target, 6);
    cam.clampFollowObstruction(target, 6, 0.5, 0.2);
    try std.testing.expectApproxEqAbs(@as(f32, 2), cam.position[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1), cam.position[1], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, -0.2), cam.position[2], 0.0001);
}
