# ADR-027: Authoritative Ranged Combat

**Status:** Accepted for S14

**Date:** 2026-08-18

**Platform:** Apple Silicon macOS; secondary platforms remain deferred

## Context

The accepted engine already has one authority implementation across solo,
listen, and dedicated placements; reliable action results; deterministic
accepted-ingress replay; authority-owned character/NPC poses; Jolt world
obstruction queries; source-aware vitals; death/respawn; and incident evidence.
S14 must make that architecture carry a real ranged-combat interaction without
turning one handgun into an inventory, ballistics, or lag-compensation framework.

## Decision

### One bounded handgun contract owns weapon rules

`ranged_combat` owns the immutable handgun configuration and the per-avatar
weapon state machine:

```text
holstered <-> equipped -> reloading -> equipped
```

The state records magazine ammunition, reserve ammunition, next-fire tick, and
reload-completion tick. It admits equip/holster, fire, and reload transitions
from explicit authority context. Death resets the loadout. Accepted vehicle
entry or carry collection holsters it because S14 does not include vehicle or
one-handed carry combat.

This owner does not know session connections, replicated identities, Jolt,
NPCs, presentation, or transport. It does not select a target or mutate health.

### Authority resolves the current world, never a client-selected victim

A fire request carries session identity, action sequence, avatar incarnation,
and the client's intended target tick for diagnosis. It carries no target,
origin, hit point, or damage. The server evaluates the current authoritative
avatar pose. S14 deliberately performs no rewind.

The authority constructs a horizontal chest-height ray from the authoritative
facing yaw, intersects current live player/NPC hit volumes, rejects world-
occluded candidates through the existing Jolt query boundary, and selects the
smallest ray fraction with stable semantic identity as the tie-breaker. Native
physics result order never selects a victim.

An admitted shot consumes ammunition even when it misses. A selected target
becomes one `firearm` proposal through the existing vitals boundary. Vitals
continues to own damage, exactly-once death, and NPC reaction/replacement.

### Reliable truth and cosmetic presentation are separate

The shooter receives one reliable action result containing the authoritative
weapon state and final hit outcome. Every relevant participant receives one
reliable shot event containing shooter, authority tick, ray origin/impact,
target when present, and hit/miss outcome. Snapshots carry current weapon state
on the character, closing reconnect and late-join state.

Clients may immediately render an accepted authoritative muzzle flash, tracer,
impact marker, hit feedback, and weapon model from those facts. They do not
predict ammunition, damage, death, or a hit. Presentation expiration uses
authority ticks, not wall time.

### The compatibility cohort breaks intentionally

S14 advances the semantic network protocol cohort because client/server
messages and character snapshots change. Accepted-ingress replay advances
because weapon actions become a new logical input kind. Greenfield policy does
not retain a compatibility decoder.

## Explicit deferrals

- rewind/lag compensation;
- projectile simulation, penetration, ricochet, spread, recoil simulation, or
  physical casings;
- weapon pickups, a general inventory, attachments, animation graphs, or an
  ability/effect framework;
- client-predicted hit markers or ammunition;
- vehicle shooting, dual wielding, NPC firearms, armor, factions, wanted
  levels, anti-cheat, or public services.

These become follow-up work only when a playable measured need exists.

## Consequences

- Solo remains the same network architecture as multiplayer.
- Current-state hitscan is honest and immediately playable, but high-latency
  fairness is not claimed.
- The weapon rules stay independently testable while session authority retains
  the unavoidable current-world composition.
- Vitals, NPC encounter/replacement, and rendering ownership do not fork.

## Verification

See [S14 Ranged Combat Vertical Slice](../design/s14-ranged-combat.md) and its
[validation ledger](../validation/s14-ranged-combat.md).
