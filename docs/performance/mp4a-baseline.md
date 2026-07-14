# MP4-A1 Network Vehicle Baseline

**Date:** 2026-07-13

**Command:** `zig build verify-mp4 --summary all`

| Profile | Upstream protocol payload | Downstream protocol payload | Up queue high | Down queue high |
|---|---:|---:|---:|---:|
| Clean | 2,912 B/s | 2,513 B/s | 1 | 2 |
| Nominal | 2,865-2,882 B/s | 2,500-2,507 B/s | 5 | 3-4 |
| Adverse | 2,841-2,855 B/s | 2,493-2,507 B/s | 8 | 4-5 |
| Blackout | 2,853 B/s | 2,507 B/s | 8 | 4 |

These figures are encoded semantic payload for one participant, one character,
and one vehicle over the deterministic adapter. They exclude GNS framing,
congestion/ack traffic, encryption, UDP/IP overhead, and multiple-client
fan-out. They are evidence for MP4-A1 only, not a city-scale budget claim.

The vehicle projection materially increased downstream MP3 payload from about
2.46 KiB/s to about 2.50 KiB/s. It remains far below the initial 96 KiB/s
average per-client ceiling. MP4-C through MP4-E must replace this single-world
broadcast baseline with relevance, prioritization, and bounded deltas before
entity counts grow.
