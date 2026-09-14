//! The title's sole mutable lighting owner. Publication happens at a frame boundary.
const std = @import("std");
const engine = @import("engine_contracts");
const contract = @import("lighting_authoring_contract");
const library = contract.library;
pub const Store = struct {
    context: *anyopaque,
    write_fn: *const fn (*anyopaque, library.Library) anyerror!void,
};
const History = struct { target: engine.assets.AssetId, before: contract.Value, after: contract.Value };
pub const Owner = struct {
    allocator: std.mem.Allocator,
    records: []contract.Record,
    catalog: []library.Reference,
    active_environment: engine.assets.AssetId,
    committed_environment: engine.assets.AssetId,
    library_revision: u64,
    next_transaction: u64 = 1,
    last_ui_outcome: ?contract.Outcome = null,
    undo_stack: std.ArrayList(History) = .empty,
    redo_stack: std.ArrayList(History) = .empty,

    pub fn init(allocator: std.mem.Allocator, initial: library.Library, catalog: []const engine.assets.Entry) !Owner {
        try initial.validate();
        const references = try allocator.alloc(library.Reference, catalog.len);
        errdefer allocator.free(references);
        for (catalog, references) |entry, *reference| reference.* = .{ .id = entry.id, .kind = entry.kind, .mountable = std.mem.startsWith(u8, entry.bundle_key, "vehicle/") };
        for (initial.definitions) |definition| try library.validateReferences(definition.value, references);
        const records = try allocator.alloc(contract.Record, initial.definitions.len);
        errdefer allocator.free(records);
        var initialized: usize = 0;
        errdefer for (records[0..initialized]) |record| allocator.free(record.label);
        for (initial.definitions, records) |definition, *record| {
            record.* = .{ .id = definition.id, .label = try allocator.dupe(u8, definition.label), .revision = definition.revision, .asset_revision = definition.revision, .committed = definition.value, .session = definition.value };
            initialized += 1;
        }
        return .{ .allocator = allocator, .records = records, .catalog = references, .active_environment = initial.active_environment, .committed_environment = initial.active_environment, .library_revision = initial.revision };
    }
    pub fn deinit(self: *Owner) void {
        for (self.records) |record| self.allocator.free(record.label);
        self.allocator.free(self.records);
        self.allocator.free(self.catalog);
        self.undo_stack.deinit(self.allocator);
        self.redo_stack.deinit(self.allocator);
    }
    pub fn find(self: *const Owner, id: engine.assets.AssetId) ?*const contract.Record {
        for (self.records) |*record| if (std.meta.eql(id, record.id)) return record;
        return null;
    }
    pub fn inspect(self: *const Owner, id: engine.assets.AssetId) ?contract.Record {
        return if (self.find(id)) |record| record.* else null;
    }
    pub fn execute(self: *Owner, source: engine.authoring.Source, request: contract.Request, store: ?Store) !contract.Outcome {
        const transaction = self.next_transaction;
        self.next_transaction = try std.math.add(u64, transaction, 1);
        var result = contract.Outcome{ .transaction_id = transaction, .source = source, .target = request.target, .action = std.meta.activeTag(request.action), .revision = 0, .asset_revision = 0, .library_revision = self.library_revision, .rejection = .target_missing };
        for (self.records) |*record| if (std.meta.eql(record.id, request.target)) {
            result.rejection = try self.perform(record, source, request, store);
            result.revision = record.revision;
            result.asset_revision = record.asset_revision;
            result.library_revision = self.library_revision;
            break;
        };
        if (source == .ui) self.last_ui_outcome = result;
        return result;
    }
    fn perform(self: *Owner, record: *contract.Record, source: engine.authoring.Source, request: contract.Request, store: ?Store) !?contract.Rejection {
        if (record.revision != request.expected_revision) return .stale_revision;
        if (record.preview) |preview| if (preview.source != source) return .preview_owned_by_another_producer;
        switch (request.action) {
            .preview, .apply => |value| {
                if (std.meta.activeTag(value) != std.meta.activeTag(record.session)) return .wrong_value_kind;
                value.validate() catch return .invalid_value;
                if (value == .fixture and value.fixture.mount == .vehicle_asset) {
                    var admitted_parent = false;
                    for (self.records) |candidate| if (candidate.committed == .fixture and candidate.committed.fixture.mount == .vehicle_asset and std.meta.eql(candidate.committed.fixture.mount.vehicle_asset, value.fixture.mount.vehicle_asset)) {
                        admitted_parent = true;
                        break;
                    };
                    if (!admitted_parent) return .invalid_value;
                }
                library.validateReferences(value, self.catalog) catch return .invalid_value;
                if (value == .fixture) if (value.fixture.surface) |surface| {
                    for (self.records) |candidate| {
                        if (std.meta.eql(candidate.id, record.id) or candidate.presented() != .fixture) continue;
                        if (candidate.presented().fixture.surface) |other| if (std.meta.eql(surface.mesh, other.mesh)) return .invalid_value;
                    }
                };
                if (request.action == .preview) {
                    record.preview = .{ .source = source, .value = value };
                } else try self.publish(record, value);
            },
            .clear_preview => record.preview = null,
            .revert => try self.publish(record, record.committed),
            .undo, .redo => {
                const undo = request.action == .undo;
                const from = if (undo) &self.undo_stack else &self.redo_stack;
                const to = if (undo) &self.redo_stack else &self.undo_stack;
                var index = from.items.len;
                while (index > 0) {
                    index -= 1;
                    if (!std.meta.eql(from.items[index].target, record.id)) continue;
                    const revision = try std.math.add(u64, record.revision, 1);
                    try to.append(self.allocator, from.items[index]);
                    const entry = from.orderedRemove(index);
                    record.session = if (undo) entry.before else entry.after;
                    record.preview = null;
                    record.revision = revision;
                    return null;
                }
                return if (undo) .nothing_to_undo else .nothing_to_redo;
            },
            .activate => {
                if (record.session != .environment) return .wrong_value_kind;
                self.active_environment = record.id;
            },
            .commit => {
                const destination = store orelse return .persistence_unavailable;
                const revision = try std.math.add(u64, self.library_revision, 1);
                const definitions = try self.allocator.alloc(library.Definition, self.records.len);
                defer self.allocator.free(definitions);
                for (self.records, definitions) |other, *definition| {
                    const target = std.meta.eql(other.id, record.id);
                    definition.* = .{ .id = other.id, .label = other.label, .revision = if (target) record.revision else other.asset_revision, .value = if (target) record.session else other.committed };
                }
                destination.write_fn(destination.context, .{ .revision = revision, .active_environment = self.active_environment, .definitions = definitions }) catch return .persistence_failed;
                record.committed = record.session;
                record.asset_revision = record.revision;
                self.committed_environment = self.active_environment;
                self.library_revision = revision;
            },
        }
        return null;
    }
    fn publish(self: *Owner, record: *contract.Record, value: contract.Value) !void {
        const revision = try std.math.add(u64, record.revision, 1);
        try self.undo_stack.append(self.allocator, .{ .target = record.id, .before = record.session, .after = value });
        // Only this target's redo lineage is invalidated by a new edit.
        var index = self.redo_stack.items.len;
        while (index > 0) {
            index -= 1;
            if (std.meta.eql(self.redo_stack.items[index].target, record.id)) _ = self.redo_stack.orderedRemove(index);
        }
        record.session = value;
        record.preview = null;
        record.revision = revision;
    }
};

test "lighting preview isolation, stale rejection, history, durable restart, and failed persistence" {
    const allocator = std.testing.allocator;
    const id = engine.assets.AssetId{ .namespace = 100, .local = 1 };
    const initial = library.Library{ .revision = 1, .active_environment = id, .definitions = &.{.{ .id = id, .label = "Dusk", .revision = 1, .value = .{ .environment = .{} } }} };
    var owner = try Owner.init(allocator, initial, &.{});
    defer owner.deinit();
    var value = initial.definitions[0].value;
    value.environment.display.exposure = 0.02;
    const preview = try owner.execute(.ui, .{ .target = id, .expected_revision = 1, .action = .{ .preview = value } }, null);
    try std.testing.expect(preview.rejection == null);
    try std.testing.expectEqualDeep(initial.definitions[0].value, owner.find(id).?.session);
    try std.testing.expectEqualDeep(value, owner.find(id).?.presented());
    try std.testing.expectEqual(contract.Rejection.preview_owned_by_another_producer, (try owner.execute(.local_developer_client, .{ .target = id, .expected_revision = 1, .action = .{ .apply = value } }, null)).rejection.?);
    try std.testing.expect((try owner.execute(.ui, .{ .target = id, .expected_revision = 1, .action = .{ .apply = value } }, null)).rejection == null);
    try std.testing.expectEqual(contract.Rejection.stale_revision, (try owner.execute(.ui, .{ .target = id, .expected_revision = 1, .action = .revert }, null)).rejection.?);
    try std.testing.expect((try owner.execute(.local_developer_client, .{ .target = id, .expected_revision = 2, .action = .undo }, null)).rejection == null);
    try std.testing.expectEqualDeep(initial.definitions[0].value, owner.find(id).?.session);
    try std.testing.expect((try owner.execute(.local_developer_client, .{ .target = id, .expected_revision = 3, .action = .redo }, null)).rejection == null);
    try std.testing.expectEqualDeep(value, owner.find(id).?.session);
    const Disk = struct {
        directory: std.Io.Dir,
        fail: bool = false,
        fn write(context: *anyopaque, data: library.Library) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (self.fail) return error.InjectedDiskFailure;
            try library.write(std.testing.allocator, std.testing.io, self.directory, data);
        }
    };
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var disk = Disk{ .directory = temporary.dir, .fail = true };
    const store = Store{ .context = &disk, .write_fn = Disk.write };
    try std.testing.expectEqual(contract.Rejection.persistence_failed, (try owner.execute(.ui, .{ .target = id, .expected_revision = 4, .action = .commit }, store)).rejection.?);
    try std.testing.expectEqual(@as(u64, 1), owner.library_revision);
    try std.testing.expectEqualDeep(initial.definitions[0].value, owner.find(id).?.committed);
    disk.fail = false;
    try std.testing.expect((try owner.execute(.ui, .{ .target = id, .expected_revision = 4, .action = .commit }, store)).rejection == null);
    var restored = try library.read(allocator, std.testing.io, temporary.dir);
    defer restored.deinit();
    var restarted = try Owner.init(allocator, restored.value, &.{});
    defer restarted.deinit();
    try std.testing.expectEqualDeep(value, restarted.find(id).?.session);
    try std.testing.expectEqual(@as(u64, 4), restarted.find(id).?.revision);
    const bytes = try library.encode(allocator, restored.value);
    defer allocator.free(bytes);
    bytes[bytes.len - 1] ^= 1;
    try std.testing.expectError(error.LightingLibraryDigestMismatch, library.decode(allocator, bytes));
}
