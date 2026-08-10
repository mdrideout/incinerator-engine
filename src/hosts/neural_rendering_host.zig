//! NR5-E interactive spatial-candidate evaluation host for Apple Silicon.
//!
//! The host consumes only the engine-owned neural-input render targets. It
//! validates one immutable external trial bundle, stages the six schema-v3
//! channels through Core ML, and optionally replaces only scene presentation.
//! Deterministic authority and post-scene UI never enter this boundary.

const std = @import("std");
const engine = @import("incinerator_engine");
const renderer = @import("../renderer.zig");
const sdl = @import("../sdl.zig");
const neural_inputs = @import("neural_input_host.zig");
const trial_bundle = @import("neural_trial_bundle.zig");

const c = sdl.c;
const contract = engine.neural_rendering;
const pixel_bytes: u32 = 4;
const channel_bytes: u32 = contract.cheap_width * contract.cheap_height * pixel_bytes;
const input_bytes: u32 = channel_bytes * contract.channels.len;
const output_bytes: u32 = contract.target_width * contract.target_height * pixel_bytes;
const error_capacity = 2048;

const NativeModel = opaque {};

extern fn incinerator_nr_model_create(
    model_path: [*:0]const u8,
    semantic_codes: [*]const u32,
    semantic_code_count: usize,
    instance_codes: [*]const u32,
    instance_code_count: usize,
    control_minimum: [*]const f32,
    control_maximum: [*]const f32,
    error_text: [*]u8,
    error_capacity_value: usize,
) ?*NativeModel;
extern fn incinerator_nr_model_destroy(handle: *NativeModel) void;
extern fn incinerator_nr_model_predict(
    handle: *NativeModel,
    appearance_pixels: [*]const u8,
    linear_depth_pixels: [*]const u8,
    world_normal_pixels: [*]const u8,
    motion_pixels: [*]const u8,
    semantic_pixels: [*]const u8,
    instance_pixels: [*]const u8,
    input_width: u32,
    input_height: u32,
    global_controls: [*]const f32,
    output_pixels: [*]u8,
    output_width: u32,
    output_height: u32,
    unknown_semantic_pixels: *u64,
    unknown_instance_pixels: *u64,
    inference_ms: *f64,
    error_text: [*]u8,
    error_capacity_value: usize,
) bool;

pub const OutputView = struct {
    binding: *const anyopaque,
    width: u32,
    height: u32,
};

pub const Diagnostics = struct {
    model_loaded: bool,
    enabled: bool,
    output_ready: bool,
    bundle_root: []const u8,
    checkpoint_digest: []const u8,
    manifest_digest: [64]u8,
    readbacks: u64,
    predictions: u64,
    failures: u64,
    last_source_tick: u64,
    last_source_frame: u64,
    last_presented_source_frame: u64,
    last_unknown_semantic_pixels: u64,
    last_unknown_instance_pixels: u64,
    last_inference_ms: f64,
    mean_staged_pipeline_ms: f64,
    maximum_staged_pipeline_ms: f64,
    last_error: []const u8,
    output: OutputView,
};

pub const Owner = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    device: *c.SDL_GPUDevice,
    bundle: trial_bundle.Loaded,
    model: ?*NativeModel = null,
    output_texture: *c.SDL_GPUTexture,
    output_binding: c.SDL_GPUTextureSamplerBinding,
    download: *c.SDL_GPUTransferBuffer,
    upload: *c.SDL_GPUTransferBuffer,
    input_pixels: []u8,
    output_pixels: []u8,
    inference_enabled: bool = false,
    presentation_enabled: bool = false,
    output_ready: bool = false,
    readbacks: u64 = 0,
    predictions: u64 = 0,
    failures: u64 = 0,
    last_source_tick: u64 = 0,
    last_source_frame: u64 = 0,
    last_presented_source_frame: u64 = 0,
    last_unknown_semantic_pixels: u64 = 0,
    last_unknown_instance_pixels: u64 = 0,
    last_inference_ms: f64 = 0,
    staged_pipeline_total_ns: u64 = 0,
    staged_pipeline_max_ns: u64 = 0,
    last_error_storage: [error_capacity]u8 = @splat(0),

    pub fn init(
        io: std.Io,
        allocator: std.mem.Allocator,
        gpu: *renderer.Renderer,
        bundle_root: []const u8,
    ) !Owner {
        var bundle = try trial_bundle.Loaded.load(io, allocator, bundle_root);
        errdefer bundle.deinit();
        const device = gpu.getDevice();
        const output_texture = c.SDL_CreateGPUTexture(device, &c.SDL_GPUTextureCreateInfo{
            .type = c.SDL_GPU_TEXTURETYPE_2D,
            .format = c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM,
            .usage = c.SDL_GPU_TEXTUREUSAGE_SAMPLER | c.SDL_GPU_TEXTUREUSAGE_COLOR_TARGET,
            .width = contract.target_width,
            .height = contract.target_height,
            .layer_count_or_depth = 1,
            .num_levels = 1,
            .sample_count = c.SDL_GPU_SAMPLECOUNT_1,
            .props = 0,
        }) orelse return error.NeuralOutputTextureCreationFailed;
        errdefer c.SDL_ReleaseGPUTexture(device, output_texture);
        const download = c.SDL_CreateGPUTransferBuffer(device, &c.SDL_GPUTransferBufferCreateInfo{
            .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_DOWNLOAD,
            .size = input_bytes,
            .props = 0,
        }) orelse return error.NeuralDownloadBufferCreationFailed;
        errdefer c.SDL_ReleaseGPUTransferBuffer(device, download);
        const upload = c.SDL_CreateGPUTransferBuffer(device, &c.SDL_GPUTransferBufferCreateInfo{
            .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
            .size = output_bytes,
            .props = 0,
        }) orelse return error.NeuralUploadBufferCreationFailed;
        errdefer c.SDL_ReleaseGPUTransferBuffer(device, upload);
        const input_pixels = try allocator.alloc(u8, input_bytes);
        errdefer allocator.free(input_pixels);
        const output_pixels = try allocator.alloc(u8, output_bytes);
        errdefer allocator.free(output_pixels);
        var result = Owner{
            .io = io,
            .allocator = allocator,
            .device = device,
            .bundle = bundle,
            .output_texture = output_texture,
            .output_binding = .{
                .texture = output_texture,
                .sampler = gpu.getDefaultSampler(),
            },
            .download = download,
            .upload = upload,
            .input_pixels = input_pixels,
            .output_pixels = output_pixels,
        };
        result.loadModel();
        return result;
    }

    pub fn deinit(self: *Owner, gpu: *renderer.Renderer) void {
        gpu.clearScenePresentationOverride();
        _ = c.SDL_WaitForGPUIdle(self.device);
        std.debug.print(
            "NR5_E_RUNTIME_RESULT bundle={s} enabled={} readbacks={d} predictions={d} " ++
                "failures={d} last_inference_ms={d:.3} staged_pipeline_mean_ms={d:.3} " ++
                "staged_pipeline_max_ms={d:.3} unknown_semantic={d} unknown_instance={d} error={s}\n",
            .{
                self.bundle.root,
                self.presentation_enabled,
                self.readbacks,
                self.predictions,
                self.failures,
                self.last_inference_ms,
                if (self.readbacks == 0) 0 else @as(f64, @floatFromInt(self.staged_pipeline_total_ns)) /
                    @as(f64, @floatFromInt(self.readbacks)) /
                    std.time.ns_per_ms,
                @as(f64, @floatFromInt(self.staged_pipeline_max_ns)) / std.time.ns_per_ms,
                self.last_unknown_semantic_pixels,
                self.last_unknown_instance_pixels,
                self.lastError(),
            },
        );
        if (self.model) |model| incinerator_nr_model_destroy(model);
        self.allocator.free(self.input_pixels);
        self.allocator.free(self.output_pixels);
        c.SDL_ReleaseGPUTransferBuffer(self.device, self.download);
        c.SDL_ReleaseGPUTransferBuffer(self.device, self.upload);
        c.SDL_ReleaseGPUTexture(self.device, self.output_texture);
        self.bundle.deinit();
        self.* = undefined;
    }

    pub fn toggle(self: *Owner) bool {
        if (!self.inference_enabled) return false;
        self.presentation_enabled = !self.presentation_enabled;
        return self.presentation_enabled;
    }

    pub fn setPresentationEnabled(self: *Owner, enabled: bool) bool {
        self.presentation_enabled = enabled and self.inference_enabled;
        return self.presentation_enabled;
    }

    pub fn prepareFrame(self: *Owner, gpu: *renderer.Renderer) void {
        if (!self.output_ready) {
            gpu.clearScenePresentationOverride();
            return;
        }
        self.uploadOutput() catch |err| {
            self.disableAfterFailure(@errorName(err));
            gpu.clearScenePresentationOverride();
            return;
        };
        if (self.presentation_enabled) {
            self.last_presented_source_frame = self.last_source_frame;
            gpu.setScenePresentationOverride(
                self.output_texture,
                contract.target_width,
                contract.target_height,
            );
        } else {
            gpu.clearScenePresentationOverride();
        }
    }

    fn uploadOutput(self: *Owner) !void {
        const mapped = c.SDL_MapGPUTransferBuffer(self.device, self.upload, true) orelse
            return error.NeuralUploadMapFailed;
        @memcpy(@as([*]u8, @ptrCast(mapped))[0..output_bytes], self.output_pixels);
        c.SDL_UnmapGPUTransferBuffer(self.device, self.upload);
        const cmd = c.SDL_AcquireGPUCommandBuffer(self.device) orelse
            return error.NeuralUploadCommandAcquireFailed;
        var submitted = false;
        defer if (!submitted) {
            _ = c.SDL_CancelGPUCommandBuffer(cmd);
        };
        const copy = c.SDL_BeginGPUCopyPass(cmd) orelse
            return error.NeuralUploadCopyPassBeginFailed;
        c.SDL_UploadToGPUTexture(copy, &c.SDL_GPUTextureTransferInfo{
            .transfer_buffer = self.upload,
            .offset = 0,
            .pixels_per_row = contract.target_width,
            .rows_per_layer = contract.target_height,
        }, &c.SDL_GPUTextureRegion{
            .texture = self.output_texture,
            .mip_level = 0,
            .layer = 0,
            .x = 0,
            .y = 0,
            .z = 0,
            .w = contract.target_width,
            .h = contract.target_height,
            .d = 1,
        }, true);
        c.SDL_EndGPUCopyPass(copy);
        if (!c.SDL_SubmitGPUCommandBuffer(cmd)) return error.NeuralUploadSubmissionFailed;
        submitted = true;
    }

    pub fn readbackAndPredict(
        self: *Owner,
        inputs: *const neural_inputs.Owner,
    ) void {
        if (!self.inference_enabled) return;
        const started_ns = monotonicNowNs(self.io);
        self.readback(inputs) catch |err| {
            self.disableAfterFailure(@errorName(err));
            return;
        };
        self.readbacks +|= 1;
        self.predict(inputs.frameView());
        const duration_ns = monotonicNowNs(self.io) -| started_ns;
        self.staged_pipeline_total_ns +|= duration_ns;
        self.staged_pipeline_max_ns = @max(self.staged_pipeline_max_ns, duration_ns);
    }

    pub fn diagnostics(self: *const Owner) Diagnostics {
        return .{
            .model_loaded = self.model != null,
            .enabled = self.presentation_enabled,
            .output_ready = self.output_ready,
            .bundle_root = self.bundle.root,
            .checkpoint_digest = self.bundle.checkpointDigest(),
            .manifest_digest = std.fmt.bytesToHex(self.bundle.manifest_digest, .lower),
            .readbacks = self.readbacks,
            .predictions = self.predictions,
            .failures = self.failures,
            .last_source_tick = self.last_source_tick,
            .last_source_frame = self.last_source_frame,
            .last_presented_source_frame = self.last_presented_source_frame,
            .last_unknown_semantic_pixels = self.last_unknown_semantic_pixels,
            .last_unknown_instance_pixels = self.last_unknown_instance_pixels,
            .last_inference_ms = self.last_inference_ms,
            .mean_staged_pipeline_ms = if (self.readbacks == 0) 0 else @as(f64, @floatFromInt(self.staged_pipeline_total_ns)) /
                @as(f64, @floatFromInt(self.readbacks)) /
                std.time.ns_per_ms,
            .maximum_staged_pipeline_ms = @as(f64, @floatFromInt(self.staged_pipeline_max_ns)) / std.time.ns_per_ms,
            .last_error = self.lastError(),
            .output = .{
                .binding = @ptrCast(&self.output_binding),
                .width = contract.target_width,
                .height = contract.target_height,
            },
        };
    }

    /// Write one immutable visual/runtime checkpoint for automated graphical
    /// acceptance. This is external evaluation evidence, never training data
    /// and never a promoted model bundle.
    pub fn writeEvaluationEvidence(self: *const Owner, root: []const u8) !void {
        if (!std.fs.path.isAbsolute(root)) return error.NeuralTrialEvidenceRootMustBeAbsolute;
        if (!self.output_ready) return error.NeuralTrialEvidenceRequiresOutput;
        std.Io.Dir.cwd().createDir(
            self.io,
            root,
            std.Io.Dir.Permissions.fromMode(0o700),
        ) catch |err| if (err != error.PathAlreadyExists) return err;
        const appearance = self.channelPixels(.appearance);
        const cheap_rgb = try self.allocator.alloc(
            u8,
            contract.target_width * contract.target_height * 3,
        );
        defer self.allocator.free(cheap_rgb);
        for (0..contract.target_height) |y| {
            const source_y = contract.nearestSourceIndex(@intCast(y), contract.cheap_height);
            for (0..contract.target_width) |x| {
                const source_x = contract.nearestSourceIndex(@intCast(x), contract.cheap_width);
                const source = (@as(usize, source_y) * contract.cheap_width + source_x) * 4;
                const destination = (y * contract.target_width + x) * 3;
                @memcpy(cheap_rgb[destination..][0..3], appearance[source..][0..3]);
            }
        }
        const neural_rgb = try rgbaToRgb(
            self.allocator,
            self.output_pixels,
            contract.target_width,
            contract.target_height,
        );
        defer self.allocator.free(neural_rgb);
        const appearance_rgb = try rgbaToRgb(
            self.allocator,
            appearance,
            contract.cheap_width,
            contract.cheap_height,
        );
        defer self.allocator.free(appearance_rgb);
        const comparison_rgb = try self.allocator.alloc(
            u8,
            contract.target_width * 2 * contract.target_height * 3,
        );
        defer self.allocator.free(comparison_rgb);
        for (0..contract.target_height) |y| {
            const cheap_start = y * contract.target_width * 3;
            const comparison_start = y * contract.target_width * 2 * 3;
            @memcpy(
                comparison_rgb[comparison_start..][0 .. contract.target_width * 3],
                cheap_rgb[cheap_start..][0 .. contract.target_width * 3],
            );
            @memcpy(
                comparison_rgb[comparison_start + contract.target_width * 3 ..][0 .. contract.target_width * 3],
                neural_rgb[cheap_start..][0 .. contract.target_width * 3],
            );
        }
        try self.writePpm(root, "appearance-160x90.ppm", contract.cheap_width, contract.cheap_height, appearance_rgb);
        try self.writePpm(root, "cheap-nearest-400x225.ppm", contract.target_width, contract.target_height, cheap_rgb);
        try self.writePpm(root, "neural-400x225.ppm", contract.target_width, contract.target_height, neural_rgb);
        try self.writePpm(root, "comparison-cheap-left-neural-right-800x225.ppm", contract.target_width * 2, contract.target_height, comparison_rgb);
        const snapshot = self.diagnostics();
        const report = try std.json.Stringify.valueAlloc(self.allocator, .{
            .schema = @as(u16, 1),
            .phase = "NR5-E",
            .status = "complete",
            .training_eligible = false,
            .promotion_authorized = false,
            .bundle_root = snapshot.bundle_root,
            .bundle_manifest_sha256 = snapshot.manifest_digest[0..],
            .checkpoint_sha256 = snapshot.checkpoint_digest,
            .source_tick = snapshot.last_source_tick,
            .source_frame = snapshot.last_source_frame,
            .presented_source_frame = snapshot.last_presented_source_frame,
            .readbacks = snapshot.readbacks,
            .predictions = snapshot.predictions,
            .failures = snapshot.failures,
            .inference_ms = snapshot.last_inference_ms,
            .staged_pipeline_mean_ms = snapshot.mean_staged_pipeline_ms,
            .staged_pipeline_maximum_ms = snapshot.maximum_staged_pipeline_ms,
            .unknown_semantic_pixels = snapshot.last_unknown_semantic_pixels,
            .unknown_instance_pixels = snapshot.last_unknown_instance_pixels,
            .files = [_][]const u8{
                "appearance-160x90.ppm",
                "cheap-nearest-400x225.ppm",
                "neural-400x225.ppm",
                "comparison-cheap-left-neural-right-800x225.ppm",
            },
        }, .{ .whitespace = .indent_2 });
        defer self.allocator.free(report);
        try self.writeExclusive(root, "runtime.json", report);
        std.debug.print("NR5_E_TRIAL_EVIDENCE root={s}\n", .{root});
    }

    fn loadModel(self: *Owner) void {
        const path = self.allocator.dupeZ(u8, self.bundle.model_path) catch {
            self.setError("model path allocation failed");
            self.failures +|= 1;
            return;
        };
        defer self.allocator.free(path);
        const semantic_codes = self.codes(self.bundle.semanticVocabulary()) catch {
            self.setError("semantic vocabulary allocation failed");
            self.failures +|= 1;
            return;
        };
        defer self.allocator.free(semantic_codes);
        const instance_codes = self.codes(self.bundle.instanceVocabulary()) catch {
            self.setError("instance vocabulary allocation failed");
            self.failures +|= 1;
            return;
        };
        defer self.allocator.free(instance_codes);
        const minimum = self.bundle.controlMinimum();
        const maximum = self.bundle.controlMaximum();
        self.model = incinerator_nr_model_create(
            path.ptr,
            semantic_codes.ptr,
            semantic_codes.len,
            instance_codes.ptr,
            instance_codes.len,
            &minimum,
            &maximum,
            &self.last_error_storage,
            self.last_error_storage.len,
        );
        self.inference_enabled = self.model != null;
        if (self.model == null) self.failures +|= 1;
    }

    fn codes(
        self: *Owner,
        vocabulary: []const trial_bundle.VocabularyEntry,
    ) ![]u32 {
        const result = try self.allocator.alloc(u32, vocabulary.len);
        for (vocabulary, result) |entry, *destination| destination.* = entry.encoded;
        return result;
    }

    fn channelPixels(self: *const Owner, channel: contract.Channel) []const u8 {
        const start: usize = @intFromEnum(channel) * channel_bytes;
        return self.input_pixels[start .. start + channel_bytes];
    }

    fn writePpm(
        self: *const Owner,
        root: []const u8,
        name: []const u8,
        width: u32,
        height: u32,
        rgb: []const u8,
    ) !void {
        var header_storage: [64]u8 = undefined;
        const header = try std.fmt.bufPrint(&header_storage, "P6\n{d} {d}\n255\n", .{ width, height });
        const bytes = try self.allocator.alloc(u8, header.len + rgb.len);
        defer self.allocator.free(bytes);
        @memcpy(bytes[0..header.len], header);
        @memcpy(bytes[header.len..], rgb);
        try self.writeExclusive(root, name, bytes);
    }

    fn writeExclusive(
        self: *const Owner,
        root: []const u8,
        name: []const u8,
        bytes: []const u8,
    ) !void {
        const path = try std.fs.path.join(self.allocator, &.{ root, name });
        defer self.allocator.free(path);
        try std.Io.Dir.cwd().writeFile(self.io, .{
            .sub_path = path,
            .data = bytes,
            .flags = .{ .exclusive = true },
        });
    }

    fn readback(self: *Owner, inputs: *const neural_inputs.Owner) !void {
        const cmd = c.SDL_AcquireGPUCommandBuffer(self.device) orelse
            return error.NeuralReadbackCommandAcquireFailed;
        var submitted = false;
        defer if (!submitted) {
            _ = c.SDL_CancelGPUCommandBuffer(cmd);
        };
        const copy = c.SDL_BeginGPUCopyPass(cmd) orelse
            return error.NeuralReadbackCopyPassBeginFailed;
        for (contract.channels, 0..) |channel, index| {
            c.SDL_DownloadFromGPUTexture(copy, &c.SDL_GPUTextureRegion{
                .texture = inputs.target(channel),
                .mip_level = 0,
                .layer = 0,
                .x = 0,
                .y = 0,
                .z = 0,
                .w = contract.cheap_width,
                .h = contract.cheap_height,
                .d = 1,
            }, &c.SDL_GPUTextureTransferInfo{
                .transfer_buffer = self.download,
                .offset = @intCast(index * channel_bytes),
                .pixels_per_row = contract.cheap_width,
                .rows_per_layer = contract.cheap_height,
            });
        }
        c.SDL_EndGPUCopyPass(copy);
        const fence = c.SDL_SubmitGPUCommandBufferAndAcquireFence(cmd) orelse
            return error.NeuralReadbackSubmissionFailed;
        submitted = true;
        defer c.SDL_ReleaseGPUFence(self.device, fence);
        if (!c.SDL_WaitForGPUFences(self.device, true, &fence, 1)) {
            return error.NeuralReadbackFenceWaitFailed;
        }
        const mapped = c.SDL_MapGPUTransferBuffer(self.device, self.download, false) orelse
            return error.NeuralDownloadMapFailed;
        @memcpy(self.input_pixels, @as([*]const u8, @ptrCast(mapped))[0..input_bytes]);
        c.SDL_UnmapGPUTransferBuffer(self.device, self.download);
    }

    fn predict(self: *Owner, frame: contract.Frame) void {
        const model = self.model orelse return;
        const controls = frame.global_controls.values();
        var inference_ms: f64 = 0;
        var unknown_semantic: u64 = 0;
        var unknown_instance: u64 = 0;
        var channels: [contract.channels.len][*]const u8 = undefined;
        for (contract.channels, 0..) |_, index| {
            channels[index] = self.input_pixels.ptr + index * channel_bytes;
        }
        if (!incinerator_nr_model_predict(
            model,
            channels[0],
            channels[1],
            channels[2],
            channels[3],
            channels[4],
            channels[5],
            contract.cheap_width,
            contract.cheap_height,
            &controls,
            self.output_pixels.ptr,
            contract.target_width,
            contract.target_height,
            &unknown_semantic,
            &unknown_instance,
            &inference_ms,
            &self.last_error_storage,
            self.last_error_storage.len,
        )) {
            self.inference_enabled = false;
            self.presentation_enabled = false;
            self.output_ready = false;
            self.failures +|= 1;
            return;
        }
        self.output_ready = true;
        self.predictions +|= 1;
        self.last_source_tick = frame.authority_tick;
        self.last_source_frame = frame.presentation_frame;
        self.last_unknown_semantic_pixels = unknown_semantic;
        self.last_unknown_instance_pixels = unknown_instance;
        self.last_inference_ms = inference_ms;
    }

    fn setError(self: *Owner, text: []const u8) void {
        const length = @min(text.len, self.last_error_storage.len - 1);
        @memcpy(self.last_error_storage[0..length], text[0..length]);
        self.last_error_storage[length] = 0;
    }

    fn disableAfterFailure(self: *Owner, reason: []const u8) void {
        self.setError(reason);
        self.inference_enabled = false;
        self.presentation_enabled = false;
        self.output_ready = false;
        self.failures +|= 1;
    }

    fn lastError(self: *const Owner) []const u8 {
        return std.mem.sliceTo(&self.last_error_storage, 0);
    }
};

fn rgbaToRgb(
    allocator: std.mem.Allocator,
    rgba: []const u8,
    width: u32,
    height: u32,
) ![]u8 {
    const pixels: usize = @as(usize, width) * height;
    if (rgba.len != pixels * 4) return error.InvalidNeuralTrialPixelBytes;
    const rgb = try allocator.alloc(u8, pixels * 3);
    for (0..pixels) |pixel| {
        @memcpy(rgb[pixel * 3 ..][0..3], rgba[pixel * 4 ..][0..3]);
    }
    return rgb;
}

fn monotonicNowNs(io: std.Io) u64 {
    const value = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
    if (value <= 0) return 0;
    return std.math.cast(u64, value) orelse std.math.maxInt(u64);
}
