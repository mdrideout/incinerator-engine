//! Versioned, bounded configuration for the macOS server-shaped host.
//!
//! Configuration is parsed and validated before content, storage, Flecs, or
//! Jolt authority is acquired. Unknown JSON fields are rejected by the
//! standard parser so a misspelled operational policy never becomes a silent
//! default.

const std = @import("std");

pub const schema_version: u16 = 1;
pub const max_config_bytes: usize = 64 * 1024;
pub const content_digest_bytes: usize = 32;
pub const content_digest_hex_bytes: usize = content_digest_bytes * 2;

pub const StartPolicy = enum {
    fresh,
    restore_required,
    fresh_or_restore,
};

pub const ClockMode = enum {
    real_time,
    virtual,
};

pub const World = struct {
    namespace: u64,
    max_crates: u32,
    max_characters: u16,
    max_vehicles: u16,
    max_npcs: u16,
};

pub const Clock = struct {
    mode: ClockMode,
    /// A required nonzero schema field and the target for reproducible virtual
    /// time. Real-time mode validates but does not consume the value; shutdown
    /// there is signal or policy driven.
    virtual_ticks: u64,
    max_catch_up_ticks: u16,
    soft_lag_ticks: u16,
    hard_lag_ticks: u16,
};

pub const Shutdown = struct {
    drain_tick_budget: u16,
};

pub const Producers = struct {
    max_registered: u8,
    per_producer_quota: u8,
    ingress_capacity: u16,
    transaction_capacity: u16,
    result_capacity_per_producer: u8,
};

pub const ConfigV1 = struct {
    schema_version: u16,
    world: World,
    expected_content_cohort: []const u8,
    save_root: []const u8,
    save_slot: []const u8,
    start_policy: StartPolicy,
    clock: Clock,
    shutdown: Shutdown,
    producers: Producers,

    pub fn validate(self: ConfigV1) !void {
        if (self.schema_version != schema_version) {
            return error.UnsupportedHeadlessConfigSchema;
        }
        if (self.world.namespace == 0 or self.world.max_crates == 0 or
            self.world.max_crates > 1024 or self.world.max_characters == 0 or
            self.world.max_characters > 64 or self.world.max_vehicles == 0 or
            self.world.max_vehicles > 64 or self.world.max_npcs != 64)
        {
            return error.InvalidHeadlessWorldLimits;
        }
        _ = try decodeDigest(self.expected_content_cohort);
        if (self.save_root.len == 0 or self.save_root.len > 1024 or
            !std.fs.path.isAbsolute(self.save_root) or
            std.mem.indexOfScalar(u8, self.save_root, 0) != null)
        {
            return error.InvalidHeadlessSaveRoot;
        }
        try validateSlot(self.save_slot);

        if (self.clock.virtual_ticks == 0 or self.clock.max_catch_up_ticks == 0 or
            self.clock.soft_lag_ticks == 0 or self.clock.hard_lag_ticks == 0 or
            self.clock.max_catch_up_ticks > self.clock.soft_lag_ticks or
            self.clock.soft_lag_ticks > self.clock.hard_lag_ticks)
        {
            return error.InvalidHeadlessClockPolicy;
        }
        if (self.shutdown.drain_tick_budget == 0) {
            return error.InvalidHeadlessShutdownPolicy;
        }

        // These values are a versioned product contract, not knobs that can
        // silently exceed the fixed storage compiled into the M3 router.
        if (self.producers.max_registered != 2 or
            self.producers.per_producer_quota != 8 or
            self.producers.ingress_capacity != 16 or
            self.producers.transaction_capacity != 16 or
            self.producers.result_capacity_per_producer != 8)
        {
            return error.IncompatibleHeadlessProducerLimits;
        }
    }

    pub fn contentDigest(self: ConfigV1) ![content_digest_bytes]u8 {
        return decodeDigest(self.expected_content_cohort);
    }
};

pub const Parsed = std.json.Parsed(ConfigV1);

pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !Parsed {
    if (bytes.len == 0 or bytes.len > max_config_bytes) {
        return error.HeadlessConfigSizeOutOfRange;
    }
    var parsed = try std.json.parseFromSlice(ConfigV1, allocator, bytes, .{});
    errdefer parsed.deinit();
    try parsed.value.validate();
    return parsed;
}

pub fn decodeDigest(hex: []const u8) ![content_digest_bytes]u8 {
    if (hex.len != content_digest_hex_bytes) return error.InvalidContentDigest;
    var digest: [content_digest_bytes]u8 = undefined;
    for (0..content_digest_bytes) |index| {
        const high = hexNibble(hex[index * 2]) orelse return error.InvalidContentDigest;
        const low = hexNibble(hex[index * 2 + 1]) orelse return error.InvalidContentDigest;
        digest[index] = (high << 4) | low;
    }
    return digest;
}

fn hexNibble(value: u8) ?u8 {
    return switch (value) {
        '0'...'9' => value - '0',
        'a'...'f' => value - 'a' + 10,
        else => null,
    };
}

fn validateSlot(slot: []const u8) !void {
    if (slot.len == 0 or slot.len > 32) return error.InvalidHeadlessSaveSlot;
    for (slot) |byte| {
        const valid = (byte >= 'a' and byte <= 'z') or
            (byte >= '0' and byte <= '9') or byte == '_' or byte == '-';
        if (!valid) return error.InvalidHeadlessSaveSlot;
    }
}

const valid_config =
    \\{
    \\  "schema_version": 1,
    \\  "world": {"namespace": 9, "max_crates": 128, "max_characters": 1, "max_vehicles": 1, "max_npcs": 64},
    \\  "expected_content_cohort": "83d3376f8bd4f0d23525921e4b2445e4fd09ee22282573d745eaf7428ba19ef0",
    \\  "save_root": "/tmp/incinerator-headless-test",
    \\  "save_slot": "world-1",
    \\  "start_policy": "fresh_or_restore",
    \\  "clock": {"mode": "virtual", "virtual_ticks": 16384, "max_catch_up_ticks": 8, "soft_lag_ticks": 8, "hard_lag_ticks": 120},
    \\  "shutdown": {"drain_tick_budget": 256},
    \\  "producers": {"max_registered": 2, "per_producer_quota": 8, "ingress_capacity": 16, "transaction_capacity": 16, "result_capacity_per_producer": 8}
    \\}
;

test "valid V1 configuration is exact and owns parsed strings" {
    var parsed = try parse(std.testing.allocator, valid_config);
    defer parsed.deinit();
    try std.testing.expectEqual(schema_version, parsed.value.schema_version);
    try std.testing.expectEqual(ClockMode.virtual, parsed.value.clock.mode);
    try std.testing.expectEqual(@as(u16, 64), parsed.value.world.max_npcs);
    const digest = try parsed.value.contentDigest();
    try std.testing.expectEqual(@as(u8, 0x83), digest[0]);
    try std.testing.expectEqual(@as(u8, 0xf0), digest[digest.len - 1]);
}

test "configuration rejects unknown fields and every incompatible boundary" {
    try std.testing.expectError(
        error.UnknownField,
        parse(std.testing.allocator,
            \\{"schema_version":1,"unknown":true}
        ),
    );
    var parsed = try parse(std.testing.allocator, valid_config);
    defer parsed.deinit();

    var value = parsed.value;
    value.schema_version = 2;
    try std.testing.expectError(error.UnsupportedHeadlessConfigSchema, value.validate());
    value = parsed.value;
    value.world.max_npcs = 63;
    try std.testing.expectError(error.InvalidHeadlessWorldLimits, value.validate());
    value = parsed.value;
    value.expected_content_cohort = "ABC";
    try std.testing.expectError(error.InvalidContentDigest, value.validate());
    value = parsed.value;
    value.save_root = "relative";
    try std.testing.expectError(error.InvalidHeadlessSaveRoot, value.validate());
    value = parsed.value;
    value.save_slot = "../escape";
    try std.testing.expectError(error.InvalidHeadlessSaveSlot, value.validate());
    value = parsed.value;
    value.clock.soft_lag_ticks = 121;
    try std.testing.expectError(error.InvalidHeadlessClockPolicy, value.validate());
    value = parsed.value;
    value.producers.ingress_capacity = 15;
    try std.testing.expectError(error.IncompatibleHeadlessProducerLimits, value.validate());
}
