//! Pure cold validation for persisted NPC records.
//!
//! The live NPC feature and durable snapshot codec share this logic without
//! making persistence depend on Runtime, Flecs, Jolt, controllers, or mutable
//! feature state. Callers provide only the canonical navigation value port.

const std = @import("std");
const engine = @import("engine_contracts");
const navigation = @import("navigation_contract");
const npc = @import("npc_contract");

pub fn validateRecords(
    navigation_access: anytype,
    records: []const npc.NpcV1,
) !void {
    const Access = @TypeOf(navigation_access.*);
    navigation.assertImplementation(Access);
    if (records.len > npc.max_npcs) return error.TooManyNpcs;

    for (records, 0..) |record, record_index| {
        try record.id.validate();
        for (records[0..record_index]) |earlier| {
            if (std.meta.eql(earlier.id, record.id)) {
                return error.DuplicateNpcPersistentId;
            }
        }

        try npc.validateGoal(record.goal);
        try validateFiniteVector(record.position);
        try validateFiniteVector(record.velocity);
        try (engine.physics.Velocity{ .linear = record.velocity }).validate();
        if (!std.math.isFinite(record.facing_yaw) or
            record.facing_yaw != normalizeYaw(record.facing_yaw) or
            isNegativeZero(record.facing_yaw))
        {
            return error.NonCanonicalNpcFacing;
        }
        for (record.position) |component| {
            if (isNegativeZero(component)) return error.NonCanonicalNpcPosition;
        }
        for (record.velocity) |component| {
            if (isNegativeZero(component)) return error.NonCanonicalNpcVelocity;
        }

        const owner = try navigation.ownerForPosition(record.position);
        if (!navigation.ChunkCoord.eql(owner, record.owner)) {
            return error.NpcOwnerPositionMismatch;
        }
        if (record.route.route_index != 0) return error.NonCanonicalNpcRouteIndex;
        try npc.validateNodeRef(record.route.current);
        if (record.route.next) |next| {
            try npc.validateNodeRef(next);
            if (navigation.NodeRef.eql(record.route.current, next)) {
                return error.NpcRouteCursorSelfEdge;
            }
            switch (navigation_access.validateTraversal(record.route.current, next)) {
                .valid => {},
                .invalid_source, .invalid_target => return error.NpcPersistedRouteInvalid,
                .not_connected => return error.NpcPersistedRouteMismatch,
            }
        }
        if (ownerRouteNodeValue(
            record.owner,
            routeFromRecord(record.route, record.position),
        ) == null) {
            return error.NpcPersistedOwnerRouteMismatch;
        }

        try requireValidContentNode(navigation_access, record.route.current);
        if (record.route.next) |next| {
            try requireValidContentNode(navigation_access, next);
        }
        switch (record.goal) {
            .hold => {
                if (record.route.next != null or record.route.patrol_leg != .none) {
                    return error.NpcHoldCursorMismatch;
                }
            },
            .navigate_to => |target| {
                try requireValidContentNode(navigation_access, target);
                if (record.route.patrol_leg != .none) {
                    return error.NpcNavigateCursorMismatch;
                }
                if ((record.route.next == null) !=
                    navigation.NodeRef.eql(record.route.current, target))
                {
                    return error.NpcNavigateCursorMismatch;
                }
                try verifyActiveRoutePrefix(
                    navigation_access,
                    record.route.current,
                    target,
                    record.route.next,
                );
            },
            .patrol_between => |patrol| {
                try requireValidContentNode(navigation_access, patrol.first);
                try requireValidContentNode(navigation_access, patrol.second);
                const target = switch (record.route.patrol_leg) {
                    .toward_first => patrol.first,
                    .toward_second => patrol.second,
                    .none => return error.NpcPatrolCursorMismatch,
                };
                if ((record.route.next == null) !=
                    navigation.NodeRef.eql(record.route.current, target))
                {
                    return error.NpcPatrolCursorMismatch;
                }
                try verifyActiveRoutePrefix(
                    navigation_access,
                    record.route.current,
                    target,
                    record.route.next,
                );
            },
        }
    }
}

fn requireValidContentNode(access: anytype, reference: navigation.NodeRef) !void {
    switch (access.resolveNode(reference)) {
        .ready, .district_inactive => {},
        .invalid_reference => return error.NpcPersistedRouteInvalid,
    }
}

fn verifyActiveRoutePrefix(
    access: anytype,
    start: navigation.NodeRef,
    target: navigation.NodeRef,
    expected_next: ?navigation.NodeRef,
) !void {
    const route = switch (try buildRoute(access, start, target)) {
        .ready => |plan| plan,
        .inactive => return,
        .invalid_content => return error.NpcPersistedRouteInvalid,
        .no_path => return error.NpcPersistedGoalUnreachable,
    };
    if (!optionalNodeRefEql(expected_next, route.next(0))) {
        return error.NpcPersistedRouteMismatch;
    }
}

const RouteBuild = union(enum) {
    ready: npc.RoutePlan,
    inactive,
    invalid_content,
    no_path,
};

fn buildRoute(
    access: anytype,
    start: navigation.NodeRef,
    target: navigation.NodeRef,
) !RouteBuild {
    switch (access.resolveNode(start)) {
        .ready => {},
        .district_inactive => return .inactive,
        .invalid_reference => return .invalid_content,
    }
    switch (access.resolveNode(target)) {
        .ready => {},
        .district_inactive => return .inactive,
        .invalid_reference => return .invalid_content,
    }
    if (navigation.NodeRef.eql(start, target)) {
        return .{ .ready = planWithOne(start) };
    }

    var refs: [npc.max_route_nodes]navigation.NodeRef = undefined;
    var previous: [npc.max_route_nodes]i8 = @splat(-1);
    var queue: [npc.max_route_nodes]u8 = undefined;
    refs[0] = start;
    queue[0] = 0;
    var count: usize = 1;
    var head: usize = 0;
    var tail: usize = 1;
    var target_index: ?usize = null;

    while (head < tail and target_index == null) : (head += 1) {
        const source_index: usize = queue[head];
        const source_ref = refs[source_index];
        const source = switch (access.resolveNode(source_ref)) {
            .ready => |resolved| resolved,
            .district_inactive => return .inactive,
            .invalid_reference => return .invalid_content,
        };
        for (0..source.node.edge_count) |ordinal_usize| {
            const ordinal: u8 = @intCast(ordinal_usize);
            const resolved_edge = switch (access.resolveEdge(source_ref, ordinal)) {
                .ready => |resolved| resolved,
                .district_inactive => return .inactive,
                .invalid_reference, .invalid_ordinal => {
                    return error.NpcNavigationPortInvariantBroken;
                },
            };
            if (!navigation.LoadTicket.eql(source.ticket, resolved_edge.ticket)) {
                return error.NpcNavigationTicketInvariantBroken;
            }
            const candidate = resolved_edge.edge.target;
            switch (access.resolveNode(candidate)) {
                .ready => {},
                .district_inactive => continue,
                .invalid_reference => return error.NpcNavigationPortInvariantBroken,
            }

            var found = false;
            for (refs[0..count]) |existing| {
                if (navigation.NodeRef.eql(existing, candidate)) {
                    found = true;
                    break;
                }
            }
            if (found) continue;
            if (count == npc.max_route_nodes) return .no_path;
            refs[count] = candidate;
            previous[count] = @intCast(source_index);
            queue[tail] = @intCast(count);
            tail += 1;
            if (navigation.NodeRef.eql(candidate, target)) target_index = count;
            count += 1;
        }
    }

    const found = target_index orelse return .no_path;
    var reversed: [npc.max_route_nodes]navigation.NodeRef = undefined;
    var length: usize = 0;
    var cursor: i8 = @intCast(found);
    while (cursor >= 0) {
        reversed[length] = refs[@intCast(cursor)];
        length += 1;
        cursor = previous[@intCast(cursor)];
    }
    var plan = npc.RoutePlan{ .len = @intCast(length) };
    for (0..length) |index| plan.nodes[index] = reversed[length - 1 - index];
    return .{ .ready = plan };
}

fn planWithOne(reference: navigation.NodeRef) npc.RoutePlan {
    var result = npc.RoutePlan{ .len = 1 };
    result.nodes[0] = reference;
    return result;
}

fn routeFromRecord(
    record: npc.NpcRouteCursorV1,
    position: [3]f32,
) npc.RouteCursor {
    var result = npc.RouteCursor{
        .index = 0,
        .patrol_leg = record.patrol_leg,
        .segment_start = position,
        .needs_rebuild = true,
    };
    result.plan.nodes[0] = record.current;
    result.plan.len = 1;
    if (record.next) |next| {
        result.plan.nodes[1] = next;
        result.plan.len += 1;
    }
    return result;
}

fn currentRouteNode(route: npc.RouteCursor) ?navigation.NodeRef {
    if (route.index >= route.plan.len or route.index >= npc.max_route_nodes) {
        return null;
    }
    return route.plan.nodes[route.index];
}

fn ownerRouteNodeValue(
    owner: navigation.ChunkCoord,
    route: npc.RouteCursor,
) ?navigation.NodeRef {
    const current = currentRouteNode(route) orelse return null;
    if (navigation.ChunkCoord.eql(current.coord, owner)) return current;
    if (route.next()) |next| {
        if (navigation.ChunkCoord.eql(next.coord, owner)) return next;
    }
    return null;
}

fn optionalNodeRefEql(a: ?navigation.NodeRef, b: ?navigation.NodeRef) bool {
    if (a == null or b == null) return a == null and b == null;
    return navigation.NodeRef.eql(a.?, b.?);
}

fn normalizeYaw(yaw: f32) f32 {
    if (!std.math.isFinite(yaw)) return yaw;
    const tau: f32 = 2 * std.math.pi;
    var result = @mod(yaw + std.math.pi, tau) - std.math.pi;
    if (result == 0) result = 0;
    return result;
}

fn isNegativeZero(value: f32) bool {
    return value == 0 and @as(u32, @bitCast(value)) != 0;
}

fn validateFiniteVector(value: [3]f32) !void {
    for (value) |component| {
        if (!std.math.isFinite(component)) return error.NonFiniteNpcVector;
    }
}
