# EA2 vehicle authoring validation

Implemented 2026-09-07 on Apple Silicon macOS with Zig 0.16.0 and the existing
pinned Jolt 5.5/JoltC revisions. Human judgment of the final driving feel remains
an iterative tuning task. The [research](../design/ea2-vehicle-dynamics-research.md)
and [implementation plan](../design/ea2-vehicle-authoring.md) explain the target.

## Delivered workflow

Open **Vehicle Lab**, select a car through the viewport or World Outliner, and
edit an owned draft. Chassis/layout, front/rear suspension, tires and brakes,
engine/gearbox, steering curves, assists and visual bindings are explicit.
Curve plots and full saved/admitted/candidate values use the actual definition.

- **Preview** changes compatible visuals only; inspection identifies its owner.
- **Measure** runs the immutable candidate in a separate renderer-free process.
  Its terminal result links the complete report and validates definition/build digests.
- **Apply** admits presentation or supported live settings at the authority tick.
- **Rebuild** explicitly reconstructs immutable physical settings. Collision,
  occupied layout, shifting and incompatible powertrain states reject atomically.
- **Revert** admits the saved definition through those same transition checks.
- **Commit** atomically saves the admitted selected car as a new archetype revision.
  Existing sibling cars retain their admitted definitions.

The project authoring directory is explicit:

```sh
zig build -Deditor=true
INCINERATOR_VEHICLE_ROOT="$PWD/game/vehicles" zig-out/bin/incinerator_engine
```

Without that environment variable, installed assets support inspect, draft,
preview, measure and session edits; project commit reports persistence unavailable.
The `.icvehicle` files are canonical. JSON files are initial authoring seeds;
regenerating visual GLBs does not replace handling. Ordinary builds install both
canonical definitions and cooked visual bundles. No missing-asset fallback exists.

For agents, start with `incinerator-dev agent bootstrap`, then `agent catalog`.
Discover the current run and stable authoring targets, retain expected instance
and asset revisions, follow every admitted transaction to its terminal result,
and inspect again. The executable catalog owns exact vehicle command syntax.
UI and CLI use the same vehicle owner and feature transactions.

## Game and engine ownership

`game/vehicles` owns the original Meridian RWD sedan and Courier FWD compact,
their dimensions, handling, visuals and initial fleet. Engine physics owns narrow
construction/live/rebuild capabilities; the vehicle feature owns each exact
admitted definition, revision, driver and conditioned input. Tooling owns drafts,
transactions, disk writes and measurement jobs. Cooked vehicle visuals have their
own GPU residency owner, separate from streaming world districts.

The tire adapter now converts authored radian lateral-slip coordinates to Jolt's
degree-based curve. A real-adapter readback test verifies the installed points.
Torque curves, gearing, differential distribution and independent axle settings
are explicit; no shipping car uses an implicit backend drivetrain default.

The chosen cars disable the pitch/roll limiter (`pi` radians). They retain visible
suspension movement and distinct RWD/FWD behavior. The historical flat benchmark
is 120 Hz; all fifteen extended maneuvers and prediction characterization run at
the product's 60 Hz. Reports retain the complete schedules, surface/obstacle
geometry, definition, build/cohort and per-tick telemetry. Unreached entry,
missing breakaway and incomplete recovery are explicit, never a fabricated zero.

The pinned Jolt tire model applies separate longitudinal/lateral friction limits.
EA2 does not introduce a combined-slip solver, tire temperature, damage, traffic
or a new camera model. Chassis sideslip and per-wheel slip are different signals;
near-rest chassis angles are not a useful measure of cornering grip. Wheel load
is an estimate from suspension impulse divided by timestep, with contact validity.

## Evidence

The complete editor aggregate passed **334/334 steps and 1,302/1,302 tests**.
This includes real-Jolt rebuild/save/replay with variable-length definitions,
malformed/stale revision rejection, immutable measurement ownership, byte-stable
restore, sibling isolation, reliable definition admission in embedded/dedicated
placements, client reset behavior, and full incident artifact ownership/digests.
The replay test deliberately alters the recorded candidate and observes tick-2
divergence after an exact successful replay.

Native industrial driving passed for both cars at 60 Hz through the normal player
input latch and session control path: walk to the car, enter, accelerate, steer,
handbrake, brake, and exit. Each car rendered 83 frames with cooked body/wheels;
peak speed was 8.154 m/s for Courier and 9.768 m/s for Meridian in the scripted
three-second acceleration/turn journey. This proves functioning control and
presentation, not subjective driving quality.

An installed native app/CLI journey measured an immutable candidate while the
world continued, applied torque, rejected a stale edit, rebuilt mass, reverted,
previewed a material from the other car's bundle, cleared preview, and committed.
The commit used a temporary project copy. Restart loaded the exact saved digest
at asset revision 2 with fresh instance revision 0. The repository's game assets
remain revision 1. The sibling car's digest stayed unchanged.

The completed incident contains ten correlated `vehicle_change` records and ten
full `vehicle-authoring/transaction-N.json` artifacts, with zero dropped records.
These own before/candidate definitions and result/run/tick/frame information;
timeline entries carry artifact SHA-256. Frame captures alone do not attach a
replay; accepted-ingress replay is independently verified by the real-Jolt test.

Retained final measurement and native/package gate results are recorded alongside
this ledger in `ea2-vehicle-authoring/`.

## Authored handling comparison

The [comparison JSON](ea2-vehicle-authoring/authored-comparison.json) retains every
maneuver summary, definition and schedule. Its four linked gzip artifacts contain
all original report bytes and per-tick traces. Both complete runs of each car were
identical on this machine/cohort; observed repeat variation was zero. This is an
observed baseline, not a universal numerical tolerance for other builds.

| 120 Hz historical flat rig | Meridian RWD | Courier FWD |
|---|---:|---:|
| Brake entry speed, m/s | 15.006 | 15.007 |
| Stop distance, m | 22.951 | 23.092 |
| Stop time, s | 3.000 | 3.025 |
| Steady turn radius, m | 16.742 | 12.619 |
| Slalom peak chassis slip, degrees | 9.455 | 16.671 |
| Induced skid peak slip, degrees | 5.472 | 22.265 |
| Recovery to the rig's stable condition, s | 0.775 | 3.408 |

All fifteen extended maneuvers reached their entry conditions at 60 Hz. Meridian
has approximately 2.38 degrees of roll in the ordinary turn sweep, versus 1.53
for Courier. The severe turn/curb produced 14.88 degrees of Meridian roll and
wheel contact loss; it did not demonstrate a full rollover. Courier's corresponding
path produced no wheel contact loss. Inputs after entry are open loop: entry speed
is not a speed-hold target, and different cars need not strike an obstacle along
the same trajectory. Complete traces retain those differences.

Meridian's straight acceleration/lift prediction error peaked at 0.073 m; its
8/16/24 m/s entry turn sweeps peaked at about 0.10/0.24/0.57 m. Courier's ordinary
turn maximum was 0.615 m. Across all maneuvers, including slides/obstacles, maximum
error was 0.569 m and 13.17 degrees for Meridian, and 1.240 m and 17.78 degrees
for Courier. There were zero hard corrections, history overflows or horizon
clamps in the specified 6-tick snapshot / 3-tick delivery-delay experiment.
Soft corrections remain visible in the report; this approximate predictor does
not reproduce authoritative tire, suspension or contact dynamics.

The deliberately softer intermediate sedan and loose-rear compact candidates
were evaluated before the selected assets. Final tuning balances visible body
motion with recovery; minimum roll or slip is not treated as a universal goal.
The old before/after tire-unit baselines remain preserved separately.

The installed [CLI journey](ea2-vehicle-authoring/installed-cli-journey.json) and
[incident transaction artifacts](ea2-vehicle-authoring/installed-incident-vehicle-changes.json)
retain the complete authoring evidence. Their earlier run IDs/build identity are
preserved rather than rewritten to impersonate the final validation build.

## Intentional cohort break

Network protocol 20, snapshot 16, replay cohort 20, district visual-bundle schema 6,
developer protocol 4 and vehicle asset format 1 are coordinated. Prior incompatible
cohorts reject explicitly. Saved worlds preserve exact admitted definitions,
including uncommitted session tuning, steering filter and powertrain state.
Clients admit immutable definition projections through reliable baselines before
ordinary snapshots can use them; disposable prediction resets on revision change.

## Next

Review both cars by hand in Vehicle Lab, compare the report traces with their
visible dive, squat, roll and recovery, and tune the game assets with the new
workflow. EA3 authored lighting remains the next engine-authoring roadmap phase;
EA4 map authoring and EA5 separate game packaging follow it. No earlier evaluation
scene dimensions or fixtures constrain this vehicle work.

## Native and packaging gate notes

The final native pointer suite passed 46/46 steps and 74/74 tests. It covers
Material Lab and Vehicle Lab draft controls, press/drag/release, held-drag Escape
cancel, both viewport modes, rebuild/apply/revert and durable restart. Vehicle
labels now avoid nested use of ImGui's shared formatting buffer; asset combo IDs
remain stable when their selection changes. The authoring journeys settle hover
before pressing; the separate same-pump routing test still covers a new press
without a preceding ImGui frame.

Real-GNS listen and dedicated process gates each passed 63/63 steps and 7/7
composition tests. The listen proof includes walk/drive/carry and retained-seat
reconnect. An earlier listen run concurrent with the aggregate build timed out
and then hit the existing room reconnect transition guard; the identical isolated
repeat passed. Compilation contention is a possible contributor, not a proved
root cause. No networking timeout or capacity was changed for that run. The
dedicated script's stale end-of-line check was corrected to accept the already
reported population telemetry after the expected room-close fields.

The final [gate manifest](ea2-vehicle-authoring/gates.json) links complete logs.
Editor-on passes 334/334 steps and 1,302/1,302 tests; editor-off passes 329/329
steps and 1,196 tests with two intentional editor-only skips. The extracted
source package passes 193/193 steps with 451 tests, plus its isolated headless
product gate at 33/33 steps and 56 tests. Package membership explicitly includes
the authored car files, cooked-source GLBs, narrow C++ bridge and authoring owners.
