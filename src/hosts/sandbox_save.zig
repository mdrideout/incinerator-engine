//! Backend-neutral durable-save envelope for the sandbox host.
//!
//! This module deliberately knows nothing about JSON, simulations, files,
//! SDL, or rendering. It wraps caller-owned logical snapshot bytes in a
//! bounded canonical little-endian envelope and validates the complete file
//! before returning a borrowed payload view. A host must validate the expected
//! schema and exact simulation, world, and content fingerprints before using
//! the payload to construct authoritative state.

const std = @import("std");

pub const Digest = [32]u8;

pub const magic = [8]u8{ 'I', 'N', 'C', 'S', 'A', 'V', 'E', 0 };
pub const format_version: u16 = 1;
pub const header_size: usize = 160;
pub const integrity_size: usize = @sizeOf(Digest);
pub const max_payload_bytes: usize = 8 * 1024 * 1024;
pub const max_envelope_bytes: usize = header_size + max_payload_bytes + integrity_size;

const format_version_offset: usize = 8;
const header_size_offset: usize = 10;
const payload_schema_offset: usize = 12;
const flags_offset: usize = 14;
const total_size_offset: usize = 16;
const payload_offset_offset: usize = 24;
const payload_size_offset: usize = 32;
const simulation_build_digest_offset: usize = 40;
const world_config_digest_offset: usize = 72;
const content_digest_offset: usize = 104;
const reserved_offset: usize = 136;

comptime {
    std.debug.assert(magic.len == format_version_offset);
    std.debug.assert(simulation_build_digest_offset + @sizeOf(Digest) == world_config_digest_offset);
    std.debug.assert(world_config_digest_offset + @sizeOf(Digest) == content_digest_offset);
    std.debug.assert(content_digest_offset + @sizeOf(Digest) == reserved_offset);
    std.debug.assert(reserved_offset <= header_size);
}

pub const EnvelopeError = error{
    InvalidSaveLimits,
    InvalidPayloadSchema,
    InvalidSimulationBuildDigest,
    InvalidWorldConfigDigest,
    InvalidContentDigest,
    SavePayloadTooLarge,
    SaveEnvelopeTooLarge,
    DestinationTooSmall,
    BadSaveMagic,
    UnsupportedSaveFormat,
    InvalidSaveHeader,
    SaveSizeMismatch,
    TruncatedSaveEnvelope,
    TrailingSaveEnvelope,
    SaveIntegrityMismatch,
    IncompatiblePayloadSchema,
    IncompatibleSimulationBuild,
    IncompatibleWorldConfig,
    IncompatibleContent,
};

pub const EncodeError = EnvelopeError || std.mem.Allocator.Error;
pub const ParseError = EnvelopeError;
pub const CompatibilityError = error{
    IncompatiblePayloadSchema,
    IncompatibleSimulationBuild,
    IncompatibleWorldConfig,
    IncompatibleContent,
};

/// Exact admission identities for one logical snapshot payload. Digests are
/// opaque SHA-256 fingerprints produced by the owning composition; this module
/// does not derive or interpret them.
pub const Metadata = struct {
    payload_schema: u16,
    simulation_build_digest: Digest,
    world_config_digest: Digest,
    content_digest: Digest,

    pub fn validate(self: Metadata) EnvelopeError!void {
        if (self.payload_schema == 0) return error.InvalidPayloadSchema;
        if (!hasNonzeroByte(&self.simulation_build_digest)) {
            return error.InvalidSimulationBuildDigest;
        }
        if (!hasNonzeroByte(&self.world_config_digest)) {
            return error.InvalidWorldConfigDigest;
        }
        if (!hasNonzeroByte(&self.content_digest)) {
            return error.InvalidContentDigest;
        }
    }
};

/// Callers may impose a narrower policy, but never widen the hard envelope
/// bounds. `max_file_bytes` includes the fixed header and integrity trailer.
pub const Limits = struct {
    max_payload_bytes: usize = max_payload_bytes,
    max_file_bytes: usize = max_envelope_bytes,

    pub fn validate(self: Limits) EnvelopeError!void {
        if (self.max_payload_bytes > max_payload_bytes or
            self.max_file_bytes < header_size + integrity_size or
            self.max_file_bytes > max_envelope_bytes)
        {
            return error.InvalidSaveLimits;
        }
    }
};

/// Fully validated, allocation-free view into the caller's immutable envelope
/// bytes. `payload` and `bytes` borrow the input supplied to `parse`.
pub const View = struct {
    bytes: []const u8,
    metadata: Metadata,
    payload: []const u8,
    integrity: Digest,

    pub fn validateCompatible(
        self: View,
        expected: Metadata,
    ) CompatibilityError!void {
        if (self.metadata.payload_schema != expected.payload_schema) {
            return error.IncompatiblePayloadSchema;
        }
        if (!std.mem.eql(
            u8,
            &self.metadata.simulation_build_digest,
            &expected.simulation_build_digest,
        )) {
            return error.IncompatibleSimulationBuild;
        }
        if (!std.mem.eql(
            u8,
            &self.metadata.world_config_digest,
            &expected.world_config_digest,
        )) {
            return error.IncompatibleWorldConfig;
        }
        if (!std.mem.eql(
            u8,
            &self.metadata.content_digest,
            &expected.content_digest,
        )) {
            return error.IncompatibleContent;
        }
    }
};

pub fn encodedSize(payload_len: usize) EnvelopeError!usize {
    return encodedSizeWithLimits(payload_len, .{});
}

pub fn encodedSizeWithLimits(
    payload_len: usize,
    limits: Limits,
) EnvelopeError!usize {
    try limits.validate();
    if (payload_len > limits.max_payload_bytes or payload_len > max_payload_bytes) {
        return error.SavePayloadTooLarge;
    }
    const payload_end = std.math.add(usize, header_size, payload_len) catch
        return error.SaveEnvelopeTooLarge;
    const total_size = std.math.add(usize, payload_end, integrity_size) catch
        return error.SaveEnvelopeTooLarge;
    if (total_size > limits.max_file_bytes or total_size > max_envelope_bytes) {
        return error.SaveEnvelopeTooLarge;
    }
    return total_size;
}

/// Allocate and encode one canonical envelope. The returned bytes are owned by
/// `allocator`. Encoding never serializes native aggregate memory layouts.
pub fn encode(
    allocator: std.mem.Allocator,
    metadata: Metadata,
    payload: []const u8,
) EncodeError![]u8 {
    return encodeWithLimits(allocator, metadata, payload, .{});
}

pub fn encodeWithLimits(
    allocator: std.mem.Allocator,
    metadata: Metadata,
    payload: []const u8,
    limits: Limits,
) EncodeError![]u8 {
    try metadata.validate();
    const total_size = try encodedSizeWithLimits(payload.len, limits);
    const bytes = try allocator.alloc(u8, total_size);
    errdefer allocator.free(bytes);
    _ = try encodeIntoWithLimits(bytes, metadata, payload, limits);
    return bytes;
}

/// Encode into caller-owned storage and return the initialized prefix. The
/// destination and payload must not overlap.
pub fn encodeInto(
    destination: []u8,
    metadata: Metadata,
    payload: []const u8,
) EnvelopeError![]u8 {
    return encodeIntoWithLimits(destination, metadata, payload, .{});
}

pub fn encodeIntoWithLimits(
    destination: []u8,
    metadata: Metadata,
    payload: []const u8,
    limits: Limits,
) EnvelopeError![]u8 {
    try metadata.validate();
    const total_size = try encodedSizeWithLimits(payload.len, limits);
    if (destination.len < total_size) return error.DestinationTooSmall;

    const bytes = destination[0..total_size];
    @memset(bytes, 0);
    @memcpy(bytes[0..magic.len], &magic);
    putU16(bytes, format_version_offset, format_version);
    putU16(bytes, header_size_offset, @intCast(header_size));
    putU16(bytes, payload_schema_offset, metadata.payload_schema);
    putU16(bytes, flags_offset, 0);
    putU64(bytes, total_size_offset, @intCast(total_size));
    putU64(bytes, payload_offset_offset, @intCast(header_size));
    putU64(bytes, payload_size_offset, @intCast(payload.len));
    @memcpy(
        bytes[simulation_build_digest_offset..world_config_digest_offset],
        &metadata.simulation_build_digest,
    );
    @memcpy(
        bytes[world_config_digest_offset..content_digest_offset],
        &metadata.world_config_digest,
    );
    @memcpy(
        bytes[content_digest_offset..reserved_offset],
        &metadata.content_digest,
    );

    const payload_end = header_size + payload.len;
    @memcpy(bytes[header_size..payload_end], payload);
    var integrity: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes[0..payload_end], &integrity, .{});
    @memcpy(bytes[payload_end..total_size], &integrity);
    return bytes;
}

/// Validate structure, bounds, canonical header fields, SHA-256 integrity, and
/// metadata presence before returning a borrowed payload view.
pub fn parse(bytes: []const u8) ParseError!View {
    return parseWithLimits(bytes, .{});
}

pub fn parseWithLimits(bytes: []const u8, limits: Limits) ParseError!View {
    try limits.validate();
    if (bytes.len > limits.max_file_bytes or bytes.len > max_envelope_bytes) {
        return error.SaveEnvelopeTooLarge;
    }
    if (bytes.len < header_size + integrity_size) {
        return error.TruncatedSaveEnvelope;
    }
    if (!std.mem.eql(u8, bytes[0..magic.len], &magic)) {
        return error.BadSaveMagic;
    }
    if (getU16(bytes, format_version_offset) != format_version) {
        return error.UnsupportedSaveFormat;
    }
    if (getU16(bytes, header_size_offset) != header_size or
        getU16(bytes, flags_offset) != 0 or
        getU64(bytes, payload_offset_offset) != header_size or
        !std.mem.allEqual(u8, bytes[reserved_offset..header_size], 0))
    {
        return error.InvalidSaveHeader;
    }

    const payload_schema = getU16(bytes, payload_schema_offset);
    if (payload_schema == 0) return error.InvalidPayloadSchema;

    const declared_total_size = getU64(bytes, total_size_offset);
    const declared_payload_size = getU64(bytes, payload_size_offset);
    if (declared_payload_size > limits.max_payload_bytes or
        declared_payload_size > max_payload_bytes)
    {
        return error.SavePayloadTooLarge;
    }
    if (declared_total_size > limits.max_file_bytes or
        declared_total_size > max_envelope_bytes)
    {
        return error.SaveEnvelopeTooLarge;
    }

    const payload_size = std.math.cast(usize, declared_payload_size) orelse
        return error.SavePayloadTooLarge;
    const payload_end = std.math.add(usize, header_size, payload_size) catch
        return error.SaveEnvelopeTooLarge;
    const expected_total_size = std.math.add(usize, payload_end, integrity_size) catch
        return error.SaveEnvelopeTooLarge;
    if (expected_total_size > limits.max_file_bytes or
        expected_total_size > max_envelope_bytes)
    {
        return error.SaveEnvelopeTooLarge;
    }
    if (declared_total_size != expected_total_size) {
        return error.SaveSizeMismatch;
    }
    if (bytes.len < expected_total_size) return error.TruncatedSaveEnvelope;
    if (bytes.len > expected_total_size) return error.TrailingSaveEnvelope;

    var actual_integrity: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes[0..payload_end], &actual_integrity, .{});
    if (!std.mem.eql(u8, &actual_integrity, bytes[payload_end..expected_total_size])) {
        return error.SaveIntegrityMismatch;
    }

    var simulation_build_digest: Digest = undefined;
    var world_config_digest: Digest = undefined;
    var content_digest: Digest = undefined;
    @memcpy(
        &simulation_build_digest,
        bytes[simulation_build_digest_offset..world_config_digest_offset],
    );
    @memcpy(
        &world_config_digest,
        bytes[world_config_digest_offset..content_digest_offset],
    );
    @memcpy(
        &content_digest,
        bytes[content_digest_offset..reserved_offset],
    );
    const metadata = Metadata{
        .payload_schema = payload_schema,
        .simulation_build_digest = simulation_build_digest,
        .world_config_digest = world_config_digest,
        .content_digest = content_digest,
    };
    try metadata.validate();

    var integrity: Digest = undefined;
    @memcpy(&integrity, bytes[payload_end..expected_total_size]);
    return .{
        .bytes = bytes,
        .metadata = metadata,
        .payload = bytes[header_size..payload_end],
        .integrity = integrity,
    };
}

pub fn parseCompatible(
    bytes: []const u8,
    expected: Metadata,
) EnvelopeError!View {
    return parseCompatibleWithLimits(bytes, expected, .{});
}

pub fn parseCompatibleWithLimits(
    bytes: []const u8,
    expected: Metadata,
    limits: Limits,
) EnvelopeError!View {
    try expected.validate();
    const view = try parseWithLimits(bytes, limits);
    try view.validateCompatible(expected);
    return view;
}

fn hasNonzeroByte(bytes: []const u8) bool {
    for (bytes) |byte| {
        if (byte != 0) return true;
    }
    return false;
}

fn putU16(bytes: []u8, offset: usize, value: u16) void {
    var encoded: [2]u8 = undefined;
    std.mem.writeInt(u16, &encoded, value, .little);
    @memcpy(bytes[offset .. offset + encoded.len], &encoded);
}

fn putU64(bytes: []u8, offset: usize, value: u64) void {
    var encoded: [8]u8 = undefined;
    std.mem.writeInt(u64, &encoded, value, .little);
    @memcpy(bytes[offset .. offset + encoded.len], &encoded);
}

fn getU16(bytes: []const u8, offset: usize) u16 {
    var encoded: [2]u8 = undefined;
    @memcpy(&encoded, bytes[offset .. offset + encoded.len]);
    return std.mem.readInt(u16, &encoded, .little);
}

fn getU64(bytes: []const u8, offset: usize) u64 {
    var encoded: [8]u8 = undefined;
    @memcpy(&encoded, bytes[offset .. offset + encoded.len]);
    return std.mem.readInt(u64, &encoded, .little);
}

fn testDigest(seed: u8) Digest {
    var digest: Digest = undefined;
    for (&digest, 0..) |*byte, index| {
        byte.* = seed +% @as(u8, @intCast(index));
    }
    return digest;
}

fn testMetadata() Metadata {
    return .{
        .payload_schema = 4,
        .simulation_build_digest = testDigest(0x10),
        .world_config_digest = testDigest(0x40),
        .content_digest = testDigest(0x80),
    };
}

test "save envelope round trips canonically as a borrowed payload view" {
    const metadata = testMetadata();
    const payload =
        \\{"schema_version":4,"tick_index":17,"next_identity":9}
    ;
    const first = try encode(std.testing.allocator, metadata, payload);
    defer std.testing.allocator.free(first);

    const view = try parseCompatible(first, metadata);
    try std.testing.expectEqual(first.len, view.bytes.len);
    try std.testing.expectEqualStrings(payload, view.payload);
    try std.testing.expectEqual(metadata, view.metadata);
    try std.testing.expectEqual(@intFromPtr(first.ptr), @intFromPtr(view.bytes.ptr));
    try std.testing.expectEqual(
        @intFromPtr(first.ptr + header_size),
        @intFromPtr(view.payload.ptr),
    );

    const second = try encode(std.testing.allocator, view.metadata, view.payload);
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualSlices(u8, first, second);

    var expected_integrity: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(
        first[0 .. first.len - integrity_size],
        &expected_integrity,
        .{},
    );
    try std.testing.expectEqual(expected_integrity, view.integrity);
}

test "save envelope uses explicit little-endian fields and zero reserved bytes" {
    var metadata = testMetadata();
    metadata.payload_schema = 0x1234;
    const payload = [_]u8{ 1, 2, 3, 4, 5 };
    const bytes = try encode(std.testing.allocator, metadata, &payload);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualSlices(u8, &magic, bytes[0..magic.len]);
    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{ @intCast(format_version), 0 },
        bytes[format_version_offset .. format_version_offset + 2],
    );
    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{ 0x34, 0x12 },
        bytes[payload_schema_offset .. payload_schema_offset + 2],
    );
    try std.testing.expectEqual(@as(u64, bytes.len), getU64(bytes, total_size_offset));
    try std.testing.expectEqual(@as(u64, header_size), getU64(bytes, payload_offset_offset));
    try std.testing.expectEqual(@as(u64, payload.len), getU64(bytes, payload_size_offset));
    try std.testing.expect(std.mem.allEqual(u8, bytes[reserved_offset..header_size], 0));
    try std.testing.expectEqualSlices(u8, &payload, bytes[header_size .. header_size + payload.len]);
}

test "encodeInto is bounded and initializes only the canonical prefix" {
    const metadata = testMetadata();
    const payload = "bounded snapshot";
    const required = try encodedSize(payload.len);
    var storage: [512]u8 = @splat(0xa5);
    try std.testing.expect(required < storage.len);

    const bytes = try encodeInto(&storage, metadata, payload);
    try std.testing.expectEqual(required, bytes.len);
    try std.testing.expectEqual(@as(u8, 0xa5), storage[required]);
    const view = try parse(bytes);
    try std.testing.expectEqualStrings(payload, view.payload);

    try std.testing.expectError(
        error.DestinationTooSmall,
        encodeInto(storage[0 .. required - 1], metadata, payload),
    );
}

test "compatibility validation distinguishes schema and every cohort" {
    const metadata = testMetadata();
    const bytes = try encode(std.testing.allocator, metadata, "snapshot");
    defer std.testing.allocator.free(bytes);
    const view = try parse(bytes);

    var wrong = metadata;
    wrong.payload_schema += 1;
    try std.testing.expectError(
        error.IncompatiblePayloadSchema,
        view.validateCompatible(wrong),
    );

    wrong = metadata;
    wrong.simulation_build_digest[5] ^= 0x80;
    try std.testing.expectError(
        error.IncompatibleSimulationBuild,
        view.validateCompatible(wrong),
    );

    wrong = metadata;
    wrong.world_config_digest[7] ^= 0x40;
    try std.testing.expectError(
        error.IncompatibleWorldConfig,
        view.validateCompatible(wrong),
    );

    wrong = metadata;
    wrong.content_digest[9] ^= 0x20;
    try std.testing.expectError(
        error.IncompatibleContent,
        view.validateCompatible(wrong),
    );
}

test "parseCompatible distinguishes canonical envelopes from different cohorts" {
    const expected = testMetadata();
    var found = expected;
    found.simulation_build_digest[0] ^= 1;
    const simulation_bytes = try encode(std.testing.allocator, found, "snapshot");
    defer std.testing.allocator.free(simulation_bytes);
    try std.testing.expectError(
        error.IncompatibleSimulationBuild,
        parseCompatible(simulation_bytes, expected),
    );

    found = expected;
    found.world_config_digest[0] ^= 1;
    const world_bytes = try encode(std.testing.allocator, found, "snapshot");
    defer std.testing.allocator.free(world_bytes);
    try std.testing.expectError(
        error.IncompatibleWorldConfig,
        parseCompatible(world_bytes, expected),
    );

    found = expected;
    found.content_digest[0] ^= 1;
    const content_bytes = try encode(std.testing.allocator, found, "snapshot");
    defer std.testing.allocator.free(content_bytes);
    try std.testing.expectError(
        error.IncompatibleContent,
        parseCompatible(content_bytes, expected),
    );
}

test "metadata rejects missing schema and fingerprints before encoding" {
    var metadata = testMetadata();
    metadata.payload_schema = 0;
    try std.testing.expectError(
        error.InvalidPayloadSchema,
        encode(std.testing.allocator, metadata, "snapshot"),
    );

    metadata = testMetadata();
    metadata.simulation_build_digest = @splat(0);
    try std.testing.expectError(
        error.InvalidSimulationBuildDigest,
        encode(std.testing.allocator, metadata, "snapshot"),
    );

    metadata = testMetadata();
    metadata.world_config_digest = @splat(0);
    try std.testing.expectError(
        error.InvalidWorldConfigDigest,
        encode(std.testing.allocator, metadata, "snapshot"),
    );

    metadata = testMetadata();
    metadata.content_digest = @splat(0);
    try std.testing.expectError(
        error.InvalidContentDigest,
        encode(std.testing.allocator, metadata, "snapshot"),
    );
}

test "parser rejects corrupt integrity and truncation at every envelope region" {
    const bytes = try encode(std.testing.allocator, testMetadata(), "snapshot payload");
    defer std.testing.allocator.free(bytes);

    const corrupt_payload = try std.testing.allocator.dupe(u8, bytes);
    defer std.testing.allocator.free(corrupt_payload);
    corrupt_payload[header_size + 2] ^= 0x80;
    try std.testing.expectError(error.SaveIntegrityMismatch, parse(corrupt_payload));

    const corrupt_integrity = try std.testing.allocator.dupe(u8, bytes);
    defer std.testing.allocator.free(corrupt_integrity);
    corrupt_integrity[corrupt_integrity.len - 1] ^= 1;
    try std.testing.expectError(error.SaveIntegrityMismatch, parse(corrupt_integrity));

    for ([_]usize{
        0,
        magic.len - 1,
        header_size - 1,
        header_size + integrity_size - 1,
        bytes.len - integrity_size,
        bytes.len - 1,
    }) |end| {
        try std.testing.expectError(error.TruncatedSaveEnvelope, parse(bytes[0..end]));
    }
}

test "parser rejects trailing data, bad magic, versions, header, and reserved bytes" {
    const canonical = try encode(std.testing.allocator, testMetadata(), "snapshot");
    defer std.testing.allocator.free(canonical);

    const trailing = try std.testing.allocator.alloc(u8, canonical.len + 1);
    defer std.testing.allocator.free(trailing);
    @memcpy(trailing[0..canonical.len], canonical);
    trailing[canonical.len] = 0xff;
    try std.testing.expectError(error.TrailingSaveEnvelope, parse(trailing));

    const bad_magic = try std.testing.allocator.dupe(u8, canonical);
    defer std.testing.allocator.free(bad_magic);
    bad_magic[0] ^= 1;
    try std.testing.expectError(error.BadSaveMagic, parse(bad_magic));

    const bad_version = try std.testing.allocator.dupe(u8, canonical);
    defer std.testing.allocator.free(bad_version);
    putU16(bad_version, format_version_offset, format_version + 1);
    try std.testing.expectError(error.UnsupportedSaveFormat, parse(bad_version));

    const bad_header_size = try std.testing.allocator.dupe(u8, canonical);
    defer std.testing.allocator.free(bad_header_size);
    putU16(bad_header_size, header_size_offset, header_size - 1);
    try std.testing.expectError(error.InvalidSaveHeader, parse(bad_header_size));

    const bad_flags = try std.testing.allocator.dupe(u8, canonical);
    defer std.testing.allocator.free(bad_flags);
    putU16(bad_flags, flags_offset, 1);
    try std.testing.expectError(error.InvalidSaveHeader, parse(bad_flags));

    const bad_payload_offset = try std.testing.allocator.dupe(u8, canonical);
    defer std.testing.allocator.free(bad_payload_offset);
    putU64(bad_payload_offset, payload_offset_offset, header_size + 1);
    try std.testing.expectError(error.InvalidSaveHeader, parse(bad_payload_offset));

    const bad_reserved = try std.testing.allocator.dupe(u8, canonical);
    defer std.testing.allocator.free(bad_reserved);
    bad_reserved[reserved_offset + 3] = 1;
    try std.testing.expectError(error.InvalidSaveHeader, parse(bad_reserved));
}

test "size preflight rejects oversized input and hostile declared sizes" {
    const oversized = try std.testing.allocator.alloc(u8, max_envelope_bytes + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 0);
    try std.testing.expectError(error.SaveEnvelopeTooLarge, parse(oversized));
    try std.testing.expectError(
        error.SavePayloadTooLarge,
        encodedSize(max_payload_bytes + 1),
    );

    const canonical = try encode(std.testing.allocator, testMetadata(), "snapshot");
    defer std.testing.allocator.free(canonical);

    const hostile_payload_size = try std.testing.allocator.dupe(u8, canonical);
    defer std.testing.allocator.free(hostile_payload_size);
    putU64(hostile_payload_size, payload_size_offset, std.math.maxInt(u64));
    try std.testing.expectError(error.SavePayloadTooLarge, parse(hostile_payload_size));

    const hostile_total_size = try std.testing.allocator.dupe(u8, canonical);
    defer std.testing.allocator.free(hostile_total_size);
    putU64(hostile_total_size, total_size_offset, std.math.maxInt(u64));
    try std.testing.expectError(error.SaveEnvelopeTooLarge, parse(hostile_total_size));

    const inconsistent_total = try std.testing.allocator.dupe(u8, canonical);
    defer std.testing.allocator.free(inconsistent_total);
    putU64(inconsistent_total, total_size_offset, canonical.len - 1);
    try std.testing.expectError(error.SaveSizeMismatch, parse(inconsistent_total));
}

test "narrow limits cap payload and complete file independently" {
    const metadata = testMetadata();
    const payload = "12345678";
    const exact_file_size = header_size + payload.len + integrity_size;

    const bytes = try encodeWithLimits(std.testing.allocator, metadata, payload, .{
        .max_payload_bytes = payload.len,
        .max_file_bytes = exact_file_size,
    });
    defer std.testing.allocator.free(bytes);
    _ = try parseWithLimits(bytes, .{
        .max_payload_bytes = payload.len,
        .max_file_bytes = exact_file_size,
    });

    try std.testing.expectError(
        error.SavePayloadTooLarge,
        encodeWithLimits(std.testing.allocator, metadata, payload, .{
            .max_payload_bytes = payload.len - 1,
            .max_file_bytes = exact_file_size,
        }),
    );
    try std.testing.expectError(
        error.SaveEnvelopeTooLarge,
        encodeWithLimits(std.testing.allocator, metadata, payload, .{
            .max_payload_bytes = payload.len,
            .max_file_bytes = exact_file_size - 1,
        }),
    );
    try std.testing.expectError(
        error.InvalidSaveLimits,
        (Limits{ .max_payload_bytes = max_payload_bytes + 1 }).validate(),
    );
    try std.testing.expectError(
        error.InvalidSaveLimits,
        (Limits{ .max_file_bytes = header_size + integrity_size - 1 }).validate(),
    );
}
