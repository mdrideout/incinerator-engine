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
//! - Contain character/crate simulation policy (features own that behavior)
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
const sandbox_visual_resources = @import("sandbox_visual_resources.zig");
const sandbox_controls = @import("sandbox_controls.zig");
const camera = @import("camera.zig");
const sdl = @import("sdl.zig");
const shader_assets = @import("shader_assets");
const editor = if (build_options.editor_enabled)
    @import("editor/editor.zig")
else
    @import("editor/disabled.zig");
const sandbox_host = @import("sandbox_simulation");
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
    s1_visual_smoke: VisualSmokeConfig,
};

const BootstrapProfile = enum { sandbox, s0_smoke };

const sandbox_block = sandbox_host.StaticBox{
    .position = .{ 0, 1, -5 },
    .half_extents = .{ 2, 1, 0.5 },
};

const FramePresentation = struct {
    crate_count: usize,
    first_id: ?sandbox_host.PersistentId,
    first_position: ?[3]f32,
    first_rotation: ?[4]f32,
    character_count: usize,
    character_id: ?sandbox_host.PersistentId,
    character_position: ?[3]f32,
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
    character_presented_frames: u64 = 0,
    character_position_changed: bool = false,
    character_jump_observed: bool = false,
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
    var s1_visual_smoke = false;
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
        } else if (std.mem.eql(u8, arg, "--s1-visual-smoke")) {
            if (s1_visual_smoke) return error.DuplicateArgument;
            s1_visual_smoke = true;
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
        if (visual_smoke or s1_visual_smoke or frames != null or virtual_render_hz != null) {
            return error.ConflictingProgramModes;
        }
        return .verify_install;
    }
    if (visual_smoke and s1_visual_smoke) return error.ConflictingProgramModes;
    if (!visual_smoke and !s1_visual_smoke and
        (frames != null or virtual_render_hz != null))
    {
        return error.VisualSmokeOptionWithoutMode;
    }
    if (!visual_smoke and !s1_visual_smoke) return .normal;

    const config = VisualSmokeConfig{
        .frames = frames orelse 480,
        .virtual_render_hz = virtual_render_hz orelse 240,
    };
    const scaled = std.math.mul(u64, config.frames, 4) catch
        return error.InvalidFrameCount;
    _ = std.math.add(u64, scaled, 120) catch return error.InvalidFrameCount;
    return if (s1_visual_smoke)
        .{ .s1_visual_smoke = config }
    else
        .{ .visual_smoke = config };
}

// ============================================================================
// Application State
// ============================================================================

const App = struct {
    window: *c.SDL_Window,
    gpu_renderer: renderer.Renderer,
    frame_timer: timing.FrameTimer,
    input_buffer: input.InputBuffer,

    simulation: sandbox_host.Simulation,
    initial_crate_id: ?sandbox_host.PersistentId,
    initial_character_id: ?sandbox_host.PersistentId,
    action_latch: sandbox_controls.ActionLatch,
    game_camera: camera.Camera,
    profile: BootstrapProfile,

    // Presentation resources remain owned by the visual host.
    ground_mesh: mesh.Mesh,
    block_mesh: mesh.Mesh,
    visuals: sandbox_visual_resources.SandboxVisualResources,

    // Debug counters
    debug_frame_counter: u32,

    pub fn init(profile: BootstrapProfile) !App {
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

        var block_mesh = try primitives.createCube(gpu_renderer.getDevice());
        errdefer block_mesh.deinit();

        const character_config = sandbox_host.CharacterConfig{
            .assets = .{
                .mesh = sandbox_visual_resources.character_mesh_handle,
                .material = sandbox_visual_resources.character_material_handle,
            },
        };
        var visuals = try sandbox_visual_resources.SandboxVisualResources.init(
            gpu_renderer.getDevice(),
            character_config.radius,
            character_config.half_height,
        );
        errdefer visuals.deinit();

        // The visual and headless hosts use the same owned sandbox composition.
        var simulation = try sandbox_host.Simulation.init(std.heap.page_allocator, .{
            .namespace = 1,
            .fixed_delta_seconds = @floatCast(timing.TICK_DURATION),
            .assets = .{
                .mesh = sandbox_visual_resources.crate_mesh_handle,
                .material = sandbox_visual_resources.crate_material_handle,
            },
            .create_ground = true,
            .character = character_config,
            .block = if (profile == .sandbox) sandbox_block else null,
        });
        errdefer simulation.deinit();
        try simulation.submit(.{ .spawn = .{
            .request_id = 1,
            .pose = .{ .position = .{ 0, 12, 0 } },
            .velocity = .{ .angular = .{ 0.2, 0.35, 0.1 } },
        } });
        if (profile == .sandbox) {
            try simulation.submitCharacter(.{ .spawn = .{
                .request_id = 1,
                .position = .{ 0, 0, 4 },
            } });
        }

        // Initialize editor (ImGui debug UI)
        // This sets up ImGui with our SDL3 GPU device
        editor.init(
            window,
            gpu_renderer.getDevice(),
            gpu_renderer.getSwapchainFormat(),
        );

        std.debug.print("===========================================\n", .{});
        std.debug.print(" Incinerator Engine initialized ({s} composition)\n", .{@tagName(profile)});
        std.debug.print(" Window: {d}x{d}\n", .{ INITIAL_WINDOW_WIDTH, INITIAL_WINDOW_HEIGHT });
        std.debug.print(" Tick rate: {d} Hz ({d:.3} ms)\n", .{ timing.TICK_RATE, timing.TICK_DURATION * 1000.0 });
        std.debug.print("===========================================\n", .{});
        std.debug.print(" Controls:\n", .{});
        std.debug.print("   ESC - Quit\n", .{});
        std.debug.print("   WASD - Move character\n", .{});
        std.debug.print("   SPACE - Jump\n", .{});
        std.debug.print("   Right-click + drag - Turn/look\n", .{});
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
            .initial_character_id = null,
            .action_latch = .{},
            .ground_mesh = ground_mesh,
            .block_mesh = block_mesh,
            .visuals = visuals,
            .game_camera = .{
                .position = .{ 0, 3, 10, 1 },
                .yaw = 0,
                .pitch = -0.25,
            },
            .profile = profile,
            .debug_frame_counter = 0,
        };
    }

    pub fn deinit(self: *App) void {
        const completed_ticks = self.simulation.tickIndex();

        // Clean up editor first (needs GPU device to still be valid)
        editor.deinit();
        self.simulation.deinit();
        self.ground_mesh.deinit();
        self.block_mesh.deinit();
        self.visuals.deinit();
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
    pub fn run(
        self: *App,
        smoke: ?VisualSmokeConfig,
        scripted_character: bool,
    ) !RunSummary {
        var running = true;
        var summary = RunSummary{};
        var smoke_quit_injected = false;
        var first_presented_position: ?[3]f32 = null;
        var first_presented_rotation: ?[4]f32 = null;
        var first_character_position: ?[3]f32 = null;
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
            if (self.profile == .sandbox) try self.captureFrameActions();

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
                try self.simulateTick(scripted_character);
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
                    if (scripted_character and self.initial_character_id != null) {
                        if (presentation.character_count != 1) {
                            return error.S1VisualSmokeCharacterPresentationMissing;
                        }
                        const presented_id = presentation.character_id orelse
                            return error.S1VisualSmokeCharacterPresentationMissing;
                        const spawned_id = self.initial_character_id orelse
                            return error.S1VisualSmokeCharacterSpawnMissing;
                        if (!std.meta.eql(presented_id, spawned_id)) {
                            return error.S1VisualSmokePresentedWrongCharacter;
                        }
                        const position = presentation.character_position orelse
                            return error.S1VisualSmokeCharacterPresentationMissing;
                        summary.character_presented_frames += 1;
                        if (first_character_position) |first| {
                            summary.character_position_changed =
                                summary.character_position_changed or
                                vectorChanged(3, first, position);
                            summary.character_jump_observed =
                                summary.character_jump_observed or
                                position[1] > first[1] + 0.1;
                        } else {
                            first_character_position = position;
                        }
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
            if (scripted_character) {
                if (self.initial_character_id == null) {
                    return error.S1VisualSmokeCharacterSpawnMissing;
                }
                if (summary.character_presented_frames == 0 or
                    !summary.character_position_changed or
                    !summary.character_jump_observed)
                {
                    return error.S1VisualSmokeCharacterDidNotMove;
                }
                if (self.simulation.crateCount() != 1 or
                    self.simulation.characterCount() != 1 or
                    self.simulation.entityCount() != 2 or
                    self.simulation.bodyCount() != 3)
                {
                    return error.S1VisualSmokeLifecycleInvariant;
                }
                const character = try self.simulation.character(self.initial_character_id.?);
                if (character.position[2] < -4.2 or character.position[2] > -3.5) {
                    return error.S1VisualSmokeBlockCollisionFailed;
                }
            } else if (self.simulation.crateCount() != 1 or
                self.simulation.characterCount() != 0 or
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

    fn captureFrameActions(self: *App) !void {
        var move = [2]f32{ 0, 0 };
        if (self.input_buffer.isKeyDown(input.Key.A)) move[0] -= 1;
        if (self.input_buffer.isKeyDown(input.Key.D)) move[0] += 1;
        if (self.input_buffer.isKeyDown(input.Key.S)) move[1] -= 1;
        if (self.input_buffer.isKeyDown(input.Key.W)) move[1] += 1;
        const looking = self.input_buffer.isMouseButtonDown(input.MouseButton.RIGHT);
        try self.action_latch.captureFrame(.{
            .move = move,
            .look_delta = if (looking)
                .{ self.input_buffer.mouse_delta_x, self.input_buffer.mouse_delta_y }
            else
                .{ 0, 0 },
            .jump_pressed = self.input_buffer.isKeyPressed(input.Key.SPACE),
            .reset = self.input_buffer.gameplayActionsMustReset(),
        });
    }

    /// Submit one device-independent action sample before each fixed tick.
    fn simulateTick(self: *App, scripted_character: bool) !void {
        if (self.initial_character_id) |id| {
            const actions = if (scripted_character)
                sandbox_controls.TickSample{
                    .move = .{ 0, 1 },
                    .look_delta = .{ 0, 0 },
                    .jump_pressed = self.simulation.tickIndex() == 60,
                }
            else
                self.action_latch.takeTick();
            self.game_camera.rotate(actions.look_delta[0], actions.look_delta[1]);
            try self.simulation.submitCharacter(.{ .actions = .{
                .id = id,
                .move = actions.move,
                .facing_yaw = self.game_camera.yaw,
                .jump_pressed = actions.jump_pressed,
            } });
        }
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
        while (self.simulation.pollCharacterOutcome()) |outcome| {
            switch (outcome) {
                .spawned => |spawned| {
                    if (spawned.request_id != 1 or self.initial_character_id != null) {
                        return error.UnexpectedCharacterBootstrapOutcome;
                    }
                    self.initial_character_id = spawned.id;
                },
                .rejected, .despawned => return error.UnexpectedCharacterBootstrapOutcome,
            }
        }
        while (self.simulation.pollCharacterEvent()) |_| {}
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

        const character_draws = try self.simulation.characterPresentation(alpha);
        if (self.initial_character_id) |player_id| {
            var player_found = false;
            for (character_draws) |draw| {
                if (std.meta.eql(draw.persistent_id, player_id)) {
                    self.game_camera.followTarget(draw.camera_target, 6.0);
                    player_found = true;
                    break;
                }
            }
            if (!player_found) return error.PlayerPresentationMissing;
        }

        // Get view-projection matrix from camera
        const view_proj = self.game_camera.getViewProjectionMatrix(aspect_ratio);

        // The ground is a visual-host fixture matching the simulation-owned
        // static body. Feature-owned entities arrive through extraction below.
        self.gpu_renderer.drawMesh(&self.ground_mesh, zm.identity(), view_proj);
        if (self.profile == .sandbox) {
            const block_scale = zm.scaling(
                sandbox_block.half_extents[0] * 2,
                sandbox_block.half_extents[1] * 2,
                sandbox_block.half_extents[2] * 2,
            );
            const block_translation = zm.translation(
                sandbox_block.position[0],
                sandbox_block.position[1],
                sandbox_block.position[2],
            );
            self.gpu_renderer.drawMesh(
                &self.block_mesh,
                zm.mul(block_scale, block_translation),
                view_proj,
            );
        }

        // CrateFeature extraction is immutable plain data. The visual host is
        // the only layer that resolves its typed handles to GPU resources.
        const crate_draws = try self.simulation.presentation(alpha);
        for (crate_draws) |draw| {
            const crate_mesh = try self.visuals.resolve(draw.mesh, draw.material);
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

        for (character_draws) |draw| {
            const character_mesh = try self.visuals.resolve(draw.mesh, draw.material);
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
            self.gpu_renderer.drawMesh(
                character_mesh,
                zm.mul(rotation, translation),
                view_proj,
            );
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
            .character_count = character_draws.len,
            .character_id = if (character_draws.len > 0)
                character_draws[0].persistent_id
            else
                null,
            .character_position = if (character_draws.len > 0)
                character_draws[0].pose.position
            else
                null,
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

    const profile: BootstrapProfile = switch (mode) {
        .normal => .sandbox,
        .visual_smoke => .s0_smoke,
        .s1_visual_smoke => .sandbox,
        .verify_install => unreachable,
    };
    var app = try App.init(profile);
    var visual_smoke_succeeded = false;
    var s1_visual_smoke_succeeded = false;
    defer {
        app.deinit();
        if (visual_smoke_succeeded) {
            std.debug.print("S0_VISUAL_SMOKE_SHUTDOWN status=clean\n", .{});
        }
        if (s1_visual_smoke_succeeded) {
            std.debug.print("S1_VISUAL_SMOKE_SHUTDOWN status=clean\n", .{});
        }
    }

    // Wire up render settings to editor tool
    render_tool.setRenderSettings(&app.gpu_renderer.render_settings);

    switch (mode) {
        .normal => _ = try app.run(null, false),
        .verify_install => unreachable,
        .visual_smoke => |config| {
            const summary = try app.run(config, false);
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
        .s1_visual_smoke => |config| {
            const summary = try app.run(config, true);
            std.debug.print(
                "S1_VISUAL_SMOKE_RESULT ready_frames={d} unavailable_frames={d} " ++
                    "attempted_frames={d} character_frames={d} character_moved={} " ++
                    "jump_observed={} " ++
                    "ticks={d} alpha_min={d:.6} alpha_max={d:.6} " ++
                    "virtual_render_hz={d} gpu_driver={s}\n",
                .{
                    summary.ready_frames,
                    summary.unavailable_frames,
                    summary.attempted_frames,
                    summary.character_presented_frames,
                    summary.character_position_changed,
                    summary.character_jump_observed,
                    app.simulation.tickIndex(),
                    summary.min_alpha,
                    summary.max_alpha,
                    config.virtual_render_hz,
                    shader_assets.driver,
                },
            );
            s1_visual_smoke_succeeded = true;
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
    const s1_smoke = try parseProgramMode(&[_][]const u8{
        "incinerator",
        "--s1-visual-smoke",
        "--frames=240",
        "--virtual-render-hz=120",
    });
    try std.testing.expectEqual(@as(u64, 240), s1_smoke.s1_visual_smoke.frames);
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
        error.ConflictingProgramModes,
        parseProgramMode(&[_][]const u8{
            "incinerator",
            "--visual-smoke",
            "--s1-visual-smoke",
        }),
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
    std.testing.refAllDecls(@import("sandbox_controls.zig"));
    std.testing.refAllDecls(@import("sandbox_visual_resources.zig"));
    std.testing.refAllDecls(@import("editor/tool.zig"));
    std.testing.refAllDecls(@import("gltf_loader.zig"));
    std.testing.refAllDecls(@import("input.zig"));
    std.testing.refAllDecls(@import("mesh.zig"));
    std.testing.refAllDecls(@import("renderer.zig"));
    std.testing.refAllDecls(@import("texture.zig"));
    std.testing.refAllDecls(@import("timing.zig"));
}
