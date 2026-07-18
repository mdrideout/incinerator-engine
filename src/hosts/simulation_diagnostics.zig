//! Pure composition of concrete sandbox diagnostic snapshots.
//!
//! The live simulation gathers values from its owner-thread runtime, feature
//! owners, and physics capabilities. This module only combines those copied
//! values into the backend-neutral snapshot consumed by hosts and tools. It
//! owns no Runtime, Flecs world, Jolt object, feature, or borrowed backend
//! state.

const std = @import("std");
const contract = @import("sandbox_diagnostics_contract");

const Diagnostics = contract.Diagnostics;

/// Copied observations gathered by the concrete composition at one
/// owner-thread boundary. The two native controller observations intentionally
/// describe the same shared physics-global pool through independently issued
/// capabilities; disagreement is therefore an authority invariant failure.
pub const Inputs = struct {
    tick_index: u64,
    fixed_delta_seconds: f32,
    first_fault: @FieldType(Diagnostics, "first_fault"),
    entity_count: usize,
    body_count: u32,
    active_body_count: u32,
    character_native_used: usize,
    character_native_capacity: usize,
    npc_native_used: usize,
    npc_native_capacity: usize,
    crates: @FieldType(Diagnostics, "crates"),
    characters: @FieldType(Diagnostics, "characters"),
    vehicles: @FieldType(Diagnostics, "vehicles"),
    district: @FieldType(Diagnostics, "district"),
    interaction: @FieldType(Diagnostics, "interaction"),
    npc: @FieldType(Diagnostics, "npc"),
    npc_encounter: @FieldType(Diagnostics, "npc_encounter"),
    npc_replacement: @FieldType(Diagnostics, "npc_replacement"),
    district_worker: @FieldType(Diagnostics, "district_worker"),
};

/// Compose one immutable diagnostic snapshot without allocation or access to
/// live authority state. Counts that cross the public u32 diagnostic boundary
/// saturate visibly rather than wrapping.
pub fn compose(inputs: Inputs) Diagnostics {
    const native_used = diagnosticCount(inputs.character_native_used);
    const native_capacity = diagnosticCount(inputs.character_native_capacity);
    const feature_owned = std.math.add(
        u32,
        inputs.characters.active_count,
        inputs.npc.controller_count,
    ) catch std.math.maxInt(u32);

    return .{
        .tick_index = inputs.tick_index,
        .fixed_delta_seconds = inputs.fixed_delta_seconds,
        .first_fault = inputs.first_fault,
        .entity_count = diagnosticCount(inputs.entity_count),
        .body_count = inputs.body_count,
        .active_body_count = inputs.active_body_count,
        .character_controllers = .{
            .native_used = native_used,
            .native_capacity = native_capacity,
            .feature_owned = feature_owned,
            .authority_consistent = inputs.character_native_used == inputs.npc_native_used and
                inputs.character_native_capacity == inputs.npc_native_capacity and
                native_used <= native_capacity and
                native_used == feature_owned,
        },
        .crates = inputs.crates,
        .characters = inputs.characters,
        .vehicles = inputs.vehicles,
        .district = inputs.district,
        .interaction = inputs.interaction,
        .npc = inputs.npc,
        .npc_encounter = inputs.npc_encounter,
        .npc_replacement = inputs.npc_replacement,
        .district_worker = inputs.district_worker,
    };
}

fn diagnosticCount(value: usize) u32 {
    return std.math.cast(u32, value) orelse std.math.maxInt(u32);
}

fn testInputs() Inputs {
    return .{
        .tick_index = 19,
        .fixed_delta_seconds = 1.0 / 120.0,
        .first_fault = null,
        .entity_count = 7,
        .body_count = 5,
        .active_body_count = 4,
        .character_native_used = 3,
        .character_native_capacity = 128,
        .npc_native_used = 3,
        .npc_native_capacity = 128,
        .crates = .{
            .active_count = 1,
            .commands = .{},
            .outcomes = .{},
        },
        .characters = .{
            .active_count = 1,
            .commands = .{},
            .outcomes = .{},
            .events = .{},
            .events_dropped = 0,
        },
        .vehicles = .{
            .active_count = 1,
            .commands = .{},
            .outcomes = .{},
            .events = .{},
            .events_dropped = 0,
        },
        .district = .{
            .active_count = 1,
            .loading_count = 0,
            .cancelling_count = 0,
            .body_count = 2,
            .slots = @splat(.{
                .state = .absent,
                .request_id = null,
                .ticket = null,
            }),
            .commands = .{},
            .outcomes = .{},
            .outcome_reservations = 0,
            .events = .{},
        },
        .interaction = .{
            .active_count = 1,
            .district_owned_count = 1,
            .held_count = 0,
            .dynamic_body_count = 1,
            .dormant_count = 0,
            .bodies_suspended = 0,
            .bodies_resumed = 0,
            .commands = .{},
            .outcomes = .{},
        },
        .npc = .{
            .active_count = 2,
            .waiting_count = 0,
            .dormant_count = 0,
            .controller_count = 2,
            .transfers = 0,
            .controllers_suspended = 0,
            .controllers_resumed = 0,
            .commands = .{},
            .outcomes = .{},
            .events = .{},
            .event_drops = .{},
        },
        .npc_encounter = .{
            .records = 1,
            .patrolling = 1,
            .pursuing = 0,
            .attack_windup = 0,
            .attack_recovery = 0,
            .searching = 0,
            .returning = 0,
            .candidates_considered = 0,
            .los_queries = 0,
            .los_deferred = 0,
            .targets_acquired = 0,
            .targets_switched = 0,
            .targets_lost = 0,
            .attacks_started = 0,
            .attacks_committed = 0,
            .attacks_cancelled = 0,
            .hit_reactions = 0,
            .directives_pending = 0,
            .damage_pending = 0,
            .cues_pending = 0,
            .transition_history = 0,
        },
        .npc_replacement = .{
            .pending = 0,
            .awaiting_spawn = 0,
            .attempts = 0,
            .replacements_ready = 0,
            .retries = 0,
            .district_inactive = 0,
            .occupied = 0,
            .too_close_to_player = 0,
            .visible_to_player = 0,
            .outcomes_pending = 0,
            .outcomes_high_water = 0,
        },
        .district_worker = .{
            .state = .idle,
            .generation = null,
            .started = false,
            .cancellation_requested = false,
            .completion_kind = null,
        },
    };
}

test "composition preserves copied diagnostics and proves controller ownership" {
    var inputs = testInputs();
    inputs.crates.commands = .{
        .occupancy = 2,
        .high_water = 3,
        .capacity = 8,
        .rejected = 1,
    };

    const result = compose(inputs);
    try std.testing.expectEqual(@as(u64, 19), result.tick_index);
    try std.testing.expectEqual(@as(u32, 7), result.entity_count);
    try std.testing.expectEqual(@as(u32, 3), result.character_controllers.native_used);
    try std.testing.expectEqual(@as(u32, 128), result.character_controllers.native_capacity);
    try std.testing.expectEqual(@as(u32, 3), result.character_controllers.feature_owned);
    try std.testing.expect(result.character_controllers.authority_consistent);
    try std.testing.expectEqual(inputs.crates.commands, result.crates.commands);
    try std.testing.expectEqual(inputs.district_worker, result.district_worker);
}

test "controller capability disagreement is visible without changing feature values" {
    var inputs = testInputs();
    inputs.npc_native_used = 2;

    const result = compose(inputs);
    try std.testing.expect(!result.character_controllers.authority_consistent);
    try std.testing.expectEqual(@as(u32, 1), result.characters.active_count);
    try std.testing.expectEqual(@as(u32, 2), result.npc.controller_count);
}

test "public diagnostic counts saturate instead of wrapping" {
    var inputs = testInputs();
    inputs.entity_count = @as(usize, std.math.maxInt(u32)) + 1;
    inputs.character_native_used = @as(usize, std.math.maxInt(u32)) + 1;
    inputs.npc_native_used = inputs.character_native_used;
    inputs.characters.active_count = std.math.maxInt(u32);
    inputs.npc.controller_count = 1;

    const result = compose(inputs);
    try std.testing.expectEqual(std.math.maxInt(u32), result.entity_count);
    try std.testing.expectEqual(
        std.math.maxInt(u32),
        result.character_controllers.native_used,
    );
    try std.testing.expectEqual(
        std.math.maxInt(u32),
        result.character_controllers.feature_owned,
    );
    try std.testing.expect(!result.character_controllers.authority_consistent);
}
