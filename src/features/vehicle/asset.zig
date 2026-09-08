//! Versioned, game-owned vehicle definitions. Runtime instances retain an
//! owned immutable admitted value; resolving a newer disk revision is explicit.
const std = @import("std");
const engine = @import("engine_contracts");
const contract = @import("contract.zig");

pub const format_version: u32 = 2;
const magic = "ICVEHDEF";
const header_bytes = 52;

pub const VehicleArchetypeId = struct {
    asset: engine.assets.AssetId,

    pub fn validate(self: VehicleArchetypeId) !void {
        try self.asset.validate();
    }
};

pub const VisualPart = struct {
    mesh: engine.assets.AssetId,
    material: engine.assets.AssetId,
    local_pose: engine.physics.Pose,
    scale: [3]f32,

    pub fn validate(self: VisualPart) !void {
        try self.mesh.validate();
        try self.material.validate();
        try self.local_pose.validate();
        for (self.scale) |value| if (!std.math.isFinite(value) or value <= 0) return error.InvalidVehicleVisualScale;
    }
};

pub const Visuals = struct {
    chassis: VisualPart,
    /// Attachments are relative to the four wheel poses, in canonical order.
    wheels: [engine.physics.vehicle_wheel_count]VisualPart,
};

pub const Definition = struct {
    version: u32,
    id: VehicleArchetypeId,
    label: []const u8,
    revision: u64,
    tuning: contract.VehicleTuningV1,
    visuals: Visuals,

    pub fn validate(self: Definition) !void {
        if (self.version != format_version) return error.VehicleDefinitionVersionMismatch;
        try self.id.validate();
        if (self.revision == 0 or self.label.len == 0 or !std.unicode.utf8ValidateSlice(self.label)) return error.InvalidVehicleDefinition;
        _ = try self.tuning.toTuning();
        try self.visuals.chassis.validate();
        for (self.visuals.wheels) |wheel| try wheel.validate();
    }

    pub fn validateCatalog(self: Definition, catalog: []const engine.assets.Entry) !void {
        try self.validate();
        try validatePart(self.visuals.chassis, catalog);
        for (self.visuals.wheels) |wheel| try validatePart(wheel, catalog);
    }

    fn validatePart(part: VisualPart, catalog: []const engine.assets.Entry) !void {
        var mesh_found = false;
        var material_found = false;
        for (catalog) |entry| {
            if (std.meta.eql(entry.id, part.mesh) and entry.kind == .mesh) mesh_found = true;
            if (std.meta.eql(entry.id, part.material) and entry.kind == .material) material_found = true;
        }
        if (!mesh_found) return error.VehicleMeshMissing;
        if (!material_found) return error.VehicleMaterialMissing;
    }

    pub fn digest(self: Definition, allocator: std.mem.Allocator) !engine.assets.Digest {
        try self.validate();
        const payload = try std.json.Stringify.valueAlloc(allocator, self, .{});
        defer allocator.free(payload);
        var result: engine.assets.Digest = undefined;
        std.crypto.hash.sha2.Sha256.hash(payload, &result, .{});
        return result;
    }

    pub fn clone(self: Definition, allocator: std.mem.Allocator) !Owned {
        try self.validate();
        const payload = try std.json.Stringify.valueAlloc(allocator, self, .{});
        defer allocator.free(payload);
        return std.json.parseFromSlice(Definition, allocator, payload, .{ .allocate = .alloc_always });
    }
};

pub const Owned = std.json.Parsed(Definition);

pub fn encode(allocator: std.mem.Allocator, definition: Definition) ![]u8 {
    try definition.validate();
    const payload = try std.json.Stringify.valueAlloc(allocator, definition, .{});
    defer allocator.free(payload);
    const bytes = try allocator.alloc(u8, header_bytes + payload.len);
    @memcpy(bytes[0..8], magic);
    std.mem.writeInt(u32, bytes[8..12], format_version, .little);
    std.mem.writeInt(u64, bytes[12..20], payload.len, .little);
    std.crypto.hash.sha2.Sha256.hash(payload, bytes[20..52], .{});
    @memcpy(bytes[header_bytes..], payload);
    return bytes;
}

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !Owned {
    if (bytes.len < header_bytes or !std.mem.eql(u8, bytes[0..8], magic)) return error.InvalidVehicleAsset;
    if (std.mem.readInt(u32, bytes[8..12], .little) != format_version) return error.VehicleDefinitionVersionMismatch;
    if (std.mem.readInt(u64, bytes[12..20], .little) != bytes.len - header_bytes) return error.VehicleAssetSizeMismatch;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes[header_bytes..], &digest, .{});
    if (!std.mem.eql(u8, &digest, bytes[20..52])) return error.VehicleAssetDigestMismatch;
    var parsed = try std.json.parseFromSlice(Definition, allocator, bytes[header_bytes..], .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    try parsed.value.validate();
    return parsed;
}

pub fn filename(id: VehicleArchetypeId) [43]u8 {
    var result: [43]u8 = undefined;
    _ = std.fmt.bufPrint(&result, "{x:0>16}-{x:0>16}.icvehicle", .{ id.asset.namespace, id.asset.local }) catch unreachable;
    return result;
}

pub fn read(allocator: std.mem.Allocator, io: std.Io, directory: std.Io.Dir, id: VehicleArchetypeId) !Owned {
    const bytes = try directory.readFileAlloc(io, &filename(id), allocator, .unlimited);
    defer allocator.free(bytes);
    var parsed = try decode(allocator, bytes);
    errdefer parsed.deinit();
    if (!std.meta.eql(id, parsed.value.id)) return error.VehicleAssetIdentityMismatch;
    return parsed;
}

/// Atomic replacement of precisely one archetype; world saves are independent.
pub fn write(allocator: std.mem.Allocator, io: std.Io, directory: std.Io.Dir, definition: Definition) !void {
    const bytes = try encode(allocator, definition);
    defer allocator.free(bytes);
    var atomic = try directory.createFileAtomic(io, &filename(definition.id), .{ .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, bytes);
    try atomic.file.sync(io);
    try atomic.replace(io);
}

/// Explicit synthetic data for renderer-free capability validation only.
pub fn validationFixture() Definition {
    const wheel = VisualPart{ .mesh = .{ .namespace = 1, .local = 3 }, .material = .{ .namespace = 1, .local = 4 }, .local_pose = .{}, .scale = .{ 1, 1, 1 } };
    return .{ .version = format_version, .id = .{ .asset = .{ .namespace = 1, .local = 5 } }, .label = "Test sedan", .revision = 1, .tuning = contract.VehicleTuningV1.fromTuning(.{}), .visuals = .{ .chassis = .{ .mesh = .{ .namespace = 1, .local = 1 }, .material = .{ .namespace = 1, .local = 2 }, .local_pose = .{}, .scale = .{ 1, 1, 1 } }, .wheels = @splat(wheel) } };
}

test "vehicle asset owns authored curves and gear counts through durable restart" {
    var definition = validationFixture();
    definition.tuning.powertrain.forward_gears = &.{ 4.1, 3.2, 2.7, 2.2, 1.8, 1.4, 1.1, 0.9, 0.7 };
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try write(std.testing.allocator, std.testing.io, temporary.dir, definition);
    var restored = try read(std.testing.allocator, std.testing.io, temporary.dir, definition.id);
    defer restored.deinit();
    try std.testing.expectEqualDeep(definition, restored.value);
    try std.testing.expect(restored.value.tuning.powertrain.forward_gears.ptr != definition.tuning.powertrain.forward_gears.ptr);
    try std.testing.expectEqual(try definition.digest(std.testing.allocator), try restored.value.digest(std.testing.allocator));
    const bytes = try encode(std.testing.allocator, definition);
    defer std.testing.allocator.free(bytes);
    bytes[bytes.len - 1] ^= 1;
    try std.testing.expectError(error.VehicleAssetDigestMismatch, decode(std.testing.allocator, bytes));
}

test "vehicle asset rejects unresolved visual dependencies and nonmonotonic torque" {
    var definition = validationFixture();
    try std.testing.expectError(error.VehicleMeshMissing, definition.validateCatalog(&.{}));
    definition.tuning.powertrain.torque_curve = &.{ .{ .rpm_fraction = 1, .torque_fraction = 1 }, .{ .rpm_fraction = 0, .torque_fraction = 1 } };
    try std.testing.expectError(error.InvalidVehicleTorqueCurve, definition.validate());
}
