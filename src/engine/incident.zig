//! Versioned, bounded contracts for local human-test incident capture.
//!
//! These are values crossing the visual developer-host/editor boundary. They
//! deliberately contain no filesystem handles, renderer objects, authority
//! handles, or dynamically owned text.

const std = @import("std");

pub const schema_version: u16 = 5;
pub const max_anomalies: usize = 32;
pub const max_path_bytes: usize = 768;
pub const max_note_bytes: usize = 240;
pub const max_status_bytes: usize = 160;
pub const max_handoff_bytes: usize = 32 * 1024;

pub const AnomalyId = u32;

pub const NoteUpdate = struct {
    id: AnomalyId,
    note: [max_note_bytes]u8,
    note_len: u8,
};

pub const Request = union(enum) {
    flag,
    save_note: NoteUpdate,
    save_note_and_copy: NoteUpdate,
    open_run_folder,
};

pub const RequestBuffer = struct {
    pub const capacity: usize = 16;

    items: [capacity]Request = undefined,
    count: u8 = 0,
    rejected: u64 = 0,

    pub fn push(self: *RequestBuffer, request: Request) bool {
        if (self.count == capacity) {
            self.rejected +|= 1;
            return false;
        }
        self.items[self.count] = request;
        self.count += 1;
        return true;
    }

    pub fn slice(self: *const RequestBuffer) []const Request {
        return self.items[0..self.count];
    }

    pub fn clear(self: *RequestBuffer) void {
        self.count = 0;
    }
};

pub const AnomalyStatus = enum {
    capturing,
    complete,
    partial,
};

pub const AnomalyView = struct {
    id: AnomalyId,
    authority_tick: u64,
    presentation_frame: u64,
    wall_unix_ms: i64,
    status: AnomalyStatus,
    artifact_count: u16 = 0,
    artifact_failures: u16 = 0,
    note: [max_note_bytes]u8 = @splat(0),
    note_len: u8 = 0,

    pub fn noteSlice(self: *const AnomalyView) []const u8 {
        return self.note[0..@min(@as(usize, self.note_len), self.note.len)];
    }
};

pub const Health = struct {
    enabled: bool = false,
    writer_ready: bool = false,
    writer_failed: bool = false,
    visual_budget_exhausted: bool = false,
    handoff_persisted: bool = false,
    queued: u16 = 0,
    queue_high_water: u16 = 0,
    dropped_records: u64 = 0,
    visual_budget_rejections: u64 = 0,
    bytes_written: u64 = 0,
    visual_bytes_reserved: u64 = 0,
    visual_budget_bytes: u64 = 0,
    screenshot_misses: u64 = 0,
    last_durable_sequence: u64 = 0,
    last_admitted_sequence: u64 = 0,
};

pub const ShortcutStage = enum {
    received,
    matched,
    queued,
    applied,
};

pub const ShortcutCandidate = struct {
    event_monotonic_ns: u64 = 0,
    window_id: u32 = 0,
    event_type: u32 = 0,
    scancode: u32 = 0,
    keycode: u32 = 0,
    raw: u16 = 0,
    modifiers: u16 = 0,
    repeat: bool = false,
    focused: bool = false,
    matched: bool = false,
};

pub const ShortcutView = struct {
    received: u64 = 0,
    matched: u64 = 0,
    queued: u64 = 0,
    applied: u64 = 0,
    last_event_type: u32 = 0,
    last_window_id: u32 = 0,
    last_scancode: u32 = 0,
    last_keycode: u32 = 0,
    last_raw: u16 = 0,
    last_modifiers: u16 = 0,
    last_repeat: bool = false,
    last_focused: bool = false,
    last_matched: bool = false,
};

pub const View = struct {
    run_path: [max_path_bytes]u8 = @splat(0),
    run_path_len: u16 = 0,
    health: Health = .{},
    anomalies: [max_anomalies]AnomalyView = undefined,
    anomaly_count: u8 = 0,
    status: [max_status_bytes]u8 = @splat(0),
    status_len: u8 = 0,
    request_rejections: u64 = 0,
    shortcuts: ShortcutView = .{},

    pub fn runPath(self: *const View) []const u8 {
        return self.run_path[0..@min(@as(usize, self.run_path_len), self.run_path.len)];
    }

    pub fn anomalySlice(self: *const View) []const AnomalyView {
        return self.anomalies[0..@min(@as(usize, self.anomaly_count), self.anomalies.len)];
    }

    pub fn statusText(self: *const View) []const u8 {
        return self.status[0..@min(@as(usize, self.status_len), self.status.len)];
    }
};

pub const InputSample = struct {
    move_forward: bool = false,
    move_backward: bool = false,
    move_left: bool = false,
    move_right: bool = false,
    interact: bool = false,
    carry: bool = false,
    attack: bool = false,
    respawn: bool = false,
    jump_or_brake: bool = false,
    interact_pressed: bool = false,
    carry_pressed: bool = false,
    attack_pressed: bool = false,
    respawn_pressed: bool = false,
    jump_pressed: bool = false,
    hand_brake: bool = false,
    right_mouse: bool = false,
    mouse_delta_x: f32 = 0,
    mouse_delta_y: f32 = 0,
    keyboard_captured: bool = false,
    mouse_captured: bool = false,
    window_minimized: bool = false,
};

test "incident request and view capacities fail visibly" {
    var requests = RequestBuffer{};
    for (0..RequestBuffer.capacity) |_| try std.testing.expect(requests.push(.flag));
    try std.testing.expect(!requests.push(.flag));
    try std.testing.expectEqual(@as(u64, 1), requests.rejected);

    var view = View{};
    const path = "/tmp/incinerator/run";
    @memcpy(view.run_path[0..path.len], path);
    view.run_path_len = path.len;
    try std.testing.expectEqualStrings(path, view.runPath());
}
