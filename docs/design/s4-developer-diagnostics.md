# S4 Developer Diagnostics and Reproducibility

> **Historical slice design.** This was the delivery contract for the slice at
> closure. Detailed file layout, cohorts, and limitations below may have been
> consolidated later. See [ADR-010](../adr/010-developer-diagnostics-replay-and-debug-visualization.md)
> and the [cleanup plan](../../CLEANUP_PLAN.md) for current architecture.

**Date:** 2026-07-13
**Status:** S4-A and S4-B are complete and independently reviewed with no
remaining actionable P0/P1/P2 finding. S4-C and the integrated S4 closeout are
also complete and independently reviewed with no remaining actionable
P0/P1/P2 finding.

## Outcome

A developer can inspect the complete district load/cancel/reload lifecycle,
retain the first authoritative runtime fault, control fixed-step execution,
capture a replayable current-cohort scenario, identify the first logical
divergence, compare physics with presentation, and profile the named hot path.

S4 adds evidence paths, not new authorities. Simulation mutation remains typed
feature commands at fixed-tick boundaries. Diagnostics, replay validation,
debug extraction, profiling, stderr/JSON, and ImGui consume immutable values.

The governing decision is
[ADR-010](../adr/010-developer-diagnostics-replay-and-debug-visualization.md).

## S4-A: Structured Diagnostics and Live Inspection

### Kernel contract

The backend-neutral journal is a fixed 256-entry ring with nonzero monotonic
sequence numbers. It overwrites the oldest entry on saturation and reports the
total overwritten count. The journal, not an individual producer or the UI,
owns the optional severity/category/code freeze condition. A host may arm or
disarm that condition through `Simulation`/`Runtime`; every later append from
the runtime, a feature, an adapter, or the host evaluates the same condition.

The condition is one-shot. Nonmatching retained entries leave it armed. A
matching entry is retained first, then consumes the condition and freezes the
journal. Rejection because capture is already frozen or the sequence space is
exhausted does not consume it. Arming while frozen stages a condition for a
later resume. Disarming does not resume, clearing changes neither frozen nor
armed state, and resuming does not recreate a consumed condition. The journal
reports its authoritative `trigger_armed` state alongside frozen and loss
statistics; hosts do not mirror this state independently.

`Runtime` stores an immutable first fault separately from the journal. The
fault is captured inside the phase/system loop and includes copied fixed-size
system and error names, phase, tick, error code, and optional journal sequence.
Every human inspection surface marks bounded-name truncation explicitly; JSON
retains the corresponding boolean fields.
After attempting to retain that entry, the runtime force-freezes capture
independently of the optional host condition. If the journal was already
frozen or could not admit the entry, the fault uses journal sequence zero but
remains authoritative and queryable while the runtime is terminal.

### Typed inspection

Each feature reports active count and command/outcome/event queue occupancy,
high-water, declared capacity, and rejection count. Occupancy includes unread
outputs and commands currently being applied; allocator capacity is never
reported as work. Crate, character, and vehicle producer queues remain
intentionally unbounded in S4-A (`capacity = null`). District channels report
their existing fixed limits and backpressure.

Worker diagnostics copy only plain lifecycle state, generation, whether the
thread started, whether cancellation was requested, and the ready/cancelled/
failed completion kind under their mutex. These facts remain orthogonal even
when the summarized state is `completion_ready`. Simulation aggregates the
runtime fault, fixed tick/delta, entity/body counts, feature snapshots, and
procedural worker snapshot. The visual host adds cooked-worker, stream-state,
GPU state/bytes/budgets, frame, and optional presentation-host time/control
data. A headless host sets presentation host time and every visual capability
to null rather than fabricating a zero-time frame.

District logical boundaries append named streaming entries for load request,
cancellation request, cancellation, failure, activation, and unload. A load
ticket generation is the stable correlation ID across one lifecycle;
activation and unload also carry the persistent entity ID. Admission is
allocation-free and nonfallible, so journal overwrite, freeze, or exhaustion
can lose evidence visibly but cannot reject or roll back the district
transition.

The visual host separately correlates cooked-content, logical-orchestration,
and GPU-residency transitions with a host-global monotonic lifecycle ID. This
cannot collide merely because concurrent registry slots share the same
per-slot scene generation, and it traces request, decode, logical admission,
staging, submission, residency, release, and drain while leaving each subsystem's
native identity and ownership private.

One versioned `DeveloperSnapshot` feeds:

- deterministic headless assertions;
- compact stderr text and canonical JSON export;
- the read-only ImGui diagnostics console/timeline;
- installed native lifecycle evidence.

### Time and fault controls

The host owns pause, one-tick step, and quarter/half/normal/double scale. Raw
frame elapsed time is distinct from time contributed to the accumulator.
Pause contributes zero time, clears gameplay action latches, and cannot create
a resume burst. One-step grants exactly one normal 1/120-second tick. Scale
changes cadence only; it never changes fixed delta or save bytes.

Only a failure accompanied by `Simulation.firstFault()` may enter visual
inspect-only mode. That mode stops authoritative ticks and streaming progress,
clears gameplay input, avoids potentially invalid feature extraction, keeps a
minimal render/editor event loop alive, and allows diagnostic export/quit.
The installed acceptance seam exercises the production `App.run` catch branch
with a resident cooked district/Metal scene, verifies no post-fault content or
streamed-GPU pump call and no tick/snapshot progress, renders a retained-fault
frame, consumes a real SDL quit, and receives the original runtime error.
Headless hosts emit the same structured snapshot on a best-effort basis and
return the original authority error; loss of diagnostic allocation after a
successful run is reported but does not turn authority success into failure.
SDL/GPU/host/teardown errors are not swallowed.

### S4-A acceptance

- [x] Journal wrap, overwrite, owner-wide one-shot freeze, disarm, resume,
  clear, and visible loss accounting pass in editor-disabled focused tests.
- [x] The immutable first fault identifies the exact phase, system, tick, and
  error and survives journal saturation and terminal calls.
- [x] Every feature and both worker paths expose tested typed occupancy,
  high-water, lifecycle, and rejection values.
- [x] The S3 district lifecycle produces correlated content/logical/GPU
  transitions and reaches a fully drained diagnostic snapshot at both 240 Hz
  and 80 Hz installed Metal cadence.
- [x] Deterministic tests prove resume and 0.5x/2x cadence without changing
  fixed delta; the installed Metal smoke proves a 20-second byte-identical
  pause and exact one-tick step.
- [x] Text, JSON, headless, and ImGui read the same snapshot/journal contract.
- [x] Editor-disabled and cold headless artifacts contain no ImGui/SDL GPU
  dependency while retaining diagnostics.
- [x] Debug, ReleaseFast, editor-enabled, installed Metal, package, and
  independent review gates pass.

The S4-A evidence and completed closeout matrix are recorded in the
[S4-A acceptance record](../validation/s4a-acceptance.md).

## S4-B: Same-Cohort Flight Recorder and Replay

### Replayable boundary

Capture begins before the first authoritative command or tick and includes the
bootstrap stream. A request made after ticking, with pending commands, active
asynchronous work, dynamic physics caches, or a non-quiescent district returns
`not_replayable_boundary`. Snapshot V4 remains a durable logical save contract,
not a hidden mid-run Jolt checkpoint.

### Recorded ingress

All commands are normalized and recorded where `Simulation.submit*` accepts
them, with the actual tick on which the feature may consume them. District
loader completion is recorded/injected at its feature-consumption tick after
same-tick commands. Presentation scene handles, GPU completion, render cadence,
pause, time scale, and editor visibility are excluded.

The bounded little-endian envelope contains simulation/world/content cohorts,
bootstrap commands, command/ingress records, and per-tick canonical subdigests.
It is fully validated before a replay world is created. Exact Jolt worker count
is configured and fingerprinted rather than inherited from host hardware.

### S4-B acceptance

- [x] A cold current-feature capture replays headlessly to matching runtime,
  crate, character, vehicle, and district digests at every tick.
- [x] Altered command and altered district completion identify the exact first
  divergent tick and category.
- [x] Corrupt, truncated, oversized, unordered, and incompatible captures fail
  before world construction.
- [x] Recorder saturation marks the capture incomplete without affecting live
  simulation.
- [x] Host-only pause and presentation metadata are excluded. Presentation
  observations cannot mutate fixed-tick state; if wall time changes when live
  asynchronous ingress is consumed, the actual consumption tick is recorded.
- [x] Replay has an SDL/editor-free executable and source-package gate.

The complete contract, evidence, and nonclaims are recorded in the
[S4-B acceptance record](../validation/s4b-acceptance.md).

## S4-C: Physics Visualization and Focused Profiling

The physics adapter extracts bounded immutable line/triangle batches after a
completed tick. Categories cover shapes, bounds, centers of mass, velocity,
and the contact information supported by the current rigid, CharacterVirtual,
and vehicle APIs. Each batch records completed tick/generation and visible
per-category overflow. No raw Jolt type crosses the contract.

The Metal adapter owns a persistent three-slot ring containing six transfer and
six GPU buffers. It maps with `cycle=false`, polls bounded copy/post-submit
fences without waiting in the live path, draws the latest completed exact generation,
and reports backpressure instead of growing storage. Headless tests consume the
same extracted batch. CPU storage and rigid-contact capture are optional
evidence capabilities whose loss cannot prevent authority construction. The
line/fill graphics pipelines are an optional paired renderer capability; each
drawn slot retains the exact fence from the frame submission that contains its
draw. A
separate bounded profile ring records fixed named phase spans and
draw/upload/resource counts; Instruments and Metal capture remain the deep
profiling workflow.

### S4-C acceptance

- [x] The crate, character, vehicle, and district scenario reports nonzero,
  aligned shapes/bounds/contact evidence in adapter/headless assertions and
  traverses the installed Metal render-command path. Pixel output remains an
  explicit nonclaim.
- [x] Repeated debug enable/disable and teardown are ownership-safe; bounded
  overflow is visible.
- [x] Debug/profiling changes no logical digest, save byte, body mode, lifecycle
  outcome, or resource release.
- [x] Installed Metal rendering uses bounded nonblocking overlay uploads.
- [x] Debug, ReleaseFast, editor-enabled, cold headless, package, and native
  gates pass; independent review found no remaining actionable P0/P1/P2 issue.

## Explicit Nonclaims

S4 does not provide arbitrary mid-run physics continuation, rollback netcode,
cross-platform determinism, peer lockstep, remote telemetry, production crash
upload, a mutable editor service locator, or hard limits on the accepted
single-player feature queues. Multiplayer remains S9 and secondary platforms
remain deferred.
