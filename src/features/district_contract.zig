//! Renderer-, ECS-, and physics-backend-neutral district loading contract.
//!
//! The first streaming slice deliberately carries a fixed amount of plain data.
//! A worker may prepare this data, but only the simulation owner may turn it
//! into entities or physics bodies.

const std = @import("std");
const engine = @import("engine_contracts");

pub const Pose = engine.Pose;

pub const max_static_boxes: usize = 8;
pub const decoded_bytes_per_static_box: u32 = 40;
pub const max_navigation_nodes: usize = 8;
pub const max_navigation_edges: usize = 16;
pub const decoded_bytes_per_navigation_node: u32 = 16;
pub const decoded_bytes_per_navigation_edge: u32 = 12;
pub const max_navigation_decoded_bytes: u32 =
    max_navigation_nodes * decoded_bytes_per_navigation_node +
    max_navigation_edges * decoded_bytes_per_navigation_edge;
pub const max_decoded_bytes: u32 =
    max_static_boxes * decoded_bytes_per_static_box + max_navigation_decoded_bytes;
pub const chunk_span: f32 = 16.0;
pub const chunk_half_span: f32 = chunk_span / 2.0;

pub const ChunkCoord = struct {
    x: i32,
    z: i32,

    pub fn eql(a: ChunkCoord, b: ChunkCoord) bool {
        return a.x == b.x and a.z == b.z;
    }
};

/// Map one finite world position into canonical, half-open district cells.
/// District `(0, 0)` owns `[-8, 8)` on X and Z; therefore the shared boundary
/// at X=8 belongs to the east district `(1, 0)`. Y is not used for ownership,
/// but is still required to be finite so no invalid world pose is admitted.
pub fn chunkCoordForWorldPosition(position: [3]f32) !ChunkCoord {
    for (position) |component| {
        if (!std.math.isFinite(component)) return error.NonFiniteWorldPosition;
    }
    return .{
        .x = try chunkAxisForWorldPosition(position[0]),
        .z = try chunkAxisForWorldPosition(position[2]),
    };
}

fn chunkAxisForWorldPosition(value: f32) !i32 {
    const shifted: f64 = @as(f64, value) + @as(f64, chunk_half_span);
    const coordinate = @floor(shifted / @as(f64, chunk_span));
    const minimum: f64 = @floatFromInt(std.math.minInt(i32));
    const maximum: f64 = @floatFromInt(std.math.maxInt(i32));
    if (coordinate < minimum or coordinate > maximum) {
        return error.WorldPositionOutsideDistrictRange;
    }
    return @intFromFloat(coordinate);
}

/// One generation identifies one attempt to load one coordinate. Generations
/// are nonzero and monotonically increase within a loader instance.
pub const LoadTicket = struct {
    coord: ChunkCoord,
    generation: u64,

    pub fn validate(self: LoadTicket) !void {
        if (self.generation == 0) return error.InvalidLoadGeneration;
    }

    pub fn isValid(self: LoadTicket) bool {
        self.validate() catch return false;
        return true;
    }

    pub fn eql(a: LoadTicket, b: LoadTicket) bool {
        return ChunkCoord.eql(a.coord, b.coord) and a.generation == b.generation;
    }
};

pub const StaticBox = struct {
    pose: Pose = .{},
    half_extents: [3]f32 = .{ 1, 1, 1 },
};

pub const navigation_node_terminal: u8 = 1 << 0;
pub const navigation_node_known_flags: u8 = navigation_node_terminal;

/// Stable content-cohort-bound reference. Node indices have meaning only with
/// the exact district recipe/content fingerprint that admitted them.
pub const NavigationNodeRef = struct {
    coord: ChunkCoord = .{ .x = 0, .z = 0 },
    index: u8 = 0,

    pub fn eql(a: NavigationNodeRef, b: NavigationNodeRef) bool {
        return ChunkCoord.eql(a.coord, b.coord) and a.index == b.index;
    }
};

/// One world-space waypoint plus its canonical contiguous outgoing edge
/// range. The explicit cooked representation is exactly 16 bytes.
pub const NavigationNode = struct {
    position: [3]f32 = .{ 0, 0, 0 },
    first_edge: u8 = 0,
    edge_count: u8 = 0,
    flags: u8 = 0,
    reserved: u8 = 0,

    pub fn terminal(self: NavigationNode) bool {
        return self.flags & navigation_node_terminal != 0;
    }
};

/// One directed graph edge. The explicit cooked representation is exactly 12
/// bytes: target X/Z, target node, flags, and two zero reserved bytes.
pub const NavigationEdge = struct {
    target: NavigationNodeRef = .{},
    flags: u8 = 0,
    reserved: u16 = 0,
};

pub const BuildValidationFailure = enum {
    unsupported_recipe_version,
    no_static_boxes,
    too_many_static_boxes,
    invalid_pose,
    non_canonical_axis_alignment,
    invalid_half_extents,
    too_many_navigation_nodes,
    too_many_navigation_edges,
    navigation_count_mismatch,
    invalid_navigation_position,
    navigation_node_outside_district,
    invalid_navigation_node_flags,
    invalid_navigation_node_reserved,
    invalid_navigation_edge_range,
    invalid_navigation_node_degree,
    invalid_navigation_edge_target,
    invalid_navigation_edge_flags,
    invalid_navigation_edge_reserved,
    duplicate_navigation_edge,
    non_canonical_navigation_edge_order,
    decoded_byte_count_mismatch,
    checksum_mismatch,
};

pub const Failure = union(enum) {
    unsupported_recipe_version: u32,
    invalid_build: BuildValidationFailure,
};

pub const DistrictBuild = struct {
    coord: ChunkCoord,
    recipe_version: u32,
    checksum: u64,
    decoded_bytes: u32,
    static_box_count: u8,
    static_boxes: [max_static_boxes]StaticBox = [_]StaticBox{.{}} ** max_static_boxes,
    navigation_node_count: u8 = 0,
    navigation_edge_count: u8 = 0,
    navigation_nodes: [max_navigation_nodes]NavigationNode =
        [_]NavigationNode{.{}} ** max_navigation_nodes,
    navigation_edges: [max_navigation_edges]NavigationEdge =
        [_]NavigationEdge{.{}} ** max_navigation_edges,

    /// Returns the initialized prefix. Call `validate` before treating the
    /// returned boxes as an accepted build.
    pub fn boxes(self: *const DistrictBuild) []const StaticBox {
        const count = @min(@as(usize, self.static_box_count), max_static_boxes);
        return self.static_boxes[0..count];
    }

    pub fn navigationNodes(self: *const DistrictBuild) []const NavigationNode {
        const count = @min(@as(usize, self.navigation_node_count), max_navigation_nodes);
        return self.navigation_nodes[0..count];
    }

    pub fn navigationEdges(self: *const DistrictBuild) []const NavigationEdge {
        const count = @min(@as(usize, self.navigation_edge_count), max_navigation_edges);
        return self.navigation_edges[0..count];
    }

    pub fn validationFailure(self: *const DistrictBuild) ?BuildValidationFailure {
        if (self.recipe_version == 0) {
            return .unsupported_recipe_version;
        }
        if (self.static_box_count == 0) return .no_static_boxes;
        if (self.static_box_count > max_static_boxes) return .too_many_static_boxes;

        for (self.boxes()) |box| {
            box.pose.validate() catch return .invalid_pose;
            if (!hasCanonicalIdentityRotation(box.pose.rotation)) {
                return .non_canonical_axis_alignment;
            }
            for (box.half_extents) |extent| {
                if (!std.math.isFinite(extent) or extent <= 0) {
                    return .invalid_half_extents;
                }
            }
        }

        if (self.navigation_node_count > max_navigation_nodes) {
            return .too_many_navigation_nodes;
        }
        if (self.navigation_edge_count > max_navigation_edges) {
            return .too_many_navigation_edges;
        }
        if ((self.navigation_node_count == 0) != (self.navigation_edge_count == 0)) {
            return .navigation_count_mismatch;
        }

        var expected_first_edge: usize = 0;
        for (self.navigationNodes(), 0..) |node, node_index| {
            for (node.position) |component| {
                if (!isCanonicalFiniteF32(component)) return .invalid_navigation_position;
            }
            const owner = chunkCoordForWorldPosition(node.position) catch
                return .navigation_node_outside_district;
            if (!ChunkCoord.eql(owner, self.coord)) return .navigation_node_outside_district;
            if (node.flags & ~navigation_node_known_flags != 0) {
                return .invalid_navigation_node_flags;
            }
            if (node.reserved != 0) return .invalid_navigation_node_reserved;
            if (node.edge_count == 0 or node.edge_count > 2) {
                return .invalid_navigation_node_degree;
            }
            if (node.first_edge != expected_first_edge) {
                return .invalid_navigation_edge_range;
            }
            const edge_end = std.math.add(
                usize,
                expected_first_edge,
                node.edge_count,
            ) catch return .invalid_navigation_edge_range;
            if (edge_end > self.navigation_edge_count) {
                return .invalid_navigation_edge_range;
            }

            var previous_target: ?NavigationNodeRef = null;
            for (self.navigationEdges()[expected_first_edge..edge_end]) |edge| {
                if (edge.flags != 0) return .invalid_navigation_edge_flags;
                if (edge.reserved != 0) return .invalid_navigation_edge_reserved;
                if (edge.target.index >= max_navigation_nodes) {
                    return .invalid_navigation_edge_target;
                }
                if (ChunkCoord.eql(edge.target.coord, self.coord)) {
                    if (edge.target.index >= self.navigation_node_count or
                        edge.target.index == node_index)
                    {
                        return .invalid_navigation_edge_target;
                    }
                } else if (!coordinatesAreAdjacent(self.coord, edge.target.coord)) {
                    return .invalid_navigation_edge_target;
                }
                if (previous_target) |previous| {
                    switch (orderNodeRef(previous, edge.target)) {
                        .lt => {},
                        .eq => return .duplicate_navigation_edge,
                        .gt => return .non_canonical_navigation_edge_order,
                    }
                }
                previous_target = edge.target;
            }
            expected_first_edge = edge_end;
        }
        if (expected_first_edge != self.navigation_edge_count) {
            return .invalid_navigation_edge_range;
        }

        const expected_decoded_bytes = decodedByteCount(
            self.static_box_count,
            self.navigation_node_count,
            self.navigation_edge_count,
        );
        if (self.decoded_bytes != expected_decoded_bytes) {
            return .decoded_byte_count_mismatch;
        }
        if (self.checksum != checksumUnchecked(self)) return .checksum_mismatch;
        return null;
    }

    pub fn validate(self: *const DistrictBuild) !void {
        const failure = self.validationFailure() orelse return;
        return switch (failure) {
            .unsupported_recipe_version => error.UnsupportedDistrictRecipeVersion,
            .no_static_boxes => error.EmptyDistrictBuild,
            .too_many_static_boxes => error.DistrictStaticBoxCapacityExceeded,
            .invalid_pose => error.InvalidDistrictPose,
            .non_canonical_axis_alignment => error.DistrictBoxMustBeAxisAligned,
            .invalid_half_extents => error.InvalidDistrictHalfExtents,
            .too_many_navigation_nodes => error.DistrictNavigationNodeCapacityExceeded,
            .too_many_navigation_edges => error.DistrictNavigationEdgeCapacityExceeded,
            .navigation_count_mismatch => error.DistrictNavigationCountMismatch,
            .invalid_navigation_position => error.InvalidDistrictNavigationPosition,
            .navigation_node_outside_district => error.DistrictNavigationNodeOutsideDistrict,
            .invalid_navigation_node_flags => error.InvalidDistrictNavigationNodeFlags,
            .invalid_navigation_node_reserved => error.InvalidDistrictNavigationNodeReserved,
            .invalid_navigation_edge_range => error.InvalidDistrictNavigationEdgeRange,
            .invalid_navigation_node_degree => error.InvalidDistrictNavigationNodeDegree,
            .invalid_navigation_edge_target => error.InvalidDistrictNavigationEdgeTarget,
            .invalid_navigation_edge_flags => error.InvalidDistrictNavigationEdgeFlags,
            .invalid_navigation_edge_reserved => error.InvalidDistrictNavigationEdgeReserved,
            .duplicate_navigation_edge => error.DuplicateDistrictNavigationEdge,
            .non_canonical_navigation_edge_order => error.NonCanonicalDistrictNavigationEdgeOrder,
            .decoded_byte_count_mismatch => error.DistrictDecodedByteCountMismatch,
            .checksum_mismatch => error.DistrictChecksumMismatch,
        };
    }

    pub fn calculateChecksum(self: *const DistrictBuild) !u64 {
        if (self.static_box_count > max_static_boxes)
            return error.DistrictStaticBoxCapacityExceeded;
        if (self.navigation_node_count > max_navigation_nodes)
            return error.DistrictNavigationNodeCapacityExceeded;
        if (self.navigation_edge_count > max_navigation_edges)
            return error.DistrictNavigationEdgeCapacityExceeded;
        return checksumUnchecked(self);
    }
};

pub const ProceduralResult = union(enum) {
    ready: DistrictBuild,
    failed: Failure,
};

/// Request a versioned district recipe from the composition's canonical
/// content provider. The resulting build remains CPU-only and fixed-capacity
/// so it can be produced on a worker or reconstructed during restore.
pub const LoadRequest = struct {
    ticket: LoadTicket,
    recipe_version: u32,
};

pub const RequestDisposition = enum {
    accepted,
    busy,
    stale,
    invalid_ticket,
};

pub const CancelDisposition = enum {
    requested,
    idle,
    stale,
    invalid_ticket,
};

pub const PendingStage = enum {
    queued,
    working,
};

pub const ReadyCompletion = struct {
    ticket: LoadTicket,
    build: DistrictBuild,
};

pub const FailedCompletion = struct {
    ticket: LoadTicket,
    failure: Failure,
};

pub const Completion = union(enum) {
    ready: ReadyCompletion,
    cancelled: LoadTicket,
    failed: FailedCompletion,

    pub fn ticket(self: Completion) LoadTicket {
        return switch (self) {
            .ready => |ready| ready.ticket,
            .cancelled => |cancelled| cancelled,
            .failed => |failed| failed.ticket,
        };
    }
};

pub const PollResult = union(enum) {
    idle,
    invalid_ticket,
    stale: LoadTicket,
    pending: PendingStage,
    completion: Completion,
};

/// Validate the minimal worker-facing port used by DistrictFeature. Expected
/// capacity and stale-generation cases remain values; infrastructure failure
/// while starting a worker remains an error from `request`.
pub fn assertLoaderImplementation(comptime Loader: type) void {
    comptime {
        assertFallibleMethod(
            Loader,
            "request",
            .{ *Loader, LoadRequest },
            RequestDisposition,
        );
        assertInfallibleMethod(
            Loader,
            "cancel",
            .{ *Loader, LoadTicket },
            CancelDisposition,
        );
        assertInfallibleMethod(
            Loader,
            "poll",
            .{ *Loader, LoadTicket },
            PollResult,
        );
    }
}

pub fn decodedByteCount(
    static_box_count: u8,
    navigation_node_count: u8,
    navigation_edge_count: u8,
) u32 {
    return @as(u32, static_box_count) * decoded_bytes_per_static_box +
        @as(u32, navigation_node_count) * decoded_bytes_per_navigation_node +
        @as(u32, navigation_edge_count) * decoded_bytes_per_navigation_edge;
}

fn hasCanonicalIdentityRotation(rotation: [4]f32) bool {
    const expected = [4]f32{ 0, 0, 0, 1 };
    inline for (rotation, expected) |actual, canonical| {
        if (@as(u32, @bitCast(actual)) != @as(u32, @bitCast(canonical))) return false;
    }
    return true;
}

fn isCanonicalFiniteF32(value: f32) bool {
    if (!std.math.isFinite(value)) return false;
    if (value == 0 and @as(u32, @bitCast(value)) != 0) return false;
    return true;
}

fn coordinatesAreAdjacent(a: ChunkCoord, b: ChunkCoord) bool {
    const dx = @abs(@as(i64, a.x) - @as(i64, b.x));
    const dz = @abs(@as(i64, a.z) - @as(i64, b.z));
    return dx + dz == 1;
}

fn orderNodeRef(a: NavigationNodeRef, b: NavigationNodeRef) std.math.Order {
    const x_order = std.math.order(a.coord.x, b.coord.x);
    if (x_order != .eq) return x_order;
    const z_order = std.math.order(a.coord.z, b.coord.z);
    if (z_order != .eq) return z_order;
    return std.math.order(a.index, b.index);
}

const fnv_offset_basis: u64 = 14_695_981_039_346_656_037;
const fnv_prime: u64 = 1_099_511_628_211;

fn checksumUnchecked(build: *const DistrictBuild) u64 {
    var hash = fnv_offset_basis;
    hashU32(&hash, @bitCast(build.coord.x));
    hashU32(&hash, @bitCast(build.coord.z));
    hashU32(&hash, build.recipe_version);
    hashByte(&hash, build.static_box_count);
    for (build.boxes()) |box| {
        for (box.pose.position) |value| hashU32(&hash, @bitCast(value));
        for (box.pose.rotation) |value| hashU32(&hash, @bitCast(value));
        for (box.half_extents) |value| hashU32(&hash, @bitCast(value));
    }
    hashByte(&hash, build.navigation_node_count);
    hashByte(&hash, build.navigation_edge_count);
    for (build.navigationNodes()) |node| {
        for (node.position) |value| hashU32(&hash, @bitCast(value));
        hashByte(&hash, node.first_edge);
        hashByte(&hash, node.edge_count);
        hashByte(&hash, node.flags);
        hashByte(&hash, node.reserved);
    }
    for (build.navigationEdges()) |edge| {
        hashU32(&hash, @bitCast(edge.target.coord.x));
        hashU32(&hash, @bitCast(edge.target.coord.z));
        hashByte(&hash, edge.target.index);
        hashByte(&hash, edge.flags);
        hashU16(&hash, edge.reserved);
    }
    return hash;
}

fn hashU16(hash: *u64, value: u16) void {
    inline for (0..2) |byte_index| {
        const shift: u4 = @intCast(byte_index * 8);
        hashByte(hash, @truncate(value >> shift));
    }
}

fn hashU32(hash: *u64, value: u32) void {
    inline for (0..4) |byte_index| {
        const shift: u5 = @intCast(byte_index * 8);
        hashByte(hash, @truncate(value >> shift));
    }
}

fn hashByte(hash: *u64, byte: u8) void {
    hash.* ^= byte;
    hash.* *%= fnv_prime;
}

fn assertInfallibleMethod(
    comptime Loader: type,
    comptime name: []const u8,
    comptime expected_params: anytype,
    comptime expected_return: type,
) void {
    if (!@hasDecl(Loader, name)) {
        @compileError("district loader implementation is missing " ++ name);
    }
    const method = switch (@typeInfo(@TypeOf(@field(Loader, name)))) {
        .@"fn" => |info| info,
        else => @compileError("district loader declaration " ++ name ++ " must be a function"),
    };
    if (method.params.len != expected_params.len) {
        @compileError("district loader method " ++ name ++ " has the wrong parameter count");
    }
    inline for (expected_params, 0..) |expected, index| {
        const actual = method.params[index].type orelse
            @compileError("district loader method " ++ name ++ " cannot use an anytype parameter");
        if (actual != expected) {
            @compileError("district loader method " ++ name ++ " has an incompatible parameter");
        }
    }
    if (method.return_type == null or method.return_type.? != expected_return) {
        @compileError("district loader method " ++ name ++ " has an incompatible return type");
    }
}

fn assertFallibleMethod(
    comptime Loader: type,
    comptime name: []const u8,
    comptime expected_params: anytype,
    comptime expected_payload: type,
) void {
    if (!@hasDecl(Loader, name)) {
        @compileError("district loader implementation is missing " ++ name);
    }
    const method = switch (@typeInfo(@TypeOf(@field(Loader, name)))) {
        .@"fn" => |info| info,
        else => @compileError("district loader declaration " ++ name ++ " must be a function"),
    };
    if (method.params.len != expected_params.len) {
        @compileError("district loader method " ++ name ++ " has the wrong parameter count");
    }
    inline for (expected_params, 0..) |expected, index| {
        const actual = method.params[index].type orelse
            @compileError("district loader method " ++ name ++ " cannot use an anytype parameter");
        if (actual != expected) {
            @compileError("district loader method " ++ name ++ " has an incompatible parameter");
        }
    }
    const return_type = method.return_type orelse
        @compileError("district loader method " ++ name ++ " must have a return type");
    const return_payload = switch (@typeInfo(return_type)) {
        .error_union => |info| info.payload,
        else => @compileError("district loader method " ++ name ++ " must return an error union"),
    };
    if (return_payload != expected_payload) {
        @compileError("district loader method " ++ name ++ " has an incompatible return payload");
    }
}

const ContractExample = struct {
    pub fn request(_: *ContractExample, _: LoadRequest) !RequestDisposition {
        return .accepted;
    }

    pub fn cancel(_: *ContractExample, _: LoadTicket) CancelDisposition {
        return .idle;
    }

    pub fn poll(_: *ContractExample, _: LoadTicket) PollResult {
        return .idle;
    }
};

test "district loader example satisfies the structural port" {
    comptime assertLoaderImplementation(ContractExample);
}

test "load ticket generation is explicit" {
    try (LoadTicket{ .coord = .{ .x = 0, .z = -4 }, .generation = 1 }).validate();
    try std.testing.expectError(
        error.InvalidLoadGeneration,
        (LoadTicket{ .coord = .{ .x = 0, .z = -4 }, .generation = 0 }).validate(),
    );
}

test "world position ownership uses finite half-open district cells" {
    try std.testing.expectEqualDeep(
        ChunkCoord{ .x = 0, .z = 0 },
        try chunkCoordForWorldPosition(.{ -8.0, 0, 7.999_999 }),
    );
    try std.testing.expectEqualDeep(
        ChunkCoord{ .x = 1, .z = 0 },
        try chunkCoordForWorldPosition(.{ 8.0, 100, -8.0 }),
    );
    try std.testing.expectEqualDeep(
        ChunkCoord{ .x = -1, .z = -1 },
        try chunkCoordForWorldPosition(.{ -8.000_001, -100, -8.000_001 }),
    );
    try std.testing.expectEqualDeep(
        ChunkCoord{ .x = -1, .z = 2 },
        try chunkCoordForWorldPosition(.{ -24.0, 0, 24.0 }),
    );

    try std.testing.expectError(
        error.NonFiniteWorldPosition,
        chunkCoordForWorldPosition(.{ 0, std.math.nan(f32), 0 }),
    );
    try std.testing.expectError(
        error.NonFiniteWorldPosition,
        chunkCoordForWorldPosition(.{ std.math.inf(f32), 0, 0 }),
    );
    try std.testing.expectError(
        error.WorldPositionOutsideDistrictRange,
        chunkCoordForWorldPosition(.{ std.math.floatMax(f32), 0, 0 }),
    );
    try std.testing.expectError(
        error.WorldPositionOutsideDistrictRange,
        chunkCoordForWorldPosition(.{ -std.math.floatMax(f32), 0, 0 }),
    );
}
