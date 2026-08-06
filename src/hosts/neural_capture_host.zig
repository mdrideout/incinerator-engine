//! External NR0-B dataset capture for aligned neural inputs and conventional targets.
//!
//! The owner consumes presentation-only GPU targets after one successful
//! product frame. Every captured frame is self-describing, hashed, and written
//! atomically beneath an exclusive external run root.

const std = @import("std");
const zm = @import("zmath");
const build_options = @import("build_options");
const engine = @import("incinerator_engine");
const renderer = @import("../renderer.zig");
const sdl = @import("../sdl.zig");
const neural_inputs = @import("neural_input_host.zig");

const c = sdl.c;
const contract = engine.neural_rendering;
const pixel_bytes: u32 = 4;
const channel_bytes: u32 = contract.cheap_width * contract.cheap_height * pixel_bytes;
const all_channel_bytes: u32 = channel_bytes * contract.channels.len;
const target_bytes: u32 = contract.target_width * contract.target_height * pixel_bytes;
const transfer_bytes: u32 = all_channel_bytes + target_bytes;

pub const Cohort = enum { overfit, train, validation, @"test", stress };

pub const Config = struct {
    root: []const u8,
    start_frame: u64,
    frame_stride: u64,
    frame_count: u64,
    cohort: Cohort,
    sequence: []const u8,
    camera_path: []const u8,
    content_digest: [32]u8,
};

pub const Diagnostics = struct {
    root: []const u8,
    cohort: Cohort,
    sequence: []const u8,
    camera_path: []const u8,
    recorded_frames: u64,
    requested_frames: u64,
    capture_failures: u64,
};

pub const Owner = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    device: *c.SDL_GPUDevice,
    source_format: c.SDL_GPUTextureFormat,
    source_bgra: bool,
    config: Config,
    root_storage: []u8,
    sequence_storage: []u8,
    camera_path_storage: []u8,
    index: std.Io.File,
    target: *c.SDL_GPUTexture,
    download: *c.SDL_GPUTransferBuffer,
    pixels: []u8,
    recorded: u64 = 0,
    capture_failures: u64 = 0,

    pub fn init(
        io: std.Io,
        allocator: std.mem.Allocator,
        gpu: *renderer.Renderer,
        config: Config,
    ) !Owner {
        if (!std.fs.path.isAbsolute(config.root)) return error.NeuralCaptureRootMustBeAbsolute;
        if (config.frame_stride == 0 or config.frame_count == 0) {
            return error.InvalidNeuralCaptureConfiguration;
        }
        if (config.sequence.len == 0 or config.camera_path.len == 0) {
            return error.NeuralCaptureSplitIdentityRequired;
        }
        try std.Io.Dir.cwd().createDir(
            io,
            config.root,
            std.Io.Dir.Permissions.fromMode(0o700),
        );
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        for ([_][]const u8{ "channels", "targets", "frames" }) |child| {
            const path = try std.fmt.bufPrint(&path_buffer, "{s}/{s}", .{ config.root, child });
            try std.Io.Dir.cwd().createDir(io, path, std.Io.Dir.Permissions.fromMode(0o700));
        }
        for (contract.channels) |channel| {
            const path = try std.fmt.bufPrint(
                &path_buffer,
                "{s}/channels/{s}",
                .{ config.root, contract.channelName(channel) },
            );
            try std.Io.Dir.cwd().createDir(io, path, std.Io.Dir.Permissions.fromMode(0o700));
        }
        const index_path = try std.fmt.bufPrint(&path_buffer, "{s}/frames.ndjson", .{config.root});
        const index = try std.Io.Dir.cwd().createFile(io, index_path, .{
            .exclusive = true,
            .permissions = std.Io.File.Permissions.fromMode(0o600),
        });
        errdefer index.close(io);

        const device = gpu.getDevice();
        const source_format = gpu.getSwapchainFormat();
        const target = c.SDL_CreateGPUTexture(device, &c.SDL_GPUTextureCreateInfo{
            .type = c.SDL_GPU_TEXTURETYPE_2D,
            .format = source_format,
            .usage = c.SDL_GPU_TEXTUREUSAGE_COLOR_TARGET | c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
            .width = contract.target_width,
            .height = contract.target_height,
            .layer_count_or_depth = 1,
            .num_levels = 1,
            .sample_count = c.SDL_GPU_SAMPLECOUNT_1,
            .props = 0,
        }) orelse return error.NeuralCaptureTargetCreationFailed;
        errdefer c.SDL_ReleaseGPUTexture(device, target);
        const download = c.SDL_CreateGPUTransferBuffer(device, &c.SDL_GPUTransferBufferCreateInfo{
            .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_DOWNLOAD,
            .size = transfer_bytes,
            .props = 0,
        }) orelse return error.NeuralCaptureTransferCreationFailed;
        errdefer c.SDL_ReleaseGPUTransferBuffer(device, download);
        const pixels = try allocator.alloc(u8, transfer_bytes);
        errdefer allocator.free(pixels);
        const root_storage = try allocator.dupe(u8, config.root);
        errdefer allocator.free(root_storage);
        const sequence_storage = try allocator.dupe(u8, config.sequence);
        errdefer allocator.free(sequence_storage);
        const camera_path_storage = try allocator.dupe(u8, config.camera_path);
        errdefer allocator.free(camera_path_storage);

        var result = Owner{
            .io = io,
            .allocator = allocator,
            .device = device,
            .source_format = source_format,
            .source_bgra = source_format == c.SDL_GPU_TEXTUREFORMAT_B8G8R8A8_UNORM or
                source_format == c.SDL_GPU_TEXTUREFORMAT_B8G8R8A8_UNORM_SRGB,
            .config = config,
            .root_storage = root_storage,
            .sequence_storage = sequence_storage,
            .camera_path_storage = camera_path_storage,
            .index = index,
            .target = target,
            .download = download,
            .pixels = pixels,
        };
        result.config.root = root_storage;
        result.config.sequence = sequence_storage;
        result.config.camera_path = camera_path_storage;
        try result.writeCaptureManifest(.partial);
        return result;
    }

    pub fn deinit(self: *Owner) void {
        self.index.sync(self.io) catch {};
        self.index.close(self.io);
        self.writeCaptureManifest(if (self.recorded == self.config.frame_count and
            self.capture_failures == 0)
            .complete
        else
            .partial) catch |err| std.debug.print(
            "Neural capture manifest failed: {s}\n",
            .{@errorName(err)},
        );
        c.SDL_ReleaseGPUTransferBuffer(self.device, self.download);
        c.SDL_ReleaseGPUTexture(self.device, self.target);
        self.allocator.free(self.pixels);
        self.allocator.free(self.camera_path_storage);
        self.allocator.free(self.sequence_storage);
        self.allocator.free(self.root_storage);
        self.* = undefined;
    }

    pub fn wantsFrame(self: *const Owner, presentation_frame: u64) bool {
        if (self.recorded >= self.config.frame_count or
            presentation_frame < self.config.start_frame) return false;
        return (presentation_frame - self.config.start_frame) % self.config.frame_stride == 0;
    }

    pub fn diagnostics(self: *const Owner) Diagnostics {
        return .{
            .root = self.config.root,
            .cohort = self.config.cohort,
            .sequence = self.config.sequence,
            .camera_path = self.config.camera_path,
            .recorded_frames = self.recorded,
            .requested_frames = self.config.frame_count,
            .capture_failures = self.capture_failures,
        };
    }

    pub fn record(
        self: *Owner,
        gpu: *renderer.Renderer,
        inputs: *const neural_inputs.Owner,
    ) !void {
        const frame = inputs.frameView();
        if (!self.wantsFrame(frame.presentation_frame)) return;
        errdefer {
            self.capture_failures +|= 1;
            self.writeCaptureManifest(.partial) catch {};
        }
        try self.readback(gpu, inputs);

        var raw_digests: [contract.channels.len][64]u8 = undefined;
        var ppm_digests: [contract.channels.len][64]u8 = undefined;
        for (contract.channels, 0..) |channel, index| {
            const start: usize = index * channel_bytes;
            const bytes = self.pixels[start .. start + channel_bytes];
            raw_digests[index] = try self.writeRawChannel(channel, frame.presentation_frame, bytes);
            ppm_digests[index] = try self.writePpmChannel(channel, frame.presentation_frame, bytes);
        }
        const target_pixels = self.pixels[all_channel_bytes..transfer_bytes];
        self.normalizeTarget(target_pixels);
        const target_raw_digest = try self.writeRawTarget(frame.presentation_frame, target_pixels);
        const target_ppm_digest = try self.writePpmTarget(frame.presentation_frame, target_pixels);
        try self.writeFrameManifest(
            inputs,
            raw_digests,
            ppm_digests,
            target_raw_digest,
            target_ppm_digest,
        );

        var summary = std.Io.Writer.Allocating.init(self.allocator);
        defer summary.deinit();
        try summary.writer.print(
            "{{\"schema\":2,\"frame_id\":\"{s}-frame-{d:0>8}\",\"cohort\":\"{s}\",\"sequence\":\"{s}\",\"camera_path\":\"{s}\",\"authority_tick\":{d},\"presentation_frame\":{d},\"frame_manifest\":\"frames/frame-{d:0>8}.json\",\"target_sha256\":\"{s}\"}}\n",
            .{
                self.config.sequence,
                frame.presentation_frame,
                @tagName(self.config.cohort),
                self.config.sequence,
                self.config.camera_path,
                frame.authority_tick,
                frame.presentation_frame,
                frame.presentation_frame,
                &target_raw_digest,
            },
        );
        try self.index.writeStreamingAll(self.io, summary.writer.buffered());
        try self.index.sync(self.io);
        self.recorded += 1;
        try self.writeCaptureManifest(if (self.recorded == self.config.frame_count and
            self.capture_failures == 0)
            .complete
        else
            .partial);
        std.debug.print(
            "NR0_CAPTURE frame={d} tick={d} cohort={s} sequence={s} target_sha256={s}\n",
            .{
                frame.presentation_frame,
                frame.authority_tick,
                @tagName(self.config.cohort),
                self.config.sequence,
                &target_raw_digest,
            },
        );
    }

    fn readback(
        self: *Owner,
        gpu: *renderer.Renderer,
        inputs: *const neural_inputs.Owner,
    ) !void {
        const source = gpu.getProductSceneTexture();
        const extent = gpu.getProductSceneExtent();
        const cmd = c.SDL_AcquireGPUCommandBuffer(self.device) orelse
            return error.NeuralCaptureCommandAcquireFailed;
        var submitted = false;
        defer if (!submitted) {
            _ = c.SDL_CancelGPUCommandBuffer(cmd);
        };
        c.SDL_BlitGPUTexture(cmd, &c.SDL_GPUBlitInfo{
            .source = .{
                .texture = source,
                .mip_level = 0,
                .layer_or_depth_plane = 0,
                .x = 0,
                .y = 0,
                .w = extent.width,
                .h = extent.height,
            },
            .destination = .{
                .texture = self.target,
                .mip_level = 0,
                .layer_or_depth_plane = 0,
                .x = 0,
                .y = 0,
                .w = contract.target_width,
                .h = contract.target_height,
            },
            .load_op = c.SDL_GPU_LOADOP_DONT_CARE,
            .clear_color = .{ .r = 0, .g = 0, .b = 0, .a = 1 },
            .flip_mode = c.SDL_FLIP_NONE,
            .filter = c.SDL_GPU_FILTER_LINEAR,
            .cycle = false,
            .padding1 = 0,
            .padding2 = 0,
            .padding3 = 0,
        });
        const copy = c.SDL_BeginGPUCopyPass(cmd) orelse
            return error.NeuralCaptureCopyPassBeginFailed;
        for (contract.channels, 0..) |channel, index| {
            downloadTexture(
                copy,
                inputs.target(channel),
                self.download,
                @intCast(index * channel_bytes),
                contract.cheap_width,
                contract.cheap_height,
            );
        }
        downloadTexture(
            copy,
            self.target,
            self.download,
            all_channel_bytes,
            contract.target_width,
            contract.target_height,
        );
        c.SDL_EndGPUCopyPass(copy);
        const fence = c.SDL_SubmitGPUCommandBufferAndAcquireFence(cmd) orelse
            return error.NeuralCaptureSubmissionFailed;
        submitted = true;
        defer c.SDL_ReleaseGPUFence(self.device, fence);
        if (!c.SDL_WaitForGPUFences(self.device, true, &fence, 1)) {
            return error.NeuralCaptureFenceWaitFailed;
        }
        const mapped = c.SDL_MapGPUTransferBuffer(self.device, self.download, false) orelse
            return error.NeuralCaptureTransferMapFailed;
        @memcpy(self.pixels, @as([*]const u8, @ptrCast(mapped))[0..transfer_bytes]);
        c.SDL_UnmapGPUTransferBuffer(self.device, self.download);
    }

    fn writeRawChannel(
        self: *Owner,
        channel: contract.Channel,
        frame: u64,
        pixels: []const u8,
    ) ![64]u8 {
        var relative: [192]u8 = undefined;
        const path = try std.fmt.bufPrint(
            &relative,
            "channels/{s}/frame-{d:0>8}.rgba8",
            .{ contract.channelName(channel), frame },
        );
        return self.writeExact(path, pixels);
    }

    fn writePpmChannel(
        self: *Owner,
        channel: contract.Channel,
        frame: u64,
        pixels: []const u8,
    ) ![64]u8 {
        var relative: [192]u8 = undefined;
        const path = try std.fmt.bufPrint(
            &relative,
            "channels/{s}/frame-{d:0>8}.ppm",
            .{ contract.channelName(channel), frame },
        );
        const debug_pixels = try self.allocator.dupe(u8, pixels);
        defer self.allocator.free(debug_pixels);
        var pixel: usize = 0;
        while (pixel < debug_pixels.len) : (pixel += 4) switch (channel) {
            .linear_depth => {
                const raw = @as(f32, @floatFromInt(debug_pixels[pixel])) / 255.0;
                const visible: u8 = @intFromFloat(@round(@sqrt(raw) * 255.0));
                debug_pixels[pixel] = visible;
                debug_pixels[pixel + 1] = visible;
                debug_pixels[pixel + 2] = visible;
            },
            .motion => {
                for (0..2) |component| {
                    const signed = @as(i16, debug_pixels[pixel + component]) - 128;
                    debug_pixels[pixel + component] = @intCast(std.math.clamp(
                        @as(i16, 128) + signed * 4,
                        0,
                        255,
                    ));
                }
            },
            else => {},
        };
        return self.writePpm(
            path,
            debug_pixels,
            contract.cheap_width,
            contract.cheap_height,
            false,
        );
    }

    fn writeRawTarget(self: *Owner, frame: u64, pixels: []const u8) ![64]u8 {
        var relative: [128]u8 = undefined;
        const path = try std.fmt.bufPrint(&relative, "targets/frame-{d:0>8}.rgba8", .{frame});
        return self.writeExact(path, pixels);
    }

    fn writePpmTarget(self: *Owner, frame: u64, pixels: []const u8) ![64]u8 {
        var relative: [128]u8 = undefined;
        const path = try std.fmt.bufPrint(&relative, "targets/frame-{d:0>8}.ppm", .{frame});
        return self.writePpm(
            path,
            pixels,
            contract.target_width,
            contract.target_height,
            false,
        );
    }

    fn normalizeTarget(self: *const Owner, pixels: []u8) void {
        if (!self.source_bgra) return;
        var offset: usize = 0;
        while (offset < pixels.len) : (offset += pixel_bytes) {
            std.mem.swap(u8, &pixels[offset], &pixels[offset + 2]);
        }
    }

    fn writeExact(self: *Owner, relative_path: []const u8, bytes: []const u8) ![64]u8 {
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const absolute = try std.fmt.bufPrint(&path_buffer, "{s}/{s}", .{ self.config.root, relative_path });
        try std.Io.Dir.cwd().writeFile(self.io, .{
            .sub_path = absolute,
            .data = bytes,
            .flags = .{ .exclusive = true },
        });
        return digest(bytes);
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
        const header = try std.fmt.bufPrint(&header_buffer, "P6\n{d} {d}\n255\n", .{ width, height });
        const rgb_count: usize = @as(usize, width) * height * 3;
        const output = try self.allocator.alloc(u8, header.len + rgb_count);
        defer self.allocator.free(output);
        @memcpy(output[0..header.len], header);
        var source: usize = 0;
        var destination = header.len;
        while (source < pixels.len) : (source += 4) {
            output[destination] = pixels[source + if (bgra) @as(usize, 2) else 0];
            output[destination + 1] = pixels[source + 1];
            output[destination + 2] = pixels[source + if (bgra) @as(usize, 0) else 2];
            destination += 3;
        }
        return self.writeExact(relative_path, output);
    }

    fn writeFrameManifest(
        self: *Owner,
        inputs: *const neural_inputs.Owner,
        raw_digests: [contract.channels.len][64]u8,
        ppm_digests: [contract.channels.len][64]u8,
        target_raw_digest: [64]u8,
        target_ppm_digest: [64]u8,
    ) !void {
        const frame = inputs.frameView();
        var allocating = std.Io.Writer.Allocating.init(self.allocator);
        defer allocating.deinit();
        const writer = &allocating.writer;
        try writer.print(
            "{{\n  \"schema\": 2,\n  \"input_schema\": {{\"version\": {d}, \"name\": \"{s}\", \"fingerprint\": \"{s}\"}},\n" ++
                "  \"shader_fingerprint\": \"{s}\", \"shader_sha256\": \"{s}\",\n  \"frame_id\": \"{s}-frame-{d:0>8}\",\n" ++
                "  \"cohort\": \"{s}\", \"sequence\": \"{s}\", \"camera_path\": \"{s}\",\n" ++
                "  \"authority_tick\": {d}, \"presentation_frame\": {d}, \"interpolation_alpha\": {d},\n" ++
                "  \"source_scene_size\": [{d}, {d}], \"target_size\": [{d}, {d}], \"cheap_size\": [{d}, {d}],\n" ++
                "  \"coordinate_system\": {{\"world\": \"right-handed +Y up -Z forward\", \"image_origin\": \"top-left\", \"sample\": \"pixel-center\"}},\n" ++
                "  \"camera\": {{\"near\": {d}, \"far\": {d}, \"jitter_pixels\": [{d}, {d}], \"history_reset\": \"{s}\", \"view\": ",
            .{
                contract.schema_version,
                contract.schema_name,
                contract.schema_fingerprint,
                neural_inputs.shader_fingerprint,
                &std.fmt.bytesToHex(neural_inputs.shaderDigest(), .lower),
                self.config.sequence,
                frame.presentation_frame,
                @tagName(self.config.cohort),
                self.config.sequence,
                self.config.camera_path,
                frame.authority_tick,
                frame.presentation_frame,
                frame.interpolation_alpha,
                frame.target_width,
                frame.target_height,
                contract.target_width,
                contract.target_height,
                contract.cheap_width,
                contract.cheap_height,
                frame.near,
                frame.far,
                frame.jitter_pixels[0],
                frame.jitter_pixels[1],
                @tagName(frame.history_reset),
            },
        );
        try writeMatrix(writer, inputs.cameraViewMatrix());
        try writer.writeAll(", \"view_projection\": ");
        if (inputs.drawsView().len != 0) {
            try writeMatrix(writer, inputs.drawsView()[0].view_projection);
        } else try writeMatrix(writer, zm.identity());
        try writer.print(
            "}},\n  \"effects\": {{\"seed\": {d}, \"exposure\": {d}}},\n  \"content\": {{\"source_revision\": \"{s}\", \"source_dirty\": {}, \"source_dirty_fingerprint\": \"{s}\", \"content_digest\": \"{s}\"}},\n  \"channels\": [\n",
            .{
                frame.effect_seed,
                frame.exposure,
                build_options.source_revision,
                build_options.source_dirty,
                build_options.source_dirty_fingerprint,
                &std.fmt.bytesToHex(self.config.content_digest, .lower),
            },
        );
        for (contract.channels, 0..) |channel, index| {
            try writer.print(
                "    {{\"name\":\"{s}\",\"format\":\"rgba8\",\"encoding\":\"{s}\",\"raw_bytes\":{d},\"raw_path\":\"channels/{s}/frame-{d:0>8}.rgba8\",\"raw_sha256\":\"{s}\",\"debug_path\":\"channels/{s}/frame-{d:0>8}.ppm\",\"debug_encoding\":\"{s}\",\"debug_sha256\":\"{s}\"}}{s}\n",
                .{
                    contract.channelName(channel),
                    contract.encoding(channel),
                    channel_bytes,
                    contract.channelName(channel),
                    frame.presentation_frame,
                    &raw_digests[index],
                    contract.channelName(channel),
                    frame.presentation_frame,
                    contract.debugEncoding(channel),
                    &ppm_digests[index],
                    if (index + 1 == contract.channels.len) "" else ",",
                },
            );
        }
        try writer.print(
            "  ],\n  \"target\": {{\"format\":\"rgba8\",\"source_gpu_format\":\"{s}\",\"raw_bytes\":{d},\"raw_path\":\"targets/frame-{d:0>8}.rgba8\",\"raw_sha256\":\"{s}\",\"debug_path\":\"targets/frame-{d:0>8}.ppm\",\"debug_sha256\":\"{s}\"}},\n  \"identities\": [\n",
            .{
                if (self.source_bgra) "bgra8" else "rgba8",
                target_bytes,
                frame.presentation_frame,
                &target_raw_digest,
                frame.presentation_frame,
                &target_ppm_digest,
            },
        );
        const draws = inputs.drawsView();
        for (draws, 0..) |draw, index| {
            try writer.print(
                "    {{\"stable_key\":\"{x:0>16}\",\"compact_rgb24\":{d},\"semantic\":\"{s}\",\"part\":\"{s}\",\"ordinal\":{d},\"identity\":",
                .{
                    draw.identity.stableKey(),
                    draw.identity.compactCode(),
                    @tagName(draw.identity.semantic),
                    @tagName(draw.identity.part),
                    draw.identity.ordinal,
                },
            );
            switch (draw.identity.identity) {
                .fixture => |value| try writer.print("{{\"kind\":\"fixture\",\"value\":{d}}}", .{value}),
                .persistent => |value| try writer.print("{{\"kind\":\"persistent\",\"namespace\":{d},\"local\":{d}}}", .{ value.namespace, value.local }),
                .replicated => |value| try writer.print("{{\"kind\":\"replicated\",\"index\":{d},\"generation\":{d}}}", .{ value.index, value.generation }),
            }
            try writer.print("}}{s}\n", .{if (index + 1 == draws.len) "" else ","});
        }
        try writer.writeAll("  ]\n}\n");
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const path = try std.fmt.bufPrint(
            &path_buffer,
            "{s}/frames/frame-{d:0>8}.json",
            .{ self.config.root, frame.presentation_frame },
        );
        try writeAtomic(self.io, path, writer.buffered());
    }

    const CaptureStatus = enum { partial, complete };

    fn writeCaptureManifest(self: *const Owner, status: CaptureStatus) !void {
        var allocating = std.Io.Writer.Allocating.init(self.allocator);
        defer allocating.deinit();
        const writer = &allocating.writer;
        try writer.print(
            "{{\n  \"schema\": 2,\n  \"status\": \"{s}\",\n  \"purpose\": \"NR0-B aligned presentation-only neural input and conventional target capture\",\n" ++
                "  \"platform\": \"macos-aarch64-metal\",\n  \"input_schema\": {{\"version\": {d}, \"name\": \"{s}\", \"fingerprint\": \"{s}\"}},\n" ++
                "  \"shader_fingerprint\": \"{s}\",\n  \"shader_sha256\": \"{s}\",\n  \"source_revision\": \"{s}\",\n  \"source_dirty\": {},\n  \"source_dirty_fingerprint\": \"{s}\",\n" ++
                "  \"content_digest\": \"{s}\",\n  \"cohort\": \"{s}\",\n  \"sequence\": \"{s}\",\n  \"camera_path\": \"{s}\",\n" ++
                "  \"input_size\": [{d}, {d}],\n  \"target_size\": [{d}, {d}],\n  \"raw_bytes_per_frame\": {d},\n" ++
                "  \"selection\": {{\"start_frame\": {d}, \"frame_stride\": {d}, \"requested_frames\": {d}}},\n" ++
                "  \"recorded_frames\": {d},\n  \"capture_failures\": {d},\n  \"frame_index\": \"frames.ndjson\"\n}}\n",
            .{
                @tagName(status),
                contract.schema_version,
                contract.schema_name,
                contract.schema_fingerprint,
                neural_inputs.shader_fingerprint,
                &std.fmt.bytesToHex(neural_inputs.shaderDigest(), .lower),
                build_options.source_revision,
                build_options.source_dirty,
                build_options.source_dirty_fingerprint,
                &std.fmt.bytesToHex(self.config.content_digest, .lower),
                @tagName(self.config.cohort),
                self.config.sequence,
                self.config.camera_path,
                contract.cheap_width,
                contract.cheap_height,
                contract.target_width,
                contract.target_height,
                transfer_bytes,
                self.config.start_frame,
                self.config.frame_stride,
                self.config.frame_count,
                self.recorded,
                self.capture_failures,
            },
        );
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, "{s}/capture.json", .{self.config.root});
        try writeAtomic(self.io, path, writer.buffered());
    }
};

fn writeMatrix(writer: *std.Io.Writer, matrix: zm.Mat) !void {
    const values = zm.matToArr(matrix);
    try writer.writeByte('[');
    for (values, 0..) |value, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.print("{d}", .{value});
    }
    try writer.writeByte(']');
}

fn writeAtomic(io: std.Io, path: []const u8, bytes: []const u8) !void {
    var atomic = try std.Io.Dir.cwd().createFileAtomic(io, path, .{
        .permissions = std.Io.File.Permissions.fromMode(0o600),
    });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, bytes);
    try atomic.file.sync(io);
    try atomic.replace(io);
}

fn digest(bytes: []const u8) [64]u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    return std.fmt.bytesToHex(hash, .lower);
}

fn downloadTexture(
    copy: *c.SDL_GPUCopyPass,
    texture: *c.SDL_GPUTexture,
    transfer: *c.SDL_GPUTransferBuffer,
    offset: u32,
    width: u32,
    height: u32,
) void {
    c.SDL_DownloadFromGPUTexture(copy, &c.SDL_GPUTextureRegion{
        .texture = texture,
        .mip_level = 0,
        .layer = 0,
        .x = 0,
        .y = 0,
        .z = 0,
        .w = width,
        .h = height,
        .d = 1,
    }, &c.SDL_GPUTextureTransferInfo{
        .transfer_buffer = transfer,
        .offset = offset,
        .pixels_per_row = width,
        .rows_per_layer = height,
    });
}

pub fn parseCohort(value: []const u8) !Cohort {
    return std.meta.stringToEnum(Cohort, value) orelse error.InvalidNeuralCaptureCohort;
}

test "capture frame selection is explicit and sequence-scoped" {
    const owner = Owner{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .device = undefined,
        .source_format = c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM,
        .source_bgra = false,
        .config = .{
            .root = "/tmp/not-opened",
            .start_frame = 10,
            .frame_stride = 3,
            .frame_count = 2,
            .cohort = .validation,
            .sequence = "route-a",
            .camera_path = "follow-a",
            .content_digest = @splat(0),
        },
        .root_storage = undefined,
        .sequence_storage = undefined,
        .camera_path_storage = undefined,
        .index = undefined,
        .target = undefined,
        .download = undefined,
        .pixels = undefined,
    };
    try std.testing.expect(!owner.wantsFrame(9));
    try std.testing.expect(owner.wantsFrame(10));
    try std.testing.expect(!owner.wantsFrame(11));
    try std.testing.expect(owner.wantsFrame(13));
    try std.testing.expectEqual(Cohort.stress, try parseCohort("stress"));
    try std.testing.expectError(error.InvalidNeuralCaptureCohort, parseCohort("random"));
}
