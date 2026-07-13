# ADR-011: Persistent Authoring and Durable Save Slots

**Status:** Accepted and implemented in S5
**Date:** 2026-07-13

## Context

The sandbox already has persistent entity identities and a byte-stable logical
snapshot, but it has no supported way to author a live object, undo the change,
or commit that snapshot to durable storage. The removed prototype editor wrote
directly to Flecs and Jolt through runtime IDs. Restoring that path would bypass
feature authority, make undo ambiguous, and couple persistence to the editor.

S5 must prove one complete vertical slice: select a crate by persistent ID,
relocate it transactionally, undo and redo it, atomically save it, terminate the
process, and restore the same logical state in a fresh process. Multiplayer,
schema migration, a general scene format, and a general editor service remain
outside this decision.

## Decision

### One authoritative command

The crate feature owns a typed relocation command and outcome. The command
identifies a crate by `PersistentId`, carries a normalized target pose, an
explicit velocity policy, an optional expected authoring revision for
optimistic conflict detection, and a nonzero transaction ID. The outcome
returns an immutable change set containing the exact before and committed
after states plus the new revision. The revision advances only for successful
authoring commits, not ordinary physics motion, so a dynamic crate does not
invalidate undo merely by simulating between editor frames.

The feature applies relocation after the shared physics step. It validates the
complete request and current state before calling one narrow physics capability
that commits pose and velocity together and wakes the dynamic body. On success,
both presentation-history samples are replaced with the committed pose for the
completed tick. Logical, physics, and presentation state therefore become
observable together; there is no direct editor-to-ECS/Jolt setter.

The velocity policy is explicit:

- `preserve` keeps the current linear and angular velocity;
- `zero` clears both velocities for ordinary placement;
- `exact` restores an exact recorded velocity for undo/redo.

Body mode, shape, material, collision layer, activation ownership, and
persistent identity do not change.

### Bounded authoring session

A renderer-neutral sandbox authoring session owns selection, at most one
in-flight transaction, and fixed-capacity undo and redo histories. It submits
the same crate command available to any future gameplay, command-line, or LLM
producer and observes typed outcomes. Undo and redo submit inverse/exact change
sets with optimistic expected-revision checks; they do not mutate the world
directly. Capacity loss and stale selection are visible and bounded.

The S5 visual composition exposes exactly one relocation producer: its editor
authoring controller. It exclusively consumes crate relocation outcomes, and
an unrelated relocation result is treated as a composition-contract violation
rather than silently discarded. A composition-owned monotonic sequencer keeps
transaction allocation outside the controller and fails closed on exhaustion.
The sequencer is safe groundwork for multiple producers, but does not by itself
route outcomes. M3 subsequently added bounded transaction-to-owner
registration and explicit delivery for the cold authority's two external crate
relocation producers. The visual authoring lane still admits only its editor;
CLI, automation, or another visual producer must receive an explicit routed
composition rather than sharing editor outcomes. The latest committed
authoring revision is refreshed across every retained history entry for that
identity, so multi-level history remains valid without changing unrelated
identities.

The editor is an optional extension over immutable authoring snapshots and a
fixed request mailbox. Hiding, closing, or compiling out the editor does not
submit a command or alter body mode. Debug inspection and persistent authoring
remain separate capabilities.

### Durable save-slot adapter

A cold filesystem adapter owns no simulation. It wraps caller-provided logical
snapshot bytes in a bounded little-endian envelope containing:

- save format and payload-schema cohorts;
- the exact current simulation/build fingerprint;
- the expected authoritative world-configuration fingerprint;
- the admitted content fingerprint;
- payload length and integrity digest.

The macOS adapter writes a same-directory temporary file, applies
`F_FULLFSYNC` to flush it to stable media, closes it, atomically renames it over
the committed slot, and applies `F_FULLFSYNC` to the containing directory. An
unsupported full-sync operation fails explicitly rather than weakening the
power-loss durability claim. A write or pre-commit rename failure leaves the
prior committed slot loadable. A stale temporary file is never selected over a
committed slot; explicit startup recovery discards it before the next save.
The result distinguishes `not_committed` from a post-rename directory-sync
warning: once rename succeeds, callers are never told that the old slot remains
authoritative. Loading validates size, structure, integrity, schema, and all
expected fingerprints before returning payload bytes. Only then may a
composition preflight the snapshot's embedded namespace, fixed delta, and
feature tuning against the envelope-admitted world fingerprint and construct a
fresh simulation. Payload/world disagreement is rejected before Flecs or Jolt
authority is acquired. Unsupported cohorts are rejected;
S5 creates no migration promise. Exact simulation fingerprints deliberately
make Debug and ReleaseFast slots incompatible during this greenfield phase.

Save paths are explicit absolute roots supplied by the host. The adapter does
not discover repository-relative paths, create a VFS, or own cloud/user-profile
policy.

### Restart semantics

The current one-live-zflecs-world restriction remains accepted. Save and load
do not hot-swap worlds. A process writes and exits; a fresh process validates
the envelope and constructs one new world from the contained logical snapshot.
Tests may also deinitialize the old world before constructing a replacement,
but that is not presented as atomic in-process world replacement.

## Consequences

### Positive

- The editor reaches authority only through the feature-owned command boundary.
- The single-producer S5 boundary cannot silently lose another owner's outcome.
- Undo/redo conflicts are rejected instead of silently overwriting newer state.
- Physics and presentation history cannot drift from the committed pose.
- Durable storage is editor-, SDL-, renderer-, and Jolt-independent.
- Corrupt or incompatible saves fail before world construction.
- S6 can extend the content fingerprint without replacing the save-slot API.

### Negative

- S5 authors only crate relocation; scale, arbitrary components, prefab
  authoring, and multi-entity transactions require later proven consumers.
- Exact build/content cohort matching intentionally rejects otherwise readable
  saves while the project has no compatibility promise.
- Undo/redo history is ephemeral authoring state and is not persisted.
- The one-world process constraint prevents live transactional world swaps.

## Explicit Nonclaims

This decision does not add schema migrations, autosave policy, cloud saves,
multiple concurrent writers, collaborative editing, arbitrary reflection-based
property editing, a generic transaction framework, multi-producer outcome
routing, networking, or secondary platform support.
