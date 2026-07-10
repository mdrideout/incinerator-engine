//! Stable identity primitives shared by engine features and persistence.
//!
//! `PersistentId` is deliberately separate from an ECS/runtime entity ID. A
//! runtime ID is only meaningful while one world is alive; a persistent ID is
//! safe to serialize and restore. The namespace identifies the authority that
//! issued the local value (a game, shard, import tool, and so on).

const std = @import("std");

pub const PersistentId = struct {
    namespace: u64,
    local: u64,

    pub fn validate(self: PersistentId) !void {
        if (self.namespace == 0) return error.InvalidIdentityNamespace;
        if (self.local == 0) return error.InvalidIdentityLocal;
    }
};

/// Monotonic issuer for one persistent-identity namespace.
///
/// Values are never recycled. A failed operation after `next` has returned may
/// leave a gap, which is preferable to accidentally giving a new object an old
/// identity. `observe` advances the high-water mark when restored data contains
/// an identity from this source.
pub const IdentitySource = struct {
    namespace: u64,
    next_local: u64,
    exhausted: bool = false,

    pub fn init(namespace: u64) !IdentitySource {
        return initAt(namespace, 1);
    }

    pub fn initAt(namespace: u64, next_local: u64) !IdentitySource {
        const first = PersistentId{ .namespace = namespace, .local = next_local };
        try first.validate();
        return .{
            .namespace = namespace,
            .next_local = next_local,
        };
    }

    pub fn next(self: *IdentitySource) !PersistentId {
        if (self.exhausted) return error.IdentitySourceExhausted;

        const result = PersistentId{
            .namespace = self.namespace,
            .local = self.next_local,
        };

        if (self.next_local == std.math.maxInt(u64)) {
            self.exhausted = true;
        } else {
            self.next_local += 1;
        }
        return result;
    }

    /// Advance past an already-issued identity from this source.
    pub fn observe(self: *IdentitySource, id: PersistentId) !void {
        try id.validate();
        if (id.namespace != self.namespace) return error.ForeignIdentityNamespace;
        if (self.exhausted or id.local < self.next_local) return;

        if (id.local == std.math.maxInt(u64)) {
            self.exhausted = true;
        } else {
            self.next_local = id.local + 1;
        }
    }

    /// The next value that would be issued, or null after the namespace is
    /// exhausted.
    pub fn cursor(self: *const IdentitySource) ?u64 {
        return if (self.exhausted) null else self.next_local;
    }
};

test "persistent identity validates both parts" {
    try (PersistentId{ .namespace = 9, .local = 4 }).validate();
    try std.testing.expectError(
        error.InvalidIdentityNamespace,
        (PersistentId{ .namespace = 0, .local = 4 }).validate(),
    );
    try std.testing.expectError(
        error.InvalidIdentityLocal,
        (PersistentId{ .namespace = 9, .local = 0 }).validate(),
    );
}

test "identity source is monotonic and observes a restored high-water mark" {
    var source = try IdentitySource.init(42);
    try std.testing.expectEqual(PersistentId{ .namespace = 42, .local = 1 }, try source.next());
    try std.testing.expectEqual(PersistentId{ .namespace = 42, .local = 2 }, try source.next());

    try source.observe(.{ .namespace = 42, .local = 20 });
    try std.testing.expectEqual(@as(?u64, 21), source.cursor());
    try std.testing.expectEqual(PersistentId{ .namespace = 42, .local = 21 }, try source.next());

    // Observing an older identity never moves the source backwards.
    try source.observe(.{ .namespace = 42, .local = 3 });
    try std.testing.expectEqual(@as(?u64, 22), source.cursor());
    try std.testing.expectError(
        error.ForeignIdentityNamespace,
        source.observe(.{ .namespace = 7, .local = 100 }),
    );
}

test "identity source reports exhaustion instead of wrapping" {
    var source = try IdentitySource.initAt(1, std.math.maxInt(u64));
    try std.testing.expectEqual(
        PersistentId{ .namespace = 1, .local = std.math.maxInt(u64) },
        try source.next(),
    );
    try std.testing.expectEqual(@as(?u64, null), source.cursor());
    try std.testing.expectError(error.IdentitySourceExhausted, source.next());
}
