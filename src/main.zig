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
//! - Define simulation feature behavior
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
const build_options = @import("build_options");
const zm = @import("zmath");
const timing = @import("timing.zig");
const input = @import("input.zig");
const renderer = @import("renderer.zig");
const mesh = @import("mesh.zig");
const primitives = @import("primitives.zig");
const crate_visual_resources = @import("crate_visual_resources.zig");
const camera = @import("camera.zig");
const sdl = @import("sdl.zig");
const shader_assets = @import("shader_assets");
const editor = if (build_options.editor_enabled)
    @import("editor/editor.zig")
else
    @import("editor/disabled.zig");
const crate_host = @import("crate_simulation");
const render_tool = if (build_options.editor_enabled)
    @import("editor/tools/render_tool.zig")
else
    struct {
        pub fn setRenderSettings(_: anytype) void {}
    };

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

const VisualSmokeConfig = struct {
    frames: u64 = 480,
    virtual_render_hz: u32 = 240,
};

const ProgramMode = union(enum) {
    normal,
    verify_install,
    visual_smoke: VisualSmokeConfig,
};

const FramePresentation = struct {
    crate_count: usize,
    first_id: ?crate_host.PersistentId,
    first_position: ?[3]f32,
    first_rotation: ?[4]f32,
};

const RenderResult = union(enum) {
    ready: FramePresentation,
    unavailable,
};

const RunSummary = struct {
    attempted_frames: u64 = 0,
    ready_frames: u64 = 0,
    unavailable_frames: u64 = 0,
    crate_presented_frames: u64 = 0,
    position_changed: bool = false,
    rotation_changed: bool = false,
    min_alpha: f32 = 1.0,
    max_alpha: f32 = 0.0,
};

const SmokeExpectation = struct {
    ticks: u64,
    min_alpha: f32,
    max_alpha: f32,
};

fn smokeExpectation(config: VisualSmokeConfig) !SmokeExpectation {
    var accumulator = timing.FixedStepAccumulator.init();
    var result = SmokeExpectation{ .ticks = 0, .min_alpha = 1, .max_alpha = 0 };
    for (0..config.frames) |_| {
        _ = try accumulator.addElapsedSeconds(
            1.0 / @as(f64, @floatFromInt(config.virtual_render_hz)),
        );
        while (accumulator.consumeTick()) result.ticks += 1;
        const alpha = accumulator.alpha();
        result.min_alpha = @min(result.min_alpha, alpha);
        result.max_alpha = @max(result.max_alpha, alpha);
    }
    return result;
}

fn vectorChanged(comptime count: usize, first: [count]f32, current: [count]f32) bool {
    for (first, current) |a, b| {
        if (@abs(a - b) > 0.00001) return true;
    }
    return false;
}

fn parseProgramMode(args: anytype) !ProgramMode {
    var verify_install = false;
    var visual_smoke = false;
    var frames: ?u64 = null;
    var virtual_render_hz: ?u32 = null;

    for (args[1..args.len]) |raw_arg| {
        const arg: []const u8 = raw_arg;
        if (std.mem.eql(u8, arg, "--verify-install")) {
            if (verify_install) return error.DuplicateArgument;
            verify_install = true;
        } else if (std.mem.eql(u8, arg, "--visual-smoke")) {
            if (visual_smoke) return error.DuplicateArgument;
            visual_smoke = true;
        } else if (std.mem.startsWith(u8, arg, "--frames=")) {
            if (frames != null) return error.DuplicateArgument;
            const value = arg["--frames=".len..];
            frames = std.fmt.parseUnsigned(u64, value, 10) catch
                return error.InvalidFrameCount;
            if (frames.? == 0) return error.InvalidFrameCount;
        } else if (std.mem.startsWith(u8, arg, "--virtual-render-hz=")) {
            if (virtual_render_hz != null) return error.DuplicateArgument;
            const value = arg["--virtual-render-hz=".len..];
            virtual_render_hz = std.fmt.parseUnsigned(u32, value, 10) catch
                return error.InvalidVirtualRenderRate;
            if (virtual_render_hz.? == 0 or virtual_render_hz.? > 10_000) {
                return error.InvalidVirtualRenderRate;
            }
        } else {
            return error.UnknownArgument;
        }
    }

    if (verify_install) {
        if (visual_smoke or frames != null or virtual_render_hz != null) {
            return error.ConflictingProgramModes;
        }
        return .verify_install;
    }
    if (!visual_smoke and (frames != null or virtual_render_hz != null)) {
        return error.VisualSmokeOptionWithoutMode;
    }
    if (!visual_smoke) return .normal;

    const config = VisualSmokeConfig{
        .frames = frames orelse 480,
        .virtual_render_hz = virtual_render_hz orelse 240,
    };
    const scaled = std.math.mul(u64, config.frames, 4) catch
        return error.InvalidFrameCount;
    _ = std.math.add(u64, scaled, 120) catch return error.InvalidFrameCount;
    return .{ .visual_smoke = config };
}

// ============================================================================
// Application State
// ============================================================================

const App = struct {
    window: *c.SDL_Window,
    gpu_renderer: renderer.Renderer,
    frame_timer: timing.FrameTimer,
    input_buffer: input.InputBuffer,

    simulation: crate_host.Simulation,
    initial_crate_id: ?crate_host.PersistentId,
    game_camera: camera.Camera,

    // Presentation resources remain owned by the visual host.
    ground_mesh: mesh.Mesh,
    crate_visuals: crate_visual_resources.CrateVisualResources,

    // Debug counters
    debug_frame_counter: u32,

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

        const main_window_id = c.SDL_GetWindowID(window);
        if (main_window_id == 0) {
            std.debug.print("SDL_GetWindowID failed: {s}\n", .{c.SDL_GetError()});
            return error.SDLWindowIdFailed;
        }

        // Create GPU renderer
        var gpu_renderer = try renderer.Renderer.init(window);
        errdefer gpu_renderer.deinit();

        // Create ground plane mesh
        var ground_mesh = try primitives.createGroundPlane(gpu_renderer.getDevice());
        errdefer ground_mesh.deinit();

        // S0 visual resources are owned by a one-slot typed resource table.
        var crate_visuals = try crate_visual_resources.CrateVisualResources.init(
            gpu_renderer.getDevice(),
        );
        errdefer crate_visuals.deinit();

        // The visual and headless hosts use the same owned S0 composition.
        var simulation = try crate_host.Simulation.init(std.heap.page_allocator, .{
            .namespace = 1,
            .fixed_delta_seconds = @floatCast(timing.TICK_DURATION),
            .assets = .{
                .mesh = crate_visual_resources.mesh_handle,
                .material = crate_visual_resources.material_handle,
            },
            .create_ground = true,
        });
        errdefer simulation.deinit();
        try simulation.submit(.{ .spawn = .{
            .request_id = 1,
            .pose = .{ .position = .{ 0, 12, 0 } },
            .velocity = .{ .angular = .{ 0.2, 0.35, 0.1 } },
        } });

        // Initialize editor (ImGui debug UI)
        // This sets up ImGui with our SDL3 GPU device
        editor.init(
            window,
            gpu_renderer.getDevice(),
            gpu_renderer.getSwapchainFormat(),
        );

        std.debug.print("===========================================\n", .{});
        std.debug.print(" Incinerator Engine initialized (owned S0 simulation)\n", .{});
        std.debug.print(" Window: {d}x{d}\n", .{ INITIAL_WINDOW_WIDTH, INITIAL_WINDOW_HEIGHT });
        std.debug.print(" Tick rate: {d} Hz ({d:.3} ms)\n", .{ timing.TICK_RATE, timing.TICK_DURATION * 1000.0 });
        std.debug.print("===========================================\n", .{});
        std.debug.print(" Controls:\n", .{});
        std.debug.print("   ESC - Quit\n", .{});
        std.debug.print("   Right-click + WASD - Move camera\n", .{});
        std.debug.print("   Right-click + drag - Look around\n", .{});
        std.debug.print("   Q/E - Move down/up\n", .{});
        std.debug.print("   SPACE - Print camera position\n", .{});
        std.debug.print("   F1 - Toggle editor UI\n", .{});
        std.debug.print("   F2 - Toggle ImGui demo\n", .{});
        std.debug.print("===========================================\n\n", .{});

        return App{
            .window = window,
            .gpu_renderer = gpu_renderer,
            .frame_timer = timing.FrameTimer.init(),
            .input_buffer = input.InputBuffer.init(main_window_id),
            .simulation = simulation,
            .initial_crate_id = null,
            .ground_mesh = ground_mesh,
            .crate_visuals = crate_visuals,
            .game_camera = .{
                .position = .{ -5.18, 4.96, 7.57, 1.0 },
                .yaw = 0.59, // 33.6 degrees
                .pitch = -0.36, // -20.6 degrees
            },
            .debug_frame_counter = 0,
        };
    }

    pub fn deinit(self: *App) void {
        const completed_ticks = self.simulation.tickIndex();

        // Clean up editor first (needs GPU device to still be valid)
        editor.deinit();
        self.simulation.deinit();
        self.ground_mesh.deinit();
        self.crate_visuals.deinit();
        self.gpu_renderer.deinit();
        c.SDL_DestroyWindow(self.window);
        c.SDL_Quit();

        std.debug.print("\n===========================================\n", .{});
        std.debug.print(" Incinerator Engine shutdown\n", .{});
        std.debug.print(" Total frames: {d}\n", .{self.frame_timer.total_frames});
        std.debug.print(" Total simulation ticks: {d}\n", .{completed_ticks});
        std.debug.print("===========================================\n", .{});
    }

    /// Run the main game loop
    pub fn run(self: *App, smoke: ?VisualSmokeConfig) !RunSummary {
        var running = true;
        var summary = RunSummary{};
        var smoke_quit_injected = false;
        var first_presented_position: ?[3]f32 = null;
        var first_presented_rotation: ?[4]f32 = null;
        const smoke_attempt_limit = if (smoke) |config|
            (std.math.mul(u64, config.frames, 4) catch unreachable) + 120
        else
            0;

        while (running) {
            // ================================================================
            // PHASE 1: INPUT PUMP (Per-Frame)
            // ================================================================
            // Clear per-frame input state and poll all SDL events.
            // This runs every frame to ensure responsive input.
            self.input_buffer.beginFrame();
            running = self.input_buffer.pumpEvents();
            if (!running) break;

            // Smoke mode feeds an explicit cadence through the same fixed-step
            // policy; normal execution adapts the SDL performance clock.
            if (smoke) |config| {
                try self.frame_timer.beginFrameWithElapsedSeconds(
                    1.0 / @as(f64, @floatFromInt(config.virtual_render_hz)),
                );
            } else {
                self.frame_timer.beginFrame();
            }

            // ================================================================
            // PHASE 2: SIMULATION TICK (Fixed 120Hz)
            // ================================================================
            // Run simulation at fixed timestep. Multiple ticks may run per frame
            // if we're behind, or zero ticks if we're ahead.
            while (self.frame_timer.shouldTick()) {
                try self.simulateTick();
            }

            // ================================================================
            // PHASE 3: PRESENTATION (Interpolated)
            // ================================================================
            // Render the current state. The alpha value can be used to
            // interpolate between previous and current state for smoothness.
            const alpha = self.frame_timer.alpha();
            const render_result = try self.render(alpha);
            const render_ready = switch (render_result) {
                .ready => true,
                .unavailable => false,
            };
            summary.attempted_frames += 1;
            summary.min_alpha = @min(summary.min_alpha, alpha);
            summary.max_alpha = @max(summary.max_alpha, alpha);
            switch (render_result) {
                .ready => |presentation| {
                    summary.ready_frames += 1;
                    if (presentation.crate_count == 1) {
                        const presented_id = presentation.first_id orelse
                            return error.VisualSmokePresentationInvariant;
                        if (self.initial_crate_id) |spawned_id| {
                            if (!std.meta.eql(spawned_id, presented_id)) {
                                return error.VisualSmokePresentedWrongCrate;
                            }
                        }
                        summary.crate_presented_frames += 1;
                        const position = presentation.first_position orelse
                            return error.VisualSmokePresentationInvariant;
                        const rotation = presentation.first_rotation orelse
                            return error.VisualSmokePresentationInvariant;
                        if (first_presented_position) |first| {
                            summary.position_changed = summary.position_changed or
                                vectorChanged(3, first, position);
                        } else {
                            first_presented_position = position;
                        }
                        if (first_presented_rotation) |first| {
                            summary.rotation_changed = summary.rotation_changed or
                                vectorChanged(4, first, rotation);
                        } else {
                            first_presented_rotation = rotation;
                        }
                    } else if (self.initial_crate_id != null) {
                        return error.VisualSmokeCratePresentationMissing;
                    }
                },
                .unavailable => summary.unavailable_frames += 1,
            }

            if (smoke) |config| {
                if (render_ready) {
                    c.SDL_DelayPrecise(
                        @as(u64, std.time.ns_per_s) / config.virtual_render_hz,
                    );
                }
                if (summary.ready_frames == config.frames and !smoke_quit_injected) {
                    var quit_event = std.mem.zeroes(c.SDL_Event);
                    quit_event.type = c.SDL_EVENT_QUIT;
                    if (!c.SDL_PushEvent(&quit_event)) return error.SDLQuitEventFailed;
                    smoke_quit_injected = true;
                }
                if (summary.attempted_frames >= smoke_attempt_limit and
                    !smoke_quit_injected)
                {
                    return error.VisualSmokeFrameLimit;
                }
            }

            // ================================================================
            // DEBUG OUTPUT
            // ================================================================
            self.debug_frame_counter += 1;
            if (self.debug_frame_counter >= DEBUG_PRINT_INTERVAL) {
                self.debug_frame_counter = 0;
                self.printDebugStats();
            }
        }

        if (smoke != null and !smoke_quit_injected) {
            return error.VisualSmokeInterrupted;
        }
        if (smoke) |config| {
            if (summary.unavailable_frames != 0) return error.VisualSmokeUnavailableFrame;
            if (self.initial_crate_id == null) return error.VisualSmokeSpawnMissing;
            if (summary.crate_presented_frames == 0) {
                return error.VisualSmokeCratePresentationMissing;
            }
            if (!summary.position_changed) return error.VisualSmokePositionDidNotChange;
            if (!summary.rotation_changed) return error.VisualSmokeRotationDidNotChange;
            if (self.simulation.crateCount() != 1 or
                self.simulation.entityCount() != 1 or
                self.simulation.bodyCount() != 2)
            {
                return error.VisualSmokeLifecycleInvariant;
            }
            const expected = try smokeExpectation(config);
            if (self.simulation.tickIndex() != expected.ticks) {
                return error.VisualSmokeTickCountMismatch;
            }
            if (@abs(summary.min_alpha - expected.min_alpha) > 0.00001 or
                @abs(summary.max_alpha - expected.max_alpha) > 0.00001)
            {
                return error.VisualSmokeAlphaMismatch;
            }
        }
        return summary;
    }

    /// Fixed timestep simulation tick
    /// This is where physics, gameplay logic, and AI would run.
    fn simulateTick(self: *App) !void {
        try self.simulation.tick();
        while (self.simulation.pollOutcome()) |outcome| {
            switch (outcome) {
                .spawned => |spawned| {
                    if (spawned.request_id != 1 or self.initial_crate_id != null) {
                        return error.UnexpectedBootstrapOutcome;
                    }
                    self.initial_crate_id = spawned.id;
                },
                else => return error.UnexpectedBootstrapOutcome,
            }
        }

        // Camera movement speed (units per tick at 120Hz)
        const move_speed = self.game_camera.move_speed * @as(f32, @floatCast(timing.TICK_DURATION));

        // ================================================================
        // Camera Controls (Unity-style)
        // ================================================================
        // WASD movement only works while right mouse button is held.
        // This matches Unity/Unreal convention where right-click enables
        // FPS-style camera navigation.

        const right_click_held = self.input_buffer.isMouseButtonDown(input.MouseButton.RIGHT);

        // WASD camera movement (only when right-click held)
        if (right_click_held) {
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
        }

        // Q/E for vertical movement.
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
                self.simulation.tickIndex(),
                self.game_camera.position[0],
                self.game_camera.position[1],
                self.game_camera.position[2],
            });
        }
    }

    /// Render the current frame using SDL3 GPU API
    /// `alpha` is the interpolation factor (0.0 to 1.0) for smooth visuals.
    fn render(self: *App, alpha: f32) !RenderResult {
        // Begin the frame (clears screen)
        switch (try self.gpu_renderer.beginFrame(renderer.Colors.CORNFLOWER_BLUE)) {
            .ready => {},
            .unavailable => {
                // Wait briefly without removing the next event from SDL's
                // queue. This keeps minimized windows responsive without
                // turning the main loop into a busy spin.
                _ = c.SDL_WaitEventTimeout(null, 16);
                return .unavailable;
            },
        }

        // Calculate aspect ratio from window dimensions
        const window_size = self.gpu_renderer.getWindowSize();
        const aspect_ratio = @as(f32, @floatFromInt(window_size.width)) /
            @as(f32, @floatFromInt(window_size.height));

        // Get view-projection matrix from camera
        const view_proj = self.game_camera.getViewProjectionMatrix(aspect_ratio);

        // The ground is a visual-host fixture matching the simulation-owned
        // static body. Feature-owned entities arrive through extraction below.
        self.gpu_renderer.drawMesh(&self.ground_mesh, zm.identity(), view_proj);

        // CrateFeature extraction is immutable plain data. The visual host is
        // the only layer that resolves its typed handles to GPU resources.
        const crate_draws = try self.simulation.presentation(alpha);
        for (crate_draws) |draw| {
            const crate_mesh = try self.crate_visuals.resolve(draw.mesh, draw.material);
            const scale = zm.scaling(
                draw.half_extents[0] * 2,
                draw.half_extents[1] * 2,
                draw.half_extents[2] * 2,
            );
            const rotation = zm.quatToMat(zm.f32x4(
                draw.pose.rotation[0],
                draw.pose.rotation[1],
                draw.pose.rotation[2],
                draw.pose.rotation[3],
            ));
            const translation = zm.translation(
                draw.pose.position[0],
                draw.pose.position[1],
                draw.pose.position[2],
            );
            const model_matrix = zm.mul(zm.mul(scale, rotation), translation);
            self.gpu_renderer.drawMesh(crate_mesh, model_matrix, view_proj);
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
            &self.frame_timer,
        );

        // Submit the frame (both scene and editor render passes)
        try self.gpu_renderer.submitFrame();
        return .{ .ready = .{
            .crate_count = crate_draws.len,
            .first_id = if (crate_draws.len > 0) crate_draws[0].persistent_id else null,
            .first_position = if (crate_draws.len > 0) crate_draws[0].pose.position else null,
            .first_rotation = if (crate_draws.len > 0) crate_draws[0].pose.rotation else null,
        } };
    }

    /// Print debug statistics
    fn printDebugStats(self: *App) void {
        std.debug.print("FPS: {d:.1} | Frame time: {d:.2}ms | Sim ticks: {d} | Ticks/frame: {d}\n", .{
            self.frame_timer.getFps(),
            self.frame_timer.getDeltaTime() * 1000.0,
            self.simulation.tickIndex(),
            self.frame_timer.ticks_this_frame,
        });
    }
};

// ============================================================================
// Entry Point
// ============================================================================

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const mode = try parseProgramMode(args);
    if (mode == .verify_install) {
        std.debug.print(
            "Incinerator install verified (shader format: {s}, GPU driver: {s}, editor: {})\n",
            .{ @tagName(shader_assets.format), shader_assets.driver, build_options.editor_enabled },
        );
        return;
    }

    var app = try App.init();
    var visual_smoke_succeeded = false;
    defer {
        app.deinit();
        if (visual_smoke_succeeded) {
            std.debug.print("S0_VISUAL_SMOKE_SHUTDOWN status=clean\n", .{});
        }
    }

    // Wire up render settings to editor tool
    render_tool.setRenderSettings(&app.gpu_renderer.render_settings);

    switch (mode) {
        .normal => _ = try app.run(null),
        .verify_install => unreachable,
        .visual_smoke => |config| {
            const summary = try app.run(config);
            std.debug.print(
                "S0_VISUAL_SMOKE_RESULT ready_frames={d} unavailable_frames={d} " ++
                    "attempted_frames={d} crate_frames={d} position_changed={} " ++
                    "rotation_changed={} ticks={d} alpha_min={d:.6} alpha_max={d:.6} " ++
                    "virtual_render_hz={d} gpu_driver={s}\n",
                .{
                    summary.ready_frames,
                    summary.unavailable_frames,
                    summary.attempted_frames,
                    summary.crate_presented_frames,
                    summary.position_changed,
                    summary.rotation_changed,
                    app.simulation.tickIndex(),
                    summary.min_alpha,
                    summary.max_alpha,
                    config.virtual_render_hz,
                    shader_assets.driver,
                },
            );
            visual_smoke_succeeded = true;
        },
    }
}

// ============================================================================
// Tests
// ============================================================================

test "app structure exists" {
    // Basic compile-time check that App struct is valid
    _ = App;
}

test "program mode parsing keeps visual smoke explicit and bounded" {
    const normal_args = [_][]const u8{"incinerator"};
    const normal = try parseProgramMode(&normal_args);
    try std.testing.expect(normal == .normal);
    const smoke_args = [_][]const u8{
        "incinerator",
        "--visual-smoke",
        "--frames=160",
        "--virtual-render-hz=80",
    };
    const smoke = try parseProgramMode(&smoke_args);
    try std.testing.expectEqual(@as(u64, 160), smoke.visual_smoke.frames);
    try std.testing.expectEqual(@as(u32, 80), smoke.visual_smoke.virtual_render_hz);
    const above = try smokeExpectation(.{ .frames = 480, .virtual_render_hz = 240 });
    try std.testing.expectEqual(@as(u64, 240), above.ticks);
    try std.testing.expectEqual(@as(f32, 0), above.min_alpha);
    try std.testing.expectEqual(@as(f32, 0.5), above.max_alpha);
    const below = try smokeExpectation(.{ .frames = 160, .virtual_render_hz = 80 });
    try std.testing.expectEqual(@as(u64, 240), below.ticks);
    try std.testing.expectEqual(@as(f32, 0), below.min_alpha);
    try std.testing.expectEqual(@as(f32, 0.5), below.max_alpha);
    try std.testing.expectError(
        error.VisualSmokeOptionWithoutMode,
        parseProgramMode(&[_][]const u8{ "incinerator", "--frames=1" }),
    );
    try std.testing.expectError(
        error.ConflictingProgramModes,
        parseProgramMode(&[_][]const u8{ "incinerator", "--verify-install", "--visual-smoke" }),
    );
    try std.testing.expectError(
        error.InvalidVirtualRenderRate,
        parseProgramMode(&[_][]const u8{ "incinerator", "--visual-smoke", "--virtual-render-hz=0" }),
    );
}

test "all engine module tests are discovered" {
    // Zig 0.16 analyzes declarations lazily. Explicitly reference each module
    // so its test blocks remain part of the engine test contract.
    std.testing.refAllDecls(@import("camera.zig"));
    std.testing.refAllDecls(@import("crate_visual_resources.zig"));
    std.testing.refAllDecls(@import("editor/tool.zig"));
    std.testing.refAllDecls(@import("gltf_loader.zig"));
    std.testing.refAllDecls(@import("input.zig"));
    std.testing.refAllDecls(@import("mesh.zig"));
    std.testing.refAllDecls(@import("renderer.zig"));
    std.testing.refAllDecls(@import("texture.zig"));
    std.testing.refAllDecls(@import("timing.zig"));
}
