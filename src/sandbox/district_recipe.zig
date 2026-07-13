//! Canonical district recipe owned by the open-source sandbox host.
//!
//! The reusable district contract owns bounded value types and structural
//! validation. This module owns the actual world layout, installed
//! coordinates, recipe cohort, and exact two-district navigation policy.

const std = @import("std");
const district = @import("district_contract");

pub const current_recipe_version: u32 = 2;
pub const navigation_west_coord = district.ChunkCoord{ .x = 0, .z = 0 };
pub const navigation_east_coord = district.ChunkCoord{ .x = 1, .z = 0 };

/// Visual-host streaming policy for one installed sandbox district. Keeping
/// it next to the logical recipe prevents a composition host from inventing a
/// second coordinate/layout catalog.
pub const PresentationPolicy = struct {
    coord: district.ChunkCoord,
    center_xz: [2]f32,
    half_extent_xz: [2]f32,
    load_margin: f32,
    unload_margin: f32,
};

pub const presentation_policies = [_]PresentationPolicy{
    .{
        .coord = navigation_west_coord,
        .center_xz = .{ 0, 0 },
        .half_extent_xz = .{ 8, 8 },
        .load_margin = 4,
        .unload_margin = 8,
    },
    .{
        .coord = navigation_east_coord,
        .center_xz = .{ district.chunk_span, 0 },
        .half_extent_xz = .{ 8, 8 },
        .load_margin = 4,
        .unload_margin = 8,
    },
};

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
        .decoded_bytes = district.decodedByteCount(3, 0, 0),
        .static_box_count = 3,
    };
    result.static_boxes[0] = .{
        .pose = .{ .position = .{ origin_x, -0.5, origin_z } },
        .half_extents = .{ 7.5, 0.5, 7.5 },
    };
    result.static_boxes[1] = .{
        .pose = .{ .position = .{ origin_x - 5.5, 1.0, origin_z - 2.0 } },
        .half_extents = .{ 1.0, 1.0, 3.0 },
    };
    result.static_boxes[2] = .{
        .pose = .{ .position = .{ origin_x + 3.0, 0.75, origin_z + 4.5 } },
        .half_extents = .{ 2.5, 0.75, 0.75 },
    };
    if (district.ChunkCoord.eql(coord, navigation_west_coord)) {
        populateWestNavigation(&result);
    } else if (district.ChunkCoord.eql(coord, navigation_east_coord)) {
        populateEastNavigation(&result);
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
            cooked.flags != logical.flags or cooked.reserved != logical.reserved) return false;
    }
    return true;
}

fn populateWestNavigation(result: *district.DistrictBuild) void {
    std.debug.assert(district.ChunkCoord.eql(result.coord, navigation_west_coord));
    result.navigation_node_count = 3;
    result.navigation_edge_count = 5;
    result.navigation_nodes[0] = .{
        .position = .{ -4, 0, 3 },
        .first_edge = 0,
        .edge_count = 1,
        .flags = district.navigation_node_terminal,
    };
    result.navigation_nodes[1] = .{
        .position = .{ 2, 0, 3 },
        .first_edge = 1,
        .edge_count = 2,
    };
    result.navigation_nodes[2] = .{
        .position = .{ 7, 0, 3 },
        .first_edge = 3,
        .edge_count = 2,
    };
    result.navigation_edges[0] = .{ .target = .{
        .coord = navigation_west_coord,
        .index = 1,
    } };
    result.navigation_edges[1] = .{ .target = .{
        .coord = navigation_west_coord,
        .index = 0,
    } };
    result.navigation_edges[2] = .{ .target = .{
        .coord = navigation_west_coord,
        .index = 2,
    } };
    result.navigation_edges[3] = .{ .target = .{
        .coord = navigation_west_coord,
        .index = 1,
    } };
    result.navigation_edges[4] = .{ .target = .{
        .coord = navigation_east_coord,
        .index = 0,
    } };
}

fn populateEastNavigation(result: *district.DistrictBuild) void {
    std.debug.assert(district.ChunkCoord.eql(result.coord, navigation_east_coord));
    result.navigation_node_count = 3;
    result.navigation_edge_count = 5;
    result.navigation_nodes[0] = .{
        .position = .{ 9, 0, 3 },
        .first_edge = 0,
        .edge_count = 2,
    };
    result.navigation_nodes[1] = .{
        .position = .{ 14, 0, 3 },
        .first_edge = 2,
        .edge_count = 2,
    };
    result.navigation_nodes[2] = .{
        .position = .{ 20, 0, 3 },
        .first_edge = 4,
        .edge_count = 1,
        .flags = district.navigation_node_terminal,
    };
    result.navigation_edges[0] = .{ .target = .{
        .coord = navigation_west_coord,
        .index = 2,
    } };
    result.navigation_edges[1] = .{ .target = .{
        .coord = navigation_east_coord,
        .index = 1,
    } };
    result.navigation_edges[2] = .{ .target = .{
        .coord = navigation_east_coord,
        .index = 0,
    } };
    result.navigation_edges[3] = .{ .target = .{
        .coord = navigation_east_coord,
        .index = 2,
    } };
    result.navigation_edges[4] = .{ .target = .{
        .coord = navigation_east_coord,
        .index = 1,
    } };
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
    invalid_terminal_count,
    invalid_terminal_degree,
    invalid_internal_degree,
    invalid_cross_district_edge_count,
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

    var terminal_count: usize = 0;
    var cross_district_edge_count: usize = 0;
    var total_node_count: usize = 0;
    for (builds) |*candidate| {
        total_node_count += candidate.navigation_node_count;
        for (candidate.navigationNodes(), 0..) |node, node_index| {
            if (node.terminal()) {
                terminal_count += 1;
                if (node.edge_count != 1) return .invalid_terminal_degree;
            } else if (node.edge_count != 2) {
                return .invalid_internal_degree;
            }
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
    if (terminal_count != 2) return .invalid_terminal_count;
    if (cross_district_edge_count != 2) return .invalid_cross_district_edge_count;

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
        .invalid_terminal_count => error.InvalidNavigationTerminalCount,
        .invalid_terminal_degree => error.InvalidNavigationTerminalDegree,
        .invalid_internal_degree => error.InvalidNavigationInternalDegree,
        .invalid_cross_district_edge_count => error.InvalidCrossDistrictNavigationEdgeCount,
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

test "canonical recipe rejects unsupported cohorts" {
    const unsupported = build(.{ .x = 0, .z = -4 }, current_recipe_version + 1);
    try std.testing.expectEqual(
        current_recipe_version + 1,
        unsupported.failed.unsupported_recipe_version,
    );
}
