# ADR-010: Developer Diagnostics, Replay, and Debug Visualization

**Status:** Accepted, implemented, and validated through M3
**Date:** 2026-07-13
**Amended:** 2026-07-13 after M3 bounded-authority completion
**Decision Maker:** Matt

## Context

The engine now has a complete streamed-district lifecycle, but a developer
still has to infer faults from ad hoc stderr messages and private subsystem
state. `Runtime` retains only a terminal fault bit, the editor has no coherent
diagnostic surface, asynchronous completion timing cannot be reproduced, and
the physics and rendered representations cannot be compared through an
engine-owned debug contract.

S4 must make the current sandbox inspectable and reproducible without creating
a mutable service locator, exposing Flecs/Jolt/SDL internals, adding a remote
telemetry platform, or promising cross-platform deterministic physics.

## Decision

S4 is delivered as three bounded developer workflows that share immutable,
backend-neutral data contracts.

### Structured diagnostics and retained faults

The kernel owns a fixed-capacity diagnostic journal. Entries contain fixed-size
typed fields: severity, category, code, sequence, optional tick/frame, thread
role, optional persistent identity, and optional correlation identity. Appends
do not allocate and cannot fault simulation. When full, the journal overwrites
the oldest entry and increments a visible counter. A conditional diagnostic
capture belongs to the journal rather than an individual producer. The host
arms one optional severity/category/code match through the runtime, and every
runtime, feature, adapter, and host append evaluates it. A retained matching
entry consumes the one-shot condition and then freezes capture; nonmatching or
rejected entries leave it armed. Appends while frozen increment a separate
visible rejection counter.

Freeze configuration and capture state are independent. Disarming does not
resume capture. Clearing retained entries changes neither frozen nor armed
state. Resuming capture does not re-arm a condition already consumed by a
match. A condition armed while frozen remains staged for the first matching
entry admitted after resume. The journal's statistics are the authoritative
source of `trigger_armed`; hosts do not keep a parallel policy value.

The first `Runtime` system failure is retained independently of the journal.
It copies the phase, system name, tick, error name/code, and associated journal
sequence into an immutable value before returning the error. After attempting
the journal append, the runtime force-freezes capture independently of the
optional host condition. Journal overflow, an earlier freeze, sequence
exhaustion, later failures, and subsequent `RuntimeFaulted` calls cannot
replace or hide the fault; sequence zero records that no journal entry was
admitted. Bounded-name truncation is an explicit field and every human
inspection surface marks it rather than presenting a clipped name as complete.

Features, workers, adapters, and hosts expose explicit read-only diagnostic
values. Those values contain counts, queue occupancy/high-water/rejection
statistics, lifecycle states, identities, and byte budgets; they never contain
raw Flecs entities, Jolt pointers/IDs, SDL objects, allocators, or mutable
feature contexts. The visual and headless hosts assemble the same versioned
developer snapshot; host-specific capabilities are optional, so headless
reports presentation time/control, cooked streaming, and GPU state as absent.
Stderr/text, JSON, tests, and ImGui consume that snapshot and journal rather
than reaching into owners independently.

Editor inspection is read-only. The only reverse path is a narrow host-control
request value. Pause, single-step, and fixed enumerated time scales alter wall
time contributed to the fixed-step accumulator, never the authoritative fixed
delta or persistent state. Pausing clears pending gameplay input and cannot
create a resume catch-up burst.

S4-A originally reported the then-unbounded single-player feature queues
honestly while tracking occupancy and high-water. M3 later completed the
authority change: feature command/outcome queues and external producer
ingress/results are now fixed-capacity, with reservation before mutation and
typed backpressure. The diagnostic snapshot reports those current capacities,
high-water marks, rejections, and retained reservations.

### Same-cohort flight recording and replay

The flight recorder belongs to the concrete sandbox composition rather than
the generic runtime. It records authoritative semantic commands at the
`Simulation.submit*` boundary with their actual eligible tick, plus
nondeterministic logical ingress at the tick where the feature consumes it.
Presentation handles, frame timing, pause state, editor state, and GPU timing
are excluded from the authoritative stream.

The first replay contract started only at a typed cold replayable boundary,
before authoritative commands/ticks, and records bootstrap commands. Snapshot
V4 was the S4-era schema and was not an arbitrary physics continuation
checkpoint: it intentionally omitted
Jolt solver/contact/vehicle caches, world construction parameters, pending
commands, and active asynchronous generations. A mid-run capture request at a
non-replayable boundary returns a structured `not_replayable_boundary` result.

The current same-cohort contract uses `SnapshotV7`, replay schema cohort 5,
and the canonical catalog content cohort. The same exclusion of opaque Jolt,
pending queue, asynchronous generation, and presentation state still applies;
no older replay or snapshot cohort is accepted.

The build graph provides one generated simulation-cohort module containing
the exact dependency revisions, schema/schedule cohorts, Jolt flags/workers,
and physics capacities consumed by replay. A host-built verifier proves those
revision values still occur in the pinned manifests. The replay codec
serializes that supplied value and no longer imports the concrete Jolt adapter
to discover build policy.

The capture fingerprint is split into:

- a simulation cohort: Zig/target/optimization, engine schedule and schema,
  Flecs/Jolt revisions and flags, and an explicit Jolt worker count;
- a world configuration: fixed delta, capacities, and constructed ground/block
  parameters;
- a content cohort: bundle format/schema/source identity and integrity digest;
- informational producer metadata such as editor/renderer configuration.

Captures use an explicit little-endian, versioned, bounded envelope with
integrity metadata and complete structural validation before world creation.
Feature-owned canonical encoders produce runtime, crate, character, vehicle,
and district subdigests after every tick. Replay reports the first divergent
tick and category. Recorder saturation marks the capture incomplete while the
live simulation continues safely.

The guarantee is exact-cohort logical reproduction on the supported Apple
Silicon macOS cohort. It is not a cross-build, cross-platform, peer-lockstep,
or universally bit-identical Jolt guarantee.

### Physics visualization and focused profiling

Physics extraction produces a bounded immutable batch of renderer-neutral
lines and triangles with category, color, optional opaque object identity,
completed tick/generation, and per-category overflow counts. The Jolt adapter
copies shapes, bounds, centers of mass, velocities, and supported contact data
after a completed tick. Any Jolt worker-thread contact callback may only copy
into fixed concurrent scratch storage; it cannot allocate or touch ECS,
renderer, editor, or contact settings.

The Metal host owns a fixed slot ring for extracted batches: buffers are
created once, upload uses `cycle=false`, and copy/post-submit fences are polled
without waiting. The real frame uses ordinary submission; each debug draw then
adds one empty same-queue command whose fence guards slot reuse. A busy ring
visibly drops new evidence while retaining the
latest completed exact generation; it never creates hidden backing storage.
Repeated enable/disable starts an explicit retry epoch without reinstalling
physics ownership or changing simulation. CPU geometry storage and rigid-body
contact capture and the paired line/fill graphics pipelines are optional
capabilities whose unavailability is visible and cannot fail authority
construction. Headless tests consume the same batch
without renderer/editor dependencies.

Profiling uses a separate fixed-capacity ring of fixed phase/span identifiers
for input, content, runtime phases, physics, extraction, GPU upload/fence
polling, drawing, editor, and submission. It does not flood the diagnostic
journal or introduce a generic tracing service. Instruments and Metal capture
remain the deep Apple-platform profiling tools.

## Failure and Ownership Rules

- Diagnostic append, snapshot, debug extraction, and profiling paths may drop
  bounded evidence visibly but may not fault or mutate authority.
- Diagnostic producers cannot select or bypass capture policy per append. The
  journal owner applies the same armed condition to every admitted entry.
- A retained conditional match consumes its one-shot arm. Frozen or
  sequence-exhausted rejection cannot consume it, and runtime-fault
  force-freeze does not consume an unrelated arm.
- A retained runtime fault remains available after the runtime becomes
  terminal and through orderly teardown.
- Diagnostic formatting/export after successful headless authority is
  best-effort: allocation loss is reported without replacing authority
  success. While preserving an existing authority failure, diagnostic loss
  likewise cannot replace the original error.
- The visual host enters an explicit inspect-only state only for a retained
  runtime-system fault; unrelated SDL, GPU, content, and teardown failures
  continue to propagate.
- Worker snapshots copy plain data while holding their mutex for the shortest
  possible interval. Formatting and UI never run under a worker lock.
- Debug listeners are optional paired owners and are detached before their
  world. On visual teardown, any partial frame is submitted and the device is
  drained before external GPU buffers are released; no such wait occurs in the
  live frame path.

## Consequences

- Headless and ImGui diagnostics describe the same engine state.
- Faults preserve actionable system/phase/tick context even when bounded
  timeline storage saturates.
- Replay is deliberately narrow but honest about physics and asynchronous
  state that cannot be reconstructed from a logical save.
- Diagnostics expose bounded queue capacity, reservation, high-water, and
  rejection behavior without becoming authority.
- Debug visualization and profiling remain optional consumers of immutable
  data instead of new authorities.

## Deferred

- arbitrary mid-run Jolt state recording or rollback;
- cross-platform deterministic replay and peer lockstep;
- remote telemetry ingestion, distributed tracing, crash-upload services, and
  production analytics;
- mutable editor consoles or universal debug service locators;
- network authentication, remote retry/idempotency, and transport-level rate
  limiting, which remain conditional S9 work;
- secondary-platform visualization/profiling adapters.
