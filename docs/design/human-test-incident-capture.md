# Human Test Incident Capture And LLM Diagnostic Handoff

**Status:** Schema-2 IC5-A through IC5-F and the IC5-H bounded-object evidence
correction plus the IC5-G long gameplay/replay, real window lifecycle, and
bounded capture-cost gates are complete for the Apple Silicon macOS solo
developer product. Controlled destructive/failure hardening and the physical
shortcut/district/NPC/vehicle human checkpoint remain open under the
[IC5 corrective plan](incident-evidence-reliability-and-boundary-corrections.md)

**Date:** 2026-07-17

**Platform:** Apple Silicon macOS; secondary platforms remain deferred

**Predecessor decision:**
[`../adr/020-gameplay-interaction-validation-and-observability.md`](../adr/020-gameplay-interaction-validation-and-observability.md)

**Existing validation design:**
[`gameplay-interaction-validation-and-observability.md`](gameplay-interaction-validation-and-observability.md)

**Accepted decision:**
[`../adr/021-local-human-test-incident-bundles.md`](../adr/021-local-human-test-incident-bundles.md)

**Implementation evidence:**
[`../validation/human-test-incident-capture.md`](../validation/human-test-incident-capture.md)

**Corrective implementation plan:**
[`incident-evidence-reliability-and-boundary-corrections.md`](incident-evidence-reliability-and-boundary-corrections.md)

## Purpose

Turn a human-observed gameplay anomaly into one bounded, searchable, visually
correlated, and replay-assisted local evidence bundle. A tester should be able
to flag a problem while it happens, optionally add a note, and copy one concise
handoff message that tells a developer or LLM exactly where the evidence lives
and when the anomaly occurred.

This is developer tooling. It must not become gameplay authority, a remote
telemetry service, a mutable editor service locator, or a reason to weaken the
typed scenario and replay contracts already accepted under ADR-020.

## Background

Post-S11 human testing found defects that broad unit, headless, replay,
session, fault, and installed Metal gates did not explain clearly enough to a
human tester. ADR-020 closed much of that gap with typed gameplay journeys,
continuous invariants, a bounded causal gameplay trace, readable product
feedback, and semantic Metal visibility checks.

The next manual pass exposed a remaining diagnostic workflow problem:

- the gameplay trace is retained in a fixed 1,024-record memory journal;
- the operational diagnostic journal retains 256 records separately;
- normal-product presentation membership and lifecycle transitions are typed;
- accepted-ingress replay and deterministic scenarios already exist;
- the validation-only Metal oracle can write a color image and object-ID mask;
- but the normal human export allocates the retained gameplay journal as one
  JSON document and prints it as one large terminal line;
- exported records have authority tick and optional presentation frame, but no
  run identity or wall/monotonic clock mapping for a human report;
- the graphical product does not continuously retain the real swapchain frames
  needed to recover a screenshot from before a flag; and
- fixed `/tmp` validation artifact names cannot organize multiple anomalies or
  multiple product launches.

The missing boundary is therefore not another logging API. It is a durable
incident recorder that consumes the existing typed evidence, adds bounded
sample streams and visual context, and owns local artifact organization.

## Research Basis

The design adapts established local diagnostic patterns without importing a
large tracing framework:

- Perfetto uses bounded ring buffers, periodic drainage to files, trigger-based
  capture, explicit loss behavior, and maximum file sizes.
- Unreal Trace, Visual Logger, and Rewind Debugger retain local trace files,
  actor snapshots, searchable timelines, and screenshots for post-hoc review.
- NDJSON makes each record independently appendable, parseable, and searchable
  with ordinary line-oriented tools.
- OpenTelemetry's stable event model distinguishes the time an event occurred
  from the time it was observed. Incinerator can preserve that useful semantic
  distinction without adopting OpenTelemetry.
- SDL 3 exposes main-thread clipboard publication, GPU texture downloads,
  reusable download transfer buffers, and nonblocking fence queries required
  for this macOS-local workflow.

References appear at the end of this document.

## Design Principles

1. **Preserve typed owners.** Gameplay trace, operational diagnostics,
   presentation observations, input, physics, session, and replay remain
   separate owners. The recorder consumes immutable values or typed events.
2. **Do not block authority or rendering.** File I/O and image encoding never
   run on the simulation critical path. GPU capture must not wait on a fence in
   the render loop.
3. **Make loss explicit.** Every bounded queue, retained window, GPU capture
   slot, and disk budget reports saturation, drops, and truncation.
4. **Use one causal time vocabulary.** Recorder sequence, process monotonic
   time, wall time, authority tick, and presentation frame are correlated but
   never treated as interchangeable.
5. **Record what the human saw.** Human screenshots come from the real product
   swapchain after product and developer UI rendering, not from a separate
   validation preview.
6. **Keep semantic and visual evidence distinct.** A screenshot explains
   appearance. Typed state and object IDs explain identity and causality.
7. **Optimize for local tools and LLMs.** Small manifests, line-oriented
   records, stable schemas, absolute paths, and exact anomaly indices are more
   useful than one giant JSON object.
8. **Reproduction is an explicit claim.** Same-cohort semantic replay can be
   verified. Graphical re-execution of live OS, GPU, and asynchronous timing is
   a best-effort reproduction until a deterministic regression scenario owns
   the defect.
9. **Remain developer-only.** Shipping builds do not record private inputs,
   local paths, diagnostic state, or screenshots unless a later product
   decision defines an explicit supported incident-reporting feature.

## Ownership And Separation Of Concerns

### Incident recorder

One developer-host-owned recorder exists per product process. It owns:

- run and anomaly identities;
- bounded ingestion queues and recorder-wide monotonic sequence;
- the mapping between wall, monotonic, tick, and frame time;
- anomaly pre-roll and post-roll state;
- writer health, drop counters, and disk budgets; and
- immutable status projected to the dedicated Incident Capture tool and its
  status-only product confirmation.

It cannot mutate gameplay, authority, session, renderer, or editor state.

### Incident writer

A dedicated low-priority writer owns directories, open files, segmentation,
buffered writes, flushes, durable synchronization, atomic manifest updates,
retention, and error reporting. Producers never own file handles.

### Screenshot recorder

A renderer adapter owns reusable GPU download buffers, fences, completed raw
frame slots, and image encoding requests. It records the final swapchain image
and publishes completed immutable frames to the incident recorder. It does not
own anomaly policy or filesystem paths.

### Control boundary

The editor and global developer hotkey submit fixed typed requests. The
developer host applies them after immutable frame borrows end, following the
same control ownership already used by diagnostics and gameplay trace tools.

### Replay attachment

The incident recorder asks the existing replay/session owners for a bounded
same-cohort capture. It does not define another replay schema and does not
serialize privileged authority internals directly.

## Run And Process Organization

The default macOS root is:

```text
~/Library/Logs/Incinerator/runs/
```

Every product process launch creates a unique run directory immediately:

```text
2026-07-15T23-54-12.431-0400_solo_7f2c9e/
```

The timestamp is human-readable and filename-safe. The random suffix prevents
collisions. Files never rely on the timestamp alone for causal ordering.

For a future orchestrated listen or dedicated journey, the orchestrator may
create one parent journey directory with a child directory per process. Every
manifest carries the shared session/topology ID and its independent process
run ID. Normal solo remains one directory and does not pay for a general
distributed trace service.

## Bundle Layout

```text
<run>/
├── manifest.json
├── anomalies.ndjson
├── LLM_HANDOFF.md
├── streams/
│   ├── timeline-000001.ndjson
│   ├── state-000001.ndjson
│   ├── input-000001.ndjson
│   └── metrics-000001.ndjson
├── anomalies/
│   └── anomaly-0003_tick-18420_frame-9672/
│       ├── marker.json
│       ├── screenshot-m1000ms.png
│       ├── screenshot-t0000ms.png
│       ├── screenshot-p1000ms.png
│       ├── semantic-id-t0000ms.png
│       └── state-window.ndjson
└── replay/
    └── accepted-ingress.icrp
```

`manifest.json` is created with `status: "running"`. Clean shutdown updates it
atomically to `complete`. A stale running manifest makes an interrupted or
crashed run visible on the next launch; no signal handler attempts complex
filesystem or allocator work.

## Stream Contracts

Streams are separated by cadence and retention pressure, not by every engine
subsystem.

| Stream | Purpose | Typical cadence |
|---|---|---|
| `timeline` | Gameplay transitions, action dispositions, lifecycle, diagnostics, streaming, network state changes | Event driven |
| `state` | Nearby entity, camera, presentation, physics, and ownership samples | Bounded periodic sampling |
| `input` | Semantic game controls, mouse deltas, focus, and input routing | State changes plus bounded samples |
| `metrics` | Frame, simulation, queue, network, GPU, writer, and loss aggregates | Once per second |
| `anomalies` | Human bookmarks and exact evidence ranges | On flag/update |

Each NDJSON line is one complete UTF-8 JSON object with:

- schema and record kind;
- recorder sequence;
- run and process identity;
- event-origin monotonic time when known;
- recorder-observed monotonic time;
- UTC wall time for human correlation;
- authority tick and presentation frame when applicable;
- channel/source and correlation identity;
- typed payload; and
- truncation, coalescing, or loss metadata when applicable.

Enum names are written as readable strings. Numeric values may accompany them
where the number belongs to an external or versioned contract. One line has a
declared maximum size; oversized arbitrary payloads are not admitted.

## Batching, Rotation, And Retention

The writer appends new records rather than dumping the complete memory rings
repeatedly.

Initial budgets to validate during implementation:

- publish a writer batch approximately every 250 milliseconds or when its
  bounded batch fills;
- flush language/runtime buffers approximately once per second;
- rotate a stream at 4 MiB or 30 seconds, whichever occurs first;
- durably synchronize after anomaly post-roll finalization and clean shutdown;
- cap a normal run at 256 MiB before images and explicitly report when a
  capture policy reduces or stops evidence;
- retain the newest 20 unflagged runs by default; and
- pin every flagged run until a human explicitly removes it or a later policy
  provides an equally visible alternative.

These are starting budgets, not promises. The acceptance phase must measure
record rates, p95/p99 frame effect, disk growth, shutdown latency, and writer
saturation under representative gameplay and faults.

## Anomaly Flag Workflow

Command+Option+I is the recommended macOS developer shortcut. F1-F3 already
belong to editor controls and F8 belongs to manufactured multiplayer
reconnect. F9/Fn+F9 remains an optional convenience because macOS may consume
the function row before SDL sees it; Command+Shift+9 remains an alternate. The
developer host records only reserved shortcut candidates through `received`,
`matched`, `queued`, and `applied`, including focus and route facts. It does
not record arbitrary keyboard input or text.

When the tester uses either shortcut or clicks **Flag anomaly**:

1. allocate a monotonic anomaly ID;
2. record wall time, monotonic time, authority tick, presentation frame,
   recorder sequence, topology/session, local entity, and selected entity;
3. bind the preceding 15 seconds and following 5 seconds of data as its
   diagnostic window;
4. bind the bounded 30 FPS product-only trail from approximately four seconds
   before through three seconds after the flag;
5. request human-visible anchors at -2, -1, 0, +1, and +3 seconds;
6. capture one product-only flag-adjacent image;
7. request one semantic object-ID image and stable identity/color map at time
   zero;
8. show a nonblocking product toast identifying the anomaly and post-roll
   status; and
9. allow the human to add or edit a note after the event.

Rapid flags receive distinct IDs. They may reference overlapping stream
ranges, but one flag never overwrites another flag's metadata or images.

## Screenshot Strategy

Visual evidence uses two asynchronous lanes because the human may react
several seconds after a transient. A 30 FPS, 480x270 product-only circular
trail retains approximately four seconds before the flag and continues three
seconds after it. A full-resolution human-visible lane captures -2, -1, 0, +1,
and +3 second anchors after product and developer UI rendering. A separate
product-only flag image and 320x180 semantic-ID image/map distinguish product,
developer-composition, and identity evidence.

The swapchain is first copied into a composition-owned stable texture with
color-target and sampler usage. Product captures blit from that texture; the
adapter never samples the swapchain directly. GPU completion uses nonblocking
fence polling, and filesystem work stays on the writer thread. Every visual
index entry stores requested and actual time, tick, frame, source, drawable
generation, fence timing, digest, pixel format, suspicious-image state, and
relative path. Filenames are labels, never timing evidence.

The actual screenshot remains unmodified. Labels and semantic mappings live in
metadata or a separate ID image so diagnostic overlays cannot obscure the
original symptom. PNG is preferred for tool compatibility if the existing
image dependency supports deterministic encoding; otherwise the first phase
may use a lossless BMP/PPM contract and document the format honestly.

## Data Required For Useful Diagnosis

### Build and environment

- source revision and dirty-worktree fingerprint;
- Zig, SDL, JoltC/Jolt, wrapper, protocol, replay, and snapshot cohorts;
- build mode, invocation, content root, and admitted content fingerprints;
- GPU backend/device, swapchain format, window size, display scale, and present
  mode; and
- scenario, random seed, deterministic fault profile, and product topology.

### Input and camera

- semantic key/button held state plus the explicit action edges consumed by
  the normal frame input buffer, so same-tick press/release pairs survive;
- right-mouse state and relative deltas;
- camera yaw, pitch, position, target, and projection values;
- window focus, minimize, relative-mouse mode, ImGui capture, and editor input
  passthrough; and
- action correlation ID and terminal disposition.

The recorder never captures global keyboard activity, arbitrary text input,
clipboard history, or events outside the product window.

### Authority, session, and gameplay

- participant, replicated, persistent, and incarnation identities;
- presence in authority, replication, presentation plan, and draw submission;
- position, velocity, facing, health, life, encounter state, target, and
  deadlines;
- vehicle and carry ownership, active district, and relevance state;
- action submission, admission/rejection, simulation outcome, publication,
  client application, and presentation; and
- spawn, death, retained proxy, despawn, replacement, and respawn causes.

The current evidence cohort applies the complete boundary ladder to
characters, NPCs, vehicles, and carryables. Vehicle chassis and four wheels
share one stable semantic entity identity while using distinct semantic object
IDs. The live manifest declares this capability matrix so an inspector does
not infer vehicle support merely because generic entity files exist.

### Physics

- controller/body identity and generation;
- capsule/body dimensions, transform, velocity, active and grounded state;
- collision layer and selected contact policy;
- nearest separation and current contact/blocker identity; and
- recent movement, support, collision, or placement query result relevant to
  the selected/local actor.

Physics samples remain interest-aware. The recorder does not dump an
unbounded copy of the complete physics world every tick.

### Presentation and rendering

- authoritative and presented transforms with interpolation age;
- camera/viewport and selected actor clip-space bounds;
- draw submission, mesh/material identity, tint, and visibility result;
- semantic pixel count/bounds when a GPU observation exists; and
- every presentation disappearance with a typed known cause or an explicit
  unexplained classification.

### Networking and asynchronous work

- topology, room generation, connection and reconnect state;
- message sequence, application receipt, snapshot age, reliable-event age,
  and bounded queue state;
- deterministic latency/loss/duplication/reorder/blackout decisions;
- content request, completion, cancellation, admission, residency, and
  retirement ordering; and
- thread role and observed time for cross-thread events.

Steam credentials, signed room tickets, authorization material, chat content,
and raw private payloads are never recorded.

### Performance and recorder health

- frame time, fixed ticks per frame, accumulator/backlog, and presentation age;
- queue occupancy, high-water, rejections, and overwritten records;
- GPU capture slots, fence latency, missed images, and encode/write latency;
- bytes by stream and total run size; and
- recorder queue loss, writer errors, flush state, and last durable sequence.

## Incident Capture UX

The editor provides a separate developer-only **Incident Capture** window:

- **Flag anomaly**;
- the current run's absolute path;
- writer/capture health and visible loss counters;
- a chronological anomaly list;
- per-anomaly post-roll and screenshot completion state;
- a note field editable after flagging;
- **Save note + Copy for LLM**, which persists the current note before replay
  attachment, handoff refresh, and clipboard publication; and
- **Open run folder**.

The shortcuts remain active while F1 hides editor windows. A compact toast
confirms the flag and later reports capture completion or a visible
partial-evidence error. The UX never claims that evidence is complete when a
write, screenshot, or replay attachment failed.

For visual review, `zig build incident-visual-report -- <run-folder>
<output-folder>` creates a chronological PNG contact sheet and frame map in a
separate output folder. It uses actual indexed capture times and frames, never
filename order or modification time, and refuses to write inside the original
evidence bundle.

## LLM Handoff Contract

**Save note + Copy for LLM** performs one ordered typed request. The developer
host saves the current note, attaches the replay, asks the writer to complete
pending post-roll and flush admitted evidence, updates `LLM_HANDOFF.md`, then
the main thread publishes the same concise UTF-8 text to the clipboard.

Example:

```text
Incinerator human-test anomaly bundle

Run folder:
/Users/matt/Library/Logs/Incinerator/runs/2026-07-15T23-54-12.431-0400_solo_7f2c9e

Human tester requested diagnostics at:
2026-07-15T23:57:03.114-04:00

Flagged anomalies:
- #2 tick=17320 frame=9120: NPC briefly disappeared near player
- #3 tick=18420 frame=9672: F did not visibly drop carryable

Start with:
- manifest.json
- anomalies.ndjson
- streams/timeline-*.ndjson
- anomalies/anomaly-0003_tick-18420_frame-9672/

Replay:
replay/accepted-ingress.icrp
```

The generated handoff also includes exact `rg` suggestions for the anomaly ID,
selected entity, and action correlation ID. It never embeds the full trace in
the clipboard.

## Reproduction Strategy

An incident bundle supports two deliberately distinct claims.

### Same-cohort semantic replay

The existing accepted-ingress replay is run against a fresh authority with the
captured content and configuration cohort. The tool reports match or the first
divergent tick/digest. This is the deterministic authority claim already
supported by the engine.

### Graphical reproduction attempt

A later `replay-incident` path launches the installed graphical composition
with captured semantic controls, camera input, render cadence, fault decisions,
and asynchronous completion ordering. This can reproduce much of the human
journey, but it does not claim bitwise OS, GPU, networking, or scheduler
determinism.

The durable repair workflow is:

```text
human flags anomaly
→ developer or LLM inspects indexed bundle
→ semantic replay and graphical reproduction attempt
→ defect becomes a deterministic scenario/invariant
→ implementation repair
→ headless and Metal regression
→ direct graphical acceptance
→ optional human confirmation
```

Logs and screenshots help locate a cause. The new deterministic regression is
what proves the repair remains fixed.

## Failure And Security Policy

- Artifact creation is best effort and never replaces the original gameplay
  or runtime failure.
- An unwritable root, full disk, failed atomic update, saturated writer queue,
  GPU backlog, failed image encoding, or replay-attachment failure is surfaced
  in the inspector and retained diagnostics.
- The writer never overwrites an existing run or anomaly path.
- Partial NDJSON files remain searchable through their last complete line.
- Untrusted or arbitrary strings are bounded and JSON escaped.
- Local evidence remains local. There is no upload, analytics SDK, account,
  daemon, or remote dashboard.
- Secrets and signed admission material are excluded at the typed projection
  boundary rather than redacted after serialization.

## Recommended Implementation Phases

### IC0 - Persistent contract and measured baseline — accepted

- [x] Accept or amend this design and record the durable architectural decision.
- [x] Measure current trace rates, export size, frame timing, and expected run
  duration before choosing final capacities.
- [x] Define versioned manifest, stream, anomaly, screenshot, and handoff
  schemas.
- [x] Define the developer-build boundary, privacy exclusions, retention, and
  source-package behavior.
- [x] Add a validation ledger and exact phase review protocol.

**Acceptance:** schemas and budgets have tests; no implementation status is
claimed from documentation alone.

### IC1 - Run bundle and asynchronous NDJSON writer — accepted

- [x] Create one unique run directory per product process launch.
- [x] Implement manifest lifecycle, monotonic recorder sequence, clock mapping,
  bounded writer queue, batching, segmentation, rotation, and retention.
- [x] Project existing gameplay trace, diagnostic journal, and presentation
  transitions without changing their ownership.
- [x] Replace giant terminal JSON export with durable bundle controls; do not
  retain a compatibility path.
- [x] Cover unwritable roots, collisions, partial lines, queue saturation, disk
  budgets, and clean/interrupted shutdown.

**Acceptance:** a normal run produces bounded grep-friendly files, explicit
loss counters, and no unbounded allocation or simulation-thread file I/O.

### IC2 - Human anomaly and LLM handoff workflow — accepted

- [x] Add Command+Option+I, optional F9/Fn+F9 and Command+Shift+9, and **Flag
  anomaly** through the typed
  developer control mailbox.
- [x] Implement 15-second pre-roll, 5-second post-roll, rapid independent flags,
  and editable notes.
- [x] Add anomaly status, writer health, visible errors, and run path to the
  dedicated Incident Capture tool.
- [x] Implement `LLM_HANDOFF.md`, **Save note + Copy for LLM**, and
  **Open run folder**.
- [x] Prove clipboard publication occurs on the main thread and never copies a
  giant trace.

**Acceptance:** a tester can flag multiple events, add notes, and paste one
self-contained handoff whose paths and stream ranges exist.

### IC3 - Trailing real-swapchain visual evidence — superseded by schema 2

- [x] Add reusable asynchronous swapchain download slots after all product/UI
  passes.
- [x] Retain a bounded pre-roll and save approximately -1, 0, and +1 second
  images per anomaly.
- [x] Add a time-zero semantic object-ID artifact and mapping metadata without
  blocking the renderer or leaking mutable render ownership.
- [x] Handle resize, minimize, missing swapchain, capture backlog, rapid flags,
  and shutdown during post-roll without a render-thread wait.
- [x] Measure memory footprint, frame-time effect, fence completion, missed
  captures, and artifact size on Apple Silicon Metal.

**Acceptance:** artifacts reflect the actual visible product, capture loss is
explicit, and enabled recording does not violate the accepted performance
budget.

### IC4 - Diagnostic state and reproduction attachments — accepted

- [x] Add bounded interest-aware input, camera, nearby entity, physics,
  presentation, streaming, network, and metrics projections.
- [x] Attach the same-cohort accepted-ingress replay and captured world/content
  configuration.
- [x] Add an `inspect-incident` command that prints a concise indexed summary.
- [x] Add a `replay-incident` semantic verifier with first-divergence evidence.
- [x] Keep graphical reproduction explicitly best effort until promoted into a
  deterministic scenario.

**Acceptance:** the reported disappearance, carry/drop, death, contact, camera,
and vehicle anomalies have enough correlated data to identify the responsible
authority, physics, session, presentation, input, or render boundary.

### IC5 - Evidence reliability, repairs, and hardening — in progress

- [x] Drive the installed graphical composition from captured semantic input
  and camera/fault timing.
- [x] Add automated schema-2 bundle capture to the current solo graphical
  product without creating a remote telemetry service. Listen and dedicated
  human-test orchestration remain deferred with those product priorities.
- [ ] Exercise disk full, unwritable root, queue saturation, rapid flags,
  minimized/closed window, GPU capture failure, unclean exit, and stale-run
  recovery.
- [x] Compare recorder-disabled and recorder-enabled p95/p99 frame behavior and
  long-run disk growth.
- [x] Perform schema-2 rendered Metal smoke acceptance plus ownership, dead-code,
  documentation-drift, and source-package audit.

**Acceptance:** a developer or LLM can inspect, replay, and visually re-run a
flagged journey; every partial-evidence case is honest; the phase does not
weaken authority or renderer boundaries.

The first long ordinary-product bundle showed that the v1 smoke evidence did
not close this phase: sparse nominal screenshots missed transitions that
preceded the flag, physical macOS key delivery was not observed, entity state
could not retain absent membership, the live manifest was stale, and long
semantic replay left an NPC encounter cue pending. IC5-A through IC5-H in the
[corrective plan](incident-evidence-reliability-and-boundary-corrections.md)
supersede the remaining broad checklist above. Schema-2 IC5-A through IC5-F,
the IC5-G normal/resize/minimize/rapid-flag/replay journey plus paired
capture-cost measurement, and the IC5-H bounded-object/evidence correction are
implemented and measured; controlled destructive fault cases and the real
macOS human checkpoint remain open. Historical IC0-IC4 acceptance remains
recorded rather than rewritten.

## Phase Review Protocol

After each phase:

1. compare implementation to this design and ADR-020;
2. run focused contract tests and inherited gates proportional to the changed
   boundary;
3. inspect queue, file, GPU, memory, and timing budgets;
4. inject the phase's failure cases;
5. inspect generated bundles manually with `rg` and the graphical artifact
   viewer;
6. review ownership, privacy, security, source-package, and documentation
   drift; and
7. update the future validation ledger before marking the phase complete.

## Definition Of Complete

- Every developer product launch creates one bounded, self-identifying local
  run bundle.
- A human can flag anomalies without pausing gameplay or opening the editor.
- One handoff clipboard message identifies all flagged timestamps, files,
  screenshots, notes, and replay evidence.
- The product trail, human-visible anchors, product-only flag frame, and
  semantic-ID artifact carry actual indexed timing and correlate with typed
  tick/frame/entity evidence.
- Discrete actions, entity disappearance, input routing, camera, physics
  contacts, presentation membership, and recorder health are searchable.
- Semantic replay either matches or reports the first divergence honestly.
- Graphical re-execution is useful but never mislabeled deterministic.
- Recording cannot block authority or rendering and has explicit, measured
  memory, GPU, disk, and loss budgets.
- No credentials, signed tickets, arbitrary typed text, or global input leave
  their owning boundaries.
- Giant terminal JSON export and fixed overwrite-prone artifact names no longer
  remain as compatibility paths.

## Explicitly Deferred

- remote telemetry ingestion, dashboards, hosted storage, or automatic upload;
- public player bug-reporting UX;
- crash minidumps and platform-wide crash handlers;
- continuous video encoding;
- complete per-tick world or physics dumps;
- broad screenshot golden testing;
- cross-platform artifact roots or GPU capture abstractions;
- deterministic operating-system, GPU, or public-network replay; and
- integration of Perfetto, OpenTelemetry, Tracy, or Unreal tooling.

## References

- [Perfetto trace configuration](https://perfetto.dev/docs/concepts/config)
- [Perfetto buffers and dataflow](https://perfetto.dev/docs/concepts/buffers)
- [Unreal Trace](https://dev.epicgames.com/documentation/en-us/unreal-engine/trace-in-unreal-engine-5)
- [Unreal Visual Logger](https://dev.epicgames.com/documentation/en-us/unreal-engine/visual-logger-in-unreal-engine)
- [Unreal Rewind Debugger](https://dev.epicgames.com/documentation/en-us/unreal-engine/animation-rewind-debugger-in-unreal-engine)
- [NDJSON specification](https://github.com/ndjson/ndjson-spec)
- [OpenTelemetry log data model](https://opentelemetry.io/docs/specs/otel/logs/data-model/)
- [SDL clipboard text](https://wiki.libsdl.org/SDL3/SDL_SetClipboardText)
- [SDL GPU texture download](https://wiki.libsdl.org/SDL3/SDL_DownloadFromGPUTexture)
- [SDL GPU fence query](https://wiki.libsdl.org/SDL3/SDL_QueryGPUFence)
- [SDL reusable transfer buffers](https://wiki.libsdl.org/SDL3/SDL_CreateGPUTransferBuffer)
