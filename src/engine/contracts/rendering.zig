//! Renderer-neutral presentation data.

const std = @import("std");

/// A typed, generational reference into a renderer-owned mesh table.
pub const MeshHandle = struct {
    index: u32,
    generation: u32,

    pub const invalid = MeshHandle{
        .index = std.math.maxInt(u32),
        .generation = 0,
    };

    pub fn isValid(self: MeshHandle) bool {
        return self.index != std.math.maxInt(u32) and self.generation != 0;
    }
};

/// A typed, generational reference into a renderer-owned material table.
pub const MaterialHandle = struct {
    index: u32,
    generation: u32,

    pub const invalid = MaterialHandle{
        .index = std.math.maxInt(u32),
        .generation = 0,
    };

    pub fn isValid(self: MaterialHandle) bool {
        return self.index != std.math.maxInt(u32) and self.generation != 0;
    }
};

test "render handles are typed and detect stale sentinel values" {
    const mesh = MeshHandle{ .index = 3, .generation = 2 };
    const material = MaterialHandle{ .index = 3, .generation = 2 };
    try std.testing.expect(mesh.isValid());
    try std.testing.expect(material.isValid());
    try std.testing.expect(!MeshHandle.invalid.isValid());
    try std.testing.expect(!MaterialHandle.invalid.isValid());
    try std.testing.expect(MeshHandle != MaterialHandle);
}
