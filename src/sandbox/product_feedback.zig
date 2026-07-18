//! Small product-owned projection for discrete local action feedback.
//!
//! Authority and session results remain canonical. This owner merely retains
//! the latest submitted, rejected, or applied local action long enough for the
//! normal product title/HUD and developer inspector to explain a button press.

const std = @import("std");
const engine = @import("incinerator_engine");

pub const retention_ticks: u64 = 180;

pub const Feedback = struct {
    sequence: u64,
    kind: engine.gameplay_trace.Kind,
    disposition: engine.gameplay_trace.Disposition,
    reason_domain: engine.gameplay_trace.ReasonDomain = .none,
    reason: u32 = 0,
    observed_tick: u64,
    expires_tick: u64,
};

pub const Owner = struct {
    next_sequence: u64 = 1,
    latest: ?Feedback = null,

    pub fn noteSubmitted(
        self: *Owner,
        tick: u64,
        kind: engine.gameplay_trace.Kind,
    ) void {
        self.note(tick, kind, .accepted, .none, 0);
    }

    pub fn noteRejected(
        self: *Owner,
        tick: u64,
        kind: engine.gameplay_trace.Kind,
        err: anyerror,
    ) void {
        self.note(tick, kind, .rejected, .error_code, @intFromError(err));
    }

    pub fn noteApplied(
        self: *Owner,
        tick: u64,
        kind: engine.gameplay_trace.Kind,
    ) void {
        self.note(tick, kind, .applied, .none, 0);
    }

    pub fn noteAuthorityRejected(
        self: *Owner,
        tick: u64,
        kind: engine.gameplay_trace.Kind,
        disposition: anytype,
    ) void {
        self.note(
            tick,
            kind,
            .rejected,
            .protocol_disposition,
            @intFromEnum(disposition),
        );
    }

    pub fn current(self: *const Owner, tick: u64) ?Feedback {
        const latest = self.latest orelse return null;
        return if (tick <= latest.expires_tick) latest else null;
    }

    fn note(
        self: *Owner,
        tick: u64,
        kind: engine.gameplay_trace.Kind,
        disposition: engine.gameplay_trace.Disposition,
        reason_domain: engine.gameplay_trace.ReasonDomain,
        reason: u32,
    ) void {
        const sequence = self.next_sequence;
        self.next_sequence +|= 1;
        self.latest = .{
            .sequence = sequence,
            .kind = kind,
            .disposition = disposition,
            .reason_domain = reason_domain,
            .reason = reason,
            .observed_tick = tick,
            .expires_tick = tick +| retention_ticks,
        };
    }
};

test "product action feedback retains typed result for a bounded interval" {
    var owner = Owner{};
    owner.noteRejected(10, .melee, error.AvatarDead);
    const feedback = owner.current(10).?;
    try std.testing.expectEqual(engine.gameplay_trace.Kind.melee, feedback.kind);
    try std.testing.expectEqual(
        engine.gameplay_trace.ReasonDomain.error_code,
        feedback.reason_domain,
    );
    try std.testing.expectEqual(
        engine.gameplay_trace.Disposition.rejected,
        feedback.disposition,
    );
    try std.testing.expectEqual(@intFromError(error.AvatarDead), feedback.reason);
    try std.testing.expect(owner.current(10 + retention_ticks) != null);
    try std.testing.expect(owner.current(11 + retention_ticks) == null);
}
