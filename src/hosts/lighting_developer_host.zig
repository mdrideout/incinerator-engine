//! Explicit-root disk adapter and typed request sink for game lighting.
const std = @import("std");
const engine = @import("engine_contracts");
const content = @import("content");
const contract = @import("lighting_authoring_contract");
const authoring = @import("lighting_authoring");
pub const Host = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    directory: std.Io.Dir,
    root: content.ContentRootPath,
    owner: authoring.Owner,
    requests: contract.Requests,
    evidence: std.ArrayList(contract.Evidence) = .empty,
    projection: std.ArrayList(engine.assets.Entry) = .empty,
    persistence_available: bool = false,
    installed_root: ?content.ContentRootPath = null,
    dependencies: std.ArrayList(engine.assets.AssetId) = .empty,

    pub fn init(io: std.Io, allocator: std.mem.Allocator, root: content.ContentRootPath, catalog: []const engine.assets.Entry, world_catalog: []const engine.assets.Entry, vehicle_ids: []const engine.assets.AssetId) !Host {
        var directory = try std.Io.Dir.openDirAbsolute(io, root.bytes(), .{});
        errdefer directory.close(io);
        var initial = try content.lighting_library.read(allocator, io, directory);
        defer initial.deinit();
        try initial.value.validateVehicleMounts(vehicle_ids);
        const combined = try allocator.alloc(engine.assets.Entry, catalog.len + world_catalog.len);
        defer allocator.free(combined);
        @memcpy(combined[0..catalog.len], catalog);
        @memcpy(combined[catalog.len..], world_catalog);
        return .{ .io = io, .allocator = allocator, .directory = directory, .root = root, .owner = try authoring.Owner.init(allocator, initial.value, combined), .requests = .{ .allocator = allocator } };
    }
    pub fn deinit(self: *Host) void {
        self.owner.deinit();
        self.requests.deinit();
        self.evidence.deinit(self.allocator);
        self.projection.deinit(self.allocator);
        self.dependencies.deinit(self.allocator);
        self.directory.close(self.io);
    }
    pub fn input(self: *Host) contract.Input {
        return .{ .view = self.view(), .requests = &self.requests };
    }
    pub fn view(self: *const Host) contract.View {
        return .{ .records = self.owner.records, .active_environment = self.owner.active_environment, .library_revision = self.owner.library_revision, .last_ui_outcome = self.owner.last_ui_outcome, .persistence_available = self.persistence_available, .installed_root = (self.installed_root orelse self.root).bytes(), .project_root = if (self.persistence_available) self.root.bytes() else null };
    }
    pub fn execute(self: *Host, source: engine.authoring.Source, request: contract.Request) !contract.Outcome {
        try self.evidence.ensureUnusedCapacity(self.allocator, 1);
        const before = self.owner.inspect(request.target);
        const result = try self.owner.execute(source, request, if (self.persistence_available) .{ .context = self, .write_fn = write } else null);
        self.evidence.appendAssumeCapacity(.{ .request = request, .outcome = result, .before = before, .after = self.owner.inspect(request.target), .active_environment = self.owner.active_environment });
        return result;
    }
    pub fn pump(self: *Host) !void {
        defer self.requests.pending.clearRetainingCapacity();
        for (self.requests.pending.items) |request| _ = try self.execute(.ui, request);
    }
    pub fn contentAssets(self: *Host, other: []const engine.assets.Entry) ![]const engine.assets.Entry {
        self.projection.clearRetainingCapacity();
        self.dependencies.clearRetainingCapacity();
        var required: usize = 0;
        for (self.owner.records) |record| if (record.session == .fixture) {
            const fixture = record.session.fixture;
            required += @as(usize, @intFromBool(fixture.visual != null)) * 2 + @as(usize, @intFromBool(fixture.surface != null));
        };
        try self.dependencies.ensureTotalCapacity(self.allocator, required);
        try self.projection.appendSlice(self.allocator, other);
        for (self.owner.records) |record| {
            const bytes = try std.json.Stringify.valueAlloc(self.allocator, record.session, .{});
            defer self.allocator.free(bytes);
            var digest: engine.assets.Digest = undefined;
            std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
            const start = self.dependencies.items.len;
            if (record.session == .fixture) {
                const fixture = record.session.fixture;
                if (fixture.visual) |visual| self.dependencies.appendSliceAssumeCapacity(&.{ visual.mesh, visual.material });
                if (fixture.surface) |surface| self.dependencies.appendAssumeCapacity(surface.mesh);
            }
            try self.projection.append(self.allocator, .{ .id = record.id, .kind = .lighting, .owner = .game, .label = record.label, .bundle_key = "lighting/industrial", .revision = record.revision, .digest = digest, .dependencies = self.dependencies.items[start..], .source_format = .authored, .cook_status = .valid, .residency = .resident, .last_use_frame = null, .details = .lighting });
        }
        return self.projection.items;
    }
    fn write(context: *anyopaque, value: content.lighting_library.Library) !void {
        const self: *Host = @ptrCast(@alignCast(context));
        try content.lighting_library.write(self.allocator, self.io, self.directory, value);
    }
};
