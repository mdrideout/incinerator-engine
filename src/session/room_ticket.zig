//! Bounded open-engine MP6 invite artifact codec.
//!
//! The artifact carries a signed join authorization and an opaque route, but
//! never the room admission secret. File creation/permissions belong to the
//! room-service or host adapter, not this value codec.

const std = @import("std");
const budgets = @import("session_budgets");
const identity = @import("session_identity");
const protocol = @import("session_protocol");
const room = @import("session_room");

const magic = "INCRMTK1";
pub const maximum_bytes: usize = 512;

pub const Artifact = struct {
    intent: room.JoinIntent,
    members: [budgets.max_participants]identity.AccountId = undefined,
    member_count: u8 = 0,

    pub fn memberSlice(self: *const Artifact) []const identity.AccountId {
        return self.members[0..self.member_count];
    }
};

pub fn encode(artifact: Artifact, storage: *[maximum_bytes]u8) ![]const u8 {
    try validate(artifact);
    const intent = artifact.intent;
    var writer = Writer{ .storage = storage };
    try writer.bytesValue(magic);
    try writer.u8Value(@intFromEnum(intent.placement));
    try writer.u8Value(@intFromEnum(intent.external_identity.provider));
    switch (intent.route) {
        .direct_ip => |endpoint| {
            try writer.u8Value(1);
            try writer.u8Value(endpoint.len);
        },
        .steam => {
            try writer.u8Value(2);
            try writer.u8Value(0);
        },
        .local => return error.InvalidTicketRoute,
    }
    try writer.u8Value(artifact.member_count);
    try writer.u8Value(0);
    try writer.u64Value(intent.room_id.value);
    try writer.u64Value(intent.authority_id);
    try writer.u64Value(intent.account.value);
    try writer.u64Value(intent.external_identity.subject);
    try writer.u32Value(intent.authorization.room_generation);
    try writer.u64Value(intent.authorization.nonce);
    try writer.u64Value(intent.authorization.expires_at_unix_seconds);
    try writer.bytesValue(&intent.authorization.authenticator);
    switch (intent.route) {
        .direct_ip => |endpoint| try writer.bytesValue(endpoint.slice()),
        .steam => |reference| try writer.u64Value(reference),
        .local => unreachable,
    }
    for (artifact.memberSlice()) |member| try writer.u64Value(member.value);
    return storage[0..writer.offset];
}

pub fn decode(bytes: []const u8) !Artifact {
    if (bytes.len > maximum_bytes) return error.RoomTicketTooLarge;
    var reader = Reader{ .bytes = bytes };
    if (!std.mem.eql(u8, try reader.bytesValue(magic.len), magic)) {
        return error.InvalidRoomTicketMagic;
    }
    const placement: room.Placement = switch (try reader.u8Value()) {
        @intFromEnum(room.Placement.embedded) => .embedded,
        @intFromEnum(room.Placement.listen) => .listen,
        @intFromEnum(room.Placement.dedicated) => .dedicated,
        else => return error.InvalidTicketPlacement,
    };
    const provider: protocol.IdentityProvider = switch (try reader.u8Value()) {
        @intFromEnum(protocol.IdentityProvider.development) => .development,
        @intFromEnum(protocol.IdentityProvider.steam) => .steam,
        else => return error.InvalidTicketIdentityProvider,
    };
    const route_tag = try reader.u8Value();
    const endpoint_len = try reader.u8Value();
    const member_count = try reader.u8Value();
    if (try reader.u8Value() != 0 or member_count == 0 or
        member_count > budgets.max_participants)
    {
        return error.InvalidRoomTicketMembers;
    }
    const room_id = try reader.u64Value();
    const authority_id = try reader.u64Value();
    const account_value = try reader.u64Value();
    const subject = try reader.u64Value();
    const room_generation = try reader.u32Value();
    const nonce = try reader.u64Value();
    const expires_at_unix_seconds = try reader.u64Value();
    var authenticator: [32]u8 = undefined;
    @memcpy(&authenticator, try reader.bytesValue(authenticator.len));
    const route: room.Route = switch (route_tag) {
        1 => blk: {
            if (endpoint_len == 0) return error.InvalidTicketRoute;
            break :blk .{ .direct_ip = try room.DirectEndpoint.init(
                try reader.bytesValue(endpoint_len),
            ) };
        },
        2 => blk: {
            if (endpoint_len != 0) return error.InvalidTicketRoute;
            break :blk .{ .steam = try reader.u64Value() };
        },
        else => return error.InvalidTicketRoute,
    };
    var artifact = Artifact{
        .intent = .{
            .room_id = .{ .value = room_id },
            .authority_id = authority_id,
            .account = .{ .value = account_value },
            .external_identity = .{ .provider = provider, .subject = subject },
            .placement = placement,
            .route = route,
            .authorization = .{
                .room_id = room_id,
                .authority_id = authority_id,
                .room_generation = room_generation,
                .nonce = nonce,
                .expires_at_unix_seconds = expires_at_unix_seconds,
                .authenticator = authenticator,
            },
        },
        .member_count = member_count,
    };
    for (artifact.members[0..artifact.member_count]) |*member| {
        member.* = .{ .value = try reader.u64Value() };
    }
    if (!reader.done()) return error.TrailingRoomTicketData;
    try validate(artifact);
    return artifact;
}

fn validate(artifact: Artifact) !void {
    const intent = artifact.intent;
    try intent.room_id.validate();
    try intent.account.validate();
    if (intent.authority_id == 0 or !intent.authorization.isPresent() or
        intent.authorization.room_id != intent.room_id.value or
        intent.authorization.authority_id != intent.authority_id or
        intent.authorization.room_generation == 0 or
        intent.authorization.nonce == 0 or
        intent.authorization.expires_at_unix_seconds == 0 or
        std.mem.allEqual(u8, &intent.authorization.authenticator, 0))
    {
        return error.InvalidRoomTicketAuthorization;
    }
    switch (intent.placement) {
        .listen, .dedicated => if (intent.route == .local) {
            return error.InvalidTicketRoute;
        },
        .embedded => return error.InvalidTicketPlacement,
    }
    if (intent.external_identity.provider == .development and
        intent.external_identity.subject != intent.account.value)
    {
        return error.InvalidTicketIdentity;
    }
    if (intent.external_identity.provider == .steam and
        intent.external_identity.subject == 0)
    {
        return error.InvalidTicketIdentity;
    }
    if (artifact.member_count == 0 or artifact.member_count > budgets.max_participants) {
        return error.InvalidRoomTicketMembers;
    }
    var contains_local = false;
    for (artifact.memberSlice(), 0..) |member, index| {
        try member.validate();
        contains_local = contains_local or std.meta.eql(member, intent.account);
        for (artifact.memberSlice()[0..index]) |previous| {
            if (std.meta.eql(previous, member)) return error.DuplicateRoomTicketMember;
        }
    }
    if (!contains_local) return error.RoomTicketMissingLocalMember;
}

const Writer = struct {
    storage: *[maximum_bytes]u8,
    offset: usize = 0,

    fn bytesValue(self: *Writer, value: []const u8) !void {
        if (value.len > self.storage.len - self.offset) return error.RoomTicketCapacity;
        @memcpy(self.storage[self.offset..][0..value.len], value);
        self.offset += value.len;
    }

    fn u8Value(self: *Writer, value: u8) !void {
        try self.bytesValue(&.{value});
    }

    fn u32Value(self: *Writer, value: u32) !void {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, value, .little);
        try self.bytesValue(&bytes);
    }

    fn u64Value(self: *Writer, value: u64) !void {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, value, .little);
        try self.bytesValue(&bytes);
    }
};

const Reader = struct {
    bytes: []const u8,
    offset: usize = 0,

    fn bytesValue(self: *Reader, len: usize) ![]const u8 {
        if (len > self.bytes.len - self.offset) return error.TruncatedRoomTicket;
        defer self.offset += len;
        return self.bytes[self.offset..][0..len];
    }

    fn u8Value(self: *Reader) !u8 {
        return (try self.bytesValue(1))[0];
    }

    fn u32Value(self: *Reader) !u32 {
        const bytes = try self.bytesValue(4);
        return std.mem.readInt(u32, @ptrCast(bytes.ptr), .little);
    }

    fn u64Value(self: *Reader) !u64 {
        const bytes = try self.bytesValue(8);
        return std.mem.readInt(u64, @ptrCast(bytes.ptr), .little);
    }

    fn done(self: *const Reader) bool {
        return self.offset == self.bytes.len;
    }
};

fn testArtifact() !Artifact {
    const account = identity.AccountId{ .value = 42 };
    const external_identity = protocol.ExternalIdentity{
        .provider = .development,
        .subject = account.value,
    };
    var authorization = protocol.JoinAuthorization{
        .room_id = 71,
        .authority_id = 9_001,
        .room_generation = 3,
        .nonce = 12,
        .expires_at_unix_seconds = 100,
    };
    protocol.signJoinAuthorization(@splat(9), account, external_identity, &authorization);
    var artifact = Artifact{
        .intent = .{
            .room_id = .{ .value = 71 },
            .authority_id = 9_001,
            .account = account,
            .external_identity = external_identity,
            .placement = .listen,
            .route = .{ .direct_ip = try room.DirectEndpoint.init("127.0.0.1:27020") },
            .authorization = authorization,
        },
        .member_count = 2,
    };
    artifact.members[0] = account;
    artifact.members[1] = .{ .value = 43 };
    return artifact;
}

test "signed invite artifact round trips without the admission secret" {
    const expected = try testArtifact();
    var storage: [maximum_bytes]u8 = undefined;
    const bytes = try encode(expected, &storage);
    const actual = try decode(bytes);
    try std.testing.expect(std.meta.eql(expected, actual));
    try std.testing.expect(bytes.len < maximum_bytes);
    try std.testing.expect(!std.mem.containsAtLeast(u8, bytes, 1, &([_]u8{9} ** 32)));
}

test "invite artifact rejects truncation invalid tags and trailing data" {
    const artifact = try testArtifact();
    var storage: [maximum_bytes]u8 = undefined;
    const bytes = try encode(artifact, &storage);
    try std.testing.expectError(error.TruncatedRoomTicket, decode(bytes[0 .. bytes.len - 1]));
    const placement_offset = magic.len;
    storage[placement_offset] = 0xff;
    try std.testing.expectError(error.InvalidTicketPlacement, decode(bytes));
    _ = try encode(artifact, &storage);
    storage[bytes.len] = 0;
    try std.testing.expectError(error.TrailingRoomTicketData, decode(storage[0 .. bytes.len + 1]));
}
