//! imgui_backend.zig - ImGui SDL3 GPU Backend Integration
//!
//! DOMAIN: Editor Layer (low-level)
//!
//! This module wraps zgui's SDL3 GPU backend, providing a clean interface
//! for initializing and rendering ImGui within our engine's render loop.
//!
//! The SDL3 GPU backend renders ImGui using the same SDL_GPU API we use
//! for scene rendering. This means:
//! - Same GPU device, same swapchain
//! - ImGui draws after scene geometry in the same render pass
//! - No additional context switching or resource conflicts
//!
//! Lifecycle:
//! 1. init() - Call once at startup after renderer is created
//! 2. processEvent() - Call for each SDL event (for input handling)
//! 3. newFrame() - Call at start of each frame
//! 4. [Tools render via zgui calls]
//! 5. render() - Call at end of frame (within render pass)
//! 6. deinit() - Call at shutdown

const std = @import("std");
const zgui = @import("zgui");
const sdl = @import("../sdl.zig");

const c = sdl.c;

/// Owned lifecycle guard around zgui's process-wide ImGui context. The backend
/// does not retain a Renderer pointer; all GPU handles needed after init arrive
/// as one-frame borrows.
pub const Backend = struct {
    initialized: bool = false,

    pub fn init(
        self: *Backend,
        window: *c.SDL_Window,
        device: *c.SDL_GPUDevice,
        color_format: c.SDL_GPUTextureFormat,
    ) void {
        std.debug.assert(!self.initialized);

        // Initialize zgui (creates ImGui context)
        zgui.init(std.heap.page_allocator);
        // ED1 uses one dockspace inside the main SDL window. Platform
        // multi-viewports remain disabled so the product keeps one window and
        // one SDL GPU presentation owner.
        zgui.io.setConfigFlags(.{ .dock_enable = true });

        // Configure ImGui style for a dark, professional look
        const style = zgui.getStyle();
        style.window_rounding = 4.0;
        style.frame_rounding = 2.0;
        // Make windows slightly transparent
        var window_bg = style.getColor(.window_bg);
        window_bg[3] = 0.95;
        style.setColor(.window_bg, window_bg);

        // Initialize the SDL3 GPU backend
        // This tells ImGui how to render using SDL's GPU API
        zgui.backend.init(
            @ptrCast(window), // SDL window for input
            .{
                .device = @ptrCast(device), // GPU device for rendering
                .color_target_format = color_format, // Must match swapchain
                .msaa_samples = c.SDL_GPU_SAMPLECOUNT_1, // No MSAA (match your renderer)
            },
        );

        self.initialized = true;
        std.debug.print("ImGui SDL3 GPU backend initialized\n", .{});
    }

    /// Shutdown the ImGui backend and release resources.
    ///
    /// Call this before destroying the SDL window/device.
    pub fn deinit(self: *Backend) void {
        if (!self.initialized) return;

        zgui.backend.deinit();
        zgui.deinit();
        self.initialized = false;
        std.debug.print("ImGui backend shutdown\n", .{});
    }

    /// Process an SDL event for ImGui input handling.
    ///
    /// ImGui needs to see input events to handle mouse clicks, keyboard input, etc.
    /// Call this for every SDL event before your game processes it.
    ///
    /// Returns whether the backend recognized the event. This is not ImGui capture;
    /// gameplay routing must use `WantCaptureMouse`/`WantCaptureKeyboard` instead.
    pub fn processEvent(self: *const Backend, event: *const c.SDL_Event) bool {
        if (!self.initialized) return false;
        return zgui.backend.processEvent(@ptrCast(event));
    }

    /// Begin a new ImGui frame.
    ///
    /// Call this at the start of each frame, before any zgui drawing calls.
    /// This updates ImGui's internal state (delta time, input, etc.).
    ///
    /// Parameters:
    /// - width: Framebuffer width in pixels
    /// - height: Framebuffer height in pixels
    pub fn newFrame(
        self: *const Backend,
        width: u32,
        height: u32,
        framebuffer_scale: f32,
    ) void {
        if (!self.initialized) return;

        zgui.backend.newFrame(width, height, framebuffer_scale);
    }

    /// Prepare and render ImGui draw data.
    ///
    /// IMPORTANT: The scene render pass must be ENDED before calling this!
    /// ImGui's data upload uses a copy pass, which can't run inside a render pass.
    ///
    /// This function:
    /// 1. Finalizes the ImGui frame (zgui.render)
    /// 2. Uploads vertex/index data (may use copy pass)
    /// 3. Starts a NEW render pass for ImGui (with LOAD, not CLEAR)
    /// 4. Renders ImGui draw commands
    /// 5. Ends the ImGui render pass
    ///
    /// Parameters:
    /// - cmd: The current command buffer
    /// - swapchain_texture: The swapchain texture to render to
    pub fn render(
        self: *const Backend,
        cmd: *c.SDL_GPUCommandBuffer,
        swapchain_texture: *c.SDL_GPUTexture,
    ) void {
        if (!self.initialized) return;

        // CRITICAL: Finalize the ImGui frame and build draw lists
        // This must be called after all zgui UI calls and before rendering.
        zgui.render();

        // Prepare the draw data (upload vertices/indices to GPU)
        // This may internally use a copy pass, so must be called outside any render pass
        zgui.backend.prepareDrawData(@ptrCast(cmd));

        // Start a new render pass for ImGui overlay
        // We use LOAD (not CLEAR) to preserve the scene that was already rendered
        const color_target = c.SDL_GPUColorTargetInfo{
            .texture = swapchain_texture,
            .mip_level = 0,
            .layer_or_depth_plane = 0,
            .clear_color = c.SDL_FColor{ .r = 0, .g = 0, .b = 0, .a = 1 },
            .load_op = c.SDL_GPU_LOADOP_LOAD, // LOAD to preserve scene
            .store_op = c.SDL_GPU_STOREOP_STORE,
            .resolve_texture = null,
            .resolve_mip_level = 0,
            .resolve_layer = 0,
            .cycle = false,
            .cycle_resolve_texture = false,
            .padding1 = 0,
            .padding2 = 0,
        };

        const imgui_pass = c.SDL_BeginGPURenderPass(cmd, &color_target, 1, null) orelse {
            std.debug.print("Failed to begin ImGui render pass: {s}\n", .{c.SDL_GetError()});
            return;
        };

        // Render ImGui draw commands
        zgui.backend.renderDrawData(@ptrCast(cmd), @ptrCast(imgui_pass), null);

        // End the ImGui render pass
        c.SDL_EndGPURenderPass(imgui_pass);
    }

    /// Check if ImGui wants to capture mouse input.
    ///
    /// When true, mouse events are over an ImGui window and the game should
    /// likely ignore them.
    pub fn wantsMouse(self: *const Backend) bool {
        if (!self.initialized) return false;
        return zgui.io.getWantCaptureMouse();
    }

    /// Check if ImGui wants to capture keyboard input.
    ///
    /// When true, keyboard events are going to an ImGui text input and the
    /// game should likely ignore them.
    pub fn wantsKeyboard(self: *const Backend) bool {
        if (!self.initialized) return false;
        return zgui.io.getWantCaptureKeyboard();
    }
};
