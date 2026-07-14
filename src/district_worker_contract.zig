//! Canonical immutable state reported by the procedural district worker.
//!
//! Thread ownership, synchronization, and procedural work remain in the
//! adapter implementation. Hosts and diagnostics consume only these values.

const std = @import("std");

pub const WorkerState = enum {
    idle,
    queued,
    working,
    cancelling,
    completion_ready,
};

pub const CompletionKind = enum {
    ready,
    cancelled,
    failed,
};

pub const Diagnostics = struct {
    state: WorkerState,
    generation: ?u64,
    started: bool,
    cancellation_requested: bool,
    completion_kind: ?CompletionKind,
};

test "worker diagnostics are copied values" {
    const value = Diagnostics{
        .state = .idle,
        .generation = null,
        .started = false,
        .cancellation_requested = false,
        .completion_kind = null,
    };
    try std.testing.expectEqual(WorkerState.idle, value.state);
}
