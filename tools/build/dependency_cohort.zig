//! Verify generated runtime cohort identities still match pinned manifests.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();

    _ = args.next() orelse return error.MissingExecutableName;
    const root_manifest_path = args.next() orelse return error.MissingRootManifest;
    const wrapper_manifest_path = args.next() orelse return error.MissingWrapperManifest;
    const wrapper_readme_path = args.next() orelse return error.MissingWrapperReadme;
    const zflecs_revision = args.next() orelse return error.MissingZflecsRevision;
    const wrapper_revision = args.next() orelse return error.MissingWrapperRevision;
    const joltc_revision = args.next() orelse return error.MissingJoltcRevision;
    const jolt_revision = args.next() orelse return error.MissingJoltRevision;
    if (args.next() != null) return error.UnexpectedArgument;

    const root_manifest = try read(init, root_manifest_path);
    defer init.gpa.free(root_manifest);
    const wrapper_manifest = try read(init, wrapper_manifest_path);
    defer init.gpa.free(wrapper_manifest);
    const wrapper_readme = try read(init, wrapper_readme_path);
    defer init.gpa.free(wrapper_readme);

    try requireRevision(root_manifest_path, root_manifest, zflecs_revision);
    try requireRevision(wrapper_readme_path, wrapper_readme, wrapper_revision);
    try requireRevision(wrapper_manifest_path, wrapper_manifest, joltc_revision);
    try requireRevision(wrapper_manifest_path, wrapper_manifest, jolt_revision);
    std.debug.print("dependency/replay cohort pins verified\n", .{});
}

fn read(init: std.process.Init, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(init.io, path, init.gpa, .limited(2 * 1024 * 1024));
}

fn requireRevision(path: []const u8, contents: []const u8, revision: []const u8) !void {
    if (!hasRevision(contents, revision)) {
        std.debug.print("cohort revision not pinned by {s}: {s}\n", .{ path, revision });
        return error.DependencyCohortDrift;
    }
}

fn hasRevision(contents: []const u8, revision: []const u8) bool {
    return revision.len == 40 and std.mem.indexOf(u8, contents, revision) != null;
}

test "revision verifier requires an exact 40-byte pin" {
    const revision = "0123456789abcdef0123456789abcdef01234567";
    try std.testing.expect(
        hasRevision("prefix 0123456789abcdef0123456789abcdef01234567 suffix", revision),
    );
    try std.testing.expect(!hasRevision("missing", revision));
    try std.testing.expect(!hasRevision("short", "abc"));
}
