const std = @import("std");
const content = @import("content");
const district_content_catalog = @import("district_content_catalog");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) return error.ExpectedExplicitContentRoot;
    const root_path = try content.ContentRootPath.parse(args[1]);
    var admission = switch (try district_content_catalog.admit(
        init.io,
        init.gpa,
        root_path,
    )) {
        .admitted => |value| value,
        .failed => return error.InstalledCatalogAdmissionFailed,
    };
    defer admission.deinit();

    const view = admission.view();
    if (view.entries.len != 2) {
        return error.InstalledCatalogSemanticsInvalid;
    }
    const west = try admission.sceneRequest(.{ .x = 0, .z = 0 }, 1);
    const east = try admission.sceneRequest(.{ .x = 1, .z = 0 }, 2);
    if (!std.mem.eql(u8, west.key.bytes(), "district/s3_fixture") or
        !std.mem.eql(u8, east.key.bytes(), "district/s6_east") or
        west.expected_identity == null or east.expected_identity == null)
    {
        return error.InstalledCatalogLookupInvalid;
    }
    const fingerprint = try admission.cohortFingerprint();
    if (std.mem.allEqual(u8, &fingerprint, 0)) {
        return error.InstalledCatalogFingerprintMissing;
    }
}
