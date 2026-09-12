# Stronger cornering and town visual residency

September 8, 2026. Work follows the human report at run
`/Users/matt/Library/Logs/Incinerator/runs/2026-09-08T14-02-37.197Z_solo_1d885add`, anomaly 1. The original run remains untouched.

## Cornering result

At 24 m/s (86.4 km/h), half steering and full throttle, mean yaw response during the first second improved:

| Vehicle | Before, degrees/s | After, degrees/s | Increase | Front slip before → after |
|---|---:|---:|---:|---:|
| Green SUV | 12.81 | 20.34 | 59% | 6.99° → 6.29° |
| Blue sedan | 13.93 | 20.67 | 48% | 7.53° → 6.86° |
| Coupe | 15.21 | 25.78 | 69% | 7.79° → 7.97° |

Coasting response increased 40–43%. This is matched entry speed and identical input, not an assertion that cars maintain the same speed throughout a turn. Complete per-phase speed, tire load, slip and force evidence is in `vehicle-grip-town/final-steering/`; the earlier sweep remains in `vehicle-high-speed/steering-sweep/`.

Authored lateral peak/sliding coefficients increase 3x for the fleet. Rear brake torque becomes 600 Nm. SUV longitudinal grip also increases 3x, and its centre of mass lowers to -0.45 m. SUV/coupe rear sliding-slip values are 0.12/0.30 to preserve rear breakaway. No steering lock or speed-curve increase, global floor change, hidden yaw assist, or input mapping change was made. Current definition revisions are sedan 6, coupe 6, SUV 5.

The tuning tradeoff is more pronounced handbrake rotation. The 120 Hz induced-skid rig reports SUV peak chassis sideslip near 90° and recovery in 4.21 seconds; coupe recovery is 2.20 seconds and sedan 1.63 seconds. All complete without rollover. This is an intentionally aggressive handling candidate and still needs human feel confirmation, especially handbrake recovery. A rejected 5x-grip candidate rolled the SUV; it was not promoted.

## Coupled 120 Hz characterization

All runs use a fresh real-Jolt world and the exact retained before/after definitions.

| Metric, before → after | Sedan | Coupe | SUV |
|---|---:|---:|---:|
| Stop distance from 15 m/s, m | 22.20 → 22.48 | 26.41 → 24.80 | 25.72 → 14.95 |
| Stop time, s | 2.96 → 2.98 | 3.28 → 3.12 | 3.29 → 1.92 |
| Steady turn radius, m | 15.37 → 15.00 | 13.26 → 12.76 | 17.97 → 17.38 |
| Steady mean sideslip, degrees | 4.35 → 5.05 | 4.47 → 6.07 | 3.93 → 4.65 |
| Slalom excursion, m | 26.28 → 23.67 | 28.43 → 30.19 | 24.90 → 25.16 |
| Slalom peak yaw, degrees/s | 34.49 → 42.86 | 35.52 → 51.45 | 31.30 → 41.29 |
| Slalom peak sideslip, degrees | 6.65 → 8.16 | 5.47 → 8.68 | 6.20 → 7.42 |
| Skid peak sideslip, degrees | 45.96 → 53.76 | 14.26 → 31.58 | 21.55 → 89.97 |
| Skid recovery, s | 1.98 → 1.63 | 2.17 → 2.20 | 2.61 → 4.21 |
| Maximum rollover tilt, degrees | 2.07 → 3.06 | 2.84 → 4.99 | 1.95 → 1.90 |
| Rollover | no → no | no → no | no → no |

The sedan's stopping distance increases about 1.3%. The SUV brakes substantially sooner but takes longer to recover from the induced skid. These are explicit tradeoffs, not claims of universal improvement.

## Rendering diagnosis and repair

The original flag image shows the parked cars against empty sky where town should appear. Vehicle position was approximately (-11.94, 1.01, -70.31), looking back toward town. Entity draw memberships remain present. The bundle validates with zero drops, writer failures, suspicious frames or warnings, and its 5,341-tick semantic replay verifies with the matching ReleaseSafe build. Debug replay correctly rejects the different simulation cohort.

Town visuals previously used only 24/28 m load/unload margins, while the test road used 256/260 m. Additionally, logical district departure destroyed the GPU scene even when predicted visual proximity still wanted it. Town now shares the road's visual horizon. Once logical extraction ends, a still-wanted scene returns to the reserved/prefetched state without GPU recycling and can bind a fresh authority ticket. Before the unload outcome, existing logical extraction draws the scene; afterward, prefetched decoration draws it. Collision and NPC activation still follow authority residency. The coordinator regression proves retention, reactivation with a fresh ticket, rejection of the old ticket and final release.

Retaining town alongside road cells can exceed the old 32 MiB resident allowance. The resident GPU budget is now 64 MiB for the authored 20-scene cohort; staging and per-submit budgets stay unchanged.

The strict incident inspector also hit a real 8 MiB file-read limit on the materialized vehicle/wheel state window. Materialized-window reads now accept the complete file; the original incident subsequently validated.

## Validation

- Vehicle dynamics gate: 6/6 passed, including all-profile handbrake, power-slide and no-rollover checks.
- Full direction/braking/steering/alignment matrix: 360/360 passed.
- Controlled sweep: complete reports include unavailable run-up speeds explicitly.
- Native background acceptance additionally checks all four town decorations through departure at z=-45…-90 and captures a look back at z=-70, while retaining the long-road acceleration/braking journey.

Run background acceptance:

```sh
zig build verify-vehicle-background-macos -Deditor=true -Doptimize=ReleaseSafe
```

Start an interactive drive with the current definitions:

```sh
INCINERATOR_VEHICLE_ROOT="$PWD/game/vehicles" zig build run -Deditor=true -Doptimize=ReleaseSafe -- --editor-panels=vehicle_lab,world_outliner --editor-focus=vehicle_lab
```

Compare the SUV and sedan around 80–90 km/h, then release throttle before turning and separately test Space handbrake recovery. Drive out of town and look back from the first road segment. Live Apply updates admitted tuning; the SUV centre-of-mass change requires reconstruction, selected automatically by Apply.

Final native result: **3/3 tests, 123/123 build steps, zero desktop focus violations**. All three vehicles passed uninterrupted town-decoration checks and long-road stopping. The [SUV look-back capture](vehicle-grip-town/town-fixed.png) was visually inspected and shows the town and parked cars correctly grounded. Full regression: **1,314/1,314 tests and 385/385 build steps passed**.

All six final accepted-ingress captures verified against the installed content. This proves logical replay, not exact Metal/SDL scheduling. The final look-back PNG is byte-identical to the inspected capture. The controlled sweep completed 432 experiments, with 324 matched-speed entries and 108 unavailable 30 m/s entries.
