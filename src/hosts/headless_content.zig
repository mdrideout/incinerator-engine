//! Logical-only admission manifest for the macOS server-shaped product.
//!
//! The headless install deliberately omits cooked visual bundles. This small
//! manifest freezes the exact S6/S8 catalog cohort, district coordinates,
//! logical recipe versions, and source bundle digests needed to reject a
//! mismatched deployment before authoritative world construction.

const std = @import("std");
const headless_config = @import("headless_config");
const admitted_manifest = @import("headless_content_manifest");
const sandbox_recipe = @import("sandbox_district_recipe");

pub const schema_version: u16 = 1;
pub const max_manifest_bytes: usize = 16 * 1024;
pub const district_count: usize = 2;

pub const District = struct {
    semantic_id: []const u8,
    coord_x: i32,
    coord_z: i32,
    recipe_version: u16,
    bundle_file_sha256: []const u8,
};

pub const ManifestV1 = struct {
    schema_version: u16,
    catalog_semantic_id: []const u8,
    catalog_wire_schema: u16,
    content_cohort_fingerprint: []const u8,
    catalog_file_sha256: []const u8,
    districts: []const District,

    pub fn validate(self: ManifestV1) !void {
        if (self.schema_version != schema_version) {
            return error.UnsupportedHeadlessContentSchema;
        }
        if (!std.mem.eql(
            u8,
            self.catalog_semantic_id,
            sandbox_recipe.catalog_semantic_id,
        ) or self.catalog_wire_schema != sandbox_recipe.catalog_wire_schema) {
            return error.IncompatibleLogicalCatalog;
        }
        _ = try headless_config.decodeDigest(self.content_cohort_fingerprint);
        _ = try headless_config.decodeDigest(self.catalog_file_sha256);
        if (self.districts.len != district_count) {
            return error.IncompatibleLogicalCatalog;
        }
        try validateDistrict(
            self.districts[0],
            "district.west",
            0,
            0,
        );
        try validateDistrict(
            self.districts[1],
            "district.east",
            1,
            0,
        );
    }

    /// Admit the expected cohort after `parse` has established exact equality
    /// with the manifest compiled into this product.
    pub fn admit(
        self: ManifestV1,
        expected: [headless_config.content_digest_bytes]u8,
    ) !void {
        try self.validate();
        const actual = try headless_config.decodeDigest(
            self.content_cohort_fingerprint,
        );
        if (!std.mem.eql(u8, &actual, &expected)) {
            return error.IncompatibleContentCohort;
        }
    }
};

pub const Parsed = std.json.Parsed(ManifestV1);

pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !Parsed {
    if (bytes.len == 0 or bytes.len > max_manifest_bytes) {
        return error.HeadlessContentManifestSizeOutOfRange;
    }
    var parsed = try std.json.parseFromSlice(ManifestV1, allocator, bytes, .{});
    errdefer parsed.deinit();
    try parsed.value.validate();
    if (!std.mem.eql(u8, bytes, admitted_manifest.bytes)) {
        return error.IncompatibleLogicalCatalog;
    }
    return parsed;
}

fn validateDistrict(
    district: District,
    semantic_id: []const u8,
    coord_x: i32,
    coord_z: i32,
) !void {
    if (!std.mem.eql(u8, district.semantic_id, semantic_id) or
        district.coord_x != coord_x or district.coord_z != coord_z or
        district.recipe_version != sandbox_recipe.current_recipe_version)
    {
        return error.IncompatibleLogicalCatalog;
    }
    _ = try headless_config.decodeDigest(district.bundle_file_sha256);
}

const valid_manifest = admitted_manifest.bytes;

test "exact logical-only manifest admits the configured content cohort" {
    var parsed = try parse(std.testing.allocator, valid_manifest);
    defer parsed.deinit();
    try parsed.value.admit(try headless_config.decodeDigest(
        parsed.value.content_cohort_fingerprint,
    ));
}

test "manifest rejects reorder mutation digest mismatch and unknown fields" {
    var parsed = try parse(std.testing.allocator, valid_manifest);
    defer parsed.deinit();

    var value = parsed.value;
    var districts: [district_count]District = .{
        value.districts[0],
        value.districts[1],
    };
    districts[0].coord_x = 7;
    value.districts = &districts;
    try std.testing.expectError(error.IncompatibleLogicalCatalog, value.validate());
    districts[0].coord_x = 0;

    var wrong = try headless_config.decodeDigest(value.content_cohort_fingerprint);
    wrong[0] ^= 0xff;
    try std.testing.expectError(error.IncompatibleContentCohort, value.admit(wrong));

    try std.testing.expectError(
        error.UnknownField,
        parse(std.testing.allocator,
            \\{"schema_version":1,"unknown":true}
        ),
    );
}
