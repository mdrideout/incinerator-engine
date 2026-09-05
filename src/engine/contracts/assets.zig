//! Stable durable asset identity shared by runtime content and authoring.
//!
//! Asset identity is deliberately nominally distinct from persistent entity
//! identity. It never contains a source path, runtime handle, pointer, or
//! backend resource identifier.

const std = @import("std");

pub const Digest = [32]u8;

/// Stable namespace for game-owned cooked assets in the current title. The
/// local component is derived from the cooked semantic key, never a path or a
/// renderer handle.
pub const game_asset_namespace: u64 = 0x494e_4349_4e45_5241;

pub const Kind = enum(u8) {
    scene,
    mesh,
    material,
    texture,
};

pub const Owner = enum(u8) {
    engine,
    game,
};

pub const SourceFormat = enum(u8) {
    gltf,
    glb,
};

pub const CookStatus = enum(u8) {
    valid,
    invalid,
};

pub const Residency = enum(u8) {
    not_resident,
    resident,
};

pub const ColorSpace = enum(u8) {
    linear,
    srgb,
};

pub const ImageEncoding = enum(u8) {
    png,
    jpeg,
};

pub const Filter = enum(u8) {
    nearest,
    linear,
};

pub const AddressMode = enum(u8) {
    clamp_to_edge,
    mirrored_repeat,
    repeat,
};

pub const Sampler = struct {
    min_filter: Filter = .linear,
    mag_filter: Filter = .linear,
    address_u: AddressMode = .repeat,
    address_v: AddressMode = .repeat,

    pub fn validate(self: Sampler) !void {
        _ = self;
    }
};

pub const TextureMetadata = struct {
    width: u32,
    height: u32,
    color_space: ColorSpace,
    encoding: ImageEncoding,
    sampler: Sampler,
};

pub const MaterialMetadata = struct {
    base_color: [4]f32,
    base_color_texture: ?AssetId,
    base_color_texcoord: u8,
};

pub const Details = union(enum) {
    scene,
    mesh,
    material: MaterialMetadata,
    texture: TextureMetadata,
};

/// Immutable cooked-content projection shared by editor UI and developer
/// clients. Source provenance is descriptive; identity is only `id`.
pub const Entry = struct {
    id: AssetId,
    kind: Kind,
    owner: Owner,
    label: []const u8,
    bundle_key: []const u8,
    revision: u64,
    digest: Digest,
    dependencies: []const AssetId,
    source_format: SourceFormat,
    cook_status: CookStatus,
    residency: Residency,
    last_use_frame: ?u64,
    details: Details,

    pub fn validate(self: Entry) !void {
        try self.id.validate();
        try validateDigest(self.digest);
        if (self.label.len == 0 or self.bundle_key.len == 0 or self.revision == 0) {
            return error.InvalidAssetEntry;
        }
        if (@intFromEnum(self.kind) != @intFromEnum(std.meta.activeTag(self.details))) {
            return error.AssetDetailKindMismatch;
        }
        for (self.dependencies) |dependency| try dependency.validate();
        switch (self.details) {
            .scene, .mesh => {},
            .material => |material| {
                for (material.base_color) |component| {
                    if (!std.math.isFinite(component) or component < 0 or component > 1) {
                        return error.InvalidMaterialMetadata;
                    }
                }
                if (material.base_color_texture) |texture| try texture.validate();
            },
            .texture => |texture| {
                if (texture.width == 0 or texture.height == 0) {
                    return error.InvalidTextureMetadata;
                }
                try texture.sampler.validate();
            },
        }
    }
};

pub const AssetId = struct {
    namespace: u64,
    local: u64,

    pub fn validate(self: AssetId) !void {
        if (self.namespace == 0) return error.InvalidAssetNamespace;
        if (self.local == 0) return error.InvalidAssetLocal;
    }
};

pub fn validateDigest(digest: Digest) !void {
    for (digest) |byte| if (byte != 0) return;
    return error.InvalidAssetDigest;
}

/// Derive a title-owned stable identity from cooked semantic names. The
/// source path, source bytes, revision digest, and runtime residency do not
/// participate, so a repeated cook or relocation preserves identity.
pub fn deriveGameAssetId(kind: Kind, bundle_key: []const u8, label: []const u8) !AssetId {
    if (bundle_key.len == 0 or label.len == 0 or
        !std.unicode.utf8ValidateSlice(bundle_key) or
        !std.unicode.utf8ValidateSlice(label))
    {
        return error.InvalidAssetSemanticKey;
    }
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("incinerator.game.asset.identity.v1");
    hash.update(&.{@intFromEnum(kind)});
    hashLengthAndBytes(&hash, bundle_key);
    hashLengthAndBytes(&hash, label);
    var digest: Digest = undefined;
    hash.final(&digest);
    var local = std.mem.readInt(u64, digest[0..8], .little);
    if (local == 0) local = 1;
    return .{ .namespace = game_asset_namespace, .local = local };
}

fn hashLengthAndBytes(hash: *std.crypto.hash.sha2.Sha256, value: []const u8) void {
    var length: [4]u8 = undefined;
    std.mem.writeInt(u32, &length, @intCast(value.len), .little);
    hash.update(&length);
    hash.update(value);
}

test "asset identity is validated independently from paths and handles" {
    const id = AssetId{ .namespace = 0x4741_4d45, .local = 7 };
    try id.validate();
    try std.testing.expectError(
        error.InvalidAssetNamespace,
        (AssetId{ .namespace = 0, .local = 7 }).validate(),
    );
    try std.testing.expectError(
        error.InvalidAssetLocal,
        (AssetId{ .namespace = 9, .local = 0 }).validate(),
    );
    try std.testing.expect(!@hasField(AssetId, "path"));
    try std.testing.expect(!@hasField(AssetId, "handle"));
}

test "asset digest rejects the absent all-zero value" {
    try std.testing.expectError(error.InvalidAssetDigest, validateDigest(@splat(0)));
    var digest: Digest = @splat(0);
    digest[31] = 1;
    try validateDigest(digest);
}

test "derived game asset identity is stable across revisions and separates kinds" {
    const material = try deriveGameAssetId(.material, "district/southwest", "Facade");
    const repeated = try deriveGameAssetId(.material, "district/southwest", "Facade");
    const texture = try deriveGameAssetId(.texture, "district/southwest", "Facade");
    try std.testing.expectEqual(material, repeated);
    try std.testing.expect(!std.meta.eql(material, texture));
    try std.testing.expectEqual(game_asset_namespace, material.namespace);
}

test "asset entry keeps identity independent from residency and source format" {
    var digest: Digest = @splat(0);
    digest[0] = 1;
    const id = try deriveGameAssetId(.texture, "project/cargo", "Panels");
    var entry = Entry{
        .id = id,
        .kind = .texture,
        .owner = .game,
        .label = "Panels",
        .bundle_key = "project/cargo",
        .revision = 1,
        .digest = digest,
        .dependencies = &.{},
        .source_format = .gltf,
        .cook_status = .valid,
        .residency = .not_resident,
        .last_use_frame = null,
        .details = .{ .texture = .{
            .width = 128,
            .height = 128,
            .color_space = .srgb,
            .encoding = .jpeg,
            .sampler = .{ .address_u = .clamp_to_edge },
        } },
    };
    try entry.validate();
    entry.residency = .resident;
    entry.source_format = .glb;
    try entry.validate();
    try std.testing.expectEqual(id, entry.id);
}
