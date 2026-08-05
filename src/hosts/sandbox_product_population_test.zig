//! Renderer-free product acceptance for the authored sandbox population.
//!
//! The test crosses the same embedded local-session boundary as `zig build
//! run`. It deliberately observes only public host capabilities: district
//! admission, NPC outcomes, authority counts, and client presentation.

const std = @import("std");
const engine = @import("incinerator_engine");
const host_contracts = @import("sandbox_host_contracts");
const local_solo = @import("local_solo_session");
const population = @import("population_contract");
const replay = @import("sandbox_replay");
const simulation = @import("sandbox_simulation");
const district_recipe = @import("sandbox_district_recipe");

const maximum_bootstrap_ticks: usize = 192;

test "normal product admits and presents the complete authored population" {
    const content = try replay.ContentCohort.init(
        "s13-product-population-test",
        replay.current_catalog_format_version,
        replay.current_catalog_schema_cohort,
        district_recipe.current_recipe_version,
        [_]u8{0x51} ** 32,
        [_]u8{0xa5} ** 32,
    );
    const composition = try local_solo.Placement.initComposition(
        std.testing.allocator,
        .{
            .namespace = 0x5052_4f44_504f_5001,
            .fixed_delta_seconds = 1.0 / 60.0,
            .create_ground = true,
            .character = .{ .max_characters = 1 },
            .authored_population = true,
        },
        .{ .recording_content = content },
    );
    const placement = composition.placement;
    var placement_live = true;
    defer if (placement_live) placement.deinit();

    try placement.characters().submit(.{ .spawn = .{
        .request_id = 1,
        .position = host_contracts.default_character_spawn_position,
    } });
    try placement.districts().submit(.{ .request_load = .{
        .request_id = 2,
        .coord = host_contracts.navigation_west_coord,
        .assets = .{},
    } });

    var west_active = false;
    var east_requested = false;
    var east_active = false;
    var character_active = false;
    var spawned_ids: [population.ordinary_member_count]engine.PersistentId = undefined;
    var spawned_count: usize = 0;
    var complete = false;

    for (0..maximum_bootstrap_ticks) |_| {
        std.Thread.yield() catch {};
        try placement.lifecycle().tick();

        while (placement.characters().pollOutcome()) |outcome| switch (outcome) {
            .spawned => character_active = true,
            .despawned, .rejected => return error.UnexpectedCharacterOutcome,
        };
        while (placement.characters().pollEvent()) |_| {}

        while (placement.districts().pollOutcome()) |outcome| switch (outcome) {
            .activated => |activated| {
                if (host_contracts.ChunkCoord.eql(
                    activated.coord,
                    host_contracts.navigation_west_coord,
                )) {
                    west_active = true;
                } else if (host_contracts.ChunkCoord.eql(
                    activated.coord,
                    host_contracts.navigation_east_coord,
                )) {
                    east_active = true;
                } else {
                    return error.UnexpectedDistrictActivation;
                }
            },
            .load_requested => {},
            .load_failed, .rejected, .cancelled => {
                return error.ProductDistrictActivationFailed;
            },
            .cancellation_requested, .unloaded => {
                return error.UnexpectedDistrictOutcome;
            },
        };
        while (placement.districts().pollEvent()) |_| {}

        if (west_active and !east_requested) {
            try placement.districts().submit(.{ .request_load = .{
                .request_id = 3,
                .coord = host_contracts.navigation_east_coord,
                .assets = .{},
            } });
            east_requested = true;
        }

        while (placement.npcs().pollOutcome()) |outcome| switch (outcome) {
            .spawned => |spawned| {
                for (spawned_ids[0..spawned_count]) |existing| {
                    if (std.meta.eql(existing, spawned.id)) {
                        return error.DuplicatePopulationActor;
                    }
                }
                if (spawned_count == spawned_ids.len) {
                    return error.ExcessPopulationActor;
                }
                spawned_ids[spawned_count] = spawned.id;
                spawned_count += 1;
            },
            .goal_set => {},
            .despawned, .rejected => return error.UnexpectedPopulationOutcome,
        };
        while (placement.npcs().pollEvent()) |_| {}
        while (placement.npcs().pollNavigationTransition()) |_| {}
        while (placement.npcs().pollPopulationTransition()) |_| {}

        if (character_active and west_active and east_active and
            spawned_count == population.ordinary_member_count and
            placement.npcs().count() == population.ordinary_member_count and
            placement.presentation().npcs(1).len ==
                population.ordinary_member_count)
        {
            complete = true;
            break;
        }
    }

    try std.testing.expect(complete);
    try std.testing.expect(character_active);
    try std.testing.expect(west_active);
    try std.testing.expect(east_active);
    try std.testing.expectEqual(population.ordinary_member_count, spawned_count);
    try std.testing.expectEqual(
        population.ordinary_member_count,
        placement.npcs().count(),
    );
    try std.testing.expectEqual(
        population.ordinary_member_count,
        placement.presentation().npcs(1).len,
    );

    var maybe_capture: ?[]u8 = null;
    for (0..maximum_bootstrap_ticks) |_| {
        if (placement.developer().snapshotFlightRecording(
            std.testing.allocator,
        )) |bytes| {
            maybe_capture = bytes;
            break;
        } else |err| switch (err) {
            error.CommandsPendingAtReplaySnapshot => {},
            else => return err,
        }
        std.Thread.yield() catch {};
        try placement.lifecycle().tick();
        while (placement.characters().pollOutcome() != null) {}
        while (placement.characters().pollEvent() != null) {}
        while (placement.districts().pollOutcome() != null) {}
        while (placement.districts().pollEvent() != null) {}
        while (placement.npcs().pollOutcome() != null) {}
        while (placement.npcs().pollEvent() != null) {}
        while (placement.npcs().pollNavigationTransition() != null) {}
        while (placement.npcs().pollPopulationTransition() != null) {}
    }
    const capture = maybe_capture orelse return error.ProductReplaySnapshotNotQuiescent;
    defer std.testing.allocator.free(capture);
    placement.deinit();
    placement_live = false;

    var parsed = try replay.parse(std.testing.allocator, capture);
    defer parsed.deinit();
    try parsed.validateCompatible(content);
    const result = try simulation.replayCapture(
        std.testing.allocator,
        parsed.view(),
        content,
    );
    try std.testing.expect(result == .matched);
    try std.testing.expectEqual(
        @as(u64, @intCast(parsed.tick_digests.len)),
        result.matched.completed_ticks,
    );
}
