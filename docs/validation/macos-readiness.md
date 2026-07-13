# Apple Silicon macOS Runtime Readiness Record

**Date:** 2026-07-12  
**Status:** Local runtime closeout and hosted macOS CI evidence complete

## Scope

This record covers the current S2 macOS runtime gate. Apple Silicon macOS
with Metal is the sole current platform target. Linux/SteamOS and Windows are
future/deferred and impose no build, shader, headless, runtime, packaging, CI,
or compatibility gates.

All native commands below use Zig 0.16.0, `ReleaseFast`, and `-Deditor=false`.
The dedicated build steps install `incinerator_engine` and launch that installed
Mach-O with `/tmp` as its working directory. They do not run Zig's cache
artifact and do not depend on repository-relative game content.

## Repeatable Gate

```sh
zig build test-macos-readiness \
  -Doptimize=ReleaseFast -Deditor=false
```

The aggregate runs the following checks serially so concurrent graphical
processes cannot turn WindowServer or Metal contention into a false result.

### Installed S2 visual runtime

```sh
zig build smoke-installed-s2-macos \
  -Doptimize=ReleaseFast -Deditor=false
```

Observed result: Metal selected; 480 ready and zero unavailable frames at 80
Hz; 720 fixed ticks; chassis/wheels rendered; vehicle movement, steering,
dynamic-crate displacement, character suppression/restoration, and successful
exit observed; normal teardown emitted `S2_VISUAL_SMOKE_SHUTDOWN status=clean`.
The corresponding 1,440-frame 240 Hz run passed the same evidence with the same
720 fixed ticks. The historical installed S1 smoke also remains independently
available and green after the bootstrap-profile split.

This proves that the installed binary is self-contained for the current
procedural sandbox. Shaders are embedded, SDL and Jolt are statically linked,
and the runtime has no working-directory asset dependency. It is not yet a
signed/notarized `.app` packaging claim.

### Native minimize and restore

```sh
zig build smoke-window-lifecycle-macos \
  -Doptimize=ReleaseFast -Deditor=false
```

Observed result: eight ready Metal frames before minimize, the main-window
`MINIMIZED` event, a 750.772 ms minimized dwell over 46 bounded wait
iterations, the main-window `RESTORED` event, eight ready Metal frames after
restore, and clean teardown. No swapchain-unavailable frame was required;
SDL permits but does not guarantee that result for a minimized window.

The production loop now treats the stable minimized state as explicit host
suspension: it waits on SDL without consuming the next event, does not advance
simulation or request a GPU frame, and resynchronizes the host clock so the
pause cannot create a catch-up burst. The renderer's independent
swapchain-unavailable path remains bounded and non-fatal for backpressure that
occurs without a minimize event.

### Initialization failure and restart

```sh
zig build smoke-init-failures-macos \
  -Doptimize=ReleaseFast -Deditor=false
```

Observed result: six injected failures unwound real SDL/Metal ownership after
window claim, pipeline creation, placeholder-resource creation, complete
renderer creation, visual-resource creation, and simulation creation. A fresh
application then initialized in the same process and completed the full
160-frame/240-tick S1 visual smoke with clean teardown.

The isolated Jolt adapter additionally injects failure after runtime lease,
job/temp allocator creation, the three-filter bundle, and PhysicsSystem/filter
ownership transfer. Each checkpoint restores the process lease count and is
followed by a healthy same-process body lifecycle. These are focused ownership
seams, not a fake SDL/Jolt backend framework. Per-upload GPU failure injection
belongs to the S3 content/upload slice where cancellation and batching policy
will exist.

## Automated Baseline

- Debug and ReleaseFast, editor excluded: 179/179 tests pass in each mode.
- Debug with the editor enabled: 179/179 tests pass.
- Native installed ReleaseFast runtime: all three gates above pass.
- `zig fmt --check` and `git diff --check`: pass.

Hosted run `29213905954` passed every macOS job step through S2 headless
composition. Graphical smokes stay local
because hosted WindowServer/Metal availability is not a reliable contract;
hosted CI runs deterministic macOS build, test, shader, headless, source-package,
and non-GPU relocation checks.
