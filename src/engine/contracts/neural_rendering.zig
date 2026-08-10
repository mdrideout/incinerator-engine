//! Versioned presentation-only input contract for game-specific neural rendering.
//!
//! The contract contains no authority, simulation, ECS, physics, SDL, or model
//! handles. A visual composition may derive these values only from immutable
//! presentation records that it was already allowed to draw.

const std = @import("std");

pub const schema_version: u16 = 3;
pub const schema_name = "incinerator.neural-input.v3";
pub const schema_fingerprint =
    "nr3|rgba8|160x90|paired-target-400x225|scale-5:2|appearance-srgb|depth-view-linear-0.1-250|" ++
    "normal-world|motion-prev-to-current-ndc-2|semantic-palette-v1|instance-rgb24|" ++
    "global-f32le:sun-strength,world-strength,local-light-strength,emissive-strength|" ++
    "top-left|pixel-center|reversed-y|no-jitter|exposure-1";

pub const cheap_width: u32 = 160;
pub const cheap_height: u32 = 90;
pub const target_width: u32 = 400;
pub const target_height: u32 = 225;
pub const scale_numerator: u32 = 5;
pub const scale_denominator: u32 = 2;
pub const near_plane: f32 = 0.1;
pub const far_plane: f32 = 250.0;
pub const exposure: f32 = 1.0;
pub const effect_seed: u64 = 0;
pub const global_control_schema_name = "incinerator.neural-frame-global.v1";
pub const global_control_encoding = "float32 little-endian";
pub const global_control_count: usize = 4;
pub const global_control_bytes: usize = global_control_count * @sizeOf(f32);

/// Frame-global title presentation intent. These values resolve the measured
/// NR4-C lighting/emissive ambiguity without adding another raster target.
/// They are model inputs, not authority state and not target-renderer output.
pub const FrameGlobalControls = extern struct {
    sun_strength: f32 = 0,
    world_strength: f32 = 0,
    local_light_strength: f32 = 0,
    emissive_strength: f32 = 0,

    pub fn validate(self: FrameGlobalControls) !void {
        for (self.values()) |value| {
            if (!std.math.isFinite(value)) return error.NonFiniteNeuralGlobalControl;
            if (value < 0) return error.NegativeNeuralGlobalControl;
        }
    }

    pub fn values(self: FrameGlobalControls) [global_control_count]f32 {
        return .{
            self.sun_strength,
            self.world_strength,
            self.local_light_strength,
            self.emissive_strength,
        };
    }
};

comptime {
    std.debug.assert(@sizeOf(FrameGlobalControls) == global_control_bytes);
}

/// Every channel is stored as RGBA8 so the same bytes can be sampled by the
/// editor, written losslessly, hashed, and inspected without a proprietary
/// decoder. The per-channel encoding below is the machine contract.
pub const Channel = enum(u8) {
    appearance = 0,
    linear_depth = 1,
    world_normal = 2,
    motion = 3,
    semantic = 4,
    instance = 5,
};

pub const channels = std.enums.values(Channel);

pub const SemanticClass = enum(u8) {
    background = 0,
    environment = 1,
    district = 2,
    crate = 3,
    carryable = 4,
    vehicle = 5,
    character = 6,
    npc = 7,
};

pub const SemanticPart = enum(u8) {
    whole = 0,
    vehicle_chassis = 1,
    vehicle_wheel_front_left = 2,
    vehicle_wheel_front_right = 3,
    vehicle_wheel_rear_left = 4,
    vehicle_wheel_rear_right = 5,
};

/// Presentation identity, never an authority handle. Session entities use the
/// replicated index/generation pair. Fixtures and authored content use their
/// durable public namespace/local values.
pub const Identity = union(enum) {
    fixture: u64,
    persistent: struct { namespace: u64, local: u64 },
    replicated: struct { index: u32, generation: u32 },

    pub fn stableKey(self: Identity, semantic: SemanticClass, part: SemanticPart) u64 {
        var hasher = std.hash.Wyhash.init(0x4e52_3041_4944_5631);
        hasher.update(std.mem.asBytes(&@intFromEnum(semantic)));
        hasher.update(std.mem.asBytes(&@intFromEnum(part)));
        switch (self) {
            .fixture => |value| {
                const tag: u8 = 1;
                hasher.update(std.mem.asBytes(&tag));
                hasher.update(std.mem.asBytes(&value));
            },
            .persistent => |value| {
                const tag: u8 = 2;
                hasher.update(std.mem.asBytes(&tag));
                hasher.update(std.mem.asBytes(&value.namespace));
                hasher.update(std.mem.asBytes(&value.local));
            },
            .replicated => |value| {
                const tag: u8 = 3;
                hasher.update(std.mem.asBytes(&tag));
                hasher.update(std.mem.asBytes(&value.index));
                hasher.update(std.mem.asBytes(&value.generation));
            },
        }
        return hasher.final();
    }
};

pub const DrawIdentity = struct {
    identity: Identity,
    semantic: SemanticClass,
    part: SemanticPart = .whole,
    /// Repeated presentation parts with the same semantic meaning (authored
    /// scene instances and collision proxies) use a stable source ordinal.
    ordinal: u16 = 0,

    pub fn stableKey(self: DrawIdentity) u64 {
        const base = self.identity.stableKey(self.semantic, self.part);
        var hasher = std.hash.Wyhash.init(base);
        hasher.update(std.mem.asBytes(&self.ordinal));
        return hasher.final();
    }

    /// RGB24 is the GPU-visible compact presentation code. The frame manifest
    /// records the full identity and mapping. Zero remains background.
    pub fn compactCode(self: DrawIdentity) u32 {
        const folded = self.stableKey() ^ (self.stableKey() >> 24) ^
            (self.stableKey() >> 48);
        return @as(u32, @truncate(folded)) & 0x00ff_ffff | 1;
    }
};

pub const ResetReason = enum(u8) {
    none,
    first_frame,
    resize,
    camera_cut,
    identity_reappeared,
};

pub const Frame = struct {
    authority_tick: u64,
    presentation_frame: u64,
    interpolation_alpha: f32,
    target_width: u32,
    target_height: u32,
    cheap_width: u32 = cheap_width,
    cheap_height: u32 = cheap_height,
    near: f32 = near_plane,
    far: f32 = far_plane,
    jitter_pixels: [2]f32 = .{ 0, 0 },
    exposure: f32 = exposure,
    effect_seed: u64 = effect_seed,
    global_controls: FrameGlobalControls = .{},
    history_reset: ResetReason = .none,

    pub fn validate(self: Frame) !void {
        if (self.target_width != target_width or self.target_height != target_height or
            self.cheap_width != cheap_width or self.cheap_height != cheap_height)
        {
            return error.ForeignNeuralFrameExtent;
        }
        if (!std.math.isFinite(self.interpolation_alpha) or
            self.interpolation_alpha < 0 or self.interpolation_alpha > 1)
        {
            return error.InvalidNeuralInterpolationAlpha;
        }
        if (!std.math.isFinite(self.near) or !std.math.isFinite(self.far) or
            self.near <= 0 or self.far <= self.near)
        {
            return error.InvalidNeuralDepthRange;
        }
        if (!std.math.isFinite(self.exposure) or self.exposure <= 0) {
            return error.InvalidNeuralExposure;
        }
        try self.global_controls.validate();
        if (self.jitter_pixels[0] != 0 or self.jitter_pixels[1] != 0) {
            return error.NeuralSchemaV3DoesNotSupportJitter;
        }
    }
};

/// Map a target pixel center into source pixel-index coordinates. Coordinates
/// use a top-left edge origin, so source pixel centers are at N + 0.5.
pub fn targetCenterToSourceIndexCoordinate(target_index: u32) f32 {
    const target_center = @as(f32, @floatFromInt(target_index)) + 0.5;
    return target_center * @as(f32, scale_denominator) / @as(f32, scale_numerator) - 0.5;
}

/// Exact nearest-neighbor source ownership for the rational 5:2 mapping.
pub fn nearestSourceIndex(target_index: u32, source_extent: u32) u32 {
    std.debug.assert(source_extent != 0);
    const mapped = (target_index * scale_denominator + scale_denominator / 2) /
        scale_numerator;
    return @min(mapped, source_extent - 1);
}

pub fn channelName(channel: Channel) []const u8 {
    return switch (channel) {
        .appearance => "appearance",
        .linear_depth => "linear-depth",
        .world_normal => "world-normal",
        .motion => "motion",
        .semantic => "semantic",
        .instance => "instance",
    };
}

pub fn encoding(channel: Channel) []const u8 {
    return switch (channel) {
        .appearance => "rgba8_srgb; rgb=cheap shaded color; a=coverage",
        .linear_depth => "rgba8_unorm; rgb=clamp((-view_z-near)/(far-near)); a=coverage",
        .world_normal => "rgba8_unorm; rgb=normalize(world_normal)*0.5+0.5; a=coverage",
        .motion => "rgba8_unorm; rg=clamp((current_ndc-previous_ndc)/2,-0.5,0.5)+0.5; b=history_valid; a=coverage",
        .semantic => "rgba8_unorm; rgb=semanticPaletteV1(class,part); a=coverage; class/part retained in identity manifest",
        .instance => "rgba8_unorm; rgb=little-endian nonzero compact RGB24; a=coverage; full mapping in frame manifest",
    };
}

pub fn debugEncoding(channel: Channel) []const u8 {
    return switch (channel) {
        .linear_depth => "sqrt(raw_linear_depth) contrast expansion",
        .motion => "4x signed RG motion contrast; B history validity",
        else => "raw RGB",
    };
}

/// High-contrast, exact categorical codes double as human-readable debug
/// colors. These are categorical values, never material appearance.
pub fn semanticPalette(class: SemanticClass, part: SemanticPart) [3]u8 {
    return switch (class) {
        .background => .{ 0, 0, 0 },
        .environment => .{ 128, 128, 128 },
        .district => .{ 64, 160, 255 },
        .crate => .{ 196, 96, 32 },
        .carryable => .{ 255, 220, 32 },
        .vehicle => switch (part) {
            .vehicle_chassis, .whole => .{ 32, 224, 224 },
            .vehicle_wheel_front_left => .{ 32, 96, 255 },
            .vehicle_wheel_front_right => .{ 64, 128, 255 },
            .vehicle_wheel_rear_left => .{ 96, 64, 224 },
            .vehicle_wheel_rear_right => .{ 128, 64, 224 },
        },
        .character => .{ 64, 224, 96 },
        .npc => .{ 255, 64, 64 },
    };
}

test "schema v3 frame contract rejects jitter and every foreign extent" {
    var frame = Frame{
        .authority_tick = 1,
        .presentation_frame = 2,
        .interpolation_alpha = 0.5,
        .target_width = target_width,
        .target_height = target_height,
    };
    try frame.validate();
    frame.jitter_pixels[0] = 0.25;
    try std.testing.expectError(error.NeuralSchemaV3DoesNotSupportJitter, frame.validate());
    frame.jitter_pixels = .{ 0, 0 };
    frame.target_width = 0;
    try std.testing.expectError(error.ForeignNeuralFrameExtent, frame.validate());
    frame.target_width = target_width;
    frame.cheap_width = 400;
    try std.testing.expectError(error.ForeignNeuralFrameExtent, frame.validate());
}

test "schema v3 owns an exact top-left pixel-center 160 to 400 mapping" {
    try std.testing.expectEqual(@as(u32, 5), scale_numerator);
    try std.testing.expectEqual(@as(u32, 2), scale_denominator);
    try std.testing.expectApproxEqAbs(@as(f32, -0.3), targetCenterToSourceIndexCoordinate(0), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.1), targetCenterToSourceIndexCoordinate(1), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 159.3), targetCenterToSourceIndexCoordinate(399), 1e-5);
    try std.testing.expectEqual(@as(u32, 0), nearestSourceIndex(0, cheap_width));
    try std.testing.expectEqual(@as(u32, 0), nearestSourceIndex(1, cheap_width));
    try std.testing.expectEqual(@as(u32, 1), nearestSourceIndex(2, cheap_width));
    try std.testing.expectEqual(@as(u32, 159), nearestSourceIndex(399, cheap_width));
}

test "schema v3 frame-global controls are exact finite nonnegative float32 values" {
    const controls = FrameGlobalControls{
        .sun_strength = 4,
        .world_strength = 0.32,
        .local_light_strength = 550,
        .emissive_strength = 8,
    };
    try controls.validate();
    try std.testing.expectEqual(
        [global_control_count]f32{ 4, 0.32, 550, 8 },
        controls.values(),
    );
    var invalid = controls;
    invalid.emissive_strength = -1;
    try std.testing.expectError(error.NegativeNeuralGlobalControl, invalid.validate());
    invalid.emissive_strength = std.math.nan(f32);
    try std.testing.expectError(error.NonFiniteNeuralGlobalControl, invalid.validate());
}

test "presentation identity is stable, part-sensitive, and never background" {
    const chassis = DrawIdentity{
        .identity = .{ .replicated = .{ .index = 9, .generation = 2 } },
        .semantic = .vehicle,
        .part = .vehicle_chassis,
    };
    const wheel = DrawIdentity{
        .identity = chassis.identity,
        .semantic = .vehicle,
        .part = .vehicle_wheel_front_left,
    };
    try std.testing.expectEqual(chassis.stableKey(), chassis.stableKey());
    try std.testing.expect(chassis.stableKey() != wheel.stableKey());
    try std.testing.expect(chassis.compactCode() != 0);
}

test "every channel has a stable machine name and explicit encoding" {
    try std.testing.expectEqual(@as(usize, 6), channels.len);
    for (channels) |channel| {
        try std.testing.expect(channelName(channel).len != 0);
        try std.testing.expect(encoding(channel).len != 0);
        try std.testing.expect(debugEncoding(channel).len != 0);
    }
}

test "semantic palette is high contrast and preserves vehicle parts" {
    try std.testing.expectEqual([3]u8{ 0, 0, 0 }, semanticPalette(.background, .whole));
    try std.testing.expect(!std.mem.eql(
        u8,
        &semanticPalette(.npc, .whole),
        &semanticPalette(.character, .whole),
    ));
    try std.testing.expect(!std.mem.eql(
        u8,
        &semanticPalette(.vehicle, .vehicle_chassis),
        &semanticPalette(.vehicle, .vehicle_wheel_front_left),
    ));
}
