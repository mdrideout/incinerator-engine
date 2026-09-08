//! Revisioned vehicle authoring session. Physics success is only the feature's tick outcome.
const std = @import("std");
const engine = @import("engine_contracts");
const contract = @import("vehicle_authoring_contract");
const vehicle = contract.vehicle;
const handling_profiles = @import("handling_profiles");
pub const Writer = struct { context: *anyopaque, write_fn: *const fn (*anyopaque, contract.Definition) anyerror!void };
pub const Transaction = struct {
    result: contract.Result,
    candidate: ?vehicle.asset.Owned = null,
    before: vehicle.asset.Owned,
    command: ?vehicle.ReconfigureVehicle = null,
    pub fn deinit(self: *Transaction) void {
        if (self.candidate) |*value| value.deinit();
        self.before.deinit();
    }
};
pub const Owner = struct {
    allocator: std.mem.Allocator,
    assets: std.ArrayList(vehicle.asset.Owned) = .empty,
    transactions: std.ArrayList(Transaction) = .empty,
    next_transaction: u64 = 1,
    last_ui_result: ?u64 = null,
    preview_transaction: ?u64 = null,
    preset_candidates: std.ArrayList(contract.HandlingPreset) = .empty,

    /// A preview contains only disposable visual bindings, scoped to one live revision.
    pub fn preview(self: *Owner, target: engine.PersistentId, revision: u64) ?vehicle.asset.Visuals {
        const tx = self.transaction(self.preview_transaction orelse return null) orelse return null;
        if (!std.meta.eql(tx.result.target, target) or tx.result.revision != revision) return null;
        return tx.candidate.?.value.visuals;
    }

    pub fn init(allocator: std.mem.Allocator, definitions: []const contract.Definition) !Owner {
        var owner = Owner{ .allocator = allocator };
        errdefer owner.deinit();
        for (definitions) |definition| {
            if (owner.findAsset(definition.id) != null) return error.DuplicateVehicleArchetype;
            var owned = try definition.clone(allocator);
            errdefer owned.deinit();
            try owner.assets.append(allocator, owned);
        }
        return owner;
    }
    pub fn deinit(self: *Owner) void {
        self.preset_candidates.deinit(self.allocator);
        for (self.assets.items) |*asset| asset.deinit();
        self.assets.deinit(self.allocator);
        for (self.transactions.items) |*tx| tx.deinit();
        self.transactions.deinit(self.allocator);
    }
    pub fn findAsset(self: *Owner, id: vehicle.VehicleArchetypeId) ?*vehicle.asset.Owned {
        for (self.assets.items) |*asset| if (std.meta.eql(asset.value.id, id)) return asset;
        return null;
    }
    pub fn inspect(self: *Owner, live: vehicle.VehicleView) !contract.Inspection {
        const saved = self.findAsset(live.definition.id) orelse return error.VehicleArchetypeMissing;
        var inspection = contract.Inspection{ .live = live, .committed = saved.value, .asset_revision = saved.value.revision };
        self.preset_candidates.clearRetainingCapacity();
        for (self.assets.items) |source| {
            try self.preset_candidates.append(self.allocator, .{
                .source_id = source.value.id,
                .source_label = source.value.label,
                .source_revision = source.value.revision,
                .source_digest = try source.value.digest(self.allocator),
                .candidate = try handling_profiles.candidate(live.definition, source.value),
            });
        }
        inspection.presets = self.preset_candidates.items;
        if (self.preview(live.id, live.revision)) |visuals| {
            const tx = self.transaction(self.preview_transaction.?).?;
            inspection.preview = .{ .source = tx.result.source, .transaction_id = tx.result.transaction_id, .visuals = visuals };
        }
        return inspection;
    }
    pub fn transaction(self: *Owner, id: u64) ?*Transaction {
        for (self.transactions.items) |*value| if (value.result.transaction_id == id) return value;
        return null;
    }
    pub fn result(self: *Owner, id: u64, source: engine.authoring.Source) ?contract.Result {
        const value = self.transaction(id) orelse return null;
        if (value.result.source != source) return null;
        return value.result;
    }

    pub fn prepare(self: *Owner, source: engine.authoring.Source, request: contract.Request, live: vehicle.VehicleView, catalog: []const engine.assets.Entry, writer: ?Writer) !*Transaction {
        try self.transactions.ensureUnusedCapacity(self.allocator, 1);
        var before = try live.definition.clone(self.allocator);
        var owns_before = true;
        errdefer if (owns_before) before.deinit();
        const id = self.next_transaction;
        self.next_transaction = try std.math.add(u64, id, 1);
        const saved = self.findAsset(live.definition.id) orelse return error.VehicleArchetypeMissing;
        self.transactions.appendAssumeCapacity(.{ .before = before, .result = .{ .transaction_id = id, .source = source, .target = request.target, .action = request.action, .disposition = .pending, .revision = live.revision, .asset_revision = saved.value.revision, .definition_digest = live.definition_digest } });
        owns_before = false;
        const tx = &self.transactions.items[self.transactions.items.len - 1];
        if (source == .ui) self.last_ui_result = id;
        if (!std.meta.eql(request.target, live.id)) return reject(tx, "target_mismatch");
        if (request.expected_revision != live.revision) return reject(tx, "stale_revision");
        if (request.expected_asset_revision != saved.value.revision) return reject(tx, "stale_asset_revision");
        if (request.action == .preview or request.action == .clear_preview) if (self.preview_transaction) |preview_id| {
            const active = self.transaction(preview_id).?;
            if (active.result.source != source and self.preview(live.id, live.revision) != null) return reject(tx, "preview_owned_by_another_producer");
        };
        if (request.action == .clear_preview) {
            self.preview_transaction = null;
            tx.result.disposition = .accepted;
            return tx;
        }
        for (self.transactions.items[0 .. self.transactions.items.len - 1]) |old| if (old.result.disposition == .pending and old.result.action != .measure and std.meta.eql(old.result.target, request.target)) return reject(tx, "owner_busy");
        var candidate = switch (request.action) {
            .apply, .rebuild, .measure, .preview => |value| value,
            .revert => saved.value,
            .commit => live.definition,
            .clear_preview => unreachable,
        };
        if (!std.meta.eql(candidate.id, saved.value.id)) return reject(tx, "archetype_mismatch");
        if (request.action == .commit) candidate.revision = try std.math.add(u64, saved.value.revision, 1) else if (candidate.revision != saved.value.revision) return reject(tx, "stale_asset_revision");
        candidate.validateCatalog(catalog) catch |err| return reject(tx, @errorName(err));
        tx.candidate = candidate.clone(self.allocator) catch |err| return reject(tx, @errorName(err));
        if (request.action == .preview) {
            self.preview_transaction = id;
            tx.result.disposition = .accepted;
            return tx;
        }
        if (request.action == .commit) {
            const durable = writer orelse return reject(tx, "persistence_unavailable");
            // Allocate every publication value before the atomic file replacement.
            var committed = candidate.clone(self.allocator) catch |err| return reject(tx, @errorName(err));
            errdefer committed.deinit();
            const digest = candidate.digest(self.allocator) catch |err| {
                committed.deinit();
                return reject(tx, @errorName(err));
            };
            durable.write_fn(durable.context, candidate) catch |err| {
                committed.deinit();
                return reject(tx, @errorName(err));
            };
            saved.deinit();
            saved.* = committed;
            tx.result.disposition = .accepted;
            tx.result.asset_revision = candidate.revision;
            tx.result.definition_digest = digest;
        } else if (request.action != .measure) {
            tx.command = .{ .transaction_id = id, .source = source, .id = request.target, .expected_revision = request.expected_revision, .expected_asset_revision = request.expected_asset_revision, .candidate = tx.candidate.?.value, .rebuild = request.action == .rebuild or request.action == .revert };
        }
        return tx;
    }

    pub fn admissionFailed(self: *Owner, id: u64, err: anyerror) void {
        if (self.transaction(id)) |tx| {
            _ = reject(tx, @errorName(err));
            tx.command = null;
        }
    }
    pub fn observe(self: *Owner, outcome: vehicle.Outcome) void {
        switch (outcome) {
            .reconfigured => |value| {
                const tx = self.transaction(value.transaction_id) orelse return;
                if (tx.result.source != value.source or !std.meta.eql(tx.result.target, value.id) or tx.result.disposition != .pending) return;
                tx.result.disposition = .accepted;
                tx.result.revision = value.revision;
                tx.result.authority_tick = value.authority_tick;
                tx.result.definition_digest = value.after_digest;
                tx.command = null;
            },
            .rejected => |value| {
                const tx = self.transaction(value.transaction_id orelse return) orelse return;
                if (value.source == null or tx.result.source != value.source.? or tx.result.disposition != .pending) return;
                _ = reject(tx, if (value.backend_error) |reason| reason else @tagName(value.reason));
                if (value.actual_revision) |revision| tx.result.revision = revision;
                tx.command = null;
            },
            else => {},
        }
    }
};
fn reject(tx: *Transaction, reason: []const u8) *Transaction {
    tx.result.disposition = .rejected;
    tx.result.rejection = reason;
    return tx;
}

fn testCatalog() [4]engine.assets.Entry {
    var result: [4]engine.assets.Entry = undefined;
    for (&result, 0..) |*entry, i| entry.* = .{
        .id = .{ .namespace = 1, .local = i + 1 },
        .kind = if (i % 2 == 0) .mesh else .material,
        .owner = .game,
        .label = "test",
        .bundle_key = "vehicle/test",
        .revision = 1,
        .digest = @splat(1),
        .dependencies = &.{},
        .source_format = .glb,
        .cook_status = .valid,
        .residency = .not_resident,
        .last_use_frame = null,
        .details = if (i % 2 == 0) .mesh else .{ .material = .{ .base_color = .{ 1, 1, 1, 1 }, .base_color_texture = null, .base_color_texcoord = 0 } },
    };
    return result;
}
fn testView(definition: contract.Definition) !vehicle.VehicleView {
    return .{
        .id = .{ .namespace = 8, .local = 1 },
        .definition = definition,
        .definition_digest = try definition.digest(std.testing.allocator),
        .revision = 0,
        .conditioned_steering = 0.3,
        .state = .{ .chassis = .{ .velocity = .{ .linear = .{ 0, 0, -12 } } }, .wheels = @splat(.{ .pose = .{}, .angular_velocity = 0, .rotation_angle = 0, .steer_angle = 0, .suspension_length = 0.3, .has_contact = true }), .engine_rpm = 2200, .current_gear = 2 },
        .input = .{},
        .driver_id = .{ .namespace = 8, .local = 2 },
    };
}

test "Lab and CLI share pending admission, owned candidates and producer-specific completion" {
    const allocator = std.testing.allocator;
    const definition = vehicle.asset.validationFixture();
    var owner = try Owner.init(allocator, &.{definition});
    defer owner.deinit();
    const live = try testView(definition);
    var candidate = definition;
    candidate.tuning.powertrain.max_torque_nm = 330;
    const tx = try owner.prepare(.ui, .{ .target = live.id, .expected_revision = 0, .expected_asset_revision = 1, .action = .{ .apply = candidate } }, live, &testCatalog(), null);
    const command = tx.command.?;
    try std.testing.expectEqual(contract.Disposition.pending, tx.result.disposition);
    try std.testing.expect(owner.result(command.transaction_id, .local_developer_client) == null);
    candidate.tuning.powertrain.max_torque_nm = 999;
    try std.testing.expectEqual(@as(f32, 330), command.candidate.tuning.powertrain.max_torque_nm);
    owner.observe(.{ .reconfigured = .{ .transaction_id = command.transaction_id, .source = .ui, .id = live.id, .authority_tick = 91, .revision = 1, .before_digest = live.definition_digest, .after_digest = try command.candidate.digest(allocator), .effect = .live } });
    const completed = owner.result(command.transaction_id, .ui).?;
    try std.testing.expectEqual(contract.Disposition.accepted, completed.disposition);
    try std.testing.expectEqual(@as(?u64, 91), completed.authority_tick);
    // Asset commits are independent; applying a selected instance has no fleet-wide effect.
    try std.testing.expectEqual(@as(f32, 500), owner.findAsset(definition.id).?.value.tuning.powertrain.max_torque_nm);
    var newer = live;
    newer.revision = 1;
    const stale = try owner.prepare(.local_developer_client, .{ .target = live.id, .expected_revision = 0, .expected_asset_revision = 1, .action = .{ .apply = candidate } }, newer, &testCatalog(), null);
    try std.testing.expectEqualStrings("stale_revision", stale.result.rejection.?);
    try std.testing.expect(stale.command == null);
}

test "vehicle durable write failure preserves saved revision and restart restores only the committed archetype" {
    const allocator = std.testing.allocator;
    const definition = vehicle.asset.validationFixture();
    var owner = try Owner.init(allocator, &.{definition});
    defer owner.deinit();
    var live = try testView(definition);
    live.definition.tuning.mass = 1750;
    live.definition_digest = try live.definition.digest(allocator);
    const request = contract.Request{ .target = live.id, .expected_revision = 0, .expected_asset_revision = 1, .action = .commit };
    const Storage = struct {
        directory: std.Io.Dir,
        fail: bool = true,
        fn write(context: *anyopaque, value: contract.Definition) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (self.fail) return error.InjectedVehicleWriteFailure;
            try vehicle.asset.write(std.testing.allocator, std.testing.io, self.directory, value);
        }
    };
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var storage = Storage{ .directory = temporary.dir };
    const writer = Writer{ .context = &storage, .write_fn = Storage.write };
    const failed = try owner.prepare(.local_developer_client, request, live, &testCatalog(), writer);
    try std.testing.expectEqualStrings("InjectedVehicleWriteFailure", failed.result.rejection.?);
    try std.testing.expectEqual(@as(u64, 1), owner.findAsset(definition.id).?.value.revision);
    storage.fail = false;
    const committed = try owner.prepare(.local_developer_client, request, live, &testCatalog(), writer);
    try std.testing.expectEqual(contract.Disposition.accepted, committed.result.disposition);
    var restarted = try vehicle.asset.read(allocator, std.testing.io, temporary.dir, definition.id);
    defer restarted.deinit();
    try std.testing.expectEqual(@as(u64, 2), restarted.value.revision);
    try std.testing.expectEqual(@as(f32, 1750), restarted.value.tuning.mass);
    try std.testing.expectEqual(@as(u64, 1), live.definition.revision);
    try std.testing.expectEqual(@as(f32, -12), live.state.chassis.velocity.linear[2]);
}

test "visual preview owns its candidate without changing admitted handling and expires across revisions" {
    const allocator = std.testing.allocator;
    const definition = vehicle.asset.validationFixture();
    var owner = try Owner.init(allocator, &.{definition});
    defer owner.deinit();
    const live = try testView(definition);
    var candidate = definition;
    candidate.tuning.mass = 1900;
    candidate.visuals.chassis.scale = .{ 1.1, 1, 1 };
    const tx = try owner.prepare(.ui, .{ .target = live.id, .expected_revision = 0, .expected_asset_revision = 1, .action = .{ .preview = candidate } }, live, &testCatalog(), null);
    try std.testing.expectEqual(contract.Disposition.accepted, tx.result.disposition);
    try std.testing.expect(tx.command == null);
    try std.testing.expectEqualDeep(candidate.visuals, owner.preview(live.id, 0).?);
    try std.testing.expect(owner.preview(live.id, 1) == null);
    try std.testing.expectEqualDeep(definition, owner.findAsset(definition.id).?.value);
    _ = try owner.prepare(.ui, .{ .target = live.id, .expected_revision = 0, .expected_asset_revision = 1, .action = .clear_preview }, live, &testCatalog(), null);
    try std.testing.expect(owner.preview(live.id, 0) == null);
}
