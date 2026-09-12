# Twice-speed fleet and increased grip

September 8, 2026. This tune follows the user’s feedback that handling is much better, the blue sedan feels most realistic, and the fleet needs approximately twice its speed with less tire sliding. Canonical definitions: sedan/coupe revision 7, SUV revision 6.

## Measured results

A fresh real-Jolt world, production 60 Hz, friction 0.2, 180 seconds of full throttle, no injected velocity or gear state:

| Vehicle | Previous settled speed | Current settled speed | Ratio |
|---|---:|---:|---:|
| Blue sedan | 93.1 km/h | 209.8 km/h | 2.25× |
| Coupe | 101.2 km/h | 198.4 km/h | 1.96× |
| Green SUV | 98.2 km/h | 194.2 km/h | 1.98× |

The last ten seconds’ acceleration is effectively zero. These are measured steady speeds, not speedometer scaling or a programmed speed cap. Each run then applies ordinary service braking and records distance/time to standstill. The regression requires at least 1.95× each retained baseline and a complete stop from the resulting speed.

At matched 24 m/s entry, half steering and full throttle, first-second yaw response rises from 20.67 to 23.47 degrees/s for the sedan, 20.34 to 26.20 for the SUV, and 25.78 to 26.62 for the coupe. Front slip falls from 6.86° to 5.83°, 6.29° to 5.45°, and 7.97° to 7.67° respectively. Coasting yaw increases from 24.29 to 29.52, 23.87 to 30.74, and 24.73 to 27.42 degrees/s. Entry speed is matched; open-loop acceleration afterward is deliberately retained in the reports.

## Authored changes

- Higher engine output with reduced low-RPM torque fractions: sedan 560 Nm, coupe 736 Nm, SUV 665 Nm. Sedan power rises later in the RPM range to retain manageable ordinary driving.
- Sedan/SUV lateral peak and sliding coefficients increase 2.025×; coupe coefficients increase 1.35× relative to the previous tune. The test surface and physics adapter are unchanged.
- Longitudinal peak/sliding coefficients increase: sedan front 3.5× and rear 3×, coupe both axles 5×, SUV front 5/3× with its existing rear grip retained. Front longitudinal sliding-slip points become 0.35 for the sedan and SUV, retaining lateral response under driven-wheel slip. Coupe rear sliding-slip point is 0.5.
- Coupe forward gears become 1.9, 1.25, 1.0, 0.9, 0.78, keeping the additional engine torque from overwhelming the rear tires at low speed. Sedan reverse becomes -4.0 after the faster powertrain reproduced unstable sustained reverse steering with the former gear. All four heading variants pass with the selected ratio.
- Sedan/coupe centre of mass lowers to -0.35 m; SUV retains -0.45 m. Steering lock, speed fractions, rise/return rates, drivetrain assignments and controls remain unchanged.

More engine power without sufficient traction was rejected: it caused driven-wheel spin and reduced powered turning response. A lower-output sedan with a late-rising torque curve also failed to sustain its higher gear; it is not the shipped definition.

## Complete coupled characterization

This is the separate historical 120 Hz characterization rig. Open-loop turn/slalom paths change with acceleration, so excursion alone is not an agility or grip score. Every metric is retained below; full characterization traces are gzip-compressed alongside the report.

| Metric, before → after | Sedan | Coupe | SUV |
|---|---|---|---|
| stopping_status | complete → complete | complete → complete | complete → complete |
| skid_status | complete → complete | complete → complete | complete → complete |
| stopping_entry_speed_mps | 15.006 → 15.015 | 15.010 → 15.018 | 15.012 → 15.031 |
| stopping_distance_m | 22.481 → 14.507 | 24.797 → 14.124 | 14.953 → 16.408 |
| stopping_time_s | 2.983 → 1.917 | 3.117 → 1.692 | 1.917 → 1.975 |
| steady_turn_radius_m | 15.000 → 18.190 | 12.756 → 12.730 | 17.378 → 23.157 |
| steady_turn_mean_slip_deg | 5.045 → 3.343 | 6.070 → 6.483 | 4.654 → 1.620 |
| slalom_lateral_excursion_m | 23.668 → 46.345 | 30.185 → 25.923 | 25.164 → 67.276 |
| slalom_peak_yaw_rate_deg_s | 42.864 → 59.771 | 51.451 → 50.253 | 41.289 → 53.448 |
| slalom_peak_slip_deg | 8.158 → 6.772 | 8.683 → 9.685 | 7.417 → 5.767 |
| skid_peak_slip_deg | 53.762 → 89.685 | 31.584 → 89.686 | 89.970 → 89.959 |
| skid_recovery_s | 1.633 → 1.783 | 2.200 → 1.900 | 4.208 → 1.917 |
| rollover_max_tilt_deg | 3.061 → 3.434 | 4.987 → 4.176 | 1.897 → 2.798 |
| rollover_occurred | False → False | False → False | False → False |

Handbrake skids remain deliberate and can create large chassis sideslip. No rollover occurred in this characterization. Human confirmation is still needed for subjective feel and recovery; faster travel also requires more stopping distance.

## Reproduce

```sh
zig build vehicle-dynamics-report -Doptimize=ReleaseSafe -- --speed-audit "$PWD/game/vehicles/494e43494e455241-20915108d5f1c706.icvehicle"
zig build vehicle-motion-report -Doptimize=ReleaseSafe -- --output /tmp/new-vehicle-motion
zig build vehicle-steering-report -Doptimize=ReleaseSafe -- --output /tmp/new-vehicle-steering
zig build verify-vehicle-background-macos -Deditor=true -Doptimize=ReleaseSafe
```

Use new output directories. The steering sweep now includes 48 and 56 m/s and records maximum chassis tilt. A 45-second run-up still marks unavailable entry speeds explicitly. Its support surface was enlarged to keep the faster run-up on the same controlled ground.

The native road journey now accelerates for 20 seconds, then observes ordinary braking for 20 seconds. It requires speed above 35 m/s, a stopped car inside the kilometre road, active road residency and continuous town decoration at the original disappearance location. The isolated long-run test proves terminal speed; the native journey proves accelerated streaming, rendering and stopping. Both remain distinct from exact SDL scheduling or subjective feel.

To drive the current definitions:

```sh
INCINERATOR_VEHICLE_ROOT="$PWD/game/vehicles" zig build run -Deditor=true -Doptimize=ReleaseSafe -- --editor-panels=vehicle_lab,world_outliner --editor-focus=vehicle_lab
```

First compare the blue sedan at 80–100 km/h with and without throttle through turns; then test faster straight travel and service braking. Use Space separately to assess handbrake recovery.

## Final acceptance

- Full regression: **1,315/1,315 tests and 385/385 build steps passed**, including the new terminal-speed/braking requirement.
- Motion matrix: **360/360 scenarios passed** across all three profiles and four headings.
- Background SDL/Metal: **3/3 tests and 123/123 build steps passed, zero desktop focus violations**. Road peaks were sedan 44.43 m/s, coupe 45.83 m/s, SUV 46.92 m/s. All stopped on the authored road with town and road residency checks passing.

All six final road/motion captures verify against installed content. Logical replay is deterministic; Metal/SDL scheduling remains a separate claim. Town and road captures were visually inspected for continuity and alignment. The sweep completed 648 experiments; 576 reached their requested entry speed, with 72 unavailable high-speed entries retained explicitly. Formatting and diff checks passed.
