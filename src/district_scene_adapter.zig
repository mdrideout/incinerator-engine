//! Convert one validated cooked district bundle into a bounded GPU upload plan.
//!
//! The adapter is renderer-neutral policy. It performs no SDL calls and owns
//! no GPU resources. `UploadPlan.sceneUpload()` borrows the plan and source
//! bundle only for the synchronous registry `stage` call; the registry copies
//! all staging data it accepts.

const std = @import("std");
const content = @import("content");
const gpu = @import("district_gpu_registry.zig");

const bundle = content.bundle;
const UploadVertex = @typeInfo(@TypeOf(@as(gpu.MeshUpload, undefined).vertices)).pointer.child;

const default_bundle_limits = bundle.Limits{};
pub const max_vertices: usize = default_bundle_limits.max_vertices;
pub const max_source_indices: usize = default_bundle_limits.max_indices;
pub const max_source_primitives: usize = default_bundle_limits.max_primitives;
pub const max_source_meshes: usize = default_bundle_limits.max_meshes;
pub const max_source_materials: usize = default_bundle_limits.max_materials;
pub const max_source_textures: usize = default_bundle_limits.max_textures;
/// Primitive index ranges may overlap in a valid renderer-neutral bundle, so
/// rebasing needs one bounded copy per primitive rather than one per source
/// index element.
pub const max_rebased_indices: usize = max_source_primitives * max_source_indices;
pub const max_nodes: usize = default_bundle_limits.max_nodes;

const MeshDescriptor = struct {
    first_vertex: u16,
    vertex_count: u16,
    first_rebased_index: u16,
    index_count: u16,
    material_index: u16,
};

/// Fixed-capacity bridge between cooked CPU data and `DistrictGpuRegistry`.
/// It contains no owning allocation and is safe to move until `sceneUpload`
/// creates slices into its final address.
pub const UploadPlan = struct {
    vertex_storage: [max_vertices]UploadVertex = undefined,
    vertex_count: u16 = 0,
    rebased_index_storage: [max_rebased_indices]u32 = undefined,
    rebased_index_count: u16 = 0,
    mesh_descriptors: [gpu.max_meshes_per_scene]MeshDescriptor = undefined,
    mesh_count: u8 = 0,
    mesh_upload_storage: [gpu.max_meshes_per_scene]gpu.MeshUpload = undefined,
    texture_storage: [gpu.max_textures_per_scene]gpu.TextureUpload = undefined,
    texture_count: u8 = 0,
    material_storage: [gpu.max_materials_per_scene]gpu.MaterialUpload = undefined,
    material_count: u8 = 0,
    instance_storage: [gpu.max_instances_per_scene]gpu.InstanceUpload = undefined,
    instance_count: u8 = 0,

    /// Produce the borrowed view consumed by `DistrictGpuRegistry.stage`.
    /// Calling this after the plan has reached its final address avoids
    /// retaining self-referential slices across a value move.
    pub fn sceneUpload(self: *UploadPlan) gpu.SceneUpload {
        for (self.mesh_descriptors[0..self.mesh_count], 0..) |descriptor, index| {
            self.mesh_upload_storage[index] = .{
                .vertices = self.vertex_storage[descriptor.first_vertex..][0..descriptor.vertex_count],
                .indices = self.rebased_index_storage[descriptor.first_rebased_index..][0..descriptor.index_count],
                .material_index = descriptor.material_index,
            };
        }
        return .{
            .meshes = self.mesh_upload_storage[0..self.mesh_count],
            .textures = self.texture_storage[0..self.texture_count],
            .materials = self.material_storage[0..self.material_count],
            .instances = self.instance_storage[0..self.instance_count],
        };
    }
};

/// Preserve the complete cooked render scene while translating its global
/// primitive indices into the primitive-local indices required by a GPU mesh.
pub fn build(source: bundle.BundleView) !UploadPlan {
    if (source.primitives.len == 0 or source.materials.len == 0 or source.nodes.len == 0) {
        return error.EmptyDistrictScene;
    }
    if (source.vertices.len > max_vertices or
        source.indices.len > max_source_indices or
        source.nodes.len > max_nodes or
        source.meshes.len > max_source_meshes or
        source.primitives.len > @min(max_source_primitives, gpu.max_meshes_per_scene) or
        source.materials.len > @min(max_source_materials, gpu.max_materials_per_scene) or
        source.textures.len > @min(max_source_textures, gpu.max_textures_per_scene))
    {
        return error.DistrictSceneAdapterCapacityExceeded;
    }

    var result = UploadPlan{};
    result.vertex_count = @intCast(source.vertices.len);
    for (source.vertices, 0..) |vertex, index| {
        for (vertex.position ++ vertex.normal ++ vertex.texcoord) |value| {
            if (!std.math.isFinite(value)) return error.InvalidDistrictSceneVertex;
        }
        result.vertex_storage[index] = .{
            .position = vertex.position,
            .normal = vertex.normal,
            .texcoord = vertex.texcoord,
        };
    }

    var rebased_cursor: usize = 0;
    for (source.primitives, 0..) |primitive, primitive_index| {
        const vertices = try rangeFromSlice(
            source.vertices,
            primitive.first_vertex,
            primitive.vertex_count,
        );
        const indices = try rangeFromSlice(
            source.indices,
            primitive.first_index,
            primitive.index_count,
        );
        if (vertices.len == 0 or indices.len == 0 or indices.len % 3 != 0) {
            return error.InvalidDistrictScenePrimitive;
        }
        if (primitive.material >= source.materials.len or
            primitive.material > std.math.maxInt(u16))
        {
            return error.InvalidDistrictSceneMaterial;
        }
        const rebased_end = std.math.add(usize, rebased_cursor, indices.len) catch
            return error.DistrictSceneAdapterCapacityExceeded;
        if (rebased_end > max_rebased_indices or
            primitive.first_vertex > std.math.maxInt(u16) or
            primitive.vertex_count > std.math.maxInt(u16) or
            rebased_cursor > std.math.maxInt(u16) or
            primitive.index_count > std.math.maxInt(u16))
        {
            return error.DistrictSceneAdapterCapacityExceeded;
        }
        const vertex_end = std.math.add(u32, primitive.first_vertex, primitive.vertex_count) catch
            return error.InvalidDistrictScenePrimitive;
        for (indices, rebased_cursor..) |global_index, target_index| {
            if (global_index < primitive.first_vertex or global_index >= vertex_end) {
                return error.InvalidDistrictSceneIndex;
            }
            result.rebased_index_storage[target_index] = global_index - primitive.first_vertex;
        }
        result.mesh_descriptors[primitive_index] = .{
            .first_vertex = @intCast(primitive.first_vertex),
            .vertex_count = @intCast(primitive.vertex_count),
            .first_rebased_index = @intCast(rebased_cursor),
            .index_count = @intCast(primitive.index_count),
            .material_index = @intCast(primitive.material),
        };
        rebased_cursor = rebased_end;
    }
    result.mesh_count = @intCast(source.primitives.len);
    result.rebased_index_count = @intCast(rebased_cursor);

    for (source.textures, 0..) |texture, index| {
        if ((texture.format != .rgba8_unorm and texture.format != .rgba8_srgb) or
            texture.width == 0 or texture.height == 0)
        {
            return error.InvalidDistrictSceneTexture;
        }
        const pixel_count = std.math.mul(u32, texture.width, texture.height) catch
            return error.InvalidDistrictSceneTexture;
        const expected_bytes = std.math.mul(u32, pixel_count, 4) catch
            return error.InvalidDistrictSceneTexture;
        if (texture.pixel_size != expected_bytes) return error.InvalidDistrictSceneTexture;
        const pixels = try rangeFromSlice(
            source.pixels,
            texture.pixel_offset,
            texture.pixel_size,
        );
        result.texture_storage[index] = .{
            .width = texture.width,
            .height = texture.height,
            .format = switch (texture.format) {
                .rgba8_unorm => .rgba8_unorm,
                .rgba8_srgb => .rgba8_srgb,
                else => unreachable,
            },
            .rgba8 = pixels,
        };
    }
    result.texture_count = @intCast(source.textures.len);

    for (source.materials, 0..) |material, index| {
        if (material.flags != 0) return error.InvalidDistrictSceneMaterial;
        for (material.base_color) |value| {
            if (!std.math.isFinite(value)) return error.InvalidDistrictSceneMaterial;
        }
        const texture_index: ?u16 = if (material.base_color_texture == bundle.none_index)
            null
        else blk: {
            if (material.base_color_texture >= source.textures.len or
                material.base_color_texture > std.math.maxInt(u16))
            {
                return error.InvalidDistrictSceneTexture;
            }
            break :blk @intCast(material.base_color_texture);
        };
        result.material_storage[index] = .{
            .base_color = material.base_color,
            .base_color_texture = texture_index,
        };
    }
    result.material_count = @intCast(source.materials.len);

    var world_transforms: [max_nodes][16]f32 = undefined;
    var instance_count: usize = 0;
    for (source.nodes, 0..) |node, node_index| {
        for (node.local_transform) |value| {
            if (!std.math.isFinite(value)) return error.InvalidDistrictSceneTransform;
        }
        const world = if (node.parent == bundle.none_index)
            node.local_transform
        else blk: {
            if (node.parent >= node_index) return error.InvalidDistrictSceneHierarchy;
            break :blk multiplyColumnMajor(
                world_transforms[node.parent],
                node.local_transform,
            );
        };
        for (world) |value| {
            if (!std.math.isFinite(value)) return error.InvalidDistrictSceneTransform;
        }
        world_transforms[node_index] = world;

        if (node.mesh == bundle.none_index) continue;
        if (node.mesh >= source.meshes.len) return error.InvalidDistrictSceneMesh;
        const mesh = source.meshes[node.mesh];
        const primitive_indices = try rangeFromSlice(
            source.primitives,
            mesh.first_primitive,
            mesh.primitive_count,
        );
        if (primitive_indices.len == 0) return error.InvalidDistrictSceneMesh;
        for (0..primitive_indices.len) |offset| {
            if (instance_count == gpu.max_instances_per_scene) {
                return error.DistrictSceneInstanceCapacityExceeded;
            }
            const upload_mesh_index = std.math.add(u32, mesh.first_primitive, @intCast(offset)) catch
                return error.InvalidDistrictSceneMesh;
            if (upload_mesh_index >= @as(u32, result.mesh_count) or
                upload_mesh_index > std.math.maxInt(u16))
            {
                return error.InvalidDistrictSceneMesh;
            }
            result.instance_storage[instance_count] = .{
                .mesh_index = @intCast(upload_mesh_index),
                .transform = world,
            };
            instance_count += 1;
        }
    }
    if (instance_count == 0) return error.EmptyDistrictScene;
    result.instance_count = @intCast(instance_count);
    return result;
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
    var plan = try build(fixtureBundle());
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
    try std.testing.expectError(error.InvalidDistrictSceneIndex, build(invalid));
}
