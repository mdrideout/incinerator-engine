# ADR-018: GameNetworkingSockets and Dedicated-First Steam-Compatible Routing

**Status:** Accepted

**Date:** 2026-07-13

**Platform:** Apple Silicon macOS implementation proof; production deployment
platform remains deferred

**Implementation:** Open-source GameNetworkingSockets 1.5.1 is exact-pinned,
built from source, and proven through direct loopback with two clients and one
cold authority as of 2026-07-13. MP6 later adds constrained graphical listen
and ticketed dedicated lifecycle proofs over the same local/direct-GNS split.
Steamworks/P2P/SDR remain absent and deferred.

**Amended:** 2026-07-15 after MP6/S11 documentation reconciliation and the
post-IV graphical catch-up audit

## Context

ADR-016 establishes one server-authoritative session for solo, listen, and
dedicated placement. ADR-017 establishes an Incinerator-owned semantic
protocol, explicit network identities, feature-owned replication, and
non-authoritative client prediction. The remaining transport decision must fit
Zig, retain an open-engine core, support direct dedicated servers, and preserve
a practical path to Steam identities, invitations, peer rendezvous, and Steam
Datagram Relay (SDR).

The terms "peer-to-peer" and "dedicated" describe connection route or authority
placement, not two competing gameplay authority models. A listen host reached
through Steam P2P still runs the one authoritative session. Incinerator will
not implement shared peer authority, peer lockstep, or a full mesh.

Valve's open-source
[GameNetworkingSockets](https://github.com/ValveSoftware/GameNetworkingSockets)
provides a message-oriented connection API, reliable and unreliable delivery,
fragmentation, encryption, lanes, impairment/statistics, IPv6, ICE, custom
signaling, and a flat C interface suitable for Zig. It intentionally mirrors a
subset of the Steamworks `ISteamNetworkingSockets` API. Steamworks supplies
additional proprietary identity, signaling, lobby, authentication, and SDR
services, and exposes a
[C-linkage flat API](https://partner.steamgames.com/doc/sdk/api) for language
bindings.

## Decision

### GameNetworkingSockets is the selected network transport

The first remote transport is the open-source GameNetworkingSockets flat C
API. Incinerator will write one narrow, owned Zig binding for the selected
surface instead of importing a broad wrapper or designing a provider-neutral
networking framework.

GameNetworkingSockets owns connection transport, delivery modes, encryption,
fragmentation, lanes, impairment, and connection statistics. It does not own
Incinerator messages, admission, identity lifetimes, authority, replication,
interest management, persistence, prediction, or replay.

### Authority placement, route, and identity remain independent

| Concern | Initial values |
|---|---|
| Authority placement | `embedded`, `listen`, `dedicated` |
| Connection route | `local`, `direct_ip`, `steam_p2p`, `steam_sdr` |
| Identity provider | `development`, `steam`, future engine/account identity |

The initial supported combinations are deliberately staged:

| Product path | Placement | Route | Policy |
|---|---|---|---|
| Offline solo | Embedded | Local typed link | Required |
| First two-client proof | Dedicated macOS authority | GNS direct IP/loopback | Required |
| Community/self-hosted instance | Dedicated | GNS direct IP | Intended baseline; hosting provider independent |
| Private Steam invite | Listen | Steam P2P/SDR | Optional later product path |
| Public Steam room | Dedicated | Direct IP first; hosted SDR when available | Canonical public topology |

Dedicated authority is canonical for public multiplayer because the sandbox
needs stable CPU/bandwidth for Jolt, NPCs, and traffic; one trusted writer for
interactions and persistence; join/reconnect independent of a player's
machine; and no host migration. Listen hosting may be added for private friend
sessions, with explicit host trust, availability, performance, and latency
advantages. If a listen host leaves, the initial session ends after its defined
drain/commit behavior.

No cloud vendor, game-server orchestrator, Linux deployment, or commercial
hosting service is selected by this decision. A dedicated authority may run on
a developer Mac, community machine, rented VM, or later managed fleet.

### Direct IP is the first network route

MP2 uses the open-source library's ordinary IP listen/connect path across real
process boundaries on macOS. This proves the game protocol and authority
without Steam availability, lobby state, relay approval, NAT traversal, or a
hosting provider.

Direct IP remains a supported path for local development and independently
hosted servers. It is also the fallback architecture if a proprietary platform
service is unavailable. IP exposure, DDoS protection, public server discovery,
and proxying remain deployment concerns to address before a public service,
not reasons to couple gameplay to Steam.

### Steam is an optional integration, not the engine's source of truth

A later `GnsSteamTransport` implementation may use the Steamworks flat API for
Steam identities, P2P rendezvous, SDR, and hosted-dedicated tickets while
running the same Incinerator protocol and authority session as direct GNS.

Steam lobby or party state may advertise an opaque room/join reference. It
does not own world state, ECS entities, physics, ownership, NPC decisions,
durable saves, or participant admission. A Steam identity is mapped to an
Incinerator account/participant identity and is never a Flecs, Jolt,
persistence, or replicated-entity handle.

The Steamworks SDK and live Steam services are proprietary. They are accepted
only as an optional game/platform integration boundary required for Steam
network compatibility:

- the open engine must build, test, run solo, and run direct GNS without the
  Steamworks SDK;
- Steamworks headers, private SDK material, credentials, and service keys are
  not vendored into the open-engine core;
- the separately licensed game or an optional integration package supplies
  the Steam adapter and SDK location;
- the cold authority has no mandatory Steam, lobby, renderer, or client
  dependency;
- distribution terms and third-party notices must be reviewed before release.

The shared API heritage reduces integration risk but is not treated as proof
that every open-source/Steamworks binary, authentication mode, or connection
route is interchangeable. Direct-IP and Steam-backed combinations require
explicit compatibility tests.

### The transport seam stays narrow

The semantic session layer needs only operations equivalent to:

```text
listen(endpoint)
connect(endpoint)
poll events
send(connection, lane, bounded bytes)
close(connection, reason)
query connection statistics
```

Endpoints are a tagged value such as local, IP address, Steam identity, or
hosted-server ticket. GNS/Steam handles, callbacks, addresses, and identities
remain private to their adapter.

One network owner pumps callbacks and connection state independently of world
loading. It copies validated bounded envelopes into authority/client queues.
Transport callbacks never access Flecs, Jolt, features, persistence, renderer,
editor, or client prediction directly. Queue capacity, overflow, disconnect,
and shutdown behavior are explicit and observable.

Graphical catch-up may place several tick-addressed input samples in GNS while
an authority process is temporarily starved. Listen and dedicated adapters
therefore share one authority-tick ingress budget: after admitting the declared
per-connection input allowance they leave later GNS messages queued until the
next authority tick. They do not drop those samples, increase the quota, or
reinterpret their target ticks. The authority independently enforces the same
quota and remains the untrusted-ingress safety boundary. This separates
transport backlog pacing from semantic admission and prevents an ordinary host
stall from being misclassified as a malicious quota violation.

### Initial lane contract

| Lane/class | Delivery policy | Intended contents |
|---|---|---|
| Input | Unreliable, replaceable, redundant recent frames | Tick-addressed player input and acknowledgement context |
| Snapshot | Unreliable, application-sequenced | Relevant poses, velocities, state deltas, processed-input acknowledgement |
| Gameplay | Reliable | Spawn/despawn, ownership, interactions, damage/inventory results |
| Control | Reliable, highest priority | Handshake, admission, loading, reconnect, graceful disconnect, protocol failure |

Application messages retain their own tick, sequence, baseline, bounds, and
stale policy. Transport reliability or message order does not replace the
Incinerator protocol state machine. Stale state snapshots are never made
reliable merely to guarantee eventual delivery.

### Admission remains independent of encryption

GNS encryption protects a connection but does not authorize a participant for
a room. Admission binds a bounded join authorization to a session, participant
or external identity, target authority, expiration, nonce/generation, and exact
protocol/build/content cohort. Steam authentication or hosted-server tickets
may strengthen that flow without replacing the Incinerator session decision.

## Initial Product Contract

- Product target: 2-8 players in one room/instance.
- Technical validation ceiling: 16 participants.
- Join-in-progress and bounded reconnect: required.
- Dedicated authority: required for the first public multiplayer topology.
- Listen hosting: optional later private-invite topology.
- Host migration: deferred.
- Authority gameplay/physics starting rate: 60 Hz, subject to measurement.
- Replication starting rate: 20 Hz with per-entity/client prioritization,
  subject to measurement.
- Local render/prediction may run up to 120 Hz.
- Initial prediction: local character; locally driven vehicle only after
  measured need.
- Interest management: spatial/district cells plus semantic dependencies and
  explicit byte/entity budgets.

These rates are starting contracts, not performance claims. MP2-MP4 must
measure and revise them through an ADR or plan update if evidence requires it.

## Consequences

### Positive

- Zig integrates through a small C surface while the engine owns protocol
  semantics.
- The first proof has no Steam, lobby, cloud, NAT, or orchestration dependency.
- Steam P2P and dedicated SDR remain possible without making Steam canonical.
- Public dedicated, private listen, community-hosted, and offline solo paths
  share one authority and replication design.
- Direct hosting remains viable if Steam services are unavailable or the game
  ships elsewhere.

### Costs and risks

- Two small GNS initialization/integration paths must remain behaviorally
  compatible and tested.
- Steam P2P introduces proprietary service availability and an SDK/distribution
  boundary despite the open-source engine goal.
- Non-Steam P2P would require custom signaling, STUN, and relay fallback; relay
  bandwidth is an operational cost.
- Optimal Steam hosted-dedicated SDR may require a game coordinator, signed
  tickets, known data-center routing, and coordination with Valve/hosting
  providers, as described by the
  [Steam SDR dedicated-server flow](https://partner.steamgames.com/doc/features/multiplayer/steamdatagramrelay).
- Direct-IP public servers expose addresses and need later abuse/DDoS/proxy
  planning.

## Alternatives Considered

### Make listen/P2P the canonical product topology

Rejected for the public sandbox because host trust, departure, performance,
upload bandwidth, and migration would become primary world constraints. Listen
hosting remains an optional placement of the same authority.

### Require cloud-hosted servers immediately

Rejected. Dedicated authority is an architecture role, not a vendor. Local and
community direct-IP servers can prove the product before provider and fleet
selection.

### Use Steamworks networking exclusively

Rejected because the open-engine core, offline development, non-Steam builds,
and independently hosted servers must not require a proprietary SDK or live
service.

### Build a provider-neutral transport framework

Rejected. There is one selected network transport family plus the local link.
The narrow seam exists to isolate ownership and the optional Steam integration,
not to predict unrelated backends.

### Build non-Steam ICE/TURN before dedicated networking

Rejected until a real non-Steam listen-host product requires its signaling and
relay operating cost.

## Deferred Decisions

- Whether listen hosting ships or remains development/private-only.
- Steam lobby UX and whether an independent room service precedes it.
- Steam hosted-dedicated SDR eligibility, coordinator, provider, and rollout.
- Public server proxy/DDoS architecture.
- Non-Steam P2P signaling, STUN, TURN, and relay operation.
- Hosting provider, process supervisor, containers, Agones, and autoscaling.
- Linux/SteamOS dedicated deployment implementation.
- Account, entitlement, matchmaking, moderation, and anti-cheat services.

## Acceptance Evidence Required

- The open engine builds and passes its normal gates without Steamworks.
- Two macOS clients communicate with one cold authority over direct GNS.
- GNS callbacks remain outside authority state and continue during loading.
- Lane/class behavior survives bounded latency, jitter, loss, duplication,
  reordering, disconnect, and reconnect.
- Connection, queue, bandwidth, RTT, jitter, loss, snapshot-age, and rejection
  diagnostics are bounded and visible.
- Join-in-progress constructs relevant state without durable-save bytes.
- A later Steam proof runs the same protocol through the Steamworks flat API
  without leaking Steam types into features, replication, or persistence.
- Direct-IP and every supported Steam route have explicit compatibility and
  lifecycle tests rather than assumed interchangeability.
