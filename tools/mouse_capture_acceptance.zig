//! Native SDL acceptance for click-to-capture continuous gameplay look.

const std = @import("std");
const input = @import("input");

const c = input.sdl_c;

const EmptySink = struct {
    mode: input.viewport.Mode = .character,

    fn process(context: *anyopaque, event: *const c.SDL_Event) input.EventRoute {
        const self: *@This() = @ptrCast(@alignCast(context));
        if (event.type == c.SDL_EVENT_KEY_DOWN and !event.key.repeat and
            event.key.scancode == c.SDL_SCANCODE_F3)
        {
            self.mode = self.mode.toggled();
            return .{
                .keyboard_reserved = true,
                .viewport_mode_request = self.mode,
            };
        }
        return .{};
    }

    fn capture(_: *anyopaque) input.Capture {
        return .{};
    }

    fn sceneRect(_: *anyopaque) ?input.viewport.SceneRect {
        return input.viewport.SceneRect.init(.{ 0, 0 }, .{ 640, 360 });
    }

    fn sink(self: *EmptySink) input.EventSink {
        return .{
            .context = self,
            .process_event = process,
            .capture = capture,
            .scene_rect = sceneRect,
        };
    }
};

fn pushMouseButton(window_id: c.SDL_WindowID, down: bool) !void {
    var event = std.mem.zeroes(c.SDL_Event);
    event.type = if (down)
        c.SDL_EVENT_MOUSE_BUTTON_DOWN
    else
        c.SDL_EVENT_MOUSE_BUTTON_UP;
    event.button.windowID = window_id;
    event.button.button = c.SDL_BUTTON_LEFT;
    event.button.down = down;
    event.button.x = 320;
    event.button.y = 180;
    if (!c.SDL_PushEvent(&event)) return error.PushMouseButtonFailed;
}

fn pushMouseButtonAt(
    window_id: c.SDL_WindowID,
    button: u8,
    down: bool,
    x: f32,
    y: f32,
) !void {
    var event = std.mem.zeroes(c.SDL_Event);
    event.type = if (down)
        c.SDL_EVENT_MOUSE_BUTTON_DOWN
    else
        c.SDL_EVENT_MOUSE_BUTTON_UP;
    event.button.windowID = window_id;
    event.button.button = button;
    event.button.down = down;
    event.button.x = x;
    event.button.y = y;
    if (!c.SDL_PushEvent(&event)) return error.PushMouseButtonFailed;
}

fn pushKey(window_id: c.SDL_WindowID, scancode: c.SDL_Scancode, down: bool) !void {
    var event = std.mem.zeroes(c.SDL_Event);
    event.type = if (down) c.SDL_EVENT_KEY_DOWN else c.SDL_EVENT_KEY_UP;
    event.key.windowID = window_id;
    event.key.scancode = scancode;
    event.key.down = down;
    if (!c.SDL_PushEvent(&event)) return error.PushKeyFailed;
}

fn pushMouseMotion(window_id: c.SDL_WindowID, dx: f32, dy: f32) !void {
    var event = std.mem.zeroes(c.SDL_Event);
    event.type = c.SDL_EVENT_MOUSE_MOTION;
    event.motion.windowID = window_id;
    event.motion.x = 320;
    event.motion.y = 180;
    event.motion.xrel = dx;
    event.motion.yrel = dy;
    if (!c.SDL_PushEvent(&event)) return error.PushMouseMotionFailed;
}

fn pushMouseWheel(window_id: c.SDL_WindowID, steps: f32) !void {
    var event = std.mem.zeroes(c.SDL_Event);
    event.type = c.SDL_EVENT_MOUSE_WHEEL;
    event.wheel.windowID = window_id;
    event.wheel.y = steps;
    event.wheel.mouse_x = 320;
    event.wheel.mouse_y = 180;
    if (!c.SDL_PushEvent(&event)) return error.PushMouseWheelFailed;
}

fn pushEscape(window_id: c.SDL_WindowID) !void {
    var event = std.mem.zeroes(c.SDL_Event);
    event.type = c.SDL_EVENT_KEY_DOWN;
    event.key.windowID = window_id;
    event.key.scancode = c.SDL_SCANCODE_ESCAPE;
    event.key.key = c.SDLK_ESCAPE;
    event.key.down = true;
    if (!c.SDL_PushEvent(&event)) return error.PushEscapeFailed;
}

pub fn main() !void {
    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) return error.SDLInitFailed;
    defer c.SDL_Quit();

    const window = c.SDL_CreateWindow(
        "Incinerator Mouse Capture Acceptance",
        640,
        360,
        c.SDL_WINDOW_RESIZABLE,
    ) orelse return error.SDLWindowFailed;
    defer c.SDL_DestroyWindow(window);

    const window_id = c.SDL_GetWindowID(window);
    if (window_id == 0) return error.SDLWindowIdentityFailed;
    _ = c.SDL_RaiseWindow(window);
    _ = c.SDL_SyncWindow(window);

    var owner = input.InputBuffer.init(window_id);
    try owner.attachGameplayMouseWindow(window);
    defer owner.detachGameplayMouseWindow();
    var empty = EmptySink{};

    // A click outside the published scene rectangle is neither capture nor a
    // gameplay/fire edge, even when no ImGui panel is present in this fixture.
    try pushMouseButtonAt(window_id, c.SDL_BUTTON_LEFT, true, 700, 180);
    owner.beginFrame();
    if (!owner.pumpEvents(empty.sink()) or owner.gameplayMouseLocked() or
        owner.isMouseButtonPressed(input.MouseButton.LEFT))
    {
        return error.OutsideSceneClickLeaked;
    }
    try pushMouseButtonAt(window_id, c.SDL_BUTTON_LEFT, false, 700, 180);
    owner.beginFrame();
    if (!owner.pumpEvents(empty.sink())) return error.OutsideSceneReleaseFailed;

    // The first unconsumed primary click acquires relative mode but must not
    // leak into the handgun/fire input edge.
    try pushMouseButton(window_id, true);
    owner.beginFrame();
    if (!owner.pumpEvents(empty.sink())) return error.UnexpectedCaptureQuit;
    if (!owner.gameplayMouseLocked() or
        !c.SDL_GetWindowRelativeMouseMode(window) or
        owner.isMouseButtonPressed(input.MouseButton.LEFT))
    {
        return error.GameplayMouseCaptureFailed;
    }

    try pushMouseButton(window_id, false);
    owner.beginFrame();
    if (!owner.pumpEvents(empty.sink())) return error.UnexpectedReleaseEdgeQuit;

    // Once captured, a subsequent click is ordinary gameplay input.
    try pushMouseButton(window_id, true);
    owner.beginFrame();
    if (!owner.pumpEvents(empty.sink()) or
        !owner.isMouseButtonPressed(input.MouseButton.LEFT))
    {
        return error.CapturedGameplayClickMissing;
    }

    // Escape releases relative mode and keeps the product alive.
    try pushEscape(window_id);
    owner.beginFrame();
    if (!owner.pumpEvents(empty.sink()) or owner.gameplayMouseLocked() or
        c.SDL_GetWindowRelativeMouseMode(window))
    {
        return error.GameplayMouseEscapeReleaseFailed;
    }

    // F3 enters Free Camera without SDL relative mode. Scene-owned RMB+WASD,
    // motion, and wheel become typed camera requests while a left selection
    // click remains unavailable to firearm/gameplay input.
    try pushKey(window_id, c.SDL_SCANCODE_F3, true);
    owner.beginFrame();
    if (!owner.pumpEvents(empty.sink()) or
        owner.viewportMode() != .free_camera or
        owner.gameplayMouseLocked())
    {
        return error.FreeCameraModeTransitionFailed;
    }
    _ = owner.takeViewportModeRequest() orelse
        return error.FreeCameraModeRequestMissing;

    try pushKey(window_id, c.SDL_SCANCODE_W, true);
    try pushKey(window_id, c.SDL_SCANCODE_D, true);
    try pushMouseButtonAt(window_id, c.SDL_BUTTON_RIGHT, true, 320, 180);
    try pushMouseMotion(window_id, 7, -4);
    try pushMouseWheel(window_id, 2);
    try pushMouseButtonAt(window_id, c.SDL_BUTTON_LEFT, true, 320, 180);
    owner.beginFrame();
    if (!owner.pumpEvents(empty.sink()) or
        owner.isKeyDown(input.Key.W) or owner.isKeyDown(input.Key.D) or
        owner.isMouseButtonPressed(input.MouseButton.LEFT))
    {
        return error.FreeCameraGameplayInputLeaked;
    }
    const free_requests = owner.takeFreeCameraRequests(0.5);
    const navigation = free_requests.navigation orelse
        return error.FreeCameraNavigationMissing;
    if (!std.meta.eql(navigation.move, [3]f32{ 1, 0, 1 }) or
        !std.meta.eql(navigation.look_delta, [2]f32{ 7, -4 }) or
        free_requests.speed_steps != 2)
    {
        return error.FreeCameraNavigationMismatch;
    }

    try pushMouseButtonAt(window_id, c.SDL_BUTTON_LEFT, false, 320, 180);
    try pushMouseButtonAt(window_id, c.SDL_BUTTON_RIGHT, false, 320, 180);
    try pushKey(window_id, c.SDL_SCANCODE_W, false);
    try pushKey(window_id, c.SDL_SCANCODE_D, false);
    try pushKey(window_id, c.SDL_SCANCODE_F3, false);
    owner.beginFrame();
    if (!owner.pumpEvents(empty.sink())) return error.FreeCameraReleaseFailed;

    try pushKey(window_id, c.SDL_SCANCODE_F3, true);
    owner.beginFrame();
    if (!owner.pumpEvents(empty.sink()) or owner.viewportMode() != .character) {
        return error.CharacterModeRestoreFailed;
    }
    _ = owner.takeViewportModeRequest() orelse
        return error.CharacterModeRequestMissing;

    // The existing quit contract remains available once the pointer is free.
    try pushEscape(window_id);
    owner.beginFrame();
    if (owner.pumpEvents(empty.sink())) return error.FreeEscapeDidNotQuit;

    std.debug.print(
        "MOUSE_CAPTURE_ACCEPTANCE_PASS first_click_consumed=true relative=true " ++
            "outside_scene_suppressed=true captured_click=true escape_release=true free_camera=true " ++
            "free_navigation=true selection_suppressed=true character_restore=true " ++
            "free_escape_quit=true failures={d}\n",
        .{owner.gameplayMouseLockFailures()},
    );
}
