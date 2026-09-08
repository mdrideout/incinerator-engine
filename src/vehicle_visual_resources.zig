//! Cooked vehicle visuals have their own residency owner; they are not world districts.
const std = @import("std");
const engine = @import("engine_contracts");
const vehicle = @import("vehicle_contract");
const content = @import("content");
const gpu = @import("district_gpu_registry.zig");
const adapter = @import("district_scene_adapter.zig");
const renderer = @import("renderer.zig");
const sdl = @import("sdl.zig");
const zm = @import("zmath");

pub const Part = struct { mesh: *const @import("mesh.zig").Mesh, textures: renderer.MaterialTextures, material: renderer.SurfaceMaterial, model: zm.Mat };
pub const Resources = struct {
    allocator: std.mem.Allocator,
    registry: gpu.DistrictGpuRegistry,
    handles: []engine.rendering.SceneHandle,
    catalog: content.asset_catalog.OwnedCatalog,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, device: *sdl.c.SDL_GPUDevice, root: content.ContentRootPath, bundle_keys: []const []const u8) !Resources {
        var registry = try gpu.DistrictGpuRegistry.init(allocator, .{ .device = device, .allocator = allocator }, .{}, .{});
        errdefer registry.deinit();
        const handles = try allocator.alloc(engine.rendering.SceneHandle, bundle_keys.len);
        errdefer allocator.free(handles);
        var builder = content.asset_catalog.Builder.init(allocator);
        defer builder.deinit();
        var directory = try content.ContentRoot.open(io, root);
        defer directory.deinit(io);
        for (bundle_keys, handles) |key, *handle| {
            var decoded = switch (try directory.load(io, allocator, try content.BundleKey.parse(key), .{})) {
                .scene => |v| v,
                .failed => return error.VehicleVisualBundleUnavailable,
            };
            defer decoded.deinit();
            if (decoded.view().static_boxes.len != 0 or decoded.view().navigation_nodes.len != 0) return error.VehicleVisualContainsWorldRecipe;
            try builder.appendBundle(key, &decoded);
            var upload = try adapter.build(allocator, decoded.view());
            defer upload.deinit();
            handle.* = try registry.reserve();
            try registry.stage(handle.*, upload.sceneUpload());
        }
        return .{ .allocator = allocator, .registry = registry, .handles = handles, .catalog = try builder.finish() };
    }

    pub fn deinit(self: *Resources) void {
        self.registry.deinit();
        self.catalog.deinit();
        self.allocator.free(self.handles);
    }

    pub fn pump(self: *Resources) !void {
        _ = try self.registry.pump();
    }

    pub fn ready(self: *Resources) !bool {
        for (self.handles) |handle| if (try self.registry.residency(handle) != .resident) return false;
        return true;
    }

    /// Missing dependencies reject; pending uploads yield no draw, never a replacement car.
    pub fn resolve(self: *Resources, part: vehicle.asset.VisualPart, pose: engine.physics.Pose) !?Part {
        if (!try self.ready()) return null;
        for (self.handles) |handle| {
            const scene = try self.registry.resolve(handle);
            for (scene.meshes()) |mesh| if (mesh.asset_id) |id| {
                if (!std.meta.eql(id, part.mesh)) continue;
                for (self.handles) |material_handle| {
                    const material_scene = try self.registry.resolve(material_handle);
                    for (material_scene.materials(), 0..) |material, index| if (material.asset_id) |material_id| {
                        if (!std.meta.eql(material_id, part.material)) continue;
                        const local = poseMatrix(part.local_pose);
                        const model = zm.mul(zm.mul(zm.scaling(part.scale[0], part.scale[1], part.scale[2]), local), poseMatrix(pose));
                        return .{ .mesh = mesh.mesh, .textures = material_scene.materialTextures(@intCast(index)), .material = material.surface(), .model = model };
                    };
                }
                return error.VehicleMaterialMissing;
            };
        }
        return error.VehicleMeshMissing;
    }
};

fn poseMatrix(pose: engine.physics.Pose) zm.Mat {
    return zm.mul(zm.quatToMat(zm.f32x4(pose.rotation[0], pose.rotation[1], pose.rotation[2], pose.rotation[3])), zm.translation(pose.position[0], pose.position[1], pose.position[2]));
}
