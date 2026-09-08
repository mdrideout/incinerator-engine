# EA2-H: Vehicle controls and drivetrain handling profiles

Status: implemented and engineering-verified. Human driving-feel acceptance remains pending.

See [EA2-H validation](../validation/ea2-handling-profiles.md) for final measurements, compatibility changes, replay and test evidence.

Date: 2026-09-07. Product-owner direction: Space operates the handbrake;
opposite-direction input service-brakes before changing direction; deliver
distinct FWD, RWD and AWD road-car behavior. Implementation was authorized after this plan.

This is the next vehicle slice before EA3. It builds on
[EA2 authoring](ea2-vehicle-authoring.md), the
[motion audit](../validation/vehicle-motion-audit.md),
[ADR-029](../adr/029-engine-game-authoring-boundary.md) and
[ADR-030](../adr/030-editor-input-routing-and-interaction-capture.md).

## Required outcome

Courier remains composed in ordinary cornering, progressively runs wide when
front grip is exceeded, and can deliberately rotate through rear-wheel
handbraking. Meridian has a stable road-car baseline with progressive
throttle-induced rear breakaway. An AWD comparison has explicit torque
distribution and predictable corner-exit traction. All three support braking,
reverse, handbrake release and recovery through the same simulation.

The first playable deliverable is the new controls and corrected FWD Courier.
Complete and verify that slice before tuning RWD and AWD. Do not mark handling
accepted merely because motion/replay tests pass.

## Current evidence and implementation facts

- `game/vehicles/courier.json` and its canonical `.icvehicle` definition use
  `front_torque_fraction = 1`; Meridian uses zero. `src/physics.zig` connects
  only the driven axle for these endpoints and both axles for intermediate
  fractions. Separate drivetrain simulation implementations are unnecessary.
- `src/features/vehicle/control.zig` already resolves opposite throttle into
  service braking above the existing 0.1 m/s signed standstill tolerance. Keep
  that tolerance initially; it addresses solver residual motion.
- `src/main.zig` currently maps Space to service brake and Left Shift to
  handbrake. Graphical incident replay independently maps `jump_or_brake` to
  service brake. Both producers must change together.
- The adapter already assigns handbrake torque only to rear wheels. Failure
  to produce the intended rear drag must be isolated from the key binding.
- The retained audit reports about 84 degrees of Courier chassis sideslip in
  its 8 m/s half-steer turn, versus about 3 degrees for Meridian. A prior
  Courier candidate improved that turn but failed handbrake breakaway and was
  rejected. Neither value alone identifies a tire-model root cause.
- Wheel state already contains contact, angular velocity, steering, suspension
  impulse, longitudinal/lateral impulses and slip. Extend interpretation and
  reports before adding redundant telemetry or replacing the tire solver.
- The historical rig uses a 0.2-friction support surface. Verify actual cooked
  industrial-road collision properties; visual material names do not establish
  physical grip. Retain the historical surface as a labeled comparison.

## Decisions and ownership

| Concern | Owner / decision |
|---|---|
| Keyboard mapping | Game composition and `sandbox_controls`; shared pure mapping used by live input and graphical replay |
| Pedal resolution and steering state | Existing fixed-tick vehicle control path; no render-time handling state |
| Tire forces, brakes, differentials | Generic physics contract and pinned Jolt adapter |
| Profile values and names | Game assets under `game/vehicles`; no hardcoded FWD/RWD/AWD force branches in the engine |
| Preset selection | Game tooling creates a candidate; existing vehicle owner performs apply/rebuild/revert/commit |
| Camera and interpolation | Retain the repaired presentation path; compare chase and fixed views during acceptance |

Keep Jolt pinned. Add a narrow tire-response extension only if H1 demonstrates
a limitation that authored settings cannot resolve. No new traffic, vehicle
art, map editor, damage system, controller platform or neural work is included.

## Ordered implementation backlog

| Item | Dependency | Deliverable | Exit condition |
|---|---|---|---|
| H0 — Controls and replay meaning | None | Shared Space/handbrake and opposite-pedal control journey | Pure mapping and actual queued SDL acceptance pass; recording/replay agree |
| H1 — Diagnose grip and rear locking | H0 | Repeatable axle-level measurements and causal finding | Report distinguishes steering conditioning, tire saturation, wheel lock, surface and drivetrain effects |
| H2 — Correct shared mechanics where proved | H1 | Smallest required adapter/contract correction, or documented evidence that tuning suffices | Ordinary grip and locked-wheel braking are independently characterized; new mechanics covered through all affected contracts |
| H3 — FWD Courier | H2 | First playable handling correction | Front-limited ordinary cornering and useful handbrake rotation/recovery pass together |
| H4 — RWD Meridian | H3 | Distinct, stable RWD road-car baseline | Progressive power-oversteer and recovery without routine corner-entry spins |
| H5 — AWD and reusable presets | H4 | Authored AWD comparison plus shared preset-to-candidate workflow | Three distinct definitions coexist; UI/CLI candidates and durable restart agree |
| H6 — Product acceptance | H5 | Current measurements, native evidence, replay and documentation | Engineering gates pass; subjective acceptance is recorded separately |

### H0 — Controls and replay meaning

Implement these rules in a pure game-control mapping, feeding the existing
`FrameSample` / action latch and authoritative pedal resolver:

| Input | On foot | Driving |
|---|---|---|
| W | Existing movement | Forward demand; service-brake reverse motion before engaging forward |
| S | Existing movement | Service-brake forward motion; continued hold engages reverse at standstill |
| Space | Jump press edge | Held rear handbrake; release removes handbrake demand |
| W + S | Existing movement cancellation | Service brake, zero propulsion; remain braking while both are held |
| Left Shift | Existing behavior | No vehicle brake binding |
| A / D | Existing movement | Existing steering path, including while braking/reversing |

Keep Space handbrake independent of throttle. In W+Space, propulsion still goes
through the declared drivetrain and rear braking through the handbrake; H1
measures their interaction. Service brake remains an explicit physics input
for tests, agents and future input devices.

Use capture-filtered gameplay input. Editor-owned presses cannot reach driving.
Release, focus loss and mode/occupancy transitions clear or suppress held input
through existing owners. A Space hold must not become a fresh jump when exiting
the car. Free Camera controls and Escape/menu routing retain their contracts.

Affected components:

- `src/sandbox_controls.zig`, `src/main.zig`, and
  `src/features/vehicle/control.zig` for mapping and pedal coverage.
- `src/hosts/incident_input_replay.zig`, `src/hosts/incident_capture.zig` and
  the incident-input DTO producers/consumers for recorded meaning.
- Startup help, README, incident schema reference and native driving fixtures.

Replace the ambiguous `jump_or_brake` input meaning with explicitly named
physical Space state and mapped jump/service-brake/handbrake actions. Introduce
an explicit input-mapping version in incident metadata and validate it before
graphical replay. Reject incompatible graphical recordings clearly; do not
silently reinterpret old Space recordings. Update affected schema consumers
and fixtures together. Accepted-ingress replay continues recording resolved
typed vehicle input; only advance its format if encoded input/state changes.

Acceptance: real SDL W acceleration -> S braking -> reverse -> W braking ->
forward; Space press/hold/release at speed; W+S; W+Space; A/D through braking;
focus loss, captured editor input and entering/exiting with Space held. Assert
actual applied brake/handbrake/throttle and direction, not just key-buffer bits.
Keep this queued-event test distinct from the motion audit's scoped physical
input filter. The latter must remain resistant to live keyboard/mouse input.

### H1 — Diagnose grip and rear locking

Extend `tools/vehicle_motion_audit.zig`, `tools/vehicle_dynamics.zig` and
`tools/vehicle_motion_report.py`. Reuse existing wheel evidence in
`src/hosts/vehicle_motion.zig` and `src/hosts/incident_capture.zig`.

Add matched comparisons for coast, acceleration, service brake and handbrake
during the same turn, plus straight rear-brake drag and release. Reuse the
existing forward 2/8/16/24 m/s and reverse 2/8/12 m/s entry cohorts where relevant;
test left/right and rotated world headings. Add constant-steer speed sweeps
and steady-circle characterization to distinguish axle balance from transient
steering response. Record every controller input if a radius/speed controller
is used in a measurement fixture; it is not a gameplay assist.

Report:

- Raw demand, conditioned steer and actual front wheel angles; signed speed,
  yaw rate, path curvature, lateral acceleration and chassis sideslip.
- Front/rear tire slip separately, wheel angular speed versus longitudinal
  contact speed, contact validity and observed rear-wheel locking.
- Suspension impulse / physics timestep as estimated wheel load, and tire
  impulses / physics timestep as estimated average contact forces.
- Rear-brake deceleration, turn rotation, release/recovery and front-wheel
  behavior; identify contact loss separately from traction loss.
- Exact definition/digest, surface properties, tick rate, entry condition and
  input schedule. Missing/incomplete conditions are not passing samples.

Compare path curvature against the actual wheel angle and low-speed reference
for that car. A larger turn radius caused solely by speed-sensitive steering
is not proof of understeer. Require corroborating front/rear slip and load
behavior before assigning the handling imbalance.

Read back effective axle drive configuration and wheel brake settings through
the real adapter. For AWD, inspect center differential coupling as well as the
authored torque split; do not assume an unspecified backend default is harmless.

Deliver a before-change report and one explicit diagnosis: incorrect bindings,
insufficient rear locking, retained lateral grip under locking, axle tuning,
steering response, surface mismatch, or a supported combination. Baseline
repeats establish numerical tolerances. No new universal slip or speed caps.

### H2 — Correct shared mechanics where proved

Fix demonstrated configuration/adapter errors first, then evaluate existing
tire curves and axle settings. More rear brake torque is justified only if
H1 shows insufficient wheel braking. Reducing steering lock alone cannot close
the front-grip objective.

If locked/slipping wheels retain excessive cornering capacity, prototype a
generic combined longitudinal/lateral tire response at Jolt's supported tire
impulse boundary. It must depend on measured contact/slip and available grip,
not the selected FWD/RWD label or an artificial chassis yaw kick. Compare it
with the pinned default across acceleration, service braking, handbraking and
recovery before selecting it. If existing settings meet these cases, close H2
with that evidence and add no solver extension.

Any new required parameter receives an explicit unit, validation and game
value in `src/engine/contracts/physics.zig` and the vehicle definition. Carry
it through `src/physics.zig`, the narrow bridge if needed, asset codecs,
feature reconstruction/digests, session admission, save/replay, authoring field
metadata, CLI schemas and incident transaction artifacts. Update all affected
cohorts in the same change. Retain explicit live-safe versus rebuild semantics.

Completion requires front wheels remaining unbraked by handbrake, meaningful
rear drag, recovery after release, no injected yaw in a symmetric straight
test, and no regression hidden by making all ordinary cornering slippery.

### H3 and H4 — Tune FWD, then RWD

Use the existing authoring/measurement owner and canonical `.icvehicle` assets.
Tune in this order: mass distribution; suspension/anti-roll; tire balance;
drivetrain/brakes; steering response. Preserve visual geometry and correct
wheel alignment. Retain exact before/candidate/accepted definitions and report
all maneuver results, including rejected candidates.

Courier acceptance:

- Ordinary steering is stable; excessive demand progressively saturates the
  front and widens the path. Normal half-steer cornering does not reproduce
  the earlier uncontrolled rear rotation.
- Power-on versus coast behavior is consistent with the front driven axle.
- Handbrake during a turn produces additional rear slip and rotation relative
  to the matched unbraked maneuver, followed by recoverable grip on release.
- Straight handbraking drags the rear without a forced sideways kick.
- Braking, reverse steering, direction changes and curb contact remain usable.

Meridian acceptance:

- Neutral/coasting and moderate-throttle cornering remain stable.
- Sufficient throttle progressively breaks rear traction; throttle release and
  appropriate countersteering recover the slide.
- Service brake and rear handbrake remain measurably different inputs.

For each profile, establish repeatable maneuver-specific acceptance bands from
H1/H2 evidence and the driving target before promoting the candidate. Retain
those bands and their rationale in the validation record; do not choose them
after a run merely to make that run pass. Assess the first playable Courier in
both chase and fixed camera views before moving to the next profile.

### H5 — AWD and game-owned presets

Create one distinct AWD comparison archetype with its own stable asset ID,
label and revision, reusing compatible existing chassis/wheel visuals. Use a
Courier-derived geometry/mass comparison initially so torque distribution can
be isolated. Author its torque split and axle differential values explicitly;
if H1 proves center-coupling settings matter, expose those through H2's typed
contract. Demonstrate both axles receiving drive and characterize W+handbrake
so drivetrain coupling does not silently defeat rear braking.

Register/cook/install the asset through `game/vehicles/catalog.zig` and the
existing content tooling. Place it in an accessible collision-free location
in the existing industrial world. Update tests that intentionally asserted
the old two-car fleet; no new world size or art pipeline is required.

Use the three canonical baseline definitions as preset sources. Add a pure
game-tooling candidate builder, proposed at
`game/vehicles/handling_profiles.zig`, shared by UI and CLI. A preset copies
explicit handling fields: mass/COM, axle suspension/anti-roll, tires/brakes,
powertrain, steering and assists. Preserve the target identity, revisions,
visuals, chassis collision dimensions and wheel geometry. Validate and measure
the resulting candidate; a baseline tune is not automatically suitable for
every chassis. Preset source identity/revision/digest accompanies the result.

Vehicle Lab offers a named preset selection and explicit Load Into Draft action.
This creates a dirty candidate only. Existing Measure, Apply/Rebuild, Revert and
Commit keep their current ownership. The CLI receives catalog-described preset
discovery/candidate construction using the same helper and full candidate;
it applies through existing revisioned vehicle operations. Exact command syntax
belongs to the executable catalog when implemented.

Affected tooling includes `src/editor/tools/vehicle_lab_tool.zig`,
`src/hosts/vehicle_authoring_contract.zig`, `vehicle_authoring.zig`,
`vehicle_developer_host.zig`, the sandbox developer protocol/catalog and
`tools/incinerator_dev.zig`. Do not introduce runtime preset inheritance or a
second mutable copy of tuning values. Saving/replay preserves the full admitted
definition, independent of later edits to its preset source.

Acceptance: UI and CLI construct identical candidates from identical source
and target revisions; stale applies reject; rejected rebuilds preserve the
live car; preset selection alone changes no physics; commit/restart preserves
exact values; all three cars coexist with distinct identities and handling.

### H6 — Verification and handoff

Run relevant focused gates after each work item, then the final aggregate.
Run native window tests sequentially. Do not repeat the full expensive matrix
after documentation-only changes.

```sh
zig build test-sandbox-controls test-vehicle-feature test-physics \
  test-session-contracts test-vehicle-assets test-vehicle-authoring \
  test-vehicle-dynamics -Deditor=true --summary all

zig build test-mouse-capture-macos -Deditor=true --summary all
zig build test-editor-pointer-macos -Deditor=true --summary all
zig build test-vehicle-driving-macos -Deditor=true --summary all

zig build test -Deditor=true --summary all
zig build test -Deditor=false --summary all
zig build verify-source-package --summary all
```

Extend the existing dynamics and native-driving targets for new scenarios and
the AWD asset. Run `--motion-audit` against each canonical definition, retaining
full outputs and compact comparisons. Generate and verify new accepted-ingress
replays for all three cars using the matching installed content/build. Exercise
human-input graphical replay separately after the input-mapping version change.

Retain solo/listen/dedicated definition/control coverage, editor-off/headless
loading and authoring round trips for every new encoded value. Preserve zero
frozen moving sub-tick frames and chassis/wheel alignment in the existing
cadence tests. These checks cannot substitute for tire behavior measurements.

Create `docs/validation/ea2-handling-profiles.md` during implementation with:
baseline and accepted definitions; scenario completion and measured bands;
before/after metrics and rejected candidates; commands/results; exact source
and content cohorts; native incident paths, indexed views and verified replay
results. Keep original human-test folders unchanged. Record subjective driving
acceptance as pending until reviewed, independently of engineering completion.

## Definition of done

- [x] H0 new controls, lifecycle ownership and graphical replay meaning agree.
- [x] H1 report identifies the measured grip/handbrake cause.
- [x] H2 minimal common correction or tuning-only conclusion is verified.
- [x] H3 Courier delivers ordinary front-limited grip and deliberate rear drag.
- [x] H4 Meridian delivers stable ordinary driving and progressive power slides.
- [x] H5 AWD and the shared preset authoring workflow are complete.
- [x] H6 focused/full gates, all-profile replay and installed native evidence pass.
- [x] Current help, schema/catalog descriptions, roadmap and validation agree.
- [ ] Human assessment of understeer, handbrake drag and recovery is recorded.
