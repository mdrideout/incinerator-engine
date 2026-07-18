# Post-S11 Runtime Corrective Audit

**Date:** 2026-07-15

**Platform:** Apple Silicon macOS

**Status:** Superseded by the accepted gameplay interaction validation and
observability program after manual real-window acceptance exposed further gaps

## Scope

This pass began with four playable-runtime regressions: diagonal movement could
fault as invalid input, a visible open area contained an invisible collision
barrier, vehicle wheels no longer visibly spun or steered, and character facing
disagreed with camera yaw. The requested scope included a first repair, a fresh
cross-system audit, a second repair, and complete headless plus rendered macOS
validation.

## Corrected Contracts

- Character input normalization now occurs before the session trust boundary;
  diagonal WASD cannot exceed the protocol unit-vector ceiling.
- Semantic facing has one engine-owned convention: zero faces `-Z`, positive
  yaw turns toward `+X`, quaternion conversion owns the sign inversion, and
  interpolation follows the shortest canonical arc.
- Vehicle exit derives horizontal facing through that contract and falls back
  to the driver's last valid on-foot yaw when a pitched chassis has no usable
  horizontal forward direction.
- Protocol revision 12 projects authoritative wheel phase, angular velocity,
  steering, suspension, and contact. Solo and graphical network clients use one
  pure wheel-pose composer; predicted chassis state cannot erase wheel state.
- Wheel phase canonicalization collapses f32 rounding at the forbidden `2pi`
  endpoint, including tiny reverse motion, and the wire plus archetype layout
  impose explicit finite bounds.
- The sandbox recipe now classifies mandatory blocker proxies independently of
  authored decorative residency. Spawn checks, initial movement, navigation
  edges, and client district presentation consume the same blocker catalog.
- Automatic initial spawn and respawn share one bounded candidate policy with
  real Jolt placement, live-character/NPC separation, and same-cycle
  reservations. Occupancy remains continuous through the respawn/vitals
  handoff, driving players are scored at the occupied chassis, and all
  advertised participant slots are checked only after the complete 64-NPC plus
  vehicle fixture has settled.
- Graphical listen and dedicated clients implement the same right-button drag
  look and focus-loss cancellation policy as solo.
- Presentation timing follows snapshots actually applied to the replicated
  world. Common 20 Hz and NPC 10 Hz lanes keep independent clocks, so an
  off-lane or rejected snapshot cannot reset NPC interpolation.
- On-foot melee is now an explicit on-foot-only contract at both client
  preflight and authority admission. A hidden retained character cannot attack
  from, or be selected as a target inside, an occupied vehicle.
- NPC replacement distance and visibility checks resolve a living driver to
  the occupied vehicle chassis rather than the dormant CharacterVirtual pose.
- The persistent headless composition now owns a bounded typed replacement
  transaction. A restored due record advances from ready to a correlated NPC
  spawn and exact vitals registration. Spawn rejection defers it; vitals
  rejection submits a compensating despawn and defers only after that exact
  outcome; only matching `registered` completes it. Unrelated FIFO heads remain
  fault evidence, in-flight work forbids quiescent save, and settled registered
  state resaves and cold-restores exactly.
- The persistent headless composition also owns restored hostile combat by
  exact encounter-attack correlation. It peeks and commits only a matching NPC
  melee damage outcome and, when lethal, its exact death-event mate. Unrelated
  FIFO heads remain fault evidence; a cold-restored windup kills, reaches
  quiescence, and resaves without losing public outcomes from another owner.
- Canonical NPC persistence now distinguishes a verified `exact_prefix` from
  an owner-aligned `deferred_rebuild`. Farther inactive content cannot emit a
  false goal completion or flip a patrol leg. Restored pursuit remains pending
  while its target content is inactive or its owner is dormant and installs
  after reload. This intentionally advances Snapshot V11 and replay schema 8;
  `world-config-v5` and protocol revision 12 remain unchanged.
- Logical gameplay publication no longer competes with immediate transport
  preparation. The conservative bound is 172 publications per participant per
  accepted cycle, with two cycles/344 records retained. An ordered cursor
  drains beneath the 16-message connection/tick ceiling; an exhausted slow
  consumer is retired without faulting the room. Client life-event and combat
  presentation queues retain one complete 16-message wire batch in FIFO order.
- Automatic listen/dedicated product bootstrap now creates six NPCs, one per
  authored route node. The 64-NPC cohort remains a synthetic scale and
  saturation ceiling. The normal embedded product separately waits for the
  player and west district, then submits one playable hostile through the
  host-managed authority. A separate narrow product-character owner correlates
  NPC-caused local death, the exact character despawn, respawn cooldown/result,
  the new character and avatar projection, and post-respawn survival instead
  of classifying expected character outcomes as bootstrap faults.
- One renderer-neutral combat-presentation owner now preserves authoritative
  health, life, incarnation, encounter state, attack deadlines, action results,
  and life events. Solo and graphical network scenes consume the same policy
  for health bars, bounded hit flashes, NPC windup/death colors, and retained
  melee/respawn/no-safe-spawn markers even while the local avatar is driving or
  absent after death.
- The dedicated cold `-Dproduct=headless` build root now imports the exact
  vitals and NPC-encounter contracts required by its shared simulation graph.
  The client graph cannot mask cold-product import drift; direct cold lifecycle
  plus extracted-source verification retain that independent boundary.

## Second-Pass Audit Results

The first repair was followed by independent world/facing and
vehicle/presentation reviews. They exposed and drove the fixes for network
district blindness, missing multiplayer mouse look, blocker-intersecting spawn
slots, vertical vehicle-exit failure, independent NPC-lane timing, f32 wheel
phase endpoint rounding, diagonal spawn preflight, navigation clearance, and
graphical-client architecture-closure drift.

The fresh independent audit did find additional P1 seams outside the original
four symptoms: a one-tick spawn-reservation handoff gap, driver position read
from a dormant character, vehicle-occupant melee, restored headless replacement
outcomes with no operational consumer, accepted S11 data discarded before the
actual solo renderer, and normal-product character death/respawn outcomes
misclassified as bootstrap faults after NPC combat. It also found that restored
hostile combat had no exact persistent-headless owner for its vitals
damage/death FIFO pair. The final packaging audit then found that the cold
headless product graph omitted the new vitals and encounter contract imports
that were present in the client graph.
Each drove the second corrections above and focused regressions. The final
independent review then followed those repairs.

The final independent implementation review closed the normal-product
character-lifecycle and cold-headless import findings and found no remaining
P0/P1 implementation defect. The focused, native Metal, S11, complete Debug,
complete ReleaseFast, direct-cold, and extracted-source automated gates below
all pass. Manual real-window control acceptance remains pending because the Mac
was locked; the retained P2 items therefore remain explicit.

The following P2 pressure points remain explicit rather than being hidden
behind speculative abstractions:

- global ground and streamed district support floors are still coplanar
  physical owners; changing this requires a coordinated bootstrap/world-layout
  migration;
- the single client vehicle archetype remains a cohort assumption rather than
  catalog-selected content, and wheel turn unwrap estimates whole turns from
  endpoint velocities;
- raw wheel deltas, per-participant authority extraction, and exact network
  render-plan instrumentation should be measured at the declared active-vehicle
  ceiling before adding quantization or projection caching;
- engaged NPCs still use the global 10 Hz NPC lane rather than the previously
  documented priority cadence;
- session authority still chooses sandbox replacement candidates, while the
  hostile role is inferred from live identity rank rather than authored and
  persistent population intent;
- reliable life feedback is broadcast room-wide and does not carry an NPC
  source cue, so hit feedback is deliberately nondirectional;
- the client combat-presentation owner retains local feedback and HUD-anchor
  state without a fresh-avatar/session identity key. Current reconnect retains
  the same avatar and current respawn clears the relevant state, so this is not
  an ordinary-flow defect; reset/key it before a fresh room/account/participant
  switch can reuse one graphical scene;
- the graphical process gates still need stronger semantic JIP/reconnect,
  selected-NPC inspection, and representative crowd-placement evidence before
  more sophisticated combat AI or density; and
- replacement clearance checks rigid bodies and living players but not another
  live `CharacterVirtual`. The accepted 64-NPC synthetic stress cohort maps
  many actors onto only six authored route nodes, so requiring capsule
  separation now would make replacement impossible. The six-NPC automatic
  product cohort avoids that default overlap; authored denser slots/crowd
  policy must precede an NPC-separation query.

These remain in the living findings register in
[`ARCHITECTURE_REVIEW.md`](../../ARCHITECTURE_REVIEW.md).

## Verification

The final evidence set covers focused contracts, the complete editor-free
graph, S11 inheritance, source architecture, installed native Metal smokes,
and an interactive rendered launch. Exact command results are retained here so
later phases can distinguish current evidence from the historical phase
records.

### Final evidence

The automated build, test, process, and Metal validation matrix is green.
Formatting and patch hygiene passed after the evidence-only reconciliation. At
this checkpoint the manual normal-product control pass remained pending;
automated scenario hosts did not replace that human acceptance. That pass was
subsequently performed, exposed further interaction-validation gaps, and is
closed by
[`gameplay-interaction-validation-and-observability.md`](gameplay-interaction-validation-and-observability.md).

| Evidence | Command | Final result |
|---|---|---|
| Formatting and patch hygiene | `zig fmt --check build.zig src tools` and `git diff --check` | **Pass — both commands exit 0; no conflict markers are present** |
| Focused corrective contracts | `zig build test-sandbox-controls test-sandbox-product-encounter test-sandbox-product-encounter-host test-npc-feature test-npc-encounter test-npc-replacement test-vitals-feature test-sandbox-host-contracts test-simulation test-simulation-snapshot test-replay test-headless test-session-contracts -Deditor=false -j1 --summary all` | **Pass — 113/113 steps and 261/261 tests** |
| Direct cold product | `zig build -Dproduct=headless test test-m3-lifecycle -j1 --summary failures` | **Pass — exit 0** |
| Installed S2 wheel regression | `zig build smoke-installed-s2-macos -Doptimize=ReleaseFast -Deditor=false` | **Pass — Metal at 240 Hz and 80 Hz; wheel spin, wheel steering, vehicle movement, steering, brake, handbrake, crate displacement, and enter/exit flags all true** |
| Installed S8 route lifecycle (historical result before IV0 solid-character correction) | `zig build smoke-installed-s8-macos -Doptimize=ReleaseFast -Deditor=false` | **Superseded — this run passed with 64 colocated synthetic controllers before character-to-character collision; the current IV evidence separates one-actor graphical lifecycle from the dedicated 64-NPC scale lane** |
| Installed S11 solo combat presentation | `zig build smoke-installed-s11-macos -Doptimize=ReleaseFast -Deditor=false` | **Pass — Metal; 240 Hz completed 3,840 frames/960 scripted ticks and 80 Hz completed 1,280 frames/960 scripted ticks; every required presentation flag true** |
| S11 aggregate | `zig build verify-s11 -Deditor=true -j1 --summary failures` | **Pass — listen and dedicated process markers present, MP4 loopback reports `npcs=6`, and both solo Metal cadence gates pass** |
| Native macOS readiness | `zig build test-macos-readiness -Doptimize=ReleaseFast -Deditor=true -j1 --summary all` | **Pass — 83/83 steps; S2, S8, S11, S3-S7, window/init, replay, and save gates clean** |
| Filtered source package | `zig build verify-source-package -Deditor=false -j1 --summary failures` | **Pass — exit 0; extracted broad 182/182 steps, 395/395 tests; extracted cold 32/32 steps, 62/62 tests** |
| Complete Debug regression | `zig build test -Deditor=false -j1 --summary all` | **Pass — 248/248 steps and 862/862 tests** |
| Complete ReleaseFast regression | `zig build test -Deditor=false -Doptimize=ReleaseFast -j1 --summary failures` | **Pass — exit 0 with no failures; exact counts were not emitted by the failure-only summary** |
| Interactive normal product | `zig build run` | **Historical checkpoint: pending because the Mac was locked. The subsequent pass was performed, exposed additional defects, and is accepted in the linked interaction-validation ledger; this superseded record is not the current acceptance claim.** |
