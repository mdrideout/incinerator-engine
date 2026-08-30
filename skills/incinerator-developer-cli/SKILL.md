---
name: incinerator-developer-cli
description: Inspect and control a running Incinerator Engine editor through the canonical incinerator-dev JSON CLI. Use for local agent discovery, world/content inspection, selection, camera control, revision-safe authoring, undo/redo, world saves, or correlated frame evidence. Do not use it to bypass feature owners or invent unavailable operations.
---

# Incinerator Developer CLI

Use the installed `incinerator-dev` executable as the sole agent-control
surface. Non-help operations emit JSON; help remains human-readable text.
Agents in this project have shell access; there is no MCP adapter and no second
mutation path.

## Discover the current contract

1. Run `incinerator-dev agent bootstrap` using the installed binary for the
   current build. If the repository build is the intended product, the normal
   path is `./zig-out/bin/incinerator-dev`.
2. Record the discovery lifecycle, run identity, protocol cohort, and agent
   catalog digest. Stop if the endpoint is not available; do not attach to an
   old socket or substitute another run.
3. Run `incinerator-dev agent catalog`. Treat its operation IDs, parameters,
   units, effects, completion models, and availability as authoritative.
4. Use the catalog rather than remembered syntax or copied documentation.
   An explicit `--discovery /absolute/path` must remain absolute and must name
   the intended run's discovery document.

## Choose the narrow operation

Read-only inspection is always preferable before mutation. Respect the effect
reported by the catalog:

- `read_only` observes state or a correlated result;
- `editor_presentation` changes selection or camera, not authority;
- `session_authority` changes the live authoritative session;
- `durable_persistence` writes the fixed world-snapshot slot; and
- `evidence_capture` materializes a correlated product frame.

Never construct a target from labels or remembered numeric IDs. Obtain live
targets from `world.list` and durable assets from `content.list`. A runtime
crate is a world instance, not a reusable content asset. Preserve the run
identity printed in every response.

For revisioned authoring, read
[authoring transactions](references/authoring-transactions.md) completely.
For saves, restart claims, or frame artifacts, read
[persistence and evidence](references/persistence-and-evidence.md) completely.

## Follow the result model

Every endpoint response contains an operation ID, `terminal`, structured
`next` operations, and the exact typed response. Treat `next` as guidance, not
permission to broaden the task.

- A synchronous response is complete when returned.
- A successful or pending operation exits zero. A typed endpoint failure,
  rejected terminal result, failed result, or missing correlated result is
  still printed as JSON and exits nonzero; inspect the JSON before stopping.
- An admission with `terminal: false` has only entered its owner. Poll the
  returned transaction, save, or capture ID through the named next operation.
- Continue until the typed disposition is terminal. Do not infer success from
  elapsed time or visible presentation.
- After a terminal authority mutation, re-inspect the stable target. The
  committed revision must match. `committed_position` is the pose applied at
  the transaction's authority tick; the inspected crate position is the
  dynamic body's current simulated pose and may have physically settled since
  that tick.
- Stop on a typed rejection or client error. Report its exact reason and current
  run identity instead of guessing flags, changing targets, or retrying a
  materially different operation.

## Preserve ownership and authorization

The CLI is a client of the same selection, viewport, authoring, persistence,
and incident owners used by the product. Do not access socket bytes directly,
mutate saves, inspect raw engine objects, execute private pointers, or add
generic command/property paths.

User authorization still governs mutations. Inspection does not authorize a
session edit; a session edit does not authorize a durable save; a capture does
not authorize unrelated filesystem access. Undo/redo are revisioned owner
transactions, not a substitute for user approval or memory rewind.

## Handoff

Report the installed CLI path, run identity, catalog digest, operation IDs,
initial and final revisions, terminal dispositions, any typed rejection, and
the exact save or capture evidence produced. State clearly whether the result
is editor presentation, live session authority, or durable persistence.
