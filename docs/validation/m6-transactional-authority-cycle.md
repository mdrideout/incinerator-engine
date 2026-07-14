# M6 Transactional Authority Cycle Acceptance

**Status:** Accepted

**Date:** 2026-07-14

**Platform scope:** Apple Silicon macOS only. Linux/SteamOS and Windows remain
deferred and provide no M6 build, test, compatibility, or abstraction gate.

**Design contract:**
[`M6 Transactional Authority Cycle`](../design/post-m5-transactional-authority-cycle.md)

This record closes M6 from implementation, focused failure injection, prior
multiplayer regression, cold-authority, source-package, and installed native
macOS evidence. M6 guarantees fail-stop atomic publication; it does not claim
rollback of an already stepped Flecs/Jolt world.

## Accepted Transaction Boundary

- [x] Connection lifecycle, decoded messages, malformed/oversized notices, and
  delivery receipts enter one bounded class-reserved mailbox.
- [x] Every accepted envelope receives a monotonic ordinal; each cycle freezes
  a stable prefix and retains deterministic original-order evidence.
- [x] The authority records all eight stages: ingress freeze, admission,
  semantic work, simulation, outcome drain, derivative preparation, durable
  disposition, and publication.
- [x] Expected admission, capacity, quota, and durable-deferral failures are
  values preflighted before the state they protect is consumed.
- [x] Unexpected failures latch the immutable first fault, publish no prepared
  batch, expose no staged durable payload, and prevent another authority tick.
- [x] Participant/credential and replication metadata used by publication are
  staged separately and swapped only with successful publication.
- [x] The simulation is deliberately fail-stop rather than rolled back after an
  unexpected post-mutation failure.

## Delivery And Reconnect

- [x] Physical adapters consume a generational outbound lease and explicitly
  commit or retry it; the former pop-before-send API is removed.
- [x] Control and gameplay reliable lanes carry independent monotonic delivery
  IDs and cumulative application receipts.
- [x] The client rejects gaps, applies duplicates idempotently, and preserves
  applied delivery identity across transport loss.
- [x] Reliable gameplay results retain a bounded 32-record replay ledger until
  application acknowledgement.
- [x] Reconnect waits for the new `Welcome` application receipt before replay,
  then drains a full ledger over quota-safe ordered batches.
- [x] Credential rotation keeps only the one predecessor needed until welcome
  confirmation; repeated loss cannot create unbounded credential history.
- [x] Local typed links, impaired links, and GNS hosts commit authority leases
  only after their respective semantic/transport acceptance point.

## Durable Ownership

- [x] A privileged owner queues a typed capture request; stage seven returns a
  typed deferral or owned immutable payload.
- [x] Encoding and blocking atomic storage remain outside the authority tick.
- [x] A staged payload is not observable when publication fails and authority
  ownership is released exactly once after the persistence owner consumes it.
- [x] The graphical save flow handles the asynchronous disposition and preserves
  canonical fresh-process verification.
- [x] Diagnostic observation remains strict and rejects non-quiescent authority
  state rather than manufacturing an incoherent snapshot.

## Failure And Saturation Evidence

- [x] Injected failure at every one of the eight stages proves completed prefix,
  absent suffix, immutable first fault, and refusal to advance.
- [x] A real unexpected feature-outcome failure covers the post-simulation
  outcome boundary.
- [x] Admission failures at credential issuance, command reservation, and
  publication preserve participant capacity, nonce history, and credentials.
- [x] Publication failure preserves live participant and replication metadata
  and hides the staged durable disposition.
- [x] Control, gameplay, input, and notice mailbox reservations prove that input
  saturation cannot starve lifecycle/control traffic.
- [x] Future input retention, same-target replacement, held-control continuity,
  jump-edge behavior, and applied-input acknowledgement retain their M5 tests.
- [x] Adapter loss before application receipt, duplicate replay, reconnect
  ordering, and a fully occupied replay ledger are covered.

## Evidence Matrix

Final-tree commands and results:

| Evidence | Command | Result |
|---|---|---|
| Focused M6 transaction contracts | `zig build test-m6-transaction -j1 --summary all` | 26/26 steps and 87/87 tests passed |
| M6 architecture boundary | `zig build verify-m6-architecture --summary all` | 2/2 steps passed with `M6_ARCHITECTURE_PASS ingress=class_reserved cycle=eight_stage publication=double_buffered delivery=leased receipts=cumulative replay=bounded durable=stage_seven` |
| Complete Debug regression | `zig build test -Deditor=false -j1 --summary all` | 225/225 steps and 774/774 tests passed |
| Native macOS readiness | `zig build test-macos-readiness -j1 --summary failures` | Passed; installed Metal gameplay, lifecycle, diagnostics, replay, and asynchronous authoring-save scenarios completed |
| Filtered source package | `zig build verify-source-package -Deditor=false -j1 --summary all` | 145/145 steps and 309/309 tests passed; nested cold authority 32/32 steps and 52/52 tests passed |
| Aggregate M6 | `zig build verify-m6 -j1 --summary failures` | Passed; M6 focus plus complete M5/M4, source-package, cold-authority, and native macOS regressions completed |
| Formatting and patch hygiene | `zig fmt --check build.zig src tools` and `git diff --check` | Passed |

## Independent Review

- [x] The implementation was checked against every design acceptance item after
  the focused gate passed, then again after the complete aggregate regression.
- [x] Legacy harnesses that assumed immediate admission, tick zero, synchronous
  durable capture, or pop-before-send behavior were migrated to the new owner
  contracts rather than retained as compatibility paths.
- [x] No unbounded queue, generic event bus, service locator, public mutable
  authority surface, second simulation world, storage I/O, or physical network
  send was added to the fixed tick.
- [x] No remaining actionable P0, P1, or P2 finding was identified in M6 scope.

## Retained Limits

- Fail-stop publication is not solver rollback or deterministic rewind.
- One authority owner remains intentional; parallel ingress/simulation is not
  justified by a second measured producer thread.
- Reliable replay is bounded to the declared ledger capacity. Later product
  work must select typed supersession/backpressure before broadening reliable
  action volume.
- Transport acceptance and application acknowledgement remain separate by
  design. Steamworks, NAT traversal, relays, public hosting, and host migration
  remain deferred.

## Closure

M6 is accepted. MP6 may now build its playable room coordinator and constrained
listen/dedicated flows on the same transactional authority and delivery model.
