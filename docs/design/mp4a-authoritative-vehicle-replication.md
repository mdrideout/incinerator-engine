# MP4-A1 Authoritative Vehicle Replication

**Status:** Implemented and accepted

**Date:** 2026-07-13

## Objective

Prove one real Jolt vehicle as a multiplayer-owned gameplay feature without
creating a generic replication layer or a second client authority. A player
can request entry, drive through lossy sequenced input, disconnect/reconnect
while occupying the seat, and request exit. Every observer derives occupancy
and chassis presentation from the same server projection.

## Ownership and message model

| Semantic | Delivery | Authority behavior |
|---|---|---|
| Enter/exit request | Reliable gameplay lane | Validate session, participant, action sequence, target vehicle, current mode, then submit the existing typed feature command |
| Enter/exit result | Reliable gameplay lane | Correlate the feature outcome with the request; report entered, exited, or a bounded domain rejection |
| Driving input | Unreliable input lane | Validate shared input sequence, target tick, current driver, replicated vehicle, finite normalized controls, and per-tick quota |
| Vehicle snapshot | Unreliable snapshot lane | Project backend-neutral chassis pose/velocity and optional driver participant |

Replicated seat ownership is dynamic input authority, not durable ownership of
the vehicle. An empty vehicle is authority-owned. A participant may control it
only while the authoritative `VehicleFeature` reports that participant's
character as its driver.

## Authority flow

1. The session creates one configured vehicle through the normal sandbox
   command path and assigns a generational replicated ID.
2. A reliable enter request resolves replicated ID to the authority-private
   persistent ID and submits `VehicleFeature.enter`.
3. Only the feature outcome commits the session's driver projection and emits a
   correlated result.
4. Fresh owned vehicle input becomes the feature's next fixed-tick drive
   command. Missing, stale, mismatched, disconnected, or expired input resolves
   to neutral controls.
5. Exit follows the same request/outcome transaction. The character becomes
   visible at the feature-authorized exit pose after the snapshot confirms the
   released seat.
6. Transport loss retains the participant and seat during reconnect grace but
   clears held controls. Grace expiry or graceful leave exits first and
   despawns the character only after the feature confirms exit.

## Client flow

The client keeps bounded character and vehicle arrays with previous/current
state. It interpolates remote and local authoritative chassis snapshots, hides
the character whose participant occupies a vehicle, and changes the camera and
input mapping from on-foot to vehicle only after confirmed snapshot ownership.
It cannot write transforms, occupancy, Jolt state, or persistence.

The graphical control is `E` to request enter/exit. `W/S` map to throttle and
reverse, `A/D` to steering, and `Space` to service brake while driving.

## Replay and diagnostics

The fixed 2,048-entry ingress journal now records character input, vehicle
input, enter, and exit with participant, connection generation, sequence,
admission tick, target tick, target replicated entity, and normalized intent.
The deterministic acceptance runner replays those records into a fresh
one-world authority and compares character identity/state, vehicle
identity/driver, pose, linear/angular velocity, and quaternion orientation.

Diagnostics distinguish accepted/rejected vehicle actions, stale action
sequences, invalid control ownership, queue pressure, impairment decisions,
snapshot age, bytes, and ingress fingerprint.

## Explicit nonclaims

- A1 does not implement locally simulated vehicle prediction or collision
  rollback.
- It does not replicate wheels, drivetrain/contact caches, damage, passengers,
  multiple seats, relevance, delta baselines, or prioritization.
- It does not claim Jolt determinism across machines.
- The development account remains unauthenticated and direct-IP remains a
  trusted-development route.

Those omissions are sequenced in
[`mp4-feature-replication-sequence.md`](mp4-feature-replication-sequence.md).

One concrete pressure point is retained in the architecture register: the
current vehicle feature has one configured exit placement. Normal blocked exit
is an honest rejected gameplay result, but disconnect cleanup needs a bounded
alternate-placement or forced-cleanup policy before district geometry makes a
permanently blocked exit plausible.
