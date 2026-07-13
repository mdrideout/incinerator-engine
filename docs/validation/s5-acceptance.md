# S5 Persistent Authoring and Durable Save Validation Record

> **Historical phase record.** This document preserves the evidence and claims
> recorded when this slice closed. Counts, cohorts, platform results, and
> limitations below describe that dated tree, not current support. See the
> [current macOS readiness record](macos-readiness.md) and
> [cleanup plan](../../CLEANUP_PLAN.md).

**Date:** 2026-07-13

**Status:** Complete and independently reviewed. The complete Debug,
ReleaseFast, editor-enabled/disabled, extracted-package, installed Metal,
cold-restart, and aggregate macOS gates pass with no remaining actionable
P0/P1/P2 finding.

**Platform:** Apple Silicon macOS is the sole current runtime-quality cohort.
The authoring controller, save envelope, storage adapter, and restart verifier
remain renderer-neutral and have no SDL, Metal, ImGui, or editor dependency.

**Scope:** S5 only. This phase proves one crate-relocation authoring slice and
one durable fixed save slot. Multiplayer, multiple authoring producers,
arbitrary property editing, schema migration, and secondary platforms remain
outside the contract.

## Implemented Contract

### Typed relocation authority

The crate feature owns one validated `relocate` command identified by
`PersistentId` and a nonzero transaction ID. It accepts an explicit preserve,
zero, or exact velocity policy plus an optional expected authoring revision.
The feature stages the command, applies the atomic body-state change after the
shared physics step, advances the authoring revision only on success, and
publishes the exact before/after change set. Both presentation samples reset to
the committed pose at the completed tick, so interpolation cannot smear a
teleport. Shape, mode, material, layer, body identity, and feature ownership
remain unchanged.

Relocation is part of the exact-cohort replay command schema and divergence
digest. Save/restore deliberately resets ephemeral authoring revisions to zero;
ordinary physics motion never increments them.

### Bounded authoring session and optional editor

The renderer-neutral controller owns one selection, one in-flight operation,
and fixed-capacity undo/redo histories. Undo and redo submit the same typed
relocation command with exact recorded state and optimistic revision checks;
they never write Flecs or Jolt directly. Deletion, lost ownership, revision
conflict, capacity eviction, stale history, and request-mailbox rejection are
explicit and counted.

The S5 application exposes exactly one relocation producer: the editor
authoring controller. Unrelated outcomes are fail-closed composition contract
violations, never silently dropped. The shared monotonic sequencer prevents ID
aliasing, but M3 must add bounded transaction-to-owner registration and delivery
before a CLI, automation, or other producer is admitted.

The editor tool receives immutable crate/session/feedback records and can only
append semantic requests to a fixed mailbox consumed after all UI borrows end.
Typed rejection reasons reach the panel. Hiding, closing, or compiling out the
editor cannot mutate authority or body mode.

### Exact-cohort durable save and restart

The bounded little-endian envelope records the save/payload schemas, exact
simulation build fingerprint, expected world-configuration fingerprint,
canonical content fingerprint, payload length, and integrity digest. Decode
rejects malformed, truncated, oversized, corrupt, or incompatible input before
world construction. `fromSnapshotForWorld` additionally checks the embedded
namespace, fixed delta, and feature tuning against the admitted world digest
before acquiring Flecs or Jolt ownership.

The macOS slot adapter writes a mode-`0600` same-directory candidate, performs
Darwin `F_FULLFSYNC`, closes it, atomically renames it, then performs
`F_FULLFSYNC` on the containing directory. Unsupported full-sync fails before
rename instead of weakening the power-loss guarantee. Pre-rename failures are
`not_committed` and preserve the old slot; post-rename directory-sync failure
is truthfully `committed_sync_warning`. Startup recovery discards, but never
promotes, a stale candidate. Bounded paths and no-follow/beneath-resolution
rules reject traversal and committed/candidate symlink attacks.

The current zflecs cohort remains one-world-per-process: the writer exits, and
an installed SDL/editor/GPU-free executable validates and restores the same
slot in a fresh process before proving canonical byte-identical re-save.

## Evidence

| Gate | Recorded result | Principal evidence |
|---|---:|---|
| full Debug, editor disabled | **114/114 steps; 464/464 tests pass** | complete project graph, headless/source/final-binary boundaries |
| full Debug, editor enabled | **117/117 steps; 464/464 tests pass** | optional ImGui authoring extension and immutable mailbox composition |
| full ReleaseFast, editor disabled | **114/114 steps; 464/464 tests pass** | optimized complete graph and cold tools |
| full ReleaseFast, editor enabled | **117/117 steps; 464/464 tests pass** | optimized visual/editor composition |
| focused S5 Debug and ReleaseFast | **39/39 steps; 156/156 tests pass in each mode** | relocation/history/replay, envelope, slot durability, restore, boundaries |
| extracted source package | **47/47 steps; 80/80 tests pass** | cold headless/replay/save/content graph with shader tools absent |
| installed editor authoring and cold restore | **46/46 steps pass** | real Metal edit/undo/redo/hide/save followed by fresh editor-free verifier |
| aggregate ReleaseFast macOS readiness | **62/62 steps pass** | all installed S2-S5, lifecycle, diagnostics, replay, save/restart gates serialized |
| independent final audit | **Pass** | no remaining actionable P0/P1/P2 finding |

The native S5 path produced:

```text
S5_AUTHORING_SMOKE_RESULT rendered_frames=4 hidden_frames=1 edit_revision=1 undo_revision=2 redo_revision=3 save_status=committed save_sequence=1 gpu_driver=metal
S5_AUTHORING_SAVE_VERIFIED id=1:1 tick=5 payload=1631 envelope=1823 canonical=true editor_free=true
```

It exercised the actual installed visual host's save, not a separately
constructed fixture. The cold verifier opened that exact slot after the visual
process exited, restored the target pose and zero velocity at tick five, and
produced identical canonical payload and envelope bytes.

## Acceptance Status

| S5 requirement | Current status |
|---|---|
| Edit -> undo -> redo -> atomic save -> process restart -> restore | **Verified through installed Metal producer and fresh editor-free consumer** |
| Exact canonical re-save after restore | **Verified byte-identical** |
| Pose, velocity, wake state, body properties, and interpolation commit coherently | **Verified with fake and real Jolt tests** |
| Stale IDs, wrong ownership, invalid input, conflicts, and saturation are typed and non-partial | **Verified** |
| Write/full-sync/rename failures preserve the old slot; post-rename uncertainty is truthful | **Verified by injected and real Darwin tests** |
| Corrupt/incompatible envelope and embedded world drift fail before world construction | **Verified** |
| Editor hide/close/exclusion leaves authority unchanged | **Verified** |
| Cold products remain free of visual dependencies | **Verified by source and final-binary gates** |
| Final independent architecture/correctness/evidence review | **Verified; no remaining actionable P0/P1/P2 finding** |

## Reproducing the Evidence

```sh
zig build test -Deditor=false --summary all
zig build test -Deditor=true --summary all
zig build test -Doptimize=ReleaseFast -Deditor=false --summary all
zig build test -Doptimize=ReleaseFast -Deditor=true --summary all

zig build test-sandbox-authoring test-sandbox-save test-save-slots \
  test-replay test-simulation -Deditor=false --summary all
zig build smoke-installed-s5-save-macos \
  -Doptimize=ReleaseFast -Deditor=false --summary all
zig build smoke-installed-s5-authoring-macos \
  -Doptimize=ReleaseFast -Deditor=true --summary all
tools/verify_source_package.sh
zig build test-macos-readiness \
  -Doptimize=ReleaseFast -Deditor=true --summary all
```

For manual use, create an existing absolute save root and run the editor build:

```sh
mkdir -p /tmp/incinerator-saves
zig build run -Deditor=true -- --save-root=/tmp/incinerator-saves
```

Press F1, open **Tools -> Crate Authoring**, select the crate, edit its position,
and use **Apply position**, **Undo**, **Redo**, and **Save**.

## Explicit Nonclaims

S5 does not provide arbitrary component/scale/collider editing, multi-entity
transactions, persisted undo history, hot in-process world replacement, schema
migration, autosave, cloud saves, multiple writers, multi-producer outcome
routing, collaborative authoring, networking, or secondary-platform support.
Exact Debug/ReleaseFast and content-cohort matching remains intentionally
strict during this greenfield phase.
