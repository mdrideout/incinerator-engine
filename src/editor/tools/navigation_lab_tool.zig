//! S12 semantic navigation control and inspection surface.
//!
//! This tool owns only UI selection. Destination and gate mutations are copied
//! into the fixed App-owned mailbox and applied through typed authority roles
//! after the immutable editor frame has ended.

const std = @import("std");
const zgui = @import("zgui");
const sandbox_host = @import("sandbox_host_contracts");
const tool_module = @import("../tool.zig");

pub const descriptor = tool_module.Descriptor{
    .id = .navigation_lab,
    .name = "Navigation Lab",
    .enabled_by_default = true,
};

pub const State = struct {
    selected: ?sandbox_host.PersistentId = null,
};

const destinations = [_]sandbox_host.DestinationId{
    sandbox_host.player_plaza_destination,
    sandbox_host.depot_forecourt_destination,
    sandbox_host.south_gate_approach_destination,
    sandbox_host.market_terminal_destination,
    sandbox_host.alley_junction_destination,
    sandbox_host.transit_yard_destination,
};

fn selectedNpc(
    state: *State,
    gameplay: *const tool_module.GameplayView,
) ?sandbox_host.PersistentId {
    const selected = state.selected orelse return null;
    for (gameplay.entitySlice()) |entity| {
        if (entity.kind == .npc and
            entity.entity.namespace == selected.namespace and
            entity.entity.local == selected.local)
        {
            return selected;
        }
    }
    state.selected = null;
    return null;
}

pub fn draw(
    state: *State,
    ctx: *const tool_module.NavigationInput,
) void {
    zgui.setNextWindowPos(.{ .x = 40, .y = 380, .cond = .first_use_ever });
    zgui.setNextWindowSize(.{ .w = 510, .h = 470, .cond = .first_use_ever });
    if (zgui.begin("Navigation Lab", .{})) {
        zgui.text(
            "Topology revision {d} | mailbox rejected {d}",
            .{ ctx.view.topology_revision, ctx.requests.rejected },
        );

        zgui.separatorText("Traversal gates");
        var north_open = ctx.view.north_gate_open;
        if (zgui.checkbox("North Gate open", .{ .v = &north_open })) {
            _ = ctx.requests.push(.{ .set_gate = .{
                .gate = .north,
                .open = north_open,
            } });
        }
        var south_open = ctx.view.south_gate_open;
        if (zgui.checkbox("South Gate open", .{ .v = &south_open })) {
            _ = ctx.requests.push(.{ .set_gate = .{
                .gate = .south,
                .open = south_open,
            } });
        }

        zgui.separatorText("NPC selection");
        var npc_count: usize = 0;
        for (ctx.gameplay.entitySlice()) |entity| {
            if (entity.kind != .npc) continue;
            npc_count += 1;
            var label: [128]u8 = undefined;
            const text = std.fmt.bufPrintZ(
                &label,
                "NPC {d}:{d}  {s}##navigation-npc-{d}-{d}",
                .{
                    entity.entity.namespace,
                    entity.entity.local,
                    if (entity.navigation_status) |status|
                        @tagName(status)
                    else
                        "unavailable",
                    entity.entity.namespace,
                    entity.entity.local,
                },
            ) catch continue;
            const candidate = sandbox_host.PersistentId{
                .namespace = entity.entity.namespace,
                .local = entity.entity.local,
            };
            if (zgui.selectable(text, .{
                .selected = if (state.selected) |selected|
                    std.meta.eql(selected, candidate)
                else
                    false,
            })) {
                state.selected = candidate;
            }
        }
        if (npc_count == 0) zgui.text("No authority-owned NPC is projected.", .{});

        zgui.separatorText("Semantic destination");
        const selected = selectedNpc(state, ctx.gameplay);
        zgui.beginDisabled(.{ .disabled = selected == null });
        for (destinations, 0..) |destination, index| {
            const name = sandbox_host.destinationName(destination) orelse "unknown";
            var label: [96]u8 = undefined;
            const text = std.fmt.bufPrintZ(
                &label,
                "{s} ({d})##destination-{d}",
                .{ name, destination.value, destination.value },
            ) catch continue;
            if (zgui.button(text, .{})) {
                _ = ctx.requests.push(.{ .set_destination = .{
                    .npc = selected.?,
                    .destination = destination,
                } });
            }
            if (index % 2 == 0) zgui.sameLine(.{});
        }
        zgui.endDisabled();

        if (selected) |id| {
            for (ctx.gameplay.entitySlice()) |entity| {
                if (entity.kind != .npc or entity.entity.namespace != id.namespace or
                    entity.entity.local != id.local) continue;
                zgui.separatorText("Selected route");
                zgui.text(
                    "status {s} / {s}",
                    .{
                        if (entity.navigation_status) |value|
                            @tagName(value)
                        else
                            "unavailable",
                        if (entity.navigation_reason) |value|
                            @tagName(value)
                        else
                            "unavailable",
                    },
                );
                zgui.text(
                    "route rev {d} topology {d} digest {x} index {d}/{d}",
                    .{
                        entity.navigation_route_revision,
                        entity.navigation_topology_revision,
                        entity.navigation_route_digest,
                        entity.navigation_route_index,
                        entity.navigation_route_length,
                    },
                );
                zgui.text(
                    "active prefix {d} cost {d} replans {d}",
                    .{
                        entity.navigation_active_prefix_length,
                        entity.navigation_route_cost,
                        entity.navigation_replan_count,
                    },
                );
                zgui.text(
                    "physical exclusions {d} | retry tick {d}",
                    .{
                        entity.navigation_physical_exclusion_count,
                        entity.navigation_physical_block_retry_tick,
                    },
                );
                break;
            }
        }
    }
    zgui.end();
}
