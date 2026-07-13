# S4-C Physics Debug and Host Profiler Baseline

> **Historical phase baseline.** Measurements and limits below are preserved as
> recorded for this slice; they are not measurements of the current tree. See
> the [current macOS readiness record](../validation/macos-readiness.md) and
> [cleanup plan](../../CLEANUP_PLAN.md).

**Date:** 2026-07-13
**Cohort:** Apple Silicon macOS, Zig 0.16.0, SDL 3.4.12 Metal backend, Jolt
5.5.0/JoltC, Debug engine build, editor disabled
**Status:** Record-only characterization; not a release performance threshold.

## Installed scenario

Command:

```sh
zig build smoke-installed-s4-physics-debug-macos \
  -Deditor=false --summary all
```

The installed executable ran from `/tmp`, discovered installed cooked content
relative to itself, streamed and activated the S3 fixture district, and kept a
crate, CharacterVirtual character, vehicle, ground, and district collision
bodies live. Physics debug and all categories were enabled for 600 presented
frames at controlled 80 Hz / 900 fixed ticks.

| Observation | Value |
|---|---:|
| completed debug batches | 900 |
| peak retained lines per batch | 524 |
| peak retained triangles per batch | 84 |
| CPU primitive drops | 0 |
| successful Metal uploads | 600 |
| copy submissions / nonblocking completions | 600 / 600 |
| aggregate uploaded bytes | 17,762,016 |
| backpressure drops | 0 |
| overlay draw frames | 600 |
| accepted empty-command post-submit fences | 600 |
| fixed slots | 3 |
| persistent GPU buffers | 6 |
| persistent transfer buffers | 6 |
| peak / maximum owned fences | 2 / 3 |
| retained profile spans | 2,048 |
| retained profile frames | 240 |
| visibly overwritten spans | 7,853 |

At the default capacity and 24-byte position/color vertex, each slot reserves
1,572,864 bytes for line vertices and 1,179,648 bytes for triangle vertices in
both GPU and transfer storage: 5,505,024 bytes per slot and **16,515,072 fixed
bytes total**. The twelve buffer owners are created once. Copy and frame fence
handles are transient but bounded to one per slot; the live path only polls and
never waits. A debug draw adds one empty same-queue command submission to obtain
the post-frame fence after the ordinary frame submit. The scenario's aggregate
upload corresponds to about 28.9 KiB per presented frame and allocates no mesh,
buffer, transfer buffer, or CPU owner per frame. Teardown alone submits any
partial frame and waits for device idle before releasing external resources.

## Interpretation

The capacity is deliberately far above this first mixed sandbox scenario:
32,768 lines and 16,384 triangles versus observed peaks of 524 and 84. That is
useful development headroom, not a claim that the current limit is optimal.
S8 representative population/scale work must remeasure this alongside active
bodies and contact density before changing the default.

The fixed ring overwrote spans as designed because roughly fourteen named host
and runtime scopes are emitted across a typical frame/tick mix. Overwrite is
visible evidence loss, not backpressure. A developer needing a deeper timeline
uses Instruments signposts/sampling and Metal capture; increasing an in-engine
unbounded trace is intentionally outside S4-C.

Wall-clock span values are intentionally not promoted to pass/fail thresholds
from this uncontrolled workstation run. The acceptance gate proves phase
coverage, bounded retention/loss accounting, upload/draw ownership, and
authority invariance. Stable-hardware performance budgets belong to the later
representative-scale gate.
