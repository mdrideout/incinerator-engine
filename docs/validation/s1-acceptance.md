# S1 Character Slice Acceptance Record

> **Historical phase record.** This document preserves the evidence and claims
> recorded when this slice closed. Counts, cohorts, platform results, and
> limitations below describe that dated tree, not current support. See the
> [current macOS readiness record](macos-readiness.md) and
> [cleanup plan](../../CLEANUP_PLAN.md).

**Date:** 2026-07-12  
**Status:** Complete; independently reviewed

## Outcome

The sandbox now composes `CharacterFeature` and `CrateFeature` over one runtime,
one Jolt world, and one fixed schedule. The character walks, turns, jumps,
distinguishes 30-degree walkable and 60-degree steep support, stops at the
composed block and a live dynamic crate, renders as an interpolated capsule,
and restores from the composition-owned V2 snapshot.

## Automated Evidence

- Backend-neutral feature tests cover typed actions, neutral missing input,
  turning, jumping, relanding, grounded transitions, a 3,600-tick diagonal
  terminal fall, canonical persistence, interpolation, explicit identity
  restore, cleanup, create-failure rollback, and update-fault cleanup.
- Real-Jolt adapter tests cover create/update/destroy, falling and landing,
  creation-time grounded contact reconstruction, repeated lifecycle, unique
  Jolt IDs across live worlds, stale and foreign handles, walkable/steep slopes,
  and strict capsule validation. The adapter also promotes Jolt's max-contact
  overflow flag to an engine error after every contact refresh/update.
- Composition tests cover the static block, dynamic-crate collision without
  feature imports, a physical step-up fixture, cross-feature/stale rejection,
  immutable character interpolation, original/restored immediate-jump
  continuation, authoritative character tuning, exact canonical-yaw round
  trips, V2 cross-feature identity policy, and one shared physics step.
- Headless tests cover target-local repeat action streams and byte-stable
  crate-plus-character save/destroy/fresh-restore/destroy, including injected
  allocation failure with both features present. The installed headless
  executable also runs crate and CharacterVirtual spawn/update/despawn.
- The frame-to-tick action latch covers zero-, one-, and multi-tick semantics
  plus capture/focus reset. Input tests prove secondary-window release events
  cannot cancel a main-window gameplay hold.
- The source and linked headless boundary checks include the character feature
  and remain free of SDL, ImGui, renderer, asset-loader, and shader edges.

The complete Debug, ReleaseFast, and editor-enabled Debug matrices each pass
139/139 tests. The filtered source-package extraction passes 16/16 tests.
Linux/Windows cross-build results recorded during S1 are historical evidence,
not current gates or support claims.

## Native Metal Evidence

Both self-terminating checks use SDL input/event pumping, the production action
and fixed-step paths, Jolt CharacterVirtual, the shared physics world, capsule
rendering, interpolated camera follow, GPU submission, and normal teardown.

```sh
zig build run -Deditor=false -- \
  --s1-visual-smoke --frames=480 --virtual-render-hz=240
```

Result: 480 ready frames, 479 post-spawn character frames, 240 ticks, position
and jump motion observed, block collision validated, alpha range `0.0..0.5`,
and `S1_VISUAL_SMOKE_SHUTDOWN status=clean`.

```sh
zig build run -Deditor=false -- \
  --s1-visual-smoke --frames=160 --virtual-render-hz=80
```

Result: 160 ready character frames, 240 ticks with both one- and two-tick
frames, position and jump motion observed, block collision validated, alpha
range `0.0..0.5`, and clean shutdown.

The historical S0 smoke profile remains separate and still passes with one
crate, no character/block, two rigid bodies including ground, and its original
clean sentinel.

## Performance Evidence

The committed [S1 baseline](../performance/s1-baseline.md) measures one virtual
character, one dynamic crate, ground, and block over three ReleaseFast trials.
The per-field median tick p99 was 0.112583 ms, or 1.35% of the 8.333 ms
fixed-tick budget. The largest measured tick was 0.148584 ms. These values
characterize the primary machine and are not shared-runner thresholds.

## Final Review

Three independent read-only reviews were repeated after their findings were
fixed:

- architecture: pass, no remaining P0/P1/P2 finding;
- correctness: pass, no remaining P0/P1/P2 finding;
- build/platform/evidence: pass, no remaining P0/P1/P2 finding.

The primary fixes found during review were terminal-fall representability,
grounded restore contact reconstruction, feature/composition persistence
ownership, authoritative character tuning, canonical yaw, host-owned physics
stepping, secondary-window release filtering, and measurement/cleanup evidence.

Linux/SteamOS and Windows are fully deferred under the macOS-only platform
policy. They impose no current compile, shader, headless, runtime, packaging,
CI, or compatibility gates. This does not change the historical S1 acceptance.
