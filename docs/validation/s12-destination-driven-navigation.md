# S12 Destination-Driven Navigation Acceptance

**Status:** Accepted on Apple Silicon macOS; implementation, automated native
evidence, and the product-owner evaluation-world checkpoint are complete

**Recorded:** 2026-07-28

**Decision:** [ADR-023](../adr/023-semantic-destinations-and-navigation-recovery.md)

**Plan:** [S12 destination navigation](../design/s12-destination-driven-navigation.md)

**World:** [S12 evaluation world](../design/s12-navigation-evaluation-world.md)

**Performance:** [S12 baseline](../performance/s12-baseline.md)

## Accepted Implementation

S12 now provides:

- six stable content-fingerprinted semantic destinations;
- a canonical 16-node, 32-directed-edge weighted graph across two districts;
- one allocation-free deterministic Dijkstra planner with typed ready,
  waiting, blocked, unreachable, invalid, capacity, and budget results;
- NPC-owned durable destination intent, transient route lineage, an eight-query
  authority budget, generation/topology replans, and encounter return;
- collision-aware re-anchoring, goal-directed progress, bounded confirmed-edge
  exclusions, and zero healthy snap-back or teleport recovery;
- two authority-owned seam gates whose topology, collision, visuals,
  persistence, and replay state change together;
- installed low-poly west/east urban fixtures with visible collision proxies;
- selected-NPC route/status inspection, an independent navigation overlay, and
  a Navigation Lab window;
- transition-only schema-4 navigation incident evidence and strict tooling;
- explicit `full_world` NPC publication for the current bounded sandbox cohort,
  shared by solo, listen, and dedicated placements;
- snapshot 13, replay 14, protocol 14, content recipe 6, and configuration
  cohort 3 with no compatibility decoders; and
- shared solo/listen/dedicated, fault, reconnect, replay, restore, scale, and
  installed Metal acceptance.

## Automated Evidence

### Focused contract and authority gate

```sh
zig build test-s12-navigation test-s12-measure \
  -Deditor=false --summary all
```

Result: `104/104` build steps and `293/293` tests passed.

The focused suite includes deterministic planner tie-breaking and result
classes, route waiting/resume, topology reroute, physical displacement,
confirmed blockage, cold restore, semantic replay, gate persistence, content
admission, and a 64-request eight-per-tick budget wave. Real-Jolt integration
uses distinct safe anchors.

### Performance

```sh
zig build measure-s12 \
  -Deditor=false -Doptimize=ReleaseFast --summary all
```

Result: `59/59` steps passed. Planner p99 was `1.210 ms`; representative
six-NPC real-Jolt movement p99 was `0.076 ms`; teleport rollbacks were zero.
Exact values and methodology are in the
[performance record](../performance/s12-baseline.md).

### Installed Metal inheritance

```sh
zig build smoke-installed-s8-macos -Deditor=true --summary failures
zig build smoke-installed-s11-macos -Deditor=true --summary failures
```

Both 240 Hz and 80 Hz lanes pass on Metal. The S8 companion proves one semantic
destination lifecycle through content wait/resume, seam transfer, controller
suspension/resume, stable projection, despawn, and full GPU drain. The S11
companion proves contact, player death/respawn, NPC death, and semantic pixel
visibility in the richer collision scene.

The graphical audit corrected two stale validation assumptions:

1. normal product prefetch intentionally keeps both neighboring scenes warm,
   so validation now controls client prefetch and authority residency
   separately when proving east-district suspension; and
2. the inherited combat script now uses authority state for control and a
   clear south-route encounter lane, while product presentation is validated
   independently. It no longer steers through an authored blocker or makes
   render cadence part of authoritative test input.

### Aggregate release gate

```sh
zig build verify-s12 -Deditor=true --summary failures
```

Result: passed on native Apple Silicon macOS. This gate includes the focused
S12 contracts, source-package and headless lifecycle verification, inherited
S11 authority/network/process acceptance, S8 and S11 Metal journeys at 240 Hz
and 80 Hz, deterministic impairment profiles, and the complete incident
hardening matrix.

### Incident evidence

A fresh schema-4 installed run was inspected at:

```text
/tmp/incinerator-s12-schema4-20260728/2026-07-28T13-12-46.596Z_solo_cb60dbcb
```

Strict inspection reported a complete protocol-14/replay-14/snapshot-13
bundle with navigation-lineage capability, 427 stream records, 59 visuals,
navigation transitions/state/metrics, no suspicious records, and no evidence
loss. The repository and personal incident-diagnostics skills both accept
schema 4. Their shared summarizer is exercised against both this ordinary
bundle and a queue-pressure bundle, reports route lineage/status aggregates,
and both skill folders pass the skill validator.

The installed destructive matrix also passes all five profiles:
`queue_pressure`, `visual_budget`, `writer_budget`,
`screenshot_submission`, and `screenshot_fence`. Every profile completes the
full gameplay journey, passes strict profile-aware inspection, and semantically
replays.

This `/tmp` bundle is disposable automated evidence. The product-owner
checkpoint later completed without a new anomaly. The accepted workflow keeps
gate-replan and displacement/block evidence ready when a real symptom occurs;
it does not require manufactured incident flags during a clean run.

### Human incident: premature NPC projection removal

The preserved run
`/Users/matt/Library/Logs/Incinerator/runs/2026-07-28T15-04-08.142Z_solo_905c53ab`
is healthy schema-4 evidence: complete lifecycle, 100 visuals, zero suspicious
artifacts, zero writer/queue loss, strict inspection, and a matching 7,353-tick
semantic replay.

NPC persistent ID `1:7` remained alive and present in authority. At authority
tick 1,629 it changed from replicated/presented/drawn to excluded while roughly
29.5 m from the observer. The owning cause was the MP4-era 20 m enter, 24 m
retain, 30-tick grace interest policy—not navigation, camera, frustum, or draw
submission.

The correction makes NPC interest policy explicit in authority construction.
All current solo/listen/dedicated sandbox placements select `full_world`;
bounded hysteresis remains directly tested but opt-in. Incident state and the
Gameplay Inspector report `relevance_reason="full_world"` and retain measured
distance/district facts. Focused evidence after the correction:

```text
zig build test-session-contracts -Deditor=false --summary all
46/46 steps; 151/151 tests passed

zig build test-s12-navigation -Deditor=false --summary all
101/101 steps; 292/292 tests passed

zig build -Deditor=true --summary all
59/59 steps passed

zig build check-validation -Deditor=true --summary all
33/33 steps passed

zig build verify-s12 -Deditor=true -j1 --summary failures
passed, including all inherited headless, network-fault, source-package,
solo/listen/dedicated Metal, and five incident-hardening profiles
```

The deterministic regression proves both deliberate modes: explicitly bounded
interest retains its existing hysteresis behavior, while `full_world` includes
an NPC 14 km away with no grace deadline.

Best-effort graphical re-execution of the exact incident completed all 7,500
ticks and shut down cleanly. Its new unflagged run stream is:

```text
/Users/matt/Library/Logs/Incinerator/runs/2026-07-28T15-37-54.118Z_solo_4151f7da
```

Across 490 recorded NPC state samples—including and well beyond the original
tick-1,629 cutoff—the NPC remained authority-present, replicated, presented,
and drawn. Every sample reported `full_world`, zero samples reported
`excluded` or relevance removal, and the maximum observer distance was
67.9 m. This is presentation evidence, not a replacement for deterministic
semantic replay or the remaining human perception check.

## Remaining Human Acceptance

Run:

```sh
zig build run -Deditor=true
```

Then use the Navigation Lab and overlays to:

1. assign `market_terminal` and observe route plus arrival;
2. close North Gate during travel and observe a South Gate replan;
3. close both gates and confirm `blocked`, then reopen one and recover;
4. push the NPC with the vehicle and confirm retained identity/destination with
   no snap-back;
5. obstruct and clear a route, confirming physical-block evidence;
6. flag one topology anomaly and one displacement/block anomaly in Incident
   Capture; and
7. send both generated run-folder handoffs for strict inspection and replay.

The product owner accepted the ordinary evaluation-world result on 2026-08-17
after the prior continuity corrections. No new anomaly was observed, so the
checkpoint did not manufacture two incident flags merely to satisfy a count;
the already accepted schema-5 workflow remains the diagnostic path for any
future navigation anomaly.

## Review Result

No P0/P1 S12 defect remains. Ownership stays narrow: the sandbox
catalog owns destinations, district authority owns admitted topology and
gates, the pure planner owns no state, NPC authority owns movement and route
execution, and presentation/editor/incident consumers receive immutable
projections. No navmesh, crowd solver, behavior tree, scheduler, platform
abstraction, or compatibility layer was introduced.

The final aggregate audit also found and corrected one replay-boundary defect:
the consumable diagnostic navigation-transition FIFO had been included in the
authoritative NPC digest even though live session authority and direct replay
consume that evidence at different boundaries. Durable route state, lineage,
drop counters, and transition traces remain covered; FIFO occupancy is now
correctly diagnostic-only, with a focused digest regression.
