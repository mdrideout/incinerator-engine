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
pub const vehicle_chassis_mesh_handle = engine.rendering.MeshHandle{ .index = 2, .generation = 1 };
pub const vehicle_chassis_material_handle = engine.rendering.MaterialHandle{ .index = 2, .generation = 1 };
pub const vehicle_wheel_mesh_handle = engine.rendering.MeshHandle{ .index = 3, .generation = 1 };
pub const vehicle_wheel_material_handle = engine.rendering.MaterialHandle{ .index = 3, .generation = 1 };

const VisualSlot = enum {
    crate,
    character,
    vehicle_chassis,
    vehicle_wheel,
};

fn visualSlot(
    requested_mesh: engine.rendering.MeshHandle,
    requested_material: engine.rendering.MaterialHandle,
) ?VisualSlot {
    if (std.meta.eql(requested_mesh, crate_mesh_handle) and
        std.meta.eql(requested_material, crate_material_handle)) return .crate;
    if (std.meta.eql(requested_mesh, character_mesh_handle) and
        std.meta.eql(requested_material, character_material_handle)) return .character;
    if (std.meta.eql(requested_mesh, vehicle_chassis_mesh_handle) and
        std.meta.eql(requested_material, vehicle_chassis_material_handle)) return .vehicle_chassis;
    if (std.meta.eql(requested_mesh, vehicle_wheel_mesh_handle) and
        std.meta.eql(requested_material, vehicle_wheel_material_handle)) return .vehicle_wheel;
    return null;
}

pub const SandboxVisualResources = struct {
    crate_mesh: mesh.Mesh,
    crate_texture: texture.OwnedTexture,
    character_mesh: mesh.Mesh,
    vehicle_chassis_mesh: mesh.Mesh,
    vehicle_wheel_mesh: mesh.Mesh,

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
        var character_mesh = try primitives.createCharacterCapsule(
            device,
            character_radius,
            character_half_height,
        );
        errdefer character_mesh.deinit();
        var vehicle_chassis_mesh = try primitives.createCube(device);
        errdefer vehicle_chassis_mesh.deinit();
        var vehicle_wheel_mesh = try primitives.createWheelCylinder(device);
        errdefer vehicle_wheel_mesh.deinit();
        return .{
            .crate_mesh = crate_mesh,
            .crate_texture = crate_texture,
            .character_mesh = character_mesh,
            .vehicle_chassis_mesh = vehicle_chassis_mesh,
            .vehicle_wheel_mesh = vehicle_wheel_mesh,
        };
    }

    pub fn deinit(self: *SandboxVisualResources) void {
        self.vehicle_wheel_mesh.deinit();
        self.vehicle_chassis_mesh.deinit();
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
        return switch (visualSlot(requested_mesh, requested_material) orelse
            return error.StaleSandboxVisualHandle) {
            .crate => &self.crate_mesh,
            .character => &self.character_mesh,
            .vehicle_chassis => &self.vehicle_chassis_mesh,
            .vehicle_wheel => &self.vehicle_wheel_mesh,
        };
    }
};

test "slice visual handles occupy distinct typed slots" {
    const mesh_handles = [_]engine.rendering.MeshHandle{
        crate_mesh_handle,
        character_mesh_handle,
        vehicle_chassis_mesh_handle,
        vehicle_wheel_mesh_handle,
    };
    const material_handles = [_]engine.rendering.MaterialHandle{
        crate_material_handle,
        character_material_handle,
        vehicle_chassis_material_handle,
        vehicle_wheel_material_handle,
    };
    for (mesh_handles, 0..) |handle, index| {
        try std.testing.expect(handle.isValid());
        for (mesh_handles[index + 1 ..]) |other| {
            try std.testing.expect(!std.meta.eql(handle, other));
        }
    }
    for (material_handles, 0..) |handle, index| {
        try std.testing.expect(handle.isValid());
        for (material_handles[index + 1 ..]) |other| {
            try std.testing.expect(!std.meta.eql(handle, other));
        }
    }
}

test "visual handle pairs resolve only exact live slots" {
    try std.testing.expectEqual(VisualSlot.crate, visualSlot(
        crate_mesh_handle,
        crate_material_handle,
    ).?);
    try std.testing.expectEqual(VisualSlot.character, visualSlot(
        character_mesh_handle,
        character_material_handle,
    ).?);
    try std.testing.expectEqual(VisualSlot.vehicle_chassis, visualSlot(
        vehicle_chassis_mesh_handle,
        vehicle_chassis_material_handle,
    ).?);
    try std.testing.expectEqual(VisualSlot.vehicle_wheel, visualSlot(
        vehicle_wheel_mesh_handle,
        vehicle_wheel_material_handle,
    ).?);

    try std.testing.expectEqual(null, visualSlot(
        vehicle_chassis_mesh_handle,
        vehicle_wheel_material_handle,
    ));
    try std.testing.expectEqual(null, visualSlot(
        engine.rendering.MeshHandle.invalid,
        engine.rendering.MaterialHandle.invalid,
    ));
    try std.testing.expectEqual(null, visualSlot(
        .{ .index = vehicle_wheel_mesh_handle.index, .generation = 2 },
        vehicle_wheel_material_handle,
    ));
}
