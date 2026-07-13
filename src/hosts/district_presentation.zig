//! Visual-host coordination for one streamed district scene.
//!
//! This module contains policy only: it owns no decoded bytes or GPU objects
//! and imports no renderer backend. A concrete visual registry reserves and
//! resolves scene generations. The coordinator keeps that generation aligned
//! with the logical district lifecycle without making residency a simulation
//! prerequisite.

const std = @import("std");
const engine_contracts = @import("engine_contracts");

const SceneHandle = engine_contracts.rendering.SceneHandle;

pub const ProximityAction = enum {
    none,
    enter,
    exit,
};

pub const ProximityConfig = struct {
    center_xz: [2]f32,
    half_extent_xz: [2]f32,
    load_margin: f32,
    unload_margin: f32,

    pub fn validate(self: ProximityConfig) !void {
        if (!std.math.isFinite(self.center_xz[0]) or
            !std.math.isFinite(self.center_xz[1]) or
            !std.math.isFinite(self.half_extent_xz[0]) or
            !std.math.isFinite(self.half_extent_xz[1]) or
            !std.math.isFinite(self.load_margin) or
            !std.math.isFinite(self.unload_margin) or
            self.half_extent_xz[0] <= 0 or
            self.half_extent_xz[1] <= 0 or
            self.load_margin < 0 or
            self.unload_margin <= self.load_margin)
        {
            return error.InvalidDistrictProximityConfig;
        }

        // Validate the derived AABBs, not only their finite inputs. Large finite
        // values can overflow while adding margins, and f32 precision can make
        // distinct margins collapse to the same per-axis threshold/boundary.
        inline for (0..2) |axis| {
            const load_threshold = self.half_extent_xz[axis] + self.load_margin;
            const unload_threshold = self.half_extent_xz[axis] + self.unload_margin;
            const load_min = self.center_xz[axis] - load_threshold;
            const load_max = self.center_xz[axis] + load_threshold;
            const unload_min = self.center_xz[axis] - unload_threshold;
            const unload_max = self.center_xz[axis] + unload_threshold;
            if (!std.math.isFinite(load_threshold) or
                !std.math.isFinite(unload_threshold) or
                !std.math.isFinite(load_min) or
                !std.math.isFinite(load_max) or
                !std.math.isFinite(unload_min) or
                !std.math.isFinite(unload_max) or
                unload_threshold <= load_threshold or
                load_min >= load_max or
                unload_min >= load_min or
                unload_max <= load_max)
            {
                return error.InvalidDistrictProximityConfig;
            }
        }
    }
};

/// Host-owned Schmitt trigger for one district boundary.
///
/// Features never inspect a character or vehicle. The composition host feeds
/// the current authority target's plain X/Z position here, then translates the
/// resulting edge into typed district commands. The band between load and
/// unload radii prevents boundary noise from repeatedly churning resources.
pub const ProximityHysteresis = struct {
    config: ProximityConfig,
    inside: bool = false,

    pub fn init(config: ProximityConfig) !ProximityHysteresis {
        try config.validate();
        return .{ .config = config };
    }

    pub fn observe(self: *ProximityHysteresis, position_xz: [2]f32) !ProximityAction {
        if (!std.math.isFinite(position_xz[0]) or !std.math.isFinite(position_xz[1])) {
            return error.InvalidDistrictFocusPosition;
        }
        const dx = @abs(position_xz[0] - self.config.center_xz[0]);
        const dz = @abs(position_xz[1] - self.config.center_xz[1]);
        if (!std.math.isFinite(dx) or !std.math.isFinite(dz)) {
            return error.InvalidDistrictFocusPosition;
        }

        if (!self.inside) {
            if (dx > self.config.half_extent_xz[0] + self.config.load_margin or
                dz > self.config.half_extent_xz[1] + self.config.load_margin)
            {
                return .none;
            }
            self.inside = true;
            return .enter;
        }
        if (dx < self.config.half_extent_xz[0] + self.config.unload_margin and
            dz < self.config.half_extent_xz[1] + self.config.unload_margin)
        {
            return .none;
        }
        self.inside = false;
        return .exit;
    }

    /// Rearm an admission that terminated while the focus remains nearby.
    /// The next observation may produce a fresh enter edge.
    pub fn rearm(self: *ProximityHysteresis) void {
        self.inside = false;
    }
};

pub const StateTag = enum {
    idle,
    reserved,
    loading,
    active,
    release_pending,
};

/// Coordinate one logical district with one renderer-owned scene generation.
///
/// `Registry` supplies:
///
/// - `pub const Resolution: type`;
/// - `reserve(*Registry) !SceneHandle`;
/// - `resolve(*Registry, SceneHandle) !Resolution`;
/// - `release(*Registry, SceneHandle) !void`.
///
/// A production resolution may be a fallback or resident scene view. The
/// coordinator deliberately does not inspect which one it received. Each
/// coordinator owns only its own state, so a fixed set of coordinators may
/// safely share one bounded registry; the host remains responsible for
/// retaining released handles until the registry reports per-generation drain.
pub fn Coordinator(comptime Registry: type, comptime Ticket: type) type {
    return struct {
        const Self = @This();

        const Bound = struct {
            scene: SceneHandle,
            ticket: Ticket,
        };

        const State = union(StateTag) {
            idle,
            reserved: SceneHandle,
            loading: Bound,
            active: Bound,
            release_pending: Bound,
        };

        registry: *Registry,
        state: State = .idle,

        pub fn init(registry: *Registry) Self {
            return .{ .registry = registry };
        }

        pub fn stateTag(self: *const Self) StateTag {
            return std.meta.activeTag(self.state);
        }

        /// Reserve presentation identity before submitting `request_load`.
        pub fn beginRequest(self: *Self) !SceneHandle {
            if (self.stateTag() != .idle) return error.DistrictPresentationBusy;
            const scene = try self.registry.reserve();
            if (!scene.isValid()) return error.InvalidReservedSceneHandle;
            self.state = .{ .reserved = scene };
            return scene;
        }

        /// Bind the feature ticket published by its `load_requested` outcome.
        pub fn loadAdmitted(self: *Self, scene: SceneHandle, ticket: Ticket) !void {
            const reserved = switch (self.state) {
                .reserved => |value| value,
                else => return error.DistrictPresentationNotReserved,
            };
            if (!std.meta.eql(reserved, scene)) return error.StaleSceneHandle;
            self.state = .{ .loading = .{ .scene = scene, .ticket = ticket } };
        }

        /// Release a reservation when the feature rejects the load command
        /// before it publishes a ticket.
        pub fn loadRejected(self: *Self, scene: SceneHandle) !void {
            const reserved = switch (self.state) {
                .reserved => |value| value,
                else => return error.DistrictPresentationNotReserved,
            };
            if (!std.meta.eql(reserved, scene)) return error.StaleSceneHandle;
            try self.registry.release(reserved);
            self.state = .idle;
        }

        /// Logical activation is accepted without querying registry residency.
        pub fn logicalActivated(self: *Self, ticket: Ticket) !void {
            const loading = switch (self.state) {
                .loading => |value| value,
                else => return error.DistrictPresentationNotLoading,
            };
            try requireTicket(loading.ticket, ticket);
            self.state = .{ .active = loading };
        }

        /// A cancelled or failed load never reached presentation extraction,
        /// so its reserved generation can be released immediately.
        pub fn loadTerminated(self: *Self, ticket: Ticket) !void {
            const loading = switch (self.state) {
                .loading => |value| value,
                else => return error.DistrictPresentationNotLoading,
            };
            try requireTicket(loading.ticket, ticket);
            try self.registry.release(loading.scene);
            self.state = .idle;
        }

        /// Resolve an extracted logical draw. A registry may return its
        /// fallback while upload is queued/in flight, then its resident scene
        /// later, without any logical state transition here.
        pub fn resolve(
            self: *Self,
            ticket: Ticket,
            scene: SceneHandle,
        ) !Registry.Resolution {
            const active = switch (self.state) {
                .active => |value| value,
                else => return error.DistrictPresentationNotActive,
            };
            try requireTicket(active.ticket, ticket);
            if (!std.meta.eql(active.scene, scene)) return error.StaleSceneHandle;
            return self.registry.resolve(scene);
        }

        /// Record the feature's `unloaded` outcome. This intentionally does
        /// not release the scene: the host must first observe empty extraction.
        pub fn logicalUnloaded(self: *Self, ticket: Ticket) !void {
            const active = switch (self.state) {
                .active => |value| value,
                else => return error.DistrictPresentationNotActive,
            };
            try requireTicket(active.ticket, ticket);
            self.state = .{ .release_pending = active };
        }

        /// Call only after `districtPresentation()` returns an empty slice for
        /// the unloaded district. It is the sole normal unload release point.
        pub fn presentationAbsent(self: *Self, extracted_draw_count: usize) !void {
            const pending = switch (self.state) {
                .release_pending => |value| value,
                else => return error.DistrictPresentationReleaseNotPending,
            };
            if (extracted_draw_count != 0) return error.DistrictPresentationStillExtracted;
            try self.registry.release(pending.scene);
            self.state = .idle;
        }

        /// Shutdown seam used after simulation teardown has removed every
        /// logical draw. Pending GPU work remains the registry's responsibility.
        pub fn releaseAfterSimulationTeardown(self: *Self) !void {
            const scene = switch (self.state) {
                .idle => return,
                .reserved => |value| value,
                .loading, .active, .release_pending => |value| value.scene,
            };
            try self.registry.release(scene);
            self.state = .idle;
        }

        fn requireTicket(expected: Ticket, received: Ticket) !void {
            if (!std.meta.eql(expected, received)) return error.StaleDistrictTicket;
        }
    };
}

const TestTicket = struct {
    generation: u64,
};

const FakeRegistry = struct {
    pub const Resolution = enum { fallback, resident };

    next_generation: u32 = 1,
    reserved: ?SceneHandle = null,
    resident: bool = false,
    resolve_count: usize = 0,
    release_count: usize = 0,

    pub fn reserve(self: *FakeRegistry) !SceneHandle {
        if (self.reserved != null) return error.FakeRegistryBusy;
        if (self.next_generation == 0) return error.FakeGenerationExhausted;
        const result = SceneHandle{
            .index = 0,
            .generation = self.next_generation,
        };
        self.next_generation +%= 1;
        self.reserved = result;
        self.resident = false;
        return result;
    }

    pub fn resolve(self: *FakeRegistry, scene: SceneHandle) !Resolution {
        const current = self.reserved orelse return error.FakeSceneMissing;
        if (!std.meta.eql(current, scene)) return error.FakeStaleScene;
        self.resolve_count += 1;
        return if (self.resident) .resident else .fallback;
    }

    pub fn makeResident(self: *FakeRegistry, scene: SceneHandle) !void {
        const current = self.reserved orelse return error.FakeSceneMissing;
        if (!std.meta.eql(current, scene)) return error.FakeStaleScene;
        self.resident = true;
    }

    pub fn release(self: *FakeRegistry, scene: SceneHandle) !void {
        const current = self.reserved orelse return error.FakeSceneMissing;
        if (!std.meta.eql(current, scene)) return error.FakeStaleScene;
        self.reserved = null;
        self.resident = false;
        self.release_count += 1;
    }
};

const TestCoordinator = Coordinator(FakeRegistry, TestTicket);

const SharedFakeRegistry = struct {
    pub const Resolution = enum { fallback, resident };

    const Slot = struct {
        generation: u64 = 1,
        reserved: bool = false,
        resident: bool = false,
    };

    slots: [2]Slot = @splat(.{}),
    release_count: usize = 0,

    pub fn reserve(self: *SharedFakeRegistry) !SceneHandle {
        for (&self.slots, 0..) |*slot, index| {
            if (slot.reserved) continue;
            slot.reserved = true;
            slot.resident = false;
            return .{ .index = @intCast(index), .generation = slot.generation };
        }
        return error.FakeRegistryFull;
    }

    pub fn resolve(self: *SharedFakeRegistry, scene: SceneHandle) !Resolution {
        const slot = try self.current(scene);
        return if (slot.resident) .resident else .fallback;
    }

    pub fn makeResident(self: *SharedFakeRegistry, scene: SceneHandle) !void {
        (try self.current(scene)).resident = true;
    }

    pub fn release(self: *SharedFakeRegistry, scene: SceneHandle) !void {
        const slot = try self.current(scene);
        slot.reserved = false;
        slot.resident = false;
        slot.generation += 1;
        self.release_count += 1;
    }

    fn current(self: *SharedFakeRegistry, scene: SceneHandle) !*Slot {
        if (!scene.isValid() or scene.index >= self.slots.len) {
            return error.FakeStaleScene;
        }
        const slot = &self.slots[scene.index];
        if (!slot.reserved or slot.generation != scene.generation) {
            return error.FakeStaleScene;
        }
        return slot;
    }
};

const SharedTestCoordinator = Coordinator(SharedFakeRegistry, TestTicket);

test "logical activation resolves fallback before independent residency" {
    var registry = FakeRegistry{};
    var coordinator = TestCoordinator.init(&registry);
    const ticket = TestTicket{ .generation = 1 };

    const scene = try coordinator.beginRequest();
    try coordinator.loadAdmitted(scene, ticket);
    try coordinator.logicalActivated(ticket);

    try std.testing.expectEqual(StateTag.active, coordinator.stateTag());
    try std.testing.expectEqual(FakeRegistry.Resolution.fallback, try coordinator.resolve(
        ticket,
        scene,
    ));
    try std.testing.expectEqual(@as(usize, 1), registry.resolve_count);

    try registry.makeResident(scene);
    try std.testing.expectEqual(FakeRegistry.Resolution.resident, try coordinator.resolve(
        ticket,
        scene,
    ));
    try std.testing.expectEqual(StateTag.active, coordinator.stateTag());
}

test "logical unload waits for empty presentation before registry release" {
    var registry = FakeRegistry{};
    var coordinator = TestCoordinator.init(&registry);
    const ticket = TestTicket{ .generation = 4 };

    const scene = try coordinator.beginRequest();
    try coordinator.loadAdmitted(scene, ticket);
    try coordinator.logicalActivated(ticket);
    try coordinator.logicalUnloaded(ticket);

    try std.testing.expectEqual(StateTag.release_pending, coordinator.stateTag());
    try std.testing.expectEqual(@as(usize, 0), registry.release_count);
    try std.testing.expect(registry.reserved != null);
    try std.testing.expectError(
        error.DistrictPresentationNotActive,
        coordinator.resolve(ticket, scene),
    );

    try std.testing.expectError(
        error.DistrictPresentationStillExtracted,
        coordinator.presentationAbsent(1),
    );
    try std.testing.expectEqual(@as(usize, 0), registry.release_count);

    // Zero is the length of the extraction slice observed after the feature's
    // owner-thread unload commit.
    try coordinator.presentationAbsent(0);
    try std.testing.expectEqual(StateTag.idle, coordinator.stateTag());
    try std.testing.expectEqual(@as(usize, 1), registry.release_count);
    try std.testing.expectEqual(@as(?SceneHandle, null), registry.reserved);
}

test "cancel failure rejection and shutdown release exactly one generation" {
    var registry = FakeRegistry{};
    var coordinator = TestCoordinator.init(&registry);

    const rejected_scene = try coordinator.beginRequest();
    try coordinator.loadRejected(rejected_scene);
    try std.testing.expectEqual(@as(usize, 1), registry.release_count);

    const cancelled_scene = try coordinator.beginRequest();
    const cancelled_ticket = TestTicket{ .generation = 2 };
    try coordinator.loadAdmitted(cancelled_scene, cancelled_ticket);
    try coordinator.loadTerminated(cancelled_ticket);
    try std.testing.expectEqual(@as(usize, 2), registry.release_count);

    _ = try coordinator.beginRequest();
    try coordinator.releaseAfterSimulationTeardown();
    try std.testing.expectEqual(@as(usize, 3), registry.release_count);
    try std.testing.expectEqual(StateTag.idle, coordinator.stateTag());
}

test "stale tickets and scene generations cannot resolve or release current state" {
    var registry = FakeRegistry{};
    var coordinator = TestCoordinator.init(&registry);
    const current_ticket = TestTicket{ .generation = 7 };
    const stale_ticket = TestTicket{ .generation = 6 };
    const scene = try coordinator.beginRequest();
    try coordinator.loadAdmitted(scene, current_ticket);

    try std.testing.expectError(
        error.StaleDistrictTicket,
        coordinator.logicalActivated(stale_ticket),
    );
    try coordinator.logicalActivated(current_ticket);
    try std.testing.expectError(
        error.StaleSceneHandle,
        coordinator.resolve(current_ticket, .{
            .index = scene.index,
            .generation = scene.generation + 1,
        }),
    );
    try std.testing.expectEqual(@as(usize, 0), registry.release_count);
    try coordinator.releaseAfterSimulationTeardown();
}

test "two coordinators share one registry and unload reload independently" {
    var registry = SharedFakeRegistry{};
    var west = SharedTestCoordinator.init(&registry);
    var east = SharedTestCoordinator.init(&registry);
    const west_ticket = TestTicket{ .generation = 10 };
    const east_ticket = TestTicket{ .generation = 20 };

    const west_scene = try west.beginRequest();
    const east_scene = try east.beginRequest();
    try std.testing.expect(west_scene.index != east_scene.index);
    try west.loadAdmitted(west_scene, west_ticket);
    try east.loadAdmitted(east_scene, east_ticket);
    try west.logicalActivated(west_ticket);
    try east.logicalActivated(east_ticket);
    try registry.makeResident(west_scene);
    try registry.makeResident(east_scene);
    try std.testing.expectEqual(
        SharedFakeRegistry.Resolution.resident,
        try west.resolve(west_ticket, west_scene),
    );
    try std.testing.expectEqual(
        SharedFakeRegistry.Resolution.resident,
        try east.resolve(east_ticket, east_scene),
    );

    try west.logicalUnloaded(west_ticket);
    try west.presentationAbsent(0);
    try std.testing.expectEqual(StateTag.idle, west.stateTag());
    try std.testing.expectEqual(StateTag.active, east.stateTag());
    try std.testing.expectEqual(@as(usize, 1), registry.release_count);
    try std.testing.expectEqual(
        SharedFakeRegistry.Resolution.resident,
        try east.resolve(east_ticket, east_scene),
    );

    const west_reload_ticket = TestTicket{ .generation = 11 };
    const west_reloaded = try west.beginRequest();
    try std.testing.expectEqual(west_scene.index, west_reloaded.index);
    try std.testing.expect(west_reloaded.generation > west_scene.generation);
    try west.loadAdmitted(west_reloaded, west_reload_ticket);
    try west.logicalActivated(west_reload_ticket);
    try registry.makeResident(west_reloaded);
    try std.testing.expectEqual(
        SharedFakeRegistry.Resolution.resident,
        try west.resolve(west_reload_ticket, west_reloaded),
    );
    try std.testing.expectEqual(
        SharedFakeRegistry.Resolution.resident,
        try east.resolve(east_ticket, east_scene),
    );

    try west.releaseAfterSimulationTeardown();
    try east.releaseAfterSimulationTeardown();
    try std.testing.expectEqual(@as(usize, 3), registry.release_count);
    try std.testing.expectEqual(StateTag.idle, west.stateTag());
    try std.testing.expectEqual(StateTag.idle, east.stateTag());
}

test "proximity hysteresis produces stable enter and exit edges" {
    var policy = try ProximityHysteresis.init(.{
        .center_xz = .{ 0, 0 },
        .half_extent_xz = .{ 8, 8 },
        .load_margin = 2,
        .unload_margin = 6,
    });

    try std.testing.expectEqual(ProximityAction.none, try policy.observe(.{ 12, 12 }));
    // The square chunk's expanded corner is included; a center-radius policy
    // would incorrectly omit it.
    try std.testing.expectEqual(ProximityAction.enter, try policy.observe(.{ 10, 10 }));
    try std.testing.expectEqual(ProximityAction.none, try policy.observe(.{ 13.99, 0 }));
    try std.testing.expectEqual(ProximityAction.exit, try policy.observe(.{ 14, 0 }));
    // Once outside, the hysteresis band cannot immediately reload the scene.
    try std.testing.expectEqual(ProximityAction.none, try policy.observe(.{ 12, 0 }));
    try std.testing.expectEqual(ProximityAction.enter, try policy.observe(.{ 0, 0 }));
}

test "proximity policy validates configuration focus and explicit rearm" {
    try std.testing.expectError(
        error.InvalidDistrictProximityConfig,
        ProximityHysteresis.init(.{
            .center_xz = .{ 0, 0 },
            .half_extent_xz = .{ 8, 8 },
            .load_margin = 4,
            .unload_margin = 4,
        }),
    );
    var policy = try ProximityHysteresis.init(.{
        .center_xz = .{ 4, -2 },
        .half_extent_xz = .{ 8, 8 },
        .load_margin = 3,
        .unload_margin = 5,
    });
    try std.testing.expectError(
        error.InvalidDistrictFocusPosition,
        policy.observe(.{ std.math.nan(f32), 0 }),
    );
    try std.testing.expectEqual(ProximityAction.enter, try policy.observe(.{ 4, -2 }));
    policy.rearm();
    try std.testing.expectEqual(ProximityAction.enter, try policy.observe(.{ 4, -2 }));
}

test "proximity config rejects overflowed and collapsed derived boundaries per axis" {
    const maximum = std.math.floatMax(f32);
    const invalid_configs = [_]ProximityConfig{
        // Finite half extents and margins overflow while deriving thresholds.
        .{
            .center_xz = .{ 0, 0 },
            .half_extent_xz = .{ maximum, 8 },
            .load_margin = maximum / 4,
            .unload_margin = maximum / 2,
        },
        // Ordered margins collapse to the same x threshold at f32 precision.
        .{
            .center_xz = .{ 0, 0 },
            .half_extent_xz = .{ maximum, 8 },
            .load_margin = 0,
            .unload_margin = 1,
        },
        // Finite thresholds overflow when translated around the x center.
        .{
            .center_xz = .{ maximum * 0.75, 0 },
            .half_extent_xz = .{ maximum * 0.25, 8 },
            .load_margin = 0,
            .unload_margin = maximum * 0.125,
        },
        // Distinct thresholds collapse to identical x boundaries at the
        // center's representable precision.
        .{
            .center_xz = .{ 1.0e30, 0 },
            .half_extent_xz = .{ 1, 8 },
            .load_margin = 0,
            .unload_margin = 1,
        },
    };
    for (invalid_configs) |config| {
        try std.testing.expectError(
            error.InvalidDistrictProximityConfig,
            ProximityHysteresis.init(config),
        );
    }
}

test "proximity dead band absorbs jitter on every AABB side" {
    var policy = try ProximityHysteresis.init(.{
        .center_xz = .{ 3, -5 },
        .half_extent_xz = .{ 8, 6 },
        .load_margin = 2,
        .unload_margin = 5,
    });

    // Enter at the inclusive positive load corner. Once admitted, crossing
    // back and forth over the load boundary remains inside until an unload
    // side is reached.
    try std.testing.expectEqual(ProximityAction.enter, try policy.observe(.{ 13, 3 }));
    const inside_jitter = [_][2]f32{
        .{ 12.999, 3.001 },
        .{ 13.001, 2.999 },
        .{ -7.001, -12.999 },
        .{ -6.999, -13.001 },
        .{ 15.999, -5 },
        .{ 3, -15.999 },
    };
    for (inside_jitter) |position| {
        try std.testing.expectEqual(ProximityAction.none, try policy.observe(position));
    }

    try std.testing.expectEqual(ProximityAction.exit, try policy.observe(.{ 16, -5 }));

    // Once outside, jitter throughout the dead band cannot re-enter until the
    // focus reaches the inclusive load AABB on both axes.
    const outside_jitter = [_][2]f32{
        .{ 15.999, -5 },
        .{ 13.001, -5 },
        .{ -7.001, -5 },
        .{ 3, 5.001 },
        .{ 3, -13.001 },
    };
    for (outside_jitter) |position| {
        try std.testing.expectEqual(ProximityAction.none, try policy.observe(position));
    }
    try std.testing.expectEqual(ProximityAction.enter, try policy.observe(.{ -7, -13 }));
}

test "proximity AABB load corners are inclusive and unload sides are exclusive" {
    const config = ProximityConfig{
        .center_xz = .{ 0, 0 },
        .half_extent_xz = .{ 8, 6 },
        .load_margin = 2,
        .unload_margin = 5,
    };
    const load_corners = [_][2]f32{
        .{ -10, -8 },
        .{ -10, 8 },
        .{ 10, -8 },
        .{ 10, 8 },
    };
    for (load_corners) |corner| {
        var policy = try ProximityHysteresis.init(config);
        try std.testing.expectEqual(ProximityAction.enter, try policy.observe(corner));
    }

    const just_outside_load = [_][2]f32{
        .{ -10.001, -8 },
        .{ 10.001, 8 },
        .{ -10, -8.001 },
        .{ 10, 8.001 },
    };
    for (just_outside_load) |position| {
        var policy = try ProximityHysteresis.init(config);
        try std.testing.expectEqual(ProximityAction.none, try policy.observe(position));
    }

    const unload_sides = [_][2]f32{
        .{ -13, 0 },
        .{ 13, 0 },
        .{ 0, -11 },
        .{ 0, 11 },
    };
    for (unload_sides) |position| {
        var policy = try ProximityHysteresis.init(config);
        try std.testing.expectEqual(ProximityAction.enter, try policy.observe(.{ 0, 0 }));
        try std.testing.expectEqual(ProximityAction.exit, try policy.observe(position));
    }

    // A zero load margin is valid and includes the authored chunk boundary.
    var zero_margin = try ProximityHysteresis.init(.{
        .center_xz = .{ 0, 0 },
        .half_extent_xz = .{ 8, 6 },
        .load_margin = 0,
        .unload_margin = 1,
    });
    try std.testing.expectEqual(ProximityAction.enter, try zero_margin.observe(.{ 8, 6 }));
}

test "proximity policy rejects every non-finite configuration and focus path" {
    const nan = std.math.nan(f32);
    const infinity = std.math.inf(f32);
    const invalid_configs = [_]ProximityConfig{
        .{ .center_xz = .{ nan, 0 }, .half_extent_xz = .{ 8, 8 }, .load_margin = 2, .unload_margin = 4 },
        .{ .center_xz = .{ 0, infinity }, .half_extent_xz = .{ 8, 8 }, .load_margin = 2, .unload_margin = 4 },
        .{ .center_xz = .{ 0, 0 }, .half_extent_xz = .{ nan, 8 }, .load_margin = 2, .unload_margin = 4 },
        .{ .center_xz = .{ 0, 0 }, .half_extent_xz = .{ 8, infinity }, .load_margin = 2, .unload_margin = 4 },
        .{ .center_xz = .{ 0, 0 }, .half_extent_xz = .{ 0, 8 }, .load_margin = 2, .unload_margin = 4 },
        .{ .center_xz = .{ 0, 0 }, .half_extent_xz = .{ 8, -1 }, .load_margin = 2, .unload_margin = 4 },
        .{ .center_xz = .{ 0, 0 }, .half_extent_xz = .{ 8, 8 }, .load_margin = nan, .unload_margin = 4 },
        .{ .center_xz = .{ 0, 0 }, .half_extent_xz = .{ 8, 8 }, .load_margin = infinity, .unload_margin = 4 },
        .{ .center_xz = .{ 0, 0 }, .half_extent_xz = .{ 8, 8 }, .load_margin = -1, .unload_margin = 4 },
        .{ .center_xz = .{ 0, 0 }, .half_extent_xz = .{ 8, 8 }, .load_margin = 2, .unload_margin = nan },
        .{ .center_xz = .{ 0, 0 }, .half_extent_xz = .{ 8, 8 }, .load_margin = 2, .unload_margin = infinity },
        .{ .center_xz = .{ 0, 0 }, .half_extent_xz = .{ 8, 8 }, .load_margin = 2, .unload_margin = 1 },
    };
    for (invalid_configs) |config| {
        try std.testing.expectError(
            error.InvalidDistrictProximityConfig,
            ProximityHysteresis.init(config),
        );
    }

    var policy = try ProximityHysteresis.init(.{
        // Keep the configured boundaries finite and representably distinct,
        // while an opposite-extreme finite focus can still overflow `dx`.
        .center_xz = .{ -2.0e38, 0 },
        .half_extent_xz = .{ 1.0e37, 8 },
        .load_margin = 1.0e36,
        .unload_margin = 2.0e36,
    });
    const invalid_positions = [_][2]f32{
        .{ nan, 0 },
        .{ 0, nan },
        .{ infinity, 0 },
        .{ 0, -infinity },
        // Both inputs are finite, but their subtraction overflows to infinity.
        .{ std.math.floatMax(f32), 0 },
    };
    for (invalid_positions) |position| {
        try std.testing.expectError(
            error.InvalidDistrictFocusPosition,
            policy.observe(position),
        );
    }
}

fn runProximityTickScript(
    render_hz: u32,
    positions: []const [2]f32,
    actions: []ProximityAction,
) !void {
    if (actions.len != positions.len or render_hz == 0 or 240 % render_hz != 0) {
        return error.InvalidTestCadence;
    }
    var policy = try ProximityHysteresis.init(.{
        .center_xz = .{ 0, 0 },
        .half_extent_xz = .{ 8, 8 },
        .load_margin = 2,
        .unload_margin = 6,
    });

    // One unit is 1/240 second. A fixed 120 Hz tick consumes two units;
    // rendering at 240 Hz contributes one unit per frame and 80 Hz contributes
    // three. The script itself is sampled only at fixed-tick boundaries.
    const frame_units = 240 / render_hz;
    const tick_units = 2;
    var accumulated_units: u32 = 0;
    var tick_index: usize = 0;
    while (tick_index < positions.len) {
        accumulated_units += frame_units;
        while (accumulated_units >= tick_units and tick_index < positions.len) {
            accumulated_units -= tick_units;
            actions[tick_index] = try policy.observe(positions[tick_index]);
            tick_index += 1;
        }
    }
}

test "proximity tick script is cadence invariant at 240 and 80 render Hz" {
    const positions = [_][2]f32{
        .{ 11, 0 },
        .{ 10, 10 },
        .{ 10.001, 0 },
        .{ 13.999, 13.999 },
        .{ 14, 0 },
        .{ 13.999, 0 },
        .{ -10, -10 },
        .{ 0, -14 },
    };
    var at_240: [positions.len]ProximityAction = undefined;
    var at_80: [positions.len]ProximityAction = undefined;
    try runProximityTickScript(240, &positions, &at_240);
    try runProximityTickScript(80, &positions, &at_80);

    try std.testing.expectEqualSlices(ProximityAction, &at_240, &at_80);
    const expected = [_]ProximityAction{
        .none,
        .enter,
        .none,
        .none,
        .exit,
        .none,
        .enter,
        .exit,
    };
    try std.testing.expectEqualSlices(ProximityAction, &expected, &at_240);
}
