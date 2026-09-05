//! Offline glTF-to-Incinerator district bundle cooker.

const std = @import("std");
const zmesh = @import("zmesh");
const zstbi = @import("zstbi");
const content = @import("content");
const district_contract = @import("district_contract");
const sandbox_recipe = @import("sandbox_district_recipe");
const bundle = content.bundle;
const cgltf = zmesh.io.zcgltf;

const max_source_bytes = 512 * 1024;
const max_image_source_bytes = 4 * 1024 * 1024;
const max_dependency_id_bytes = 64;
const max_dependencies = 8;
const max_source_dependencies = 8;
const dependency_digest_domain = "incinerator.district.cook.dependencies.v1";
const root_translation_digest_domain = "incinerator.district.cook.root-translation.v1";

const DependencyArgument = struct {
    semantic_id: []const u8,
    bundle_path: []const u8,
};

const Invocation = struct {
    input_path: []const u8,
    provenance_path: []const u8,
    output_path: []const u8,
    key: content.BundleKey,
    coord: district_contract.ChunkCoord,
    root_translation: [3]f32,
    dependencies: [max_dependencies]DependencyArgument = undefined,
    dependency_count: u8 = 0,
    source_dependencies: [max_source_dependencies][]const u8 = undefined,
    source_dependency_count: u8 = 0,

    fn dependencySlice(self: *const Invocation) []const DependencyArgument {
        return self.dependencies[0..self.dependency_count];
    }

    fn sourceDependencySlice(self: *const Invocation) []const []const u8 {
        return self.source_dependencies[0..self.source_dependency_count];
    }
};

const HashedDependency = struct {
    semantic_id: []const u8,
    bundle_key: content.BundleKey,
    canonical_identity: [32]u8,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const invocation = try parseInvocation(args);

    const source = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        invocation.input_path,
        allocator,
        .limited(max_source_bytes),
    );
    defer allocator.free(source);
    const provenance = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        invocation.provenance_path,
        allocator,
        .limited(16 * 1024),
    );
    defer allocator.free(provenance);
    if (provenance.len == 0 or
        std.mem.indexOf(u8, provenance, "External source material: none") == null)
    {
        return error.InvalidFixtureProvenance;
    }

    const source_z = try allocator.dupeZ(u8, invocation.input_path);
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
    var resolver = try SourceResolver.open(init.io, invocation.input_path);
    defer resolver.deinit(init.io);
    try validateDeclaredSourceDependencies(
        init.io,
        allocator,
        data,
        &resolver,
        invocation.sourceDependencySlice(),
    );
    try requireSafeBoundedBuffers(data);
    try cgltf.loadBuffers(cgltf_options, data, source_z);
    const source_digest = try sourceDigest(
        init.io,
        allocator,
        source,
        provenance,
        &invocation.key,
        invocation.root_translation,
        invocation.dependencySlice(),
        data,
        &resolver,
    );
    var cooked = try cook(
        allocator,
        data,
        &resolver,
        invocation.key.bytes(),
        invocation.coord,
        invocation.root_translation,
        source_digest,
    );
    defer cooked.deinit();
    const encoded = switch (try bundle.encode(allocator, cooked.view(), .{})) {
        .bytes => |bytes| bytes,
        .failed => return error.CookedBundleValidationFailed,
    };
    defer allocator.free(encoded);
    try writeAtomic(init.io, invocation.output_path, encoded);
}

fn parseInvocation(args: anytype) !Invocation {
    if (args.len < 10) {
        return error.ExpectedInputProvenanceOutputKeyCoordinateTranslationAndDependencies;
    }

    const input_path: []const u8 = args[1];
    const provenance_path: []const u8 = args[2];
    const output_path: []const u8 = args[3];
    const key = try content.BundleKey.parse(args[4]);
    const coord_x = std.fmt.parseInt(i32, args[5], 10) catch
        return error.InvalidDistrictCoordinate;
    const coord_z = std.fmt.parseInt(i32, args[6], 10) catch
        return error.InvalidDistrictCoordinate;
    var root_translation: [3]f32 = undefined;
    for (&root_translation, args[7..10]) |*component, argument| {
        component.* = std.fmt.parseFloat(f32, argument) catch
            return error.InvalidRootTranslation;
        if (!std.math.isFinite(component.*)) return error.InvalidRootTranslation;
    }

    var result = Invocation{
        .input_path = input_path,
        .provenance_path = provenance_path,
        .output_path = output_path,
        .key = key,
        .coord = .{ .x = coord_x, .z = coord_z },
        .root_translation = root_translation,
    };
    var cursor: usize = 10;
    while (cursor < args.len and std.mem.eql(u8, args[cursor], "--source-dependency")) {
        if (cursor + 1 >= args.len) return error.SourceDependencyPathRequired;
        if (result.source_dependency_count == max_source_dependencies) {
            return error.TooManySourceDependencies;
        }
        const path: []const u8 = args[cursor + 1];
        if (path.len == 0) return error.SourceDependencyPathRequired;
        for (result.sourceDependencySlice()) |existing| {
            if (std.mem.eql(u8, existing, path)) return error.DuplicateSourceDependency;
        }
        result.source_dependencies[result.source_dependency_count] = path;
        result.source_dependency_count += 1;
        cursor += 2;
    }
    if ((args.len - cursor) % 2 != 0) return error.InvalidCookDependencyArguments;
    const dependency_count = (args.len - cursor) / 2;
    if (dependency_count > max_dependencies) return error.TooManyCookDependencies;

    var previous_id: ?[]const u8 = null;
    for (0..dependency_count) |index| {
        const semantic_id: []const u8 = args[cursor + index * 2];
        const bundle_path: []const u8 = args[cursor + index * 2 + 1];
        if (!isValidDependencyId(semantic_id)) return error.InvalidDependencySemanticId;
        if (bundle_path.len == 0) return error.InvalidDependencyBundlePath;
        if (previous_id) |previous| {
            switch (std.mem.order(u8, previous, semantic_id)) {
                .lt => {},
                .eq => return error.DuplicateDependencySemanticId,
                .gt => return error.UnsortedDependencySemanticIds,
            }
        }
        result.dependencies[index] = .{
            .semantic_id = semantic_id,
            .bundle_path = bundle_path,
        };
        previous_id = semantic_id;
    }
    result.dependency_count = @intCast(dependency_count);
    return result;
}

fn validateDeclaredSourceDependencies(
    io: std.Io,
    allocator: std.mem.Allocator,
    data: *cgltf.Data,
    resolver: *const SourceResolver,
    declared: []const []const u8,
) !void {
    const images = if (data.images_count == 0)
        &[_]cgltf.Image{}
    else
        (data.images orelse return error.InvalidImageTable)[0..data.images_count];
    var matched: [max_source_dependencies]bool = @splat(false);
    for (images) |image| {
        const uri = if (image.uri) |raw| cString(raw) else continue;
        if (std.mem.startsWith(u8, uri, "data:")) continue;
        var match: ?usize = null;
        for (declared, 0..) |path, index| {
            if (std.mem.eql(u8, std.fs.path.basename(path), uri)) {
                if (match != null) return error.AmbiguousDeclaredSourceDependency;
                match = index;
            }
        }
        const index = match orelse return error.UndeclaredSourceDependency;
        const rooted_bytes = try resolver.read(allocator, uri);
        defer allocator.free(rooted_bytes);
        const declared_bytes = try std.Io.Dir.cwd().readFileAlloc(
            io,
            declared[index],
            allocator,
            .limited(max_image_source_bytes),
        );
        defer allocator.free(declared_bytes);
        if (!std.mem.eql(u8, rooted_bytes, declared_bytes)) {
            return error.SourceDependencyContentMismatch;
        }
        matched[index] = true;
    }
    for (matched[0..declared.len]) |value| {
        if (!value) return error.UnusedDeclaredSourceDependency;
    }
}

fn isValidDependencyId(value: []const u8) bool {
    if (value.len == 0 or value.len > max_dependency_id_bytes) return false;
    if (!isLowerAlphaNumeric(value[0]) or !isLowerAlphaNumeric(value[value.len - 1])) {
        return false;
    }
    var segment_start: usize = 0;
    for (value, 0..) |byte, index| {
        const allowed = isLowerAlphaNumeric(byte) or
            byte == '_' or byte == '-' or byte == '.' or byte == '/';
        if (!allowed) return false;
        if (byte == '/') {
            const segment = value[segment_start..index];
            if (segment.len == 0 or std.mem.eql(u8, segment, ".") or
                std.mem.eql(u8, segment, "..")) return false;
            segment_start = index + 1;
        }
    }
    const final_segment = value[segment_start..];
    return final_segment.len != 0 and
        !std.mem.eql(u8, final_segment, ".") and
        !std.mem.eql(u8, final_segment, "..");
}

fn isLowerAlphaNumeric(byte: u8) bool {
    return (byte >= 'a' and byte <= 'z') or (byte >= '0' and byte <= '9');
}

fn baseSourceDigest(source: []const u8, provenance: []const u8) [32]u8 {
    var result: [32]u8 = undefined;
    var digest = std.crypto.hash.sha2.Sha256.init(.{});
    digest.update(source);
    digest.update(&.{0});
    digest.update(provenance);
    digest.final(&result);
    return result;
}

fn sourceDigest(
    io: std.Io,
    allocator: std.mem.Allocator,
    source: []const u8,
    provenance: []const u8,
    output_key: *const content.BundleKey,
    root_translation: [3]f32,
    dependency_arguments: []const DependencyArgument,
    data: *cgltf.Data,
    resolver: *const SourceResolver,
) ![32]u8 {
    const dependency_source = try sourceDependencyDigest(
        allocator,
        baseSourceDigest(source, provenance),
        data,
        resolver,
    );
    const base = translatedSourceDigest(
        dependency_source,
        root_translation,
    );
    var dependencies: [max_dependencies]HashedDependency = undefined;
    for (dependency_arguments, 0..) |argument, index| {
        const dependency = try loadDependencyIdentity(io, allocator, argument);
        if (std.mem.eql(u8, dependency.bundle_key.bytes(), output_key.bytes())) {
            return error.DependencyReferencesOutputBundle;
        }
        for (dependencies[0..index]) |*existing| {
            if (std.mem.eql(u8, existing.bundle_key.bytes(), dependency.bundle_key.bytes())) {
                return error.DuplicateDependencyBundleKey;
            }
        }
        dependencies[index] = dependency;
    }
    return deriveDependentSourceDigest(base, dependencies[0..dependency_arguments.len]);
}

fn translatedSourceDigest(base: [32]u8, translation: [3]f32) [32]u8 {
    var digest = std.crypto.hash.sha2.Sha256.init(.{});
    digest.update(root_translation_digest_domain);
    digest.update(&base);
    for (translation) |component| {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, @bitCast(component), .little);
        digest.update(&bytes);
    }
    var result: [32]u8 = undefined;
    digest.final(&result);
    return result;
}

fn loadDependencyIdentity(
    io: std.Io,
    allocator: std.mem.Allocator,
    argument: DependencyArgument,
) !HashedDependency {
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        io,
        argument.bundle_path,
        allocator,
        .limited((bundle.Limits{}).max_file_bytes),
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.DependencyBundleReadFailed,
    };
    defer allocator.free(bytes);

    var scene = switch (try bundle.decode(allocator, bytes, .{})) {
        .bundle => |value| value,
        .failed => return error.DependencyBundleInvalid,
    };
    defer scene.deinit();
    const identity = scene.bundleIdentity();
    const key = content.BundleKey.parse(identity.name) catch
        return error.DependencyBundleKeyInvalid;
    const canonical_identity = identity.canonicalFingerprint() catch
        return error.DependencyBundleIdentityInvalid;
    return .{
        .semantic_id = argument.semantic_id,
        .bundle_key = key,
        .canonical_identity = canonical_identity,
    };
}

fn deriveDependentSourceDigest(
    base: [32]u8,
    dependencies: []const HashedDependency,
) [32]u8 {
    var digest = std.crypto.hash.sha2.Sha256.init(.{});
    digest.update(dependency_digest_domain);
    digest.update(&base);
    hashU16(&digest, @intCast(dependencies.len));
    for (dependencies) |dependency| {
        hashU16(&digest, @intCast(dependency.semantic_id.len));
        digest.update(dependency.semantic_id);
        digest.update(&dependency.canonical_identity);
    }
    var result: [32]u8 = undefined;
    digest.final(&result);
    return result;
}

const SourceResolver = struct {
    io: std.Io,
    dir: std.Io.Dir,

    fn open(io: std.Io, source_path: []const u8) !SourceResolver {
        const directory_path = std.fs.path.dirname(source_path) orelse ".";
        return .{ .io = io, .dir = if (std.fs.path.isAbsolute(directory_path))
            try std.Io.Dir.openDirAbsolute(io, directory_path, .{})
        else
            try std.Io.Dir.cwd().openDir(io, directory_path, .{}) };
    }

    fn deinit(self: *SourceResolver, io: std.Io) void {
        self.dir.close(io);
        self.* = undefined;
    }

    fn read(
        self: *const SourceResolver,
        allocator: std.mem.Allocator,
        uri: []const u8,
    ) ![]u8 {
        try validateRelativeDependencyUri(uri);
        var file = try self.dir.openFile(self.io, uri, .{
            .allow_directory = false,
            .follow_symlinks = true,
            .resolve_beneath = true,
        });
        defer file.close(self.io);
        const length = try file.length(self.io);
        if (length > max_image_source_bytes) return error.ImageSourceTooLarge;
        var read_buffer: [4096]u8 = undefined;
        var reader = file.reader(self.io, &read_buffer);
        return try reader.interface.readAlloc(allocator, @intCast(length));
    }
};

fn validateRelativeDependencyUri(uri: []const u8) !void {
    if (uri.len == 0 or std.fs.path.isAbsolute(uri) or
        std.mem.indexOfScalar(u8, uri, 0) != null or
        std.mem.indexOfAny(u8, uri, "\\?#%") != null or
        std.mem.indexOfScalar(u8, uri, ':') != null)
    {
        return error.InvalidSourceDependencyUri;
    }
    var components = std.mem.splitScalar(u8, uri, '/');
    while (components.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".") or
            std.mem.eql(u8, component, ".."))
        {
            return error.InvalidSourceDependencyUri;
        }
    }
}

fn sourceDependencyDigest(
    allocator: std.mem.Allocator,
    base: [32]u8,
    data: *cgltf.Data,
    resolver: *const SourceResolver,
) ![32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("incinerator.gltf.source.dependencies.v1");
    hash.update(&base);
    const images = if (data.images_count == 0)
        &[_]cgltf.Image{}
    else
        (data.images orelse return error.InvalidImageTable)[0..data.images_count];
    var external_count: u32 = 0;
    for (images) |image| {
        const uri = if (image.uri) |raw| cString(raw) else continue;
        if (std.mem.startsWith(u8, uri, "data:")) continue;
        const bytes = try resolver.read(allocator, uri);
        defer allocator.free(bytes);
        external_count += 1;
        hashU32(&hash, @intCast(uri.len));
        hash.update(uri);
        hashU64(&hash, bytes.len);
        hash.update(bytes);
    }
    hashU32(&hash, external_count);
    var result: [32]u8 = undefined;
    hash.final(&result);
    return result;
}

fn hashU16(hash: *std.crypto.hash.sha2.Sha256, value: u16) void {
    var bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &bytes, value, .little);
    hash.update(&bytes);
}

fn hashU32(hash: *std.crypto.hash.sha2.Sha256, value: u32) void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    hash.update(&bytes);
}

fn hashU64(hash: *std.crypto.hash.sha2.Sha256, value: u64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    hash.update(&bytes);
}

fn requireSafeBoundedBuffers(data: *cgltf.Data) !void {
    if (data.buffers_count == 0) return error.SourceBufferRequired;
    const buffers = data.buffers orelse return error.SourceBufferRequired;
    var total_bytes: usize = 0;
    for (buffers[0..data.buffers_count]) |buffer| {
        if (buffer.uri) |raw_uri| {
            const uri = cString(raw_uri);
            if (!std.mem.startsWith(u8, uri, "data:")) {
                // External binary buffers remain unsupported in EA1-A. Image
                // dependencies are admitted through a resolve-beneath root;
                // GLB BIN chunks and data URIs cover the measured mesh cohort.
                return error.ExternalBufferUnsupported;
            }
        } else if (data.file_type != .glb) {
            return error.EmbeddedBufferRequired;
        }
        total_bytes = std.math.add(usize, total_bytes, buffer.size) catch
            return error.SourceCapacityExceeded;
        if (total_bytes > max_source_bytes) return error.SourceCapacityExceeded;
    }
}

const Cooked = struct {
    allocator: std.mem.Allocator,
    bundle_name: bundle.NameRef,
    source_digest: [32]u8,
    source_format: bundle.SourceFormat,
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
    navigation_nodes: std.ArrayListUnmanaged(bundle.NavigationNode),
    navigation_edges: std.ArrayListUnmanaged(bundle.NavigationEdge),

    fn init(allocator: std.mem.Allocator, source_digest: [32]u8) Cooked {
        return .{
            .allocator = allocator,
            .bundle_name = undefined,
            .source_digest = source_digest,
            .source_format = .gltf,
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
            .navigation_nodes = .empty,
            .navigation_edges = .empty,
        };
    }

    fn view(self: *const Cooked) bundle.BundleView {
        return .{
            .bundle_name = self.bundle_name,
            .source_digest = self.source_digest,
            .source_format = self.source_format,
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
            .navigation_nodes = self.navigation_nodes.items,
            .navigation_edges = self.navigation_edges.items,
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
        self.navigation_edges.deinit(self.allocator);
        self.navigation_nodes.deinit(self.allocator);
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
    resolver: *const SourceResolver,
    bundle_name: []const u8,
    coord: district_contract.ChunkCoord,
    root_translation: [3]f32,
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
    result.source_format = switch (data.file_type) {
        .gltf => .gltf,
        .glb => .glb,
        else => return error.UnsupportedSourceContainer,
    };

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
    for (result.nodes.items) |*node| {
        if (node.parent != bundle.none_index) continue;
        inline for (0..3) |axis| {
            node.local_transform[12 + axis] += root_translation[axis];
            if (!std.math.isFinite(node.local_transform[12 + axis])) {
                return error.InvalidTranslatedRootTransform;
            }
        }
    }

    const meshes = data.meshes orelse return error.SceneContainsNoMeshes;
    for (meshes[0..data.meshes_count]) |*mesh| try appendMesh(&result, data, mesh);
    const materials = data.materials orelse return error.SceneContainsNoMaterials;
    for (materials[0..data.materials_count]) |*material| try appendMaterial(&result, data, material);
    if (data.textures_count != 0) {
        const textures = data.textures orelse return error.InvalidTextureTable;
        for (textures[0..data.textures_count]) |*texture| {
            try appendTexture(&result, resolver, texture);
        }
    }

    const logical = switch (sandbox_recipe.build(
        coord,
        sandbox_recipe.current_recipe_version,
    )) {
        .ready => |build| build,
        .failed => return error.DistrictRecipeFailed,
    };
    try logical.validate();
    for (logical.boxes()) |box| {
        try result.static_boxes.append(allocator, .{
            .position = box.pose.position,
            .rotation = box.pose.rotation,
            .half_extents = box.half_extents,
        });
    }
    // Navigation is authoritative logical recipe data. It is intentionally
    // not inferred from artist-authored glTF so headless simulation and cooked
    // presentation consume the same deterministic graph fragment.
    for (logical.navigationNodes()) |node| {
        try result.navigation_nodes.append(allocator, .{
            .position = node.position,
            .first_edge = node.first_edge,
            .edge_count = node.edge_count,
            .flags = node.flags,
            .reserved = node.reserved,
        });
    }
    for (logical.navigationEdges()) |edge| {
        try result.navigation_edges.append(allocator, .{
            .target_coord = .{ edge.target.coord.x, edge.target.coord.z },
            .target_node = edge.target.index,
            .flags = edge.flags,
            .cost = edge.cost,
        });
    }
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
    if (pbr.metallic_roughness_texture.texture != null) {
        return error.UnsupportedMaterialFeature;
    }
    if ((pbr.base_color_texture.texture != null and pbr.base_color_texture.texcoord != 0) or
        pbr.base_color_texture.has_transform != 0 or
        pbr.metallic_factor != 0 or pbr.roughness_factor != 1)
    {
        return error.UnsupportedMaterialFeature;
    }
    try cooked.materials.append(cooked.allocator, .{
        .name = try cooked.addName(cString(material.name orelse return error.MaterialNameRequired)),
        .base_color = pbr.base_color_factor,
        .base_color_texture = if (pbr.base_color_texture.texture) |texture|
            try pointerIndex(cgltf.Texture, data.textures.?, data.textures_count, texture)
        else
            bundle.none_index,
        .base_color_texcoord = @intCast(pbr.base_color_texture.texcoord),
    });
}

fn appendTexture(
    cooked: *Cooked,
    resolver: *const SourceResolver,
    texture: *cgltf.Texture,
) !void {
    if (texture.extensions_count != 0 or texture.has_basisu != 0 or texture.has_webp != 0) {
        return error.UnsupportedTextureFeature;
    }
    const image = texture.image orelse return error.TextureImageRequired;
    if (image.extensions_count != 0) return error.UnsupportedImageFeature;
    const sampler = try samplerState(texture.sampler);

    var owned_encoded: ?[]u8 = null;
    defer if (owned_encoded) |bytes| cooked.allocator.free(bytes);
    const encoded: []const u8 = if (image.buffer_view) |view| blk: {
        if (image.uri != null) return error.AmbiguousImageSource;
        const encoded_ptr = view.getData() orelse return error.ImageBufferUnavailable;
        break :blk encoded_ptr[0..view.size];
    } else if (image.uri) |raw_uri| blk: {
        const uri = cString(raw_uri);
        owned_encoded = if (std.mem.startsWith(u8, uri, "data:"))
            try decodeDataUri(cooked.allocator, uri)
        else
            try resolver.read(cooked.allocator, uri);
        break :blk owned_encoded.?;
    } else return error.ImageSourceRequired;

    const encoding = try imageEncoding(image, encoded);
    const declared_dimensions = try encodedDimensions(encoding, encoded);
    const declared_pixels = std.math.mul(
        u32,
        declared_dimensions[0],
        declared_dimensions[1],
    ) catch return error.ImageTooLarge;
    const declared_bytes = std.math.mul(u32, declared_pixels, 4) catch
        return error.ImageTooLarge;
    const limits = bundle.Limits{};
    if (declared_dimensions[0] == 0 or declared_dimensions[1] == 0 or
        declared_bytes > limits.max_pixel_bytes)
    {
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
        .encoding = encoding,
        .sampler = sampler,
    });
}

fn samplerState(source: ?*cgltf.Sampler) !bundle.Sampler {
    const sampler = source orelse return .{};
    if (sampler.extensions_count != 0) return error.UnsupportedTextureSampler;
    return .{
        .min_filter = switch (sampler.min_filter) {
            .undefined, .linear, .linear_mipmap_nearest, .linear_mipmap_linear => .linear,
            .nearest, .nearest_mipmap_nearest, .nearest_mipmap_linear => .nearest,
        },
        .mag_filter = switch (sampler.mag_filter) {
            .undefined, .linear => .linear,
            .nearest => .nearest,
            else => return error.UnsupportedTextureSampler,
        },
        .address_u = switch (sampler.wrap_s) {
            .clamp_to_edge => .clamp_to_edge,
            .mirrored_repeat => .mirrored_repeat,
            .repeat => .repeat,
        },
        .address_v = switch (sampler.wrap_t) {
            .clamp_to_edge => .clamp_to_edge,
            .mirrored_repeat => .mirrored_repeat,
            .repeat => .repeat,
        },
    };
}

fn imageEncoding(image: *const cgltf.Image, encoded: []const u8) !bundle.ImageEncoding {
    const detected: bundle.ImageEncoding = if (encoded.len >= 24 and
        std.mem.eql(u8, encoded[0..8], "\x89PNG\r\n\x1a\n"))
        .png
    else if (encoded.len >= 4 and encoded[0] == 0xff and encoded[1] == 0xd8 and
        encoded[2] == 0xff)
        .jpeg
    else
        return error.UnsupportedImageEncoding;
    if (image.mime_type) |raw| {
        const mime = cString(raw);
        const matches = switch (detected) {
            .png => std.mem.eql(u8, mime, "image/png"),
            .jpeg => std.mem.eql(u8, mime, "image/jpeg"),
            else => false,
        };
        if (!matches) return error.ImageMimeTypeMismatch;
    }
    return detected;
}

fn encodedDimensions(encoding: bundle.ImageEncoding, encoded: []const u8) ![2]u32 {
    return switch (encoding) {
        .png => .{
            std.mem.readInt(u32, encoded[16..20], .big),
            std.mem.readInt(u32, encoded[20..24], .big),
        },
        .jpeg => jpegDimensions(encoded),
        else => error.UnsupportedImageEncoding,
    };
}

fn jpegDimensions(encoded: []const u8) ![2]u32 {
    if (encoded.len < 4 or encoded[0] != 0xff or encoded[1] != 0xd8) {
        return error.InvalidJpegHeader;
    }
    var cursor: usize = 2;
    while (cursor + 4 <= encoded.len) {
        while (cursor < encoded.len and encoded[cursor] == 0xff) cursor += 1;
        if (cursor >= encoded.len) break;
        const marker = encoded[cursor];
        cursor += 1;
        if (marker == 0xd8 or marker == 0xd9 or (marker >= 0xd0 and marker <= 0xd7)) {
            continue;
        }
        if (cursor + 2 > encoded.len) break;
        const segment_length = std.mem.readInt(u16, encoded[cursor..][0..2], .big);
        if (segment_length < 2) return error.InvalidJpegHeader;
        const segment_end = std.math.add(usize, cursor, segment_length) catch
            return error.InvalidJpegHeader;
        if (segment_end > encoded.len) return error.InvalidJpegHeader;
        const start_of_frame = (marker >= 0xc0 and marker <= 0xc3) or
            (marker >= 0xc5 and marker <= 0xc7) or
            (marker >= 0xc9 and marker <= 0xcb) or
            (marker >= 0xcd and marker <= 0xcf);
        if (start_of_frame) {
            if (segment_length < 7) return error.InvalidJpegHeader;
            return .{
                std.mem.readInt(u16, encoded[cursor + 5 ..][0..2], .big),
                std.mem.readInt(u16, encoded[cursor + 3 ..][0..2], .big),
            };
        }
        cursor = segment_end;
    }
    return error.JpegDimensionsMissing;
}

fn decodeDataUri(allocator: std.mem.Allocator, uri: []const u8) ![]u8 {
    const comma = std.mem.indexOfScalar(u8, uri, ',') orelse return error.InvalidImageDataUri;
    const metadata = uri[0..comma];
    if ((!std.mem.eql(u8, metadata, "data:image/png;base64") and
        !std.mem.eql(u8, metadata, "data:image/jpeg;base64")) or
        comma + 1 == uri.len)
    {
        return error.InvalidImageDataUri;
    }
    const payload = uri[comma + 1 ..];
    const decoded_size = std.base64.standard.Decoder.calcSizeForSlice(payload) catch
        return error.InvalidImageDataUri;
    if (decoded_size > max_image_source_bytes) return error.ImageSourceTooLarge;
    const decoded = try allocator.alloc(u8, decoded_size);
    errdefer allocator.free(decoded);
    std.base64.standard.Decoder.decode(decoded, payload) catch
        return error.InvalidImageDataUri;
    return decoded;
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
    try std.testing.expectError(error.ExternalBufferUnsupported, requireSafeBoundedBuffers(data));
}

test "cooker invocation parses coordinates and strictly sorted dependency pairs" {
    const args = [_][]const u8{
        "incinerator_content_cooker",
        "district.gltf",
        "PROVENANCE.md",
        "district.icdb",
        "district/s6_east",
        "1",
        "-2",
        "0",
        "0",
        "16",
        "sandbox.foundation",
        "foundation.icdb",
        "sandbox.west",
        "west.icdb",
    };
    const invocation = try parseInvocation(args);
    try std.testing.expectEqual(@as(i32, 1), invocation.coord.x);
    try std.testing.expectEqual(@as(i32, -2), invocation.coord.z);
    try std.testing.expectEqualDeep([3]f32{ 0, 0, 16 }, invocation.root_translation);
    try std.testing.expectEqualStrings("district/s6_east", invocation.key.bytes());
    try std.testing.expectEqual(@as(usize, 2), invocation.dependencySlice().len);
    try std.testing.expectEqualStrings(
        "sandbox.foundation",
        invocation.dependencySlice()[0].semantic_id,
    );
    try std.testing.expectEqualStrings(
        "foundation.icdb",
        invocation.dependencySlice()[0].bundle_path,
    );

    const no_dependencies = [_][]const u8{
        "incinerator_content_cooker",
        "district.gltf",
        "PROVENANCE.md",
        "district.icdb",
        "district/s3_fixture",
        "0",
        "0",
        "0",
        "0",
        "0",
    };
    const dependency_free = try parseInvocation(no_dependencies);
    try std.testing.expectEqual(@as(usize, 0), dependency_free.dependencySlice().len);
}

test "cooker invocation records declared rooted image dependencies separately" {
    const args = [_][]const u8{
        "incinerator_content_cooker",
        "cargo.gltf",
        "PROVENANCE.md",
        "cargo.icdb",
        "district/cargo",
        "1",
        "0",
        "0",
        "0",
        "0",
        "--source-dependency",
        "/project/assets/panels.jpg",
        "district.west",
        "west.icdb",
    };
    const invocation = try parseInvocation(args);
    try std.testing.expectEqual(@as(usize, 1), invocation.sourceDependencySlice().len);
    try std.testing.expectEqualStrings(
        "/project/assets/panels.jpg",
        invocation.sourceDependencySlice()[0],
    );
    try std.testing.expectEqual(@as(usize, 1), invocation.dependencySlice().len);
}

test "rooted dependency URI validation rejects traversal absolute query and fragments" {
    try validateRelativeDependencyUri("textures/panels.jpg");
    try std.testing.expectError(error.InvalidSourceDependencyUri, validateRelativeDependencyUri("../panels.jpg"));
    try std.testing.expectError(error.InvalidSourceDependencyUri, validateRelativeDependencyUri("/tmp/panels.jpg"));
    try std.testing.expectError(error.InvalidSourceDependencyUri, validateRelativeDependencyUri("panels.jpg?x=1"));
    try std.testing.expectError(error.InvalidSourceDependencyUri, validateRelativeDependencyUri("panels.jpg#x"));
}

test "cooker invocation rejects malformed unsorted duplicate and invalid dependencies" {
    const missing_path = [_][]const u8{
        "cooker",
        "district.gltf",
        "PROVENANCE.md",
        "district.icdb",
        "district/s6_east",
        "1",
        "0",
        "0",
        "sandbox.west",
    };
    try std.testing.expectError(
        error.ExpectedInputProvenanceOutputKeyCoordinateTranslationAndDependencies,
        parseInvocation(missing_path),
    );

    const unsorted = [_][]const u8{
        "cooker",
        "district.gltf",
        "PROVENANCE.md",
        "district.icdb",
        "district/s6_east",
        "1",
        "0",
        "0",
        "0",
        "0",
        "sandbox.west",
        "west.icdb",
        "sandbox.foundation",
        "foundation.icdb",
    };
    try std.testing.expectError(
        error.UnsortedDependencySemanticIds,
        parseInvocation(unsorted),
    );

    const duplicate = [_][]const u8{
        "cooker",
        "district.gltf",
        "PROVENANCE.md",
        "district.icdb",
        "district/s6_east",
        "1",
        "0",
        "0",
        "0",
        "0",
        "sandbox.west",
        "west.icdb",
        "sandbox.west",
        "west-again.icdb",
    };
    try std.testing.expectError(
        error.DuplicateDependencySemanticId,
        parseInvocation(duplicate),
    );

    const invalid = [_][]const u8{
        "cooker",
        "district.gltf",
        "PROVENANCE.md",
        "district.icdb",
        "district/s6_east",
        "east",
        "0",
        "0",
        "0",
        "0",
        "Sandbox.West",
        "west.icdb",
    };
    try std.testing.expectError(error.InvalidDistrictCoordinate, parseInvocation(invalid));

    const invalid_id = [_][]const u8{
        "cooker",
        "district.gltf",
        "PROVENANCE.md",
        "district.icdb",
        "district/s6_east",
        "1",
        "0",
        "0",
        "0",
        "0",
        "Sandbox.West",
        "west.icdb",
    };
    try std.testing.expectError(error.InvalidDependencySemanticId, parseInvocation(invalid_id));
}

test "source digest frames dependency count and identities deterministically" {
    const base = baseSourceDigest("source bytes", "provenance bytes");
    const no_dependencies = deriveDependentSourceDigest(base, &.{});
    try std.testing.expect(!std.mem.eql(u8, &base, &no_dependencies));

    const dependencies = [_]HashedDependency{
        .{
            .semantic_id = "sandbox.foundation",
            .bundle_key = try content.BundleKey.parse("district/foundation"),
            .canonical_identity = @splat(0x11),
        },
        .{
            .semantic_id = "sandbox.west",
            .bundle_key = try content.BundleKey.parse("district/s3_fixture"),
            .canonical_identity = @splat(0x22),
        },
    };
    const first = deriveDependentSourceDigest(base, &dependencies);
    const repeated = deriveDependentSourceDigest(base, &dependencies);
    try std.testing.expectEqualSlices(u8, &first, &repeated);
    try std.testing.expect(!std.mem.eql(u8, &base, &first));

    var renamed = dependencies;
    renamed[1].semantic_id = "sandbox.west-renamed";
    const renamed_digest = deriveDependentSourceDigest(base, &renamed);
    try std.testing.expect(!std.mem.eql(u8, &first, &renamed_digest));

    var changed_identity = dependencies;
    changed_identity[1].canonical_identity[0] ^= 1;
    const changed_digest = deriveDependentSourceDigest(base, &changed_identity);
    try std.testing.expect(!std.mem.eql(u8, &first, &changed_digest));
}

test "root translation participates in source identity" {
    const base = baseSourceDigest("source bytes", "provenance bytes");
    const origin = translatedSourceDigest(base, .{ 0, 0, 0 });
    const north = translatedSourceDigest(base, .{ 0, 0, 16 });
    const repeated = translatedSourceDigest(base, .{ 0, 0, 16 });
    try std.testing.expect(!std.mem.eql(u8, &origin, &north));
    try std.testing.expectEqualSlices(u8, &north, &repeated);
}
