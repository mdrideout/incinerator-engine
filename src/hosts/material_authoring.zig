//! The demo game's material authoring owner. UI and local CLI are producers;
//! only this owner publishes session values or commits the game asset library.
const std = @import("std");
const engine = @import("incinerator_engine");
const library = @import("content").material_library;
const assets = engine.assets;

const contract = @import("material_authoring_contract");
pub const Action = contract.Action;
pub const Request = contract.Request;
pub const Rejection = contract.Rejection;
pub const Outcome = contract.Outcome;
pub const Preview = contract.Preview;
pub const Record = contract.Record;

pub const Store = struct {
    context: *anyopaque,
    write_fn: *const fn (*anyopaque, library.Library) anyerror!void,

    fn write(self: Store, value: library.Library) !void {
        try self.write_fn(self.context, value);
    }
};

pub const Owner = struct {
    allocator: std.mem.Allocator,
    records: []Record,
    bindings: []contract.BindingRecord,
    textures: []const assets.Entry,
    next_transaction: u64 = 1,
    last_outcome: ?Outcome = null,
    last_ui_outcome: ?Outcome = null,

    pub fn init(allocator: std.mem.Allocator, initial: library.Library, catalog: []const assets.Entry) !Owner {
        try initial.validate();
        try initial.validateCatalog(catalog);
        const records = try allocator.alloc(Record, initial.materials.len);
        errdefer allocator.free(records);
        var initialized: usize = 0;
        errdefer for (records[0..initialized]) |record| allocator.free(record.label);
        for (initial.materials, records) |definition, *record| {
            record.* = .{ .id = definition.id, .label = try allocator.dupe(u8, definition.label), .revision = definition.revision, .asset_revision = definition.revision, .committed = definition.value, .session = definition.value };
            initialized += 1;
        }
        const bindings = try allocator.alloc(contract.BindingRecord, initial.bindings.len);
        for (bindings, initial.bindings) |*binding, initial_binding| binding.* = .{ .mesh = initial_binding.mesh, .revision = initial_binding.revision, .asset_revision = initial_binding.revision, .committed = initial_binding.material, .session = initial_binding.material };
        errdefer allocator.free(bindings);
        const self = Owner{ .allocator = allocator, .records = records, .bindings = bindings, .textures = catalog };
        for (records) |record| {
            if (self.validateValue(record.session) != null) return error.InvalidInstalledMaterialLibrary;
        }
        return self;
    }

    pub fn deinit(self: *Owner) void {
        for (self.records) |record| self.allocator.free(record.label);
        self.allocator.free(self.records);
        self.allocator.free(self.bindings);
        self.* = undefined;
    }

    pub fn find(self: *const Owner, id: assets.AssetId) ?*const Record {
        for (self.records) |*record| if (std.meta.eql(record.id, id)) return record;
        return null;
    }

    pub fn findBinding(self: *const Owner, id: assets.AssetId) ?*const contract.BindingRecord {
        for (self.bindings) |*binding| if (std.meta.eql(binding.mesh, id)) return binding;
        return null;
    }

    pub fn inspect(self: *const Owner, id: assets.AssetId) ?contract.Inspection {
        if (self.find(id)) |record| return .{ .material = record.* };
        if (self.findBinding(id)) |binding| return .{ .binding = binding.* };
        return null;
    }

    fn findMut(self: *Owner, id: assets.AssetId) ?*Record {
        for (self.records) |*record| if (std.meta.eql(record.id, id)) return record;
        return null;
    }

    pub fn execute(self: *Owner, source: engine.authoring.Source, request: Request, store: ?Store) !Outcome {
        const transaction = self.next_transaction;
        self.next_transaction = try std.math.add(u64, transaction, 1);
        var result = Outcome{ .transaction_id = transaction, .source = source, .target = request.target, .action = std.meta.activeTag(request.action), .revision = 0, .asset_revision = 0 };
        if (self.findMut(request.target)) |record| {
            result.revision = record.revision;
            result.asset_revision = record.asset_revision;
            result.rejection = try self.perform(record, source, request, store);
            result.revision = record.revision;
            result.asset_revision = record.asset_revision;
        } else {
            result.rejection = .target_missing;
            for (self.bindings) |*binding| if (std.meta.eql(binding.mesh, request.target)) {
                result.rejection = try self.performBinding(binding, source, request, store);
                result.revision = binding.revision;
                result.asset_revision = binding.asset_revision;
                break;
            };
        }
        self.last_outcome = result;
        if (source == .ui) self.last_ui_outcome = result;
        return result;
    }

    fn perform(self: *Owner, record: *Record, source: engine.authoring.Source, request: Request, store: ?Store) !?Rejection {
        if (request.expected_revision != record.revision) return .stale_revision;
        if (record.preview) |preview| {
            if (preview.source != source) return .preview_owned_by_another_producer;
        }
        switch (request.action) {
            .preview, .apply => |value| if (self.validateValue(value)) |reason| return reason,
            else => {},
        }
        switch (request.action) {
            .assign, .preview_assignment => return .wrong_target_kind,
            .preview => |value| record.preview = .{ .source = source, .value = value },
            .clear_preview => record.preview = null,
            .apply => |value| {
                record.revision = try std.math.add(u64, record.revision, 1);
                record.session = value;
                record.preview = null;
            },
            .revert => {
                record.revision = try std.math.add(u64, record.revision, 1);
                record.session = record.committed;
                record.preview = null;
            },
            .commit => {
                const destination = store orelse return .persistence_unavailable;
                const next = try std.math.add(u64, record.revision, 1);
                const definitions = try self.allocator.alloc(library.Definition, self.records.len);
                defer self.allocator.free(definitions);
                for (self.records, definitions) |*entry, *definition| {
                    // Committing one asset never persists another asset's
                    // uncommitted session or preview.
                    definition.* = .{ .id = entry.id, .label = entry.label, .revision = if (entry == record) next else entry.asset_revision, .value = if (entry == record) entry.session else entry.committed };
                }
                const bindings = try self.committedBindings(null, 0);
                defer self.allocator.free(bindings);
                destination.write(.{ .materials = definitions, .bindings = bindings }) catch return .persistence_failed;
                record.revision = next;
                record.asset_revision = next;
                record.committed = record.session;
                record.preview = null;
            },
        }
        return null;
    }

    fn committedBindings(self: *const Owner, target: ?*const contract.BindingRecord, revision: u64) ![]library.Binding {
        const bindings = try self.allocator.alloc(library.Binding, self.bindings.len);
        for (self.bindings, bindings) |*entry, *binding| {
            const selected = if (target) |value| entry == value else false;
            binding.* = .{ .mesh = entry.mesh, .material = if (selected) entry.session else entry.committed, .revision = if (selected) revision else entry.asset_revision };
        }
        return bindings;
    }

    fn performBinding(self: *Owner, binding: *contract.BindingRecord, source: engine.authoring.Source, request: Request, store: ?Store) !?Rejection {
        if (request.expected_revision != binding.revision) return .stale_revision;
        if (binding.preview) |preview| if (preview.source != source) return .preview_owned_by_another_producer;
        switch (request.action) {
            .assign, .preview_assignment => |id| if (self.find(id) == null) return .material_missing,
            else => {},
        }
        switch (request.action) {
            .preview, .apply => return .wrong_target_kind,
            .preview_assignment => |id| binding.preview = .{ .source = source, .value = id },
            .clear_preview => binding.preview = null,
            .assign => |id| {
                binding.revision = try std.math.add(u64, binding.revision, 1);
                binding.session = id;
                binding.preview = null;
            },
            .revert => {
                binding.revision = try std.math.add(u64, binding.revision, 1);
                binding.session = binding.committed;
                binding.preview = null;
            },
            .commit => {
                const destination = store orelse return .persistence_unavailable;
                const next = try std.math.add(u64, binding.revision, 1);
                const bindings = try self.committedBindings(binding, next);
                defer self.allocator.free(bindings);
                const definitions = try self.allocator.alloc(library.Definition, self.records.len);
                defer self.allocator.free(definitions);
                for (self.records, definitions) |entry, *definition| definition.* = .{ .id = entry.id, .label = entry.label, .revision = entry.asset_revision, .value = entry.committed };
                destination.write(.{ .materials = definitions, .bindings = bindings }) catch return .persistence_failed;
                binding.revision = next;
                binding.asset_revision = next;
                binding.committed = binding.session;
                binding.preview = null;
            },
        }
        return null;
    }

    fn validateValue(self: *const Owner, value: assets.MaterialMetadata) ?Rejection {
        value.validate() catch return .invalid_material;
        library.validateTextureAssets(value, self.textures) catch |err| return switch (err) {
            error.MaterialTextureMissing => .texture_missing,
            error.MaterialTextureColorSpace => .texture_color_space,
        };
        return null;
    }
};

test "material preview apply conflict revert commit and restart share one owner" {
    const id = try assets.deriveGameAssetId(.material, "materials", "Steel");
    const initial = assets.MaterialMetadata{ .base_color = .{ 0.3, 0.4, 0.5, 1 }, .base_color_texture = null, .base_color_texcoord = 0 };
    const definitions = [_]library.Definition{.{ .id = id, .label = "Steel", .revision = 1, .value = initial }};
    var owner = try Owner.init(std.testing.allocator, .{ .materials = &definitions, .bindings = &.{} }, &.{});
    defer owner.deinit();
    var draft = initial;
    draft.metallic = 0.7;
    draft.roughness = 0.24;
    var outcome = try owner.execute(.ui, .{ .target = id, .expected_revision = 1, .action = .{ .preview = draft } }, null);
    try std.testing.expect(outcome.rejection == null);
    try std.testing.expectEqualDeep(initial, owner.find(id).?.session);
    try std.testing.expectEqualDeep(draft, owner.find(id).?.presented());
    outcome = try owner.execute(.local_developer_client, .{ .target = id, .expected_revision = 1, .action = .{ .apply = draft } }, null);
    try std.testing.expectEqual(Rejection.preview_owned_by_another_producer, outcome.rejection.?);
    outcome = try owner.execute(.ui, .{ .target = id, .expected_revision = 1, .action = .{ .apply = draft } }, null);
    try std.testing.expectEqual(@as(u64, 2), outcome.revision);
    outcome = try owner.execute(.local_developer_client, .{ .target = id, .expected_revision = 1, .action = .revert }, null);
    try std.testing.expectEqual(Rejection.stale_revision, outcome.rejection.?);
    try std.testing.expectEqual(@as(u64, 2), owner.last_ui_outcome.?.revision);
    outcome = try owner.execute(.ui, .{ .target = id, .expected_revision = 2, .action = .commit }, null);
    try std.testing.expectEqual(Rejection.persistence_unavailable, outcome.rejection.?);
    try std.testing.expect(owner.find(id).?.dirty());

    const Disk = struct {
        directory: std.Io.Dir,
        fn write(context: *anyopaque, value: library.Library) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            try library.write(std.testing.allocator, std.testing.io, self.directory, value);
        }
    };
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var disk = Disk{ .directory = temporary.dir };
    outcome = try owner.execute(.ui, .{ .target = id, .expected_revision = 2, .action = .commit }, .{ .context = &disk, .write_fn = Disk.write });
    try std.testing.expect(outcome.rejection == null);
    var saved = try library.read(std.testing.allocator, std.testing.io, temporary.dir);
    defer saved.deinit();
    var restarted = try Owner.init(std.testing.allocator, saved.value, &.{});
    defer restarted.deinit();
    try std.testing.expectEqualDeep(draft, restarted.find(id).?.session);
    try std.testing.expectEqual(outcome.revision, restarted.find(id).?.revision);
    try std.testing.expect(!restarted.find(id).?.dirty());
    _ = try owner.execute(.ui, .{ .target = id, .expected_revision = outcome.revision, .action = .{ .apply = initial } }, null);
    outcome = try owner.execute(.ui, .{ .target = id, .expected_revision = outcome.revision + 1, .action = .revert }, null);
    try std.testing.expect(outcome.rejection == null);
    try std.testing.expectEqualDeep(draft, owner.find(id).?.session);
}

test "mesh assignment commits only its own session state and failed persistence leaves revisions unchanged" {
    const a = try assets.deriveGameAssetId(.material, "materials", "Brick");
    const b = try assets.deriveGameAssetId(.material, "materials", "Metal");
    const mesh_id = try assets.deriveGameAssetId(.mesh, "street", "Garage");
    const value = assets.MaterialMetadata{ .base_color = .{ 1, 1, 1, 1 }, .base_color_texture = null, .base_color_texcoord = 0 };
    const definitions = [_]library.Definition{
        .{ .id = a, .label = "Brick", .revision = 1, .value = value },
        .{ .id = b, .label = "Metal", .revision = 1, .value = value },
    };
    const bindings = [_]library.Binding{.{ .mesh = mesh_id, .material = a, .revision = 1 }};
    const catalog = [_]assets.Entry{.{ .id = mesh_id, .kind = .mesh, .owner = .game, .label = "Garage", .bundle_key = "street", .revision = 1, .digest = @splat(1), .dependencies = &.{a}, .source_format = .glb, .cook_status = .valid, .residency = .not_resident, .last_use_frame = null, .details = .mesh }};
    var owner = try Owner.init(std.testing.allocator, .{ .materials = &definitions, .bindings = &bindings }, &catalog);
    defer owner.deinit();
    var dirty = value;
    dirty.roughness = 0.25;
    _ = try owner.execute(.ui, .{ .target = b, .expected_revision = 1, .action = .{ .apply = dirty } }, null);
    _ = try owner.execute(.local_developer_client, .{ .target = mesh_id, .expected_revision = 1, .action = .{ .preview_assignment = b } }, null);
    try std.testing.expectEqual(a, owner.findBinding(mesh_id).?.session);
    try std.testing.expectEqual(b, owner.findBinding(mesh_id).?.presented());
    const conflict = try owner.execute(.ui, .{ .target = mesh_id, .expected_revision = 1, .action = .{ .assign = a } }, null);
    try std.testing.expectEqual(Rejection.preview_owned_by_another_producer, conflict.rejection.?);
    _ = try owner.execute(.local_developer_client, .{ .target = mesh_id, .expected_revision = 1, .action = .{ .assign = b } }, null);
    const Disk = struct {
        directory: std.Io.Dir,
        fail: bool = true,
        fn write(context: *anyopaque, data: library.Library) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (self.fail) return error.InjectedDiskFailure;
            try library.write(std.testing.allocator, std.testing.io, self.directory, data);
        }
    };
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var disk = Disk{ .directory = temporary.dir };
    const store = Store{ .context = &disk, .write_fn = Disk.write };
    const failed = try owner.execute(.local_developer_client, .{ .target = mesh_id, .expected_revision = 2, .action = .commit }, store);
    try std.testing.expectEqual(Rejection.persistence_failed, failed.rejection.?);
    try std.testing.expectEqual(@as(u64, 2), owner.findBinding(mesh_id).?.revision);
    try std.testing.expectEqual(a, owner.findBinding(mesh_id).?.committed);
    disk.fail = false;
    _ = try owner.execute(.local_developer_client, .{ .target = mesh_id, .expected_revision = 2, .action = .commit }, store);
    var saved = try library.read(std.testing.allocator, std.testing.io, temporary.dir);
    defer saved.deinit();
    var restarted = try Owner.init(std.testing.allocator, saved.value, &catalog);
    defer restarted.deinit();
    try std.testing.expectEqual(b, restarted.findBinding(mesh_id).?.session);
    try std.testing.expectEqual(@as(u64, 3), restarted.findBinding(mesh_id).?.revision);
    try std.testing.expectEqualDeep(value, restarted.find(b).?.session);
    try std.testing.expectEqualDeep(dirty, owner.find(b).?.session);
}
