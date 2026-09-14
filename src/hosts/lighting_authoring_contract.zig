//! Shared typed presentation transactions. UI and CLI are producers, not owners.
const std = @import("std");
const engine = @import("engine_contracts");
pub const library = @import("content").lighting_library;
pub const Value = library.Value;
pub const Action = union(enum) { preview: Value, clear_preview, apply: Value, revert, undo, redo, commit, activate };
pub const Request = struct { target: engine.assets.AssetId, expected_revision: u64, action: Action };
pub const Rejection = enum { target_missing, stale_revision, invalid_value, wrong_value_kind, preview_owned_by_another_producer, persistence_unavailable, persistence_failed, nothing_to_undo, nothing_to_redo };
pub const Outcome = struct { transaction_id: u64, source: engine.authoring.Source, target: engine.assets.AssetId, action: std.meta.Tag(Action), revision: u64, asset_revision: u64, library_revision: u64, rejection: ?Rejection = null };
pub const Record = struct {
    id: engine.assets.AssetId,
    label: []const u8,
    revision: u64,
    asset_revision: u64,
    committed: Value,
    session: Value,
    preview: ?struct { source: engine.authoring.Source, value: Value } = null,
    pub fn presented(self: Record) Value {
        return if (self.preview) |preview| preview.value else self.session;
    }
    pub fn dirty(self: Record) bool {
        return !std.meta.eql(self.session, self.committed);
    }
};
pub const Evidence = struct { request: Request, outcome: Outcome, before: ?Record, after: ?Record, active_environment: engine.assets.AssetId };
pub const View = struct { records: []const Record, active_environment: engine.assets.AssetId, library_revision: u64, last_ui_outcome: ?Outcome, persistence_available: bool, installed_root: ?[]const u8 = null, project_root: ?[]const u8 = null };
pub const Requests = struct {
    allocator: std.mem.Allocator,
    pending: std.ArrayList(Request) = .empty,
    pub fn submit(self: *Requests, request: Request) !void {
        try self.pending.append(self.allocator, request);
    }
    pub fn deinit(self: *Requests) void {
        self.pending.deinit(self.allocator);
    }
};
pub const Input = struct { view: View, requests: *Requests };

pub const Field = struct { path: []const u8, unit: []const u8, description: []const u8 };
pub const fields = [_]Field{
    .{ .path = "environment.sun", .unit = "lux / linear RGB", .description = "Directional illuminance; position is ignored." },
    .{ .path = "environment.sun_direction", .unit = "unit vector", .description = "Emitted ray direction from the sun toward the scene." },
    .{ .path = "environment.ambient", .unit = "linear irradiance", .description = "Authored constant fill; not simulated indirect bounce." },
    .{ .path = "environment.background", .unit = "linear radiance", .description = "Background shaded through the same exposure and display transform." },
    .{ .path = "environment.display.exposure", .unit = "multiplier", .description = "Applied once in HDR shading, before bloom and Reinhard/sRGB resolve." },
    .{ .path = "environment.display.bloom_strength", .unit = "multiplier", .description = "Optical halo contribution; zero disables bloom, without disabling illumination." },
    .{ .path = "environment.display.bloom_threshold", .unit = "exposed linear RGB", .description = "Threshold for the first downsample; independent of light transport." },
    .{ .path = "environment.display.bloom_radius", .unit = "pixels", .description = "Selects the reduced-resolution bloom pyramid extent." },
    .{ .path = "environment.shadow_resolution", .unit = "pixels per view", .description = "Depth-array width and height. Point and hemispherical spot lights use six views." },
    .{ .path = "environment.shadow_bias", .unit = "normalized depth", .description = "Receiver comparison offset; adjust with resolution and projection to avoid acne or detached shadows." },
    .{ .path = "fixture.light.intensity", .unit = "candela (point/spot), lux (directional)", .description = "Direct illumination, independent of the material emission scale." },
    .{ .path = "fixture.light.color", .unit = "linear RGB", .description = "Nonnegative color multiplier for direct illumination." },
    .{ .path = "fixture.light.range", .unit = "metres or null", .description = "Smooth finite cutoff; null is unbounded and is never replaced by an implicit radius." },
    .{ .path = "fixture.light.source_radius", .unit = "metres", .description = "Near-source inverse-square regularization; does not create physical area-light shadows." },
    .{ .path = "fixture.light.inner_angle", .unit = "radians (half angle)", .description = "Full-intensity spot cone. Lighting Lab displays degrees." },
    .{ .path = "fixture.light.outer_angle", .unit = "radians (half angle)", .description = "Zero-intensity outer cone; smooth transition from inner to outer." },
    .{ .path = "fixture.pose", .unit = "metres / quaternion", .description = "World pose or local rigid mount; -Z is forward and +Y is up." },
    .{ .path = "fixture.mount", .unit = "world / vehicle_asset / carryable", .description = "Game presentation parent, resolved from the exact parent color-draw pose." },
    .{ .path = "fixture.surface", .unit = "mesh identity / multiplier", .description = "Emission on an existing cooked surface; disappears with that surface's visual residency." },
    .{ .path = "fixture.visual", .unit = "mesh/material identities / metres / multiplier", .description = "Mounted cooked lens geometry, kept separate from vehicle physics and shared material state." },
    .{ .path = "fixture.follows_night", .unit = "boolean", .description = "Applies the environment artificial-light switch; vehicle rigs also obey headlights_enabled." },
};
