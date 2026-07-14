//! DistrictFeature: two bounded, asynchronously prepared static districts.
//!
//! Worker preparation stays behind `Loader`; this feature alone commits a
//! completed build to runtime entities and static physics bodies. Presentation
//! handles are inert data and never participate in activation readiness. The
//! shared loader remains single-job: one district may be loading or cancelling
//! while either neighboring slot remains active.

const std = @import("std");
const engine = @import("incinerator_engine");
const district_contract = @import("district_contract");
const feature_contract = @import("district_feature_contract");
const interaction_contract = @import("interaction_contract");
const navigation_contract = @import("navigation_contract");

const logical_state_domain = "incinerator.district.logical";
const logical_state_schema: u16 = 2;

const max_districts = feature_contract.max_districts;
const max_pending_commands = feature_contract.max_pending_commands;
const max_outcomes = feature_contract.max_outcomes;
const max_events = feature_contract.max_events;
const Assets = feature_contract.Assets;
const StateTag = feature_contract.StateTag;
const SlotDiagnostics = feature_contract.SlotDiagnostics;
const Diagnostics = feature_contract.Diagnostics;
const RequestLoad = feature_contract.RequestLoad;
const CancelLoad = feature_contract.CancelLoad;
const Unload = feature_contract.Unload;
const Command = feature_contract.Command;
const CommandKind = feature_contract.CommandKind;
const RejectionReason = feature_contract.RejectionReason;
const CommandRejected = feature_contract.CommandRejected;
const Outcome = feature_contract.Outcome;
const Event = feature_contract.Event;
const DistrictDraw = feature_contract.DistrictDraw;
const DistrictV1 = feature_contract.DistrictV1;
const validateRecords = feature_contract.validateRecords;

pub fn Feature(
    comptime StaticBodies: type,
    comptime Loader: type,
    comptime CanonicalContent: type,
) type {
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

        const Slot = union(StateTag) {
            absent,
            loading: InFlight,
            cancelling: Cancelling,
            active: Active,
        };

        const QueuedCommand = struct {
            command: Command,
            eligible_tick: u64,
            outcome_reservation: u8,
        };

        const CanonicalSlot = struct {
            index: u8,
            occupied: bool,
            coord: district_contract.ChunkCoord = .{ .x = 0, .z = 0 },
            id: ?engine.PersistentId = null,
        };

        /// Exact active-residency port consumed by InteractionFeature. The
        /// capability exposes no district ECS entity, body, loader, or asset
        /// state.
        pub const DistrictAccess = struct {
            feature: *Self,

            pub fn activeTicketFor(
                self: *DistrictAccess,
                coord: district_contract.ChunkCoord,
            ) ?district_contract.LoadTicket {
                return self.feature.activeTicketFor(coord);
            }
        };

        /// Generation-aware copied-value route access consumed by NpcFeature.
        /// The capability exposes no district entity, component, borrowed
        /// slice, loader, body, asset, or residency mutation surface.
        pub const NavigationAccess = struct {
            feature: *Self,

            pub fn resolveNode(
                self: *NavigationAccess,
                reference: navigation_contract.NodeRef,
            ) navigation_contract.NodeResolution {
                return self.feature.resolveNavigationNode(reference);
            }

            pub fn resolveEdge(
                self: *NavigationAccess,
                source: navigation_contract.NodeRef,
                ordinal: u8,
            ) navigation_contract.EdgeResolution {
                return self.feature.resolveNavigationEdge(source, ordinal);
            }

            /// Validate one exact content-cohort edge without requiring or
            /// mutating residency. This exists for hostile snapshot preflight;
            /// it returns no route payload or district-private state.
            pub fn validateTraversal(
                self: *NavigationAccess,
                source: navigation_contract.NodeRef,
                target: navigation_contract.NodeRef,
            ) navigation_contract.TraversalValidation {
                return self.feature.validateNavigationTraversal(source, target);
            }
        };

        allocator: std.mem.Allocator,
        runtime: *engine.Runtime,
        bodies: *StaticBodies,
        loader: *Loader,
        slots: [max_districts]Slot = @splat(.absent),
        next_generation: u64 = 1,
        pending: FixedQueue(QueuedCommand, max_pending_commands) = .{},
        outcomes: FixedQueue(Outcome, max_outcomes) = .{},
        outcome_reservations: usize = 0,
        events: FixedQueue(Event, max_events) = .{},
        presentation: [max_districts]DistrictDraw = undefined,

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

        pub fn districtAccess(self: *Self) DistrictAccess {
            return .{ .feature = self };
        }

        pub fn navigationAccess(self: *Self) NavigationAccess {
            return .{ .feature = self };
        }

        pub fn deinit(self: *Self) void {
            self.runtime.assertOwnerThread();
            for (self.slots) |slot| {
                switch (slot) {
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
            const eligible_tick = try self.runtime.commandTargetTick();
            const reservation = outcomeReservation(command);
            if (self.pending.isFull()) {
                self.pending.recordRejected();
                return error.DistrictQueueFull;
            }
            const committed_outputs = std.math.add(
                usize,
                self.outcomes.count(),
                self.outcome_reservations,
            ) catch return error.DistrictOutcomeBackpressure;
            if (committed_outputs > max_outcomes or
                reservation > max_outcomes - committed_outputs)
            {
                self.pending.recordRejected();
                self.outcomes.recordRejected();
                return error.DistrictOutcomeBackpressure;
            }
            try self.pending.push(.{
                .command = command,
                .eligible_tick = eligible_tick,
                .outcome_reservation = @intCast(reservation),
            });
            self.outcome_reservations += reservation;
        }

        pub fn pollOutcome(self: *Self) ?Outcome {
            self.runtime.assertOwnerThread();
            return self.outcomes.pop();
        }

        pub fn pollEvent(self: *Self) ?Event {
            self.runtime.assertOwnerThread();
            return self.events.pop();
        }

        fn stateTag(self: *const Self) StateTag {
            self.runtime.assertOwnerThread();
            return self.aggregateStateTag();
        }

        pub fn count(self: *const Self) usize {
            self.runtime.assertOwnerThread();
            var result: usize = 0;
            for (self.slots) |slot| if (slot == .active) {
                result += 1;
            };
            return result;
        }

        pub fn diagnostics(self: *const Self) Diagnostics {
            self.runtime.assertOwnerThread();
            var slot_diagnostics: [max_districts]SlotDiagnostics = undefined;
            var active_count: u32 = 0;
            var loading_count: u32 = 0;
            var cancelling_count: u32 = 0;
            for (self.slots, 0..) |slot, index| {
                const state = std.meta.activeTag(slot);
                switch (state) {
                    .absent => {},
                    .loading => loading_count += 1,
                    .cancelling => cancelling_count += 1,
                    .active => active_count += 1,
                }
                slot_diagnostics[index] = .{
                    .state = state,
                    .request_id = switch (slot) {
                        .absent => null,
                        .loading => |flight| flight.request_id,
                        .cancelling => |value| value.flight.request_id,
                        .active => |active| active.request_id,
                    },
                    .ticket = slotTicket(slot),
                };
            }
            return .{
                .active_count = active_count,
                .loading_count = loading_count,
                .cancelling_count = cancelling_count,
                .body_count = std.math.cast(u32, self.bodyCount()) orelse
                    std.math.maxInt(u32),
                .slots = slot_diagnostics,
                .commands = self.pending.diagnostics(),
                .outcomes = self.outcomes.diagnostics(),
                .outcome_reservations = @intCast(self.outcome_reservations),
                .events = self.events.diagnostics(),
            };
        }

        /// Append the district state machine and active logical build without
        /// including loader/body handles or presentation assets. Scratch is
        /// caller-owned to keep tick capture allocation-free.
        pub fn writeLogicalState(
            self: *Self,
            writer: *engine.contracts.replay.Writer,
            scratch: []engine.PersistentId,
        ) !void {
            try self.runtime.ensureOwnerThread();
            const active_count = self.count();
            if (scratch.len < active_count) {
                return error.InsufficientLogicalStateScratch;
            }

            var canonical: [max_districts]CanonicalSlot = undefined;
            var scratch_index: usize = 0;
            for (self.slots, 0..) |slot, index| {
                canonical[index] = switch (slot) {
                    .absent => .{
                        .index = @intCast(index),
                        .occupied = false,
                    },
                    .loading => |flight| .{
                        .index = @intCast(index),
                        .occupied = true,
                        .coord = flight.ticket.coord,
                    },
                    .cancelling => |value| .{
                        .index = @intCast(index),
                        .occupied = true,
                        .coord = value.flight.ticket.coord,
                    },
                    .active => |active| blk: {
                        const id = try self.runtime.identity(active.runtime_id);
                        scratch[scratch_index] = id;
                        scratch_index += 1;
                        break :blk .{
                            .index = @intCast(index),
                            .occupied = true,
                            .coord = active.ticket.coord,
                            .id = id,
                        };
                    },
                };
            }
            std.mem.sort(CanonicalSlot, canonical[0..], {}, lessThanCanonicalSlot);

            writer.writeU8(@intCast(logical_state_domain.len));
            writer.writeBytes(logical_state_domain);
            writer.writeU16(logical_state_schema);
            writer.writeU64(self.runtime.tickIndex());
            writer.writeU8(@intCast(max_districts));
            writer.writeU32(@intCast(active_count));
            writer.writeU64(self.next_generation);

            for (canonical) |item| {
                switch (self.slots[item.index]) {
                    .absent => writer.writeU8(1),
                    .loading => |flight| {
                        writer.writeU8(2);
                        writeInFlight(writer, flight);
                    },
                    .cancelling => |cancelling| {
                        writer.writeU8(3);
                        writeInFlight(writer, cancelling.flight);
                        writer.writeU64(cancelling.cancel_request_id);
                    },
                    .active => |active| {
                        writer.writeU8(4);
                        const id = item.id orelse
                            return error.DistrictComponentInvariantBroken;
                        const district = self.runtime.get(active.runtime_id, District) orelse
                            return error.DistrictComponentInvariantBroken;
                        const runtime_bodies = self.runtime.get(active.runtime_id, RuntimeBodies) orelse
                            return error.DistrictBodiesInvariantBroken;

                        writer.writeU64(active.request_id);
                        writeLoadTicket(writer, active.ticket);
                        writePersistentId(writer, id);
                        writeLoadTicket(writer, district.ticket);
                        writer.writeU8(runtime_bodies.count);
                        try writeDistrictBuild(writer, district.build);
                    },
                }
            }

            writer.writeU32(@intCast(self.pending.count()));
            for (0..self.pending.count()) |index| {
                try writeQueuedCommand(writer, self.pending.at(index).?);
            }
            writer.writeU32(@intCast(self.outcomes.count()));
            writer.writeU32(@intCast(self.events.count()));
        }

        pub fn bodyCount(self: *const Self) usize {
            self.runtime.assertOwnerThread();
            var result: usize = 0;
            for (self.slots) |slot| switch (slot) {
                .active => |active| if (self.runtime.get(active.runtime_id, RuntimeBodies)) |bodies| {
                    result += bodies.count;
                },
                else => {},
            };
            return result;
        }

        pub fn activeTicketFor(
            self: *const Self,
            coord: district_contract.ChunkCoord,
        ) ?district_contract.LoadTicket {
            self.runtime.assertOwnerThread();
            const index = self.findCoordIndex(coord) orelse return null;
            return switch (self.slots[index]) {
                .active => |active| active.ticket,
                else => null,
            };
        }

        fn resolveNavigationNode(
            self: *const Self,
            reference: navigation_contract.NodeRef,
        ) navigation_contract.NodeResolution {
            self.runtime.assertOwnerThread();
            const canonical = canonicalNavigationBuild(CanonicalContent, reference.coord) orelse
                return .invalid_reference;
            if (reference.index >= canonical.navigation_node_count) {
                return .invalid_reference;
            }
            const index = self.findCoordIndex(reference.coord) orelse
                return .district_inactive;
            const active = switch (self.slots[index]) {
                .active => |value| value,
                else => return .district_inactive,
            };
            const district = self.runtime.get(active.runtime_id, District) orelse
                return .invalid_reference;
            if (reference.index >= district.build.navigation_node_count) {
                return .invalid_reference;
            }
            return .{ .ready = .{
                .ticket = active.ticket,
                .reference = reference,
                .node = district.build.navigation_nodes[reference.index],
            } };
        }

        fn resolveNavigationEdge(
            self: *const Self,
            source: navigation_contract.NodeRef,
            ordinal: u8,
        ) navigation_contract.EdgeResolution {
            const canonical = canonicalNavigationBuild(CanonicalContent, source.coord) orelse
                return .invalid_reference;
            if (source.index >= canonical.navigation_node_count) {
                return .invalid_reference;
            }
            if (ordinal >= canonical.navigation_nodes[source.index].edge_count) {
                return .invalid_ordinal;
            }
            const resolved = self.resolveNavigationNode(source);
            const node = switch (resolved) {
                .ready => |value| value,
                .district_inactive => return .district_inactive,
                .invalid_reference => return .invalid_reference,
            };
            if (ordinal >= node.node.edge_count) return .invalid_ordinal;
            const edge_index = @as(usize, node.node.first_edge) + ordinal;
            const slot_index = self.findCoordIndex(source.coord) orelse
                return .district_inactive;
            const active = switch (self.slots[slot_index]) {
                .active => |value| value,
                else => return .district_inactive,
            };
            if (!district_contract.LoadTicket.eql(active.ticket, node.ticket)) {
                return .district_inactive;
            }
            const district = self.runtime.get(active.runtime_id, District) orelse
                return .invalid_reference;
            if (edge_index >= district.build.navigation_edge_count) {
                return .invalid_ordinal;
            }
            return .{ .ready = .{
                .ticket = active.ticket,
                .source = source,
                .ordinal = ordinal,
                .edge = district.build.navigation_edges[edge_index],
            } };
        }

        fn validateNavigationTraversal(
            self: *const Self,
            source: navigation_contract.NodeRef,
            target: navigation_contract.NodeRef,
        ) navigation_contract.TraversalValidation {
            self.runtime.assertOwnerThread();
            const source_build = canonicalNavigationBuild(CanonicalContent, source.coord) orelse
                return .invalid_source;
            const target_build = canonicalNavigationBuild(CanonicalContent, target.coord) orelse
                return .invalid_target;
            if (source.index >= source_build.navigation_node_count) return .invalid_source;
            if (target.index >= target_build.navigation_node_count) return .invalid_target;
            const node = source_build.navigation_nodes[source.index];
            const first: usize = node.first_edge;
            const end = first + node.edge_count;
            for (source_build.navigation_edges[first..end]) |edge| {
                if (navigation_contract.NodeRef.eql(edge.target, target)) {
                    return .valid;
                }
            }
            return .not_connected;
        }

        pub fn stateForCoord(
            self: *const Self,
            coord: district_contract.ChunkCoord,
        ) ?StateTag {
            self.runtime.assertOwnerThread();
            const index = self.findCoordIndex(coord) orelse return null;
            return std.meta.activeTag(self.slots[index]);
        }

        pub fn hasPendingCommands(self: *const Self) bool {
            self.runtime.assertOwnerThread();
            return !self.pending.isEmpty();
        }

        pub fn extract(self: *Self) ![]const DistrictDraw {
            try self.runtime.ensureOwnerThread();
            var count_value: usize = 0;
            for (self.slots) |slot| switch (slot) {
                .active => |active| {
                    const district = self.runtime.get(active.runtime_id, District) orelse
                        return error.DistrictComponentInvariantBroken;
                    self.presentation[count_value] = .{
                        .persistent_id = try self.runtime.identity(active.runtime_id),
                        .ticket = district.ticket,
                        .build = district.build,
                        .assets = district.assets,
                    };
                    count_value += 1;
                },
                else => {},
            };
            std.mem.sort(
                DistrictDraw,
                self.presentation[0..count_value],
                {},
                lessThanDistrictDraw,
            );
            return self.presentation[0..count_value];
        }

        pub fn snapshotRecords(
            self: *Self,
            allocator: std.mem.Allocator,
        ) ![]DistrictV1 {
            try self.runtime.ensureSnapshotBoundary();
            if (self.hasPendingCommands()) return error.CommandsPending;
            for (self.slots) |slot| switch (slot) {
                .loading, .cancelling => return error.DistrictTransitionPending,
                else => {},
            };
            const records = try allocator.alloc(DistrictV1, self.count());
            errdefer allocator.free(records);
            var count_value: usize = 0;
            for (self.slots) |slot| switch (slot) {
                .active => |active| {
                    const district = self.runtime.get(active.runtime_id, District) orelse
                        return error.DistrictComponentInvariantBroken;
                    records[count_value] = .{
                        .id = try self.runtime.identity(active.runtime_id),
                        .coord = district.build.coord,
                        .recipe_version = district.build.recipe_version,
                        .checksum = district.build.checksum,
                    };
                    count_value += 1;
                },
                else => {},
            };
            std.debug.assert(count_value == records.len);
            std.mem.sort(DistrictV1, records, {}, lessThanDistrictRecord);
            return records;
        }

        pub fn restoreRecords(
            self: *Self,
            records: []const DistrictV1,
            assets: Assets,
        ) !void {
            try self.runtime.ensureOwnerThread();
            try validateRecords(CanonicalContent, records);
            if (self.stateTag() != .absent or self.hasPendingCommands()) {
                return error.RestoreRequiresEmptyFeature;
            }
            if (records.len == 0) return;

            const restore_checkpoint = try self.runtime.beginRegistrationRestore();
            errdefer self.runtime.rollbackRegistrationRestore(restore_checkpoint) catch |err| {
                std.debug.panic(
                    "district registration restore rollback failed: {s}",
                    .{@errorName(err)},
                );
            };

            var canonical: [max_districts]DistrictV1 = undefined;
            @memcpy(canonical[0..records.len], records);
            std.mem.sort(
                DistrictV1,
                canonical[0..records.len],
                {},
                lessThanDistrictRecord,
            );

            const original_next_generation = self.next_generation;
            errdefer {
                for (&self.slots) |*slot| switch (slot.*) {
                    .active => |active| {
                        self.destroyActiveOrPanic(active.runtime_id);
                        slot.* = .absent;
                    },
                    else => {},
                };
                self.next_generation = original_next_generation;
            }

            for (canonical[0..records.len]) |record| {
                const build = switch (CanonicalContent.build(
                    record.coord,
                    record.recipe_version,
                )) {
                    .ready => |value| value,
                    .failed => return error.InvalidDistrictRecord,
                };
                const ticket = district_contract.LoadTicket{
                    .coord = record.coord,
                    .generation = try self.takeGeneration(),
                };
                const slot_index = self.findFreeSlot() orelse
                    return error.DistrictCapacityInvariantBroken;
                const runtime_id = try self.activateNow(build, assets, ticket, record.id);
                self.slots[slot_index] = .{ .active = .{
                    .request_id = 0,
                    .ticket = ticket,
                    .runtime_id = runtime_id,
                } };
            }
            try self.runtime.commitRegistrationRestore(restore_checkpoint);
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
                const due = self.pending.pop().?;
                var reservation = due.outcome_reservation;
                errdefer self.releaseCommandReservation(&reservation);
                const retained_for_completion = try self.applyCommand(
                    due.command,
                    tick.tick_index,
                    &reservation,
                );
                if (retained_for_completion) {
                    if (reservation != 1) {
                        return error.DistrictOutcomeReservationInvariantBroken;
                    }
                } else {
                    self.releaseCommandReservation(&reservation);
                }
            }

            try self.pollOneCompletion(tick.tick_index);
        }

        fn applyCommand(
            self: *Self,
            command: Command,
            tick_index: u64,
            reservation: *u8,
        ) !bool {
            return switch (command) {
                .request_load => |request| try self.applyRequest(
                    request,
                    tick_index,
                    reservation,
                ),
                .cancel_load => |cancel| try self.applyCancel(
                    cancel,
                    tick_index,
                    reservation,
                ),
                .unload => |request| try self.applyUnload(
                    request,
                    tick_index,
                    reservation,
                ),
            };
        }

        fn applyRequest(
            self: *Self,
            request: RequestLoad,
            tick_index: u64,
            reservation: *u8,
        ) !bool {
            if (self.findCoordIndex(request.coord)) |existing_index| {
                try self.reject(
                    .request_load,
                    .coordinate_already_present,
                    request.request_id,
                    slotTicket(self.slots[existing_index]),
                    reservation,
                );
                return false;
            }
            const slot_index = self.findFreeSlot() orelse {
                try self.reject(
                    .request_load,
                    .district_capacity_reached,
                    request.request_id,
                    null,
                    reservation,
                );
                return false;
            };
            if (self.transitionSlotIndex() != null) {
                try self.reject(
                    .request_load,
                    .loader_busy,
                    request.request_id,
                    null,
                    reservation,
                );
                return false;
            }
            const ticket = district_contract.LoadTicket{
                .coord = request.coord,
                .generation = try self.takeGeneration(),
            };
            switch (try self.loader.request(.{
                .ticket = ticket,
                .recipe_version = CanonicalContent.current_recipe_version,
            })) {
                .accepted => {
                    self.slots[slot_index] = .{ .loading = .{
                        .request_id = request.request_id,
                        .ticket = ticket,
                        .request_tick = tick_index,
                        .assets = request.assets,
                    } };
                    self.emitCommandOutcome(reservation, .{ .load_requested = .{
                        .request_id = request.request_id,
                        .ticket = ticket,
                    } });
                    self.emitEvent(.{ .load_started = .{
                        .ticket = ticket,
                        .coord = request.coord,
                    } });
                    self.recordLifecycle(
                        .info,
                        engine.contracts.diagnostics.codes.district_load_requested,
                        tick_index,
                        ticket,
                        null,
                    );
                    // The load command retains its second reservation for the
                    // eventual ready, failed, or cancelled completion.
                    return true;
                },
                .busy => try self.reject(
                    .request_load,
                    .loader_busy,
                    request.request_id,
                    ticket,
                    reservation,
                ),
                .stale => try self.reject(
                    .request_load,
                    .loader_stale,
                    request.request_id,
                    ticket,
                    reservation,
                ),
                .invalid_ticket => try self.reject(
                    .request_load,
                    .invalid_ticket,
                    request.request_id,
                    ticket,
                    reservation,
                ),
            }
            return false;
        }

        fn applyCancel(
            self: *Self,
            cancel: CancelLoad,
            tick_index: u64,
            reservation: *u8,
        ) !bool {
            const slot_index = self.findTicketIndex(cancel.ticket) orelse {
                const reason: RejectionReason = if (self.transitionSlotIndex() != null)
                    .stale_ticket
                else
                    .district_not_loading;
                try self.reject(
                    .cancel_load,
                    reason,
                    cancel.request_id,
                    cancel.ticket,
                    reservation,
                );
                return false;
            };
            const flight = switch (self.slots[slot_index]) {
                .loading => |value| value,
                .cancelling, .absent, .active => {
                    try self.reject(
                        .cancel_load,
                        .district_not_loading,
                        cancel.request_id,
                        cancel.ticket,
                        reservation,
                    );
                    return false;
                },
            };
            if (!district_contract.LoadTicket.eql(flight.ticket, cancel.ticket)) {
                try self.reject(
                    .cancel_load,
                    .stale_ticket,
                    cancel.request_id,
                    cancel.ticket,
                    reservation,
                );
                return false;
            }
            switch (self.loader.cancel(cancel.ticket)) {
                .requested => {
                    self.slots[slot_index] = .{ .cancelling = .{
                        .flight = flight,
                        .cancel_request_id = cancel.request_id,
                    } };
                    self.emitCommandOutcome(reservation, .{ .cancellation_requested = .{
                        .request_id = cancel.request_id,
                        .ticket = cancel.ticket,
                    } });
                    self.emitEvent(.{ .cancellation_started = cancel.ticket });
                    self.recordLifecycle(
                        .info,
                        engine.contracts.diagnostics.codes.district_cancellation_requested,
                        tick_index,
                        cancel.ticket,
                        null,
                    );
                    // The original load command already owns the eventual
                    // terminal completion. Cancellation owns only this ack.
                    return false;
                },
                .idle => try self.reject(
                    .cancel_load,
                    .loader_idle,
                    cancel.request_id,
                    cancel.ticket,
                    reservation,
                ),
                .stale => try self.reject(
                    .cancel_load,
                    .loader_stale,
                    cancel.request_id,
                    cancel.ticket,
                    reservation,
                ),
                .invalid_ticket => try self.reject(
                    .cancel_load,
                    .invalid_ticket,
                    cancel.request_id,
                    cancel.ticket,
                    reservation,
                ),
            }
            return false;
        }

        fn applyUnload(
            self: *Self,
            request: Unload,
            tick_index: u64,
            reservation: *u8,
        ) !bool {
            const slot_index = self.findTicketIndex(request.ticket) orelse {
                const reason: RejectionReason = if (self.count() != 0)
                    .stale_ticket
                else
                    .district_not_active;
                try self.reject(
                    .unload,
                    reason,
                    request.request_id,
                    request.ticket,
                    reservation,
                );
                return false;
            };
            const active = switch (self.slots[slot_index]) {
                .active => |value| value,
                else => {
                    try self.reject(
                        .unload,
                        .district_not_active,
                        request.request_id,
                        request.ticket,
                        reservation,
                    );
                    return false;
                },
            };
            if (!district_contract.LoadTicket.eql(active.ticket, request.ticket)) {
                try self.reject(
                    .unload,
                    .stale_ticket,
                    request.request_id,
                    request.ticket,
                    reservation,
                );
                return false;
            }
            const id = try self.runtime.identity(active.runtime_id);
            try self.destroyActive(active.runtime_id);
            self.slots[slot_index] = .absent;
            self.emitCommandOutcome(reservation, .{ .unloaded = .{
                .request_id = request.request_id,
                .ticket = request.ticket,
                .id = id,
            } });
            self.emitEvent(.{ .deactivated = .{
                .ticket = request.ticket,
                .id = id,
                .reason = .unloaded,
            } });
            self.recordLifecycle(
                .info,
                engine.contracts.diagnostics.codes.district_unloaded,
                tick_index,
                request.ticket,
                id,
            );
            return false;
        }

        fn pollOneCompletion(self: *Self, tick_index: u64) !void {
            const slot_index = self.transitionSlotIndex() orelse return;
            const flight = switch (self.slots[slot_index]) {
                .loading => |value| value,
                .cancelling => |value| value.flight,
                else => return error.DistrictTransitionInvariantBroken,
            };
            // Even a fake that is immediately ready crosses a fixed-tick
            // boundary before its build may become authoritative.
            if (tick_index <= flight.request_tick) return;

            switch (self.loader.poll(flight.ticket)) {
                .pending => {},
                .completion => |completion| try self.applyCompletion(
                    slot_index,
                    flight,
                    completion,
                    tick_index,
                ),
                .idle => return error.DistrictLoaderUnexpectedIdle,
                .invalid_ticket => return error.DistrictLoaderInvalidCurrentTicket,
                .stale => return error.DistrictLoaderCurrentTicketStale,
            }
        }

        fn applyCompletion(
            self: *Self,
            slot_index: usize,
            flight: InFlight,
            completion: district_contract.Completion,
            tick_index: u64,
        ) !void {
            const received = completion.ticket();
            if (!district_contract.LoadTicket.eql(flight.ticket, received)) {
                self.emitEvent(.{ .stale_completion = .{
                    .expected = flight.ticket,
                    .received = received,
                } });
                return;
            }

            if (self.slots[slot_index] == .cancelling) {
                self.finishCancelled(slot_index, flight.ticket, tick_index);
                return;
            }

            switch (completion) {
                .ready => |ready| {
                    if (!district_contract.ChunkCoord.eql(ready.build.coord, flight.ticket.coord)) {
                        return error.DistrictBuildCoordinateMismatch;
                    }
                    if (ready.build.validationFailure()) |failure| {
                        return self.finishFailed(
                            slot_index,
                            flight,
                            .{ .invalid_build = failure },
                            tick_index,
                        );
                    }
                    const runtime_id = try self.activateNow(
                        ready.build,
                        flight.assets,
                        flight.ticket,
                        null,
                    );
                    errdefer self.destroyActiveOrPanic(runtime_id);
                    const id = try self.runtime.identity(runtime_id);
                    self.slots[slot_index] = .{ .active = .{
                        .request_id = flight.request_id,
                        .ticket = flight.ticket,
                        .runtime_id = runtime_id,
                    } };
                    self.emitCompletionOutcome(.{ .activated = .{
                        .request_id = flight.request_id,
                        .ticket = flight.ticket,
                        .id = id,
                        .coord = ready.build.coord,
                        .static_box_count = ready.build.static_box_count,
                    } });
                    self.emitEvent(.{ .activated = .{
                        .ticket = flight.ticket,
                        .id = id,
                    } });
                    self.recordLifecycle(
                        .info,
                        engine.contracts.diagnostics.codes.district_activated,
                        tick_index,
                        flight.ticket,
                        id,
                    );
                },
                .cancelled => self.finishCancelled(slot_index, flight.ticket, tick_index),
                .failed => |failed| self.finishFailed(
                    slot_index,
                    flight,
                    failed.failure,
                    tick_index,
                ),
            }
        }

        fn finishCancelled(
            self: *Self,
            slot_index: usize,
            ticket: district_contract.LoadTicket,
            tick_index: u64,
        ) void {
            self.slots[slot_index] = .absent;
            self.emitCompletionOutcome(.{ .cancelled = .{ .ticket = ticket } });
            self.emitEvent(.{ .deactivated = .{
                .ticket = ticket,
                .id = null,
                .reason = .cancelled,
            } });
            self.recordLifecycle(
                .info,
                engine.contracts.diagnostics.codes.district_cancelled,
                tick_index,
                ticket,
                null,
            );
        }

        fn finishFailed(
            self: *Self,
            slot_index: usize,
            flight: InFlight,
            failure: district_contract.Failure,
            tick_index: u64,
        ) void {
            self.slots[slot_index] = .absent;
            self.emitCompletionOutcome(.{ .load_failed = .{
                .request_id = flight.request_id,
                .ticket = flight.ticket,
                .failure = failure,
            } });
            self.emitEvent(.{ .deactivated = .{
                .ticket = flight.ticket,
                .id = null,
                .reason = .failed,
            } });
            self.recordLifecycle(
                .warning,
                engine.contracts.diagnostics.codes.district_load_failed,
                tick_index,
                flight.ticket,
                null,
            );
        }

        fn takeGeneration(self: *Self) !u64 {
            if (self.next_generation == 0) return error.DistrictGenerationExhausted;
            const generation = self.next_generation;
            self.next_generation +%= 1;
            return generation;
        }

        fn findFreeSlot(self: *const Self) ?usize {
            for (self.slots, 0..) |slot, index| if (slot == .absent) {
                return index;
            };
            return null;
        }

        fn findCoordIndex(
            self: *const Self,
            coord: district_contract.ChunkCoord,
        ) ?usize {
            for (self.slots, 0..) |slot, index| {
                const ticket = slotTicket(slot) orelse continue;
                if (district_contract.ChunkCoord.eql(ticket.coord, coord)) return index;
            }
            return null;
        }

        fn findTicketIndex(
            self: *const Self,
            ticket: district_contract.LoadTicket,
        ) ?usize {
            for (self.slots, 0..) |slot, index| {
                const current = slotTicket(slot) orelse continue;
                if (district_contract.LoadTicket.eql(current, ticket)) return index;
            }
            return null;
        }

        fn transitionSlotIndex(self: *const Self) ?usize {
            var result: ?usize = null;
            for (self.slots, 0..) |slot, index| switch (slot) {
                .loading, .cancelling => {
                    std.debug.assert(result == null);
                    result = index;
                },
                else => {},
            };
            return result;
        }

        fn aggregateStateTag(self: *const Self) StateTag {
            if (self.transitionSlotIndex()) |index| {
                return std.meta.activeTag(self.slots[index]);
            }
            for (self.slots) |slot| if (slot == .active) return .active;
            return .absent;
        }

        fn slotTicket(slot: Slot) ?district_contract.LoadTicket {
            return switch (slot) {
                .absent => null,
                .loading => |flight| flight.ticket,
                .cancelling => |value| value.flight.ticket,
                .active => |active| active.ticket,
            };
        }

        fn lessThanCanonicalSlot(_: void, lhs: CanonicalSlot, rhs: CanonicalSlot) bool {
            if (lhs.occupied != rhs.occupied) return lhs.occupied;
            if (!lhs.occupied) return lhs.index < rhs.index;
            if (!district_contract.ChunkCoord.eql(lhs.coord, rhs.coord)) {
                return lessThanChunkCoord({}, lhs.coord, rhs.coord);
            }
            if (lhs.id) |lhs_id| {
                if (rhs.id) |rhs_id| return lessThanPersistentId({}, lhs_id, rhs_id);
                return false;
            }
            if (rhs.id != null) return true;
            return lhs.index < rhs.index;
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

        /// Lifecycle instrumentation is deliberately nonfallible and outside
        /// authoritative transition policy. Journal overwrite or a frozen
        /// capture is visible in journal statistics but cannot reject, defer,
        /// or roll back the district operation that produced this entry.
        fn recordLifecycle(
            self: *Self,
            severity: engine.contracts.diagnostics.Severity,
            code: engine.contracts.diagnostics.Code,
            tick_index: u64,
            ticket: district_contract.LoadTicket,
            persistent_id: ?engine.PersistentId,
        ) void {
            _ = self.runtime.recordDiagnostic(.{
                .severity = severity,
                .category = .streaming,
                .code = code,
                .tick_index = tick_index,
                .thread_role = .simulation,
                .thread_id = engine.diagnostics.currentThreadId(),
                .persistent_id = persistent_id,
                .correlation_id = ticket.generation,
            });
        }

        fn reject(
            self: *Self,
            command: CommandKind,
            reason: RejectionReason,
            request_id: u64,
            ticket: ?district_contract.LoadTicket,
            reservation: *u8,
        ) !void {
            self.emitCommandOutcome(reservation, .{ .rejected = .{
                .command = command,
                .reason = reason,
                .request_id = request_id,
                .ticket = ticket,
            } });
        }

        fn emitCommandOutcome(
            self: *Self,
            reservation: *u8,
            outcome: Outcome,
        ) void {
            std.debug.assert(reservation.* > 0);
            std.debug.assert(self.outcome_reservations > 0);
            std.debug.assert(self.outcomes.count() < max_outcomes);
            reservation.* -= 1;
            self.outcome_reservations -= 1;
            self.outcomes.pushAssumeCapacity(outcome);
        }

        fn emitCompletionOutcome(self: *Self, outcome: Outcome) void {
            std.debug.assert(self.outcome_reservations > 0);
            std.debug.assert(self.outcomes.count() < max_outcomes);
            self.outcome_reservations -= 1;
            self.outcomes.pushAssumeCapacity(outcome);
        }

        fn emitEvent(self: *Self, event: Event) void {
            self.events.push(event) catch |err| switch (err) {
                error.DistrictQueueFull => {},
                else => unreachable,
            };
        }

        fn releaseCommandReservation(self: *Self, reservation: *u8) void {
            std.debug.assert(self.outcome_reservations >= reservation.*);
            self.outcome_reservations -= reservation.*;
            reservation.* = 0;
        }

        fn writeInFlight(
            writer: *engine.contracts.replay.Writer,
            flight: InFlight,
        ) void {
            writer.writeU64(flight.request_id);
            writeLoadTicket(writer, flight.ticket);
            writer.writeU64(flight.request_tick);
        }

        fn writeQueuedCommand(
            writer: *engine.contracts.replay.Writer,
            queued: QueuedCommand,
        ) !void {
            writer.writeU64(queued.eligible_tick);
            switch (queued.command) {
                .request_load => |request| {
                    writer.writeU8(1);
                    writer.writeU64(request.request_id);
                    writeChunkCoord(writer, request.coord);
                },
                .cancel_load => |cancel| {
                    writer.writeU8(2);
                    writer.writeU64(cancel.request_id);
                    writeLoadTicket(writer, cancel.ticket);
                },
                .unload => |unload_request| {
                    writer.writeU8(3);
                    writer.writeU64(unload_request.request_id);
                    writeLoadTicket(writer, unload_request.ticket);
                },
            }
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

/// A load request owns its immediate acknowledgement and eventual loader
/// completion. Cancellation owns only its immediate acknowledgement; the
/// original load reservation becomes the terminal `cancelled` outcome.
/// Unload has one terminal outcome.
fn outcomeReservation(command: Command) usize {
    return switch (command) {
        .request_load => 2,
        .cancel_load, .unload => 1,
    };
}

fn writePersistentId(
    writer: *engine.contracts.replay.Writer,
    id: engine.PersistentId,
) void {
    writer.writeU64(id.namespace);
    writer.writeU64(id.local);
}

fn writeChunkCoord(
    writer: *engine.contracts.replay.Writer,
    coord: district_contract.ChunkCoord,
) void {
    writer.writeI32(coord.x);
    writer.writeI32(coord.z);
}

fn writeLoadTicket(
    writer: *engine.contracts.replay.Writer,
    ticket: district_contract.LoadTicket,
) void {
    writeChunkCoord(writer, ticket.coord);
    writer.writeU64(ticket.generation);
}

fn writeVector3(
    writer: *engine.contracts.replay.Writer,
    value: [3]f32,
) !void {
    for (value) |component| try writer.writeF32(component);
}

fn writePose(
    writer: *engine.contracts.replay.Writer,
    raw: engine.physics.Pose,
) !void {
    var pose = try raw.normalized();
    if (quaternionNeedsNegation(pose.rotation)) {
        for (&pose.rotation) |*component| component.* = -component.*;
    }
    for (&pose.position) |*component| if (component.* == 0) {
        component.* = 0;
    };
    for (&pose.rotation) |*component| if (component.* == 0) {
        component.* = 0;
    };
    try writeVector3(writer, pose.position);
    for (pose.rotation) |component| try writer.writeF32(component);
}

fn writeDistrictBuild(
    writer: *engine.contracts.replay.Writer,
    build: district_contract.DistrictBuild,
) !void {
    try build.validate();
    writeChunkCoord(writer, build.coord);
    writer.writeU32(build.recipe_version);
    writer.writeU64(build.checksum);
    writer.writeU32(build.decoded_bytes);
    writer.writeU8(build.static_box_count);
    for (build.boxes()) |box| {
        try writePose(writer, box.pose);
        try writeVector3(writer, box.half_extents);
    }
}

fn quaternionNeedsNegation(rotation: [4]f32) bool {
    for ([_]usize{ 3, 2, 1, 0 }) |index| {
        if (rotation[index] > 0) return false;
        if (rotation[index] < 0) return true;
    }
    return false;
}

fn lessThanPersistentId(
    _: void,
    lhs: engine.PersistentId,
    rhs: engine.PersistentId,
) bool {
    if (lhs.namespace != rhs.namespace) return lhs.namespace < rhs.namespace;
    return lhs.local < rhs.local;
}

fn lessThanChunkCoord(
    _: void,
    lhs: district_contract.ChunkCoord,
    rhs: district_contract.ChunkCoord,
) bool {
    if (lhs.x != rhs.x) return lhs.x < rhs.x;
    return lhs.z < rhs.z;
}

fn lessThanDistrictRecord(_: void, lhs: DistrictV1, rhs: DistrictV1) bool {
    if (!district_contract.ChunkCoord.eql(lhs.coord, rhs.coord)) {
        return lessThanChunkCoord({}, lhs.coord, rhs.coord);
    }
    return lessThanPersistentId({}, lhs.id, rhs.id);
}

fn lessThanDistrictDraw(_: void, lhs: DistrictDraw, rhs: DistrictDraw) bool {
    if (!district_contract.ChunkCoord.eql(lhs.build.coord, rhs.build.coord)) {
        return lessThanChunkCoord({}, lhs.build.coord, rhs.build.coord);
    }
    return lessThanPersistentId({}, lhs.persistent_id, rhs.persistent_id);
}

fn FixedQueue(comptime T: type, comptime capacity: usize) type {
    if (capacity > std.math.maxInt(u32)) {
        @compileError("fixed queue capacity must fit diagnostic QueueStats");
    }
    return struct {
        const Self = @This();

        ring: engine.BoundedQueue(T, capacity) = .{},
        high_water: u32 = 0,
        rejected: u64 = 0,

        fn push(self: *Self, value: T) !void {
            self.ring.push(value) catch {
                self.recordRejected();
                return error.DistrictQueueFull;
            };
            self.recordHighWater();
        }

        fn pushAssumeCapacity(self: *Self, value: T) void {
            self.ring.pushAssumeCapacity(value);
            self.recordHighWater();
        }

        fn pop(self: *Self) ?T {
            return self.ring.pop();
        }

        fn peek(self: *const Self) ?T {
            return self.ring.peek();
        }

        fn at(self: *const Self, index: usize) ?T {
            return self.ring.at(index);
        }

        fn count(self: *const Self) usize {
            return self.ring.len;
        }

        fn isEmpty(self: *const Self) bool {
            return self.ring.isEmpty();
        }

        fn isFull(self: *const Self) bool {
            return self.ring.isFull();
        }

        fn recordRejected(self: *Self) void {
            self.rejected +|= 1;
        }

        fn diagnostics(self: *const Self) engine.contracts.diagnostics.QueueStats {
            return .{
                .occupancy = @intCast(self.ring.len),
                .high_water = self.high_water,
                .capacity = @intCast(capacity),
                .rejected = self.rejected,
            };
        }

        fn recordHighWater(self: *Self) void {
            self.high_water = @max(
                self.high_water,
                @as(u32, @intCast(self.ring.len)),
            );
        }
    };
}

/// Resolve exact cohort-bound route shape without activating or pinning a
/// district. Catalog admission requires cooked route bytes to equal this
/// logical recipe, so this validity check does not create a second authority.
fn canonicalNavigationBuild(
    comptime CanonicalContent: type,
    coord: district_contract.ChunkCoord,
) ?district_contract.DistrictBuild {
    const build = switch (CanonicalContent.build(
        coord,
        CanonicalContent.current_recipe_version,
    )) {
        .ready => |value| value,
        .failed => return null,
    };
    if (build.navigation_node_count == 0 or build.validationFailure() != null) {
        return null;
    }
    return build;
}

/// Neutral deterministic content used only to exercise feature mechanics.
/// Sandbox-installed coordinates and recipes belong to the host composition,
/// so the reusable feature's tests must not import game policy.
const TestCanonicalContent = struct {
    pub const current_recipe_version: u32 = 1;
    pub const navigation_primary_coord = district_contract.ChunkCoord{ .x = 0, .z = 0 };
    pub const navigation_adjacent_coord = district_contract.ChunkCoord{ .x = 1, .z = 0 };

    pub fn build(
        coord: district_contract.ChunkCoord,
        recipe_version: u32,
    ) district_contract.ProceduralResult {
        if (recipe_version != current_recipe_version) {
            return .{ .failed = .{ .unsupported_recipe_version = recipe_version } };
        }

        const origin_x = @as(f32, @floatFromInt(coord.x)) * district_contract.chunk_span;
        const origin_z = @as(f32, @floatFromInt(coord.z)) * district_contract.chunk_span;
        var result = district_contract.DistrictBuild{
            .coord = coord,
            .recipe_version = recipe_version,
            .checksum = 0,
            .decoded_bytes = district_contract.decodedByteCount(3, 0, 0),
            .static_box_count = 3,
        };
        result.static_boxes[0] = .{
            .pose = .{ .position = .{ origin_x, -0.5, origin_z } },
            .half_extents = .{ 7.5, 0.5, 7.5 },
        };
        result.static_boxes[1] = .{
            .pose = .{ .position = .{ origin_x - 5.5, 1, origin_z - 2 } },
            .half_extents = .{ 1, 1, 3 },
        };
        result.static_boxes[2] = .{
            .pose = .{ .position = .{ origin_x + 3, 0.75, origin_z + 4.5 } },
            .half_extents = .{ 2.5, 0.75, 0.75 },
        };
        if (district_contract.ChunkCoord.eql(coord, navigation_primary_coord)) {
            populatePrimaryNavigation(&result);
        } else if (district_contract.ChunkCoord.eql(coord, navigation_adjacent_coord)) {
            populateAdjacentNavigation(&result);
        }
        result.decoded_bytes = district_contract.decodedByteCount(
            result.static_box_count,
            result.navigation_node_count,
            result.navigation_edge_count,
        );
        result.checksum = result.calculateChecksum() catch unreachable;
        return .{ .ready = result };
    }

    fn populatePrimaryNavigation(result: *district_contract.DistrictBuild) void {
        result.navigation_node_count = 3;
        result.navigation_edge_count = 5;
        result.navigation_nodes[0] = .{
            .position = .{ -4, 0, 3 },
            .first_edge = 0,
            .edge_count = 1,
            .flags = district_contract.navigation_node_terminal,
        };
        result.navigation_nodes[1] = .{
            .position = .{ 2, 0, 3 },
            .first_edge = 1,
            .edge_count = 2,
        };
        result.navigation_nodes[2] = .{
            .position = .{ 7, 0, 3 },
            .first_edge = 3,
            .edge_count = 2,
        };
        result.navigation_edges[0] = .{ .target = .{
            .coord = navigation_primary_coord,
            .index = 1,
        } };
        result.navigation_edges[1] = .{ .target = .{
            .coord = navigation_primary_coord,
            .index = 0,
        } };
        result.navigation_edges[2] = .{ .target = .{
            .coord = navigation_primary_coord,
            .index = 2,
        } };
        result.navigation_edges[3] = .{ .target = .{
            .coord = navigation_primary_coord,
            .index = 1,
        } };
        result.navigation_edges[4] = .{ .target = .{
            .coord = navigation_adjacent_coord,
            .index = 0,
        } };
    }

    fn populateAdjacentNavigation(result: *district_contract.DistrictBuild) void {
        result.navigation_node_count = 3;
        result.navigation_edge_count = 5;
        result.navigation_nodes[0] = .{
            .position = .{ 9, 0, 3 },
            .first_edge = 0,
            .edge_count = 2,
        };
        result.navigation_nodes[1] = .{
            .position = .{ 14, 0, 3 },
            .first_edge = 2,
            .edge_count = 2,
        };
        result.navigation_nodes[2] = .{
            .position = .{ 20, 0, 3 },
            .first_edge = 4,
            .edge_count = 1,
            .flags = district_contract.navigation_node_terminal,
        };
        result.navigation_edges[0] = .{ .target = .{
            .coord = navigation_primary_coord,
            .index = 2,
        } };
        result.navigation_edges[1] = .{ .target = .{
            .coord = navigation_adjacent_coord,
            .index = 1,
        } };
        result.navigation_edges[2] = .{ .target = .{
            .coord = navigation_adjacent_coord,
            .index = 0,
        } };
        result.navigation_edges[3] = .{ .target = .{
            .coord = navigation_adjacent_coord,
            .index = 2,
        } };
        result.navigation_edges[4] = .{ .target = .{
            .coord = navigation_adjacent_coord,
            .index = 1,
        } };
    }
};

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
            const build = TestCanonicalContent.build(
                stale.coord,
                TestCanonicalContent.current_recipe_version,
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
        const build = TestCanonicalContent.build(
            ticket.coord,
            TestCanonicalContent.current_recipe_version,
        ).ready;
        return .{ .completion = .{ .ready = .{
            .ticket = ticket,
            .build = build,
        } } };
    }
};

const TestFeature = Feature(FakeStaticBodies, FakeLoader, TestCanonicalContent);
comptime {
    interaction_contract.assertDistrictImplementation(TestFeature.DistrictAccess);
    navigation_contract.assertImplementation(TestFeature.NavigationAccess);
}
const test_coord = district_contract.ChunkCoord{ .x = 0, .z = -4 };
const adjacent_coord = district_contract.ChunkCoord{ .x = 1, .z = -4 };
const third_coord = district_contract.ChunkCoord{ .x = 2, .z = -4 };
const test_assets = Assets{
    .scene = .{ .index = 7, .generation = 2 },
};
const adjacent_assets = Assets{
    .scene = .{ .index = 8, .generation = 3 },
};

fn expectLoadTicket(outcome: Outcome) !district_contract.LoadTicket {
    return switch (outcome) {
        .load_requested => |requested| requested.ticket,
        else => error.UnexpectedDistrictOutcome,
    };
}

fn expectRejectedReason(outcome: Outcome, expected: RejectionReason) !CommandRejected {
    const rejected = switch (outcome) {
        .rejected => |value| value,
        else => return error.UnexpectedDistrictOutcome,
    };
    try std.testing.expectEqual(expected, rejected.reason);
    return rejected;
}

fn loadDistrictActive(
    feature: *TestFeature,
    runtime: *engine.Runtime,
    request_id: u64,
    coord: district_contract.ChunkCoord,
    assets: Assets,
) !district_contract.LoadTicket {
    try feature.requestLoad(request_id, coord, assets);
    try runtime.tick();
    const ticket = try expectLoadTicket(feature.pollOutcome() orelse
        return error.MissingOutcome);
    try std.testing.expectEqualDeep(coord, ticket.coord);
    try std.testing.expect(
        (feature.pollEvent() orelse return error.MissingEvent) == .load_started,
    );
    try runtime.tick();
    const activated = switch (feature.pollOutcome() orelse return error.MissingOutcome) {
        .activated => |value| value,
        else => return error.UnexpectedDistrictOutcome,
    };
    try std.testing.expectEqualDeep(ticket, activated.ticket);
    try std.testing.expect(
        (feature.pollEvent() orelse return error.MissingEvent) == .activated,
    );
    return ticket;
}

fn districtRecord(
    id: engine.PersistentId,
    coord: district_contract.ChunkCoord,
) DistrictV1 {
    const build = TestCanonicalContent.build(
        coord,
        TestCanonicalContent.current_recipe_version,
    ).ready;
    return .{
        .id = id,
        .coord = coord,
        .recipe_version = build.recipe_version,
        .checksum = build.checksum,
    };
}

fn expectLifecycleEntry(
    entry: *const engine.contracts.diagnostics.Entry,
    sequence: u64,
    severity: engine.contracts.diagnostics.Severity,
    code: engine.contracts.diagnostics.Code,
    tick_index: u64,
    correlation_id: u64,
    persistent_id: ?engine.PersistentId,
) !void {
    try std.testing.expectEqual(sequence, entry.sequence);
    try std.testing.expectEqual(severity, entry.severity);
    try std.testing.expectEqual(engine.contracts.diagnostics.Category.streaming, entry.category);
    try std.testing.expectEqual(code, entry.code);
    try std.testing.expectEqual(@as(?u64, tick_index), entry.tick_index);
    try std.testing.expectEqual(engine.contracts.diagnostics.ThreadRole.simulation, entry.thread_role);
    try std.testing.expect(entry.thread_id != null);
    try std.testing.expectEqualDeep(persistent_id, entry.persistent_id);
    try std.testing.expectEqual(correlation_id, entry.correlation_id);
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
    var diagnostics = feature.diagnostics();
    try std.testing.expectEqual(StateTag.absent, diagnostics.slots[0].state);
    try std.testing.expectEqual(@as(u32, 1), diagnostics.commands.occupancy);
    try std.testing.expectEqual(@as(u32, 1), diagnostics.commands.high_water);
    try std.testing.expectEqual(@as(?u32, max_pending_commands), diagnostics.commands.capacity);
    try runtime.tick();
    try std.testing.expectEqual(StateTag.loading, feature.stateTag());
    try std.testing.expectEqual(@as(u8, 0), loader.poll_calls);
    diagnostics = feature.diagnostics();
    try std.testing.expectEqual(StateTag.loading, diagnostics.slots[0].state);
    try std.testing.expectEqual(@as(u32, 0), diagnostics.active_count);
    try std.testing.expectEqual(@as(u32, 0), diagnostics.body_count);
    try std.testing.expectEqual(@as(u64, 1), diagnostics.slots[0].ticket.?.generation);
    try std.testing.expectEqual(@as(u32, 1), diagnostics.outcomes.occupancy);
    try std.testing.expectEqual(@as(u32, 1), diagnostics.events.occupancy);
    const ticket = try expectLoadTicket(feature.pollOutcome() orelse return error.MissingOutcome);

    try runtime.tick();
    try std.testing.expectEqual(StateTag.active, feature.stateTag());
    try std.testing.expectEqual(@as(usize, 1), feature.count());
    try std.testing.expectEqual(@as(usize, 3), feature.bodyCount());
    try std.testing.expectEqual(@as(u8, 3), bodies.live_count);
    try std.testing.expectEqual(@as(usize, 1), runtime.entityCount());
    diagnostics = feature.diagnostics();
    try std.testing.expectEqual(StateTag.active, diagnostics.slots[0].state);
    try std.testing.expectEqual(@as(u32, 1), diagnostics.active_count);
    try std.testing.expectEqual(@as(u32, 3), diagnostics.body_count);
    try std.testing.expectEqual(@as(u32, 1), diagnostics.outcomes.high_water);
    try std.testing.expectEqual(@as(u32, 2), diagnostics.events.high_water);
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

test "district logical state covers FIFO commands transitions build and body count" {
    var runtime = try engine.Runtime.init(std.testing.allocator, .{
        .namespace = 602,
        .fixed_delta_seconds = 1.0 / 120.0,
    });
    defer runtime.deinit();
    var bodies = FakeStaticBodies{ .runtime = &runtime };
    var loader = FakeLoader{};
    var feature = TestFeature.init(std.testing.allocator, &runtime, &bodies, &loader);
    defer feature.deinit();
    var registry = runtime.registry();
    try feature.register(&registry);

    try feature.requestLoad(21, test_coord, test_assets);
    var none: [0]engine.PersistentId = .{};
    var pending_writer = engine.contracts.replay.Writer.init();
    try feature.writeLogicalState(&pending_writer, &none);
    const pending = pending_writer.final();

    try runtime.tick();
    var loading_writer = engine.contracts.replay.Writer.init();
    try feature.writeLogicalState(&loading_writer, &none);
    const loading = loading_writer.final();
    try std.testing.expect(!std.mem.eql(u8, &pending, &loading));

    try runtime.tick();
    var too_small = engine.contracts.replay.Writer.init();
    try std.testing.expectError(
        error.InsufficientLogicalStateScratch,
        feature.writeLogicalState(&too_small, &none),
    );
    var scratch: [1]engine.PersistentId = undefined;
    var active_writer = engine.contracts.replay.Writer.init();
    try feature.writeLogicalState(&active_writer, &scratch);
    const active = active_writer.final();
    var repeated_writer = engine.contracts.replay.Writer.init();
    try feature.writeLogicalState(&repeated_writer, &scratch);
    try std.testing.expectEqual(active, repeated_writer.final());
    try std.testing.expectEqual(@as(u8, 3), bodies.live_count);
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
    try std.testing.expectEqual(
        @as(u32, 0),
        feature.diagnostics().outcome_reservations,
    );
}

test "district lifecycle journal is ordered and correlated across cancel reload and unload" {
    var runtime = try engine.Runtime.init(std.testing.allocator, .{
        .namespace = 612,
        .fixed_delta_seconds = 1.0 / 120.0,
    });
    defer runtime.deinit();
    var bodies = FakeStaticBodies{ .runtime = &runtime };
    var loader = FakeLoader{};
    var feature = TestFeature.init(std.testing.allocator, &runtime, &bodies, &loader);
    defer feature.deinit();
    var registry = runtime.registry();
    try feature.register(&registry);

    try feature.requestLoad(81, test_coord, test_assets);
    try runtime.tick();
    const cancelled_ticket = try expectLoadTicket(
        feature.pollOutcome() orelse return error.MissingOutcome,
    );
    try std.testing.expectEqual(@as(u64, 1), cancelled_ticket.generation);
    try std.testing.expect(feature.pollOutcome() == null);
    try std.testing.expect(feature.pollEvent().? == .load_started);
    try std.testing.expect(feature.pollEvent() == null);

    try feature.cancelLoad(82, cancelled_ticket);
    try runtime.tick();
    try std.testing.expect(
        (feature.pollOutcome() orelse return error.MissingOutcome) == .cancellation_requested,
    );
    try std.testing.expect(
        (feature.pollOutcome() orelse return error.MissingOutcome) == .cancelled,
    );
    try std.testing.expect(feature.pollOutcome() == null);
    try std.testing.expect(feature.pollEvent().? == .cancellation_started);
    try std.testing.expect(feature.pollEvent().? == .deactivated);
    try std.testing.expect(feature.pollEvent() == null);
    try std.testing.expectEqual(StateTag.absent, feature.stateTag());

    try feature.requestLoad(83, test_coord, test_assets);
    try runtime.tick();
    const active_ticket = try expectLoadTicket(
        feature.pollOutcome() orelse return error.MissingOutcome,
    );
    try std.testing.expectEqual(@as(u64, 2), active_ticket.generation);
    try std.testing.expect(feature.pollOutcome() == null);
    try std.testing.expect(feature.pollEvent().? == .load_started);
    try std.testing.expect(feature.pollEvent() == null);

    try runtime.tick();
    const activated = switch (feature.pollOutcome() orelse return error.MissingOutcome) {
        .activated => |value| value,
        else => return error.UnexpectedDistrictOutcome,
    };
    try std.testing.expectEqualDeep(active_ticket, activated.ticket);
    try std.testing.expect(feature.pollOutcome() == null);
    try std.testing.expect(feature.pollEvent().? == .activated);
    try std.testing.expect(feature.pollEvent() == null);

    try feature.unload(84, active_ticket);
    try runtime.tick();
    const unloaded = switch (feature.pollOutcome() orelse return error.MissingOutcome) {
        .unloaded => |value| value,
        else => return error.UnexpectedDistrictOutcome,
    };
    try std.testing.expectEqualDeep(activated.id, unloaded.id);
    try std.testing.expect(feature.pollOutcome() == null);
    try std.testing.expect(feature.pollEvent().? == .deactivated);
    try std.testing.expect(feature.pollEvent() == null);

    const diagnostics = feature.diagnostics();
    try std.testing.expectEqual(StateTag.absent, diagnostics.slots[0].state);
    try std.testing.expectEqual(@as(u32, 0), diagnostics.active_count);
    try std.testing.expectEqual(@as(u32, 0), diagnostics.body_count);
    try std.testing.expectEqual(@as(u32, 0), diagnostics.commands.occupancy);
    try std.testing.expectEqual(@as(u32, 0), diagnostics.outcomes.occupancy);
    try std.testing.expectEqual(@as(u32, 0), diagnostics.events.occupancy);

    const journal = runtime.diagnosticJournal();
    try std.testing.expectEqual(@as(usize, 6), journal.stats().count);
    const entries = journal.borrowedChronological();
    try expectLifecycleEntry(
        entries.at(0) orelse return error.MissingDiagnosticEntry,
        1,
        .info,
        engine.contracts.diagnostics.codes.district_load_requested,
        1,
        cancelled_ticket.generation,
        null,
    );
    try expectLifecycleEntry(
        entries.at(1) orelse return error.MissingDiagnosticEntry,
        2,
        .info,
        engine.contracts.diagnostics.codes.district_cancellation_requested,
        2,
        cancelled_ticket.generation,
        null,
    );
    try expectLifecycleEntry(
        entries.at(2) orelse return error.MissingDiagnosticEntry,
        3,
        .info,
        engine.contracts.diagnostics.codes.district_cancelled,
        2,
        cancelled_ticket.generation,
        null,
    );
    try expectLifecycleEntry(
        entries.at(3) orelse return error.MissingDiagnosticEntry,
        4,
        .info,
        engine.contracts.diagnostics.codes.district_load_requested,
        3,
        active_ticket.generation,
        null,
    );
    try expectLifecycleEntry(
        entries.at(4) orelse return error.MissingDiagnosticEntry,
        5,
        .info,
        engine.contracts.diagnostics.codes.district_activated,
        4,
        active_ticket.generation,
        activated.id,
    );
    try expectLifecycleEntry(
        entries.at(5) orelse return error.MissingDiagnosticEntry,
        6,
        .info,
        engine.contracts.diagnostics.codes.district_unloaded,
        5,
        active_ticket.generation,
        activated.id,
    );
}

test "runtime-owned district trigger freezes one match without affecting transitions" {
    var runtime = try engine.Runtime.init(std.testing.allocator, .{
        .namespace = 613,
        .fixed_delta_seconds = 1.0 / 120.0,
    });
    defer runtime.deinit();
    var bodies = FakeStaticBodies{ .runtime = &runtime };
    var loader = FakeLoader{};
    var feature = TestFeature.init(std.testing.allocator, &runtime, &bodies, &loader);
    defer feature.deinit();
    var registry = runtime.registry();
    try feature.register(&registry);

    runtime.armDiagnosticFreeze(.{
        .severity = .info,
        .category = .streaming,
        .code = engine.contracts.diagnostics.codes.district_activated,
    });
    try std.testing.expect(runtime.diagnosticJournal().stats().trigger_armed);

    try feature.requestLoad(91, test_coord, test_assets);
    try runtime.tick();
    const ticket = try expectLoadTicket(
        feature.pollOutcome() orelse return error.MissingOutcome,
    );
    _ = feature.pollEvent() orelse return error.MissingEvent;
    try std.testing.expectEqual(StateTag.loading, feature.stateTag());
    try std.testing.expect(!runtime.diagnosticJournal().stats().frozen);
    try std.testing.expect(runtime.diagnosticJournal().stats().trigger_armed);
    try std.testing.expectEqual(@as(usize, 1), runtime.diagnosticJournal().stats().count);

    try runtime.tick();
    try std.testing.expect(
        (feature.pollOutcome() orelse return error.MissingOutcome) == .activated,
    );
    _ = feature.pollEvent() orelse return error.MissingEvent;
    try std.testing.expectEqual(StateTag.active, feature.stateTag());
    try std.testing.expectEqual(@as(u8, 3), bodies.live_count);
    try std.testing.expect(runtime.diagnosticJournal().stats().frozen);
    try std.testing.expect(!runtime.diagnosticJournal().stats().trigger_armed);

    try feature.unload(92, ticket);
    try runtime.tick();
    try std.testing.expect(
        (feature.pollOutcome() orelse return error.MissingOutcome) == .unloaded,
    );
    _ = feature.pollEvent() orelse return error.MissingEvent;
    try std.testing.expectEqual(StateTag.absent, feature.stateTag());
    try std.testing.expectEqual(@as(u8, 0), bodies.live_count);

    const journal = runtime.diagnosticJournal();
    try std.testing.expect(journal.stats().frozen);
    try std.testing.expect(!journal.stats().trigger_armed);
    try std.testing.expectEqual(@as(usize, 2), journal.stats().count);
    try std.testing.expectEqual(@as(u64, 1), journal.stats().rejected_while_frozen);
    try std.testing.expectEqual(@as(usize, 0), runtime.entityCount());
    const diagnostics = feature.diagnostics();
    try std.testing.expectEqual(@as(u32, 0), diagnostics.commands.occupancy);
    try std.testing.expectEqual(@as(u32, 0), diagnostics.outcomes.occupancy);
    try std.testing.expectEqual(@as(u32, 0), diagnostics.events.occupancy);
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
    const build = TestCanonicalContent.build(
        test_coord,
        TestCanonicalContent.current_recipe_version,
    ).ready;
    var record = DistrictV1{
        .id = .{ .namespace = 610, .local = 1 },
        .coord = test_coord,
        .recipe_version = TestCanonicalContent.current_recipe_version,
        .checksum = build.checksum,
    };
    try validateRecords(TestCanonicalContent, (&record)[0..1]);
    record.checksum +%= 1;
    try std.testing.expectError(
        error.DistrictChecksumMismatch,
        validateRecords(TestCanonicalContent, (&record)[0..1]),
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
    const entries = runtime.diagnosticJournal().borrowedChronological();
    try std.testing.expectEqual(@as(usize, 2), entries.len());
    try expectLifecycleEntry(
        entries.at(1) orelse return error.MissingDiagnosticEntry,
        2,
        .warning,
        engine.contracts.diagnostics.codes.district_load_failed,
        2,
        1,
        null,
    );
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
    var diagnostics = feature.diagnostics();
    try std.testing.expectEqual(@as(u32, max_pending_commands), diagnostics.commands.occupancy);
    try std.testing.expectEqual(@as(u32, max_pending_commands), diagnostics.commands.high_water);
    try std.testing.expectEqual(@as(?u32, max_pending_commands), diagnostics.commands.capacity);
    try std.testing.expectEqual(@as(u64, 0), diagnostics.commands.rejected);
    try std.testing.expectError(
        error.DistrictQueueFull,
        feature.requestLoad(999, test_coord, .{}),
    );
    diagnostics = feature.diagnostics();
    try std.testing.expectEqual(@as(u32, max_pending_commands), diagnostics.commands.occupancy);
    try std.testing.expectEqual(@as(u64, 1), diagnostics.commands.rejected);
}

test "outcome reservations reject admission without fault and recover after drain" {
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
    const ticket = switch (feature.outcomes.at(0) orelse return error.MissingOutcome) {
        .load_requested => |value| value.ticket,
        else => return error.UnexpectedDistrictOutcome,
    };

    var next_request: u64 = 100;
    fill: while (true) {
        var admitted: usize = 0;
        while (admitted < max_pending_commands) : (admitted += 1) {
            feature.requestLoad(next_request, test_coord, .{}) catch |err| switch (err) {
                error.DistrictOutcomeBackpressure => break,
                else => return err,
            };
            next_request += 1;
        }
        if (admitted == 0) break :fill;
        try runtime.tick();
    }

    var diagnostics = feature.diagnostics();
    try std.testing.expectEqual(@as(u32, max_outcomes - 1), diagnostics.outcomes.occupancy);
    try std.testing.expectEqual(@as(u32, 0), diagnostics.outcome_reservations);
    try std.testing.expect(!runtime.isFaulted());

    // Unload has a one-outcome contract and can use the final reserved slot.
    try feature.unload(next_request, ticket);
    try runtime.tick();
    diagnostics = feature.diagnostics();
    try std.testing.expectEqual(@as(u32, max_outcomes), diagnostics.outcomes.occupancy);
    try std.testing.expectEqual(@as(u32, max_outcomes), diagnostics.outcomes.high_water);
    try std.testing.expectEqual(@as(?u32, max_outcomes), diagnostics.outcomes.capacity);
    try std.testing.expectEqual(@as(u32, 0), diagnostics.outcome_reservations);
    try std.testing.expectError(
        error.DistrictOutcomeBackpressure,
        feature.requestLoad(next_request + 1, test_coord, .{}),
    );
    try std.testing.expect(!runtime.isFaulted());

    var drained: usize = 0;
    while (feature.pollOutcome() != null) drained += 1;
    try std.testing.expectEqual(@as(usize, max_outcomes), drained);
    try feature.requestLoad(next_request + 2, test_coord, .{});
    try runtime.tick();
    _ = try expectLoadTicket(feature.pollOutcome() orelse return error.MissingOutcome);
    try std.testing.expectEqual(StateTag.loading, feature.stateTag());

    feature.deinit();
    feature_live = false;
    try std.testing.expectEqual(@as(u8, 0), bodies.live_count);
    try std.testing.expectEqual(@as(usize, 0), runtime.entityCount());
}

test "full event storage drops observability without fault and recovers" {
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
    const ticket = try expectLoadTicket(feature.pollOutcome() orelse
        return error.MissingOutcome);
    try runtime.tick();
    if ((feature.pollOutcome() orelse return error.MissingOutcome) != .activated) {
        return error.UnexpectedDistrictOutcome;
    }
    try std.testing.expect(!runtime.isFaulted());
    var diagnostics = feature.diagnostics();
    try std.testing.expectEqual(@as(u32, max_events), diagnostics.events.occupancy);
    try std.testing.expectEqual(@as(u32, max_events), diagnostics.events.high_water);
    try std.testing.expectEqual(@as(?u32, max_events), diagnostics.events.capacity);
    try std.testing.expectEqual(@as(u64, 1), diagnostics.events.rejected);

    var drained: usize = 0;
    while (feature.pollEvent() != null) drained += 1;
    try std.testing.expectEqual(@as(usize, max_events), drained);
    try feature.unload(101, ticket);
    try runtime.tick();
    if ((feature.pollOutcome() orelse return error.MissingOutcome) != .unloaded) {
        return error.UnexpectedDistrictOutcome;
    }
    try std.testing.expect(feature.pollEvent() != null);
    try std.testing.expect(feature.pollEvent() == null);
    diagnostics = feature.diagnostics();
    try std.testing.expectEqual(@as(u64, 1), diagnostics.events.rejected);
    try std.testing.expectEqual(@as(u32, 0), diagnostics.events.occupancy);
    try std.testing.expect(!runtime.isFaulted());

    feature.deinit();
    feature_live = false;
    try std.testing.expectEqual(@as(u8, 0), bodies.live_count);
    try std.testing.expectEqual(@as(usize, 0), runtime.entityCount());
}

test "two adjacent districts activate extract unload and reload independently" {
    var runtime = try engine.Runtime.init(std.testing.allocator, .{
        .namespace = 614,
        .fixed_delta_seconds = 1.0 / 120.0,
    });
    defer runtime.deinit();
    var bodies = FakeStaticBodies{ .runtime = &runtime };
    var loader = FakeLoader{};
    var feature = TestFeature.init(std.testing.allocator, &runtime, &bodies, &loader);
    defer feature.deinit();
    var registry = runtime.registry();
    try feature.register(&registry);

    // Load east first so canonical extraction cannot accidentally be physical
    // slot or admission order.
    const east_ticket = try loadDistrictActive(
        &feature,
        &runtime,
        101,
        adjacent_coord,
        adjacent_assets,
    );
    const west_ticket = try loadDistrictActive(
        &feature,
        &runtime,
        102,
        test_coord,
        test_assets,
    );

    try std.testing.expectEqual(@as(usize, 2), feature.count());
    try std.testing.expectEqual(@as(usize, 6), feature.bodyCount());
    try std.testing.expectEqual(@as(u8, 6), bodies.live_count);
    try std.testing.expectEqual(@as(usize, 2), runtime.entityCount());
    try std.testing.expectEqualDeep(west_ticket, feature.activeTicketFor(test_coord).?);
    try std.testing.expectEqualDeep(east_ticket, feature.activeTicketFor(adjacent_coord).?);
    var districts = feature.districtAccess();
    try std.testing.expectEqualDeep(west_ticket, districts.activeTicketFor(test_coord).?);
    try std.testing.expectEqualDeep(east_ticket, districts.activeTicketFor(adjacent_coord).?);
    try std.testing.expect(districts.activeTicketFor(third_coord) == null);

    const diagnostics = feature.diagnostics();
    try std.testing.expectEqual(@as(u32, 2), diagnostics.active_count);
    try std.testing.expectEqual(@as(u32, 0), diagnostics.loading_count);
    try std.testing.expectEqual(@as(u32, 0), diagnostics.cancelling_count);
    try std.testing.expectEqual(@as(u32, 6), diagnostics.body_count);
    try std.testing.expectEqual(StateTag.active, diagnostics.slots[0].state);
    try std.testing.expectEqual(StateTag.active, diagnostics.slots[1].state);

    const draws = try feature.extract();
    try std.testing.expectEqual(@as(usize, 2), draws.len);
    try std.testing.expectEqualDeep(test_coord, draws[0].build.coord);
    try std.testing.expectEqualDeep(test_assets, draws[0].assets);
    try std.testing.expectEqualDeep(adjacent_coord, draws[1].build.coord);
    try std.testing.expectEqualDeep(adjacent_assets, draws[1].assets);
    const records = try feature.snapshotRecords(std.testing.allocator);
    defer std.testing.allocator.free(records);
    try std.testing.expectEqual(@as(usize, 2), records.len);
    try std.testing.expectEqualDeep(test_coord, records[0].coord);
    try std.testing.expectEqualDeep(adjacent_coord, records[1].coord);

    try feature.unload(103, east_ticket);
    try runtime.tick();
    try std.testing.expect(
        (feature.pollOutcome() orelse return error.MissingOutcome) == .unloaded,
    );
    try std.testing.expect(
        (feature.pollEvent() orelse return error.MissingEvent) == .deactivated,
    );
    try std.testing.expectEqual(@as(usize, 1), feature.count());
    try std.testing.expectEqual(@as(usize, 3), feature.bodyCount());
    try std.testing.expectEqual(@as(u8, 3), bodies.live_count);
    try std.testing.expectEqual(@as(usize, 1), runtime.entityCount());
    try std.testing.expect(feature.activeTicketFor(adjacent_coord) == null);
    try std.testing.expectEqualDeep(west_ticket, feature.activeTicketFor(test_coord).?);
    try std.testing.expect(districts.activeTicketFor(adjacent_coord) == null);
    try std.testing.expectEqualDeep(west_ticket, districts.activeTicketFor(test_coord).?);
    try std.testing.expectEqualDeep(test_coord, (try feature.extract())[0].build.coord);

    const reloaded_east = try loadDistrictActive(
        &feature,
        &runtime,
        104,
        adjacent_coord,
        adjacent_assets,
    );
    try std.testing.expect(reloaded_east.generation > east_ticket.generation);
    try std.testing.expectEqual(@as(usize, 2), feature.count());
    try std.testing.expectEqual(@as(usize, 6), feature.bodyCount());
    try std.testing.expectEqual(@as(usize, 2), (try feature.extract()).len);
}

test "navigation access resolves copied route values only for the active generation" {
    var runtime = try engine.Runtime.init(std.testing.allocator, .{
        .namespace = 619,
        .fixed_delta_seconds = 1.0 / 120.0,
    });
    defer runtime.deinit();
    var bodies = FakeStaticBodies{ .runtime = &runtime };
    var loader = FakeLoader{};
    var feature = TestFeature.init(std.testing.allocator, &runtime, &bodies, &loader);
    defer feature.deinit();
    var registry = runtime.registry();
    try feature.register(&registry);
    var navigation = feature.navigationAccess();

    const west_start = navigation_contract.NodeRef{
        .coord = TestCanonicalContent.navigation_primary_coord,
        .index = 0,
    };
    const west_seam = navigation_contract.NodeRef{
        .coord = TestCanonicalContent.navigation_primary_coord,
        .index = 2,
    };
    const east_seam = navigation_contract.NodeRef{
        .coord = TestCanonicalContent.navigation_adjacent_coord,
        .index = 0,
    };
    const west_middle = navigation_contract.NodeRef{
        .coord = TestCanonicalContent.navigation_primary_coord,
        .index = 1,
    };
    try std.testing.expect(navigation.resolveNode(west_start) == .district_inactive);
    try std.testing.expect(navigation.resolveNode(.{
        .coord = TestCanonicalContent.navigation_primary_coord,
        .index = 3,
    }) == .invalid_reference);
    try std.testing.expect(navigation.resolveEdge(west_start, 1) == .invalid_ordinal);
    try std.testing.expectEqual(
        navigation_contract.TraversalValidation.valid,
        navigation.validateTraversal(west_start, west_middle),
    );
    try std.testing.expectEqual(
        navigation_contract.TraversalValidation.valid,
        navigation.validateTraversal(west_seam, east_seam),
    );
    try std.testing.expectEqual(
        navigation_contract.TraversalValidation.not_connected,
        navigation.validateTraversal(west_start, east_seam),
    );
    try std.testing.expectEqual(
        navigation_contract.TraversalValidation.invalid_source,
        navigation.validateTraversal(.{
            .coord = TestCanonicalContent.navigation_primary_coord,
            .index = 3,
        }, west_middle),
    );
    try std.testing.expectEqual(
        navigation_contract.TraversalValidation.invalid_target,
        navigation.validateTraversal(west_start, .{
            .coord = TestCanonicalContent.navigation_adjacent_coord,
            .index = 3,
        }),
    );

    const west_ticket = try loadDistrictActive(
        &feature,
        &runtime,
        151,
        TestCanonicalContent.navigation_primary_coord,
        test_assets,
    );
    const west = switch (navigation.resolveNode(west_start)) {
        .ready => |value| value,
        else => return error.ExpectedReadyNavigationNode,
    };
    try std.testing.expectEqualDeep(west_ticket, west.ticket);
    try std.testing.expectEqualDeep([3]f32{ -4, 0, 3 }, west.node.position);
    try std.testing.expect(west.node.terminal());
    const first_edge = switch (navigation.resolveEdge(west_start, 0)) {
        .ready => |value| value,
        else => return error.ExpectedReadyNavigationEdge,
    };
    try std.testing.expectEqualDeep(west_ticket, first_edge.ticket);
    try std.testing.expectEqualDeep(
        navigation_contract.NodeRef{
            .coord = TestCanonicalContent.navigation_primary_coord,
            .index = 1,
        },
        first_edge.edge.target,
    );
    try std.testing.expect(navigation.resolveEdge(west_start, 1) == .invalid_ordinal);
    try std.testing.expect(navigation.resolveNode(.{
        .coord = TestCanonicalContent.navigation_primary_coord,
        .index = 3,
    }) == .invalid_reference);
    try std.testing.expect(navigation.resolveNode(east_seam) == .district_inactive);

    const east_ticket = try loadDistrictActive(
        &feature,
        &runtime,
        152,
        TestCanonicalContent.navigation_adjacent_coord,
        adjacent_assets,
    );
    const cross_edge = switch (navigation.resolveEdge(west_seam, 1)) {
        .ready => |value| value,
        else => return error.ExpectedReadyCrossDistrictEdge,
    };
    try std.testing.expectEqualDeep(east_seam, cross_edge.edge.target);
    const east = switch (navigation.resolveNode(cross_edge.edge.target)) {
        .ready => |value| value,
        else => return error.ExpectedReadyCrossDistrictTarget,
    };
    try std.testing.expectEqualDeep(east_ticket, east.ticket);
    try std.testing.expectEqualDeep([3]f32{ 9, 0, 3 }, east.node.position);

    try feature.unload(153, east_ticket);
    try runtime.tick();
    try std.testing.expect(
        (feature.pollOutcome() orelse return error.MissingOutcome) == .unloaded,
    );
    try std.testing.expect(
        (feature.pollEvent() orelse return error.MissingEvent) == .deactivated,
    );
    try std.testing.expect(navigation.resolveNode(east_seam) == .district_inactive);
    const retained_source = switch (navigation.resolveEdge(west_seam, 1)) {
        .ready => |value| value,
        else => return error.ExpectedReadyRetainedSourceEdge,
    };
    try std.testing.expectEqualDeep(east_seam, retained_source.edge.target);
    try std.testing.expectEqualDeep(west_ticket, retained_source.ticket);
}

test "two-slot admission reports duplicate busy capacity and stale tickets structurally" {
    var runtime = try engine.Runtime.init(std.testing.allocator, .{
        .namespace = 615,
        .fixed_delta_seconds = 1.0 / 120.0,
    });
    defer runtime.deinit();
    var bodies = FakeStaticBodies{};
    var loader = FakeLoader{};
    var feature = TestFeature.init(std.testing.allocator, &runtime, &bodies, &loader);
    defer feature.deinit();
    var registry = runtime.registry();
    try feature.register(&registry);

    try feature.requestLoad(201, test_coord, test_assets);
    try runtime.tick();
    const west_ticket = try expectLoadTicket(feature.pollOutcome() orelse
        return error.MissingOutcome);
    _ = feature.pollEvent() orelse return error.MissingEvent;

    // Commands precede completion: the second slot is free, but the shared
    // loader is still owned by west for this tick.
    try feature.requestLoad(202, adjacent_coord, adjacent_assets);
    try runtime.tick();
    const busy = try expectRejectedReason(
        feature.pollOutcome() orelse return error.MissingOutcome,
        .loader_busy,
    );
    try std.testing.expect(busy.ticket == null);
    try std.testing.expect(
        (feature.pollOutcome() orelse return error.MissingOutcome) == .activated,
    );
    _ = feature.pollEvent() orelse return error.MissingEvent;
    try std.testing.expectEqual(@as(u8, 1), loader.request_calls);

    try feature.requestLoad(203, test_coord, test_assets);
    try runtime.tick();
    const duplicate = try expectRejectedReason(
        feature.pollOutcome() orelse return error.MissingOutcome,
        .coordinate_already_present,
    );
    try std.testing.expectEqualDeep(west_ticket, duplicate.ticket.?);
    const east_ticket = try loadDistrictActive(
        &feature,
        &runtime,
        204,
        adjacent_coord,
        adjacent_assets,
    );

    try feature.requestLoad(205, third_coord, .{});
    try runtime.tick();
    _ = try expectRejectedReason(
        feature.pollOutcome() orelse return error.MissingOutcome,
        .district_capacity_reached,
    );

    const stale = district_contract.LoadTicket{
        .coord = test_coord,
        .generation = west_ticket.generation + 100,
    };
    try feature.unload(206, stale);
    try runtime.tick();
    _ = try expectRejectedReason(
        feature.pollOutcome() orelse return error.MissingOutcome,
        .stale_ticket,
    );
    try feature.cancelLoad(207, east_ticket);
    try runtime.tick();
    _ = try expectRejectedReason(
        feature.pollOutcome() orelse return error.MissingOutcome,
        .district_not_loading,
    );
    try std.testing.expectEqual(@as(usize, 2), feature.count());
    try std.testing.expectEqual(@as(u8, 6), bodies.live_count);
}

test "candidate cancellation and failure preserve an active neighbor" {
    var runtime = try engine.Runtime.init(std.testing.allocator, .{
        .namespace = 616,
        .fixed_delta_seconds = 1.0 / 120.0,
    });
    defer runtime.deinit();
    var bodies = FakeStaticBodies{};
    var loader = FakeLoader{};
    var feature = TestFeature.init(std.testing.allocator, &runtime, &bodies, &loader);
    defer feature.deinit();
    var registry = runtime.registry();
    try feature.register(&registry);

    const west_ticket = try loadDistrictActive(
        &feature,
        &runtime,
        301,
        test_coord,
        test_assets,
    );
    try feature.requestLoad(302, adjacent_coord, adjacent_assets);
    try runtime.tick();
    const cancelling_ticket = try expectLoadTicket(feature.pollOutcome() orelse
        return error.MissingOutcome);
    _ = feature.pollEvent() orelse return error.MissingEvent;
    var diagnostics = feature.diagnostics();
    try std.testing.expectEqual(@as(u32, 1), diagnostics.active_count);
    try std.testing.expectEqual(@as(u32, 1), diagnostics.loading_count);
    try std.testing.expectEqual(@as(u32, 3), diagnostics.body_count);

    try feature.cancelLoad(303, cancelling_ticket);
    try runtime.tick();
    try std.testing.expect(
        (feature.pollOutcome() orelse return error.MissingOutcome) == .cancellation_requested,
    );
    try std.testing.expect(
        (feature.pollOutcome() orelse return error.MissingOutcome) == .cancelled,
    );
    try std.testing.expect(
        (feature.pollEvent() orelse return error.MissingEvent) == .cancellation_started,
    );
    try std.testing.expect(
        (feature.pollEvent() orelse return error.MissingEvent) == .deactivated,
    );
    try std.testing.expectEqual(@as(usize, 1), feature.count());
    try std.testing.expectEqual(@as(u8, 3), bodies.live_count);
    try std.testing.expectEqualDeep(west_ticket, feature.activeTicketFor(test_coord).?);

    loader.failure = .{ .unsupported_recipe_version = 404 };
    try feature.requestLoad(304, adjacent_coord, adjacent_assets);
    try runtime.tick();
    _ = try expectLoadTicket(feature.pollOutcome() orelse return error.MissingOutcome);
    _ = feature.pollEvent() orelse return error.MissingEvent;
    try runtime.tick();
    const failed = switch (feature.pollOutcome() orelse return error.MissingOutcome) {
        .load_failed => |value| value,
        else => return error.UnexpectedDistrictOutcome,
    };
    try std.testing.expectEqual(@as(u32, 404), failed.failure.unsupported_recipe_version);
    try std.testing.expect(
        (feature.pollEvent() orelse return error.MissingEvent) == .deactivated,
    );
    try std.testing.expectEqual(@as(usize, 1), feature.count());
    try std.testing.expectEqual(@as(usize, 3), feature.bodyCount());
    try std.testing.expectEqual(@as(usize, 1), runtime.entityCount());
    try std.testing.expectEqualDeep(west_ticket, feature.activeTicketFor(test_coord).?);
    try std.testing.expect(feature.activeTicketFor(adjacent_coord) == null);
    diagnostics = feature.diagnostics();
    try std.testing.expectEqual(@as(u32, 1), diagnostics.active_count);
    try std.testing.expectEqual(@as(u32, 0), diagnostics.loading_count);
}

test "two-record validation and restore rollback are whole-operation transactional" {
    const records = [_]DistrictV1{
        districtRecord(.{ .namespace = 617, .local = 10 }, test_coord),
        districtRecord(.{ .namespace = 617, .local = 11 }, adjacent_coord),
    };
    try validateRecords(TestCanonicalContent, &records);

    var duplicate_coord = records;
    duplicate_coord[1].coord = test_coord;
    duplicate_coord[1].checksum = TestCanonicalContent.build(
        test_coord,
        TestCanonicalContent.current_recipe_version,
    ).ready.checksum;
    try std.testing.expectError(
        error.DuplicateDistrictCoordinate,
        validateRecords(TestCanonicalContent, &duplicate_coord),
    );
    var duplicate_id = records;
    duplicate_id[1].id = duplicate_id[0].id;
    try std.testing.expectError(
        error.DuplicateDistrictPersistentId,
        validateRecords(TestCanonicalContent, &duplicate_id),
    );
    const too_many = [_]DistrictV1{ records[0], records[1], records[0] };
    try std.testing.expectError(
        error.TooManyDistricts,
        validateRecords(TestCanonicalContent, &too_many),
    );

    var runtime = try engine.Runtime.init(std.testing.allocator, .{
        .namespace = 617,
        .fixed_delta_seconds = 1.0 / 120.0,
        .next_local_id = 1,
    });
    defer runtime.deinit();
    // The first district owns three bodies. Failing the first body of the
    // second candidate proves the restored prefix is also rolled back.
    var bodies = FakeStaticBodies{ .fail_create_call = 4 };
    var loader = FakeLoader{};
    var feature = TestFeature.init(std.testing.allocator, &runtime, &bodies, &loader);
    defer feature.deinit();
    var registry = runtime.registry();
    try feature.register(&registry);

    try std.testing.expectError(
        error.InjectedStaticBodyCreateFailure,
        feature.restoreRecords(&records, test_assets),
    );
    try std.testing.expectEqual(StateTag.absent, feature.stateTag());
    try std.testing.expectEqual(@as(usize, 0), feature.count());
    try std.testing.expectEqual(@as(usize, 0), feature.bodyCount());
    try std.testing.expectEqual(@as(u8, 0), bodies.live_count);
    try std.testing.expectEqual(@as(usize, 0), runtime.entityCount());
    try std.testing.expectEqual(@as(u64, 1), feature.next_generation);
    try std.testing.expectEqual(@as(u64, 1), try runtime.nextLocalId());
    for (feature.diagnostics().slots) |slot| {
        try std.testing.expectEqual(StateTag.absent, slot.state);
        try std.testing.expect(slot.ticket == null);
    }

    // The failed batch must not retain explicit-ID tombstones or an observed
    // cursor. Clearing the injected port failure allows an exact same-runtime
    // retry to restore both records.
    bodies.fail_create_call = null;
    try feature.restoreRecords(&records, test_assets);
    try std.testing.expectEqual(@as(usize, max_districts), feature.count());
    try std.testing.expectEqual(@as(usize, 6), feature.bodyCount());
    try std.testing.expectEqual(@as(u8, 6), bodies.live_count);
    try std.testing.expectEqual(@as(usize, max_districts), runtime.entityCount());
    try std.testing.expectEqual(@as(u64, 12), try runtime.nextLocalId());
}

test "restore input order cannot change canonical snapshot extraction or logical digest" {
    const west = districtRecord(.{ .namespace = 618, .local = 10 }, test_coord);
    const east = districtRecord(.{ .namespace = 618, .local = 11 }, adjacent_coord);
    const east_first = [_]DistrictV1{ east, west };
    const west_first = [_]DistrictV1{ west, east };

    var snapshot_a: [max_districts]DistrictV1 = undefined;
    var draws_a: [max_districts]DistrictDraw = undefined;
    var digest_a: engine.contracts.replay.Digest = undefined;
    {
        var runtime = try engine.Runtime.init(std.testing.allocator, .{
            .namespace = 618,
            .fixed_delta_seconds = 1.0 / 120.0,
            .next_local_id = 20,
        });
        defer runtime.deinit();
        var bodies = FakeStaticBodies{};
        var loader = FakeLoader{};
        var feature = TestFeature.init(
            std.testing.allocator,
            &runtime,
            &bodies,
            &loader,
        );
        defer feature.deinit();
        var registry = runtime.registry();
        try feature.register(&registry);
        try feature.restoreRecords(&east_first, test_assets);

        const snapshot = try feature.snapshotRecords(std.testing.allocator);
        defer std.testing.allocator.free(snapshot);
        try std.testing.expectEqual(@as(usize, max_districts), snapshot.len);
        @memcpy(snapshot_a[0..], snapshot);
        const draws = try feature.extract();
        try std.testing.expectEqual(@as(usize, max_districts), draws.len);
        @memcpy(draws_a[0..], draws);
        var scratch: [max_districts]engine.PersistentId = undefined;
        var writer = engine.contracts.replay.Writer.init();
        try feature.writeLogicalState(&writer, &scratch);
        digest_a = writer.final();
    }

    var runtime = try engine.Runtime.init(std.testing.allocator, .{
        .namespace = 618,
        .fixed_delta_seconds = 1.0 / 120.0,
        .next_local_id = 20,
    });
    defer runtime.deinit();
    var bodies = FakeStaticBodies{};
    var loader = FakeLoader{};
    var feature = TestFeature.init(
        std.testing.allocator,
        &runtime,
        &bodies,
        &loader,
    );
    defer feature.deinit();
    var registry = runtime.registry();
    try feature.register(&registry);
    try feature.restoreRecords(&west_first, test_assets);

    const snapshot_b = try feature.snapshotRecords(std.testing.allocator);
    defer std.testing.allocator.free(snapshot_b);
    try std.testing.expectEqualSlices(DistrictV1, &snapshot_a, snapshot_b);
    try std.testing.expectEqualDeep(test_coord, snapshot_a[0].coord);
    try std.testing.expectEqualDeep(adjacent_coord, snapshot_a[1].coord);
    const draws_b = try feature.extract();
    try std.testing.expectEqual(@as(usize, max_districts), draws_b.len);
    for (draws_a, draws_b) |draw_a, draw_b| {
        try std.testing.expectEqualDeep(draw_a, draw_b);
    }
    var scratch_b: [max_districts]engine.PersistentId = undefined;
    var writer_b = engine.contracts.replay.Writer.init();
    try feature.writeLogicalState(&writer_b, &scratch_b);
    try std.testing.expectEqual(digest_a, writer_b.final());
}
