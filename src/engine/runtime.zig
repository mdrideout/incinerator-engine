//! Thin, deterministic runtime for feature-oriented simulation slices.

const std = @import("std");
const flecs = @import("zflecs");
const identity_module = @import("engine_contracts").identity;
const diagnostic_contract = @import("engine_contracts").diagnostics;
const diagnostic_module = @import("diagnostics.zig");

pub const PersistentId = identity_module.PersistentId;

pub const RuntimeId = struct {
    runtime_token: u64,
    serial: u64,
};
const PersistentIdentity = struct { id: PersistentId };

var runtime_token_mutex: std.atomic.Mutex = .unlocked;
var next_runtime_token: u64 = 1;
var owned_world_mutex: std.atomic.Mutex = .unlocked;
var owned_world_live: bool = false;

pub const Phase = enum(u8) {
    commands,
    pre_physics,
    physics,
    post_physics,
};

pub const TickContext = struct {
    tick_index: u64,
    delta_seconds: f32,
};

/// Optional nonfallible observation seam for host-owned profiling. The
/// runtime owns phase ordering and authority; an observer may timestamp the
/// immutable phase/tick values but cannot reject, defer, or mutate a phase.
pub const PhaseOutcome = enum(u8) {
    succeeded,
    failed,
};

pub const PhaseObserver = struct {
    context: *anyopaque,
    begin_fn: *const fn (*anyopaque, Phase, TickContext) void,
    end_fn: *const fn (*anyopaque, Phase, TickContext, PhaseOutcome) void,

    fn begin(self: PhaseObserver, phase: Phase, tick: TickContext) void {
        self.begin_fn(self.context, phase, tick);
    }

    fn end(
        self: PhaseObserver,
        phase: Phase,
        tick: TickContext,
        outcome: PhaseOutcome,
    ) void {
        self.end_fn(self.context, phase, tick, outcome);
    }
};

pub const DiagnosticJournal = diagnostic_module.DefaultJournal;
pub const DiagnosticEntry = diagnostic_contract.Entry;
pub const DiagnosticFreezeMatch = diagnostic_module.FreezeMatch;
pub const DiagnosticAppendResult = diagnostic_module.AppendResult;
pub const max_fault_name_bytes: usize = 96;
pub const RuntimeErrorCode = @TypeOf(@intFromError(error.RuntimeFaulted));

comptime {
    if (max_fault_name_bytes > std.math.maxInt(u8)) {
        @compileError("fault text length no longer fits its fixed-size length field");
    }
}

/// Fixed owned text retained after the failing callback returns. Truncation is
/// explicit, so diagnostics never imply that a clipped system/error name was
/// complete.
pub const FaultText = struct {
    bytes: [max_fault_name_bytes]u8 = [_]u8{0} ** max_fault_name_bytes,
    len: u8 = 0,
    truncated: bool = false,

    pub fn copy(value: []const u8) FaultText {
        var result = FaultText{};
        const copy_len = @min(value.len, max_fault_name_bytes);
        @memcpy(result.bytes[0..copy_len], value[0..copy_len]);
        result.len = @intCast(copy_len);
        result.truncated = value.len > copy_len;
        return result;
    }

    pub fn slice(self: *const FaultText) []const u8 {
        return self.bytes[0..self.len];
    }
};

/// The first scheduled infrastructure failure is immutable for the remainder
/// of a runtime's life. It is returned by copy, never as mutable runtime state.
pub const RuntimeFault = struct {
    phase: Phase,
    tick_index: u64,
    journal_sequence: u64,
    error_code: RuntimeErrorCode,
    system_name: FaultText,
    error_name: FaultText,
};

pub const SystemCallback = *const fn (
    context: *anyopaque,
    runtime: *Runtime,
    tick: TickContext,
) anyerror!void;

const System = struct {
    phase: Phase,
    name: []u8,
    context: *anyopaque,
    callback: SystemCallback,
};

pub const Config = struct {
    namespace: u64,
    fixed_delta_seconds: f32,
    next_local_id: u64 = 1,
    completed_ticks: u64 = 0,
};

const Lifecycle = enum { registering, ready, ticking, faulted, deinitialized };

/// Opaque capability for one registration-only restore batch. A failed batch
/// may use this checkpoint to release only the persistent-ID tombstones it
/// issued and restore the identity-source cursor without recycling identities
/// from an already-committed batch.
pub const RegistrationRestoreCheckpoint = struct {
    runtime_token: u64,
    sequence: u64,
};

const ActiveRegistrationRestore = struct {
    sequence: u64,
    identity_source: identity_module.IdentitySource,
    issued_identity_count: usize,
};

const State = struct {
    gpa: std.mem.Allocator,
    world: *flecs.world_t,
    identities: std.AutoHashMap(PersistentId, RuntimeId),
    entities: std.AutoHashMap(u64, flecs.entity_t),
    issued_identities: std.AutoHashMap(PersistentId, void),
    registration_restore_ids: std.ArrayListUnmanaged(PersistentId) = .empty,
    active_registration_restore: ?ActiveRegistrationRestore = null,
    next_registration_restore_sequence: u64 = 1,
    identity_source: identity_module.IdentitySource,
    runtime_token: u64,
    owner_thread: std.Thread.Id,
    next_entity_serial: u64 = 1,
    systems: std.ArrayListUnmanaged(System) = .empty,
    fixed_delta_seconds: f32,
    completed_ticks: u64,
    tracked_entity_count: usize = 0,
    journal: DiagnosticJournal,
    first_fault: ?RuntimeFault = null,
    lifecycle: Lifecycle = .registering,
};

pub const Runtime = struct {
    /// Type-erased private state keeps Flecs and mutable bookkeeping out of
    /// the public engine layout. All access is centralized below.
    storage: *anyopaque,

    fn statePtr(self: *const Runtime) *State {
        return @ptrCast(@alignCast(self.storage));
    }

    pub fn init(gpa: std.mem.Allocator, config: Config) !Runtime {
        try validateConfig(config);
        try acquireOwnedWorldLease();
        errdefer releaseOwnedWorldLease();
        const world = flecs.init();
        errdefer _ = flecs.fini(world);
        const state = try gpa.create(State);
        errdefer gpa.destroy(state);
        state.* = .{
            .gpa = gpa,
            .world = world,
            .identities = std.AutoHashMap(PersistentId, RuntimeId).init(gpa),
            .entities = std.AutoHashMap(u64, flecs.entity_t).init(gpa),
            .issued_identities = std.AutoHashMap(PersistentId, void).init(gpa),
            .identity_source = try identity_module.IdentitySource.initAt(
                config.namespace,
                config.next_local_id,
            ),
            .runtime_token = try allocateRuntimeToken(),
            .owner_thread = std.Thread.getCurrentId(),
            .fixed_delta_seconds = config.fixed_delta_seconds,
            .completed_ticks = config.completed_ticks,
            .journal = DiagnosticJournal.init(),
        };
        const result = Runtime{ .storage = state };
        flecs.COMPONENT(result.statePtr().world, PersistentIdentity);
        return result;
    }

    pub fn deinit(self: *Runtime) void {
        self.assertOwnerThread();
        if (self.statePtr().lifecycle == .deinitialized or
            self.statePtr().lifecycle == .ticking)
        {
            @panic("runtime deinitialized from an invalid lifecycle state");
        }
        // Features remove bodies before their corresponding entities.
        if (self.statePtr().tracked_entity_count != 0 or
            self.statePtr().identities.count() != 0 or
            self.statePtr().entities.count() != 0)
        {
            @panic("runtime deinitialized with live feature entities");
        }
        for (self.statePtr().systems.items) |system| self.statePtr().gpa.free(system.name);
        self.statePtr().systems.deinit(self.statePtr().gpa);
        self.statePtr().identities.deinit();
        self.statePtr().entities.deinit();
        self.statePtr().issued_identities.deinit();
        self.statePtr().registration_restore_ids.deinit(self.statePtr().gpa);
        _ = flecs.fini(self.statePtr().world);
        releaseOwnedWorldLease();
        self.statePtr().lifecycle = .deinitialized;
        const state = self.statePtr();
        state.gpa.destroy(state);
        self.* = undefined;
    }

    pub fn allocator(self: *const Runtime) std.mem.Allocator {
        self.assertOwnerThread();
        return self.statePtr().gpa;
    }

    pub fn ensureHealthy(self: *const Runtime) !void {
        try self.requireOwnerThread();
        if (self.statePtr().lifecycle == .deinitialized) return error.RuntimeDeinitialized;
        if (self.statePtr().lifecycle == .faulted) return error.RuntimeFaulted;
    }

    pub fn isFaulted(self: *const Runtime) bool {
        self.assertOwnerThread();
        return self.statePtr().lifecycle == .faulted;
    }

    /// Return an immutable copy so callers cannot mutate or outlive private
    /// runtime storage accidentally.
    pub fn firstFault(self: *const Runtime) ?RuntimeFault {
        self.assertOwnerThread();
        return self.statePtr().first_fault;
    }

    /// Borrowed read-only journal access. The view APIs on the journal retain
    /// their owner-thread and mutation-lifetime contracts.
    pub fn diagnosticJournal(self: *const Runtime) *const DiagnosticJournal {
        self.assertOwnerThread();
        return &self.statePtr().journal;
    }

    /// Shared owner-thread admission point for runtime, feature, adapter, and
    /// host diagnostics. It performs no allocation and cannot return an error;
    /// bounded rejection is represented by the returned value and statistics.
    pub fn recordDiagnostic(
        self: *Runtime,
        entry: DiagnosticEntry,
    ) DiagnosticAppendResult {
        self.assertOwnerThread();
        return self.statePtr().journal.append(entry);
    }

    pub fn armDiagnosticFreeze(self: *Runtime, condition: DiagnosticFreezeMatch) void {
        self.assertOwnerThread();
        self.statePtr().journal.armFreeze(condition);
    }

    pub fn disarmDiagnosticFreeze(self: *Runtime) bool {
        self.assertOwnerThread();
        return self.statePtr().journal.disarmFreeze();
    }

    pub fn resumeDiagnosticCapture(self: *Runtime) bool {
        self.assertOwnerThread();
        return self.statePtr().journal.resumeCapture();
    }

    pub fn clearDiagnostics(self: *Runtime) void {
        self.assertOwnerThread();
        self.statePtr().journal.clear();
    }

    pub fn ensureSnapshotBoundary(self: *const Runtime) !void {
        try self.ensureHealthy();
        if (self.statePtr().lifecycle == .ticking) return error.TickInProgress;
    }

    /// Owner-thread inspection/serialization boundary that remains available
    /// after an immutable runtime fault. It never permits observation while a
    /// tick is executing and does not make the runtime healthy again.
    pub fn ensureStoppedInspectionBoundary(self: *const Runtime) !void {
        try self.requireOwnerThread();
        return switch (self.statePtr().lifecycle) {
            .ticking => error.TickInProgress,
            .deinitialized => error.RuntimeDeinitialized,
            .registering, .ready, .faulted => {},
        };
    }

    /// Commands submitted while a tick is executing target the following
    /// tick, independent of system registration order within `.commands`.
    pub fn commandTargetTick(self: *const Runtime) !u64 {
        try self.ensureHealthy();
        const offset: u64 = if (self.statePtr().lifecycle == .ticking) 2 else 1;
        return std.math.add(u64, self.statePtr().completed_ticks, offset) catch
            error.TickCounterExhausted;
    }

    pub fn registry(self: *Runtime) FeatureRegistry {
        self.assertOwnerThread();
        return .{ .runtime = self };
    }

    pub fn finishRegistration(self: *Runtime) void {
        self.assertOwnerThread();
        if (self.statePtr().lifecycle == .registering) {
            if (self.statePtr().active_registration_restore != null) {
                @panic("runtime registration finished with an open restore transaction");
            }
            // Explicit restore IDs are accepted only during registration.
            // Automatic runtime IDs are monotonic, so retaining restore
            // tombstones after this boundary would make normal churn leak.
            self.statePtr().issued_identities.clearAndFree();
            self.statePtr().lifecycle = .ready;
        }
    }

    pub fn tick(self: *Runtime) !void {
        return self.tickObserved(null);
    }

    pub fn tickObserved(self: *Runtime, observer: ?PhaseObserver) !void {
        try self.requireOwnerThread();
        if (self.statePtr().lifecycle == .deinitialized) return error.RuntimeDeinitialized;
        if (self.statePtr().lifecycle == .ticking) return error.ReentrantTick;
        if (self.statePtr().lifecycle == .faulted) return error.RuntimeFaulted;
        self.finishRegistration();

        const next_tick = std.math.add(u64, self.statePtr().completed_ticks, 1) catch
            return error.TickCounterExhausted;
        const context = TickContext{
            .tick_index = next_tick,
            .delta_seconds = self.statePtr().fixed_delta_seconds,
        };

        self.statePtr().lifecycle = .ticking;
        self.runObservedPhase(.commands, context, observer) catch |err| {
            self.statePtr().lifecycle = .faulted;
            return err;
        };
        self.runObservedPhase(.pre_physics, context, observer) catch |err| {
            self.statePtr().lifecycle = .faulted;
            return err;
        };
        self.runObservedPhase(.physics, context, observer) catch |err| {
            self.statePtr().lifecycle = .faulted;
            return err;
        };
        self.runObservedPhase(.post_physics, context, observer) catch |err| {
            self.statePtr().lifecycle = .faulted;
            return err;
        };
        self.statePtr().completed_ticks = next_tick;
        self.statePtr().lifecycle = .ready;
    }

    fn runObservedPhase(
        self: *Runtime,
        phase: Phase,
        context: TickContext,
        observer: ?PhaseObserver,
    ) !void {
        if (observer) |sink| sink.begin(phase, context);
        self.runPhase(phase, context) catch |err| {
            if (observer) |sink| sink.end(phase, context, .failed);
            return err;
        };
        if (observer) |sink| sink.end(phase, context, .succeeded);
    }

    fn runPhase(self: *Runtime, phase: Phase, context: TickContext) !void {
        for (self.statePtr().systems.items) |system| {
            if (system.phase == phase) {
                system.callback(system.context, self, context) catch |err| {
                    self.captureFirstFault(phase, system.name, context.tick_index, err);
                    return err;
                };
            }
        }
    }

    fn captureFirstFault(
        self: *Runtime,
        phase: Phase,
        system_name: []const u8,
        tick_index: u64,
        err: anyerror,
    ) void {
        if (self.statePtr().first_fault != null) return;
        const result = self.recordDiagnostic(.{
            .severity = .fatal,
            .category = .runtime,
            .code = diagnostic_contract.codes.runtime_system_fault,
            .tick_index = tick_index,
            .thread_role = .simulation,
            .thread_id = diagnostic_module.currentThreadId(),
            .correlation_id = self.statePtr().runtime_token,
        });
        _ = self.statePtr().journal.forceFreeze();
        // A prior conditional capture may already have frozen the journal.
        // The separately retained fault remains authoritative in that case.
        const journal_sequence = if (result.accepted) result.sequence else 0;
        self.statePtr().first_fault = .{
            .phase = phase,
            .tick_index = tick_index,
            .journal_sequence = journal_sequence,
            .error_code = @intFromError(err),
            .system_name = FaultText.copy(system_name),
            .error_name = FaultText.copy(@errorName(err)),
        };
    }

    pub fn create(self: *Runtime) !RuntimeId {
        try self.ensureHealthy();
        if (self.statePtr().lifecycle == .registering) {
            try self.statePtr().issued_identities.ensureUnusedCapacity(1);
            if (self.statePtr().active_registration_restore != null) {
                try self.statePtr().registration_restore_ids.ensureUnusedCapacity(
                    self.statePtr().gpa,
                    1,
                );
            }
            // Reserve every fallible index allocation before consuming the
            // automatic persistent ID. If a later creation stage fails, the
            // already-reserved registration tombstone retires that ID.
            try self.statePtr().identities.ensureUnusedCapacity(1);
            try self.statePtr().entities.ensureUnusedCapacity(1);
        }
        const id = try self.statePtr().identity_source.next();
        return self.createWithPersistentIdInternal(id, false);
    }

    pub fn createWithPersistentId(self: *Runtime, id: PersistentId) !RuntimeId {
        try self.ensureHealthy();
        if (self.statePtr().lifecycle != .registering) return error.RestoreIdentityOutsideRegistration;
        try self.statePtr().issued_identities.ensureUnusedCapacity(1);
        if (self.statePtr().active_registration_restore != null) {
            try self.statePtr().registration_restore_ids.ensureUnusedCapacity(
                self.statePtr().gpa,
                1,
            );
        }
        return self.createWithPersistentIdInternal(id, true);
    }

    fn createWithPersistentIdInternal(
        self: *Runtime,
        id: PersistentId,
        observe_identity: bool,
    ) !RuntimeId {
        try self.requireLive();
        try id.validate();
        if (id.namespace != self.statePtr().identity_source.namespace) {
            return error.ForeignIdentityNamespace;
        }
        const track_registration_identity = observe_identity or
            self.statePtr().lifecycle == .registering;
        if (track_registration_identity and self.statePtr().issued_identities.contains(id)) {
            return error.PersistentIdAlreadyIssued;
        }
        if (self.statePtr().identities.contains(id)) return error.DuplicatePersistentId;

        try self.statePtr().identities.ensureUnusedCapacity(1);
        try self.statePtr().entities.ensureUnusedCapacity(1);

        if (track_registration_identity) {
            const issued_entry = self.statePtr().issued_identities.getOrPutAssumeCapacity(id);
            if (issued_entry.found_existing) return error.PersistentIdAlreadyIssued;
            if (self.statePtr().active_registration_restore != null) {
                self.statePtr().registration_restore_ids.appendAssumeCapacity(id);
            }
        }

        const entity = flecs.new_id(self.statePtr().world);
        if (entity == 0) return error.EntityCreationFailed;
        errdefer flecs.delete(self.statePtr().world, entity);
        if (flecs.set(self.statePtr().world, entity, PersistentIdentity, .{ .id = id }) == 0) {
            return error.IdentityComponentSetFailed;
        }

        if (self.statePtr().next_entity_serial == 0) return error.EntitySerialExhausted;
        const entity_serial = self.statePtr().next_entity_serial;
        self.statePtr().next_entity_serial +%= 1;
        const runtime_id = RuntimeId{
            .runtime_token = self.statePtr().runtime_token,
            .serial = entity_serial,
        };

        self.statePtr().identities.putAssumeCapacityNoClobber(id, runtime_id);
        self.statePtr().entities.putAssumeCapacityNoClobber(entity_serial, entity);
        if (observe_identity) self.statePtr().identity_source.observe(id) catch unreachable;
        self.statePtr().tracked_entity_count += 1;
        return runtime_id;
    }

    pub fn destroy(self: *Runtime, runtime_id: RuntimeId) !void {
        try self.requireLive();
        const entity = try self.rawEntity(runtime_id);
        const persistent = flecs.get(self.statePtr().world, entity, PersistentIdentity) orelse
            return error.EntityMissingPersistentIdentity;
        const persistent_id = persistent.id;
        const indexed = self.statePtr().identities.get(persistent_id) orelse
            return error.PersistentIndexInvariantBroken;
        if (!std.meta.eql(indexed, runtime_id)) return error.PersistentIndexInvariantBroken;
        flecs.delete(self.statePtr().world, entity);
        const removed_identity = self.statePtr().identities.remove(persistent_id);
        const removed_entity = self.statePtr().entities.remove(runtime_id.serial);
        if (!removed_identity or !removed_entity) {
            @panic("runtime index removal invariant failed");
        }
        std.debug.assert(self.statePtr().tracked_entity_count > 0);
        self.statePtr().tracked_entity_count -= 1;
    }

    pub fn resolve(self: *const Runtime, id: PersistentId) ?RuntimeId {
        self.assertOwnerThread();
        return self.statePtr().identities.get(id);
    }

    pub fn identity(self: *const Runtime, runtime_id: RuntimeId) !PersistentId {
        const entity = try self.rawEntity(runtime_id);
        const component = flecs.get(self.statePtr().world, entity, PersistentIdentity) orelse
            return error.EntityMissingPersistentIdentity;
        return component.id;
    }

    pub fn set(self: *Runtime, runtime_id: RuntimeId, comptime T: type, value: T) !void {
        try self.ensureHealthy();
        const entity = try self.rawEntity(runtime_id);
        if (flecs.set(self.statePtr().world, entity, T, value) == 0) return error.ComponentSetFailed;
    }

    pub fn get(self: *const Runtime, runtime_id: RuntimeId, comptime T: type) ?*const T {
        self.assertOwnerThread();
        const entity = self.rawEntity(runtime_id) catch return null;
        return flecs.get(self.statePtr().world, entity, T);
    }

    pub fn getMut(self: *Runtime, runtime_id: RuntimeId, comptime T: type) ?*T {
        self.assertOwnerThread();
        self.ensureHealthy() catch return null;
        const entity = self.rawEntity(runtime_id) catch return null;
        return flecs.get_mut(self.statePtr().world, entity, T);
    }

    fn rawEntity(self: *const Runtime, runtime_id: RuntimeId) !flecs.entity_t {
        try self.requireLive();
        if (runtime_id.runtime_token != self.statePtr().runtime_token) return error.ForeignRuntimeId;
        const entity = self.statePtr().entities.get(runtime_id.serial) orelse {
            if (runtime_id.serial != 0 and
                (self.statePtr().next_entity_serial == 0 or
                    runtime_id.serial < self.statePtr().next_entity_serial))
            {
                return error.StaleRuntimeId;
            }
            return error.UntrackedRuntimeId;
        };
        if (entity == 0 or !flecs.is_alive(self.statePtr().world, entity)) return error.StaleRuntimeId;
        const persistent = flecs.get(self.statePtr().world, entity, PersistentIdentity) orelse
            return error.UntrackedRuntimeId;
        const indexed = self.statePtr().identities.get(persistent.id) orelse return error.UntrackedRuntimeId;
        if (!std.meta.eql(indexed, runtime_id)) return error.UntrackedRuntimeId;
        return entity;
    }

    pub fn entityCount(self: *const Runtime) usize {
        self.assertOwnerThread();
        return self.statePtr().tracked_entity_count;
    }

    /// Copy the live persistent identity set into caller-owned bounded scratch
    /// and sort it by the stable namespace/local key. This is intentionally a
    /// logical inspection boundary: Flecs entity IDs, RuntimeIds, hash-table
    /// iteration order, and allocator capacity never cross it.
    pub fn copyPersistentIds(
        self: *const Runtime,
        scratch: []PersistentId,
    ) ![]const PersistentId {
        try self.ensureSnapshotBoundary();
        const count = self.statePtr().identities.count();
        if (scratch.len < count) return error.IdentityScratchTooSmall;

        var index: usize = 0;
        var iterator = self.statePtr().identities.keyIterator();
        while (iterator.next()) |id| : (index += 1) scratch[index] = id.*;
        std.mem.sort(PersistentId, scratch[0..count], {}, lessThanPersistentId);
        return scratch[0..count];
    }
    pub fn persistentCount(self: *const Runtime) usize {
        self.assertOwnerThread();
        return self.statePtr().identities.count();
    }
    pub fn tickIndex(self: *const Runtime) u64 {
        self.assertOwnerThread();
        return self.statePtr().completed_ticks;
    }
    pub fn fixedDelta(self: *const Runtime) f32 {
        self.assertOwnerThread();
        return self.statePtr().fixed_delta_seconds;
    }
    pub fn namespace(self: *const Runtime) u64 {
        self.assertOwnerThread();
        return self.statePtr().identity_source.namespace;
    }
    pub fn nextLocalId(self: *const Runtime) !u64 {
        try self.requireOwnerThread();
        return self.statePtr().identity_source.cursor() orelse error.IdentitySourceExhausted;
    }

    /// Begin one registration-only restore batch. The checkpoint is runtime
    /// specific and must be committed or rolled back before another batch or
    /// the registration boundary may complete.
    pub fn beginRegistrationRestore(self: *Runtime) !RegistrationRestoreCheckpoint {
        try self.requireOwnerThread();
        if (self.statePtr().lifecycle != .registering) return error.RegistrationClosed;
        if (self.statePtr().active_registration_restore != null) {
            return error.RegistrationRestoreAlreadyActive;
        }
        if (self.statePtr().registration_restore_ids.items.len != 0) {
            return error.RegistrationRestoreLogInvariantBroken;
        }
        const sequence = self.statePtr().next_registration_restore_sequence;
        if (sequence == 0) return error.RegistrationRestoreSequenceExhausted;
        self.statePtr().next_registration_restore_sequence +%= 1;
        self.statePtr().active_registration_restore = .{
            .sequence = sequence,
            .identity_source = self.statePtr().identity_source,
            .issued_identity_count = self.statePtr().issued_identities.count(),
        };
        return .{
            .runtime_token = self.statePtr().runtime_token,
            .sequence = sequence,
        };
    }

    /// Commit a completed restore batch. Issued-ID tombstones and the observed
    /// cursor become part of the registration result.
    pub fn commitRegistrationRestore(
        self: *Runtime,
        checkpoint: RegistrationRestoreCheckpoint,
    ) !void {
        _ = try self.requireRegistrationRestore(checkpoint);
        self.statePtr().registration_restore_ids.clearRetainingCapacity();
        self.statePtr().active_registration_restore = null;
    }

    /// Roll back a failed restore batch after its caller has destroyed every
    /// entity created by the batch. Runtime/entity serials remain monotonic,
    /// while explicit-ID tombstones and the identity cursor return to their
    /// exact pre-batch state so the same validated restore may be retried.
    pub fn rollbackRegistrationRestore(
        self: *Runtime,
        checkpoint: RegistrationRestoreCheckpoint,
    ) !void {
        const active = try self.requireRegistrationRestore(checkpoint);
        for (self.statePtr().registration_restore_ids.items) |id| {
            if (self.statePtr().identities.contains(id)) {
                return error.RegistrationRestoreHasLiveEntities;
            }
        }
        const expected_count = std.math.add(
            usize,
            active.issued_identity_count,
            self.statePtr().registration_restore_ids.items.len,
        ) catch return error.RegistrationRestoreLogInvariantBroken;
        if (self.statePtr().issued_identities.count() != expected_count) {
            return error.RegistrationRestoreLogInvariantBroken;
        }
        for (self.statePtr().registration_restore_ids.items) |id| {
            if (!self.statePtr().issued_identities.remove(id)) {
                return error.RegistrationRestoreLogInvariantBroken;
            }
        }
        self.statePtr().identity_source = active.identity_source;
        self.statePtr().registration_restore_ids.clearRetainingCapacity();
        self.statePtr().active_registration_restore = null;
    }

    fn requireRegistrationRestore(
        self: *Runtime,
        checkpoint: RegistrationRestoreCheckpoint,
    ) !ActiveRegistrationRestore {
        try self.requireOwnerThread();
        if (self.statePtr().lifecycle != .registering) return error.RegistrationClosed;
        if (checkpoint.runtime_token != self.statePtr().runtime_token) {
            return error.ForeignRegistrationRestoreCheckpoint;
        }
        const active = self.statePtr().active_registration_restore orelse
            return error.RegistrationRestoreNotActive;
        if (checkpoint.sequence != active.sequence) {
            return error.StaleRegistrationRestoreCheckpoint;
        }
        return active;
    }

    /// Persistence-only cursor/clock restoration. It is legal only before the
    /// startup registry is frozen.
    pub fn restoreClock(self: *Runtime, completed_ticks: u64, next_local_id: u64) !void {
        try self.requireOwnerThread();
        if (self.statePtr().lifecycle != .registering) return error.RegistrationClosed;
        if (self.statePtr().active_registration_restore != null) {
            return error.RegistrationRestoreAlreadyActive;
        }
        const current_cursor = try self.nextLocalId();
        if (next_local_id < current_cursor) return error.IdentityCursorWouldCollide;
        self.statePtr().identity_source = try identity_module.IdentitySource.initAt(
            self.statePtr().identity_source.namespace,
            next_local_id,
        );
        self.statePtr().completed_ticks = completed_ticks;
    }

    fn requireRegistrationOpen(self: *const Runtime) !void {
        try self.requireLive();
        if (self.statePtr().lifecycle != .registering) return error.RegistrationClosed;
    }
    fn requireLive(self: *const Runtime) !void {
        try self.requireOwnerThread();
        if (self.statePtr().lifecycle == .deinitialized) return error.RuntimeDeinitialized;
    }

    pub fn ensureOwnerThread(self: *const Runtime) !void {
        try self.requireOwnerThread();
    }

    fn requireOwnerThread(self: *const Runtime) !void {
        if (std.Thread.getCurrentId() != self.statePtr().owner_thread) {
            return error.WrongRuntimeThread;
        }
    }

    pub fn assertOwnerThread(self: *const Runtime) void {
        self.requireOwnerThread() catch @panic("runtime accessed from a non-owner thread");
    }
};

fn lessThanPersistentId(_: void, lhs: PersistentId, rhs: PersistentId) bool {
    if (lhs.namespace != rhs.namespace) return lhs.namespace < rhs.namespace;
    return lhs.local < rhs.local;
}

pub const FeatureRegistry = struct {
    runtime: *Runtime,

    pub fn registerComponent(self: *FeatureRegistry, comptime T: type) !void {
        try self.runtime.requireRegistrationOpen();
        if (@sizeOf(T) == 0) {
            flecs.TAG(self.runtime.statePtr().world, T);
        } else {
            flecs.COMPONENT(self.runtime.statePtr().world, T);
        }
    }

    pub fn addSystem(
        self: *FeatureRegistry,
        phase: Phase,
        name: []const u8,
        context: *anyopaque,
        callback: SystemCallback,
    ) !void {
        try self.runtime.requireRegistrationOpen();
        if (name.len == 0) return error.EmptySystemName;
        for (self.runtime.statePtr().systems.items) |existing| {
            if (std.mem.eql(u8, existing.name, name)) return error.DuplicateSystemName;
        }
        const owned_name = try self.runtime.statePtr().gpa.dupe(u8, name);
        errdefer self.runtime.statePtr().gpa.free(owned_name);
        try self.runtime.statePtr().systems.append(self.runtime.statePtr().gpa, .{
            .phase = phase,
            .name = owned_name,
            .context = context,
            .callback = callback,
        });
    }
};

fn validateConfig(config: Config) !void {
    _ = try identity_module.IdentitySource.initAt(config.namespace, config.next_local_id);
    if (!std.math.isFinite(config.fixed_delta_seconds) or config.fixed_delta_seconds <= 0) {
        return error.InvalidFixedDelta;
    }
}

fn allocateRuntimeToken() !u64 {
    while (!runtime_token_mutex.tryLock()) std.atomic.spinLoopHint();
    defer runtime_token_mutex.unlock();
    if (next_runtime_token == 0) return error.RuntimeTokenExhausted;
    const result = next_runtime_token;
    next_runtime_token +%= 1;
    return result;
}

fn acquireOwnedWorldLease() !void {
    while (!owned_world_mutex.tryLock()) std.atomic.spinLoopHint();
    defer owned_world_mutex.unlock();
    if (owned_world_live) return error.EngineWorldAlreadyLive;
    owned_world_live = true;
}

fn releaseOwnedWorldLease() void {
    while (!owned_world_mutex.tryLock()) std.atomic.spinLoopHint();
    defer owned_world_mutex.unlock();
    if (!owned_world_live) @panic("owned world lease invariant failed");
    owned_world_live = false;
}

test "runtime separates persistent and live identity" {
    var runtime = try Runtime.init(std.testing.allocator, .{
        .namespace = 44,
        .fixed_delta_seconds = 1.0 / 120.0,
    });
    defer runtime.deinit();

    const first = try runtime.create();
    const stable = try runtime.identity(first);
    try std.testing.expectEqual(PersistentId{ .namespace = 44, .local = 1 }, stable);
    try std.testing.expectEqual(first, runtime.resolve(stable).?);
    try runtime.destroy(first);
    try std.testing.expect(runtime.resolve(stable) == null);
    try std.testing.expectError(error.StaleRuntimeId, runtime.identity(first));
    try std.testing.expectError(
        error.PersistentIdAlreadyIssued,
        runtime.createWithPersistentId(stable),
    );

    const second = try runtime.create();
    try std.testing.expectEqual(@as(u64, 2), (try runtime.identity(second)).local);
    try runtime.destroy(second);

    const restored_id = PersistentId{ .namespace = 44, .local = 20 };
    const restored = try runtime.createWithPersistentId(restored_id);
    try runtime.destroy(restored);
    try std.testing.expectError(
        error.PersistentIdAlreadyIssued,
        runtime.createWithPersistentId(restored_id),
    );
}

test "registration restore rollback releases only scoped tombstones and cursor" {
    var runtime = try Runtime.init(std.testing.allocator, .{
        .namespace = 442,
        .fixed_delta_seconds = 1.0 / 120.0,
    });
    defer runtime.deinit();

    const committed_id = PersistentId{ .namespace = 442, .local = 2 };
    const committed = try runtime.createWithPersistentId(committed_id);
    try runtime.destroy(committed);

    const retry_id = PersistentId{ .namespace = 442, .local = 20 };
    const failed_batch = try runtime.beginRegistrationRestore();
    const candidate = try runtime.createWithPersistentId(retry_id);
    try runtime.destroy(candidate);
    try std.testing.expectEqual(@as(u64, 21), try runtime.nextLocalId());
    try runtime.rollbackRegistrationRestore(failed_batch);
    try std.testing.expectEqual(@as(u64, 3), try runtime.nextLocalId());
    try std.testing.expectError(
        error.PersistentIdAlreadyIssued,
        runtime.createWithPersistentId(committed_id),
    );

    const retry_batch = try runtime.beginRegistrationRestore();
    const restored = try runtime.createWithPersistentId(retry_id);
    try runtime.commitRegistrationRestore(retry_batch);
    try std.testing.expectEqual(@as(u64, 21), try runtime.nextLocalId());
    try runtime.destroy(restored);
    try std.testing.expectError(
        error.PersistentIdAlreadyIssued,
        runtime.createWithPersistentId(retry_id),
    );
}

test "runtime rejects fallible health and restore access from a worker thread" {
    var runtime = try Runtime.init(std.testing.allocator, .{
        .namespace = 441,
        .fixed_delta_seconds = 1.0 / 120.0,
    });
    defer runtime.deinit();

    const Probe = struct {
        fn run(
            target: *Runtime,
            health_rejected: *std.atomic.Value(bool),
            restore_rejected: *std.atomic.Value(bool),
        ) void {
            target.ensureHealthy() catch |err| {
                health_rejected.store(err == error.WrongRuntimeThread, .release);
            };
            target.restoreClock(0, 1) catch |err| {
                restore_rejected.store(err == error.WrongRuntimeThread, .release);
            };
        }
    };
    var health_rejected = std.atomic.Value(bool).init(false);
    var restore_rejected = std.atomic.Value(bool).init(false);
    const thread = try std.Thread.spawn(
        .{},
        Probe.run,
        .{ &runtime, &health_rejected, &restore_rejected },
    );
    thread.join();
    try std.testing.expect(health_rejected.load(.acquire));
    try std.testing.expect(restore_rejected.load(.acquire));
    try runtime.ensureHealthy();
}

test "registration allocation failure does not consume an automatic identity" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var runtime = try Runtime.init(failing.allocator(), .{
        .namespace = 43,
        .fixed_delta_seconds = 1.0 / 60.0,
    });
    defer runtime.deinit();

    // Let the issued-ID tombstone map allocate, then fail the first runtime
    // index reservation. All index capacity must be reserved before `next()`.
    failing.fail_index = failing.alloc_index + 1;
    try std.testing.expectError(error.OutOfMemory, runtime.create());

    failing.fail_index = std.math.maxInt(usize);
    const entity = try runtime.create();
    try std.testing.expectEqual(
        PersistentId{ .namespace = 43, .local = 1 },
        try runtime.identity(entity),
    );
    try runtime.destroy(entity);
}

test "schedule is ordered and freezes before first tick" {
    var runtime = try Runtime.init(std.testing.allocator, .{
        .namespace = 1,
        .fixed_delta_seconds = 0.25,
    });
    defer runtime.deinit();
    var values: std.ArrayListUnmanaged(u8) = .empty;
    defer values.deinit(std.testing.allocator);
    const SharedCounter = struct {
        list: *std.ArrayListUnmanaged(u8),
        allocator: std.mem.Allocator,
        marker: u8,
        fn run(raw: *anyopaque, _: *Runtime, tick: TickContext) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            try std.testing.expectEqual(@as(u64, 1), tick.tick_index);
            try self.list.append(self.allocator, self.marker);
        }
    };
    var first = SharedCounter{ .list = &values, .allocator = std.testing.allocator, .marker = 1 };
    var second = SharedCounter{ .list = &values, .allocator = std.testing.allocator, .marker = 2 };
    var pre = SharedCounter{ .list = &values, .allocator = std.testing.allocator, .marker = 3 };
    var physics_step = SharedCounter{ .list = &values, .allocator = std.testing.allocator, .marker = 4 };
    var post = SharedCounter{ .list = &values, .allocator = std.testing.allocator, .marker = 5 };

    var registry = runtime.registry();
    // Register phases out of order to prove phase order is declared by the
    // runtime, while order inside one phase remains registration order.
    try registry.addSystem(.post_physics, "test.post", &post, SharedCounter.run);
    try registry.addSystem(.commands, "test.command.first", &first, SharedCounter.run);
    try registry.addSystem(.physics, "test.physics", &physics_step, SharedCounter.run);
    try registry.addSystem(.commands, "test.command.second", &second, SharedCounter.run);
    try registry.addSystem(.pre_physics, "test.pre", &pre, SharedCounter.run);
    try runtime.tick();
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5 }, values.items);
    try std.testing.expectEqual(@as(u64, 1), runtime.tickIndex());
    try std.testing.expectError(
        error.RegistrationClosed,
        registry.addSystem(.commands, "test.too-late", &first, SharedCounter.run),
    );
}

test "phase observer brackets successful and failed phases without owning authority" {
    const Edge = enum { begin, end };
    const Event = struct {
        phase: Phase,
        edge: Edge,
        outcome: ?PhaseOutcome,
        tick_index: u64,
    };
    const Recorder = struct {
        events: [8]Event = undefined,
        count: usize = 0,

        fn append(self: *@This(), event: Event) void {
            if (self.count == self.events.len) @panic("phase observer test overflow");
            self.events[self.count] = event;
            self.count += 1;
        }

        fn onBegin(raw: *anyopaque, phase: Phase, tick: TickContext) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.append(.{
                .phase = phase,
                .edge = .begin,
                .outcome = null,
                .tick_index = tick.tick_index,
            });
        }

        fn onEnd(
            raw: *anyopaque,
            phase: Phase,
            tick: TickContext,
            outcome: PhaseOutcome,
        ) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.append(.{
                .phase = phase,
                .edge = .end,
                .outcome = outcome,
                .tick_index = tick.tick_index,
            });
        }

        fn observer(self: *@This()) PhaseObserver {
            return .{
                .context = self,
                .begin_fn = onBegin,
                .end_fn = onEnd,
            };
        }
    };

    var success = try Runtime.init(std.testing.allocator, .{
        .namespace = 11,
        .fixed_delta_seconds = 1.0 / 120.0,
    });
    var success_record = Recorder{};
    try success.tickObserved(success_record.observer());
    try std.testing.expectEqual(@as(usize, 8), success_record.count);
    inline for ([_]Phase{ .commands, .pre_physics, .physics, .post_physics }, 0..) |phase, index| {
        const begin = success_record.events[index * 2];
        const end = success_record.events[index * 2 + 1];
        try std.testing.expectEqual(phase, begin.phase);
        try std.testing.expectEqual(Edge.begin, begin.edge);
        try std.testing.expect(begin.outcome == null);
        try std.testing.expectEqual(@as(u64, 1), begin.tick_index);
        try std.testing.expectEqual(phase, end.phase);
        try std.testing.expectEqual(Edge.end, end.edge);
        try std.testing.expectEqual(PhaseOutcome.succeeded, end.outcome.?);
        try std.testing.expectEqual(@as(u64, 1), end.tick_index);
    }
    try std.testing.expectEqual(@as(u64, 1), success.tickIndex());
    success.deinit();

    const Failure = struct {
        fn run(_: *anyopaque, _: *Runtime, _: TickContext) !void {
            return error.ObservedPhaseFailure;
        }
    };
    var failed = try Runtime.init(std.testing.allocator, .{
        .namespace = 12,
        .fixed_delta_seconds = 1.0 / 120.0,
    });
    defer failed.deinit();
    var ignored_context: u8 = 0;
    var registry = failed.registry();
    try registry.addSystem(.physics, "test.observed-failure", &ignored_context, Failure.run);
    var failure_record = Recorder{};
    try std.testing.expectError(
        error.ObservedPhaseFailure,
        failed.tickObserved(failure_record.observer()),
    );
    try std.testing.expectEqual(@as(usize, 6), failure_record.count);
    try std.testing.expectEqual(Phase.physics, failure_record.events[5].phase);
    try std.testing.expectEqual(Edge.end, failure_record.events[5].edge);
    try std.testing.expectEqual(PhaseOutcome.failed, failure_record.events[5].outcome.?);
    try std.testing.expectEqual(@as(u64, 0), failed.tickIndex());
}

test "registry owns system names instead of borrowing caller storage" {
    const Noop = struct {
        fn run(_: *anyopaque, _: *Runtime, _: TickContext) !void {}
    };
    var runtime = try Runtime.init(std.testing.allocator, .{
        .namespace = 2,
        .fixed_delta_seconds = 1.0 / 120.0,
    });
    defer runtime.deinit();
    var context: u8 = 0;
    var mutable_name = [_]u8{ 't', 'e', 's', 't', '.', 'o', 'w', 'n', 'e', 'd' };
    var registry = runtime.registry();
    try registry.addSystem(.commands, &mutable_name, &context, Noop.run);
    mutable_name[0] = 'X';
    try std.testing.expectError(
        error.DuplicateSystemName,
        registry.addSystem(.commands, "test.owned", &context, Noop.run),
    );
}

test "runtime IDs cannot alias a later runtime" {
    var first = try Runtime.init(std.testing.allocator, .{
        .namespace = 101,
        .fixed_delta_seconds = 1.0 / 60.0,
    });
    const first_entity = try first.create();
    try std.testing.expectError(error.UntrackedRuntimeId, first.identity(.{
        .runtime_token = first_entity.runtime_token,
        .serial = first_entity.serial + 1,
    }));
    try first.destroy(first_entity);
    first.deinit();

    var second = try Runtime.init(std.testing.allocator, .{
        .namespace = 202,
        .fixed_delta_seconds = 1.0 / 60.0,
    });
    defer second.deinit();
    try std.testing.expectError(error.ForeignRuntimeId, second.identity(first_entity));
}

test "a scheduled failure retains exact immutable first-fault evidence" {
    const Failure = struct {
        fn run(_: *anyopaque, _: *Runtime, _: TickContext) !void {
            return error.SyntheticSystemFailure;
        }
    };
    var runtime = try Runtime.init(std.testing.allocator, .{
        .namespace = 303,
        .fixed_delta_seconds = 1.0 / 120.0,
        .completed_ticks = 12,
    });
    var context: u8 = 0;
    var registry = runtime.registry();
    try registry.addSystem(.physics, "test.failure", &context, Failure.run);
    runtime.armDiagnosticFreeze(.{
        .severity = .fatal,
        .category = .runtime,
        .code = diagnostic_contract.codes.runtime_system_fault,
    });
    const unrelated = runtime.recordDiagnostic(.{
        .severity = .info,
        .category = .host,
        .code = 76,
        .thread_role = .host,
    });
    try std.testing.expect(unrelated.accepted);
    try std.testing.expect(!unrelated.froze);
    try std.testing.expect(runtime.diagnosticJournal().stats().trigger_armed);
    try std.testing.expect(!runtime.diagnosticJournal().stats().frozen);
    try std.testing.expectError(error.SyntheticSystemFailure, runtime.tick());
    try std.testing.expectEqual(@as(u64, 12), runtime.tickIndex());

    const first = runtime.firstFault() orelse return error.RuntimeFaultMissing;
    try std.testing.expectEqual(Phase.physics, first.phase);
    try std.testing.expectEqual(@as(u64, 13), first.tick_index);
    try std.testing.expectEqual(@as(u64, 2), first.journal_sequence);
    try std.testing.expectEqual(
        @intFromError(error.SyntheticSystemFailure),
        first.error_code,
    );
    try std.testing.expectEqualStrings("test.failure", first.system_name.slice());
    try std.testing.expect(!first.system_name.truncated);
    try std.testing.expectEqualStrings(
        "SyntheticSystemFailure",
        first.error_name.slice(),
    );
    try std.testing.expect(!first.error_name.truncated);

    const journal = runtime.diagnosticJournal();
    const view = journal.borrowedChronological();
    try std.testing.expectEqual(@as(usize, 2), view.len());
    const entry = view.at(1).?.*;
    try std.testing.expectEqual(first.journal_sequence, entry.sequence);
    try std.testing.expectEqual(diagnostic_contract.Severity.fatal, entry.severity);
    try std.testing.expectEqual(diagnostic_contract.Category.runtime, entry.category);
    try std.testing.expectEqual(
        diagnostic_contract.codes.runtime_system_fault,
        entry.code,
    );
    try std.testing.expectEqual(@as(?u64, 13), entry.tick_index);
    try std.testing.expectEqual(diagnostic_contract.ThreadRole.simulation, entry.thread_role);
    try std.testing.expect(entry.thread_id.? != 0);
    try std.testing.expectEqual(runtime.statePtr().runtime_token, entry.correlation_id);
    try std.testing.expect(journal.stats().frozen);
    try std.testing.expect(!journal.stats().trigger_armed);

    try std.testing.expectError(error.RuntimeFaulted, runtime.tick());
    const after_runtime_faulted = runtime.firstFault().?;
    try std.testing.expectEqualDeep(first, after_runtime_faulted);
    try std.testing.expectEqual(@as(usize, 2), runtime.diagnosticJournal().stats().count);

    // Fault state and its frozen journal remain readable during orderly
    // teardown, and teardown releases the one-world lease for a fresh runtime.
    runtime.deinit();
    var replacement = try Runtime.init(std.testing.allocator, .{
        .namespace = 304,
        .fixed_delta_seconds = 1.0 / 120.0,
    });
    defer replacement.deinit();
    try std.testing.expect(replacement.firstFault() == null);
    try std.testing.expect(!replacement.diagnosticJournal().stats().trigger_armed);
}

test "first fault survives a journal that an earlier capture froze" {
    const Failure = struct {
        fn run(_: *anyopaque, _: *Runtime, _: TickContext) !void {
            return error.FailureAfterCapture;
        }
    };
    var runtime = try Runtime.init(std.testing.allocator, .{
        .namespace = 305,
        .fixed_delta_seconds = 1.0 / 120.0,
    });
    defer runtime.deinit();
    var context: u8 = 0;
    var registry = runtime.registry();
    try registry.addSystem(.commands, "test.failure-after-capture", &context, Failure.run);

    runtime.armDiagnosticFreeze(.{
        .severity = .warning,
        .category = .host,
        .code = 77,
    });
    const capture = runtime.recordDiagnostic(.{
        .severity = .warning,
        .category = .host,
        .code = 77,
        .thread_role = .host,
        .thread_id = diagnostic_module.currentThreadId(),
    });
    try std.testing.expect(capture.accepted);
    try std.testing.expect(capture.froze);
    try std.testing.expect(!runtime.diagnosticJournal().stats().trigger_armed);

    try std.testing.expectError(error.FailureAfterCapture, runtime.tick());
    const first = runtime.firstFault() orelse return error.RuntimeFaultMissing;
    try std.testing.expectEqual(Phase.commands, first.phase);
    try std.testing.expectEqual(@as(u64, 1), first.tick_index);
    try std.testing.expectEqual(@as(u64, 0), first.journal_sequence);
    try std.testing.expectEqual(@intFromError(error.FailureAfterCapture), first.error_code);
    try std.testing.expectEqualStrings("test.failure-after-capture", first.system_name.slice());
    try std.testing.expectEqualStrings("FailureAfterCapture", first.error_name.slice());
    try std.testing.expectEqual(@as(usize, 1), runtime.diagnosticJournal().stats().count);
    try std.testing.expectEqual(
        @as(u64, 1),
        runtime.diagnosticJournal().stats().rejected_while_frozen,
    );

    runtime.clearDiagnostics();
    try std.testing.expectEqual(@as(usize, 0), runtime.diagnosticJournal().stats().count);
    try std.testing.expect(runtime.diagnosticJournal().stats().frozen);
    try std.testing.expect(runtime.resumeDiagnosticCapture());
    const after_resume = runtime.recordDiagnostic(.{
        .severity = .info,
        .category = .host,
        .code = 78,
        .thread_role = .host,
    });
    try std.testing.expect(after_resume.accepted);
    try std.testing.expectEqual(@as(u64, 2), after_resume.sequence);
    try std.testing.expect(!runtime.diagnosticJournal().stats().trigger_armed);
    try std.testing.expectEqualDeep(first, runtime.firstFault().?);
    try std.testing.expectError(error.RuntimeFaulted, runtime.tick());
    try std.testing.expectEqualDeep(first, runtime.firstFault().?);
}

test "fault text owns a bounded copy with visible truncation" {
    const source = "abcdefghijklmnopqrstuvwxyz" ** 5;
    const copied = FaultText.copy(source);
    try std.testing.expect(copied.truncated);
    try std.testing.expectEqual(max_fault_name_bytes, copied.slice().len);
    try std.testing.expectEqualStrings(source[0..max_fault_name_bytes], copied.slice());
}

test "a second owned world returns a defined error before zflecs asserts" {
    var runtime = try Runtime.init(std.testing.allocator, .{
        .namespace = 404,
        .fixed_delta_seconds = 1.0 / 120.0,
    });
    defer runtime.deinit();
    try std.testing.expectError(
        error.EngineWorldAlreadyLive,
        Runtime.init(std.testing.allocator, .{
            .namespace = 405,
            .fixed_delta_seconds = 1.0 / 120.0,
        }),
    );
}
