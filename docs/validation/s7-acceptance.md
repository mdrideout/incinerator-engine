# S7 Interaction and Cross-District Ownership Acceptance

> **Historical phase record.** This document preserves the evidence and claims
> recorded when this slice closed. Counts, cohorts, platform results, and
> limitations below describe that dated tree, not current support. See the
> [current macOS readiness record](macos-readiness.md) and
> [cleanup plan](../../CLEANUP_PLAN.md).

**Status:** Complete
**Platform:** Apple Silicon macOS only
**Date:** 2026-07-13

This record is governed by
[ADR-013](../adr/013-feature-owned-carry-interaction-and-district-ownership.md)
and tracks [the staged S7 design](../design/s7-interaction-ownership.md).

## S7-A — Capability seams and standalone authority

Complete at the standalone boundary. The shared coordinate rule uses centered
16-unit half-open cells (`[-8, 8)` is west and `x == 8` is east), and the
character/district capabilities expose only carrier and exact-active-ticket
state. Entering a vehicle while carrying is a typed `driver_carrying`
rejection that preserves both relationships and leaves the runtime healthy.

The fixed-capacity InteractionFeature owns one persistent object and covers
district-owned, held, and dormant states. Its Debug and ReleaseFast suites each
pass 12/12 tests, including collect/drop rollback at both sides of each
transaction, unload/reload reconciliation and failure rollback, active/dormant/
held cold restore, canonical logical hashing, 16-command/16-outcome saturation,
and eight repeated cross-boundary cycles ending with zero entities, bodies, and
queued output. The carrier/district port cohort and driver/character/vehicle
cohort also pass in both optimization modes. Full independent S7 review remains
the final S7-C gate.

## S7-B — Composition, persistence, and replay

Complete. The composition owns crate -> character -> district -> interaction
-> vehicle -> physics ordering and reserves exact identity/body budgets for one
carryable. `InteractionV1`, `SnapshotV6`, replay schema/schedule cohort 4, and a
separate interaction digest category preserve district-owned, held, active,
and dormant state. Preflight rejects duplicate/global identity conflicts,
missing holders, held-and-driving relationships, invalid carryable records,
and incompatible cohorts before a fresh Flecs/Jolt world is constructed.

The real-Jolt suite passes 29/29 in Debug and ReleaseFast. Installed replay
records 449 ticks, matches every category, then reports a district-only
divergence for an altered district command and an interaction-only divergence
for an altered valid interaction spawn. The installed two-process save gate
writes held and dormant slots, catalog-preflights them in a cold process, and
restores each canonically (`held_payload=2351`, `dormant_payload=2512`).

## S7-C — Producers, presentation, measurement, and native closeout

Complete. `F` and the optional editor both emit the same exact collect/drop
commands through a fixed eight-entry host mailbox and nonzero monotonic
transaction IDs; `E` remains vehicle enter/exit. Immutable carryable draws
represent both held and district-owned state, while dormant objects emit no
draw. Structured diagnostics expose bounded queue, ownership, body,
suspend/resume, and producer-rejection evidence without a generic inventory or
ownership debugger.

The versioned ReleaseFast workload completed 128/128 real-Jolt ownership
cycles over 11,615 fixed ticks. It submitted 11,033 semantic commands,
observed 1,034 outcomes and 774 events, and canonically serialized 512 active/
dormant snapshots. Peaks were four entities, eight bodies, and command/outcome/
event occupancies 2/2/1 with zero rejection. It also cancelled a source-owner
load while the item was held, proved unchanged holder/body/entity state, and
subsequently reloaded that coordinate. Final state was zero entities, one
ground body, zero active bodies, and empty command/outcome/event queues. See
[the S7 baseline](../performance/s7-baseline.md) and its
[machine-readable result](../performance/s7-baseline.json).

Installed Metal completed the entire lifecycle at both cadence extremes. The
240 Hz run used 364 frames / 182 ticks / 182 zero-tick frames / zero multi-tick
frames; the 80 Hz run used 124 frames / 186 ticks / zero zero-tick frames / 62
multi-tick frames. Both observed held/world draws, source unload while held,
east drop, dormancy, reload/resume, and exact final zero-draw cleanup.

Normal interactive vehicle entry while carrying now treats the typed
`driver_carrying` rejection as a healthy domain outcome and records it in the
bounded diagnostic journal. Authority failures remain fatal. Feature and host
regressions prove unchanged relationships and continued usability.

Final gates include 519/519 tests in all four aggregate modes: Debug and
ReleaseFast completed 134/134 build steps with the editor excluded and 137/137
with it included. Focused evidence includes 12/12 interaction tests, 29/29
simulation tests, 17/17 replay tests, 25/25 headless tests, and 2/2 measurement
tests. The extracted source package completed 65/65 steps and 101/101 tests;
aggregate installed macOS readiness completed 72/72 serialized steps. Replay,
save, Metal, formatting, and diff gates pass. Independent review corrected the
interactive host rejection policy and required S7-specific cancellation
evidence; after remediation it reported no remaining actionable P0/P1/P2
finding.
