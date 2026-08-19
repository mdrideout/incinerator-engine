//! Bounded per-process human-test incident bundle and asynchronous writer.
//!
//! Producers submit already-bounded typed projections. The writer thread is
//! the sole owner of stream file handles and durable manifest/handoff writes.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const engine = @import("incinerator_engine");
const sandbox_replay = @import("sandbox_replay");
const sandbox_authoring = @import("sandbox_authoring");
const sandbox_host_contracts = @import("sandbox_host_contracts");
const session_protocol = @import("session_protocol");
const authority_diagnostics = @import("session_authority_diagnostics");
const editor_contract = @import("../editor/tool.zig");

const incident = @import("../engine/incident.zig");

pub const stream_rotation_bytes: u64 = 4 * 1024 * 1024;
pub const run_budget_bytes: u64 = 512 * 1024 * 1024;
/// Raw visual evidence has an explicit admission ceiling. The remaining run
/// budget is reserved for streams, anomaly lifecycle, materialized windows,
/// replay, manifests, and the LLM handoff. A visual rejection degrades only
/// that anomaly; it must never prevent the tester from copying the handoff.
pub const visual_budget_bytes: u64 = 384 * 1024 * 1024;
pub const non_visual_reserve_bytes: u64 = run_budget_bytes - visual_budget_bytes;
pub const maximum_stored_anchor_width: u16 = 1280;
pub const maximum_stored_anchor_height: u16 = 720;
pub const writer_queue_capacity: usize = 1024;
/// Entity state now carries S12 route lineage plus S13 population identity and
/// activity. Keep one complete NDJSON object atomic in the writer queue; 2 KiB
/// truncated valid NPC records after those schemas composed.
pub const max_line_bytes: usize = 4096;
pub const pre_roll_ns: u64 = 15 * std.time.ns_per_s;
pub const post_roll_ns: u64 = 5 * std.time.ns_per_s;
pub const retained_unflagged_runs: usize = 20;
pub const hardening_visual_budget_bytes: u64 = 16 * 1024 * 1024;
pub const manifest_protocol_cohort: u16 = session_protocol.wire_version;
pub const manifest_snapshot_cohort: u16 = sandbox_host_contracts.snapshot_schema;
const complete_human_anchor_mask: u8 = 0xff;

/// Explicit installed-product fault profiles used only by the IC5-G
/// acceptance journey. The default profile leaves every production boundary
/// unchanged.
pub const HardeningProfile = enum {
    none,
    queue_pressure,
    visual_budget,
    writer_budget,
    screenshot_submission,
    screenshot_fence,
};

const Stream = enum { timeline, state, input, metrics, anomalies };
const ByteClass = enum { stream, visual, replay, metadata };

const Line = struct {
    stream: Stream,
    sequence: u64,
    len: u16,
    bytes: [max_line_bytes]u8,

    fn slice(self: *const Line) []const u8 {
        return self.bytes[0..self.len];
    }
};

const Handoff = struct {
    len: u16,
    bytes: [incident.max_handoff_bytes]u8,

    fn slice(self: *const Handoff) []const u8 {
        return self.bytes[0..self.len];
    }
};

const HandoffJob = struct {
    bytes: []u8,
};

pub const VisualSource = enum {
    product_trail,
    human_visible,
    product_flag,
    semantic_id,
};

pub const VisualFrameMetadata = struct {
    capture_sequence: u64,
    source: VisualSource,
    requested_offset_ms: ?i16,
    flag_monotonic_ns: u64,
    target_monotonic_ns: u64,
    captured_monotonic_ns: u64,
    submitted_monotonic_ns: u64,
    completed_monotonic_ns: u64,
    authority_tick: u64,
    presentation_frame: u64,
    drawable_generation: u32,
    width: u16,
    height: u16,
    bgra: bool,
    fence_latency_ns: u64,
    pixel_digest: u64,
    suspicious: bool,
};

const StoredVisualExtent = struct {
    width: u16,
    height: u16,
};

fn storedVisualExtent(metadata: VisualFrameMetadata) StoredVisualExtent {
    if (metadata.source != .human_visible or
        (metadata.width <= maximum_stored_anchor_width and
            metadata.height <= maximum_stored_anchor_height))
    {
        return .{ .width = metadata.width, .height = metadata.height };
    }
    const source_width: u64 = metadata.width;
    const source_height: u64 = metadata.height;
    const max_width: u64 = maximum_stored_anchor_width;
    const max_height: u64 = maximum_stored_anchor_height;
    if (source_width * max_height >= source_height * max_width) {
        return .{
            .width = maximum_stored_anchor_width,
            .height = @intCast(@max(@as(u64, 1), @divFloor(
                source_height * max_width,
                source_width,
            ))),
        };
    }
    return .{
        .width = @intCast(@max(@as(u64, 1), @divFloor(
            source_width * max_height,
            source_height,
        ))),
        .height = maximum_stored_anchor_height,
    };
}

fn visualStorageBytes(metadata: VisualFrameMetadata) u64 {
    const extent = storedVisualExtent(metadata);
    return @as(u64, extent.width) * extent.height * 3 + 64;
}

/// Complete live semantic cohort including chassis plus four wheels for every
/// bounded vehicle. Keep aligned with the renderer semantic oracle ceiling.
pub const maximum_semantic_entries: usize = 128;

pub const SemanticMapEntry = struct {
    object_id: u32,
    entity: engine.gameplay_trace.EntityRef,
    color_rgb: [3]u8,
};

const Image = struct {
    anomaly_id: incident.AnomalyId,
    metadata: VisualFrameMetadata,
    pixels: ?[]u8,
    semantic_entries: [maximum_semantic_entries]SemanticMapEntry = undefined,
    semantic_entry_count: u8 = 0,
};

const Replay = struct {
    bytes: []u8,
};

const Marker = struct {
    anomaly_id: incident.AnomalyId,
    authority_tick: u64,
    presentation_frame: u64,
    wall_unix_ms: i64,
    monotonic_ns: u64,
    lifecycle_status: incident.AnomalyStatus,
    artifact_count: u16,
    artifact_failures: u16,
    human_anchor_mask: u8,
    product_flag_present: bool,
    semantic_id_present: bool,
    selected: ?engine.gameplay_trace.EntityRef,
    note: [incident.max_note_bytes]u8,
    note_len: u8,
};

const Job = union(enum) {
    line: Line,
    handoff: HandoffJob,
    image: Image,
    replay: Replay,
    marker: Marker,
    checkpoint,
    flush,
    pressure_probe,
    arm_writer_budget,
    shutdown,
};

const Queue = struct {
    mutex: std.atomic.Mutex = .unlocked,
    jobs: [writer_queue_capacity]Job = undefined,
    read_index: usize = 0,
    count: usize = 0,
    high_water: usize = 0,
    dropped: u64 = 0,
    stopped: bool = false,
    writer_ready: bool = false,
    writer_failed: bool = false,
    visual_budget_exhausted: bool = false,
    handoff_persisted: bool = false,
    bytes_written: u64 = 0,
    stream_bytes_written: u64 = 0,
    visual_bytes_written: u64 = 0,
    replay_bytes_written: u64 = 0,
    metadata_bytes_written: u64 = 0,
    visual_bytes_reserved: u64 = 0,
    visual_budget_bytes: u64 = visual_budget_bytes,
    visual_budget_rejections: u64 = 0,
    screenshot_misses: u64 = 0,
    screenshot_fence_failures: u64 = 0,
    replay_attached: bool = false,
    anomaly_count: u8 = 0,
    last_admitted_sequence: u64 = 0,
    last_durable_sequence: u64 = 0,
    last_written_sequence: u64 = 0,
    handoff_ready: bool = false,
    handoff: Handoff = undefined,

    fn reserveVisual(self: *Queue, amount: u64) bool {
        self.lock();
        defer self.unlock();
        if (amount > self.visual_budget_bytes or
            self.visual_bytes_reserved > self.visual_budget_bytes - amount)
        {
            self.visual_budget_exhausted = true;
            self.visual_budget_rejections +|= 1;
            return false;
        }
        self.visual_bytes_reserved += amount;
        return true;
    }

    fn releaseVisual(self: *Queue, amount: u64) void {
        self.lock();
        defer self.unlock();
        self.visual_bytes_reserved -|= amount;
    }

    fn publishHandoff(self: *Queue, bytes: []const u8) void {
        std.debug.assert(bytes.len <= incident.max_handoff_bytes);
        var handoff = Handoff{ .len = @intCast(bytes.len), .bytes = @splat(0) };
        @memcpy(handoff.bytes[0..bytes.len], bytes);
        self.lock();
        defer self.unlock();
        self.handoff = handoff;
        self.handoff_ready = true;
        self.handoff_persisted = false;
    }

    fn lock(self: *Queue) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlock(self: *Queue) void {
        self.mutex.unlock();
    }

    fn push(self: *Queue, job: Job) bool {
        self.lock();
        defer self.unlock();
        if (self.stopped or self.count == self.jobs.len) {
            self.dropped +|= 1;
            return false;
        }
        const index = (self.read_index + self.count) % self.jobs.len;
        self.jobs[index] = job;
        self.count += 1;
        self.high_water = @max(self.high_water, self.count);
        return true;
    }

    fn pop(self: *Queue) ?Job {
        self.lock();
        defer self.unlock();
        if (self.count == 0) return null;
        const job = self.jobs[self.read_index];
        self.read_index = (self.read_index + 1) % self.jobs.len;
        self.count -= 1;
        return job;
    }
};

const StreamFile = struct {
    stream: Stream,
    segment: u32 = 1,
    bytes: u64 = 0,
    opened_ns: u64 = 0,
    file: ?std.Io.File = null,

    fn close(self: *StreamFile, io: std.Io) void {
        if (self.file) |file| file.close(io);
        self.file = null;
    }
};

const Writer = struct {
    io: std.Io,
    queue: *Queue,
    run_path: []const u8,
    started_wall_unix_ms: i64,
    budget_bytes: u64 = run_budget_bytes,
    hardening_profile: HardeningProfile = .none,
    write_failure_after_bytes: ?u64 = null,
    streams: [5]StreamFile = .{
        .{ .stream = .timeline },
        .{ .stream = .state },
        .{ .stream = .input },
        .{ .stream = .metrics },
        .{ .stream = .anomalies },
    },
    last_flush_ns: u64 = 0,

    fn run(self: *Writer) void {
        self.writeManifest("running") catch {
            self.fail();
            self.queue.lock();
            self.queue.stopped = true;
            self.queue.unlock();
            return;
        };
        self.last_flush_ns = monotonicNowNs(self.io);
        self.setReady();
        while (true) {
            const job = self.queue.pop() orelse {
                const now = monotonicNowNs(self.io);
                if (now -| self.last_flush_ns >= std.time.ns_per_s) {
                    self.flushAll() catch self.fail();
                    self.writeManifest("running") catch self.fail();
                    self.last_flush_ns = now;
                }
                std.Io.sleep(self.io, .fromMilliseconds(10), .awake) catch {};
                continue;
            };
            switch (job) {
                .line => |line| self.writeLine(line) catch self.fail(),
                .handoff => |handoff| {
                    defer std.heap.page_allocator.free(handoff.bytes);
                    self.flushAll() catch self.fail();
                    self.writeManifest("running") catch self.fail();
                    self.writeHandoff(handoff.bytes) catch self.fail();
                    self.writeManifest("running") catch self.fail();
                },
                .image => |image| {
                    defer if (image.pixels) |pixels| std.heap.page_allocator.free(pixels);
                    self.writeImage(image) catch self.fail();
                },
                .replay => |replay| {
                    defer std.heap.page_allocator.free(replay.bytes);
                    self.writeReplay(replay.bytes) catch self.fail();
                },
                .marker => |marker| self.writeMarkerAndWindows(marker) catch self.fail(),
                .checkpoint => {
                    self.flushAll() catch self.fail();
                    self.writeManifest("running") catch self.fail();
                },
                .flush => self.flushAll() catch self.fail(),
                .pressure_probe => {},
                .arm_writer_budget => {
                    self.queue.lock();
                    self.write_failure_after_bytes = self.queue.bytes_written;
                    self.queue.unlock();
                },
                .shutdown => break,
            }
        }
        self.flushAll() catch self.fail();
        for (&self.streams) |*stream| stream.close(self.io);
        self.writeManifest(if (self.partial()) "partial" else "complete") catch self.fail();
        self.queue.lock();
        self.queue.stopped = true;
        self.queue.unlock();
    }

    fn fail(self: *Writer) void {
        self.queue.lock();
        self.queue.writer_failed = true;
        self.queue.unlock();
    }

    fn partial(self: *Writer) bool {
        self.queue.lock();
        defer self.queue.unlock();
        return self.queue.writer_failed or self.queue.dropped != 0 or
            self.queue.screenshot_misses != 0 or
            self.queue.visual_budget_exhausted;
    }

    fn setReady(self: *Writer) void {
        self.queue.lock();
        self.queue.writer_ready = true;
        self.queue.unlock();
    }

    fn streamFile(self: *Writer, stream: Stream) *StreamFile {
        return &self.streams[@intFromEnum(stream)];
    }

    fn ensureStreamFile(self: *Writer, value: *StreamFile, incoming: usize) !std.Io.File {
        const now = monotonicNowNs(self.io);
        if (value.file != null and (value.stream == .anomalies or
            (value.bytes + incoming <= stream_rotation_bytes and
                now -| value.opened_ns < 30 * std.time.ns_per_s)))
        {
            return value.file.?;
        }
        value.close(self.io);
        if (value.bytes != 0) value.segment += 1;
        value.bytes = 0;
        value.opened_ns = now;
        var path_buffer: [incident.max_path_bytes]u8 = undefined;
        const path = if (value.stream == .anomalies)
            try std.fmt.bufPrint(&path_buffer, "{s}/anomalies.ndjson", .{self.run_path})
        else
            try std.fmt.bufPrint(
                &path_buffer,
                "{s}/streams/{s}-{d:0>6}.ndjson",
                .{ self.run_path, @tagName(value.stream), value.segment },
            );
        value.file = try std.Io.Dir.cwd().createFile(self.io, path, .{
            .exclusive = true,
            .permissions = std.Io.File.Permissions.fromMode(0o600),
        });
        return value.file.?;
    }

    fn writeLine(self: *Writer, line: Line) !void {
        try self.ensureBudget(line.len + 1);
        const stream = self.streamFile(line.stream);
        const file = try self.ensureStreamFile(stream, line.len + 1);
        try file.writeStreamingAll(self.io, line.slice());
        try file.writeStreamingAll(self.io, "\n");
        stream.bytes += line.len + 1;
        self.queue.lock();
        self.queue.last_written_sequence = @max(
            self.queue.last_written_sequence,
            line.sequence,
        );
        self.queue.unlock();
        self.noteBytes(.stream, line.len + 1);
    }

    fn writeHandoff(self: *Writer, bytes: []const u8) !void {
        try self.ensureBudget(bytes.len);
        var path_buffer: [incident.max_path_bytes]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, "{s}/LLM_HANDOFF.md", .{self.run_path});
        var atomic = try std.Io.Dir.cwd().createFileAtomic(self.io, path, .{
            .replace = true,
            .permissions = std.Io.File.Permissions.fromMode(0o600),
        });
        defer atomic.deinit(self.io);
        try atomic.file.writeStreamingAll(self.io, bytes);
        try atomic.file.sync(self.io);
        try atomic.replace(self.io);
        self.noteBytes(.metadata, bytes.len);
        self.queue.lock();
        self.queue.handoff_persisted = true;
        self.queue.unlock();
    }

    fn writeReplay(self: *Writer, bytes: []const u8) !void {
        try self.ensureBudget(bytes.len);
        var path_buffer: [incident.max_path_bytes]u8 = undefined;
        const path = try std.fmt.bufPrint(
            &path_buffer,
            "{s}/replay/accepted-ingress.icrp",
            .{self.run_path},
        );
        var atomic = try std.Io.Dir.cwd().createFileAtomic(self.io, path, .{
            .replace = true,
            .permissions = std.Io.File.Permissions.fromMode(0o600),
        });
        defer atomic.deinit(self.io);
        try atomic.file.writeStreamingAll(self.io, bytes);
        try atomic.file.sync(self.io);
        try atomic.replace(self.io);
        self.noteBytes(.replay, bytes.len);
        self.queue.lock();
        self.queue.replay_attached = true;
        self.queue.unlock();
    }

    fn writeMarkerAndWindows(self: *Writer, marker: Marker) !void {
        try self.flushAll();
        var directory_buffer: [incident.max_path_bytes]u8 = undefined;
        const directory = try std.fmt.bufPrint(
            &directory_buffer,
            "{s}/anomalies/anomaly-{d:0>4}",
            .{ self.run_path, marker.anomaly_id },
        );
        _ = try std.Io.Dir.createDirPathStatus(
            .cwd(),
            self.io,
            directory,
            std.Io.Dir.Permissions.fromMode(0o700),
        );
        var path_buffer: [incident.max_path_bytes]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, "{s}/marker.json", .{directory});
        var selected_buffer: [128]u8 = undefined;
        const selected = entityJson(&selected_buffer, marker.selected);
        var escaped_note_buffer: [incident.max_note_bytes * 2]u8 = undefined;
        const note = escapeJson(
            &escaped_note_buffer,
            marker.note[0..@min(@as(usize, marker.note_len), marker.note.len)],
        );
        var buffer: [1536]u8 = undefined;
        const json = try std.fmt.bufPrint(
            &buffer,
            "{{\"schema\":{d},\"kind\":\"incident_marker\",\"anomaly_id\":{d},\"lifecycle_status\":\"{s}\",\"authority_tick\":{d},\"presentation_frame\":{d},\"wall_unix_ms\":{d},\"flag_monotonic_ns\":{d},\"window_start_ns\":{d},\"window_end_ns\":{d},\"artifacts\":{{\"count\":{d},\"failures\":{d},\"human_m5000ms\":{},\"human_m4000ms\":{},\"human_m3000ms\":{},\"human_m2000ms\":{},\"human_m1000ms\":{},\"human_flag\":{},\"human_p1000ms\":{},\"human_p2000ms\":{},\"product_flag\":{},\"semantic_id_flag\":{}}},\"selected_entity\":{s},\"semantic_id_status\":\"{s}\",\"note\":\"{s}\"}}\n",
            .{ incident.schema_version, marker.anomaly_id, @tagName(marker.lifecycle_status), marker.authority_tick, marker.presentation_frame, marker.wall_unix_ms, marker.monotonic_ns, marker.monotonic_ns -| pre_roll_ns, marker.monotonic_ns +| post_roll_ns, marker.artifact_count, marker.artifact_failures, marker.human_anchor_mask & 1 != 0, marker.human_anchor_mask & 2 != 0, marker.human_anchor_mask & 4 != 0, marker.human_anchor_mask & 8 != 0, marker.human_anchor_mask & 16 != 0, marker.human_anchor_mask & 32 != 0, marker.human_anchor_mask & 64 != 0, marker.human_anchor_mask & 128 != 0, marker.product_flag_present, marker.semantic_id_present, selected, if (marker.semantic_id_present) "available" else "missing", note },
        );
        try self.ensureBudget(json.len);
        var atomic = try std.Io.Dir.cwd().createFileAtomic(self.io, path, .{
            .replace = true,
            .permissions = std.Io.File.Permissions.fromMode(0o600),
        });
        defer atomic.deinit(self.io);
        try atomic.file.writeStreamingAll(self.io, json);
        try atomic.file.sync(self.io);
        try atomic.replace(self.io);
        self.noteBytes(.metadata, json.len);
        inline for ([_]Stream{ .timeline, .state, .input, .metrics }) |stream| {
            try self.writeStreamWindow(
                directory,
                stream,
                marker.monotonic_ns -| pre_roll_ns,
                marker.monotonic_ns +| post_roll_ns,
            );
        }
    }

    fn writeStreamWindow(
        self: *Writer,
        anomaly_directory: []const u8,
        stream: Stream,
        start_ns: u64,
        end_ns: u64,
    ) !void {
        var streams_path_buffer: [incident.max_path_bytes]u8 = undefined;
        const streams_path = try std.fmt.bufPrint(&streams_path_buffer, "{s}/streams", .{self.run_path});
        var output_path_buffer: [incident.max_path_bytes]u8 = undefined;
        const output_path = try std.fmt.bufPrint(
            &output_path_buffer,
            "{s}/{s}-window.ndjson",
            .{ anomaly_directory, @tagName(stream) },
        );
        var output = try std.Io.Dir.cwd().createFileAtomic(self.io, output_path, .{
            .replace = true,
            .permissions = std.Io.File.Permissions.fromMode(0o600),
        });
        defer output.deinit(self.io);
        var streams = try std.Io.Dir.cwd().openDir(self.io, streams_path, .{ .iterate = true });
        defer streams.close(self.io);
        var walker = try streams.walk(std.heap.page_allocator);
        defer walker.deinit();
        var segment_paths = try std.ArrayList([]u8).initCapacity(
            std.heap.page_allocator,
            4,
        );
        defer {
            for (segment_paths.items) |segment_path| {
                std.heap.page_allocator.free(segment_path);
            }
            segment_paths.deinit(std.heap.page_allocator);
        }
        while (try walker.next(self.io)) |entry| {
            if (entry.kind != .file or !std.mem.startsWith(u8, entry.path, @tagName(stream)) or
                !std.mem.endsWith(u8, entry.path, ".ndjson")) continue;
            try segment_paths.append(
                std.heap.page_allocator,
                try std.heap.page_allocator.dupe(u8, entry.path),
            );
        }
        std.mem.sort([]u8, segment_paths.items, {}, struct {
            fn lessThan(_: void, left: []u8, right: []u8) bool {
                return std.mem.lessThan(u8, left, right);
            }
        }.lessThan);
        for (segment_paths.items) |segment_path| {
            const source_path = try std.fs.path.join(
                std.heap.page_allocator,
                &.{ streams_path, segment_path },
            );
            defer std.heap.page_allocator.free(source_path);
            const bytes = try std.Io.Dir.cwd().readFileAlloc(
                self.io,
                source_path,
                std.heap.page_allocator,
                .limited(stream_rotation_bytes + max_line_bytes),
            );
            defer std.heap.page_allocator.free(bytes);
            var lines = std.mem.splitScalar(u8, bytes, '\n');
            while (lines.next()) |line| {
                if (line.len == 0) continue;
                const timestamp = jsonU64(line, "\"monotonic_ns\":") orelse continue;
                if (timestamp < start_ns or timestamp > end_ns) continue;
                try self.ensureBudget(line.len + 1);
                try output.file.writeStreamingAll(self.io, line);
                try output.file.writeStreamingAll(self.io, "\n");
                self.noteBytes(.metadata, line.len + 1);
            }
        }
        try output.file.sync(self.io);
        try output.replace(self.io);
    }

    fn writeImage(self: *Writer, image: Image) !void {
        var anomaly_directory_buffer: [incident.max_path_bytes]u8 = undefined;
        const anomaly_directory = try std.fmt.bufPrint(
            &anomaly_directory_buffer,
            "{s}/anomalies/anomaly-{d:0>4}",
            .{ self.run_path, image.anomaly_id },
        );
        _ = try std.Io.Dir.createDirPathStatus(
            .cwd(),
            self.io,
            anomaly_directory,
            std.Io.Dir.Permissions.fromMode(0o700),
        );

        var relative_buffer: [incident.max_path_bytes]u8 = undefined;
        const relative_path = switch (image.metadata.source) {
            .product_trail => try std.fmt.bufPrint(
                &relative_buffer,
                "visual/frame-{d:0>8}_{d:0>8}.ppm",
                .{ image.metadata.capture_sequence, image.metadata.presentation_frame },
            ),
            .human_visible => try std.fmt.bufPrint(
                &relative_buffer,
                "anomalies/anomaly-{d:0>4}/screenshot-human-{s}.ppm",
                .{ image.anomaly_id, visualOffsetLabel(image.metadata.requested_offset_ms orelse 0) },
            ),
            .product_flag => try std.fmt.bufPrint(
                &relative_buffer,
                "anomalies/anomaly-{d:0>4}/screenshot-product-flag.ppm",
                .{image.anomaly_id},
            ),
            .semantic_id => try std.fmt.bufPrint(
                &relative_buffer,
                "anomalies/anomaly-{d:0>4}/semantic-id-flag.ppm",
                .{image.anomaly_id},
            ),
        };
        const stored_extent = storedVisualExtent(image.metadata);
        if (image.pixels) |pixels| {
            const visual_bytes = @as(usize, stored_extent.width) * stored_extent.height * 3 + 64;
            try self.ensureBudget(visual_bytes);
            var absolute_buffer: [incident.max_path_bytes]u8 = undefined;
            const absolute_path = try std.fmt.bufPrint(
                &absolute_buffer,
                "{s}/{s}",
                .{ self.run_path, relative_path },
            );
            const file = try std.Io.Dir.cwd().createFile(self.io, absolute_path, .{
                .exclusive = true,
                .permissions = std.Io.File.Permissions.fromMode(0o600),
            });
            defer file.close(self.io);
            var header: [64]u8 = undefined;
            const header_text = try std.fmt.bufPrint(
                &header,
                "P6\n{d} {d}\n255\n",
                .{ stored_extent.width, stored_extent.height },
            );
            try file.writeStreamingAll(self.io, header_text);
            var row: [4096 * 3]u8 = undefined;
            if (stored_extent.width > 4096) return error.ImageWidthUnsupported;
            for (0..stored_extent.height) |y| {
                const source_y = @divFloor(
                    @as(usize, y) * image.metadata.height,
                    stored_extent.height,
                );
                for (0..stored_extent.width) |x| {
                    const source_x = @divFloor(
                        @as(usize, x) * image.metadata.width,
                        stored_extent.width,
                    );
                    const source = (source_y * image.metadata.width + source_x) * 4;
                    const destination = x * 3;
                    const red_offset: usize = if (image.metadata.bgra) 2 else 0;
                    const blue_offset: usize = if (image.metadata.bgra) 0 else 2;
                    row[destination + 0] = pixels[source + red_offset];
                    row[destination + 1] = pixels[source + 1];
                    row[destination + 2] = pixels[source + blue_offset];
                }
                try file.writeStreamingAll(self.io, row[0 .. stored_extent.width * 3]);
            }
            try file.sync(self.io);
            self.noteBytes(
                .visual,
                header_text.len + @as(usize, stored_extent.width) * stored_extent.height * 3,
            );
        }

        var index_path_buffer: [incident.max_path_bytes]u8 = undefined;
        const index_path = try std.fmt.bufPrint(
            &index_path_buffer,
            "{s}/visual-index.ndjson",
            .{anomaly_directory},
        );
        var index_line_buffer: [2048]u8 = undefined;
        const actual_delta_ms = signedDeltaMs(
            image.metadata.captured_monotonic_ns,
            image.metadata.flag_monotonic_ns,
        );
        const index_line = try std.fmt.bufPrint(
            &index_line_buffer,
            "{{\"schema\":{d},\"kind\":\"visual_frame\",\"anomaly_id\":{d},\"capture_sequence\":{d},\"source\":\"{s}\",\"requested_offset_ms\":{?d},\"target_monotonic_ns\":{d},\"captured_monotonic_ns\":{d},\"actual_offset_ms\":{d},\"submitted_monotonic_ns\":{d},\"completed_monotonic_ns\":{d},\"writer_observed_monotonic_ns\":{d},\"authority_tick\":{d},\"presentation_frame\":{d},\"drawable_generation\":{d},\"source_width\":{d},\"source_height\":{d},\"width\":{d},\"height\":{d},\"pixel_format\":\"{s}\",\"fence_latency_ns\":{d},\"pixel_digest\":\"{x:0>16}\",\"suspicious\":{},\"path\":\"{s}\"}}\n",
            .{ incident.schema_version, image.anomaly_id, image.metadata.capture_sequence, @tagName(image.metadata.source), image.metadata.requested_offset_ms, image.metadata.target_monotonic_ns, image.metadata.captured_monotonic_ns, actual_delta_ms, image.metadata.submitted_monotonic_ns, image.metadata.completed_monotonic_ns, monotonicNowNs(self.io), image.metadata.authority_tick, image.metadata.presentation_frame, image.metadata.drawable_generation, image.metadata.width, image.metadata.height, stored_extent.width, stored_extent.height, if (image.metadata.bgra) "bgra8" else "rgba8", image.metadata.fence_latency_ns, image.metadata.pixel_digest, image.metadata.suspicious, relative_path },
        );
        try self.ensureBudget(index_line.len);
        const index_file = try std.Io.Dir.cwd().createFile(self.io, index_path, .{
            .truncate = false,
            .permissions = std.Io.File.Permissions.fromMode(0o600),
        });
        defer index_file.close(self.io);
        const end = try index_file.length(self.io);
        try index_file.writePositionalAll(self.io, index_line, end);
        try index_file.sync(self.io);
        self.noteBytes(.metadata, index_line.len);
        if (image.metadata.source == .semantic_id) try self.writeSemanticMap(image);
    }

    fn writeSemanticMap(self: *Writer, image: Image) !void {
        if (image.semantic_entry_count == 0) return error.EmptySemanticMap;
        var path_buffer: [incident.max_path_bytes]u8 = undefined;
        const path = try std.fmt.bufPrint(
            &path_buffer,
            "{s}/anomalies/anomaly-{d:0>4}/semantic-id-map.json",
            .{ self.run_path, image.anomaly_id },
        );
        var json_buffer: [32 * 1024]u8 = undefined;
        var writer = std.Io.Writer.fixed(&json_buffer);
        try writer.print(
            "{{\"schema\":{d},\"kind\":\"semantic_id_map\",\"anomaly_id\":{d},\"capture_sequence\":{d},\"width\":{d},\"height\":{d},\"entries\":[",
            .{ incident.schema_version, image.anomaly_id, image.metadata.capture_sequence, image.metadata.width, image.metadata.height },
        );
        for (image.semantic_entries[0..image.semantic_entry_count], 0..) |entry, index| {
            if (index != 0) try writer.writeAll(",");
            try writer.print(
                "{{\"object_id\":{d},\"entity\":{{\"namespace\":{d},\"local\":{d},\"incarnation\":{d}}},\"color_rgb\":[{d},{d},{d}]}}",
                .{ entry.object_id, entry.entity.namespace, entry.entity.local, entry.entity.incarnation, entry.color_rgb[0], entry.color_rgb[1], entry.color_rgb[2] },
            );
        }
        try writer.writeAll("]}\n");
        const json = json_buffer[0..writer.end];
        try self.ensureBudget(json.len);
        var atomic = try std.Io.Dir.cwd().createFileAtomic(self.io, path, .{
            .replace = true,
            .permissions = std.Io.File.Permissions.fromMode(0o600),
        });
        defer atomic.deinit(self.io);
        try atomic.file.writeStreamingAll(self.io, json);
        try atomic.file.sync(self.io);
        try atomic.replace(self.io);
        self.noteBytes(.metadata, json.len);
    }

    fn writeManifest(self: *Writer, status: []const u8) !void {
        var path_buffer: [incident.max_path_bytes]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, "{s}/manifest.json", .{self.run_path});
        var manifest_buffer: [4096]u8 = undefined;
        self.queue.lock();
        const dropped = self.queue.dropped;
        const bytes = self.queue.bytes_written;
        const high_water = self.queue.high_water;
        const queued = self.queue.count;
        const writer_failed = self.queue.writer_failed;
        const last_admitted = self.queue.last_admitted_sequence;
        const last_durable = self.queue.last_durable_sequence;
        const stream_bytes = self.queue.stream_bytes_written;
        const visual_bytes = self.queue.visual_bytes_written;
        const replay_bytes = self.queue.replay_bytes_written;
        const metadata_bytes = self.queue.metadata_bytes_written;
        const visual_reserved = self.queue.visual_bytes_reserved;
        const configured_visual_budget = self.queue.visual_budget_bytes;
        const visual_exhausted = self.queue.visual_budget_exhausted;
        const visual_rejections = self.queue.visual_budget_rejections;
        const handoff_persisted = self.queue.handoff_persisted;
        const screenshot_misses = self.queue.screenshot_misses;
        const screenshot_fence_failures = self.queue.screenshot_fence_failures;
        const replay_attached = self.queue.replay_attached;
        const anomaly_count = self.queue.anomaly_count;
        self.queue.unlock();
        var manifest_writer = std.Io.Writer.fixed(&manifest_buffer);
        try manifest_writer.print(
            "{{\"schema\":{d},\"kind\":\"incinerator_incident_run\",\"status\":\"{s}\",\"platform\":\"macos-aarch64\",\"topology\":\"solo\",\"source_revision\":\"{s}\",\"source_dirty\":{},\"source_dirty_fingerprint\":\"{s}\",\"zig_version\":\"{s}\",\"optimize\":\"{s}\",\"cohorts\":{{\"sdl\":\"3.4.14\",\"jolt\":\"5.5.0\",\"protocol\":{d},\"replay\":{d},\"snapshot\":{d}}},\"evidence_capabilities\":{{\"characters\":\"full_boundary\",\"npcs\":\"full_boundary\",\"vehicles\":\"full_boundary\",\"carryables\":\"full_boundary\",\"semantic_vehicle_parts\":true,\"atomic_note_handoff\":true,\"navigation_lineage\":true,\"population_activity\":true,\"deterministic_render_state\":true,\"ranged_combat\":true,\"authored_changes\":true}},\"hardening_profile\":\"{s}\",\"hardening_write_failure_after_bytes\":{?d},\"started_wall_unix_ms\":{d},\"updated_wall_unix_ms\":{d},\"updated_monotonic_ns\":{d},\"stream_rotation_bytes\":{d},\"run_budget_bytes\":{d},\"visual_budget_bytes\":{d},\"non_visual_reserve_bytes\":{d},\"visual_bytes_reserved\":{d},\"visual_budget_exhausted\":{},\"visual_budget_rejections\":{d},",
            .{ incident.schema_version, status, build_options.source_revision, build_options.source_dirty, build_options.source_dirty_fingerprint, builtin.zig_version_string, @tagName(builtin.mode), manifest_protocol_cohort, sandbox_replay.schema_cohort, manifest_snapshot_cohort, @tagName(self.hardening_profile), self.write_failure_after_bytes, self.started_wall_unix_ms, @divFloor(wallNowNs(self.io), std.time.ns_per_ms), monotonicNowNs(self.io), stream_rotation_bytes, self.budget_bytes, configured_visual_budget, self.budget_bytes - configured_visual_budget, visual_reserved, visual_exhausted, visual_rejections },
        );
        try manifest_writer.print(
            "\"writer_queue_capacity\":{d},\"writer_queue\":{d},\"queue_high_water\":{d},\"dropped_records\":{d},\"writer_failed\":{},\"handoff_persisted\":{},\"last_admitted_sequence\":{d},\"last_durable_sequence\":{d},\"bytes_written\":{d},\"bytes_by_class\":{{\"streams\":{d},\"visual\":{d},\"replay\":{d},\"metadata\":{d}}},\"screenshot_misses\":{d},\"screenshot_fence_failures\":{d},\"anomaly_count\":{d},\"replay_status\":\"{s}\",\"screenshot_format\":\"ppm-p6\",\"privacy\":{{\"local_only\":true,\"captures_text_input\":false,\"captures_credentials\":false,\"captures_reserved_shortcut_candidates\":true}}}}\n",
            .{ writer_queue_capacity, queued, high_water, dropped, writer_failed, handoff_persisted, last_admitted, last_durable, bytes, stream_bytes, visual_bytes, replay_bytes, metadata_bytes, screenshot_misses, screenshot_fence_failures, anomaly_count, if (replay_attached) "attached" else "not_attached" },
        );
        const manifest = manifest_buffer[0..manifest_writer.end];
        var atomic = try std.Io.Dir.cwd().createFileAtomic(self.io, path, .{
            .replace = true,
            .permissions = std.Io.File.Permissions.fromMode(0o600),
        });
        defer atomic.deinit(self.io);
        try atomic.file.writeStreamingAll(self.io, manifest);
        try atomic.file.sync(self.io);
        try atomic.replace(self.io);
    }

    fn flushAll(self: *Writer) !void {
        for (&self.streams) |*stream| if (stream.file) |file| try file.sync(self.io);
        self.queue.lock();
        self.queue.last_durable_sequence = self.queue.last_written_sequence;
        self.queue.unlock();
    }

    fn noteBytes(self: *Writer, class: ByteClass, amount: usize) void {
        self.queue.lock();
        self.queue.bytes_written +|= amount;
        switch (class) {
            .stream => self.queue.stream_bytes_written +|= amount,
            .visual => self.queue.visual_bytes_written +|= amount,
            .replay => self.queue.replay_bytes_written +|= amount,
            .metadata => self.queue.metadata_bytes_written +|= amount,
        }
        if (self.queue.bytes_written > self.budget_bytes) self.queue.writer_failed = true;
        self.queue.unlock();
    }

    fn ensureBudget(self: *Writer, amount: usize) !void {
        self.queue.lock();
        defer self.queue.unlock();
        if (self.write_failure_after_bytes) |limit| {
            if (amount > limit or
                self.queue.bytes_written > limit - @as(u64, @intCast(amount)))
            {
                self.queue.writer_failed = true;
                return error.IncidentInjectedWriterBudgetExceeded;
            }
        }
        if (amount > self.budget_bytes or
            self.queue.bytes_written > self.budget_bytes - @as(u64, @intCast(amount)))
        {
            self.queue.writer_failed = true;
            return error.IncidentRunBudgetExceeded;
        }
    }
};

const ActiveAnomaly = struct {
    view: incident.AnomalyView,
    monotonic_ns: u64,
    post_roll_deadline_ns: u64,
    selected: ?engine.gameplay_trace.EntityRef,
    human_anchor_mask: u8 = 0,
    product_flag_present: bool = false,
    semantic_id_present: bool = false,
};

const AuthoredChangeKey = struct {
    run_started_wall_unix_ms: i64,
    run_nonce: u64,
    transaction_id: engine.authoring.TransactionId,
};

pub const Capture = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    queue: Queue = .{},
    writer: Writer,
    thread: ?std.Thread = null,
    run_path: [incident.max_path_bytes]u8 = @splat(0),
    run_path_len: u16 = 0,
    next_sequence: u64 = 1,
    next_anomaly_id: incident.AnomalyId = 1,
    anomalies: [incident.max_anomalies]ActiveAnomaly = undefined,
    anomaly_count: u8 = 0,
    last_gameplay_sequence: u64 = 0,
    last_diagnostic_sequence: u64 = 0,
    runtime_fault_recorded: bool = false,
    authority_cycle_fault_recorded: bool = false,
    last_authored_change: ?AuthoredChangeKey = null,
    last_state_sample_ns: u64 = 0,
    last_input_sample_ns: u64 = 0,
    last_metrics_sample_ns: u64 = 0,
    last_input: incident.InputSample = .{},
    status: [incident.max_status_bytes]u8 = @splat(0),
    status_len: u8 = 0,
    screenshot_misses: u64 = 0,
    last_screenshot_metrics_ns: u64 = 0,
    handoff_pending_post_roll: bool = false,
    writer_budget_armed: bool = false,
    shortcuts: incident.ShortcutView = .{},

    pub fn create(
        allocator: std.mem.Allocator,
        io: std.Io,
        runs_root: []const u8,
    ) !*Capture {
        const result = try allocator.create(Capture);
        errdefer allocator.destroy(result);
        result.* = .{
            .allocator = allocator,
            .io = io,
            .writer = undefined,
        };
        _ = try std.Io.Dir.createDirPathStatus(
            .cwd(),
            io,
            runs_root,
            std.Io.Dir.Permissions.fromMode(0o700),
        );
        applyRetention(io, allocator, runs_root) catch {};
        const wall_ns = wallNowNs(io);
        const suffix = std.hash.Wyhash.hash(@intCast(wall_ns), std.mem.asBytes(&wall_ns));
        const timestamp = utcFilename(wall_ns);
        const path = try std.fmt.bufPrint(
            &result.run_path,
            "{s}/{s}_solo_{x:0>8}",
            .{ runs_root, timestamp.slice(), @as(u32, @truncate(suffix)) },
        );
        result.run_path_len = @intCast(path.len);
        try std.Io.Dir.cwd().createDir(
            io,
            result.runPath(),
            std.Io.Dir.Permissions.fromMode(0o700),
        );
        for ([_][]const u8{ "streams", "anomalies", "visual", "replay" }) |child| {
            var child_buffer: [incident.max_path_bytes]u8 = undefined;
            const child_path = try std.fmt.bufPrint(&child_buffer, "{s}/{s}", .{ result.runPath(), child });
            _ = try std.Io.Dir.createDirPathStatus(
                .cwd(),
                io,
                child_path,
                std.Io.Dir.Permissions.fromMode(0o700),
            );
        }
        result.writer = .{
            .io = io,
            .queue = &result.queue,
            .run_path = result.runPath(),
            .started_wall_unix_ms = @intCast(@divFloor(wall_ns, std.time.ns_per_ms)),
        };
        // `Capture` must be moved to its final address before start() so the
        // writer's internal pointers remain stable.
        return result;
    }

    pub fn start(self: *Capture) !void {
        self.writer.queue = &self.queue;
        self.writer.run_path = self.runPath();
        self.thread = try std.Thread.spawn(.{}, Writer.run, .{&self.writer});
        self.setStatus("Incident recording active (Cmd+Option+I; F9 optional)");
    }

    /// Configure one explicit IC5-G profile before the writer starts. This is
    /// a required pre-start operation so ordinary live capture cannot mutate
    /// its evidence contract mid-run.
    pub fn configureHardening(
        self: *Capture,
        profile: HardeningProfile,
    ) void {
        std.debug.assert(self.thread == null);
        self.writer.hardening_profile = profile;
        switch (profile) {
            .visual_budget => self.queue.visual_budget_bytes = hardening_visual_budget_bytes,
            else => {},
        }
    }

    /// Fill the pre-start queue and reject one additional probe. Starting the
    /// writer then proves bounded recovery without scheduling races or sleeps.
    pub fn injectQueuePressure(self: *Capture) void {
        std.debug.assert(self.thread == null);
        for (0..writer_queue_capacity) |_| {
            std.debug.assert(self.queue.push(.pressure_probe));
        }
        std.debug.assert(!self.queue.push(.pressure_probe));
    }

    pub fn deinit(self: *Capture) void {
        if (self.thread != null) {
            for (self.anomalies[0..self.anomaly_count]) |*anomaly| {
                if (anomaly.view.status != .capturing) continue;
                anomaly.view.status = .partial;
                self.recordAnomalyIndex(
                    anomaly.view.id,
                    anomaly.view.authority_tick,
                    anomaly.view.presentation_frame,
                    anomaly.view.wall_unix_ms,
                    "post_roll_finalized",
                    .partial,
                    anomaly.view.noteSlice(),
                );
                self.queueMarker(anomaly);
            }
            if (self.handoff_pending_post_roll) {
                self.handoff_pending_post_roll = false;
                _ = self.enqueueHandoff();
            }
            while (true) {
                self.queue.lock();
                const stopped = self.queue.stopped;
                self.queue.unlock();
                if (stopped or self.queue.push(.shutdown)) break;
                std.Io.sleep(self.io, .fromMilliseconds(1), .awake) catch {};
            }
            self.thread.?.join();
            self.thread = null;
        }
        // Jobs with owned payloads can remain only if thread creation failed.
        while (self.queue.pop()) |job| switch (job) {
            .image => |image| if (image.pixels) |pixels| std.heap.page_allocator.free(pixels),
            .replay => |replay| std.heap.page_allocator.free(replay.bytes),
            else => {},
        };
        self.* = undefined;
    }

    pub fn destroy(self: *Capture) void {
        const allocator = self.allocator;
        self.deinit();
        allocator.destroy(self);
    }

    pub fn runPath(self: *const Capture) []const u8 {
        return self.run_path[0..self.run_path_len];
    }

    pub fn nowNs(self: *const Capture) u64 {
        return monotonicNowNs(self.io);
    }

    pub fn anomalyFlagNs(self: *Capture, id: incident.AnomalyId) ?u64 {
        return (self.findAnomaly(id) orelse return null).monotonic_ns;
    }

    pub fn observe(
        self: *Capture,
        gameplay: engine.gameplay_trace.BorrowedView,
        diagnostics: engine.runtime.DiagnosticJournal.BorrowedView,
        runtime_fault: ?engine.runtime.RuntimeFault,
        authority_cycle_fault: ?authority_diagnostics.CycleFault,
        view: *const editor_contract.GameplayView,
        render_view: *const editor_contract.RenderView,
        input_sample: incident.InputSample,
        camera_yaw: f32,
        camera_pitch: f32,
        frame_time_ms: f32,
        authored_change: ?sandbox_authoring.ChangeEvidence,
    ) void {
        const now = monotonicNowNs(self.io);
        self.drainGameplay(gameplay, now);
        self.drainDiagnostics(diagnostics, now);
        self.recordRetainedFaults(runtime_fault, authority_cycle_fault, now);
        if (authored_change) |change| self.recordAuthoredChange(change, now);
        if (now -| self.last_state_sample_ns >= 250 * std.time.ns_per_ms) {
            self.last_state_sample_ns = now;
            self.recordState(view, camera_yaw, camera_pitch, now);
            self.recordRenderState(view, render_view, now);
        }
        if (!std.meta.eql(input_sample, self.last_input) or
            now -| self.last_input_sample_ns >= std.time.ns_per_s)
        {
            self.last_input_sample_ns = now;
            self.last_input = input_sample;
            self.recordInput(view, input_sample, now);
        }
        if (now -| self.last_metrics_sample_ns >= std.time.ns_per_s) {
            self.last_metrics_sample_ns = now;
            self.recordMetrics(view, frame_time_ms, now);
        }
        self.finishPostRoll(now);
    }

    fn recordAuthoredChange(
        self: *Capture,
        evidence: sandbox_authoring.ChangeEvidence,
        now: u64,
    ) void {
        const change = evidence.record;
        const key = AuthoredChangeKey{
            .run_started_wall_unix_ms = change.run_id.started_wall_unix_ms,
            .run_nonce = change.run_id.nonce,
            .transaction_id = change.request.transaction_id,
        };
        if (self.last_authored_change) |last| {
            if (std.meta.eql(last, key)) return;
        }

        var target_namespace: u64 = 0;
        var target_local: u64 = 0;
        var member_namespace: u64 = 0;
        var member_local: u64 = 0;
        const target_kind: []const u8 = switch (change.request.target) {
            .persistent_entity => |id| target: {
                target_namespace = id.namespace;
                target_local = id.local;
                break :target "persistent_entity";
            },
            .asset => |id| target: {
                target_namespace = id.namespace;
                target_local = id.local;
                break :target "asset";
            },
            .asset_member => |member| target: {
                target_namespace = member.asset.namespace;
                target_local = member.asset.local;
                member_namespace = member.member.namespace;
                member_local = member.member.local;
                break :target "asset_member";
            },
        };

        var rejection_kind: []const u8 = "none";
        var rejection_name: []const u8 = "";
        var owner_rejection_domain: u32 = 0;
        var owner_rejection_code: u32 = 0;
        if (change.rejection) |rejection| switch (rejection) {
            .common => |common| {
                rejection_kind = "common";
                rejection_name = @tagName(common);
            },
            .owner => |owner| {
                rejection_kind = "owner";
                owner_rejection_domain = owner.domain;
                owner_rejection_code = owner.code;
            },
        };

        var durable_namespace: u64 = 0;
        var durable_local: u64 = 0;
        var durable_digest: [64]u8 = @splat(0);
        var durable_digest_len: usize = 0;
        if (change.durable_commit) |commit| {
            durable_namespace = commit.asset.namespace;
            durable_local = commit.asset.local;
            durable_digest = std.fmt.bytesToHex(commit.digest, .lower);
            durable_digest_len = durable_digest.len;
        }
        const before_digest = if (change.values.before) |digest|
            std.fmt.bytesToHex(digest, .lower)
        else
            [_]u8{0} ** 64;
        const requested_digest = if (change.values.requested) |digest|
            std.fmt.bytesToHex(digest, .lower)
        else
            [_]u8{0} ** 64;
        const committed_digest = if (change.values.committed) |digest|
            std.fmt.bytesToHex(digest, .lower)
        else
            [_]u8{0} ** 64;

        var requested_linear: [3]f32 = .{ 0, 0, 0 };
        var requested_angular: [3]f32 = .{ 0, 0, 0 };
        const requested_velocity_kind: []const u8 = switch (evidence.requested.velocity) {
            .preserve => "preserve",
            .zero => "zero",
            .exact => |velocity| exact: {
                requested_linear = velocity.linear;
                requested_angular = velocity.angular;
                break :exact "exact";
            },
        };
        const before = evidence.before orelse engine.physics.BodyState{};
        const committed = evidence.committed orelse engine.physics.BodyState{};

        const sequence = self.takeSequence();
        var line_buffer: [max_line_bytes]u8 = undefined;
        var writer = std.Io.Writer.fixed(&line_buffer);
        writer.print(
            "{{\"schema\":{d},\"kind\":\"authored_change\",\"recorder_sequence\":{d}," ++
                "\"monotonic_ns\":{d},\"run_started_wall_unix_ms\":{d},\"run_nonce\":{d}," ++
                "\"wall_unix_ms\":{d},\"authority_tick\":{?d},\"presentation_frame\":{?d}," ++
                "\"transaction_id\":{d},\"source\":\"{s}\",\"scope\":\"{s}\"," ++
                "\"target_kind\":\"{s}\",\"target_namespace\":{d},\"target_local\":{d}," ++
                "\"member_namespace\":{d},\"member_local\":{d}," ++
                "\"expected_revision\":{d},\"committed_revision\":{?d}," ++
                "\"disposition\":\"{s}\",\"rejection_kind\":\"{s}\"," ++
                "\"rejection\":\"{s}\",\"owner_rejection_domain\":{d}," ++
                "\"owner_rejection_code\":{d},\"operation\":\"{s}\"," ++
                "\"owner_rejection\":\"{s}\",\"actual_revision\":{?d},",
            .{
                incident.schema_version,
                sequence,
                now,
                change.run_id.started_wall_unix_ms,
                change.run_id.nonce,
                change.wall_unix_ms,
                change.authority_tick,
                change.presentation_frame,
                change.request.transaction_id,
                @tagName(change.request.source),
                @tagName(change.request.scope),
                target_kind,
                target_namespace,
                target_local,
                member_namespace,
                member_local,
                change.request.expected_revision,
                change.committed_revision,
                @tagName(change.disposition),
                rejection_kind,
                rejection_name,
                owner_rejection_domain,
                owner_rejection_code,
                @tagName(evidence.operation),
                if (evidence.owner_rejection) |reason| @tagName(reason) else "",
                evidence.actual_revision,
            },
        ) catch {
            self.noteDropped();
            return;
        };
        writer.print(
            "\"requested_pose\":[{d},{d},{d},{d},{d},{d},{d}]," ++
                "\"requested_velocity_kind\":\"{s}\",\"requested_linear_velocity\":[{d},{d},{d}]," ++
                "\"requested_angular_velocity\":[{d},{d},{d}],\"before_present\":{},",
            .{
                evidence.requested.target_pose.position[0],
                evidence.requested.target_pose.position[1],
                evidence.requested.target_pose.position[2],
                evidence.requested.target_pose.rotation[0],
                evidence.requested.target_pose.rotation[1],
                evidence.requested.target_pose.rotation[2],
                evidence.requested.target_pose.rotation[3],
                requested_velocity_kind,
                requested_linear[0],
                requested_linear[1],
                requested_linear[2],
                requested_angular[0],
                requested_angular[1],
                requested_angular[2],
                evidence.before != null,
            },
        ) catch {
            self.noteDropped();
            return;
        };
        writer.print(
            "\"before_pose\":[{d},{d},{d},{d},{d},{d},{d}]," ++
                "\"before_linear_velocity\":[{d},{d},{d}],\"before_angular_velocity\":[{d},{d},{d}]," ++
                "\"committed_present\":{},",
            .{
                before.pose.position[0],
                before.pose.position[1],
                before.pose.position[2],
                before.pose.rotation[0],
                before.pose.rotation[1],
                before.pose.rotation[2],
                before.pose.rotation[3],
                before.velocity.linear[0],
                before.velocity.linear[1],
                before.velocity.linear[2],
                before.velocity.angular[0],
                before.velocity.angular[1],
                before.velocity.angular[2],
                evidence.committed != null,
            },
        ) catch {
            self.noteDropped();
            return;
        };
        writer.print(
            "\"committed_pose\":[{d},{d},{d},{d},{d},{d},{d}]," ++
                "\"committed_linear_velocity\":[{d},{d},{d}]," ++
                "\"committed_angular_velocity\":[{d},{d},{d}],",
            .{
                committed.pose.position[0],
                committed.pose.position[1],
                committed.pose.position[2],
                committed.pose.rotation[0],
                committed.pose.rotation[1],
                committed.pose.rotation[2],
                committed.pose.rotation[3],
                committed.velocity.linear[0],
                committed.velocity.linear[1],
                committed.velocity.linear[2],
                committed.velocity.angular[0],
                committed.velocity.angular[1],
                committed.velocity.angular[2],
            },
        ) catch {
            self.noteDropped();
            return;
        };
        writer.print(
            "\"before_sha256\":\"{s}\",\"requested_sha256\":\"{s}\"," ++
                "\"committed_sha256\":\"{s}\",\"durable_asset_namespace\":{d}," ++
                "\"durable_asset_local\":{d},\"durable_sha256\":\"{s}\"}}",
            .{
                before_digest[0..if (change.values.before != null) before_digest.len else 0],
                requested_digest[0..if (change.values.requested != null) requested_digest.len else 0],
                committed_digest[0..if (change.values.committed != null) committed_digest.len else 0],
                durable_namespace,
                durable_local,
                durable_digest[0..durable_digest_len],
            },
        ) catch {
            self.noteDropped();
            return;
        };
        if (!self.enqueueLine(.timeline, sequence, line_buffer[0..writer.end])) {
            return;
        }
        self.last_authored_change = key;
    }

    pub fn flag(
        self: *Capture,
        authority_tick: u64,
        presentation_frame: u64,
        selected: ?engine.gameplay_trace.EntityRef,
    ) ?incident.AnomalyId {
        if (self.anomaly_count == self.anomalies.len) {
            self.setStatus("Anomaly capacity reached; flag rejected visibly");
            return null;
        }
        const now = monotonicNowNs(self.io);
        const wall_ms: i64 = @intCast(@divFloor(wallNowNs(self.io), std.time.ns_per_ms));
        const id = self.next_anomaly_id;
        self.next_anomaly_id +|= 1;
        self.anomalies[self.anomaly_count] = .{
            .view = .{
                .id = id,
                .authority_tick = authority_tick,
                .presentation_frame = presentation_frame,
                .wall_unix_ms = wall_ms,
                .status = .capturing,
            },
            .monotonic_ns = now,
            .post_roll_deadline_ns = now +| post_roll_ns,
            .selected = selected,
        };
        self.anomaly_count += 1;
        self.queue.lock();
        self.queue.anomaly_count = self.anomaly_count;
        self.queue.unlock();
        var selected_buffer: [128]u8 = undefined;
        const selected_json = if (selected) |entity|
            std.fmt.bufPrint(
                &selected_buffer,
                "{{\"namespace\":{d},\"local\":{d},\"incarnation\":{d}}}",
                .{ entity.namespace, entity.local, entity.incarnation },
            ) catch "null"
        else
            "null";
        self.recordFormatted(.timeline, "{{\"schema\":{d},\"kind\":\"anomaly_flag\",\"recorder_sequence\":{d},\"monotonic_ns\":{d},\"wall_unix_ms\":{d},\"authority_tick\":{d},\"presentation_frame\":{d},\"anomaly_id\":{d},\"pre_roll_ns\":{d},\"post_roll_ns\":{d},\"selected_entity\":{s}}}", .{ incident.schema_version, self.takeSequence(), now, wall_ms, authority_tick, presentation_frame, id, pre_roll_ns, post_roll_ns, selected_json });
        self.recordAnomalyIndex(id, authority_tick, presentation_frame, wall_ms, "flagged", .capturing, "");
        _ = self.queue.push(.checkpoint);
        var status_buffer: [incident.max_status_bytes]u8 = undefined;
        const status = std.fmt.bufPrint(&status_buffer, "Anomaly #{d} flagged; collecting 5s post-roll", .{id}) catch "Anomaly flagged";
        self.setStatus(status);
        return id;
    }

    pub fn saveNote(self: *Capture, id: incident.AnomalyId, note: []const u8) bool {
        const anomaly = self.findAnomaly(id) orelse return false;
        const bounded = note[0..@min(note.len, incident.max_note_bytes)];
        @memset(&anomaly.view.note, 0);
        @memcpy(anomaly.view.note[0..bounded.len], bounded);
        anomaly.view.note_len = @intCast(bounded.len);
        self.recordAnomalyIndex(
            id,
            anomaly.view.authority_tick,
            anomaly.view.presentation_frame,
            anomaly.view.wall_unix_ms,
            "note_updated",
            anomaly.view.status,
            bounded,
        );
        if (anomaly.view.status != .capturing) self.queueMarker(anomaly);
        self.setStatus("Anomaly note saved");
        return true;
    }

    pub fn observeScreenshotHealth(
        self: *Capture,
        trail_submitted: u64,
        trail_completed: u64,
        anchor_submitted: u64,
        anchor_completed: u64,
        missed: u64,
        fence_failures: u64,
        attached: u64,
        suspicious: u64,
        anchor_width: u32,
        anchor_height: u32,
        trail_bytes_per_slot: u32,
        anchor_bytes_per_slot: u32,
        trail_slots: u8,
        anchor_slots: u8,
        bounded_download_bytes: u64,
    ) void {
        self.screenshot_misses = missed;
        self.queue.lock();
        self.queue.screenshot_misses = missed;
        self.queue.screenshot_fence_failures = fence_failures;
        self.queue.unlock();
        const now = monotonicNowNs(self.io);
        if (now -| self.last_screenshot_metrics_ns < std.time.ns_per_s) return;
        self.last_screenshot_metrics_ns = now;
        self.recordFormatted(.metrics, "{{\"schema\":{d},\"kind\":\"screenshot_metrics\",\"recorder_sequence\":{d},\"monotonic_ns\":{d},\"trail_submitted\":{d},\"trail_completed\":{d},\"anchor_submitted\":{d},\"anchor_completed\":{d},\"missed\":{d},\"fence_failures\":{d},\"attached\":{d},\"suspicious\":{d},\"anchor_width\":{d},\"anchor_height\":{d},\"trail_bytes_per_slot\":{d},\"anchor_bytes_per_slot\":{d},\"trail_slots\":{d},\"anchor_slots\":{d},\"bounded_gpu_download_bytes\":{d}}}", .{ incident.schema_version, self.takeSequence(), now, trail_submitted, trail_completed, anchor_submitted, anchor_completed, missed, fence_failures, attached, suspicious, anchor_width, anchor_height, trail_bytes_per_slot, anchor_bytes_per_slot, trail_slots, anchor_slots, bounded_download_bytes });
    }

    pub fn recordShortcut(
        self: *Capture,
        stage: incident.ShortcutStage,
        candidate: incident.ShortcutCandidate,
        anomaly_id: ?incident.AnomalyId,
    ) void {
        switch (stage) {
            .received => {
                self.shortcuts.received +|= 1;
                self.shortcuts.last_event_type = candidate.event_type;
                self.shortcuts.last_window_id = candidate.window_id;
                self.shortcuts.last_scancode = candidate.scancode;
                self.shortcuts.last_keycode = candidate.keycode;
                self.shortcuts.last_raw = candidate.raw;
                self.shortcuts.last_modifiers = candidate.modifiers;
                self.shortcuts.last_repeat = candidate.repeat;
                self.shortcuts.last_focused = candidate.focused;
                self.shortcuts.last_matched = candidate.matched;
            },
            .matched => {
                self.shortcuts.matched +|= 1;
                self.shortcuts.last_matched = true;
            },
            .queued => self.shortcuts.queued +|= 1,
            .applied => self.shortcuts.applied +|= 1,
        }
        self.recordFormatted(.input, "{{\"schema\":{d},\"kind\":\"developer_shortcut\",\"recorder_sequence\":{d},\"monotonic_ns\":{d},\"sdl_timestamp_ns\":{d},\"stage\":\"{s}\",\"window_id\":{d},\"event_type\":{d},\"scancode\":{d},\"keycode\":{d},\"raw\":{d},\"modifiers\":{d},\"repeat\":{},\"focused\":{},\"matched\":{},\"anomaly_id\":{?d}}}", .{ incident.schema_version, self.takeSequence(), monotonicNowNs(self.io), candidate.event_monotonic_ns, @tagName(stage), candidate.window_id, candidate.event_type, candidate.scancode, candidate.keycode, candidate.raw, candidate.modifiers, candidate.repeat, candidate.focused, candidate.matched, anomaly_id });
    }

    pub fn recordNeuralRendering(
        self: *Capture,
        enabled: bool,
        output_ready: bool,
        manifest_digest: []const u8,
        checkpoint_digest: []const u8,
        source_tick: u64,
        source_frame: u64,
        presented_source_frame: u64,
        readbacks: u64,
        predictions: u64,
        failures: u64,
        inference_ms: f64,
        pipeline_mean_ms: f64,
        pipeline_maximum_ms: f64,
        unknown_semantic_pixels: u64,
        unknown_instance_pixels: u64,
    ) void {
        self.recordFormatted(.metrics, "{{\"schema\":{d},\"kind\":\"neural_rendering\",\"phase\":\"RF10-G\",\"recorder_sequence\":{d},\"monotonic_ns\":{d},\"enabled\":{},\"output_ready\":{},\"bundle_manifest_sha256\":\"{s}\",\"checkpoint_sha256\":\"{s}\",\"source_tick\":{d},\"source_frame\":{d},\"presented_source_frame\":{d},\"readbacks\":{d},\"predictions\":{d},\"failures\":{d},\"inference_ms\":{d},\"pipeline_mean_ms\":{d},\"pipeline_maximum_ms\":{d},\"unknown_semantic_pixels\":{d},\"unknown_instance_pixels\":{d}}}", .{ incident.schema_version, self.takeSequence(), monotonicNowNs(self.io), enabled, output_ready, manifest_digest, checkpoint_digest, source_tick, source_frame, presented_source_frame, readbacks, predictions, failures, inference_ms, pipeline_mean_ms, pipeline_maximum_ms, unknown_semantic_pixels, unknown_instance_pixels });
    }

    pub fn requestHandoff(self: *Capture) bool {
        for (self.anomalies[0..self.anomaly_count]) |anomaly| {
            if (anomaly.view.status == .capturing) {
                self.handoff_pending_post_roll = true;
                self.setStatus("LLM handoff queued until anomaly post-roll completes");
                return true;
            }
        }
        return self.enqueueHandoff();
    }

    fn enqueueHandoff(self: *Capture) bool {
        var buffer: [incident.max_handoff_bytes]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        writer.print(
            "# Incinerator human-test anomaly bundle\n\nRun folder:\n{s}\n\nHuman tester requested diagnostics at wall_unix_ms={d}.\n\nFlagged anomalies:\n",
            .{ self.runPath(), @divFloor(wallNowNs(self.io), std.time.ns_per_ms) },
        ) catch return false;
        for (self.anomalies[0..self.anomaly_count]) |anomaly| {
            writer.print(
                "- #{d} wall_unix_ms={d} tick={d} frame={d} status={s} evidence=anomalies/anomaly-{d:0>4}/",
                .{ anomaly.view.id, anomaly.view.wall_unix_ms, anomaly.view.authority_tick, anomaly.view.presentation_frame, @tagName(anomaly.view.status), anomaly.view.id },
            ) catch return false;
            if (anomaly.view.note_len != 0) {
                writer.print(": {s}", .{anomaly.view.noteSlice()}) catch return false;
            }
            writer.writeAll("\n") catch return false;
        }
        writer.print(
            "\nEach evidence directory contains marker.json; materialized timeline, state, input, and metrics windows; visual-index.ndjson; eight human-visible anchors from -5 through +2 seconds when admitted; a product-only flag frame; a continuous product trail over the same visual window; and semantic-ID evidence when available. Filenames describe requested anchors; visual-index.ndjson records actual capture times. Timeline windows include immutable runtime phase/system/error and authority-cycle fault ownership when the engine retains a fault.\n\nStart with:\n- manifest.json (current atomic health/build snapshot and evidence capability matrix)\n- anomalies.ndjson (reduce event separately from lifecycle_status)\n- anomalies/anomaly-NNNN/marker.json\n- anomalies/anomaly-NNNN/visual-index.ndjson\n- anomalies/anomaly-NNNN/*-window.ndjson\n- replay/accepted-ingress.icrp\n\nVehicle and carryable entity-state records include persistent/replicated identity, authority-to-draw membership, typed bounded-world interest, baseline/snapshot sequence, districts, distance, and tombstones. Vehicle semantic-ID evidence groups chassis and wheels under one stable identity. NPC state and navigation transition records include semantic destination, status/reason, exact route lineage, topology revision, physical exclusions, and retry timing. Authored NPC records also include stable population member, role, combat disposition, and activity across actor generations. Firearm records use kind=firearm and correlate action sequence, shooter/target identity and incarnation, disposition, weapon mode, ammunition, deadlines, ray origin, impact position, damage, death, and draw submission. kind=render_state records identify the conventional renderer, visual schema, scene light, product/debug and normal/color draw paths, plus the last stable semantic part/material identity. kind=authored_change records source, scope, stable target, optimistic revisions, typed crate values, outcome/rejection, time correlation, and SHA-256 value digests.\n\nSearch examples:\n```sh\nrg '\"removal_reason\":\"(relevance|replication_removed|authority_removed|presentation_removed)\"|\"relevance_reason\"' '{s}'\nrg '\"action\":\"navigation\"|\"navigation_status\":\"(blocked|waiting_for_content|structurally_unreachable)\"|\"navigation_reason\":\"physical_obstruction\"' '{s}/streams'\nrg '\"action\":\"population\"|\"population_member\"|\"population_activity_state\"' '{s}/streams'\nrg '\"kind\":\"firearm\"|\"weapon\":|\"fire_pressed\":true|\"weapon_toggle_pressed\":true|\"reload_pressed\":true' '{s}/streams'\nrg '\"kind\":\"render_state\"|\"render_mode\"|\"last_visual\"' '{s}/streams'\nrg '\"kind\":\"authored_change\"|\"transaction_id\"|\"expected_revision\"' '{s}/streams'\nrg '\"kind\":\"(runtime_fault|authority_cycle_fault)\"' '{s}/streams'\nrg '\"kind\":\"developer_shortcut\"|\"stage\":\"(received|matched|queued|applied)\"' '{s}/streams'\n```\n\nVerification from the repository root:\n```sh\nzig build inspect-incident -- '{s}'\nzig build incident-visual-report -- '{s}' <new-output-folder-outside-the-run>\nzig build replay-incident -- '{s}' <absolute-installed-content-root>\nzig build run -- --replay-incident='{s}'\n```\n\nThe replay content root must be absolute; from the repository root use \"$PWD/zig-out/share/incinerator/content\". Semantic replay proves accepted-ingress logical digests for the recorded cohort. Graphical re-execution is best effort for SDL, Metal, worker, and presentation timing. Preserve this original folder.\n",
            .{ self.runPath(), self.runPath(), self.runPath(), self.runPath(), self.runPath(), self.runPath(), self.runPath(), self.runPath(), self.runPath(), self.runPath(), self.runPath(), self.runPath() },
        ) catch return false;
        const handoff_bytes = buffer[0..writer.end];
        self.queue.publishHandoff(handoff_bytes);

        const owned = std.heap.page_allocator.dupe(u8, handoff_bytes) catch {
            self.setStatus("LLM handoff ready for clipboard; durable copy allocation failed");
            return true;
        };
        if (self.writer.hardening_profile == .writer_budget and
            !self.writer_budget_armed)
        {
            if (!self.queue.push(.arm_writer_budget)) {
                std.heap.page_allocator.free(owned);
                self.setStatus("LLM handoff ready for clipboard; writer-budget arm rejected");
                return true;
            }
            self.writer_budget_armed = true;
        }
        if (!self.queue.push(.{ .handoff = .{ .bytes = owned } })) {
            std.heap.page_allocator.free(owned);
            self.setStatus("LLM handoff ready for clipboard; durable writer queue rejected it");
            return true;
        }
        _ = self.queue.push(.flush);
        self.setStatus("LLM handoff ready for clipboard; durable persistence queued");
        return true;
    }

    pub fn takeHandoff(self: *Capture, buffer: *[incident.max_handoff_bytes]u8) ?[]const u8 {
        self.queue.lock();
        defer self.queue.unlock();
        if (!self.queue.handoff_ready) return null;
        const value = self.queue.handoff;
        @memcpy(buffer[0..value.len], value.slice());
        self.queue.handoff_ready = false;
        self.setStatusLocked("LLM handoff copied; folder path and anomaly index are ready");
        return buffer[0..value.len];
    }

    pub fn attachReplay(self: *Capture, owned_bytes: []u8) bool {
        if (self.queue.push(.{ .replay = .{ .bytes = owned_bytes } })) return true;
        std.heap.page_allocator.free(owned_bytes);
        return false;
    }

    pub fn attachVisual(
        self: *Capture,
        anomaly_id: incident.AnomalyId,
        metadata: VisualFrameMetadata,
        owned_rgba: ?[]u8,
    ) bool {
        const reservation = if (owned_rgba != null) visualStorageBytes(metadata) else 0;
        if (reservation != 0 and !self.queue.reserveVisual(reservation)) {
            if (owned_rgba) |pixels| std.heap.page_allocator.free(pixels);
            self.noteVisualFailure(anomaly_id);
            self.setStatus("Visual evidence budget exhausted; anomaly will finalize partial");
            return false;
        }
        if (self.queue.push(.{ .image = .{
            .anomaly_id = anomaly_id,
            .metadata = metadata,
            .pixels = owned_rgba,
            .semantic_entry_count = 0,
        } })) {
            if (self.findAnomaly(anomaly_id)) |anomaly| {
                anomaly.view.artifact_count +|= 1;
                switch (metadata.source) {
                    .human_visible => if (metadata.requested_offset_ms) |offset| {
                        anomaly.human_anchor_mask |= humanAnchorBit(offset);
                    },
                    .product_flag => anomaly.product_flag_present = true,
                    .semantic_id => anomaly.semantic_id_present = true,
                    .product_trail => {},
                }
            }
            return true;
        }
        self.screenshot_misses +|= 1;
        self.queue.lock();
        self.queue.screenshot_misses = self.screenshot_misses;
        self.queue.unlock();
        if (reservation != 0) self.queue.releaseVisual(reservation);
        if (owned_rgba) |pixels| std.heap.page_allocator.free(pixels);
        return false;
    }

    pub fn attachSemanticVisual(
        self: *Capture,
        anomaly_id: incident.AnomalyId,
        metadata: VisualFrameMetadata,
        owned_rgba: []u8,
        entries: []const SemanticMapEntry,
    ) bool {
        if (metadata.source != .semantic_id or entries.len == 0 or
            entries.len > maximum_semantic_entries)
        {
            std.heap.page_allocator.free(owned_rgba);
            self.noteVisualFailure(anomaly_id);
            return false;
        }
        var image = Image{
            .anomaly_id = anomaly_id,
            .metadata = metadata,
            .pixels = owned_rgba,
            .semantic_entry_count = @intCast(entries.len),
        };
        @memcpy(image.semantic_entries[0..entries.len], entries);
        const reservation = visualStorageBytes(metadata);
        if (!self.queue.reserveVisual(reservation)) {
            std.heap.page_allocator.free(owned_rgba);
            self.noteVisualFailure(anomaly_id);
            self.setStatus("Visual evidence budget exhausted; anomaly will finalize partial");
            return false;
        }
        if (!self.queue.push(.{ .image = image })) {
            self.queue.releaseVisual(reservation);
            std.heap.page_allocator.free(owned_rgba);
            self.noteVisualFailure(anomaly_id);
            return false;
        }
        if (self.findAnomaly(anomaly_id)) |anomaly| {
            anomaly.view.artifact_count +|= 1;
            anomaly.semantic_id_present = true;
        }
        return true;
    }

    pub fn noteVisualFailure(self: *Capture, anomaly_id: incident.AnomalyId) void {
        self.screenshot_misses +|= 1;
        if (self.findAnomaly(anomaly_id)) |anomaly| {
            anomaly.view.artifact_failures +|= 1;
        }
        self.queue.lock();
        self.queue.screenshot_misses = self.screenshot_misses;
        self.queue.unlock();
    }

    pub fn snapshot(self: *Capture, request_rejections: u64) incident.View {
        var result = incident.View{};
        @memcpy(result.run_path[0..self.run_path_len], self.runPath());
        result.run_path_len = self.run_path_len;
        result.anomaly_count = self.anomaly_count;
        for (self.anomalies[0..self.anomaly_count], 0..) |anomaly, index| {
            result.anomalies[index] = anomaly.view;
        }
        @memcpy(result.status[0..self.status_len], self.status[0..self.status_len]);
        result.status_len = self.status_len;
        result.request_rejections = request_rejections;
        result.shortcuts = self.shortcuts;
        self.queue.lock();
        result.health = .{
            .enabled = true,
            .writer_ready = self.queue.writer_ready,
            .writer_failed = self.queue.writer_failed,
            .visual_budget_exhausted = self.queue.visual_budget_exhausted,
            .handoff_persisted = self.queue.handoff_persisted,
            .queued = @intCast(@min(self.queue.count, std.math.maxInt(u16))),
            .queue_high_water = @intCast(@min(self.queue.high_water, std.math.maxInt(u16))),
            .dropped_records = self.queue.dropped,
            .visual_budget_rejections = self.queue.visual_budget_rejections,
            .bytes_written = self.queue.bytes_written,
            .visual_bytes_reserved = self.queue.visual_bytes_reserved,
            .visual_budget_bytes = self.queue.visual_budget_bytes,
            .screenshot_misses = self.screenshot_misses,
            .last_durable_sequence = self.queue.last_durable_sequence,
            .last_admitted_sequence = self.queue.last_admitted_sequence,
        };
        self.queue.unlock();
        return result;
    }

    fn drainGameplay(self: *Capture, view: engine.gameplay_trace.BorrowedView, now: u64) void {
        for (0..view.len()) |index| {
            const record = view.at(index).?;
            if (record.sequence <= self.last_gameplay_sequence) continue;
            self.last_gameplay_sequence = record.sequence;
            var actor_buffer: [128]u8 = undefined;
            var target_buffer: [128]u8 = undefined;
            const actor = entityJson(&actor_buffer, record.actor);
            const target = entityJson(&target_buffer, record.target);
            self.recordGameplayTrace(record, actor, target, now);
        }
    }

    fn recordGameplayTrace(
        self: *Capture,
        record: engine.gameplay_trace.Record,
        actor: []const u8,
        target: []const u8,
        now: u64,
    ) void {
        const sequence = self.takeSequence();
        var buffer: [max_line_bytes]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        writer.print(
            "{{\"schema\":{d},\"kind\":\"gameplay_trace\",\"recorder_sequence\":{d},\"monotonic_ns\":{d},\"trace_sequence\":{d},\"authority_tick\":{d},\"presentation_frame\":{?d},\"source\":\"{s}\",\"stage\":\"{s}\",\"action\":\"{s}\",\"disposition\":\"{s}\",\"reason_domain\":\"{s}\",\"reason\":{d},\"topology_id\":{d},\"correlation_id\":{d},\"actor\":{s},\"target\":{s},\"position\":[{d},{d},{d}],\"health\":{d},\"maximum_health\":{d},\"state\":{d},\"deadline_tick\":{d},\"visible_pixels\":{d},\"navigation\":",
            .{ incident.schema_version, sequence, now, record.sequence, record.authority_tick, record.presentation_frame, @tagName(record.source), @tagName(record.stage), @tagName(record.kind), @tagName(record.disposition), @tagName(record.reason_domain), record.reason, record.topology_id, record.correlation_id, actor, target, record.position[0], record.position[1], record.position[2], record.health, record.maximum_health, record.state, record.deadline_tick, record.visible_pixels },
        ) catch return self.noteDropped();
        if (record.navigation) |navigation_evidence| {
            writer.print(
                "{{\"destination_id\":{?d},\"route_revision\":{d},\"topology_revision\":{d},\"route_digest\":{d},\"route_cost\":{d},\"route_length\":{d},\"active_prefix_length\":{d},\"route_index\":{d},\"nodes\":[",
                .{ navigation_evidence.destination_id, navigation_evidence.route_revision, navigation_evidence.topology_revision, navigation_evidence.route_digest, navigation_evidence.route_cost, navigation_evidence.route_length, navigation_evidence.active_prefix_length, navigation_evidence.route_index },
            ) catch return self.noteDropped();
            const route_length = @min(
                @as(usize, navigation_evidence.route_length),
                navigation_evidence.nodes.len,
            );
            for (navigation_evidence.nodes[0..route_length], 0..) |node, index| {
                if (index != 0) writer.writeAll(",") catch return self.noteDropped();
                writer.print(
                    "{{\"district\":[{d},{d}],\"index\":{d}}}",
                    .{ node.district_x, node.district_z, node.index },
                ) catch return self.noteDropped();
            }
            writer.writeAll("]}") catch return self.noteDropped();
        } else {
            writer.writeAll("null") catch return self.noteDropped();
        }
        writer.writeAll(",\"population\":") catch return self.noteDropped();
        if (record.population) |value| {
            writer.print(
                "{{\"member_id\":{d},\"actor_generation\":{d},\"role\":{d},\"combat_disposition\":{d},\"activity_program\":{d},\"activity_sequence\":{d},\"activity_kind\":{d},\"previous_state\":{d},\"current_state\":{d},\"transition_reason\":{d},\"activity_site\":{?d},\"activity_slot\":{?d},\"deadline_tick\":{d},\"retry_reason\":{d}}}",
                .{
                    value.member_id,
                    value.actor_generation,
                    value.role,
                    value.combat_disposition,
                    value.activity_program,
                    value.activity_sequence,
                    value.activity_kind,
                    value.previous_state,
                    value.current_state,
                    value.transition_reason,
                    value.activity_site,
                    value.activity_slot,
                    value.deadline_tick,
                    value.retry_reason,
                },
            ) catch return self.noteDropped();
        } else {
            writer.writeAll("null") catch return self.noteDropped();
        }
        writer.writeAll(",\"weapon\":") catch return self.noteDropped();
        if (record.weapon) |weapon| {
            writer.print(
                "{{\"action\":{d},\"mode\":{d},\"magazine_ammo\":{d},\"reserve_ammo\":{d},\"weapon_ready_tick\":{d},\"reload_complete_tick\":{d},\"ray_origin\":[{d},{d},{d}],\"impact_position\":[{d},{d},{d}],\"applied_damage\":{d},\"killed\":{}}}",
                .{ weapon.action, weapon.mode, weapon.magazine_ammo, weapon.reserve_ammo, weapon.weapon_ready_tick, weapon.reload_complete_tick, weapon.ray_origin[0], weapon.ray_origin[1], weapon.ray_origin[2], weapon.impact_position[0], weapon.impact_position[1], weapon.impact_position[2], weapon.applied_damage, weapon.killed },
            ) catch return self.noteDropped();
        } else {
            writer.writeAll("null") catch return self.noteDropped();
        }
        writer.writeAll("}") catch return self.noteDropped();
        _ = self.enqueueLine(.timeline, sequence, buffer[0..writer.end]);
    }

    fn drainDiagnostics(self: *Capture, view: engine.runtime.DiagnosticJournal.BorrowedView, now: u64) void {
        for (0..view.len()) |index| {
            const entry = view.at(index).?.*;
            if (entry.sequence <= self.last_diagnostic_sequence) continue;
            self.last_diagnostic_sequence = entry.sequence;
            self.recordFormatted(.timeline, "{{\"schema\":{d},\"kind\":\"diagnostic\",\"recorder_sequence\":{d},\"monotonic_ns\":{d},\"diagnostic_sequence\":{d},\"severity\":\"{s}\",\"category\":\"{s}\",\"code\":{d},\"authority_tick\":{?d},\"presentation_frame\":{?d},\"thread_role\":\"{s}\",\"thread_id\":{?d},\"correlation_id\":{d}}}", .{ incident.schema_version, self.takeSequence(), now, entry.sequence, @tagName(entry.severity), @tagName(entry.category), entry.code, entry.tick_index, entry.frame_index, @tagName(entry.thread_role), entry.thread_id, entry.correlation_id });
        }
    }

    fn recordRetainedFaults(
        self: *Capture,
        runtime_fault: ?engine.runtime.RuntimeFault,
        authority_cycle_fault: ?authority_diagnostics.CycleFault,
        now: u64,
    ) void {
        if (!self.runtime_fault_recorded) {
            if (runtime_fault) |fault| {
                self.runtime_fault_recorded = self.recordFormattedAdmitted(.timeline, "{{\"schema\":{d},\"kind\":\"runtime_fault\",\"recorder_sequence\":{d},\"monotonic_ns\":{d},\"phase\":\"{s}\",\"authority_tick\":{d},\"system\":\"{s}\",\"system_truncated\":{},\"error\":\"{s}\",\"error_truncated\":{},\"error_code\":{d},\"diagnostic_sequence\":{d}}}", .{ incident.schema_version, self.takeSequence(), now, @tagName(fault.phase), fault.tick_index, fault.system_name.slice(), fault.system_name.truncated, fault.error_name.slice(), fault.error_name.truncated, fault.error_code, fault.journal_sequence });
            }
        }
        if (!self.authority_cycle_fault_recorded) {
            if (authority_cycle_fault) |fault| {
                self.authority_cycle_fault_recorded = self.recordFormattedAdmitted(.timeline, "{{\"schema\":{d},\"kind\":\"authority_cycle_fault\",\"recorder_sequence\":{d},\"monotonic_ns\":{d},\"stage\":\"{s}\",\"target_tick\":{d},\"completed_tick\":{d},\"error\":\"{s}\",\"error_truncated\":{},\"error_code\":{d}}}", .{ incident.schema_version, self.takeSequence(), now, @tagName(fault.stage), fault.target_tick, fault.completed_tick, fault.error_name.slice(), fault.error_name.truncated, fault.error_code });
            }
        }
    }

    fn recordState(self: *Capture, view: *const editor_contract.GameplayView, yaw: f32, pitch: f32, now: u64) void {
        self.recordFormatted(.state, "{{\"schema\":{d},\"kind\":\"camera_state\",\"recorder_sequence\":{d},\"monotonic_ns\":{d},\"authority_tick\":{d},\"presentation_frame\":{d},\"yaw\":{d},\"pitch\":{d},\"entity_count\":{d},\"weapon_mode\":\"{s}\",\"magazine_ammo\":{d},\"reserve_ammo\":{d},\"weapon_remaining_ticks\":{d},\"reload_remaining_ticks\":{d}}}", .{ incident.schema_version, self.takeSequence(), now, view.authority_tick, view.presentation_frame, yaw, pitch, view.entity_count, @tagName(view.weapon_mode), view.magazine_ammo, view.reserve_ammo, view.weapon_remaining_ticks, view.reload_remaining_ticks });
        for (view.entitySlice()) |entity| self.recordEntityState(view, entity, now);
    }

    fn recordRenderState(
        self: *Capture,
        gameplay: *const editor_contract.GameplayView,
        view: *const editor_contract.RenderView,
        now: u64,
    ) void {
        self.recordFormatted(
            .state,
            "{{\"schema\":{d},\"kind\":\"render_state\",\"recorder_sequence\":{d},\"monotonic_ns\":{d},\"authority_tick\":{d},\"presentation_frame\":{d},\"render_mode\":\"{s}\",\"visual_schema\":{d},\"scene_light\":{{\"sun_direction\":[{d},{d},{d}],\"sun_color\":[{d},{d},{d}],\"sun_intensity\":{d},\"ambient_color\":[{d},{d},{d}]}},\"draw_paths\":{{\"lit_product\":{d},\"unlit_product\":{d},\"debug\":{d},\"normal_geometry\":{d},\"color_geometry\":{d}}},\"last_visual\":{{\"semantic\":\"{s}\",\"part\":\"{s}\",\"ordinal\":{d},\"surface\":\"{s}\"}}}}",
            .{
                incident.schema_version,
                self.takeSequence(),
                now,
                gameplay.authority_tick,
                gameplay.presentation_frame,
                view.mode,
                view.visual_schema,
                view.scene_light.sun_direction[0],
                view.scene_light.sun_direction[1],
                view.scene_light.sun_direction[2],
                view.scene_light.sun_color[0],
                view.scene_light.sun_color[1],
                view.scene_light.sun_color[2],
                view.scene_light.sun_intensity,
                view.scene_light.ambient_color[0],
                view.scene_light.ambient_color[1],
                view.scene_light.ambient_color[2],
                view.frame_stats.lit_product_draws,
                view.frame_stats.unlit_product_draws,
                view.frame_stats.debug_draws,
                view.frame_stats.normal_geometry_draws,
                view.frame_stats.color_geometry_draws,
                view.last_semantic,
                view.last_part,
                view.last_ordinal,
                view.last_surface,
            },
        );
    }

    fn recordEntityState(
        self: *Capture,
        view: *const editor_contract.GameplayView,
        entity: editor_contract.GameplayEntityView,
        now: u64,
    ) void {
        const sequence = self.takeSequence();
        var buffer: [max_line_bytes]u8 = undefined;
        var persistent_buffer: [128]u8 = undefined;
        const persistent_json = if (entity.persistent_id) |id|
            std.fmt.bufPrint(
                &persistent_buffer,
                "{{\"namespace\":{d},\"local\":{d}}}",
                .{ id.namespace, id.local },
            ) catch "null"
        else
            "null";
        var writer = std.Io.Writer.fixed(&buffer);
        writer.print(
            "{{\"schema\":{d},\"kind\":\"entity_state\",\"recorder_sequence\":{d},\"monotonic_ns\":{d},\"authority_tick\":{d},\"presentation_frame\":{d},\"entity\":{{\"namespace\":{d},\"local\":{d},\"incarnation\":{d}}},\"persistent_id\":{s},\"entity_kind\":\"{s}\",\"authority_presence\":\"{s}\",\"replication_presence\":\"{s}\",\"presentation_presence\":\"{s}\",\"draw_presence\":\"{s}\",\"removal_reason\":\"{s}\",\"removed_tick\":{d},\"removed_frame\":{d},",
            .{ incident.schema_version, sequence, now, view.authority_tick, view.presentation_frame, entity.entity.namespace, entity.entity.local, entity.entity.incarnation, persistent_json, @tagName(entity.kind), @tagName(entity.authority_presence), @tagName(entity.replication_presence), @tagName(entity.presentation_presence), @tagName(entity.draw_presence), @tagName(entity.removal_reason), entity.removed_tick, entity.removed_frame },
        ) catch return self.noteDropped();
        writer.print(
            "\"authority_position\":[{d},{d},{d}],\"presentation_position\":[{d},{d},{d}],\"velocity\":[{d},{d},{d}],\"facing_yaw\":{d},\"radius\":{d},\"half_height\":{d},\"health\":{d},\"maximum_health\":{d},\"life_state\":\"{s}\",\"encounter_state\":{d},\"attack_windup\":{},\"deadline_tick\":{d},\"nearest_actor_separation\":{?d},\"navigation_progress\":\"{s}\",\"navigation_no_progress_ticks\":{d},\"navigation_last_progress_tick\":{d},",
            .{ entity.authority_position[0], entity.authority_position[1], entity.authority_position[2], entity.presentation_position[0], entity.presentation_position[1], entity.presentation_position[2], entity.velocity[0], entity.velocity[1], entity.velocity[2], entity.facing_yaw, entity.radius, entity.half_height, entity.health, entity.maximum_health, @tagName(entity.life_state), entity.encounter_state, entity.attack_windup, entity.deadline_tick, entity.nearest_actor_separation, @tagName(entity.navigation_progress), entity.navigation_no_progress_ticks, entity.navigation_last_progress_tick },
        ) catch return self.noteDropped();
        if (entity.navigation_target) |target| {
            writer.print(
                "\"navigation_target\":[{d},{d},{d}],",
                .{ target[0], target[1], target[2] },
            ) catch return self.noteDropped();
        } else {
            writer.writeAll("\"navigation_target\":null,") catch return self.noteDropped();
        }
        if (entity.navigation_destination) |destination| {
            writer.print(
                "\"navigation_destination\":{d},\"navigation_destination_name\":\"{s}\",",
                .{
                    destination.value,
                    sandbox_host_contracts.destinationName(destination) orelse "unknown",
                },
            ) catch return self.noteDropped();
        } else {
            writer.writeAll(
                "\"navigation_destination\":null,\"navigation_destination_name\":null,",
            ) catch return self.noteDropped();
        }
        writer.print(
            "\"navigation_status\":\"{s}\",\"navigation_reason\":\"{s}\",\"navigation_trigger\":\"{s}\",\"navigation_result\":\"{s}\",\"navigation_route_revision\":{d},\"navigation_topology_revision\":{d},\"navigation_route_digest\":{d},\"navigation_route_cost\":{d},\"navigation_route_length\":{d},\"navigation_active_prefix_length\":{d},\"navigation_route_index\":{d},\"navigation_replan_count\":{d},\"navigation_arrival_tick\":{?d},\"navigation_physical_exclusion_count\":{d},\"navigation_physical_block_retry_tick\":{d},",
            .{
                if (entity.navigation_status) |value| @tagName(value) else "unavailable",
                if (entity.navigation_reason) |value| @tagName(value) else "unavailable",
                if (entity.navigation_trigger) |value| @tagName(value) else "unavailable",
                if (entity.navigation_result) |value| @tagName(value) else "unavailable",
                entity.navigation_route_revision,
                entity.navigation_topology_revision,
                entity.navigation_route_digest,
                entity.navigation_route_cost,
                entity.navigation_route_length,
                entity.navigation_active_prefix_length,
                entity.navigation_route_index,
                entity.navigation_replan_count,
                entity.navigation_arrival_tick,
                entity.navigation_physical_exclusion_count,
                entity.navigation_physical_block_retry_tick,
            },
        ) catch return self.noteDropped();
        writer.print(
            "\"population_member\":{?d},\"population_role\":\"{s}\",\"population_combat_disposition\":\"{s}\",\"population_activity_kind\":\"{s}\",\"population_activity_state\":\"{s}\",",
            .{
                if (entity.population_member) |value| value.value else null,
                if (entity.population_role) |value| @tagName(value) else "unavailable",
                if (entity.population_disposition) |value| @tagName(value) else "unavailable",
                if (entity.population_activity_kind) |value| @tagName(value) else "unavailable",
                if (entity.population_activity_state) |value| @tagName(value) else "unavailable",
            },
        ) catch return self.noteDropped();
        const relevance_included = if (entity.relevance_included) |included|
            if (included) "true" else "false"
        else
            "null";
        writer.print(
            "\"relevance_included\":{s},\"relevance_reason\":\"{s}\",\"relevance_evaluated_tick\":{d},\"relevance_baseline_id\":{d},\"relevance_snapshot_sequence\":{d},\"relevance_grace_until_tick\":{d},\"relevance_observer_position\":[{d},{d},{d}],\"relevance_observer_district\":[{d},{d}],\"relevance_owner_district\":[{d},{d}],\"relevance_distance_squared_xz\":{d},\"relevance_encounter\":{}}}",
            .{ relevance_included, @tagName(entity.relevance_reason), entity.relevance_evaluated_tick, entity.relevance_baseline_id, entity.relevance_snapshot_sequence, entity.relevance_grace_until_tick, entity.relevance_observer_position[0], entity.relevance_observer_position[1], entity.relevance_observer_position[2], entity.relevance_observer_district[0], entity.relevance_observer_district[1], entity.relevance_owner_district[0], entity.relevance_owner_district[1], entity.relevance_distance_squared_xz, entity.relevance_encounter },
        ) catch return self.noteDropped();
        _ = self.enqueueLine(.state, sequence, buffer[0..writer.end]);
    }

    fn recordInput(self: *Capture, view: *const editor_contract.GameplayView, value: incident.InputSample, now: u64) void {
        self.recordFormatted(.input, "{{\"schema\":{d},\"kind\":\"semantic_input\",\"recorder_sequence\":{d},\"monotonic_ns\":{d},\"authority_tick\":{d},\"presentation_frame\":{d},\"forward\":{},\"backward\":{},\"left\":{},\"right\":{},\"interact\":{},\"carry\":{},\"attack\":{},\"respawn\":{},\"jump_or_brake\":{},\"interact_pressed\":{},\"carry_pressed\":{},\"attack_pressed\":{},\"weapon_toggle_pressed\":{},\"fire_pressed\":{},\"reload_pressed\":{},\"respawn_pressed\":{},\"jump_pressed\":{},\"hand_brake\":{},\"right_mouse\":{},\"mouse_delta\":[{d},{d}],\"keyboard_captured\":{},\"mouse_captured\":{},\"window_minimized\":{}}}", .{ incident.schema_version, self.takeSequence(), now, view.authority_tick, view.presentation_frame, value.move_forward, value.move_backward, value.move_left, value.move_right, value.interact, value.carry, value.attack, value.respawn, value.jump_or_brake, value.interact_pressed, value.carry_pressed, value.attack_pressed, value.weapon_toggle_pressed, value.fire_pressed, value.reload_pressed, value.respawn_pressed, value.jump_pressed, value.hand_brake, value.right_mouse, value.mouse_delta_x, value.mouse_delta_y, value.keyboard_captured, value.mouse_captured, value.window_minimized });
    }

    fn recordMetrics(self: *Capture, view: *const editor_contract.GameplayView, frame_time_ms: f32, now: u64) void {
        self.queue.lock();
        const queued = self.queue.count;
        const high_water = self.queue.high_water;
        const dropped = self.queue.dropped;
        const bytes = self.queue.bytes_written;
        self.queue.unlock();
        var npc_count: u32 = 0;
        var following_count: u32 = 0;
        var waiting_count: u32 = 0;
        var blocked_count: u32 = 0;
        var arrived_count: u32 = 0;
        var unreachable_count: u32 = 0;
        var total_replans: u64 = 0;
        var physical_exclusions: u32 = 0;
        var maximum_route_length: u8 = 0;
        var maximum_route_cost: u32 = 0;
        for (view.entitySlice()) |entity| {
            if (entity.kind != .npc) continue;
            npc_count += 1;
            if (entity.navigation_status) |status| switch (status) {
                .following => following_count += 1,
                .waiting_for_content => waiting_count += 1,
                .blocked => blocked_count += 1,
                .arrived => arrived_count += 1,
                .structurally_unreachable => unreachable_count += 1,
                .idle, .resolving => {},
            };
            total_replans +|= entity.navigation_replan_count;
            physical_exclusions +|= entity.navigation_physical_exclusion_count;
            maximum_route_length = @max(
                maximum_route_length,
                entity.navigation_route_length,
            );
            maximum_route_cost = @max(maximum_route_cost, entity.navigation_route_cost);
        }
        self.recordFormatted(.metrics, "{{\"schema\":{d},\"kind\":\"recorder_metrics\",\"recorder_sequence\":{d},\"monotonic_ns\":{d},\"authority_tick\":{d},\"presentation_frame\":{d},\"frame_time_ms\":{d},\"writer_queue\":{d},\"writer_queue_high_water\":{d},\"dropped_records\":{d},\"bytes_written\":{d},\"screenshot_misses\":{d},\"navigation\":{{\"npc_count\":{d},\"following\":{d},\"waiting_for_content\":{d},\"blocked\":{d},\"arrived\":{d},\"structurally_unreachable\":{d},\"total_replans\":{d},\"physical_exclusions\":{d},\"maximum_route_length\":{d},\"maximum_route_cost\":{d}}}}}", .{ incident.schema_version, self.takeSequence(), now, view.authority_tick, view.presentation_frame, frame_time_ms, queued, high_water, dropped, bytes, self.screenshot_misses, npc_count, following_count, waiting_count, blocked_count, arrived_count, unreachable_count, total_replans, physical_exclusions, maximum_route_length, maximum_route_cost });
    }

    fn finishPostRoll(self: *Capture, now: u64) void {
        for (self.anomalies[0..self.anomaly_count]) |*anomaly| {
            if (anomaly.view.status != .capturing or now < anomaly.post_roll_deadline_ns) continue;
            anomaly.view.status = if (anomaly.human_anchor_mask != complete_human_anchor_mask or
                !anomaly.product_flag_present or !anomaly.semantic_id_present or
                anomaly.view.artifact_failures != 0) .partial else .complete;
            self.queueMarker(anomaly);
            self.recordAnomalyIndex(
                anomaly.view.id,
                anomaly.view.authority_tick,
                anomaly.view.presentation_frame,
                anomaly.view.wall_unix_ms,
                "post_roll_finalized",
                anomaly.view.status,
                anomaly.view.noteSlice(),
            );
            _ = self.queue.push(.flush);
            var status_buffer: [incident.max_status_bytes]u8 = undefined;
            const status = std.fmt.bufPrint(&status_buffer, "Anomaly #{d} post-roll {s}", .{ anomaly.view.id, @tagName(anomaly.view.status) }) catch "Anomaly post-roll finalized";
            self.setStatus(status);
        }
        if (self.handoff_pending_post_roll) {
            for (self.anomalies[0..self.anomaly_count]) |anomaly| {
                if (anomaly.view.status == .capturing) return;
            }
            self.handoff_pending_post_roll = false;
            _ = self.enqueueHandoff();
        }
    }

    fn recordAnomalyIndex(self: *Capture, id: incident.AnomalyId, tick: u64, frame: u64, wall_ms: i64, event: []const u8, lifecycle_status: incident.AnomalyStatus, note: []const u8) void {
        var escaped: [incident.max_note_bytes * 2]u8 = undefined;
        const safe_note = escapeJson(&escaped, note);
        self.recordFormatted(.anomalies, "{{\"schema\":{d},\"kind\":\"anomaly_index\",\"recorder_sequence\":{d},\"monotonic_ns\":{d},\"wall_unix_ms\":{d},\"authority_tick\":{d},\"presentation_frame\":{d},\"anomaly_id\":{d},\"event\":\"{s}\",\"lifecycle_status\":\"{s}\",\"note\":\"{s}\"}}", .{ incident.schema_version, self.takeSequence(), monotonicNowNs(self.io), wall_ms, tick, frame, id, event, @tagName(lifecycle_status), safe_note });
    }

    fn queueMarker(self: *Capture, anomaly: *const ActiveAnomaly) void {
        _ = self.queue.push(.{ .marker = .{
            .anomaly_id = anomaly.view.id,
            .authority_tick = anomaly.view.authority_tick,
            .presentation_frame = anomaly.view.presentation_frame,
            .wall_unix_ms = anomaly.view.wall_unix_ms,
            .monotonic_ns = anomaly.monotonic_ns,
            .lifecycle_status = anomaly.view.status,
            .artifact_count = anomaly.view.artifact_count,
            .artifact_failures = anomaly.view.artifact_failures,
            .human_anchor_mask = anomaly.human_anchor_mask,
            .product_flag_present = anomaly.product_flag_present,
            .semantic_id_present = anomaly.semantic_id_present,
            .selected = anomaly.selected,
            .note = anomaly.view.note,
            .note_len = anomaly.view.note_len,
        } });
    }

    fn recordFormatted(self: *Capture, stream: Stream, comptime format: []const u8, args: anytype) void {
        _ = self.recordFormattedAdmitted(stream, format, args);
    }

    fn recordFormattedAdmitted(
        self: *Capture,
        stream: Stream,
        comptime format: []const u8,
        args: anytype,
    ) bool {
        var buffer: [max_line_bytes]u8 = undefined;
        const bytes = std.fmt.bufPrint(&buffer, format, args) catch {
            self.noteDropped();
            return false;
        };
        return self.enqueueLine(stream, self.next_sequence -| 1, bytes);
    }

    fn enqueueLine(self: *Capture, stream: Stream, sequence: u64, bytes: []const u8) bool {
        var line = Line{
            .stream = stream,
            .sequence = sequence,
            .len = @intCast(bytes.len),
            .bytes = undefined,
        };
        @memcpy(line.bytes[0..bytes.len], bytes);
        if (self.queue.push(.{ .line = line })) {
            self.queue.lock();
            self.queue.last_admitted_sequence = @max(
                self.queue.last_admitted_sequence,
                line.sequence,
            );
            self.queue.unlock();
            return true;
        }
        return false;
    }

    fn noteDropped(self: *Capture) void {
        self.queue.lock();
        self.queue.dropped +|= 1;
        self.queue.unlock();
    }

    fn takeSequence(self: *Capture) u64 {
        const value = self.next_sequence;
        self.next_sequence +|= 1;
        return value;
    }

    fn findAnomaly(self: *Capture, id: incident.AnomalyId) ?*ActiveAnomaly {
        for (self.anomalies[0..self.anomaly_count]) |*anomaly| {
            if (anomaly.view.id == id) return anomaly;
        }
        return null;
    }

    fn setStatus(self: *Capture, text: []const u8) void {
        const bounded = text[0..@min(text.len, self.status.len)];
        @memset(&self.status, 0);
        @memcpy(self.status[0..bounded.len], bounded);
        self.status_len = @intCast(bounded.len);
    }

    fn setStatusLocked(self: *Capture, text: []const u8) void {
        const bounded = text[0..@min(text.len, self.status.len)];
        @memset(&self.status, 0);
        @memcpy(self.status[0..bounded.len], bounded);
        self.status_len = @intCast(bounded.len);
    }
};

const TimestampText = struct {
    bytes: [32]u8,
    len: u8,
    fn slice(self: *const TimestampText) []const u8 {
        return self.bytes[0..self.len];
    }
};

fn utcFilename(unix_ns: i96) TimestampText {
    const seconds: u64 = if (unix_ns <= 0) 0 else @intCast(@divFloor(unix_ns, std.time.ns_per_s));
    const millis: u16 = @intCast(@divFloor(@mod(unix_ns, std.time.ns_per_s), std.time.ns_per_ms));
    const epoch = std.time.epoch.EpochSeconds{ .secs = seconds };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch.getDaySeconds();
    var result = TimestampText{ .bytes = undefined, .len = 0 };
    const value = std.fmt.bufPrint(
        &result.bytes,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}-{d:0>2}-{d:0>2}.{d:0>3}Z",
        .{ year_day.year, @intFromEnum(month_day.month), month_day.day_index + 1, day_seconds.getHoursIntoDay(), day_seconds.getMinutesIntoHour(), day_seconds.getSecondsIntoMinute(), millis },
    ) catch unreachable;
    result.len = @intCast(value.len);
    return result;
}

fn wallNowNs(io: std.Io) i96 {
    return std.Io.Clock.Timestamp.now(io, .real).raw.nanoseconds;
}

fn monotonicNowNs(io: std.Io) u64 {
    const value = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
    if (value <= 0) return 0;
    return std.math.cast(u64, value) orelse std.math.maxInt(u64);
}

fn escapeJson(destination: []u8, source: []const u8) []const u8 {
    var count: usize = 0;
    for (source) |byte| {
        const replacement: ?[]const u8 = switch (byte) {
            '"' => "\\\"",
            '\\' => "\\\\",
            '\n' => "\\n",
            '\r' => "\\r",
            '\t' => "\\t",
            else => if (byte < 0x20) "?" else null,
        };
        if (replacement) |bytes| {
            if (count + bytes.len > destination.len) break;
            @memcpy(destination[count..][0..bytes.len], bytes);
            count += bytes.len;
        } else {
            if (count == destination.len) break;
            destination[count] = byte;
            count += 1;
        }
    }
    return destination[0..count];
}

fn entityJson(
    destination: []u8,
    entity: ?engine.gameplay_trace.EntityRef,
) []const u8 {
    const value = entity orelse return "null";
    return std.fmt.bufPrint(
        destination,
        "{{\"namespace\":{d},\"local\":{d},\"incarnation\":{d}}}",
        .{ value.namespace, value.local, value.incarnation },
    ) catch "null";
}

fn jsonU64(line: []const u8, key: []const u8) ?u64 {
    const key_index = std.mem.indexOf(u8, line, key) orelse return null;
    var index = key_index + key.len;
    const start = index;
    while (index < line.len and line[index] >= '0' and line[index] <= '9') : (index += 1) {}
    if (index == start) return null;
    return std.fmt.parseInt(u64, line[start..index], 10) catch null;
}

fn visualOffsetLabel(offset_ms: i16) []const u8 {
    return switch (offset_ms) {
        -5000 => "m5000ms",
        -4000 => "m4000ms",
        -3000 => "m3000ms",
        -2000 => "m2000ms",
        -1000 => "m1000ms",
        0 => "flag",
        1000 => "p1000ms",
        2000 => "p2000ms",
        else => "unclassified",
    };
}

fn humanAnchorBit(offset_ms: i16) u8 {
    return switch (offset_ms) {
        -5000 => 1,
        -4000 => 2,
        -3000 => 4,
        -2000 => 8,
        -1000 => 16,
        0 => 32,
        1000 => 64,
        2000 => 128,
        else => 0,
    };
}

fn signedDeltaMs(value: u64, origin: u64) i64 {
    const magnitude = if (value >= origin) value - origin else origin - value;
    const milliseconds = @min(magnitude / std.time.ns_per_ms, @as(u64, std.math.maxInt(i64)));
    const signed: i64 = @intCast(milliseconds);
    return if (value >= origin) signed else -signed;
}

fn applyRetention(
    io: std.Io,
    allocator: std.mem.Allocator,
    runs_root: []const u8,
) !void {
    var root = try std.Io.Dir.cwd().openDir(io, runs_root, .{ .iterate = true });
    defer root.close(io);
    var candidates = try std.ArrayList([]u8).initCapacity(allocator, retained_unflagged_runs + 8);
    defer {
        for (candidates.items) |name| allocator.free(name);
        candidates.deinit(allocator);
    }
    var iterator = root.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .directory or std.mem.indexOf(u8, entry.name, "_solo_") == null) continue;
        var manifest_path_buffer: [incident.max_path_bytes]u8 = undefined;
        const manifest_path = std.fmt.bufPrint(
            &manifest_path_buffer,
            "{s}/{s}/manifest.json",
            .{ runs_root, entry.name },
        ) catch continue;
        const manifest = std.Io.Dir.cwd().readFileAlloc(
            io,
            manifest_path,
            allocator,
            .limited(4096),
        ) catch continue;
        defer allocator.free(manifest);
        if (std.mem.indexOf(u8, manifest, "\"status\":\"running\"") != null) continue;
        var anomaly_path_buffer: [incident.max_path_bytes]u8 = undefined;
        const anomaly_path = std.fmt.bufPrint(
            &anomaly_path_buffer,
            "{s}/{s}/anomalies.ndjson",
            .{ runs_root, entry.name },
        ) catch continue;
        if (std.Io.Dir.cwd().openFile(io, anomaly_path, .{})) |file| {
            defer file.close(io);
            const stat = file.stat(io) catch continue;
            if (stat.size != 0) continue;
        } else |_| {}
        try candidates.append(allocator, try allocator.dupe(u8, entry.name));
    }
    std.mem.sort([]u8, candidates.items, {}, struct {
        fn lessThan(_: void, left: []u8, right: []u8) bool {
            return std.mem.lessThan(u8, left, right);
        }
    }.lessThan);
    const remove_count = candidates.items.len -| retained_unflagged_runs;
    for (candidates.items[0..remove_count]) |name| try root.deleteTree(io, name);
}

test "JSON note escaping is bounded" {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("a\\\"b\\nc", escapeJson(&buffer, "a\"b\nc"));
}

test "UTC filename is stable and path safe" {
    const value = utcFilename(0);
    try std.testing.expectEqualStrings("1970-01-01T00-00-00.000Z", value.slice());
}

test "human visual anchors cover every whole second from minus five through plus two" {
    var mask: u8 = 0;
    inline for ([_]i16{ -5000, -4000, -3000, -2000, -1000, 0, 1000, 2000 }) |offset_ms| {
        mask |= humanAnchorBit(offset_ms);
        try std.testing.expect(!std.mem.eql(u8, visualOffsetLabel(offset_ms), "unclassified"));
    }
    try std.testing.expectEqual(complete_human_anchor_mask, mask);
    try std.testing.expectEqual(@as(u8, 0), humanAnchorBit(3000));
}

test "NDJSON monotonic timestamp extraction is exact" {
    try std.testing.expectEqual(
        @as(?u64, 42),
        jsonU64("{\"monotonic_ns\":42,\"kind\":\"state\"}", "\"monotonic_ns\":"),
    );
    try std.testing.expectEqual(
        @as(?u64, null),
        jsonU64("{\"kind\":\"state\"}", "\"monotonic_ns\":"),
    );
}

test "writer queue saturation is bounded and explicit" {
    var queue = Queue{};
    for (0..writer_queue_capacity) |_| try std.testing.expect(queue.push(.flush));
    try std.testing.expect(!queue.push(.flush));
    try std.testing.expectEqual(writer_queue_capacity, queue.high_water);
    try std.testing.expectEqual(@as(u64, 1), queue.dropped);
}

test "incident records retain the composed navigation and population budget" {
    try std.testing.expectEqual(@as(usize, 4 * 1024), max_line_bytes);
    try std.testing.expect(@sizeOf(Line) < 5 * 1024);
}

test "writer run budget fails closed with exact byte accounting" {
    var queue = Queue{};
    var writer = Writer{
        .io = std.testing.io,
        .queue = &queue,
        .run_path = "/unused",
        .started_wall_unix_ms = 0,
        .budget_bytes = 16,
    };
    try writer.ensureBudget(16);
    writer.noteBytes(.visual, 16);
    try std.testing.expectEqual(@as(u64, 16), queue.bytes_written);
    try std.testing.expectEqual(@as(u64, 16), queue.visual_bytes_written);
    try std.testing.expectError(error.IncidentRunBudgetExceeded, writer.ensureBudget(1));
    try std.testing.expect(queue.writer_failed);

    queue = .{};
    try std.testing.expectError(error.IncidentRunBudgetExceeded, writer.ensureBudget(17));
    try std.testing.expect(queue.writer_failed);
}

test "visual admission preserves non-visual evidence reserve" {
    var queue = Queue{};
    queue.visual_bytes_reserved = visual_budget_bytes - 16;
    try std.testing.expect(queue.reserveVisual(16));
    try std.testing.expectEqual(visual_budget_bytes, queue.visual_bytes_reserved);
    try std.testing.expect(!queue.reserveVisual(1));
    try std.testing.expect(queue.visual_budget_exhausted);
    try std.testing.expectEqual(@as(u64, 1), queue.visual_budget_rejections);
    try std.testing.expect(!queue.writer_failed);
    queue.releaseVisual(16);
    try std.testing.expectEqual(visual_budget_bytes - 16, queue.visual_bytes_reserved);
}

test "Retina human anchors have a bounded stored extent" {
    const metadata = VisualFrameMetadata{
        .capture_sequence = 1,
        .source = .human_visible,
        .requested_offset_ms = 0,
        .flag_monotonic_ns = 1,
        .target_monotonic_ns = 1,
        .captured_monotonic_ns = 1,
        .submitted_monotonic_ns = 1,
        .completed_monotonic_ns = 1,
        .authority_tick = 1,
        .presentation_frame = 1,
        .drawable_generation = 1,
        .width = 2560,
        .height = 1440,
        .bgra = true,
        .fence_latency_ns = 0,
        .pixel_digest = 0,
        .suspicious = false,
    };
    try std.testing.expectEqual(
        StoredVisualExtent{ .width = 1280, .height = 720 },
        storedVisualExtent(metadata),
    );
    try std.testing.expectEqual(
        @as(u64, 1280 * 720 * 3 + 64),
        visualStorageBytes(metadata),
    );
}

test "incident manifest cohorts source the live protocol and snapshot owners" {
    try std.testing.expectEqual(@as(u16, 5), incident.schema_version);
    try std.testing.expectEqual(session_protocol.wire_version, manifest_protocol_cohort);
    try std.testing.expectEqual(
        sandbox_host_contracts.snapshot_schema,
        manifest_snapshot_cohort,
    );
    try std.testing.expectEqual(@as(u16, 17), manifest_protocol_cohort);
    try std.testing.expectEqual(@as(u16, 15), manifest_snapshot_cohort);
}

test "handoff is available to clipboard before durable writer completion" {
    var queue = Queue{};
    queue.handoff_persisted = true;
    queue.publishHandoff("bounded handoff");
    try std.testing.expect(queue.handoff_ready);
    try std.testing.expect(!queue.handoff_persisted);
    try std.testing.expectEqualStrings("bounded handoff", queue.handoff.slice());
}

test "authored changes retain typed values and are recorded once per transaction" {
    var capture = Capture{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .writer = undefined,
    };
    const id = engine.PersistentId{ .namespace = 9, .local = 3 };
    const request = sandbox_authoring.RelocateRequest{
        .id = id,
        .target_pose = .{ .position = .{ 4, 5, 6 } },
    };
    const pending = sandbox_authoring.PendingSummary{
        .kind = .edit,
        .transaction_id = 41,
        .id = id,
        .request = .{
            .transaction_id = 41,
            .source = .ui,
            .scope = .session,
            .target = .{ .persistent_entity = id },
            .expected_revision = 7,
        },
        .requested = request,
    };
    const evidence = try sandbox_authoring.ChangeEvidence.rejectedBeforeOwnerOutcome(
        pending,
        .owner_unavailable,
        .{
            .run_id = .{ .started_wall_unix_ms = 1, .nonce = 2 },
            .wall_unix_ms = 3,
            .authority_tick = 8,
            .presentation_frame = 12,
        },
    );

    capture.recordAuthoredChange(evidence, 98);
    capture.recordAuthoredChange(evidence, 99);
    const job = capture.queue.pop() orelse return error.AuthoredChangeRecordMissing;
    const line = switch (job) {
        .line => |value| value,
        else => return error.UnexpectedIncidentJob,
    };
    try std.testing.expect(std.mem.indexOf(
        u8,
        line.slice(),
        "\"kind\":\"authored_change\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        line.slice(),
        "\"transaction_id\":41",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        line.slice(),
        "\"requested_pose\":[4,5,6",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        line.slice(),
        "\"rejection\":\"owner_unavailable\"",
    ) != null);
    try std.testing.expect(capture.queue.pop() == null);
}

test "retained fault records name runtime system and authority stage once" {
    var capture = Capture{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .writer = undefined,
    };
    const runtime_fault = engine.runtime.RuntimeFault{
        .phase = .post_physics,
        .tick_index = 2382,
        .journal_sequence = 23,
        .error_code = @intFromError(error.NpcUnexpectedOwnerTransfer),
        .system_name = engine.runtime.FaultText.copy("npc.publish_and_transfer"),
        .error_name = engine.runtime.FaultText.copy("NpcUnexpectedOwnerTransfer"),
    };
    const cycle_fault = authority_diagnostics.CycleFault{
        .stage = .simulation,
        .target_tick = 2382,
        .completed_tick = 2381,
        .error_code = @intFromError(error.NpcUnexpectedOwnerTransfer),
        .error_name = engine.runtime.FaultText.copy("NpcUnexpectedOwnerTransfer"),
    };

    // Queue pressure cannot make the immutable first fault appear recorded.
    // Observe retries on the next frame until both exact records are admitted.
    capture.queue.stopped = true;
    capture.recordRetainedFaults(runtime_fault, cycle_fault, 98);
    try std.testing.expect(!capture.runtime_fault_recorded);
    try std.testing.expect(!capture.authority_cycle_fault_recorded);
    try std.testing.expect(capture.queue.pop() == null);
    capture.queue.stopped = false;

    capture.recordRetainedFaults(runtime_fault, cycle_fault, 99);
    const runtime_job = capture.queue.pop() orelse return error.RuntimeFaultRecordMissing;
    const runtime_line = switch (runtime_job) {
        .line => |line| line,
        else => return error.UnexpectedIncidentJob,
    };
    try std.testing.expect(std.mem.indexOf(
        u8,
        runtime_line.slice(),
        "\"kind\":\"runtime_fault\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        runtime_line.slice(),
        "\"system\":\"npc.publish_and_transfer\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        runtime_line.slice(),
        "\"error\":\"NpcUnexpectedOwnerTransfer\"",
    ) != null);

    const authority_job = capture.queue.pop() orelse
        return error.AuthorityFaultRecordMissing;
    const authority_line = switch (authority_job) {
        .line => |line| line,
        else => return error.UnexpectedIncidentJob,
    };
    try std.testing.expect(std.mem.indexOf(
        u8,
        authority_line.slice(),
        "\"kind\":\"authority_cycle_fault\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        authority_line.slice(),
        "\"stage\":\"simulation\"",
    ) != null);

    capture.recordRetainedFaults(runtime_fault, cycle_fault, 100);
    try std.testing.expect(capture.queue.pop() == null);
}

test "capture creation rejects an unusable root without a compatibility fallback" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "not-a-directory",
        .data = "bounded failure fixture",
    });
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try temporary.dir.realPath(std.testing.io, &root_buffer);
    var invalid_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const invalid = try std.fmt.bufPrint(
        &invalid_buffer,
        "{s}/not-a-directory/runs",
        .{root_buffer[0..root_len]},
    );
    try std.testing.expectError(
        error.NotDir,
        Capture.create(std.testing.allocator, std.testing.io, invalid),
    );
}
