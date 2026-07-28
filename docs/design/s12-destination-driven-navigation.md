# S12 Destination-Driven Navigation And Recovery

**Status:** Implemented; automated acceptance complete, final human
evaluation-world walkthrough and two preserved incident captures pending

**Date:** 2026-07-27

**Platform:** Apple Silicon macOS only

**Decision:**
[`../adr/023-semantic-destinations-and-navigation-recovery.md`](../adr/023-semantic-destinations-and-navigation-recovery.md)

**Evaluation world:**
[`s12-navigation-evaluation-world.md`](s12-navigation-evaluation-world.md)

**Prerequisites:** Accepted S8 navigation/population, S11 encounter behavior,
IV0-IV5 interaction validation, IC0-IC5 incident evidence, and the open-world
spatial correction

## Outcome

Deliver one playable NPC journey in which authority retains a named
destination while routes are derived, invalidated, and rebuilt around:

- a branched two-district graph;
- district activation and generation changes;
- an authored traversal-gate topology revision;
- physical vehicle/carryable obstruction;
- external vehicle displacement;
- encounter interruption and return;
- save/restore, replay, reconnect, and network impairment; and
- installed Metal presentation plus human incident capture.

The player or tester must be able to answer:

```text
Where is this NPC trying to go?
Which route did it choose?
Why did that route change?
Is it waiting, physically blocked, or truly unreachable?
What exact authority evidence proves that classification?
```

S12 is not complete merely because an NPC eventually reaches a point.

## Historical Entry Baseline

The pre-S12 architecture provided a strong starting point:

- `DistrictFeature` owns active graph fragments and exact load tickets.
- `NpcFeature` owns identity, controller, goal, route cursor, transform,
  persistence, diagnostics, and presentation.
- The route search is fixed-capacity, allocation-free, and off the steady-tick
  path.
- Restore excludes native handles and rebuilds runtime controller/route state.
- S11 encounter movement is a typed temporary directive; it does not own the
  controller.
- Gameplay scenarios, fault profiles, replay, selected-entity inspection,
  semantic GPU visibility, and schema-3 incident bundles already exist.
- Human testing has physically proven vehicle-driven NPC displacement and open
  district traversal.

The focused pre-S12 navigation baseline was:

```text
zig build test-navigation-contract test-sandbox-navigation \
  test-district-feature test-npc-feature -Deditor=false --summary all

13/13 steps succeeded; 50/50 tests passed
```

Those tests certified the six-node linear contract. S12 intentionally replaced
several of those assertions.

## Implementation-Entry Findings

The twelve findings below are preserved as the reason S12 exists. The
implementation resolves them as a cohort; executed evidence and the few
deliberate validation deviations are recorded in
[`../validation/s12-destination-driven-navigation.md`](../validation/s12-destination-driven-navigation.md).

### S12-F001 — Graph identity is mistaken for destination intent

`Goal.navigate_to` and patrol endpoints are `NavigationNodeRef` values. Saved
intent therefore names the current routing implementation, not a product
destination such as `market_terminal`.

### S12-F002 — The installed graph cannot exercise route choice

The canonical recipe requires one degree-one/two linear route, two terminals,
and one reciprocal seam connection. It cannot prove an alternate path,
topology-driven replan, or meaningful route cost.

### S12-F003 — Inactive, exhausted, and unreachable results are conflated

The existing BFS can skip inactive intermediate nodes, return `inactive` for an
inactive target, and return `no_path` for either a disconnected graph or fixed
capacity exhaustion. Those meanings cannot share one result in S12.

### S12-F004 — Ordinary intent cannot wait for inactive destination content

Spawn/set-goal rejects an inactive destination district. A durable destination
must instead remain accepted while runtime execution waits at the last safe
active frontier.

### S12-F005 — Displacement recovery can erase physical truth

When a displaced actor cannot rebuild its route, current recovery may relocate
the controller to its previous pose or reconstruct it there. Existing tests
certify that behavior. S12 replaces it with accept-pose, re-anchor, wait, or
blocked semantics.

### S12-F006 — Nearest node is geometric, not necessarily reachable

The current same-district nearest-node query can select an anchor across a
wall. The richer map requires a bounded reachability/clearance check before an
anchor is committed.

### S12-F007 — Progress can move away from the goal

Any horizontal movement greater than two millimetres resets the stall counter.
Sideways pushing or motion away from the route can therefore look healthy.

### S12-F008 — Base routes have no explicit lineage

Routes do not retain a route revision, topology revision, plan tick, trigger,
result, or watched load generations. Encounter pursuit replans because the
encounter producer periodically reissues a directive; ordinary destinations
do not have the same explicit triggers.

### S12-F009 — Navigation overlay ownership is mixed with encounter debugging

Current route drawing iterates encounter records. Ambient destination
navigation must have an independent read-only overlay.

### S12-F010 — Fast replans are invisible to current incident state

Incident NPC state is sampled at 4 Hz and includes only immediate target,
coarse progress state, no-progress ticks, and last-progress tick. A route can
invalidate and rebuild between samples without an event record.

### S12-F011 — Incident manifest cohort metadata is stale

`src/hosts/incident_capture.zig` wrote protocol `12` and snapshot `11` as
literals while the accepted cohort had already advanced. S12 now sources live
cohort constants and regression-tests that manifest metadata cannot drift.

### S12-F012 — The installed scene is content-pipeline conformance, not a map

Each current district glTF is one triangle instanced twice. This is correct for
the old cooker proof and insufficient for navigation evaluation.

## Architecture And Ownership

```text
sandbox destination catalog ----\
admitted district topology ------+--> pure bounded route planner
runtime traversal/gate view -----/                 |
active district ticket view ----------------------|
                                                  v
encounter temporary intent ------------------> NPC feature
                                                  |
                                                  +--> CharacterVirtual motion
                                                  +--> canonical NPC state
                                                  +--> transition trace
                                                  +--> immutable inspection
```

The pure planner owns no retained state. `NpcFeature` remains the only
autonomous movement owner. `DistrictFeature` remains the only active-content
and load-generation owner.

## S12 Contract

### Destination

Initial value shape:

```zig
pub const DestinationId = struct {
    value: u32,
};

pub const Destination = struct {
    id: DestinationId,
    position: [3]f32,
    arrival_radius: f32,
    anchors: [max_destination_anchors]NodeRef,
    anchor_count: u8,
};
```

The sandbox catalog provides developer labels separately. Runtime and wire
records do not retain string pointers.

### Goal

```zig
pub const Goal = union(enum) {
    hold,
    travel_to: DestinationId,
    patrol_between: struct {
        first: DestinationId,
        second: DestinationId,
    },
};
```

There is no raw-node compatibility variant.

### Route plan

A committed runtime route includes:

- `route_revision`;
- `planned_tick`;
- `topology_revision`;
- ordered node/edge identities;
- total integer travel cost;
- active prefix length;
- current index/segment;
- watched district load tickets;
- plan trigger and result; and
- a deterministic route digest for evidence/replay.

It is runtime scratch and is rebuilt after restore.

### Planner result

```text
ready
waiting_for_content
blocked_by_traversal
unreachable
invalid_destination
invalid_topology
capacity_exhausted
deferred_budget
```

`ready` may carry a complete catalog route and a shorter currently active
prefix. Movement never enters a node whose district ticket is absent or stale.

### Navigation status

```text
idle
resolving
following
waiting_for_content
blocked
arrived
unreachable
```

Status reason is a separate closed enum. Examples:

```text
destination_assigned
destination_changed
restored
encounter_resumed
external_displacement
owner_transferred
district_inactive
district_generation_changed
topology_changed
edge_closed
physical_obstruction
outside_navigation_coverage
structurally_disconnected
destination_reached
```

NPC runtime/controller residency is represented independently as active or
dormant.

## Deterministic Planning

The S12 graph remains tiny, so use fixed-array Dijkstra rather than importing a
heap or third-party pathfinder.

- Edge cost is an explicit positive integer stored in the admitted content.
- Accumulated cost uses checked `u32` or `u64` arithmetic.
- Equal total cost is broken by stable predecessor/node identity.
- Search order is canonical and independent of native container order.
- Every searched node/edge count is returned for metrics.
- Complete immutable topology determines structural reachability.
- Runtime gate exclusions are applied as a separate filter.
- Residency determines the movable prefix, not whether the destination exists.

Live authority, command preflight, persistence validation, and replay use this
one implementation.

## Replan Policy

Replan requests are fixed-capacity records ordered by:

1. request authority tick;
2. urgency class;
3. stable NPC identity.

Initial urgency:

| Class | Trigger |
|---|---|
| Immediate | destination change, invalid current edge, topology revision |
| Immediate | external displacement beyond route corridor |
| Normal | district generation change or content becomes active |
| Normal | encounter returns base intent |
| Deferred | suspected/confirmed physical block retry |

At most eight plan requests execute per authority tick. A deferred request
retains its reason and age. Budget delay is observable and cannot become
`unreachable`.

No periodic replan runs for an unchanged static destination. Moving encounter
targets retain the bounded S11 cadence and use the same planner result types.

## Displacement And Recovery

### Detect

Compare the authoritative position with:

- current route segment;
- current/next anchor ownership;
- cross-track distance;
- distance advanced toward the segment target;
- active load ticket; and
- the controller's actual published displacement.

Vehicle impulses and externally caused movement are physical truth and count
as displacement evidence, not route progress.

### Re-anchor

Candidate anchors:

1. current segment endpoints when still reachable;
2. same-district graph nodes in distance order;
3. adjacent active-district seam nodes when ownership changed.

Before selection, a narrow physics/clearance capability proves the character
capsule can reach the candidate without crossing a blocker. Stable node
identity breaks equal-distance ties.

### Recover

- invalidate route with `external_displacement`;
- commit the selected anchor;
- plan to the same destination;
- follow, wait, or become blocked;
- never rewrite position to the old route;
- never manufacture arrival from nearest-node selection.

If no anchor is reachable, retain the actor and destination with
`blocked/outside_navigation_coverage`. Recovery retries only after movement,
content, topology, or bounded backoff changes.

## Physical Blockage

`potentially_stalled` remains an early diagnostic state. Confirmation requires:

- an active movement target;
- insufficient reduction in segment/destination distance;
- excessive cross-track or near-zero controller advance;
- stable route/topology/load generations during the observation window; and
- an authoritative capsule/segment obstruction result.

On confirmation:

1. record the blocking semantic body/type when available;
2. add the current edge to the NPC's two-entry temporary exclusion set;
3. request one `physical_obstruction` replan;
4. follow an alternate route when one exists; otherwise remain blocked; and
5. clear/retry when the blocker moves, exclusion expires, or topology changes.

Blocked is recoverable. It is never a runtime fault and never structural
unreachable.

## Evaluation World

Implement the exact two-district map in
[`s12-navigation-evaluation-world.md`](s12-navigation-evaluation-world.md).

Key constraints:

- retain two districts and current graph/content capacities;
- replace the linear topology validator with bounded graph validation;
- add two seam routes and six named destinations;
- add readable low-poly road/plaza/market/depot content;
- keep collision proxies visible;
- add one bounded two-gate topology control;
- keep the old triangle fixtures as cooker conformance data; and
- do not absorb S15 city/content expansion.

## Debugging And Audit Contract

### Immutable NPC navigation inspection

For each NPC:

- stable persistent and replicated identity;
- owner district and controller residency;
- semantic destination ID and developer label;
- resolved destination position/anchor;
- navigation status and reason;
- route revision, digest, length, cost, index, current/next node;
- topology revision and watched district tickets;
- last plan/replan tick, trigger, result, age, and cumulative count;
- remaining segment/destination distance and cross-track error;
- goal-directed no-progress ticks;
- blocker identity/type and temporary edge exclusions;
- displacement tick, previous/new anchor, and distance;
- arrival tick;
- teleport/rollback count.

The accepted teleport/rollback count is zero.

### Transition events

Use transition-only typed records:

```text
destination_assigned
destination_changed
plan_requested
plan_committed
plan_waiting
plan_blocked
plan_unreachable
route_invalidated
waypoint_advanced
waiting_entered
waiting_resumed
block_suspected
block_confirmed
block_cleared
displacement_detected
anchor_changed
destination_arrived
```

Every record includes authority tick, NPC identity, destination, route/topology
revision, trigger/result, position, and correlation. Route-commit records also
include the complete bounded route and route digest.

Do not log per-tick transforms as transition events.

### Gameplay trace

Add `navigation` as a typed gameplay trace kind. Map destination assignment,
planning, invalidation, recovery, wait, block, unreachable, and arrival into
the existing causal journal. Ordinary navigation states are not fault
diagnostics.

### Incident schema

Advance the incident schema as one greenfield cohort when the navigation
record shapes land.

- Manifest cohort fields source exported constants, never literals.
- Compact NPC navigation state remains in `state-*.ndjson`.
- Exact transitions and full route changes enter `timeline-*.ndjson`.
- Aggregate planner/status data enters `metrics-*.ndjson`.
- Anomaly windows materialize those same records without a parallel file
  format.
- Handoff search examples include destination, route revision, replan trigger,
  blocked/waiting/unreachable, and arrival.
- Inspector, replay adapter, repository skill, personal installed skill, and
  docs advance together.

The existing -5 through +2 second visual window and 15-second/5-second typed
pre/post windows remain sufficient.

### Overlay

Split navigation visualization from encounter visualization.

Navigation overlay shows:

- all admitted graph nodes and edges;
- active/inactive district state and ticket generations;
- runtime-closed gates/edges;
- selected destination beacon;
- committed route, route cursor, and current segment;
- re-anchor/displacement vector;
- obstruction hit/edge exclusion;
- status/reason text; and
- debug batch saturation/drop evidence.

Encounter overlay retains perception, leash, last-known target, and combat
state.

### Navigation Lab

Add the UI described in the evaluation-world document. It is a narrow
developer control surface. It never mutates NPC, district, or gate state
directly; requests cross existing typed owner boundaries.

## Scenario Catalog

### `destination_branch_arrival`

- assign `market_terminal`;
- prove deterministic route digest and route tie-break;
- cross the district seam;
- arrive exactly once;
- retain identity, finite pose, and continuous presentation.

### `destination_topology_replan`

- begin on the preferred North Gate route;
- close North Gate transactionally;
- observe topology revision and one route invalidation;
- replan through South Gate;
- arrive without teleport, disappearance, or destination change.

### `destination_content_wait_resume`

- unload east in the unpinned validation composition;
- retain destination and active prefix;
- enter waiting, never inactive content;
- reload with a new generation;
- replan once within budget and arrive.

### `destination_external_displacement`

- use a focused fake-port test and a real-Jolt vehicle push;
- preserve physical displacement and destination;
- re-anchor to the new corridor;
- replan and arrive;
- assert zero snap-back, teleport, duplicate controller, or authority fault.

### `destination_dynamic_block_recovery`

- place/park an authoritative rigid body on the preferred segment;
- observe suspected then confirmed physical block;
- choose an alternate route when available;
- when every current route is obstructed, remain blocked with bounded retry;
- remove the blocker and recover.

### `destination_genuinely_unreachable`

- use a complete focused topology fixture with no structural path;
- produce one unreachable transition per destination/topology revision;
- prove no inactive frontier, runtime gate, planner exhaustion, or blocker was
  misclassified.

The ordinary product map does not need a fake unreachable island.

### `destination_encounter_interrupt_resume`

- start destination travel;
- enter S11 pursuit/attack/search/return;
- preserve the base destination;
- replan on encounter return and arrive.

### `destination_save_restore_replay`

Capture moving, waiting, and blocked states:

- cold restore retains semantic destination;
- runtime route is derived from restored topology;
- gate/content state restores before classification;
- accepted-ingress replay reproduces transition categories and exact first
  divergence;
- no native/Jolt bitwise determinism is claimed.

## Placement And Fault Coverage

Use one shared semantic journey in:

- embedded solo;
- constrained listen with one remote client; and
- dedicated authority with graphical clients.

Authority navigation decisions must match. Client presentation may arrive at a
different frame under impairment but converges without identity gaps.

Reuse the existing network fault harness:

- one nominal adverse profile;
- one blackout/reconnect profile; and
- one seeded first-failure reproduction path.

Do not build a second navigation-specific packet fault framework or a complete
Cartesian matrix.

## Performance And Capacity

Measure:

- planner queries and deferred requests per tick;
- searched nodes/edges per query;
- route length/cost;
- route/replan counts by trigger/result;
- maximum plan age;
- current/peak waiting, blocked, and unreachable counts;
- progress/block confirmation cost;
- controller count and update time;
- trace/event queue high-water and drops;
- incident state/timeline bytes;
- ReleaseFast fixed-tick p50/p95/p99;
- allocator peak/live bytes and process RSS; and
- installed GPU scene/instance/upload budgets.

Run:

1. ordinary six-NPC evaluation-world journey;
2. simultaneous 64-request planner wave;
3. representative real-Jolt moving cohort that fits authored spawn clearance;
4. long wait/reload/replan soak; and
5. incident capture enabled/disabled comparison.

Do not force 64 physical NPCs into six or eight safe map positions merely to
preserve an old synthetic shape. Planner scale and physical movement scale may
use separate explicit fixtures.

## Implementation Sequence

Complete one phase, update its evidence, and review the plan before starting
the next.

### S12-A — Contract, preflight, and failing proofs

- [x] Accept or amend ADR-023.
- [x] Record the current focused baseline and exact cohort constants.
- [x] Make incident manifest cohort fields source live constants and add a
  drift regression.
- [x] Add failing tests for semantic-intent coupling, inactive-versus-no-path,
  displacement snap-back, and missing replan evidence.
- [x] Freeze initial capacities and measurement method.

**Exit:** the old behavior is reproduced and named; evidence metadata is
truthful before new navigation work begins.

### S12-B — Destination catalog and pure planner

- [x] Add bounded stable destinations to sandbox content.
- [x] Generalize route validation from one line to the exact bounded graph
  rules needed by the evaluation world.
- [x] Add positive integer edge cost and canonical graph ordering.
- [x] Implement one shared allocation-free deterministic planner.
- [x] Distinguish ready, waiting, blocked, unreachable, invalid, capacity, and
  budget results.
- [x] Use the planner from live command preflight and cold snapshot validation.
- [x] Delete the duplicated raw-node/BFS compatibility paths.

**Exit:** pure tests prove deterministic routes and every result class over
known, inactive, gated, malformed, exhausted, and disconnected fixtures.

### S12-C — NPC intent, execution, and physical recovery

- [x] Replace raw node goals with semantic destinations.
- [x] Separate controller residency from navigation execution status.
- [x] Add route/topology lineage and bounded replan scheduling.
- [x] Accept inactive destinations and retain an active route prefix.
- [x] Replace snap-back recovery with collision-aware re-anchoring.
- [x] Add goal-directed progress, confirmed blockage, two-entry temporary edge
  exclusion, bounded retry, and zero-teleport evidence.
- [x] Resume base intent through the shared planner after transient direct
  encounter pursuit, as required by ADR-023.

**Exit:** fake-port and real-Jolt tests prove displacement, waiting, blockage,
recovery, encounter return, and arrival without hidden relocation.

### S12-D — Higher-fidelity evaluation world

- [x] Author/cook/install the west/east S12 product fixtures and provenance.
- [x] Install the exact branched graph, destinations, costs, and clear routes.
- [x] Add the two bounded seam gates with matching topology, collision, visual,
  persistence, and replay state.
- [x] Remove or canonicalize the composition-private invisible sandbox blocker.
- [x] Reposition the playable cohort using swept-clearance and camera tests.
- [x] Retain the original S3/S6 cooker conformance fixtures.

**Exit:** the installed scene is readable, every blocker is visible, both
corridors are playable, and all existing declared content budgets still pass.

### S12-E — Inspector, overlay, trace, and incident evidence

- [x] Add immutable per-NPC destination/route/status/recovery inspection.
- [x] Add transition-only navigation events and aggregate metrics.
- [x] Add the independent navigation overlay and Navigation Lab window.
- [x] Extend the gameplay trace with navigation causality.
- [x] Advance incident schema/inspector/handoff/replay/skill as one cohort.
- [x] Prove exact route-change evidence survives rapid replans and overlapping
  anomaly flags without per-tick log spam.

**Exit:** a fresh-context developer or LLM can explain every committed route
and classification from one bundle without reading source first.

### S12-F — Persistence, replay, placement, faults, and scale

- [x] Advance snapshot/replay/content/config cohorts together with no decoder
  fallback.
- [x] Prove cold restore from following, waiting, blocked, and encounter-return
  checkpoints.
- [x] Prove exact first-category replay divergence.
- [x] Run shared solo/listen/dedicated semantic journeys.
- [x] Run adverse plus blackout/reconnect fault profiles.
- [x] Measure ordinary, planner-wave, representative real-Jolt, soak, and
  incident-enabled cohorts.
- [x] Keep all inherited S8/S11/IV/IC gates green.

**Exit:** authority decisions match across placements and remain within every
declared resource/evidence budget.

### S12-G — Installed Metal and human acceptance

- [x] Run scripted installed Metal journeys above and below authority tick
  cadence.
- [x] Prove continuous semantic-ID presence at declared checkpoints.
- [ ] Perform the evaluation-world human walkthrough.
- [ ] Capture one real incident during topology replan and one during physical
  displacement/block recovery.
- [ ] Inspect, grep, replay, and preserve both bundles.
- [x] Perform automated architecture, correctness, dead-code, documentation-drift,
  performance, and playable reviews.
- [x] Update parent plans and record automated evidence.

**Exit:** human behavior is understandable, incident evidence explains it, all
tests pass, and no P0/P1 S12 finding remains.

## Proposed Build Gates

Names may be adjusted to existing build conventions, but ownership remains:

```text
zig build test-s12-navigation -Deditor=false --summary all
zig build measure-s12 -Deditor=false --summary all
zig build smoke-installed-s12-macos -Deditor=true --summary all
zig build verify-s12 -Deditor=true --summary all
```

`verify-s12` composes focused planner/NPC/map/incident checks with inherited
interaction, S11, replay, content, source-package, editor, and macOS gates. It
does not duplicate their implementations.

## Acceptance Matrix

| Concern | Required evidence |
|---|---|
| Intent | Persistent NPC goal names a destination, never a route node |
| Planning | Lowest-cost route and tie-break are deterministic and bounded |
| Waiting | Inactive required content waits and later resumes |
| Blocked | Runtime gate/physical obstruction remains recoverable and inspectable |
| Unreachable | Only complete immutable structural disconnection produces the terminal class |
| Displacement | Physical pose is retained; same destination replans from a reachable anchor |
| Movement | No healthy S12 path teleports or rolls back position |
| Encounter | Temporary combat movement cannot erase base destination |
| Persistence | Restore derives route scratch from semantic destination and current topology |
| Replay | Navigation transition digest matches or identifies exact first divergence |
| Multiplayer | Solo/listen/dedicated authority decisions match; network faults affect observation only |
| Presentation | Living NPC has no unexplained projection/draw/semantic-ID gap |
| World | Two readable corridors, named landmarks, visible blockers, and coherent collision |
| Debugging | Inspector/overlay/bundle explain destination, route, trigger, result, and status |
| Evidence | Manifest cohorts are live constants and schema tools advance together |
| Performance | Ordinary, planner wave, movement, soak, and incident budgets pass |

## Documentation Strategy

The reason for S12 is retained in four layers:

1. ADR-023 owns durable architecture and explicit nonclaims.
2. This document owns implementation order and acceptance.
3. The evaluation-world document owns exact map, graph, destinations, visual
   language, and human walkthrough.
4. [`../validation/s12-destination-driven-navigation.md`](../validation/s12-destination-driven-navigation.md)
   owns only
   executed commands, measurements, incident paths, reviews, and deviations.

Implementation discoveries update the finding list here before changing scope.
Accepted changes to ownership or semantics amend ADR-023. Temporary progress
does not rewrite historical S8/S11 evidence.

## Stop/Review Conditions

Stop the phase and review rather than expanding silently if:

- the two-district map cannot create a valid alternate route;
- matching visible/physical/logical gate state cannot commit transactionally;
- collision-aware re-anchoring requires general navmesh generation;
- ordinary six-NPC planning exceeds current tick budgets;
- remote debugging would require private route data in the normal protocol;
- the content scene exceeds current limits by more than a measured narrow
  increase;
- a proposed recovery needs teleportation to pass; or
- S12 begins absorbing S13 population activity, S14 firearms, S15 city
  expansion, or MP7 services.

## Definition Of Done

S12 implementation is complete. Full phase acceptance remains pending until:

- one NPC retains a semantic destination through branching, waiting, topology
  revision, physical block, vehicle displacement, encounter interruption,
  restore, replay, reconnect, and network faults;
- waiting, blocked, and unreachable are mechanically distinct and correctly
  evidenced;
- the installed evaluation world is coherent and every blocker is visible;
- zero healthy path uses snap-back or teleport recovery;
- selected-NPC inspection, graph overlay, transition logs, and incident
  bundles explain the journey;
- focused, aggregate, source-package, headless, installed Metal, performance,
  and human acceptance pass; and
- parent plans and the architecture review record the accepted result and any
  remaining pressure points.
