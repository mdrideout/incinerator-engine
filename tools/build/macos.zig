const std = @import("std");
const builtin = @import("builtin");

const required_zig_version = std.SemanticVersion{ .major = 0, .minor = 16, .patch = 0 };

/// The package manifest can express only a minimum Zig version. The build
/// graph enforces the project's intentionally exact development cohort.
pub fn requireToolchain() void {
    if (!std.meta.eql(builtin.zig_version, required_zig_version)) {
        @panic("Incinerator requires Zig 0.16.0 exactly; activate the version recorded in .zigversion");
    }
}

/// Reject unsupported product targets before any optional client dependency is
/// resolved. Linux, SteamOS, Windows, and Intel macOS are future ports, not
/// partially supported build configurations.
pub fn requireAppleSilicon(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
) void {
    const host = b.graph.host.result;
    if (host.os.tag != .macos or host.cpu.arch != .aarch64 or
        target.result.os.tag != .macos or target.result.cpu.arch != .aarch64 or
        target.result.abi != .none or target.result.ofmt != .macho)
    {
        @panic("Incinerator currently supports only the native Apple Silicon macOS target (aarch64-macos-none, Mach-O); Linux, Windows, GNU ABI, ELF, Intel, and cross-host builds are deferred");
    }
}
