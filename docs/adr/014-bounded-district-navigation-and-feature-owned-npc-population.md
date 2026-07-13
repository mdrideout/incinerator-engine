# ADR-014: Bounded District Navigation and Feature-Owned NPC Population

**Status:** Accepted, implemented, and validated in S8
**Date:** 2026-07-13
**Platform:** Apple Silicon macOS only

## Context

S8 must prove that persistent autonomous actors can cross the exact two
streamed districts, wait through unavailable destinations, survive unload and
restart, replay deterministically within one cohort, and scale to one declared
population. It must do that without inventing a general navigation, AI, crowd,
or procedural population framework.

The existing architecture already has the important owners: `DistrictBuild`
is the renderer-neutral logical payload consumed by live loading and replay;
`DistrictFeature` owns exact residency generations; feature modules own their
ECS/controller lifecycle; the composition owns identity, schema, save, replay,
and schedule order. A second navigation database or a private feature import
would split authority and make restore/replay ambiguous.

## Decision

### Navigation is part of the admitted district build

`DistrictBuild` gains one fixed route fragment: at most eight copied waypoint
nodes and sixteen copied directed edges. The cooked district bundle encodes
the same explicit little-endian fragment, and catalog admission compares it
exactly with the coordinate-specific logical recipe before either reaches the
simulation. The installed west/east cohort is validated as one connected,
bidirectional, linear six-node route through the existing `z=3` clear
corridor.

S8 navigation is therefore recipe-authored and cooked. It is not extracted
from artist glTF extras, a navmesh, or a parallel runtime database. If future
games require artist-authored navigation, the deliberate successor is to make
the admitted cooked logical build the loader source—not to bolt a second
authority beside it.

Greenfield cleanup places the exact two-district route and installed
coordinates in the sandbox-owned canonical recipe provider. The reusable
district/navigation contracts retain bounded node/edge value shapes,
structural validation, and query capabilities without owning a particular
game world's topology.

`DistrictFeature` implements a narrow generation-aware `NavigationAccess`.
Queries return copied node/edge values plus the exact active load ticket, or a
typed inactive/invalid result. They return no component, slice, pointer,
backend handle, or district-private state. Exact cohort validity is checked
before residency, so an invalid reference or edge ordinal never masquerades as
a valid goal waiting on an inactive district. NPC runtime state binds its
controller to the returned ticket, re-resolves before every movement tick, and
suspends/reconciles before use when the generation changes. The ticket is not
serialized.

The same port exposes only a residency-independent directed-edge validity
result for hostile persistence preflight. A pure composition adapter evaluates
that result over the exact logical recipe before Runtime, Flecs, or Jolt is
acquired; the live feature still resolves movement through active district
tickets. Neither operation creates a parallel route database.

### One NPC feature owns autonomous actor authority

`NpcFeature(Controllers, NavigationAccess)` owns persistent identity, district
owner, semantic goal, route cursor, movement state, CharacterVirtual handle,
commands/outcomes/events, persistence, digest, diagnostics, and immutable
presentation. It imports neither `CharacterFeature` nor `DistrictFeature`.

The only public commands are spawn, set-goal, and despawn. Goals are limited to
hold, navigate-to, and patrol-between. Per-tick movement intent is derived
inside the feature and is neither a public producer API nor replay ingress.

An NPC is exactly one of:

- `active`: owner district is active and a controller exists;
- `waiting_at_boundary`: source remains active but the next district is not;
- `dormant`: owner district is inactive and no controller or draw exists.

There is no between-owners state. A cross-district edge is entered only after
the destination resolves under an active ticket. After physics publication,
the existing half-open coordinate rule commits the new owner in the same tick;
`x == 8` belongs east. NPCs never pin district residency.

### Population is a bounded producer, not another authority

A fixed population planner emits at most 64 deterministic spawn commands for
one proven patrol template and owns no entity, outcome, ECS state, or snapshot
record. Every spawn remains independently transactional; no atomic 64-NPC
batch is claimed.

Hard S8 feature capacities are:

| Resource | Capacity |
|---|---:|
| NPC records/controllers/draws | 64 |
| Pending commands | 128 |
| Reserved unread outcomes | 128 |
| Observable events | 256 |
| Population command batch | 64 |
| Route nodes / directed edges per district | 8 / 16 |
| Global CharacterVirtual ceiling | 128 (65 used by sandbox scale proof) |

Accepted commands reserve outcome space before mutation. Authority-relevant
outcomes are never dropped. Observable events may be dropped only with a
bounded counter. No feature path allocates or searches a graph per tick.

### Composition and schemas

The schedule is:

```text
crate -> character -> district -> interaction -> vehicle -> npc -> physics
```

NPC commands and district reconciliation happen before physics; transforms and
half-open ownership transfers publish after physics. Construction/restore uses
the same dependency order and destruction is exact reverse.

S8 introduces `NpcConfigV1`, `NpcV1`, composition-owned `SnapshotV7`, replay
schema cohort 5, schedule cohort 5, command source 6, and a separate NPC digest
category. Content-bound node references remain valid only under the existing
exact content fingerprint. Runtime controller handles, Flecs identities, load
tickets, borrowed data, and content arrays are never serialized.

`NpcV1` contains only persistent identity, district owner, canonical
position/velocity/facing, semantic goal, and route cursor including patrol
direction. Active/waiting/dormant state, controller presence, load ticket, and
transform history are reconstructed after districts restore. Snapshot
preflight validates owner versus half-open position, every goal/cursor node
against the exact content cohort, cursor bounds and relationships, and unique
identity before acquiring a Flecs world or Jolt runtime.

## Consequences

- Live loading, replay ingress, save restore, and NPC queries share one logical
  navigation authority.
- District unload naturally determines active versus dormant NPC runtime
  ownership without a residency pin or migration service.
- CharacterVirtual controllers add no rigid bodies and must be counted
  separately in diagnostics and scale budgets.
- The first population workload can exercise S4–S7 contracts without making
  speculative abstractions for later multiplayer.
- Bundle/recipe/snapshot/replay cohorts intentionally break; there is no
  compatibility or migration obligation in this greenfield overhaul.

## Explicit Nonclaims

No navmesh, Recast, A*, dynamic replanning, crowd/RVO, NPC collision, behavior
tree, utility AI, combat, traffic, procedural spawning, archetype database,
entity migration service, origin rebasing, replication, prediction,
cross-platform determinism, networking, multiplayer, secondary platform, or
MMO-scale population is introduced.
