const std = @import("std");

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

    // ---------------------------------------------------------
    // Editor Build Option
    // ---------------------------------------------------------
    // The editor (ImGui debug UI, gizmos, tools) is enabled by default in Debug
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
        "Enable the editor UI (ImGui tools, gizmos). Defaults to true in Debug, false in Release.",
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
    });

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
        //.preferred_linkage = .static,
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
    // Jolt Physics (zphysics)
    // ---------------------------------------------------------
    const zphysics = b.dependency("zphysics", .{
        .use_double_precision = false,
        .enable_cross_platform_determinism = true,
    });
    exe.root_module.addImport("zphysics", zphysics.module("root"));
    exe.linkLibrary(zphysics.artifact("joltc"));

    // ---------------------------------------------------------
    // ImGui (zgui)
    // ---------------------------------------------------------
    // zgui wraps Dear ImGui for immediate-mode debug UI.
    // We use the SDL3 GPU backend to integrate with our existing renderer.
    // Available backends: no_backend, glfw_opengl3, glfw_wgpu, sdl3_gpu, etc.
    const zgui = b.dependency("zgui", .{
        .shared = false,
        .with_implot = true,
        .backend = .sdl3_gpu, // Use SDL3's GPU API for rendering ImGui
    });
    exe.root_module.addImport("zgui", zgui.module("root"));
    exe.linkLibrary(zgui.artifact("imgui"));

    // ---------------------------------------------------------
    // Math (zmath)
    // ---------------------------------------------------------
    const zmath = b.dependency("zmath", .{});
    exe.root_module.addImport("zmath", zmath.module("root"));

    // ---------------------------------------------------------
    // Mesh Loading (zmesh) - glTF/GLB loader + mesh utilities
    // ---------------------------------------------------------
    // zmesh wraps cgltf for glTF loading and meshoptimizer for optimization.
    // Used to load 3D models exported from Blender, AI generators, etc.
    const zmesh = b.dependency("zmesh", .{});
    exe.root_module.addImport("zmesh", zmesh.module("root"));
    exe.linkLibrary(zmesh.artifact("zmesh"));

    // ---------------------------------------------------------
    // Image Loading (zstbi) - stb_image wrapper
    // ---------------------------------------------------------
    // Used to decode PNG/JPEG textures embedded in GLB files.
    const zstbi = b.dependency("zstbi", .{});
    exe.root_module.addImport("zstbi", zstbi.module("root"));

    // ---------------------------------------------------------
    // ECS (zflecs) - Entity Component System
    // ---------------------------------------------------------
    // zflecs wraps the flecs ECS library for high-performance entity management.
    // Used for all game entities: vehicles, NPCs, props, debris, particles.
    // Archetype-based storage provides cache-friendly iteration for physics sync.
    const zflecs = b.dependency("zflecs", .{});
    exe.root_module.addImport("zflecs", zflecs.module("root"));
    exe.linkLibrary(zflecs.artifact("flecs"));

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
    // Shader Compilation (GLSL → SPIR-V → MSL/HLSL)
    // ---------------------------------------------------------
    // Compiles all shader formats at build time for cross-platform support.
    // See docs/adr/001-shader-language-and-compilation.md for rationale.
    const shader_step = buildShaders(b);
    exe.step.dependOn(shader_step);

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

    // A run step that will run the test executable.
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // Creates an executable that will run `test` blocks from the executable's
    // root module. Note that test executables only test one module at a time,
    // hence why we have to create two separate ones.
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    // A run step that will run the second test executable.
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // A top level step for running all tests. dependOn can be called multiple
    // times and since the two run steps do not depend on one another, this will
    // make the two of them run in parallel.
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

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
// Compiles GLSL shaders to all platform formats (SPIR-V, MSL, HLSL).
// This runs at build time so all formats are always available.

/// List of shaders to compile (without extension)
const shader_sources = [_][]const u8{
    "triangle", // Colored primitives (pos + color)
    "model", // Loaded 3D models (pos + normal + uv)
};

/// Shader stages and their file extensions
const ShaderStage = enum {
    vertex,
    fragment,

    fn extension(self: ShaderStage) []const u8 {
        return switch (self) {
            .vertex => ".vert",
            .fragment => ".frag",
        };
    }
};

const shader_stages = [_]ShaderStage{ .vertex, .fragment };

/// Build all shaders and return a step that depends on all compilation commands
fn buildShaders(b: *std.Build) *std.Build.Step {
    const shader_compile_step = b.step("shaders", "Compile GLSL shaders to SPIR-V and platform formats");

    // Create output directory inside src/ (required for @embedFile to work)
    const mkdir_cmd = b.addSystemCommand(&.{
        "mkdir",
        "-p",
        "src/shaders/compiled",
    });
    shader_compile_step.dependOn(&mkdir_cmd.step);

    // Process each shader
    for (shader_sources) |shader_name| {
        // Process each stage (vertex, fragment)
        for (shader_stages) |stage| {
            const ext = stage.extension();

            // Input: shaders/triangle.vert
            const input_path = b.fmt("shaders/{s}{s}", .{ shader_name, ext });

            // Output paths (inside src/ for @embedFile access)
            const spv_output = b.fmt("src/shaders/compiled/{s}{s}.spv", .{ shader_name, ext });
            const msl_output = b.fmt("src/shaders/compiled/{s}{s}.metal", .{ shader_name, ext });

            // Step 1: GLSL → SPIR-V (using glslc)
            const glslc_cmd = b.addSystemCommand(&.{
                "glslc",
                input_path,
                "-o",
                spv_output,
            });
            // Ensure directory exists before compiling
            glslc_cmd.step.dependOn(&mkdir_cmd.step);

            // Step 2: SPIR-V → MSL (using spirv-cross)
            const spirv_cross_msl = b.addSystemCommand(&.{
                "spirv-cross",
                "--msl",
                spv_output,
                "--output",
                msl_output,
            });
            // MSL depends on SPIR-V being generated first
            spirv_cross_msl.step.dependOn(&glslc_cmd.step);

            // Add to the shader compile step
            shader_compile_step.dependOn(&spirv_cross_msl.step);
        }
    }

    return shader_compile_step;
}
