# S4-C Physics Visualization and Focused Profiling Validation Record

> **Historical phase record.** This document preserves the evidence and claims
> recorded when this slice closed. Counts, cohorts, platform results, and
> limitations below describe that dated tree, not current support. See the
> [current macOS readiness record](macos-readiness.md) and
> [cleanup plan](../../CLEANUP_PLAN.md).

**Date:** 2026-07-13

**Status:** Complete and independently reviewed. The complete Debug,
ReleaseFast, editor, package, installed Metal, and aggregate macOS matrix passes
with no remaining actionable P0/P1/P2 finding.

**Platform:** Apple Silicon macOS is the sole current supported visual cohort.
The renderer-neutral extraction and profiling records remain available to cold
headless tests without SDL, Metal, ImGui, or editor linkage.

**Scope:** S4-C only. S4-A structured diagnostics and S4-B same-cohort replay
remain complete. Multiplayer and secondary platforms remain deferred.

## Implemented Contract

### Bounded renderer-neutral extraction

The engine contract exposes finite, immutable line and triangle batches tagged
with a completed fixed tick, nonzero storage generation, stable category, and
optional plain object correlation. Caller-owned storage has separate fixed line
and triangle capacities. Every attempted, admitted, invalid, local-overflow,
and upstream-producer-overflow primitive is counted per category without an
allocator or fallible authority path. Schema v1 colors are explicitly opaque
RGB; their reserved fourth lane must be `1.0` and carries no blend semantics.

The Jolt adapter retains engine-owned normalized box, sphere, capsule, vehicle
chassis, and wheel descriptors. It queries stopped-world transforms, AABBs,
centers of mass, and velocities after a completed tick; no raw Jolt identifier
or shape crosses the contract. A permanent per-world contact listener writes
Added/Persisted rigid contacts to a fixed 4,096-slot atomic scratch area. Jolt
validation remains on its default path because the pinned C adapter allocates
shape-face arrays in its validation callback. CharacterVirtual and wheel
contacts use their direct query APIs. Scratch saturation becomes visible
contact-line overflow rather than changing collision response. Contact capture
is an optional paired listener/scratch capability: allocation or listener
creation failure cannot fail `Physics.init`, and affected batches mark the
contact source unavailable without inventing a primitive count. All other
debug categories remain available.

The listener is detached from `PhysicsSystem` before its listener/scratch owner
and the physics system are destroyed. Shape-descriptor replacement is
transactional: a failed body mutation cannot make later debug extraction lie
about the body that remains live.

### Persistent Metal overlay

The visual host owns a fixed three-slot ring for the complete application
lifetime. Each slot contains one line and one triangle GPU vertex buffer plus
matching transfer buffers: six GPU and six transfer buffers total. Upload maps
with `cycle=false`, submits one bounded copy, and acquires a copy fence. The
host polls fences with `SDL_QueryGPUFence` and never waits in the live path.
The real frame first uses the ordinary fallible submit path. After every debug
draw, the host submits one empty command on the same queue and transfers that
post-submit fence to the slot; this makes optional fence failure distinguishable
from real frame-submit failure. At most one owned fence exists per slot; when
all slots are busy the new batch is visibly dropped for backpressure and the
latest completed exact generation remains drawable.

Opaque, two-sided fills are depth-tested without writing depth and render
before coplanar lines. The renderer therefore preserves diagnostic line
evidence without implying alpha blending. Stale, disabled, empty, failed,
backpressured, or deinitialized generations are typed non-authority statuses.

GPU or post-submit-fence failure disables only the overlay and clears or conservatively
retires affected evidence. A fresh typed enable begins a retry epoch even when
the simulation is paused on the same CPU generation. No per-frame mesh,
buffer, transfer buffer, or allocator owner is created; copy/frame fence
handles are transient and bounded to the slot count. App startup also treats
the multi-megabyte CPU batch owner as best-effort. Both diagnostic graphics
pipelines are also one optional transactional renderer capability; their
creation failure leaves the renderer and simulation usable while making the
GPU overlay visibly unavailable. On teardown, any partially
recorded frame is submitted and the device is drained before external buffers
are released; this is the only overlay-related idle wait.

### Fixed host profiling and UI

The host profiler is separate from the diagnostic journal. It retains fixed
named spans for input, content pumping, all four runtime phases, physics-debug
extraction/upload/draw, streamed-GPU pumping, scene extraction/draw, editor,
and submission. Explicit host timestamps, success/failure closure, monotonic
sequences, ring overwrite/rejection accounting, and fixed per-frame
draw/upload/stream/live-resource counts require no allocator and cannot reject
an authoritative tick.

The default rings retain 2,048 spans and 240 frame records. Clearing drops only
retained samples; lifetime loss counters and sequence cursors remain visible.
The ImGui panel consumes immutable snapshots and borrowed ring views, and emits
only fixed typed enable/category/profile/clear requests that the composition
root applies after rendering. Instruments and Metal capture remain the deep
profiling workflow; S4-C introduces no generic tracing or telemetry service.

## Focused Evidence

| Gate | Recorded result | Principal evidence |
|---|---:|---|
| physics adapter | **38/38 Debug and ReleaseFast tests pass** | all shapes/categories, optional rigid-listener OOM/create failure, rigid/character/wheel contacts, atomic publication/reset/overflow, 100 toggles, state invariance, descriptor transactions, init failure, repeated worlds |
| persistent GPU adapter | **24/24 Debug and ReleaseFast tests pass** | fixed-slot saturation, async generation lag, `cycle=false` planning, copy/post-submit fence ownership, enable/fail/retry epochs/deinit lifecycle, bounded ownership/accounting |
| profiler and typed visualization controls | **9/9 tests pass** | fixed spans/frames, wrap/rejection/exhaustion, count saturation, clear semantics, bounded request mailbox |
| full Debug, editor disabled | **106/106 steps; 420/420 tests pass** | complete project graph and final binary boundary checks |
| full ReleaseFast, editor disabled | **106/106 steps; 420/420 tests pass** | optimized complete graph and final binary boundary checks |
| full Debug, editor enabled | **109/109 steps; 420/420 tests pass** | ImGui panel and typed borrowed-view composition compile |
| filtered extracted source package | **35/35 steps; 48/48 tests pass** | cold headless/replay/content graph with shader tools unavailable |
| installed native Metal smoke from `/tmp` | **37/37 steps pass** | real streamed district plus crate/character/vehicle, all categories, persistent upload/draw, bounded profile wrap, clean teardown |
| ReleaseFast aggregate macOS readiness | **47/47 steps pass** | S2/S3/window/init/S4-A/S4-B/S4-C installed gates run serially |
| final independent integration review | **Pass** | no remaining actionable P0/P1/P2 finding after the bounded-ring, retry-epoch, real-frame-submit, optional-capability, and teardown re-audits |

The native smoke ran 600 presented frames at a controlled 80 Hz and completed
900 fixed ticks. It retained 900 CPU batches, peaked at 524 lines and 84
triangles, dropped no primitive, and observed shapes, bounds, contacts, centers
of mass, and velocities. It performed 600 copy submissions, 600 nonblocking
copy completions, 600 overlay draws, and 600 accepted post-submit frame fences
with zero backpressure through the
fixed three-slot ring. Exactly six GPU plus six transfer buffers stayed live;
owned fences peaked at two against the hard maximum of three. The profile
rings retained their fixed 2,048 spans/240 frames while reporting 7,853
overwritten spans.

## Acceptance Status

| S4-C requirement | Current status |
|---|---|
| No raw Jolt types cross the bounded immutable contract | **Verified** |
| Crate, character, vehicle, ground, and district expose aligned debug evidence | **Verified by adapter geometry/alignment assertions plus installed Metal render-command-path evidence; no pixel assertion** |
| Rigid, CharacterVirtual, and wheel contact evidence is supported | **Verified** |
| Repeated enable/disable, saturation, init failure, and teardown are safe and visible | **Verified** |
| Persistent Metal upload is fixed-capacity, query-only in the live path, and visibly backpressured | **Verified by implementation tests and installed smoke** |
| Fixed named spans and frame/resource counts are bounded and fault-safe | **Verified** |
| Debug/profiling changes no logical digest, save bytes, body mode, lifecycle, or release ownership | **Verified by 22/22 headless acceptance tests in Debug and ReleaseFast** |
| Cold headless and replay products remain free of SDL/editor/GPU dependencies | **Debug, ReleaseFast, and 48-test filtered-package boundaries verified** |
| Debug, ReleaseFast, editor-enabled, native aggregate, and source-package gates | **Verified** |
| Final independent integration review | **Verified; no remaining actionable P0/P1/P2 finding** |

## Reproducing the Evidence

```sh
zig build test-physics test-physics-debug-gpu test-developer-profile \
  test-developer-visualization test-simulation -Deditor=false --summary all
zig build smoke-installed-s4-physics-debug-macos \
  -Deditor=false --summary all
zig build test -Deditor=false --summary all
zig build test -Deditor=true --summary all
```

The complete closeout also runs:

```sh
zig build test -Doptimize=ReleaseFast -Deditor=false --summary all
tools/verify_source_package.sh
zig build test-macos-readiness \
  -Doptimize=ReleaseFast -Deditor=false --summary all
```

## Explicit Nonclaims

S4-C is not a generic tracing backend, remote telemetry/crash upload service,
production performance budget, pixel-readback or physical-display correctness
assertion, arbitrary mid-tick physics inspection path,
Jolt's debug-renderer cache, cross-platform renderer abstraction, or
cross-build deterministic-physics guarantee. Debug geometry and profile
records are ephemeral evidence, never save/replay authority. Multiplayer
remains deferred, and Linux/SteamOS and Windows impose no current compatibility
requirement.
