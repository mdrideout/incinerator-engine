# ADR-021: Local Human-Test Incident Bundles

**Status:** Accepted

**Date:** Accepted 2026-07-16; evidence-capability amendment 2026-07-17

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

Schema 2 retains a 30 FPS 480x270 product-only trail from approximately four
seconds before through three seconds after the flag, five full-resolution
human-visible anchors at -2/-1/0/+1/+3 seconds, a product-only flag frame, and
a 320x180 semantic-ID image with a stable identity/color map. The swapchain is
copied into a stable composition-owned texture before product capture; no
adapter samples the swapchain directly. Every PPM has indexed actual timing,
tick/frame, source, generation, fence, digest, format, and integrity metadata.

**Save note + Copy for LLM** is one ordered request: it persists the current
note, attaches the active accepted-ingress replay, flushes a concise handoff,
and publishes only that handoff through SDL's main-thread clipboard. The giant
gameplay-trace terminal export is removed rather than retained as a
compatibility path.

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

`inspect-incident` strictly validates schema 2 and indexes a bundle.
`replay-incident` performs same-cohort semantic replay through one explicit
public-output boundary. `--replay-incident=<absolute-run-folder>` drives
captured controls through the normal graphical composition, but is explicitly
best effort and cannot replace deterministic replay or a promoted regression
scenario.

The local evidence is developer-only. It captures no arbitrary text, global
input, credentials, signed admission material, upload, analytics, or remote
service.

## Consequences

- A human report now identifies exact process, anomaly, clocks, ticks, frames,
  stream windows, screenshots, recorder health, and replay evidence.
- File I/O and image encoding leave the render/simulation path. GPU completion
  is polled; the render loop never waits for a screenshot fence.
- Queue, disk, line, anomaly, image-slot, replay-envelope, and memory bounds
  are explicit. Missing evidence remains visible.
- Replay schema cohorts 9 and 10 add vitals and authority-owned NPC replacement
  ingress discovered by the first real and first full combat incident replays.
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
