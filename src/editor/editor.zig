//! Owned optional developer editor for the visual sandbox composition.
//!
//! The editor is a value owned by App. Visibility, capture policy, tool
//! toggles, and stateful tool data all share that lifetime. Tools receive only
//! one-frame borrows and fixed semantic request buffers.

const std = @import("std");
const zgui = @import("zgui");
const workspace = @import("editor_workspace");

const sdl = @import("../sdl.zig");
const input = @import("../input.zig");
const renderer_module = @import("../renderer.zig");

const imgui_backend = @import("imgui_backend.zig");
const tool = @import("tool.zig");
const stats_tool = @import("tools/stats_tool.zig");
const camera_tool = @import("tools/camera_tool.zig");
const render_tool = @import("tools/render_tool.zig");
const diagnostics_tool = @import("tools/diagnostics_tool.zig");
const gameplay_inspector_tool = @import("tools/gameplay_inspector_tool.zig");
const navigation_lab_tool = @import("tools/navigation_lab_tool.zig");
const population_lab_tool = @import("tools/population_lab_tool.zig");
const incident_capture_tool = @import("tools/incident_capture_tool.zig");
const physics_debug_tool = @import("tools/physics_debug_tool.zig");
const crate_authoring_tool = @import("tools/crate_authoring_tool.zig");
const interaction_tool = @import("tools/interaction_tool.zig");
const neural_rendering_lab_tool = @import("tools/neural_rendering_lab_tool.zig");

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
pub const StartupConfig = workspace.StartupConfig;

/// Semantic editor routing for an SDL event. This reports only shortcuts that
/// the editor reserves; ImGui capture is queried independently.
pub const EventRoute = input.EventRoute;

const default_tools = [_]Tool{
    Tool.init(stats_tool.descriptor),
    Tool.init(camera_tool.descriptor),
    Tool.init(render_tool.descriptor),
    Tool.init(diagnostics_tool.descriptor),
    Tool.init(gameplay_inspector_tool.descriptor),
    Tool.init(navigation_lab_tool.descriptor),
    Tool.init(population_lab_tool.descriptor),
    Tool.init(incident_capture_tool.descriptor),
    Tool.init(physics_debug_tool.descriptor),
    Tool.init(crate_authoring_tool.descriptor),
    Tool.init(interaction_tool.descriptor),
    Tool.init(neural_rendering_lab_tool.descriptor),
};

pub const Editor = struct {
    backend: imgui_backend.Backend = .{},
    visible: bool = true,
    show_demo_window: bool = false,
    input_passthrough: bool = false,
    tools: [default_tools.len]Tool = default_tools,
    stats: stats_tool.State = .{},
    crate_authoring: crate_authoring_tool.State = .{},
    gameplay_inspector: gameplay_inspector_tool.State = .{},
    navigation_lab: navigation_lab_tool.State = .{},
    population_lab: population_lab_tool.State = .{},
    incident_capture: incident_capture_tool.State = .{},
    layout: workspace.LayoutPreset = .gameplay,
    layout_pending: bool = true,
    pending_focus: ?workspace.ToolId = workspace.defaultFocus(.gameplay),
    show_workspace_guide: bool = false,
    gameplay_mouse_captured: bool = false,

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

    /// Apply one validated process-start workspace request. The editor stores
    /// only the resolved preset, mask, focus, and guide state; it never retains
    /// process argument slices.
    pub fn configureStartup(self: *Editor, config: StartupConfig) void {
        self.layout = config.layout;
        const mask = config.exact_panels orelse
            workspace.PanelMask.fromPreset(config.layout);
        for (&self.tools) |*registered_tool| {
            registered_tool.enabled = mask.contains(registered_tool.descriptor.id);
        }
        self.pending_focus = config.focus orelse if (config.exact_panels == null)
            workspace.defaultFocus(config.layout)
        else
            null;
        self.show_workspace_guide = config.show_guide;
        self.layout_pending = true;
    }

    /// Forward every event to ImGui, then reserve only explicit editor keys.
    pub fn processEvent(self: *Editor, event: *const c.SDL_Event) EventRoute {
        if (self.gameplay_mouse_captured and isMouseEvent(event.type)) {
            return .{};
        }
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

        gameplay_inspector_tool.drawProductHud(&frame.gameplay);
        incident_capture_tool.drawProductStatus(&frame.incident);
        if (self.gameplay_mouse_captured) drawGameplayMouseCaptureHint();

        if (!self.visible) {
            drawHiddenHint();
            self.backend.render(cmd, swapchain_texture);
            return;
        }

        // Newly docked windows can override a same-frame focus request as
        // their tabs appear. Preserve the requested panel through the layout
        // frame and focus it on the following stable frame.
        const layout_was_pending = self.layout_pending;
        self.drawWorkspace(&frame);
        for (&self.tools) |*registered_tool| {
            if (registered_tool.enabled) {
                if (!layout_was_pending and
                    self.pending_focus == registered_tool.descriptor.id)
                {
                    zgui.setNextWindowFocus();
                    self.pending_focus = null;
                }
                self.drawTool(
                    registered_tool.descriptor.id,
                    &frame,
                    &gpu_renderer.render_settings,
                );
            }
        }
        if (self.show_workspace_guide) self.drawWorkspaceGuide();
        if (self.show_demo_window) zgui.showDemoWindow(&self.show_demo_window);
        self.backend.render(cmd, swapchain_texture);
    }

    pub fn wantsMouse(self: *const Editor) bool {
        if (self.gameplay_mouse_captured) return false;
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

    pub fn setGameplayMouseCaptured(self: *Editor, captured: bool) void {
        if (captured and !self.gameplay_mouse_captured) {
            // The acquisition click reached ImGui before the input pump knew
            // it belonged to the passthrough scene. Explicit releases prevent
            // a button from remaining logically held while captured mouse
            // events are intentionally withheld from the editor.
            zgui.io.addMouseButtonEvent(.left, false);
            zgui.io.addMouseButtonEvent(.right, false);
            zgui.io.addMouseButtonEvent(.middle, false);
        }
        self.gameplay_mouse_captured = captured;
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
            .render => render_tool.draw(render_settings, &frame.render),
            .diagnostics => diagnostics_tool.draw(&frame.developer),
            .gameplay_inspector => gameplay_inspector_tool.draw(
                &self.gameplay_inspector,
                &frame.gameplay,
            ),
            .navigation_lab => navigation_lab_tool.draw(
                &self.navigation_lab,
                &frame.navigation,
            ),
            .population_lab => population_lab_tool.draw(
                &self.population_lab,
                &frame.population,
            ),
            .incident_capture => incident_capture_tool.draw(
                &self.incident_capture,
                &frame.incident,
            ),
            .physics_debug => physics_debug_tool.draw(&frame.visualization),
            .crate_authoring => crate_authoring_tool.draw(
                &self.crate_authoring,
                &frame.authoring,
            ),
            .interaction => interaction_tool.draw(&frame.interaction),
            .neural_rendering_lab => neural_rendering_lab_tool.draw(&frame.neural),
        }
    }

    fn drawWorkspace(self: *Editor, frame: *const FrameInput) void {
        self.drawMainMenuBar();

        const viewport = zgui.getMainViewport();
        const work_pos = viewport.getWorkPos();
        const work_size = viewport.getWorkSize();
        zgui.setNextWindowPos(.{ .x = work_pos[0], .y = work_pos[1], .cond = .always });
        zgui.setNextWindowSize(.{ .w = work_size[0], .h = work_size[1], .cond = .always });
        zgui.setNextWindowViewport(viewport.getId());
        zgui.pushStyleVar1f(.{ .idx = .window_rounding, .v = 0 });
        zgui.pushStyleVar1f(.{ .idx = .window_border_size, .v = 0 });
        zgui.pushStyleVar2f(.{ .idx = .window_padding, .v = .{ 0, 0 } });
        defer zgui.popStyleVar(.{ .count = 3 });

        if (zgui.begin("##incinerator_workspace", .{ .flags = .{
            .no_title_bar = true,
            .no_resize = true,
            .no_move = true,
            .no_collapse = true,
            .no_background = true,
            .no_saved_settings = true,
            .no_bring_to_front_on_focus = true,
            .no_nav_focus = true,
            .no_docking = true,
        } })) {
            const status_height: f32 = 26;
            const available = zgui.getContentRegionAvail();
            const dock_size = .{ available[0], @max(@as(f32, 0), available[1] - status_height) };
            const dock_pos = zgui.getCursorScreenPos();
            const dockspace_id = zgui.dockSpace(
                "IncineratorWorkspaceDockspace",
                dock_size,
                .{
                    .passthru_central_node = true,
                    .no_docking_over_central_node = true,
                },
            );
            if (self.layout_pending and dock_size[0] > 0 and dock_size[1] > 0) {
                self.buildDockLayout(dockspace_id, dock_pos, dock_size);
                self.layout_pending = false;
            }

            if (zgui.beginChild("##workspace_status", .{
                .h = status_height,
                .child_flags = .{ .frame_style = true },
                .window_flags = .{ .no_scrollbar = true },
            })) {
                const utc = workspace.formatUtcWallMs(frame.wall_unix_ms);
                zgui.text(
                    "UTC {s}  |  wall_unix_ms={d}  |  tick={d}  |  frame={d}  |  layout={s}  |  mouse={s}",
                    .{
                        utc.slice(),
                        frame.wall_unix_ms,
                        frame.gameplay.view.authority_tick,
                        frame.gameplay.view.presentation_frame,
                        @tagName(self.layout),
                        if (self.gameplay_mouse_captured)
                            "CAPTURED (Esc releases)"
                        else
                            "free (click scene to capture)",
                    },
                );
            }
            zgui.endChild();
        }
        zgui.end();
    }

    fn buildDockLayout(
        self: *Editor,
        dockspace_id: zgui.Ident,
        dock_pos: [2]f32,
        dock_size: [2]f32,
    ) void {
        zgui.dockBuilderRemoveNode(dockspace_id);
        _ = zgui.dockBuilderAddNode(dockspace_id, .{ .dock_space = true });
        zgui.dockBuilderSetNodePos(dockspace_id, dock_pos);
        zgui.dockBuilderSetNodeSize(dockspace_id, dock_size);

        var center = dockspace_id;
        var left: zgui.Ident = 0;
        var right: zgui.Ident = 0;
        var bottom: zgui.Ident = 0;
        _ = zgui.dockBuilderSplitNode(center, .left, 0.22, &left, &center);
        _ = zgui.dockBuilderSplitNode(center, .right, 0.25, &right, &center);
        _ = zgui.dockBuilderSplitNode(center, .down, 0.28, &bottom, &center);

        for (self.tools) |registered_tool| {
            const node = switch (registered_tool.descriptor.default_region) {
                .left => left,
                .right => right,
                .bottom => bottom,
            };
            zgui.dockBuilderDockWindow(registered_tool.descriptor.name, node);
        }
        zgui.dockBuilderDockWindow("Workspace Guide", right);
        zgui.dockBuilderFinish(dockspace_id);
    }

    fn applyLayout(self: *Editor, preset: workspace.LayoutPreset) void {
        self.layout = preset;
        const mask = workspace.PanelMask.fromPreset(preset);
        for (&self.tools) |*registered_tool| {
            registered_tool.enabled = mask.contains(registered_tool.descriptor.id);
        }
        self.pending_focus = workspace.defaultFocus(preset);
        self.layout_pending = true;
    }

    fn drawWorkspaceGuide(self: *Editor) void {
        if (zgui.begin("Workspace Guide", .{ .popen = &self.show_workspace_guide })) {
            zgui.textWrapped(
                "Panels read immutable frame projections. Any mutation leaves through the request boundary named below.",
                .{},
            );
            zgui.separator();
            zgui.text("Startup examples", .{});
            zgui.bulletText("--editor-layout=navigation --editor-focus=navigation_lab", .{});
            zgui.bulletText("--editor-layout=incident --editor-guide", .{});
            zgui.bulletText("--editor-panels=gameplay_inspector,diagnostics,incident_capture", .{});

            for (self.tools) |registered_tool| {
                const descriptor = registered_tool.descriptor;
                zgui.separatorText(descriptor.name);
                zgui.textDisabled(
                    "id={s}  category={s}  region={s}  availability={s}",
                    .{
                        @tagName(descriptor.id),
                        @tagName(descriptor.category),
                        @tagName(descriptor.default_region),
                        @tagName(descriptor.availability),
                    },
                );
                zgui.textWrapped("{s}", .{descriptor.purpose});
                zgui.textWrapped("Reads: {s}", .{descriptor.reads});
                zgui.textWrapped("Requests: {s}", .{descriptor.requests});
                zgui.text("Examples", .{});
                for (descriptor.examples) |example| zgui.bulletText("{s}", .{example});
                zgui.text("Audit identity", .{});
                for (descriptor.audit_fields) |field| zgui.bulletText("{s}", .{field});
            }
        }
        zgui.end();
    }

    fn drawMainMenuBar(self: *Editor) void {
        if (!zgui.beginMainMenuBar()) return;
        defer zgui.endMainMenuBar();

        if (zgui.beginMenu("Workspace", true)) {
            inline for (std.meta.tags(workspace.LayoutPreset)) |preset| {
                if (zgui.menuItem(@tagName(preset), .{
                    .selected = self.layout == preset,
                })) self.applyLayout(preset);
            }
            zgui.separator();
            if (zgui.menuItem("Reapply layout", .{})) self.layout_pending = true;
            if (zgui.menuItem("Workspace Guide", .{
                .selected = self.show_workspace_guide,
            })) self.show_workspace_guide = !self.show_workspace_guide;
            zgui.endMenu();
        }

        if (zgui.beginMenu("Panels", true)) {
            for (&self.tools) |*registered_tool| {
                if (zgui.menuItem(registered_tool.descriptor.name, .{
                    .selected = registered_tool.enabled,
                })) {
                    registered_tool.toggle();
                    if (registered_tool.enabled) {
                        self.pending_focus = registered_tool.descriptor.id;
                    }
                }
                if (zgui.isItemHovered(.{}) and zgui.beginTooltip()) {
                    zgui.textDisabled("{s}", .{@tagName(registered_tool.descriptor.id)});
                    zgui.textWrapped("{s}", .{registered_tool.descriptor.purpose});
                    zgui.endTooltip();
                }
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

        if (zgui.beginMenu("Help", true)) {
            if (zgui.menuItem("Workspace Guide", .{
                .selected = self.show_workspace_guide,
            })) self.show_workspace_guide = !self.show_workspace_guide;
            if (zgui.menuItem("ImGui Demo", .{
                .shortcut = "F2",
                .selected = self.show_demo_window,
            })) self.show_demo_window = !self.show_demo_window;
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

fn isMouseEvent(event_type: u32) bool {
    return switch (event_type) {
        c.SDL_EVENT_MOUSE_MOTION,
        c.SDL_EVENT_MOUSE_BUTTON_DOWN,
        c.SDL_EVENT_MOUSE_BUTTON_UP,
        c.SDL_EVENT_MOUSE_WHEEL,
        => true,
        else => false,
    };
}

fn drawGameplayMouseCaptureHint() void {
    const viewport = zgui.getMainViewport();
    const work_pos = viewport.getWorkPos();
    const work_size = viewport.getWorkSize();
    zgui.setNextWindowPos(.{
        .x = work_pos[0] + work_size[0] * 0.5,
        .y = work_pos[1] + 10,
        .cond = .always,
        .pivot_x = 0.5,
        .pivot_y = 0,
    });
    zgui.setNextWindowBgAlpha(.{ .alpha = 0.82 });
    if (zgui.begin("##gameplay_mouse_capture_hint", .{ .flags = .{
        .no_title_bar = true,
        .no_resize = true,
        .no_move = true,
        .no_collapse = true,
        .always_auto_resize = true,
        .no_saved_settings = true,
        .no_focus_on_appearing = true,
        .no_nav_focus = true,
    } })) {
        zgui.textColored(
            .{ 0.25, 0.95, 1.0, 1.0 },
            "MOUSE CAPTURED  |  Move to look  |  ESC releases",
            .{},
        );
    }
    zgui.end();
}

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
        const index = @intFromEnum(registered_tool.descriptor.id);
        try std.testing.expect(!seen[index]);
        try std.testing.expect(registered_tool.descriptor.isComplete());
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
    first.gameplay_inspector.selected = .{ .namespace = 1, .local = 2 };

    try std.testing.expect(second.visible);
    try std.testing.expect(second.tools[0].enabled);
    try std.testing.expectEqual(@as(usize, 0), second.stats.history_index);
    try std.testing.expect(!second.crate_authoring.dirty);
    try std.testing.expect(second.gameplay_inspector.selected == null);
}

test "startup configuration owns exact panel visibility and focus" {
    var value = Editor{};
    var exact = workspace.PanelMask{};
    exact.set(.diagnostics, true);
    exact.set(.incident_capture, true);
    value.configureStartup(.{
        .layout = .incident,
        .layout_explicit = true,
        .exact_panels = exact,
        .focus = .incident_capture,
        .show_guide = true,
    });

    for (value.tools) |registered_tool| {
        const expected = registered_tool.descriptor.id == .diagnostics or
            registered_tool.descriptor.id == .incident_capture;
        try std.testing.expectEqual(expected, registered_tool.enabled);
    }
    try std.testing.expectEqual(workspace.ToolId.incident_capture, value.pending_focus.?);
    try std.testing.expect(value.show_workspace_guide);
    try std.testing.expect(value.layout_pending);
}

test "exact startup panel selection has no unrelated preset focus" {
    var value = Editor{};
    var exact = workspace.PanelMask{};
    exact.set(.diagnostics, true);
    value.configureStartup(.{ .exact_panels = exact });

    try std.testing.expect(value.pending_focus == null);
    for (value.tools) |registered_tool| {
        try std.testing.expectEqual(
            registered_tool.descriptor.id == .diagnostics,
            registered_tool.enabled,
        );
    }
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
