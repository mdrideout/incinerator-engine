//! Typed material authoring values shared by UI, CLI, and the concrete owner.
const std = @import("std");
const engine = @import("engine_contracts");
const assets = engine.assets;

pub const Action = union(enum) {
    preview: assets.MaterialMetadata,
    preview_assignment: assets.AssetId,
    assign: assets.AssetId,
    clear_preview,
    apply: assets.MaterialMetadata,
    revert,
    commit,
};

pub const Request = struct {
    target: assets.AssetId,
    expected_revision: u64,
    action: Action,
};

pub const Rejection = enum {
    target_missing,
    wrong_target_kind,
    material_missing,
    stale_revision,
    invalid_material,
    texture_missing,
    texture_color_space,
    preview_owned_by_another_producer,
    persistence_unavailable,
    persistence_failed,
};

pub const Outcome = struct {
    transaction_id: u64,
    source: engine.authoring.Source,
    target: assets.AssetId,
    action: std.meta.Tag(Action),
    revision: u64,
    asset_revision: u64,
    rejection: ?Rejection = null,
};

pub const Preview = struct {
    source: engine.authoring.Source,
    value: assets.MaterialMetadata,
};

pub const Record = struct {
    id: assets.AssetId,
    label: []const u8,
    revision: u64,
    asset_revision: u64,
    committed: assets.MaterialMetadata,
    session: assets.MaterialMetadata,
    preview: ?Preview = null,

    pub fn presented(self: Record) assets.MaterialMetadata {
        return if (self.preview) |value| value.value else self.session;
    }

    pub fn dirty(self: Record) bool {
        return !std.meta.eql(self.session, self.committed);
    }
};

pub const PreviewMode = enum { world, neutral };

pub const BindingRecord = struct {
    mesh: assets.AssetId,
    revision: u64,
    asset_revision: u64,
    committed: assets.AssetId,
    session: assets.AssetId,
    preview: ?struct { source: engine.authoring.Source, value: assets.AssetId } = null,

    pub fn presented(self: BindingRecord) assets.AssetId {
        return if (self.preview) |value| value.value else self.session;
    }
};

pub const Inspection = union(enum) { material: Record, binding: BindingRecord };

pub const Evidence = struct {
    request: Request,
    outcome: Outcome,
    before: ?Inspection,
    after: ?Inspection,
};

pub const Requests = struct {
    allocator: std.mem.Allocator,
    pending: std.ArrayList(Request) = .empty,

    pub fn submit(self: *Requests, request: Request) !void {
        try self.pending.append(self.allocator, request);
    }

    pub fn deinit(self: *Requests) void {
        self.pending.deinit(self.allocator);
    }
};

pub const View = struct {
    records: []const Record,
    bindings: []const BindingRecord,
    last_ui_outcome: ?Outcome,
    persistence_available: bool,
};

pub const PreviewImage = struct { binding: *const anyopaque, extent: u32 };

pub const Input = struct {
    preview_image: ?PreviewImage = null,
    preview_extent: *u32,
    view: View,
    requests: *Requests,
    preview_mode: *PreviewMode,
    preview_material: *?assets.AssetId,
};
