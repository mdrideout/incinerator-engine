//! Backend-neutral identity, transaction, and evidence values for authoring.
//!
//! Owners keep their concrete values, request unions, validation, outcomes,
//! and undo semantics. This contract supplies only stable correlation,
//! provenance, scope, revisions, and immutable diagnostic evidence.

const std = @import("std");
const assets = @import("assets.zig");
const identity = @import("../identity.zig");

pub const TransactionId = u64;
pub const Revision = u64;

pub const RunId = struct {
    started_wall_unix_ms: i64,
    nonce: u64,

    pub fn validate(self: RunId) !void {
        if (self.started_wall_unix_ms <= 0) return error.InvalidRunWallTime;
        if (self.nonce == 0) return error.InvalidRunNonce;
    }
};

pub const AssetMember = struct {
    asset: assets.AssetId,
    member: identity.PersistentId,

    pub fn validate(self: AssetMember) !void {
        try self.asset.validate();
        try self.member.validate();
    }
};

/// Explicit stable target variants. Title semantics remain owner-defined;
/// arbitrary property names and backend/runtime handles do not enter here.
pub const AuthoringTarget = union(enum) {
    persistent_entity: identity.PersistentId,
    asset: assets.AssetId,
    asset_member: AssetMember,

    pub fn validate(self: AuthoringTarget) !void {
        switch (self) {
            .persistent_entity => |id| try id.validate(),
            .asset => |id| try id.validate(),
            .asset_member => |member| try member.validate(),
        }
    }
};

pub const Source = enum(u8) {
    ui,
    local_developer_client,
    scripted_validation,
};

pub const EditScope = enum(u8) {
    preview,
    session,
    asset_commit,
};

pub const Request = struct {
    transaction_id: TransactionId,
    source: Source,
    scope: EditScope,
    target: AuthoringTarget,
    expected_revision: Revision,

    pub fn validate(self: Request) !void {
        if (self.transaction_id == 0) return error.InvalidAuthoringTransactionId;
        try self.target.validate();
    }
};

pub const Disposition = enum(u8) {
    accepted,
    rejected,
};

pub const CommonRejection = enum(u16) {
    invalid_request,
    stale_revision,
    scope_not_supported,
    target_not_found,
    target_kind_not_supported,
    owner_busy,
    owner_unavailable,
    durable_commit_failed,
};

pub const OwnerRejection = struct {
    /// Stable owner-selected numeric namespace, never a pointer or runtime ID.
    domain: u32,
    code: u32,

    pub fn validate(self: OwnerRejection) !void {
        if (self.domain == 0) return error.InvalidAuthoringRejectionDomain;
        if (self.code == 0) return error.InvalidAuthoringRejectionCode;
    }
};

pub const Rejection = union(enum) {
    common: CommonRejection,
    owner: OwnerRejection,

    pub fn validate(self: Rejection) !void {
        switch (self) {
            .common => {},
            .owner => |owner| try owner.validate(),
        }
    }
};

pub const DurableCommit = struct {
    asset: assets.AssetId,
    digest: assets.Digest,

    pub fn validate(self: DurableCommit) !void {
        try self.asset.validate();
        try assets.validateDigest(self.digest);
    }
};

/// Optional fingerprints correlate owner-specific typed values without
/// replacing those values with a generic property representation.
pub const ValueDigests = struct {
    before: ?assets.Digest = null,
    requested: ?assets.Digest = null,
    committed: ?assets.Digest = null,

    pub fn validate(self: ValueDigests) !void {
        if (self.before) |digest| try assets.validateDigest(digest);
        if (self.requested) |digest| try assets.validateDigest(digest);
        if (self.committed) |digest| try assets.validateDigest(digest);
    }
};

/// One immutable generic authored-change record. Concrete owners retain typed
/// before/requested/committed values next to this record when applicable.
pub const AuthoredChange = struct {
    run_id: RunId,
    request: Request,
    committed_revision: ?Revision,
    wall_unix_ms: i64,
    authority_tick: ?u64,
    presentation_frame: ?u64,
    disposition: Disposition,
    rejection: ?Rejection = null,
    durable_commit: ?DurableCommit = null,
    values: ValueDigests = .{},

    pub fn validate(self: AuthoredChange) !void {
        try self.run_id.validate();
        try self.request.validate();
        if (self.wall_unix_ms <= 0) return error.InvalidAuthoredChangeWallTime;
        try self.values.validate();

        switch (self.disposition) {
            .accepted => {
                if (self.committed_revision == null) {
                    return error.AcceptedAuthoringRevisionMissing;
                }
                if (self.rejection != null) return error.AcceptedAuthoringHasRejection;
            },
            .rejected => {
                if (self.committed_revision != null) {
                    return error.RejectedAuthoringHasCommittedRevision;
                }
                const rejection = self.rejection orelse
                    return error.RejectedAuthoringReasonMissing;
                try rejection.validate();
                if (self.durable_commit != null) {
                    return error.RejectedAuthoringHasDurableCommit;
                }
            },
        }
        if (self.durable_commit) |commit| {
            if (self.request.scope != .asset_commit) {
                return error.DurableCommitScopeMismatch;
            }
            try commit.validate();
        }
    }
};

test "authoring targets validate explicit identity variants" {
    const entity = AuthoringTarget{ .persistent_entity = .{
        .namespace = 5,
        .local = 9,
    } };
    try entity.validate();
    try (AuthoringTarget{ .asset = .{ .namespace = 8, .local = 3 } }).validate();
    try (AuthoringTarget{ .asset_member = .{
        .asset = .{ .namespace = 8, .local = 3 },
        .member = .{ .namespace = 4, .local = 2 },
    } }).validate();
}

test "request requires correlation and stable target but permits revision zero" {
    const request = Request{
        .transaction_id = 1,
        .source = .ui,
        .scope = .session,
        .target = .{ .persistent_entity = .{ .namespace = 5, .local = 1 } },
        .expected_revision = 0,
    };
    try request.validate();
    var invalid = request;
    invalid.transaction_id = 0;
    try std.testing.expectError(error.InvalidAuthoringTransactionId, invalid.validate());
}

test "accepted and rejected authored changes are structurally exclusive" {
    const request = Request{
        .transaction_id = 4,
        .source = .scripted_validation,
        .scope = .session,
        .target = .{ .persistent_entity = .{ .namespace = 5, .local = 1 } },
        .expected_revision = 2,
    };
    const accepted = AuthoredChange{
        .run_id = .{ .started_wall_unix_ms = 1_700_000_000_000, .nonce = 11 },
        .request = request,
        .committed_revision = 3,
        .wall_unix_ms = 1_700_000_000_100,
        .authority_tick = 9,
        .presentation_frame = 14,
        .disposition = .accepted,
    };
    try accepted.validate();

    var rejected = accepted;
    rejected.committed_revision = null;
    rejected.disposition = .rejected;
    rejected.rejection = .{ .common = .stale_revision };
    try rejected.validate();

    rejected.rejection = null;
    try std.testing.expectError(
        error.RejectedAuthoringReasonMissing,
        rejected.validate(),
    );
}

test "durable evidence is exclusive to asset commit scope" {
    var digest: assets.Digest = @splat(0);
    digest[0] = 1;
    var change = AuthoredChange{
        .run_id = .{ .started_wall_unix_ms = 1, .nonce = 2 },
        .request = .{
            .transaction_id = 3,
            .source = .ui,
            .scope = .asset_commit,
            .target = .{ .asset = .{ .namespace = 4, .local = 5 } },
            .expected_revision = 6,
        },
        .committed_revision = 7,
        .wall_unix_ms = 8,
        .authority_tick = null,
        .presentation_frame = 9,
        .disposition = .accepted,
        .durable_commit = .{
            .asset = .{ .namespace = 4, .local = 5 },
            .digest = digest,
        },
    };
    try change.validate();
    change.request.scope = .session;
    try std.testing.expectError(error.DurableCommitScopeMismatch, change.validate());
}
