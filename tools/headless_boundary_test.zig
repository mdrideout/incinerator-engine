//! Portable source-edge verifier for the first-party headless module graph.

const std = @import("std");

const prohibited_import_basenames = [_][]const u8{
    "sdl",
    "renderer",
    "mesh",
    "texture",
    "editor",
    "sandbox_visual_resources",
    "sandbox_controls",
    "zgui",
    "zmath",
    "zmesh",
    "zstbi",
    "shader_assets",
    "vulkan",
    "d3d12",
    "metal",
};

const root_files = [_][]const u8{
    "src/root.zig",
    "src/physics.zig",
    "src/adapters/physics/jolt_c.zig",
    "src/hosts/headless.zig",
    "src/hosts/simulation.zig",
};

const root_directories = [_][]const u8{
    "src/engine",
    "src/features/crates",
    "src/features/character",
};

pub fn main(init: std.process.Init) !void {
    for (root_files) |path| try scanFile(init, path);
    for (root_directories) |path| try scanDirectory(init, path);
    std.debug.print("headless source boundary verified\n", .{});
}

fn scanDirectory(init: std.process.Init, path: []const u8) !void {
    var directory = try std.Io.Dir.cwd().openDir(init.io, path, .{ .iterate = true });
    defer directory.close(init.io);
    var walker = try directory.walk(init.gpa);
    defer walker.deinit();
    while (try walker.next(init.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const joined = try std.fs.path.join(init.gpa, &.{ path, entry.path });
        defer init.gpa.free(joined);
        try scanFile(init, joined);
    }
}

fn scanFile(init: std.process.Init, path: []const u8) !void {
    const source = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        path,
        init.gpa,
        .limited(4 * 1024 * 1024),
    );
    defer init.gpa.free(source);

    try scanStringDirective(source, path, "@import(\"", true);
    try scanStringDirective(source, path, "@cInclude(\"", true);
}

fn scanStringDirective(
    source: []const u8,
    path: []const u8,
    prefix: []const u8,
    emit_diagnostics: bool,
) !void {
    var remaining = source;
    while (std.mem.indexOf(u8, remaining, prefix)) |start| {
        const import_start = start + prefix.len;
        const after_start = remaining[import_start..];
        const import_end = std.mem.indexOf(u8, after_start, "\")") orelse
            return error.MalformedImport;
        const imported = after_start[0..import_end];
        const basename_with_extension = std.fs.path.basename(imported);
        const basename = std.fs.path.stem(basename_with_extension);
        for (prohibited_import_basenames) |prohibited| {
            if (std.ascii.startsWithIgnoreCase(basename, prohibited)) {
                if (emit_diagnostics) {
                    std.debug.print(
                        "prohibited headless dependency in {s}: {s}\n",
                        .{ path, imported },
                    );
                }
                return error.ProhibitedHeadlessImport;
            }
        }
        remaining = after_start[import_end + "\")".len ..];
    }
}

test "directive scanner covers Zig imports and raw C includes" {
    try std.testing.expectEqualStrings("sdl.zig", std.fs.path.basename("../../sdl.zig"));
    try std.testing.expectEqualStrings("shader_assets", std.fs.path.basename("shader_assets"));
    try std.testing.expectError(
        error.ProhibitedHeadlessImport,
        scanStringDirective(
            "const c = @cImport({ @cInclude(\"SDL3/SDL.h\"); });",
            "test",
            "@cInclude(\"",
            false,
        ),
    );
    try scanStringDirective(
        "const c = @cImport({ @cInclude(\"joltc.h\"); });",
        "test",
        "@cInclude(\"",
        false,
    );
}
