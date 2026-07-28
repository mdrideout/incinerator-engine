//! Pure exact-cohort navigation adapter for hostile save/replay preflight.
//!
//! This adapter constructs no Runtime, Flecs world, Jolt object, controller,
//! or district residency. It reads the same logical recipe whose node/edge
//! bytes catalog admission requires cooked content to match exactly. Live NPC
//! movement must use DistrictFeature.NavigationAccess instead.

const std = @import("std");
const district = @import("district_contract");
const navigation = @import("navigation_contract");
const recipe = @import("sandbox_district_recipe");

pub const Gate = enum(u8) {
    north,
    south,
};

pub const GateState = struct {
    north_open: bool,
    south_open: bool,
    topology_revision: u64,

    pub fn validate(self: GateState) !void {
        if (self.topology_revision == 0) {
            return error.InvalidNavigationTopologyRevision;
        }
    }
};

pub const initial_gate_state = GateState{
    .north_open = true,
    .south_open = true,
    .topology_revision = 1,
};

/// Sandbox-owned traversal policy layered over district-owned content and
/// residency. Closing a gate changes runtime traversal only; it never edits
/// the immutable admitted graph or destination catalog.
pub fn RuntimeAccess(comptime DistrictAccess: type) type {
    navigation.assertImplementation(DistrictAccess);
    return struct {
        const Self = @This();

        district: *DistrictAccess,
        north_open: bool = true,
        south_open: bool = true,
        topology_revision: u64 = 1,

        pub fn init(district_access: *DistrictAccess) Self {
            return .{ .district = district_access };
        }

        pub fn restoreGateState(self: *Self, state: GateState) !void {
            try state.validate();
            self.north_open = state.north_open;
            self.south_open = state.south_open;
            self.topology_revision = state.topology_revision;
        }

        pub fn gateState(self: *const Self) GateState {
            return .{
                .north_open = self.north_open,
                .south_open = self.south_open,
                .topology_revision = self.topology_revision,
            };
        }

        pub fn setGate(self: *Self, gate: Gate, open: bool) bool {
            const value = switch (gate) {
                .north => &self.north_open,
                .south => &self.south_open,
            };
            if (value.* == open) return false;
            value.* = open;
            self.topology_revision +|= 1;
            return true;
        }

        pub fn resolveNode(
            self: *Self,
            reference: navigation.NodeRef,
        ) navigation.NodeResolution {
            return self.district.resolveNode(reference);
        }

        pub fn resolveEdge(
            self: *Self,
            source: navigation.NodeRef,
            ordinal: u8,
        ) navigation.EdgeResolution {
            return self.district.resolveEdge(source, ordinal);
        }

        pub fn validateTraversal(
            self: *Self,
            source: navigation.NodeRef,
            target: navigation.NodeRef,
        ) navigation.TraversalValidation {
            return self.district.validateTraversal(source, target);
        }

        pub fn nearestActiveNode(
            self: *Self,
            position: [3]f32,
        ) navigation.NearestNodeResolution {
            return self.district.nearestActiveNode(position);
        }

        pub fn resolveDestination(
            self: *Self,
            id: navigation.DestinationId,
        ) navigation.DestinationResolution {
            return self.district.resolveDestination(id);
        }

        pub fn resolveCatalogNode(
            self: *Self,
            reference: navigation.NodeRef,
        ) navigation.CatalogNodeResolution {
            return self.district.resolveCatalogNode(reference);
        }

        pub fn resolveCatalogEdge(
            self: *Self,
            source: navigation.NodeRef,
            ordinal: u8,
        ) navigation.CatalogEdgeResolution {
            return self.district.resolveCatalogEdge(source, ordinal);
        }

        pub fn activeTicketFor(
            self: *Self,
            coord: navigation.ChunkCoord,
        ) ?navigation.LoadTicket {
            return self.district.activeTicketFor(coord);
        }

        pub fn topologyRevision(self: *Self) u64 {
            return self.topology_revision;
        }

        pub fn edgeAvailability(
            self: *Self,
            source: navigation.NodeRef,
            target: navigation.NodeRef,
        ) navigation.EdgeAvailability {
            if (isGateEdge(source, target, .north)) {
                return if (self.north_open) .open else .closed;
            }
            if (isGateEdge(source, target, .south)) {
                return if (self.south_open) .open else .closed;
            }
            return .open;
        }
    };
}

fn isGateEdge(
    source: navigation.NodeRef,
    target: navigation.NodeRef,
    gate: Gate,
) bool {
    const west_index: u8 = switch (gate) {
        .north => 6,
        .south => 7,
    };
    const east_index: u8 = switch (gate) {
        .north => 0,
        .south => 6,
    };
    const west = navigation.NodeRef{
        .coord = recipe.navigation_west_coord,
        .index = west_index,
    };
    const east = navigation.NodeRef{
        .coord = recipe.navigation_east_coord,
        .index = east_index,
    };
    return (navigation.NodeRef.eql(source, west) and
        navigation.NodeRef.eql(target, east)) or
        (navigation.NodeRef.eql(source, east) and
            navigation.NodeRef.eql(target, west));
}

pub const CanonicalAccess = struct {
    pub fn resolveNode(
        _: *CanonicalAccess,
        reference: navigation.NodeRef,
    ) navigation.NodeResolution {
        const build = canonicalBuild(reference.coord) orelse
            return .invalid_reference;
        if (reference.index >= build.navigation_node_count) {
            return .invalid_reference;
        }
        return .{ .ready = .{
            .ticket = canonicalTicket(reference.coord),
            .reference = reference,
            .node = build.navigation_nodes[reference.index],
        } };
    }

    pub fn resolveEdge(
        self: *CanonicalAccess,
        source: navigation.NodeRef,
        ordinal: u8,
    ) navigation.EdgeResolution {
        const node = switch (self.resolveNode(source)) {
            .ready => |value| value,
            .invalid_reference => return .invalid_reference,
            .district_inactive => unreachable,
        };
        if (ordinal >= node.node.edge_count) return .invalid_ordinal;
        const build = canonicalBuild(source.coord) orelse unreachable;
        const edge_index = @as(usize, node.node.first_edge) + ordinal;
        if (edge_index >= build.navigation_edge_count) return .invalid_ordinal;
        return .{ .ready = .{
            .ticket = node.ticket,
            .source = source,
            .ordinal = ordinal,
            .edge = build.navigation_edges[edge_index],
        } };
    }

    pub fn validateTraversal(
        _: *CanonicalAccess,
        source: navigation.NodeRef,
        target: navigation.NodeRef,
    ) navigation.TraversalValidation {
        const source_build = canonicalBuild(source.coord) orelse return .invalid_source;
        const target_build = canonicalBuild(target.coord) orelse return .invalid_target;
        if (source.index >= source_build.navigation_node_count) return .invalid_source;
        if (target.index >= target_build.navigation_node_count) return .invalid_target;
        const node = source_build.navigation_nodes[source.index];
        const first: usize = node.first_edge;
        const end = first + node.edge_count;
        for (source_build.navigation_edges[first..end]) |edge| {
            if (navigation.NodeRef.eql(edge.target, target)) return .valid;
        }
        return .not_connected;
    }

    pub fn nearestActiveNode(
        self: *CanonicalAccess,
        position: [3]f32,
    ) navigation.NearestNodeResolution {
        const coord = navigation.ownerForPosition(position) catch return .unavailable;
        const build = canonicalBuild(coord) orelse return .unavailable;
        var best: ?navigation.ResolvedNode = null;
        var best_distance_squared = std.math.inf(f32);
        for (0..build.navigation_node_count) |index| {
            const resolved = switch (self.resolveNode(.{
                .coord = coord,
                .index = @intCast(index),
            })) {
                .ready => |value| value,
                .district_inactive => return .district_inactive,
                .invalid_reference => return .unavailable,
            };
            const dx = resolved.node.position[0] - position[0];
            const dz = resolved.node.position[2] - position[2];
            const distance_squared = dx * dx + dz * dz;
            if (best == null or distance_squared < best_distance_squared) {
                best = resolved;
                best_distance_squared = distance_squared;
            }
        }
        return .{ .ready = best orelse return .unavailable };
    }

    pub fn resolveDestination(
        _: *CanonicalAccess,
        id: navigation.DestinationId,
    ) navigation.DestinationResolution {
        const destination = recipe.resolveDestination(id) orelse
            return .invalid_destination;
        return .{ .ready = destination };
    }

    pub fn resolveCatalogNode(
        _: *CanonicalAccess,
        reference: navigation.NodeRef,
    ) navigation.CatalogNodeResolution {
        const build = canonicalBuild(reference.coord) orelse
            return .invalid_reference;
        if (reference.index >= build.navigation_node_count) {
            return .invalid_reference;
        }
        return .{ .ready = .{
            .reference = reference,
            .node = build.navigation_nodes[reference.index],
        } };
    }

    pub fn resolveCatalogEdge(
        self: *CanonicalAccess,
        source: navigation.NodeRef,
        ordinal: u8,
    ) navigation.CatalogEdgeResolution {
        const node_value = switch (self.resolveCatalogNode(source)) {
            .ready => |value| value,
            .invalid_reference => return .invalid_reference,
        };
        if (ordinal >= node_value.node.edge_count) return .invalid_ordinal;
        const build = canonicalBuild(source.coord) orelse return .invalid_reference;
        const edge_index = @as(usize, node_value.node.first_edge) + ordinal;
        if (edge_index >= build.navigation_edge_count) return .invalid_ordinal;
        return .{ .ready = .{
            .source = source,
            .ordinal = ordinal,
            .edge = build.navigation_edges[edge_index],
        } };
    }

    pub fn activeTicketFor(
        _: *CanonicalAccess,
        coord: navigation.ChunkCoord,
    ) ?navigation.LoadTicket {
        return if (canonicalBuild(coord) != null) canonicalTicket(coord) else null;
    }

    pub fn topologyRevision(_: *CanonicalAccess) u64 {
        return 1;
    }

    pub fn edgeAvailability(
        _: *CanonicalAccess,
        _: navigation.NodeRef,
        _: navigation.NodeRef,
    ) navigation.EdgeAvailability {
        return .open;
    }
};

fn canonicalBuild(coord: navigation.ChunkCoord) ?district.DistrictBuild {
    const build = switch (recipe.build(coord, recipe.current_recipe_version)) {
        .ready => |value| value,
        .failed => return null,
    };
    if (build.navigation_node_count == 0 or build.validationFailure() != null) return null;
    return build;
}

fn canonicalTicket(coord: navigation.ChunkCoord) navigation.LoadTicket {
    // A nonzero sentinel satisfies the value contract but never leaves this
    // preflight adapter or enters persistent data.
    return .{ .coord = coord, .generation = 1 };
}

test "canonical preflight access validates exact route without runtime authority" {
    comptime navigation.assertImplementation(CanonicalAccess);
    var access = CanonicalAccess{};
    const west_start = navigation.NodeRef{
        .coord = recipe.navigation_west_coord,
        .index = 0,
    };
    const west_middle = navigation.NodeRef{
        .coord = recipe.navigation_west_coord,
        .index = 1,
    };
    const west_seam = navigation.NodeRef{
        .coord = recipe.navigation_west_coord,
        .index = 6,
    };
    const east_seam = navigation.NodeRef{
        .coord = recipe.navigation_east_coord,
        .index = 0,
    };

    const start = switch (access.resolveNode(west_start)) {
        .ready => |value| value,
        else => return error.ExpectedCanonicalNode,
    };
    try std.testing.expectEqualDeep([3]f32{ -5, 0, 5 }, start.node.position);
    try std.testing.expectEqual(@as(u64, 1), start.ticket.generation);
    const seam = switch (access.resolveEdge(west_seam, 1)) {
        .ready => |value| value,
        else => return error.ExpectedCanonicalEdge,
    };
    try std.testing.expectEqualDeep(east_seam, seam.edge.target);
    try std.testing.expectEqual(
        navigation.TraversalValidation.valid,
        access.validateTraversal(west_start, west_middle),
    );
    try std.testing.expectEqual(
        navigation.TraversalValidation.valid,
        access.validateTraversal(west_seam, east_seam),
    );
    try std.testing.expectEqual(
        navigation.TraversalValidation.not_connected,
        access.validateTraversal(west_start, east_seam),
    );
    try std.testing.expect(access.resolveNode(.{
        .coord = recipe.navigation_west_coord,
        .index = 8,
    }) == .invalid_reference);
    try std.testing.expect(access.resolveEdge(west_start, 1) == .invalid_ordinal);
    try std.testing.expectEqualDeep(
        navigation.ChunkCoord{ .x = 1, .z = 0 },
        try navigation.ownerForPosition(.{ 8, 0, 3 }),
    );
}
