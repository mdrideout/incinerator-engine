const std = @import("std");
const content = @import("content");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) return error.ExpectedTwoCookedBundles;
    const allocator = init.gpa;
    const first = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], allocator, .limited(64 * 1024));
    defer allocator.free(first);
    const second = try std.Io.Dir.cwd().readFileAlloc(init.io, args[2], allocator, .limited(64 * 1024));
    defer allocator.free(second);
    if (!std.mem.eql(u8, first, second)) return error.CookIsNotDeterministic;

    var scene = switch (try content.bundle.decode(allocator, first, .{})) {
        .bundle => |value| value,
        .failed => return error.GeneratedBundleIsInvalid,
    };
    defer scene.deinit();
    try verify(scene.view());
}

fn verify(scene: content.bundle.BundleView) !void {
    if (!std.mem.eql(u8, scene.name(scene.bundle_name).?, "district/s3_fixture")) return error.InvalidBundleName;
    if (std.mem.allEqual(u8, &scene.source_digest, 0)) return error.MissingSourceDigest;
    if (scene.nodes.len != 2 or scene.meshes.len != 1 or scene.primitives.len != 1 or
        scene.materials.len != 1 or scene.textures.len != 1 or scene.vertices.len != 3 or
        scene.indices.len != 3 or scene.static_boxes.len != 3) return error.InvalidFixtureCounts;
    if (scene.nodes[0].mesh != 0 or scene.nodes[1].mesh != 0) return error.InstancingWasNotPreserved;
    if (!std.mem.eql(u8, scene.name(scene.nodes[0].name).?, "LeftInstance") or
        !std.mem.eql(u8, scene.name(scene.nodes[1].name).?, "RightInstance")) return error.NodeNamesWereNotPreserved;
    if (scene.nodes[0].local_transform[12] != -2 or scene.nodes[1].local_transform[12] != 2 or
        scene.nodes[1].local_transform[0] != 0.5 or scene.nodes[1].local_transform[10] != 0.5)
    {
        return error.NodeTransformsWereNotPreserved;
    }
    if (scene.primitives[0].material != 0 or scene.materials[0].base_color_texture != 0) {
        return error.MaterialRelationshipWasNotPreserved;
    }
    if (scene.textures[0].width != 1 or scene.textures[0].height != 2 or
        scene.textures[0].format != .rgba8_srgb or scene.textures[0].pixel_size != 8 or
        scene.pixels.len != 8) return error.TextureWasNotDecoded;
    if (!std.meta.eql(scene.materials[0].base_color, [4]f32{ 1.0, 0.5, 0.25, 1.0 })) {
        return error.BaseColorFactorWasNotPreserved;
    }

    const expected_boxes = [_]content.bundle.StaticBox{
        .{ .position = .{ 0, -0.5, 0 }, .half_extents = .{ 7.5, 0.5, 7.5 } },
        .{ .position = .{ -5.5, 1, -2 }, .half_extents = .{ 1, 1, 3 } },
        .{ .position = .{ 3, 0.75, 4.5 }, .half_extents = .{ 2.5, 0.75, 0.75 } },
    };
    if (!std.meta.eql(expected_boxes, scene.static_boxes[0..3].*)) return error.StaticBoxesDiverged;
}
