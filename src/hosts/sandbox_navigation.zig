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
        .index = 2,
    };
    const east_seam = navigation.NodeRef{
        .coord = recipe.navigation_east_coord,
        .index = 0,
    };

    const start = switch (access.resolveNode(west_start)) {
        .ready => |value| value,
        else => return error.ExpectedCanonicalNode,
    };
    try std.testing.expectEqualDeep([3]f32{ -4, 0, 3 }, start.node.position);
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
        .index = 3,
    }) == .invalid_reference);
    try std.testing.expect(access.resolveEdge(west_start, 1) == .invalid_ordinal);
    try std.testing.expectEqualDeep(
        navigation.ChunkCoord{ .x = 1, .z = 0 },
        try navigation.ownerForPosition(.{ 8, 0, 3 }),
    );
}
