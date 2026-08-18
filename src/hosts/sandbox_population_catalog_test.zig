//! Native placement proof for the exact S13 authored coordinate table.

const std = @import("std");
const district = @import("district_contract");
const engine = @import("incinerator_engine");
const physics_adapter = @import("jolt_physics");
const population = @import("population_contract");
const catalog = @import("sandbox_population_catalog");
const recipe = @import("sandbox_district_recipe");

test "sixteen authored activity spawn and replacement poses remain physically admissible" {
    try catalog.validate();

    var physics = try physics_adapter.Physics.init();
    defer physics.deinit();

    var builds: [recipe.installed_coords.len]district.DistrictBuild = undefined;
    for (recipe.installed_coords, 0..) |coord, index| {
        builds[index] = recipe.build(coord, recipe.current_recipe_version).ready;
    }
    var body_count: usize = 0;
    var bodies: [1 + recipe.installed_coords.len * district.max_static_boxes]physics_adapter.BodyId =
        undefined;
    bodies[body_count] = try physics.createStaticBox(.{ 0, -1, 0 }, .{ 50, 1, 50 });
    body_count += 1;
    for (builds) |build| {
        for (build.boxes()) |box| {
            bodies[body_count] = try physics.createStaticBox(
                box.pose.position,
                box.half_extents,
            );
            body_count += 1;
        }
    }
    defer for (bodies[0..body_count]) |body| {
        _ = physics.removeBody(body);
    };

    var controllers = physics.characterControllers();
    var handles: [population.max_activity_slots]physics_adapter.CharacterId = undefined;
    var handle_count: usize = 0;
    defer for (handles[0..handle_count]) |handle| {
        controllers.destroyCharacter(handle) catch unreachable;
    };

    for (catalog.activity_slots) |slot| {
        const desc = engine.physics.CharacterDesc{
            .position = slot.position,
            .radius = catalog.placement_clearance.radius,
            .half_height = catalog.placement_clearance.half_height,
        };
        try std.testing.expect(try controllers.placementClear(desc, 0.05));
        handles[handle_count] = try controllers.createCharacter(desc);
        handle_count += 1;
    }
    try std.testing.expectEqual(population.max_activity_slots, handle_count);
    try std.testing.expectEqual(population.max_activity_slots, controllers.controllerCount());

    for (0..120) |_| {
        try physics.update(1.0 / 120.0);
        for (handles) |handle| {
            const before = try controllers.characterState(handle);
            var velocity = before.velocity;
            velocity[1] = @max(velocity[1] - 20.0 / 120.0, -55.0);
            _ = try controllers.updateCharacter(
                handle,
                .{ .velocity = velocity },
                1.0 / 120.0,
            );
        }
    }

    var positions: [population.max_activity_slots][3]f32 = undefined;
    for (handles, 0..) |handle, index| {
        const state = try controllers.characterState(handle);
        positions[index] = state.position;
        try std.testing.expect(@abs(
            state.position[0] - catalog.activity_slots[index].position[0],
        ) < 0.05);
        try std.testing.expect(@abs(
            state.position[2] - catalog.activity_slots[index].position[2],
        ) < 0.05);
        try std.testing.expect(state.position[1] >= -0.01 and state.position[1] < 0.1);
    }
    for (positions, 0..) |position, index| {
        for (positions[0..index]) |earlier| {
            const dx = position[0] - earlier[0];
            const dz = position[2] - earlier[2];
            try std.testing.expect(
                dx * dx + dz * dz >=
                    catalog.activity_separation * catalog.activity_separation,
            );
        }
    }

    for (handles[0..handle_count]) |handle| {
        try controllers.destroyCharacter(handle);
    }
    handle_count = 0;

    for (catalog.members) |member| {
        const slot = catalog.spawnSlotDefinition(member.initial_spawn_slot) orelse
            return error.InitialPopulationSpawnSlotMissing;
        const desc = engine.physics.CharacterDesc{
            .position = slot.position,
            .radius = catalog.placement_clearance.radius,
            .half_height = catalog.placement_clearance.half_height,
        };
        try std.testing.expect(try controllers.placementClear(desc, 0.05));
        handles[handle_count] = try controllers.createCharacter(desc);
        positions[handle_count] = slot.position;
        handle_count += 1;
    }
    try std.testing.expectEqual(population.max_members, handle_count);
    try std.testing.expectEqual(population.max_members, controllers.controllerCount());
    assertSeparated(positions[0..handle_count], catalog.spawn_separation);

    // Model P01's death: remove its controller, then prove the ordered
    // candidate set has at least one replacement pose clear of both Jolt
    // bodies and all fifteen retained CharacterVirtual actors.
    try controllers.destroyCharacter(handles[0]);
    for (1..handle_count) |index| handles[index - 1] = handles[index];
    handle_count -= 1;
    var replacement_position: ?[3]f32 = null;
    const p01 = catalog.members[0];
    for (p01.replacementSpawnSlots()) |candidate_id| {
        const candidate = catalog.spawnSlotDefinition(candidate_id) orelse
            return error.ReplacementPopulationSpawnSlotMissing;
        if (!separatedFromAll(
            candidate.position,
            positions[1..],
            catalog.spawn_separation,
        )) continue;
        const desc = engine.physics.CharacterDesc{
            .position = candidate.position,
            .radius = catalog.placement_clearance.radius,
            .half_height = catalog.placement_clearance.half_height,
        };
        if (!try controllers.placementClear(desc, 0.05)) continue;
        handles[handle_count] = try controllers.createCharacter(desc);
        handle_count += 1;
        replacement_position = candidate.position;
        break;
    }
    try std.testing.expect(replacement_position != null);
    try std.testing.expectEqual(population.max_members, handle_count);
    try std.testing.expectEqual(population.max_members, controllers.controllerCount());
}

fn assertSeparated(positions: []const [3]f32, minimum: f32) void {
    for (positions, 0..) |position, index| {
        for (positions[0..index]) |earlier| {
            std.debug.assert(horizontalDistanceSquared(position, earlier) >=
                minimum * minimum);
        }
    }
}

fn separatedFromAll(
    candidate: [3]f32,
    positions: []const [3]f32,
    minimum: f32,
) bool {
    for (positions) |position| {
        if (horizontalDistanceSquared(candidate, position) <
            minimum * minimum) return false;
    }
    return true;
}

fn horizontalDistanceSquared(lhs: [3]f32, rhs: [3]f32) f32 {
    const dx = lhs[0] - rhs[0];
    const dz = lhs[2] - rhs[2];
    return dx * dx + dz * dz;
}
