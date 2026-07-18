//! Best-effort graphical re-execution of semantic input captured in an incident.
//!
//! This is intentionally not the deterministic authority verifier. It maps
//! recorded focused-window controls back onto the normal product action latch
//! at their authority ticks so a developer can attempt to reproduce the human
//! camera and interaction journey on the same macOS graphical composition.

const std = @import("std");
const controls = @import("../sandbox_controls.zig");

pub const max_samples: usize = 8192;

const State = struct {
    forward: bool = false,
    backward: bool = false,
    left: bool = false,
    right: bool = false,
    interact: bool = false,
    carry: bool = false,
    attack: bool = false,
    respawn: bool = false,
    jump_or_brake: bool = false,
    hand_brake: bool = false,
};

const Sample = struct {
    tick: u64,
    sequence: u64,
    state: State,
    interact_pressed: bool,
    carry_pressed: bool,
    attack_pressed: bool,
    respawn_pressed: bool,
    jump_pressed: bool,
    mouse_delta: [2]f32,
};

pub const Replay = struct {
    allocator: std.mem.Allocator,
    samples: []Sample,
    cursor: usize = 0,
    current: State = .{},
    last_tick: u64 = 0,

    pub fn load(
        io: std.Io,
        allocator: std.mem.Allocator,
        run_path: []const u8,
    ) !Replay {
        const streams_path = try std.fs.path.join(allocator, &.{ run_path, "streams" });
        defer allocator.free(streams_path);
        var list = try std.ArrayList(Sample).initCapacity(allocator, 64);
        errdefer list.deinit(allocator);
        var directory = try std.Io.Dir.cwd().openDir(io, streams_path, .{ .iterate = true });
        defer directory.close(io);
        var walker = try directory.walk(allocator);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file or !std.mem.startsWith(u8, entry.path, "input-") or
                !std.mem.endsWith(u8, entry.path, ".ndjson")) continue;
            const path = try std.fs.path.join(allocator, &.{ streams_path, entry.path });
            defer allocator.free(path);
            const bytes = try std.Io.Dir.cwd().readFileAlloc(
                io,
                path,
                allocator,
                .limited(4 * 1024 * 1024 + 4096),
            );
            defer allocator.free(bytes);
            var lines = std.mem.splitScalar(u8, bytes, '\n');
            while (lines.next()) |line| {
                if (line.len == 0) continue;
                if (list.items.len == max_samples) return error.IncidentInputCapacityExceeded;
                var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
                defer parsed.deinit();
                const object = switch (parsed.value) {
                    .object => |value| value,
                    else => return error.InvalidIncidentInputRecord,
                };
                if (!stringEquals(object.get("kind"), "semantic_input")) continue;
                const delta = object.get("mouse_delta") orelse return error.InvalidIncidentInputRecord;
                if (delta != .array or delta.array.items.len != 2) {
                    return error.InvalidIncidentInputRecord;
                }
                try list.append(allocator, .{
                    .tick = try integer(object.get("authority_tick")),
                    .sequence = try integer(object.get("recorder_sequence")),
                    .state = .{
                        .forward = try boolean(object.get("forward")),
                        .backward = try boolean(object.get("backward")),
                        .left = try boolean(object.get("left")),
                        .right = try boolean(object.get("right")),
                        .interact = try boolean(object.get("interact")),
                        .carry = try boolean(object.get("carry")),
                        .attack = try boolean(object.get("attack")),
                        .respawn = try boolean(object.get("respawn")),
                        .jump_or_brake = try boolean(object.get("jump_or_brake")),
                        .hand_brake = try boolean(object.get("hand_brake")),
                    },
                    .interact_pressed = try boolean(object.get("interact_pressed")),
                    .carry_pressed = try boolean(object.get("carry_pressed")),
                    .attack_pressed = try boolean(object.get("attack_pressed")),
                    .respawn_pressed = try boolean(object.get("respawn_pressed")),
                    .jump_pressed = try boolean(object.get("jump_pressed")),
                    .mouse_delta = .{
                        try numberF32(delta.array.items[0]),
                        try numberF32(delta.array.items[1]),
                    },
                });
            }
        }
        if (list.items.len == 0) return error.IncidentInputMissing;
        std.mem.sort(Sample, list.items, {}, lessThan);
        return .{
            .allocator = allocator,
            .samples = try list.toOwnedSlice(allocator),
        };
    }

    pub fn deinit(self: *Replay) void {
        self.allocator.free(self.samples);
        self.* = undefined;
    }

    pub fn frameForTick(self: *Replay, tick: u64) controls.FrameSample {
        var mouse_delta = [2]f32{ 0, 0 };
        var interact_pressed = false;
        var carry_pressed = false;
        var attack_pressed = false;
        var respawn_pressed = false;
        var jump_pressed = false;
        while (self.cursor < self.samples.len and self.samples[self.cursor].tick <= tick) {
            const sample = self.samples[self.cursor];
            self.current = sample.state;
            if (sample.tick == tick) {
                mouse_delta[0] += sample.mouse_delta[0];
                mouse_delta[1] += sample.mouse_delta[1];
                interact_pressed = interact_pressed or sample.interact_pressed;
                carry_pressed = carry_pressed or sample.carry_pressed;
                attack_pressed = attack_pressed or sample.attack_pressed;
                respawn_pressed = respawn_pressed or sample.respawn_pressed;
                jump_pressed = jump_pressed or sample.jump_pressed;
            }
            self.cursor += 1;
        }
        self.last_tick = tick;
        return .{
            .move = .{
                @as(f32, @floatFromInt(@as(i2, @intFromBool(self.current.right)) -
                    @as(i2, @intFromBool(self.current.left)))),
                @as(f32, @floatFromInt(@as(i2, @intFromBool(self.current.forward)) -
                    @as(i2, @intFromBool(self.current.backward)))),
            },
            .look_delta = mouse_delta,
            .jump_pressed = jump_pressed,
            .interact_pressed = interact_pressed,
            .carry_pressed = carry_pressed,
            .melee_pressed = attack_pressed,
            .respawn_pressed = respawn_pressed,
            .brake = self.current.jump_or_brake,
            .hand_brake = self.current.hand_brake,
        };
    }

    pub fn finalTick(self: *const Replay) u64 {
        return self.samples[self.samples.len - 1].tick;
    }
};

fn lessThan(_: void, left: Sample, right: Sample) bool {
    return left.tick < right.tick or (left.tick == right.tick and left.sequence < right.sequence);
}

fn integer(value: ?std.json.Value) !u64 {
    const present = value orelse return error.InvalidIncidentInputRecord;
    if (present != .integer or present.integer < 0) return error.InvalidIncidentInputRecord;
    return @intCast(present.integer);
}

fn boolean(value: ?std.json.Value) !bool {
    const present = value orelse return error.InvalidIncidentInputRecord;
    return if (present == .bool) present.bool else error.InvalidIncidentInputRecord;
}

fn numberF32(value: std.json.Value) !f32 {
    return switch (value) {
        .integer => |number| @floatFromInt(number),
        .float => |number| @floatCast(number),
        else => error.InvalidIncidentInputRecord,
    };
}

fn stringEquals(value: ?std.json.Value, expected: []const u8) bool {
    const present = value orelse return false;
    return present == .string and std.mem.eql(u8, present.string, expected);
}

test "captured action edges survive same-tick state changes" {
    var samples = [_]Sample{
        .{ .tick = 3, .sequence = 1, .state = .{ .forward = true }, .interact_pressed = false, .carry_pressed = false, .attack_pressed = false, .respawn_pressed = false, .jump_pressed = false, .mouse_delta = .{ 2, 0 } },
        .{ .tick = 4, .sequence = 2, .state = .{ .forward = true, .carry = false }, .interact_pressed = false, .carry_pressed = true, .attack_pressed = false, .respawn_pressed = false, .jump_pressed = false, .mouse_delta = .{ 0, 0 } },
        .{ .tick = 4, .sequence = 3, .state = .{ .forward = true, .carry = false }, .interact_pressed = false, .carry_pressed = false, .attack_pressed = false, .respawn_pressed = false, .jump_pressed = false, .mouse_delta = .{ 0, 0 } },
        .{ .tick = 5, .sequence = 4, .state = .{ .forward = true, .carry = false }, .interact_pressed = false, .carry_pressed = false, .attack_pressed = false, .respawn_pressed = false, .jump_pressed = false, .mouse_delta = .{ 0, 0 } },
    };
    var replay = Replay{ .allocator = std.testing.allocator, .samples = &samples };
    const first = replay.frameForTick(3);
    try std.testing.expectEqual(@as(f32, 1), first.move[1]);
    try std.testing.expectEqual(@as(f32, 2), first.look_delta[0]);
    const edge = replay.frameForTick(4);
    try std.testing.expect(edge.carry_pressed);
    const held = replay.frameForTick(5);
    try std.testing.expect(!held.carry_pressed);
}
