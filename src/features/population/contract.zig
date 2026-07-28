//! Canonical fixed, non-authoritative NPC population command contract.
//!
//! Planning owns no identity, entity, outcome, snapshot, allocator, or mutable
//! runtime state. Each emitted spawn remains an independent NPC transaction.

const std = @import("std");
const npc = @import("npc_contract");

pub const max_population_commands: usize = 64;

pub const Template = struct {
    first_request_id: u64,
    start_node: npc.NodeRef,
    goal: npc.Goal,
};

pub const Batch = struct {
    commands: [max_population_commands]npc.Command = undefined,
    len: u8 = 0,

    pub fn slice(self: *const Batch) []const npc.Command {
        return self.commands[0..self.len];
    }
};

pub fn plan(count: usize, template: Template) !Batch {
    if (count > max_population_commands) return error.PopulationCapacityExceeded;
    if (count != 0 and template.first_request_id == 0) {
        return error.InvalidPopulationRequestId;
    }
    if (count != 0 and
        template.first_request_id > std.math.maxInt(u64) - (count - 1))
    {
        return error.PopulationRequestIdOverflow;
    }
    var result = Batch{ .len = @intCast(count) };
    for (result.commands[0..count], 0..) |*command, index| {
        command.* = .{ .spawn = .{
            .request_id = template.first_request_id + index,
            .node = template.start_node,
            .goal = template.goal,
        } };
    }
    return result;
}

test "fixed population planning is deterministic bounded and stateless" {
    const template = Template{
        .first_request_id = 40,
        .start_node = .{ .coord = .{ .x = 0, .z = 0 }, .index = 0 },
        .goal = .{ .patrol_between = .{
            .first = .{ .value = 1 },
            .second = .{ .value = 4 },
        } },
    };
    const first = try plan(max_population_commands, template);
    const second = try plan(max_population_commands, template);
    try std.testing.expectEqualDeep(first, second);
    try std.testing.expectEqual(@as(usize, max_population_commands), first.slice().len);
    try std.testing.expectEqual(@as(u64, 40), first.commands[0].spawn.request_id);
    try std.testing.expectEqual(@as(u64, 103), first.commands[63].spawn.request_id);
    try std.testing.expectError(
        error.PopulationCapacityExceeded,
        plan(max_population_commands + 1, template),
    );
    var invalid = template;
    invalid.first_request_id = 0;
    try std.testing.expectError(error.InvalidPopulationRequestId, plan(1, invalid));
    invalid.first_request_id = std.math.maxInt(u64);
    try std.testing.expectError(error.PopulationRequestIdOverflow, plan(2, invalid));
    try std.testing.expectEqual(@as(u8, 0), (try plan(0, invalid)).len);
}
