//! Deterministic, presentation-only camera programs for neural dataset capture.
//!
//! These programs never enter authority or gameplay. They provide honest,
//! disjoint camera cohorts without pretending that a metadata label changed
//! the camera used to produce the recorded pixels.

const std = @import("std");
const camera_module = @import("../camera.zig");

pub const Program = enum {
    default_follow,
    orbit_close,
    orbit_wide,
    elevated_sweep,
};

pub fn parse(value: []const u8) !Program {
    if (std.mem.eql(u8, value, "default-follow")) return .default_follow;
    if (std.mem.eql(u8, value, "orbit-close")) return .orbit_close;
    if (std.mem.eql(u8, value, "orbit-wide")) return .orbit_wide;
    if (std.mem.eql(u8, value, "elevated-sweep")) return .elevated_sweep;
    return error.InvalidNeuralCaptureCameraPath;
}

pub fn name(program: Program) []const u8 {
    return switch (program) {
        .default_follow => "default-follow",
        .orbit_close => "orbit-close",
        .orbit_wide => "orbit-wide",
        .elevated_sweep => "elevated-sweep",
    };
}

/// Applies a deterministic camera pose after the ordinary product-follow
/// camera has selected its semantic target. `presentation_frame` is the only
/// clock, so two captures of one sequence reproduce the same path.
pub fn apply(
    program: Program,
    game_camera: *camera_module.Camera,
    target: [3]f32,
    presentation_frame: u64,
) void {
    if (program == .default_follow) return;

    const frame: f32 = @floatFromInt(presentation_frame);
    const phase = switch (program) {
        .orbit_close => frame * 0.006,
        .orbit_wide => frame * 0.0035 + 0.7,
        .elevated_sweep => frame * 0.0025 - 0.45,
        .default_follow => unreachable,
    };
    const radius: f32 = switch (program) {
        .orbit_close => 11.0,
        .orbit_wide => 24.0,
        .elevated_sweep => 18.0,
        .default_follow => unreachable,
    };
    const height: f32 = switch (program) {
        .orbit_close => 5.0,
        .orbit_wide => 10.0,
        .elevated_sweep => 18.0 + @sin(phase * 0.5) * 4.0,
        .default_follow => unreachable,
    };
    game_camera.position = .{
        target[0] + @sin(phase) * radius,
        target[1] + height,
        target[2] + @cos(phase) * radius,
        1,
    };
    lookAt(game_camera, target);
}

fn lookAt(game_camera: *camera_module.Camera, target: [3]f32) void {
    const dx = target[0] - game_camera.position[0];
    const dy = target[1] - game_camera.position[1];
    const dz = target[2] - game_camera.position[2];
    const horizontal = @sqrt(dx * dx + dz * dz);
    game_camera.yaw = std.math.atan2(dx, -dz);
    game_camera.pitch = std.math.atan2(dy, horizontal);
}

test "capture camera paths have strict names" {
    try std.testing.expectEqual(Program.default_follow, try parse("default-follow"));
    try std.testing.expectEqual(Program.elevated_sweep, try parse("elevated-sweep"));
    try std.testing.expectError(error.InvalidNeuralCaptureCameraPath, parse("metadata-only"));
}

test "orbit capture camera remains aimed at the supplied target" {
    var game_camera = camera_module.Camera{};
    const target = [3]f32{ 4, 2, -7 };
    apply(.orbit_close, &game_camera, target, 300);
    const forward = game_camera.getForward();
    const dx = target[0] - game_camera.position[0];
    const dy = target[1] - game_camera.position[1];
    const dz = target[2] - game_camera.position[2];
    const length = @sqrt(dx * dx + dy * dy + dz * dz);
    try std.testing.expectApproxEqAbs(dx / length, forward[0], 0.0001);
    try std.testing.expectApproxEqAbs(dy / length, forward[1], 0.0001);
    try std.testing.expectApproxEqAbs(dz / length, forward[2], 0.0001);
}
