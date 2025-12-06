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

const c = sdl.c;

pub const Tool = tool.Tool;
pub const EditorContext = tool.EditorContext;
pub const GizmoMode = tool.GizmoMode;
pub const GizmoSpace = tool.GizmoSpace;

// ============================================================================
// Editor State
// ============================================================================

/// Whether the editor overlay is visible (can be toggled with F1)
var editor_visible: bool = true;

/// Show the ImGui demo window (for learning/reference)
var show_demo_window: bool = false;

/// Input passthrough mode (F3 toggle)
/// When true, ALL input passes through to the game even when editor is visible.
/// This allows camera movement while keeping editor windows open for monitoring.
/// ImGui still receives events for hover detection and drawing, but doesn't consume them.
/// Defaults to true so you can move the camera immediately without toggling.
var input_passthrough: bool = true;

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
) void {
    // Skip if editor is disabled at build time
    if (!build_options.editor_enabled) return;

    // Initialize ImGui backend
    // We use BGRA8 which is the common swapchain format
    imgui_backend.init(window, device, c.SDL_GPU_TEXTUREFORMAT_B8G8R8A8_UNORM);

    std.debug.print("Editor initialized with {} tools\n", .{tools.len});
}

/// Shutdown the editor system.
pub fn deinit() void {
    if (!build_options.editor_enabled) return;
    imgui_backend.deinit();
}

/// Process an SDL event for editor input.
///
/// Returns true if the editor consumed the event (game won't see it).
/// Returns false if the event should also be processed by the game.
///
/// Key behavior:
/// - F1: Toggle editor visibility (always works, even when hidden)
/// - F2: Toggle ImGui demo window (only when editor visible)
/// - F3: Toggle input passthrough mode (always works)
///
/// Input passthrough mode: When enabled, ALL input passes through to the game
/// even when hovering ImGui windows. This allows camera control while monitoring
/// editor panels. ImGui still receives events for drawing/hover state.
pub fn processEvent(event: *const c.SDL_Event) bool {
    if (!build_options.editor_enabled) return false;

    // ========================================================================
    // Global hotkeys - these work regardless of editor visibility or passthrough
    // ========================================================================
    // IMPORTANT: Check these BEFORE the !editor_visible early return!
    // This fixes the bug where F1 couldn't re-show the editor after hiding.
    if (event.type == c.SDL_EVENT_KEY_DOWN) {
        // F1: Toggle editor visibility
        if (event.key.scancode == c.SDL_SCANCODE_F1) {
            editor_visible = !editor_visible;
            return true; // Consume F1 - game doesn't need it
        }
        // F3: Toggle input passthrough mode
        if (event.key.scancode == c.SDL_SCANCODE_F3) {
            input_passthrough = !input_passthrough;
            return true; // Consume F3 - game doesn't need it
        }
    }

    // If editor is hidden, don't process any other events
    if (!editor_visible) return false;

    // ========================================================================
    // Editor-only hotkeys - only work when editor is visible
    // ========================================================================
    if (event.type == c.SDL_EVENT_KEY_DOWN) {
        // F2: Toggle demo window
        if (event.key.scancode == c.SDL_SCANCODE_F2) {
            show_demo_window = !show_demo_window;
            return true;
        }
    }

    // ========================================================================
    // Input passthrough mode
    // ========================================================================
    // When passthrough is ON:
    // - Let ImGui see the event (so it can update hover state, draw correctly)
    // - But return false so the game ALSO gets the input
    if (input_passthrough) {
        _ = imgui_backend.processEvent(event); // ImGui sees it for drawing
        return false; // Game also gets it
    }

    // Normal mode: ImGui decides whether to consume
    return imgui_backend.processEvent(event);
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
        .selected_entity = selected_entity,
        .gizmo_mode = gizmo_mode,
        .gizmo_space = gizmo_space,
        .wants_mouse = imgui_backend.wantsMouse(),
        .wants_keyboard = imgui_backend.wantsKeyboard(),
    };

    // Draw main menu bar
    drawMainMenuBar();

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
    return imgui_backend.wantsMouse();
}

/// Check if editor wants keyboard input
pub fn wantsKeyboard() bool {
    if (!build_options.editor_enabled) return false;
    if (!editor_visible) return false;
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
