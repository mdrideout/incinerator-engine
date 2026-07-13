# S2 Vehicle Slice Performance Baseline

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

The SDL-free workload composes one real Jolt four-wheel vehicle, its occupied
and dormant `CharacterVirtual`, one dynamic crate, and the static ground. Each
trial settles the bodies for 240 ticks, enters the vehicle, performs 120 warmup
drive ticks, then measures 512 occupied drive ticks. Presentation extraction
includes the crate, chassis, and four interpolated wheel poses while correctly
omitting the dormant character. Every trial must also prove more than 0.1 m of
chassis displacement; the recorded workload moved 24.264 m in each trial.

Reproduce with:

```sh
zig build measure-s2 -Doptimize=ReleaseFast -Deditor=false -- \
  --warmup=120 --samples=512 --trials=3
```

The complete output is committed as [`s2-baseline.json`](s2-baseline.json).

## Results

The fixed-tick budget at 120 Hz is 8.333 ms. Each table cell is the median of
that field across the three trials. The largest tick is the maximum over every
sample in every trial.

| Operation | p50 | p95 | p99 | p99 tick budget |
|---|---:|---:|---:|---:|
| Typed drive submission | 0.000042 ms | 0.000042 ms | 0.000125 ms | <0.01% |
| Complete simulation tick | 0.083833 ms | 0.106792 ms | 0.125625 ms | 1.51% |
| Crate + vehicle/four-wheel extraction | 0.000333 ms | 0.000417 ms | 0.000750 ms | <0.01% |

The largest measured tick across all three trials was 0.224917 ms. Median
fresh-world initialization was 1.133 ms, spawn was 0.160 ms, enter was
0.081 ms, exit was 0.050 ms, and teardown was 0.595 ms. Every trial returned
to zero gameplay entities and only the host-owned ground body, with no active
rigid body.

## Interpretation

- This one-player, one-vehicle workload remains comfortably inside the 120 Hz
  fixed-tick budget on the primary development machine.
- Unlike the resting S1 workload, the occupied vehicle keeps its chassis,
  constraint, suspension, wheel collision, and drivetrain work active. The
  tick distribution is consistently near 0.07–0.14 ms. No elapsed-time
  threshold is inferred from this local characterization.
- Extracting a chassis and four wheel poses remains negligible compared with
  physics; GPU rendering is intentionally outside this headless measurement.
- The benchmark proves lifecycle completion and cleanup counts, not a stable
  timing promise or a multiplayer/NPC vehicle capacity target.
