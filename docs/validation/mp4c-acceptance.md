# MP4-C District Relevance Acceptance

**Accepted:** 2026-07-14

- The protocol round-trips bounded district baselines and explicit client
  acknowledgements; wire revision 5 rejects older cohorts.
- The authority withholds steady snapshots until the current baseline is
  acknowledged and records emitted, acknowledged, stale, and transfer counts.
- The real-GNS two-client proof covers initial JIP baselines, a reconnect
  baseline, west-to-east hysteretic transfer, and removal of west-only vehicle
  and carryable projections from the east client.
- The reconnecting driver retains its occupied vehicle as a semantic dependency
  even after the remote east client correctly stops receiving it.
- Focused session contracts pass 41/41; the real-GNS MP2 gate passes 34/34 build
  steps and 3/3 host tests.
