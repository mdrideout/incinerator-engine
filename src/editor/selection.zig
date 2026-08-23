//! Renderer-neutral editor selection and CPU viewport picking.
//!
//! Selection identities are semantic engine/game identities. This contract
//! deliberately carries no ECS entity, physics body, renderer handle, pointer,
//! source path, or arbitrary property path.

const std = @import("std");
const engine = @import("incinerator_engine");

pub const Id = union(enum) {
    persistent_entity: engine.PersistentId,
    gameplay_entity: engine.gameplay_trace.EntityRef,
    content_asset: engine.AssetId,

    pub fn validate(self: Id) !void {
        switch (self) {
            .persistent_entity => |id| try id.validate(),
            .gameplay_entity => |id| {
                if (id.namespace == 0) return error.InvalidGameplayEntityNamespace;
                if (id.local == 0) return error.InvalidGameplayEntityLocal;
            },
            .content_asset => |id| try id.validate(),
        }
    }

    pub fn eql(first: Id, second: Id) bool {
        if (std.meta.activeTag(first) != std.meta.activeTag(second)) return false;
        return switch (first) {
            .persistent_entity => |id| std.meta.eql(id, second.persistent_entity),
            .gameplay_entity => |id| std.meta.eql(id, second.gameplay_entity),
            .content_asset => |id| std.meta.eql(id, second.content_asset),
        };
    }

    pub fn lessThan(first: Id, second: Id) bool {
        const first_tag = @intFromEnum(std.meta.activeTag(first));
        const second_tag = @intFromEnum(std.meta.activeTag(second));
        if (first_tag != second_tag) return first_tag < second_tag;
        return switch (first) {
            .persistent_entity => |id| pairLess(
                id.namespace,
                id.local,
                second.persistent_entity.namespace,
                second.persistent_entity.local,
            ),
            .gameplay_entity => |id| if (pairLess(
                id.namespace,
                id.local,
                second.gameplay_entity.namespace,
                second.gameplay_entity.local,
            )) true else if (id.namespace == second.gameplay_entity.namespace and
                id.local == second.gameplay_entity.local)
                id.incarnation < second.gameplay_entity.incarnation
            else
                false,
            .content_asset => |id| pairLess(
                id.namespace,
                id.local,
                second.content_asset.namespace,
                second.content_asset.local,
            ),
        };
    }

    pub fn gameplay(self: Id) ?engine.gameplay_trace.EntityRef {
        return switch (self) {
            .gameplay_entity => |id| id,
            else => null,
        };
    }
};

fn pairLess(a0: u64, a1: u64, b0: u64, b1: u64) bool {
    return a0 < b0 or (a0 == b0 and a1 < b1);
}

pub const ObjectKind = enum {
    crate,
    local_player,
    remote_player,
    npc,
    vehicle,
    carryable,
    content_asset,
};

pub const Owner = enum {
    game_runtime,
    game_content,
};

pub const Availability = enum {
    available,
    unavailable,
};

pub const Bounds = struct {
    minimum: [3]f32,
    maximum: [3]f32,

    pub fn init(origin: [3]f32, half_extents: [3]f32) !Bounds {
        for (origin) |component| if (!std.math.isFinite(component)) {
            return error.InvalidSelectionBounds;
        };
        for (half_extents) |component| if (!std.math.isFinite(component) or
            component <= 0)
        {
            return error.InvalidSelectionBounds;
        };
        return .{
            .minimum = .{
                origin[0] - half_extents[0],
                origin[1] - half_extents[1],
                origin[2] - half_extents[2],
            },
            .maximum = .{
                origin[0] + half_extents[0],
                origin[1] + half_extents[1],
                origin[2] + half_extents[2],
            },
        };
    }

    pub fn validate(self: Bounds) !void {
        for (0..3) |axis| {
            if (!std.math.isFinite(self.minimum[axis]) or
                !std.math.isFinite(self.maximum[axis]) or
                self.minimum[axis] >= self.maximum[axis])
            {
                return error.InvalidSelectionBounds;
            }
        }
    }

    pub fn center(self: Bounds) [3]f32 {
        return .{
            (self.minimum[0] + self.maximum[0]) * 0.5,
            (self.minimum[1] + self.maximum[1]) * 0.5,
            (self.minimum[2] + self.maximum[2]) * 0.5,
        };
    }

    pub fn halfExtents(self: Bounds) [3]f32 {
        return .{
            (self.maximum[0] - self.minimum[0]) * 0.5,
            (self.maximum[1] - self.minimum[1]) * 0.5,
            (self.maximum[2] - self.minimum[2]) * 0.5,
        };
    }
};

pub const Entry = struct {
    id: Id,
    label: []const u8,
    kind: ObjectKind,
    owner: Owner,
    availability: Availability = .available,
    inspectable: bool,
    authorable: bool,
    world_bounds: ?Bounds,

    pub fn validate(self: Entry) !void {
        try self.id.validate();
        if (self.label.len == 0) return error.InvalidSelectionLabel;
        if (!self.inspectable and self.authorable) return error.InvalidSelectionCapabilities;
        if (self.world_bounds) |bounds| try bounds.validate();
        if (self.kind != .content_asset and self.world_bounds == null) {
            return error.MissingSelectionBounds;
        }
    }
};

pub fn entryLessThan(_: void, first: Entry, second: Entry) bool {
    const order = std.ascii.orderIgnoreCase(first.label, second.label);
    if (order != .eq) return order == .lt;
    return first.id.lessThan(second.id);
}

pub fn sortEntries(entries: []Entry) void {
    std.mem.sort(Entry, entries, {}, entryLessThan);
}

pub fn containsDuplicate(entries: []const Entry) bool {
    for (entries, 0..) |entry, index| {
        for (entries[index + 1 ..]) |candidate| {
            if (entry.id.eql(candidate.id)) return true;
        }
    }
    return false;
}

pub const View = struct {
    entries: []const Entry,
    active: ?Id,

    pub fn resolve(self: View, id: Id) ?*const Entry {
        for (self.entries) |*entry| if (entry.id.eql(id)) return entry;
        return null;
    }

    pub fn activeEntry(self: View) ?*const Entry {
        return self.resolve(self.active orelse return null);
    }

    pub fn activeGameplay(self: View) ?engine.gameplay_trace.EntityRef {
        return (self.active orelse return null).gameplay();
    }
};

pub const Request = union(enum) {
    select: Id,
    clear,
};

/// One latest semantic selection request per draw. Multiple tools converge on
/// the final explicit user action without creating an unbounded UI queue.
pub const Requests = struct {
    pending: ?Request = null,

    pub fn submit(self: *Requests, request: Request) void {
        self.pending = request;
    }

    pub fn take(self: *Requests) ?Request {
        defer self.pending = null;
        return self.pending;
    }

    pub fn clear(self: *Requests) void {
        self.pending = null;
    }
};

pub const Controller = struct {
    active: ?Id = null,

    pub fn apply(self: *Controller, request: Request, entries: []const Entry) void {
        switch (request) {
            .clear => self.active = null,
            .select => |id| {
                id.validate() catch {
                    self.active = null;
                    return;
                };
                for (entries) |entry| {
                    if (entry.id.eql(id) and entry.availability == .available) {
                        self.active = id;
                        return;
                    }
                }
                self.active = null;
            },
        }
    }

    pub fn reconcile(self: *Controller, entries: []const Entry) void {
        const active = self.active orelse return;
        for (entries) |entry| {
            if (entry.id.eql(active) and entry.availability == .available) return;
        }
        self.active = null;
    }

    pub fn view(self: *const Controller, entries: []const Entry) View {
        return .{ .entries = entries, .active = self.active };
    }
};

pub const Ray = struct {
    origin: [3]f32,
    direction: [3]f32,
};

pub const Projection = struct {
    position: [3]f32,
    forward: [3]f32,
    right: [3]f32,
    fov_radians: f32,
    screen_extent: [2]f32,
    scene_aspect: f32,

    pub fn ray(self: Projection, point: [2]f32) !Ray {
        for (self.position ++ self.forward ++ self.right) |component| {
            if (!std.math.isFinite(component)) return error.InvalidSelectionProjection;
        }
        if (!std.math.isFinite(self.fov_radians) or self.fov_radians <= 0 or
            self.fov_radians >= std.math.pi or
            !std.math.isFinite(self.screen_extent[0]) or self.screen_extent[0] <= 0 or
            !std.math.isFinite(self.screen_extent[1]) or self.screen_extent[1] <= 0 or
            !std.math.isFinite(self.scene_aspect) or self.scene_aspect <= 0 or
            !std.math.isFinite(point[0]) or !std.math.isFinite(point[1]))
        {
            return error.InvalidSelectionProjection;
        }

        const forward = try normalize(self.forward);
        const right = try normalize(self.right);
        const up = try normalize(cross(right, forward));
        const ndc_x = point[0] / self.screen_extent[0] * 2 - 1;
        const ndc_y = 1 - point[1] / self.screen_extent[1] * 2;
        const tangent = @tan(self.fov_radians * 0.5);
        return .{
            .origin = self.position,
            .direction = try normalize(add(
                forward,
                add(
                    scale(right, ndc_x * self.scene_aspect * tangent),
                    scale(up, ndc_y * tangent),
                ),
            )),
        };
    }
};

pub fn pickNearest(ray: Ray, entries: []const Entry) ?Id {
    var nearest: ?Id = null;
    var nearest_distance = std.math.inf(f32);
    for (entries) |entry| {
        if (entry.availability != .available) continue;
        const bounds = entry.world_bounds orelse continue;
        const distance = rayBoundsDistance(ray, bounds) orelse continue;
        if (distance < nearest_distance or
            (distance == nearest_distance and
                (nearest == null or entry.id.lessThan(nearest.?))))
        {
            nearest = entry.id;
            nearest_distance = distance;
        }
    }
    return nearest;
}

pub fn rayBoundsDistance(ray: Ray, bounds: Bounds) ?f32 {
    bounds.validate() catch return null;
    const direction = normalize(ray.direction) catch return null;
    var near: f32 = 0;
    var far = std.math.inf(f32);
    for (0..3) |axis| {
        const component = direction[axis];
        if (@abs(component) < 0.000001) {
            if (ray.origin[axis] < bounds.minimum[axis] or
                ray.origin[axis] > bounds.maximum[axis]) return null;
            continue;
        }
        const reciprocal = 1 / component;
        var first = (bounds.minimum[axis] - ray.origin[axis]) * reciprocal;
        var second = (bounds.maximum[axis] - ray.origin[axis]) * reciprocal;
        if (first > second) std.mem.swap(f32, &first, &second);
        near = @max(near, first);
        far = @min(far, second);
        if (near > far) return null;
    }
    return if (far >= 0) near else null;
}

pub fn matches(entry: Entry, query: []const u8, kind: ?ObjectKind) bool {
    if (kind) |required| if (entry.kind != required) return false;
    if (query.len == 0) return true;
    if (std.ascii.indexOfIgnoreCase(entry.label, query) != null) return true;
    return std.ascii.indexOfIgnoreCase(@tagName(entry.kind), query) != null;
}

fn add(first: [3]f32, second: [3]f32) [3]f32 {
    return .{ first[0] + second[0], first[1] + second[1], first[2] + second[2] };
}

fn scale(value: [3]f32, amount: f32) [3]f32 {
    return .{ value[0] * amount, value[1] * amount, value[2] * amount };
}

fn cross(first: [3]f32, second: [3]f32) [3]f32 {
    return .{
        first[1] * second[2] - first[2] * second[1],
        first[2] * second[0] - first[0] * second[2],
        first[0] * second[1] - first[1] * second[0],
    };
}

fn normalize(value: [3]f32) ![3]f32 {
    const length_squared = value[0] * value[0] + value[1] * value[1] +
        value[2] * value[2];
    if (!std.math.isFinite(length_squared) or length_squared <= 0) {
        return error.InvalidSelectionVector;
    }
    return scale(value, 1 / @sqrt(length_squared));
}

fn testEntry(id: Id, label: []const u8, center: [3]f32) Entry {
    return .{
        .id = id,
        .label = label,
        .kind = .crate,
        .owner = .game_content,
        .inspectable = true,
        .authorable = true,
        .world_bounds = Bounds.init(center, .{ 1, 1, 1 }) catch unreachable,
    };
}

test "selection identities reject absent stable values" {
    try std.testing.expectError(
        error.InvalidIdentityNamespace,
        (Id{ .persistent_entity = .{ .namespace = 0, .local = 1 } }).validate(),
    );
    try std.testing.expectError(
        error.InvalidGameplayEntityLocal,
        (Id{ .gameplay_entity = .{ .namespace = 1, .local = 0 } }).validate(),
    );
    try std.testing.expectError(
        error.InvalidAssetLocal,
        (Id{ .content_asset = .{ .namespace = 1, .local = 0 } }).validate(),
    );
}

test "world entries require finite bounds and closed capabilities" {
    var entry = testEntry(
        .{ .persistent_entity = .{ .namespace = 1, .local = 1 } },
        "Crate",
        .{ 0, 0, 0 },
    );
    try entry.validate();
    entry.inspectable = false;
    try std.testing.expectError(error.InvalidSelectionCapabilities, entry.validate());
    entry.inspectable = true;
    entry.world_bounds.?.maximum[0] = std.math.inf(f32);
    try std.testing.expectError(error.InvalidSelectionBounds, entry.validate());
    try std.testing.expectError(
        error.InvalidSelectionBounds,
        Bounds.init(.{ 0, 0, 0 }, .{ 1, 0, 1 }),
    );
}

test "nearest picking rejects misses and behind-camera bounds" {
    const entries = [_]Entry{
        testEntry(.{ .persistent_entity = .{ .namespace = 1, .local = 2 } }, "Far", .{ 0, 0, -9 }),
        testEntry(.{ .persistent_entity = .{ .namespace = 1, .local = 1 } }, "Near", .{ 0, 0, -4 }),
        testEntry(.{ .persistent_entity = .{ .namespace = 1, .local = 3 } }, "Behind", .{ 0, 0, 4 }),
    };
    const hit = pickNearest(.{ .origin = .{ 0, 0, 0 }, .direction = .{ 0, 0, -1 } }, &entries);
    try std.testing.expect(hit.?.eql(entries[1].id));
    try std.testing.expect(pickNearest(
        .{ .origin = .{ 8, 0, 0 }, .direction = .{ 0, 0, -1 } },
        &entries,
    ) == null);
}

test "screen projection maps center and corners through rendered aspect" {
    const projection = Projection{
        .position = .{ 0, 0, 0 },
        .forward = .{ 0, 0, -1 },
        .right = .{ 1, 0, 0 },
        .fov_radians = @as(f32, std.math.pi) / 2,
        .screen_extent = .{ 800, 400 },
        .scene_aspect = 2,
    };
    const center = try projection.ray(.{ 400, 200 });
    try std.testing.expectApproxEqAbs(@as(f32, 0), center.direction[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), center.direction[1], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, -1), center.direction[2], 0.0001);
    const upper_right = try projection.ray(.{ 800, 0 });
    try std.testing.expect(upper_right.direction[0] > 0);
    try std.testing.expect(upper_right.direction[1] > 0);
    try std.testing.expect(upper_right.direction[2] < 0);
}

test "ordering filtering duplicate and stale selection are deterministic" {
    var entries = [_]Entry{
        testEntry(.{ .persistent_entity = .{ .namespace = 2, .local = 1 } }, "zebra", .{ 0, 0, -2 }),
        testEntry(.{ .persistent_entity = .{ .namespace = 1, .local = 2 } }, "Alpha", .{ 0, 0, -3 }),
        testEntry(.{ .persistent_entity = .{ .namespace = 1, .local = 1 } }, "alpha", .{ 0, 0, -4 }),
    };
    sortEntries(&entries);
    try std.testing.expectEqual(@as(u64, 1), entries[0].id.persistent_entity.local);
    try std.testing.expectEqual(@as(u64, 2), entries[1].id.persistent_entity.local);
    try std.testing.expect(matches(entries[0], "ALP", .crate));
    try std.testing.expect(!matches(entries[2], "alp", null));
    try std.testing.expect(!containsDuplicate(&entries));
    entries[2].id = entries[1].id;
    try std.testing.expect(containsDuplicate(&entries));

    var controller = Controller{};
    controller.apply(.{ .select = entries[0].id }, &entries);
    try std.testing.expect(controller.active.?.eql(entries[0].id));
    controller.reconcile(entries[1..]);
    try std.testing.expect(controller.active == null);
}
