//! Standalone test root for the graphical developer owner.

const std = @import("std");
const sandbox_developer_host = @import("hosts/sandbox_developer_host.zig");

test {
    std.testing.refAllDecls(sandbox_developer_host);
}
