const std = @import("std");
const content = @import("content");

const expected_west_file_bytes: usize = 1128;
const expected_east_file_bytes: usize = 1136;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 5) return error.ExpectedTwoDeterministicBundlePairs;
    const allocator = init.gpa;
    const west = try read(init, args[1]);
    defer allocator.free(west);
    const west_repeat = try read(init, args[2]);
    defer allocator.free(west_repeat);
    const east = try read(init, args[3]);
    defer allocator.free(east);
    const east_repeat = try read(init, args[4]);
    defer allocator.free(east_repeat);
    if (!std.mem.eql(u8, west, west_repeat) or
        !std.mem.eql(u8, east, east_repeat))
    {
        return error.CookIsNotDeterministic;
    }
    if (std.mem.eql(u8, west, east)) return error.DistrictBundlesAliased;
    if (west.len != expected_west_file_bytes or
        east.len != expected_east_file_bytes) return error.UnexpectedCookedBundleSize;

    var west_scene = switch (try content.bundle.decode(allocator, west, .{})) {
        .bundle => |value| value,
        .failed => return error.GeneratedBundleIsInvalid,
    };
    defer west_scene.deinit();
    try verifyIdentity(west_scene.bundleIdentity());
    try verifyWest(west_scene.view());

    var east_scene = switch (try content.bundle.decode(allocator, east, .{})) {
        .bundle => |value| value,
        .failed => return error.GeneratedBundleIsInvalid,
    };
    defer east_scene.deinit();
    try verifyIdentity(east_scene.bundleIdentity());
    try verifyEast(east_scene.view());
    if (std.mem.eql(u8, &west_scene.source_digest, &east_scene.source_digest)) {
        return error.DependencyAwareSourceIdentityAliased;
    }
}

fn verifyIdentity(identity: content.bundle.BundleIdentity) !void {
    if (identity.format_version != content.bundle.format_version or
        identity.schema_cohort != content.bundle.schema_cohort or
        identity.format_version != 2 or identity.schema_cohort != 2)
    {
        return error.InvalidCookedBundleCohort;
    }
}

fn read(init: std.process.Init, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        init.io,
        path,
        init.gpa,
        .limited(64 * 1024),
    );
}

fn verifyCommon(scene: content.bundle.BundleView) !void {
    if (std.mem.allEqual(u8, &scene.source_digest, 0)) return error.MissingSourceDigest;
    if (scene.nodes.len != 2 or scene.meshes.len != 1 or scene.primitives.len != 1 or
        scene.materials.len != 1 or scene.textures.len != 1 or scene.vertices.len != 3 or
        scene.indices.len != 3 or scene.static_boxes.len != 6 or
        scene.navigation_nodes.len != 3 or scene.navigation_edges.len != 5)
    {
        return error.InvalidFixtureCounts;
    }
    if (scene.nodes[0].mesh != 0 or scene.nodes[1].mesh != 0) return error.InstancingWasNotPreserved;
    if (scene.primitives[0].material != 0 or scene.materials[0].base_color_texture != 0) {
        return error.MaterialRelationshipWasNotPreserved;
    }
    if (scene.textures[0].width != 1 or scene.textures[0].height != 2 or
        scene.textures[0].format != .rgba8_srgb or scene.textures[0].pixel_size != 8 or
        scene.pixels.len != 8) return error.TextureWasNotDecoded;
}

fn verifyWest(scene: content.bundle.BundleView) !void {
    try verifyCommon(scene);
    if (!std.mem.eql(u8, scene.name(scene.bundle_name).?, "district/s3_fixture")) return error.InvalidBundleName;
    if (!std.mem.eql(u8, scene.name(scene.nodes[0].name).?, "LeftInstance") or
        !std.mem.eql(u8, scene.name(scene.nodes[1].name).?, "RightInstance")) return error.NodeNamesWereNotPreserved;
    if (scene.nodes[0].local_transform[12] != -2 or scene.nodes[1].local_transform[12] != 2 or
        scene.nodes[1].local_transform[0] != 0.5 or scene.nodes[1].local_transform[10] != 0.5)
    {
        return error.NodeTransformsWereNotPreserved;
    }
    if (!std.meta.eql(scene.materials[0].base_color, [4]f32{ 1.0, 0.5, 0.25, 1.0 })) {
        return error.BaseColorFactorWasNotPreserved;
    }

    const expected_boxes = [_]content.bundle.StaticBox{
        .{ .position = .{ 0, -0.5, 0 }, .half_extents = .{ 7.5, 0.5, 7.5 } },
        .{ .position = .{ -5.5, 1, -2 }, .half_extents = .{ 1, 1, 3 } },
        .{ .position = .{ 3, 0.75, 4.5 }, .half_extents = .{ 2.5, 0.75, 0.75 } },
        .{ .position = .{ 0, 1.5, -8.25 }, .half_extents = .{ 8.25, 1.5, 0.25 } },
        .{ .position = .{ 0, 1.5, 8.25 }, .half_extents = .{ 8.25, 1.5, 0.25 } },
        .{ .position = .{ -8.25, 1.5, 0 }, .half_extents = .{ 0.25, 1.5, 8.25 } },
    };
    if (!std.meta.eql(expected_boxes, scene.static_boxes[0..6].*)) return error.StaticBoxesDiverged;
    const expected_nodes = [_]content.bundle.NavigationNode{
        .{ .position = .{ -4, 0, 3 }, .first_edge = 0, .edge_count = 1, .flags = content.bundle.navigation_node_terminal },
        .{ .position = .{ 2, 0, 3 }, .first_edge = 1, .edge_count = 2 },
        .{ .position = .{ 7, 0, 3 }, .first_edge = 3, .edge_count = 2 },
    };
    const expected_edges = [_]content.bundle.NavigationEdge{
        .{ .target_coord = .{ 0, 0 }, .target_node = 1 },
        .{ .target_coord = .{ 0, 0 }, .target_node = 0 },
        .{ .target_coord = .{ 0, 0 }, .target_node = 2 },
        .{ .target_coord = .{ 0, 0 }, .target_node = 1 },
        .{ .target_coord = .{ 1, 0 }, .target_node = 0 },
    };
    if (!std.meta.eql(expected_nodes, scene.navigation_nodes[0..3].*) or
        !std.meta.eql(expected_edges, scene.navigation_edges[0..5].*))
    {
        return error.NavigationFragmentDiverged;
    }
}

fn verifyEast(scene: content.bundle.BundleView) !void {
    try verifyCommon(scene);
    if (!std.mem.eql(u8, scene.name(scene.bundle_name).?, "district/s6_east")) {
        return error.InvalidBundleName;
    }
    if (!std.mem.eql(u8, scene.name(scene.nodes[0].name).?, "EastBoundaryMarker") or
        !std.mem.eql(u8, scene.name(scene.nodes[1].name).?, "EastInteriorMarker"))
    {
        return error.NodeNamesWereNotPreserved;
    }
    if (scene.nodes[0].local_transform[12] != 14 or
        scene.nodes[1].local_transform[12] != 18 or
        scene.nodes[1].local_transform[0] != 0.75 or
        scene.nodes[1].local_transform[10] != 0.75)
    {
        return error.NodeTransformsWereNotPreserved;
    }
    if (!std.meta.eql(scene.materials[0].base_color, [4]f32{ 0.2, 0.55, 1.0, 1.0 })) {
        return error.BaseColorFactorWasNotPreserved;
    }
    const expected_boxes = [_]content.bundle.StaticBox{
        .{ .position = .{ 16, -0.5, 0 }, .half_extents = .{ 7.5, 0.5, 7.5 } },
        .{ .position = .{ 10.5, 1, -2 }, .half_extents = .{ 1, 1, 3 } },
        .{ .position = .{ 19, 0.75, 4.5 }, .half_extents = .{ 2.5, 0.75, 0.75 } },
        .{ .position = .{ 16, 1.5, -8.25 }, .half_extents = .{ 8.25, 1.5, 0.25 } },
        .{ .position = .{ 16, 1.5, 8.25 }, .half_extents = .{ 8.25, 1.5, 0.25 } },
        .{ .position = .{ 24.25, 1.5, 0 }, .half_extents = .{ 0.25, 1.5, 8.25 } },
    };
    if (!std.meta.eql(expected_boxes, scene.static_boxes[0..6].*)) {
        return error.StaticBoxesDiverged;
    }
    const expected_nodes = [_]content.bundle.NavigationNode{
        .{ .position = .{ 9, 0, 3 }, .first_edge = 0, .edge_count = 2 },
        .{ .position = .{ 14, 0, 3 }, .first_edge = 2, .edge_count = 2 },
        .{ .position = .{ 20, 0, 3 }, .first_edge = 4, .edge_count = 1, .flags = content.bundle.navigation_node_terminal },
    };
    const expected_edges = [_]content.bundle.NavigationEdge{
        .{ .target_coord = .{ 0, 0 }, .target_node = 2 },
        .{ .target_coord = .{ 1, 0 }, .target_node = 1 },
        .{ .target_coord = .{ 1, 0 }, .target_node = 0 },
        .{ .target_coord = .{ 1, 0 }, .target_node = 2 },
        .{ .target_coord = .{ 1, 0 }, .target_node = 1 },
    };
    if (!std.meta.eql(expected_nodes, scene.navigation_nodes[0..3].*) or
        !std.meta.eql(expected_edges, scene.navigation_edges[0..5].*))
    {
        return error.NavigationFragmentDiverged;
    }
}
