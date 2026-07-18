# Human-Test Incident Capture Validation Record

**Status:** Schema-2 IC5-A through IC5-F and the IC5-H bounded-object evidence
correction plus the IC5-G long gameplay/replay, real window lifecycle, and
capture-cost gates are validated for the Apple Silicon macOS solo developer
product. Controlled destructive/failure hardening and the physical
shortcut/district/NPC/vehicle human checkpoint remain open in the
[corrective implementation plan](../design/incident-evidence-reliability-and-boundary-corrections.md)

**Date:** 2026-07-17

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
- Single writer thread and 1,024-job queue; 2,048-byte record ceiling, 4 MiB
  stream rotation, 512 MiB total run budget, explicit high-water/drop/failure state,
  atomic manifest/handoff/replay/marker updates, and 0700/0600 local paths.
- Event timeline, 4 Hz camera/entity state, semantic input, one-second runtime
  and visual metrics, reduced anomaly lifecycle, four materialized typed
  windows, editable notes, reserved shortcut-stage evidence, separate Incident
  Capture controls, main-thread clipboard, and Finder folder opening.
- Atomic live manifests expose current source/cohort, durable/admitted
  sequence, per-class bytes, queue, loss, writer, replay, and visual health.
- A 30 FPS 480x270 product-only trail, full-resolution -2/-1/0/+1/+3
  human-visible anchors, product-only flag frame, and 320x180 semantic-ID
  frame/map use nonblocking Metal fences and explicit partial-evidence paths.
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
which violated the declared 128 MiB bound. Four 1 Hz full-drawable slots now
own human/UI context while the existing 30 Hz product lane owns transient
continuity. A fresh flag smoke at 2560x1440 retained all five requested anchors
at actual -1928, -925, +75, +1000, and +3008 ms with zero warnings; the final
full journey above validates the same bounded policy.

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
parsing, explicit captured-input edge preservation, replay v10 round trips/integrity,
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
events prove routing only; the physical macOS gate remains open.

## Explicit remaining limits

- Command+Option+I still requires one focused physical macOS run from SDL
  receipt through applied anomaly ID. F9/Fn+F9 remains optional and is expected
  to be absent when macOS consumes the function row.
- Current human workflow acceptance is solo macOS. Listen/dedicated bundle
  parent/child orchestration is deferred with those human-test products.
- Long-run retention cleanup, deterministic fault, forced disk-full,
  rapid-flag GPU saturation, and explicit screenshot-failure remain hardening
  gates before calling IC5 fully closed. Capture-on/off performance, real
  minimized-window automation, unusable-root, and forced unclean-exit behavior
  now pass.
- The full west-to-east/east-to-west scripted walk/drive journey now passes;
  direct human continuity confirmation remains open.
- The full evidence-truth, trailing visual, shortcut delivery, causal
  membership, replay, skill, and anomaly-specific repair sequence is now owned
  by the corrective plan; none is accepted from documentation alone.
