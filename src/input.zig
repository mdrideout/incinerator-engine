//! input.zig - Input buffering for the canonical game loop
//!
//! This module handles SDL3 event processing and provides a buffered input state
//! that the simulation can consume at its fixed tick rate.
//!
//! Key concepts:
//! - Input is polled every frame (uncapped) to ensure responsiveness
//! - Physical state is independent from capture-filtered gameplay state
//! - Edges and deltas are accumulated until the fixed-tick consumer accepts them

const std = @import("std");
const sdl = @import("sdl.zig");

// Use shared SDL bindings to avoid opaque type conflicts
const c = sdl.c;
pub const sdl_c = c;

pub const EventRoute = struct {
    keyboard_reserved: bool = false,
    mouse_reserved: bool = false,
};

pub const Capture = struct {
    keyboard: bool = false,
    mouse: bool = false,
};

/// Narrow callback surface from the platform input pump to an owned optional
/// editor. The context is borrowed for one pump call and is never retained.
pub const EventSink = struct {
    context: *anyopaque,
    process_event: *const fn (*anyopaque, *const c.SDL_Event) EventRoute,
    capture: *const fn (*anyopaque) Capture,

    fn processEvent(self: EventSink, event: *const c.SDL_Event) EventRoute {
        return self.process_event(self.context, event);
    }

    fn currentCapture(self: EventSink) Capture {
        return self.capture(self.context);
    }
};

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

    /// Physical state is maintained independently from gameplay routing.
    physical_keys_down: [MAX_KEYS]bool,

    /// A captured/reserved held key stays suppressed until its physical release.
    keys_suppressed: [MAX_KEYS]bool,

    // ========================================================================
    // Mouse State
    // ========================================================================

    /// Capture-filtered mouse movement accumulated during the current frame.
    mouse_delta_x: f32,
    mouse_delta_y: f32,

    /// Mouse button state (SDL supports up to 5 buttons)
    mouse_buttons: [5]bool,

    /// Capture-filtered button-down edges observed during this frame.
    mouse_buttons_pressed: [5]bool,

    /// Physical mouse button state, independent from gameplay routing.
    physical_mouse_buttons: [5]bool,

    /// Captured/reserved buttons remain suppressed until physical release.
    mouse_buttons_suppressed: [5]bool,

    /// Capture state applied to gameplay input.
    keyboard_captured: bool,
    mouse_captured: bool,

    /// The normal product may lock the main-window pointer for continuous
    /// relative look. This is distinct from editor mouse capture: while
    /// locked, gameplay owns relative motion and ImGui receives no mouse
    /// input. The first playable-area click is consumed by the transition.
    gameplay_mouse_window: ?*c.SDL_Window,
    gameplay_mouse_locked: bool,
    gameplay_mouse_ignore_motion: bool,
    gameplay_mouse_lock_failures: u64,

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

    /// Stable visibility state for the main window.
    window_minimized: bool,

    /// Main-window minimize/restore events observed during this frame.
    window_minimized_this_frame: bool,
    window_restored_this_frame: bool,

    /// Initialize with all inputs cleared
    pub fn init(main_window_id: c.SDL_WindowID) InputBuffer {
        return InputBuffer{
            .keys_down = [_]bool{false} ** MAX_KEYS,
            .keys_pressed = [_]bool{false} ** MAX_KEYS,
            .physical_keys_down = [_]bool{false} ** MAX_KEYS,
            .keys_suppressed = [_]bool{false} ** MAX_KEYS,
            .mouse_delta_x = 0,
            .mouse_delta_y = 0,
            .mouse_buttons = [_]bool{false} ** 5,
            .mouse_buttons_pressed = [_]bool{false} ** 5,
            .physical_mouse_buttons = [_]bool{false} ** 5,
            .mouse_buttons_suppressed = [_]bool{false} ** 5,
            .keyboard_captured = false,
            .mouse_captured = false,
            .gameplay_mouse_window = null,
            .gameplay_mouse_locked = false,
            .gameplay_mouse_ignore_motion = false,
            .gameplay_mouse_lock_failures = 0,
            .gameplay_reset_requested = false,
            .quit_requested = false,
            .main_window_id = main_window_id,
            .window_minimized = false,
            .window_minimized_this_frame = false,
            .window_restored_this_frame = false,
        };
    }

    /// Bind relative mouse mode to the same SDL window that owns this input
    /// buffer. Tests and cold input consumers can leave the binding absent.
    pub fn attachGameplayMouseWindow(
        self: *InputBuffer,
        window: *c.SDL_Window,
    ) !void {
        if (c.SDL_GetWindowID(window) != self.main_window_id) {
            return error.GameplayMouseWindowMismatch;
        }
        self.gameplay_mouse_window = window;
    }

    pub fn gameplayMouseLocked(self: *const InputBuffer) bool {
        return self.gameplay_mouse_locked;
    }

    pub fn gameplayMouseLockFailures(self: *const InputBuffer) u64 {
        return self.gameplay_mouse_lock_failures;
    }

    /// Release before destroying the SDL window. This is also used for focus
    /// loss, minimization, and Escape while captured.
    pub fn releaseGameplayMouse(self: *InputBuffer) void {
        if (!self.gameplay_mouse_locked) return;
        if (self.gameplay_mouse_window) |window| {
            if (!c.SDL_SetWindowRelativeMouseMode(window, false)) {
                self.gameplay_mouse_lock_failures +|= 1;
                std.debug.print(
                    "Gameplay mouse release failed: {s}\n",
                    .{c.SDL_GetError()},
                );
                return;
            }
        }
        self.setGameplayMouseLocked(false);
    }

    pub fn detachGameplayMouseWindow(self: *InputBuffer) void {
        self.releaseGameplayMouse();
        self.gameplay_mouse_window = null;
    }

    /// Clear per-frame pressed edges, motion deltas, and lifecycle flags.
    /// Call this at the start of each frame before pumping events.
    pub fn beginFrame(self: *InputBuffer) void {
        // Clear "just pressed" flags.
        @memset(&self.keys_pressed, false);
        @memset(&self.mouse_buttons_pressed, false);

        // Clear accumulated deltas
        self.mouse_delta_x = 0;
        self.mouse_delta_y = 0;

        // Clear per-frame flags
        self.window_minimized_this_frame = false;
        self.window_restored_this_frame = false;
        self.gameplay_reset_requested = false;
        self.gameplay_mouse_ignore_motion = false;
    }

    /// Process all pending SDL events. Call once per frame.
    /// Returns false if the application should quit.
    /// The caller supplies a one-call event sink borrowed from its owned editor.
    pub fn pumpEvents(self: *InputBuffer, editor_sink: EventSink) bool {
        var event: c.SDL_Event = undefined;

        // Capture can change when the previous ImGui frame is finalized even
        // when there are no new SDL events.
        const initial_capture = editor_sink.currentCapture();
        self.applyCapture(
            initial_capture.keyboard,
            initial_capture.mouse and !self.gameplay_mouse_locked,
        );

        while (c.SDL_PollEvent(&event)) {
            // ImGui always observes the event. The returned route represents
            // only explicit editor shortcuts, never backend recognition.
            const route = editor_sink.processEvent(&event);
            const current_capture = editor_sink.currentCapture();
            self.applyCapture(
                current_capture.keyboard,
                current_capture.mouse and !self.gameplay_mouse_locked,
            );

            const keyboard_blocked = self.keyboard_captured or route.keyboard_reserved;
            const mouse_blocked = self.mouse_captured or route.mouse_reserved;

            switch (event.type) {
                // Process lifecycle/window events regardless of editor routing.
                c.SDL_EVENT_QUIT => {
                    self.quit_requested = true;
                },

                c.SDL_EVENT_WINDOW_CLOSE_REQUESTED => {
                    if (self.isMainWindow(event.window.windowID)) {
                        self.releaseGameplayMouse();
                    }
                    self.handleWindowCloseRequested(event.window.windowID);
                },

                c.SDL_EVENT_KEY_DOWN => {
                    if (!self.isMainWindow(event.key.windowID)) continue;
                    if (event.key.scancode == c.SDL_SCANCODE_ESCAPE) {
                        if (!event.key.repeat) {
                            if (self.gameplay_mouse_locked) {
                                self.releaseGameplayMouse();
                            } else {
                                self.quit_requested = true;
                            }
                        }
                        continue;
                    }
                    const scancode: usize = @intCast(event.key.scancode);
                    if (scancode < MAX_KEYS) {
                        self.handleKeyDown(scancode, keyboard_blocked);
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
                        event.motion.xrel,
                        event.motion.yrel,
                        mouse_blocked,
                    );
                },

                c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
                    if (!self.isMainWindow(event.button.windowID)) continue;
                    const raw_button: usize = @intCast(event.button.button);
                    if (raw_button >= 1 and raw_button <= self.mouse_buttons.len) {
                        const button = raw_button - 1;
                        if (button == MouseButton.LEFT and
                            !self.gameplay_mouse_locked and !mouse_blocked and
                            self.captureGameplayMouse())
                        {
                            // Acquiring the pointer is a mode transition, not
                            // a handgun shot or held gameplay button.
                            continue;
                        }
                        self.handleMouseButtonDown(button, mouse_blocked);
                    }
                },

                c.SDL_EVENT_MOUSE_BUTTON_UP => {
                    const raw_button: usize = @intCast(event.button.button);
                    if (raw_button >= 1 and raw_button <= self.mouse_buttons.len) {
                        self.handleMouseButtonUp(event.button.windowID, raw_button - 1);
                    }
                },

                c.SDL_EVENT_WINDOW_MINIMIZED => {
                    if (self.isMainWindow(event.window.windowID)) {
                        self.releaseGameplayMouse();
                    }
                    self.handleWindowMinimized(event.window.windowID);
                },

                c.SDL_EVENT_WINDOW_RESTORED => {
                    self.handleWindowRestored(event.window.windowID);
                },

                c.SDL_EVENT_WINDOW_FOCUS_LOST => {
                    if (self.isMainWindow(event.window.windowID)) {
                        self.releaseGameplayMouse();
                        self.handleFocusLost();
                    }
                },

                else => {},
            }
        }

        return !self.quit_requested;
    }

    fn captureGameplayMouse(self: *InputBuffer) bool {
        const window = self.gameplay_mouse_window orelse return false;
        if (!c.SDL_SetWindowRelativeMouseMode(window, true)) {
            self.gameplay_mouse_lock_failures +|= 1;
            std.debug.print(
                "Gameplay mouse capture failed: {s}\n",
                .{c.SDL_GetError()},
            );
            return false;
        }
        self.setGameplayMouseLocked(true);
        return true;
    }

    fn setGameplayMouseLocked(self: *InputBuffer, locked: bool) void {
        self.gameplay_mouse_locked = locked;
        self.gameplay_mouse_ignore_motion = locked;
        self.gameplay_reset_requested = true;
        for (0..self.mouse_buttons.len) |button| {
            if (self.physical_mouse_buttons[button]) {
                self.mouse_buttons_suppressed[button] = true;
            }
            self.mouse_buttons[button] = false;
            self.mouse_buttons_pressed[button] = false;
        }
        self.mouse_delta_x = 0;
        self.mouse_delta_y = 0;
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
                }
            }

            // Motion/wheel accumulated before capture began must not leak into
            // gameplay later in this frame.
            self.mouse_delta_x = 0;
            self.mouse_delta_y = 0;
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
        self.keys_down[scancode] = false;
    }

    fn handleMouseMotion(
        self: *InputBuffer,
        delta_x: f32,
        delta_y: f32,
        blocked: bool,
    ) void {
        if (blocked or self.gameplay_mouse_ignore_motion) return;
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
            }
            return;
        }

        if (self.mouse_buttons_suppressed[button]) return;
        if (!self.mouse_buttons[button]) self.mouse_buttons_pressed[button] = true;
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
        self.mouse_buttons[button] = false;
    }

    /// Focus loss is an authoritative physical release boundary. No stale
    /// gameplay or physical input survives.
    fn handleFocusLost(self: *InputBuffer) void {
        self.gameplay_reset_requested = true;
        @memset(&self.keys_pressed, false);
        @memset(&self.keys_down, false);
        @memset(&self.physical_keys_down, false);
        @memset(&self.keys_suppressed, false);

        @memset(&self.mouse_buttons, false);
        @memset(&self.mouse_buttons_pressed, false);
        @memset(&self.physical_mouse_buttons, false);
        @memset(&self.mouse_buttons_suppressed, false);

        self.mouse_delta_x = 0;
        self.mouse_delta_y = 0;
    }

    fn handleWindowCloseRequested(self: *InputBuffer, window_id: c.SDL_WindowID) void {
        if (self.isMainWindow(window_id)) {
            self.quit_requested = true;
        }
    }

    fn handleWindowMinimized(self: *InputBuffer, window_id: c.SDL_WindowID) void {
        if (!self.isMainWindow(window_id)) return;
        // Minimize is an authoritative gameplay-input release boundary even
        // on window managers that do not also emit a focus-lost event.
        self.handleFocusLost();
        self.window_minimized = true;
        self.window_minimized_this_frame = true;
    }

    fn handleWindowRestored(self: *InputBuffer, window_id: c.SDL_WindowID) void {
        if (!self.isMainWindow(window_id)) return;
        self.window_minimized = false;
        self.window_restored_this_frame = true;
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

    /// Check if a mouse button is currently held (0=left, 1=middle, 2=right)
    pub fn isMouseButtonDown(self: *const InputBuffer, button: u8) bool {
        if (button >= 5) return false;
        return self.mouse_buttons[button];
    }

    pub fn isMouseButtonPressed(self: *const InputBuffer, button: u8) bool {
        if (button >= self.mouse_buttons_pressed.len) return false;
        return self.mouse_buttons_pressed[button];
    }

    pub fn gameplayActionsMustReset(self: *const InputBuffer) bool {
        return self.gameplay_reset_requested;
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
    pub const E = c.SDL_SCANCODE_E;
    pub const F = c.SDL_SCANCODE_F;
    pub const Q = c.SDL_SCANCODE_Q;
    pub const R = c.SDL_SCANCODE_R;
    pub const NUM_1 = c.SDL_SCANCODE_1;
    pub const N = c.SDL_SCANCODE_N;
    pub const SPACE = c.SDL_SCANCODE_SPACE;
    pub const LSHIFT = c.SDL_SCANCODE_LSHIFT;
};

pub const MouseButton = struct {
    pub const LEFT: u8 = 0;
    pub const RIGHT: u8 = 2;
};

// ============================================================================
// Tests
// ============================================================================

test "InputBuffer initialization" {
    const input = InputBuffer.init(1);
    try std.testing.expect(!input.quit_requested);
    try std.testing.expect(!input.keyboard_captured);
    try std.testing.expect(!input.mouse_captured);
    try std.testing.expect(!input.gameplayMouseLocked());
    try std.testing.expectEqual(@as(u64, 0), input.gameplayMouseLockFailures());
    try std.testing.expect(!input.window_minimized);
    try std.testing.expect(!input.window_minimized_this_frame);
    try std.testing.expect(!input.window_restored_this_frame);
}

test "gameplay mouse mode transition consumes held input and releases cleanly" {
    var input = InputBuffer.init(1);
    input.handleMouseButtonDown(MouseButton.LEFT, false);
    input.handleMouseMotion(9, -4, false);

    input.setGameplayMouseLocked(true);
    try std.testing.expect(input.gameplayMouseLocked());
    try std.testing.expect(input.gameplayActionsMustReset());
    try std.testing.expect(!input.isMouseButtonDown(MouseButton.LEFT));
    try std.testing.expect(!input.isMouseButtonPressed(MouseButton.LEFT));
    try std.testing.expectEqual(@as(f32, 0), input.mouse_delta_x);
    try std.testing.expectEqual(@as(f32, 0), input.mouse_delta_y);

    // No SDL window is attached in this pure state test. Release still owns
    // the same state transition used after a successful platform unlock.
    input.releaseGameplayMouse();
    try std.testing.expect(!input.gameplayMouseLocked());
}

test "physical key release is observed during keyboard capture" {
    var input = InputBuffer.init(1);
    const key: usize = @intCast(Key.W);

    input.handleKeyDown(key, false);
    input.beginFrame();
    input.applyCapture(true, false);

    try std.testing.expect(input.physical_keys_down[key]);
    try std.testing.expect(!input.isKeyDown(Key.W));
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
    input.handleMouseMotion(3, -2, false);
    input.handleFocusLost();

    try std.testing.expect(input.gameplayActionsMustReset());
    try std.testing.expect(!input.physical_keys_down[key]);
    try std.testing.expect(!input.isKeyDown(Key.W));
    try std.testing.expect(!input.physical_mouse_buttons[button]);
    try std.testing.expect(!input.isMouseButtonDown(MouseButton.RIGHT));
    try std.testing.expectEqual(@as(f32, 0), input.mouse_delta_x);
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

    input.beginFrame();
    input.applyCapture(false, false);
    input.handleMouseButtonDown(button, false);
    try std.testing.expect(!input.isMouseButtonDown(MouseButton.RIGHT));

    input.handleMouseButtonUp(1, button);
    input.handleMouseButtonDown(button, false);
    try std.testing.expect(input.isMouseButtonDown(MouseButton.RIGHT));
}

test "disabled editor reserves and captures no input" {
    const disabled_editor = @import("editor/disabled.zig");
    var owned_editor = disabled_editor.Editor.init(null, null, null);
    defer owned_editor.deinit();
    const route = owned_editor.processEvent(null);

    try std.testing.expect(!route.keyboard_reserved);
    try std.testing.expect(!route.mouse_reserved);
    try std.testing.expect(!owned_editor.wantsKeyboard());
    try std.testing.expect(!owned_editor.wantsMouse());
}

test "event sink is a borrowed callback surface without retained ownership" {
    const FakeEditor = struct {
        calls: u32 = 0,
        current_capture: Capture = .{ .keyboard = true },

        fn process(
            context: *anyopaque,
            _: *const c.SDL_Event,
        ) EventRoute {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            return .{ .keyboard_reserved = true };
        }

        fn readCapture(context: *anyopaque) Capture {
            const self: *const @This() = @ptrCast(@alignCast(context));
            return self.current_capture;
        }
    };

    var fake = FakeEditor{};
    const sink = EventSink{
        .context = &fake,
        .process_event = FakeEditor.process,
        .capture = FakeEditor.readCapture,
    };
    const event = std.mem.zeroes(c.SDL_Event);
    try std.testing.expect(sink.processEvent(&event).keyboard_reserved);
    try std.testing.expect(sink.currentCapture().keyboard);
    try std.testing.expectEqual(@as(u32, 1), fake.calls);
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

test "main window minimize and restore update stable and frame state" {
    var input = InputBuffer.init(42);

    input.handleWindowMinimized(42);
    try std.testing.expect(input.window_minimized);
    try std.testing.expect(input.window_minimized_this_frame);
    try std.testing.expect(!input.window_restored_this_frame);

    input.handleWindowRestored(42);
    try std.testing.expect(!input.window_minimized);
    try std.testing.expect(input.window_minimized_this_frame);
    try std.testing.expect(input.window_restored_this_frame);
}

test "main window minimize releases held gameplay input without focus event" {
    var input = InputBuffer.init(42);
    const key: usize = @intCast(Key.W);
    const button: usize = MouseButton.RIGHT;

    input.handleKeyDown(key, false);
    input.handleMouseButtonDown(button, false);
    input.beginFrame();
    input.handleWindowMinimized(42);

    try std.testing.expect(input.gameplayActionsMustReset());
    try std.testing.expect(!input.physical_keys_down[key]);
    try std.testing.expect(!input.isKeyDown(Key.W));
    try std.testing.expect(!input.physical_mouse_buttons[button]);
    try std.testing.expect(!input.isMouseButtonDown(MouseButton.RIGHT));
}

test "window lifecycle frame flags clear without clearing stable state" {
    var input = InputBuffer.init(42);

    input.handleWindowMinimized(42);
    input.beginFrame();
    try std.testing.expect(input.window_minimized);
    try std.testing.expect(!input.window_minimized_this_frame);
    try std.testing.expect(!input.window_restored_this_frame);

    input.handleWindowRestored(42);
    input.beginFrame();
    try std.testing.expect(!input.window_minimized);
    try std.testing.expect(!input.window_minimized_this_frame);
    try std.testing.expect(!input.window_restored_this_frame);
}

test "secondary window minimize and restore do not affect main window state" {
    var input = InputBuffer.init(42);

    input.handleWindowMinimized(42);
    input.beginFrame();
    input.handleWindowRestored(99);

    try std.testing.expect(input.window_minimized);
    try std.testing.expect(!input.window_minimized_this_frame);
    try std.testing.expect(!input.window_restored_this_frame);

    input.handleWindowRestored(42);
    input.beginFrame();
    input.handleWindowMinimized(99);

    try std.testing.expect(!input.window_minimized);
    try std.testing.expect(!input.window_minimized_this_frame);
    try std.testing.expect(!input.window_restored_this_frame);
}

test "secondary window key release preserves main window hold" {
    var input = InputBuffer.init(42);
    const key: usize = @intCast(Key.W);

    input.handleKeyDown(key, false);
    input.beginFrame();
    input.handleKeyUp(99, key);

    try std.testing.expect(input.physical_keys_down[key]);
    try std.testing.expect(input.isKeyDown(Key.W));

    input.handleKeyUp(42, key);
    try std.testing.expect(!input.physical_keys_down[key]);
    try std.testing.expect(!input.isKeyDown(Key.W));
}

test "secondary window mouse release preserves main window hold" {
    var input = InputBuffer.init(42);
    const button: usize = MouseButton.RIGHT;

    input.handleMouseButtonDown(button, false);
    input.beginFrame();
    input.handleMouseButtonUp(99, button);

    try std.testing.expect(input.physical_mouse_buttons[button]);
    try std.testing.expect(input.isMouseButtonDown(MouseButton.RIGHT));

    input.handleMouseButtonUp(42, button);
    try std.testing.expect(!input.physical_mouse_buttons[button]);
    try std.testing.expect(!input.isMouseButtonDown(MouseButton.RIGHT));
}
