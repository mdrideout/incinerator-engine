//! input.zig - Input buffering for the canonical game loop
//!
//! This module handles SDL3 event processing and provides a buffered input state
//! that the simulation can consume at its fixed tick rate.
//!
//! Key concepts:
//! - Input is polled every frame (uncapped) to ensure responsiveness
//! - Physical state is independent from capture-filtered gameplay state
//! - Edges and deltas remain frame-scoped until the S0/S1 tick-buffer redesign

const std = @import("std");
const sdl = @import("sdl.zig");
const build_options = @import("build_options");

// Conditionally import the editor event/capture contract.
const editor = if (build_options.editor_enabled)
    @import("editor/editor.zig")
else
    @import("editor/disabled.zig");

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

    /// Gameplay-visible state of all keys (true = pressed).
    keys_down: [MAX_KEYS]bool,

    /// Keys that were just pressed this frame (for "on press" events)
    keys_pressed: [MAX_KEYS]bool,

    /// Keys that were just released this frame (for "on release" events)
    keys_released: [MAX_KEYS]bool,

    /// Physical state is maintained independently from gameplay routing.
    physical_keys_down: [MAX_KEYS]bool,

    /// A captured/reserved held key stays suppressed until its physical release.
    keys_suppressed: [MAX_KEYS]bool,

    // ========================================================================
    // Mouse State
    // ========================================================================

    /// Gameplay-visible mouse position in window coordinates.
    mouse_x: f32,
    mouse_y: f32,

    /// Physical mouse position, updated even while gameplay is captured.
    physical_mouse_x: f32,
    physical_mouse_y: f32,

    /// Capture-filtered mouse movement accumulated during the current frame.
    mouse_delta_x: f32,
    mouse_delta_y: f32,

    /// Physical motion accumulated this frame regardless of capture.
    physical_mouse_delta_x: f32,
    physical_mouse_delta_y: f32,

    /// Mouse button state (SDL supports up to 5 buttons)
    mouse_buttons: [5]bool,

    /// Physical mouse button state, independent from gameplay routing.
    physical_mouse_buttons: [5]bool,

    /// Captured/reserved buttons remain suppressed until physical release.
    mouse_buttons_suppressed: [5]bool,

    /// Mouse buttons just pressed this frame
    mouse_buttons_pressed: [5]bool,

    /// Mouse buttons just released this frame
    mouse_buttons_released: [5]bool,

    /// Mouse wheel delta (accumulated)
    mouse_wheel_x: f32,
    mouse_wheel_y: f32,

    /// Physical wheel delta accumulated regardless of capture.
    physical_mouse_wheel_x: f32,
    physical_mouse_wheel_y: f32,

    /// Capture state applied to gameplay input.
    keyboard_captured: bool,
    mouse_captured: bool,

    /// Entering editor capture or losing focus invalidates any actions already
    /// latched by the sandbox host during earlier render frames.
    gameplay_reset_requested: bool,

    // ========================================================================
    // Window/System Events
    // ========================================================================

    /// True if the user requested to quit (close button, Alt+F4, etc.)
    quit_requested: bool,

    /// Only this SDL window owns the application lifecycle. ImGui platform
    /// windows may emit their own close requests without quitting the engine.
    main_window_id: c.SDL_WindowID,

    /// True if the window was resized this frame
    window_resized: bool,

    /// New window dimensions (valid if window_resized is true)
    window_width: i32,
    window_height: i32,

    /// Initialize with all inputs cleared
    pub fn init(main_window_id: c.SDL_WindowID) InputBuffer {
        return InputBuffer{
            .keys_down = [_]bool{false} ** MAX_KEYS,
            .keys_pressed = [_]bool{false} ** MAX_KEYS,
            .keys_released = [_]bool{false} ** MAX_KEYS,
            .physical_keys_down = [_]bool{false} ** MAX_KEYS,
            .keys_suppressed = [_]bool{false} ** MAX_KEYS,
            .mouse_x = 0,
            .mouse_y = 0,
            .physical_mouse_x = 0,
            .physical_mouse_y = 0,
            .mouse_delta_x = 0,
            .mouse_delta_y = 0,
            .physical_mouse_delta_x = 0,
            .physical_mouse_delta_y = 0,
            .mouse_buttons = [_]bool{false} ** 5,
            .physical_mouse_buttons = [_]bool{false} ** 5,
            .mouse_buttons_suppressed = [_]bool{false} ** 5,
            .mouse_buttons_pressed = [_]bool{false} ** 5,
            .mouse_buttons_released = [_]bool{false} ** 5,
            .mouse_wheel_x = 0,
            .mouse_wheel_y = 0,
            .physical_mouse_wheel_x = 0,
            .physical_mouse_wheel_y = 0,
            .keyboard_captured = false,
            .mouse_captured = false,
            .gameplay_reset_requested = false,
            .quit_requested = false,
            .main_window_id = main_window_id,
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
        self.physical_mouse_delta_x = 0;
        self.physical_mouse_delta_y = 0;
        self.physical_mouse_wheel_x = 0;
        self.physical_mouse_wheel_y = 0;

        // Clear per-frame flags
        self.window_resized = false;
        self.gameplay_reset_requested = false;
    }

    /// Process all pending SDL events. Call once per frame.
    /// Returns false if the application should quit.
    pub fn pumpEvents(self: *InputBuffer) bool {
        var event: c.SDL_Event = undefined;

        // Capture can change when the previous ImGui frame is finalized even
        // when there are no new SDL events.
        self.applyCapture(editor.wantsKeyboard(), editor.wantsMouse());

        while (c.SDL_PollEvent(&event)) {
            // ImGui always observes the event. The returned route represents
            // only explicit editor shortcuts, never backend recognition.
            const route = editor.processEvent(&event);
            self.applyCapture(editor.wantsKeyboard(), editor.wantsMouse());

            const keyboard_blocked = self.keyboard_captured or route.keyboard_reserved;
            const mouse_blocked = self.mouse_captured or route.mouse_reserved;

            switch (event.type) {
                // Process lifecycle/window events regardless of editor routing.
                c.SDL_EVENT_QUIT => {
                    self.quit_requested = true;
                },

                c.SDL_EVENT_WINDOW_CLOSE_REQUESTED => {
                    self.handleWindowCloseRequested(event.window.windowID);
                },

                c.SDL_EVENT_KEY_DOWN => {
                    if (!self.isMainWindow(event.key.windowID)) continue;
                    const scancode: usize = @intCast(event.key.scancode);
                    if (scancode < MAX_KEYS) {
                        self.handleKeyDown(scancode, keyboard_blocked);
                    }

                    // Debug: ESC to quit (convenience during development)
                    if (event.key.scancode == c.SDL_SCANCODE_ESCAPE) {
                        self.quit_requested = true;
                    }
                },

                c.SDL_EVENT_KEY_UP => {
                    const scancode: usize = @intCast(event.key.scancode);
                    if (scancode < MAX_KEYS) {
                        self.handleKeyUp(event.key.windowID, scancode);
                    }
                },

                c.SDL_EVENT_MOUSE_MOTION => {
                    if (!self.isMainWindow(event.motion.windowID)) continue;
                    self.handleMouseMotion(
                        event.motion.x,
                        event.motion.y,
                        event.motion.xrel,
                        event.motion.yrel,
                        mouse_blocked,
                    );
                },

                c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
                    if (!self.isMainWindow(event.button.windowID)) continue;
                    const raw_button: usize = @intCast(event.button.button);
                    if (raw_button >= 1 and raw_button <= self.mouse_buttons.len) {
                        self.handleMouseButtonDown(raw_button - 1, mouse_blocked);
                    }
                },

                c.SDL_EVENT_MOUSE_BUTTON_UP => {
                    const raw_button: usize = @intCast(event.button.button);
                    if (raw_button >= 1 and raw_button <= self.mouse_buttons.len) {
                        self.handleMouseButtonUp(event.button.windowID, raw_button - 1);
                    }
                },

                c.SDL_EVENT_MOUSE_WHEEL => {
                    if (self.isMainWindow(event.wheel.windowID)) {
                        self.handleMouseWheel(event.wheel.x, event.wheel.y, mouse_blocked);
                    }
                },

                c.SDL_EVENT_WINDOW_RESIZED => {
                    if (self.isMainWindow(event.window.windowID)) {
                        self.window_resized = true;
                        self.window_width = event.window.data1;
                        self.window_height = event.window.data2;
                    }
                },

                c.SDL_EVENT_WINDOW_FOCUS_LOST => {
                    if (self.isMainWindow(event.window.windowID)) {
                        self.handleFocusLost();
                    }
                },

                else => {},
            }
        }

        return !self.quit_requested;
    }

    /// Apply current ImGui capture state to gameplay input. Entering capture
    /// releases gameplay-held inputs and suppresses their physical holds until
    /// the OS reports a release, preventing them from reappearing mid-hold.
    fn applyCapture(self: *InputBuffer, keyboard: bool, mouse: bool) void {
        if (keyboard and !self.keyboard_captured) {
            self.gameplay_reset_requested = true;
            for (0..MAX_KEYS) |i| {
                if (self.physical_keys_down[i]) {
                    self.keys_suppressed[i] = true;
                }
                if (self.keys_down[i]) {
                    self.keys_down[i] = false;
                    self.keys_pressed[i] = false;
                    self.keys_released[i] = true;
                }
            }
        }
        self.keyboard_captured = keyboard;

        if (mouse and !self.mouse_captured) {
            self.gameplay_reset_requested = true;
            for (0..self.mouse_buttons.len) |i| {
                if (self.physical_mouse_buttons[i]) {
                    self.mouse_buttons_suppressed[i] = true;
                }
                if (self.mouse_buttons[i]) {
                    self.mouse_buttons[i] = false;
                    self.mouse_buttons_pressed[i] = false;
                    self.mouse_buttons_released[i] = true;
                }
            }

            // Motion/wheel accumulated before capture began must not leak into
            // gameplay later in this frame.
            self.mouse_delta_x = 0;
            self.mouse_delta_y = 0;
            self.mouse_wheel_x = 0;
            self.mouse_wheel_y = 0;
        }
        self.mouse_captured = mouse;
    }

    fn handleKeyDown(self: *InputBuffer, scancode: usize, blocked: bool) void {
        const was_physically_down = self.physical_keys_down[scancode];
        if (!was_physically_down) {
            self.keys_suppressed[scancode] = false;
        }
        self.physical_keys_down[scancode] = true;

        if (blocked) {
            self.keys_suppressed[scancode] = true;
            if (self.keys_down[scancode]) {
                self.keys_down[scancode] = false;
                self.keys_pressed[scancode] = false;
                self.keys_released[scancode] = true;
            }
            return;
        }

        if (self.keys_suppressed[scancode]) return;
        if (!self.keys_down[scancode]) {
            self.keys_pressed[scancode] = true;
        }
        self.keys_down[scancode] = true;
    }

    fn handleKeyUp(
        self: *InputBuffer,
        window_id: c.SDL_WindowID,
        scancode: usize,
    ) void {
        if (!self.isMainWindow(window_id)) return;
        self.physical_keys_down[scancode] = false;
        self.keys_suppressed[scancode] = false;
        if (self.keys_down[scancode]) {
            self.keys_released[scancode] = true;
        }
        self.keys_down[scancode] = false;
    }

    fn handleMouseMotion(
        self: *InputBuffer,
        x: f32,
        y: f32,
        delta_x: f32,
        delta_y: f32,
        blocked: bool,
    ) void {
        self.physical_mouse_x = x;
        self.physical_mouse_y = y;
        self.physical_mouse_delta_x += delta_x;
        self.physical_mouse_delta_y += delta_y;

        if (blocked) return;
        self.mouse_x = x;
        self.mouse_y = y;
        self.mouse_delta_x += delta_x;
        self.mouse_delta_y += delta_y;
    }

    fn handleMouseButtonDown(self: *InputBuffer, button: usize, blocked: bool) void {
        const was_physically_down = self.physical_mouse_buttons[button];
        if (!was_physically_down) {
            self.mouse_buttons_suppressed[button] = false;
        }
        self.physical_mouse_buttons[button] = true;

        if (blocked) {
            self.mouse_buttons_suppressed[button] = true;
            if (self.mouse_buttons[button]) {
                self.mouse_buttons[button] = false;
                self.mouse_buttons_pressed[button] = false;
                self.mouse_buttons_released[button] = true;
            }
            return;
        }

        if (self.mouse_buttons_suppressed[button]) return;
        if (!self.mouse_buttons[button]) {
            self.mouse_buttons_pressed[button] = true;
        }
        self.mouse_buttons[button] = true;
    }

    fn handleMouseButtonUp(
        self: *InputBuffer,
        window_id: c.SDL_WindowID,
        button: usize,
    ) void {
        if (!self.isMainWindow(window_id)) return;
        self.physical_mouse_buttons[button] = false;
        self.mouse_buttons_suppressed[button] = false;
        if (self.mouse_buttons[button]) {
            self.mouse_buttons_released[button] = true;
        }
        self.mouse_buttons[button] = false;
    }

    fn handleMouseWheel(self: *InputBuffer, x: f32, y: f32, blocked: bool) void {
        self.physical_mouse_wheel_x += x;
        self.physical_mouse_wheel_y += y;
        if (blocked) return;
        self.mouse_wheel_x += x;
        self.mouse_wheel_y += y;
    }

    /// Focus loss is an authoritative physical release boundary. Gameplay gets
    /// release edges for every active key/button and no stale input survives.
    fn handleFocusLost(self: *InputBuffer) void {
        self.gameplay_reset_requested = true;
        @memset(&self.keys_pressed, false);
        for (0..MAX_KEYS) |i| {
            if (self.keys_down[i]) {
                self.keys_released[i] = true;
            }
        }
        @memset(&self.keys_down, false);
        @memset(&self.physical_keys_down, false);
        @memset(&self.keys_suppressed, false);

        @memset(&self.mouse_buttons_pressed, false);
        for (0..self.mouse_buttons.len) |i| {
            if (self.mouse_buttons[i]) {
                self.mouse_buttons_released[i] = true;
            }
        }
        @memset(&self.mouse_buttons, false);
        @memset(&self.physical_mouse_buttons, false);
        @memset(&self.mouse_buttons_suppressed, false);

        self.mouse_delta_x = 0;
        self.mouse_delta_y = 0;
        self.mouse_wheel_x = 0;
        self.mouse_wheel_y = 0;
        self.physical_mouse_delta_x = 0;
        self.physical_mouse_delta_y = 0;
        self.physical_mouse_wheel_x = 0;
        self.physical_mouse_wheel_y = 0;
    }

    fn handleWindowCloseRequested(self: *InputBuffer, window_id: c.SDL_WindowID) void {
        if (self.isMainWindow(window_id)) {
            self.quit_requested = true;
        }
    }

    fn isMainWindow(self: *const InputBuffer, window_id: c.SDL_WindowID) bool {
        return window_id == self.main_window_id;
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

    pub fn gameplayActionsMustReset(self: *const InputBuffer) bool {
        return self.gameplay_reset_requested;
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
    const input = InputBuffer.init(1);
    try std.testing.expect(!input.quit_requested);
    try std.testing.expect(input.mouse_x == 0);
    try std.testing.expect(!input.keyboard_captured);
    try std.testing.expect(!input.mouse_captured);
}

test "physical key release is observed during keyboard capture" {
    var input = InputBuffer.init(1);
    const key: usize = @intCast(Key.W);

    input.handleKeyDown(key, false);
    input.beginFrame();
    input.applyCapture(true, false);

    try std.testing.expect(input.physical_keys_down[key]);
    try std.testing.expect(!input.isKeyDown(Key.W));
    try std.testing.expect(input.isKeyReleased(Key.W));
    try std.testing.expect(input.keys_suppressed[key]);

    input.handleKeyUp(1, key);
    try std.testing.expect(!input.physical_keys_down[key]);
    try std.testing.expect(!input.keys_suppressed[key]);
    try std.testing.expect(!input.isKeyDown(Key.W));
}

test "focus loss releases and clears keyboard and mouse state" {
    var input = InputBuffer.init(1);
    const key: usize = @intCast(Key.W);
    const button: usize = MouseButton.RIGHT;

    input.handleKeyDown(key, false);
    input.handleMouseButtonDown(button, false);
    input.beginFrame();
    input.handleMouseMotion(10, 20, 3, -2, false);
    input.handleMouseWheel(1, -1, false);
    input.handleFocusLost();

    try std.testing.expect(input.gameplayActionsMustReset());
    try std.testing.expect(input.isKeyReleased(Key.W));
    try std.testing.expect(input.mouse_buttons_released[button]);
    try std.testing.expect(!input.physical_keys_down[key]);
    try std.testing.expect(!input.isKeyDown(Key.W));
    try std.testing.expect(!input.physical_mouse_buttons[button]);
    try std.testing.expect(!input.isMouseButtonDown(MouseButton.RIGHT));
    try std.testing.expectEqual(@as(f32, 0), input.mouse_delta_x);
    try std.testing.expectEqual(@as(f32, 0), input.physical_mouse_delta_x);
    try std.testing.expectEqual(@as(f32, 0), input.mouse_wheel_x);
    try std.testing.expectEqual(@as(f32, 0), input.physical_mouse_wheel_x);
}

test "held input stays suppressed after capture ends until physical release" {
    var input = InputBuffer.init(1);
    const key: usize = @intCast(Key.W);

    input.handleKeyDown(key, false);
    input.beginFrame();
    input.applyCapture(true, false);
    try std.testing.expect(input.gameplayActionsMustReset());
    input.beginFrame();
    try std.testing.expect(!input.gameplayActionsMustReset());
    input.applyCapture(false, false);

    // A repeated key-down while the physical key remains held must not revive
    // gameplay input after capture ends.
    input.handleKeyDown(key, false);
    try std.testing.expect(input.physical_keys_down[key]);
    try std.testing.expect(!input.isKeyDown(Key.W));
    try std.testing.expect(!input.isKeyPressed(Key.W));

    input.handleKeyUp(1, key);
    input.handleKeyDown(key, false);
    try std.testing.expect(input.isKeyDown(Key.W));
    try std.testing.expect(input.isKeyPressed(Key.W));
}

test "held mouse button stays suppressed across mouse capture" {
    var input = InputBuffer.init(1);
    const button: usize = MouseButton.RIGHT;

    input.handleMouseButtonDown(button, false);
    input.beginFrame();
    input.applyCapture(false, true);

    try std.testing.expect(input.physical_mouse_buttons[button]);
    try std.testing.expect(!input.isMouseButtonDown(MouseButton.RIGHT));
    try std.testing.expect(input.mouse_buttons_released[button]);

    input.beginFrame();
    input.applyCapture(false, false);
    input.handleMouseButtonDown(button, false);
    try std.testing.expect(!input.isMouseButtonDown(MouseButton.RIGHT));

    input.handleMouseButtonUp(1, button);
    input.handleMouseButtonDown(button, false);
    try std.testing.expect(input.isMouseButtonDown(MouseButton.RIGHT));
    try std.testing.expect(input.isMouseButtonPressed(MouseButton.RIGHT));
}

test "disabled editor reserves and captures no input" {
    const disabled_editor = @import("editor/disabled.zig");
    const route = disabled_editor.processEvent(null);

    try std.testing.expect(!route.keyboard_reserved);
    try std.testing.expect(!route.mouse_reserved);
    try std.testing.expect(!disabled_editor.wantsKeyboard());
    try std.testing.expect(!disabled_editor.wantsMouse());
}

test "only the main window close request quits the application" {
    var input = InputBuffer.init(42);

    input.handleWindowCloseRequested(99);
    try std.testing.expect(!input.quit_requested);

    input.handleWindowCloseRequested(42);
    try std.testing.expect(input.quit_requested);
}

test "secondary window events are not gameplay window events" {
    const input = InputBuffer.init(42);
    try std.testing.expect(input.isMainWindow(42));
    try std.testing.expect(!input.isMainWindow(99));
}

test "secondary window key release preserves main window hold" {
    var input = InputBuffer.init(42);
    const key: usize = @intCast(Key.W);

    input.handleKeyDown(key, false);
    input.beginFrame();
    input.handleKeyUp(99, key);

    try std.testing.expect(input.physical_keys_down[key]);
    try std.testing.expect(input.isKeyDown(Key.W));
    try std.testing.expect(!input.isKeyReleased(Key.W));

    input.handleKeyUp(42, key);
    try std.testing.expect(!input.physical_keys_down[key]);
    try std.testing.expect(!input.isKeyDown(Key.W));
    try std.testing.expect(input.isKeyReleased(Key.W));
}

test "secondary window mouse release preserves main window hold" {
    var input = InputBuffer.init(42);
    const button: usize = MouseButton.RIGHT;

    input.handleMouseButtonDown(button, false);
    input.beginFrame();
    input.handleMouseButtonUp(99, button);

    try std.testing.expect(input.physical_mouse_buttons[button]);
    try std.testing.expect(input.isMouseButtonDown(MouseButton.RIGHT));
    try std.testing.expect(!input.mouse_buttons_released[button]);

    input.handleMouseButtonUp(42, button);
    try std.testing.expect(!input.physical_mouse_buttons[button]);
    try std.testing.expect(!input.isMouseButtonDown(MouseButton.RIGHT));
    try std.testing.expect(input.mouse_buttons_released[button]);
}
