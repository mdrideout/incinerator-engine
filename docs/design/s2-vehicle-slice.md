# S2 Vehicle Slice Design

> **Historical slice design.** This was the delivery contract for the slice at
> closure. Detailed file layout, cohorts, and limitations below may have been
> consolidated later. See [ADR-008](../adr/008-feature-oriented-engine-architecture.md)
> and the [cleanup plan](../../CLEANUP_PLAN.md) for current architecture.

**Date:** 2026-07-12  
**Status:** Complete

## Outcome

S2 adds one procedural four-wheel car and one driver seat. The existing player
can spawn the car, enter it, drive and steer it, exit beside it, destroy it, and
restore both occupied and unoccupied state. The same composition runs headless
and visually over the existing 120 Hz fixed step.

This is a vertical slice, not a general vehicle framework. It must prove real
Jolt Vehicle ownership and character/vehicle authority transfer before the
engine grows generic possession, constraint, or wheel APIs.

## Capability Decision

The exact-pinned Jolt 5.5/JoltC cohort already compiles and exposes the required
wheeled-vehicle APIs. No dependency upgrade is required. S2 will use the real
`VehicleConstraint` and `WheeledVehicleController` through a narrow
engine-owned adapter.

Rejected alternatives:

- a force/torque car built on the crate body capability, because it would not
  prove Jolt Vehicle and would create a later rewrite;
- a public generic constraint/wheel framework, because one car does not justify
  that surface;
- opaque Jolt state serialization, because it would make persistence dependent
  on backend pointers, binary format, and version-specific solver state.

The pinned wrapper has two known hazards that the adapter must avoid:

- `JPH_WheeledVehicleControllerSettings_AddDifferential` leaves
  `leftRightSplit` uninitialized. S2 initializes the full differential struct
  and uses `SetDifferentials`.
- `JPH_VehicleEngineSettings_Init` allocates a torque curve without a matching
  settings destructor. S2 retains the controller's default engine settings and
  does not call this initializer.

## Staged Delivery

1. [x] Prove an isolated real-Jolt adapter: create, settle, contact, throttle,
   steer, brake, query, failure unwind, repeated destroy.
2. [x] Implement `VehicleFeature` against fake vehicle physics and fake driver
   access, including enter/exit transactions and persistence policy.
3. [x] Compose character, crate, and vehicle over one runtime and one physics step;
   add Snapshot V3 and headless lifecycle/restore evidence.
4. [x] Add procedural chassis/wheel presentation, input routing, camera switching,
   and a self-terminating native Metal lifecycle smoke.
5. [x] Record a ReleaseFast one-vehicle baseline and complete independent
   architecture, correctness, and build/evidence reviews.

Stages 1–3 prove the native ownership model, backend-neutral feature, explicit
driver-authority boundary, and real headless composition. Stages 4–5 retain
SDL, renderer, camera, resource ownership, native smoke orchestration, and
performance recording in the visual/build hosts rather than `VehicleFeature`.

## Dependency and Ownership Boundaries

### Engine physics contract

The backend-neutral physics contract adds only the four-wheel capability used
by this slice:

- `VehicleDesc`: initial chassis body state, chassis dimensions, lowered
  center of mass, mass, four attachment points, wheel dimensions, suspension,
  steering/braking, explicit front-differential tuning, and the minimal wheel
  rotation/angular velocity needed for logical reconstruction;
- `VehicleInput`: throttle and steering in `[-1, 1]`, service brake and
  handbrake in `[0, 1]`;
- `VehicleState`: body-origin chassis pose/velocity plus four finite wheel
  states and read-only drivetrain diagnostics;
- `createVehicle`, `destroyVehicle`, `setVehicleInput`, and `vehicleState`.

The handle is adapter-owned, monotonic, and world-qualified. No Jolt body ID,
constraint, wheel, controller, tester, or pointer crosses this boundary. The
vehicle capability has no `step` method: the composition owns exactly one
shared physics step.

Engine/camera forward is `-Z`, while Jolt Vehicle defaults to `+Z`. The adapter
sets the constraint and every wheel to `-Z`, places the front axle at negative
Z, and behaviorally tests throttle and steering signs. Public steering input
and reported wheel steer angles are positive toward engine right (`+X`); the
adapter translates Jolt's opposite scalar-angle sign.

### Jolt adapter

One live adapter record owns one chassis body and the caller reference to one
vehicle constraint. The physics system separately retains the registered
constraint; the step-listener registry is non-owning.

Construction releases all temporary wheel/controller settings immediately
after the constraint retains/constructs its internal state. A collision tester
caller reference is released immediately after the constraint stores its
`RefConst`.

Rollback and normal destruction use one strict order:

1. remove the physics step listener;
2. remove the system constraint;
3. release the caller constraint reference;
4. remove and destroy the chassis body;
5. remove the engine handle record.

The body must outlive the constraint. Native failpoints cover each ownership
transition because a retained listener after constraint destruction would be a
use-after-free, not a recoverable leak.

### Shared gameplay driver contract

Character and vehicle do not import each other's implementation. A small
gameplay-level `driver_contract` defines the structural `DriverAccess` port and
driver state. `CharacterFeature` exposes a narrow wrapper implementing:

- inspect whether a character is on foot or driving a specific vehicle;
- begin driving a specific vehicle;
- attempt to end driving at a supplied exit pose.

`VehicleFeature` is generic over the vehicle-physics capability and
`DriverAccess`. This is an explicit feature dependency, not a kernel-wide
possession system.

### CharacterFeature

The CharacterVirtual remains allocated while its character is driving, but it
is dormant: character actions/despawn reject, controller updates stop, and
character presentation is omitted. CharacterVirtual is query-based and has no
inner rigid body in the current configuration, so a dormant controller does
not leave a simulated collider at the entry point.

Exit transactionally relocates the same controller, refreshes contacts, resets
both presentation history samples, and then returns the character to on-foot
mode. If the exit placement is invalid, the character and vehicle remain in the
unchanged driving relationship.

### VehicleFeature

`VehicleFeature` owns:

- chassis/wheel configuration and runtime vehicle handle;
- one optional driver relationship and drive authority;
- spawn, enter, drive, exit, and despawn commands;
- typed outcomes and occupancy-change events;
- chassis and four-wheel presentation history;
- `VehicleV1` records and immutable `VehicleDraw` extraction.

Wheels are fixed semantic indices—front-left, front-right, rear-left,
rear-right—not entities or persistent identities.

### Sandbox composition

The composition constructs the character driver port and vehicle capability,
registers character commands before vehicle commands, owns the neutral shared
physics step, validates all cross-feature references, and deinitializes vehicles
before characters.

The composition exposes public submit/poll/query/extract methods. It does not
reach into feature-private ECS components.

### Visual host

The visual host owns SDL mappings, action latching, procedural chassis/wheel
resources, camera target selection, and resolving typed draw handles. `E`
targets the sandbox's one known vehicle; a general proximity/selection query is
deferred. WASD is routed to exactly one current control target. The transition
tick sends neutral locomotion input to avoid replaying one frame to both modes.

## Enter and Exit Transactions

VehicleFeature owns the complete interaction so two independent deferred
queues cannot partially transfer authority.

Enter processing:

1. validate vehicle and character identities, on-foot mode, empty seat,
   maximum entry distance, and command authority;
2. reserve outcome/event capacity before mutation;
3. call `DriverAccess.beginDriving(character, vehicle)`, which atomically marks
   the existing controller dormant;
4. commit the non-fallible occupant field and emit the entered result/event.

No fallible work follows the character transition.

Exit processing:

1. validate the mirrored driver/vehicle relationship;
2. derive the configured local exit offset from the body-origin chassis pose;
3. transactionally test and relocate the dormant CharacterVirtual;
4. only after success clear occupancy and emit the exited result/event.

Failure preserves the occupied state. Driving rejects a missing or different
driver. Vehicle despawn rejects while occupied. Character actions and despawn
reject while driving. Queue order and same-tick enter/action/despawn cases are
explicit tests, not incidental system-order behavior.

## Persistence

The sandbox advances to a greenfield composition-owned `SnapshotV3` containing
the existing clock/namespace/identity cursor, crate and character records,
authoritative `VehicleConfigV1`, and sorted `VehicleV1` records.

Vehicle persistence includes:

- persistent ID;
- canonical body-origin chassis pose and linear/angular velocity;
- canonical wheel rotation in `[0, 2π)` and finite angular velocity where
  required for visual and first-tick continuity;
- current high-level drive input;
- optional driver persistent ID.

Assets, capacity, handles, constraints, tester/controller pointers, command
queues, contacts, suspension caches, solver warm-start state, and Jolt binary
state are not persisted.

The pinned C wrapper cannot faithfully restore internal transmission shift
timers or all wheel/contact caches. S2 therefore defines save files as logical
reconstruction: chassis, wheel, authority, input, and configuration state are
restored; internal engine/transmission/contact warm state restarts from declared
defaults. RPM/gear remain query diagnostics unless a later gameplay requirement
justifies a small engine-owned mutable-state wrapper extension. The acceptance
record must state this limit and must not claim bit-identical physics
continuation or cross-platform determinism.

Before creating a world, V3 validation proves:

- global ID uniqueness across crate, character, and vehicle records;
- correct namespace and identity cursor bounds;
- every driver refers to an existing character;
- one character occupies at most one vehicle;
- every config/state scalar, quaternion, and wheel value is finite, ranged,
  and canonical.

Restore creates characters, creates vehicles, links validated drivers, then
freezes registration. Both previous/current presentation samples start equal.
An immediate save after restore is byte-stable for the declared logical state.

## Acceptance Evidence

### Adapter gate

- Real ground plus vehicle settles with four contacts and finite wheel poses.
- Positive throttle moves materially toward `-Z`; steering changes heading in
  the declared sign; service brake materially reduces speed.
- Creation temporaries can be released before stepping.
- Body/constraint/listener/handle counts return to baseline after repeated
  lifecycle and every injected creation failure.
- Stale, foreign, and recreated-world handles reject.
- Debug and ReleaseFast adapter tests pass on Apple Silicon macOS. Secondary
  platforms are fully deferred and are not S2 gates.

### Feature gate with fakes

- Command/outcome/event order, missing-input neutralization, capacity, range,
  double/wrong/far/missing enter, blocked/successful exit, authority, occupied
  despawn rejection, and failure rollback.
- Driver transition is atomic under allocation and adapter failures.
- Canonical persistence, interpolation, and exact logical save-after-restore.

### Real composition and headless gate

- Character, crate, and vehicle coexist without private feature imports and
  use one physics step.
- Scripted spawn → enter → drive → exit → despawn runs headless and survives
  occupied and unoccupied V3 restore.
- Vehicle displaces one live dynamic crate in the shared Jolt world.
- Extracted-package and linked headless boundaries remain free of SDL,
  renderer, editor, and shader dependencies.

### Native macOS gate

- Procedural chassis plus four interpolated wheel poses render on Metal.
- Camera/control target and character visibility switch on enter/exit.
- A self-terminating S2 smoke observes movement, steering, collision, exit, and
  clean teardown above and below the simulation rate.
- At least one S2 smoke runs from the installed executable under `/tmp`.

### Performance gate

`measure-s2` records three ReleaseFast trials after warmup for one vehicle:
command submission, tick, extraction, creation/destruction, cleanup counts, and
p50/p95/p99/max. Shared CI gates schema and completion, not noisy wall time.

## Explicit Deferrals

- multiple seats, passengers, door/seat animation, and visible seated driver;
- general vehicle selection and safe-exit overlap search;
- reset/unstuck unless the lifecycle smoke proves it necessary;
- AI/autopilot, motorcycles, tracked vehicles, trailers, and multiple car
  archetypes;
- damage, fuel, keys/account ownership, audio, VFX, and surface/tire materials;
- streaming assets, editor tuning, and secondary-platform native runtime polish;
- network authority, prediction, replication, and a generic relation/event
  framework;
- opaque/exact Jolt solver-state persistence and backward snapshot
  compatibility.
