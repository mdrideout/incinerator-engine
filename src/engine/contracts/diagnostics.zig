//! Backend-neutral structured diagnostic records.
//!
//! These types deliberately contain no allocator, backend handle, pointer, or
//! borrowed text. Human-readable rendering belongs to a journal consumer; the
//! stable category/code pair and explicit context remain useful headlessly.

const identity = @import("../identity.zig");

pub const PersistentId = identity.PersistentId;

pub const Severity = enum(u8) {
    trace,
    debug,
    info,
    warning,
    err,
    fatal,
};

pub const Category = enum(u8) {
    general,
    runtime,
    schedule,
    command,
    feature,
    physics,
    content,
    streaming,
    rendering,
    persistence,
    host,
    _,
};

/// Stable logical role of the thread that produced an entry. The optional raw
/// thread ID below is useful for one-run correlation, while this value remains
/// meaningful across runs and operating-system thread-ID implementations.
pub const ThreadRole = enum(u8) {
    unknown,
    host,
    simulation,
    worker,
    rendering,
    content_io,
    audio,
    _,
};

/// Numeric codes are namespaced by convention. Keeping the representation
/// open lets features and adapters define codes without making this contract a
/// central registry that must change whenever a vertical slice is added.
pub const Code = u32;

pub const codes = struct {
    pub const runtime_system_fault: Code = 0x0001_0001;

    // Streaming lifecycle codes. District entries use the load ticket's
    // generation as their stable correlation ID across command boundaries.
    pub const district_load_requested: Code = 0x0008_0001;
    pub const district_cancellation_requested: Code = 0x0008_0002;
    pub const district_cancelled: Code = 0x0008_0003;
    pub const district_load_failed: Code = 0x0008_0004;
    pub const district_activated: Code = 0x0008_0005;
    pub const district_unloaded: Code = 0x0008_0006;

    // Visual-host orchestration for one streamed district. Every entry uses a
    // host-global monotonic lifecycle ID so concurrent registry slots cannot
    // collide while content, logical admission, and GPU residency are traced.
    pub const district_stream_content_requested: Code = 0x0009_0001;
    pub const district_stream_content_cancel_requested: Code = 0x0009_0002;
    pub const district_stream_content_cancelled: Code = 0x0009_0003;
    pub const district_stream_content_ready: Code = 0x0009_0004;
    pub const district_stream_content_failed: Code = 0x0009_0005;
    pub const district_stream_logical_submitted: Code = 0x0009_0010;
    pub const district_stream_logical_cancel_submitted: Code = 0x0009_0011;
    pub const district_stream_logical_unload_submitted: Code = 0x0009_0012;
    pub const district_stream_logical_admitted: Code = 0x0009_0013;
    pub const district_stream_logical_activated: Code = 0x0009_0014;
    pub const district_stream_logical_cancelled: Code = 0x0009_0015;
    pub const district_stream_logical_unloaded: Code = 0x0009_0016;
    pub const district_stream_logical_failed: Code = 0x0009_0017;
    pub const district_stream_gpu_reserved: Code = 0x0009_0020;
    pub const district_stream_gpu_staged: Code = 0x0009_0021;
    pub const district_stream_gpu_submitted: Code = 0x0009_0022;
    pub const district_stream_gpu_resident: Code = 0x0009_0023;
    pub const district_stream_gpu_release_requested: Code = 0x0009_0024;
    pub const district_stream_gpu_drained: Code = 0x0009_0025;
};

/// One immutable journal record. Sequence zero means that a caller-created
/// value has not yet been admitted by a journal; successful admission replaces
/// it with a journal-owned monotonically increasing sequence.
pub const Entry = struct {
    sequence: u64 = 0,
    severity: Severity,
    category: Category,
    code: Code,
    tick_index: ?u64 = null,
    frame_index: ?u64 = null,
    thread_role: ThreadRole = .unknown,
    thread_id: ?u64 = null,
    persistent_id: ?PersistentId = null,
    correlation_id: u64 = 0,
};

/// Shared queue instrumentation used by typed feature/adapter snapshots.
/// `capacity == null` identifies a currently unbounded implementation without
/// pretending it has bounded saturation behavior.
pub const QueueStats = struct {
    occupancy: u32 = 0,
    high_water: u32 = 0,
    capacity: ?u32 = null,
    rejected: u64 = 0,
};

test "diagnostic entry carries optional backend-neutral context" {
    const value = Entry{
        .severity = .warning,
        .category = .streaming,
        .code = 7,
        .tick_index = 19,
        .frame_index = 4,
        .thread_role = .worker,
        .thread_id = 3,
        .persistent_id = .{ .namespace = 2, .local = 8 },
        .correlation_id = 11,
    };
    try @import("std").testing.expectEqual(@as(?u64, 19), value.tick_index);
    try @import("std").testing.expectEqual(ThreadRole.worker, value.thread_role);
    try @import("std").testing.expectEqual(@as(?u64, 3), value.thread_id);
    try @import("std").testing.expectEqual(
        PersistentId{ .namespace = 2, .local = 8 },
        value.persistent_id.?,
    );
}
