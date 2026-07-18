# S2 Vehicle Acceptance Record

> **Historical phase record.** This document preserves the evidence and claims
> recorded when this slice closed. Counts, cohorts, platform results, and
> limitations below describe that dated tree, not current support. See the
> [current macOS readiness record](macos-readiness.md) and
> [cleanup plan](../../CLEANUP_PLAN.md).

**Date:** 2026-07-12
**Status:** Complete

## Outcome

The sandbox now composes `CrateFeature`, `CharacterFeature`, and
`VehicleFeature` over one runtime, one Jolt world, and exactly one
composition-owned physics step. A character can enter one procedural
four-wheel vehicle, make its existing CharacterVirtual controller dormant,
drive and collide with a live dynamic crate, exit through a transactionally
validated relocation, and destroy every gameplay object back to the ground-only
baseline.

The feature boundary is backend-neutral. `VehicleFeature` depends on a narrow
vehicle-physics capability and a named gameplay `DriverAccess` port; it imports
neither Jolt nor `CharacterFeature`. The sandbox composition constructs the
real adapters and owns cross-feature identity and restore policy.

## Automated Evidence

- The real Jolt adapter covers settle/contact, throttle toward engine `-Z`,
  steering convention, braking, body-origin and wheel-pose reconstruction,
  stale/foreign/recreated-world handles, more than 256 handle-slot reuse, and
  rollback at every native vehicle creation ownership transition.
- Backend-neutral vehicle tests cover ordered commands, neutral missing input,
  entry distance and authority, occupied/wrong-driver rejection, blocked and
  adapter-failed exits, allocation failure before authority transfer, create
  and multi-record restore rollback, infallible cancellation of a partially
  linked restore with complete pre-enter driver-state restoration, adapter
  error-name isolation, four-wheel interpolation, rotated exit offsets, and
  strict logical persistence DTOs.
- Character tests prove that driving suppresses actions, despawn, controller
  updates, and character presentation without destroying the controller.
  Exit placement uses a read-only Jolt overlap preflight; rejection and adapter
  failure preserve both sides of the occupied relationship.
- Real composition tests run spawn → settle → enter → drive → collide with and
  displace a dynamic crate → exit → despawn. Teardown returns entity count to
  zero and Jolt body count to the host-owned ground. A same-tick test locks the
  declared character-before-vehicle authority order for actions and despawn
  across enter/exit.
- Snapshot V3 validates global IDs and cursor bounds, strict character/vehicle
  configuration, driver existence, and unique driver assignment before world
  construction. Occupied and unoccupied fresh restores immediately re-save to
  the exact same bytes, and existing non-character IDs reject as absent drivers
  rather than faulting the schedule.
- Headless fixtures now use V3 and continue to cover deterministic crate
  timelines, sorted multi-record saves, live-world restore rejection, and
  exhaustive Zig allocation-failure unwind.
- The visual host owns distinct typed chassis/wheel handles, one procedural
  chassis mesh, and one canonical +X-axis wheel mesh reused four times. It
  resolves immutable feature extraction without exposing SDL/GPU resources to
  `VehicleFeature`.
- Input is latched per render frame and consumed per fixed tick. `E` is a
  one-tick authority edge; transition ticks send locomotion to neither feature.
  WASD, service brake, and handbrake route exclusively to the outcome-confirmed
  control target. Camera selection follows the same authority state.
- The native S2 smoke settles the real vehicle, then sends synthetic fixed-tick
  samples through the same interaction/action mapper as manual play: enter,
  drive into and displace the dynamic crate, service brake, steer, and exit. It
  proves character suppression/restoration and self-terminates with clean
  teardown. It passes with 720
  fixed ticks both above the simulation rate (1,440 frames at 240 Hz) and below
  it (480 frames at 80 Hz). The ReleaseFast installed Mach-O passes from `/tmp`.
- `measure-s2` requires one matching `drive_applied` result for every measured
  input plus material chassis displacement, and records three ReleaseFast trials for the complete occupied vehicle
  tick and chassis/four-wheel extraction. CI validates the report schema and
  lifecycle cleanup, never noisy elapsed-time thresholds.

### Post-S11 corrective amendment (2026-07-15)

The current installed regression also exercises the handbrake and inspects the
actual shared wheel-pose composition. It requires visible wheel spin and front
wheel steering at both 240 Hz and 80 Hz rather than treating chassis movement
as wheel evidence. Exact final-tree markers remain pending in the
[`post-S11 runtime corrective audit`](post-s11-runtime-corrective-audit.md);
the historical S2 counts above are intentionally unchanged.

The complete Apple Silicon macOS Debug, ReleaseFast, and editor-enabled Debug
matrices each pass 179/179 tests. The filtered source-package extraction passes
16/16 tests and executes the isolated macOS headless graph. Linux/SteamOS and
Windows are fully deferred: they have no current S2 build, shader, headless,
runtime, packaging, or compatibility gates.

## Persistence Contract

Vehicle saves are logical reconstruction, not opaque Jolt serialization. V3
persists canonical chassis pose and velocities, canonical wheel rotation and
angular velocity, current high-level input, optional driver identity, and all
simulation-relevant vehicle tuning. It excludes native handles, constraints,
listeners, controller/tester pointers, contacts, suspension caches, solver
warm-start state, assets, capacities, and command queues.

The pinned wrapper does not expose enough mutable transmission state for exact
continuation. Internal engine/transmission/contact warm state therefore restarts
from declared defaults after restore. The byte-stability guarantee applies to
the declared logical snapshot immediately after reconstruction; it does not
promise bit-identical future physics, cross-platform determinism, or backward
compatibility with V1/V2 snapshots.

## Closeout

The committed [`S2 performance baseline`](../performance/s2-baseline.md)
characterizes one occupied four-wheel vehicle, one dormant character, one
dynamic crate, and ground on the primary Apple Silicon development machine.
The median p99 complete tick is 0.125625 ms, 1.51% of the 8.333 ms budget; this
is a one-player characterization, not an NPC, server, or MMO capacity claim.

Independent architecture, correctness, and macOS build/evidence reviews were
repeated over the complete visual and measurement slice. Their findings were
corrected before closeout; no actionable P0/P1/P2 S2 issue remains. S2 is
complete and does not broaden the accepted macOS-only platform contract.
