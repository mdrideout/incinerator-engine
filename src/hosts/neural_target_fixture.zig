//! Rights-clean, presentation-only RF5 urban-corner target fixture.
//!
//! The same immutable plans drive the cheap product draw, neural inputs, and
//! offline target-frame package. Blender consumes the package; it never
//! reconstructs or advances gameplay.

const std = @import("std");
const contract = @import("incinerator_engine").neural_rendering;
const target = @import("neural_target_contract.zig");
const catalog = @import("../sandbox_visual_catalog.zig");

pub const source_fingerprint =
    "rf9-spatial-quality-v1|road-sidewalk-curb-masonry-roof-glass-door-sign|" ++
    "shared-catalog-t-characters|multipart-vehicle-four-wheels|" ++
    "character-npc-prop|thin-bollards|declared-material-light-responses|" ++
    "five-authored-layout-material-variants|exact-material-ambiguity-pairs|" ++
    "frame-global-sun-world-local-emissive-material-controls|six-causal-motion-segments|" ++
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
    .id = "rf9-urban-day-v1",
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

/// RF9 authored presentation variants manufacture independent layout,
/// material, and lighting causes plus exact material-ambiguity controls,
/// without introducing a general scene system.
pub const Variant = enum {
    urban_day,
    copper_evening,
    wet_night,
    urban_copper_material,
    urban_wet_material,

    pub fn parse(value: []const u8) !Variant {
        if (std.mem.eql(u8, value, "urban-day")) return .urban_day;
        if (std.mem.eql(u8, value, "copper-evening")) return .copper_evening;
        if (std.mem.eql(u8, value, "wet-night")) return .wet_night;
        if (std.mem.eql(u8, value, "urban-copper-material")) return .urban_copper_material;
        if (std.mem.eql(u8, value, "urban-wet-material")) return .urban_wet_material;
        return error.UnknownNeuralTargetFixtureVariant;
    }

    pub fn name(self: Variant) []const u8 {
        return switch (self) {
            .urban_day => "urban-day",
            .copper_evening => "copper-evening",
            .wet_night => "wet-night",
            .urban_copper_material => "urban-copper-material",
            .urban_wet_material => "urban-wet-material",
        };
    }

    pub fn palette(self: Variant) f32 {
        return switch (self) {
            .urban_day => 0,
            .copper_evening, .urban_copper_material => 1,
            .wet_night, .urban_wet_material => 2,
        };
    }
};

pub fn sceneFor(variant: Variant) target.Scene {
    var result = scene;
    switch (variant) {
        .urban_day => {},
        .copper_evening => {
            result.id = "rf9-copper-evening-v1";
            result.fingerprint = source_fingerprint ++ "|rf9-copper-evening-v1";
            result.sun_color = .{ 1.0, 0.62, 0.34 };
            result.sun_strength = 2.8;
            result.world_color = .{ 0.08, 0.055, 0.12 };
            result.world_strength = 0.22;
            result.local_light_color = .{ 0.35, 0.58, 1.0 };
            result.local_light_strength = 900;
        },
        .wet_night => {
            result.id = "rf9-wet-night-v1";
            result.fingerprint = source_fingerprint ++ "|rf9-wet-night-v1";
            result.sun_color = .{ 0.42, 0.55, 0.86 };
            result.sun_strength = 0.85;
            result.world_color = .{ 0.012, 0.025, 0.065 };
            result.world_strength = 0.12;
            result.local_light_color = .{ 1.0, 0.30, 0.08 };
            result.local_light_strength = 1_800;
        },
        .urban_copper_material => {
            result.id = "rf9-urban-copper-material-v1";
            result.fingerprint = source_fingerprint ++ "|rf9-urban-copper-material-v1";
        },
        .urban_wet_material => {
            result.id = "rf9-urban-wet-material-v1";
            result.fingerprint = source_fingerprint ++ "|rf9-urban-wet-material-v1";
        },
    }
    return result;
}

pub fn contentDigest() [32]u8 {
    return contentDigestFor(.urban_day);
}

pub fn contentDigestFor(variant: Variant) [32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(source_fingerprint);
    hasher.update(variant.name());
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

const environment_count = 20;
const vehicle_start = environment_count;
const vehicle_body_count = catalog.vehicle_parts.len;
const wheel_start = vehicle_start + vehicle_body_count;
const character_start = wheel_start + 4;
const npc_start = character_start + catalog.character_parts.len;
const prop_start = npc_start + catalog.character_parts.len;
pub const draw_count = prop_start + 2;
const character_labels = [_][]const u8{
    "character/left-leg",
    "character/right-leg",
    "character/torso",
    "character/shoulder-arm-bar",
    "character/head",
    "character/facing-marker",
};
const npc_labels = [_][]const u8{
    "npc/left-leg",
    "npc/right-leg",
    "npc/torso",
    "npc/shoulder-arm-bar",
    "npc/head",
    "npc/facing-marker",
};

pub fn plans(presentation_frame: u64) [draw_count]Draw {
    return plansFor(.urban_day, presentation_frame);
}

pub fn plansFor(variant: Variant, presentation_frame: u64) [draw_count]Draw {
    var result = basePlans();
    applyVariant(&result, variant);
    const state = sequenceStateFor(variant, presentation_frame);
    switch (state.event.segment) {
        .object_motion => translateVehicle(&result, .{
            -2.2 * state.event.progress,
            0,
            2.4 * state.event.progress,
        }),
        .wheel_articulation => articulateWheels(&result, state.event.progress),
        .occlusion_disocclusion => translateNpc(&result, .{
            -8.0 * state.event.progress,
            0,
            -2.7 * state.event.progress,
        }),
        .lighting_effect => {
            const strength = state.global_controls.emissive_strength;
            for (&result) |*draw| if (draw.target_source.material == .emissive) {
                draw.target_source.material_response.emission_strength = strength;
            };
        },
        else => {},
    }
    return result;
}

fn applyVariant(result: *[draw_count]Draw, variant: Variant) void {
    switch (variant) {
        .urban_day => {},
        .copper_evening => {
            result[2].target_source.transform.scale[0] = 13.5;
            result[2].target_source.transform.translation[0] += 2.0;
            result[10].target_source.transform.translation[0] -= 3.0;
            translateVehicle(result, .{ 4.4, 0, -2.0 });
            translateNpc(result, .{ -4.2, 0, 3.8 });
            result[prop_start].target_source.transform.translation[0] -= 7.0;
            applyCopperMaterials(result);
        },
        .wet_night => {
            result[2].target_source.transform.scale[0] = 10.0;
            result[2].target_source.transform.translation[0] -= 5.0;
            result[4].target_source.transform.translation[0] += 4.0;
            result[5].target_source.transform.translation[0] -= 4.0;
            translateVehicle(result, .{ -5.0, 0, 4.2 });
            translateNpc(result, .{ 1.4, 0, 5.6 });
            result[prop_start + 1].target_source.transform.translation[2] -= 6.0;
            applyWetMaterials(result, 13);
        },
        .urban_copper_material => applyCopperMaterials(result),
        .urban_wet_material => applyWetMaterials(result, 8),
    }
}

fn applyCopperMaterials(result: *[draw_count]Draw) void {
    for (result) |*draw| switch (draw.target_source.material) {
        .masonry => {
            draw.target_source.material_response.pattern_scale = 11;
            draw.target_source.material_response.bump_strength = 0.48;
        },
        .painted_metal => {
            draw.target_source.material_response.metallic = 0.92;
            draw.target_source.material_response.roughness = 0.14;
        },
        .fabric => draw.target_source.material_response.sheen = 0.48,
        else => {},
    };
}

fn applyWetMaterials(result: *[draw_count]Draw, emissive_strength: f32) void {
    for (result) |*draw| switch (draw.target_source.material) {
        .asphalt => {
            draw.target_source.material_response.roughness = 0.16;
            draw.target_source.material_response.metallic = 0.12;
            draw.target_source.material_response.bump_strength = 0.05;
        },
        .sidewalk => draw.target_source.material_response.roughness = 0.30,
        .glass => {
            draw.target_source.material_response.roughness = 0.025;
            draw.target_source.material_response.transmission = 0.90;
        },
        .emissive => draw.target_source.material_response.emission_strength = emissive_strength,
        else => {},
    };
}

fn basePlans() [draw_count]Draw {
    var result: [draw_count]Draw = undefined;
    result[0] = plan(1, .environment, .whole, "road", .cube, .asphalt, .{ 18, 0.18, 13 }, .{ center[0], 0.09, 0 }, .{ 0.10, 0.11, 0.12, 1 });
    result[1] = plan(2, .environment, .whole, "sidewalk", .cube, .sidewalk, .{ 18, 0.28, 4.0 }, .{ center[0], 0.23, -8.5 }, .{ 0.52, 0.54, 0.56, 1 });
    result[2] = plan(3, .environment, .whole, "building", .cube, .masonry, .{ 17, 8.0, 3.5 }, .{ center[0], 4.35, -11.2 }, .{ 0.48, 0.24, 0.15, 1 });
    result[3] = plan(4, .environment, .whole, "roof", .cube, .painted_metal, .{ 17.6, 0.35, 3.9 }, .{ center[0], 8.48, -11.2 }, .{ 0.10, 0.12, 0.15, 1 });
    result[4] = plan(5, .environment, .whole, "storefront-glass-left", .cube, .glass, .{ 5.8, 4.2, 0.12 }, .{ center[0] - 5.0, 2.65, -9.38 }, .{ 0.22, 0.48, 0.68, 1 });
    result[5] = plan(6, .environment, .whole, "storefront-glass-right", .cube, .glass, .{ 5.8, 4.2, 0.12 }, .{ center[0] + 5.0, 2.65, -9.38 }, .{ 0.22, 0.48, 0.68, 1 });
    result[6] = plan(7, .environment, .whole, "storefront-divider", .cube, .painted_metal, .{ 0.28, 4.5, 0.28 }, .{ center[0], 2.75, -9.2 }, .{ 0.08, 0.09, 0.11, 1 });
    result[7] = plan(8, .environment, .whole, "storefront-door", .cube, .painted_metal, .{ 1.8, 3.7, 0.18 }, .{ center[0], 2.35, -9.3 }, .{ 0.10, 0.16, 0.20, 1 });
    result[8] = plan(9, .environment, .whole, "door-glass", .cube, .glass, .{ 1.35, 2.85, 0.08 }, .{ center[0], 2.55, -9.18 }, .{ 0.20, 0.42, 0.54, 1 });
    result[9] = plan(10, .environment, .whole, "emissive-sign", .cube, .emissive, .{ 7.5, 1.15, 0.32 }, .{ center[0], 6.25, -9.1 }, .{ 1.0, 0.10, 0.03, 1 });
    result[10] = plan(11, .environment, .whole, "awning", .cube, .painted_metal, .{ 10.0, 0.22, 1.6 }, .{ center[0], 5.15, -8.6 }, .{ 0.04, 0.14, 0.27, 1 });
    result[11] = plan(12, .environment, .whole, "lamp-post", .cube, .painted_metal, .{ 0.20, 5.2, 0.20 }, .{ center[0] - 7.0, 2.88, -6.9 }, .{ 0.05, 0.06, 0.07, 1 });
    result[12] = plan(13, .environment, .whole, "lamp-head", .cube, .emissive, .{ 1.25, 0.28, 0.55 }, .{ center[0] - 6.55, 5.55, -6.9 }, .{ 1.0, 0.72, 0.25, 1 });
    result[13] = plan(14, .environment, .whole, "bollard-left", .cube, .painted_metal, .{ 0.24, 1.5, 0.24 }, .{ center[0] - 3.4, 1.02, -6.0 }, .{ 0.82, 0.08, 0.04, 1 });
    result[14] = plan(15, .environment, .whole, "bollard-right", .cube, .painted_metal, .{ 0.24, 1.5, 0.24 }, .{ center[0] + 3.4, 1.02, -6.0 }, .{ 0.82, 0.08, 0.04, 1 });
    result[15] = plan(16, .environment, .whole, "crosswalk-a", .cube, .sidewalk, .{ 2.2, 0.025, 0.58 }, .{ center[0] - 6.0, 0.205, 5.0 }, .{ 0.82, 0.84, 0.80, 1 });
    result[16] = plan(17, .environment, .whole, "crosswalk-b", .cube, .sidewalk, .{ 2.2, 0.025, 0.58 }, .{ center[0] - 2.0, 0.205, 5.0 }, .{ 0.82, 0.84, 0.80, 1 });
    result[17] = plan(18, .environment, .whole, "crosswalk-c", .cube, .sidewalk, .{ 2.2, 0.025, 0.58 }, .{ center[0] + 2.0, 0.205, 5.0 }, .{ 0.82, 0.84, 0.80, 1 });
    result[18] = plan(19, .environment, .whole, "crosswalk-d", .cube, .sidewalk, .{ 2.2, 0.025, 0.58 }, .{ center[0] + 6.0, 0.205, 5.0 }, .{ 0.82, 0.84, 0.80, 1 });
    result[19] = plan(20, .environment, .whole, "curb", .cube, .sidewalk, .{ 18, 0.36, 0.28 }, .{ center[0], 0.32, -6.62 }, .{ 0.68, 0.69, 0.66, 1 });

    const vehicle_origin = [3]f32{ center[0] - 2.0, 1.05, 1.0 };
    const vehicle_bounds = [3]f32{ 1.8, 0.5, 4.0 };
    for (catalog.vehicle_parts, 0..) |part, index| {
        result[vehicle_start + index] = catalogPlan(
            100,
            .vehicle,
            .vehicle_chassis,
            part,
            part.label,
            vehicle_origin,
            vehicle_bounds,
            part.cheap_color,
        );
    }
    result[wheel_start + 0] = wheel(100, .vehicle_wheel_front_left, "wheel-front-left", .{ vehicle_origin[0] - 0.8, 0.62, vehicle_origin[2] - 1.4 });
    result[wheel_start + 1] = wheel(100, .vehicle_wheel_front_right, "wheel-front-right", .{ vehicle_origin[0] + 0.8, 0.62, vehicle_origin[2] - 1.4 });
    result[wheel_start + 2] = wheel(100, .vehicle_wheel_rear_left, "wheel-rear-left", .{ vehicle_origin[0] - 0.8, 0.62, vehicle_origin[2] + 1.4 });
    result[wheel_start + 3] = wheel(100, .vehicle_wheel_rear_right, "wheel-rear-right", .{ vehicle_origin[0] + 0.8, 0.62, vehicle_origin[2] + 1.4 });

    const character_bounds = [3]f32{ 0.8, 1.8, 0.8 };
    for (catalog.character_parts, 0..) |part, index| {
        result[character_start + index] = catalogPlan(
            200,
            .character,
            .whole,
            part,
            character_labels[index],
            .{ center[0] + 3.1, 0.28, -1.2 },
            character_bounds,
            characterColor(part, .{ 0.10, 0.48, 0.78, 1 }),
        );
        result[npc_start + index] = catalogPlan(
            201,
            .npc,
            .whole,
            part,
            npc_labels[index],
            .{ center[0] + 6.0, 0.28, -2.6 },
            character_bounds,
            characterColor(part, .{ 0.72, 0.16, 0.08, 1 }),
        );
    }
    result[prop_start] = plan(300, .carryable, .whole, "carryable", .cube, .cardboard, .{ 0.75, 0.75, 0.75 }, .{ center[0] + 4.8, 0.66, 1.3 }, .{ 0.62, 0.38, 0.16, 1 });
    result[prop_start + 1] = plan(301, .crate, .whole, "crate", .cube, .cardboard, .{ 1.25, 1.25, 1.25 }, .{ center[0] + 7.6, 0.91, 2.7 }, .{ 0.48, 0.27, 0.10, 1 });
    return result;
}

pub const SequenceState = struct {
    event: target.SequenceEvent,
    scene: target.Scene,
    global_controls: contract.FrameGlobalControls,
};

pub fn sequenceState(presentation_frame: u64) SequenceState {
    return sequenceStateFor(.urban_day, presentation_frame);
}

pub fn sequenceStateFor(variant: Variant, presentation_frame: u64) SequenceState {
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
    var frame_scene = sceneFor(variant);
    var global_controls = contract.FrameGlobalControls{
        .sun_strength = frame_scene.sun_strength,
        .world_strength = frame_scene.world_strength,
        .local_light_strength = frame_scene.local_light_strength,
        .emissive_strength = switch (variant) {
            .urban_day, .copper_evening, .urban_copper_material, .urban_wet_material => 8,
            .wet_night => 13,
        },
        .material_palette = variant.palette(),
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
    for (draws[vehicle_start .. wheel_start + 4]) |*draw| {
        for (0..3) |axis| draw.target_source.transform.translation[axis] += offset[axis];
    }
}

fn translateNpc(draws: *[draw_count]Draw, offset: [3]f32) void {
    for (draws[npc_start .. npc_start + catalog.character_parts.len]) |*draw| {
        for (0..3) |axis| draw.target_source.transform.translation[axis] += offset[axis];
    }
}

fn articulateWheels(draws: *[draw_count]Draw, progress: f32) void {
    const roll = progress * std.math.tau * 1.5;
    const steer = (progress * 2.0 - 1.0) * 0.42;
    for (draws[wheel_start .. wheel_start + 4], 0..) |*draw, index| {
        draw.target_source.transform.rotation_xyz[0] = roll;
        if (index < 2) draw.target_source.transform.rotation_xyz[1] = steer;
    }
}

fn catalogPlan(
    entity_ordinal: u16,
    semantic: contract.SemanticClass,
    semantic_part: contract.SemanticPart,
    part: catalog.Part,
    label: []const u8,
    origin: [3]f32,
    bounds: [3]f32,
    base_color: [4]f32,
) Draw {
    const material = materialForSurface(part.surface);
    return .{
        .identity = groupIdentity(entity_ordinal, semantic, semantic_part, part.ordinal),
        .mesh = .cube,
        .base_color = base_color,
        .target_source = .{
            .label = label,
            .shape = .box,
            .material = material,
            .material_response = materialResponse(material),
            .transform = .{
                .scale = .{
                    bounds[0] * part.scale[0],
                    bounds[1] * part.scale[1],
                    bounds[2] * part.scale[2],
                },
                .translation = .{
                    origin[0] + bounds[0] * part.offset[0],
                    origin[1] + bounds[1] * part.offset[1],
                    origin[2] + bounds[2] * part.offset[2],
                },
            },
        },
    };
}

fn materialForSurface(surface: catalog.Surface) target.Material {
    return switch (surface) {
        .painted_metal, .facing_marker => .painted_metal,
        .glass => .glass,
        .emissive => .emissive,
        .fabric_primary, .fabric_secondary => .fabric,
        .skin => .skin,
        // DR1 conventional-only surfaces do not enter the retained neural
        // fixture catalogs. Keep the paused fixture total without teaching it
        // a second material vocabulary.
        else => .painted_metal,
    };
}

fn characterColor(part: catalog.Part, role_color: [4]f32) [4]f32 {
    return switch (part.surface) {
        .fabric_primary => role_color,
        .fabric_secondary => .{
            role_color[0] * 0.42,
            role_color[1] * 0.42,
            role_color[2] * 0.42,
            role_color[3],
        },
        else => part.cheap_color,
    };
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
    var result = plan(ordinal, .vehicle, part, label, .wheel, .rubber, .{ 0.32, 0.72, 0.72 }, translation, .{ 0.07, 0.08, 0.09, 1 });
    result.identity = groupIdentity(ordinal, .vehicle, part, 0);
    return result;
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

fn groupIdentity(
    entity_ordinal: u16,
    semantic: contract.SemanticClass,
    part: contract.SemanticPart,
    ordinal: u16,
) contract.DrawIdentity {
    return .{
        .identity = .{ .fixture = fixture_identity_base + entity_ordinal },
        .semantic = semantic,
        .part = part,
        .ordinal = ordinal,
    };
}

test "RF5 target fixture has unique stable identities and complete target sources" {
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

test "RF5 target fixture contains the required semantic product slice" {
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
    try std.testing.expectEqual(@as(usize, catalog.vehicle_parts.len + 4), vehicle_parts);
}

test "RF5 fixture shares explicit character and vehicle catalogs" {
    const draws = plans(120);
    for (catalog.character_parts, 0..) |part, index| {
        try std.testing.expect(std.mem.endsWith(u8, draws[character_start + index].target_source.label, part.label));
        try std.testing.expect(std.mem.endsWith(u8, draws[npc_start + index].target_source.label, part.label));
        try std.testing.expectEqual(part.ordinal, draws[character_start + index].identity.ordinal);
    }
    for (catalog.vehicle_parts, 0..) |part, index| {
        try std.testing.expectEqualStrings(part.label, draws[vehicle_start + index].target_source.label);
        try std.testing.expectEqual(part.ordinal, draws[vehicle_start + index].identity.ordinal);
    }
}

test "RF2 through RF5 material and lighting intent is explicit" {
    var materials = std.EnumSet(target.Material).initEmpty();
    var emissive_count: usize = 0;
    for (plans(sequence_start_frame)) |draw| {
        materials.insert(draw.target_source.material);
        if (draw.target_source.material == .emissive) emissive_count += 1;
    }
    inline for (.{
        target.Material.asphalt,
        .sidewalk,
        .masonry,
        .painted_metal,
        .rubber,
        .glass,
        .emissive,
        .fabric,
        .skin,
        .cardboard,
    }) |material| try std.testing.expect(materials.contains(material));
    try std.testing.expect(emissive_count >= 4);
    const low = sequenceState(sequence_start_frame + 5 * segment_frame_span);
    const high = sequenceState(sequence_start_frame + 5 * segment_frame_span + 2 * sequence_frame_stride);
    try std.testing.expect(high.global_controls.local_light_strength > low.global_controls.local_light_strength);
    try std.testing.expect(high.global_controls.emissive_strength > low.global_controls.emissive_strength);
}

test "RF5 sequence isolates one authored cause per segment" {
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

test "RF9 fixture controls agree with variant material intent" {
    for (std.enums.values(Variant)) |variant| {
        const state = sequenceStateFor(variant, sequence_start_frame);
        const draws = plansFor(variant, sequence_start_frame);
        for (draws) |draw| {
            if (draw.target_source.material != .emissive) continue;
            try std.testing.expectEqual(
                state.global_controls.emissive_strength,
                draw.target_source.material_response.emission_strength,
            );
        }
    }
}

test "RF9 material ambiguity fixtures change no cheap spatial or lighting fact" {
    const reference_scene = sceneFor(.urban_day);
    const reference_controls = sequenceStateFor(.urban_day, sequence_start_frame).global_controls;
    for ([_]Variant{ .urban_copper_material, .urban_wet_material }) |variant| {
        const candidate_scene = sceneFor(variant);
        try std.testing.expectEqual(reference_scene.sun_direction, candidate_scene.sun_direction);
        try std.testing.expectEqual(reference_scene.sun_color, candidate_scene.sun_color);
        try std.testing.expectEqual(reference_scene.sun_strength, candidate_scene.sun_strength);
        try std.testing.expectEqual(reference_scene.world_color, candidate_scene.world_color);
        try std.testing.expectEqual(reference_scene.world_strength, candidate_scene.world_strength);
        try std.testing.expectEqual(reference_scene.local_light_position, candidate_scene.local_light_position);
        try std.testing.expectEqual(reference_scene.local_light_color, candidate_scene.local_light_color);
        try std.testing.expectEqual(reference_scene.local_light_strength, candidate_scene.local_light_strength);
        const candidate_controls = sequenceStateFor(variant, sequence_start_frame).global_controls;
        try std.testing.expectEqual(reference_controls.sun_strength, candidate_controls.sun_strength);
        try std.testing.expectEqual(reference_controls.world_strength, candidate_controls.world_strength);
        try std.testing.expectEqual(reference_controls.local_light_strength, candidate_controls.local_light_strength);
        try std.testing.expectEqual(reference_controls.emissive_strength, candidate_controls.emissive_strength);
        try std.testing.expect(reference_controls.material_palette != candidate_controls.material_palette);

        const reference_draws = plansFor(.urban_day, sequence_start_frame);
        const candidate_draws = plansFor(variant, sequence_start_frame);
        for (reference_draws, candidate_draws) |reference, candidate| {
            try std.testing.expectEqual(reference.identity, candidate.identity);
            try std.testing.expectEqual(reference.mesh, candidate.mesh);
            try std.testing.expectEqual(reference.base_color, candidate.base_color);
            try std.testing.expectEqual(reference.target_source.transform, candidate.target_source.transform);
        }
    }
}
