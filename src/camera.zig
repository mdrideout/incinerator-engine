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

    // ========================================================================
    // Movement
    // ========================================================================

    /// Move the camera forward/backward along its look direction
    ///
    /// Positive amount = forward, negative = backward
    /// Movement is projected onto the XZ plane (no flying up/down)
    pub fn moveForward(self: *Camera, amount: f32) void {
        const forward = self.getForward();
        // Project onto XZ plane for ground-based movement
        const forward_xz = zm.normalize3(.{
            forward[0],
            0.0,
            forward[2],
            0.0,
        });
        self.position += forward_xz * zm.splat(zm.Vec, amount);
    }

    /// Move the camera left/right (strafe)
    ///
    /// Positive amount = right, negative = left
    pub fn moveRight(self: *Camera, amount: f32) void {
        const right = self.getRight();
        self.position += right * zm.splat(zm.Vec, amount);
    }

    /// Move the camera up/down (world Y axis)
    ///
    /// Positive amount = up, negative = down
    pub fn moveUp(self: *Camera, amount: f32) void {
        self.position += zm.f32x4(0.0, amount, 0.0, 0.0);
    }

    /// Rotate the camera based on mouse delta
    ///
    /// dx = horizontal mouse movement (pixels)
    /// dy = vertical mouse movement (pixels)
    pub fn rotate(self: *Camera, dx: f32, dy: f32) void {
        self.yaw += dx * self.look_sensitivity;
        self.pitch -= dy * self.look_sensitivity; // Inverted: moving mouse up looks up

        // Clamp pitch to prevent flipping (just under 90 degrees)
        const max_pitch = std.math.pi / 2.0 - 0.01;
        self.pitch = std.math.clamp(self.pitch, -max_pitch, max_pitch);

        // Keep yaw in reasonable range to avoid floating point issues
        if (self.yaw > std.math.pi) {
            self.yaw -= std.math.pi * 2.0;
        } else if (self.yaw < -std.math.pi) {
            self.yaw += std.math.pi * 2.0;
        }
    }

    // ========================================================================
    // Convenience
    // ========================================================================

    /// Create a camera positioned to look at the origin from a distance
    pub fn lookingAtOrigin(distance: f32) Camera {
        return Camera{
            .position = zm.f32x4(0.0, 0.0, distance, 1.0),
            .yaw = 0.0,
            .pitch = 0.0,
        };
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
