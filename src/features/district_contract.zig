//! Renderer-, ECS-, and physics-backend-neutral district loading contract.
//!
//! The first streaming slice deliberately carries a fixed amount of plain data.
//! A worker may prepare this data, but only the simulation owner may turn it
//! into entities or physics bodies.

const std = @import("std");
const engine = @import("engine_contracts");

pub const Pose = engine.Pose;

pub const current_recipe_version: u32 = 1;
pub const max_static_boxes: usize = 8;
pub const decoded_bytes_per_static_box: u32 = 40;
pub const max_decoded_bytes: u32 = max_static_boxes * decoded_bytes_per_static_box;

pub const ChunkCoord = struct {
    x: i32,
    z: i32,

    pub fn eql(a: ChunkCoord, b: ChunkCoord) bool {
        return a.x == b.x and a.z == b.z;
    }
};

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

pub const BuildValidationFailure = enum {
    unsupported_recipe_version,
    no_static_boxes,
    too_many_static_boxes,
    invalid_pose,
    non_canonical_axis_alignment,
    invalid_half_extents,
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

    /// Returns the initialized prefix. Call `validate` before treating the
    /// returned boxes as an accepted build.
    pub fn boxes(self: *const DistrictBuild) []const StaticBox {
        const count = @min(@as(usize, self.static_box_count), max_static_boxes);
        return self.static_boxes[0..count];
    }

    pub fn validationFailure(self: *const DistrictBuild) ?BuildValidationFailure {
        if (self.recipe_version != current_recipe_version) {
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

        const expected_decoded_bytes = decodedByteCount(self.static_box_count);
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
            .decoded_byte_count_mismatch => error.DistrictDecodedByteCountMismatch,
            .checksum_mismatch => error.DistrictChecksumMismatch,
        };
    }

    pub fn calculateChecksum(self: *const DistrictBuild) !u64 {
        if (self.static_box_count > max_static_boxes) {
            return error.DistrictStaticBoxCapacityExceeded;
        }
        return checksumUnchecked(self);
    }
};

pub const ProceduralResult = union(enum) {
    ready: DistrictBuild,
    failed: Failure,
};

/// Produce the deterministic first-slice district recipe. It is intentionally
/// CPU-only and fixed-capacity so the same value can be built on a worker or in
/// a deterministic restore path.
pub fn proceduralBuild(coord: ChunkCoord, recipe_version: u32) ProceduralResult {
    if (recipe_version != current_recipe_version) {
        return .{ .failed = .{ .unsupported_recipe_version = recipe_version } };
    }

    const origin_x = @as(f32, @floatFromInt(coord.x)) * 16.0;
    const origin_z = @as(f32, @floatFromInt(coord.z)) * 16.0;
    var result = DistrictBuild{
        .coord = coord,
        .recipe_version = recipe_version,
        .checksum = 0,
        .decoded_bytes = decodedByteCount(3),
        .static_box_count = 3,
    };
    result.static_boxes[0] = .{
        .pose = .{ .position = .{ origin_x, -0.5, origin_z } },
        .half_extents = .{ 7.5, 0.5, 7.5 },
    };
    result.static_boxes[1] = .{
        .pose = .{ .position = .{ origin_x - 5.5, 1.0, origin_z - 2.0 } },
        .half_extents = .{ 1.0, 1.0, 3.0 },
    };
    result.static_boxes[2] = .{
        .pose = .{ .position = .{ origin_x + 3.0, 0.75, origin_z + 4.5 } },
        .half_extents = .{ 2.5, 0.75, 0.75 },
    };
    result.checksum = checksumUnchecked(&result);
    return .{ .ready = result };
}

pub const LoadRequest = struct {
    ticket: LoadTicket,
    recipe_version: u32 = current_recipe_version,
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

fn decodedByteCount(static_box_count: u8) u32 {
    return @as(u32, static_box_count) * decoded_bytes_per_static_box;
}

fn hasCanonicalIdentityRotation(rotation: [4]f32) bool {
    const expected = [4]f32{ 0, 0, 0, 1 };
    inline for (rotation, expected) |actual, canonical| {
        if (@as(u32, @bitCast(actual)) != @as(u32, @bitCast(canonical))) return false;
    }
    return true;
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
    return hash;
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

test "procedural district build is deterministic, bounded, and coordinate-specific" {
    const coord = ChunkCoord{ .x = 0, .z = -4 };
    const first = proceduralBuild(coord, current_recipe_version).ready;
    const second = proceduralBuild(coord, current_recipe_version).ready;
    try first.validate();
    try second.validate();
    try std.testing.expectEqualDeep(first, second);
    try std.testing.expect(first.static_box_count <= max_static_boxes);
    try std.testing.expect(first.decoded_bytes <= max_decoded_bytes);

    const neighbor = proceduralBuild(.{ .x = 1, .z = -4 }, current_recipe_version).ready;
    try neighbor.validate();
    try std.testing.expect(first.checksum != neighbor.checksum);
    try std.testing.expect(first.static_boxes[0].pose.position[0] !=
        neighbor.static_boxes[0].pose.position[0]);
}

test "district validation rejects non-finite bounds and checksum corruption" {
    var invalid_bounds = proceduralBuild(.{ .x = 0, .z = -4 }, current_recipe_version).ready;
    invalid_bounds.static_boxes[1].half_extents[0] = std.math.nan(f32);
    try std.testing.expectEqual(
        BuildValidationFailure.invalid_half_extents,
        invalid_bounds.validationFailure().?,
    );

    var corrupted = proceduralBuild(.{ .x = 0, .z = -4 }, current_recipe_version).ready;
    corrupted.static_boxes[2].pose.position[2] += 1;
    try std.testing.expectEqual(
        BuildValidationFailure.checksum_mismatch,
        corrupted.validationFailure().?,
    );

    var rotated = proceduralBuild(.{ .x = 0, .z = -4 }, current_recipe_version).ready;
    rotated.static_boxes[0].pose.rotation = .{ 0, 0, 0, 2 };
    try std.testing.expectEqual(
        BuildValidationFailure.non_canonical_axis_alignment,
        rotated.validationFailure().?,
    );
}

test "district recipe failure and load ticket generation are explicit" {
    const unsupported = proceduralBuild(.{ .x = 0, .z = -4 }, current_recipe_version + 1);
    try std.testing.expectEqual(
        current_recipe_version + 1,
        unsupported.failed.unsupported_recipe_version,
    );
    try (LoadTicket{ .coord = .{ .x = 0, .z = -4 }, .generation = 1 }).validate();
    try std.testing.expectError(
        error.InvalidLoadGeneration,
        (LoadTicket{ .coord = .{ .x = 0, .z = -4 }, .generation = 0 }).validate(),
    );
}
