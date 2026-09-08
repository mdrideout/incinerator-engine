//! Canonical game-owned material asset library. The envelope is the editable
//! durable asset and the runtime representation: no glTF paths or importer
//! state enter it. Edits replace this one complete revision atomically.
const std = @import("std");
const assets = @import("engine_contracts").assets;

pub const filename = "materials.icmat";
pub const format_version: u32 = 1;
const magic = "ICMATLIB";
const header_bytes = 52;

pub const Definition = struct {
    id: assets.AssetId,
    label: []const u8,
    revision: u64,
    value: assets.MaterialMetadata,
};

pub const Binding = struct {
    mesh: assets.AssetId,
    material: assets.AssetId,
    revision: u64,
};

pub const Library = struct {
    materials: []const Definition,
    bindings: []const Binding,

    pub fn validate(self: Library) !void {
        for (self.materials, 0..) |entry, index| {
            try entry.id.validate();
            try entry.value.validate();
            if (entry.label.len == 0 or !std.unicode.utf8ValidateSlice(entry.label) or entry.revision == 0) return error.InvalidMaterialDefinition;
            for (self.materials[0..index]) |other| {
                if (std.meta.eql(entry.id, other.id)) return error.DuplicateMaterialId;
            }
        }
        for (self.bindings, 0..) |binding, index| {
            try binding.mesh.validate();
            if (binding.revision == 0 or self.find(binding.material) == null) return error.InvalidMaterialBinding;
            for (self.bindings[0..index]) |other| {
                if (std.meta.eql(binding.mesh, other.mesh)) return error.DuplicateMeshBinding;
            }
        }
    }

    pub fn validateCatalog(self: Library, catalog: []const assets.Entry) !void {
        for (self.materials) |definition| try validateTextureAssets(definition.value, catalog);
        for (self.bindings) |binding| {
            var found = false;
            for (catalog) |entry| if (entry.kind == .mesh and std.meta.eql(entry.id, binding.mesh)) {
                found = true;
                break;
            };
            if (!found) return error.MaterialBindingMeshMissing;
        }
    }

    pub fn find(self: Library, id: assets.AssetId) ?Definition {
        for (self.materials) |entry| if (std.meta.eql(entry.id, id)) return entry;
        return null;
    }
};

pub fn validateTextureAssets(value: assets.MaterialMetadata, catalog: []const assets.Entry) !void {
    inline for (.{ "base_color", "metallic_roughness", "normal", "occlusion", "emissive" }) |slot| {
        if (@field(value, slot ++ "_texture")) |id| {
            const color_space: assets.ColorSpace = if (comptime std.mem.eql(u8, slot, "base_color") or std.mem.eql(u8, slot, "emissive")) .srgb else .linear;
            var found = false;
            for (catalog) |entry| if (entry.kind == .texture and std.meta.eql(entry.id, id)) {
                if (entry.details.texture.color_space != color_space) return error.MaterialTextureColorSpace;
                found = true;
                break;
            };
            if (!found) return error.MaterialTextureMissing;
        }
    }
}

test "runtime material admission rejects a missing texture instead of losing its map" {
    const value = assets.MaterialMetadata{ .base_color = .{ 1, 1, 1, 1 }, .base_color_texture = .{ .namespace = 1, .local = 1 }, .base_color_texcoord = 0 };
    try std.testing.expectError(error.MaterialTextureMissing, validateTextureAssets(value, &.{}));
}

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
    if (bytes.len < header_bytes or !std.mem.eql(u8, bytes[0..8], magic)) return error.InvalidMaterialLibrary;
    if (std.mem.readInt(u32, bytes[8..12], .little) != format_version) return error.MaterialLibraryVersionMismatch;
    if (std.mem.readInt(u64, bytes[12..20], .little) != bytes.len - header_bytes) return error.MaterialLibrarySizeMismatch;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes[header_bytes..], &digest, .{});
    if (!std.mem.eql(u8, &digest, bytes[20..52])) return error.MaterialLibraryDigestMismatch;
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

test "material asset durable round trip retains exact values and detects corruption" {
    const id = try assets.deriveGameAssetId(.material, "materials", "PaintedSteel");
    const definitions = [_]Definition{.{ .id = id, .label = "Painted steel", .revision = 7, .value = .{ .base_color = .{ 0.1, 0.2, 0.4, 1 }, .base_color_texture = null, .base_color_texcoord = 0, .metallic = 0.8, .roughness = 0.35 } }};
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const library = Library{ .materials = &definitions, .bindings = &.{} };
    try write(std.testing.allocator, std.testing.io, temporary.dir, library);
    var restored = try read(std.testing.allocator, std.testing.io, temporary.dir);
    defer restored.deinit();
    try std.testing.expectEqualDeep(definitions[0], restored.value.materials[0]);
    const bytes = try encode(std.testing.allocator, library);
    defer std.testing.allocator.free(bytes);
    bytes[bytes.len - 1] ^= 1;
    try std.testing.expectError(error.MaterialLibraryDigestMismatch, decode(std.testing.allocator, bytes));
}
