//! Game lighting assets consumed from an explicit installed content root.
//! Fixtures and parent rules belong to content; the renderer sees only emitters.
const std = @import("std");
const engine = @import("engine_contracts");
const assets = engine.assets;
pub const filename = "lighting.iclight";
pub const format_version: u32 = 1;
const magic = "ICLIGHTS";
const header_bytes = 52;

pub const Mount = union(enum) {
    world,
    /// One local mount on every presented instance of this vehicle definition.
    vehicle_asset: assets.AssetId,
    carryable,
};
pub const Visual = struct {
    mesh: assets.AssetId,
    material: assets.AssetId,
    local_pose: engine.Pose = .{},
    scale: [3]f32,
    emissive_scale: f32 = 1,
    pub fn validate(self: Visual) !void {
        try self.mesh.validate();
        try self.material.validate();
        _ = try self.local_pose.normalized();
        for (self.scale) |value| if (!std.math.isFinite(value) or value <= 0) return error.InvalidLightingVisualScale;
        if (!std.math.isFinite(self.emissive_scale) or self.emissive_scale < 0) return error.InvalidLightingEmissionScale;
    }
};
/// Emission override on an existing cooked surface, without copying its material.
pub const Reference = struct { id: assets.AssetId, kind: assets.Kind, mountable: bool = true };
pub fn validateReferences(value: Value, catalog: []const Reference) !void {
    if (value != .fixture) return;
    const fixture = value.fixture;
    if (fixture.surface) |surface| try requireReference(catalog, surface.mesh, .mesh, false);
    if (fixture.visual) |visual| {
        try requireReference(catalog, visual.mesh, .mesh, true);
        try requireReference(catalog, visual.material, .material, true);
    }
}
fn requireReference(catalog: []const Reference, id: assets.AssetId, kind: assets.Kind, mountable: bool) !void {
    for (catalog) |entry| if (entry.kind == kind and std.meta.eql(entry.id, id) and (!mountable or entry.mountable)) return;
    return error.LightingVisualAssetMissing;
}
pub const Surface = struct { mesh: assets.AssetId, emissive_scale: f32 = 1 };
pub const Fixture = struct {
    light: engine.lighting.Light,
    pose: engine.Pose = .{},
    mount: Mount = .world,
    visual: ?Visual = null,
    surface: ?Surface = null,
    /// Presets can disable exterior artificial lights without changing assets.
    follows_night: bool = true,

    pub fn validate(self: Fixture) !void {
        try self.light.validate();
        if (self.visual) |visual| try visual.validate();
        if (self.surface) |surface| {
            try surface.mesh.validate();
            if (!std.math.isFinite(surface.emissive_scale) or surface.emissive_scale < 0) return error.InvalidLightingEmissionScale;
        }
        _ = try self.pose.normalized();
        switch (self.mount) {
            .vehicle_asset => |id| try id.validate(),
            .world, .carryable => {},
        }
    }
};
pub const Value = union(enum) {
    environment: engine.lighting.Environment,
    fixture: Fixture,
    pub fn validate(self: Value) !void {
        switch (self) {
            .environment => |value| try value.validate(),
            .fixture => |value| try value.validate(),
        }
    }
};
pub const Definition = struct { id: assets.AssetId, label: []const u8, revision: u64, value: Value };
pub const Library = struct {
    revision: u64,
    active_environment: assets.AssetId,
    definitions: []const Definition,

    pub fn find(self: Library, id: assets.AssetId) ?Definition {
        for (self.definitions) |definition| if (std.meta.eql(id, definition.id)) return definition;
        return null;
    }
    pub fn validateCatalog(self: Library, allocator: std.mem.Allocator, catalogs: []const []const assets.Entry) !void {
        var count: usize = 0;
        for (catalogs) |catalog| count += catalog.len;
        const references = try allocator.alloc(Reference, count);
        defer allocator.free(references);
        var index: usize = 0;
        for (catalogs) |catalog| for (catalog) |entry| {
            references[index] = .{ .id = entry.id, .kind = entry.kind, .mountable = std.mem.startsWith(u8, entry.bundle_key, "vehicle/") };
            index += 1;
        };
        for (self.definitions) |definition| try validateReferences(definition.value, references);
    }
    pub fn validateVehicleMounts(self: Library, admitted_vehicles: []const assets.AssetId) !void {
        for (self.definitions) |definition| {
            if (definition.value != .fixture) continue;
            const mount = definition.value.fixture.mount;
            if (mount != .vehicle_asset) continue;
            var admitted = false;
            for (admitted_vehicles) |id| if (std.meta.eql(id, mount.vehicle_asset)) {
                admitted = true;
                break;
            };
            if (!admitted) return error.LightingVehicleAssetMissing;
        }
    }
    pub fn validate(self: Library) !void {
        if (self.revision == 0) return error.InvalidLightingLibraryRevision;
        for (self.definitions, 0..) |definition, index| {
            try definition.id.validate();
            try definition.value.validate();
            if (definition.revision == 0 or definition.label.len == 0 or !std.unicode.utf8ValidateSlice(definition.label)) return error.InvalidLightingDefinition;
            for (self.definitions[0..index]) |other| {
                if (std.meta.eql(other.id, definition.id)) return error.DuplicateLightingIdentity;
                if (definition.value == .fixture and other.value == .fixture) if (definition.value.fixture.surface) |surface| if (other.value.fixture.surface) |previous| if (std.meta.eql(surface.mesh, previous.mesh)) return error.DuplicateLightingSurfaceOwner;
            }
        }
        const active = self.find(self.active_environment) orelse return error.MissingLightingEnvironment;
        if (active.value != .environment) return error.InvalidLightingEnvironment;
    }
};

pub fn encode(allocator: std.mem.Allocator, library: Library) ![]u8 {
    try library.validate();
    const payload = try std.json.Stringify.valueAlloc(allocator, library, .{});
    defer allocator.free(payload);
    const bytes = try allocator.alloc(u8, header_bytes + payload.len);
    @memcpy(bytes[0..8], magic);
    std.mem.writeInt(u32, bytes[8..12], format_version, .little);
    std.mem.writeInt(u64, bytes[12..20], payload.len, .little);
    std.crypto.hash.sha2.Sha256.hash(payload, bytes[20..52], .{});
    @memcpy(bytes[header_bytes..], payload);
    return bytes;
}

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Library) {
    if (bytes.len < header_bytes or !std.mem.eql(u8, bytes[0..8], magic)) return error.InvalidLightingLibrary;
    if (std.mem.readInt(u32, bytes[8..12], .little) != format_version) return error.LightingLibraryVersionMismatch;
    if (std.mem.readInt(u64, bytes[12..20], .little) != bytes.len - header_bytes) return error.LightingLibrarySizeMismatch;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes[header_bytes..], &digest, .{});
    if (!std.mem.eql(u8, &digest, bytes[20..52])) return error.LightingLibraryDigestMismatch;
    var parsed = try std.json.parseFromSlice(Library, allocator, bytes[header_bytes..], .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    try parsed.value.validate();
    return parsed;
}

pub fn read(allocator: std.mem.Allocator, io: std.Io, directory: std.Io.Dir) !std.json.Parsed(Library) {
    const bytes = try directory.readFileAlloc(io, filename, allocator, .unlimited);
    defer allocator.free(bytes);
    return decode(allocator, bytes);
}

pub fn write(allocator: std.mem.Allocator, io: std.Io, directory: std.Io.Dir, library: Library) !void {
    const bytes = try encode(allocator, library);
    defer allocator.free(bytes);
    var atomic = try directory.createFileAtomic(io, filename, .{ .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, bytes);
    try atomic.file.sync(io);
    try atomic.replace(io);
}
