//! Renderer-neutral admission boundary for the canonical district catalog.

const std = @import("std");
const engine = @import("incinerator_engine");
const content = @import("content");
const district_contract = @import("district_contract");
const sandbox_replay = @import("sandbox_replay");
const sandbox_recipe = @import("sandbox_district_recipe");

pub const ContentCohort = sandbox_replay.ContentCohort;

pub const EntryIssue = struct { entry_index: u32 };
pub const BundleLoadIssue = struct {
    entry_index: u32,
    failure: content.LoadFailure,
};
pub const BundleIdentityIssue = struct {
    entry_index: u32,
    mismatch: content.BundleIdentityMismatch,
};

pub const AdmissionFailure = union(enum) {
    catalog_load: content.CatalogLoadFailure,
    bundle_load: BundleLoadIssue,
    bundle_identity: BundleIdentityIssue,
    incompatible_recipe: EntryIssue,
    logical_checksum_mismatch: EntryIssue,
    logical_shape_mismatch: EntryIssue,
    navigation_route: sandbox_recipe.RouteValidationFailure,
};

pub const AdmissionResult = union(enum) {
    admitted: AdmittedCatalog,
    failed: AdmissionFailure,
};

/// Move-only by convention. The catalog owns every string and entry slice
/// returned by `view`; call `deinit` exactly once.
pub const AdmittedCatalog = struct {
    root_path: content.ContentRootPath,
    catalog: content.catalog.OwnedCatalog,
    assets: content.asset_catalog.OwnedCatalog,
    cohort: sandbox_replay.ContentCohort,

    pub fn deinit(self: *AdmittedCatalog) void {
        self.assets.deinit();
        self.catalog.deinit();
        self.* = undefined;
    }

    pub fn view(self: *const AdmittedCatalog) content.catalog.View {
        return self.catalog.view();
    }

    pub fn identity(self: *const AdmittedCatalog) content.catalog.Identity {
        return self.catalog.identity();
    }

    pub fn assetView(self: *const AdmittedCatalog) []const engine.assets.Entry {
        return self.assets.view();
    }

    pub fn contentCohort(self: *const AdmittedCatalog) ContentCohort {
        return self.cohort;
    }

    pub fn cohortFingerprint(self: *const AdmittedCatalog) !sandbox_replay.Digest {
        return self.cohort.fingerprint();
    }

    pub fn entryForCoordinate(
        self: *const AdmittedCatalog,
        coord: district_contract.ChunkCoord,
    ) ?content.catalog.EntryView {
        const catalog_view = self.view();
        const index = catalog_view.lookupCoordinate(.{ .x = coord.x, .z = coord.z }) orelse
            return null;
        return catalog_view.entries[index];
    }

    pub fn sceneRequest(
        self: *const AdmittedCatalog,
        coord: district_contract.ChunkCoord,
        generation: u64,
    ) !content.SceneRequest {
        if (generation == 0) return error.InvalidSceneGeneration;
        const entry = self.entryForCoordinate(coord) orelse
            return error.DistrictCoordinateNotInCatalog;
        return .{
            .generation = generation,
            .content_root = self.root_path,
            .key = try content.BundleKey.parse(entry.bundle_key),
            .expected_identity = .{
                .format_version = entry.bundle.format_version,
                .schema_cohort = entry.bundle.schema_cohort,
                .source_digest = entry.bundle.source_digest,
                .integrity_digest = entry.bundle.integrity_digest,
            },
        };
    }

    pub fn validateLogicalRecord(
        self: *const AdmittedCatalog,
        coord: district_contract.ChunkCoord,
        recipe_version: u32,
        logical_checksum: u64,
    ) !void {
        const entry = self.entryForCoordinate(coord) orelse
            return error.DistrictCoordinateNotInCatalog;
        if (entry.recipe_version != recipe_version) {
            return error.DistrictCatalogRecipeMismatch;
        }
        if (entry.logical_checksum != logical_checksum) {
            return error.DistrictCatalogChecksumMismatch;
        }
    }

    pub fn validateLogicalRecords(self: *const AdmittedCatalog, records: anytype) !void {
        for (records, 0..) |record, index| {
            for (records[0..index]) |earlier| {
                if (district_contract.ChunkCoord.eql(earlier.coord, record.coord)) {
                    return error.DuplicateDistrictCoordinate;
                }
            }
            try self.validateLogicalRecord(
                record.coord,
                record.recipe_version,
                record.checksum,
            );
        }
    }
};

pub fn admit(
    io: std.Io,
    allocator: std.mem.Allocator,
    root_path: content.ContentRootPath,
) !AdmissionResult {
    var root = try content.ContentRoot.open(io, root_path);
    defer root.deinit(io);
    var catalog = switch (try root.loadCatalog(io, allocator, .{})) {
        .loaded => |value| value,
        .failed => |failure| return .{ .failed = .{ .catalog_load = failure } },
    };
    var catalog_owned = true;
    defer if (catalog_owned) catalog.deinit();

    const catalog_view = catalog.view();
    if (catalog_view.entries.len != sandbox_recipe.installed_coords.len) {
        return .{ .failed = .{ .navigation_route = .wrong_build_count } };
    }
    var logical_builds: [sandbox_recipe.installed_coords.len]district_contract.DistrictBuild =
        undefined;
    var asset_builder = content.asset_catalog.Builder.init(allocator);
    defer asset_builder.deinit();
    for (catalog_view.entries, 0..) |entry, entry_index| {
        if (entry.recipe_version != sandbox_recipe.current_recipe_version) {
            return .{ .failed = .{ .incompatible_recipe = .{
                .entry_index = @intCast(entry_index),
            } } };
        }
        const build = switch (sandbox_recipe.build(
            .{ .x = entry.coord.x, .z = entry.coord.z },
            entry.recipe_version,
        )) {
            .ready => |value| value,
            .failed => return .{ .failed = .{ .incompatible_recipe = .{
                .entry_index = @intCast(entry_index),
            } } },
        };
        if (build.checksum != entry.logical_checksum) {
            return .{ .failed = .{ .logical_checksum_mismatch = .{
                .entry_index = @intCast(entry_index),
            } } };
        }
        logical_builds[entry_index] = build;

        var loaded = try root.load(
            io,
            allocator,
            try content.BundleKey.parse(entry.bundle_key),
            .{},
        );
        switch (loaded) {
            .failed => |failure| return .{ .failed = .{ .bundle_load = .{
                .entry_index = @intCast(entry_index),
                .failure = failure,
            } } },
            .scene => |*scene| {
                defer scene.deinit();
                const expected = content.ExpectedBundleIdentity{
                    .format_version = entry.bundle.format_version,
                    .schema_cohort = entry.bundle.schema_cohort,
                    .source_digest = entry.bundle.source_digest,
                    .integrity_digest = entry.bundle.integrity_digest,
                };
                if (expected.mismatch(scene.bundleIdentity())) |mismatch| {
                    return .{ .failed = .{ .bundle_identity = .{
                        .entry_index = @intCast(entry_index),
                        .mismatch = mismatch,
                    } } };
                }
                if (!sandbox_recipe.logicalShapeMatches(scene.view(), &build)) {
                    return .{ .failed = .{ .logical_shape_mismatch = .{
                        .entry_index = @intCast(entry_index),
                    } } };
                }
                try asset_builder.appendBundle(entry.semantic_id, scene);
            },
        }
    }
    if (sandbox_recipe.routeValidationFailure(&logical_builds)) |failure| {
        return .{ .failed = .{ .navigation_route = failure } };
    }

    const identity = catalog.identity();
    const cohort = try sandbox_replay.ContentCohort.init(
        identity.name,
        identity.format_version,
        identity.schema_cohort,
        sandbox_recipe.current_recipe_version,
        identity.source_digest,
        identity.integrity_digest,
    );
    var assets = try asset_builder.finish();
    errdefer assets.deinit();
    catalog_owned = false;
    return .{ .admitted = .{
        .root_path = root_path,
        .catalog = catalog,
        .assets = assets,
        .cohort = cohort,
    } };
}

test "admitted catalog type is renderer and backend neutral" {
    comptime {
        std.testing.refAllDecls(@This());
        if (@hasDecl(AdmittedCatalog, "renderer") or @hasDecl(AdmittedCatalog, "physics")) {
            @compileError("content admission must not own presentation or physics");
        }
    }
}

test "catalog shape admission compares the complete logical navigation fragment" {
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
            .cost = edge.cost,
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
    try std.testing.expect(sandbox_recipe.logicalShapeMatches(view, &build));

    edges[4].cost += 1;
    try std.testing.expect(!sandbox_recipe.logicalShapeMatches(view, &build));
    edges[4].cost -= 1;
    nodes[0].flags = 0;
    try std.testing.expect(!sandbox_recipe.logicalShapeMatches(view, &build));
    nodes[0].flags = content.bundle.navigation_node_terminal;
    view.navigation_edges = edges[0 .. build.navigation_edge_count - 1];
    try std.testing.expect(!sandbox_recipe.logicalShapeMatches(view, &build));
}
