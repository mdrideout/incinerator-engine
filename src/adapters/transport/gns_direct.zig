//! Narrow Zig owner for the open-source GameNetworkingSockets direct-IP path.
//! GNS handles and callbacks end here; session code receives copied bytes and
//! typed lifecycle events.

const std = @import("std");
const budgets = @import("session_budgets");

const c = @cImport({
    @cInclude("gns_c_api.h");
});

pub const Connection = struct {
    value: u32,

    pub const invalid = Connection{ .value = 0 };
    pub fn isValid(self: Connection) bool {
        return self.value != 0;
    }
};

pub const ListenSocket = struct {
    value: u32,

    pub const invalid = ListenSocket{ .value = 0 };
    pub fn isValid(self: ListenSocket) bool {
        return self.value != 0;
    }
};

pub const ListenScope = enum { loopback, any_interface };

pub const State = enum {
    none,
    connecting,
    finding_route,
    connected,
    closed_by_peer,
    problem_detected_locally,
};

pub const Lane = enum(u16) {
    input = 0,
    snapshot = 1,
    gameplay = 2,
    control = 3,
};

pub const Delivery = enum { unreliable, reliable };
pub const CloseMode = enum { immediate, linger };

pub const Event = struct {
    connection: Connection,
    listen_socket: ListenSocket,
    old_state: State,
    new_state: State,
    end_reason: i32,
    debug: [128]u8,

    pub fn debugText(self: *const Event) []const u8 {
        return std.mem.sliceTo(&self.debug, 0);
    }
};

pub const Stats = struct {
    ping_ms: i32,
    connection_quality_local: f32,
    connection_quality_remote: f32,
    out_packets_per_second: f32,
    out_bytes_per_second: f32,
    in_packets_per_second: f32,
    in_bytes_per_second: f32,
    pending_unreliable_bytes: i32,
    pending_reliable_bytes: i32,
    sent_unacked_reliable_bytes: i32,
    queue_time_microseconds: i64,
};

pub const Received = struct {
    bytes: []const u8,
    delivery: Delivery,
    lane: Lane,
};

pub const Network = struct {
    initialized: bool,

    pub fn init() !Network {
        var error_text: [1024]u8 = @splat(0);
        if (!c.inc_gns_init(&error_text, error_text.len)) {
            std.debug.print("GameNetworkingSockets init failed: {s}\n", .{
                std.mem.sliceTo(&error_text, 0),
            });
            return error.GameNetworkingSocketsInitFailed;
        }
        return .{ .initialized = true };
    }

    pub fn deinit(self: *Network) void {
        if (self.initialized) c.inc_gns_shutdown();
        self.* = undefined;
    }

    pub fn listen(self: *Network, port: u16, scope: ListenScope) !ListenSocket {
        self.assertInitialized();
        const socket = ListenSocket{
            .value = c.inc_gns_listen(port, scope == .loopback),
        };
        if (!socket.isValid()) return error.GameNetworkingSocketsListenFailed;
        return socket;
    }

    pub fn closeListen(self: *Network, socket: ListenSocket) void {
        self.assertInitialized();
        if (socket.isValid()) _ = c.inc_gns_close_listen(socket.value);
    }

    pub fn connect(self: *Network, endpoint: [:0]const u8) !Connection {
        self.assertInitialized();
        const connection = Connection{ .value = c.inc_gns_connect(endpoint.ptr) };
        if (!connection.isValid()) return error.InvalidOrUnavailableEndpoint;
        return connection;
    }

    pub fn runCallbacks(self: *Network) void {
        self.assertInitialized();
        c.inc_gns_run_callbacks();
    }

    pub fn pollEvent(self: *Network) ?Event {
        self.assertInitialized();
        var raw: c.IncGnsEvent = undefined;
        if (!c.inc_gns_poll_event(&raw)) return null;
        var result = Event{
            .connection = .{ .value = raw.connection },
            .listen_socket = .{ .value = raw.listen_socket },
            .old_state = state(raw.old_state) catch .none,
            .new_state = state(raw.new_state) catch .none,
            .end_reason = raw.end_reason,
            .debug = @splat(0),
        };
        const source = std.mem.sliceTo(&raw.debug, 0);
        @memcpy(result.debug[0..source.len], source);
        return result;
    }

    pub fn droppedEvents(self: *const Network) u64 {
        self.assertInitialized();
        return c.inc_gns_dropped_events();
    }

    pub fn accept(self: *Network, connection: Connection) !void {
        self.assertInitialized();
        if (!connection.isValid() or !c.inc_gns_accept(connection.value)) {
            return error.GameNetworkingSocketsAcceptFailed;
        }
        if (!c.inc_gns_configure_lanes(connection.value)) {
            return error.GameNetworkingSocketsLaneConfigurationFailed;
        }
    }

    pub fn configureConnected(self: *Network, connection: Connection) !void {
        self.assertInitialized();
        if (!connection.isValid() or !c.inc_gns_configure_lanes(connection.value)) {
            return error.GameNetworkingSocketsLaneConfigurationFailed;
        }
    }

    pub fn close(
        self: *Network,
        connection: Connection,
        reason: i32,
        debug: [:0]const u8,
        mode: CloseMode,
    ) void {
        self.assertInitialized();
        if (connection.isValid()) {
            _ = c.inc_gns_close(connection.value, reason, debug.ptr, mode == .linger);
        }
    }

    pub fn send(
        self: *Network,
        connection: Connection,
        bytes: []const u8,
        delivery: Delivery,
        lane: Lane,
    ) !void {
        self.assertInitialized();
        if (!connection.isValid()) return error.InvalidConnection;
        if (bytes.len == 0 or bytes.len > budgets.max_wire_message_bytes) {
            return error.InvalidMessageSize;
        }
        const result = c.inc_gns_send(
            connection.value,
            bytes.ptr,
            @intCast(bytes.len),
            delivery == .reliable,
            @intFromEnum(lane),
        );
        if (result <= 0) return error.GameNetworkingSocketsSendFailed;
    }

    pub fn receive(
        self: *Network,
        connection: Connection,
        storage: []u8,
    ) !?Received {
        self.assertInitialized();
        if (!connection.isValid()) return error.InvalidConnection;
        if (storage.len > std.math.maxInt(u32)) return error.ReceiveStorageTooLarge;
        var size: u32 = 0;
        var reliable = false;
        var raw_lane: u16 = 0;
        const result = c.inc_gns_receive(
            connection.value,
            storage.ptr,
            @intCast(storage.len),
            &size,
            &reliable,
            &raw_lane,
        );
        if (result == 0) return null;
        if (result == -2) return error.ReceivedMessageTooLarge;
        if (result < 0) return error.GameNetworkingSocketsReceiveFailed;
        if (size > storage.len) return error.GameNetworkingSocketsReceiveContractViolated;
        const lane: Lane = switch (raw_lane) {
            0 => .input,
            1 => .snapshot,
            2 => .gameplay,
            3 => .control,
            else => return error.InvalidLane,
        };
        return .{
            .bytes = storage[0..size],
            .delivery = if (reliable) .reliable else .unreliable,
            .lane = lane,
        };
    }

    pub fn stats(self: *Network, connection: Connection) ?Stats {
        self.assertInitialized();
        var raw: c.IncGnsStats = undefined;
        if (!connection.isValid() or !c.inc_gns_stats(connection.value, &raw)) return null;
        return .{
            .ping_ms = raw.ping_ms,
            .connection_quality_local = raw.connection_quality_local,
            .connection_quality_remote = raw.connection_quality_remote,
            .out_packets_per_second = raw.out_packets_per_second,
            .out_bytes_per_second = raw.out_bytes_per_second,
            .in_packets_per_second = raw.in_packets_per_second,
            .in_bytes_per_second = raw.in_bytes_per_second,
            .pending_unreliable_bytes = raw.pending_unreliable_bytes,
            .pending_reliable_bytes = raw.pending_reliable_bytes,
            .sent_unacked_reliable_bytes = raw.sent_unacked_reliable_bytes,
            .queue_time_microseconds = raw.queue_time_microseconds,
        };
    }

    fn assertInitialized(self: *const Network) void {
        std.debug.assert(self.initialized);
    }
};

fn state(value: i32) !State {
    return switch (value) {
        c.INC_GNS_NONE => .none,
        c.INC_GNS_CONNECTING => .connecting,
        c.INC_GNS_FINDING_ROUTE => .finding_route,
        c.INC_GNS_CONNECTED => .connected,
        c.INC_GNS_CLOSED_BY_PEER => .closed_by_peer,
        c.INC_GNS_PROBLEM_DETECTED_LOCALLY => .problem_detected_locally,
        else => error.UnknownConnectionState,
    };
}

test "lane and delivery policy remain explicit" {
    try std.testing.expectEqual(@as(u16, 0), @intFromEnum(Lane.input));
    try std.testing.expectEqual(@as(u16, 1), @intFromEnum(Lane.snapshot));
    try std.testing.expect(Delivery.reliable != .unreliable);
}
