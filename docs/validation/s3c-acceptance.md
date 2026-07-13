# S3-C Boundary and Native Lifecycle Acceptance Record

> **Historical phase record.** This document preserves the evidence and claims
> recorded when this slice closed. Counts, cohorts, platform results, and
> limitations below describe that dated tree, not current support. See the
> [current macOS readiness record](macos-readiness.md) and
> [cleanup plan](../../CLEANUP_PLAN.md).

**Date:** 2026-07-13

**Status:** Accepted; implementation, native evidence, and independent reviews
are complete

**Platform:** Native Apple Silicon macOS / Metal only

**Scope:** S3-C and the remaining full-S3 closeout gates

S3 closed after final architecture, correctness/concurrency/resource, and
build/evidence reviews found no remaining actionable P0/P1/P2 issue.

## Accepted Boundary

Proximity is host policy, not district-feature policy. The sandbox composition
root selects one plain X/Z focus position: the occupied vehicle while driving,
otherwise the character. The native smoke supplies the same boundary with a
synthetic focus position. `DistrictFeature` imports neither character nor
vehicle code and never queries either feature.

The host evaluates one finite AABB Schmitt trigger exactly once per fixed
simulation tick. The load boundary is inclusive and lies strictly inside the
unload boundary; the band between them absorbs jitter. Render frames may pump
content and nonblocking GPU fences, but they cannot independently decide
district proximity. A deterministic tick script must produce the same
enter/exit edge sequence at 240 Hz and 80 Hz render cadence.

Desired presence and actual asynchronous state are separate:

- the proximity policy records whether the focus is inside;
- the lifecycle independently moves through content reading, logical
  admission/activation, GPU staging/submission/residency, unload/cancel, and
  drain;
- a desired re-entry observed while an older generation drains remains latched;
- a replacement request is admitted only after the prior scene and batch have
  fully drained.

This keeps simulation authority at the 120 Hz fixed tick while permitting
frame-rate-independent I/O and presentation progress.

## Cancellation Contract

### Cooked content worker

Content cancellation is cooperative, not arbitrary instruction-level
preemption. A bounded file read or decode already in progress may finish. Once
cancel is requested, however, that generation must not transfer a ready scene
to the host: cancellation wins before publication or over a
published-but-unconsumed completion, decoded ownership is released, and the
worker thread is joined by poll or teardown. A later request must use a larger
nonzero content generation.

### Logical lifecycle

The host translates departure into typed cancel or unload commands according
to the current logical state. Command processing precedes loader completion at
the fixed-tick boundary, so a same-tick cancel wins. A cancelled or failed
ticket cannot activate, resolve, unload, or release a newer ticket.

### GPU residency

The fake-backed registry is authoritative for the two timing-sensitive GPU
windows:

- **Pre-submit:** cancellation releases staged CPU/upload ownership
  immediately, invalidates the scene handle, and submits nothing.
- **Post-submit:** cancellation invalidates resolution immediately and marks
  the submitted candidate discard-on-completion. Fence polling remains
  nonblocking; once signaled it releases both candidate and submission, never
  publishes the scene, and returns all accounting to zero.

The native smoke proves cancellation in the complete installed lifecycle, but
the 116-byte upload may move through a particular pre/post-submit window too
quickly to make that race deterministic. It therefore complements rather than
replaces the fake-backed pre-submit and post-submit tests.

## Identity and Drain Contract

Content generations, logical request/ticket identities, and renderer scene
generations are nonzero and monotonic within their owners. Reusing a fixed
scene slot increments its generation; an older handle must return
`StaleSceneHandle` and cannot resolve or release its replacement.

Every cancellation and every completed unload must reach the following state
before a replacement is admitted:

| Owner | Required drained state |
|---|---|
| Content worker | no active job or unconsumed completion; thread joined |
| Host lifecycle | stream state `idle`; no pending decoded scene |
| Presentation coordinator | `idle`; prior scene handle stale |
| Logical simulation | 0 district entities, 0 district bodies, 0 extracted district draws |
| Shared test world | 0 feature entities and only the host ground body remains |
| GPU registry states | 0 live, reserved, staged, submitted, retiring, and resident scenes; 0 active batches |
| GPU registry bytes | 0 staged CPU, staged upload, in-flight upload, and resident GPU bytes |

Clean process shutdown must additionally emit
`S3_STREAMING_SMOKE_SHUTDOWN status=clean` after releasing SDL, Metal, Jolt,
content-worker, and host ownership.

## Deterministic Automated Evidence

The focused command below was run on 2026-07-13:

```sh
zig build test-content test-district-feature test-district-presentation \
  test-district-gpu-registry test-simulation \
  -Deditor=false --summary all
```

Result: **PASS — 22/22 build steps and 72/72 tests.**

| Focused gate | Result | Required proof |
|---|---:|---|
| `test-content` | 8/8 pass | monotonic worker admission, cooperative cancellation, joined completion, and released ready ownership |
| `test-district-feature` | 12/12 pass | typed cancellation/unload ordering, stale-ticket isolation, rollback, and logical cleanup |
| `test-district-presentation` | 11/11 pass | coordinator ownership, stale scene/ticket rejection, AABB hysteresis, derived-boundary validation, finite inputs, dead-band edges, and 240/80 fixed-tick cadence invariance |
| `test-district-gpu-registry` | 23/23 pass | pre-submit cancel, post-submit discard, fail-closed generation exhaustion, full per-state/byte drain, budgets, and nonblocking fence ownership |
| `test-simulation` | 18/18 pass | real Jolt composition and district lifecycle integration remain intact |

The following closeout matrix is required after all S3-C changes settle:

```sh
zig build test -Deditor=false --summary all
zig build test -Doptimize=ReleaseFast -Deditor=false --summary all
zig build test --summary all
```

| Matrix | Result |
|---|---|
| Debug, editor excluded | **PASS — 90/90 steps; 295/295 tests** |
| ReleaseFast, editor excluded | **PASS — 90/90 steps; 295/295 tests** |
| Debug, editor enabled | **PASS — 93/93 steps; 295/295 tests** |

The filtered extracted source package also passed 29/29 build steps and 28/28
tests with shader tools deliberately unavailable. Installed cooked-content
relocation passed 11/11 steps from `/tmp`, and the non-GPU `--verify-install`
path passed 35/35 steps against the installed fixture.

## Installed Native Metal Evidence

The canonical gate installs the executable plus cooked fixture and provenance,
then serially runs both cadences from `/tmp`:

```sh
zig build smoke-installed-s3-macos \
  -Doptimize=ReleaseFast -Deditor=false --summary all
```

Each invocation has a 1,200-frame ceiling and must finish its milestone-driven
lifecycle before reaching it: cancel one first load, fully drain it, then
complete three load-to-resident/unload-to-drained cycles. Success is based on
lifecycle milestones, not a sleep-sized race window.

| Cadence | Fixed-tick cadence proof | Lifecycle proof | Recorded result |
|---:|---|---|---|
| 240 Hz | 18 zero-tick frames | 1 cancelled load; 3 resident cycles; 3 unload cycles; 6 resident frames; exact peaks; final drain; clean shutdown | **PASS — 36/36-step gate** |
| 80 Hz | 7 multi-tick frames | 1 cancelled load; 3 resident cycles; 3 unload cycles; 3 resident frames; exact peaks; final drain; clean shutdown | **PASS — 36/36-step gate** |

For both runs, the result line must report `gpu_driver=metal`,
`peak_live_scenes=1`, `peak_active_batches=1`,
`peak_staged_cpu_bytes=344`, and 116 bytes each for peak staged upload,
in-flight upload, and resident GPU ownership. Resident
validation must observe one logical district entity, three static bodies, one
mesh, one material, and two authored instances. Every saved scene handle must
be stale after its cancellation or unload.

Record the complete `S3_STREAMING_SMOKE_RESULT` and matching clean-shutdown
line for each cadence in the
[`S3-C performance baseline`](../performance/s3c-baseline.md).

## Full-S3 Closeout Checklist

- [x] Host-owned, character/vehicle-independent proximity policy exists and is
  sampled only at fixed ticks.
- [x] Focused deterministic cancellation, generation, drain, and cadence gates
  pass.
- [x] Installed ReleaseFast 240 Hz `/tmp` result is recorded and passes.
- [x] Installed ReleaseFast 80 Hz `/tmp` result is recorded and passes.
- [x] Debug/editor-excluded, ReleaseFast/editor-excluded, and editor-enabled
  full graphs pass after the final changes.
- [x] Extracted source-package/install evidence is rerun after the final
  changes.
- [x] Independent architecture, correctness/concurrency/resource, and
  build/evidence reviews report no remaining actionable P0/P1/P2 finding.

## Explicit Nonclaims

S3-C does not add multiple simultaneous chunks, dependency graphs, culling,
LOD, hardware-instanced submission, compression, a general upload heap, or
cross-platform gates. It does not claim GPU pixel-readback validation: authored
scene structure is validated before rendering and the native Metal frame path
must remain available. The frame-latency and resource figures are
characterization evidence, not shared-CI timing thresholds or shipping-scale
throughput targets.
