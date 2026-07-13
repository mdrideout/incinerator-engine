# S4-B Same-Cohort Flight Recorder and Replay Validation Record

> **Historical phase record.** This document preserves the evidence and claims
> recorded when this slice closed. Counts, cohorts, platform results, and
> limitations below describe that dated tree, not current support. See the
> [current macOS readiness record](macos-readiness.md) and
> [cleanup plan](../../CLEANUP_PLAN.md).

**Date:** 2026-07-13

**Status:** Complete. Implementation, every Debug/ReleaseFast, editor-enabled,
installed native macOS, aggregate readiness, filtered source-package, and
independent closeout gate pass with no remaining actionable P0/P1/P2 finding.

**Platform:** Apple Silicon macOS is the sole current supported cohort. The
replay product itself is SDL/editor/GPU-free, but this record makes no
cross-platform replay or deterministic-Jolt claim.

**Scope:** S4-B only. S4-A structured diagnostics remains complete; S4-C owns
physics visualization and focused profiling.

## Implemented Contract

### Cold admission and evidence ownership

`Simulation` admits one flight recording only at the typed cold boundary:
before the first command or tick, with the initial identity cursor, no live
entities or unread outputs, an absent district, an idle worker, the configured
static bootstrap body count, and no retained runtime fault. Unsupported
capture points return a typed rejection; they are not approximated with
Snapshot V4 or opaque Jolt state.

Once admitted, recorder failure remains evidence loss rather than authority
failure. Fixed capacities are allocated at admission. Saturation, unread prior
outputs, digest failure, loader observation loss, authority failure, pending
work at finish, and unsupported command-submission phases mark the envelope
incomplete without changing whether a live command or tick succeeds.

Every accepted crate, character, vehicle, and district command is recorded at
the `Simulation.submit*` boundary with the fixed tick at which it can be
consumed. A command submitted during an unsupported phase still follows the
normal live authority path but visibly invalidates the capture. The logical
district-loader adapter retains only the completion actually consumed by the
district feature and records it at that exact tick. Replay starts no content
worker and injects the retained completion through the same request/cancel and
feature-consumption boundary.

### Canonical logical state

The replay contract uses an engine-owned, little-endian SHA-256 writer with
explicit integer widths, finite-only floats, normalized signed zero, and
canonical quaternion hemispheres. Runtime identity and each vertical slice
write their own sorted logical state without exposing Flecs or Jolt types:

- runtime completed tick and sorted persistent identities;
- crate transforms, motion, authority, and queue/output occupancy;
- complete character controller, locomotion, grounding, driver state, and
  queue/output/event occupancy;
- complete vehicle/chassis/wheel/contact, controls, RPM/gear, driver/restored
  state, and queue/output/event occupancy; and
- exact district absent/loading/cancelling/active payload, build/static-body
  count, pending FIFO, and queue/output/event occupancy.

The envelope stores the runtime aggregate and category subdigests per tick.
Replay compares in stable category order and reports the first divergent tick
and category, separating a crate, character, vehicle, or district divergence
from a runtime identity/tick mismatch.

### Cohort and hostile-input boundary

The bounded 8 MiB little-endian envelope carries separate simulation,
world-configuration, and cooked-content cohorts, bootstrap state, semantic
commands, consumed district ingress, and per-tick digests. The exact simulation
cohort includes Zig/target/optimization, dependency and configuration pins,
the Apple CPU model/features fingerprint, and explicit Jolt job-system values:
one worker, 2,048 jobs, and eight barriers. Content identity retains bundle
name, format/schema, source digest, and validated integrity digest.

Parsing validates the complete envelope before acquiring a world: header and
payload integrity, magic/version/schema, sizes, reserved fields, flags/tags,
finite canonical floats, counts, ordering, trailing bytes, completion payloads,
cohort compatibility, and world capacities. Declared crate, character,
vehicle, district, and identity counts are capped before world or digest-scratch
allocation. Replay therefore cannot partially apply corrupt, truncated,
oversized, unordered, hostile, or incompatible input.

### Standalone replay product

The installed `incinerator_replay` tool contains no SDL, ImGui, editor, GPU, or
presentation import. `record-smoke` loads and validates installed cooked
content, exercises crate impulse, character action, occupied vehicle drive and
exit, district cancellation, reload, asynchronous completion, and activation,
drains every feature output each tick, and writes only a complete,
self-validated capture. `verify` replays a capture; `verify-smoke` additionally
changes one ready district build to a different valid checksummed build and
requires divergence at the exact consumption tick in the district category,
then restores and matches the original capture again.

## Focused Evidence

| Gate | Recorded result | Principal evidence |
|---|---:|---|
| `test-replay` | **15/15 tests pass** | canonical envelope round-trip, incompatible/hostile/corrupt/truncated/oversized/unordered input rejection, caps, ordering, saturation, and cohort fingerprint |
| `test-district-replay-loader` | **6/6 tests pass** | live consumed-completion observation, request/cancel parity, scheduled replay injection, invalid schedule rejection, and no replay worker |
| `test-simulation` | **25/25 tests pass** | full capture/replay match, command divergence, cold preflight, nonfatal saturation/output policy, post-fault inspection, and presentation-observation invariance |
| `check-replay` | **7/7 steps pass** | standalone build plus final Mach-O visual-dependency rejection |
| generic CPU replay compile/test | **15/15 tests pass** | CPU fingerprint code does not assume the native feature set at compile time |
| installed ReleaseFast replay smoke from `/tmp` | **39/39 steps pass** | installed cooked content, full asynchronous scenario, match, exact altered-district-ingress divergence, restore, and match |
| full Debug, editor disabled | **100/100 steps; 369/369 tests** | complete project graph |
| full ReleaseFast, editor disabled | **100/100 steps; 369/369 tests** | optimized complete project graph |
| full Debug, editor enabled | **103/103 steps; 369/369 tests** | optional ImGui composition remains compatible |
| filtered extracted source package | **35/35 steps; 47/47 tests** | membership, cold headless execution, replay tests, and linkage with shader tools unavailable |
| aggregate installed ReleaseFast macOS readiness | **46/46 steps** | S2/S3 lifecycle, minimize/restore, injected restart, S4-A fault inspection, and S4-B replay run serially |

The latest installed run recorded a 56,752-byte capture over 309 fixed ticks,
then matched all 309 ticks. The altered but structurally valid district ingress
diverged at tick 309 in `district`, and the restored capture matched again.
The live worker may finish one tick earlier or later between separate recording
runs; the consumed completion tick is precisely the nondeterministic ingress
the recorder owns and replay reproduces.

Presentation-only observations in a synchronous crate scenario produce
byte-identical captures. Pausing can legitimately let a live asynchronous
worker completion become consumable at a different fixed tick; pause metadata
is still excluded, while the changed consumed-ingress tick is retained rather
than hidden.

## Acceptance Status

| S4-B requirement | Current status |
|---|---|
| Cold capture replays runtime, crate, character, vehicle, and district logical digests every tick | **Verified** |
| Altered command reports the exact first tick/category | **Verified** |
| Altered valid district completion reports the exact consumption tick/category | **Verified installed** |
| Corrupt, truncated, oversized, unordered, hostile, and incompatible input fails before world construction | **Verified** |
| Recorder saturation and output-policy violations do not change live authority | **Verified** |
| Host-only pause/presentation metadata is excluded; presentation-only observation cannot mutate fixed-tick state | **Verified** |
| Runtime authority failure retains a serializable incomplete capture and original fault | **Verified** |
| Replay executable and extracted source package exclude SDL/editor/GPU dependencies | **Verified** |
| Debug, ReleaseFast, editor-enabled, native aggregate, and source-package gates | **Verified** |
| Final independent review | **Verified: no remaining actionable P0/P1/P2 finding** |

## Reproducing the Evidence

```sh
zig build test-replay test-district-replay-loader test-simulation \
  check-replay -Deditor=false --summary all
zig build smoke-installed-s4-replay-macos \
  -Doptimize=ReleaseFast -Deditor=false --summary all
tools/verify_source_package.sh
zig build test-macos-readiness \
  -Doptimize=ReleaseFast -Deditor=false --summary all
```

For manual use after `zig build install -Doptimize=ReleaseFast -Deditor=false`,
pass the installed content directory, not the repository source fixture:

```sh
zig-out/bin/incinerator_replay record-smoke /tmp/incinerator.icrp \
  "$PWD/zig-out/share/incinerator/content"
zig-out/bin/incinerator_replay verify /tmp/incinerator.icrp \
  "$PWD/zig-out/share/incinerator/content"
```

## Explicit Nonclaims

S4-B is not an arbitrary mid-run physics checkpoint, durable save replacement,
rollback or lockstep substrate, bit-identical cross-build Jolt guarantee,
cross-platform replay contract, remote crash service, or presentation/GPU
recording. A capture is comparable only within the exact supported toolchain,
target, optimization, CPU, dependency/configuration, world, and cooked-content
cohort. Snapshot V4 remains the current durable logical save contract until S5
replaces it deliberately. Multiplayer remains deferred, and Linux/SteamOS and
Windows impose no current compatibility requirement.
