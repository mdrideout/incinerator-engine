//! Compile-time editor implementation for product builds without ImGui.
//!
//! The API mirrors editor.Editor so the application and input pump retain the
//! same explicit ownership and routing shape in both build configurations.

const renderer_module = @import("../renderer.zig");
const input = @import("../input.zig");
const sdl = @import("../sdl.zig");
const tool = @import("tool.zig");
const viewport = tool.viewport;
const workspace = @import("editor_workspace");

pub const AuthoringCrateView = tool.AuthoringCrateView;
pub const AuthoringFeedbackStatus = tool.AuthoringFeedbackStatus;
pub const AuthoringFeedback = tool.AuthoringFeedback;
pub const SaveFeedbackStatus = tool.SaveFeedbackStatus;
pub const SaveFeedback = tool.SaveFeedback;
pub const CrateAuthoringView = tool.CrateAuthoringView;
pub const InteractionView = tool.InteractionView;
pub const FrameInput = tool.FrameInput;

pub const EventRoute = input.EventRoute;

pub const Editor = struct {
    pub fn init(_: anytype, _: anytype, _: anytype) Editor {
        return .{};
    }

    pub fn deinit(_: *Editor) void {}

    pub fn configureStartup(_: *Editor, _: workspace.StartupConfig) void {}

    pub fn processEvent(_: *Editor, _: anytype) EventRoute {
        return .{};
    }

    pub fn eventSink(self: *Editor) input.EventSink {
        return .{
            .context = self,
            .process_event = routeInputEvent,
            .capture = inputCapture,
            .scene_rect = inputSceneRect,
            .toggle_system_menu = inputToggleSystemMenu,
        };
    }

    pub fn draw(
        _: *Editor,
        _: *renderer_module.Renderer,
        _: FrameInput,
    ) void {}

    pub fn wantsMouse(_: *const Editor) bool {
        return false;
    }

    pub fn wantsKeyboard(_: *const Editor) bool {
        return false;
    }

    pub fn isVisible(_: *const Editor) bool {
        return false;
    }

    pub fn setGameplayMouseCaptured(_: *Editor, _: bool) void {}

    pub fn setViewportMode(_: *Editor, _: viewport.Mode) void {}

    pub fn toggleSystemMenu(_: *Editor) void {}

    pub fn systemMenuOpen(_: *const Editor) bool {
        return false;
    }

    pub fn takeQuitRequested(_: *Editor) bool {
        return false;
    }

    pub fn viewportSceneRect(_: *const Editor) ?viewport.SceneRect {
        return null;
    }

    fn routeInputEvent(
        context: *anyopaque,
        event: *const sdl.c.SDL_Event,
    ) input.EventRoute {
        const self: *Editor = @ptrCast(@alignCast(context));
        return self.processEvent(event);
    }

    fn inputCapture(_: *anyopaque) input.Capture {
        return .{};
    }

    fn inputSceneRect(_: *anyopaque) ?viewport.SceneRect {
        return null;
    }

    fn inputToggleSystemMenu(_: *anyopaque) void {}
};

test "disabled editor reserves and captures no input" {
    var disabled = Editor.init(null, null, null);
    const route = disabled.processEvent(null);
    try @import("std").testing.expect(!route.keyboard_reserved);
    try @import("std").testing.expect(!route.mouse_reserved);
    try @import("std").testing.expect(!disabled.wantsKeyboard());
    try @import("std").testing.expect(!disabled.wantsMouse());
    try @import("std").testing.expect(!disabled.isVisible());
}
