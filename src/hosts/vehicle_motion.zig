//! Observational vehicle/frame evidence; never a control or mutation authority.
const engine = @import("incinerator_engine");
const protocol = @import("session_protocol");

pub const Frame = struct {
    semantic_entity: engine.gameplay_trace.EntityRef,
    authority_tick: u64,
    presentation_frame: u64,
    frame_time_ms: f64,
    fixed_alpha: f32,
    snapshot_alpha: f32,
    previous_snapshot_tick: u64,
    snapshot_tick: u64,
    latest_snapshot_tick: u64,
    entity: protocol.VehicleState,
    persistent_id: engine.PersistentId,
    raw_input: engine.physics.VehicleInput,
    applied_input: engine.physics.VehicleInput,
    conditioned_steering: f32,
    authority: engine.physics.VehicleState,
    predicted_pose: ?engine.physics.Pose,
    presented_pose: engine.physics.Pose,
    presented_wheels: [4]engine.physics.Pose,
    camera_position: [3]f32,
    camera_yaw: f32,
    camera_pitch: f32,
    camera_mode: []const u8,
    forward_mps: f32,
    lateral_mps: f32,
    prediction_error_m: f32,
    prediction_soft_corrections: u64,
    prediction_hard_corrections: u64,
};
