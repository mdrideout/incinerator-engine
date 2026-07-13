//! District loader decorator used by S4-B live capture and replay.
//!
//! The feature-facing loader contract deliberately has no tick parameter. The
//! composition therefore supplies the current authoritative tick through
//! `setCurrentTick` before `Runtime.tick`. Live mode delegates to the real
//! worker and retains only the completion actually returned to the feature.
//! Replay mode starts no worker and releases one validated recorded completion
//! only at its scheduled consumption tick.

const std = @import("std");
const district_contract = @import("district_contract");
const district_worker = @import("district_worker");
const sandbox_recipe = @import("sandbox_district_recipe");

pub const Mode = enum {
    live,
    replay,
};

pub const ConsumedCompletion = struct {
    /// Zero is reserved to make a missing `setCurrentTick` call visible.
    tick_index: u64,
    completion: district_contract.Completion,
};

pub const ScheduledCompletion = struct {
    tick_index: u64,
    completion: district_contract.Completion,
};

pub const TicketMismatch = struct {
    active: district_contract.LoadTicket,
    scheduled: district_contract.LoadTicket,
};

pub const TickRegression = struct {
    previous: u64,
    received: u64,
};

pub const OverdueCompletion = struct {
    scheduled_tick: u64,
    observed_tick: u64,
    ticket: district_contract.LoadTicket,
};

/// The first loader-level structural problem is retained. Required loader
/// methods continue returning only the established district-contract values;
/// the replay runner inspects this state and reports the structural error.
pub const Issue = union(enum) {
    current_tick_missing,
    current_tick_regressed: TickRegression,
    consumed_completion_not_taken,
    replay_completion_already_scheduled,
    replay_completion_wrong_ticket: TicketMismatch,
    replay_completion_overdue: OverdueCompletion,
};

pub const Observation = struct {
    mode: Mode,
    current_tick: ?u64,
    active_ticket: ?district_contract.LoadTicket,
    scheduled_tick: ?u64,
    scheduled_ticket: ?district_contract.LoadTicket,
    consumed_waiting: bool,
    issue: ?Issue,
};

const ReplayState = struct {
    active: ?district_contract.LoadRequest = null,
    last_generation: u64 = 0,
    cancellation_requested: bool = false,
    scheduled: ?ScheduledCompletion = null,
};

const Backend = union(Mode) {
    live: district_worker.Worker,
    replay: ReplayState,
};

pub const Loader = struct {
    backend: Backend,
    current_tick: ?u64 = null,
    consumed: ?ConsumedCompletion = null,
    issue: ?Issue = null,

    /// The returned value must reach its final address before `request` starts
    /// the embedded worker and must not move until that job is collected or
    /// `deinit` joins it.
    pub fn initLive() Loader {
        return .{ .backend = .{ .live = district_worker.Worker.init() } };
    }

    /// Deterministic concurrency seam for this decorator's focused tests.
    pub fn initLiveWithTestGate(gate: *district_worker.TestGate) Loader {
        return .{
            .backend = .{
                .live = district_worker.Worker.initWithTestGate(gate),
            },
        };
    }

    /// Replay mode owns no worker thread.
    pub fn initReplay() Loader {
        return .{ .backend = .{ .replay = .{} } };
    }

    pub fn deinit(self: *Loader) void {
        switch (self.backend) {
            .live => |*worker| worker.deinit(),
            .replay => {},
        }
        self.* = undefined;
    }

    /// Set the tick that a later `poll` belongs to. Repeating one tick is
    /// harmless; moving backwards is retained as the first structural issue.
    pub fn setCurrentTick(self: *Loader, tick_index: u64) !void {
        if (self.current_tick) |previous| {
            if (tick_index < previous) {
                self.retainIssue(.{ .current_tick_regressed = .{
                    .previous = previous,
                    .received = tick_index,
                } });
                return error.ReplayTickRegressed;
            }
        }
        self.current_tick = tick_index;
    }

    /// Install the next replay ingress. It may be installed before or after
    /// the matching logical request, but only one unconsumed ingress may be
    /// scheduled at a time.
    pub fn scheduleReplayCompletion(
        self: *Loader,
        scheduled: ScheduledCompletion,
    ) !void {
        const replay = switch (self.backend) {
            .live => return error.NotReplayLoader,
            .replay => |*state| state,
        };
        if (scheduled.tick_index == 0) return error.InvalidReplayCompletionTick;
        try validateCompletion(scheduled.completion);
        if (replay.scheduled != null) {
            self.retainIssue(.replay_completion_already_scheduled);
            return error.ReplayCompletionAlreadyScheduled;
        }
        replay.scheduled = scheduled;

        if (replay.active) |active| {
            const scheduled_ticket = scheduled.completion.ticket();
            if (!district_contract.LoadTicket.eql(active.ticket, scheduled_ticket)) {
                self.retainIssue(.{ .replay_completion_wrong_ticket = .{
                    .active = active.ticket,
                    .scheduled = scheduled_ticket,
                } });
                return error.ReplayCompletionWrongTicket;
            }
        }
        if (self.current_tick) |current_tick| {
            if (current_tick > scheduled.tick_index) {
                self.retainIssue(.{ .replay_completion_overdue = .{
                    .scheduled_tick = scheduled.tick_index,
                    .observed_tick = current_tick,
                    .ticket = scheduled.completion.ticket(),
                } });
                return error.ReplayCompletionOverdue;
            }
        }
    }

    /// Consume the completion most recently delivered to DistrictFeature.
    /// A second feature completion cannot silently replace an untaken record.
    pub fn takeConsumedCompletion(self: *Loader) ?ConsumedCompletion {
        const result = self.consumed;
        self.consumed = null;
        return result;
    }

    pub fn observation(self: *const Loader) Observation {
        const replay = switch (self.backend) {
            .live => null,
            .replay => |*state| state,
        };
        return .{
            .mode = std.meta.activeTag(self.backend),
            .current_tick = self.current_tick,
            .active_ticket = if (replay) |state|
                if (state.active) |active| active.ticket else null
            else
                null,
            .scheduled_tick = if (replay) |state|
                if (state.scheduled) |scheduled| scheduled.tick_index else null
            else
                null,
            .scheduled_ticket = if (replay) |state|
                if (state.scheduled) |scheduled| scheduled.completion.ticket() else null
            else
                null,
            .consumed_waiting = self.consumed != null,
            .issue = self.issue,
        };
    }

    /// Preserve the existing worker-facing diagnostic contract without
    /// exposing whether the feature is backed by a live thread or recorded
    /// ingress. Replay values describe the logical loader state only.
    pub fn diagnostics(self: *Loader) district_worker.Diagnostics {
        return switch (self.backend) {
            .live => |*worker| worker.diagnostics(),
            .replay => |*state| .{
                .state = if (state.active == null)
                    .idle
                else if (state.scheduled != null)
                    .completion_ready
                else if (state.cancellation_requested)
                    .cancelling
                else
                    .working,
                .generation = if (state.active) |active|
                    active.ticket.generation
                else
                    null,
                .started = state.active != null,
                .cancellation_requested = state.cancellation_requested,
                .completion_kind = if (state.scheduled) |scheduled| switch (scheduled.completion) {
                    .ready => .ready,
                    .cancelled => .cancelled,
                    .failed => .failed,
                } else null,
            },
        };
    }

    pub fn request(
        self: *Loader,
        request_value: district_contract.LoadRequest,
    ) !district_contract.RequestDisposition {
        return switch (self.backend) {
            .live => |*worker| worker.request(request_value),
            .replay => |*replay| self.requestReplay(replay, request_value),
        };
    }

    pub fn cancel(
        self: *Loader,
        ticket: district_contract.LoadTicket,
    ) district_contract.CancelDisposition {
        return switch (self.backend) {
            .live => |*worker| worker.cancel(ticket),
            .replay => |*replay| cancelReplay(replay, ticket),
        };
    }

    pub fn poll(
        self: *Loader,
        ticket: district_contract.LoadTicket,
    ) district_contract.PollResult {
        return switch (self.backend) {
            .live => |*worker| blk: {
                const result = worker.poll(ticket);
                if (result == .completion) {
                    self.retainConsumed(result.completion);
                }
                break :blk result;
            },
            .replay => |*replay| self.pollReplay(replay, ticket),
        };
    }

    fn requestReplay(
        self: *Loader,
        replay: *ReplayState,
        request_value: district_contract.LoadRequest,
    ) district_contract.RequestDisposition {
        if (!request_value.ticket.isValid()) return .invalid_ticket;
        if (replay.active != null) return .busy;
        if (request_value.ticket.generation <= replay.last_generation) return .stale;

        replay.active = request_value;
        replay.last_generation = request_value.ticket.generation;
        replay.cancellation_requested = false;
        if (replay.scheduled) |scheduled| {
            const scheduled_ticket = scheduled.completion.ticket();
            if (!district_contract.LoadTicket.eql(request_value.ticket, scheduled_ticket)) {
                self.retainIssue(.{ .replay_completion_wrong_ticket = .{
                    .active = request_value.ticket,
                    .scheduled = scheduled_ticket,
                } });
            }
        }
        return .accepted;
    }

    fn pollReplay(
        self: *Loader,
        replay: *ReplayState,
        ticket: district_contract.LoadTicket,
    ) district_contract.PollResult {
        if (!ticket.isValid()) return .invalid_ticket;
        const active = replay.active orelse return .idle;
        if (!district_contract.LoadTicket.eql(active.ticket, ticket)) {
            return .{ .stale = active.ticket };
        }

        const scheduled = replay.scheduled orelse return replayPending();
        const scheduled_ticket = scheduled.completion.ticket();
        if (!district_contract.LoadTicket.eql(active.ticket, scheduled_ticket)) {
            self.retainIssue(.{ .replay_completion_wrong_ticket = .{
                .active = active.ticket,
                .scheduled = scheduled_ticket,
            } });
            return replayPending();
        }
        const current_tick = self.current_tick orelse {
            self.retainIssue(.current_tick_missing);
            return replayPending();
        };
        if (current_tick < scheduled.tick_index) return replayPending();
        if (current_tick > scheduled.tick_index) {
            self.retainIssue(.{ .replay_completion_overdue = .{
                .scheduled_tick = scheduled.tick_index,
                .observed_tick = current_tick,
                .ticket = scheduled_ticket,
            } });
            return replayPending();
        }

        const completion: district_contract.Completion = if (replay.cancellation_requested)
            .{ .cancelled = active.ticket }
        else
            scheduled.completion;
        replay.active = null;
        replay.scheduled = null;
        replay.cancellation_requested = false;
        self.retainConsumed(completion);
        return .{ .completion = completion };
    }

    fn retainConsumed(
        self: *Loader,
        completion: district_contract.Completion,
    ) void {
        if (self.consumed != null) {
            self.retainIssue(.consumed_completion_not_taken);
            return;
        }
        const tick_index = self.current_tick orelse blk: {
            self.retainIssue(.current_tick_missing);
            break :blk 0;
        };
        self.consumed = .{
            .tick_index = tick_index,
            .completion = completion,
        };
    }

    fn retainIssue(self: *Loader, issue: Issue) void {
        if (self.issue == null) self.issue = issue;
    }
};

fn cancelReplay(
    replay: *ReplayState,
    ticket: district_contract.LoadTicket,
) district_contract.CancelDisposition {
    if (!ticket.isValid()) return .invalid_ticket;
    const active = replay.active orelse return .idle;
    if (!district_contract.LoadTicket.eql(active.ticket, ticket)) return .stale;
    replay.cancellation_requested = true;
    return .requested;
}

fn replayPending() district_contract.PollResult {
    return .{ .pending = .working };
}

fn validateCompletion(completion: district_contract.Completion) !void {
    const ticket = completion.ticket();
    try ticket.validate();
    switch (completion) {
        .ready => |ready| {
            try ready.build.validate();
            if (!district_contract.ChunkCoord.eql(ready.ticket.coord, ready.build.coord)) {
                return error.ReplayCompletionCoordinateMismatch;
            }
        },
        .cancelled => {},
        .failed => {},
    }
}

comptime {
    district_contract.assertLoaderImplementation(Loader);
}

fn testTicket(generation: u64) district_contract.LoadTicket {
    return .{ .coord = .{ .x = 2, .z = -3 }, .generation = generation };
}

fn testRequest(ticket: district_contract.LoadTicket) district_contract.LoadRequest {
    return .{
        .ticket = ticket,
        .recipe_version = sandbox_recipe.current_recipe_version,
    };
}

fn readyCompletion(ticket: district_contract.LoadTicket) district_contract.Completion {
    return .{ .ready = .{
        .ticket = ticket,
        .build = sandbox_recipe.build(
            ticket.coord,
            sandbox_recipe.current_recipe_version,
        ).ready,
    } };
}

test "replay releases validated completion only at its exact tick" {
    var loader = Loader.initReplay();
    defer loader.deinit();
    const ticket = testTicket(1);
    try std.testing.expectEqual(
        district_contract.RequestDisposition.accepted,
        try loader.request(testRequest(ticket)),
    );
    try loader.scheduleReplayCompletion(.{
        .tick_index = 3,
        .completion = readyCompletion(ticket),
    });

    try loader.setCurrentTick(2);
    try std.testing.expect(loader.poll(ticket) == .pending);
    try std.testing.expect(loader.observation().issue == null);
    try std.testing.expect(loader.takeConsumedCompletion() == null);

    try loader.setCurrentTick(3);
    const delivered = switch (loader.poll(ticket)) {
        .completion => |completion| completion,
        else => return error.ExpectedReplayCompletion,
    };
    try std.testing.expectEqualDeep(readyCompletion(ticket), delivered);
    const retained = loader.takeConsumedCompletion() orelse
        return error.ExpectedRetainedCompletion;
    try std.testing.expectEqual(@as(u64, 3), retained.tick_index);
    try std.testing.expectEqualDeep(delivered, retained.completion);
    try std.testing.expect(loader.poll(ticket) == .idle);
}

test "replay cancellation before same-tick poll wins over ready completion" {
    var loader = Loader.initReplay();
    defer loader.deinit();
    const ticket = testTicket(7);
    try std.testing.expectEqual(
        district_contract.RequestDisposition.accepted,
        try loader.request(testRequest(ticket)),
    );
    try loader.scheduleReplayCompletion(.{
        .tick_index = 5,
        .completion = readyCompletion(ticket),
    });
    try loader.setCurrentTick(5);
    try std.testing.expectEqual(
        district_contract.CancelDisposition.requested,
        loader.cancel(ticket),
    );
    const completion = switch (loader.poll(ticket)) {
        .completion => |value| value,
        else => return error.ExpectedCancelledReplayCompletion,
    };
    try std.testing.expectEqualDeep(
        district_contract.Completion{ .cancelled = ticket },
        completion,
    );
    try std.testing.expectEqualDeep(
        completion,
        loader.takeConsumedCompletion().?.completion,
    );
}

test "replay distinguishes early polling from an overdue completion" {
    var loader = Loader.initReplay();
    defer loader.deinit();
    const ticket = testTicket(11);
    try std.testing.expectEqual(
        district_contract.RequestDisposition.accepted,
        try loader.request(testRequest(ticket)),
    );
    try loader.scheduleReplayCompletion(.{
        .tick_index = 9,
        .completion = readyCompletion(ticket),
    });

    try loader.setCurrentTick(8);
    try std.testing.expect(loader.poll(ticket) == .pending);
    try std.testing.expect(loader.observation().issue == null);

    try loader.setCurrentTick(10);
    try std.testing.expect(loader.poll(ticket) == .pending);
    const overdue = loader.observation().issue.?.replay_completion_overdue;
    try std.testing.expectEqual(@as(u64, 9), overdue.scheduled_tick);
    try std.testing.expectEqual(@as(u64, 10), overdue.observed_tick);
    try std.testing.expect(district_contract.LoadTicket.eql(ticket, overdue.ticket));
    try std.testing.expect(loader.takeConsumedCompletion() == null);
}

test "replay retains a wrong scheduled ticket as structural state" {
    var loader = Loader.initReplay();
    defer loader.deinit();
    const active = testTicket(20);
    const wrong = testTicket(21);
    try std.testing.expectEqual(
        district_contract.RequestDisposition.accepted,
        try loader.request(testRequest(active)),
    );
    try std.testing.expectError(
        error.ReplayCompletionWrongTicket,
        loader.scheduleReplayCompletion(.{
            .tick_index = 4,
            .completion = readyCompletion(wrong),
        }),
    );
    const mismatch = loader.observation().issue.?.replay_completion_wrong_ticket;
    try std.testing.expect(district_contract.LoadTicket.eql(active, mismatch.active));
    try std.testing.expect(district_contract.LoadTicket.eql(wrong, mismatch.scheduled));
    try loader.setCurrentTick(4);
    try std.testing.expect(loader.poll(active) == .pending);
}

test "live decorator retains exactly the completion consumed by feature poll" {
    var gate = district_worker.TestGate.init(std.testing.io);
    var loader = Loader.initLiveWithTestGate(&gate);
    defer loader.deinit();
    const ticket = testTicket(31);
    try std.testing.expectEqual(
        district_contract.RequestDisposition.accepted,
        try loader.request(testRequest(ticket)),
    );
    gate.waitEntered();
    gate.release();
    gate.waitFinished();

    try loader.setCurrentTick(12);
    const delivered = switch (loader.poll(ticket)) {
        .completion => |completion| completion,
        else => return error.ExpectedLiveCompletion,
    };
    const retained = loader.takeConsumedCompletion() orelse
        return error.ExpectedRetainedCompletion;
    try std.testing.expectEqual(@as(u64, 12), retained.tick_index);
    try std.testing.expectEqualDeep(delivered, retained.completion);
    try std.testing.expect(loader.takeConsumedCompletion() == null);
}

test "replay mirrors worker busy stale and cancel ticket semantics" {
    var loader = Loader.initReplay();
    defer loader.deinit();
    const first = testTicket(41);
    const next = testTicket(42);
    try std.testing.expectEqual(
        district_contract.RequestDisposition.accepted,
        try loader.request(testRequest(first)),
    );
    try std.testing.expectEqual(
        district_contract.RequestDisposition.busy,
        try loader.request(testRequest(next)),
    );
    try std.testing.expectEqual(
        district_contract.CancelDisposition.stale,
        loader.cancel(next),
    );
    try std.testing.expectEqual(
        district_contract.CancelDisposition.requested,
        loader.cancel(first),
    );
    try loader.scheduleReplayCompletion(.{
        .tick_index = 2,
        .completion = .{ .cancelled = first },
    });
    try loader.setCurrentTick(2);
    _ = loader.poll(first);
    _ = loader.takeConsumedCompletion();

    try std.testing.expectEqual(
        district_contract.RequestDisposition.stale,
        try loader.request(testRequest(first)),
    );
    try std.testing.expectEqual(
        district_contract.RequestDisposition.accepted,
        try loader.request(testRequest(next)),
    );
}
