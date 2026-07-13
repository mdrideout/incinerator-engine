# S0 Crate Lifecycle Acceptance Record

> **Historical phase record.** This document preserves the evidence and claims
> recorded when this slice closed. Counts, cohorts, platform results, and
> limitations below describe that dated tree, not current support. See the
> [current macOS readiness record](macos-readiness.md) and
> [cleanup plan](../../CLEANUP_PLAN.md).

**Date:** 2026-07-10  
**Status:** Complete; independently reviewed

## Outcome

S0 now has one owned crate simulation composition used by both visual and
headless hosts. A typed command spawns a crate, Jolt simulates it at 120 Hz,
immutable extraction interpolates it, V1 JSON saves/restores logical state, and
a typed command destroys it with coordinated body/entity cleanup.

The prototype `GameWorld`, borrowed Runtime/Physics seam, duplicate tick/render
paths, raw Flecs editor selection, direct Jolt gizmo mutation, ImGuizmo build
edge, and cylinder demo are deleted. The editor retains Stats, Camera, and
Render tools; authoring is deferred to S5 typed commands.

## Automated Evidence

| Gate | Result |
|---|---|
| Exact Zig 0.16.0 Debug aggregate | 103/103 tests passed |
| Exact Zig 0.16.0 ReleaseFast aggregate, editor excluded | 103/103 tests passed |
| Headless source and final-binary dependency checks | Passed |
| Linux x86_64 GNU Debug/editor and ReleaseFast/no-editor cross-links | Passed |
| Windows x86_64 GNU Vulkan Debug/editor and ReleaseFast/no-editor cross-links | Passed |
| Linux and Windows headless cross-builds with shader tools deliberately missing | Passed |
| ReleaseFast measurement schema/completion | Passed locally; CI schema smoke added |

Coverage includes:

- real-Jolt spawn/tick/save/destroy/fresh-restore/tick/destroy;
- 128 repeated lifecycles, stale persistent/runtime/body handles, and foreign
  world/runtime rejection;
- allocation-failure sweep through multi-crate fresh restore;
- injected body-create, physics-step, body-read, impulse, and body-destroy
  failures with fault/ownership/teardown assertions;
- malformed, oversized, over-count, invalid-version, duplicate/foreign ID,
  cursor, non-finite, extent, quaternion, and velocity-limit persistence cases;
- sorted multi-record, byte-stable save/restore and exact post-restore cursor;
- deterministic phase/registration order and next-tick command deferral;
- repeated multi-sample timeline comparison with `0.00001` target-local
  tolerance;
- interpolation endpoints, midpoint, clamping, shortest-path quaternion math,
  and non-mutation;
- 240 Hz and 80 Hz presentation cadence plus the 250 ms/30-tick clamp.

## Native Metal Evidence

Both self-terminating checks used the production SDL event pump, fixed-step
policy, Jolt simulation, Metal renderer, presentation extraction, and normal
deinitialization path on an Apple M2 Max.

```sh
zig build run -Deditor=false -- \
  --visual-smoke --frames=480 --virtual-render-hz=240
```

Result: 480/480 ready Metal frames, no unavailable frames, 479 frames with the
one expected persistent crate (the first 240 Hz frame precedes its first tick),
changed position and rotation, 240 simulation ticks, alpha range `0.0..0.5`, normal SDL quit, and
`S0_VISUAL_SMOKE_SHUTDOWN status=clean`.

```sh
zig build run -Deditor=false -- \
  --visual-smoke --frames=160 --virtual-render-hz=80
```

Result: 160/160 ready Metal frames containing the expected persistent crate, no
unavailable frames, changed position and rotation, 240 simulation ticks, both
one- and two-tick frames, alpha range `0.0..0.5`, normal SDL quit, and the clean
shutdown sentinel.

The executable now fails this smoke unless the spawn outcome arrives, exactly
one matching crate is extracted after spawn, its position and rotation change,
body/entity counts remain coherent, and tick/alpha totals match the pure
cadence model. These are controlled virtual cadence checks with real submitted
GPU frames; they do not use pixel readback or claim the physical display
refreshed at 240 Hz.

## Performance Evidence

The versioned `measure-s0` program records fresh-world init, command enqueue,
bulk command ticks, outcome drain, steady tick percentiles, presentation
percentiles, active/total body counts, and teardown. The committed
[baseline](../performance/s0-baseline.md) and raw JSON cover 0, 1, 128, and the
exact 1,024 crate cap. The one-crate tick p99 was 0.112 ms; the
1,024-active-crate median-trial p99 was 0.889 ms (10.67% of the 8.333 ms
budget) in the documented sparse freefall layout. These numbers characterize
this machine and are not CI thresholds.

## Accepted Constraints

- The current zflecs wrapper permits one live owned world per process. A second
  candidate fails before entering Flecs and leaves the current simulation
  usable. Replacement requires old-world teardown first; revisit before
  multi-world/server architecture, not S1.
- Command/outcome storage is allocator-backed and unbounded. The single-player
  host is the only producer contract today; measured backpressure is required
  before network-originated commands.
- Jolt cross-platform deterministic mode remains disabled. Repeatability is
  target-local scheduling evidence, not peer-lockstep or bitwise portability.
- Linux/SteamOS and Windows are fully deferred by the macOS-only platform
  policy. Their recorded S0 cross-build results are historical evidence, not
  current gates or compatibility promises.
- The headless source graph and linked artifact are isolated, but a cold root
  build still resolves visual package dependencies before selecting a step.
  Split dependency resolution before a server-only distribution workflow.

## Final Review

Three independent read-only reviews were completed against the final working
tree:

- **Architecture/scope:** pass with no blocking findings. It confirmed one
  owned composition, clean dependency direction, no reachable legacy/editor
  mutation path, no S1/speculative framework work, and accurate placement of
  the one-world/backpressure constraints. One stale ADR-005 paragraph was
  corrected and the re-audit passed.
- **Correctness:** the first pass found two P1 and four P2 edge cases: f32 Jolt
  clamp rounding, partial-drain FIFO retention, smoke assertions, allocator
  coverage, impulse behavior, and active-body measurement enforcement. All
  were corrected; the targeted Debug/ReleaseFast re-audit and both native
  Metal smokes passed with no remaining actionable P0/P1/P2 issue.
- **Build/platform/evidence:** pass with no blocking findings. CI schema checks,
  checked measurement workload arithmetic, raw JSON/summary consistency,
  README commands, YAML/Bash syntax, source packaging, and local/cross build
  gates were verified. Native non-Metal client work is trigger-based under
  ADR-007 rather than hidden in S0.

S0 is therefore closed. This does not close the macOS-first M1/M2 evidence or
authorize S1; the next slice begins only through a separate plan decision.
