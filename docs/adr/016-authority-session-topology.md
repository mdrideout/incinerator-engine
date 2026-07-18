# ADR-016: Authority Session Topology and Solo as a Local Session

**Status:** Accepted

**Date:** 2026-07-13

**Platform:** Apple Silicon macOS architecture proof only

**Implementation:** The MP1 character seam, MP2 cold-authority placement, and
MP2.1/MP3 lifecycle, prediction, impairment, and accepted-ingress evidence were
implemented and audited on 2026-07-13. MP4-MP6, M5/M6, S10, and S11 later
completed the shared embedded/listen/dedicated authority boundary through
vehicle/carry/NPC replication, cohesive local authority, transactional
publication, room lifecycle, and authoritative combat.

**Amended:** 2026-07-15 after the S11 corrective review

## Context

The completed S0-S8/M3 program proves one fixed-tick `Simulation`, one owner
thread, one Flecs world, one Jolt world, feature-owned commands/state, durable
logical restore, bounded diagnostics/replay, and a cold headless product. The
graphical `App` currently owns that simulation directly, which is correct for
the completed local sandbox but leaves no client/authority boundary.

The likely product is now multiplayer-first: a player may play alone, host an
invite/party/room instance, join another authority, or eventually connect to a
dedicated/persistent service. If solo and multiplayer use different sources of
truth, every later gameplay feature must support two mutation, persistence,
and lifecycle models. Adding a server after those paths proliferate would be a
fundamental rewrite.

The current zflecs integration permits only one owned Flecs world per process.
The topology must incorporate that constraint honestly rather than assuming a
second full client world can coexist with an embedded authority.

**Accepted:** 2026-07-13 after multiplayer architecture and deployment review

**Transport/routing decision:**
[ADR-018](018-gamenetworkingsockets-and-steam-compatible-routing.md)

## Decision

### Authority is a role

One authoritative session owns canonical gameplay state in every mode. It owns
the fixed clock, `Simulation`, feature command admission, Flecs/Jolt mutation,
NPC behavior, ownership decisions, replication extraction, accepted-ingress
evidence, durable save, and orderly shutdown.

The graphical game is a client. It owns input capture, connection/session UX,
outgoing requests, non-authoritative replicated state, bounded prediction,
reconciliation, interpolation, camera, renderer, audio, and local UI. It cannot
mutate `Simulation`, Flecs, Jolt authority, or durable storage directly.

### Three placements share one semantic boundary

| Placement | Authority location | Client link |
|---|---|---|
| Solo | Embedded in the graphical process | Bounded typed local link |
| Listen/invite | Embedded beside the hosting player's client | Host uses local link; guests use network links; optional private topology |
| Dedicated | Cold headless process | Every client uses a network link; canonical public topology |

The local link may pass typed values without byte encoding or artificial
socket latency. It must not bypass participant identity, sequencing,
validation, eligibility, authority queue reservations, outcomes, or lifecycle.
Same architecture means the same semantics, not the same transport overhead.

### One authority world remains the initial process contract

An embedded/listen process owns one authoritative Flecs world. The client uses
a lightweight replicated-state store and presentation timeline, not a second
authoritative `Simulation`. Client prediction is a separate disposable model
and must not require a second full authority world initially.

If measured client prediction, editor previews, host migration, or another real
consumer requires multiple Flecs worlds, a later ADR may replace/fork zflecs or
move authority to a separate process. This decision does not hide that future
cost behind a speculative world abstraction.

### Session discovery is not authority

Lobby, invite, party, platform identity, relay, and instance-allocation
services locate and authenticate a session. They do not own ECS entities,
physics state, gameplay ownership, NPC decisions, or durable world state.

### Dedicated is canonical; listen hosting is optional

Dedicated authority is the canonical public multiplayer topology. It provides
stable simulation resources, a trusted persistence/interaction owner,
join/reconnect independent of a player's process, and no host migration
requirement. The first real network proof uses a dedicated macOS authority over
direct GameNetworkingSockets IP connections.

Listen hosting remains an acceptable optional topology for private friend
sessions. It gives the hosting player latency, availability, performance, and
trust advantages and is not equivalent to a fair dedicated server. Whether it
ships is deferred until the dedicated slice establishes product need.

Host migration is not part of the initial topology. If the listen authority
stops, the session stops after its defined drain/commit behavior. Adding host
migration would require transferable complete authority, connection
reassignment, security, and failure-consensus policy and therefore needs its
own approved phase.

Peer-to-peer may describe the route used to reach a listen authority. It never
means shared authority, peer lockstep, or a full mesh. Authority placement,
connection route, and identity provider remain independent as defined by
ADR-018.

### Initial room contract

- Product target: 2-8 participants; technical validation ceiling: 16.
- One authority owns one room/instance.
- Join-in-progress and bounded reconnect are required.
- A room does not span authority processes or provide a seamless MMO world.
- Solo, listen, and dedicated use the same semantic admission and replication
  rules.

## Ownership Boundaries

### Authority session owns

- admitted session/participant/connection mappings;
- command sequencing, validation, quota, and tick eligibility;
- one `Simulation` and every authoritative feature;
- outcome and replication routing;
- durable save and restore;
- accepted-ingress replay and network-facing authority diagnostics;
- graceful drain and session termination.

### Client owns

- platform/lobby UI and connection intent;
- physical input and local action mapping;
- outgoing input/command history;
- replicated entity views and snapshot baselines;
- local prediction, correction, and remote interpolation;
- content/GPU residency needed to present relevant state;
- camera, renderer, audio, editor/developer presentation, and local settings.

### Link/transport owns

- bounded delivery between one client and the authority;
- connection-oriented lifecycle as selected;
- reliable/unreliable message delivery capabilities;
- encryption/relay/statistics supplied by the selected adapter;
- no gameplay validation, feature mutation, persistence, or entity authority.

## Consequences

### Positive

- New gameplay has one source-of-truth model from the start.
- Solo remains offline-capable without becoming a separate gameplay path.
- The completed cold M3 product becomes the natural dedicated authority base.
- Listen and dedicated placements share gameplay and protocol semantics.
- Client prediction is visibly approximate rather than an accidental second
  authority.
- Existing typed commands, fixed ticks, persistence, districts, diagnostics,
  and replay remain useful foundations.

### Costs and risks

- `App` and `Simulation` require high-churn ownership decomposition before new
  gameplay work.
- Solo actions gain explicit session/admission machinery even when delivered
  locally.
- A listen host has unavoidable trust and latency advantages.
- One Flecs world limits client architecture options until a real need justifies
  replacement or process separation.
- Testing must cover solo, listen-local, remote-client, dedicated, reconnect,
  and shutdown placement without duplicating gameplay implementations.

## Alternatives Considered

### Keep direct local simulation and add multiplayer later

Rejected by this decision because gameplay would accumulate client-authority
assumptions, local-only save semantics, and direct feature access that later
networking must replace.

### Always run authority as a separate local process

This gives the strongest placement symmetry but adds process startup, IPC,
packaging, crash recovery, debugging, and offline UX cost to every solo run.
Keep it as a validation/deployment option, not the required initial solo path.

### Peer-to-peer shared authority or lockstep

Rejected. Jolt is not being treated as a cross-platform peer-lockstep state
machine, host trust still exists, persistence ownership becomes ambiguous, and
future MMO/dedicated aspirations require server authority.

### Replace zflecs immediately for multiple worlds

Rejected until MP1-MP3 prove a client need for a full second Flecs world. A
lightweight replicated client store preserves the authority boundary with less
scope.

## Deferred and Follow-up Decisions

1. Whether listen hosting ships or remains development/private-only.
2. Exact reconnect window, empty-room lifetime, and persistence cadence.
3. Whether a running solo session may promote itself to a listen session.
4. Which editor/developer tools attach to authority, client, or both.
5. Hosting provider and eventual Linux/SteamOS dedicated deployment.
6. Cross-authority world partitioning, which is outside the initial room model.

## Acceptance Evidence Required

ADR acceptance is not implementation completion. MP1 must subsequently prove:

- existing solo behavior through a local client/authority link;
- no direct graphical mutation of authority or durable storage;
- one embedded authority world and lightweight client state;
- the same semantic admission through local and test-network links;
- a cold dedicated authority with no visual/client dependencies;
- lifecycle, save/restart, replay, diagnostics, editor, package, and macOS gates
  remain healthy.
- two remote clients reach one dedicated macOS authority over the
  ADR-018-selected direct GNS route before listen/P2P product work.
