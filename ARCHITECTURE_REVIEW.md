# Incinerator Engine Architecture Review

**Status:** Living assessment; MP0-MP5, the M4 Apple Silicon macOS multiplayer
foundation, and M5 client/authority cohesion are implemented and accepted

**Last reviewed:** 2026-07-14

**Scope:** Current post-M5 architecture, its demonstrated strengths, its
structural weaknesses, and the transactional authority pressure point planned
before further product expansion

**Related roadmap:** [`OVERHAUL_PLAN.md`](OVERHAUL_PLAN.md)

**Multiplayer strategy:** [`MULTIPLAYER_PLAN.md`](MULTIPLAYER_PLAN.md)

**Latest accepted foundation:**
[`docs/validation/m5-client-authority-cohesion.md`](docs/validation/m5-client-authority-cohesion.md)

**Accepted cohesion contract:**
[`docs/design/m5-client-authority-cohesion.md`](docs/design/m5-client-authority-cohesion.md)

**Recorded post-M5 pressure point:**
[`docs/design/post-m5-transactional-authority-cycle.md`](docs/design/post-m5-transactional-authority-cycle.md)

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

None of those findings invalidates the completed foundation. MP1-MP3 prove the
graphical-client/authority boundary, direct GNS placement, bounded local
prediction, deterministic network impairment, and accepted-ingress replay for
the character slice. MP4-A through MP4-E extend that model through authoritative
vehicles, carry interaction, district relevance, relevant NPC projection, and
acknowledged prioritized delta replication without generic ECS replication or a
client Flecs/Jolt world. MP5 adds bounded open room/admission semantics while
keeping Steamworks and service state outside gameplay authority. M4 accepts that
Apple Silicon macOS multiplayer foundation.

M4 intentionally did not reclassify the broad embedded-solo facade as complete.
M5 replaces its separate character dispatcher with one
opaque embedded placement over the shared authority core, routes character,
vehicle, and carry requests through session admission, renders those gameplay
surfaces from replicated client state, and moves durable commit plus district
streaming behind dedicated owners. It also removes the historical 120 Hz
mismatch: graphical embedded authority advances at the accepted 60 Hz,
independently paced from presentation, with 20 Hz replication. The complete
owner boundary, regression matrix, documentation, and independent review are
accepted in the M5 evidence record.

The accepted M5 tree records real nested placement, authority, and runtime phase
traces with an immutable first authority-cycle fault. It does not yet provide a
single atomic ingress-to-publication transaction. Mailbox batching, prepared
derivatives, atomic outbox publication, delivery leases, and a queued durable
decision are an explicit post-M5 pressure point rather than a completion claim.

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

### Multiplayer foundation

- The remote graphical client owns only protocol/session state, disposable
  prediction, replicated presentation, GNS transport, SDL input, and rendering;
  it has no authoritative Simulation/Flecs/Jolt world.
- The authority accepts bounded semantic character, vehicle, and carry requests
  and projects backend-neutral character, vehicle, carryable, district, and NPC
  state without automatic ECS replication.
- Acknowledged full/delta history, relevance, explicit removals, and overload
  degradation have declared per-client entity, byte, event, and memory budgets.
- Open room/invite admission binds external identity to a participant while
  keeping lobby/service state, Steamworks, and transport routes outside world
  authority.
- The aggregate M4 gate retains real two-client GNS, deterministic network
  faults, prediction/reconciliation, reconnect, accepted-ingress replay, cold
  authority, installed Metal, and architecture evidence.

## Findings Register

Priorities describe the next multiplayer-first program, not regressions in the
already accepted S0-S8/M3 evidence.

| ID | Finding | Priority | Trigger / target | Status |
|---|---|---:|---|---|
| A-F001 | The solo `App` remains the graphical composition root and retains presentation, input, authoring, and validation orchestration; embedded authority, district streaming, persistence, and developer state are separate opaque owners | P1 | Complete independent M5 review of cohesive graphical/developer/streaming/persistence/authority ownership | Resolved for M5; the graphical composition root is intentional and architecture-gated |
| A-F002 | `Simulation` remains a broad private live-authority facade; canonical DTOs and the durable snapshot codec/preflight are extracted, while live composition, restore, replay capture, ticking, outcomes, diagnostics, and queries remain together where they share the world | P1 | Keep the authority surface narrow; split only responsibilities that gain an independent lifecycle or consumer | Mitigated and accepted for current scope; retain as a measured pressure point |
| A-F003 | The Jolt adapter combines runtime/world, bodies, characters, vehicles, contacts, and debug extraction in one physical module | P2 | Before a multiplayer phase materially changes two or more physics concerns | Open |
| A-F004 | Feature implementation roots still combine private components, systems, persistence/restore, extraction, diagnostics, and extensive tests; canonical public value/protocol contracts are now extracted | P2 | Split only roots materially changed by M5 or the next gameplay slice; do not perform unrelated file-only churn | Partially mitigated; open measured pressure point |
| A-F005 | M5 makes placement, authority mutation, and nested runtime phase order executable with completion-aware traces and a retained first fault, but ingress admission, derivative preparation/publication, adapter delivery, and durable decision are not one atomic authority cycle; intra-phase feature order remains registration order | P1 | Post-M5 transactional authority-cycle plan; retain intra-phase scheduling as a separate measured pressure point | Partially mitigated; follow-up recorded |
| A-F006 | The visual product had no client/authority separation or local-session seam; character input reached `Simulation` directly | P0 | MP1 | Resolved for the character slice: typed local session plus separate MP2 products |
| A-F007 | Client replicated-state plus bounded character and owned-vehicle prediction/reconciliation exist without a second Flecs/Jolt world; remote vehicles remain interpolated | P1 | MP3 / MP4-A2 | Resolved and contract-tested through MP4-A2 |
| A-F008 | Persistent/runtime and session/account/participant/connection/replicated/input/snapshot identities must remain distinct | P0 | MP0/MP2 | Resolved and contract-tested |
| A-F009 | The durable snapshot is suitable for restore but must not become a bandwidth-oriented network snapshot or protocol DTO | P0 | ADR-017 before protocol implementation | Guardrail recorded |
| A-F010 | Accepted character, vehicle, enter/exit, and carry interaction ingress records participant, generational connection, sequence, target/admission tick, target entity, intent, and fingerprint and replays into a fresh authority; district/NPC autonomy is authority-owned rather than client ingress | P1 | Apply the same rule to every later client-originated feature request | Resolved for the complete M4 gameplay surface |
| A-F011 | Feature iteration relies on private active arrays and point component access; city-scale query locality and parallel access are not demonstrated | P2 | Profile the first substantially larger replicated population before changing the model | Accepted pressure point |
| A-F012 | The zflecs cohort permits one owned world per process, constraining an embedded authority plus any future full client ECS | P1 | Accepted topology starts with one authority world plus lightweight client state | Accepted constraint |
| A-F013 | Engine/game dependency direction exists internally, but no separately built game package currently proves the intended open-engine/separate-game consumer boundary | P1 | First production game composition | Open |
| A-F014 | Validation and operational rigor have advanced faster than player-visible game depth, risking further infrastructure without product pressure | P1 | M5 may extract only ownership required by the accepted boundary; later infrastructure must be pulled by a real product/gameplay slice | Active guardrail |
| A-F015 | The engine has no selected license, third-party notice set, stable public API promise, or external consumer guide | Release | Before public distribution, not before multiplayer architecture work | Deferred by owner |
| A-F016 | Vehicle exit needs bounded collision-safe placement and disconnect teardown even when every candidate is blocked | P1 | Resolve before district collision/relevance makes blocked exits routine | Resolved in MP4-A2: five deterministic candidates, then typed teardown-only release and immediate hidden-character despawn |
| A-F017 | At M5 entry, embedded solo owned a separate `Simulation` dispatcher and sent only character gameplay through the local protocol; M5 uses the shared authority behavior and routes character, vehicle, and carry gameplay through admission | P0 | M5 local/remote semantic parity and final regression | Resolved and accepted in M5 |
| A-F018 | Embedded solo advanced authority from the historical 120 Hz presentation accumulator while the accepted session authority was 60 Hz; its three-tick snapshot divisor therefore yielded 40 Hz rather than 20 Hz | P0 | M5 independent 60 Hz authority clock plus product-level cadence tests | Resolved: embedded authority is 60 Hz, replication is 20 Hz, and 80/240 Hz cadence contracts cover independent presentation |
| A-F019 | The M4 static check scanned one graphical client file for direct import names rather than proving the complete client-facing source/API closure | P1 | M5 transitive source-boundary and negative API checks | Resolved by the accepted M5 transitive architecture gate |

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
| Durable save | Authority snapshot source + persistence owner | Canonical complete logical recovery; authority captures, persistence owner encodes/commits | Across process/session restart |
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
2. **MP1 separates owners — historical character seam complete.** The
   graphical client, authoritative session, and typed local link became
   explicit; M5 owns the later whole-gameplay cohesion work.
3. **M5 completes embedded cohesion — complete and accepted.** M5 uses one
   embedded/dedicated authority behavior and
   60 Hz clock, routes local character/vehicle/carry gameplay through semantic
   admission, and introduces opaque streaming and persistence owners plus
   narrower private authority contracts and an opaque heap-stable developer
   owner. Aggregate regression and independent review are recorded in the
   acceptance evidence.
4. **MP2 proves the boundary — character slice complete and audited.** Two clients connect to one authority with
   versioned admission, session identities, sequenced input, initial state,
   snapshots, interpolation, leave, and reconnect.
5. **MP3 adds responsiveness and fault evidence — complete for character.**
   Bounded prediction, reconciliation, impairment, quotas, network diagnostics,
   terminal lifecycle, and accepted-ingress replay are accepted.
6. **MP4 decomposes features when touched — complete.** Vehicle, interaction,
   district, and NPC replication reuse explicit semantic feature surfaces
   without exposing private components or backend handles.
7. **MP5/M4 close the open multiplayer foundation — complete.** Open room
   admission, real-GNS placement, bounded relevance/deltas, and architecture
   evidence are accepted without proprietary service dependencies.
8. **Harden the authority transaction — planned after M5.** Freeze bounded
   ingress, separate admission from semantic work, prepare derivatives, publish
   outputs atomically, lease delivery, and queue durable decisions as specified
   in the
   [`Post-M5 Transactional Authority Cycle`](docs/design/post-m5-transactional-authority-cycle.md).
9. **Reassess scale and ECS access.** Use measured replicated populations and
   snapshot budgets before adding Flecs queries, access declarations, or
   parallel scheduling.

## Architecture Definition of Done Through M5

M4 satisfies the remote multiplayer foundation. M5 satisfies the embedded-
specific criteria below; the linked acceptance record contains the evidence.

- Embedded solo and dedicated placement share one authority model; listen-host
  productization remains a future placement of that model.
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
- The placement and authority traces prove their actual nested owner order,
  completed prefixes, and retained first fault without claiming one atomic
  eight-stage transaction.
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
