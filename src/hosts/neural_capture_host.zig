//! Filesystem owner for exact same-frame NR-0001 product-color pairs.

const std = @import("std");
const build_options = @import("build_options");
const neural_rendering = @import("neural_rendering_host.zig");

pub const Config = struct {
    root: []const u8,
    start_frame: u64,
    frame_stride: u64,
    frame_count: u64,
};

pub const Owner = struct {
    io: std.Io,
    config: Config,
    index: std.Io.File,
    recorded: u64 = 0,
    neural_outputs_recorded: u64 = 0,

    pub fn init(io: std.Io, config: Config) !Owner {
        if (!std.fs.path.isAbsolute(config.root)) return error.NeuralCaptureRootMustBeAbsolute;
        if (config.frame_stride == 0 or config.frame_count == 0) {
            return error.InvalidNeuralCaptureConfiguration;
        }
        try std.Io.Dir.cwd().createDir(
            io,
            config.root,
            std.Io.Dir.Permissions.fromMode(0o700),
        );
        var child_buffer: [std.fs.max_path_bytes]u8 = undefined;
        for ([_][]const u8{ "inputs", "targets", "outputs" }) |child| {
            const path = try std.fmt.bufPrint(&child_buffer, "{s}/{s}", .{ config.root, child });
            try std.Io.Dir.cwd().createDir(io, path, std.Io.Dir.Permissions.fromMode(0o700));
        }
        const index_path = try std.fmt.bufPrint(
            &child_buffer,
            "{s}/frames.ndjson",
            .{config.root},
        );
        const index = try std.Io.Dir.cwd().createFile(io, index_path, .{
            .exclusive = true,
            .permissions = std.Io.File.Permissions.fromMode(0o600),
        });
        return .{ .io = io, .config = config, .index = index };
    }

    pub fn deinit(self: *Owner) void {
        self.index.sync(self.io) catch {};
        self.index.close(self.io);
        self.writeManifest() catch |err| std.debug.print(
            "Neural capture manifest failed: {s}\n",
            .{@errorName(err)},
        );
        self.* = undefined;
    }

    pub fn wantsFrame(self: *const Owner, presentation_frame: u64) bool {
        if (self.recorded >= self.config.frame_count or
            presentation_frame < self.config.start_frame) return false;
        return (presentation_frame - self.config.start_frame) % self.config.frame_stride == 0;
    }

    pub fn record(self: *Owner, frame: neural_rendering.CapturedFrame) !void {
        if (!self.wantsFrame(frame.presentation_frame)) return;
        var input_relative: [128]u8 = undefined;
        var target_relative: [128]u8 = undefined;
        const input_path = try std.fmt.bufPrint(
            &input_relative,
            "inputs/frame-{d:0>8}.ppm",
            .{frame.presentation_frame},
        );
        const target_path = try std.fmt.bufPrint(
            &target_relative,
            "targets/frame-{d:0>8}.ppm",
            .{frame.presentation_frame},
        );
        const input_digest = try self.writePpm(
            input_path,
            frame.input_pixels,
            neural_rendering.input_width,
            neural_rendering.input_height,
            frame.bgra,
        );
        const target_digest = try self.writePpm(
            target_path,
            frame.target_pixels,
            neural_rendering.output_width,
            neural_rendering.output_height,
            frame.bgra,
        );
        var neural_fields_buffer: [512]u8 = undefined;
        const neural_fields = if (frame.neural_output_pixels) |pixels| blk: {
            var relative_buffer: [128]u8 = undefined;
            const relative = try std.fmt.bufPrint(
                &relative_buffer,
                "outputs/frame-{d:0>8}.ppm",
                .{frame.presentation_frame},
            );
            const digest = try self.writePpm(
                relative,
                pixels,
                neural_rendering.output_width,
                neural_rendering.output_height,
                frame.bgra,
            );
            self.neural_outputs_recorded += 1;
            break :blk try std.fmt.bufPrint(
                &neural_fields_buffer,
                "\"neural_output_path\":\"{s}\",\"neural_output_sha256\":\"{s}\"",
                .{ relative, &digest },
            );
        } else "\"neural_output_path\":null,\"neural_output_sha256\":null";
        var line: [1536]u8 = undefined;
        const encoded = try std.fmt.bufPrint(
            &line,
            "{{\"schema\":1,\"frame_id\":\"frame-{d:0>8}\",\"authority_tick\":{d}," ++
                "\"presentation_frame\":{d},\"input_path\":\"{s}\",\"input_sha256\":\"{s}\"," ++
                "\"target_path\":\"{s}\",\"target_sha256\":\"{s}\",{s}}}\n",
            .{
                frame.presentation_frame,
                frame.authority_tick,
                frame.presentation_frame,
                input_path,
                &input_digest,
                target_path,
                &target_digest,
                neural_fields,
            },
        );
        try self.index.writeStreamingAll(self.io, encoded);
        self.recorded += 1;
    }

    fn writePpm(
        self: *Owner,
        relative_path: []const u8,
        pixels: []const u8,
        width: u32,
        height: u32,
        bgra: bool,
    ) ![64]u8 {
        var header_buffer: [64]u8 = undefined;
        const header = try std.fmt.bufPrint(
            &header_buffer,
            "P6\n{d} {d}\n255\n",
            .{ width, height },
        );
        const rgb_count: usize = @as(usize, width) * height * 3;
        const output = try std.heap.page_allocator.alloc(u8, header.len + rgb_count);
        defer std.heap.page_allocator.free(output);
        @memcpy(output[0..header.len], header);
        var pixel: usize = 0;
        var destination = header.len;
        while (pixel < pixels.len) : (pixel += 4) {
            output[destination] = pixels[pixel + if (bgra) @as(usize, 2) else 0];
            output[destination + 1] = pixels[pixel + 1];
            output[destination + 2] = pixels[pixel + if (bgra) @as(usize, 0) else 2];
            destination += 3;
        }
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const absolute = try std.fmt.bufPrint(
            &path_buffer,
            "{s}/{s}",
            .{ self.config.root, relative_path },
        );
        try std.Io.Dir.cwd().writeFile(self.io, .{
            .sub_path = absolute,
            .data = output,
            .flags = .{ .exclusive = true },
        });
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(output, &digest, .{});
        return std.fmt.bytesToHex(digest, .lower);
    }

    fn writeManifest(self: *const Owner) !void {
        var bytes: [4096]u8 = undefined;
        const status = if (self.recorded == self.config.frame_count) "complete" else "partial";
        const encoded = try std.fmt.bufPrint(
            &bytes,
            "{{\n" ++
                "  \"schema\": 1,\n" ++
                "  \"status\": \"{s}\",\n" ++
                "  \"purpose\": \"exact same-frame product-color spatial pipeline proof; not NR0 auxiliary-buffer capture\",\n" ++
                "  \"source_revision\": \"{s}\",\n" ++
                "  \"source_dirty\": {},\n" ++
                "  \"source_dirty_fingerprint\": \"{s}\",\n" ++
                "  \"input_size\": [{d}, {d}],\n" ++
                "  \"target_size\": [{d}, {d}],\n" ++
                "  \"scale\": 4,\n" ++
                "  \"selection\": {{\"start_frame\": {d}, \"frame_stride\": {d}, \"requested_frames\": {d}}},\n" ++
                "  \"recorded_frames\": {d},\n" ++
                "  \"neural_outputs_recorded\": {d},\n" ++
                "  \"frame_index\": \"frames.ndjson\"\n" ++
                "}}\n",
            .{
                status,
                build_options.source_revision,
                build_options.source_dirty,
                build_options.source_dirty_fingerprint,
                neural_rendering.input_width,
                neural_rendering.input_height,
                neural_rendering.output_width,
                neural_rendering.output_height,
                self.config.start_frame,
                self.config.frame_stride,
                self.config.frame_count,
                self.recorded,
                self.neural_outputs_recorded,
            },
        );
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, "{s}/capture.json", .{self.config.root});
        try std.Io.Dir.cwd().writeFile(self.io, .{
            .sub_path = path,
            .data = encoded,
            .flags = .{ .exclusive = true },
        });
    }
};

test "capture frame selection is explicit and finite" {
    const owner = Owner{
        .io = std.testing.io,
        .config = .{ .root = "/tmp/not-opened", .start_frame = 10, .frame_stride = 3, .frame_count = 2 },
        .index = undefined,
    };
    try std.testing.expect(!owner.wantsFrame(9));
    try std.testing.expect(owner.wantsFrame(10));
    try std.testing.expect(!owner.wantsFrame(11));
    try std.testing.expect(owner.wantsFrame(13));
}
