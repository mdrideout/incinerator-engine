//! Renderer-free acceptance for the normal product's playable NPC encounter.
//!
//! This intentionally does not use the validation-only S11 script. It proves
//! the product initializer crosses the same local session/authority boundary
//! used by `zig build run`, then exercises the product character owner through
//! NPC-caused death, cooldown, respawn, replacement identity projection, and a
//! short post-respawn survival window.

const std = @import("std");
const engine = @import("incinerator_engine");
const host_contracts = @import("sandbox_host_contracts");
const local_solo = @import("local_solo_session");
const product_character_lifecycle = @import("sandbox_product_character_lifecycle");
const product_encounter = @import("sandbox_product_encounter");

const maximum_lifecycle_ticks: usize = 10_000;
const post_respawn_survival_ticks: usize = 30;

test "normal product encounter survives NPC-caused death and local respawn" {
    const composition = try local_solo.Placement.initComposition(
        std.testing.allocator,
        .{
            .namespace = 0x5052_4f44_4e50_4301,
            .fixed_delta_seconds = 1.0 / 60.0,
            .create_ground = true,
            .character = .{ .max_characters = 1 },
        },
        .{},
    );
    const placement = composition.placement;
    defer placement.deinit();

    try placement.characters().submit(.{ .spawn = .{
        .request_id = 1,
        .position = host_contracts.default_character_spawn_position,
    } });
    try placement.districts().submit(.{ .request_load = .{
        .request_id = 2,
        .coord = host_contracts.navigation_west_coord,
        .assets = .{},
    } });

    var character_lifecycle = product_character_lifecycle.Owner{};
    var current_character: ?@FieldType(local_solo.CharacterAdminOutcome, "despawned") = null;
    var west_ready = false;
    for (0..maximum_lifecycle_ticks) |_| {
        std.Thread.yield() catch {};
        try placement.lifecycle().tick();
        while (placement.characters().pollOutcome()) |outcome| switch (outcome) {
            .spawned => |spawned| {
                const projected = placement.inspection().replicatedId(spawned.id) orelse
                    return error.ProductCharacterProjectionMissing;
                try character_lifecycle.observeSpawn(
                    &current_character,
                    spawned,
                    placement.presentation().combatHud(),
                    projected,
                );
            },
            .despawned, .rejected => return error.UnexpectedProductCharacterOutcome,
        };
        while (placement.characters().pollEvent()) |_| {}
        while (placement.districts().pollOutcome()) |outcome| switch (outcome) {
            .activated => |activated| {
                if (activated.request_id != 2 or
                    !host_contracts.ChunkCoord.eql(
                        activated.coord,
                        host_contracts.navigation_west_coord,
                    ))
                {
                    return error.UnexpectedProductDistrictOutcome;
                }
                west_ready = true;
            },
            .load_requested => {},
            .load_failed, .rejected, .cancelled => {
                return error.ProductDistrictActivationFailed;
            },
            .cancellation_requested, .unloaded => {
                return error.UnexpectedProductDistrictOutcome;
            },
        };
        while (placement.districts().pollEvent()) |_| {}
        if (current_character != null and west_ready) break;
    }
    const initial_character_id = current_character orelse
        return error.ProductCharacterDidNotBootstrap;
    const initial_avatar = placement.inspection().replicatedId(initial_character_id) orelse
        return error.ProductCharacterProjectionMissing;
    try std.testing.expect(west_ready);
    try std.testing.expect(placement.districts().activeTicket(
        host_contracts.navigation_west_coord,
    ) != null);

    var owner = product_encounter.Owner{};
    const command = owner.pendingSpawn(.{
        .player_ready = true,
        .west_district_active = west_ready,
    }) orelse return error.MissingProductEncounterCommand;
    try placement.npcs().submit(command);
    try owner.markSubmitted(command);

    var activated = false;
    var replicated_living_draw = false;
    for (0..maximum_lifecycle_ticks) |_| {
        try placement.lifecycle().tick();
        if (placement.characters().pollOutcome() != null) {
            return error.UnexpectedProductCharacterOutcome;
        }
        while (placement.characters().pollEvent()) |_| {}
        while (placement.npcs().pollOutcome()) |outcome| {
            switch (try owner.observe(outcome)) {
                .unrelated => {},
                .activated => activated = true,
            }
        }
        while (placement.npcs().pollEvent()) |_| {}
        const draws = placement.presentation().npcs(1);
        if (activated and draws.len == 1 and
            draws[0].life_state == .alive and
            draws[0].health == draws[0].maximum_health and
            draws[0].maximum_health != 0)
        {
            replicated_living_draw = true;
            break;
        }
    }

    try std.testing.expect(activated);
    try std.testing.expectEqual(product_encounter.State.bootstrap_complete, owner.state);
    try std.testing.expect(owner.bootstrap_npc != null);
    try std.testing.expectEqual(@as(usize, 1), placement.npcs().count());
    try std.testing.expect(replicated_living_draw);
    // Freeze only the patrol goal for this contact journey. Perception,
    // pursuit, attacks, authority/session placement, and product lifecycle
    // remain identical to the normal product while the fixture stays away
    // from the deliberately separate district-transfer scenario.
    try placement.npcs().submit(.{ .set_goal = .{
        .request_id = product_encounter.initial_request_id + 1,
        .id = owner.bootstrap_npc orelse return error.ProductNpcIdentityMissing,
        .goal = .hold,
    } });

    // Preserve the user's exact cross-feature regression: NPC death must
    // release a held object without making character cleanup fatal or leaving
    // an attachment floating after the avatar controller is removed.
    var carry_pose = engine.physics.Pose{};
    carry_pose.position = host_contracts.default_character_spawn_position;
    carry_pose.position[1] += 0.5;
    try placement.interactions().submit(.{ .spawn = .{
        .request_id = 3,
        .pose = carry_pose,
    } });
    try placement.lifecycle().tick();
    while (placement.npcs().pollOutcome()) |outcome| {
        if (try owner.observe(outcome) != .unrelated) {
            return error.UnexpectedProductNpcLifecycleOutcome;
        }
    }
    while (placement.npcs().pollEvent()) |_| {}
    const carryable = (placement.interactions().pollOutcome() orelse
        return error.ProductCarryableDidNotSpawn).spawned;
    try placement.player().requestInteractionToggle();
    try placement.lifecycle().tick();
    const collected = placement.player().pollInteractionActionResult() orelse
        return error.ProductCarryableWasNotCollected;
    try std.testing.expectEqual(local_solo.InteractionActionDisposition.collected, collected.disposition);
    try std.testing.expectEqual(
        placement.inspection().replicatedId(carryable.id).?,
        collected.carryable,
    );
    const held_draws = placement.presentation().carryables(1);
    try std.testing.expectEqual(@as(usize, 1), held_draws.len);
    try std.testing.expect(held_draws[0].holder != null);

    var death_incarnation: u16 = 0;
    var respawn_ready_tick: u64 = 0;
    var death_event_observed = false;
    var death_despawn_observed = false;
    var death_projection_observed = false;
    var death_carry_release_observed = false;
    var close_contact_observed = false;
    var provocation_submitted = false;
    var minimum_horizontal_separation: f32 = std.math.inf(f32);
    var minimum_presented_separation: f32 = std.math.inf(f32);
    for (0..maximum_lifecycle_ticks) |_| {
        const before_hud = placement.presentation().combatHud();
        if (before_hud.life_state == .alive) {
            const characters = placement.presentation().characters(1);
            const npcs = placement.presentation().npcs(1);
            const character = if (characters.len == 1 and characters[0].local_player)
                characters[0]
            else
                return error.ProductCharacterPresentationGap;
            const npc = if (npcs.len == 1 and npcs[0].life_state == .alive)
                npcs[0]
            else
                return error.ProductNpcPresentationGap;
            const dx = npc.pose.position[0] - character.pose.position[0];
            const dz = npc.pose.position[2] - character.pose.position[2];
            const presented_separation = @sqrt(dx * dx + dz * dz);
            const contact_distance = character.radius + npc.radius;
            minimum_presented_separation = @min(
                minimum_presented_separation,
                presented_separation,
            );
            const authority_character = try placement.characters().view(
                initial_character_id,
            );
            const authority_npc = try placement.npcs().view(
                owner.bootstrap_npc orelse return error.ProductNpcIdentityMissing,
            );
            const authority_dx = authority_npc.position[0] - authority_character.position[0];
            const authority_dz = authority_npc.position[2] - authority_character.position[2];
            const separation = @sqrt(
                authority_dx * authority_dx + authority_dz * authority_dz,
            );
            const authority_character_observation = engine.gameplay_invariants.Actor{
                .entity = .{
                    .namespace = initial_character_id.namespace,
                    .local = initial_character_id.local,
                    .incarnation = character.incarnation,
                },
                .alive = true,
                .authority_present = true,
                .replication_present = true,
                .presentation_present = true,
                .position = authority_character.position,
                .facing_yaw = authority_character.facing_yaw,
                .radius = character.radius,
            };
            const authority_npc_observation = engine.gameplay_invariants.Actor{
                .entity = .{
                    .namespace = (owner.bootstrap_npc orelse
                        return error.ProductNpcIdentityMissing).namespace,
                    .local = owner.bootstrap_npc.?.local,
                    .incarnation = npc.incarnation,
                },
                .alive = true,
                .authority_present = true,
                .replication_present = true,
                .presentation_present = true,
                .position = authority_npc.position,
                .facing_yaw = authority_npc.facing_yaw,
                .radius = npc.radius,
            };
            try authority_character_observation.validate();
            try authority_npc_observation.validate();
            _ = try engine.gameplay_invariants.requireHorizontalSeparation(
                authority_character_observation,
                authority_npc_observation,
                0.06,
            );
            minimum_horizontal_separation = @min(
                minimum_horizontal_separation,
                separation,
            );
            if (separation <= contact_distance + 0.08) {
                close_contact_observed = true;
                if (!provocation_submitted) {
                    try placement.player().requestMelee();
                    provocation_submitted = true;
                }
            }
            // Jolt CharacterVirtual keeps a configurable padded shell inside
            // the authored capsule. Accept only that measured contact skin;
            // crossing or deep overlap remains a temporal product failure.
            if (separation + 0.06 < contact_distance) {
                std.debug.print(
                    "PRODUCT_CONTACT_PENETRATION separation={d:.5} contact={d:.5} tick={d}\n",
                    .{ separation, contact_distance, before_hud.authority_tick },
                );
                return error.ProductCharacterNpcPenetration;
            }
            if (!close_contact_observed and
                presented_separation > contact_distance + 0.02)
            {
                try placement.player().submitMovement(.{
                    .move = .{ 0, 1 },
                    .facing_yaw = std.math.atan2(dx, -dz),
                    .jump_pressed = false,
                });
            }
        }
        placement.lifecycle().tick() catch |err| {
            const character = placement.characters().view(initial_character_id) catch null;
            const npc = placement.npcs().view(
                owner.bootstrap_npc orelse return error.ProductNpcIdentityMissing,
            ) catch null;
            std.debug.print(
                "PRODUCT_CONTACT_TICK_FAILURE error={s} character={any} npc={any}\n",
                .{ @errorName(err), character, npc },
            );
            return err;
        };
        while (placement.characters().pollOutcome()) |outcome| switch (outcome) {
            .despawned => |id| {
                if (death_despawn_observed or !std.meta.eql(id, initial_character_id)) {
                    return error.UnexpectedProductCharacterDeathOutcome;
                }
                try character_lifecycle.observeDespawn(
                    &current_character,
                    id,
                    placement.presentation().combatHud(),
                );
                death_despawn_observed = true;
            },
            .spawned, .rejected => return error.UnexpectedProductCharacterDeathOutcome,
        };
        while (placement.characters().pollEvent()) |_| {}
        while (placement.npcs().pollOutcome()) |outcome| {
            if (try owner.observe(outcome) != .unrelated) {
                return error.UnexpectedProductNpcLifecycleOutcome;
            }
        }
        while (placement.npcs().pollEvent()) |_| {}
        while (placement.player().pollLifeEvent()) |event| {
            if (!std.meta.eql(event.avatar, initial_avatar)) continue;
            const character = current_character orelse
                return error.ProductCharacterIdentityMissingForLifeEvent;
            const projected = placement.inspection().replicatedId(character) orelse
                return error.ProductCharacterProjectionMissingForLifeEvent;
            try character_lifecycle.observeLocalLife(
                character,
                projected,
                placement.presentation().combatHud(),
                event,
            );
            if (event.state == .dead) {
                if (death_event_observed or event.incarnation != initial_avatar.generation or
                    event.health != 0 or event.respawn_ready_tick == 0)
                {
                    return error.UnexpectedProductCharacterDeathEvent;
                }
                death_event_observed = true;
                death_incarnation = event.incarnation;
                respawn_ready_tick = event.respawn_ready_tick;
            }
        }
        const hud = placement.presentation().combatHud();
        if (death_event_observed and hud.life_state == .dead) {
            const draws = placement.presentation().characters(1);
            if (draws.len == 1 and draws[0].local_player and
                std.meta.eql(draws[0].entity, initial_avatar) and
                draws[0].incarnation == death_incarnation and
                draws[0].life_state == .dead and draws[0].health == 0 and
                draws[0].combat.dead and draws[0].combat.body_color[0] > 0.8 and
                draws[0].combat.body_color[1] < 0.2 and
                draws[0].combat.body_color[2] < 0.2)
            {
                death_projection_observed = true;
            }
            const carryable_draws = placement.presentation().carryables(1);
            if (carryable_draws.len == 1 and carryable_draws[0].holder == null) {
                death_carry_release_observed = true;
            }
        }
        if (death_event_observed and death_despawn_observed and hud.available and
            hud.life_state == .dead and hud.incarnation == death_incarnation and
            std.meta.eql(hud.avatar, initial_avatar) and death_projection_observed and
            death_carry_release_observed)
        {
            break;
        }
    }
    if (!death_event_observed) {
        std.debug.print(
            "PRODUCT_CONTACT_NO_DEATH hud={any} npc={any} min_authority={d:.5} min_presented={d:.5} close={}\n",
            .{
                placement.presentation().combatHud(),
                placement.presentation().npcs(1),
                minimum_horizontal_separation,
                minimum_presented_separation,
                close_contact_observed,
            },
        );
    }
    try std.testing.expect(death_event_observed);
    try std.testing.expect(death_despawn_observed);
    try std.testing.expect(death_projection_observed);
    try std.testing.expect(death_carry_release_observed);
    try std.testing.expect(close_contact_observed);
    try std.testing.expect(minimum_horizontal_separation < 0.9);
    try std.testing.expect(std.math.isFinite(minimum_presented_separation));
    try std.testing.expect(minimum_presented_separation + 0.1 >= 0.75);
    try std.testing.expectEqual(@as(usize, 0), placement.characters().count());

    var cooldown_reached = false;
    for (0..maximum_lifecycle_ticks) |_| {
        const hud = placement.presentation().combatHud();
        if (hud.authority_tick >= respawn_ready_tick) {
            cooldown_reached = true;
            break;
        }
        try placement.lifecycle().tick();
        if (placement.characters().pollOutcome() != null) {
            return error.UnexpectedProductCharacterCooldownOutcome;
        }
        while (placement.characters().pollEvent()) |_| {}
        while (placement.npcs().pollOutcome()) |outcome| {
            if (try owner.observe(outcome) != .unrelated) {
                return error.UnexpectedProductNpcLifecycleOutcome;
            }
        }
        while (placement.npcs().pollEvent()) |_| {}
        while (placement.player().pollLifeEvent()) |_| {}
    }
    try std.testing.expect(cooldown_reached);
    try placement.player().requestRespawn();

    var respawned_character: ?@TypeOf(initial_character_id) = null;
    var respawned_avatar: ?@TypeOf(initial_avatar) = null;
    var respawn_result_observed = false;
    var respawn_life_observed = false;
    var respawn_projection_observed = false;
    for (0..maximum_lifecycle_ticks) |_| {
        try placement.lifecycle().tick();
        while (placement.characters().pollOutcome()) |outcome| switch (outcome) {
            .spawned => |spawned| {
                if (respawned_character != null or spawned.request_id == 1 or
                    std.meta.eql(spawned.id, initial_character_id))
                {
                    return error.UnexpectedProductCharacterRespawnOutcome;
                }
                const projected = placement.inspection().replicatedId(spawned.id) orelse
                    return error.ProductCharacterRespawnProjectionMissing;
                try character_lifecycle.observeSpawn(
                    &current_character,
                    spawned,
                    placement.presentation().combatHud(),
                    projected,
                );
                respawned_character = spawned.id;
            },
            .despawned, .rejected => return error.UnexpectedProductCharacterRespawnOutcome,
        };
        while (placement.characters().pollEvent()) |_| {}
        while (placement.npcs().pollOutcome()) |outcome| {
            if (try owner.observe(outcome) != .unrelated) {
                return error.UnexpectedProductNpcLifecycleOutcome;
            }
        }
        while (placement.npcs().pollEvent()) |_| {}
        while (placement.player().pollRespawnActionResult()) |result| {
            try character_lifecycle.observeRespawnResult(
                &current_character,
                placement.presentation().combatHud(),
                result,
            );
            if (respawn_result_observed or result.disposition != .respawned or
                result.incarnation <= death_incarnation or !result.avatar.isValid())
            {
                return error.UnexpectedProductCharacterRespawnResult;
            }
            respawn_result_observed = true;
            respawned_avatar = result.avatar;
        }
        while (placement.player().pollLifeEvent()) |event| {
            if (event.avatar.index != initial_avatar.index or event.state != .alive or
                event.incarnation <= death_incarnation)
            {
                continue;
            }
            const character = current_character orelse
                return error.ProductCharacterIdentityMissingForRespawnLife;
            const projected = placement.inspection().replicatedId(character) orelse
                return error.ProductCharacterProjectionMissingForRespawnLife;
            try character_lifecycle.observeLocalLife(
                character,
                projected,
                placement.presentation().combatHud(),
                event,
            );
            if (respawn_life_observed) return error.DuplicateProductCharacterRespawnLife;
            respawn_life_observed = true;
            respawned_avatar = if (respawned_avatar) |avatar| blk: {
                if (!std.meta.eql(avatar, event.avatar)) {
                    return error.ProductCharacterRespawnIdentityMismatch;
                }
                break :blk avatar;
            } else event.avatar;
        }
        if (respawned_character) |id| {
            const projected = placement.inspection().replicatedId(id) orelse continue;
            if (respawned_avatar) |avatar| {
                if (!std.meta.eql(projected, avatar)) {
                    return error.ProductCharacterRespawnProjectionMismatch;
                }
                const draws = placement.presentation().characters(1);
                if (draws.len == 1 and draws[0].local_player and
                    std.meta.eql(draws[0].entity, avatar) and
                    draws[0].life_state == .alive)
                {
                    respawn_projection_observed = true;
                }
            }
        }
        if (respawned_character != null and respawn_result_observed and
            respawn_life_observed and respawn_projection_observed)
        {
            break;
        }
    }

    const respawned_character_id = respawned_character orelse
        return error.ProductCharacterDidNotRespawn;
    const current_avatar = respawned_avatar orelse
        return error.ProductCharacterRespawnAvatarMissing;
    try std.testing.expect(respawn_result_observed);
    try std.testing.expect(respawn_life_observed);
    try std.testing.expect(respawn_projection_observed);
    try std.testing.expectEqual(@as(usize, 1), placement.characters().count());
    try std.testing.expect(std.meta.eql(
        placement.inspection().replicatedId(respawned_character_id).?,
        current_avatar,
    ));
    try std.testing.expect(std.meta.eql(current_character.?, respawned_character_id));

    for (0..post_respawn_survival_ticks) |_| {
        try placement.lifecycle().tick();
        if (placement.characters().pollOutcome() != null) {
            return error.ProductCharacterLifecycleDidNotQuiesce;
        }
        while (placement.characters().pollEvent()) |_| {}
        while (placement.npcs().pollOutcome()) |outcome| {
            if (try owner.observe(outcome) != .unrelated) {
                return error.UnexpectedProductNpcLifecycleOutcome;
            }
        }
        while (placement.npcs().pollEvent()) |_| {}
        if (placement.player().pollRespawnActionResult() != null) {
            return error.ProductCharacterRespawnResultDidNotQuiesce;
        }
        while (placement.player().pollLifeEvent()) |event| {
            if (std.meta.eql(event.avatar, current_avatar)) {
                const projected = placement.inspection().replicatedId(
                    current_character.?,
                ) orelse return error.ProductCharacterProjectionMissingAfterRespawn;
                try character_lifecycle.observeLocalLife(
                    current_character,
                    projected,
                    placement.presentation().combatHud(),
                    event,
                );
                if (event.state == .dead) {
                    return error.ProductCharacterDidNotSurviveRespawn;
                }
            }
        }
    }
    const final_hud = placement.presentation().combatHud();
    try std.testing.expect(final_hud.available);
    try std.testing.expect(final_hud.life_state == .alive);
    try std.testing.expect(std.meta.eql(final_hud.avatar, current_avatar));
    try std.testing.expect(
        placement.inspection().clientDiagnostics().authority.first_cycle_fault == null,
    );

    const trace = placement.developer().gameplayTrace();
    const trace_stats = trace.stats();
    try std.testing.expect(trace_stats.occupancy != 0);
    try std.testing.expectEqual(@as(u64, 0), trace_stats.overwritten);
    try std.testing.expect(!trace_stats.frozen);
    var previous_sequence: u64 = 0;
    var melee_submitted = false;
    var melee_admitted = false;
    var melee_applied = false;
    var death_applied = false;
    var respawn_submitted = false;
    var respawn_admitted = false;
    var respawn_applied = false;
    for (0..trace_stats.occupancy) |index| {
        const record = trace.at(index) orelse return error.ProductGameplayTraceGap;
        if (record.sequence <= previous_sequence) return error.ProductGameplayTraceOrder;
        previous_sequence = record.sequence;
        switch (record.kind) {
            .melee => switch (record.stage) {
                .client_submitted => melee_submitted = true,
                .authority_admitted => melee_admitted = true,
                .client_applied => melee_applied = true,
                else => {},
            },
            .death => if (record.stage == .client_applied) {
                death_applied = true;
            },
            .respawn => switch (record.stage) {
                .client_submitted => respawn_submitted = true,
                .authority_admitted => respawn_admitted = true,
                .client_applied => respawn_applied = true,
                else => {},
            },
            else => {},
        }
    }
    try std.testing.expect(melee_submitted and melee_admitted and melee_applied);
    try std.testing.expect(death_applied);
    try std.testing.expect(respawn_submitted and respawn_admitted and respawn_applied);
}
