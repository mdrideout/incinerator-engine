# ADR-028: Content-Rich Four-District Sandbox Cohort

**Status:** Accepted and implemented; automated acceptance complete

**Date:** 2026-08-18

**Platform:** Apple Silicon macOS only

**Implementation plan:**
[S15 Content-Rich District Expansion](../design/s15-content-rich-district-expansion.md)

**Evaluation world:**
[S15 Four-District Evaluation World](../design/s15-four-district-evaluation-world.md)

## Context

S12 proved destination-driven recovery on an exact two-district, 16-node
weighted graph. S13 placed twelve authored population members and sixteen
activity slots in that world. DR1 made the deterministic presentation readable,
and S14 added authoritative ranged combat. The result is a coherent product
slice, but the world remains too small and too linear to pressure the next
architectural boundaries honestly:

- district, streaming, replay, diagnostics, and dedicated bootstrap capacities
  still encode exactly two entries;
- every route crosses one west/east seam, so the graph does not represent a
  city-block circuit;
- population activity cannot exercise a second spatial axis;
- the recipe and the composition both create flat support collision, leaving
  two owners for the same physical fact; and
- the product pins the complete tiny route, so content growth has no measured
  four-scene residency or cook/install evidence.

S15 must expand real content without turning the engine into a general asset
database, procedural city generator, navmesh stack, or crowd framework.

## Decision

### One exact 2×2 installed cohort

The sandbox installs four adjacent 16 m districts:

```text
northwest (0,1) ─ northeast (1,1)
       │                  │
southwest (0,0) ─ southeast (1,0)
```

The four entries are one exact content cohort. Catalog admission, logical
recipe reconstruction, cooked bundle identity, save/replay fingerprints,
dedicated bootstrap, visual streaming slots, and developer diagnostics all use
the same ordered coordinate set. No directory enumeration or legacy
two-district decoder remains.

The ordinary product deliberately keeps all four logical and visual districts
resident. Four entries exactly fill the already-existing four-scene GPU
registry and expose real load/publication cost without allowing the tester to
outrun a tiny asynchronous route. Lifecycle validation still exercises
selective load, cancellation, unload, drain, and reload.

### One flat support owner

The composition-owned continuous sandbox ground is the sole flat support
collision and fallback visual surface. District recipes no longer create
overlapping floor boxes. District logical content owns only obstacles,
navigation, and semantic world placement; cooked scenes and deterministic
environment composition own road, sidewalk, plaza, and landmark decoration.

This is an explicit current-world decision, not a permanent terrain model.
Future ramps, stairs, bridges, interiors, or multi-level streets require a
content schema that binds authored support geometry to collision truth. They
must not be approximated by adding another hidden global floor.

### Expand the admitted weighted graph, not the navigation architecture

Each district retains at most eight nodes and sixteen directed edges. The
installed graph becomes 32 nodes with reciprocal links across all four seams.
It contains multiple cross-axis routes and a complete block circuit. The
existing deterministic allocation-free Dijkstra planner remains the backend.
Its retained route/search storage grows to the exact 32-node admitted cohort.

This content does not prove a navmesh is necessary. Every required pedestrian
destination and obstacle can still be represented clearly by the authored
graph, route-clearance admission, and existing displacement recovery. Recast/
Detour is reconsidered only when irregular walkable polygons, vertical
connectivity, or authoring cost produces a repeatable failure. A crowd solver
is reconsidered only after measured local-avoidance pressure, not merely
because four districts exist.

### Expand authored activity into the north row

The stable S13 population roster and role model remain unchanged. The content
catalog adds north-row destinations, activity sites, activity slots, and spawn
slots. Existing cyclic programs are revised so ordinary residents, workers,
and visitors traverse both axes. Population continues to own why a destination
is selected; S12 navigation owns how it is reached.

The normal product still publishes its bounded twelve-NPC cohort as
`full_world`. The relevance baseline names all four installed districts. S15
does not reintroduce a distance cutoff or representation LOD.

### Cohort break

S15 intentionally advances the sandbox recipe, population catalog, replay,
snapshot, and network content cohorts. The network baseline already carries a
bounded district array, but its product semantics change from one current
district to the complete four-district sandbox, so the protocol cohort also
advances. No compatibility reader or alias bundle is retained.

## Acceptance Boundaries

- Four deterministic bundles and one catalog cook twice to identical bytes.
- Catalog admission validates all four logical builds, dependencies,
  reciprocal topology, destinations, and exact bundle identities.
- Solo, listen, and dedicated authorities activate the same four districts.
- A route can traverse the full block circuit and replan across both axes.
- Twelve ordinary population members use north- and south-row activity.
- Static support body count has one owner and no district floor duplicates.
- The normal Metal product draws all four districts and remains traversable.
- Incident/developer evidence names all four streaming slots and current route
  lineage without truncation.
- Cook, residency, fixed-tick, and presentation costs are measured against the
  accepted S13/DR1 baseline.

## Consequences

- Several fixed arrays grow because a concrete four-entry product now consumes
  them. This is cohort work, not a generic unbounded streamer.
- Historical S6/S8/S12/S13 measurements remain evidence for their original
  cohorts; current verification tools consume the new exact cohort.
- The four-scene registry is full in ordinary play. A fifth district is a
  deliberate future trigger for eviction policy and a larger streaming-window
  design rather than an automatic capacity increase.
- A flat continuous support plane remains honest for this evaluation world but
  cannot represent production vertical city geometry.

## Explicit Nonclaims

S15 does not add a navmesh, Recast/Detour, DetourCrowd, ORCA/RVO, procedural
city generation, origin rebasing, terrain system, interiors, traffic,
production art, hot reload, asset database, public services, Steam routing,
secondary platforms, save migration, or a stable content/mod ABI.
