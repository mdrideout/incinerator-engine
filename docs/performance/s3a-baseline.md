# S3-A Procedural District Performance Baseline

> **Historical phase baseline.** Measurements and limits below are preserved as
> recorded for this slice; they are not measurements of the current tree. See
> the [current macOS readiness record](../validation/macos-readiness.md) and
> [cleanup plan](../../CLEANUP_PLAN.md).

**Recorded:** 2026-07-12
**Status:** Characterization evidence, not a performance guarantee

## Environment

- Apple M2 Max MacBook Pro, 12 CPU cores, 64 GB memory
- macOS 15.7.7 (`aarch64`)
- Zig 0.16.0, `ReleaseFast`, editor excluded
- Jolt 5.5.0 through the exact-pinned JoltC adapter
- monotonic awake clock, 42 ns reported resolution

The SDL-free workload composes one real bounded worker, one procedural district
containing three static boxes, and the host-owned ground. Each trial first
proves real cancellation and exact cleanup, then performs eight complete
request, worker preparation, fixed-tick activation, extraction, and unload
cycles. The first active cycle includes 120 warmup ticks and 512 measured
steady ticks/extractions. No GPU upload, cooked I/O, renderer work, dynamic
collision workload, or proximity policy is included; those remain S3-B/C
evidence.

Reproduce with:

```sh
zig build measure-s3 -Doptimize=ReleaseFast -Deditor=false -- \
  --warmup=120 --samples=512 --trials=3 --cycles=8
```

The complete output is committed as [`s3a-baseline.json`](s3a-baseline.json).

## Results

The fixed-tick budget at 120 Hz is 8.333 ms. Timing cells below are the median
of each reported percentile across three trials. They are recorded for future
comparison and are not CI thresholds.

| Operation | p50 | p95 | p99 |
|---|---:|---:|---:|
| Request to logical activation, wall clock | 0.040917 ms | 0.068792 ms | 0.068792 ms |
| Logical activation tick | 0.016541 ms | 0.025708 ms | 0.025708 ms |
| Static-body/entity unload tick | 0.002542 ms | 0.004125 ms | 0.004125 ms |
| Active steady simulation tick | 0.000750 ms | 0.000833 ms | 0.000875 ms |
| District logical extraction | 0.000042 ms | 0.000084 ms | 0.000084 ms |

Median fresh-world initialization was 1.104125 ms, cancellation completed in
0.025792 ms wall time, and teardown was 0.467166 ms. The largest measured
steady tick across all 1,536 samples was 0.001000 ms.

The active logical payload was exactly three static boxes and 120 decoded
bytes, within the contract maximum of eight boxes and 320 bytes. Activation
owned one district entity and three district bodies; together with ground the
Jolt world contained four bodies and no awake body. All 24 measured lifecycle
cycles returned to zero district entities/bodies and the single ground body.
Every cancellation returned to the same baseline.

## Interpretation

- The procedural job is deliberately tiny. Its wall-clock result establishes
  harness behavior and ownership accounting, not a cooked-content throughput
  target.
- Request-to-activation required a median p50 of six synthetic progress ticks
  and a median p95 of 20. The benchmark advances ticks as fast as the CPU can
  run while yielding to a separate OS thread, so this count mainly
  characterizes scheduler interleaving. It is not a claim of that many rendered
  or real-time frames at the normal 120 Hz cadence.
- The near-empty steady tick and extraction costs are expected for three
  sleeping static bodies. Collision behavior is gated separately by the real
  headless acceptance test rather than hidden inside this microbenchmark.
- S3-A records no GPU allocation/upload bytes and makes no renderer performance
  claim. Cooked I/O, staging, fence latency, resident CPU/GPU memory, and native
  Metal behavior must be measured by S3-B/C before full S3 closes.
