# ADR-021: Local Human-Test Incident Bundles

**Status:** Accepted

**Date:** Accepted 2026-07-16; evidence-capability amendment 2026-07-17;
budget, handoff, and deterministic-failure amendments 2026-07-18; schema-3
visual-window amendment 2026-07-19

## Context

Typed gameplay journeys, invariants, causal traces, replay, and Metal
visibility gates can detect many regressions, but they did not give a human
tester one durable, time-correlated account of an unexpected visual or control
experience. Printing the retained gameplay journal as one large JSON terminal
line was not searchable, durable, visually correlated, or suitable for an LLM
handoff. A screenshot taken after a report also cannot recover what the tester
saw before it.

## Decision

Debug graphical product launches create one bounded local run under
`~/Library/Logs/Incinerator/runs` (or the explicit
`INCINERATOR_INCIDENT_ROOT`). The developer host owns the recorder and its
typed request mailbox. A dedicated writer thread solely owns files. Existing
gameplay trace, diagnostics, editor projections, semantic input, renderer, and
replay owners publish bounded immutable values; the recorder cannot mutate
them.

Command+Option+I, optional F9/Fn+F9 and Command+Shift+9 routes, and **Flag
anomaly** in the separate Incident Capture tool create an indexed 15-second
typed pre-roll/5-second post-roll window. The developer host records only
reserved shortcut candidates through received, matched, queued, and applied
stages so a macOS delivery failure is distinguishable from a routing failure.
Four line-oriented streams separate causal events, periodic state, semantic
input, and metrics.

Schema 3 retains a 15 FPS 480x270 product-only trail from approximately five
seconds before through two seconds after the flag, eight human-visible anchors
at every whole second from -5 through +2 stored at no more than 1280x720 while
retaining source dimensions in the index, a product-only flag frame, and a
320x180 semantic-ID image with a stable identity/color map. The swapchain is
copied into a stable composition-owned texture before product capture; no
adapter samples the swapchain directly. Every PPM has indexed actual timing,
tick/frame, source, generation, fence, digest, format, and integrity metadata.
Integrity checks flag both large zero-filled regions and frames dominated by
one quantized color; a camera embedded in a bright collision proxy is
diagnostic evidence, not a healthy screenshot merely because its bytes are
nonzero.

**Save note + Copy for LLM** is one ordered request: it updates the in-memory
note, attaches the active accepted-ingress replay, publishes a concise handoff
to the main-thread clipboard immediately, and queues the durable handoff. The
UI reports durable handoff state separately. Clipboard availability therefore
does not depend on unrelated visual evidence consuming the remaining disk
budget. The giant gameplay-trace terminal export is removed rather than
retained as a compatibility path.

`manifest.json` is an atomic live health snapshot. Anomaly lifecycle is an
event reduction, not a mutable last-row status. Finalization materializes
timeline, state, input, and metrics windows and records typed artifact presence
or missing reasons. Entity evidence uses tri-state authority/replication/
presentation/draw membership, stable entity plus incarnation identity,
five-second tombstones, and typed relevance facts.

The live manifest declares which entity kinds have full boundary evidence and
whether semantic vehicle parts and atomic note/handoff are supported. Vehicle
chassis and wheels share one stable entity identity. Chronological visual
reports are derived outside the immutable run folder from indexed actual
capture times.

`inspect-incident` strictly validates schema 3 and indexes a bundle.
`replay-incident` performs same-cohort semantic replay through one explicit
public-output boundary. `--replay-incident=<absolute-run-folder>` drives
captured controls through the normal graphical composition, but is explicitly
best effort and cannot replace deterministic replay or a promoted regression
scenario.

The installed debug product exposes five explicit IC5-G hardening profiles,
never implicit environment fallbacks: queue pressure, visual-budget
exhaustion, late writer-budget failure, screenshot submission failure, and
post-submission fence failure. Their manifests name the profile and exact
health counters. Any evidence loss makes the run `partial`; the strict
inspector validates the profile-specific expected loss. The late writer case
is ordered after marker/window/replay persistence so it proves that clipboard
publication is independent of `LLM_HANDOFF.md` durability without destroying
the evidence needed to diagnose the failure.

Schema 3 is an intentional greenfield break from schema 2. It replaces the
five-anchor marker with eight required UI-inclusive anchors and changes the
visual window from -4/+3 to -5/+2 seconds. Producer, inspector, handoff,
documentation, and diagnostics skill advance as one cohort; no schema-2
fallback parser is retained.

The local evidence is developer-only. It captures no arbitrary text, global
input, credentials, signed admission material, upload, analytics, or remote
service.

The 512 MiB run cap is partitioned into a 384 MiB visual lane and a 128 MiB
nonvisual reserve. Visual reservation is accounted before work enters the
writer. Once exhausted, new images are rejected with explicit counters and the
anomaly becomes partial; typed streams, lifecycle markers, notes, replay,
manifest refresh, and LLM handoff retain their reserve. Visual exhaustion is
not reported as a writer failure.

## Consequences

- A human report now identifies exact process, anomaly, clocks, ticks, frames,
  stream windows, screenshots, recorder health, and replay evidence.
- File I/O and image encoding leave the render/simulation path. GPU completion
  is polled; the render loop never waits for a screenshot fence.
- Queue, disk, line, anomaly, image-slot, replay-envelope, and memory bounds
  are explicit. Missing evidence remains visible.
- Replay schema cohorts 9 and 10 add vitals and authority-owned NPC replacement
  ingress discovered by the first real and first full combat incident replays;
  cohort 11 adds explicit player-requested versus forced-cleanup drop purpose.
  These are intentional greenfield breaking cohort changes; digested authority
  state is not allowed to mutate outside the recorded command spine.
- The normal product now supplies bounded asynchronous semantic-ID evidence;
  fence, slot, mapping, and writer failures make the anomaly partial instead of
  silently dropping identity evidence.
- Nearby or engaged NPC relevance is authority-owned with 20 m entry, 24 m
  exit, and 30-tick grace. One-hop presentation prefetch stages adjacent
  authored district visuals without activating collision or authority.
- Schema 1 is intentionally unsupported. Inspector, marker, handoff, replay,
  docs, and repository-owned diagnostic skill advance as one greenfield cohort.
- Current acceptance is Apple Silicon macOS solo product scope. Listen and
  dedicated bundle orchestration waits until those graphical human-test paths
  are active product priorities.

## Documentation contract

- This ADR records the durable why and owner boundaries.
- [`../design/human-test-incident-capture.md`](../design/human-test-incident-capture.md)
  owns schemas, workflow, budgets, and phased design.
- [`../validation/human-test-incident-capture.md`](../validation/human-test-incident-capture.md)
  owns commands, generated evidence, measurements, failures, and open limits.
- `README.md` owns tester/operator instructions.
- `skills/incinerator-incident-diagnostics/` is the canonical fresh-context
  LLM inspection and reproduction procedure. The personal installed skill is
  a deployed copy; repository docs and source remain authoritative.
