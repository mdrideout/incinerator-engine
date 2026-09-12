# Stronger steering experiment — September 7, 2026

User-requested exact content change: increase maximum steering angle by 10%
and double every speed-curve fraction. Fractions saturate at 1 because they
represent a proportion of maximum steering lock; this is the existing typed
contract, not an additional safety limiter. Rise/return rates are unchanged.

All three vehicles now use 0.6143559 rad (35.2°) maximum lock and these points:

| Speed m/s | km/h | Fraction | Available angle |
| --- | --- | --- | --- |
| 0 | 0 | 1 | 35.2° |
| 8 | 28.8 | 1 | 35.2° |
| 18 | 64.8 | 0.96 | 33.792° |
| 30 | 108 | 0.64 | 22.528° |

Canonical assets and JSON mirrors advance to Courier/Meridian revision 4 and
SUV revision 3. This changes source defaults, not an already running instance.

## Results: candidate has unresolved failures

Before values come from the [responsive fleet](vehicle-responsive-fleet.md).
After metrics, exact definitions and complete compact motion matrix are retained
in [vehicle-steering-lock/](vehicle-steering-lock/).

| Metric, before → after | Sedan | Coupe | SUV |
| --- | --- | --- | --- |
| Steady turn radius m | 15.37 → 9.12 | 13.26 → 11.00 | 17.97 → 10.57 |
| Mean turn sideslip ° | 4.35 → 6.85 | 4.47 → 5.57 | 3.93 → 6.49 |
| Slalom excursion m | 26.28 → 31.37 | 28.43 → 26.52 | 24.91 → 25.17 |
| Slalom peak yaw °/s | 34.49 → 39.49 | 35.52 → 33.39 | 31.30 → 33.28 |
| Slalom peak sideslip ° | 6.65 → 7.43 | 5.47 → 5.29 | 6.20 → 6.58 |
| Skid peak sideslip ° | 45.96 → 14.55 | 14.26 → 2.62 | 21.55 → 2.90 |
| Skid recovery s | 1.98 → 1.22 | 2.17 → not measured | 2.61 → not measured |
| Rollover fixture peak tilt ° | 2.07 → 1.46 | 2.84 → 2.56 | 1.95 → 1.61 |

Stopping distances/times are unchanged (22.20 m/2.96 s, 26.41 m/3.28 s,
25.72 m/3.29 s respectively). No fixture rollover occurred. Tighter turning
is measured, but it is not a complete handling improvement: coupe and SUV
did not reach the required handbrake breakaway in the characterization fixture,
so their recovery times are unavailable rather than zero.

The full 360-scenario motion matrix executed but failed verification in five
profile/heading workers: sedan at 180° and 270°, SUV at 0°, 180° and 270°.
Each reports `MotionAuditDidNotReverse`; forward-to-reverse with steering
finished with positive forward velocity. The exact requested values remain
in the content for review. No gates, pedal logic or other tuning were changed
to mask these failures. Rendered acceptance was not run because deterministic
gates failed. A stronger-steering baseline requires a follow-up investigation
of direction transitions and handbrake breakaway before acceptance.

Commands run:

```sh
zig build vehicle-dynamics-report -Deditor=false -Doptimize=ReleaseSafe
zig build test-vehicle-dynamics test-vehicle-assets test-vehicle-feature test-physics -Deditor=false -Doptimize=ReleaseSafe --summary all
zig build vehicle-motion-report -Doptimize=ReleaseSafe -- --output /tmp/vehicle-steering-lock/motion
zig build test -Deditor=true --summary all
```

The focused group passed 79/80 tests; the authored dynamics test fails on the
coupe's missing skid breakaway. Standalone per-definition measurements also
identify the SUV's missing breakaway, which the fail-fast test does not reach.
The full editor-enabled suite passed 1,310/1,311 tests, with that same dynamics
failure. See `vehicle-steering-lock/full-tests.log` for the complete result.

## Live editing versus rebuild

Steering conditioning is owned by the vehicle feature and read each tick.
Maximum steering angle belongs to Jolt wheel configuration; our current adapter
does not expose it through `VehicleLiveSettings`. Thus Apply admits rate/curve
changes, while maximum angle requires Rebuild. The latter reconstructs physics
in the running game and preserves motion; it is not a program build or restart.

More scalar/curve settings could have explicit in-place update support. Making
all settings update in place is not the same problem: chassis shape, wheel
placement and drivetrain structure need coordinated reconstruction and state
validation. A future unified Apply action could route between those paths and
report the resulting operation. No authoring UI or backend mutation contracts
were changed in this content-only experiment.
