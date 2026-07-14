# MP6 Playable Multiplayer Room Flow

**Status:** Implemented, independently reviewed, and accepted

**Date:** 2026-07-14

**Prerequisites:** Accepted M4/M5 multiplayer foundation and accepted M6
transactional authority cycle

**Current platform scope:** Apple Silicon macOS only; Linux/SteamOS and Windows
remain deferred product ports and add no requirements to this design.

**Accepted room core:**
[`MP5 Open Room and Admission Boundary`](mp5-open-room-and-admission-boundary.md)

**Acceptance record:**
[`MP6 Playable Multiplayer Room Flow Acceptance`](../validation/mp6-playable-multiplayer-room-flow.md)

## Outcome

Expose the existing bounded MP5 room/admission core as a complete graphical
create, join, ready, connect, synchronize, play, reconnect, leave, drain, and
close experience. The phase must be playable by two graphical clients on one
Mac and must preserve the same authority and protocol semantics in embedded,
constrained listen, and dedicated placements.

MP6 is product flow over the accepted open engine. It does not add Steamworks,
NAT traversal, public matchmaking, server orchestration, or host migration.

## Ownership

Four owners remain distinct:

1. The room registry owns discovery membership, readiness, route, bounded
   invitation state, and signed join authorization. It owns no gameplay.
2. A client room coordinator owns one asynchronous operation, cancellation
   generation, retry policy, and a read-only presentation model.
3. The authority session validates final admission and exclusively owns
   participants, simulation, replication, persistence source, and gameplay.
4. Room presentation renders status and submits typed user intents. UI
   callbacks do not mutate the registry or authority directly.

Lobby/provider loss after admission does not invalidate a healthy gameplay
connection. Lobby departure and network loss remain different transitions.

## Client Coordinator State Machine

```text
idle
  -> creating | joining
  -> in_room
  -> ready
  -> resolving_route
  -> connecting
  -> authenticating
  -> synchronizing
  -> playable
  -> reconnecting -> playable

any nonterminal state -> cancelling -> idle
any operation -> recoverable_failure | terminal_failure
playable -> leaving -> idle
host/authority -> draining -> closed
```

Every asynchronous attempt receives a nonzero generation. A callback,
transport event, authorization result, or timeout from an older generation is
diagnostic-only and cannot mutate the current attempt.

`ready` is per-member intent to load and connect. It is not a global
match-start barrier: the GTA-style sandbox remains join-in-progress while an
individual member resolves, loads, and synchronizes.

## Playable Placements

### Embedded solo

Solo remains one graphical client using the typed local link to the shared
authority behavior. MP6 may present it in the same front end but may not add a
direct authority bypass.

### Constrained private listen

`Create Private Room` starts one embedded authority with both:

- the host client attached through the typed local link; and
- one GNS listen route for remote guests on localhost or a trusted LAN.

This is the first executable listen placement and proves simultaneous local and
remote participants in one authority. It is deliberately not public Internet
productization: no host migration, NAT traversal, relay, Steam identity,
untrusted public exposure, or fairness equivalence with dedicated authority is
claimed.

If the host closes or faults, the authority performs its defined healthy drain
and optional durable-capture disposition, then the room ends. It does not elect
another host.

### Dedicated direct IP

The existing cold authority remains the canonical server topology. The same
graphical join flow resolves a direct endpoint and signed authorization, then
uses the existing GNS client path. A manually launched local dedicated process
remains a supported developer/test route; MP6 does not add an allocation
service merely to hide process startup.

## User-Facing Contract

The first UI exposes:

- solo;
- create private localhost/LAN room;
- join direct endpoint/invite;
- member list and each member's ready/connection state;
- ready/connect, cancel, leave, reconnect, and close-room actions;
- distinct connecting, authenticating, synchronizing, and playable progress;
- actionable semantic failures; and
- development impairment selection without exposing raw transport internals.

User-facing failures are typed values such as room missing, invite expired,
room full, version/content mismatch, authority unavailable, authorization
rejected, timeout, reconnect expired, and host closed. Raw GNS codes and debug
strings remain structured diagnostics.

No admission secret, reconnect credential, complete signed authorization, or
Steam/provider credential may enter UI state, ordinary logs, replay, or crash
summaries.

## Steam-Compatible Boundary

Steam lobby and invite callbacks may later translate to the same bounded room
intent, opaque route, external identity, and signed authority authorization.
They never become gameplay authority. The open-engine build, room coordinator,
direct-IP route, and tests remain complete without Steamworks.

Keeping a future Steam lobby open during gameplay is allowed for invitation and
presence purposes, but lobby membership does not replace authority participant
state or reconnect policy.

## Completed Implementation Sequence

1. Added the generation-safe client room coordinator and immutable presentation
   model over the implemented MP5 registry contract.
2. Added graphical solo/create/join/member/progress/failure/leave flows without
   exposing registry or authority mutation.
3. Composed one constrained listen owner that combines the shared embedded
   authority, host local link, and guest GNS listener with explicit teardown.
4. Routed the dedicated direct-IP product through the same coordinator states
   and semantic error mapping.
5. Added real-GNS two-client and deterministic impairment lifecycle scenarios.
6. Added installed graphical macOS create/join/play/reconnect/close evidence and
   retained the complete M6/M5/M4 regression.

## Acceptance

- One graphical client creates a private listen room and plays as the host.
- A second graphical client joins that authority over real GNS on the same Mac.
- Both clients can walk, drive, carry, stream districts, and observe relevant
  NPCs through the existing authoritative paths.
- A dedicated process supports the same graphical join/synchronize/play flow.
- Every asynchronous state can be cancelled; stale completions cannot affect a
  newer attempt.
- Invite expiry/replay, room full, wrong cohort, authorization failure,
  transport timeout, reconnect expiry, and host closure are actionable values.
- Leaving lobby/discovery state does not terminate a healthy gameplay
  connection; network loss retains eligible room membership and enters bounded
  reconnect.
- Closing the host room drains and terminates it without host migration.
- The network fault harness is selectable and remains bounded/reproducible.
- The open engine and complete MP6 acceptance run without Steamworks, a cloud
  service, or a second platform.

The linked acceptance record contains the final-tree automated, installed, and
manual playable evidence. The initial UX is intentionally developer-facing;
polished menu/social presentation remains product work, not an architectural
prerequisite.

## Explicit Deferrals

- Public Internet listen hosting, NAT traversal, relay, and Steam P2P/SDR.
- Steamworks identity, lobbies, overlay invites, and hosted-server tickets.
- Public room discovery, matchmaking, accounts, entitlements, and moderation.
- Host migration or transferable complete authority.
- Agones/Open Match, fleet allocation, autoscaling, and Linux deployment.

## Reference Influences

- [Steam matchmaking and lobbies](https://partner.steamgames.com/doc/features/multiplayer/matchmaking?language=english)
  separates lobby assembly/readiness from the subsequent host or game-server
  connection.
- [SteamNetworkingSockets](https://github.com/ValveSoftware/GameNetworkingSockets)
  remains the selected open message transport and not a room/gameplay service.
- [Agones GameServer lifecycle](https://agones.dev/site/docs/reference/gameserver/)
  is a later dedicated-fleet reference, not an MP6 dependency.
- [Open Match architecture](https://open-match.dev/site/v2/overview/) is a later
  ticket/assignment reference, not a reason to build matchmaking now.
