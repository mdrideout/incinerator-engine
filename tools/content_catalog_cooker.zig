//! Offline canonical district-catalog cooker.

const std = @import("std");
const content = @import("content");
const district_contract = @import("district_contract");
const sandbox_recipe = @import("sandbox_district_recipe");

const max_spec_bytes = 16 * 1024;
const max_input_bundles = content.catalog.max_entries;
const spec_magic = "incinerator-district-catalog-v1";
const source_digest_domain = "incinerator.catalog.source.v1";

const ParsedEntry = struct {
    coord: content.catalog.ChunkCoord,
    semantic_id: []const u8,
    bundle_key: []const u8,
    dependency_storage: [content.catalog.max_dependencies_per_entry][]const u8 = undefined,
    dependency_count: u8 = 0,

    fn dependencies(self: *const ParsedEntry) []const []const u8 {
        return self.dependency_storage[0..self.dependency_count];
    }
};

const ParsedSpec = struct {
    name: []const u8,
    entries: [content.catalog.max_entries]ParsedEntry = undefined,
    entry_count: u8 = 0,

    fn entrySlice(self: *const ParsedSpec) []const ParsedEntry {
        return self.entries[0..self.entry_count];
    }
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 4 or args.len - 3 > max_input_bundles) {
        return error.ExpectedSpecOutputAndBundles;
    }
    const allocator = init.gpa;
    const spec_bytes = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        args[1],
        allocator,
        .limited(max_spec_bytes),
    );
    defer allocator.free(spec_bytes);
    const parsed = try parseSpec(spec_bytes);

    const scenes = try allocator.alloc(content.bundle.OwnedBundle, args.len - 3);
    defer allocator.free(scenes);
    var scene_count: usize = 0;
    defer for (scenes[0..scene_count]) |*scene| scene.deinit();
    for (args[3..]) |path| {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(
            init.io,
            path,
            allocator,
            .limited((content.bundle.Limits{}).max_file_bytes),
        );
        defer allocator.free(bytes);
        scenes[scene_count] = switch (try content.bundle.decode(allocator, bytes, .{})) {
            .bundle => |scene| scene,
            .failed => return error.InvalidInputBundle,
        };
        scene_count += 1;
    }

    const declarations = try allocator.alloc(
        content.catalog.EntryDeclaration,
        parsed.entry_count,
    );
    defer allocator.free(declarations);
    var logical_builds: [content.catalog.max_entries]district_contract.DistrictBuild = undefined;
    var matched = [_]bool{false} ** max_input_bundles;
    for (parsed.entrySlice(), 0..) |*entry, entry_index| {
        var matched_index: ?usize = null;
        for (scenes[0..scene_count], 0..) |*scene, scene_index| {
            const identity = scene.bundleIdentity();
            if (!std.mem.eql(u8, identity.name, entry.bundle_key)) continue;
            if (matched_index != null) return error.DuplicateInputBundleKey;
            matched_index = scene_index;
        }
        const scene_index = matched_index orelse return error.MissingInputBundle;
        if (matched[scene_index]) return error.DuplicateCatalogBundleKey;
        matched[scene_index] = true;
        const scene = &scenes[scene_index];
        const build = switch (sandbox_recipe.build(
            .{ .x = entry.coord.x, .z = entry.coord.z },
            sandbox_recipe.current_recipe_version,
        )) {
            .ready => |value| value,
            .failed => return error.InvalidDistrictRecipe,
        };
        logical_builds[entry_index] = build;
        try validateLogicalScene(scene.view(), &build);
        const identity = scene.bundleIdentity();
        declarations[entry_index] = .{
            .coord = entry.coord,
            .semantic_id = entry.semantic_id,
            .bundle_key = entry.bundle_key,
            .recipe_version = build.recipe_version,
            .logical_checksum = build.checksum,
            .bundle = .{
                .format_version = identity.format_version,
                .schema_cohort = identity.schema_cohort,
                .source_digest = identity.source_digest,
                .integrity_digest = identity.integrity_digest,
            },
            .dependencies = entry.dependencies(),
        };
    }
    for (matched[0..scene_count]) |was_matched| {
        if (!was_matched) return error.UnreferencedInputBundle;
    }
    try validateLogicalRoute(logical_builds[0..parsed.entry_count]);

    const encoded = switch (try content.catalog.encode(allocator, .{
        .name = parsed.name,
        .source_digest = sourceDigest(spec_bytes),
        .entries = declarations,
    }, .{})) {
        .bytes => |bytes| bytes,
        .failed => return error.CatalogDeclarationInvalid,
    };
    defer allocator.free(encoded);
    try writeAtomic(init.io, args[2], encoded);
}

fn parseSpec(bytes: []const u8) !ParsedSpec {
    if (bytes.len == 0 or !std.unicode.utf8ValidateSlice(bytes)) {
        return error.InvalidCatalogSpec;
    }
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    if (!std.mem.eql(u8, lines.next() orelse return error.InvalidCatalogSpec, spec_magic)) {
        return error.InvalidCatalogSpecMagic;
    }
    const catalog_line = lines.next() orelse return error.MissingCatalogDeclaration;
    var catalog_tokens = std.mem.tokenizeScalar(u8, catalog_line, ' ');
    if (!std.mem.eql(u8, catalog_tokens.next() orelse "", "catalog")) {
        return error.MissingCatalogDeclaration;
    }
    const name = catalog_tokens.next() orelse return error.MissingCatalogName;
    if (catalog_tokens.next() != null) return error.InvalidCatalogDeclaration;

    var result = ParsedSpec{ .name = name };
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (result.entry_count == result.entries.len) return error.TooManyCatalogEntries;
        var tokens = std.mem.tokenizeScalar(u8, line, ' ');
        if (!std.mem.eql(u8, tokens.next() orelse "", "entry")) {
            return error.InvalidCatalogEntry;
        }
        const semantic_id = tokens.next() orelse return error.InvalidCatalogEntry;
        const coord_x = std.fmt.parseInt(
            i32,
            tokens.next() orelse return error.InvalidCatalogEntry,
            10,
        ) catch return error.InvalidCatalogCoordinate;
        const coord_z = std.fmt.parseInt(
            i32,
            tokens.next() orelse return error.InvalidCatalogEntry,
            10,
        ) catch return error.InvalidCatalogCoordinate;
        const bundle_key = tokens.next() orelse return error.InvalidCatalogEntry;
        const dependency = tokens.next() orelse return error.InvalidCatalogEntry;
        if (tokens.next() != null) return error.InvalidCatalogEntry;
        const index: usize = result.entry_count;
        result.entries[index] = .{
            .coord = .{ .x = coord_x, .z = coord_z },
            .semantic_id = semantic_id,
            .bundle_key = bundle_key,
        };
        if (!std.mem.eql(u8, dependency, "-")) {
            result.entries[index].dependency_storage[0] = dependency;
            result.entries[index].dependency_count = 1;
        }
        result.entry_count += 1;
    }
    if (result.entry_count == 0) return error.EmptyCatalogSpec;
    return result;
}

fn sourceDigest(bytes: []const u8) content.catalog.Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(source_digest_domain);
    var size: [8]u8 = undefined;
    std.mem.writeInt(u64, &size, bytes.len, .little);
    hash.update(&size);
    hash.update(bytes);
    var result: content.catalog.Digest = undefined;
    hash.final(&result);
    return result;
}

fn validateLogicalScene(
    view: content.bundle.BundleView,
    build: *const district_contract.DistrictBuild,
) !void {
    if (!sandbox_recipe.logicalShapeMatches(view, build))
        return error.CookedDistrictLogicalShapeMismatch;
}

fn validateLogicalRoute(builds: []const district_contract.DistrictBuild) !void {
    if (sandbox_recipe.routeValidationFailure(builds) != null)
        return error.CookedDistrictLogicalRouteMismatch;
}

fn writeAtomic(io: std.Io, output_path: []const u8, bytes: []const u8) !void {
    const directory_path = std.fs.path.dirname(output_path) orelse
        return error.OutputDirectoryRequired;
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

test "catalog spec parser preserves canonical adjacent declaration" {
    const source =
        \\incinerator-district-catalog-v1
        \\catalog district.catalog
        \\entry district.east 1 0 district/s6_east district.west
        \\entry district.west 0 0 district/s3_fixture -
        \\
    ;
    const parsed = try parseSpec(source);
    try std.testing.expectEqualStrings("district.catalog", parsed.name);
    try std.testing.expectEqual(@as(usize, 2), parsed.entrySlice().len);
    try std.testing.expectEqualStrings("district.east", parsed.entries[0].semantic_id);
    try std.testing.expectEqual(@as(i32, 1), parsed.entries[0].coord.x);
    try std.testing.expectEqualStrings(
        "district.west",
        parsed.entries[0].dependencies()[0],
    );
    try std.testing.expectEqual(@as(usize, 0), parsed.entries[1].dependencies().len);
}

test "catalog source digest is deterministic and domain separated" {
    const first = sourceDigest("catalog\n");
    const repeated = sourceDigest("catalog\n");
    const changed = sourceDigest("catalog!\n");
    try std.testing.expectEqual(first, repeated);
    try std.testing.expect(!std.mem.eql(u8, &first, &changed));
}

test "catalog cooker rejects complete logical navigation mismatch" {
    const build = sandbox_recipe.build(
        sandbox_recipe.navigation_west_coord,
        sandbox_recipe.current_recipe_version,
    ).ready;
    var boxes: [district_contract.max_static_boxes]content.bundle.StaticBox = undefined;
    for (build.boxes(), 0..) |box, index| {
        boxes[index] = .{
            .position = box.pose.position,
            .rotation = box.pose.rotation,
            .half_extents = box.half_extents,
        };
    }
    var nodes: [district_contract.max_navigation_nodes]content.bundle.NavigationNode = undefined;
    for (build.navigationNodes(), 0..) |node, index| {
        nodes[index] = .{
            .position = node.position,
            .first_edge = node.first_edge,
            .edge_count = node.edge_count,
            .flags = node.flags,
            .reserved = node.reserved,
        };
    }
    var edges: [district_contract.max_navigation_edges]content.bundle.NavigationEdge = undefined;
    for (build.navigationEdges(), 0..) |edge, index| {
        edges[index] = .{
            .target_coord = .{ edge.target.coord.x, edge.target.coord.z },
            .target_node = edge.target.index,
            .flags = edge.flags,
            .reserved = edge.reserved,
        };
    }
    var view = content.bundle.BundleView{
        .bundle_name = .{ .offset = 0, .len = 1 },
        .source_digest = [_]u8{1} ** 32,
        .strings = "x",
        .nodes = &.{},
        .meshes = &.{},
        .primitives = &.{},
        .materials = &.{},
        .textures = &.{},
        .vertices = &.{},
        .indices = &.{},
        .pixels = &.{},
        .static_boxes = boxes[0..build.static_box_count],
        .navigation_nodes = nodes[0..build.navigation_node_count],
        .navigation_edges = edges[0..build.navigation_edge_count],
    };
    try validateLogicalScene(view, &build);

    edges[4].target_node = 1;
    try std.testing.expectError(
        error.CookedDistrictLogicalShapeMismatch,
        validateLogicalScene(view, &build),
    );
    edges[4].target_node = 0;
    nodes[0].flags = 0;
    try std.testing.expectError(
        error.CookedDistrictLogicalShapeMismatch,
        validateLogicalScene(view, &build),
    );
    nodes[0].flags = content.bundle.navigation_node_terminal;
    view.navigation_edges = edges[0 .. build.navigation_edge_count - 1];
    try std.testing.expectError(
        error.CookedDistrictLogicalShapeMismatch,
        validateLogicalScene(view, &build),
    );
}

test "catalog cooker rejects an incomplete or wrong installed route" {
    const west = sandbox_recipe.build(
        sandbox_recipe.navigation_west_coord,
        sandbox_recipe.current_recipe_version,
    ).ready;
    const east = sandbox_recipe.build(
        sandbox_recipe.navigation_east_coord,
        sandbox_recipe.current_recipe_version,
    ).ready;
    try validateLogicalRoute(&.{ west, east });
    try std.testing.expectError(
        error.CookedDistrictLogicalRouteMismatch,
        validateLogicalRoute(&.{west}),
    );

    const uninstalled = sandbox_recipe.build(
        .{ .x = 2, .z = 0 },
        sandbox_recipe.current_recipe_version,
    ).ready;
    try std.testing.expectError(
        error.CookedDistrictLogicalRouteMismatch,
        validateLogicalRoute(&.{ west, uninstalled }),
    );
}
