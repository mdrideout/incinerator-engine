//! Stable read-only asset projection derived from validated cooked bundles.
//!
//! Source paths and GPU handles never enter this catalog. Repeated cooks keep
//! identity when semantic bundle/name keys are unchanged; cooked digests move
//! when validated bundle content changes.

const std = @import("std");
const engine = @import("engine_contracts");
const bundle = @import("district_bundle.zig");

const assets = engine.assets;

const Name = struct { offset: u32, len: u32 };

const Draft = struct {
    id: assets.AssetId,
    kind: assets.Kind,
    label: Name,
    bundle_key: Name,
    digest: assets.Digest,
    dependency_start: u32,
    dependency_count: u32,
    source_format: assets.SourceFormat,
    details: assets.Details,
};

pub const Builder = struct {
    allocator: std.mem.Allocator,
    strings: std.ArrayListUnmanaged(u8) = .empty,
    drafts: std.ArrayListUnmanaged(Draft) = .empty,
    dependencies: std.ArrayListUnmanaged(assets.AssetId) = .empty,

    pub fn init(allocator: std.mem.Allocator) Builder {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Builder) void {
        self.dependencies.deinit(self.allocator);
        self.drafts.deinit(self.allocator);
        self.strings.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn appendBundle(
        self: *Builder,
        scene_label: []const u8,
        source: *const bundle.OwnedBundle,
    ) !void {
        const view = source.view();
        const bundle_key = view.name(view.bundle_name) orelse return error.InvalidBundleKey;
        const identity = source.bundleIdentity();

        var scene_dependencies = try self.allocator.alloc(assets.AssetId, view.meshes.len);
        defer self.allocator.free(scene_dependencies);
        for (view.meshes, 0..) |mesh, index| {
            scene_dependencies[index] = try assets.deriveGameAssetId(
                .mesh,
                bundle_key,
                view.name(mesh.name) orelse return error.InvalidAssetName,
            );
        }
        try self.append(.scene, scene_label, bundle_key, identity.integrity_digest, scene_dependencies, source, .scene);

        for (view.meshes) |mesh| {
            const label = view.name(mesh.name) orelse return error.InvalidAssetName;
            const primitives = try range(view.primitives, mesh.first_primitive, mesh.primitive_count);
            var mesh_dependencies: std.ArrayListUnmanaged(assets.AssetId) = .empty;
            defer mesh_dependencies.deinit(self.allocator);
            for (primitives) |primitive| {
                const material = view.materials[primitive.material];
                const material_label = view.name(material.name) orelse return error.InvalidAssetName;
                const id = try assets.deriveGameAssetId(.material, bundle_key, material_label);
                if (!contains(mesh_dependencies.items, id)) {
                    try mesh_dependencies.append(self.allocator, id);
                }
            }
            try self.append(.mesh, label, bundle_key, identity.integrity_digest, mesh_dependencies.items, source, .mesh);
        }

        for (view.materials) |material| {
            const label = view.name(material.name) orelse return error.InvalidAssetName;
            var material_dependencies: [1]assets.AssetId = undefined;
            const dependency_count: usize = if (material.base_color_texture == bundle.none_index)
                0
            else blk: {
                const texture = view.textures[material.base_color_texture];
                material_dependencies[0] = try assets.deriveGameAssetId(
                    .texture,
                    bundle_key,
                    view.name(texture.name) orelse return error.InvalidAssetName,
                );
                break :blk 1;
            };
            try self.append(
                .material,
                label,
                bundle_key,
                identity.integrity_digest,
                material_dependencies[0..dependency_count],
                source,
                .{ .material = .{
                    .base_color = material.base_color,
                    .base_color_texture = if (dependency_count == 0)
                        null
                    else
                        material_dependencies[0],
                    .base_color_texcoord = material.base_color_texcoord,
                } },
            );
        }

        for (view.textures) |texture| {
            const label = view.name(texture.name) orelse return error.InvalidAssetName;
            try self.append(
                .texture,
                label,
                bundle_key,
                identity.integrity_digest,
                &.{},
                source,
                .{ .texture = .{
                    .width = texture.width,
                    .height = texture.height,
                    .color_space = switch (texture.format) {
                        .rgba8_unorm => .linear,
                        .rgba8_srgb => .srgb,
                        else => return error.InvalidTextureFormat,
                    },
                    .encoding = switch (texture.encoding) {
                        .png => .png,
                        .jpeg => .jpeg,
                        else => return error.InvalidImageEncoding,
                    },
                    .sampler = .{
                        .min_filter = switch (texture.sampler.min_filter) {
                            .nearest => .nearest,
                            .linear => .linear,
                            else => return error.InvalidSampler,
                        },
                        .mag_filter = switch (texture.sampler.mag_filter) {
                            .nearest => .nearest,
                            .linear => .linear,
                            else => return error.InvalidSampler,
                        },
                        .address_u = try addressMode(texture.sampler.address_u),
                        .address_v = try addressMode(texture.sampler.address_v),
                    },
                } },
            );
        }
    }

    fn append(
        self: *Builder,
        kind: assets.Kind,
        label: []const u8,
        bundle_key: []const u8,
        bundle_digest: assets.Digest,
        dependencies: []const assets.AssetId,
        source: *const bundle.OwnedBundle,
        details: assets.Details,
    ) !void {
        const id = try assets.deriveGameAssetId(kind, bundle_key, label);
        for (self.drafts.items) |existing| {
            if (std.meta.eql(existing.id, id)) return error.DuplicateAssetIdentity;
        }
        const dependency_start = std.math.cast(u32, self.dependencies.items.len) orelse
            return error.AssetCatalogTooLarge;
        try self.dependencies.appendSlice(self.allocator, dependencies);
        try self.drafts.append(self.allocator, .{
            .id = id,
            .kind = kind,
            .label = try self.addString(label),
            .bundle_key = try self.addString(bundle_key),
            .digest = assetDigest(bundle_digest, kind, label),
            .dependency_start = dependency_start,
            .dependency_count = std.math.cast(u32, dependencies.len) orelse
                return error.AssetCatalogTooLarge,
            .source_format = switch (source.source_format) {
                .gltf => .gltf,
                .glb => .glb,
                else => return error.InvalidSourceFormat,
            },
            .details = details,
        });
    }

    fn addString(self: *Builder, value: []const u8) !Name {
        if (value.len == 0 or !std.unicode.utf8ValidateSlice(value)) {
            return error.InvalidAssetName;
        }
        const offset = std.math.cast(u32, self.strings.items.len) orelse
            return error.AssetCatalogTooLarge;
        const len = std.math.cast(u32, value.len) orelse return error.AssetCatalogTooLarge;
        try self.strings.appendSlice(self.allocator, value);
        return .{ .offset = offset, .len = len };
    }

    pub fn finish(self: *Builder) !OwnedCatalog {
        const strings = try self.strings.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(strings);
        const dependencies = try self.dependencies.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(dependencies);
        const entries = try self.allocator.alloc(assets.Entry, self.drafts.items.len);
        errdefer self.allocator.free(entries);
        for (self.drafts.items, 0..) |draft, index| {
            const dependency_end = std.math.add(
                u32,
                draft.dependency_start,
                draft.dependency_count,
            ) catch return error.InvalidAssetDependencies;
            if (dependency_end > dependencies.len) return error.InvalidAssetDependencies;
            entries[index] = .{
                .id = draft.id,
                .kind = draft.kind,
                .owner = .game,
                .label = strings[draft.label.offset..][0..draft.label.len],
                .bundle_key = strings[draft.bundle_key.offset..][0..draft.bundle_key.len],
                .revision = 1,
                .digest = draft.digest,
                .dependencies = dependencies[draft.dependency_start..dependency_end],
                .source_format = draft.source_format,
                .cook_status = .valid,
                .residency = .not_resident,
                .last_use_frame = null,
                .details = draft.details,
            };
            try entries[index].validate();
        }
        self.drafts.clearRetainingCapacity();
        return .{
            .allocator = self.allocator,
            .strings = strings,
            .dependencies = dependencies,
            .entries = entries,
        };
    }
};

pub const OwnedCatalog = struct {
    allocator: std.mem.Allocator,
    strings: []u8,
    dependencies: []assets.AssetId,
    entries: []assets.Entry,

    pub fn view(self: *const OwnedCatalog) []const assets.Entry {
        return self.entries;
    }

    pub fn deinit(self: *OwnedCatalog) void {
        self.allocator.free(self.entries);
        self.allocator.free(self.dependencies);
        self.allocator.free(self.strings);
        self.* = undefined;
    }
};

fn range(slice: anytype, first: u32, count: u32) !@TypeOf(slice) {
    const end = std.math.add(u32, first, count) catch return error.InvalidAssetRange;
    if (end > slice.len) return error.InvalidAssetRange;
    return slice[first..end];
}

fn contains(values: []const assets.AssetId, id: assets.AssetId) bool {
    for (values) |value| if (std.meta.eql(value, id)) return true;
    return false;
}

fn addressMode(value: bundle.SamplerAddressMode) !assets.AddressMode {
    return switch (value) {
        .clamp_to_edge => .clamp_to_edge,
        .mirrored_repeat => .mirrored_repeat,
        .repeat => .repeat,
        else => error.InvalidSampler,
    };
}

fn assetDigest(bundle_digest: assets.Digest, kind: assets.Kind, label: []const u8) assets.Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("incinerator.cooked.asset.digest.v1");
    hash.update(&bundle_digest);
    hash.update(&.{@intFromEnum(kind)});
    var length: [4]u8 = undefined;
    std.mem.writeInt(u32, &length, @intCast(label.len), .little);
    hash.update(&length);
    hash.update(label);
    var result: assets.Digest = undefined;
    hash.final(&result);
    return result;
}

test "asset digest is revision-sensitive while identity remains semantic" {
    var first_bundle: assets.Digest = @splat(1);
    const first = assetDigest(first_bundle, .material, "Facade");
    first_bundle[0] = 2;
    const changed = assetDigest(first_bundle, .material, "Facade");
    try std.testing.expect(!std.mem.eql(u8, &first, &changed));
    try std.testing.expectEqual(
        try assets.deriveGameAssetId(.material, "district/southwest", "Facade"),
        try assets.deriveGameAssetId(.material, "district/southwest", "Facade"),
    );
}
