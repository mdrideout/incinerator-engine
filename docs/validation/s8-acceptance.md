# S8 Navigation-Driven Population Acceptance

> **Historical phase record.** This document preserves the evidence and claims
> recorded when this slice closed. Counts, cohorts, platform results, and
> limitations below describe that dated tree, not current support. See the
> [current macOS readiness record](macos-readiness.md) and
> [cleanup plan](../../CLEANUP_PLAN.md).

**Status:** Complete
**Platform:** Apple Silicon macOS only
**Date:** 2026-07-13

This record is governed by
[ADR-014](../adr/014-bounded-district-navigation-and-feature-owned-npc-population.md)
and tracks [the staged S8 design](../design/s8-navigation-population.md).

## S8-A — Cooked route and standalone NPC authority

Complete. The following frozen-boundary evidence is green:

- `zig build test-navigation-contract -Deditor=false --summary all`: 3/3
  steps, 1/1 test. The pure half-open owner rule pins `x == 8` to east.
- `zig build test-district-contract -Deditor=false --summary all`: 3/3
  steps, 5/5 tests. Recipe V2 and the bounded west/east route validate.
- `zig build test-district-feature -Deditor=false --summary all`: 3/3
  steps, 21/21 tests. Copied nodes/edges resolve only under the exact active
  load ticket; invalid references/ordinals, inactive destinations, the seam,
  and post-unload invalidation are covered.
- Debug and ReleaseFast content authority gates: district contract 9/9,
  content 20/20, catalog admission 2/2, cooker 20/20 steps and 6/6 tests,
  worker 8/8, replay-loader 6/6, and scene adapter 28/28. West/east bundles
  are exactly 1,008/1,016 file bytes with 108 decoded route bytes apiece;
  logical builds are 228 bytes each and the renderer upload path ignores the
  logical route payload.
- Debug and ReleaseFast replay ingress codec: 6/6 steps, 18/18 tests. Recipe
  V2 node/edge bytes and every typed build-validation failure round-trip;
  hostile node/edge counts fail before allocation or construction.
- Full editor-free Debug integration after the cooked-route and ingress-codec
  cutover: 136/136 build steps and 529/529 tests. This is an S8-A intermediate
  regression gate; it does not include the still-open NPC authority.
- Independent final review of the content/navigation half: aggregated
  ReleaseFast 45/45 steps and 87/87 tests, exact cooked-versus-logical route
  comparison confirmed, no route bytes enter GPU staging, and no remaining
  actionable P0/P1/P2 finding.
- Pure hostile-snapshot navigation preflight plus live navigation/district
  access: 10/10 focused steps and 23/23 tests. Exact directed-edge validity is
  available before Runtime/Flecs/Jolt acquisition, while live positions and
  movement remain generation-bound to active district tickets.

- Standalone NPC, stateless population producer, and shared Jolt controller
  cap in Debug and ReleaseFast: 12/12 steps and 51/51 tests in each mode.
  Coverage includes exact-generation rebinding, destination wait, retained-
  handle half-open transfer, dormancy/resume, both patrol restore directions,
  hostile compact records, rollback, 128 reserved outcomes, the 65th-NPC
  rejection, event drops, and the Physics-global 128-controller ceiling.
- Full editor-free repository gates after the completed S8-A cutover: 142/142
  steps and 541/541 tests in both Debug and ReleaseFast.
- Extracted source package: 80/80 steps and 158/158 tests, including the pure
  preflight, NPC, population, and real-Jolt controller-cap targets with missing
  visual shader tools and final headless linkage checks.
- Final independent S8-A review: the healthy-transfer controller recreation
  finding was corrected to retain the global CharacterVirtual and atomically
  rebind owner plus ticket; no remaining actionable P0/P1/P2 finding.

## S8-B — Composition, persistence, and replay

Complete. The integrated authority and persistence evidence is green:

- Replay/schema/schedule/snapshot cohorts are exactly `5 / 5 / 7`.
  `CommandSource.npc = 6`, `Category.npc = 7`, and the seventh per-tick
  digest is NPC-owned. WorldConfig V3 is 343 bytes, the seven-category tick
  digest is 232 bytes, and the fixed world contract admits exactly 64 NPCs
  only when player characters plus NPCs fit the global 128-controller limit.
- `zig build test-contracts` and `zig build test-replay` pass in Debug and
  ReleaseFast at 26/26 and 19/19 tests. WorldConfig V3 and the canonical NPC
  patrol command have frozen fingerprints
  `0ba288eeb62c2cd1c8ee2b76564502313bb3c26c047836eaeb7cdaacfe8027d8`
  and `6492549f47350880de4b5146f93141a2108c75dff564c72a8162762322ffa4e6`.
- `zig build test-simulation` passes in Debug and ReleaseFast at 32/32 tests.
  One shared Jolt world composes crate -> character -> district -> interaction
  -> vehicle -> NPC -> physics and deinitializes in exact reverse. The real
  patrol waits at an inactive east seam, survives a canceled destination load,
  crosses on the later ticket, becomes controller-free and dormant when its
  owner unloads, resumes exactly one controller under a new generation, and
  cold-restores without duplicate entities/controllers or NPC rigid bodies.
- Hostile owner/position records, identity collisions, the wrong fixed NPC
  capacity, and a 65-player-plus-64-NPC controller configuration fail before
  Runtime/Flecs/Jolt acquisition; a hostile restore is rejected while an
  unrelated live world remains healthy.
- `zig build test-headless` passes in Debug and ReleaseFast at 27/27 tests,
  including source and final-binary visual-boundary verification. The headless
  lifecycle validates the exact wait, resume, owner-transfer, dormancy,
  second-resume, and goal-reached event sequence and every ID/state/owner/node
  payload; NPC output queues are empty at save/restore boundaries. The normal
  headless executable passes 6/6 steps and exits with clean ownership.
- Installed S4 capture/replay passes at 50/50 Debug and 47/47 ReleaseFast
  steps. Asynchronous district completion is captured at its actual consumed
  tick; the same capture matches, while one altered semantic NPC patrol goal
  diverges at its exact eligible tick and only in category `npc`. Live output
  validation drains every typed NPC outcome/event with no drops.
- NPC logical digest schema 2 hashes the complete FIFO-ordered outcome and
  event payloads, per-kind event drops, and transfer/suspend/resume history.
  This corrected an independent P1 finding in which event divergence could
  previously be drained after an incomplete digest match. Debug and
  ReleaseFast NPC tests pass at 11/11; replay plus simulation pass at 51/51.
- Installed S5 save/restart passes at 52/52 Debug and 49/49 ReleaseFast steps.
  Active, boundary-waiting, and dormant checkpoints cold-restore and re-save
  byte-identically at payload/envelope sizes 2,927/3,119, 2,931/3,123, and
  3,211/3,403 bytes. The first two own exactly one controller; dormant owns
  zero. Runtime controllers, tickets, and route scratch are absent from the
  compact record.
- The complete editor-free Debug integration gate passes at 142/142 build
  steps and 547/547 tests. Root-lane reproduction also passed the modified
  NPC, replay, simulation, headless, and durable-save gates.
- Two independent reviews covered the core schema/composition and the
  headless/replay/save products. Their event-digest and blind-drain findings
  were corrected and rereviewed; no remaining actionable P0/P1/P2 finding
  remains for S8-B.

## S8-C — Scale, diagnostics, presentation, and native closeout

Complete. The representative scale and native product evidence is green:

- The installed exact-content Metal smoke runs from `/tmp` at both 240 and
  80 virtual render Hz. Each run proves 64 distinct spawn identities, 64
  destination waits/resumes, 64 west-to-east ownership transfers, 64 owner
  unload dormancies, 64 controller resumes, and 64 exact despawns. It reaches
  64 immutable NPC draws with two resident scenes, retains the S6 peaks of
  344 staged CPU, 116 staged/upload, and 232 resident GPU bytes, then drains
  to zero entities, one ground body, zero Physics-global CharacterVirtual
  controllers, zero draws, empty queues, and clean shutdown. The final native
  gate passes at 49/49 steps in editor-enabled ReleaseFast.
- Every rendered smoke frame samples the direct Physics registry rather than
  trusting a feature aggregate: native used/capacity, independently summed
  feature ownership, and NPC ownership must agree and
  `authority_consistent` must remain true. The report records native peak 64
  and final 0. This closes the final independent P2 finding about a possible
  invisible native controller leak.
- The ReleaseFast scale gate admits the real installed S6 two-bundle/catalog
  cohort with fingerprint
  `3f7ae7e4f979dabea6c60ed3e3374f166a0910f0385d1513296170301f592c2b`.
  Three fresh baseline/scale process pairs each run one unmeasured lifecycle
  and 32 measured 512-tick cycles: exactly 16,384 measured ticks per trial.
  Direct native controller peaks are 1 baseline and 65 scale, with final 0;
  entities peak at 68, bodies at 8, NPCs/draws at 64, and NPC queue high-water
  marks at 64/64/64 with no drops.
- The three scale nearest-rank p99 values are 0.482125, 0.488375, and
  0.491250 ms against the 4.166 ms ceiling. Worst incremental tracked Zig
  allocation is 124,296 bytes against 2 MiB, and worst paired max-RSS delta is
  2,457,600 bytes against 32 MiB. The canonical scale snapshot/save envelope
  is 31,289/31,481 bytes, and a separate 4,096-tick real-cohort replay matches
  in a 958,046-byte envelope.
- Typed hostile coverage includes invalid references and goals, inactive and
  unreachable destinations, stale/non-owned IDs, exact 65th-NPC capacity
  rejection, 129th-command rejection, and actual saturation of each event
  class. After draining all 256 events, each class accepts 64 new production
  events in exact FIFO order without changing drop counters, then completes
  full cleanup and fresh lifecycle reuse. NPC Debug and ReleaseFast both pass
  at 14/14 steps.
- Diagnostics schema V4 exposes the complete bounded NPC queue and lifecycle
  surface plus Physics-global controller use/capacity/consistency through
  compact text, JSON, ImGui, and the headless host. Generic diagnostics remain
  valid when NPC data is absent. Focused Debug and ReleaseFast simulation,
  diagnostics, headless, and measurement gates pass at 24/24 steps and 65/65
  tests.
- Full repository tests pass in editor-free Debug and ReleaseFast at 145/145
  steps and 558/558 tests, and editor-enabled Debug and ReleaseFast at 148/148
  steps and 558/558 tests. The tightened extracted-source proof explicitly
  includes and executes the S8 measurement tool and passes 85/85 steps with
  169/169 tests while all visual shader tools are unavailable.
- Independent architecture/correctness/build review covered exact per-ID
  visual evidence, output-digest completeness, saturation recovery, native
  controller authority, measurement methodology, build wiring, and teardown.
  Its findings were corrected and rereviewed; no actionable P0/P1/P2 finding
  remains.
