# S4-A Structured Diagnostics and Live Inspection Validation Record

> **Historical phase record.** This document preserves the evidence and claims
> recorded when this slice closed. Counts, cohorts, platform results, and
> limitations below describe that dated tree, not current support. See the
> [current macOS readiness record](macos-readiness.md) and
> [cleanup plan](../../CLEANUP_PLAN.md).

**Date:** 2026-07-13

**Status:** Complete. Implementation, Debug/ReleaseFast, editor-enabled,
installed Metal, aggregate macOS, filtered source-package, and independent
closeout review all pass with no remaining actionable P0/P1/P2 finding.

**Platform:** Apple Silicon macOS is the sole current native target. The
verified evidence in this record is renderer-independent/editor-disabled unless
explicitly stated otherwise.

**Scope:** This record covers S4-A only. The subsequent S4-B replay and S4-C
physics visualization/profiling phases are recorded separately and are now
complete; together the three records close S4.

## Implemented Architecture

### Journal and capture ownership

`Runtime` owns one fixed 256-entry backend-neutral journal on its owner thread.
Entries are fixed-size values containing severity, category, stable numeric
code, monotonic sequence, optional tick/frame, thread context, optional
persistent identity, and one correlation ID. Append performs no allocation and
cannot return a simulation error. A full journal overwrites its oldest entry
and increments a visible counter.

The journal also owns the optional freeze condition. The host can arm or disarm
one severity/category/code match through `Simulation`/`Runtime`, but a producer
cannot supply or bypass capture policy when appending. Consequently runtime,
feature, adapter, and host entries all participate in the same capture.

The condition is one-shot and has these exact rules:

- a nonmatching retained entry leaves it armed;
- a matching entry is retained, consumes the arm, and then freezes capture;
- rejection while already frozen or after sequence exhaustion does not consume
  the arm;
- arming while frozen stages the condition until capture resumes;
- disarming does not resume capture;
- clearing retained entries changes neither frozen nor armed state and
  preserves lifetime loss counters and the sequence cursor;
- resuming capture does not recreate a consumed condition; and
- `JournalStats.trigger_armed` is authoritative for every host and export.

### Immutable first fault

The runtime copies the first scheduled system failure into an immutable value
containing phase, tick, numeric error, bounded owned system/error names, and the
associated journal sequence. It then force-freezes capture independently of
the optional host condition. If the fault entry cannot be admitted because the
journal was already frozen or exhausted, sequence zero makes that loss
explicit while the separately retained fault remains queryable. Later failures
and terminal `RuntimeFaulted` calls cannot replace it.

### Typed inspection and lifecycle correlation

Crate, character, vehicle, and district features expose typed read-only counts
and command/outcome/event queue occupancy, high-water, capacity, and rejection
statistics. The allocator-backed single-player queues report `capacity = null`
rather than presenting allocator capacity as work capacity. District queues
report their actual fixed bounds and explicit backpressure losses.

The cooked-content and procedural workers copy only plain values under a short
mutex hold: lifecycle state, generation, thread-started flag, cancellation
request flag, and ready/cancelled/failed completion kind. They expose no thread
handle, allocator, scene ownership, or backend pointer.

District logical transitions emit named streaming codes for load requested,
cancellation requested, cancelled, failed, activated, and unloaded. The load
ticket generation is the stable correlation ID for the whole logical
lifecycle. Activation and unload additionally carry the persistent entity ID.
Journal admission is outside authoritative transition policy, so overwrite,
freeze, or exhaustion can lose evidence visibly but cannot reject, defer, or
roll back a district transition.

The visual host additionally emits content, logical-orchestration, and GPU
residency transitions using a host-global monotonic lifecycle ID as one
cross-layer correlation ID. This avoids collisions between concurrent
registry slots while keeping decoded I/O, typed logical admission, staging,
submission, residency, release, and full drain traceable together even though
their owners retain separate identities and lifetimes.

`Simulation.Diagnostics` composes the immutable first fault, completed tick,
fixed delta, entity/body counts, all feature snapshots, and the procedural
worker snapshot. The visual host adds cooked-worker, stream, GPU budget/usage,
frame, and host-time values. Presentation-host time/control state is optional;
headless hosts report it and every other visual value as absent. Text,
JSON, tests, and the editor consume the same versioned developer snapshot and
journal contracts.

### Control and failure boundary

Pause, one-tick step, and fixed time scales are host controls. They alter only
wall time contributed to the accumulator; fixed simulation delta and persisted
logical state are unchanged. The editor sends narrow typed control requests
and remains read-only with respect to simulation authority.

Only a failure accompanied by `Simulation.firstFault()` may enter the visual
inspect-only path. The installed S4 gate drives that failure through the real
`App.run` catch/retain branch with a resident cooked district and Metal scene,
then proves the committed simulation tick, completed-tick counter, stream
snapshot, GPU snapshot, and content/GPU pump call counts cannot progress. The
path clears gameplay input, avoids unsafe feature extraction, renders a
minimal retained-fault frame, consumes a real SDL quit event, and returns the
original runtime error. SDL, GPU, content, and teardown errors remain ordinary
propagated failures.

## Verified Editor-Disabled Evidence

The following focused steps were run individually after the finalized
runtime-owned one-shot trigger migration:

| Gate | Recorded result | Principal evidence |
|---|---:|---|
| `test-contracts` | **15/15 tests pass** | backend-neutral diagnostic entry and queue-stat contracts |
| `test-kernel` | **21/21 tests pass** | wrap/overwrite, one-shot match, unrelated-entry persistence, disarm, clear, resume, arm-while-frozen, sequence exhaustion, forced fault freeze, and immutable first fault |
| `test-content` | **9/9 tests pass** | cooked-worker lifecycle, cancellation, completion kind, generation reset, and joined ownership |
| `test-district-worker` | **8/8 tests pass** | procedural-worker queued/working/cancelling/completion-ready facts and cancellation-over-ready behavior |
| `test-district-feature` | **14/14 tests pass** | fixed queue statistics, named lifecycle ordering/correlation, persistent activation/unload identity, failure entry, drained snapshot, and frozen-journal transition noninterference |
| `test-developer-diagnostics` | **3/3 tests pass** | shared text/JSON snapshot, actionable compact first-fault text with explicit bounded-name truncation, and bounded request contracts |
| `test-simulation` | **20/20 tests pass** | aggregate diagnostics, trigger proxies, real-Jolt counts, exact immutable fault evidence, and journal-sequence correlation |
| `test-headless` | **15/15 build steps; 21/21 tests pass** | absent visual/host-time capabilities, best-effort emission under allocation loss, shared export, and source/final-binary SDL/ImGui boundary checks |

The full editor-disabled graph was then run:

```sh
zig build test -Deditor=false --summary all
```

Result: **PASS — 94/94 build steps and 332/332 tests.**

## Verified Full and Native Evidence

| Gate | Recorded result |
|---|---:|
| Debug, editor disabled | **94/94 steps; 332/332 tests** |
| ReleaseFast, editor disabled | **94/94 steps; 332/332 tests** |
| Debug, editor enabled | **97/97 steps; 332/332 tests** |
| Installed ReleaseFast diagnostics/Metal smoke from `/tmp` | **35/35 steps** |
| Installed Debug editor-enabled ImGui/Metal smoke from `/tmp` | **38/38 steps** |
| Installed S3 lifecycle at 240 Hz | **4 correlated lifecycles; 63 journal entries; resident + drained shared snapshots** |
| Installed S3 lifecycle at 80 Hz | **4 correlated lifecycles; 61 journal entries; resident + drained shared snapshots** |
| Aggregate ReleaseFast macOS readiness | **41/41 steps** |
| Filtered extracted source package | **29/29 steps; 31/31 tests** |

The dedicated S4 smoke records 600 paused frames (20 virtual seconds) without
advancing tick 1 or changing canonical save bytes; one accepted step advances
exactly to tick 2. It then proves one-shot freeze/reject/resume/clear, loads one
real cooked district to logical and Metal residency, and drives
`InjectedDeveloperDiagnosticFault` through the production loop on the next
attempted tick while committed simulation remains on the preceding tick. M3
made district output pressure a healthy typed admission rejection, so the old
capacity-abuse fixture was intentionally replaced: only the diagnostics-smoke
composition registers one dormant fixed-error commands-phase probe. Normal
sandbox, headless, replay, save, and M3 products cannot arm or reach it; queue
saturation/recovery remains covered by feature-capacity tests. The
probe records content pumps `1/1`, streamed-GPU pumps `0/0`, unchanged stream
and GPU snapshots, one retained inspection frame, a real injected/consumed SDL
quit, and the original error returned unchanged. The bounded shared
JSON export is parsed; its exact byte count varies with real-clock fields. The
teardown then retains identical fault evidence and releases the resident scene
cleanly.

`git diff --check` also passes after this record and its documentation links
were added.

## Acceptance Status

| S4-A requirement | Current status |
|---|---|
| Journal wrap, overwrite, runtime-owned one-shot freeze, disarm, resume, clear, and visible loss accounting | **Verified editor-disabled** |
| Immutable first fault identifies phase/system/tick/error and survives saturation and terminal calls | **Verified editor-disabled** |
| Every feature and both worker paths expose typed occupancy/high-water/lifecycle/rejection values | **Verified editor-disabled** |
| Logical district load → cancel → reload → activate → unload is ordered, correlated, and fully drained | **Verified editor-disabled** |
| Full content/logical/GPU diagnostic lifecycle reaches resident and drained installed snapshots | **Verified at 240 Hz and 80 Hz** |
| Pause/one-step preserve bytes natively; resume/0.5x/2x preserve fixed delta and bytes deterministically | **Verified** |
| Production runtime-fault loop freezes authoritative/content/GPU progress, renders inspect-only, consumes quit, and returns the original error | **Verified in installed Metal smoke** |
| Text, JSON, headless, and ImGui consume the same contracts | **Verified** |
| Editor-disabled and cold headless artifacts retain diagnostics without SDL GPU/ImGui linkage | **Verified editor-disabled** |
| Debug editor-disabled full graph | **Verified: 94/94 steps, 332/332 tests** |
| ReleaseFast editor-disabled full graph | **Verified: 94/94 steps, 332/332 tests** |
| Debug editor-enabled full graph | **Verified: 97/97 steps, 332/332 tests** |
| Installed ReleaseFast Metal diagnostics/fault-inspection smoke | **Verified: 35/35 steps** |
| Filtered extracted source-package membership/execution | **Verified: 29/29 steps, 31/31 tests** |
| Final independent closeout review | **Verified: no remaining actionable P0/P1/P2 finding** |

## Reproducing the Closeout Evidence

```sh
zig build test -Doptimize=ReleaseFast -Deditor=false --summary all
zig build test -Deditor=true --summary all
zig build smoke-installed-s4-diagnostics-macos \
  -Doptimize=ReleaseFast -Deditor=false --summary all
zig build smoke-installed-s4-diagnostics-macos -Deditor=true --summary all
tools/verify_source_package.sh
zig build test-macos-readiness \
  -Doptimize=ReleaseFast -Deditor=false --summary all
```

The final independent review covered architecture/dependency direction, fault
and capture semantics, worker/thread ownership, resource cleanup, visual
inspect-only behavior, build/package evidence, and documentation accuracy. It
closed with no remaining actionable P0/P1/P2 finding.

## Explicit Nonclaims

S4-A does not add a remote telemetry service, distributed tracing, production
crash upload, mutable editor service locator, arbitrary mid-run Jolt capture,
rollback netcode, peer lockstep, cross-platform deterministic physics, or hard
network-facing queue limits. Multiplayer remains S9, S4-B owns replay, S4-C
owns physics visualization/profiling, and Linux/SteamOS/Windows remain deferred.
