# ADR-013: Feature-Owned Carry Interaction

**Status:** Accepted feature ownership; spatial-residency portion superseded by [ADR-022](022-open-world-spatial-objects-and-handling-characterization.md)
**Date:** 2026-07-13
**Amended:** 2026-07-19

## Context

S7 needed one explicit owner for a persistent carryable crossing character,
physics, persistence, replay, and streamed-world boundaries. Folding the
behavior into the crate, character, or district feature would mix unrelated
lifetimes. A general inventory or ownership framework was not justified.

The original S7 implementation also made a spatial carryable's physics body
conditional on exact district residency. Human testing later proved that was
the wrong open-world boundary: it rejected ordinary drops outside the two
authored districts. ADR-022 removes that policy without changing feature
ownership.

## Decision retained

One bounded `InteractionFeature` owns the carryable's complete lifetime,
persistent identity, logical state, physics body, typed commands/outcomes,
diagnostics, presentation, replay digest, and persistence record.

The ownership value is:

- `spatially_owned: ChunkCoord`; or
- `inventory_held: PersistentId`.

`CharacterFeature` exposes the narrow transactional `CarrierAccess` port.
Begin/end/cancel operations keep character mode consistent while
`InteractionFeature` remains the persistence owner of the relationship.

Collect validates identities, on-foot/empty carrier state, range, and body
presence; it attaches the relationship, removes the body, and commits held
ownership transactionally. Drop derives one deterministic pose from the
authoritative carrier, creates the body, detaches the relationship, and commits
spatial ownership transactionally. Failure leaves the prior relationship and
world state intact.

The spatial coordinate uses the canonical finite half-open 16 m mapping. It is
indexing metadata, not a district-residency lease. A spatial object remains
physical and present when cooked district content unloads. There is no inactive
district rejection, dormant carryable state, alternate placement, or previous-
pose cleanup fallback.

## Consequences

- Carry behavior remains a cohesive vertical slice joined to character through
  one narrow port.
- Streaming content cannot delete, suspend, or strand an object owned by the
  interaction slice.
- Persistence/replay encode backend-neutral state and never Jolt handles.
- This remains one simple carryable/holder cohort, not a general inventory,
  equipment, stacking, throwing, migration, or MMO ownership system.
