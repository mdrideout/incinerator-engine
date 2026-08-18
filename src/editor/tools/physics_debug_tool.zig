//! Read-only S4-C physics-debug and bounded host-profiler inspection.
//!
//! Every control is a typed request into a fixed host-owned mailbox. This tool
//! never retains a simulation, physics-adapter, renderer, or profiler pointer.

const std = @import("std");
const zgui = @import("zgui");
const engine = @import("incinerator_engine");
const developer_profile = @import("developer_profile");
const developer_visualization = @import("developer_visualization");
const tool_module = @import("../tool.zig");

const VisualizationInput = tool_module.VisualizationInput;
const PhysicsCategory = engine.physics_debug.Category;

const ProfilePhaseSummary = struct {
    count: u64 = 0,
    failures: u64 = 0,
    total_ns: u64 = 0,
    latest_ns: u64 = 0,
    maximum_ns: u64 = 0,
};

pub const descriptor = tool_module.Descriptor{
    .id = .physics_debug,
    .name = "Physics Debug & Profiler",
    .category = .rendering,
    .default_region = .right,
    .purpose = "Inspect collision geometry, spatial ownership overlays, and focused runtime profile spans.",
    .reads = "Immutable developer visualization snapshot and bounded profile rings.",
    .requests = "Emits typed visualization enable/category/selection/profile requests.",
    .examples = &.{ "collision_shapes=true contacts=false", "frame_cpu_ms=4.20" },
    .audit_fields = &.{ "authority_tick", "presentation_frame", "profile_frame", "persistent_id" },
};

fn request(ctx: *const VisualizationInput, value: developer_visualization.Request) void {
    _ = ctx.visualization_requests.push(value);
}

fn drawCategoryToggle(
    ctx: *const VisualizationInput,
    label: [:0]const u8,
    category: PhysicsCategory,
    current: bool,
) void {
    var enabled = current;
    if (zgui.checkbox(label, .{ .v = &enabled })) {
        request(ctx, .{ .set_category = .{
            .category = category,
            .enabled = enabled,
        } });
    }
}

fn drawPrimitiveStats(
    label: []const u8,
    stats: engine.physics_debug.PrimitiveStats,
) void {
    zgui.text(
        "  {s}: admitted {d}/{d}, dropped {d} (overflow {d}, invalid {d})",
        .{
            label,
            stats.admitted,
            stats.attempted,
            stats.dropped,
            stats.overflow_dropped,
            stats.invalid_dropped,
        },
    );
}

fn drawBatchSummary(snapshot: *const developer_visualization.Snapshot) void {
    zgui.separator();
    zgui.text("Bounded physics-debug batch", .{});
    zgui.text("CPU evidence storage available={}", .{snapshot.cpu_available});
    if (!snapshot.cpu_available) {
        zgui.text("Debug geometry unavailable; simulation authority is unaffected.", .{});
    }
    if (snapshot.batch) |batch| {
        zgui.text(
            "tick {d}, generation {d}, lines {d}, triangles {d}, dropped {d}",
            .{
                batch.completed_tick,
                batch.generation,
                batch.line_count,
                batch.triangle_count,
                batch.dropped(),
            },
        );
        inline for (std.meta.tags(PhysicsCategory)) |category| {
            const stats = batch.category_stats[@intFromEnum(category)];
            zgui.text("{s}", .{@tagName(category)});
            if (stats.source_unavailable) {
                zgui.text("  source unavailable; authority remains active", .{});
            }
            drawPrimitiveStats("lines", stats.lines);
            drawPrimitiveStats("triangles", stats.triangles);
        }
    } else {
        zgui.text("No completed debug batch retained.", .{});
    }
}

fn drawGpuSummary(snapshot: *const developer_visualization.Snapshot) void {
    zgui.separator();
    zgui.text("Persistent GPU overlay", .{});
    if (snapshot.gpu) |gpu| {
        zgui.text(
            "available={}, enabled={}, uploaded generation {d}",
            .{ gpu.available, gpu.enabled, gpu.uploaded_generation },
        );
        zgui.text(
            "vertices: lines {d}, triangles {d}; last upload {d} bytes",
            .{ gpu.line_vertices, gpu.triangle_vertices, gpu.upload_bytes },
        );
        zgui.text(
            "uploads {d}, draws {d}, dropped batches {d}, failures {d}",
            .{ gpu.uploads, gpu.draws, gpu.dropped_batches, gpu.failures },
        );
        zgui.text(
            "slots {d}: free {d}, busy {d}, copy-pending {d}, retired {d}",
            .{
                gpu.slot_count,
                gpu.free_slots,
                gpu.busy_slots,
                gpu.copy_pending_slots,
                gpu.retired_slots,
            },
        );
        zgui.text(
            "fences live/peak/max {d}/{d}/{d}; backpressure {d}",
            .{
                gpu.live_fences,
                gpu.peak_fences,
                gpu.max_fences,
                gpu.backpressure_drops,
            },
        );
        zgui.text(
            "post-submit fence failures {d}; lifetime slot retirements {d}",
            .{ gpu.frame_fence_failures, gpu.slot_retirements },
        );
    } else {
        zgui.text("GPU overlay status unavailable.", .{});
    }
}

fn accumulateSpan(summary: *ProfilePhaseSummary, span: developer_profile.Span) void {
    summary.count +|= 1;
    if (span.outcome == .failure) summary.failures +|= 1;
    summary.total_ns +|= span.duration_ns;
    summary.latest_ns = span.duration_ns;
    summary.maximum_ns = @max(summary.maximum_ns, span.duration_ns);
}

fn durationMs(duration_ns: u64) f64 {
    return @as(f64, @floatFromInt(duration_ns)) / @as(f64, std.time.ns_per_ms);
}

fn drawHistoryStats(
    label: []const u8,
    stats: developer_profile.HistoryStats,
) void {
    zgui.text(
        "{s}: {d}/{d}, overwritten {d}, rejected {d}",
        .{ label, stats.count, stats.capacity, stats.overwritten, stats.rejected },
    );
    if (stats.rejected != 0 or stats.sequence_exhausted) {
        zgui.text(
            "  invalid intervals {d}, duplicate finishes {d}, exhausted {d}, sequence exhausted={}",
            .{
                stats.rejected_invalid_interval,
                stats.rejected_duplicate_scope_finish,
                stats.rejected_sequence_exhausted,
                stats.sequence_exhausted,
            },
        );
    }
}

fn drawProfileSummary(ctx: *const VisualizationInput) void {
    zgui.separator();
    zgui.text("Bounded host profiler", .{});
    drawHistoryStats("spans", ctx.profile_stats.spans);
    drawHistoryStats("frames", ctx.profile_stats.frames);

    var phases = [_]ProfilePhaseSummary{.{}} ** std.meta.tags(developer_profile.Phase).len;
    for (ctx.profile_spans.first) |span| {
        accumulateSpan(&phases[@intFromEnum(span.phase)], span);
    }
    for (ctx.profile_spans.second) |span| {
        accumulateSpan(&phases[@intFromEnum(span.phase)], span);
    }

    zgui.text("Phase spans (retained / latest / average / maximum):", .{});
    inline for (std.meta.tags(developer_profile.Phase)) |phase| {
        const summary = phases[@intFromEnum(phase)];
        if (summary.count == 0) {
            zgui.text("  {s}: no samples", .{@tagName(phase)});
        } else {
            const average_ns = summary.total_ns / summary.count;
            zgui.text(
                "  {s}: {d} / {d:.3} / {d:.3} / {d:.3} ms; failures {d}",
                .{
                    @tagName(phase),
                    summary.count,
                    durationMs(summary.latest_ns),
                    durationMs(average_ns),
                    durationMs(summary.maximum_ns),
                    summary.failures,
                },
            );
        }
    }

    zgui.text("Latest retained frame counts:", .{});
    if (ctx.profile_frames.len() == 0) {
        zgui.text("  no completed frame samples", .{});
        return;
    }

    const frame = ctx.profile_frames.at(ctx.profile_frames.len() - 1).?.*;
    zgui.text(
        "  frame {d}, tick {?d}, {d:.3} ms, outcome {s}",
        .{
            frame.frame_index,
            frame.tick_index,
            durationMs(frame.duration_ns),
            @tagName(frame.outcome),
        },
    );
    zgui.text(
        "  draws {d}, debug primitives {d}, debug upload {d} bytes",
        .{
            frame.counts.draw_calls,
            frame.counts.debug_primitives,
            frame.counts.debug_upload_bytes,
        },
    );
    zgui.text(
        "  stream submissions {d}, publishes {d}",
        .{
            frame.counts.streaming_submissions,
            frame.counts.streaming_publishes,
        },
    );
    zgui.text(
        "  live resources {d}, live bytes {d}",
        .{ frame.counts.live_resources, frame.counts.live_resource_bytes },
    );
}

pub fn draw(ctx: *const VisualizationInput) void {
    if (zgui.begin("Physics Debug & Profiler", .{})) {
        const snapshot = ctx.snapshot;

        var visualization_enabled = snapshot.config.enabled;
        if (zgui.checkbox("Enable physics debug overlay", .{ .v = &visualization_enabled })) {
            request(ctx, .{ .set_enabled = visualization_enabled });
        }

        zgui.text("Categories", .{});
        drawCategoryToggle(ctx, "Shapes", .shape, snapshot.config.shapes);
        drawCategoryToggle(ctx, "Bounds", .bounds, snapshot.config.bounds);
        drawCategoryToggle(ctx, "Contacts", .contact, snapshot.config.contacts);
        drawCategoryToggle(
            ctx,
            "Centers of mass",
            .center_of_mass,
            snapshot.config.centers_of_mass,
        );
        drawCategoryToggle(ctx, "Velocities", .velocity, snapshot.config.velocities);

        var profiling_enabled = snapshot.profiling_enabled;
        if (zgui.checkbox("Enable host profiling", .{ .v = &profiling_enabled })) {
            request(ctx, .{ .set_profiling_enabled = profiling_enabled });
        }
        zgui.sameLine(.{});
        if (zgui.button("Clear retained profile history", .{})) {
            request(ctx, .clear_profile_history);
        }
        zgui.text(
            "Visualization request rejections: host {d}, mailbox {d}",
            .{ snapshot.rejected_requests, ctx.visualization_requests.rejected },
        );

        drawBatchSummary(snapshot);
        drawGpuSummary(snapshot);
        drawProfileSummary(ctx);
    }
    zgui.end();
}
