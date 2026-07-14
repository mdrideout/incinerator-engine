//! Quantitative starting contract for the first multiplayer vertical slice.
//!
//! These values are admission ceilings and validation profiles, not promises
//! about public Internet service quality. They are intentionally centralized
//! so tests, diagnostics, and documentation cannot silently disagree.

pub const authority_tick_hz: u32 = 60;
pub const snapshot_hz: u32 = 20;
pub const ticks_per_snapshot: u32 = authority_tick_hz / snapshot_hz;
pub const max_participants: usize = 16;
pub const product_participants: usize = 8;
pub const max_vehicles: usize = 4;
pub const product_vehicles: usize = 1;
pub const max_carryables: usize = 4;
pub const product_carryables: usize = 1;
pub const max_relevant_districts_per_client: usize = 4;
pub const product_relevant_districts_per_client: usize = 1;
pub const max_npcs: usize = 64;
pub const product_npcs: usize = 64;
pub const npc_snapshot_hz: u32 = 10;
pub const ticks_per_npc_snapshot: u32 = authority_tick_hz / npc_snapshot_hz;
pub const snapshot_history_capacity: usize = 8;
pub const full_snapshot_interval_ticks: u64 = authority_tick_hz;
pub const max_delta_base_age_ticks: u64 = authority_tick_hz * 2;
pub const max_snapshot_starvation_ticks: u64 = authority_tick_hz / 5;
pub const max_reliable_events_per_tick: u16 = 16;
pub const admission_nonce_history_capacity: usize = 256;

pub const max_wire_message_bytes: usize = 64 * 1024;
pub const max_snapshot_bytes: usize = 32 * 1024;
pub const max_relevant_entities_per_client: usize = 2_048;
pub const max_baseline_bytes_per_client: usize = 4 * 1024 * 1024;

pub const inbound_message_capacity: usize = 256;
pub const outbound_message_capacity: usize = 512;
pub const inbound_bytes_per_connection: usize = 512 * 1024;
pub const outbound_bytes_per_connection: usize = 2 * 1024 * 1024;

pub const input_history_ticks: u32 = 256;
pub const vehicle_prediction_horizon_ticks: u16 = 12;
pub const max_future_input_ticks: u64 = 6;
pub const input_hold_ticks: u64 = 6;
pub const max_input_messages_per_tick: u16 = 8;
pub const accepted_ingress_capacity: usize = 2_048;
pub const reconnect_grace_ticks: u64 = authority_tick_hz * 10;
pub const handshake_timeout_ticks: u64 = authority_tick_hz * 5;
pub const idle_timeout_ticks: u64 = authority_tick_hz * 10;

pub const average_client_up_bytes_per_second: usize = 16 * 1024;
pub const peak_client_up_bytes_per_second: usize = 32 * 1024;
pub const average_client_down_bytes_per_second: usize = 96 * 1024;
pub const peak_client_down_bytes_per_second: usize = 192 * 1024;

pub const nominal_profile = ImpairmentProfile{
    .rtt_ms = 80,
    .jitter_ms = 10,
    .loss_percent = 1,
    .duplicate_percent = 0.1,
    .reorder_percent = 0.5,
};

pub const adverse_profile = ImpairmentProfile{
    .rtt_ms = 160,
    .jitter_ms = 30,
    .loss_percent = 5,
    .duplicate_percent = 1,
    .reorder_percent = 2,
};

pub const ImpairmentProfile = struct {
    rtt_ms: u16,
    jitter_ms: u16,
    loss_percent: f32,
    duplicate_percent: f32,
    reorder_percent: f32,
};

pub const PredictionThresholds = struct {
    soft_position_error_m: f32 = 0.10,
    hard_position_error_m: f32 = 2.0,
    maximum_snapshot_age_ms: u16 = 250,
    maximum_soft_corrections_per_minute: u16 = 120,
};

pub const prediction_thresholds = PredictionThresholds{};

pub const VehiclePredictionThresholds = struct {
    soft_position_error_m: f32 = 0.15,
    hard_position_error_m: f32 = 2.5,
    soft_orientation_error_degrees: f32 = 4.0,
    hard_orientation_error_degrees: f32 = 45.0,
    maximum_soft_corrections_per_minute: u16 = 180,
};

pub const vehicle_prediction_thresholds = VehiclePredictionThresholds{};

comptime {
    if (authority_tick_hz % snapshot_hz != 0) {
        @compileError("snapshot rate must divide authority tick rate");
    }
    if (product_participants > max_participants) {
        @compileError("product participant target exceeds validation ceiling");
    }
    if (product_vehicles > max_vehicles) {
        @compileError("product vehicle target exceeds validation ceiling");
    }
    if (product_carryables > max_carryables) {
        @compileError("product carryable target exceeds validation ceiling");
    }
    if (product_npcs > max_npcs or authority_tick_hz % npc_snapshot_hz != 0) {
        @compileError("NPC capacity/rate contract is invalid");
    }
    if (max_snapshot_bytes > max_wire_message_bytes) {
        @compileError("snapshot ceiling exceeds wire message ceiling");
    }
    if (vehicle_prediction_horizon_ticks == 0 or
        vehicle_prediction_horizon_ticks > input_history_ticks)
    {
        @compileError("vehicle prediction horizon must fit the input history");
    }
}

test "MP0 budgets retain the accepted rate and capacity relationships" {
    const std = @import("std");
    try std.testing.expectEqual(@as(u32, 3), ticks_per_snapshot);
    try std.testing.expect(product_participants <= max_participants);
    try std.testing.expect(max_snapshot_bytes <= max_wire_message_bytes);
    try std.testing.expect(adverse_profile.rtt_ms > nominal_profile.rtt_ms);
    try std.testing.expect(adverse_profile.loss_percent > nominal_profile.loss_percent);
}
