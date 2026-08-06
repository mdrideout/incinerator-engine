//! Backend-neutral data contracts shared by the kernel, features, and adapters.

const std = @import("std");

pub const identity = @import("identity.zig");
pub const transform = @import("transform.zig");
pub const diagnostics = @import("contracts/diagnostics.zig");
pub const physics = @import("contracts/physics.zig");
pub const physics_debug = @import("contracts/physics_debug.zig");
pub const replay = @import("contracts/replay.zig");
pub const rendering = @import("contracts/rendering.zig");
pub const neural_rendering = @import("contracts/neural_rendering.zig");

pub const PersistentId = identity.PersistentId;
pub const Pose = transform.Pose;

test "contract surface remains backend neutral" {
    std.testing.refAllDecls(identity);
    std.testing.refAllDecls(transform);
    std.testing.refAllDecls(diagnostics);
    std.testing.refAllDecls(physics);
    std.testing.refAllDecls(physics_debug);
    std.testing.refAllDecls(replay);
    std.testing.refAllDecls(rendering);
    std.testing.refAllDecls(neural_rendering);
}
