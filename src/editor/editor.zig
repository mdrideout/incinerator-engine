//! editor.zig - Editor System Orchestrator
//!
//! DOMAIN: Editor Layer (top-level)
//!
//! This module is the main entry point for the editor system. It manages:
//! - ImGui backend lifecycle
//! - Tool registration and rendering
//! - Editor UI (main menu bar, tool toggles)
//! - Shared editor state (EditorContext)
//!
//! Architecture:
//! The editor follows a tool-first architecture where each debug panel is a
//! self-contained "Tool" that implements a simple interface. Tools are manually
//! registered in this file, giving explicit control over what's included.
//!
//! The editor is conditionally compiled via the `editor_enabled` build option:
//! - Debug builds: Editor enabled by default
//! - Release builds: Editor disabled by default (can override with -Deditor=true)
//!
//! Integration with Game Loop:
//! ```
//! // In main.zig render function:
//! renderer.beginFrame(clear_color);
//! // ... draw scene ...
//! editor.draw(renderer, ctx);  // Draw editor overlay
//! renderer.endFrame();
//! ```

const std = @import("std");
const build_options = @import("build_options");
const zgui = @import("zgui");

const sdl = @import("../sdl.zig");
const renderer_module = @import("../renderer.zig");
const camera_module = @import("../camera.zig");
const ecs_module = @import("../ecs.zig");
const timing_module = @import("../timing.zig");

const imgui_backend = @import("imgui_backend.zig");
const tool = @import("tool.zig");

// Import tools
// Each tool is a self-contained module that defines a `tool` variable.
// We import them here and register them in the tools array below.
const stats_tool = @import("tools/stats_tool.zig");
const camera_tool = @import("tools/camera_tool.zig");
const scene_tool = @import("tools/scene_tool.zig");
const render_tool = @import("tools/render_tool.zig");
const gizmo_tool = @import("tools/gizmo_tool.zig");

const c = sdl.c;

pub const Tool = tool.Tool;
pub const EditorContext = tool.EditorContext;
pub const GizmoMode = tool.GizmoMode;
pub const GizmoSpace = tool.GizmoSpace;

/// Semantic editor routing for an SDL event.
///
/// This reports only shortcuts that the editor itself reserved. It is
/// intentionally separate from ImGui's `WantCapture*` state: the boolean
/// returned by the SDL backend only means that it recognized an event.
pub const EventRoute = struct {
    keyboard_reserved: bool = false,
    mouse_reserved: bool = false,
};

fn cameraNavigationActive(mouse_state: c.SDL_MouseButtonFlags, mouse_captured: bool) bool {
    return !mouse_captured and (mouse_state & c.SDL_BUTTON_RMASK) != 0;
}

// ============================================================================
// Editor State
// ============================================================================

/// Whether the editor overlay is visible (can be toggled with F1)
var editor_visible: bool = true;

/// Show the ImGui demo window (for learning/reference)
var show_demo_window: bool = false;

/// Input passthrough mode (F3 toggle).
///
/// Passthrough is an explicit debugging override. It defaults to false so the
/// editor honors ImGui's capture requests during normal use. ImGui always sees
/// every SDL event regardless of this setting.
var input_passthrough: bool = false;

/// Currently selected entity (persists across frames)
/// Used by Scene tool for entity selection/inspection
var selected_entity: ?u64 = null;

/// Current gizmo operation mode (for future gizmo tool)
var gizmo_mode: GizmoMode = .translate;

/// Gizmo coordinate space (for future gizmo tool)
var gizmo_space: GizmoSpace = .world;

// ============================================================================
// Tool Registry
// ============================================================================
// Tools are explicitly registered here. This is intentional:
// - You see exactly what tools are included
// - Easy to reorder (affects menu and render order)
// - Compile error if a tool file is missing
//
// To add a new tool:
// 1. Create the tool file in tools/
// 2. Import it above
// 3. Add &tool_name.tool to this array

var tools = [_]*Tool{
    &stats_tool.tool,
    &camera_tool.tool,
    &scene_tool.tool,
    &render_tool.tool,
    &gizmo_tool.tool, // 3D transform manipulation gizmo (W/E/R to switch modes)
    // Add more tools here as we create them:
    // &console_tool.tool,
};

// ============================================================================
// Public API
// ============================================================================

/// Initialize the editor system.
///
/// Call this after the renderer is initialized. Sets up ImGui and all tools.
pub fn init(
    window: *c.SDL_Window,
    device: *c.SDL_GPUDevice,
    swapchain_format: c.SDL_GPUTextureFormat,
) void {
    // Skip if editor is disabled at build time
    if (!build_options.editor_enabled) return;

    // ImGui's pipeline must match the actual claimed-window swapchain format.
    imgui_backend.init(window, device, swapchain_format);

    std.debug.print("Editor initialized with {} tools\n", .{tools.len});
}

/// Shutdown the editor system.
pub fn deinit() void {
    if (!build_options.editor_enabled) return;
    imgui_backend.deinit();
}

/// Run editor-owned lifecycle transitions independently of rendering. This is
/// required while a window is minimized or otherwise has no renderable frame.
pub fn updateLifecycle(world: *ecs_module.GameWorld) void {
    if (!build_options.editor_enabled) return;
    if (!editor_visible or !gizmo_tool.tool.enabled) {
        gizmo_tool.releaseInteraction(world);
    }
}

/// Release world-scoped editor state before the ECS/physics world is destroyed.
pub fn releaseWorld(world: *ecs_module.GameWorld) void {
    if (!build_options.editor_enabled) return;
    gizmo_tool.releaseInteraction(world);
    selected_entity = null;
}

/// Process an SDL event for editor input.
///
/// Every event is forwarded to the ImGui backend, including events received
/// while the overlay is hidden. The returned route contains only explicit
/// editor shortcuts; gameplay capture is queried separately through
/// wantsMouse() and wantsKeyboard().
///
/// Key behavior:
/// - F1: Toggle editor visibility (always works, even when hidden)
/// - F2: Toggle ImGui demo window (only when editor visible)
/// - F3: Toggle input passthrough mode (always works)
///
/// Input passthrough mode disables ImGui capture as an explicit debugging
/// override. It does not stop ImGui from receiving events.
pub fn processEvent(event: *const c.SDL_Event) EventRoute {
    if (!build_options.editor_enabled) return .{};

    // Backend recognition is not capture. ImGui must observe every event so
    // key/button releases and focus transitions cannot become unbalanced.
    _ = imgui_backend.processEvent(event);

    var route = EventRoute{};

    // ========================================================================
    // Global hotkeys - these work regardless of editor visibility or passthrough
    // ========================================================================
    if (event.type == c.SDL_EVENT_KEY_DOWN) {
        // F1: Toggle editor visibility
        if (event.key.scancode == c.SDL_SCANCODE_F1) {
            if (!event.key.repeat) {
                editor_visible = !editor_visible;
            }
            route.keyboard_reserved = true;
            return route;
        }
        // F3: Toggle input passthrough mode
        if (event.key.scancode == c.SDL_SCANCODE_F3) {
            if (!event.key.repeat) {
                input_passthrough = !input_passthrough;
            }
            route.keyboard_reserved = true;
            return route;
        }
        // ====================================================================
        // Gizmo Mode Hotkeys (W/E/R) - Unity convention
        // ====================================================================
        // These switch between translate/rotate/scale gizmo modes.
        // The gizmo mode is a persistent editor state - it stays set even
        // when nothing is selected, so when you DO select something, the
        // gizmo appears in the mode you last chose.
        //
        // Unity behavior:
        // - Right-click NOT held: W/E/R switch gizmo modes (always)
        // - Right-click held: WASD moves camera (keys pass through)
        //
        // This means there's never a conflict because camera movement
        // ONLY happens while right-click is held.
        if (editor_visible) {
            // Query current mouse state to check if right-click is held
            const mouse_state = c.SDL_GetMouseState(null, null);
            const right_click_held = cameraNavigationActive(mouse_state, wantsMouse());

            // Only handle gizmo hotkeys when NOT in camera mode (right-click held)
            if (!right_click_held) {
                if (event.key.scancode == c.SDL_SCANCODE_W) {
                    gizmo_mode = .translate;
                    route.keyboard_reserved = true;
                    return route;
                }
                if (event.key.scancode == c.SDL_SCANCODE_E) {
                    gizmo_mode = .rotate;
                    route.keyboard_reserved = true;
                    return route;
                }
                if (event.key.scancode == c.SDL_SCANCODE_R) {
                    gizmo_mode = .scale;
                    route.keyboard_reserved = true;
                    return route;
                }
            }
            // When right-click is held, W/E/R pass through to game for camera
        }
    }

    // A hidden editor still receives backend events, but reserves no local
    // shortcuts other than the global toggles above.
    if (!editor_visible) return route;

    // ========================================================================
    // Editor-only hotkeys - only work when editor is visible
    // ========================================================================
    if (event.type == c.SDL_EVENT_KEY_DOWN) {
        // F2: Toggle demo window
        if (event.key.scancode == c.SDL_SCANCODE_F2) {
            if (!event.key.repeat) {
                show_demo_window = !show_demo_window;
            }
            route.keyboard_reserved = true;
            return route;
        }
    }

    return route;
}

/// Draw the editor overlay.
///
/// IMPORTANT: Call this AFTER ending the scene render pass but BEFORE submitting.
/// The editor needs to:
/// 1. Build ImGui UI (happens immediately)
/// 2. Upload draw data (needs copy pass - can't be inside render pass)
/// 3. Render ImGui (starts its own render pass with LOAD to preserve scene)
///
/// Call sequence in main.zig:
///   renderer.beginFrame()
///   drawScene()
///   renderer.endRenderPass()  // End scene pass first!
///   editor.draw()             // ImGui does its thing
///   renderer.submitFrame()    // Submit everything
///
/// When editor is hidden, a small hint is still drawn to remind users how to
/// bring it back (Press F1).
pub fn draw(
    gpu_renderer: *renderer_module.Renderer,
    camera: *const camera_module.Camera,
    world: *const ecs_module.GameWorld,
    frame_timer: *const timing_module.FrameTimer,
) void {
    if (!build_options.editor_enabled) return;

    // Get command buffer (render pass should already be ended)
    const cmd = gpu_renderer.current_cmd orelse return;

    // Get swapchain texture for ImGui's render pass
    const swapchain_texture = gpu_renderer.getSwapchainTexture() orelse return;

    // Get window size for ImGui frame
    const window_size = gpu_renderer.getWindowSize();

    // Begin new ImGui frame - we always need this, even when hidden (for the hint)
    imgui_backend.newFrame(
        @intCast(window_size.width),
        @intCast(window_size.height),
    );

    // ========================================================================
    // Hidden state: just draw the hint and return
    // ========================================================================
    if (!editor_visible) {
        gizmo_tool.releaseInteraction(@constCast(world));
        drawHiddenHint();
        imgui_backend.render(cmd, swapchain_texture);
        return;
    }

    // ========================================================================
    // Visible state: draw full editor UI
    // ========================================================================

    // Create the editor context that tools will use
    // Note: selected_entity, gizmo_mode, gizmo_space are module-level vars that persist
    var ctx = EditorContext{
        .camera = camera,
        .world = world,
        .frame_timer = frame_timer,
        .window_width = @intCast(window_size.width),
        .window_height = @intCast(window_size.height),
        .selected_entity = selected_entity,
        .gizmo_mode = gizmo_mode,
        .gizmo_space = gizmo_space,
        .wants_mouse = wantsMouse(),
        .wants_keyboard = wantsKeyboard(),
    };

    // Draw main menu bar
    drawMainMenuBar();

    // Disabling the gizmo tool is a lifecycle boundary, not just a rendering
    // choice: release any temporary kinematic body state immediately.
    if (!gizmo_tool.tool.enabled) {
        gizmo_tool.releaseInteraction(@constCast(world));
    }

    // Draw all enabled tools
    for (&tools) |t| {
        t.draw(&ctx);
    }

    // Persist editor state changes back to module-level vars
    selected_entity = ctx.selected_entity;
    gizmo_mode = ctx.gizmo_mode;
    gizmo_space = ctx.gizmo_space;

    // Draw demo window if enabled (great for learning ImGui!)
    if (show_demo_window) {
        zgui.showDemoWindow(&show_demo_window);
    }

    // Render ImGui (handles its own render pass)
    imgui_backend.render(cmd, swapchain_texture);
}

/// Check if editor wants mouse input
pub fn wantsMouse() bool {
    if (!build_options.editor_enabled) return false;
    if (!editor_visible) return false;
    if (input_passthrough) return false;
    return imgui_backend.wantsMouse();
}

/// Check if editor wants keyboard input
pub fn wantsKeyboard() bool {
    if (!build_options.editor_enabled) return false;
    if (!editor_visible) return false;
    if (input_passthrough) return false;
    return imgui_backend.wantsKeyboard();
}

/// Check if editor is currently visible
pub fn isVisible() bool {
    if (!build_options.editor_enabled) return false;
    return editor_visible;
}

// ============================================================================
// Internal: Hidden Hint Overlay
// ============================================================================

/// Draw a small hint when the editor is hidden.
/// This helps users remember how to bring the editor back.
fn drawHiddenHint() void {
    // Position in top-left corner
    zgui.setNextWindowPos(.{ .x = 10, .y = 10, .cond = .always });

    // Semi-transparent background
    zgui.setNextWindowBgAlpha(.{ .alpha = 0.5 });

    // Minimal window with no decorations
    // Note: We use a minimal set of flags that zgui supports
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
        // Gray text so it's not too distracting
        zgui.textColored(.{ 0.7, 0.7, 0.7, 1.0 }, "Press F1 to show editor", .{});
    }
    zgui.end();
}

// ============================================================================
// Internal: Main Menu Bar
// ============================================================================

fn drawMainMenuBar() void {
    if (zgui.beginMainMenuBar()) {
        // Tools menu - toggle visibility of each tool
        if (zgui.beginMenu("Tools", true)) {
            for (&tools) |t| {
                // menuItem takes a struct with optional shortcut, selected state, and enabled
                if (zgui.menuItem(t.name, .{
                    .selected = t.enabled, // Checkmark when enabled
                })) {
                    t.toggle();
                }
            }
            zgui.separator();
            if (zgui.menuItem("ImGui Demo", .{
                .shortcut = "F2",
                .selected = show_demo_window,
            })) {
                show_demo_window = !show_demo_window;
            }
            zgui.endMenu();
        }

        // View menu - general editor settings
        if (zgui.beginMenu("View", true)) {
            // Input passthrough toggle - allows camera movement while editor is open
            if (zgui.menuItem("Input Passthrough", .{
                .shortcut = "F3",
                .selected = input_passthrough,
            })) {
                input_passthrough = !input_passthrough;
            }
            zgui.separator();
            if (zgui.menuItem("Hide Editor", .{ .shortcut = "F1" })) {
                editor_visible = false;
            }
            zgui.endMenu();
        }

        zgui.endMainMenuBar();
    }
}

test "captured right mouse does not enable camera shortcut mode" {
    try std.testing.expect(cameraNavigationActive(c.SDL_BUTTON_RMASK, false));
    try std.testing.expect(!cameraNavigationActive(c.SDL_BUTTON_RMASK, true));
    try std.testing.expect(!cameraNavigationActive(0, false));
}
