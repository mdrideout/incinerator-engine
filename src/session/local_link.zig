//! In-process typed session link. It avoids byte encoding and artificial
//! latency, but it does not bypass identity, admission, sequencing, or bounds.

const std = @import("std");
const engine = @import("incinerator_engine");
const budgets = @import("session_budgets");
const protocol = @import("session_protocol");

const ClientQueue = engine.BoundedQueue(
    protocol.ClientMessage,
    budgets.inbound_message_capacity,
);
const ServerQueue = engine.BoundedQueue(
    protocol.ServerMessage,
    budgets.outbound_message_capacity,
);

pub const Diagnostics = struct {
    client_to_authority_occupancy: u32,
    authority_to_client_occupancy: u32,
    client_to_authority_high_water: u32,
    authority_to_client_high_water: u32,
    rejected_client_messages: u64,
    rejected_server_messages: u64,
};

pub const Link = struct {
    client_to_authority: ClientQueue = .{},
    authority_to_client: ServerQueue = .{},
    client_high_water: u32 = 0,
    server_high_water: u32 = 0,
    rejected_client_messages: u64 = 0,
    rejected_server_messages: u64 = 0,

    pub fn sendFromClient(self: *Link, message: protocol.ClientMessage) !void {
        protocol.validateClient(message) catch |err| {
            self.rejected_client_messages +|= 1;
            return err;
        };
        self.client_to_authority.push(message) catch {
            self.rejected_client_messages +|= 1;
            return error.LocalClientQueueFull;
        };
        self.client_high_water = @max(
            self.client_high_water,
            @as(u32, @intCast(self.client_to_authority.len)),
        );
    }

    pub fn receiveForAuthority(self: *Link) ?protocol.ClientMessage {
        return self.client_to_authority.pop();
    }

    pub fn sendFromAuthority(self: *Link, message: protocol.ServerMessage) !void {
        self.authority_to_client.push(message) catch {
            self.rejected_server_messages +|= 1;
            return error.LocalServerQueueFull;
        };
        self.server_high_water = @max(
            self.server_high_water,
            @as(u32, @intCast(self.authority_to_client.len)),
        );
    }

    pub fn receiveForClient(self: *Link) ?protocol.ServerMessage {
        return self.authority_to_client.pop();
    }

    pub fn diagnostics(self: *const Link) Diagnostics {
        return .{
            .client_to_authority_occupancy = @intCast(self.client_to_authority.len),
            .authority_to_client_occupancy = @intCast(self.authority_to_client.len),
            .client_to_authority_high_water = self.client_high_water,
            .authority_to_client_high_water = self.server_high_water,
            .rejected_client_messages = self.rejected_client_messages,
            .rejected_server_messages = self.rejected_server_messages,
        };
    }
};

test "local link is typed bounded FIFO in both directions" {
    var link = Link{};
    try link.sendFromClient(.{ .hello = .{ .account = .{ .value = 7 } } });
    try std.testing.expect(link.receiveForAuthority().? == .hello);
    try link.sendFromAuthority(.{ .rejected = .{ .reason = .unauthorized } });
    try std.testing.expect(link.receiveForClient().? == .rejected);
    const diagnostics = link.diagnostics();
    try std.testing.expectEqual(@as(u32, 1), diagnostics.client_to_authority_high_water);
    try std.testing.expectEqual(@as(u32, 1), diagnostics.authority_to_client_high_water);
}
