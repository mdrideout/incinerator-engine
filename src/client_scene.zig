//! Shared presentation-only scene for graphical session clients.
//!
//! The scene consumes a client-owned replicated world and prediction values.
//! It has no transport, room-registry, authority, persistence, or gameplay
//! mutation capability.

const std = @import("std");
const zm = @import("zmath");
const engine_transform = @import("engine_contracts").transform;
const protocol = @import("session_protocol");
const combat_presentation = @import("combat_presentation");
const session_client = @import("session_client");
const replicated_world = @import("replicated_world");
const sandbox_district_recipe = @import("sandbox_district_recipe");
const presentation = @import("mp2_presentation");
const renderer = presentation.renderer;
const primitives = presentation.primitives;
const mesh = presentation.mesh;
const camera_module = presentation.camera;
const visual_catalog = presentation.visual_catalog;

pub const Scene = struct {
    gpu: renderer.Renderer,
    ground: mesh.Mesh,
    character: mesh.Mesh,
    cube: mesh.Mesh,
    vehicle_wheel: mesh.Mesh,
    camera: camera_module.Camera = .{ .pitch = -0.25 },
    drag_look: camera_module.DragLook = .{},
    vehicle_prediction_enabled: bool = true,
    timeline: replicated_world.PresentationTimeline = .{},
    combat_owner: combat_presentation.Owner = .{},
    last_combat_hud: ?combat_presentation.LocalHud = null,

    pub fn init(window: *presentation.c.SDL_Window) !Scene {
        var gpu = try renderer.Renderer.init(window);
        errdefer gpu.deinit();
        try gpu.setSceneLight(visual_catalog.scene_light);
        var ground = try primitives.createLitGroundPlane(gpu.getDevice());
        errdefer ground.deinit();
        var character = try primitives.createLitCharacterCapsule(gpu.getDevice(), 0.4, 0.5);
        errdefer character.deinit();
        var cube = try primitives.createLitCube(gpu.getDevice());
        errdefer cube.deinit();
        var vehicle_wheel = try primitives.createLitWheelCylinder(gpu.getDevice());
        errdefer vehicle_wheel.deinit();
        return .{
            .gpu = gpu,
            .ground = ground,
            .character = character,
            .cube = cube,
            .vehicle_wheel = vehicle_wheel,
        };
    }

    pub fn deinit(self: *Scene) void {
        self.vehicle_wheel.deinit();
        self.cube.deinit();
        self.character.deinit();
        self.ground.deinit();
        self.gpu.deinit();
        self.* = undefined;
    }

    pub fn toggleVehiclePrediction(self: *Scene) bool {
        self.vehicle_prediction_enabled = !self.vehicle_prediction_enabled;
        return self.vehicle_prediction_enabled;
    }

    pub fn setLookActive(self: *Scene, active: bool) void {
        self.drag_look.setActive(active);
    }

    pub fn applyLookMotion(self: *Scene, dx: f32, dy: f32) void {
        self.drag_look.apply(&self.camera, dx, dy);
    }

    pub fn cancelLook(self: *Scene) void {
        self.drag_look.reset();
    }

    pub fn observeAppliedWorld(
        self: *Scene,
        client: *const session_client.Client,
        now_ns: u64,
    ) void {
        self.timeline.observeAppliedWorld(&client.world, now_ns);
    }

    pub fn noteCombatFeedback(
        self: *Scene,
        client: *const session_client.Client,
        feedback: combat_presentation.Feedback,
    ) void {
        self.combat_owner.noteFeedback(client.avatar_entity, feedback);
    }

    pub fn combatHud(self: *const Scene) ?combat_presentation.LocalHud {
        return self.last_combat_hud;
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
        const size = self.gpu.getProductSceneExtent();
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
        self.last_combat_hud = self.localCombatHud(client);
        self.gpu.drawMeshWithMaterial(
            &self.ground,
            null,
            visual_catalog.material(.ground),
            zm.identity(),
            view_projection,
        );
        for (client.relevantDistrictSlice()) |coord| {
            const build = switch (sandbox_district_recipe.build(
                .{ .x = coord.x, .z = coord.z },
                sandbox_district_recipe.current_recipe_version,
            )) {
                .ready => |value| value,
                .failed => return error.RelevantDistrictRecipeUnavailable,
            };
            const plan = try sandbox_district_recipe.presentationPlan(&build, false);
            for (plan.proxyBoxIndices()) |box_index| {
                const index: usize = box_index;
                if (index >= build.boxes().len) {
                    return error.RelevantDistrictPresentationProxyInvalid;
                }
                const box = build.boxes()[index];
                const scale = zm.scaling(
                    box.half_extents[0] * 2,
                    box.half_extents[1] * 2,
                    box.half_extents[2] * 2,
                );
                const rotation = zm.quatToMat(zm.f32x4(
                    box.pose.rotation[0],
                    box.pose.rotation[1],
                    box.pose.rotation[2],
                    box.pose.rotation[3],
                ));
                const translation = zm.translation(
                    box.pose.position[0],
                    box.pose.position[1],
                    box.pose.position[2],
                );
                self.gpu.drawMeshWithMaterial(
                    &self.cube,
                    null,
                    visual_catalog.material(.obstacle),
                    zm.mul(zm.mul(scale, rotation), translation),
                    view_projection,
                );
            }
        }
        for (client.world.slice()) |entry| {
            const state = self.presentedState(client, entry, now_ns);
            const local_player = std.meta.eql(state.owner, client.participant);
            const combat = self.combat_owner.characterPlan(
                client.world.server_tick,
                state,
                local_player,
            );
            if (participantDriving(client, state.owner)) continue;
            const facing_rotation = try engine_transform.rotationFromFacingYaw(state.facing_yaw);
            const rotation = zm.quatToMat(zm.f32x4(
                facing_rotation[0],
                facing_rotation[1],
                facing_rotation[2],
                facing_rotation[3],
            ));
            const translation = zm.translation(
                state.position[0],
                state.position[1],
                state.position[2],
            );
            self.gpu.drawMeshWithMaterial(
                &self.character,
                null,
                visual_catalog.materialTinted(.fabric_primary, combat.body_color),
                zm.mul(rotation, translation),
                view_projection,
            );
            self.drawFacingMarker(rotation, translation, view_projection);
            self.drawHealthBar(
                state.position,
                1.2,
                combat.health_bar,
                view_projection,
            );
        }
        const local_character = self.localCharacterPresentation(client, now_ns);
        for (client.world.npcSlice()) |entry| {
            var state = self.presentedNpc(entry, now_ns);
            if (local_character) |character| {
                state = replicated_world.separateNpcPresentation(
                    state,
                    character,
                    0.35,
                    0.4,
                ).state;
            }
            // Sparse NPC snapshots publish state; the common replicated
            // server tick owns presentation deadlines between them.
            const combat = self.combat_owner.npcPlan(
                client.world.server_tick,
                state,
            );
            const facing_rotation = try engine_transform.rotationFromFacingYaw(state.facing_yaw);
            const rotation = zm.quatToMat(zm.f32x4(
                facing_rotation[0],
                facing_rotation[1],
                facing_rotation[2],
                facing_rotation[3],
            ));
            const translation = zm.translation(
                state.position[0],
                state.position[1],
                state.position[2],
            );
            self.gpu.drawMeshWithMaterial(
                &self.character,
                null,
                visual_catalog.materialTinted(.fabric_primary, combat.entity.body_color),
                zm.mul(rotation, translation),
                view_projection,
            );
            self.drawFacingMarker(rotation, translation, view_projection);
            self.drawHealthBar(
                state.position,
                1.2,
                combat.entity.health_bar,
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
                &self.cube,
                null,
                visual_catalog.materialTinted(
                    .painted_metal,
                    if (state.driver != null)
                        .{ 0.95, 0.65, 0.10, 1 }
                    else
                        .{ 0.25, 0.35, 0.95, 1 },
                ),
                zm.mul(zm.mul(scale, rotation), translation),
                view_projection,
            );
            const wheel_layout = replicated_world.default_vehicle_wheel_layout;
            const wheel_poses = try replicated_world.composeVehicleWheelPoses(
                state,
                wheel_layout,
            );
            for (wheel_poses) |pose| {
                const wheel_scale = zm.scaling(
                    wheel_layout.width,
                    wheel_layout.radius * 2,
                    wheel_layout.radius * 2,
                );
                const wheel_rotation = zm.quatToMat(zm.f32x4(
                    pose.rotation[0],
                    pose.rotation[1],
                    pose.rotation[2],
                    pose.rotation[3],
                ));
                const wheel_translation = zm.translation(
                    pose.position[0],
                    pose.position[1],
                    pose.position[2],
                );
                self.gpu.drawMeshWithMaterial(
                    &self.vehicle_wheel,
                    null,
                    visual_catalog.material(.tire),
                    zm.mul(zm.mul(wheel_scale, wheel_rotation), wheel_translation),
                    view_projection,
                );
                self.gpu.drawMeshWithMaterial(
                    &self.cube,
                    null,
                    visual_catalog.material(.wheel_marker),
                    wheelMarkerModel(
                        wheel_layout.width,
                        wheel_layout.radius,
                        pose,
                    ),
                    view_projection,
                );
            }
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
                &self.cube,
                null,
                visual_catalog.materialTinted(
                    .carryable,
                    if (state.holder != null)
                        .{ 0.15, 0.90, 0.95, 1 }
                    else
                        .{ 0.95, 0.85, 0.15, 1 },
                ),
                zm.mul(zm.mul(scale, rotation), translation),
                view_projection,
            );
        }
        const combat_hud = self.last_combat_hud.?;
        if (combat_hud.anchor_position) |position| {
            self.drawHudMarkers(
                position,
                1.45,
                combat_hud,
                view_projection,
            );
        }
        self.gpu.endRenderPass();
        try self.gpu.submitFrame();
    }

    fn drawFacingMarker(
        self: *Scene,
        rotation: zm.Mat,
        translation: zm.Mat,
        view_projection: zm.Mat,
    ) void {
        self.gpu.drawMeshWithMaterial(
            &self.cube,
            null,
            visual_catalog.material(.facing_marker),
            zm.mul(
                zm.mul(
                    zm.mul(
                        zm.scaling(0.18, 0.10, 0.08),
                        zm.translation(0, 1.45, -0.42),
                    ),
                    rotation,
                ),
                translation,
            ),
            view_projection,
        );
    }

    fn localCombatHud(
        self: *Scene,
        client: *const session_client.Client,
    ) combat_presentation.LocalHud {
        var local_character: ?protocol.CharacterState = null;
        for (client.world.slice()) |entry| {
            if (std.meta.eql(entry.current.owner, client.participant)) {
                local_character = entry.current;
                break;
            }
        }
        return self.combat_owner.localHud(.{
            .authority_tick = client.world.server_tick,
            .avatar = client.avatar_entity,
            .incarnation = client.avatar_incarnation,
            .life_state = client.avatar_life_state,
            .melee_ready_tick = client.melee_ready_tick,
            .respawn_ready_tick = client.respawn_ready_tick,
            .character = local_character,
            .owned_vehicle = client.ownedVehicle(),
        });
    }

    fn drawHealthBar(
        self: *Scene,
        position: [3]f32,
        y_offset: f32,
        plan: combat_presentation.HealthBarPlan,
        view_projection: zm.Mat,
    ) void {
        if (!plan.visible) return;
        const width: f32 = 1;
        const height: f32 = 0.08;
        const depth: f32 = 0.05;
        const geometry = combat_presentation.healthBarGeometry(plan, width);
        const y = position[1] + y_offset;
        const rotation = zm.rotationY(-self.camera.yaw);
        const right = self.camera.getRight();
        self.gpu.drawMeshWithMaterial(
            &self.cube,
            null,
            visual_catalog.materialTinted(.health_marker, plan.empty_color),
            zm.mul(
                zm.mul(zm.scaling(width, height, depth), rotation),
                zm.translation(position[0], y, position[2]),
            ),
            view_projection,
        );
        if (geometry.fill_width <= 0) return;
        self.gpu.drawMeshWithMaterial(
            &self.cube,
            null,
            visual_catalog.materialTinted(.health_marker, plan.fill_color),
            zm.mul(
                zm.mul(
                    zm.scaling(geometry.fill_width, height * 1.15, depth * 1.15),
                    rotation,
                ),
                zm.translation(
                    position[0] + right[0] * geometry.fill_center_offset,
                    y,
                    position[2] + right[2] * geometry.fill_center_offset,
                ),
            ),
            view_projection,
        );
    }

    fn drawHudMarkers(
        self: *Scene,
        position: [3]f32,
        y_offset: f32,
        hud: combat_presentation.LocalHud,
        view_projection: zm.Mat,
    ) void {
        var marker_index: u8 = 0;
        if (hud.melee_cooldown_marker) {
            self.drawHudMarker(
                position,
                y_offset,
                marker_index,
                combat_presentation.colors.melee_cooldown,
                view_projection,
            );
            marker_index += 1;
        }
        const respawn_color = combat_presentation.respawnMarkerColor(
            hud.respawn_marker,
        );
        if (respawn_color) |color| self.drawHudMarker(
            position,
            y_offset,
            marker_index,
            color,
            view_projection,
        );
    }

    fn drawHudMarker(
        self: *Scene,
        position: [3]f32,
        y_offset: f32,
        marker_index: u8,
        color: combat_presentation.Color,
        view_projection: zm.Mat,
    ) void {
        const x_offset = (@as(f32, @floatFromInt(marker_index)) - 0.5) * 0.22;
        self.gpu.drawMeshWithMaterial(
            &self.cube,
            null,
            visual_catalog.materialTinted(.health_marker, color),
            zm.mul(
                zm.scaling(0.16, 0.16, 0.16),
                zm.translation(
                    position[0] + x_offset,
                    position[1] + y_offset,
                    position[2],
                ),
            ),
            view_projection,
        );
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
            if (client.localVehiclePresentation()) |predicted| {
                return replicated_world.applyPredictedChassis(
                    replicated_world.World.interpolateVehicle(entry, self.snapshotAlpha(now_ns)),
                    predicted,
                );
            }
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
        return replicated_world.World.interpolateNpc(entry, self.timeline.npcAlpha(now_ns));
    }

    fn localCharacterPresentation(
        self: *const Scene,
        client: *const session_client.Client,
        now_ns: u64,
    ) ?protocol.CharacterState {
        if (client.avatar_life_state != .alive or client.ownedVehicle() != null) return null;
        if (client.localPresentation()) |predicted| return predicted;
        for (client.world.slice()) |entry| {
            if (std.meta.eql(entry.current.owner, client.participant)) {
                return self.presentedState(client, entry, now_ns);
            }
        }
        return null;
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
        return self.timeline.commonAlpha(now_ns);
    }
};

fn wheelMarkerModel(width: f32, radius: f32, pose: anytype) zm.Mat {
    const rotation = zm.quatToMat(zm.f32x4(
        pose.rotation[0],
        pose.rotation[1],
        pose.rotation[2],
        pose.rotation[3],
    ));
    const translation = zm.translation(
        pose.position[0],
        pose.position[1],
        pose.position[2],
    );
    return zm.mul(
        zm.mul(
            zm.mul(
                zm.scaling(width * 1.08, radius * 0.14, radius * 0.72),
                zm.translation(0, radius * 0.22, 0),
            ),
            rotation,
        ),
        translation,
    );
}

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
