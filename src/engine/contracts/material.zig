//! Renderer-neutral conventional material values. Game assets supply values;
//! renderers evaluate them and tooling authors them through a concrete owner.
const std = @import("std");

pub const Parameters = struct {
    base_color: [4]f32 = .{ 1, 1, 1, 1 },
    metallic: f32 = 0,
    roughness: f32 = 1,
    normal_scale: f32 = 1,
    occlusion_strength: f32 = 1,
    emissive: [3]f32 = .{ 0, 0, 0 },

    pub fn validate(self: Parameters) !void {
        for (self.base_color ++ .{ self.metallic, self.roughness, self.occlusion_strength }) |value| {
            if (!std.math.isFinite(value) or value < 0 or value > 1) return error.InvalidMaterialFactor;
        }
        if (!std.math.isFinite(self.normal_scale) or self.normal_scale < 0) return error.InvalidNormalScale;
        for (self.emissive) |value| {
            if (!std.math.isFinite(value) or value < 0) return error.InvalidMaterialEmission;
        }
    }
};

pub const TextureSlot = enum { base_color, metallic_roughness, normal, occlusion, emissive };

pub fn isColor(slot: TextureSlot) bool {
    return slot == .base_color or slot == .emissive;
}

test "material parameters preserve physical domains and finite emission without an arbitrary HDR ceiling" {
    try (Parameters{ .metallic = 1, .roughness = 0, .emissive = .{ 40, 2, 0 } }).validate();
    try std.testing.expectError(error.InvalidMaterialFactor, (Parameters{ .roughness = -0.1 }).validate());
    try std.testing.expectError(error.InvalidMaterialFactor, (Parameters{ .metallic = std.math.nan(f32) }).validate());
    try std.testing.expectError(error.InvalidNormalScale, (Parameters{ .normal_scale = -1 }).validate());
    try std.testing.expectError(error.InvalidMaterialEmission, (Parameters{ .emissive = .{ 0, std.math.inf(f32), 0 } }).validate());
    try std.testing.expect(isColor(.base_color) and isColor(.emissive));
    try std.testing.expect(!isColor(.normal) and !isColor(.metallic_roughness) and !isColor(.occlusion));
}
