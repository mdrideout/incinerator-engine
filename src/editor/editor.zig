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
const selection = tool.selection;
const content_selection = @import("content_selection.zig");
const viewport = tool.viewport;
const stats_tool = @import("tools/stats_tool.zig");
const camera_tool = @import("tools/camera_tool.zig");
const render_tool = @import("tools/render_tool.zig");
const diagnostics_tool = @import("tools/diagnostics_tool.zig");
const event_log_tool = @import("tools/event_log_tool.zig");
const gameplay_inspector_tool = @import("tools/gameplay_inspector_tool.zig");
const world_outliner_tool = @import("tools/world_outliner_tool.zig");
const content_browser_tool = @import("tools/content_browser_tool.zig");
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

/// Semantic editor routing for an SDL event. This reports explicit shortcuts
/// and viewport controls that the editor owns; ImGui capture is queried
/// independently.
pub const EventRoute = input.EventRoute;

const default_tools = [_]Tool{
    Tool.init(stats_tool.descriptor),
    Tool.init(content_browser_tool.descriptor),
    Tool.init(camera_tool.descriptor),
    Tool.init(render_tool.descriptor),
    Tool.init(diagnostics_tool.descriptor),
    Tool.init(event_log_tool.descriptor),
    Tool.init(gameplay_inspector_tool.descriptor),
    Tool.init(navigation_lab_tool.descriptor),
    Tool.init(population_lab_tool.descriptor),
    Tool.init(incident_capture_tool.descriptor),
    Tool.init(physics_debug_tool.descriptor),
    Tool.init(crate_authoring_tool.descriptor),
    Tool.init(interaction_tool.descriptor),
    Tool.init(neural_rendering_lab_tool.descriptor),
    Tool.init(world_outliner_tool.descriptor),
};

/// Human-facing Panels menu order. Keep this independent from `default_tools`:
/// registry order also determines default dock/tab construction, while this
/// list exists only to make panel discovery alphabetical.
const panel_menu_order = [_]tool.ToolId{
    .camera,
    .content_browser,
    .diagnostics,
    .event_log,
    .gameplay_inspector,
    .incident_capture,
    .crate_authoring,
    .interaction,
    .navigation_lab,
    .neural_rendering_lab,
    .physics_debug,
    .population_lab,
    .render,
    .stats,
    .world_outliner,
};

pub const Editor = struct {
    backend: imgui_backend.Backend = .{},
    visible: bool = true,
    show_demo_window: bool = false,
    tools: [default_tools.len]Tool = default_tools,
    stats: stats_tool.State = .{},
    crate_authoring: crate_authoring_tool.State = .{},
    world_outliner: world_outliner_tool.State = .{},
    content_browser: content_browser_tool.State = .{},
    content_selection_controller: content_selection.Controller = .{},
    content_selection_requests: content_selection.Requests = .{},
    inspector_subject: enum { world, content } = .world,
    navigation_lab: navigation_lab_tool.State = .{},
    population_lab: population_lab_tool.State = .{},
    incident_capture: incident_capture_tool.State = .{},
    layout: workspace.LayoutPreset = .gameplay,
    layout_pending: bool = true,
    pending_focus: ?workspace.ToolId = workspace.defaultFocus(.gameplay),
    last_observed_selection: ?selection.Id = null,
    show_workspace_guide: bool = false,
    gameplay_mouse_captured: bool = false,
    viewport_mode: viewport.Mode = .character,
    scene_rect: ?viewport.SceneRect = null,
    pending_viewport_mode: ?viewport.Mode = null,
    system_menu_open: bool = false,
    system_menu_popup_pending: bool = false,
    quit_requested: bool = false,

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
        self.world_outliner.deinit();
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

        if (event.type == c.SDL_EVENT_WINDOW_FOCUS_LOST or
            event.type == c.SDL_EVENT_WINDOW_MINIMIZED)
        {
            self.crate_authoring.deactivateGizmo();
        }

        var route = EventRoute{};
        if (event.type == c.SDL_EVENT_KEY_DOWN) {
            if (event.key.scancode == c.SDL_SCANCODE_ESCAPE) {
                route.system_menu_available = true;
                if (!event.key.repeat and self.crate_authoring.cancelGizmoDrag()) {
                    route.keyboard_reserved = true;
                    return route;
                }
                if (!event.key.repeat and self.system_menu_open) {
                    self.system_menu_open = false;
                    self.system_menu_popup_pending = false;
                    route.keyboard_reserved = true;
                    return route;
                }
                if (self.system_menu_open) route.keyboard_reserved = true;
                return route;
            }
            if (self.system_menu_open) {
                route.keyboard_reserved = true;
                return route;
            }
            if (event.key.scancode == c.SDL_SCANCODE_F1) {
                if (!event.key.repeat) {
                    self.visible = !self.visible;
                    if (!self.visible) self.crate_authoring.deactivateGizmo();
                }
                route.keyboard_reserved = true;
                return route;
            }
            if (event.key.scancode == c.SDL_SCANCODE_F3) {
                if (!event.key.repeat) {
                    self.setViewportMode(self.viewport_mode.toggled());
                    route.viewport_mode_request = self.viewport_mode;
                }
                route.keyboard_reserved = true;
                return route;
            }
        }

        if (self.system_menu_open and isMouseEvent(event.type)) {
            route.mouse_reserved = true;
            return route;
        }

        if (!self.visible) return route;
        if (viewport.editorWorldAffordancesVisible(
            self.visible,
            self.viewport_mode,
        ) and
            event.type == c.SDL_EVENT_MOUSE_BUTTON_DOWN and
            event.button.button == c.SDL_BUTTON_LEFT and
            self.toolById(.crate_authoring).enabled and
            self.crate_authoring.claimsGizmoPointer(.{ event.button.x, event.button.y }))
        {
            // Backend capture reflects the previous completed ImGui frame and
            // can lag a cursor move plus click delivered in one event pump.
            // Claim the concrete handle hit synchronously so the same press
            // cannot also become a Free Camera world-selection miss.
            route.mouse_reserved = true;
        }
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
            .scene_rect = inputSceneRect,
            .toggle_system_menu = inputToggleSystemMenu,
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
        self.setViewportMode(frame.viewport.view.mode);
        self.observeSelection(frame.selection.view);
        const world_affordances_visible = viewport.editorWorldAffordancesVisible(
            self.visible,
            self.viewport_mode,
        );
        if (!world_affordances_visible or
            !self.toolById(.crate_authoring).enabled)
        {
            self.crate_authoring.deactivateGizmo();
        }

        if (!self.visible) {
            self.scene_rect = null;
            drawProductStatusOverlay(self, &frame);
            self.drawSystemMenu();
            self.backend.render(cmd, swapchain_texture);
            return;
        }

        // Newly docked windows can override a same-frame focus request as
        // their tabs appear. Preserve the requested panel through the layout
        // frame and focus it on the following stable frame.
        const layout_was_pending = self.layout_pending;
        const viewport_content = self.drawWorkspace(&frame);
        self.drawSceneViewport(&frame, viewport_content);
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
        if (self.content_selection_controller.apply(
            frame.content_assets,
            &self.content_selection_requests,
        )) {
            if (self.content_selection_controller.active != null) {
                self.inspector_subject = .content;
                self.toolById(.crate_authoring).enabled = true;
                self.pending_focus = .crate_authoring;
            } else if (self.inspector_subject == .content) {
                self.inspector_subject = .world;
            }
        }
        if (world_affordances_visible and
            self.toolById(.crate_authoring).enabled)
        {
            if (self.scene_rect) |scene| crate_authoring_tool.drawGizmo(
                &self.crate_authoring,
                frame.authoring.view,
                frame.camera.*,
                scene,
                .{
                    @floatFromInt(window_size.width),
                    @floatFromInt(window_size.height),
                },
            );
        }
        if (self.show_workspace_guide) self.drawWorkspaceGuide();
        if (self.show_demo_window) zgui.showDemoWindow(&self.show_demo_window);
        self.drawSystemMenu();
        self.backend.render(cmd, swapchain_texture);
    }

    pub fn wantsMouse(self: *const Editor) bool {
        if (self.system_menu_open) return true;
        if (self.gameplay_mouse_captured) return false;
        if (!self.visible) return false;
        return self.backend.wantsMouse();
    }

    pub fn wantsKeyboard(self: *const Editor) bool {
        if (self.system_menu_open) return true;
        if (!self.visible) return false;
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

    pub fn setViewportMode(self: *Editor, mode: viewport.Mode) void {
        if (self.viewport_mode != mode) self.crate_authoring.deactivateGizmo();
        self.viewport_mode = mode;
    }

    pub fn toggleSystemMenu(self: *Editor) void {
        self.system_menu_open = !self.system_menu_open;
        self.system_menu_popup_pending = self.system_menu_open;
    }

    pub fn systemMenuOpen(self: *const Editor) bool {
        return self.system_menu_open;
    }

    /// Active editor interactions retain ownership until release or cancel.
    /// External editor-control producers query this state instead of mutating
    /// selection or camera state underneath a live pointer gesture.
    pub fn gizmoDragActive(self: *const Editor) bool {
        return self.crate_authoring.gizmoDragActive();
    }

    pub fn selectContentAsset(
        self: *Editor,
        entries: []const @import("incinerator_engine").assets.Entry,
        id: @import("incinerator_engine").assets.AssetId,
    ) bool {
        for (entries) |entry| if (std.meta.eql(entry.id, id)) {
            self.content_selection_controller.active = id;
            self.inspector_subject = .content;
            self.toolById(.crate_authoring).enabled = true;
            self.pending_focus = .crate_authoring;
            return true;
        };
        return false;
    }

    pub fn clearContentSelection(self: *Editor) void {
        self.content_selection_controller.active = null;
        if (self.inspector_subject == .content) self.inspector_subject = .world;
    }

    pub fn takeQuitRequested(self: *Editor) bool {
        defer self.quit_requested = false;
        return self.quit_requested;
    }

    pub fn viewportSceneRect(self: *const Editor) ?viewport.SceneRect {
        return self.scene_rect;
    }

    fn drawTool(
        self: *Editor,
        id: tool.ToolId,
        frame: *const FrameInput,
        render_settings: *renderer_module.RenderSettings,
    ) void {
        switch (id) {
            .stats => stats_tool.draw(&self.stats, frame.frame_timing),
            .content_browser => content_browser_tool.draw(
                &self.content_browser,
                &self.content_selection_controller.view(frame.content_assets),
                &self.content_selection_requests,
            ),
            .camera => camera_tool.draw(frame.camera),
            .render => render_tool.draw(render_settings, &frame.render),
            .diagnostics => diagnostics_tool.draw(&frame.developer),
            .event_log => event_log_tool.draw(
                &frame.developer,
                &frame.gameplay,
                frame.selection.view.activeGameplay(),
            ),
            .gameplay_inspector => gameplay_inspector_tool.draw(
                &frame.gameplay,
                &frame.selection,
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
                &frame.selection,
                if (self.inspector_subject == .content)
                    self.content_selection_controller.view(frame.content_assets).activeEntry()
                else
                    null,
            ),
            .interaction => interaction_tool.draw(&frame.interaction),
            .neural_rendering_lab => neural_rendering_lab_tool.draw(&frame.neural),
            .world_outliner => world_outliner_tool.draw(
                &self.world_outliner,
                &frame.selection,
            ),
        }
    }

    fn drawWorkspace(
        self: *Editor,
        frame: *const FrameInput,
    ) ?viewport.SceneRect {
        self.drawMainMenuBar();
        var central_rect: ?viewport.SceneRect = null;

        const main_viewport = zgui.getMainViewport();
        const work_pos = main_viewport.getWorkPos();
        const work_size = main_viewport.getWorkSize();
        zgui.setNextWindowPos(.{ .x = work_pos[0], .y = work_pos[1], .cond = .always });
        zgui.setNextWindowSize(.{ .w = work_size[0], .h = work_size[1], .cond = .always });
        zgui.setNextWindowViewport(main_viewport.getId());
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
            const available_width = zgui.getContentRegionAvail()[0];
            const product_status_height = productStatusHeight(available_width);
            if (zgui.beginChild("##product_status", .{
                .h = product_status_height,
                .child_flags = .{ .frame_style = true },
                .window_flags = .{ .no_scrollbar = true },
            })) {
                drawProductStatusTable(self, frame, available_width);
            }
            zgui.endChild();

            const footer_height: f32 = 26;
            const available = zgui.getContentRegionAvail();
            const dock_size = .{ available[0], @max(@as(f32, 0), available[1] - footer_height) };
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
            if (zgui.dockBuilderGetCentralNode(dockspace_id)) |central_node| {
                var rect: [4]f32 = undefined;
                zgui.dockNodeRect(central_node, &rect);
                central_rect = viewport.SceneRect.init(
                    .{ rect[0], rect[1] },
                    .{ rect[2], rect[3] },
                );
            }

            if (zgui.beginChild("##workspace_status", .{
                .h = footer_height,
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
                        viewportMouseStatus(
                            self.viewport_mode,
                            self.gameplay_mouse_captured,
                        ),
                    },
                );
            }
            zgui.endChild();
        }
        zgui.end();
        return central_rect;
    }

    fn drawSceneViewport(
        self: *Editor,
        frame: *const FrameInput,
        viewport_content: ?viewport.SceneRect,
    ) void {
        if (self.pending_viewport_mode) |mode| {
            frame.viewport.requests.submit(.{ .set_mode = mode });
            self.pending_viewport_mode = null;
        }
        self.scene_rect = null;
        const content = viewport_content orelse return;
        const toolbar_height: f32 = 58;
        const toolbar_maximum_y = @min(
            content.maximum[1],
            content.minimum[1] + toolbar_height,
        );
        const toolbar = viewport.SceneRect.init(content.minimum, .{
            content.maximum[0],
            toolbar_maximum_y,
        }) orelse return;
        self.scene_rect = viewport.SceneRect.init(.{
            content.minimum[0],
            toolbar.maximum[1],
        }, content.maximum);
        self.drawViewportToolbar(frame, toolbar);
    }

    fn drawViewportToolbar(
        self: *Editor,
        frame: *const FrameInput,
        toolbar: viewport.SceneRect,
    ) void {
        zgui.setNextWindowPos(.{
            .x = toolbar.minimum[0],
            .y = toolbar.minimum[1],
            .cond = .always,
        });
        zgui.setNextWindowSize(.{
            .w = toolbar.maximum[0] - toolbar.minimum[0],
            .h = toolbar.maximum[1] - toolbar.minimum[1],
            .cond = .always,
        });
        zgui.setNextWindowBgAlpha(.{ .alpha = 0.92 });
        if (zgui.begin("##viewport_toolbar", .{ .flags = .{
            .no_title_bar = true,
            .no_resize = true,
            .no_move = true,
            .no_collapse = true,
            .no_saved_settings = true,
            .no_focus_on_appearing = true,
            .no_nav_focus = true,
            .no_docking = true,
        } })) {
            if (zgui.button(if (self.viewport_mode == .character)
                "Character [active]"
            else
                "Character", .{}))
            {
                frame.viewport.requests.submit(.{ .set_mode = .character });
            }
            zgui.sameLine(.{});
            if (zgui.button(if (self.viewport_mode == .free_camera)
                "Free Camera [active]"
            else
                "Free Camera", .{}))
            {
                frame.viewport.requests.submit(.{ .set_mode = .free_camera });
            }

            const free_mode = self.viewport_mode == .free_camera;
            zgui.sameLine(.{});
            zgui.beginDisabled(.{ .disabled = !free_mode });
            if (zgui.button("Start From Product View", .{})) {
                frame.viewport.requests.submit(.start_from_product_view);
            }
            zgui.sameLine(.{});
            const target = viewportFocusTarget(self, frame);
            zgui.beginDisabled(.{ .disabled = target == null });
            if (zgui.button("Frame Selection", .{})) {
                frame.viewport.requests.submit(.{ .frame_selection = target.? });
            }
            zgui.endDisabled();
            zgui.endDisabled();

            if (free_mode) {
                zgui.sameLine(.{});
                zgui.textDisabled(
                    "speed {d:.2} m/s",
                    .{frame.viewport.view.free_camera.move_speed},
                );
            }

            if (free_mode) {
                zgui.textDisabled(
                    "LMB select | RMB+WASD fly | Q/E up/down | Shift fast | wheel speed | F frame selection | F3 Character",
                    .{},
                );
                if (self.scene_rect) |scene| {
                    if (scene.contains(zgui.getMousePos()) and
                        !zgui.isAnyItemActive() and
                        !zgui.isPopupOpen("", .any_popup) and
                        zgui.isKeyPressed(.f, false))
                    {
                        if (target) |focus| {
                            frame.viewport.requests.submit(.{ .frame_selection = focus });
                        }
                    }
                }
            } else {
                zgui.textDisabled(
                    "Click viewport: capture | Esc: release | 1: handgun | LMB: fire | R: tactical reload | F3: Free Camera",
                    .{},
                );
            }
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

    fn drawSystemMenu(self: *Editor) void {
        const popup_name = "System Menu##incinerator_system_menu";
        if (self.system_menu_popup_pending) {
            zgui.openPopup(popup_name, .{});
            self.system_menu_popup_pending = false;
        }

        const main_viewport = zgui.getMainViewport();
        const work_pos = main_viewport.getWorkPos();
        const work_size = main_viewport.getWorkSize();
        zgui.setNextWindowPos(.{
            .x = work_pos[0] + work_size[0] * 0.5,
            .y = work_pos[1] + work_size[1] * 0.5,
            .cond = .always,
            .pivot_x = 0.5,
            .pivot_y = 0.5,
        });
        zgui.setNextWindowSize(.{ .w = 360, .h = 150, .cond = .always });
        if (zgui.beginPopupModal(popup_name, .{
            .popen = &self.system_menu_open,
            .flags = .{
                .no_resize = true,
                .no_move = true,
                .no_collapse = true,
                .no_saved_settings = true,
            },
        })) {
            zgui.textWrapped(
                "Gameplay continues while this developer menu is open.",
                .{},
            );
            zgui.separator();
            if (zgui.button("Resume", .{ .w = 160 })) {
                self.system_menu_open = false;
                zgui.closeCurrentPopup();
            }
            zgui.sameLine(.{});
            if (zgui.button("Quit", .{ .w = 160 })) {
                self.requestSystemMenuQuit();
                zgui.closeCurrentPopup();
            }
            zgui.textDisabled("Esc resumes | Quit exits the application", .{});
            zgui.endPopup();
        }
    }

    pub fn requestSystemMenuQuit(self: *Editor) void {
        self.quit_requested = true;
        self.system_menu_open = false;
        self.system_menu_popup_pending = false;
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
            for (panel_menu_order) |id| {
                const registered_tool = self.toolById(id);
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
            if (zgui.menuItem("Character", .{
                .shortcut = "F3",
                .selected = self.viewport_mode == .character,
            })) {
                self.pending_viewport_mode = .character;
            }
            if (zgui.menuItem("Free Camera", .{
                .shortcut = "F3",
                .selected = self.viewport_mode == .free_camera,
            })) {
                self.pending_viewport_mode = .free_camera;
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

    fn toolById(self: *Editor, id: tool.ToolId) *Tool {
        for (&self.tools) |*registered_tool| {
            if (registered_tool.descriptor.id == id) return registered_tool;
        }
        unreachable;
    }

    /// Reveal the concrete authoring Inspector once when a new inspectable
    /// crate becomes the shared selection. Remembering the observed identity
    /// lets a developer close the panel without it reopening every frame; a
    /// later clear or different selection makes reselecting the crate reveal
    /// it again.
    fn observeSelection(self: *Editor, view: selection.View) void {
        const active = view.activeEntry();
        const current = if (active) |entry| entry.id else null;
        if (optionalSelectionEql(self.last_observed_selection, current)) return;
        self.last_observed_selection = current;
        if (current != null) self.inspector_subject = .world;

        const entry = active orelse return;
        if (entry.kind != .crate or
            entry.availability != .available or
            !entry.inspectable)
        {
            return;
        }

        self.toolById(.crate_authoring).enabled = true;
        self.pending_focus = .crate_authoring;
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

    fn inputSceneRect(context: *anyopaque) ?viewport.SceneRect {
        const self: *const Editor = @ptrCast(@alignCast(context));
        return self.viewportSceneRect();
    }

    fn inputToggleSystemMenu(context: *anyopaque) void {
        const self: *Editor = @ptrCast(@alignCast(context));
        self.toggleSystemMenu();
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

fn panelNameLessThanIgnoreCase(lhs: []const u8, rhs: []const u8) bool {
    const shared_len = @min(lhs.len, rhs.len);
    for (lhs[0..shared_len], rhs[0..shared_len]) |lhs_byte, rhs_byte| {
        const lhs_lower = std.ascii.toLower(lhs_byte);
        const rhs_lower = std.ascii.toLower(rhs_byte);
        if (lhs_lower != rhs_lower) return lhs_lower < rhs_lower;
    }
    return lhs.len < rhs.len;
}

fn optionalSelectionEql(first: ?selection.Id, second: ?selection.Id) bool {
    if (first == null or second == null) return first == null and second == null;
    return first.?.eql(second.?);
}

fn viewportMouseStatus(mode: viewport.Mode, captured: bool) []const u8 {
    return switch (mode) {
        .character => if (captured)
            "Character CAPTURED (Esc releases)"
        else
            "Character cursor free (click viewport to capture)",
        .free_camera => "Free Camera cursor released",
    };
}

fn viewportFocusTarget(
    _: *const Editor,
    frame: *const FrameInput,
) ?viewport.FocusTarget {
    const bounds = (frame.selection.view.activeEntry() orelse return null)
        .world_bounds orelse return null;
    const half_extents = bounds.halfExtents();
    const target = viewport.FocusTarget{
        .center = bounds.center(),
        .radius = @max(half_extents[0], @max(half_extents[1], half_extents[2])),
    };
    return if (target.isValid()) target else null;
}

fn productStatusColumnCount(width: f32) i32 {
    if (width >= 1_000) return 4;
    if (width >= 600) return 2;
    return 1;
}

fn productStatusHeight(width: f32) f32 {
    return switch (productStatusColumnCount(width)) {
        4 => 76,
        2 => 132,
        else => 204,
    };
}

fn drawProductStatusTable(
    editor: *const Editor,
    frame: *const FrameInput,
    available_width: f32,
) void {
    const columns = productStatusColumnCount(available_width);
    if (!zgui.beginTable("##product_status_columns", .{
        .column = columns,
        .flags = .{
            .borders = .inner,
            .sizing = .stretch_same,
            .no_saved_settings = true,
        },
    })) return;
    defer zgui.endTable();

    inline for (0..4) |index| {
        if (index % @as(usize, @intCast(columns)) == 0) {
            zgui.tableNextRow(.{});
        }
        _ = zgui.tableNextColumn();
        switch (index) {
            0 => gameplay_inspector_tool.drawPlayerStatus(&frame.gameplay),
            1 => gameplay_inspector_tool.drawWeaponStatus(&frame.gameplay),
            2 => gameplay_inspector_tool.drawThreatStatus(&frame.gameplay),
            3 => {
                incident_capture_tool.drawProductStatus(&frame.incident);
                zgui.textColored(
                    if (editor.viewport_mode == .free_camera)
                        .{ 0.85, 0.65, 1, 1 }
                    else if (editor.gameplay_mouse_captured)
                        .{ 0.25, 0.95, 1, 1 }
                    else
                        .{ 0.7, 0.7, 0.7, 1 },
                    "{s}",
                    .{viewportMouseStatus(
                        editor.viewport_mode,
                        editor.gameplay_mouse_captured,
                    )},
                );
            },
            else => unreachable,
        }
    }
}

fn drawProductStatusOverlay(editor: *const Editor, frame: *const FrameInput) void {
    const main_viewport = zgui.getMainViewport();
    const work_pos = main_viewport.getWorkPos();
    const work_size = main_viewport.getWorkSize();
    zgui.setNextWindowPos(.{
        .x = work_pos[0] + 10,
        .y = work_pos[1] + 10,
        .cond = .always,
    });
    const overlay_width = @max(@as(f32, 280), work_size[0] - 20);
    zgui.setNextWindowSize(.{
        .w = overlay_width,
        .h = productStatusHeight(overlay_width) + 30,
        .cond = .always,
    });
    zgui.setNextWindowBgAlpha(.{ .alpha = 0.82 });
    if (zgui.begin("##product_status_overlay", .{ .flags = .{
        .no_title_bar = true,
        .no_resize = true,
        .no_move = true,
        .no_collapse = true,
        .no_saved_settings = true,
        .no_focus_on_appearing = true,
        .no_nav_focus = true,
    } })) {
        drawProductStatusTable(editor, frame, overlay_width);
        zgui.textDisabled("Editor hidden | F1 shows the workspace", .{});
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

test "Panels menu contains every registered tool once in alphabetical order" {
    try std.testing.expectEqual(default_tools.len, panel_menu_order.len);

    var seen = [_]bool{false} ** std.meta.tags(tool.ToolId).len;
    var previous_name: ?[]const u8 = null;
    for (panel_menu_order) |id| {
        const index = @intFromEnum(id);
        try std.testing.expect(!seen[index]);
        seen[index] = true;

        var descriptor: ?workspace.Descriptor = null;
        for (default_tools) |registered_tool| {
            if (registered_tool.descriptor.id == id) {
                descriptor = registered_tool.descriptor;
                break;
            }
        }
        const current_name = descriptor orelse return error.UnregisteredPanelMenuTool;
        if (previous_name) |previous| {
            try std.testing.expect(panelNameLessThanIgnoreCase(
                previous,
                current_name.name,
            ));
        }
        previous_name = current_name.name;
    }

    for (seen) |present| try std.testing.expect(present);
    try std.testing.expect(panelNameLessThanIgnoreCase("Incident Capture", "Inspector"));
}

test "product status strip uses responsive columns without overlapping docks" {
    try std.testing.expectEqual(@as(i32, 4), productStatusColumnCount(1_600));
    try std.testing.expectEqual(@as(i32, 2), productStatusColumnCount(800));
    try std.testing.expectEqual(@as(i32, 1), productStatusColumnCount(420));
    try std.testing.expect(productStatusHeight(420) > productStatusHeight(1_600));
}

test "editor runtime and tool state belong to each value" {
    var first = Editor{};
    const second = Editor{};

    first.visible = false;
    first.tools[0].toggle();
    first.stats.history_index = 7;
    first.crate_authoring.dirty = true;
    first.world_outliner.kind_filter = .crate;

    try std.testing.expect(second.visible);
    try std.testing.expect(second.tools[0].enabled);
    try std.testing.expectEqual(@as(usize, 0), second.stats.history_index);
    try std.testing.expect(!second.crate_authoring.dirty);
    try std.testing.expect(second.world_outliner.kind_filter == null);
}

test "new crate selection reveals Inspector once and respects manual close" {
    var editor = Editor{};
    editor.toolById(.crate_authoring).enabled = false;
    editor.pending_focus = null;

    const crate_id: selection.Id = .{
        .persistent_entity = .{ .namespace = 1, .local = 1 },
    };
    const entries = [_]selection.Entry{.{
        .id = crate_id,
        .label = "Crate",
        .kind = .crate,
        .owner = .game_runtime,
        .inspectable = true,
        .authorable = true,
        .world_bounds = try selection.Bounds.init(.{ 0, 0, 0 }, .{ 1, 1, 1 }),
    }};
    const selected = selection.View{ .entries = &entries, .active = crate_id };

    editor.observeSelection(selected);
    try std.testing.expect(editor.toolById(.crate_authoring).enabled);
    try std.testing.expectEqual(
        workspace.ToolId.crate_authoring,
        editor.pending_focus.?,
    );

    // A manual close remains respected while the same selection stays active.
    editor.toolById(.crate_authoring).enabled = false;
    editor.pending_focus = null;
    editor.observeSelection(selected);
    try std.testing.expect(!editor.toolById(.crate_authoring).enabled);
    try std.testing.expect(editor.pending_focus == null);

    editor.observeSelection(.{ .entries = &entries, .active = null });
    editor.observeSelection(selected);
    try std.testing.expect(editor.toolById(.crate_authoring).enabled);
    try std.testing.expectEqual(
        workspace.ToolId.crate_authoring,
        editor.pending_focus.?,
    );
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

test "F3 requests the opposite explicit viewport mode" {
    var editor = Editor{};
    var event = std.mem.zeroes(c.SDL_Event);
    event.type = c.SDL_EVENT_KEY_DOWN;
    event.key.scancode = c.SDL_SCANCODE_F3;

    var route = editor.processEvent(&event);
    try std.testing.expect(route.keyboard_reserved);
    try std.testing.expectEqual(viewport.Mode.free_camera, route.viewport_mode_request.?);
    try std.testing.expectEqual(viewport.Mode.free_camera, editor.viewport_mode);

    route = editor.processEvent(&event);
    try std.testing.expectEqual(viewport.Mode.character, route.viewport_mode_request.?);
    try std.testing.expectEqual(viewport.Mode.character, editor.viewport_mode);
}

test "editor Escape acceptance cancels an active gizmo before the system menu fallback" {
    var editor = Editor{};
    editor.crate_authoring = .{
        .id = .{ .namespace = 1, .local = 4 },
        .position = .{ 3, 4, 5 },
        .dirty = true,
    };
    editor.crate_authoring.beginGizmoDrag(.x);
    try std.testing.expect(editor.crate_authoring.applyGizmoDisplacement(.x, 7));

    var event = std.mem.zeroes(c.SDL_Event);
    event.type = c.SDL_EVENT_KEY_DOWN;
    event.key.scancode = c.SDL_SCANCODE_ESCAPE;
    const route = editor.processEvent(&event);

    try std.testing.expect(route.keyboard_reserved);
    try std.testing.expect(route.system_menu_available);
    try std.testing.expect(!editor.gizmoDragActive());
    try std.testing.expect(!editor.crate_authoring.gizmoDragActive());
    try std.testing.expectEqual([3]f32{ 3, 4, 5 }, editor.crate_authoring.position);
    try std.testing.expect(editor.crate_authoring.dirty);
    try std.testing.expect(!editor.systemMenuOpen());
}

test "editor Escape acceptance opens and then closes the owned system menu" {
    var editor = Editor{};
    var event = std.mem.zeroes(c.SDL_Event);
    event.type = c.SDL_EVENT_KEY_DOWN;
    event.key.scancode = c.SDL_SCANCODE_ESCAPE;

    const fallback = editor.processEvent(&event);
    try std.testing.expect(!fallback.keyboard_reserved);
    try std.testing.expect(fallback.system_menu_available);
    editor.toggleSystemMenu();
    try std.testing.expect(editor.systemMenuOpen());
    try std.testing.expect(editor.wantsKeyboard());
    try std.testing.expect(editor.wantsMouse());

    const close = editor.processEvent(&event);
    try std.testing.expect(close.keyboard_reserved);
    try std.testing.expect(!editor.systemMenuOpen());
    try std.testing.expect(!editor.takeQuitRequested());
}

test "viewport mode change forcibly cancels an active gizmo" {
    var editor = Editor{};
    editor.viewport_mode = .free_camera;
    editor.crate_authoring = .{
        .id = .{ .namespace = 1, .local = 4 },
        .position = .{ 3, 4, 5 },
    };
    editor.crate_authoring.gizmo_handle_regions[0] = .{
        .minimum = .{ 90, 90 },
        .maximum = .{ 110, 110 },
    };
    editor.crate_authoring.beginGizmoDrag(.z);
    try std.testing.expect(editor.crate_authoring.applyGizmoDisplacement(.z, 7));

    var event = std.mem.zeroes(c.SDL_Event);
    event.type = c.SDL_EVENT_KEY_DOWN;
    event.key.scancode = c.SDL_SCANCODE_F3;
    const route = editor.processEvent(&event);

    try std.testing.expect(route.keyboard_reserved);
    try std.testing.expectEqual(viewport.Mode.character, editor.viewport_mode);
    try std.testing.expect(!editor.crate_authoring.gizmoDragActive());
    try std.testing.expectEqual([3]f32{ 3, 4, 5 }, editor.crate_authoring.position);
    try std.testing.expect(!editor.crate_authoring.dirty);
    try std.testing.expect(!editor.crate_authoring.claimsGizmoPointer(.{ 100, 100 }));
}

test "viewport mode round trip hides gizmo projection but preserves its inactive authoring draft" {
    var editor = Editor{};
    editor.viewport_mode = .free_camera;
    editor.crate_authoring = .{
        .id = .{ .namespace = 1, .local = 4 },
        .position = .{ 6, 7, 8 },
        .draft_base_revision = 12,
        .dirty = true,
    };

    editor.setViewportMode(.character);
    try std.testing.expectEqual([3]f32{ 6, 7, 8 }, editor.crate_authoring.position);
    try std.testing.expectEqual(@as(u64, 12), editor.crate_authoring.draft_base_revision);
    try std.testing.expect(editor.crate_authoring.dirty);
    try std.testing.expect(!viewport.editorWorldAffordancesVisible(
        editor.visible,
        editor.viewport_mode,
    ));

    editor.setViewportMode(.free_camera);
    try std.testing.expectEqual([3]f32{ 6, 7, 8 }, editor.crate_authoring.position);
    try std.testing.expectEqual(@as(u64, 12), editor.crate_authoring.draft_base_revision);
    try std.testing.expect(editor.crate_authoring.dirty);
    try std.testing.expect(viewport.editorWorldAffordancesVisible(
        editor.visible,
        editor.viewport_mode,
    ));
}

test "focus loss and minimization deactivate the complete gizmo projection" {
    for ([_]u32{
        c.SDL_EVENT_WINDOW_FOCUS_LOST,
        c.SDL_EVENT_WINDOW_MINIMIZED,
    }) |event_type| {
        var editor = Editor{};
        editor.viewport_mode = .free_camera;
        editor.crate_authoring = .{
            .id = .{ .namespace = 1, .local = 4 },
            .position = .{ 3, 4, 5 },
            .dirty = true,
        };
        editor.crate_authoring.gizmo_handle_regions[0] = .{
            .minimum = .{ 90, 90 },
            .maximum = .{ 110, 110 },
        };
        editor.crate_authoring.beginGizmoDrag(.x);
        try std.testing.expect(editor.crate_authoring.applyGizmoDisplacement(.x, 7));

        var event = std.mem.zeroes(c.SDL_Event);
        event.type = event_type;
        _ = editor.processEvent(&event);

        try std.testing.expect(!editor.crate_authoring.gizmoDragActive());
        try std.testing.expectEqual([3]f32{ 3, 4, 5 }, editor.crate_authoring.position);
        try std.testing.expect(editor.crate_authoring.dirty);
        try std.testing.expect(!editor.crate_authoring.claimsGizmoPointer(.{ 100, 100 }));
    }
}

test "editor Escape acceptance system menu Quit emits one explicit lifecycle request" {
    var editor = Editor{};
    editor.toggleSystemMenu();
    editor.requestSystemMenuQuit();

    try std.testing.expect(!editor.systemMenuOpen());
    try std.testing.expect(editor.takeQuitRequested());
    try std.testing.expect(!editor.takeQuitRequested());
}
