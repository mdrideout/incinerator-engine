# EA0 Ownership, Identity, and Transaction Boundary

**Status:** Implementation candidate complete; product-owner review pending

**Date:** 2026-08-19

**Decision:**
[ADR-029](../adr/029-engine-game-authoring-boundary.md)

**Program:**
[Engine Authoring Foundation](engine-authoring-foundation.md)

**Validation:**
[EA0 validation ledger](../validation/ea0-ownership-identity-transaction-boundary.md)

## Outcome

Make the engine-runtime, engine-tooling, game-runtime/content, and game-tooling
boundaries executable before practical material, vehicle, lighting, or map
authoring expands the mutable surface. EA0 adds stable asset and authoring
identity, one small revisioned transaction envelope, authored-change evidence,
and the lifecycle/discovery contract for a future local developer endpoint.

Existing gameplay and presentation remain unchanged. The crate relocation
workflow is the only live vertical proof. It keeps its feature-owned typed
command and outcome; the shared EA0 contract supplies correlation, provenance,
scope, revisions, timing, and durable-identity evidence rather than becoming a
generic command or property system.

## Ownership Classification

EA0 classifies current modules without a repository-wide file move.

| Owner | Current module groups | Allowed dependencies |
|---|---|---|
| Engine runtime | `src/root.zig`, `src/engine/**`, backend-neutral `src/content/**`, reusable feature contracts/roots, session capability contracts | Standard library, engine contracts/kernel, narrow capabilities; concrete adapters only at composition roots |
| Engine tooling | `src/editor/workspace.zig`, host-neutral editor views/request tools, developer diagnostics/profile/visualization contracts, offline cook/validation machinery | Engine-runtime public contracts and immutable game/tool projections; no Flecs, Jolt, SDL, renderer resources, `Simulation`, or filesystem mutation |
| Game runtime/content | `src/sandbox/**`, sandbox recipes/catalogs/composition policy, title feature values and installed cooked content | Engine-runtime contracts/features and explicit adapters selected by game composition; no source-asset discovery at runtime |
| Game tooling | Sandbox authoring controllers, title-specific editor panels/palettes/diagnostic projections, title validation workflows | Engine-tooling contracts plus game-owned typed requests/views; no raw authority/backend/filesystem access |

SDL/ImGui integration, Metal rendering, Jolt, storage, and worker I/O remain
explicit adapters or host composition concerns. They are not host-neutral
engine/game tooling merely because developer products compose them.

## Increment Plan

### EA0-A — Executable ownership

- Declare the four owners and dependency policy in one build-owned manifest.
- Add a transitive source/import verifier over the classified roots.
- Keep current explicit Zig module imports as the compile-time authority.
- Reject tooling edges to Flecs, Jolt, SDL, renderer resources, `Simulation`,
  and filesystem mutation owners.
- Reject runtime-content source-path discovery while permitting explicit cooked
  roots and logical bundle keys.
- Treat graphical editor/backend integration as an adapter boundary rather than
  granting every tool raw SDL or renderer access.

### EA0-B — Stable identity

- Add a validated `AssetId` whose representation is independent of paths,
  pointers, runtime entities, physics bodies, and renderer handles.
- Add a validated `AuthoringTarget` containing an explicit target kind and
  stable owner-defined identity.
- Keep persistent entity identity and durable asset identity distinct.

### EA0-C — Revisioned authoring transaction

- Add nonzero `TransactionId`, `Revision`, `Source`, and `EditScope` values.
- Define shared request metadata and result metadata without defining arbitrary
  fields or values.
- Define accepted/rejected disposition and typed common rejection reasons while
  preserving owner-specific typed rejection payloads.
- Require expected-revision comparison for session and durable mutations.
- Keep `preview`, `session`, and `asset_commit` distinct; no scope silently
  promotes to another.

### EA0-D — Crate vertical proof

- Adapt crate relocation to carry the shared request metadata while preserving
  its concrete pose/velocity command and typed outcome.
- Preserve exact inverse/exact undo and redo transactions.
- Preserve immutable editor views and bounded semantic request mailboxes.
- Preserve gameplay, physics, presentation, save, and replay behavior.

### EA0-E — Diagnostics and future endpoint contract

- Add an authored-change record covering run identity, source, target,
  transaction, scope, expected/committed revision, wall time, authority tick,
  presentation frame, disposition, typed rejection, and optional durable asset
  identity/digest.
- Store owner-specific before/requested/committed values outside the generic
  envelope while correlating them by transaction ID.
- Define endpoint lifecycle and discovery values for one process-local macOS
  developer endpoint.
- Do not create a socket, transport, CLI, shell evaluator, remote service, or
  multiplayer administration surface in EA0.

### EA0-F — Closeout

- Run focused identity/transaction/architecture tests.
- Run editor-enabled and editor-disabled repository aggregates.
- Run headless, save/replay/incident, cooked-content relocation, installed
  product, and native Metal regression gates.
- Audit architecture, dead code, documentation drift, and forbidden generic
  abstractions.
- Stop for product-owner review before EA1.

## Contract Rules

1. `AssetId` identifies durable authored/cooked content, not a source path.
2. `AuthoringTarget` identifies the concrete owner and stable subject of an
   edit, not an arbitrary property name.
3. Each owner retains its concrete value, request union, validation, outcome,
   and inverse/exact undo semantics.
4. Shared transaction metadata never contains `anytype`, arbitrary strings as
   commands, reflective values, raw pointers, backend handles, or allocators.
5. UI, validation, and the future local developer client use the same owner
   request and outcome path.
6. Durable commit is a separate owner action and returns the committed asset
   identity and digest only after persistence succeeds.
7. Authored-change diagnostics are immutable evidence, not a second state
   owner or replay authority.

## Explicit Non-Goals

EA0 does not add materials, vehicle archetypes, live vehicle tuning, lights,
map assets, endpoint transport, a CLI, scripting, CVars, reflection, a property
bag, a service locator, a universal command bus, remote control, multiplayer
administration, schema compatibility readers, or a broad file move.

## Acceptance

EA0 is candidate-complete when the four-owner import policy is executable,
stable identities and the typed transaction envelope are public engine-runtime
contracts, crate authoring proves the envelope end to end, authored-change and
endpoint-discovery values are validated, existing gameplay/presentation remain
unchanged, all declared automated/native gates pass, and the product owner has
a concise manual crate-authoring/editor regression checklist.

The implementation reached that candidate-complete state on 2026-08-19. The
automated, installed-product, native Metal, architecture, dead-code, and
documentation evidence is recorded in the validation ledger. EA1 remains
blocked on the product-owner checkpoint.
