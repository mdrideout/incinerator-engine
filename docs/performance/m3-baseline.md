# M3 Pre-Server Readiness Performance Baseline

> **Historical pre-cleanup baseline.** Measurements and limits below are
> preserved as recorded when M3 closed; they are not measurements of the
> consolidated tree. See the
> [current macOS readiness record](../validation/macos-readiness.md) and
> [cleanup plan](../../CLEANUP_PLAN.md).

**Recorded:** 2026-07-13

**Platform:** Apple M2 Max, 64 GiB, macOS 15.7.7 (24G720)

**Toolchain:** Zig 0.16.0, `ReleaseFast`, native `aarch64-macos`

The machine-readable record is
[`m3-baseline.json`](m3-baseline.json). This is a macOS characterization and
regression gate for the exact M3 cohort, not a portable throughput promise.

## Method

Each routine trial used a fresh workload process and ran exactly 32,768
authority ticks. The scenario keeps two districts, one character, one live
vehicle, one carryable, and 64 NPCs active while two synthetic producers use
the bounded relocation seam. It also exercises district cancellation and
reload, collect/drop ownership, all four external-router saturation results,
shutdown drain, snapshot creation, destruction of the original authority, and
canonical cold restore.

`allocator_peak_bytes` is measured by a tracking allocator over the workload
GPA. `allocator_final_live_bytes` is observed after teardown. RSS is the
absolute `getrusage(RUSAGE_SELF).ru_maxrss` value from each fresh workload
process; it is not a paired idle-to-loaded delta and is intentionally not
described as one. Timing uses the awake monotonic clock around each authority
tick. The integrated soak saturates the internal outcome and external producer
router queues; feature-specific full/reject/drain/reuse behavior is a separate
unit-test gate recorded in the M3 acceptance document.

## Routine observations

| Trial | p50 | p95 | p99 | Max | Authority ticks/s | Whole-run ticks/s | Allocator peak | Absolute max RSS |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | 0.366 ms | 0.419 ms | 0.474 ms | 2.169 ms | 2,710.00 | 2,659.50 | 733,394 B | 19,955,712 B |
| 2 | 0.364 ms | 0.414 ms | 0.561 ms | 10.243 ms | 2,688.81 | 2,639.45 | 733,394 B | 21,708,800 B |
| 3 | 0.364 ms | 0.413 ms | 0.472 ms | 8.786 ms | 2,726.12 | 2,676.62 | 733,394 B | 21,594,112 B |

All three trials completed exactly, ended with zero live allocator bytes,
preserved exact producer completion ownership, drained all accepted work, and
produced byte-canonical state before and after cold restore. Snapshot payloads
were 34,441 bytes and save envelopes were 34,633 bytes.

## Long observation

The opt-in 131,072-tick cohort completed with a 0.478 ms p99, 2,717.20
authority ticks/s, 1,519,514 allocator peak bytes, zero allocator-live bytes,
22,626,304 bytes absolute max RSS, a fully drained shutdown, and canonical
restore. Its snapshot and envelope were 34,337 and 34,529 bytes.

## Enforced ceilings

| Measurement | Ceiling | Worst routine observation | Long observation |
|---|---:|---:|---:|
| Authority tick p99 | 8,333,333 ns | 560,500 ns | 477,875 ns |
| Snapshot payload | 131,072 B | 34,441 B | 34,337 B |
| Save envelope | 131,072 B | 34,633 B | 34,529 B |
| Tracking-allocator peak | 67,108,864 B | 733,394 B | 1,519,514 B |
| Absolute process max RSS | 134,217,728 B | 21,708,800 B | 22,626,304 B |

The p99 gate is the scheduling budget. Individual wall-clock maxima remain
reported for diagnosis but are not a correctness failure when p99 and all
deterministic gates pass.
