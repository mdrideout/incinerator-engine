# S5 Persistent Authoring and Durable Save Design

> **Historical slice design.** This was the delivery contract for the slice at
> closure. Detailed file layout, cohorts, and limitations below may have been
> consolidated later. See [ADR-011](../adr/011-persistent-authoring-and-durable-save-slots.md)
> and the [cleanup plan](../../CLEANUP_PLAN.md) for current architecture.

**Status:** Complete and independently reviewed
**Platform:** Apple Silicon macOS only

S5 proves one narrow vertical slice from an optional editor request to durable
authority. The complete path is:

```text
persistent crate selection
  -> typed relocation request
  -> feature-owned post-physics transaction
  -> immutable change-set outcome
  -> bounded undo/redo session
  -> logical snapshot
  -> exact-cohort atomic save slot
  -> fresh process
  -> validated restore
```

The governing decision is
[ADR-011](../adr/011-persistent-authoring-and-durable-save-slots.md).

## Stage S5-A: Authoritative Relocation and History

- [x] Add the narrow rigid-body relocation capability and adapter tests.
- [x] Add crate relocation command validation, conflict rejection, exact
  before/after outcomes, post-physics commit, and coherent history publication.
- [x] Include accepted relocation commands in same-cohort replay/digests.
- [x] Add a renderer-neutral bounded authoring session with persistent
  selection, one in-flight operation, undo, redo, stale-selection handling,
  and visible capacity/loss statistics.
- [x] Prove fake and real-Jolt success, failure, rollback, deletion, history,
  body-mode/property, save-byte, and editor-exclusion invariants.

## Stage S5-B: Durable Save and Restart

- [x] Add the bounded binary save envelope and exact simulation, world-config,
  and content fingerprint validation around the existing logical snapshot
  payload.
- [x] Add same-directory temporary write, file sync, atomic replace, stale-temp
  recovery, and structured stage failures.
- [x] Prove malformed, truncated, oversized, corrupt, incompatible, missing,
  write-failed, and rename-failed behavior before world construction.
- [x] Run write and verify as separate installed headless processes and require
  byte-stable canonical re-save after restore.

## Stage S5-C: Optional Editor Extension and Native Closeout

- [x] Register a crate-authoring extension only in editor-enabled builds.
- [x] Give the tool immutable selection/history/world views and a fixed typed
  request mailbox; apply requests after UI borrowing ends.
- [x] Prove editor hide/show/close and editor-disabled builds do not change
  authority, body mode, save bytes, or runtime dependency boundaries.
- [x] Run the full Debug, ReleaseFast, editor-enabled, filtered source-package,
  installed headless restart, and native Metal matrices.
- [x] Complete an independent architecture/correctness/evidence review with no
  remaining actionable P0/P1/P2 finding.

## Acceptance

- [x] Relocate -> undo -> redo -> atomic save -> real process restart -> restore
  passes, and canonical re-save is byte-identical.
- [x] Every successful relocation commits pose, velocity policy, wake state,
  and both presentation samples coherently without changing body mode or shape.
- [x] Stale IDs, wrong feature ownership, non-finite input, state conflicts,
  queue/history saturation, and injected adapter failures are typed and leave
  no partial mutation.
- [x] Write or rename failure leaves the previous committed slot loadable;
  corrupt and incompatible envelopes fail before a replacement world exists.
- [x] The editor can only query immutable records and submit the feature-owned
  semantic relocation command. S5 exposes one relocation producer; any future
  CLI/automation producer requires bounded transaction-to-owner routing first.
- [x] Cold headless and installed save products contain no SDL, Metal, ImGui,
  shader, renderer, or visual-content dependency.

## Explicit Nonclaims

S5 does not provide arbitrary component editing, scale/collider recreation,
multi-entity transactions, persisted undo history, schema migration, autosave,
cloud storage, collaborative editing, networking, or secondary-platform
support.
