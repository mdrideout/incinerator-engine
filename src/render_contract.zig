//! Small renderer-neutral contracts for the conventional deterministic path.
//!
//! The sandbox chooses these values and the GPU renderer transports them.
//! Neither value carries gameplay meaning, resource ownership, or backend
//! handles.

const std = @import("std");

pub const mode_name = "sdl_gpu_metal_deterministic";
pub const visual_schema_version: u16 = 1;

pub const SceneLight = struct {
    /// Normalized world-space direction from a surface toward the sun.
    sun_direction: [3]f32,
    sun_color: [3]f32,
    sun_intensity: f32,
    ambient_color: [3]f32,

    pub fn validate(self: SceneLight) !void {
        for (self.sun_direction ++ self.sun_color ++ self.ambient_color) |value| {
            if (!std.math.isFinite(value)) return error.NonFiniteSceneLight;
        }
        if (!std.math.isFinite(self.sun_intensity) or self.sun_intensity < 0) {
            return error.InvalidSceneLightIntensity;
        }
        for (self.sun_color ++ self.ambient_color) |value| {
            if (value < 0) return error.InvalidSceneLightColor;
        }
        const length_squared = self.sun_direction[0] * self.sun_direction[0] +
            self.sun_direction[1] * self.sun_direction[1] +
            self.sun_direction[2] * self.sun_direction[2];
        if (@abs(length_squared - 1) > 0.001) return error.SceneLightDirectionNotNormalized;
    }
};

pub const SurfaceMaterial = struct {
    /// Linear RGBA factor multiplied by the optional sampled base-color map.
    base_color: [4]f32,
    /// Linear additive emission. It is presentation only and emits no light.
    emissive: [3]f32 = .{ 0, 0, 0 },
    lit: bool = true,

    pub fn validate(self: SurfaceMaterial) !void {
        for (self.base_color ++ self.emissive) |value| {
            if (!std.math.isFinite(value) or value < 0) {
                return error.InvalidSurfaceMaterial;
            }
        }
    }

    pub fn tinted(color: [4]f32) SurfaceMaterial {
        return .{ .base_color = color };
    }

    pub fn unlit(color: [4]f32) SurfaceMaterial {
        return .{ .base_color = color, .lit = false };
    }
};

pub const FrameStats = struct {
    lit_product_draws: u64 = 0,
    unlit_product_draws: u64 = 0,
    debug_draws: u64 = 0,
    normal_geometry_draws: u64 = 0,
    color_geometry_draws: u64 = 0,

    pub fn productDraws(self: FrameStats) u64 {
        return self.lit_product_draws +| self.unlit_product_draws;
    }
};

test "conventional scene and material contracts reject invalid values" {
    const light = SceneLight{
        .sun_direction = .{ 0, 1, 0 },
        .sun_color = .{ 1, 0.95, 0.85 },
        .sun_intensity = 0.9,
        .ambient_color = .{ 0.18, 0.22, 0.28 },
    };
    try light.validate();
    try SurfaceMaterial.tinted(.{ 0.4, 0.5, 0.6, 1 }).validate();

    var invalid = light;
    invalid.sun_direction = .{ 1, 1, 0 };
    try std.testing.expectError(error.SceneLightDirectionNotNormalized, invalid.validate());
}
