# S1 Character Slice Design

> **Historical slice design.** This was the delivery contract for the slice at
> closure. Detailed file layout, cohorts, and limitations below may have been
> consolidated later. See [ADR-008](../adr/008-feature-oriented-engine-architecture.md)
> and the [cleanup plan](../../CLEANUP_PLAN.md) for current architecture.

**Status:** Complete; independently reviewed  
**Date:** 2026-07-12

## Outcome

S1 adds one player-controlled, foot-anchored capsule that walks, turns, jumps,
distinguishes walkable from steep support, collides with static geometry and
dynamic crates, renders through an interpolated snapshot, follows a third-person
camera, and saves/restores beside crate state. The same feature runs with fake
controllers, real Jolt headlessly, and SDL/Metal visually.

## Ownership and Dependency Boundary

`src/features/character/root.zig` imports only the public engine module. It owns:

- typed spawn, tick-scoped action, and despawn commands;
- private character, controller-handle, locomotion, and transform-history data;
- command application, pre-physics movement, and post-physics publication;
- a grounded-state event stream separate from command outcomes;
- canonical `CharacterV1` records and simulation-relevant `CharacterConfigV1`;
- immutable `CharacterDraw` extraction.

The feature does not import SDL, ImGui, renderer code, Jolt, crates, zmath, or a
host. `src/hosts/simulation.zig` is the sole composition point pairing the
feature with `jolt.CharacterControllers` and composing it beside crates.

## Fixed-Tick Flow

```text
SDL frame input
  -> sandbox ActionLatch
  -> one typed action sample per fixed tick
  -> commands: apply character commands
  -> pre_physics: calculate locomotion + update CharacterVirtual
  -> physics: step the shared Jolt world once
  -> post_physics: publish character and crate transform histories
  -> immutable interpolated extraction
  -> renderer + follow camera
```

Actions contain normalized local movement axes, absolute facing yaw, and a
one-tick jump edge. Missing action input for a tick is neutral; it never repeats
a stale movement sample. The host latch separately preserves frame edges across
zero-tick frames and consumes them only once during multi-tick frames.
Character gravity has an explicit terminal fall speed relative to supporting
ground motion, and the final controller velocity saturates at the shared
engine/Jolt representation boundary instead of eventually faulting or being
silently clamped by the backend.

## Jolt Adapter

The engine adapter uses Jolt 5.5 `CharacterVirtual`, not the simpler rigid-body
`Character`. Its narrow public capability consists of:

- create one bottom-anchored capsule;
- destroy through a world-qualified, monotonic handle;
- read backend-neutral position, velocity, ground state, ground velocity, and
  ground normal;
- update collision/stair/floor behavior from a feature-calculated velocity.

The feature integrates gameplay gravity itself, as required by
`CharacterVirtual`; Jolt's ExtendedUpdate gravity argument does not integrate
the character velocity. ExtendedUpdate owns collision casts, slope response,
floor adhesion, and stair stepping. A general shape-cast API was deliberately
not added because no S1 consumer needs one.

The capsule shape is translated so Jolt position and persistent gameplay
position both mean “feet.” No inner rigid body is created in S1. Ordinary
physics queries therefore do not detect the character, while CharacterVirtual
still detects rigid bodies during its update.

Creation and snapshot reconstruction are treated as logical teleports. The
adapter refreshes contacts before returning the new controller, so a grounded
character is already grounded when its first action is evaluated. Its opaque
engine handle remains world-qualified, while JoltC retains Jolt's own
process-unique character ID for deterministic contact ordering.

The pinned JoltC settings initializer allocates an unreleasable default empty
shape path. The adapter avoids it and explicitly fills the exact Jolt 5.5
defaults. It also checks the wrapper's max-contact overflow flag after every
void ExtendedUpdate call.

## Persistence

S1 establishes composition-owned `SnapshotV2`:

```text
schema + runtime clock + namespace + identity cursor
  character_config: CharacterConfigV1
  crates: CrateV1[]
  characters: CharacterV1[]
```

Features validate, collect, sort, and restore only their records. The host owns
schema parsing, size limits, runtime metadata, cursor validation, and duplicate
identity detection within and across features. Restore occurs while feature
registration remains open; previous/current presentation history starts equal
to avoid a synthetic interpolation jump.

`CharacterConfigV1` contains collider dimensions, locomotion/gravity limits,
slope/stair/floor policy, mass, and maximum push strength. It is authoritative
on restore. The caller may replace presentation asset handles and impose a host
capacity, but cannot silently load the same save with different simulation
tuning. Persisted yaw is finite and canonical in `[-pi, pi)` (with negative
zero rejected) and is copied exactly during restore, so accepted snapshots are
byte-stable across a fresh save.

## Presentation and Camera

The character feature emits plain poses, physical capsule dimensions, typed
asset handles, and a camera target. The visual host owns one small two-slice
resource table containing the existing textured crate and the procedural
character capsule. The capsule is authored at the same physical dimensions as
the Jolt shape, uses the renderer's clockwise winding, and has a blue forward
stripe so yaw is visible.

The camera follows the interpolated target rather than authoritative current
state. Mouse look changes camera yaw/pitch; the absolute yaw submitted in the
next action sample controls character facing. Camera state remains host-owned,
not a global or a mutable feature dependency.

## Deliberate S1 Limits

- One local player is configured, although the feature data path supports a
  bounded character count.
- There is no crouch, animation graph, character-to-character collision,
  moving-platform fixture, camera obstruction, or relative-mouse mode yet.
- Contact events expose grounded-state changes, not contacted entity IDs.
  Body-owner mapping is deferred until a gameplay slice consumes that identity.
- The default 100 N controller collides with but does not push the current
  dense crate fixture materially. Mass/density policy belongs to a later game
  tuning slice.
- Jolt cross-platform deterministic mode remains disabled. Repeat tests are
  target-local evidence for scheduling and command behavior, not lockstep.
