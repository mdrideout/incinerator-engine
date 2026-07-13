# S8 Navigation-Driven Population Design

> **Historical slice design.** This was the delivery contract for the slice at
> closure. Detailed file layout, cohorts, and limitations below may have been
> consolidated later. See [ADR-014](../adr/014-bounded-district-navigation-and-feature-owned-npc-population.md)
> and the [cleanup plan](../../CLEANUP_PLAN.md) for current architecture.

**Status:** Complete
**Platform:** Apple Silicon macOS only

The governing decision is
[ADR-014](../adr/014-bounded-district-navigation-and-feature-owned-npc-population.md).

## S8-A — Cooked route and standalone NPC authority

- [x] Extend the bounded district recipe and explicit little-endian cooked
  bundle with exact node/edge fragments and structural/combined validation.
- [x] Admit cooked navigation only when it exactly matches the logical build
  and the installed west/east union is one connected bidirectional line.
- [x] Add the generation-aware copied-value navigation port without exposing
  district components, slices, handles, or residency mutation.
- [x] Implement feature-owned NPC commands, goals, active/waiting/dormant
  lifecycle, controller rollback, persistence, digest, extraction, and bounded
  queues against fake ports.
- [x] Add the fixed 64-command population planner and CharacterVirtual
  capacity/count evidence without making it persistent authority.

## S8-B — Composition, persistence, and replay

- [x] Compose NPC after vehicle and before the shared physics step; restore in
  the same dependency order and deinitialize in exact reverse.
- [x] Add `NpcConfigV1`, `NpcV1`, `SnapshotV7`, replay/schedule cohort 5, NPC
  command encoding, and a separate logical digest category.
- [x] Make active, boundary-waiting, and dormant saves validate all identities,
  owners, goals, node references, and content cohort before world construction.
- [x] Prove one real-Jolt patrol crosses both directions, waits through
  destination cancellation, follows source/destination unload policy, and
  cold-restores without duplicate controllers/entities.
- [x] Prove same-cohort capture/replay and an altered semantic goal diverge only
  in the NPC category at the exact tick.

## S8-C — Scale, diagnostics, presentation, and native closeout

- [x] Run 64 instances of the same patrol template while the player completes
  the S7 carry lifecycle; measure controller/entity/body/queue/navigation/
  persistence/tick/allocation/memory budgets.
- [x] Add immutable NPC draws and aggregate NPC/controller/wait/transfer/
  dormant/resume diagnostics; do not add a general navigation/crowd overlay.
- [x] Prove stale IDs, invalid data/references, unreachable goals, inactive
  destinations, 65th spawn, queue saturation, and event saturation are typed,
  bounded, and leave authority consistent.
- [x] Run installed Metal behavior from `/tmp` at 240/80 Hz with one crossing,
  64 draws, two resident scenes, unload/reload, unchanged S6 GPU payload peaks,
  and exact final drain.
- [x] Run full Debug/ReleaseFast/editor/source-package/macOS gates and an
  independent P0/P1/P2 review.

## Declared Representative Ceilings

| Resource | Workload / ceiling |
|---|---:|
| NPCs / NPC draws | 64 / 64 |
| Total entities | at most 68 |
| CharacterVirtual controllers | 65 used / 128 global |
| Rigid bodies | 7 held / 8 dropped; NPC adds zero |
| Two-district navigation payload | at most 640 bytes |
| NPC commands / outcomes / events | 128 / 128 / 256 |
| Population producer batch | 64 |
| Representative replay | 4,096 ticks / 2 MiB envelope |
| Scale soak | 16,384 ticks / 32 lifecycle cycles |
| Snapshot payload | 128 KiB |
| Save envelope | 131,264 bytes |
| Incremental live allocation | 2 MiB |
| Incremental matched-run max RSS | 32 MiB |
| ReleaseFast tick p99 on the primary machine | 4.166 ms |

Timing and memory values are characterization ceilings for the primary
machine, not portable promises. Exact capacities, authority transitions,
content bytes, and final cleanup are deterministic pass/fail gates.

The ReleaseFast scale measurement uses three fresh-process trials after one
unmeasured in-process warmup cycle. Tick percentiles use the nearest-rank
method over exactly 16,384 measured fixed ticks per trial; the recorded result
is the worst of the three trial p99 values. Allocation accounting separately
reports Zig allocator live/peak bytes and native Jolt resources. RSS is the
paired fresh-process delta between the identical baseline host and scale host,
using the worst matched trial. The navigation byte ceiling is reported as
explicit decoded and cooked-wire accounting, not estimated heap size.

## Acceptance

- [x] One persistent NPC patrols west -> east -> west, never enters an inactive
  destination, survives unload/reload and cold restore, and never duplicates or
  loses entity/controller/district ownership.
- [x] Same-cohort replay preserves semantic goals and logical transitions; no
  bitwise Jolt or cross-platform determinism is claimed.
- [x] Invalid navigation, unreachable goals, stale IDs, capacity exhaustion,
  and saturation produce typed bounded results with no partial commit.
- [x] The 64-NPC workload stays within every declared resource ceiling and
  returns entities, controllers, draws, queues, and navigation ownership to
  exact baseline.
- [x] Headless and installed native Metal paths pass at both cadences.

## Explicit Nonclaims

The nonclaims in ADR-014 are acceptance boundaries, not future placeholders to
implement opportunistically during S8.
