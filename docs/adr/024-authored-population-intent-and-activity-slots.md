# ADR-024: Authored Population Intent and Activity Slots

**Status:** Accepted and implemented; final human walkthrough pending

**Date:** 2026-07-28

**Platform:** Apple Silicon macOS only

**Implementation plan:**
[`../design/s13-authored-population-and-sandbox-activity.md`](../design/s13-authored-population-and-sandbox-activity.md)

**Evaluation world:**
[`../design/s13-population-evaluation-world.md`](../design/s13-population-evaluation-world.md)

## Context

S8 established a bounded 64-NPC feature and a stateless batch command producer.
S11 added one playable hostile encounter and a durable delayed replacement
policy. S12 made semantic destination the durable navigation intent and route
state a derived, recoverable implementation detail.

Those slices intentionally did not establish an authored population model:

- the normal-product encounter has a one-off bootstrap owner;
- the historical population producer repeats one spawn template and owns no
  roster, role, or activity state;
- session authority chooses replacement node candidates from its NPC array
  index;
- encounter hostility is assigned by sorted persistent-identity rank through
  `hostile_npc_limit`;
- replacement records name the session NPC slot rather than a stable authored
  population member;
- replacement placement does not explicitly reject another live NPC
  `CharacterVirtual`; and
- the synthetic 64-NPC pressure cohort is not a claim that six or sixteen
  route nodes form a readable physical crowd.

These are architecture findings A-F035 and A-F037. They are acceptable for the
completed single-encounter slices, but they cannot support multiple pedestrian
roles, authored activity, or believable replacement.

S13 must create a visible GTA-style sandbox activity slice without jumping to
a generic AI framework. It must preserve the existing authoritative
solo/listen/dedicated model, S12 navigation ownership, deterministic replay,
bounded memory, and human-test evidence.

## Research Position as of July 2026

The mature patterns worth adopting are narrower than the available commercial
frameworks:

- data-only entity templates/archetypes, small components, and purpose-built
  systems;
- authored spawn and activity locations with stable content identities;
- explicit free/claimed/occupied slot state and exact release on completion or
  interruption;
- a small inspectable state machine for travel, dwell, retry, interruption,
  death, and replacement;
- stable population identity separated from the disposable physical actor;
- event-driven decisions and bounded per-tick work; and
- independent simulation, representation, and replication fidelity policies.

Unreal Mass is useful prior art for separating data-oriented entities,
spawning, representation LOD, simulation LOD, and per-client replication LOD.
Its Smart Object design is useful prior art for placing activity data and slots
in the world while leaving behavior execution with the agent. StateTree and
behavior trees are mature tools, but S13 has neither the behavior breadth nor
the authoring pressure that justifies either graph runtime.

Flecs supports prefabs, relationships, and cached queries. Its own design
guidance favors small atomic components and single-responsibility systems, and
its relationship documentation calls out archetype fragmentation from large
numbers of relationship combinations. S13 will therefore keep the canonical
authored catalog and bounded reservation ledger as explicit sandbox values.
It will add Flecs role/activity components only where a measured runtime query
needs them; it will not model every slot claim as a high-churn relationship
graph.

Recast/Detour and ORCA/RVO are mature open-source successors for irregular
navigation geometry and dense local collision avoidance. They solve different
problems: path topology/corridors and preferred-velocity avoidance. Godot's
current documentation similarly warns that avoidance is separate from
pathfinding and can reduce path quality when applied indiscriminately. The
two-district S13 cohort does not yet demonstrate either need.

Generative and LLM-driven agents are emerging research. They can produce
believable schedules and social behavior, but current work still depends on
explicit canonical world state, validation, exposure, and scheduling to make
outcomes auditable. June 2026 work on LLM-driven game worlds still describes
empirical multiplayer validation as future work, while separate 2026 social
simulation research argues that explicit environment exposure and scheduling
remain necessary. These approaches are unsuitable as authoritative tick-time
decision makers for this deterministic, replayable multiplayer model. A future
offline authoring tool could propose activity programs, but generated prose or
model output will not become runtime authority in S13.

The implementation remains engine-owned Zig plus the existing open-source
stack. Unreal concepts are research references, not runtime dependencies.

References:

- [Unreal Mass Gameplay subsystem separation](https://dev.epicgames.com/documentation/en-us/unreal-engine/overview-of-mass-gameplay-in-unreal-engine)
- [Unreal Mass Entity data-only fragments, templates, and traits](https://dev.epicgames.com/documentation/en-us/unreal-engine/overview-of-mass-entity-in-unreal-engine)
- [Unreal Smart Object activities, slots, claims, occupancy, and release](https://dev.epicgames.com/documentation/unreal-engine/smart-objects-in-unreal-engine---overview?lang=en-US)
- [Unreal StateTree hierarchical state-machine model](https://dev.epicgames.com/documentation/unreal-engine/overview-of-state-tree-in-unreal-engine?lang=en-US)
- [Flecs design guidance](https://www.flecs.dev/flecs/md_docs_2DesignWithFlecs.html)
- [Flecs relationship behavior and fragmentation considerations](https://www.flecs.dev/flecs/md_docs_2Relationships.html)
- [Recast/Detour module boundaries](https://github.com/recastnavigation/recastnavigation)
- [ORCA formulation](https://gamma-web.iacs.umd.edu/ORCA/)
- [Godot's separation of avoidance and pathfinding](https://docs.godotengine.org/en/stable/tutorials/navigation/navigation_using_navigationagents.html)
- [Generative Agents research](https://research.google/pubs/generative-agents-interactive-simulacra-of-human-behavior/)
- [Orchestrated Reality LLM-driven game-world work in progress](https://arxiv.org/abs/2606.16014)
- [AI Agents Alone Are Not (Yet) Sufficient for Social Simulation](https://arxiv.org/abs/2603.00113)

## Decision

### Authored population identity survives physical actor replacement

S13 introduces a bounded `PopulationMemberId` in the sandbox content cohort.
It names authored population intent and survives death, safe replacement,
save/restore, and a new NPC physical identity.

The identities remain distinct:

| Identity | Owner | Lifetime |
|---|---|---|
| `PopulationMemberId` | Sandbox population owner | Authored roster member across actor replacements |
| NPC persistent ID plus incarnation | NPC/vitals authority | One physical NPC lifetime |
| Replicated entity ID | Session authority | One client-visible actor generation |
| Flecs entity/controller handle | Feature/backend | Runtime only |

The session NPC array index is storage, not population identity. It may be used
as a bounded implementation index but cannot select role, hostility,
activity, spawn candidates, or replacement behavior.

### One sandbox population owner owns durable intent

S13 replaces the stateless population planner, one-off product encounter
initializer, and standalone hostile replacement policy with one cohesive
`sandbox_population` owner. The old implementations are removed rather than
wrapped in compatibility adapters.

| Owner | Responsibility |
|---|---|
| Sandbox population catalog | Stable roles, member definitions, activity programs, sites, slots, spawn slots, and exact content validation |
| Sandbox population runtime owner | Member lifecycle, current actor binding, activity cursor/state, slot claims, deadlines, safe replacement intent, transitions, persistence, digest, and diagnostics |
| NPC feature | Physical NPC identity, controller, transform, semantic navigation goal, route execution, and movement status |
| Navigation/district owners | Destination catalog, admitted topology, traversal state, residency, route planning, and displacement recovery |
| NPC encounter feature | Perception, target selection, melee, and transient locomotion override for explicitly hostile members |
| Vitals feature | Health, damage, life state, and exactly-once death facts |
| Session authority | Thin identity/result routing, actor registration, replication, and reliable client feedback |
| Presentation/client | Role appearance and coarse observable activity feedback; never activity selection |

The population owner receives copied facts and emits bounded commands or
transaction intents. It receives no mutable NPC component, controller, route
slice, connection, or transport object.

### Roles describe authored intent, not class inheritance

S13 begins with three pedestrian roles:

- `resident`;
- `worker`; and
- `visitor`.

A role supplies a stable presentation profile and selects an authored activity
program. It is not a behavior class, prefab inheritance hierarchy, faction,
profession framework, or permission system.

Combat disposition is a separate authored value:

- `passive`; or
- `hostile_to_players`.

At least one member retains the existing hostile encounter for regression and
playability. The encounter feature consumes this explicit disposition and
removes `hostile_npc_limit` and persistent-ID rank as authority.

### Activity is one small deterministic program

Each member references a bounded cyclic activity program. A program contains
explicit steps such as `commute`, `shop`, `visit`, and `idle`, with:

- a stable activity site;
- an exact dwell duration in authority ticks; and
- optional member-specific phase offset.

The activity producer advances that authored program. It does not score an
open-ended action set, search a behavior graph, mutate a blackboard, query a
language model, or use wall-clock randomness.

The runtime states are explicit:

```text
selecting
  -> waiting_for_slot
  -> traveling
  -> dwelling
  -> completing
  -> selecting

traveling/dwelling -> interrupted -> selecting same retained step
any live state -> vacant -> replacement_pending -> selecting
```

S12 navigation owns how to reach a destination. S13 activity owns why that
destination was selected. Encounter locomotion may temporarily interrupt
activity but cannot overwrite its program cursor. S12 waiting or blocked
status does not make the population owner silently choose a different activity.

### Activity and spawn slots are separate authored concepts

An activity site groups one or more activity slots. Every activity slot has:

- stable site and slot IDs;
- a semantic destination ID;
- an exact pose/facing used for arrival and dwell;
- an allowed activity kind; and
- capacity one for S13.

The runtime reservation ledger uses:

```text
free -> claimed -> occupied -> free
```

Claims are selected in canonical slot-ID order with a member-specific starting
offset. Same-tick claims are reserved before another member can select them.
A claim becomes occupied only after the matching NPC arrives. Completion,
death, despawn, invalidation, or encounter interruption releases the claim
exactly. A bounded authority-tick lease prevents a permanently blocked traveler
from monopolizing a slot; expiration retains the same activity step and enters
an inspectable retry state.

A spawn slot separately contains an exact physical pose and an admitted
navigation anchor. Catalog admission proves the capsule is clear, the pose and
anchor share a valid owner, and the capsule can traverse from the pose to the
anchor. The NPC spawn command may therefore accept an authored pose plus start
anchor instead of forcing every spawn to occur exactly on a route node.

### Replacement restores authored membership, not a generic NPC count

Death vacates one population member. The same member retains role, combat
disposition, activity program, and cursor while its old physical actor is
removed. The population owner selects from that member's authored spawn-slot
set and emits one correlated replacement intent.

Admission checks, in stable order:

1. active district/content and valid navigation anchor;
2. canonical static clearance and real Jolt placement;
3. same-tick spawn-slot reservation;
4. living players, including occupied vehicle position;
5. other live NPC `CharacterVirtual` capsules;
6. active vehicle/rigid-body obstruction; and
7. player distance and line-of-sight policy.

No safe slot is a typed retry, not teleportation, overlap, disappearance, or
member deletion. The existing death proxy remains until the matching new actor
is registered exactly as required by ADR-019.

### Persistence stores decisions; authored definitions come from content

The exact content cohort owns roles, members, programs, sites, and slots.
Snapshots do not duplicate those immutable definitions.

Canonical mutable records include:

- member ID and lifecycle;
- current NPC persistent ID/incarnation when bound;
- activity program cursor and activity sequence;
- activity state, retained site/slot claim, and authority-tick deadlines;
- replacement generation/retry state; and
- any deterministic selection cursor needed to resume exact slot order.

Cold preflight validates every relationship against the exact catalog and NPC,
vitals, encounter, and replacement records before Runtime, Flecs, or Jolt is
acquired. Runtime handles, queries, candidate scratch, and presentation state
are never serialized.

### Replicate only observable product state

The NPC projection gains only the state needed to render and understand the
actor:

- stable population member ID;
- role/presentation profile;
- combat disposition only if the product presentation consumes it; and
- coarse activity kind/state needed for visible activity feedback.

Private programs, candidate lists, slot claims, retry ordering, and deadlines
do not enter the normal gameplay protocol. Authority-side incident evidence
and local host inspection retain the complete explanation.

The current bounded sandbox continues to publish its NPC cohort with explicit
`full_world` interest. S13 does not reintroduce an arbitrary distance cutoff.
Representation, simulation, and per-client replication LOD remain separate
future decisions triggered by measured larger content.

### Accepted bounded cohort

S13-A accepted these limits against the current feature/controller capacities,
map-area plan, and measured 60 Hz authority budget. Exact physical clearance
for the authored coordinate table remains an S13-B admission requirement.

| Resource | S13 target |
|---|---:|
| Pedestrian roles | 3 |
| Combat dispositions | 2 |
| Ordinary authored population | 12 |
| Maximum authored population members | 16 |
| Spawn slots | 24 |
| Activity sites / slots | 8 / 16 |
| Activity steps per program | 6 |
| Simultaneous slot claims | 16 |
| Population transitions retained | 256 |
| Activity/replacement decisions per authority tick | 4 |
| Semantic destination ceiling | 16 |
| Physical authored stress cohort | 16 |
| Existing NPC transaction/synthetic ceiling | 64 |

The 64-NPC ceiling remains a bounded engine and transaction pressure profile,
not a visual crowd-quality claim. S13 must remove any test that derives
product quality from forced co-location.

## Consequences

- Population membership becomes the stable source of authored pedestrian
  intent across death and replacement.
- A-F035 closes by moving role, disposition, activity, and replacement
  candidates out of session array order.
- A-F037 closes for the declared authored product/stress cohorts through
  sufficient slots, same-tick reservations, and live-NPC capsule separation.
- NPC navigation stays destination-driven and can later replace its graph
  backend without changing population intent.
- The normal product becomes the primary acceptance surface; S13 is not another
  infrastructure-only phase.
- Snapshot, replay, protocol, incident, and content cohorts may break together.
  No old planner, bootstrap owner, replacement record, or decoder is retained.

## Explicit Nonclaims

S13 does not add:

- behavior trees, StateTree, GOAP, utility AI, a blackboard, or a generic task
  graph;
- schedules tied to a calendar, economy, needs, relationships, conversation,
  factions, wanted levels, jobs, or households;
- navmesh baking, Recast/Detour, path corridors, off-mesh links, ORCA/RVO, a
  crowd solver, formations, or traffic;
- LLM/generative agents, learned policies, cloud inference, or nondeterministic
  authority;
- procedural city generation, more than the existing two districts, production
  character animation, or S15 content expansion;
- distance-based NPC disappearance, a generic replication graph, or new public
  Internet/Steam services;
- cross-platform support, save migration, compatibility shims, a stable mod
  ABI, or the separate game-package boundary.

## Review Triggers

Review this decision before expanding S13 if:

- activity-slot arrival requires a general local-steering or navmesh solution;
- the 16-member physical cohort cannot remain separated in the bounded map;
- a fourth behavior family cannot be expressed as one explicit program step
  without duplicating state across owners;
- activity state begins leaking into NPC transform/navigation ownership;
- remote debugging would require private population state in normal protocol;
- population work exceeds the fixed-tick budget or creates steady-state
  allocations; or
- the phase starts absorbing S14 firearms, S15 city expansion, G1 packaging, or
  MP7 services.
