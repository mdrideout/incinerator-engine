# S8 Navigation Population Baseline

> **Historical phase baseline.** Measurements and limits below are preserved as
> recorded for this slice; they are not measurements of the current tree. See
> the [current macOS readiness record](../validation/macos-readiness.md) and
> [cleanup plan](../../CLEANUP_PLAN.md).

**Recorded:** 2026-07-13
**Status:** Complete SDL-free S8 scale characterization
**Platform:** Native Apple Silicon macOS
**Mode:** Zig 0.16.0 `ReleaseFast`, SDL/editor excluded

## Workload

Each trial owns one real Flecs/Jolt simulation with two active procedural
districts, one CharacterVirtual player, one persistent carryable, and either
zero NPCs (baseline) or the exact 64-NPC population cohort (scale). Every NPC
uses the same west-terminal to east-terminal patrol. The player completes one
unmeasured carry warmup and then 32 collect/cross/drop cycles of exactly 512
fixed ticks each, for exactly 16,384 measured ticks per process.

The scale setup also submits a 65th spawn and requires the typed
`capacity_reached` outcome without changing entities, controllers, or the 64
retained identities. Every NPC output and event is drained and validated;
event drops are forbidden. The workload saves twice canonically, wraps and
parses the durable envelope, destroys the first world, cold-restores the same
snapshot, requires a byte-identical resave, and then drains all entities,
controllers, draws, bodies, districts, and queues to the exact ground-only
baseline.

Every observation samples the Physics-global CharacterVirtual registry
directly, requires its 128-handle capacity, and rejects any mismatch with the
independent sum of player-character and NPC feature ownership. Peak and final
controller counts below are therefore native registry counts rather than an
inference from feature records.

A separate fresh process captures 4,096 ticks of the two-district, 64-NPC,
S7 carry composition and replays it from a cold world. This keeps replay
instrumentation out of the timing and paired-memory trials. Before any world
authority is created, every child admits the installed S6 catalog, loads and
identity-checks both installed district bundles, compares their complete
cooked navigation fragments with the logical route, and validates the joined
two-district graph. The admitted content-cohort fingerprint for this recording
is `3f7ae7e4f979dabea6c60ed3e3374f166a0910f0385d1513296170301f592c2b`.

## Reproduction

```sh
zig build check-s8-measure -Deditor=false
zig build test-s8-measure -Deditor=false
zig build test-s8-measure -Deditor=false -Doptimize=ReleaseFast
zig build measure-s8 -Deditor=false -Doptimize=ReleaseFast
```

`measure-s8` always runs one replay-proof process followed by three fresh
baseline/scale process pairs. There are no workload-size options that can
silently weaken the recorded gate. The canonical machine-readable result is
[s8-baseline.json](s8-baseline.json).

## Recorded Result

| Metric | Result | Ceiling |
|---|---:|---:|
| Scale NPCs / immutable NPC draws | 64 / 64 | 64 / 64 |
| Peak entities | 68 | 68 |
| Native CharacterVirtual controllers (feature ownership matched) | 65 | 65 used / 128 global |
| Native rigid bodies, held / dropped | 7 / 8 | 7 / 8 |
| NPC command / outcome / event capacity | 128 / 128 / 256 | exact |
| Observed NPC queue high water | 64 / 64 / 64 | 128 / 128 / 256 |
| NPC event drops | 0 | 0 |
| Patrol transfer / goal events per scale trial | 4,416 / 4,352 | nonzero |
| Two-district navigation decoded / wire bytes | 216 / 216 | 640 each |
| Snapshot payload | 31,289 bytes | 131,072 bytes |
| Durable save envelope | 31,481 bytes | 131,264 bytes |
| Incremental tracked Zig allocation peak | 124,296 bytes | 2,097,152 bytes |
| Worst paired fresh-process RSS delta | 2,457,600 bytes | 33,554,432 bytes |
| Worst scale nearest-rank p99 | 0.491 ms | 4.166 ms |
| Final entities / bodies / controllers / draws | 0 / 1 / 0 / 0 | exact |
| Final NPC queue occupancy / tracked live bytes | 0 / 0 | exact |

The three scale p99 values were 0.482, 0.488, and 0.491 ms. Scale allocator
peak was 356,459 bytes versus 232,163 bytes for every matched baseline.
Per-process raw maximum RSS and every matched delta remain in the JSON. The
largest scale-minus-baseline maximum-RSS delta was 2,457,600 bytes. This coarse
process result is kept separate from exact allocator and native-resource
counts.

The replay proof matched all 4,096 tick digests. Its envelope was 958,046
bytes, with one bootstrap command, 151 recorded commands, two district
completion ingress records, and 4,096 digest records, below the 2 MiB ceiling.

## Native Presentation Companion

The installed Metal gate ran from `/tmp` against the installed catalog at both
declared cadences. At 240 Hz it completed in 134 frames / 67 fixed ticks, with
67 zero-tick frames and no multi-tick frames. At 80 Hz it completed in 48
frames / 72 fixed ticks, with no zero-tick frames and 24 multi-tick frames.
Both runs planned, spawned, drew, transferred, suspended/resumed, and despawned
all 64 NPCs; observed two simultaneously resident scenes; and finished with
zero entities, one ground body, zero controllers/draws, empty queues, and a
clean shutdown.

The native runs retained the S6 GPU payload peaks: 344 staged CPU bytes, 116
staged-upload bytes, 116 in-flight-upload bytes, and 232 resident GPU bytes.
Thus the new immutable NPC draws did not introduce an unmeasured district GPU
payload or a general crowd overlay.

## Interpretation

At this representative cohort the fixed 120 Hz simulation budget has ample
headroom: worst p99 used about 11.8% of one 4.166 ms half-tick ceiling and
about 5.9% of a full 8.333 ms fixed tick. NPC authority adds no rigid bodies;
its native scale is visible in the 64 additional CharacterVirtual controllers.
The 64-way synchronized patrol intentionally creates bursty output, yet the
largest observed NPC event batch was 64 and no bounded queue dropped data.

Timing and RSS are primary-machine characterization, not portable promises.
Exact capacities, typed rejection, event/drop behavior, persistence identity,
replay match, native counts, and final cleanup are deterministic pass/fail
gates.
