# S0 Crate Lifecycle Performance Baseline

**Recorded:** 2026-07-10  
**Status:** Characterization evidence, not a performance guarantee

## Environment

- Apple M2 Max MacBook Pro, 12 CPU cores, 64 GB memory
- macOS 15.7.7 (arm64)
- Zig 0.16.0, `ReleaseFast`, editor excluded
- Jolt 5.5.0 through the exact-pinned JoltC adapter
- monotonic awake clock, 42 ns reported resolution

The SDL-free measurement creates a fresh owned simulation for every trial. It
uses a sparse 32-by-32 grid at `y=1000`, so every crate remains an active,
falling rigid body without crate/ground or crate/crate contacts during the
sample window. Each scale has 120 warmup ticks, 512 measured ticks, and three
trials. Values below are medians across trials except the explicitly named
maximum.

Reproduce with:

```sh
zig build measure-s0 -Doptimize=ReleaseFast -Deditor=false -- \
  --counts=0,1,128,1024 --warmup=120 --samples=512 --trials=3
```

The complete three-trial output is committed as
[`s0-baseline.json`](s0-baseline.json).

## Results

The fixed-tick budget at 120 Hz is 8.333 ms.

| Crates | Active bodies | Tick p50 | Tick p95 | Tick p99 | p99 budget | Presentation p50 | Presentation p99 |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 0 | 0 | 0.001 ms | 0.001 ms | 0.001 ms | 0.01% | <0.001 ms | <0.001 ms |
| 1 | 1 | 0.077 ms | 0.101 ms | 0.112 ms | 1.35% | <0.001 ms | <0.001 ms |
| 128 | 128 | 0.123 ms | 0.154 ms | 0.172 ms | 2.06% | 0.012 ms | 0.021 ms |
| 1024 | 1024 | 0.524 ms | 0.642 ms | 0.889 ms | 10.67% | 0.098 ms | 0.159 ms |

| Crates | Init | Bulk spawn tick | Spawn outcome drain | Bulk despawn tick | Despawn outcome drain | Teardown |
|---:|---:|---:|---:|---:|---:|---:|
| 0 | 1.189 ms | 0.007 ms | <0.001 ms | 0.001 ms | <0.001 ms | 0.382 ms |
| 1 | 1.149 ms | 0.097 ms | <0.001 ms | 0.005 ms | <0.001 ms | 0.676 ms |
| 128 | 1.102 ms | 0.333 ms | 0.001 ms | 0.056 ms | <0.001 ms | 0.616 ms |
| 1024 | 1.069 ms | 2.363 ms | 0.004 ms | 0.580 ms | 0.003 ms | 0.861 ms |

The largest observed 1,024-crate tick across the three trials was 5.749 ms;
its median-trial p99 was 0.889 ms. The isolated maximum is retained as scheduler/noise
evidence, not hidden or converted into a threshold.

## Interpretation

- The actual S0 workload—one falling crate—uses about 1.35% of the fixed-tick
  budget at p99 on this machine.
- The exact configured cap of 1,024 active crates remains below 11% of the tick
  budget at p99 in this collision-free layout. This is a characterization of
  S0, not an MMO/entity-scale promise.
- Presentation extraction is materially cheaper than simulation at every
  measured scale and contains no GPU submission work.
- The first measurement exposed quadratic front-removal in the outcome queue:
  draining 1,024 outcomes took roughly 0.36–0.38 ms. Replacing it with a cursor
  reduced subsequent recorded drains to low single-digit microseconds
  (0.001–0.004 ms) while preserving FIFO order and bounded retained storage.
- Bulk despawn still includes linear active-record lookup/removal. Its 0.580 ms
  result at the hard S0 cap is acceptable evidence for this slice; a more
  complex index is not justified until another workload demonstrates need.

CI should verify that the measurement completes, emits the versioned schema,
and reports the requested counts. Wall-time regressions should not fail shared
runners until stable dedicated-hardware history exists.
