# MP4 Architecture Closeout

**Status:** Accepted

**Date:** 2026-07-14

MP4 now provides one vertical replication path for characters, vehicles,
carry interactions, district relevance, and NPC presentation. The simulation
and its feature modules remain canonical; the session layer performs admission
and semantic projection; the protocol is bounded and backend-neutral; the
client owns only replicated presentation, prediction, and interpolation.

## Gate composition

- Simulation save/restore tests cover the same vehicle, held interaction,
  district, and NPC feature records without reusing network snapshots as save
  data.
- Join-in-progress, reconnect, district transfer, dependency retention, and
  real GNS connection lifecycle are covered by the MP4-B through MP4-D gates.
- MP4-E covers acknowledged delta history, byte/entity/baseline ceilings,
  overload degradation, and recovery.
- `tools/verify_mp4_architecture.sh` fails on backend leakage into protocol or
  client state, proprietary service imports in session core, or missing
  quantitative replication budgets.

## Review findings

No unrecorded P0, P1, or P2 architectural issue remains inside MP4 scope.
At MP4 closure, the following pressure points were intentionally assigned to
later work:

- room/invite identity and instance placement belonged to MP5 and do not own
  gameplay state; the open-engine scope was subsequently accepted on
  2026-07-14 in [`MP5 Acceptance`](mp5-acceptance.md);
- an optional Steam adapter remains outside the open core;
- listen productization, NAT/relay, host migration, public orchestration, and
  MMO world partitioning remain explicit deferrals;
- transform quantization and denser field-level encoding remain measurement-
  driven optimizations.

MP4 is therefore closed as a multiplayer gameplay foundation, not presented
as a production online service.

## Subsequent status

MP5 and the aggregate M4 Apple Silicon macOS foundation are now accepted. The
broad embedded-solo administration facade deliberately excluded from this MP4
scope is closed by the accepted
[`M5 Client/Authority Cohesion`](../design/m5-client-authority-cohesion.md)
gate and its [acceptance record](m5-client-authority-cohesion.md).
