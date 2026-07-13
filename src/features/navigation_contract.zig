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
};

test "navigation access example satisfies the generation-aware value port" {
    comptime assertImplementation(Example);
    try @import("std").testing.expectEqualDeep(
        ChunkCoord{ .x = 1, .z = 0 },
        try ownerForPosition(.{ 8, 0, 3 }),
    );
}
