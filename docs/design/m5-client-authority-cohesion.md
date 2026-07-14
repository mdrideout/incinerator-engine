# M5 Client/Authority Cohesion

**Status:** Accepted

**Date:** 2026-07-14

**Prerequisite:** The Apple Silicon macOS multiplayer foundation is accepted in
[`M4 Multiplayer Foundation Gate`](../validation/m4-multiplayer-foundation.md).

**Current platform scope:** Apple Silicon macOS only; Linux/SteamOS and Windows
remain future ports with no M5 build, abstraction, or compatibility requirement.

## Purpose

M4 proves the authoritative multiplayer model over direct GameNetworkingSockets,
including characters, vehicles, carry interaction, district relevance, NPCs,
prediction, reconnect, bounded replication, and open room admission. It also
deliberately left one pre-existing MP1 pressure point open: the embedded solo
product exposed a broad local authority-administration facade to a large
graphical host. M5 replaces that flat facade and its ordinary gameplay bypasses,
closes the owner boundaries, and retains the complete macOS and multiplayer
regression.

M5 closes that cohesion gap before another gameplay slice widens it. This is an
ownership and dependency-direction milestone, not a compatibility-preserving
file shuffle. The repository is greenfield; obsolete forwarding APIs are
removed rather than deprecated, and the refactor must not add compatibility
aliases.

## Outcome

Solo becomes an actual placement of the same authoritative session model used by
the dedicated product:

```text
graphical input/UI
        |
        v
client requests + disposable prediction
        |
        v
typed local link ----- same semantic admission ----- network link
        |                                           |
        +--------------> authority session <--------+
                              |
                              v
                    authoritative Simulation
                              |
                              v
                    immutable client projection
```

The embedded composition root may own both halves, but graphical, streaming,
developer, and persistence consumers receive only the capabilities they need.
No client-facing owner receives the concrete `Simulation`, Flecs/Jolt state,
private feature state, durable snapshot bytes, or a save-slot commit handle.

## Starting Pressure Points

This list records the M5 entry state. Resolved items remain here as historical
rationale and are labeled with their current status.

- **Accepted boundary:** the graphical `App` remains the composition root and
  retains presentation, input, authoring, and validation orchestration.
  Embedded authority, district streaming, durable persistence, and developer
  state have explicit opaque owners and lifecycles. Keeping one graphical
  composition root is intentional; it does not receive general mutable
  subsystem access.
- **Resolved:** the former flat `local_solo.Session` surface has been replaced
  by an opaque placement and role-scoped capabilities.
- **Resolved:** ordinary character, vehicle, and carry gameplay now crosses the
  shared semantic client/session path.
- At M5 entry, the solo product advanced embedded simulation from the historical
  120 Hz presentation accumulator rather than the accepted 60 Hz authority rate.
  **Resolved:** embedded authority now runs at 60 Hz with 20 Hz replication while
  presentation remains independently paced.
- **Accepted measured pressure point:** `Simulation` remains the private
  game-world facade.
  Canonical value contracts and diagnostic composition are separate; durable
  snapshot values, codec, cold preflight, and cohort fingerprints have a
  dedicated private module. Native feature composition and restore, tick
  integration, result draining, replay capture, and world queries remain
  intentionally cohesive where they require the live authority.

These are evidence-backed pressure points, not APIs to preserve. Live-authority
responsibilities retained for cohesion are not failures merely because they
share one private facade.

## Ownership Contract

### Graphical application owner

The graphical application owns SDL window/event lifetime, renderer submission,
camera, input sampling, and top-level teardown ordering. It may submit typed
client or developer requests and consume immutable presentation/diagnostic
records. It does not implement gameplay admission, inspect authoritative
feature state, produce durable bytes, or commit a save slot.

### Client session owner

The client owner owns connection state, session/participant identity, semantic
request sequencing, prediction history, snapshot acknowledgement, replicated
state, interpolation, and actionable rejection state. Local and network
placements use the same client request and server message types. A local link
may avoid byte encoding, encryption, and a socket, but it may not bypass
identity, sequencing, ownership, quota, or authority admission.

Ordinary player requests and privileged local administration remain distinct
capabilities: spawn/despawn admin unions cannot carry player gameplay actions.
Client draw DTOs carry replicated/session identity, never durable persistent
identity, and their presentation path consumes replicated-world and prediction
state without consulting authority inspection. Typed local and encoded network
server messages share one semantic validator; invalid snapshot sequences,
duplicate or conflicting replicated identities, non-physical projection values,
zero or contradictory action sequences, and action/result contradictions are
rejected before client or authority state mutates. Transport loss retires at
most one ambiguous vehicle and interaction correlation per lane. A matching
late result is consumed diagnostically without changing newer pending state;
provably older duplicates are nonfatal, while impossible/future and
same-sequence mismatches remain errors. Snapshots remain the gameplay truth.
Delivery-confirmed result replay across reconnect is reserved for the planned
transactional delivery-lease work.

### Authority session owner

The authority owner is the only session layer allowed to mutate the
authoritative simulation. It owns admission, connection/participant lifecycle,
accepted-ingress evidence, feature request translation, simulation ticking,
per-client projection, replication baselines, durable-save eligibility, and
graceful drain. Embedded and dedicated placement must exercise the same
authority behavior rather than separate hand-written dispatch paths.

Every authority instance obtains a private CSPRNG-backed credential secret.
Session and 128-bit reconnect credentials are domain-separated HMAC values;
reconnect credentials are bound to session, account, external identity, and
participant, rotate on use, and compare in constant time. A reconnect retains
at most the credential actually presented until a valid post-welcome message
confirms receipt, preventing a lost queued welcome from stranding the client
without creating an unbounded token history. Room admission rejects a known
zero HMAC secret, verifies the signed identity before reconnect lookup, and
preflights bounded nonce history before participant allocation.

### Authority runtime

`Simulation` remains a private, game-specific authority implementation rather
than a generic engine/ECS service. It constructs or restores one world, accepts
semantic authority work, advances one tick, drains typed results, extracts
immutable evidence, and shuts down. Durable snapshot values/codec/preflight,
diagnostic value composition, and public feature DTOs use cohesive private
modules/contracts. Replication projection and replay envelopes remain private
authority concerns. Live cross-feature wiring, capture/restore transactions,
and tick integration stay inside `Simulation` because splitting them would
require a wider mutable service context.

### District streaming

Logical district residency remains authority-owned. Disposable predicted client
focus may only prefetch decoded visual content; a distinct privileged copied
authority-focus capability drives logical residency. The graphical district
streaming owner consumes those immutable values and owns content-worker/GPU
residency lifecycle. It cannot load or unload canonical logical authority by
mutating `Simulation` directly.

### Developer and authoring tools

Editor, diagnostics, replay, and validation use explicit local privileged
requests or immutable evidence capabilities. Privileged local authority
operations remain distinct from ordinary player protocol messages. UI panels do
not receive raw authority pointers, storage adapters, or backend handles.

### Durable persistence

The authority supplies quiescence eligibility and canonical snapshot creation.
The durable owner decides whether a typed request can proceed and exclusively
owns envelope construction and `SaveSlots` commit. A graphical tool may request
a save and display immutable progress/result feedback; unhealthy, pending, or
non-quiescent authority may not commit.

## Clock and Stage Contract

The authoritative session runs at the accepted 60 Hz in embedded and dedicated
placement. Rendering and input sampling remain independent and may run above or
below the authority rate. Replication remains 20 Hz initially, with the existing
feature-specific NPC cadence and explicit measured budgets.

M5 observes three owner boundaries instead of pretending that physical
transport delivery or blocking storage is part of the fixed simulation tick:

1. the placement trace records client ingress delivery, authority execution,
   authority egress transfer, client application, and acknowledgement ingress;
2. the authority trace records pre-simulation work, simulation, outcome drain,
   and replication extraction, while the nested runtime observer records
   command, pre-physics, physics, and post-physics phases; and
3. the persistence owner evaluates an explicit request only after the link and
   authority report a healthy quiescent boundary, then owns envelope encoding
   and atomic storage commit.

Both traces are completion-aware. A failure records only the completed prefix;
the first authority-cycle failure is immutable and prevents a later call from
advancing another tick. Future inputs remain in a bounded per-target queue and
replication acknowledges a sequence only after it affected a completed tick.

The stricter transactional mailbox, prepared-output, delivery-lease, and queued
durable-decision design is recorded separately in
[`Post-M5 Transactional Authority Cycle`](post-m5-transactional-authority-cycle.md).
It must not be marked complete by adding labels around currently fused calls.

That transactional follow-up is not an M5 acceptance criterion. M5 must prove
the real nested owner traces above and must not describe them as one atomic
eight-stage authority transaction.

## Local/Remote Semantic Parity

| Concern | Embedded solo | Dedicated/direct IP | Required invariant |
|---|---|---|---|
| Player identity | Development account mapped to one participant | Admitted account/ticket mapped to one participant | Same distinct identity lifetimes |
| Character input | Typed local message | Encoded GNS message | Same sequence, target tick, quota, and ownership checks |
| Vehicle control/actions | Typed local message | Encoded GNS message | Same input expiry and reliable action outcomes |
| Carry collect/drop | Typed local message | Encoded GNS message | Same range, ownership, contention, and cleanup policy |
| Player-facing character, vehicle, carryable, and NPC presentation | Replicated client world | Replicated client world | No direct authority view for replicated gameplay rendering |
| Prediction | Disposable client history | Disposable client history | Never persisted or authoritative |
| Save request | Privileged local request | Authority/operations request | Authority creates canonical state; durable owner alone commits it |
| Encoding/transport | May be skipped | Required | Skipping bytes never skips semantic admission |

District bootstrap, NPC population, validation setup, and editor authoring are
authority/host operations rather than ordinary remote-player messages. They
still use narrow explicit capabilities and declared tick boundaries.

## Dependency Rules

- Client-facing modules may import protocol, identity, replicated-world,
  prediction/interpolation, presentation contracts, renderer/input adapters,
  and immutable developer contracts.
- Client-facing modules may not import `sandbox_simulation`, Flecs, Jolt,
  authority feature roots, replay implementation, save-slot storage, or durable
  snapshot implementation.
- Only an embedded composition root may depend on both the client and authority
  graphs.
- The dedicated authority graph retains no SDL, GPU, renderer, editor, visual
  content, lobby SDK, or client prediction dependency.
- `session` and protocol DTOs contain no Flecs IDs, Jolt handles, allocator
  state, raw persistent-save bytes, GPU objects, or borrowed pointers.
- New owners expose domain operations, immutable snapshots, and explicit
  lifecycle methods—not general subsystem accessors.

Architecture checks enforce dependency closure and negative API boundaries.
They do not enforce arbitrary file-size limits.

## Implementation Sequence

1. Reconcile M4 status and record this contract before changing ownership.
2. Establish the single embedded/dedicated authority-session path and independent
   60 Hz authority clock.
3. Route solo character, vehicle, and carry gameplay through the same semantic
   client/session messages and replicated presentation state.
4. Extract graphical, district-streaming, developer, and persistence owners from
   `App` with explicit teardown order.
5. Extract canonical value, snapshot-codec/preflight, diagnostic composition,
   and projection helpers behind the private authority boundary where ownership
   is materially clearer; retain live world composition, replay capture,
   restore, and ticking together.
6. Delete the broad solo forwarding facade without compatibility aliases.
   Historical phase-labelled products and acceptance targets may remain when
   they are outside the ownership boundary and still describe real evidence.
7. Add architecture, parity, order, failure-unwind, playable, and installed
   macOS gates and record the final M5 acceptance evidence.

## Deliberate Non-Goals

- A generic RPC or command bus.
- Automatic Flecs/component replication.
- A service locator or universal mutable engine context.
- A second Flecs/Jolt client world, full physics rollback, or peer lockstep.
- A scheduler rewrite or speculative parallel simulation.
- Jolt/feature-root decomposition unrelated to the ownership boundary.
- Steamworks, NAT/relay, listen-host productization, public hosting, accounts,
  Linux/Windows, or MMO operations.
- Mixed-version compatibility, deprecated facades, or migration shims.

## Definition of Done

- Embedded solo and dedicated placement use one authority-session behavior and a
  60 Hz authority clock.
- Character, vehicle, and carry gameplay cannot bypass semantic session
  admission locally.
- Network-replicated character, vehicle, carryable, and NPC presentation uses
  client replicated state rather than private authority views. Privileged crate
  authoring and logical district-streaming projections remain explicit host
  capabilities.
- Graphical and developer code cannot access Flecs, Jolt authority, private
  feature state, canonical save bytes, or save-slot commit directly.
- Persistence, replay, diagnostics, streaming, presentation, and authority each
  have an explicit owner or private responsibility boundary plus proportionate
  lifecycle tests.
- Tick/stage order and failure behavior are executable contracts.
- Session/reconnect credentials are unpredictable in operational constructors,
  identity-bound and one-time after confirmation; room configuration fails
  closed and a faulted authority refuses later operational mutation while
  still permitting diagnostics, transport closure, draining, and shutdown.
- Placement, authority, and nested runtime order are described and tested as
  separate owner traces; M5 makes no transactional eight-stage publication
  claim.
- Existing solo/editor/save/replay/streaming/diagnostic behavior and the complete
  M4 two-client foundation remain playable and green.
- Architecture and correctness review leaves no unrecorded actionable P0, P1,
  or P2 issue in M5 scope.

The completed evidence is recorded in
[`M5 Client/Authority Cohesion Acceptance`](../validation/m5-client-authority-cohesion.md).
