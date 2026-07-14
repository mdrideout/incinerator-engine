//! Opaque visual-host owner for developer controls, diagnostics, profiling,
//! editor state, and optional physics-debug presentation.
//!
//! The graphical composition supplies short-lived authority and streaming
//! diagnostic ports plus one-frame editor extension borrows. This owner never
//! receives a Simulation, session authority, persistence adapter, or gameplay
//! feature implementation.

const std = @import("std");
const build_options = @import("build_options");
const engine = @import("incinerator_engine");
const zm = @import("zmath");
const developer_controls = @import("developer_controls");
const developer_diagnostics = @import("developer_diagnostics");
const developer_profile = @import("developer_profile");
const developer_visualization = @import("developer_visualization");
const authority_diagnostics = @import("session_authority_diagnostics");
const sandbox_contracts = @import("sandbox_host_contracts");
const renderer = @import("../renderer.zig");
const physics_debug_gpu = @import("../physics_debug_gpu.zig");
const timing = @import("../timing.zig");
const camera = @import("../camera.zig");
const input = @import("../input.zig");
const sdl = @import("../sdl.zig");
const editor_contract = @import("../editor/tool.zig");
const editor = if (build_options.editor_enabled)
    @import("../editor/editor.zig")
else
    @import("../editor/disabled.zig");

const c = sdl.c;

pub const Snapshot = developer_diagnostics.Snapshot(sandbox_contracts.Diagnostics);
const Export = developer_diagnostics.Export(sandbox_contracts.Diagnostics);
pub const ProfileSpanView = developer_profile.SpanRing(
    developer_profile.default_span_capacity,
).BorrowedView;
pub const ProfileFrameView = developer_profile.FrameRing(
    developer_profile.default_frame_capacity,
).BorrowedView;

pub const diagnostic_codes = struct {
    pub const host_control_applied: engine.diagnostic_contracts.Code = 0x000b_0001;
    pub const host_control_rejected: engine.diagnostic_contracts.Code = 0x000b_0002;
};

pub const physics_debug_default_slot_count = physics_debug_gpu.default_slot_count;

const debug_print_interval: u32 = 120;
const physics_debug_line_capacity: usize = 32_768;
const physics_debug_triangle_capacity: usize = 16_384;

pub const AuthorityPort = struct {
    context: *anyopaque,
    simulation_diagnostics_fn: *const fn (*anyopaque) sandbox_contracts.Diagnostics,
    session_diagnostics_fn: *const fn (*anyopaque) authority_diagnostics.Diagnostics,
    journal_fn: *const fn (*anyopaque) *const engine.runtime.DiagnosticJournal,
    record_fn: *const fn (
        *anyopaque,
        engine.runtime.DiagnosticEntry,
    ) engine.runtime.DiagnosticAppendResult,
    arm_freeze_fn: *const fn (*anyopaque, engine.runtime.DiagnosticFreezeMatch) void,
    disarm_freeze_fn: *const fn (*anyopaque) bool,
    resume_capture_fn: *const fn (*anyopaque) bool,
    clear_fn: *const fn (*anyopaque) void,
    extract_physics_debug_fn: *const fn (
        *anyopaque,
        engine.physics_debug.Config,
        *engine.physics_debug.Storage,
    ) anyerror!engine.physics_debug.Batch,

    pub fn simulationDiagnostics(self: AuthorityPort) sandbox_contracts.Diagnostics {
        return self.simulation_diagnostics_fn(self.context);
    }

    pub fn sessionDiagnostics(self: AuthorityPort) authority_diagnostics.Diagnostics {
        return self.session_diagnostics_fn(self.context);
    }

    pub fn journal(self: AuthorityPort) *const engine.runtime.DiagnosticJournal {
        return self.journal_fn(self.context);
    }

    fn record(
        self: AuthorityPort,
        entry: engine.runtime.DiagnosticEntry,
    ) engine.runtime.DiagnosticAppendResult {
        return self.record_fn(self.context, entry);
    }

    fn armFreeze(
        self: AuthorityPort,
        condition: engine.runtime.DiagnosticFreezeMatch,
    ) void {
        self.arm_freeze_fn(self.context, condition);
    }

    fn disarmFreeze(self: AuthorityPort) bool {
        return self.disarm_freeze_fn(self.context);
    }

    fn resumeCapture(self: AuthorityPort) bool {
        return self.resume_capture_fn(self.context);
    }

    fn clear(self: AuthorityPort) void {
        self.clear_fn(self.context);
    }

    fn extractPhysicsDebug(
        self: AuthorityPort,
        config: engine.physics_debug.Config,
        storage: *engine.physics_debug.Storage,
    ) !engine.physics_debug.Batch {
        return self.extract_physics_debug_fn(self.context, config, storage);
    }
};

pub const StreamingDiagnosticsPort = struct {
    context: *anyopaque,
    worker_fn: *const fn (*anyopaque) ?developer_diagnostics.ContentWorker,
    streams_fn: *const fn (*anyopaque) developer_diagnostics.DistrictStreams,
    gpu_fn: *const fn (*anyopaque) anyerror!developer_diagnostics.Gpu,

    fn worker(self: StreamingDiagnosticsPort) ?developer_diagnostics.ContentWorker {
        return self.worker_fn(self.context);
    }

    fn streams(self: StreamingDiagnosticsPort) developer_diagnostics.DistrictStreams {
        return self.streams_fn(self.context);
    }

    fn gpu(self: StreamingDiagnosticsPort) !developer_diagnostics.Gpu {
        return self.gpu_fn(self.context);
    }
};

pub const FrameInput = struct {
    camera: *const camera.Camera,
    frame_timer: *const timing.FrameTimer,
    include_district_streams: bool,
    authoring: editor_contract.AuthoringInput,
    interaction: editor_contract.InteractionInput,
};

pub const Effects = struct {
    reset_gameplay_actions: bool = false,

    pub fn merge(self: *Effects, other: Effects) void {
        self.reset_gameplay_actions = self.reset_gameplay_actions or
            other.reset_gameplay_actions;
    }
};

fn profileNowNs() u64 {
    return c.SDL_GetTicksNS();
}

fn profilePhase(phase: engine.Phase) developer_profile.Phase {
    return switch (phase) {
        .commands => .runtime_commands,
        .pre_physics => .runtime_pre_physics,
        .physics => .physics,
        .post_physics => .runtime_post_physics,
    };
}

pub const ProfileScope = struct {
    recorder: *developer_profile.DefaultRecorder,
    token: ?developer_profile.SpanToken,

    pub fn finish(self: *ProfileScope, outcome: developer_profile.Outcome) void {
        const token = self.token orelse return;
        self.token = null;
        _ = self.recorder.spans.finish(token, profileNowNs(), outcome);
    }
};

pub const RuntimeProfileScope = struct {
    recorder: *developer_profile.DefaultRecorder,
    frame_index: u64,
    enabled: bool,
    open: [std.meta.tags(engine.Phase).len]?developer_profile.SpanToken =
        @splat(null),

    pub fn observer(self: *RuntimeProfileScope) ?engine.PhaseObserver {
        if (!self.enabled) return null;
        return .{
            .context = self,
            .begin_fn = begin,
            .end_fn = end,
        };
    }

    fn begin(raw: *anyopaque, phase: engine.Phase, tick: engine.TickContext) void {
        const self: *RuntimeProfileScope = @ptrCast(@alignCast(raw));
        const index: usize = @intFromEnum(phase);
        if (self.open[index]) |stale| {
            _ = self.recorder.spans.finish(stale, profileNowNs(), .failure);
        }
        self.open[index] = self.recorder.spans.begin(
            profilePhase(phase),
            self.frame_index,
            tick.tick_index,
            profileNowNs(),
        );
    }

    fn end(
        raw: *anyopaque,
        phase: engine.Phase,
        _: engine.TickContext,
        outcome: engine.PhaseOutcome,
    ) void {
        const self: *RuntimeProfileScope = @ptrCast(@alignCast(raw));
        const index: usize = @intFromEnum(phase);
        const token = self.open[index] orelse return;
        self.open[index] = null;
        _ = self.recorder.spans.finish(
            token,
            profileNowNs(),
            switch (outcome) {
                .succeeded => .success,
                .failed => .failure,
            },
        );
    }
};

const ActiveFrameProfile = struct {
    token: ?developer_profile.FrameToken,
    counts: developer_profile.Counts = .{},
};

const PhysicsDebugCpuStorage = struct {
    allocator: std.mem.Allocator,
    lines: []engine.physics_debug.Line,
    triangles: []engine.physics_debug.Triangle,
    storage: engine.physics_debug.Storage,

    fn init(
        allocator: std.mem.Allocator,
        report_failure: bool,
    ) ?PhysicsDebugCpuStorage {
        const lines = allocator.alloc(
            engine.physics_debug.Line,
            physics_debug_line_capacity,
        ) catch |err| {
            if (report_failure) std.debug.print(
                "Physics debug CPU line storage unavailable: {s}\n",
                .{@errorName(err)},
            );
            return null;
        };
        const triangles = allocator.alloc(
            engine.physics_debug.Triangle,
            physics_debug_triangle_capacity,
        ) catch |err| {
            allocator.free(lines);
            if (report_failure) std.debug.print(
                "Physics debug CPU triangle storage unavailable: {s}\n",
                .{@errorName(err)},
            );
            return null;
        };
        return .{
            .allocator = allocator,
            .lines = lines,
            .triangles = triangles,
            .storage = engine.physics_debug.Storage.init(lines, triangles),
        };
    }

    fn deinit(self: *PhysicsDebugCpuStorage) void {
        self.allocator.free(self.triangles);
        self.allocator.free(self.lines);
        self.* = undefined;
    }
};

const State = struct {
    allocator: std.mem.Allocator,
    editor: editor.Editor,
    controller: developer_controls.Controller = .{},
    control_requests: developer_controls.RequestBuffer = .{},
    diagnostic_requests: developer_diagnostics.RequestBuffer = .{},
    profiler: developer_profile.DefaultRecorder = .{},
    visualization_controller: developer_visualization.Controller = .{},
    visualization_requests: developer_visualization.RequestBuffer = .{},
    active_frame_profile: ?ActiveFrameProfile = null,
    physics_debug_cpu: ?PhysicsDebugCpuStorage,
    physics_debug_batch_summary: ?developer_visualization.BatchSummary = null,
    physics_debug_overlay: ?physics_debug_gpu.Overlay,
    debug_frame_counter: u32 = 0,
};

fn ownerState(owner: *Owner) *State {
    return @ptrCast(@alignCast(owner));
}

fn ownerStateConst(owner: *const Owner) *const State {
    return @ptrCast(@alignCast(owner));
}

fn requestedVisualizationEnable(
    requests: []const developer_visualization.Request,
) ?bool {
    var requested: ?bool = null;
    for (requests) |request| switch (request) {
        .set_enabled => |enabled| requested = enabled,
        else => {},
    };
    return requested;
}

/// Move-only, heap-stable developer owner. The stable allocation keeps editor
/// event-sink context valid when the containing graphical App moves by value.
pub const Owner = opaque {
    pub fn init(
        allocator: std.mem.Allocator,
        window: *c.SDL_Window,
        gpu_renderer: *renderer.Renderer,
    ) !*Owner {
        const state = try allocator.create(State);
        errdefer allocator.destroy(state);

        var cpu = PhysicsDebugCpuStorage.init(allocator, true);
        errdefer if (cpu) |*value| value.deinit();
        var overlay: ?physics_debug_gpu.Overlay = if (cpu != null)
            physics_debug_gpu.Overlay.init(gpu_renderer, .{
                .line_capacity = @intCast(physics_debug_line_capacity),
                .triangle_capacity = @intCast(physics_debug_triangle_capacity),
                .initially_enabled = false,
            }) catch |err| blk: {
                std.debug.print(
                    "Physics debug GPU overlay unavailable: {s}\n",
                    .{@errorName(err)},
                );
                break :blk null;
            }
        else
            null;
        errdefer if (overlay) |*value| value.deinit();

        state.* = .{
            .allocator = allocator,
            .editor = editor.Editor.init(
                window,
                gpu_renderer.getDevice(),
                gpu_renderer.getSwapchainFormat(),
            ),
            .physics_debug_cpu = cpu,
            .physics_debug_overlay = overlay,
        };
        return @ptrCast(state);
    }

    pub fn deinit(self: *Owner) void {
        const state = ownerState(self);
        state.editor.deinit();
        if (state.physics_debug_overlay) |*overlay| overlay.deinit();
        state.physics_debug_overlay = null;
        if (state.physics_debug_cpu) |*cpu| cpu.deinit();
        state.physics_debug_cpu = null;
        const allocator = state.allocator;
        allocator.destroy(state);
    }

    pub fn eventSink(self: *Owner) input.EventSink {
        return ownerState(self).editor.eventSink();
    }

    pub fn processEditorEvent(self: *Owner, event: *const c.SDL_Event) input.EventRoute {
        return ownerState(self).editor.processEvent(event);
    }

    pub fn editorVisible(self: *const Owner) bool {
        return ownerStateConst(self).editor.isVisible();
    }

    pub fn clockPolicy(self: *const Owner) developer_controls.ClockPolicy {
        return ownerStateConst(self).controller.clockPolicy();
    }

    pub fn paused(self: *const Owner) bool {
        return ownerStateConst(self).controller.paused;
    }

    pub fn takeSingleStep(self: *Owner) bool {
        return ownerState(self).controller.takeSingleStep();
    }

    pub fn controlSnapshot(self: *const Owner) developer_controls.Snapshot {
        return ownerStateConst(self).controller.snapshot();
    }

    pub fn hasRetainedFault(_: *const Owner, authority: AuthorityPort) bool {
        return authority.simulationDiagnostics().first_fault != null or
            authority.sessionDiagnostics().first_cycle_fault != null;
    }

    pub fn beginHostProfile(
        self: *Owner,
        phase: developer_profile.Phase,
        frame_index: ?u64,
        tick_index: ?u64,
    ) ProfileScope {
        const state = ownerState(self);
        return .{
            .recorder = &state.profiler,
            .token = if (state.visualization_controller.profiling_enabled)
                state.profiler.spans.begin(
                    phase,
                    frame_index,
                    tick_index,
                    profileNowNs(),
                )
            else
                null,
        };
    }

    pub fn runtimeProfile(
        self: *Owner,
        frame_index: u64,
    ) RuntimeProfileScope {
        const state = ownerState(self);
        return .{
            .recorder = &state.profiler,
            .frame_index = frame_index,
            .enabled = state.visualization_controller.profiling_enabled,
        };
    }

    pub fn beginFrameProfile(
        self: *Owner,
        frame_index: u64,
        tick_index: u64,
    ) void {
        const state = ownerState(self);
        if (state.active_frame_profile != null) self.finishFrameProfile(.failure);
        state.active_frame_profile = .{
            .token = if (state.visualization_controller.profiling_enabled)
                state.profiler.frames.begin(
                    frame_index,
                    tick_index,
                    profileNowNs(),
                )
            else
                null,
        };
    }

    pub fn finishFrameProfile(
        self: *Owner,
        outcome: developer_profile.Outcome,
    ) void {
        const state = ownerState(self);
        const active = state.active_frame_profile orelse return;
        state.active_frame_profile = null;
        const token = active.token orelse return;
        _ = state.profiler.frames.finish(
            token,
            profileNowNs(),
            outcome,
            active.counts,
        );
    }

    pub fn mergeProfileCounts(
        self: *Owner,
        counts: developer_profile.Counts,
    ) void {
        if (ownerState(self).active_frame_profile) |*frame| {
            frame.counts.merge(counts);
        }
    }

    pub fn snapshot(
        self: *const Owner,
        authority: AuthorityPort,
        streaming: StreamingDiagnosticsPort,
        frame_timer: *const timing.FrameTimer,
        include_district_streams: bool,
    ) !Snapshot {
        const state = ownerStateConst(self);
        const controller = state.controller.snapshot();
        const journal_stats = authority.journal().stats();
        return .{
            .frame_index = frame_timer.total_frames,
            .simulation = authority.simulationDiagnostics(),
            .authority_session = authority.sessionDiagnostics(),
            .content_worker = streaming.worker(),
            .district_streams = if (include_district_streams)
                streaming.streams()
            else
                null,
            .gpu = try streaming.gpu(),
            .host_time = .{
                .paused = controller.paused,
                .time_scale = controller.time_scale,
                .single_step_pending = controller.single_step_pending,
                .raw_frame_seconds = frame_timer.getDeltaTime(),
                .simulation_frame_seconds = frame_timer.getSimulationDeltaTime(),
                .ticks_this_frame = frame_timer.ticks_this_frame,
                .control_requests_rejected = state.control_requests.rejected,
                .diagnostic_requests_rejected = state.diagnostic_requests.rejected,
            },
            .journal = .{
                .count = @intCast(journal_stats.count),
                .capacity = @intCast(journal_stats.capacity),
                .overwritten = journal_stats.overwritten,
                .rejected_while_frozen = journal_stats.rejected_while_frozen,
                .rejected_sequence_exhausted = journal_stats.rejected_sequence_exhausted,
                .sequence_exhausted = journal_stats.sequence_exhausted,
                .frozen = journal_stats.frozen,
                .trigger_armed = journal_stats.trigger_armed,
            },
        };
    }

    pub fn applyControlRequests(
        self: *Owner,
        authority: AuthorityPort,
        frame_index: u64,
        requests: []const developer_controls.Request,
    ) Effects {
        const state = ownerState(self);
        var effects = Effects{};
        for (requests) |request| {
            if (self.hasRetainedFault(authority)) switch (request) {
                .set_paused => |requested_paused| if (!requested_paused) {
                    self.recordRejectedControl(authority, frame_index, error.RuntimeFaulted);
                    continue;
                },
                .single_step => {
                    self.recordRejectedControl(authority, frame_index, error.RuntimeFaulted);
                    continue;
                },
                .set_time_scale => {},
            };
            const result = state.controller.apply(request) catch |err| {
                self.recordRejectedControl(authority, frame_index, err);
                continue;
            };
            effects.reset_gameplay_actions = effects.reset_gameplay_actions or
                result.entered_pause;
            _ = authority.record(.{
                .severity = .info,
                .category = .host,
                .code = diagnostic_codes.host_control_applied,
                .frame_index = frame_index,
                .thread_role = .host,
                .thread_id = engine.diagnostics.currentThreadId(),
                .correlation_id = @intFromEnum(std.meta.activeTag(request)),
            });
        }
        return effects;
    }

    fn recordRejectedControl(
        self: *Owner,
        authority: AuthorityPort,
        frame_index: u64,
        err: anyerror,
    ) void {
        _ = self;
        _ = authority.record(.{
            .severity = .warning,
            .category = .host,
            .code = diagnostic_codes.host_control_rejected,
            .frame_index = frame_index,
            .thread_role = .host,
            .thread_id = engine.diagnostics.currentThreadId(),
            .correlation_id = @intFromError(err),
        });
    }

    pub fn applyDiagnosticRequests(
        self: *Owner,
        authority: AuthorityPort,
        streaming: StreamingDiagnosticsPort,
        frame_timer: *const timing.FrameTimer,
        include_district_streams: bool,
        requests: []const developer_diagnostics.Request,
    ) void {
        for (requests) |request| switch (request) {
            .arm_freeze => |condition| authority.armFreeze(condition),
            .disarm_freeze => _ = authority.disarmFreeze(),
            .resume_capture => _ = authority.resumeCapture(),
            .clear => authority.clear(),
            .export_json => self.exportDiagnostics(
                authority,
                streaming,
                frame_timer,
                include_district_streams,
            ) catch |err| {
                _ = authority.record(.{
                    .severity = .warning,
                    .category = .host,
                    .code = diagnostic_codes.host_control_rejected,
                    .frame_index = frame_timer.total_frames,
                    .thread_role = .host,
                    .thread_id = engine.diagnostics.currentThreadId(),
                    .correlation_id = @intFromError(err),
                });
            },
        };
    }

    fn exportDiagnostics(
        self: *Owner,
        authority: AuthorityPort,
        streaming: StreamingDiagnosticsPort,
        frame_timer: *const timing.FrameTimer,
        include_district_streams: bool,
    ) !void {
        const json = try self.diagnosticsJsonAlloc(
            std.heap.page_allocator,
            authority,
            streaming,
            frame_timer,
            include_district_streams,
        );
        defer std.heap.page_allocator.free(json);
        std.debug.print("S4_DIAGNOSTICS_JSON {s}\n", .{json});
    }

    pub fn diagnosticsJsonAlloc(
        self: *const Owner,
        allocator: std.mem.Allocator,
        authority: AuthorityPort,
        streaming: StreamingDiagnosticsPort,
        frame_timer: *const timing.FrameTimer,
        include_district_streams: bool,
    ) ![]u8 {
        var entry_storage: [engine.runtime.DiagnosticJournal.capacity]engine.diagnostic_contracts.Entry = undefined;
        const entries = authority.journal().copyChronological(&entry_storage);
        return developer_diagnostics.formatJsonAlloc(allocator, Export{
            .snapshot = try self.snapshot(
                authority,
                streaming,
                frame_timer,
                include_district_streams,
            ),
            .entries = entries,
        });
    }

    pub fn enterFaultInspection(
        self: *Owner,
        authority: AuthorityPort,
        streaming: StreamingDiagnosticsPort,
        frame_timer: *const timing.FrameTimer,
        include_district_streams: bool,
    ) Effects {
        const state = ownerState(self);
        state.controller.single_step_pending = false;
        state.controller.paused = true;
        const value = self.snapshot(
            authority,
            streaming,
            frame_timer,
            include_district_streams,
        ) catch |err| {
            self.printFaultInspectionFallback(authority, err);
            return .{ .reset_gameplay_actions = true };
        };
        const text_value = developer_diagnostics.formatTextAlloc(
            std.heap.page_allocator,
            value,
        ) catch |err| {
            self.printFaultInspectionFallback(authority, err);
            return .{ .reset_gameplay_actions = true };
        };
        defer std.heap.page_allocator.free(text_value);
        std.debug.print("RUNTIME_FAULT_INSPECTION {s}\n", .{text_value});
        return .{ .reset_gameplay_actions = true };
    }

    fn printFaultInspectionFallback(
        _: *Owner,
        authority: AuthorityPort,
        reporting_error: anyerror,
    ) void {
        if (authority.simulationDiagnostics().first_fault) |fault| {
            std.debug.print(
                "RUNTIME_FAULT_INSPECTION_FALLBACK phase={s} tick={d} " ++
                    "system={s}{s} error={s}{s} code={d} sequence={d} reporting_error={s}\n",
                .{
                    @tagName(fault.phase),
                    fault.tick_index,
                    fault.system_name.slice(),
                    if (fault.system_name.truncated) "[truncated]" else "",
                    fault.error_name.slice(),
                    if (fault.error_name.truncated) "[truncated]" else "",
                    fault.error_code,
                    fault.journal_sequence,
                    @errorName(reporting_error),
                },
            );
            return;
        }
        if (authority.sessionDiagnostics().first_cycle_fault) |fault| {
            std.debug.print(
                "RUNTIME_FAULT_INSPECTION_FALLBACK authority_stage={s} " ++
                    "target_tick={d} completed_tick={d} error={s}{s} " ++
                    "code={d} reporting_error={s}\n",
                .{
                    @tagName(fault.stage),
                    fault.target_tick,
                    fault.completed_tick,
                    fault.error_name.slice(),
                    if (fault.error_name.truncated) "[truncated]" else "",
                    fault.error_code,
                    @errorName(reporting_error),
                },
            );
            return;
        }
        std.debug.print(
            "RUNTIME_FAULT_INSPECTION_FALLBACK retained_fault=missing reporting_error={s}\n",
            .{@errorName(reporting_error)},
        );
    }

    pub fn visualizationSnapshot(
        self: *const Owner,
    ) developer_visualization.Snapshot {
        const state = ownerStateConst(self);
        return .{
            .config = state.visualization_controller.config,
            .profiling_enabled = state.visualization_controller.profiling_enabled,
            .rejected_requests = state.visualization_requests.rejected,
            .cpu_available = state.physics_debug_cpu != null,
            .batch = state.physics_debug_batch_summary,
            .gpu = if (state.physics_debug_overlay) |*overlay| blk: {
                const stats = overlay.stats();
                const resources = stats.resources;
                const uploaded = stats.latest_uploaded_generation != 0;
                break :blk developer_visualization.GpuSummary{
                    .available = true,
                    .enabled = stats.mode == .enabled,
                    .uploaded_generation = stats.latest_uploaded_generation,
                    .line_vertices = if (uploaded) stats.retained_line_vertices else 0,
                    .triangle_vertices = if (uploaded) stats.retained_triangle_vertices else 0,
                    .upload_bytes = if (uploaded) stats.retained_upload_bytes else 0,
                    .uploads = stats.successful_uploads,
                    .draws = stats.draw_calls,
                    .dropped_batches = stats.failed_uploads +| stats.skipped_uploads,
                    .failures = stats.failed_uploads,
                    .backpressure_drops = stats.backpressure_drops,
                    .slot_count = resources.slot_count,
                    .free_slots = resources.free_slots,
                    .busy_slots = resources.busy_slots,
                    .copy_pending_slots = resources.copy_pending_slots,
                    .retired_slots = resources.retired_slots,
                    .live_fences = resources.live_owned_fences,
                    .peak_fences = resources.peak_owned_fences,
                    .max_fences = resources.max_owned_fences,
                    .frame_fence_failures = stats.frame_fence_failures,
                    .slot_retirements = stats.slot_retirements,
                };
            } else developer_visualization.GpuSummary{
                .available = false,
                .enabled = false,
                .uploaded_generation = 0,
                .line_vertices = 0,
                .triangle_vertices = 0,
                .upload_bytes = 0,
                .uploads = 0,
                .draws = 0,
                .dropped_batches = 0,
                .failures = 0,
                .backpressure_drops = 0,
                .slot_count = 0,
                .free_slots = 0,
                .busy_slots = 0,
                .copy_pending_slots = 0,
                .retired_slots = 0,
                .live_fences = 0,
                .peak_fences = 0,
                .max_fences = 0,
                .frame_fence_failures = 0,
                .slot_retirements = 0,
            },
        };
    }

    pub fn applyVisualizationRequests(
        self: *Owner,
        requests: []const developer_visualization.Request,
    ) void {
        const state = ownerState(self);
        var clear_profile_history = false;
        const overlay_enable_request = requestedVisualizationEnable(requests);
        for (requests) |request| {
            clear_profile_history = state.visualization_controller.apply(request) or
                clear_profile_history;
        }
        if (overlay_enable_request) |enabled| {
            if (state.physics_debug_overlay) |*overlay| {
                _ = overlay.setEnabled(enabled);
            }
        }
        if (clear_profile_history) state.profiler.clearRetained();
    }

    pub fn drawEditor(
        self: *Owner,
        gpu_renderer: *renderer.Renderer,
        authority: AuthorityPort,
        streaming: StreamingDiagnosticsPort,
        frame: FrameInput,
    ) !Effects {
        const state = ownerState(self);
        state.control_requests.clear();
        state.diagnostic_requests.clear();
        state.visualization_requests.clear();
        defer {
            state.control_requests.clear();
            state.diagnostic_requests.clear();
            state.visualization_requests.clear();
        }
        const diagnostics_snapshot = try self.snapshot(
            authority,
            streaming,
            frame.frame_timer,
            frame.include_district_streams,
        );
        const visualization_snapshot = self.visualizationSnapshot();
        state.editor.draw(gpu_renderer, .{
            .camera = frame.camera,
            .frame_timer = frame.frame_timer,
            .developer = .{
                .snapshot = &diagnostics_snapshot,
                .journal = authority.journal().borrowedChronological(),
                .control_requests = &state.control_requests,
                .diagnostic_requests = &state.diagnostic_requests,
            },
            .visualization = .{
                .snapshot = &visualization_snapshot,
                .profile_spans = state.profiler.spans.view(),
                .profile_frames = state.profiler.frames.view(),
                .profile_stats = state.profiler.stats(),
                .visualization_requests = &state.visualization_requests,
            },
            .authoring = frame.authoring,
            .interaction = frame.interaction,
        });
        const effects = self.applyControlRequests(
            authority,
            frame.frame_timer.total_frames,
            state.control_requests.slice(),
        );
        self.applyDiagnosticRequests(
            authority,
            streaming,
            frame.frame_timer,
            frame.include_district_streams,
            state.diagnostic_requests.slice(),
        );
        self.applyVisualizationRequests(state.visualization_requests.slice());
        return effects;
    }

    pub fn extractPhysicsDebug(
        self: *Owner,
        authority: AuthorityPort,
        frame_index: u64,
        tick_index: u64,
    ) ?engine.physics_debug.Batch {
        const state = ownerState(self);
        const config = state.visualization_controller.config;
        if (!config.enabled) return null;
        const cpu = if (state.physics_debug_cpu) |*value| value else {
            state.physics_debug_batch_summary = null;
            return null;
        };
        var profile_scope = self.beginHostProfile(
            .debug_extraction,
            frame_index,
            tick_index,
        );
        const batch = authority.extractPhysicsDebug(.{
            .shapes = config.shapes,
            .bounds = config.bounds,
            .contacts = config.contacts,
            .centers_of_mass = config.centers_of_mass,
            .velocities = config.velocities,
        }, &cpu.storage) catch {
            profile_scope.finish(.failure);
            state.visualization_controller.config.enabled = false;
            if (state.physics_debug_overlay) |*overlay| _ = overlay.setEnabled(false);
            return null;
        };
        const summary = developer_visualization.BatchSummary.fromBatch(batch);
        state.physics_debug_batch_summary = summary;
        profile_scope.finish(.success);
        return batch;
    }

    pub fn preparePhysicsDebugFrame(
        self: *Owner,
        frame_index: u64,
    ) void {
        const state = ownerState(self);
        if (state.physics_debug_overlay) |*overlay| {
            _ = overlay.poll();
            const resources = overlay.stats().resources;
            self.mergeProfileCounts(.{
                .live_resources = @as(u64, resources.gpu_buffer_count) +
                    resources.transfer_buffer_count +
                    resources.live_owned_fences,
                .live_resource_bytes = resources.gpu_bytes +|
                    resources.transfer_bytes,
            });
        }
        const config = state.visualization_controller.config;
        if (!config.enabled) return;
        const cpu = if (state.physics_debug_cpu) |*value| value else return;
        const batch = cpu.storage.batch() orelse return;
        const overlay = if (state.physics_debug_overlay) |*value| value else return;
        if (overlay.stats().latest_attempted_generation == batch.generation) return;

        var profile_scope = self.beginHostProfile(
            .debug_upload,
            frame_index,
            batch.completed_tick,
        );
        const result = overlay.upload(batch);
        if (result.status == .copy_submitted) {
            self.mergeProfileCounts(.{
                .debug_primitives = @as(u64, result.plan.admitted_lines) +
                    result.plan.admitted_triangles,
                .debug_upload_bytes = result.plan.totalBytes(),
            });
        }
        profile_scope.finish(if (result.status.isFailure()) .failure else .success);
    }

    pub fn drawPhysicsDebug(
        self: *Owner,
        gpu_renderer: *renderer.Renderer,
        view_projection: zm.Mat,
        frame_index: u64,
    ) void {
        const state = ownerState(self);
        if (!state.visualization_controller.config.enabled) return;
        const cpu = if (state.physics_debug_cpu) |*value| value else return;
        _ = cpu.storage.batch() orelse return;
        const overlay = if (state.physics_debug_overlay) |*value| value else return;
        var profile_scope = self.beginHostProfile(.debug_draw, frame_index, null);
        const before = overlay.stats();
        const result = overlay.drawLatest(gpu_renderer, view_projection);
        const after = overlay.stats();
        self.mergeProfileCounts(.{
            .draw_calls = (after.line_draw_calls -| before.line_draw_calls) +
                (after.triangle_draw_calls -| before.triangle_draw_calls),
        });
        profile_scope.finish(switch (result.status) {
            .drawn, .empty => .success,
            else => .failure,
        });
    }

    /// Call only after the real renderer frame submission succeeded.
    pub fn afterSuccessfulFrameSubmission(
        self: *Owner,
        gpu_renderer: *renderer.Renderer,
    ) void {
        const state = ownerState(self);
        const overlay = if (state.physics_debug_overlay) |*value| value else return;
        if (!overlay.needsFrameFence()) return;
        const fence = gpu_renderer.acquirePostSubmissionFence() catch {
            overlay.noteFrameFenceFailed();
            return;
        };
        _ = overlay.noteFrameSubmitted(fence);
    }

    pub fn physicsDebugAvailable(self: *const Owner) bool {
        return ownerStateConst(self).physics_debug_overlay != null;
    }

    pub fn physicsDebugStats(self: *Owner) ?physics_debug_gpu.Stats {
        const overlay = if (ownerState(self).physics_debug_overlay) |*value| value else return null;
        _ = overlay.poll();
        return overlay.stats();
    }

    pub fn profileSpans(self: *const Owner) ProfileSpanView {
        return ownerStateConst(self).profiler.spans.view();
    }

    pub fn profileFrames(self: *const Owner) ProfileFrameView {
        return ownerStateConst(self).profiler.frames.view();
    }

    pub fn profileStats(self: *const Owner) developer_profile.RecorderStats {
        return ownerStateConst(self).profiler.stats();
    }

    pub fn maybePrintFrameStats(
        self: *Owner,
        frame_timer: *const timing.FrameTimer,
        completed_tick: u64,
    ) void {
        const state = ownerState(self);
        state.debug_frame_counter += 1;
        if (state.debug_frame_counter < debug_print_interval) return;
        state.debug_frame_counter = 0;
        std.debug.print(
            "FPS: {d:.1} | Frame time: {d:.2}ms | Sim ticks: {d} | Ticks/frame: {d}\n",
            .{
                frame_timer.getFps(),
                frame_timer.getDeltaTime() * 1000.0,
                completed_tick,
                frame_timer.ticks_this_frame,
            },
        );
    }
};

test "developer owner is opaque and enable requests are explicit" {
    switch (@typeInfo(Owner)) {
        .@"opaque" => {},
        else => return error.DeveloperOwnerMustRemainOpaque,
    }
    try std.testing.expectEqual(
        @as(?bool, null),
        requestedVisualizationEnable(&.{.{ .set_profiling_enabled = true }}),
    );
    try std.testing.expectEqual(
        @as(?bool, false),
        requestedVisualizationEnable(&.{
            .{ .set_enabled = true },
            .{ .set_enabled = false },
        }),
    );
}

test "effects merge gameplay reset monotonically" {
    var effects = Effects{};
    effects.merge(.{ .reset_gameplay_actions = true });
    effects.merge(.{});
    try std.testing.expect(effects.reset_gameplay_actions);
}

test "optional physics debug CPU storage failure remains non-fatal" {
    var fail_first = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );
    try std.testing.expect(
        PhysicsDebugCpuStorage.init(fail_first.allocator(), false) == null,
    );

    // The first reservation succeeds and the second fails. The helper must
    // release the partial owner and still report ordinary unavailability.
    var fail_second = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 1 },
    );
    try std.testing.expect(
        PhysicsDebugCpuStorage.init(fail_second.allocator(), false) == null,
    );
}
