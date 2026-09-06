const std = @import("std");

/// Matches zgui's public backend option so its source module can select the
/// SDL3 GPU Zig adapter without asking zgui to compile against its own, older
/// zsdl header snapshot.
const Backend = enum {
    no_backend,
    glfw_wgpu,
    glfw_opengl3,
    glfw_vulkan,
    glfw_dx12,
    win32_dx12,
    glfw,
    sdl2_opengl3,
    osx_metal,
    sdl2,
    sdl2_renderer,
    sdl3,
    sdl3_opengl3,
    sdl3_vulkan,
    sdl3_renderer,
    sdl3_gpu,
};

pub const Integration = struct {
    module: *std.Build.Module,
    library: *std.Build.Step.Compile,
};

/// Compile the exact-pinned zgui sources as an engine adapter. The crucial
/// ownership rule is that SDL headers come from the same castholm/SDL package
/// whose library the host links; zgui's transitive zsdl package is not used.
pub fn build(
    b: *std.Build,
    zgui: *std.Build.Dependency,
    sdl: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) Integration {
    const options = b.addOptions();
    options.addOption(Backend, "backend", .sdl3_gpu);
    options.addOption(bool, "with_te", false);
    options.addOption(bool, "use_wchar32", false);
    options.addOption(bool, "use_32bit_draw_idx", false);
    options.addOption(bool, "with_gizmo", false);
    options.addOption(bool, "disable_obsolete", true);

    const module = b.createModule(.{
        .root_source_file = zgui.path("src/gui.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zgui_options", .module = options.createModule() }},
    });

    const native = b.createModule(.{
        .target = target,
        .optimize = optimize,
    });
    native.link_libc = true;
    native.link_libcpp = true;

    native.addIncludePath(zgui.path("libs"));
    native.addIncludePath(zgui.path("libs/imgui"));
    native.addIncludePath(sdl.path("include"));

    native.addCMacro("IMGUI_DISABLE_OBSOLETE_FUNCTIONS", "");
    native.addCMacro("IMGUI_IMPL_API", "extern \"C\"");

    const cflags = &.{
        "-fno-sanitize=undefined",
        "-Wno-elaborated-enum-base",
        "-Wno-error=date-time",
    };
    native.addCSourceFiles(.{
        .root = zgui.path(""),
        .files = &.{
            "src/zgui.cpp",
            "libs/imgui/imgui.cpp",
            "libs/imgui/imgui_widgets.cpp",
            "libs/imgui/imgui_tables.cpp",
            "libs/imgui/imgui_draw.cpp",
            "libs/imgui/imgui_demo.cpp",
            "libs/imgui/backends/imgui_impl_sdl3.cpp",
            "libs/imgui/backends/imgui_impl_sdlgpu3.cpp",
        },
        .flags = cflags,
    });
    native.addCSourceFile(.{ .file = b.path("src/editor/imgui_pointer.cpp"), .flags = cflags });

    const library = b.addLibrary(.{
        .name = "incinerator_imgui",
        .linkage = .static,
        .root_module = native,
    });

    return .{ .module = module, .library = library };
}
