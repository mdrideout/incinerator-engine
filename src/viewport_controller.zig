//! Visual-host owner for Character versus Free Camera presentation.
//!
//! This controller contains no gameplay authority and is deliberately absent
//! from snapshots, replication, replay, and persistence.

const std = @import("std");
const camera_module = @import("camera.zig");
const viewport = @import("editor/viewport.zig");

pub const Controller = struct {
    mode: viewport.Mode = .character,
    free_camera: camera_module.Camera = .{},
    free_camera_initialized: bool = false,
    last_focus: ?viewport.FocusTarget = null,

    pub fn view(self: *const Controller) viewport.View {
        return .{
            .mode = self.mode,
            .free_camera = .{
                .initialized = self.free_camera_initialized,
                .position = .{
                    self.free_camera.position[0],
                    self.free_camera.position[1],
                    self.free_camera.position[2],
                },
                .yaw = self.free_camera.yaw,
                .pitch = self.free_camera.pitch,
                .move_speed = self.free_camera.move_speed,
                .last_focus = self.last_focus,
            },
        };
    }

    pub fn activeCamera(
        self: *const Controller,
        product_camera: *const camera_module.Camera,
    ) *const camera_module.Camera {
        return if (self.mode == .free_camera and self.free_camera_initialized)
            &self.free_camera
        else
            product_camera;
    }

    pub fn activeCameraMut(
        self: *Controller,
        product_camera: *camera_module.Camera,
    ) *camera_module.Camera {
        return if (self.mode == .free_camera and self.free_camera_initialized)
            &self.free_camera
        else
            product_camera;
    }

    pub fn apply(
        self: *Controller,
        request: viewport.Request,
        product_camera: *const camera_module.Camera,
    ) void {
        switch (request) {
            .set_mode => |mode| self.setMode(mode, product_camera),
            .navigate => |navigation| {
                if (self.mode != .free_camera or !self.free_camera_initialized or
                    !navigation.hasInput()) return;
                self.free_camera.rotate(
                    navigation.look_delta[0],
                    navigation.look_delta[1],
                );
                self.free_camera.moveFree(
                    navigation.move,
                    navigation.delta_seconds,
                    navigation.fast,
                );
            },
            .adjust_speed => |steps| {
                if (self.mode == .free_camera and self.free_camera_initialized) {
                    self.free_camera.adjustMoveSpeed(steps);
                }
            },
            .frame_selection => |target| {
                if (self.mode != .free_camera or !self.free_camera_initialized or
                    !target.isValid()) return;
                const half_fov = self.free_camera.fov * 0.5;
                const tangent = @tan(half_fov);
                if (!std.math.isFinite(tangent) or tangent <= 0) return;
                const distance = target.radius / tangent + target.radius;
                if (!std.math.isFinite(distance) or distance <= 0) return;
                self.free_camera.followTarget(target.center, distance);
                self.last_focus = target;
            },
            .start_from_product_view => {
                if (self.mode == .free_camera) self.copyProductView(product_camera);
            },
        }
    }

    fn setMode(
        self: *Controller,
        mode: viewport.Mode,
        product_camera: *const camera_module.Camera,
    ) void {
        if (mode == .free_camera and !self.free_camera_initialized) {
            self.copyProductView(product_camera);
        }
        self.mode = mode;
    }

    fn copyProductView(
        self: *Controller,
        product_camera: *const camera_module.Camera,
    ) void {
        self.free_camera = product_camera.*;
        self.free_camera_initialized = true;
        self.last_focus = null;
    }
};

test "free camera initializes once and stays independent of product follow" {
    var product = camera_module.Camera{
        .position = .{ 2, 4, 9, 1 },
        .yaw = 0.4,
        .pitch = -0.2,
    };
    var controller = Controller{};
    controller.apply(.{ .set_mode = .free_camera }, &product);
    try std.testing.expect(controller.free_camera_initialized);
    try std.testing.expectEqual(@as(f32, 2), controller.free_camera.position[0]);

    controller.apply(.{ .navigate = .{
        .move = .{ 1, 0, 0 },
        .delta_seconds = 1,
    } }, &product);
    const free_position = controller.free_camera.position;
    product.followTarget(.{ 30, 2, -20 }, 9);
    try std.testing.expectEqual(free_position, controller.free_camera.position);
    try std.testing.expect(controller.activeCamera(&product) == &controller.free_camera);
}

test "returning to Character resumes the product camera" {
    var product = camera_module.Camera{ .position = .{ 0, 3, 10, 1 } };
    var controller = Controller{};
    controller.apply(.{ .set_mode = .free_camera }, &product);
    controller.apply(.{ .navigate = .{
        .move = .{ 0, 1, 0 },
        .delta_seconds = 0.5,
    } }, &product);
    controller.apply(.{ .set_mode = .character }, &product);
    product.followTarget(.{ 4, 1, -8 }, 9);
    try std.testing.expect(controller.activeCamera(&product) == &product);
    try std.testing.expect(controller.free_camera.position[1] != product.position[1]);
}
