//! Standalone test root for the graphical developer owner.

const std = @import("std");
const sandbox_developer_host = @import("hosts/sandbox_developer_host.zig");
const viewport_controller = @import("viewport_controller.zig");

test {
    std.testing.refAllDecls(sandbox_developer_host);
    std.testing.refAllDecls(viewport_controller);
}
