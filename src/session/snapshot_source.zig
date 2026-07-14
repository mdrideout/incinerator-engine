//! Type-erased request/result port for authority-cycle durable capture.
//!
//! The source is handed to the persistence owner at composition time. Runtime
//! graphical code receives only typed observations and commit feedback.

const std = @import("std");

pub const RequestId = u64;

pub const Deferral = enum {
    session_work,
    simulation_commands,
    district_transition,
    authority_outputs,
};

pub const Disposition = union(enum) {
    deferred: Deferral,
    captured: []u8,
    failed: anyerror,
};

pub const Source = struct {
    context: *anyopaque,
    observe_fn: *const fn (*anyopaque, std.mem.Allocator) anyerror![]u8,
    request_fn: *const fn (*anyopaque) anyerror!RequestId,
    take_fn: *const fn (*anyopaque, RequestId) anyerror!?Disposition,
    release_fn: *const fn (*anyopaque, []u8) void,

    /// Validation/diagnostic observation only. Durable commits use request /
    /// take and are decided at authority-cycle stage seven.
    pub fn observe(self: Source, allocator: std.mem.Allocator) anyerror![]u8 {
        return self.observe_fn(self.context, allocator);
    }

    pub fn request(self: Source) anyerror!RequestId {
        return self.request_fn(self.context);
    }

    pub fn take(self: Source, request_id: RequestId) anyerror!?Disposition {
        return self.take_fn(self.context, request_id);
    }

    pub fn release(self: Source, bytes: []u8) void {
        self.release_fn(self.context, bytes);
    }
};

test "source transfers request disposition through an opaque authority context" {
    const Fixture = struct {
        bytes: []u8,
        requested: bool = false,

        fn request(context: *anyopaque) anyerror!RequestId {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (self.requested) return error.CaptureBusy;
            self.requested = true;
            return 1;
        }

        fn observe(context: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            return allocator.dupe(u8, self.bytes);
        }

        fn take(context: *anyopaque, request_id: RequestId) anyerror!?Disposition {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (!self.requested or request_id != 1) return error.UnknownCaptureRequest;
            self.requested = false;
            return .{ .captured = self.bytes };
        }

        fn release(_: *anyopaque, _: []u8) void {}
    };
    var bytes = [_]u8{ 1, 2, 3 };
    var fixture = Fixture{ .bytes = &bytes };
    const source = Source{
        .context = &fixture,
        .observe_fn = Fixture.observe,
        .request_fn = Fixture.request,
        .take_fn = Fixture.take,
        .release_fn = Fixture.release,
    };
    const request_id = try source.request();
    const result = (try source.take(request_id)) orelse return error.MissingCaptureResult;
    try std.testing.expectEqualSlices(u8, &bytes, result.captured);
    source.release(result.captured);
}
