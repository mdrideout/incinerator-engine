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
/// coordinator deliberately does not inspect which one it received.
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
