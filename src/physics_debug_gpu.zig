//! Persistent SDL3 GPU presentation for bounded physics debug geometry.
//!
//! This owner is renderer-thread state. It creates a fixed ring of GPU and
//! transfer-buffer slots once, polls fences without waiting, and applies
//! visible backpressure when the GPU has not released a slot. Upload failures
//! disable only debug evidence; they are returned as typed status and never
//! become simulation-authority errors.

const std = @import("std");
const engine_contracts = @import("engine_contracts");
const sdl = @import("sdl.zig");
const renderer_module = @import("renderer.zig");
const mesh = @import("mesh.zig");
const zm = @import("zmath");

const c = sdl.c;
const PhysicsDebug = engine_contracts.physics_debug;
const Renderer = renderer_module.Renderer;
const Vertex = mesh.Vertex;

pub const Config = struct {
    line_capacity: u32 = 32_768,
    triangle_capacity: u32 = 16_384,
    slot_count: u8 = default_slot_count,
    initially_enabled: bool = true,
};

pub const default_slot_count: u8 = 3;
pub const max_slot_count: u8 = 8;

pub const InitError = error{
    EmptyLineCapacity,
    EmptyTriangleCapacity,
    EmptySlotCount,
    TooManySlots,
    LineCapacityTooLarge,
    TriangleCapacityTooLarge,
    DebugPipelinesUnavailable,
    LineBufferCreationFailed,
    TriangleBufferCreationFailed,
    LineTransferCreationFailed,
    TriangleTransferCreationFailed,
};

pub const ResourcePlan = struct {
    slot_count: u8,
    line_vertex_capacity: u32,
    triangle_vertex_capacity: u32,
    line_bytes: u32,
    triangle_bytes: u32,

    pub fn gpuBytes(self: ResourcePlan) u64 {
        return self.gpuBytesPerSlot() * self.slot_count;
    }

    pub fn transferBytes(self: ResourcePlan) u64 {
        return self.gpuBytes();
    }

    pub fn gpuBytesPerSlot(self: ResourcePlan) u64 {
        return @as(u64, self.line_bytes) + self.triangle_bytes;
    }
};

/// Validate all backend size narrowing before creating the first GPU owner.
pub fn planResources(config: Config) InitError!ResourcePlan {
    if (config.line_capacity == 0) return error.EmptyLineCapacity;
    if (config.triangle_capacity == 0) return error.EmptyTriangleCapacity;
    if (config.slot_count == 0) return error.EmptySlotCount;
    if (config.slot_count > max_slot_count) return error.TooManySlots;

    const line_vertices = std.math.mul(u32, config.line_capacity, 2) catch
        return error.LineCapacityTooLarge;
    const line_bytes = std.math.mul(u32, line_vertices, @sizeOf(Vertex)) catch
        return error.LineCapacityTooLarge;
    const triangle_vertices = std.math.mul(u32, config.triangle_capacity, 3) catch
        return error.TriangleCapacityTooLarge;
    const triangle_bytes = std.math.mul(u32, triangle_vertices, @sizeOf(Vertex)) catch
        return error.TriangleCapacityTooLarge;

    return .{
        .slot_count = config.slot_count,
        .line_vertex_capacity = line_vertices,
        .triangle_vertex_capacity = triangle_vertices,
        .line_bytes = line_bytes,
        .triangle_bytes = triangle_bytes,
    };
}

pub const UploadPlan = struct {
    source_lines: usize = 0,
    source_triangles: usize = 0,
    admitted_lines: u32 = 0,
    admitted_triangles: u32 = 0,
    dropped_lines: usize = 0,
    dropped_triangles: usize = 0,
    line_vertices: u32 = 0,
    triangle_vertices: u32 = 0,
    line_bytes: u32 = 0,
    triangle_bytes: u32 = 0,

    pub fn totalBytes(self: UploadPlan) u64 {
        return @as(u64, self.line_bytes) + self.triangle_bytes;
    }

    pub fn empty(self: UploadPlan) bool {
        return self.line_vertices == 0 and self.triangle_vertices == 0;
    }
};

/// Pure capacity planning shared by the live upload and headless tests.
pub fn planUpload(config: Config, source_lines: usize, source_triangles: usize) UploadPlan {
    // Remain total even when called with a Config that `planResources` would
    // reject. A live Overlay can only contain a validated Config.
    const max_vertices = std.math.maxInt(u32) / @as(u32, @sizeOf(Vertex));
    const safe_line_capacity = @min(config.line_capacity, max_vertices / 2);
    const safe_triangle_capacity = @min(config.triangle_capacity, max_vertices / 3);
    const line_capacity: usize = safe_line_capacity;
    const triangle_capacity: usize = safe_triangle_capacity;
    const line_count = @min(source_lines, line_capacity);
    const triangle_count = @min(source_triangles, triangle_capacity);
    const line_vertices: u32 = @intCast(line_count * 2);
    const triangle_vertices: u32 = @intCast(triangle_count * 3);

    return .{
        .source_lines = source_lines,
        .source_triangles = source_triangles,
        .admitted_lines = @intCast(line_count),
        .admitted_triangles = @intCast(triangle_count),
        .dropped_lines = source_lines - line_count,
        .dropped_triangles = source_triangles - triangle_count,
        .line_vertices = line_vertices,
        .triangle_vertices = triangle_vertices,
        .line_bytes = line_vertices * @sizeOf(Vertex),
        .triangle_bytes = triangle_vertices * @sizeOf(Vertex),
    };
}

pub const Mode = enum {
    enabled,
    disabled,
    failed,
    deinitialized,
};

pub const EnableResult = enum {
    enabled,
    disabled,
    unchanged,
    deinitialized,
};

/// Pure lifecycle seam. Disabling or failing clears the uploaded generation so
/// stale geometry can never become drawable after a later batch is observed.
pub const Lifecycle = struct {
    mode: Mode,
    uploaded_generation: u64 = 0,
    line_vertices: u32 = 0,
    triangle_vertices: u32 = 0,

    pub fn init(enabled: bool) Lifecycle {
        return .{ .mode = if (enabled) .enabled else .disabled };
    }

    pub fn setEnabled(self: *Lifecycle, enabled: bool) EnableResult {
        if (self.mode == .deinitialized) return .deinitialized;
        const wanted: Mode = if (enabled) .enabled else .disabled;
        if (self.mode == wanted) return .unchanged;
        self.mode = wanted;
        self.clearUpload();
        return if (enabled) .enabled else .disabled;
    }

    pub fn uploadSucceeded(
        self: *Lifecycle,
        generation: u64,
        line_vertices: u32,
        triangle_vertices: u32,
    ) void {
        if (self.mode != .enabled or generation == 0) return;
        self.uploaded_generation = generation;
        self.line_vertices = line_vertices;
        self.triangle_vertices = triangle_vertices;
    }

    pub fn uploadFailed(self: *Lifecycle) void {
        if (self.mode == .deinitialized) return;
        self.mode = .failed;
        self.clearUpload();
    }

    pub fn deinitialize(self: *Lifecycle) void {
        self.mode = .deinitialized;
        self.clearUpload();
    }

    pub fn hasUploadedGeneration(self: Lifecycle, generation: u64) bool {
        return self.mode == .enabled and
            generation != 0 and
            self.uploaded_generation == generation;
    }

    pub fn canDraw(self: Lifecycle, generation: u64) bool {
        return self.hasUploadedGeneration(generation) and
            (self.line_vertices != 0 or self.triangle_vertices != 0);
    }

    fn clearUpload(self: *Lifecycle) void {
        self.uploaded_generation = 0;
        self.line_vertices = 0;
        self.triangle_vertices = 0;
    }
};

pub const SlotStage = enum {
    unused,
    free,
    reserved,
    copy_pending,
    ready,
    retired,
};

pub const SlotState = struct {
    stage: SlotStage = .unused,
    submission_sequence: u64 = 0,
    generation: u64 = 0,
    completed_tick: u64 = 0,
    line_vertices: u32 = 0,
    triangle_vertices: u32 = 0,
    admitted_lines: u32 = 0,
    admitted_triangles: u32 = 0,
    upload_bytes: u64 = 0,
    frame_in_flight: bool = false,
};

pub const SlotCounts = struct {
    free: u8 = 0,
    reserved: u8 = 0,
    copy_pending: u8 = 0,
    ready: u8 = 0,
    retired: u8 = 0,

    pub fn busy(self: SlotCounts) u8 {
        return self.reserved + self.copy_pending + self.ready + self.retired;
    }
};

/// Pure ownership planner shared by the live SDL owner and lifecycle tests.
/// A ready active slot may be read by multiple frames. It is never reused for
/// a copy until a newer generation supersedes it and its latest frame fence
/// signals. One later same-queue frame fence safely supersedes an earlier one.
pub const SlotRing = struct {
    slot_count: u8,
    slots: [max_slot_count]SlotState = [_]SlotState{.{}} ** max_slot_count,
    active_slot: ?u8 = null,
    drawn_slot: ?u8 = null,
    active_sequence: u64 = 0,
    next_sequence: u64 = 0,

    pub fn init(slot_count: u8) SlotRing {
        std.debug.assert(slot_count > 0 and slot_count <= max_slot_count);
        var result = SlotRing{ .slot_count = slot_count };
        for (result.slots[0..slot_count]) |*slot| slot.stage = .free;
        return result;
    }

    pub fn reserve(self: *SlotRing) ?u8 {
        self.reclaimStale();
        for (self.slots[0..self.slot_count], 0..) |*slot, index| {
            if (slot.stage != .free) continue;
            slot.stage = .reserved;
            return @intCast(index);
        }
        return null;
    }

    pub fn releaseReservation(self: *SlotRing, slot_index: u8) void {
        const slot = &self.slots[slot_index];
        std.debug.assert(slot.stage == .reserved);
        slot.* = .{ .stage = .free };
    }

    pub fn copySubmitted(
        self: *SlotRing,
        slot_index: u8,
        generation: u64,
        completed_tick: u64,
        plan: UploadPlan,
    ) u64 {
        const slot = &self.slots[slot_index];
        std.debug.assert(slot.stage == .reserved);
        const sequence = nextNonZero(&self.next_sequence);
        slot.* = .{
            .stage = .copy_pending,
            .submission_sequence = sequence,
            .generation = generation,
            .completed_tick = completed_tick,
            .line_vertices = plan.line_vertices,
            .triangle_vertices = plan.triangle_vertices,
            .admitted_lines = plan.admitted_lines,
            .admitted_triangles = plan.admitted_triangles,
            .upload_bytes = plan.totalBytes(),
        };
        return sequence;
    }

    /// Returns true when this completion became the exact drawable generation.
    pub fn copyCompleted(self: *SlotRing, slot_index: u8) bool {
        const slot = &self.slots[slot_index];
        std.debug.assert(slot.stage == .copy_pending);
        slot.stage = .ready;
        const previous_active = self.active_slot;
        self.promoteNewestReady();
        return self.active_slot != previous_active and self.active_slot == slot_index;
    }

    pub fn supersedeWithEmpty(self: *SlotRing) u64 {
        self.active_slot = null;
        self.active_sequence = nextNonZero(&self.next_sequence);
        self.reclaimStale();
        return self.active_sequence;
    }

    pub fn clearActive(self: *SlotRing) void {
        self.active_slot = null;
        self.active_sequence = nextNonZero(&self.next_sequence);
        self.reclaimStale();
    }

    pub fn markDrawn(self: *SlotRing) bool {
        const active = self.active_slot orelse return false;
        if (self.slots[active].stage != .ready) return false;
        if (self.drawn_slot) |drawn| return drawn == active;
        self.drawn_slot = active;
        return true;
    }

    pub fn needsFrameFence(self: SlotRing) bool {
        return self.drawn_slot != null;
    }

    /// Records ownership of a fence for the frame that read `drawn_slot`.
    /// The caller may replace an older fence for that slot because submissions
    /// to the same SDL GPU queue are ordered and the newer fence subsumes it.
    pub fn frameSubmitted(self: *SlotRing) ?u8 {
        const drawn = self.drawn_slot orelse return null;
        self.slots[drawn].frame_in_flight = true;
        self.drawn_slot = null;
        return drawn;
    }

    pub fn frameCompleted(self: *SlotRing, slot_index: u8) void {
        self.slots[slot_index].frame_in_flight = false;
        self.reclaimStale();
    }

    /// A submission whose completion cannot be fenced permanently retires the
    /// affected slot. Fixed capacity therefore degrades visibly, never by
    /// unsafely overwriting a buffer that the GPU may still read or write.
    pub fn retire(self: *SlotRing, slot_index: u8) void {
        const was_active = self.active_slot != null and self.active_slot.? == slot_index;
        const was_drawn = self.drawn_slot != null and self.drawn_slot.? == slot_index;
        self.slots[slot_index].stage = .retired;
        self.slots[slot_index].frame_in_flight = false;
        if (was_active) {
            self.active_slot = null;
            self.active_sequence = nextNonZero(&self.next_sequence);
        }
        if (was_drawn) self.drawn_slot = null;
        self.reclaimStale();
    }

    pub fn counts(self: SlotRing) SlotCounts {
        var result = SlotCounts{};
        for (self.slots[0..self.slot_count]) |slot| switch (slot.stage) {
            .unused => unreachable,
            .free => result.free += 1,
            .reserved => result.reserved += 1,
            .copy_pending => result.copy_pending += 1,
            .ready => result.ready += 1,
            .retired => result.retired += 1,
        };
        return result;
    }

    pub fn containsPendingOrActiveGeneration(
        self: SlotRing,
        generation: u64,
    ) bool {
        if (generation == 0) return false;
        if (self.active_slot) |active| {
            if (self.slots[active].generation == generation) return true;
        }
        for (self.slots[0..self.slot_count]) |slot| {
            // `clearActive` advances active_sequence as an epoch barrier.
            // Pending work from an older disabled/failed epoch may complete
            // and be reclaimed, but must not suppress an explicit retry of
            // the same CPU generation.
            if (slot.stage == .copy_pending and
                slot.submission_sequence > self.active_sequence and
                slot.generation == generation)
            {
                return true;
            }
        }
        return false;
    }

    fn promoteNewestReady(self: *SlotRing) void {
        var newest_slot: ?u8 = null;
        var newest_sequence = self.active_sequence;
        for (self.slots[0..self.slot_count], 0..) |slot, index| {
            if (slot.stage == .ready and slot.submission_sequence > newest_sequence) {
                newest_sequence = slot.submission_sequence;
                newest_slot = @intCast(index);
            }
        }
        if (newest_slot) |slot_index| {
            self.active_slot = slot_index;
            self.active_sequence = newest_sequence;
        }
        self.reclaimStale();
    }

    fn reclaimStale(self: *SlotRing) void {
        for (self.slots[0..self.slot_count], 0..) |*slot, index| {
            if (slot.stage != .ready or slot.frame_in_flight) continue;
            if (self.active_slot != null and self.active_slot.? == index) continue;
            if (self.drawn_slot != null and self.drawn_slot.? == index) continue;
            slot.* = .{ .stage = .free };
        }
    }
};

pub const UploadStatus = enum {
    not_attempted,
    copy_submitted,
    empty,
    duplicate_generation,
    backpressure_dropped,
    disabled,
    failure_disabled,
    deinitialized,
    invalid_schema,
    invalid_generation,
    invalid_primitive,
    line_map_failed,
    triangle_map_failed,
    command_acquire_failed,
    copy_pass_begin_failed,
    command_cancel_failed,
    copy_fence_acquire_failed,

    pub fn isFailure(self: UploadStatus) bool {
        return switch (self) {
            .invalid_schema,
            .invalid_generation,
            .invalid_primitive,
            .line_map_failed,
            .triangle_map_failed,
            .command_acquire_failed,
            .copy_pass_begin_failed,
            .command_cancel_failed,
            .copy_fence_acquire_failed,
            => true,
            else => false,
        };
    }
};

pub const UploadResult = struct {
    status: UploadStatus,
    generation: u64,
    plan: UploadPlan,
};

pub const DrawStatus = enum {
    drawn,
    empty,
    generation_not_uploaded,
    frame_fence_required,
    disabled,
    failure_disabled,
    deinitialized,
};

pub const DrawResult = struct {
    status: DrawStatus,
    /// Exact retained GPU generation selected for this call, or zero when no
    /// completed generation exists. This deliberately need not equal the CPU
    /// storage's newest generation while a copy fence remains pending.
    generation: u64,
};

pub const ResourceStats = struct {
    gpu_buffer_count: u8 = 0,
    transfer_buffer_count: u8 = 0,
    gpu_bytes: u64 = 0,
    transfer_bytes: u64 = 0,
    slot_count: u8 = 0,
    max_owned_fences: u8 = 0,
    live_owned_fences: u8 = 0,
    peak_owned_fences: u8 = 0,
    free_slots: u8 = 0,
    busy_slots: u8 = 0,
    copy_pending_slots: u8 = 0,
    retired_slots: u8 = 0,
};

pub const Stats = struct {
    mode: Mode,
    resources: ResourceStats,
    /// Outcome and capacity plan for the newest attempted CPU batch. These may
    /// be newer than the retained generation while its copy remains pending.
    last_upload_status: UploadStatus = .not_attempted,
    last_plan: UploadPlan = .{},
    latest_attempted_generation: u64 = 0,
    /// Exact completed generation currently selected for `drawLatest`.
    latest_uploaded_generation: u64 = 0,
    latest_completed_tick: u64 = 0,
    retained_line_vertices: u32 = 0,
    retained_triangle_vertices: u32 = 0,
    retained_upload_bytes: u64 = 0,
    upload_attempts: u64 = 0,
    copy_submissions: u64 = 0,
    copy_completions: u64 = 0,
    /// Completed fenced copies plus immediately completed empty generations.
    successful_uploads: u64 = 0,
    empty_uploads: u64 = 0,
    failed_uploads: u64 = 0,
    skipped_uploads: u64 = 0,
    backpressure_drops: u64 = 0,
    uploaded_lines: u64 = 0,
    uploaded_triangles: u64 = 0,
    uploaded_vertices: u64 = 0,
    last_upload_bytes: u64 = 0,
    total_upload_bytes: u64 = 0,
    capacity_dropped_lines: u64 = 0,
    capacity_dropped_triangles: u64 = 0,
    failure_dropped_lines: u64 = 0,
    failure_dropped_triangles: u64 = 0,
    skipped_lines: u64 = 0,
    skipped_triangles: u64 = 0,
    backpressure_dropped_lines: u64 = 0,
    backpressure_dropped_triangles: u64 = 0,
    fence_queries: u64 = 0,
    fence_acquisitions: u64 = 0,
    fence_releases: u64 = 0,
    frame_fences_accepted: u64 = 0,
    frame_fences_superseded: u64 = 0,
    unexpected_frame_fences_released: u64 = 0,
    frame_fence_failures: u64 = 0,
    slot_retirements: u64 = 0,
    draw_calls: u64 = 0,
    line_draw_calls: u64 = 0,
    triangle_draw_calls: u64 = 0,
    drawn_line_vertices: u64 = 0,
    drawn_triangle_vertices: u64 = 0,
    skipped_draws: u64 = 0,
};

pub const PollResult = struct {
    completed_copies: u8 = 0,
    completed_frames: u8 = 0,
    promoted_generation: u64 = 0,
};

pub const FrameFenceResult = enum {
    accepted,
    not_needed_released,
    deinitialized_released,
};

const SlotResources = struct {
    line_buffer: ?*c.SDL_GPUBuffer = null,
    triangle_buffer: ?*c.SDL_GPUBuffer = null,
    line_transfer: ?*c.SDL_GPUTransferBuffer = null,
    triangle_transfer: ?*c.SDL_GPUTransferBuffer = null,
    copy_fence: ?*c.SDL_GPUFence = null,
    frame_fence: ?*renderer_module.SubmissionFence = null,

    fn releaseResources(self: *SlotResources, device: *c.SDL_GPUDevice) void {
        if (self.triangle_transfer) |transfer| {
            c.SDL_ReleaseGPUTransferBuffer(device, transfer);
            self.triangle_transfer = null;
        }
        if (self.line_transfer) |transfer| {
            c.SDL_ReleaseGPUTransferBuffer(device, transfer);
            self.line_transfer = null;
        }
        if (self.triangle_buffer) |buffer| {
            c.SDL_ReleaseGPUBuffer(device, buffer);
            self.triangle_buffer = null;
        }
        if (self.line_buffer) |buffer| {
            c.SDL_ReleaseGPUBuffer(device, buffer);
            self.line_buffer = null;
        }
    }
};

/// Persistent fixed-capacity GPU owner. Deinitialize it before the Renderer
/// that supplied its device. Repeated `deinit` calls are harmless. The owner
/// never waits; it polls and releases at most one owned fence per slot.
pub const Overlay = struct {
    device: *c.SDL_GPUDevice,
    config: Config,
    resource_plan: ResourcePlan,
    slots: [max_slot_count]SlotResources,
    ring: SlotRing,
    lifecycle: Lifecycle,
    metrics: Stats,

    pub fn init(renderer: *Renderer, config: Config) InitError!Overlay {
        const resource_plan = try planResources(config);
        if (!renderer.physicsDebugPipelinesAvailable()) {
            return error.DebugPipelinesUnavailable;
        }
        const device = renderer.getDevice();
        var slots = [_]SlotResources{.{}} ** max_slot_count;
        errdefer for (slots[0..config.slot_count]) |*slot| slot.releaseResources(device);

        for (slots[0..config.slot_count]) |*slot| {
            slot.line_buffer = c.SDL_CreateGPUBuffer(device, &.{
                .usage = c.SDL_GPU_BUFFERUSAGE_VERTEX,
                .size = resource_plan.line_bytes,
                .props = 0,
            }) orelse return error.LineBufferCreationFailed;
            slot.triangle_buffer = c.SDL_CreateGPUBuffer(device, &.{
                .usage = c.SDL_GPU_BUFFERUSAGE_VERTEX,
                .size = resource_plan.triangle_bytes,
                .props = 0,
            }) orelse return error.TriangleBufferCreationFailed;
            slot.line_transfer = c.SDL_CreateGPUTransferBuffer(device, &.{
                .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
                .size = resource_plan.line_bytes,
                .props = 0,
            }) orelse return error.LineTransferCreationFailed;
            slot.triangle_transfer = c.SDL_CreateGPUTransferBuffer(device, &.{
                .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
                .size = resource_plan.triangle_bytes,
                .props = 0,
            }) orelse return error.TriangleTransferCreationFailed;
        }

        const lifecycle = Lifecycle.init(config.initially_enabled);
        const buffer_count: u8 = config.slot_count * 2;
        return .{
            .device = device,
            .config = config,
            .resource_plan = resource_plan,
            .slots = slots,
            .ring = SlotRing.init(config.slot_count),
            .lifecycle = lifecycle,
            .metrics = .{
                .mode = lifecycle.mode,
                .resources = .{
                    .gpu_buffer_count = buffer_count,
                    .transfer_buffer_count = buffer_count,
                    .gpu_bytes = resource_plan.gpuBytes(),
                    .transfer_bytes = resource_plan.transferBytes(),
                    .slot_count = config.slot_count,
                    .max_owned_fences = config.slot_count,
                    .free_slots = config.slot_count,
                },
                .last_upload_status = if (config.initially_enabled) .not_attempted else .disabled,
            },
        };
    }

    pub fn deinit(self: *Overlay) void {
        if (self.lifecycle.mode == .deinitialized) return;
        for (self.slots[0..self.config.slot_count]) |*slot| {
            if (slot.copy_fence) |fence| {
                self.releaseOwnedFence(fence);
                slot.copy_fence = null;
            }
            if (slot.frame_fence) |fence| {
                self.releaseOwnedFrameFence(fence);
                slot.frame_fence = null;
            }
            slot.releaseResources(self.device);
        }
        self.lifecycle.deinitialize();
        self.metrics.mode = .deinitialized;
        self.metrics.resources = .{};
        self.metrics.latest_uploaded_generation = 0;
    }

    pub fn setEnabled(self: *Overlay, enabled: bool) EnableResult {
        const result = self.lifecycle.setEnabled(enabled);
        if (result == .disabled or result == .enabled) self.ring.clearActive();
        if (result == .enabled) resetAttemptCursor(&self.metrics);
        self.metrics.mode = self.lifecycle.mode;
        self.metrics.latest_uploaded_generation = self.lifecycle.uploaded_generation;
        self.refreshResourceStats();
        return result;
    }

    /// Poll copy and frame fences without waiting. A signaled copy may promote
    /// its exact generation; a signaled frame fence may make a superseded slot
    /// reusable. This function performs no allocation or resource creation.
    pub fn poll(self: *Overlay) PollResult {
        if (self.lifecycle.mode == .deinitialized) return .{};
        var result = PollResult{};

        for (self.slots[0..self.config.slot_count], 0..) |*slot, index| {
            const slot_index: u8 = @intCast(index);
            if (slot.copy_fence) |fence| {
                saturatingIncrement(&self.metrics.fence_queries);
                if (sdl.gpuFenceSignaled(self.device, fence)) {
                    const completed = self.ring.slots[index];
                    self.releaseOwnedFence(fence);
                    slot.copy_fence = null;
                    const promoted = self.ring.copyCompleted(slot_index);
                    saturatingIncrement(&self.metrics.copy_completions);
                    saturatingIncrement(&self.metrics.successful_uploads);
                    saturatingAdd(&self.metrics.uploaded_lines, completed.admitted_lines);
                    saturatingAdd(&self.metrics.uploaded_triangles, completed.admitted_triangles);
                    saturatingAdd(
                        &self.metrics.uploaded_vertices,
                        @as(u64, completed.line_vertices) + completed.triangle_vertices,
                    );
                    saturatingAdd(&self.metrics.total_upload_bytes, completed.upload_bytes);
                    result.completed_copies += 1;

                    if (self.lifecycle.mode == .enabled and promoted) {
                        self.lifecycle.uploadSucceeded(
                            completed.generation,
                            completed.line_vertices,
                            completed.triangle_vertices,
                        );
                        self.metrics.latest_completed_tick = completed.completed_tick;
                        result.promoted_generation = completed.generation;
                    } else if (self.lifecycle.mode != .enabled) {
                        self.ring.clearActive();
                    }
                }
            }
            if (slot.frame_fence) |fence| {
                saturatingIncrement(&self.metrics.fence_queries);
                if (fence.signaled()) {
                    self.releaseOwnedFrameFence(fence);
                    slot.frame_fence = null;
                    self.ring.frameCompleted(slot_index);
                    result.completed_frames += 1;
                }
            }
        }
        self.metrics.mode = self.lifecycle.mode;
        self.metrics.latest_uploaded_generation = self.lifecycle.uploaded_generation;
        self.refreshResourceStats();
        return result;
    }

    /// Convert and submit one bounded batch into a reusable slot. The copy uses
    /// `cycle=false` and acquires a fence. When every slot is busy, this returns
    /// visible backpressure and retains the prior exact drawable generation.
    pub fn upload(self: *Overlay, batch: PhysicsDebug.Batch) UploadResult {
        _ = self.poll();
        const plan = planUpload(self.config, batch.lines.len, batch.triangles.len);
        self.metrics.last_plan = plan;
        self.metrics.latest_attempted_generation = batch.generation;
        saturatingIncrement(&self.metrics.upload_attempts);

        switch (self.lifecycle.mode) {
            .deinitialized => return self.skipUpload(.deinitialized, batch.generation, plan),
            .disabled => return self.skipUpload(.disabled, batch.generation, plan),
            .failed => return self.skipUpload(.failure_disabled, batch.generation, plan),
            .enabled => {},
        }

        saturatingAdd(&self.metrics.capacity_dropped_lines, usizeToU64(plan.dropped_lines));
        saturatingAdd(&self.metrics.capacity_dropped_triangles, usizeToU64(plan.dropped_triangles));
        if (batch.schema != PhysicsDebug.schema_version) {
            return self.failUpload(.invalid_schema, batch.generation, plan);
        }
        if (batch.generation == 0) {
            return self.failUpload(.invalid_generation, batch.generation, plan);
        }
        for (batch.lines[0..plan.admitted_lines]) |line| {
            if (!line.isValid()) return self.failUpload(.invalid_primitive, batch.generation, plan);
        }
        for (batch.triangles[0..plan.admitted_triangles]) |triangle| {
            if (!triangle.isValid()) return self.failUpload(.invalid_primitive, batch.generation, plan);
        }
        if (self.lifecycle.hasUploadedGeneration(batch.generation) or
            self.ring.containsPendingOrActiveGeneration(batch.generation))
        {
            return self.skipUpload(.duplicate_generation, batch.generation, plan);
        }

        if (plan.empty()) {
            _ = self.ring.supersedeWithEmpty();
            self.lifecycle.uploadSucceeded(batch.generation, 0, 0);
            self.recordEmpty(batch, plan);
            return .{ .status = .empty, .generation = batch.generation, .plan = plan };
        }

        const slot_index = self.ring.reserve() orelse
            return self.dropForBackpressure(batch.generation, plan);
        const slot = &self.slots[slot_index];

        if (plan.line_vertices != 0) {
            const transfer = slot.line_transfer orelse {
                self.ring.releaseReservation(slot_index);
                return self.failUpload(.line_map_failed, batch.generation, plan);
            };
            const mapped_raw = c.SDL_MapGPUTransferBuffer(self.device, transfer, false) orelse {
                self.ring.releaseReservation(slot_index);
                return self.failUpload(.line_map_failed, batch.generation, plan);
            };
            const mapped: [*]Vertex = @ptrCast(@alignCast(mapped_raw));
            var vertex_index: usize = 0;
            for (batch.lines[0..plan.admitted_lines]) |line| {
                const rgb = opaqueRgbFrom(line.color);
                mapped[vertex_index] = .{ .position = line.start, .color = rgb };
                mapped[vertex_index + 1] = .{ .position = line.end, .color = rgb };
                vertex_index += 2;
            }
            c.SDL_UnmapGPUTransferBuffer(self.device, transfer);
        }

        if (plan.triangle_vertices != 0) {
            const transfer = slot.triangle_transfer orelse {
                self.ring.releaseReservation(slot_index);
                return self.failUpload(.triangle_map_failed, batch.generation, plan);
            };
            const mapped_raw = c.SDL_MapGPUTransferBuffer(self.device, transfer, false) orelse {
                self.ring.releaseReservation(slot_index);
                return self.failUpload(.triangle_map_failed, batch.generation, plan);
            };
            const mapped: [*]Vertex = @ptrCast(@alignCast(mapped_raw));
            var vertex_index: usize = 0;
            for (batch.triangles[0..plan.admitted_triangles]) |triangle| {
                const rgb = opaqueRgbFrom(triangle.color);
                mapped[vertex_index] = .{ .position = triangle.a, .color = rgb };
                mapped[vertex_index + 1] = .{ .position = triangle.b, .color = rgb };
                mapped[vertex_index + 2] = .{ .position = triangle.c, .color = rgb };
                vertex_index += 3;
            }
            c.SDL_UnmapGPUTransferBuffer(self.device, transfer);
        }

        const command = c.SDL_AcquireGPUCommandBuffer(self.device) orelse {
            self.ring.releaseReservation(slot_index);
            return self.failUpload(.command_acquire_failed, batch.generation, plan);
        };
        const copy_pass = c.SDL_BeginGPUCopyPass(command) orelse {
            if (c.SDL_CancelGPUCommandBuffer(command)) {
                self.ring.releaseReservation(slot_index);
                return self.failUpload(.copy_pass_begin_failed, batch.generation, plan);
            }
            self.retireSlot(slot_index);
            return self.failUpload(.command_cancel_failed, batch.generation, plan);
        };

        if (plan.line_vertices != 0) {
            c.SDL_UploadToGPUBuffer(copy_pass, &.{
                .transfer_buffer = slot.line_transfer.?,
                .offset = 0,
            }, &.{
                .buffer = slot.line_buffer.?,
                .offset = 0,
                .size = plan.line_bytes,
            }, false);
        }
        if (plan.triangle_vertices != 0) {
            c.SDL_UploadToGPUBuffer(copy_pass, &.{
                .transfer_buffer = slot.triangle_transfer.?,
                .offset = 0,
            }, &.{
                .buffer = slot.triangle_buffer.?,
                .offset = 0,
                .size = plan.triangle_bytes,
            }, false);
        }
        c.SDL_EndGPUCopyPass(copy_pass);

        // Submission consumes the command buffer even if fence acquisition
        // fails. Without a fence this slot is permanently retired.
        const fence = c.SDL_SubmitGPUCommandBufferAndAcquireFence(command) orelse {
            self.retireSlot(slot_index);
            return self.failUpload(.copy_fence_acquire_failed, batch.generation, plan);
        };
        _ = self.ring.copySubmitted(
            slot_index,
            batch.generation,
            batch.completed_tick,
            plan,
        );
        slot.copy_fence = fence;
        self.acquireOwnedFence();
        self.metrics.last_upload_status = .copy_submitted;
        self.metrics.last_upload_bytes = plan.totalBytes();
        saturatingIncrement(&self.metrics.copy_submissions);
        self.refreshResourceStats();
        return .{ .status = .copy_submitted, .generation = batch.generation, .plan = plan };
    }

    /// Draw only a caller-selected exact generation whose copy fence signaled.
    /// Prefer `drawLatest` for a live producer that publishes every tick.
    pub fn draw(
        self: *Overlay,
        renderer: *Renderer,
        expected_generation: u64,
        mvp: zm.Mat,
    ) DrawStatus {
        _ = self.poll();
        return self.drawGeneration(renderer, expected_generation, mvp);
    }

    /// Draw the latest retained completed generation. This avoids starvation
    /// when CPU batches advance every frame while their asynchronous copies
    /// complete one or more frames later. `generation` identifies exactly what
    /// was drawn and remains zero until the first copy completes.
    pub fn drawLatest(
        self: *Overlay,
        renderer: *Renderer,
        mvp: zm.Mat,
    ) DrawResult {
        _ = self.poll();
        const generation = self.lifecycle.uploaded_generation;
        return .{
            .status = self.drawGeneration(renderer, generation, mvp),
            .generation = generation,
        };
    }

    fn drawGeneration(
        self: *Overlay,
        renderer: *Renderer,
        expected_generation: u64,
        mvp: zm.Mat,
    ) DrawStatus {
        var status = self.drawStatus(expected_generation);
        if (status == .drawn and !self.ring.markDrawn()) status = .frame_fence_required;
        if (status != .drawn) {
            saturatingIncrement(&self.metrics.skipped_draws);
            return status;
        }

        const slot_index = self.ring.active_slot orelse unreachable;
        const slot = &self.slots[slot_index];
        saturatingIncrement(&self.metrics.draw_calls);
        // Opaque, depth-tested fills go first; coplanar diagnostic lines remain
        // visible because the line pass is later and neither pass writes depth.
        if (self.lifecycle.triangle_vertices != 0) {
            renderer.drawDebugTriangles(
                slot.triangle_buffer.?,
                self.lifecycle.triangle_vertices,
                mvp,
            );
            saturatingIncrement(&self.metrics.triangle_draw_calls);
            saturatingAdd(&self.metrics.drawn_triangle_vertices, self.lifecycle.triangle_vertices);
        }
        if (self.lifecycle.line_vertices != 0) {
            renderer.drawLines(slot.line_buffer.?, self.lifecycle.line_vertices, mvp);
            saturatingIncrement(&self.metrics.line_draw_calls);
            saturatingAdd(&self.metrics.drawn_line_vertices, self.lifecycle.line_vertices);
        }
        return .drawn;
    }

    /// True only after a successful debug draw in the currently recording
    /// renderer frame. After ordinary frame submission, the host must call
    /// exactly one of the two `noteFrame...` functions for its post-submit
    /// same-queue fence attempt.
    pub fn needsFrameFence(self: *const Overlay) bool {
        return self.ring.needsFrameFence();
    }

    /// Transfer ownership of a same-queue fence enqueued after the submitted
    /// renderer frame that read this slot.
    pub fn noteFrameSubmitted(
        self: *Overlay,
        fence: *renderer_module.SubmissionFence,
    ) FrameFenceResult {
        if (self.lifecycle.mode == .deinitialized) {
            fence.release();
            saturatingIncrement(&self.metrics.unexpected_frame_fences_released);
            return .deinitialized_released;
        }
        const slot_index = self.ring.drawn_slot orelse {
            fence.release();
            saturatingIncrement(&self.metrics.unexpected_frame_fences_released);
            return .not_needed_released;
        };
        const slot = &self.slots[slot_index];
        if (slot.frame_fence) |older| {
            self.releaseOwnedFrameFence(older);
            slot.frame_fence = null;
            saturatingIncrement(&self.metrics.frame_fences_superseded);
        }
        slot.frame_fence = fence;
        _ = self.ring.frameSubmitted();
        self.acquireOwnedFence();
        saturatingIncrement(&self.metrics.frame_fences_accepted);
        self.refreshResourceStats();
        return .accepted;
    }

    /// Conservatively retire the drawn slot when the frame submitted but its
    /// post-submit completion fence could not be acquired. This path never
    /// guesses that reuse is safe and never grows the resource set.
    pub fn noteFrameFenceFailed(self: *Overlay) void {
        const slot_index = self.ring.drawn_slot orelse return;
        const slot = &self.slots[slot_index];
        if (slot.frame_fence) |older| {
            self.releaseOwnedFrameFence(older);
            slot.frame_fence = null;
        }
        self.retireSlot(slot_index);
        self.lifecycle.uploadFailed();
        self.metrics.mode = self.lifecycle.mode;
        self.metrics.latest_uploaded_generation = 0;
        saturatingIncrement(&self.metrics.frame_fence_failures);
        self.refreshResourceStats();
    }

    pub fn stats(self: *const Overlay) Stats {
        var result = self.metrics;
        result.mode = self.lifecycle.mode;
        result.latest_uploaded_generation = self.lifecycle.uploaded_generation;
        result.retained_line_vertices = self.lifecycle.line_vertices;
        result.retained_triangle_vertices = self.lifecycle.triangle_vertices;
        result.retained_upload_bytes = if (self.ring.active_slot) |slot_index|
            self.ring.slots[slot_index].upload_bytes
        else
            0;
        const counts = self.ring.counts();
        result.resources.free_slots = counts.free;
        result.resources.busy_slots = counts.busy();
        result.resources.copy_pending_slots = counts.copy_pending;
        result.resources.retired_slots = counts.retired;
        return result;
    }

    fn drawStatus(self: *const Overlay, expected_generation: u64) DrawStatus {
        return switch (self.lifecycle.mode) {
            .deinitialized => .deinitialized,
            .disabled => .disabled,
            .failed => .failure_disabled,
            .enabled => if (!self.lifecycle.hasUploadedGeneration(expected_generation))
                .generation_not_uploaded
            else if (!self.lifecycle.canDraw(expected_generation))
                .empty
            else if (self.ring.active_slot == null)
                .generation_not_uploaded
            else if (self.ring.drawn_slot != null and
                self.ring.drawn_slot.? != self.ring.active_slot.?)
                .frame_fence_required
            else
                .drawn,
        };
    }

    fn skipUpload(
        self: *Overlay,
        status: UploadStatus,
        generation: u64,
        plan: UploadPlan,
    ) UploadResult {
        self.metrics.last_upload_status = status;
        self.metrics.last_upload_bytes = 0;
        saturatingIncrement(&self.metrics.skipped_uploads);
        saturatingAdd(&self.metrics.skipped_lines, usizeToU64(plan.source_lines));
        saturatingAdd(&self.metrics.skipped_triangles, usizeToU64(plan.source_triangles));
        return .{ .status = status, .generation = generation, .plan = plan };
    }

    fn dropForBackpressure(
        self: *Overlay,
        generation: u64,
        plan: UploadPlan,
    ) UploadResult {
        self.metrics.last_upload_status = .backpressure_dropped;
        self.metrics.last_upload_bytes = 0;
        saturatingIncrement(&self.metrics.skipped_uploads);
        saturatingIncrement(&self.metrics.backpressure_drops);
        saturatingAdd(&self.metrics.backpressure_dropped_lines, plan.admitted_lines);
        saturatingAdd(&self.metrics.backpressure_dropped_triangles, plan.admitted_triangles);
        self.refreshResourceStats();
        return .{ .status = .backpressure_dropped, .generation = generation, .plan = plan };
    }

    fn failUpload(
        self: *Overlay,
        status: UploadStatus,
        generation: u64,
        plan: UploadPlan,
    ) UploadResult {
        std.debug.assert(status.isFailure());
        self.lifecycle.uploadFailed();
        self.ring.clearActive();
        self.metrics.mode = self.lifecycle.mode;
        self.metrics.latest_uploaded_generation = 0;
        self.metrics.last_upload_status = status;
        self.metrics.last_upload_bytes = 0;
        saturatingIncrement(&self.metrics.failed_uploads);
        saturatingAdd(&self.metrics.failure_dropped_lines, plan.admitted_lines);
        saturatingAdd(&self.metrics.failure_dropped_triangles, plan.admitted_triangles);
        self.refreshResourceStats();
        return .{ .status = status, .generation = generation, .plan = plan };
    }

    fn recordEmpty(self: *Overlay, batch: PhysicsDebug.Batch, plan: UploadPlan) void {
        self.metrics.mode = self.lifecycle.mode;
        self.metrics.last_upload_status = .empty;
        self.metrics.latest_uploaded_generation = batch.generation;
        self.metrics.latest_completed_tick = batch.completed_tick;
        self.metrics.last_upload_bytes = 0;
        saturatingIncrement(&self.metrics.successful_uploads);
        saturatingIncrement(&self.metrics.empty_uploads);
        self.refreshResourceStats();
        _ = plan;
    }

    fn retireSlot(self: *Overlay, slot_index: u8) void {
        self.ring.retire(slot_index);
        saturatingIncrement(&self.metrics.slot_retirements);
    }

    fn acquireOwnedFence(self: *Overlay) void {
        saturatingIncrement(&self.metrics.fence_acquisitions);
        self.metrics.resources.live_owned_fences += 1;
        self.metrics.resources.peak_owned_fences = @max(
            self.metrics.resources.peak_owned_fences,
            self.metrics.resources.live_owned_fences,
        );
        std.debug.assert(
            self.metrics.resources.live_owned_fences <= self.config.slot_count,
        );
    }

    fn releaseOwnedFence(self: *Overlay, fence: *c.SDL_GPUFence) void {
        c.SDL_ReleaseGPUFence(self.device, fence);
        saturatingIncrement(&self.metrics.fence_releases);
        std.debug.assert(self.metrics.resources.live_owned_fences > 0);
        self.metrics.resources.live_owned_fences -= 1;
    }

    fn releaseOwnedFrameFence(
        self: *Overlay,
        fence: *renderer_module.SubmissionFence,
    ) void {
        fence.release();
        saturatingIncrement(&self.metrics.fence_releases);
        std.debug.assert(self.metrics.resources.live_owned_fences > 0);
        self.metrics.resources.live_owned_fences -= 1;
    }

    fn refreshResourceStats(self: *Overlay) void {
        const counts = self.ring.counts();
        self.metrics.resources.free_slots = counts.free;
        self.metrics.resources.busy_slots = counts.busy();
        self.metrics.resources.copy_pending_slots = counts.copy_pending;
        self.metrics.resources.retired_slots = counts.retired;
    }
};

/// The current debug pipelines are explicitly opaque RGB pipelines. Schema v1
/// has already validated lane four as the reserved `1.0`; this adapter selects
/// the three contract RGB lanes required by the renderer's vertex format.
fn opaqueRgbFrom(color: PhysicsDebug.Color) [3]f32 {
    return .{ color[0], color[1], color[2] };
}

fn nextNonZero(value: *u64) u64 {
    value.* +%= 1;
    if (value.* == 0) value.* = 1;
    return value.*;
}

/// A fresh enable is an explicit retry epoch. The host may be paused, so its
/// current CPU batch can legitimately have the same generation as the last
/// attempt made before disable/failure.
fn resetAttemptCursor(metrics: *Stats) void {
    metrics.latest_attempted_generation = 0;
    metrics.last_upload_status = .not_attempted;
    metrics.last_plan = .{};
    metrics.last_upload_bytes = 0;
}

fn usizeToU64(value: usize) u64 {
    return std.math.cast(u64, value) orelse std.math.maxInt(u64);
}

fn saturatingIncrement(value: *u64) void {
    saturatingAdd(value, 1);
}

fn saturatingAdd(value: *u64, amount: anytype) void {
    const increment: u64 = @intCast(amount);
    const remaining = std.math.maxInt(u64) - value.*;
    value.* = if (increment > remaining) std.math.maxInt(u64) else value.* + increment;
}

test "overlay API remains semantically complete" {
    std.testing.refAllDecls(Overlay);
}

test "upload planning preserves line pairs and triangle triples" {
    const empty = planUpload(.{ .line_capacity = 2, .triangle_capacity = 2 }, 0, 0);
    try std.testing.expect(empty.empty());
    try std.testing.expectEqual(@as(u32, 0), empty.line_vertices);
    try std.testing.expectEqual(@as(u32, 0), empty.triangle_vertices);

    const plan = planUpload(.{ .line_capacity = 4, .triangle_capacity = 3 }, 2, 2);
    try std.testing.expectEqual(@as(u32, 4), plan.line_vertices);
    try std.testing.expectEqual(@as(u32, 6), plan.triangle_vertices);
    try std.testing.expectEqual(@as(u32, 0), plan.line_vertices % 2);
    try std.testing.expectEqual(@as(u32, 0), plan.triangle_vertices % 3);
    try std.testing.expectEqual(@as(u64, 10 * @sizeOf(Vertex)), plan.totalBytes());
}

test "upload planning clamps both primitive streams visibly" {
    const plan = planUpload(.{ .line_capacity = 2, .triangle_capacity = 1 }, 7, 5);
    try std.testing.expectEqual(@as(u32, 2), plan.admitted_lines);
    try std.testing.expectEqual(@as(u32, 1), plan.admitted_triangles);
    try std.testing.expectEqual(@as(usize, 5), plan.dropped_lines);
    try std.testing.expectEqual(@as(usize, 4), plan.dropped_triangles);
    try std.testing.expectEqual(@as(u32, 4), plan.line_vertices);
    try std.testing.expectEqual(@as(u32, 3), plan.triangle_vertices);
}

test "resource planning rejects empty and overflowing capacities" {
    try std.testing.expectError(
        error.EmptyLineCapacity,
        planResources(.{ .line_capacity = 0 }),
    );
    try std.testing.expectError(
        error.EmptyTriangleCapacity,
        planResources(.{ .triangle_capacity = 0 }),
    );
    try std.testing.expectError(
        error.EmptySlotCount,
        planResources(.{ .slot_count = 0 }),
    );
    try std.testing.expectError(
        error.TooManySlots,
        planResources(.{ .slot_count = max_slot_count + 1 }),
    );
    try std.testing.expectError(
        error.LineCapacityTooLarge,
        planResources(.{ .line_capacity = std.math.maxInt(u32) }),
    );
    try std.testing.expectError(
        error.TriangleCapacityTooLarge,
        planResources(.{ .triangle_capacity = std.math.maxInt(u32) }),
    );

    const plan = try planResources(.{ .line_capacity = 2, .triangle_capacity = 3 });
    try std.testing.expectEqual(@as(u32, 4), plan.line_vertex_capacity);
    try std.testing.expectEqual(@as(u32, 9), plan.triangle_vertex_capacity);
    try std.testing.expectEqual(default_slot_count, plan.slot_count);
    try std.testing.expectEqual(
        @as(u64, 13 * @sizeOf(Vertex)),
        plan.gpuBytesPerSlot(),
    );
    try std.testing.expectEqual(
        @as(u64, default_slot_count) * 13 * @sizeOf(Vertex),
        plan.gpuBytes(),
    );
    try std.testing.expectEqual(plan.gpuBytes(), plan.transferBytes());
}

test "slot ring visibly saturates and retains latest completed generation" {
    const one_line = UploadPlan{
        .admitted_lines = 1,
        .line_vertices = 2,
        .line_bytes = 2 * @sizeOf(Vertex),
    };
    var ring = SlotRing.init(3);

    const first = ring.reserve().?;
    _ = ring.copySubmitted(first, 10, 10, one_line);
    try std.testing.expect(ring.copyCompleted(first));
    try std.testing.expectEqual(@as(u64, 10), ring.slots[ring.active_slot.?].generation);
    try std.testing.expect(ring.markDrawn());
    try std.testing.expectEqual(first, ring.frameSubmitted().?);

    const second = ring.reserve().?;
    _ = ring.copySubmitted(second, 11, 11, one_line);
    const third = ring.reserve().?;
    _ = ring.copySubmitted(third, 12, 12, one_line);
    try std.testing.expectEqual(@as(?u8, null), ring.reserve());
    try std.testing.expectEqual(@as(u64, 10), ring.slots[ring.active_slot.?].generation);
    try std.testing.expect(ring.containsPendingOrActiveGeneration(10));
    try std.testing.expect(ring.containsPendingOrActiveGeneration(11));
    try std.testing.expect(!ring.containsPendingOrActiveGeneration(13));

    const counts = ring.counts();
    try std.testing.expectEqual(@as(u8, 0), counts.free);
    try std.testing.expectEqual(@as(u8, 2), counts.copy_pending);
    try std.testing.expectEqual(@as(u8, 3), counts.busy());
    try std.testing.expect(!UploadStatus.backpressure_dropped.isFailure());
}

test "latest completed generation remains drawable with one new batch each frame" {
    const one_triangle = UploadPlan{
        .admitted_triangles = 1,
        .triangle_vertices = 3,
        .triangle_bytes = 3 * @sizeOf(Vertex),
    };
    var ring = SlotRing.init(3);
    var pending: ?u8 = null;

    var generation: u64 = 1;
    while (generation <= 6) : (generation += 1) {
        if (pending) |slot_index| {
            try std.testing.expect(ring.copyCompleted(slot_index));
            try std.testing.expectEqual(
                generation - 1,
                ring.slots[ring.active_slot.?].generation,
            );
            try std.testing.expect(ring.markDrawn());
            const drawn = ring.frameSubmitted().?;
            // A test completion models the latest same-queue frame fence.
            ring.frameCompleted(drawn);
        }
        const slot_index = ring.reserve().?;
        _ = ring.copySubmitted(slot_index, generation, generation, one_triangle);
        pending = slot_index;
    }
}

test "fresh enable epoch can retry the same generation behind stale pending work" {
    const one_line = UploadPlan{
        .admitted_lines = 1,
        .line_vertices = 2,
        .line_bytes = 2 * @sizeOf(Vertex),
    };
    var ring = SlotRing.init(3);
    const stale = ring.reserve().?;
    _ = ring.copySubmitted(stale, 41, 41, one_line);
    try std.testing.expect(ring.containsPendingOrActiveGeneration(41));

    // Disable/re-enable establishes a new evidence epoch while the old GPU
    // copy remains in flight. The same paused CPU generation is retryable.
    ring.clearActive();
    ring.clearActive();
    try std.testing.expect(!ring.containsPendingOrActiveGeneration(41));
    const retry = ring.reserve().?;
    _ = ring.copySubmitted(retry, 41, 41, one_line);
    try std.testing.expect(ring.containsPendingOrActiveGeneration(41));

    // The stale completion cannot cross the epoch barrier; the retry can.
    try std.testing.expect(!ring.copyCompleted(stale));
    try std.testing.expect(ring.copyCompleted(retry));
    try std.testing.expectEqual(retry, ring.active_slot.?);
}

test "frame-fence planning supports supersession and conservative retirement" {
    const one_line = UploadPlan{
        .admitted_lines = 1,
        .line_vertices = 2,
        .line_bytes = 2 * @sizeOf(Vertex),
    };
    var ring = SlotRing.init(3);
    const slot_index = ring.reserve().?;
    _ = ring.copySubmitted(slot_index, 4, 4, one_line);
    try std.testing.expect(ring.copyCompleted(slot_index));

    try std.testing.expect(ring.markDrawn());
    try std.testing.expect(ring.needsFrameFence());
    try std.testing.expectEqual(slot_index, ring.frameSubmitted().?);
    try std.testing.expect(ring.slots[slot_index].frame_in_flight);
    // A later frame can read the same immutable active buffer. Its later fence
    // supersedes the earlier fence while the planner remains bounded to one.
    try std.testing.expect(ring.markDrawn());
    try std.testing.expectEqual(slot_index, ring.frameSubmitted().?);
    try std.testing.expect(ring.slots[slot_index].frame_in_flight);

    try std.testing.expect(ring.markDrawn());
    ring.retire(slot_index);
    try std.testing.expectEqual(@as(?u8, null), ring.active_slot);
    try std.testing.expectEqual(@as(?u8, null), ring.drawn_slot);
    try std.testing.expectEqual(SlotStage.retired, ring.slots[slot_index].stage);
    try std.testing.expectEqual(@as(u8, 1), ring.counts().retired);
}

test "opaque RGB adaptation selects schema v1 contract RGB lanes" {
    try std.testing.expectEqual(
        [3]f32{ 0.25, 0.5, 0.75 },
        opaqueRgbFrom(.{ 0.25, 0.5, 0.75, 1.0 }),
    );
}

test "failure disables evidence and prevents stale generation draws" {
    var lifecycle = Lifecycle.init(true);
    lifecycle.uploadSucceeded(8, 4, 3);
    try std.testing.expect(lifecycle.canDraw(8));
    try std.testing.expect(!lifecycle.canDraw(9));

    lifecycle.uploadFailed();
    try std.testing.expectEqual(Mode.failed, lifecycle.mode);
    try std.testing.expectEqual(@as(u64, 0), lifecycle.uploaded_generation);
    try std.testing.expect(!lifecycle.canDraw(8));

    try std.testing.expectEqual(EnableResult.enabled, lifecycle.setEnabled(true));
    try std.testing.expectEqual(Mode.enabled, lifecycle.mode);
    try std.testing.expect(!lifecycle.canDraw(8));
}

test "repeated enable disable and deinitialize transitions are idempotent" {
    var lifecycle = Lifecycle.init(false);
    try std.testing.expectEqual(EnableResult.unchanged, lifecycle.setEnabled(false));
    try std.testing.expectEqual(EnableResult.enabled, lifecycle.setEnabled(true));
    try std.testing.expectEqual(EnableResult.unchanged, lifecycle.setEnabled(true));
    lifecycle.uploadSucceeded(3, 2, 0);
    try std.testing.expect(lifecycle.canDraw(3));
    try std.testing.expectEqual(EnableResult.disabled, lifecycle.setEnabled(false));
    try std.testing.expect(!lifecycle.canDraw(3));
    try std.testing.expectEqual(EnableResult.unchanged, lifecycle.setEnabled(false));

    lifecycle.deinitialize();
    lifecycle.deinitialize();
    try std.testing.expectEqual(Mode.deinitialized, lifecycle.mode);
    try std.testing.expectEqual(EnableResult.deinitialized, lifecycle.setEnabled(true));
}

test "fresh enable retry epoch accepts an unchanged CPU generation" {
    var metrics = Stats{
        .mode = .failed,
        .resources = .{},
        .latest_attempted_generation = 41,
        .last_upload_status = .failure_disabled,
        .last_plan = .{ .source_lines = 7 },
        .last_upload_bytes = 96,
    };
    resetAttemptCursor(&metrics);
    try std.testing.expectEqual(@as(u64, 0), metrics.latest_attempted_generation);
    try std.testing.expectEqual(UploadStatus.not_attempted, metrics.last_upload_status);
    try std.testing.expectEqual(UploadPlan{}, metrics.last_plan);
    try std.testing.expectEqual(@as(u64, 0), metrics.last_upload_bytes);
}
