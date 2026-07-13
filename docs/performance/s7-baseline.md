# S7 Interaction and Ownership Baseline

> **Historical phase baseline.** Measurements and limits below are preserved as
> recorded for this slice; they are not measurements of the current tree. See
> the [current macOS readiness record](../validation/macos-readiness.md) and
> [cleanup plan](../../CLEANUP_PLAN.md).

**Recorded:** 2026-07-13
**Status:** Complete S7 characterization
**Platform:** Native Apple Silicon macOS
**Mode:** SDL-free `ReleaseFast`, editor excluded

## Workload

One real Flecs/Jolt world owns the sandbox ground, two procedural district
authorities, one CharacterVirtual, and one persistent carryable. The first
cycle loads both districts, collects the west-owned carryable, unloads the
source while it is held, cancels a new source-district load without changing
the held relationship, crosses through the procedural clear corridor, drops
under east ownership, unloads to a dormant record, and reconstructs the body
from the exact retained state.

The workload then alternates the same authoritative path between east and west
for 127 more cycles. Every cycle serializes each active and dormant state twice
and requires byte-identical repeated snapshots. Final cleanup destroys the
character and carryable, unloads the last district, drains every feature queue,
and requires exactly zero entities and the sandbox ground as the sole body.

This is a fixed bounded conformance workload, not a general inventory, content
scale, or NPC benchmark.

## Reproduction

```sh
zig build test-s7-measure -Doptimize=ReleaseFast -Deditor=false --summary all
zig build measure-s7 -Doptimize=ReleaseFast -Deditor=false --summary none
```

`measure-s7` defaults to exactly 128 cycles. `--cycles=N` exists for local
diagnosis and rejects zero or more than 4,096 cycles. The canonical machine-
readable result is [s7-baseline.json](s7-baseline.json).

## Recorded Result

| Metric | Result |
|---|---:|
| Completed ownership cycles | 128 / 128 |
| Fixed ticks | 11,615 |
| Total measured wall time | 46.951 ms |
| Cycle wall p50 / p95 / p99 / max | 0.347 / 0.381 / 0.420 / 0.430 ms |
| Semantic commands submitted | 11,033 |
| Typed outcomes / events observed | 1,034 / 774 |
| Held-owner cancellation episode | complete |
| Peak entities / physics bodies | 4 / 8 |
| Peak command / outcome / event occupancy | 2 / 2 / 1 |
| Queue rejections | 0 |
| Canonical persistence snapshots | 512 |
| Active snapshot bytes | 2,055–2,064 |
| Dormant snapshot bytes | 1,947–1,954 |
| Total serialized persistence bytes | 1,026,770 |
| Final entities / bodies / active bodies | 0 / 1 / 0 |
| Final command / outcome / event occupancy | 0 / 0 / 0 |

The snapshot-size ranges reflect the canonical tick/sequence values across the
128-cycle run; each same-state pair is byte-identical. The high command count
is expected because locomotion remains expressed as one semantic character
action per fixed tick rather than a privileged teleport.

## Native Presentation Companion

The installed Metal smoke separately proves presentation and cadence. At 240
Hz it completed in 364 frames / 182 ticks with 182 zero-tick and zero
multi-tick frames. At 80 Hz it completed in 124 frames / 186 ticks with zero
zero-tick and 62 multi-tick frames. Both observed world-owned and held draws,
source unload while held, destination drop, dormant unload, reload/resume, and
clean final `entities=0`, `bodies=1`, `draws=0` shutdown.

Timing values are characterization, not portable pass/fail thresholds. Exact
counts, bounded capacities, lifecycle milestones, canonical persistence, and
final cleanup are the acceptance gates. S8 must remeasure these ownership and
streaming budgets under its declared NPC population.
