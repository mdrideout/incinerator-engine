# ADR-013: Feature-Owned Carry Interaction and District Ownership

**Status:** Accepted, implemented, and validated in S7
**Date:** 2026-07-13

## Context

S6 proves two exact streamed districts, but every current persistent gameplay
object is owned by one feature for its whole lifetime. A future authoritative
game needs a concrete answer to a smaller question before networking: what
happens when one persistent object leaves district ownership, is held by a
character while its source district unloads, and is committed under the
destination district after crossing the half-open boundary?

Retrofitting this behavior into `CrateFeature` would mix the existing physics
and authoring conformance slice with inventory and district authority. A
generic entity registry, inventory framework, ownership graph, or migration
service would be speculation: S7 has one character and one carryable object.

## Decision

### A dedicated InteractionFeature owns the complete object lifetime

S7 adds one bounded `InteractionFeature`. It owns the carryable's persistent
entity, logical state, optional dynamic body, commands, outcomes, diagnostics,
presentation record, replay digest, and persistence record. Neither the
character nor district feature owns or migrates that entity.

The authoritative ownership value is exactly one of:

- `district_owned: ChunkCoord`; or
- `inventory_held: PersistentId`, naming the character.

The persistent entity exists in both states. A district-owned object owns a
dynamic body only while its exact owner district is active. A held object owns
no body. An object whose owner district is unloaded remains a dormant logical
entity with its last validated body state and no presentation. District unload
therefore cannot delete or duplicate the persistent object, and holding an
object never pins district residency.

### Narrow ports, not feature imports

`CharacterFeature` exposes a `CarrierAccess` capability analogous to its
existing `DriverAccess`. The port exposes only a validated carrier pose/mode,
the optional held item identity, and transactional begin/end/cancel operations.
The character stores a runtime `CarryState` so driving or despawning cannot
silently violate the relationship. `CharacterV1` does not persist the
relationship; `InteractionV1` is its sole persistence owner.

`DistrictFeature` exposes a read-only `DistrictAccess` capability for exact
coordinate residency/ticket state. `InteractionFeature` imports neither
feature implementation and receives only the two ports plus the existing
dynamic-box body capability.

Systems are composed in this order:

```text
crate -> character -> district -> interaction -> vehicle -> physics
```

This lets interaction reconcile body residency after district commands while
retaining the established character-before-vehicle authority ordering.

### Typed transactional commands

The bounded semantic command set is `spawn`, `despawn`, `collect`, and `drop`.
Input, editor, replay, tests, and a future transport produce the same commands;
none may mutate the carrier, entity, or body directly.

Collect validates both identities, on-foot/empty carrier state, exact owner
district residency, and configured proximity before changing anything. It
attaches through `CarrierAccess`, destroys the body, then commits held
ownership; body-removal failure cancels the carrier attachment.

Drop derives a deterministic pose from the authoritative carrier pose, maps
that position through the shared half-open coordinate rule, requires the exact
destination district to be active, creates the body, detaches through
`CarrierAccess`, then commits district ownership. Any failure destroys the
staged body and leaves the held relation unchanged. There is no best-effort
partial transfer.

At the 16-unit district seam, bounds are half-open: west owns `[-8, 8)` and
east owns `[8, 24)`. Therefore a drop at `x == 8` belongs to east `(1,0)`.
The shared helper rejects non-finite or unrepresentable positions.

### Honest schema and replay cohort changes

S7 introduces `InteractionV1`, `SnapshotV6`, replay schema cohort 4, and engine
schedule cohort 4. The interaction record stores backend-neutral dimensions,
last world body state, and the ownership union; it never stores a Jolt handle,
runtime entity value, or character component.

Cold restore validates all records and cross-feature identities before
construction. Restore order is crate, character, district, interaction,
vehicle so carrier and residency ports exist before the relationship/body is
reconstructed. Replay records semantic interaction commands and compares a
separate interaction logical-digest category.

## Consequences

### Positive

- One representative cross-feature ownership transfer is explicit, bounded,
  transactional, persistent, and testable without networking.
- Character, district, and interaction remain separate vertical slices joined
  through narrow ports.
- Source-district unload, destination load, save/restart, and replay all use
  one authoritative relationship.
- The same typed command can be produced by gameplay input and the optional
  editor without a privileged mutation path.

### Negative

- Snapshot, replay, diagnostics, and host composition cohorts change again.
- Character runtime state now contains one cross-feature guard even though the
  relationship is persisted by InteractionFeature.
- The object is a deliberately simple dynamic box; more general item shapes or
  inventory slots require later evidence.

## Explicit Nonclaims

S7 does not introduce a general inventory, item database, equipment system,
entity migration framework, ownership registry, arbitrary parent hierarchy,
stacking, throwing, replication, prediction, MMO authority, multiple holders,
or secondary-platform support. It proves one persistent carryable and one
character across exactly the two S6 districts.
