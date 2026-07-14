//! Opaque visual-host owner for catalog-backed district streaming.
//!
//! The graphical composition supplies a narrow authority port and frame index;
//! this owner keeps decoded content, logical load state, renderer residency,
//! diagnostics, and teardown ordering behind one stable heap allocation.

const std = @import("std");
const engine = @import("incinerator_engine");
const content = @import("content");
const district_contract = @import("district_contract");
const districts = @import("district_feature_contract");
const sandbox_recipe = @import("sandbox_district_recipe");
const sandbox_host_contracts = @import("sandbox_host_contracts");
const district_content_catalog = @import("district_content_catalog");
const district_gpu_registry = @import("../district_gpu_registry.zig");
const district_scene_adapter = @import("../district_scene_adapter.zig");
const district_presentation = @import("district_presentation");
const developer_diagnostics = @import("developer_diagnostics");

pub const slot_count: usize = sandbox_recipe.presentation_policies.len;
pub const west_slot_index: usize = 0;
pub const east_slot_index: usize = 1;

comptime {
    if (slot_count != developer_diagnostics.district_stream_slot_count) {
        @compileError("district streaming and developer diagnostics slot counts must match");
    }
}

const Registry = district_gpu_registry.DistrictGpuRegistry;
const Presentation = district_presentation.Coordinator(
    Registry,
    district_contract.LoadTicket,
);

pub const InitOptions = struct {
    stream_content: bool,
    admit_catalog: bool,
    content_root: ?content.ContentRootPath,
};

/// The authority-facing seam contains semantic district work and immutable
/// evidence only. It owns no transport, renderer, content, or storage object.
pub const AuthorityPort = struct {
    context: *anyopaque,
    submit_fn: *const fn (*anyopaque, districts.Command) anyerror!void,
    poll_outcome_fn: *const fn (*anyopaque) ?districts.Outcome,
    poll_event_fn: *const fn (*anyopaque) ?districts.Event,
    state_fn: *const fn (*anyopaque, district_contract.ChunkCoord) ?districts.StateTag,
    active_ticket_fn: *const fn (
        *anyopaque,
        district_contract.ChunkCoord,
    ) ?district_contract.LoadTicket,
    presentation_fn: *const fn (*anyopaque) anyerror![]const districts.DistrictDraw,
    tick_index_fn: *const fn (*anyopaque) u64,
    record_fn: *const fn (
        *anyopaque,
        engine.runtime.DiagnosticEntry,
    ) engine.runtime.DiagnosticAppendResult,

    fn submit(self: AuthorityPort, command: districts.Command) !void {
        try self.submit_fn(self.context, command);
    }

    fn pollOutcome(self: AuthorityPort) ?districts.Outcome {
        return self.poll_outcome_fn(self.context);
    }

    fn pollEvent(self: AuthorityPort) ?districts.Event {
        return self.poll_event_fn(self.context);
    }

    fn state(
        self: AuthorityPort,
        coord: district_contract.ChunkCoord,
    ) ?districts.StateTag {
        return self.state_fn(self.context, coord);
    }

    fn activeTicket(
        self: AuthorityPort,
        coord: district_contract.ChunkCoord,
    ) ?district_contract.LoadTicket {
        return self.active_ticket_fn(self.context, coord);
    }

    fn presentation(self: AuthorityPort) ![]const districts.DistrictDraw {
        return self.presentation_fn(self.context);
    }

    fn tickIndex(self: AuthorityPort) u64 {
        return self.tick_index_fn(self.context);
    }

    fn record(
        self: AuthorityPort,
        entry: engine.runtime.DiagnosticEntry,
    ) engine.runtime.DiagnosticAppendResult {
        return self.record_fn(self.context, entry);
    }
};

pub const Phase = enum {
    idle,
    reading,
    cancelling_content,
    content_ready,
    request_submitted,
    request_submitted_cancel,
    loading,
    cancelling_logical,
    active,
    unloading,
    draining,
};

/// Immutable inspection value used by validation and developer presentation.
pub const SlotView = struct {
    coord: district_contract.ChunkCoord,
    phase: Phase,
    desired_inside: bool,
    correlation_id: ?u64 = null,
    scene: ?engine.rendering.SceneHandle = null,
    ticket: ?district_contract.LoadTicket = null,
    request_id: ?u64 = null,
    content_generation: ?u64 = null,
    pending_decoded_scene: bool,
};

pub const SceneResidency = enum {
    free,
    reserved,
    staged,
    submitted,
    retiring,
    resident,
};

pub const GpuPump = struct {
    submitted_scenes: u8,
    published_scenes: u8,
    usage: developer_diagnostics.GpuUsage,
};

const Bound = struct {
    scene: engine.rendering.SceneHandle,
    ticket: district_contract.LoadTicket,
    load_request_id: u64,
    content_generation: u64,
};

const Reading = struct {
    scene: engine.rendering.SceneHandle,
    generation: u64,
};

const Submitted = struct {
    scene: engine.rendering.SceneHandle,
    request_id: u64,
    content_generation: u64,
};

const Cancelling = struct {
    bound: Bound,
    request_id: u64,
};

const Unloading = struct {
    bound: Bound,
    request_id: u64,
};

const Draining = struct {
    scene: engine.rendering.SceneHandle,
    content_generation: ?u64,
};

const StateTag = enum {
    idle,
    reading,
    cancelling_content,
    content_ready,
    request_submitted,
    request_submitted_cancel,
    loading,
    cancelling_logical,
    active,
    unloading,
    draining,
};

const StreamState = union(StateTag) {
    idle,
    reading: Reading,
    cancelling_content: Reading,
    content_ready: Reading,
    request_submitted: Submitted,
    request_submitted_cancel: Submitted,
    loading: Bound,
    cancelling_logical: Cancelling,
    active: Bound,
    unloading: Unloading,
    draining: Draining,
};

const Slot = struct {
    coord: district_contract.ChunkCoord,
    presentation: Presentation,
    state: StreamState = .idle,
    prefetch_proximity: district_presentation.ProximityHysteresis,
    authority_proximity: district_presentation.ProximityHysteresis,
    pending_scene: ?content.bundle.OwnedBundle = null,
    correlation: u64 = 0,

    fn wantsContent(self: *const Slot) bool {
        return self.prefetch_proximity.inside or self.authority_proximity.inside;
    }
};

const ContentJob = struct {
    value: Reading,
    cancelling: bool,
};

const Admission = struct {
    scene: engine.rendering.SceneHandle,
    request_id: u64,
    content_generation: u64,
    cancel: bool,
};

const State = struct {
    allocator: std.mem.Allocator,
    registry: Registry,
    slots: [slot_count]Slot,
    catalog: ?district_content_catalog.AdmittedCatalog = null,
    worker: ?content.SceneWorker = null,
    content_owner: ?u8 = null,
    next_content_generation: u64 = 1,
    next_request_id: u64 = 1,
    next_correlation: u64 = 1,
    teardown_prepared: bool = false,

    fn ensureOperational(self: *const State) !void {
        try ensureOperationalPhase(self.teardown_prepared);
    }

    fn recordTransition(
        self: *State,
        authority: AuthorityPort,
        frame_index: u64,
        slot_index: usize,
        severity: engine.diagnostic_contracts.Severity,
        category: engine.diagnostic_contracts.Category,
        code: engine.diagnostic_contracts.Code,
        persistent_id: ?engine.PersistentId,
    ) void {
        const correlation = self.slots[slot_index].correlation;
        if (correlation == 0) return;
        _ = authority.record(.{
            .severity = severity,
            .category = category,
            .code = code,
            .tick_index = authority.tickIndex(),
            .frame_index = frame_index,
            .thread_role = .host,
            .thread_id = engine.diagnostics.currentThreadId(),
            .persistent_id = persistent_id,
            .correlation_id = correlation,
        });
    }

    fn slotIndexForCoord(
        self: *const State,
        coord: district_contract.ChunkCoord,
    ) ?usize {
        for (self.slots, 0..) |slot, index| {
            if (district_contract.ChunkCoord.eql(slot.coord, coord)) return index;
        }
        return null;
    }

    fn slotIndexForLoadRequest(self: *const State, request_id: u64) ?usize {
        for (self.slots, 0..) |slot, index| switch (slot.state) {
            .request_submitted, .request_submitted_cancel => |submitted| {
                if (submitted.request_id == request_id) return index;
            },
            else => {},
        };
        return null;
    }

    fn slotIndexForTicket(
        self: *const State,
        ticket: district_contract.LoadTicket,
    ) ?usize {
        for (self.slots, 0..) |slot, index| {
            const owned: ?district_contract.LoadTicket = switch (slot.state) {
                .loading, .active => |bound| bound.ticket,
                .cancelling_logical => |value| value.bound.ticket,
                .unloading => |value| value.bound.ticket,
                else => null,
            };
            if (owned) |candidate| if (district_contract.LoadTicket.eql(
                candidate,
                ticket,
            )) return index;
        }
        return null;
    }

    fn logicalTransitionInFlight(self: *const State) bool {
        for (self.slots) |slot| switch (slot.state) {
            .request_submitted,
            .request_submitted_cancel,
            .loading,
            .cancelling_logical,
            .unloading,
            => return true,
            else => {},
        };
        return false;
    }

    fn reconcile(
        self: *State,
        authority: AuthorityPort,
        frame_index: u64,
    ) !void {
        for (&self.slots, 0..) |*slot, slot_index| {
            const draining = switch (slot.state) {
                .draining => |value| value,
                else => continue,
            };
            if (!try self.registry.recycleComplete(draining.scene)) continue;
            self.recordTransition(
                authority,
                frame_index,
                slot_index,
                .info,
                .rendering,
                engine.diagnostic_contracts.codes.district_stream_gpu_drained,
                null,
            );
            slot.state = .idle;
            slot.correlation = 0;
        }

        const catalog = if (self.catalog) |*value| value else return;
        for (catalog.view().entries) |entry| {
            const coord = district_contract.ChunkCoord{ .x = entry.coord.x, .z = entry.coord.z };
            const slot_index = self.slotIndexForCoord(coord) orelse
                return error.DistrictCatalogSlotMismatch;
            const slot = &self.slots[slot_index];
            if (!slot.wantsContent()) continue;
            switch (slot.state) {
                .content_ready => {
                    if (!slot.authority_proximity.inside) continue;
                    if (self.logicalTransitionInFlight()) continue;
                    try self.submitPrepared(authority, frame_index, slot_index);
                    return;
                },
                .idle => {
                    if (self.content_owner != null) continue;
                    try self.beginContentRequest(authority, frame_index, slot_index);
                    return;
                },
                else => {},
            }
        }
    }

    fn rejectReserved(
        self: *State,
        authority: AuthorityPort,
        frame_index: u64,
        slot_index: usize,
        scene: engine.rendering.SceneHandle,
        content_generation: ?u64,
    ) !void {
        const slot = &self.slots[slot_index];
        try slot.presentation.loadRejected(scene);
        self.recordTransition(
            authority,
            frame_index,
            slot_index,
            .warning,
            .rendering,
            engine.diagnostic_contracts.codes.district_stream_gpu_release_requested,
            null,
        );
        slot.state = .{ .draining = .{
            .scene = scene,
            .content_generation = content_generation,
        } };
    }

    fn beginContentRequest(
        self: *State,
        authority: AuthorityPort,
        frame_index: u64,
        slot_index: usize,
    ) !void {
        const slot = &self.slots[slot_index];
        if (std.meta.activeTag(slot.state) != .idle) {
            return error.DistrictContentRequestWhileBusy;
        }
        if (self.content_owner != null) return error.DistrictContentWorkerBusy;
        if (authority.state(slot.coord) != null) return error.DistrictLogicalStateMismatch;
        const worker = if (self.worker) |*value| value else return error.DistrictContentWorkerMissing;
        const catalog = if (self.catalog) |*value| value else return error.DistrictCatalogMissing;
        const scene = slot.presentation.beginRequest() catch |err| {
            if (err == error.DistrictSceneRegistryFull) return;
            return err;
        };
        slot.correlation = takeMonotonicId(&self.next_correlation) catch |err| {
            try self.rejectReserved(authority, frame_index, slot_index, scene, null);
            return err;
        };
        self.recordTransition(
            authority,
            frame_index,
            slot_index,
            .debug,
            .rendering,
            engine.diagnostic_contracts.codes.district_stream_gpu_reserved,
            null,
        );
        const generation = takeMonotonicId(&self.next_content_generation) catch |err| {
            try self.rejectReserved(authority, frame_index, slot_index, scene, null);
            return err;
        };
        const request = catalog.sceneRequest(slot.coord, generation) catch |err| {
            try self.rejectReserved(authority, frame_index, slot_index, scene, generation);
            return err;
        };
        const disposition = worker.request(request) catch |err| {
            self.recordTransition(
                authority,
                frame_index,
                slot_index,
                .err,
                .content,
                engine.diagnostic_contracts.codes.district_stream_content_failed,
                null,
            );
            try self.rejectReserved(authority, frame_index, slot_index, scene, generation);
            return err;
        };
        switch (disposition) {
            .accepted => {
                slot.state = .{ .reading = .{ .scene = scene, .generation = generation } };
                self.content_owner = @intCast(slot_index);
                self.recordTransition(
                    authority,
                    frame_index,
                    slot_index,
                    .info,
                    .content,
                    engine.diagnostic_contracts.codes.district_stream_content_requested,
                    null,
                );
            },
            .busy, .stale, .invalid => {
                self.recordTransition(
                    authority,
                    frame_index,
                    slot_index,
                    .err,
                    .content,
                    engine.diagnostic_contracts.codes.district_stream_content_failed,
                    null,
                );
                try self.rejectReserved(authority, frame_index, slot_index, scene, generation);
                return error.DistrictContentWorkerAdmissionFailed;
            },
        }
    }

    fn clearPendingScene(self: *State, slot_index: usize) void {
        const slot = &self.slots[slot_index];
        if (slot.pending_scene) |*scene| scene.deinit();
        slot.pending_scene = null;
    }

    fn requestDeparture(
        self: *State,
        authority: AuthorityPort,
        frame_index: u64,
        slot_index: usize,
    ) !void {
        const slot = &self.slots[slot_index];
        switch (slot.state) {
            .idle,
            .draining,
            .cancelling_content,
            .request_submitted_cancel,
            .cancelling_logical,
            .unloading,
            => {},
            .reading => |reading| {
                if (self.content_owner != @as(u8, @intCast(slot_index))) {
                    return error.DistrictContentOwnerMismatch;
                }
                const worker = if (self.worker) |*value| value else return error.DistrictContentWorkerMissing;
                switch (worker.cancel(reading.generation)) {
                    .requested => {
                        slot.state = .{ .cancelling_content = reading };
                        self.recordTransition(
                            authority,
                            frame_index,
                            slot_index,
                            .info,
                            .content,
                            engine.diagnostic_contracts.codes.district_stream_content_cancel_requested,
                            null,
                        );
                    },
                    .idle, .stale, .invalid => return error.DistrictContentWorkerStateMismatch,
                }
            },
            .content_ready => |ready| {
                self.clearPendingScene(slot_index);
                try self.rejectReserved(
                    authority,
                    frame_index,
                    slot_index,
                    ready.scene,
                    ready.generation,
                );
            },
            .request_submitted => |submitted| {
                self.clearPendingScene(slot_index);
                slot.state = .{ .request_submitted_cancel = submitted };
            },
            .loading => |loading| {
                self.clearPendingScene(slot_index);
                const request_id = try takeMonotonicId(&self.next_request_id);
                try authority.submit(.{ .cancel_load = .{
                    .request_id = request_id,
                    .ticket = loading.ticket,
                } });
                slot.state = .{ .cancelling_logical = .{
                    .bound = loading,
                    .request_id = request_id,
                } };
                self.recordTransition(
                    authority,
                    frame_index,
                    slot_index,
                    .info,
                    .streaming,
                    engine.diagnostic_contracts.codes.district_stream_logical_cancel_submitted,
                    null,
                );
            },
            .active => |active| {
                self.clearPendingScene(slot_index);
                const request_id = try takeMonotonicId(&self.next_request_id);
                try authority.submit(.{ .unload = .{
                    .request_id = request_id,
                    .ticket = active.ticket,
                } });
                slot.state = .{ .unloading = .{
                    .bound = active,
                    .request_id = request_id,
                } };
                self.recordTransition(
                    authority,
                    frame_index,
                    slot_index,
                    .info,
                    .streaming,
                    engine.diagnostic_contracts.codes.district_stream_logical_unload_submitted,
                    null,
                );
            },
        }
    }

    fn requestAuthorityDeparture(
        self: *State,
        authority: AuthorityPort,
        frame_index: u64,
        slot_index: usize,
    ) !void {
        const slot = &self.slots[slot_index];
        if (slot.prefetch_proximity.inside) switch (slot.state) {
            // No logical command or ticket exists yet. Keep the warmed bytes
            // while prediction still wants them, but do not submit them.
            .reading, .content_ready => return,
            else => {},
        };
        try self.requestDeparture(authority, frame_index, slot_index);
    }

    fn stageUpload(
        self: *State,
        authority: AuthorityPort,
        frame_index: u64,
        slot_index: usize,
        scene_handle: engine.rendering.SceneHandle,
        upload_plan: *district_scene_adapter.UploadPlan,
    ) !bool {
        self.registry.stage(scene_handle, upload_plan.sceneUpload()) catch |err| {
            if (isRetryableStageError(err)) return false;
            return err;
        };
        const staged_stats = try self.registry.stats();
        self.recordTransition(
            authority,
            frame_index,
            slot_index,
            .info,
            .rendering,
            engine.diagnostic_contracts.codes.district_stream_gpu_staged,
            null,
        );
        std.debug.print(
            "Cooked district ({d},{d}) staged: primitives={d} textures={d} cpu_bytes={d}\n",
            .{
                self.slots[slot_index].coord.x,
                self.slots[slot_index].coord.z,
                upload_plan.mesh_count,
                upload_plan.texture_count,
                staged_stats.staged_cpu_bytes,
            },
        );
        return true;
    }

    fn retryPendingScene(
        self: *State,
        authority: AuthorityPort,
        frame_index: u64,
        slot_index: usize,
    ) !void {
        const slot = &self.slots[slot_index];
        const pending = if (slot.pending_scene) |*scene| scene else return;
        const scene_handle = switch (slot.state) {
            .request_submitted => |value| value.scene,
            .loading, .active => |value| value.scene,
            .content_ready => return,
            else => return error.DistrictPendingSceneStateMismatch,
        };
        var upload_plan = try district_scene_adapter.build(pending.view());
        if (!try self.stageUpload(
            authority,
            frame_index,
            slot_index,
            scene_handle,
            &upload_plan,
        )) return;
        pending.deinit();
        slot.pending_scene = null;
    }

    fn submitPrepared(
        self: *State,
        authority: AuthorityPort,
        frame_index: u64,
        slot_index: usize,
    ) !void {
        const slot = &self.slots[slot_index];
        const ready = switch (slot.state) {
            .content_ready => |value| value,
            else => return error.DistrictPreparedSceneStateMismatch,
        };
        const pending = if (slot.pending_scene) |*scene| scene else return error.DistrictPreparedSceneMissing;
        if (authority.state(slot.coord) != null) return error.DistrictLogicalStateMismatch;
        const request_id = try takeMonotonicId(&self.next_request_id);
        var upload_plan = try district_scene_adapter.build(pending.view());
        try authority.submit(.{ .request_load = .{
            .request_id = request_id,
            .coord = slot.coord,
            .assets = .{ .scene = ready.scene },
        } });
        slot.state = .{ .request_submitted = .{
            .scene = ready.scene,
            .request_id = request_id,
            .content_generation = ready.generation,
        } };
        self.recordTransition(
            authority,
            frame_index,
            slot_index,
            .info,
            .streaming,
            engine.diagnostic_contracts.codes.district_stream_logical_submitted,
            null,
        );
        if (!try self.stageUpload(
            authority,
            frame_index,
            slot_index,
            ready.scene,
            &upload_plan,
        )) return;
        pending.deinit();
        slot.pending_scene = null;
    }

    fn pumpContent(
        self: *State,
        authority: AuthorityPort,
        frame_index: u64,
    ) !void {
        for (0..slot_count) |slot_index| {
            try self.retryPendingScene(authority, frame_index, slot_index);
        }
        const slot_index: usize = self.content_owner orelse return;
        const slot = &self.slots[slot_index];
        const job: ContentJob = switch (slot.state) {
            .reading => |value| .{ .value = value, .cancelling = false },
            .cancelling_content => |value| .{ .value = value, .cancelling = true },
            else => return error.DistrictContentOwnerMismatch,
        };
        const worker = if (self.worker) |*value| value else return error.DistrictContentWorkerMissing;
        switch (worker.poll(job.value.generation)) {
            .pending => {},
            .idle, .stale => return error.DistrictContentWorkerStateMismatch,
            .completion => |completion| {
                self.content_owner = null;
                switch (completion) {
                    .cancelled => |generation| {
                        if (!job.cancelling or generation != job.value.generation) {
                            return error.DistrictContentLoadCancelled;
                        }
                        self.recordTransition(
                            authority,
                            frame_index,
                            slot_index,
                            .info,
                            .content,
                            engine.diagnostic_contracts.codes.district_stream_content_cancelled,
                            null,
                        );
                        try self.rejectReserved(
                            authority,
                            frame_index,
                            slot_index,
                            job.value.scene,
                            job.value.generation,
                        );
                    },
                    .failed => |failed| {
                        self.recordTransition(
                            authority,
                            frame_index,
                            slot_index,
                            .err,
                            .content,
                            engine.diagnostic_contracts.codes.district_stream_content_failed,
                            null,
                        );
                        try self.rejectReserved(
                            authority,
                            frame_index,
                            slot_index,
                            job.value.scene,
                            job.value.generation,
                        );
                        std.debug.print(
                            "Cooked district load failed for ({d},{d}): {any}\n",
                            .{ slot.coord.x, slot.coord.z, failed.failure },
                        );
                        return error.DistrictContentLoadFailed;
                    },
                    .ready => |ready_value| {
                        if (ready_value.generation != job.value.generation) {
                            var stale_scene = ready_value.scene;
                            stale_scene.deinit();
                            return error.DistrictContentGenerationMismatch;
                        }
                        var scene = ready_value.scene;
                        errdefer scene.deinit();
                        self.recordTransition(
                            authority,
                            frame_index,
                            slot_index,
                            .info,
                            .content,
                            engine.diagnostic_contracts.codes.district_stream_content_ready,
                            null,
                        );
                        if (job.cancelling or !slot.wantsContent()) {
                            scene.deinit();
                            try self.rejectReserved(
                                authority,
                                frame_index,
                                slot_index,
                                job.value.scene,
                                job.value.generation,
                            );
                            return;
                        }
                        try validateCookedLogicalDistrict(scene.view(), slot.coord);
                        slot.pending_scene = scene;
                        slot.state = .{ .content_ready = job.value };
                    },
                }
            },
        }
    }

    fn processOutcomes(
        self: *State,
        authority: AuthorityPort,
        frame_index: u64,
    ) !void {
        while (authority.pollOutcome()) |outcome| {
            switch (outcome) {
                .load_requested => |requested| {
                    const slot_index = self.slotIndexForLoadRequest(requested.request_id) orelse
                        return error.UnexpectedDistrictOutcome;
                    const slot = &self.slots[slot_index];
                    if (!district_contract.ChunkCoord.eql(requested.ticket.coord, slot.coord)) {
                        return error.UnexpectedDistrictOutcome;
                    }
                    const admission: Admission = switch (slot.state) {
                        .request_submitted => |submitted| .{
                            .scene = submitted.scene,
                            .request_id = submitted.request_id,
                            .content_generation = submitted.content_generation,
                            .cancel = false,
                        },
                        .request_submitted_cancel => |submitted| .{
                            .scene = submitted.scene,
                            .request_id = submitted.request_id,
                            .content_generation = submitted.content_generation,
                            .cancel = true,
                        },
                        else => return error.UnexpectedDistrictOutcome,
                    };
                    try slot.presentation.loadAdmitted(admission.scene, requested.ticket);
                    self.recordTransition(
                        authority,
                        frame_index,
                        slot_index,
                        .info,
                        .streaming,
                        engine.diagnostic_contracts.codes.district_stream_logical_admitted,
                        null,
                    );
                    const bound = Bound{
                        .scene = admission.scene,
                        .ticket = requested.ticket,
                        .load_request_id = admission.request_id,
                        .content_generation = admission.content_generation,
                    };
                    if (admission.cancel) {
                        const cancel_request_id = try takeMonotonicId(&self.next_request_id);
                        try authority.submit(.{ .cancel_load = .{
                            .request_id = cancel_request_id,
                            .ticket = requested.ticket,
                        } });
                        slot.state = .{ .cancelling_logical = .{
                            .bound = bound,
                            .request_id = cancel_request_id,
                        } };
                        self.recordTransition(
                            authority,
                            frame_index,
                            slot_index,
                            .info,
                            .streaming,
                            engine.diagnostic_contracts.codes.district_stream_logical_cancel_submitted,
                            null,
                        );
                    } else {
                        slot.state = .{ .loading = bound };
                    }
                },
                .activated => |activated| {
                    const slot_index = self.slotIndexForTicket(activated.ticket) orelse
                        return error.UnexpectedDistrictOutcome;
                    const slot = &self.slots[slot_index];
                    const loading = switch (slot.state) {
                        .loading => |value| value,
                        else => return error.UnexpectedDistrictOutcome,
                    };
                    if (loading.load_request_id != activated.request_id or
                        !district_contract.ChunkCoord.eql(activated.coord, slot.coord))
                    {
                        return error.UnexpectedDistrictOutcome;
                    }
                    try slot.presentation.logicalActivated(activated.ticket);
                    slot.state = .{ .active = loading };
                    const active_ticket = authority.activeTicket(slot.coord) orelse
                        return error.DistrictLogicalStateMismatch;
                    if (!district_contract.LoadTicket.eql(active_ticket, activated.ticket)) {
                        return error.DistrictLogicalStateMismatch;
                    }
                    self.recordTransition(
                        authority,
                        frame_index,
                        slot_index,
                        .info,
                        .streaming,
                        engine.diagnostic_contracts.codes.district_stream_logical_activated,
                        activated.id,
                    );
                },
                .rejected => |rejected| switch (rejected.command) {
                    .request_load => {
                        const slot_index = self.slotIndexForLoadRequest(rejected.request_id) orelse
                            return error.UnexpectedDistrictOutcome;
                        const slot = &self.slots[slot_index];
                        const submitted = switch (slot.state) {
                            .request_submitted, .request_submitted_cancel => |value| value,
                            else => return error.UnexpectedDistrictOutcome,
                        };
                        self.clearPendingScene(slot_index);
                        self.recordTransition(
                            authority,
                            frame_index,
                            slot_index,
                            .err,
                            .streaming,
                            engine.diagnostic_contracts.codes.district_stream_logical_failed,
                            null,
                        );
                        try self.rejectReserved(
                            authority,
                            frame_index,
                            slot_index,
                            submitted.scene,
                            submitted.content_generation,
                        );
                        return error.DistrictLoadRejected;
                    },
                    .cancel_load => {
                        const ticket = rejected.ticket orelse
                            return error.UnexpectedDistrictOutcome;
                        const slot_index = self.slotIndexForTicket(ticket) orelse
                            return error.UnexpectedDistrictOutcome;
                        const cancelling = switch (self.slots[slot_index].state) {
                            .cancelling_logical => |value| value,
                            else => return error.UnexpectedDistrictOutcome,
                        };
                        if (cancelling.request_id != rejected.request_id) {
                            return error.UnexpectedDistrictOutcome;
                        }
                        return error.DistrictCancelRejected;
                    },
                    .unload => {
                        const ticket = rejected.ticket orelse
                            return error.UnexpectedDistrictOutcome;
                        const slot_index = self.slotIndexForTicket(ticket) orelse
                            return error.UnexpectedDistrictOutcome;
                        const unloading = switch (self.slots[slot_index].state) {
                            .unloading => |value| value,
                            else => return error.UnexpectedDistrictOutcome,
                        };
                        if (unloading.request_id != rejected.request_id) {
                            return error.UnexpectedDistrictOutcome;
                        }
                        return error.DistrictUnloadRejected;
                    },
                },
                .cancelled => |cancelled| {
                    const slot_index = self.slotIndexForTicket(cancelled.ticket) orelse
                        return error.UnexpectedDistrictOutcome;
                    const slot = &self.slots[slot_index];
                    const cancelling = switch (slot.state) {
                        .cancelling_logical => |value| value,
                        else => return error.UnexpectedDistrictOutcome,
                    };
                    self.clearPendingScene(slot_index);
                    try slot.presentation.loadTerminated(cancelled.ticket);
                    self.recordTransition(
                        authority,
                        frame_index,
                        slot_index,
                        .info,
                        .streaming,
                        engine.diagnostic_contracts.codes.district_stream_logical_cancelled,
                        null,
                    );
                    self.recordTransition(
                        authority,
                        frame_index,
                        slot_index,
                        .warning,
                        .rendering,
                        engine.diagnostic_contracts.codes.district_stream_gpu_release_requested,
                        null,
                    );
                    slot.state = .{ .draining = .{
                        .scene = cancelling.bound.scene,
                        .content_generation = cancelling.bound.content_generation,
                    } };
                },
                .load_failed => |failed| {
                    const slot_index = self.slotIndexForTicket(failed.ticket) orelse
                        return error.UnexpectedDistrictOutcome;
                    const slot = &self.slots[slot_index];
                    const loading = switch (slot.state) {
                        .loading => |value| value,
                        .cancelling_logical => |value| value.bound,
                        else => return error.UnexpectedDistrictOutcome,
                    };
                    if (loading.load_request_id != failed.request_id) {
                        return error.UnexpectedDistrictOutcome;
                    }
                    self.clearPendingScene(slot_index);
                    try slot.presentation.loadTerminated(failed.ticket);
                    self.recordTransition(
                        authority,
                        frame_index,
                        slot_index,
                        .err,
                        .streaming,
                        engine.diagnostic_contracts.codes.district_stream_logical_failed,
                        null,
                    );
                    self.recordTransition(
                        authority,
                        frame_index,
                        slot_index,
                        .warning,
                        .rendering,
                        engine.diagnostic_contracts.codes.district_stream_gpu_release_requested,
                        null,
                    );
                    slot.state = .{ .draining = .{
                        .scene = loading.scene,
                        .content_generation = loading.content_generation,
                    } };
                    return error.DistrictLogicalLoadFailed;
                },
                .unloaded => |unloaded| {
                    const slot_index = self.slotIndexForTicket(unloaded.ticket) orelse
                        return error.UnexpectedDistrictOutcome;
                    const slot = &self.slots[slot_index];
                    const unloading = switch (slot.state) {
                        .unloading => |value| value,
                        else => return error.UnexpectedDistrictOutcome,
                    };
                    if (unloading.request_id != unloaded.request_id) {
                        return error.UnexpectedDistrictOutcome;
                    }
                    self.clearPendingScene(slot_index);
                    try slot.presentation.logicalUnloaded(unloaded.ticket);
                    self.recordTransition(
                        authority,
                        frame_index,
                        slot_index,
                        .info,
                        .streaming,
                        engine.diagnostic_contracts.codes.district_stream_logical_unloaded,
                        unloaded.id,
                    );
                    self.recordTransition(
                        authority,
                        frame_index,
                        slot_index,
                        .warning,
                        .rendering,
                        engine.diagnostic_contracts.codes.district_stream_gpu_release_requested,
                        null,
                    );
                    const draws = try authority.presentation();
                    for (draws) |draw| {
                        if (district_contract.LoadTicket.eql(draw.ticket, unloaded.ticket)) {
                            return error.DistrictPresentationStillExtracted;
                        }
                    }
                    try slot.presentation.presentationAbsent(0);
                    if (authority.state(slot.coord) != null) {
                        return error.DistrictLogicalStateMismatch;
                    }
                    slot.state = .{ .draining = .{
                        .scene = unloading.bound.scene,
                        .content_generation = unloading.bound.content_generation,
                    } };
                },
                .cancellation_requested => |requested| {
                    const slot_index = self.slotIndexForTicket(requested.ticket) orelse
                        return error.UnexpectedDistrictOutcome;
                    const cancelling = switch (self.slots[slot_index].state) {
                        .cancelling_logical => |value| value,
                        else => return error.UnexpectedDistrictOutcome,
                    };
                    if (cancelling.request_id != requested.request_id) {
                        return error.UnexpectedDistrictOutcome;
                    }
                },
            }
        }
        while (authority.pollEvent()) |_| {}
    }

    fn pumpGpu(
        self: *State,
        authority: AuthorityPort,
        frame_index: u64,
    ) !GpuPump {
        var before: [slot_count]?district_gpu_registry.Residency = @splat(null);
        for (self.slots, 0..) |slot, slot_index| {
            if (sceneHandle(slot.state)) |scene| {
                before[slot_index] = self.registry.residency(scene) catch |err| switch (err) {
                    error.StaleSceneHandle => null,
                    else => return err,
                };
            }
        }
        const progress = try self.registry.pump();
        for (self.slots, 0..) |slot, slot_index| {
            const scene = sceneHandle(slot.state) orelse continue;
            const after = self.registry.residency(scene) catch |err| switch (err) {
                error.StaleSceneHandle => continue,
                else => return err,
            };
            if (after == .submitted and before[slot_index] != .submitted) {
                self.recordTransition(
                    authority,
                    frame_index,
                    slot_index,
                    .info,
                    .rendering,
                    engine.diagnostic_contracts.codes.district_stream_gpu_submitted,
                    null,
                );
            }
            if (after == .resident and before[slot_index] != .resident) {
                self.recordTransition(
                    authority,
                    frame_index,
                    slot_index,
                    .info,
                    .rendering,
                    engine.diagnostic_contracts.codes.district_stream_gpu_resident,
                    null,
                );
            }
        }
        const usage = gpuUsageFromStats(try self.registry.stats());
        if (progress.published_scenes > 0) {
            std.debug.print(
                "Cooked district GPU resident: scenes={d} bytes={d}\n",
                .{ progress.published_scenes, usage.resident_gpu_bytes },
            );
        }
        return .{
            .submitted_scenes = progress.submitted_scenes,
            .published_scenes = progress.published_scenes,
            .usage = usage,
        };
    }
};

/// Move-only, opaque owner of the visual district-streaming lifecycle.
///
/// The heap allocation keeps presentation coordinators and the worker at
/// stable addresses even when the containing graphical host is returned by
/// value. Call `prepareAuthorityTeardown` before destroying the authority,
/// then `deinitAfterAuthority` after it has been destroyed.
pub const Owner = opaque {
    pub fn init(
        io: std.Io,
        allocator: std.mem.Allocator,
        device: @FieldType(district_gpu_registry.SdlBackend, "device"),
        options: InitOptions,
    ) !*Owner {
        if (options.stream_content and !options.admit_catalog) {
            return error.DistrictStreamingCatalogRequired;
        }
        if (options.admit_catalog and options.content_root == null) {
            return error.ContentRootRequired;
        }

        const state = try allocator.create(State);
        errdefer allocator.destroy(state);
        state.* = .{
            .allocator = allocator,
            .registry = try Registry.init(
                allocator,
                .{ .device = device },
                .{},
                .{},
            ),
            .slots = undefined,
        };
        errdefer state.registry.deinit();

        for (&state.slots, sandbox_recipe.presentation_policies) |*stream_slot, policy| {
            const proximity_config = district_presentation.ProximityConfig{
                .center_xz = policy.center_xz,
                .half_extent_xz = policy.half_extent_xz,
                .load_margin = policy.load_margin,
                .unload_margin = policy.unload_margin,
            };
            stream_slot.* = .{
                .coord = policy.coord,
                .presentation = Presentation.init(&state.registry),
                .prefetch_proximity = try district_presentation.ProximityHysteresis.init(
                    proximity_config,
                ),
                .authority_proximity = try district_presentation.ProximityHysteresis.init(
                    proximity_config,
                ),
            };
        }

        if (options.admit_catalog) {
            state.catalog = switch (try district_content_catalog.admit(
                io,
                allocator,
                options.content_root.?,
            )) {
                .admitted => |value| value,
                .failed => |failure| {
                    std.debug.print("District catalog admission failed: {any}\n", .{failure});
                    return error.DistrictCatalogAdmissionFailed;
                },
            };
            errdefer if (state.catalog) |*catalog| catalog.deinit();
            try validateCatalogEntries(state.catalog.?.view().entries);
        }

        if (options.stream_content) {
            state.worker = content.SceneWorker.init(io, allocator);
        }
        return @ptrCast(state);
    }

    /// Stop background content work and release decoded-but-not-submitted
    /// content while authority-owned tickets are still valid.
    pub fn prepareAuthorityTeardown(self: *Owner) void {
        const state = ownerState(self);
        if (state.teardown_prepared) return;
        if (state.worker) |*worker| worker.deinit();
        state.worker = null;
        state.content_owner = null;
        for (0..slot_count) |slot_index| state.clearPendingScene(slot_index);
        state.teardown_prepared = true;
    }

    /// Release presentation bindings and renderer resources after the
    /// authority has stopped exposing logical district tickets.
    pub fn deinitAfterAuthority(self: *Owner) void {
        if (!ownerState(self).teardown_prepared) self.prepareAuthorityTeardown();
        const state = ownerState(self);
        for (&state.slots) |*stream_slot| {
            stream_slot.presentation.releaseAfterSimulationTeardown() catch |err| {
                std.debug.panic(
                    "district presentation teardown failed: {s}",
                    .{@errorName(err)},
                );
            };
        }
        state.registry.deinit();
        if (state.catalog) |*catalog| catalog.deinit();
        state.catalog = null;
        const allocator = state.allocator;
        allocator.destroy(state);
    }

    /// Init-error cleanup for a host that never began streaming work.
    pub fn abortInit(self: *Owner) void {
        self.prepareAuthorityTeardown();
        self.deinitAfterAuthority();
    }

    /// Warm decoded visual content from client-predicted focus. This path may
    /// prefetch bytes, but cannot make a district logically resident.
    pub fn updatePrefetch(
        self: *Owner,
        authority: AuthorityPort,
        frame_index: u64,
        position_xz: [2]f32,
    ) !void {
        try ownerState(self).ensureOperational();
        for (&ownerState(self).slots, 0..) |*stream_slot, slot_index| {
            switch (try stream_slot.prefetch_proximity.observe(position_xz)) {
                .none, .enter => {},
                .exit => if (!stream_slot.authority_proximity.inside) {
                    try ownerState(self).requestDeparture(
                        authority,
                        frame_index,
                        slot_index,
                    );
                },
            }
        }
        try ownerState(self).reconcile(authority, frame_index);
    }

    /// Drive logical residency exclusively from authority-owned focus.
    pub fn updateAuthorityResidency(
        self: *Owner,
        authority: AuthorityPort,
        frame_index: u64,
        position_xz: [2]f32,
    ) !void {
        try ownerState(self).ensureOperational();
        for (&ownerState(self).slots, 0..) |*stream_slot, slot_index| {
            switch (try stream_slot.authority_proximity.observe(position_xz)) {
                .none, .enter => {},
                .exit => try ownerState(self).requestAuthorityDeparture(
                    authority,
                    frame_index,
                    slot_index,
                ),
            }
        }
        try ownerState(self).reconcile(authority, frame_index);
    }

    pub fn forceDeparture(
        self: *Owner,
        authority: AuthorityPort,
        frame_index: u64,
        slot_index: usize,
    ) !void {
        try ownerState(self).ensureOperational();
        const stream_slot = try self.checkedSlot(slot_index);
        stream_slot.prefetch_proximity.inside = false;
        stream_slot.authority_proximity.inside = false;
        try ownerState(self).requestDeparture(authority, frame_index, slot_index);
    }

    pub fn pumpContent(
        self: *Owner,
        authority: AuthorityPort,
        frame_index: u64,
    ) !void {
        try ownerState(self).ensureOperational();
        try ownerState(self).pumpContent(authority, frame_index);
    }

    pub fn processOutcomes(
        self: *Owner,
        authority: AuthorityPort,
        frame_index: u64,
    ) !void {
        try ownerState(self).ensureOperational();
        try ownerState(self).processOutcomes(authority, frame_index);
    }

    pub fn pumpGpu(
        self: *Owner,
        authority: AuthorityPort,
        frame_index: u64,
    ) !GpuPump {
        try ownerState(self).ensureOperational();
        return ownerState(self).pumpGpu(authority, frame_index);
    }

    pub fn contentDigest(self: *Owner) ![32]u8 {
        const catalog = if (ownerState(self).catalog) |*value| value else return error.DistrictCatalogMissing;
        return catalog.cohortFingerprint();
    }

    pub fn slot(self: *Owner, slot_index: usize) !SlotView {
        const source = try self.checkedSlotConst(slot_index);
        return slotView(source);
    }

    pub fn slotIndexForCoord(
        self: *Owner,
        coord: district_contract.ChunkCoord,
    ) ?usize {
        return ownerState(self).slotIndexForCoord(coord);
    }

    pub fn slotResident(self: *Owner, slot_index: usize) !bool {
        const view = try self.slot(slot_index);
        if (view.phase != .active) return false;
        return (try self.sceneResidency(view.scene.?)) == .resident;
    }

    pub fn slotIdle(self: *Owner, slot_index: usize) bool {
        const slot_value = self.checkedSlotConst(slot_index) catch return false;
        return std.meta.activeTag(slot_value.state) == .idle and
            slot_value.presentation.stateTag() == .idle and
            slot_value.pending_scene == null;
    }

    pub fn contentOwnerActive(self: *Owner) bool {
        return ownerState(self).content_owner != null;
    }

    pub fn workerIdle(self: *Owner) bool {
        const worker = if (ownerState(self).worker) |*value| value else return true;
        return worker.diagnostics().state == .idle;
    }

    pub fn resolve(
        self: *Owner,
        coord: district_contract.ChunkCoord,
        ticket: district_contract.LoadTicket,
        scene: engine.rendering.SceneHandle,
    ) !district_gpu_registry.SdlSceneView {
        const slot_index = ownerState(self).slotIndexForCoord(coord) orelse
            return error.DistrictPresentationSlotMissing;
        return ownerState(self).slots[slot_index].presentation.resolve(ticket, scene);
    }

    pub fn sceneResidency(
        self: *Owner,
        scene: engine.rendering.SceneHandle,
    ) !SceneResidency {
        return residencyView(try ownerState(self).registry.residency(scene));
    }

    pub fn sceneIsStale(
        self: *Owner,
        scene: engine.rendering.SceneHandle,
    ) !bool {
        _ = ownerState(self).registry.residency(scene) catch |err| {
            if (err == error.StaleSceneHandle) return true;
            return err;
        };
        return false;
    }

    pub fn gpuUsage(self: *Owner) !developer_diagnostics.GpuUsage {
        return gpuUsageFromStats(try ownerState(self).registry.stats());
    }

    pub fn gpuDiagnostics(self: *Owner) !developer_diagnostics.Gpu {
        const source = try ownerState(self).registry.diagnostics();
        return .{
            .current = gpuUsageFromStats(source.current),
            .high_water = gpuUsageFromStats(source.high_water),
            .limits = .{
                .scene_capacity = source.limits.scene_capacity,
                .batch_capacity = source.limits.batch_capacity,
                .scenes_per_batch = source.limits.scenes_per_batch,
                .max_staged_cpu_bytes = source.limits.max_staged_cpu_bytes,
                .max_in_flight_upload_bytes = source.limits.max_in_flight_upload_bytes,
                .max_resident_gpu_bytes = source.limits.max_resident_gpu_bytes,
                .max_submit_bytes_per_pump = source.limits.max_submit_bytes_per_pump,
            },
        };
    }

    pub fn workerDiagnostics(self: *Owner) ?developer_diagnostics.ContentWorker {
        const worker = if (ownerState(self).worker) |*value| value else return null;
        const source = worker.diagnostics();
        return .{
            .stage = switch (source.state) {
                .idle => .idle,
                .queued => .queued,
                .working => .working,
                .cancelling => .cancelling,
                .completion_ready => .completion_ready,
            },
            .generation = source.generation orelse 0,
            .thread_started = source.started,
            .cancellation_requested = source.cancellation_requested,
            .completion_kind = if (source.completion_kind) |kind| switch (kind) {
                .ready => .ready,
                .cancelled => .cancelled,
                .failed => .failed,
            } else null,
        };
    }

    pub fn developerStreams(self: *Owner) developer_diagnostics.DistrictStreams {
        var result: [slot_count]developer_diagnostics.DistrictStreamSlot = undefined;
        for (&ownerState(self).slots, 0..) |*source, index| {
            const view = slotView(source);
            result[index] = .{
                .coord = .{ .x = view.coord.x, .z = view.coord.z },
                .state = switch (view.phase) {
                    .idle => .idle,
                    .reading => .reading,
                    .cancelling_content => .cancelling_content,
                    .content_ready => .content_ready,
                    .request_submitted => .request_submitted,
                    .request_submitted_cancel => .request_submitted_cancel,
                    .loading => .loading,
                    .cancelling_logical => .cancelling_logical,
                    .active => .active,
                    .unloading => .unloading,
                    .draining => .draining,
                },
                .desired_inside = view.desired_inside,
                .generations = .{
                    .content = view.content_generation,
                    .logical = if (view.ticket) |ticket| ticket.generation else null,
                },
                .correlation_id = view.correlation_id,
                .scene = view.scene,
                .pending_decoded_scene = view.pending_decoded_scene,
            };
        }
        return developer_diagnostics.DistrictStreams.init(result);
    }

    fn checkedSlot(self: *Owner, slot_index: usize) !*Slot {
        if (slot_index >= slot_count) return error.DistrictStreamingSlotOutOfRange;
        return &ownerState(self).slots[slot_index];
    }

    fn checkedSlotConst(self: *Owner, slot_index: usize) !*const Slot {
        if (slot_index >= slot_count) return error.DistrictStreamingSlotOutOfRange;
        return &ownerState(self).slots[slot_index];
    }
};

fn ownerState(owner: *Owner) *State {
    return @ptrCast(@alignCast(owner));
}

fn ensureOperationalPhase(teardown_prepared: bool) !void {
    if (teardown_prepared) return error.DistrictStreamingTeardownPrepared;
}

fn sceneHandle(state: StreamState) ?engine.rendering.SceneHandle {
    return switch (state) {
        .idle => null,
        .reading, .cancelling_content, .content_ready => |value| value.scene,
        .request_submitted, .request_submitted_cancel => |value| value.scene,
        .loading, .active => |value| value.scene,
        .cancelling_logical => |value| value.bound.scene,
        .unloading => |value| value.bound.scene,
        .draining => |value| value.scene,
    };
}

fn slotView(source: *const Slot) SlotView {
    var result = SlotView{
        .coord = source.coord,
        .phase = switch (source.state) {
            .idle => .idle,
            .reading => .reading,
            .cancelling_content => .cancelling_content,
            .content_ready => .content_ready,
            .request_submitted => .request_submitted,
            .request_submitted_cancel => .request_submitted_cancel,
            .loading => .loading,
            .cancelling_logical => .cancelling_logical,
            .active => .active,
            .unloading => .unloading,
            .draining => .draining,
        },
        // Developer residency intent is authority truth. Predicted prefetch
        // never masquerades as permission to own logical state.
        .desired_inside = source.authority_proximity.inside,
        .correlation_id = if (source.correlation == 0) null else source.correlation,
        .scene = sceneHandle(source.state),
        .pending_decoded_scene = source.pending_scene != null,
    };
    switch (source.state) {
        .idle => {},
        .reading, .cancelling_content, .content_ready => |value| {
            result.content_generation = value.generation;
        },
        .request_submitted, .request_submitted_cancel => |value| {
            result.request_id = value.request_id;
            result.content_generation = value.content_generation;
        },
        .loading, .active => |value| {
            result.ticket = value.ticket;
            result.request_id = value.load_request_id;
            result.content_generation = value.content_generation;
        },
        .cancelling_logical => |value| {
            result.ticket = value.bound.ticket;
            result.request_id = value.request_id;
            result.content_generation = value.bound.content_generation;
        },
        .unloading => |value| {
            result.ticket = value.bound.ticket;
            result.request_id = value.request_id;
            result.content_generation = value.bound.content_generation;
        },
        .draining => |value| {
            result.content_generation = value.content_generation;
        },
    }
    return result;
}

fn residencyView(source: district_gpu_registry.Residency) SceneResidency {
    return switch (source) {
        .free => .free,
        .reserved => .reserved,
        .staged => .staged,
        .submitted => .submitted,
        .retiring => .retiring,
        .resident => .resident,
    };
}

fn gpuUsageFromStats(source: district_gpu_registry.Stats) developer_diagnostics.GpuUsage {
    return .{
        .staged_cpu_bytes = source.staged_cpu_bytes,
        .staged_upload_bytes = source.staged_upload_bytes,
        .in_flight_upload_bytes = source.in_flight_upload_bytes,
        .resident_gpu_bytes = source.resident_gpu_bytes,
        .live_scenes = source.live_scenes,
        .reserved_scenes = source.reserved_scenes,
        .staged_scenes = source.staged_scenes,
        .submitted_scenes = source.submitted_scenes,
        .retiring_scenes = source.retiring_scenes,
        .resident_scenes = source.resident_scenes,
        .active_batches = source.active_batches,
    };
}

fn validateCookedLogicalDistrict(
    view: content.bundle.BundleView,
    coord: district_contract.ChunkCoord,
) !void {
    const expected = try sandbox_host_contracts.proceduralDistrictBuild(coord);
    if (view.static_boxes.len != expected.boxes().len) {
        return error.CookedDistrictLogicalShapeMismatch;
    }
    for (view.static_boxes, expected.boxes()) |cooked, logical| {
        if (!std.meta.eql(cooked.position, logical.pose.position) or
            !std.meta.eql(cooked.rotation, logical.pose.rotation) or
            !std.meta.eql(cooked.half_extents, logical.half_extents))
        {
            return error.CookedDistrictLogicalShapeMismatch;
        }
    }
}

fn isRetryableStageError(err: anyerror) bool {
    return err == error.DistrictStagingBudgetExceeded or
        err == error.DistrictResidentBudgetExceeded;
}

fn takeMonotonicId(next: *u64) !u64 {
    if (next.* == 0 or next.* == std.math.maxInt(u64)) {
        return error.DistrictSequenceExhausted;
    }
    const result = next.*;
    next.* += 1;
    return result;
}

pub fn validateCatalogEntries(entries: anytype) !void {
    if (entries.len != slot_count) return error.DistrictCatalogSlotMismatch;
    var present: [slot_count]bool = @splat(false);
    for (entries) |entry| {
        const coord = district_contract.ChunkCoord{ .x = entry.coord.x, .z = entry.coord.z };
        var matched = false;
        for (sandbox_recipe.presentation_policies, 0..) |policy, index| {
            if (!district_contract.ChunkCoord.eql(coord, policy.coord)) continue;
            if (present[index]) return error.DistrictCatalogSlotMismatch;
            present[index] = true;
            matched = true;
            break;
        }
        if (!matched) return error.DistrictCatalogSlotMismatch;
    }
    for (present) |value| if (!value) return error.DistrictCatalogSlotMismatch;
}

test "monotonic district stream identifiers reject invalid and exhausted state" {
    var next: u64 = 1;
    try std.testing.expectEqual(@as(u64, 1), try takeMonotonicId(&next));
    try std.testing.expectEqual(@as(u64, 2), try takeMonotonicId(&next));

    var invalid: u64 = 0;
    try std.testing.expectError(error.DistrictSequenceExhausted, takeMonotonicId(&invalid));
    var exhausted: u64 = std.math.maxInt(u64);
    try std.testing.expectError(error.DistrictSequenceExhausted, takeMonotonicId(&exhausted));
}

test "only bounded GPU pressure is a retryable district stage failure" {
    try std.testing.expect(isRetryableStageError(error.DistrictStagingBudgetExceeded));
    try std.testing.expect(isRetryableStageError(error.DistrictResidentBudgetExceeded));
    try std.testing.expect(!isRetryableStageError(error.OutOfMemory));
    try std.testing.expect(!isRetryableStageError(error.InvalidSceneMaterial));
}

test "prepared district streaming lifecycle rejects further state advancement" {
    try ensureOperationalPhase(false);
    try std.testing.expectError(
        error.DistrictStreamingTeardownPrepared,
        ensureOperationalPhase(true),
    );
}

test "catalog admission requires each fixed stream coordinate exactly once" {
    const Entry = struct { coord: district_contract.ChunkCoord };
    const west = sandbox_recipe.presentation_policies[west_slot_index].coord;
    const east = sandbox_recipe.presentation_policies[east_slot_index].coord;

    try validateCatalogEntries(&[_]Entry{
        .{ .coord = west },
        .{ .coord = east },
    });
    try validateCatalogEntries(&[_]Entry{
        .{ .coord = east },
        .{ .coord = west },
    });
    try std.testing.expectError(
        error.DistrictCatalogSlotMismatch,
        validateCatalogEntries(&[_]Entry{.{ .coord = west }}),
    );
    try std.testing.expectError(
        error.DistrictCatalogSlotMismatch,
        validateCatalogEntries(&[_]Entry{
            .{ .coord = west },
            .{ .coord = west },
        }),
    );
    try std.testing.expectError(
        error.DistrictCatalogSlotMismatch,
        validateCatalogEntries(&[_]Entry{
            .{ .coord = west },
            .{ .coord = .{ .x = east.x + 1, .z = east.z } },
        }),
    );
}

test "slot inspection projects private lifecycle without exposing ownership" {
    const coord = sandbox_recipe.presentation_policies[0].coord;
    var source = Slot{
        .coord = coord,
        .presentation = undefined,
        .state = .{ .active = .{
            .scene = .{ .index = 2, .generation = 7 },
            .ticket = .{ .coord = coord, .generation = 11 },
            .load_request_id = 13,
            .content_generation = 17,
        } },
        .prefetch_proximity = undefined,
        .authority_proximity = undefined,
        .correlation = 19,
    };
    source.prefetch_proximity.inside = true;
    source.authority_proximity.inside = true;
    const view = slotView(&source);
    try std.testing.expectEqual(Phase.active, view.phase);
    try std.testing.expect(view.desired_inside);
    try std.testing.expectEqual(@as(?u64, 19), view.correlation_id);
    try std.testing.expectEqual(@as(?u64, 17), view.content_generation);
    try std.testing.expectEqual(@as(?u64, 13), view.request_id);
    try std.testing.expectEqual(@as(?u64, 11), view.ticket.?.generation);

    source.authority_proximity.inside = false;
    try std.testing.expect(source.wantsContent());
    try std.testing.expect(!slotView(&source).desired_inside);
}

test "host owner exposes no registry worker or mutable slot implementation" {
    try std.testing.expect(switch (@typeInfo(Owner)) {
        .@"opaque" => true,
        else => false,
    });
    try std.testing.expect(!@hasDecl(Owner, "State"));
}

const TestAuthority = struct {
    outcomes: [3]districts.Outcome = undefined,
    outcome_len: usize = 0,
    outcome_index: usize = 0,
    logical_state: ?districts.StateTag = null,
    active_ticket: ?district_contract.LoadTicket = null,
    submitted: ?districts.Command = null,
    submit_count: u8 = 0,
    record_count: u8 = 0,

    fn port(self: *TestAuthority) AuthorityPort {
        return .{
            .context = self,
            .submit_fn = submit,
            .poll_outcome_fn = pollOutcome,
            .poll_event_fn = pollEvent,
            .state_fn = state,
            .active_ticket_fn = activeTicket,
            .presentation_fn = presentation,
            .tick_index_fn = tickIndex,
            .record_fn = record,
        };
    }

    fn from(context: *anyopaque) *TestAuthority {
        return @ptrCast(@alignCast(context));
    }

    fn submit(context: *anyopaque, command: districts.Command) !void {
        const self = from(context);
        self.submitted = command;
        self.submit_count += 1;
    }

    fn pollOutcome(context: *anyopaque) ?districts.Outcome {
        const self = from(context);
        if (self.outcome_index >= self.outcome_len) return null;
        defer self.outcome_index += 1;
        return self.outcomes[self.outcome_index];
    }

    fn pollEvent(_: *anyopaque) ?districts.Event {
        return null;
    }

    fn state(
        context: *anyopaque,
        _: district_contract.ChunkCoord,
    ) ?districts.StateTag {
        return from(context).logical_state;
    }

    fn activeTicket(
        context: *anyopaque,
        _: district_contract.ChunkCoord,
    ) ?district_contract.LoadTicket {
        return from(context).active_ticket;
    }

    fn presentation(_: *anyopaque) ![]const districts.DistrictDraw {
        return &.{};
    }

    fn tickIndex(_: *anyopaque) u64 {
        return 7;
    }

    fn record(
        context: *anyopaque,
        _: engine.runtime.DiagnosticEntry,
    ) engine.runtime.DiagnosticAppendResult {
        const self = from(context);
        self.record_count += 1;
        return .{ .accepted = true, .sequence = self.record_count };
    }
};

fn inertTestDevice() @FieldType(district_gpu_registry.SdlBackend, "device") {
    // These owner tests never stage or pump GPU work. The non-null token is
    // retained only by the inert backend and is never dereferenced.
    return @ptrFromInt(1);
}

fn initAndDestroyTestOwner(allocator: std.mem.Allocator) !void {
    const owner = try Owner.init(
        std.testing.io,
        allocator,
        inertTestDevice(),
        .{ .stream_content = false, .admit_catalog = false, .content_root = null },
    );
    // Exercise the Release-safe fallback path, not only the documented
    // explicit preparation sequence.
    owner.deinitAfterAuthority();
}

test "owner initialization rollback and implicit teardown release every allocation" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        initAndDestroyTestOwner,
        .{},
    );
    try std.testing.expectError(
        error.DistrictStreamingCatalogRequired,
        Owner.init(
            std.testing.io,
            std.testing.allocator,
            inertTestDevice(),
            .{ .stream_content = true, .admit_catalog = false, .content_root = null },
        ),
    );
    try std.testing.expectError(
        error.ContentRootRequired,
        Owner.init(
            std.testing.io,
            std.testing.allocator,
            inertTestDevice(),
            .{ .stream_content = false, .admit_catalog = true, .content_root = null },
        ),
    );
}

test "owner drives authority port lifecycle stale handles and teardown guard" {
    var owner: ?*Owner = try Owner.init(
        std.testing.io,
        std.testing.allocator,
        inertTestDevice(),
        .{ .stream_content = false, .admit_catalog = false, .content_root = null },
    );
    defer if (owner) |value| value.abortInit();
    const value = owner.?;
    const state = ownerState(value);
    const slot_index = west_slot_index;
    const coord = state.slots[slot_index].coord;
    const scene = try state.slots[slot_index].presentation.beginRequest();
    const ticket = district_contract.LoadTicket{ .coord = coord, .generation = 3 };
    const persistent = engine.PersistentId{ .namespace = 81, .local = 9 };
    state.slots[slot_index].state = .{ .request_submitted = .{
        .scene = scene,
        .request_id = 41,
        .content_generation = 5,
    } };
    state.slots[slot_index].correlation = 1;

    var authority = TestAuthority{};
    authority.logical_state = .active;
    authority.active_ticket = ticket;
    authority.outcomes[0] = .{ .load_requested = .{
        .request_id = 41,
        .ticket = ticket,
    } };
    authority.outcomes[1] = .{ .activated = .{
        .request_id = 41,
        .ticket = ticket,
        .id = persistent,
        .coord = coord,
        .static_box_count = 1,
    } };
    authority.outcome_len = 2;
    try value.processOutcomes(authority.port(), 11);
    try std.testing.expectEqual(Phase.active, (try value.slot(slot_index)).phase);
    try std.testing.expect(authority.record_count >= 2);

    var stale_scene = scene;
    stale_scene.generation += 1;
    try std.testing.expectError(
        error.StaleSceneHandle,
        value.resolve(coord, ticket, stale_scene),
    );

    try value.forceDeparture(authority.port(), 12, slot_index);
    const unload = switch (authority.submitted orelse
        return error.TestExpectedDistrictUnload) {
        .unload => |command| command,
        else => return error.TestExpectedDistrictUnload,
    };
    try std.testing.expect(district_contract.LoadTicket.eql(ticket, unload.ticket));
    try std.testing.expectEqual(@as(u8, 1), authority.submit_count);

    authority.logical_state = null;
    authority.active_ticket = null;
    authority.outcomes[2] = .{ .unloaded = .{
        .request_id = unload.request_id,
        .ticket = ticket,
        .id = persistent,
    } };
    authority.outcome_len = 3;
    try value.processOutcomes(authority.port(), 13);
    try value.updateAuthorityResidency(authority.port(), 14, .{ 1000, 1000 });
    try std.testing.expect(value.slotIdle(slot_index));
    try std.testing.expect(try value.sceneIsStale(scene));

    value.prepareAuthorityTeardown();
    value.prepareAuthorityTeardown();
    try std.testing.expectError(
        error.DistrictStreamingTeardownPrepared,
        value.updateAuthorityResidency(authority.port(), 15, .{ 0, 0 }),
    );
    value.deinitAfterAuthority();
    owner = null;
}
