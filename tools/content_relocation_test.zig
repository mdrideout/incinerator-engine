const std = @import("std");
const content = @import("content");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) return error.ExpectedExplicitContentRoot;
    const root_path = try content.ContentRootPath.parse(args[1]);
    var root = try content.ContentRoot.open(init.io, root_path);
    defer root.deinit(init.io);
    var result = try root.load(
        init.io,
        init.gpa,
        try content.BundleKey.parse("district/s3_fixture"),
        .{},
    );
    switch (result) {
        .failed => return error.InstalledContentLoadFailed,
        .scene => |*scene| {
            defer scene.deinit();
            const view = scene.view();
            if (view.nodes.len != 2 or view.nodes[0].mesh != 0 or view.nodes[1].mesh != 0 or
                view.textures.len != 1 or view.static_boxes.len != 6)
            {
                return error.InstalledContentSemanticsInvalid;
            }
        },
    }
}
