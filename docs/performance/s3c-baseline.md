# S3-C Installed Streaming Lifecycle Baseline

> **Historical phase baseline.** Measurements and limits below are preserved as
> recorded for this slice; they are not measurements of the current tree. See
> the [current macOS readiness record](../validation/macos-readiness.md) and
> [cleanup plan](../../CLEANUP_PLAN.md).

**Recorded:** 2026-07-13

**Status:** Complete S3-C native characterization

**Platform:** Native Apple Silicon macOS / Metal only

**Mode:** Installed `ReleaseFast`, editor excluded, launched from `/tmp`

## Environment

| Field | Recorded value |
|---|---|
| Mac model / SoC | MacBook Pro `Mac14,6` / Apple M2 Max |
| CPU cores / memory | 12 cores (8 performance + 4 efficiency) / 64 GB |
| macOS version | 15.7.7 (24G720) |
| Architecture | `arm64` |
| Zig | 0.16.0 |
| Optimization / editor | `ReleaseFast` / excluded |
| SDL GPU driver | Metal |
| Commit | Working tree based on `7fa0146`; S3-C milestone commit pending |

## Workload

Each run uses the installed 868-byte cooked S3 fixture and a synthetic focus
position applied through the same fixed-tick proximity boundary as the
sandbox. It has a 1,200-frame ceiling and exits after these milestones:

1. begin one content/scene generation, move the focus out after logical
   submission, cancel, drain, and prove its scene handle stale;
2. load one replacement to logical activation and Metal residency;
3. validate one district entity, three static bodies, one mesh, one material,
   and two authored instances;
4. move out, unload, fully drain, and prove the handle stale;
5. repeat the resident/unload cycle until three cycles have completed;
6. prove the content worker, logical host, presentation coordinator, and GPU
   registry are empty before controlled shutdown.

The 240 Hz run proves frames with no fixed tick. The 80 Hz run proves frames
with multiple 120 Hz fixed ticks. Content and fence pumping remain per-frame
and nonblocking in both cases; proximity authority remains fixed-tick only.

## Reproduction

Run the canonical serialized gate:

```sh
zig build smoke-installed-s3-macos \
  -Doptimize=ReleaseFast -Deditor=false --summary all
```

It installs the Mach-O, cooked bundle, and provenance, then runs 240 Hz followed
by 80 Hz from `/tmp`. The gate removes `INCINERATOR_CONTENT_ROOT` so both runs
must derive the installed content root from the executable prefix. To capture
per-process wall time and maximum RSS without changing the workload, build once
and invoke the installed binary separately with the same environment isolation:

```sh
zig build -Doptimize=ReleaseFast -Deditor=false
repo_root="$(pwd -P)"
(
  cd /tmp
  unset INCINERATOR_CONTENT_ROOT
  /usr/bin/time -lp "$repo_root/zig-out/bin/incinerator_engine" \
    --s3-streaming-smoke --frames=1200 --virtual-render-hz=240
  /usr/bin/time -lp "$repo_root/zig-out/bin/incinerator_engine" \
    --s3-streaming-smoke --frames=1200 --virtual-render-hz=80
)
```

Keep each `S3_STREAMING_SMOKE_RESULT` line, its immediately following
`S3_STREAMING_SMOKE_SHUTDOWN status=clean` line, and the corresponding
`/usr/bin/time` block together. Do not combine results from different builds.

## Accepted Resource Envelope

These are the exact expected peaks for the one-scene fixture. The smoke rejects
a run when any emitted exact value differs.

| Resource | Expected / asserted | 240 Hz observed | 80 Hz observed |
|---|---:|---:|---:|
| Installed cooked bundle | 868 bytes | 868 | 868 |
| Static logical boxes | 3 | 3 | 3 |
| Peak live GPU-registry scenes | 1 | 1 | 1 |
| Peak registry-owned staged CPU | 344 bytes | 344 | 344 |
| Peak staged upload | 116 bytes | 116 | 116 |
| Peak in-flight upload | 116 bytes | 116 | 116 |
| Peak resident GPU | 116 bytes | 116 | 116 |
| Peak active batches | 1 | 1 | 1 |
| Resident district entities / bodies | 1 / 3 | 1 / 3 | 1 / 3 |
| Resident mesh / material / instances | 1 / 1 / 2 | 1 / 1 / 2 | 1 / 1 / 2 |

The 116 GPU bytes comprise 96 vertex bytes, 12 index bytes, and 8 texture
bytes. The staged CPU and upload values are registry accounting, not total
process heap or RSS. The cooked bundle is separately bounded at 64 KiB; this
workload records its 868-byte fixture rather than claiming a general decoded
content-memory high-water mark.

The enforced S3-B capacity limits remain 16 MiB staged CPU, 16 MiB in-flight
upload, 32 MiB resident GPU, and 8 MiB submitted per pump. Exact fixture peaks
are regression evidence inside those caps, not revised production budgets.

## Cadence and Lifecycle Results

| Metric | Acceptance | 240 Hz observed | 80 Hz observed |
|---|---:|---:|---:|
| Attempted frames | `1..1200`, milestone exit | 36 | 14 |
| Fixed ticks | `> 0` | 18 | 21 |
| Zero-tick frames | `> 0` at 240 Hz | 18 | 0 (observation) |
| Multi-tick frames | record at 240; `> 0` at 80 Hz | 0 | 7 |
| Cancelled loads | exactly 1 | 1 | 1 |
| Resident cycles | exactly 3 | 3 | 3 |
| Unload/drain cycles | exactly 3 | 3 | 3 |
| Fallback frames | record; no threshold | 0 | 0 |
| Resident frames | `> 0` | 6 | 3 |
| GPU driver | `metal` | `metal` | `metal` |
| Clean shutdown marker | required | present | present |

## Lifecycle Latency Characterization

The native result reports frame counts rather than imposing wall-time
thresholds. Convert a frame count to nominal scripted time with
`frames * 1000 / virtual_render_hz`; retain the original frame value because
worker scheduling and Metal fence completion are asynchronous.

| Interval | Statistic | 240 Hz frames / nominal ms | 80 Hz frames / nominal ms |
|---|---|---:|---:|
| First cancel request to complete drain | one cancelled generation | 5 / 20.83 | 2 / 25.00 |
| Desired load to Metal resident | maximum of 3 cycles | 7 / 29.17 | 4 / 50.00 |
| Desired unload to complete drain | maximum of 3 cycles | 5 / 20.83 | 2 / 25.00 |
| Whole process elapsed wall time | `/usr/bin/time -lp` real seconds | 0.48 s | 0.34 s |
| Whole process maximum RSS | `/usr/bin/time -lp` bytes | 74,350,592 | 74,432,512 |

The first interval begins after the initial cooked scene has reached the
host's logical-submission boundary. It is not a measurement of arbitrary
mid-read preemption. Cooked content cancellation remains cooperative: a
bounded read/decode may complete, but cancellation must win before ownership
is transferred or over an unconsumed completion.

## Final Drain Results

Every row must be zero at the end of each successful run. These observations
are asserted before the result line; the clean-shutdown marker then proves
controlled application teardown.

| Final value | Required | 240 Hz observed | 80 Hz observed |
|---|---:|---:|---:|
| District entities / bodies / draws | 0 / 0 / 0 | 0 / 0 / 0 | 0 / 0 / 0 |
| Pending decoded scene | 0 | 0 | 0 |
| Live / reserved / staged GPU scenes | 0 / 0 / 0 | 0 / 0 / 0 | 0 / 0 / 0 |
| Submitted / retiring / resident GPU scenes | 0 / 0 / 0 | 0 / 0 / 0 | 0 / 0 / 0 |
| Active upload batches | 0 | 0 | 0 |
| Staged CPU / staged upload bytes | 0 / 0 | 0 / 0 | 0 / 0 |
| In-flight upload / resident GPU bytes | 0 / 0 | 0 / 0 | 0 / 0 |
| Content worker active job/completion | 0 / 0 | 0 / 0 | 0 / 0 |
| Prior saved scene handles | stale | stale | stale |

## Raw Native Results

### 240 Hz

```text
S3_STREAMING_SMOKE_RESULT frames=36 ticks=18 zero_tick_frames=18 multi_tick_frames=0 cancelled_loads=1 resident_cycles=3 unload_cycles=3 cancel_to_drained_frames=5 peak_load_to_resident_frames=7 peak_unload_to_drained_frames=5 fallback_frames=0 resident_frames=6 peak_live_scenes=1 peak_active_batches=1 peak_staged_cpu_bytes=344 peak_staged_upload_bytes=116 peak_in_flight_upload_bytes=116 peak_resident_gpu_bytes=116 virtual_render_hz=240 gpu_driver=metal
S3_STREAMING_SMOKE_SHUTDOWN status=clean
real 0.48
user 0.07
sys 0.03
74350592 maximum resident set size
```

### 80 Hz

```text
S3_STREAMING_SMOKE_RESULT frames=14 ticks=21 zero_tick_frames=0 multi_tick_frames=7 cancelled_loads=1 resident_cycles=3 unload_cycles=3 cancel_to_drained_frames=2 peak_load_to_resident_frames=4 peak_unload_to_drained_frames=2 fallback_frames=0 resident_frames=3 peak_live_scenes=1 peak_active_batches=1 peak_staged_cpu_bytes=344 peak_staged_upload_bytes=116 peak_in_flight_upload_bytes=116 peak_resident_gpu_bytes=116 virtual_render_hz=80 gpu_driver=metal
S3_STREAMING_SMOKE_SHUTDOWN status=clean
real 0.34
user 0.07
sys 0.03
74432512 maximum resident set size
```

## Interpretation

This baseline characterizes one deliberately tiny, self-authored scene and the
ownership transitions around it. Frame latency, process RSS, and wall time are
comparison evidence only and are not shared-CI thresholds. The two native
runs establish installed-content relocation, fixed-tick proximity authority,
nonblocking Metal progress, repeated cancellation/unload cleanup, and bounded
resource accounting. They do not establish multi-chunk throughput, shipping
memory targets, pixel-readback correctness, culling/LOD needs, or secondary
platform support.
