//! main.zig - Incinerator Engine Entry Point
//!
//! This is the main entry point for the engine. It implements the Canonical Game Loop:
//!
//! ┌─────────────────────────────────────────────────────────────┐
//! │ Phase 1: INPUT PUMP (Per-Frame / Uncapped)                  │
//! │ - Drains OS events, latches actions to the Input Buffer     │
//! ├─────────────────────────────────────────────────────────────┤
//! │ Phase 2: SIMULATION TICK (Fixed 120Hz)                      │
//! │ - Physics, gameplay logic, consume buffered input           │
//! ├─────────────────────────────────────────────────────────────┤
//! │ Phase 3: PRESENTATION (Interpolated)                        │
//! │ - Renders visual state blended between two ticks            │
//! └─────────────────────────────────────────────────────────────┘

const std = @import("std");
const timing = @import("timing.zig");
const input = @import("input.zig");

// SDL3 C bindings
const c = @cImport({
    @cInclude("SDL3/SDL.h");
});

// ============================================================================
// Configuration
// ============================================================================

const WINDOW_TITLE = "Incinerator Engine";
const INITIAL_WINDOW_WIDTH = 1280;
const INITIAL_WINDOW_HEIGHT = 720;

/// How often to print debug stats (in frames)
const DEBUG_PRINT_INTERVAL = 120; // Every ~1 second at 120 FPS

// ============================================================================
// Application State
// ============================================================================

const App = struct {
    window: *c.SDL_Window,
    renderer: *c.SDL_Renderer,
    frame_timer: timing.FrameTimer,
    input_buffer: input.InputBuffer,

    // Debug counters
    debug_frame_counter: u32,

    // Placeholder simulation state (will be replaced with actual game state)
    sim_tick_count: u64,

    pub fn init() !App {
        // Initialize SDL3 with video subsystem
        if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
            std.debug.print("SDL_Init failed: {s}\n", .{c.SDL_GetError()});
            return error.SDLInitFailed;
        }
        errdefer c.SDL_Quit();

        // Create the window
        const window = c.SDL_CreateWindow(
            WINDOW_TITLE,
            INITIAL_WINDOW_WIDTH,
            INITIAL_WINDOW_HEIGHT,
            c.SDL_WINDOW_RESIZABLE,
        ) orelse {
            std.debug.print("SDL_CreateWindow failed: {s}\n", .{c.SDL_GetError()});
            return error.SDLWindowFailed;
        };
        errdefer c.SDL_DestroyWindow(window);

        // Create a renderer (for now we use SDL_Renderer; will switch to SDL_GPU later)
        const renderer = c.SDL_CreateRenderer(window, null) orelse {
            std.debug.print("SDL_CreateRenderer failed: {s}\n", .{c.SDL_GetError()});
            return error.SDLRendererFailed;
        };
        errdefer c.SDL_DestroyRenderer(renderer);

        std.debug.print("===========================================\n", .{});
        std.debug.print(" Incinerator Engine initialized\n", .{});
        std.debug.print(" Window: {d}x{d}\n", .{ INITIAL_WINDOW_WIDTH, INITIAL_WINDOW_HEIGHT });
        std.debug.print(" Tick rate: {d} Hz ({d:.3} ms)\n", .{ timing.TICK_RATE, timing.TICK_DURATION * 1000.0 });
        std.debug.print("===========================================\n", .{});
        std.debug.print(" Controls:\n", .{});
        std.debug.print("   ESC - Quit\n", .{});
        std.debug.print("   WASD - (placeholder) movement\n", .{});
        std.debug.print("===========================================\n\n", .{});

        return App{
            .window = window,
            .renderer = renderer,
            .frame_timer = timing.FrameTimer.init(),
            .input_buffer = input.InputBuffer.init(),
            .debug_frame_counter = 0,
            .sim_tick_count = 0,
        };
    }

    pub fn deinit(self: *App) void {
        c.SDL_DestroyRenderer(self.renderer);
        c.SDL_DestroyWindow(self.window);
        c.SDL_Quit();

        std.debug.print("\n===========================================\n", .{});
        std.debug.print(" Incinerator Engine shutdown\n", .{});
        std.debug.print(" Total frames: {d}\n", .{self.frame_timer.total_frames});
        std.debug.print(" Total simulation ticks: {d}\n", .{self.sim_tick_count});
        std.debug.print("===========================================\n", .{});
    }

    /// Run the main game loop
    pub fn run(self: *App) void {
        var running = true;

        while (running) {
            // ================================================================
            // PHASE 1: INPUT PUMP (Per-Frame)
            // ================================================================
            // Clear per-frame input state and poll all SDL events.
            // This runs every frame to ensure responsive input.
            self.input_buffer.beginFrame();
            running = self.input_buffer.pumpEvents();

            // Begin frame timing (must be after input pump for accurate delta)
            self.frame_timer.beginFrame();

            // ================================================================
            // PHASE 2: SIMULATION TICK (Fixed 120Hz)
            // ================================================================
            // Run simulation at fixed timestep. Multiple ticks may run per frame
            // if we're behind, or zero ticks if we're ahead.
            while (self.frame_timer.shouldTick()) {
                self.simulateTick();
            }

            // ================================================================
            // PHASE 3: PRESENTATION (Interpolated)
            // ================================================================
            // Render the current state. The alpha value can be used to
            // interpolate between previous and current state for smoothness.
            const alpha = self.frame_timer.alpha();
            self.render(alpha);

            // ================================================================
            // DEBUG OUTPUT
            // ================================================================
            self.debug_frame_counter += 1;
            if (self.debug_frame_counter >= DEBUG_PRINT_INTERVAL) {
                self.debug_frame_counter = 0;
                self.printDebugStats();
            }
        }
    }

    /// Fixed timestep simulation tick
    /// This is where physics, gameplay logic, and AI would run.
    fn simulateTick(self: *App) void {
        self.sim_tick_count += 1;

        // Example: Check for WASD input (placeholder for movement)
        if (self.input_buffer.isKeyDown(input.Key.W)) {
            // Would move forward here
        }
        if (self.input_buffer.isKeyDown(input.Key.S)) {
            // Would move backward here
        }
        if (self.input_buffer.isKeyDown(input.Key.A)) {
            // Would strafe left here
        }
        if (self.input_buffer.isKeyDown(input.Key.D)) {
            // Would strafe right here
        }

        // Debug: Print when space is pressed (single trigger)
        if (self.input_buffer.isKeyPressed(input.Key.SPACE)) {
            std.debug.print("[Tick {d}] SPACE pressed!\n", .{self.sim_tick_count});
        }

        // Debug: Print mouse clicks
        if (self.input_buffer.isMouseButtonPressed(input.MouseButton.LEFT)) {
            std.debug.print("[Tick {d}] Left mouse clicked at ({d:.0}, {d:.0})\n", .{
                self.sim_tick_count,
                self.input_buffer.mouse_x,
                self.input_buffer.mouse_y,
            });
        }
    }

    /// Render the current frame
    /// `alpha` is the interpolation factor (0.0 to 1.0) for smooth visuals.
    fn render(self: *App, alpha: f32) void {
        _ = alpha; // Will use for interpolation later

        // Clear to cornflower blue (the classic XNA/DirectX test color)
        _ = c.SDL_SetRenderDrawColor(self.renderer, 100, 149, 237, 255);
        _ = c.SDL_RenderClear(self.renderer);

        // TODO: Render game objects here

        // Present the frame
        _ = c.SDL_RenderPresent(self.renderer);
    }

    /// Print debug statistics
    fn printDebugStats(self: *App) void {
        std.debug.print("FPS: {d:.1} | Frame time: {d:.2}ms | Sim ticks: {d} | Ticks/frame: {d}\n", .{
            self.frame_timer.getFps(),
            self.frame_timer.getDeltaTime() * 1000.0,
            self.sim_tick_count,
            self.frame_timer.ticks_this_frame,
        });
    }
};

// ============================================================================
// Entry Point
// ============================================================================

pub fn main() !void {
    var app = try App.init();
    defer app.deinit();

    app.run();
}

// ============================================================================
// Tests
// ============================================================================

test "app structure exists" {
    // Basic compile-time check that App struct is valid
    _ = App;
}
