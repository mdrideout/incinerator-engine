const std = @import("std");
const content = @import("content");
const district = @import("district_contract");
const sandbox_recipe = @import("sandbox_district_recipe");

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
        identity.format_version != 3 or identity.schema_cohort != 4)
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
        scene.indices.len != 3 or scene.static_boxes.len != sandbox_recipe.static_box_count or
        scene.navigation_nodes.len != 8 or scene.navigation_edges.len != 16)
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

    try verifyLogicalRecipe(scene, .{ .x = 0, .z = 0 });
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
    try verifyLogicalRecipe(scene, .{ .x = 1, .z = 0 });
}

fn verifyLogicalRecipe(
    scene: content.bundle.BundleView,
    coord: district.ChunkCoord,
) !void {
    const logical = switch (sandbox_recipe.build(
        .{ .x = coord.x, .z = coord.z },
        sandbox_recipe.current_recipe_version,
    )) {
        .ready => |value| value,
        .failed => return error.LogicalRecipeUnavailable,
    };
    if (scene.static_boxes.len != logical.boxes().len or
        scene.navigation_nodes.len != logical.navigationNodes().len or
        scene.navigation_edges.len != logical.navigationEdges().len)
    {
        return error.LogicalRecipeCountDiverged;
    }
    for (scene.static_boxes, logical.boxes()) |actual, expected| {
        if (!std.meta.eql(actual.position, expected.pose.position) or
            !std.meta.eql(actual.rotation, expected.pose.rotation) or
            !std.meta.eql(actual.half_extents, expected.half_extents))
        {
            return error.StaticBoxesDiverged;
        }
    }
    for (scene.navigation_nodes, logical.navigationNodes()) |actual, expected| {
        if (!std.meta.eql(actual.position, expected.position) or
            actual.first_edge != expected.first_edge or
            actual.edge_count != expected.edge_count or
            actual.flags != expected.flags or
            actual.reserved != expected.reserved)
        {
            return error.NavigationFragmentDiverged;
        }
    }
    for (scene.navigation_edges, logical.navigationEdges()) |actual, expected| {
        if (actual.target_coord[0] != expected.target.coord.x or
            actual.target_coord[1] != expected.target.coord.z or
            actual.target_node != expected.target.index or
            actual.cost != expected.cost)
        {
            return error.NavigationFragmentDiverged;
        }
    }
}
