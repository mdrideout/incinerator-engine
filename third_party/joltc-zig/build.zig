// Adapted from jrdurandt/joltc-zig at
// c7ff571d475ae4ef26e327e6ffcd81f158e93d97.
// See LICENSE in this directory.

const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const cross_platform_deterministic = b.option(
        bool,
        "cross_platform_deterministic",
        "Compile Jolt for cross-platform deterministic simulation",
    ) orelse false;

    const lib_joltc = try buildLibJoltc(b, .{
        .target = target,
        .optimize = optimize,
        .shared = false,
        .no_exceptions = true,
        .cross_platform_deterministic = cross_platform_deterministic,
    });

    b.installArtifact(lib_joltc);
}

fn buildLibJoltc(
    b: *std.Build,
    options: struct {
        target: std.Build.ResolvedTarget,
        optimize: std.builtin.OptimizeMode,
        shared: bool,
        no_exceptions: bool,
        cross_platform_deterministic: bool,
    },
) !*std.Build.Step.Compile {
    const joltc_dep = b.dependency("joltc", .{});
    const jolt_dep = b.dependency("jolt_physics", .{});

    const lib_joltc = b.addLibrary(.{
        .name = "joltc",
        .linkage = if (options.shared) .dynamic else .static,
        .root_module = b.createModule(.{
            .target = options.target,
            .optimize = options.optimize,
            .link_libc = true,
            .link_libcpp = true,
        }),
    });

    if (options.shared and options.target.result.os.tag == .windows) {
        lib_joltc.root_module.addCMacro("JPH_API", "extern __declspec(dllexport)");
    }

    // JoltC's public ABI fixes JPH_ObjectLayer at uint32_t. Jolt defaults to
    // 16 bits, so every C++ translation unit must receive this definition.
    // joltc_assert.cpp below makes an ABI mismatch a compile-time failure.
    lib_joltc.root_module.addCMacro("JPH_OBJECT_LAYER_BITS", "32");
    if (options.cross_platform_deterministic) {
        lib_joltc.root_module.addCMacro("JPH_CROSS_PLATFORM_DETERMINISTIC", "1");
    }

    lib_joltc.installHeader(joltc_dep.path("include/joltc.h"), "joltc.h");
    lib_joltc.root_module.addIncludePath(joltc_dep.path("include"));
    lib_joltc.root_module.addIncludePath(jolt_dep.path(""));

    if (options.target.result.abi == .msvc) {
        lib_joltc.root_module.linkSystemLibrary("advapi32", .{});
    }

    const c_flags = &.{
        "-std=c++17",
        if (options.no_exceptions) "-fno-exceptions" else "",
        "-fno-access-control",
        "-fno-sanitize=undefined",
    };

    lib_joltc.root_module.addCSourceFiles(.{
        .root = joltc_dep.path("src"),
        .files = &.{ "joltc.cpp", "joltc_assert.cpp" },
        .flags = c_flags,
    });

    const allocator = b.allocator;
    var cpp_files = try std.ArrayList([]const u8).initCapacity(allocator, 0);
    defer cpp_files.deinit(allocator);

    const jolt_path = jolt_dep.path("Jolt");
    const jolt_root = try jolt_path.getPath3(b, null).toString(allocator);
    try collectCppFiles(b.graph.io, allocator, jolt_root, &cpp_files);
    std.mem.sort([]const u8, cpp_files.items, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.lessThan);

    var relative_files = try std.ArrayList([]const u8).initCapacity(allocator, cpp_files.items.len);
    defer relative_files.deinit(allocator);

    const environment = b.graph.environ_map;
    for (cpp_files.items) |absolute_path| {
        const relative_path = try std.Io.Dir.path.relative(
            allocator,
            jolt_root,
            &environment,
            jolt_root,
            absolute_path,
        );
        try relative_files.append(allocator, relative_path);
    }

    lib_joltc.root_module.addCSourceFiles(.{
        .root = jolt_dep.path("Jolt"),
        .files = relative_files.items,
        .flags = c_flags,
    });

    return lib_joltc;
}

fn collectCppFiles(
    io: std.Io,
    allocator: std.mem.Allocator,
    directory_path: []const u8,
    files: *std.ArrayList([]const u8),
) !void {
    var directory = try std.Io.Dir.openDirAbsolute(io, directory_path, .{ .iterate = true });
    defer directory.close(io);

    var iterator = directory.iterate();
    while (try iterator.next(io)) |entry| {
        const full_path = try std.fs.path.join(allocator, &.{ directory_path, entry.name });
        switch (entry.kind) {
            .file => {
                if (std.mem.endsWith(u8, entry.name, ".cpp")) {
                    try files.append(allocator, full_path);
                }
            },
            .directory => try collectCppFiles(io, allocator, full_path, files),
            else => {},
        }
    }
}
