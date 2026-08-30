# Authoring Transactions

Read this reference before crate relocation, undo, redo, or future revisioned
feature authoring.

## Required journey

1. Use `world.list` to discover the current stable target.
2. Use `target.inspect` immediately before mutation and record its authoring
   revision and value.
3. Submit the narrow mutation with that exact target and expected revision.
4. An accepted admission is not a committed edit. Read its transaction ID and
   follow the structured `transaction.inspect` operation.
5. Poll until the disposition is `accepted` or `rejected`.
6. Reinspect the target. An accepted result must agree on the committed
   revision. The transaction's `committed_position` is the exact pose applied
   at its authority tick, while crate inspection reports the dynamic body's
   current simulated pose. Gravity or collision may have moved it afterward;
   judge that evolution separately from transaction success. A rejected result
   must not be treated as a partial success.

Do not silently retry `stale_revision`. Reinspect and report the concurrent
change; only submit a new value if the user's request still authorizes it in
light of the new state.

## Undo and redo

Undo and redo are exact feature-owner transactions over the current history
lineage. They require the currently inspected revision, return admission, and
must be polled and reinspected exactly like a direct edit.

Escape cancellation of an active UI gizmo is not an undo transaction. It ends
the transient interaction and restores that interaction's starting preview.
CLI undo/redo operate on already committed session-authority history.

## Effect boundary

A committed crate edit changes the live authoritative session. It does not by
itself write a world snapshot. `world.save` is a separately authorized durable
persistence operation.
