# S3-A Procedural District Acceptance Record

> **Historical phase record.** This document preserves the evidence and claims
> recorded when this slice closed. Counts, cohorts, platform results, and
> limitations below describe that dated tree, not current support. See the
> [current macOS readiness record](macos-readiness.md) and
> [cleanup plan](../../CLEANUP_PLAN.md).

**Date:** 2026-07-12
**Status:** Complete

## Outcome

The sandbox now composes one bounded asynchronous district lifecycle over the
same owner-thread Runtime and Jolt world used by crates, characters, and
vehicles. A request starts a real joined worker that produces only a fixed
renderer/ECS/physics-neutral build. A later simulation tick transactionally
commits one district entity and three static bodies. Cancellation and unload
return to exact baseline counts, sleeping bodies wake when streamed support is
removed, and Snapshot V4 reconstructs the active logical district without
persisting process-local handles.

This closes only the procedural/headless ownership foundation. It does not
claim cooked content, runtime glTF parsing, GPU residency, Metal upload,
proximity policy, installed cooked content, or full S3 completion. Those are
explicit S3-B/C gates.

## Automated Evidence

- `Runtime` records its construction thread. Fallible access returns
  `WrongRuntimeThread`; nonfallible owner-only access asserts instead of racing
  Flecs or mutable runtime bookkeeping.
- The district build contract is fixed-capacity plain data: one coordinate,
  recipe version/checksum, at most eight validated boxes, and at most 320
  decoded bytes. It imports no SDL, renderer, Flecs, Jolt, host, or feature
  implementation.
- The real loader admits one job, rejects stale generations and excess work,
  never detaches a thread, and joins on completion or shutdown. Deterministic
  event-gated tests prove cooperative cancellation after work actually starts,
  cancellation over a published but unconsumed result, teardown of in-flight
  work, and owner-thread admission rejection without sleeps.
- `DistrictFeature` fake-backed tests cover one-tick minimum activation,
  command-before-completion cancellation, stale tickets/completions, typed
  worker failure, bounded queues, transactional partial-body rollback,
  runtime-identity collision rollback, partial unload failure cleanup, exact
  extraction, checksum rejection, explicit terminal output-backpressure, safe
  faulted teardown, and byte-stable logical restore.
- The Jolt adapter validates and normalizes static boxes, preserves
  world-qualified body handles, rolls back failed rotation, destroys bodies
  before entities, and activates moving bodies inside removed support bounds.
- The shared simulation holds the worker at a stable heap-owned address,
  registers district command/commit before the one physics step, destroys the
  feature before joining/resetting its loader, and rejects configured maximums
  that cannot fit Jolt's declared body capacity before acquiring a world.
- The real headless composition cancels the first generation, activates the
  next, settles a dynamic crate on the raised district obstacle, unloads its
  support, observes the crate resume falling, and repeats three more complete
  activation/unload cycles with exact body/entity cleanup.
- Snapshot V4 validates district recipe/checksum plus global namespace, cursor,
  and cross-feature identity uniqueness before world construction. Active
  restore recreates three bodies and one entity using host-supplied presentation
  handles and immediately re-saves to identical bytes. Loading/cancelling state
  rejects save as `DistrictTransitionPending`.
- The headless source and final-binary gates continue to exclude SDL, ImGui,
  renderer, asset-loader, shader-tool, Metal, Vulkan, and D3D12 dependencies.
- `measure-s3` records real cancellation, request-to-activation tick/wall
  distributions, activation/unload, steady tick/extraction, exact 3-box/120-byte
  accounting, eight repeated cleanup cycles per trial, and teardown. CI checks
  schema and lifecycle invariants without timing thresholds.

## Persistence Contract

`DistrictV1` contains only persistent ID, chunk coordinate, recipe version, and
deterministic build checksum. Snapshot V4 excludes load tickets/generations,
worker thread and queue state, prepared ownership, runtime IDs, Jolt body IDs,
GPU handles, and presentation assets. Restore rebuilds the validated recipe
synchronously during registration and transactionally creates its entity and
static bodies.

This byte-stability guarantee applies to the declared logical snapshot
immediately after reconstruction. It is not a backward-compatibility promise,
opaque Jolt serialization, cross-platform lockstep claim, or guarantee that
future cooked schemas will reuse the procedural recipe format.

## Performance Evidence

The committed [`S3-A performance baseline`](../performance/s3a-baseline.md)
characterizes three procedural static boxes plus ground on the primary Apple
Silicon development machine. It gates 120 decoded bytes, one entity, three
district bodies, cancellation cleanup, and 24 clean measured lifecycle cycles.
Timings are comparison evidence only; cooked I/O, GPU upload, resident memory,
and native Metal costs remain unmeasured until S3-B/C.

## Closeout

The complete editor-excluded Debug, ReleaseFast, and editor-enabled Debug
matrices each pass 212/212 tests. The filtered source-package extraction passes
19/19 tests and executes the isolated headless graph. Worker ThreadSanitizer
passes 7/7 tests, and 100 repeated worker runs complete cleanly.

Independent architecture and correctness/concurrency/persistence reviews were
repeated after their findings were fixed. Both report no remaining actionable
P0/P1/P2 S3-A issue. S3-A is complete; S3-B cooked content/GPU residency and
S3-C proximity/native evidence remain open, so full S3 is not complete.
