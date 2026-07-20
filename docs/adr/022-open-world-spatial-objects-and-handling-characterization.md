# ADR-022: Open-World Spatial Objects and Handling Characterization

**Status:** Accepted and implemented
**Date:** 2026-07-19
**Supersedes:** ADR-013's district-residency gating for carryables

## Context

Human testing found that a held object could only be dropped near its pickup
area. Authority returned `destination_unavailable` after the carrier moved
beyond the two authored districts. The same architectural confusion had once
made vehicle/object continuity depend on district projection.

A district is a bounded streamed content and navigation cohort. It is not the
existence owner of every dynamic world object whose position maps to that
coordinate. Treating it as both created arbitrary invisible walls and made
ordinary open-world actions depend on whether nearby authored content happened
to be resident.

Vehicle handling also had no repeatable objective characterization. Tuning by
rendered feel alone could improve one behavior while silently regressing
braking, slip recovery, or rollover tendency.

## Decision

`InteractionFeature` remains the sole lifetime owner of carryables. Its
ownership union is `spatially_owned: ChunkCoord` or
`inventory_held: PersistentId`. The coordinate is spatial indexing metadata,
not a residency lease. A spatial carryable always owns its dynamic body and is
presented independently of district load state. A held carryable owns no body.

Collect remains range-, identity-, carrier-, and transaction-validated. Drop
always derives one deterministic pose from the authoritative carrier and maps
it to a half-open spatial coordinate. No active-district precondition,
alternate offset, old-pose teleport, or forced-cleanup exception remains.

District residency remains authoritative for cooked collision, presentation,
and navigation cohorts. The physics bounds overlay draws active 16 m district
cells and centers. NPCs expose route target and non-fatal navigation progress;
120 ticks without horizontal progress while pursuing a target is reported as
`potentially_stalled`. It does not throw, teleport, abandon the goal, or claim
the goal is unreachable.

Vehicle tire curves, braking, steering, suspension, and center of mass are
explicit backend-neutral tuning values. `tools/vehicle_dynamics.zig` compares
the current profile with a frozen legacy profile on real Jolt and reports
stopping, turning, slip, slalom, skid recovery, and rollover metrics.

This intentional greenfield break advances snapshot schema to 12, replay
schema to 12, and protocol revision to 14. No decoder for the invalid
residency-gated meaning is retained.

## Consequences

- Open-world carry interaction no longer depends on a tiny authored-content
  catalog.
- Streaming can unload scenery/navigation without silently deleting a dynamic
  object owned by another feature.
- District boundaries and NPC movement intent are inspectable without turning
  diagnostic suspicion into gameplay correction.
- Handling changes now have a repeatable regression surface and documented
  tradeoffs.
- Unbounded-world lifecycle, persistence scaling, broadphase partitioning,
  navigation generation, and eventual interest management remain future work;
  continuous existence in the current bounded cohort is not an MMO solution.

