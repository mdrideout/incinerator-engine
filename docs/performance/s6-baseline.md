# S6 Two-District Streaming Baseline

> **Historical phase baseline.** Measurements and limits below are preserved as
> recorded for this slice; they are not measurements of the current tree. See
> the [current macOS readiness record](../validation/macos-readiness.md) and
> [cleanup plan](../../CLEANUP_PLAN.md).

**Recorded:** 2026-07-13
**Status:** Complete native S6 characterization
**Platform:** Native Apple Silicon macOS / Metal only
**Mode:** Installed `ReleaseFast`, editor excluded, launched from `/tmp`

## Workload

The installed host resolves the fixed canonical catalog relative to the
executable, then moves a synthetic fixed-tick focus between the west-only,
overlap, east-only, overlap, and west-only bands. It completes three full
forward/reverse cycles and finally moves outside both districts.

Every overlap validates two exact catalog coordinates, two logical entities,
six district static bodies, two canonical draws, and two resident authored
scenes. Every single-district stage validates that the other district has
fully drained while its neighbor remains active. The final stage requires the
content worker, both logical slots, both presentation coordinators, and every
GPU registry owner and byte counter to return to zero; the sandbox ground is
the only remaining body.

## Reproduction

```sh
zig build smoke-installed-s6-macos \
  -Doptimize=ReleaseFast -Deditor=false --summary all
```

The serialized build step installs the two exact bundles and catalog, removes
`INCINERATOR_CONTENT_ROOT`, changes the process working directory to `/tmp`,
and runs 240 Hz followed by 80 Hz. Its frame ceilings are 240 and 96,
respectively; successful runs exit as soon as all milestones and final drain
are proven.

## Native Results

| Metric | Required | 240 Hz | 80 Hz |
|---|---:|---:|---:|
| Completed frames | within ceiling | 84 / 240 | 30 / 96 |
| Fixed ticks | greater than zero | 42 | 45 |
| Zero-tick frames | positive at 240 Hz; zero at 80 Hz | 42 | 0 |
| Multi-tick frames | zero at 240 Hz; positive at 80 Hz | 0 | 15 |
| Complete forward/reverse cycles | exactly 3 | 3 | 3 |
| Forward overlap validations | exactly 3 | 3 | 3 |
| Reverse overlap validations | exactly 3 | 3 | 3 |
| Peak live/resident scenes | exactly 2 / 2 | 2 / 2 | 2 / 2 |
| Peak active upload batches | bounded `1..2` | 1 | 1 |
| Peak staged CPU ownership | exactly 344 bytes | 344 | 344 |
| Peak in-flight upload ownership | positive multiple of 116, at most 232 bytes | 116 | 116 |
| Peak resident GPU ownership | exactly 232 bytes | 232 | 232 |
| Clean final drain and shutdown | required | pass | pass |
| GPU driver | Metal | Metal | Metal |

The 232 resident bytes are two copies of the conformance scene's 116-byte GPU
payload. CPU decoding is intentionally serialized through one content worker,
so staged CPU ownership remains 344 bytes even while both already-uploaded
scenes overlap. The registry has two fixed scene slots and permits at most two
bounded upload batches; the observed workload used one batch at a time.

Raw result lines:

```text
S6_STREAMING_SMOKE_RESULT frames=84 ticks=42 zero_tick_frames=42 multi_tick_frames=0 overlap_cycles=3 forward_overlaps=3 reverse_overlaps=3 peak_live_scenes=2 peak_resident_scenes=2 peak_active_batches=1 peak_staged_cpu_bytes=344 peak_in_flight_upload_bytes=116 peak_resident_gpu_bytes=232 final_drain=true virtual_render_hz=240 gpu_driver=metal
S6_STREAMING_SMOKE_SHUTDOWN status=clean
S6_STREAMING_SMOKE_RESULT frames=30 ticks=45 zero_tick_frames=0 multi_tick_frames=15 overlap_cycles=3 forward_overlaps=3 reverse_overlaps=3 peak_live_scenes=2 peak_resident_scenes=2 peak_active_batches=1 peak_staged_cpu_bytes=344 peak_in_flight_upload_bytes=116 peak_resident_gpu_bytes=232 final_drain=true virtual_render_hz=80 gpu_driver=metal
S6_STREAMING_SMOKE_SHUTDOWN status=clean
```

The build gate completed 46/46 steps. A separate installed S3 regression gate
also completed 46/46 steps at both cadences after the two-slot refactor.

## Interpretation

This baseline proves bounded adjacent overlap, independent neighbor drain, and
complete ownership cleanup for exactly two deliberately tiny authored
districts. It is not a throughput target, open-world streaming architecture,
origin-rebasing claim, general asset cache, or secondary-platform result. S8
must remeasure the same budgets under the representative NPC workload.
