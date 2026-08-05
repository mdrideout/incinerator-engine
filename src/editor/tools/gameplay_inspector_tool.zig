//! Read-only selected-entity gameplay inspector and causal trace viewer.
//!
//! The tool consumes one immutable frame projection and a type-erased trace
//! borrow. Its only write surface is the fixed trace-control mailbox owned by
//! the developer host.

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
    .enabled_by_default = true,
};

pub const State = struct {
    selected: ?EntityRef = null,
};

fn sameEntity(first: EntityRef, second: EntityRef) bool {
    return first.namespace == second.namespace and first.local == second.local and
        first.incarnation == second.incarnation;
}

fn selectedIndex(
    state: *State,
    view: *const tool_module.GameplayView,
) ?usize {
    const entities = view.entitySlice();
    if (entities.len == 0) {
        state.selected = null;
        return null;
    }
    if (state.selected) |selected| {
        for (entities, 0..) |entity, index| {
            if (sameEntity(selected, entity.entity)) return index;
        }
    }
    for (entities, 0..) |entity, index| {
        if (entity.kind == .local_player) {
            state.selected = entity.entity;
            return index;
        }
    }
    state.selected = entities[0].entity;
    return 0;
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

/// Always-on, presentation-only product feedback. It deliberately remains
/// visible when the developer windows are hidden with F1.
pub fn drawProductHud(ctx: *const GameplayInput) void {
    const view = ctx.view;
    zgui.setNextWindowPos(.{ .x = 10, .y = 38, .cond = .always });
    zgui.setNextWindowBgAlpha(.{ .alpha = 0.72 });
    if (zgui.begin("##gameplay_product_hud", .{
        .flags = .{
            .no_title_bar = true,
            .no_resize = true,
            .no_move = true,
            .no_collapse = true,
            .always_auto_resize = true,
            .no_saved_settings = true,
            .no_focus_on_appearing = true,
        },
    })) {
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
                zgui.textColored(.{ 0.2, 0.9, 1, 1 }, "Press R to respawn", .{});
            } else {
                zgui.text(
                    "Respawn available in {d} ticks",
                    .{view.respawn_remaining_ticks},
                );
            }
        } else if (view.melee_remaining_ticks != 0) {
            zgui.text("Melee cooldown: {d} ticks", .{view.melee_remaining_ticks});
        }

        for (view.entitySlice()) |entity| {
            if (entity.kind != .npc or !entity.attack_windup) continue;
            zgui.textColored(
                .{ 1, 0.45, 0.08, 1 },
                "HOSTILE ATTACK in {d} ticks",
                .{entity.deadline_tick -| view.authority_tick},
            );
            break;
        }
        if (view.last_action.sequence != 0 and
            view.last_action.disposition == .rejected)
        {
            zgui.textColored(
                .{ 1, 0.3, 0.2, 1 },
                "{s} rejected: {s}",
                .{
                    @tagName(view.last_action.action),
                    view.last_action.reasonText(),
                },
            );
        }
    }
    zgui.end();
}

pub fn draw(
    state: *State,
    ctx: *const GameplayInput,
) void {
    zgui.setNextWindowPos(.{ .x = 850, .y = 30, .cond = .first_use_ever });
    zgui.setNextWindowSize(.{ .w = 560, .h = 700, .cond = .first_use_ever });

    if (zgui.begin("Gameplay Inspector", .{})) {
        const view = ctx.view;
        const entities = view.entitySlice();
        const selected_index = selectedIndex(state, view);

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
                state.selected = entities[(index + entities.len - 1) % entities.len].entity;
            }
            zgui.sameLine(.{});
            if (zgui.button("Local player", .{})) {
                for (entities) |entity| if (entity.kind == .local_player) {
                    state.selected = entity.entity;
                    break;
                };
            }
            zgui.sameLine(.{});
            if (zgui.button("Next", .{})) {
                state.selected = entities[(index + 1) % entities.len].entity;
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
            zgui.text("No gameplay entities projected", .{});
        }

        zgui.separatorText("Causal gameplay trace");
        const stats = ctx.trace.summary;
        zgui.text(
            "{d}/{d}, peak {d}, overwritten {d}, frozen {}, rejected {d}",
            .{
                stats.occupancy,
                stats.capacity,
                stats.high_water,
                stats.overwritten,
                stats.frozen,
                stats.rejected_while_frozen,
            },
        );
        zgui.text("UI request rejections {d}", .{ctx.requests.rejected});
        if (zgui.button("Freeze", .{})) request(ctx, .freeze);
        zgui.sameLine(.{});
        if (zgui.button("Resume", .{})) request(ctx, .resume_capture);
        zgui.sameLine(.{});
        if (zgui.button("Clear", .{})) request(ctx, .clear);

        if (state.selected) |selected| {
            const first = ctx.trace.len() -| 128;
            for (first..ctx.trace.len()) |trace_index| {
                const record = ctx.trace.at(trace_index).?;
                if (!recordMatches(record, selected)) continue;
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
        }
    }
    zgui.end();
}

test "selection follows stable identity and defaults to local player" {
    var state = State{};
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
    try std.testing.expectEqual(@as(?usize, 1), selectedIndex(&state, &view));
    try std.testing.expectEqual(@as(u64, 1), state.selected.?.local);
}
