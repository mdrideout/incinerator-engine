# S1 Character Slice Performance Baseline

> **Historical phase baseline.** Measurements and limits below are preserved as
> recorded for this slice; they are not measurements of the current tree. See
> the [current macOS readiness record](../validation/macos-readiness.md) and
> [cleanup plan](../../CLEANUP_PLAN.md).

**Recorded:** 2026-07-12  
**Status:** Characterization evidence, not a performance guarantee

## Environment

- Apple M2 Max MacBook Pro, 12 CPU cores, 64 GB memory
- macOS 15.7.7 (arm64)
- Zig 0.16.0, `ReleaseFast`, editor excluded
- Jolt 5.5.0 through the exact-pinned JoltC adapter
- monotonic awake clock, 42 ns reported resolution

The SDL-free workload composes the actual S1 sandbox simulation: one Jolt
`CharacterVirtual`, one dynamic crate, the static ground, and the static block.
Each trial performs 120 warmup ticks followed by 512 measured ticks. Every
measured tick receives one typed forward action, updates the character against
the block, steps the shared physics world, and publishes both features.

Reproduce with:

```sh
zig build measure-s1 -Doptimize=ReleaseFast -Deditor=false -- \
  --warmup=120 --samples=512 --trials=3
```

The complete output is committed as [`s1-baseline.json`](s1-baseline.json).

## Results

The fixed-tick budget at 120 Hz is 8.333 ms. Each table cell is the median of
that same field across the three trials (for example, the median of the three
reported p95 values). Lifecycle summaries use the same per-field median. The
explicitly named largest tick is the maximum over every trial.

| Operation | p50 | p95 | p99 | p99 tick budget |
|---|---:|---:|---:|---:|
| Typed action submission | 0.000041 ms | 0.000042 ms | 0.000042 ms | <0.01% |
| Complete simulation tick | 0.002750 ms | 0.100083 ms | 0.112583 ms | 1.35% |
| Crate + character extraction | 0.000167 ms | 0.000250 ms | 0.000292 ms | <0.01% |

The largest measured tick across all three trials was 0.148584 ms. Median
fresh-world initialization was 1.095 ms, the composed spawn tick was 0.110 ms,
and teardown was 0.633 ms. Every trial also reported zero crates, characters,
and entities after despawn, with only ground and block bodies remaining and no
active rigid body.

## Interpretation

- The actual S1 workload remains comfortably inside the 120 Hz fixed-tick
  budget on the primary development machine.
- The tick distribution is bimodal because the dynamic crate transitions from
  falling/active to resting while the character remains blocked against the
  wall. The p95/p99 values therefore describe the active portion better than
  the very small median.
- Presentation extraction remains negligible and contains no GPU submission.
- Action submission is measured separately from the tick so future queue or
  networking work has an explicit baseline.
- These results characterize one local player. They do not establish NPC,
  crowd, server, or MMO-scale budgets.
