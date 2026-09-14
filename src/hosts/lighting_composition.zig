//! Title presentation composition: resolved fixtures, vehicle rigs and work lamps.
//! No SDL, physics reads, clock or mutation authority is available here.
const std = @import("std");
const engine = @import("engine_contracts");
const library = @import("content").lighting_library;
pub const Parent = struct {
    kind: enum { vehicle, carryable },
    index: u32,
    incarnation: u32,
    asset: ?engine.assets.AssetId = null,
    /// Borrowed from the actual parent color draw's presentation extraction.
    pose: engine.Pose,
};
pub const Resolved = struct {
    asset: engine.assets.AssetId,
    revision: u64,
    parent: ?Parent,
    emitter: engine.lighting.Instance,
    surface: ?library.Surface,
    surface_submitted: bool = false,
    visual: ?struct { binding: library.Visual, pose: engine.Pose, color: [3]f32 },
};
pub const Frame = struct {
    allocator: std.mem.Allocator,
    resolved: std.ArrayList(Resolved) = .empty,
    emitters: std.ArrayList(engine.lighting.Instance) = .empty,
    pub fn deinit(self: *Frame) void {
        self.resolved.deinit(self.allocator);
        self.emitters.deinit(self.allocator);
    }
    pub fn begin(self: *Frame) void {
        self.resolved.clearRetainingCapacity();
        self.emitters.clearRetainingCapacity();
    }
    /// Called for every contributing cooked draw, including retained districts.
    pub fn surfaceScale(self: *Frame, mesh: engine.assets.AssetId) ?f32 {
        for (self.resolved.items) |*resolved| if (resolved.surface) |surface| if (std.meta.eql(surface.mesh, mesh)) {
            resolved.surface_submitted = true;
            return if (resolved.emitter.light.enabled) surface.emissive_scale else 0;
        };
        return null;
    }
    pub fn finish(self: *Frame) void {
        self.emitters.clearRetainingCapacity();
        for (self.resolved.items) |resolved| {
            if (resolved.surface != null and !resolved.surface_submitted) continue;
            self.emitters.appendAssumeCapacity(resolved.emitter);
        }
    }
    pub fn add(self: *Frame, asset: engine.assets.AssetId, revision: u64, fixture: library.Fixture, environment: engine.lighting.Environment, parent: ?Parent) !void {
        switch (fixture.mount) {
            .world => if (parent != null) return,
            .vehicle_asset => |id| {
                const p = parent orelse return;
                if (p.kind != .vehicle or p.asset == null or !std.meta.eql(id, p.asset.?)) return;
            },
            .carryable => if (parent == null or parent.?.kind != .carryable) return,
        }
        const pose = if (parent) |p| try engine.transform.compose(p.pose, fixture.pose) else try fixture.pose.normalized();
        var light = fixture.light;
        if (fixture.follows_night and !environment.artificial_lights_enabled) light.enabled = false;
        if (fixture.mount == .vehicle_asset and !environment.headlights_enabled) light.enabled = false;
        const id = identity(asset, parent);
        for (self.resolved.items) |other| if (other.emitter.id == id) return error.DuplicateResolvedLight;
        const visual: @FieldType(Resolved, "visual") = if (fixture.visual) |binding| if (light.enabled) .{ .binding = binding, .pose = try engine.transform.compose(pose, binding.local_pose), .color = light.color } else null else null;
        try self.resolved.ensureUnusedCapacity(self.allocator, 1);
        try self.emitters.ensureUnusedCapacity(self.allocator, 1);
        const emitter = engine.lighting.Instance{ .id = id, .light = light, .pose = pose };
        self.resolved.appendAssumeCapacity(.{ .asset = asset, .revision = revision, .parent = parent, .emitter = emitter, .visual = visual, .surface = fixture.surface });
        self.emitters.appendAssumeCapacity(emitter);
    }
};
pub fn identity(asset: engine.assets.AssetId, parent: ?Parent) u64 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("incinerator.lighting.instance.v1");
    var bytes: [16]u8 = undefined;
    std.mem.writeInt(u64, bytes[0..8], asset.namespace, .little);
    std.mem.writeInt(u64, bytes[8..16], asset.local, .little);
    hash.update(&bytes);
    if (parent) |p| {
        hash.update(&.{ 1, @intFromEnum(p.kind) });
        std.mem.writeInt(u32, bytes[0..4], p.index, .little);
        std.mem.writeInt(u32, bytes[4..8], p.incarnation, .little);
        hash.update(bytes[0..8]);
    } else hash.update(&.{0});
    const digest = hash.finalResult();
    const value = std.mem.readInt(u64, digest[0..8], .little);
    return if (value == 0) 1 else value;
}

test "rig uses exact interpolated parent pose at mixed cadences and clears without a parent" {
    var frame = Frame{ .allocator = std.testing.allocator };
    defer frame.deinit();
    const asset = engine.assets.AssetId{ .namespace = 1, .local = 2 };
    const car = engine.assets.AssetId{ .namespace = 2, .local = 3 };
    const fixture = library.Fixture{ .light = .{ .kind = .spot }, .mount = .{ .vehicle_asset = car }, .pose = .{ .position = .{ 0, 0, -2 } } };
    const environment = engine.lighting.Environment{ .artificial_lights_enabled = true, .headlights_enabled = true };
    var previous_id: ?u64 = null;
    for ([_]f32{ 0, 0.3, 0.5, 0.95, 1, 0.1, 0.67 }) |alpha| {
        const pose = try engine.transform.interpolate(.{ .position = .{ 0, 1, 0 } }, .{ .position = .{ 4, 1.1, -2 }, .rotation = try engine.transform.rotationFromFacingYaw(std.math.pi / 2.0) }, alpha);
        frame.begin();
        const parent = Parent{ .kind = .vehicle, .index = 7, .incarnation = 3, .asset = car, .pose = pose };
        try frame.add(asset, 1, fixture, environment, parent);
        const emitted = frame.resolved.items[0];
        const forward = engine.lighting.emittedDirection(pose);
        for (0..3) |axis| try std.testing.expectApproxEqAbs(pose.position[axis] + forward[axis] * 2, emitted.emitter.pose.position[axis], 0.00001);
        if (previous_id) |id| try std.testing.expectEqual(id, emitted.emitter.id);
        previous_id = emitted.emitter.id;
    }
    frame.begin();
    try frame.add(asset, 1, fixture, environment, null);
    try std.testing.expectEqual(@as(usize, 0), frame.emitters.items.len);
    try frame.add(asset, 1, fixture, environment, .{ .kind = .vehicle, .index = 7, .incarnation = 4, .asset = car, .pose = .{} });
    try std.testing.expect(frame.emitters.items[0].id != previous_id.?);
}
