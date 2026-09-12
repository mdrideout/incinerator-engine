# Low-speed handbrake and stronger cornering

Date: 2026-09-12. Apple Silicon macOS, Zig 0.16.0, pinned real Jolt.

The prior handbrake locked the rear wheels but allowed propulsion to oppose
braking. The combined-slip response also retained only about 12% of the SUV's
lateral capacity at rear-wheel lock. A held 8 m/s steered stop could rotate it
nearly 200 degrees. Existing tests required some deceleration and breakaway,
but did not bound stopping distance or excessive rotation.

## Shipping change

Courier sedan and Meridian coupe advance to revision 8; Courier AWD SUV to 7.
The canonical `.icvehicle` definitions and their JSON authoring mirrors agree.

- All front/rear lateral peak and sliding coefficients increase by 1.44. Jolt
  combines tire/surface friction geometrically, so this increases the resulting
  pure lateral capacity by 20% on the same surface. It is not a guarantee of
  exactly 20% more yaw response in every speed/input combination.
- Rear longitudinal peak coefficients increase by 3x for sedan/SUV and 2x for
  coupe. Sliding friction is 95% of the new peak, strengthening locked-wheel
  deceleration. Rear longitudinal sliding-slip coordinates become 0.60 for all
  three cars, retaining about 51% of the lateral-capacity multiplier at wheel
  lock. The earlier SUV value was 0.12 (about 12% retained).
- Handbrake demand proportionally suppresses propulsion in the shared gameplay
  pedal policy: full Space suppresses throttle, including W+Space and reverse
  throttle+Space. Release restores the requested pedal. Opposite-pedal service
  braking remains available. Authority, the real-Jolt rig and client prediction
  use this same policy; the physics adapter does not add a hidden assist.
- Sedan/SUV centres of mass move down 0.10 m to -0.45/-0.55 m. The unbalanced
  higher-grip candidates rolled in the sustained full-steering test. The coupe
  remains at -0.35 m. No yaw limiter or pitch/roll constraint was added.

Steering curves, engine output/gears, service-brake torque, rear-only 4,000 Nm
handbrake torque, suspension, geometry and surface friction are unchanged.
A front-traction increase did not improve sedan stopping, and was rejected.
A new handbrake ramp or speed-dependent service-brake blend was considered but
was not needed to meet the measured low-speed stopping/stability criteria.

All tuning changes use the existing authoring contract. The existing Apply
path chooses live update or reconstruction; centre-of-mass edits reconstruct.
The pedal-policy change requires the new executable. Source fingerprints include
the new handbrake audit and the speed/steering audit implementations. Older
accepted-ingress captures remain old-cohort evidence, not compatible replays.

## Measured before/after

Held handbrake from a naturally accelerated approximately 8 m/s (29 km/h),
with throttle released and steering straight. Stop means horizontal speed below
0.25 m/s for 0.25 s; distances integrate horizontal travel, including sideways
motion. The observation is eight seconds held, then three seconds released to
0.2 throttle. Recovery is separate from stopping.

| Vehicle | Stop distance before → after | Stop time before → after |
| --- | ---: | ---: |
| Sedan | 17.34 → 10.19 m (-41%) | 3.37 → 2.03 s |
| SUV | 13.64 → 7.64 m (-44%) | 2.88 → 1.67 s |
| Coupe | 7.94 → 5.68 m (-28%) | 1.92 → 1.37 s |

For the half-steered 8 m/s held stop, the SUV's peak sideslip decreases from
89.43° to 9.40° and accumulated yaw from 197.64° to 24.44°. All 126 low-speed
cases stop and remain stopped while held, including simultaneous full throttle,
then move again after release. Peak held sideslip across the fleet is 11.45°.
The pre-fix reports retain incomplete stops explicitly rather than replacing
missing stopping distances with zero.

The 24 m/s entry, half-steer, full-throttle comparison below uses the second
second of the turn on the shipping 0.2-friction support. It is open-loop: cars
can accelerate/decelerate during the turn. Exact entries, exit speeds, tire
forces, steering, path curvature and tilt are retained in the reports.

| Vehicle | Yaw response before → after | Change | Terminal speed after |
| --- | ---: | ---: | ---: |
| Sedan | 26.52 → 30.19 °/s | +14% | 58.30 m/s (210 km/h) |
| SUV | 22.88 → 25.07 °/s | +10% | 53.96 m/s (194 km/h) |
| Coupe | 17.82 → 22.33 °/s | +25% | 55.46 m/s (200 km/h) |

All three complete the 180-second acceleration and subsequent high-speed
service-brake observation. No rollover occurs in the historical handling rig
or the shipping-surface steering matrix. Artificial 0.5/1.0-friction surfaces
still include rollover cases, as they did before; these exploratory rows are
retained and must not be interpreted as calibrated alternative asphalt tuning.

## Tests and reproduction

The new real-Jolt audit covers entry speeds 0, ±2, ±4 and ±8 m/s, straight/left/
right half steering, and throttle released/held: 42 cases per car, 126 total.
Regression gates require stopping and holding, recovery after release, at least
25% shorter forward 8 m/s straight stops than the captured prior distances,
less than 20° peak low-speed sideslip and less than 90° accumulated rotation.
The thresholds distinguish the observed prolonged sliding/spin from a composed
low-speed stop. Angles are excluded below 0.5 m/s, where sideslip is ill-defined;
position, speed and yaw remain measured at standstill.

The prior RWD test insisted that full throttle create more sideslip than
coasting at 8 m/s. With the requested higher road grip, both may remain composed.
It now requires the powered turn to remain below 10° like the coast turn;
handbrake breakaway relative to coasting remains required for every drivetrain.
Control unit tests are explicitly included by the vehicle contract test root.

```sh
zig build vehicle-dynamics-report -Deditor=false -Doptimize=ReleaseSafe -- \
  --handbrake-audit game/vehicles/494e43494e455241-38d7f4075c7ac47d.icvehicle
zig build vehicle-motion-report -Doptimize=ReleaseSafe
zig build test-vehicle-dynamics test-vehicle-assets test-physics test-vehicle-feature -Deditor=false -Doptimize=ReleaseSafe
zig build test -Deditor=true
zig build verify-vehicle-background-macos -Deditor=true -Doptimize=ReleaseSafe
```

Validation: full editor-enabled suite **1,319/1,319 tests, 385/385 build steps**;
focused real-Jolt/asset/feature checks **83/83** before explicitly adding the
three pedal-policy unit tests; asset/control discovery **8/8** after that fix.
The shipping motion matrix passes **360/360** scenarios, and all **126/126**
held-stop cases complete. Hidden SDL/Metal acceptance passes **123/123 build
steps**, all three mixed-cadence drives and all three long-road acceleration/
braking drives. Cocoa observation reports **zero activation/window violations**.
All **six accepted-ingress replays verify** with the final ReleaseSafe source
cohort `12012028534066410874`. Captured road/town views were visually inspected;
vehicles are upright, aligned with the road and visible with cooked town content.
All native checks are background-only; no foreground SDL acceptance or
subjective human drive is claimed.

Complete [before/after definitions and comparison](vehicle-handbrake-grip/comparison.json),
low-speed reports, the full 360-case motion matrix, 648 steering experiments,
180-second speed reports and compressed characterization traces are retained in
[the evidence directory](vehicle-handbrake-grip/). The legacy/current no-argument
report remains a historical-default comparison, separate from the authored fleet.
