//! Real queued SDL events, real ImGui windows, and a Metal-presented frame.
const std = @import("std");
const zgui = @import("zgui");
const editor_module = @import("editor/editor.zig");
const input = @import("input.zig");
const c = @import("sdl.zig").c;

fn draw(editor: *editor_module.Editor, window: *c.SDL_Window, device: *c.SDL_GPUDevice) !void {
    editor.backend.newFrame(640, 360, 1);
    _ = zgui.dockSpaceOverViewport(0, zgui.getMainViewport(), .{
        .passthru_central_node = true,
        .no_docking_over_central_node = true,
    });
    zgui.setNextWindowPos(.{ .x = 150, .y = 80, .cond = .always });
    zgui.setNextWindowSize(.{ .w = 240, .h = 180, .cond = .always });
    if (zgui.begin("Inspector Pointer Acceptance", .{ .flags = .{ .no_saved_settings = true } })) {
        zgui.text("Unapplied Inspector draft", .{});
        _ = zgui.button("Apply Position", .{});
    }
    zgui.end();
    const command = c.SDL_AcquireGPUCommandBuffer(device) orelse return error.CommandBufferFailed;
    var texture: ?*c.SDL_GPUTexture = null;
    var width: u32 = 0;
    var height: u32 = 0;
    if (!c.SDL_WaitAndAcquireGPUSwapchainTexture(command, window, &texture, &width, &height))
        return error.SwapchainFailed;
    if (texture) |target| {
        editor.backend.render(command, target);
    } else zgui.render();
    if (!c.SDL_SubmitGPUCommandBuffer(command)) return error.SubmitFailed;
}

fn button(window: *c.SDL_Window, down: bool, x: f32, y: f32) !void {
    var event = std.mem.zeroes(c.SDL_Event);
    event.type = if (down) c.SDL_EVENT_MOUSE_BUTTON_DOWN else c.SDL_EVENT_MOUSE_BUTTON_UP;
    event.button.windowID = c.SDL_GetWindowID(window);
    event.button.button = c.SDL_BUTTON_LEFT;
    event.button.down = down;
    event.button.x = x;
    event.button.y = y;
    if (!c.SDL_PushEvent(&event)) return error.PushFailed;
}

fn motion(window: *c.SDL_Window, x: f32, y: f32) !void {
    var event = std.mem.zeroes(c.SDL_Event);
    event.type = c.SDL_EVENT_MOUSE_MOTION;
    event.motion.windowID = c.SDL_GetWindowID(window);
    event.motion.x = x;
    event.motion.y = y;
    if (!c.SDL_PushEvent(&event)) return error.PushFailed;
}

test "floating Inspector native acceptance owns same-pump press drag release in both viewport modes" {
    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) return error.SDLInitFailed;
    defer c.SDL_Quit();
    const window = c.SDL_CreateWindow("Incinerator Editor Pointer Acceptance", 640, 360, 0) orelse return error.WindowFailed;
    defer c.SDL_DestroyWindow(window);
    const device = c.SDL_CreateGPUDevice(c.SDL_GPU_SHADERFORMAT_MSL, true, "metal") orelse return error.MetalFailed;
    defer c.SDL_DestroyGPUDevice(device);
    if (!c.SDL_ClaimWindowForGPUDevice(device, window)) return error.ClaimFailed;
    defer c.SDL_ReleaseWindowFromGPUDevice(device, window);
    var editor = editor_module.Editor.init(window, device, c.SDL_GetGPUSwapchainTextureFormat(device, window));
    defer editor.deinit();
    zgui.io.setIniFilename(null);
    editor.scene_rect = input.viewport.SceneRect.init(.{ 0, 0 }, .{ 640, 360 });
    var owner = input.InputBuffer.init(c.SDL_GetWindowID(window));
    try owner.attachGameplayMouseWindow(window);
    defer owner.detachGameplayMouseWindow();
    _ = c.SDL_RaiseWindow(window);
    _ = c.SDL_SyncWindow(window);
    c.SDL_WarpMouseInWindow(window, 550, 320);
    try std.testing.expect(owner.pumpEvents(editor.eventSink()));
    try draw(&editor, window, device);
    try draw(&editor, window, device);

    for ([_]input.viewport.Mode{ .free_camera, .character }) |mode| {
        owner.setViewportMode(mode);
        editor.setViewportMode(mode);
        // No ImGui NewFrame between movement into the floating panel and press.
        try motion(window, 200, 120);
        try button(window, true, 200, 120);
        owner.beginFrame();
        try std.testing.expect(owner.pumpEvents(editor.eventSink()));
        try std.testing.expect(!owner.gameplayMouseLocked());
        try std.testing.expect(owner.takeFreeCameraSelectionClick() == null);
        try std.testing.expect(!owner.isMouseButtonPressed(input.MouseButton.LEFT));
        try motion(window, 550, 320);
        owner.beginFrame();
        try std.testing.expect(owner.pumpEvents(editor.eventSink()));
        try std.testing.expect(editor.wantsMouse());
        try button(window, false, 550, 320);
        try std.testing.expect(owner.pumpEvents(editor.eventSink()));
        try std.testing.expectEqual(@as(u32, 0), editor.backend.pointer_buttons);
        try button(window, true, 200, 120);
        try std.testing.expect(owner.pumpEvents(editor.eventSink()));
        var lost = std.mem.zeroes(c.SDL_Event);
        lost.type = c.SDL_EVENT_WINDOW_FOCUS_LOST;
        lost.window.windowID = c.SDL_GetWindowID(window);
        if (!c.SDL_PushEvent(&lost)) return error.PushFailed;
        try std.testing.expect(owner.pumpEvents(editor.eventSink()));
        try std.testing.expectEqual(@as(u32, 0), editor.backend.pointer_buttons);
        try button(window, false, 200, 120);
        try std.testing.expect(owner.pumpEvents(editor.eventSink()));
        // The next press over the passthrough central scene belongs to it.
        try button(window, true, 550, 320);
        owner.beginFrame();
        try std.testing.expect(owner.pumpEvents(editor.eventSink()));
        if (mode == .free_camera) {
            try std.testing.expect(owner.takeFreeCameraSelectionClick() != null);
        } else try std.testing.expect(owner.gameplayMouseLocked());
        try button(window, false, 550, 320);
        try std.testing.expect(owner.pumpEvents(editor.eventSink()));
    }
    try std.testing.expect(c.SDL_WaitForGPUIdle(device));
}
