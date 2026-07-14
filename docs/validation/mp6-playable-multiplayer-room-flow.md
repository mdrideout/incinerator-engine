# MP6 Playable Multiplayer Room Flow Acceptance

**Status:** Accepted

**Date:** 2026-07-14

**Platform scope:** Apple Silicon macOS only. Linux/SteamOS and Windows remain
deferred and provide no MP6 abstraction, build, test, or compatibility gate.

**Design contract:**
[`MP6 Playable Multiplayer Room Flow`](../design/mp6-playable-multiplayer-room-flow.md)

This record reviews the implemented room lifecycle against the accepted MP6
contract. It does not claim Steamworks, Internet rendezvous, NAT traversal,
relay, public matchmaking, allocation services, host migration, or a second
platform.

## Ownership And Security

- [x] A generation-safe coordinator owns create/join/connect/synchronize,
  cancellation, reconnect, failure, leave, drain, and close state.
- [x] Stale completions increment diagnostics and cannot mutate a newer
  operation generation.
- [x] Graphical presentation receives a copied `View`; private connection
  plans and signed admission material have no public coordinator accessor.
- [x] The room registry owns discovery membership/readiness/route only; the
  authority remains the only gameplay source of truth.
- [x] Account-bound room artifacts are capped at 512 bytes, contain no
  admission secret, are written atomically with mode `0600`, and are never
  printed as raw bytes.
- [x] Listen and dedicated room secrets come from the macOS CSPRNG and are
  wiped with their owning room state.
- [x] Unknown or unauthorized guest identity is rejected by the authority
  without terminating the listen host or mutating a valid room member.

## Playable Placements

- [x] Existing embedded solo continues through the typed local client/
  authority boundary and remains in the inherited M6/M5 regression.
- [x] `incinerator_mp6_listen` creates a graphical private room with one
  embedded authority, a host protocol client over the typed local link, and a
  loopback-by-default GNS guest listener.
- [x] A second graphical client joins that listen authority with an
  account-bound signed ticket over real GNS.
- [x] The host and guest both walk, collect/drop, enter/drive/exit, render
  streamed authoritative entities/NPCs, and retain client-owned prediction.
- [x] The guest performs bounded reconnect, keeps its participant identity,
  receives a new relevance baseline, and returns to `playable`.
- [x] Closing the listen owner drains and closes the room and authority without
  host migration.
- [x] `incinerator_mp6_server` owns a dedicated room and writes bounded signed
  tickets; two graphical clients join/synchronize/render over real GNS.
- [x] The dedicated and listen graphical clients share the coordinator,
  semantic failure mapping, protocol client, and extracted client-owned scene
  presenter.

## Lifecycle And Fault Evidence

- [x] Clean, nominal, adverse, and blackout profiles are independently
  selectable in a deterministic lifecycle harness.
- [x] The blackout profile manufactures a bounded unreliable drop; reliable
  lifecycle semantics remain independently covered by M3-M6 regressions.
- [x] Every async coordinator state has cancellation coverage; a completion
  from the previous generation is harmless during reconnect/new attempts.
- [x] Lobby departure leaves a healthy gameplay connection playable, while
  network loss enters bounded reconnect and preserves eligible membership.
- [x] Invite expiry/replay, room full, cohort mismatch, authorization failure,
  reconnect expiry, and service outage remain typed values in MP5/authority
  regressions and are mapped to room presentation failures.
- [x] Ordinary graphical titles/logs expose semantic state, member readiness/
  connection summary, and failure values, not raw GNS codes or credentials.

## Evidence Matrix

Final-tree commands are recorded here when the aggregate gate closes:

| Evidence | Command | Result |
|---|---|---|
| Focused MP6 contracts | `zig build test-mp6-room -j1 --summary all` | Passed: coordinator, ticket, room, host, lifecycle, and architecture contracts |
| Selectable deterministic lifecycle | `zig build verify-mp6-lifecycle -j1 --summary all` | Passed for `clean`, `nominal`, `adverse`, and `blackout`; blackout drop and reconnect/lobby separation observed |
| Architecture boundary | `zig build verify-mp6-room-architecture --summary all` | Passed with `MP6_ARCHITECTURE_PASS coordinator=generation_safe view=sanitized host=typed_local guest=real_gns dedicated=ticketed presentation=client_owned steamworks=absent` |
| Graphical listen process | `zig build verify-mp6-listen -j1 --summary all` | Passed with two SDL/Metal clients; host typed local link, guest real GNS, walk/drive/carry/reconnect/close all observed |
| Graphical dedicated process | `zig build verify-mp6-dedicated -j1 --summary all` | Passed with two signed-ticket SDL/Metal clients over real GNS |
| Complete MP6 aggregate | `zig build verify-mp6-room -j1 --summary failures` | Passed: complete M6/M5/M4, source-package, cold-headless, installed Metal, real-GNS, readiness, replay, persistence, and architecture regression |
| Extracted source package | Transitive `verify-source-package` aggregate | Passed: 153/153 steps and 316/316 tests; cold graph 32/32 steps and 52/52 tests |
| Formatting and patch hygiene | `zig fmt --check build.zig src tools` and `git diff --check` | Passed on the reviewed tree |

## Independent Review

- [x] The implementation was compared with each design acceptance item after
  focused coordinator/ticket coverage and again after both process topologies.
- [x] Shared scene extraction removed duplicated graphical-world rendering; it
  gained no transport, room, authority, persistence, Flecs, or Jolt access.
- [x] The graphical listen composition remains a thin orchestrator over a
  heap-owned room runtime; bounded network/protocol buffers do not inflate the
  UI stack or become globals.
- [x] Remote ingress does not trust a claimed account before authority
  admission, and malformed bytes enter the authority's bounded rejection path.
- [x] No generic event bus, service locator, universal RPC layer, automatic ECS
  replication, second client simulation world, or compatibility layer was
  introduced.
- [x] Complete aggregate/source-package regression is green on the final tree.
- [x] No remaining actionable P0/P1/P2 MP6 finding is identified after the
  final aggregate review.

## Retained Limits

- The first open-engine room UX is a developer-facing graphical executable and
  status/title surface, not a polished game menu or social overlay.
- Private listen is loopback by default. LAN exposure requires explicit
  `--allow-remote --advertise <host>` and retains host trust/performance
  asymmetry.
- Tickets are local development artifacts, not public-service bearer formats;
  no discovery backend, revocation service, entitlement, or matchmaking claim
  is made.
- The fault harness models deterministic semantic impairment; GNS remains the
  real transport proof and is not replaced by that harness.
- Host migration is intentionally absent. Closing/faulting the listen owner
  ends the authority and room.

## Closure Condition

MP6 is accepted and S10 may begin. Steamworks, NAT/relay, public hosting,
matchmaking, Linux/SteamOS, Windows, firearms, lag compensation, and MMO scope
remain deferred.
