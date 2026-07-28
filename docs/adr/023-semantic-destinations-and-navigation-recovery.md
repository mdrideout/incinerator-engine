# ADR-023: Semantic Destinations and Authoritative Navigation Recovery

**Status:** Accepted and implemented; automated acceptance recorded 2026-07-28

**Date:** 2026-07-27

**Platform:** Apple Silicon macOS only

**Implementation plan:**
[`../design/s12-destination-driven-navigation.md`](../design/s12-destination-driven-navigation.md)

**Evaluation world:**
[`../design/s12-navigation-evaluation-world.md`](../design/s12-navigation-evaluation-world.md)

## Context

S8 proved bounded, deterministic NPC movement across two streamed districts.
S11 proved that encounter behavior can temporarily override that movement and
later return control to the NPC owner. Human playtesting subsequently proved
that vehicle contact can displace an NPC without corrupting authority.

Those slices deliberately stopped short of general navigation:

- `navigate_to` and patrol endpoints still retain cooked graph node references;
- the installed graph is one six-node line with no alternate path;
- ordinary goal admission rejects inactive destination content;
- inactive topology, planner capacity, and a disconnected graph can collapse
  into the same `no_path` result;
- failed displacement rebasing can move the controller back to its previous
  pose;
- any horizontal motion counts as progress even when it moves away from the
  route; and
- incident evidence does not retain the destination, committed route, plan
  revision, or exact reason for a replan.

The physical pose is authoritative fact. A navigation system may interpret
that pose, wait, re-anchor, or report failure. It must not erase a legitimate
vehicle displacement merely to preserve an old route cursor.

## Decision

### Destination intent is not a graph node

The sandbox owns a bounded, content-fingerprinted destination catalog. A
destination has:

- a stable numeric `DestinationId`;
- a developer-facing name;
- one canonical world position and arrival radius; and
- one or more ordered graph anchors for the current content cohort.

NPC persistent intent stores the destination ID. Cooked node references,
active load tickets, path nodes, path costs, current segments, and planner
scratch are derived runtime state.

The initial goal vocabulary remains small:

- hold;
- travel to one destination; and
- patrol between two destinations.

Encounter pursuit remains transient world-position intent. When encounter
control ends, the NPC returns to its retained base destination intent through
the same planner and status vocabulary.

Destination IDs are stable only inside the exact game content cohort. S12 does
not promise a public mod ABI, save migration, or compatibility decoder.

### Keep the existing owners

S12 does not introduce a second world, AI runtime, or transform authority.

| Owner | Responsibility |
|---|---|
| Sandbox destination catalog | Stable destination identity and mapping to current graph anchors |
| Admitted district content | Immutable nodes, weighted directed edges, structural topology, and content fingerprint |
| District feature | Active residency, exact load generations, collision lifecycle, and copied active values |
| Pure bounded planner | Deterministic route result from a topology view, traversal view, start anchor, and destination |
| NPC feature | Destination intent, route execution, controller motion, progress, replan policy, status, persistence, and immutable inspection |
| Encounter feature | Temporary pursuit/hold/return directives only |
| Sandbox evaluation gate | One bounded test-world topology change with matching visible and physical state |
| Session authority | Identity routing and publication, not path planning |

Live authority and cold snapshot validation use the same pure planner. The
duplicated live-versus-restore graph searches are removed rather than retained
as compatibility paths.

### Separate immutable topology, runtime availability, and residency

The planner consumes three distinct facts:

1. **Catalog topology:** the complete admitted graph and destination catalog,
   whether or not every district is currently active.
2. **Runtime traversal:** the current open/closed state of authored traversal
   gates plus a monotonic topology revision.
3. **Residency:** exact active district tickets and generations required before
   a controller may enter a segment.

This separation gives each outcome one meaning:

- inactive required content is waiting;
- a structurally valid route excluded by a temporary gate or confirmed
  obstruction is blocked;
- a complete search over the immutable admitted graph with no path is
  unreachable; and
- malformed or missing destination content is invalid, not unreachable.

An exhausted planner budget or fixed-array capacity is an explicit
infrastructure/budget result. It must never masquerade as unreachable.

### Use a small deterministic weighted graph planner

S12 retains the admitted waypoint graph. It does not integrate a navmesh.

Edges gain an explicit bounded integer travel cost. A pure, allocation-free
fixed-array Dijkstra search selects the lowest-cost route. For the S12 graph,
an `O(nodes² + edges)` scan is simpler and easier to audit than a heap. Stable
node/edge identity breaks equal-cost ties, so native iteration order never
affects authority.

The result includes:

- complete route;
- active route prefix plus the first required inactive district;
- blocked with the exclusions that prevented a runtime route;
- structurally unreachable;
- invalid topology/destination; or
- planner capacity/budget exhaustion.

The planner does not move an NPC, mutate content, load a district, or write
diagnostics.

### Navigation execution status is separate from runtime residency

NPC execution uses a closed status:

```text
idle
resolving
following
waiting_for_content
blocked
arrived
unreachable
```

Controller residency remains active or dormant. Waiting at an active boundary
does not become a third controller-lifetime concept.

Every status transition has one typed reason and authority tick. At minimum,
replan triggers are:

- destination assigned or changed;
- restore;
- encounter return;
- external physical displacement;
- owner transfer;
- district activation, deactivation, or generation change;
- traversal topology revision;
- current edge unavailable; and
- confirmed loss of goal-directed progress.

Replans are event-driven and budgeted. They do not run every tick.

### Physical displacement is accepted, not undone

When an NPC is pushed:

1. retain the authoritative physical pose;
2. compare it with the committed route corridor;
3. resolve a reachable active anchor using a bounded, collision-aware query;
4. invalidate the old route with `external_displacement`;
5. replan toward the same destination; and
6. follow, wait, or report blocked/off-network truthfully.

No healthy S12 path teleports or snaps the NPC back to its former position.
Diagnostics retain a teleport/rollback counter whose accepted value is zero.
An off-network NPC is blocked and remains inspectable; it is not silently
removed, declared unreachable, or moved to conceal the condition.

### No-progress is evidence, not an exception

The existing potential-stall signal remains non-fatal. S12 strengthens it to
measure goal-directed progress:

- distance reduction toward the current segment and final destination;
- cross-track error from the committed segment;
- actual controller displacement;
- current grounding/support state;
- route/topology revision stability; and
- elapsed authority ticks.

No-progress alone does not close an edge. A bounded authoritative segment
obstruction query must confirm the physical blocker before the NPC temporarily
excludes the current edge and replans. Each NPC may retain at most two
short-lived edge exclusions.

Dynamic-object avoidance, crowd steering, and route planning remain separate.
S12 does not add RVO, DetourCrowd, or a general local-avoidance simulation.

### Debug evidence is part of the authority contract

S12 navigation transitions use the existing gameplay trace and incident
timeline, not fault logs and not unbounded text.

Transition records include:

- NPC stable identity;
- destination ID;
- start/current/next anchor;
- route and topology revisions;
- trigger and result;
- missing district or blocked edge when applicable;
- route length/cost/digest; and
- authoritative position and tick.

The 4 Hz incident state lane retains compact current state. A full bounded
route is written only on a route-change transition, preventing per-tick log
spam and 2 KiB line overflow.

Private route scratch does not enter the normal gameplay protocol merely to
support debugging. Solo/listen/dedicated validation reads authority-side
evidence. A wire change requires a real player-facing presentation need.

## Initial Boundaries

| Resource | Accepted S12 ceiling |
|---|---:|
| Active/installed districts | 2 |
| Navigation nodes per district | 8 |
| Directed edges per district | 16 |
| Maximum outgoing degree | 3 |
| Semantic destinations | 8 |
| Retained route nodes | 16 |
| Temporary edge exclusions per NPC | 2 |
| Planner queries per authority tick | 8 |
| Search expansions per query | 16 nodes / 32 directed edges |
| Ordinary product NPCs | Existing 6-NPC ceiling |
| Synthetic NPC ceiling | Existing 64 |

These are accepted slice budgets, not permanent public limits. The measured
planner and real-Jolt cohorts are recorded in
[`../performance/s12-baseline.md`](../performance/s12-baseline.md).

## Research Position

Mature navigation systems separate destination selection, path query, path
following, local movement, and avoidance. Godot's current navigation agent
documentation likewise treats the target as input, returns the next path
position to caller-owned movement, and requests a new path when an actor moves
too far from its path. It also warns against recomputing paths every frame.

Recast/Detour remains the leading open-source successor when actual city
geometry requires polygon corridors, tiled streaming, query filters, and
crowd-scale steering. Its own module split separates navmesh generation,
runtime query, tile caching, crowd behavior, and debug utilities. S12 adopts
the ownership lessons without adding the dependency.

References:

- [Recast Navigation project and module boundaries](https://github.com/recastnavigation/recastnavigation)
- [Detour runtime query, filters, tile references, and path corridors](https://recastnav.com/group__detour.html)
- [Godot path query and path-following model](https://docs.godotengine.org/en/stable/tutorials/navigation/navigation_using_navigationagents.html)
- [Godot query metadata, filtering, and search limits](https://docs.godotengine.org/en/stable/tutorials/navigation/navigation_using_navigationpathqueryobjects.html)
- [Unreal navigation costs and dynamic generation](https://dev.epicgames.com/documentation/en-us/unreal-engine/navigation-system-in-unreal-engine)
- [Jolt `CharacterVirtual` lifecycle and collision behavior](https://jrouwe.github.io/JoltPhysics/class_character_virtual.html)

## Consequences

- Snapshot, replay, content, incident, and possibly protocol cohorts may break
  together. No fallback decoder is retained.
- Current raw-node NPC goals and snap-back displacement tests are replaced.
- The linear-route validator becomes a bounded general graph validator with
  canonical ordering, reciprocal-edge policy, costs, and destination checks.
- Route search leaves `NpcFeature` as a shared pure module consumed by live and
  restore paths; NPC remains the movement owner.
- The map gains real branch pressure while the district count, renderer,
  streaming topology, and physics architecture remain bounded.
- Future Recast integration can replace the planner/topology adapter without
  changing semantic destination or NPC authority ownership.

## Explicit Nonclaims

S12 does not add:

- a navmesh, Recast/Detour dependency, or Zig C wrapper;
- navmesh baking, tiles, polygon corridors, or off-mesh links;
- crowd simulation, RVO, reciprocal avoidance, or traffic;
- four-district/city-scale streaming;
- behavior trees, GOAP, schedules, smart objects, or population roles;
- arbitrary runtime world editing or a generic door framework;
- client-authoritative navigation or private route replication;
- save compatibility, a stable content ABI, or secondary-platform support.
