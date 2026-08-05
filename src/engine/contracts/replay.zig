//! Backend-neutral canonical hashing contracts for same-cohort replay.
//!
//! The writer hashes a deliberately framed byte stream supplied by its caller.
//! Integers and floats have an explicit little-endian representation; Zig
//! aggregate layout, enum layout, padding, pointers, and allocator state never
//! enter the stream. `writeBytes` writes raw bytes and does not add a length, so
//! a domain encoder must write its own length or otherwise provide framing.

const std = @import("std");

pub const Digest = [32]u8;

/// Stable category identifiers used by per-tick divergence reports. Zero is
/// intentionally left unassigned so an all-zero/corrupt tag is never valid.
pub const Category = enum(u8) {
    runtime = 1,
    crate = 2,
    character = 3,
    vehicle = 4,
    district = 5,
    interaction = 6,
    npc = 7,
    npc_encounter = 8,
    population = 9,
};

/// Canonical logical hashes captured after one successfully completed tick.
pub const TickDigests = struct {
    tick_index: u64,
    runtime: Digest,
    crate: Digest,
    character: Digest,
    vehicle: Digest,
    district: Digest,
    interaction: Digest,
    npc: Digest,
    npc_encounter: Digest,
    population: Digest,

    pub fn get(self: TickDigests, category: Category) Digest {
        return switch (category) {
            .runtime => self.runtime,
            .crate => self.crate,
            .character => self.character,
            .vehicle => self.vehicle,
            .district => self.district,
            .interaction => self.interaction,
            .npc => self.npc,
            .npc_encounter => self.npc_encounter,
            .population => self.population,
        };
    }
};

/// Collapse the two IEEE-754 zero encodings to positive zero while rejecting
/// infinities and NaNs. Other finite values retain their exact f32 bits.
pub fn canonicalF32(value: f32) !f32 {
    if (!std.math.isFinite(value)) return error.NonFiniteFloat;
    return if (value == 0) 0 else value;
}

/// Validate bytes read from a canonical replay envelope. Unlike the writer,
/// which accepts and normalizes negative zero, a decoder uses this function to
/// reject a non-unique wire encoding.
pub fn validateCanonicalF32(value: f32) !void {
    const canonical = try canonicalF32(value);
    if (@as(u32, @bitCast(value)) != @as(u32, @bitCast(canonical))) {
        return error.NonCanonicalFloat;
    }
}

/// Incremental canonical SHA-256 writer. Primitive methods never serialize a
/// native aggregate and therefore have the same byte meaning on every host.
pub const Writer = struct {
    hash: std.crypto.hash.sha2.Sha256,

    pub fn init() Writer {
        return .{ .hash = std.crypto.hash.sha2.Sha256.init(.{}) };
    }

    pub fn writeU8(self: *Writer, value: u8) void {
        self.hash.update(&.{value});
    }

    pub fn writeU16(self: *Writer, value: u16) void {
        var bytes: [2]u8 = undefined;
        std.mem.writeInt(u16, &bytes, value, .little);
        self.hash.update(&bytes);
    }

    pub fn writeU32(self: *Writer, value: u32) void {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, value, .little);
        self.hash.update(&bytes);
    }

    pub fn writeU64(self: *Writer, value: u64) void {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, value, .little);
        self.hash.update(&bytes);
    }

    pub fn writeI32(self: *Writer, value: i32) void {
        self.writeU32(@bitCast(value));
    }

    pub fn writeF32(self: *Writer, value: f32) !void {
        const canonical = try canonicalF32(value);
        self.writeU32(@bitCast(canonical));
    }

    pub fn writeBool(self: *Writer, value: bool) void {
        self.writeU8(if (value) 1 else 0);
    }

    pub fn writeBytes(self: *Writer, bytes: []const u8) void {
        self.hash.update(bytes);
    }

    pub fn final(self: *Writer) Digest {
        var digest: Digest = undefined;
        self.hash.final(&digest);
        return digest;
    }
};

test "canonical writer has a stable little-endian primitive golden digest" {
    var writer = Writer.init();
    writer.writeU8(0xa5);
    writer.writeU16(0x1234);
    writer.writeU32(0x89ab_cdef);
    writer.writeU64(0x0123_4567_89ab_cdef);
    writer.writeI32(-2);
    try writer.writeF32(1.5);
    writer.writeBool(true);
    writer.writeBool(false);
    writer.writeBytes(&.{ 0xde, 0xad });

    const expected = Digest{
        0x32, 0x77, 0xa6, 0xc3, 0x42, 0xa5, 0xb6, 0xc1,
        0x08, 0x14, 0xe6, 0x08, 0x1f, 0xa6, 0xfa, 0x68,
        0xb5, 0x3e, 0x35, 0x51, 0x2c, 0x02, 0xda, 0xa3,
        0x11, 0xb4, 0x99, 0x20, 0x3f, 0x36, 0x7b, 0x0f,
    };
    try std.testing.expectEqual(expected, writer.final());
}

test "f32 hashing collapses signed zero and preserves finite nonzero bits" {
    const negative_zero: f32 = @bitCast(@as(u32, 0x8000_0000));
    try std.testing.expectEqual(@as(u32, 0), @as(u32, @bitCast(try canonicalF32(negative_zero))));

    var positive = Writer.init();
    try positive.writeF32(0.0);
    var negative = Writer.init();
    try negative.writeF32(negative_zero);
    try std.testing.expectEqual(positive.final(), negative.final());

    const finite: f32 = @bitCast(@as(u32, 0x3eaa_aaab));
    try std.testing.expectEqual(
        @as(u32, @bitCast(finite)),
        @as(u32, @bitCast(try canonicalF32(finite))),
    );
}

test "canonical f32 validation rejects non-finite and negative-zero encodings" {
    try validateCanonicalF32(0.0);
    try validateCanonicalF32(-17.25);

    const negative_zero: f32 = @bitCast(@as(u32, 0x8000_0000));
    try std.testing.expectError(error.NonCanonicalFloat, validateCanonicalF32(negative_zero));
    try std.testing.expectError(error.NonFiniteFloat, validateCanonicalF32(std.math.inf(f32)));
    try std.testing.expectError(error.NonFiniteFloat, validateCanonicalF32(std.math.nan(f32)));

    var writer = Writer.init();
    try std.testing.expectError(error.NonFiniteFloat, writer.writeF32(std.math.inf(f32)));
    try std.testing.expectError(error.NonFiniteFloat, writer.writeF32(std.math.nan(f32)));
}

test "tick digest categories have stable tags and exact field routing" {
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(Category.runtime));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(Category.crate));
    try std.testing.expectEqual(@as(u8, 3), @intFromEnum(Category.character));
    try std.testing.expectEqual(@as(u8, 4), @intFromEnum(Category.vehicle));
    try std.testing.expectEqual(@as(u8, 5), @intFromEnum(Category.district));
    try std.testing.expectEqual(@as(u8, 6), @intFromEnum(Category.interaction));
    try std.testing.expectEqual(@as(u8, 7), @intFromEnum(Category.npc));
    try std.testing.expectEqual(@as(u8, 8), @intFromEnum(Category.npc_encounter));
    try std.testing.expectEqual(@as(u8, 9), @intFromEnum(Category.population));

    const values = TickDigests{
        .tick_index = 44,
        .runtime = [_]u8{1} ** 32,
        .crate = [_]u8{2} ** 32,
        .character = [_]u8{3} ** 32,
        .vehicle = [_]u8{4} ** 32,
        .district = [_]u8{5} ** 32,
        .interaction = [_]u8{6} ** 32,
        .npc = [_]u8{7} ** 32,
        .npc_encounter = [_]u8{8} ** 32,
        .population = [_]u8{9} ** 32,
    };
    try std.testing.expectEqual(@as(u64, 44), values.tick_index);
    try std.testing.expectEqual(values.runtime, values.get(.runtime));
    try std.testing.expectEqual(values.crate, values.get(.crate));
    try std.testing.expectEqual(values.character, values.get(.character));
    try std.testing.expectEqual(values.vehicle, values.get(.vehicle));
    try std.testing.expectEqual(values.district, values.get(.district));
    try std.testing.expectEqual(values.interaction, values.get(.interaction));
    try std.testing.expectEqual(values.npc, values.get(.npc));
    try std.testing.expectEqual(values.npc_encounter, values.get(.npc_encounter));
    try std.testing.expectEqual(values.population, values.get(.population));
}
