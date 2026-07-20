# Vehicle Dynamics Characterization

**Status:** Implemented and automated
**Date:** 2026-07-19
**Product target:** Apple Silicon macOS
**Physics cohort:** Jolt 5.5 through the pinned JoltC adapter, 120 Hz

## Purpose

Vehicle feel is subjective, but tuning changes need objective characterization
before a human drive. `tools/vehicle_dynamics.zig` runs six renderer-free
scenarios against the real Jolt adapter in fresh worlds and compares the exact
pre-change profile (`legacy`) with current authoritative defaults (`current`).

Run:

```sh
zig build vehicle-dynamics-report -Deditor=false
zig build test-vehicle-dynamics -Deditor=false
```

## Current tuning cohort

The current cohort lowers the center of mass from -0.25 m to -0.38 m, changes
suspension frequency/damping from 1.5/0.5 to 1.8/0.7, reduces maximum steering
lock from 30° to 28°, and raises service brake torque from 1,500 to 2,200 Nm.

Every wheel receives explicit Jolt friction curves:

| Curve | Peak | Sliding |
|---|---:|---:|
| Longitudinal | 1.40 at 0.06 slip | 1.15 at 0.20 slip |
| Lateral | 1.65 at 3° | 1.40 at 20° |

The legacy row uses Jolt's prior effective curve values: 1.20 peak and 1.00
sliding for both axes, with the same slip/angle points.

## Results

| Metric | Legacy | Current | Change |
|---|---:|---:|---:|
| Brake entry speed | 15.003 m/s | 15.009 m/s | matched |
| Stopping distance | 25.320 m | 23.164 m | -8.5% |
| Stopping time | 3.258 s | 3.017 s | -7.4% |
| Steady turn radius | 5.729 m | 6.107 m | +6.6% |
| Steady turn mean slip | 23.806° | 23.573° | -1.0% |
| Slalom lateral excursion | 36.213 m | 40.145 m | +10.9% |
| Slalom peak yaw rate | 57.718°/s | 57.368°/s | -0.6% |
| Slalom peak slip | 15.048° | 10.671° | -29.1% |
| Skid peak slip | 5.719° | 5.600° | -2.1% |
| Skid recovery | 0.275 s | 0.250 s | -9.1% |
| Rollover maximum tilt | 3.795° | 2.187° | -42.3% |
| Rollover occurred | no | no | unchanged |

## Assessment

The new profile brakes materially sooner, produces much less peak slalom slip,
recovers from the induced skid faster, and reduces measured rollover tilt. The
slightly larger constant turn radius is expected from the 28° steering lock.
The larger slalom excursion is not treated as a standalone regression: yaw
rate is essentially unchanged while peak slip falls sharply, indicating a
wider, more controlled path rather than greater lateral breakaway.

The automated gate requires no rollover, improved stopping distance, improved
slalom peak slip, and skid recovery no worse than legacy. All other metrics are
reported so a future change cannot optimize one value invisibly.

## Method boundaries

This is deterministic characterization, not final vehicle certification. The
surface is flat, the vehicle has no aerodynamic model or assists, inputs are
step functions, and there is one speed/load cohort. Terrain materials, tire
temperature, analog controller curves, load transfer under varied cargo,
network prediction, curb strikes, and subjective play feel still require
separate future work and rendered human acceptance.

The reusable workflow lives in
[`skills/incinerator-vehicle-tuning/SKILL.md`](../../skills/incinerator-vehicle-tuning/SKILL.md).

