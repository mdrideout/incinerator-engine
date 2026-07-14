# MP4-A1 Vehicle Replication Acceptance

**Status:** Accepted

**Date:** 2026-07-13

## Automated command

```bash
zig build verify-mp4 --summary all
```

This gate includes the MP3 regression, session contracts, independent-process
authority shutdown, the real-GNS two-client proof, and the deterministic
vehicle fault matrix.

The completed repository validation also passed:

- full Debug: 199/199 build steps and 623/623 tests;
- full ReleaseFast: 199/199 build steps and 623/623 tests;
- filtered source package: 98/98 steps and 196/196 tests;
- cold extracted product: 32/32 steps and 52/52 tests.

## Accepted behavior

- A real Jolt vehicle is spawned and projected without backend handles.
- Reliable enter/exit requests are correlated to feature outcomes.
- Driving input is unreliable, sequenced, quota-bound, ownership-checked, and
  neutralized after expiry or transport loss.
- Two real GNS clients observe one seat; the second client receives an
  `unavailable` result while occupied.
- The driver reconnects with the same participant and retains confirmed
  occupancy; controls remain neutral while disconnected.
- Exit restores the character and releases the replicated driver.
- Character/vehicle/action ingress replays into a fresh authority with matching
  character and vehicle state.
- The graphical client renders vehicle chassis state, hides the driver, follows
  the vehicle, and exposes `E` enter/exit controls.

## Deterministic matrix

| Profile | Seeds | Movement | Maximum snapshot age | Actions | Queue overflow |
|---|---:|---:|---:|---:|---:|
| Clean | 1 | 83.67 m | 2 ticks | 2 accepted / 0 rejected | 0 |
| Nominal | 13, 31, 53 | 72.11-82.05 m | 9 ticks | 2 / 0 each | 0 |
| Adverse | 109, 223, 313 | 71.54-84.68 m | 12-15 ticks | 2 / 0 each | 0 |
| One-second blackout | 409 | 59.62 m | 71 ticks | 2 / 0 | 0 |

The blackout intentionally exceeds the normal presentation-age envelope. It
drops replaceable inputs/snapshots while reliable lifecycle survives. One late
vehicle input crossed the confirmed exit boundary and was counted as an invalid
control rather than mutating the vehicle or terminating the session.

Repeating nominal seed 13 produced the same impairment diagnostics, movement,
and ingress fingerprint. Every trial also passed fresh-authority replay.

## Real GNS proof

The two-client loopback result recorded:

```text
participants=2 reconnects=1 actions=2/1 vehicle_moved_z=-7.928 character_moved_x=11.800 dropped_events=0
```

The two accepted actions are the driver's enter/exit. The one rejected action
is the second client's occupied-seat contention, which is an expected domain
result rather than a protocol/session rejection.

## Prediction decision

The A1 client interpolates authoritative vehicle state. It does not claim local
vehicle prediction. Nominal maximum age was 9 ticks and adverse age reached
12-15 ticks (200-250 ms at 60 Hz), so MP4-A2 must explicitly evaluate and
implement—or consciously reject—a local vehicle prediction/reconciliation
policy before interaction replication expands the gameplay surface.
