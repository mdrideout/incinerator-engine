# S7 Interaction and Cross-District Ownership Design

> **Historical slice design.** This was the delivery contract for the slice at
> closure. Detailed file layout, cohorts, and limitations below may have been
> consolidated later. See [ADR-013](../adr/013-feature-owned-carry-interaction-and-district-ownership.md)
> and the [cleanup plan](../../CLEANUP_PLAN.md) for current architecture.

**Status:** Complete
**Platform:** Apple Silicon macOS only

The governing decision is
[ADR-013](../adr/013-feature-owned-carry-interaction-and-district-ownership.md).

## S7-A: Capability seams and standalone authority — complete

- [x] Add the canonical half-open world-position to district-coordinate rule
  with finite, boundary, negative-coordinate, and range tests.
- [x] Add narrow character carrier and district-residency ports without
  importing feature implementations across the boundary.
- [x] Implement one bounded InteractionFeature with persistent district-owned,
  held, and dormant states plus typed spawn/despawn/collect/drop outcomes.
- [x] Prove transactional body/carrier rollback, stale/wrong-owner/range/mode/
  residency/capacity rejection, unload/reload, and exact cleanup with fakes.

## S7-B: Composition, persistence, and replay

- [x] Compose systems in crate -> character -> district -> interaction ->
  vehicle -> physics order over the real Jolt dynamic-box capability.
- [x] Add `InteractionV1`, `SnapshotV6`, replay/schedule cohort changes,
  interaction command encoding, and a separate logical-digest category.
- [x] Make cold restore validate identities/ownership/cohorts before world
  construction and reconstruct active, held, and dormant records exactly.
- [x] Prove real-Jolt collect -> cross-boundary -> drop -> unload/reload,
  canonical save/restart, same-cohort replay, and altered-command divergence.

## S7-C: Producers, presentation, measurement, and native closeout

- [x] Bind `F` gameplay input and the optional editor to the same typed
  collect/drop commands; preserve `E` exclusively for vehicle enter/exit.
- [x] Add renderer-neutral held/world draws and truthful diagnostics without a
  generic inventory or ownership debugger.
- [x] Add a bounded repeated-cycle workload and record command/entity/body/
  persistence/tick/resource cleanup evidence.
- [x] Run installed native Metal behavior at 240/80 Hz, full
  Debug/ReleaseFast/editor/source-package/aggregate gates, and independent
  P0/P1/P2 review.

## Acceptance

- [x] Invalid range, stale or wrong IDs, occupied/driving carrier, duplicate
  collect, invalid drop, unloaded destination, and capacity saturation are
  typed rejections with byte-identical authoritative state after rejection.
- [x] Collect commits carrier attachment/body removal/held ownership together;
  drop commits destination body/carrier detach/district ownership together;
  every injected failure rolls back fully.
- [x] Source-district unload cannot destroy or duplicate a held object; a
  dormant district-owned object reconstructs exactly when its owner reloads.
- [x] Capture/replay and save/process-restart/restore preserve holder and
  district ownership exactly and reject incompatible cohorts before world
  construction.
- [x] Repeated west collect -> east drop -> unload/reload cycles return every
  entity, body, command, outcome, draw, and relationship to its exact expected
  owner or final baseline.
- [x] Headless and installed Metal paths pass with explicit bounded resource
  evidence at both render cadences.

## Explicit Nonclaims

No general inventory, item catalog, equipment, stack, throw/ballistics,
arbitrary ownership graph, entity migration service, networking, multiplayer,
or secondary-platform abstraction is introduced.
