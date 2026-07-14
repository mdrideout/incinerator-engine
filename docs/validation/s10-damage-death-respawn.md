# S10 Damage, Death, And Respawn Acceptance

**Status:** Accepted

**Date:** 2026-07-14

**Platform scope:** Apple Silicon macOS only. Linux/SteamOS and Windows remain
deferred and provide no S10 abstraction, build, test, or compatibility gate.

**Design contract:**
[`S10 Damage, Death, And Respawn`](../design/s10-damage-death-respawn.md)

This record closes the first authoritative combat/lifecycle slice. It proves a
playable short-range melee cycle in solo-compatible authority code and in real
graphical listen and dedicated rooms. It does not claim firearms, rewind/lag
compensation, account persistence, public services, Steamworks, NAT traversal,
or broader respawn game policy.

## Feature And Authority Ownership

- [x] `features/vitals` owns bounded integer health, deterministic same-tick
  damage ordering, exact incarnation lookup, outcomes, diagnostics, canonical
  snapshot state, and exactly-once death facts for players and NPCs.
- [x] Clients submit melee and respawn intent only. Target selection, hit,
  damage amount, death, cleanup, spawn choice, and replacement incarnation are
  authority decisions.
- [x] Participant identity and connection survive avatar death. The physical
  avatar is disposable and every delayed action is checked against a nonzero
  incarnation.
- [x] Protocol revision 10 carries health, maximum health, life state, and
  incarnation in full/delta projection; welcome also carries the reconnecting
  participant's authoritative dead/alive state and avatar identity.
- [x] The solo, constrained-listen, and dedicated placements use the same
  authority, protocol client, admission, vitals, death, and respawn code.

## Damage And Death

- [x] The authority validates identity, monotonic action sequence, avatar
  incarnation, alive/vitals-ready state, target-tick window, and a 30-tick
  cooldown before admitting melee.
- [x] Closest-target selection is bounded and deterministic across living
  players and NPCs, uses authoritative facing/range, and asks the Jolt adapter
  for line-of-sight rather than accepting a client hit result.
- [x] Three hits apply `34`, `34`, then a clamped `32` against 100 health.
  Same-tick overkill cannot underflow health and emits exactly one death fact
  per incarnation.
- [x] Death immediately stops admission/control, clears client prediction, and
  reuses typed vehicle, carry, character, and possession teardown. The
  participant remains admitted while the physical avatar is removed.
- [x] NPCs register through the same vitals boundary, can be melee targets, and
  the canonical restart test proves a scripted NPC damage source against a
  player target.

## Reconnect And Respawn

- [x] Alive reconnect remains inherited from MP2-MP6. Focused S10 coverage
  disconnects a dead participant, reconnects it with the same participant and
  dead incarnation, and proves no implicit respawn.
- [x] Respawn requires an explicit newer action after a three-second authority
  cooldown and validates the dead incarnation and completed teardown.
- [x] A fixed eight-point sandbox catalog rotates deterministically by
  participant/incarnation. Jolt capsule overlap and explicit living-entity
  clearance reject blocked points; distance from threats scores remaining
  candidates with stable catalog order as the tie break.
- [x] No safe candidate yields `no_safe_spawn` and leaves the participant
  explicitly retryable in `respawn_pending`; a character-capacity rejection
  cannot publish a replacement incarnation or partial possession.
- [x] Accepted respawn creates a new avatar incarnation, resets the replication
  baseline and prediction, restores 100 health, and publishes reliable result
  and life event semantics.

## Delivery, Replay, Persistence, And Diagnostics

- [x] Melee result, respawn result, and life events use M6 reliable gameplay
  delivery IDs, cumulative application receipts, bounded reconnect replay,
  and idempotent client application.
- [x] Accepted ingress records melee/respawn categories and avatar incarnation.
  The replay adapter can reconstruct both intent types, and replay comparison
  now classifies player/NPC health, life-state, or incarnation mismatch as a
  vitals divergence.
- [x] Snapshot schema 8 canonically persists player/NPC vitals. A fresh
  simulation restart reproduces dead health/incarnation byte-for-byte. This is
  sandbox world state, not durable account death or progression policy.
- [x] Authority diagnostics expose alive/dead/spawning participants, admitted
  melee actions, hits, deaths, and respawns without exposing mutable state.

## Evidence Matrix

Final-tree commands and results:

| Evidence | Command | Result |
|---|---|---|
| Focused vitals, protocol, authority, client, and physics contracts | `zig build test-vitals-feature test-session-contracts test-physics -Deditor=false -j1 --summary failures` | Passed, including deterministic overkill, exact-one death, protocol rejection/round trip, dead reconnect, generational respawn, reliable replay, Jolt line query, and blocked capsule placement |
| Canonical restart | `zig build test-simulation -Deditor=false -j1 --summary failures` | Passed, including dead incarnation/vitals fresh restart and scripted NPC damage source |
| Graphical listen process | `zig build verify-s10-listen -Deditor=false -j1 --summary failures` | Passed with `S10_LISTEN_PROCESS_PASS graphical=2 host_local_link=true guest_real_gns=true damage=true death=true respawn=true` |
| Graphical dedicated process | `zig build verify-s10-dedicated -Deditor=false -j1 --summary failures` | Passed with `S10_DEDICATED_PROCESS_PASS graphical=2 real_gns=true damage=true death=true respawn=true` |
| Complete focused S10 aggregate | `zig build verify-s10 -Deditor=false -j1 --summary failures` | Passed: both installed graphical placements plus focused vitals/session/physics contracts |
| Preserved room/foundation regression | `zig build verify-mp6-room -j1 --summary failures` | Passed: MP6/M6/M5/M4, real GNS, source-package, cold-authority, editor-enabled native Metal, and gameplay inheritance remains green |
| Architecture and package boundary | `zig build verify-m5-architecture verify-m6-architecture verify-mp6-room-architecture verify-source-package -Deditor=false -j1 --summary failures` | Passed with the backend-only vitals dependency explicitly classified in the dedicated closure and S10 source/evidence retained in the filtered package |
| Formatting and patch hygiene | `zig fmt --check build.zig src tools` and `git diff --check` | Passed on the reviewed tree |

## Independent Review Findings

- [x] The feature contract is backend-neutral; Flecs/Jolt, SDL/Metal, client
  prediction, room coordination, transport, and storage do not enter it.
- [x] A review-found respawn race was corrected: replacement incarnation and
  baseline mutation now occur only after character spawn acceptance, so a
  rejected spawn leaves the old dead incarnation retryable.
- [x] A review-found readiness race was corrected: a character awaiting vitals
  registration cannot attack or become a melee target.
- [x] Dead reconnect state now overrides any retained pre-disconnect client
  projection, so an old locally alive avatar cannot block a valid respawn
  request while the replacement baseline is still arriving.
- [x] A real listen-process drain race was corrected by allowing the reliable
  gameplay result to reach the guest before room closure.
- [x] Jolt's required all-hit collector and invalid-body/fraction initialization
  were discovered through real assertions and retained in focused adapter
  tests.
- [x] No generic ability framework, event bus, RPC framework, ECS replication,
  client physics world, compatibility shim, or secondary-platform abstraction
  was introduced.
- [x] No remaining actionable P0/P1/P2 S10 finding is identified after the
  final aggregate review.

## Retained Limits

- Melee is the only playable damage producer. Firearms, projectiles, vehicle
  impact, fall/environment damage, armor, status effects, and friendly-fire
  game policy remain future slices over the same vitals boundary.
- The current respawn catalog belongs to the permanently resident sandbox.
  District-authored spawn catalogs, hazard volumes, hospitals, teams, scoring,
  corpse/ragdoll persistence, and progression penalties remain later product
  policy.
- A `no_safe_spawn` result requires another explicit player request; S10 does
  not add an automatic retry timer or automatic respawn.
- Accepted-ingress replay remains an authority diagnostic, not rollback,
  lockstep, or firearm lag compensation.
- Session lifecycle is ephemeral. Canonical world saves retain vitals, but no
  account service or durable account death exists.

## Closure

S10 is accepted on Apple Silicon macOS. The next phase should be another
player-visible product slice or a deliberately selected production-service
boundary; Steamworks/NAT/public hosting, secondary platforms, firearms/lag
compensation, and MMO-scale services remain deferred until explicitly chosen.
