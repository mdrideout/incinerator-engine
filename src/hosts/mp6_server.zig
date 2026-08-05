//! MP6 room-owning dedicated direct-IP development server.
//!
//! This process combines the open room registry with the existing cold GNS
//! authority placement. It writes account-bound signed invite artifacts for
//! local/LAN testing; gameplay remains exclusively authority-owned.

const std = @import("std");
const budgets = @import("session_budgets");
const identity = @import("session_identity");
const protocol = @import("session_protocol");
const room = @import("session_room");
const room_ticket = @import("room_ticket");
const authority = @import("session_authority");
const direct_server = @import("direct_server");

const max_ticks_per_pump: u8 = 8;
const default_port: u16 = 27_020;
const default_room_id: u64 = 6_001;
const default_authority_id: u64 = 9_001;
const default_ticket_dir = "/tmp/incinerator-mp6-room";
const invite_lifetime_seconds: u64 = 24 * 60 * 60;

const Invocation = struct {
    port: u16 = default_port,
    max_ticks: ?u64 = null,
    allow_remote: bool = false,
    advertise_host: []const u8 = "127.0.0.1",
    ticket_dir: []const u8 = default_ticket_dir,
    room_id: u64 = default_room_id,
    authority_id: u64 = default_authority_id,
    accounts: [budgets.max_participants]identity.AccountId = undefined,
    account_count: u8 = 0,
};

const RoomOwner = struct {
    registry: room.Registry = .{},
    handle: room.Handle,
    intents: [budgets.max_participants]room.JoinIntent = undefined,
    intent_count: u8,
    secret: protocol.AdmissionSecret,
    issued_at_unix_seconds: u64,

    fn init(invocation: Invocation, now_unix_seconds: u64) !RoomOwner {
        var secret: protocol.AdmissionSecret = undefined;
        std.c.arc4random_buf(secret[0..].ptr, secret.len);
        if (std.mem.allEqual(u8, &secret, 0)) return error.SecureRoomEntropyFailed;
        var owner = RoomOwner{
            .handle = undefined,
            .intent_count = invocation.account_count,
            .secret = secret,
            .issued_at_unix_seconds = now_unix_seconds,
        };
        var endpoint_storage: [room.max_endpoint_bytes]u8 = undefined;
        const endpoint = try std.fmt.bufPrint(
            &endpoint_storage,
            "{s}:{d}",
            .{ invocation.advertise_host, invocation.port },
        );
        owner.handle = try owner.registry.create(.{
            .id = .{ .value = invocation.room_id },
            .authority_id = invocation.authority_id,
            .placement = .dedicated,
            .route = .{ .direct_ip = try room.DirectEndpoint.init(endpoint) },
            .host = invocation.accounts[0],
            .secret = secret,
        });
        for (invocation.accounts[0..invocation.account_count], 0..) |account, index| {
            const invite = try owner.registry.invite(
                owner.handle,
                account,
                .{ .provider = .development, .subject = account.value },
                now_unix_seconds,
                invite_lifetime_seconds,
            );
            owner.intents[index] = try owner.registry.join(invite, now_unix_seconds);
        }
        return owner;
    }

    fn authorityOptions(self: *const RoomOwner, invocation: Invocation) authority.Options {
        return .{ .room_admission = .{
            .room_id = invocation.room_id,
            .authority_id = invocation.authority_id,
            .room_generation = self.intents[0].authorization.room_generation,
            .secret = self.secret,
        } };
    }

    fn writeTickets(self: *const RoomOwner, io: std.Io, directory: []const u8) !void {
        for (self.intents[0..self.intent_count]) |intent| {
            var artifact = room_ticket.Artifact{
                .intent = intent,
                .member_count = self.intent_count,
            };
            for (self.intents[0..self.intent_count], 0..) |member, index| {
                artifact.members[index] = member.account;
            }
            var storage: [room_ticket.maximum_bytes]u8 = undefined;
            const bytes = try room_ticket.encode(artifact, &storage);
            var path_storage: [512]u8 = undefined;
            const path = try std.fmt.bufPrint(
                &path_storage,
                "{s}/account-{d}.room",
                .{ directory, intent.account.value },
            );
            var atomic = try std.Io.Dir.cwd().createFileAtomic(io, path, .{
                .permissions = std.Io.File.Permissions.fromMode(0o600),
                .make_path = true,
                .replace = true,
            });
            defer atomic.deinit(io);
            try atomic.file.writeStreamingAll(io, bytes);
            try atomic.replace(io);
            std.debug.print(
                "MP6_TICKET_READY account={d} path={s}\n",
                .{ intent.account.value, path },
            );
        }
    }

    fn close(self: *RoomOwner) !void {
        try self.registry.beginDrain(self.handle);
        try self.registry.close(self.handle);
    }
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var invocation = try parseInvocation(args);
    if (invocation.account_count == 0) {
        invocation.accounts[0] = .{ .value = 1 };
        invocation.accounts[1] = .{ .value = 2 };
        invocation.account_count = 2;
    }
    const now_unix_seconds = try unixSeconds(init.io);
    var room_owner = try RoomOwner.init(invocation, now_unix_seconds);
    defer std.crypto.secureZero(u8, std.mem.asBytes(&room_owner));
    try room_owner.writeTickets(init.io, invocation.ticket_dir);

    var server = try direct_server.Server.initWithOptions(
        init.gpa,
        invocation.port,
        invocation.allow_remote,
        room_owner.authorityOptions(invocation),
        now_unix_seconds,
    );
    defer server.deinit();
    std.debug.print(
        "MP6_SERVER_READY room={d} authority={d} endpoint={s}:{d} members={d} " ++
            "tickets={s} authority_hz={d} snapshot_hz={d}\n",
        .{
            invocation.room_id,
            invocation.authority_id,
            invocation.advertise_host,
            invocation.port,
            invocation.account_count,
            invocation.ticket_dir,
            budgets.authority_tick_hz,
            budgets.snapshot_hz,
        },
    );

    const start = std.Io.Clock.Timestamp.now(init.io, .awake);
    var completed_ticks: u64 = 0;
    while (invocation.max_ticks == null or completed_ticks < invocation.max_ticks.?) {
        server.updateAdmissionTime(try unixSeconds(init.io));
        try server.pumpNetwork();
        const elapsed = elapsedNs(start, std.Io.Clock.Timestamp.now(init.io, .awake));
        const due = (@as(u128, elapsed) * budgets.authority_tick_hz) / std.time.ns_per_s;
        const due_ticks = std.math.cast(u64, due) orelse return error.ServerClockRangeExceeded;
        var remaining = @min(due_ticks -| completed_ticks, max_ticks_per_pump);
        while (remaining > 0) : (remaining -= 1) {
            try server.tick();
            completed_ticks += 1;
        }
        if (due_ticks <= completed_ticks) {
            try std.Io.sleep(init.io, .fromMilliseconds(1), .awake);
        }
    }
    const diagnostics = server.authority.diagnostics();
    const population = server.authority.populationDiagnostics();
    try server.stop(init.io);
    try room_owner.close();
    std.debug.print(
        "MP6_SERVER_CLOSED room={d} tick={d} participants={d} host_migration=false " ++
            "population_live={d} population_awaiting={d} population_vacant={d} " ++
            "population_replacement={d} population_retries={d}\n",
        .{
            invocation.room_id,
            diagnostics.tick,
            diagnostics.active_participants,
            if (population) |value| value.live else 0,
            if (population) |value| value.awaiting_spawn else 0,
            if (population) |value| value.vacant else 0,
            if (population) |value| value.replacement_pending else 0,
            if (population) |value| value.spawn_retries.total() else 0,
        },
    );
}

fn parseInvocation(args: []const []const u8) !Invocation {
    var result = Invocation{};
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--port")) {
            index += 1;
            if (index >= args.len) return error.MissingPort;
            result.port = try std.fmt.parseInt(u16, args[index], 10);
            if (result.port == 0) return error.InvalidPort;
        } else if (std.mem.eql(u8, args[index], "--max-ticks")) {
            index += 1;
            if (index >= args.len) return error.MissingMaxTicks;
            result.max_ticks = try std.fmt.parseInt(u64, args[index], 10);
        } else if (std.mem.eql(u8, args[index], "--allow-remote")) {
            result.allow_remote = true;
        } else if (std.mem.eql(u8, args[index], "--advertise")) {
            index += 1;
            if (index >= args.len or args[index].len == 0) return error.MissingAdvertiseHost;
            result.advertise_host = args[index];
        } else if (std.mem.eql(u8, args[index], "--ticket-dir")) {
            index += 1;
            if (index >= args.len or args[index].len == 0) return error.MissingTicketDirectory;
            result.ticket_dir = args[index];
        } else if (std.mem.eql(u8, args[index], "--room-id")) {
            index += 1;
            if (index >= args.len) return error.MissingRoomId;
            result.room_id = try std.fmt.parseInt(u64, args[index], 10);
            if (result.room_id == 0) return error.InvalidRoomId;
        } else if (std.mem.eql(u8, args[index], "--authority-id")) {
            index += 1;
            if (index >= args.len) return error.MissingAuthorityId;
            result.authority_id = try std.fmt.parseInt(u64, args[index], 10);
            if (result.authority_id == 0) return error.InvalidAuthorityId;
        } else if (std.mem.eql(u8, args[index], "--account")) {
            index += 1;
            if (index >= args.len or result.account_count == budgets.max_participants) {
                return error.InvalidRoomAccounts;
            }
            const account = identity.AccountId{
                .value = try std.fmt.parseInt(u64, args[index], 10),
            };
            try account.validate();
            for (result.accounts[0..result.account_count]) |previous| {
                if (std.meta.eql(previous, account)) return error.DuplicateRoomAccount;
            }
            result.accounts[result.account_count] = account;
            result.account_count += 1;
        } else return error.UnknownArgument;
    }
    if (result.allow_remote and std.mem.eql(u8, result.advertise_host, "127.0.0.1")) {
        return error.RemoteRoomRequiresAdvertisedHost;
    }
    return result;
}

fn unixSeconds(io: std.Io) !u64 {
    const nanoseconds = std.Io.Clock.Timestamp.now(io, .real).raw.nanoseconds;
    if (nanoseconds <= 0) return error.SystemClockBeforeUnixEpoch;
    return std.math.cast(u64, @divFloor(nanoseconds, std.time.ns_per_s)) orelse
        error.SystemClockRangeExceeded;
}

fn elapsedNs(start: std.Io.Clock.Timestamp, end: std.Io.Clock.Timestamp) u64 {
    const nanoseconds = start.durationTo(end).raw.nanoseconds;
    if (nanoseconds <= 0) return 0;
    return std.math.cast(u64, nanoseconds) orelse std.math.maxInt(u64);
}

test "MP6 dedicated defaults to two local ticketed members" {
    var invocation = try parseInvocation(&.{"server"});
    if (invocation.account_count == 0) {
        invocation.accounts[0] = .{ .value = 1 };
        invocation.accounts[1] = .{ .value = 2 };
        invocation.account_count = 2;
    }
    try std.testing.expectEqual(@as(u8, 2), invocation.account_count);
    try std.testing.expect(!invocation.allow_remote);
    try std.testing.expectEqualStrings("127.0.0.1", invocation.advertise_host);
}

test "MP6 remote exposure requires an explicit advertised host" {
    try std.testing.expectError(
        error.RemoteRoomRequiresAdvertisedHost,
        parseInvocation(&.{ "server", "--allow-remote" }),
    );
    const invocation = try parseInvocation(&.{
        "server",
        "--allow-remote",
        "--advertise",
        "192.168.1.25",
    });
    try std.testing.expect(invocation.allow_remote);
}
