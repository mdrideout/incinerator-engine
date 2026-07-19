# Incident Evidence Reliability And Boundary Corrections

**Status:** IC5-A through IC5-I implemented and software-validated; the IC5-G
long gameplay, window lifecycle, graphical/semantic replay, bounded A/B
performance, and deterministic failure-hardening gates pass; only the physical
macOS/human visual checkpoint remains open

**Date:** 2026-07-19

**Platform:** Apple Silicon macOS developer product; Linux and Windows remain
deferred

**Parent design:**
[`human-test-incident-capture.md`](human-test-incident-capture.md)

**Accepted decision:**
[`../adr/021-local-human-test-incident-bundles.md`](../adr/021-local-human-test-incident-bundles.md)

**Current validation record:**
[`../validation/human-test-incident-capture.md`](../validation/human-test-incident-capture.md)

## Purpose

Correct the evidence, replay, input, streaming, and relevance weaknesses
exposed by the first long ordinary-product incident bundle. This plan preserves
the accepted incident-recorder ownership model while replacing the v1
assumptions that proved too weak under real human use.

The work has two distinct outcomes:

1. a tester, developer, or fresh-context LLM can determine what the product
   received, simulated, published, planned, submitted, and displayed around a
   flag without guessing from filenames; and
2. the two reproduced gameplay defects become durable scripted regressions and
   receive product repairs at their owning boundaries.

This is not a general telemetry platform, video editor, render graph, generic
interest-management framework, or compatibility exercise.

## Triggering Evidence

The reference run is
`2026-07-16T13-56-17.518Z_solo_b5942566`. The private local bundle remains
outside source control. Its durable conclusions are recorded here so the plan
does not depend on that folder continuing to exist.

| Observation | Evidence | Boundary |
|---|---|---|
| East-district blocks appeared suddenly | District request through GPU residency and logical activation occurred at frames 2190-2195; the flag was frame 2357 | Presentation streaming happened about 1.6 seconds before the flag |
| NPC flashed/disappeared | NPC presentation despawn occurred at frame 3731 after the player crossed the district boundary; the flag was frame 3895; spawn returned at frame 4185 | Exact district-equality relevance removed a still-near NPC |
| Saved images missed both transitions | The three images were approximately one second before the flag, at the flag, and one second after it | Nominal flag anchors are not a trailing visual record of a human reaction |
| Image files could not prove their timing | Actual capture monotonic time was retained in the GPU slot and discarded when attached | Image filename and file modification time were insufficient evidence |
| Some images contained large black rectangles | Only one final-swapchain readback source existed | The bundle could not distinguish product rendering from capture corruption |
| Physical shortcuts did not work for the tester | Unit and smoke tests constructed an SDL event and called the handler; candidate key delivery was not recorded | The handler predicate was tested, not the macOS-to-SDL path |
| Entity state could not explain NPC absence | State records were built from existing draw lists and marked replication/presentation present | An absent actor left no authority/replication/presentation tombstone |
| Complete semantic replay failed | Long replay stopped with `NpcEncounterOutputsPending`; the replay drain omitted encounter cues | Short smoke replay did not exercise all output lanes |
| Live handoff reported stale health | `manifest.json` remained its startup snapshot while the process continued writing healthy streams | Copy-for-LLM did not publish a current live manifest |

Captured semantic input reproduced the east-district transition and NPC
presentation removal in a fresh graphical re-execution. Exact wall time, frame
time, GPU scheduling, and asynchronous return timing remained best effort, as
required by ADR-021.

## Decisions

### Evidence truth precedes gameplay repair

Repair the recorder contracts before changing district or relevance behavior.
Otherwise the repaired journey would be judged by the same incomplete
evidence that missed it.

### Flag time is not symptom time

The button or shortcut records `flag_monotonic_ns`. It never calls that instant
the anomaly time. A human reaction may lag the visible symptom by several
seconds. Visual and typed trailing windows make the causal transition
discoverable without asking the tester to estimate reaction latency.

### Use a greenfield schema cohort

The current bundle is schema 3. The inspector, replay adapter, repository skill
source, and documentation advance as one cohort. No schema-1/schema-2 reader,
fallback parser, legacy screenshot-mask interpretation, or compatibility shim
is retained. Earlier bundles remain historical evidence and are never mutated.

### Preserve semantic, product, and human-visible evidence separately

- Typed state explains engine ownership and causality.
- Product-only frames show the scene before developer UI.
- Human-visible frames show the final drawable including developer UI.
- Semantic-ID evidence maps pixels to stable presentation identity.

None substitutes for another.

### A physical macOS shortcut requires a physical acceptance gate

Synthetic SDL events remain useful unit tests. They cannot close the macOS
shortcut gate. At least one non-function-row application shortcut must be
observed through a real focused product window before the phase is accepted.
F9 remains an optional convenience because macOS may consume the function row.

## Ownership And Separation Of Concerns

| Owner | Added responsibility | Explicitly does not own |
|---|---|---|
| Incident recorder | Flag lifecycle, immutable evidence indices, time correlation, typed health projection | Files, GPU commands, gameplay mutation |
| Incident writer | Atomic live manifests, segmented streams, materialized anomaly windows, image/index files, budgets | Simulation or render timing policy |
| Screenshot adapter | Bounded GPU copies, trailing frame slots, fences, capture timestamps, immutable pixel buffers | Run paths, anomaly lifecycle, notes |
| Developer host | Reserved shortcut routing and narrowly scoped delivery telemetry | Global input logging or OS hooks |
| Authority/session | Relevance decisions and typed add/remove reasons | Rendering or incident-file policy |
| Presentation host | Membership transitions, draw submission identity, product-only capture point | Authority truth |
| Replay owner | Accepted-ingress verification, output-lane classification, first divergence | Claims of deterministic GPU/OS replay |
| Inspector/skill | Validation, correlation, reproduction workflow, claim language | Repairing or mutating the original bundle |

The graphical composition may coordinate these immutable projections. It may
not become a second owner of their mutable state.

## Schema-3 Bundle Contract

The implemented schema-3 anomaly layout is:

```text
<run>/
├── manifest.json
├── anomalies.ndjson
├── LLM_HANDOFF.md
├── streams/
│   ├── timeline-*.ndjson
│   ├── state-*.ndjson
│   ├── input-*.ndjson
│   └── metrics-*.ndjson
├── visual/
│   └── frame-<capture-sequence>_<presentation-frame>.ppm
├── anomalies/
│   └── anomaly-0001/
│       ├── marker.json
│       ├── timeline-window.ndjson
│       ├── state-window.ndjson
│       ├── input-window.ndjson
│       ├── metrics-window.ndjson
│       ├── visual-index.ndjson
│       ├── screenshot-human-m5000ms.ppm
│       ├── screenshot-human-m4000ms.ppm
│       ├── screenshot-human-m3000ms.ppm
│       ├── screenshot-human-m2000ms.ppm
│       ├── screenshot-human-m1000ms.ppm
│       ├── screenshot-human-flag.ppm
│       ├── screenshot-human-p1000ms.ppm
│       ├── screenshot-human-p2000ms.ppm
│       ├── screenshot-product-flag.ppm
│       ├── semantic-id-flag.ppm
│       └── semantic-id-map.json
└── replay/
    └── accepted-ingress.icrp
```

Run-level visual frames are written once and referenced by every overlapping
anomaly window. Rapid flags do not duplicate the same trailing frames.

### Live manifest

`manifest.json` remains an atomic snapshot, not an append-only stream. It is
refreshed:

- approximately once per second;
- immediately after a flag is admitted;
- after anomaly post-roll finalization;
- before a Copy-for-LLM handoff is published; and
- at clean shutdown.

It distinguishes `running`, `complete`, and `partial`, and records snapshot
wall/monotonic time, last admitted and durable recorder sequence, bytes by
artifact class, queue occupancy/high-water, drops, writer failures, screenshot
loss, and replay attachment status. A running manifest is valid live evidence,
but the inspector must label it partial-in-time rather than treating startup
zeros as current health.

Build identity includes source revision, dirty-worktree fingerprint, build
mode, Zig/SDL/Jolt/wrapper cohorts, protocol/replay/snapshot cohorts, content
fingerprints, product invocation, GPU device/backend, swapchain format, and
window/display scale. Build-time injection owns revision information; runtime
code does not shell out to Git.

### Anomaly lifecycle

Each `anomalies.ndjson` row separates:

- `event`: `flagged`, `note_updated`, `post_roll_finalized`, or
  `handoff_refreshed`; and
- `lifecycle_status`: `capturing`, `complete`, or `partial`.

A note update cannot demote or replace completion status. `marker.json` is the
canonical reduced current view and records every missing artifact with a typed
reason.

### Visual frame index

Every saved frame receives an entry containing:

- capture sequence and source: `product` or `human_visible`;
- requested offset from the flag when it is an anchor;
- target, submitted, completed, and writer-observed monotonic times;
- actual offset from the flag and timing error;
- authority tick and presentation frame at capture submission;
- dimensions, pixel format, drawable generation, and swapchain format;
- fence latency, byte count, digest, and relative path; and
- explicit missed/partial reason when no image exists.

File modification time is never used as capture time. Filenames describe the
requested anchor; the index records what actually happened.

### Causal entity state

Presence is a tri-state value: `present`, `absent`, or `unavailable`. The last
value matters for remote clients that cannot inspect authority internals.

The state projection is the bounded union of authority, replication,
presentation-plan, and draw-submission identities. A recently removed entity
retains a five-second tombstone containing its stable identity, incarnation,
last transforms, last health/life/encounter state, transition time, and typed
removal reason. It is not synthesized from the current draw list.

Relevance records include observer position and primary district, entity owner
district, evaluated policy facts, admitted relevance generation, baseline
transition, and typed inclusion/removal reason. District lifecycle records use
readable event names in addition to stable numeric codes.

## Visual Capture Policy

### Continuous trailing lane

The accepted target is a 15 FPS, 480x270, product-only circular lane covering
five seconds before the flag and two seconds after it. This is 80 retained
RGBA slots, approximately 40 MiB before transfer/fence overhead. It is
developer-only, bounded, and allowed to report loss rather than stall the
renderer.

Frames pinned by one or more anomalies are written once as lossless P6 PPM
artifacts and indexed from each anomaly. At 480x270 the seven-second window is
about 39 MiB as RGB PPM before filesystem overhead. The format stays directly
inspectable without adding a new encoder dependency. Compression or video is a
future measured optimization, not an entry requirement.

### Bounded human-visible anchors

The final human-visible drawable uses seven history-only source slots at 1 Hz,
leaving six completed samples available while one may be in flight. Two
separate event slots capture exact flag frames without consuming history when
incidents overlap. The history ring supplies the closest completed frames to
-5, -4, -3, -2, -1, +1, and +2 seconds. Each anchor retains source dimensions
but is stored at no more than 1280x720. The 15 Hz product lane owns transient
continuity; the sparse human lane owns product-plus-UI context. Actual timing
is always recorded; the implementation does not claim exact milliseconds. A
2560x1440 drawable plus the 80-slot product trail remains below the explicit
176 MiB diagnostic download-memory ceiling.

The product-only flag frame is captured before developer UI. A semantic-ID
flag frame and mapping are captured through the existing validation semantics
without exposing mutable renderer ownership.

### Stable capture source

Do not depend solely on direct download from the acquired swapchain. Copy the
selected product/final image into a composition-owned diagnostic texture on
the same command buffer, then download that stable non-swapchain source
asynchronously. This is a narrow capture adapter, not a generalized render
graph.

The first implementation must compare product-only, human-visible, and direct
validation patterns. Large zero-filled or rectangularly corrupted regions are
reported as suspicious evidence, not automatically classified as a gameplay
render failure.

### Budgets

Starting budgets to measure rather than silently exceed:

- at most 128 MiB live GPU/CPU trailing-capture memory at 1280x720;
- at most 512 MiB total run artifacts, partitioned into a 384 MiB visual lane
  and a 128 MiB nonvisual reserve;
- one stored copy for frames shared by overlapping flags;
- no render-thread fence wait or image encoding;
- explicit gaps when the target cadence or human-visible anchor is missed;
  and
- recorder-disabled versus enabled p95/p99 frame comparison on Apple Silicon.

## Concrete Implementation Sequence

The corrective track refines the open IC5 hardening phase. Complete it in the
following order; do not mark parent IC5 complete from partial progress.

| Phase | Outcome | Depends on |
|---|---|---|
| IC5-A | Evidence truth and schema-2 lifecycle | Accepted v1 baseline |
| IC5-B | Observable, physically accepted macOS shortcut | IC5-A |
| IC5-C | Temporally useful trailing visual evidence | IC5-A |
| IC5-D | Cross-boundary entity/relevance/presentation evidence | IC5-A |
| IC5-E | Replay, inspector, and LLM skill reliability | IC5-C, IC5-D |
| IC5-F | District-pop and NPC-relevance gameplay repairs | IC5-D, IC5-E |
| IC5-G | Long-run, fault, graphical, and human closeout | IC5-B through IC5-F |
| IC5-H | Bounded vehicle/carry continuity and evidence capability correction | IC5-D through IC5-G human evidence |
| IC5-I | Budget-safe handoff and truthful playable-boundary correction | IC5-H human evidence |

### IC5-A - Evidence truth and schema-2 lifecycle

- [x] Advance the incident schema, marker, inspector, handoff, and replay
  attachment cohort together; delete schema-1 parsing paths.
- [x] Add atomic live manifest snapshots and force one before clipboard
  publication.
- [x] Split anomaly event type from reduced lifecycle status.
- [x] Replace the screenshot bit mask with typed artifact entries and explicit
  missing reasons.
- [x] Materialize bounded timeline, state, input, and metrics windows after
  post-roll finalization.
- [x] Add build revision/cohort and current recorder-health fields.
- [x] Make `inspect-incident` warn on a live bundle, validate every reduced
  lifecycle, and distinguish unknown health from zero health.

**Focused gates**

- Atomic snapshots remain valid during concurrent stream writes.
- Copy-for-LLM reports current bytes, high-water, loss, and durable sequence
  while the product is still running.
- `note_updated` preserves `complete` or `partial` status.
- Truncated final lines, missing windows, stale snapshots, and invalid artifact
  metadata fail or report partial with a typed reason.

**Exit:** A fresh LLM can decide whether the evidence itself is complete
without reading source code or inferring state from file modification times.

### IC5-B - Observable macOS shortcut delivery

- [x] Record only reserved developer-shortcut candidates received by the
  focused Incinerator window: event time, window/focus, SDL event type,
  scancode, keycode, raw value, modifiers, repeat, and route decision.
- [x] Record `received`, `matched`, `queued`, and `applied` as distinct states
  linked to the created anomaly ID.
- [x] Show last candidate, route result, and the three counters in the Incident
  Capture window.
- [x] Keep F9/Fn+F9 as optional macOS convenience and make
  Command+Option+I the recommended non-function-row route.
- [x] Keep arbitrary text and non-reserved keyboard activity out of incident
  evidence.

**Focused gates**

- Synthetic SDL tests cover keycode, scancode, modifiers, repeat, key-up,
  focus, disabled recorder, queue saturation, and one-flag-per-press behavior.
- A real Apple Silicon macOS product window records a physical fallback key
  from `received` through `applied` and creates the expected anomaly.
- When F9 is consumed by macOS, the UI says no SDL event was observed rather
  than claiming a handler failure.

**Exit:** At least one documented non-function-row shortcut works from the
tester’s physical keyboard; button and shortcut produce the same typed request.

### IC5-C - Trailing visual evidence

- [x] Add the bounded 15 FPS product-only trailing lane and eight bounded
  human-visible anchors from -5 through +2 seconds.
- [x] Store target and actual time, tick, frame, source, drawable generation,
  fence timing, and digest for every frame.
- [x] Deduplicate frames shared by rapid or overlapping flags.
- [x] Add the stable diagnostic texture and preserve nonblocking fence polling.
- [x] Add the product-only flag image and semantic-ID flag artifact.
- [x] Add visual integrity warnings for all-zero, stale/repeated, truncated, or
  structurally suspicious captures without treating a warning as root cause.
- [x] Extend the Incident Capture tool with visual-window completion, gaps,
  memory, and writer status.

**Focused gates**

- A generated per-frame color/motion pattern proves ordering, orientation,
  channel conversion, resize generations, and absence of rectangular
  corruption.
- Pre-roll includes frames at least two seconds before the flag; continuous
  cadence gaps above the measured tolerance are explicit.
- Flag, +1, and +3 scheduling remains correct under 60, 80, 120, and 240 Hz
  presentation, minimize/restore, resize, rapid flags, and clean shutdown.
- Capture never waits for a GPU fence in the render loop and stays within the
  accepted memory/frame-time budget.

**Exit:** The anomaly directory can show a transient that occurred up to four
seconds before the tester reacted and can distinguish product-only content
from developer UI.

### IC5-D - Cross-boundary causal evidence

- [x] Build the incident entity projection from the union of authority,
  replication, presentation-plan, and draw-submission identities.
- [x] Replace boolean absence guesses with tri-state membership and five-second
  tombstones.
- [x] Emit typed relevance evaluation, inclusion, removal, baseline, and
  district lifecycle records.
- [x] Record draw submission and visibility evidence using stable entity plus
  incarnation identity.
- [x] Preserve interest-aware bounds; do not dump the complete physics or
  authority world every tick.
- [x] Teach the Gameplay Inspector and incident state windows the same terms so
  the live and persisted views agree.

**Focused gates**

- Scripted authority-present/replication-absent,
  replication-present/presentation-absent, and
  presentation-present/draw-absent cases remain distinguishable.
- An NPC relevance removal retains a searchable tombstone and typed cause.
- A remote graphical client reports authority membership as `unavailable`, not
  false.
- Capacity saturation and tombstone eviction are explicit and deterministic.

**Exit:** Disappearance can be assigned to authority, replication,
presentation planning, draw submission, or GPU visibility without relying on
an entity’s continued presence in a draw list.

### IC5-E - Replay, inspector, and LLM skill reliability

- [x] Replace the replay helper’s ad hoc output-drain list with one explicit
  replay-boundary operation that classifies every public output lane as
  digested, retained, or drained.
- [x] Include NPC encounter cues and run the current long accepted-ingress
  replay through encounter and streaming behavior without pending outputs.
- [x] Make the inspector validate visual timing/index integrity, materialized
  windows, semantic-ID mappings, current live health, replay cohort, and
  suspicious image warnings.
- [x] Add concise anomaly-relative tables and named diagnostic codes to the
  inspector output.
- [x] Add a repository-owned canonical source for the
  `incinerator-incident-diagnostics` skill, schema references, reproduction
  protocol, and summarizer; install/update the personal skill from that source.
- [x] Make the skill reduce lifecycle events correctly, treat running manifests
  as live partial evidence, validate actual image deltas, map named codes,
  identify boundary transitions, and keep semantic/graphical/human claims
  separate.

**Focused gates**

- The reference journey no longer fails with
  `NpcEncounterOutputsPending` when recorded under the current cohort.
- Adding or omitting a replay-visible output lane breaks a focused contract
  test instead of a later human replay.
- The repository skill summarizer and `inspect-incident` agree on lifecycle,
  loss, artifact count, image timing, and replay status.
- Original bundles are never mutated by inspection or reproduction.

**Exit:** A fresh agent can inspect, semantically replay, graphically
re-execute, and state the limits of a current bundle using repository-owned
instructions.

### IC5-F - Gameplay boundary repairs

#### District presentation pop

- [x] Add a sandbox-owned one-hop adjacent-district presentation prefetch
  policy. It may request/stage visual content before authority focus transfers,
  but it cannot activate logical collision or mutate authority.
- [x] Preserve explicit GPU, memory, request, cancellation, and residency
  budgets. Do not create a generalized world-streaming framework.
- [x] Keep mandatory collision proxies and authored scene residency separately
  observable.
- [x] Add a scripted west-to-east and east-to-west walk/drive journey with a
  camera-visible residency invariant.

**Acceptance:** Adjacent authored content is resident before it enters the
accepted camera visibility region; a failed/late request is visible as a typed
streaming fault rather than an unexplained block pop.

#### NPC relevance flash

- [x] Replace exact owner-district equality with one authority-owned NPC
  interest predicate.
- [x] Include same-district actors, nearby actors through a measured enter/exit
  distance hysteresis, and NPCs actively targeting or interacting with the
  participant.
- [x] Retain an included NPC until it leaves the larger exit radius and is no
  longer encounter-relevant for a bounded grace period.
- [x] Emit the evaluated reason and preserve explicit removals, baseline
  generation, entity count, byte, and cadence budgets.
- [x] Keep the current feature/session ownership; do not introduce a generic
  replication graph before population evidence requires it.

Starting values are a 20-metre proximity entry radius, 24-metre exit radius,
and 30-authority-tick exit grace. Acceptance measurements may tune them, but
the hysteresis and encounter-retention rules are contractual.

**Acceptance:** Repeated boundary traversal cannot remove a nearby or engaged
NPC; a genuinely distant, disengaged NPC leaves within the declared bound with
one typed removal and no permanent ghost.

#### Black capture decision gate

Compare product-only, human-visible, stable-texture, and semantic-ID evidence
before changing renderer behavior. If only a capture source is corrupt, repair
the adapter. If product and semantic evidence are also corrupt, open a focused
render-pass/load-store/draw-lifetime defect. Do not mask either case with image
post-processing.

**Exit:** Both reproduced gameplay defects have deterministic tests at their
owning boundary plus an ordinary installed Metal journey.

### IC5-G - Hardening and closeout

- [x] Add a long scripted human-style journey that walks, looks, carries,
  drops, enters/drives/exits, crosses both district boundaries, approaches and
  fights an NPC, dies, respawns, flags multiple anomalies, and creates a live
  handoff before shutdown.
- [x] Run the journey in normal, deterministic-fault, graphical replay, resize,
  minimize/restore, rapid-flag, queue-pressure, unwritable-root, disk-budget,
  screenshot-failure, and unclean-exit conditions.
- [x] Compare recorder disabled/enabled p50/p95/p99 frame behavior, memory,
  GPU capture latency, writer queue, artifact growth, and shutdown latency.
- [x] Run the inherited unit, headless, replay, architecture, source-package,
  and installed Metal gates.
- [ ] Generate a new human-flagged bundle for the two repaired journeys and
  inspect every typed and visual artifact.
- [x] Update ADR-021, the parent design, validation record, root plan, README,
  architecture findings, and repository skill only from measured results.

The normal, resize, rapid-overlapping-flag, real minimize/restore, semantic
replay, best-effort graphical replay, capture-on/off A/B, unusable-root, and
forced unclean-exit cases are complete. `zig build verify-incident-hardening`
also runs the full installed Metal gameplay journey under five explicit
developer-only profiles: queue pressure, a 16 MiB visual lane, a late writer
budget failure, screenshot submission failure, and post-submission fence
failure. Every profile completes the 2,148-tick accepted-ingress replay and
the strict inspector accepts its deliberately partial bundle. The writer case
arms only after anomaly materialization and replay: all four markers and replay
remain durable, `LLM_HANDOFF.md` is honestly absent, and the main-thread
clipboard publication still succeeds once. A real host-volume ENOSPC is not
manufactured because consuming the developer's filesystem is unsafe; the
writer-owned exact byte ceiling exercises the same fail-closed write boundary.

**Human checkpoint:** The tester confirms the physical shortcut, district
transition, NPC continuity, and usefulness of the trailing evidence. This is
the only required external checkpoint; all earlier work can proceed
autonomously.

**Exit:** IC5 is complete only when partial evidence is honest, both anomalies
remain repaired under long scripted and installed graphical execution, and a
new human bundle is sufficient for a fresh agent to reach the same conclusion.

### IC5-H - Bounded object continuity and evidence capability correction

The 2026-07-17 human bundle
`2026-07-17T14-15-26.910Z_solo_2d786ed4` exposed a third boundary defect. The
vehicle retained authority identity `{namespace=2, local=4294967313,
incarnation=1}` but exact observer/owner district equality omitted it from the
client projection. It entered presentation abruptly when the observer's
relevance district changed. The bundle was useful visually, but its entity
state and semantic map only covered characters and NPCs, so the vehicle cause
still required manual correlation across generic snapshots.

- [x] Project the complete current presentable vehicle and carryable cohort to
  every participant while the product budgets remain four of each.
- [x] Preserve occupied/held semantic reasons and add a typed `bounded_world`
  reason; retain `district_dormant` only for a carryable whose feature-owned
  presentation is actually inactive.
- [x] Record authority, replication, presentation, and draw membership plus
  baseline ID, snapshot sequence, observer/object transforms, districts, and
  stable replicated/persistent identity for vehicles and carryables.
- [x] Preserve typed tombstones for replication, relevance, authority, and
  presentation removal instead of turning absence into an unexplained gap.
- [x] Map one vehicle chassis and all four wheels to the same semantic entity
  identity while retaining distinct semantic object IDs.
- [x] Publish an honest manifest evidence-capability matrix. A current bundle
  fails inspection if the declared full-boundary/vehicle-parts/note-handoff
  cohort drifts; an older bundle is reported as capability-limited.
- [x] Add an immutable chronological visual contact-sheet report generated
  outside the original run folder, with every tile labeled by actual capture
  offset and presentation frame from `visual-index.ndjson`.
- [x] Make note persistence and Copy-for-LLM one ordered developer-host request
  so the copied handoff cannot race an unsaved note.
- [x] Correct accepted-ingress verification to compare the replayed projection
  at the client's recorded server tick rather than a newer authority frame.
- [x] Make real-GNS acceptance require the same vehicle and carryable identity
  across relevance transfer. NPC acceptance follows the current dynamic
  distance/encounter interest contract instead of a brittle exact count.

The bounded-world decision is deliberately small and explicit. It is not a
generic replication graph and does not add a spatial abstraction before scale
requires one. A future vehicle/carry interest policy must introduce measured
entry/exit hysteresis, semantic ownership retention, typed removal evidence,
and a no-pop graphical acceptance journey as one cohort. Exact coordinate
equality is not an acceptable replacement.

**Exit:** One stable vehicle and carryable identity remains continuously
present through the west/east observer relevance transfer in focused,
real-GNS, accepted-ingress replay, and installed Metal journeys; a fresh
schema-2 bundle declares and contains full vehicle/carry evidence.

### IC5-I - Budget-safe handoff and truthful playable boundaries

The 2026-07-18 human bundle
`2026-07-18T23-30-25.799Z_solo_c6b42031` reached 536,870,814 of its
536,870,912-byte run cap. Retina human-visible anchors and the product trail
consumed the budget until an unrelated 98-byte write failed. Anomaly #5 was
left incomplete, anomaly #6 existed only in memory, and the ordered handoff
never reached clipboard publication. The same run also exposed reversed wheel
spin, a user drop that silently returned the carryable to an earlier valid
pose, logical district visuals entering/leaving inside apparently playable
checkerboard space, and an intentionally timed NPC death proxy becoming an
unexplained absence before replacement.

- [x] Partition the run cap into a 384 MiB visual lane and 128 MiB nonvisual
  reserve; reserve visual bytes before enqueue and report visual exhaustion
  separately from writer failure.
- [x] Bound the product trail at 15 FPS and store
  human-visible anchors at no more than 1280x720 while indexing original and
  stored dimensions.
- [x] Publish the in-memory LLM handoff for main-thread clipboard use before
  its durable write and expose durable handoff state independently.
- [x] Correct the explicit engine/Jolt wheel angular-velocity and phase sign
  boundary and assert forward-drive wheel direction.
- [x] Add explicit `player_requested` and `forced_cleanup` drop purpose;
  rejected user placement remains held while teardown alone may use the last
  valid world pose. Advance accepted-ingress replay to cohort 11.
- [x] Pin both current route districts only in the ordinary two-district
  sandbox product; retain real streaming lifecycle in validation profiles.
- [x] Advance the canonical district recipe to version 4 with collision-backed
  perimeter walls just outside the authored route. This historical IC5-I
  implementation was rejected by the subsequent physical checkpoint and is
  superseded by recipe 5's open traversal in
  [`playable-boundary-and-vehicle-npc-collision-correction.md`](playable-boundary-and-vehicle-npc-collision-correction.md).
- [x] Retain the noninteractive NPC death proxy until replacement spawn and
  vitals registration complete, and name the pending interval in product
  feedback.
- [x] Keep the third-person follow camera on the target side of live world
  collision through a read-only value query; dominant solid-color captures
  are now integrity warnings instead of silently passing inspection.
- [x] Stop the human-style journey at a reachable, replacement-safe position
  instead of continuing to push into a blocker to manufacture occlusion.
- [x] Run the aggregate, S11, replay, interaction, physics, content, and
  installed Metal journey gates against this exact cohort.
- [ ] Obtain a fresh human pass for wheel motion, explicit rejected drop,
  route continuity, NPC death/replacement readability, and UI/shortcut copy.

The route pin is deliberately product-specific. It does not weaken the
streaming owner or introduce a speculative open-world policy. The death proxy
remains bounded by the fixed NPC population and is cleared by a transactional
replacement lifecycle rather than a presentation timer. The drop purpose is a
required command field, not a compatibility default.

**Exit:** visual saturation cannot disable notes/replay/handoff; all player
actions either commit where shown or visibly reject; current-route content does
not pop; wheel motion follows the engine coordinate convention; and NPC death
remains visually explained until its replacement is authoritative. Camera
obstruction and visual-integrity warnings prevent collision surfaces from
masquerading as a healthy diagnostic capture.

## Required Validation Matrix

| Layer | Required proof |
|---|---|
| Pure contracts | Schema reduction, time math, tri-state membership, tombstone eviction, relevance hysteresis |
| Recorder/writer | Live atomic manifests, rotation, budget, overlap deduplication, failure injection |
| Renderer-neutral | Frame scheduling, entity membership transitions, draw identity, semantic map |
| Headless authority | District journey, NPC boundary continuity, combat/death/replacement, long replay |
| Installed Metal | Stable capture texture, trailing ordering, resize/minimize, product versus human-visible images |
| Real macOS input | Focused physical fallback shortcut from SDL receipt through anomaly application |
| Reproduction | Same-cohort semantic match plus best-effort graphical re-execution |
| Human perception | New bundle and direct confirmation for the originally reported visual behavior |

No single row substitutes for another.

## Documentation And Skill Strategy

The durable ownership remains:

- ADR-021 records the accepted architectural decision and is amended only
  after measured implementation.
- The parent incident design records stable workflow, owners, and budgets.
- This document owns the corrective sequence and unchecked implementation
  ledger.
- The validation record owns commands, generated run IDs, measurements,
  failures, and phase acceptance.
- README owns short tester instructions and current physical shortcut.
- A repository-owned skill source owns fresh-context diagnostic procedure;
  the installed personal skill is a deployed copy, not the canonical source.

After every phase:

1. compare implementation with ADR-020, ADR-021, and this plan;
2. run the focused and inherited gates;
3. inspect one generated bundle manually and with the inspector/skill;
4. record measured budgets and failure cases in validation;
5. review ownership, privacy, dead code, compatibility leftovers, and doc
   drift; and
6. mark checkboxes only after evidence is linked.

## Explicit Non-Goals

- remote upload, analytics, dashboards, accounts, or public bug reporting;
- recording arbitrary keys, text entry, clipboard history, credentials, or
  out-of-window input;
- Linux, Windows, Steam Deck, or cross-GPU capture abstractions;
- deterministic macOS, Metal, scheduler, or public-network replay;
- a generalized render graph, replication graph, ECS mirror, or telemetry bus;
- indefinite video recording or an in-engine video editor;
- preserving schema-1 incident compatibility; and
- claiming that an incident bundle replaces a deterministic regression or
  human confirmation of visual readability.

## Definition Of Complete

- The live handoff describes current recorder health and exact durable ranges.
- A physical non-function-row macOS shortcut is observably received and
  applied; F9 failure is diagnosable.
- Trailing frames cover the human reaction window, and every visual artifact
  carries actual tick/frame/time/source metadata.
- Product-only, human-visible, and semantic evidence are distinguishable.
- Recently absent actors retain causal cross-boundary tombstones.
- Long semantic replay classifies every output lane and reaches encounter
  behavior without pending-output failure.
- The district scene is prefetched before becoming visibly relevant.
- Nearby or engaged NPCs remain continuously relevant across district edges.
- New scripted, Metal, replay, fault, and human evidence agree on both repairs.
- The repository documentation and skill explain the same current schema and
  never overstate what graphical reproduction proves.
