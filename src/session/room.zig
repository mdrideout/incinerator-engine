//! Open-engine MP5 room, invite, and instance-placement state.
//! Discovery state selects an authority route; it never owns gameplay state.

const std = @import("std");
const budgets = @import("session_budgets");
const identity = @import("session_identity");
const protocol = @import("session_protocol");

pub const max_rooms: usize = 8;
pub const max_endpoint_bytes: usize = 128;

pub const Placement = enum { embedded, listen, dedicated };

pub const DirectEndpoint = struct {
    len: u8,
    bytes: [max_endpoint_bytes]u8,

    pub fn init(text: []const u8) !DirectEndpoint {
        if (text.len == 0 or text.len > max_endpoint_bytes) return error.InvalidEndpoint;
        var result = DirectEndpoint{ .len = @intCast(text.len), .bytes = @splat(0) };
        @memcpy(result.bytes[0..text.len], text);
        return result;
    }

    pub fn slice(self: *const DirectEndpoint) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const Route = union(enum) {
    local,
    direct_ip: DirectEndpoint,
    /// Opaque provider join reference. Steam types and SDK material remain in
    /// the optional adapter, not this open-engine contract.
    steam: u64,
};

pub const RoomId = struct {
    value: u64,

    pub fn validate(self: RoomId) !void {
        if (self.value == 0) return error.InvalidRoomId;
    }
};

pub const Handle = struct {
    index: u8,
    generation: u16,
};

pub const Config = struct {
    id: RoomId,
    authority_id: u64,
    placement: Placement,
    route: Route,
    host: identity.AccountId,
    secret: protocol.AdmissionSecret,
};

pub const Invite = struct {
    account: identity.AccountId,
    external_identity: protocol.ExternalIdentity,
    placement: Placement,
    route: Route,
    authorization: protocol.JoinAuthorization,
};

pub const JoinIntent = struct {
    room_id: RoomId,
    authority_id: u64,
    account: identity.AccountId,
    external_identity: protocol.ExternalIdentity,
    placement: Placement,
    route: Route,
    authorization: protocol.JoinAuthorization,
};

pub const ConnectionState = enum {
    none,
    connecting,
    connected,
    reconnecting,
    failed,
};

pub const ConnectFailure = enum {
    route_unavailable,
    authorization_rejected,
    authority_full,
    version_mismatch,
};

pub const MemberView = struct {
    account: identity.AccountId,
    external_identity: protocol.ExternalIdentity,
    lobby_present: bool,
    ready: bool,
    connection: ConnectionState,
    connect_failure: ?ConnectFailure,
};

const Member = struct {
    active: bool = false,
    account: identity.AccountId = .{ .value = 0 },
    external_identity: protocol.ExternalIdentity = .{},
    invited: bool = false,
    lobby_present: bool = false,
    ready: bool = false,
    connection: ConnectionState = .none,
    connect_failure: ?ConnectFailure = null,
};

const RoomState = enum { open, draining, closed };

const Room = struct {
    active: bool = false,
    generation: u16 = 0,
    id: RoomId = .{ .value = 0 },
    authority_id: u64 = 0,
    placement: Placement = .dedicated,
    route: Route = .local,
    host: identity.AccountId = .{ .value = 0 },
    secret: protocol.AdmissionSecret = @splat(0),
    state: RoomState = .closed,
    members: [budgets.max_participants]Member = @splat(.{}),
};

pub const Registry = struct {
    rooms: [max_rooms]Room = @splat(.{}),
    next_nonce: u64 = 1,

    pub fn create(self: *Registry, config: Config) !Handle {
        try config.id.validate();
        try config.host.validate();
        if (config.authority_id == 0 or std.mem.allEqual(u8, &config.secret, 0)) {
            return error.InvalidRoomConfig;
        }
        try validatePlacementRoute(config.placement, config.route);
        for (self.rooms) |room| {
            if (room.active and room.id.value == config.id.value) return error.DuplicateRoom;
        }
        for (&self.rooms, 0..) |*room, index| {
            if (room.active) continue;
            room.generation +%= 1;
            if (room.generation == 0) room.generation = 1;
            room.active = true;
            room.id = config.id;
            room.authority_id = config.authority_id;
            room.placement = config.placement;
            room.route = config.route;
            room.host = config.host;
            room.secret = config.secret;
            room.state = .open;
            room.members = @splat(.{});
            return .{ .index = @intCast(index + 1), .generation = room.generation };
        }
        return error.RoomCapacityReached;
    }

    pub fn invite(
        self: *Registry,
        handle: Handle,
        account: identity.AccountId,
        external_identity: protocol.ExternalIdentity,
        now_unix_seconds: u64,
        lifetime_seconds: u64,
    ) !Invite {
        try account.validate();
        if (lifetime_seconds == 0) return error.InvalidInviteLifetime;
        var normalized_identity = external_identity;
        if (normalized_identity.provider == .development and normalized_identity.subject == 0) {
            normalized_identity.subject = account.value;
        }
        if (normalized_identity.provider == .development and
            normalized_identity.subject != account.value)
        {
            return error.ExternalIdentityAccountMismatch;
        }
        if (normalized_identity.provider == .steam and normalized_identity.subject == 0) {
            return error.InvalidExternalIdentity;
        }
        const room = try self.roomSlot(handle);
        if (room.state != .open) return error.RoomNotJoinable;
        const member = try reserveMember(room, account, normalized_identity);
        member.invited = true;
        var authorization = protocol.JoinAuthorization{
            .room_id = room.id.value,
            .authority_id = room.authority_id,
            .room_generation = room.generation,
            .nonce = self.next_nonce,
            .expires_at_unix_seconds = try std.math.add(
                u64,
                now_unix_seconds,
                lifetime_seconds,
            ),
        };
        self.next_nonce +%= 1;
        if (self.next_nonce == 0) self.next_nonce = 1;
        protocol.signJoinAuthorization(room.secret, account, normalized_identity, &authorization);
        return .{
            .account = account,
            .external_identity = normalized_identity,
            .placement = room.placement,
            .route = room.route,
            .authorization = authorization,
        };
    }

    pub fn join(self: *Registry, invite_value: Invite, now_unix_seconds: u64) !JoinIntent {
        const room = self.findRoomById(invite_value.authorization.room_id) orelse
            return error.RoomNotFound;
        if (room.state != .open or room.authority_id != invite_value.authorization.authority_id or
            room.generation != invite_value.authorization.room_generation)
        {
            return error.RoomNotJoinable;
        }
        if (now_unix_seconds > invite_value.authorization.expires_at_unix_seconds) {
            return error.InviteExpired;
        }
        if (!protocol.verifyJoinAuthorization(
            room.secret,
            invite_value.account,
            invite_value.external_identity,
            invite_value.authorization,
        )) return error.InvalidInvite;
        const member = findMember(room, invite_value.account) orelse return error.InviteNotIssued;
        if (!member.invited) return error.InviteAlreadyUsed;
        if (!std.meta.eql(member.external_identity, invite_value.external_identity)) {
            return error.InviteIdentityMismatch;
        }
        member.invited = false;
        member.lobby_present = true;
        member.connect_failure = null;
        return .{
            .room_id = room.id,
            .authority_id = room.authority_id,
            .account = invite_value.account,
            .external_identity = invite_value.external_identity,
            .placement = room.placement,
            .route = room.route,
            .authorization = invite_value.authorization,
        };
    }

    pub fn setReady(self: *Registry, handle: Handle, account: identity.AccountId, ready: bool) !void {
        const member = try self.joinedMember(handle, account);
        member.ready = ready;
    }

    pub fn beginConnect(self: *Registry, handle: Handle, account: identity.AccountId) !void {
        const member = try self.joinedMember(handle, account);
        if (!member.ready) return error.MemberNotReady;
        member.connection = .connecting;
        member.connect_failure = null;
    }

    pub fn connected(self: *Registry, handle: Handle, account: identity.AccountId) !void {
        const member = try self.joinedMember(handle, account);
        if (member.connection != .connecting and member.connection != .reconnecting) {
            return error.InvalidConnectionTransition;
        }
        member.connection = .connected;
    }

    pub fn connectFailed(
        self: *Registry,
        handle: Handle,
        account: identity.AccountId,
        reason: ConnectFailure,
    ) !void {
        const member = try self.joinedMember(handle, account);
        member.connection = .failed;
        member.connect_failure = reason;
    }

    /// Lobby departure is social/discovery state. It deliberately does not
    /// terminate an established gameplay connection.
    pub fn leaveLobby(self: *Registry, handle: Handle, account: identity.AccountId) !void {
        const member = try self.joinedMember(handle, account);
        member.lobby_present = false;
        member.ready = false;
    }

    /// A transport loss is connection state. It deliberately does not remove
    /// lobby membership and permits the authority's bounded reconnect flow.
    pub fn networkDisconnected(self: *Registry, handle: Handle, account: identity.AccountId) !void {
        const member = try self.joinedMember(handle, account);
        member.connection = .reconnecting;
    }

    pub fn beginDrain(self: *Registry, handle: Handle) !void {
        const room = try self.roomSlot(handle);
        if (room.state != .open) return error.InvalidRoomTransition;
        room.state = .draining;
    }

    pub fn close(self: *Registry, handle: Handle) !void {
        const room = try self.roomSlot(handle);
        room.state = .closed;
        room.active = false;
    }

    pub fn memberView(self: *Registry, handle: Handle, account: identity.AccountId) !MemberView {
        const room_value = try self.roomSlot(handle);
        const value = findMember(room_value, account) orelse return error.MemberNotFound;
        return .{
            .account = value.account,
            .external_identity = value.external_identity,
            .lobby_present = value.lobby_present,
            .ready = value.ready,
            .connection = value.connection,
            .connect_failure = value.connect_failure,
        };
    }

    fn joinedMember(self: *Registry, handle: Handle, account: identity.AccountId) !*Member {
        const room_value = try self.roomSlot(handle);
        const member_value = findMember(room_value, account) orelse return error.MemberNotFound;
        if (!member_value.lobby_present and member_value.connection != .connected and
            member_value.connection != .reconnecting)
        {
            return error.MemberNotJoined;
        }
        return member_value;
    }

    fn roomSlot(self: *Registry, handle: Handle) !*Room {
        if (handle.index == 0 or handle.index > self.rooms.len) return error.StaleRoomHandle;
        const room_value = &self.rooms[handle.index - 1];
        if (!room_value.active or room_value.generation != handle.generation) {
            return error.StaleRoomHandle;
        }
        return room_value;
    }

    fn findRoomById(self: *Registry, room_id: u64) ?*Room {
        for (&self.rooms) |*room_value| {
            if (room_value.active and room_value.id.value == room_id) return room_value;
        }
        return null;
    }
};

fn validatePlacementRoute(placement: Placement, route: Route) !void {
    switch (placement) {
        .embedded => if (route != .local) return error.InvalidPlacementRoute,
        .listen => if (route == .local) return error.InvalidPlacementRoute,
        .dedicated => if (route == .local) return error.InvalidPlacementRoute,
    }
}

fn reserveMember(
    room: *Room,
    account: identity.AccountId,
    external_identity: protocol.ExternalIdentity,
) !*Member {
    if (findMember(room, account)) |member| {
        if (!std.meta.eql(member.external_identity, external_identity)) {
            return error.AccountIdentityConflict;
        }
        return member;
    }
    for (&room.members) |*member| {
        if (member.active) continue;
        member.* = .{
            .active = true,
            .account = account,
            .external_identity = external_identity,
        };
        return member;
    }
    return error.RoomFull;
}

fn findMember(room: *Room, account: identity.AccountId) ?*Member {
    for (&room.members) |*member| {
        if (member.active and std.meta.eql(member.account, account)) return member;
    }
    return null;
}

test "lobby departure and network disconnect are nonidentical" {
    var registry = Registry{};
    const handle = try registry.create(.{
        .id = .{ .value = 1 },
        .authority_id = 9,
        .placement = .dedicated,
        .route = .{ .direct_ip = try DirectEndpoint.init("127.0.0.1:27020") },
        .host = .{ .value = 1 },
        .secret = @splat(7),
    });
    const invite_value = try registry.invite(
        handle,
        .{ .value = 2 },
        .{ .provider = .development, .subject = 2 },
        10,
        60,
    );
    _ = try registry.join(invite_value, 11);
    try registry.setReady(handle, .{ .value = 2 }, true);
    try registry.beginConnect(handle, .{ .value = 2 });
    try registry.connected(handle, .{ .value = 2 });
    try registry.leaveLobby(handle, .{ .value = 2 });
    try std.testing.expectEqual(ConnectionState.connected, (try registry.memberView(
        handle,
        .{ .value = 2 },
    )).connection);
    try registry.networkDisconnected(handle, .{ .value = 2 });
    const member_value = try registry.memberView(handle, .{ .value = 2 });
    try std.testing.expect(!member_value.lobby_present);
    try std.testing.expectEqual(ConnectionState.reconnecting, member_value.connection);
}
