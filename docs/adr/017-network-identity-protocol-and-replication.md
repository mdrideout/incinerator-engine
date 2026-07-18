# ADR-017: Network Identity, Protocol, Replication, and Client Approximation

**Status:** Accepted

**Date:** 2026-07-13

**Platform:** Apple Silicon macOS architecture proof only

**Implementation:** The bounded identity/codec/full-character-snapshot subset
was implemented and audited in MP0-MP2 on 2026-07-13. MP3/MP4 subsequently
completed prediction, delta baselines, interest management, accepted-ingress
replay, and feature projections. M5/M6/MP6/S10/S11 retain those boundaries
through embedded/listen/dedicated cohesion, transactional publication, player
lifecycle, and NPC combat. Protocol revision 13 is current.

**Amended:** 2026-07-15 after the S11 corrective review

## Context

Incinerator already has persistent logical identities, process-local runtime
and physics handles, feature-owned typed commands/outcomes, a canonical durable
snapshot, same-cohort semantic replay, exact content fingerprints, and bounded
external producer routing. None of those is by itself a multiplayer protocol.

Remote clients introduce untrusted bytes, connection churn, participant
ownership, duplicates, loss, reordering, stale input, per-client relevance,
bandwidth limits, prediction, correction, and short-lived replication
baselines. Reusing durable save bytes, raw ECS components, Jolt state, runtime
handles, or the M3 synthetic-producer router as a general network layer would
conflate incompatible lifetimes and trust models.

**Accepted:** 2026-07-13 after multiplayer architecture, transport, and
deployment review

**Transport/routing decision:**
[ADR-018](018-gamenetworkingsockets-and-steam-compatible-routing.md)

## Decision

### The server is the only gameplay authority

Clients send intent and commands, never canonical poses, ownership, completed
ticks, NPC decisions, identity allocation, or durable state. The authority
validates connection, participant, sequence, ownership, state preconditions,
capacity, and tick eligibility before translating a protocol message into a
semantic feature/session command.

Client state is an approximation. Locally predicted state is disposable and
reconciled to acknowledged authority. Remote entities are interpolated from
server snapshots. Neither path can be saved as canonical state or feed server
authority without a validated command.

### Identity is layered by lifetime

| Identity | Lifetime and owner | May cross network? |
|---|---|---|
| `AccountId` | Durable engine/game player identity; mapped from an external provider such as Steam | Yes, only where admission/persistence requires it |
| External identity | Steam or future platform/account credential | Only through authentication/admission; never an entity handle |
| `PersistentId` | Durable logical world identity, authority-owned | Only through a deliberate semantic mapping; not the default entity handle |
| `RuntimeId` | One authority process/runtime | Never |
| Jolt/Flecs/GPU handles | Backend/process lifetime | Never |
| `SessionId` | One admitted game session | Yes, protocol-scoped |
| `ParticipantId` | One logical joined player in a session | Yes |
| `ConnectionId` | One generational live link | Internal/diagnostic or protocol token as selected; never gameplay identity alone |
| `ReplicatedEntityId` | Server-issued generational visible entity reference | Yes |
| `InputSequence` | Per participant/control stream | Yes |
| `SnapshotSequence` | Per connection replication stream | Yes |

Platform account/Steam identity may authenticate or discover a participant but
does not become an ECS, persistence, physics, or replicated entity identifier.
Reconnect may replace a connection while retaining or deliberately replacing a
participant according to session policy.

### Protocol messages are explicit, bounded, and versioned

The protocol has an exact cohort containing at least:

- protocol schema/version;
- engine/game build identity;
- authoritative schedule/simulation cohort as required;
- logical content/catalog fingerprint;
- feature protocol capabilities actually supported by the session.

Every message has bounded encoded size, counts, strings, collections, and
decode work. Unknown, malformed, oversized, incompatible, stale, duplicate,
unauthorized, over-quota, and wrong-state messages have explicit admission or
disconnect policy and cannot partially mutate authority.

The first message set is semantic and narrow: handshake/admission,
join/leave/reconnect, tick-addressed player input, command result, initial
state, incremental state, lifecycle/ownership event, snapshot acknowledgement,
and graceful disconnect.

The handshake admits an exact protocol/build/content cohort and a bounded join
authorization tied to the target session/authority, participant or external
identity, expiration, and nonce/generation. Transport encryption and Steam
authentication do not independently authorize gameplay membership.

There is no generic RPC system, generic event bus, or reflection-driven
component replication.

### Durable, replication, prediction, and replay schemas are distinct

`SnapshotV11` is the current complete canonical durable record. It is not sent
as a join snapshot or reused as the replication wire schema.

A replication snapshot is assembled per connection from explicit
feature-owned records after a completed authority tick. It may be partial,
relevance-filtered, quantized, rate-limited, delta-compressed, and based on a
short-lived acknowledged baseline. Those losses never enter durable state.

Prediction history is client-owned bounded input and approximate local state.
It is discarded after acknowledgement/correction and is never a server save or
replication source.

Accepted-ingress replay records semantic authority admission with participant,
input/transaction sequence, eligible/applied tick, command, and result class.
Raw packets, encryption frames, retransmissions, and lobby events are not the
canonical gameplay replay stream.

### Replication remains feature-owned

Each network-participating feature defines:

- client request/input values;
- authority validation and ownership rules;
- replicated state value(s) and quantization/rate policy;
- reliable lifecycle/ownership events, if required;
- client interpolation and optional prediction policy;
- bounded encode/decode and per-client memory budgets;
- headless authority, codec, impairment, and lifecycle tests.

The session layer owns connection-specific sequencing, baselines, relevance,
budgets, and routing. It does not inspect or expose private ECS components.

### Interest starts with district ownership

The first relevance model uses admitted district coordinates, residency, and
feature-owned district ownership. A participant receives its controlled state,
required session state, and relevant entities/district lifecycle within a
bounded neighborhood or explicit dependency closure.

This is not a generic spatial database or final MMO interest system. Per-client
entity, byte, event, snapshot, and baseline ceilings are part of acceptance.
The initial model combines spatial/district cells with semantic dependencies
such as controlled entities, vehicle occupants, mission relationships, recent
interactions, and threats. Distance alone is not a complete relevance rule.

### Physics uses snapshots, prediction, and reconciliation—not lockstep

The authority alone advances canonical Jolt state. Initial client prediction
targets the locally controlled character and may later include the locally
controlled vehicle only after measured need. Other physics entities are
interpolated from server state.

Snapshots acknowledge processed input. The client rewinds/corrects its
supported prediction state and reapplies still-eligible unacknowledged input.
Hard correction, smoothing, ownership loss, district unavailability, and
teleport policies are explicit. No cross-machine bit-identical Jolt or peer
rollback guarantee is implied.

### Transport is an adapter, not the protocol or replication model

The selected transport may provide connection handles, reliable/unreliable
delivery, encryption, fragmentation, congestion behavior, relay/NAT traversal,
impairment, and statistics. Incinerator still owns semantic messages,
validation, entity identity, authority, replication, interest, prediction,
persistence, and replay.

Local delivery implements the same semantic protocol interface without being
forced through encoded packets. A network codec must nevertheless be tested
independently and through real process boundaries.

ADR-018 selects the open-source GameNetworkingSockets flat C API for the first
remote path, direct IP for the initial two-client proof, and a later optional
Steamworks flat-API adapter for Steam P2P/SDR compatibility. This selection does
not widen the session layer into a provider-neutral networking framework.

### Initial rates and delivery classes

The initial measured starting contract is 60 Hz authoritative gameplay/physics,
20 Hz replication with per-entity/client prioritization, and client
render/prediction up to 120 Hz. AI and population work use lower relevance-
dependent rates rather than inheriting the main authority frequency. Evidence
may revise these values; the rates are not performance claims.

| Message class | Initial delivery policy |
|---|---|
| Recent tick-addressed input | Unreliable and replaceable, with bounded redundancy |
| Replication snapshots | Unreliable and application-sequenced |
| Gameplay lifecycle/results | Reliable |
| Handshake/admission/loading/disconnect | Reliable and highest priority |

Snapshots retain explicit server tick, snapshot sequence, baseline identity,
and processed-input acknowledgement. Stale state is discarded instead of
being made reliable merely to guarantee eventual delivery.

## Authority Pipeline

```text
receive bounded bytes / local typed message
  -> decode and structural validation
  -> cohort and connection validation
  -> participant, sequence, ownership, state, and quota admission
  -> reserve authority/result capacity
  -> enqueue semantic session/feature command for an eligible tick
  -> run authoritative fixed-tick simulation
  -> route outcomes and lifecycle events
  -> extract per-client relevant replication records
  -> encode/send within snapshot and bandwidth budgets
  -> record accepted semantic ingress and diagnostics
```

Transport threads or callbacks may append bounded copied envelopes. They do
not access ECS, Jolt, feature state, durable storage, renderer, editor, or
client prediction directly.

## Consequences

### Positive

- Durable recovery remains canonical and independent of bandwidth choices.
- Features retain vertical ownership instead of leaking components to a global
  replicator.
- Remote ingress has explicit trust, sequencing, and capacity boundaries.
- Solo local delivery and remote transport share semantics without unnecessary
  packet overhead.
- District ownership provides a concrete first interest-management consumer.
- Same-cohort replay can diagnose authority behavior without promising packet
  or cross-platform physics determinism.

### Costs and risks

- Explicit feature codecs/projections add work to every networked gameplay
  slice.
- Baseline acknowledgement, reconnect, and ownership transfer require careful
  bounded lifecycle design.
- Prediction will duplicate a deliberately small part of movement behavior on
  the client and must be kept subordinate to authority.
- Exact-cohort rejection accelerates development but prevents mixed-version
  sessions until a future compatibility promise and migration policy exist.
- District relevance may be insufficient for dense scenes and will need
  measured refinement.

## Alternatives Considered

### Replicate raw Flecs components automatically

Rejected. It exposes private storage, couples protocol stability to component
layout, weakens feature ownership, and makes per-feature security/relevance/
quantization policy implicit.

### Send durable snapshots for join-in-progress

Rejected. Durable saves contain complete canonical recovery state, while a
client requires bounded relevant presentation/gameplay state with different
trust, bandwidth, and lifetime.

### Trust client physics and periodically validate

Rejected for canonical gameplay. It makes ownership, collisions, interactions,
NPCs, and persistence vulnerable to divergence or manipulation and conflicts
with the future dedicated/MMO direction.

### Full deterministic lockstep or complete-world rollback

Rejected for the initial product. It would require a substantially different
physics/determinism contract, complete rollback state, and strict cross-client
execution guarantees not provided by the current architecture.

### General network abstraction before selecting a transport

Rejected. Define the semantic protocol/session boundary first, then adapt the
one selected transport plus the proven local link. Additional abstraction
requires a second real transport consumer.

## Follow-up Measurements and Decisions

1. Per-client relevant entity/byte scale within the accepted 2-8 player target
   and 16-participant validation ceiling.
2. Input batching, server input-delay, stale-window, timeout, and reconnect
   policies.
3. Initial position/rotation/velocity quantization and bandwidth ceilings.
4. Full versus delta snapshot sequence and baseline recovery strategy.
5. Character prediction model and correction thresholds.
6. Whether vehicle prediction enters MP3 or MP4 after measured need.
7. Exact build/content/protocol cohort fields and development override policy,
    if any.
8. Steam identity/lobby/SDR integration timing after the direct GNS proof.

## Acceptance Evidence Required

ADR acceptance is followed by MP2-MP4 implementation evidence:

- hostile codec/preflight tests for every bound and state transition;
- two-client join/input/snapshot/disconnect/reconnect behavior;
- stale/duplicate/reordered/unauthorized/over-quota rejection without partial
  mutation;
- deterministic impaired-link tests and measured RTT/jitter/loss/bandwidth/
  correction budgets;
- server-only durable commit and restart;
- accepted-ingress replay and first-divergence evidence;
- per-client interest and baseline ceilings;
- cold authority source/import/linkage/package isolation from client, renderer,
  editor, visual content, and lobby SDKs.
