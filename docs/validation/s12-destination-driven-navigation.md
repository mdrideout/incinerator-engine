# S12 Destination-Driven Navigation Acceptance

**Status:** Implementation and automated acceptance complete on Apple Silicon
macOS; final human evaluation-world walkthrough and two human-flagged incident
captures remain pending

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

This `/tmp` bundle is disposable automated evidence. S12 final human acceptance
still requires two preserved ordinary run folders: one flagged during a gate
topology replan and one flagged during physical displacement/block recovery.

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

S12 is not marked fully human-accepted until that walkthrough is completed.

## Review Result

No automated P0/P1 S12 defect remains. Ownership stays narrow: the sandbox
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
