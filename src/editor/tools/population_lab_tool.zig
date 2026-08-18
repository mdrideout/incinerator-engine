//! Read-only authored-population inspection and visualization controls.
//!
//! Population intent remains owned by the simulation host. This tool retains
//! only a selected stable member ID and emits existing visualization requests.

const std = @import("std");
const zgui = @import("zgui");
const population = @import("population_contract");
const developer_visualization = @import("developer_visualization");
const tool_module = @import("../tool.zig");

pub const descriptor = tool_module.Descriptor{
    .id = .population_lab,
    .name = "Population Lab",
    .category = .world,
    .default_region = .left,
    .purpose = "Inspect stable authored population identity, role, activity, slot contention, and replacement.",
    .reads = "Population catalog, member/slot records, diagnostics, gameplay projection, and visualization state.",
    .requests = "Emits bounded population/navigation visualization requests only.",
    .examples = &.{ "member=P03 role=worker activity=commute", "slot=depot_bench owner=P07" },
    .audit_fields = &.{ "authority_tick", "population_member", "activity_revision", "persistent_id" },
};

pub const State = struct {
    selected: ?population.PopulationMemberId = null,
};

fn memberDefinition(
    catalog: population.Catalog,
    id: population.PopulationMemberId,
) ?population.PopulationMemberDefinition {
    for (catalog.members) |definition| {
        if (population.PopulationMemberId.eql(definition.id, id)) return definition;
    }
    return null;
}

fn programDefinition(
    catalog: population.Catalog,
    id: population.ActivityProgramId,
) ?population.ActivityProgramDefinition {
    for (catalog.programs) |definition| {
        if (population.ActivityProgramId.eql(definition.id, id)) return definition;
    }
    return null;
}

fn slotDefinition(
    catalog: population.Catalog,
    id: population.ActivitySlotId,
) ?population.ActivitySlotDefinition {
    for (catalog.activity_slots) |definition| {
        if (population.ActivitySlotId.eql(definition.id, id)) return definition;
    }
    return null;
}

fn roleColor(catalog: population.Catalog, role: population.Role) [4]f32 {
    for (catalog.roles) |definition| {
        if (definition.role == role) return definition.base_color;
    }
    return .{ 1, 1, 1, 1 };
}

fn selectedMember(
    state: *State,
    members: []const population.MemberRecordV1,
) ?population.MemberRecordV1 {
    if (state.selected == null and members.len != 0) {
        state.selected = members[0].id;
    }
    const selected = state.selected orelse return null;
    for (members) |member| {
        if (population.PopulationMemberId.eql(member.id, selected)) return member;
    }
    state.selected = null;
    return null;
}

fn request(
    ctx: *const tool_module.PopulationInput,
    value: developer_visualization.Request,
) void {
    _ = ctx.visualization_requests.push(value);
}

pub fn draw(
    state: *State,
    ctx: *const tool_module.PopulationInput,
) void {
    if (zgui.begin("Population Lab", .{})) {
        const view = ctx.view;
        if (view.diagnostics) |diagnostics| {
            zgui.text(
                "members live {d}, awaiting {d}, vacant {d}, replacement {d}",
                .{
                    diagnostics.live,
                    diagnostics.awaiting_spawn,
                    diagnostics.vacant,
                    diagnostics.replacement_pending,
                },
            );
            zgui.text(
                "activity traveling {d}, dwelling {d}, waiting {d}, interrupted {d}",
                .{
                    diagnostics.traveling,
                    diagnostics.dwelling,
                    diagnostics.waiting_for_slot,
                    diagnostics.interrupted,
                },
            );
            zgui.text(
                "slots free {d}, claimed {d}, occupied {d} | contention {d}",
                .{
                    diagnostics.free_slots,
                    diagnostics.claimed_slots,
                    diagnostics.occupied_slots,
                    diagnostics.slot_contentions,
                },
            );
            zgui.text(
                "decisions {d}, lease expirations {d}, spawn retries {d}",
                .{
                    diagnostics.decisions,
                    diagnostics.lease_expirations,
                    diagnostics.spawn_retries.total(),
                },
            );
        } else {
            zgui.text("Authored product population is disabled for this host.", .{});
        }

        zgui.separatorText("World overlays");
        zgui.text(
            "Bounds debug includes spawn slots, activity claims, and member destinations.",
            .{},
        );
        if (!ctx.visualization.config.enabled or
            !ctx.visualization.config.bounds)
        {
            if (zgui.button("Enable population world overlays", .{})) {
                request(ctx, .{ .set_enabled = true });
                request(ctx, .{ .set_category = .{
                    .category = .bounds,
                    .enabled = true,
                } });
            }
        } else {
            zgui.textColored(
                .{ 0.25, 0.9, 0.4, 1 },
                "Population world overlays enabled",
                .{},
            );
        }

        zgui.separatorText("Stable members");
        if (view.members.len == 0) {
            zgui.text("No population records.", .{});
        }
        for (view.members) |member| {
            const definition = memberDefinition(view.catalog, member.id) orelse continue;
            var label: [160]u8 = undefined;
            const text = std.fmt.bufPrintZ(
                &label,
                "{s} #{d}  {s} / {s}##population-member-{d}",
                .{
                    definition.label,
                    member.id.value,
                    @tagName(definition.role),
                    @tagName(member.activity_state),
                    member.id.value,
                },
            ) catch continue;
            if (zgui.selectable(text, .{
                .selected = if (state.selected) |selected|
                    population.PopulationMemberId.eql(selected, member.id)
                else
                    false,
            })) {
                state.selected = member.id;
            }
        }

        if (selectedMember(state, view.members)) |member| {
            const definition = memberDefinition(view.catalog, member.id) orelse {
                zgui.end();
                return;
            };
            const color = roleColor(view.catalog, definition.role);
            zgui.separatorText("Selected member");
            zgui.textColored(
                color,
                "{s} #{d}: {s} / {s}",
                .{
                    definition.label,
                    member.id.value,
                    @tagName(definition.role),
                    @tagName(definition.combat_disposition),
                },
            );
            zgui.text(
                "lifecycle {s}, activity {s}, generation {d}",
                .{
                    @tagName(member.lifecycle),
                    @tagName(member.activity_state),
                    member.actor_generation,
                },
            );
            if (member.actor) |actor| {
                zgui.text(
                    "actor {d}:{d}",
                    .{ actor.namespace, actor.local },
                );
            } else {
                zgui.text("actor unavailable", .{});
            }
            if (programDefinition(view.catalog, definition.program)) |program| {
                const cursor = @min(
                    @as(usize, member.program_cursor),
                    program.stepSlice().len -| 1,
                );
                const step = program.stepSlice()[cursor];
                zgui.text(
                    "program {s} step {d}/{d}: {s}",
                    .{
                        program.label,
                        cursor + 1,
                        program.stepSlice().len,
                        @tagName(step.kind),
                    },
                );
            }
            if (member.activity_slot) |slot_id| {
                if (slotDefinition(view.catalog, slot_id)) |slot| {
                    zgui.text(
                        "slot {s} #{d}, destination {d}",
                        .{ slot.label, slot.id.value, slot.destination.value },
                    );
                    zgui.text(
                        "position ({d:.2}, {d:.2}, {d:.2})",
                        .{ slot.position[0], slot.position[1], slot.position[2] },
                    );
                }
            } else {
                zgui.text("activity slot unassigned", .{});
            }
            zgui.text(
                "sequence {d}, deadline {d}, retry {d}",
                .{
                    member.activity_sequence,
                    member.deadline_tick,
                    member.retry_tick,
                },
            );
            zgui.text(
                "last transition tick {d}: {s}",
                .{ member.last_transition_tick, @tagName(member.last_transition_reason) },
            );
            zgui.text(
                "spawn candidate {d}, retry reason {s}, retries {d}",
                .{
                    member.spawn_candidate_cursor,
                    @tagName(member.spawn_retry_reason),
                    member.spawn_retry_counts.total(),
                },
            );
        }
    }
    zgui.end();
}

test "population lab resolves stable catalog identities" {
    const definition = population.PopulationMemberDefinition{
        .id = .{ .value = 1 },
        .label = "member",
        .ordinary_product = true,
        .role = .resident,
        .program = .{ .value = 1 },
        .phase_offset = 0,
        .combat_disposition = .passive,
        .initial_spawn_slot = .{ .value = 1 },
        .replacement_spawn_slot_count = 0,
    };
    const catalog = population.Catalog{
        .roles = &.{},
        .programs = &.{},
        .members = &.{definition},
        .sites = &.{},
        .activity_slots = &.{},
        .spawn_slots = &.{},
    };
    try std.testing.expectEqual(
        definition,
        memberDefinition(catalog, .{ .value = 1 }).?,
    );
    try std.testing.expect(memberDefinition(catalog, .{ .value = 2 }) == null);
}
