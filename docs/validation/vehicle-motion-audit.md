# Vehicle motion audit — 2026-09-07

Current routine commands use [background testing](vehicle-background-testing.md):
compact headless batches and offscreen Metal acceptance. The incident findings
and historical evidence below describe their original cohort.

This closes the vehicle direction, wheel alignment, render-cadence and replay
coverage gaps exposed during EA2 human testing. It does not certify final driving
feel. Both shipping definitions remain at their existing authored revision.

## Incident findings

Original evidence, preserved unchanged:
`/Users/matt/Library/Logs/Incinerator/runs/2026-09-07T19-50-20.255Z_solo_ddadac9e`.
Anomaly 1 was flagged at tick 4800: “weird car handling and skidding, glitchy feeling”.

- Inspection validates the bundle. Its `running` manifest is a valid snapshot of
  a live recording; the anomaly itself has complete visual evidence.
- The moving car is Courier, replicated local 4294967314. The selected identity
  in the marker is the parked Meridian, local 4294967313. Selection alone was
  insufficient to identify the problem vehicle.
- Sampled frame times span 32.25–50.48 ms, median 36.09 ms. Low frame rate is a
  real contribution; this work does not claim to fix the renderer's throughput.
- The original compatible semantic replay matches through the flag, then
  diverges at tick 5278 in **NPC** state. The whole original replay is not clean.
  The compatible executable and detailed analysis remain in
  `/tmp/incinerator-motion-audit`; inspection/replay results are retained beside
  this document. The later NPC divergence is a separate unresolved finding.
- The original 250 ms state sampler and 15 FPS product trail cannot establish
  per-frame continuity. The original vehicle entity records also did not carry
  signed velocity or chassis rotation. New evidence fills these omissions.

## Changes

The vehicle feature resolves opposite throttle into service braking until
longitudinal speed is within 0.1 m/s of standstill. This avoids Jolt's immediate
forward/reverse gear selection against several metres per second of existing
motion. W, S, Space and handbrake retain their input mappings. Steering and
handbrake remain independent of the pedal policy. The real-Jolt rig and network
predictor use the same pure pedal rule. Last applied physics input is an
observational feature field, excluded from logical save/replay state.

Solo draws use accepted replicated motion for chassis and wheels. The approximate
network predictor remains observable but no longer replaces the solo chassis.
The chase camera follows that same presented chassis. The tradeoff is the
existing snapshot interpolation delay: three authority ticks, or 50 ms.
Authority admission, replication, identities and gameplay ownership are preserved.

Forced snapshots can occur between the regular 20 Hz updates. Using just the
last two poses and rescaling their interval caused three frozen moving sub-tick
frames in the first industrial-world native trace. Vehicle entries now retain
four samples, derived from the three-tick delay and one possible snapshot per
authority tick. Presentation selects the pair surrounding the delayed absolute
tick. Definition changes discard obsolete interpolation history. This is
disposable client state and changes no wire encoding.

Incident capture now records `vehicle_motion` once per successfully submitted
controlled-car frame, plus four `vehicle_wheel_motion` records. These correlate
semantic and persistent identity, authority tick, render frame, frame duration,
raw held controls, actual applied physics controls, conditioned steering,
authoritative/replicated/predicted/presented pose, signed forward/lateral speed,
gear, RPM, snapshot endpoints/alpha, camera and prediction corrections. Wheel
records include actual physics pose, contact, suspension, tire slip, spin,
replicated state and presented pose. The additive schema-5 capability is
`vehicle_frame_motion`; older bundles lack it. Existing writer limits and
degraded-evidence reporting remain authoritative.

## Reproduce the tests

From the repository root:

```sh
zig build -Deditor=true
zig build test-vehicle-dynamics test-vehicle-feature test-physics test-session-contracts -Deditor=true

zig-out/bin/incinerator_vehicle_dynamics --motion-audit \
  "$PWD/game/vehicles/494e43494e455241-20915108d5f1c706.icvehicle" > /tmp/courier-motion.json
zig-out/bin/incinerator_vehicle_dynamics --motion-audit \
  "$PWD/game/vehicles/494e43494e455241-867ee4c3b011b0fe.icvehicle" > /tmp/meridian-motion.json
python3 tools/vehicle_motion_report.py /tmp/courier-motion.json /tmp/courier-summary.json

zig build test-vehicle-driving-macos -Deditor=true
zig-out/bin/incinerator_replay verify zig-out/vehicle-motion-native-Courier.icrp \
  "$PWD/zig-out/share/incinerator/content"
zig-out/bin/incinerator_replay verify zig-out/vehicle-motion-native-Meridian.icrp \
  "$PWD/zig-out/share/incinerator/content"
```

Use the exact build/content cohort that produced a replay. Source changes can
invalidate old recordings. A successful semantic replay verifies recorded
accepted ingress and logical digests; it does not reproduce GPU scheduling.

Each car has **96 real-Jolt experiments**: acceleration/coast/stop in both
directions; opposite-pedal transitions straight and with held steering; service
braking in both directions; handbrake/release/countersteering; left/right turns
entered at 2/8/16/24 m/s forward and 2/8/12 m/s reverse. Every case runs from
0/90/180/270-degree world headings at 60 Hz. Entry speeds are followed by open-loop
controls, not a hidden speed-hold assist. Schedules, complete definition/digest,
build identity and every tick are retained. Sideslip is unavailable below 0.5 m/s;
signed velocities remain present. That is a measurement-validity threshold.

The audit fails on unreached entry, wrong steering direction, incomplete stop or
direction transition, or disagreement between Jolt wheel poses and the actual
replicated wheel-composition function (1 mm position / 0.001 axis-vector error).
It reports skids and high lateral velocity without silently treating them as
acceptable tuning. All durations define experiments, not job timeouts.

The native test drives both actual authored cars in the streamed industrial
world. It pumps content, physics and GPU publication and requires districts in
every driving frame. It uses the product input latch and fixed-step accumulator
with 30/60/144 Hz and irregular virtual frame intervals, including zero-tick and
multi-tick frames. It checks direction/stopping, interpolated movement, camera
alignment, stationary inspection camera and cooked visual availability.
Keyboard and mouse input in this automated window are excluded before editor
and viewport routing; the script owns the controls and camera. Window close
still stops the test. Use the normal `zig build run -Deditor=true` product for
manual driving.

Native outputs:

- `zig-out/vehicle-motion-native-{Courier,Meridian}.ndjson`: frame-by-frame trace.
- `zig-out/vehicle-motion-native-{Courier,Meridian}.icrp`: accepted-ingress replay.
- `zig-out/vehicle-motion-runs/`: complete incident runs and a correlated visual
  flag during the transition into steering/handbrake tests.

Summarize an incident with `python3 tools/vehicle_motion_report.py RUN_FOLDER
OUTPUT.json`. Write summaries outside the original run. Use
`zig build incident-visual-report -- RUN_FOLDER NEW_OUTPUT_FOLDER` for indexed
contact sheets. Native virtual cadences test interpolation; they are not FPS
performance measurements. For human SDL recordings, graphical replay remains available through
`zig build run -- --replay-incident=RUN_FOLDER` and remains best effort. The
scripted native runs inject the player action latch, not SDL keyboard events:
replay those with their `.icrp` files or rerun the native test. Their incident
folders retain visuals/motion; their replay files are exported separately.

## Handling findings retained

Before the pedal fix, Courier's straight forward-to-reverse case spent 178
ticks moving faster than 1 m/s with an opposing gear; reverse-to-forward spent
215 ticks. Both become zero with the new policy. Wheel reconstruction already
matched Jolt, with observed position error below 0.04 mm and axis-vector error
below 0.000002 across the original sweep; no wheel-axis patch was justified.

Courier still has excessive ordinary-cornering oversteer. At an 8 m/s entry with
half steering, its original definition reaches roughly 84 degrees of sideslip
in three seconds; Meridian remains near 3 degrees. A measured candidate reduced
Courier's 8 m/s steering lock fraction from 0.8 to 0.55 and increased rear lateral
peak/slide friction to 1.65/1.32. Ordinary-turn sideslip fell to 2.31 degrees, but
the unchanged reference handbrake experiment never reached breakaway (peak
2.298 degrees, recovery unavailable). **The candidate was rejected.** Its full
summary is retained for the next tuning iteration.

The pinned Jolt solver combines tire and surface friction using a geometric
mean and independently limits longitudinal and lateral tire impulses. This audit
uses the adapter's existing 0.2-friction ground. Do not label it dry-asphalt
certification or mistake steering-induced oversteer for verified locked-wheel
handbrake behavior. The next handling task should address that measured tradeoff
across both ordinary cornering and deliberate breakaway. Network predictor
fidelity and low-FPS renderer profiling remain separate follow-ups.

## Verification ledger

Final command results and compact experiment/native summaries are retained in
`vehicle-motion-audit/`. Full regenerable traces remain in the local audit
directory and `zig-out` to avoid checking hundreds of megabytes into source.

Original audit source cohort: **3885578312503337429**, Debug, Zig 0.16.0, Apple Silicon.

- `zig build test -Deditor=true --summary all`: **334/334 steps**,
  **1,305/1,305 tests passed**, including architecture checks and native driving.
- Both 96-scenario motion audits passed; **30,840 recorded ticks per car**.
  Maximum wheel-position discrepancy was 0.0306 mm; maximum axis-vector
  discrepancy was 0.00000109. Both complete reports repeated byte-for-byte; SHA-256 hashes are retained in
  `vehicle-motion-audit/repeatability.json`.
- Native industrial runs: **1,375 driving frames per car**, no dropped incident
  records, all four wheel records per frame. There were **zero frozen moving
  sub-tick frames** out of 310 Courier / 323 Meridian opportunities. The retained
  tick-only shadow predictor remained frozen on every one of those opportunities.
- Final native accepted-ingress replays verified **1,891 Courier ticks** and
  **2,041 Meridian ticks**, including bootstrap and entry before driving.
- Indexed contact sheets were visually inspected: industrial streets loaded,
  both camera modes usable, visible chassis/wheel assemblies correctly oriented.
  This is visual review of recorded frames, not a claim about subjective feel.

## Native test input isolation correction

The subsequent user run
`zig-out/vehicle-motion-runs/2026-09-07T20-46-23.991Z_solo_fd2aab8f`
failed the fixed-camera assertion at frame 742 / tick 907 and shut down cleanly.
The camera started rotating at frame 712 and reached yaw 0.29336 radians before
its x position moved from -2.99149 to -3.02473 metres. The car was almost stopped
(-0.00131 m/s) at failure. Selected original records are retained in
`vehicle-motion-audit/native-input-interference.json`.

The fixture used `renderS5SmokeFrame`, which pumps live SDL events. A physical
RMB drag and movement key could therefore navigate the supposedly fixed camera
through the normal Free Camera owner. This was a test input-ownership defect;
the previous passing runs did not exercise competing physical input.

The driving test now installs a scoped SDL keyboard/mouse event filter, including
already queued events, before its first input pump. It restores the previous
filter before app teardown. Product input routing is unchanged. Regression
coverage injects RMB press/motion/release and movement, mode-switch, Escape and
editor key press/release events throughout both cars' scripted segments. The
fixed camera must retain its exact full position, yaw and pitch on every frame.
Native focus-loss and main-window close events must still reach the normal
lifecycle owner.

The failed run has no flagged anomaly or attached replay: the strict inspector
and skill summarizer reject its absent anomaly index. Its completed manifest
reports zero drops and no writer failure, and its per-frame motion stream is
available. The original folder remains unchanged. The new scripted runs export
accepted-ingress replay only upon completing the drive.

Correction verification:

- `zig build test-vehicle-driving-macos -Deditor=true --summary all`:
  **87/87 steps, 2/2 tests passed**.
- Repeated the emitted native test executable with the user's original
  `--seed=0x840999c`: **2/2 tests passed** again. Each pass drove 1,375 frames per
  car, totaling **5,500 driving frames** across the two runs, with injected
  input interference and exact camera checks.
- Both runs' exported replays verified: **1,891 Courier / 2,041 Meridian ticks**
  each. All four incident manifests completed with zero drops, writer failures
  or screenshot fence failures. The first corrected Courier bundle passed the
  strict inspector; its indexed Metal contact sheet was visually inspected.
- Corrected runs begin at `20-54-12.507Z` / `20-55-00.396Z`; repeat runs at
  `20-56-36.481Z` / `20-57-24.141Z` on 2026-09-07, under
  `zig-out/vehicle-motion-runs/`. Command output is retained in
  `vehicle-motion-audit/native-input-fix-{tests,repeat,inspection,replays}.txt`.

This correction changes the test fixture only. The earlier full-suite and
physics-sweep results above remain historical evidence for that original audit;
the physics sweep was not rerun for input isolation.
