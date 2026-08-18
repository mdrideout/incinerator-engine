//! Canonical value contract for the streamed-district gameplay slice.
//! Runtime residency, loader ownership, physics bodies, and systems remain in
//! the feature implementation.

const std = @import("std");
const engine = @import("engine_contracts");
const district_contract = @import("district_contract");

pub const max_districts: usize = 4;
pub const max_pending_commands: usize = 16;
pub const max_outcomes: usize = 32;
pub const max_events: usize = 16;

pub const Assets = struct {
    /// One scene-level identity preserves cooked nodes, authored transforms,
    /// mesh instances, material relationships, and textures behind the
    /// renderer-owned registry boundary. Its residency is never an activation
    /// prerequisite.
    scene: engine.rendering.SceneHandle = .invalid,
};

pub const StateTag = enum { absent, loading, cancelling, active };

pub const SlotDiagnostics = struct {
    state: StateTag,
    request_id: ?u64,
    ticket: ?district_contract.LoadTicket,
};

pub const Diagnostics = struct {
    active_count: u32,
    loading_count: u32,
    cancelling_count: u32,
    body_count: u32,
    slots: [max_districts]SlotDiagnostics,
    commands: engine.diagnostics.QueueStats,
    outcomes: engine.diagnostics.QueueStats,
    /// Outcome slots promised to accepted commands or the one in-flight
    /// loader transition. Occupancy plus reservations never exceeds capacity.
    outcome_reservations: u32,
    events: engine.diagnostics.QueueStats,
};

pub const RequestLoad = struct {
    request_id: u64,
    coord: district_contract.ChunkCoord,
    assets: Assets,
};

pub const CancelLoad = struct {
    request_id: u64,
    ticket: district_contract.LoadTicket,
};

pub const Unload = struct {
    request_id: u64,
    ticket: district_contract.LoadTicket,
};

pub const Command = union(enum) {
    request_load: RequestLoad,
    cancel_load: CancelLoad,
    unload: Unload,
};

pub const CommandKind = enum { request_load, cancel_load, unload };

pub const RejectionReason = enum {
    district_not_absent,
    district_not_loading,
    district_not_active,
    coordinate_already_present,
    district_capacity_reached,
    stale_ticket,
    loader_busy,
    loader_stale,
    loader_idle,
    invalid_ticket,
};

pub const CommandRejected = struct {
    command: CommandKind,
    reason: RejectionReason,
    request_id: u64,
    ticket: ?district_contract.LoadTicket = null,
};

pub const LoadRequested = struct {
    request_id: u64,
    ticket: district_contract.LoadTicket,
};

pub const CancellationRequested = struct {
    request_id: u64,
    ticket: district_contract.LoadTicket,
};

pub const Activated = struct {
    request_id: u64,
    ticket: district_contract.LoadTicket,
    id: engine.PersistentId,
    coord: district_contract.ChunkCoord,
    static_box_count: u8,
};

pub const LoadCancelled = struct {
    ticket: district_contract.LoadTicket,
};

pub const LoadFailed = struct {
    request_id: u64,
    ticket: district_contract.LoadTicket,
    failure: district_contract.Failure,
};

pub const Unloaded = struct {
    request_id: u64,
    ticket: district_contract.LoadTicket,
    id: engine.PersistentId,
};

pub const Outcome = union(enum) {
    load_requested: LoadRequested,
    cancellation_requested: CancellationRequested,
    activated: Activated,
    cancelled: LoadCancelled,
    load_failed: LoadFailed,
    unloaded: Unloaded,
    rejected: CommandRejected,
};

pub const LoadStarted = struct {
    ticket: district_contract.LoadTicket,
    coord: district_contract.ChunkCoord,
};

pub const DistrictActivated = struct {
    ticket: district_contract.LoadTicket,
    id: engine.PersistentId,
};

pub const DistrictDeactivated = struct {
    ticket: district_contract.LoadTicket,
    id: ?engine.PersistentId,
    reason: enum { cancelled, failed, unloaded },
};

pub const StaleCompletion = struct {
    expected: district_contract.LoadTicket,
    received: district_contract.LoadTicket,
};

pub const Event = union(enum) {
    load_started: LoadStarted,
    cancellation_started: district_contract.LoadTicket,
    activated: DistrictActivated,
    deactivated: DistrictDeactivated,
    stale_completion: StaleCompletion,
};

/// Immutable logical draw input. The renderer may resolve these handles to a
/// fallback while an independent GPU residency operation is still pending.
pub const DistrictDraw = struct {
    persistent_id: engine.PersistentId,
    ticket: district_contract.LoadTicket,
    build: district_contract.DistrictBuild,
    assets: Assets,
};

/// Logical persistence record. Transient jobs, tickets, physics handles,
/// queues, and presentation resources are deliberately excluded.
pub const DistrictV1 = struct {
    id: engine.PersistentId,
    coord: district_contract.ChunkCoord,
    recipe_version: u32,
    checksum: u64,
};

pub fn validateRecords(
    comptime CanonicalContent: type,
    records: []const DistrictV1,
) !void {
    if (records.len > max_districts) return error.TooManyDistricts;
    for (records, 0..) |record, index| {
        try record.id.validate();
        for (records[0..index]) |earlier| {
            if (district_contract.ChunkCoord.eql(earlier.coord, record.coord)) {
                return error.DuplicateDistrictCoordinate;
            }
            if (std.meta.eql(earlier.id, record.id)) {
                return error.DuplicateDistrictPersistentId;
            }
        }
        if (record.recipe_version != CanonicalContent.current_recipe_version) {
            return error.UnsupportedDistrictRecipeVersion;
        }
        const build = switch (CanonicalContent.build(
            record.coord,
            record.recipe_version,
        )) {
            .ready => |value| value,
            .failed => return error.InvalidDistrictRecord,
        };
        try build.validate();
        if (build.checksum != record.checksum) return error.DistrictChecksumMismatch;
    }
}

test "district contract accepts the canonical empty record set" {
    const Content = struct {
        pub const current_recipe_version: u32 = 1;
        const Result = union(enum) {
            ready: district_contract.DistrictBuild,
            failed,
        };
        pub fn build(_: district_contract.ChunkCoord, _: u32) Result {
            return .failed;
        }
    };
    try validateRecords(Content, &.{});
}
