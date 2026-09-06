//! Deterministic source/content identity, including uncommitted source edits.
//! No Git metadata or checkout paths: filtered source packages match checkouts.
const std = @import("std");

pub fn sourceFingerprint(io: std.Io, allocator: std.mem.Allocator, root: std.Io.Dir) !u64 {
    var hash = std.hash.Wyhash.init(0x494e_4342);
    for ([_][]const u8{ "src", "shaders", "third_party", "tools/build" }) |path| {
        var dir = try root.openDir(io, path, .{ .iterate = true });
        defer dir.close(io);
        addPart(&hash, path);
        const fingerprint = try treeFingerprint(io, allocator, dir);
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, fingerprint, .little);
        addPart(&hash, &bytes);
    }
    for ([_][]const u8{ "build.zig", "build.zig.zon", "tools/build_gamenetworking_sockets.sh" }) |path| {
        addPart(&hash, path);
        const bytes = try root.readFileAlloc(io, path, allocator, .unlimited);
        defer allocator.free(bytes);
        addPart(&hash, bytes);
    }
    return hash.final();
}

pub fn contentFingerprint(bytes: []const u8) u64 {
    // This is the exact admitted logical manifest, including catalog/bundle
    // digests and recipe versions, also verified against the cooked install.
    return std.hash.Wyhash.hash(0x494e_434e, bytes);
}

fn treeFingerprint(io: std.Io, allocator: std.mem.Allocator, dir: std.Io.Dir) !u64 {
    var paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (paths.items) |path| allocator.free(path);
        paths.deinit(allocator);
    }
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !isSource(entry.path)) continue;
        try paths.append(allocator, try allocator.dupe(u8, entry.path));
    }
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
    var hash = std.hash.Wyhash.init(0);
    for (paths.items) |path| {
        addPart(&hash, path);
        const bytes = try dir.readFileAlloc(io, path, allocator, .unlimited);
        defer allocator.free(bytes);
        addPart(&hash, bytes);
    }
    return hash.final();
}

fn isSource(path: []const u8) bool {
    for ([_][]const u8{ ".zig", ".zon", ".c", ".cpp", ".h", ".hpp", ".m", ".mm", ".vert", ".frag", ".comp", ".glsl", ".metal" }) |extension|
        if (std.mem.endsWith(u8, path, extension)) return true;
    return false;
}

fn addPart(hash: *std.hash.Wyhash, bytes: []const u8) void {
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, bytes.len, .little);
    hash.update(&length);
    hash.update(bytes);
}

test "source cohorts ignore checkout location and detect source edits and additions" {
    var first = std.testing.tmpDir(.{ .iterate = true });
    defer first.cleanup();
    var second = std.testing.tmpDir(.{ .iterate = true });
    defer second.cleanup();
    try first.dir.writeFile(std.testing.io, .{ .sub_path = "a.zig", .data = "source a" });
    try first.dir.writeFile(std.testing.io, .{ .sub_path = "b.cpp", .data = "source b" });
    try second.dir.writeFile(std.testing.io, .{ .sub_path = "b.cpp", .data = "source b" });
    try second.dir.writeFile(std.testing.io, .{ .sub_path = "a.zig", .data = "source a" });
    const original = try treeFingerprint(std.testing.io, std.testing.allocator, first.dir);
    try std.testing.expectEqual(original, try treeFingerprint(std.testing.io, std.testing.allocator, second.dir));
    try second.dir.writeFile(std.testing.io, .{ .sub_path = "a.zig", .data = "changed source" });
    try std.testing.expect(original != try treeFingerprint(std.testing.io, std.testing.allocator, second.dir));
    try first.dir.writeFile(std.testing.io, .{ .sub_path = "new.zig", .data = "new owner" });
    try std.testing.expect(original != try treeFingerprint(std.testing.io, std.testing.allocator, first.dir));
    try std.testing.expect(contentFingerprint("catalog digest A") != contentFingerprint("catalog digest B"));
}
