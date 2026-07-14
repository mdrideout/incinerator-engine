# MP0 Quantitative Network Contract

**Status:** Implemented initial contract

**Date:** 2026-07-13

This document records the ceilings used by the first multiplayer character
slice. They are admission and test inputs, not production service-level claims.
Evidence may change them only together with `src/session/budgets.zig`, tests,
and the multiplayer plan.

## Rates and capacity

| Concern | Initial contract |
|---|---:|
| Authority/gameplay tick | 60 Hz |
| Snapshot publication | 20 Hz, every 3 authority ticks |
| Product room target | 8 participants |
| Validation ceiling | 16 participants |
| Maximum wire message | 64 KiB |
| Maximum snapshot | 32 KiB |
| Relevant entities per client | 2,048 |
| Baseline memory per client | 4 MiB |
| Inbound/outbound message queues | 256 / 512 messages |
| Inbound/outbound queued bytes per connection | 512 KiB / 2 MiB |
| Input history | 256 ticks |
| Future input window | 6 ticks |
| Handshake / idle timeout | 5 s / 10 s at authority time |
| Reconnect grace | 10 s at authority time |

## Bandwidth and impairment profiles

| Profile | RTT | Jitter | Loss | Duplicate | Reorder |
|---|---:|---:|---:|---:|---:|
| Nominal | 80 ms | 10 ms | 1% | 0.1% | 0.5% |
| Adverse | 160 ms | 30 ms | 5% | 1% | 2% |

Per-client starting budgets are 16 KiB/s average and 32 KiB/s peak upstream,
and 96 KiB/s average and 192 KiB/s peak downstream. MP3 measured and accepted
the bounded character profile under deterministic impairment; see
`docs/performance/mp3-baseline.md`.

The initial prediction thresholds are 0.10 m for soft correction, 2.0 m for a
hard correction, 250 ms maximum snapshot age, and 120 soft corrections per
minute. They are contracts for MP3 implementation, not evidence that prediction
already exists.

## Failure policy

- Oversized, malformed, wrong-cohort, unauthorized, expired-reconnect, and
  pre-handshake traffic is rejected before canonical character mutation.
- Input is bounded by participant, connection generation, sequence, and tick
  window. A client submits intent, never a canonical pose.
- Unreliable snapshots are application-sequenced; reordered or duplicate
  samples are counted and dropped.
- Handshake and idle timeouts are authority-time decisions. Transport loss
  enters a bounded reconnect grace; an explicit graceful leave despawns.
- Every queue and fixed store has a compile-time ceiling. MP2 does not allocate
  per packet or grow participant state dynamically.

MP2 uses an unauthenticated, self-declared development `AccountId`. The server
therefore binds `127.0.0.1` by default. `--allow-remote` is an explicit trusted
LAN/development escape hatch, not authorization for public exposure. A real
identity/ticket provider remains an MP5 prerequisite.

## Cohorts

Wire protocol revision is explicit. The build cohort is generated from the
tested Zig, Flecs, Jolt/JoltC, GNS, rate, and protocol cohort. The MP2 content
cohort identifies the fixed character-sandbox proof. A later cooked-world room
must derive its admitted content cohort from the selected logical catalog; it
must not reuse the MP2 proof value.
