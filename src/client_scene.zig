//! Shared presentation-only scene for graphical session clients.
//!
//! The scene consumes a client-owned replicated world and prediction values.
//! It has no transport, room-registry, authority, persistence, or gameplay
//! mutation capability.

const std = @import("std");
const zm = @import("zmath");
const budgets = @import("session_budgets");
const protocol = @import("session_protocol");
const session_client = @import("session_client");
const replicated_world = @import("replicated_world");
const presentation = @import("mp2_presentation");
const renderer = presentation.renderer;
const primitives = presentation.primitives;
const mesh = presentation.mesh;
const camera_module = presentation.camera;

pub const Scene = struct {
    gpu: renderer.Renderer,
    ground: mesh.Mesh,
    character: mesh.Mesh,
    vehicle: mesh.Mesh,
    carryable: mesh.Mesh,
    camera: camera_module.Camera = .{ .pitch = -0.25 },
    vehicle_prediction_enabled: bool = true,
    last_snapshot_ns: u64 = 0,
    snapshot_interval_ns: u64 = std.time.ns_per_s / budgets.snapshot_hz,

    pub fn init(window: *presentation.c.SDL_Window) !Scene {
        var gpu = try renderer.Renderer.init(window);
        errdefer gpu.deinit();
        var ground = try primitives.createGroundPlane(gpu.getDevice());
        errdefer ground.deinit();
        var character = try primitives.createCharacterCapsule(gpu.getDevice(), 0.4, 0.5);
        errdefer character.deinit();
        var vehicle = try primitives.createCube(gpu.getDevice());
        errdefer vehicle.deinit();
        var carryable = try primitives.createCube(gpu.getDevice());
        errdefer carryable.deinit();
        return .{
            .gpu = gpu,
            .ground = ground,
            .character = character,
            .vehicle = vehicle,
            .carryable = carryable,
        };
    }

    pub fn deinit(self: *Scene) void {
        self.carryable.deinit();
        self.vehicle.deinit();
        self.character.deinit();
        self.ground.deinit();
        self.gpu.deinit();
        self.* = undefined;
    }

    pub fn toggleVehiclePrediction(self: *Scene) bool {
        self.vehicle_prediction_enabled = !self.vehicle_prediction_enabled;
        return self.vehicle_prediction_enabled;
    }

    pub fn observeSnapshot(self: *Scene, now_ns: u64) void {
        if (self.last_snapshot_ns != 0 and now_ns > self.last_snapshot_ns) {
            self.snapshot_interval_ns = now_ns - self.last_snapshot_ns;
        }
        self.last_snapshot_ns = now_ns;
    }

    pub fn render(
        self: *Scene,
        client: *const session_client.Client,
        now_ns: u64,
    ) !void {
        switch (try self.gpu.beginFrame(renderer.Colors.CORNFLOWER_BLUE)) {
            .unavailable => return,
            .ready => {},
        }
        const size = self.gpu.getWindowSize();
        const aspect = @as(f32, @floatFromInt(size.width)) /
            @as(f32, @floatFromInt(size.height));
        if (self.ownedVehiclePresentation(client, now_ns)) |owned| {
            self.camera.followTarget(.{
                owned.position[0],
                owned.position[1] + 0.75,
                owned.position[2],
            }, 9);
        } else for (client.world.slice()) |entry| {
            const state = self.presentedState(client, entry, now_ns);
            if (!std.meta.eql(state.owner, client.participant)) continue;
            self.camera.followTarget(.{
                state.position[0],
                state.position[1] + 0.9,
                state.position[2],
            }, 7);
            break;
        }
        const view_projection = self.camera.getViewProjectionMatrix(aspect);
        self.gpu.drawMesh(&self.ground, zm.identity(), view_projection);
        for (client.world.slice()) |entry| {
            const state = self.presentedState(client, entry, now_ns);
            if (participantDriving(client, state.owner)) continue;
            const half_yaw = state.facing_yaw * 0.5;
            const rotation = zm.quatToMat(zm.f32x4(0, @sin(half_yaw), 0, @cos(half_yaw)));
            const translation = zm.translation(
                state.position[0],
                state.position[1],
                state.position[2],
            );
            self.gpu.drawMeshWithMaterial(
                &self.character,
                null,
                if (std.meta.eql(state.owner, client.participant))
                    .{ 0.15, 0.95, 0.25, 1 }
                else
                    .{ 0.95, 0.25, 0.15, 1 },
                zm.mul(rotation, translation),
                view_projection,
            );
        }
        for (client.world.npcSlice()) |entry| {
            const state = self.presentedNpc(entry, now_ns);
            const half_yaw = state.facing_yaw * 0.5;
            const rotation = zm.quatToMat(zm.f32x4(0, @sin(half_yaw), 0, @cos(half_yaw)));
            const translation = zm.translation(
                state.position[0],
                state.position[1],
                state.position[2],
            );
            self.gpu.drawMeshWithMaterial(
                &self.character,
                null,
                if (state.state == .active)
                    .{ 0.65, 0.25, 0.95, 1 }
                else
                    .{ 0.45, 0.45, 0.55, 1 },
                zm.mul(rotation, translation),
                view_projection,
            );
        }
        for (client.world.vehicleSlice()) |entry| {
            const state = self.presentedVehicle(client, entry, now_ns);
            const scale = zm.scaling(1.8, 0.5, 4.0);
            const rotation = zm.quatToMat(zm.f32x4(
                state.rotation[0],
                state.rotation[1],
                state.rotation[2],
                state.rotation[3],
            ));
            const translation = zm.translation(
                state.position[0],
                state.position[1],
                state.position[2],
            );
            self.gpu.drawMeshWithMaterial(
                &self.vehicle,
                null,
                if (state.driver != null)
                    .{ 0.95, 0.65, 0.10, 1 }
                else
                    .{ 0.25, 0.35, 0.95, 1 },
                zm.mul(zm.mul(scale, rotation), translation),
                view_projection,
            );
        }
        for (client.world.carryableSlice()) |entry| {
            const state = self.presentedCarryable(entry, now_ns);
            const scale = zm.scaling(
                state.half_extents[0] * 2,
                state.half_extents[1] * 2,
                state.half_extents[2] * 2,
            );
            const rotation = zm.quatToMat(zm.f32x4(
                state.rotation[0],
                state.rotation[1],
                state.rotation[2],
                state.rotation[3],
            ));
            const translation = zm.translation(
                state.position[0],
                state.position[1],
                state.position[2],
            );
            self.gpu.drawMeshWithMaterial(
                &self.carryable,
                null,
                if (state.holder != null)
                    .{ 0.15, 0.90, 0.95, 1 }
                else
                    .{ 0.95, 0.85, 0.15, 1 },
                zm.mul(zm.mul(scale, rotation), translation),
                view_projection,
            );
        }
        self.gpu.endRenderPass();
        try self.gpu.submitFrame();
    }

    fn presentedState(
        self: *const Scene,
        client: *const session_client.Client,
        entry: replicated_world.Entry,
        now_ns: u64,
    ) protocol.CharacterState {
        if (std.meta.eql(entry.current.owner, client.participant)) {
            if (client.localPresentation()) |predicted| return predicted;
        }
        return replicated_world.World.interpolate(entry, self.snapshotAlpha(now_ns));
    }

    fn presentedVehicle(
        self: *const Scene,
        client: *const session_client.Client,
        entry: replicated_world.VehicleEntry,
        now_ns: u64,
    ) protocol.VehicleState {
        if (self.vehicle_prediction_enabled and entry.current.driver != null and
            std.meta.eql(entry.current.driver.?, client.participant))
        {
            if (client.localVehiclePresentation()) |predicted| return predicted;
        }
        return replicated_world.World.interpolateVehicle(entry, self.snapshotAlpha(now_ns));
    }

    fn presentedCarryable(
        self: *const Scene,
        entry: replicated_world.CarryableEntry,
        now_ns: u64,
    ) protocol.CarryableState {
        return replicated_world.World.interpolateCarryable(entry, self.snapshotAlpha(now_ns));
    }

    fn presentedNpc(
        self: *const Scene,
        entry: replicated_world.NpcEntry,
        now_ns: u64,
    ) protocol.NpcState {
        const elapsed = now_ns -| self.last_snapshot_ns;
        const interval = std.time.ns_per_s / budgets.npc_snapshot_hz;
        const alpha = @as(f32, @floatFromInt(elapsed)) /
            @as(f32, @floatFromInt(interval));
        return replicated_world.World.interpolateNpc(entry, alpha);
    }

    fn ownedVehiclePresentation(
        self: *const Scene,
        client: *const session_client.Client,
        now_ns: u64,
    ) ?protocol.VehicleState {
        for (client.world.vehicleSlice()) |entry| {
            if (entry.current.driver) |driver| {
                if (std.meta.eql(driver, client.participant)) {
                    return self.presentedVehicle(client, entry, now_ns);
                }
            }
        }
        return null;
    }

    fn snapshotAlpha(self: *const Scene, now_ns: u64) f32 {
        const elapsed = now_ns -| self.last_snapshot_ns;
        if (self.snapshot_interval_ns == 0) return 1;
        return @as(f32, @floatFromInt(elapsed)) /
            @as(f32, @floatFromInt(self.snapshot_interval_ns));
    }
};

fn participantDriving(
    client: *const session_client.Client,
    participant: @TypeOf(client.participant),
) bool {
    for (client.world.vehicleSlice()) |entry| {
        if (entry.current.driver) |driver| {
            if (std.meta.eql(driver, participant)) return true;
        }
    }
    return false;
}
