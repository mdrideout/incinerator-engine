//! Bounded procedural district worker for the first streaming slice.
//!
//! This adapter owns at most one short-lived thread. The thread is never
//! detached: a matching `poll` joins it before returning a completion, and
//! `deinit` cancels and joins any outstanding work. Publication is fixed-size
//! plain data protected by a small mutex; no simulation or backend pointer may
//! cross this boundary.

const std = @import("std");
const builtin = @import("builtin");
const contract = @import("district_contract");
const sandbox_recipe = @import("sandbox_district_recipe");

pub const WorkerState = enum {
    idle,
    queued,
    working,
    cancelling,
    completion_ready,
};

pub const CompletionKind = enum {
    ready,
    cancelled,
    failed,
};

pub const Diagnostics = struct {
    state: WorkerState,
    generation: ?u64,
    started: bool,
    cancellation_requested: bool,
    completion_kind: ?CompletionKind,
};

fn diagnosticState(
    has_active: bool,
    has_completion: bool,
    started: bool,
    cancel_requested: bool,
) WorkerState {
    if (!has_active) return .idle;
    if (has_completion) return .completion_ready;
    if (cancel_requested) return .cancelling;
    return if (started) .working else .queued;
}

pub const Worker = struct {
    /// `std.atomic.Mutex` is sufficient here because every critical section is
    /// a fixed-size state copy. Procedural work and thread joining occur outside
    /// the lock, except for the already-published join in `poll`.
    mutex: std.atomic.Mutex = .unlocked,
    owner_thread: std.Thread.Id,
    thread: ?std.Thread = null,
    active: ?contract.LoadRequest = null,
    completion: ?contract.Completion = null,
    last_generation: u64 = 0,
    started: bool = false,
    cancel_requested: bool = false,
    test_gate: if (builtin.is_test) ?*TestGate else void = if (builtin.is_test) null else {},

    pub fn init() Worker {
        return .{ .owner_thread = std.Thread.getCurrentId() };
    }

    /// Conformance-only constructor used to hold a real worker between
    /// observable start and publication without scheduler-dependent sleeps.
    pub fn initWithTestGate(test_gate: *TestGate) Worker {
        return .{
            .owner_thread = std.Thread.getCurrentId(),
            .test_gate = test_gate,
        };
    }

    /// The worker must already reside at its final address before this method
    /// is called and must not be moved until the job is collected or deinit
    /// joins it.
    pub fn request(
        self: *Worker,
        request_value: contract.LoadRequest,
    ) !contract.RequestDisposition {
        try self.requireOwnerThread();
        if (!request_value.ticket.isValid()) return .invalid_ticket;

        self.lock();
        defer self.unlock();
        if (self.active != null) return .busy;
        if (request_value.ticket.generation <= self.last_generation) return .stale;

        self.active = request_value;
        self.completion = null;
        self.started = false;
        self.cancel_requested = false;
        const thread = std.Thread.spawn(.{}, threadMain, .{self}) catch |err| {
            self.active = null;
            return err;
        };
        self.thread = thread;
        self.last_generation = request_value.ticket.generation;
        return .accepted;
    }

    /// Cancellation is generation-safe. It also wins over a completed but
    /// unconsumed result, matching command-before-completion tick semantics.
    pub fn cancel(
        self: *Worker,
        ticket: contract.LoadTicket,
    ) contract.CancelDisposition {
        self.assertOwnerThread();
        if (!ticket.isValid()) return .invalid_ticket;

        self.lock();
        defer self.unlock();
        const active = self.active orelse return .idle;
        if (!contract.LoadTicket.eql(active.ticket, ticket)) return .stale;

        self.cancel_requested = true;
        if (self.completion != null) {
            self.completion = .{ .cancelled = ticket };
        }
        return .requested;
    }

    /// A completion is returned exactly once. The worker thread is joined and
    /// its handle consumed before the result crosses back to the caller.
    pub fn poll(self: *Worker, ticket: contract.LoadTicket) contract.PollResult {
        self.assertOwnerThread();
        if (!ticket.isValid()) return .invalid_ticket;

        self.lock();
        defer self.unlock();
        const active = self.active orelse return .idle;
        if (!contract.LoadTicket.eql(active.ticket, ticket)) {
            return .{ .stale = active.ticket };
        }
        const completion = self.completion orelse return .{
            .pending = if (self.started) .working else .queued,
        };

        // Publishing completion is the worker's final locked operation, so it
        // cannot need this mutex again while the join completes.
        const thread = self.thread orelse @panic("district completion has no worker thread");
        thread.join();
        self.thread = null;
        self.active = null;
        self.completion = null;
        self.started = false;
        self.cancel_requested = false;
        return .{ .completion = completion };
    }

    /// Nonblocking concrete-adapter diagnostic used to synchronize lifecycle
    /// tests without wall-clock sleeps.
    pub fn hasStarted(self: *Worker, ticket: contract.LoadTicket) bool {
        self.assertOwnerThread();
        if (!ticket.isValid()) return false;
        self.lock();
        defer self.unlock();
        const active = self.active orelse return false;
        return contract.LoadTicket.eql(active.ticket, ticket) and self.started;
    }

    pub fn diagnostics(self: *Worker) Diagnostics {
        self.assertOwnerThread();
        self.lock();
        defer self.unlock();
        const completion_kind: ?CompletionKind = if (self.completion) |*completion|
            switch (completion.*) {
                .ready => .ready,
                .cancelled => .cancelled,
                .failed => .failed,
            }
        else
            null;
        return .{
            .state = diagnosticState(
                self.active != null,
                self.completion != null,
                self.started,
                self.cancel_requested,
            ),
            .generation = if (self.active) |*active| active.ticket.generation else null,
            .started = self.started,
            .cancellation_requested = self.cancel_requested,
            .completion_kind = completion_kind,
        };
    }

    pub fn deinit(self: *Worker) void {
        self.assertOwnerThread();
        self.lock();
        self.cancel_requested = true;
        const thread = self.thread;
        self.unlock();

        if (thread) |running| running.join();

        self.lock();
        self.thread = null;
        self.active = null;
        self.completion = null;
        self.started = false;
        self.cancel_requested = false;
        self.unlock();
        self.* = undefined;
    }

    fn threadMain(self: *Worker) void {
        self.lock();
        const request_value = self.active orelse {
            self.unlock();
            return;
        };
        self.started = true;
        const cancelled_at_start = self.cancel_requested;
        self.unlock();

        if (cancelled_at_start) {
            self.publish(request_value.ticket, .{ .cancelled = request_value.ticket });
            return;
        }

        if (builtin.is_test) {
            if (self.test_gate) |gate| gate.hold(self, request_value.ticket);
        }

        // Give the owner a scheduling point after work has observably started.
        // Cancellation is also checked between each bounded preparation unit.
        std.Thread.yield() catch {};
        if (self.isCancellationRequested(request_value.ticket)) {
            self.publish(request_value.ticket, .{ .cancelled = request_value.ticket });
            return;
        }

        const procedural = sandbox_recipe.build(
            request_value.ticket.coord,
            request_value.recipe_version,
        );
        if (self.isCancellationRequested(request_value.ticket)) {
            self.publish(request_value.ticket, .{ .cancelled = request_value.ticket });
            return;
        }

        const candidate: contract.Completion = switch (procedural) {
            .ready => |build| blk: {
                if (build.validationFailure()) |failure| {
                    break :blk .{ .failed = .{
                        .ticket = request_value.ticket,
                        .failure = .{ .invalid_build = failure },
                    } };
                }
                break :blk .{ .ready = .{
                    .ticket = request_value.ticket,
                    .build = build,
                } };
            },
            .failed => |failure| .{ .failed = .{
                .ticket = request_value.ticket,
                .failure = failure,
            } },
        };
        self.publish(request_value.ticket, candidate);
    }

    fn isCancellationRequested(self: *Worker, ticket: contract.LoadTicket) bool {
        self.lock();
        defer self.unlock();
        const active = self.active orelse return true;
        return !contract.LoadTicket.eql(active.ticket, ticket) or self.cancel_requested;
    }

    fn publish(
        self: *Worker,
        ticket: contract.LoadTicket,
        candidate: contract.Completion,
    ) void {
        self.lock();
        const active = self.active orelse {
            self.unlock();
            return;
        };
        if (!contract.LoadTicket.eql(active.ticket, ticket) or self.completion != null) {
            self.unlock();
            return;
        }
        self.completion = if (self.cancel_requested)
            .{ .cancelled = ticket }
        else
            candidate;
        self.unlock();
        if (builtin.is_test) {
            if (self.test_gate) |gate| gate.finished.set(gate.io);
        }
    }

    fn lock(self: *Worker) void {
        while (!self.mutex.tryLock()) {
            std.atomic.spinLoopHint();
            std.Thread.yield() catch {};
        }
    }

    fn unlock(self: *Worker) void {
        self.mutex.unlock();
    }

    fn requireOwnerThread(self: *const Worker) !void {
        if (std.Thread.getCurrentId() != self.owner_thread) {
            return error.WrongDistrictWorkerThread;
        }
    }

    fn assertOwnerThread(self: *const Worker) void {
        self.requireOwnerThread() catch
            @panic("district worker lifecycle accessed from a non-owner thread");
    }
};

/// Deterministic synchronization seam for the worker's own concurrency tests.
/// Production construction leaves this absent.
pub const TestGate = struct {
    io: std.Io,
    entered: std.Io.Event = .unset,
    released: std.Io.Event = .unset,
    finished: std.Io.Event = .unset,

    pub fn init(io: std.Io) TestGate {
        return .{ .io = io };
    }

    pub fn waitEntered(self: *TestGate) void {
        self.entered.waitUncancelable(self.io);
    }

    pub fn release(self: *TestGate) void {
        self.released.set(self.io);
    }

    pub fn waitFinished(self: *TestGate) void {
        self.finished.waitUncancelable(self.io);
    }

    pub fn reset(self: *TestGate) void {
        self.entered.reset();
        self.released.reset();
        self.finished.reset();
    }

    fn hold(self: *TestGate, worker: *Worker, ticket: contract.LoadTicket) void {
        self.entered.set(self.io);
        while (!self.released.isSet() and !worker.isCancellationRequested(ticket)) {
            std.atomic.spinLoopHint();
            std.Thread.yield() catch {};
        }
    }
};

comptime {
    contract.assertLoaderImplementation(Worker);
}

fn testTicket(generation: u64) contract.LoadTicket {
    return .{ .coord = .{ .x = 0, .z = -4 }, .generation = generation };
}

fn testRequest(ticket: contract.LoadTicket) contract.LoadRequest {
    return .{
        .ticket = ticket,
        .recipe_version = sandbox_recipe.current_recipe_version,
    };
}

fn collectFinished(
    worker: *Worker,
    gate: *TestGate,
    expected: contract.LoadTicket,
) !contract.Completion {
    gate.waitFinished();
    return switch (worker.poll(expected)) {
        .completion => |completion| completion,
        else => error.UnexpectedWorkerPoll,
    };
}

fn startAndRelease(
    worker: *Worker,
    gate: *TestGate,
    expected: contract.LoadTicket,
) !contract.Completion {
    gate.waitEntered();
    if (!worker.hasStarted(expected)) return error.WorkerDidNotStart;
    gate.release();
    return collectFinished(worker, gate, expected);
}

fn startAndCancel(
    worker: *Worker,
    gate: *TestGate,
    expected: contract.LoadTicket,
) !contract.Completion {
    gate.waitEntered();
    if (!worker.hasStarted(expected)) return error.WorkerDidNotStart;
    try std.testing.expectEqual(contract.CancelDisposition.requested, worker.cancel(expected));
    return collectFinished(worker, gate, expected);
}

fn expectCancelled(completion: contract.Completion, expected: contract.LoadTicket) !void {
    switch (completion) {
        .cancelled => |ticket| try std.testing.expect(contract.LoadTicket.eql(expected, ticket)),
        else => return error.ExpectedCancelledCompletion,
    }
}

test "district worker diagnostics distinguish every one-job lifecycle state" {
    try std.testing.expectEqual(
        WorkerState.idle,
        diagnosticState(false, false, false, false),
    );
    try std.testing.expectEqual(
        WorkerState.queued,
        diagnosticState(true, false, false, false),
    );
    try std.testing.expectEqual(
        WorkerState.working,
        diagnosticState(true, false, true, false),
    );
    try std.testing.expectEqual(
        WorkerState.cancelling,
        diagnosticState(true, false, true, true),
    );
    try std.testing.expectEqual(
        WorkerState.completion_ready,
        diagnosticState(true, true, true, true),
    );

    var gate = TestGate.init(std.testing.io);
    var worker = Worker.initWithTestGate(&gate);
    defer worker.deinit();
    var snapshot = worker.diagnostics();
    try std.testing.expectEqual(WorkerState.idle, snapshot.state);
    try std.testing.expect(!snapshot.started);
    try std.testing.expect(!snapshot.cancellation_requested);
    try std.testing.expect(snapshot.completion_kind == null);
    const expected = testTicket(91);
    try std.testing.expectEqual(
        contract.RequestDisposition.accepted,
        try worker.request(testRequest(expected)),
    );
    gate.waitEntered();
    snapshot = worker.diagnostics();
    try std.testing.expectEqual(WorkerState.working, snapshot.state);
    try std.testing.expectEqual(@as(?u64, 91), snapshot.generation);
    try std.testing.expect(snapshot.started);
    try std.testing.expect(!snapshot.cancellation_requested);
    try std.testing.expect(snapshot.completion_kind == null);
    gate.release();
    gate.waitFinished();
    snapshot = worker.diagnostics();
    try std.testing.expectEqual(WorkerState.completion_ready, snapshot.state);
    try std.testing.expectEqual(@as(?u64, 91), snapshot.generation);
    try std.testing.expect(snapshot.started);
    try std.testing.expect(!snapshot.cancellation_requested);
    try std.testing.expectEqual(CompletionKind.ready, snapshot.completion_kind.?);
    _ = switch (worker.poll(expected)) {
        .completion => |completion| completion,
        else => return error.UnexpectedWorkerPoll,
    };
    snapshot = worker.diagnostics();
    try std.testing.expectEqual(WorkerState.idle, snapshot.state);
    try std.testing.expectEqual(@as(?u64, null), snapshot.generation);
    try std.testing.expect(!snapshot.started);
    try std.testing.expect(!snapshot.cancellation_requested);
    try std.testing.expect(snapshot.completion_kind == null);
}

test "district worker returns a validated deterministic build and joins on poll" {
    var gate = TestGate.init(std.testing.io);
    var worker = Worker.initWithTestGate(&gate);
    defer worker.deinit();
    const expected = testTicket(1);
    try std.testing.expectEqual(
        contract.RequestDisposition.accepted,
        try worker.request(testRequest(expected)),
    );
    const completion = try startAndRelease(&worker, &gate, expected);
    try std.testing.expect(contract.LoadTicket.eql(expected, completion.ticket()));
    try completion.ready.build.validate();
    try std.testing.expectEqual(expected.coord, completion.ready.build.coord);
    try std.testing.expect(worker.poll(expected) == .idle);
}

test "district worker enforces one-job backpressure and stale generations" {
    var gate = TestGate.init(std.testing.io);
    var worker = Worker.initWithTestGate(&gate);
    defer worker.deinit();
    const first = testTicket(1);
    const second = testTicket(2);
    try std.testing.expectEqual(
        contract.RequestDisposition.accepted,
        try worker.request(testRequest(first)),
    );
    try std.testing.expectEqual(
        contract.RequestDisposition.busy,
        try worker.request(testRequest(second)),
    );
    try std.testing.expectEqual(contract.CancelDisposition.stale, worker.cancel(second));
    const stale_poll = worker.poll(second);
    try std.testing.expect(contract.LoadTicket.eql(first, stale_poll.stale));

    const cancelled = try startAndCancel(&worker, &gate, first);
    try expectCancelled(cancelled, first);
    try std.testing.expectEqual(
        contract.RequestDisposition.stale,
        try worker.request(testRequest(first)),
    );
    gate.reset();
    try std.testing.expectEqual(
        contract.RequestDisposition.accepted,
        try worker.request(testRequest(second)),
    );
    _ = try startAndRelease(&worker, &gate, second);
}

test "district worker cancellation after work starts is sleep-free and generation-safe" {
    var gate = TestGate.init(std.testing.io);
    var worker = Worker.initWithTestGate(&gate);
    defer worker.deinit();
    const expected = testTicket(11);
    try std.testing.expectEqual(
        contract.RequestDisposition.accepted,
        try worker.request(testRequest(expected)),
    );
    const completion = try startAndCancel(&worker, &gate, expected);
    try expectCancelled(completion, expected);
}

test "district worker reports unsupported recipes as structured failures" {
    var gate = TestGate.init(std.testing.io);
    var worker = Worker.initWithTestGate(&gate);
    defer worker.deinit();
    const expected = testTicket(21);
    try std.testing.expectEqual(
        contract.RequestDisposition.accepted,
        try worker.request(.{
            .ticket = expected,
            .recipe_version = sandbox_recipe.current_recipe_version + 1,
        }),
    );
    const completion = try startAndRelease(&worker, &gate, expected);
    try std.testing.expectEqual(
        sandbox_recipe.current_recipe_version + 1,
        completion.failed.failure.unsupported_recipe_version,
    );
}

test "district worker deinit cancels and joins started work" {
    var gate = TestGate.init(std.testing.io);
    var worker = Worker.initWithTestGate(&gate);
    const expected = testTicket(31);
    try std.testing.expectEqual(
        contract.RequestDisposition.accepted,
        try worker.request(testRequest(expected)),
    );
    gate.waitEntered();
    try std.testing.expect(worker.hasStarted(expected));
    worker.deinit();
}

test "district worker cancellation wins over a published unconsumed result" {
    var gate = TestGate.init(std.testing.io);
    var worker = Worker.initWithTestGate(&gate);
    defer worker.deinit();
    const expected = testTicket(41);
    try std.testing.expectEqual(
        contract.RequestDisposition.accepted,
        try worker.request(testRequest(expected)),
    );
    gate.waitEntered();
    gate.release();
    gate.waitFinished();
    try std.testing.expectEqual(contract.CancelDisposition.requested, worker.cancel(expected));
    const snapshot = worker.diagnostics();
    try std.testing.expectEqual(WorkerState.completion_ready, snapshot.state);
    try std.testing.expectEqual(@as(?u64, 41), snapshot.generation);
    try std.testing.expect(snapshot.started);
    try std.testing.expect(snapshot.cancellation_requested);
    try std.testing.expectEqual(CompletionKind.cancelled, snapshot.completion_kind.?);
    const completion = switch (worker.poll(expected)) {
        .completion => |value| value,
        else => return error.UnexpectedWorkerPoll,
    };
    try expectCancelled(completion, expected);
}

test "district worker rejects fallible admission from a non-owner thread" {
    var worker = Worker.init();
    defer worker.deinit();
    var rejected = std.atomic.Value(bool).init(false);
    const Probe = struct {
        fn run(target: *Worker, result: *std.atomic.Value(bool)) void {
            _ = target.request(testRequest(testTicket(51))) catch |err| {
                result.store(err == error.WrongDistrictWorkerThread, .release);
                return;
            };
        }
    };
    const thread = try std.Thread.spawn(.{}, Probe.run, .{ &worker, &rejected });
    thread.join();
    try std.testing.expect(rejected.load(.acquire));
    try std.testing.expectEqual(
        contract.RequestDisposition.accepted,
        try worker.request(testRequest(testTicket(51))),
    );
}
