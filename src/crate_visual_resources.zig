//! Visual-host owner for the S0 crate's shared GPU resources.
//!
//! CrateFeature stores only the typed handles below. This table is deliberately
//! one slot until a second asset consumer proves the need for a general asset
//! database.

const std = @import("std");
const engine = @import("incinerator_engine");
const sdl = @import("sdl.zig");
const mesh = @import("mesh.zig");
const primitives = @import("primitives.zig");
const texture = @import("texture.zig");

const c = sdl.c;

pub const mesh_handle = engine.rendering.MeshHandle{ .index = 0, .generation = 1 };
pub const material_handle = engine.rendering.MaterialHandle{ .index = 0, .generation = 1 };

pub const CrateVisualResources = struct {
    mesh: mesh.Mesh,
    texture: texture.OwnedTexture,

    pub fn init(device: *c.SDL_GPUDevice) !CrateVisualResources {
        var owned_texture = try texture.createDebugCheckerboard(device);
        errdefer owned_texture.deinit();
        var owned_mesh = try primitives.createTexturedCube(device);
        errdefer owned_mesh.deinit();
        owned_mesh.diffuse_texture = owned_texture.borrow();
        return .{ .mesh = owned_mesh, .texture = owned_texture };
    }

    pub fn deinit(self: *CrateVisualResources) void {
        self.mesh.deinit();
        self.texture.deinit();
        self.* = undefined;
    }

    pub fn borrowTexture(self: *const CrateVisualResources) texture.Texture {
        return self.texture.borrow();
    }

    pub fn resolve(
        self: *CrateVisualResources,
        requested_mesh: engine.rendering.MeshHandle,
        requested_material: engine.rendering.MaterialHandle,
    ) !*mesh.Mesh {
        if (!std.meta.eql(requested_mesh, mesh_handle)) return error.StaleCrateMeshHandle;
        if (!std.meta.eql(requested_material, material_handle)) {
            return error.StaleCrateMaterialHandle;
        }
        return &self.mesh;
    }
};

test "the one-slot visual table rejects stale generations" {
    try std.testing.expect(mesh_handle.isValid());
    try std.testing.expect(material_handle.isValid());
    try std.testing.expect(!std.meta.eql(
        mesh_handle,
        engine.rendering.MeshHandle{ .index = 0, .generation = 2 },
    ));
}
