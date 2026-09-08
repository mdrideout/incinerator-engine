# EA2-H handling profiles

Engineering verification passed; human driving-feel acceptance is pending.
The original human incident directory remains unchanged.

## Implementation and ownership

Space is held rear handbrake while driving and a jump edge on foot. S brakes
forward motion before reverse; W is symmetric. W+S service-brakes with no
propulsion. The shared fixed-tick resolver also checks horizontal speed and
current gear: crossing zero forward speed during a sideways skid is not a stop.
Left Shift retains Free Camera acceleration and has no vehicle brake binding.

The pinned Jolt adapter uses a smooth combined-slip response. Pure longitudinal
and lateral curves remain authored; each axis loses capacity as slip on the
other axis grows, normalized by that axle's authored sliding coordinates.
This is an empirical grip response, not a full tire thermodynamics model.
There are no drivetrain-name force branches or injected chassis yaw impulses.

`game/vehicles/handling_profiles.zig` projects canonical handling onto a target
without replacing its identity, revision, visuals or physical attachment geometry.
Vehicle Lab and `vehicle.inspect` consume that same projection. The inspection
includes source ID/revision/digest and the complete candidate. Loading a preset
only dirties the draft; measure, rebuild, apply and commit retain the existing
revisioned owner. The executable CLI catalog describes this discovery path;
there is no additional mutation operation or runtime preset inheritance.

## Diagnosis and rejected alternatives

The original Courier already drove the front axle, and rear handbrake torque
already locked only the rear wheels. In the matched one-second handbrake window,
all 120 rear contact samples locked; none of the front samples locked. Yet the
pinned default tire callback supplied independent full longitudinal and lateral
limits, preserving excessive lateral capacity during longitudinal sliding.

Courier also combined excessive low-gear wheelspin, equal axle lateral curves
and excessive rear service braking. Front engine/wheel rotational energy could
counter rear braking after throttle release: measured front and rear contact
forces were nearly equal and opposite in the straight handbrake window. Merely
increasing rear handbrake torque would not fix these causes.

The industrial ground and measurement rig both use the same static-box adapter,
whose effective friction reads back as 0.2. The game ground is created by
`Simulation.init` through `Physics.createStaticBox`; visual asphalt roughness
is not a physics friction setting. A real-adapter readback regression locks this
comparison to evidence rather than a material-name assumption.

Rejected prototypes include discontinuous normalized-slip coupling (reverse
entry failure), peak-coordinate coupling, overpowered Courier variants,
Meridian's overly loose rear/power balance, and AWD with implicit 1.4 center
limited-slip coupling. The last redirected drive toward a slowed rear axle and
failed release recovery. Explicit open-center coupling recovered in the matched
comparison. Lower AWD rear sliding coordinates then reconciled the short
power-plus-handbrake and longer unpowered handbrake schedules; neither schedule
was weakened to pass the candidate.

Full exploratory reports remain under `/tmp/ea2h`. Checked-in compact evidence
retains exact definitions, input schedules, headings, axle phases and rejected
results. Historical baseline source cohorts differ deliberately from the final
cohort; they are comparison evidence, not current replay compatibility claims.

## Promoted content

| Profile | Revision | Driven axles | Peak torque | Rear service torque/wheel | Rear longitudinal slide coordinate | Center coupling |
|---|---:|---|---:|---:|---:|---|
| Courier compact | 2 | Front | 140 N m | 300 N m | 0.4 | 1.4; only one axle connected |
| Meridian road sedan | 2 | Rear | 230 N m | 450 N m | 0.6 | 1.4; only one axle connected |
| Courier AWD | 1 | 70% front / 30% rear | 140 N m | 300 N m | 0.32 | Open |

Courier AWD shares Courier geometry and visuals and has its own durable identity.
It is parked at (-6, 1, -4), northwest of the original two cars, with a separate
clear lane. Readback verifies connected axle count, front-only versus rear-only
selection, center ratio and zero front handbrake torque.

The standard 120 Hz characterization measured:

| Profile | Stop from 15 m/s | Steady turn slip | Handbrake peak slip | Recovery |
|---|---:|---:|---:|---:|
| Courier | 22.62 m / 3.00 s | 4.37° | 44.73° | 1.98 s |
| Meridian | 25.85 m / 3.31 s | 4.51° | 15.49° | 2.28 s |
| Courier AWD | 22.93 m / 3.00 s | 4.14° | 4.15° | 0.99 s |

These values describe the retained scripted maneuver, not universal limits.
The separate 60 Hz matched-handbrake maneuver has a longer unpowered turn and
produces substantially more AWD rotation. Reports distinguish the schedules.

Regression expectations require composed coast/service turns (<10° chassis slip,
well separated from the original ~84° failure), additional rotation under
handbrake, straight rear drag without a yaw kick, actual rear locking with front
wheels rotating, and complete measured recovery. RWD power slip must exceed its
coast baseline. Full motion audits retain all entry, stop, direction-change and
alignment failures rather than dropping incomplete cases.

## Intentional compatibility changes

- Vehicle asset envelope and definition version: ICVEHDEF 2.
- Explicit `powertrain.center_limited_slip_ratio`, finite and >1; f32 maximum
  selects open coupling. Rebuild-only; copied, digested and replayed in full.
- Network protocol 21, snapshot schema 17, accepted-ingress replay schema 21.
- Developer protocol 5 and its updated canonical vehicle schema digest.
- Incident schema stays 5; mapping version 2 explicitly records physical Space,
  occupancy and mapped actions. Graphical replay rejects old/missing mappings.

Rebuild/install the game and content together. Old same-cohort recordings and
old vehicle files are intentionally rejected, not silently reinterpreted.

## Verification record

All runs use Debug, Zig 0.16.0, aarch64, pinned Jolt
`23dadd0e603f1b321142d4c74df07fce85064989` and final source cohort
`8435456339590904288`.

| Gate | Result |
|---|---|
| Focused controls/physics/assets/authoring/dynamics/protocol/host | 408/408 tests |
| Native editor pointer/Vehicle Lab | 74/74 tests; preset load changes draft only |
| Native mouse capture/routing | Passed |
| Full editor-enabled aggregate | 335/335 build steps; 1,313/1,313 tests |
| Full editor-off aggregate | 330/330 steps; 1,207 passed, 2 skipped |
| Filtered source package | Passed; packaged 455-test suite and 56-test headless suite |
| Final motion matrix | 120 cases / 37,080 ticks per car; all completed |
| Repeatability | All three complete JSON reports byte-identical on repeat |
| Native presentation | 1,375 audited frames per car; zero frozen moving sub-tick frames |

The original editor-off aggregate first rejected an unclassified import for the
new game-tooling preset helper. The explicit ownership manifest was updated;
the rerun passed. Expected failure-injection warnings in persistence tests are
not test failures. Complete command logs are retained beside this document.

The steering sweep corroborates Courier understeer beyond speed-dependent
steering reduction: at entry speeds 2/8/16 m/s, measured mean path curvature
was 0.084/0.046/0.021 per metre, versus actual-wheel-angle kinematic references
0.089/0.060/0.056. Front mean slip grew 1.10/3.88/7.56 degrees while rear slip
was 0.29/1.92/2.68. Matched coast/power and wheel loads are retained separately;
these are transient sweep measurements, not controlled steady-state circles.

The longer matched handbrake scenario produces peak chassis slip of about
38.5° Courier, 30.8° Meridian and 45.3° AWD. Courier and AWD settle to approximately
0°/0.5° by its end. Meridian still has approximately 16° residual slip after
that scenario's three seconds of straightening with light throttle; the separate
standard recovery maneuver completes in 2.28 seconds. This distinction is kept
visible for human tuning rather than presenting one recovery value as universal.

Final native incident runs:

- Courier: `zig-out/vehicle-motion-runs/2026-09-07T23-13-27.109Z_solo_bdd3830a`
- Meridian: `zig-out/vehicle-motion-runs/2026-09-07T23-14-41.466Z_solo_feed8a9a`
- AWD: `zig-out/vehicle-motion-runs/2026-09-07T23-15-30.680Z_solo_a990b83d`

Their complete `vehicle-motion-native-*.icrp` files verified **2,770 / 2,041 /
1,947 ticks** respectively against the current installed content. The native
SDL journey covers W acceleration, S braking/reverse, W braking/forward,
steering during braking, W+Space, Space release, W+S, focus loss/regain and
exit/re-entry with Space held. Scripted motion separately covers all three cars
in fixed and chase views with 30/60/144 Hz and irregular presentation cadences.

The explicitly **authored**, not human-recorded, graphical fixture in
`graphical-control-fixture/` completed the normal product loop at tick 1181.
Its new run is
`/Users/matt/Library/Logs/Incinerator/runs/2026-09-07T23-16-47.222Z_solo_67099ec1`.
Vehicle telemetry confirms forward 6.19 m/s, reverse -6.17 m/s, forward 5.24 m/s,
held Space with propulsion/steering, W+S stopping, and exit. See
`graphical-replay-result.json`. Ordinary graphical completion does not write a
flight capture unless diagnostics are requested; the three native recordings
above provide the full semantic replay proof.

Live CLI acceptance bootstrapped protocol 5 and discovered all three car targets
and all three preset sources. On a temporary project copy, it measured the
Courier-AWD preset projected onto Courier, rebuilt it at instance revision 1,
committed asset revision 3, then cold-launched the graphical product again.
The freshly admitted definition equaled the complete committed value exactly,
including center coupling; all three cars still existed. Native Vehicle Lab
acceptance and CLI inspection share the same candidate projection. Existing
stale-revision, rejected rebuild and persistence-failure tests passed.

CLI evidence is in `cli-measure.json`, `cli-rebuild.json`, `cli-commit.json` and
`cli-restart.json`; its correlated UI frame is `cli-authoring.png`. Only
`/tmp/ea2h/cli-vehicles` was committed by this acceptance exercise. Repository
and installed baselines retain Courier FWD, Meridian RWD and Courier AWD.

Remaining product acceptance: have a human drive the three baselines, particularly
Meridian recovery and AWD's stronger long-hold handbrake response. This work does
not resolve the separately observed approximately 30 FPS renderer throughput;
injected native cadence verifies interpolation and alignment, not GPU performance.
