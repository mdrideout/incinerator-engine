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
    if (view.entries.len != 4) {
        return error.InstalledCatalogSemanticsInvalid;
    }
    const southwest = try admission.sceneRequest(.{ .x = 0, .z = 0 }, 1);
    const southeast = try admission.sceneRequest(.{ .x = 1, .z = 0 }, 2);
    const northwest = try admission.sceneRequest(.{ .x = 0, .z = 1 }, 3);
    const northeast = try admission.sceneRequest(.{ .x = 1, .z = 1 }, 4);
    if (!std.mem.eql(u8, southwest.key.bytes(), "district/s15_world_southwest") or
        !std.mem.eql(u8, southeast.key.bytes(), "district/s15_world_southeast") or
        !std.mem.eql(u8, northwest.key.bytes(), "district/s15_world_northwest") or
        !std.mem.eql(u8, northeast.key.bytes(), "district/s15_world_northeast") or
        southwest.expected_identity == null or southeast.expected_identity == null or
        northwest.expected_identity == null or northeast.expected_identity == null)
    {
        return error.InstalledCatalogLookupInvalid;
    }
    const fingerprint = try admission.cohortFingerprint();
    if (std.mem.allEqual(u8, &fingerprint, 0)) {
        return error.InstalledCatalogFingerprintMissing;
    }
}
