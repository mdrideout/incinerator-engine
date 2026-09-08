//! Translate validated cooked scenes into owned, content-sized GPU uploads.
//! Arrays follow actual authored data; scene fixture limits are not storage.
const std = @import("std");
const content = @import("content");
const gpu = @import("district_gpu_registry.zig");
const bundle = content.bundle;
const assets = @import("engine_contracts").assets;
const UploadVertex = @typeInfo(@TypeOf(@as(gpu.MeshUpload, undefined).vertices)).pointer.child;

pub const UploadPlan = struct {
    arena: std.heap.ArenaAllocator,
    upload: gpu.SceneUpload,

    pub fn deinit(self: *UploadPlan) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn sceneUpload(self: *const UploadPlan) gpu.SceneUpload {
        return self.upload;
    }
};

pub fn build(backing_allocator: std.mem.Allocator, source: bundle.BundleView) !UploadPlan {
    if (source.primitives.len == 0 or source.materials.len == 0 or source.nodes.len == 0) return error.EmptyDistrictScene;
    var arena = std.heap.ArenaAllocator.init(backing_allocator);
    errdefer arena.deinit();
    const allocator = arena.allocator();
    const vertices = try allocator.alloc(UploadVertex, source.vertices.len);
    for (source.vertices, vertices) |vertex, *target| {
        for (vertex.position ++ vertex.normal ++ vertex.texcoord) |value| {
            if (!std.math.isFinite(value)) return error.InvalidDistrictSceneVertex;
        }
        target.* = .{ .position = vertex.position, .normal = vertex.normal, .texcoord = vertex.texcoord };
    }
    const meshes = try allocator.alloc(gpu.MeshUpload, source.primitives.len);
    for (source.primitives, meshes) |primitive, *target| {
        const primitive_vertices = try rangeFromSlice(vertices, primitive.first_vertex, primitive.vertex_count);
        const global_indices = try rangeFromSlice(source.indices, primitive.first_index, primitive.index_count);
        if (primitive_vertices.len == 0 or global_indices.len == 0 or global_indices.len % 3 != 0) return error.InvalidDistrictScenePrimitive;
        if (primitive.material >= source.materials.len) return error.InvalidDistrictSceneMaterial;
        const indices = try allocator.alloc(u32, global_indices.len);
        for (global_indices, indices) |index, *local| {
            if (index < primitive.first_vertex or index - primitive.first_vertex >= primitive.vertex_count) return error.InvalidDistrictSceneIndex;
            local.* = index - primitive.first_vertex;
        }
        target.* = .{ .vertices = primitive_vertices, .indices = indices, .material_index = std.math.cast(u16, primitive.material) orelse return error.InvalidDistrictSceneMaterial };
    }
    const bundle_key = source.name(source.bundle_name) orelse return error.InvalidDistrictSceneName;
    for (source.meshes) |mesh| {
        const id = try assets.deriveGameAssetId(.mesh, bundle_key, source.name(mesh.name) orelse return error.InvalidDistrictSceneName);
        const primitives = try rangeFromSlice(meshes, mesh.first_primitive, mesh.primitive_count);
        for (primitives) |*primitive| primitive.asset_id = id;
    }
    const textures = try allocator.alloc(gpu.TextureUpload, source.textures.len);
    for (source.textures, textures) |texture, *target| {
        const pixels = try rangeFromSlice(source.pixels, texture.pixel_offset, texture.pixel_size);
        const expected = try std.math.mul(u64, try std.math.mul(u64, texture.width, texture.height), 4);
        if (texture.width == 0 or texture.height == 0 or expected != pixels.len) return error.InvalidDistrictSceneTexture;
        target.* = .{ .width = texture.width, .height = texture.height, .format = switch (texture.format) {
            .rgba8_unorm => .rgba8_unorm,
            .rgba8_srgb => .rgba8_srgb,
            else => return error.InvalidDistrictSceneTexture,
        }, .min_filter = switch (texture.sampler.min_filter) {
            .nearest => .nearest,
            .linear => .linear,
            else => return error.InvalidDistrictSceneSampler,
        }, .mag_filter = switch (texture.sampler.mag_filter) {
            .nearest => .nearest,
            .linear => .linear,
            else => return error.InvalidDistrictSceneSampler,
        }, .address_u = try addressMode(texture.sampler.address_u), .address_v = try addressMode(texture.sampler.address_v), .rgba8 = pixels };
    }
    const materials = try allocator.alloc(gpu.MaterialUpload, source.materials.len);
    for (source.materials, materials) |material, *target| {
        if (material.flags != 0) return error.InvalidDistrictSceneMaterial;
        target.* = .{ .asset_id = try assets.deriveGameAssetId(.material, bundle_key, source.name(material.name) orelse return error.InvalidDistrictSceneName), .base_color = material.base_color, .metallic = material.metallic, .roughness = material.roughness, .normal_scale = material.normal_scale, .occlusion_strength = material.occlusion_strength, .emissive = material.emissive };
        inline for (.{ "base_color_texture", "metallic_roughness_texture", "normal_texture", "occlusion_texture", "emissive_texture" }) |field| {
            const index = @field(material, field);
            if (index != bundle.none_index) {
                if (index >= textures.len) return error.InvalidDistrictSceneTexture;
                @field(target, field) = std.math.cast(u16, index) orelse return error.InvalidDistrictSceneTexture;
            }
        }
        try target.surface().validate();
    }
    const transforms = try allocator.alloc([16]f32, source.nodes.len);
    var instances: std.ArrayList(gpu.InstanceUpload) = .empty;
    for (source.nodes, 0..) |node, node_index| {
        const world = if (node.parent == bundle.none_index) node.local_transform else blk: {
            if (node.parent >= node_index) return error.InvalidDistrictSceneHierarchy;
            break :blk multiplyColumnMajor(transforms[node.parent], node.local_transform);
        };
        for (world) |value| if (!std.math.isFinite(value)) return error.InvalidDistrictSceneTransform;
        transforms[node_index] = world;
        if (node.mesh == bundle.none_index) continue;
        if (node.mesh >= source.meshes.len) return error.InvalidDistrictSceneMesh;
        const mesh = source.meshes[node.mesh];
        _ = try rangeFromSlice(source.primitives, mesh.first_primitive, mesh.primitive_count);
        for (0..mesh.primitive_count) |offset| {
            try instances.append(allocator, .{ .mesh_index = std.math.cast(u16, @as(usize, mesh.first_primitive) + offset) orelse return error.InvalidDistrictSceneMesh, .transform = world });
        }
    }
    if (instances.items.len == 0) return error.EmptyDistrictScene;
    const owned_instances = try instances.toOwnedSlice(allocator);
    return .{ .arena = arena, .upload = .{ .meshes = meshes, .textures = textures, .materials = materials, .instances = owned_instances } };
}

fn addressMode(value: bundle.SamplerAddressMode) !gpu.TextureAddressMode {
    return switch (value) {
        .clamp_to_edge => .clamp_to_edge,
        .mirrored_repeat => .mirrored_repeat,
        .repeat => .repeat,
        else => error.InvalidDistrictSceneSampler,
    };
}

fn rangeFromSlice(slice: anytype, first: u32, count: u32) !@TypeOf(slice) {
    const first_usize: usize = first;
    const count_usize: usize = count;
    const end = std.math.add(usize, first_usize, count_usize) catch
        return error.InvalidDistrictSceneRange;
    if (end > slice.len) return error.InvalidDistrictSceneRange;
    return slice[first_usize..end];
}

/// Column-major glTF composition: `world = parent_world * local`.
fn multiplyColumnMajor(left: [16]f32, right: [16]f32) [16]f32 {
    var result: [16]f32 = undefined;
    for (0..4) |column| {
        for (0..4) |row| {
            var value: f32 = 0;
            for (0..4) |inner| {
                value += left[inner * 4 + row] * right[column * 4 + inner];
            }
            result[column * 4 + row] = value;
        }
    }
    return result;
}

const fixture_strings = "adapter-rootchild-achild-bmeshmat-texturedmat-plaintexture";

fn nameRef(comptime value: []const u8) bundle.NameRef {
    const offset = std.mem.indexOf(u8, fixture_strings, value).?;
    return .{ .offset = @intCast(offset), .len = @intCast(value.len) };
}

const identity = [16]f32{
    1, 0, 0, 0,
    0, 1, 0, 0,
    0, 0, 1, 0,
    0, 0, 0, 1,
};

const fixture_nodes = [_]bundle.Node{
    .{
        .name = nameRef("adapter-root"),
        .local_transform = .{
            2, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            0, 0, 0, 1,
        },
    },
    .{
        .name = nameRef("child-a"),
        .parent = 0,
        .mesh = 0,
        .local_transform = .{
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            1, 0, 0, 1,
        },
    },
    .{
        .name = nameRef("child-b"),
        .parent = 0,
        .mesh = 0,
        .local_transform = .{
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            3, 0, 0, 1,
        },
    },
};

const fixture_meshes = [_]bundle.Mesh{.{
    .name = nameRef("mesh"),
    .first_primitive = 0,
    .primitive_count = 2,
}};
const fixture_primitives = [_]bundle.Primitive{
    .{ .first_vertex = 2, .vertex_count = 3, .first_index = 0, .index_count = 3, .material = 0 },
    .{ .first_vertex = 5, .vertex_count = 3, .first_index = 3, .index_count = 3, .material = 1 },
};
const fixture_materials = [_]bundle.Material{
    .{ .name = nameRef("mat-textured"), .base_color = .{ 1, 0.5, 0.25, 1 }, .base_color_texture = 0 },
    .{ .name = nameRef("mat-plain"), .base_color = .{ 0.5, 0.5, 0.5, 1 } },
};
const fixture_textures = [_]bundle.Texture{.{
    .name = nameRef("texture"),
    .width = 1,
    .height = 1,
    .format = .rgba8_srgb,
    .pixel_offset = 0,
    .pixel_size = 4,
}};
const fixture_vertices = [_]bundle.VertexPNU{
    .{ .position = .{ -9, -9, -9 }, .normal = .{ 0, 1, 0 }, .texcoord = .{ 0, 0 } },
    .{ .position = .{ -8, -8, -8 }, .normal = .{ 0, 1, 0 }, .texcoord = .{ 0, 0 } },
    .{ .position = .{ 0, 0, 0 }, .normal = .{ 0, 1, 0 }, .texcoord = .{ 0, 0 } },
    .{ .position = .{ 1, 0, 0 }, .normal = .{ 0, 1, 0 }, .texcoord = .{ 1, 0 } },
    .{ .position = .{ 0, 0, 1 }, .normal = .{ 0, 1, 0 }, .texcoord = .{ 0, 1 } },
    .{ .position = .{ 0, 1, 0 }, .normal = .{ 0, 1, 0 }, .texcoord = .{ 0, 0 } },
    .{ .position = .{ 1, 1, 0 }, .normal = .{ 0, 1, 0 }, .texcoord = .{ 1, 0 } },
    .{ .position = .{ 0, 1, 1 }, .normal = .{ 0, 1, 0 }, .texcoord = .{ 0, 1 } },
};
const fixture_indices = [_]u32{ 2, 3, 4, 5, 7, 6 };
const fixture_pixels = [_]u8{ 20, 40, 60, 255 };
const fixture_boxes = [_]bundle.StaticBox{.{
    .position = .{ 0, -0.5, 0 },
    .half_extents = .{ 8, 0.5, 8 },
}};

fn fixtureBundle() bundle.BundleView {
    return .{
        .bundle_name = nameRef("adapter-root"),
        .source_digest = [_]u8{0x33} ** 32,
        .strings = fixture_strings,
        .nodes = &fixture_nodes,
        .meshes = &fixture_meshes,
        .primitives = &fixture_primitives,
        .materials = &fixture_materials,
        .textures = &fixture_textures,
        .vertices = &fixture_vertices,
        .indices = &fixture_indices,
        .pixels = &fixture_pixels,
        .static_boxes = &fixture_boxes,
        .navigation_nodes = &.{},
        .navigation_edges = &.{},
    };
}

test "adapter preserves primitives shared node instances hierarchy and texture edges" {
    var plan = try build(std.testing.allocator, fixtureBundle());
    defer plan.deinit();
    const upload = plan.sceneUpload();

    try std.testing.expectEqual(@as(usize, 2), upload.meshes.len);
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2 }, upload.meshes[0].indices);
    try std.testing.expectEqualSlices(u32, &.{ 0, 2, 1 }, upload.meshes[1].indices);
    try std.testing.expectEqual(@as(u16, 0), upload.meshes[0].material_index);
    try std.testing.expectEqual(@as(u16, 1), upload.meshes[1].material_index);
    try std.testing.expectEqual(@as(usize, 3), upload.meshes[0].vertices.len);
    try std.testing.expectEqual(@as(f32, 0), upload.meshes[0].vertices[0].position[0]);

    try std.testing.expectEqual(@as(usize, 1), upload.textures.len);
    try std.testing.expectEqualSlices(u8, &fixture_pixels, upload.textures[0].rgba8);
    try std.testing.expectEqual(gpu.TextureFormat.rgba8_srgb, upload.textures[0].format);
    try std.testing.expectEqual(@as(?u16, 0), upload.materials[0].base_color_texture);
    try std.testing.expectEqual([4]f32{ 1, 0.5, 0.25, 1 }, upload.materials[0].base_color);
    try std.testing.expectEqual(@as(?u16, null), upload.materials[1].base_color_texture);

    // Both authored nodes reuse the same two primitive uploads. Their parent
    // scale composes with distinct local translations: x=1 -> 2, x=3 -> 6.
    try std.testing.expectEqual(@as(usize, 4), upload.instances.len);
    try std.testing.expectEqual(@as(u16, 0), upload.instances[0].mesh_index);
    try std.testing.expectEqual(@as(u16, 1), upload.instances[1].mesh_index);
    try std.testing.expectEqual(@as(u16, 0), upload.instances[2].mesh_index);
    try std.testing.expectEqual(@as(u16, 1), upload.instances[3].mesh_index);
    try std.testing.expectEqual(@as(f32, 2), upload.instances[0].transform[12]);
    try std.testing.expectEqual(@as(f32, 2), upload.instances[1].transform[12]);
    try std.testing.expectEqual(@as(f32, 6), upload.instances[2].transform[12]);
    try std.testing.expectEqual(@as(f32, 6), upload.instances[3].transform[12]);
}

test "adapter rejects primitive indices outside their local vertex range" {
    var invalid_indices = fixture_indices;
    invalid_indices[1] = 7;
    var invalid = fixtureBundle();
    invalid.indices = &invalid_indices;
    try std.testing.expectError(error.InvalidDistrictSceneIndex, build(std.testing.allocator, invalid));
}
