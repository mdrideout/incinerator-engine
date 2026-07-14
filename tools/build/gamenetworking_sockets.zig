const std = @import("std");

pub const Integration = struct {
    source: std.Build.LazyPath,
    include: std.Build.LazyPath,
    archive: std.Build.LazyPath,
    build_step: *std.Build.Step,

    pub fn link(self: Integration, artifact: *std.Build.Step.Compile) void {
        const b = artifact.step.owner;
        artifact.step.dependOn(self.build_step);
        artifact.root_module.addCSourceFile(.{
            .file = b.path("src/adapters/transport/gns_c_api.cpp"),
            .flags = &.{ "-std=c++17", "-DSTEAMNETWORKINGSOCKETS_STATIC_LINK" },
        });
        artifact.root_module.addIncludePath(b.path("src/adapters/transport"));
        artifact.root_module.addIncludePath(self.include);
        artifact.root_module.addObjectFile(self.archive);
        artifact.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/opt/protobuf/lib" });
        artifact.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/opt/openssl@3/lib" });
        artifact.root_module.linkSystemLibrary("protobuf", .{});
        artifact.root_module.linkSystemLibrary("crypto", .{});
        artifact.root_module.link_libcpp = true;
    }
};

pub fn create(
    b: *std.Build,
    optimize: std.builtin.OptimizeMode,
) ?Integration {
    const dependency = b.lazyDependency("game_networking_sockets", .{}) orelse return null;
    const build = b.addSystemCommand(&.{"sh"});
    build.addFileArg(b.path("tools/build_gamenetworking_sockets.sh"));
    build.addDirectoryArg(dependency.path("."));
    const output = build.addOutputDirectoryArg("game-networking-sockets");
    build.addArg(switch (optimize) {
        .Debug => "Debug",
        .ReleaseSafe, .ReleaseFast, .ReleaseSmall => "Release",
    });
    return .{
        .source = dependency.path("."),
        .include = dependency.path("include"),
        .archive = output.path(b, "src/libGameNetworkingSockets_s.a"),
        .build_step = &build.step,
    };
}
