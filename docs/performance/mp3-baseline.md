# MP3 Character Networking Baseline

**Date:** 2026-07-13

**Command:** `zig build verify-mp3 --summary all`

**Host:** Apple Silicon macOS, Zig 0.16.0, Debug evidence run

The deterministic trial is 900 authority ticks (15 seconds), with 360 moving
input ticks followed by neutral convergence. Rates below count encoded semantic
protocol bytes before GNS packet, encryption, and IP overhead.

| Scenario | Upstream payload | Downstream payload | Up queue high | Down queue high | Max age | Max prediction error |
|---|---:|---:|---:|---:|---:|---:|
| Clean | 2,703 B/s | 1,267 B/s | 1 | 2 | 2 ticks | 0.0 m |
| Nominal range | 2,679-2,688 B/s | 1,263 B/s | 4-5 | 3-4 | 7-8 ticks | 0.2 m |
| Adverse range | 2,661-2,670 B/s | 1,259 B/s | 8 | 4-5 | 12-14 ticks | 0.3-0.4 m |
| 1 s blackout | 2,673 B/s sent | 1,259 B/s sent | 8 | 4 | 73 ticks | 6.7 m |

All fixed queues reported zero overflow and prediction history reported zero
overflow. An explicit one-byte/tick unit scenario proves bandwidth deferral and
queue high-water behavior without allowing unbounded growth. An input flood
above eight messages in one authority tick produces one typed quota rejection
and releases the connection.

This baseline is intentionally not extrapolated to 8/16 participants, vehicles,
NPCs, or relevant districts. MP4 must measure those actual projections before
choosing delta compression, baseline, and prioritization policy.
