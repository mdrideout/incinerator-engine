const std = @import("std");
const zgui_sdl3_gpu = @import("tools/build/zgui_sdl3_gpu.zig");

const WindowsGpu = enum {
    d3d12,
    vulkan,
};

const FlecsDebugMode = enum {
    sanitize,
    debug,
    depends_on_build,
    none,
};

// Although this function looks imperative, it does not perform the build
// directly and instead it mutates the build graph (`b`) that will be then
// executed by an external runner. The functions in `std.Build` implement a DSL
// for defining build steps and express dependencies between them, allowing the
// build runner to parallelize the build automatically (and the cache system to
// know when a step doesn't need to be re-run).
pub fn build(b: *std.Build) void {
    // Standard target options allow the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});
    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});
    const flecs_debug_mode: FlecsDebugMode = if (optimize == .Debug) .sanitize else .none;
    const glslc_path = b.option(
        []const u8,
        "glslc",
        "Path to the host glslc executable",
    ) orelse "glslc";
    const spirv_cross_path = b.option(
        []const u8,
        "spirv-cross",
        "Path to the host spirv-cross executable",
    ) orelse "spirv-cross";
    const shadercross_path = b.option(
        []const u8,
        "shadercross",
        "Path to the host SDL_shadercross executable used for DXIL",
    ) orelse "shadercross";
    const windows_gpu = b.option(
        WindowsGpu,
        "windows-gpu",
        "Windows SDL GPU backend (d3d12 is the support target; vulkan is a bootstrap fallback)",
    ) orelse .d3d12;

    // ---------------------------------------------------------
    // Editor Build Option
    // ---------------------------------------------------------
    // The editor (ImGui debug UI and tools) is enabled by default in Debug
    // builds but can be explicitly disabled. In Release builds, it defaults to
    // off but can be explicitly enabled for profiling/debugging release builds.
    //
    // Usage:
    //   zig build                    # Debug with editor
    //   zig build -Deditor=false     # Debug without editor
    //   zig build -Doptimize=ReleaseFast              # Release without editor
    //   zig build -Doptimize=ReleaseFast -Deditor=true # Release with editor
    const default_editor_enabled = optimize == .Debug;
    const editor_enabled = b.option(
        bool,
        "editor",
        "Enable the editor UI (ImGui tools). Defaults to true in Debug, false in Release.",
    ) orelse default_editor_enabled;

    // It's also possible to define more custom flags to toggle optional features
    // of this build script using `b.option()`. All defined flags (including
    // target and optimize options) will be listed when running `zig build --help`
    // in this directory.

    // This creates a module, which represents a collection of source files alongside
    // some compilation options, such as optimization mode and linked system libraries.
    // Zig modules are the preferred way of making Zig code available to consumers.
    // addModule defines a module that we intend to make available for importing
    // to our consumers. We must give it a name because a Zig package can expose
    // multiple modules and consumers will need to be able to specify which
    // module they want to access.
    const contracts_module = b.createModule(.{
        .root_source_file = b.path("src/engine/contracts.zig"),
        .target = target,
        .optimize = optimize,
    });

    const mod = b.addModule("incinerator_engine", .{
        // The root source file is the "entry point" of this module. Users of
        // this module will only be able to access public declarations contained
        // in this file, which means that if you have declarations that you
        // intend to expose to consumers that were defined in other files part
        // of this module, you will have to make sure to re-export them from
        // the root file.
        .root_source_file = b.path("src/root.zig"),
        // Later on we'll use this module as the root module of a test executable
        // which requires us to specify a target.
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("engine_contracts", contracts_module);

    // Here we define an executable. An executable needs to have a root module
    // which needs to expose a `main` function. While we could add a main function
    // to the module defined above, it's sometimes preferable to split business
    // logic and the CLI into two separate modules.
    //
    // If your goal is to create a Zig library for others to use, consider if
    // it might benefit from also exposing a CLI tool. A parser library for a
    // data serialization format could also bundle a CLI syntax checker, for example.
    //
    // If instead your goal is to create an executable, consider if users might
    // be interested in also being able to embed the core functionality of your
    // program in their own executable in order to avoid the overhead involved in
    // subprocessing your CLI tool.
    //
    // If neither case applies to you, feel free to delete the declaration you
    // don't need and to put everything under a single module.
    // ---------------------------------------------------------
    // Build Options Module
    // ---------------------------------------------------------
    // Creates an importable module containing build-time configuration.
    // Code can access these via: const options = @import("build_options");
    const options = b.addOptions();
    options.addOption(bool, "editor_enabled", editor_enabled);

    const exe = b.addExecutable(.{
        .name = "incinerator_engine",
        .root_module = b.createModule(.{
            // b.createModule defines a new module just like b.addModule but,
            // unlike b.addModule, it does not expose the module to consumers of
            // this package, which is why in this case we don't have to give it a name.
            .root_source_file = b.path("src/main.zig"),
            // Target and optimization levels must be explicitly wired in when
            // defining an executable or library (in the root module), and you
            // can also hardcode a specific target for an executable or library
            // definition if desireable (e.g. firmware for embedded devices).
            .target = target,
            .optimize = optimize,
            // List of modules available for import in source files part of the
            // root module.
            .imports = &.{
                // Here "incinerator_engine" is the name you will use in your source code to
                // import this module (e.g. `@import("incinerator_engine")`). The name is
                // repeated because you are allowed to rename your imports, which
                // can be extremely useful in case of collisions (which can happen
                // importing modules from different packages).
                .{ .name = "incinerator_engine", .module = mod },
                // Build options module - provides compile-time access to build flags
                .{ .name = "build_options", .module = options.createModule() },
            },
        }),
    });

    // ---------------------------------------------------------
    // SDL3 (castholm/SDL)
    // ---------------------------------------------------------
    const sdl_dep = b.dependency("sdl", .{
        .target = target,
        .optimize = optimize,
        .preferred_linkage = .static,
        //.strip = null,
        //.sanitize_c = null,
        //.pic = null,
        //.lto = null,
        //.emscripten_pthreads = false,
        //.install_build_config_h = false,
    });
    const sdl_lib = sdl_dep.artifact("SDL3");
    exe.root_module.linkLibrary(sdl_lib);

    // ---------------------------------------------------------
    // Jolt Physics 5.5 through the engine-owned JoltC build package.
    // ---------------------------------------------------------
    const joltc = b.dependency("joltc", .{
        .target = target,
        .optimize = optimize,
        .cross_platform_deterministic = false,
    });
    const jolt_c_module = b.createModule(.{
        .root_source_file = b.path("src/adapters/physics/jolt_c.zig"),
        .target = target,
        .optimize = optimize,
    });
    jolt_c_module.linkLibrary(joltc.artifact("joltc"));
    const jolt_physics_module = b.createModule(.{
        .root_source_file = b.path("src/physics.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "engine_contracts", .module = contracts_module },
            .{ .name = "jolt_c", .module = jolt_c_module },
        },
    });
    // ---------------------------------------------------------
    // ImGui (zgui) debug UI
    // ---------------------------------------------------------
    // zgui wraps Dear ImGui for immediate-mode debug UI.
    // We use the SDL3 GPU backend to integrate with our existing renderer.
    // Available backends: no_backend, glfw_opengl3, glfw_wgpu, sdl3_gpu, etc.
    if (editor_enabled) {
        const zgui = b.lazyDependency("zgui", .{
            .target = target,
            .optimize = optimize,
            .shared = false,
            .with_implot = true,
            .with_gizmo = false,
            .with_node_editor = false,
            .with_te = false,
            .with_freetype = false,
            .with_knobs = false,
            .use_wchar32 = false,
            .use_32bit_draw_idx = false,
            .disable_obsolete = true,
            // The engine owns the backend compilation below so it can use the
            // same SDL 3.4.12 headers as the runtime library. Upstream zgui's
            // sdl3_gpu option currently pulls an independent SDL 3.2 snapshot.
            .backend = .no_backend,
        }) orelse return;
        const editor_gui = zgui_sdl3_gpu.build(b, zgui, sdl_dep, target, optimize);
        exe.root_module.addImport("zgui", editor_gui.module);
        exe.root_module.linkLibrary(editor_gui.library);
    }

    // ---------------------------------------------------------
    // Math (zmath)
    // ---------------------------------------------------------
    const zmath = b.dependency("zmath", .{
        .target = target,
        .optimize = optimize,
        .enable_cross_platform_determinism = true,
    });
    exe.root_module.addImport("zmath", zmath.module("root"));

    // ---------------------------------------------------------
    // Mesh Loading (zmesh) - glTF/GLB loader + mesh utilities
    // ---------------------------------------------------------
    // zmesh wraps cgltf for glTF loading and meshoptimizer for optimization.
    // Used to load 3D models exported from Blender, AI generators, etc.
    const zmesh = b.dependency("zmesh", .{
        .target = target,
        .optimize = optimize,
        .shape_use_32bit_indices = true,
        .shared = false,
    });
    exe.root_module.addImport("zmesh", zmesh.module("root"));
    exe.root_module.linkLibrary(zmesh.artifact("zmesh"));

    // ---------------------------------------------------------
    // Image Loading (zstbi) - stb_image wrapper
    // ---------------------------------------------------------
    // Used to decode PNG/JPEG textures embedded in GLB files.
    const zstbi = b.dependency("zstbi", .{
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("zstbi", zstbi.module("root"));

    // ---------------------------------------------------------
    // ECS (zflecs) - Entity Component System
    // ---------------------------------------------------------
    // zflecs is the kernel-private storage implementation used by registered
    // feature components. Flecs APIs/IDs are not imported by the visual host
    // or exposed as the engine's identity/persistence contract.
    const zflecs = b.dependency("zflecs", .{
        .target = target,
        .optimize = optimize,
        .shared = false,
        .debug_mode = flecs_debug_mode,
        .debug_info = false,
        .float_t = .fp32,
        .ftime_t = .fp32,
        .accurate_counters = false,
        .disable_counters = false,
        .soft_assert = false,
        .keep_assert = false,
        .default_to_uncached_queries = false,
        .no_always_inline = false,
        .custom_build = .whitelist,
        .toggle_alerts_addon = true,
        .toggle_app_addon = true,
        .toggle_doc_addon = true,
        .toggle_json_addon = true,
        .toggle_http_addon = true,
        .toggle_log_addon = true,
        .toggle_meta_addon = true,
        .toggle_metrics_addon = true,
        .toggle_module_addon = true,
        .toggle_os_api_impl_addon = true,
        .toggle_pipeline_addon = true,
        .toggle_rest_addon = true,
        .toggle_parser_addon = true,
        .toggle_query_dsl_addon = true,
        .toggle_script_addon = true,
        .toggle_system_addon = true,
        .toggle_stats_addon = true,
        .toggle_timer_addon = true,
        .toggle_units_addon = true,
        .low_footprint = false,
        // zflecs currently always compiles C with FLECS_USE_OS_ALLOC. Passing
        // true keeps the generated Zig layout in lockstep with that C ABI.
        .use_os_alloc = true,
        .hi_component_id = 256,
        .hi_id_record_id = 1024,
        .sparse_page_bits = 6,
        .entity_page_bits = 10,
        .id_desc_max = 32,
        .event_desc_max = 8,
        .variable_count_max = 64,
        .term_count_max = 32,
        .term_arg_count_max = 16,
        .query_variable_count_max = 64,
        .query_scope_nesting_max = 8,
        .dag_depth_max = 128,
    });
    const zflecs_module = zflecs.module("root");
    mod.addImport("zflecs", zflecs_module);

    // Gameplay features see only the public kernel/contracts module; the
    // sandbox simulation host is the sole place where they are paired with Jolt.
    const crate_feature_module = b.createModule(.{
        .root_source_file = b.path("src/features/crates/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "incinerator_engine", .module = mod },
        },
    });
    const character_feature_module = b.createModule(.{
        .root_source_file = b.path("src/features/character/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "incinerator_engine", .module = mod },
        },
    });
    const sandbox_controls_module = b.createModule(.{
        .root_source_file = b.path("src/sandbox_controls.zig"),
        .target = target,
        .optimize = optimize,
    });
    const sandbox_simulation_module = b.createModule(.{
        .root_source_file = b.path("src/hosts/simulation.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "incinerator_engine", .module = mod },
            .{ .name = "crate_feature", .module = crate_feature_module },
            .{ .name = "character_feature", .module = character_feature_module },
            .{ .name = "jolt_physics", .module = jolt_physics_module },
        },
    });
    exe.root_module.addImport("sandbox_simulation", sandbox_simulation_module);
    // zflecs's exported module already owns flecs.c. Linking its library too
    // compiles the amalgamation twice and relies on archive laziness to hide
    // duplicate symbols. Keep one C owner and add the library's Windows system
    // dependencies explicitly.
    if (target.result.os.tag == .windows) {
        mod.linkSystemLibrary("ws2_32", .{});
        mod.linkSystemLibrary("dbghelp", .{});
        exe.root_module.linkSystemLibrary("ws2_32", .{});
        exe.root_module.linkSystemLibrary("dbghelp", .{});
    }

    // unsure if need these
    // { // Needed for glfw/wgpu rendering backend
    //     const zglfw = b.dependency("zglfw", .{});
    //     exe.root_module.addImport("zglfw", zglfw.module("root"));
    //     exe.linkLibrary(zglfw.artifact("glfw"));

    //     const zpool = b.dependency("zpool", .{});
    //     exe.root_module.addImport("zpool", zpool.module("root"));

    //     const zgpu = b.dependency("zgpu", .{});
    //     exe.root_module.addImport("zgpu", zgpu.module("root"));
    //     exe.linkLibrary(zgpu.artifact("zdawn"));
    // }

    // ---------------------------------------------------------
    // Shader Compilation (GLSL → target backend format)
    // ---------------------------------------------------------
    // Shader outputs live in the Zig cache and are exposed as a generated
    // module. This makes the exact generated files dependencies of every
    // executable/test compilation that embeds them without mutating `src/`.
    const shaders = buildShaders(b, target, optimize, .{
        .glslc = glslc_path,
        .spirv_cross = spirv_cross_path,
        .shadercross = shadercross_path,
        .windows_gpu = windows_gpu,
    });
    exe.root_module.addImport("shader_assets", shaders.module);
    exe.step.dependOn(shaders.step);

    const shader_contract_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/shader_contract_test.zig"),
            .target = b.graph.host,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "shader_reflections", .module = shaders.reflection_module },
                .{ .name = "shader_assets", .module = shaders.validation_module },
            },
        }),
    });
    const run_shader_contract_tests = b.addRunArtifact(shader_contract_tests);
    const shader_test_step = b.step("test-shaders", "Validate SDL GPU shader contracts");
    shader_test_step.dependOn(&run_shader_contract_tests.step);

    // The headless host is intentionally not installed by the default build.
    // Its allowlisted module graph has no SDL, editor, asset, or shader edge.
    const headless_root_module = b.createModule(.{
        .root_source_file = b.path("src/hosts/headless.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sandbox_simulation", .module = sandbox_simulation_module },
        },
    });
    const headless_exe = b.addExecutable(.{
        .name = "incinerator_headless",
        .root_module = headless_root_module,
    });
    const check_headless_step = b.step(
        "check-headless",
        "Compile the SDL-free sandbox simulation host",
    );
    check_headless_step.dependOn(&headless_exe.step);

    const install_headless_artifact = b.addInstallArtifact(headless_exe, .{});
    const install_headless_step = b.step(
        "install-headless",
        "Install only the SDL-free sandbox simulation host",
    );
    install_headless_step.dependOn(&install_headless_artifact.step);

    const headless_boundary_exe = b.addExecutable(.{
        .name = "headless_boundary_test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/headless_boundary_test.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    const verify_headless_boundary = b.addRunArtifact(headless_boundary_exe);
    verify_headless_boundary.setCwd(b.path("."));
    const verify_headless_boundary_step = b.step(
        "verify-headless-boundary",
        "Reject visual imports from the headless source graph",
    );
    verify_headless_boundary_step.dependOn(&verify_headless_boundary.step);

    const headless_linkage_exe = b.addExecutable(.{
        .name = "headless_linkage_test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/headless_linkage_test.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    const verify_headless_linkage = b.addRunArtifact(headless_linkage_exe);
    verify_headless_linkage.addFileArg(headless_exe.getEmittedBin());
    const verify_headless_linkage_step = b.step(
        "verify-headless-linkage",
        "Reject visual dependencies from the final headless binary",
    );
    verify_headless_linkage_step.dependOn(&verify_headless_linkage.step);

    const headless_boundary_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/headless_boundary_test.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    const run_headless_boundary_tests = b.addRunArtifact(headless_boundary_tests);
    const headless_linkage_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/headless_linkage_test.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    const run_headless_linkage_tests = b.addRunArtifact(headless_linkage_tests);
    const headless_tool_test_step = b.step(
        "test-headless-tools",
        "Run portable headless boundary verifier tests",
    );
    headless_tool_test_step.dependOn(&run_headless_boundary_tests.step);
    headless_tool_test_step.dependOn(&run_headless_linkage_tests.step);

    const run_headless_cmd = b.addRunArtifact(headless_exe);
    if (b.args) |args| run_headless_cmd.addArgs(args);
    const run_headless_step = b.step("run-headless", "Run the SDL-free sandbox simulation host");
    run_headless_step.dependOn(&run_headless_cmd.step);

    // Native, record-only S0 characterization. Timings are intentionally not
    // test thresholds; CI validates and logs the JSON report for comparison on
    // stable hardware.
    const s0_measure_root_module = b.createModule(.{
        .root_source_file = b.path("tools/s0_measure.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sandbox_simulation", .module = sandbox_simulation_module },
        },
    });
    const s0_measure_exe = b.addExecutable(.{
        .name = "incinerator_s0_measure",
        .root_module = s0_measure_root_module,
    });
    const run_s0_measure = b.addRunArtifact(s0_measure_exe);
    if (b.args) |args| run_s0_measure.addArgs(args);
    const s0_measure_step = b.step(
        "measure-s0",
        "Record SDL-free S0 lifecycle timings as versioned JSON",
    );
    s0_measure_step.dependOn(&run_s0_measure.step);

    const s1_measure_root_module = b.createModule(.{
        .root_source_file = b.path("tools/s1_measure.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sandbox_simulation", .module = sandbox_simulation_module },
        },
    });
    const s1_measure_exe = b.addExecutable(.{
        .name = "incinerator_s1_measure",
        .root_module = s1_measure_root_module,
    });
    const run_s1_measure = b.addRunArtifact(s1_measure_exe);
    if (b.args) |args| run_s1_measure.addArgs(args);
    const s1_measure_step = b.step(
        "measure-s1",
        "Record SDL-free S1 character slice timings as versioned JSON",
    );
    s1_measure_step.dependOn(&run_s1_measure.step);
    const s1_measure_tests = b.addTest(.{ .root_module = s1_measure_root_module });
    const run_s1_measure_tests = b.addRunArtifact(s1_measure_tests);

    const headless_tests = b.addTest(.{ .root_module = headless_root_module });
    const run_headless_tests = b.addRunArtifact(headless_tests);
    const headless_test_step = b.step(
        "test-headless",
        "Run the isolated Flecs/Jolt crate and character lifecycle tests",
    );
    headless_test_step.dependOn(&run_headless_tests.step);
    headless_test_step.dependOn(&verify_headless_boundary.step);
    headless_test_step.dependOn(&verify_headless_linkage.step);
    headless_test_step.dependOn(&run_headless_boundary_tests.step);
    headless_test_step.dependOn(&run_headless_linkage_tests.step);

    // This declares intent for the executable to be installed into the
    // install prefix when running `zig build` (i.e. when executing the default
    // step). By default the install prefix is `zig-out/` but can be overridden
    // by passing `--prefix` or `-p`.
    b.installArtifact(exe);

    // This creates a top level step. Top level steps have a name and can be
    // invoked by name when running `zig build` (e.g. `zig build run`).
    // This will evaluate the `run` step rather than the default step.
    // For a top level step to actually do something, it must depend on other
    // steps (e.g. a Run step, as we will see in a moment).
    const run_step = b.step("run", "Run the app");

    // This creates a RunArtifact step in the build graph. A RunArtifact step
    // invokes an executable compiled by Zig. Steps will only be executed by the
    // runner if invoked directly by the user (in the case of top level steps)
    // or if another step depends on it, so it's up to you to define when and
    // how this Run step will be executed. In our case we want to run it when
    // the user runs `zig build run`, so we create a dependency link.
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    // By making the run step depend on the default step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Creates an executable that will run `test` blocks from the provided module.
    // Here `mod` needs to define a target, which is why earlier we made sure to
    // set the releative field.
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const contracts_tests = b.addTest(.{ .root_module = contracts_module });
    const run_contracts_tests = b.addRunArtifact(contracts_tests);
    const contracts_test_step = b.step(
        "test-contracts",
        "Run backend-neutral contract tests",
    );
    contracts_test_step.dependOn(&run_contracts_tests.step);

    // A run step that will run the test executable.
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const kernel_test_step = b.step("test-kernel", "Run the SDL-free public kernel tests");
    kernel_test_step.dependOn(&run_mod_tests.step);

    const crate_feature_tests = b.addTest(.{ .root_module = crate_feature_module });
    const run_crate_feature_tests = b.addRunArtifact(crate_feature_tests);
    const crate_feature_test_step = b.step(
        "test-crate-feature",
        "Run the backend-neutral crate feature tests",
    );
    crate_feature_test_step.dependOn(&run_crate_feature_tests.step);

    const character_feature_tests = b.addTest(.{ .root_module = character_feature_module });
    const run_character_feature_tests = b.addRunArtifact(character_feature_tests);
    const character_feature_test_step = b.step(
        "test-character-feature",
        "Run the backend-neutral character feature tests",
    );
    character_feature_test_step.dependOn(&run_character_feature_tests.step);

    const sandbox_controls_tests = b.addTest(.{ .root_module = sandbox_controls_module });
    const run_sandbox_controls_tests = b.addRunArtifact(sandbox_controls_tests);
    const sandbox_controls_test_step = b.step(
        "test-sandbox-controls",
        "Run frame-to-tick action latch tests",
    );
    sandbox_controls_test_step.dependOn(&run_sandbox_controls_tests.step);

    const sandbox_simulation_tests = b.addTest(.{ .root_module = sandbox_simulation_module });
    const run_sandbox_simulation_tests = b.addRunArtifact(sandbox_simulation_tests);
    const sandbox_simulation_test_step = b.step(
        "test-simulation",
        "Run the concrete sandbox/Jolt composition tests",
    );
    sandbox_simulation_test_step.dependOn(&run_sandbox_simulation_tests.step);

    // Creates an executable that will run `test` blocks from the executable's
    // root module. Note that test executables only test one module at a time,
    // hence why we have to create two separate ones.
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    // A run step that will run the second test executable.
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // Keep the Jolt adapter independently testable. This target intentionally
    // links no SDL, renderer, shader, or editor dependencies.
    const physics_tests = b.addTest(.{ .root_module = jolt_physics_module });
    const run_physics_tests = b.addRunArtifact(physics_tests);
    const physics_test_step = b.step("test-physics", "Run isolated Jolt adapter tests");
    physics_test_step.dependOn(&run_physics_tests.step);

    // A top level step for running all tests. dependOn can be called multiple
    // times and since the two run steps do not depend on one another, this will
    // make the two of them run in parallel.
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_contracts_tests.step);
    test_step.dependOn(&run_crate_feature_tests.step);
    test_step.dependOn(&run_character_feature_tests.step);
    test_step.dependOn(&run_sandbox_controls_tests.step);
    test_step.dependOn(&run_sandbox_simulation_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_physics_tests.step);
    test_step.dependOn(&run_headless_tests.step);
    test_step.dependOn(&run_shader_contract_tests.step);
    test_step.dependOn(&verify_headless_boundary.step);
    test_step.dependOn(&verify_headless_linkage.step);
    test_step.dependOn(&run_headless_boundary_tests.step);
    test_step.dependOn(&run_headless_linkage_tests.step);
    test_step.dependOn(&s0_measure_exe.step);
    test_step.dependOn(&s1_measure_exe.step);
    test_step.dependOn(&run_s1_measure_tests.step);

    // Just like flags, top level steps are also listed in the `--help` menu.
    //
    // The Zig build system is entirely implemented in userland, which means
    // that it cannot hook into private compiler APIs. All compilation work
    // orchestrated by the build system will result in other Zig compiler
    // subcommands being invoked with the right flags defined. You can observe
    // these invocations when one fails (or you pass a flag to increase
    // verbosity) to validate assumptions and diagnose problems.
    //
    // Lastly, the Zig build system is relatively simple and self-contained,
    // and reading its source code will allow you to master it.
}

// =============================================================================
// Shader Compilation
// =============================================================================
// Compiles GLSL shaders into the format consumed by the selected target's SDL
// GPU backend. Windows defaults to D3D12/DXIL and exposes Vulkan/SPIR-V only as
// an explicit fallback; the renderer advertises only the format built.

const ShaderFormat = enum {
    msl,
    spirv,
    dxil,

    fn fileExtension(self: ShaderFormat) []const u8 {
        return switch (self) {
            .msl => "metal",
            .spirv => "spv",
            .dxil => "dxil",
        };
    }

    fn entrypoint(self: ShaderFormat) []const u8 {
        return switch (self) {
            .msl => "main0",
            .spirv, .dxil => "main",
        };
    }

    fn driver(self: ShaderFormat) []const u8 {
        return switch (self) {
            .msl => "metal",
            .spirv => "vulkan",
            .dxil => "direct3d12",
        };
    }
};

const ShaderStage = enum {
    vertex,
    fragment,

    fn shadercrossName(self: ShaderStage) []const u8 {
        return switch (self) {
            .vertex => "vertex",
            .fragment => "fragment",
        };
    }
};

const ShaderBuild = struct {
    module: *std.Build.Module,
    validation_module: *std.Build.Module,
    reflection_module: *std.Build.Module,
    step: *std.Build.Step,
};

const ShaderTools = struct {
    glslc: []const u8,
    spirv_cross: []const u8,
    shadercross: []const u8,
    windows_gpu: WindowsGpu,
};

const CompiledShader = struct {
    spirv: std.Build.LazyPath,
    target: std.Build.LazyPath,
};

fn buildShaders(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    tools: ShaderTools,
) ShaderBuild {
    const format: ShaderFormat = switch (target.result.os.tag) {
        .macos => .msl,
        .linux => .spirv,
        .windows => switch (tools.windows_gpu) {
            .d3d12 => .dxil,
            .vulkan => .spirv,
        },
        else => @panic("unsupported target: Incinerator shaders support macOS, Linux, and Windows only"),
    };

    const shader_step = b.step("shaders", "Compile shaders for the selected target backend");
    const generated = b.addWriteFiles();

    const triangle_vertex = compileShader(b, tools, "shaders/triangle.vert", "triangle.vert", .vertex, format);
    const triangle_fragment = compileShader(b, tools, "shaders/triangle.frag", "triangle.frag", .fragment, format);
    const model_vertex = compileShader(b, tools, "shaders/model.vert", "model.vert", .vertex, format);
    const model_fragment = compileShader(b, tools, "shaders/model.frag", "model.frag", .fragment, format);

    const extension = format.fileExtension();
    _ = generated.addCopyFile(triangle_vertex.target, b.fmt("triangle.vert.{s}", .{extension}));
    _ = generated.addCopyFile(triangle_fragment.target, b.fmt("triangle.frag.{s}", .{extension}));
    _ = generated.addCopyFile(model_vertex.target, b.fmt("model.vert.{s}", .{extension}));
    _ = generated.addCopyFile(model_fragment.target, b.fmt("model.frag.{s}", .{extension}));

    _ = generated.addCopyFile(reflectShader(b, tools, triangle_vertex.spirv, "triangle.vert"), "triangle.vert.json");
    _ = generated.addCopyFile(reflectShader(b, tools, triangle_fragment.spirv, "triangle.frag"), "triangle.frag.json");
    _ = generated.addCopyFile(reflectShader(b, tools, model_vertex.spirv, "model.vert"), "model.vert.json");
    _ = generated.addCopyFile(reflectShader(b, tools, model_fragment.spirv, "model.frag"), "model.frag.json");

    const module_source = generated.add("shader_assets.zig", b.fmt(
        \\pub const Format = enum {{ msl, spirv, dxil }};
        \\pub const format: Format = .{s};
        \\pub const entrypoint = "{s}";
        \\pub const driver = "{s}";
        \\pub const triangle_vertex = @embedFile("triangle.vert.{s}");
        \\pub const triangle_fragment = @embedFile("triangle.frag.{s}");
        \\pub const model_vertex = @embedFile("model.vert.{s}");
        \\pub const model_fragment = @embedFile("model.frag.{s}");
        \\
    , .{
        @tagName(format),
        format.entrypoint(),
        format.driver(),
        extension,
        extension,
        extension,
        extension,
    }));

    const reflection_source = generated.add("shader_reflections.zig",
        \\pub const triangle_vertex = @embedFile("triangle.vert.json");
        \\pub const triangle_fragment = @embedFile("triangle.frag.json");
        \\pub const model_vertex = @embedFile("model.vert.json");
        \\pub const model_fragment = @embedFile("model.frag.json");
        \\
    );

    shader_step.dependOn(&generated.step);

    return .{
        .module = b.createModule(.{
            .root_source_file = module_source,
            .target = target,
            .optimize = optimize,
        }),
        .validation_module = b.createModule(.{
            .root_source_file = module_source,
            .target = b.graph.host,
            .optimize = optimize,
        }),
        .reflection_module = b.createModule(.{
            .root_source_file = reflection_source,
            .target = b.graph.host,
            .optimize = optimize,
        }),
        .step = shader_step,
    };
}

fn compileShader(
    b: *std.Build,
    tools: ShaderTools,
    source_path: []const u8,
    output_name: []const u8,
    stage: ShaderStage,
    format: ShaderFormat,
) CompiledShader {
    const glslc = b.addSystemCommand(&.{tools.glslc});
    glslc.addFileArg(b.path(source_path));
    glslc.addArg("-o");
    const spirv = glslc.addOutputFileArg(b.fmt("{s}.spv", .{output_name}));

    if (format == .spirv) return .{ .spirv = spirv, .target = spirv };

    if (format == .dxil) {
        const shadercross = b.addSystemCommand(&.{tools.shadercross});
        shadercross.addFileArg(spirv);
        shadercross.addArgs(&.{
            "-s",
            "SPIRV",
            "-d",
            "DXIL",
            "-t",
            stage.shadercrossName(),
            "-e",
            "main",
            "-o",
        });
        return .{
            .spirv = spirv,
            .target = shadercross.addOutputFileArg(b.fmt("{s}.dxil", .{output_name})),
        };
    }

    const spirv_cross = b.addSystemCommand(&.{tools.spirv_cross});
    spirv_cross.addFileArg(spirv);
    spirv_cross.addArg("--msl");
    spirv_cross.addArg("--output");
    return .{
        .spirv = spirv,
        .target = spirv_cross.addOutputFileArg(b.fmt("{s}.metal", .{output_name})),
    };
}

fn reflectShader(
    b: *std.Build,
    tools: ShaderTools,
    spirv: std.Build.LazyPath,
    output_name: []const u8,
) std.Build.LazyPath {
    const spirv_cross = b.addSystemCommand(&.{tools.spirv_cross});
    spirv_cross.addFileArg(spirv);
    spirv_cross.addArg("--reflect");
    spirv_cross.addArg("--output");
    return spirv_cross.addOutputFileArg(b.fmt("{s}.json", .{output_name}));
}
