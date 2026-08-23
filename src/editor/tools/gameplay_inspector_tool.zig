//! Read-only selected-entity gameplay inspector and product status views.
//!
//! The inspector consumes one immutable frame projection. The bounded gameplay
//! event history is rendered in the bottom Diagnostics tool, while its only
//! write surface remains the fixed trace-control mailbox owned by the
//! developer host.

const std = @import("std");
const zgui = @import("zgui");
const engine = @import("incinerator_engine");
const sandbox_host = @import("sandbox_host_contracts");
const population = @import("population_contract");
const tool_module = @import("../tool.zig");

const GameplayInput = tool_module.GameplayInput;
const EntityRef = engine.gameplay_trace.EntityRef;

pub const descriptor = tool_module.Descriptor{
    .id = .gameplay_inspector,
    .name = "Gameplay Inspector",
    .category = .gameplay,
    .default_region = .left,
    .purpose = "Inspect an entity across authority, replication, presentation, relevance, vitals, and navigation.",
    .reads = "Immutable GameplayView projected by the sandbox composition.",
    .requests = "Selection is editor-local; the inspector emits no gameplay mutation requests.",
    .examples = &.{ "npc 1:12:3 authority=present draw=present", "health=75/100 relevance=full_world" },
    .audit_fields = &.{ "wall_unix_ms", "authority_tick", "presentation_frame", "persistent_id", "replicated_entity" },
};

fn sameEntity(first: EntityRef, second: EntityRef) bool {
    return first.namespace == second.namespace and first.local == second.local and
        first.incarnation == second.incarnation;
}

fn selectedIndex(
    view: *const tool_module.GameplayView,
    selection_view: tool_module.selection.View,
) ?usize {
    const entities = view.entitySlice();
    if (selection_view.activeGameplay()) |selected| {
        for (entities, 0..) |entity, index| {
            if (sameEntity(selected, entity.entity)) return index;
        }
    }
    return null;
}

fn recordMatches(record: engine.gameplay_trace.Record, selected: EntityRef) bool {
    if (record.actor) |actor| if (sameEntity(actor, selected)) return true;
    if (record.target) |target| if (sameEntity(target, selected)) return true;
    return false;
}

fn reasonName(
    domain: engine.gameplay_trace.ReasonDomain,
    reason: u32,
) []const u8 {
    return switch (domain) {
        .none => "none",
        .error_code => if (reason == 0 or reason > std.math.maxInt(u16))
            "unknown_error"
        else
            @errorName(@errorFromInt(@as(u16, @intCast(reason)))),
        .protocol_disposition => "protocol_disposition",
        .navigation_reason => if (std.enums.fromInt(
            sandbox_host.NpcNavigationReason,
            reason,
        )) |value|
            @tagName(value)
        else
            "unknown_navigation_reason",
        .population_transition => if (std.enums.fromInt(
            population.TransitionReason,
            reason,
        )) |value|
            @tagName(value)
        else
            "unknown_population_transition",
        .validation_code => "validation_code",
    };
}

fn request(ctx: *const GameplayInput, value: engine.gameplay_trace.Request) void {
    _ = ctx.requests.push(value);
}

pub fn drawPlayerStatus(ctx: *const GameplayInput) void {
    const view = ctx.view;
    zgui.textDisabled("PLAYER", .{});
    const health_color: [4]f32 = if (view.local_life_state == .dead)
        .{ 1, 0.2, 0.15, 1 }
    else if (view.local_damage_feedback)
        .{ 1, 0.55, 0.1, 1 }
    else
        .{ 0.25, 0.95, 0.35, 1 };
    zgui.textColored(
        health_color,
        "HP {d}/{d}  {s}",
        .{
            view.local_health,
            view.local_maximum_health,
            if (view.local_life_state == .dead)
                "DEAD"
            else if (view.local_damage_feedback)
                "DAMAGE RECEIVED"
            else
                "ALIVE",
        },
    );
    if (view.local_life_state == .dead) {
        if (view.respawn_instruction_visible) {
            zgui.textColored(.{ 0.2, 0.9, 1, 1 }, "R: respawn", .{});
        } else {
            zgui.text("Respawn in {d} ticks", .{view.respawn_remaining_ticks});
        }
    } else if (view.melee_remaining_ticks != 0) {
        zgui.text("Melee cooldown: {d} ticks", .{view.melee_remaining_ticks});
    } else {
        zgui.textDisabled(
            "tick {d}  frame {d}",
            .{ view.authority_tick, view.presentation_frame },
        );
    }
}

pub fn drawWeaponStatus(ctx: *const GameplayInput) void {
    const view = ctx.view;
    zgui.textDisabled("HANDGUN", .{});
    zgui.text(
        "{s}  ammo {d}/{d}",
        .{ @tagName(view.weapon_mode), view.magazine_ammo, view.reserve_ammo },
    );
    if (view.reload_remaining_ticks != 0) {
        zgui.textColored(
            .{ 1, 0.8, 0.15, 1 },
            "Reloading: {d} ticks",
            .{view.reload_remaining_ticks},
        );
    } else if (view.weapon_remaining_ticks != 0) {
        zgui.text("Fire cadence: {d} ticks", .{view.weapon_remaining_ticks});
    } else {
        zgui.textColored(
            .{ 0.2, 0.85, 1, 1 },
            "1 equip/holster | LMB fire | R tactical reload",
            .{},
        );
    }
}

pub fn drawThreatStatus(ctx: *const GameplayInput) void {
    const view = ctx.view;
    zgui.textDisabled("THREAT / LAST ACTION", .{});
    var hostile_visible = false;
    for (view.entitySlice()) |entity| {
        if (entity.kind != .npc) continue;
        hostile_visible = true;
        if (entity.attack_windup) {
            zgui.textColored(
                .{ 1, 0.45, 0.08, 1 },
                "HOSTILE ATTACK in {d} ticks",
                .{entity.deadline_tick -| view.authority_tick},
            );
        } else {
            zgui.text(
                "NPC {s}  HP {d}/{d}",
                .{ @tagName(entity.life_state), entity.health, entity.maximum_health },
            );
        }
        break;
    }
    if (!hostile_visible) zgui.textDisabled("No NPC projected", .{});
    if (view.last_action.sequence == 0) {
        zgui.textDisabled("No action result yet", .{});
    } else {
        zgui.textColored(
            if (view.last_action.disposition == .rejected)
                .{ 1, 0.3, 0.2, 1 }
            else
                .{ 0.25, 0.9, 0.35, 1 },
            "{s}: {s} ({s})",
            .{
                @tagName(view.last_action.action),
                @tagName(view.last_action.disposition),
                view.last_action.reasonText(),
            },
        );
    }
}

pub fn draw(
    ctx: *const GameplayInput,
    selection_input: *const tool_module.SelectionInput,
) void {
    if (zgui.begin("Gameplay Inspector", .{})) {
        const view = ctx.view;
        const entities = view.entitySlice();
        const selected_index = selectedIndex(view, selection_input.view);

        zgui.text(
            "Authority tick {d} | presentation frame {d} | entities {d}",
            .{ view.authority_tick, view.presentation_frame, entities.len },
        );
        zgui.text(
            "Local HP {d}/{d} | {s} | melee {d}t | respawn {d}t{s}",
            .{
                view.local_health,
                view.local_maximum_health,
                @tagName(view.local_life_state),
                view.melee_remaining_ticks,
                view.respawn_remaining_ticks,
                if (view.respawn_instruction_visible) " (press R)" else "",
            },
        );
        if (view.last_action.sequence != 0) {
            zgui.textColored(
                if (view.last_action.disposition == .rejected)
                    .{ 1, 0.35, 0.25, 1 }
                else
                    .{ 0.25, 0.9, 0.35, 1 },
                "Last action #{d}: {s} {s} ({s}) at tick {d}",
                .{
                    view.last_action.sequence,
                    @tagName(view.last_action.action),
                    @tagName(view.last_action.disposition),
                    view.last_action.reasonText(),
                    view.last_action.observed_tick,
                },
            );
        }

        zgui.separatorText("Selected entity");
        if (selected_index) |index| {
            if (zgui.button("Previous", .{})) {
                selection_input.requests.submit(.{ .select = .{
                    .gameplay_entity = entities[(index + entities.len - 1) % entities.len].entity,
                } });
            }
            zgui.sameLine(.{});
            if (zgui.button("Local player", .{})) {
                for (entities) |entity| if (entity.kind == .local_player) {
                    selection_input.requests.submit(.{ .select = .{
                        .gameplay_entity = entity.entity,
                    } });
                    break;
                };
            }
            zgui.sameLine(.{});
            if (zgui.button("Next", .{})) {
                selection_input.requests.submit(.{ .select = .{
                    .gameplay_entity = entities[(index + 1) % entities.len].entity,
                } });
            }

            const entity = entities[index];
            zgui.text(
                "{s}: replicated {d}:{d}:{d}",
                .{
                    @tagName(entity.kind),
                    entity.entity.namespace,
                    entity.entity.local,
                    entity.entity.incarnation,
                },
            );
            if (entity.persistent_id) |persistent| {
                zgui.text(
                    "persistent {d}:{d}",
                    .{ persistent.namespace, persistent.local },
                );
            } else {
                zgui.text("persistent unavailable", .{});
            }
            zgui.text(
                "authority/replication/presentation/draw: {s}/{s}/{s}/{s}",
                .{
                    @tagName(entity.authority_presence),
                    @tagName(entity.replication_presence),
                    @tagName(entity.presentation_presence),
                    @tagName(entity.draw_presence),
                },
            );
            if (entity.removal_reason != .none) zgui.text(
                "removed: {s} tick={d} frame={d}",
                .{ @tagName(entity.removal_reason), entity.removed_tick, entity.removed_frame },
            );
            if (entity.relevance_included) |included| zgui.text(
                "relevance: {s} included={} eval={d} baseline={d} snapshot={d} grace={d} distance={d:.2}m",
                .{
                    @tagName(entity.relevance_reason),
                    included,
                    entity.relevance_evaluated_tick,
                    entity.relevance_baseline_id,
                    entity.relevance_snapshot_sequence,
                    entity.relevance_grace_until_tick,
                    @sqrt(entity.relevance_distance_squared_xz),
                },
            ) else zgui.text("relevance: unavailable", .{});
            if (entity.relevance_included != null) zgui.text(
                "observer district ({d},{d}) -> owner ({d},{d}) encounter={}",
                .{
                    entity.relevance_observer_district[0],
                    entity.relevance_observer_district[1],
                    entity.relevance_owner_district[0],
                    entity.relevance_owner_district[1],
                    entity.relevance_encounter,
                },
            );
            zgui.text(
                "life {s} | HP {d}/{d} | encounter {d} | deadline {d}",
                .{
                    @tagName(entity.life_state),
                    entity.health,
                    entity.maximum_health,
                    entity.encounter_state,
                    entity.deadline_tick,
                },
            );
            zgui.text(
                "authority ({d:.3}, {d:.3}, {d:.3})",
                .{
                    entity.authority_position[0],
                    entity.authority_position[1],
                    entity.authority_position[2],
                },
            );
            zgui.text(
                "presentation ({d:.3}, {d:.3}, {d:.3})",
                .{
                    entity.presentation_position[0],
                    entity.presentation_position[1],
                    entity.presentation_position[2],
                },
            );
            zgui.text(
                "velocity ({d:.3}, {d:.3}, {d:.3}) | yaw {d:.3}",
                .{ entity.velocity[0], entity.velocity[1], entity.velocity[2], entity.facing_yaw },
            );
            zgui.text(
                "controller radius {d:.3} half-height {d:.3} | nearest {?d:.3}",
                .{ entity.radius, entity.half_height, entity.nearest_actor_separation },
            );
            if (entity.kind == .npc) {
                if (entity.population_member) |member| {
                    zgui.text(
                        "population member {d} | role {s} | disposition {s}",
                        .{
                            member.value,
                            if (entity.population_role) |value|
                                @tagName(value)
                            else
                                "unavailable",
                            if (entity.population_disposition) |value|
                                @tagName(value)
                            else
                                "unavailable",
                        },
                    );
                    zgui.text(
                        "activity {s} / {s}",
                        .{
                            if (entity.population_activity_kind) |value|
                                @tagName(value)
                            else
                                "unavailable",
                            if (entity.population_activity_state) |value|
                                @tagName(value)
                            else
                                "unavailable",
                        },
                    );
                } else {
                    zgui.text("population member unavailable (synthetic NPC)", .{});
                }
                zgui.text(
                    "navigation {s} | no-progress {d} ticks | last progress {d}",
                    .{
                        @tagName(entity.navigation_progress),
                        entity.navigation_no_progress_ticks,
                        entity.navigation_last_progress_tick,
                    },
                );
                if (entity.navigation_target) |target| zgui.text(
                    "navigation target ({d:.3}, {d:.3}, {d:.3})",
                    .{ target[0], target[1], target[2] },
                );
                if (entity.navigation_destination) |destination| zgui.text(
                    "destination {s} ({d})",
                    .{
                        sandbox_host.destinationName(destination) orelse "unknown",
                        destination.value,
                    },
                );
                if (entity.navigation_status) |status| zgui.text(
                    "status {s} / {s} | trigger {s} -> {s}",
                    .{
                        @tagName(status),
                        if (entity.navigation_reason) |reason|
                            @tagName(reason)
                        else
                            "none",
                        if (entity.navigation_trigger) |trigger|
                            @tagName(trigger)
                        else
                            "none",
                        if (entity.navigation_result) |result|
                            @tagName(result)
                        else
                            "none",
                    },
                );
                zgui.text(
                    "route rev {d} topo {d} digest 0x{x} | node {d}/{d} active {d} cost {d}",
                    .{
                        entity.navigation_route_revision,
                        entity.navigation_topology_revision,
                        entity.navigation_route_digest,
                        entity.navigation_route_index,
                        entity.navigation_route_length,
                        entity.navigation_active_prefix_length,
                        entity.navigation_route_cost,
                    },
                );
                zgui.text(
                    "replans {d} | arrival tick {?d}",
                    .{ entity.navigation_replan_count, entity.navigation_arrival_tick },
                );
                zgui.text(
                    "physical exclusions {d} | retry tick {d}",
                    .{
                        entity.navigation_physical_exclusion_count,
                        entity.navigation_physical_block_retry_tick,
                    },
                );
            }
            if (entity.target) |target| {
                zgui.text(
                    "target {d}:{d}:{d}",
                    .{ target.namespace, target.local, target.incarnation },
                );
            } else {
                zgui.text("target none", .{});
            }
        } else {
            if (entities.len == 0) {
                zgui.text("No gameplay entities projected", .{});
            } else {
                if (zgui.button("Select local player", .{})) {
                    for (entities) |entity| if (entity.kind == .local_player) {
                        selection_input.requests.submit(.{ .select = .{
                            .gameplay_entity = entity.entity,
                        } });
                        break;
                    };
                }
                zgui.textDisabled(
                    "Select a gameplay entity in World Outliner or the Free Camera viewport.",
                    .{},
                );
            }
        }
    }
    zgui.end();
}

/// Bottom-wide diagnostic history for the entity selected in Gameplay
/// Inspector. Recording controls affect only this bounded history; they never
/// pause or resume gameplay.
pub fn drawEventHistory(ctx: *const GameplayInput, selected: ?EntityRef) void {
    if (!zgui.collapsingHeader("Gameplay event history", .{})) return;
    zgui.textWrapped(
        "Recent authority events for the selected entity: requests, admission, outcomes, replication, and presentation. This is diagnostic history, not a gameplay mode or a replay.",
        .{},
    );
    const stats = ctx.trace.summary;
    zgui.text(
        "Recorded {d}/{d} | peak {d} | overwritten {d} | recording {s} | rejected while paused {d}",
        .{
            stats.occupancy,
            stats.capacity,
            stats.high_water,
            stats.overwritten,
            if (stats.frozen) "PAUSED" else "ACTIVE",
            stats.rejected_while_frozen,
        },
    );
    zgui.text("UI request rejections {d}", .{ctx.requests.rejected});
    if (zgui.button("Pause event recording", .{})) request(ctx, .freeze);
    zgui.sameLine(.{});
    if (zgui.button("Resume event recording", .{})) request(ctx, .resume_capture);
    zgui.sameLine(.{});
    if (zgui.button("Clear event history", .{})) request(ctx, .clear);

    if (selected) |entity| {
        if (zgui.beginChild("##gameplay_event_entries", .{
            .h = 180,
            .child_flags = .{ .frame_style = true },
        })) {
            const first = ctx.trace.len() -| 128;
            var matches: usize = 0;
            for (first..ctx.trace.len()) |trace_index| {
                const record = ctx.trace.at(trace_index).?;
                if (!recordMatches(record, entity)) continue;
                matches += 1;
                zgui.text(
                    "#{d} tick={d} {s}/{s}/{s} {s} reason={s}:{d} correlation={d}",
                    .{
                        record.sequence,
                        record.authority_tick,
                        @tagName(record.source),
                        @tagName(record.stage),
                        @tagName(record.kind),
                        @tagName(record.disposition),
                        reasonName(record.reason_domain, record.reason),
                        record.reason,
                        record.correlation_id,
                    },
                );
            }
            if (matches == 0) zgui.textDisabled(
                "No recent events match the selected entity.",
                .{},
            );
        }
        zgui.endChild();
    } else {
        zgui.textDisabled(
            "Select a gameplay entity in World Outliner, Gameplay Inspector, or the Free Camera viewport to filter the history.",
            .{},
        );
    }
}

test "gameplay inspector resolves only the shared stable selection" {
    var view = tool_module.GameplayView{
        .authority_tick = 1,
        .presentation_frame = 2,
    };
    view.entities[0] = .{
        .entity = .{ .namespace = 1, .local = 7, .incarnation = 1 },
        .kind = .npc,
        .authority_presence = .present,
        .replication_presence = .present,
        .presentation_presence = .present,
        .draw_presence = .present,
        .authority_position = .{ 0, 0, 0 },
        .presentation_position = .{ 0, 0, 0 },
        .radius = 0.35,
        .half_height = 0.45,
        .health = 100,
        .maximum_health = 100,
        .life_state = .alive,
    };
    view.entities[1] = view.entities[0];
    view.entities[1].entity.local = 1;
    view.entities[1].kind = .local_player;
    view.entity_count = 2;
    const selected = tool_module.selection.View{
        .entries = &.{},
        .active = .{ .gameplay_entity = view.entities[1].entity },
    };
    try std.testing.expectEqual(@as(?usize, 1), selectedIndex(&view, selected));
    try std.testing.expectEqual(
        @as(?usize, null),
        selectedIndex(&view, .{ .entries = &.{}, .active = null }),
    );
}
