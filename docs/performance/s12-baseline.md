# S12 Destination Navigation Baseline

**Status:** Accepted automated characterization; human play acceptance is
tracked separately

**Recorded:** 2026-07-28

**Platform:** Native Apple Silicon macOS

**Build:** Zig 0.16.0, `ReleaseFast`, editor excluded

## Purpose

This baseline separates route-query scale from physical-controller scale. A
64-request burst is admitted through the real eight-query-per-authority-tick
planner budget, while the real-Jolt movement cohort uses six distinct authored
anchors. It does not create 64 overlapping `CharacterVirtual` controllers and
mistake penetration resolution cost for navigation cost.

The machine-readable result is
[`s12-baseline.json`](s12-baseline.json).

## Reproduction

```sh
zig build test-s12-measure -Deditor=false -Doptimize=ReleaseFast
zig build measure-s12 -Deditor=false -Doptimize=ReleaseFast --summary all
```

The benchmark refuses a non-`ReleaseFast` product measurement. Timing values
are development-machine characterization; the workload shape, deterministic
digest, zero-teleport rule, capacities, and ceiling are regression contracts.

## Recorded Result

| Metric | Result | Ceiling |
|---|---:|---:|
| Planner requests / admitted per wave | 64 / 8 | exact |
| Planner measured waves / queries | 4,096 / 32,768 | exact |
| Planner p50 / p95 / p99 | 0.985 / 1.139 / 1.210 ms | p99 4.166 ms |
| Planner maximum | 1.328 ms | informational |
| Searched nodes / edges | 448,512 / 849,920 | deterministic |
| Route digest accumulator | 2,615,804,729,959,975,360 | deterministic |
| Real-Jolt movement ticks / NPCs | 2,048 / 6 | exact |
| NPCs moved / arrived / blocked | 6 / 3 / 0 | exact |
| Peak native NPC controllers | 6 | exact |
| Route replans / teleport rollbacks | 10 / 0 | nonzero / zero |
| Movement p50 / p95 / p99 | 0.046 / 0.063 / 0.076 ms | p99 4.166 ms |
| Movement maximum | 0.138 ms | informational |

The exact installed content cohort fingerprint is
`7c4f7a353ac7f1160f123bd21ea1ee356c9a274dae7646d29d0a6f4b63f5bc80`.

## Interpretation

The bounded fixed-array planner has ample headroom at the declared query
budget. The 1.210 ms p99 is about 29% of the conservative 4.166 ms ceiling,
while six-controller movement uses about 1.8% at p99. The data provides no
reason to add a heap, job system, navmesh runtime, crowd solver, or parallel
AI scheduler for this two-district slice.

Only three of six movement actors arrive during the fixed 2,048-tick window
because the cohort deliberately mixes patrol, waiting, and longer cross-map
journeys. Every actor moves, no actor becomes structurally blocked, and no
healthy recovery teleports or rolls back its physical pose.
