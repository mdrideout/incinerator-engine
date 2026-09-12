# Responsive fleet: coupe, sedan and SUV

September 7, 2026. This is a first response-tuning pass, not a claim to reproduce
Rockstar's handling model. The target is prompt keyboard response with visible
vehicle weight. Human driving review remains necessary for subjective feel.

## Approach and sources

Vehicle feel has several independent contributors. Criterion's
[Vehicle Feel Masterclass](https://www.gdcvault.com/play/1025295/Vehicle-Feel-Masterclass-Balancing-Arcade)
describes handling assists and camera motion as part of the result. Avalanche's
[Just Cause 4 vehicle physics talk](https://www.gdcvault.com/play/1026035/Vehicle-Physics-and-Tire-Dynamics)
describes choosing designer-friendly tire behavior for believable, fun driving
rather than assuming a more elaborate simulation automatically feels better.
The published talk abstracts informed this pass; their complete slides were not
available through the research reader.

[AVS's arcade tuning documentation](https://avs.overtorque-creations.com/general/arcade-physics)
separates steering take-up, steering return, speed-dependent lock, torque, tire
friction and center of mass. These are useful independent tuning axes. In our
existing implementation, normalized steering took about 385 ms from neutral to
full lock at rest. Transmission shift and clutch-release settings were 500 ms
and 300 ms respectively. [Jolt's transmission contract](https://jrouwe.github.io/JoltPhysics/class_vehicle_transmission_settings.html)
distinguishes these from shift latency; they should not be treated as one delay.

We retain the existing physics, tire balance, speed-dependent steering lock,
pedal state machine and camera. This pass adjusts authored response, modestly
increases suspension damping, and gives the SUV appropriate dimensions and
power. Simply reducing mass or raising torque was not an acceptable substitute:
the aggressive candidate failed direction-transition checks.

## Promoted content

| Vehicle | Body | Revision | Steering rise / return per second | Mass | Torque |
| --- | --- | --- | --- | --- | --- |
| Meridian | Blue two-door coupe | 3 | 5.5 / 8 | 1,580 kg | 230 Nm |
| Courier | Orange four-door sedan | 3 | 5.5 / 8 | 1,120 kg | 140 Nm |
| Courier AWD | Green SUV | 2 | 4.5 / 8 | 1,520 kg | 190 Nm |

Coupe/sedan neutral-to-full steering is now about 182 ms at rest; SUV is 222 ms.
Full-to-neutral return is 125 ms instead of 250 ms. All three use 300 ms shifts,
180 ms clutch release, unchanged 500 ms shift latency and engine inertia, and
front/rear suspension damping of 0.72 instead of 0.62. At speed, existing lock
curves still apply; these timings do not imply instant chassis yaw response.

The SUV has chassis half extents 0.94 × 0.85 × 2.20 m, 0.35 m wheel radius,
0.245 m wheel width and attachments at x=±0.83, y=-0.32, z=±1.36 m. It retains
the 70/30 front/rear torque split and open center differential. It owns a new
`vehicle/courier-awd` cooked bundle. All three models are original procedural
assets with distinct cabins, door trim and silhouettes. Their durable vehicle
IDs remain unchanged; the SUV's visual dependencies now belong to its own bundle.
Generation also corrects inward-facing cabin and tire-tread geometry.

## Measurements and tradeoffs

The same ReleaseSafe real-Jolt runner measured original and candidate definitions.
The acceleration fixture samples at 60 Hz; threshold times below are first sampled
crossings. Braking uses the existing approximately 15 m/s entry fixture.
[comparison.json](vehicle-responsive-fleet/comparison.json) contains exact
definitions, characterization metrics and acceleration threshold crossings.

| Vehicle | 0–50 km/h, before → after | Stop distance, before → after | Skid recovery, before → after |
| --- | --- | --- | --- |
| Courier | 8.00 → 7.70 s | 22.61 → 22.20 m | 1.98 → 1.98 s |
| Meridian | 7.07 → 6.97 s | 25.85 → 26.41 m | 2.28 → 2.17 s |
| AWD compact → SUV | 7.28 → 6.05 s | 22.93 → 25.72 m | 0.99 → 2.61 s |

The sedan/coupe change is primarily steering response, not a large acceleration
increase. SUV results compare different masses and geometry, not tuning alone.
The SUV takes a wider steady turn (17.97 m versus 15.66 m) and longer to stop and
recover from the skid fixture. These are explicit tradeoffs, not hidden wins.
No rollover occurred in the characterization fixture for any promoted profile.

An initial candidate shortened shifts to 180 ms, clutch release to 120 ms and
latency to 250 ms, reduced engine inertia and gave the SUV 210 Nm. Direction
transitions failed. Restoring inertia and using the promoted transmission values
fixed the sedan/coupe, but the 210 Nm SUV still failed forward-to-reverse steering
at heading 270° (final forward speed 10.4 m/s; 27 opposing-gear-at-speed ticks).
Reducing SUV torque to 190 Nm passed the full matrix. Gates were not relaxed.

## Validation results

- Focused physics, vehicle feature, asset and dynamics checks: 80/80 passed.
- Full editor-enabled regression suite: 1,311/1,311 passed.
- Final current-source motion matrix: 360/360 scenarios passed in 1.35 s of
  batch execution, excluding compilation.
- Offscreen industrial drive: both tests passed, exercising all three cars.
  Desktop observer recorded no focus violations; the frontmost application
  remained unchanged. This exercises player-control semantics, not physical SDL
  key delivery (`sdl_pedal_journey=false`).
- Accepted-ingress replay verification passed: Courier 1,891 ticks, Meridian
  2,041 ticks, SUV 1,947 ticks. Captures and verification logs are retained beside
  this report. Replay verification proves logical simulation results; it does
  not reproduce OS or GPU scheduling.
- Reviewed the three rendered front-quarter captures: distinct silhouettes,
  coupe/sedan door trim, SUV roof rails and wheel placement are visible. These
  are deliberately simple original models, not finished production artwork.

Evidence is in [vehicle-responsive-fleet/](vehicle-responsive-fleet/), including
full test logs, per-profile motion summaries and the native replay captures.

## Reproduction

```sh
zig build test-vehicle-dynamics test-vehicle-assets test-vehicle-feature test-physics -Doptimize=ReleaseSafe -Deditor=false
zig build vehicle-motion-report -Doptimize=ReleaseSafe -- --output /tmp/vehicle-fleet-motion
zig build verify-vehicle-background-macos -Deditor=true -Doptimize=ReleaseSafe
zig build test -Deditor=true
```

The motion matrix covers all three profiles, four headings and 30 driving
scenarios per profile/heading. The native acceptance cooks and loads each body's
real dependencies, drives with player controls, checks authority/presentation
alignment and produces replay captures. Additional front-quarter images use the
existing free-camera contract only in the test; product camera behavior is unchanged.

For human review, compare small steering taps, sustained bends, release-to-center,
shifts, S braking through zero into reverse, and Space handbrake recovery on each
vehicle. Review the SUV's longer stopping distance separately from steering
responsiveness. Use the incident shortcut to record remaining handling complaints.
