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
        try std.testing.expectEqual(@as(u64, 2), next_id.local);
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

const timeline_tolerance: f32 = 0.00001;

fn captureTimelineSample(
    world: *simulation.Simulation,
    id: simulation.PersistentId,
) !TimelineSample {
    const view = try world.crate(id);
    return .{
        .tick = world.tickIndex(),
        .position = view.state.pose.position,
        .rotation = view.state.pose.rotation,
        .linear_velocity = view.state.velocity.linear,
    };
}

fn runTimeline(allocator: std.mem.Allocator) ![4]TimelineSample {
    const initial_v1 =
        \\{"schema_version":1,"completed_ticks":10,
        \\"fixed_delta_seconds":0.008333333,"namespace":99,
        \\"next_local_id":2,"crates":[
        \\{"id":{"namespace":99,"local":1},"half_extents":[0.5,0.75,0.25],
        \\"pose":{"position":[1,6,-2],"rotation":[0,0.25881904,0,0.9659258]},
        \\"linear_velocity":[0.5,0.25,-0.25],"angular_velocity":[0.1,0.2,0.3]}]}
    ;
    var world = try simulation.Simulation.fromSnapshot(allocator, initial_v1, .{});
    defer world.deinit();
    const id = simulation.PersistentId{ .namespace = 99, .local = 1 };
    var samples: [4]TimelineSample = undefined;
    samples[0] = try captureTimelineSample(&world, id);
    for (0..5) |_| try world.tick();
    samples[1] = try captureTimelineSample(&world, id);
    try world.submit(.{ .impulse = .{ .id = id, .impulse = .{ 0, 1000, 0 } } });
    try world.tick();
    switch (world.pollOutcome() orelse return error.ImpulseOutcomeMissing) {
        .impulse_applied => |applied_id| try std.testing.expectEqual(id, applied_id),
        else => return error.UnexpectedOutcome,
    }
    samples[2] = try captureTimelineSample(&world, id);
    try std.testing.expect(
        samples[2].linear_velocity[1] > samples[1].linear_velocity[1],
    );
    for (0..20) |_| try world.tick();
    samples[3] = try captureTimelineSample(&world, id);
    return samples;
}

test "the same V1 command timeline repeats at multiple samples on one target" {
    const first = try runTimeline(std.testing.allocator);
    const second = try runTimeline(std.testing.allocator);
    try std.testing.expectEqual([4]u64{ 10, 15, 16, 36 }, .{
        first[0].tick,
        first[1].tick,
        first[2].tick,
        first[3].tick,
    });
    for (first, second) |expected, actual| {
        try std.testing.expectEqual(expected.tick, actual.tick);
        for (expected.position, actual.position) |a, b| {
            try std.testing.expectApproxEqAbs(a, b, timeline_tolerance);
        }
        for (expected.rotation, actual.rotation) |a, b| {
            try std.testing.expectApproxEqAbs(a, b, timeline_tolerance);
        }
        for (expected.linear_velocity, actual.linear_velocity) |a, b| {
            try std.testing.expectApproxEqAbs(a, b, timeline_tolerance);
        }
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
    const clamped_start = (try world.presentation(-1))[0].pose;
    const start = (try world.presentation(0))[0].pose;
    const midpoint = (try world.presentation(0.5))[0].pose;
    const end = (try world.presentation(1))[0].pose;
    const clamped = (try world.presentation(2))[0].pose;
    const current_after = (try world.crate(id)).state.pose;

    try std.testing.expectApproxEqAbs(current_before.position[1], end.position[1], 0.00001);
    try std.testing.expectEqual(start.position, clamped_start.position);
    for (start.position, midpoint.position, end.position) |previous, interpolated, current| {
        try std.testing.expectApproxEqAbs(
            (previous + current) * 0.5,
            interpolated,
            0.00001,
        );
    }
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

test "multi-record V1 save is sorted and byte-stable across fresh restore" {
    const allocator = std.testing.allocator;
    const unsorted =
        \\{"schema_version":1,"completed_ticks":17,
        \\"fixed_delta_seconds":0.008333333,"namespace":700,
        \\"next_local_id":42,"crates":[
        \\{"id":{"namespace":700,"local":7},"half_extents":[0.25,0.5,0.75],
        \\"pose":{"position":[3,8,-2],"rotation":[0,0.38268343,0,0.9238795]},
        \\"linear_velocity":[1.25,-2.5,0.5],"angular_velocity":[0.1,0.2,0.3]},
        \\{"id":{"namespace":700,"local":2},"half_extents":[1,0.75,0.5],
        \\"pose":{"position":[-4,6,1],"rotation":[0.25881904,0,0,0.9659258]},
        \\"linear_velocity":[-0.75,1.5,2.25],"angular_velocity":[-0.3,0.4,-0.2]}]}
    ;

    var first_save: []u8 = undefined;
    {
        var world = try simulation.Simulation.fromSnapshot(allocator, unsorted, .{});
        defer world.deinit();
        try std.testing.expectEqual(@as(u64, 17), world.tickIndex());
        try std.testing.expectEqual(@as(usize, 2), world.crateCount());
        first_save = try world.save(allocator);
    }
    defer allocator.free(first_save);

    var parsed = try std.json.parseFromSlice(
        struct {
            schema_version: u16,
            completed_ticks: u64,
            fixed_delta_seconds: f32,
            namespace: u64,
            next_local_id: u64,
            crates: []const struct { id: simulation.PersistentId },
        },
        allocator,
        first_save,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u16, 1), parsed.value.schema_version);
    try std.testing.expectEqual(@as(u64, 17), parsed.value.completed_ticks);
    try std.testing.expectEqual(@as(u64, 700), parsed.value.namespace);
    try std.testing.expectEqual(@as(u64, 42), parsed.value.next_local_id);
    try std.testing.expectEqual(@as(usize, 2), parsed.value.crates.len);
    try std.testing.expectEqual(@as(u64, 2), parsed.value.crates[0].id.local);
    try std.testing.expectEqual(@as(u64, 7), parsed.value.crates[1].id.local);

    {
        var restored = try simulation.Simulation.fromSnapshot(allocator, first_save, .{});
        defer restored.deinit();
        const second_save = try restored.save(allocator);
        defer allocator.free(second_save);
        try std.testing.expectEqualSlices(u8, first_save, second_save);

        try restored.submit(.{ .spawn = .{
            .request_id = 99,
            .pose = .{ .position = .{ 0, 20, 0 } },
        } });
        try restored.tick();
        const allocated = switch (restored.pollOutcome().?) {
            .spawned => |spawned| spawned.id,
            else => return error.UnexpectedOutcome,
        };
        try std.testing.expectEqual(simulation.PersistentId{
            .namespace = 700,
            .local = 42,
        }, allocated);
    }
}

test "failed fresh loads do not mutate a live simulation" {
    const allocator = std.testing.allocator;
    var world = try simulation.Simulation.init(allocator, .{ .namespace = 701 });
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
    const before = try world.crate(id);
    const tick_before = world.tickIndex();

    try std.testing.expectError(
        error.UnexpectedEndOfInput,
        simulation.Simulation.fromSnapshot(allocator, "{", .{}),
    );
    const oversized = try allocator.alloc(u8, 8 * 1024 * 1024 + 1);
    defer allocator.free(oversized);
    @memset(oversized, ' ');
    try std.testing.expectError(
        error.SnapshotTooLarge,
        simulation.Simulation.fromSnapshot(allocator, oversized, .{}),
    );
    const valid_empty =
        \\{"schema_version":1,"completed_ticks":0,
        \\"fixed_delta_seconds":0.008333333,"namespace":702,
        \\"next_local_id":1,"crates":[]}
    ;
    try std.testing.expectError(
        error.EngineWorldAlreadyLive,
        simulation.Simulation.fromSnapshot(allocator, valid_empty, .{}),
    );

    try std.testing.expectEqual(@as(usize, 1), world.crateCount());
    try std.testing.expectEqual(tick_before, world.tickIndex());
    const after = try world.crate(id);
    try std.testing.expectEqual(before.state.pose.position, after.state.pose.position);
    try world.tick();
    try std.testing.expectEqual(tick_before + 1, world.tickIndex());
}

fn restoreAllocationCase(allocator: std.mem.Allocator) !void {
    const snapshot =
        \\{"schema_version":1,"completed_ticks":3,
        \\"fixed_delta_seconds":0.008333333,"namespace":703,
        \\"next_local_id":3,"crates":[
        \\{"id":{"namespace":703,"local":1},"half_extents":[0.5,0.5,0.5],
        \\"pose":{"position":[0,4,0],"rotation":[0,0,0,1]},
        \\"linear_velocity":[0,0,0],"angular_velocity":[0,0,0]},
        \\{"id":{"namespace":703,"local":2},"half_extents":[0.75,0.5,0.25],
        \\"pose":{"position":[2,6,0],"rotation":[0,0,0,1]},
        \\"linear_velocity":[0.5,0,-0.25],"angular_velocity":[0.1,0.2,0.3]}]}
    ;
    var world = try simulation.Simulation.fromSnapshot(allocator, snapshot, .{});
    defer world.deinit();
    try std.testing.expectEqual(@as(usize, 2), world.entityCount());
    try std.testing.expectEqual(@as(u32, 3), world.bodyCount());
}

test "fresh restore unwinds every injected Zig allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        restoreAllocationCase,
        .{},
    );
}

test "owned simulation teardown accepts live crates pending commands and outcomes" {
    {
        var world = try simulation.Simulation.init(std.testing.allocator, .{
            .namespace = 704,
        });
        try world.submit(.{ .spawn = .{
            .request_id = 1,
            .pose = .{ .position = .{ 0, 3, 0 } },
        } });
        try world.tick();
        // Leave the spawn outcome unread and a command pending.
        try world.submit(.{ .spawn = .{
            .request_id = 2,
            .pose = .{ .position = .{ 2, 3, 0 } },
        } });
        world.deinit();
    }

    // Both the Flecs and process-Jolt ownership leases must have returned.
    var replacement = try simulation.Simulation.init(std.testing.allocator, .{
        .namespace = 705,
    });
    defer replacement.deinit();
    try std.testing.expectEqual(@as(usize, 0), replacement.entityCount());
    try std.testing.expectEqual(@as(u32, 1), replacement.bodyCount());
}

test "all imported S0 module tests are discovered" {
    std.testing.refAllDecls(simulation);
}
