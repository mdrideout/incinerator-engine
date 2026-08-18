# S13 Population Evaluation World

**Status:** Accepted; world, runtime population, automated product journey,
performance evidence, and human walkthrough complete

**Date:** 2026-07-28

**Parent plan:**
[`s13-authored-population-and-sandbox-activity.md`](s13-authored-population-and-sandbox-activity.md)

## Purpose

The S13 world must make authored pedestrian activity, slot contention,
separation, interruption, and replacement obvious in ordinary play. It extends
the accepted S12 two-district urban test block without becoming S15's larger
content program.

The world remains:

- two admitted districts;
- the current support/collision ownership;
- the current S12 destination-driven graph and gate semantics;
- fully traversable by player and vehicle;
- small enough to observe activity from several viewpoints; and
- large enough for sixteen uniquely placed NPC capsules.

No wall, relevance cutoff, invisible blocker, or district policy may hide a
population defect.

## Authored Roster

The ordinary product has twelve stable population members:

| Members | Role | Count | Activity character | Combat disposition |
|---|---|---:|---|---|
| P01-P05 | resident | 5 | Local plaza, alley, market, and idle visits | P01 hostile test; four passive |
| P06-P09 | worker | 4 | Depot/transit commute with market break | Passive |
| P10-P12 | visitor | 3 | Plaza/market/transit visits | Passive |

The exact member IDs, program IDs, initial phase offsets, and spawn-slot sets
are canonical content values. Member names are developer labels only.

P01 preserves the current playable hostile encounter and its death/replacement
journey. Hostility is authored directly; it is not inferred from P01's low ID
or roster position.

## Activity Sites and Capacity

S13 authors eight recognizable sites and sixteen capacity-one activity slots:

| Site | District | Slots | Primary roles | Activity |
|---|---|---:|---|---|
| Player Plaza | West | 2 | Resident, visitor | Visit / idle |
| Depot Forecourt | West | 2 | Worker, resident | Commute / visit |
| South Gate Approach | West | 2 | Resident, visitor | Visit |
| North Walk | West | 2 | Worker, visitor | Commute / idle |
| Market Terminal | East | 3 | All | Shop / visit |
| Alley Junction | East | 2 | Resident, visitor | Visit / idle |
| Transit Yard | East | 2 | Worker, visitor | Commute |
| East Court | East | 1 | Resident, worker | Idle / visit |

Every slot receives:

- stable site/slot identity;
- exact semantic destination;
- exact pose and facing;
- visible debug marker;
- one activity-kind mask; and
- capacity one.

The market's three slots create normal contention pressure. East Court's one
slot creates a deterministic single-slot wait case. Activity locations must
remain clear of the player's initial pose, vehicle, carryable, route
intersections, gates, and collision proxies.

## Activity Programs

Programs are short cyclic authored sequences. They do not model clock time.

Representative intent:

```text
resident-local:
  Player Plaza visit -> Alley Junction visit -> Market shop -> Player Plaza idle

resident-east:
  East Court idle -> Market shop -> Alley Junction visit

worker-cross-district:
  Depot commute -> Transit commute -> Market visit -> Depot commute

visitor-loop:
  Player Plaza visit -> North Walk idle -> Market visit -> Transit visit
```

The twelve members use program variants and phase offsets so they do not all
request the same site on the same tick. At least two members intentionally
reach East Court close together during the scripted journey, proving one claim
and one visible `waiting_for_slot` outcome.

Dwell times are long enough to see at normal play speed and short enough for
the complete scripted journey to observe two steps per role. Exact tick values
are set once S13-A measures the product journey; wall time is never authority.

## Spawn Capacity

The world provides twenty-four authored spawn slots:

- twelve west and twelve east;
- at least four candidates per role;
- at least one cross-district safe fallback per member;
- exact physical pose plus admitted navigation anchor;
- pairwise capsule separation at catalog admission; and
- multiple candidates that are naturally offscreen from common player
  positions without erecting an artificial perimeter.

Spawn slots are not activity slots. A dead member cannot reserve an activity
location as its replacement pose.

S13-B finalized these exact coordinates. Positions are capsule-bottom world
positions; anchors are the retained S12 graph node references.

### Activity slot coordinates

| Slot | Position (x, y, z) | Anchor |
|---|---|---|
| Player Plaza A / B | `(-6.5, 0, 6.2)` / `(-3.5, 0, 6.2)` | West 0 |
| Depot A / B | `(4.0, 0, 6.3)` / `(5.8, 0, 5.2)` | West 5 |
| South Gate A / B | `(3.0, 0, -5.8)` / `(5.3, 0, -4.8)` | West 3 / 7 |
| North Walk A / B | `(2.0, 0, 1.5)` / `(4.5, 0, 2.5)` | West 4 |
| Market A / B / C | `(18.5, 0, 6.3)` / `(20.5, 0, 6.3)` / `(22.5, 0, 5.3)` | East 2 |
| Alley A / B | `(13.0, 0, -0.8)` / `(14.5, 0, 0.6)` | East 7 |
| Transit A / B | `(19.0, 0, -5.7)` / `(21.5, 0, -5.5)` | East 4 |
| East Court A | `(12.5, 0, 5.8)` | East 1 |

Each activity slot owns one of the exact semantic destinations `1..16`.
Existing destination names `1..6` remain recognizable developer vocabulary;
destinations `7..16` name the companion and additional slots.

### Spawn slot coordinates

| District | Slots and positions |
|---|---|
| West 01–06 | `(-6.5,0,-6.5)`, `(-4.5,0,-6.5)`, `(-2.5,0,-6.5)`, `(2.0,0,-7.0)`, `(4.5,0,-6.5)`, `(6.5,0,-6.5)` |
| West 07–12 | `(-6.5,0,0)`, `(-3.5,0,0)`, `(2.5,0,0)`, `(5.5,0,0)`, `(-6.5,0,2)`, `(-3.5,0,2)` |
| East 01–06 | `(9.5,0,6.5)`, `(11.5,0,3.5)`, `(15,0,6.5)`, `(17.5,0,4.5)`, `(21,0,3.5)`, `(23,0,6.5)` |
| East 07–12 | `(9.5,0,0)`, `(12,0,0)`, `(20,0,1.5)`, `(22.5,0,1.5)`, `(10,0,-6.5)`, `(13,0,-6.5)` |

The cold catalog admission performs:

1. canonical static capsule-clearance checks;
2. pose-to-anchor traversal checks;
3. pairwise spawn, activity, and cross-kind separation checks;
4. exact role/program/member/reference/distribution checks; and
5. destination-pose equality and route-catalog admission.

A native host test creates the two canonical Jolt collision districts, admits
all sixteen activity capsules, and settles them for 120 ticks. All remain at
their authored x/z, on the support surface, with no overlap. Player, vehicle,
carryable, replacement visibility, ordinary-camera, and installed Metal
interactions remain later integration/acceptance gates; no
composition-private fallback coordinate is permitted.

## Navigation Capacity

The existing graph remains the authority. S13 may add only the destinations
and anchors needed for the sixteen activity slots and twenty-four spawn poses.

Requirements:

- every activity destination is reachable from every compatible spawn anchor
  in immutable topology;
- at least two cross-district activity programs exercise both S12 gates;
- spawn pose-to-anchor paths do not cross a canonical blocker;
- an occupied activity slot does not make an unrelated graph node physically
  unusable;
- the market and transit sites do not force all traffic through one exact
  point; and
- the 16-member stress roster can stand at its authored slots without overlap.

If these conditions require materially larger polygonal walkable space or
continuous local steering, stop and review the S15/Recast trigger rather than
smuggling a navmesh into S13.

## Scene Readability

The S12 primitive urban language remains intentionally simple. S13 adds only
enough visual grouping to identify the eight sites:

- low nonblocking site pads or signs;
- unique site labels in debug mode;
- visible activity-slot rings;
- visible spawn-slot capsule outlines in debug mode; and
- role-colored NPC base presentation.

Authoritative collision remains in the canonical district recipe. Decorative
site markers cannot stop the player, NPC, or vehicle.

Presentation precedence:

1. death;
2. hit reaction / attack windup;
3. hostile encounter;
4. activity interruption/wait;
5. role base presentation.

Role color alone is not the contract. Population Lab text and overhead debug
labels show role and activity.

## Population Debug Overlay

| Evidence | Visual |
|---|---|
| Free activity slot | Thin cyan ring plus site/slot label |
| Claimed activity slot | Amber ring and line to member |
| Occupied activity slot | Green ring and member label |
| Waiting member | Amber destination line and retry text |
| Interrupted member | Magenta activity line |
| Free spawn slot | Thin blue capsule |
| Reserved/selected spawn slot | White capsule |
| Rejected spawn slot | Red capsule plus typed reason |
| Live-NPC separation radius | Muted gray circle; red on violation |
| Population member destination | Role-colored line |
| Vacancy/replacement | Red member marker at retained death proxy and candidate labels |

The overlay composes with Navigation Lab. It does not replace S12 route,
topology, block, or district visualization.

## Automated Product Journey

The installed renderer-neutral and Metal scenarios execute the same semantics:

1. Load both districts and bootstrap twelve members.
2. Prove twelve distinct member IDs, physical NPC IDs, spawn slots, and
   nonoverlapping capsules.
3. Observe one travel and dwell for each role.
4. Observe East Court contention: one claim and one typed wait.
5. Close North Gate while a worker is crossing; retain its activity and use
   S12 replan/wait semantics.
6. Reopen the gate and observe arrival and dwell.
7. Push a resident off route with the vehicle; retain member, program step, and
   slot intent while S12 recovers.
8. Enter/drive/exit the vehicle and carry/drop/recollect the object to preserve
   inherited product playability.
9. Approach and fight P01; observe encounter interruption, death proxy,
   vacancy, unsafe candidate retry, safe replacement, same member/role, and new
   physical identity.
10. Save/restore one traveling member, one dwelling member, and the pending
    replacement.
11. Complete at least two activity steps for every role.
12. Capture contention, displacement, and replacement incidents.

The journey runs above and below authority render cadence and under the
existing deterministic fault/reconnect profiles.

## Human Evaluation Walkthrough

Run:

```sh
zig build run -Deditor=true
```

Then:

1. Open Population Lab and Navigation Lab.
2. Watch the roster table reach twelve live members with no overlap warning.
3. Select one resident, worker, and visitor; confirm their role, program,
   activity, site, slot, and destination match visible behavior.
4. Observe at least one claimed-to-occupied-to-released slot lifecycle.
5. Wait for the East Court contention case; confirm one member visibly waits
   and later continues.
6. Drive into a traveling NPC and move it away from its route. Confirm no
   snap-back, disappearance, identity loss, activity change, or unexplained
   fault.
7. Close/reopen a route gate in Navigation Lab and confirm activity intent is
   retained.
8. Fight and kill P01. Confirm red death feedback, named vacancy/replacement
   pending state, safe retry if necessary, then the same P01 role/program on a
   new physical actor.
9. Enter/drive/exit/re-enter the vehicle and collect/drop/recollect the
   carryable while population continues.
10. Walk and drive across the full open area. Confirm no distance-based NPC
    disappearance.
11. Flag any unexplained wait, overlap, disappearance, wrong role, activity
    jump, or replacement with the Incident Capture window.
12. Use the bundle inspector and visual report before accepting the phase.

## Human Acceptance Questions

- Can the tester tell that pedestrians have different authored purposes?
- Does waiting look like a named state rather than broken movement?
- Can the tester identify the site and slot an NPC is using?
- Does vehicle displacement preserve activity truthfully?
- Does death remain visible until safe replacement?
- Is replacement clearly the same population member but a new physical actor?
- Can every absence or delay be explained by Population Lab and an incident?
- Can the full product still be played without opening any developer window?

## Performance and Scale Cohorts

| Cohort | Purpose |
|---|---|
| 12 ordinary authored members | Product behavior, rendering, network, incident, and human acceptance |
| 16 authored physical members | Unique placement, separation, activity contention, controller/draw/CPU pressure |
| 64 synthetic NPCs | Existing bounded feature/queue/replay pressure only; no crowd-quality claim |

Measure:

- authority total and population/activity decision time;
- planner queries and deferred work;
- Jolt bodies, CharacterVirtual controllers, placement/separation queries;
- ECS/entity/component and fixed-owner memory;
- snapshot/replay bytes and save/restore time;
- projection bytes/publications for member/role/activity fields;
- render draws and Metal frame time;
- incident NDJSON and visual-capture cost; and
- every queue high-water/drop/rejection counter.

S13 does not add simulation/representation/replication LOD in response to these
measurements unless the ordinary or 16-member cohort proves a concrete budget
failure. A failure triggers review, not an arbitrary visibility cutoff.

## Acceptance

- Twelve ordinary members and sixteen stress members have unique authored
  physical placement.
- All three roles produce visibly different authored activity loops.
- Every activity slot is exclusive and its lifecycle is inspectable.
- One deterministic contention case waits and recovers.
- S12 waiting, blocked, gate, displacement, and encounter-return semantics
  preserve the retained activity step.
- Only the explicitly authored hostile member initiates combat.
- Death and replacement preserve member/role/program while replacing physical
  actor identity.
- No NPC disappears because of distance in the bounded evaluation world.
- Solo/listen/dedicated and fresh replay agree on population decisions.
- The world remains playable by character, vehicle, and carry interaction.
- The complete cohort stays within measured fixed-tick, memory, controller,
  draw, network, save, replay, and incident budgets.

## Explicit Deferrals

- Larger map or more than two districts.
- Production art, pedestrian animation, conversations, shops, jobs, economy,
  schedules, needs, factions, wanted levels, or social relationships.
- Behavior trees, StateTree, GOAP, utility AI, or generic smart objects.
- Navmesh, Recast/Detour, ORCA/RVO, crowd flow, formations, and traffic.
- Simulation/representation/replication LOD or a generic relevance graph.
- Firearms, S15 world expansion, separate game packaging, Steam/public
  services, MMO operations, and secondary platforms.
