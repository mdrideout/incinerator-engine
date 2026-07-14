//! Generation-safe MP6 client room-flow coordinator.
//!
//! Registry/service adapters and transport owners feed typed completions into
//! this state machine. Presentation receives only `View`; signed admission and
//! reconnect material remain in the private connection plan.

const std = @import("std");
const budgets = @import("session_budgets");
const identity = @import("session_identity");
const protocol = @import("session_protocol");
const room = @import("session_room");

pub const State = enum {
    idle,
    creating,
    joining,
    in_room,
    ready,
    resolving_route,
    connecting,
    authenticating,
    synchronizing,
    playable,
    reconnecting,
    cancelling,
    recoverable_failure,
    terminal_failure,
    leaving,
    draining,
    closed,
};

pub const Operation = enum {
    solo,
    create_private,
    join,
};

pub const Impairment = enum {
    clean,
    nominal,
    adverse,
    blackout,
};

pub const Failure = enum {
    room_missing,
    invite_expired,
    room_full,
    version_mismatch,
    content_mismatch,
    authority_unavailable,
    authorization_rejected,
    timeout,
    reconnect_expired,
    host_closed,
    route_unavailable,
    cancelled,
    internal,
};

pub const Completion = enum {
    applied,
    stale,
};

pub const Member = struct {
    account: identity.AccountId,
    lobby_present: bool,
    ready: bool,
    connection: room.ConnectionState,
    local: bool,
};

const ConnectionPlan = struct {
    room_id: room.RoomId,
    authority_id: u64,
    account: identity.AccountId,
    external_identity: protocol.ExternalIdentity,
    placement: room.Placement,
    route: room.Route,
    authorization: ?protocol.JoinAuthorization,

    fn fromJoinIntent(intent: room.JoinIntent) ConnectionPlan {
        return .{
            .room_id = intent.room_id,
            .authority_id = intent.authority_id,
            .account = intent.account,
            .external_identity = intent.external_identity,
            .placement = intent.placement,
            .route = intent.route,
            .authorization = intent.authorization,
        };
    }

    fn solo(account: identity.AccountId) !ConnectionPlan {
        try account.validate();
        return .{
            .room_id = .{ .value = account.value },
            .authority_id = account.value,
            .account = account,
            .external_identity = .{
                .provider = .development,
                .subject = account.value,
            },
            .placement = .embedded,
            .route = .local,
            .authorization = null,
        };
    }
};

/// Sanitized value intended for graphical presentation and ordinary logs.
/// It deliberately contains no admission authorization, reconnect credential,
/// provider token, or registry/authority handle.
pub const View = struct {
    state: State,
    generation: u64,
    operation: ?Operation,
    placement: ?room.Placement,
    room_id: ?room.RoomId,
    local_account: ?identity.AccountId,
    members: [budgets.max_participants]Member,
    member_count: u8,
    failure: ?Failure,
    impairment: Impairment,
    reconnect_attempt: u8,
    stale_completions: u32,

    pub fn memberSlice(self: *const View) []const Member {
        return self.members[0..self.member_count];
    }
};

pub const Coordinator = struct {
    state: State = .idle,
    generation: u64 = 0,
    operation: ?Operation = null,
    plan: ?ConnectionPlan = null,
    members: [budgets.max_participants]Member = undefined,
    member_count: u8 = 0,
    failure: ?Failure = null,
    impairment: Impairment = .clean,
    reconnect_attempt: u8 = 0,
    stale_completions: u32 = 0,

    pub fn begin(self: *Coordinator, operation: Operation) !u64 {
        if (self.state != .idle and self.state != .recoverable_failure and
            self.state != .closed)
        {
            return error.RoomOperationInProgress;
        }
        const generation = self.advanceGeneration();
        self.operation = operation;
        self.plan = null;
        self.member_count = 0;
        self.failure = null;
        self.reconnect_attempt = 0;
        self.state = switch (operation) {
            .solo, .create_private => .creating,
            .join => .joining,
        };
        return generation;
    }

    pub fn completeJoin(
        self: *Coordinator,
        generation: u64,
        intent: room.JoinIntent,
        members: []const Member,
    ) !Completion {
        if (self.operation == .solo) return error.InvalidRoomCoordinatorTransition;
        return self.completeMembership(
            generation,
            ConnectionPlan.fromJoinIntent(intent),
            members,
        );
    }

    pub fn completeSolo(
        self: *Coordinator,
        generation: u64,
        account: identity.AccountId,
        members: []const Member,
    ) !Completion {
        if (self.operation != .solo) return error.InvalidRoomCoordinatorTransition;
        return self.completeMembership(
            generation,
            try ConnectionPlan.solo(account),
            members,
        );
    }

    fn completeMembership(
        self: *Coordinator,
        generation: u64,
        plan: ConnectionPlan,
        members: []const Member,
    ) !Completion {
        if (!self.accepts(generation)) return .stale;
        if (self.state != .creating and self.state != .joining) {
            return error.InvalidRoomCoordinatorTransition;
        }
        try validatePlan(plan, self.operation orelse
            return error.InvalidRoomCoordinatorTransition);
        try self.replaceMembers(members);
        self.plan = plan;
        self.state = .in_room;
        return .applied;
    }

    pub fn markReady(self: *Coordinator, generation: u64) !Completion {
        if (!self.accepts(generation)) return .stale;
        if (self.state != .in_room) return error.InvalidRoomCoordinatorTransition;
        self.setLocalReady(true);
        self.state = .ready;
        return .applied;
    }

    pub fn beginRouteResolution(self: *Coordinator, generation: u64) !Completion {
        if (!self.accepts(generation)) return .stale;
        if (self.state != .ready) return error.InvalidRoomCoordinatorTransition;
        self.state = .resolving_route;
        return .applied;
    }

    pub fn routeResolved(self: *Coordinator, generation: u64) !Completion {
        if (!self.accepts(generation)) return .stale;
        if (self.state != .resolving_route) return error.InvalidRoomCoordinatorTransition;
        self.state = .connecting;
        return .applied;
    }

    pub fn transportConnected(self: *Coordinator, generation: u64) !Completion {
        if (!self.accepts(generation)) return .stale;
        if (self.state != .connecting and self.state != .reconnecting) {
            return error.InvalidRoomCoordinatorTransition;
        }
        self.state = .authenticating;
        self.setLocalConnection(.connecting);
        return .applied;
    }

    pub fn authorityAccepted(self: *Coordinator, generation: u64) !Completion {
        if (!self.accepts(generation)) return .stale;
        if (self.state != .authenticating) return error.InvalidRoomCoordinatorTransition;
        self.state = .synchronizing;
        return .applied;
    }

    pub fn synchronized(self: *Coordinator, generation: u64) !Completion {
        if (!self.accepts(generation)) return .stale;
        if (self.state != .synchronizing) return error.InvalidRoomCoordinatorTransition;
        self.state = .playable;
        self.failure = null;
        self.reconnect_attempt = 0;
        self.setLocalConnection(.connected);
        return .applied;
    }

    pub fn networkLost(self: *Coordinator) !u64 {
        if (self.state != .playable and self.state != .authenticating and
            self.state != .synchronizing)
        {
            return error.InvalidRoomCoordinatorTransition;
        }
        const generation = self.advanceGeneration();
        self.state = .reconnecting;
        self.reconnect_attempt = 1;
        self.setLocalConnection(.reconnecting);
        return generation;
    }

    pub fn retryReconnect(self: *Coordinator, generation: u64) !Completion {
        if (!self.accepts(generation)) return .stale;
        if (self.state != .reconnecting) return error.InvalidRoomCoordinatorTransition;
        self.reconnect_attempt +|= 1;
        return .applied;
    }

    /// Discovery/lobby membership is independent from a healthy gameplay
    /// connection and therefore does not change the coordinator state.
    pub fn lobbyDeparted(self: *Coordinator, account: identity.AccountId) !void {
        for (self.members[0..self.member_count]) |*member| {
            if (std.meta.eql(member.account, account)) {
                member.lobby_present = false;
                member.ready = false;
                return;
            }
        }
        return error.MemberNotFound;
    }

    pub fn replaceMemberPresentation(
        self: *Coordinator,
        generation: u64,
        members: []const Member,
    ) !Completion {
        if (!self.accepts(generation)) return .stale;
        try self.replaceMembers(members);
        return .applied;
    }

    pub fn cancel(self: *Coordinator) !u64 {
        switch (self.state) {
            .creating,
            .joining,
            .in_room,
            .ready,
            .resolving_route,
            .connecting,
            .authenticating,
            .synchronizing,
            .reconnecting,
            .recoverable_failure,
            => {},
            else => return error.InvalidRoomCoordinatorTransition,
        }
        const generation = self.advanceGeneration();
        self.state = .cancelling;
        self.failure = .cancelled;
        return generation;
    }

    pub fn cancelled(self: *Coordinator, generation: u64) !Completion {
        if (!self.accepts(generation)) return .stale;
        if (self.state != .cancelling) return error.InvalidRoomCoordinatorTransition;
        self.resetIdle();
        return .applied;
    }

    pub fn leave(self: *Coordinator) !u64 {
        if (self.state != .playable and self.state != .recoverable_failure) {
            return error.InvalidRoomCoordinatorTransition;
        }
        const generation = self.advanceGeneration();
        self.state = .leaving;
        return generation;
    }

    pub fn left(self: *Coordinator, generation: u64) !Completion {
        if (!self.accepts(generation)) return .stale;
        if (self.state != .leaving) return error.InvalidRoomCoordinatorTransition;
        self.resetIdle();
        return .applied;
    }

    pub fn beginDrain(self: *Coordinator) !u64 {
        if (self.operation != .create_private or
            (self.state != .playable and self.state != .recoverable_failure))
        {
            return error.InvalidRoomCoordinatorTransition;
        }
        const generation = self.advanceGeneration();
        self.state = .draining;
        return generation;
    }

    pub fn closed(self: *Coordinator, generation: u64) !Completion {
        if (!self.accepts(generation)) return .stale;
        if (self.state != .draining and self.state != .leaving) {
            return error.InvalidRoomCoordinatorTransition;
        }
        self.plan = null;
        self.member_count = 0;
        self.failure = null;
        self.state = .closed;
        return .applied;
    }

    pub fn fail(
        self: *Coordinator,
        generation: u64,
        reason: Failure,
        terminal: bool,
    ) !Completion {
        if (!self.accepts(generation)) return .stale;
        if (self.state == .idle or self.state == .closed or self.state == .draining or
            self.state == .leaving or self.state == .cancelling)
        {
            return error.InvalidRoomCoordinatorTransition;
        }
        self.failure = reason;
        self.state = if (terminal) .terminal_failure else .recoverable_failure;
        self.setLocalConnection(.failed);
        return .applied;
    }

    pub fn setImpairment(self: *Coordinator, value: Impairment) void {
        self.impairment = value;
    }

    pub fn view(self: *const Coordinator) View {
        var result = View{
            .state = self.state,
            .generation = self.generation,
            .operation = self.operation,
            .placement = if (self.plan) |plan| plan.placement else null,
            .room_id = if (self.plan) |plan| plan.room_id else null,
            .local_account = if (self.plan) |plan| plan.account else null,
            .members = undefined,
            .member_count = self.member_count,
            .failure = self.failure,
            .impairment = self.impairment,
            .reconnect_attempt = self.reconnect_attempt,
            .stale_completions = self.stale_completions,
        };
        @memcpy(result.members[0..self.member_count], self.members[0..self.member_count]);
        return result;
    }

    fn accepts(self: *Coordinator, generation: u64) bool {
        if (generation != 0 and generation == self.generation) return true;
        self.stale_completions +|= 1;
        return false;
    }

    fn advanceGeneration(self: *Coordinator) u64 {
        self.generation +%= 1;
        if (self.generation == 0) self.generation = 1;
        return self.generation;
    }

    fn replaceMembers(self: *Coordinator, members: []const Member) !void {
        if (members.len > budgets.max_participants) return error.RoomMemberCapacity;
        var local_count: usize = 0;
        for (members, 0..) |member, index| {
            try member.account.validate();
            for (members[0..index]) |previous| {
                if (std.meta.eql(previous.account, member.account)) {
                    return error.DuplicateRoomMember;
                }
            }
            local_count += @intFromBool(member.local);
        }
        if (members.len != 0 and local_count != 1) return error.InvalidLocalRoomMember;
        @memcpy(self.members[0..members.len], members);
        self.member_count = @intCast(members.len);
    }

    fn setLocalReady(self: *Coordinator, ready: bool) void {
        for (self.members[0..self.member_count]) |*member| {
            if (member.local) member.ready = ready;
        }
    }

    fn setLocalConnection(self: *Coordinator, state: room.ConnectionState) void {
        for (self.members[0..self.member_count]) |*member| {
            if (member.local) member.connection = state;
        }
    }

    fn resetIdle(self: *Coordinator) void {
        self.state = .idle;
        self.operation = null;
        self.plan = null;
        self.member_count = 0;
        self.failure = null;
        self.reconnect_attempt = 0;
    }
};

pub fn failureFromError(err: anyerror) Failure {
    return switch (err) {
        error.RoomNotFound => .room_missing,
        error.InviteExpired, error.InviteAlreadyUsed => .invite_expired,
        error.RoomFull, error.RoomCapacityReached => .room_full,
        error.BuildMismatch, error.VersionMismatch => .version_mismatch,
        error.ContentMismatch => .content_mismatch,
        error.InvalidInvite,
        error.InviteNotIssued,
        error.InviteIdentityMismatch,
        error.Unauthorized,
        error.AuthorizationRejected,
        => .authorization_rejected,
        error.Timeout, error.ConnectionTimeout, error.HandshakeTimeout => .timeout,
        error.ReconnectExpired, error.ReconnectAttemptsExhausted => .reconnect_expired,
        error.RoomNotJoinable, error.HostClosed, error.AuthorityStopped => .host_closed,
        error.RouteUnavailable, error.InvalidEndpoint => .route_unavailable,
        error.AuthorityFaulted,
        error.AuthorityUnavailable,
        error.ConnectionCapacityReached,
        error.ParticipantCapacityReached,
        => .authority_unavailable,
        else => .internal,
    };
}

fn validatePlan(plan: ConnectionPlan, operation: Operation) !void {
    try plan.room_id.validate();
    try plan.account.validate();
    if (plan.authority_id == 0) return error.InvalidAuthorityId;
    switch (operation) {
        .solo => {
            if (plan.placement != .embedded or plan.route != .local or
                plan.authorization != null)
            {
                return error.InvalidSoloRoomPlan;
            }
        },
        .create_private => {
            if (plan.placement != .listen or plan.route == .local or
                plan.authorization == null)
            {
                return error.InvalidListenRoomPlan;
            }
        },
        .join => {
            if (plan.placement == .embedded or plan.authorization == null) {
                return error.InvalidJoinRoomPlan;
            }
        },
    }
}

fn testPlan(placement: room.Placement, account_value: u64) !ConnectionPlan {
    const account = identity.AccountId{ .value = account_value };
    const external_identity = protocol.ExternalIdentity{
        .provider = .development,
        .subject = account_value,
    };
    var authorization = protocol.JoinAuthorization{
        .room_id = 71,
        .authority_id = 9_001,
        .room_generation = 1,
        .nonce = account_value,
        .expires_at_unix_seconds = 100,
    };
    protocol.signJoinAuthorization(@splat(7), account, external_identity, &authorization);
    return .{
        .room_id = .{ .value = 71 },
        .authority_id = 9_001,
        .account = account,
        .external_identity = external_identity,
        .placement = placement,
        .route = .{ .direct_ip = try room.DirectEndpoint.init("127.0.0.1:27020") },
        .authorization = authorization,
    };
}

fn testMembers(local_account: u64) [2]Member {
    return .{
        .{
            .account = .{ .value = local_account },
            .lobby_present = true,
            .ready = false,
            .connection = .none,
            .local = true,
        },
        .{
            .account = .{ .value = if (local_account == 2) 3 else 2 },
            .lobby_present = true,
            .ready = true,
            .connection = .connected,
            .local = false,
        },
    };
}

test "coordinator drives create through playable without exposing admission" {
    var coordinator = Coordinator{};
    const generation = try coordinator.begin(.create_private);
    const members = testMembers(1);
    try std.testing.expectEqual(
        Completion.applied,
        try coordinator.completeMembership(
            generation,
            try testPlan(.listen, 1),
            &members,
        ),
    );
    _ = try coordinator.markReady(generation);
    _ = try coordinator.beginRouteResolution(generation);
    _ = try coordinator.routeResolved(generation);
    _ = try coordinator.transportConnected(generation);
    _ = try coordinator.authorityAccepted(generation);
    _ = try coordinator.synchronized(generation);
    const view = coordinator.view();
    try std.testing.expectEqual(State.playable, view.state);
    try std.testing.expectEqual(room.Placement.listen, view.placement.?);
    try std.testing.expectEqual(@as(u8, 2), view.member_count);
    try std.testing.expect(view.members[0].ready);
    try std.testing.expectEqual(room.ConnectionState.connected, view.members[0].connection);
    try std.testing.expect(!@hasField(View, "authorization"));
    try std.testing.expect(!@hasField(View, "reconnect"));
    try std.testing.expect(!@hasField(View, "secret"));
}

test "stale completions cannot mutate a cancelled or newer attempt" {
    var coordinator = Coordinator{};
    const old_generation = try coordinator.begin(.join);
    const cancel_generation = try coordinator.cancel();
    const members = testMembers(2);
    try std.testing.expectEqual(
        Completion.stale,
        try coordinator.completeMembership(
            old_generation,
            try testPlan(.dedicated, 2),
            &members,
        ),
    );
    try std.testing.expectEqual(State.cancelling, coordinator.view().state);
    _ = try coordinator.cancelled(cancel_generation);
    const new_generation = try coordinator.begin(.join);
    try std.testing.expect(new_generation != old_generation);
    try std.testing.expectEqual(
        Completion.stale,
        try coordinator.fail(old_generation, .timeout, false),
    );
    try std.testing.expectEqual(State.joining, coordinator.view().state);
    try std.testing.expectEqual(@as(u32, 2), coordinator.view().stale_completions);
}

test "network loss reconnects while lobby departure remains independent" {
    var coordinator = Coordinator{};
    const generation = try coordinator.begin(.join);
    const members = testMembers(2);
    _ = try coordinator.completeMembership(
        generation,
        try testPlan(.dedicated, 2),
        &members,
    );
    _ = try coordinator.markReady(generation);
    _ = try coordinator.beginRouteResolution(generation);
    _ = try coordinator.routeResolved(generation);
    _ = try coordinator.transportConnected(generation);
    _ = try coordinator.authorityAccepted(generation);
    _ = try coordinator.synchronized(generation);
    try coordinator.lobbyDeparted(.{ .value = 2 });
    try std.testing.expectEqual(State.playable, coordinator.view().state);
    try std.testing.expect(!coordinator.view().members[0].lobby_present);

    const reconnect_generation = try coordinator.networkLost();
    try std.testing.expectEqual(State.reconnecting, coordinator.view().state);
    _ = try coordinator.transportConnected(reconnect_generation);
    _ = try coordinator.authorityAccepted(reconnect_generation);
    _ = try coordinator.synchronized(reconnect_generation);
    try std.testing.expectEqual(State.playable, coordinator.view().state);
    try std.testing.expect(!coordinator.view().members[0].lobby_present);
}

test "all asynchronous pre-play states are cancellable" {
    inline for (.{
        State.creating,
        State.joining,
        State.in_room,
        State.ready,
        State.resolving_route,
        State.connecting,
        State.authenticating,
        State.synchronizing,
        State.reconnecting,
        State.recoverable_failure,
    }) |state| {
        var coordinator = Coordinator{};
        coordinator.state = state;
        coordinator.generation = 7;
        coordinator.operation = .join;
        const generation = try coordinator.cancel();
        try std.testing.expectEqual(State.cancelling, coordinator.view().state);
        _ = try coordinator.cancelled(generation);
        try std.testing.expectEqual(State.idle, coordinator.view().state);
    }
}

test "room and transport failures map to actionable presentation values" {
    try std.testing.expectEqual(Failure.room_missing, failureFromError(error.RoomNotFound));
    try std.testing.expectEqual(Failure.invite_expired, failureFromError(error.InviteExpired));
    try std.testing.expectEqual(Failure.room_full, failureFromError(error.RoomFull));
    try std.testing.expectEqual(Failure.version_mismatch, failureFromError(error.BuildMismatch));
    try std.testing.expectEqual(Failure.authorization_rejected, failureFromError(error.InvalidInvite));
    try std.testing.expectEqual(Failure.timeout, failureFromError(error.ConnectionTimeout));
    try std.testing.expectEqual(Failure.reconnect_expired, failureFromError(error.ReconnectExpired));
    try std.testing.expectEqual(Failure.host_closed, failureFromError(error.HostClosed));
}
