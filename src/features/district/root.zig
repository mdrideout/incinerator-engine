//! DistrictFeature: one bounded, asynchronously prepared static district.
//!
//! Worker preparation stays behind `Loader`; this feature alone commits a
//! completed build to runtime entities and static physics bodies. Presentation
//! handles are inert data and never participate in activation readiness.

const std = @import("std");
const engine = @import("incinerator_engine");
const district_contract = @import("district_contract");

pub const max_pending_commands: usize = 16;
pub const max_outcomes: usize = 32;
pub const max_events: usize = 16;

pub const Assets = struct {
    /// One scene-level identity preserves cooked nodes, authored transforms,
    /// mesh instances, material relationships, and textures behind the
    /// renderer-owned registry boundary. Its residency is never an activation
    /// prerequisite.
    scene: engine.rendering.SceneHandle = .invalid,
};

pub const StateTag = enum { absent, loading, cancelling, active };

pub const RequestLoad = struct {
    request_id: u64,
    coord: district_contract.ChunkCoord,
    assets: Assets,
};

pub const CancelLoad = struct {
    request_id: u64,
    ticket: district_contract.LoadTicket,
};

pub const Unload = struct {
    request_id: u64,
    ticket: district_contract.LoadTicket,
};

pub const Command = union(enum) {
    request_load: RequestLoad,
    cancel_load: CancelLoad,
    unload: Unload,
};

pub const CommandKind = enum { request_load, cancel_load, unload };

pub const RejectionReason = enum {
    district_not_absent,
    district_not_loading,
    district_not_active,
    stale_ticket,
    loader_busy,
    loader_stale,
    loader_idle,
    invalid_ticket,
};

pub const CommandRejected = struct {
    command: CommandKind,
    reason: RejectionReason,
    request_id: u64,
    ticket: ?district_contract.LoadTicket = null,
    state: StateTag,
};

pub const LoadRequested = struct {
    request_id: u64,
    ticket: district_contract.LoadTicket,
};

pub const CancellationRequested = struct {
    request_id: u64,
    ticket: district_contract.LoadTicket,
};

pub const Activated = struct {
    request_id: u64,
    ticket: district_contract.LoadTicket,
    id: engine.PersistentId,
    coord: district_contract.ChunkCoord,
    static_box_count: u8,
};

pub const LoadCancelled = struct {
    ticket: district_contract.LoadTicket,
};

pub const LoadFailed = struct {
    request_id: u64,
    ticket: district_contract.LoadTicket,
    failure: district_contract.Failure,
};

pub const Unloaded = struct {
    request_id: u64,
    ticket: district_contract.LoadTicket,
    id: engine.PersistentId,
};

pub const Outcome = union(enum) {
    load_requested: LoadRequested,
    cancellation_requested: CancellationRequested,
    activated: Activated,
    cancelled: LoadCancelled,
    load_failed: LoadFailed,
    unloaded: Unloaded,
    rejected: CommandRejected,
};

pub const LoadStarted = struct {
    ticket: district_contract.LoadTicket,
    coord: district_contract.ChunkCoord,
};

pub const DistrictActivated = struct {
    ticket: district_contract.LoadTicket,
    id: engine.PersistentId,
};

pub const DistrictDeactivated = struct {
    ticket: district_contract.LoadTicket,
    id: ?engine.PersistentId,
    reason: enum { cancelled, failed, unloaded },
};

pub const StaleCompletion = struct {
    expected: district_contract.LoadTicket,
    received: district_contract.LoadTicket,
};

pub const Event = union(enum) {
    load_started: LoadStarted,
    cancellation_started: district_contract.LoadTicket,
    activated: DistrictActivated,
    deactivated: DistrictDeactivated,
    stale_completion: StaleCompletion,
};

/// Immutable logical draw input. The renderer may resolve these handles to a
/// fallback while an independent GPU residency operation is still pending.
pub const DistrictDraw = struct {
    persistent_id: engine.PersistentId,
    ticket: district_contract.LoadTicket,
    build: district_contract.DistrictBuild,
    assets: Assets,
};

/// Logical persistence record. Transient jobs, tickets, physics handles,
/// queues, and presentation resources are deliberately excluded.
pub const DistrictV1 = struct {
    id: engine.PersistentId,
    coord: district_contract.ChunkCoord,
    recipe_version: u32,
    checksum: u64,
};

pub fn validateRecords(records: []const DistrictV1) !void {
    if (records.len > 1) return error.TooManyDistricts;
    if (records.len == 0) return;
    const record = records[0];
    try record.id.validate();
    if (record.recipe_version != district_contract.current_recipe_version) {
        return error.UnsupportedDistrictRecipeVersion;
    }
    const build = switch (district_contract.proceduralBuild(
        record.coord,
        record.recipe_version,
    )) {
        .ready => |value| value,
        .failed => return error.InvalidDistrictRecord,
    };
    try build.validate();
    if (build.checksum != record.checksum) return error.DistrictChecksumMismatch;
}

pub fn Feature(comptime StaticBodies: type, comptime Loader: type) type {
    engine.physics.assertStaticBodyImplementation(StaticBodies);
    district_contract.assertLoaderImplementation(Loader);

    return struct {
        const Self = @This();

        const District = struct {
            ticket: district_contract.LoadTicket,
            build: district_contract.DistrictBuild,
            assets: Assets,
        };

        const RuntimeBodies = struct {
            handles: [district_contract.max_static_boxes]StaticBodies.Handle = undefined,
            count: u8 = 0,
        };

        const InFlight = struct {
            request_id: u64,
            ticket: district_contract.LoadTicket,
            request_tick: u64,
            assets: Assets,
        };

        const Cancelling = struct {
            flight: InFlight,
            cancel_request_id: u64,
        };

        const Active = struct {
            request_id: u64,
            ticket: district_contract.LoadTicket,
            runtime_id: engine.RuntimeId,
        };

        const State = union(StateTag) {
            absent,
            loading: InFlight,
            cancelling: Cancelling,
            active: Active,
        };

        const QueuedCommand = struct {
            command: Command,
            eligible_tick: u64,
        };

        allocator: std.mem.Allocator,
        runtime: *engine.Runtime,
        bodies: *StaticBodies,
        loader: *Loader,
        state: State = .absent,
        next_generation: u64 = 1,
        pending: FixedQueue(QueuedCommand, max_pending_commands) = .{},
        outcomes: FixedQueue(Outcome, max_outcomes) = .{},
        events: FixedQueue(Event, max_events) = .{},
        presentation: [1]DistrictDraw = undefined,

        pub fn init(
            allocator: std.mem.Allocator,
            runtime: *engine.Runtime,
            bodies: *StaticBodies,
            loader: *Loader,
        ) Self {
            return .{
                .allocator = allocator,
                .runtime = runtime,
                .bodies = bodies,
                .loader = loader,
            };
        }

        pub fn register(self: *Self, registry: *engine.FeatureRegistry) !void {
            try registry.registerComponent(District);
            try registry.registerComponent(RuntimeBodies);
            try registry.addSystem(
                .commands,
                "district.apply_commands_and_completion",
                self,
                applyCommandsAndCompletion,
            );
        }

        pub fn deinit(self: *Self) void {
            self.runtime.assertOwnerThread();
            switch (self.state) {
                .absent => {},
                .loading => |flight| {
                    _ = self.loader.cancel(flight.ticket);
                    _ = self.loader.poll(flight.ticket);
                },
                .cancelling => |cancelling| {
                    _ = self.loader.cancel(cancelling.flight.ticket);
                    _ = self.loader.poll(cancelling.flight.ticket);
                },
                .active => |active| self.destroyActiveOrPanic(active.runtime_id),
            }
            self.* = undefined;
        }

        pub fn requestLoad(
            self: *Self,
            request_id: u64,
            coord: district_contract.ChunkCoord,
            assets: Assets,
        ) !void {
            try self.enqueue(.{ .request_load = .{
                .request_id = request_id,
                .coord = coord,
                .assets = assets,
            } });
        }

        pub fn cancelLoad(
            self: *Self,
            request_id: u64,
            ticket: district_contract.LoadTicket,
        ) !void {
            try self.enqueue(.{ .cancel_load = .{
                .request_id = request_id,
                .ticket = ticket,
            } });
        }

        pub fn unload(
            self: *Self,
            request_id: u64,
            ticket: district_contract.LoadTicket,
        ) !void {
            try self.enqueue(.{ .unload = .{
                .request_id = request_id,
                .ticket = ticket,
            } });
        }

        pub fn enqueue(self: *Self, command: Command) !void {
            try self.runtime.ensureHealthy();
            try validateCommand(command);
            try self.pending.push(.{
                .command = command,
                .eligible_tick = try self.runtime.commandTargetTick(),
            });
        }

        pub fn pollOutcome(self: *Self) ?Outcome {
            self.runtime.assertOwnerThread();
            return self.outcomes.pop();
        }

        pub fn pollEvent(self: *Self) ?Event {
            self.runtime.assertOwnerThread();
            return self.events.pop();
        }

        pub fn stateTag(self: *const Self) StateTag {
            self.runtime.assertOwnerThread();
            return std.meta.activeTag(self.state);
        }

        pub fn count(self: *const Self) usize {
            return if (self.stateTag() == .active) 1 else 0;
        }

        pub fn bodyCount(self: *const Self) usize {
            self.runtime.assertOwnerThread();
            return switch (self.state) {
                .active => |active| if (self.runtime.get(active.runtime_id, RuntimeBodies)) |bodies|
                    bodies.count
                else
                    0,
                else => 0,
            };
        }

        pub fn activeTicket(self: *const Self) ?district_contract.LoadTicket {
            self.runtime.assertOwnerThread();
            return switch (self.state) {
                .active => |active| active.ticket,
                else => null,
            };
        }

        pub fn hasPendingCommands(self: *const Self) bool {
            self.runtime.assertOwnerThread();
            return !self.pending.isEmpty();
        }

        pub fn extract(self: *Self) ![]const DistrictDraw {
            try self.runtime.ensureOwnerThread();
            const active = switch (self.state) {
                .active => |value| value,
                else => return self.presentation[0..0],
            };
            const district = self.runtime.get(active.runtime_id, District) orelse
                return error.DistrictComponentInvariantBroken;
            self.presentation[0] = .{
                .persistent_id = try self.runtime.identity(active.runtime_id),
                .ticket = district.ticket,
                .build = district.build,
                .assets = district.assets,
            };
            return self.presentation[0..1];
        }

        pub fn snapshotRecords(
            self: *Self,
            allocator: std.mem.Allocator,
        ) ![]DistrictV1 {
            try self.runtime.ensureSnapshotBoundary();
            if (self.hasPendingCommands()) return error.CommandsPending;
            return switch (self.state) {
                .loading, .cancelling => error.DistrictTransitionPending,
                .absent => allocator.alloc(DistrictV1, 0),
                .active => |active| blk: {
                    const district = self.runtime.get(active.runtime_id, District) orelse
                        return error.DistrictComponentInvariantBroken;
                    const records = try allocator.alloc(DistrictV1, 1);
                    records[0] = .{
                        .id = try self.runtime.identity(active.runtime_id),
                        .coord = district.build.coord,
                        .recipe_version = district.build.recipe_version,
                        .checksum = district.build.checksum,
                    };
                    break :blk records;
                },
            };
        }

        pub fn restoreRecords(
            self: *Self,
            records: []const DistrictV1,
            assets: Assets,
        ) !void {
            try self.runtime.ensureOwnerThread();
            try validateRecords(records);
            if (self.stateTag() != .absent or self.hasPendingCommands()) {
                return error.RestoreRequiresEmptyFeature;
            }
            if (records.len == 0) return;
            const record = records[0];
            const build = switch (district_contract.proceduralBuild(
                record.coord,
                record.recipe_version,
            )) {
                .ready => |value| value,
                .failed => return error.InvalidDistrictRecord,
            };
            if (self.next_generation == 0) return error.DistrictGenerationExhausted;
            const ticket = district_contract.LoadTicket{
                .coord = record.coord,
                .generation = self.next_generation,
            };
            self.next_generation +%= 1;
            const runtime_id = try self.activateNow(build, assets, ticket, record.id);
            self.state = .{ .active = .{
                .request_id = 0,
                .ticket = ticket,
                .runtime_id = runtime_id,
            } };
        }

        fn applyCommandsAndCompletion(
            raw: *anyopaque,
            _: *engine.Runtime,
            tick: engine.TickContext,
        ) !void {
            const self: *Self = @ptrCast(@alignCast(raw));

            // Commands always win over a completion observed in the same tick.
            while (self.pending.peek()) |queued| {
                if (queued.eligible_tick > tick.tick_index) break;
                if (self.outcomes.isFull() or self.events.isFull()) {
                    return error.DistrictOutputBackpressure;
                }
                const due = self.pending.pop().?;
                try self.applyCommand(due.command, tick.tick_index);
            }

            try self.pollOneCompletion(tick.tick_index);
        }

        fn applyCommand(self: *Self, command: Command, tick_index: u64) !void {
            switch (command) {
                .request_load => |request| try self.applyRequest(request, tick_index),
                .cancel_load => |cancel| try self.applyCancel(cancel),
                .unload => |request| try self.applyUnload(request),
            }
        }

        fn applyRequest(self: *Self, request: RequestLoad, tick_index: u64) !void {
            if (self.stateTag() != .absent) {
                return self.reject(.request_load, .district_not_absent, request.request_id, null);
            }
            if (self.next_generation == 0) return error.DistrictGenerationExhausted;
            const ticket = district_contract.LoadTicket{
                .coord = request.coord,
                .generation = self.next_generation,
            };
            self.next_generation +%= 1;
            switch (try self.loader.request(.{ .ticket = ticket })) {
                .accepted => {
                    self.state = .{ .loading = .{
                        .request_id = request.request_id,
                        .ticket = ticket,
                        .request_tick = tick_index,
                        .assets = request.assets,
                    } };
                    self.outcomes.pushAssumeCapacity(.{ .load_requested = .{
                        .request_id = request.request_id,
                        .ticket = ticket,
                    } });
                    self.events.pushAssumeCapacity(.{ .load_started = .{
                        .ticket = ticket,
                        .coord = request.coord,
                    } });
                },
                .busy => try self.reject(.request_load, .loader_busy, request.request_id, ticket),
                .stale => try self.reject(.request_load, .loader_stale, request.request_id, ticket),
                .invalid_ticket => try self.reject(
                    .request_load,
                    .invalid_ticket,
                    request.request_id,
                    ticket,
                ),
            }
        }

        fn applyCancel(self: *Self, cancel: CancelLoad) !void {
            const flight = switch (self.state) {
                .loading => |value| value,
                .cancelling => |value| {
                    const reason: RejectionReason = if (district_contract.LoadTicket.eql(
                        value.flight.ticket,
                        cancel.ticket,
                    )) .district_not_loading else .stale_ticket;
                    return self.reject(.cancel_load, reason, cancel.request_id, cancel.ticket);
                },
                else => return self.reject(
                    .cancel_load,
                    .district_not_loading,
                    cancel.request_id,
                    cancel.ticket,
                ),
            };
            if (!district_contract.LoadTicket.eql(flight.ticket, cancel.ticket)) {
                return self.reject(.cancel_load, .stale_ticket, cancel.request_id, cancel.ticket);
            }
            switch (self.loader.cancel(cancel.ticket)) {
                .requested => {
                    self.state = .{ .cancelling = .{
                        .flight = flight,
                        .cancel_request_id = cancel.request_id,
                    } };
                    self.outcomes.pushAssumeCapacity(.{ .cancellation_requested = .{
                        .request_id = cancel.request_id,
                        .ticket = cancel.ticket,
                    } });
                    self.events.pushAssumeCapacity(.{ .cancellation_started = cancel.ticket });
                },
                .idle => try self.reject(.cancel_load, .loader_idle, cancel.request_id, cancel.ticket),
                .stale => try self.reject(.cancel_load, .loader_stale, cancel.request_id, cancel.ticket),
                .invalid_ticket => try self.reject(
                    .cancel_load,
                    .invalid_ticket,
                    cancel.request_id,
                    cancel.ticket,
                ),
            }
        }

        fn applyUnload(self: *Self, request: Unload) !void {
            const active = switch (self.state) {
                .active => |value| value,
                else => return self.reject(
                    .unload,
                    .district_not_active,
                    request.request_id,
                    request.ticket,
                ),
            };
            if (!district_contract.LoadTicket.eql(active.ticket, request.ticket)) {
                return self.reject(.unload, .stale_ticket, request.request_id, request.ticket);
            }
            const id = try self.runtime.identity(active.runtime_id);
            try self.destroyActive(active.runtime_id);
            self.state = .absent;
            self.outcomes.pushAssumeCapacity(.{ .unloaded = .{
                .request_id = request.request_id,
                .ticket = request.ticket,
                .id = id,
            } });
            self.events.pushAssumeCapacity(.{ .deactivated = .{
                .ticket = request.ticket,
                .id = id,
                .reason = .unloaded,
            } });
        }

        fn pollOneCompletion(self: *Self, tick_index: u64) !void {
            const flight = switch (self.state) {
                .loading => |value| value,
                .cancelling => |value| value.flight,
                else => return,
            };
            // Even a fake that is immediately ready crosses a fixed-tick
            // boundary before its build may become authoritative.
            if (tick_index <= flight.request_tick) return;
            if (self.outcomes.isFull() or self.events.isFull()) {
                return error.DistrictOutputBackpressure;
            }

            switch (self.loader.poll(flight.ticket)) {
                .pending => {},
                .completion => |completion| try self.applyCompletion(flight, completion),
                .idle => return error.DistrictLoaderUnexpectedIdle,
                .invalid_ticket => return error.DistrictLoaderInvalidCurrentTicket,
                .stale => return error.DistrictLoaderCurrentTicketStale,
            }
        }

        fn applyCompletion(
            self: *Self,
            flight: InFlight,
            completion: district_contract.Completion,
        ) !void {
            const received = completion.ticket();
            if (!district_contract.LoadTicket.eql(flight.ticket, received)) {
                self.events.pushAssumeCapacity(.{ .stale_completion = .{
                    .expected = flight.ticket,
                    .received = received,
                } });
                return;
            }

            if (self.stateTag() == .cancelling) {
                self.finishCancelled(flight.ticket);
                return;
            }

            switch (completion) {
                .ready => |ready| {
                    if (!district_contract.ChunkCoord.eql(ready.build.coord, flight.ticket.coord)) {
                        return error.DistrictBuildCoordinateMismatch;
                    }
                    if (ready.build.validationFailure()) |failure| {
                        return self.finishFailed(flight, .{ .invalid_build = failure });
                    }
                    const runtime_id = try self.activateNow(
                        ready.build,
                        flight.assets,
                        flight.ticket,
                        null,
                    );
                    const id = try self.runtime.identity(runtime_id);
                    self.state = .{ .active = .{
                        .request_id = flight.request_id,
                        .ticket = flight.ticket,
                        .runtime_id = runtime_id,
                    } };
                    self.outcomes.pushAssumeCapacity(.{ .activated = .{
                        .request_id = flight.request_id,
                        .ticket = flight.ticket,
                        .id = id,
                        .coord = ready.build.coord,
                        .static_box_count = ready.build.static_box_count,
                    } });
                    self.events.pushAssumeCapacity(.{ .activated = .{
                        .ticket = flight.ticket,
                        .id = id,
                    } });
                },
                .cancelled => self.finishCancelled(flight.ticket),
                .failed => |failed| self.finishFailed(flight, failed.failure),
            }
        }

        fn finishCancelled(self: *Self, ticket: district_contract.LoadTicket) void {
            self.state = .absent;
            self.outcomes.pushAssumeCapacity(.{ .cancelled = .{ .ticket = ticket } });
            self.events.pushAssumeCapacity(.{ .deactivated = .{
                .ticket = ticket,
                .id = null,
                .reason = .cancelled,
            } });
        }

        fn finishFailed(
            self: *Self,
            flight: InFlight,
            failure: district_contract.Failure,
        ) void {
            self.state = .absent;
            self.outcomes.pushAssumeCapacity(.{ .load_failed = .{
                .request_id = flight.request_id,
                .ticket = flight.ticket,
                .failure = failure,
            } });
            self.events.pushAssumeCapacity(.{ .deactivated = .{
                .ticket = flight.ticket,
                .id = null,
                .reason = .failed,
            } });
        }

        fn activateNow(
            self: *Self,
            build: district_contract.DistrictBuild,
            assets: Assets,
            ticket: district_contract.LoadTicket,
            restored_id: ?engine.PersistentId,
        ) !engine.RuntimeId {
            try build.validate();
            var created = RuntimeBodies{};
            errdefer self.rollbackBodies(&created);
            for (build.boxes()) |box| {
                const handle = try self.bodies.createStaticBox(.{
                    .pose = box.pose,
                    .half_extents = box.half_extents,
                });
                created.handles[created.count] = handle;
                created.count += 1;
            }

            const runtime_id = if (restored_id) |id|
                try self.runtime.createWithPersistentId(id)
            else
                try self.runtime.create();
            errdefer self.destroyRuntimeOrPanic(runtime_id);
            try self.runtime.set(runtime_id, District, .{
                .ticket = ticket,
                .build = build,
                .assets = assets,
            });
            try self.runtime.set(runtime_id, RuntimeBodies, created);
            return runtime_id;
        }

        fn destroyActive(self: *Self, runtime_id: engine.RuntimeId) !void {
            // Teardown remains available after a tick fault. Runtime.getMut is
            // intentionally health-gated, while the already-owned component
            // must still be updated as each fallible body release succeeds.
            const owned_bodies = self.runtime.get(runtime_id, RuntimeBodies) orelse
                return error.DistrictBodiesInvariantBroken;
            const bodies = @constCast(owned_bodies);
            while (bodies.count > 0) {
                const index = bodies.count - 1;
                try self.bodies.destroyBody(bodies.handles[index]);
                bodies.count = index;
            }
            try self.runtime.destroy(runtime_id);
        }

        fn destroyActiveOrPanic(self: *Self, runtime_id: engine.RuntimeId) void {
            self.destroyActive(runtime_id) catch |err| {
                std.debug.panic("district cleanup invariant failed: {s}", .{@errorName(err)});
            };
        }

        fn rollbackBodies(self: *Self, bodies: *RuntimeBodies) void {
            while (bodies.count > 0) {
                const index = bodies.count - 1;
                self.bodies.destroyBody(bodies.handles[index]) catch |err| {
                    std.debug.panic(
                        "district body rollback invariant failed: {s}",
                        .{@errorName(err)},
                    );
                };
                bodies.count = index;
            }
        }

        fn destroyRuntimeOrPanic(self: *Self, runtime_id: engine.RuntimeId) void {
            self.runtime.destroy(runtime_id) catch |err| {
                std.debug.panic(
                    "district entity rollback invariant failed: {s}",
                    .{@errorName(err)},
                );
            };
        }

        fn reject(
            self: *Self,
            command: CommandKind,
            reason: RejectionReason,
            request_id: u64,
            ticket: ?district_contract.LoadTicket,
        ) !void {
            try self.outcomes.push(.{ .rejected = .{
                .command = command,
                .reason = reason,
                .request_id = request_id,
                .ticket = ticket,
                .state = self.stateTag(),
            } });
        }
    };
}

fn validateCommand(command: Command) !void {
    switch (command) {
        .request_load => {},
        .cancel_load => |cancel| try cancel.ticket.validate(),
        .unload => |unload_request| try unload_request.ticket.validate(),
    }
}

fn FixedQueue(comptime T: type, comptime capacity: usize) type {
    if (capacity == 0) @compileError("fixed queue capacity must be nonzero");
    return struct {
        const Self = @This();

        values: [capacity]T = undefined,
        head: usize = 0,
        len: usize = 0,

        fn push(self: *Self, value: T) !void {
            if (self.len == capacity) return error.DistrictQueueFull;
            self.pushAssumeCapacity(value);
        }

        fn pushAssumeCapacity(self: *Self, value: T) void {
            std.debug.assert(self.len < capacity);
            self.values[(self.head + self.len) % capacity] = value;
            self.len += 1;
        }

        fn pop(self: *Self) ?T {
            if (self.len == 0) return null;
            const value = self.values[self.head];
            self.head = (self.head + 1) % capacity;
            self.len -= 1;
            if (self.len == 0) self.head = 0;
            return value;
        }

        fn peek(self: *const Self) ?T {
            if (self.len == 0) return null;
            return self.values[self.head];
        }

        fn isEmpty(self: *const Self) bool {
            return self.len == 0;
        }

        fn isFull(self: *const Self) bool {
            return self.len == capacity;
        }
    };
}

const FakeStaticBodies = struct {
    pub const Handle = u8;

    live: [32]bool = [_]bool{false} ** 32,
    next_handle: u8 = 0,
    live_count: u8 = 0,
    create_calls: u8 = 0,
    destroy_calls: u8 = 0,
    fail_create_call: ?u8 = null,
    fail_destroy_call: ?u8 = null,
    runtime: ?*engine.Runtime = null,
    destroy_observed_live_entity: bool = false,

    pub fn createStaticBox(
        self: *FakeStaticBodies,
        desc: engine.physics.StaticBoxDesc,
    ) !Handle {
        _ = try desc.normalized();
        self.create_calls += 1;
        if (self.fail_create_call == self.create_calls) {
            return error.InjectedStaticBodyCreateFailure;
        }
        if (self.next_handle >= self.live.len) return error.FakeBodyCapacityReached;
        const handle = self.next_handle;
        self.next_handle += 1;
        self.live[handle] = true;
        self.live_count += 1;
        return handle;
    }

    pub fn destroyBody(self: *FakeStaticBodies, handle: Handle) !void {
        if (handle >= self.live.len or !self.live[handle]) return error.InvalidFakeBody;
        self.destroy_calls += 1;
        if (self.fail_destroy_call == self.destroy_calls) {
            return error.InjectedStaticBodyDestroyFailure;
        }
        if (self.runtime) |runtime| {
            if (runtime.entityCount() != 0) self.destroy_observed_live_entity = true;
        }
        self.live[handle] = false;
        self.live_count -= 1;
    }
};

const FakeLoader = struct {
    current: ?district_contract.LoadTicket = null,
    request_disposition: district_contract.RequestDisposition = .accepted,
    pending: bool = false,
    cancelled: bool = false,
    failure: ?district_contract.Failure = null,
    stale_completion_once: ?district_contract.LoadTicket = null,
    request_calls: u8 = 0,
    cancel_calls: u8 = 0,
    poll_calls: u8 = 0,

    pub fn request(
        self: *FakeLoader,
        request_value: district_contract.LoadRequest,
    ) !district_contract.RequestDisposition {
        self.request_calls += 1;
        if (self.request_disposition != .accepted) return self.request_disposition;
        if (self.current != null) return .busy;
        self.current = request_value.ticket;
        self.cancelled = false;
        return .accepted;
    }

    pub fn cancel(
        self: *FakeLoader,
        ticket: district_contract.LoadTicket,
    ) district_contract.CancelDisposition {
        self.cancel_calls += 1;
        const current = self.current orelse return .idle;
        if (!ticket.isValid()) return .invalid_ticket;
        if (!district_contract.LoadTicket.eql(current, ticket)) return .stale;
        self.cancelled = true;
        return .requested;
    }

    pub fn poll(
        self: *FakeLoader,
        ticket: district_contract.LoadTicket,
    ) district_contract.PollResult {
        self.poll_calls += 1;
        if (!ticket.isValid()) return .invalid_ticket;
        const current = self.current orelse return .idle;
        if (!district_contract.LoadTicket.eql(current, ticket)) return .{ .stale = current };
        if (self.stale_completion_once) |stale| {
            self.stale_completion_once = null;
            const build = district_contract.proceduralBuild(
                stale.coord,
                district_contract.current_recipe_version,
            ).ready;
            return .{ .completion = .{ .ready = .{
                .ticket = stale,
                .build = build,
            } } };
        }
        if (self.pending) return .{ .pending = .working };
        self.current = null;
        if (self.cancelled) return .{ .completion = .{ .cancelled = ticket } };
        if (self.failure) |failure| {
            return .{ .completion = .{ .failed = .{
                .ticket = ticket,
                .failure = failure,
            } } };
        }
        const build = district_contract.proceduralBuild(
            ticket.coord,
            district_contract.current_recipe_version,
        ).ready;
        return .{ .completion = .{ .ready = .{
            .ticket = ticket,
            .build = build,
        } } };
    }
};

const TestFeature = Feature(FakeStaticBodies, FakeLoader);
const test_coord = district_contract.ChunkCoord{ .x = 0, .z = -4 };
const test_assets = Assets{
    .scene = .{ .index = 7, .generation = 2 },
};

fn expectLoadTicket(outcome: Outcome) !district_contract.LoadTicket {
    return switch (outcome) {
        .load_requested => |requested| requested.ticket,
        else => error.UnexpectedDistrictOutcome,
    };
}

test "ready completion crosses a tick boundary then activates and unloads in ownership order" {
    var runtime = try engine.Runtime.init(std.testing.allocator, .{
        .namespace = 601,
        .fixed_delta_seconds = 1.0 / 120.0,
    });
    defer runtime.deinit();
    var bodies = FakeStaticBodies{ .runtime = &runtime };
    var loader = FakeLoader{};
    var feature = TestFeature.init(std.testing.allocator, &runtime, &bodies, &loader);
    defer feature.deinit();
    var registry = runtime.registry();
    try feature.register(&registry);

    try feature.requestLoad(11, test_coord, test_assets);
    try runtime.tick();
    try std.testing.expectEqual(StateTag.loading, feature.stateTag());
    try std.testing.expectEqual(@as(u8, 0), loader.poll_calls);
    const ticket = try expectLoadTicket(feature.pollOutcome() orelse return error.MissingOutcome);

    try runtime.tick();
    try std.testing.expectEqual(StateTag.active, feature.stateTag());
    try std.testing.expectEqual(@as(usize, 1), feature.count());
    try std.testing.expectEqual(@as(usize, 3), feature.bodyCount());
    try std.testing.expectEqual(@as(u8, 3), bodies.live_count);
    try std.testing.expectEqual(@as(usize, 1), runtime.entityCount());
    const activated = switch (feature.pollOutcome() orelse return error.MissingOutcome) {
        .activated => |value| value,
        else => return error.UnexpectedDistrictOutcome,
    };
    try std.testing.expectEqualDeep(ticket, activated.ticket);
    try std.testing.expectEqual(@as(u8, 3), activated.static_box_count);
    const draws = try feature.extract();
    try std.testing.expectEqual(@as(usize, 1), draws.len);
    try std.testing.expectEqualDeep(test_assets, draws[0].assets);
    try std.testing.expectEqualDeep(test_coord, draws[0].build.coord);

    try feature.unload(12, ticket);
    try runtime.tick();
    try std.testing.expectEqual(StateTag.absent, feature.stateTag());
    try std.testing.expectEqual(@as(u8, 0), bodies.live_count);
    try std.testing.expectEqual(@as(usize, 0), runtime.entityCount());
    try std.testing.expect(bodies.destroy_observed_live_entity);
    _ = feature.pollOutcome() orelse return error.MissingOutcome;
}

test "same-tick cancellation wins over an immediately ready completion" {
    var runtime = try engine.Runtime.init(std.testing.allocator, .{
        .namespace = 602,
        .fixed_delta_seconds = 1.0 / 120.0,
    });
    defer runtime.deinit();
    var bodies = FakeStaticBodies{};
    var loader = FakeLoader{};
    var feature = TestFeature.init(std.testing.allocator, &runtime, &bodies, &loader);
    defer feature.deinit();
    var registry = runtime.registry();
    try feature.register(&registry);
    const expected_ticket = district_contract.LoadTicket{
        .coord = test_coord,
        .generation = 1,
    };

    try feature.requestLoad(21, test_coord, .{});
    try feature.cancelLoad(22, expected_ticket);
    try runtime.tick();
    try std.testing.expectEqual(StateTag.cancelling, feature.stateTag());
    try std.testing.expectEqual(@as(u8, 0), loader.poll_calls);
    _ = feature.pollOutcome() orelse return error.MissingOutcome;
    const cancel_outcome = feature.pollOutcome() orelse return error.MissingOutcome;
    try std.testing.expect(cancel_outcome == .cancellation_requested);

    try runtime.tick();
    try std.testing.expectEqual(StateTag.absent, feature.stateTag());
    try std.testing.expectEqual(@as(u8, 0), bodies.live_count);
    const terminal = feature.pollOutcome() orelse return error.MissingOutcome;
    try std.testing.expect(terminal == .cancelled);
}

test "a stale ticket rejects without preventing the current completion" {
    var runtime = try engine.Runtime.init(std.testing.allocator, .{
        .namespace = 603,
        .fixed_delta_seconds = 1.0 / 120.0,
    });
    defer runtime.deinit();
    var bodies = FakeStaticBodies{};
    var loader = FakeLoader{};
    var feature = TestFeature.init(std.testing.allocator, &runtime, &bodies, &loader);
    defer feature.deinit();
    var registry = runtime.registry();
    try feature.register(&registry);

    try feature.requestLoad(31, test_coord, .{});
    try runtime.tick();
    const ticket = try expectLoadTicket(feature.pollOutcome() orelse return error.MissingOutcome);
    const stale = district_contract.LoadTicket{ .coord = test_coord, .generation = 99 };
    try feature.cancelLoad(32, stale);
    try runtime.tick();
    const rejected = switch (feature.pollOutcome() orelse return error.MissingOutcome) {
        .rejected => |value| value,
        else => return error.UnexpectedDistrictOutcome,
    };
    try std.testing.expectEqual(RejectionReason.stale_ticket, rejected.reason);
    const activated = switch (feature.pollOutcome() orelse return error.MissingOutcome) {
        .activated => |value| value,
        else => return error.UnexpectedDistrictOutcome,
    };
    try std.testing.expectEqualDeep(ticket, activated.ticket);
    try std.testing.expectEqual(StateTag.active, feature.stateTag());
}

test "a stale completion is diagnosed and cannot mutate the current generation" {
    var runtime = try engine.Runtime.init(std.testing.allocator, .{
        .namespace = 604,
        .fixed_delta_seconds = 1.0 / 120.0,
    });
    defer runtime.deinit();
    var bodies = FakeStaticBodies{};
    var loader = FakeLoader{
        .stale_completion_once = .{ .coord = test_coord, .generation = 77 },
    };
    var feature = TestFeature.init(std.testing.allocator, &runtime, &bodies, &loader);
    defer feature.deinit();
    var registry = runtime.registry();
    try feature.register(&registry);

    try feature.requestLoad(41, test_coord, .{});
    try runtime.tick();
    _ = feature.pollOutcome();
    _ = feature.pollEvent();
    try runtime.tick();
    try std.testing.expectEqual(StateTag.loading, feature.stateTag());
    const event = feature.pollEvent() orelse return error.MissingEvent;
    try std.testing.expect(event == .stale_completion);
    try std.testing.expectEqual(@as(u8, 0), bodies.live_count);
    try runtime.tick();
    try std.testing.expectEqual(StateTag.active, feature.stateTag());
    try std.testing.expectEqual(@as(u8, 3), bodies.live_count);
}

test "activation body failure rolls back the entire candidate" {
    var runtime = try engine.Runtime.init(std.testing.allocator, .{
        .namespace = 605,
        .fixed_delta_seconds = 1.0 / 120.0,
    });
    defer runtime.deinit();
    var bodies = FakeStaticBodies{ .fail_create_call = 2 };
    var loader = FakeLoader{};
    var feature = TestFeature.init(std.testing.allocator, &runtime, &bodies, &loader);
    defer feature.deinit();
    var registry = runtime.registry();
    try feature.register(&registry);

    try feature.requestLoad(51, test_coord, .{});
    try runtime.tick();
    try std.testing.expectError(error.InjectedStaticBodyCreateFailure, runtime.tick());
    try std.testing.expect(runtime.isFaulted());
    try std.testing.expectEqual(@as(u8, 0), bodies.live_count);
    try std.testing.expectEqual(@as(usize, 0), runtime.entityCount());
}

test "partial unload failure retains only remaining ownership for fault cleanup" {
    var runtime = try engine.Runtime.init(std.testing.allocator, .{
        .namespace = 609,
        .fixed_delta_seconds = 1.0 / 120.0,
    });
    defer runtime.deinit();
    var bodies = FakeStaticBodies{};
    var loader = FakeLoader{};
    var feature = TestFeature.init(std.testing.allocator, &runtime, &bodies, &loader);
    var feature_live = true;
    defer if (feature_live) feature.deinit();
    var registry = runtime.registry();
    try feature.register(&registry);
    try feature.requestLoad(55, test_coord, .{});
    try runtime.tick();
    const ticket = try expectLoadTicket(feature.pollOutcome() orelse return error.MissingOutcome);
    try runtime.tick();
    _ = feature.pollOutcome();
    bodies.fail_destroy_call = 2;

    try feature.unload(56, ticket);
    try std.testing.expectError(error.InjectedStaticBodyDestroyFailure, runtime.tick());
    try std.testing.expect(runtime.isFaulted());
    try std.testing.expectEqual(StateTag.active, feature.stateTag());
    try std.testing.expectEqual(@as(u8, 2), bodies.live_count);
    try std.testing.expectEqual(@as(usize, 1), runtime.entityCount());

    feature.deinit();
    feature_live = false;
    try std.testing.expectEqual(@as(u8, 0), bodies.live_count);
    try std.testing.expectEqual(@as(usize, 0), runtime.entityCount());
}

test "snapshot requires quiescence and active restore is byte-stable" {
    var record: DistrictV1 = undefined;
    {
        var runtime = try engine.Runtime.init(std.testing.allocator, .{
            .namespace = 606,
            .fixed_delta_seconds = 1.0 / 120.0,
        });
        defer runtime.deinit();
        var bodies = FakeStaticBodies{};
        var loader = FakeLoader{};
        var feature = TestFeature.init(std.testing.allocator, &runtime, &bodies, &loader);
        defer feature.deinit();
        var registry = runtime.registry();
        try feature.register(&registry);
        try feature.requestLoad(61, test_coord, test_assets);
        try runtime.tick();
        try std.testing.expectError(
            error.DistrictTransitionPending,
            feature.snapshotRecords(std.testing.allocator),
        );
        try runtime.tick();
        const records = try feature.snapshotRecords(std.testing.allocator);
        defer std.testing.allocator.free(records);
        try std.testing.expectEqual(@as(usize, 1), records.len);
        record = records[0];
    }

    var restored_runtime = try engine.Runtime.init(std.testing.allocator, .{
        .namespace = 606,
        .fixed_delta_seconds = 1.0 / 120.0,
        .next_local_id = record.id.local + 1,
    });
    defer restored_runtime.deinit();
    var restored_bodies = FakeStaticBodies{};
    var restored_loader = FakeLoader{};
    var restored = TestFeature.init(
        std.testing.allocator,
        &restored_runtime,
        &restored_bodies,
        &restored_loader,
    );
    defer restored.deinit();
    var restored_registry = restored_runtime.registry();
    try restored.register(&restored_registry);
    try restored.restoreRecords((&record)[0..1], test_assets);
    const second = try restored.snapshotRecords(std.testing.allocator);
    defer std.testing.allocator.free(second);
    try std.testing.expectEqual(@as(usize, 1), second.len);
    try std.testing.expectEqualDeep(record, second[0]);
    try std.testing.expectEqual(@as(u8, 3), restored_bodies.live_count);
    try std.testing.expectEqualDeep(test_assets, (try restored.extract())[0].assets);
}

test "record validation and restore identity failure leave no candidate bodies" {
    const build = district_contract.proceduralBuild(
        test_coord,
        district_contract.current_recipe_version,
    ).ready;
    var record = DistrictV1{
        .id = .{ .namespace = 610, .local = 1 },
        .coord = test_coord,
        .recipe_version = district_contract.current_recipe_version,
        .checksum = build.checksum,
    };
    try validateRecords((&record)[0..1]);
    record.checksum +%= 1;
    try std.testing.expectError(
        error.DistrictChecksumMismatch,
        validateRecords((&record)[0..1]),
    );
    record.checksum = build.checksum;

    var runtime = try engine.Runtime.init(std.testing.allocator, .{
        .namespace = 610,
        .fixed_delta_seconds = 1.0 / 120.0,
    });
    defer runtime.deinit();
    const existing = try runtime.createWithPersistentId(record.id);
    var bodies = FakeStaticBodies{};
    var loader = FakeLoader{};
    var feature = TestFeature.init(std.testing.allocator, &runtime, &bodies, &loader);
    defer feature.deinit();
    var registry = runtime.registry();
    try feature.register(&registry);
    try std.testing.expectError(
        error.PersistentIdAlreadyIssued,
        feature.restoreRecords((&record)[0..1], .{}),
    );
    try std.testing.expectEqual(StateTag.absent, feature.stateTag());
    try std.testing.expectEqual(@as(u8, 0), bodies.live_count);
    try std.testing.expectEqual(@as(usize, 1), runtime.entityCount());
    try runtime.destroy(existing);
}

test "worker failure is typed and returns the feature to absent" {
    var runtime = try engine.Runtime.init(std.testing.allocator, .{
        .namespace = 607,
        .fixed_delta_seconds = 1.0 / 120.0,
    });
    defer runtime.deinit();
    var bodies = FakeStaticBodies{};
    var loader = FakeLoader{
        .failure = .{ .unsupported_recipe_version = 99 },
    };
    var feature = TestFeature.init(std.testing.allocator, &runtime, &bodies, &loader);
    defer feature.deinit();
    var registry = runtime.registry();
    try feature.register(&registry);
    try feature.requestLoad(71, test_coord, .{});
    try runtime.tick();
    _ = feature.pollOutcome();
    try runtime.tick();
    const failed = switch (feature.pollOutcome() orelse return error.MissingOutcome) {
        .load_failed => |value| value,
        else => return error.UnexpectedDistrictOutcome,
    };
    try std.testing.expectEqual(@as(u32, 99), failed.failure.unsupported_recipe_version);
    try std.testing.expectEqual(StateTag.absent, feature.stateTag());
    try std.testing.expectEqual(@as(u8, 0), bodies.live_count);
}

test "pending command storage is explicitly bounded" {
    var runtime = try engine.Runtime.init(std.testing.allocator, .{
        .namespace = 608,
        .fixed_delta_seconds = 1.0 / 120.0,
    });
    defer runtime.deinit();
    var bodies = FakeStaticBodies{};
    var loader = FakeLoader{};
    var feature = TestFeature.init(std.testing.allocator, &runtime, &bodies, &loader);
    defer feature.deinit();
    var registry = runtime.registry();
    try feature.register(&registry);
    for (0..max_pending_commands) |index| {
        try feature.requestLoad(@intCast(index), test_coord, .{});
    }
    try std.testing.expectError(
        error.DistrictQueueFull,
        feature.requestLoad(999, test_coord, .{}),
    );
}

test "full outcome storage faults explicitly and in-flight teardown remains safe" {
    var runtime = try engine.Runtime.init(std.testing.allocator, .{
        .namespace = 611,
        .fixed_delta_seconds = 1.0 / 120.0,
    });
    defer runtime.deinit();
    var bodies = FakeStaticBodies{};
    var loader = FakeLoader{};
    var feature = TestFeature.init(std.testing.allocator, &runtime, &bodies, &loader);
    var feature_live = true;
    defer if (feature_live) feature.deinit();
    var registry = runtime.registry();
    try feature.register(&registry);

    for (0..max_pending_commands) |index| {
        try feature.requestLoad(@intCast(index), test_coord, .{});
    }
    try runtime.tick();
    try std.testing.expectEqual(StateTag.loading, feature.stateTag());
    for (0..max_pending_commands) |index| {
        try feature.requestLoad(@intCast(100 + index), test_coord, .{});
    }
    try std.testing.expectError(error.DistrictOutputBackpressure, runtime.tick());
    try std.testing.expect(runtime.isFaulted());

    feature.deinit();
    feature_live = false;
    try std.testing.expectEqual(@as(u8, 0), bodies.live_count);
    try std.testing.expectEqual(@as(usize, 0), runtime.entityCount());
}

test "full event storage faults explicitly and in-flight teardown remains safe" {
    var runtime = try engine.Runtime.init(std.testing.allocator, .{
        .namespace = 612,
        .fixed_delta_seconds = 1.0 / 120.0,
    });
    defer runtime.deinit();
    var bodies = FakeStaticBodies{};
    var loader = FakeLoader{};
    var feature = TestFeature.init(std.testing.allocator, &runtime, &bodies, &loader);
    var feature_live = true;
    defer if (feature_live) feature.deinit();
    var registry = runtime.registry();
    try feature.register(&registry);

    // Five complete cycles retain fifteen unread events while outcomes are
    // drained normally.
    for (0..5) |cycle| {
        try feature.requestLoad(@intCast(cycle * 2), test_coord, .{});
        try runtime.tick();
        const ticket = try expectLoadTicket(feature.pollOutcome() orelse
            return error.MissingOutcome);
        try runtime.tick();
        if ((feature.pollOutcome() orelse return error.MissingOutcome) != .activated) {
            return error.UnexpectedDistrictOutcome;
        }
        try feature.unload(@intCast(cycle * 2 + 1), ticket);
        try runtime.tick();
        if ((feature.pollOutcome() orelse return error.MissingOutcome) != .unloaded) {
            return error.UnexpectedDistrictOutcome;
        }
    }

    try feature.requestLoad(100, test_coord, .{});
    try runtime.tick();
    _ = try expectLoadTicket(feature.pollOutcome() orelse return error.MissingOutcome);
    try std.testing.expectError(error.DistrictOutputBackpressure, runtime.tick());
    try std.testing.expect(runtime.isFaulted());

    feature.deinit();
    feature_live = false;
    try std.testing.expectEqual(@as(u8, 0), bodies.live_count);
    try std.testing.expectEqual(@as(usize, 0), runtime.entityCount());
}
