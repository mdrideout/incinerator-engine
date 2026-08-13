//! External dataset capture for native neural-renderer inputs.
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
const transfer_bytes: u32 = channel_bytes * contract.channels.len;
const controls_bytes: u32 = @intCast(contract.global_control_bytes);
const training_bytes: u32 = transfer_bytes + controls_bytes;

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
    config: Config,
    root_storage: []u8,
    sequence_storage: []u8,
    camera_path_storage: []u8,
    index: std.Io.File,
    download: *c.SDL_GPUTransferBuffer,
    pixels: []u8,
    recorded: u64 = 0,
    capture_failures: u64 = 0,
    last_input_command_encoding_ns: u64 = 0,
    total_input_command_encoding_ns: u64 = 0,
    maximum_input_command_encoding_ns: u64 = 0,

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
        for ([_][]const u8{ "channels", "controls", "frames" }) |child| {
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
            .config = config,
            .root_storage = root_storage,
            .sequence_storage = sequence_storage,
            .camera_path_storage = camera_path_storage,
            .index = index,
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
        inputs: *const neural_inputs.Owner,
    ) !void {
        const frame = inputs.frameView();
        if (!self.wantsFrame(frame.presentation_frame)) return;
        errdefer {
            self.capture_failures +|= 1;
            self.writeCaptureManifest(.partial) catch {};
        }
        try self.readback(inputs);

        var raw_digests: [contract.channels.len][64]u8 = undefined;
        var ppm_digests: [contract.channels.len][64]u8 = undefined;
        for (contract.channels, 0..) |channel, index| {
            const start: usize = index * channel_bytes;
            const bytes = self.pixels[start .. start + channel_bytes];
            raw_digests[index] = try self.writeRawChannel(channel, frame.presentation_frame, bytes);
            ppm_digests[index] = try self.writePpmChannel(channel, frame.presentation_frame, bytes);
        }
        const controls_digest = try self.writeGlobalControls(frame);
        const input_diagnostics = inputs.diagnostics();
        self.last_input_command_encoding_ns = input_diagnostics.last_command_encoding_ns;
        self.total_input_command_encoding_ns +|= input_diagnostics.last_command_encoding_ns;
        self.maximum_input_command_encoding_ns = @max(
            self.maximum_input_command_encoding_ns,
            input_diagnostics.last_command_encoding_ns,
        );
        try self.writeFrameManifest(inputs, controls_digest, raw_digests, ppm_digests);

        var summary = std.Io.Writer.Allocating.init(self.allocator);
        defer summary.deinit();
        try summary.writer.print(
            "{{\"schema\":5,\"frame_id\":\"{s}-frame-{d:0>8}\",\"cohort\":\"{s}\",\"sequence\":\"{s}\",\"camera_path\":\"{s}\",\"authority_tick\":{d},\"presentation_frame\":{d},\"frame_manifest\":\"frames/frame-{d:0>8}.json\"}}\n",
            .{
                self.config.sequence,
                frame.presentation_frame,
                @tagName(self.config.cohort),
                self.config.sequence,
                self.config.camera_path,
                frame.authority_tick,
                frame.presentation_frame,
                frame.presentation_frame,
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
            "NR_INPUT_CAPTURE frame={d} tick={d} cohort={s} sequence={s}\n",
            .{
                frame.presentation_frame,
                frame.authority_tick,
                @tagName(self.config.cohort),
                self.config.sequence,
            },
        );
    }

    fn readback(
        self: *Owner,
        inputs: *const neural_inputs.Owner,
    ) !void {
        const cmd = c.SDL_AcquireGPUCommandBuffer(self.device) orelse
            return error.NeuralCaptureCommandAcquireFailed;
        var submitted = false;
        defer if (!submitted) {
            _ = c.SDL_CancelGPUCommandBuffer(cmd);
        };
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

    fn writeGlobalControls(
        self: *Owner,
        frame: contract.Frame,
    ) ![64]u8 {
        const values = frame.global_controls.values();
        var bytes: [contract.global_control_bytes]u8 = undefined;
        for (values, 0..) |value, index| {
            const offset = index * @sizeOf(f32);
            std.mem.writeInt(
                u32,
                bytes[offset..][0..@sizeOf(f32)],
                @bitCast(value),
                .little,
            );
        }
        var relative: [192]u8 = undefined;
        const path = try std.fmt.bufPrint(
            &relative,
            "controls/frame-{d:0>8}.f32le",
            .{frame.presentation_frame},
        );
        return self.writeExact(path, &bytes);
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
        controls_digest: [64]u8,
        raw_digests: [contract.channels.len][64]u8,
        ppm_digests: [contract.channels.len][64]u8,
    ) !void {
        const frame = inputs.frameView();
        const input_diagnostics = inputs.diagnostics();
        var allocating = std.Io.Writer.Allocating.init(self.allocator);
        defer allocating.deinit();
        const writer = &allocating.writer;
        try writer.print(
            "{{\n  \"schema\": 6,\n  \"input_schema\": {{\"version\": {d}, \"name\": \"{s}\", \"fingerprint\": \"{s}\"}},\n" ++
                "  \"shader_fingerprint\": \"{s}\", \"shader_sha256\": \"{s}\",\n  \"frame_id\": \"{s}-frame-{d:0>8}\",\n" ++
                "  \"cohort\": \"{s}\", \"sequence\": \"{s}\", \"camera_path\": \"{s}\",\n" ++
                "  \"authority_tick\": {d}, \"presentation_frame\": {d}, \"interpolation_alpha\": {d},\n" ++
                "  \"input_size\": [{d}, {d}], \"paired_target_size\": [{d}, {d}],\n" ++
                "  \"sampling_map\": {{\"x\":{{\"scale_numerator\":{d},\"scale_denominator\":{d},\"target_center_to_source_index\":\"((target_x + 0.5) / 4) - 0.5\"}},\"y\":{{\"scale_numerator\":{d},\"scale_denominator\":{d},\"target_center_to_source_index\":\"((target_y + 0.5) / 4) - 0.5\"}},\"border\":\"clamp\"}},\n" ++
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
                contract.cheap_width,
                contract.cheap_height,
                contract.target_width,
                contract.target_height,
                contract.horizontal_scale_numerator,
                contract.horizontal_scale_denominator,
                contract.vertical_scale_numerator,
                contract.vertical_scale_denominator,
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
            "}},\n  \"effects\": {{\"seed\": {d}, \"exposure\": {d}}},\n" ++
                "  \"global_controls\": {{\"schema_name\":\"{s}\",\"encoding\":\"{s}\",\"order\":[\"sun_strength\",\"world_strength\",\"local_light_strength\",\"emissive_strength\"],\"values\":{{\"sun_strength\":{d},\"world_strength\":{d},\"local_light_strength\":{d},\"emissive_strength\":{d}}},\"raw_bytes\":{d},\"raw_path\":\"controls/frame-{d:0>8}.f32le\",\"raw_sha256\":\"{s}\"}},\n" ++
                "  \"input_raster_timing\": {{\"scope\":\"CPU command encoding only; GPU raster time unavailable\",\"last_command_encoding_ns\":{d},\"lifetime_total_command_encoding_ns\":{d},\"lifetime_maximum_command_encoding_ns\":{d}}},\n" ++
                "  \"content\": {{\"source_revision\": \"{s}\", \"source_dirty\": {}, \"source_dirty_fingerprint\": \"{s}\", \"content_digest\": \"{s}\"}},\n  \"channels\": [\n",
            .{
                frame.effect_seed,
                frame.exposure,
                contract.global_control_schema_name,
                contract.global_control_encoding,
                frame.global_controls.sun_strength,
                frame.global_controls.world_strength,
                frame.global_controls.local_light_strength,
                frame.global_controls.emissive_strength,
                contract.global_control_bytes,
                frame.presentation_frame,
                &controls_digest,
                input_diagnostics.last_command_encoding_ns,
                input_diagnostics.total_command_encoding_ns,
                input_diagnostics.maximum_command_encoding_ns,
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
        try writer.writeAll("  ],\n  \"identities\": [\n");
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
            "{{\n  \"schema\": 6,\n  \"status\": \"{s}\",\n  \"purpose\": \"native presentation-only neural inputs and frame-global controls for direct 640x360 offline target pairing\",\n" ++
                "  \"platform\": \"macos-aarch64-metal\",\n  \"input_schema\": {{\"version\": {d}, \"name\": \"{s}\", \"fingerprint\": \"{s}\"}},\n" ++
                "  \"shader_fingerprint\": \"{s}\",\n  \"shader_sha256\": \"{s}\",\n  \"source_revision\": \"{s}\",\n  \"source_dirty\": {},\n  \"source_dirty_fingerprint\": \"{s}\",\n" ++
                "  \"content_digest\": \"{s}\",\n  \"cohort\": \"{s}\",\n  \"sequence\": \"{s}\",\n  \"camera_path\": \"{s}\",\n" ++
                "  \"input_size\": [{d}, {d}],\n  \"paired_target_size\": [{d}, {d}],\n" ++
                "  \"sampling_map\": {{\"x\":{{\"scale_numerator\":{d},\"scale_denominator\":{d},\"target_center_to_source_index\":\"((target_x + 0.5) / 4) - 0.5\"}},\"y\":{{\"scale_numerator\":{d},\"scale_denominator\":{d},\"target_center_to_source_index\":\"((target_y + 0.5) / 4) - 0.5\"}},\"border\":\"clamp\"}},\n",
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
                contract.horizontal_scale_numerator,
                contract.horizontal_scale_denominator,
                contract.vertical_scale_numerator,
                contract.vertical_scale_denominator,
            },
        );
        try writer.print(
            "  \"global_control_schema\": {{\"name\":\"{s}\",\"encoding\":\"{s}\",\"order\":[\"sun_strength\",\"world_strength\",\"local_light_strength\",\"emissive_strength\"],\"count\":{d}}},\n" ++
                "  \"raw_channel_bytes_per_frame\": {d},\n  \"raw_global_control_bytes_per_frame\": {d},\n  \"raw_training_bytes_per_frame\": {d},\n" ++
                "  \"selection\": {{\"start_frame\": {d}, \"frame_stride\": {d}, \"requested_frames\": {d}}},\n" ++
                "  \"recorded_frames\": {d},\n  \"capture_failures\": {d},\n" ++
                "  \"input_raster_timing\": {{\"scope\":\"CPU command encoding only; GPU raster time unavailable\",\"last_command_encoding_ns\":{d},\"captured_total_command_encoding_ns\":{d},\"captured_maximum_command_encoding_ns\":{d}}},\n" ++
                "  \"frame_index\": \"frames.ndjson\"\n}}\n",
            .{
                contract.global_control_schema_name,
                contract.global_control_encoding,
                contract.global_control_count,
                transfer_bytes,
                controls_bytes,
                training_bytes,
                self.config.start_frame,
                self.config.frame_stride,
                self.config.frame_count,
                self.recorded,
                self.capture_failures,
                self.last_input_command_encoding_ns,
                self.total_input_command_encoding_ns,
                self.maximum_input_command_encoding_ns,
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
