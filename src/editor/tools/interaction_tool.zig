//! Optional S7 interaction inspector and semantic command producer.
//!
//! The tool renders immutable host-owned values and appends the exact same
//! collect/drop command used by keyboard and scripted producers to a fixed
//! mailbox. It never polls outcomes or reaches simulation/physics authority.

const std = @import("std");
const zgui = @import("zgui");
const sandbox_host = @import("sandbox_host_contracts");
const sandbox_interaction = @import("sandbox_interaction");
const tool_module = @import("../tool.zig");

const InteractionInput = tool_module.InteractionInput;

pub const descriptor = tool_module.Descriptor{
    .id = .interaction,
    .name = "Interaction",
    .enabled_by_default = true,
};

fn drawIdentity(label: []const u8, id: sandbox_host.PersistentId) void {
    zgui.text(
        "{s}: namespace={d}, local={d}",
        .{ label, id.namespace, id.local },
    );
}

fn proposedCommand(
    view: *const tool_module.InteractionView,
) ?sandbox_interaction.Request {
    const carrier = view.carrier orelse return null;
    const carryable = view.carryable orelse return null;
    const transaction_id = view.next_transaction_id orelse return null;
    switch (carrier.driver_mode) {
        .on_foot => {},
        .driving => return null,
    }
    return switch (carryable.ownership) {
        .district_owned => .{ .collect = .{
            .transaction_id = transaction_id,
            .carrier_id = carrier.id,
            .carryable_id = carryable.id,
        } },
        .inventory_held => |holder| if (std.meta.eql(holder, carrier.id))
            .{ .drop = .{
                .transaction_id = transaction_id,
                .carrier_id = carrier.id,
                .carryable_id = carryable.id,
                .purpose = .player_requested,
            } }
        else
            null,
    };
}

fn drawOutcome(outcome: sandbox_host.InteractionOutcome) void {
    zgui.separatorText("Last authority result");
    switch (outcome) {
        .spawned => |spawned| {
            zgui.textColored(.{ 0.25, 0.9, 0.35, 1 }, "Spawned", .{});
            drawIdentity("Carryable", spawned.id);
            zgui.text("District: ({d}, {d})", .{ spawned.owner.x, spawned.owner.z });
        },
        .despawned => |id| {
            zgui.textColored(.{ 0.25, 0.9, 0.35, 1 }, "Despawned", .{});
            drawIdentity("Carryable", id);
        },
        .collected => |collected| {
            zgui.textColored(.{ 0.25, 0.9, 0.35, 1 }, "Collected", .{});
            zgui.text("Transaction: {d}", .{collected.transaction_id});
            drawIdentity("Carrier", collected.carrier_id);
            drawIdentity("Carryable", collected.carryable_id);
        },
        .dropped => |dropped| {
            zgui.textColored(.{ 0.25, 0.9, 0.35, 1 }, "Dropped", .{});
            zgui.text("Transaction: {d}", .{dropped.transaction_id});
            zgui.text("District: ({d}, {d})", .{ dropped.owner.x, dropped.owner.z });
            drawIdentity("Carryable", dropped.carryable_id);
        },
        .rejected => |rejected| {
            zgui.textColored(.{ 1, 0.35, 0.25, 1 }, "Rejected", .{});
            zgui.text(
                "Command {s}: {s}",
                .{ @tagName(rejected.command), @tagName(rejected.reason) },
            );
            if (rejected.transaction_id) |transaction_id| {
                zgui.text("Transaction: {d}", .{transaction_id});
            }
        },
    }
}

pub fn draw(ctx: *const InteractionInput) void {
    const view = ctx.view;
    zgui.setNextWindowPos(.{ .x = 850, .y = 560, .cond = .first_use_ever });
    zgui.setNextWindowSize(.{ .w = 430, .h = 390, .cond = .first_use_ever });

    if (zgui.begin("Interaction", .{})) {
        zgui.text(
            "UI mailbox rejected: {d}",
            .{@max(view.request_rejections, ctx.requests.rejected)},
        );
        zgui.text("Submission failures: {d}", .{view.submission_failures});

        zgui.separatorText("Carrier");
        if (view.carrier) |carrier| {
            drawIdentity("Character", carrier.id);
            zgui.text(
                "Mode: {s}",
                .{@tagName(std.meta.activeTag(carrier.driver_mode))},
            );
            zgui.text(
                "Position: ({d:.2}, {d:.2}, {d:.2})",
                .{ carrier.position[0], carrier.position[1], carrier.position[2] },
            );
        } else {
            zgui.text("No carrier", .{});
        }

        zgui.separatorText("Carryable");
        if (view.carryable) |carryable| {
            drawIdentity("Carryable", carryable.id);
            switch (carryable.ownership) {
                .district_owned => |coord| zgui.text(
                    "District owned: ({d}, {d})",
                    .{ coord.x, coord.z },
                ),
                .inventory_held => |holder| {
                    zgui.text("Inventory held", .{});
                    drawIdentity("Holder", holder);
                },
            }
            zgui.text("Body present: {}", .{carryable.body_present});
            zgui.text(
                "Durable pose: ({d:.2}, {d:.2}, {d:.2})",
                .{
                    carryable.state.pose.position[0],
                    carryable.state.pose.position[1],
                    carryable.state.pose.position[2],
                },
            );
        } else {
            zgui.text("No carryable", .{});
        }

        const command = proposedCommand(view);
        zgui.beginDisabled(.{ .disabled = command == null });
        const label: [:0]const u8 = if (command) |value| switch (value) {
            .collect => "Collect",
            .drop => "Drop",
            .spawn, .despawn => "Unavailable",
        } else "Unavailable";
        if (zgui.button(label, .{})) {
            _ = ctx.requests.push(command.?);
        }
        zgui.endDisabled();
        zgui.sameLine(.{});
        zgui.text("Same admitted client action as F", .{});

        if (view.last_outcome) |outcome| drawOutcome(outcome);
    }
    zgui.end();
}
