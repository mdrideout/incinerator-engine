//! Native SDL acceptance for click-to-capture continuous gameplay look.

const std = @import("std");
const input = @import("input");

const c = input.sdl_c;

const EmptySink = struct {
    fn process(_: *anyopaque, _: *const c.SDL_Event) input.EventRoute {
        return .{};
    }

    fn capture(_: *anyopaque) input.Capture {
        return .{};
    }

    fn sink(self: *EmptySink) input.EventSink {
        return .{
            .context = self,
            .process_event = process,
            .capture = capture,
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
    if (!c.SDL_PushEvent(&event)) return error.PushMouseButtonFailed;
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

    // The existing quit contract remains available once the pointer is free.
    try pushEscape(window_id);
    owner.beginFrame();
    if (owner.pumpEvents(empty.sink())) return error.FreeEscapeDidNotQuit;

    std.debug.print(
        "MOUSE_CAPTURE_ACCEPTANCE_PASS first_click_consumed=true relative=true " ++
            "captured_click=true escape_release=true free_escape_quit=true failures={d}\n",
        .{owner.gameplayMouseLockFailures()},
    );
}
