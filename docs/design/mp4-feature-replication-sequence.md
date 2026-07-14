# MP4 Feature Replication Sequence

**Status:** Complete; MP4-A through MP4-E are implemented and accepted

**Last reviewed:** 2026-07-14

MP4 is a sequence of pressure-driven vertical slices. Every slice reuses the
MP3 authority, deterministic impairment, diagnostics, and replay contracts.
None may introduce reflective ECS replication, expose private Flecs/Jolt
state, or turn a client approximation into authority.

## MP4-A — Vehicle

### MP4-A1 authoritative replication — complete

- Reliable, sequenced enter/exit requests target a generational replicated
  vehicle ID and receive a correlated domain result.
- Continuous throttle/steering/brake input is unreliable, tick-addressed,
  ownership-validated, quota-bound, and neutralized when input expires.
- The existing sandbox `VehicleFeature` and real Jolt vehicle remain the sole
  physics and seat authority.
- Snapshots project chassis pose/velocity and optional driver identity, never a
  Jolt handle, constraint, wheel cache, Flecs ID, or durable-save record.
- The lightweight client interpolates chassis state, hides the driving
  character, changes camera target, and renders the same confirmed seat
  ownership for local and remote participants.
- Accepted character input, vehicle input, enter, and exit share one bounded
  semantic ingress journal and replay into a fresh authority.
- Reconnect preserves confirmed occupancy; graceful departure exits before
  character despawn; an unoccupied or disconnected vehicle receives neutral
  input.

Design: [`mp4a-authoritative-vehicle-replication.md`](mp4a-authoritative-vehicle-replication.md)

Evidence: [`../validation/mp4a-acceptance.md`](../validation/mp4a-acceptance.md)

### MP4-A2 local vehicle responsiveness — complete

- A separate lightweight predictor records actual owned-vehicle inputs,
  replays unacknowledged history from authority, and immediately updates only
  local presentation.
- Prediction is capped at 12 ticks/200 ms and cannot survive ownership or
  transport loss. Remote vehicles remain interpolated.
- Soft position/quaternion correction is measured; 2.5 m or 45 degree errors
  snap to authority. Nominal/adverse trials produced no hard correction.
- Static collision-stop and dynamic-impact corrections, blackout recovery,
  real-GNS reconnect, enter/exit, and ownership contention are covered.
- `P` provides live prediction/interpolation A/B testing and `F8` manufactures
  a reconnect in the installed graphical client.
- Vehicle exit tries five authority-selected placements. Exhausted disconnect
  cleanup uses a typed teardown-only seat release before hidden-character
  despawn; it never publishes a collision-invalid client pose.

Design:
[`mp4a2-bounded-vehicle-prediction.md`](mp4a2-bounded-vehicle-prediction.md)

Evidence: [`../validation/mp4a2-acceptance.md`](../validation/mp4a2-acceptance.md)

## MP4-B — Carry interaction

**Status:** complete. Design:
[`mp4b-authoritative-carry-interaction.md`](mp4b-authoritative-carry-interaction.md).
Evidence: [`../validation/mp4b-acceptance.md`](../validation/mp4b-acceptance.md).

**Entry:** MP4-A ownership and reconnect semantics remain green.

- Add reliable collect/drop requests with correlated outcomes and an
  unreliable replaceable carryable projection where appropriate.
- Preserve feature-owned district/held/dormant authority and transactional
  rollback from S7.
- Define cancellation during disconnect, district unload, ownership loss, and
  cross-district transfer.
- Extend semantic replay with accepted collect/drop requests and rejected
  outcomes that can affect subsequent play.

**Exit:** two clients contend for one carryable under nominal/adverse faults;
ownership is never duplicated; reconnect/JIP reconstructs the confirmed
holder; queues and payload remain bounded.

## MP4-C — District relevance and join baseline

**Status:** complete. Design:
[`mp4c-district-relevance-and-baselines.md`](mp4c-district-relevance-and-baselines.md).
Evidence: [`../validation/mp4c-acceptance.md`](../validation/mp4c-acceptance.md).

**Entry:** character, vehicle, and carryable lifecycle dependencies are
explicit.

- Admit the exact cooked catalog cohort and derive interest from authoritative
  district/cell residency plus semantic dependencies such as an occupied
  vehicle or held object.
- Build a bounded per-client relevant set with deterministic ordering and an
  explicit initial-baseline lifecycle.
- Prove join-in-progress, reconnect, boundary hysteresis, cross-district
  transfer, unload, and dependency retention.
- Keep content acquisition/visual residency separate from logical authority
  and never transmit durable save bytes as a join baseline.

**Exit:** irrelevant districts consume no per-client entity/baseline growth;
initial state is bounded and acknowledged; missing dependencies fail closed.

## MP4-D — Relevant NPC projection

**Status:** complete. Design:
[`mp4d-relevant-npc-projection.md`](mp4d-relevant-npc-projection.md).
Evidence: [`../validation/mp4d-acceptance.md`](../validation/mp4d-acceptance.md).

**Entry:** district relevance has measured entity and byte budgets.

- Project relevant NPC identity, lifecycle, pose/velocity, and the minimum
  presentation state at a measured lower rate.
- Keep goals, route decisions, navigation internals, and AI mutation private to
  the authority.
- Define spawn/despawn versus dormant/out-of-interest semantics so relevance
  changes are not mistaken for canonical destruction.
- Validate 64 NPCs with two clients crossing district boundaries.

**Exit:** NPC bandwidth and interpolation stay bounded under impairment;
clients cannot submit AI decisions; JIP/reconnect reproduces relevant NPCs
without exposing private components.

## MP4-E — Prioritization, deltas, and overload behavior

**Status:** complete. Design:
[`mp4e-prioritized-delta-replication.md`](mp4e-prioritized-delta-replication.md).
Evidence: [`../validation/mp4e-acceptance.md`](../validation/mp4e-acceptance.md).

**Entry:** real character, vehicle, carryable, district, and NPC traffic exists.

- Introduce per-connection entity/byte/event budgets and semantic priority
  classes based on measured traffic.
- Add acknowledged delta baselines with bounded memory and explicit fallback to
  full state when a baseline is missing or too old.
- Define starvation prevention and overload degradation: ownership/lifecycle
  remains reliable while distant replaceable state reduces rate first.
- Add payload, queue, baseline-memory, stale-age, and fallback diagnostics.

**Exit:** nominal and adverse profiles remain within declared budgets;
intentional saturation degrades observably without unbounded growth, ownership
loss, or permanent baseline divergence.

## MP4 completion gate

Each subphase ends with deterministic nominal/adverse/blackout evidence plus
real-GNS coverage where transport lifecycle matters. MP4 as a whole additionally
requires save/restart, reconnect, join-in-progress, district transfer, bounded
baseline memory, and an architecture review before MP5 lobby/room work.

Closeout: [`../validation/mp4-architecture-closeout.md`](../validation/mp4-architecture-closeout.md).
