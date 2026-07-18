# MP4-C District Relevance Acceptance

**Accepted:** 2026-07-14

**Boundary correction validated:** 2026-07-17

- The protocol round-trips bounded district baselines and explicit client
  acknowledgements; wire revision 5 rejects older cohorts.
- The authority withholds steady snapshots until the current baseline is
  acknowledged and records emitted, acknowledged, stale, and transfer counts.
- The real-GNS two-client proof covers initial JIP baselines, a reconnect
  baseline, and west-to-east hysteretic transfer.
- The original acceptance expected unowned vehicles and carryables to leave a
  client's projection at the exact district seam. Human incident evidence
  proved that contract caused authority-live objects to disappear and then pop
  back into presentation. That expectation is superseded.
- The current bounded sandbox cohort projects every presentable vehicle and
  carryable to every participant. The two-client proof requires both objects to
  retain the same replicated identity through relevance transfer. Characters
  and NPC population remain district-relevant; occupied vehicles and held
  objects remain semantic dependencies.
- This is an intentionally simple bounded-world policy, not a general-purpose
  replication graph. Revisit it only when measured object counts require a
  spatial interest policy with explicit hysteresis and lifecycle evidence.
- `zig build verify-mp4c --summary all` passed the corrected cohort on
  2026-07-17: 87/87 steps and 154/154 tests, including clean, nominal,
  adverse, blackout, and real-GNS two-client proofs.
