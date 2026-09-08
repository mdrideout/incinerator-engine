//! Composition adapter for the demo's material owner and its explicit game
//! content directory. The renderer receives values; UI receives a request sink.
const std = @import("std");
const content = @import("content");
const engine = @import("incinerator_engine");
const authoring = @import("material_authoring");
const contract = @import("material_authoring_contract");

pub const Host = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    directory: std.Io.Dir,
    owner: authoring.Owner,
    persistence_available: bool = false,
    preview_extent: u32 = 0,
    preview_image: ?contract.PreviewImage = null,
    projection: []engine.assets.Entry,
    dependencies: [][5]engine.assets.AssetId,
    requests: contract.Requests,
    evidence: std.ArrayList(contract.Evidence) = .empty,
    preview_mode: contract.PreviewMode = .neutral,
    preview_material: ?engine.assets.AssetId = null,

    pub fn init(io: std.Io, allocator: std.mem.Allocator, root: content.ContentRootPath, catalog: []const engine.assets.Entry) !Host {
        var directory = try std.Io.Dir.openDirAbsolute(io, root.bytes(), .{});
        errdefer directory.close(io);
        var initial = try content.material_library.read(allocator, io, directory);
        defer initial.deinit();
        const projection = try allocator.dupe(engine.assets.Entry, catalog);
        errdefer allocator.free(projection);
        const dependencies = try allocator.alloc([5]engine.assets.AssetId, catalog.len);
        errdefer allocator.free(dependencies);
        return .{ .io = io, .allocator = allocator, .directory = directory, .owner = try authoring.Owner.init(allocator, initial.value, catalog), .requests = .{ .allocator = allocator }, .projection = projection, .dependencies = dependencies };
    }

    pub fn deinit(self: *Host) void {
        self.requests.deinit();
        self.evidence.deinit(self.allocator);
        self.owner.deinit();
        self.allocator.free(self.projection);
        self.allocator.free(self.dependencies);
        self.directory.close(self.io);
    }

    pub fn input(self: *Host) contract.Input {
        return .{ .preview_extent = &self.preview_extent, .preview_image = self.preview_image, .view = .{ .records = self.owner.records, .bindings = self.owner.bindings, .last_ui_outcome = self.owner.last_ui_outcome, .persistence_available = self.persistence_available }, .requests = &self.requests, .preview_mode = &self.preview_mode, .preview_material = &self.preview_material };
    }

    pub fn execute(self: *Host, source: engine.authoring.Source, request: contract.Request) !contract.Outcome {
        try self.evidence.ensureUnusedCapacity(self.allocator, 1);
        const before = self.owner.inspect(request.target);
        const outcome = try self.owner.execute(source, request, if (self.persistence_available) .{ .context = self, .write_fn = write } else null);
        self.evidence.appendAssumeCapacity(.{ .request = request, .outcome = outcome, .before = before, .after = self.owner.inspect(request.target) });
        return outcome;
    }

    pub fn pump(self: *Host) !void {
        defer self.requests.pending.clearRetainingCapacity();
        for (self.requests.pending.items) |request| _ = try self.execute(.ui, request);
    }

    /// Content inspection shows admitted session state. Disposable preview is
    /// reported separately by material.inspect and never masquerades as an asset.
    pub fn contentAssets(self: *Host, catalog: []const engine.assets.Entry) []const engine.assets.Entry {
        std.debug.assert(catalog.len == self.projection.len);
        for (catalog, self.projection, self.dependencies) |original, *entry, *dependencies| {
            entry.* = original;
            if (self.owner.find(entry.id)) |record| {
                entry.revision = record.revision;
                entry.details = .{ .material = record.session };
                entry.digest = record.session.digest();
                var count: usize = 0;
                inline for (.{ "base_color_texture", "metallic_roughness_texture", "normal_texture", "occlusion_texture", "emissive_texture" }) |slot| {
                    if (@field(record.session, slot)) |id| {
                        var duplicate = false;
                        for (dependencies[0..count]) |other| if (std.meta.eql(id, other)) {
                            duplicate = true;
                            break;
                        };
                        if (!duplicate) {
                            dependencies[count] = id;
                            count += 1;
                        }
                    }
                }
                entry.dependencies = dependencies[0..count];
            } else if (self.owner.findBinding(entry.id)) |binding| {
                entry.revision = binding.revision;
                dependencies[0] = binding.session;
                entry.dependencies = dependencies[0..1];
                var hash = std.crypto.hash.sha2.Sha256.init(.{});
                hash.update(&original.digest);
                var bytes: [16]u8 = undefined;
                std.mem.writeInt(u64, bytes[0..8], binding.session.namespace, .little);
                std.mem.writeInt(u64, bytes[8..16], binding.session.local, .little);
                hash.update(&bytes);
                hash.final(&entry.digest);
            }
        }
        return self.projection;
    }

    fn write(context: *anyopaque, library: content.material_library.Library) !void {
        const self: *Host = @ptrCast(@alignCast(context));
        try content.material_library.write(self.allocator, self.io, self.directory, library);
    }
};
