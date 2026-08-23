//! Renderer-neutral editor viewport interaction contracts.
//!
//! These values belong to engine tooling and visual composition. They are not
//! gameplay authority, replication, replay, or world-save state.

const std = @import("std");

pub const Mode = enum {
    character,
    free_camera,

    pub fn toggled(self: Mode) Mode {
        return switch (self) {
            .character => .free_camera,
            .free_camera => .character,
        };
    }
};

/// Window-space scene region from the most recently composed editor frame.
/// The platform input adapter uses it only for routing pointer input.
pub const SceneRect = struct {
    minimum: [2]f32,
    maximum: [2]f32,

    pub fn init(minimum: [2]f32, maximum: [2]f32) ?SceneRect {
        for (minimum ++ maximum) |value| {
            if (!std.math.isFinite(value)) return null;
        }
        if (maximum[0] <= minimum[0] or maximum[1] <= minimum[1]) return null;
        return .{ .minimum = minimum, .maximum = maximum };
    }

    pub fn contains(self: SceneRect, point: [2]f32) bool {
        return point[0] >= self.minimum[0] and point[0] < self.maximum[0] and
            point[1] >= self.minimum[1] and point[1] < self.maximum[1];
    }
};

pub const FocusTarget = struct {
    center: [3]f32,
    radius: f32,

    pub fn isValid(self: FocusTarget) bool {
        for (self.center) |value| {
            if (!std.math.isFinite(value)) return false;
        }
        return std.math.isFinite(self.radius) and self.radius > 0;
    }
};

pub const FreeCameraView = struct {
    initialized: bool = false,
    position: [3]f32 = .{ 0, 0, 0 },
    yaw: f32 = 0,
    pitch: f32 = 0,
    move_speed: f32 = 0,
    last_focus: ?FocusTarget = null,
};

pub const View = struct {
    mode: Mode = .character,
    free_camera: FreeCameraView = .{},
};

pub const Navigation = struct {
    /// Right, vertical, and forward intent in camera-local space.
    move: [3]f32 = .{ 0, 0, 0 },
    look_delta: [2]f32 = .{ 0, 0 },
    delta_seconds: f32,
    fast: bool = false,

    pub fn hasInput(self: Navigation) bool {
        return self.move[0] != 0 or self.move[1] != 0 or self.move[2] != 0 or
            self.look_delta[0] != 0 or self.look_delta[1] != 0;
    }
};

/// Fixed semantic operations accepted by the visual viewport owner.
pub const Request = union(enum) {
    set_mode: Mode,
    navigate: Navigation,
    adjust_speed: f32,
    frame_selection: FocusTarget,
    start_from_product_view,
};

/// One-frame mailbox with one explicit slot per operation. This avoids a
/// generic command bus and does not impose an arbitrary queue capacity.
pub const Requests = struct {
    mode: ?Mode = null,
    navigation: ?Navigation = null,
    speed_steps: f32 = 0,
    frame_target: ?FocusTarget = null,
    start_from_product_view: bool = false,

    pub fn submit(self: *Requests, request: Request) void {
        switch (request) {
            .set_mode => |mode| self.mode = mode,
            .navigate => |navigation| self.navigation = navigation,
            .adjust_speed => |steps| self.speed_steps += steps,
            .frame_selection => |target| self.frame_target = target,
            .start_from_product_view => self.start_from_product_view = true,
        }
    }

    pub fn take(self: *Requests) Requests {
        const result = self.*;
        self.* = .{};
        return result;
    }

    pub fn clear(self: *Requests) void {
        self.* = .{};
    }
};

test "scene rectangle uses half-open window-space bounds" {
    const rect = SceneRect.init(.{ 10, 20 }, .{ 110, 220 }).?;
    try std.testing.expect(rect.contains(.{ 10, 20 }));
    try std.testing.expect(rect.contains(.{ 109.9, 219.9 }));
    try std.testing.expect(!rect.contains(.{ 110, 40 }));
    try std.testing.expect(!rect.contains(.{ 40, 220 }));
    try std.testing.expect(SceneRect.init(.{ 4, 4 }, .{ 4, 9 }) == null);
}

test "viewport request slots remain typed and coalesce per operation" {
    var requests = Requests{};
    requests.submit(.{ .set_mode = .free_camera });
    requests.submit(.{ .adjust_speed = 1 });
    requests.submit(.{ .adjust_speed = -0.25 });
    requests.submit(.start_from_product_view);

    const batch = requests.take();
    try std.testing.expectEqual(Mode.free_camera, batch.mode.?);
    try std.testing.expectEqual(@as(f32, 0.75), batch.speed_steps);
    try std.testing.expect(batch.start_from_product_view);
    try std.testing.expect(requests.mode == null);
    try std.testing.expectEqual(@as(f32, 0), requests.speed_steps);
}
