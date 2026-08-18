# Human-Test Incident Capture Validation Record

**Status:** Accepted for the Apple Silicon macOS solo developer product.
Schema-3 visual capture, IC5-A through IC5-I, long gameplay/replay, real window
lifecycle, capture-cost, five-profile deterministic failure hardening, fresh
human bundles, and the physical drop/district/NPC/vehicle checkpoint pass.

**Date:** 2026-07-19

**Decision:** [ADR-021](../adr/021-local-human-test-incident-bundles.md)

**Design:** [Human Test Incident Capture And LLM Diagnostic Handoff](../design/human-test-incident-capture.md)

**Corrective plan:**
[Incident Evidence Reliability And Boundary Corrections](../design/incident-evidence-reliability-and-boundary-corrections.md)

## Long human bundle findings

The ordinary-product run `2026-07-16T13-56-17.518Z_solo_b5942566` invalidated
several claims that the short smoke could not exercise:

- east-district presentation became resident roughly 1.6 seconds before the
  human flag, outside the retained -1/flag/+1 visual evidence;
- exact district-equality NPC relevance removed a nearby NPC at a boundary and
  restored it later;
- screenshot slots retained actual monotonic times but attachment discarded
  them, so nominal filenames and writer modification times could not prove
  capture time;
- some evidence images contained large black rectangular regions that the
  single swapchain-readback source could not classify as product or capture
  corruption;
- physical F9 and Command+Shift+9 delivery remained unobservable because smoke
  and unit tests injected SDL events after the OS boundary;
- entity-state samples originated from current draw lists and therefore could
  not retain a removed NPC's authority/replication/presentation membership;
- live Copy-for-LLM retained a startup manifest while streams continued
  growing; and
- complete semantic replay failed with `NpcEncounterOutputsPending` because
  the replay drain did not classify the NPC encounter cue lane.

Captured semantic input reproduced both the district transition and NPC
presentation removal in a fresh graphical re-execution. These results reopen
IC5; they do not revoke the narrower historical statement that IC0-IC4 v1
artifacts were created successfully.

## IC5-H vehicle continuity and evidence correction

The later human run
`2026-07-17T14-15-26.910Z_solo_2d786ed4` recorded “vehicle briefly was
invisible then visible.” Its product trail showed the abrupt entry, and the
typed streams proved the vehicle remained authoritative while the client
projection omitted it until the observer relevance district changed. The
original schema-2 capability set did not include full vehicle/carry state or
semantic vehicle parts, so the strict inspector now reports that preserved
bundle as capability-limited instead of claiming evidence it never captured.

The chronological report command was validated against the preserved bundle:

```sh
zig build incident-visual-report -- \
  /Users/matt/Library/Logs/Incinerator/runs/2026-07-17T14-15-26.910Z_solo_2d786ed4 \
  /tmp/incinerator-visual-report-validation-20260717a
```

It produced an 800×3848 PNG contact sheet and Markdown frame map outside the
original folder. Every tile uses the actual offset and presentation frame from
the visual index; manual inspection made the vehicle transition visible in one
chronological artifact.

The corrected installed Metal journey was:

```sh
INCINERATOR_INCIDENT_ROOT=/tmp/incinerator-vehicle-relevance-20260717a \
  zig build run -Deditor=true -- --incident-journey
```

It completed 2,166 authority ticks, four anomaly flags, carry/drop,
vehicle entry/drive/exit, both district transfers, player and NPC
death/replacement, and resize/restore. The run is:

```text
/tmp/incinerator-vehicle-relevance-20260717a/2026-07-17T19-11-28.247Z_solo_995ff5a7
```

The strict inspector reported four complete anomalies, 16 materialized
windows, 767 visual records, zero artifact failures, zero suspicious images,
zero warnings, writer high-water 157/1,024, durable sequence 1,126/1,126, and
421,574,086 bytes under the 536,870,912-byte budget. Its current manifest
declares full-boundary evidence for characters, NPCs, vehicles, and
carryables, semantic vehicle parts, and atomic note/handoff support.

Across 144 vehicle state samples from ticks 6 through 2,157, the same stable
vehicle identity remained authority/replication/presentation/draw present with
no removal. Its observer district covered both `(0,0)` and `(1,0)` while its
owner remained `(0,0)`; reasons were 132 `bounded_world` and 12 `controlled`.
The carryable likewise remained continuously present across 143 samples. Each
of the four semantic maps contains one chassis plus four wheel object IDs under
the same vehicle entity identity. There was one vehicle presentation spawn at
tick 6 and no vehicle presentation despawn.

Semantic accepted-ingress replay verified all 2,106 recorded ticks. A separate
best-effort graphical replay completed the current cohort through the final
recorded tick on SDL Metal without a presentation or renderer fault. This
separates deterministic authority evidence from graphical re-execution rather
than treating either as the human-perception claim.

The post-correction network and fault gate passed 87/87 steps and 154/154
tests. It includes clean, nominal, adverse, and blackout vehicle trials plus a
real-GNS two-client proof that the same vehicle and carryable identities remain
projected across relevance transfer. The broad editor-disabled regression
passed 255/255 steps and 922/922 tests; the focused developer-host gate passed
28/28 steps and 42/42 tests. Formatting, filtered-boundary checks, current
inspector validation, repository skill summarization, and Python report/script
compilation also pass.

## Delivered boundaries

- Heap-stable developer-host recorder with fixed typed requests and immutable
  inspector view.
- Single writer thread and 1,024-job queue; 4,096-byte record ceiling, 4 MiB
  stream rotation, a 384 MiB visual lane plus 128 MiB nonvisual reserve,
  explicit high-water/drop/failure state, atomic manifest/handoff/replay/marker
  updates, and 0700/0600 local paths.
- Event timeline, 4 Hz camera/entity state, semantic input, one-second runtime
  and visual metrics, reduced anomaly lifecycle, four materialized typed
  windows, editable notes, reserved shortcut-stage evidence, separate Incident
  Capture controls, main-thread clipboard, and Finder folder opening.
- Atomic live manifests expose current source/cohort, durable/admitted
  sequence, per-class bytes, queue, loss, writer, replay, and visual health.
- A 15 FPS 480x270 product-only trail from -5 through +2 seconds, UI-inclusive
  human-visible anchors at every whole second in that window stored at no more
  than 1280x720, a product-only flag frame, and 320x180
  semantic-ID frame/map use the exact shared frame-submission fence through
  nonblocking Metal polling and explicit
  partial-evidence paths. Source and stored dimensions are both indexed.
- Tri-state authority/replication/presentation/draw membership, five-second
  tombstones, stable incarnation identity, relevance facts, and shared
  Gameplay Inspector terms preserve causal evidence after an entity vanishes.
- Same-cohort active replay snapshot, standalone bundle inspector, semantic
  verifier with one explicit output-drain boundary, and best-effort graphical
  semantic-input re-execution.
- Authority-owned NPC interest uses 20 m enter, 24 m exit, encounter retention,
  and 30-tick grace. One-hop adjacent district visual prefetch is separate from
  authority/collision activation.
- Debug defaults on; validation and non-Debug builds default off unless
  explicitly enabled. No upload, global input, text, credentials, or signed
  network material.
- Removed the giant `GAMEPLAY_TRACE_JSON` terminal/UI compatibility path.

## Schema-2 installed Metal evidence

The corrective installed-product command was:

```sh
INCINERATOR_INCIDENT_ROOT=/tmp/incinerator-ic5-smoke-20260716-1 \
  zig build run -- --incident-smoke
```

It completed on SDL Metal and produced:

```text
/tmp/incinerator-ic5-smoke-20260716-1/2026-07-16T15-13-50.401Z_solo_cc1274b8
```

The strict schema-2 inspector reported a complete manifest, four stream
segments, 289 records, one complete anomaly, all four materialized windows,
134 visual artifacts, zero suspicious images, zero warnings, queue high-water
57/1,024, durable sequence 159/159, and 105,640,772 bytes under the 512 MiB
run budget. The repository skill summarizer independently reduced the same
lifecycle and counted five human-visible anchors, 127 shared product-trail
frames, one product-only flag frame, and one semantic-ID frame.

The actual visual span was -1,928 through +3,000 ms. The smoke flags about two
seconds after process start, so schema 2 correctly reports the unavailable
earlier portion instead of manufacturing a four-second pre-roll. Manual image
inspection found no large black capture rectangle. Product-only and
human-visible sources differed as designed, and the semantic map identified
the local player and NPC using stable identity/color entries.

The log showed both adjacent district scenes staged and GPU-resident before
logical focus movement. Semantic replay verified all 480 recorded ticks after
the explicit replay boundary began draining NPC encounter cues, and graphical
re-execution completed through tick 549:

```sh
zig build inspect-incident -- /tmp/incinerator-ic5-smoke-20260716-1/2026-07-16T15-13-50.401Z_solo_cc1274b8
zig build replay-incident -- /tmp/incinerator-ic5-smoke-20260716-1/2026-07-16T15-13-50.401Z_solo_cc1274b8 /Users/matt/repos/incinerator-engine/zig-out/share/incinerator/content
zig build run -- --replay-incident=/tmp/incinerator-ic5-smoke-20260716-1/2026-07-16T15-13-50.401Z_solo_cc1274b8
```

The first corrective Metal attempt also caught two defects missed by
renderer-neutral tests: direct sampling of an SDL swapchain texture violated
its usage contract, and the authority bootstrap projected NPC relevance before
a participant avatar position existed. The stable intermediate texture and
optional observer bootstrap are the resulting repairs. A later transition
found mutation-order sensitivity in district state; that path is now ordered
and covered by the installed run.

After semantic-fence failure accounting was made explicit, a final installed
run at
`/tmp/incinerator-ic5-final-20260716-2/2026-07-16T15-28-56.630Z_solo_8d1279bd`
again completed normally: 287 records, four windows, 137 visuals, zero artifact
failures, zero suspicious images, zero inspector warnings, queue high-water
54/1,024, and durable sequence 158/158. Both districts staged and became GPU
resident before movement, and replay verified all 480 ticks. This pass also
caught and corrected one handoff instruction: the replay content-root argument
must be absolute, matching the existing content-root contract.

The final filtered-source audit then found a real cold-product cohort drift:
the manifests, replay, configs, and graphical streamer had advanced the
district recipe to 3, while `headless_content` still admitted only recipe 2.
The validator now imports the sandbox recipe owner instead of duplicating that
number; it remains fail-closed and adds no legacy admission. The exact
`-Dproduct=headless test-m3-lifecycle` gate again passes 10/10 steps, including
startup, restart, recovery, hostile input/storage, SIGTERM/SIGINT, and hard
lag. The final filtered package includes the canonical diagnostic skill and
passes 182/182 broad steps with 409/409 tests plus 32/32 cold-product steps
with 62/62 tests.

## IC5-G long journey and replay cohort 10

The normal installed Metal journey is now an explicit product mode:

```sh
INCINERATOR_INCIDENT_ROOT=/tmp/incinerator-ic5-journey-20260716-19 \
  zig build run -Deditor=true -- --incident-journey
```

It drives the ordinary input latch and authority boundaries through carry and
drop, vehicle approach/entry/drive/exit, west-to-east and east-to-west district
travel, resize and restoration, player death/cooldown/respawn, NPC approach and
melee, NPC death, occluded safe replacement, four anomaly flags including two
rapid overlapping flags, live handoff, and replay attachment. The final run is:

```text
/tmp/incinerator-ic5-journey-20260716-19/2026-07-16T16-30-34.767Z_solo_e40e95bd
```

The strict inspector reported four complete anomaly lifecycles, 16 materialized
typed windows, 682 visual records, zero artifact failures, zero suspicious
images, zero warnings, queue high-water 175/1,024, durable sequence 826/826,
and 398,667,148 bytes under the 536,870,912-byte run budget. The manifest
correctly identifies replay cohort 10. The repository skill summarizer agreed
on lifecycle, health, five human anchors per anomaly, product/semantic sources,
actual visual spans, replay, and handoff.

The first full combat replay exposed a real boundary omission at tick 1500:
authority-owned NPC replacement schedule/defer/complete operations changed the
`npc_encounter` digest but were absent from normalized replay ingress. The
repair advances replay cohort 10 and records those bounded operations with
stable slot, generation, death tick, and candidate nodes. The final semantic
verification matches all 2,106 recorded ticks:

```sh
zig build replay-incident -- \
  /tmp/incinerator-ic5-journey-20260716-19/2026-07-16T16-30-34.767Z_solo_e40e95bd \
  /Users/matt/repos/incinerator-engine/zig-out/share/incinerator/content
```

Best-effort graphical re-execution of the same cohort from
`/tmp/incinerator-ic5-journey-20260716-13/2026-07-16T16-03-31.862Z_solo_d5f5ebb5`
completed through tick 2,169. This is Metal/presentation workflow evidence,
not a deterministic graphical claim.

The separate installed window-pressure journey:

```sh
INCINERATOR_INCIDENT_ROOT=/tmp/incinerator-ic5-journey-window-20260716-18 \
  zig build run -Deditor=true -- --incident-journey-window
```

observed both the requested SDL minimized and restored events, completed the
same 2,166-tick gameplay journey, and produced four complete anomalies, 16
typed windows, 686 visuals, zero suspicious images/warnings, a drained
147/1,024 writer high-water, and a matching 2,106-tick semantic replay.

## IC5-G paired capture-cost measurement

The installed product now owns a bounded measurement mode rather than relying
on periodic FPS text:

```sh
INCINERATOR_INCIDENT_ROOT=/tmp/incinerator-ic5-benchmark-enabled-v2 \
  zig build run -Deditor=true -- --incident-benchmark
zig build run -Deditor=true -Dincident-capture=false -- --incident-benchmark
```

Both runs use 300 warm-up frames followed by 2,400 real Metal frames. The
2026-07-16 foreground pair measured:

| Capture | p50 | p95 | p99 | Shutdown | Bounded downloads | Queue / loss |
|---|---:|---:|---:|---:|---:|---:|
| off | 8.341 ms | 9.096 ms | 9.562 ms | 10.985 ms | 0 | 0 / 0 |
| on | 8.327 ms | 9.311 ms | 9.707 ms | 28.296 ms | 121,190,400 bytes | 8 / 0 |

Capture-on completed 589/589 trail and 23/23 anchor fences with zero
screenshot misses. Mean/max observed fence latency was 8.279/15.704 ms; the
unflagged benchmark wrote 229,667 bytes of typed metadata and streams. The
paired p95 and p99 deltas were approximately +2.36% and +1.52%. This is one
controlled local pair, not a universal hardware claim.

The first benchmark exposed 239,155,200 bytes of Retina download buffers,
which violated the declared 128 MiB live bound. Four 1 Hz source slots own
human/UI context while the product lane owns transient continuity. A fresh flag
smoke at 2560x1440 retained all five requested anchors at actual -1928, -925,
+75, +1000, and +3008 ms with zero warnings. IC5-I subsequently reduced the
product lane from 30 to 15 FPS and bounds stored human anchors at 1280x720 to
protect the total-run evidence partition; that later cohort requires its own
fresh installed evidence below.

## IC5-G unclean-exit and unusable-root evidence

The installed product was terminated with `SIGKILL` after anomaly #1 was
flagged but before its post-roll finalized. The surviving run is:

```text
/tmp/incinerator-ic5-unclean-v3/2026-07-16T16-39-42.972Z_solo_487c2341
```

The atomic manifest remained valid with `status=running`, durable/admitted
sequence 115/115, no loss, and 105,384,788 classified bytes. This test exposed
that both diagnostic consumers treated the legitimately absent, not-yet-
materialized `marker.json` as fatal. The inspector and repository/personal
skill now reduce that case as `lifecycle=capturing`, `marker=pending`, and
`live partial-in-time`; the inspector reports two warnings, zero windows,
and no replay/handoff without a stack trace or invented completion claim.

An installed smoke with `INCINERATOR_INCIDENT_ROOT=/dev/null/incinerator-runs`
reported `Incident capture unavailable: NotDir`, exposed no shortcut controls,
and failed the requested incident acceptance at tick 120 rather than silently
writing elsewhere. The pure unusable-root and exact run-budget contracts remain
the deterministic coverage for those failure boundaries.

The post-repair aggregates pass 258/258 steps and 915/915 tests with the editor,
255/255 steps and 915/915 tests without it, and 182/182 extracted-source steps
with 409/409 tests plus the independent 32/32 cold-product gate with 62/62
tests. Focused coverage now includes canonical replacement command encoding,
capture/replay of replacement ingress, queue saturation, unusable roots, and
fail-closed exact run-budget admission including an oversized first write.

## Real graphical workflow evidence

The rendered acceptance command was:

```sh
INCINERATOR_INCIDENT_ROOT=/tmp/incinerator-incident-final \
  zig build run -- --incident-smoke
```

It rendered the normal Metal sandbox, flagged anomaly #1 at authority tick 120,
continued through post-roll, attached replay at tick 480, and shut down at tick
540. The generated bundle was:

```text
/tmp/incinerator-incident-final/2026-07-16T04-42-21.990Z_solo_8a4d7d6d
```

Observed bundle evidence:

- complete Zig 0.16.0 Debug manifest; 8.15 MiB recorded;
- queue high-water 10/1,024, zero dropped records;
- 151 validated NDJSON records in four streams;
- anomaly marker and a 20-second materialized state window;
- three 1280×720 real-swapchain P6 images, screenshot mask 7;
- accepted-ingress replay attached; and
- concise `LLM_HANDOFF.md` attached.

The first live implementation attempt found two defects that narrower tests had
not exercised: an invalid actor JSON projection and an inferred one-bit integer
overflow at the cold capture boundary. The first replay attempt then diverged
at tick 11 in `npc_encounter` because vitals commands were absent from the
canonical replay ingress. Replay cohort 9 now records/validates/encodes those
commands. The repaired bundle verifies all 480 recorded ticks:

```sh
zig build inspect-incident -- /tmp/incinerator-incident-final/2026-07-16T04-42-21.990Z_solo_8a4d7d6d
zig build replay-incident -- /tmp/incinerator-incident-final/2026-07-16T04-42-21.990Z_solo_8a4d7d6d /Users/matt/repos/incinerator-engine/zig-out/share/incinerator/content
```

The best-effort graphical path also completed through tick 543:

```sh
INCINERATOR_INCIDENT_ROOT=/tmp/incinerator-graphical-replay-runs \
  zig build run -- --replay-incident=/tmp/incinerator-incident-final/2026-07-16T04-42-21.990Z_solo_8a4d7d6d
```

## Measured v1 budgets

- Eight 1280×720 RGBA download slots reserve 29,491,200 bytes. This scales with
  drawable resolution and is exposed in `screenshot_metrics`.
- The final screenshot metric reported 33 submitted/completed captures, three
  attached anomaly images, zero misses, and zero fence failures.
- Three PPM evidence images consume about 7.9 MiB at 1280×720.
- The deliberately unpaced rendered smoke remained above 1,000 FPS with
  roughly 0.8–1.6 ms observed frame times and zero screenshot/queue loss. This
  exercises capture progress under high frame pressure; it is acceptance
  evidence, not a controlled p95/p99 A/B benchmark.
- State capture is interest-bounded by the Gameplay Inspector projection and
  sampled at 4 Hz; it is not a complete per-tick physics-world dump.

## Automated gates

```sh
zig build test-replay --summary all
zig build -Deditor=true --summary all
zig build test -Deditor=false --summary all
zig build inspect-incident -- <run-folder>
zig build replay-incident -- <run-folder> <absolute-content-root>
```

Unit coverage includes bounded request/queue rejection, path-safe UTC identity,
JSON escaping/timestamp extraction, unusable-root rejection, product-mode
parsing, explicit captured-input edge preservation, replay v11 round trips/integrity,
and inherited architecture/source/binary gates.

After schema-2 capture, relevance, prefetch, replay-boundary, semantic-ID,
shortcut, long-journey, and replacement-ingress coverage landed, the
editor-enabled aggregate passed 258/258 build steps and 915/915 tests. The
editor-disabled aggregate passed 255/255 build steps and 915/915 tests. Both
include architecture, installed-content, headless-product, source-boundary,
and exact dependency-cohort gates.

## Shortcut and tool separation correction

The 2026-07-16 corrective smoke routes its anomaly through the actual SDL
developer shortcut handler rather than calling the recorder directly. It
registered the standalone `Incident Capture` tool, queued one physical/virtual
F9 event, showed the always-visible post-roll confirmation, and produced:

```text
/tmp/incinerator-hotkey-window-ui/2026-07-16T13-45-07.194Z_solo_e83fe04c
```

`inspect-incident` found anomaly #1 at tick 120/frame 191, all three
screenshots, an attached replay and handoff, queue high-water 9/1,024, and zero
drops. Event-level tests cover SDL scancode F9, keycode F9, Command+Shift+9,
modifier rejection, and key-up rejection. Schema 2 adds Command+Option+I as the
recommended route and tests keycode, scancode, fields, focus, disabled state,
repeat, key-up, one-request-per-press, and bounded queue saturation. Synthetic
events prove routing. Human testing accepts the visible Incident Capture
window and Copy-for-LLM workflow as the primary path; Command+Option+I is the
recommended convenience shortcut and the UI remains the explicit fallback.

## IC5-I budget and playable-boundary correction

The human run
`/Users/matt/Library/Logs/Incinerator/runs/2026-07-18T23-30-25.799Z_solo_c6b42031`
stopped at 536,870,814 of 536,870,912 bytes. Only 98 bytes remained when the
writer faulted: anomaly #5 was incomplete, anomaly #6 remained memory-only,
and the pre-write ordered handoff never reached clipboard publication. Visual
evidence accounted for 525,063,676 bytes. This was a recorder priority defect,
not an SDL clipboard diagnosis.

The same run correlated four product defects with authoritative evidence:

- all four Jolt wheel angular velocities had the opposite sign from the
  engine's right-handed +X wheel model during forward drive;
- player-requested drop outside active district ownership returned the item to
  an earlier pose instead of rejecting and retaining it;
- logical route districts activated/deactivated while an infinite diagnostic
  checkerboard made their unsupported exterior appear playable; and
- the NPC death proxy expired after 90 ticks, leaving an empty replacement
  delay/retry interval.

The corrective cohort adds visual-budget admission and a protected nonvisual
reserve, immediate in-memory handoff publication plus separately observed
durability, 15 FPS/64-slot product capture, bounded stored human anchors,
explicit wheel sign conversion, required drop purpose/replay cohort 11,
ordinary-product two-route residency with recipe-4 perimeter collision, and a
death proxy cleared only after replacement spawn plus vitals registration.

Focused gates completed before the aggregate pass:

| Gate | Result |
|---|---|
| Developer-host incident contracts | 45/45 tests passed |
| Physics | 44/44 tests passed, including forward wheel direction |
| Interaction feature | 15/15 tests passed, including requested rejection and forced cleanup |
| Accepted-ingress replay | 20/20 tests passed for cohort 11 |
| District streaming host | 37/37 tests passed with normal-product pin isolated from validation profiles |
| Sandbox navigation | 1/1 test passed against recipe 4 |
| Session contracts | 151/151 tests passed after placing the perimeter outside existing spawn/vehicle candidates |
| Product NPC encounter host | 1/1 test passed with replacement-owned proxy retirement |
| Default editor build graph | 53/53 steps passed |

Aggregate, S11, installed Metal journey, fresh-bundle inspection, and direct
human visual acceptance are recorded after they run; focused success does not
substitute for them.

The completed correction then passed the broad editor-disabled graph at
255/255 steps with 932/932 tests, the inherited MP4 network/fault matrix at
83/83 steps with 154/154 tests, and the full S11 source/package, solo, listen,
dedicated, fault, replay, reconnect, player lifecycle, NPC replacement, and
headless matrix at 182/182 steps with 249/249 outer tests. Its extracted broad
and cold subgates additionally passed 182/182 with 410/410 tests and 32/32 with
62/62 tests. The editor-enabled install graph passed 53/53 steps.

The final ordinary-product Metal journey used:

```sh
INCINERATOR_INCIDENT_ROOT=/tmp/incinerator-ic5i-final-v3 \
  zig build run -Deditor=true -- --incident-journey
```

It completed carry/drop, vehicle entry/drive/exit, both route crossings,
player death/respawn, NPC death/transactional replacement, resize/restore,
four overlapping anomaly lifecycles, handoff, and replay in:

```text
/tmp/incinerator-ic5i-final-v3/2026-07-19T01-13-27.875Z_solo_4b1a019d
```

The strict inspector and repository skill independently report four complete
anomalies, 16 materialized windows, 403 visuals, zero suspicious frames, zero
artifact failures, zero screenshot misses, zero dropped records, writer queue
high-water 41/1,024, durable sequence 1,148/1,148, and 159,492,640 bytes under
the 512 MiB cap. The visual lane reserved 155,926,784 of 402,653,184 bytes;
replay and handoff are present and the handoff is durable. Semantic replay
matches all 2,148 accepted-ingress ticks.

Visual review of the first corrected journey found a genuine secondary issue:
collision-backed perimeter walls could sit between the third-person camera and
its target, while the integrity heuristic recognized only black corruption.
The final cohort keeps the camera on the target side of live collision and
marks a frame suspicious when one quantized nonzero color occupies at least
75 percent of it. That stricter check then exposed a validation-script flaw:
after NPC death the script continued pushing into a blocker to force an
occluded replacement. The journey now stops at a reachable, policy-valid
point. A fresh chronological report is readable and the final run has zero
visual-integrity warnings.

## IC5-G deterministic failure-hardening matrix

The installed debug product now owns one explicit gate:

```sh
zig build verify-incident-hardening -Deditor=true --summary all
```

The 2026-07-18 gate passed 49/49 build steps and ran the complete gameplay
journey once under each developer-only failure profile. Every run reached all
four flags, finalized 16 typed windows, published clipboard text exactly once,
and semantically replayed all 2,148 accepted-ingress ticks. The strict
inspector required `status=partial` and validated the loss expected for that
specific manifest profile.

| Profile | Measured result | Durable outcome |
|---|---|---|
| `queue_pressure` | high-water 1,024/1,024; one rejected probe; 380 visuals | replay and handoff persisted; writer recovered |
| `visual_budget` | 16,633,600/16,777,216 bytes reserved; 354 visual rejections; 25 visuals | nonvisual replay, windows, and handoff persisted |
| `writer_budget` | late writer failure; 379 visuals; durable sequence 1,101/1,125 | four markers/windows and replay persisted; handoff file absent; clipboard succeeded |
| `screenshot_submission` | 8,821 misses; zero fence failures; four semantic visuals | typed evidence, replay, and handoff persisted |
| `screenshot_fence` | 567 misses; 555 injected fence failures; four semantic visuals | typed evidence, replay, and handoff persisted |

Evidence is retained under `/tmp/incinerator-ic5g-final`. A real host-volume
ENOSPC was deliberately not manufactured; the writer-owned byte ceiling
injects the same fail-closed write result without consuming or mounting an
unsafe filesystem. The implementation also changed final run status so any
writer failure, queue loss, screenshot miss, or visual-lane exhaustion is
reported as `partial` rather than allowing a healthy-looking `complete` run.
A fault-free companion run under `/tmp/incinerator-ic5g-normal-final` remains
`complete`: four complete anomalies, 16 windows, 402 visuals, zero suspicious
frames/loss/failures, durable replay and handoff, and a matching 2,148-tick
semantic replay.

After the hardening changes, the full editor-disabled repository graph passed
255/255 steps with 932/932 tests. The filtered source-package gate included
the new runner, rebuilt the extracted tree, and passed its 182/182-step,
410/410-test broad graph plus the 32/32-step, 62/62-test cold graph. This keeps
the hardening workflow usable from the distributed source package rather than
only from this checkout.

## Schema-3 -5/+2 visual-window amendment

The 2026-07-19 visual contract intentionally advances the incident schema to
3. The 15 FPS product-only ring now uses 80 slots for five seconds before
through two seconds after a flag. Eight UI-inclusive anchors are required at
every whole second from -5 through +2. Seven history-only one-Hz slots retain
six completed frames while one may be in flight; two separate event slots
capture flag frames without allowing rapid incidents to consume history. The
combined 2560x1440 download allocation remains below 176 MiB.

The first Metal trial caught history slots being reused by scheduled flag/post
captures: a later rapid incident had only 2.46 seconds of UI prehistory. The
accepted design separates those owners and delays +1/+2 selection by half a
capture interval so the nearest completed one-Hz frame is chosen. The final
installed journey is:

```text
/tmp/incinerator-schema3-visual-window-v3-20260719/
  2026-07-19T16-53-46.113Z_solo_aaa71ff2
```

It completed 2,214 gameplay ticks with four complete anomalies, 16 typed
windows, 387 visuals, eight human-visible anchors per anomaly, zero suspicious
images, misses, drops, writer failures, or budget rejections, durable replay
and handoff, and queue high-water 55/1,024. The three mature/overlapping
incidents retained distinct UI frames spanning approximately -5.205 through
+2.309 seconds; the startup incident truthfully had only the history available
since process launch. The strict inspector and repository skill accepted the
bundle, and semantic replay matched all 2,154 attached ticks.

The complete five-profile installed Metal failure matrix then passed 49/49
steps under schema 3. Queue, visual-budget, writer-budget, screenshot
submission, and fence failures each retained their expected honest partial
contract.

The final editor-disabled repository graph passed 255/255 steps with 934/934
tests. The extracted source-package gate passed its 182/182-step, 410/410-test
broad graph and its 32/32-step, 62/62-test cold graph, confirming that schema 3
and its diagnostics remain reproducible outside this checkout.

## Physical-checkpoint perimeter and vehicle–NPC correction

The 2026-07-19 human bundle
`2026-07-19T17-40-08.000Z_solo_9b38ce58` captured a cornflower fault frame
after sustained vehicle contact with the NPC. The strict inspector accepted the
complete run and honest partial anomaly: 4,240 records, 23 segments, 60 visuals,
zero recorder loss/failure/warnings, and a generic fatal runtime diagnostic at
committed tick 2,381. Authority state immediately before failure placed the
eastbound vehicle and NPC at the `x=8` district seam. Code-level reproduction
then failed deterministically in `npc.publish_and_transfer` with
`NpcUnexpectedOwnerTransfer`.

The correction deliberately supersedes recipe 4's perimeter strategy. Recipe
5 retains the support surfaces and two real obstacles but removes all four
containment planes from collision and proxy presentation. Ordinary product
residency remains pinned for the two currently authored districts; traversal
is not used to hide finite content or relevance behavior.

NPC publish now treats physical position as spatial ownership and the route as
rebuildable intent. A displaced live controller rebinds to the positional
owner's current ticket, rebases base and encounter routes from the nearest
active owner node, and emits one typed transfer. Inactive/unavailable
destinations relocate to the last owner-valid pose; a blocked relocation
suspends and reconstructs only that NPC on the next reconciliation tick.

Incident capture now emits immutable `runtime_fault` and
`authority_cycle_fault` timeline records containing exact phase/stage,
system/error name, error code, and tick ownership. The inspector, repository
diagnostic skill, schema reference, and LLM handoff search hints consume those
records. The old source bundle cannot acquire evidence it never recorded, but
a future equivalent fault will identify the responsible system directly.

Focused automated results are recorded in
[the correction plan](../design/playable-boundary-and-vehicle-npc-collision-correction.md).
The full editor-disabled graph passes 255/255 steps with 942/942 tests. The
extracted package passes 182/182 broad steps with 414/414 tests and 32/32 cold
steps with 62/62 tests. The installed S4 Metal fault gate passes 59/59 steps
after its validation accepted exact one-or-two-scene accounting for the
intentional adjacent visual prefetch while still requiring one authoritative
district.

The installed recipe-5 product journey completed 2,209 authority ticks and
semantic replay matched all 2,149 captured ticks. The strict inspector accepted
four complete anomalies, 16 typed windows, 387 visuals, zero recorder loss,
and durable replay/handoff. It also truthfully reported 207 suspicious
dominant-green frames during scripted close-range NPC combat. That is a dynamic
camera-occlusion warning rather than the original cornflower fault frame, so
the automated heuristic alone was not used as visual acceptance. The
subsequent targeted human pass confirmed open traversal and sustained
vehicle/NPC contact without a retained fault or entity discontinuity.

## Explicit remaining limits

- Command+Option+I remains a convenience path rather than the sole admission
  path. Its SDL routing is automated; the visible Incident Capture UI is the
  accepted human fallback. F9/Fn+F9 remains optional and may be consumed by
  macOS.
- Current human workflow acceptance is solo macOS. Listen/dedicated bundle
  parent/child orchestration is deferred with those human-test products.
- Capture-on/off performance, real minimized-window automation, unusable-root,
  forced unclean-exit behavior, queue/visual/writer pressure, and explicit GPU
  submission/fence failures pass.
- The full west-to-east/east-to-west scripted walk/drive journey and direct
  human continuity checkpoint pass.
- The full evidence-truth, trailing visual, shortcut delivery, causal
  membership, replay, skill, and anomaly-specific repair sequence is now owned
  by the corrective plan; none is accepted from documentation alone.
