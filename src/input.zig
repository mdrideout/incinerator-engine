//! input.zig - Input buffering for the canonical game loop
//!
//! This module handles SDL3 event processing and provides a buffered input state
//! that the simulation can consume at its fixed tick rate.
//!
//! Key concepts:
//! - Input is polled every frame (uncapped) to ensure responsiveness
//! - State is "latched" so the simulation sees consistent input per tick
//! - Mouse delta is accumulated between ticks for smooth camera movement

const std = @import("std");
const sdl = @import("sdl.zig");
const build_options = @import("build_options");

// Conditionally import editor for event processing
const editor = if (build_options.editor_enabled)
    @import("editor/editor.zig")
else
    struct {
        pub fn processEvent(_: anytype) bool {
            return false;
        }
    };

// Use shared SDL bindings to avoid opaque type conflicts
const c = sdl.c;

/// Maximum number of keys we track (SDL scancodes go up to ~512)
const MAX_KEYS = 512;

/// InputBuffer stores the current input state.
/// This is what the simulation reads each tick.
pub const InputBuffer = struct {
    // ========================================================================
    // Keyboard State
    // ========================================================================

    /// Current state of all keys (true = pressed)
    keys_down: [MAX_KEYS]bool,

    /// Keys that were just pressed this frame (for "on press" events)
    keys_pressed: [MAX_KEYS]bool,

    /// Keys that were just released this frame (for "on release" events)
    keys_released: [MAX_KEYS]bool,

    // ========================================================================
    // Mouse State
    // ========================================================================

    /// Current mouse position in window coordinates
    mouse_x: f32,
    mouse_y: f32,

    /// Mouse movement delta since last tick (accumulated)
    mouse_delta_x: f32,
    mouse_delta_y: f32,

    /// Mouse button state (SDL supports up to 5 buttons)
    mouse_buttons: [5]bool,

    /// Mouse buttons just pressed this frame
    mouse_buttons_pressed: [5]bool,

    /// Mouse buttons just released this frame
    mouse_buttons_released: [5]bool,

    /// Mouse wheel delta (accumulated)
    mouse_wheel_x: f32,
    mouse_wheel_y: f32,

    // ========================================================================
    // Window/System Events
    // ========================================================================

    /// True if the user requested to quit (close button, Alt+F4, etc.)
    quit_requested: bool,

    /// True if the window was resized this frame
    window_resized: bool,

    /// New window dimensions (valid if window_resized is true)
    window_width: i32,
    window_height: i32,

    /// Initialize with all inputs cleared
    pub fn init() InputBuffer {
        return InputBuffer{
            .keys_down = [_]bool{false} ** MAX_KEYS,
            .keys_pressed = [_]bool{false} ** MAX_KEYS,
            .keys_released = [_]bool{false} ** MAX_KEYS,
            .mouse_x = 0,
            .mouse_y = 0,
            .mouse_delta_x = 0,
            .mouse_delta_y = 0,
            .mouse_buttons = [_]bool{false} ** 5,
            .mouse_buttons_pressed = [_]bool{false} ** 5,
            .mouse_buttons_released = [_]bool{false} ** 5,
            .mouse_wheel_x = 0,
            .mouse_wheel_y = 0,
            .quit_requested = false,
            .window_resized = false,
            .window_width = 0,
            .window_height = 0,
        };
    }

    /// Clear per-frame events (pressed/released flags, deltas)
    /// Call this at the start of each frame before pumping events.
    pub fn beginFrame(self: *InputBuffer) void {
        // Clear "just pressed" and "just released" flags
        @memset(&self.keys_pressed, false);
        @memset(&self.keys_released, false);
        @memset(&self.mouse_buttons_pressed, false);
        @memset(&self.mouse_buttons_released, false);

        // Clear accumulated deltas
        self.mouse_delta_x = 0;
        self.mouse_delta_y = 0;
        self.mouse_wheel_x = 0;
        self.mouse_wheel_y = 0;

        // Clear per-frame flags
        self.window_resized = false;
    }

    /// Process all pending SDL events. Call once per frame.
    /// Returns false if the application should quit.
    pub fn pumpEvents(self: *InputBuffer) bool {
        var event: c.SDL_Event = undefined;

        while (c.SDL_PollEvent(&event)) {
            // Let editor process events first (for ImGui input handling)
            // If editor consumed the event, skip game input processing
            const editor_consumed = editor.processEvent(&event);
            if (editor_consumed) {
                // Still check for quit even if editor consumed the event
                if (event.type == c.SDL_EVENT_QUIT) {
                    self.quit_requested = true;
                }
                continue;
            }

            switch (event.type) {
                // Window close requested
                c.SDL_EVENT_QUIT => {
                    self.quit_requested = true;
                },

                // Keyboard events
                c.SDL_EVENT_KEY_DOWN => {
                    const scancode: usize = @intCast(event.key.scancode);
                    if (scancode < MAX_KEYS) {
                        // Only set "pressed" if it wasn't already down (ignore repeats)
                        if (!self.keys_down[scancode]) {
                            self.keys_pressed[scancode] = true;
                        }
                        self.keys_down[scancode] = true;
                    }

                    // Debug: ESC to quit (convenience during development)
                    if (event.key.scancode == c.SDL_SCANCODE_ESCAPE) {
                        self.quit_requested = true;
                    }
                },

                c.SDL_EVENT_KEY_UP => {
                    const scancode: usize = @intCast(event.key.scancode);
                    if (scancode < MAX_KEYS) {
                        self.keys_released[scancode] = true;
                        self.keys_down[scancode] = false;
                    }
                },

                // Mouse motion
                c.SDL_EVENT_MOUSE_MOTION => {
                    self.mouse_x = event.motion.x;
                    self.mouse_y = event.motion.y;
                    self.mouse_delta_x += event.motion.xrel;
                    self.mouse_delta_y += event.motion.yrel;
                },

                // Mouse buttons
                c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
                    const button: usize = @intCast(event.button.button - 1); // SDL buttons are 1-indexed
                    if (button < 5) {
                        if (!self.mouse_buttons[button]) {
                            self.mouse_buttons_pressed[button] = true;
                        }
                        self.mouse_buttons[button] = true;
                    }
                },

                c.SDL_EVENT_MOUSE_BUTTON_UP => {
                    const button: usize = @intCast(event.button.button - 1);
                    if (button < 5) {
                        self.mouse_buttons_released[button] = true;
                        self.mouse_buttons[button] = false;
                    }
                },

                // Mouse wheel
                c.SDL_EVENT_MOUSE_WHEEL => {
                    self.mouse_wheel_x += event.wheel.x;
                    self.mouse_wheel_y += event.wheel.y;
                },

                // Window resize
                c.SDL_EVENT_WINDOW_RESIZED => {
                    self.window_resized = true;
                    self.window_width = event.window.data1;
                    self.window_height = event.window.data2;
                },

                else => {},
            }
        }

        return !self.quit_requested;
    }

    // ========================================================================
    // Query Methods - Use these in your simulation/game code
    // ========================================================================

    /// Check if a key is currently held down
    pub fn isKeyDown(self: *const InputBuffer, scancode: c.SDL_Scancode) bool {
        const idx: usize = @intCast(scancode);
        if (idx >= MAX_KEYS) return false;
        return self.keys_down[idx];
    }

    /// Check if a key was just pressed this frame
    pub fn isKeyPressed(self: *const InputBuffer, scancode: c.SDL_Scancode) bool {
        const idx: usize = @intCast(scancode);
        if (idx >= MAX_KEYS) return false;
        return self.keys_pressed[idx];
    }

    /// Check if a key was just released this frame
    pub fn isKeyReleased(self: *const InputBuffer, scancode: c.SDL_Scancode) bool {
        const idx: usize = @intCast(scancode);
        if (idx >= MAX_KEYS) return false;
        return self.keys_released[idx];
    }

    /// Check if a mouse button is currently held (0=left, 1=middle, 2=right)
    pub fn isMouseButtonDown(self: *const InputBuffer, button: u8) bool {
        if (button >= 5) return false;
        return self.mouse_buttons[button];
    }

    /// Check if a mouse button was just pressed
    pub fn isMouseButtonPressed(self: *const InputBuffer, button: u8) bool {
        if (button >= 5) return false;
        return self.mouse_buttons_pressed[button];
    }

    /// Debug: Print current input state
    pub fn debugPrint(self: *const InputBuffer) void {
        // Only print if there's interesting input
        if (self.mouse_delta_x != 0 or self.mouse_delta_y != 0) {
            std.debug.print("Mouse: ({d:.1}, {d:.1}) delta: ({d:.1}, {d:.1})\n", .{
                self.mouse_x,
                self.mouse_y,
                self.mouse_delta_x,
                self.mouse_delta_y,
            });
        }

        // Print any pressed keys
        for (self.keys_pressed, 0..) |pressed, i| {
            if (pressed) {
                std.debug.print("Key pressed: scancode {d}\n", .{i});
            }
        }

        // Print mouse button presses
        for (self.mouse_buttons_pressed, 0..) |pressed, i| {
            if (pressed) {
                std.debug.print("Mouse button pressed: {d}\n", .{i});
            }
        }
    }
};

// ============================================================================
// Common Scancode Constants (for convenience)
// ============================================================================

pub const Key = struct {
    pub const W = c.SDL_SCANCODE_W;
    pub const A = c.SDL_SCANCODE_A;
    pub const S = c.SDL_SCANCODE_S;
    pub const D = c.SDL_SCANCODE_D;
    pub const Q = c.SDL_SCANCODE_Q;
    pub const E = c.SDL_SCANCODE_E;
    pub const SPACE = c.SDL_SCANCODE_SPACE;
    pub const LSHIFT = c.SDL_SCANCODE_LSHIFT;
    pub const LCTRL = c.SDL_SCANCODE_LCTRL;
    pub const ESCAPE = c.SDL_SCANCODE_ESCAPE;
    pub const TAB = c.SDL_SCANCODE_TAB;
    pub const F1 = c.SDL_SCANCODE_F1;
    pub const F2 = c.SDL_SCANCODE_F2;
    pub const F3 = c.SDL_SCANCODE_F3;
};

pub const MouseButton = struct {
    pub const LEFT: u8 = 0;
    pub const MIDDLE: u8 = 1;
    pub const RIGHT: u8 = 2;
};

// ============================================================================
// Tests
// ============================================================================

test "InputBuffer initialization" {
    const input = InputBuffer.init();
    try std.testing.expect(!input.quit_requested);
    try std.testing.expect(input.mouse_x == 0);
}
