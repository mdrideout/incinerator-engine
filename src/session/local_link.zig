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
    protocol.DeliveredServerMessage,
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

    pub fn sendFromAuthority(
        self: *Link,
        delivered: protocol.DeliveredServerMessage,
    ) !void {
        protocol.validateServer(delivered.message) catch |err| {
            self.rejected_server_messages +|= 1;
            return err;
        };
        self.authority_to_client.push(delivered) catch {
            self.rejected_server_messages +|= 1;
            return error.LocalServerQueueFull;
        };
        self.server_high_water = @max(
            self.server_high_water,
            @as(u32, @intCast(self.authority_to_client.len)),
        );
    }

    pub fn receiveForClient(self: *Link) ?protocol.DeliveredServerMessage {
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
    try link.sendFromAuthority(.{ .message = .{ .rejected = .{ .reason = .unauthorized } } });
    try std.testing.expect(link.receiveForClient().?.message == .rejected);
    const diagnostics = link.diagnostics();
    try std.testing.expectEqual(@as(u32, 1), diagnostics.client_to_authority_high_water);
    try std.testing.expectEqual(@as(u32, 1), diagnostics.authority_to_client_high_water);
}

test "local link rejects server messages outside the shared semantic contract" {
    var link = Link{};
    var invalid = protocol.Snapshot.empty();
    invalid.sequence.value = 1;
    invalid.npc_count = 1;

    try std.testing.expectError(
        error.InvalidNpcProjection,
        link.sendFromAuthority(.{ .message = .{ .snapshot = invalid } }),
    );
    try std.testing.expect(link.receiveForClient() == null);
    const diagnostics = link.diagnostics();
    try std.testing.expectEqual(@as(u64, 1), diagnostics.rejected_server_messages);
    try std.testing.expectEqual(@as(u32, 0), diagnostics.authority_to_client_occupancy);
}

test "local link rejects duplicate replicated identities without enqueueing" {
    var invalid = protocol.Snapshot.empty();
    invalid.sequence.value = 1;
    const entity: @FieldType(protocol.CharacterState, "entity") =
        .{ .index = 7, .generation = 1 };
    invalid.character_count = 1;
    invalid.characters[0] = .{
        .entity = entity,
        .owner = .{ .index = 1, .generation = 1 },
        .position = .{ 0, 0, 0 },
        .velocity = .{ 0, 0, 0 },
        .facing_yaw = 0,
    };
    invalid.carryable_count = 1;
    invalid.carryables[0] = .{
        .entity = entity,
        .position = .{ 0, 0.5, 0 },
        .rotation = .{ 0, 0, 0, 1 },
        .linear_velocity = .{ 0, 0, 0 },
        .angular_velocity = .{ 0, 0, 0 },
        .half_extents = .{ 0.25, 0.25, 0.25 },
        .holder = null,
    };

    var link = Link{};
    try std.testing.expectError(
        error.DuplicateActiveProjectionEntity,
        link.sendFromAuthority(.{ .message = .{ .snapshot = invalid } }),
    );
    try std.testing.expect(link.receiveForClient() == null);
    const diagnostics = link.diagnostics();
    try std.testing.expectEqual(@as(u64, 1), diagnostics.rejected_server_messages);
    try std.testing.expectEqual(@as(u32, 0), diagnostics.authority_to_client_occupancy);
}

test "local link rejects impossible snapshot and action semantics before enqueueing" {
    var link = Link{};

    var invalid_snapshot = protocol.Snapshot.empty();
    try std.testing.expectError(
        error.InvalidSnapshotSequence,
        link.sendFromAuthority(.{ .message = .{ .snapshot = invalid_snapshot } }),
    );
    invalid_snapshot.sequence.value = 1;
    invalid_snapshot.vehicle_count = 1;
    invalid_snapshot.vehicles[0] = .{
        .entity = .{ .index = 17, .generation = 1 },
        .position = .{ 0, 1, 0 },
        .rotation = .{ 0, 0, 0, 0 },
        .linear_velocity = .{ 0, 0, 0 },
        .angular_velocity = .{ 0, 0, 0 },
        .driver = null,
    };
    try std.testing.expectError(
        error.DegenerateQuaternion,
        link.sendFromAuthority(.{ .message = .{ .snapshot = invalid_snapshot } }),
    );
    try std.testing.expectError(
        error.InvalidVehicleActionResultDisposition,
        link.sendFromAuthority(.{ .message = .{ .vehicle_action_result = .{
            .sequence = .{ .value = 1 },
            .vehicle = .{ .index = 17, .generation = 1 },
            .action = .enter,
            .disposition = .exited,
        } } }),
    );

    try std.testing.expect(link.receiveForClient() == null);
    const diagnostics = link.diagnostics();
    try std.testing.expectEqual(@as(u64, 3), diagnostics.rejected_server_messages);
    try std.testing.expectEqual(@as(u32, 0), diagnostics.authority_to_client_occupancy);
}
