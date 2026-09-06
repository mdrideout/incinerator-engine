# E2E Review Corrections

**Date:** 2026-09-06

**Status:** Implementation and aggregate/native verification complete

## Scope and ownership

This follow-through implements the seven concrete findings from the E2E review
of goals, architecture, progress, strategy, and implementation. It preserves the
thin kernel, feature owners, typed session boundary, canonical CLI, Apple Silicon
focus, and indefinite neural pause. EA1-A's human visual/usability checkpoint is
still pending; EA1-B through EA5 are subsequent accepted roadmap work.

| Finding | Correction | Regression evidence |
|---|---|---|
| Optimized benchmark API drift | S11 uses the current NPC observation/config; M3 uses semantic destination IDs and the current singular-ground body counts | ReleaseFast editor-off aggregate; S11 and M3 workload execution |
| Peer traffic can overflow ingress and abort a room | Both GNS hosts leave messages queued when a mailbox class cannot admit more. Existing control capacity reserves room for lifecycle closes; listen host input is drained first. Duplicate/unknown terminal callbacks cannot fill the close reserve. Peer send failures close that transport and commit publication leases so the room can continue | Real GNS malformed/control bursts beyond admission capacity, healthy participant snapshots, listen host input, closed-transport reliable-send failure, and reserved-capacity cycle tests |
| Fixed network cohort labels admit differing implementations/content | Protocol 18 hashes actual source/build inputs and the exact admitted logical content manifest | Path/order-independent source hash with source edit/addition cases, content hash change, and authority build/content mismatch rejection |
| CLI completion erases a human draft | Shared authored-change evidence retains every producer, while Inspector completion feedback retains only its UI owner's results; later external results cannot replace an unobserved UI completion | Real App/authority endpoint commit preserves Inspector draft and original revision; stale UI Apply rejects without overwriting authority; own successful Apply refreshes the draft |
| Prepared CLI mutation silently adopts a replacement run | Agent contract 3 exposes bootstrap `expected_run` and requires it for every non-read-only CLI effect; caller token reaches the existing protocol precondition | All effect families and token grammar; real socket restart/second-editor replacement rejects before either owner receives a command |
| Floating UI press leaks into scene input | Editor adapter synchronously hit-tests current event position against presented ImGui geometry, preserving dockspace holes and popup ownership; UI presses remain owned through outside drag/release and focus cancellation | Real SDL queue plus Metal-presented floating Inspector, same-batch motion/press in both viewport modes, outside release, focus loss, and subsequent valid scene press |
| CI compiles but does not execute editor tests | CI runs `zig build test install -Deditor=true` | Editor routing and draft tests execute in CI. Native SDL/Metal acceptance remains an explicit `test-editor-pointer-macos` gate, also included in editor-enabled `verify-s15` |

## Compatibility changes

Rebuild network clients and authorities together: protocol 18 deliberately
rejects protocol 17. The network fingerprint includes sorted `.zig`, `.zon`,
native C/C++/Objective-C source/header and shader files under `src`, `shaders`, `third_party`, and
`tools/build`, plus the root build files and GNS build script. Dependency pins
and rates remain part of identity. Documentation, checkout path, Git metadata,
and optimization mode do not change it. The content fingerprint includes all
bytes of `config/headless-content.json`, whose catalog/bundle digests are checked
against freshly cooked content by the build gates. These identities do not
provide authentication and do not claim independent engine/game packages.

CLI mutations without `--expected-run` now fail with `ExpectedRunRequired`.
Use the exact token from bootstrap for the whole workflow, including reads and
polls. A replaced run fails with `DeveloperRunMismatch`; bootstrap and inspect
again before preparing a new edit. Endpoint wire protocol 2 is unchanged.

## M3 fixture correction

Restoring the optimized entry point also exposed the old fixture placing every
one of its 64 physical NPC controllers at `(-5,0,5)` with the same patrol goal.
A native sample repeatedly located the resulting cost in Jolt
CharacterVirtual-vs-CharacterVirtual penetration resolution. The obsolete run
was stopped after diagnosis; it did not produce a passing benchmark result. That fixture no
longer represented the capacity/lifecycle claim it was intended to measure.

Scenario v4 keeps 64 live controllers at distinct grid positions, with one
patrol goal and 63 hold goals. It retains two districts, the
character/vehicle/carryable, producer saturation, shutdown, and canonical restore.
Existing tick, memory, and payload limits are unchanged. This measures native
controller capacity plus one pathing actor; it is **not** a 64-agent crowd or
64-agent moving-population claim. S12 movement and S13's separately stated
12/16/24/64 cohorts remain the movement/population evidence. The dated M3 v3
baseline is preserved as history.

## Validation

Commands and terminal results are recorded here after completion. Raw local
logs are under `/tmp/incinerator-e2e-fixes/` during this implementation session.

| Command | Result |
|---|---|
| `zig build test verify-s15 smoke-installed-s5-authoring-macos test-developer-endpoint -Deditor=true --prefix /tmp/incinerator-e2e-fixes/final-install --summary all` | Exit 0; 450/450 steps; 1,365/1,365 tests passed, including native SDL/Metal pointer, gameplay, authoring, incident, source-package, and installed-product gates |
| `zig build test -Deditor=false -Doptimize=ReleaseFast --summary all` | 315/315 steps; 1,117 passed, 2 intended skips |
| `zig build test-mp6-hosts --summary all` | 48/48 steps; 7/7 tests passed, including real guest bursts |
| `zig build test-m3-soak test-dependency-cohort test-developer-endpoint -Deditor=true --summary all` | 109/109 steps; 50/50 tests passed, including the real App/authority draft-conflict journey |
| `zig build test-editor-pointer-macos test-m3-soak test-dependency-cohort -Deditor=true --summary all` | 51/51 steps; 78/78 tests passed |
| `zig build -Dproduct=headless test --summary all` | 32/32 steps; 56/56 tests passed |
| `zig build measure-s11 -Doptimize=ReleaseFast` | Passed; worst scale p99 32,750 ns; paired RSS delta 65,536 bytes |
| `zig build -Dproduct=headless -Doptimize=ReleaseFast measure-m3 --summary none` | Passed; 32,768 ticks; p99 469,667 ns; peak allocator 1,093,414 bytes; final live bytes 0; all unchanged limits passed. [Full report](../performance/m3-readiness-2026-09-06.json) |
| `zig build -Deditor=true --summary all` | 81/81 steps; normal `zig-out` install updated |
| `./zig-out/bin/incinerator_engine --verify-install` | Canonical district content, Metal shaders/driver, and editor-enabled install verified |
| `./zig-out/bin/incinerator-dev agent catalog` | Installed CLI reports agent contract 3 and the `--expected-run` workflow requirement |
| `zig fmt --check build.zig build.zig.zon src tools third_party/joltc-zig`; `git diff --check`; `bash tools/verify_interaction_validation.sh` | Passed; validation audit reports protocol 18 |

## Strategy and remaining checkpoint

Current architecture summaries now name snapshot 15 and protocol 18, ADR-003
defers to ADR-030 for event/Escape ownership, and the S15 baseline acknowledges
its 2026-08-18 human acceptance without relabeling old measurements as current.
The [player-loop proposal](../design/sandbox-player-loop.md) connects the existing
authoring sequence to ordinary play and distinguishes available mechanics from
unselected objectives/rewards. Product-owner selection and EA1-A visual/usability
acceptance remain human decisions; this correction does not mark them complete.
