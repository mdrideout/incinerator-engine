//! Canonical district recipe owned by the open-source sandbox host.
//!
//! The reusable district contract owns bounded value types and structural
//! validation. This module owns the actual world layout, installed
//! coordinates, recipe cohort, and exact two-district navigation policy.

const std = @import("std");
const district = @import("district_contract");
const navigation = @import("navigation_contract");

pub const current_recipe_version: u32 = 7;
pub const catalog_semantic_id = "incinerator.s13.population-two-district";
pub const catalog_wire_schema: u16 = 1;
pub const static_box_count: u8 = 3;
pub const blocking_proxy_count: u8 = static_box_count - 1;
pub const navigation_west_coord = district.ChunkCoord{ .x = 0, .z = 0 };
pub const navigation_east_coord = district.ChunkCoord{ .x = 1, .z = 0 };

pub const player_plaza = navigation.DestinationId{ .value = 1 };
pub const depot_forecourt = navigation.DestinationId{ .value = 2 };
pub const south_gate_approach = navigation.DestinationId{ .value = 3 };
pub const market_terminal = navigation.DestinationId{ .value = 4 };
pub const alley_junction = navigation.DestinationId{ .value = 5 };
pub const transit_yard = navigation.DestinationId{ .value = 6 };
pub const player_plaza_companion = navigation.DestinationId{ .value = 7 };
pub const depot_forecourt_companion = navigation.DestinationId{ .value = 8 };
pub const south_gate_companion = navigation.DestinationId{ .value = 9 };
pub const north_walk_first = navigation.DestinationId{ .value = 10 };
pub const north_walk_second = navigation.DestinationId{ .value = 11 };
pub const market_terminal_second = navigation.DestinationId{ .value = 12 };
pub const market_terminal_third = navigation.DestinationId{ .value = 13 };
pub const alley_junction_companion = navigation.DestinationId{ .value = 14 };
pub const transit_yard_companion = navigation.DestinationId{ .value = 15 };
pub const east_court = navigation.DestinationId{ .value = 16 };
pub const destination_count: usize = 16;

pub fn resolveDestination(id: navigation.DestinationId) ?navigation.Destination {
    const entry: navigation.Destination = switch (id.value) {
        1 => .{
            .id = player_plaza,
            .position = .{ -6.5, 0, 6.2 },
            .arrival_radius = 0.25,
            .anchors = .{ nodeRef(navigation_west_coord, 0), .{} },
            .anchor_count = 1,
        },
        2 => .{
            .id = depot_forecourt,
            .position = .{ 4, 0, 6.3 },
            .arrival_radius = 0.25,
            .anchors = .{ nodeRef(navigation_west_coord, 5), .{} },
            .anchor_count = 1,
        },
        3 => .{
            .id = south_gate_approach,
            .position = .{ 3, 0, -5.8 },
            .arrival_radius = 0.25,
            .anchors = .{ nodeRef(navigation_west_coord, 3), .{} },
            .anchor_count = 1,
        },
        4 => .{
            .id = market_terminal,
            .position = .{ 18.5, 0, 6.3 },
            .arrival_radius = 0.25,
            .anchors = .{ nodeRef(navigation_east_coord, 2), .{} },
            .anchor_count = 1,
        },
        5 => .{
            .id = alley_junction,
            .position = .{ 13, 0, -0.8 },
            .arrival_radius = 0.25,
            .anchors = .{ nodeRef(navigation_east_coord, 7), .{} },
            .anchor_count = 1,
        },
        6 => .{
            .id = transit_yard,
            .position = .{ 19, 0, -5.7 },
            .arrival_radius = 0.25,
            .anchors = .{ nodeRef(navigation_east_coord, 4), .{} },
            .anchor_count = 1,
        },
        7 => .{
            .id = player_plaza_companion,
            .position = .{ -3.5, 0, 6.2 },
            .arrival_radius = 0.25,
            .anchors = .{ nodeRef(navigation_west_coord, 0), .{} },
            .anchor_count = 1,
        },
        8 => .{
            .id = depot_forecourt_companion,
            .position = .{ 5.8, 0, 5.2 },
            .arrival_radius = 0.25,
            .anchors = .{ nodeRef(navigation_west_coord, 5), .{} },
            .anchor_count = 1,
        },
        9 => .{
            .id = south_gate_companion,
            .position = .{ 5.3, 0, -4.8 },
            .arrival_radius = 0.25,
            .anchors = .{ nodeRef(navigation_west_coord, 7), .{} },
            .anchor_count = 1,
        },
        10 => .{
            .id = north_walk_first,
            .position = .{ 2, 0, 1.5 },
            .arrival_radius = 0.25,
            .anchors = .{ nodeRef(navigation_west_coord, 4), .{} },
            .anchor_count = 1,
        },
        11 => .{
            .id = north_walk_second,
            .position = .{ 4.5, 0, 2.5 },
            .arrival_radius = 0.25,
            .anchors = .{ nodeRef(navigation_west_coord, 4), .{} },
            .anchor_count = 1,
        },
        12 => .{
            .id = market_terminal_second,
            .position = .{ 20.5, 0, 6.3 },
            .arrival_radius = 0.25,
            .anchors = .{ nodeRef(navigation_east_coord, 2), .{} },
            .anchor_count = 1,
        },
        13 => .{
            .id = market_terminal_third,
            .position = .{ 22.5, 0, 5.3 },
            .arrival_radius = 0.25,
            .anchors = .{ nodeRef(navigation_east_coord, 2), .{} },
            .anchor_count = 1,
        },
        14 => .{
            .id = alley_junction_companion,
            .position = .{ 14.5, 0, 0.6 },
            .arrival_radius = 0.25,
            .anchors = .{ nodeRef(navigation_east_coord, 7), .{} },
            .anchor_count = 1,
        },
        15 => .{
            .id = transit_yard_companion,
            .position = .{ 21.5, 0, -5.5 },
            .arrival_radius = 0.25,
            .anchors = .{ nodeRef(navigation_east_coord, 4), .{} },
            .anchor_count = 1,
        },
        16 => .{
            .id = east_court,
            .position = .{ 12.5, 0, 5.8 },
            .arrival_radius = 0.25,
            .anchors = .{ nodeRef(navigation_east_coord, 1), .{} },
            .anchor_count = 1,
        },
        else => return null,
    };
    entry.validate() catch return null;
    return entry;
}

pub fn destinationName(id: navigation.DestinationId) ?[]const u8 {
    return switch (id.value) {
        1 => "player_plaza",
        2 => "depot_forecourt",
        3 => "south_gate_approach",
        4 => "market_terminal",
        5 => "alley_junction",
        6 => "transit_yard",
        7 => "player_plaza_companion",
        8 => "depot_forecourt_companion",
        9 => "south_gate_companion",
        10 => "north_walk_first",
        11 => "north_walk_second",
        12 => "market_terminal_second",
        13 => "market_terminal_third",
        14 => "alley_junction_companion",
        15 => "transit_yard_companion",
        16 => "east_court",
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
        .half_extent_xz = .{ 8, 8 },
        // The sandbox has one adjacent district in either direction. Warm
        // that visual content from the neighboring district center while
        // retaining the existing narrow logical/collision boundary.
        .prefetch_load_margin = 24,
        .prefetch_unload_margin = 28,
        .authority_load_margin = 4,
        .authority_unload_margin = 8,
    },
    .{
        .coord = navigation_east_coord,
        .center_xz = .{ district.chunk_span, 0 },
        .half_extent_xz = .{ 8, 8 },
        .prefetch_load_margin = 24,
        .prefetch_unload_margin = 28,
        .authority_load_margin = 4,
        .authority_unload_margin = 8,
    },
};

/// Product presentation responsibility for each canonical static box.
///
/// Cooked meshes are authored decoration until a future content schema can
/// explicitly bind mesh instances to collision. A blocking box therefore
/// keeps a simple proxy in every residency state. The support surface is
/// presented by the composition-owned ground mesh and must not be drawn a
/// second time as a coplanar district proxy.
pub const StaticBoxPresentation = enum {
    host_support_surface,
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
    for (logical_build.boxes(), 0..) |_, box_index| {
        switch (staticBoxPresentation(box_index) orelse
            return error.UnknownDistrictStaticBoxPresentation) {
            .host_support_surface => {},
            .blocking_proxy => {
                plan.proxy_box_indices[plan.proxy_box_count] = @intCast(box_index);
                plan.proxy_box_count += 1;
            },
        }
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
        if (role != .blocking_proxy) continue;

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
    return switch (box_index) {
        0 => .host_support_surface,
        1, 2 => .blocking_proxy,
        else => null,
    };
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

pub fn build(
    coord: district.ChunkCoord,
    recipe_version: u32,
) district.ProceduralResult {
    if (recipe_version != current_recipe_version) {
        return .{ .failed = .{ .unsupported_recipe_version = recipe_version } };
    }

    const origin_x = @as(f32, @floatFromInt(coord.x)) * district.chunk_span;
    const origin_z = @as(f32, @floatFromInt(coord.z)) * district.chunk_span;
    var result = district.DistrictBuild{
        .coord = coord,
        .recipe_version = recipe_version,
        .checksum = 0,
        .decoded_bytes = district.decodedByteCount(static_box_count, 0, 0),
        .static_box_count = static_box_count,
    };
    result.static_boxes[0] = .{
        .pose = .{ .position = .{ origin_x, -0.5, origin_z } },
        .half_extents = .{ 7.5, 0.5, 7.5 },
    };
    if (district.ChunkCoord.eql(coord, navigation_west_coord)) {
        result.static_boxes[1] = .{
            .pose = .{ .position = .{ 0, 1.0, 4.8 } },
            .half_extents = .{ 1.25, 1.0, 0.5 },
        };
        result.static_boxes[2] = .{
            .pose = .{ .position = .{ 0, 0.75, -4.8 } },
            .half_extents = .{ 1.25, 0.75, 0.5 },
        };
        populateWestNavigation(&result);
    } else if (district.ChunkCoord.eql(coord, navigation_east_coord)) {
        result.static_boxes[1] = .{
            .pose = .{ .position = .{ 16.0, 1.0, 2.0 } },
            .half_extents = .{ 1.0, 1.0, 0.5 },
        };
        result.static_boxes[2] = .{
            .pose = .{ .position = .{ 16.0, 0.75, -2.0 } },
            .half_extents = .{ 1.0, 0.75, 0.5 },
        };
        populateEastNavigation(&result);
    } else {
        result.static_boxes[1] = .{
            .pose = .{ .position = .{ origin_x - 5.5, 1.0, origin_z - 2.0 } },
            .half_extents = .{ 1.0, 1.0, 3.0 },
        };
        result.static_boxes[2] = .{
            .pose = .{ .position = .{ origin_x + 3.0, 0.75, origin_z + 4.5 } },
            .half_extents = .{ 2.5, 0.75, 0.75 },
        };
    }
    result.decoded_bytes = district.decodedByteCount(
        result.static_box_count,
        result.navigation_node_count,
        result.navigation_edge_count,
    );
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

fn populateWestNavigation(result: *district.DistrictBuild) void {
    std.debug.assert(district.ChunkCoord.eql(result.coord, navigation_west_coord));
    result.navigation_node_count = 8;
    result.navigation_edge_count = 16;
    result.navigation_nodes[0] = .{ .position = .{ -5, 0, 5 }, .first_edge = 0, .edge_count = 1, .flags = district.navigation_node_terminal };
    result.navigation_nodes[1] = .{ .position = .{ -5, 0, 3 }, .first_edge = 1, .edge_count = 3 };
    result.navigation_nodes[2] = .{ .position = .{ -5, 0, -3 }, .first_edge = 4, .edge_count = 2 };
    result.navigation_nodes[3] = .{ .position = .{ 3, 0, -3 }, .first_edge = 6, .edge_count = 2 };
    result.navigation_nodes[4] = .{ .position = .{ 2, 0, 3 }, .first_edge = 8, .edge_count = 2 };
    result.navigation_nodes[5] = .{ .position = .{ 4, 0, 5 }, .first_edge = 10, .edge_count = 2 };
    result.navigation_nodes[6] = .{ .position = .{ 7, 0, 4 }, .first_edge = 12, .edge_count = 2 };
    result.navigation_nodes[7] = .{ .position = .{ 7, 0, -3 }, .first_edge = 14, .edge_count = 2 };

    result.navigation_edges[0] = navEdge(navigation_west_coord, 1, 200);
    result.navigation_edges[1] = navEdge(navigation_west_coord, 0, 200);
    result.navigation_edges[2] = navEdge(navigation_west_coord, 2, 600);
    result.navigation_edges[3] = navEdge(navigation_west_coord, 4, 700);
    result.navigation_edges[4] = navEdge(navigation_west_coord, 1, 600);
    result.navigation_edges[5] = navEdge(navigation_west_coord, 3, 800);
    result.navigation_edges[6] = navEdge(navigation_west_coord, 2, 800);
    result.navigation_edges[7] = navEdge(navigation_west_coord, 7, 400);
    result.navigation_edges[8] = navEdge(navigation_west_coord, 1, 700);
    result.navigation_edges[9] = navEdge(navigation_west_coord, 5, 283);
    result.navigation_edges[10] = navEdge(navigation_west_coord, 4, 283);
    result.navigation_edges[11] = navEdge(navigation_west_coord, 6, 316);
    result.navigation_edges[12] = navEdge(navigation_west_coord, 5, 316);
    result.navigation_edges[13] = navEdge(navigation_east_coord, 0, 200);
    result.navigation_edges[14] = navEdge(navigation_west_coord, 3, 400);
    result.navigation_edges[15] = navEdge(navigation_east_coord, 6, 200);
}

fn populateEastNavigation(result: *district.DistrictBuild) void {
    std.debug.assert(district.ChunkCoord.eql(result.coord, navigation_east_coord));
    result.navigation_node_count = 8;
    result.navigation_edge_count = 16;
    result.navigation_nodes[0] = .{ .position = .{ 9, 0, 4 }, .first_edge = 0, .edge_count = 2 };
    result.navigation_nodes[1] = .{ .position = .{ 13, 0, 4 }, .first_edge = 2, .edge_count = 3 };
    result.navigation_nodes[2] = .{ .position = .{ 20, 0, 5 }, .first_edge = 5, .edge_count = 1, .flags = district.navigation_node_terminal };
    result.navigation_nodes[3] = .{ .position = .{ 20, 0, 0 }, .first_edge = 6, .edge_count = 2 };
    result.navigation_nodes[4] = .{ .position = .{ 20, 0, -4 }, .first_edge = 8, .edge_count = 2 };
    result.navigation_nodes[5] = .{ .position = .{ 14, 0, -4 }, .first_edge = 10, .edge_count = 2 };
    result.navigation_nodes[6] = .{ .position = .{ 9, 0, -3 }, .first_edge = 12, .edge_count = 2 };
    result.navigation_nodes[7] = .{ .position = .{ 14, 0, 0 }, .first_edge = 14, .edge_count = 2 };

    result.navigation_edges[0] = navEdge(navigation_west_coord, 6, 200);
    result.navigation_edges[1] = navEdge(navigation_east_coord, 1, 400);
    result.navigation_edges[2] = navEdge(navigation_east_coord, 0, 400);
    result.navigation_edges[3] = navEdge(navigation_east_coord, 2, 707);
    result.navigation_edges[4] = navEdge(navigation_east_coord, 7, 412);
    result.navigation_edges[5] = navEdge(navigation_east_coord, 1, 707);
    result.navigation_edges[6] = navEdge(navigation_east_coord, 4, 400);
    result.navigation_edges[7] = navEdge(navigation_east_coord, 7, 600);
    result.navigation_edges[8] = navEdge(navigation_east_coord, 3, 400);
    result.navigation_edges[9] = navEdge(navigation_east_coord, 5, 600);
    result.navigation_edges[10] = navEdge(navigation_east_coord, 4, 600);
    result.navigation_edges[11] = navEdge(navigation_east_coord, 6, 500);
    result.navigation_edges[12] = navEdge(navigation_west_coord, 7, 200);
    result.navigation_edges[13] = navEdge(navigation_east_coord, 5, 500);
    result.navigation_edges[14] = navEdge(navigation_east_coord, 1, 412);
    result.navigation_edges[15] = navEdge(navigation_east_coord, 3, 600);
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
    if (builds.len != 2) return .wrong_build_count;
    for (builds, 0..) |*candidate, index| {
        if (candidate.validationFailure() != null) return .invalid_build;
        if (candidate.navigation_node_count == 0) return .missing_navigation_fragment;
        for (builds[0..index]) |earlier| {
            if (district.ChunkCoord.eql(earlier.coord, candidate.coord)) {
                return .duplicate_district;
            }
        }
    }
    if (findBuildIndex(builds, navigation_west_coord) == null or
        findBuildIndex(builds, navigation_east_coord) == null)
    {
        return .missing_installed_district;
    }

    var cross_district_edge_count: usize = 0;
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
                if (!district.ChunkCoord.eql(candidate.coord, edge.target.coord)) {
                    cross_district_edge_count += 1;
                }
                if (!nodeHasEdge(target_build, edge.target.index, source)) {
                    return .non_reciprocal_edge;
                }
            }
        }
    }
    if (cross_district_edge_count != 4) return .invalid_cross_district_edge_count;
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

    var visited = [_]bool{false} ** (2 * district.max_navigation_nodes);
    const QueueItem = struct { build_index: u8, node_index: u8 };
    var queue: [2 * district.max_navigation_nodes]QueueItem = undefined;
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

test "canonical recipe is deterministic, bounded, and coordinate-specific" {
    const coord = district.ChunkCoord{ .x = 0, .z = -4 };
    const first = build(coord, current_recipe_version).ready;
    const repeated = build(coord, current_recipe_version).ready;
    try first.validate();
    try std.testing.expectEqualDeep(first, repeated);
    try std.testing.expect(first.static_box_count <= district.max_static_boxes);
    try std.testing.expect(first.decoded_bytes <= district.max_decoded_bytes);

    const neighbor = build(.{ .x = 1, .z = -4 }, current_recipe_version).ready;
    try neighbor.validate();
    try std.testing.expect(first.checksum != neighbor.checksum);
}

test "installed recipe carries one exact connected bidirectional route" {
    const west = build(navigation_west_coord, current_recipe_version).ready;
    const east = build(navigation_east_coord, current_recipe_version).ready;
    const forward = [_]district.DistrictBuild{ west, east };
    try validateRoute(&forward);
    const reverse = [_]district.DistrictBuild{ east, west };
    try validateRoute(&reverse);
}

test "resident authored content cannot replace canonical blocker proxies" {
    const west = build(navigation_west_coord, current_recipe_version).ready;
    const staged = try presentationPlan(&west, false);
    const resident = try presentationPlan(&west, true);

    try std.testing.expect(!staged.authored_scene_resident);
    try std.testing.expect(resident.authored_scene_resident);
    try std.testing.expectEqual(@as(u8, 2), staged.proxy_box_count);
    try std.testing.expectEqualSlices(u8, staged.proxyBoxIndices(), resident.proxyBoxIndices());
    for (west.boxes(), 0..) |_, box_index| {
        const role = staticBoxPresentation(box_index).?;
        try std.testing.expectEqual(
            role == .blocking_proxy,
            resident.presentsBlockingBox(box_index),
        );
    }
}

test "capsule clearance shares the canonical blocking-box catalog" {
    const west = build(navigation_west_coord, current_recipe_version).ready;
    const capsule = CapsuleClearance{
        .radius = 0.4,
        .half_height = 0.5,
        .margin = 0.5,
    };
    const spawn = [3]f32{ -2, 0, 4 };

    try std.testing.expect(capsuleTraversalClear(&west, spawn, spawn, capsule));
    for ([_][3]f32{
        .{ -3, 0, 4 },
        .{ -1, 0, 4 },
        .{ -2, 0, 3 },
        .{ -2, 0, 5 },
    }) |destination| {
        try std.testing.expect(capsuleTraversalClear(&west, spawn, destination, capsule));
    }

    // The previous spawn sat at the physics predictive-contact threshold of
    // the low east wall and must remain rejected by the explicit margin.
    const previous_spawn = [3]f32{ 0, 0, 4 };
    try std.testing.expect(!capsuleTraversalClear(
        &west,
        previous_spawn,
        previous_spawn,
        capsule,
    ));
    try std.testing.expect(!capsuleTraversalClear(
        &west,
        spawn,
        .{ 4, 0, 4 },
        capsule,
    ));
}

test "former route perimeter planes remain open traversal" {
    const west = build(navigation_west_coord, current_recipe_version).ready;
    const east = build(navigation_east_coord, current_recipe_version).ready;
    const capsule = CapsuleClearance{
        .radius = 0.4,
        .half_height = 0.5,
        .margin = 0.1,
    };

    // North, south, west, and east were recipe-4 containment planes. Sparse
    // diagnostic space outside authored content is intentionally traversable;
    // only the two authored obstacle boxes remain blocking proxies.
    try std.testing.expect(capsuleTraversalClear(
        &west,
        .{ 0, 0, -7 },
        .{ 0, 0, -9 },
        capsule,
    ));
    try std.testing.expect(capsuleTraversalClear(
        &west,
        .{ 0, 0, 7 },
        .{ 0, 0, 9 },
        capsule,
    ));
    try std.testing.expect(capsuleTraversalClear(
        &west,
        .{ -7, 0, 6 },
        .{ -9, 0, 6 },
        capsule,
    ));
    try std.testing.expect(capsuleTraversalClear(
        &east,
        .{ 23, 0, 6 },
        .{ 25, 0, 6 },
        capsule,
    ));
}

test "canonical recipe rejects unsupported cohorts" {
    const unsupported = build(.{ .x = 0, .z = -4 }, current_recipe_version + 1);
    try std.testing.expectEqual(
        current_recipe_version + 1,
        unsupported.failed.unsupported_recipe_version,
    );
}
