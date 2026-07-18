# S11 NPC Encounter Scale Baseline

**Status:** Accepted characterization

**Recorded:** 2026-07-14

**Platform:** Apple Silicon macOS

**Build:** Zig 0.16.0, `ReleaseFast`, editor excluded

## Purpose

This is the S11 feature-cost characterization, not a complete rendered-frame
budget. It compares a fresh-process empty encounter baseline with the declared
fully engaged ceiling of 64 hostile NPCs and 16 eligible participants.

The scale workload keeps every NPC pursuing, exercises the deterministic
16-query global line-of-sight budget and deferral path, drains all bounded
outputs, and performs no workload allocation. Three paired trials each use 64
warm-up ticks and 16,384 measured authority ticks.

## Reproduction

```sh
zig build check-s11-measure -Deditor=false -Doptimize=ReleaseFast
zig build test-s11-measure -Deditor=false -Doptimize=ReleaseFast
zig build measure-s11 -Deditor=false -Doptimize=ReleaseFast
```

The measurement refuses non-`ReleaseFast` builds. Its retained pass/fail limits
are 4,166,000 ns p99 and an 8 MiB paired RSS delta. These are regression
ceilings, not a claim that this one feature may consume the whole authority
frame.

## Result

| Metric | Accepted result |
|---|---:|
| Worst scale p99 | 49,083 ns |
| Worst paired RSS delta | 81,920 bytes |
| Fixed encounter storage | 147,160 bytes |
| Workload allocations | 0 |
| Scale mean across trials | approximately 34.8–36.2 us |
| Worst baseline p99 | 208 ns |

All three pairs passed. The fixed-array, single-threaded encounter owner is
appropriate at the declared ceiling; S11 provides no measured reason to add an
ECS query pipeline, job scheduler, or parallel AI execution.

Timing values characterize this Apple Silicon development machine and exact
dependency cohort. The explicit workload, capacities, zero-allocation rule,
and ceilings are the portable regression contract.
