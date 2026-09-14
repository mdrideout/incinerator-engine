//! Game-owned industrial neighborhood: authored collision, travel routes and destinations.
//!
//! The reusable district contract owns bounded value types and structural
//! validation. This module owns the actual world layout, installed
//! coordinates, recipe cohort, and exact four-district navigation policy.

const std = @import("std");
const district = @import("district_contract");
const navigation = @import("navigation_contract");
const scene = @import("scene.zig");

pub const current_recipe_version: u32 = 11;
pub const catalog_semantic_id = "incinerator.industrial.neighborhood";
pub const catalog_wire_schema: u16 = 1;
pub const player_spawn = [3]f32{ -8, 0, 4 };
pub const vehicle_spawn = [3]f32{ 2, 1, 3 };
pub const carryable_spawn = [3]f32{ -8, 0.5, 6 };
pub const ground_center = [3]f32{ 32, -1, -480 };
pub const ground_half_extents = [3]f32{ 64, 1, 576 };
pub const gate_positions = [2][3]f32{ .{ 32, 1, 72 }, .{ 32, 1, 8 } };
pub const static_box_count: u8 = scene.max_static_box_count;
pub const blocking_proxy_count: u8 = static_box_count;
pub const navigation_west_coord = district.ChunkCoord{ .x = 0, .z = 0 };
pub const navigation_east_coord = district.ChunkCoord{ .x = 1, .z = 0 };
pub const navigation_northwest_coord = district.ChunkCoord{ .x = 0, .z = 1 };
pub const navigation_northeast_coord = district.ChunkCoord{ .x = 1, .z = 1 };
pub const installed_coords = [_]district.ChunkCoord{
    navigation_west_coord,
    navigation_east_coord,
    navigation_northwest_coord,
    navigation_northeast_coord,
    .{ .x = 0, .z = -1 },
    .{ .x = 0, .z = -2 },
    .{ .x = 0, .z = -3 },
    .{ .x = 0, .z = -4 },
    .{ .x = 0, .z = -5 },
    .{ .x = 0, .z = -6 },
    .{ .x = 0, .z = -7 },
    .{ .x = 0, .z = -8 },
    .{ .x = 0, .z = -9 },
    .{ .x = 0, .z = -10 },
    .{ .x = 0, .z = -11 },
    .{ .x = 0, .z = -12 },
    .{ .x = 0, .z = -13 },
    .{ .x = 0, .z = -14 },
    .{ .x = 0, .z = -15 },
    .{ .x = 0, .z = -16 },
};

/// The isolated multiplayer fixture retains the original neighborhood.
pub const fixture_coords = installed_coords[0..4];

pub const garage_forecourt = navigation.DestinationId{ .value = 1 };
pub const foundry_office = navigation.DestinationId{ .value = 2 };
pub const foundry_south_walk = navigation.DestinationId{ .value = 3 };
pub const freight_dispatch = navigation.DestinationId{ .value = 4 };
pub const freight_alley = navigation.DestinationId{ .value = 5 };
pub const freight_yard = navigation.DestinationId{ .value = 6 };
pub const garage_forecourt_companion = navigation.DestinationId{ .value = 7 };
pub const foundry_office_companion = navigation.DestinationId{ .value = 8 };
pub const south_gate_companion = navigation.DestinationId{ .value = 9 };
pub const foundry_west_walk_first = navigation.DestinationId{ .value = 10 };
pub const foundry_west_walk_second = navigation.DestinationId{ .value = 11 };
pub const freight_dispatch_second = navigation.DestinationId{ .value = 12 };
pub const freight_dispatch_third = navigation.DestinationId{ .value = 13 };
pub const freight_alley_companion = navigation.DestinationId{ .value = 14 };
pub const freight_yard_companion = navigation.DestinationId{ .value = 15 };
pub const freight_court = navigation.DestinationId{ .value = 16 };
pub const motor_works_entry_first = navigation.DestinationId{ .value = 17 };
pub const motor_works_entry_second = navigation.DestinationId{ .value = 18 };
pub const motor_works_yard_first = navigation.DestinationId{ .value = 19 };
pub const motor_works_yard_second = navigation.DestinationId{ .value = 20 };
pub const warehouse_dispatch_first = navigation.DestinationId{ .value = 21 };
pub const warehouse_dispatch_second = navigation.DestinationId{ .value = 22 };
pub const warehouse_service_alley_first = navigation.DestinationId{ .value = 23 };
pub const warehouse_service_alley_second = navigation.DestinationId{ .value = 24 };
pub const destination_count: usize = 24;

pub fn resolveDestination(id: navigation.DestinationId) ?navigation.Destination {
    const entry: navigation.Destination = switch (id.value) {
        1 => .{
            .id = garage_forecourt,
            .position = .{ -8, 0, 6 },
            .arrival_radius = 0.25,
            .anchors = .{ nodeRef(navigation_west_coord, 6), .{} },
            .anchor_count = 1,
        },
        2 => .{
            .id = foundry_office,
            .position = .{ 6, 0, 8 },
            .arrival_radius = 0.25,
            .anchors = .{ nodeRef(navigation_west_coord, 4), .{} },
            .anchor_count = 1,
        },
        3 => .{
            .id = foundry_south_walk,
            .position = .{ 0, 0, -8 },
            .arrival_radius = 0.25,
            .anchors = .{ nodeRef(navigation_west_coord, 1), .{} },
            .anchor_count = 1,
        },
        4 => .{
            .id = freight_dispatch,
            .position = .{ 70, 0, 8 },
            .arrival_radius = 0.25,
            .anchors = .{ nodeRef(navigation_east_coord, 4), .{} },
            .anchor_count = 1,
        },
        5 => .{
            .id = freight_alley,
            .position = .{ 56, 0, 0 },
            .arrival_radius = 0.25,
            .anchors = .{ nodeRef(navigation_east_coord, 7), .{} },
            .anchor_count = 1,
        },
        6 => .{
            .id = freight_yard,
            .position = .{ 64, 0, -8 },
            .arrival_radius = 0.25,
            .anchors = .{ nodeRef(navigation_east_coord, 1), .{} },
            .anchor_count = 1,
        },
        7 => .{
            .id = garage_forecourt_companion,
            .position = .{ -8, 0, 4 },
            .arrival_radius = 0.25,
            .anchors = .{ nodeRef(navigation_west_coord, 6), .{} },
            .anchor_count = 1,
        },
        8 => .{
            .id = foundry_office_companion,
            .position = .{ 4, 0, 8 },
            .arrival_radius = 0.25,
            .anchors = .{ nodeRef(navigation_west_coord, 4), .{} },
            .anchor_count = 1,
        },
        9 => .{
            .id = south_gate_companion,
            .position = .{ 2, 0, -8 },
            .arrival_radius = 0.25,
            .anchors = .{ nodeRef(navigation_west_coord, 1), .{} },
            .anchor_count = 1,
        },
        10 => .{
            .id = foundry_west_walk_first,
            .position = .{ -6, 0, -8 },
            .arrival_radius = 0.25,
            .anchors = .{ nodeRef(navigation_west_coord, 0), .{} },
            .anchor_count = 1,
        },
        11 => .{
            .id = foundry_west_walk_second,
            .position = .{ -4, 0, -8 },
            .arrival_radius = 0.25,
            .anchors = .{ nodeRef(navigation_west_coord, 0), .{} },
            .anchor_count = 1,
        },
        12 => .{
            .id = freight_dispatch_second,
            .position = .{ 68, 0, 8 },
            .arrival_radius = 0.25,
            .anchors = .{ nodeRef(navigation_east_coord, 4), .{} },
            .anchor_count = 1,
        },
        13 => .{
            .id = freight_dispatch_third,
            .position = .{ 66, 0, 8 },
            .arrival_radius = 0.25,
            .anchors = .{ nodeRef(navigation_east_coord, 5), .{} },
            .anchor_count = 1,
        },
        14 => .{
            .id = freight_alley_companion,
            .position = .{ 56, 0, 2 },
            .arrival_radius = 0.25,
            .anchors = .{ nodeRef(navigation_east_coord, 7), .{} },
            .anchor_count = 1,
        },
        15 => .{
            .id = freight_yard_companion,
            .position = .{ 66, 0, -8 },
            .arrival_radius = 0.25,
            .anchors = .{ nodeRef(navigation_east_coord, 1), .{} },
            .anchor_count = 1,
        },
        16 => .{
            .id = freight_court,
            .position = .{ 58, 0, 8 },
            .arrival_radius = 0.25,
            .anchors = .{ nodeRef(navigation_east_coord, 6), .{} },
            .anchor_count = 1,
        },
        17 => .{
            .id = motor_works_entry_first,
            .position = .{ -8, 0, 70 },
            .arrival_radius = 0.25,
            .anchors = .{ nodeRef(navigation_northwest_coord, 6), .{} },
            .anchor_count = 1,
        },
        18 => .{
            .id = motor_works_entry_second,
            .position = .{ -8, 0, 68 },
            .arrival_radius = 0.25,
            .anchors = .{ nodeRef(navigation_northwest_coord, 6), .{} },
            .anchor_count = 1,
        },
        19 => .{
            .id = motor_works_yard_first,
            .position = .{ 6, 0, 72 },
            .arrival_radius = 0.25,
            .anchors = .{ nodeRef(navigation_northwest_coord, 4), .{} },
            .anchor_count = 1,
        },
        20 => .{
            .id = motor_works_yard_second,
            .position = .{ 4, 0, 72 },
            .arrival_radius = 0.25,
            .anchors = .{ nodeRef(navigation_northwest_coord, 4), .{} },
            .anchor_count = 1,
        },
        21 => .{
            .id = warehouse_dispatch_first,
            .position = .{ 70, 0, 72 },
            .arrival_radius = 0.25,
            .anchors = .{ nodeRef(navigation_northeast_coord, 4), .{} },
            .anchor_count = 1,
        },
        22 => .{
            .id = warehouse_dispatch_second,
            .position = .{ 68, 0, 72 },
            .arrival_radius = 0.25,
            .anchors = .{ nodeRef(navigation_northeast_coord, 4), .{} },
            .anchor_count = 1,
        },
        23 => .{
            .id = warehouse_service_alley_first,
            .position = .{ 56, 0, 64 },
            .arrival_radius = 0.25,
            .anchors = .{ nodeRef(navigation_northeast_coord, 7), .{} },
            .anchor_count = 1,
        },
        24 => .{
            .id = warehouse_service_alley_second,
            .position = .{ 56, 0, 66 },
            .arrival_radius = 0.25,
            .anchors = .{ nodeRef(navigation_northeast_coord, 7), .{} },
            .anchor_count = 1,
        },
        else => return null,
    };
    return entry;
}

pub fn destinationName(id: navigation.DestinationId) ?[]const u8 {
    return switch (id.value) {
        1 => "garage_forecourt",
        2 => "foundry_office",
        3 => "foundry_south_walk",
        4 => "freight_dispatch",
        5 => "freight_alley",
        6 => "freight_yard",
        7 => "garage_forecourt_companion",
        8 => "foundry_office_companion",
        9 => "south_gate_companion",
        10 => "foundry_west_walk_first",
        11 => "foundry_west_walk_second",
        12 => "freight_dispatch_second",
        13 => "freight_dispatch_third",
        14 => "freight_alley_companion",
        15 => "freight_yard_companion",
        16 => "freight_court",
        17 => "motor_works_entry_first",
        18 => "motor_works_entry_second",
        19 => "motor_works_yard_first",
        20 => "motor_works_yard_second",
        21 => "warehouse_dispatch_first",
        22 => "warehouse_dispatch_second",
        23 => "warehouse_service_alley_first",
        24 => "warehouse_service_alley_second",
        else => null,
    };
}

fn nodeRef(coord: district.ChunkCoord, index: u8) navigation.NodeRef {
    return .{ .coord = coord, .index = index };
}

/// Visual-host streaming policy for one installed sandbox district. Keeping
/// it next to the logical recipe prevents a composition host from inventing a
/// second coordinate/layout catalog.
pub const PresentationPolicy = struct {
    coord: district.ChunkCoord,
    center_xz: [2]f32,
    half_extent_xz: [2]f32,
    prefetch_load_margin: f32,
    prefetch_unload_margin: f32,
    authority_load_margin: f32,
    authority_unload_margin: f32,
};

pub const presentation_policies = [_]PresentationPolicy{
    .{
        .coord = navigation_west_coord,
        .center_xz = .{ 0, 0 },
        .half_extent_xz = .{ district.chunk_half_span, district.chunk_half_span },
        // The sandbox has one adjacent district in either direction. Warm
        // that visual content from the neighboring district center while
        // retaining the existing narrow logical/collision boundary.
        .prefetch_load_margin = 4 * scene.chunk_span,
        .prefetch_unload_margin = 4 * scene.chunk_span + 4,
        .authority_load_margin = 4,
        .authority_unload_margin = 8,
    },
    .{
        .coord = navigation_east_coord,
        .center_xz = .{ district.chunk_span, 0 },
        .half_extent_xz = .{ district.chunk_half_span, district.chunk_half_span },
        .prefetch_load_margin = 4 * scene.chunk_span,
        .prefetch_unload_margin = 4 * scene.chunk_span + 4,
        .authority_load_margin = 4,
        .authority_unload_margin = 8,
    },
    .{
        .coord = navigation_northwest_coord,
        .center_xz = .{ 0, district.chunk_span },
        .half_extent_xz = .{ district.chunk_half_span, district.chunk_half_span },
        .prefetch_load_margin = 4 * scene.chunk_span,
        .prefetch_unload_margin = 4 * scene.chunk_span + 4,
        .authority_load_margin = 4,
        .authority_unload_margin = 8,
    },
    .{
        .coord = navigation_northeast_coord,
        .center_xz = .{ district.chunk_span, district.chunk_span },
        .half_extent_xz = .{ district.chunk_half_span, district.chunk_half_span },
        .prefetch_load_margin = 4 * scene.chunk_span,
        .prefetch_unload_margin = 4 * scene.chunk_span + 4,
        .authority_load_margin = 4,
        .authority_unload_margin = 8,
    },
    // Look four road cells ahead; the former 24 m margin showed an apparent road end.
    .{ .coord = .{ .x = 0, .z = -1 }, .center_xz = .{ 0, -64 }, .half_extent_xz = .{ 32, 32 }, .prefetch_load_margin = 4 * scene.chunk_span, .prefetch_unload_margin = 4 * scene.chunk_span + 4, .authority_load_margin = 4, .authority_unload_margin = 8 },
    .{ .coord = .{ .x = 0, .z = -2 }, .center_xz = .{ 0, -128 }, .half_extent_xz = .{ 32, 32 }, .prefetch_load_margin = 4 * scene.chunk_span, .prefetch_unload_margin = 4 * scene.chunk_span + 4, .authority_load_margin = 4, .authority_unload_margin = 8 },
    .{ .coord = .{ .x = 0, .z = -3 }, .center_xz = .{ 0, -192 }, .half_extent_xz = .{ 32, 32 }, .prefetch_load_margin = 4 * scene.chunk_span, .prefetch_unload_margin = 4 * scene.chunk_span + 4, .authority_load_margin = 4, .authority_unload_margin = 8 },
    .{ .coord = .{ .x = 0, .z = -4 }, .center_xz = .{ 0, -256 }, .half_extent_xz = .{ 32, 32 }, .prefetch_load_margin = 4 * scene.chunk_span, .prefetch_unload_margin = 4 * scene.chunk_span + 4, .authority_load_margin = 4, .authority_unload_margin = 8 },
    .{ .coord = .{ .x = 0, .z = -5 }, .center_xz = .{ 0, -320 }, .half_extent_xz = .{ 32, 32 }, .prefetch_load_margin = 4 * scene.chunk_span, .prefetch_unload_margin = 4 * scene.chunk_span + 4, .authority_load_margin = 4, .authority_unload_margin = 8 },
    .{ .coord = .{ .x = 0, .z = -6 }, .center_xz = .{ 0, -384 }, .half_extent_xz = .{ 32, 32 }, .prefetch_load_margin = 4 * scene.chunk_span, .prefetch_unload_margin = 4 * scene.chunk_span + 4, .authority_load_margin = 4, .authority_unload_margin = 8 },
    .{ .coord = .{ .x = 0, .z = -7 }, .center_xz = .{ 0, -448 }, .half_extent_xz = .{ 32, 32 }, .prefetch_load_margin = 4 * scene.chunk_span, .prefetch_unload_margin = 4 * scene.chunk_span + 4, .authority_load_margin = 4, .authority_unload_margin = 8 },
    .{ .coord = .{ .x = 0, .z = -8 }, .center_xz = .{ 0, -512 }, .half_extent_xz = .{ 32, 32 }, .prefetch_load_margin = 4 * scene.chunk_span, .prefetch_unload_margin = 4 * scene.chunk_span + 4, .authority_load_margin = 4, .authority_unload_margin = 8 },
    .{ .coord = .{ .x = 0, .z = -9 }, .center_xz = .{ 0, -576 }, .half_extent_xz = .{ 32, 32 }, .prefetch_load_margin = 4 * scene.chunk_span, .prefetch_unload_margin = 4 * scene.chunk_span + 4, .authority_load_margin = 4, .authority_unload_margin = 8 },
    .{ .coord = .{ .x = 0, .z = -10 }, .center_xz = .{ 0, -640 }, .half_extent_xz = .{ 32, 32 }, .prefetch_load_margin = 4 * scene.chunk_span, .prefetch_unload_margin = 4 * scene.chunk_span + 4, .authority_load_margin = 4, .authority_unload_margin = 8 },
    .{ .coord = .{ .x = 0, .z = -11 }, .center_xz = .{ 0, -704 }, .half_extent_xz = .{ 32, 32 }, .prefetch_load_margin = 4 * scene.chunk_span, .prefetch_unload_margin = 4 * scene.chunk_span + 4, .authority_load_margin = 4, .authority_unload_margin = 8 },
    .{ .coord = .{ .x = 0, .z = -12 }, .center_xz = .{ 0, -768 }, .half_extent_xz = .{ 32, 32 }, .prefetch_load_margin = 4 * scene.chunk_span, .prefetch_unload_margin = 4 * scene.chunk_span + 4, .authority_load_margin = 4, .authority_unload_margin = 8 },
    .{ .coord = .{ .x = 0, .z = -13 }, .center_xz = .{ 0, -832 }, .half_extent_xz = .{ 32, 32 }, .prefetch_load_margin = 4 * scene.chunk_span, .prefetch_unload_margin = 4 * scene.chunk_span + 4, .authority_load_margin = 4, .authority_unload_margin = 8 },
    .{ .coord = .{ .x = 0, .z = -14 }, .center_xz = .{ 0, -896 }, .half_extent_xz = .{ 32, 32 }, .prefetch_load_margin = 4 * scene.chunk_span, .prefetch_unload_margin = 4 * scene.chunk_span + 4, .authority_load_margin = 4, .authority_unload_margin = 8 },
    .{ .coord = .{ .x = 0, .z = -15 }, .center_xz = .{ 0, -960 }, .half_extent_xz = .{ 32, 32 }, .prefetch_load_margin = 4 * scene.chunk_span, .prefetch_unload_margin = 4 * scene.chunk_span + 4, .authority_load_margin = 4, .authority_unload_margin = 8 },
    .{ .coord = .{ .x = 0, .z = -16 }, .center_xz = .{ 0, -1024 }, .half_extent_xz = .{ 32, 32 }, .prefetch_load_margin = 4 * scene.chunk_span, .prefetch_unload_margin = 4 * scene.chunk_span + 4, .authority_load_margin = 4, .authority_unload_margin = 8 },
};

/// Product presentation responsibility for each canonical static box.
///
/// Cooked meshes are authored decoration until a future content schema can
/// explicitly bind mesh instances to collision. Every district-owned obstacle
/// therefore keeps a simple proxy in every residency state. The composition
/// owns the one continuous flat support body and visual; districts do not
/// duplicate it.
pub const StaticBoxPresentation = enum {
    blocking_proxy,
};

pub const PresentationPlan = struct {
    authored_scene_resident: bool,
    proxy_box_indices: [district.max_static_boxes]u8 = undefined,
    proxy_box_count: u8 = 0,

    pub fn proxyBoxIndices(self: *const PresentationPlan) []const u8 {
        return self.proxy_box_indices[0..self.proxy_box_count];
    }

    pub fn presentsBlockingBox(self: *const PresentationPlan, box_index: usize) bool {
        for (self.proxyBoxIndices()) |candidate| {
            if (candidate == box_index) return true;
        }
        return false;
    }
};

pub const CapsuleClearance = struct {
    radius: f32,
    half_height: f32,
    margin: f32,
};

/// Build the renderer-neutral district draw contract. Authored content and
/// collision proxies are additive: residency must never make a blocker
/// disappear merely because the cooked scene contains unrelated geometry.
pub fn presentationPlan(
    logical_build: *const district.DistrictBuild,
    authored_scene_resident: bool,
) !PresentationPlan {
    if (logical_build.validationFailure() != null) {
        return error.InvalidDistrictPresentationBuild;
    }

    var plan = PresentationPlan{
        .authored_scene_resident = authored_scene_resident,
    };
    if (authored_scene_resident) return plan;
    for (logical_build.boxes(), 0..) |_, box_index| {
        _ = staticBoxPresentation(box_index) orelse
            return error.UnknownDistrictStaticBoxPresentation;
        plan.proxy_box_indices[plan.proxy_box_count] = @intCast(box_index);
        plan.proxy_box_count += 1;
    }
    return plan;
}

/// Pure product-layout query used before the asynchronous district is active.
/// It deliberately checks the same canonical blocking boxes that require
/// presentation proxies, so spawn safety and visible collision cannot drift
/// into separate catalogs.
pub fn capsuleTraversalClear(
    logical_build: *const district.DistrictBuild,
    start: [3]f32,
    end: [3]f32,
    clearance: CapsuleClearance,
) bool {
    if (!validPoint(start) or !validPoint(end) or
        !std.math.isFinite(clearance.radius) or clearance.radius <= 0 or
        !std.math.isFinite(clearance.half_height) or clearance.half_height <= 0 or
        !std.math.isFinite(clearance.margin) or clearance.margin < 0)
    {
        return false;
    }
    if (logical_build.validationFailure() != null) return false;

    const capsule_min_y = @min(start[1], end[1]);
    const capsule_max_y = @max(start[1], end[1]) +
        2 * (clearance.half_height + clearance.radius);
    const horizontal_extent = clearance.radius + clearance.margin;
    for (logical_build.boxes(), 0..) |box, box_index| {
        const role = staticBoxPresentation(box_index) orelse return false;
        _ = role;

        // The installed recipe is intentionally axis-aligned. Reject layout
        // drift conservatively until an oriented-box clearance query is part
        // of the canonical contract.
        if (!std.meta.eql(box.pose.rotation, [4]f32{ 0, 0, 0, 1 })) return false;
        const box_min_y = box.pose.position[1] - box.half_extents[1];
        const box_max_y = box.pose.position[1] + box.half_extents[1];
        if (capsule_max_y < box_min_y or capsule_min_y > box_max_y) continue;

        const minimum = [2]f32{
            box.pose.position[0] - box.half_extents[0] - horizontal_extent,
            box.pose.position[2] - box.half_extents[2] - horizontal_extent,
        };
        const maximum = [2]f32{
            box.pose.position[0] + box.half_extents[0] + horizontal_extent,
            box.pose.position[2] + box.half_extents[2] + horizontal_extent,
        };
        if (segmentIntersectsAabb2(
            .{ start[0], start[2] },
            .{ end[0], end[2] },
            minimum,
            maximum,
        )) return false;
    }
    return true;
}

fn staticBoxPresentation(box_index: usize) ?StaticBoxPresentation {
    return if (box_index < static_box_count) .blocking_proxy else null;
}

fn validPoint(point: [3]f32) bool {
    for (point) |component| {
        if (!std.math.isFinite(component)) return false;
    }
    return true;
}

fn segmentIntersectsAabb2(
    start: [2]f32,
    end: [2]f32,
    minimum: [2]f32,
    maximum: [2]f32,
) bool {
    var first_t: f32 = 0;
    var last_t: f32 = 1;
    for (0..2) |axis| {
        const delta = end[axis] - start[axis];
        if (@abs(delta) <= std.math.floatEps(f32)) {
            if (start[axis] < minimum[axis] or start[axis] > maximum[axis]) {
                return false;
            }
            continue;
        }
        var near_t = (minimum[axis] - start[axis]) / delta;
        var far_t = (maximum[axis] - start[axis]) / delta;
        if (near_t > far_t) std.mem.swap(f32, &near_t, &far_t);
        first_t = @max(first_t, near_t);
        last_t = @min(last_t, far_t);
        if (first_t > last_t) return false;
    }
    return true;
}

pub fn build(coord: district.ChunkCoord, recipe_version: u32) district.ProceduralResult {
    if (recipe_version != current_recipe_version) return .{ .failed = .{ .unsupported_recipe_version = recipe_version } };
    var result = district.DistrictBuild{ .coord = coord, .recipe_version = recipe_version, .checksum = 0, .decoded_bytes = 0, .static_box_count = static_box_count };
    var found = false;
    inline for (installed_coords, 0..) |installed, index| {
        if (district.ChunkCoord.eql(coord, installed)) {
            result.static_box_count = scene.boxes[index].len;
            inline for (scene.boxes[index], 0..) |box, box_index| {
                result.static_boxes[box_index] = .{ .pose = .{ .position = box.position }, .half_extents = box.half_extents };
            }
            found = true;
        }
    }
    if (!found) return .{ .failed = .{ .invalid_build = .no_static_boxes } };
    populateNavigation(&result);
    result.decoded_bytes = district.decodedByteCount(result.static_box_count, result.navigation_node_count, result.navigation_edge_count);
    result.checksum = result.calculateChecksum() catch unreachable;
    return .{ .ready = result };
}

/// Compare a cooked renderer-neutral view with the exact logical recipe. The
/// structural view is generic so this game-policy module does not own or
/// import the reusable bundle wire format.
pub fn logicalShapeMatches(
    view: anytype,
    logical_build: *const district.DistrictBuild,
) bool {
    if (view.static_boxes.len != logical_build.boxes().len) return false;
    for (view.static_boxes, logical_build.boxes()) |cooked, logical| {
        if (!std.meta.eql(cooked.position, logical.pose.position) or
            !std.meta.eql(cooked.rotation, logical.pose.rotation) or
            !std.meta.eql(cooked.half_extents, logical.half_extents)) return false;
    }
    if (view.navigation_nodes.len != logical_build.navigationNodes().len or
        view.navigation_edges.len != logical_build.navigationEdges().len) return false;
    for (view.navigation_nodes, logical_build.navigationNodes()) |cooked, logical| {
        if (!std.meta.eql(cooked.position, logical.position) or
            cooked.first_edge != logical.first_edge or
            cooked.edge_count != logical.edge_count or
            cooked.flags != logical.flags or
            cooked.reserved != logical.reserved) return false;
    }
    for (view.navigation_edges, logical_build.navigationEdges()) |cooked, logical| {
        if (!std.meta.eql(
            cooked.target_coord,
            [2]i32{ logical.target.coord.x, logical.target.coord.z },
        ) or cooked.target_node != logical.target.index or
            cooked.flags != logical.flags or cooked.cost != logical.cost) return false;
    }
    return true;
}

pub const navigation_positions = scene.navigation_positions;

fn populateNavigation(result: *district.DistrictBuild) void {
    result.navigation_node_count = navigation_positions.len;
    for (navigation_positions, 0..) |position, index| {
        const node = &result.navigation_nodes[index];
        node.position = .{ position[0] + @as(f32, @floatFromInt(result.coord.x)) * district.chunk_span, 0, position[1] + @as(f32, @floatFromInt(result.coord.z)) * district.chunk_span };
        node.first_edge = result.navigation_edge_count;
        var targets: [3]district.NavigationNodeRef = undefined;
        var count: usize = 0;
        if (index < 8) {
            targets[0] = nodeRef(result.coord, @intCast((index + 7) % 8));
            targets[1] = nodeRef(result.coord, @intCast((index + 1) % 8));
            count = 2;
            const spoke: ?u8 = switch (index) {
                3 => 8,
                7 => 9,
                5 => 10,
                1 => 11,
                else => null,
            };
            if (spoke) |value| {
                targets[count] = nodeRef(result.coord, value);
                count += 1;
            }
        } else {
            targets[0] = nodeRef(result.coord, switch (index) {
                8 => 3,
                9 => 7,
                10 => 5,
                11 => 1,
                else => unreachable,
            });
            count = 1;
            const neighbor = district.ChunkCoord{ .x = result.coord.x + @as(i32, if (index == 8) 1 else if (index == 9) -1 else 0), .z = result.coord.z + @as(i32, if (index == 10) 1 else if (index == 11) -1 else 0) };
            for (installed_coords) |installed| if (district.ChunkCoord.eql(installed, neighbor)) {
                targets[count] = nodeRef(neighbor, switch (index) {
                    8 => 9,
                    9 => 8,
                    10 => 11,
                    11 => 10,
                    else => unreachable,
                });
                count += 1;
            };
        }
        std.mem.sort(district.NavigationNodeRef, targets[0..count], {}, struct {
            fn less(_: void, a: district.NavigationNodeRef, b: district.NavigationNodeRef) bool {
                if (a.coord.x != b.coord.x) return a.coord.x < b.coord.x;
                if (a.coord.z != b.coord.z) return a.coord.z < b.coord.z;
                return a.index < b.index;
            }
        }.less);
        node.edge_count = @intCast(count);
        for (targets[0..count]) |target| {
            const p = navigation_positions[target.index];
            const dx = p[0] + @as(f32, @floatFromInt(target.coord.x)) * district.chunk_span - node.position[0];
            const dz = p[1] + @as(f32, @floatFromInt(target.coord.z)) * district.chunk_span - node.position[2];
            result.navigation_edges[result.navigation_edge_count] = navEdge(target.coord, target.index, @intFromFloat(@sqrt(dx * dx + dz * dz) * 100));
            result.navigation_edge_count += 1;
        }
    }
}

fn navEdge(coord: district.ChunkCoord, index: u8, cost: u16) district.NavigationEdge {
    return .{ .target = .{ .coord = coord, .index = index }, .cost = cost };
}

pub const RouteValidationFailure = enum {
    wrong_build_count,
    invalid_build,
    duplicate_district,
    missing_installed_district,
    missing_navigation_fragment,
    target_district_missing,
    target_node_missing,
    non_reciprocal_edge,
    invalid_cross_district_edge_count,
    invalid_destination_catalog,
    disconnected_route,
};

/// Validate the exact bounded reciprocal route installed by this sandbox.
pub fn routeValidationFailure(
    builds: []const district.DistrictBuild,
) ?RouteValidationFailure {
    if (builds.len != installed_coords.len) return .wrong_build_count;
    for (builds, 0..) |*candidate, index| {
        if (candidate.validationFailure() != null) return .invalid_build;
        if (candidate.navigation_node_count == 0) return .missing_navigation_fragment;
        for (builds[0..index]) |earlier| {
            if (district.ChunkCoord.eql(earlier.coord, candidate.coord)) {
                return .duplicate_district;
            }
        }
    }
    for (installed_coords) |coord| {
        if (findBuildIndex(builds, coord) == null) return .missing_installed_district;
    }

    var total_node_count: usize = 0;
    for (builds) |*candidate| {
        total_node_count += candidate.navigation_node_count;
        for (candidate.navigationNodes(), 0..) |node, node_index| {
            const first: usize = node.first_edge;
            const end = first + node.edge_count;
            const source = district.NavigationNodeRef{
                .coord = candidate.coord,
                .index = @intCast(node_index),
            };
            for (candidate.navigationEdges()[first..end]) |edge| {
                const target_build_index = findBuildIndex(builds, edge.target.coord) orelse
                    return .target_district_missing;
                const target_build = &builds[target_build_index];
                if (edge.target.index >= target_build.navigation_node_count) {
                    return .target_node_missing;
                }
                if (!nodeHasEdge(target_build, edge.target.index, source)) {
                    return .non_reciprocal_edge;
                }
            }
        }
    }
    for (1..destination_count + 1) |value| {
        const destination = resolveDestination(.{ .value = @intCast(value) }) orelse
            return .invalid_destination_catalog;
        for (destination.anchorSlice()) |anchor| {
            const build_index = findBuildIndex(builds, anchor.coord) orelse
                return .invalid_destination_catalog;
            if (anchor.index >= builds[build_index].navigation_node_count) {
                return .invalid_destination_catalog;
            }
        }
    }

    var visited = [_]bool{false} ** (installed_coords.len * district.max_navigation_nodes);
    const QueueItem = struct { build_index: u8, node_index: u8 };
    var queue: [installed_coords.len * district.max_navigation_nodes]QueueItem = undefined;
    var head: usize = 0;
    var tail: usize = 1;
    queue[0] = .{ .build_index = 0, .node_index = 0 };
    visited[0] = true;
    var visited_count: usize = 0;
    while (head < tail) : (head += 1) {
        const item = queue[head];
        visited_count += 1;
        const candidate = &builds[item.build_index];
        const node = candidate.navigationNodes()[item.node_index];
        const first: usize = node.first_edge;
        const end = first + node.edge_count;
        for (candidate.navigationEdges()[first..end]) |edge| {
            const target_build_index = findBuildIndex(builds, edge.target.coord) orelse
                unreachable;
            const global_index = target_build_index * district.max_navigation_nodes +
                edge.target.index;
            if (visited[global_index]) continue;
            visited[global_index] = true;
            queue[tail] = .{
                .build_index = @intCast(target_build_index),
                .node_index = edge.target.index,
            };
            tail += 1;
        }
    }
    if (visited_count != total_node_count) return .disconnected_route;
    return null;
}

pub fn validateRoute(builds: []const district.DistrictBuild) !void {
    const failure = routeValidationFailure(builds) orelse return;
    return switch (failure) {
        .wrong_build_count => error.NavigationRouteBuildCountMismatch,
        .invalid_build => error.InvalidNavigationRouteBuild,
        .duplicate_district => error.DuplicateNavigationRouteDistrict,
        .missing_installed_district => error.MissingInstalledNavigationRouteDistrict,
        .missing_navigation_fragment => error.MissingDistrictNavigationFragment,
        .target_district_missing => error.NavigationTargetDistrictMissing,
        .target_node_missing => error.NavigationTargetNodeMissing,
        .non_reciprocal_edge => error.NonReciprocalNavigationEdge,
        .invalid_cross_district_edge_count => error.InvalidCrossDistrictNavigationEdgeCount,
        .invalid_destination_catalog => error.InvalidNavigationDestinationCatalog,
        .disconnected_route => error.DisconnectedNavigationRoute,
    };
}

fn findBuildIndex(
    builds: []const district.DistrictBuild,
    coord: district.ChunkCoord,
) ?usize {
    for (builds, 0..) |candidate, index| {
        if (district.ChunkCoord.eql(candidate.coord, coord)) return index;
    }
    return null;
}

fn nodeHasEdge(
    candidate: *const district.DistrictBuild,
    node_index: u8,
    target: district.NavigationNodeRef,
) bool {
    const node = candidate.navigationNodes()[node_index];
    const first: usize = node.first_edge;
    const end = first + node.edge_count;
    for (candidate.navigationEdges()[first..end]) |edge| {
        if (district.NavigationNodeRef.eql(edge.target, target)) return true;
    }
    return false;
}

test "industrial world has matching collision, connected navigation and traversable destinations" {
    var builds: [installed_coords.len]district.DistrictBuild = undefined;
    for (installed_coords, &builds) |coord, *value| value.* = build(coord, current_recipe_version).ready;
    try validateRoute(&builds);
    for (builds) |value| {
        const cold = try presentationPlan(&value, false);
        const resident = try presentationPlan(&value, true);
        try std.testing.expectEqual(value.static_box_count, cold.proxy_box_count);
        try std.testing.expectEqual(@as(u8, 0), resident.proxy_box_count);
        for (value.navigationNodes()) |node| {
            const first: usize = node.first_edge;
            for (value.navigationEdges()[first .. first + node.edge_count]) |edge| {
                if (!district.ChunkCoord.eql(value.coord, edge.target.coord)) continue;
                try std.testing.expect(capsuleTraversalClear(&value, node.position, value.navigation_nodes[edge.target.index].position, .{ .radius = 0.35, .half_height = 0.45, .margin = 0.08 }));
            }
        }
    }
    for (1..destination_count + 1) |id| {
        const destination = resolveDestination(.{ .value = @intCast(id) }).?;
        const logical = build(destination.anchors[0].coord, current_recipe_version).ready;
        try std.testing.expect(capsuleTraversalClear(&logical, destination.position, logical.navigation_nodes[destination.anchors[0].index].position, .{ .radius = 0.35, .half_height = 0.45, .margin = 0.08 }));
    }
}
