# S2 Vehicle Headless Acceptance Record

**Date:** 2026-07-12
**Status:** Stages 1–3 complete; native macOS presentation and performance remain

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

The complete Apple Silicon macOS Debug, ReleaseFast, and editor-enabled Debug
matrices each pass 177/177 tests. The filtered source-package extraction passes
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

## Remaining S2 Gates

- Add visual-host-only input routing, camera target switching, and procedural
  chassis/four-wheel resource ownership.
- Run the self-terminating native Metal lifecycle smoke above and below the
  120 Hz simulation rate, including an installed ReleaseFast executable from
  outside the repository.
- Record the one-vehicle ReleaseFast characterization.
- Repeat the final architecture, correctness, and build/evidence reviews over
  the complete visual slice.

These are Stage 4/5 gates. They do not change the accepted headless contracts,
and they must not move SDL, renderer, camera, or GPU ownership into the feature.
