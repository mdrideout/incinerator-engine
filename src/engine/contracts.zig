//! Backend-neutral data contracts shared by the kernel, features, and adapters.

const std = @import("std");

pub const identity = @import("identity.zig");
pub const transform = @import("transform.zig");
pub const physics = @import("contracts/physics.zig");
pub const rendering = @import("contracts/rendering.zig");

pub const PersistentId = identity.PersistentId;
pub const Pose = transform.Pose;

test "contract surface remains backend neutral" {
    std.testing.refAllDecls(identity);
    std.testing.refAllDecls(transform);
    std.testing.refAllDecls(physics);
    std.testing.refAllDecls(rendering);
}
