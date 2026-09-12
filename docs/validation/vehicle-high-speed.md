# Controlled high-speed steering and streamed test road

September 7, 2026. The prior doubled-fraction/+10% lock experiment is reverted
to the last passing steering values. Meridian/Courier revisions are 5; SUV is 4.
The coupe/sedan/SUV bodies, quicker steering conditioning and single Apply UI
remain. Production surface friction is unchanged in this investigation.

## Driving area

The three cars start at z=-8, x=4/0/-4, facing -Z. Sixteen 64 m districts extend
the existing street south to z=-1056. The added road is 24 m wide with paved
runoff, lane edges and marker blocks. The original four neighborhood districts
remain. Visual prefetch looks four road cells ahead; the old 24 m neighborhood
margin made the road appear to end just beyond the lineup. Normal game residency
now follows the driver instead of pinning the entire original neighborhood. Geometry and marker collision are generated together; materials are
admitted without overwriting existing authored values or bindings.

This is ordinary catalog-backed content, not a permanently drawn test overlay.
The continuous support body covers the extended road, and the recipe, navigation
topology, catalog, installed bundles and headless content digests are coordinated.
Recipe version advances to 10. GPU scene slots, relevance baseline and diagnostic district slots
now cover the actual 20 districts. Navigation search breadth covers their 240
nodes; retained NPC route length is unchanged. These changes resolve observed
four-district array overflow, GPU scene recycling and planner exhaustion during
regression tests. GPU byte budgets and logical active-district capacity remain
unchanged; scenes stream around the driver. The isolated multiplayer fixture
still bootstraps only its original four neighborhood districts.

## Controlled experiments

```sh
zig build vehicle-steering-report -Doptimize=ReleaseSafe -- --output /tmp/vehicle-steering-run
```

Use a new output directory. This runs without a renderer or window and records
the definition, digest and source cohort. It executes 144 rows per car:

- Entry speed: 8, 18, 24 and 30 m/s (29, 65, 86 and 108 km/h).
- Throttle during the turn: coast or full power.
- Steering input: 0.1, 0.5 or 1.0.
- Support-body friction: 0.2, 0.6 or 1.0.
- Initial heading: 0° or 90°.

Each row starts in a fresh real-Jolt world, settles, and accelerates naturally
for up to the specified 45-second experiment before a two-second steering step.
No initial velocity, gear or wheel rotation is fabricated. The same entry phase
is used for paired throttle/steering tests. Across surface values, traction can
change run-up distance and drivetrain state; these are not identical-state
friction swaps. The support spans 3 km to contain the measured run-up and turn.

Every turn tick contributes to separate first/second-second summaries: actual
wheel angle, conditioned input, yaw rate, curvature, speed, axle slip, wheel
contacts, estimated loads and tire forces. Half-second heading change measures
turn-in. Yaw-derived lateral acceleration is identified as such; it is not an
accelerometer measurement. Unreached entry speeds are explicit and have no turn
samples. A successful batch means experiments completed, not handling acceptance.

For one candidate definition:

```sh
zig build vehicle-dynamics-report -Deditor=false -Doptimize=ReleaseSafe -- --steering-audit /absolute/path/car.icvehicle
```

The existing motion-audit command remains available for full per-tick driving
traces and the reverse/brake/handbrake matrix.

## Findings

The road body and old rig both used Jolt's default 0.2 friction. Render-material
roughness does not control tire contact friction. The new adapter experiment
sets support friction explicitly without changing production body creation.

All three cars reached 8, 18 and 24 m/s. None reached 30 m/s within the 45-second
run-up: final speeds ranged approximately 25.6–28.6 m/s across cars/surfaces.
Thus 324 of 432 rows produced turn measurements; the other 108 explicitly report
unavailable entry. The first batch took 6.20 seconds after compilation.

SUV at 24 m/s, first second of coasting:

| Surface friction | Input | Mean wheel angle | Mean yaw rate | Front lateral slip |
| --- | --- | --- | --- | --- |
| 0.2 | 0.5 | 6.48° | 16.76°/s | 7.98° |
| 0.2 | 1.0 | 12.72° | 14.58°/s | 13.87° |
| 0.6 | 0.5 | 6.50° | 23.22°/s | 6.99° |
| 1.0 | 0.5 | 6.53° | 35.17°/s | 4.78° |

At full power and half steering, the corresponding yaw rates are 12.81, 21.00
and 34.58°/s. These are strong evidence that low support friction and front tire
saturation contribute to the reported understeer. More wheel angle can reduce
turning response. They do not prove that friction 1.0 is a suitable final road
setting: brake distances, handbrake breakaway, rollover and drivetrain balance
must be revalidated before promoting a new surface/tire combination.

The complete per-car reports are retained in
[vehicle-high-speed/steering-sweep/](vehicle-high-speed/steering-sweep/).

## Product-road acceptance

```sh
zig build verify-vehicle-background-macos -Deditor=true -Doptimize=ReleaseSafe
```

The offscreen suite retains its mixed-cadence driving scenarios and adds a
30-second acceleration / six-second braking journey for each car down the real
streamed road. It requires district draws throughout, more than 300 m of southward
travel, speed above 20 m/s and a stopped final car, with its actual current road district resident. Every tick writes speed,
position and district draw count to `zig-out/vehicle-road-<car>.ndjson`; accepted
ingress is retained in the matching `.icrp`. This is the straight-road streaming
proof; the isolated rig owns the controlled lateral/surface comparisons.

For interactive testing:

```sh
INCINERATOR_VEHICLE_ROOT="$PWD/game/vehicles" zig build run -Deditor=true -- --editor-panels=vehicle_lab,world_outliner --editor-focus=vehicle_lab
```

Select a car and drive south. S brakes then reverses, Space operates the handbrake.
Apply changes the selected running car; Commit Admitted Car saves its admitted
definition. Surface-friction variants currently belong to the controlled rig,
not the Vehicle Lab UI.

The initial five-second braking window left the SUV moving at 0.80 m/s; the
road experiment now measures six seconds while keeping the <0.25 m/s stop
criterion. Replay capture drains pending streaming commands through normal
ticks before snapshotting. No authority commands are discarded.

## Final validation — September 8, 2026

- Full regression: **385/385 build steps, 1,313/1,313 tests passed**.
- Restored-profile motion matrix: **360/360 passed**.
- Controlled sweep: **432 experiments completed in 5.37 seconds** after compilation; 324 reached their requested entry speed. The 108 experiments targeting 30 m/s did not reach it within the 45-second run-up and are explicitly unavailable, not handling passes.
- Native background acceptance: **3/3 tests passed**, with **zero desktop focus violations**. All three body styles passed mixed-cadence motion/rendering checks and the streamed-road journey.
- Road peaks: Courier **24.52 m/s**, Meridian **26.81 m/s**, SUV **25.73 m/s**. They travelled beyond 600 m, retained their actual road district in GPU residency, and stopped below 0.25 m/s after the six-second brake phase.
- All **six accepted-ingress captures verified** against installed content. This checks logical replay; graphical scheduling remains best effort.
- The SUV road image was visually inspected for road continuity and vehicle alignment. Formatting and diff-whitespace checks passed.

The road acceptance exposed two infrastructure issues: the four-scene GPU registry recycled road scenes prematurely, and streaming commands could remain pending at replay capture. The registry now accommodates the authored 20-district world while retaining existing byte budgets; capture advances ordinary simulation frames until admitted commands drain. Normal sandbox residency now follows the vehicle rather than pinning the initial neighborhood.

Logs, six replay captures, compressed road traces and the inspected [SUV road image](vehicle-high-speed/suv-road.png) are retained alongside this report. Production surface friction is still 0.2; the next tuning step is to select a higher-grip candidate and validate braking, handbrake breakaway, rollover and drivetrain distinctions before promoting it.
