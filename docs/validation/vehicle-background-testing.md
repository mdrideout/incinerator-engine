# Background vehicle testing

Routine physics and motion work runs without SDL and without wall-clock pacing.
Use ReleaseSafe for the whole build graph; the physics timestep and all motion
schedules remain unchanged. Compilation is separate from simulation time.

```sh
# All three admitted game profiles, four headings, 120 scenarios per profile.
zig build vehicle-motion-report -Doptimize=ReleaseSafe

# Pure physics, controls, authoring contracts, replication and replay coverage.
zig build test -Deditor=true

# Product world + Metal + mixed render cadences, hidden SDL host, no swapchain.
zig build test-vehicle-offscreen -Deditor=true -Doptimize=ReleaseSafe

# Also observe Cocoa activation and on-screen windows during that acceptance.
zig build verify-vehicle-background-macos -Deditor=true -Doptimize=ReleaseSafe
```

The batch writes a new timestamped folder under `zig-out/vehicle-motion/`.
Each vehicle report includes build identity, exact definition/digest, all
37,080 measured ticks, all 120 scenario results and per-segment front/rear
contact, locking, slip, load, force, steering and curvature statistics.
`run.json` records duration, worker statuses, report/log paths and the executable.
`parts/` retains each heading's report and stderr, including failed gates.
Existing output folders are rejected so stale evidence cannot look successful.

Override the output location and process concurrency explicitly:

```sh
zig build vehicle-motion-report -Doptimize=ReleaseSafe -- --jobs 2 --output /tmp/my-new-driving-results
```

The default worker count is the detected logical CPU count. `--jobs 1` runs
serially; use a smaller count when reserving CPU for other work. Each process
owns its Jolt lifetime, and merged results follow definition/heading order,
independent of completion order. Failures remain failures in compact mode.

A full per-tick trace is opt-in and keeps the existing command:

```sh
zig build vehicle-dynamics-report -Doptimize=ReleaseSafe -- --motion-audit game/vehicles/494e43494e455241-20915108d5f1c706.icvehicle > /tmp/courier-full.json
```

Both `--motion-audit` and `--motion-summary` accept `--heading 0`, `90`, `180`
or `270` to reproduce one batch worker. Pass an admitted `.icvehicle` file,
not its authoring-source JSON. `--definition` retains its existing measurement
contract, including the live authoring measurement consumer.

Motion report schema 2 adds `trace_retained`, per-result `sample_count` and
`axle_phases`. Compact reports have empty `samples`; zero retained samples
never means zero simulated ticks. Means with zero moving/contact counts have
no measurement support; consult those counts. The offline Python reducer reads
both historical full reports and current compact reports.

Offscreen acceptance retains the product world, Jolt, authority/presentation,
wheel composition, fixed/chase cameras, cooked materials/meshes and Metal draw
path. It renders 1,375 measured frames per vehicle at injected 30/60/144/irregular
cadences. It checks the host stays hidden, has no keyboard/mouse focus, and
never acquires a swapchain. GPU readbacks are saved as
`zig-out/vehicle-motion-offscreen-{Courier,Meridian,Courier-AWD}.ppm` and must
contain nonuniform pixels. Matching NDJSON and `.icrp` files accompany them.
These cadence experiments do not measure interactive frame-rate performance.

Window/input acceptance is explicitly foreground and may take focus:

```sh
zig build test-vehicle-driving-macos -Deditor=true
zig build test-editor-pointer-macos -Deditor=true
zig build test-mouse-capture-macos -Deditor=true
zig build test-developer-endpoint -Deditor=true
```

Run those commands sequentially. `zig build check-foreground-macos -Deditor=true`
compiles the vehicle and developer app fixtures without opening windows.
Default `test` and `test-m5-cohesion` retain main's pure tests but cannot discover
the three window-opening app fixtures, which now have a separate test root.
Offscreen acceptance does not claim real window focus, pointer lock, swapchain
presentation or the SDL pedal press/release journey. Those stay in the explicit
foreground fixtures; product input routing is unchanged.

Replay verification remains headless. Verify with the same source/content and
optimization cohort as the recording; a build identity mismatch is an error.
For example, after the ReleaseSafe offscreen run:

```sh
zig build run-replay -Doptimize=ReleaseSafe -- verify "$PWD/zig-out/vehicle-motion-offscreen-Courier.icrp" "$PWD/zig-out/share/incinerator/content"
```

## Verified 2026-09-07

Source cohort `12349060619409440027`, Zig 0.16.0, Apple Silicon, pinned Jolt
`23dadd0e603f1b321142d4c74df07fce85064989`. No authored vehicle definition,
physics contract, input mapping or simulation timestep changed.

| Full matrix (360 scenarios / 111,240 measured ticks) | Runtime excluding compilation |
| --- | ---: |
| Debug, serial | 54.65 s |
| ReleaseSafe, serial | 4.54 s |
| ReleaseSafe, 4 workers | 1.64 s |
| ReleaseSafe, detected CPU worker count | 0.89 s |

These are individual local runs, not general hardware guarantees. All optimized
serial/four-worker/default-worker report files were byte-identical. For Courier
at heading 0, full output was 66,793,996 bytes versus 92,442 bytes compact
(about 723× smaller); measured maximum RSS was 31.3 MB versus 19.5 MB.
The full and compact runs matched every retained field exactly. An independent
Python reduction of the raw wheel samples matched online axle statistics within
2e-6 relative tolerance. Pretty-printed complete compact reports are about
514 KB per vehicle.

- Default editor suite: 338/338 build steps, 1,311/1,311 tests; includes compiling
  both foreground app fixtures. Main's background suite retains 240 tests,
  down from 243 only because the three native app journeys moved out.
- Default editor-disabled suite: 330/330 steps, 1,205 passed and two existing
  skips (1,207 total).
- Offscreen acceptance with desktop observer: 89/89 steps, both tests passed.
  All three vehicles rendered 1,375 measured frames; zero frozen moving
  sub-tick presentations. Hidden/no-focus/no-swapchain assertions passed, and
  each Metal readback contained visible industrial content. Cocoa observation
  recorded no test activation and no visible test window.
- Matching semantic replays verified Courier through tick 1,891, Meridian
  through 2,041, and Courier AWD through 1,947.
- Invalid admitted-asset input returned failure from all four heading workers;
  the batch retained their logs/statuses and returned exit 1.
- Foreground SDL key/focus journeys were compiled but deliberately not launched
  during this background-work request. Their previous acceptance remains
  historical evidence; offscreen results do not replace their focus contract.

Retained [benchmark data](vehicle-background-testing/benchmark.json),
[acceptance log](vehicle-background-testing/acceptance.txt), complete compact
reports and per-frame reductions are in `vehicle-background-testing/`.
The original human incident was preserved unchanged.
