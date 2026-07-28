//! Pure cold validation for persisted NPC records.
//!
//! The live NPC feature and durable snapshot codec share this logic without
//! making persistence depend on Runtime, Flecs, Jolt, controllers, or mutable
//! feature state. Callers provide only the canonical navigation value port.

const std = @import("std");
const engine = @import("engine_contracts");
const navigation = @import("navigation_contract");
const navigation_planner = @import("navigation_planner");
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
        const canonical_facing = engine.transform.normalizeFacingYaw(
            record.facing_yaw,
        ) catch return error.NonCanonicalNpcFacing;
        if (record.facing_yaw != canonical_facing or
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
                if (record.route.next != null or record.route.patrol_leg != .none or
                    record.route.mode != .exact_prefix)
                {
                    return error.NpcHoldCursorMismatch;
                }
            },
            .navigate_to => |destination| {
                try requireValidDestination(navigation_access, destination);
                if (record.route.patrol_leg != .none) {
                    return error.NpcNavigateCursorMismatch;
                }
                switch (record.route.mode) {
                    .exact_prefix => {
                        if ((record.route.next == null) !=
                            destinationHasAnchor(
                                navigation_access,
                                destination,
                                record.route.current,
                            ))
                        {
                            return error.NpcNavigateCursorMismatch;
                        }
                        try verifyActiveDestinationPrefix(
                            navigation_access,
                            record.route.current,
                            destination,
                            record.route.next,
                        );
                    },
                    .deferred_rebuild => {
                        if (record.route.next != null or
                            destinationHasAnchor(
                                navigation_access,
                                destination,
                                record.route.current,
                            ))
                        {
                            return error.NpcNavigateCursorMismatch;
                        }
                        try verifyDeferredDestination(
                            navigation_access,
                            record.route.current,
                            destination,
                        );
                    },
                }
            },
            .patrol_between => |patrol| {
                try requireValidDestination(navigation_access, patrol.first);
                try requireValidDestination(navigation_access, patrol.second);
                const destination = switch (record.route.patrol_leg) {
                    .toward_first => patrol.first,
                    .toward_second => patrol.second,
                    .none => return error.NpcPatrolCursorMismatch,
                };
                switch (record.route.mode) {
                    .exact_prefix => {
                        if ((record.route.next == null) !=
                            destinationHasAnchor(
                                navigation_access,
                                destination,
                                record.route.current,
                            ))
                        {
                            return error.NpcPatrolCursorMismatch;
                        }
                        try verifyActiveDestinationPrefix(
                            navigation_access,
                            record.route.current,
                            destination,
                            record.route.next,
                        );
                    },
                    .deferred_rebuild => {
                        if (record.route.next != null or
                            destinationHasAnchor(
                                navigation_access,
                                destination,
                                record.route.current,
                            ))
                        {
                            return error.NpcPatrolCursorMismatch;
                        }
                        try verifyDeferredDestination(
                            navigation_access,
                            record.route.current,
                            destination,
                        );
                    },
                }
            },
        }
    }
}

fn requireValidDestination(
    access: anytype,
    id: navigation.DestinationId,
) !void {
    const destination = switch (access.resolveDestination(id)) {
        .ready => |value| value,
        .invalid_destination => return error.NpcPersistedGoalInvalid,
    };
    destination.validate() catch return error.NpcPersistedGoalInvalid;
    for (destination.anchorSlice()) |anchor| {
        switch (access.resolveCatalogNode(anchor)) {
            .ready => {},
            .invalid_reference => return error.NpcPersistedGoalInvalid,
        }
    }
}

fn destinationHasAnchor(
    access: anytype,
    id: navigation.DestinationId,
    reference: navigation.NodeRef,
) bool {
    const destination = switch (access.resolveDestination(id)) {
        .ready => |value| value,
        .invalid_destination => return false,
    };
    for (destination.anchorSlice()) |anchor| {
        if (navigation.NodeRef.eql(anchor, reference)) return true;
    }
    return false;
}

fn requireValidContentNode(access: anytype, reference: navigation.NodeRef) !void {
    switch (access.resolveNode(reference)) {
        .ready, .district_inactive => {},
        .invalid_reference => return error.NpcPersistedRouteInvalid,
    }
}

fn verifyActiveDestinationPrefix(
    access: anytype,
    start: navigation.NodeRef,
    destination: navigation.DestinationId,
    expected_next: ?navigation.NodeRef,
) !void {
    const route = switch (navigation_planner.plan(access, start, destination)) {
        .ready, .waiting_for_content => |plan| plan,
        .invalid_destination, .invalid_topology => return error.NpcPersistedRouteInvalid,
        .blocked_by_traversal, .structurally_unreachable => {
            return error.NpcPersistedGoalUnreachable;
        },
        .capacity_exhausted => return error.NpcRoutePlannerCapacityExceeded,
    };
    if (!optionalNodeRefEql(expected_next, route.next(0))) {
        return error.NpcPersistedRouteMismatch;
    }
}

fn verifyDeferredDestination(
    access: anytype,
    start: navigation.NodeRef,
    destination: navigation.DestinationId,
) !void {
    switch (navigation_planner.plan(access, start, destination)) {
        .ready, .waiting_for_content, .blocked_by_traversal => {},
        .invalid_destination, .invalid_topology => return error.NpcPersistedRouteInvalid,
        .structurally_unreachable => {
            return error.NpcPersistedGoalUnreachable;
        },
        .capacity_exhausted => return error.NpcRoutePlannerCapacityExceeded,
    }
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

fn isNegativeZero(value: f32) bool {
    return value == 0 and @as(u32, @bitCast(value)) != 0;
}

fn validateFiniteVector(value: [3]f32) !void {
    for (value) |component| {
        if (!std.math.isFinite(component)) return error.NonFiniteNpcVector;
    }
}
