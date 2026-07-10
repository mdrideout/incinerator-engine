//! Portable final-binary check for prohibited visual dependencies.

const std = @import("std");

const prohibited_markers = [_][]const u8{
    "sdl_",
    "sdl3",
    "libsdl",
    "imgui",
    "cgltf",
    "stbi_",
    "meshopt_",
    "metal.framework",
    "quartzcore.framework",
    "appkit.framework",
    "libvulkan",
    "vulkan-1.dll",
    "libx11",
    "libwayland",
    "libgl.so",
    "libegl",
    "d3d12.dll",
    "dxgi.dll",
    "dxcompiler.dll",
    "opengl32.dll",
    "user32.dll",
    "gdi32.dll",
};

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();

    _ = args.next() orelse return error.MissingExecutableName;
    const binary_path = args.next() orelse return error.MissingHeadlessBinary;
    if (args.next() != null) return error.UnexpectedArgument;

    const binary = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        binary_path,
        init.gpa,
        .limited(512 * 1024 * 1024),
    );
    defer init.gpa.free(binary);

    if (findProhibitedMarker(binary)) |marker| {
        std.debug.print(
            "prohibited marker in headless binary {s}: {s}\n",
            .{ binary_path, marker },
        );
        return error.ProhibitedHeadlessLinkage;
    }

    std.debug.print("headless final-binary boundary verified\n", .{});
}

fn findProhibitedMarker(binary: []const u8) ?[]const u8 {
    for (prohibited_markers) |marker| {
        if (std.ascii.indexOfIgnoreCase(binary, marker) != null) return marker;
    }
    return null;
}

test "marker detection accepts headless data and rejects graphics dependencies" {
    try std.testing.expectEqual(null, findProhibitedMarker("joltc flecs libc"));
    try std.testing.expectEqualStrings(
        "d3d12.dll",
        findProhibitedMarker("KERNEL32.dll\x00D3D12.DLL\x00").?,
    );
    try std.testing.expectEqualStrings(
        "sdl_",
        findProhibitedMarker("prefix SDL_CreateWindow suffix").?,
    );
}
