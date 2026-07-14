# M5 Client/Authority Cohesion Acceptance

**Status:** Accepted

**Date:** 2026-07-14

**Platform scope:** Apple Silicon macOS only. Linux/SteamOS and Windows remain
deferred and provide no M5 build, test, compatibility, or abstraction gate.

**Design contract:**
[`M5 Client/Authority Cohesion`](../design/m5-client-authority-cohesion.md)

This record closes M5 from measured implementation, architecture, native macOS,
package, and independent-review evidence. Subjective human free-play remains a
recommended exploratory follow-up and is not represented as completed here.

## Aggregate Gate

```sh
zig build verify-m5 -j1 --summary all
```

The aggregate must compose the complete M4 multiplayer regression, M5 ownership
and architecture checks, embedded-session parity/order tests, cold-authority and
product/validation boundaries, filtered source-package execution, and installed
Apple Silicon macOS gameplay evidence. A build-step name alone is not acceptance;
the evidence below must be recorded.

### Clock evidence

Focused contracts exercise the pure accumulator, graphical invocation, and the
real embedded placement at both 80 Hz and 240 Hz presentation cadence. They
observe exactly 120 authority ticks and 40 applied snapshots over two seconds in
each case. The installed S2 scenarios additionally retain the first correlated
drive, steering, and brake sequences so acknowledgement is measured against a
fixed request rather than a moving latest-input target.

## Architecture and Ownership

- [x] The graphical application owns presentation/input lifecycle but has no
  concrete `Simulation`, Flecs, Jolt, private feature-state, canonical-save-byte,
  or save-slot commit access.
- [x] The embedded composition root is the sole graphical source edge that can
  see both client and authority graphs.
- [x] Embedded and dedicated placements use the same authority-session behavior;
  no separate local gameplay dispatcher bypasses admission.
- [x] The broad `local_solo` forwarding facade and direct `sandbox.*` re-export
  surface are removed rather than deprecated.
- [x] Durable snapshot values/codec/preflight, replication projection, replay
  values, and diagnostic composition have cohesive private boundaries without
  widening the live authority API or introducing a service locator.
- [x] District visual streaming, developer tools, and durable persistence have
  explicit lifecycles and narrow immutable/request capabilities.
- [x] The complete client source closure rejects authority, Flecs/Jolt,
  persistence, replay, and private-feature imports.
- [x] The dedicated authority remains free of SDL, GPU, renderer, editor, visual
  content, lobby SDK, and client-prediction dependencies.

## Clock, Ordering, and Semantic Parity

- [x] The embedded and dedicated authority clocks both run at 60 Hz.
- [x] At 80 Hz and 240 Hz render cadence, embedded replication remains 20 Hz and
  authority tick count depends on elapsed authority time rather than frame rate.
- [x] Character input uses identical identity, sequence, target-tick, ownership,
  quota, and outcome semantics over local and decoded/network delivery.
- [x] Vehicle enter/drive/exit uses the same authority path locally and remotely;
  neutral expiry, nonzero sequence wrap, and bounded reconnect-result ambiguity
  remain intact.
- [x] Carry collect/drop uses the same authority path locally and remotely;
  contention, disconnect cleanup, nonzero sequence wrap, and stale/late result
  policy remain intact.
- [x] The placement trace proves, as separate owner operations, client ingress
  delivery → authority execution → authority egress transfer → client
  application → acknowledgement ingress.
- [x] The authority trace proves pre-simulation → simulation → outcome drain
  → replication extraction, including the nested runtime command →
  pre-physics → physics → post-physics order.
- [x] Failure tests prove completion-aware prefixes, immutable first authority
  fault, and refusal to advance another tick after that fault.
- [x] Future-tick tests prove bounded per-target retention, no early
  application, and acknowledgement only after an input affects a completed
  tick.

## Trust and Recovery Boundaries

- [x] Operational authority constructors use private CSPRNG-backed credential
  secrets; deterministic credential injection is inaccessible through the
  public options API.
- [x] Session and reconnect credentials are unpredictable from public identity,
  domain-separated, identity-bound, timing-safe to compare, rotated after use,
  and retain only one presented predecessor until post-welcome confirmation.
- [x] Room admission rejects zero secrets, validates the signed account and
  external identity before reconnect lookup, and cannot partially allocate a
  participant when nonce history has no free or expired slot.
- [x] Encoded and typed local server messages share semantic validation for
  snapshot sequence, global replicated-identity uniqueness, delta conflicts,
  physical projection values, and action/result compatibility before client
  mutation.
- [x] After the first authority-cycle fault, every operational mutation entry
  point fails without state drift while diagnostics, outbound drain, transport
  closure, and shutdown remain available.

M5 does not claim that ingress admission, derivative preparation, durable
decision, or egress publication form one atomic eight-stage transaction. That
separate hardening is specified in
[`Post-M5 Transactional Authority Cycle`](../design/post-m5-transactional-authority-cycle.md).

## Persistence, Replay, and Diagnostics

- [x] The editor emits a typed save request and consumes immutable feedback; it
  cannot generate canonical payload bytes or call `SaveSlots.commit`.
- [x] Healthy quiescent state commits atomically, while pending work, authority
  fault, encode failure, and storage failure preserve the previous committed
  slot with typed feedback.
- [x] Durable snapshot, replication state, prediction history, and accepted-
  ingress replay remain distinct schemas and lifetimes.
- [x] Replay still identifies first authority divergence in the exact cohort.
- [x] The immutable first fault, bounded journal, profiler, and physics-debug
  evidence remain observable without exposing mutable authority state.

## Playable Regression

- [x] Installed automated embedded scenarios exercise walking, jumping, vehicle
  entry/driving/exit, carry collect/drop, district transitions, and relevant NPC
  presentation through the production composition.
- [x] Installed automated scenarios exercise editor relocation, undo, redo,
  save, fresh-process restore, diagnostics, replay, physics visualization,
  pause/step/scale, and streamed-content lifecycle.
- [x] One dedicated authority plus two graphical clients retains character,
  vehicle, carry, district, NPC, prediction, reconnect, fault-injection, and room
  admission behavior from M4.
- [x] New owner initialization failpoints unwind once, workers join, GPU work
  drains, and shutdown releases authority after client/presentation consumers.

## Evidence Matrix

Final commands and exact results:

| Evidence | Command | Result |
|---|---|---|
| Focused M5 contracts | `zig build test-m5-cohesion --summary all` | 62/62 steps and 281/281 tests passed |
| M5 architecture boundary | `zig build verify-m5-architecture --summary all` | 2/2 steps passed |
| Complete multiplayer regression | `zig build verify-m4 -j1 --summary all` | 132/132 steps and 92/92 tests passed |
| Debug, editor excluded | `zig build test -Deditor=false -j1 --summary all` | 223/223 steps and 764/764 tests passed |
| Debug, editor enabled | `zig build test -Deditor=true -j1 --summary all` | 226/226 steps and 764/764 tests passed |
| ReleaseFast, editor excluded | `zig build test -Doptimize=ReleaseFast -Deditor=false -j1 --summary all` | 223/223 steps and 764/764 tests passed |
| ReleaseFast, editor enabled | `zig build test -Doptimize=ReleaseFast -Deditor=true -j1 --summary all` | 226/226 steps and 764/764 tests passed |
| Cold authority | `zig build -Dproduct=headless test -j1 --summary all` | 32/32 steps and 52/52 tests passed |
| Aggregate cold-authority wrapper | `zig build verify-m5-cold -j1 --summary all` | 2/2 wrapper steps; nested 32/32 steps and 52/52 tests passed |
| Filtered source package | `zig build verify-source-package -Deditor=false -j1 --summary all` | 145/145 steps and 299/299 tests; nested cold 32/32 steps and 52/52 tests passed |
| Native macOS readiness | `zig build test-macos-readiness -Doptimize=ReleaseFast -Deditor=true -j1 --summary all` | 81/81 steps passed |
| Aggregate M5 | `zig build verify-m5 -j1 --summary all` | 190/190 steps and 316/316 tests passed |
| Formatting and patch hygiene | `zig fmt --check build.zig src tools` and `git diff --check` | Passed |

## Independent Review

- [x] Architecture, correctness, authority security, protocol semantics,
  boundary closure, build/package, and documentation reviews completed.
- [x] Review findings were corrected and rechecked with no remaining unrecorded
  actionable P0, P1, or P2 issue in M5 scope.
- [x] The non-atomic fresh-admission/publication boundary remains explicitly
  recorded for the post-M5 transactional authority cycle rather than being
  misrepresented as complete.

## Exploratory Human Follow-up (Non-blocking)

These subjective checks are recommended but were not performed as part of the
automated M5 acceptance and are not completion claims:

- Run embedded solo and assess controls, camera, editor, save feedback, and
  district-streaming feel after the intended authority-clock change.
- Run one dedicated authority and two clients, exercise `P` prediction A/B and
  `F8` manufactured reconnect, and visually inspect convergence.

## Closure

M5 is accepted from the required automated evidence and independent reviews
above. The deeper atomic ingress-to-publication concern is intentionally
carried forward by the post-M5 transactional authority-cycle plan; it is not an
unrecorded M5 completion claim.
