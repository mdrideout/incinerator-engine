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
    if (view.entries.len != @import("sandbox_district_recipe").installed_coords.len) {
        return error.InstalledCatalogSemanticsInvalid;
    }
    const southwest = try admission.sceneRequest(.{ .x = 0, .z = 0 }, 1);
    const southeast = try admission.sceneRequest(.{ .x = 1, .z = 0 }, 2);
    const northwest = try admission.sceneRequest(.{ .x = 0, .z = 1 }, 3);
    const northeast = try admission.sceneRequest(.{ .x = 1, .z = 1 }, 4);
    if (!std.mem.eql(u8, southwest.key.bytes(), "district/industrial_0_0") or
        !std.mem.eql(u8, southeast.key.bytes(), "district/industrial_1_0") or
        !std.mem.eql(u8, northwest.key.bytes(), "district/industrial_0_1") or
        !std.mem.eql(u8, northeast.key.bytes(), "district/industrial_1_1") or
        southwest.expected_identity == null or southeast.expected_identity == null or
        northwest.expected_identity == null or northeast.expected_identity == null)
    {
        return error.InstalledCatalogLookupInvalid;
    }
    const fingerprint = try admission.cohortFingerprint();
    if (std.mem.allEqual(u8, &fingerprint, 0)) {
        return error.InstalledCatalogFingerprintMissing;
    }
    var root = try content.ContentRoot.open(init.io, root_path);
    defer root.deinit(init.io);
    var vehicles = content.asset_catalog.Builder.init(init.gpa);
    defer vehicles.deinit();
    for (@import("game_vehicles").bundle_keys) |key| {
        var scene = switch (try root.load(init.io, init.gpa, try content.BundleKey.parse(key), .{})) {
            .scene => |value| value,
            .failed => return error.InstalledVehicleBundleMissing,
        };
        defer scene.deinit();
        try vehicles.appendBundle(key, &scene);
    }
    var vehicle_assets = try vehicles.finish();
    defer vehicle_assets.deinit();
    var lights = try content.lighting_library.read(init.gpa, init.io, root.dir);
    defer lights.deinit();
    try lights.value.validateCatalog(init.gpa, &.{ admission.assetView(), vehicle_assets.view() });
    try lights.value.validateVehicleMounts(&@import("game_vehicles").lighting_mount_ids);
    std.debug.print("EA3_RELOCATION installed_lighting=true references_valid=true source_discovery=false\n", .{});
}
