//! Deterministic semantic network-fault adapter for MP3 validation. It models
//! effects visible above a reliable/unreliable message transport; it is not a
//! replacement implementation of GameNetworkingSockets.

const std = @import("std");
const budgets = @import("session_budgets");
const protocol = @import("session_protocol");
const transport = @import("session_transport_policy");

pub const Blackout = struct {
    first_tick: u64,
    end_tick: u64,

    pub fn contains(self: Blackout, tick: u64) bool {
        return tick >= self.first_tick and tick < self.end_tick;
    }
};

pub const Config = struct {
    seed: u64,
    one_way_latency_ticks: u16,
    jitter_ticks: u16,
    loss_per_10k: u16,
    duplicate_per_10k: u16,
    reorder_per_10k: u16,
    upstream_bytes_per_tick: u32 = 0,
    downstream_bytes_per_tick: u32 = 0,
    blackout: ?Blackout = null,

    pub fn fromProfile(seed: u64, profile: budgets.ImpairmentProfile) Config {
        return .{
            .seed = seed,
            .one_way_latency_ticks = millisecondsToTicksCeil(profile.rtt_ms / 2),
            .jitter_ticks = millisecondsToTicksCeil(profile.jitter_ms),
            .loss_per_10k = percentToPer10k(profile.loss_percent),
            .duplicate_per_10k = percentToPer10k(profile.duplicate_percent),
            .reorder_per_10k = percentToPer10k(profile.reorder_percent),
            .upstream_bytes_per_tick = @intCast(
                budgets.average_client_up_bytes_per_second / budgets.authority_tick_hz,
            ),
            .downstream_bytes_per_tick = @intCast(
                budgets.average_client_down_bytes_per_second / budgets.authority_tick_hz,
            ),
        };
    }

    pub fn validate(self: Config) !void {
        if (self.loss_per_10k > 10_000 or self.duplicate_per_10k > 10_000 or
            self.reorder_per_10k > 10_000)
        {
            return error.InvalidImpairmentProbability;
        }
        if (self.blackout) |blackout| {
            if (blackout.end_tick <= blackout.first_tick) return error.InvalidBlackout;
        }
    }
};

pub const DirectionDiagnostics = struct {
    sent_messages: u64 = 0,
    sent_bytes: u64 = 0,
    delivered_messages: u64 = 0,
    delivered_bytes: u64 = 0,
    lost_messages: u64 = 0,
    duplicated_messages: u64 = 0,
    reordered_messages: u64 = 0,
    blackout_drops: u64 = 0,
    bandwidth_deferrals: u64 = 0,
    queue_occupancy: u16 = 0,
    queue_high_water: u16 = 0,
    queue_overflows: u64 = 0,
};

pub const Diagnostics = struct {
    client_to_authority: DirectionDiagnostics,
    authority_to_client: DirectionDiagnostics,
};

fn ScheduledQueue(comptime Message: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();
        const Slot = struct {
            active: bool = false,
            message: Message = undefined,
            due_tick: u64 = 0,
            ordinal: u64 = 0,
            bytes: u32 = 0,
            class: transport.Class = undefined,
        };

        slots: [capacity]Slot = @splat(.{}),
        count: u16 = 0,
        next_ordinal: u64 = 0,
        last_reliable_due: [4]u64 = @splat(0),

        fn push(
            self: *Self,
            message: Message,
            due_tick_unordered: u64,
            bytes: u32,
            class: transport.Class,
        ) !void {
            var due_tick = due_tick_unordered;
            if (class.delivery == .reliable) {
                const lane_index: usize = @intFromEnum(class.lane);
                due_tick = @max(due_tick, self.last_reliable_due[lane_index]);
                self.last_reliable_due[lane_index] = due_tick;
            }
            for (&self.slots) |*slot| {
                if (slot.active) continue;
                self.next_ordinal +|= 1;
                slot.* = .{
                    .active = true,
                    .message = message,
                    .due_tick = due_tick,
                    .ordinal = self.next_ordinal,
                    .bytes = bytes,
                    .class = class,
                };
                self.count += 1;
                return;
            }
            return error.ImpairedLinkQueueFull;
        }

        fn earliestDue(self: *Self, now_tick: u64) ?*Slot {
            var selected: ?*Slot = null;
            for (&self.slots) |*slot| {
                if (!slot.active or slot.due_tick > now_tick) continue;
                if (selected == null or slot.due_tick < selected.?.due_tick or
                    (slot.due_tick == selected.?.due_tick and
                        slot.ordinal < selected.?.ordinal))
                {
                    selected = slot;
                }
            }
            return selected;
        }

        fn remove(self: *Self, slot: *Slot) Message {
            const message = slot.message;
            slot.active = false;
            self.count -= 1;
            return message;
        }
    };
}

const ClientQueue = ScheduledQueue(protocol.ClientMessage, budgets.inbound_message_capacity);
const ServerQueue = ScheduledQueue(
    protocol.DeliveredServerMessage,
    budgets.outbound_message_capacity,
);

pub const Link = struct {
    config: Config,
    tick: u64 = 0,
    client_send_index: u64 = 0,
    server_send_index: u64 = 0,
    client_queue: ClientQueue = .{},
    server_queue: *ServerQueue,
    client_diagnostics: DirectionDiagnostics = .{},
    server_diagnostics: DirectionDiagnostics = .{},
    upstream_budget_initialized: bool = false,
    upstream_budget_tick: u64 = 0,
    upstream_tokens: u64 = 0,
    downstream_budget_initialized: bool = false,
    downstream_budget_tick: u64 = 0,
    downstream_tokens: u64 = 0,

    pub fn init(config: Config) !Link {
        try config.validate();
        const server_queue = try std.heap.page_allocator.create(ServerQueue);
        server_queue.* = .{};
        return .{ .config = config, .server_queue = server_queue };
    }

    pub fn deinit(self: *Link) void {
        std.heap.page_allocator.destroy(self.server_queue);
        self.* = undefined;
    }

    pub fn advanceTo(self: *Link, tick: u64) !void {
        if (tick < self.tick) return error.ImpairedLinkTimeReversed;
        self.tick = tick;
    }

    pub fn sendFromClient(self: *Link, message: protocol.ClientMessage) !void {
        try protocol.validateClient(message);
        var storage: [budgets.max_wire_message_bytes]u8 = undefined;
        const size: u32 = @intCast((try protocol.encodeClient(message, &storage)).len);
        const class = transport.clientClass(message);
        try self.schedule(
            protocol.ClientMessage,
            &self.client_queue,
            &self.client_diagnostics,
            message,
            size,
            class,
            0,
            &self.client_send_index,
        );
    }

    pub fn sendFromAuthority(
        self: *Link,
        delivered: protocol.DeliveredServerMessage,
    ) !void {
        var storage: [budgets.max_wire_message_bytes]u8 = undefined;
        const size: u32 = @intCast((try protocol.encodeDeliveredServer(
            delivered,
            &storage,
        )).len);
        const class = transport.serverClass(delivered.message);
        try self.schedule(
            protocol.DeliveredServerMessage,
            self.server_queue,
            &self.server_diagnostics,
            delivered,
            size,
            class,
            1,
            &self.server_send_index,
        );
    }

    pub fn receiveForAuthority(self: *Link) ?protocol.ClientMessage {
        return self.receive(
            protocol.ClientMessage,
            &self.client_queue,
            &self.client_diagnostics,
            self.config.upstream_bytes_per_tick,
            &self.upstream_budget_initialized,
            &self.upstream_budget_tick,
            &self.upstream_tokens,
        );
    }

    pub fn receiveForClient(self: *Link) ?protocol.DeliveredServerMessage {
        return self.receive(
            protocol.DeliveredServerMessage,
            self.server_queue,
            &self.server_diagnostics,
            self.config.downstream_bytes_per_tick,
            &self.downstream_budget_initialized,
            &self.downstream_budget_tick,
            &self.downstream_tokens,
        );
    }

    pub fn diagnostics(self: *const Link) Diagnostics {
        var client = self.client_diagnostics;
        var server = self.server_diagnostics;
        client.queue_occupancy = self.client_queue.count;
        server.queue_occupancy = self.server_queue.count;
        return .{
            .client_to_authority = client,
            .authority_to_client = server,
        };
    }

    fn schedule(
        self: *Link,
        comptime Message: type,
        queue: anytype,
        direction_diagnostics: *DirectionDiagnostics,
        message: Message,
        bytes: u32,
        class: transport.Class,
        direction: u64,
        send_index: *u64,
    ) !void {
        direction_diagnostics.sent_messages +|= 1;
        direction_diagnostics.sent_bytes +|= bytes;
        send_index.* +|= 1;
        const index = send_index.*;
        const blackout = self.config.blackout;
        if (blackout != null and blackout.?.contains(self.tick) and
            class.delivery == .unreliable)
        {
            direction_diagnostics.lost_messages +|= 1;
            direction_diagnostics.blackout_drops +|= 1;
            return;
        }
        if (class.delivery == .unreliable and
            self.selected(direction, index, 1, self.config.loss_per_10k))
        {
            direction_diagnostics.lost_messages +|= 1;
            return;
        }

        var due = self.tick +| self.config.one_way_latency_ticks;
        due = applyJitter(self, due, direction, index);
        if (blackout) |range| {
            if (class.delivery == .reliable and due < range.end_tick and
                (range.contains(self.tick) or range.contains(due)))
            {
                due = range.end_tick;
            }
        }
        if (class.delivery == .unreliable and
            self.selected(direction, index, 2, self.config.reorder_per_10k))
        {
            due +|= @as(u64, self.config.jitter_ticks) + 1;
            direction_diagnostics.reordered_messages +|= 1;
        }
        queue.push(message, due, bytes, class) catch |err| {
            direction_diagnostics.queue_overflows +|= 1;
            return err;
        };
        direction_diagnostics.queue_high_water = @max(
            direction_diagnostics.queue_high_water,
            queue.count,
        );

        if (class.delivery == .unreliable and
            self.selected(direction, index, 3, self.config.duplicate_per_10k))
        {
            queue.push(message, due +| 1, bytes, class) catch |err| {
                direction_diagnostics.queue_overflows +|= 1;
                return err;
            };
            direction_diagnostics.duplicated_messages +|= 1;
            direction_diagnostics.queue_high_water = @max(
                direction_diagnostics.queue_high_water,
                queue.count,
            );
        }
    }

    fn receive(
        self: *Link,
        comptime Message: type,
        queue: anytype,
        direction_diagnostics: *DirectionDiagnostics,
        bytes_per_tick: u32,
        budget_initialized: *bool,
        budget_tick: *u64,
        tokens: *u64,
    ) ?Message {
        if (bytes_per_tick != 0 and !budget_initialized.*) {
            budget_initialized.* = true;
            budget_tick.* = self.tick;
            tokens.* = bytes_per_tick;
        } else if (bytes_per_tick != 0 and budget_tick.* != self.tick) {
            const elapsed = self.tick -| budget_tick.*;
            const replenished = tokens.* +| elapsed *| bytes_per_tick;
            tokens.* = @min(replenished, budgets.max_wire_message_bytes);
            budget_tick.* = self.tick;
        }
        while (queue.earliestDue(self.tick)) |slot| {
            if (self.config.blackout) |range| {
                if (range.contains(self.tick)) {
                    if (slot.class.delivery == .unreliable) {
                        _ = queue.remove(slot);
                        direction_diagnostics.lost_messages +|= 1;
                        direction_diagnostics.blackout_drops +|= 1;
                        continue;
                    }
                    slot.due_tick = range.end_tick;
                    continue;
                }
            }
            if (bytes_per_tick != 0 and tokens.* < slot.bytes) {
                slot.due_tick +|= 1;
                direction_diagnostics.bandwidth_deferrals +|= 1;
                continue;
            }
            if (bytes_per_tick != 0) tokens.* -= slot.bytes;
            direction_diagnostics.delivered_messages +|= 1;
            direction_diagnostics.delivered_bytes +|= slot.bytes;
            return queue.remove(slot);
        }
        return null;
    }

    fn selected(
        self: *const Link,
        direction: u64,
        index: u64,
        category: u64,
        threshold: u16,
    ) bool {
        if (threshold == 0) return false;
        if (threshold == 10_000) return true;
        var input = [4]u64{ self.config.seed, direction, index, category };
        const value = std.hash.Wyhash.hash(self.config.seed ^ category, std.mem.asBytes(&input));
        return value % 10_000 < threshold;
    }
};

fn applyJitter(link: *const Link, due: u64, direction: u64, index: u64) u64 {
    if (link.config.jitter_ticks == 0) return due;
    var input = [4]u64{ link.config.seed, direction, index, 0x4a4954544552 };
    const value = std.hash.Wyhash.hash(link.config.seed, std.mem.asBytes(&input));
    const span: u64 = @as(u64, link.config.jitter_ticks) * 2 + 1;
    const offset: i64 = @as(i64, @intCast(value % span)) - link.config.jitter_ticks;
    if (offset < 0) return due -| @as(u64, @intCast(-offset));
    return due +| @as(u64, @intCast(offset));
}

fn millisecondsToTicksCeil(milliseconds: u16) u16 {
    return @intCast((@as(u32, milliseconds) * budgets.authority_tick_hz + 999) / 1000);
}

fn percentToPer10k(percent: f32) u16 {
    return @intFromFloat(@round(std.math.clamp(percent, 0, 100) * 100));
}

fn testInput(sequence: u32) protocol.ClientMessage {
    return .{ .input = .{
        .session = .{ .value = 1 },
        .participant = .{ .index = 1, .generation = 1 },
        .sequence = .{ .value = sequence },
        .target_tick = sequence,
        .move = .{ 1, 0 },
        .facing_yaw = 0,
        .jump_pressed = false,
    } };
}

test "fault decisions and diagnostics repeat for the same seed" {
    const config = Config{
        .seed = 99,
        .one_way_latency_ticks = 2,
        .jitter_ticks = 2,
        .loss_per_10k = 2_000,
        .duplicate_per_10k = 1_000,
        .reorder_per_10k = 1_000,
    };
    var first = try Link.init(config);
    defer first.deinit();
    var second = try Link.init(config);
    defer second.deinit();
    for (1..50) |sequence| {
        try first.sendFromClient(testInput(@intCast(sequence)));
        try second.sendFromClient(testInput(@intCast(sequence)));
    }
    for (0..20) |tick| {
        try first.advanceTo(tick);
        try second.advanceTo(tick);
        while (first.receiveForAuthority()) |_| {}
        while (second.receiveForAuthority()) |_| {}
    }
    try std.testing.expectEqualDeep(first.diagnostics(), second.diagnostics());
    try std.testing.expect(first.diagnostics().client_to_authority.lost_messages != 0);
}

test "blackout drops unreliable traffic and delays reliable control" {
    var link = try Link.init(.{
        .seed = 1,
        .one_way_latency_ticks = 1,
        .jitter_ticks = 0,
        .loss_per_10k = 0,
        .duplicate_per_10k = 0,
        .reorder_per_10k = 0,
        .blackout = .{ .first_tick = 2, .end_tick = 5 },
    });
    defer link.deinit();
    try link.advanceTo(2);
    try link.sendFromClient(testInput(1));
    try link.sendFromClient(.{ .hello = .{ .account = .{ .value = 1 } } });
    try link.advanceTo(4);
    try std.testing.expect(link.receiveForAuthority() == null);
    try link.advanceTo(5);
    try std.testing.expect(link.receiveForAuthority().? == .hello);
    try std.testing.expectEqual(
        @as(u64, 1),
        link.diagnostics().client_to_authority.blackout_drops,
    );
}

test "directional bandwidth pressure defers into a fixed queue" {
    var link = try Link.init(.{
        .seed = 4,
        .one_way_latency_ticks = 0,
        .jitter_ticks = 0,
        .loss_per_10k = 0,
        .duplicate_per_10k = 0,
        .reorder_per_10k = 0,
        .upstream_bytes_per_tick = 1,
    });
    defer link.deinit();
    try link.sendFromClient(testInput(1));
    try link.sendFromClient(testInput(2));
    try std.testing.expect(link.receiveForAuthority() == null);
    try std.testing.expect(
        link.diagnostics().client_to_authority.bandwidth_deferrals != 0,
    );
    try link.advanceTo(64);
    try std.testing.expect(link.receiveForAuthority() != null);
    try std.testing.expect(link.receiveForAuthority() == null);
    try link.advanceTo(128);
    try std.testing.expect(link.receiveForAuthority() != null);
    try std.testing.expectEqual(
        @as(u16, 2),
        link.diagnostics().client_to_authority.queue_high_water,
    );
}
