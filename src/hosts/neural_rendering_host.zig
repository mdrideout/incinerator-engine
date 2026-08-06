//! Experimental NR-0001 presentation host for Apple Silicon macOS.
//!
//! The host receives only renderer-owned product color. Its initial staged
//! path is intentionally disposable: fixed-size GPU downsample/readback,
//! Core ML CPU tensors, and a one-frame-delayed GPU upload. Authority and
//! gameplay values are absent from this dependency boundary.

const std = @import("std");
const renderer = @import("../renderer.zig");
const sdl = @import("../sdl.zig");

const c = sdl.c;

pub const input_width: u32 = 80;
pub const input_height: u32 = 45;
pub const output_width: u32 = 320;
pub const output_height: u32 = 180;
pub const pixel_bytes: u32 = 4;
const input_byte_count: usize = input_width * input_height * pixel_bytes;
const output_byte_count: usize = output_width * output_height * pixel_bytes;
const download_byte_count: u32 = input_byte_count + output_byte_count;
const error_capacity = 1024;

const NativeModel = opaque {};

extern fn incinerator_nr_model_create(
    model_path: [*:0]const u8,
    error_text: [*]u8,
    error_capacity_value: usize,
) ?*NativeModel;
extern fn incinerator_nr_model_destroy(handle: *NativeModel) void;
extern fn incinerator_nr_model_predict(
    handle: *NativeModel,
    input_pixels: [*]const u8,
    input_width_value: u32,
    input_height_value: u32,
    input_bgra: bool,
    output_pixels: [*]u8,
    output_width_value: u32,
    output_height_value: u32,
    output_bgra: bool,
    inference_ms: *f64,
    error_text: [*]u8,
    error_capacity_value: usize,
) bool;

pub const CapturedFrame = struct {
    authority_tick: u64,
    presentation_frame: u64,
    input_pixels: []const u8,
    target_pixels: []const u8,
    neural_output_pixels: ?[]const u8,
    bgra: bool,
};

pub const Diagnostics = struct {
    model_loaded: bool,
    enabled: bool,
    output_ready: bool,
    readbacks: u64,
    predictions: u64,
    failures: u64,
    last_inference_ms: f64,
    mean_staged_pipeline_ms: f64,
    maximum_staged_pipeline_ms: f64,
    last_error: []const u8,
};

pub const Owner = struct {
    io: std.Io,
    device: *c.SDL_GPUDevice,
    format: c.SDL_GPUTextureFormat,
    bgra: bool,
    input_texture: *c.SDL_GPUTexture,
    target_texture: *c.SDL_GPUTexture,
    output_texture: *c.SDL_GPUTexture,
    download: *c.SDL_GPUTransferBuffer,
    upload: *c.SDL_GPUTransferBuffer,
    input_pixels: []u8,
    target_pixels: []u8,
    output_pixels: []u8,
    model: ?*NativeModel = null,
    model_path: ?[]const u8,
    enabled: bool = false,
    output_ready: bool = false,
    readbacks: u64 = 0,
    predictions: u64 = 0,
    failures: u64 = 0,
    last_inference_ms: f64 = 0,
    staged_pipeline_total_ns: u64 = 0,
    staged_pipeline_max_ns: u64 = 0,
    last_error_storage: [error_capacity]u8 = @splat(0),

    pub fn init(io: std.Io, gpu: *renderer.Renderer, model_path: ?[]const u8) !Owner {
        const device = gpu.getDevice();
        const format = gpu.getSwapchainFormat();
        const input_texture = try createTexture(device, format, input_width, input_height);
        errdefer c.SDL_ReleaseGPUTexture(device, input_texture);
        const target_texture = try createTexture(device, format, output_width, output_height);
        errdefer c.SDL_ReleaseGPUTexture(device, target_texture);
        const output_texture = try createTexture(device, format, output_width, output_height);
        errdefer c.SDL_ReleaseGPUTexture(device, output_texture);
        const download = c.SDL_CreateGPUTransferBuffer(device, &c.SDL_GPUTransferBufferCreateInfo{
            .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_DOWNLOAD,
            .size = download_byte_count,
            .props = 0,
        }) orelse return error.NeuralDownloadBufferCreationFailed;
        errdefer c.SDL_ReleaseGPUTransferBuffer(device, download);
        const upload = c.SDL_CreateGPUTransferBuffer(device, &c.SDL_GPUTransferBufferCreateInfo{
            .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
            .size = output_byte_count,
            .props = 0,
        }) orelse return error.NeuralUploadBufferCreationFailed;
        errdefer c.SDL_ReleaseGPUTransferBuffer(device, upload);
        const input_pixels = try std.heap.page_allocator.alloc(u8, input_byte_count);
        errdefer std.heap.page_allocator.free(input_pixels);
        const target_pixels = try std.heap.page_allocator.alloc(u8, output_byte_count);
        errdefer std.heap.page_allocator.free(target_pixels);
        const output_pixels = try std.heap.page_allocator.alloc(u8, output_byte_count);
        errdefer std.heap.page_allocator.free(output_pixels);

        var result = Owner{
            .io = io,
            .device = device,
            .format = format,
            .bgra = format == c.SDL_GPU_TEXTUREFORMAT_B8G8R8A8_UNORM or
                format == c.SDL_GPU_TEXTUREFORMAT_B8G8R8A8_UNORM_SRGB,
            .input_texture = input_texture,
            .target_texture = target_texture,
            .output_texture = output_texture,
            .download = download,
            .upload = upload,
            .input_pixels = input_pixels,
            .target_pixels = target_pixels,
            .output_pixels = output_pixels,
            .model_path = model_path,
        };
        if (model_path) |path| result.loadModel(path);
        return result;
    }

    pub fn deinit(self: *Owner, gpu: *renderer.Renderer) void {
        gpu.clearScenePresentationOverride();
        _ = c.SDL_WaitForGPUIdle(self.device);
        std.debug.print(
            "NEURAL_RENDERER_POC_RESULT model={s} enabled={} readbacks={d} " ++
                "predictions={d} failures={d} last_inference_ms={d:.3} " ++
                "staged_pipeline_mean_ms={d:.3} staged_pipeline_max_ms={d:.3} error={s}\n",
            .{
                self.model_path orelse "none",
                self.enabled,
                self.readbacks,
                self.predictions,
                self.failures,
                self.last_inference_ms,
                if (self.readbacks == 0)
                    0
                else
                    @as(f64, @floatFromInt(self.staged_pipeline_total_ns)) /
                        @as(f64, @floatFromInt(self.readbacks)) /
                        std.time.ns_per_ms,
                @as(f64, @floatFromInt(self.staged_pipeline_max_ns)) / std.time.ns_per_ms,
                self.lastError(),
            },
        );
        if (self.model) |model| incinerator_nr_model_destroy(model);
        std.heap.page_allocator.free(self.input_pixels);
        std.heap.page_allocator.free(self.target_pixels);
        std.heap.page_allocator.free(self.output_pixels);
        c.SDL_ReleaseGPUTransferBuffer(self.device, self.download);
        c.SDL_ReleaseGPUTransferBuffer(self.device, self.upload);
        c.SDL_ReleaseGPUTexture(self.device, self.input_texture);
        c.SDL_ReleaseGPUTexture(self.device, self.target_texture);
        c.SDL_ReleaseGPUTexture(self.device, self.output_texture);
        self.* = undefined;
    }

    pub fn toggle(self: *Owner) bool {
        if (self.model == null) return false;
        self.enabled = !self.enabled;
        return self.enabled;
    }

    pub fn prepareFrame(self: *Owner, gpu: *renderer.Renderer) !void {
        if (!self.enabled or !self.output_ready) {
            gpu.clearScenePresentationOverride();
            return;
        }
        const mapped = c.SDL_MapGPUTransferBuffer(self.device, self.upload, true) orelse
            return error.NeuralUploadMapFailed;
        @memcpy(@as([*]u8, @ptrCast(mapped))[0..output_byte_count], self.output_pixels);
        c.SDL_UnmapGPUTransferBuffer(self.device, self.upload);
        const cmd = c.SDL_AcquireGPUCommandBuffer(self.device) orelse
            return error.NeuralUploadCommandAcquireFailed;
        var submitted = false;
        defer if (!submitted) {
            _ = c.SDL_CancelGPUCommandBuffer(cmd);
        };
        const copy = c.SDL_BeginGPUCopyPass(cmd) orelse
            return error.NeuralUploadCopyPassBeginFailed;
        c.SDL_UploadToGPUTexture(
            copy,
            &c.SDL_GPUTextureTransferInfo{
                .transfer_buffer = self.upload,
                .offset = 0,
                .pixels_per_row = output_width,
                .rows_per_layer = output_height,
            },
            &c.SDL_GPUTextureRegion{
                .texture = self.output_texture,
                .mip_level = 0,
                .layer = 0,
                .x = 0,
                .y = 0,
                .z = 0,
                .w = output_width,
                .h = output_height,
                .d = 1,
            },
            true,
        );
        c.SDL_EndGPUCopyPass(copy);
        if (!c.SDL_SubmitGPUCommandBuffer(cmd)) return error.NeuralUploadSubmissionFailed;
        submitted = true;
        gpu.setScenePresentationOverride(self.output_texture, output_width, output_height);
    }

    pub fn readbackAndPredict(
        self: *Owner,
        gpu: *renderer.Renderer,
        authority_tick: u64,
        presentation_frame: u64,
        capture_requested: bool,
    ) !?CapturedFrame {
        if (!capture_requested and !self.enabled) return null;
        const started_ns = monotonicNowNs(self.io);
        const source = gpu.getProductSceneTexture();
        const extent = gpu.getProductSceneExtent();
        const cmd = c.SDL_AcquireGPUCommandBuffer(self.device) orelse
            return error.NeuralReadbackCommandAcquireFailed;
        var submitted = false;
        defer if (!submitted) {
            _ = c.SDL_CancelGPUCommandBuffer(cmd);
        };
        blit(cmd, source, extent.width, extent.height, self.input_texture, input_width, input_height);
        blit(cmd, source, extent.width, extent.height, self.target_texture, output_width, output_height);
        const copy = c.SDL_BeginGPUCopyPass(cmd) orelse
            return error.NeuralReadbackCopyPassBeginFailed;
        downloadTexture(copy, self.input_texture, self.download, 0, input_width, input_height);
        downloadTexture(
            copy,
            self.target_texture,
            self.download,
            input_byte_count,
            output_width,
            output_height,
        );
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
        const bytes: [*]const u8 = @ptrCast(mapped);
        @memcpy(self.input_pixels, bytes[0..input_byte_count]);
        @memcpy(
            self.target_pixels,
            bytes[input_byte_count .. input_byte_count + output_byte_count],
        );
        c.SDL_UnmapGPUTransferBuffer(self.device, self.download);
        self.readbacks +|= 1;

        if (self.enabled) self.predict();
        const duration_ns = monotonicNowNs(self.io) -| started_ns;
        self.staged_pipeline_total_ns +|= duration_ns;
        self.staged_pipeline_max_ns = @max(self.staged_pipeline_max_ns, duration_ns);
        return .{
            .authority_tick = authority_tick,
            .presentation_frame = presentation_frame,
            .input_pixels = self.input_pixels,
            .target_pixels = self.target_pixels,
            .neural_output_pixels = if (self.enabled and self.output_ready)
                self.output_pixels
            else
                null,
            .bgra = self.bgra,
        };
    }

    pub fn diagnostics(self: *const Owner) Diagnostics {
        return .{
            .model_loaded = self.model != null,
            .enabled = self.enabled,
            .output_ready = self.output_ready,
            .readbacks = self.readbacks,
            .predictions = self.predictions,
            .failures = self.failures,
            .last_inference_ms = self.last_inference_ms,
            .mean_staged_pipeline_ms = if (self.readbacks == 0)
                0
            else
                @as(f64, @floatFromInt(self.staged_pipeline_total_ns)) /
                    @as(f64, @floatFromInt(self.readbacks)) /
                    std.time.ns_per_ms,
            .maximum_staged_pipeline_ms = @as(f64, @floatFromInt(self.staged_pipeline_max_ns)) /
                std.time.ns_per_ms,
            .last_error = self.lastError(),
        };
    }

    fn loadModel(self: *Owner, path: []const u8) void {
        const terminated = std.heap.page_allocator.dupeZ(u8, path) catch {
            self.setError("model path allocation failed");
            self.failures +|= 1;
            return;
        };
        defer std.heap.page_allocator.free(terminated);
        self.model = incinerator_nr_model_create(
            terminated.ptr,
            &self.last_error_storage,
            self.last_error_storage.len,
        );
        self.enabled = self.model != null;
        if (self.model == null) self.failures +|= 1;
    }

    fn predict(self: *Owner) void {
        const model = self.model orelse return;
        var inference_ms: f64 = 0;
        if (!incinerator_nr_model_predict(
            model,
            self.input_pixels.ptr,
            input_width,
            input_height,
            self.bgra,
            self.output_pixels.ptr,
            output_width,
            output_height,
            self.bgra,
            &inference_ms,
            &self.last_error_storage,
            self.last_error_storage.len,
        )) {
            self.enabled = false;
            self.output_ready = false;
            self.failures +|= 1;
            return;
        }
        self.output_ready = true;
        self.predictions +|= 1;
        self.last_inference_ms = inference_ms;
    }

    fn setError(self: *Owner, text: []const u8) void {
        const length = @min(text.len, self.last_error_storage.len - 1);
        @memcpy(self.last_error_storage[0..length], text[0..length]);
        self.last_error_storage[length] = 0;
    }

    fn lastError(self: *const Owner) []const u8 {
        return std.mem.sliceTo(&self.last_error_storage, 0);
    }
};

fn monotonicNowNs(io: std.Io) u64 {
    const value = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
    if (value <= 0) return 0;
    return std.math.cast(u64, value) orelse std.math.maxInt(u64);
}

fn createTexture(
    device: *c.SDL_GPUDevice,
    format: c.SDL_GPUTextureFormat,
    width: u32,
    height: u32,
) !*c.SDL_GPUTexture {
    return c.SDL_CreateGPUTexture(device, &c.SDL_GPUTextureCreateInfo{
        .type = c.SDL_GPU_TEXTURETYPE_2D,
        .format = format,
        .usage = c.SDL_GPU_TEXTUREUSAGE_COLOR_TARGET |
            c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
        .width = width,
        .height = height,
        .layer_count_or_depth = 1,
        .num_levels = 1,
        .sample_count = c.SDL_GPU_SAMPLECOUNT_1,
        .props = 0,
    }) orelse error.NeuralTextureCreationFailed;
}

fn blit(
    cmd: *c.SDL_GPUCommandBuffer,
    source: *c.SDL_GPUTexture,
    source_width: u32,
    source_height: u32,
    destination: *c.SDL_GPUTexture,
    destination_width: u32,
    destination_height: u32,
) void {
    c.SDL_BlitGPUTexture(cmd, &c.SDL_GPUBlitInfo{
        .source = .{
            .texture = source,
            .mip_level = 0,
            .layer_or_depth_plane = 0,
            .x = 0,
            .y = 0,
            .w = source_width,
            .h = source_height,
        },
        .destination = .{
            .texture = destination,
            .mip_level = 0,
            .layer_or_depth_plane = 0,
            .x = 0,
            .y = 0,
            .w = destination_width,
            .h = destination_height,
        },
        .load_op = c.SDL_GPU_LOADOP_DONT_CARE,
        .clear_color = .{ .r = 0, .g = 0, .b = 0, .a = 1 },
        .flip_mode = c.SDL_FLIP_NONE,
        .filter = c.SDL_GPU_FILTER_LINEAR,
        .cycle = true,
        .padding1 = 0,
        .padding2 = 0,
        .padding3 = 0,
    });
}

fn downloadTexture(
    copy: *c.SDL_GPUCopyPass,
    texture: *c.SDL_GPUTexture,
    transfer: *c.SDL_GPUTransferBuffer,
    offset: u32,
    width: u32,
    height: u32,
) void {
    c.SDL_DownloadFromGPUTexture(
        copy,
        &c.SDL_GPUTextureRegion{
            .texture = texture,
            .mip_level = 0,
            .layer = 0,
            .x = 0,
            .y = 0,
            .z = 0,
            .w = width,
            .h = height,
            .d = 1,
        },
        &c.SDL_GPUTextureTransferInfo{
            .transfer_buffer = transfer,
            .offset = offset,
            .pixels_per_row = width,
            .rows_per_layer = height,
        },
    );
}
