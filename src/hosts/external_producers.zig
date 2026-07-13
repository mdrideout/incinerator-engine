//! Composition-owned, bounded ingress for synthetic external producers.
//!
//! M3 deliberately starts with one narrow completion contract: a producer may
//! submit a crate relocation and receives exactly one terminal result. The
//! router owns correlation, capacity reservation, and producer isolation; it
//! does not own the simulation or consume outcomes belonging to other hosts.
//! Like the simulation it fronts, this value is single-owner. Transport or
//! worker threads must cross into it through a composition-owned synchronization
//! boundary rather than concurrently mutating the router.

const std = @import("std");

pub const Limits = struct {
    producer_capacity: usize = 2,
    ingress_capacity: usize = 16,
    transaction_capacity: usize = 16,
    pending_quota_per_producer: usize = 4,
    result_capacity_per_producer: usize = 8,
};

pub const ProducerHandle = struct {
    index: u16,
    generation: u32,
};

pub const Lifecycle = enum { accepting, draining, stopped };

pub const Registration = union(enum) {
    registered: ProducerHandle,
    shutting_down,
    producer_capacity_full,
    producer_slots_exhausted,
};

pub const UnregisterStatus = enum {
    unregistered,
    stale_handle,
    pending_work,
    unread_results,
};

pub const SubmitStatus = enum {
    accepted,
    shutting_down,
    stale_handle,
    invalid_transaction_id,
    duplicate_transaction_id,
    producer_quota_full,
    result_capacity_full,
    ingress_full,
    transaction_table_full,
};

pub const SubmitDisposition = enum {
    /// The supplied port transferred the command into world authority.
    accepted,
    /// No transfer occurred. Retain the FIFO head and try it again later.
    retry_later,
    /// No transfer occurred and retrying cannot succeed. Publish a reserved
    /// terminal result so the producer is never left waiting indefinitely.
    terminal_rejected,
};

pub const PumpStop = enum { empty, budget, retry_later };

pub const PumpReport = struct {
    accepted: u32 = 0,
    terminal_rejected: u32 = 0,
    stop: PumpStop,
};

pub const ShutdownStatus = enum { draining, already_draining, already_stopped };
pub const FinishShutdownStatus = enum {
    stopped,
    not_draining,
    not_drained,
    already_stopped,
};

pub const QueueStats = struct {
    occupancy: u32,
    capacity: u32,
    high_water: u32,
    rejected: u64,
};

pub const RejectionCounters = struct {
    registration: u64 = 0,
    producer_capacity_full: u64 = 0,
    producer_slots_exhausted: u64 = 0,
    shutting_down: u64 = 0,
    stale_handle: u64 = 0,
    invalid_transaction_id: u64 = 0,
    duplicate_transaction_id: u64 = 0,
    producer_quota_full: u64 = 0,
    result_capacity_full: u64 = 0,
    ingress_full: u64 = 0,
    transaction_table_full: u64 = 0,
    unregister_pending: u64 = 0,
    unregister_unread: u64 = 0,
    terminal_submission_rejected: u64 = 0,
};

pub const ProducerDiagnostics = struct {
    live: bool,
    generation: u32,
    pending: u32,
    pending_high_water: u32,
    unread_results: u32,
    results: QueueStats,
    /// Pending commands and unread results share these delivery slots. A slot
    /// is reserved at admission, before the command can reach the world.
    delivery: QueueStats,
    admission_rejected: u64,
};

/// `CrateContract` is the crate feature module (or a test double) and must
/// expose RelocateCrate, Command, Outcome, and CommandKind. Keeping this host
/// seam parameterized lets it be unit-tested without constructing Flecs/Jolt.
pub fn Router(comptime CrateContract: type, comptime limits: Limits) type {
    validateLimits(limits);

    const Relocation = CrateContract.RelocateCrate;
    const Command = CrateContract.Command;
    const Outcome = CrateContract.Outcome;
    const Identity = @FieldType(Relocation, "id");

    return struct {
        const Self = @This();

        pub const SubmissionRejected = struct { transaction_id: u64 };

        pub const Result = union(enum) {
            outcome: Outcome,
            submission_rejected: SubmissionRejected,
        };

        pub const PollResult = union(enum) {
            result: Result,
            empty,
            stale_handle,
        };

        pub const HandbackReason = enum {
            not_relocation,
            unknown_transaction,
            not_submitted,
            duplicate_final,
            identity_mismatch,
        };

        pub const Handback = struct {
            reason: HandbackReason,
            outcome: Outcome,
        };

        pub const RouteResult = union(enum) {
            routed: struct {
                producer: ProducerHandle,
                transaction_id: u64,
            },
            handback: Handback,
        };

        pub const SubmitPort = struct {
            context: *anyopaque,
            submit_fn: *const fn (*anyopaque, Command) SubmitDisposition,

            pub fn submit(self: SubmitPort, command: Command) SubmitDisposition {
                return self.submit_fn(self.context, command);
            }
        };

        pub const Diagnostics = struct {
            lifecycle: Lifecycle,
            producers: QueueStats,
            ingress: QueueStats,
            transactions: QueueStats,
            delivery: QueueStats,
            slots: [limits.producer_capacity]ProducerDiagnostics,
            rejections: RejectionCounters,
            outcomes_handed_back: u64,
        };

        const TransactionStage = enum { ingress, submitted, result_queued };

        const Transaction = struct {
            live: bool = false,
            producer: ProducerHandle = undefined,
            relocation: Relocation = undefined,
            stage: TransactionStage = undefined,
        };

        const ResultEntry = struct {
            transaction_index: usize,
            value: Result,
        };

        const ProducerSlot = struct {
            generation: u32 = 1,
            live: bool = false,
            pending: usize = 0,
            pending_high_water: u32 = 0,
            reserved_results: usize = 0,
            results: [limits.result_capacity_per_producer]ResultEntry = undefined,
            results_head: usize = 0,
            results_len: usize = 0,
            results_high_water: u32 = 0,
            delivery_high_water: u32 = 0,
            delivery_rejected: u64 = 0,
            admission_rejected: u64 = 0,
        };

        const OutcomeMetadata = struct {
            transaction_id: u64,
            id: ?Identity,
        };

        lifecycle: Lifecycle = .accepting,
        producers: [limits.producer_capacity]ProducerSlot =
            [_]ProducerSlot{.{}} ** limits.producer_capacity,
        producer_count: usize = 0,
        producer_high_water: u32 = 0,
        producer_rejected: u64 = 0,

        ingress: [limits.ingress_capacity]usize = undefined,
        ingress_head: usize = 0,
        ingress_len: usize = 0,
        ingress_high_water: u32 = 0,
        ingress_rejected: u64 = 0,

        transactions: [limits.transaction_capacity]Transaction =
            [_]Transaction{.{}} ** limits.transaction_capacity,
        transaction_count: usize = 0,
        transaction_high_water: u32 = 0,
        transaction_rejected: u64 = 0,

        delivery_high_water: u32 = 0,
        delivery_rejected: u64 = 0,
        rejections: RejectionCounters = .{},
        outcomes_handed_back: u64 = 0,

        pub fn init() Self {
            return .{};
        }

        pub fn register(self: *Self) Registration {
            if (self.lifecycle != .accepting) {
                saturatingIncrement(&self.rejections.shutting_down);
                saturatingIncrement(&self.rejections.registration);
                saturatingIncrement(&self.producer_rejected);
                return .shutting_down;
            }

            for (&self.producers, 0..) |*slot, index| {
                if (slot.live) continue;
                if (slot.generation == 0) continue;

                const generation = slot.generation;
                slot.* = .{ .generation = generation, .live = true };
                self.producer_count += 1;
                self.producer_high_water = @max(
                    self.producer_high_water,
                    diagnosticCount(self.producer_count),
                );
                self.assertInvariants();
                return .{ .registered = .{
                    .index = @intCast(index),
                    .generation = generation,
                } };
            }

            saturatingIncrement(&self.rejections.registration);
            saturatingIncrement(&self.producer_rejected);
            if (self.producer_count == limits.producer_capacity) {
                saturatingIncrement(&self.rejections.producer_capacity_full);
                return .producer_capacity_full;
            }
            saturatingIncrement(&self.rejections.producer_slots_exhausted);
            return .producer_slots_exhausted;
        }

        pub fn unregister(
            self: *Self,
            handle: ProducerHandle,
        ) UnregisterStatus {
            const slot = self.slotFor(handle) orelse {
                saturatingIncrement(&self.rejections.stale_handle);
                return .stale_handle;
            };
            if (slot.pending != 0) {
                saturatingIncrement(&self.rejections.unregister_pending);
                return .pending_work;
            }
            if (slot.results_len != 0) {
                saturatingIncrement(&self.rejections.unregister_unread);
                return .unread_results;
            }
            std.debug.assert(slot.reserved_results == 0);

            const next_generation: u32 = if (slot.generation == std.math.maxInt(u32))
                0
            else
                slot.generation + 1;
            slot.* = .{ .generation = next_generation };
            self.producer_count -= 1;
            self.assertInvariants();
            return .unregistered;
        }

        pub fn submit(
            self: *Self,
            handle: ProducerHandle,
            relocation: Relocation,
        ) SubmitStatus {
            if (self.lifecycle != .accepting) {
                saturatingIncrement(&self.rejections.shutting_down);
                return .shutting_down;
            }
            const slot = self.slotFor(handle) orelse {
                saturatingIncrement(&self.rejections.stale_handle);
                return .stale_handle;
            };
            if (relocation.transaction_id == 0) {
                self.rejectProducer(slot, &self.rejections.invalid_transaction_id);
                return .invalid_transaction_id;
            }
            if (self.findTransaction(relocation.transaction_id) != null) {
                self.rejectProducer(slot, &self.rejections.duplicate_transaction_id);
                return .duplicate_transaction_id;
            }
            if (self.ingress_len == limits.ingress_capacity) {
                self.rejectProducer(slot, &self.rejections.ingress_full);
                saturatingIncrement(&self.ingress_rejected);
                return .ingress_full;
            }
            const transaction_index = self.findFreeTransaction() orelse {
                self.rejectProducer(slot, &self.rejections.transaction_table_full);
                saturatingIncrement(&self.transaction_rejected);
                return .transaction_table_full;
            };
            if (slot.pending == limits.pending_quota_per_producer) {
                self.rejectProducer(slot, &self.rejections.producer_quota_full);
                return .producer_quota_full;
            }
            if (slot.pending + slot.results_len == limits.result_capacity_per_producer) {
                self.rejectProducer(slot, &self.rejections.result_capacity_full);
                saturatingIncrement(&slot.delivery_rejected);
                saturatingIncrement(&self.delivery_rejected);
                return .result_capacity_full;
            }

            self.transactions[transaction_index] = .{
                .live = true,
                .producer = handle,
                .relocation = relocation,
                .stage = .ingress,
            };
            self.transaction_count += 1;
            self.transaction_high_water = @max(
                self.transaction_high_water,
                diagnosticCount(self.transaction_count),
            );

            self.ingress[(self.ingress_head + self.ingress_len) % limits.ingress_capacity] =
                transaction_index;
            self.ingress_len += 1;
            self.ingress_high_water = @max(
                self.ingress_high_water,
                diagnosticCount(self.ingress_len),
            );

            slot.pending += 1;
            slot.reserved_results += 1;
            slot.pending_high_water = @max(
                slot.pending_high_water,
                diagnosticCount(slot.pending),
            );
            self.observeDeliveryHighWater(slot);
            self.assertInvariants();
            return .accepted;
        }

        /// Transfer FIFO ingress into the supplied world capability. The port
        /// must return `accepted` only after world submission has committed.
        pub fn pump(
            self: *Self,
            port: SubmitPort,
            max_commands: usize,
        ) PumpReport {
            if (self.ingress_len == 0) return .{ .stop = .empty };
            var report = PumpReport{ .stop = .budget };
            var processed: usize = 0;
            while (processed < max_commands) : (processed += 1) {
                if (self.ingress_len == 0) {
                    report.stop = .empty;
                    self.assertInvariants();
                    return report;
                }

                const transaction_index = self.ingress[self.ingress_head];
                const transaction = &self.transactions[transaction_index];
                std.debug.assert(transaction.live and transaction.stage == .ingress);
                const disposition = port.submit(.{ .relocate = transaction.relocation });
                switch (disposition) {
                    .accepted => {
                        transaction.stage = .submitted;
                        self.popIngress();
                        report.accepted +|= 1;
                    },
                    .retry_later => {
                        report.stop = .retry_later;
                        self.assertInvariants();
                        return report;
                    },
                    .terminal_rejected => {
                        self.popIngress();
                        const transaction_id = transaction.relocation.transaction_id;
                        self.publishResult(transaction_index, .{
                            .submission_rejected = .{ .transaction_id = transaction_id },
                        });
                        saturatingIncrement(
                            &self.rejections.terminal_submission_rejected,
                        );
                        report.terminal_rejected +|= 1;
                    },
                }
            }
            if (self.ingress_len == 0) report.stop = .empty;
            self.assertInvariants();
            return report;
        }

        /// Route only a matching submitted relocation completion. Every other
        /// outcome is returned by value for the composition's next consumer.
        pub fn routeOutcome(self: *Self, outcome: Outcome) RouteResult {
            const metadata = outcomeMetadata(outcome) orelse
                return self.handBack(.not_relocation, outcome);
            const transaction_index = self.findTransaction(metadata.transaction_id) orelse
                return self.handBack(.unknown_transaction, outcome);
            const transaction = &self.transactions[transaction_index];
            switch (transaction.stage) {
                .ingress => return self.handBack(.not_submitted, outcome),
                .result_queued => return self.handBack(.duplicate_final, outcome),
                .submitted => {},
            }
            if (metadata.id) |id| {
                if (!std.meta.eql(id, transaction.relocation.id)) {
                    return self.handBack(.identity_mismatch, outcome);
                }
            }

            const producer = transaction.producer;
            self.publishResult(transaction_index, .{ .outcome = outcome });
            self.assertInvariants();
            return .{ .routed = .{
                .producer = producer,
                .transaction_id = metadata.transaction_id,
            } };
        }

        pub fn pollResult(self: *Self, handle: ProducerHandle) PollResult {
            const slot = self.slotFor(handle) orelse {
                saturatingIncrement(&self.rejections.stale_handle);
                return .stale_handle;
            };
            if (slot.results_len == 0) return .empty;

            const entry = slot.results[slot.results_head];
            slot.results_head = (slot.results_head + 1) % limits.result_capacity_per_producer;
            slot.results_len -= 1;
            if (slot.results_len == 0) slot.results_head = 0;

            const transaction = &self.transactions[entry.transaction_index];
            std.debug.assert(transaction.live and transaction.stage == .result_queued);
            transaction.* = .{};
            self.transaction_count -= 1;
            self.assertInvariants();
            return .{ .result = entry.value };
        }

        pub fn beginShutdown(self: *Self) ShutdownStatus {
            return switch (self.lifecycle) {
                .accepting => blk: {
                    self.lifecycle = .draining;
                    break :blk .draining;
                },
                .draining => .already_draining,
                .stopped => .already_stopped,
            };
        }

        pub fn isDrained(self: *const Self) bool {
            return self.ingress_len == 0 and self.transaction_count == 0;
        }

        pub fn finishShutdown(self: *Self) FinishShutdownStatus {
            if (self.lifecycle == .stopped) return .already_stopped;
            if (self.lifecycle == .accepting) return .not_draining;
            if (!self.isDrained()) return .not_drained;
            self.lifecycle = .stopped;
            return .stopped;
        }

        pub fn diagnostics(self: *const Self) Diagnostics {
            var slots: [limits.producer_capacity]ProducerDiagnostics = undefined;
            var delivery_occupancy: usize = 0;
            for (self.producers, 0..) |slot, index| {
                const used = slot.pending + slot.results_len;
                delivery_occupancy += used;
                slots[index] = .{
                    .live = slot.live,
                    .generation = slot.generation,
                    .pending = diagnosticCount(slot.pending),
                    .pending_high_water = slot.pending_high_water,
                    .unread_results = diagnosticCount(slot.results_len),
                    .results = .{
                        .occupancy = diagnosticCount(slot.results_len),
                        .capacity = diagnosticCount(limits.result_capacity_per_producer),
                        .high_water = slot.results_high_water,
                        // Delivery reservations guarantee publication, so a
                        // routed result can never be rejected here.
                        .rejected = 0,
                    },
                    .delivery = .{
                        .occupancy = diagnosticCount(used),
                        .capacity = diagnosticCount(limits.result_capacity_per_producer),
                        .high_water = slot.delivery_high_water,
                        .rejected = slot.delivery_rejected,
                    },
                    .admission_rejected = slot.admission_rejected,
                };
            }
            return .{
                .lifecycle = self.lifecycle,
                .producers = .{
                    .occupancy = diagnosticCount(self.producer_count),
                    .capacity = diagnosticCount(limits.producer_capacity),
                    .high_water = self.producer_high_water,
                    .rejected = self.producer_rejected,
                },
                .ingress = .{
                    .occupancy = diagnosticCount(self.ingress_len),
                    .capacity = diagnosticCount(limits.ingress_capacity),
                    .high_water = self.ingress_high_water,
                    .rejected = self.ingress_rejected,
                },
                .transactions = .{
                    .occupancy = diagnosticCount(self.transaction_count),
                    .capacity = diagnosticCount(limits.transaction_capacity),
                    .high_water = self.transaction_high_water,
                    .rejected = self.transaction_rejected,
                },
                .delivery = .{
                    .occupancy = diagnosticCount(delivery_occupancy),
                    .capacity = diagnosticCount(
                        limits.producer_capacity * limits.result_capacity_per_producer,
                    ),
                    .high_water = self.delivery_high_water,
                    .rejected = self.delivery_rejected,
                },
                .slots = slots,
                .rejections = self.rejections,
                .outcomes_handed_back = self.outcomes_handed_back,
            };
        }

        fn slotFor(self: *Self, handle: ProducerHandle) ?*ProducerSlot {
            const index: usize = handle.index;
            if (index >= limits.producer_capacity) return null;
            const slot = &self.producers[index];
            if (!slot.live or slot.generation != handle.generation) return null;
            return slot;
        }

        fn findTransaction(self: *const Self, transaction_id: u64) ?usize {
            for (self.transactions, 0..) |transaction, index| {
                if (transaction.live and
                    transaction.relocation.transaction_id == transaction_id)
                {
                    return index;
                }
            }
            return null;
        }

        fn findFreeTransaction(self: *const Self) ?usize {
            for (self.transactions, 0..) |transaction, index| {
                if (!transaction.live) return index;
            }
            return null;
        }

        fn popIngress(self: *Self) void {
            std.debug.assert(self.ingress_len > 0);
            self.ingress_head = (self.ingress_head + 1) % limits.ingress_capacity;
            self.ingress_len -= 1;
            if (self.ingress_len == 0) self.ingress_head = 0;
        }

        fn publishResult(
            self: *Self,
            transaction_index: usize,
            value: Result,
        ) void {
            const transaction = &self.transactions[transaction_index];
            std.debug.assert(transaction.live and transaction.stage != .result_queued);
            const slot = self.slotFor(transaction.producer) orelse
                @panic("external producer transaction lost its live owner");
            std.debug.assert(slot.pending > 0 and slot.reserved_results > 0);
            std.debug.assert(slot.results_len < limits.result_capacity_per_producer);

            slot.pending -= 1;
            slot.reserved_results -= 1;
            slot.results[
                (slot.results_head + slot.results_len) %
                    limits.result_capacity_per_producer
            ] = .{
                .transaction_index = transaction_index,
                .value = value,
            };
            slot.results_len += 1;
            slot.results_high_water = @max(
                slot.results_high_water,
                diagnosticCount(slot.results_len),
            );
            transaction.stage = .result_queued;
        }

        fn handBack(
            self: *Self,
            reason: HandbackReason,
            outcome: Outcome,
        ) RouteResult {
            saturatingIncrement(&self.outcomes_handed_back);
            return .{ .handback = .{ .reason = reason, .outcome = outcome } };
        }

        fn observeDeliveryHighWater(self: *Self, slot: *ProducerSlot) void {
            const slot_used = slot.pending + slot.results_len;
            slot.delivery_high_water = @max(
                slot.delivery_high_water,
                diagnosticCount(slot_used),
            );
            var total: usize = 0;
            for (self.producers) |producer| total += producer.pending + producer.results_len;
            self.delivery_high_water = @max(
                self.delivery_high_water,
                diagnosticCount(total),
            );
        }

        fn rejectProducer(self: *Self, slot: *ProducerSlot, counter: *u64) void {
            _ = self;
            saturatingIncrement(counter);
            saturatingIncrement(&slot.admission_rejected);
        }

        fn assertInvariants(self: *const Self) void {
            var live_transactions: usize = 0;
            var live_producers: usize = 0;
            var expected_pending = [_]usize{0} ** limits.producer_capacity;
            var expected_unread = [_]usize{0} ** limits.producer_capacity;

            for (self.producers) |slot| {
                live_producers += @intFromBool(slot.live);
            }
            for (self.transactions) |transaction| {
                if (!transaction.live) continue;
                live_transactions += 1;
                const producer_index: usize = transaction.producer.index;
                std.debug.assert(producer_index < limits.producer_capacity);
                const slot = self.producers[producer_index];
                std.debug.assert(
                    slot.live and slot.generation == transaction.producer.generation,
                );
                switch (transaction.stage) {
                    .ingress, .submitted => expected_pending[producer_index] += 1,
                    .result_queued => expected_unread[producer_index] += 1,
                }
            }
            for (self.producers, 0..) |slot, index| {
                std.debug.assert(slot.pending == expected_pending[index]);
                std.debug.assert(slot.reserved_results == expected_pending[index]);
                std.debug.assert(slot.results_len == expected_unread[index]);
                std.debug.assert(
                    slot.pending + slot.results_len <= limits.result_capacity_per_producer,
                );
            }
            for (0..self.ingress_len) |offset| {
                const transaction_index = self.ingress[
                    (self.ingress_head + offset) % limits.ingress_capacity
                ];
                std.debug.assert(transaction_index < limits.transaction_capacity);
                const transaction = self.transactions[transaction_index];
                std.debug.assert(transaction.live and transaction.stage == .ingress);
            }
            std.debug.assert(live_transactions == self.transaction_count);
            std.debug.assert(live_producers == self.producer_count);
        }

        fn outcomeMetadata(outcome: Outcome) ?OutcomeMetadata {
            return switch (outcome) {
                .relocated => |relocated| .{
                    .transaction_id = relocated.transaction_id,
                    .id = relocated.id,
                },
                .rejected => |rejected| if (rejected.command == .relocate)
                    if (rejected.transaction_id) |transaction_id| .{
                        .transaction_id = transaction_id,
                        .id = rejected.id,
                    } else null
                else
                    null,
                else => null,
            };
        }
    };
}

fn validateLimits(comptime limits: Limits) void {
    if (limits.producer_capacity == 0 or
        limits.ingress_capacity == 0 or
        limits.transaction_capacity == 0 or
        limits.pending_quota_per_producer == 0 or
        limits.result_capacity_per_producer == 0)
    {
        @compileError("external producer capacities must be nonzero");
    }
    if (limits.producer_capacity > std.math.maxInt(u16) or
        limits.ingress_capacity > std.math.maxInt(u32) or
        limits.transaction_capacity > std.math.maxInt(u32) or
        limits.pending_quota_per_producer > std.math.maxInt(u32) or
        limits.result_capacity_per_producer > std.math.maxInt(u32) or
        limits.producer_capacity * limits.result_capacity_per_producer >
            std.math.maxInt(u32))
    {
        @compileError("external producer capacities must fit diagnostics and handles");
    }
}

fn diagnosticCount(value: usize) u32 {
    return @intCast(value);
}

fn saturatingIncrement(value: *u64) void {
    value.* +|= 1;
}

const FakeCrates = struct {
    pub const Identity = u64;
    pub const RelocateCrate = struct {
        transaction_id: u64,
        id: Identity,
        target: i32,
    };
    pub const Command = union(enum) {
        relocate: RelocateCrate,
        spawn: u64,
    };
    pub const CommandKind = enum { relocate, spawn };
    pub const CommandRejected = struct {
        command: CommandKind,
        transaction_id: ?u64 = null,
        id: ?Identity = null,
    };
    pub const Relocated = struct {
        transaction_id: u64,
        id: Identity,
        committed: i32,
    };
    pub const Outcome = union(enum) {
        relocated: Relocated,
        rejected: CommandRejected,
        spawned: u64,
    };
};

const test_limits = Limits{
    .producer_capacity = 2,
    .ingress_capacity = 2,
    .transaction_capacity = 6,
    .pending_quota_per_producer = 3,
    .result_capacity_per_producer = 3,
};
const TestRouter = Router(FakeCrates, test_limits);

const FakeWorld = struct {
    commands: [16]FakeCrates.Command = undefined,
    len: usize = 0,
    next_disposition: SubmitDisposition = .accepted,

    fn port(self: *FakeWorld) TestRouter.SubmitPort {
        return .{ .context = self, .submit_fn = submitOpaque };
    }

    fn submitOpaque(raw: *anyopaque, command: FakeCrates.Command) SubmitDisposition {
        const self: *FakeWorld = @ptrCast(@alignCast(raw));
        const disposition = self.next_disposition;
        self.next_disposition = .accepted;
        if (disposition == .accepted) {
            self.commands[self.len] = command;
            self.len += 1;
        }
        return disposition;
    }
};

fn registered(router: *TestRouter) !ProducerHandle {
    return switch (router.register()) {
        .registered => |handle| handle,
        else => error.RegistrationFailed,
    };
}

fn testRelocation(transaction_id: u64, id: u64, target: i32) FakeCrates.RelocateCrate {
    return .{ .transaction_id = transaction_id, .id = id, .target = target };
}

fn testRelocated(transaction_id: u64, id: u64, committed: i32) FakeCrates.Outcome {
    return .{ .relocated = .{
        .transaction_id = transaction_id,
        .id = id,
        .committed = committed,
    } };
}

test "two producers receive only their exact relocation results" {
    var router = TestRouter.init();
    const first = try registered(&router);
    const second = try registered(&router);
    try std.testing.expectEqual(SubmitStatus.accepted, router.submit(
        first,
        testRelocation(101, 11, 7),
    ));
    try std.testing.expectEqual(SubmitStatus.accepted, router.submit(
        second,
        testRelocation(202, 22, 8),
    ));

    var world = FakeWorld{};
    const pumped = router.pump(world.port(), 8);
    try std.testing.expectEqual(@as(u32, 2), pumped.accepted);
    try std.testing.expectEqual(PumpStop.empty, pumped.stop);
    try std.testing.expectEqual(@as(usize, 2), world.len);

    _ = router.routeOutcome(testRelocated(202, 22, 18));
    _ = router.routeOutcome(testRelocated(101, 11, 17));
    try std.testing.expect(router.pollResult(first) == .result);
    const second_result = router.pollResult(second);
    const exact = switch (second_result) {
        .result => |result| switch (result) {
            .outcome => |outcome| outcome,
            else => return error.UnexpectedSubmissionRejection,
        },
        else => return error.MissingResult,
    };
    try std.testing.expectEqualDeep(testRelocated(202, 22, 18), exact);
    try std.testing.expect(router.pollResult(first) == .empty);
    try std.testing.expect(router.pollResult(second) == .empty);
}

test "global duplicate IDs stale generations and unregister gates are explicit" {
    var router = TestRouter.init();
    const first = try registered(&router);
    const second = try registered(&router);
    try std.testing.expect(router.register() == .producer_capacity_full);
    try std.testing.expectEqual(
        SubmitStatus.accepted,
        router.submit(first, testRelocation(55, 1, 1)),
    );
    try std.testing.expectEqual(
        SubmitStatus.duplicate_transaction_id,
        router.submit(second, testRelocation(55, 2, 2)),
    );
    try std.testing.expectEqual(UnregisterStatus.pending_work, router.unregister(first));

    var world = FakeWorld{};
    _ = router.pump(world.port(), 1);
    _ = router.routeOutcome(testRelocated(55, 1, 1));
    try std.testing.expectEqual(UnregisterStatus.unread_results, router.unregister(first));
    _ = router.pollResult(first);
    try std.testing.expectEqual(UnregisterStatus.unregistered, router.unregister(first));

    const replacement = switch (router.register()) {
        .registered => |handle| handle,
        else => return error.MissingReplacement,
    };
    try std.testing.expectEqual(first.index, replacement.index);
    try std.testing.expect(replacement.generation > first.generation);
    try std.testing.expectEqual(
        SubmitStatus.stale_handle,
        router.submit(first, testRelocation(56, 1, 1)),
    );
    try std.testing.expect(router.pollResult(first) == .stale_handle);
    try std.testing.expectEqual(
        @as(u64, 1),
        router.diagnostics().rejections.producer_capacity_full,
    );
}

test "ingress saturation is atomic and recovers without leaking reservations" {
    var router = TestRouter.init();
    const producer = try registered(&router);
    try std.testing.expectEqual(
        SubmitStatus.accepted,
        router.submit(producer, testRelocation(1, 1, 1)),
    );
    try std.testing.expectEqual(
        SubmitStatus.accepted,
        router.submit(producer, testRelocation(2, 1, 2)),
    );
    try std.testing.expectEqual(
        SubmitStatus.ingress_full,
        router.submit(producer, testRelocation(3, 1, 3)),
    );
    var diagnostics_value = router.diagnostics();
    try std.testing.expectEqual(@as(u32, 2), diagnostics_value.ingress.occupancy);
    try std.testing.expectEqual(@as(u32, 2), diagnostics_value.transactions.occupancy);
    try std.testing.expectEqual(@as(u32, 2), diagnostics_value.slots[0].delivery.occupancy);

    var world = FakeWorld{};
    _ = router.pump(world.port(), 1);
    try std.testing.expectEqual(
        SubmitStatus.accepted,
        router.submit(producer, testRelocation(3, 1, 3)),
    );
    diagnostics_value = router.diagnostics();
    try std.testing.expectEqual(@as(u64, 1), diagnostics_value.ingress.rejected);
    try std.testing.expectEqual(@as(u32, 3), diagnostics_value.delivery.high_water);
}

test "per-producer pending quota recovers when a terminal outcome arrives" {
    const QuotaRouter = Router(FakeCrates, .{
        .producer_capacity = 1,
        .ingress_capacity = 2,
        .transaction_capacity = 2,
        .pending_quota_per_producer = 1,
        .result_capacity_per_producer = 2,
    });
    var router = QuotaRouter.init();
    const producer = router.register().registered;
    try std.testing.expectEqual(
        SubmitStatus.accepted,
        router.submit(producer, testRelocation(1, 4, 1)),
    );
    var world = FakeWorld{};
    const port = QuotaRouter.SubmitPort{
        .context = &world,
        .submit_fn = FakeWorld.submitOpaque,
    };
    _ = router.pump(port, 1);
    try std.testing.expectEqual(
        SubmitStatus.producer_quota_full,
        router.submit(producer, testRelocation(2, 4, 2)),
    );
    _ = router.routeOutcome(testRelocated(1, 4, 1));
    try std.testing.expectEqual(
        SubmitStatus.accepted,
        router.submit(producer, testRelocation(2, 4, 2)),
    );
    const diagnostics_value = router.diagnostics();
    try std.testing.expectEqual(@as(u64, 1), diagnostics_value.rejections.producer_quota_full);
    try std.testing.expectEqual(@as(u32, 1), diagnostics_value.slots[0].pending_high_water);
    try std.testing.expectEqual(@as(u32, 1), diagnostics_value.slots[0].results.high_water);
}

test "retry later retains the exact FIFO head" {
    var router = TestRouter.init();
    const producer = try registered(&router);
    _ = router.submit(producer, testRelocation(31, 8, 1));
    _ = router.submit(producer, testRelocation(32, 8, 2));
    var world = FakeWorld{ .next_disposition = .retry_later };
    const blocked = router.pump(world.port(), 8);
    try std.testing.expectEqual(PumpStop.retry_later, blocked.stop);
    try std.testing.expectEqual(@as(usize, 0), world.len);
    try std.testing.expectEqual(@as(u32, 2), router.diagnostics().ingress.occupancy);

    const drained = router.pump(world.port(), 8);
    try std.testing.expectEqual(@as(u32, 2), drained.accepted);
    try std.testing.expectEqual(PumpStop.empty, drained.stop);
    try std.testing.expectEqual(@as(u64, 31), world.commands[0].relocate.transaction_id);
    try std.testing.expectEqual(@as(u64, 32), world.commands[1].relocate.transaction_id);
}

test "reserved delivery capacity saturates on unread results then recovers" {
    var router = TestRouter.init();
    const producer = try registered(&router);
    var world = FakeWorld{};
    for (1..4) |transaction_id| {
        try std.testing.expectEqual(SubmitStatus.accepted, router.submit(
            producer,
            testRelocation(transaction_id, 9, @intCast(transaction_id)),
        ));
        _ = router.pump(world.port(), 1);
        _ = router.routeOutcome(testRelocated(
            transaction_id,
            9,
            @intCast(transaction_id),
        ));
    }
    try std.testing.expectEqual(
        SubmitStatus.result_capacity_full,
        router.submit(producer, testRelocation(4, 9, 4)),
    );
    _ = router.pollResult(producer);
    try std.testing.expectEqual(
        SubmitStatus.accepted,
        router.submit(producer, testRelocation(4, 9, 4)),
    );
    const diagnostics_value = router.diagnostics();
    try std.testing.expectEqual(@as(u32, 3), diagnostics_value.slots[0].delivery.high_water);
    try std.testing.expectEqual(@as(u64, 1), diagnostics_value.delivery.rejected);
}

test "transaction table exhaustion and terminal port rejection both recover" {
    const Small = Router(FakeCrates, .{
        .producer_capacity = 1,
        .ingress_capacity = 2,
        .transaction_capacity = 1,
        .pending_quota_per_producer = 2,
        .result_capacity_per_producer = 2,
    });
    var router = Small.init();
    const producer = router.register().registered;
    try std.testing.expectEqual(
        SubmitStatus.accepted,
        router.submit(producer, testRelocation(1, 7, 1)),
    );
    var world = struct {
        fn submit(_: *anyopaque, _: FakeCrates.Command) SubmitDisposition {
            return .terminal_rejected;
        }
    }{};
    const port = Small.SubmitPort{ .context = &world, .submit_fn = @TypeOf(world).submit };
    const report = router.pump(port, 1);
    try std.testing.expectEqual(@as(u32, 1), report.terminal_rejected);
    try std.testing.expectEqual(
        SubmitStatus.transaction_table_full,
        router.submit(producer, testRelocation(2, 7, 2)),
    );
    const result = router.pollResult(producer);
    try std.testing.expect(result == .result);
    try std.testing.expectEqual(
        SubmitStatus.accepted,
        router.submit(producer, testRelocation(2, 7, 2)),
    );
}

test "unrelated early duplicate and mismatched outcomes are handed back intact" {
    var router = TestRouter.init();
    const producer = try registered(&router);
    _ = router.submit(producer, testRelocation(41, 5, 9));

    const spawned = FakeCrates.Outcome{ .spawned = 88 };
    const spawn_handback = router.routeOutcome(spawned).handback;
    try std.testing.expectEqual(TestRouter.HandbackReason.not_relocation, spawn_handback.reason);
    try std.testing.expectEqualDeep(spawned, spawn_handback.outcome);

    const early = testRelocated(41, 5, 9);
    try std.testing.expectEqual(
        TestRouter.HandbackReason.not_submitted,
        router.routeOutcome(early).handback.reason,
    );
    var world = FakeWorld{};
    _ = router.pump(world.port(), 1);
    const mismatched = testRelocated(41, 6, 9);
    const mismatch_handback = router.routeOutcome(mismatched).handback;
    try std.testing.expectEqual(
        TestRouter.HandbackReason.identity_mismatch,
        mismatch_handback.reason,
    );
    try std.testing.expectEqualDeep(mismatched, mismatch_handback.outcome);

    _ = router.routeOutcome(testRelocated(41, 5, 9));
    try std.testing.expectEqual(
        TestRouter.HandbackReason.duplicate_final,
        router.routeOutcome(testRelocated(41, 5, 10)).handback.reason,
    );
    try std.testing.expectEqual(
        TestRouter.HandbackReason.unknown_transaction,
        router.routeOutcome(testRelocated(999, 5, 10)).handback.reason,
    );
    try std.testing.expectEqual(@as(u64, 5), router.diagnostics().outcomes_handed_back);
}

test "shutdown closes admission while accepted work and results drain" {
    var router = TestRouter.init();
    const producer = try registered(&router);
    _ = router.submit(producer, testRelocation(71, 3, 1));
    _ = router.submit(producer, testRelocation(72, 3, 2));
    try std.testing.expectEqual(FinishShutdownStatus.not_draining, router.finishShutdown());
    try std.testing.expectEqual(ShutdownStatus.draining, router.beginShutdown());
    try std.testing.expectEqual(
        SubmitStatus.shutting_down,
        router.submit(producer, testRelocation(73, 3, 3)),
    );
    try std.testing.expect(router.register() == .shutting_down);
    try std.testing.expectEqual(FinishShutdownStatus.not_drained, router.finishShutdown());

    var world = FakeWorld{};
    _ = router.pump(world.port(), 8);
    _ = router.routeOutcome(testRelocated(71, 3, 1));
    _ = router.routeOutcome(.{ .rejected = .{
        .command = .relocate,
        .transaction_id = 72,
        .id = 3,
    } });
    try std.testing.expectEqual(UnregisterStatus.unread_results, router.unregister(producer));
    const first_result = router.pollResult(producer).result.outcome;
    try std.testing.expectEqualDeep(testRelocated(71, 3, 1), first_result);
    const expected_rejection = FakeCrates.Outcome{ .rejected = .{
        .command = .relocate,
        .transaction_id = 72,
        .id = 3,
    } };
    const second_result = router.pollResult(producer).result.outcome;
    try std.testing.expectEqualDeep(expected_rejection, second_result);
    try std.testing.expect(router.isDrained());
    try std.testing.expectEqual(UnregisterStatus.unregistered, router.unregister(producer));
    try std.testing.expectEqual(FinishShutdownStatus.stopped, router.finishShutdown());
    try std.testing.expectEqual(Lifecycle.stopped, router.diagnostics().lifecycle);
}

test "producer generation exhaustion is permanent and typed" {
    const One = Router(FakeCrates, .{
        .producer_capacity = 1,
        .ingress_capacity = 1,
        .transaction_capacity = 1,
        .pending_quota_per_producer = 1,
        .result_capacity_per_producer = 1,
    });
    var router = One.init();
    const producer = router.register().registered;
    router.producers[0].generation = std.math.maxInt(u32);
    const exhausted_handle = ProducerHandle{
        .index = producer.index,
        .generation = std.math.maxInt(u32),
    };
    try std.testing.expectEqual(
        UnregisterStatus.unregistered,
        router.unregister(exhausted_handle),
    );
    try std.testing.expect(router.register() == .producer_slots_exhausted);
    try std.testing.expectEqual(
        @as(u64, 1),
        router.diagnostics().rejections.producer_slots_exhausted,
    );
}

test "mixed live and exhausted producer slots are not reported as full" {
    const Mixed = Router(FakeCrates, .{
        .producer_capacity = 2,
        .ingress_capacity = 2,
        .transaction_capacity = 2,
        .pending_quota_per_producer = 1,
        .result_capacity_per_producer = 1,
    });
    var router = Mixed.init();
    _ = router.register().registered;
    router.producers[1].generation = 0;
    try std.testing.expect(router.register() == .producer_slots_exhausted);
    const diagnostics_value = router.diagnostics();
    try std.testing.expectEqual(@as(u32, 1), diagnostics_value.producers.occupancy);
    try std.testing.expectEqual(
        @as(u64, 1),
        diagnostics_value.rejections.producer_slots_exhausted,
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        diagnostics_value.rejections.producer_capacity_full,
    );
}
