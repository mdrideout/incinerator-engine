//! Validation-only macOS Metal semantic visibility oracle.
//!
//! This is deliberately a small serial adapter, not a render graph. Selected
//! meshes are rendered with their product model/view-projection transforms and
//! product depth/cull policy into normalized RGBA8 ID and color-preview
//! targets. A fenced SDL GPU download yields exact pixel occupancy and bounds.

const std = @import("std");
const zm = @import("zmath");
const shader_assets = @import("shader_assets");
const sdl = @import("sdl.zig");
const mesh_module = @import("mesh.zig");
const renderer = @import("renderer.zig");

const c = sdl.c;

pub const width: u32 = 320;
pub const height: u32 = 180;
/// The incident semantic pass can cover the complete bounded live gameplay
/// cohort, including five independently rasterized parts per vehicle. Normal
/// focused visibility scenarios remain much smaller.
pub const maximum_draws: usize = 128;
/// One or two surviving edge pixels prove only technical rasterization. A
/// declared human-facing entity needs enough depth-tested area to read as an
/// object at this fixed validation resolution.
pub const minimum_meaningful_pixels: u32 = 64;
const pixel_bytes: u32 = 4;
pub const target_bytes: u32 = width * height * pixel_bytes;
const transfer_bytes: u32 = target_bytes * 2;
const target_format = c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM;

pub const Draw = struct {
    object_id: u32,
    mesh: *const mesh_module.Mesh,
    model: zm.Mat,
    view_projection: zm.Mat,
    display_color: [4]f32,
};

pub const Bounds = struct {
    min_x: u32,
    min_y: u32,
    max_x: u32,
    max_y: u32,
};

pub const Observation = struct {
    object_id: u32,
    pixel_count: u32,
    bounds: ?Bounds,
};

pub const Capture = struct {
    observations: [maximum_draws]Observation = undefined,
    count: usize = 0,

    pub fn slice(self: *const Capture) []const Observation {
        return self.observations[0..self.count];
    }
};

const VisibilitySettings = extern struct {
    id_color: [4]f32,
    display_color: [4]f32,
};

comptime {
    std.debug.assert(@sizeOf(VisibilitySettings) == 32);
}

pub const Owner = struct {
    device: *c.SDL_GPUDevice,
    pipeline: *c.SDL_GPUGraphicsPipeline,
    id_target: *c.SDL_GPUTexture,
    color_target: *c.SDL_GPUTexture,
    depth_target: *c.SDL_GPUTexture,
    download: *c.SDL_GPUTransferBuffer,
    first_failure_artifacts_written: bool = false,
    last_failed_object_id: ?u32 = null,
    captures: u32 = 0,

    pub fn init(gpu: *renderer.Renderer) !Owner {
        const device = gpu.getDevice();
        if (!c.SDL_GPUTextureSupportsFormat(
            device,
            target_format,
            c.SDL_GPU_TEXTURETYPE_2D,
            c.SDL_GPU_TEXTUREUSAGE_COLOR_TARGET,
        )) return error.VisibilityTargetFormatUnsupported;

        const id_target = try createColorTarget(device);
        errdefer c.SDL_ReleaseGPUTexture(device, id_target);
        const color_target = try createColorTarget(device);
        errdefer c.SDL_ReleaseGPUTexture(device, color_target);
        const depth_target = c.SDL_CreateGPUTexture(device, &c.SDL_GPUTextureCreateInfo{
            .type = c.SDL_GPU_TEXTURETYPE_2D,
            .format = gpu.getDepthFormat(),
            .usage = c.SDL_GPU_TEXTUREUSAGE_DEPTH_STENCIL_TARGET,
            .width = width,
            .height = height,
            .layer_count_or_depth = 1,
            .num_levels = 1,
            .sample_count = c.SDL_GPU_SAMPLECOUNT_1,
            .props = 0,
        }) orelse return error.VisibilityDepthTargetCreationFailed;
        errdefer c.SDL_ReleaseGPUTexture(device, depth_target);
        const download = c.SDL_CreateGPUTransferBuffer(
            device,
            &c.SDL_GPUTransferBufferCreateInfo{
                .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_DOWNLOAD,
                .size = transfer_bytes,
                .props = 0,
            },
        ) orelse return error.VisibilityTransferBufferCreationFailed;
        errdefer c.SDL_ReleaseGPUTransferBuffer(device, download);
        const pipeline = try createPipeline(device, gpu.getDepthFormat());
        return .{
            .device = device,
            .pipeline = pipeline,
            .id_target = id_target,
            .color_target = color_target,
            .depth_target = depth_target,
            .download = download,
        };
    }

    pub fn deinit(self: *Owner) void {
        // Every capture waits its own fence. The renderer also drains before
        // calling this owner, making teardown explicit under error unwinds.
        c.SDL_ReleaseGPUGraphicsPipeline(self.device, self.pipeline);
        c.SDL_ReleaseGPUTransferBuffer(self.device, self.download);
        c.SDL_ReleaseGPUTexture(self.device, self.depth_target);
        c.SDL_ReleaseGPUTexture(self.device, self.color_target);
        c.SDL_ReleaseGPUTexture(self.device, self.id_target);
        self.* = undefined;
    }

    pub fn capture(
        self: *Owner,
        io: std.Io,
        scenario_name: []const u8,
        checkpoint_name: []const u8,
        authority_tick: u64,
        presentation_frame: u64,
        draws: []const Draw,
    ) !Capture {
        if (draws.len == 0 or draws.len > maximum_draws) {
            return error.InvalidVisibilityDrawCount;
        }
        try validateDraws(draws);
        self.last_failed_object_id = null;

        const cmd = c.SDL_AcquireGPUCommandBuffer(self.device) orelse
            return error.VisibilityCommandAcquireFailed;
        var submitted = false;
        defer if (!submitted) {
            if (!c.SDL_CancelGPUCommandBuffer(cmd)) {
                std.debug.print("visibility oracle command cancel failed: {s}\n", .{c.SDL_GetError()});
            }
        };

        const targets = [_]c.SDL_GPUColorTargetInfo{
            colorTargetInfo(self.id_target),
            colorTargetInfo(self.color_target),
        };
        const depth = c.SDL_GPUDepthStencilTargetInfo{
            .texture = self.depth_target,
            .clear_depth = 1.0,
            .load_op = c.SDL_GPU_LOADOP_CLEAR,
            .store_op = c.SDL_GPU_STOREOP_DONT_CARE,
            .stencil_load_op = c.SDL_GPU_LOADOP_DONT_CARE,
            .stencil_store_op = c.SDL_GPU_STOREOP_DONT_CARE,
            .cycle = false,
            .clear_stencil = 0,
            .mip_level = 0,
            .layer = 0,
        };
        const pass = c.SDL_BeginGPURenderPass(cmd, &targets, targets.len, &depth) orelse
            return error.VisibilityRenderPassBeginFailed;
        c.SDL_BindGPUGraphicsPipeline(pass, self.pipeline);
        for (draws) |draw| drawOne(cmd, pass, draw);
        c.SDL_EndGPURenderPass(pass);

        const copy = c.SDL_BeginGPUCopyPass(cmd) orelse
            return error.VisibilityCopyPassBeginFailed;
        downloadTarget(copy, self.id_target, self.download, 0);
        downloadTarget(copy, self.color_target, self.download, target_bytes);
        c.SDL_EndGPUCopyPass(copy);

        const fence = c.SDL_SubmitGPUCommandBufferAndAcquireFence(cmd) orelse
            return error.VisibilitySubmissionFailed;
        submitted = true;
        defer c.SDL_ReleaseGPUFence(self.device, fence);
        if (!c.SDL_WaitForGPUFences(self.device, true, &fence, 1)) {
            return error.VisibilityFenceWaitFailed;
        }

        const mapped = c.SDL_MapGPUTransferBuffer(self.device, self.download, false) orelse
            return error.VisibilityTransferMapFailed;
        defer c.SDL_UnmapGPUTransferBuffer(self.device, self.download);
        const bytes: [*]const u8 = @ptrCast(mapped);
        const id_pixels = bytes[0..target_bytes];
        const color_pixels = bytes[target_bytes..transfer_bytes];
        var result = scan(draws, id_pixels);
        self.captures +|= 1;

        for (result.slice()) |observation| {
            if (observation.pixel_count != 0 and observation.bounds != null) continue;
            if (!self.first_failure_artifacts_written) {
                self.writeFailureArtifacts(
                    io,
                    scenario_name,
                    checkpoint_name,
                    authority_tick,
                    presentation_frame,
                    observation.object_id,
                    id_pixels,
                    color_pixels,
                ) catch |artifact_err| std.debug.print(
                    "visibility oracle artifact write failed: {s}\n",
                    .{@errorName(artifact_err)},
                );
                self.first_failure_artifacts_written = true;
            }
            self.last_failed_object_id = observation.object_id;
            return error.DeclaredEntityHasNoVisiblePixels;
        }
        return result;
    }

    fn writeFailureArtifacts(
        self: *Owner,
        io: std.Io,
        scenario_name: []const u8,
        checkpoint_name: []const u8,
        authority_tick: u64,
        presentation_frame: u64,
        object_id: u32,
        id_pixels: []const u8,
        color_pixels: []const u8,
    ) !void {
        _ = self;
        var metadata: [1024]u8 = undefined;
        const metadata_bytes = try std.fmt.bufPrint(
            &metadata,
            "scenario={s}\ncheckpoint={s}\nauthority_tick={d}\npresentation_frame={d}\n" ++
                "object_id={d}\nwidth={d}\nheight={d}\n",
            .{ scenario_name, checkpoint_name, authority_tick, presentation_frame, object_id, width, height },
        );
        try writeTmp(io, "incinerator-visibility-first-failure.txt", metadata_bytes);
        try writePpm(io, "incinerator-visibility-first-failure-id.ppm", id_pixels, true);
        try writePpm(io, "incinerator-visibility-first-failure-color.ppm", color_pixels, false);
    }
};

pub fn createColorTarget(device: *c.SDL_GPUDevice) !*c.SDL_GPUTexture {
    return c.SDL_CreateGPUTexture(device, &c.SDL_GPUTextureCreateInfo{
        .type = c.SDL_GPU_TEXTURETYPE_2D,
        .format = target_format,
        .usage = c.SDL_GPU_TEXTUREUSAGE_COLOR_TARGET,
        .width = width,
        .height = height,
        .layer_count_or_depth = 1,
        .num_levels = 1,
        .sample_count = c.SDL_GPU_SAMPLECOUNT_1,
        .props = 0,
    }) orelse error.VisibilityColorTargetCreationFailed;
}

pub fn colorTargetInfo(texture: *c.SDL_GPUTexture) c.SDL_GPUColorTargetInfo {
    return .{
        .texture = texture,
        .mip_level = 0,
        .layer_or_depth_plane = 0,
        .clear_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .load_op = c.SDL_GPU_LOADOP_CLEAR,
        .store_op = c.SDL_GPU_STOREOP_STORE,
        .resolve_texture = null,
        .resolve_mip_level = 0,
        .resolve_layer = 0,
        .cycle = false,
        .cycle_resolve_texture = false,
        .padding1 = 0,
        .padding2 = 0,
    };
}

fn encodeId(object_id: u32) [4]f32 {
    return .{
        @as(f32, @floatFromInt(object_id & 0xff)) / 255.0,
        @as(f32, @floatFromInt((object_id >> 8) & 0xff)) / 255.0,
        @as(f32, @floatFromInt((object_id >> 16) & 0xff)) / 255.0,
        1.0,
    };
}

pub fn decodeId(pixel: []const u8) u32 {
    return @as(u32, pixel[0]) |
        (@as(u32, pixel[1]) << 8) |
        (@as(u32, pixel[2]) << 16);
}

fn validateDraws(draws: []const Draw) !void {
    for (draws, 0..) |draw, index| {
        if (draw.object_id == 0 or draw.object_id > 0x00ff_ffff) {
            return error.InvalidVisibilityObjectId;
        }
        if (draw.mesh.vertex_format != .pos_normal_uv) {
            return error.UnsupportedVisibilityVertexFormat;
        }
        for (draws[index + 1 ..]) |other| {
            if (draw.object_id == other.object_id) return error.DuplicateVisibilityObjectId;
        }
    }
}

pub fn drawOne(
    cmd: *c.SDL_GPUCommandBuffer,
    pass: *c.SDL_GPURenderPass,
    draw: Draw,
) void {
    const uniforms = renderer.Uniforms{
        .mvp = zm.matToArr(zm.mul(draw.model, draw.view_projection)),
    };
    c.SDL_PushGPUVertexUniformData(cmd, 0, &uniforms, @sizeOf(renderer.Uniforms));
    const settings = VisibilitySettings{
        .id_color = encodeId(draw.object_id),
        .display_color = draw.display_color,
    };
    c.SDL_PushGPUFragmentUniformData(cmd, 0, &settings, @sizeOf(VisibilitySettings));
    const binding = c.SDL_GPUBufferBinding{ .buffer = draw.mesh.vertex_buffer, .offset = 0 };
    c.SDL_BindGPUVertexBuffers(pass, 0, &binding, 1);
    if (draw.mesh.isIndexed()) {
        const index_binding = c.SDL_GPUBufferBinding{
            .buffer = draw.mesh.index_buffer.?,
            .offset = 0,
        };
        c.SDL_BindGPUIndexBuffer(pass, &index_binding, c.SDL_GPU_INDEXELEMENTSIZE_32BIT);
        c.SDL_DrawGPUIndexedPrimitives(pass, draw.mesh.index_count, 1, 0, 0, 0);
    } else {
        c.SDL_DrawGPUPrimitives(pass, draw.mesh.vertex_count, 1, 0, 0);
    }
}

pub fn downloadTarget(
    copy: *c.SDL_GPUCopyPass,
    texture: *c.SDL_GPUTexture,
    transfer: *c.SDL_GPUTransferBuffer,
    offset: u32,
) void {
    const source = c.SDL_GPUTextureRegion{
        .texture = texture,
        .mip_level = 0,
        .layer = 0,
        .x = 0,
        .y = 0,
        .z = 0,
        .w = width,
        .h = height,
        .d = 1,
    };
    const destination = c.SDL_GPUTextureTransferInfo{
        .transfer_buffer = transfer,
        .offset = offset,
        .pixels_per_row = width,
        .rows_per_layer = height,
    };
    c.SDL_DownloadFromGPUTexture(copy, &source, &destination);
}

fn scan(draws: []const Draw, pixels: []const u8) Capture {
    std.debug.assert(pixels.len == target_bytes);
    var result = Capture{ .count = draws.len };
    for (draws, 0..) |draw, index| {
        result.observations[index] = .{
            .object_id = draw.object_id,
            .pixel_count = 0,
            .bounds = null,
        };
    }
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const pixel_index: usize = (@as(usize, y) * width + x) * pixel_bytes;
            const object_id = decodeId(pixels[pixel_index .. pixel_index + pixel_bytes]);
            if (object_id == 0) continue;
            for (result.observations[0..result.count]) |*observation| {
                if (observation.object_id != object_id) continue;
                observation.pixel_count +|= 1;
                if (observation.bounds) |*bounds| {
                    bounds.min_x = @min(bounds.min_x, x);
                    bounds.min_y = @min(bounds.min_y, y);
                    bounds.max_x = @max(bounds.max_x, x);
                    bounds.max_y = @max(bounds.max_y, y);
                } else observation.bounds = .{
                    .min_x = x,
                    .min_y = y,
                    .max_x = x,
                    .max_y = y,
                };
                break;
            }
        }
    }
    return result;
}

pub fn createPipeline(
    device: *c.SDL_GPUDevice,
    depth_format: c.SDL_GPUTextureFormat,
) !*c.SDL_GPUGraphicsPipeline {
    const shader_format = c.SDL_GPU_SHADERFORMAT_MSL;
    const vertex = c.SDL_CreateGPUShader(device, &c.SDL_GPUShaderCreateInfo{
        .code = shader_assets.triangle_vertex.ptr,
        .code_size = shader_assets.triangle_vertex.len,
        .entrypoint = shader_assets.entrypoint,
        .format = shader_format,
        .stage = c.SDL_GPU_SHADERSTAGE_VERTEX,
        .num_samplers = 0,
        .num_storage_textures = 0,
        .num_storage_buffers = 0,
        .num_uniform_buffers = 1,
        .props = 0,
    }) orelse return error.VisibilityVertexShaderCreationFailed;
    defer c.SDL_ReleaseGPUShader(device, vertex);
    const fragment = c.SDL_CreateGPUShader(device, &c.SDL_GPUShaderCreateInfo{
        .code = shader_assets.visibility_fragment.ptr,
        .code_size = shader_assets.visibility_fragment.len,
        .entrypoint = shader_assets.entrypoint,
        .format = shader_format,
        .stage = c.SDL_GPU_SHADERSTAGE_FRAGMENT,
        .num_samplers = 0,
        .num_storage_textures = 0,
        .num_storage_buffers = 0,
        .num_uniform_buffers = 1,
        .props = 0,
    }) orelse return error.VisibilityFragmentShaderCreationFailed;
    defer c.SDL_ReleaseGPUShader(device, fragment);

    const vertex_buffer = c.SDL_GPUVertexBufferDescription{
        .slot = 0,
        .pitch = @sizeOf(mesh_module.VertexPNU),
        .input_rate = c.SDL_GPU_VERTEXINPUTRATE_VERTEX,
        .instance_step_rate = 0,
    };
    const vertex_attributes = [_]c.SDL_GPUVertexAttribute{
        .{
            .location = 0,
            .buffer_slot = 0,
            .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT3,
            .offset = @offsetOf(mesh_module.Vertex, "position"),
        },
        .{
            .location = 1,
            .buffer_slot = 0,
            .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT3,
            // triangle.vert's unused color output gives this validation-only
            // pass a compact position/normal-compatible vertex contract.
            .offset = @offsetOf(mesh_module.VertexPNU, "normal"),
        },
    };
    const targets = [_]c.SDL_GPUColorTargetDescription{
        colorTargetDescription(),
        colorTargetDescription(),
    };
    return c.SDL_CreateGPUGraphicsPipeline(device, &c.SDL_GPUGraphicsPipelineCreateInfo{
        .vertex_shader = vertex,
        .fragment_shader = fragment,
        .vertex_input_state = .{
            .vertex_buffer_descriptions = &vertex_buffer,
            .num_vertex_buffers = 1,
            .vertex_attributes = &vertex_attributes,
            .num_vertex_attributes = vertex_attributes.len,
        },
        .primitive_type = c.SDL_GPU_PRIMITIVETYPE_TRIANGLELIST,
        .rasterizer_state = .{
            .fill_mode = c.SDL_GPU_FILLMODE_FILL,
            .cull_mode = c.SDL_GPU_CULLMODE_BACK,
            .front_face = c.SDL_GPU_FRONTFACE_CLOCKWISE,
            .depth_bias_constant_factor = 0,
            .depth_bias_clamp = 0,
            .depth_bias_slope_factor = 0,
            .enable_depth_bias = false,
            .enable_depth_clip = false,
            .padding1 = 0,
            .padding2 = 0,
        },
        .multisample_state = .{
            .sample_count = c.SDL_GPU_SAMPLECOUNT_1,
            .sample_mask = 0,
            .enable_mask = false,
            .enable_alpha_to_coverage = false,
            .padding2 = 0,
            .padding3 = 0,
        },
        .depth_stencil_state = .{
            .compare_op = c.SDL_GPU_COMPAREOP_LESS,
            .back_stencil_state = std.mem.zeroes(c.SDL_GPUStencilOpState),
            .front_stencil_state = std.mem.zeroes(c.SDL_GPUStencilOpState),
            .compare_mask = 0,
            .write_mask = 0,
            .enable_depth_test = true,
            .enable_depth_write = true,
            .enable_stencil_test = false,
            .padding1 = 0,
            .padding2 = 0,
            .padding3 = 0,
        },
        .target_info = .{
            .color_target_descriptions = &targets,
            .num_color_targets = targets.len,
            .depth_stencil_format = depth_format,
            .has_depth_stencil_target = true,
            .padding1 = 0,
            .padding2 = 0,
            .padding3 = 0,
        },
        .props = 0,
    }) orelse error.VisibilityPipelineCreationFailed;
}

fn colorTargetDescription() c.SDL_GPUColorTargetDescription {
    return .{
        .format = target_format,
        .blend_state = .{
            .src_color_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE,
            .dst_color_blendfactor = c.SDL_GPU_BLENDFACTOR_ZERO,
            .color_blend_op = c.SDL_GPU_BLENDOP_ADD,
            .src_alpha_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE,
            .dst_alpha_blendfactor = c.SDL_GPU_BLENDFACTOR_ZERO,
            .alpha_blend_op = c.SDL_GPU_BLENDOP_ADD,
            .color_write_mask = 0xf,
            .enable_blend = false,
            .enable_color_write_mask = false,
            .padding1 = 0,
            .padding2 = 0,
        },
    };
}

fn writeTmp(io: std.Io, name: []const u8, bytes: []const u8) !void {
    var tmp = try std.Io.Dir.openDirAbsolute(io, "/tmp", .{});
    defer tmp.close(io);
    try tmp.writeFile(io, .{ .sub_path = name, .data = bytes });
}

fn writePpm(io: std.Io, name: []const u8, rgba: []const u8, id_mask: bool) !void {
    const header = "P6\n320 180\n255\n";
    const rgb_bytes = @as(usize, width) * height * 3;
    const output = try std.heap.page_allocator.alloc(u8, header.len + rgb_bytes);
    defer std.heap.page_allocator.free(output);
    @memcpy(output[0..header.len], header);
    var source: usize = 0;
    var destination: usize = header.len;
    while (source < rgba.len) : (source += 4) {
        if (id_mask and decodeId(rgba[source .. source + 4]) != 0) {
            const id = decodeId(rgba[source .. source + 4]);
            output[destination] = @intCast((id *% 97) | 0x40);
            output[destination + 1] = @intCast(((id *% 57) >> 1) | 0x40);
            output[destination + 2] = @intCast(((id *% 31) >> 2) | 0x40);
        } else {
            @memcpy(output[destination .. destination + 3], rgba[source .. source + 3]);
        }
        destination += 3;
    }
    try writeTmp(io, name, output);
}

test "ID scan reports exact visible occupancy and bounds" {
    var pixels: [target_bytes]u8 = @splat(0);
    const first = (@as(usize, 7) * width + 5) * pixel_bytes;
    pixels[first] = 1;
    const second = (@as(usize, 9) * width + 8) * pixel_bytes;
    pixels[second] = 1;
    const fake_mesh: *const mesh_module.Mesh = undefined;
    const draws = [_]Draw{.{
        .object_id = 1,
        .mesh = fake_mesh,
        .model = undefined,
        .view_projection = undefined,
        .display_color = .{ 1, 1, 1, 1 },
    }};
    const result = scan(&draws, &pixels);
    try std.testing.expectEqual(@as(usize, 1), result.slice().len);
    try std.testing.expectEqual(@as(u32, 2), result.slice()[0].pixel_count);
    try std.testing.expectEqual(Bounds{
        .min_x = 5,
        .min_y = 7,
        .max_x = 8,
        .max_y = 9,
    }, result.slice()[0].bounds.?);
}

test "visibility IDs are stable normalized RGBA8 values" {
    const cases = [_]u32{ 1, 255, 256, 65_535, 0x00ff_ffff };
    for (cases) |object_id| {
        const encoded = encodeId(object_id);
        const pixel = [4]u8{
            @intFromFloat(@round(encoded[0] * 255.0)),
            @intFromFloat(@round(encoded[1] * 255.0)),
            @intFromFloat(@round(encoded[2] * 255.0)),
            255,
        };
        try std.testing.expectEqual(object_id, decodeId(&pixel));
    }
}
