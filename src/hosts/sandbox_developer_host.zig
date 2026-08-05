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
const incident_capture = @import("incident_capture.zig");
const incident_contract = @import("../engine/incident.zig");
const incident_screenshot = @import("../incident_screenshot.zig");
const incident_semantic = @import("../incident_semantic.zig");
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
pub const incident_hotkey_scancode = c.SDL_SCANCODE_F9;
pub const incident_hotkey_keycode = c.SDLK_F9;
pub const incident_hotkey_fallback_keycode = c.SDLK_9;
pub const incident_hotkey_recommended_keycode = c.SDLK_I;
pub const IncidentSemanticDraw = incident_semantic.Draw;
pub const incident_semantic_maximum_draws = incident_semantic.maximum_draws;

const PendingShortcutQueue = struct {
    pub const capacity: usize = 16;

    items: [capacity]incident_contract.ShortcutCandidate = undefined,
    count: u8 = 0,
    rejected: u64 = 0,

    fn push(self: *PendingShortcutQueue, candidate: incident_contract.ShortcutCandidate) bool {
        if (self.count == self.items.len) {
            self.rejected +|= 1;
            return false;
        }
        self.items[self.count] = candidate;
        self.count += 1;
        return true;
    }

    fn pop(self: *PendingShortcutQueue) ?incident_contract.ShortcutCandidate {
        if (self.count == 0) return null;
        const value = self.items[0];
        for (self.items[1..self.count], 0..) |item, index| self.items[index] = item;
        self.count -= 1;
        return value;
    }
};

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
    gameplay_trace_fn: *const fn (*anyopaque) engine.gameplay_trace.BorrowedView,
    freeze_gameplay_trace_fn: *const fn (*anyopaque) bool,
    resume_gameplay_trace_fn: *const fn (*anyopaque) bool,
    clear_gameplay_trace_fn: *const fn (*anyopaque) void,
    replay_snapshot_fn: *const fn (
        *anyopaque,
        std.mem.Allocator,
    ) anyerror![]u8,
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

    fn gameplayTrace(self: AuthorityPort) engine.gameplay_trace.BorrowedView {
        return self.gameplay_trace_fn(self.context);
    }

    fn freezeGameplayTrace(self: AuthorityPort) bool {
        return self.freeze_gameplay_trace_fn(self.context);
    }

    fn resumeGameplayTrace(self: AuthorityPort) bool {
        return self.resume_gameplay_trace_fn(self.context);
    }

    fn clearGameplayTrace(self: AuthorityPort) void {
        self.clear_gameplay_trace_fn(self.context);
    }

    fn replaySnapshotAlloc(
        self: AuthorityPort,
        allocator: std.mem.Allocator,
    ) ![]u8 {
        return self.replay_snapshot_fn(self.context, allocator);
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
    navigation: editor_contract.NavigationInput,
    population_view: *const editor_contract.PopulationView,
    gameplay_view: *const editor_contract.GameplayView,
    incident_input: incident_contract.InputSample = .{},
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
    gameplay_trace_requests: engine.gameplay_trace.RequestBuffer = .{},
    profiler: developer_profile.DefaultRecorder = .{},
    visualization_controller: developer_visualization.Controller = .{},
    visualization_requests: developer_visualization.RequestBuffer = .{},
    active_frame_profile: ?ActiveFrameProfile = null,
    physics_debug_cpu: ?PhysicsDebugCpuStorage,
    physics_debug_batch_summary: ?developer_visualization.BatchSummary = null,
    physics_debug_overlay: ?physics_debug_gpu.Overlay,
    debug_frame_counter: u32 = 0,
    incident: ?*incident_capture.Capture = null,
    incident_screenshots: ?incident_screenshot.Owner = null,
    incident_semantic: ?incident_semantic.Owner = null,
    incident_requests: incident_contract.RequestBuffer = .{},
    pending_shortcuts: PendingShortcutQueue = .{},
    window_id: c.SDL_WindowID,
    incident_clipboard: [incident_contract.max_handoff_bytes]u8 = undefined,
    incident_clipboard_publications: u64 = 0,
};

fn ownerState(owner: *Owner) *State {
    return @ptrCast(@alignCast(owner));
}

fn ownerStateConst(owner: *const Owner) *const State {
    return @ptrCast(@alignCast(owner));
}

fn defaultIncidentEntity(
    view: *const editor_contract.GameplayView,
) ?engine.gameplay_trace.EntityRef {
    for (view.entitySlice()) |entity| if (entity.kind == .local_player) {
        return entity.entity;
    };
    return if (view.entitySlice().len == 0) null else view.entitySlice()[0].entity;
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

fn processDeveloperEvent(self: *Owner, event: *const c.SDL_Event) input.EventRoute {
    const state = ownerState(self);
    if (isIncidentCandidate(event)) {
        var candidate = shortcutCandidate(state.window_id, event);
        if (state.incident) |capture| capture.recordShortcut(.received, candidate, null);
        if (isIncidentHotkey(event) and (event.key.windowID == 0 or candidate.focused)) {
            candidate.matched = true;
            if (state.incident) |capture| capture.recordShortcut(.matched, candidate, null);
            if (shouldQueueIncident(event, candidate, state.incident != null) and
                state.pending_shortcuts.push(candidate))
            {
                state.incident.?.recordShortcut(.queued, candidate, null);
            }
            return .{ .keyboard_reserved = true };
        }
    }
    return state.editor.processEvent(event);
}

fn shortcutCandidate(
    window_id: c.SDL_WindowID,
    event: *const c.SDL_Event,
) incident_contract.ShortcutCandidate {
    return .{
        .event_monotonic_ns = event.key.timestamp,
        .window_id = event.key.windowID,
        .event_type = event.type,
        .scancode = @intCast(event.key.scancode),
        .keycode = @intCast(event.key.key),
        .raw = event.key.raw,
        .modifiers = @intCast(event.key.mod),
        .repeat = event.key.repeat,
        .focused = event.key.windowID != 0 and event.key.windowID == window_id,
    };
}

fn shouldQueueIncident(
    event: *const c.SDL_Event,
    candidate: incident_contract.ShortcutCandidate,
    recorder_enabled: bool,
) bool {
    return recorder_enabled and !event.key.repeat and isIncidentHotkey(event) and
        (event.key.windowID == 0 or candidate.focused);
}

fn isIncidentCandidate(event: *const c.SDL_Event) bool {
    if (event.type != c.SDL_EVENT_KEY_DOWN and event.type != c.SDL_EVENT_KEY_UP) return false;
    return event.key.scancode == incident_hotkey_scancode or
        event.key.key == incident_hotkey_keycode or
        event.key.scancode == c.SDL_SCANCODE_9 or
        event.key.key == incident_hotkey_fallback_keycode or
        event.key.scancode == c.SDL_SCANCODE_I or
        event.key.key == incident_hotkey_recommended_keycode;
}

/// macOS function-row settings can prevent an unmodified physical F9 press
/// from reaching SDL as F9. Accept both SDL's physical and virtual identities
/// plus Command+Shift+9 and Command+Option+I application fallbacks. Every
/// route feeds the same bounded developer request queue.
fn isIncidentHotkey(event: *const c.SDL_Event) bool {
    if (event.type != c.SDL_EVENT_KEY_DOWN) return false;
    if (event.key.scancode == incident_hotkey_scancode or
        event.key.key == incident_hotkey_keycode)
    {
        return true;
    }
    const required = c.SDL_KMOD_GUI | c.SDL_KMOD_SHIFT;
    if ((event.key.key == incident_hotkey_fallback_keycode or
        event.key.scancode == c.SDL_SCANCODE_9) and
        event.key.mod & required == required) return true;
    const recommended = c.SDL_KMOD_GUI | c.SDL_KMOD_ALT;
    return (event.key.key == incident_hotkey_recommended_keycode or
        event.key.scancode == c.SDL_SCANCODE_I) and
        event.key.mod & recommended == recommended;
}

fn routeInputEvent(context: *anyopaque, event: *const c.SDL_Event) input.EventRoute {
    const self: *Owner = @ptrCast(@alignCast(context));
    return processDeveloperEvent(self, event);
}

fn inputCapture(context: *anyopaque) input.Capture {
    const self: *const Owner = @ptrCast(@alignCast(context));
    const state = ownerStateConst(self);
    return .{
        .keyboard = state.editor.wantsKeyboard(),
        .mouse = state.editor.wantsMouse(),
    };
}

fn openRunFolder(path: []const u8) void {
    const url = std.fmt.allocPrintSentinel(
        std.heap.page_allocator,
        "file://{s}",
        .{path},
        0,
    ) catch return;
    defer std.heap.page_allocator.free(url);
    if (!c.SDL_OpenURL(url.ptr)) {
        std.debug.print("Incident folder open failed: {s}\n", .{c.SDL_GetError()});
    }
}

/// Move-only, heap-stable developer owner. The stable allocation keeps editor
/// event-sink context valid when the containing graphical App moves by value.
pub const Owner = opaque {
    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        window: *c.SDL_Window,
        gpu_renderer: *renderer.Renderer,
        incident_runs_root: ?[]const u8,
        incident_hardening_profile: incident_capture.HardeningProfile,
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
            .window_id = c.SDL_GetWindowID(window),
        };
        if (incident_runs_root) |root| {
            state.incident = incident_capture.Capture.create(allocator, io, root) catch |err| unavailable: {
                std.debug.print("Incident capture unavailable: {s}\n", .{@errorName(err)});
                break :unavailable null;
            };
            if (state.incident) |capture| {
                capture.configureHardening(incident_hardening_profile);
                if (incident_hardening_profile == .queue_pressure) {
                    capture.injectQueuePressure();
                }
                capture.start() catch |err| {
                    std.debug.print("Incident writer unavailable: {s}\n", .{@errorName(err)});
                    capture.destroy();
                    state.incident = null;
                };
                if (state.incident != null) {
                    std.debug.print("Incident run: {s}\n", .{capture.runPath()});
                    state.incident_screenshots = incident_screenshot.Owner.init(
                        gpu_renderer,
                        incident_hardening_profile,
                    ) catch |err| unavailable: {
                        std.debug.print("Incident screenshots unavailable: {s}\n", .{@errorName(err)});
                        break :unavailable null;
                    };
                    state.incident_semantic = incident_semantic.Owner.init(gpu_renderer) catch |err| unavailable: {
                        std.debug.print("Incident semantic capture unavailable: {s}\n", .{@errorName(err)});
                        break :unavailable null;
                    };
                }
            }
        }
        return @ptrCast(state);
    }

    pub fn deinit(self: *Owner) void {
        const state = ownerState(self);
        if (state.incident_semantic) |*semantic| {
            if (state.incident) |capture| semantic.drain(capture);
            semantic.deinit();
        }
        state.incident_semantic = null;
        if (state.incident_screenshots) |*screenshots| {
            if (state.incident) |capture| screenshots.drain(capture);
            screenshots.deinit();
        }
        state.incident_screenshots = null;
        if (state.incident) |capture| capture.destroy();
        state.incident = null;
        state.editor.deinit();
        if (state.physics_debug_overlay) |*overlay| overlay.deinit();
        state.physics_debug_overlay = null;
        if (state.physics_debug_cpu) |*cpu| cpu.deinit();
        state.physics_debug_cpu = null;
        const allocator = state.allocator;
        allocator.destroy(state);
    }

    pub fn eventSink(self: *Owner) input.EventSink {
        return .{
            .context = self,
            .process_event = routeInputEvent,
            .capture = inputCapture,
        };
    }

    pub fn processEditorEvent(self: *Owner, event: *const c.SDL_Event) input.EventRoute {
        return processDeveloperEvent(self, event);
    }

    pub fn editorVisible(self: *const Owner) bool {
        return ownerStateConst(self).editor.isVisible();
    }

    /// Route the graphical acceptance flag through the same SDL event boundary
    /// as a human shortcut. The next editor draw applies the queued flag using
    /// the current immutable gameplay projection.
    pub fn queueIncidentHotkeyForAcceptance(self: *Owner) bool {
        const state = ownerState(self);
        if (state.incident == null) return false;
        const previous = state.pending_shortcuts.count;
        var event = std.mem.zeroes(c.SDL_Event);
        event.type = c.SDL_EVENT_KEY_DOWN;
        event.key.scancode = incident_hotkey_scancode;
        event.key.key = incident_hotkey_keycode;
        const route = processDeveloperEvent(self, &event);
        return route.keyboard_reserved and state.pending_shortcuts.count == previous +| 1;
    }

    pub fn requestIncidentHandoffWithReplayForAcceptance(
        self: *Owner,
        authority: AuthorityPort,
    ) bool {
        const capture = ownerState(self).incident orelse return false;
        const bytes = authority.replaySnapshotAlloc(std.heap.page_allocator) catch return false;
        if (!capture.attachReplay(bytes)) return false;
        return capture.requestHandoff();
    }

    pub fn incidentRunPath(self: *const Owner) ?[]const u8 {
        const capture = ownerStateConst(self).incident orelse return null;
        return capture.runPath();
    }

    pub const IncidentBenchmarkSnapshot = struct {
        enabled: bool = false,
        queue_high_water: u16 = 0,
        dropped_records: u64 = 0,
        bytes_written: u64 = 0,
        screenshot_misses: u64 = 0,
        bounded_download_bytes: u64 = 0,
        trail_submitted: u64 = 0,
        trail_completed: u64 = 0,
        anchor_submitted: u64 = 0,
        anchor_completed: u64 = 0,
        fence_latency_samples: u64 = 0,
        fence_latency_total_ns: u64 = 0,
        fence_latency_max_ns: u64 = 0,
    };

    pub const IncidentHardeningSnapshot = struct {
        writer_failed: bool = false,
        visual_budget_exhausted: bool = false,
        handoff_persisted: bool = false,
        queue_high_water: u16 = 0,
        dropped_records: u64 = 0,
        visual_budget_rejections: u64 = 0,
        screenshot_misses: u64 = 0,
        screenshot_fence_failures: u64 = 0,
        clipboard_publications: u64 = 0,
    };

    pub fn incidentHardeningSnapshot(
        self: *const Owner,
    ) IncidentHardeningSnapshot {
        const state = ownerStateConst(self);
        const capture = state.incident orelse return .{};
        const view = capture.snapshot(state.incident_requests.rejected);
        return .{
            .writer_failed = view.health.writer_failed,
            .visual_budget_exhausted = view.health.visual_budget_exhausted,
            .handoff_persisted = view.health.handoff_persisted,
            .queue_high_water = view.health.queue_high_water,
            .dropped_records = view.health.dropped_records,
            .visual_budget_rejections = view.health.visual_budget_rejections,
            .screenshot_misses = view.health.screenshot_misses,
            .screenshot_fence_failures = if (state.incident_screenshots) |*screenshots|
                screenshots.health().stats.fence_failures
            else
                0,
            .clipboard_publications = state.incident_clipboard_publications,
        };
    }

    /// Read-only measurement seam for the installed capture A/B. It exposes
    /// bounded health counters, never the recorder, files, or GPU resources.
    pub fn incidentBenchmarkSnapshot(
        self: *const Owner,
    ) IncidentBenchmarkSnapshot {
        const state = ownerStateConst(self);
        const capture = state.incident orelse return .{};
        const view = capture.snapshot(state.incident_requests.rejected);
        const screenshot_health = if (state.incident_screenshots) |*screenshots|
            screenshots.health()
        else
            return .{
                .enabled = true,
                .queue_high_water = view.health.queue_high_water,
                .dropped_records = view.health.dropped_records,
                .bytes_written = view.health.bytes_written,
                .screenshot_misses = view.health.screenshot_misses,
            };
        return .{
            .enabled = true,
            .queue_high_water = view.health.queue_high_water,
            .dropped_records = view.health.dropped_records,
            .bytes_written = view.health.bytes_written,
            .screenshot_misses = view.health.screenshot_misses,
            .bounded_download_bytes = screenshot_health.bounded_download_bytes,
            .trail_submitted = screenshot_health.stats.trail_submitted,
            .trail_completed = screenshot_health.stats.trail_completed,
            .anchor_submitted = screenshot_health.stats.anchor_submitted,
            .anchor_completed = screenshot_health.stats.anchor_completed,
            .fence_latency_samples = screenshot_health.stats.fence_latency_samples,
            .fence_latency_total_ns = screenshot_health.stats.fence_latency_total_ns,
            .fence_latency_max_ns = screenshot_health.stats.fence_latency_max_ns,
        };
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

    pub fn applyGameplayTraceRequests(
        self: *Owner,
        authority: AuthorityPort,
        frame_timer: *const timing.FrameTimer,
        requests: []const engine.gameplay_trace.Request,
    ) void {
        for (requests) |request| switch (request) {
            .freeze => _ = authority.freezeGameplayTrace(),
            .resume_capture => _ = authority.resumeGameplayTrace(),
            .clear => authority.clearGameplayTrace(),
        };
        _ = self;
        _ = frame_timer;
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
        state.gameplay_trace_requests.clear();
        state.visualization_requests.clear();
        // Incident hotkeys are collected by the event pump before this draw.
        // Editor requests join the same fixed mailbox and are applied only
        // after the immutable frame inputs are no longer borrowed.
        defer {
            state.control_requests.clear();
            state.diagnostic_requests.clear();
            state.gameplay_trace_requests.clear();
            state.visualization_requests.clear();
        }
        const diagnostics_snapshot = try self.snapshot(
            authority,
            streaming,
            frame.frame_timer,
            frame.include_district_streams,
        );
        const visualization_snapshot = self.visualizationSnapshot();
        if (state.incident) |capture| {
            capture.observe(
                authority.gameplayTrace(),
                authority.journal().borrowedChronological(),
                diagnostics_snapshot.simulation.first_fault,
                authority.sessionDiagnostics().first_cycle_fault,
                frame.gameplay_view,
                frame.incident_input,
                frame.camera.yaw,
                frame.camera.pitch,
                @floatCast(frame.frame_timer.getDeltaTime() * 1000.0),
            );
            if (state.incident_screenshots) |*screenshots| {
                const health = screenshots.health();
                capture.observeScreenshotHealth(
                    health.stats.trail_submitted,
                    health.stats.trail_completed,
                    health.stats.anchor_submitted,
                    health.stats.anchor_completed,
                    health.stats.missed,
                    health.stats.fence_failures,
                    health.stats.attached,
                    health.stats.suspicious,
                    health.anchor_width,
                    health.anchor_height,
                    health.trail_bytes_per_slot,
                    health.anchor_bytes_per_slot,
                    health.trail_slots,
                    health.anchor_slots,
                    health.bounded_download_bytes,
                );
            }
        }
        var incident_snapshot = if (state.incident) |capture|
            capture.snapshot(state.incident_requests.rejected)
        else
            incident_contract.View{};
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
            .navigation = frame.navigation,
            .population = .{
                .view = frame.population_view,
                .gameplay = frame.gameplay_view,
                .visualization = &visualization_snapshot,
                .visualization_requests = &state.visualization_requests,
            },
            .gameplay = .{
                .view = frame.gameplay_view,
                .trace = authority.gameplayTrace(),
                .requests = &state.gameplay_trace_requests,
            },
            .incident = .{
                .view = &incident_snapshot,
                .requests = &state.incident_requests,
            },
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
        self.applyGameplayTraceRequests(
            authority,
            frame.frame_timer,
            state.gameplay_trace_requests.slice(),
        );
        self.applyVisualizationRequests(state.visualization_requests.slice());
        if (state.incident) |capture| {
            while (state.pending_shortcuts.pop()) |candidate| {
                if (capture.flag(
                    frame.gameplay_view.authority_tick,
                    frame.gameplay_view.presentation_frame,
                    defaultIncidentEntity(frame.gameplay_view),
                )) |id| {
                    capture.recordShortcut(.applied, candidate, id);
                    const flagged_ns = capture.anomalyFlagNs(id).?;
                    if (state.incident_screenshots) |*screenshots| {
                        screenshots.flag(capture, id, flagged_ns);
                    }
                    if (state.incident_semantic) |*semantic| {
                        semantic.flag(capture, id, flagged_ns);
                    }
                }
            }
            for (state.incident_requests.slice()) |request| switch (request) {
                .flag => if (capture.flag(
                    frame.gameplay_view.authority_tick,
                    frame.gameplay_view.presentation_frame,
                    defaultIncidentEntity(frame.gameplay_view),
                )) |id| {
                    const flagged_ns = capture.anomalyFlagNs(id).?;
                    if (state.incident_screenshots) |*screenshots| {
                        screenshots.flag(capture, id, flagged_ns);
                    }
                    if (state.incident_semantic) |*semantic| {
                        semantic.flag(capture, id, flagged_ns);
                    }
                },
                .save_note => |note| _ = capture.saveNote(
                    note.id,
                    note.note[0..@min(@as(usize, note.note_len), note.note.len)],
                ),
                .save_note_and_copy => |note| {
                    if (!capture.saveNote(
                        note.id,
                        note.note[0..@min(@as(usize, note.note_len), note.note.len)],
                    )) continue;
                    if (authority.replaySnapshotAlloc(std.heap.page_allocator)) |bytes| {
                        _ = capture.attachReplay(bytes);
                    } else |err| {
                        std.debug.print("Incident replay attachment unavailable: {s}\n", .{@errorName(err)});
                    }
                    _ = capture.requestHandoff();
                },
                .open_run_folder => openRunFolder(capture.runPath()),
            };
            if (capture.takeHandoff(&state.incident_clipboard)) |handoff| {
                var clipboard: [incident_contract.max_handoff_bytes + 1]u8 = undefined;
                @memcpy(clipboard[0..handoff.len], handoff);
                clipboard[handoff.len] = 0;
                if (!c.SDL_SetClipboardText(clipboard[0..handoff.len :0].ptr)) {
                    std.debug.print("Incident clipboard publication failed: {s}\n", .{c.SDL_GetError()});
                } else {
                    state.incident_clipboard_publications +|= 1;
                }
            }
        }
        state.incident_requests.clear();
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
        if (state.physics_debug_overlay) |*overlay| if (overlay.needsFrameFence()) {
            const fence = gpu_renderer.acquirePostSubmissionFence() catch failed: {
                overlay.noteFrameFenceFailed();
                break :failed null;
            };
            if (fence) |value| _ = overlay.noteFrameSubmitted(value);
        };
        if (state.incident_screenshots) |*screenshots| {
            screenshots.afterSubmission(gpu_renderer);
        }
        if (state.incident_semantic) |*semantic| {
            if (state.incident) |capture| {
                semantic.afterSubmission(gpu_renderer, capture);
            }
        }
    }

    /// Enqueue a final-swapchain download after all product and ImGui passes.
    pub fn prepareIncidentFrame(
        self: *Owner,
        gpu_renderer: *renderer.Renderer,
        authority_tick: u64,
        presentation_frame: u64,
    ) void {
        const state = ownerState(self);
        const capture = state.incident orelse return;
        const screenshots = if (state.incident_screenshots) |*value| value else return;
        screenshots.prepareHuman(
            gpu_renderer,
            capture,
            capture.nowNs(),
            authority_tick,
            presentation_frame,
        );
    }

    /// Enqueue the product-only trailing lane after the scene pass and before
    /// developer UI changes the drawable.
    pub fn prepareIncidentProductFrame(
        self: *Owner,
        gpu_renderer: *renderer.Renderer,
        authority_tick: u64,
        presentation_frame: u64,
    ) void {
        const state = ownerState(self);
        const capture = state.incident orelse return;
        const screenshots = if (state.incident_screenshots) |*value| value else return;
        screenshots.prepareProduct(
            gpu_renderer,
            capture,
            capture.nowNs(),
            authority_tick,
            presentation_frame,
        );
    }

    /// Encode one semantic-ID pass only when a flag is awaiting evidence.
    pub fn prepareIncidentSemanticFrame(
        self: *Owner,
        gpu_renderer: *renderer.Renderer,
        authority_tick: u64,
        presentation_frame: u64,
        draws: []const IncidentSemanticDraw,
    ) void {
        const state = ownerState(self);
        const capture = state.incident orelse return;
        const semantic = if (state.incident_semantic) |*value| value else return;
        semantic.prepare(
            gpu_renderer,
            capture,
            capture.nowNs(),
            authority_tick,
            presentation_frame,
            draws,
        );
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

test "incident hotkey remains distinct from existing developer and reconnect controls" {
    for ([_]c.SDL_Scancode{
        c.SDL_SCANCODE_F1,
        c.SDL_SCANCODE_F2,
        c.SDL_SCANCODE_F3,
        c.SDL_SCANCODE_F8,
    }) |reserved| try std.testing.expect(incident_hotkey_scancode != reserved);
}

test "incident hotkey recognizes physical virtual and macOS fallback routes" {
    var event = std.mem.zeroes(c.SDL_Event);
    event.type = c.SDL_EVENT_KEY_DOWN;
    event.key.scancode = incident_hotkey_scancode;
    try std.testing.expect(isIncidentHotkey(&event));

    event.key.scancode = c.SDL_SCANCODE_UNKNOWN;
    event.key.key = incident_hotkey_keycode;
    try std.testing.expect(isIncidentHotkey(&event));

    event.key.key = incident_hotkey_fallback_keycode;
    event.key.mod = c.SDL_KMOD_GUI | c.SDL_KMOD_SHIFT;
    try std.testing.expect(isIncidentHotkey(&event));

    event.key.key = 0;
    event.key.scancode = c.SDL_SCANCODE_9;
    try std.testing.expect(isIncidentHotkey(&event));

    event.key.scancode = c.SDL_SCANCODE_UNKNOWN;
    event.key.mod = c.SDL_KMOD_GUI;
    try std.testing.expect(!isIncidentHotkey(&event));

    event.key.key = incident_hotkey_recommended_keycode;
    event.key.mod = c.SDL_KMOD_GUI | c.SDL_KMOD_ALT;
    try std.testing.expect(isIncidentHotkey(&event));
    event.type = c.SDL_EVENT_KEY_UP;
    try std.testing.expect(!isIncidentHotkey(&event));
}

test "incident shortcut candidate preserves focus and admission facts" {
    var event = std.mem.zeroes(c.SDL_Event);
    event.type = c.SDL_EVENT_KEY_DOWN;
    event.key.timestamp = 1234;
    event.key.windowID = 77;
    event.key.scancode = c.SDL_SCANCODE_I;
    event.key.key = incident_hotkey_recommended_keycode;
    event.key.mod = c.SDL_KMOD_GUI | c.SDL_KMOD_ALT;
    event.key.raw = 12;
    const focused = shortcutCandidate(77, &event);
    try std.testing.expect(focused.focused);
    try std.testing.expectEqual(@as(u64, 1234), focused.event_monotonic_ns);
    try std.testing.expectEqual(@as(u32, 77), focused.window_id);
    try std.testing.expect(shouldQueueIncident(&event, focused, true));
    try std.testing.expect(!shouldQueueIncident(&event, focused, false));

    const unfocused = shortcutCandidate(78, &event);
    try std.testing.expect(!unfocused.focused);
    try std.testing.expect(!shouldQueueIncident(&event, unfocused, true));
    event.key.repeat = true;
    try std.testing.expect(!shouldQueueIncident(&event, focused, true));
    event.key.repeat = false;
    event.type = c.SDL_EVENT_KEY_UP;
    try std.testing.expect(!shouldQueueIncident(&event, focused, true));
}

test "incident shortcut queue saturation is bounded" {
    var queue = PendingShortcutQueue{};
    const candidate = incident_contract.ShortcutCandidate{};
    for (0..PendingShortcutQueue.capacity) |_| try std.testing.expect(queue.push(candidate));
    try std.testing.expect(!queue.push(candidate));
    for (0..PendingShortcutQueue.capacity) |_| try std.testing.expect(queue.pop() != null);
    try std.testing.expect(queue.pop() == null);
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
