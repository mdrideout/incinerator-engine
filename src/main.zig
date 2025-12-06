//! main.zig - Incinerator Engine Entry Point
//!
//! DOMAIN: Application Layer (top-level orchestration)
//!
//! This module is the entry point and main orchestrator for the engine.
//! It owns the game loop and coordinates between all other systems.
//!
//! Responsibilities:
//! - Application lifecycle (init, run, shutdown)
//! - Game loop orchestration (input → simulation → render)
//! - Owning and wiring together engine systems
//!
//! This module does NOT:
//! - Contain game-specific logic (future: that's game.zig)
//! - Perform low-level rendering (that's renderer.zig)
//! - Define assets or entities (that's primitives.zig, ecs.zig)
//!
//! The Canonical Game Loop:
//!
//! ┌─────────────────────────────────────────────────────────────┐
//! │ Phase 1: INPUT PUMP (Per-Frame / Uncapped)                  │
//! │ - Drains OS events, latches actions to the Input Buffer     │
//! ├─────────────────────────────────────────────────────────────┤
//! │ Phase 2: SIMULATION TICK (Fixed 120Hz)                      │
//! │ - Physics, gameplay logic, consume buffered input           │
//! ├─────────────────────────────────────────────────────────────┤
//! │ Phase 3: PRESENTATION (Interpolated)                        │
//! │ - Renders visual state via SDL3 GPU API                     │
//! └─────────────────────────────────────────────────────────────┘

const std = @import("std");
const zm = @import("zmath");
const timing = @import("timing.zig");
const input = @import("input.zig");
const renderer = @import("renderer.zig");
const mesh = @import("mesh.zig");
const primitives = @import("primitives.zig");
const ecs = @import("ecs.zig");
const camera = @import("camera.zig");
const sdl = @import("sdl.zig");
const gltf_loader = @import("gltf_loader.zig");
const editor = @import("editor/editor.zig");

// Use shared SDL bindings to avoid opaque type conflicts
const c = sdl.c;

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
    gpu_renderer: renderer.Renderer,
    frame_timer: timing.FrameTimer,
    input_buffer: input.InputBuffer,
    allocator: std.mem.Allocator, // For GLB loading

    // Scene - now using ECS!
    game_world: ecs.GameWorld,
    game_camera: camera.Camera, // Player camera

    // Owned mesh/model data (entities reference these, ECS doesn't own the data)
    cube_mesh: mesh.Mesh,
    loaded_model_1: ?gltf_loader.LoadedModel,
    loaded_model_2: ?gltf_loader.LoadedModel,

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

        // Create GPU renderer
        var gpu_renderer = try renderer.Renderer.init(window);
        errdefer gpu_renderer.deinit();

        // Create the test cube mesh
        var cube_mesh = try primitives.createCube(gpu_renderer.getDevice());
        errdefer cube_mesh.deinit();

        // Load the GLB models
        const allocator = std.heap.page_allocator;

        // Load first model (blonde-woman.glb)
        var loaded_model_1: ?gltf_loader.LoadedModel = null;
        loaded_model_1 = gltf_loader.loadGlb(
            allocator,
            gpu_renderer.getDevice(),
            "assets/models/blonde-woman.glb",
        ) catch |err| blk: {
            std.debug.print("Warning: Failed to load blonde-woman.glb: {any}\n", .{err});
            break :blk null;
        };

        // Load second model (blonde-woman-hunyuan.glb)
        var loaded_model_2: ?gltf_loader.LoadedModel = null;
        loaded_model_2 = gltf_loader.loadGlb(
            allocator,
            gpu_renderer.getDevice(),
            "assets/models/blonde-woman-hunyuan.glb",
        ) catch |err| blk: {
            std.debug.print("Warning: Failed to load blonde-woman-hunyuan.glb: {any}\n", .{err});
            break :blk null;
        };

        // Create the ECS world (entities spawned in spawnEntities after App construction)
        const game_world = ecs.GameWorld.init();

        // Initialize editor (ImGui debug UI)
        // This sets up ImGui with our SDL3 GPU device
        editor.init(window, gpu_renderer.getDevice());

        std.debug.print("===========================================\n", .{});
        std.debug.print(" Incinerator Engine initialized (ECS)\n", .{});
        std.debug.print(" Window: {d}x{d}\n", .{ INITIAL_WINDOW_WIDTH, INITIAL_WINDOW_HEIGHT });
        std.debug.print(" Tick rate: {d} Hz ({d:.3} ms)\n", .{ timing.TICK_RATE, timing.TICK_DURATION * 1000.0 });
        std.debug.print("===========================================\n", .{});
        std.debug.print(" Controls:\n", .{});
        std.debug.print("   ESC - Quit\n", .{});
        std.debug.print("   WASD - Move camera\n", .{});
        std.debug.print("   Q/E - Move down/up\n", .{});
        std.debug.print("   Right-click + drag - Look around\n", .{});
        std.debug.print("   SPACE - Print camera position\n", .{});
        std.debug.print("   F1 - Toggle editor UI\n", .{});
        std.debug.print("   F2 - Toggle ImGui demo\n", .{});
        std.debug.print("===========================================\n\n", .{});

        return App{
            .window = window,
            .gpu_renderer = gpu_renderer,
            .frame_timer = timing.FrameTimer.init(),
            .input_buffer = input.InputBuffer.init(),
            .allocator = allocator,
            .game_world = game_world,
            .cube_mesh = cube_mesh,
            .loaded_model_1 = loaded_model_1,
            .loaded_model_2 = loaded_model_2,
            .game_camera = camera.Camera.lookingAtOrigin(5.0), // Camera 5 units back (model is bigger)
            .debug_frame_counter = 0,
            .sim_tick_count = 0,
        };
    }

    pub fn deinit(self: *App) void {
        // Clean up editor first (needs GPU device to still be valid)
        editor.deinit();

        // Clean up loaded models if present
        if (self.loaded_model_1) |*model| {
            model.deinit();
        }
        if (self.loaded_model_2) |*model| {
            model.deinit();
        }
        self.game_world.deinit();
        self.cube_mesh.deinit();
        self.gpu_renderer.deinit();
        c.SDL_DestroyWindow(self.window);
        c.SDL_Quit();

        std.debug.print("\n===========================================\n", .{});
        std.debug.print(" Incinerator Engine shutdown\n", .{});
        std.debug.print(" Total frames: {d}\n", .{self.frame_timer.total_frames});
        std.debug.print(" Total simulation ticks: {d}\n", .{self.sim_tick_count});
        std.debug.print("===========================================\n", .{});
    }

    /// Spawn initial entities into the ECS world.
    /// IMPORTANT: Must be called AFTER App construction to ensure mesh pointers
    /// point to stable memory (App's fields, not stack locals).
    pub fn spawnEntities(self: *App) void {
        // Spawn the cube as an ECS entity at the origin
        // Use &self.cube_mesh to get a pointer to the App's owned mesh
        _ = self.game_world.spawnRenderable(
            "Cube",
            .{ .x = 0, .y = 0, .z = 0 },
            .{ .x = 0, .y = 0, .z = 0 },
            .{ .x = 1, .y = 1, .z = 1 },
            &self.cube_mesh,
        );

        // Spawn loaded model meshes as ECS entities
        // The meshes slice is heap-allocated so pointers into it are stable
        if (self.loaded_model_1) |*loaded| {
            for (loaded.meshes) |*m| {
                _ = self.game_world.spawnRenderable(
                    "Woman1",
                    .{ .x = 2.0, .y = 0, .z = 0 }, // Right of cube
                    .{ .x = std.math.pi / 2.0, .y = 0, .z = 0 }, // Rotate to stand up
                    .{ .x = 1, .y = 1, .z = 1 },
                    m,
                );
            }
        }

        if (self.loaded_model_2) |*loaded| {
            for (loaded.meshes) |*m| {
                _ = self.game_world.spawnRenderable(
                    "Woman2",
                    .{ .x = -2.0, .y = 0, .z = 0 }, // Left of cube
                    .{ .x = std.math.pi / 2.0, .y = 0, .z = 0 }, // Rotate to stand up
                    .{ .x = 1, .y = 1, .z = 1 },
                    m,
                );
            }
        }

        std.debug.print(" Entities spawned: {d}\n", .{self.game_world.entityCount()});
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

        // Camera movement speed (units per tick at 120Hz)
        const move_speed = self.game_camera.move_speed * @as(f32, @floatCast(timing.TICK_DURATION));

        // WASD camera movement
        if (self.input_buffer.isKeyDown(input.Key.W)) {
            self.game_camera.moveForward(move_speed);
        }
        if (self.input_buffer.isKeyDown(input.Key.S)) {
            self.game_camera.moveForward(-move_speed);
        }
        if (self.input_buffer.isKeyDown(input.Key.A)) {
            self.game_camera.moveRight(-move_speed);
        }
        if (self.input_buffer.isKeyDown(input.Key.D)) {
            self.game_camera.moveRight(move_speed);
        }

        // Q/E for vertical movement (up/down)
        if (self.input_buffer.isKeyDown(input.Key.Q)) {
            self.game_camera.moveUp(-move_speed);
        }
        if (self.input_buffer.isKeyDown(input.Key.E)) {
            self.game_camera.moveUp(move_speed);
        }

        // Mouse look (when right mouse button is held)
        if (self.input_buffer.isMouseButtonDown(input.MouseButton.RIGHT)) {
            self.game_camera.rotate(self.input_buffer.mouse_delta_x, self.input_buffer.mouse_delta_y);
        }

        // Debug: Print when space is pressed (single trigger)
        if (self.input_buffer.isKeyPressed(input.Key.SPACE)) {
            std.debug.print("[Tick {d}] Camera pos: ({d:.2}, {d:.2}, {d:.2})\n", .{
                self.sim_tick_count,
                self.game_camera.position[0],
                self.game_camera.position[1],
                self.game_camera.position[2],
            });
        }
    }

    /// Render the current frame using SDL3 GPU API
    /// `alpha` is the interpolation factor (0.0 to 1.0) for smooth visuals.
    fn render(self: *App, alpha: f32) void {
        _ = alpha; // Will use for interpolation when transforms work

        // Begin the frame (clears screen)
        if (!self.gpu_renderer.beginFrame(renderer.Colors.CORNFLOWER_BLUE)) {
            return; // Frame skipped (e.g., window minimized)
        }

        // Calculate aspect ratio from window dimensions
        const window_size = self.gpu_renderer.getWindowSize();
        const aspect_ratio = @as(f32, @floatFromInt(window_size.width)) /
            @as(f32, @floatFromInt(window_size.height));

        // Get view-projection matrix from camera
        const view_proj = self.game_camera.getViewProjectionMatrix(aspect_ratio);

        // Draw all renderable entities from the ECS
        // This is the unified rendering loop - no more special-casing loaded models!
        var iter = self.game_world.renderables();
        defer iter.deinit(); // Finalize flecs iterator
        while (iter.next()) |entity| {
            // Each entity computes its own model matrix from Position/Rotation/Scale
            const model_matrix = entity.getModelMatrix();
            const mvp = zm.mul(model_matrix, view_proj);
            self.gpu_renderer.drawMesh(entity.mesh, mvp);
        }

        // ================================================================
        // End scene render pass BEFORE editor drawing
        // ================================================================
        // ImGui needs to upload vertex data via a copy pass, which can't
        // happen inside a render pass. So we split the frame:
        // 1. End the scene render pass
        // 2. Let editor do its thing (copy pass + its own render pass)
        // 3. Submit everything together
        self.gpu_renderer.endRenderPass();

        // Draw editor overlay (ImGui debug UI)
        // This creates its own render pass with LOAD to preserve the scene
        editor.draw(
            &self.gpu_renderer,
            &self.game_camera,
            &self.game_world,
            &self.frame_timer,
        );

        // Submit the frame (both scene and editor render passes)
        self.gpu_renderer.submitFrame();
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

    // Spawn entities AFTER App is constructed (mesh pointers must be stable)
    app.spawnEntities();

    app.run();
}

// ============================================================================
// Tests
// ============================================================================

test "app structure exists" {
    // Basic compile-time check that App struct is valid
    _ = App;
}
