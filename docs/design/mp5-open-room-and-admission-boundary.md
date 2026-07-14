# MP5 Open Room and Admission Boundary

**Status:** Open-engine scope implemented and accepted

**Date:** 2026-07-14

MP5 introduces bounded room discovery and identity-bound admission without
making a lobby, Steam, or any future service the gameplay authority.

## Implemented core

- A fixed-capacity room registry models create, invite, join, ready, connect,
  failure, lobby leave, network disconnect/reconnect, drain, and close.
- Placement (`embedded`, `listen`, `dedicated`), route (`local`, direct GNS IP,
  or opaque Steam join reference), and identity provider are independent tagged
  values. Provider handles never become entity, persistence, or physics IDs.
- Direct endpoints and member/room counts are bounded. Stale room handles use a
  generation and fail closed.
- A join authorization binds room ID/generation, target authority, account,
  external identity, expiration, and nonce. HMAC-SHA-256 authenticates the
  bounded development/service handoff. The authority validates it before
  allocating any participant state.
- Invitations are one-use in the registry, and each authority retains a
  fixed, expiry-aware nonce history so a consumed authorization cannot create
  another participant lifecycle during its validity window.
- Room admission must use the timestamped ingress entry point. The network or
  service owner supplies monotonic Unix time; deterministic simulation ticks
  are never misused as a distributed credential clock, and untimestamped room
  admission fails closed.
- Lobby departure and transport loss are deliberately nonidentical. Leaving a
  lobby does not terminate a healthy gameplay connection; network loss keeps
  lobby membership and enters the existing bounded reconnect path.
- Once admitted, a healthy authority has no dependency on registry/service
  availability.

## Steam boundary

The open core contains only `IdentityProvider.steam` and an opaque Steam route
reference. It does not contain Steamworks headers, SDK binaries, credentials,
callbacks, or platform types. A separately distributed optional adapter may
translate authenticated Steam lobby/ticket results into this exact join
contract and the existing GNS transport family.

This is an intentional boundary, not an incomplete attempt to reimplement
Steam. The proprietary adapter cannot be completed or validated without the
game's Steamworks setup and remains a product integration phase. Direct-IP
rooms and development identities are fully testable without it.

## Placement limits

Dedicated direct IP is the executable multiplayer path. Embedded solo already
uses the local semantic boundary. Listen is represented in the same placement
and room contract, but private-listen productization, NAT traversal, relay,
Steam P2P, and host shutdown UX remain deferred as previously accepted. Host
migration is not implied.

## Security boundary

The HMAC proof authenticates a handoff from a trusted room issuer holding the
authority secret. It does not provide accounts, entitlement, anti-cheat,
moderation, replay protection across a distributed fleet, or secret rotation.
Those require an actual online service threat model before public deployment.
