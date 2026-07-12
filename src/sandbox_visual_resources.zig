//! Small visual-host resource owner proven by the crate and character slices.

const std = @import("std");
const engine = @import("incinerator_engine");
const sdl = @import("sdl.zig");
const mesh = @import("mesh.zig");
const primitives = @import("primitives.zig");
const texture = @import("texture.zig");

const c = sdl.c;

pub const crate_mesh_handle = engine.rendering.MeshHandle{ .index = 0, .generation = 1 };
pub const crate_material_handle = engine.rendering.MaterialHandle{ .index = 0, .generation = 1 };
pub const character_mesh_handle = engine.rendering.MeshHandle{ .index = 1, .generation = 1 };
pub const character_material_handle = engine.rendering.MaterialHandle{ .index = 1, .generation = 1 };

pub const SandboxVisualResources = struct {
    crate_mesh: mesh.Mesh,
    crate_texture: texture.OwnedTexture,
    character_mesh: mesh.Mesh,

    pub fn init(
        device: *c.SDL_GPUDevice,
        character_radius: f32,
        character_half_height: f32,
    ) !SandboxVisualResources {
        var crate_texture = try texture.createDebugCheckerboard(device);
        errdefer crate_texture.deinit();
        var crate_mesh = try primitives.createTexturedCube(device);
        errdefer crate_mesh.deinit();
        crate_mesh.diffuse_texture = crate_texture.borrow();
        const character_mesh = try primitives.createCharacterCapsule(
            device,
            character_radius,
            character_half_height,
        );
        return .{
            .crate_mesh = crate_mesh,
            .crate_texture = crate_texture,
            .character_mesh = character_mesh,
        };
    }

    pub fn deinit(self: *SandboxVisualResources) void {
        self.character_mesh.deinit();
        self.crate_mesh.deinit();
        self.crate_texture.deinit();
        self.* = undefined;
    }

    pub fn resolve(
        self: *SandboxVisualResources,
        requested_mesh: engine.rendering.MeshHandle,
        requested_material: engine.rendering.MaterialHandle,
    ) !*mesh.Mesh {
        if (std.meta.eql(requested_mesh, crate_mesh_handle) and
            std.meta.eql(requested_material, crate_material_handle))
        {
            return &self.crate_mesh;
        }
        if (std.meta.eql(requested_mesh, character_mesh_handle) and
            std.meta.eql(requested_material, character_material_handle))
        {
            return &self.character_mesh;
        }
        return error.StaleSandboxVisualHandle;
    }
};

test "slice visual handles occupy distinct typed slots" {
    try std.testing.expect(crate_mesh_handle.isValid());
    try std.testing.expect(character_mesh_handle.isValid());
    try std.testing.expect(!std.meta.eql(crate_mesh_handle, character_mesh_handle));
    try std.testing.expect(!std.meta.eql(crate_material_handle, character_material_handle));
}
