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
const engine = @import("incinerator_engine");
const zm = @import("zmath");
const timing = @import("timing.zig");
const input = @import("input.zig");
const renderer = @import("renderer.zig");
const mesh = @import("mesh.zig");
const primitives = @import("primitives.zig");
const sandbox_visual_resources = @import("sandbox_visual_resources.zig");
const district_gpu_registry = @import("district_gpu_registry.zig");
const district_scene_adapter = @import("district_scene_adapter.zig");
const district_presentation = @import("district_presentation");
const content = @import("content");
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
    s2_visual_smoke: VisualSmokeConfig,
    window_lifecycle_smoke,
    init_failure_smoke,
};

const BootstrapProfile = enum { sandbox, s0_smoke, s1_smoke, s2_smoke };

const ScriptedScenario = enum { none, s1_character, s2_vehicle };

const s2_enter_tick: u64 = 240;
const s2_brake_tick: u64 = 581;
const s2_steer_tick: u64 = 601;
const s2_exit_tick: u64 = 661;
const s2_required_ticks: u64 = 720;

const district_content_key = "district/s3_fixture";
const district_stream_coord = sandbox_host.ChunkCoord{ .x = 0, .z = 0 };
const DistrictPresentation = district_presentation.Coordinator(
    district_gpu_registry.DistrictGpuRegistry,
    sandbox_host.LoadTicket,
);

const DistrictStreamBound = struct {
    scene: engine.rendering.SceneHandle,
    ticket: sandbox_host.LoadTicket,
};

const DistrictStreamState = union(enum) {
    disabled,
    reading: struct {
        scene: engine.rendering.SceneHandle,
        generation: u64,
    },
    request_submitted: engine.rendering.SceneHandle,
    loading: DistrictStreamBound,
    active: DistrictStreamBound,
};

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
    vehicle_count: usize,
    vehicle_id: ?sandbox_host.PersistentId,
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
    vehicle_presented_frames: u64 = 0,
    character_hidden_while_driving: bool = false,
    character_visible_after_exit: bool = false,
    min_alpha: f32 = 1.0,
    max_alpha: f32 = 0.0,
};

const S2SmokeProgress = struct {
    entered: bool = false,
    drive_applied: bool = false,
    steering_applied: bool = false,
    brake_applied: bool = false,
    steering_observed: bool = false,
    vehicle_moved: bool = false,
    crate_displaced: bool = false,
    exited: bool = false,
    vehicle_position_before_drive: ?[3]f32 = null,
    crate_position_before_drive: ?[3]f32 = null,
};

const WindowLifecycleSummary = struct {
    warmup_ready_frames: u64 = 0,
    restored_ready_frames: u64 = 0,
    unavailable_frames: u64 = 0,
    minimized_wait_iterations: u64 = 0,
    minimized_dwell_ns: u64 = 0,
};

const AppInitFailurePoint = enum {
    renderer_after_window_claim,
    renderer_after_pipelines,
    renderer_after_placeholder_resources,
    after_renderer,
    after_visual_resources,
    after_simulation,
};

fn rendererFailurePoint(point: ?AppInitFailurePoint) ?renderer.InitFailurePoint {
    return switch (point orelse return null) {
        .renderer_after_window_claim => .after_window_claim,
        .renderer_after_pipelines => .after_pipelines,
        .renderer_after_placeholder_resources => .after_placeholder_resources,
        .after_renderer, .after_visual_resources, .after_simulation => null,
    };
}

fn injectAppInitFailure(
    configured: ?AppInitFailurePoint,
    reached: AppInitFailurePoint,
) !void {
    if (configured == reached) return error.InjectedAppInitFailure;
}

fn suspendGameplayForWindowState(
    input_buffer: *const input.InputBuffer,
    action_latch: *sandbox_controls.ActionLatch,
) bool {
    if (!input_buffer.window_minimized) return false;
    // A focus-loss reset can arrive while the render/simulation loop is
    // suspended. Clear unconsumed frame edges and deltas here so they cannot
    // replay when the window is restored.
    action_latch.clear();
    return true;
}

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

fn distanceSquared(first: [3]f32, current: [3]f32) f32 {
    var result: f32 = 0;
    for (first, current) |a, b| {
        const delta = b - a;
        result += delta * delta;
    }
    return result;
}

fn parseProgramMode(args: anytype) !ProgramMode {
    var verify_install = false;
    var visual_smoke = false;
    var s1_visual_smoke = false;
    var s2_visual_smoke = false;
    var window_lifecycle_smoke = false;
    var init_failure_smoke = false;
    var frames: ?u64 = null;
    var virtual_render_hz: ?u32 = null;
    var content_root_seen = false;

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
        } else if (std.mem.eql(u8, arg, "--s2-visual-smoke")) {
            if (s2_visual_smoke) return error.DuplicateArgument;
            s2_visual_smoke = true;
        } else if (std.mem.eql(u8, arg, "--window-lifecycle-smoke")) {
            if (window_lifecycle_smoke) return error.DuplicateArgument;
            window_lifecycle_smoke = true;
        } else if (std.mem.eql(u8, arg, "--init-failure-smoke")) {
            if (init_failure_smoke) return error.DuplicateArgument;
            init_failure_smoke = true;
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
        } else if (std.mem.startsWith(u8, arg, "--content-root=")) {
            if (content_root_seen) return error.DuplicateArgument;
            _ = try content.ContentRootPath.parse(arg["--content-root=".len..]);
            content_root_seen = true;
        } else {
            return error.UnknownArgument;
        }
    }

    if (verify_install) {
        if (visual_smoke or s1_visual_smoke or s2_visual_smoke or window_lifecycle_smoke or
            init_failure_smoke or frames != null or virtual_render_hz != null)
        {
            return error.ConflictingProgramModes;
        }
        return .verify_install;
    }
    const explicit_mode_count = @as(u8, @intFromBool(visual_smoke)) +
        @as(u8, @intFromBool(s1_visual_smoke)) +
        @as(u8, @intFromBool(s2_visual_smoke)) +
        @as(u8, @intFromBool(window_lifecycle_smoke)) +
        @as(u8, @intFromBool(init_failure_smoke));
    if (explicit_mode_count > 1) return error.ConflictingProgramModes;
    if (content_root_seen and explicit_mode_count != 0) return error.ConflictingProgramModes;
    if (!visual_smoke and !s1_visual_smoke and !s2_visual_smoke and
        (frames != null or virtual_render_hz != null))
    {
        return error.VisualSmokeOptionWithoutMode;
    }
    if (window_lifecycle_smoke) return .window_lifecycle_smoke;
    if (init_failure_smoke) return .init_failure_smoke;
    if (!visual_smoke and !s1_visual_smoke and !s2_visual_smoke) return .normal;

    const config = VisualSmokeConfig{
        .frames = frames orelse if (s2_visual_smoke) 1_440 else 480,
        .virtual_render_hz = virtual_render_hz orelse 240,
    };
    const scaled = std.math.mul(u64, config.frames, 4) catch
        return error.InvalidFrameCount;
    _ = std.math.add(u64, scaled, 120) catch return error.InvalidFrameCount;
    return if (s2_visual_smoke)
        .{ .s2_visual_smoke = config }
    else if (s1_visual_smoke)
        .{ .s1_visual_smoke = config }
    else
        .{ .visual_smoke = config };
}

fn parseContentRootOverride(args: anytype) !?content.ContentRootPath {
    var result: ?content.ContentRootPath = null;
    for (args[1..args.len]) |raw_arg| {
        const arg: []const u8 = raw_arg;
        if (!std.mem.startsWith(u8, arg, "--content-root=")) continue;
        if (result != null) return error.DuplicateArgument;
        result = try content.ContentRootPath.parse(arg["--content-root=".len..]);
    }
    return result;
}

fn resolveContentRoot(
    io: std.Io,
    allocator: std.mem.Allocator,
    configured: ?content.ContentRootPath,
) !content.ContentRootPath {
    if (configured) |root| return root;
    var executable_dir_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const executable_dir_len = try std.process.executableDirPath(io, &executable_dir_buffer);
    const resolved = try std.fs.path.resolve(
        allocator,
        &.{ executable_dir_buffer[0..executable_dir_len], "../share/incinerator/content" },
    );
    defer allocator.free(resolved);
    return content.ContentRootPath.parse(resolved);
}

fn validateCookedLogicalDistrict(view: content.bundle.BundleView) !void {
    const expected = try sandbox_host.proceduralDistrictBuild(district_stream_coord);
    if (view.static_boxes.len != expected.boxes().len) {
        return error.CookedDistrictLogicalShapeMismatch;
    }
    for (view.static_boxes, expected.boxes()) |cooked, logical| {
        if (!std.meta.eql(cooked.position, logical.pose.position) or
            !std.meta.eql(cooked.rotation, logical.pose.rotation) or
            !std.meta.eql(cooked.half_extents, logical.half_extents))
        {
            return error.CookedDistrictLogicalShapeMismatch;
        }
    }
}

fn isRetryableDistrictStageError(err: anyerror) bool {
    return err == error.DistrictStagingBudgetExceeded or
        err == error.DistrictResidentBudgetExceeded;
}

fn submitLogicalBeforeStage(
    context: anytype,
    comptime submit_logical: anytype,
    comptime stage_visual: anytype,
) !bool {
    try submit_logical(context);
    return try stage_visual(context);
}

fn verifyInstalledContent(
    io: std.Io,
    allocator: std.mem.Allocator,
    root_path: content.ContentRootPath,
) !void {
    var root = try content.ContentRoot.open(io, root_path);
    defer root.deinit(io);
    const key = try content.BundleKey.parse(district_content_key);
    var result = try root.load(io, allocator, key, .{});
    switch (result) {
        .failed => |failure| {
            std.debug.print("Installed cooked content failed validation: {any}\n", .{failure});
            return error.InstalledContentInvalid;
        },
        .scene => |*scene| {
            defer scene.deinit();
            const view = scene.view();
            try validateCookedLogicalDistrict(view);
            if (view.nodes.len < 2 or view.meshes.len == 0 or view.materials.len == 0 or
                view.textures.len == 0)
            {
                return error.InstalledContentIncomplete;
            }
        },
    }
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
    initial_vehicle_id: ?sandbox_host.PersistentId,
    controlled_vehicle_id: ?sandbox_host.PersistentId,
    action_latch: sandbox_controls.ActionLatch,
    game_camera: camera.Camera,
    profile: BootstrapProfile,
    s2_smoke: S2SmokeProgress,

    // Presentation resources remain owned by the visual host.
    ground_mesh: mesh.Mesh,
    block_mesh: mesh.Mesh,
    visuals: sandbox_visual_resources.SandboxVisualResources,
    district_registry: *district_gpu_registry.DistrictGpuRegistry,
    district_presentation: DistrictPresentation,
    district_content_worker: ?*content.SceneWorker,
    district_pending_scene: ?content.bundle.OwnedBundle,
    district_stream_state: DistrictStreamState,

    // Debug counters
    debug_frame_counter: u32,

    pub fn init(
        io: std.Io,
        profile: BootstrapProfile,
        content_root: ?content.ContentRootPath,
    ) !App {
        return initWithFailurePoint(io, profile, content_root, null);
    }

    fn initWithFailurePoint(
        io: std.Io,
        profile: BootstrapProfile,
        content_root: ?content.ContentRootPath,
        failure_point: ?AppInitFailurePoint,
    ) !App {
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
        var gpu_renderer = try renderer.Renderer.initWithFailurePoint(
            window,
            rendererFailurePoint(failure_point),
        );
        errdefer gpu_renderer.deinit();
        try injectAppInitFailure(failure_point, .after_renderer);

        // Create ground plane mesh
        var ground_mesh = try primitives.createGroundPlane(gpu_renderer.getDevice());
        errdefer ground_mesh.deinit();

        var block_mesh = try primitives.createCube(gpu_renderer.getDevice());
        errdefer block_mesh.deinit();

        const district_registry = try std.heap.page_allocator.create(
            district_gpu_registry.DistrictGpuRegistry,
        );
        errdefer std.heap.page_allocator.destroy(district_registry);
        district_registry.* = try district_gpu_registry.DistrictGpuRegistry.init(
            std.heap.page_allocator,
            .{ .device = gpu_renderer.getDevice() },
            .{},
            .{},
        );
        errdefer district_registry.deinit();
        var district_presentation_owner = DistrictPresentation.init(district_registry);

        const character_config = sandbox_host.CharacterConfig{
            .assets = .{
                .mesh = sandbox_visual_resources.character_mesh_handle,
                .material = sandbox_visual_resources.character_material_handle,
            },
        };
        const vehicle_config = sandbox_host.VehicleConfig{
            .assets = .{
                .chassis_mesh = sandbox_visual_resources.vehicle_chassis_mesh_handle,
                .chassis_material = sandbox_visual_resources.vehicle_chassis_material_handle,
                .wheel_mesh = sandbox_visual_resources.vehicle_wheel_mesh_handle,
                .wheel_material = sandbox_visual_resources.vehicle_wheel_material_handle,
            },
        };
        var visuals = try sandbox_visual_resources.SandboxVisualResources.init(
            gpu_renderer.getDevice(),
            character_config.radius,
            character_config.half_height,
        );
        errdefer visuals.deinit();
        try injectAppInitFailure(failure_point, .after_visual_resources);

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
            .vehicle = vehicle_config,
            .block = switch (profile) {
                .sandbox, .s1_smoke => sandbox_block,
                .s0_smoke, .s2_smoke => null,
            },
        });
        errdefer simulation.deinit();
        try injectAppInitFailure(failure_point, .after_simulation);

        var district_content_worker: ?*content.SceneWorker = null;
        var district_stream_state: DistrictStreamState = .disabled;
        if (profile == .sandbox) {
            const configured_root = content_root orelse return error.ContentRootRequired;
            const scene = try district_presentation_owner.beginRequest();
            errdefer district_presentation_owner.releaseAfterSimulationTeardown() catch {};
            const worker = try std.heap.page_allocator.create(content.SceneWorker);
            errdefer std.heap.page_allocator.destroy(worker);
            worker.* = content.SceneWorker.init(io, std.heap.page_allocator);
            errdefer worker.deinit();
            const generation: u64 = 1;
            switch (try worker.request(.{
                .generation = generation,
                .content_root = configured_root,
                .key = try content.BundleKey.parse(district_content_key),
            })) {
                .accepted => {},
                else => return error.DistrictContentWorkerAdmissionFailed,
            }
            district_content_worker = worker;
            district_stream_state = .{ .reading = .{
                .scene = scene,
                .generation = generation,
            } };
        }
        try simulation.submit(.{ .spawn = .{
            .request_id = 1,
            .pose = .{ .position = switch (profile) {
                .s2_smoke => .{ 0, 0.5, -9 },
                .sandbox, .s0_smoke, .s1_smoke => .{ 0, 12, 0 },
            } },
            .velocity = .{ .angular = .{ 0.2, 0.35, 0.1 } },
        } });
        if (profile != .s0_smoke) {
            try simulation.submitCharacter(.{ .spawn = .{
                .request_id = 1,
                .position = switch (profile) {
                    .s2_smoke => .{ 0, 0, 2 },
                    .sandbox, .s1_smoke => .{ 0, 0, 4 },
                    .s0_smoke => unreachable,
                },
            } });
        }
        if (profile == .sandbox or profile == .s2_smoke) {
            try simulation.submitVehicle(.{ .spawn = .{
                .request_id = 1,
                .chassis = .{ .pose = .{ .position = switch (profile) {
                    .sandbox => .{ 0, 2, 2 },
                    .s2_smoke => .{ 0, 2, 0 },
                    .s0_smoke, .s1_smoke => unreachable,
                } } },
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
        std.debug.print("   WASD - Move character / drive vehicle\n", .{});
        std.debug.print("   E - Enter / exit vehicle\n", .{});
        std.debug.print("   SPACE - Jump / vehicle brake\n", .{});
        std.debug.print("   LEFT SHIFT - Vehicle hand brake\n", .{});
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
            .initial_vehicle_id = null,
            .controlled_vehicle_id = null,
            .action_latch = .{},
            .ground_mesh = ground_mesh,
            .block_mesh = block_mesh,
            .visuals = visuals,
            .district_registry = district_registry,
            .district_presentation = district_presentation_owner,
            .district_content_worker = district_content_worker,
            .district_pending_scene = null,
            .district_stream_state = district_stream_state,
            .game_camera = .{
                .position = .{ 0, 3, 10, 1 },
                .yaw = 0,
                .pitch = -0.25,
            },
            .profile = profile,
            .s2_smoke = .{},
            .debug_frame_counter = 0,
        };
    }

    pub fn deinit(self: *App) void {
        const completed_ticks = self.simulation.tickIndex();

        // Clean up editor first (needs GPU device to still be valid)
        editor.deinit();
        if (self.district_content_worker) |worker| {
            worker.deinit();
            std.heap.page_allocator.destroy(worker);
            self.district_content_worker = null;
        }
        self.clearPendingDistrictScene();
        self.simulation.deinit();
        self.district_presentation.releaseAfterSimulationTeardown() catch |err| {
            std.debug.panic("district presentation teardown failed: {s}", .{@errorName(err)});
        };
        self.district_registry.deinit();
        std.heap.page_allocator.destroy(self.district_registry);
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
        scenario: ScriptedScenario,
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
            if (self.waitForWindowSuspension()) continue;
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
            try self.pumpDistrictContent();

            // ================================================================
            // PHASE 2: SIMULATION TICK (Fixed 120Hz)
            // ================================================================
            // Run simulation at fixed timestep. Multiple ticks may run per frame
            // if we're behind, or zero ticks if we're ahead.
            while (self.frame_timer.shouldTick()) {
                try self.simulateTick(scenario);
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
                    switch (scenario) {
                        .none => {},
                        .s1_character => if (self.initial_character_id != null) {
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
                        },
                        .s2_vehicle => {
                            if (self.initial_vehicle_id) |spawned_id| {
                                if (presentation.vehicle_count != 1) {
                                    return error.S2VisualSmokeVehiclePresentationMissing;
                                }
                                const presented_id = presentation.vehicle_id orelse
                                    return error.S2VisualSmokeVehiclePresentationMissing;
                                if (!std.meta.eql(presented_id, spawned_id)) {
                                    return error.S2VisualSmokePresentedWrongVehicle;
                                }
                                summary.vehicle_presented_frames += 1;
                            }
                            if (self.initial_character_id) |spawned_id| {
                                if (self.s2_smoke.entered and !self.s2_smoke.exited) {
                                    if (presentation.character_count != 0) {
                                        return error.S2VisualSmokeDrivingCharacterVisible;
                                    }
                                    summary.character_hidden_while_driving = true;
                                } else {
                                    if (presentation.character_count != 1) {
                                        return error.S2VisualSmokeCharacterPresentationMissing;
                                    }
                                    const presented_id = presentation.character_id orelse
                                        return error.S2VisualSmokeCharacterPresentationMissing;
                                    if (!std.meta.eql(presented_id, spawned_id)) {
                                        return error.S2VisualSmokePresentedWrongCharacter;
                                    }
                                    summary.character_presented_frames += 1;
                                    if (self.s2_smoke.exited) {
                                        summary.character_visible_after_exit = true;
                                    }
                                }
                            }
                        },
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
            switch (scenario) {
                .none => if (self.simulation.crateCount() != 1 or
                    self.simulation.characterCount() != 0 or
                    self.simulation.vehicleCount() != 0 or
                    self.simulation.entityCount() != 1 or
                    self.simulation.bodyCount() != 2)
                {
                    return error.VisualSmokeLifecycleInvariant;
                },
                .s1_character => {
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
                        self.simulation.vehicleCount() != 0 or
                        self.simulation.entityCount() != 2 or
                        self.simulation.bodyCount() != 3)
                    {
                        return error.S1VisualSmokeLifecycleInvariant;
                    }
                    const character = try self.simulation.character(self.initial_character_id.?);
                    if (character.position[2] < -4.2 or character.position[2] > -3.5) {
                        return error.S1VisualSmokeBlockCollisionFailed;
                    }
                },
                .s2_vehicle => {
                    if (self.simulation.tickIndex() < s2_required_ticks) {
                        return error.S2VisualSmokeInsufficientTicks;
                    }
                    if (self.initial_character_id == null or self.initial_vehicle_id == null) {
                        return error.S2VisualSmokeSpawnMissing;
                    }
                    if (summary.vehicle_presented_frames == 0 or
                        !summary.character_hidden_while_driving or
                        !summary.character_visible_after_exit or
                        !self.s2_smoke.entered or
                        !self.s2_smoke.drive_applied or
                        !self.s2_smoke.steering_applied or
                        !self.s2_smoke.brake_applied or
                        !self.s2_smoke.steering_observed or
                        !self.s2_smoke.vehicle_moved or
                        !self.s2_smoke.crate_displaced or
                        !self.s2_smoke.exited)
                    {
                        return error.S2VisualSmokeLifecycleEvidenceMissing;
                    }
                    if (self.controlled_vehicle_id != null or
                        self.simulation.crateCount() != 1 or
                        self.simulation.characterCount() != 1 or
                        self.simulation.vehicleCount() != 1 or
                        self.simulation.entityCount() != 3 or
                        self.simulation.bodyCount() != 3)
                    {
                        return error.S2VisualSmokeLifecycleInvariant;
                    }
                    const vehicle = try self.simulation.vehicle(self.initial_vehicle_id.?);
                    if (vehicle.driver_id != null) {
                        return error.S2VisualSmokeDriverStillActive;
                    }
                },
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

    /// Exercise the production window-suspension path against a real SDL/Metal
    /// window. This is deliberately real-clock and event-driven: a synthetic
    /// flag would not prove that the platform emits the lifecycle transitions
    /// the host relies on.
    pub fn runWindowLifecycleSmoke(self: *App) !WindowLifecycleSummary {
        const Phase = enum {
            warmup,
            await_minimized,
            dwell,
            await_restored,
            restored,
        };
        const ready_frames_per_side = 8;
        const required_dwell_ns = 750 * std.time.ns_per_ms;
        const overall_timeout_ns = 10 * std.time.ns_per_s;
        const max_minimized_wait_iterations = 512;

        var phase: Phase = .warmup;
        var summary = WindowLifecycleSummary{};
        var running = true;
        var quit_injected = false;
        var saw_minimized_event = false;
        var saw_restored_event = false;
        var minimized_started_ns: u64 = 0;
        const smoke_started_ns = c.SDL_GetTicksNS();

        while (running) {
            self.input_buffer.beginFrame();
            running = self.input_buffer.pumpEvents();
            if (!running) break;

            const now_ns = c.SDL_GetTicksNS();
            if (now_ns - smoke_started_ns > overall_timeout_ns) {
                return error.WindowLifecycleSmokeTimeout;
            }

            if (self.input_buffer.window_minimized_this_frame) {
                if (phase != .await_minimized) {
                    return error.UnexpectedWindowMinimizedEvent;
                }
                saw_minimized_event = true;
                minimized_started_ns = now_ns;
                phase = .dwell;
            }
            if (self.input_buffer.window_restored_this_frame) {
                if (phase != .await_restored) {
                    return error.UnexpectedWindowRestoredEvent;
                }
                saw_restored_event = true;
                phase = .restored;
                self.frame_timer.resyncClock();
            }

            if (phase == .dwell and now_ns - minimized_started_ns >= required_dwell_ns) {
                summary.minimized_dwell_ns = now_ns - minimized_started_ns;
                if (!c.SDL_RestoreWindow(self.window)) {
                    std.debug.print("SDL_RestoreWindow failed: {s}\n", .{c.SDL_GetError()});
                    return error.WindowRestoreFailed;
                }
                if (!c.SDL_SyncWindow(self.window)) {
                    std.debug.print("SDL_SyncWindow after restore failed: {s}\n", .{c.SDL_GetError()});
                    return error.WindowRestoreSyncFailed;
                }
                phase = .await_restored;
            }

            if (phase == .await_minimized or phase == .dwell or phase == .await_restored) {
                summary.minimized_wait_iterations += 1;
                if (summary.minimized_wait_iterations > max_minimized_wait_iterations) {
                    return error.WindowLifecycleBusyLoop;
                }
                if (self.waitForWindowSuspension()) continue;
                _ = c.SDL_WaitEventTimeout(null, 16);
                self.frame_timer.resyncClock();
                continue;
            }

            self.frame_timer.beginFrame();
            while (self.frame_timer.shouldTick()) {
                try self.simulateTick(.s1_character);
            }

            switch (try self.render(self.frame_timer.alpha())) {
                .ready => {
                    switch (phase) {
                        .warmup => {
                            summary.warmup_ready_frames += 1;
                            if (summary.warmup_ready_frames == ready_frames_per_side) {
                                if (!c.SDL_MinimizeWindow(self.window)) {
                                    std.debug.print("SDL_MinimizeWindow failed: {s}\n", .{c.SDL_GetError()});
                                    return error.WindowMinimizeFailed;
                                }
                                if (!c.SDL_SyncWindow(self.window)) {
                                    std.debug.print("SDL_SyncWindow after minimize failed: {s}\n", .{c.SDL_GetError()});
                                    return error.WindowMinimizeSyncFailed;
                                }
                                phase = .await_minimized;
                            }
                        },
                        .restored => {
                            summary.restored_ready_frames += 1;
                            if (summary.restored_ready_frames == ready_frames_per_side and
                                !quit_injected)
                            {
                                var quit_event = std.mem.zeroes(c.SDL_Event);
                                quit_event.type = c.SDL_EVENT_QUIT;
                                if (!c.SDL_PushEvent(&quit_event)) {
                                    return error.SDLQuitEventFailed;
                                }
                                quit_injected = true;
                            }
                        },
                        .await_minimized, .dwell, .await_restored => unreachable,
                    }
                },
                .unavailable => summary.unavailable_frames += 1,
            }
        }

        if (!quit_injected or !saw_minimized_event or !saw_restored_event) {
            return error.WindowLifecycleSmokeInterrupted;
        }
        if (summary.minimized_dwell_ns < required_dwell_ns or
            summary.warmup_ready_frames < ready_frames_per_side or
            summary.restored_ready_frames < ready_frames_per_side)
        {
            return error.WindowLifecycleSmokeInvariant;
        }
        return summary;
    }

    /// Apply the canonical main-window suspension policy. Both the normal loop
    /// and the native lifecycle smoke use this path.
    fn waitForWindowSuspension(self: *App) bool {
        if (!suspendGameplayForWindowState(&self.input_buffer, &self.action_latch)) {
            return false;
        }
        // Do not advance simulation or request a GPU frame. Waiting without an
        // output event preserves SDL's queue for the next input-pump phase.
        _ = c.SDL_WaitEventTimeout(null, 16);
        self.frame_timer.resyncClock();
        return true;
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
            .interact_pressed = self.input_buffer.isKeyPressed(input.Key.E),
            .brake = self.input_buffer.isKeyDown(input.Key.SPACE),
            .hand_brake = self.input_buffer.isKeyDown(input.Key.LSHIFT),
            .reset = self.input_buffer.gameplayActionsMustReset(),
        });
    }

    fn pumpDistrictContent(self: *App) !void {
        try self.retryPendingDistrictScene();
        const reading = switch (self.district_stream_state) {
            .reading => |value| value,
            else => return,
        };
        const worker = self.district_content_worker orelse
            return error.DistrictContentWorkerMissing;
        switch (worker.poll(reading.generation)) {
            .pending => {},
            .idle, .stale => return error.DistrictContentWorkerStateMismatch,
            .completion => |completion| switch (completion) {
                .cancelled => return error.DistrictContentLoadCancelled,
                .failed => |failed| {
                    std.debug.print("Cooked district load failed: {any}\n", .{failed.failure});
                    return error.DistrictContentLoadFailed;
                },
                .ready => |ready_value| {
                    if (ready_value.generation != reading.generation) {
                        var stale_scene = ready_value.scene;
                        stale_scene.deinit();
                        return error.DistrictContentGenerationMismatch;
                    }
                    var scene = ready_value.scene;
                    errdefer scene.deinit();
                    const view = scene.view();
                    try validateCookedLogicalDistrict(view);
                    var upload_plan = try district_scene_adapter.build(view);
                    // A validated logical district is submitted before GPU
                    // staging admission. Expected registry backpressure keeps
                    // the scene on fallback and retries on a later frame.
                    const Admission = struct {
                        app: *App,
                        scene_handle: engine.rendering.SceneHandle,
                        plan: *district_scene_adapter.UploadPlan,

                        fn submitLogical(context: *@This()) !void {
                            try context.app.simulation.submitDistrict(.{ .request_load = .{
                                .request_id = 1,
                                .coord = district_stream_coord,
                                .assets = .{ .scene = context.scene_handle },
                            } });
                            context.app.district_stream_state = .{
                                .request_submitted = context.scene_handle,
                            };
                        }

                        fn stageVisual(context: *@This()) !bool {
                            return context.app.stageDistrictUpload(context.scene_handle, context.plan);
                        }
                    };
                    var admission = Admission{
                        .app = self,
                        .scene_handle = reading.scene,
                        .plan = &upload_plan,
                    };
                    if (try submitLogicalBeforeStage(
                        &admission,
                        Admission.submitLogical,
                        Admission.stageVisual,
                    )) {
                        scene.deinit();
                    } else {
                        self.district_pending_scene = scene;
                    }
                },
            },
        }
    }

    fn stageDistrictUpload(
        self: *App,
        scene_handle: engine.rendering.SceneHandle,
        upload_plan: *district_scene_adapter.UploadPlan,
    ) !bool {
        self.district_registry.stage(scene_handle, upload_plan.sceneUpload()) catch |err| {
            if (isRetryableDistrictStageError(err)) return false;
            return err;
        };
        const staged_stats = try self.district_registry.stats();
        std.debug.print(
            "Cooked district staged: primitives={d} textures={d} cpu_bytes={d}\n",
            .{
                upload_plan.mesh_count,
                upload_plan.texture_count,
                staged_stats.staged_cpu_bytes,
            },
        );
        return true;
    }

    fn retryPendingDistrictScene(self: *App) !void {
        const pending = if (self.district_pending_scene) |*scene| scene else return;
        const scene_handle = switch (self.district_stream_state) {
            .request_submitted => |value| value,
            .loading, .active => |value| value.scene,
            .disabled, .reading => return error.DistrictPendingSceneStateMismatch,
        };
        var upload_plan = try district_scene_adapter.build(pending.view());
        if (!try self.stageDistrictUpload(scene_handle, &upload_plan)) return;
        pending.deinit();
        self.district_pending_scene = null;
    }

    fn clearPendingDistrictScene(self: *App) void {
        if (self.district_pending_scene) |*scene| scene.deinit();
        self.district_pending_scene = null;
    }

    fn processDistrictOutcomes(self: *App) !void {
        while (self.simulation.pollDistrictOutcome()) |outcome| {
            switch (outcome) {
                .load_requested => |requested| {
                    const scene = switch (self.district_stream_state) {
                        .request_submitted => |value| value,
                        else => return error.UnexpectedDistrictOutcome,
                    };
                    try self.district_presentation.loadAdmitted(scene, requested.ticket);
                    self.district_stream_state = .{ .loading = .{
                        .scene = scene,
                        .ticket = requested.ticket,
                    } };
                },
                .activated => |activated| {
                    const loading = switch (self.district_stream_state) {
                        .loading => |value| value,
                        else => return error.UnexpectedDistrictOutcome,
                    };
                    if (!std.meta.eql(loading.ticket, activated.ticket)) {
                        return error.UnexpectedDistrictOutcome;
                    }
                    try self.district_presentation.logicalActivated(activated.ticket);
                    self.district_stream_state = .{ .active = loading };
                    std.debug.print(
                        "Logical district active: coord=({d},{d}) generation={d}\n",
                        .{
                            activated.coord.x,
                            activated.coord.z,
                            activated.ticket.generation,
                        },
                    );
                },
                .rejected => {
                    const scene = switch (self.district_stream_state) {
                        .request_submitted => |value| value,
                        else => return error.UnexpectedDistrictOutcome,
                    };
                    self.clearPendingDistrictScene();
                    try self.district_presentation.loadRejected(scene);
                    self.district_stream_state = .disabled;
                    return error.DistrictLoadRejected;
                },
                .cancelled => |cancelled| {
                    self.clearPendingDistrictScene();
                    try self.district_presentation.loadTerminated(cancelled.ticket);
                    self.district_stream_state = .disabled;
                },
                .load_failed => |failed| {
                    self.clearPendingDistrictScene();
                    try self.district_presentation.loadTerminated(failed.ticket);
                    self.district_stream_state = .disabled;
                    return error.DistrictLogicalLoadFailed;
                },
                .unloaded => |unloaded| {
                    self.clearPendingDistrictScene();
                    try self.district_presentation.logicalUnloaded(unloaded.ticket);
                    const draws = try self.simulation.districtPresentation();
                    try self.district_presentation.presentationAbsent(draws.len);
                    self.district_stream_state = .disabled;
                },
                .cancellation_requested => return error.UnexpectedDistrictOutcome,
            }
        }
        while (self.simulation.pollDistrictEvent()) |_| {}
    }

    /// Submit one device-independent action sample before each fixed tick.
    fn simulateTick(self: *App, scenario: ScriptedScenario) !void {
        const actions = switch (scenario) {
            .none => self.action_latch.takeTick(),
            .s1_character => sandbox_controls.TickSample{
                .move = .{ 0, 1 },
                .look_delta = .{ 0, 0 },
                .jump_pressed = self.simulation.tickIndex() == 60,
                .interact_pressed = false,
                .brake = false,
                .hand_brake = false,
            },
            .s2_vehicle => sandbox_controls.TickSample{
                .move = .{ 0, 0 },
                .look_delta = .{ 0, 0 },
                .jump_pressed = false,
                .interact_pressed = false,
                .brake = false,
                .hand_brake = false,
            },
        };
        self.game_camera.rotate(actions.look_delta[0], actions.look_delta[1]);

        switch (scenario) {
            .none => try self.submitInteractiveActions(actions),
            .s1_character => if (self.initial_character_id) |id| {
                try self.submitCharacterActions(id, actions);
            },
            .s2_vehicle => try self.submitInteractiveActions(self.s2ScriptedActions()),
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
        try self.processVehicleOutcomes(scenario);
        while (self.simulation.pollVehicleEvent()) |_| {}
        try self.processDistrictOutcomes();
        if (scenario == .s2_vehicle) try self.observeS2State();
    }

    fn submitInteractiveActions(
        self: *App,
        actions: sandbox_controls.TickSample,
    ) !void {
        if (actions.interact_pressed) {
            const character_id = self.initial_character_id orelse return;
            const vehicle_id = self.initial_vehicle_id orelse return;
            if (self.controlled_vehicle_id) |controlled_id| {
                try self.simulation.submitVehicle(.{ .exit = .{
                    .vehicle_id = controlled_id,
                    .driver_id = character_id,
                } });
            } else {
                try self.simulation.submitVehicle(.{ .enter = .{
                    .vehicle_id = vehicle_id,
                    .driver_id = character_id,
                } });
            }
            // Authority transitions consume the tick without applying the same
            // frame sample to either locomotion target.
            return;
        }

        if (self.controlled_vehicle_id) |vehicle_id| {
            const character_id = self.initial_character_id orelse
                return error.ControlledVehicleMissingCharacter;
            try self.simulation.submitVehicle(.{ .drive = .{
                .vehicle_id = vehicle_id,
                .driver_id = character_id,
                .input = .{
                    .throttle = actions.move[1],
                    .steering = actions.move[0],
                    .brake = if (actions.brake) 1 else 0,
                    .hand_brake = if (actions.hand_brake) 1 else 0,
                },
            } });
        } else if (self.initial_character_id) |character_id| {
            try self.submitCharacterActions(character_id, actions);
        }
    }

    fn submitCharacterActions(
        self: *App,
        character_id: sandbox_host.PersistentId,
        actions: sandbox_controls.TickSample,
    ) !void {
        try self.simulation.submitCharacter(.{ .actions = .{
            .id = character_id,
            .move = actions.move,
            .facing_yaw = self.game_camera.yaw,
            .jump_pressed = actions.jump_pressed,
        } });
    }

    fn s2ScriptedActions(self: *const App) sandbox_controls.TickSample {
        const tick = self.simulation.tickIndex();
        var actions = sandbox_controls.TickSample{
            .move = .{ 0, 0 },
            .look_delta = .{ 0, 0 },
            .jump_pressed = false,
            .interact_pressed = tick == s2_enter_tick or tick == s2_exit_tick,
            .brake = false,
            .hand_brake = false,
        };
        if (tick > s2_enter_tick and tick < s2_exit_tick) {
            actions.move = .{
                if (tick >= s2_steer_tick) 0.65 else 0,
                1,
            };
            actions.brake = tick >= s2_brake_tick and tick < s2_steer_tick;
        }
        return actions;
    }

    fn processVehicleOutcomes(self: *App, scenario: ScriptedScenario) !void {
        while (self.simulation.pollVehicleOutcome()) |outcome| {
            switch (outcome) {
                .spawned => |spawned| {
                    if (spawned.request_id != 1 or self.initial_vehicle_id != null) {
                        return error.UnexpectedVehicleBootstrapOutcome;
                    }
                    self.initial_vehicle_id = spawned.id;
                },
                .entered => |entered| {
                    if (self.controlled_vehicle_id != null or
                        !std.meta.eql(entered.vehicle_id, self.initial_vehicle_id orelse
                            return error.UnexpectedVehicleAuthorityOutcome) or
                        !std.meta.eql(entered.driver_id, self.initial_character_id orelse
                            return error.UnexpectedVehicleAuthorityOutcome))
                    {
                        return error.UnexpectedVehicleAuthorityOutcome;
                    }
                    self.controlled_vehicle_id = entered.vehicle_id;
                    if (scenario == .s2_vehicle) {
                        self.s2_smoke.entered = true;
                        self.s2_smoke.vehicle_position_before_drive =
                            (try self.simulation.vehicle(entered.vehicle_id)).state.chassis.pose.position;
                        const crate_id = self.initial_crate_id orelse
                            return error.S2VisualSmokeCrateSpawnMissing;
                        self.s2_smoke.crate_position_before_drive =
                            (try self.simulation.crate(crate_id)).state.pose.position;
                    }
                },
                .drive_applied => |applied| {
                    if (!std.meta.eql(applied.vehicle_id, self.controlled_vehicle_id orelse
                        return error.UnexpectedVehicleDriveOutcome) or
                        !std.meta.eql(applied.driver_id, self.initial_character_id orelse
                            return error.UnexpectedVehicleDriveOutcome))
                    {
                        return error.UnexpectedVehicleDriveOutcome;
                    }
                    if (scenario == .s2_vehicle) {
                        self.s2_smoke.drive_applied = true;
                        self.s2_smoke.steering_applied = self.s2_smoke.steering_applied or
                            @abs(applied.input.steering) > 0.1;
                        self.s2_smoke.brake_applied = self.s2_smoke.brake_applied or
                            applied.input.brake > 0.5;
                    }
                },
                .exited => |exited| {
                    if (!std.meta.eql(exited.vehicle_id, self.controlled_vehicle_id orelse
                        return error.UnexpectedVehicleAuthorityOutcome) or
                        !std.meta.eql(exited.driver_id, self.initial_character_id orelse
                            return error.UnexpectedVehicleAuthorityOutcome))
                    {
                        return error.UnexpectedVehicleAuthorityOutcome;
                    }
                    self.controlled_vehicle_id = null;
                    if (scenario == .s2_vehicle) self.s2_smoke.exited = true;
                },
                .rejected => |rejected| switch (scenario) {
                    .s1_character, .s2_vehicle => return error.ScriptedVehicleCommandRejected,
                    .none => switch (rejected.command) {
                        .enter => if (rejected.reason != .too_far) {
                            return error.UnexpectedVehicleEnterRejection;
                        },
                        .exit => if (rejected.reason != .exit_blocked) {
                            return error.UnexpectedVehicleExitRejection;
                        },
                        .spawn, .drive, .despawn => return error.UnexpectedVehicleCommandRejection,
                    },
                },
                .despawned => return error.UnexpectedVehicleBootstrapOutcome,
            }
        }
    }

    fn observeS2State(self: *App) !void {
        if (!self.s2_smoke.entered or self.s2_smoke.exited) return;
        const vehicle_id = self.initial_vehicle_id orelse
            return error.S2VisualSmokeVehicleSpawnMissing;
        const vehicle = try self.simulation.vehicle(vehicle_id);
        if (self.s2_smoke.vehicle_position_before_drive) |before| {
            self.s2_smoke.vehicle_moved = self.s2_smoke.vehicle_moved or
                distanceSquared(before, vehicle.state.chassis.pose.position) > 1;
        }
        self.s2_smoke.steering_observed = self.s2_smoke.steering_observed or
            @abs(vehicle.state.wheels[0].steer_angle) > 0.05 or
            @abs(vehicle.state.wheels[1].steer_angle) > 0.05;
        if (self.s2_smoke.crate_position_before_drive) |before| {
            const crate_id = self.initial_crate_id orelse
                return error.S2VisualSmokeCrateSpawnMissing;
            const position = (try self.simulation.crate(crate_id)).state.pose.position;
            self.s2_smoke.crate_displaced = self.s2_smoke.crate_displaced or
                distanceSquared(before, position) > 0.04;
        }
    }

    /// Render the current frame using SDL3 GPU API
    /// `alpha` is the interpolation factor (0.0 to 1.0) for smooth visuals.
    fn render(self: *App, alpha: f32) !RenderResult {
        // Streamed submissions are independent of the frame command buffer.
        // Poll fences without waiting, then submit at most one bounded batch.
        const district_gpu_progress = try self.district_registry.pump();
        if (district_gpu_progress.published_scenes > 0) {
            std.debug.print(
                "Cooked district GPU resident: scenes={d} bytes={d}\n",
                .{
                    district_gpu_progress.published_scenes,
                    (try self.district_registry.stats()).resident_gpu_bytes,
                },
            );
        }

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
        const vehicle_draws = try self.simulation.vehiclePresentation(alpha);
        if (self.controlled_vehicle_id) |controlled_id| {
            var vehicle_found = false;
            for (vehicle_draws) |draw| {
                if (std.meta.eql(draw.persistent_id, controlled_id)) {
                    self.game_camera.followTarget(.{
                        draw.chassis_pose.position[0],
                        draw.chassis_pose.position[1] + 1,
                        draw.chassis_pose.position[2],
                    }, 8.0);
                    vehicle_found = true;
                    break;
                }
            }
            if (!vehicle_found) return error.ControlledVehiclePresentationMissing;
        } else if (self.initial_character_id) |player_id| {
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
        if (self.profile == .sandbox or self.profile == .s1_smoke) {
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

        const district_draws = try self.simulation.districtPresentation();
        for (district_draws) |draw| {
            const scene = try self.district_presentation.resolve(
                draw.ticket,
                draw.assets.scene,
            );
            if (scene.meshes().len == 0) {
                // Logical activation is visible immediately, even while a
                // cooked scene is staged or its Metal fence is unsignaled.
                for (draw.build.boxes()) |box| {
                    const scale = zm.scaling(
                        box.half_extents[0] * 2,
                        box.half_extents[1] * 2,
                        box.half_extents[2] * 2,
                    );
                    const rotation = zm.quatToMat(zm.f32x4(
                        box.pose.rotation[0],
                        box.pose.rotation[1],
                        box.pose.rotation[2],
                        box.pose.rotation[3],
                    ));
                    const translation = zm.translation(
                        box.pose.position[0],
                        box.pose.position[1],
                        box.pose.position[2],
                    );
                    self.gpu_renderer.drawMesh(
                        &self.block_mesh,
                        zm.mul(zm.mul(scale, rotation), translation),
                        view_proj,
                    );
                }
            } else {
                const root_translation = zm.translation(
                    @as(f32, @floatFromInt(draw.build.coord.x)) * 16.0,
                    0,
                    @as(f32, @floatFromInt(draw.build.coord.z)) * 16.0,
                );
                for (scene.instances()) |instance| {
                    if (instance.mesh_index >= scene.meshes().len) {
                        return error.DistrictResidentInstanceInvalid;
                    }
                    const resident_mesh = scene.meshes()[instance.mesh_index];
                    const texture_view = scene.materialTexture(resident_mesh.material_index);
                    const base_color = scene.materialBaseColor(resident_mesh.material_index);
                    const authored_transform = zm.loadMat(instance.transform[0..]);
                    self.gpu_renderer.drawMeshWithMaterial(
                        resident_mesh.mesh,
                        texture_view,
                        base_color,
                        zm.mul(authored_transform, root_translation),
                        view_proj,
                    );
                }
            }
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

        for (vehicle_draws) |draw| {
            const chassis_mesh = try self.visuals.resolve(
                draw.chassis_mesh,
                draw.chassis_material,
            );
            const chassis_scale = zm.scaling(
                draw.chassis_half_extents[0] * 2,
                draw.chassis_half_extents[1] * 2,
                draw.chassis_half_extents[2] * 2,
            );
            const chassis_rotation = zm.quatToMat(zm.f32x4(
                draw.chassis_pose.rotation[0],
                draw.chassis_pose.rotation[1],
                draw.chassis_pose.rotation[2],
                draw.chassis_pose.rotation[3],
            ));
            const chassis_translation = zm.translation(
                draw.chassis_pose.position[0],
                draw.chassis_pose.position[1],
                draw.chassis_pose.position[2],
            );
            self.gpu_renderer.drawMesh(
                chassis_mesh,
                zm.mul(zm.mul(chassis_scale, chassis_rotation), chassis_translation),
                view_proj,
            );

            for (draw.wheels) |wheel| {
                const wheel_mesh = try self.visuals.resolve(wheel.mesh, wheel.material);
                const wheel_scale = zm.scaling(
                    wheel.width,
                    wheel.radius * 2,
                    wheel.radius * 2,
                );
                const wheel_rotation = zm.quatToMat(zm.f32x4(
                    wheel.pose.rotation[0],
                    wheel.pose.rotation[1],
                    wheel.pose.rotation[2],
                    wheel.pose.rotation[3],
                ));
                const wheel_translation = zm.translation(
                    wheel.pose.position[0],
                    wheel.pose.position[1],
                    wheel.pose.position[2],
                );
                self.gpu_renderer.drawMesh(
                    wheel_mesh,
                    zm.mul(zm.mul(wheel_scale, wheel_rotation), wheel_translation),
                    view_proj,
                );
            }
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
            .vehicle_count = vehicle_draws.len,
            .vehicle_id = if (vehicle_draws.len > 0)
                vehicle_draws[0].persistent_id
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

fn runInitFailureSmoke(io: std.Io) !RunSummary {
    const failure_points = [_]AppInitFailurePoint{
        .renderer_after_window_claim,
        .renderer_after_pipelines,
        .renderer_after_placeholder_resources,
        .after_renderer,
        .after_visual_resources,
        .after_simulation,
    };

    for (failure_points) |failure_point| {
        var unexpected = App.initWithFailurePoint(io, .s1_smoke, null, failure_point) catch |err| {
            const expected: anyerror = if (rendererFailurePoint(failure_point) != null)
                error.InjectedRendererInitFailure
            else
                error.InjectedAppInitFailure;
            if (err != expected) return err;
            continue;
        };
        unexpected.deinit();
        return error.InitFailureInjectionMissed;
    }

    // A successful lifecycle in the same process proves that each injected
    // unwind released the SDL video runtime, window, Metal device, Jolt world,
    // and all intermediate resources needed by a later initialization.
    var healthy = try App.init(io, .s1_smoke, null);
    defer healthy.deinit();
    return healthy.run(.{ .frames = 160, .virtual_render_hz = 80 }, .s1_character);
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const mode = try parseProgramMode(args);
    const cli_content_root = try parseContentRootOverride(args);
    const configured_content_root = cli_content_root orelse if (init.environ_map.get(
        "INCINERATOR_CONTENT_ROOT",
    )) |environment_root|
        try content.ContentRootPath.parse(environment_root)
    else
        null;
    const resolved_content_root = switch (mode) {
        .normal, .verify_install => try resolveContentRoot(
            init.io,
            init.arena.allocator(),
            configured_content_root,
        ),
        else => null,
    };
    if (mode == .verify_install) {
        try verifyInstalledContent(
            init.io,
            init.arena.allocator(),
            resolved_content_root.?,
        );
        std.debug.print(
            "Incinerator install verified (content: {s}, shader format: {s}, GPU driver: {s}, editor: {})\n",
            .{
                district_content_key,
                @tagName(shader_assets.format),
                shader_assets.driver,
                build_options.editor_enabled,
            },
        );
        return;
    }

    const profile: BootstrapProfile = switch (mode) {
        .normal => .sandbox,
        .visual_smoke => .s0_smoke,
        .s1_visual_smoke, .window_lifecycle_smoke => .s1_smoke,
        .s2_visual_smoke => .s2_smoke,
        .init_failure_smoke => {
            const summary = try runInitFailureSmoke(init.io);
            const expected = try smokeExpectation(.{
                .frames = 160,
                .virtual_render_hz = 80,
            });
            std.debug.print(
                "INIT_FAILURE_SMOKE_RESULT checkpoints=6 ready_frames={d} " ++
                    "ticks={d} gpu_driver={s}\n",
                .{
                    summary.ready_frames,
                    expected.ticks,
                    shader_assets.driver,
                },
            );
            std.debug.print("INIT_FAILURE_SMOKE_SHUTDOWN status=clean\n", .{});
            return;
        },
        .verify_install => unreachable,
    };
    var app = try App.init(init.io, profile, resolved_content_root);
    var visual_smoke_succeeded = false;
    var s1_visual_smoke_succeeded = false;
    var s2_visual_smoke_succeeded = false;
    var window_lifecycle_smoke_succeeded = false;
    defer {
        app.deinit();
        if (visual_smoke_succeeded) {
            std.debug.print("S0_VISUAL_SMOKE_SHUTDOWN status=clean\n", .{});
        }
        if (s1_visual_smoke_succeeded) {
            std.debug.print("S1_VISUAL_SMOKE_SHUTDOWN status=clean\n", .{});
        }
        if (s2_visual_smoke_succeeded) {
            std.debug.print("S2_VISUAL_SMOKE_SHUTDOWN status=clean\n", .{});
        }
        if (window_lifecycle_smoke_succeeded) {
            std.debug.print("WINDOW_LIFECYCLE_SMOKE_SHUTDOWN status=clean\n", .{});
        }
    }

    // Wire up render settings to editor tool
    render_tool.setRenderSettings(&app.gpu_renderer.render_settings);

    switch (mode) {
        .normal => _ = try app.run(null, .none),
        .verify_install => unreachable,
        .visual_smoke => |config| {
            const summary = try app.run(config, .none);
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
            const summary = try app.run(config, .s1_character);
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
        .s2_visual_smoke => |config| {
            const summary = try app.run(config, .s2_vehicle);
            std.debug.print(
                "S2_VISUAL_SMOKE_RESULT ready_frames={d} unavailable_frames={d} " ++
                    "attempted_frames={d} vehicle_frames={d} vehicle_moved={} " ++
                    "steering_observed={} brake_applied={} crate_displaced={} character_hidden={} " ++
                    "character_restored={} exited={} ticks={d} alpha_min={d:.6} " ++
                    "alpha_max={d:.6} virtual_render_hz={d} gpu_driver={s}\n",
                .{
                    summary.ready_frames,
                    summary.unavailable_frames,
                    summary.attempted_frames,
                    summary.vehicle_presented_frames,
                    app.s2_smoke.vehicle_moved,
                    app.s2_smoke.steering_observed,
                    app.s2_smoke.brake_applied,
                    app.s2_smoke.crate_displaced,
                    summary.character_hidden_while_driving,
                    summary.character_visible_after_exit,
                    app.s2_smoke.exited,
                    app.simulation.tickIndex(),
                    summary.min_alpha,
                    summary.max_alpha,
                    config.virtual_render_hz,
                    shader_assets.driver,
                },
            );
            s2_visual_smoke_succeeded = true;
        },
        .window_lifecycle_smoke => {
            const summary = try app.runWindowLifecycleSmoke();
            std.debug.print(
                "WINDOW_LIFECYCLE_SMOKE_RESULT warmup_ready={d} restored_ready={d} " ++
                    "unavailable_frames={d} minimized_wait_iterations={d} " ++
                    "minimized_dwell_ms={d:.3} gpu_driver={s}\n",
                .{
                    summary.warmup_ready_frames,
                    summary.restored_ready_frames,
                    summary.unavailable_frames,
                    summary.minimized_wait_iterations,
                    @as(f64, @floatFromInt(summary.minimized_dwell_ns)) /
                        std.time.ns_per_ms,
                    shader_assets.driver,
                },
            );
            window_lifecycle_smoke_succeeded = true;
        },
        .init_failure_smoke => unreachable,
    }
}

// ============================================================================
// Tests
// ============================================================================

test "app structure exists" {
    // Basic compile-time check that App struct is valid
    _ = App;
}

test "window suspension discards pending and held gameplay actions" {
    var input_buffer = input.InputBuffer.init(1);
    input_buffer.window_minimized = true;
    var action_latch = sandbox_controls.ActionLatch{};
    try action_latch.captureFrame(.{
        .move = .{ 1, -1 },
        .look_delta = .{ 3, -2 },
        .jump_pressed = true,
        .interact_pressed = true,
        .brake = true,
        .hand_brake = true,
    });

    try std.testing.expect(suspendGameplayForWindowState(
        &input_buffer,
        &action_latch,
    ));
    const after_restore = action_latch.takeTick();
    try std.testing.expectEqual([2]f32{ 0, 0 }, after_restore.move);
    try std.testing.expectEqual([2]f32{ 0, 0 }, after_restore.look_delta);
    try std.testing.expect(!after_restore.jump_pressed);
    try std.testing.expect(!after_restore.interact_pressed);
    try std.testing.expect(!after_restore.brake);
    try std.testing.expect(!after_restore.hand_brake);
}

test "program mode parsing keeps visual smoke explicit and bounded" {
    const normal_args = [_][]const u8{"incinerator"};
    const normal = try parseProgramMode(&normal_args);
    try std.testing.expect(normal == .normal);
    const configured_root_args = [_][]const u8{
        "incinerator",
        "--content-root=/tmp/incinerator-content",
    };
    try std.testing.expect((try parseProgramMode(&configured_root_args)) == .normal);
    const configured_root = (try parseContentRootOverride(&configured_root_args)).?;
    try std.testing.expectEqualStrings("/tmp/incinerator-content", configured_root.bytes());
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
    const s2_smoke = try parseProgramMode(&[_][]const u8{
        "incinerator",
        "--s2-visual-smoke",
    });
    try std.testing.expectEqual(@as(u64, 1_440), s2_smoke.s2_visual_smoke.frames);
    try std.testing.expectEqual(@as(u32, 240), s2_smoke.s2_visual_smoke.virtual_render_hz);
    const s2_expected = try smokeExpectation(s2_smoke.s2_visual_smoke);
    try std.testing.expectEqual(s2_required_ticks, s2_expected.ticks);
    const window_smoke = try parseProgramMode(&[_][]const u8{
        "incinerator",
        "--window-lifecycle-smoke",
    });
    try std.testing.expect(window_smoke == .window_lifecycle_smoke);
    const init_failure_smoke = try parseProgramMode(&[_][]const u8{
        "incinerator",
        "--init-failure-smoke",
    });
    try std.testing.expect(init_failure_smoke == .init_failure_smoke);
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
        error.ConflictingProgramModes,
        parseProgramMode(&[_][]const u8{
            "incinerator",
            "--s1-visual-smoke",
            "--s2-visual-smoke",
        }),
    );
    try std.testing.expectError(
        error.ConflictingProgramModes,
        parseProgramMode(&[_][]const u8{
            "incinerator",
            "--window-lifecycle-smoke",
            "--init-failure-smoke",
        }),
    );
    try std.testing.expectError(
        error.VisualSmokeOptionWithoutMode,
        parseProgramMode(&[_][]const u8{
            "incinerator",
            "--window-lifecycle-smoke",
            "--frames=8",
        }),
    );
    try std.testing.expectError(
        error.InvalidVirtualRenderRate,
        parseProgramMode(&[_][]const u8{ "incinerator", "--visual-smoke", "--virtual-render-hz=0" }),
    );
    try std.testing.expectError(
        error.InvalidContentRoot,
        parseProgramMode(&[_][]const u8{ "incinerator", "--content-root=relative" }),
    );
    try std.testing.expectError(
        error.ConflictingProgramModes,
        parseProgramMode(&[_][]const u8{
            "incinerator",
            "--s2-visual-smoke",
            "--content-root=/tmp/incinerator-content",
        }),
    );
}

test "district GPU budget backpressure is retryable without blocking logical activation" {
    try std.testing.expect(isRetryableDistrictStageError(error.DistrictStagingBudgetExceeded));
    try std.testing.expect(isRetryableDistrictStageError(error.DistrictResidentBudgetExceeded));
    try std.testing.expect(!isRetryableDistrictStageError(error.OutOfMemory));
    try std.testing.expect(!isRetryableDistrictStageError(error.InvalidSceneMaterial));

    const FakeAdmission = struct {
        events: [2]u8 = undefined,
        count: usize = 0,
        logical_submitted: bool = false,

        fn submitLogical(self: *@This()) !void {
            self.events[self.count] = 1;
            self.count += 1;
            self.logical_submitted = true;
        }

        fn stageBackpressured(self: *@This()) !bool {
            if (!self.logical_submitted) return error.StageRanBeforeLogicalSubmit;
            self.events[self.count] = 2;
            self.count += 1;
            return false;
        }
    };
    var admission = FakeAdmission{};
    try std.testing.expect(!try submitLogicalBeforeStage(
        &admission,
        FakeAdmission.submitLogical,
        FakeAdmission.stageBackpressured,
    ));
    try std.testing.expect(admission.logical_submitted);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, admission.events[0..admission.count]);
}

test "all engine module tests are discovered" {
    // Zig 0.16 analyzes declarations lazily. Explicitly reference each module
    // so its test blocks remain part of the engine test contract.
    std.testing.refAllDecls(@import("camera.zig"));
    std.testing.refAllDecls(@import("sandbox_controls.zig"));
    std.testing.refAllDecls(@import("sandbox_visual_resources.zig"));
    std.testing.refAllDecls(@import("editor/tool.zig"));
    std.testing.refAllDecls(@import("district_gpu_registry.zig"));
    std.testing.refAllDecls(@import("district_scene_adapter.zig"));
    std.testing.refAllDecls(@import("district_presentation"));
    std.testing.refAllDecls(@import("input.zig"));
    std.testing.refAllDecls(@import("mesh.zig"));
    std.testing.refAllDecls(@import("renderer.zig"));
    std.testing.refAllDecls(@import("texture.zig"));
    std.testing.refAllDecls(@import("timing.zig"));
}
