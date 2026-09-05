//! Deterministically pack a project glTF template and one PNG dependency into GLB.
//!
//! The template contains exactly one `__EA1_IMAGE_DATA_URI__` marker. Replacing
//! it at build time keeps the authored source reviewable while proving the GLB
//! import path without checking generated container bytes into source control.

const std = @import("std");

const marker = "__EA1_IMAGE_DATA_URI__";
const max_template_bytes = 512 * 1024;
const max_image_bytes = 4 * 1024 * 1024;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 4) return error.ExpectedTemplateImageAndOutput;

    const template = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        args[1],
        allocator,
        .limited(max_template_bytes),
    );
    defer allocator.free(template);
    const image = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        args[2],
        allocator,
        .limited(max_image_bytes),
    );
    defer allocator.free(image);
    if (!isPng(image)) return error.ExpectedPngImage;

    const bytes = try pack(allocator, template, image);
    defer allocator.free(bytes);
    try writeAtomic(init.io, args[3], bytes);
}

fn pack(allocator: std.mem.Allocator, template: []const u8, png: []const u8) ![]u8 {
    const marker_offset = std.mem.indexOf(u8, template, marker) orelse
        return error.ImageMarkerMissing;
    if (std.mem.indexOf(u8, template[marker_offset + marker.len ..], marker) != null) {
        return error.MultipleImageMarkers;
    }

    const encoded_len = std.base64.standard.Encoder.calcSize(png.len);
    const data_uri_len = "data:image/png;base64,".len + encoded_len;
    const json_len = template.len - marker.len + data_uri_len;
    const padded_json_len = std.mem.alignForward(usize, json_len, 4);
    const total_len = 12 + 8 + padded_json_len;
    const output = try allocator.alloc(u8, total_len);
    errdefer allocator.free(output);
    @memset(output, ' ');

    std.mem.writeInt(u32, output[0..4], 0x46546c67, .little);
    std.mem.writeInt(u32, output[4..8], 2, .little);
    std.mem.writeInt(u32, output[8..12], @intCast(total_len), .little);
    std.mem.writeInt(u32, output[12..16], @intCast(padded_json_len), .little);
    std.mem.writeInt(u32, output[16..20], 0x4e4f534a, .little);

    var cursor: usize = 20;
    @memcpy(output[cursor..][0..marker_offset], template[0..marker_offset]);
    cursor += marker_offset;
    const prefix = "data:image/png;base64,";
    @memcpy(output[cursor..][0..prefix.len], prefix);
    cursor += prefix.len;
    _ = std.base64.standard.Encoder.encode(output[cursor..][0..encoded_len], png);
    cursor += encoded_len;
    const suffix = template[marker_offset + marker.len ..];
    @memcpy(output[cursor..][0..suffix.len], suffix);
    return output;
}

fn isPng(bytes: []const u8) bool {
    return bytes.len >= 8 and std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n");
}

fn writeAtomic(io: std.Io, output_path: []const u8, bytes: []const u8) !void {
    const directory_path = std.fs.path.dirname(output_path) orelse
        return error.OutputDirectoryRequired;
    const basename = std.fs.path.basename(output_path);
    var directory = if (std.fs.path.isAbsolute(directory_path))
        try std.Io.Dir.openDirAbsolute(io, directory_path, .{})
    else
        try std.Io.Dir.cwd().openDir(io, directory_path, .{});
    defer directory.close(io);
    var atomic = try directory.createFileAtomic(io, basename, .{ .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, bytes);
    try atomic.replace(io);
}

test "packer emits deterministic GLB JSON container" {
    const template = "{\"asset\":{\"version\":\"2.0\"},\"uri\":\"__EA1_IMAGE_DATA_URI__\"}";
    const png = "\x89PNG\r\n\x1a\nbody";
    const first = try pack(std.testing.allocator, template, png);
    defer std.testing.allocator.free(first);
    const second = try pack(std.testing.allocator, template, png);
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualSlices(u8, first, second);
    try std.testing.expectEqual(@as(u32, 0x46546c67), std.mem.readInt(u32, first[0..4], .little));
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, first[4..8], .little));
    try std.testing.expectEqual(first.len, std.mem.readInt(u32, first[8..12], .little));
    try std.testing.expect(std.mem.indexOf(u8, first, "data:image/png;base64,") != null);
}
