//! SDL-free executable and integration-test root for the S0 crate slice.

const std = @import("std");
const simulation = @import("crate_simulation");

pub fn main(init: std.process.Init) !void {
    _ = init;
    var world = try simulation.Simulation.init(std.heap.page_allocator, .{
        .namespace = 1,
    });
    defer world.deinit();

    try world.submit(.{ .spawn = .{
        .request_id = 1,
        .pose = .{ .position = .{ 0, 8, 0 } },
    } });
    for (0..240) |_| try world.tick();

    const outcome = world.pollOutcome() orelse return error.SpawnOutcomeMissing;
    const id = switch (outcome) {
        .spawned => |spawned| spawned.id,
        else => return error.UnexpectedOutcome,
    };
    const crate = try world.crate(id);
    std.debug.print(
        "headless crate {d}:{d} at ({d:.3}, {d:.3}, {d:.3}) after {d} ticks\n",
        .{
            id.namespace,
            id.local,
            crate.state.pose.position[0],
            crate.state.pose.position[1],
            crate.state.pose.position[2],
            world.tickIndex(),
        },
    );
}

test "real Jolt lifecycle saves destroys restores and destroys" {
    const allocator = std.testing.allocator;
    var saved: []u8 = undefined;
    var stable_id: simulation.PersistentId = undefined;
    var saved_position: [3]f32 = undefined;
    var saved_linear_velocity: [3]f32 = undefined;
    var saved_angular_velocity: [3]f32 = undefined;
    {
        var world = try simulation.Simulation.init(allocator, .{
            .namespace = 77,
        });
        defer world.deinit();
        try std.testing.expectEqual(@as(u32, 1), world.bodyCount());

        try world.submit(.{ .spawn = .{
            .request_id = 41,
            .pose = .{ .position = .{ 0.25, 12, -0.5 } },
            .velocity = .{ .angular = .{ 0.2, 0.4, 0.1 } },
        } });
        for (0..30) |_| try world.tick();
        stable_id = switch (world.pollOutcome().?) {
            .spawned => |spawned| spawned.id,
            else => return error.UnexpectedOutcome,
        };
        try std.testing.expectEqual(@as(usize, 1), world.crateCount());
        try std.testing.expectEqual(@as(usize, 1), world.entityCount());
        try std.testing.expectEqual(@as(u32, 2), world.bodyCount());
        const saved_view = try world.crate(stable_id);
        saved_position = saved_view.state.pose.position;
        saved_linear_velocity = saved_view.state.velocity.linear;
        saved_angular_velocity = saved_view.state.velocity.angular;

        saved = try world.save(allocator);
        const saved_again = try world.save(allocator);
        defer allocator.free(saved_again);
        try std.testing.expectEqualSlices(u8, saved, saved_again);

        try world.submit(.{ .despawn = .{ .id = stable_id } });
        try world.tick();
        _ = world.pollOutcome() orelse return error.DespawnOutcomeMissing;
        try std.testing.expectEqual(@as(usize, 0), world.crateCount());
        try std.testing.expectEqual(@as(usize, 0), world.entityCount());
        try std.testing.expectEqual(@as(u32, 1), world.bodyCount());
    }
    defer allocator.free(saved);

    {
        var restored = try simulation.Simulation.fromSnapshot(allocator, saved, .{});
        defer restored.deinit();
        try std.testing.expectEqual(@as(usize, 1), restored.crateCount());
        try std.testing.expectEqual(@as(u32, 2), restored.bodyCount());
        const restored_view = try restored.crate(stable_id);
        for (saved_position, restored_view.state.pose.position) |expected, actual| {
            try std.testing.expectApproxEqAbs(expected, actual, 0.0001);
        }
        for (saved_linear_velocity, restored_view.state.velocity.linear) |expected, actual| {
            try std.testing.expectApproxEqAbs(expected, actual, 0.0001);
        }
        for (saved_angular_velocity, restored_view.state.velocity.angular) |expected, actual| {
            try std.testing.expectApproxEqAbs(expected, actual, 0.0001);
        }
        const restored_previous = (try restored.presentation(0))[0].pose;
        const restored_current = (try restored.presentation(1))[0].pose;
        try std.testing.expectEqual(restored_previous.position, restored_current.position);
        try std.testing.expectEqual(restored_previous.rotation, restored_current.rotation);

        try restored.submit(.{ .spawn = .{
            .request_id = 99,
            .pose = .{ .position = .{ 2, 4, 0 } },
        } });
        try restored.tick();
        const next_id = switch (restored.pollOutcome().?) {
            .spawned => |spawned| spawned.id,
            else => return error.UnexpectedOutcome,
        };
        try std.testing.expect(next_id.local > stable_id.local);
        try restored.submit(.{ .despawn = .{ .id = stable_id } });
        try restored.submit(.{ .despawn = .{ .id = next_id } });
        try restored.tick();
        try std.testing.expectEqual(@as(usize, 0), restored.crateCount());
        try std.testing.expectEqual(@as(u32, 1), restored.bodyCount());
    }
}

test "repeated crate lifecycle leaves only the host-owned ground" {
    var world = try simulation.Simulation.init(std.testing.allocator, .{
        .namespace = 88,
    });
    defer world.deinit();

    var previous_local: u64 = 0;
    for (0..128) |index| {
        try world.submit(.{ .spawn = .{
            .request_id = index,
            .pose = .{ .position = .{ 0, 3, 0 } },
        } });
        try world.tick();
        const id = switch (world.pollOutcome().?) {
            .spawned => |spawned| spawned.id,
            else => return error.UnexpectedOutcome,
        };
        try std.testing.expect(id.local > previous_local);
        previous_local = id.local;
        try world.submit(.{ .despawn = .{ .id = id } });
        try world.tick();
        _ = world.pollOutcome().?;
        try std.testing.expectEqual(@as(usize, 0), world.entityCount());
        try std.testing.expectEqual(@as(u32, 1), world.bodyCount());
    }
}

test "a stale domain command is rejected without faulting or aliasing" {
    var world = try simulation.Simulation.init(std.testing.allocator, .{
        .namespace = 89,
    });
    defer world.deinit();

    try world.submit(.{ .spawn = .{
        .request_id = 1,
        .pose = .{ .position = .{ 0, 3, 0 } },
    } });
    try world.tick();
    const stale_id = switch (world.pollOutcome().?) {
        .spawned => |spawned| spawned.id,
        else => return error.UnexpectedOutcome,
    };
    try world.submit(.{ .despawn = .{ .id = stale_id } });
    try world.tick();
    _ = world.pollOutcome().?;

    try world.submit(.{ .despawn = .{ .id = stale_id } });
    try world.submit(.{ .spawn = .{
        .request_id = 2,
        .pose = .{ .position = .{ 1, 3, 0 } },
    } });
    try world.tick();
    switch (world.pollOutcome().?) {
        .rejected => |rejected| {
            try std.testing.expectEqual(simulation.CommandKind.despawn, rejected.command);
            try std.testing.expectEqual(
                simulation.RejectionReason.crate_not_found,
                rejected.reason,
            );
        },
        else => return error.UnexpectedOutcome,
    }
    const replacement_id = switch (world.pollOutcome().?) {
        .spawned => |spawned| spawned.id,
        else => return error.UnexpectedOutcome,
    };
    try std.testing.expect(replacement_id.local > stale_id.local);
    try world.tick();
    try world.submit(.{ .despawn = .{ .id = replacement_id } });
    try world.tick();
    try std.testing.expectEqual(@as(usize, 0), world.crateCount());
}

const TimelineSample = struct {
    tick: u64,
    position: [3]f32,
    rotation: [4]f32,
    linear_velocity: [3]f32,
};

fn runTimeline(allocator: std.mem.Allocator) !TimelineSample {
    var world = try simulation.Simulation.init(allocator, .{ .namespace = 99 });
    defer world.deinit();
    try world.submit(.{ .spawn = .{
        .request_id = 1,
        .pose = .{ .position = .{ 0, 6, 0 } },
        .velocity = .{ .linear = .{ 0.5, 0, -0.25 } },
    } });
    try world.tick();
    const id = switch (world.pollOutcome().?) {
        .spawned => |spawned| spawned.id,
        else => return error.UnexpectedOutcome,
    };
    for (0..20) |_| try world.tick();
    try world.submit(.{ .impulse = .{ .id = id, .impulse = .{ 0, 1.5, 0 } } });
    for (0..20) |_| try world.tick();
    const view = try world.crate(id);
    return .{
        .tick = world.tickIndex(),
        .position = view.state.pose.position,
        .rotation = view.state.pose.rotation,
        .linear_velocity = view.state.velocity.linear,
    };
}

test "the same command timeline repeats on one target" {
    const first = try runTimeline(std.testing.allocator);
    const second = try runTimeline(std.testing.allocator);
    try std.testing.expectEqual(first.tick, second.tick);
    for (first.position, second.position) |a, b| {
        try std.testing.expectApproxEqAbs(a, b, 0.00001);
    }
    for (first.rotation, second.rotation) |a, b| {
        try std.testing.expectApproxEqAbs(a, b, 0.00001);
    }
    for (first.linear_velocity, second.linear_velocity) |a, b| {
        try std.testing.expectApproxEqAbs(a, b, 0.00001);
    }
}

test "presentation interpolates without writing authoritative state" {
    var world = try simulation.Simulation.init(std.testing.allocator, .{
        .namespace = 123,
    });
    defer world.deinit();
    try world.submit(.{ .spawn = .{
        .request_id = 1,
        .pose = .{ .position = .{ 0, 5, 0 } },
    } });
    try world.tick();
    const id = switch (world.pollOutcome().?) {
        .spawned => |spawned| spawned.id,
        else => return error.UnexpectedOutcome,
    };
    const current_before = (try world.crate(id)).state.pose;
    const start = (try world.presentation(0))[0].pose;
    const midpoint = (try world.presentation(0.5))[0].pose;
    const end = (try world.presentation(1))[0].pose;
    const clamped = (try world.presentation(2))[0].pose;
    const current_after = (try world.crate(id)).state.pose;

    try std.testing.expectApproxEqAbs(current_before.position[1], end.position[1], 0.00001);
    try std.testing.expectApproxEqAbs(end.position[1], clamped.position[1], 0.00001);
    try std.testing.expect(midpoint.position[1] <= start.position[1]);
    try std.testing.expect(midpoint.position[1] >= end.position[1]);
    try std.testing.expectEqual(current_before.position, current_after.position);
    try std.testing.expectEqual(current_before.rotation, current_after.rotation);
}

test "empty presentation still rejects non-finite alpha" {
    var world = try simulation.Simulation.init(std.testing.allocator, .{
        .namespace = 124,
    });
    defer world.deinit();
    try std.testing.expectError(
        error.InvalidInterpolationAlpha,
        world.presentation(std.math.nan(f32)),
    );
}

test "live-world restore fails cleanly and leaves the caller usable" {
    var world = try simulation.Simulation.init(std.testing.allocator, .{
        .namespace = 125,
    });
    defer world.deinit();
    const saved = try world.save(std.testing.allocator);
    defer std.testing.allocator.free(saved);

    try std.testing.expectError(
        error.EngineWorldAlreadyLive,
        simulation.Simulation.fromSnapshot(std.testing.allocator, saved, .{}),
    );
    try world.tick();
    try std.testing.expectEqual(@as(u64, 1), world.tickIndex());
}

test "all imported S0 module tests are discovered" {
    std.testing.refAllDecls(simulation);
}
