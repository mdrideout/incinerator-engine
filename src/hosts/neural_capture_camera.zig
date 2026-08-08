//! Deterministic, presentation-only camera programs for neural dataset capture.
//!
//! These programs never enter authority or gameplay. They provide honest,
//! disjoint camera cohorts without pretending that a metadata label changed
//! the camera used to produce the recorded pixels.

const std = @import("std");
const camera_module = @import("../camera.zig");
const contract = @import("incinerator_engine").neural_rendering;

pub const Program = enum {
    default_follow,
    orbit_close,
    orbit_wide,
    elevated_sweep,
    near_pass,
    fast_orbit,
    disocclusion_sweep,
    camera_cut,
    top_down,
    resize_cycle,
};

pub fn parse(value: []const u8) !Program {
    if (std.mem.eql(u8, value, "default-follow")) return .default_follow;
    if (std.mem.eql(u8, value, "orbit-close")) return .orbit_close;
    if (std.mem.eql(u8, value, "orbit-wide")) return .orbit_wide;
    if (std.mem.eql(u8, value, "elevated-sweep")) return .elevated_sweep;
    if (std.mem.eql(u8, value, "near-pass")) return .near_pass;
    if (std.mem.eql(u8, value, "fast-orbit")) return .fast_orbit;
    if (std.mem.eql(u8, value, "disocclusion-sweep")) return .disocclusion_sweep;
    if (std.mem.eql(u8, value, "camera-cut")) return .camera_cut;
    if (std.mem.eql(u8, value, "top-down")) return .top_down;
    if (std.mem.eql(u8, value, "resize-cycle")) return .resize_cycle;
    return error.InvalidNeuralCaptureCameraPath;
}

pub fn name(program: Program) []const u8 {
    return switch (program) {
        .default_follow => "default-follow",
        .orbit_close => "orbit-close",
        .orbit_wide => "orbit-wide",
        .elevated_sweep => "elevated-sweep",
        .near_pass => "near-pass",
        .fast_orbit => "fast-orbit",
        .disocclusion_sweep => "disocclusion-sweep",
        .camera_cut => "camera-cut",
        .top_down => "top-down",
        .resize_cycle => "resize-cycle",
    };
}

pub const ResizeRequest = struct {
    width: i32,
    height: i32,
};

/// The resize stress path changes the real product window at exact recorded
/// frames. Returning only event frames keeps retries idempotent in the app.
pub fn resizeRequest(program: Program, presentation_frame: u64) ?ResizeRequest {
    if (program != .resize_cycle) return null;
    return switch (presentation_frame) {
        120 => .{ .width = 1280, .height = 720 },
        180 => .{ .width = 1440, .height = 900 },
        240 => .{ .width = 1600, .height = 900 },
        else => null,
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
) contract.ResetReason {
    if (program == .default_follow) return .none;

    const frame: f32 = @floatFromInt(presentation_frame);
    if (program == .camera_cut) {
        const pose_index = (presentation_frame / 60) % 4;
        game_camera.position = switch (pose_index) {
            0 => .{ target[0] - 13, target[1] + 4, target[2] + 15, 1 },
            1 => .{ target[0] + 16, target[1] + 7, target[2] + 8, 1 },
            2 => .{ target[0] + 5, target[1] + 15, target[2] - 14, 1 },
            else => .{ target[0] - 18, target[1] + 9, target[2] - 6, 1 },
        };
        lookAt(game_camera, target);
        return if (presentation_frame != 0 and presentation_frame % 60 == 0)
            .camera_cut
        else
            .none;
    }
    if (program == .top_down) {
        const phase = frame * 0.002;
        game_camera.position = .{
            target[0] + @sin(phase) * 4,
            target[1] + 38,
            target[2] + @cos(phase) * 4,
            1,
        };
        lookAt(game_camera, target);
        return .none;
    }
    if (program == .near_pass) {
        const cycle = @mod(frame, 240.0) / 240.0;
        game_camera.position = .{
            target[0] - 10 + cycle * 20,
            target[1] + 1.1,
            target[2] + 2.2,
            1,
        };
        lookAt(game_camera, .{ target[0], target[1] + 0.8, target[2] - 3.2 });
        return .none;
    }
    if (program == .disocclusion_sweep) {
        const phase = frame * 0.014;
        game_camera.position = .{
            target[0] + @sin(phase) * 20,
            target[1] + 5.5,
            target[2] + 17,
            1,
        };
        lookAt(game_camera, target);
        return .none;
    }
    const phase = switch (program) {
        .orbit_close => frame * 0.006,
        .orbit_wide => frame * 0.0035 + 0.7,
        .elevated_sweep => frame * 0.0025 - 0.45,
        .fast_orbit => frame * 0.028,
        .resize_cycle => frame * 0.006 + 0.25,
        .default_follow => unreachable,
        .near_pass, .disocclusion_sweep, .camera_cut, .top_down => unreachable,
    };
    const radius: f32 = switch (program) {
        .orbit_close => 11.0,
        .orbit_wide => 24.0,
        .elevated_sweep => 18.0,
        .fast_orbit => 18.0,
        .resize_cycle => 20.0,
        .default_follow => unreachable,
        .near_pass, .disocclusion_sweep, .camera_cut, .top_down => unreachable,
    };
    const height: f32 = switch (program) {
        .orbit_close => 5.0,
        .orbit_wide => 10.0,
        .elevated_sweep => 18.0 + @sin(phase * 0.5) * 4.0,
        .fast_orbit => 6.0,
        .resize_cycle => 7.0,
        .default_follow => unreachable,
        .near_pass, .disocclusion_sweep, .camera_cut, .top_down => unreachable,
    };
    game_camera.position = .{
        target[0] + @sin(phase) * radius,
        target[1] + height,
        target[2] + @cos(phase) * radius,
        1,
    };
    lookAt(game_camera, target);
    return .none;
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
    try std.testing.expectEqual(Program.camera_cut, try parse("camera-cut"));
    try std.testing.expectEqual(Program.resize_cycle, try parse("resize-cycle"));
    try std.testing.expectError(error.InvalidNeuralCaptureCameraPath, parse("metadata-only"));
}

test "orbit capture camera remains aimed at the supplied target" {
    var game_camera = camera_module.Camera{};
    const target = [3]f32{ 4, 2, -7 };
    try std.testing.expectEqual(contract.ResetReason.none, apply(.orbit_close, &game_camera, target, 300));
    const forward = game_camera.getForward();
    const dx = target[0] - game_camera.position[0];
    const dy = target[1] - game_camera.position[1];
    const dz = target[2] - game_camera.position[2];
    const length = @sqrt(dx * dx + dy * dy + dz * dz);
    try std.testing.expectApproxEqAbs(dx / length, forward[0], 0.0001);
    try std.testing.expectApproxEqAbs(dy / length, forward[1], 0.0001);
    try std.testing.expectApproxEqAbs(dz / length, forward[2], 0.0001);
}

test "camera cuts and resize requests are explicit events" {
    var game_camera = camera_module.Camera{};
    try std.testing.expectEqual(
        contract.ResetReason.none,
        apply(.camera_cut, &game_camera, .{ 0, 0, 0 }, 59),
    );
    try std.testing.expectEqual(
        contract.ResetReason.camera_cut,
        apply(.camera_cut, &game_camera, .{ 0, 0, 0 }, 60),
    );
    try std.testing.expectEqual(@as(?ResizeRequest, null), resizeRequest(.orbit_close, 120));
    try std.testing.expectEqual(@as(i32, 1280), resizeRequest(.resize_cycle, 120).?.width);
    try std.testing.expectEqual(@as(i32, 1600), resizeRequest(.resize_cycle, 240).?.width);
}
