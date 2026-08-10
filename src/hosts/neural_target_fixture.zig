//! Rights-clean, presentation-only NR-0004 urban-corner target fixture.
//!
//! The same immutable plans drive the cheap product draw, neural inputs, and
//! offline target-frame package. Blender consumes the package; it never
//! reconstructs or advances gameplay.

const std = @import("std");
const contract = @import("incinerator_engine").neural_rendering;
const target = @import("neural_target_contract.zig");

pub const source_fingerprint =
    "nr4-urban-corner-v3|road-sidewalk-masonry-glass-sign|vehicle-four-wheels|" ++
    "character-npc-prop|thin-bollards|declared-material-light-responses|" ++
    "frame-global-sun-world-local-emissive-controls|six-causal-motion-segments|" ++
    "rights-clean-procedural";
pub const center = [3]f32{ 26, 2.6, 0 };
pub const fixture_identity_base: u64 = 0x4e52_3400_0000_0000;
pub const sequence_start_frame: u64 = 240;
pub const sequence_frame_stride: u64 = 8;
pub const samples_per_segment: u8 = 3;
pub const segment_count: u8 = 6;
pub const sequence_frame_count: u64 = samples_per_segment * segment_count;
pub const segment_frame_span: u64 = sequence_frame_stride * samples_per_segment;

pub const scene = target.Scene{
    .id = "nr4-urban-corner-v3",
    .fingerprint = source_fingerprint,
    .sun_direction = .{ -0.4082483, -0.8164966, -0.4082483 },
    .sun_color = .{ 1.0, 0.91, 0.78 },
    .sun_strength = 4.0,
    .sun_angle_radians = 0.08,
    .world_color = .{ 0.055, 0.09, 0.16 },
    .world_strength = 0.32,
    .local_light_position = .{ center[0] - 6.55, 5.35, -6.6 },
    .local_light_color = .{ 1.0, 0.58, 0.18 },
    .local_light_strength = 550,
    .local_light_radius = 1.1,
};

pub fn contentDigest() [32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(source_fingerprint);
    var result: [32]u8 = undefined;
    hasher.final(&result);
    return result;
}

pub const MeshKind = enum { cube, wheel, capsule };

pub const Draw = struct {
    identity: contract.DrawIdentity,
    mesh: MeshKind,
    base_color: [4]f32,
    target_source: target.Source,
};

pub const draw_count = 26;

pub fn plans(presentation_frame: u64) [draw_count]Draw {
    var result = basePlans();
    const state = sequenceState(presentation_frame);
    switch (state.event.segment) {
        .object_motion => translateVehicle(&result, .{
            -2.2 * state.event.progress,
            0,
            2.4 * state.event.progress,
        }),
        .wheel_articulation => articulateWheels(&result, state.event.progress),
        .occlusion_disocclusion => {
            const translation = &result[19].target_source.transform.translation;
            translation[0] = center[0] + 6.0 - 8.0 * state.event.progress;
            translation[2] = -2.6 - 2.7 * state.event.progress;
        },
        .lighting_effect => {
            const strength = state.global_controls.emissive_strength;
            result[6].target_source.material_response.emission_strength = strength;
            result[9].target_source.material_response.emission_strength = strength * 0.75;
        },
        else => {},
    }
    return result;
}

fn basePlans() [draw_count]Draw {
    return .{
        plan(1, .environment, .whole, "road", .cube, .asphalt, .{ 18, 0.18, 13 }, .{ center[0], 0.09, 0 }, .{ 0.10, 0.11, 0.12, 1 }),
        plan(2, .environment, .whole, "sidewalk", .cube, .sidewalk, .{ 18, 0.28, 4.0 }, .{ center[0], 0.23, -8.5 }, .{ 0.52, 0.54, 0.56, 1 }),
        plan(3, .environment, .whole, "building", .cube, .masonry, .{ 17, 8.0, 3.5 }, .{ center[0], 4.35, -11.2 }, .{ 0.48, 0.24, 0.15, 1 }),
        plan(4, .environment, .whole, "storefront-glass-left", .cube, .glass, .{ 5.8, 4.2, 0.12 }, .{ center[0] - 5.0, 2.65, -9.38 }, .{ 0.22, 0.48, 0.68, 1 }),
        plan(5, .environment, .whole, "storefront-glass-right", .cube, .glass, .{ 5.8, 4.2, 0.12 }, .{ center[0] + 5.0, 2.65, -9.38 }, .{ 0.22, 0.48, 0.68, 1 }),
        plan(6, .environment, .whole, "storefront-divider", .cube, .painted_metal, .{ 0.28, 4.5, 0.28 }, .{ center[0], 2.75, -9.2 }, .{ 0.08, 0.09, 0.11, 1 }),
        plan(7, .environment, .whole, "emissive-sign", .cube, .emissive, .{ 7.5, 1.15, 0.32 }, .{ center[0], 6.25, -9.1 }, .{ 1.0, 0.10, 0.03, 1 }),
        plan(8, .environment, .whole, "awning", .cube, .painted_metal, .{ 10.0, 0.22, 1.6 }, .{ center[0], 5.15, -8.6 }, .{ 0.04, 0.14, 0.27, 1 }),
        plan(9, .environment, .whole, "lamp-post", .cube, .painted_metal, .{ 0.20, 5.2, 0.20 }, .{ center[0] - 7.0, 2.88, -6.9 }, .{ 0.05, 0.06, 0.07, 1 }),
        plan(10, .environment, .whole, "lamp-head", .cube, .emissive, .{ 1.25, 0.28, 0.55 }, .{ center[0] - 6.55, 5.55, -6.9 }, .{ 1.0, 0.72, 0.25, 1 }),
        plan(11, .environment, .whole, "bollard-left", .cube, .painted_metal, .{ 0.24, 1.5, 0.24 }, .{ center[0] - 3.4, 1.02, -6.0 }, .{ 0.82, 0.08, 0.04, 1 }),
        plan(12, .environment, .whole, "bollard-right", .cube, .painted_metal, .{ 0.24, 1.5, 0.24 }, .{ center[0] + 3.4, 1.02, -6.0 }, .{ 0.82, 0.08, 0.04, 1 }),

        plan(13, .vehicle, .vehicle_chassis, "vehicle-chassis", .cube, .painted_metal, .{ 4.4, 1.35, 2.15 }, .{ center[0] - 2.0, 1.25, 1.0 }, .{ 0.04, 0.35, 0.62, 1 }),
        plan(14, .vehicle, .vehicle_chassis, "vehicle-cabin", .cube, .glass, .{ 2.2, 1.15, 1.85 }, .{ center[0] - 2.0, 2.35, 0.85 }, .{ 0.16, 0.34, 0.46, 1 }),
        wheel(15, .vehicle_wheel_front_left, "wheel-front-left", .{ center[0] - 3.4, 0.72, 0.05 }),
        wheel(16, .vehicle_wheel_front_right, "wheel-front-right", .{ center[0] - 3.4, 0.72, 1.95 }),
        wheel(17, .vehicle_wheel_rear_left, "wheel-rear-left", .{ center[0] - 0.6, 0.72, 0.05 }),
        wheel(18, .vehicle_wheel_rear_right, "wheel-rear-right", .{ center[0] - 0.6, 0.72, 1.95 }),

        capsule(19, .character, "character", .fabric, .{ center[0] + 3.1, 0.28, -1.2 }, .{ 0.10, 0.48, 0.78, 1 }),
        capsule(20, .npc, "npc", .fabric, .{ center[0] + 6.0, 0.28, -2.6 }, .{ 0.72, 0.16, 0.08, 1 }),
        plan(21, .carryable, .whole, "carryable", .cube, .cardboard, .{ 0.75, 0.75, 0.75 }, .{ center[0] + 4.8, 0.66, 1.3 }, .{ 0.62, 0.38, 0.16, 1 }),
        plan(22, .crate, .whole, "crate", .cube, .cardboard, .{ 1.25, 1.25, 1.25 }, .{ center[0] + 7.6, 0.91, 2.7 }, .{ 0.48, 0.27, 0.10, 1 }),

        plan(23, .environment, .whole, "crosswalk-a", .cube, .sidewalk, .{ 2.2, 0.025, 0.58 }, .{ center[0] - 6.0, 0.205, 5.0 }, .{ 0.82, 0.84, 0.80, 1 }),
        plan(24, .environment, .whole, "crosswalk-b", .cube, .sidewalk, .{ 2.2, 0.025, 0.58 }, .{ center[0] - 2.0, 0.205, 5.0 }, .{ 0.82, 0.84, 0.80, 1 }),
        plan(25, .environment, .whole, "crosswalk-c", .cube, .sidewalk, .{ 2.2, 0.025, 0.58 }, .{ center[0] + 2.0, 0.205, 5.0 }, .{ 0.82, 0.84, 0.80, 1 }),
        plan(26, .environment, .whole, "crosswalk-d", .cube, .sidewalk, .{ 2.2, 0.025, 0.58 }, .{ center[0] + 6.0, 0.205, 5.0 }, .{ 0.82, 0.84, 0.80, 1 }),
    };
}

pub const SequenceState = struct {
    event: target.SequenceEvent,
    scene: target.Scene,
    global_controls: contract.FrameGlobalControls,
};

pub fn sequenceState(presentation_frame: u64) SequenceState {
    var event = target.SequenceEvent{
        .segment = .still,
        .segment_index = 0,
        .sample_index = 0,
        .progress = 0,
        .reset = false,
        .controlled_change = "none; accepted NR4-A still state",
    };
    if (presentation_frame >= sequence_start_frame and
        presentation_frame < sequence_start_frame + segment_frame_span * segment_count)
    {
        const relative = presentation_frame - sequence_start_frame;
        const segment_index: u8 = @intCast(relative / segment_frame_span);
        const frame_in_segment = relative % segment_frame_span;
        const sample_index: u8 = @intCast(@min(
            frame_in_segment / sequence_frame_stride,
            samples_per_segment - 1,
        ));
        event = .{
            .segment = segmentForIndex(segment_index),
            .segment_index = segment_index,
            .sample_index = sample_index,
            .progress = @as(f32, @floatFromInt(@min(
                frame_in_segment,
                sequence_frame_stride * (samples_per_segment - 1),
            ))) / @as(f32, @floatFromInt(sequence_frame_stride * (samples_per_segment - 1))),
            .reset = frame_in_segment == 0,
            .controlled_change = controlledChange(segment_index),
        };
    }
    var frame_scene = scene;
    var global_controls = contract.FrameGlobalControls{
        .sun_strength = frame_scene.sun_strength,
        .world_strength = frame_scene.world_strength,
        .local_light_strength = frame_scene.local_light_strength,
        .emissive_strength = 8,
    };
    if (event.segment == .lighting_effect) {
        frame_scene.sun_strength = 4.0 - 1.5 * event.progress;
        frame_scene.world_strength = 0.32 - 0.12 * event.progress;
        frame_scene.local_light_strength = 550 + 1_650 * event.progress;
        global_controls.sun_strength = frame_scene.sun_strength;
        global_controls.world_strength = frame_scene.world_strength;
        global_controls.local_light_strength = frame_scene.local_light_strength;
        global_controls.emissive_strength = 2.0 + 10.0 * event.progress;
    }
    return .{
        .event = event,
        .scene = frame_scene,
        .global_controls = global_controls,
    };
}

fn segmentForIndex(index: u8) target.SequenceSegment {
    return switch (index) {
        0 => .camera_motion,
        1 => .object_motion,
        2 => .near_edge,
        3 => .wheel_articulation,
        4 => .occlusion_disocclusion,
        5 => .lighting_effect,
        else => unreachable,
    };
}

fn controlledChange(index: u8) []const u8 {
    return switch (index) {
        0 => "camera pose only; all object and light state fixed",
        1 => "rigid vehicle translation only; camera, articulation, and light state fixed",
        2 => "near-edge camera translation only; all object and light state fixed",
        3 => "vehicle wheel roll and front steering only; chassis, camera, and lights fixed",
        4 => "NPC translation through occlusion only; camera and all other object/light state fixed",
        5 => "sun/world/local/emissive response only; camera and object transforms fixed",
        else => unreachable,
    };
}

fn translateVehicle(draws: *[draw_count]Draw, offset: [3]f32) void {
    for (draws[12..18]) |*draw| {
        for (0..3) |axis| draw.target_source.transform.translation[axis] += offset[axis];
    }
}

fn articulateWheels(draws: *[draw_count]Draw, progress: f32) void {
    const roll = progress * std.math.tau * 1.5;
    const steer = (progress * 2.0 - 1.0) * 0.42;
    for (draws[14..18], 0..) |*draw, index| {
        draw.target_source.transform.rotation_xyz[0] = roll;
        if (index < 2) draw.target_source.transform.rotation_xyz[1] = steer;
    }
}

fn plan(
    ordinal: u16,
    semantic: contract.SemanticClass,
    part: contract.SemanticPart,
    label: []const u8,
    mesh: MeshKind,
    material: target.Material,
    scale: [3]f32,
    translation: [3]f32,
    base_color: [4]f32,
) Draw {
    return .{
        .identity = identity(ordinal, semantic, part),
        .mesh = mesh,
        .base_color = base_color,
        .target_source = .{
            .label = label,
            .shape = switch (mesh) {
                .cube => .box,
                .wheel => .wheel_x,
                .capsule => .capsule_y,
            },
            .material = material,
            .material_response = materialResponse(material),
            .transform = .{ .scale = scale, .translation = translation },
        },
    };
}

fn materialResponse(material: target.Material) target.MaterialResponse {
    return switch (material) {
        .asphalt => .{ .roughness = 0.86, .pattern = .noise, .pattern_scale = 34, .pattern_detail = 7, .bump_strength = 0.22, .bump_distance = 0.08 },
        .sidewalk => .{ .roughness = 0.72, .pattern = .noise, .pattern_scale = 18, .pattern_detail = 4, .bump_strength = 0.16, .bump_distance = 0.05 },
        .masonry => .{ .roughness = 0.78, .pattern = .brick, .pattern_scale = 7, .bump_strength = 0.32, .bump_distance = 0.06 },
        .painted_metal => .{ .roughness = 0.24, .metallic = 0.72, .pattern = .noise, .pattern_scale = 48, .pattern_detail = 3, .bump_strength = 0.08, .bump_distance = 0.02 },
        .rubber => .{ .roughness = 0.68, .pattern = .noise, .pattern_scale = 58, .pattern_detail = 5, .bump_strength = 0.25, .bump_distance = 0.025 },
        .glass => .{ .roughness = 0.08, .transmission = 0.72, .ior = 1.45 },
        .emissive => .{ .roughness = 0.22, .emission_strength = 8 },
        .fabric => .{ .roughness = 0.9, .sheen = 0.28, .pattern = .noise, .pattern_scale = 95, .pattern_detail = 2, .bump_strength = 0.12, .bump_distance = 0.012 },
        .skin => .{ .roughness = 0.52, .subsurface = 0.08 },
        .cardboard => .{ .roughness = 0.84, .pattern = .noise, .pattern_scale = 42, .pattern_detail = 3, .bump_strength = 0.15, .bump_distance = 0.018 },
    };
}

fn wheel(ordinal: u16, part: contract.SemanticPart, label: []const u8, translation: [3]f32) Draw {
    return plan(
        ordinal,
        .vehicle,
        part,
        label,
        .wheel,
        .rubber,
        .{ 0.48, 1.05, 1.05 },
        translation,
        .{ 0.07, 0.08, 0.09, 1 },
    );
}

fn capsule(
    ordinal: u16,
    semantic: contract.SemanticClass,
    label: []const u8,
    material: target.Material,
    translation: [3]f32,
    color: [4]f32,
) Draw {
    return plan(
        ordinal,
        semantic,
        .whole,
        label,
        .capsule,
        material,
        .{ 1.0, 1.0, 1.0 },
        translation,
        color,
    );
}

fn identity(
    ordinal: u16,
    semantic: contract.SemanticClass,
    part: contract.SemanticPart,
) contract.DrawIdentity {
    return .{
        .identity = .{ .fixture = fixture_identity_base + ordinal },
        .semantic = semantic,
        .part = part,
    };
}

test "NR4 target fixture has unique stable identities and complete target sources" {
    try scene.validate();
    const draws = plans(120);
    try std.testing.expectEqual(@as(usize, draw_count), draws.len);
    for (draws, 0..) |draw, index| {
        try draw.target_source.validate();
        for (draws[index + 1 ..]) |other| {
            try std.testing.expect(draw.identity.stableKey() != other.identity.stableKey());
        }
    }
}

test "NR4 target fixture contains the required semantic product slice" {
    var character = false;
    var npc = false;
    var vehicle_parts: usize = 0;
    var prop = false;
    for (plans(120)) |draw| switch (draw.identity.semantic) {
        .character => character = true,
        .npc => npc = true,
        .vehicle => vehicle_parts += 1,
        .carryable, .crate => prop = true,
        else => {},
    };
    try std.testing.expect(character and npc and prop);
    try std.testing.expectEqual(@as(usize, 6), vehicle_parts);
}

test "NR4-B sequence isolates one authored cause per segment" {
    var previous_segment: ?target.SequenceSegment = null;
    for (0..sequence_frame_count) |index| {
        const frame = sequence_start_frame + index * sequence_frame_stride;
        const state = sequenceState(frame);
        try state.event.validate();
        try state.scene.validate();
        const expected_segment: u8 = @intCast(index / samples_per_segment);
        const expected_sample: u8 = @intCast(index % samples_per_segment);
        try std.testing.expectEqual(expected_segment, state.event.segment_index);
        try std.testing.expectEqual(expected_sample, state.event.sample_index);
        try std.testing.expectEqual(expected_sample == 0, state.event.reset);
        if (previous_segment) |previous| {
            if (expected_sample == 0) try std.testing.expect(previous != state.event.segment);
        }
        previous_segment = state.event.segment;
    }
}
