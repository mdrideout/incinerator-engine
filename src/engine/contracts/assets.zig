//! Stable durable asset identity shared by runtime content and authoring.
//!
//! Asset identity is deliberately nominally distinct from persistent entity
//! identity. It never contains a source path, runtime handle, pointer, or
//! backend resource identifier.

const std = @import("std");

pub const Digest = [32]u8;

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
