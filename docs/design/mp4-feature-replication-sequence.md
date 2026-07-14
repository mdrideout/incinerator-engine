# MP4 Feature Replication Sequence

**Status:** MP4-A1 authoritative vehicle replication is implemented and
accepted; MP4-A2 and MP4-B through MP4-E remain

**Last reviewed:** 2026-07-13

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

### MP4-A2 local vehicle responsiveness — next decision slice

The A1 measurements show 9-tick nominal and 12-15-tick adverse maximum
snapshot age. Interpolation makes remote vehicles smooth but cannot make the
local throttle/steering response immediate. The next slice must evaluate the
installed graphical client and choose one explicit policy:

1. a bounded local Jolt prediction scene with authoritative reconciliation;
2. a deliberately smaller vehicle motion predictor with measured correction
   limits; or
3. authority-only vehicle presentation if playtesting demonstrates that the
   latency target is acceptable.

It may not silently call velocity extrapolation "prediction," run a second
authoritative Flecs world, or depend on cross-machine Jolt determinism. The
choice needs correction, collision, ownership-loss, enter/exit, and blackout
evidence before MP4-B.

## MP4-B — Carry interaction

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
