//! SDL-free executable and integration-test root for sandbox slices.

const std = @import("std");
const simulation = @import("sandbox_simulation");
const simulation_snapshot = @import("simulation_snapshot");
const crate_contract = @import("crate_contract");
const character_contract = @import("character_contract");
const vehicle_contract = @import("vehicle_contract");
const district_contract = @import("district_contract");
const district_feature_contract = @import("district_feature_contract");
const interaction_contract = @import("interaction_feature_contract");
const npc_contract = @import("npc_contract");
const npc_encounter_contract = @import("npc_encounter_contract");
const vitals_contract = @import("vitals_contract");
const sandbox_contracts = @import("sandbox_host_contracts");
const sandbox_diagnostics = @import("sandbox_diagnostics_contract");
const sandbox_replay = @import("sandbox_replay");
const authoring = @import("sandbox_authoring");
const developer_diagnostics = @import("developer_diagnostics");
const engine = @import("incinerator_engine");
const sandbox_save = @import("sandbox_save");
const save_slots = @import("save_slots");
const headless_config = @import("headless_config");
const headless_content = @import("headless_content");
const headless_clock = @import("headless_clock");
const macos_signals = @import("macos_signals");
const headless_authority = @import("headless_authority");

const DeveloperSnapshot = developer_diagnostics.Snapshot(sandbox_diagnostics.Diagnostics);
const DeveloperExport = developer_diagnostics.Export(sandbox_diagnostics.Diagnostics);

fn developerSnapshot(world: *simulation.Simulation) DeveloperSnapshot {
    const journal = world.diagnosticJournal().stats();
    return .{
        .frame_index = null,
        .simulation = world.diagnostics(),
        .authority_session = null,
        .content_worker = null,
        .district_streams = null,
        .gpu = null,
        .host_time = null,
        .journal = .{
            .count = @intCast(journal.count),
            .capacity = @intCast(journal.capacity),
            .overwritten = journal.overwritten,
            .rejected_while_frozen = journal.rejected_while_frozen,
            .rejected_sequence_exhausted = journal.rejected_sequence_exhausted,
            .sequence_exhausted = journal.sequence_exhausted,
            .frozen = journal.frozen,
            .trigger_armed = journal.trigger_armed,
        },
    };
}

const Invocation = struct {
    config_path: []const u8,
    content_manifest_path: []const u8,
    synthetic_producers: bool,
};

const StopReason = enum { virtual_target, signal, hard_lag };

const OperationalSummary = struct {
    schema_version: u16 = 1,
    product: []const u8 = "incinerator_headless",
    restored: bool,
    stop_reason: StopReason,
    ticks_this_run: u64,
    world_tick: u64,
    save_bytes: u64,
    producer_ingress_high_water: u32,
    producer_transaction_high_water: u32,
    producer_delivery_high_water: u32,
    producer_admission_rejections: u64,
    producer_submitted: [2]u64,
    producer_completed: [2]u64,
    observational_events_consumed: u64,
};

const OperationalConsumers = struct {
    observational_events: u64 = 0,

    fn consume(self: *OperationalConsumers, world: *simulation.Simulation) !void {
        const diagnostics = world.diagnostics();
        if (diagnostics.characters.outcomes.occupancy != 0 or
            diagnostics.vehicles.outcomes.occupancy != 0 or
            diagnostics.district.outcomes.occupancy != 0 or
            diagnostics.interaction.outcomes.occupancy != 0)
        {
            // Preserve the authoritative outcome in its owner queue as fault
            // evidence. This host submitted no commands in these categories.
            return error.UnownedHeadlessFeatureOutcome;
        }
        if (world.peekNpcOutcome() != null) return error.UnownedHeadlessFeatureOutcome;
        try self.consumeVitalsOutcomes(world);
        while (world.pollCharacterEvent() != null) self.observational_events +|= 1;
        while (world.pollVehicleEvent() != null) self.observational_events +|= 1;
        while (world.pollDistrictEvent() != null) self.observational_events +|= 1;
        while (world.pollNpcEvent() != null) self.observational_events +|= 1;
        while (world.pollNpcEncounterCue() != null) self.observational_events +|= 1;
    }

    fn ensureQuiescent(_: *const OperationalConsumers) !void {}

    fn consumeVitalsOutcomes(
        self: *OperationalConsumers,
        world: *simulation.Simulation,
    ) !void {
        while (world.peekVitalsOutcome()) |outcome| {
            if (std.meta.activeTag(outcome) == .damage) {
                const damage = outcome.damage;
                if (!ownsEncounterDamage(world, damage)) {
                    return error.UnownedHeadlessFeatureOutcome;
                }
                if (damage.killed) {
                    const expected_event = vitals_contract.Event{ .died = .{
                        .target = damage.proposal.target,
                        .source = damage.proposal.source,
                        .cause = damage.proposal.cause,
                        .authority_tick = damage.proposal.authority_tick,
                        .correlation = damage.proposal.correlation,
                    } };
                    const actual_event = world.peekVitalsEvent() orelse
                        return error.HeadlessEncounterDeathEventMissing;
                    if (!std.meta.eql(actual_event, expected_event)) {
                        return error.UnownedHeadlessFeatureOutcome;
                    }
                    try world.commitVitalsOutcome(outcome);
                    try world.commitVitalsEvent(expected_event);
                    self.observational_events +|= 2;
                } else {
                    try world.commitVitalsOutcome(outcome);
                    self.observational_events +|= 1;
                }
                continue;
            }
            return error.UnownedHeadlessFeatureOutcome;
        }
        // Death events are consumed only as the exact mate of an owned killed
        // damage outcome above. Any remaining event belongs to another host
        // transaction and must stay at the FIFO head as fault evidence.
        if (world.peekVitalsEvent() != null) {
            return error.UnownedHeadlessFeatureOutcome;
        }
    }
};

fn ownsEncounterDamage(
    world: *const simulation.Simulation,
    damage: vitals_contract.DamageOutcome,
) bool {
    const proposal = damage.proposal;
    if (proposal.source.kind != .npc or proposal.target.kind != .player or
        proposal.cause != .npc_melee)
    {
        return false;
    }
    const source = vitals_contract.Target{
        .kind = .npc,
        .id = proposal.source.id,
        .incarnation = proposal.source.incarnation,
    };
    if (world.npcEncounter(source) == null) return false;
    return proposal.correlation == npc_encounter_contract.attackDamageCorrelation(
        source,
        proposal.source.action_sequence,
    );
}

const SyntheticProducers = struct {
    handles: [2]headless_authority.ProducerHandle,
    crate_id: ?engine.PersistentId = null,
    spawn_pending: bool = false,
    next_sequence: [2]u64 = .{ 1, 1 },
    submitted: [2]u64 = .{ 0, 0 },
    completed: [2]u64 = .{ 0, 0 },

    fn init(
        authority: *headless_authority.Authority,
        restored: bool,
        namespace: u64,
    ) !SyntheticProducers {
        var result = SyntheticProducers{ .handles = undefined };
        for (&result.handles) |*handle| {
            handle.* = switch (authority.registerProducer()) {
                .registered => |value| value,
                else => return error.HeadlessSyntheticProducerRegistrationFailed,
            };
        }
        if (restored) {
            const count = authority.world.diagnostics().crates.active_count;
            if (count > 1) return error.HeadlessSyntheticWorldShapeMismatch;
            if (count == 1) {
                const id = engine.PersistentId{ .namespace = namespace, .local = 1 };
                _ = try authority.world.crate(id);
                result.crate_id = id;
            }
        }
        return result;
    }

    fn beforeTick(
        self: *SyntheticProducers,
        authority: *headless_authority.Authority,
    ) !void {
        if (self.crate_id == null) {
            if (!self.spawn_pending) {
                try authority.submitInternal(.{ .spawn = .{
                    .request_id = 1,
                    .pose = .{ .position = .{ 0, 2, 0 } },
                } });
                self.spawn_pending = true;
            }
            return;
        }
        if (authority.world.tickIndex() % 64 == 0) {
            try self.submitBatch(authority, 1);
        }
    }

    fn afterTick(
        self: *SyntheticProducers,
        authority: *headless_authority.Authority,
    ) !void {
        if (self.spawn_pending) {
            const outcome = authority.pollInternalOutcome() orelse
                return error.HeadlessSyntheticSpawnOutcomeMissing;
            self.crate_id = switch (outcome) {
                .spawned => |spawned| if (spawned.request_id == 1)
                    spawned.id
                else
                    return error.HeadlessSyntheticSpawnOutcomeMismatch,
                else => return error.HeadlessSyntheticSpawnOutcomeMismatch,
            };
            self.spawn_pending = false;
        }
        for (self.handles, 0..) |handle, producer_index| {
            while (true) switch (authority.pollProducerResult(handle)) {
                .empty => break,
                .stale_handle => return error.HeadlessSyntheticProducerBecameStale,
                .result => |result| {
                    const outcome = switch (result) {
                        .outcome => |value| value,
                        .submission_rejected => return error.HeadlessSyntheticSubmissionRejected,
                    };
                    const relocated = switch (outcome) {
                        .relocated => |value| value,
                        else => return error.HeadlessSyntheticOutcomeMismatch,
                    };
                    if ((relocated.transaction_id & 1) !=
                        @as(u64, @intCast(producer_index)) or
                        !std.meta.eql(relocated.id, self.crate_id.?))
                    {
                        return error.HeadlessSyntheticCompletionMisrouted;
                    }
                    self.completed[producer_index] += 1;
                },
            };
        }
    }

    fn submitBatch(
        self: *SyntheticProducers,
        authority: *headless_authority.Authority,
        per_producer: usize,
    ) !void {
        const id = self.crate_id orelse return;
        for (0..per_producer) |_| {
            for (self.handles, 0..) |handle, producer_index| {
                const sequence = self.next_sequence[producer_index];
                if (sequence > std.math.maxInt(u64) >> 1) {
                    return error.HeadlessSyntheticTransactionSequenceExhausted;
                }
                const transaction_id = (sequence << 1) |
                    @as(u64, @intCast(producer_index));
                const offset: f32 = @floatFromInt(sequence % 17);
                if (authority.submitExternal(handle, .{
                    .transaction_id = transaction_id,
                    .id = id,
                    .target_pose = .{ .position = .{
                        offset - 8,
                        2,
                        if (producer_index == 0) -2 else 2,
                    } },
                    .velocity = .zero,
                }) != .accepted) {
                    return error.HeadlessSyntheticAdmissionFailed;
                }
                self.next_sequence[producer_index] += 1;
                self.submitted[producer_index] += 1;
            }
        }
    }

    fn unregister(
        self: *SyntheticProducers,
        authority: *headless_authority.Authority,
    ) !void {
        if (!std.meta.eql(self.submitted, self.completed)) {
            return error.HeadlessSyntheticCompletionCountMismatch;
        }
        for (self.handles) |handle| {
            if (authority.unregisterProducer(handle) != .unregistered) {
                return error.HeadlessSyntheticProducerUnregisterFailed;
            }
        }
    }
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const invocation = try parseInvocation(args) orelse {
        try writeUsage(init.io);
        return;
    };

    // All operator-controlled bytes and the exact content cohort are admitted
    // before storage is touched or Flecs/Jolt authority is constructed.
    const config_bytes = try readBoundedFile(
        init.io,
        init.gpa,
        invocation.config_path,
        headless_config.max_config_bytes,
    );
    defer init.gpa.free(config_bytes);
    var parsed_config = try headless_config.parse(init.gpa, config_bytes);
    defer parsed_config.deinit();

    const manifest_bytes = try readBoundedFile(
        init.io,
        init.gpa,
        invocation.content_manifest_path,
        headless_content.max_manifest_bytes,
    );
    defer init.gpa.free(manifest_bytes);
    var parsed_manifest = try headless_content.parse(init.gpa, manifest_bytes);
    defer parsed_manifest.deinit();
    const content_digest = try parsed_config.value.contentDigest();
    try parsed_manifest.value.admit(content_digest);

    _ = try std.Io.Dir.createDirPathStatus(
        .cwd(),
        init.io,
        parsed_config.value.save_root,
        std.Io.Dir.Permissions.fromMode(0o700),
    );
    var store = try save_slots.SaveSlots.open(
        init.io,
        try save_slots.RootPath.parse(parsed_config.value.save_root),
    );
    defer store.deinit(init.io);
    const slot = try save_slots.SlotId.parse(parsed_config.value.save_slot);
    switch (store.recover(init.io, slot)) {
        .clean, .discarded_stale_candidate => {},
        .failed => return error.HeadlessSaveRecoveryFailed,
    }

    const world_config = simulationConfig(parsed_config.value);
    const metadata = sandbox_save.Metadata{
        .payload_schema = sandbox_contracts.snapshot_schema,
        .simulation_build_digest = try simulation_snapshot.currentSimulationBuildFingerprint(),
        .world_config_digest = try simulation_snapshot.worldConfigFingerprint(world_config),
        .content_digest = content_digest,
    };

    const loaded = try store.load(init.io, init.gpa, slot, .{});
    var restored = false;
    var authority = switch (loaded) {
        .loaded => |bytes| blk: {
            defer init.gpa.free(bytes);
            if (parsed_config.value.start_policy == .fresh) {
                return error.HeadlessFreshSlotAlreadyExists;
            }
            const view = try sandbox_save.parseCompatible(bytes, metadata);
            restored = true;
            break :blk try headless_authority.Authority.initRestored(
                init.gpa,
                view.payload,
                world_config,
            );
        },
        .failed => |failure| switch (failure) {
            .not_found => blk: {
                if (parsed_config.value.start_policy == .restore_required) {
                    return error.HeadlessRestoreRequired;
                }
                break :blk try headless_authority.Authority.initFresh(
                    init.gpa,
                    world_config,
                );
            },
            else => return error.HeadlessSaveLoadFailed,
        },
    };
    defer authority.deinit();

    var signal_guard = try macos_signals.Guard.install();
    defer signal_guard.deinit();

    runOperationalAuthority(
        init,
        parsed_config.value,
        &authority,
        &store,
        slot,
        metadata,
        restored,
        invocation.synthetic_producers,
    ) catch |err| {
        // Every propagated failure is pre-commit except the explicitly
        // classified post-rename directory-sync warning below.
        emitDeveloperDiagnostics(&authority.world) catch |diagnostic_error| {
            std.debug.print(
                "headless diagnostics emission failed while preserving {s}: {s}\n",
                .{ @errorName(err), @errorName(diagnostic_error) },
            );
        };
        if (err == error.HeadlessSaveDirectorySyncWarning) {
            std.debug.print(
                "HEADLESS_EXIT status=degraded error={s} save=committed_sync_warning\n",
                .{@errorName(err)},
            );
        } else {
            std.debug.print(
                "HEADLESS_EXIT status=fault error={s} save=skipped\n",
                .{@errorName(err)},
            );
        }
        return err;
    };
}

fn runOperationalAuthority(
    init: std.process.Init,
    config: headless_config.ConfigV1,
    authority: *headless_authority.Authority,
    store: *const save_slots.SaveSlots,
    slot: save_slots.SlotId,
    metadata: sandbox_save.Metadata,
    restored: bool,
    enable_synthetic_producers: bool,
) !void {
    const policy = headless_clock.Policy{
        .max_catch_up_ticks = config.clock.max_catch_up_ticks,
        .soft_lag_ticks = config.clock.soft_lag_ticks,
        .hard_lag_ticks = config.clock.hard_lag_ticks,
    };
    const start = std.Io.Clock.Timestamp.now(init.io, .awake);
    var scheduler = try headless_clock.Scheduler.init(
        switch (config.clock.mode) {
            .virtual => .{ .virtual = .{ .target_ticks = config.clock.virtual_ticks } },
            .real_time => .{ .real_time = .{ .start_ns = 0 } },
        },
        policy,
    );
    var stop_reason: StopReason = .virtual_target;
    var terminal_error: ?anyerror = null;
    var synthetic: ?SyntheticProducers = if (enable_synthetic_producers)
        try SyntheticProducers.init(authority, restored, config.world.namespace)
    else
        null;
    var consumers = OperationalConsumers{};
    try consumers.consume(&authority.world);
    std.debug.print(
        "HEADLESS_READY restored={} world_tick={d} clock={s}\n",
        .{ restored, authority.world.tickIndex(), @tagName(config.clock.mode) },
    );

    authority_loop: while (true) {
        if (macos_signals.requested()) {
            stop_reason = .signal;
            break;
        }
        const elapsed = switch (config.clock.mode) {
            .virtual => 0,
            .real_time => elapsedNanoseconds(
                start,
                std.Io.Clock.Timestamp.now(init.io, .awake),
            ),
        };
        const decision = try scheduler.sample(elapsed);
        if (decision.complete) {
            stop_reason = .virtual_target;
            break;
        }
        if (decision.hard_lag) {
            stop_reason = .hard_lag;
            terminal_error = error.HeadlessHardLagLimit;
            break;
        }
        if (decision.granted_ticks == 0) {
            try std.Io.sleep(
                init.io,
                std.Io.Duration.fromNanoseconds(std.time.ns_per_ms),
                .awake,
            );
            continue;
        }
        for (0..decision.granted_ticks) |_| {
            if (macos_signals.requested()) {
                stop_reason = .signal;
                break :authority_loop;
            }
            if (!decision.shed_ingress) {
                if (synthetic) |*producers| try producers.beforeTick(authority);
            }
            _ = try authority.tick(if (decision.shed_ingress) 0 else headless_authority.producer_limits.ingress_capacity);
            if (synthetic) |*producers| try producers.afterTick(authority);
            try consumers.consume(&authority.world);
            try scheduler.recordCompletedTick();
        }
    }

    _ = authority.beginShutdown();
    var drain_ticks: u16 = 0;
    while (!authority.isDrained() and drain_ticks < config.shutdown.drain_tick_budget) : (drain_ticks += 1) {
        _ = try authority.tick(headless_authority.producer_limits.ingress_capacity);
        if (synthetic) |*producers| try producers.afterTick(authority);
        try consumers.consume(&authority.world);
    }
    if (!authority.isDrained()) return error.HeadlessProducerDrainTimeout;
    if (synthetic) |*producers| try producers.unregister(authority);
    if (authority.finishShutdown() != .stopped) {
        return error.HeadlessProducerShutdownInvariant;
    }
    if (terminal_error) |err| return err;
    try consumers.ensureQuiescent();

    const envelope = try authority.saveEnvelope(init.gpa, metadata);
    defer init.gpa.free(envelope);
    const committed_bytes = switch (store.commit(init.io, slot, envelope, .{})) {
        .committed => |info| info.bytes,
        .committed_sync_warning => |warning| {
            std.debug.print(
                "HEADLESS_SAVE status=committed_sync_warning bytes={d} warning={s}\n",
                .{ warning.commit.bytes, @tagName(warning.warning) },
            );
            return error.HeadlessSaveDirectorySyncWarning;
        },
        .not_committed => |failure| {
            std.debug.print(
                "HEADLESS_SAVE status=not_committed reason={s}\n",
                .{@tagName(failure.failure)},
            );
            return error.HeadlessSaveCommitFailed;
        },
    };

    emitDeveloperDiagnosticsBestEffort(&authority.world, init.gpa, true);
    const diagnostics = authority.diagnostics();
    const summary = OperationalSummary{
        .restored = restored,
        .stop_reason = stop_reason,
        .ticks_this_run = scheduler.completed_ticks,
        .world_tick = diagnostics.world.tick_index,
        .save_bytes = committed_bytes,
        .producer_ingress_high_water = diagnostics.producers.ingress.high_water,
        .producer_transaction_high_water = diagnostics.producers.transactions.high_water,
        .producer_delivery_high_water = diagnostics.producers.delivery.high_water,
        .producer_admission_rejections = producerAdmissionRejections(
            diagnostics.producers.rejections,
        ),
        .producer_submitted = if (synthetic) |producers|
            producers.submitted
        else
            .{ 0, 0 },
        .producer_completed = if (synthetic) |producers|
            producers.completed
        else
            .{ 0, 0 },
        .observational_events_consumed = consumers.observational_events,
    };
    writeOperationalSummary(init.io, summary) catch |err| {
        // Authority is already durably committed. Observability loss must not
        // turn a successful commit into a failure/skip disposition that could
        // induce an unsafe retry. stderr is itself best-effort here.
        std.debug.print(
            "HEADLESS_EXIT status=degraded error={s} save=committed\n",
            .{@errorName(err)},
        );
    };
}

fn producerAdmissionRejections(
    rejections: @FieldType(headless_authority.ProducerDiagnostics, "rejections"),
) u64 {
    return rejections.shutting_down +|
        rejections.stale_handle +|
        rejections.invalid_transaction_id +|
        rejections.duplicate_transaction_id +|
        rejections.producer_quota_full +|
        rejections.result_capacity_full +|
        rejections.ingress_full +|
        rejections.transaction_table_full;
}

fn writeOperationalSummary(io: std.Io, summary: OperationalSummary) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    try std.json.Stringify.value(summary, .{}, &stdout_writer.interface);
    try stdout_writer.interface.writeByte('\n');
    try stdout_writer.interface.flush();
}

fn simulationConfig(config: headless_config.ConfigV1) sandbox_contracts.Config {
    return .{
        .namespace = config.world.namespace,
        .max_crates = config.world.max_crates,
        .create_ground = true,
        .character = .{ .max_characters = config.world.max_characters },
        .vehicle = .{ .max_vehicles = config.world.max_vehicles },
        // M3 admits exactly the feature's compile-time 64-NPC cohort above.
        .npc = .{},
    };
}

fn parseInvocation(args: []const []const u8) !?Invocation {
    if (args.len == 2 and std.mem.eql(u8, args[1], "--help")) return null;
    if ((args.len != 5 and args.len != 6) or
        !std.mem.eql(u8, args[1], "--config") or
        !std.mem.eql(u8, args[3], "--content-manifest") or
        (args.len == 6 and !std.mem.eql(u8, args[5], "--synthetic-producers")))
    {
        return error.InvalidHeadlessInvocation;
    }
    if (!std.fs.path.isAbsolute(args[2]) or !std.fs.path.isAbsolute(args[4])) {
        return error.HeadlessPathsMustBeAbsolute;
    }
    return .{
        .config_path = args[2],
        .content_manifest_path = args[4],
        .synthetic_producers = args.len == 6,
    };
}

fn writeUsage(io: std.Io) !void {
    var buffer: [512]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buffer);
    try writer.interface.writeAll(
        "usage: incinerator_headless --config /absolute/config.json " ++
            "--content-manifest /absolute/content.json [--synthetic-producers]\n",
    );
    try writer.interface.flush();
}

fn readBoundedFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    maximum: usize,
) ![]u8 {
    const file = try std.Io.Dir.openFileAbsolute(io, path, .{
        .allow_directory = false,
        .follow_symlinks = false,
    });
    defer file.close(io);
    var read_buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    const read_limit = std.math.add(usize, maximum, 1) catch
        return error.HeadlessInputSizeOutOfRange;
    const bytes = reader.interface.allocRemaining(
        allocator,
        .limited(read_limit),
    ) catch |err| switch (err) {
        error.StreamTooLong => return error.HeadlessInputSizeOutOfRange,
        else => |other| return other,
    };
    if (bytes.len == 0 or bytes.len > maximum) {
        allocator.free(bytes);
        return error.HeadlessInputSizeOutOfRange;
    }
    return bytes;
}

test "bounded product reads admit exact maximum and reject one extra byte" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();

    const maximum = headless_content.max_manifest_bytes;
    const exact = [_]u8{'x'} ** maximum;
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "exact.json",
        .data = &exact,
    });
    const oversized = [_]u8{'x'} ** (maximum + 1);
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "oversized.json",
        .data = &oversized,
    });

    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try temporary.dir.realPath(std.testing.io, &root_buffer);
    var exact_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const exact_path = try std.fmt.bufPrint(
        &exact_path_buffer,
        "{s}/exact.json",
        .{root_buffer[0..root_len]},
    );
    const bytes = try readBoundedFile(
        std.testing.io,
        std.testing.allocator,
        exact_path,
        maximum,
    );
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqual(maximum, bytes.len);

    var oversized_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const oversized_path = try std.fmt.bufPrint(
        &oversized_path_buffer,
        "{s}/oversized.json",
        .{root_buffer[0..root_len]},
    );
    try std.testing.expectError(
        error.HeadlessInputSizeOutOfRange,
        readBoundedFile(
            std.testing.io,
            std.testing.allocator,
            oversized_path,
            maximum,
        ),
    );
}

test "operational producer rejection summary uses persistent global counters" {
    const Rejections = @FieldType(headless_authority.ProducerDiagnostics, "rejections");
    var rejections = Rejections{};
    rejections.shutting_down = 1;
    rejections.stale_handle = 2;
    rejections.invalid_transaction_id = 3;
    rejections.duplicate_transaction_id = 4;
    rejections.producer_quota_full = 5;
    rejections.result_capacity_full = 6;
    rejections.ingress_full = 7;
    rejections.transaction_table_full = 8;
    // Registration and terminal port rejection are distinct from submit
    // admission, and therefore are intentionally not part of this field.
    rejections.registration = 100;
    rejections.terminal_submission_rejected = 100;
    try std.testing.expectEqual(
        @as(u64, 36),
        producerAdmissionRejections(rejections),
    );
}

fn elapsedNanoseconds(
    start: std.Io.Clock.Timestamp,
    end: std.Io.Clock.Timestamp,
) u64 {
    const value = start.durationTo(end).raw.nanoseconds;
    if (value <= 0) return 0;
    return std.math.cast(u64, value) orelse std.math.maxInt(u64);
}

fn runSandbox(world: *simulation.Simulation) !void {
    try world.submit(.{ .spawn = .{
        .request_id = 1,
        .pose = .{ .position = .{ 0, 8, 0 } },
    } });
    try world.submitCharacter(.{ .spawn = .{
        .request_id = 2,
        .position = .{ 0, 0, 2 },
    } });
    // Exercise the NPC command surface even before streamed navigation is
    // present. Inactive content is an expected bounded domain rejection, not
    // a silent omission or infrastructure fault in the SDL-free host.
    try world.submitNpc(.{ .spawn = .{
        .request_id = 3,
        .position = .{ -5, 0, 5 },
        .facing_yaw = 0,
        .anchor = .{ .coord = sandbox_contracts.navigation_west_coord, .index = 0 },
        .hostile_to_players = true,
        .goal = .hold,
    } });
    try world.tick();

    const outcome = world.pollOutcome() orelse return error.SpawnOutcomeMissing;
    const crate_id = switch (outcome) {
        .spawned => |spawned| spawned.id,
        else => return error.UnexpectedOutcome,
    };
    const character_outcome = world.pollCharacterOutcome() orelse
        return error.CharacterSpawnOutcomeMissing;
    const character_id = switch (character_outcome) {
        .spawned => |spawned| spawned.id,
        else => return error.UnexpectedCharacterOutcome,
    };
    const npc_outcome = world.pollNpcOutcome() orelse return error.NpcOutcomeMissing;
    switch (npc_outcome) {
        .rejected => |rejected| if (rejected.reason != .start_district_inactive) {
            return error.UnexpectedNpcOutcome;
        },
        else => return error.UnexpectedNpcOutcome,
    }
    if (world.pollNpcOutcome() != null or world.pollNpcEvent() != null) {
        return error.ExtraNpcOutput;
    }
    for (0..239) |_| {
        try world.submitCharacter(.{ .actions = .{
            .id = character_id,
            .move = .{ 1, 0 },
            .facing_yaw = 0,
        } });
        try world.tick();
    }

    const crate = try world.crate(crate_id);
    const character = try world.character(character_id);
    std.debug.print(
        "headless crate {d}:{d} at ({d:.3}, {d:.3}, {d:.3}); " ++
            "character {d}:{d} at ({d:.3}, {d:.3}, {d:.3}) after {d} ticks\n",
        .{
            crate_id.namespace,
            crate_id.local,
            crate.state.pose.position[0],
            crate.state.pose.position[1],
            crate.state.pose.position[2],
            character_id.namespace,
            character_id.local,
            character.position[0],
            character.position[1],
            character.position[2],
            world.tickIndex(),
        },
    );

    try world.submit(.{ .despawn = .{ .id = crate_id } });
    try world.submitCharacter(.{ .despawn = .{ .id = character_id } });
    try world.tick();
    _ = world.pollOutcome() orelse return error.DespawnOutcomeMissing;
    _ = world.pollCharacterOutcome() orelse return error.CharacterDespawnOutcomeMissing;
    if (world.entityCount() != 0 or world.npcCount() != 0 or world.bodyCount() != 1) {
        return error.HeadlessCleanupMismatch;
    }
}

/// Emit the same immutable snapshot and chronological journal contract on
/// both successful shutdown and failure. A caller handling another error may
/// ignore an emission failure so the original authoritative error is retained.
fn emitDeveloperDiagnostics(world: *simulation.Simulation) !void {
    return emitDeveloperDiagnosticsWithAllocator(world, std.heap.page_allocator);
}

fn emitDeveloperDiagnosticsBestEffort(
    world: *simulation.Simulation,
    allocator: std.mem.Allocator,
    report_failure: bool,
) void {
    emitDeveloperDiagnosticsWithAllocator(world, allocator) catch |err| {
        // Allocation-free visibility without converting a successful
        // authoritative run into a diagnostics failure.
        if (report_failure) {
            std.debug.print(
                "headless diagnostics emission failed after successful authority: {s}\n",
                .{@errorName(err)},
            );
        }
    };
}

fn emitDeveloperDiagnosticsWithAllocator(
    world: *simulation.Simulation,
    allocator: std.mem.Allocator,
) !void {
    const snapshot = developerSnapshot(world);
    const diagnostic_text = try developer_diagnostics.formatTextAlloc(
        allocator,
        snapshot,
    );
    defer allocator.free(diagnostic_text);
    var entry_storage: [engine.runtime.DiagnosticJournal.capacity]engine.diagnostic_contracts.Entry = undefined;
    const entries = world.diagnosticJournal().copyChronological(&entry_storage);
    const json = try developer_diagnostics.formatJsonAlloc(
        allocator,
        DeveloperExport{ .snapshot = snapshot, .entries = entries },
    );
    defer allocator.free(json);
    std.debug.print("HEADLESS_DIAGNOSTICS {s}\n", .{diagnostic_text});
    std.debug.print("HEADLESS_DIAGNOSTICS_JSON {s}\n", .{json});
}

test "headless host exports the shared typed diagnostics as text and JSON" {
    var world = try simulation.Simulation.init(std.testing.allocator, .{
        .namespace = 760,
    });
    defer world.deinit();
    const admitted = world.recordDiagnostic(.{
        .severity = .info,
        .category = .feature,
        .code = 0x0005_0001,
        .tick_index = world.tickIndex(),
        .thread_role = .simulation,
        .correlation_id = 77,
    });
    try std.testing.expect(admitted.accepted);

    const snapshot = developerSnapshot(&world);
    try std.testing.expect(snapshot.host_time == null);
    const text_value = try developer_diagnostics.formatTextAlloc(
        std.testing.allocator,
        snapshot,
    );
    defer std.testing.allocator.free(text_value);
    try std.testing.expect(std.mem.indexOf(u8, text_value, "diagnostics_v5") != null);
    try std.testing.expect(std.mem.indexOf(u8, text_value, "tick=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, text_value, "journal=1/256") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        text_value,
        "district_streams=absent",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        text_value,
        "character_virtual=0/128 feature_owned=0 consistent=true",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        text_value,
        "npc active=0 waiting=0 dormant=0 controllers=0 transfers=0 suspended=0 resumed=0",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        text_value,
        "npc_commands=0/128 peak=0 rejected=0",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        text_value,
        "npc_outcomes=0/128 peak=0 rejected=0",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        text_value,
        "npc_events=0/256 peak=0 rejected=0",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        text_value,
        "npc_event_drops=state:0 owner:0 goal:0 total:0",
    ) != null);

    var entries_storage: [engine.runtime.DiagnosticJournal.capacity]engine.diagnostic_contracts.Entry = undefined;
    const entries = world.diagnosticJournal().copyChronological(&entries_storage);
    const export_value = DeveloperExport{ .snapshot = snapshot, .entries = entries };
    const json = try developer_diagnostics.formatJsonAlloc(
        std.testing.allocator,
        export_value,
    );
    defer std.testing.allocator.free(json);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(
        @as(i64, developer_diagnostics.schema_version),
        parsed.value.object.get("schema").?.integer,
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        parsed.value.object.get("entries").?.array.items.len,
    );
    try std.testing.expectEqual(
        @as(i64, 77),
        parsed.value.object.get("entries").?.array.items[0].object
            .get("correlation_id").?.integer,
    );
    try std.testing.expect(parsed.value.object.get("snapshot").?.object
        .get("host_time").? == .null);
    try std.testing.expect(parsed.value.object.get("snapshot").?.object
        .get("district_streams").? == .null);
    const snapshot_json = parsed.value.object.get("snapshot").?.object;
    try std.testing.expectEqual(
        @as(i64, developer_diagnostics.schema_version),
        snapshot_json.get("schema").?.integer,
    );
    const character_controllers = snapshot_json.get("simulation").?.object
        .get("character_controllers").?.object;
    try std.testing.expectEqual(
        @as(i64, 0),
        character_controllers.get("native_used").?.integer,
    );
    try std.testing.expectEqual(
        @as(i64, 128),
        character_controllers.get("native_capacity").?.integer,
    );
    try std.testing.expectEqual(
        @as(i64, 0),
        character_controllers.get("feature_owned").?.integer,
    );
    try std.testing.expect(character_controllers.get("authority_consistent").?.bool);
    const npc = snapshot_json.get("simulation").?.object.get("npc").?.object;
    try std.testing.expectEqual(@as(i64, 0), npc.get("active_count").?.integer);
    try std.testing.expectEqual(@as(i64, 0), npc.get("waiting_count").?.integer);
    try std.testing.expectEqual(@as(i64, 0), npc.get("dormant_count").?.integer);
    try std.testing.expectEqual(@as(i64, 0), npc.get("controller_count").?.integer);
    try std.testing.expectEqual(@as(i64, 0), npc.get("transfers").?.integer);
    try std.testing.expectEqual(
        @as(i64, 0),
        npc.get("controllers_suspended").?.integer,
    );
    try std.testing.expectEqual(
        @as(i64, 0),
        npc.get("controllers_resumed").?.integer,
    );
    const npc_commands = npc.get("commands").?.object;
    try std.testing.expectEqual(@as(i64, 0), npc_commands.get("occupancy").?.integer);
    try std.testing.expectEqual(@as(i64, 0), npc_commands.get("high_water").?.integer);
    try std.testing.expectEqual(@as(i64, 128), npc_commands.get("capacity").?.integer);
    try std.testing.expectEqual(@as(i64, 0), npc_commands.get("rejected").?.integer);
    const npc_outcomes = npc.get("outcomes").?.object;
    try std.testing.expectEqual(@as(i64, 0), npc_outcomes.get("occupancy").?.integer);
    try std.testing.expectEqual(@as(i64, 0), npc_outcomes.get("high_water").?.integer);
    try std.testing.expectEqual(@as(i64, 128), npc_outcomes.get("capacity").?.integer);
    try std.testing.expectEqual(@as(i64, 0), npc_outcomes.get("rejected").?.integer);
    const npc_events = npc.get("events").?.object;
    try std.testing.expectEqual(@as(i64, 0), npc_events.get("occupancy").?.integer);
    try std.testing.expectEqual(@as(i64, 0), npc_events.get("high_water").?.integer);
    try std.testing.expectEqual(@as(i64, 256), npc_events.get("capacity").?.integer);
    try std.testing.expectEqual(@as(i64, 0), npc_events.get("rejected").?.integer);
    const event_drops = npc.get("event_drops").?.object;
    try std.testing.expectEqual(@as(i64, 0), event_drops.get("state_changed").?.integer);
    try std.testing.expectEqual(@as(i64, 0), event_drops.get("owner_transferred").?.integer);
    try std.testing.expectEqual(@as(i64, 0), event_drops.get("goal_reached").?.integer);
}

test "successful headless authority is not failed by diagnostic allocation loss" {
    var world = try simulation.Simulation.init(std.testing.allocator, .{
        .namespace = 761,
    });
    defer world.deinit();
    try world.tick();
    const completed_tick = world.tickIndex();

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    failing.fail_index = 0;
    emitDeveloperDiagnosticsBestEffort(&world, failing.allocator(), false);

    try std.testing.expectEqual(completed_tick, world.tickIndex());
    try world.tick();
    try std.testing.expectEqual(completed_tick + 1, world.tickIndex());
}

test "real Jolt lifecycle saves destroys restores and destroys" {
    const allocator = std.testing.allocator;
    var saved: []u8 = undefined;
    var stable_id: engine.PersistentId = undefined;
    var saved_position: [3]f32 = undefined;
    var saved_linear_velocity: [3]f32 = undefined;
    var saved_angular_velocity: [3]f32 = undefined;
    {
        var world = try simulation.Simulation.init(allocator, .{
            .namespace = 77,
        });
        defer world.deinit();
        try std.testing.expectEqual(@as(u32, 1), world.bodyCount());

        try world.submit(.{ .spawn = .{
            .request_id = 41,
            .pose = .{ .position = .{ 0.25, 12, -0.5 } },
            .velocity = .{ .angular = .{ 0.2, 0.4, 0.1 } },
        } });
        for (0..30) |_| try world.tick();
        stable_id = switch (world.pollOutcome().?) {
            .spawned => |spawned| spawned.id,
            else => return error.UnexpectedOutcome,
        };
        try std.testing.expectEqual(@as(usize, 1), world.crateCount());
        try std.testing.expectEqual(@as(usize, 1), world.entityCount());
        try std.testing.expectEqual(@as(u32, 2), world.bodyCount());
        const saved_view = try world.crate(stable_id);
        saved_position = saved_view.state.pose.position;
        saved_linear_velocity = saved_view.state.velocity.linear;
        saved_angular_velocity = saved_view.state.velocity.angular;

        saved = try world.save(allocator);
        const saved_again = try world.save(allocator);
        defer allocator.free(saved_again);
        try std.testing.expectEqualSlices(u8, saved, saved_again);

        try world.submit(.{ .despawn = .{ .id = stable_id } });
        try world.tick();
        _ = world.pollOutcome() orelse return error.DespawnOutcomeMissing;
        try std.testing.expectEqual(@as(usize, 0), world.crateCount());
        try std.testing.expectEqual(@as(usize, 0), world.entityCount());
        try std.testing.expectEqual(@as(u32, 1), world.bodyCount());
    }
    defer allocator.free(saved);

    {
        var restored = try simulation.Simulation.fromSnapshot(allocator, saved, .{});
        defer restored.deinit();
        try std.testing.expectEqual(@as(usize, 1), restored.crateCount());
        try std.testing.expectEqual(@as(u32, 2), restored.bodyCount());
        const restored_view = try restored.crate(stable_id);
        for (saved_position, restored_view.state.pose.position) |expected, actual| {
            try std.testing.expectApproxEqAbs(expected, actual, 0.0001);
        }
        for (saved_linear_velocity, restored_view.state.velocity.linear) |expected, actual| {
            try std.testing.expectApproxEqAbs(expected, actual, 0.0001);
        }
        for (saved_angular_velocity, restored_view.state.velocity.angular) |expected, actual| {
            try std.testing.expectApproxEqAbs(expected, actual, 0.0001);
        }
        const restored_previous = (try restored.presentation(0))[0].pose;
        const restored_current = (try restored.presentation(1))[0].pose;
        try std.testing.expectEqual(restored_previous.position, restored_current.position);
        try std.testing.expectEqual(restored_previous.rotation, restored_current.rotation);

        try restored.submit(.{ .spawn = .{
            .request_id = 99,
            .pose = .{ .position = .{ 2, 4, 0 } },
        } });
        try restored.tick();
        const next_id = switch (restored.pollOutcome().?) {
            .spawned => |spawned| spawned.id,
            else => return error.UnexpectedOutcome,
        };
        try std.testing.expectEqual(@as(u64, 2), next_id.local);
        try restored.submit(.{ .despawn = .{ .id = stable_id } });
        try restored.submit(.{ .despawn = .{ .id = next_id } });
        try restored.tick();
        try std.testing.expectEqual(@as(usize, 0), restored.crateCount());
        try std.testing.expectEqual(@as(u32, 1), restored.bodyCount());
    }
}

test "V11 snapshot composes crate character and empty NPC records under one runtime envelope" {
    const allocator = std.testing.allocator;
    var saved: []u8 = undefined;
    var crate_id: engine.PersistentId = undefined;
    var character_id: engine.PersistentId = undefined;
    var character_position: [3]f32 = undefined;
    {
        var world = try simulation.Simulation.init(allocator, .{ .namespace = 706 });
        defer world.deinit();
        try world.submit(.{ .spawn = .{
            .request_id = 1,
            .pose = .{ .position = .{ 2, 6, 0 } },
        } });
        try world.submitCharacter(.{ .spawn = .{
            .request_id = 2,
            .position = .{ 0, 0, 2 },
            .facing_yaw = 0.25,
        } });
        try world.tick();
        crate_id = world.pollOutcome().?.spawned.id;
        character_id = world.pollCharacterOutcome().?.spawned.id;
        while (world.pollCharacterOutcome() != null) {}
        while (world.pollCharacterEvent() != null) {}
        for (0..30) |_| {
            try world.submitCharacter(.{ .actions = .{
                .id = character_id,
                .move = .{ 1, 0 },
                .facing_yaw = 0.25,
            } });
            try world.tick();
        }
        character_position = (try world.character(character_id)).position;
        saved = try world.save(allocator);
        try std.testing.expectEqual(@as(usize, 2), world.entityCount());
        try std.testing.expectEqual(@as(u32, 2), world.bodyCount());
    }
    defer allocator.free(saved);

    var restored = try simulation.Simulation.fromSnapshot(allocator, saved, .{});
    defer restored.deinit();
    try std.testing.expectEqual(@as(usize, 1), restored.crateCount());
    try std.testing.expectEqual(@as(usize, 1), restored.characterCount());
    try std.testing.expectEqual(@as(usize, 2), restored.entityCount());
    try std.testing.expectEqual(@as(u32, 2), restored.bodyCount());
    const restored_character = try restored.character(character_id);
    for (character_position, restored_character.position) |expected, actual| {
        try std.testing.expectApproxEqAbs(expected, actual, 0.0001);
    }
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), restored_character.facing_yaw, 0.0001);
    const character_start = (try restored.characterPresentation(0))[0].pose;
    const character_end = (try restored.characterPresentation(1))[0].pose;
    try std.testing.expectEqual(character_start.position, character_end.position);

    const saved_again = try restored.save(allocator);
    defer allocator.free(saved_again);
    try std.testing.expectEqualSlices(u8, saved, saved_again);

    try restored.submit(.{ .despawn = .{ .id = crate_id } });
    try restored.submitCharacter(.{ .despawn = .{ .id = character_id } });
    try restored.tick();
    try std.testing.expectEqual(@as(usize, 0), restored.entityCount());
    try std.testing.expectEqual(@as(u32, 1), restored.bodyCount());
}

test "repeated crate lifecycle leaves only the host-owned ground" {
    var world = try simulation.Simulation.init(std.testing.allocator, .{
        .namespace = 88,
    });
    defer world.deinit();

    var previous_local: u64 = 0;
    for (0..128) |index| {
        try world.submit(.{ .spawn = .{
            .request_id = index,
            .pose = .{ .position = .{ 0, 3, 0 } },
        } });
        try world.tick();
        const id = switch (world.pollOutcome().?) {
            .spawned => |spawned| spawned.id,
            else => return error.UnexpectedOutcome,
        };
        try std.testing.expect(id.local > previous_local);
        previous_local = id.local;
        try world.submit(.{ .despawn = .{ .id = id } });
        try world.tick();
        _ = world.pollOutcome().?;
        try std.testing.expectEqual(@as(usize, 0), world.entityCount());
        try std.testing.expectEqual(@as(u32, 1), world.bodyCount());
    }
}

test "a stale domain command is rejected without faulting or aliasing" {
    var world = try simulation.Simulation.init(std.testing.allocator, .{
        .namespace = 89,
    });
    defer world.deinit();

    try world.submit(.{ .spawn = .{
        .request_id = 1,
        .pose = .{ .position = .{ 0, 3, 0 } },
    } });
    try world.tick();
    const stale_id = switch (world.pollOutcome().?) {
        .spawned => |spawned| spawned.id,
        else => return error.UnexpectedOutcome,
    };
    try world.submit(.{ .despawn = .{ .id = stale_id } });
    try world.tick();
    _ = world.pollOutcome().?;

    try world.submit(.{ .despawn = .{ .id = stale_id } });
    try world.submit(.{ .spawn = .{
        .request_id = 2,
        .pose = .{ .position = .{ 1, 3, 0 } },
    } });
    try world.tick();
    switch (world.pollOutcome().?) {
        .rejected => |rejected| {
            try std.testing.expectEqual(crate_contract.CommandKind.despawn, rejected.command);
            try std.testing.expectEqual(
                crate_contract.RejectionReason.crate_not_found,
                rejected.reason,
            );
        },
        else => return error.UnexpectedOutcome,
    }
    const replacement_id = switch (world.pollOutcome().?) {
        .spawned => |spawned| spawned.id,
        else => return error.UnexpectedOutcome,
    };
    try std.testing.expect(replacement_id.local > stale_id.local);
    try world.tick();
    try world.submit(.{ .despawn = .{ .id = replacement_id } });
    try world.tick();
    try std.testing.expectEqual(@as(usize, 0), world.crateCount());
}

const TimelineSample = struct {
    tick: u64,
    position: [3]f32,
    rotation: [4]f32,
    linear_velocity: [3]f32,
};

const timeline_tolerance: f32 = 0.00001;

fn captureTimelineSample(
    world: *simulation.Simulation,
    id: engine.PersistentId,
) !TimelineSample {
    const view = try world.crate(id);
    return .{
        .tick = world.tickIndex(),
        .position = view.state.pose.position,
        .rotation = view.state.pose.rotation,
        .linear_velocity = view.state.velocity.linear,
    };
}

fn runTimeline(allocator: std.mem.Allocator) ![4]TimelineSample {
    const crate_records = [_]crate_contract.CrateV1{.{
        .id = .{ .namespace = 99, .local = 1 },
        .half_extents = .{ 0.5, 0.75, 0.25 },
        .pose = .{
            .position = .{ 1, 6, -2 },
            .rotation = .{ 0, 0.25881904, 0, 0.9659258 },
        },
        .linear_velocity = .{ 0.5, 0.25, -0.25 },
        .angular_velocity = .{ 0.1, 0.2, 0.3 },
    }};
    const initial = simulation_snapshot.SnapshotV14{
        .schema_version = sandbox_contracts.snapshot_schema,
        .completed_ticks = 10,
        .fixed_delta_seconds = 1.0 / 120.0,
        .namespace = 99,
        .next_local_id = 2,
        .character_config = character_contract.CharacterConfigV1.fromConfig(.{}),
        .vehicle_config = vehicle_contract.VehicleConfigV1.fromConfig(.{}),
        .interaction_config = interaction_contract.InteractionConfigV1.fromConfig(.{}),
        .npc_config = npc_contract.NpcConfigV1.fromConfig(.{}),
        .npc_encounter_config = simulation_snapshot.NpcEncounterConfigV1.fromConfig(.{}),
        .authored_population = false,
        .navigation_gates = simulation_snapshot.initial_navigation_gates,
        .crates = &crate_records,
        .characters = &.{},
        .vehicles = &.{},
        .districts = &.{},
        .interactions = &.{},
        .npcs = &.{},
        .npc_encounters = &.{},
        .population = null,
    };
    const initial_v7 = try std.json.Stringify.valueAlloc(allocator, initial, .{});
    defer allocator.free(initial_v7);
    var world = try simulation.Simulation.fromSnapshot(allocator, initial_v7, .{});
    defer world.deinit();
    const id = engine.PersistentId{ .namespace = 99, .local = 1 };
    var samples: [4]TimelineSample = undefined;
    samples[0] = try captureTimelineSample(&world, id);
    for (0..5) |_| try world.tick();
    samples[1] = try captureTimelineSample(&world, id);
    try world.submit(.{ .impulse = .{ .id = id, .impulse = .{ 0, 1000, 0 } } });
    try world.tick();
    switch (world.pollOutcome() orelse return error.ImpulseOutcomeMissing) {
        .impulse_applied => |applied_id| try std.testing.expectEqual(id, applied_id),
        else => return error.UnexpectedOutcome,
    }
    samples[2] = try captureTimelineSample(&world, id);
    try std.testing.expect(
        samples[2].linear_velocity[1] > samples[1].linear_velocity[1],
    );
    for (0..20) |_| try world.tick();
    samples[3] = try captureTimelineSample(&world, id);
    return samples;
}

test "the same V7 command timeline repeats at multiple samples on one target" {
    const first = try runTimeline(std.testing.allocator);
    const second = try runTimeline(std.testing.allocator);
    try std.testing.expectEqual([4]u64{ 10, 15, 16, 36 }, .{
        first[0].tick,
        first[1].tick,
        first[2].tick,
        first[3].tick,
    });
    for (first, second) |expected, actual| {
        try std.testing.expectEqual(expected.tick, actual.tick);
        for (expected.position, actual.position) |a, b| {
            try std.testing.expectApproxEqAbs(a, b, timeline_tolerance);
        }
        for (expected.rotation, actual.rotation) |a, b| {
            try std.testing.expectApproxEqAbs(a, b, timeline_tolerance);
        }
        for (expected.linear_velocity, actual.linear_velocity) |a, b| {
            try std.testing.expectApproxEqAbs(a, b, timeline_tolerance);
        }
    }
}

const CharacterTimelineSample = struct {
    tick: u64,
    position: [3]f32,
    velocity: [3]f32,
    facing_yaw: f32,
    ground_state: engine.physics.GroundState,
};

fn runCharacterTimeline() ![4]CharacterTimelineSample {
    var world = try simulation.Simulation.init(std.testing.allocator, .{
        .namespace = 100,
        .block = .{
            .position = .{ 0, 1, -5 },
            .half_extents = .{ 2, 1, 0.5 },
        },
    });
    defer world.deinit();
    try world.submitCharacter(.{ .spawn = .{
        .request_id = 1,
        .position = .{ 0, 0, 4 },
    } });
    try world.tick();
    const id = world.pollCharacterOutcome().?.spawned.id;
    while (world.pollCharacterOutcome() != null) {}
    while (world.pollCharacterEvent() != null) {}

    var samples: [4]CharacterTimelineSample = undefined;
    samples[0] = characterTimelineSample(&world, id);
    for (0..239) |index| {
        try world.submitCharacter(.{ .actions = .{
            .id = id,
            .move = if (index < 160) .{ 0, 1 } else .{ 1, 0 },
            .facing_yaw = if (index < 160) 0 else std.math.pi / 2.0,
            .jump_pressed = index == 59,
        } });
        try world.tick();
        while (world.pollCharacterOutcome() != null) {}
        while (world.pollCharacterEvent() != null) {}
        if (index == 58) samples[1] = characterTimelineSample(&world, id);
        if (index == 118) samples[2] = characterTimelineSample(&world, id);
    }
    samples[3] = characterTimelineSample(&world, id);
    return samples;
}

fn characterTimelineSample(
    world: *simulation.Simulation,
    id: engine.PersistentId,
) CharacterTimelineSample {
    const view = world.character(id) catch unreachable;
    return .{
        .tick = world.tickIndex(),
        .position = view.position,
        .velocity = view.velocity,
        .facing_yaw = view.facing_yaw,
        .ground_state = view.ground_state,
    };
}

test "the same character action stream repeats on one target" {
    const first = try runCharacterTimeline();
    const second = try runCharacterTimeline();
    try std.testing.expectEqual([4]u64{ 1, 60, 120, 240 }, .{
        first[0].tick,
        first[1].tick,
        first[2].tick,
        first[3].tick,
    });
    for (first, second) |expected, actual| {
        try std.testing.expectEqual(expected.tick, actual.tick);
        for (expected.position, actual.position) |a, b| {
            try std.testing.expectApproxEqAbs(a, b, timeline_tolerance);
        }
        for (expected.velocity, actual.velocity) |a, b| {
            try std.testing.expectApproxEqAbs(a, b, timeline_tolerance);
        }
        try std.testing.expectApproxEqAbs(
            expected.facing_yaw,
            actual.facing_yaw,
            timeline_tolerance,
        );
        try std.testing.expectEqual(expected.ground_state, actual.ground_state);
    }
}

test "presentation interpolates without writing authoritative state" {
    var world = try simulation.Simulation.init(std.testing.allocator, .{
        .namespace = 123,
    });
    defer world.deinit();
    try world.submit(.{ .spawn = .{
        .request_id = 1,
        .pose = .{ .position = .{ 0, 5, 0 } },
    } });
    try world.tick();
    const id = switch (world.pollOutcome().?) {
        .spawned => |spawned| spawned.id,
        else => return error.UnexpectedOutcome,
    };
    const current_before = (try world.crate(id)).state.pose;
    const clamped_start = (try world.presentation(-1))[0].pose;
    const start = (try world.presentation(0))[0].pose;
    const midpoint = (try world.presentation(0.5))[0].pose;
    const end = (try world.presentation(1))[0].pose;
    const clamped = (try world.presentation(2))[0].pose;
    const current_after = (try world.crate(id)).state.pose;

    try std.testing.expectApproxEqAbs(current_before.position[1], end.position[1], 0.00001);
    try std.testing.expectEqual(start.position, clamped_start.position);
    for (start.position, midpoint.position, end.position) |previous, interpolated, current| {
        try std.testing.expectApproxEqAbs(
            (previous + current) * 0.5,
            interpolated,
            0.00001,
        );
    }
    try std.testing.expectApproxEqAbs(end.position[1], clamped.position[1], 0.00001);
    try std.testing.expect(midpoint.position[1] <= start.position[1]);
    try std.testing.expect(midpoint.position[1] >= end.position[1]);
    try std.testing.expectEqual(current_before.position, current_after.position);
    try std.testing.expectEqual(current_before.rotation, current_after.rotation);
}

test "empty presentation still rejects non-finite alpha" {
    var world = try simulation.Simulation.init(std.testing.allocator, .{
        .namespace = 124,
    });
    defer world.deinit();
    try std.testing.expectError(
        error.InvalidInterpolationAlpha,
        world.presentation(std.math.nan(f32)),
    );
}

test "live-world restore fails cleanly and leaves the caller usable" {
    var world = try simulation.Simulation.init(std.testing.allocator, .{
        .namespace = 125,
    });
    defer world.deinit();
    const saved = try world.save(std.testing.allocator);
    defer std.testing.allocator.free(saved);

    try std.testing.expectError(
        error.EngineWorldAlreadyLive,
        simulation.Simulation.fromSnapshot(std.testing.allocator, saved, .{}),
    );
    try world.tick();
    try std.testing.expectEqual(@as(u64, 1), world.tickIndex());
}

test "multi-record V7 save is sorted and byte-stable across fresh restore" {
    const allocator = std.testing.allocator;
    const crate_records = [_]crate_contract.CrateV1{
        .{
            .id = .{ .namespace = 700, .local = 7 },
            .half_extents = .{ 0.25, 0.5, 0.75 },
            .pose = .{
                .position = .{ 3, 8, -2 },
                .rotation = .{ 0, 0.38268343, 0, 0.9238795 },
            },
            .linear_velocity = .{ 1.25, -2.5, 0.5 },
            .angular_velocity = .{ 0.1, 0.2, 0.3 },
        },
        .{
            .id = .{ .namespace = 700, .local = 2 },
            .half_extents = .{ 1, 0.75, 0.5 },
            .pose = .{
                .position = .{ -4, 6, 1 },
                .rotation = .{ 0.25881904, 0, 0, 0.9659258 },
            },
            .linear_velocity = .{ -0.75, 1.5, 2.25 },
            .angular_velocity = .{ -0.3, 0.4, -0.2 },
        },
    };
    const snapshot = simulation_snapshot.SnapshotV14{
        .schema_version = sandbox_contracts.snapshot_schema,
        .completed_ticks = 17,
        .fixed_delta_seconds = 1.0 / 120.0,
        .namespace = 700,
        .next_local_id = 42,
        .character_config = character_contract.CharacterConfigV1.fromConfig(.{}),
        .vehicle_config = vehicle_contract.VehicleConfigV1.fromConfig(.{}),
        .interaction_config = interaction_contract.InteractionConfigV1.fromConfig(.{}),
        .npc_config = npc_contract.NpcConfigV1.fromConfig(.{}),
        .npc_encounter_config = simulation_snapshot.NpcEncounterConfigV1.fromConfig(.{}),
        .authored_population = false,
        .navigation_gates = simulation_snapshot.initial_navigation_gates,
        .crates = &crate_records,
        .characters = &.{},
        .vehicles = &.{},
        .districts = &.{},
        .interactions = &.{},
        .npcs = &.{},
        .npc_encounters = &.{},
        .population = null,
    };
    const unsorted = try std.json.Stringify.valueAlloc(allocator, snapshot, .{});
    defer allocator.free(unsorted);

    var first_save: []u8 = undefined;
    {
        var world = try simulation.Simulation.fromSnapshot(allocator, unsorted, .{});
        defer world.deinit();
        try std.testing.expectEqual(@as(u64, 17), world.tickIndex());
        try std.testing.expectEqual(@as(usize, 2), world.crateCount());
        first_save = try world.save(allocator);
    }
    defer allocator.free(first_save);

    var parsed = try std.json.parseFromSlice(
        struct {
            schema_version: u16,
            completed_ticks: u64,
            fixed_delta_seconds: f32,
            namespace: u64,
            next_local_id: u64,
            crates: []const struct { id: engine.PersistentId },
            characters: []const struct { id: engine.PersistentId },
        },
        allocator,
        first_save,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();
    try std.testing.expectEqual(sandbox_contracts.snapshot_schema, parsed.value.schema_version);
    try std.testing.expectEqual(@as(u64, 17), parsed.value.completed_ticks);
    try std.testing.expectEqual(@as(u64, 700), parsed.value.namespace);
    try std.testing.expectEqual(@as(u64, 42), parsed.value.next_local_id);
    try std.testing.expectEqual(@as(usize, 2), parsed.value.crates.len);
    try std.testing.expectEqual(@as(u64, 2), parsed.value.crates[0].id.local);
    try std.testing.expectEqual(@as(u64, 7), parsed.value.crates[1].id.local);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.characters.len);

    {
        var restored = try simulation.Simulation.fromSnapshot(allocator, first_save, .{});
        defer restored.deinit();
        const second_save = try restored.save(allocator);
        defer allocator.free(second_save);
        try std.testing.expectEqualSlices(u8, first_save, second_save);

        try restored.submit(.{ .spawn = .{
            .request_id = 99,
            .pose = .{ .position = .{ 0, 20, 0 } },
        } });
        try restored.tick();
        const allocated = switch (restored.pollOutcome().?) {
            .spawned => |spawned| spawned.id,
            else => return error.UnexpectedOutcome,
        };
        try std.testing.expectEqual(engine.PersistentId{
            .namespace = 700,
            .local = 42,
        }, allocated);
    }
}

test "failed fresh loads do not mutate a live simulation" {
    const allocator = std.testing.allocator;
    var world = try simulation.Simulation.init(allocator, .{ .namespace = 701 });
    defer world.deinit();
    try world.submit(.{ .spawn = .{
        .request_id = 1,
        .pose = .{ .position = .{ 0, 5, 0 } },
    } });
    try world.tick();
    const id = switch (world.pollOutcome().?) {
        .spawned => |spawned| spawned.id,
        else => return error.UnexpectedOutcome,
    };
    const before = try world.crate(id);
    const tick_before = world.tickIndex();

    try std.testing.expectError(
        error.UnexpectedEndOfInput,
        simulation.Simulation.fromSnapshot(allocator, "{", .{}),
    );
    const oversized = try allocator.alloc(u8, 8 * 1024 * 1024 + 1);
    defer allocator.free(oversized);
    @memset(oversized, ' ');
    try std.testing.expectError(
        error.SnapshotTooLarge,
        simulation.Simulation.fromSnapshot(allocator, oversized, .{}),
    );
    const empty_snapshot = simulation_snapshot.SnapshotV14{
        .schema_version = sandbox_contracts.snapshot_schema,
        .completed_ticks = 0,
        .fixed_delta_seconds = 1.0 / 120.0,
        .namespace = 702,
        .next_local_id = 1,
        .character_config = character_contract.CharacterConfigV1.fromConfig(.{}),
        .vehicle_config = vehicle_contract.VehicleConfigV1.fromConfig(.{}),
        .interaction_config = interaction_contract.InteractionConfigV1.fromConfig(.{}),
        .npc_config = npc_contract.NpcConfigV1.fromConfig(.{}),
        .npc_encounter_config = simulation_snapshot.NpcEncounterConfigV1.fromConfig(.{}),
        .authored_population = false,
        .navigation_gates = simulation_snapshot.initial_navigation_gates,
        .crates = &.{},
        .characters = &.{},
        .vehicles = &.{},
        .districts = &.{},
        .interactions = &.{},
        .npcs = &.{},
        .npc_encounters = &.{},
        .population = null,
    };
    const valid_empty = try std.json.Stringify.valueAlloc(allocator, empty_snapshot, .{});
    defer allocator.free(valid_empty);
    try std.testing.expectError(
        error.EngineWorldAlreadyLive,
        simulation.Simulation.fromSnapshot(allocator, valid_empty, .{}),
    );

    try std.testing.expectEqual(@as(usize, 1), world.crateCount());
    try std.testing.expectEqual(tick_before, world.tickIndex());
    const after = try world.crate(id);
    try std.testing.expectEqual(before.state.pose.position, after.state.pose.position);
    try world.tick();
    try std.testing.expectEqual(tick_before + 1, world.tickIndex());
}

fn restoreAllocationCase(allocator: std.mem.Allocator) !void {
    const crate_records = [_]crate_contract.CrateV1{
        .{
            .id = .{ .namespace = 703, .local = 1 },
            .half_extents = .{ 0.5, 0.5, 0.5 },
            .pose = .{ .position = .{ 0, 4, 0 } },
            .linear_velocity = .{ 0, 0, 0 },
            .angular_velocity = .{ 0, 0, 0 },
        },
        .{
            .id = .{ .namespace = 703, .local = 2 },
            .half_extents = .{ 0.75, 0.5, 0.25 },
            .pose = .{ .position = .{ 2, 6, 0 } },
            .linear_velocity = .{ 0.5, 0, -0.25 },
            .angular_velocity = .{ 0.1, 0.2, 0.3 },
        },
    };
    const character_records = [_]character_contract.CharacterV1{.{
        .id = .{ .namespace = 703, .local = 3 },
        .position = .{ -2, 0, 1 },
        .velocity = .{ 0, 0, 0 },
        .facing_yaw = 0.25,
    }};
    const logical_snapshot = simulation_snapshot.SnapshotV14{
        .schema_version = sandbox_contracts.snapshot_schema,
        .completed_ticks = 3,
        .fixed_delta_seconds = 1.0 / 120.0,
        .namespace = 703,
        .next_local_id = 4,
        .character_config = character_contract.CharacterConfigV1.fromConfig(.{}),
        .vehicle_config = vehicle_contract.VehicleConfigV1.fromConfig(.{}),
        .interaction_config = interaction_contract.InteractionConfigV1.fromConfig(.{}),
        .npc_config = npc_contract.NpcConfigV1.fromConfig(.{}),
        .npc_encounter_config = simulation_snapshot.NpcEncounterConfigV1.fromConfig(.{}),
        .authored_population = false,
        .navigation_gates = simulation_snapshot.initial_navigation_gates,
        .crates = &crate_records,
        .characters = &character_records,
        .vehicles = &.{},
        .districts = &.{},
        .interactions = &.{},
        .npcs = &.{},
        .npc_encounters = &.{},
        .population = null,
    };
    const snapshot = try std.json.Stringify.valueAlloc(allocator, logical_snapshot, .{});
    defer allocator.free(snapshot);
    var world = try simulation.Simulation.fromSnapshot(allocator, snapshot, .{});
    defer world.deinit();
    try std.testing.expectEqual(@as(usize, 3), world.entityCount());
    try std.testing.expectEqual(@as(usize, 1), world.characterCount());
    try std.testing.expectEqual(@as(u32, 3), world.bodyCount());
}

test "fresh restore unwinds every injected Zig allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        restoreAllocationCase,
        .{},
    );
}

test "owned simulation teardown accepts live crates pending commands and outcomes" {
    {
        var world = try simulation.Simulation.init(std.testing.allocator, .{
            .namespace = 704,
        });
        try world.submit(.{ .spawn = .{
            .request_id = 1,
            .pose = .{ .position = .{ 0, 3, 0 } },
        } });
        try world.tick();
        // Leave the spawn outcome unread and a command pending.
        try world.submit(.{ .spawn = .{
            .request_id = 2,
            .pose = .{ .position = .{ 2, 3, 0 } },
        } });
        world.deinit();
    }

    // Both the Flecs and process-Jolt ownership leases must have returned.
    var replacement = try simulation.Simulation.init(std.testing.allocator, .{
        .namespace = 705,
    });
    defer replacement.deinit();
    try std.testing.expectEqual(@as(usize, 0), replacement.entityCount());
    try std.testing.expectEqual(@as(u32, 1), replacement.bodyCount());
}

const district_test_assets = district_feature_contract.Assets{
    .scene = .{ .index = 17, .generation = 2 },
};
const district_test_coord = district_contract.ChunkCoord{ .x = 0, .z = -4 };

fn requestDistrict(
    world: *simulation.Simulation,
    request_id: u64,
) !district_contract.LoadTicket {
    return requestDistrictAt(
        world,
        request_id,
        district_test_coord,
        district_test_assets,
    );
}

fn requestDistrictAt(
    world: *simulation.Simulation,
    request_id: u64,
    coord: district_contract.ChunkCoord,
    assets: district_feature_contract.Assets,
) !district_contract.LoadTicket {
    try world.submitDistrict(.{ .request_load = .{
        .request_id = request_id,
        .coord = coord,
        .assets = assets,
    } });
    try world.tick();
    const outcome = world.pollDistrictOutcome() orelse
        return error.DistrictRequestOutcomeMissing;
    const ticket = switch (outcome) {
        .load_requested => |requested| requested.ticket,
        else => return error.UnexpectedDistrictOutcome,
    };
    if (world.pollDistrictOutcome() != null) return error.ExtraDistrictOutcome;
    while (world.pollDistrictEvent() != null) {}
    return ticket;
}

test "two real Jolt districts restore canonically and unload independently" {
    const allocator = std.testing.allocator;
    const west = district_contract.ChunkCoord{ .x = 0, .z = 0 };
    const east = district_contract.ChunkCoord{ .x = 1, .z = 0 };
    var canonical_save: []u8 = undefined;

    {
        var world = try simulation.Simulation.init(allocator, .{
            .namespace = 805,
            .create_ground = false,
        });
        defer world.deinit();

        const west_ticket = try requestDistrictAt(
            &world,
            1,
            west,
            district_test_assets,
        );
        try waitForDistrictActivation(&world, west_ticket);
        const east_ticket = try requestDistrictAt(
            &world,
            2,
            east,
            district_test_assets,
        );
        try waitForDistrictActivation(&world, east_ticket);

        try std.testing.expectEqual(@as(usize, 2), world.districtCount());
        try std.testing.expectEqual(@as(usize, 2), world.entityCount());
        try std.testing.expectEqual(
            sandbox_contracts.district_static_box_count * 2,
            world.bodyCount(),
        );
        try std.testing.expectEqual(
            @as(usize, sandbox_contracts.district_static_box_count) * 2,
            world.districtBodyCount(),
        );
        try std.testing.expectEqual(west_ticket, world.activeDistrictTicketFor(west).?);
        try std.testing.expectEqual(east_ticket, world.activeDistrictTicketFor(east).?);
        const draws = try world.districtPresentation();
        try std.testing.expectEqual(@as(usize, 2), draws.len);
        try std.testing.expectEqual(west, draws[0].build.coord);
        try std.testing.expectEqual(east, draws[1].build.coord);

        canonical_save = try world.save(allocator);
        const repeated = try world.save(allocator);
        defer allocator.free(repeated);
        try std.testing.expectEqualSlices(u8, canonical_save, repeated);

        try unloadDistrict(&world, 3, west_ticket);
        try std.testing.expectEqual(@as(usize, 1), world.districtCount());
        try std.testing.expectEqual(
            sandbox_contracts.district_static_box_count,
            world.bodyCount(),
        );
        try std.testing.expect(world.activeDistrictTicketFor(west) == null);
        try std.testing.expectEqual(east_ticket, world.activeDistrictTicketFor(east).?);

        const west_reloaded = try requestDistrictAt(
            &world,
            4,
            west,
            district_test_assets,
        );
        try waitForDistrictActivation(&world, west_reloaded);
        try std.testing.expectEqual(@as(usize, 2), world.districtCount());
        try unloadDistrict(&world, 5, east_ticket);
        try std.testing.expectEqual(west_reloaded, world.activeDistrictTicketFor(west).?);
        try unloadDistrict(&world, 6, west_reloaded);
        try std.testing.expectEqual(@as(usize, 0), world.entityCount());
        try std.testing.expectEqual(@as(u32, 0), world.bodyCount());
    }
    defer allocator.free(canonical_save);

    var restored = try simulation.Simulation.fromSnapshot(allocator, canonical_save, .{
        .create_ground = false,
        .district_assets = district_test_assets,
    });
    defer restored.deinit();
    try std.testing.expectEqual(@as(usize, 2), restored.districtCount());
    try std.testing.expectEqual(@as(usize, 2), restored.entityCount());
    try std.testing.expectEqual(
        sandbox_contracts.district_static_box_count * 2,
        restored.bodyCount(),
    );
    const restored_draws = try restored.districtPresentation();
    try std.testing.expectEqual(west, restored_draws[0].build.coord);
    try std.testing.expectEqual(east, restored_draws[1].build.coord);
    const resaved = try restored.save(allocator);
    defer allocator.free(resaved);
    try std.testing.expectEqualSlices(u8, canonical_save, resaved);
}

fn waitForDistrictActivation(
    world: *simulation.Simulation,
    expected: district_contract.LoadTicket,
) !void {
    for (0..10_000) |_| {
        std.Thread.yield() catch {};
        try world.tick();
        while (world.pollDistrictOutcome()) |outcome| switch (outcome) {
            .activated => |activated| {
                if (!std.meta.eql(expected, activated.ticket)) {
                    return error.UnexpectedDistrictTicket;
                }
                while (world.pollDistrictEvent() != null) {}
                return;
            },
            .load_failed => return error.DistrictLoadFailed,
            .cancelled => return error.DistrictLoadCancelled,
            else => return error.UnexpectedDistrictOutcome,
        };
        while (world.pollDistrictEvent() != null) {}
    }
    return error.DistrictWorkerDidNotComplete;
}

fn waitForDistrictCancellation(
    world: *simulation.Simulation,
    expected: district_contract.LoadTicket,
) !void {
    var cancellation_requested = false;
    for (0..10_000) |_| {
        std.Thread.yield() catch {};
        try world.tick();
        while (world.pollDistrictOutcome()) |outcome| switch (outcome) {
            .cancellation_requested => |requested| {
                if (!std.meta.eql(expected, requested.ticket)) {
                    return error.UnexpectedDistrictTicket;
                }
                cancellation_requested = true;
            },
            .cancelled => |cancelled| {
                if (!std.meta.eql(expected, cancelled.ticket) or !cancellation_requested) {
                    return error.UnexpectedDistrictCancellation;
                }
                while (world.pollDistrictEvent() != null) {}
                return;
            },
            else => return error.UnexpectedDistrictOutcome,
        };
        while (world.pollDistrictEvent() != null) {}
    }
    return error.DistrictWorkerDidNotCancel;
}

fn unloadDistrict(
    world: *simulation.Simulation,
    request_id: u64,
    ticket: district_contract.LoadTicket,
) !void {
    try world.submitDistrict(.{ .unload = .{
        .request_id = request_id,
        .ticket = ticket,
    } });
    try world.tick();
    const outcome = world.pollDistrictOutcome() orelse
        return error.DistrictUnloadOutcomeMissing;
    switch (outcome) {
        .unloaded => |unloaded| {
            if (!std.meta.eql(ticket, unloaded.ticket)) {
                return error.UnexpectedDistrictTicket;
            }
        },
        else => return error.UnexpectedDistrictOutcome,
    }
    if (world.pollDistrictOutcome() != null) return error.ExtraDistrictOutcome;
    while (world.pollDistrictEvent() != null) {}
}

test "operational headless resumes restored hostile combat and owns damage death pair" {
    const allocator = std.testing.allocator;
    const config = sandbox_contracts.Config{
        .namespace = 8_219,
        .create_ground = false,
        .character = .{ .max_characters = 1 },
        .npc_encounter = .{
            .ambient_perception_interval_ticks = 1,
            .engaged_perception_interval_ticks = 1,
            .route_replan_interval_ticks = 1,
            .attack_windup_ticks = 3,
            .attack_recovery_ticks = 3,
        },
    };
    var character_id: engine.PersistentId = undefined;
    var saved: []u8 = undefined;

    {
        var world = try simulation.Simulation.init(allocator, config);
        defer world.deinit();
        const ticket = try requestDistrictAt(
            &world,
            1,
            sandbox_contracts.navigation_west_coord,
            district_test_assets,
        );
        try waitForDistrictActivation(&world, ticket);
        try world.submitCharacter(.{ .spawn = .{
            .request_id = 2,
            .position = .{ -4, 0, 4 },
            .facing_yaw = 0,
        } });
        try world.submitNpc(.{ .spawn = .{
            .request_id = 3,
            .position = .{ -5, 0, 5 },
            .facing_yaw = 0,
            .anchor = .{
                .coord = sandbox_contracts.navigation_west_coord,
                .index = 0,
            },
            .hostile_to_players = true,
            .goal = .hold,
        } });
        try world.tick();
        character_id = switch (world.pollCharacterOutcome() orelse
            return error.CharacterSpawnOutcomeMissing) {
            .spawned => |spawned| spawned.id,
            else => return error.UnexpectedCharacterOutcome,
        };
        const npc_id = switch (world.pollNpcOutcome() orelse
            return error.NpcSpawnOutcomeMissing) {
            .spawned => |spawned| spawned.id,
            else => return error.UnexpectedNpcOutcome,
        };
        while (world.pollCharacterEvent() != null) {}
        while (world.pollNpcEvent() != null) {}

        const character_target = vitals_contract.Target{
            .kind = .player,
            .id = character_id,
            .incarnation = .{ .value = 1 },
        };
        const npc_target = vitals_contract.Target{
            .kind = .npc,
            .id = npc_id,
            .incarnation = .{ .value = 1 },
        };
        try world.submitVitals(.{ .register = .{
            .target = character_target,
            .current_health = config.npc_encounter.attack_damage,
        } });
        try world.submitVitals(.{ .register = .{ .target = npc_target } });
        try world.tick();
        var registrations: u8 = 0;
        while (world.pollVitalsOutcome()) |outcome| switch (outcome) {
            .registered => registrations += 1,
            else => return error.UnexpectedVitalsOutcome,
        };
        try std.testing.expectEqual(@as(u8, 2), registrations);
        while (world.pollNpcEncounterCue() != null) {}

        var armed = false;
        for (0..32) |_| {
            try world.tick();
            while (world.pollCharacterEvent() != null) {}
            while (world.pollNpcEvent() != null) {}
            while (world.pollNpcEncounterCue() != null) {}
            if (world.peekVitalsOutcome() != null or world.peekVitalsEvent() != null) {
                return error.HostileSnapshotArmedTooLate;
            }
            const encounter = world.npcEncounter(npc_target) orelse
                return error.NpcEncounterMissing;
            if (encounter.state == .attack_windup) {
                armed = true;
                break;
            }
        }
        try std.testing.expect(armed);
        saved = try world.save(allocator);
    }
    defer allocator.free(saved);

    var restored = try simulation.Simulation.fromSnapshotForWorld(
        allocator,
        saved,
        config,
        district_test_assets,
    );
    defer restored.deinit();
    var consumers = OperationalConsumers{};
    try consumers.consume(&restored);

    var player_died = false;
    for (0..32) |_| {
        try restored.tick();
        try consumers.consume(&restored);
        const current = restored.currentVitals(.player, character_id) orelse
            return error.CharacterVitalsMissing;
        if (current.life_state == .dead) {
            player_died = true;
            break;
        }
    }
    try std.testing.expect(player_died);
    try std.testing.expect(consumers.observational_events >= 2);
    try std.testing.expect(restored.peekVitalsOutcome() == null);
    try std.testing.expect(restored.peekVitalsEvent() == null);
    try std.testing.expect(restored.firstFault() == null);
    try std.testing.expect(restored.operationalQuiescenceReason() == null);
    try consumers.ensureQuiescent();
    const completed = try restored.save(allocator);
    defer allocator.free(completed);
}

test "operational headless preserves unrelated damage and death FIFO heads" {
    const namespace: u64 = 8_220;
    var world = try simulation.Simulation.init(std.testing.allocator, .{
        .namespace = namespace,
        .create_ground = false,
    });
    defer world.deinit();
    const target = vitals_contract.Target{
        .kind = .player,
        .id = .{ .namespace = namespace, .local = 1 },
        .incarnation = .{ .value = 1 },
    };
    try world.submitVitals(.{ .register = .{
        .target = target,
        .current_health = 1,
    } });
    try world.tick();
    const registered = world.pollVitalsOutcome() orelse
        return error.VitalsRegistrationMissing;
    try std.testing.expect(std.meta.activeTag(registered) == .registered);

    const source_target = vitals_contract.Target{
        .kind = .npc,
        .id = .{ .namespace = namespace, .local = 2 },
        .incarnation = .{ .value = 1 },
    };
    try world.submitVitals(.{ .damage = .{
        .source = .{
            .kind = .npc,
            .id = source_target.id,
            .incarnation = source_target.incarnation,
            .action_sequence = 1,
        },
        .target = target,
        .cause = .npc_melee,
        .authority_tick = world.tickIndex() + 1,
        .correlation = npc_encounter_contract.attackDamageCorrelation(source_target, 1),
        .base_amount = 1,
        .ordinal = 0,
    } });
    try world.tick();
    const outcome_head = world.peekVitalsOutcome() orelse
        return error.VitalsDamageOutcomeMissing;
    const event_head = world.peekVitalsEvent() orelse
        return error.VitalsDeathEventMissing;

    var consumers = OperationalConsumers{};
    try std.testing.expectError(
        error.UnownedHeadlessFeatureOutcome,
        consumers.consume(&world),
    );
    try std.testing.expectEqualDeep(outcome_head, world.peekVitalsOutcome().?);
    try std.testing.expectEqualDeep(event_head, world.peekVitalsEvent().?);
    try std.testing.expectEqual(@as(u64, 0), consumers.observational_events);
}

fn expectNpcOutputEmpty(world: *simulation.Simulation) !void {
    if (world.pollNpcOutcome() != null) return error.UnexpectedNpcOutcome;
    if (world.pollNpcEvent() != null) return error.UnexpectedNpcEvent;
}

fn expectNpcStateChanged(
    world: *simulation.Simulation,
    id: engine.PersistentId,
    previous: npc_contract.State,
    current: npc_contract.State,
) !void {
    const event = world.pollNpcEvent() orelse return error.NpcStateEventMissing;
    switch (event) {
        .state_changed => |value| {
            try std.testing.expectEqual(id, value.id);
            try std.testing.expectEqual(previous, value.previous);
            try std.testing.expectEqual(current, value.current);
        },
        else => return error.UnexpectedNpcEvent,
    }
    try expectNpcOutputEmpty(world);
}

fn expectNpcOwnerTransferred(
    world: *simulation.Simulation,
    id: engine.PersistentId,
    previous: district_contract.ChunkCoord,
    current: district_contract.ChunkCoord,
) !void {
    const event = world.pollNpcEvent() orelse return error.NpcTransferEventMissing;
    switch (event) {
        .owner_transferred => |value| {
            try std.testing.expectEqual(id, value.id);
            try std.testing.expectEqual(previous, value.previous);
            try std.testing.expectEqual(current, value.current);
        },
        else => return error.UnexpectedNpcEvent,
    }
    try expectNpcOutputEmpty(world);
}

fn expectNpcGoalReached(
    world: *simulation.Simulation,
    id: engine.PersistentId,
    destination: npc_contract.DestinationId,
) !void {
    const event = world.pollNpcEvent() orelse return error.NpcGoalEventMissing;
    switch (event) {
        .goal_reached => |value| {
            try std.testing.expectEqual(id, value.id);
            try std.testing.expectEqual(destination, value.destination);
        },
        else => return error.UnexpectedNpcEvent,
    }
    try expectNpcOutputEmpty(world);
}

test "S8 headless NPC patrol waits through cancellation crosses suspends and restores" {
    const allocator = std.testing.allocator;
    const west_start = npc_contract.NodeRef{
        .coord = sandbox_contracts.navigation_west_coord,
        .index = 0,
    };
    var saved: []u8 = undefined;
    var npc_id: engine.PersistentId = undefined;
    var event_sequence: u8 = 0;

    {
        var world = try simulation.Simulation.init(allocator, .{
            .namespace = 8_201,
            .create_ground = false,
        });
        defer world.deinit();

        const west_ticket = try requestDistrictAt(
            &world,
            1,
            sandbox_contracts.navigation_west_coord,
            district_test_assets,
        );
        try waitForDistrictActivation(&world, west_ticket);
        const first_east_ticket = try requestDistrictAt(
            &world,
            2,
            sandbox_contracts.navigation_east_coord,
            district_test_assets,
        );
        try waitForDistrictActivation(&world, first_east_ticket);
        try std.testing.expectEqual(
            sandbox_contracts.district_static_box_count * 2,
            world.bodyCount(),
        );

        try world.submitNpc(.{ .spawn = .{
            .request_id = 10,
            .position = .{ -5, 0, 5 },
            .facing_yaw = 0,
            .anchor = west_start,
            .hostile_to_players = true,
            .goal = .{ .patrol_between = .{
                .first = sandbox_contracts.player_plaza_destination,
                .second = sandbox_contracts.market_terminal_destination,
            } },
        } });
        try world.tick();
        npc_id = switch (world.pollNpcOutcome() orelse
            return error.NpcSpawnOutcomeMissing) {
            .spawned => |value| value.id,
            else => return error.UnexpectedNpcOutcome,
        };
        try std.testing.expectEqual(npc_contract.State.active, (try world.npc(npc_id)).state);
        try std.testing.expectEqual(@as(usize, 1), world.npcCount());
        const active_diagnostics = world.diagnostics();
        try std.testing.expectEqual(@as(u32, 1), active_diagnostics.npc.controller_count);
        try std.testing.expectEqual(
            @as(u32, 1),
            active_diagnostics.character_controllers.native_used,
        );
        try std.testing.expectEqual(
            @as(u32, 1),
            active_diagnostics.character_controllers.feature_owned,
        );
        try std.testing.expect(active_diagnostics.character_controllers.authority_consistent);
        try std.testing.expectEqual(
            sandbox_contracts.district_static_box_count * 2,
            world.bodyCount(),
        );
        try expectNpcOutputEmpty(&world);

        try unloadDistrict(&world, 11, first_east_ticket);
        var observed_waiting = false;
        for (0..2_000) |_| {
            try world.tick();
            if ((try world.npc(npc_id)).state == .waiting_at_boundary) {
                observed_waiting = true;
                break;
            }
        }
        try std.testing.expect(observed_waiting);
        const waiting = try world.npc(npc_id);
        try std.testing.expectEqual(sandbox_contracts.navigation_west_coord, waiting.owner);
        try std.testing.expect(waiting.controller_present);
        try std.testing.expectEqual(
            sandbox_contracts.district_static_box_count,
            world.bodyCount(),
        );
        try std.testing.expectEqual(@as(u8, 0), event_sequence);
        try expectNpcStateChanged(
            &world,
            npc_id,
            .active,
            .waiting_at_boundary,
        );
        event_sequence += 1;

        // A canceled destination load must not wake the waiting NPC or pin the
        // district. This proves the same asynchronous cancel boundary used by
        // the normal headless district host remains authoritative for S8.
        const cancelled_east_ticket = try requestDistrictAt(
            &world,
            12,
            sandbox_contracts.navigation_east_coord,
            district_test_assets,
        );
        try world.submitDistrict(.{ .cancel_load = .{
            .request_id = 13,
            .ticket = cancelled_east_ticket,
        } });
        try waitForDistrictCancellation(&world, cancelled_east_ticket);
        try std.testing.expect(
            world.activeDistrictTicketFor(sandbox_contracts.navigation_east_coord) == null,
        );
        try std.testing.expectEqual(
            npc_contract.State.waiting_at_boundary,
            (try world.npc(npc_id)).state,
        );
        try std.testing.expectEqual(@as(u32, 1), world.diagnostics().npc.controller_count);
        try std.testing.expectEqual(
            sandbox_contracts.district_static_box_count,
            world.bodyCount(),
        );
        try expectNpcOutputEmpty(&world);

        const second_east_ticket = try requestDistrictAt(
            &world,
            14,
            sandbox_contracts.navigation_east_coord,
            district_test_assets,
        );
        try waitForDistrictActivation(&world, second_east_ticket);
        try std.testing.expect(
            second_east_ticket.generation > cancelled_east_ticket.generation,
        );
        try std.testing.expectEqual(@as(u8, 1), event_sequence);
        try expectNpcStateChanged(
            &world,
            npc_id,
            .waiting_at_boundary,
            .active,
        );
        event_sequence += 1;
        var observed_transfer = false;
        for (0..1_000) |_| {
            try world.tick();
            if (district_contract.ChunkCoord.eql(
                (try world.npc(npc_id)).owner,
                sandbox_contracts.navigation_east_coord,
            )) {
                observed_transfer = true;
                break;
            }
        }
        try std.testing.expect(observed_transfer);
        try std.testing.expectEqual(
            sandbox_contracts.district_static_box_count * 2,
            world.bodyCount(),
        );
        try std.testing.expectEqual(@as(u32, 1), world.diagnostics().npc.controller_count);
        try std.testing.expectEqual(@as(u8, 2), event_sequence);
        try expectNpcOwnerTransferred(
            &world,
            npc_id,
            sandbox_contracts.navigation_west_coord,
            sandbox_contracts.navigation_east_coord,
        );
        event_sequence += 1;

        try unloadDistrict(&world, 15, second_east_ticket);
        const dormant = try world.npc(npc_id);
        try std.testing.expectEqual(npc_contract.State.dormant, dormant.state);
        try std.testing.expect(!dormant.controller_present);
        const dormant_diagnostics = world.diagnostics();
        try std.testing.expectEqual(@as(u32, 0), dormant_diagnostics.npc.controller_count);
        try std.testing.expectEqual(
            @as(u32, 0),
            dormant_diagnostics.character_controllers.native_used,
        );
        try std.testing.expectEqual(
            @as(u32, 0),
            dormant_diagnostics.character_controllers.feature_owned,
        );
        try std.testing.expect(dormant_diagnostics.character_controllers.authority_consistent);
        try std.testing.expectEqual(
            sandbox_contracts.district_static_box_count,
            world.bodyCount(),
        );
        try std.testing.expectEqual(@as(u8, 3), event_sequence);
        try expectNpcStateChanged(&world, npc_id, .active, .dormant);
        event_sequence += 1;

        const third_east_ticket = try requestDistrictAt(
            &world,
            16,
            sandbox_contracts.navigation_east_coord,
            district_test_assets,
        );
        try waitForDistrictActivation(&world, third_east_ticket);
        try std.testing.expect(third_east_ticket.generation > second_east_ticket.generation);
        const resumed = try world.npc(npc_id);
        try std.testing.expect(resumed.state != .dormant);
        try std.testing.expect(resumed.controller_present);
        try std.testing.expectEqual(@as(u32, 1), world.diagnostics().npc.controller_count);
        try std.testing.expectEqual(
            sandbox_contracts.district_static_box_count * 2,
            world.bodyCount(),
        );
        try std.testing.expectEqual(@as(usize, 1), (try world.npcPresentation(0)).len);
        try std.testing.expectEqual(@as(u8, 4), event_sequence);
        try expectNpcStateChanged(&world, npc_id, .dormant, .active);
        event_sequence += 1;

        var observed_goal = false;
        for (0..2_000) |_| {
            try world.tick();
            if ((try world.npc(npc_id)).route.patrol_leg == .toward_first) {
                observed_goal = true;
                break;
            }
        }
        try std.testing.expect(observed_goal);
        try std.testing.expectEqual(@as(u8, 5), event_sequence);
        try expectNpcGoalReached(
            &world,
            npc_id,
            sandbox_contracts.market_terminal_destination,
        );
        event_sequence += 1;
        saved = try world.save(allocator);
    }
    defer allocator.free(saved);

    var restored = try simulation.Simulation.fromSnapshot(allocator, saved, .{
        .create_ground = false,
        .district_assets = district_test_assets,
    });
    defer restored.deinit();
    try std.testing.expectEqual(@as(usize, 1), restored.npcCount());
    try std.testing.expectEqual(@as(usize, 3), restored.entityCount());
    try std.testing.expectEqual(
        sandbox_contracts.district_static_box_count * 2,
        restored.bodyCount(),
    );
    const restored_diagnostics = restored.diagnostics();
    try std.testing.expectEqual(@as(u32, 1), restored_diagnostics.npc.controller_count);
    try std.testing.expectEqual(
        @as(u32, 1),
        restored_diagnostics.character_controllers.native_used,
    );
    try std.testing.expectEqual(
        @as(u32, 1),
        restored_diagnostics.character_controllers.feature_owned,
    );
    try std.testing.expect(restored_diagnostics.character_controllers.authority_consistent);
    try std.testing.expect((try restored.npc(npc_id)).controller_present);
    try std.testing.expectEqual(@as(u8, 6), event_sequence);
    try expectNpcOutputEmpty(&restored);
    const resaved = try restored.save(allocator);
    defer allocator.free(resaved);
    try std.testing.expectEqualSlices(u8, saved, resaved);
}

test "S8 headless rejects hostile NPC restore and controller overflow before authority" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(
        error.VirtualCharacterCapacityExceeded,
        simulation.Simulation.init(allocator, .{
            .namespace = 8_210,
            .character = .{ .max_characters = 65 },
        }),
    );

    const hostile_npc = npc_contract.NpcV1{
        .id = .{ .namespace = 8_211, .local = 1 },
        .owner = sandbox_contracts.navigation_west_coord,
        .goal = .hold,
        .route = .{ .current = .{
            .coord = sandbox_contracts.navigation_west_coord,
            .index = 0,
        } },
        .position = .{ 9, 0, 3 },
        .velocity = .{ 0, 0, 0 },
        .facing_yaw = 0,
        .hostile_to_players = true,
    };
    const hostile = try std.json.Stringify.valueAlloc(
        allocator,
        simulation_snapshot.SnapshotV14{
            .schema_version = sandbox_contracts.snapshot_schema,
            .completed_ticks = 0,
            .fixed_delta_seconds = 1.0 / 120.0,
            .namespace = 8_211,
            .next_local_id = 2,
            .character_config = character_contract.CharacterConfigV1.fromConfig(.{}),
            .vehicle_config = vehicle_contract.VehicleConfigV1.fromConfig(.{}),
            .interaction_config = interaction_contract.InteractionConfigV1.fromConfig(.{}),
            .npc_config = npc_contract.NpcConfigV1.fromConfig(.{}),
            .npc_encounter_config = simulation_snapshot.NpcEncounterConfigV1.fromConfig(.{}),
            .authored_population = false,
            .navigation_gates = simulation_snapshot.initial_navigation_gates,
            .crates = &.{},
            .characters = &.{},
            .vehicles = &.{},
            .districts = &.{},
            .interactions = &.{},
            .npcs = &.{hostile_npc},
            .npc_encounters = &.{},
            .population = null,
        },
        .{},
    );
    defer allocator.free(hostile);

    var blocker = try simulation.Simulation.init(allocator, .{
        .namespace = 8_212,
        .create_ground = false,
    });
    defer blocker.deinit();
    try std.testing.expectError(
        error.NpcOwnerPositionMismatch,
        simulation.Simulation.fromSnapshot(allocator, hostile, .{}),
    );
    try blocker.tick();
}

const s7_west = district_contract.ChunkCoord{ .x = 0, .z = 0 };
const s7_east = district_contract.ChunkCoord{ .x = 1, .z = 0 };
const s7_west_x: f32 = 6;
const s7_east_x: f32 = 10;

fn drainS7Ambient(world: *simulation.Simulation) !void {
    while (world.pollCharacterEvent() != null) {}
    while (world.pollVehicleEvent() != null) {}
    while (world.pollDistrictEvent() != null) {}
    var unexpected_npc_event = false;
    while (world.pollNpcEvent() != null) unexpected_npc_event = true;
    if (unexpected_npc_event or
        world.pollOutcome() != null or
        world.pollCharacterOutcome() != null or
        world.pollVehicleOutcome() != null or
        world.pollDistrictOutcome() != null or
        world.pollInteractionOutcome() != null or
        world.pollNpcOutcome() != null)
    {
        return error.UnexpectedS7Output;
    }
}

fn activateS7District(
    world: *simulation.Simulation,
    request_id: u64,
    coord: district_contract.ChunkCoord,
) !district_contract.LoadTicket {
    try world.submitDistrict(.{ .request_load = .{
        .request_id = request_id,
        .coord = coord,
        .assets = district_test_assets,
    } });
    try world.tick();
    const requested = world.pollDistrictOutcome() orelse
        return error.DistrictRequestOutcomeMissing;
    const ticket = switch (requested) {
        .load_requested => |value| value.ticket,
        else => return error.UnexpectedDistrictOutcome,
    };
    try drainS7Ambient(world);

    for (0..10_000) |_| {
        std.Thread.yield() catch {};
        try world.tick();
        var activated = false;
        while (world.pollDistrictOutcome()) |outcome| switch (outcome) {
            .activated => |value| {
                if (!district_contract.LoadTicket.eql(ticket, value.ticket)) {
                    return error.UnexpectedDistrictTicket;
                }
                activated = true;
            },
            .load_failed => return error.DistrictLoadFailed,
            .cancelled => return error.DistrictLoadCancelled,
            else => return error.UnexpectedDistrictOutcome,
        };
        while (world.pollCharacterEvent() != null) {}
        while (world.pollVehicleEvent() != null) {}
        while (world.pollDistrictEvent() != null) {}
        var unexpected_npc_event = false;
        while (world.pollNpcEvent() != null) unexpected_npc_event = true;
        if (unexpected_npc_event or
            world.pollOutcome() != null or
            world.pollCharacterOutcome() != null or
            world.pollVehicleOutcome() != null or
            world.pollInteractionOutcome() != null or
            world.pollNpcOutcome() != null)
        {
            return error.UnexpectedS7Output;
        }
        if (activated) return ticket;
    }
    return error.DistrictWorkerDidNotComplete;
}

fn unloadS7District(
    world: *simulation.Simulation,
    request_id: u64,
    ticket: district_contract.LoadTicket,
) !void {
    try world.submitDistrict(.{ .unload = .{
        .request_id = request_id,
        .ticket = ticket,
    } });
    try world.tick();
    const outcome = world.pollDistrictOutcome() orelse
        return error.DistrictUnloadOutcomeMissing;
    switch (outcome) {
        .unloaded => |value| if (!district_contract.LoadTicket.eql(ticket, value.ticket)) {
            return error.UnexpectedDistrictTicket;
        },
        else => return error.UnexpectedDistrictOutcome,
    }
    try drainS7Ambient(world);
}

fn expectS7InteractionDraw(
    world: *simulation.Simulation,
    carryable_id: engine.PersistentId,
    ownership: @TypeOf(@as(interaction_contract.CarryableView, undefined).ownership),
) !void {
    const draws = try world.interactionPresentation();
    if (draws.len != 1) return error.InteractionPresentationCountMismatch;
    try std.testing.expectEqual(carryable_id, draws[0].persistent_id);
    try std.testing.expect(std.meta.eql(ownership, draws[0].ownership));
}

fn collectS7Carryable(
    world: *simulation.Simulation,
    transaction_id: u64,
    character_id: engine.PersistentId,
    carryable_id: engine.PersistentId,
    previous_owner: district_contract.ChunkCoord,
) !void {
    try world.submitInteraction(.{ .collect = .{
        .transaction_id = transaction_id,
        .carrier_id = character_id,
        .carryable_id = carryable_id,
    } });
    try world.tick();
    const outcome = world.pollInteractionOutcome() orelse
        return error.InteractionOutcomeMissing;
    switch (outcome) {
        .collected => |value| {
            try std.testing.expectEqual(transaction_id, value.transaction_id);
            try std.testing.expectEqual(character_id, value.carrier_id);
            try std.testing.expectEqual(carryable_id, value.carryable_id);
            try std.testing.expectEqual(previous_owner, value.previous_owner);
        },
        else => return error.UnexpectedInteractionOutcome,
    }
    try drainS7Ambient(world);
    const view = try world.carryable(carryable_id);
    try std.testing.expect(!view.body_present);
    try expectS7InteractionDraw(
        world,
        carryable_id,
        .{ .inventory_held = character_id },
    );
}

fn moveS7CharacterToX(
    world: *simulation.Simulation,
    character_id: engine.PersistentId,
    target_x: f32,
) !void {
    for (0..256) |_| {
        const current = try world.character(character_id);
        const delta = target_x - current.position[0];
        if (@abs(delta) <= 0.05) break;
        try world.submitCharacter(.{ .actions = .{
            .id = character_id,
            .move = .{ if (delta > 0) 1 else -1, 0 },
            .facing_yaw = 0,
        } });
        try world.tick();
        try drainS7Ambient(world);
    } else return error.CharacterDidNotCrossDistrictBoundary;

    try world.submitCharacter(.{ .actions = .{
        .id = character_id,
        .move = .{ 0, 0 },
        .facing_yaw = 0,
    } });
    try world.tick();
    try drainS7Ambient(world);
    const final = try world.character(character_id);
    if (@abs(final.position[0] - target_x) > 0.11) {
        return error.CharacterTargetPositionMismatch;
    }
}

fn dropS7Carryable(
    world: *simulation.Simulation,
    transaction_id: u64,
    character_id: engine.PersistentId,
    carryable_id: engine.PersistentId,
    owner: district_contract.ChunkCoord,
) !void {
    try world.submitInteraction(.{ .drop = .{
        .transaction_id = transaction_id,
        .carrier_id = character_id,
        .carryable_id = carryable_id,
        .purpose = .player_requested,
    } });
    try world.tick();
    const outcome = world.pollInteractionOutcome() orelse
        return error.InteractionOutcomeMissing;
    switch (outcome) {
        .dropped => |value| {
            try std.testing.expectEqual(transaction_id, value.transaction_id);
            try std.testing.expectEqual(character_id, value.carrier_id);
            try std.testing.expectEqual(carryable_id, value.carryable_id);
            try std.testing.expectEqual(owner, value.owner);
        },
        else => return error.UnexpectedInteractionOutcome,
    }
    try drainS7Ambient(world);
    try std.testing.expect((try world.carryable(carryable_id)).body_present);
    try expectS7InteractionDraw(world, carryable_id, .{ .spatially_owned = owner });
}

fn runS7RepeatedCycle(
    world: *simulation.Simulation,
    request_base: u64,
    character_id: engine.PersistentId,
    carryable_id: engine.PersistentId,
    source: district_contract.ChunkCoord,
    source_ticket: district_contract.LoadTicket,
    destination: district_contract.ChunkCoord,
    destination_x: f32,
) !district_contract.LoadTicket {
    try collectS7Carryable(
        world,
        request_base,
        character_id,
        carryable_id,
        source,
    );
    try std.testing.expectEqual(
        1 + sandbox_contracts.district_static_box_count,
        world.bodyCount(),
    );
    try std.testing.expectEqual(@as(usize, 3), world.entityCount());

    try unloadS7District(world, request_base + 1, source_ticket);
    try std.testing.expectEqual(@as(u32, 1), world.bodyCount());
    try std.testing.expectEqual(@as(usize, 2), world.entityCount());

    const destination_ticket = try activateS7District(
        world,
        request_base + 2,
        destination,
    );
    try std.testing.expectEqual(
        1 + sandbox_contracts.district_static_box_count,
        world.bodyCount(),
    );
    try std.testing.expectEqual(@as(usize, 3), world.entityCount());
    try moveS7CharacterToX(world, character_id, destination_x);
    try dropS7Carryable(
        world,
        request_base + 3,
        character_id,
        carryable_id,
        destination,
    );
    try std.testing.expectEqual(
        2 + sandbox_contracts.district_static_box_count,
        world.bodyCount(),
    );
    try std.testing.expectEqual(@as(usize, 3), world.entityCount());

    try unloadS7District(world, request_base + 4, destination_ticket);
    try std.testing.expectEqual(@as(u32, 2), world.bodyCount());
    try std.testing.expectEqual(@as(usize, 2), world.entityCount());
    try std.testing.expectEqual(@as(usize, 1), (try world.interactionPresentation()).len);
    try std.testing.expect((try world.carryable(carryable_id)).body_present);

    const reloaded = try activateS7District(
        world,
        request_base + 5,
        destination,
    );
    try std.testing.expectEqual(
        2 + sandbox_contracts.district_static_box_count,
        world.bodyCount(),
    );
    try std.testing.expectEqual(@as(usize, 3), world.entityCount());
    try expectS7InteractionDraw(
        world,
        carryable_id,
        .{ .spatially_owned = destination },
    );
    return reloaded;
}

fn cleanupS7World(
    world: *simulation.Simulation,
    request_id: u64,
    character_id: engine.PersistentId,
    carryable_id: engine.PersistentId,
    district_ticket: district_contract.LoadTicket,
) !void {
    try world.submitCharacter(.{ .despawn = .{ .id = character_id } });
    try world.submitInteraction(.{ .despawn = .{ .id = carryable_id } });
    try world.tick();
    const character_outcome = world.pollCharacterOutcome() orelse
        return error.CharacterDespawnOutcomeMissing;
    switch (character_outcome) {
        .despawned => |id| try std.testing.expectEqual(character_id, id),
        else => return error.UnexpectedCharacterOutcome,
    }
    const interaction_outcome = world.pollInteractionOutcome() orelse
        return error.InteractionOutcomeMissing;
    switch (interaction_outcome) {
        .despawned => |id| try std.testing.expectEqual(carryable_id, id),
        else => return error.UnexpectedInteractionOutcome,
    }
    try drainS7Ambient(world);
    try std.testing.expectEqual(
        1 + sandbox_contracts.district_static_box_count,
        world.bodyCount(),
    );
    try std.testing.expectEqual(@as(usize, 1), world.entityCount());
    try unloadS7District(world, request_id, district_ticket);
    try std.testing.expectEqual(@as(u32, 1), world.bodyCount());
    try std.testing.expectEqual(@as(usize, 0), world.entityCount());
    try std.testing.expectEqual(@as(usize, 0), world.characterCount());
    try std.testing.expectEqual(@as(usize, 0), world.interactionCount());
    try std.testing.expectEqual(@as(usize, 0), world.districtCount());
    const diagnostics = world.diagnostics();
    try std.testing.expectEqual(@as(u32, 0), diagnostics.interaction.commands.occupancy);
    try std.testing.expectEqual(@as(u32, 0), diagnostics.interaction.outcomes.occupancy);
}

test "S7 captured real Jolt cross-district ownership lifecycle is exact and repeatable" {
    const allocator = std.testing.allocator;
    const content = try sandbox_replay.ContentCohort.init(
        "s7-headless-west-east",
        sandbox_replay.current_catalog_format_version,
        sandbox_replay.current_catalog_schema_cohort,
        1,
        [_]u8{0x71} ** 32,
        [_]u8{0x17} ** 32,
    );
    var capture_bytes: []u8 = undefined;
    var spatial_save: []u8 = undefined;
    var completed_ticks: u64 = 0;
    const character_id: engine.PersistentId = blk: {
        var world = try simulation.Simulation.init(allocator, .{
            .namespace = 8_071,
        });
        defer world.deinit();
        try std.testing.expectEqual(@as(u32, 1), world.bodyCount());
        try std.testing.expectEqual(@as(usize, 0), world.entityCount());
        try std.testing.expect(
            (try world.beginFlightRecording(content, .{})) == .admitted,
        );

        const west_ticket = try activateS7District(&world, 1, s7_west);
        const east_ticket = try activateS7District(&world, 2, s7_east);
        try std.testing.expectEqual(
            1 + sandbox_contracts.district_static_box_count * 2,
            world.bodyCount(),
        );
        try std.testing.expectEqual(@as(usize, 2), world.entityCount());

        try world.submitCharacter(.{ .spawn = .{
            .request_id = 3,
            .position = .{ s7_west_x, 0, 3 },
        } });
        try world.submitInteraction(.{ .spawn = .{
            .request_id = 4,
            .pose = .{ .position = .{ s7_west_x, 0.75, 1.5 } },
        } });
        try world.tick();
        const spawned_character = switch (world.pollCharacterOutcome() orelse
            return error.CharacterSpawnOutcomeMissing) {
            .spawned => |value| value.id,
            else => return error.UnexpectedCharacterOutcome,
        };
        const carryable_id = switch (world.pollInteractionOutcome() orelse
            return error.InteractionOutcomeMissing) {
            .spawned => |value| value.id,
            else => return error.UnexpectedInteractionOutcome,
        };
        try drainS7Ambient(&world);
        try std.testing.expectEqual(
            2 + sandbox_contracts.district_static_box_count * 2,
            world.bodyCount(),
        );
        try std.testing.expectEqual(@as(usize, 4), world.entityCount());
        try expectS7InteractionDraw(
            &world,
            carryable_id,
            .{ .spatially_owned = s7_west },
        );

        try collectS7Carryable(
            &world,
            10,
            spawned_character,
            carryable_id,
            s7_west,
        );
        try std.testing.expectEqual(
            1 + sandbox_contracts.district_static_box_count * 2,
            world.bodyCount(),
        );
        try unloadS7District(&world, 11, west_ticket);
        try std.testing.expectEqual(
            1 + sandbox_contracts.district_static_box_count,
            world.bodyCount(),
        );
        try std.testing.expectEqual(@as(usize, 3), world.entityCount());

        try moveS7CharacterToX(&world, spawned_character, s7_east_x);
        try dropS7Carryable(
            &world,
            12,
            spawned_character,
            carryable_id,
            s7_east,
        );
        try std.testing.expectEqual(
            2 + sandbox_contracts.district_static_box_count,
            world.bodyCount(),
        );
        try std.testing.expectEqual(@as(usize, 3), world.entityCount());
        try unloadS7District(&world, 13, east_ticket);
        try std.testing.expectEqual(@as(u32, 2), world.bodyCount());
        try std.testing.expectEqual(@as(usize, 2), world.entityCount());
        try std.testing.expectEqual(
            @as(usize, 1),
            (try world.interactionPresentation()).len,
        );
        spatial_save = try world.save(allocator);
        const repeated_spatial = try world.save(allocator);
        defer allocator.free(repeated_spatial);
        try std.testing.expectEqualSlices(u8, spatial_save, repeated_spatial);

        var active_coord = s7_east;
        var active_x = s7_east_x;
        var active_ticket = try activateS7District(&world, 14, active_coord);
        try std.testing.expectEqual(
            2 + sandbox_contracts.district_static_box_count,
            world.bodyCount(),
        );
        try std.testing.expectEqual(@as(usize, 3), world.entityCount());

        for (0..4) |cycle| {
            const destination = if (district_contract.ChunkCoord.eql(active_coord, s7_east))
                s7_west
            else
                s7_east;
            const destination_x = if (district_contract.ChunkCoord.eql(destination, s7_west))
                s7_west_x
            else
                s7_east_x;
            active_ticket = try runS7RepeatedCycle(
                &world,
                100 + cycle * 10,
                spawned_character,
                carryable_id,
                active_coord,
                active_ticket,
                destination,
                destination_x,
            );
            active_coord = destination;
            active_x = destination_x;
        }
        try std.testing.expectApproxEqAbs(
            active_x,
            (try world.character(spawned_character)).position[0],
            0.11,
        );
        try cleanupS7World(
            &world,
            1_000,
            spawned_character,
            carryable_id,
            active_ticket,
        );
        completed_ticks = world.tickIndex();
        capture_bytes = try world.finishFlightRecording(allocator);
        break :blk spawned_character;
    };
    defer allocator.free(capture_bytes);
    defer allocator.free(spatial_save);

    var parsed_capture = try sandbox_replay.parseCompatible(
        allocator,
        capture_bytes,
        content,
    );
    defer parsed_capture.deinit();
    switch (try simulation.replayCapture(
        allocator,
        parsed_capture.view(),
        content,
    )) {
        .matched => |value| try std.testing.expectEqual(
            completed_ticks,
            value.completed_ticks,
        ),
        .divergent => return error.S7CaptureDiverged,
    }

    var restored = try simulation.Simulation.fromSnapshot(allocator, spatial_save, .{});
    defer restored.deinit();
    try std.testing.expectEqual(@as(u32, 2), restored.bodyCount());
    try std.testing.expectEqual(@as(usize, 2), restored.entityCount());
    try std.testing.expectEqual(@as(usize, 1), restored.interactionCount());
    try std.testing.expectEqual(@as(usize, 1), (try restored.interactionPresentation()).len);
    const restored_item = restored.diagnostics().interaction;
    try std.testing.expectEqual(@as(u32, 1), restored_item.spatially_owned_count);
    try std.testing.expectEqual(@as(u32, 1), restored_item.dynamic_body_count);

    const reloaded = try activateS7District(&restored, 2_000, s7_east);
    try std.testing.expectEqual(
        2 + sandbox_contracts.district_static_box_count,
        restored.bodyCount(),
    );
    try std.testing.expectEqual(@as(usize, 3), restored.entityCount());
    const restored_draws = try restored.interactionPresentation();
    try std.testing.expectEqual(@as(usize, 1), restored_draws.len);
    const restored_carryable_id = restored_draws[0].persistent_id;
    try expectS7InteractionDraw(
        &restored,
        restored_carryable_id,
        .{ .spatially_owned = s7_east },
    );
    const resaved = try restored.save(allocator);
    defer allocator.free(resaved);
    const resaved_again = try restored.save(allocator);
    defer allocator.free(resaved_again);
    try std.testing.expectEqualSlices(u8, resaved, resaved_again);
    try cleanupS7World(
        &restored,
        2_001,
        character_id,
        restored_carryable_id,
        reloaded,
    );
}

test "real district worker cancels activates collides unloads and repeats cleanly" {
    const allocator = std.testing.allocator;
    var world = try simulation.Simulation.init(allocator, .{
        .namespace = 801,
    });
    defer world.deinit();

    const cancelled_ticket = try requestDistrict(&world, 1);
    try std.testing.expectEqual(
        district_feature_contract.StateTag.loading,
        world.districtStateFor(district_test_coord).?,
    );
    try std.testing.expectError(error.DistrictTransitionPending, world.save(allocator));
    try world.submitDistrict(.{ .cancel_load = .{
        .request_id = 2,
        .ticket = cancelled_ticket,
    } });
    try waitForDistrictCancellation(&world, cancelled_ticket);
    try std.testing.expect(world.districtStateFor(district_test_coord) == null);
    try std.testing.expectEqual(@as(usize, 0), world.entityCount());
    try std.testing.expectEqual(@as(u32, 1), world.bodyCount());

    const active_ticket = try requestDistrict(&world, 3);
    try waitForDistrictActivation(&world, active_ticket);
    try std.testing.expectEqual(
        district_feature_contract.StateTag.active,
        world.districtStateFor(district_test_coord).?,
    );
    try std.testing.expectEqual(@as(usize, 1), world.districtCount());
    try std.testing.expectEqual(
        @as(usize, sandbox_contracts.district_static_box_count),
        world.districtBodyCount(),
    );
    try std.testing.expectEqual(@as(usize, 1), world.entityCount());
    try std.testing.expectEqual(
        1 + sandbox_contracts.district_static_box_count,
        world.bodyCount(),
    );
    const district_draws = try world.districtPresentation();
    try std.testing.expectEqual(@as(usize, 1), district_draws.len);
    try std.testing.expectEqual(
        @as(u8, @intCast(sandbox_contracts.district_static_box_count)),
        district_draws[0].build.static_box_count,
    );
    try std.testing.expectEqual(district_test_assets.scene, district_draws[0].assets.scene);

    // The crate settles on the raised district obstacle, not the district floor.
    try world.submit(.{ .spawn = .{
        .request_id = 4,
        .pose = .{ .position = .{ -5.5, 6, -66 } },
    } });
    try world.tick();
    const crate_id = world.pollOutcome().?.spawned.id;
    for (0..360) |_| try world.tick();
    const supported_y = (try world.crate(crate_id)).state.pose.position[1];
    try std.testing.expect(supported_y > 2.4);
    try std.testing.expect(supported_y < 2.7);

    try unloadDistrict(&world, 5, active_ticket);
    try std.testing.expectEqual(@as(usize, 1), world.entityCount());
    try std.testing.expectEqual(@as(u32, 2), world.bodyCount());
    try std.testing.expectEqual(@as(usize, 0), (try world.districtPresentation()).len);
    for (0..120) |_| try world.tick();
    try std.testing.expect(
        (try world.crate(crate_id)).state.pose.position[1] < supported_y - 3,
    );
    try world.submit(.{ .despawn = .{ .id = crate_id } });
    try world.tick();
    _ = world.pollOutcome();

    for (0..3) |cycle| {
        const ticket = try requestDistrict(&world, 10 + cycle * 2);
        try waitForDistrictActivation(&world, ticket);
        try std.testing.expectEqual(@as(usize, 1), world.entityCount());
        try std.testing.expectEqual(
            1 + sandbox_contracts.district_static_box_count,
            world.bodyCount(),
        );
        try unloadDistrict(&world, 11 + cycle * 2, ticket);
        try std.testing.expectEqual(@as(usize, 0), world.entityCount());
        try std.testing.expectEqual(@as(u32, 1), world.bodyCount());
    }
}

test "CharacterVirtual leaves removed district support without stale ground state" {
    var world = try simulation.Simulation.init(std.testing.allocator, .{
        .namespace = 803,
    });
    defer world.deinit();
    const ticket = try requestDistrict(&world, 1);
    try waitForDistrictActivation(&world, ticket);

    try world.submitCharacter(.{ .spawn = .{
        .request_id = 2,
        .position = .{ -5.5, 6, -66 },
    } });
    try world.tick();
    const character_id = world.pollCharacterOutcome().?.spawned.id;
    while (world.pollCharacterEvent() != null) {}
    for (0..360) |_| try world.tick();
    const supported = try world.character(character_id);
    try std.testing.expectEqual(engine.physics.GroundState.on_ground, supported.ground_state);
    try std.testing.expect(supported.position[1] > 1.9);
    try std.testing.expect(supported.position[1] < 2.1);

    try unloadDistrict(&world, 3, ticket);
    const after_unload = try world.character(character_id);
    try std.testing.expect(after_unload.ground_state != .on_ground);
    for (0..120) |_| try world.tick();
    try std.testing.expect(
        (try world.character(character_id)).position[1] < supported.position[1] - 3,
    );
    try world.submitCharacter(.{ .despawn = .{ .id = character_id } });
    try world.tick();
    _ = world.pollCharacterOutcome();
    try std.testing.expectEqual(@as(usize, 0), world.entityCount());
    try std.testing.expectEqual(@as(u32, 1), world.bodyCount());
}

test "active district Snapshot V11 restore is byte-stable and rebuilds logical ownership" {
    const allocator = std.testing.allocator;
    var bytes: []u8 = undefined;
    {
        var original = try simulation.Simulation.init(allocator, .{
            .namespace = 802,
            .create_ground = false,
        });
        defer original.deinit();
        const ticket = try requestDistrict(&original, 1);
        try waitForDistrictActivation(&original, ticket);
        bytes = try original.save(allocator);
        const repeated = try original.save(allocator);
        defer allocator.free(repeated);
        try std.testing.expectEqualSlices(u8, bytes, repeated);
    }
    defer allocator.free(bytes);

    var restored = try simulation.Simulation.fromSnapshot(allocator, bytes, .{
        .create_ground = false,
        .district_assets = district_test_assets,
    });
    defer restored.deinit();
    try std.testing.expectEqual(@as(usize, 1), restored.districtCount());
    try std.testing.expectEqual(@as(usize, 1), restored.entityCount());
    try std.testing.expectEqual(
        sandbox_contracts.district_static_box_count,
        restored.bodyCount(),
    );
    const draw = (try restored.districtPresentation())[0];
    try std.testing.expectEqual(district_test_assets.scene, draw.assets.scene);
    const resaved = try restored.save(allocator);
    defer allocator.free(resaved);
    try std.testing.expectEqualSlices(u8, bytes, resaved);
}

const s4c_namespace: u64 = 840;
const s4c_tick_count: usize = 181;
const s4c_crate_id = engine.PersistentId{ .namespace = s4c_namespace, .local = 1 };
const s4c_character_id = engine.PersistentId{ .namespace = s4c_namespace, .local = 2 };
const s4c_vehicle_id = engine.PersistentId{ .namespace = s4c_namespace, .local = 3 };
const s4c_district_id = engine.PersistentId{ .namespace = s4c_namespace, .local = 4 };

fn makeS4cScenarioSnapshot(allocator: std.mem.Allocator) ![]u8 {
    const crate_records = [_]crate_contract.CrateV1{.{
        .id = s4c_crate_id,
        .half_extents = .{ 0.5, 0.5, 0.5 },
        .pose = .{ .position = .{ 4, 2, 0 } },
        .linear_velocity = .{ 0, 0, 0 },
        .angular_velocity = .{ 0, 0, 0 },
    }};
    const character_records = [_]character_contract.CharacterV1{.{
        .id = s4c_character_id,
        .position = .{ 0, 0, 0 },
        .velocity = .{ 0, 0, 0 },
        .facing_yaw = 0,
    }};
    const vehicle_records = [_]vehicle_contract.VehicleV1{.{
        .id = s4c_vehicle_id,
        .chassis_pose = .{
            .position = .{ 0, 2, 0 },
            .rotation = .{ 0, 0, 0, 1 },
        },
        .linear_velocity = .{ 0, 0, 0 },
        .angular_velocity = .{ 0, 0, 0 },
        .wheels = @splat(.{ .rotation_angle = 0, .angular_velocity = 0 }),
        .input = .{ .throttle = 0, .steering = 0, .brake = 0, .hand_brake = 0 },
        .driver_id = s4c_character_id,
    }};
    const district_coord = district_contract.ChunkCoord{ .x = 0, .z = -4 };
    const build = try sandbox_contracts.proceduralDistrictBuild(district_coord);
    const district_records = [_]district_feature_contract.DistrictV1{.{
        .id = s4c_district_id,
        .coord = district_coord,
        .recipe_version = build.recipe_version,
        .checksum = build.checksum,
    }};
    return simulation_snapshot.encode(allocator, .{
        .schema_version = sandbox_contracts.snapshot_schema,
        .completed_ticks = 0,
        .fixed_delta_seconds = 1.0 / 120.0,
        .namespace = s4c_namespace,
        .next_local_id = 5,
        .character_config = character_contract.CharacterConfigV1.fromConfig(.{}),
        .vehicle_config = vehicle_contract.VehicleConfigV1.fromConfig(.{}),
        .interaction_config = interaction_contract.InteractionConfigV1.fromConfig(.{}),
        .npc_config = npc_contract.NpcConfigV1.fromConfig(.{}),
        .npc_encounter_config = simulation_snapshot.NpcEncounterConfigV1.fromConfig(.{}),
        .authored_population = false,
        .navigation_gates = simulation_snapshot.initial_navigation_gates,
        .crates = &crate_records,
        .characters = &character_records,
        .vehicles = &vehicle_records,
        .districts = &district_records,
        .interactions = &.{},
        .npcs = &.{},
        .npc_encounters = &.{},
        .population = null,
    }, .{});
}

const S4cLifecycleEvidence = struct {
    crate_impulses: u64 = 0,
    vehicle_drives: u64 = 0,
    vehicle_exits: u64 = 0,
    character_events: u64 = 0,
    vehicle_events: u64 = 0,
    rejections: u64 = 0,
    unexpected: u64 = 0,
};

fn drainS4cLifecycle(
    world: *simulation.Simulation,
    evidence: *S4cLifecycleEvidence,
) void {
    while (world.pollOutcome()) |outcome| switch (outcome) {
        .impulse_applied => evidence.crate_impulses +|= 1,
        .rejected => evidence.rejections +|= 1,
        .spawned => evidence.unexpected +|= 1,
        .despawned => evidence.unexpected +|= 1,
        .relocated => evidence.unexpected +|= 1,
    };
    while (world.pollCharacterOutcome()) |outcome| switch (outcome) {
        .rejected => evidence.rejections +|= 1,
        .spawned => evidence.unexpected +|= 1,
        .despawned => evidence.unexpected +|= 1,
    };
    while (world.pollVehicleOutcome()) |outcome| switch (outcome) {
        .drive_applied => evidence.vehicle_drives +|= 1,
        .exited => evidence.vehicle_exits +|= 1,
        .abandoned => evidence.unexpected +|= 1,
        .rejected => evidence.rejections +|= 1,
        .spawned => evidence.unexpected +|= 1,
        .entered => evidence.unexpected +|= 1,
        .despawned => evidence.unexpected +|= 1,
    };
    while (world.pollDistrictOutcome()) |_| evidence.unexpected +|= 1;
    while (world.pollNpcOutcome()) |outcome| switch (outcome) {
        .rejected => evidence.rejections +|= 1,
        .spawned, .goal_set, .despawned => evidence.unexpected +|= 1,
    };
    while (world.pollCharacterEvent()) |_| evidence.character_events +|= 1;
    while (world.pollVehicleEvent()) |_| evidence.vehicle_events +|= 1;
    while (world.pollDistrictEvent()) |_| evidence.unexpected +|= 1;
    while (world.pollNpcEvent()) |_| evidence.unexpected +|= 1;
}

const runtime_phase_count = std.meta.tags(engine.Phase).len;

/// Test-only adapter for the same nonfallible runtime seam consumed by the
/// host profiler. It deliberately retains only plain counters, so evidence can
/// outlive a deinitialized one-world simulation cohort.
const S4cProfileObservation = struct {
    begins: [runtime_phase_count]u64 = @splat(0),
    ends: [runtime_phase_count]u64 = @splat(0),
    open_ticks: [runtime_phase_count]?u64 = @splat(null),
    failed_phases: u64 = 0,
    protocol_errors: u64 = 0,

    fn observer(self: *@This()) engine.PhaseObserver {
        return .{
            .context = self,
            .begin_fn = begin,
            .end_fn = end,
        };
    }

    fn begin(raw: *anyopaque, phase: engine.Phase, tick: engine.TickContext) void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        const index: usize = @intFromEnum(phase);
        if (self.open_ticks[index] != null or tick.tick_index == 0) {
            self.protocol_errors +|= 1;
        }
        self.open_ticks[index] = tick.tick_index;
        self.begins[index] +|= 1;
    }

    fn end(
        raw: *anyopaque,
        phase: engine.Phase,
        tick: engine.TickContext,
        outcome: engine.PhaseOutcome,
    ) void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        const index: usize = @intFromEnum(phase);
        if (self.open_ticks[index] == null or self.open_ticks[index].? != tick.tick_index) {
            self.protocol_errors +|= 1;
        }
        self.open_ticks[index] = null;
        self.ends[index] +|= 1;
        if (outcome == .failed) self.failed_phases +|= 1;
    }
};

const S4cDebugEvidence = struct {
    batches: u64 = 0,
    category_primitives: [engine.physics_debug.category_count]u64 = @splat(0),
    category_nonempty_batches: [engine.physics_debug.category_count]u64 = @splat(0),
    tiny_overflow_drops: u64 = 0,
    toggle_generations: u64 = 0,
};

fn retainDebugBatch(
    evidence: *S4cDebugEvidence,
    batch: engine.physics_debug.Batch,
    expected_tick: u64,
) !void {
    if (batch.completed_tick != expected_tick or batch.generation == 0) {
        return error.InvalidPhysicsDebugBatchBoundary;
    }
    evidence.batches +|= 1;
    for (batch.category_stats, 0..) |stats, index| {
        const admitted = stats.lines.admitted +| stats.triangles.admitted;
        evidence.category_primitives[index] +|= admitted;
        if (admitted != 0) evidence.category_nonempty_batches[index] +|= 1;
    }
}

fn countDebugOverflow(batch: engine.physics_debug.Batch) u64 {
    var total: u64 = 0;
    for (batch.category_stats) |stats| {
        total +|= stats.lines.overflow_dropped;
        total +|= stats.triangles.overflow_dropped;
    }
    return total;
}

const S4cFinalState = struct {
    diagnostics: sandbox_diagnostics.Diagnostics,
    crate: crate_contract.CrateView,
    character: character_contract.CharacterView,
    vehicle: vehicle_contract.VehicleView,
    district_state: district_feature_contract.StateTag,
    district_ticket: ?district_contract.LoadTicket,
    district_count: usize,
    district_body_count: usize,
    entity_count: usize,
    body_count: u32,
    active_body_count: u32,
};

const S4cCohortEvidence = struct {
    save_bytes: []u8,
    digests: [s4c_tick_count]engine.contracts.replay.TickDigests,
    post_instrumentation_digest: engine.contracts.replay.TickDigests,
    state: S4cFinalState,
    lifecycle: S4cLifecycleEvidence,
    debug: S4cDebugEvidence,
    profile: S4cProfileObservation,

    fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.save_bytes);
        self.* = undefined;
    }
};

fn runS4cCohort(
    allocator: std.mem.Allocator,
    snapshot: []const u8,
    observed: bool,
) !S4cCohortEvidence {
    var world = try simulation.Simulation.fromSnapshot(allocator, snapshot, .{
        .max_crates = 4,
        .district_assets = district_test_assets,
    });
    defer world.deinit();

    var digest_scratch = try simulation.DigestScratch.init(
        allocator,
        world.requiredDigestIdentityCapacity(),
    );
    defer digest_scratch.deinit();

    const line_storage = try allocator.alloc(engine.physics_debug.Line, 16_384);
    defer allocator.free(line_storage);
    const triangle_storage = try allocator.alloc(engine.physics_debug.Triangle, 8_192);
    defer allocator.free(triangle_storage);
    var debug_storage = engine.physics_debug.Storage.init(
        line_storage,
        triangle_storage,
    );

    var digests: [s4c_tick_count]engine.contracts.replay.TickDigests = undefined;
    var lifecycle = S4cLifecycleEvidence{};
    var debug = S4cDebugEvidence{};
    var profile = S4cProfileObservation{};

    for (0..s4c_tick_count) |index| {
        if (index == 60) {
            try world.submit(.{ .impulse = .{
                .id = s4c_crate_id,
                .impulse = .{ 0, 2, 0 },
            } });
        }
        if (index >= 120 and index < 180) {
            try world.submitVehicle(.{ .drive = .{
                .vehicle_id = s4c_vehicle_id,
                .driver_id = s4c_character_id,
                .input = .{ .throttle = 0.7 },
            } });
        } else if (index == 180) {
            try world.submitVehicle(.{ .exit = .{
                .vehicle_id = s4c_vehicle_id,
                .driver_id = s4c_character_id,
            } });
        }

        if (observed) {
            try world.tickObserved(profile.observer());
            const batch = try world.extractPhysicsDebug(.{}, &debug_storage);
            try retainDebugBatch(&debug, batch, world.tickIndex());
        } else {
            try world.tick();
        }
        digests[index] = try world.logicalDigests(&digest_scratch);
        drainS4cLifecycle(&world, &lifecycle);
    }

    if (observed) {
        var tiny_lines: [1]engine.physics_debug.Line = undefined;
        var tiny_triangles: [1]engine.physics_debug.Triangle = undefined;
        var tiny_storage = engine.physics_debug.Storage.init(
            &tiny_lines,
            &tiny_triangles,
        );
        const tiny = try world.extractPhysicsDebug(.{}, &tiny_storage);
        debug.tiny_overflow_drops = countDebugOverflow(tiny);

        var toggle_lines: [8]engine.physics_debug.Line = undefined;
        var toggle_triangles: [8]engine.physics_debug.Triangle = undefined;
        var toggle_storage = engine.physics_debug.Storage.init(
            &toggle_lines,
            &toggle_triangles,
        );
        const disabled = engine.physics_debug.Config{
            .shapes = false,
            .bounds = false,
            .contacts = false,
            .centers_of_mass = false,
            .velocities = false,
        };
        for (0..100) |index| {
            const enabled = index % 2 == 0;
            const batch = try world.extractPhysicsDebug(
                if (enabled) .{} else disabled,
                &toggle_storage,
            );
            if (enabled) {
                if (batch.lines.len == 0 or batch.triangles.len == 0) {
                    return error.EnabledPhysicsDebugBatchEmpty;
                }
            } else if (batch.lines.len != 0 or batch.triangles.len != 0) {
                return error.DisabledPhysicsDebugBatchNotEmpty;
            }
        }
        debug.toggle_generations = toggle_storage.batch().?.generation;
    }

    const post_instrumentation_digest = try world.logicalDigests(&digest_scratch);
    const save_bytes = try world.save(allocator);
    errdefer allocator.free(save_bytes);
    return .{
        .save_bytes = save_bytes,
        .digests = digests,
        .post_instrumentation_digest = post_instrumentation_digest,
        .state = .{
            .diagnostics = world.diagnostics(),
            .crate = try world.crate(s4c_crate_id),
            .character = try world.character(s4c_character_id),
            .vehicle = try world.vehicle(s4c_vehicle_id),
            .district_state = world.districtStateFor(district_test_coord).?,
            .district_ticket = world.activeDistrictTicketFor(district_test_coord),
            .district_count = world.districtCount(),
            .district_body_count = world.districtBodyCount(),
            .entity_count = world.entityCount(),
            .body_count = world.bodyCount(),
            .active_body_count = world.activeBodyCount(),
        },
        .lifecycle = lifecycle,
        .debug = debug,
        .profile = profile,
    };
}

test "S4-C headless debug extraction and profile observation preserve authority" {
    const allocator = std.testing.allocator;
    const snapshot = try makeS4cScenarioSnapshot(allocator);
    defer allocator.free(snapshot);

    // The zflecs/Jolt composition admits one world per process. Each helper
    // destroys its world before returning only copy-safe evidence, so these
    // cohorts are deliberately sequential rather than simultaneously alive.
    var plain = try runS4cCohort(allocator, snapshot, false);
    defer plain.deinit(allocator);
    var observed = try runS4cCohort(allocator, snapshot, true);
    defer observed.deinit(allocator);

    try std.testing.expectEqualDeep(plain.digests, observed.digests);
    try std.testing.expectEqualDeep(
        plain.post_instrumentation_digest,
        observed.post_instrumentation_digest,
    );
    try std.testing.expectEqualSlices(u8, plain.save_bytes, observed.save_bytes);
    try std.testing.expectEqualDeep(plain.state, observed.state);
    try std.testing.expectEqualDeep(plain.lifecycle, observed.lifecycle);

    try std.testing.expectEqual(@as(u64, 0), plain.debug.batches);
    try std.testing.expectEqual(@as(u64, s4c_tick_count), observed.debug.batches);
    for (observed.debug.category_primitives) |count| {
        try std.testing.expect(count > 0);
    }
    for (observed.debug.category_nonempty_batches) |count| {
        try std.testing.expect(count > 0);
    }
    try std.testing.expect(observed.debug.tiny_overflow_drops > 0);
    try std.testing.expectEqual(@as(u64, 100), observed.debug.toggle_generations);

    try std.testing.expectEqual(@as(u64, 0), observed.profile.failed_phases);
    try std.testing.expectEqual(@as(u64, 0), observed.profile.protocol_errors);
    for (observed.profile.begins, observed.profile.ends) |begins, ends| {
        try std.testing.expectEqual(@as(u64, s4c_tick_count), begins);
        try std.testing.expectEqual(begins, ends);
    }
    for (observed.profile.open_ticks) |open_tick| {
        try std.testing.expect(open_tick == null);
    }

    try std.testing.expectEqual(@as(u64, 1), observed.lifecycle.crate_impulses);
    try std.testing.expectEqual(@as(u64, 60), observed.lifecycle.vehicle_drives);
    try std.testing.expectEqual(@as(u64, 1), observed.lifecycle.vehicle_exits);
    try std.testing.expectEqual(@as(u64, 0), observed.lifecycle.rejections);
    try std.testing.expectEqual(@as(u64, 0), observed.lifecycle.unexpected);
    switch (observed.state.character.driver_mode) {
        .on_foot => {},
        .driving => return error.CharacterStillDrivingAfterExit,
    }
    try std.testing.expect(observed.state.vehicle.driver_id == null);
    try std.testing.expectEqual(
        district_feature_contract.StateTag.active,
        observed.state.district_state,
    );
    try std.testing.expect(observed.state.district_ticket != null);
    try std.testing.expectEqual(@as(usize, 1), observed.state.district_count);
    try std.testing.expectEqual(
        @as(usize, sandbox_contracts.district_static_box_count),
        observed.state.district_body_count,
    );
    try std.testing.expectEqual(@as(usize, 4), observed.state.entity_count);
    try std.testing.expectEqual(
        3 + sandbox_contracts.district_static_box_count,
        observed.state.body_count,
    );
}

test "S5 crate authoring edit undo redo and cold restore are coherent" {
    const allocator = std.testing.allocator;
    var world = try simulation.Simulation.init(allocator, .{
        .namespace = 5_005,
        .max_crates = 4,
    });
    var world_live = true;
    defer if (world_live) world.deinit();

    try world.submit(.{ .spawn = .{
        .request_id = 1,
        .pose = .{ .position = .{ 0, 2, 0 } },
        .velocity = .{ .linear = .{ 1, 0, 0 } },
    } });
    try world.tick();
    const id = switch (world.pollOutcome() orelse return error.MissingCrateSpawn) {
        .spawned => |spawned| spawned.id,
        else => return error.UnexpectedCrateOutcome,
    };
    const before = try world.crate(id);

    var authoring_transactions = authoring.TransactionSequencer{};
    var controller = authoring.DefaultController.init(&authoring_transactions);
    try controller.select(id);
    const edit = try controller.beginEdit(.{
        .id = id,
        .target_pose = .{
            .position = .{ 5, 3, -2 },
            .rotation = .{ 0, 0.70710677, 0, 0.70710677 },
        },
        .velocity = .zero,
    }, before.authoring_revision);
    try world.submit(edit);
    try world.tick();
    const edit_outcome = world.pollOutcome() orelse return error.MissingRelocationOutcome;
    const authored_before = switch (edit_outcome) {
        .relocated => |relocated| relocated.before,
        else => return error.UnexpectedCrateOutcome,
    };
    try std.testing.expectEqual(
        authoring.ObserveResult.applied,
        try controller.observe(edit_outcome),
    );
    const edited = try world.crate(id);
    try std.testing.expectEqualDeep(edit.relocate.target_pose, edited.state.pose);
    try std.testing.expectEqualDeep(engine.physics.Velocity{}, edited.state.velocity);
    try std.testing.expectEqual(@as(u64, 1), edited.authoring_revision);
    for ([_]f32{ 0, 0.5, 1 }) |alpha| {
        const draw = (try world.presentation(alpha))[0];
        try std.testing.expectEqualDeep(edited.state.pose, draw.pose);
    }

    // Ordinary dynamics may move the crate, but do not advance the authoring
    // revision or make the inverse command stale.
    try world.tick();
    try std.testing.expectEqual(@as(u64, 1), (try world.crate(id)).authoring_revision);

    const undo = try controller.beginUndo();
    try world.submit(undo);
    try world.tick();
    try std.testing.expectEqual(
        authoring.ObserveResult.applied,
        try controller.observe(world.pollOutcome() orelse return error.MissingUndoOutcome),
    );
    const undone = try world.crate(id);
    try std.testing.expectEqualDeep(authored_before, undone.state);
    try std.testing.expectEqual(@as(u64, 2), undone.authoring_revision);

    const redo = try controller.beginRedo();
    try world.submit(redo);
    try world.tick();
    try std.testing.expectEqual(
        authoring.ObserveResult.applied,
        try controller.observe(world.pollOutcome() orelse return error.MissingRedoOutcome),
    );
    const redone = try world.crate(id);
    try std.testing.expectEqualDeep(edited.state, redone.state);
    try std.testing.expectEqual(@as(u64, 3), redone.authoring_revision);

    const saved = try world.save(allocator);
    world.deinit();
    world_live = false;
    defer allocator.free(saved);

    var restored = try simulation.Simulation.fromSnapshot(allocator, saved, .{
        .max_crates = 4,
    });
    defer restored.deinit();
    const restored_view = try restored.crate(id);
    try std.testing.expectEqualDeep(redone.state, restored_view.state);
    // Authoring concurrency is session-local and intentionally cold-reset.
    try std.testing.expectEqual(@as(u64, 0), restored_view.authoring_revision);
    controller.resetForRestore();
    try std.testing.expect(controller.snapshot().selected == null);
    try std.testing.expectEqual(@as(u16, 0), controller.snapshot().undo_count);

    const resaved = try restored.save(allocator);
    defer allocator.free(resaved);
    try std.testing.expectEqualSlices(u8, saved, resaved);
}

test "all imported sandbox module tests are discovered" {
    std.testing.refAllDecls(simulation);
    std.testing.refAllDecls(authoring);
}
