# MP3 Prediction and Network-Fault Acceptance

**Status:** Accepted for the bounded character slice

**Date:** 2026-07-13

## Delivered

- Monotonic capped exponential reconnect backoff with deterministic account
  jitter, an attempt ceiling, and welcome reset.
- Reliable semantic `authority_stopping` delivery with bounded GNS linger;
  rejection and deliberate shutdown are terminal, while transport loss and
  timeout remain reconnectable.
- Welcome-anchored authority time that prevents disconnected wall time from
  creating input catch-up traffic.
- A 256-entry local input history and deliberately small horizontal on-foot
  predictor; no client Flecs/Jolt world was added.
- Snapshot acknowledgement, authoritative reset, unacknowledged-input reapply,
  buffered remote interpolation, smoothing episodes, and hard-snap policy.
- A deterministic fixed-capacity semantic impaired link manufacturing latency,
  jitter, unreliable loss, duplication, reordering, blackout, and directional
  bandwidth pressure.
- Shared client/server semantic delivery classes, bounded per-tick input quota,
  six-tick authority intent hold, and nonterminal stale-input drops.
- A fixed 2,048-entry accepted-input journal with participant, generational
  connection, sequence, target/admission tick, intent, and rolling fingerprint.
- Replay of accepted ingress into a fresh one-world authority with first
  divergence classified as identity, position, velocity, or facing.

## Automated matrix

`zig build verify-mp3 --summary all` runs:

1. prediction/fault contract tests;
2. a clean deterministic character trial;
3. three nominal trials at 80 ms RTT, 10 ms jitter, 1% loss;
4. three adverse trials at 160 ms RTT, 30 ms jitter, 5% loss;
5. a one-second complete blackout and recovery trial;
6. a repeated-seed determinism comparison;
7. accepted-ingress replay for every trial;
8. the real-GNS two-client MP2 regression; and
9. independent server/client processes proving reliable authority-stop delivery.

## Results

| Profile | Seeds | Movement | Max raw error | Max snapshot age | Soft / hard corrections | Convergence |
|---|---:|---:|---:|---:|---:|---:|
| Clean | 1 | 36.0 m | 0.0 m | 2 ticks | 0 / 0 | 0.0 m |
| Nominal | 11, 29, 47 | 35.8-36.0 m | 0.2 m | 7-8 ticks | 10-11 / 0 | 0.0 m |
| Adverse | 101, 211, 307 | 35.7-36.2 m | 0.3-0.4 m | 12-14 ticks | 11-12 / 0 | 0.0 m |
| Blackout | 401 | 30.3 m | 6.7 m | 73 ticks | 10 / 1 | 0.0 m |

The non-blackout trials remain below the 15-tick/250 ms age ceiling and the
2.0 m hard-correction threshold. A correction counter represents one visible
smoothing episode, not every snapshot that updates an active episode; every
trial remains below the starting 120-episode/minute ceiling.

Wire payload rates for this one-character scenario were approximately
2.66-2.70 KiB/s upstream and 1.26-1.27 KiB/s downstream, well below the MP0
16 KiB/s and 96 KiB/s average budgets. These are protocol-payload measurements,
not GNS packet/crypto overhead or a multi-entity scale claim.

The blackout intentionally exceeds normal budgets. It drops unreliable traffic,
forces one hard correction, and must converge afterward; it is a recovery proof,
not an accepted playable profile.

## Defects found by the new evidence

- Render-frame retry timing could spin at uncapped frame rates; retry is now
  monotonic and capped.
- Explicit authority shutdown was indistinguishable from transport loss; it is
  now a reliable terminal semantic event.
- A first input could arrive after welcome but before character spawn outcome;
  admitted pending intent is now retained safely.
- Duplicate/reordered unreliable input was treated like a terminal rejection;
  it is now an expected counted stale drop.
- Presentation smoothing was initially capable of counting itself as repeated
  authority divergence; correction diagnostics now use raw prediction and
  coalesce one visible episode.

## Remaining boundary

MP3 accepts only the on-foot character responsiveness foundation. Vehicle,
interaction, district relevance/baselines, NPC projections, content-catalog
admission, and replication prioritization remain the ordered MP4 program.

## Final validation

- Full Debug, editor disabled: 199/199 steps and 618/618 tests.
- Full ReleaseFast, editor disabled: 199/199 steps and 618/618 tests.
- MP3 Debug: 63/63 steps and 31/31 tests, including real GNS and process proof.
- MP3 ReleaseFast: 63/63 steps and 31/31 tests.
- Filtered extracted source: 98/98 headless steps with 196/196 tests, followed
  by 32/32 cold-product/lifecycle steps with 52/52 tests.
- No validation process remained running after completion.
