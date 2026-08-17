//! Immutable NR-0004 target-frame package writer.
//!
//! The writer consumes the same presentation draws already mirrored into the
//! neural-input host. It serializes no simulation, ECS, physics, or session
//! state and owns no rendering decisions.

const std = @import("std");
const zm = @import("zmath");
const build_options = @import("build_options");
const engine = @import("incinerator_engine");
const neural_inputs = @import("neural_input_host.zig");
const target = @import("neural_target_contract.zig");

const contract = engine.neural_rendering;

comptime {
    std.debug.assert(contract.cheap_width == target.input_width);
    std.debug.assert(contract.cheap_height == target.input_height);
    std.debug.assert(contract.target_width == target.target_width);
    std.debug.assert(contract.target_height == target.target_height);
    std.debug.assert(contract.horizontal_scale_numerator == target.horizontal_scale_numerator);
    std.debug.assert(contract.horizontal_scale_denominator == target.horizontal_scale_denominator);
    std.debug.assert(contract.vertical_scale_numerator == target.vertical_scale_numerator);
    std.debug.assert(contract.vertical_scale_denominator == target.vertical_scale_denominator);
}

pub const Config = struct {
    root: []const u8,
    capture_root: []const u8,
    start_frame: u64,
    frame_stride: u64,
    frame_count: u64,
    sequence: []const u8,
    camera_path: []const u8,
    content_digest: [32]u8,
    scene: target.Scene,
};

pub const Diagnostics = struct {
    root: []const u8,
    recorded_frames: u64,
    requested_frames: u64,
    failures: u64,
};

pub const Owner = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    config: Config,
    root_storage: []u8,
    capture_root_storage: []u8,
    sequence_storage: []u8,
    camera_path_storage: []u8,
    index: std.Io.File,
    recorded: u64 = 0,
    failures: u64 = 0,

    pub fn init(io: std.Io, allocator: std.mem.Allocator, config: Config) !Owner {
        if (!std.fs.path.isAbsolute(config.root)) return error.NeuralTargetRootMustBeAbsolute;
        if (!std.fs.path.isAbsolute(config.capture_root)) {
            return error.NeuralTargetCaptureRootMustBeAbsolute;
        }
        if (config.frame_stride == 0 or config.frame_count == 0) {
            return error.InvalidNeuralTargetFrameConfiguration;
        }
        if (config.sequence.len == 0 or config.camera_path.len == 0) {
            return error.NeuralTargetFrameIdentityRequired;
        }
        try config.scene.validate();
        try std.Io.Dir.cwd().createDir(
            io,
            config.root,
            std.Io.Dir.Permissions.fromMode(0o700),
        );
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const frames_path = try std.fmt.bufPrint(&path_buffer, "{s}/frames", .{config.root});
        try std.Io.Dir.cwd().createDir(
            io,
            frames_path,
            std.Io.Dir.Permissions.fromMode(0o700),
        );
        const index_path = try std.fmt.bufPrint(&path_buffer, "{s}/frames.ndjson", .{config.root});
        const index = try std.Io.Dir.cwd().createFile(io, index_path, .{
            .exclusive = true,
            .permissions = std.Io.File.Permissions.fromMode(0o600),
        });
        errdefer index.close(io);

        const root_storage = try allocator.dupe(u8, config.root);
        errdefer allocator.free(root_storage);
        const capture_root_storage = try allocator.dupe(u8, config.capture_root);
        errdefer allocator.free(capture_root_storage);
        const sequence_storage = try allocator.dupe(u8, config.sequence);
        errdefer allocator.free(sequence_storage);
        const camera_path_storage = try allocator.dupe(u8, config.camera_path);
        errdefer allocator.free(camera_path_storage);

        var result = Owner{
            .io = io,
            .allocator = allocator,
            .config = config,
            .root_storage = root_storage,
            .capture_root_storage = capture_root_storage,
            .sequence_storage = sequence_storage,
            .camera_path_storage = camera_path_storage,
            .index = index,
        };
        result.config.root = root_storage;
        result.config.capture_root = capture_root_storage;
        result.config.sequence = sequence_storage;
        result.config.camera_path = camera_path_storage;
        try result.writeRootManifest(.partial);
        return result;
    }

    pub fn deinit(self: *Owner) void {
        self.index.sync(self.io) catch {};
        self.index.close(self.io);
        self.writeRootManifest(if (self.recorded == self.config.frame_count and self.failures == 0)
            .complete
        else
            .partial) catch |err| std.debug.print(
            "Neural target-frame manifest failed: {s}\n",
            .{@errorName(err)},
        );
        self.allocator.free(self.camera_path_storage);
        self.allocator.free(self.sequence_storage);
        self.allocator.free(self.capture_root_storage);
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
            .recorded_frames = self.recorded,
            .requested_frames = self.config.frame_count,
            .failures = self.failures,
        };
    }

    pub fn record(
        self: *Owner,
        inputs: *const neural_inputs.Owner,
        camera: target.Camera,
        scene: target.Scene,
        event: target.SequenceEvent,
    ) !void {
        const frame = inputs.frameView();
        if (!self.wantsFrame(frame.presentation_frame)) return;
        errdefer {
            self.failures +|= 1;
            self.writeRootManifest(.partial) catch {};
        }
        try camera.validate();
        try scene.validate();
        try event.validate();
        const draws = inputs.drawsView();
        var target_draw_count: usize = 0;
        for (draws) |draw| if (draw.target_source != null) {
            try draw.target_source.?.validate();
            target_draw_count += 1;
        };
        if (target_draw_count == 0) return error.NeuralTargetFrameHasNoDraws;

        var allocating = std.Io.Writer.Allocating.init(self.allocator);
        defer allocating.deinit();
        const writer = &allocating.writer;
        try writer.print(
            "{{\n  \"schema\": {d},\n  \"schema_name\": \"{s}\",\n  \"status\": \"complete\",\n" ++
                "  \"frame_id\": \"{s}-frame-{d:0>8}\",\n  \"sequence\": \"{s}\",\n  \"camera_path\": \"{s}\",\n" ++
                "  \"authority_tick\": {d},\n  \"presentation_frame\": {d},\n  \"interpolation_alpha\": {d},\n" ++
                "  \"source_capture_frame\": \"{s}/frames/frame-{d:0>8}.json\",\n" ++
                "  \"source\": {{\"revision\":\"{s}\",\"dirty\":{},\"dirty_fingerprint\":\"{s}\",\"content_sha256\":\"{s}\",\"input_schema\":\"{s}\",\"shader_fingerprint\":\"{s}\"}},\n" ++
                "  \"coordinate_system\": {{\"world\":\"right-handed +Y up -Z forward\",\"matrix_storage\":\"zmath row-major row-vector\",\"image_origin\":\"top-left\",\"sample\":\"pixel-center\"}},\n" ++
                "  \"input_extent\": [{d},{d}],\n  \"target_extent\": [{d},{d}],\n" ++
                "  \"sampling_map\": {{\"x\":{{\"scale_numerator\":{d},\"scale_denominator\":{d},\"target_center_to_source_index\":\"((target_x + 0.5) / 5) - 0.5\"}},\"y\":{{\"scale_numerator\":{d},\"scale_denominator\":{d},\"target_center_to_source_index\":\"((target_y + 0.5) / 5) - 0.5\"}},\"border\":\"clamp\"}},\n" ++
                "  \"exposure\": {d},\n  \"effect_seed\": {d},\n",
            .{
                target.schema_version,
                target.schema_name,
                self.config.sequence,
                frame.presentation_frame,
                self.config.sequence,
                self.config.camera_path,
                frame.authority_tick,
                frame.presentation_frame,
                frame.interpolation_alpha,
                self.config.capture_root,
                frame.presentation_frame,
                build_options.source_revision,
                build_options.source_dirty,
                build_options.source_dirty_fingerprint,
                &std.fmt.bytesToHex(self.config.content_digest, .lower),
                contract.schema_fingerprint,
                neural_inputs.shader_fingerprint,
                contract.cheap_width,
                contract.cheap_height,
                contract.target_width,
                contract.target_height,
                contract.horizontal_scale_numerator,
                contract.horizontal_scale_denominator,
                contract.vertical_scale_numerator,
                contract.vertical_scale_denominator,
                frame.exposure,
                frame.effect_seed,
            },
        );
        try writer.print(
            "  \"global_controls\": {{\"schema_name\":\"{s}\",\"sun_strength\":{d},\"world_strength\":{d},\"local_light_strength\":{d},\"emissive_strength\":{d},\"material_palette\":{d}}},\n" ++
                "  \"sequence_event\": {{\"segment\":\"{s}\",\"segment_index\":{d},\"sample_index\":{d},\"progress\":{d},\"reset\":{},\"controlled_change\":\"{s}\"}},\n" ++
                "  \"camera\": {{\"position\":",
            .{
                contract.global_control_schema_name,
                frame.global_controls.sun_strength,
                frame.global_controls.world_strength,
                frame.global_controls.local_light_strength,
                frame.global_controls.emissive_strength,
                frame.global_controls.material_palette,
                @tagName(event.segment),
                event.segment_index,
                event.sample_index,
                event.progress,
                event.reset,
                event.controlled_change,
            },
        );
        try writeFloat3(writer, camera.position);
        try writer.writeAll(",\"forward\":");
        try writeFloat3(writer, camera.forward);
        try writer.writeAll(",\"up\":");
        try writeFloat3(writer, camera.up);
        try writer.print(",\"vertical_fov_radians\":{d},\"near\":{d},\"far\":{d},\"view\":", .{
            camera.vertical_fov_radians,
            frame.near,
            frame.far,
        });
        try writeMatrix(writer, inputs.cameraViewMatrix());
        try writer.writeAll(",\"view_projection\":");
        try writeMatrix(writer, draws[0].view_projection);
        try writer.writeAll("},\n  \"scene\": {");
        try writer.print(
            "\"id\":\"{s}\",\"fingerprint\":\"{s}\",\"sun_direction\":",
            .{ scene.id, scene.fingerprint },
        );
        try writeFloat3(writer, scene.sun_direction);
        try writer.writeAll(",\"sun_color\":");
        try writeFloat3(writer, scene.sun_color);
        try writer.print(",\"sun_strength\":{d},\"sun_angle_radians\":{d},\"world_color\":", .{
            scene.sun_strength,
            scene.sun_angle_radians,
        });
        try writeFloat3(writer, scene.world_color);
        try writer.print(",\"world_strength\":{d},\"local_light_position\":", .{
            scene.world_strength,
        });
        try writeFloat3(writer, scene.local_light_position);
        try writer.writeAll(",\"local_light_color\":");
        try writeFloat3(writer, scene.local_light_color);
        try writer.print(",\"local_light_strength\":{d},\"local_light_radius\":{d}}},\n  \"draws\": [\n", .{
            scene.local_light_strength,
            scene.local_light_radius,
        });

        var emitted: usize = 0;
        for (draws) |draw| {
            const source = draw.target_source orelse continue;
            try writer.print(
                "    {{\"label\":\"{s}\",\"stable_key\":\"{x:0>16}\",\"compact_rgb24\":{d},\"semantic\":\"{s}\",\"part\":\"{s}\",\"ordinal\":{d},\"identity\":",
                .{
                    source.label,
                    draw.identity.stableKey(),
                    draw.identity.compactCode(),
                    @tagName(draw.identity.semantic),
                    @tagName(draw.identity.part),
                    draw.identity.ordinal,
                },
            );
            try writeIdentity(writer, draw.identity.identity);
            try writer.print(",\"shape\":\"{s}\",\"material\":\"{s}\",\"material_response\":{{\"roughness\":{d},\"metallic\":{d},\"transmission\":{d},\"ior\":{d},\"emission_strength\":{d},\"sheen\":{d},\"subsurface\":{d},\"pattern\":\"{s}\",\"pattern_scale\":{d},\"pattern_detail\":{d},\"bump_strength\":{d},\"bump_distance\":{d}}},\"base_color\":", .{
                @tagName(source.shape),
                @tagName(source.material),
                source.material_response.roughness,
                source.material_response.metallic,
                source.material_response.transmission,
                source.material_response.ior,
                source.material_response.emission_strength,
                source.material_response.sheen,
                source.material_response.subsurface,
                @tagName(source.material_response.pattern),
                source.material_response.pattern_scale,
                source.material_response.pattern_detail,
                source.material_response.bump_strength,
                source.material_response.bump_distance,
            });
            try writeFloat4(writer, draw.base_color);
            try writer.writeAll(",\"transform\":{\"scale\":");
            try writeFloat3(writer, source.transform.scale);
            try writer.writeAll(",\"rotation_xyz\":");
            try writeFloat3(writer, source.transform.rotation_xyz);
            try writer.writeAll(",\"translation\":");
            try writeFloat3(writer, source.transform.translation);
            try writer.writeAll("},\"model_matrix\":");
            try writeMatrix(writer, draw.model);
            emitted += 1;
            try writer.print("}}{s}\n", .{if (emitted == target_draw_count) "" else ","});
        }
        try writer.writeAll("  ]\n}\n");

        var relative: [160]u8 = undefined;
        const relative_path = try std.fmt.bufPrint(
            &relative,
            "frames/frame-{d:0>8}.json",
            .{frame.presentation_frame},
        );
        var absolute: [std.fs.max_path_bytes]u8 = undefined;
        const absolute_path = try std.fmt.bufPrint(
            &absolute,
            "{s}/{s}",
            .{ self.config.root, relative_path },
        );
        try writeAtomic(self.io, absolute_path, writer.buffered());
        const frame_digest = digest(writer.buffered());
        var summary = std.Io.Writer.Allocating.init(self.allocator);
        defer summary.deinit();
        try summary.writer.print(
            "{{\"schema\":{d},\"frame_id\":\"{s}-frame-{d:0>8}\",\"presentation_frame\":{d},\"segment\":\"{s}\",\"segment_index\":{d},\"sample_index\":{d},\"path\":\"{s}\",\"sha256\":\"{s}\",\"draw_count\":{d}}}\n",
            .{
                target.schema_version,
                self.config.sequence,
                frame.presentation_frame,
                frame.presentation_frame,
                @tagName(event.segment),
                event.segment_index,
                event.sample_index,
                relative_path,
                &frame_digest,
                target_draw_count,
            },
        );
        try self.index.writeStreamingAll(self.io, summary.writer.buffered());
        try self.index.sync(self.io);
        self.recorded += 1;
        try self.writeRootManifest(if (self.recorded == self.config.frame_count and self.failures == 0)
            .complete
        else
            .partial);
        std.debug.print(
            "NR4_TARGET_FRAME frame={d} draws={d} sha256={s}\n",
            .{ frame.presentation_frame, target_draw_count, &frame_digest },
        );
    }

    const Status = enum { partial, complete };

    fn writeRootManifest(self: *const Owner, status: Status) !void {
        var allocating = std.Io.Writer.Allocating.init(self.allocator);
        defer allocating.deinit();
        try allocating.writer.print(
            "{{\n  \"schema\": {d},\n  \"schema_name\": \"{s}\",\n  \"status\": \"{s}\",\n" ++
                "  \"purpose\": \"native 256x144 input lineage for direct native 1280x720 Blender target pairs\",\n" ++
                "  \"source_revision\": \"{s}\",\n  \"source_dirty\": {},\n  \"source_dirty_fingerprint\": \"{s}\",\n" ++
                "  \"content_sha256\": \"{s}\",\n  \"scene_id\": \"{s}\",\n  \"scene_fingerprint\": \"{s}\",\n" ++
                "  \"capture_root\": \"{s}\",\n  \"sequence\": \"{s}\",\n  \"camera_path\": \"{s}\",\n" ++
                "  \"input_extent\": [{d},{d}],\n  \"target_extent\": [{d},{d}],\n" ++
                "  \"sampling_map\": {{\"x\":{{\"scale_numerator\":{d},\"scale_denominator\":{d},\"target_center_to_source_index\":\"((target_x + 0.5) / 5) - 0.5\"}},\"y\":{{\"scale_numerator\":{d},\"scale_denominator\":{d},\"target_center_to_source_index\":\"((target_y + 0.5) / 5) - 0.5\"}},\"border\":\"clamp\"}},\n" ++
                "  \"global_control_schema\": {{\"name\":\"{s}\",\"encoding\":\"{s}\",\"order\":[\"sun_strength\",\"world_strength\",\"local_light_strength\",\"emissive_strength\",\"material_palette\"],\"count\":{d}}},\n" ++
                "  \"selection\": {{\"start_frame\":{d},\"frame_stride\":{d},\"requested_frames\":{d}}},\n" ++
                "  \"recorded_frames\": {d},\n  \"failures\": {d},\n  \"frame_index\": \"frames.ndjson\"\n}}\n",
            .{
                target.schema_version,
                target.schema_name,
                @tagName(status),
                build_options.source_revision,
                build_options.source_dirty,
                build_options.source_dirty_fingerprint,
                &std.fmt.bytesToHex(self.config.content_digest, .lower),
                self.config.scene.id,
                self.config.scene.fingerprint,
                self.config.capture_root,
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
                contract.global_control_schema_name,
                contract.global_control_encoding,
                contract.global_control_count,
                self.config.start_frame,
                self.config.frame_stride,
                self.config.frame_count,
                self.recorded,
                self.failures,
            },
        );
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, "{s}/target-frames.json", .{self.config.root});
        try writeAtomic(self.io, path, allocating.writer.buffered());
    }
};

fn writeIdentity(writer: *std.Io.Writer, identity: contract.Identity) !void {
    switch (identity) {
        .fixture => |value| try writer.print("{{\"kind\":\"fixture\",\"value\":{d}}}", .{value}),
        .persistent => |value| try writer.print(
            "{{\"kind\":\"persistent\",\"namespace\":{d},\"local\":{d}}}",
            .{ value.namespace, value.local },
        ),
        .replicated => |value| try writer.print(
            "{{\"kind\":\"replicated\",\"index\":{d},\"generation\":{d}}}",
            .{ value.index, value.generation },
        ),
    }
}

fn writeFloat3(writer: *std.Io.Writer, values: [3]f32) !void {
    try writer.print("[{d},{d},{d}]", .{ values[0], values[1], values[2] });
}

fn writeFloat4(writer: *std.Io.Writer, values: [4]f32) !void {
    try writer.print("[{d},{d},{d},{d}]", .{ values[0], values[1], values[2], values[3] });
}

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

test "target frame selection is explicit" {
    const owner = Owner{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .config = .{
            .root = "/tmp/not-opened",
            .capture_root = "/tmp/not-opened-capture",
            .start_frame = 12,
            .frame_stride = 4,
            .frame_count = 2,
            .sequence = "nr4-still",
            .camera_path = "orbit-wide",
            .content_digest = @splat(0),
            .scene = .{
                .id = "test",
                .fingerprint = "test-v1",
                .sun_direction = .{ 0, -1, 0 },
                .sun_color = .{ 1, 1, 1 },
                .sun_strength = 1,
                .sun_angle_radians = 0.1,
                .world_color = .{ 0, 0, 0 },
                .world_strength = 0,
                .local_light_position = .{ 0, 2, 0 },
                .local_light_color = .{ 1, 1, 1 },
                .local_light_strength = 0,
                .local_light_radius = 0.5,
            },
        },
        .root_storage = undefined,
        .capture_root_storage = undefined,
        .sequence_storage = undefined,
        .camera_path_storage = undefined,
        .index = undefined,
    };
    try std.testing.expect(!owner.wantsFrame(11));
    try std.testing.expect(owner.wantsFrame(12));
    try std.testing.expect(!owner.wantsFrame(13));
    try std.testing.expect(owner.wantsFrame(16));
}
