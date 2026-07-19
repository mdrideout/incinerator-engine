//! Bounded, asynchronous incident visual capture for the macOS product.
//!
//! A low-resolution product-only lane retains five seconds before and two
//! seconds after a flag at 15 Hz. A full-resolution human-visible lane retains
//! five seconds at 1 Hz and owns the -5/-4/-3/-2/-1/flag/+1/+2 anchors. Both
//! copy through stable diagnostic textures;
//! neither waits for a GPU fence in the render loop.

const std = @import("std");
const renderer = @import("renderer.zig");
const sdl = @import("sdl.zig");
const incident_capture = @import("hosts/incident_capture.zig");

const c = sdl.c;

pub const pixel_bytes: usize = 4;
pub const trail_width: u32 = 480;
pub const trail_height: u32 = 270;
pub const trail_slot_count: usize = 80;
pub const trail_cadence_ns: u64 = std.time.ns_per_s / 15;
pub const trail_pre_roll_ns: u64 = 5 * std.time.ns_per_s;
pub const trail_post_roll_ns: u64 = 2 * std.time.ns_per_s;
// Seven one-second full-drawable slots retain six completed frames while one
// capture may still be in flight. Two separate event slots keep exact flag
// captures from consuming history when incidents overlap.
pub const anchor_slot_count: usize = 7;
pub const event_slot_count: usize = 2;
pub const anchor_cadence_ns: u64 = std.time.ns_per_s;
const anchor_selection_delay_ns: u64 = anchor_cadence_ns / 2;
pub const maximum_dimension: u32 = 4096;
pub const maximum_schedules: usize = 32;
const exported_sequence_capacity: usize = 4096;
const exports_per_prepare: usize = 3;

const Status = enum { free, submitted, complete };

const AnchorTag = struct {
    schedule_index: u8,
    requested_offset_ms: i16,
    target_ns: u64,
};

const Slot = struct {
    transfer: ?*c.SDL_GPUTransferBuffer = null,
    fence: ?*c.SDL_GPUFence = null,
    status: Status = .free,
    capture_sequence: u64 = 0,
    captured_ns: u64 = 0,
    submitted_ns: u64 = 0,
    completed_ns: u64 = 0,
    authority_tick: u64 = 0,
    presentation_frame: u64 = 0,
    drawable_generation: u32 = 0,
    pin_mask: u32 = 0,
    anchor_tag: ?AnchorTag = null,
};

const Schedule = struct {
    anomaly_id: u32,
    flagged_ns: u64,
    t0_submitted: bool = false,
    p1_attached: bool = false,
    p2_attached: bool = false,
};

pub const Stats = struct {
    trail_submitted: u64 = 0,
    trail_completed: u64 = 0,
    anchor_submitted: u64 = 0,
    anchor_completed: u64 = 0,
    missed: u64 = 0,
    fence_failures: u64 = 0,
    attached: u64 = 0,
    suspicious: u64 = 0,
    fence_latency_samples: u64 = 0,
    fence_latency_total_ns: u64 = 0,
    fence_latency_max_ns: u64 = 0,
};

pub const Health = struct {
    stats: Stats,
    anchor_width: u32,
    anchor_height: u32,
    trail_bytes_per_slot: u32,
    anchor_bytes_per_slot: u32,
    trail_slots: u8,
    anchor_slots: u8,
    bounded_download_bytes: u64,
};

pub const Owner = struct {
    device: *c.SDL_GPUDevice,
    format: c.SDL_GPUTextureFormat,
    bgra: bool,
    trail_texture: ?*c.SDL_GPUTexture = null,
    anchor_texture: ?*c.SDL_GPUTexture = null,
    trail_slots: [trail_slot_count]Slot = @splat(.{}),
    anchor_slots: [anchor_slot_count]Slot = @splat(.{}),
    event_slots: [event_slot_count]Slot = @splat(.{}),
    pending_trail: ?u8 = null,
    pending_anchor: ?u8 = null,
    pending_event: ?u8 = null,
    schedules: [maximum_schedules]Schedule = undefined,
    schedule_count: u8 = 0,
    exported_sequences: [exported_sequence_capacity]u64 = undefined,
    exported_sequence_count: u16 = 0,
    next_capture_sequence: u64 = 1,
    last_trail_ns: u64 = 0,
    last_anchor_ns: u64 = 0,
    anchor_width: u32 = 0,
    anchor_height: u32 = 0,
    anchor_transfer_bytes: u32 = 0,
    drawable_generation: u32 = 1,
    stats: Stats = .{},
    hardening_profile: incident_capture.HardeningProfile = .none,

    pub fn init(
        gpu: *renderer.Renderer,
        hardening_profile: incident_capture.HardeningProfile,
    ) !Owner {
        const format = gpu.getSwapchainFormat();
        var result = Owner{
            .device = gpu.getDevice(),
            .format = format,
            .bgra = format == c.SDL_GPU_TEXTUREFORMAT_B8G8R8A8_UNORM or
                format == c.SDL_GPU_TEXTUREFORMAT_B8G8R8A8_UNORM_SRGB,
            .hardening_profile = hardening_profile,
        };
        errdefer result.releaseTrailResources();
        result.trail_texture = try createCaptureTexture(
            result.device,
            format,
            trail_width,
            trail_height,
        );
        const trail_bytes = trailTransferBytes();
        for (&result.trail_slots) |*slot| {
            slot.transfer = createDownloadBuffer(result.device, trail_bytes) orelse
                return error.IncidentTrailTransferCreationFailed;
        }
        return result;
    }

    pub fn deinit(self: *Owner) void {
        _ = c.SDL_WaitForGPUIdle(self.device);
        self.releaseTrailResources();
        self.releaseAnchorResources();
        self.* = undefined;
    }

    pub fn drain(self: *Owner, capture: *incident_capture.Capture) void {
        _ = c.SDL_WaitForGPUIdle(self.device);
        self.poll(capture, capture.nowNs());
        while (self.exportPinnedTrail(capture, self.trail_slots.len) != 0) {}
    }

    pub fn health(self: *const Owner) Health {
        const trail_bytes = trailTransferBytes();
        return .{
            .stats = self.stats,
            .anchor_width = self.anchor_width,
            .anchor_height = self.anchor_height,
            .trail_bytes_per_slot = trail_bytes,
            .anchor_bytes_per_slot = self.anchor_transfer_bytes,
            .trail_slots = trail_slot_count,
            .anchor_slots = anchor_slot_count + event_slot_count,
            .bounded_download_bytes = @as(u64, trail_bytes) * trail_slot_count +
                @as(u64, self.anchor_transfer_bytes) *
                    (anchor_slot_count + event_slot_count),
        };
    }

    pub fn flag(
        self: *Owner,
        capture: *incident_capture.Capture,
        anomaly_id: u32,
        flagged_ns: u64,
    ) void {
        if (self.schedule_count == self.schedules.len) {
            self.stats.missed +|= 1;
            capture.noteVisualFailure(anomaly_id);
            return;
        }
        const schedule_index = self.schedule_count;
        self.schedules[schedule_index] = .{
            .anomaly_id = anomaly_id,
            .flagged_ns = flagged_ns,
        };
        self.schedule_count += 1;
        const bit = scheduleBit(schedule_index);
        for (&self.trail_slots) |*slot| {
            if (slot.status != .complete or slot.captured_ns > flagged_ns or
                slot.captured_ns < flagged_ns -| trail_pre_roll_ns) continue;
            slot.pin_mask |= bit;
        }
        inline for ([_]i16{ -5000, -4000, -3000, -2000, -1000 }) |offset_ms| {
            self.attachNearestAnchor(capture, schedule_index, offset_ms);
        }
        self.attachProductFlag(capture, schedule_index);
    }

    /// Capture the product scene before developer UI. Call after the product
    /// render pass ends and before ImGui starts its pass.
    pub fn prepareProduct(
        self: *Owner,
        gpu: *renderer.Renderer,
        capture: *incident_capture.Capture,
        now_ns: u64,
        authority_tick: u64,
        presentation_frame: u64,
    ) void {
        self.poll(capture, now_ns);
        _ = self.exportPinnedTrail(capture, exports_per_prepare);
        if (self.pending_trail != null or now_ns -| self.last_trail_ns < trail_cadence_ns) return;
        const extent = gpu.getSwapchainExtent() orelse return;
        if (!self.ensureAnchorResources(extent.width, extent.height)) {
            self.stats.missed +|= 1;
            return;
        }
        const index = reusableSlot(&self.trail_slots) orelse {
            self.stats.missed +|= 1;
            return;
        };
        const slot = &self.trail_slots[index];
        var pin_mask: u32 = 0;
        for (self.schedules[0..self.schedule_count], 0..) |schedule, schedule_index| {
            if (now_ns >= schedule.flagged_ns and
                now_ns <= schedule.flagged_ns +| trail_post_roll_ns)
            {
                pin_mask |= scheduleBit(schedule_index);
            }
        }
        if (!self.submitCapture(
            gpu,
            slot,
            self.trail_texture.?,
            trail_width,
            trail_height,
            now_ns,
            authority_tick,
            presentation_frame,
        )) return;
        slot.pin_mask = pin_mask;
        self.pending_trail = @intCast(index);
        self.last_trail_ns = now_ns;
        self.stats.trail_submitted +|= 1;
    }

    /// Capture the final human-visible drawable after developer UI.
    pub fn prepareHuman(
        self: *Owner,
        gpu: *renderer.Renderer,
        capture: *incident_capture.Capture,
        now_ns: u64,
        authority_tick: u64,
        presentation_frame: u64,
    ) void {
        self.poll(capture, now_ns);
        _ = self.exportPinnedTrail(capture, exports_per_prepare);
        const extent = gpu.getSwapchainExtent() orelse return;
        if (!self.ensureAnchorResources(extent.width, extent.height)) {
            self.stats.missed +|= 1;
            return;
        }

        for (self.schedules[0..self.schedule_count], 0..) |*schedule, schedule_index| {
            if (!schedule.t0_submitted and self.pending_event == null) {
                const event_index = reusableSlot(&self.event_slots) orelse {
                    self.stats.missed +|= 1;
                    capture.noteVisualFailure(schedule.anomaly_id);
                    continue;
                };
                schedule.t0_submitted = true;
                const event_slot = &self.event_slots[event_index];
                if (!self.submitCapture(
                    gpu,
                    event_slot,
                    self.anchor_texture.?,
                    extent.width,
                    extent.height,
                    now_ns,
                    authority_tick,
                    presentation_frame,
                )) {
                    capture.noteVisualFailure(schedule.anomaly_id);
                    continue;
                }
                event_slot.anchor_tag = .{
                    .schedule_index = @intCast(schedule_index),
                    .requested_offset_ms = 0,
                    .target_ns = schedule.flagged_ns,
                };
                self.pending_event = @intCast(event_index);
                self.stats.anchor_submitted +|= 1;
            }
            if (!schedule.p1_attached and
                now_ns >= schedule.flagged_ns +| std.time.ns_per_s +| anchor_selection_delay_ns)
            {
                schedule.p1_attached = true;
                self.attachNearestAnchor(capture, @intCast(schedule_index), 1000);
            }
            if (!schedule.p2_attached and
                now_ns >= schedule.flagged_ns +| 2 * std.time.ns_per_s +| anchor_selection_delay_ns)
            {
                schedule.p2_attached = true;
                self.attachNearestAnchor(capture, @intCast(schedule_index), 2000);
            }
        }
        if (self.pending_anchor != null or now_ns -| self.last_anchor_ns < anchor_cadence_ns) return;
        const index = reusableSlot(&self.anchor_slots) orelse {
            self.stats.missed +|= 1;
            return;
        };
        const slot = &self.anchor_slots[index];
        if (!self.submitCapture(
            gpu,
            slot,
            self.anchor_texture.?,
            extent.width,
            extent.height,
            now_ns,
            authority_tick,
            presentation_frame,
        )) return;
        self.pending_anchor = @intCast(index);
        self.last_anchor_ns = now_ns;
        self.stats.anchor_submitted +|= 1;
    }

    /// Called only after the renderer's real frame submission succeeds.
    pub fn afterSubmission(self: *Owner, gpu: *renderer.Renderer) void {
        if (self.pending_trail) |index| {
            self.pending_trail = null;
            self.assignFence(gpu, &self.trail_slots[index]);
        }
        if (self.pending_anchor) |index| {
            self.pending_anchor = null;
            self.assignFence(gpu, &self.anchor_slots[index]);
        }
        if (self.pending_event) |index| {
            self.pending_event = null;
            self.assignFence(gpu, &self.event_slots[index]);
        }
    }

    fn assignFence(self: *Owner, gpu: *renderer.Renderer, slot: *Slot) void {
        if (self.hardening_profile == .screenshot_fence) {
            slot.status = .free;
            slot.anchor_tag = null;
            slot.pin_mask = 0;
            self.stats.fence_failures +|= 1;
            self.stats.missed +|= 1;
            return;
        }
        const fence = gpu.acquirePostSubmissionFence() catch {
            slot.status = .free;
            slot.anchor_tag = null;
            slot.pin_mask = 0;
            self.stats.fence_failures +|= 1;
            self.stats.missed +|= 1;
            return;
        };
        slot.fence = fence;
    }

    fn submitCapture(
        self: *Owner,
        gpu: *renderer.Renderer,
        slot: *Slot,
        stable_texture: *c.SDL_GPUTexture,
        width: u32,
        height: u32,
        now_ns: u64,
        authority_tick: u64,
        presentation_frame: u64,
    ) bool {
        if (self.hardening_profile == .screenshot_submission) {
            self.stats.missed +|= 1;
            return false;
        }
        const cmd = gpu.getCurrentCommandBuffer() orelse return false;
        const swapchain = gpu.getSwapchainTexture() orelse return false;
        const extent = gpu.getSwapchainExtent() orelse return false;
        if (slot.fence) |fence| {
            c.SDL_ReleaseGPUFence(self.device, fence);
            slot.fence = null;
        }
        const source_texture = self.anchor_texture orelse return false;
        const stable_is_source = stable_texture == source_texture;
        const source_copy = c.SDL_BeginGPUCopyPass(cmd) orelse {
            self.stats.missed +|= 1;
            return false;
        };
        c.SDL_CopyGPUTextureToTexture(
            source_copy,
            &c.SDL_GPUTextureLocation{
                .texture = swapchain,
                .mip_level = 0,
                .layer = 0,
                .x = 0,
                .y = 0,
            },
            &c.SDL_GPUTextureLocation{
                .texture = source_texture,
                .mip_level = 0,
                .layer = 0,
                .x = 0,
                .y = 0,
            },
            extent.width,
            extent.height,
            1,
            true,
        );
        c.SDL_EndGPUCopyPass(source_copy);
        if (!stable_is_source) c.SDL_BlitGPUTexture(cmd, &c.SDL_GPUBlitInfo{
            .source = .{
                .texture = source_texture,
                .mip_level = 0,
                .layer_or_depth_plane = 0,
                .x = 0,
                .y = 0,
                .w = extent.width,
                .h = extent.height,
            },
            .destination = .{
                .texture = stable_texture,
                .mip_level = 0,
                .layer_or_depth_plane = 0,
                .x = 0,
                .y = 0,
                .w = width,
                .h = height,
            },
            .load_op = c.SDL_GPU_LOADOP_DONT_CARE,
            .clear_color = .{ .r = 0, .g = 0, .b = 0, .a = 1 },
            .flip_mode = c.SDL_FLIP_NONE,
            .filter = c.SDL_GPU_FILTER_LINEAR,
            .cycle = true,
            .padding1 = 0,
            .padding2 = 0,
            .padding3 = 0,
        });
        const download_copy = c.SDL_BeginGPUCopyPass(cmd) orelse {
            self.stats.missed +|= 1;
            return false;
        };
        c.SDL_DownloadFromGPUTexture(download_copy, &c.SDL_GPUTextureRegion{
            .texture = stable_texture,
            .mip_level = 0,
            .layer = 0,
            .x = 0,
            .y = 0,
            .z = 0,
            .w = width,
            .h = height,
            .d = 1,
        }, &c.SDL_GPUTextureTransferInfo{
            .transfer_buffer = slot.transfer.?,
            .offset = 0,
            .pixels_per_row = width,
            .rows_per_layer = height,
        });
        c.SDL_EndGPUCopyPass(download_copy);
        slot.status = .submitted;
        slot.capture_sequence = self.next_capture_sequence;
        self.next_capture_sequence +|= 1;
        slot.captured_ns = now_ns;
        slot.submitted_ns = now_ns;
        slot.completed_ns = 0;
        slot.authority_tick = authority_tick;
        slot.presentation_frame = presentation_frame;
        slot.drawable_generation = self.drawable_generation;
        return true;
    }

    fn poll(
        self: *Owner,
        capture: *incident_capture.Capture,
        now_ns: u64,
    ) void {
        self.pollLane(capture, &self.trail_slots, now_ns, .product_trail);
        self.pollLane(capture, &self.anchor_slots, now_ns, .human_visible);
        self.pollLane(capture, &self.event_slots, now_ns, .human_visible);
    }

    fn pollLane(
        self: *Owner,
        capture: *incident_capture.Capture,
        slots: anytype,
        now_ns: u64,
        source: incident_capture.VisualSource,
    ) void {
        for (slots) |*slot| {
            if (slot.status != .submitted) continue;
            const fence = slot.fence orelse continue;
            if (!c.SDL_QueryGPUFence(self.device, fence)) continue;
            c.SDL_ReleaseGPUFence(self.device, fence);
            slot.fence = null;
            slot.status = .complete;
            slot.completed_ns = now_ns;
            const latency_ns = slot.completed_ns -| slot.submitted_ns;
            self.stats.fence_latency_samples +|= 1;
            self.stats.fence_latency_total_ns +|= latency_ns;
            self.stats.fence_latency_max_ns = @max(
                self.stats.fence_latency_max_ns,
                latency_ns,
            );
            switch (source) {
                .product_trail => self.stats.trail_completed +|= 1,
                .human_visible => self.stats.anchor_completed +|= 1,
                else => unreachable,
            }
            if (slot.anchor_tag) |tag| {
                self.exportAnchor(capture, slot, tag);
                slot.anchor_tag = null;
            }
        }
    }

    fn exportPinnedTrail(
        self: *Owner,
        capture: *incident_capture.Capture,
        limit: usize,
    ) usize {
        var exported: usize = 0;
        for (&self.trail_slots) |*slot| {
            if (exported == limit) break;
            if (slot.status != .complete or slot.pin_mask == 0) continue;
            const mapped = c.SDL_MapGPUTransferBuffer(self.device, slot.transfer.?, false) orelse {
                self.stats.missed +|= 1;
                slot.pin_mask = 0;
                continue;
            };
            defer c.SDL_UnmapGPUTransferBuffer(self.device, slot.transfer.?);
            const source: [*]const u8 = @ptrCast(mapped);
            const bytes = source[0..trailTransferBytes()];
            const digest = std.hash.Wyhash.hash(0, bytes);
            const suspicious = suspiciousPixels(bytes, trail_width, trail_height);
            if (suspicious) self.stats.suspicious +|= 1;
            var wrote_pixels = self.wasExported(slot.capture_sequence);
            var mask = slot.pin_mask;
            while (mask != 0) {
                const schedule_index: u5 = @intCast(@ctz(mask));
                mask &= ~scheduleBit(schedule_index);
                if (schedule_index >= self.schedule_count) continue;
                const schedule = self.schedules[schedule_index];
                var owned: ?[]u8 = null;
                if (!wrote_pixels) {
                    owned = std.heap.page_allocator.dupe(u8, bytes) catch {
                        self.stats.missed +|= 1;
                        capture.noteVisualFailure(schedule.anomaly_id);
                        continue;
                    };
                }
                const attached = capture.attachVisual(
                    schedule.anomaly_id,
                    metadataForSlot(
                        slot,
                        .product_trail,
                        null,
                        schedule.flagged_ns,
                        slot.captured_ns,
                        trail_width,
                        trail_height,
                        self.bgra,
                        digest,
                        suspicious,
                    ),
                    owned,
                );
                if (attached) {
                    self.stats.attached +|= 1;
                    if (!wrote_pixels) {
                        self.markExported(slot.capture_sequence);
                        wrote_pixels = true;
                    }
                }
            }
            slot.pin_mask = 0;
            exported += 1;
        }
        return exported;
    }

    fn exportAnchor(
        self: *Owner,
        capture: *incident_capture.Capture,
        slot: *Slot,
        tag: AnchorTag,
    ) void {
        if (tag.schedule_index >= self.schedule_count) return;
        const schedule = self.schedules[tag.schedule_index];
        self.attachSlot(
            capture,
            slot,
            schedule.anomaly_id,
            .human_visible,
            tag.requested_offset_ms,
            schedule.flagged_ns,
            tag.target_ns,
            self.anchor_width,
            self.anchor_height,
        );
    }

    fn attachNearestAnchor(
        self: *Owner,
        capture: *incident_capture.Capture,
        schedule_index: u8,
        requested_offset_ms: i16,
    ) void {
        const schedule = self.schedules[schedule_index];
        const target = if (requested_offset_ms < 0)
            schedule.flagged_ns -| @as(u64, @intCast(-requested_offset_ms)) * std.time.ns_per_ms
        else
            schedule.flagged_ns +| @as(u64, @intCast(requested_offset_ms)) * std.time.ns_per_ms;
        const slot = nearestComplete(&self.anchor_slots, target) orelse {
            self.stats.missed +|= 1;
            capture.noteVisualFailure(schedule.anomaly_id);
            return;
        };
        self.attachSlot(
            capture,
            slot,
            schedule.anomaly_id,
            .human_visible,
            requested_offset_ms,
            schedule.flagged_ns,
            target,
            self.anchor_width,
            self.anchor_height,
        );
    }

    fn attachProductFlag(
        self: *Owner,
        capture: *incident_capture.Capture,
        schedule_index: u8,
    ) void {
        const schedule = self.schedules[schedule_index];
        const slot = nearestComplete(&self.trail_slots, schedule.flagged_ns) orelse {
            self.stats.missed +|= 1;
            capture.noteVisualFailure(schedule.anomaly_id);
            return;
        };
        self.attachSlot(
            capture,
            slot,
            schedule.anomaly_id,
            .product_flag,
            0,
            schedule.flagged_ns,
            schedule.flagged_ns,
            trail_width,
            trail_height,
        );
    }

    fn attachSlot(
        self: *Owner,
        capture: *incident_capture.Capture,
        slot: *Slot,
        anomaly_id: u32,
        visual_source: incident_capture.VisualSource,
        requested_offset_ms: i16,
        flagged_ns: u64,
        target_ns: u64,
        width: u32,
        height: u32,
    ) void {
        const mapped = c.SDL_MapGPUTransferBuffer(self.device, slot.transfer.?, false) orelse {
            self.stats.missed +|= 1;
            capture.noteVisualFailure(anomaly_id);
            return;
        };
        defer c.SDL_UnmapGPUTransferBuffer(self.device, slot.transfer.?);
        const byte_count: usize = @as(usize, width) * height * pixel_bytes;
        const source: [*]const u8 = @ptrCast(mapped);
        const bytes = source[0..byte_count];
        const owned = std.heap.page_allocator.dupe(u8, bytes) catch {
            self.stats.missed +|= 1;
            capture.noteVisualFailure(anomaly_id);
            return;
        };
        const digest = std.hash.Wyhash.hash(0, bytes);
        const suspicious = suspiciousPixels(bytes, width, height);
        if (suspicious) self.stats.suspicious +|= 1;
        if (capture.attachVisual(
            anomaly_id,
            metadataForSlot(
                slot,
                visual_source,
                requested_offset_ms,
                flagged_ns,
                target_ns,
                width,
                height,
                self.bgra,
                digest,
                suspicious,
            ),
            owned,
        )) self.stats.attached +|= 1 else self.stats.missed +|= 1;
    }

    fn ensureAnchorResources(self: *Owner, width: u32, height: u32) bool {
        if (width == self.anchor_width and height == self.anchor_height and
            self.anchor_texture != null) return true;
        if (width == 0 or height == 0 or width > maximum_dimension or height > maximum_dimension) {
            return false;
        }
        for (self.anchor_slots) |slot| if (slot.status == .submitted) return false;
        for (self.event_slots) |slot| if (slot.status == .submitted) return false;
        self.releaseAnchorResources();
        const bytes = std.math.mul(u32, width, height) catch return false;
        self.anchor_transfer_bytes = std.math.mul(u32, bytes, pixel_bytes) catch return false;
        self.anchor_texture = createCaptureTexture(self.device, self.format, width, height) catch {
            self.anchor_transfer_bytes = 0;
            return false;
        };
        for (&self.anchor_slots) |*slot| {
            slot.transfer = createDownloadBuffer(self.device, self.anchor_transfer_bytes) orelse {
                self.releaseAnchorResources();
                return false;
            };
        }
        for (&self.event_slots) |*slot| {
            slot.transfer = createDownloadBuffer(self.device, self.anchor_transfer_bytes) orelse {
                self.releaseAnchorResources();
                return false;
            };
        }
        self.anchor_width = width;
        self.anchor_height = height;
        self.drawable_generation +|= 1;
        if (self.drawable_generation == 0) self.drawable_generation = 1;
        return true;
    }

    fn releaseTrailResources(self: *Owner) void {
        for (&self.trail_slots) |*slot| releaseSlot(self.device, slot);
        if (self.trail_texture) |texture| c.SDL_ReleaseGPUTexture(self.device, texture);
        self.trail_texture = null;
    }

    fn releaseAnchorResources(self: *Owner) void {
        for (&self.anchor_slots) |*slot| releaseSlot(self.device, slot);
        for (&self.event_slots) |*slot| releaseSlot(self.device, slot);
        if (self.anchor_texture) |texture| c.SDL_ReleaseGPUTexture(self.device, texture);
        self.anchor_texture = null;
        self.anchor_width = 0;
        self.anchor_height = 0;
        self.anchor_transfer_bytes = 0;
        self.pending_anchor = null;
        self.pending_event = null;
    }

    fn wasExported(self: *const Owner, sequence: u64) bool {
        for (self.exported_sequences[0..self.exported_sequence_count]) |candidate| {
            if (candidate == sequence) return true;
        }
        return false;
    }

    fn markExported(self: *Owner, sequence: u64) void {
        if (self.wasExported(sequence)) return;
        if (self.exported_sequence_count == self.exported_sequences.len) {
            self.stats.missed +|= 1;
            return;
        }
        self.exported_sequences[self.exported_sequence_count] = sequence;
        self.exported_sequence_count += 1;
    }
};

fn metadataForSlot(
    slot: *const Slot,
    source: incident_capture.VisualSource,
    requested_offset_ms: ?i16,
    flagged_ns: u64,
    target_ns: u64,
    width: u32,
    height: u32,
    bgra: bool,
    digest: u64,
    suspicious: bool,
) incident_capture.VisualFrameMetadata {
    return .{
        .capture_sequence = slot.capture_sequence,
        .source = source,
        .requested_offset_ms = requested_offset_ms,
        .flag_monotonic_ns = flagged_ns,
        .target_monotonic_ns = target_ns,
        .captured_monotonic_ns = slot.captured_ns,
        .submitted_monotonic_ns = slot.submitted_ns,
        .completed_monotonic_ns = slot.completed_ns,
        .authority_tick = slot.authority_tick,
        .presentation_frame = slot.presentation_frame,
        .drawable_generation = slot.drawable_generation,
        .width = @intCast(width),
        .height = @intCast(height),
        .bgra = bgra,
        .fence_latency_ns = slot.completed_ns -| slot.submitted_ns,
        .pixel_digest = digest,
        .suspicious = suspicious,
    };
}

fn createCaptureTexture(
    device: *c.SDL_GPUDevice,
    format: c.SDL_GPUTextureFormat,
    width: u32,
    height: u32,
) !*c.SDL_GPUTexture {
    return c.SDL_CreateGPUTexture(device, &c.SDL_GPUTextureCreateInfo{
        .type = c.SDL_GPU_TEXTURETYPE_2D,
        .format = format,
        .usage = c.SDL_GPU_TEXTUREUSAGE_COLOR_TARGET |
            c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
        .width = width,
        .height = height,
        .layer_count_or_depth = 1,
        .num_levels = 1,
        .sample_count = c.SDL_GPU_SAMPLECOUNT_1,
        .props = 0,
    }) orelse error.IncidentCaptureTextureCreationFailed;
}

fn createDownloadBuffer(device: *c.SDL_GPUDevice, bytes: u32) ?*c.SDL_GPUTransferBuffer {
    return c.SDL_CreateGPUTransferBuffer(device, &c.SDL_GPUTransferBufferCreateInfo{
        .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_DOWNLOAD,
        .size = bytes,
        .props = 0,
    });
}

fn releaseSlot(device: *c.SDL_GPUDevice, slot: *Slot) void {
    if (slot.fence) |fence| c.SDL_ReleaseGPUFence(device, fence);
    if (slot.transfer) |transfer| c.SDL_ReleaseGPUTransferBuffer(device, transfer);
    slot.* = .{};
}

fn trailTransferBytes() u32 {
    return trail_width * trail_height * pixel_bytes;
}

fn scheduleBit(index: anytype) u32 {
    return @as(u32, 1) << @intCast(index);
}

fn reusableSlot(slots: anytype) ?usize {
    var oldest: ?usize = null;
    for (slots, 0..) |*slot, index| {
        if (slot.status == .free) return index;
        if (slot.status != .complete or slot.pin_mask != 0 or slot.anchor_tag != null) continue;
        if (oldest == null or slot.captured_ns < slots[oldest.?].captured_ns) oldest = index;
    }
    return oldest;
}

fn nearestComplete(slots: anytype, target_ns: u64) ?*Slot {
    var best: ?*Slot = null;
    var best_distance: u64 = std.math.maxInt(u64);
    for (slots) |*slot| {
        if (slot.status != .complete) continue;
        const distance = if (slot.captured_ns > target_ns)
            slot.captured_ns - target_ns
        else
            target_ns - slot.captured_ns;
        if (distance < best_distance) {
            best = slot;
            best_distance = distance;
        }
    }
    return best;
}

fn suspiciousPixels(pixels: []const u8, width: u32, height: u32) bool {
    if (width == 0 or height == 0 or pixels.len < @as(usize, width) * height * pixel_bytes) {
        return true;
    }
    var zero_pixels: usize = 0;
    var block_rows: u32 = 0;
    var maximum_block_rows: u32 = 0;
    var quantized_colors: [4096]u32 = @splat(0);
    var dominant_color_pixels: u32 = 0;
    for (0..height) |y| {
        var run: u32 = 0;
        var maximum_run: u32 = 0;
        for (0..width) |x| {
            const offset = (@as(usize, y) * width + x) * pixel_bytes;
            const zero = pixels[offset] == 0 and pixels[offset + 1] == 0 and
                pixels[offset + 2] == 0;
            const color_index = (@as(usize, pixels[offset] >> 4) << 8) |
                (@as(usize, pixels[offset + 1] >> 4) << 4) |
                @as(usize, pixels[offset + 2] >> 4);
            quantized_colors[color_index] += 1;
            dominant_color_pixels = @max(
                dominant_color_pixels,
                quantized_colors[color_index],
            );
            if (zero) {
                zero_pixels += 1;
                run += 1;
                maximum_run = @max(maximum_run, run);
            } else {
                run = 0;
            }
        }
        if (maximum_run >= width / 3) {
            block_rows += 1;
            maximum_block_rows = @max(maximum_block_rows, block_rows);
        } else {
            block_rows = 0;
        }
    }
    const total: usize = @as(usize, width) * height;
    return zero_pixels * 2 >= total or
        maximum_block_rows >= @max(1, height / 4) or
        @as(usize, dominant_color_pixels) * 4 >= total * 3;
}

test "visual integrity warning detects a large zero rectangle" {
    const width: u32 = 12;
    const height: u32 = 8;
    var pixels: [width * height * pixel_bytes]u8 = @splat(255);
    for (2..6) |y| for (1..9) |x| {
        const offset = (y * width + x) * pixel_bytes;
        pixels[offset + 0] = 0;
        pixels[offset + 1] = 0;
        pixels[offset + 2] = 0;
    };
    try std.testing.expect(suspiciousPixels(&pixels, width, height));
}

test "visual integrity warning accepts a varied frame" {
    const width: u32 = 12;
    const height: u32 = 8;
    var pixels: [width * height * pixel_bytes]u8 = undefined;
    for (&pixels, 0..) |*byte, index| byte.* = @truncate(index * 17 + 3);
    try std.testing.expect(!suspiciousPixels(&pixels, width, height));
}

test "visual integrity warning detects a dominant nonzero surface" {
    const width: u32 = 12;
    const height: u32 = 8;
    var pixels: [width * height * pixel_bytes]u8 = @splat(255);
    for (0..height) |y| for (0..10) |x| {
        const offset = (y * width + x) * pixel_bytes;
        pixels[offset + 0] = 230;
        pixels[offset + 1] = 10;
        pixels[offset + 2] = 10;
    };
    try std.testing.expect(suspiciousPixels(&pixels, width, height));
}

test "Retina capture policy stays within the declared download memory budget" {
    const retina_anchor_bytes = @as(u64, 2560) * 1440 * pixel_bytes *
        (anchor_slot_count + event_slot_count);
    const trail_bytes = @as(u64, trailTransferBytes()) * trail_slot_count;
    try std.testing.expect(retina_anchor_bytes + trail_bytes <= 176 * 1024 * 1024);
    try std.testing.expect(anchor_slot_count >= 7);
    try std.testing.expect(anchor_cadence_ns * (anchor_slot_count - 1) >=
        5 * std.time.ns_per_s);
}
