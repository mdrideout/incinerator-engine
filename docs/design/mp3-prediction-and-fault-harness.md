# MP3 Prediction, Reconciliation, and Deterministic Network Faults

**Status:** Implemented and accepted for the bounded character slice

**Date:** 2026-07-13

## Outcome

The locally owned character remains responsive while the authoritative state
continues to win under the MP0 nominal and adverse network profiles. The proof
must be deterministic, bounded, repeatable, and independent of a real network.

## Why a manufactured-fault harness exists

A localhost socket normally hides the conditions that break networked games.
The MP3 harness sits between semantic client/server messages and advances on an
explicit authority tick. Given the same configuration, seed, traffic, and tick
sequence, it must make the same delivery decisions every run.

The harness can manufacture:

- one-way latency derived from an RTT profile;
- bounded positive and negative jitter;
- unreliable loss and duplication;
- cross-message reordering while application sequence rules remain active;
- complete blackout intervals;
- directional byte budgets and resulting queue pressure.

Reliable messages are delayed and bandwidth-limited, not permanently discarded
by synthetic packet loss. Unreliable input/snapshot messages may be dropped or
duplicated. This models the semantic effects expected above GNS; it does not try
to reimplement GNS congestion control or packet retransmission.

The harness is a test adapter, not a production transport abstraction. Local
solo delivery remains immediate, and direct GNS remains the production network
adapter.

## Client prediction model

1. Admission establishes participant ownership and anchors the authority clock.
2. Each locally produced input receives a sequence and is retained in a fixed
   256-entry history.
3. A deliberately small on-foot motor predicts horizontal movement only. It is
   not a second Flecs/Jolt world and makes no cross-machine physics determinism
   claim.
4. Each authoritative snapshot acknowledges the latest accepted input.
5. The client resets the predicted base to its authoritative character record,
   discards acknowledged history, and reapplies the remaining inputs.
6. Small error is corrected without a reported event, soft error is smoothed,
   and error at or above the hard threshold snaps immediately.
7. Ownership loss, terminal disconnect, or a new session clears prediction.

Remote characters remain on a buffered snapshot interpolation timeline. They
are never predicted from another player's inputs.

## Authority ingress policy

- Input identity, participant ownership, sequence, target-tick window, and
  finite normalized values are validated before mutation.
- Duplicate or reordered stale input is an expected unreliable-network drop,
  counted without terminating the client.
- A bounded per-tick input-message quota rejects abusive ingress.
- The authority holds the latest admitted intent for a short bounded window so
  one lost datagram does not create a one-tick stop; it then falls back to
  neutral input.
- Accepted input is appended to a fixed flight journal with participant,
  connection, sequence, target tick, admitted tick, and a rolling fingerprint.

## Diagnostics and budgets

The acceptance runner records at least:

- sent, delivered, lost, duplicated, reordered, blackout-dropped, and
  bandwidth-deferred messages/bytes by direction;
- queue occupancy/high-water and overflow;
- snapshot age and stale snapshot count;
- current/maximum prediction error, soft/hard corrections, history pressure,
  and ownership resets;
- authority accepted/rejected/stale/quota input and ingress-journal pressure.

The MP0 nominal and adverse profiles are each run with three fixed seeds. The
runner fails on queue overflow, non-finite state, terminal client rejection,
history overflow, or failure to converge after input stops. Performance numbers
are evidence for these bounded scenarios, not public-Internet service claims.

## Acceptance matrix

| Scenario | Required proof |
|---|---|
| Clean | Prediction follows flat-ground authority and converges exactly |
| Nominal, 3 seeds | Join, movement, bounded age/error/corrections, convergence |
| Adverse, 3 seeds | Same under 160 ms RTT, 30 ms jitter, 5% loss, duplicate/reorder |
| Blackout | Unreliable loss is visible; reliable lifecycle survives; prediction converges afterward |
| Reordered/duplicate input | Authority counts stale input without rejecting the session |
| Saturation | Fixed queues and byte budgets defer or reject observably; no growth |
| Ownership loss | Predicted state is discarded immediately |

## Acceptance

- [x] Prediction history and correction behavior are bounded and unit-tested.
- [x] The deterministic harness reproduces identical diagnostics for a seed.
- [x] Nominal and adverse three-seed trials pass quantitative gates.
- [x] Accepted ingress is bounded, fingerprinted, and replayed into a fresh authority.
- [x] Client/server transport-class policy has one shared source of truth.
- [x] Debug, ReleaseFast, real-GNS MP2, and extracted-source gates pass.

## Explicitly later

Vehicle prediction, district relevance, delta baselines, NPC replication,
Steam identity/lobbies/P2P/SDR, public authentication, Linux hosting, shards,
and persistent-world/MMO services remain MP4, MP5, or later programs.
