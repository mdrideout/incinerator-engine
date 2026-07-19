//! SDL/GPU-free schema-2 validator and concise incident-bundle index.

const std = @import("std");

const schema_version: u16 = 2;
const maximum_manifest_bytes = 64 * 1024;
const maximum_segment_bytes = 8 * 1024 * 1024;
const maximum_anomalies = 64;

const EvidenceCapabilities = struct {
    characters: []const u8,
    npcs: []const u8,
    vehicles: []const u8,
    carryables: []const u8,
    semantic_vehicle_parts: bool,
    atomic_note_handoff: bool,
};

const Manifest = struct {
    schema: u16,
    kind: []const u8,
    status: []const u8,
    platform: []const u8,
    topology: []const u8,
    source_revision: []const u8,
    source_dirty: bool,
    source_dirty_fingerprint: []const u8,
    zig_version: []const u8,
    optimize: []const u8,
    evidence_capabilities: ?EvidenceCapabilities = null,
    started_wall_unix_ms: i64,
    updated_wall_unix_ms: i64,
    updated_monotonic_ns: u64,
    stream_rotation_bytes: u64,
    run_budget_bytes: u64,
    visual_budget_bytes: ?u64 = null,
    non_visual_reserve_bytes: ?u64 = null,
    visual_bytes_reserved: ?u64 = null,
    visual_budget_exhausted: ?bool = null,
    visual_budget_rejections: ?u64 = null,
    handoff_persisted: ?bool = null,
    writer_queue_capacity: usize,
    writer_queue: usize,
    queue_high_water: usize,
    dropped_records: u64,
    writer_failed: bool,
    last_admitted_sequence: u64,
    last_durable_sequence: u64,
    bytes_written: u64,
    bytes_by_class: struct {
        streams: u64,
        visual: u64,
        replay: u64,
        metadata: u64,
    },
    screenshot_misses: u64,
    anomaly_count: usize,
    replay_status: []const u8,
    privacy: struct {
        local_only: bool,
        captures_text_input: bool,
        captures_credentials: bool,
        captures_reserved_shortcut_candidates: bool,
    },
};

const Lifecycle = enum { unknown, capturing, complete, partial };

const AnomalyEvent = struct {
    schema: u16,
    kind: []const u8,
    recorder_sequence: u64,
    monotonic_ns: u64,
    wall_unix_ms: i64,
    authority_tick: u64,
    presentation_frame: u64,
    anomaly_id: u32,
    event: []const u8,
    lifecycle_status: []const u8,
    note: []const u8,
};

const AnomalySummary = struct {
    seen: bool = false,
    flagged: bool = false,
    finalized: bool = false,
    id: u32 = 0,
    tick: u64 = 0,
    frame: u64 = 0,
    flag_monotonic_ns: u64 = 0,
    lifecycle: Lifecycle = .unknown,
    updates: u32 = 0,
};

const Marker = struct {
    schema: u16,
    kind: []const u8,
    anomaly_id: u32,
    lifecycle_status: []const u8,
    authority_tick: u64,
    presentation_frame: u64,
    wall_unix_ms: i64,
    flag_monotonic_ns: u64,
    window_start_ns: u64,
    window_end_ns: u64,
    artifacts: struct {
        count: u32,
        failures: u32,
        human_m2000ms: bool,
        human_m1000ms: bool,
        human_flag: bool,
        human_p1000ms: bool,
        human_p3000ms: bool,
        product_flag: bool,
        semantic_id_flag: bool,
    },
    semantic_id_status: []const u8,
    note: []const u8,
};

const VisualFrame = struct {
    schema: u16,
    kind: []const u8,
    anomaly_id: u32,
    capture_sequence: u64,
    source: []const u8,
    requested_offset_ms: ?i64,
    target_monotonic_ns: u64,
    captured_monotonic_ns: u64,
    actual_offset_ms: i64,
    submitted_monotonic_ns: u64,
    completed_monotonic_ns: u64,
    writer_observed_monotonic_ns: u64,
    authority_tick: u64,
    presentation_frame: u64,
    drawable_generation: u64,
    width: u32,
    height: u32,
    pixel_format: []const u8,
    fence_latency_ns: u64,
    pixel_digest: []const u8,
    suspicious: bool,
    path: []const u8,
};

const SemanticMap = struct {
    schema: u16,
    kind: []const u8,
    anomaly_id: u32,
    capture_sequence: u64,
    width: u32,
    height: u32,
    entries: []const struct {
        object_id: u32,
        entity: struct {
            namespace: u64,
            local: u64,
            incarnation: u32,
        },
        color_rgb: [3]u8,
    },
};

const Counts = struct {
    segments: usize = 0,
    records: usize = 0,
    invalid: usize = 0,
    windows: usize = 0,
    visual_records: usize = 0,
    suspicious_visuals: usize = 0,
    warnings: usize = 0,
};

const DiagnosticCount = struct {
    code: u32,
    count: u32,
};

const DiagnosticSummary = struct {
    const capacity: usize = 32;

    items: [capacity]DiagnosticCount = undefined,
    len: u8 = 0,
    overflow: u32 = 0,

    fn note(self: *DiagnosticSummary, code: u32) void {
        for (self.items[0..self.len]) |*item| {
            if (item.code != code) continue;
            item.count +|= 1;
            return;
        }
        if (self.len == self.items.len) {
            self.overflow +|= 1;
            return;
        }
        self.items[self.len] = .{ .code = code, .count = 1 };
        self.len += 1;
    }
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len == 2 and std.mem.eql(u8, args[1], "--help")) {
        printUsage();
        return;
    }
    if (args.len != 2) {
        printUsage();
        return error.InvalidArguments;
    }
    try inspect(init, args[1]);
}

fn printUsage() void {
    std.debug.print("usage: incinerator_incident_inspect <run-folder>\n", .{});
}

fn inspect(init: std.process.Init, run_path: []const u8) !void {
    const manifest_path = try join(init, &.{ run_path, "manifest.json" });
    defer init.gpa.free(manifest_path);
    const manifest_bytes = try read(init, manifest_path, maximum_manifest_bytes);
    defer init.gpa.free(manifest_bytes);
    var parsed_manifest = try std.json.parseFromSlice(Manifest, init.gpa, manifest_bytes, .{
        .ignore_unknown_fields = true,
    });
    defer parsed_manifest.deinit();
    const manifest = parsed_manifest.value;
    if (manifest.schema != schema_version or
        !std.mem.eql(u8, manifest.kind, "incinerator_incident_run") or
        !manifest.privacy.local_only or manifest.privacy.captures_text_input or
        manifest.privacy.captures_credentials or
        !manifest.privacy.captures_reserved_shortcut_candidates)
    {
        return error.InvalidIncidentManifest;
    }
    if (!std.mem.eql(u8, manifest.platform, "macos-aarch64") or
        !std.mem.eql(u8, manifest.topology, "solo"))
    {
        return error.UnsupportedIncidentCohort;
    }
    if (manifest.writer_queue > manifest.writer_queue_capacity or
        manifest.queue_high_water > manifest.writer_queue_capacity or
        manifest.last_durable_sequence > manifest.last_admitted_sequence)
    {
        return error.InvalidIncidentHealth;
    }
    const classified_bytes = manifest.bytes_by_class.streams +|
        manifest.bytes_by_class.visual +| manifest.bytes_by_class.replay +|
        manifest.bytes_by_class.metadata;
    if (classified_bytes != manifest.bytes_written or
        manifest.bytes_written > manifest.run_budget_bytes)
    {
        return error.InvalidIncidentByteAccounting;
    }
    const has_visual_partition = manifest.visual_budget_bytes != null;
    if (has_visual_partition != (manifest.non_visual_reserve_bytes != null) or
        has_visual_partition != (manifest.visual_bytes_reserved != null) or
        has_visual_partition != (manifest.visual_budget_exhausted != null) or
        has_visual_partition != (manifest.visual_budget_rejections != null) or
        has_visual_partition != (manifest.handoff_persisted != null))
    {
        return error.IncompleteIncidentBudgetPartition;
    }
    if (has_visual_partition) {
        const visual_budget = manifest.visual_budget_bytes.?;
        const non_visual_reserve = manifest.non_visual_reserve_bytes.?;
        const visual_reserved = manifest.visual_bytes_reserved.?;
        const visual_exhausted = manifest.visual_budget_exhausted.?;
        const visual_rejections = manifest.visual_budget_rejections.?;
        if (visual_budget +| non_visual_reserve != manifest.run_budget_bytes or
            visual_reserved > visual_budget or
            manifest.bytes_by_class.visual > visual_reserved or
            (visual_exhausted != (visual_rejections != 0)))
        {
            return error.InvalidIncidentBudgetPartition;
        }
    }

    var counts = Counts{};
    if (std.mem.eql(u8, manifest.status, "running")) {
        counts.warnings += 1;
        std.debug.print(
            "WARN live_bundle: manifest is a current partial-in-time snapshot at wall_unix_ms={d}\n",
            .{manifest.updated_wall_unix_ms},
        );
    } else if (!std.mem.eql(u8, manifest.status, "complete") and
        !std.mem.eql(u8, manifest.status, "partial"))
    {
        return error.InvalidIncidentStatus;
    }
    if (manifest.writer_failed or manifest.dropped_records != 0 or
        manifest.screenshot_misses != 0)
    {
        counts.warnings += 1;
        std.debug.print(
            "WARN evidence_health: writer_failed={} dropped={d} screenshot_misses={d}\n",
            .{ manifest.writer_failed, manifest.dropped_records, manifest.screenshot_misses },
        );
    }
    if (manifest.visual_budget_exhausted orelse false) {
        counts.warnings += 1;
        std.debug.print(
            "WARN visual_budget: reserved={d}/{d} rejected={d}; non-visual evidence remains protected\n",
            .{ manifest.visual_bytes_reserved.?, manifest.visual_budget_bytes.?, manifest.visual_budget_rejections.? },
        );
    }
    if (manifest.evidence_capabilities) |capabilities| {
        if (!std.mem.eql(u8, capabilities.characters, "full_boundary") or
            !std.mem.eql(u8, capabilities.npcs, "full_boundary") or
            !std.mem.eql(u8, capabilities.vehicles, "full_boundary") or
            !std.mem.eql(u8, capabilities.carryables, "full_boundary") or
            !capabilities.semantic_vehicle_parts or
            !capabilities.atomic_note_handoff)
        {
            return error.InvalidEvidenceCapabilities;
        }
        std.debug.print(
            "  capabilities characters={s} npcs={s} vehicles={s} carryables={s} vehicle_parts={} atomic_note={}\n",
            .{ capabilities.characters, capabilities.npcs, capabilities.vehicles, capabilities.carryables, capabilities.semantic_vehicle_parts, capabilities.atomic_note_handoff },
        );
    } else {
        counts.warnings += 1;
        std.debug.print(
            "WARN capability_matrix: bundle predates explicit per-entity evidence coverage\n",
            .{},
        );
    }

    var anomalies: [maximum_anomalies]AnomalySummary = @splat(.{});
    const anomaly_path = try join(init, &.{ run_path, "anomalies.ndjson" });
    defer init.gpa.free(anomaly_path);
    const live_bundle = std.mem.eql(u8, manifest.status, "running");
    if (fileExists(init, anomaly_path)) {
        try reduceAnomalies(init, anomaly_path, &anomalies, &counts);
    } else if (!live_bundle or manifest.anomaly_count != 0) {
        return error.MissingAnomalyIndex;
    }

    const streams_path = try join(init, &.{ run_path, "streams" });
    defer init.gpa.free(streams_path);
    var streams = try std.Io.Dir.cwd().openDir(init.io, streams_path, .{ .iterate = true });
    defer streams.close(init.io);
    var walker = try streams.walk(init.gpa);
    defer walker.deinit();
    while (try walker.next(init.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".ndjson")) continue;
        const path = try join(init, &.{ streams_path, entry.path });
        defer init.gpa.free(path);
        try validateNdjson(init, path, null, null, &counts, null);
        counts.segments += 1;
    }

    var anomaly_total: usize = 0;
    for (&anomalies) |*summary| {
        if (!summary.seen) continue;
        anomaly_total += 1;
        try inspectAnomaly(init, run_path, summary, live_bundle, &counts);
    }
    if (anomaly_total != manifest.anomaly_count or counts.invalid != 0) {
        return error.InvalidIncidentRecord;
    }

    const replay_present = exists(init, run_path, "replay/accepted-ingress.icrp");
    if (std.mem.eql(u8, manifest.replay_status, "attached") != replay_present) {
        return error.InvalidReplayAttachmentStatus;
    }
    const handoff_present = exists(init, run_path, "LLM_HANDOFF.md");

    std.debug.print(
        "INCIDENT_BUNDLE_VALID run={s}\n" ++
            "  status={s} source={s} dirty={} build={s}/{s}\n" ++
            "  records={d} segments={d} anomalies={d} windows={d} visuals={d} suspicious={d}\n" ++
            "  queue={d} high_water={d}/{d} durable={d}/{d} bytes={d}/{d}\n" ++
            "  visual_reserved={d}/{d} rejected={d} replay={} handoff={} persisted={} warnings={d}\n",
        .{
            run_path,
            manifest.status,
            manifest.source_revision,
            manifest.source_dirty,
            manifest.zig_version,
            manifest.optimize,
            counts.records,
            counts.segments,
            anomaly_total,
            counts.windows,
            counts.visual_records,
            counts.suspicious_visuals,
            manifest.writer_queue,
            manifest.queue_high_water,
            manifest.writer_queue_capacity,
            manifest.last_durable_sequence,
            manifest.last_admitted_sequence,
            manifest.bytes_written,
            manifest.run_budget_bytes,
            manifest.visual_bytes_reserved orelse 0,
            manifest.visual_budget_bytes orelse 0,
            manifest.visual_budget_rejections orelse 0,
            replay_present,
            handoff_present,
            manifest.handoff_persisted orelse false,
            counts.warnings,
        },
    );
}

fn reduceAnomalies(
    init: std.process.Init,
    path: []const u8,
    summaries: *[maximum_anomalies]AnomalySummary,
    counts: *Counts,
) !void {
    const bytes = try read(init, path, maximum_segment_bytes);
    defer init.gpa.free(bytes);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var parsed = std.json.parseFromSlice(AnomalyEvent, init.gpa, line, .{
            .ignore_unknown_fields = true,
        }) catch {
            counts.invalid += 1;
            continue;
        };
        defer parsed.deinit();
        const event = parsed.value;
        counts.records += 1;
        if (event.schema != schema_version or
            !std.mem.eql(u8, event.kind, "anomaly_index") or event.anomaly_id == 0 or
            event.anomaly_id > maximum_anomalies)
        {
            counts.invalid += 1;
            continue;
        }
        const lifecycle = parseLifecycle(event.lifecycle_status) orelse {
            counts.invalid += 1;
            continue;
        };
        const summary = &summaries[event.anomaly_id - 1];
        summary.seen = true;
        summary.id = event.anomaly_id;
        summary.updates +|= 1;
        if (std.mem.eql(u8, event.event, "flagged")) {
            if (summary.flagged or lifecycle != .capturing) {
                counts.invalid += 1;
                continue;
            }
            summary.flagged = true;
            summary.tick = event.authority_tick;
            summary.frame = event.presentation_frame;
            summary.flag_monotonic_ns = event.monotonic_ns;
            summary.lifecycle = lifecycle;
        } else if (std.mem.eql(u8, event.event, "note_updated")) {
            if (!summary.flagged or lifecycle != summary.lifecycle) counts.invalid += 1;
        } else if (std.mem.eql(u8, event.event, "post_roll_finalized")) {
            if (!summary.flagged or summary.finalized or lifecycle == .capturing) {
                counts.invalid += 1;
                continue;
            }
            summary.finalized = true;
            summary.lifecycle = lifecycle;
        } else if (std.mem.eql(u8, event.event, "handoff_refreshed")) {
            if (!summary.flagged or lifecycle != summary.lifecycle) counts.invalid += 1;
        } else {
            counts.invalid += 1;
        }
    }
}

fn inspectAnomaly(
    init: std.process.Init,
    run_path: []const u8,
    summary: *const AnomalySummary,
    live_bundle: bool,
    counts: *Counts,
) !void {
    if (!summary.flagged) return error.InvalidAnomalyLifecycle;
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory = try std.fmt.bufPrint(
        &directory_buffer,
        "{s}/anomalies/anomaly-{d:0>4}",
        .{ run_path, summary.id },
    );
    const marker_path = try join(init, &.{ directory, "marker.json" });
    defer init.gpa.free(marker_path);
    if (!fileExists(init, marker_path)) {
        if (!live_bundle or summary.lifecycle != .capturing or summary.finalized) {
            return error.MissingIncidentMarker;
        }
        counts.warnings += 1;
        std.debug.print(
            "  anomaly #{d} tick={d} frame={d} lifecycle=capturing " ++
                "updates={d} marker=pending (live partial-in-time)\n",
            .{ summary.id, summary.tick, summary.frame, summary.updates },
        );
        return;
    }
    const marker_bytes = try read(init, marker_path, maximum_manifest_bytes);
    defer init.gpa.free(marker_bytes);
    var parsed_marker = try std.json.parseFromSlice(Marker, init.gpa, marker_bytes, .{
        .ignore_unknown_fields = true,
    });
    defer parsed_marker.deinit();
    const marker = parsed_marker.value;
    const marker_lifecycle = parseLifecycle(marker.lifecycle_status) orelse
        return error.InvalidMarkerLifecycle;
    if (marker.schema != schema_version or
        !std.mem.eql(u8, marker.kind, "incident_marker") or
        marker.anomaly_id != summary.id or marker.authority_tick != summary.tick or
        marker.presentation_frame != summary.frame or marker_lifecycle != summary.lifecycle or
        marker.window_start_ns > marker.flag_monotonic_ns or
        marker.window_end_ns < marker.flag_monotonic_ns)
    {
        return error.InvalidIncidentMarker;
    }
    if (marker_lifecycle != .capturing and !summary.finalized) {
        return error.MissingAnomalyFinalization;
    }

    var diagnostics = DiagnosticSummary{};
    inline for ([_][]const u8{ "timeline", "state", "input", "metrics" }) |stream| {
        const window_name = try std.fmt.allocPrint(init.gpa, "{s}-window.ndjson", .{stream});
        defer init.gpa.free(window_name);
        const window_path = try join(init, &.{ directory, window_name });
        defer init.gpa.free(window_path);
        try validateNdjson(
            init,
            window_path,
            marker.window_start_ns,
            marker.window_end_ns,
            counts,
            if (std.mem.eql(u8, stream, "timeline")) &diagnostics else null,
        );
        counts.windows += 1;
    }

    const visual_path = try join(init, &.{ directory, "visual-index.ndjson" });
    defer init.gpa.free(visual_path);
    const visual_count = if (fileExists(init, visual_path))
        try inspectVisualIndex(init, run_path, visual_path, marker, counts)
    else
        0;
    if (visual_count != marker.artifacts.count) return error.InvalidArtifactCount;
    if (marker.artifacts.semantic_id_flag !=
        existsAbsolute(init, directory, "semantic-id-map.json"))
    {
        return error.InvalidSemanticMapStatus;
    }
    if (marker.artifacts.semantic_id_flag) {
        try validateSemanticMap(init, directory, marker.anomaly_id);
    }

    std.debug.print(
        "  anomaly #{d} tick={d} frame={d} lifecycle={s} updates={d} " ++
            "artifacts={d} failures={d} typed_window=[-{d},{d}]ms note=\"{s}\"\n",
        .{
            marker.anomaly_id,
            marker.authority_tick,
            marker.presentation_frame,
            marker.lifecycle_status,
            summary.updates,
            marker.artifacts.count,
            marker.artifacts.failures,
            @divFloor(marker.flag_monotonic_ns -| marker.window_start_ns, std.time.ns_per_ms),
            @divFloor(marker.window_end_ns -| marker.flag_monotonic_ns, std.time.ns_per_ms),
            marker.note,
        },
    );
    for (diagnostics.items[0..diagnostics.len]) |item| {
        std.debug.print(
            "    diagnostic 0x{x:0>8} {s} count={d}\n",
            .{ item.code, diagnosticName(item.code), item.count },
        );
    }
    if (diagnostics.overflow != 0) {
        std.debug.print("    diagnostic overflow count={d}\n", .{diagnostics.overflow});
    }
}

fn validateSemanticMap(
    init: std.process.Init,
    directory: []const u8,
    anomaly_id: u32,
) !void {
    const path = try join(init, &.{ directory, "semantic-id-map.json" });
    defer init.gpa.free(path);
    const bytes = try read(init, path, maximum_manifest_bytes);
    defer init.gpa.free(bytes);
    var parsed = try std.json.parseFromSlice(SemanticMap, init.gpa, bytes, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    const map = parsed.value;
    if (map.schema != schema_version or
        !std.mem.eql(u8, map.kind, "semantic_id_map") or
        map.anomaly_id != anomaly_id or map.capture_sequence == 0 or
        map.width == 0 or map.height == 0 or map.entries.len == 0 or
        map.entries.len > 128)
    {
        return error.InvalidSemanticMap;
    }
    for (map.entries, 0..) |entry, index| {
        const expected_id: u32 = @intCast(index + 1);
        if (entry.object_id != expected_id or entry.entity.namespace == 0 or
            entry.entity.local == 0 or entry.entity.incarnation == 0 or
            !std.meta.eql(entry.color_rgb, semanticColor(expected_id)))
        {
            return error.InvalidSemanticMap;
        }
    }
}

fn semanticColor(object_id: u32) [3]u8 {
    return .{
        @intCast(64 + (object_id *% 97) % 192),
        @intCast(64 + (object_id *% 57) % 192),
        @intCast(64 + (object_id *% 31) % 192),
    };
}

fn inspectVisualIndex(
    init: std.process.Init,
    run_path: []const u8,
    path: []const u8,
    marker: Marker,
    counts: *Counts,
) !u32 {
    const bytes = try read(init, path, maximum_segment_bytes);
    defer init.gpa.free(bytes);
    var record_count: u32 = 0;
    var human_mask: u5 = 0;
    var product_flag = false;
    var semantic_id = false;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var parsed = try std.json.parseFromSlice(VisualFrame, init.gpa, line, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        const visual = parsed.value;
        if (visual.schema != schema_version or
            !std.mem.eql(u8, visual.kind, "visual_frame") or
            visual.anomaly_id != marker.anomaly_id or visual.width == 0 or visual.height == 0 or
            visual.submitted_monotonic_ns > visual.completed_monotonic_ns or
            visual.completed_monotonic_ns > visual.writer_observed_monotonic_ns or
            visual.actual_offset_ms != signedDeltaMs(
                visual.captured_monotonic_ns,
                marker.flag_monotonic_ns,
            ))
        {
            return error.InvalidVisualMetadata;
        }
        const expected_latency = visual.completed_monotonic_ns -| visual.submitted_monotonic_ns;
        if (expected_latency != visual.fence_latency_ns) return error.InvalidFenceLatency;
        if (!std.mem.eql(u8, visual.pixel_format, "rgba8") and
            !std.mem.eql(u8, visual.pixel_format, "bgra8"))
        {
            return error.InvalidVisualPixelFormat;
        }
        const absolute = try join(init, &.{ run_path, visual.path });
        defer init.gpa.free(absolute);
        try validatePpmLength(init, absolute, visual.width, visual.height);

        if (std.mem.eql(u8, visual.source, "human_visible")) {
            const requested = visual.requested_offset_ms orelse
                return error.MissingVisualRequestedOffset;
            human_mask |= switch (requested) {
                -2000 => 1,
                -1000 => 2,
                0 => 4,
                1000 => 8,
                3000 => 16,
                else => return error.InvalidHumanVisualOffset,
            };
        } else if (std.mem.eql(u8, visual.source, "product_flag")) {
            product_flag = true;
        } else if (std.mem.eql(u8, visual.source, "semantic_id")) {
            semantic_id = true;
        } else if (!std.mem.eql(u8, visual.source, "product_trail")) {
            return error.InvalidVisualSource;
        }
        if (visual.suspicious) {
            counts.suspicious_visuals += 1;
            counts.warnings += 1;
        }
        counts.visual_records += 1;
        record_count += 1;
    }
    const expected_human_mask: u5 = @as(u5, @intFromBool(marker.artifacts.human_m2000ms)) |
        (@as(u5, @intFromBool(marker.artifacts.human_m1000ms)) << 1) |
        (@as(u5, @intFromBool(marker.artifacts.human_flag)) << 2) |
        (@as(u5, @intFromBool(marker.artifacts.human_p1000ms)) << 3) |
        (@as(u5, @intFromBool(marker.artifacts.human_p3000ms)) << 4);
    if (human_mask != expected_human_mask or
        product_flag != marker.artifacts.product_flag or
        semantic_id != marker.artifacts.semantic_id_flag)
    {
        return error.VisualArtifactMarkerMismatch;
    }
    return record_count;
}

fn validateNdjson(
    init: std.process.Init,
    path: []const u8,
    minimum_ns: ?u64,
    maximum_ns: ?u64,
    counts: *Counts,
    diagnostics: ?*DiagnosticSummary,
) !void {
    const bytes = try read(init, path, maximum_segment_bytes);
    defer init.gpa.free(bytes);
    var last_sequence: u64 = 0;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var parsed = std.json.parseFromSlice(std.json.Value, init.gpa, line, .{}) catch {
            counts.invalid += 1;
            continue;
        };
        defer parsed.deinit();
        const object = switch (parsed.value) {
            .object => |value| value,
            else => {
                counts.invalid += 1;
                continue;
            },
        };
        const schema = object.get("schema") orelse {
            counts.invalid += 1;
            continue;
        };
        const kind = object.get("kind") orelse {
            counts.invalid += 1;
            continue;
        };
        if (schema != .integer or schema.integer != schema_version or kind != .string) {
            counts.invalid += 1;
            continue;
        }
        const sequence = object.get("recorder_sequence") orelse {
            counts.invalid += 1;
            continue;
        };
        if (sequence != .integer or sequence.integer <= 0 or
            @as(u64, @intCast(sequence.integer)) <= last_sequence)
        {
            counts.invalid += 1;
            continue;
        }
        last_sequence = @intCast(sequence.integer);
        if (minimum_ns != null or maximum_ns != null) {
            const timestamp = object.get("monotonic_ns") orelse {
                counts.invalid += 1;
                continue;
            };
            if (timestamp != .integer or timestamp.integer < 0) {
                counts.invalid += 1;
                continue;
            }
            const value: u64 = @intCast(timestamp.integer);
            if ((minimum_ns != null and value < minimum_ns.?) or
                (maximum_ns != null and value > maximum_ns.?))
            {
                counts.invalid += 1;
                continue;
            }
        }
        if (diagnostics) |summary| {
            if (std.mem.eql(u8, kind.string, "diagnostic")) {
                const code = object.get("code") orelse {
                    counts.invalid += 1;
                    continue;
                };
                if (code != .integer or code.integer < 0 or
                    code.integer > std.math.maxInt(u32))
                {
                    counts.invalid += 1;
                    continue;
                }
                summary.note(@intCast(code.integer));
            }
        }
        counts.records += 1;
    }
}

fn diagnosticName(code: u32) []const u8 {
    return switch (code) {
        0x0001_0001 => "runtime_system_fault",
        0x0008_0001 => "district_load_requested",
        0x0008_0002 => "district_cancellation_requested",
        0x0008_0003 => "district_cancelled",
        0x0008_0004 => "district_load_failed",
        0x0008_0005 => "district_activated",
        0x0008_0006 => "district_unloaded",
        0x0009_0001 => "district_stream_content_requested",
        0x0009_0002 => "district_stream_content_cancel_requested",
        0x0009_0003 => "district_stream_content_cancelled",
        0x0009_0004 => "district_stream_content_ready",
        0x0009_0005 => "district_stream_content_failed",
        0x0009_0010 => "district_stream_logical_submitted",
        0x0009_0011 => "district_stream_logical_cancel_submitted",
        0x0009_0012 => "district_stream_logical_unload_submitted",
        0x0009_0013 => "district_stream_logical_admitted",
        0x0009_0014 => "district_stream_logical_activated",
        0x0009_0015 => "district_stream_logical_cancelled",
        0x0009_0016 => "district_stream_logical_unloaded",
        0x0009_0017 => "district_stream_logical_failed",
        0x0009_0020 => "district_stream_gpu_reserved",
        0x0009_0021 => "district_stream_gpu_staged",
        0x0009_0022 => "district_stream_gpu_submitted",
        0x0009_0023 => "district_stream_gpu_resident",
        0x0009_0024 => "district_stream_gpu_release_requested",
        0x0009_0025 => "district_stream_gpu_drained",
        0x000b_0001 => "host_control_applied",
        0x000b_0002 => "host_control_rejected",
        else => "unregistered",
    };
}

fn validatePpmLength(
    init: std.process.Init,
    path: []const u8,
    width: u32,
    height: u32,
) !void {
    const file = try std.Io.Dir.cwd().openFile(init.io, path, .{});
    defer file.close(init.io);
    const minimum_pixels = try std.math.mul(u64, width, height);
    const minimum_bytes = try std.math.mul(u64, minimum_pixels, 3);
    if (try file.length(init.io) <= minimum_bytes) return error.TruncatedVisualArtifact;
}

fn parseLifecycle(value: []const u8) ?Lifecycle {
    inline for (.{ .capturing, .complete, .partial }) |candidate| {
        if (std.mem.eql(u8, value, @tagName(candidate))) return candidate;
    }
    return null;
}

fn signedDeltaMs(value: u64, origin: u64) i64 {
    if (value >= origin) return @intCast((value - origin) / std.time.ns_per_ms);
    return -@as(i64, @intCast((origin - value) / std.time.ns_per_ms));
}

fn exists(init: std.process.Init, root: []const u8, child: []const u8) bool {
    return existsAbsolute(init, root, child);
}

fn existsAbsolute(init: std.process.Init, root: []const u8, child: []const u8) bool {
    const path = join(init, &.{ root, child }) catch return false;
    defer init.gpa.free(path);
    return fileExists(init, path);
}

fn fileExists(init: std.process.Init, path: []const u8) bool {
    const file = std.Io.Dir.cwd().openFile(init.io, path, .{}) catch return false;
    file.close(init.io);
    return true;
}

fn join(init: std.process.Init, parts: []const []const u8) ![]u8 {
    return std.fs.path.join(init.gpa, parts);
}

fn read(init: std.process.Init, path: []const u8, limit: usize) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(init.io, path, init.gpa, .limited(limit));
}
