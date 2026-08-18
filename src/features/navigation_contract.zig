//! Narrow generation-aware navigation capability consumed by NpcFeature.
//!
//! DistrictFeature owns residency and the admitted route fragment. Consumers
//! receive copied values tied to one exact active load ticket; no ECS value,
//! backend handle, borrowed slice, or district-private component crosses this
//! boundary.

const district = @import("district_contract");

pub const NodeRef = district.NavigationNodeRef;
pub const Node = district.NavigationNode;
pub const Edge = district.NavigationEdge;
pub const LoadTicket = district.LoadTicket;
pub const ChunkCoord = district.ChunkCoord;
pub const max_destination_anchors: usize = 2;
pub const max_route_nodes: usize = 4 * district.max_navigation_nodes;
pub const max_route_edges: usize = max_route_nodes - 1;

/// Stable game-content identity. A destination survives route invalidation,
/// residency changes, and physical displacement; node references do not.
pub const DestinationId = struct {
    value: u16 = 0,

    pub fn validate(self: DestinationId) !void {
        if (self.value == 0) return error.InvalidNavigationDestinationId;
    }

    pub fn eql(a: DestinationId, b: DestinationId) bool {
        return a.value == b.value;
    }
};

pub const Destination = struct {
    id: DestinationId,
    position: [3]f32,
    arrival_radius: f32,
    anchors: [max_destination_anchors]NodeRef =
        [_]NodeRef{.{}} ** max_destination_anchors,
    anchor_count: u8,

    pub fn anchorSlice(self: *const Destination) []const NodeRef {
        return self.anchors[0..@min(
            @as(usize, self.anchor_count),
            max_destination_anchors,
        )];
    }

    pub fn validate(self: Destination) !void {
        try self.id.validate();
        for (self.position) |component| {
            if (!@import("std").math.isFinite(component)) {
                return error.InvalidNavigationDestinationPosition;
            }
        }
        if (!@import("std").math.isFinite(self.arrival_radius) or
            self.arrival_radius <= 0 or self.anchor_count == 0 or
            self.anchor_count > max_destination_anchors)
        {
            return error.InvalidNavigationDestination;
        }
        for (self.anchorSlice(), 0..) |anchor, index| {
            for (self.anchorSlice()[0..index]) |earlier| {
                if (NodeRef.eql(anchor, earlier)) {
                    return error.DuplicateNavigationDestinationAnchor;
                }
            }
        }
    }
};

pub const DestinationResolution = union(enum) {
    ready: Destination,
    invalid_destination,
};

/// Canonical finite half-open world ownership rule shared by district and NPC
/// authority. This is pure value logic; it does not grant residency access.
pub const ownerForPosition = district.chunkCoordForWorldPosition;

pub const ResolvedNode = struct {
    ticket: LoadTicket,
    reference: NodeRef,
    node: Node,
};

pub const ResolvedEdge = struct {
    ticket: LoadTicket,
    source: NodeRef,
    ordinal: u8,
    edge: Edge,
};

pub const CatalogNode = struct {
    reference: NodeRef,
    node: Node,
};

pub const CatalogEdge = struct {
    source: NodeRef,
    ordinal: u8,
    edge: Edge,
};

pub const CatalogNodeResolution = union(enum) {
    ready: CatalogNode,
    invalid_reference,
};

pub const CatalogEdgeResolution = union(enum) {
    ready: CatalogEdge,
    invalid_reference,
    invalid_ordinal,
};

pub const EdgeAvailability = enum {
    open,
    closed,
};

pub const NodeResolution = union(enum) {
    ready: ResolvedNode,
    district_inactive,
    invalid_reference,
};

pub const EdgeResolution = union(enum) {
    ready: ResolvedEdge,
    district_inactive,
    invalid_reference,
    invalid_ordinal,
};

/// Result of projecting an authoritative world position onto the nearest
/// admitted node in its owning active district. Ties are resolved by node
/// index so native iteration order can never affect gameplay.
pub const NearestNodeResolution = union(enum) {
    ready: ResolvedNode,
    district_inactive,
    unavailable,
};

pub const TraversalValidation = enum {
    valid,
    invalid_source,
    invalid_target,
    not_connected,
};

/// Validate the structural district navigation port consumed by NpcFeature.
/// All calls are owner-thread, allocation-free, and infallible; inactive or
/// invalid logical content is an explicit domain result rather than an adapter
/// failure. Exact content-cohort validity has precedence over residency:
/// `invalid_reference` / `invalid_ordinal` must be returned even while the
/// referenced district is inactive. This lets command admission distinguish a
/// valid waiting goal from malformed content without granting residency.
///
/// A ready result always carries the current exact load ticket. Because calls
/// do not take an expected generation, a consumer that retains runtime state
/// must re-resolve and compare that ticket before every movement tick. A
/// changed ticket is stale consumer state and must be reconciled before use;
/// load tickets are never persistent data.
pub fn assertImplementation(comptime NavigationAccess: type) void {
    comptime {
        assertMethod(
            NavigationAccess,
            "resolveNode",
            .{ *NavigationAccess, NodeRef },
            NodeResolution,
        );
        assertMethod(
            NavigationAccess,
            "resolveEdge",
            .{ *NavigationAccess, NodeRef, u8 },
            EdgeResolution,
        );
        assertMethod(
            NavigationAccess,
            "validateTraversal",
            .{ *NavigationAccess, NodeRef, NodeRef },
            TraversalValidation,
        );
        assertMethod(
            NavigationAccess,
            "nearestActiveNode",
            .{ *NavigationAccess, [3]f32 },
            NearestNodeResolution,
        );
        assertMethod(
            NavigationAccess,
            "resolveDestination",
            .{ *NavigationAccess, DestinationId },
            DestinationResolution,
        );
        assertMethod(
            NavigationAccess,
            "resolveCatalogNode",
            .{ *NavigationAccess, NodeRef },
            CatalogNodeResolution,
        );
        assertMethod(
            NavigationAccess,
            "resolveCatalogEdge",
            .{ *NavigationAccess, NodeRef, u8 },
            CatalogEdgeResolution,
        );
        assertMethod(
            NavigationAccess,
            "activeTicketFor",
            .{ *NavigationAccess, ChunkCoord },
            ?LoadTicket,
        );
        assertMethod(
            NavigationAccess,
            "topologyRevision",
            .{*NavigationAccess},
            u64,
        );
        assertMethod(
            NavigationAccess,
            "edgeAvailability",
            .{ *NavigationAccess, NodeRef, NodeRef },
            EdgeAvailability,
        );
    }
}

fn assertMethod(
    comptime Access: type,
    comptime name: []const u8,
    comptime expected_params: anytype,
    comptime expected_return: type,
) void {
    if (!@hasDecl(Access, name)) {
        @compileError("navigation access implementation is missing " ++ name);
    }
    const method = switch (@typeInfo(@TypeOf(@field(Access, name)))) {
        .@"fn" => |info| info,
        else => @compileError("navigation access declaration " ++ name ++
            " must be a function"),
    };
    if (method.params.len != expected_params.len) {
        @compileError("navigation access method " ++ name ++
            " has the wrong parameter count");
    }
    inline for (expected_params, 0..) |expected, index| {
        const actual = method.params[index].type orelse
            @compileError("navigation access method " ++ name ++
                " cannot use an anytype parameter");
        if (actual != expected) {
            @compileError("navigation access method " ++ name ++
                " has an incompatible parameter");
        }
    }
    if (method.return_type == null or method.return_type.? != expected_return) {
        @compileError("navigation access method " ++ name ++
            " has an incompatible return type");
    }
}

const Example = struct {
    pub fn resolveNode(_: *Example, _: NodeRef) NodeResolution {
        return .district_inactive;
    }

    pub fn resolveEdge(_: *Example, _: NodeRef, _: u8) EdgeResolution {
        return .district_inactive;
    }

    pub fn validateTraversal(_: *Example, _: NodeRef, _: NodeRef) TraversalValidation {
        return .not_connected;
    }

    pub fn nearestActiveNode(_: *Example, _: [3]f32) NearestNodeResolution {
        return .district_inactive;
    }

    pub fn resolveDestination(
        _: *Example,
        _: DestinationId,
    ) DestinationResolution {
        return .invalid_destination;
    }

    pub fn resolveCatalogNode(
        _: *Example,
        _: NodeRef,
    ) CatalogNodeResolution {
        return .invalid_reference;
    }

    pub fn resolveCatalogEdge(
        _: *Example,
        _: NodeRef,
        _: u8,
    ) CatalogEdgeResolution {
        return .invalid_reference;
    }

    pub fn activeTicketFor(_: *Example, _: ChunkCoord) ?LoadTicket {
        return null;
    }

    pub fn topologyRevision(_: *Example) u64 {
        return 1;
    }

    pub fn edgeAvailability(
        _: *Example,
        _: NodeRef,
        _: NodeRef,
    ) EdgeAvailability {
        return .open;
    }
};

test "navigation access example satisfies the generation-aware value port" {
    comptime assertImplementation(Example);
    try @import("std").testing.expectEqualDeep(
        ChunkCoord{ .x = 1, .z = 0 },
        try ownerForPosition(.{ 8, 0, 3 }),
    );
}

test "semantic destination rejects zero identity and duplicate anchors" {
    const std = @import("std");
    try std.testing.expectError(
        error.InvalidNavigationDestinationId,
        (DestinationId{}).validate(),
    );
    try std.testing.expectError(
        error.DuplicateNavigationDestinationAnchor,
        (Destination{
            .id = .{ .value = 1 },
            .position = .{ 0, 0, 0 },
            .arrival_radius = 0.25,
            .anchors = .{ .{}, .{} },
            .anchor_count = 2,
        }).validate(),
    );
}
