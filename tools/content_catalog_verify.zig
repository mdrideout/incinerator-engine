const std = @import("std");
const content = @import("content");
const district_contract = @import("district_contract");
const sandbox_replay = @import("sandbox_replay");
const sandbox_recipe = @import("sandbox_district_recipe");

const HeadlessDistrict = struct {
    semantic_id: []const u8,
    coord_x: i32,
    coord_z: i32,
    recipe_version: u16,
    bundle_file_sha256: []const u8,
};

const HeadlessManifest = struct {
    schema_version: u16,
    catalog_semantic_id: []const u8,
    catalog_wire_schema: u16,
    content_cohort_fingerprint: []const u8,
    catalog_file_sha256: []const u8,
    districts: []const HeadlessDistrict,
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 7) {
        return error.ExpectedCatalogPairBundlesAndHeadlessManifests;
    }
    const allocator = init.gpa;
    const catalog_bytes = try read(init, args[1], content.catalog.max_file_bytes);
    defer allocator.free(catalog_bytes);
    const repeated_bytes = try read(init, args[2], content.catalog.max_file_bytes);
    defer allocator.free(repeated_bytes);
    if (!std.mem.eql(u8, catalog_bytes, repeated_bytes)) {
        return error.CatalogCookIsNotDeterministic;
    }

    var catalog = switch (try content.catalog.decode(allocator, catalog_bytes, .{})) {
        .catalog => |value| value,
        .failed => return error.GeneratedCatalogIsInvalid,
    };
    defer catalog.deinit();
    const view = catalog.view();
    if (!std.mem.eql(u8, view.name, "district.catalog") or view.entries.len != 2) {
        return error.UnexpectedCatalogIdentity;
    }
    _ = try view.fingerprint();

    const west_bytes = try read(init, args[3], (content.bundle.Limits{}).max_file_bytes);
    defer allocator.free(west_bytes);
    const east_bytes = try read(init, args[4], (content.bundle.Limits{}).max_file_bytes);
    defer allocator.free(east_bytes);
    var west = switch (try content.bundle.decode(allocator, west_bytes, .{})) {
        .bundle => |value| value,
        .failed => return error.GeneratedBundleIsInvalid,
    };
    defer west.deinit();
    var east = switch (try content.bundle.decode(allocator, east_bytes, .{})) {
        .bundle => |value| value,
        .failed => return error.GeneratedBundleIsInvalid,
    };
    defer east.deinit();

    const east_index = view.lookupSemanticId("district.east") orelse
        return error.MissingEastEntry;
    const west_index = view.lookupSemanticId("district.west") orelse
        return error.MissingWestEntry;
    try verifyEntry(view.entries[east_index], .{ .x = 1, .z = 0 }, east.bundleIdentity());
    try verifyEntry(view.entries[west_index], .{ .x = 0, .z = 0 }, west.bundleIdentity());
    if (view.lookupCoordinate(.{ .x = 1, .z = 0 }) != east_index or
        view.lookupCoordinate(.{ .x = 0, .z = 0 }) != west_index or
        view.lookupBundleKey("district/s6_east") != east_index or
        view.lookupBundleKey("district/s3_fixture") != west_index)
    {
        return error.CatalogLookupDiverged;
    }
    const east_dependencies = try view.dependencies(east_index);
    if (east_dependencies.len != 1 or east_dependencies[0] != west_index or
        (try view.dependencies(west_index)).len != 0)
    {
        return error.CatalogDependencyDiverged;
    }
    var closure_storage: [content.catalog.max_entries]u32 = undefined;
    const required = try view.dependencyClosure(east_index, &closure_storage);
    if (required.len != 2 or required[0] != east_index or required[1] != west_index) {
        return error.CatalogDependencyClosureDiverged;
    }
    const affected = try view.dependentClosure(west_index, &closure_storage);
    if (affected.len != 2 or affected[0] != east_index or affected[1] != west_index) {
        return error.CatalogAffectedClosureDiverged;
    }
    try verifyHeadlessCohort(
        init,
        catalog.identity(),
        catalog_bytes,
        west_bytes,
        east_bytes,
        args[5],
        args[6],
    );
}

fn verifyHeadlessCohort(
    init: std.process.Init,
    identity: content.catalog.Identity,
    catalog_bytes: []const u8,
    west_bytes: []const u8,
    east_bytes: []const u8,
    manifest_path: []const u8,
    config_path: []const u8,
) !void {
    const manifest_bytes = try read(init, manifest_path, 16 * 1024);
    defer init.gpa.free(manifest_bytes);
    var manifest = try std.json.parseFromSlice(
        HeadlessManifest,
        init.gpa,
        manifest_bytes,
        .{},
    );
    defer manifest.deinit();
    const value = manifest.value;
    if (value.schema_version != 1 or value.catalog_wire_schema != 1 or
        !std.mem.eql(u8, value.catalog_semantic_id, "incinerator.s6.two-district") or
        value.districts.len != 2)
    {
        return error.HeadlessContentManifestShapeDiverged;
    }

    const cohort = try sandbox_replay.ContentCohort.init(
        identity.name,
        identity.format_version,
        identity.schema_cohort,
        sandbox_recipe.current_recipe_version,
        identity.source_digest,
        identity.integrity_digest,
    );
    try expectDigest(
        "content cohort fingerprint",
        try cohort.fingerprint(),
        value.content_cohort_fingerprint,
    );
    try expectDigest("catalog file", sha256(catalog_bytes), value.catalog_file_sha256);
    try expectDistrictDigest(
        value.districts[0],
        "district.west",
        .{ .x = 0, .z = 0 },
        sha256(west_bytes),
    );
    try expectDistrictDigest(
        value.districts[1],
        "district.east",
        .{ .x = 1, .z = 0 },
        sha256(east_bytes),
    );

    const config_bytes = try read(init, config_path, 64 * 1024);
    defer init.gpa.free(config_bytes);
    var config = try std.json.parseFromSlice(std.json.Value, init.gpa, config_bytes, .{});
    defer config.deinit();
    const expected = switch (config.value) {
        .object => |object| switch (object.get("expected_content_cohort") orelse
            return error.HeadlessConfigMissingContentCohort) {
            .string => |string| string,
            else => return error.HeadlessConfigInvalidContentCohort,
        },
        else => return error.HeadlessConfigInvalid,
    };
    if (!std.mem.eql(u8, expected, value.content_cohort_fingerprint)) {
        return error.HeadlessConfigContentCohortDiverged;
    }
    std.debug.print(
        "headless logical manifest matches freshly cooked catalog and bundles\n",
        .{},
    );
}

fn expectDistrictDigest(
    district: HeadlessDistrict,
    semantic_id: []const u8,
    coord: district_contract.ChunkCoord,
    digest: [32]u8,
) !void {
    if (!std.mem.eql(u8, district.semantic_id, semantic_id) or
        district.coord_x != coord.x or district.coord_z != coord.z or
        district.recipe_version != sandbox_recipe.current_recipe_version)
    {
        return error.HeadlessDistrictIdentityDiverged;
    }
    try expectDigest(semantic_id, digest, district.bundle_file_sha256);
}

fn expectDigest(label: []const u8, digest: [32]u8, found: []const u8) !void {
    const expected = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, &expected, found)) {
        std.debug.print("{s} digest drift: expected {s}, found {s}\n", .{
            label,
            &expected,
            found,
        });
        return error.HeadlessContentDigestDiverged;
    }
}

fn sha256(bytes: []const u8) [32]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return digest;
}

fn read(init: std.process.Init, path: []const u8, maximum: usize) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(init.io, path, init.gpa, .limited(maximum));
}

fn verifyEntry(
    entry: content.catalog.EntryView,
    coord: content.catalog.ChunkCoord,
    identity: content.bundle.BundleIdentity,
) !void {
    if (!content.catalog.ChunkCoord.eql(entry.coord, coord) or
        !std.mem.eql(u8, entry.bundle_key, identity.name) or
        entry.bundle.format_version != identity.format_version or
        entry.bundle.schema_cohort != identity.schema_cohort or
        !std.mem.eql(u8, &entry.bundle.source_digest, &identity.source_digest) or
        !std.mem.eql(u8, &entry.bundle.integrity_digest, &identity.integrity_digest))
    {
        return error.CatalogBundleIdentityDiverged;
    }
    const expected = switch (sandbox_recipe.build(
        .{ .x = coord.x, .z = coord.z },
        entry.recipe_version,
    )) {
        .ready => |value| value,
        .failed => return error.CatalogLogicalIdentityDiverged,
    };
    if (entry.logical_checksum != expected.checksum) {
        return error.CatalogLogicalIdentityDiverged;
    }
}
