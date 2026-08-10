//! Adapter-specific source contract for the NR-0004 offline target renderer.
//!
//! This is presentation data, not an authority or model-input schema. It is
//! deliberately local to the host/tool boundary until a second target producer
//! demonstrates that a general interchange format is useful.

const std = @import("std");

pub const schema_version: u16 = 4;
pub const schema_name = "incinerator.nr4.blender-target-frame.v4";
pub const input_width: u32 = 160;
pub const input_height: u32 = 90;
pub const target_width: u32 = 400;
pub const target_height: u32 = 225;
pub const scale_numerator: u32 = 5;
pub const scale_denominator: u32 = 2;

pub const Shape = enum {
    box,
    wheel_x,
    capsule_y,
};

pub const Material = enum {
    asphalt,
    sidewalk,
    masonry,
    painted_metal,
    rubber,
    glass,
    emissive,
    fabric,
    skin,
    cardboard,
};

pub const Pattern = enum {
    none,
    noise,
    brick,
};

/// Explicit offline-target material intent. These values are not part of the
/// runtime neural-input ABI; NR4-C will decide which observed ambiguities need
/// deterministic model inputs. Keeping them in the target package prevents
/// the Blender script from silently owning title art direction.
pub const MaterialResponse = struct {
    roughness: f32,
    metallic: f32 = 0,
    transmission: f32 = 0,
    ior: f32 = 1.45,
    emission_strength: f32 = 0,
    sheen: f32 = 0,
    subsurface: f32 = 0,
    pattern: Pattern = .none,
    pattern_scale: f32 = 1,
    pattern_detail: f32 = 0,
    bump_strength: f32 = 0,
    bump_distance: f32 = 0,

    pub fn validate(self: MaterialResponse) !void {
        for ([11]f32{
            self.roughness,
            self.metallic,
            self.transmission,
            self.ior,
            self.emission_strength,
            self.sheen,
            self.subsurface,
            self.pattern_scale,
            self.pattern_detail,
            self.bump_strength,
            self.bump_distance,
        }) |value| {
            if (!std.math.isFinite(value)) return error.NonFiniteNeuralTargetMaterial;
        }
        if (self.roughness < 0 or self.roughness > 1 or
            self.metallic < 0 or self.metallic > 1 or
            self.transmission < 0 or self.transmission > 1 or
            self.ior < 1 or self.emission_strength < 0 or
            self.sheen < 0 or self.sheen > 1 or
            self.subsurface < 0 or self.subsurface > 1 or
            self.pattern_scale <= 0 or self.pattern_detail < 0 or
            self.bump_strength < 0 or self.bump_distance < 0)
        {
            return error.InvalidNeuralTargetMaterial;
        }
    }
};

pub const Transform = struct {
    scale: [3]f32,
    rotation_xyz: [3]f32 = .{ 0, 0, 0 },
    translation: [3]f32,

    pub fn validate(self: Transform) !void {
        for (self.scale) |value| if (!std.math.isFinite(value) or value <= 0) {
            return error.InvalidNeuralTargetScale;
        };
        for (self.rotation_xyz ++ self.translation) |value| {
            if (!std.math.isFinite(value)) return error.NonFiniteNeuralTargetTransform;
        }
    }
};

pub const Source = struct {
    label: []const u8,
    shape: Shape,
    material: Material,
    material_response: MaterialResponse,
    transform: Transform,

    pub fn validate(self: Source) !void {
        if (self.label.len == 0) return error.NeuralTargetLabelRequired;
        try self.material_response.validate();
        try self.transform.validate();
    }
};

pub const Scene = struct {
    id: []const u8,
    fingerprint: []const u8,
    sun_direction: [3]f32,
    sun_color: [3]f32,
    sun_strength: f32,
    sun_angle_radians: f32,
    world_color: [3]f32,
    world_strength: f32,
    local_light_position: [3]f32,
    local_light_color: [3]f32,
    local_light_strength: f32,
    local_light_radius: f32,

    pub fn validate(self: Scene) !void {
        if (self.id.len == 0 or self.fingerprint.len == 0) {
            return error.NeuralTargetSceneIdentityRequired;
        }
        for (self.sun_direction ++ self.sun_color ++ self.world_color ++
            self.local_light_position ++ self.local_light_color ++
            .{
                self.sun_strength,
                self.sun_angle_radians,
                self.world_strength,
                self.local_light_strength,
                self.local_light_radius,
            }) |value|
        {
            if (!std.math.isFinite(value)) return error.NonFiniteNeuralTargetLighting;
        }
        const direction_length_squared = self.sun_direction[0] * self.sun_direction[0] +
            self.sun_direction[1] * self.sun_direction[1] +
            self.sun_direction[2] * self.sun_direction[2];
        if (direction_length_squared < 0.999 or direction_length_squared > 1.001 or
            self.sun_strength <= 0 or self.sun_angle_radians <= 0 or
            self.world_strength < 0 or self.local_light_strength < 0 or
            self.local_light_radius <= 0)
        {
            return error.InvalidNeuralTargetLighting;
        }
    }
};

pub const SequenceSegment = enum {
    still,
    camera_motion,
    object_motion,
    near_edge,
    wheel_articulation,
    occlusion_disocclusion,
    lighting_effect,
};

pub const SequenceEvent = struct {
    segment: SequenceSegment,
    segment_index: u8,
    sample_index: u8,
    progress: f32,
    reset: bool,
    controlled_change: []const u8,

    pub fn validate(self: SequenceEvent) !void {
        if (self.controlled_change.len == 0 or !std.math.isFinite(self.progress) or
            self.progress < 0 or self.progress > 1)
        {
            return error.InvalidNeuralTargetSequenceEvent;
        }
    }
};

pub const Camera = struct {
    position: [3]f32,
    forward: [3]f32,
    up: [3]f32,
    vertical_fov_radians: f32,

    pub fn validate(self: Camera) !void {
        for (self.position ++ self.forward ++ self.up ++ .{self.vertical_fov_radians}) |value| {
            if (!std.math.isFinite(value)) return error.NonFiniteNeuralTargetCamera;
        }
        if (self.vertical_fov_radians <= 0 or self.vertical_fov_radians >= std.math.pi) {
            return error.InvalidNeuralTargetCamera;
        }
    }
};

test "target source contract rejects ambiguous or non-finite values" {
    const valid = Source{
        .label = "road",
        .shape = .box,
        .material = .asphalt,
        .material_response = .{ .roughness = 0.8 },
        .transform = .{ .scale = .{ 4, 0.2, 8 }, .translation = .{ 0, 0, 0 } },
    };
    try valid.validate();
    var invalid = valid;
    invalid.transform.scale[0] = 0;
    try std.testing.expectError(error.InvalidNeuralTargetScale, invalid.validate());
}

test "target scene requires a normalized sun direction" {
    var scene = Scene{
        .id = "urban-corner",
        .fingerprint = "fixture-v1",
        .sun_direction = .{ 0, -1, 0 },
        .sun_color = .{ 1, 1, 1 },
        .sun_strength = 3,
        .sun_angle_radians = 0.1,
        .world_color = .{ 0.1, 0.2, 0.3 },
        .world_strength = 0.3,
        .local_light_position = .{ 0, 2, 0 },
        .local_light_color = .{ 1, 0.8, 0.5 },
        .local_light_strength = 20,
        .local_light_radius = 0.5,
    };
    try scene.validate();
    scene.sun_direction = .{ 0, -2, 0 };
    try std.testing.expectError(error.InvalidNeuralTargetLighting, scene.validate());
}
