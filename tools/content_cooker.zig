//! Offline glTF-to-Incinerator district bundle cooker.

const std = @import("std");
const zmesh = @import("zmesh");
const zstbi = @import("zstbi");
const content = @import("content");
const bundle = content.bundle;
const cgltf = zmesh.io.zcgltf;

const max_source_bytes = 256 * 1024;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 5) return error.ExpectedInputProvenanceOutputAndBundleKey;
    const input_path: []const u8 = args[1];
    const provenance_path: []const u8 = args[2];
    const output_path: []const u8 = args[3];
    const key = try content.BundleKey.parse(args[4]);

    const source = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        input_path,
        allocator,
        .limited(max_source_bytes),
    );
    defer allocator.free(source);
    const provenance = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        provenance_path,
        allocator,
        .limited(16 * 1024),
    );
    defer allocator.free(provenance);
    if (provenance.len == 0 or
        std.mem.indexOf(u8, provenance, "External source material: none") == null)
    {
        return error.InvalidFixtureProvenance;
    }

    var source_digest: [32]u8 = undefined;
    var digest = std.crypto.hash.sha2.Sha256.init(.{});
    digest.update(source);
    digest.update(&.{0});
    digest.update(provenance);
    digest.final(&source_digest);

    const source_z = try allocator.dupeZ(u8, input_path);
    defer allocator.free(source_z);
    zmesh.init(allocator);
    defer zmesh.deinit();
    zstbi.init(init.io, allocator);
    defer zstbi.deinit();

    const cgltf_options = cgltf.Options{
        .memory = .{
            .alloc_func = zmesh.mem.zmeshAllocUser,
            .free_func = zmesh.mem.zmeshFreeUser,
        },
    };
    const data = try cgltf.parse(cgltf_options, source);
    defer cgltf.free(data);
    try requireEmbeddedBoundedBuffers(data);
    try cgltf.loadBuffers(cgltf_options, data, source_z);
    var cooked = try cook(allocator, data, key.bytes(), source_digest);
    defer cooked.deinit();
    const encoded = switch (try bundle.encode(allocator, cooked.view(), .{})) {
        .bytes => |bytes| bytes,
        .failed => return error.CookedBundleValidationFailed,
    };
    defer allocator.free(encoded);
    try writeAtomic(init.io, output_path, encoded);
}

fn requireEmbeddedBoundedBuffers(data: *cgltf.Data) !void {
    if (data.buffers_count == 0) return error.SourceBufferRequired;
    const buffers = data.buffers orelse return error.SourceBufferRequired;
    var total_bytes: usize = 0;
    for (buffers[0..data.buffers_count]) |buffer| {
        const uri = cString(buffer.uri orelse return error.EmbeddedBufferRequired);
        if (!std.mem.startsWith(u8, uri, "data:")) return error.ExternalBufferUnsupported;
        total_bytes = std.math.add(usize, total_bytes, buffer.size) catch
            return error.SourceCapacityExceeded;
        if (total_bytes > max_source_bytes) return error.SourceCapacityExceeded;
    }
}

const Cooked = struct {
    allocator: std.mem.Allocator,
    bundle_name: bundle.NameRef,
    source_digest: [32]u8,
    strings: std.ArrayListUnmanaged(u8),
    nodes: std.ArrayListUnmanaged(bundle.Node),
    meshes: std.ArrayListUnmanaged(bundle.Mesh),
    primitives: std.ArrayListUnmanaged(bundle.Primitive),
    materials: std.ArrayListUnmanaged(bundle.Material),
    textures: std.ArrayListUnmanaged(bundle.Texture),
    vertices: std.ArrayListUnmanaged(bundle.VertexPNU),
    indices: std.ArrayListUnmanaged(u32),
    pixels: std.ArrayListUnmanaged(u8),
    static_boxes: std.ArrayListUnmanaged(bundle.StaticBox),

    fn init(allocator: std.mem.Allocator, source_digest: [32]u8) Cooked {
        return .{
            .allocator = allocator,
            .bundle_name = undefined,
            .source_digest = source_digest,
            .strings = .empty,
            .nodes = .empty,
            .meshes = .empty,
            .primitives = .empty,
            .materials = .empty,
            .textures = .empty,
            .vertices = .empty,
            .indices = .empty,
            .pixels = .empty,
            .static_boxes = .empty,
        };
    }

    fn view(self: *const Cooked) bundle.BundleView {
        return .{
            .bundle_name = self.bundle_name,
            .source_digest = self.source_digest,
            .strings = self.strings.items,
            .nodes = self.nodes.items,
            .meshes = self.meshes.items,
            .primitives = self.primitives.items,
            .materials = self.materials.items,
            .textures = self.textures.items,
            .vertices = self.vertices.items,
            .indices = self.indices.items,
            .pixels = self.pixels.items,
            .static_boxes = self.static_boxes.items,
        };
    }

    fn addName(self: *Cooked, name: []const u8) !bundle.NameRef {
        if (name.len == 0 or !std.unicode.utf8ValidateSlice(name)) return error.InvalidSemanticName;
        const offset = std.math.cast(u32, self.strings.items.len) orelse return error.StringTableTooLarge;
        const len = std.math.cast(u32, name.len) orelse return error.StringTableTooLarge;
        try self.strings.appendSlice(self.allocator, name);
        return .{ .offset = offset, .len = len };
    }

    fn deinit(self: *Cooked) void {
        self.static_boxes.deinit(self.allocator);
        self.pixels.deinit(self.allocator);
        self.indices.deinit(self.allocator);
        self.vertices.deinit(self.allocator);
        self.textures.deinit(self.allocator);
        self.materials.deinit(self.allocator);
        self.primitives.deinit(self.allocator);
        self.meshes.deinit(self.allocator);
        self.nodes.deinit(self.allocator);
        self.strings.deinit(self.allocator);
        self.* = undefined;
    }
};

fn cook(
    allocator: std.mem.Allocator,
    data: *cgltf.Data,
    bundle_name: []const u8,
    source_digest: [32]u8,
) !Cooked {
    if (data.scene == null or data.scenes_count != 1) return error.ExactlyOneDefaultSceneRequired;
    if (data.extensions_used_count != 0 or data.extensions_required_count != 0 or
        data.data_extensions_count != 0 or data.animations_count != 0 or data.skins_count != 0 or
        data.cameras_count != 0 or data.lights_count != 0 or data.variants_count != 0)
    {
        return error.UnsupportedGltfFeature;
    }
    const limits = bundle.Limits{};
    if (data.nodes_count > limits.max_nodes or
        data.meshes_count > limits.max_meshes or
        data.materials_count > limits.max_materials or
        data.textures_count > limits.max_textures)
    {
        return error.SourceCapacityExceeded;
    }

    var result = Cooked.init(allocator, source_digest);
    errdefer result.deinit();
    result.bundle_name = try result.addName(bundle_name);

    const nodes = data.nodes orelse return error.SceneContainsNoNodes;
    const node_map = try allocator.alloc(u32, data.nodes_count);
    defer allocator.free(node_map);
    @memset(node_map, bundle.none_index);
    const scene = data.scene.?;
    const roots = scene.nodes orelse return error.SceneContainsNoNodes;
    for (roots[0..scene.nodes_count]) |root| {
        try appendNode(&result, data, nodes, node_map, root, bundle.none_index);
    }
    for (node_map) |mapped| if (mapped == bundle.none_index) return error.NodesOutsideDefaultScene;

    const meshes = data.meshes orelse return error.SceneContainsNoMeshes;
    for (meshes[0..data.meshes_count]) |*mesh| try appendMesh(&result, data, mesh);
    const materials = data.materials orelse return error.SceneContainsNoMaterials;
    for (materials[0..data.materials_count]) |*material| try appendMaterial(&result, data, material);
    const textures = data.textures orelse return error.SceneContainsNoTextures;
    for (textures[0..data.textures_count]) |*texture| try appendTexture(&result, texture);

    // Same narrow logical district shape proven by S3-A at coordinate (0,0).
    try result.static_boxes.appendSlice(allocator, &.{
        .{ .position = .{ 0, -0.5, 0 }, .half_extents = .{ 7.5, 0.5, 7.5 } },
        .{ .position = .{ -5.5, 1, -2 }, .half_extents = .{ 1, 1, 3 } },
        .{ .position = .{ 3, 0.75, 4.5 }, .half_extents = .{ 2.5, 0.75, 0.75 } },
    });
    return result;
}

fn appendNode(
    cooked: *Cooked,
    data: *cgltf.Data,
    source_nodes: [*]cgltf.Node,
    node_map: []u32,
    node: *cgltf.Node,
    parent: u32,
) !void {
    const source_index = try pointerIndex(cgltf.Node, source_nodes, data.nodes_count, node);
    if (node_map[source_index] != bundle.none_index) return error.CyclicOrSharedNodeHierarchy;
    if (node.skin != null or node.camera != null or node.light != null or
        node.weights_count != 0 or node.has_mesh_gpu_instancing != 0 or node.extensions_count != 0)
    {
        return error.UnsupportedNodeFeature;
    }
    const cooked_index = std.math.cast(u32, cooked.nodes.items.len) orelse return error.SourceCapacityExceeded;
    node_map[source_index] = cooked_index;
    const mesh_index = if (node.mesh) |mesh|
        try pointerIndex(cgltf.Mesh, data.meshes.?, data.meshes_count, mesh)
    else
        bundle.none_index;
    try cooked.nodes.append(cooked.allocator, .{
        .name = try cooked.addName(cString(node.name orelse return error.NodeNameRequired)),
        .parent = parent,
        .mesh = mesh_index,
        .local_transform = node.transformLocal(),
    });
    if (node.children_count == 0) return;
    const children = node.children orelse return error.InvalidNodeChildren;
    for (children[0..node.children_count]) |child| {
        try appendNode(cooked, data, source_nodes, node_map, child, cooked_index);
    }
}

fn appendMesh(cooked: *Cooked, data: *cgltf.Data, mesh: *cgltf.Mesh) !void {
    if (mesh.primitives_count == 0 or mesh.extensions_count != 0 or mesh.weights_count != 0 or
        mesh.target_names_count != 0) return error.UnsupportedMeshFeature;
    const mesh_index = try pointerIndex(cgltf.Mesh, data.meshes.?, data.meshes_count, mesh);
    const first_primitive = std.math.cast(u32, cooked.primitives.items.len) orelse return error.SourceCapacityExceeded;
    for (mesh.primitives[0..mesh.primitives_count], 0..) |*primitive, primitive_index| {
        try appendPrimitive(cooked, data, mesh_index, @intCast(primitive_index), primitive);
    }
    try cooked.meshes.append(cooked.allocator, .{
        .name = try cooked.addName(cString(mesh.name orelse return error.MeshNameRequired)),
        .first_primitive = first_primitive,
        .primitive_count = @intCast(mesh.primitives_count),
    });
}

fn appendPrimitive(
    cooked: *Cooked,
    data: *cgltf.Data,
    mesh_index: u32,
    primitive_index: u32,
    primitive: *cgltf.Primitive,
) !void {
    if (primitive.type != .triangles or primitive.indices == null or primitive.material == null or
        primitive.targets_count != 0 or primitive.has_draco_mesh_compression != 0 or
        primitive.mappings_count != 0 or primitive.extensions_count != 0)
    {
        return error.UnsupportedPrimitiveFeature;
    }
    const index_accessor = primitive.indices.?;
    if (index_accessor.type != .scalar or index_accessor.normalized != 0 or
        index_accessor.is_sparse != 0 or index_accessor.buffer_view == null or
        (index_accessor.component_type != .r_8u and index_accessor.component_type != .r_16u and
            index_accessor.component_type != .r_32u)) return error.InvalidIndexAccessor;
    try validateAccessorLayout(index_accessor);
    var position_count: u8 = 0;
    var normal_count: u8 = 0;
    var texcoord_zero_count: u8 = 0;
    for (primitive.attributes[0..primitive.attributes_count]) |attribute| {
        if (attribute.data.component_type != .r_32f or attribute.data.normalized != 0 or
            attribute.data.is_sparse != 0 or attribute.data.buffer_view == null)
        {
            return error.InvalidVertexAccessor;
        }
        try validateAccessorLayout(attribute.data);
        switch (attribute.type) {
            .position => {
                if (attribute.data.type != .vec3) return error.InvalidVertexAccessor;
                position_count += 1;
            },
            .normal => {
                if (attribute.data.type != .vec3) return error.InvalidVertexAccessor;
                normal_count += 1;
            },
            .texcoord => if (attribute.index == 0) {
                if (attribute.data.type != .vec2) return error.InvalidVertexAccessor;
                texcoord_zero_count += 1;
            } else return error.UnsupportedPrimitiveAttribute,
            else => return error.UnsupportedPrimitiveAttribute,
        }
    }
    if (position_count != 1 or normal_count != 1 or texcoord_zero_count != 1 or
        primitive.attributes_count != 3) return error.RequiredPrimitiveAttributesMissing;

    var source_indices: std.ArrayListUnmanaged(u32) = .empty;
    defer source_indices.deinit(cooked.allocator);
    var positions: std.ArrayListUnmanaged([3]f32) = .empty;
    defer positions.deinit(cooked.allocator);
    var normals: std.ArrayListUnmanaged([3]f32) = .empty;
    defer normals.deinit(cooked.allocator);
    var texcoords: std.ArrayListUnmanaged([2]f32) = .empty;
    defer texcoords.deinit(cooked.allocator);
    try cgltf.appendMeshPrimitive(
        cooked.allocator,
        data,
        mesh_index,
        primitive_index,
        &source_indices,
        &positions,
        &normals,
        &texcoords,
        null,
    );
    if (positions.items.len != normals.items.len or positions.items.len != texcoords.items.len or
        source_indices.items.len == 0 or source_indices.items.len % 3 != 0)
    {
        return error.InvalidPrimitiveData;
    }
    const first_vertex = std.math.cast(u32, cooked.vertices.items.len) orelse return error.SourceCapacityExceeded;
    const first_index = std.math.cast(u32, cooked.indices.items.len) orelse return error.SourceCapacityExceeded;
    for (positions.items, normals.items, texcoords.items) |position, normal, texcoord| {
        try cooked.vertices.append(cooked.allocator, .{
            .position = position,
            .normal = normal,
            .texcoord = texcoord,
        });
    }
    for (source_indices.items) |index| {
        if (index >= positions.items.len) return error.InvalidPrimitiveData;
        try cooked.indices.append(cooked.allocator, first_vertex + index);
    }
    try cooked.primitives.append(cooked.allocator, .{
        .first_vertex = first_vertex,
        .vertex_count = @intCast(positions.items.len),
        .first_index = first_index,
        .index_count = @intCast(source_indices.items.len),
        .material = try pointerIndex(cgltf.Material, data.materials.?, data.materials_count, primitive.material.?),
    });
}

fn appendMaterial(cooked: *Cooked, data: *cgltf.Data, material: *cgltf.Material) !void {
    if (material.has_pbr_metallic_roughness == 0 or material.extensions_count != 0 or
        material.has_pbr_specular_glossiness != 0 or material.has_clearcoat != 0 or
        material.has_transmission != 0 or material.has_volume != 0 or material.has_ior != 0 or
        material.has_specular != 0 or material.has_sheen != 0 or
        material.has_emissive_strength != 0 or material.has_iridescence != 0 or
        material.has_diffuse_transmission != 0 or material.has_anisotropy != 0 or
        material.has_dispersion != 0 or
        material.alpha_mode != .@"opaque" or material.double_sided != 0 or material.unlit != 0 or
        material.normal_texture.texture != null or material.occlusion_texture.texture != null or
        material.emissive_texture.texture != null)
    {
        return error.UnsupportedMaterialFeature;
    }
    const pbr = material.pbr_metallic_roughness;
    if (pbr.base_color_texture.texture == null or pbr.metallic_roughness_texture.texture != null) {
        return error.BaseColorTextureRequired;
    }
    if (pbr.base_color_texture.texcoord != 0 or pbr.base_color_texture.has_transform != 0 or
        pbr.metallic_factor != 0 or pbr.roughness_factor != 1)
    {
        return error.UnsupportedMaterialFeature;
    }
    try cooked.materials.append(cooked.allocator, .{
        .name = try cooked.addName(cString(material.name orelse return error.MaterialNameRequired)),
        .base_color = pbr.base_color_factor,
        .base_color_texture = try pointerIndex(
            cgltf.Texture,
            data.textures.?,
            data.textures_count,
            pbr.base_color_texture.texture.?,
        ),
    });
}

fn appendTexture(cooked: *Cooked, texture: *cgltf.Texture) !void {
    if (texture.extensions_count != 0 or texture.has_basisu != 0 or texture.has_webp != 0) {
        return error.UnsupportedTextureFeature;
    }
    const image = texture.image orelse return error.TextureImageRequired;
    if (image.uri != null or image.extensions_count != 0) return error.EmbeddedTextureRequired;
    if (image.mime_type == null or !std.mem.eql(u8, cString(image.mime_type.?), "image/png")) {
        return error.PngTextureRequired;
    }
    const sampler = texture.sampler orelse return error.TextureSamplerRequired;
    if (sampler.mag_filter != .linear or sampler.min_filter != .linear or
        sampler.wrap_s != .repeat or sampler.wrap_t != .repeat or sampler.extensions_count != 0)
    {
        return error.UnsupportedTextureSampler;
    }
    const view = image.buffer_view orelse return error.EmbeddedTextureRequired;
    const encoded_ptr = view.getData() orelse return error.ImageBufferUnavailable;
    const encoded = encoded_ptr[0..view.size];
    if (encoded.len < 24 or !std.mem.eql(u8, encoded[0..8], "\x89PNG\r\n\x1a\n")) {
        return error.InvalidPngHeader;
    }
    const declared_width = std.mem.readInt(u32, encoded[16..20], .big);
    const declared_height = std.mem.readInt(u32, encoded[20..24], .big);
    const declared_pixels = std.math.mul(u32, declared_width, declared_height) catch return error.ImageTooLarge;
    const declared_bytes = std.math.mul(u32, declared_pixels, 4) catch return error.ImageTooLarge;
    const limits = bundle.Limits{};
    if (declared_width == 0 or declared_height == 0 or declared_bytes > limits.max_pixel_bytes) {
        return error.ImageTooLarge;
    }
    var decoded = try zstbi.Image.loadFromMemory(encoded, 4);
    defer decoded.deinit();
    if (decoded.is_hdr or decoded.bytes_per_component != 1 or decoded.num_components != 4) {
        return error.UnsupportedDecodedImage;
    }
    const pixel_size = std.math.mul(u32, decoded.width, decoded.height) catch return error.ImageTooLarge;
    const rgba_size = std.math.mul(u32, pixel_size, 4) catch return error.ImageTooLarge;
    if (decoded.data.len != rgba_size) return error.InvalidDecodedImage;
    const pixel_offset = std.math.cast(u32, cooked.pixels.items.len) orelse return error.ImageTooLarge;
    try cooked.pixels.appendSlice(cooked.allocator, decoded.data);
    try cooked.textures.append(cooked.allocator, .{
        .name = try cooked.addName(cString(texture.name orelse return error.TextureNameRequired)),
        .width = decoded.width,
        .height = decoded.height,
        .format = .rgba8_srgb,
        .pixel_offset = pixel_offset,
        .pixel_size = rgba_size,
    });
}

fn pointerIndex(
    comptime T: type,
    values: [*]T,
    count: usize,
    target: *T,
) !u32 {
    for (values[0..count], 0..) |*value, index| {
        if (value == target) return std.math.cast(u32, index) orelse error.SourceCapacityExceeded;
    }
    return error.InvalidSourceReference;
}

fn validateAccessorLayout(accessor: *cgltf.Accessor) !void {
    const view = accessor.buffer_view orelse return error.InvalidAccessorLayout;
    if (view.buffer.data == null or accessor.offset != 0) return error.InvalidAccessorLayout;
    if (view.stride != 0 and accessor.stride != view.stride) return error.InvalidAccessorLayout;
    const occupied = std.math.mul(usize, accessor.stride, accessor.count) catch return error.InvalidAccessorLayout;
    if (occupied != view.size) return error.InvalidAccessorLayout;
}

fn cString(value: anytype) []const u8 {
    return std.mem.span(@as([*:0]const u8, @ptrCast(value)));
}

fn writeAtomic(io: std.Io, output_path: []const u8, bytes: []const u8) !void {
    const directory_path = std.fs.path.dirname(output_path) orelse return error.OutputDirectoryRequired;
    const basename = std.fs.path.basename(output_path);
    var directory = if (std.fs.path.isAbsolute(directory_path))
        try std.Io.Dir.openDirAbsolute(io, directory_path, .{})
    else
        try std.Io.Dir.cwd().openDir(io, directory_path, .{});
    defer directory.close(io);
    var atomic = try directory.createFileAtomic(io, basename, .{ .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, bytes);
    try atomic.replace(io);
}

test "cooker rejects external buffer dependencies before loading bytes" {
    zmesh.init(std.testing.allocator);
    defer zmesh.deinit();
    const options = cgltf.Options{
        .memory = .{
            .alloc_func = zmesh.mem.zmeshAllocUser,
            .free_func = zmesh.mem.zmeshFreeUser,
        },
    };
    const source =
        \\{"asset":{"version":"2.0"},"buffers":[{"byteLength":4,"uri":"external.bin"}]}
    ;
    const data = try cgltf.parse(options, source);
    defer cgltf.free(data);
    try std.testing.expectError(error.ExternalBufferUnsupported, requireEmbeddedBoundedBuffers(data));
}
