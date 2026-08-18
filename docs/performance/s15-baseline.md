# S15 Four-District Baseline

**Status:** Automated characterization accepted; human play acceptance remains
open

**Recorded:** 2026-08-18

**Platform:** Native Apple Silicon macOS

**Build:** Zig 0.16.0; `ReleaseFast` measurement and installed Debug Metal
acceptance

## Purpose

This baseline records the first exact four-district product cohort. It keeps
content residency, route-search work, authored-population authority, physical
placement, and presentation cadence as separate claims. The machine-readable
result is [`s15-baseline.json`](s15-baseline.json).

## Reproduction

```sh
zig build measure-s12 measure-s13 -Doptimize=ReleaseFast
zig build smoke-installed-s13-macos -Deditor=true --summary all
zig build verify-s15 -Deditor=true --summary all
```

The S12 and S13 meters deliberately retain their subsystem names. They admit
the current exact content cohort, so these S15 values characterize the new
32-node graph, 24 activity slots, and four-district collision fixture rather
than the historical S12/S13 world.

## Content and Metal Residency

| Metric | Result |
|---|---:|
| Installed catalog | 824 bytes |
| Four installed bundles | 4,364 / 4,360 / 4,364 / 4,360 bytes |
| Staged CPU bytes per scene | 3,888 |
| Resident GPU bytes per scene | 2,528 |
| Simultaneously resident scenes | 4 |
| Total resident GPU bytes | 10,112 |

The installed Metal smoke visibly admitted `(1,1)`, `(0,1)`, `(1,0)`, and
`(0,0)` and reached the exact four-scene GPU-registry capacity. The strengthened
acceptance observes every district draw and at least one stable population
identity on both rows before it can pass.

## Navigation

| Metric | Result | Contract |
|---|---:|---:|
| Planner queries | 32,768 | exact workload |
| Nodes / edges searched | 679,936 / 1,343,488 | informational |
| Planner p50 / p95 / p99 | 1.427 / 1.503 / 1.522 ms | p99 ≤ 4.166 ms |
| Six-NPC movement p99 | 0.055 ms | p99 ≤ 4.166 ms |
| Moved / arrived / blocked | 6 / 5 / 0 | no blocked actors |
| Replans / teleport rollbacks | 12 / 0 | zero rollback |

The focused live-Jolt gate separately proves arrival through the north-row
detour after closing the south-row seam. Five of the six fixed-duration meter
actors completed within 2,048 ticks; the sixth was still making valid progress
and none entered a blocked state. That distinction avoids turning a benchmark
duration into navigation policy.

## Population and Physical Placement

| Metric | Result | Contract |
|---|---:|---:|
| Ordinary / physical-stress members | 12 / 16 | exact |
| Owner ticks per cohort | 8,192 | exact |
| Ordinary / physical owner p99 | 0.000292 / 0.000292 ms | p99 ≤ 4.166 ms |
| Fixed owner bytes / workload allocations | 22,120 / 0 | fixed / zero |
| Activity-slot CharacterVirtual actors | 24 | exact |
| Static bodies in placement fixture | 9 | one support + eight obstacles |
| Placement queries / rejections | 24 / 0 | zero rejection |
| Separation violations | 0 | zero |
| Jolt p50 / p95 / p99 | 0.025 / 0.030 / 0.038 ms | p99 ≤ 4.166 ms |
| Jolt fixture maximum RSS | 12,550,144 bytes | informational |

The nine static bodies are intentional proof of singular support ownership:
one composition ground plus two obstacle boxes for each of four districts.
There is no district floor or containment perimeter.

## Two-Rate Product Acceptance

| Virtual render rate | Frames / authority ticks | Cadence evidence | Population evidence |
|---:|---:|---|---|
| 240 Hz | 3,840 / 960 | 2,880 zero-tick; zero multi-tick | 3,113 complete frames; zero loss after full |
| 40 Hz | 640 / 960 | zero zero-tick; 320 multi-tick | 519 complete frames; zero loss after full |

Both runs retained all twelve ordinary population identities, observed all
three roles and traveling/dwelling/waiting states, kept four district scenes
resident, and shut down cleanly.

## Interpretation

S15 does not demonstrate a need for a navmesh, crowd solver, behavior tree,
parallel content workers, larger GPU registry, or simulation LOD. The current
weighted graph, explicit authored activities, one content worker, and four
fixed scene slots remain appropriate for this evaluation world. The next
architecture decision should be driven by human testing or materially richer
geometry—not by extrapolating from unused framework capacity.
