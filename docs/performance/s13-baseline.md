# S13 Authored Population Baseline

**Status:** Accepted automated characterization; final human play acceptance is
tracked separately

**Recorded:** 2026-08-01

**Platform:** Native Apple Silicon macOS

**Build:** Zig 0.16.0; `ReleaseFast` for owner/physics measurement and `Debug`
for the installed product/incident journey

## Purpose

This baseline keeps three different claims separate:

- the ordinary product contains twelve authored population members;
- physical stress uses sixteen uniquely placed real-Jolt
  `CharacterVirtual` controllers; and
- the existing 64-NPC ceiling remains a logic/projection pressure fixture, not
  a claim that the two-district map can host 64 credible pedestrians.

The machine-readable owner, physical, synthetic, persistence, and protocol
result is [`s13-baseline.json`](s13-baseline.json).

## Reproduction

```sh
zig build test-s13-measure -Deditor=false -Doptimize=ReleaseFast
zig build measure-s13 -Deditor=false -Doptimize=ReleaseFast --summary all
zig build smoke-installed-s13-macos -Deditor=true --summary all
zig build benchmark-s13-incident-macos -Deditor=true \
  -Dincident-capture=true --summary all
```

The measurement tool refuses a non-`ReleaseFast` build. Timing values are
development-machine characterization. Exact cohort sizes, fixed storage,
zero workload allocation, queue integrity, unique physical placement,
separation, and the 4.166 ms p99 ceilings are regression contracts.

## Recorded Result

| Cohort / metric | Result | Ceiling or contract |
|---|---:|---:|
| Ordinary owner ticks / members | 8,192 / 12 | exact |
| Ordinary owner p50 / p95 / p99 | 0.000042 / 0.000167 / 0.000250 ms | p99 4.166 ms |
| Physical owner ticks / members | 8,192 / 16 | exact |
| Physical owner p50 / p95 / p99 | 0.000083 / 0.000208 / 0.000333 ms | p99 4.166 ms |
| Owner fixed storage / workload allocations | 21,992 bytes / 0 | fixed / zero |
| Ordinary intent / transition high-water | 4 / 8 | bounded; no drops |
| Physical intent / transition high-water | 4 / 8 | bounded; no drops |
| Ordinary snapshot JSON / parse-restore p99 | 7,990 bytes / 0.162 ms | informational |
| Physical snapshot JSON / parse-restore p99 | 10,170 bytes / 0.161 ms | informational |
| Real-Jolt measured ticks / controllers | 2,048 / 16 | exact |
| Jolt p50 / p95 / p99 | 0.0148 / 0.0199 / 0.0269 ms | p99 4.166 ms |
| Placement queries / rejected / separation violations | 16 / 0 / 0 | exact zero failures |
| Jolt cohort maximum RSS | 12,320,768 bytes | informational |
| Synthetic waves / commands | 4,096 / 262,144 | exact |
| Synthetic p50 / p95 / p99 | 0.00113 / 0.00117 / 0.00154 ms | p99 4.166 ms |
| Synthetic workload allocations | 0 | zero |
| Full 12-member protocol-15 snapshot | 918 bytes | exact |
| Full 16-member protocol-15 snapshot | 1,210 bytes | exact |
| Full 64-NPC protocol-15 snapshot | 4,714 bytes | logic-pressure only |

At the configured 10 Hz NPC publication cadence, those full-snapshot figures
are 9,180, 12,100, and 47,140 bytes per second respectively before transport
framing. S13 does not use the 64-NPC number to justify crowd quality or product
density.

## Installed Metal Acceptance

The installed S13 smoke ran the ordinary twelve-member world at two render
cadences while authority remained fixed at 60 Hz:

| Virtual render cadence | Frames / authority ticks | Cadence evidence | Population evidence |
|---:|---:|---|---|
| 240 Hz | 3,840 / 960 | 2,880 zero-tick frames; no multi-tick frames | all 12 members, all roles/states, peak 12 draws, no unexplained cohort loss |
| 40 Hz | 640 / 960 | 320 multi-tick frames; no zero-tick frames | all 12 members, all roles/states, peak 12 draws, no unexplained cohort loss |

Both executions used the installed Metal product and completed all 66 build
steps. This proves render cadence does not choose activity or population
authority.

## Incident-Capture Cost and Evidence

The paired 2,400-frame installed-product benchmark measured:

| Product mode | p50 / p95 / p99 frame work | Capture state |
|---|---:|---|
| Capture disabled | 1.600 / 3.382 / 3.850 ms | no writer, queue, image, or fence work |
| Capture enabled | 1.775 / 3.791 / 4.275 ms | queue high-water 28/1,024; zero dropped records; 80/80 trail frames; 6/6 anchors |

Capture increased p50, p95, and p99 by approximately 10.9%, 12.1%, and 11.0%
respectively. The enabled p99 remains about 25.7% of a 16.667 ms frame. The
benchmark wrote 668,304 artifact bytes; its 86 screenshot fences averaged
3.863 ms with a 13.576 ms maximum. These are characterization values, not a
promise for materially larger scenes.

The first S13 run exposed 767 dropped trace records despite a queue high-water
of only 30. The queue was not overloaded: composed navigation plus population
state records exceeded the historical 2 KiB atomic-line buffer. S13 raised
that explicit record budget to 4 KiB and added a composed-record regression
test. The repaired benchmark and product journey both report zero drops.

The final scripted product journey completed at authority tick 2,466 and
proved vehicle, district, player-death/respawn, and stable population-member
death/replacement lifecycles. Its schema-5 bundle contained 8,891 records,
eight stream segments, four complete anomalies, zero suspicious artifacts,
zero record loss, 342 visual artifacts, and a verified 2,406-tick
accepted-ingress replay. Population member P01 moved from actor generation 1
to vacancy, recorded typed unsafe replacement retries, and returned as actor
generation 2 before the journey could complete.

## Interpretation

The bounded owner and real-Jolt cohort have ample fixed-tick headroom. S13
therefore provides no measured reason to add a behavior tree, job scheduler,
navmesh, crowd solver, heap-backed activity system, or simulation LOD. The
largest immediate cost is optional local incident imagery, not population
decision authority. Future city-scale content should remeasure the three
cohorts independently instead of extrapolating from the current map.
