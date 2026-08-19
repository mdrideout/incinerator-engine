//! One-world macOS authority composition used by the M3 headless product.
//!
//! This module owns the only simulation instance in the process and the
//! bounded external-producer router in front of it. It deliberately contains
//! no transport: future networking must adapt to this capability boundary
//! without entering feature or simulation internals.

const std = @import("std");
const crate_feature = @import("crate_contract");
const simulation = @import("sandbox_simulation");
const simulation_snapshot = @import("simulation_snapshot");
const sandbox_contracts = @import("sandbox_host_contracts");
const sandbox_diagnostics = @import("sandbox_diagnostics_contract");
const npc_contract = @import("npc_contract");
const external_producers = @import("external_producers");
const sandbox_save = @import("sandbox_save");

pub const producer_limits = external_producers.Limits{
    .producer_capacity = 2,
    .ingress_capacity = 16,
    .transaction_capacity = 16,
    .pending_quota_per_producer = 8,
    .result_capacity_per_producer = 8,
};

pub const ProducerRouter = external_producers.Router(crate_feature, producer_limits);
pub const ProducerHandle = external_producers.ProducerHandle;
pub const ProducerRegistration = external_producers.Registration;
pub const ProducerSubmitStatus = external_producers.SubmitStatus;
pub const ProducerResult = ProducerRouter.Result;
pub const ProducerPollResult = ProducerRouter.PollResult;
pub const ProducerDiagnostics = ProducerRouter.Diagnostics;

pub const internal_outcome_capacity: usize = crate_feature.max_outcomes;

pub const TickReport = struct {
    transferred_commands: u32,
    terminal_submission_rejections: u32,
    routed_results: u32,
    internal_outcomes: u32,
};

pub const Diagnostics = struct {
    healthy: bool,
    world: sandbox_diagnostics.Diagnostics,
    producers: ProducerDiagnostics,
    internal_outcomes: QueueDiagnostics,
};

pub const QueueDiagnostics = struct {
    occupancy: u32,
    capacity: u32,
    high_water: u32,
    reservations: u32,
};

pub const Authority = struct {
    world: simulation.Simulation,
    router: ProducerRouter = ProducerRouter.init(),
    healthy: bool = true,
    submit_fault: ?anyerror = null,
    internal_outcomes: [internal_outcome_capacity]crate_feature.Outcome = undefined,
    internal_head: usize = 0,
    internal_len: usize = 0,
    internal_reservations: usize = 0,
    internal_high_water: u32 = 0,

    pub fn initFresh(
        allocator: std.mem.Allocator,
        config: sandbox_contracts.Config,
    ) !Authority {
        return .{ .world = try simulation.Simulation.init(allocator, config) };
    }

    pub fn initRestored(
        allocator: std.mem.Allocator,
        payload: []const u8,
        config: sandbox_contracts.Config,
    ) !Authority {
        return .{ .world = try simulation.Simulation.fromSnapshotForWorld(
            allocator,
            payload,
            config,
            .{},
        ) };
    }

    pub fn deinit(self: *Authority) void {
        self.world.deinit();
        self.* = undefined;
    }

    pub fn registerProducer(self: *Authority) ProducerRegistration {
        if (!self.healthy) _ = self.router.beginShutdown();
        return self.router.register();
    }

    pub fn unregisterProducer(
        self: *Authority,
        handle: ProducerHandle,
    ) external_producers.UnregisterStatus {
        return self.router.unregister(handle);
    }

    pub fn submitExternal(
        self: *Authority,
        handle: ProducerHandle,
        relocation: crate_feature.RelocateCrate,
    ) ProducerSubmitStatus {
        if (!self.healthy) _ = self.router.beginShutdown();
        return self.router.submit(handle, relocation);
    }

    /// Internal commands are intentionally explicit. Their outcomes are
    /// retained in a separate bounded queue and can never be consumed by an
    /// external producer merely because their union type is shared.
    pub fn submitInternal(
        self: *Authority,
        command: crate_feature.Command,
    ) !void {
        if (!self.healthy) return error.HeadlessAuthorityUnhealthy;
        if (self.router.diagnostics().lifecycle != .accepting) {
            return error.HeadlessAuthorityNotAccepting;
        }
        if (command == .relocate) {
            return error.InternalRelocationRequiresProducerOwnership;
        }
        // Retain one emergency slot for a structurally unexpected handback so
        // even protocol-fault evidence is never silently discarded.
        if (self.internal_len + self.internal_reservations >=
            internal_outcome_capacity - 1)
        {
            return error.InternalOutcomeQueueFull;
        }
        self.world.submit(command) catch |err| switch (err) {
            error.RuntimeFaulted,
            error.RuntimeDeinitialized,
            error.TickCounterExhausted,
            => {
                self.enterFault();
                return err;
            },
            else => return err,
        };
        self.internal_reservations += 1;
    }

    pub fn pollInternalOutcome(self: *Authority) ?crate_feature.Outcome {
        if (self.internal_len == 0) return null;
        const result = self.internal_outcomes[self.internal_head];
        self.internal_head = (self.internal_head + 1) % internal_outcome_capacity;
        self.internal_len -= 1;
        if (self.internal_len == 0) self.internal_head = 0;
        return result;
    }

    pub fn pollProducerResult(
        self: *Authority,
        handle: ProducerHandle,
    ) ProducerPollResult {
        return self.router.pollResult(handle);
    }

    /// One fixed authority tick. Accepted external commands transfer before
    /// the world step; every crate outcome is then routed or retained exactly
    /// once. Any unowned relocation is a composition protocol fault.
    pub fn tick(self: *Authority, transfer_budget: usize) !TickReport {
        if (!self.healthy) {
            self.enterFault();
            return error.HeadlessAuthorityUnhealthy;
        }
        if (self.router.diagnostics().lifecycle == .stopped) {
            return error.HeadlessAuthorityStopped;
        }
        self.submit_fault = null;
        const pump = self.router.pump(.{
            .context = self,
            .submit_fn = submitFromRouter,
        }, transfer_budget);
        if (self.submit_fault) |err| {
            self.enterFault();
            return err;
        }

        self.world.tick() catch |err| {
            self.enterFault();
            return err;
        };

        var report = TickReport{
            .transferred_commands = pump.accepted,
            .terminal_submission_rejections = pump.terminal_rejected,
            .routed_results = 0,
            .internal_outcomes = 0,
        };
        while (self.world.pollOutcome()) |outcome| {
            switch (self.router.routeOutcome(outcome)) {
                .routed => report.routed_results +|= 1,
                .handback => |handback| switch (handback.reason) {
                    .not_relocation => {
                        if (self.internal_reservations == 0) {
                            // Retain the already-polled authority output in the
                            // emergency slot before exposing the accounting
                            // fault. Polling the world is never destructive.
                            self.pushInternalOutcome(handback.outcome) catch |err| {
                                self.enterFault();
                                return err;
                            };
                            self.enterFault();
                            return error.InternalOutcomeReservationMissing;
                        }
                        self.internal_reservations -= 1;
                        self.pushInternalOutcome(handback.outcome) catch |err| {
                            self.enterFault();
                            return err;
                        };
                        report.internal_outcomes +|= 1;
                    },
                    else => {
                        // Retain evidence before escalating; no world output is
                        // silently consumed even on a protocol violation. The
                        // emergency slot is unreserved; reservations belong
                        // only to accepted internal commands and must remain
                        // attached to those still-unread outcomes.
                        self.pushInternalOutcome(handback.outcome) catch |err| {
                            self.enterFault();
                            return err;
                        };
                        self.enterFault();
                        return error.UnownedExternalRelocationOutcome;
                    },
                },
            }
        }
        return report;
    }

    pub fn beginShutdown(self: *Authority) external_producers.ShutdownStatus {
        return self.router.beginShutdown();
    }

    pub fn isDrained(self: *Authority) bool {
        return self.router.isDrained() and self.internal_len == 0 and
            self.internal_reservations == 0 and
            self.world.operationalQuiescenceReason() == null;
    }

    pub fn finishShutdown(
        self: *Authority,
    ) external_producers.FinishShutdownStatus {
        switch (self.router.diagnostics().lifecycle) {
            .accepting => return .not_draining,
            .stopped => return .already_stopped,
            .draining => {},
        }
        if (!self.isDrained()) return .not_drained;
        return self.router.finishShutdown();
    }

    pub fn canCommitSave(self: *Authority) bool {
        return self.healthy and
            self.router.diagnostics().lifecycle == .stopped and
            self.isDrained();
    }

    pub fn saveEnvelope(
        self: *Authority,
        allocator: std.mem.Allocator,
        metadata: sandbox_save.Metadata,
    ) ![]u8 {
        if (!self.canCommitSave()) return error.HeadlessSaveBoundaryNotReady;
        const payload = try self.world.save(allocator);
        defer allocator.free(payload);
        return sandbox_save.encode(allocator, metadata, payload);
    }

    pub fn diagnostics(self: *Authority) Diagnostics {
        return .{
            .healthy = self.healthy,
            .world = self.world.diagnostics(),
            .producers = self.router.diagnostics(),
            .internal_outcomes = .{
                .occupancy = countDiagnostic(self.internal_len),
                .capacity = countDiagnostic(internal_outcome_capacity),
                .high_water = self.internal_high_water,
                .reservations = countDiagnostic(self.internal_reservations),
            },
        };
    }

    fn submitFromRouter(
        raw: *anyopaque,
        command: crate_feature.Command,
    ) external_producers.SubmitDisposition {
        const self: *Authority = @ptrCast(@alignCast(raw));
        self.world.submit(command) catch |err| switch (err) {
            error.CrateCommandQueueFull => return .retry_later,
            error.RuntimeFaulted,
            error.RuntimeDeinitialized,
            error.TickCounterExhausted,
            => {
                self.submit_fault = err;
                return .retry_later;
            },
            else => return .terminal_rejected,
        };
        return .accepted;
    }

    fn pushInternalOutcome(
        self: *Authority,
        outcome: crate_feature.Outcome,
    ) !void {
        if (self.internal_len == internal_outcome_capacity) {
            return error.InternalOutcomeQueueFull;
        }
        self.internal_outcomes[
            (self.internal_head + self.internal_len) % internal_outcome_capacity
        ] = outcome;
        self.internal_len += 1;
        self.internal_high_water = @max(
            self.internal_high_water,
            countDiagnostic(self.internal_len),
        );
    }

    fn enterFault(self: *Authority) void {
        self.healthy = false;
        _ = self.router.beginShutdown();
    }
};

fn countDiagnostic(value: usize) u32 {
    return std.math.cast(u32, value) orelse std.math.maxInt(u32);
}

fn testWorldConfig(namespace: u64) sandbox_contracts.Config {
    return .{
        .namespace = namespace,
        .max_crates = 8,
        .create_ground = false,
        .character = .{ .max_characters = 1 },
        .vehicle = .{ .max_vehicles = 1 },
        .npc = .{},
    };
}

test "two producers receive exact relocation completions and drain cleanly" {
    var authority = try Authority.initFresh(std.testing.allocator, testWorldConfig(8_101));
    defer authority.deinit();

    try authority.submitInternal(.{ .spawn = .{
        .request_id = 1,
        .pose = .{ .position = .{ 0, 2, 0 } },
    } });
    _ = try authority.tick(32);
    const spawned = switch (authority.pollInternalOutcome() orelse
        return error.MissingInternalOutcome) {
        .spawned => |value| value,
        else => return error.UnexpectedInternalOutcome,
    };

    const first = switch (authority.registerProducer()) {
        .registered => |handle| handle,
        else => return error.ProducerRegistrationFailed,
    };
    const second = switch (authority.registerProducer()) {
        .registered => |handle| handle,
        else => return error.ProducerRegistrationFailed,
    };
    for (0..8) |index| {
        try std.testing.expectEqual(
            external_producers.SubmitStatus.accepted,
            authority.submitExternal(first, .{
                .transaction_id = 100 + index,
                .source = .scripted_validation,
                .scope = .session,
                .id = spawned.id,
                .target_pose = .{ .position = .{ @floatFromInt(index), 2, 0 } },
                .expected_revision = index * 2,
            }),
        );
        try std.testing.expectEqual(
            external_producers.SubmitStatus.accepted,
            authority.submitExternal(second, .{
                .transaction_id = 200 + index,
                .source = .scripted_validation,
                .scope = .session,
                .id = spawned.id,
                .target_pose = .{ .position = .{ 0, 2, @floatFromInt(index) } },
                .expected_revision = index * 2 + 1,
            }),
        );
    }
    try std.testing.expectEqual(
        external_producers.SubmitStatus.ingress_full,
        authority.submitExternal(first, .{
            .transaction_id = 999,
            .source = .scripted_validation,
            .scope = .session,
            .id = spawned.id,
            .target_pose = .{},
            .expected_revision = 16,
        }),
    );

    _ = try authority.tick(32);
    for ([_]ProducerHandle{ first, second }) |handle| {
        for (0..8) |_| switch (authority.pollProducerResult(handle)) {
            .result => |result| try std.testing.expect(result == .outcome),
            else => return error.MissingProducerResult,
        };
        try std.testing.expect(authority.pollProducerResult(handle) == .empty);
    }
    try std.testing.expectEqual(external_producers.ShutdownStatus.draining, authority.beginShutdown());
    try std.testing.expect(authority.isDrained());
    try std.testing.expectEqual(
        external_producers.UnregisterStatus.unregistered,
        authority.unregisterProducer(first),
    );
    try std.testing.expectEqual(
        external_producers.UnregisterStatus.unregistered,
        authority.unregisterProducer(second),
    );
    try std.testing.expectEqual(
        external_producers.FinishShutdownStatus.stopped,
        authority.finishShutdown(),
    );
    try std.testing.expect(authority.canCommitSave());
}

test "unowned relocation is retained and permanently closes the save boundary" {
    var authority = try Authority.initFresh(std.testing.allocator, testWorldConfig(8_102));
    defer authority.deinit();
    const producer = switch (authority.registerProducer()) {
        .registered => |handle| handle,
        else => return error.ProducerRegistrationFailed,
    };
    // Deliberately bypass the composition-owned port to inject the protocol
    // violation that the public internal surface rejects.
    try authority.world.submit(.{ .relocate = .{
        .transaction_id = 77,
        .source = .scripted_validation,
        .scope = .session,
        .id = .{ .namespace = 8_102, .local = 1 },
        .target_pose = .{},
        .expected_revision = 0,
    } });
    // Isolate the accounting rule directly: model one already-accepted
    // internal command whose outcome has not reached this composition yet.
    // Feature systems do not promise command-kind processing order, so
    // submitting a second crate command here would make the test depend on an
    // unrelated scheduler detail.
    authority.internal_reservations = 1;
    try std.testing.expectEqual(
        @as(u32, 1),
        authority.diagnostics().internal_outcomes.reservations,
    );
    try std.testing.expectError(
        error.UnownedExternalRelocationOutcome,
        authority.tick(1),
    );
    try std.testing.expectEqual(
        external_producers.Lifecycle.draining,
        authority.diagnostics().producers.lifecycle,
    );
    try std.testing.expect(authority.registerProducer() == .shutting_down);
    try std.testing.expectEqual(
        external_producers.SubmitStatus.shutting_down,
        authority.submitExternal(producer, .{
            .transaction_id = 78,
            .source = .scripted_validation,
            .scope = .session,
            .id = .{ .namespace = 8_102, .local = 1 },
            .target_pose = .{},
            .expected_revision = 0,
        }),
    );
    try std.testing.expect(!authority.canCommitSave());
    try std.testing.expect(authority.pollInternalOutcome() != null);
    try std.testing.expectEqual(
        @as(u32, 1),
        authority.diagnostics().internal_outcomes.reservations,
    );
    try std.testing.expectError(
        error.HeadlessSaveBoundaryNotReady,
        authority.saveEnvelope(std.testing.allocator, .{
            .payload_schema = sandbox_contracts.snapshot_schema,
            .simulation_build_digest = [_]u8{1} ** 32,
            .world_config_digest = [_]u8{2} ** 32,
            .content_digest = [_]u8{3} ** 32,
        }),
    );
    try std.testing.expectError(error.HeadlessAuthorityUnhealthy, authority.tick(1));
}

test "missing internal reservation retains evidence and closes ingress" {
    var authority = try Authority.initFresh(std.testing.allocator, testWorldConfig(8_105));
    defer authority.deinit();
    // Deliberately bypass submitInternal so the world publishes a valid
    // non-relocation outcome without the composition reservation it requires.
    try authority.world.submit(.{ .spawn = .{
        .request_id = 1,
        .pose = .{ .position = .{ 0, 2, 0 } },
    } });
    try std.testing.expectError(
        error.InternalOutcomeReservationMissing,
        authority.tick(0),
    );
    const evidence = authority.pollInternalOutcome() orelse
        return error.MissingProtocolFaultEvidence;
    try std.testing.expect(evidence == .spawned);
    try std.testing.expect(!authority.healthy);
    try std.testing.expectEqual(
        external_producers.Lifecycle.draining,
        authority.diagnostics().producers.lifecycle,
    );
    try std.testing.expect(authority.registerProducer() == .shutting_down);
}

test "internal relocation cannot alias an external producer transaction" {
    var authority = try Authority.initFresh(std.testing.allocator, testWorldConfig(8_104));
    defer authority.deinit();
    try authority.submitInternal(.{ .spawn = .{
        .request_id = 1,
        .pose = .{ .position = .{ 0, 2, 0 } },
    } });
    _ = try authority.tick(1);
    const id = authority.pollInternalOutcome().?.spawned.id;
    const producer = switch (authority.registerProducer()) {
        .registered => |handle| handle,
        else => return error.ProducerRegistrationFailed,
    };
    const relocation = crate_feature.RelocateCrate{
        .transaction_id = 77,
        .source = .scripted_validation,
        .scope = .session,
        .id = id,
        .target_pose = .{ .position = .{ 1, 2, 0 } },
        .expected_revision = 0,
    };
    try std.testing.expectEqual(
        external_producers.SubmitStatus.accepted,
        authority.submitExternal(producer, relocation),
    );
    try std.testing.expectError(
        error.InternalRelocationRequiresProducerOwnership,
        authority.submitInternal(.{ .relocate = relocation }),
    );
    _ = try authority.tick(1);
    try std.testing.expect(authority.pollProducerResult(producer) == .result);
    try std.testing.expect(authority.pollProducerResult(producer) == .empty);
    try std.testing.expect(authority.healthy);
}

test "shutdown save boundary rejects unread non-crate process outputs" {
    var authority = try Authority.initFresh(std.testing.allocator, testWorldConfig(8_103));
    defer authority.deinit();
    try authority.world.submitCharacter(.{ .spawn = .{
        .request_id = 1,
        .position = .{ 0, 0, 0 },
    } });
    _ = try authority.tick(0);
    try std.testing.expectEqual(
        simulation.OperationalQuiescenceReason.outputs_pending,
        authority.world.operationalQuiescenceReason().?,
    );
    try std.testing.expectEqual(
        external_producers.ShutdownStatus.draining,
        authority.beginShutdown(),
    );
    try std.testing.expectEqual(
        external_producers.FinishShutdownStatus.not_drained,
        authority.finishShutdown(),
    );
    try std.testing.expect(!authority.canCommitSave());
    _ = authority.world.pollCharacterOutcome() orelse
        return error.CharacterOutcomeMissing;
    while (authority.world.pollCharacterEvent() != null) {}
    try std.testing.expect(authority.world.operationalQuiescenceReason() == null);
    try std.testing.expectEqual(
        external_producers.FinishShutdownStatus.stopped,
        authority.finishShutdown(),
    );
    try std.testing.expect(authority.canCommitSave());
}

test "restored tick exhaustion faults authority and closes producer ingress" {
    const config = testWorldConfig(8_107);
    const exhausted_payload = payload: {
        var source = try Authority.initFresh(std.testing.allocator, config);
        defer source.deinit();
        const canonical = try source.world.save(std.testing.allocator);
        defer std.testing.allocator.free(canonical);
        var parsed = try simulation_snapshot.parse(
            std.testing.allocator,
            canonical,
            config.max_crates,
            config.character.max_characters,
            config.vehicle.max_vehicles,
            npc_contract.max_npcs,
        );
        defer parsed.deinit();
        parsed.value.completed_ticks = std.math.maxInt(u64);
        break :payload try std.json.Stringify.valueAlloc(
            std.testing.allocator,
            parsed.value,
            .{},
        );
    };
    defer std.testing.allocator.free(exhausted_payload);

    var authority = try Authority.initRestored(
        std.testing.allocator,
        exhausted_payload,
        config,
    );
    defer authority.deinit();
    const producer = switch (authority.registerProducer()) {
        .registered => |handle| handle,
        else => return error.ProducerRegistrationFailed,
    };
    try std.testing.expectError(
        error.TickCounterExhausted,
        authority.submitInternal(.{ .spawn = .{
            .request_id = 1,
            .pose = .{ .position = .{ 0, 2, 0 } },
        } }),
    );
    const diagnostics_value = authority.diagnostics();
    try std.testing.expect(!diagnostics_value.healthy);
    try std.testing.expectEqual(
        external_producers.Lifecycle.draining,
        diagnostics_value.producers.lifecycle,
    );
    try std.testing.expect(authority.registerProducer() == .shutting_down);
    try std.testing.expectEqual(
        external_producers.SubmitStatus.shutting_down,
        authority.submitExternal(producer, .{
            .transaction_id = 1,
            .source = .scripted_validation,
            .scope = .session,
            .id = .{ .namespace = config.namespace, .local = 1 },
            .target_pose = .{},
            .expected_revision = 0,
        }),
    );
    try std.testing.expect(!authority.canCommitSave());
}

test "stopped authority rejects mutation and preserves the final tick" {
    var authority = try Authority.initFresh(std.testing.allocator, testWorldConfig(8_106));
    defer authority.deinit();
    const final_tick = authority.world.tickIndex();
    try std.testing.expectEqual(
        external_producers.ShutdownStatus.draining,
        authority.beginShutdown(),
    );
    try std.testing.expectEqual(
        external_producers.FinishShutdownStatus.stopped,
        authority.finishShutdown(),
    );
    try std.testing.expectError(
        error.HeadlessAuthorityNotAccepting,
        authority.submitInternal(.{ .spawn = .{
            .request_id = 1,
            .pose = .{ .position = .{ 0, 2, 0 } },
        } }),
    );
    try std.testing.expectError(error.HeadlessAuthorityStopped, authority.tick(0));
    try std.testing.expectEqual(final_tick, authority.world.tickIndex());
    try std.testing.expect(authority.registerProducer() == .shutting_down);
    try std.testing.expect(authority.isDrained());
    try std.testing.expect(authority.canCommitSave());
}
