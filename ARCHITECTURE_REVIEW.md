# Incinerator Engine Architecture Review

**Status:** Living assessment; MP0-MP3 are implemented and accepted for the
bounded character slice; residual MP1 cohesion and MP4+ pressure points are
recorded

**Last reviewed:** 2026-07-13

**Scope:** Current post-M3 architecture, its demonstrated strengths, its
structural weaknesses, and the pressure introduced by a likely
multiplayer-first product

**Related roadmap:** [`OVERHAUL_PLAN.md`](OVERHAUL_PLAN.md)

**Multiplayer strategy:** [`MULTIPLAYER_PLAN.md`](MULTIPLAYER_PLAN.md)

**Latest implementation audit:**
[`docs/validation/mp3-acceptance.md`](docs/validation/mp3-acceptance.md)

**Completed cleanup record:** [`CLEANUP_PLAN.md`](CLEANUP_PLAN.md)

## Purpose

This is the living architectural health record for Incinerator. It does not
replace phase acceptance evidence or ADRs. It answers a different question:
whether the code and product topology still express the intended architecture
well enough for the next material capability.

The review is updated when a new phase changes ownership, authority, process
topology, persistence, scheduling, or an important dependency boundary. A
finding is not resolved because a file was moved; it is resolved only when the
result has a clearer owner, dependency direction, lifecycle, and acceptance
test.

## Executive Assessment

The engine has a strong modern foundation. The original subsystem-oriented
prototype has been replaced by a thin feature-authoring kernel, vertically
owned gameplay features, explicit capability ports, fixed-tick authority,
presentation extraction, exact persistence/content cohorts, a cold headless
product, bounded diagnostics, and same-cohort replay.

The architecture is stronger than the physical source layout. `App`,
`Simulation`, the Jolt adapter, replay, and several feature roots now combine
too many private responsibilities in large files. Product and validation are
separate at the binary/reachability boundary, but some of that code remains
physically co-located. The current four-phase schedule is explicit at the
coarse level but relies on registration order within a phase. Flecs is safely
encapsulated, although current feature iteration uses private active arrays and
point access more than archetype queries or declared data access.

None of those findings invalidates the completed foundation. MP1-MP3 now prove
the graphical-client/authority boundary, direct GNS placement, bounded local
prediction, deterministic network impairment, and accepted-ingress replay for
the character slice. The next architecture pressure should come from MP4-A's
real vehicle ownership/replication slice rather than a broad file-only cleanup.

## Accepted Architectural Thesis

The accepted foundation remains:

1. A thin kernel owns lifecycle, schedule, identity, bounded mechanics, and
   diagnostics—not gameplay or backend policy.
2. Gameplay features own behavior end to end across commands, state, systems,
   persistence, presentation extraction, diagnostics, and tests.
3. Features depend on narrow capabilities; SDL, Jolt, storage, platform, and
   future transport integrations remain adapters.
4. One owner thread mutates one authoritative world. Workers publish bounded
   copied results and never mutate authority directly.
5. Rendering, editor UI, replay evidence, and future clients consume immutable
   projections or submit typed requests; they are not parallel authorities.
6. Shared infrastructure is extracted only from demonstrated consumers and
   retains domain-specific policy at its edge.

The accepted multiplayer refinement is:

> Authority is a role, not a machine. Solo, listen-hosted, and dedicated modes
> use the same authoritative session semantics with different links and
> process placement.

That refinement is described in accepted
[ADR-016](docs/adr/016-authority-session-topology.md) and
[ADR-017](docs/adr/017-network-identity-protocol-and-replication.md).
[ADR-018](docs/adr/018-gamenetworkingsockets-and-steam-compatible-routing.md)
selects the open-source GameNetworkingSockets flat C API, direct IP for the
first remote proof, dedicated authority as the canonical public topology, and
an optional non-vendored Steamworks adapter for Steam networking compatibility.

## Current Strengths

### Feature and dependency direction

- `src/root.zig` exposes a deliberately small backend-neutral engine surface.
- Feature implementations import the engine and explicit shared contracts,
  not SDL, ImGui, the renderer, raw Flecs, or JoltC.
- Raw JoltC access is isolated behind the engine-owned Jolt adapter and
  engine-defined handles/capabilities.
- The sandbox owns installed coordinates, routes, controls, and content policy;
  reusable district contracts own bounded structural values and validation.
- Editor mutations use the same typed authority commands as other producers.

### Authority, persistence, and lifecycle

- Runtime, persistent, physics, content, and presentation identities have
  explicit lifetimes and do not masquerade as each other.
- Dynamic physics owns simulation transforms; presentation reads interpolated
  previous/current state.
- Snapshot V7 is canonical logical state and contains no Flecs IDs, Jolt
  handles, GPU objects, borrowed pointers, or asynchronous worker ownership.
- Feature queues and external-producer paths are bounded with typed admission,
  reserved authority outcomes, and visible observational loss.
- The M3 authority validates configuration, content, and saves before acquiring
  the one Flecs/Jolt world, then drains and durably commits only healthy state.

### Observability and evidence

- Structured diagnostics preserve the immutable first authority fault.
- Replay records semantic authority ingress and reports category-first logical
  divergence within an exact build/content cohort.
- Physics visualization and profiling consume bounded immutable evidence and
  cannot mutate authority.
- Normal client, visual validation, cold authority, and extracted packages have
  separately verified membership and linkage boundaries.
- Debug, ReleaseFast, editor, native Metal, failure, lifecycle, packaging, and
  soak evidence exist for the current Apple Silicon macOS contract.

## Findings Register

Priorities describe the next multiplayer-first program, not regressions in the
already accepted S0-S8/M3 evidence.

| ID | Finding | Priority | Trigger / target | Status |
|---|---|---:|---|---|
| A-F001 | The legacy solo `App` still owns graphical, streaming, authoring, diagnostics, save policy, validation, and embedded-session administration; it no longer owns `Simulation` directly and the remote client has a clean boundary | P1 | Continue physical decomposition when MP4 supplies real feature/session consumers | Mitigated by MP1; open physical cohesion |
| A-F002 | `Simulation` is a broad internal authority facade combining composition, persistence, replay, extraction, diagnostics, and many feature re-exports | P1 | Split private responsibilities as MP4 materially changes each feature; retain one authority owner | Open |
| A-F003 | The Jolt adapter combines runtime/world, bodies, characters, vehicles, contacts, and debug extraction in one physical module | P2 | Before a multiplayer phase materially changes two or more physics concerns | Open |
| A-F004 | Feature root files combine public protocol, private components, systems, persistence, diagnostics, and extensive tests | P2 | Split a feature internally when its replication extension is added | Open |
| A-F005 | Schedule order inside each phase is registration order with no declared access or before/after constraint | P1 | MP1/MP2 authority ingress and replication boundaries | Open |
| A-F006 | The visual product had no client/authority separation or local-session seam; character input reached `Simulation` directly | P0 | MP1 | Resolved for the character slice: typed local session plus separate MP2 products |
| A-F007 | Client replicated-state, bounded prediction history, reconciliation, and remote interpolation owners exist without a second Flecs/Jolt world | P1 | MP3 | Resolved for character slice |
| A-F008 | Persistent/runtime and session/account/participant/connection/replicated/input/snapshot identities must remain distinct | P0 | MP0/MP2 | Resolved and contract-tested |
| A-F009 | The durable snapshot is suitable for restore but must not become a bandwidth-oriented network snapshot or protocol DTO | P0 | ADR-017 before protocol implementation | Guardrail recorded |
| A-F010 | Accepted character input now records participant, generational connection, sequence, target/admission tick, intent, and fingerprint and replays into a fresh authority with category-first divergence; later feature commands/rejections still need their own records | P1 | MP3 / expand per MP4 feature | Resolved for character input; feature expansion open |
| A-F011 | Feature iteration relies on private active arrays and point component access; city-scale query locality and parallel access are not demonstrated | P2 | Profile the first substantially larger replicated population before changing the model | Accepted pressure point |
| A-F012 | The zflecs cohort permits one owned world per process, constraining an embedded authority plus any future full client ECS | P1 | Accepted topology starts with one authority world plus lightweight client state | Accepted constraint |
| A-F013 | Engine/game dependency direction exists internally, but no separately built game package currently proves the intended open-engine/separate-game consumer boundary | P1 | First production game composition | Open |
| A-F014 | Validation and operational rigor have advanced faster than player-visible game depth, risking further infrastructure without product pressure | P1 | Every new shared abstraction must be pulled by MP1-MP4 or a real gameplay slice | Active guardrail |
| A-F015 | The engine has no selected license, third-party notice set, stable public API promise, or external consumer guide | Release | Before public distribution, not before multiplayer architecture work | Deferred by owner |

No finding authorizes a service locator, universal mutable context, generic
command bus, reflective ECS replication framework, speculative backend layer,
or platform expansion.

## Multiplayer Pressure on Existing Boundaries

### Source of truth

The authoritative world must remain the only source of gameplay truth in every
mode. A solo process may embed that authority, but the graphical client remains
a requester and approximate observer. Client prediction is disposable and
reconciled; it never becomes persistence or authority.

NPC decisions, physics, vehicle occupancy, carried-object ownership, district
ownership, spawn/despawn, and durable saves remain server-owned. Lobby and
party services discover or assemble a session; they do not own world state.

Dedicated authority is canonical for public multiplayer. Listen hosting is an
optional later private-friend placement with explicit host trust, performance,
latency, availability, and shutdown limitations. P2P may describe how guests
reach that listen authority; it never means shared authority or peer lockstep.

Authority placement (`embedded`, `listen`, `dedicated`), connection route
(`local`, `direct_ip`, `steam_p2p`, `steam_sdr`), and identity provider remain
separate concerns. This prevents Steam lobby/identity/routing decisions from
leaking into gameplay authority or persistence.

### One-world process model

The current one-Flecs-world rule fits a dedicated authority and can fit an
embedded/listen authority if the graphical client stores a lightweight
replicated scene rather than a second authoritative `Simulation`. A client
prediction world, editor preview world, hot authority replacement, or full
client ECS would require a later measured decision to replace/fork zflecs or
separate processes. The accepted MP0 topology makes that choice without
pretending the constraint does not exist.

### Persistence and replay

Durable saves, network snapshots, and replay envelopes serve different
lifetimes:

| Artifact | Owner | Purpose | Lifetime |
|---|---|---|---|
| Durable save | Authority | Canonical complete logical recovery | Across process/session restart |
| Replication snapshot | Authority per connection | Relevant approximate client state | Short-lived network baseline |
| Client prediction history | Client | Responsive local correction | Bounded recent ticks |
| Accepted-ingress replay | Authority evidence | Reproduce admitted semantic work | Exact diagnostic cohort |

They may share feature-owned value encoders only where their invariants are
actually identical. They must not share a wire envelope merely because all
contain entity state.

### Scheduling and threading

Network polling, decode, admission, authority ticks, replication extraction,
and send routing are host/session responsibilities around the existing runtime
phases. A transport callback cannot mutate ECS, Jolt, persistence, UI, or
renderer state. The first implementation should keep authority single-threaded
and make bounded queues visible before considering parallel simulation.

The selected GNS adapter has one explicit connection/callback owner. It pumps
independently of world loading and exchanges bounded copied envelopes with the
client/authority owners. No GNS or Steam handle, callback, address, or identity
enters Flecs, Jolt, a gameplay feature, persistence, or replication schemas.

## Recommended Cleanup Sequence

Architectural cleanup should be delivered through the multiplayer program,
not as an unbounded file-reorganization phase.

1. **MP0 records decisions and budgets — complete.** Topology, identity, protocol,
   dedicated-first placement, GNS, direct-IP-first routing, Steam compatibility,
   initial player scale, starting rates, impairment profiles, and per-client
   ceilings are recorded as initial contracts.
2. **MP1 separates owners — character seam complete.** The graphical client, authoritative
   session, and typed local link. Solo behavior must pass through the authority
   admission boundary without requiring a network socket.
3. **MP1 narrows physical composition — still open.** Split `App` into cohesive graphical,
   district-stream, developer-session, and local-authority owners; split
   `Simulation` persistence/replay/diagnostics into private modules behind a
   narrow authority facade.
4. **MP2 proves the boundary — character slice complete and audited.** Two clients connect to one authority with
   versioned admission, session identities, sequenced input, initial state,
   snapshots, interpolation, leave, and reconnect.
5. **MP3 adds responsiveness and fault evidence — complete for character.**
   Bounded prediction, reconciliation, impairment, quotas, network diagnostics,
   terminal lifecycle, and accepted-ingress replay are accepted.
6. **MP4 decomposes features when touched.** Add feature-owned replication for
   vehicles, interaction, districts, and NPCs while splitting only the feature
   internals materially changed.
7. **Reassess scale and ECS access.** Use measured replicated populations and
   snapshot budgets before adding Flecs queries, access declarations, or
   parallel scheduling.

## Architecture Definition of Done for the Multiplayer Foundation

- Solo, listen, and dedicated placement share one authority model.
- The visual client cannot mutate `Simulation`, Flecs, Jolt, or durable storage
  directly.
- The authority product can run without SDL, GPU, renderer, editor, visual
  content, lobby SDKs, or client prediction code.
- Local and network links deliver the same typed protocol semantics without a
  generic message bus.
- Durable and replicated state have separate schemas, limits, and validation.
- Session/network identity never leaks raw Flecs or Jolt handles.
- Prediction is explicitly non-authoritative and corrects from server state.
- Feature-owned replication does not expose private components or backend
  types.
- All remote ingress has bounded sequencing, ownership, quota, and outcome
  policy.
- Existing save, replay, diagnostics, package, and macOS readiness guarantees
  remain intact or are deliberately superseded by reviewed evidence.

## Explicit Non-Goals

- General-purpose engine networking or automatic component replication.
- Peer-to-peer or lockstep authority.
- Cross-platform deterministic Jolt simulation.
- Accounts, commerce, social graph, matchmaking backend, anti-cheat platform,
  distributed persistence, sharding, or MMO operations.
- Host migration before the initial session product requires it.
- Linux/SteamOS/Windows implementation during the macOS architecture proof.
- Multiple simultaneous authoritative worlds in one process.
- Mandatory Steamworks, lobby, SDR, cloud, or orchestration dependencies in the
  open engine or cold direct-GNS authority.

## Reference Influences

These are comparison points, not frameworks Incinerator promises to reproduce:

- [Flecs design guidance](https://www.flecs.dev/flecs/md_docs_2DesignWithFlecs.html)
  recommends feature-oriented modules, while the
  [systems/staging model](https://www.flecs.dev/flecs/md_docs_2Systems.html)
  documents deferred structural mutation and explicit sync behavior.
- [Bevy render extraction](https://docs.rs/bevy/latest/bevy/render/struct.Extract.html)
  provides a current example of read-only simulation-to-render-world
  extraction and independent presentation scheduling.
- [SDL GPU architecture](https://wiki.libsdl.org/SDL3/CategoryGPU) reinforces
  explicit command-buffer, pass, resource, fence, and submission ownership.
- [Jolt deterministic-simulation guidance](https://jrouwe.github.io/JoltPhysicsDocs/3.0.1/)
  motivates the exact-cohort replay nonclaims and server-snapshot approach
  rather than peer lockstep assumptions.

## Review Cadence

Update this document:

- when a multiplayer ADR is accepted, rejected, or superseded;
- at the close of every MP phase;
- when a finding changes priority or is resolved;
- before introducing a shared scheduler, replication, asset, physics, or
  service abstraction;
- when a separately licensed game consumer is created;
- before selecting a second platform or public engine license.
