//! Pure allocation-free route planning over the admitted navigation catalog.
//!
//! The planner owns no destination intent, residency, controller, topology
//! mutation, or diagnostics sink. It returns one bounded value that callers
//! may commit, defer, inspect, persist by meaning, or reject.

const std = @import("std");
const navigation = @import("navigation_contract");

pub const max_search_nodes: usize = navigation.max_route_nodes;

pub const RoutePlan = struct {
    nodes: [navigation.max_route_nodes]navigation.NodeRef =
        [_]navigation.NodeRef{.{}} ** navigation.max_route_nodes,
    len: u8 = 0,
    active_prefix_len: u8 = 0,
    total_cost: u32 = 0,
    topology_revision: u64 = 0,
    searched_nodes: u16 = 0,
    searched_edges: u16 = 0,
    digest: u64 = 0,
    missing_district: ?navigation.ChunkCoord = null,

    pub fn slice(self: *const RoutePlan) []const navigation.NodeRef {
        return self.nodes[0..@min(
            @as(usize, self.len),
            navigation.max_route_nodes,
        )];
    }

    pub fn next(self: *const RoutePlan, index: u8) ?navigation.NodeRef {
        const next_index = @as(usize, index) + 1;
        if (next_index >= self.len or next_index >= navigation.max_route_nodes) {
            return null;
        }
        return self.nodes[next_index];
    }
};

pub const FailureEvidence = struct {
    topology_revision: u64,
    searched_nodes: u16,
    searched_edges: u16,
};

/// Runtime-only traversal exclusion. NPC recovery may temporarily exclude a
/// physically obstructed directed segment without mutating the immutable
/// authored topology or the sandbox gate policy.
pub const EdgeExclusion = struct {
    source: navigation.NodeRef,
    target: navigation.NodeRef,

    pub fn matches(
        self: EdgeExclusion,
        source: navigation.NodeRef,
        target: navigation.NodeRef,
    ) bool {
        return navigation.NodeRef.eql(self.source, source) and
            navigation.NodeRef.eql(self.target, target);
    }
};

pub const Result = union(enum) {
    ready: RoutePlan,
    waiting_for_content: RoutePlan,
    blocked_by_traversal: FailureEvidence,
    structurally_unreachable: FailureEvidence,
    invalid_destination,
    invalid_topology,
    capacity_exhausted,
};

const SearchSlot = struct {
    reference: navigation.NodeRef,
    distance: u32 = std.math.maxInt(u32),
    predecessor: ?u8 = null,
    visited: bool = false,
};

const Found = struct {
    nodes: [navigation.max_route_nodes]navigation.NodeRef =
        [_]navigation.NodeRef{.{}} ** navigation.max_route_nodes,
    len: u8,
    total_cost: u32,
    searched_nodes: u16,
    searched_edges: u16,
};

const SearchResult = union(enum) {
    found: Found,
    no_path: FailureEvidence,
    invalid_topology,
    capacity_exhausted,
};

pub fn plan(
    access: anytype,
    start: navigation.NodeRef,
    destination_id: navigation.DestinationId,
) Result {
    return planExcluding(access, start, destination_id, &.{});
}

pub fn planExcluding(
    access: anytype,
    start: navigation.NodeRef,
    destination_id: navigation.DestinationId,
    exclusions: []const EdgeExclusion,
) Result {
    const destination = switch (access.resolveDestination(destination_id)) {
        .ready => |value| value,
        .invalid_destination => return .invalid_destination,
    };
    destination.validate() catch return .invalid_destination;
    return planToAnchors(access, start, destination.anchorSlice(), exclusions);
}

pub fn planToNode(
    access: anytype,
    start: navigation.NodeRef,
    target: navigation.NodeRef,
) Result {
    return planToNodeExcluding(access, start, target, &.{});
}

pub fn planToNodeExcluding(
    access: anytype,
    start: navigation.NodeRef,
    target: navigation.NodeRef,
    exclusions: []const EdgeExclusion,
) Result {
    const anchors = [_]navigation.NodeRef{target};
    return planToAnchors(access, start, &anchors, exclusions);
}

fn planToAnchors(
    access: anytype,
    start: navigation.NodeRef,
    anchors: []const navigation.NodeRef,
    exclusions: []const EdgeExclusion,
) Result {
    switch (access.resolveCatalogNode(start)) {
        .ready => {},
        .invalid_reference => return .invalid_topology,
    }

    const topology_revision = access.topologyRevision();
    const runtime = bestSearch(access, start, anchors, true, exclusions);
    switch (runtime) {
        .found => |found| {
            var route = RoutePlan{
                .nodes = found.nodes,
                .len = found.len,
                .total_cost = found.total_cost,
                .topology_revision = topology_revision,
                .searched_nodes = found.searched_nodes,
                .searched_edges = found.searched_edges,
            };
            for (route.slice()) |reference| {
                if (access.activeTicketFor(reference.coord) == null) {
                    route.missing_district = reference.coord;
                    break;
                }
                route.active_prefix_len += 1;
            }
            route.digest = routeDigest(&route);
            return if (route.active_prefix_len == route.len)
                .{ .ready = route }
            else
                .{ .waiting_for_content = route };
        },
        .invalid_topology => return .invalid_topology,
        .capacity_exhausted => return .capacity_exhausted,
        .no_path => |runtime_evidence| {
            const structural = bestSearch(
                access,
                start,
                anchors,
                false,
                &.{},
            );
            return switch (structural) {
                .found => |found| .{ .blocked_by_traversal = .{
                    .topology_revision = topology_revision,
                    .searched_nodes = runtime_evidence.searched_nodes +|
                        found.searched_nodes,
                    .searched_edges = runtime_evidence.searched_edges +|
                        found.searched_edges,
                } },
                .no_path => |evidence| .{ .structurally_unreachable = .{
                    .topology_revision = topology_revision,
                    .searched_nodes = runtime_evidence.searched_nodes +|
                        evidence.searched_nodes,
                    .searched_edges = runtime_evidence.searched_edges +|
                        evidence.searched_edges,
                } },
                .invalid_topology => .invalid_topology,
                .capacity_exhausted => .capacity_exhausted,
            };
        },
    }
}

fn bestSearch(
    access: anytype,
    start: navigation.NodeRef,
    anchors: []const navigation.NodeRef,
    apply_runtime_traversal: bool,
    exclusions: []const EdgeExclusion,
) SearchResult {
    var best: ?Found = null;
    var searched_nodes: u16 = 0;
    var searched_edges: u16 = 0;
    for (anchors) |anchor| {
        const candidate = search(
            access,
            start,
            anchor,
            apply_runtime_traversal,
            exclusions,
        );
        switch (candidate) {
            .found => |found| {
                searched_nodes +|= found.searched_nodes;
                searched_edges +|= found.searched_edges;
                if (best == null or found.total_cost < best.?.total_cost or
                    (found.total_cost == best.?.total_cost and
                        orderNodeRef(
                            found.nodes[found.len - 1],
                            best.?.nodes[best.?.len - 1],
                        ) == .lt))
                {
                    best = found;
                }
            },
            .no_path => |evidence| {
                searched_nodes +|= evidence.searched_nodes;
                searched_edges +|= evidence.searched_edges;
            },
            .invalid_topology => return .invalid_topology,
            .capacity_exhausted => return .capacity_exhausted,
        }
    }
    if (best) |found| {
        var result = found;
        result.searched_nodes = searched_nodes;
        result.searched_edges = searched_edges;
        return .{ .found = result };
    }
    return .{ .no_path = .{
        .topology_revision = access.topologyRevision(),
        .searched_nodes = searched_nodes,
        .searched_edges = searched_edges,
    } };
}

fn search(
    access: anytype,
    start: navigation.NodeRef,
    target: navigation.NodeRef,
    apply_runtime_traversal: bool,
    exclusions: []const EdgeExclusion,
) SearchResult {
    switch (access.resolveCatalogNode(target)) {
        .ready => {},
        .invalid_reference => return .invalid_topology,
    }

    var slots: [max_search_nodes]SearchSlot = undefined;
    var slot_count: usize = 1;
    slots[0] = .{ .reference = start, .distance = 0 };
    var searched_nodes: u16 = 0;
    var searched_edges: u16 = 0;

    while (true) {
        const current_index = nextUnvisited(&slots, slot_count) orelse
            return .{ .no_path = .{
                .topology_revision = access.topologyRevision(),
                .searched_nodes = searched_nodes,
                .searched_edges = searched_edges,
            } };
        slots[current_index].visited = true;
        searched_nodes +|= 1;

        if (navigation.NodeRef.eql(slots[current_index].reference, target)) {
            return reconstruct(&slots, slot_count, current_index, searched_nodes, searched_edges);
        }

        const current_node = switch (access.resolveCatalogNode(
            slots[current_index].reference,
        )) {
            .ready => |value| value,
            .invalid_reference => return .invalid_topology,
        };
        for (0..current_node.node.edge_count) |ordinal_index| {
            const edge = switch (access.resolveCatalogEdge(
                current_node.reference,
                @intCast(ordinal_index),
            )) {
                .ready => |value| value.edge,
                .invalid_reference, .invalid_ordinal => return .invalid_topology,
            };
            searched_edges +|= 1;
            if (edge.cost == 0) return .invalid_topology;
            switch (access.resolveCatalogNode(edge.target)) {
                .ready => {},
                .invalid_reference => return .invalid_topology,
            }
            if (apply_runtime_traversal and
                (access.edgeAvailability(current_node.reference, edge.target) == .closed or
                    edgeExcluded(
                        exclusions,
                        current_node.reference,
                        edge.target,
                    )))
            {
                continue;
            }

            var target_index = findSlot(&slots, slot_count, edge.target);
            if (target_index == null) {
                if (slot_count == slots.len) return .capacity_exhausted;
                target_index = slot_count;
                slots[slot_count] = .{ .reference = edge.target };
                slot_count += 1;
            }
            const candidate_distance = std.math.add(
                u32,
                slots[current_index].distance,
                edge.cost,
            ) catch return .invalid_topology;
            const target_slot = &slots[target_index.?];
            const predecessor_is_better =
                target_slot.predecessor == null or
                orderNodeRef(
                    slots[current_index].reference,
                    slots[target_slot.predecessor.?].reference,
                ) == .lt;
            if (candidate_distance < target_slot.distance or
                (candidate_distance == target_slot.distance and predecessor_is_better))
            {
                target_slot.distance = candidate_distance;
                target_slot.predecessor = @intCast(current_index);
            }
        }
    }
}

fn edgeExcluded(
    exclusions: []const EdgeExclusion,
    source: navigation.NodeRef,
    target: navigation.NodeRef,
) bool {
    for (exclusions) |exclusion| {
        if (exclusion.matches(source, target)) return true;
    }
    return false;
}

fn nextUnvisited(slots: *const [max_search_nodes]SearchSlot, len: usize) ?usize {
    var best: ?usize = null;
    for (slots[0..len], 0..) |slot, index| {
        if (slot.visited or slot.distance == std.math.maxInt(u32)) continue;
        if (best == null or slot.distance < slots[best.?].distance or
            (slot.distance == slots[best.?].distance and
                orderNodeRef(slot.reference, slots[best.?].reference) == .lt))
        {
            best = index;
        }
    }
    return best;
}

fn findSlot(
    slots: *const [max_search_nodes]SearchSlot,
    len: usize,
    reference: navigation.NodeRef,
) ?usize {
    for (slots[0..len], 0..) |slot, index| {
        if (navigation.NodeRef.eql(slot.reference, reference)) return index;
    }
    return null;
}

fn reconstruct(
    slots: *const [max_search_nodes]SearchSlot,
    slot_count: usize,
    target_index: usize,
    searched_nodes: u16,
    searched_edges: u16,
) SearchResult {
    _ = slot_count;
    var reversed: [navigation.max_route_nodes]navigation.NodeRef =
        [_]navigation.NodeRef{.{}} ** navigation.max_route_nodes;
    var len: usize = 0;
    var cursor: ?usize = target_index;
    while (cursor) |index| {
        if (len == reversed.len) return .capacity_exhausted;
        reversed[len] = slots[index].reference;
        len += 1;
        cursor = if (slots[index].predecessor) |value| value else null;
    }

    var found = Found{
        .len = @intCast(len),
        .total_cost = slots[target_index].distance,
        .searched_nodes = searched_nodes,
        .searched_edges = searched_edges,
    };
    for (0..len) |index| found.nodes[index] = reversed[len - 1 - index];
    return .{ .found = found };
}

fn routeDigest(route: *const RoutePlan) u64 {
    var hash: u64 = 14_695_981_039_346_656_037;
    hashU64(&hash, route.topology_revision);
    hashU32(&hash, route.total_cost);
    hashByte(&hash, route.len);
    for (route.slice()) |reference| {
        hashU32(&hash, @bitCast(reference.coord.x));
        hashU32(&hash, @bitCast(reference.coord.z));
        hashByte(&hash, reference.index);
    }
    return hash;
}

fn orderNodeRef(a: navigation.NodeRef, b: navigation.NodeRef) std.math.Order {
    const x = std.math.order(a.coord.x, b.coord.x);
    if (x != .eq) return x;
    const z = std.math.order(a.coord.z, b.coord.z);
    if (z != .eq) return z;
    return std.math.order(a.index, b.index);
}

fn hashByte(hash: *u64, value: u8) void {
    hash.* = (hash.* ^ value) *% 1_099_511_628_211;
}

fn hashU32(hash: *u64, value: u32) void {
    inline for (0..4) |index| {
        hashByte(hash, @truncate(value >> @as(u5, @intCast(index * 8))));
    }
}

fn hashU64(hash: *u64, value: u64) void {
    inline for (0..8) |index| {
        hashByte(hash, @truncate(value >> @as(u6, @intCast(index * 8))));
    }
}

const TestAccess = struct {
    east_active: bool = true,
    close_north: bool = false,
    close_south: bool = false,
    structural_north: bool = true,
    structural_south: bool = true,

    const west = navigation.ChunkCoord{ .x = 0, .z = 0 };
    const east = navigation.ChunkCoord{ .x = 1, .z = 0 };

    fn ref(coord: navigation.ChunkCoord, index: u8) navigation.NodeRef {
        return .{ .coord = coord, .index = index };
    }

    pub fn resolveDestination(
        _: *TestAccess,
        id: navigation.DestinationId,
    ) navigation.DestinationResolution {
        if (id.value != 1) return .invalid_destination;
        return .{ .ready = .{
            .id = id,
            .position = .{ 10, 0, 0 },
            .arrival_radius = 0.25,
            .anchors = .{ ref(east, 2), .{} },
            .anchor_count = 1,
        } };
    }

    pub fn resolveCatalogNode(
        self: *TestAccess,
        reference: navigation.NodeRef,
    ) navigation.CatalogNodeResolution {
        if (!self.valid(reference)) return .invalid_reference;
        return .{ .ready = .{
            .reference = reference,
            .node = .{
                .position = .{ 0, 0, 0 },
                .first_edge = 0,
                .edge_count = self.edgeCount(reference),
            },
        } };
    }

    pub fn resolveCatalogEdge(
        self: *TestAccess,
        source: navigation.NodeRef,
        ordinal: u8,
    ) navigation.CatalogEdgeResolution {
        const target = self.edgeTarget(source, ordinal) orelse
            return .invalid_ordinal;
        return .{ .ready = .{
            .source = source,
            .ordinal = ordinal,
            .edge = .{
                .target = target.reference,
                .cost = target.cost,
            },
        } };
    }

    pub fn activeTicketFor(
        self: *TestAccess,
        coord: navigation.ChunkCoord,
    ) ?navigation.LoadTicket {
        if (navigation.ChunkCoord.eql(coord, west) or
            (navigation.ChunkCoord.eql(coord, east) and self.east_active))
        {
            return .{ .coord = coord, .generation = 1 };
        }
        return null;
    }

    pub fn topologyRevision(self: *TestAccess) u64 {
        return 1 + @as(u64, @intFromBool(self.close_north)) +
            @as(u64, @intFromBool(self.close_south));
    }

    pub fn edgeAvailability(
        self: *TestAccess,
        source: navigation.NodeRef,
        target: navigation.NodeRef,
    ) navigation.EdgeAvailability {
        if ((navigation.NodeRef.eql(source, ref(west, 1)) and
            navigation.NodeRef.eql(target, ref(east, 0))) or
            (navigation.NodeRef.eql(source, ref(east, 0)) and
                navigation.NodeRef.eql(target, ref(west, 1))))
        {
            return if (self.close_north) .closed else .open;
        }
        if ((navigation.NodeRef.eql(source, ref(west, 2)) and
            navigation.NodeRef.eql(target, ref(east, 1))) or
            (navigation.NodeRef.eql(source, ref(east, 1)) and
                navigation.NodeRef.eql(target, ref(west, 2))))
        {
            return if (self.close_south) .closed else .open;
        }
        return .open;
    }

    fn valid(self: *const TestAccess, reference: navigation.NodeRef) bool {
        if (navigation.ChunkCoord.eql(reference.coord, west)) {
            return reference.index < 3;
        }
        if (navigation.ChunkCoord.eql(reference.coord, east)) {
            if (reference.index >= 3) return false;
            if (!self.structural_south and reference.index == 1) return false;
            return true;
        }
        return false;
    }

    fn edgeCount(self: *const TestAccess, source: navigation.NodeRef) u8 {
        var count: u8 = 0;
        while (self.edgeTarget(source, count) != null) count += 1;
        return count;
    }

    const Target = struct { reference: navigation.NodeRef, cost: u16 };

    fn edgeTarget(
        self: *const TestAccess,
        source: navigation.NodeRef,
        ordinal: u8,
    ) ?Target {
        if (navigation.NodeRef.eql(source, ref(west, 0))) return switch (ordinal) {
            0 => .{ .reference = ref(west, 1), .cost = 1 },
            1 => .{ .reference = ref(west, 2), .cost = 2 },
            else => null,
        };
        if (navigation.NodeRef.eql(source, ref(west, 1))) return switch (ordinal) {
            0 => .{ .reference = ref(west, 0), .cost = 1 },
            1 => if (self.structural_north)
                .{ .reference = ref(east, 0), .cost = 1 }
            else
                null,
            else => null,
        };
        if (navigation.NodeRef.eql(source, ref(west, 2))) return switch (ordinal) {
            0 => .{ .reference = ref(west, 0), .cost = 2 },
            1 => if (self.structural_south)
                .{ .reference = ref(east, 1), .cost = 2 }
            else
                null,
            else => null,
        };
        if (navigation.NodeRef.eql(source, ref(east, 0))) return switch (ordinal) {
            0 => if (self.structural_north)
                .{ .reference = ref(west, 1), .cost = 1 }
            else
                .{ .reference = ref(east, 2), .cost = 1 },
            1 => if (self.structural_north)
                .{ .reference = ref(east, 2), .cost = 1 }
            else
                null,
            else => null,
        };
        if (navigation.NodeRef.eql(source, ref(east, 1))) return switch (ordinal) {
            0 => .{ .reference = ref(west, 2), .cost = 2 },
            1 => .{ .reference = ref(east, 2), .cost = 2 },
            else => null,
        };
        if (navigation.NodeRef.eql(source, ref(east, 2))) return switch (ordinal) {
            0 => if (self.structural_north)
                .{ .reference = ref(east, 0), .cost = 1 }
            else if (self.structural_south)
                .{ .reference = ref(east, 1), .cost = 2 }
            else
                null,
            1 => if (self.structural_north and self.structural_south)
                .{ .reference = ref(east, 1), .cost = 2 }
            else
                null,
            else => null,
        };
        return null;
    }
};

test "planner chooses deterministic cost and reports inactive content" {
    var access = TestAccess{};
    const start = TestAccess.ref(TestAccess.west, 0);
    const ready = plan(&access, start, .{ .value = 1 });
    try std.testing.expect(ready == .ready);
    try std.testing.expectEqual(@as(u32, 3), ready.ready.total_cost);
    try std.testing.expectEqual(@as(u8, 4), ready.ready.len);

    access.east_active = false;
    const waiting = plan(&access, start, .{ .value = 1 });
    try std.testing.expect(waiting == .waiting_for_content);
    try std.testing.expectEqual(@as(u8, 2), waiting.waiting_for_content.active_prefix_len);
    try std.testing.expectEqual(TestAccess.east, waiting.waiting_for_content.missing_district.?);
}

test "planner distinguishes runtime block from structural disconnection" {
    var access = TestAccess{ .close_north = true, .close_south = true };
    const start = TestAccess.ref(TestAccess.west, 0);
    try std.testing.expect(plan(&access, start, .{ .value = 1 }) == .blocked_by_traversal);

    access.close_north = false;
    access.close_south = false;
    access.structural_north = false;
    access.structural_south = false;
    try std.testing.expect(
        plan(&access, start, .{ .value = 1 }) == .structurally_unreachable,
    );
}

test "planner treats temporary physical exclusions as runtime traversal policy" {
    var access = TestAccess{};
    const start = TestAccess.ref(TestAccess.west, 0);
    const exclusions = [_]EdgeExclusion{.{
        .source = TestAccess.ref(TestAccess.west, 1),
        .target = TestAccess.ref(TestAccess.east, 0),
    }};
    const alternate = planExcluding(
        &access,
        start,
        .{ .value = 1 },
        &exclusions,
    );
    try std.testing.expect(alternate == .ready);
    try std.testing.expectEqual(
        TestAccess.ref(TestAccess.west, 2),
        alternate.ready.nodes[1],
    );

    const both = [_]EdgeExclusion{
        exclusions[0],
        .{
            .source = TestAccess.ref(TestAccess.west, 2),
            .target = TestAccess.ref(TestAccess.east, 1),
        },
    };
    try std.testing.expect(
        planExcluding(&access, start, .{ .value = 1 }, &both) ==
            .blocked_by_traversal,
    );
}
