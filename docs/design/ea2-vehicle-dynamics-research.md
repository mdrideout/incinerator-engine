# EA2 Vehicle Dynamics Research

Date: 2026-09-07. Research and planning complete; implementation is tracked in
[the EA2 plan](ea2-vehicle-authoring.md). Product owner direction: focus on
vehicle authoring with GTA IV-style driving inspiration.

## Driving target

Build a weighty, readable urban driving model. The working interpretation of
the requested GTA IV influence is visible braking dive, acceleration squat and
cornering roll; momentum that rewards braking before corners; progressive tire
breakaway; useful countersteering; and meaningful differences between vehicles.
These are our design targets, not claims about Rockstar's proprietary solver
or exact handling constants. The research did not establish an authoritative
public specification of GTA IV's vehicle implementation.

Start the authored driving experience with an original conventional road sedan.
A rear-wheel-drive configuration provides a direct test of throttle-controlled
corner exit and recovery. Use the existing front-wheel-drive configuration as
a comparison, then prove that two differently proportioned archetypes coexist.
Neither the first car nor the test fixtures define an engine capacity limit.

## Primary-source findings

### Criterion: simulation, input and presentation have separate jobs

Matthew Harris's GDC 2018 presentation describes vehicle design in the context
of the player's task, and distinguishes input assistance from forces added to
the simulation. It emphasizes preserving useful simulation nuance and giving
designers debugging and automated physics tools. Its camera discussion is a
separate part of the driving experience. We should measure the chassis and
wheels directly, then assess how well the existing camera communicates them.
Input filtering must operate at the authority tick if it affects handling;
camera smoothing remains presentation.

Sources: [GDC session](https://gdcvault.com/play/1025383/Vehicle-Feel-Masterclass-Balancing-Arcade)
and [original slides](https://media.gdcvault.com/gdc2018/presentations/Harris_Matthew_VehicleFeelMasterclass.pdf),
especially pages 13, 17-24, 37-48. The relevant slides were rendered and inspected
because much of their text is not recoverable through PDF text extraction.

### Avalanche: curves should expose the handling decisions

Hamish Young's GDC 2019 Just Cause 4 presentation describes authored tire curves,
separate front/rear grip, wheel loads, and the interaction between braking and
cornering forces. It also explains the tradeoffs of a tire model fitted to
real tire measurements. Our inference is to begin with Jolt's existing explicit
curves, correct their units, expose their meaning, and measure combined maneuvers
before considering a replacement tire solver. Just Cause 4's deliberate roll
suppression and direct drift assistance serve a different driving target from
the expressive body motion requested here.

Sources: [GDC session](https://www.gdcvault.com/play/1026035/Vehicle-Physics-and-Tire-Dynamics)
and [original slides](https://media.gdcvault.com/gdc2019/presentations/Young_Hamish_Vehicle_Physics_And.pdf),
especially pages 5-7, 11-16 and 26-32. Curve diagrams and force relationships were
visually inspected.

### BeamNG: characterize coupled behavior before compensating for it

BeamNG's developers describe how a contact-model problem affected rolling
resistance, grip and speed together, and how apparently local workarounds had
other consequences. That supports comparing complete driving traces, correcting
the cause of observed problems, and recording tradeoffs. Their node-beam vehicle
model is materially different from Incinerator's rigid-body vehicle. EA2 uses
their measurement discipline as inspiration.

Source: [BeamNG, Tire Physics Changes, 2021-06-03](https://www.beamng.com/game/news/blog/tire-physics-changes/).

### Pinned Jolt: verify the actual adapter boundary

Incinerator pins Jolt revision `23dadd0e603f1b321142d4c74df07fce85064989`
through JoltC revision `52d8c98df523f449eb3e01b1060a0fde052970d1`.
The pinned source, rather than newer documentation, determines implementation
capabilities and units. It exposes engine, transmission and differential runtime
configuration, anti-roll bars, tire curves and wheel contact/suspension impulses.
The C wrapper exposes only a subset of those mutation capabilities.

The lateral friction curve's X coordinate is **degrees**, although steering
angles and the wheel's reported lateral slip are radians. Its pitch/roll
constraint is an explicit stabilization aid; setting the angle to pi disables
that constraint. These details materially affect our current baseline.

Sources: pinned [wheel/controller contract](https://github.com/jrouwe/JoltPhysics/blob/23dadd0e603f1b321142d4c74df07fce85064989/Jolt/Physics/Vehicle/WheeledVehicleController.h),
[controller implementation](https://github.com/jrouwe/JoltPhysics/blob/23dadd0e603f1b321142d4c74df07fce85064989/Jolt/Physics/Vehicle/WheeledVehicleController.cpp),
and [vehicle constraint](https://github.com/jrouwe/JoltPhysics/blob/23dadd0e603f1b321142d4c74df07fce85064989/Jolt/Physics/Vehicle/VehicleConstraint.h).

## Current code and material gaps

| Finding | Current evidence | EA2 consequence |
|---|---|---|
| Lateral tire-curve unit mismatch | `src/physics.zig` passes `lateral_*_angle_radians` directly to `JPH_LinearCurve_AddPoint`; pinned Jolt samples degrees | Correct conversion in the adapter before selecting new tuning; verify installed curve coordinates against Jolt |
| Existing rollover characterization includes assistance | `VehicleTuning.max_pitch_roll_radians` defaults to 60 degrees | Report assist state; characterize the target car with the stabilizer disabled as well as any explicitly assisted profile |
| One world-level tuning definition | `src/features/vehicle/contract.zig` has `Config.tuning`; instance records contain motion and driver state | Introduce admitted per-instance archetype identity, definition revision and tuning |
| Fixed front-wheel drive | `src/physics.zig` installs one front differential | Author front/rear torque distribution and differential values explicitly |
| Shared axle tuning | One suspension spring/damper and tire response apply to every wheel | Author front/rear axle behavior, brake distribution and anti-roll response |
| Implicit drivetrain defaults | Controller creation does not configure engine or transmission values | Make engine torque, inertia, RPM and gearbox choices visible game data |
| Digital steering reaches physics directly | `driveNow` retains the input; the feature supplies it to the backend at the tick | Add explicit tick-based steering response and speed sensitivity, with saved/replayed filter state |
| Minimal reconstruction state | Vehicle records preserve chassis, wheels, input and occupancy; engine/gearbox transient state is not restored | Distinguish logical reconstruction from in-place live edits; never call destroy/recreate state-preserving without a proved transition |
| Client assumes one layout | `src/client_scene.zig` uses `default_vehicle_wheel_layout` and fixed chassis scale | Close A-F029 through admitted definitions and visual bindings |
| Client prediction assumes one response | `src/session/vehicle_prediction.zig` has fixed acceleration, braking and yaw response | Account for archetype changes and flush obsolete prediction; validate correction behavior for the new cars |
| Existing objective gate favors one handling style | `tools/vehicle_dynamics.zig` requires less slip, faster recovery and shorter stopping than legacy | Keep the historical comparison; define behavior checks for the new target instead of treating minimum roll/slip as universal quality |

The unit mismatch is concrete: an authored 3-degree peak currently becomes
approximately 0.05236 degrees in Jolt's curve; the 20-degree slide point becomes
approximately 0.34907 degrees. This does not mean all measured chassis slip is
caused by that defect. Correcting it changes the model and requires a new
measurement cohort.

The current pitch/roll test's small measured tilt does not demonstrate that
the 60-degree stabilizer engaged. It does mean that the test cannot establish
unassisted rollover behavior under more severe maneuvers.

## Reproduced baseline

Executed `zig build vehicle-dynamics-report -Deditor=false` on Apple Silicon
with Zig 0.16.0. Exit status was zero. Full output, source hashes and dependency
revisions are preserved in
[research-baseline.json](../validation/ea2-vehicle-authoring/research-baseline.json).
These reproduce the existing report; they precede the tire-unit correction.

| Metric | Legacy | Current |
|---|---:|---:|
| Brake entry speed, m/s | 15.003 | 15.009 |
| Stopping distance, m | 25.320 | 23.164 |
| Stopping time, s | 3.258 | 3.017 |
| Steady turn radius, m | 5.729 | 6.107 |
| Steady turn mean chassis sideslip, degrees | 23.806 | 23.573 |
| Slalom lateral excursion, m | 36.213 | 40.145 |
| Slalom peak yaw rate, degrees/s | 57.718 | 57.368 |
| Slalom peak chassis sideslip, degrees | 15.048 | 10.671 |
| Skid peak chassis sideslip, degrees | 5.719 | 5.600 |
| Skid recovery, s | 0.275 | 0.250 |
| Maximum tilt, degrees | 3.795 | 2.187 |
| Rollover | false | false |

The report's slip metric is chassis sideslip, not per-tire slip. Its legacy and
current profiles change several variables together; their deltas do not isolate
individual causes. The fixed flat course and scripted scenario lengths define
the experiment, not game-world dimensions or engine resource limits.

## Design decisions from the research

1. Retain Jolt, the existing 120 Hz authority, and explicit physics ports.
2. Fix units and improve characterization before tuning the new sedan.
3. Author visible weight transfer through chassis mass properties, suspension
   and axle balance. Do not introduce a second gameplay force model merely to
   imitate a reference game's appearance.
4. Expose finite, physically meaningful values with clear units. UI ranges are
   convenience hints; game tuning targets are not universal schema limits.
5. Keep wheel-load effects and combined braking/cornering visible in telemetry.
   Prove whether the existing model is sufficient before adding load-sensitive
   tire coefficients or custom force callbacks.
6. Keep steering response and any assist state explicit. Inspect raw input,
   conditioned input and resulting motion independently.
7. Separate draft preview, authoritative instance application and durable asset
   commit. Material Lab's synchronous presentation owner cannot become a second
   physics authority.
8. Deliver authoring, save/replay/replication identity, measurements and native
   driving acceptance together. A tune that only works in the solo renderer
   does not complete EA2.
