# MP4-A2 Bounded Vehicle Prediction

**Status:** Implemented and accepted

**Date:** 2026-07-13

## Decision

Use a deliberately small client-side vehicle motion predictor before adding a
client Jolt scene. The predictor exists only for the locally owned vehicle and
only changes presentation. The authority's Jolt chassis, collision results,
seat ownership, and snapshots remain canonical.

This is not velocity extrapolation presented as prediction. Every locally sent
vehicle input is recorded with its sequence and target tick, applied to a
bounded input-driven motion model, discarded when acknowledged, and replayed
from each new authoritative chassis sample.

## Boundary

The predictor is a separate client module with no Flecs, Jolt, save, feature,
or authority dependency. It owns:

- one disposable predicted `VehicleState`;
- a fixed 256-record input history;
- a maximum 12-tick (200 ms at 60 Hz) prediction lead;
- presentation-only position and quaternion correction offsets; and
- correction, history, horizon, ownership, and transport diagnostics.

It does not own collision, occupancy, damage, drivetrain state, wheels,
district residency, or persistent identity. Remote vehicles continue to use
snapshot interpolation.

## Motion model

The current model integrates bounded longitudinal acceleration, rolling and
brake deceleration, forward/reverse limits, and speed-scaled yaw. It preserves
the authoritative chassis height and applies yaw deltas to the authoritative
quaternion, so it does not invent suspension, airborne, pitch, or roll state.

This model is intentionally replaceable. Its purpose is immediate input
response with measured reconciliation—not cross-machine Jolt determinism.

## Reconciliation

On each owned-vehicle snapshot the client:

1. removes inputs at or below the acknowledged sequence;
2. seeds from authoritative pose and velocity;
3. reapplies retained inputs no farther than 12 ticks beyond that snapshot;
4. measures position, orientation, and velocity divergence;
5. smoothly retains the old presentation across a soft correction; or
6. snaps to authority at 2.5 m or 45 degrees.

Prediction is discarded on exit, ownership loss, terminal rejection, and
transport loss. Reconnect recreates it only after a confirmed owned snapshot.
During a long blackout, new inputs still reach the transport but presentation
prediction stops at the 200 ms horizon.

## Collision and exit policy

Collision remains authoritative. Tests inject an authoritative collision stop
and dynamic-impact correction to prove bounded smoothing and snap behavior.
A future client Jolt scene is justified only if playtesting shows that these
bounded corrections are unacceptable once replicated district collision is
available.

Vehicle exit now tries five authority-derived collision-safe placements: the
configured side, the opposite side, both longitudinal ends, and a vertical
fallback. If every placement is blocked during disconnect teardown, a typed
teardown-only abandon command releases the seat without presenting an invalid
on-foot pose, then immediately despawns the hidden character.

## Playtest surface

The installed graphical client exposes:

- `E`: enter or exit;
- `W/S`: throttle or reverse;
- `A/D`: steer;
- `Space`: service brake;
- `Left Shift`: hand brake;
- `P`: toggle owned-vehicle prediction for live A/B comparison;
- `F8`: manufacture a transport disconnect and exercise reconnect; and
- `Escape`: quit.

The title reports ping, snapshot age, prediction mode, soft/hard correction
counts, and maximum position/orientation divergence.

Acceptance evidence is recorded in
[`../validation/mp4a2-acceptance.md`](../validation/mp4a2-acceptance.md).
