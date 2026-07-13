//! Versioned renderer-neutral cooked district scene format.
//!
//! The wire representation is explicit little-endian bytes. No Zig aggregate
//! layout, pointer, allocator state, or renderer/backend value is serialized.

const std = @import("std");

pub const magic = [8]u8{ 'I', 'N', 'C', 'D', 'B', 'N', 'D', 'L' };
pub const format_version: u16 = 1;
pub const schema_cohort: u16 = 1;
pub const header_size: u32 = 288;
pub const section_count: usize = 10;
pub const none_index: u32 = std.math.maxInt(u32);

pub const Limits = struct {
    max_file_bytes: usize = 64 * 1024,
    max_strings_bytes: u32 = 4 * 1024,
    max_nodes: u32 = 8,
    max_meshes: u32 = 2,
    max_primitives: u32 = 4,
    max_materials: u32 = 4,
    max_textures: u32 = 2,
    max_vertices: u32 = 128,
    max_indices: u32 = 384,
    max_pixel_bytes: u32 = 4 * 1024,
    max_static_boxes: u32 = 8,
};

pub const Section = enum(u8) {
    strings,
    nodes,
    meshes,
    primitives,
    materials,
    textures,
    vertices,
    indices,
    pixels,
    static_boxes,
};

const section_strides = [section_count]u32{
    1, 80, 16, 20, 32, 28, 32, 4, 1, 40,
};

pub const NameRef = struct {
    offset: u32,
    len: u32,

    pub fn bytes(self: NameRef, strings: []const u8) ?[]const u8 {
        const end = std.math.add(u32, self.offset, self.len) catch return null;
        if (self.len == 0 or end > strings.len) return null;
        return strings[self.offset..end];
    }
};

pub const Node = struct {
    name: NameRef,
    parent: u32 = none_index,
    mesh: u32 = none_index,
    /// Column-major glTF local transform.
    local_transform: [16]f32,
};

pub const Mesh = struct {
    name: NameRef,
    first_primitive: u32,
    primitive_count: u32,
};

pub const Primitive = struct {
    first_vertex: u32,
    vertex_count: u32,
    first_index: u32,
    index_count: u32,
    material: u32,
};

pub const Material = struct {
    name: NameRef,
    base_color: [4]f32,
    base_color_texture: u32 = none_index,
    flags: u32 = 0,
};

pub const TextureFormat = enum(u32) {
    rgba8_unorm = 1,
    rgba8_srgb = 2,
    _,
};

pub const Texture = struct {
    name: NameRef,
    width: u32,
    height: u32,
    format: TextureFormat = .rgba8_unorm,
    pixel_offset: u32,
    pixel_size: u32,
};

pub const VertexPNU = struct {
    position: [3]f32,
    normal: [3]f32,
    texcoord: [2]f32,
};

pub const StaticBox = struct {
    position: [3]f32,
    rotation: [4]f32 = .{ 0, 0, 0, 1 },
    half_extents: [3]f32,
};

/// Borrowed immutable scene data. The owner of every slice must outlive it.
pub const BundleView = struct {
    bundle_name: NameRef,
    source_digest: [32]u8,
    strings: []const u8,
    nodes: []const Node,
    meshes: []const Mesh,
    primitives: []const Primitive,
    materials: []const Material,
    textures: []const Texture,
    vertices: []const VertexPNU,
    indices: []const u32,
    pixels: []const u8,
    static_boxes: []const StaticBox,

    pub fn name(self: BundleView, reference: NameRef) ?[]const u8 {
        return reference.bytes(self.strings);
    }
};

/// Move-only by convention. Call `deinit` exactly once after a successful
/// decode; a renderer registry may take ownership of this complete value.
pub const OwnedBundle = struct {
    allocator: std.mem.Allocator,
    bundle_name: NameRef,
    source_digest: [32]u8,
    strings: []u8,
    nodes: []Node,
    meshes: []Mesh,
    primitives: []Primitive,
    materials: []Material,
    textures: []Texture,
    vertices: []VertexPNU,
    indices: []u32,
    pixels: []u8,
    static_boxes: []StaticBox,

    pub fn view(self: *const OwnedBundle) BundleView {
        return .{
            .bundle_name = self.bundle_name,
            .source_digest = self.source_digest,
            .strings = self.strings,
            .nodes = self.nodes,
            .meshes = self.meshes,
            .primitives = self.primitives,
            .materials = self.materials,
            .textures = self.textures,
            .vertices = self.vertices,
            .indices = self.indices,
            .pixels = self.pixels,
            .static_boxes = self.static_boxes,
        };
    }

    pub fn deinit(self: *OwnedBundle) void {
        self.allocator.free(self.static_boxes);
        self.allocator.free(self.pixels);
        self.allocator.free(self.indices);
        self.allocator.free(self.vertices);
        self.allocator.free(self.textures);
        self.allocator.free(self.materials);
        self.allocator.free(self.primitives);
        self.allocator.free(self.meshes);
        self.allocator.free(self.nodes);
        self.allocator.free(self.strings);
        self.* = undefined;
    }
};

pub const CapacityKind = enum {
    file_bytes,
    strings,
    nodes,
    meshes,
    primitives,
    materials,
    textures,
    vertices,
    indices,
    pixels,
    static_boxes,
};

pub const CapacityFailure = struct {
    kind: CapacityKind,
    actual: u64,
    maximum: u64,
};

pub const ValidationFailure = union(enum) {
    bad_magic,
    unsupported_format_version: u16,
    incompatible_schema: u16,
    invalid_header,
    size_mismatch,
    invalid_section: Section,
    capacity_exceeded: CapacityFailure,
    integrity_mismatch,
    invalid_name,
    duplicate_name,
    invalid_reference,
    invalid_transform,
    invalid_geometry,
    invalid_material,
    invalid_texture,
    invalid_static_box,
};

pub const EncodeResult = union(enum) {
    bytes: []u8,
    failed: ValidationFailure,
};

pub const DecodeResult = union(enum) {
    bundle: OwnedBundle,
    failed: ValidationFailure,
};

const SectionDesc = struct {
    offset: u32,
    count: u32,
    stride: u32,
    byte_size: u32,
};

pub fn encode(
    allocator: std.mem.Allocator,
    bundle: BundleView,
    limits: Limits,
) !EncodeResult {
    if (validationFailure(bundle, limits)) |failure| return .{ .failed = failure };

    const counts = sectionCounts(bundle);
    var sections: [section_count]SectionDesc = undefined;
    var cursor: u64 = header_size;
    for (&sections, counts, section_strides) |*section, count, stride| {
        cursor = std.mem.alignForward(u64, cursor, 4);
        const byte_size = std.math.mul(u64, count, stride) catch
            return .{ .failed = .{ .capacity_exceeded = .{
                .kind = .file_bytes,
                .actual = std.math.maxInt(u64),
                .maximum = limits.max_file_bytes,
            } } };
        const end = std.math.add(u64, cursor, byte_size) catch
            return .{ .failed = .{ .capacity_exceeded = .{
                .kind = .file_bytes,
                .actual = std.math.maxInt(u64),
                .maximum = limits.max_file_bytes,
            } } };
        if (end > limits.max_file_bytes or end > std.math.maxInt(u32)) {
            return .{ .failed = .{ .capacity_exceeded = .{
                .kind = .file_bytes,
                .actual = end,
                .maximum = limits.max_file_bytes,
            } } };
        }
        section.* = .{
            .offset = @intCast(cursor),
            .count = count,
            .stride = stride,
            .byte_size = @intCast(byte_size),
        };
        cursor = end;
    }

    const total_size: usize = @intCast(cursor);
    const bytes = try allocator.alloc(u8, total_size);
    errdefer allocator.free(bytes);
    @memset(bytes, 0);

    @memcpy(bytes[0..magic.len], &magic);
    putU16(bytes, 8, format_version);
    putU16(bytes, 10, schema_cohort);
    putU32(bytes, 12, header_size);
    putU64(bytes, 16, total_size);
    putU64(bytes, 24, header_size);
    putU64(bytes, 32, total_size - header_size);
    @memcpy(bytes[40..72], &bundle.source_digest);
    putU16(bytes, 104, section_count);
    putU16(bytes, 106, 0);
    putU32(bytes, 108, bundle.bundle_name.offset);
    putU32(bytes, 112, bundle.bundle_name.len);
    for (sections, 0..) |section, index| writeSectionDesc(bytes, index, section);

    @memcpy(sectionBytes(bytes, sections[@intFromEnum(Section.strings)]), bundle.strings);
    encodeNodes(sectionBytes(bytes, sections[@intFromEnum(Section.nodes)]), bundle.nodes);
    encodeMeshes(sectionBytes(bytes, sections[@intFromEnum(Section.meshes)]), bundle.meshes);
    encodePrimitives(sectionBytes(bytes, sections[@intFromEnum(Section.primitives)]), bundle.primitives);
    encodeMaterials(sectionBytes(bytes, sections[@intFromEnum(Section.materials)]), bundle.materials);
    encodeTextures(sectionBytes(bytes, sections[@intFromEnum(Section.textures)]), bundle.textures);
    encodeVertices(sectionBytes(bytes, sections[@intFromEnum(Section.vertices)]), bundle.vertices);
    encodeIndices(sectionBytes(bytes, sections[@intFromEnum(Section.indices)]), bundle.indices);
    @memcpy(sectionBytes(bytes, sections[@intFromEnum(Section.pixels)]), bundle.pixels);
    encodeStaticBoxes(sectionBytes(bytes, sections[@intFromEnum(Section.static_boxes)]), bundle.static_boxes);

    var integrity_digest: [32]u8 = undefined;
    calculateIntegrity(bytes, &integrity_digest);
    @memcpy(bytes[72..104], &integrity_digest);
    return .{ .bytes = bytes };
}

pub fn decode(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    limits: Limits,
) !DecodeResult {
    if (bytes.len > limits.max_file_bytes) return .{ .failed = .{ .capacity_exceeded = .{
        .kind = .file_bytes,
        .actual = bytes.len,
        .maximum = limits.max_file_bytes,
    } } };
    if (bytes.len < header_size) return .{ .failed = .invalid_header };
    if (!std.mem.eql(u8, bytes[0..magic.len], &magic)) return .{ .failed = .bad_magic };

    const found_format = getU16(bytes, 8);
    if (found_format != format_version) {
        return .{ .failed = .{ .unsupported_format_version = found_format } };
    }
    const found_schema = getU16(bytes, 10);
    if (found_schema != schema_cohort) {
        return .{ .failed = .{ .incompatible_schema = found_schema } };
    }
    if (getU32(bytes, 12) != header_size or
        getU64(bytes, 16) != bytes.len or
        getU64(bytes, 24) != header_size or
        getU64(bytes, 32) != bytes.len - header_size or
        getU16(bytes, 104) != section_count or
        getU16(bytes, 106) != 0)
    {
        return .{ .failed = .invalid_header };
    }

    var expected_digest: [32]u8 = undefined;
    calculateIntegrity(bytes, &expected_digest);
    if (!std.mem.eql(u8, bytes[72..104], &expected_digest)) {
        return .{ .failed = .integrity_mismatch };
    }

    var sections: [section_count]SectionDesc = undefined;
    var expected_offset: u64 = header_size;
    for (&sections, section_strides, 0..) |*section, expected_stride, index| {
        section.* = readSectionDesc(bytes, index);
        if (section.stride != expected_stride) {
            return .{ .failed = .{ .invalid_section = @enumFromInt(index) } };
        }
        const expected_size = std.math.mul(u32, section.count, section.stride) catch
            return .{ .failed = .{ .invalid_section = @enumFromInt(index) } };
        expected_offset = std.mem.alignForward(u64, expected_offset, 4);
        const end = std.math.add(u64, section.offset, section.byte_size) catch
            return .{ .failed = .{ .invalid_section = @enumFromInt(index) } };
        if (section.byte_size != expected_size or section.offset != expected_offset or end > bytes.len) {
            return .{ .failed = .{ .invalid_section = @enumFromInt(index) } };
        }
        expected_offset = end;
    }
    if (expected_offset != bytes.len) return .{ .failed = .size_mismatch };

    const counts = Counts.fromSections(sections);
    if (counts.capacityFailure(limits)) |failure| {
        return .{ .failed = .{ .capacity_exceeded = failure } };
    }

    const strings = try allocator.dupe(u8, constSectionBytes(bytes, sections[@intFromEnum(Section.strings)]));
    errdefer allocator.free(strings);
    const nodes = try allocator.alloc(Node, counts.nodes);
    errdefer allocator.free(nodes);
    const meshes = try allocator.alloc(Mesh, counts.meshes);
    errdefer allocator.free(meshes);
    const primitives = try allocator.alloc(Primitive, counts.primitives);
    errdefer allocator.free(primitives);
    const materials = try allocator.alloc(Material, counts.materials);
    errdefer allocator.free(materials);
    const textures = try allocator.alloc(Texture, counts.textures);
    errdefer allocator.free(textures);
    const vertices = try allocator.alloc(VertexPNU, counts.vertices);
    errdefer allocator.free(vertices);
    const indices = try allocator.alloc(u32, counts.indices);
    errdefer allocator.free(indices);
    const pixels = try allocator.dupe(u8, constSectionBytes(bytes, sections[@intFromEnum(Section.pixels)]));
    errdefer allocator.free(pixels);
    const static_boxes = try allocator.alloc(StaticBox, counts.static_boxes);
    errdefer allocator.free(static_boxes);

    decodeNodes(nodes, constSectionBytes(bytes, sections[@intFromEnum(Section.nodes)]));
    decodeMeshes(meshes, constSectionBytes(bytes, sections[@intFromEnum(Section.meshes)]));
    decodePrimitives(primitives, constSectionBytes(bytes, sections[@intFromEnum(Section.primitives)]));
    decodeMaterials(materials, constSectionBytes(bytes, sections[@intFromEnum(Section.materials)]));
    decodeTextures(textures, constSectionBytes(bytes, sections[@intFromEnum(Section.textures)]));
    decodeVertices(vertices, constSectionBytes(bytes, sections[@intFromEnum(Section.vertices)]));
    decodeIndices(indices, constSectionBytes(bytes, sections[@intFromEnum(Section.indices)]));
    decodeStaticBoxes(static_boxes, constSectionBytes(bytes, sections[@intFromEnum(Section.static_boxes)]));

    var source_digest: [32]u8 = undefined;
    @memcpy(&source_digest, bytes[40..72]);
    var owned = OwnedBundle{
        .allocator = allocator,
        .bundle_name = .{ .offset = getU32(bytes, 108), .len = getU32(bytes, 112) },
        .source_digest = source_digest,
        .strings = strings,
        .nodes = nodes,
        .meshes = meshes,
        .primitives = primitives,
        .materials = materials,
        .textures = textures,
        .vertices = vertices,
        .indices = indices,
        .pixels = pixels,
        .static_boxes = static_boxes,
    };
    if (validationFailure(owned.view(), limits)) |failure| {
        owned.deinit();
        return .{ .failed = failure };
    }
    return .{ .bundle = owned };
}

fn validationFailure(bundle: BundleView, limits: Limits) ?ValidationFailure {
    const counts = Counts.fromView(bundle);
    if (counts.capacityFailure(limits)) |failure| return .{ .capacity_exceeded = failure };
    if (bundle.bundle_name.bytes(bundle.strings) == null) return .invalid_name;
    if (!std.unicode.utf8ValidateSlice(bundle.strings)) return .invalid_name;
    if (bundle.nodes.len == 0 or bundle.meshes.len == 0 or bundle.primitives.len == 0 or
        bundle.materials.len == 0 or bundle.vertices.len == 0 or bundle.indices.len == 0 or
        bundle.static_boxes.len == 0)
    {
        return .invalid_geometry;
    }

    var root_count: usize = 0;
    for (bundle.nodes, 0..) |node, index| {
        if (node.name.bytes(bundle.strings) == null) return .invalid_name;
        if (node.parent == none_index) {
            root_count += 1;
        } else if (node.parent >= index) {
            return .invalid_reference;
        }
        if (node.mesh != none_index and node.mesh >= bundle.meshes.len) return .invalid_reference;
        for (node.local_transform) |value| if (!std.math.isFinite(value)) return .invalid_transform;
    }
    if (root_count == 0) return .invalid_reference;

    for (bundle.meshes) |mesh| {
        if (mesh.name.bytes(bundle.strings) == null or mesh.primitive_count == 0) return .invalid_name;
        if (!rangeInBounds(mesh.first_primitive, mesh.primitive_count, bundle.primitives.len)) {
            return .invalid_reference;
        }
    }
    for (bundle.primitives) |primitive| {
        if (primitive.vertex_count == 0 or primitive.index_count == 0 or primitive.index_count % 3 != 0) {
            return .invalid_geometry;
        }
        if (!rangeInBounds(primitive.first_vertex, primitive.vertex_count, bundle.vertices.len) or
            !rangeInBounds(primitive.first_index, primitive.index_count, bundle.indices.len) or
            primitive.material >= bundle.materials.len)
        {
            return .invalid_reference;
        }
        for (bundle.indices[primitive.first_index..][0..primitive.index_count]) |index| {
            if (index < primitive.first_vertex or
                index >= primitive.first_vertex + primitive.vertex_count) return .invalid_geometry;
        }
    }
    for (bundle.materials) |material| {
        if (material.name.bytes(bundle.strings) == null or material.flags != 0) return .invalid_material;
        for (material.base_color) |value| {
            if (!std.math.isFinite(value) or value < 0 or value > 1) return .invalid_material;
        }
        if (material.base_color_texture != none_index and
            material.base_color_texture >= bundle.textures.len) return .invalid_reference;
    }
    for (bundle.textures) |texture| {
        if (texture.name.bytes(bundle.strings) == null or texture.width == 0 or texture.height == 0 or
            (texture.format != .rgba8_unorm and texture.format != .rgba8_srgb)) return .invalid_texture;
        const pixels = std.math.mul(u32, texture.width, texture.height) catch return .invalid_texture;
        const expected_size = std.math.mul(u32, pixels, 4) catch return .invalid_texture;
        if (texture.pixel_size != expected_size or
            !rangeInBounds(texture.pixel_offset, texture.pixel_size, bundle.pixels.len)) return .invalid_texture;
    }
    for (bundle.vertices) |vertex| {
        for (vertex.position ++ vertex.normal ++ vertex.texcoord) |value| {
            if (!std.math.isFinite(value)) return .invalid_geometry;
        }
    }
    for (bundle.static_boxes) |box| {
        for (box.position ++ box.rotation ++ box.half_extents) |value| {
            if (!std.math.isFinite(value)) return .invalid_static_box;
        }
        for (box.half_extents) |value| if (value <= 0) return .invalid_static_box;
        const canonical_rotation = [4]f32{ 0, 0, 0, 1 };
        for (box.rotation, canonical_rotation) |actual, expected| {
            if (@as(u32, @bitCast(actual)) != @as(u32, @bitCast(expected))) {
                return .invalid_static_box;
            }
        }
    }
    if (hasDuplicateNames(bundle.nodes, bundle.strings) or
        hasDuplicateNames(bundle.meshes, bundle.strings) or
        hasDuplicateNames(bundle.materials, bundle.strings) or
        hasDuplicateNames(bundle.textures, bundle.strings)) return .duplicate_name;
    return null;
}

fn hasDuplicateNames(items: anytype, strings: []const u8) bool {
    for (items, 0..) |item, index| {
        const name = item.name.bytes(strings) orelse return true;
        for (items[index + 1 ..]) |other| {
            const other_name = other.name.bytes(strings) orelse return true;
            if (std.mem.eql(u8, name, other_name)) return true;
        }
    }
    return false;
}

fn rangeInBounds(first: u32, count: u32, len: usize) bool {
    const end = std.math.add(u32, first, count) catch return false;
    return end <= len;
}

const Counts = struct {
    strings: u32,
    nodes: u32,
    meshes: u32,
    primitives: u32,
    materials: u32,
    textures: u32,
    vertices: u32,
    indices: u32,
    pixels: u32,
    static_boxes: u32,

    fn fromView(bundle: BundleView) Counts {
        return .{
            .strings = count32(bundle.strings.len),
            .nodes = count32(bundle.nodes.len),
            .meshes = count32(bundle.meshes.len),
            .primitives = count32(bundle.primitives.len),
            .materials = count32(bundle.materials.len),
            .textures = count32(bundle.textures.len),
            .vertices = count32(bundle.vertices.len),
            .indices = count32(bundle.indices.len),
            .pixels = count32(bundle.pixels.len),
            .static_boxes = count32(bundle.static_boxes.len),
        };
    }

    fn fromSections(sections: [section_count]SectionDesc) Counts {
        return .{
            .strings = sections[0].count,
            .nodes = sections[1].count,
            .meshes = sections[2].count,
            .primitives = sections[3].count,
            .materials = sections[4].count,
            .textures = sections[5].count,
            .vertices = sections[6].count,
            .indices = sections[7].count,
            .pixels = sections[8].count,
            .static_boxes = sections[9].count,
        };
    }

    fn capacityFailure(self: Counts, limits: Limits) ?CapacityFailure {
        const checks = .{
            .{ CapacityKind.strings, self.strings, limits.max_strings_bytes },
            .{ CapacityKind.nodes, self.nodes, limits.max_nodes },
            .{ CapacityKind.meshes, self.meshes, limits.max_meshes },
            .{ CapacityKind.primitives, self.primitives, limits.max_primitives },
            .{ CapacityKind.materials, self.materials, limits.max_materials },
            .{ CapacityKind.textures, self.textures, limits.max_textures },
            .{ CapacityKind.vertices, self.vertices, limits.max_vertices },
            .{ CapacityKind.indices, self.indices, limits.max_indices },
            .{ CapacityKind.pixels, self.pixels, limits.max_pixel_bytes },
            .{ CapacityKind.static_boxes, self.static_boxes, limits.max_static_boxes },
        };
        inline for (checks) |check| {
            if (check[1] > check[2]) return .{ .kind = check[0], .actual = check[1], .maximum = check[2] };
        }
        return null;
    }
};

fn count32(value: usize) u32 {
    return std.math.cast(u32, value) orelse std.math.maxInt(u32);
}

/// Covers the canonical header and payload while treating the digest field
/// itself as zero. This authenticates neither bytes nor publisher; it detects
/// accidental/corrupt mutation of source identity, semantic name, section
/// metadata, and payload as one immutable unit.
fn calculateIntegrity(bytes: []const u8, out: *[32]u8) void {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(bytes[0..72]);
    hash.update(&([_]u8{0} ** 32));
    hash.update(bytes[104..]);
    hash.final(out);
}

fn sectionCounts(bundle: BundleView) [section_count]u32 {
    const counts = Counts.fromView(bundle);
    return .{ counts.strings, counts.nodes, counts.meshes, counts.primitives, counts.materials, counts.textures, counts.vertices, counts.indices, counts.pixels, counts.static_boxes };
}

fn sectionBytes(bytes: []u8, section: SectionDesc) []u8 {
    return bytes[section.offset..][0..section.byte_size];
}

fn constSectionBytes(bytes: []const u8, section: SectionDesc) []const u8 {
    return bytes[section.offset..][0..section.byte_size];
}

fn writeSectionDesc(bytes: []u8, index: usize, section: SectionDesc) void {
    const offset = 120 + index * 16;
    putU32(bytes, offset, section.offset);
    putU32(bytes, offset + 4, section.count);
    putU32(bytes, offset + 8, section.stride);
    putU32(bytes, offset + 12, section.byte_size);
}

fn readSectionDesc(bytes: []const u8, index: usize) SectionDesc {
    const offset = 120 + index * 16;
    return .{
        .offset = getU32(bytes, offset),
        .count = getU32(bytes, offset + 4),
        .stride = getU32(bytes, offset + 8),
        .byte_size = getU32(bytes, offset + 12),
    };
}

fn encodeNodes(bytes: []u8, values: []const Node) void {
    for (values, 0..) |value, index| {
        const base = index * 80;
        putName(bytes, base, value.name);
        putU32(bytes, base + 8, value.parent);
        putU32(bytes, base + 12, value.mesh);
        for (value.local_transform, 0..) |item, item_index| putF32(bytes, base + 16 + item_index * 4, item);
    }
}

fn decodeNodes(values: []Node, bytes: []const u8) void {
    for (values, 0..) |*value, index| {
        const base = index * 80;
        value.name = getName(bytes, base);
        value.parent = getU32(bytes, base + 8);
        value.mesh = getU32(bytes, base + 12);
        for (&value.local_transform, 0..) |*item, item_index| item.* = getF32(bytes, base + 16 + item_index * 4);
    }
}

fn encodeMeshes(bytes: []u8, values: []const Mesh) void {
    for (values, 0..) |value, index| {
        const base = index * 16;
        putName(bytes, base, value.name);
        putU32(bytes, base + 8, value.first_primitive);
        putU32(bytes, base + 12, value.primitive_count);
    }
}

fn decodeMeshes(values: []Mesh, bytes: []const u8) void {
    for (values, 0..) |*value, index| {
        const base = index * 16;
        value.* = .{ .name = getName(bytes, base), .first_primitive = getU32(bytes, base + 8), .primitive_count = getU32(bytes, base + 12) };
    }
}

fn encodePrimitives(bytes: []u8, values: []const Primitive) void {
    for (values, 0..) |value, index| {
        const base = index * 20;
        putU32(bytes, base, value.first_vertex);
        putU32(bytes, base + 4, value.vertex_count);
        putU32(bytes, base + 8, value.first_index);
        putU32(bytes, base + 12, value.index_count);
        putU32(bytes, base + 16, value.material);
    }
}

fn decodePrimitives(values: []Primitive, bytes: []const u8) void {
    for (values, 0..) |*value, index| {
        const base = index * 20;
        value.* = .{ .first_vertex = getU32(bytes, base), .vertex_count = getU32(bytes, base + 4), .first_index = getU32(bytes, base + 8), .index_count = getU32(bytes, base + 12), .material = getU32(bytes, base + 16) };
    }
}

fn encodeMaterials(bytes: []u8, values: []const Material) void {
    for (values, 0..) |value, index| {
        const base = index * 32;
        putName(bytes, base, value.name);
        for (value.base_color, 0..) |item, item_index| putF32(bytes, base + 8 + item_index * 4, item);
        putU32(bytes, base + 24, value.base_color_texture);
        putU32(bytes, base + 28, value.flags);
    }
}

fn decodeMaterials(values: []Material, bytes: []const u8) void {
    for (values, 0..) |*value, index| {
        const base = index * 32;
        value.name = getName(bytes, base);
        for (&value.base_color, 0..) |*item, item_index| item.* = getF32(bytes, base + 8 + item_index * 4);
        value.base_color_texture = getU32(bytes, base + 24);
        value.flags = getU32(bytes, base + 28);
    }
}

fn encodeTextures(bytes: []u8, values: []const Texture) void {
    for (values, 0..) |value, index| {
        const base = index * 28;
        putName(bytes, base, value.name);
        putU32(bytes, base + 8, value.width);
        putU32(bytes, base + 12, value.height);
        putU32(bytes, base + 16, @intFromEnum(value.format));
        putU32(bytes, base + 20, value.pixel_offset);
        putU32(bytes, base + 24, value.pixel_size);
    }
}

fn decodeTextures(values: []Texture, bytes: []const u8) void {
    for (values, 0..) |*value, index| {
        const base = index * 28;
        value.* = .{ .name = getName(bytes, base), .width = getU32(bytes, base + 8), .height = getU32(bytes, base + 12), .format = @enumFromInt(getU32(bytes, base + 16)), .pixel_offset = getU32(bytes, base + 20), .pixel_size = getU32(bytes, base + 24) };
    }
}

fn encodeVertices(bytes: []u8, values: []const VertexPNU) void {
    for (values, 0..) |value, index| {
        const base = index * 32;
        var item_index: usize = 0;
        for (value.position ++ value.normal ++ value.texcoord) |item| {
            putF32(bytes, base + item_index * 4, item);
            item_index += 1;
        }
    }
}

fn decodeVertices(values: []VertexPNU, bytes: []const u8) void {
    for (values, 0..) |*value, index| {
        const base = index * 32;
        for (&value.position, 0..) |*item, item_index| item.* = getF32(bytes, base + item_index * 4);
        for (&value.normal, 0..) |*item, item_index| item.* = getF32(bytes, base + 12 + item_index * 4);
        for (&value.texcoord, 0..) |*item, item_index| item.* = getF32(bytes, base + 24 + item_index * 4);
    }
}

fn encodeIndices(bytes: []u8, values: []const u32) void {
    for (values, 0..) |value, index| putU32(bytes, index * 4, value);
}

fn decodeIndices(values: []u32, bytes: []const u8) void {
    for (values, 0..) |*value, index| value.* = getU32(bytes, index * 4);
}

fn encodeStaticBoxes(bytes: []u8, values: []const StaticBox) void {
    for (values, 0..) |value, index| {
        const base = index * 40;
        var item_index: usize = 0;
        for (value.position ++ value.rotation ++ value.half_extents) |item| {
            putF32(bytes, base + item_index * 4, item);
            item_index += 1;
        }
    }
}

fn decodeStaticBoxes(values: []StaticBox, bytes: []const u8) void {
    for (values, 0..) |*value, index| {
        const base = index * 40;
        for (&value.position, 0..) |*item, item_index| item.* = getF32(bytes, base + item_index * 4);
        for (&value.rotation, 0..) |*item, item_index| item.* = getF32(bytes, base + 12 + item_index * 4);
        for (&value.half_extents, 0..) |*item, item_index| item.* = getF32(bytes, base + 28 + item_index * 4);
    }
}

fn putName(bytes: []u8, offset: usize, value: NameRef) void {
    putU32(bytes, offset, value.offset);
    putU32(bytes, offset + 4, value.len);
}

fn getName(bytes: []const u8, offset: usize) NameRef {
    return .{ .offset = getU32(bytes, offset), .len = getU32(bytes, offset + 4) };
}

fn putU16(bytes: []u8, offset: usize, value: u16) void {
    std.mem.writeInt(u16, bytes[offset..][0..2], value, .little);
}

fn putU32(bytes: []u8, offset: usize, value: anytype) void {
    std.mem.writeInt(u32, bytes[offset..][0..4], @intCast(value), .little);
}

fn putU64(bytes: []u8, offset: usize, value: anytype) void {
    std.mem.writeInt(u64, bytes[offset..][0..8], @intCast(value), .little);
}

fn putF32(bytes: []u8, offset: usize, value: f32) void {
    putU32(bytes, offset, @as(u32, @bitCast(value)));
}

fn getU16(bytes: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, bytes[offset..][0..2], .little);
}

fn getU32(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}

fn getU64(bytes: []const u8, offset: usize) u64 {
    return std.mem.readInt(u64, bytes[offset..][0..8], .little);
}

fn getF32(bytes: []const u8, offset: usize) f32 {
    return @bitCast(getU32(bytes, offset));
}

const fixture_strings = "district/s3_fixtureLeftInstanceRightInstanceFixtureTriangleFixtureMaterialFixtureTexture";
const identity = [16]f32{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };

fn refAt(comptime value: []const u8) NameRef {
    const offset = std.mem.indexOf(u8, fixture_strings, value).?;
    return .{ .offset = @intCast(offset), .len = @intCast(value.len) };
}

const test_nodes = [_]Node{
    .{ .name = refAt("LeftInstance"), .mesh = 0, .local_transform = identity },
    .{ .name = refAt("RightInstance"), .mesh = 0, .local_transform = .{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 4, 0, 0, 1 } },
};
const test_meshes = [_]Mesh{.{ .name = refAt("FixtureTriangle"), .first_primitive = 0, .primitive_count = 1 }};
const test_primitives = [_]Primitive{.{ .first_vertex = 0, .vertex_count = 3, .first_index = 0, .index_count = 3, .material = 0 }};
const test_materials = [_]Material{.{ .name = refAt("FixtureMaterial"), .base_color = .{ 1, 0.5, 0.25, 1 }, .base_color_texture = 0 }};
const test_textures = [_]Texture{.{ .name = refAt("FixtureTexture"), .width = 1, .height = 1, .pixel_offset = 0, .pixel_size = 4 }};
const test_vertices = [_]VertexPNU{
    .{ .position = .{ -1, 0, 0 }, .normal = .{ 0, 0, 1 }, .texcoord = .{ 0, 0 } },
    .{ .position = .{ 1, 0, 0 }, .normal = .{ 0, 0, 1 }, .texcoord = .{ 1, 0 } },
    .{ .position = .{ 0, 1, 0 }, .normal = .{ 0, 0, 1 }, .texcoord = .{ 0.5, 1 } },
};
const test_indices = [_]u32{ 0, 1, 2 };
const test_pixels = [_]u8{ 255, 64, 32, 255 };
const test_boxes = [_]StaticBox{.{ .position = .{ 0, -0.5, 0 }, .half_extents = .{ 7.5, 0.5, 7.5 } }};

fn testBundle() BundleView {
    return .{
        .bundle_name = refAt("district/s3_fixture"),
        .source_digest = [_]u8{0x5a} ** 32,
        .strings = fixture_strings,
        .nodes = &test_nodes,
        .meshes = &test_meshes,
        .primitives = &test_primitives,
        .materials = &test_materials,
        .textures = &test_textures,
        .vertices = &test_vertices,
        .indices = &test_indices,
        .pixels = &test_pixels,
        .static_boxes = &test_boxes,
    };
}

test "bundle encoding is deterministic little-endian and round trips scene relationships" {
    const first = (try encode(std.testing.allocator, testBundle(), .{})).bytes;
    defer std.testing.allocator.free(first);
    const second = (try encode(std.testing.allocator, testBundle(), .{})).bytes;
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualSlices(u8, first, second);
    try std.testing.expectEqualSlices(u8, &magic, first[0..8]);
    try std.testing.expectEqual(@as(u16, 1), getU16(first, 8));

    var decoded = (try decode(std.testing.allocator, first, .{})).bundle;
    defer decoded.deinit();
    const view = decoded.view();
    try std.testing.expectEqualStrings("district/s3_fixture", view.name(view.bundle_name).?);
    try std.testing.expectEqual(@as(usize, 2), view.nodes.len);
    try std.testing.expectEqual(@as(u32, 0), view.nodes[0].mesh);
    try std.testing.expectEqual(@as(u32, 0), view.nodes[1].mesh);
    try std.testing.expectEqual(@as(f32, 4), view.nodes[1].local_transform[12]);
    try std.testing.expectEqual(@as(u32, 0), view.primitives[0].material);
    try std.testing.expectEqual(@as(u32, 0), view.materials[0].base_color_texture);
    try std.testing.expectEqualSlices(u8, &test_pixels, view.pixels);
}

test "bundle rejects integrity corruption before constructing typed slices" {
    const bytes = (try encode(std.testing.allocator, testBundle(), .{})).bytes;
    defer std.testing.allocator.free(bytes);
    bytes[bytes.len - 1] ^= 1;
    const result = try decode(std.testing.allocator, bytes, .{});
    try std.testing.expect(result == .failed);
    try std.testing.expect(result.failed == .integrity_mismatch);

    const header_bytes = (try encode(std.testing.allocator, testBundle(), .{})).bytes;
    defer std.testing.allocator.free(header_bytes);
    header_bytes[40] ^= 1;
    const header_result = try decode(std.testing.allocator, header_bytes, .{});
    try std.testing.expect(header_result.failed == .integrity_mismatch);
}

test "bundle rejects version, schema, section, reference, and capacity failures" {
    const canonical = (try encode(std.testing.allocator, testBundle(), .{})).bytes;
    defer std.testing.allocator.free(canonical);

    const versioned = try std.testing.allocator.dupe(u8, canonical);
    defer std.testing.allocator.free(versioned);
    putU16(versioned, 8, format_version + 1);
    const bad_version = try decode(std.testing.allocator, versioned, .{});
    try std.testing.expectEqual(format_version + 1, bad_version.failed.unsupported_format_version);

    const schema = try std.testing.allocator.dupe(u8, canonical);
    defer std.testing.allocator.free(schema);
    putU16(schema, 10, schema_cohort + 1);
    const bad_schema = try decode(std.testing.allocator, schema, .{});
    try std.testing.expectEqual(schema_cohort + 1, bad_schema.failed.incompatible_schema);

    const section = try std.testing.allocator.dupe(u8, canonical);
    defer std.testing.allocator.free(section);
    putU32(section, 120 + @intFromEnum(Section.nodes) * 16 + 8, 79);
    @memset(section[72..104], 0);
    var section_digest: [32]u8 = undefined;
    calculateIntegrity(section, &section_digest);
    @memcpy(section[72..104], &section_digest);
    const bad_section = try decode(std.testing.allocator, section, .{});
    try std.testing.expectEqual(Section.nodes, bad_section.failed.invalid_section);

    const texture_format = try std.testing.allocator.dupe(u8, canonical);
    defer std.testing.allocator.free(texture_format);
    const texture_section = readSectionDesc(texture_format, @intFromEnum(Section.textures));
    putU32(texture_format, texture_section.offset + 16, 99);
    @memset(texture_format[72..104], 0);
    var texture_digest: [32]u8 = undefined;
    calculateIntegrity(texture_format, &texture_digest);
    @memcpy(texture_format[72..104], &texture_digest);
    const bad_texture = try decode(std.testing.allocator, texture_format, .{});
    try std.testing.expect(bad_texture.failed == .invalid_texture);

    var invalid = testBundle();
    var nodes = test_nodes;
    nodes[0].mesh = 99;
    invalid.nodes = &nodes;
    try std.testing.expect((try encode(std.testing.allocator, invalid, .{})).failed == .invalid_reference);

    var limits = Limits{};
    limits.max_nodes = 1;
    const over_capacity = try encode(std.testing.allocator, testBundle(), limits);
    try std.testing.expectEqual(CapacityKind.nodes, over_capacity.failed.capacity_exceeded.kind);
}

test "bundle validation rejects non-finite transforms and invalid texture ranges" {
    var invalid = testBundle();
    var nodes = test_nodes;
    nodes[0].local_transform[0] = std.math.nan(f32);
    invalid.nodes = &nodes;
    try std.testing.expect((try encode(std.testing.allocator, invalid, .{})).failed == .invalid_transform);

    invalid = testBundle();
    var textures = test_textures;
    textures[0].pixel_size = 3;
    invalid.textures = &textures;
    try std.testing.expect((try encode(std.testing.allocator, invalid, .{})).failed == .invalid_texture);

    invalid = testBundle();
    var boxes = test_boxes;
    boxes[0].rotation = .{ 0, 0.5, 0, 0.5 };
    invalid.static_boxes = &boxes;
    try std.testing.expect((try encode(std.testing.allocator, invalid, .{})).failed == .invalid_static_box);
}
