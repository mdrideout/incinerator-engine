//! Owned optional developer editor for the visual sandbox composition.
//!
//! The editor is a value owned by App. Visibility, capture policy, tool
//! toggles, and stateful tool data all share that lifetime. Tools receive only
//! one-frame borrows and fixed semantic request buffers.

const std = @import("std");
const zgui = @import("zgui");

const sdl = @import("../sdl.zig");
const input = @import("../input.zig");
const renderer_module = @import("../renderer.zig");

const imgui_backend = @import("imgui_backend.zig");
const tool = @import("tool.zig");
const stats_tool = @import("tools/stats_tool.zig");
const camera_tool = @import("tools/camera_tool.zig");
const render_tool = @import("tools/render_tool.zig");
const diagnostics_tool = @import("tools/diagnostics_tool.zig");
const physics_debug_tool = @import("tools/physics_debug_tool.zig");
const crate_authoring_tool = @import("tools/crate_authoring_tool.zig");
const interaction_tool = @import("tools/interaction_tool.zig");

const c = sdl.c;

pub const Tool = tool.Tool;
pub const FrameInput = tool.FrameInput;
pub const AuthoringCrateView = tool.AuthoringCrateView;
pub const AuthoringFeedbackStatus = tool.AuthoringFeedbackStatus;
pub const AuthoringFeedback = tool.AuthoringFeedback;
pub const SaveFeedbackStatus = tool.SaveFeedbackStatus;
pub const SaveFeedback = tool.SaveFeedback;
pub const CrateAuthoringView = tool.CrateAuthoringView;
pub const InteractionView = tool.InteractionView;

/// Semantic editor routing for an SDL event. This reports only shortcuts that
/// the editor reserves; ImGui capture is queried independently.
pub const EventRoute = input.EventRoute;

const default_tools = [_]Tool{
    Tool.init(stats_tool.descriptor),
    Tool.init(camera_tool.descriptor),
    Tool.init(render_tool.descriptor),
    Tool.init(diagnostics_tool.descriptor),
    Tool.init(physics_debug_tool.descriptor),
    Tool.init(crate_authoring_tool.descriptor),
    Tool.init(interaction_tool.descriptor),
};

pub const Editor = struct {
    backend: imgui_backend.Backend = .{},
    visible: bool = true,
    show_demo_window: bool = false,
    input_passthrough: bool = false,
    tools: [default_tools.len]Tool = default_tools,
    stats: stats_tool.State = .{},
    crate_authoring: crate_authoring_tool.State = .{},

    /// Initialize the owned editor after the renderer has claimed its window.
    pub fn init(
        window: *c.SDL_Window,
        device: *c.SDL_GPUDevice,
        swapchain_format: c.SDL_GPUTextureFormat,
    ) Editor {
        var result = Editor{};
        result.backend.init(window, device, swapchain_format);
        std.debug.print("Editor initialized with {} tools\n", .{result.tools.len});
        return result;
    }

    /// Release ImGui while the renderer device and window are still alive.
    pub fn deinit(self: *Editor) void {
        self.backend.deinit();
        self.* = .{};
    }

    /// Forward every event to ImGui, then reserve only explicit editor keys.
    pub fn processEvent(self: *Editor, event: *const c.SDL_Event) EventRoute {
        _ = self.backend.processEvent(event);

        var route = EventRoute{};
        if (event.type == c.SDL_EVENT_KEY_DOWN) {
            if (event.key.scancode == c.SDL_SCANCODE_F1) {
                if (!event.key.repeat) self.visible = !self.visible;
                route.keyboard_reserved = true;
                return route;
            }
            if (event.key.scancode == c.SDL_SCANCODE_F3) {
                if (!event.key.repeat) self.input_passthrough = !self.input_passthrough;
                route.keyboard_reserved = true;
                return route;
            }
        }

        if (!self.visible) return route;
        if (event.type == c.SDL_EVENT_KEY_DOWN and
            event.key.scancode == c.SDL_SCANCODE_F2)
        {
            if (!event.key.repeat) self.show_demo_window = !self.show_demo_window;
            route.keyboard_reserved = true;
        }
        return route;
    }

    /// Produce a stack-borrowed adapter for the platform event pump. The sink
    /// never outlives the call in which the App supplies it.
    pub fn eventSink(self: *Editor) input.EventSink {
        return .{
            .context = self,
            .process_event = routeInputEvent,
            .capture = inputCapture,
        };
    }

    /// Draw after the scene render pass and before the renderer submits the
    /// frame. Renderer settings are borrowed only through the local context.
    pub fn draw(
        self: *Editor,
        gpu_renderer: *renderer_module.Renderer,
        frame: FrameInput,
    ) void {
        const cmd = gpu_renderer.current_cmd orelse return;
        const swapchain_texture = gpu_renderer.getSwapchainTexture() orelse return;
        const window_size = gpu_renderer.getWindowSize();
        const pixel_density = c.SDL_GetWindowPixelDensity(gpu_renderer.window);
        const framebuffer_scale = if (std.math.isFinite(pixel_density) and
            pixel_density > 0)
            pixel_density
        else
            1.0;
        self.backend.newFrame(
            @intCast(window_size.width),
            @intCast(window_size.height),
            framebuffer_scale,
        );

        if (!self.visible) {
            drawHiddenHint();
            self.backend.render(cmd, swapchain_texture);
            return;
        }

        self.drawMainMenuBar();
        for (&self.tools) |*registered_tool| {
            if (registered_tool.enabled) {
                self.drawTool(
                    registered_tool.id,
                    &frame,
                    &gpu_renderer.render_settings,
                );
            }
        }
        if (self.show_demo_window) zgui.showDemoWindow(&self.show_demo_window);
        self.backend.render(cmd, swapchain_texture);
    }

    pub fn wantsMouse(self: *const Editor) bool {
        if (!self.visible or self.input_passthrough) return false;
        return self.backend.wantsMouse();
    }

    pub fn wantsKeyboard(self: *const Editor) bool {
        if (!self.visible or self.input_passthrough) return false;
        return self.backend.wantsKeyboard();
    }

    pub fn isVisible(self: *const Editor) bool {
        return self.visible;
    }

    fn drawTool(
        self: *Editor,
        id: tool.ToolId,
        frame: *const FrameInput,
        render_settings: *renderer_module.RenderSettings,
    ) void {
        switch (id) {
            .stats => stats_tool.draw(&self.stats, frame.frame_timer),
            .camera => camera_tool.draw(frame.camera),
            .render => render_tool.draw(render_settings),
            .diagnostics => diagnostics_tool.draw(&frame.developer),
            .physics_debug => physics_debug_tool.draw(&frame.visualization),
            .crate_authoring => crate_authoring_tool.draw(
                &self.crate_authoring,
                &frame.authoring,
            ),
            .interaction => interaction_tool.draw(&frame.interaction),
        }
    }

    fn drawMainMenuBar(self: *Editor) void {
        if (!zgui.beginMainMenuBar()) return;
        defer zgui.endMainMenuBar();

        if (zgui.beginMenu("Tools", true)) {
            for (&self.tools) |*registered_tool| {
                if (zgui.menuItem(registered_tool.name, .{
                    .selected = registered_tool.enabled,
                })) {
                    registered_tool.toggle();
                }
            }
            zgui.separator();
            if (zgui.menuItem("ImGui Demo", .{
                .shortcut = "F2",
                .selected = self.show_demo_window,
            })) {
                self.show_demo_window = !self.show_demo_window;
            }
            zgui.endMenu();
        }

        if (zgui.beginMenu("View", true)) {
            if (zgui.menuItem("Input Passthrough", .{
                .shortcut = "F3",
                .selected = self.input_passthrough,
            })) {
                self.input_passthrough = !self.input_passthrough;
            }
            zgui.separator();
            if (zgui.menuItem("Hide Editor", .{ .shortcut = "F1" })) {
                self.visible = false;
            }
            zgui.endMenu();
        }
    }

    fn routeInputEvent(
        context: *anyopaque,
        event: *const c.SDL_Event,
    ) input.EventRoute {
        const self: *Editor = @ptrCast(@alignCast(context));
        return self.processEvent(event);
    }

    fn inputCapture(context: *anyopaque) input.Capture {
        const self: *const Editor = @ptrCast(@alignCast(context));
        return .{
            .keyboard = self.wantsKeyboard(),
            .mouse = self.wantsMouse(),
        };
    }
};

fn drawHiddenHint() void {
    zgui.setNextWindowPos(.{ .x = 10, .y = 10, .cond = .always });
    zgui.setNextWindowBgAlpha(.{ .alpha = 0.5 });
    if (zgui.begin("##hidden_hint", .{
        .flags = .{
            .no_title_bar = true,
            .no_resize = true,
            .no_move = true,
            .no_collapse = true,
            .always_auto_resize = true,
            .no_saved_settings = true,
            .no_focus_on_appearing = true,
        },
    })) {
        zgui.textColored(
            .{ 0.7, 0.7, 0.7, 1.0 },
            "Press F1 to show editor",
            .{},
        );
    }
    zgui.end();
}

test "tool registry contains every tool identity exactly once" {
    var seen = [_]bool{false} ** std.meta.tags(tool.ToolId).len;
    for (default_tools) |registered_tool| {
        const index = @intFromEnum(registered_tool.id);
        try std.testing.expect(!seen[index]);
        seen[index] = true;
    }
    for (seen) |present| try std.testing.expect(present);
}

test "editor runtime and tool state belong to each value" {
    var first = Editor{};
    const second = Editor{};

    first.visible = false;
    first.tools[0].toggle();
    first.stats.history_index = 7;
    first.crate_authoring.dirty = true;

    try std.testing.expect(second.visible);
    try std.testing.expect(second.tools[0].enabled);
    try std.testing.expectEqual(@as(usize, 0), second.stats.history_index);
    try std.testing.expect(!second.crate_authoring.dirty);
}

test "owned editor event routing mutates only its receiver" {
    var first = Editor{};
    const second = Editor{};
    var event = std.mem.zeroes(c.SDL_Event);
    event.type = c.SDL_EVENT_KEY_DOWN;
    event.key.scancode = c.SDL_SCANCODE_F1;

    const route = first.processEvent(&event);
    try std.testing.expect(route.keyboard_reserved);
    try std.testing.expect(!first.isVisible());
    try std.testing.expect(second.isVisible());
}
