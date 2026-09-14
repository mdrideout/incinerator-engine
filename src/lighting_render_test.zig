//! Native lighting/image acceptance. Never activates or presents a window.
const std = @import("std");
const c = @import("sdl.zig").c;
const renderer = @import("renderer.zig");
const mesh = @import("mesh.zig");
const zm = @import("zmath");

pub fn pixels(gpu: *renderer.Renderer, texture: *c.SDL_GPUTexture, width: u32, height: u32, stride: u32) ![]u8 {
    const count = try std.math.mul(u32, try std.math.mul(u32, width, height), stride);
    const device = gpu.device;
    const transfer = c.SDL_CreateGPUTransferBuffer(device, &std.mem.zeroInit(c.SDL_GPUTransferBufferCreateInfo, .{
        .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_DOWNLOAD,
        .size = count,
    })) orelse return error.LightingReadbackAllocationFailed;
    defer c.SDL_ReleaseGPUTransferBuffer(device, transfer);
    const cmd = c.SDL_AcquireGPUCommandBuffer(device) orelse return error.LightingReadbackCommandFailed;
    const copy = c.SDL_BeginGPUCopyPass(cmd) orelse {
        _ = c.SDL_CancelGPUCommandBuffer(cmd);
        return error.LightingReadbackCopyFailed;
    };
    c.SDL_DownloadFromGPUTexture(copy, &std.mem.zeroInit(c.SDL_GPUTextureRegion, .{ .texture = texture, .w = width, .h = height, .d = 1 }), &std.mem.zeroInit(c.SDL_GPUTextureTransferInfo, .{ .transfer_buffer = transfer, .pixels_per_row = width, .rows_per_layer = height }));
    c.SDL_EndGPUCopyPass(copy);
    const fence = c.SDL_SubmitGPUCommandBufferAndAcquireFence(cmd) orelse return error.LightingReadbackSubmitFailed;
    defer c.SDL_ReleaseGPUFence(device, fence);
    const fences = [_]?*c.SDL_GPUFence{fence};
    if (!c.SDL_WaitForGPUFences(device, true, &fences, 1)) return error.LightingReadbackFenceFailed;
    const mapped = c.SDL_MapGPUTransferBuffer(device, transfer, false) orelse return error.LightingReadbackMapFailed;
    defer c.SDL_UnmapGPUTransferBuffer(device, transfer);
    return std.testing.allocator.dupe(u8, @as([*]const u8, @ptrCast(mapped))[0..count]);
}

test "EA3 hidden Metal preserves HDR and resolves exposure for captures" {
    try std.testing.expect(c.SDL_SetHint(c.SDL_HINT_MAC_BACKGROUND_APP, "1"));
    try std.testing.expect(c.SDL_SetHint(c.SDL_HINT_WINDOW_ACTIVATE_WHEN_SHOWN, "0"));
    try std.testing.expect(c.SDL_Init(c.SDL_INIT_VIDEO));
    defer c.SDL_Quit();
    const window = c.SDL_CreateWindow("EA3 offscreen", 256, 256, c.SDL_WINDOW_HIDDEN) orelse return error.WindowFailed;
    defer c.SDL_DestroyWindow(window);
    var gpu = try renderer.Renderer.initOffscreen(window, 256, 256);
    defer gpu.deinit();
    const vertices = [_]mesh.VertexPNU{
        .{ .position = .{ -0.5, -0.5, 0.5 }, .normal = .{ 0, 0, 1 }, .texcoord = .{ 0, 0 } },
        .{ .position = .{ 0.5, -0.5, 0.5 }, .normal = .{ 0, 0, 1 }, .texcoord = .{ 1, 0 } },
        .{ .position = .{ 0.5, 0.5, 0.5 }, .normal = .{ 0, 0, 1 }, .texcoord = .{ 1, 1 } },
        .{ .position = .{ -0.5, -0.5, 0.5 }, .normal = .{ 0, 0, 1 }, .texcoord = .{ 0, 0 } },
        .{ .position = .{ 0.5, 0.5, 0.5 }, .normal = .{ 0, 0, 1 }, .texcoord = .{ 1, 1 } },
        .{ .position = .{ -0.5, 0.5, 0.5 }, .normal = .{ 0, 0, 1 }, .texcoord = .{ 0, 1 } },
    };
    var shape = try mesh.Mesh.initTextured(gpu.device, &vertices);
    defer shape.deinit();
    var colored_vertices: [vertices.len]mesh.Vertex = undefined;
    for (vertices, &colored_vertices) |source, *destination| destination.* = .{ .position = source.position, .color = .{ 1, 1, 1 } };
    // Engine colored primitives use CW fronts; imported glTF uses CCW.
    for (0..vertices.len / 3) |triangle| std.mem.swap(mesh.Vertex, &colored_vertices[triangle * 3 + 1], &colored_vertices[triangle * 3 + 2]);
    var colored = try mesh.Mesh.init(gpu.device, &colored_vertices);
    defer colored.deinit();

    for ([_]f32{ 1, 0.5 }) |exposure| {
        gpu.display_settings = .{ .exposure = exposure, .bloom_strength = 0 };
        try std.testing.expectEqual(.ready, try gpu.beginFrame(.{ 0.1, 0.1, 0.1, 1 }));
        gpu.drawMeshWithTextures(&shape, .{}, .{ .base_color = .{ 0, 0, 0, 1 }, .lit = false, .emissive = .{ 8, 2, 1 } }, zm.identity(), zm.identity());
        try gpu.endRenderPass();
        try gpu.submitFrame();
        const raw = try pixels(&gpu, gpu.hdr.targets.scene.texture, 256, 256, 8);
        defer std.testing.allocator.free(raw);
        const center = (128 * 256 + 128) * 8;
        const red: f16 = @bitCast(std.mem.readInt(u16, raw[center..][0..2], .little));
        try std.testing.expectApproxEqAbs(@as(f32, 8) * exposure, @as(f32, red), 0.01);
        const display = try pixels(&gpu, gpu.getProductSceneTexture(), 256, 256, 4);
        defer std.testing.allocator.free(display);
        const encoded = display[(128 * 256 + 128) * 4 + 2];
        const reinhard = (8 * exposure) / (1 + 8 * exposure);
        const expected = (1.055 * std.math.pow(f32, reinhard, 1.0 / 2.4) - 0.055) * 255;
        try std.testing.expectApproxEqAbs(expected, @as(f32, @floatFromInt(encoded)), 2);
        try std.testing.expect(gpu.getSwapchainTexture() == null);
        try std.testing.expect(c.SDL_GetKeyboardFocus() != window);
    }
    try @import("vehicle_offscreen_capture.zig").write(&gpu, "zig-out/ea3-hdr.ppm");
    gpu.display_settings = .{ .exposure = 1, .bloom_strength = 0 };
    try gpu.setSceneLight(.{ .sun_direction = .{ 0, 0, 1 }, .sun_color = .{ 1, 1, 1 }, .sun_intensity = 0, .ambient_color = .{ 0, 0, 0 } });
    gpu.camera_position = .{ 0, 0, 10 };
    // At normal incidence, a white dielectric with roughness 1 has diffuse
    // 0.96/pi plus specular 0.01/pi. Compare linear HDR, before tone mapping.
    const Sample = struct { kind: @import("engine_contracts").lighting.Kind, distance: f32, range: ?f32 = null, rotation: [4]f32 = .{ 0, 0, 0, 1 }, enabled: bool = true, expected: f32 };
    const response: f32 = 0.97 / std.math.pi;
    for ([_]Sample{
        .{ .kind = .point, .distance = 2, .expected = 100 / 4 * response },
        .{ .kind = .point, .distance = 4, .expected = 100.0 / 16.0 * response },
        .{ .kind = .spot, .distance = 2, .expected = 100 / 4 * response },
        .{ .kind = .point, .distance = 2, .range = 1, .expected = 0 },
        .{ .kind = .spot, .distance = 2, .rotation = .{ 0, 1, 0, 0 }, .expected = 0 },
        .{ .kind = .point, .distance = 2, .enabled = false, .expected = 0 },
    }) |sample| {
        for ([_]*const mesh.Mesh{ &shape, &colored }) |probe| {
            try gpu.lights.set(&.{.{ .id = 1, .pose = .{ .position = .{ 0, 0, 0.5 + sample.distance }, .rotation = sample.rotation }, .light = .{ .kind = sample.kind, .intensity = 100, .range = sample.range, .enabled = sample.enabled, .casts_shadows = false } }});
            try std.testing.expectEqual(.ready, try gpu.beginFrame(.{ 0, 0, 0, 1 }));
            gpu.drawMeshWithTextures(probe, .{}, .{ .base_color = .{ 1, 1, 1, 1 } }, zm.identity(), zm.identity());
            try gpu.endRenderPass();
            try gpu.submitFrame();
            const raw = try pixels(&gpu, gpu.hdr.targets.scene.texture, 256, 256, 8);
            defer std.testing.allocator.free(raw);
            const center = (128 * 256 + 128) * 8;
            const red: f16 = @bitCast(std.mem.readInt(u16, raw[center..][0..2], .little));
            // Half-float storage and the off-center pixel change the ideal probe
            // by less than 0.2%; 0.01 also bounds the zero-contribution cases.
            try std.testing.expectApproxEqAbs(sample.expected, @as(f32, red), 0.01);
        }
    }
    // Blocker lies beyond the camera far plane, but between the light and the
    // receiver. Its shadow must still be present in the product image.
    for ([_]@import("engine_contracts").lighting.Kind{ .spot, .point, .directional }) |kind| {
        for ([_]bool{ false, true }) |shadowed| {
            try gpu.lights.set(&.{.{ .id = 9, .pose = .{ .position = .{ 0, 0, 2.5 } }, .light = .{ .kind = kind, .intensity = if (kind == .directional) 25 else 100, .range = null, .casts_shadows = shadowed } }});
            try std.testing.expectEqual(.ready, try gpu.beginFrame(.{ 0, 0, 0, 1 }));
            gpu.drawMeshWithTextures(&shape, .{}, .{ .base_color = .{ 1, 1, 1, 1 } }, zm.identity(), zm.identity());
            gpu.drawMeshWithTextures(&colored, .{}, .{ .base_color = .{ 1, 0, 0, 1 } }, zm.mul(zm.scaling(0.2, 0.2, 1), zm.translation(0, 0, 1)), zm.identity());
            try gpu.endRenderPass();
            try gpu.submitFrame();
            const raw = try pixels(&gpu, gpu.hdr.targets.scene.texture, 256, 256, 8);
            defer std.testing.allocator.free(raw);
            const center = (128 * 256 + 128) * 8;
            const red: f16 = @bitCast(std.mem.readInt(u16, raw[center..][0..2], .little));
            if (shadowed) {
                try std.testing.expect(@as(f32, red) < 0.01);
                try std.testing.expectEqual(@as(usize, if (kind == .point) 6 else 1), gpu.lights.shadows.?.views.items.len);
                const outside = (128 * 256 + 176) * 8;
                const lit: f16 = @bitCast(std.mem.readInt(u16, raw[outside..][0..2], .little));
                try std.testing.expect(@as(f32, lit) > 1);
            } else try std.testing.expectApproxEqAbs(25 * response, @as(f32, red), 0.01);
        }
    }
    try @import("vehicle_offscreen_capture.zig").write(&gpu, "zig-out/ea3-shadow.ppm");
    // Rotate receiver and camera together to sample every cube face, both
    // sides of a face boundary, and the hemispherical spotlight representation.
    const light_contract = @import("engine_contracts").lighting;
    const transform = @import("engine_contracts").transform;
    for ([_][3]f32{ .{ 1, 0, 0 }, .{ -1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, -1, 0 }, .{ 0, 0, 1 }, .{ 0, 0, -1 }, .{ 0.7063997, 0, -0.7078135 }, .{ 0.7078135, 0, -0.7063997 } }) |ray| {
        const rotation = try light_contract.rotationFromDirection(ray);
        const model = zm.quatToMat(zm.loadArr4(rotation));
        const view = zm.transpose(model);
        gpu.camera_position = transform.rotateVector(rotation, .{ 0, 0, 10 });
        for ([_]light_contract.Kind{ .point, .spot }) |kind| {
            try gpu.lights.set(&.{.{ .id = 10, .pose = .{ .position = transform.rotateVector(rotation, .{ 0, 0, 2.5 }), .rotation = rotation }, .light = .{ .kind = kind, .intensity = 100, .range = null, .outer_angle = std.math.pi / 2.0, .casts_shadows = true } }});
            try std.testing.expectEqual(.ready, try gpu.beginFrame(.{ 0, 0, 0, 1 }));
            gpu.drawMeshWithTextures(&shape, .{}, .{ .base_color = .{ 1, 1, 1, 1 } }, model, view);
            gpu.drawMeshWithTextures(&colored, .{}, .{ .base_color = .{ 1, 0, 0, 1 } }, zm.mul(zm.mul(zm.scaling(0.2, 0.2, 1), zm.translation(0, 0, 1)), model), view);
            try gpu.endRenderPass();
            try gpu.submitFrame();
            const raw = try pixels(&gpu, gpu.hdr.targets.scene.texture, 256, 256, 8);
            defer std.testing.allocator.free(raw);
            const center: f16 = @bitCast(std.mem.readInt(u16, raw[(128 * 256 + 128) * 8 ..][0..2], .little));
            const outside: f16 = @bitCast(std.mem.readInt(u16, raw[(128 * 256 + 176) * 8 ..][0..2], .little));
            try std.testing.expect(@as(f32, center) < 0.01);
            try std.testing.expect(@as(f32, outside) > 1);
            try std.testing.expectEqual(@as(usize, 6), gpu.lights.shadows.?.views.items.len);
        }
    }
    gpu.camera_position = .{ 0, 0, 10 };
    std.debug.print("EA3_CUBE all_faces=true seam_sides=true hemispherical_spot=true\n", .{});

    try gpu.lights.set(&.{});
    gpu.lights.environment = null;
    // Bloom transports image energy outside an emissive face without adding a
    // local emitter; disabling it removes only that optical halo.
    var no_bloom: u8 = 0;
    for ([_]f32{ 0, 0.3 }) |strength| {
        gpu.display_settings = .{ .exposure = 1, .bloom_strength = strength, .bloom_radius = 32 };
        try std.testing.expectEqual(.ready, try gpu.beginFrame(.{ 0, 0, 0, 1 }));
        gpu.drawMeshWithTextures(&shape, .{}, .{ .base_color = .{ 0, 0, 0, 1 }, .lit = false, .emissive = .{ 8, 2, 1 } }, zm.identity(), zm.identity());
        try gpu.endRenderPass();
        try gpu.submitFrame();
        const display = try pixels(&gpu, gpu.getProductSceneTexture(), 256, 256, 4);
        defer std.testing.allocator.free(display);
        const halo = display[(128 * 256 + 198) * 4 + 2];
        if (strength == 0) no_bloom = halo else try std.testing.expect(halo > no_bloom + 2);
    }
    var overlay_reference: ?[4]u8 = null;
    for ([_]f32{ 0.01, 10 }) |exposure| {
        gpu.display_settings = .{ .exposure = exposure, .bloom_strength = 0.3 };
        try std.testing.expectEqual(.ready, try gpu.beginFrame(.{ 0, 0, 0, 1 }));
        gpu.drawMeshWithTextures(&shape, .{}, .{ .base_color = .{ 0.8, 0.2, 0.1, 1 }, .lit = false, .display_space = true }, zm.identity(), zm.identity());
        try gpu.endRenderPass();
        try gpu.submitFrame();
        const display = try pixels(&gpu, gpu.getProductSceneTexture(), 256, 256, 4);
        defer std.testing.allocator.free(display);
        const center: [4]u8 = display[(128 * 256 + 128) * 4 ..][0..4].*;
        if (overlay_reference) |reference| try std.testing.expectEqual(reference, center) else overlay_reference = center;
        try std.testing.expectApproxEqAbs(@as(f32, 204), @as(f32, @floatFromInt(center[2])), 1);
    }
    var preview = try @import("material_preview.zig").Preview.init(&gpu, 256);
    defer preview.deinit();
    var neutral: ?[]u8 = null;
    defer if (neutral) |bytes| std.testing.allocator.free(bytes);
    for ([_]f32{ 0.00004, 0.06 }) |exposure| {
        try gpu.setEnvironment(.{ .display = .{ .exposure = exposure } });
        try std.testing.expectEqual(.ready, try gpu.beginFrame(.{ 0, 0, 0, 1 }));
        try gpu.endRenderPass();
        try preview.render(&gpu, &shape, .{}, .{ .base_color = .{ 0.6, 0.3, 0.1, 1 } });
        try gpu.submitFrame();
        const display = try pixels(&gpu, preview.color, 256, 256, 4);
        if (neutral) |reference| {
            defer std.testing.allocator.free(display);
            try std.testing.expectEqualSlices(u8, reference, display);
        } else neutral = display;
    }
    std.debug.print("EA3_DISPLAY bloom_isolated=true overlay_exposure_independent=true material_preview_neutral=true\n", .{});
    std.debug.print("EA3_SHADOW spot=true point_six_faces=true directional=true off_camera_blocker=true primitive_lighting=true\n", .{});
    std.debug.print("EA3_HDR hdr_rgba16f=true exposed_once=true offscreen_display=true focus=false\n", .{});
}
