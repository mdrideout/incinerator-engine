//! macOS SDL-GPU adapter for the engine-owned neural input schema.
//!
//! Draws are copied from the visual composition's immutable presentation plan.
//! This host has no simulation/session authority access and cannot affect the
//! conventional product pass.

const std = @import("std");
const zm = @import("zmath");
const shader_assets = @import("shader_assets");
const engine = @import("incinerator_engine");
const renderer = @import("../renderer.zig");
const mesh_module = @import("../mesh.zig");
const texture_module = @import("../texture.zig");
const sdl = @import("../sdl.zig");
const target_contract = @import("neural_target_contract.zig");

const c = sdl.c;
const contract = engine.neural_rendering;
const target_format = c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM;
const appearance_format = c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM_SRGB;

pub const shader_fingerprint =
    "nr-input-mrt-v1|primitive/model|world-normal|linear-view-depth|prev-current-ndc";

pub fn shaderDigest() [32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(shader_assets.neural_primitive_vertex);
    hasher.update(shader_assets.neural_primitive_fragment);
    hasher.update(shader_assets.neural_model_vertex);
    hasher.update(shader_assets.neural_model_fragment);
    var result: [32]u8 = undefined;
    hasher.final(&result);
    return result;
}

const NeuralVertexUniforms = extern struct {
    current_mvp: [16]f32,
    previous_mvp: [16]f32,
    model: [16]f32,
    normal_matrix: [16]f32,
    model_view: [16]f32,
};

const NeuralFragmentSettings = extern struct {
    use_texture: f32,
    history_valid: f32,
    near_plane: f32,
    far_plane: f32,
    base_color: [4]f32,
    semantic_color: [4]f32,
    instance_color: [4]f32,
};

comptime {
    std.debug.assert(@sizeOf(NeuralVertexUniforms) == 320);
    std.debug.assert(@sizeOf(NeuralFragmentSettings) == 64);
}

pub const Draw = struct {
    identity: contract.DrawIdentity,
    mesh: *const mesh_module.Mesh,
    diffuse_texture: ?texture_module.Texture,
    base_color: [4]f32,
    model: zm.Mat,
    view_projection: zm.Mat,
    /// Optional adapter-specific source carried by the immutable draw record.
    /// It is never rasterized into the model ABI and never reaches authority.
    target_source: ?target_contract.Source = null,
};

const Previous = struct {
    mvp: [16]f32,
    seen_frame: u64,
};

pub const TextureView = struct {
    channel: contract.Channel,
    binding: *const anyopaque,
    width: u32,
    height: u32,
};

pub const Diagnostics = struct {
    available: bool,
    schema_version: u16,
    schema_name: []const u8,
    schema_fingerprint: []const u8,
    shader_fingerprint: []const u8,
    authority_tick: u64,
    presentation_frame: u64,
    draw_count: usize,
    history_valid_draws: usize,
    history_reset_draws: usize,
    global_controls: contract.FrameGlobalControls,
    compact_id_collisions: u64,
    rendered_frames: u64,
    render_failures: u64,
    last_command_encoding_ns: u64,
    total_command_encoding_ns: u64,
    maximum_command_encoding_ns: u64,
    last_error: []const u8,
    views: [contract.channels.len]TextureView,
};

pub const Owner = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    device: *c.SDL_GPUDevice,
    depth_format: c.SDL_GPUTextureFormat,
    sampler: *c.SDL_GPUSampler,
    placeholder: texture_module.Texture,
    primitive_pipeline: *c.SDL_GPUGraphicsPipeline,
    model_pipeline: *c.SDL_GPUGraphicsPipeline,
    targets: [contract.channels.len]*c.SDL_GPUTexture,
    bindings: [contract.channels.len]c.SDL_GPUTextureSamplerBinding,
    depth: *c.SDL_GPUTexture,
    draws: std.ArrayList(Draw),
    previous: std.AutoHashMap(u64, Previous),
    current_ids: std.AutoHashMap(u32, u64),
    frame: contract.Frame = .{
        .authority_tick = 0,
        .presentation_frame = 0,
        .interpolation_alpha = 0,
        .target_width = contract.target_width,
        .target_height = contract.target_height,
        .history_reset = .first_frame,
    },
    view: zm.Mat = zm.identity(),
    rendered_frames: u64 = 0,
    render_failures: u64 = 0,
    compact_id_collisions: u64 = 0,
    history_valid_draws: usize = 0,
    history_reset_draws: usize = 0,
    last_command_encoding_ns: u64 = 0,
    total_command_encoding_ns: u64 = 0,
    maximum_command_encoding_ns: u64 = 0,
    last_error: ?[]u8 = null,
    last_target_width: u32 = 0,
    last_target_height: u32 = 0,

    pub fn init(io: std.Io, allocator: std.mem.Allocator, gpu: *renderer.Renderer) !Owner {
        const device = gpu.getDevice();
        for ([_]c.SDL_GPUTextureFormat{ appearance_format, target_format }) |format| {
            if (!c.SDL_GPUTextureSupportsFormat(
                device,
                format,
                c.SDL_GPU_TEXTURETYPE_2D,
                c.SDL_GPU_TEXTUREUSAGE_COLOR_TARGET | c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
            )) return error.NeuralInputTargetFormatUnsupported;
        }

        var targets: [contract.channels.len]*c.SDL_GPUTexture = undefined;
        var initialized: usize = 0;
        errdefer for (targets[0..initialized]) |texture| {
            c.SDL_ReleaseGPUTexture(device, texture);
        };
        for (contract.channels, 0..) |channel, index| {
            targets[index] = try createColorTarget(device, channel);
            initialized += 1;
        }
        const depth = c.SDL_CreateGPUTexture(device, &c.SDL_GPUTextureCreateInfo{
            .type = c.SDL_GPU_TEXTURETYPE_2D,
            .format = gpu.getDepthFormat(),
            .usage = c.SDL_GPU_TEXTUREUSAGE_DEPTH_STENCIL_TARGET,
            .width = contract.cheap_width,
            .height = contract.cheap_height,
            .layer_count_or_depth = 1,
            .num_levels = 1,
            .sample_count = c.SDL_GPU_SAMPLECOUNT_1,
            .props = 0,
        }) orelse return error.NeuralInputDepthTargetCreationFailed;
        errdefer c.SDL_ReleaseGPUTexture(device, depth);
        const primitive_pipeline = try createPipeline(
            device,
            gpu.getDepthFormat(),
            .pos_color,
        );
        errdefer c.SDL_ReleaseGPUGraphicsPipeline(device, primitive_pipeline);
        const model_pipeline = try createPipeline(
            device,
            gpu.getDepthFormat(),
            .pos_normal_uv,
        );
        errdefer c.SDL_ReleaseGPUGraphicsPipeline(device, model_pipeline);
        var bindings: [contract.channels.len]c.SDL_GPUTextureSamplerBinding = undefined;
        for (targets, 0..) |texture, index| bindings[index] = .{
            .texture = texture,
            .sampler = gpu.getDefaultSampler(),
        };
        const draws = try std.ArrayList(Draw).initCapacity(allocator, 64);
        errdefer draws.deinit(allocator);
        return .{
            .io = io,
            .allocator = allocator,
            .device = device,
            .depth_format = gpu.getDepthFormat(),
            .sampler = gpu.getDefaultSampler(),
            .placeholder = gpu.getPlaceholderTexture(),
            .primitive_pipeline = primitive_pipeline,
            .model_pipeline = model_pipeline,
            .targets = targets,
            .bindings = bindings,
            .depth = depth,
            .draws = draws,
            .previous = std.AutoHashMap(u64, Previous).init(allocator),
            .current_ids = std.AutoHashMap(u32, u64).init(allocator),
        };
    }

    pub fn deinit(self: *Owner) void {
        if (self.last_error) |value| self.allocator.free(value);
        self.current_ids.deinit();
        self.previous.deinit();
        self.draws.deinit(self.allocator);
        c.SDL_ReleaseGPUGraphicsPipeline(self.device, self.model_pipeline);
        c.SDL_ReleaseGPUGraphicsPipeline(self.device, self.primitive_pipeline);
        c.SDL_ReleaseGPUTexture(self.device, self.depth);
        for (self.targets) |texture| c.SDL_ReleaseGPUTexture(self.device, texture);
        self.* = undefined;
    }

    pub fn beginFrame(self: *Owner, frame: contract.Frame, view: zm.Mat) !void {
        try frame.validate();
        self.draws.clearRetainingCapacity();
        self.current_ids.clearRetainingCapacity();
        self.frame = frame;
        if (self.rendered_frames != 0 and
            (self.last_target_width != frame.target_width or
                self.last_target_height != frame.target_height))
        {
            self.frame.history_reset = .resize;
        }
        self.last_target_width = frame.target_width;
        self.last_target_height = frame.target_height;
        self.view = view;
        self.history_valid_draws = 0;
        self.history_reset_draws = 0;
        if (self.last_error) |value| self.allocator.free(value);
        self.last_error = null;
    }

    pub fn record(self: *Owner, draw: Draw) !void {
        const key = draw.identity.stableKey();
        const compact = draw.identity.compactCode();
        const entry = try self.current_ids.getOrPut(compact);
        if (entry.found_existing and entry.value_ptr.* != key) {
            self.compact_id_collisions +|= 1;
            self.setError("compact instance identity collision");
            return error.NeuralCompactIdentityCollision;
        }
        entry.value_ptr.* = key;
        try self.draws.append(self.allocator, draw);
    }

    /// Render all six channels into independent low-resolution targets using
    /// the same frame command buffer. Product output remains untouched.
    pub fn render(self: *Owner, gpu: *renderer.Renderer) !void {
        const started_ns = monotonicNowNs(self.io);
        const cmd = gpu.getCurrentCommandBuffer() orelse
            return error.NeuralInputNoFrameInProgress;
        if (self.draws.items.len == 0) return error.NeuralInputFrameHasNoDraws;
        const targets = [_]c.SDL_GPUColorTargetInfo{
            colorTargetInfo(self.targets[0], .appearance),
            colorTargetInfo(self.targets[1], .linear_depth),
            colorTargetInfo(self.targets[2], .world_normal),
            colorTargetInfo(self.targets[3], .motion),
            colorTargetInfo(self.targets[4], .semantic),
            colorTargetInfo(self.targets[5], .instance),
        };
        const depth = c.SDL_GPUDepthStencilTargetInfo{
            .texture = self.depth,
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
        const pass = c.SDL_BeginGPURenderPass(cmd, &targets, targets.len, &depth) orelse {
            self.render_failures +|= 1;
            self.setSdlError("neural input render pass failed");
            return error.NeuralInputRenderPassBeginFailed;
        };
        for (self.draws.items) |draw| self.drawOne(cmd, pass, draw);
        c.SDL_EndGPURenderPass(pass);

        // Motion requires exactly the preceding presentation frame. Retaining
        // older identities cannot make history valid and would turn streamed
        // world traversal into unbounded adapter memory.
        self.previous.clearRetainingCapacity();
        for (self.draws.items) |draw| {
            const key = draw.identity.stableKey();
            try self.previous.put(key, .{
                .mvp = zm.matToArr(zm.mul(draw.model, draw.view_projection)),
                .seen_frame = self.frame.presentation_frame,
            });
        }
        self.rendered_frames +|= 1;
        self.last_command_encoding_ns = monotonicNowNs(self.io) -| started_ns;
        self.total_command_encoding_ns +|= self.last_command_encoding_ns;
        self.maximum_command_encoding_ns = @max(
            self.maximum_command_encoding_ns,
            self.last_command_encoding_ns,
        );
    }

    pub fn diagnostics(self: *const Owner) Diagnostics {
        var views: [contract.channels.len]TextureView = undefined;
        for (contract.channels, 0..) |channel, index| views[index] = .{
            .channel = channel,
            .binding = @ptrCast(&self.bindings[index]),
            .width = contract.cheap_width,
            .height = contract.cheap_height,
        };
        return .{
            .available = true,
            .schema_version = contract.schema_version,
            .schema_name = contract.schema_name,
            .schema_fingerprint = contract.schema_fingerprint,
            .shader_fingerprint = shader_fingerprint,
            .authority_tick = self.frame.authority_tick,
            .presentation_frame = self.frame.presentation_frame,
            .draw_count = self.draws.items.len,
            .history_valid_draws = self.history_valid_draws,
            .history_reset_draws = self.history_reset_draws,
            .global_controls = self.frame.global_controls,
            .compact_id_collisions = self.compact_id_collisions,
            .rendered_frames = self.rendered_frames,
            .render_failures = self.render_failures,
            .last_command_encoding_ns = self.last_command_encoding_ns,
            .total_command_encoding_ns = self.total_command_encoding_ns,
            .maximum_command_encoding_ns = self.maximum_command_encoding_ns,
            .last_error = self.last_error orelse "",
            .views = views,
        };
    }

    pub fn drawsView(self: *const Owner) []const Draw {
        return self.draws.items;
    }

    pub fn frameView(self: *const Owner) contract.Frame {
        return self.frame;
    }

    pub fn cameraViewMatrix(self: *const Owner) zm.Mat {
        return self.view;
    }

    pub fn target(self: *const Owner, channel: contract.Channel) *c.SDL_GPUTexture {
        return self.targets[@intFromEnum(channel)];
    }

    fn drawOne(
        self: *Owner,
        cmd: *c.SDL_GPUCommandBuffer,
        pass: *c.SDL_GPURenderPass,
        draw: Draw,
    ) void {
        const key = draw.identity.stableKey();
        const current_mvp = zm.matToArr(zm.mul(draw.model, draw.view_projection));
        const previous_entry = self.previous.get(key);
        const history_valid = if (previous_entry) |previous|
            previous.seen_frame +| 1 == self.frame.presentation_frame and
                self.frame.history_reset == .none
        else
            false;
        if (history_valid) self.history_valid_draws += 1 else self.history_reset_draws += 1;
        const uniforms = NeuralVertexUniforms{
            .current_mvp = current_mvp,
            .previous_mvp = if (history_valid) previous_entry.?.mvp else current_mvp,
            .model = zm.matToArr(draw.model),
            .normal_matrix = zm.matToArr(zm.transpose(zm.inverse(draw.model))),
            .model_view = zm.matToArr(zm.mul(draw.model, self.view)),
        };
        c.SDL_PushGPUVertexUniformData(cmd, 0, &uniforms, @sizeOf(NeuralVertexUniforms));
        const settings = NeuralFragmentSettings{
            .use_texture = if (draw.mesh.vertex_format == .pos_normal_uv and
                draw.diffuse_texture != null) 1 else 0,
            .history_valid = if (history_valid) 1 else 0,
            .near_plane = self.frame.near,
            .far_plane = self.frame.far,
            .base_color = draw.base_color,
            .semantic_color = encodeSemantic(draw.identity.semantic, draw.identity.part),
            .instance_color = encodeInstance(draw.identity.compactCode()),
        };
        c.SDL_PushGPUFragmentUniformData(cmd, 0, &settings, @sizeOf(NeuralFragmentSettings));
        switch (draw.mesh.vertex_format) {
            .pos_color => c.SDL_BindGPUGraphicsPipeline(pass, self.primitive_pipeline),
            .pos_normal_uv => {
                c.SDL_BindGPUGraphicsPipeline(pass, self.model_pipeline);
                const binding = c.SDL_GPUTextureSamplerBinding{
                    .texture = if (draw.diffuse_texture) |texture|
                        texture.getHandle()
                    else
                        self.placeholder.getHandle(),
                    .sampler = self.sampler,
                };
                c.SDL_BindGPUFragmentSamplers(pass, 0, &binding, 1);
            },
        }
        const vertex_binding = c.SDL_GPUBufferBinding{
            .buffer = draw.mesh.vertex_buffer,
            .offset = 0,
        };
        c.SDL_BindGPUVertexBuffers(pass, 0, &vertex_binding, 1);
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

    fn setError(self: *Owner, value: []const u8) void {
        if (self.last_error) |previous| self.allocator.free(previous);
        self.last_error = self.allocator.dupe(u8, value) catch null;
    }

    fn setSdlError(self: *Owner, prefix: []const u8) void {
        const value = std.fmt.allocPrint(
            self.allocator,
            "{s}: {s}",
            .{ prefix, c.SDL_GetError() },
        ) catch {
            self.setError(prefix);
            return;
        };
        defer self.allocator.free(value);
        self.setError(value);
    }
};

fn createColorTarget(
    device: *c.SDL_GPUDevice,
    channel: contract.Channel,
) !*c.SDL_GPUTexture {
    return c.SDL_CreateGPUTexture(device, &c.SDL_GPUTextureCreateInfo{
        .type = c.SDL_GPU_TEXTURETYPE_2D,
        .format = if (channel == .appearance) appearance_format else target_format,
        .usage = c.SDL_GPU_TEXTUREUSAGE_COLOR_TARGET | c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
        .width = contract.cheap_width,
        .height = contract.cheap_height,
        .layer_count_or_depth = 1,
        .num_levels = 1,
        .sample_count = c.SDL_GPU_SAMPLECOUNT_1,
        .props = 0,
    }) orelse error.NeuralInputColorTargetCreationFailed;
}

fn monotonicNowNs(io: std.Io) u64 {
    const value = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
    if (value <= 0) return 0;
    return std.math.cast(u64, value) orelse std.math.maxInt(u64);
}

fn colorTargetInfo(
    texture: *c.SDL_GPUTexture,
    channel: contract.Channel,
) c.SDL_GPUColorTargetInfo {
    const clear: c.SDL_FColor = switch (channel) {
        .appearance => .{ .r = 0.392, .g = 0.584, .b = 0.929, .a = 0 },
        .linear_depth => .{ .r = 1, .g = 1, .b = 1, .a = 0 },
        .world_normal => .{ .r = 0.5, .g = 0.5, .b = 1, .a = 0 },
        .motion => .{ .r = 0.5, .g = 0.5, .b = 0, .a = 0 },
        .semantic, .instance => .{ .r = 0, .g = 0, .b = 0, .a = 0 },
    };
    return .{
        .texture = texture,
        .mip_level = 0,
        .layer_or_depth_plane = 0,
        .clear_color = clear,
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

fn encodeSemantic(semantic: contract.SemanticClass, part: contract.SemanticPart) [4]f32 {
    const color = contract.semanticPalette(semantic, part);
    return .{
        @as(f32, @floatFromInt(color[0])) / 255.0,
        @as(f32, @floatFromInt(color[1])) / 255.0,
        @as(f32, @floatFromInt(color[2])) / 255.0,
        1,
    };
}

fn encodeInstance(code: u32) [4]f32 {
    return .{
        @as(f32, @floatFromInt(code & 0xff)) / 255.0,
        @as(f32, @floatFromInt((code >> 8) & 0xff)) / 255.0,
        @as(f32, @floatFromInt((code >> 16) & 0xff)) / 255.0,
        1,
    };
}

fn colorTargetDescription(channel: contract.Channel) c.SDL_GPUColorTargetDescription {
    return .{
        .format = if (channel == .appearance) appearance_format else target_format,
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

fn createPipeline(
    device: *c.SDL_GPUDevice,
    depth_format: c.SDL_GPUTextureFormat,
    vertex_format: mesh_module.VertexFormat,
) !*c.SDL_GPUGraphicsPipeline {
    const vertex_code = switch (vertex_format) {
        .pos_color => shader_assets.neural_primitive_vertex,
        .pos_normal_uv => shader_assets.neural_model_vertex,
    };
    const fragment_code = switch (vertex_format) {
        .pos_color => shader_assets.neural_primitive_fragment,
        .pos_normal_uv => shader_assets.neural_model_fragment,
    };
    const vertex = c.SDL_CreateGPUShader(device, &c.SDL_GPUShaderCreateInfo{
        .code = vertex_code.ptr,
        .code_size = vertex_code.len,
        .entrypoint = shader_assets.entrypoint,
        .format = c.SDL_GPU_SHADERFORMAT_MSL,
        .stage = c.SDL_GPU_SHADERSTAGE_VERTEX,
        .num_samplers = 0,
        .num_storage_textures = 0,
        .num_storage_buffers = 0,
        .num_uniform_buffers = 1,
        .props = 0,
    }) orelse return error.NeuralInputVertexShaderCreationFailed;
    defer c.SDL_ReleaseGPUShader(device, vertex);
    const fragment = c.SDL_CreateGPUShader(device, &c.SDL_GPUShaderCreateInfo{
        .code = fragment_code.ptr,
        .code_size = fragment_code.len,
        .entrypoint = shader_assets.entrypoint,
        .format = c.SDL_GPU_SHADERFORMAT_MSL,
        .stage = c.SDL_GPU_SHADERSTAGE_FRAGMENT,
        .num_samplers = if (vertex_format == .pos_normal_uv) 1 else 0,
        .num_storage_textures = 0,
        .num_storage_buffers = 0,
        .num_uniform_buffers = 1,
        .props = 0,
    }) orelse return error.NeuralInputFragmentShaderCreationFailed;
    defer c.SDL_ReleaseGPUShader(device, fragment);

    const vertex_buffer = c.SDL_GPUVertexBufferDescription{
        .slot = 0,
        .pitch = vertex_format.stride(),
        .input_rate = c.SDL_GPU_VERTEXINPUTRATE_VERTEX,
        .instance_step_rate = 0,
    };
    const primitive_attributes = [_]c.SDL_GPUVertexAttribute{
        .{ .location = 0, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT3, .offset = @offsetOf(mesh_module.Vertex, "position") },
        .{ .location = 1, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT3, .offset = @offsetOf(mesh_module.Vertex, "color") },
    };
    const model_attributes = [_]c.SDL_GPUVertexAttribute{
        .{ .location = 0, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT3, .offset = @offsetOf(mesh_module.VertexPNU, "position") },
        .{ .location = 1, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT3, .offset = @offsetOf(mesh_module.VertexPNU, "normal") },
        .{ .location = 2, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2, .offset = @offsetOf(mesh_module.VertexPNU, "texcoord") },
    };
    const attributes: []const c.SDL_GPUVertexAttribute = switch (vertex_format) {
        .pos_color => &primitive_attributes,
        .pos_normal_uv => &model_attributes,
    };
    var target_descriptions: [contract.channels.len]c.SDL_GPUColorTargetDescription = undefined;
    for (contract.channels, 0..) |channel, index| {
        target_descriptions[index] = colorTargetDescription(channel);
    }
    return c.SDL_CreateGPUGraphicsPipeline(device, &c.SDL_GPUGraphicsPipelineCreateInfo{
        .vertex_shader = vertex,
        .fragment_shader = fragment,
        .vertex_input_state = .{
            .vertex_buffer_descriptions = &vertex_buffer,
            .num_vertex_buffers = 1,
            .vertex_attributes = attributes.ptr,
            .num_vertex_attributes = @intCast(attributes.len),
        },
        .primitive_type = c.SDL_GPU_PRIMITIVETYPE_TRIANGLELIST,
        .rasterizer_state = .{
            .fill_mode = c.SDL_GPU_FILLMODE_FILL,
            .cull_mode = c.SDL_GPU_CULLMODE_BACK,
            .front_face = if (vertex_format == .pos_color)
                c.SDL_GPU_FRONTFACE_CLOCKWISE
            else
                c.SDL_GPU_FRONTFACE_COUNTER_CLOCKWISE,
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
            .color_target_descriptions = &target_descriptions,
            .num_color_targets = target_descriptions.len,
            .depth_stencil_format = depth_format,
            .has_depth_stencil_target = true,
            .padding1 = 0,
            .padding2 = 0,
            .padding3 = 0,
        },
        .props = 0,
    }) orelse error.NeuralInputPipelineCreationFailed;
}

test "schema GPU encodings reserve transparent zero for background" {
    try std.testing.expectEqual([4]f32{ 1.0 / 255.0, 0, 0, 1 }, encodeInstance(1));
    try std.testing.expectEqual(
        [4]f32{ 1, 64.0 / 255.0, 64.0 / 255.0, 1 },
        encodeSemantic(.npc, .whole),
    );
}
