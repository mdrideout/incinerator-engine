# Gameplay Interaction Validation And Observability Evidence

**Status:** Accepted

**Date:** 2026-07-15

**Decision:**
[`../adr/020-gameplay-interaction-validation-and-observability.md`](../adr/020-gameplay-interaction-validation-and-observability.md)

**Design:**
[`../design/gameplay-interaction-validation-and-observability.md`](../design/gameplay-interaction-validation-and-observability.md)

## Evidence Rules

- Record exact commands, configurations, test counts, and measurements.
- Separate focused, inherited, installed graphical, and manual evidence.
- Never mark a phase complete from implementation inspection alone.
- Preserve the first failing reproduction before accepting its correction.
- List retained risks explicitly; do not hide them inside a completion claim.
- A later aggregate gate does not erase phase evidence or rationale.

## Baseline Audit

The 2026-07-15 read-only audit found:

- 781 Zig test declarations under `src/` and `tools/`;
- 12 installed visual smoke build steps;
- six hard-coded non-empty graphical scenarios (`s1_character`, `s2_vehicle`,
  `s3_streaming`, `s4_physics_debug`, `s7_interaction`, `s11_combat`);
- an eventual-state S11 Metal smoke, but no continuous presence,
  non-penetration, camera, or semantic pixel invariant;
- a renderer-free normal-product encounter test that intentionally accepts
  local avatar despawn after NPC-caused death;
- a retained world-space HUD anchor rendered as geometric markers after the
  avatar is absent;
- no explicit Jolt character-vs-character collision owner in the engine;
- aggregate encounter/authority diagnostics without a chronological
  selected-entity action trace; and
- recoverable submission failures that are stable but not consistently visible
  to developers or players.

This explains why existing automated gates could pass while the rendered
interaction remained confusing or visually incoherent.

## Phase Ledger

| Phase | Status | Focused evidence | Inherited evidence | Review |
|---|---|---|---|---|
| IV0 contracts/reproduction | Accepted 2026-07-15 | Real-Jolt crossing failed before registry and passes after it; product contact/death journey passes | `zig build test -Deditor=false --summary all` passes | Contract/source review complete; projection skew retained for IV2 |
| IV1 scenario/trace | Accepted 2026-07-15 | 3 trace, 4 runner, 2 catalog, session projection, product journey | 875/875 complete test gate | Architecture/source review complete |
| IV2 contact correction | Accepted 2026-07-15 | Real-Jolt 65-controller measurement, stand-off contract, authority and presentation separation journeys | 880/880 complete test gate; 239/239 S11 gate | Contact/source/topology review complete; spatial registry deferred until measured need |
| IV3 inspector/product feedback | Accepted 2026-07-15 | Immutable selected-entity inspector, bounded trace controls, retained action feedback, semantic HUD observations | 882/882 editor-enabled gate; two-rate installed Metal S11 smoke | UI/authority/source review complete; editor-disabled text uses macOS window title |
| IV4 Metal visibility oracle | Accepted 2026-07-15 | Shader/reflection contract; real Metal checkpoint readback and retained first failure | Two-rate installed S11 55/55; M5 passes | GPU lifecycle/scope/source review complete |
| IV5 topology/fault/soak | Accepted 2026-07-15 | Eight-seed clean/nominal/adverse/blackout matrix; 8,192- and 32,768-tick seeded fuzz soaks | Real graphical listen/dedicated, installed solo Metal, source/package/M5 and aggregate gates pass | Lifecycle cross-lane defect corrected at protocol/client boundary; code and documentation audit complete |
| Human trace corrective | Accepted 2026-07-15 | Death proxy, safe carry release/drop, typed reasons, presentation trace, dead-avatar separation, and primitive-material renderer regressions | 198/198 aggregate with 246/246 tests; two-rate installed Metal; direct rendered collect/drop/melee/death/clean-shutdown pass | Human-visible red death body and exact action feedback confirmed; held movement/vehicle controls remain covered by S1/S2 automation |

## Human Trace Corrective Addendum

The exported trace from the first real-window play-through retained 1,024 of
2,470 records and reported 1,446 overwritten records. Its discrete evidence
was still sufficient to isolate three concrete defects:

- carry collect was applied at tick 1,610, but later drop requests at ticks
  1,753, 1,844, and 2,010 were rejected with protocol disposition 6
  (`destination_unavailable`); the prior UI incorrectly rendered that reason
  as `none`;
- the local avatar reached health `60`, `40`, `20`, then `0`, followed by one
  authoritative death at tick 2,337; the accepted graphical oracle had encoded
  that transition as `local_character == null`, certifying the reported
  disappearance; and
- movement sampling occupied 1,001 records because insignificant camera-yaw
  changes were treated as causal transitions, pushing useful early context out
  of the fixed journal.

The corrective implementation keeps authority teardown intact but snapshots a
zero-health dead player proxy before destroying the physical controller. The
proxy uses the same replicated character identity/incarnation, is
noninteractive, remains in relevant snapshots until respawn, and renders
bright red. Respawn clears the proxy when the new live incarnation is created.

Dropping now resolves a placement inside the carrier's active district. It
tries the configured forward offset, deterministic quarter-turn alternatives,
then the carryable's last active world pose. This prevents a forward offset at
a half-open district edge from making an otherwise valid drop impossible.
Death while holding an object is covered through the normal product session
journey and must leave the carryable visibly released before the death result
is accepted.

Gameplay trace schema 2 records reason domains, coalesces small analog movement
changes, and adds normal-product semantic presentation transitions. The
always-visible product feedback retains the exact action-specific protocol
reason. The Metal S11 death checkpoint now requires the dead local body, its
red death color, health bar, and visibility evidence; disappearance is no
longer an accepted success condition.

`src/sandbox/product_presentation_trace.zig` is the fixed-capacity owner of
those normal-product semantic presentation transitions. It records membership,
health, life, and disappearance changes only; frame-by-frame transforms remain
outside the causal journal.

The first post-correction aggregate run exposed two stale assumptions rather
than weakening the new lifecycle contract. The fault runner treated a prior
incarnation's retained death proxy as the newly respawned interactive avatar;
it now requires the live state, replicated entity, and incarnation all to
match before submitting movement or melee. The same run starved a graphical
listen host long enough for GNS to accumulate client catch-up inputs; draining
that backlog into one authority tick exceeded the legitimate eight-input
quota. `src/session/transport_policy.zig` now owns a shared per-authority-tick
transport ingress budget used by both direct dedicated and listen adapters.
Excess samples remain queued in GNS for the next authority tick, while the
authority retains its independent rejection quota.

The aggregate then exposed three test-architecture races rather than product
semantics to weaken:

- MP3 character prediction/fault acceptance had accidentally included live
  asynchronous district/content bootstrap. Its authority core now runs in the
  deterministic host-managed empty world appropriate to MP3; streaming and NPC
  projection remain covered by MP4 and S11.
- The listen process observer could close after its local replacement while
  the remote client had not yet printed its terminal replacement evidence. It
  now waits for the remote member completion/disconnect handshake with a
  bounded 600-tick deadline.
- A clean IV5 repeat had compared exact sampled neutral inputs, yaw, deltas,
  and bytes while live asynchronous bootstrap legitimately shifts their ticks.
  The harness now settles bootstrap before network admission, fingerprints
  ingress relative to that origin, and compares causal action/submission/
  outcome semantics. The impaired-link unit boundary still proves exact
  same-message seeded transport decisions. Incinerator does not claim bitwise
  lockstep determinism.

The final rendered pass found one more distinction that the first Metal oracle
did not encode. Combat presentation supplied the correct red death color, but
the product's `pos_color` primitive pipeline ignored the `base_color` argument
to `drawMeshWithMaterial`; the oracle's independent fragment shader rendered
the supplied color and therefore produced a false positive. The primitive
shader now multiplies authored vertex detail by the material color, shader
reflection requires its 16-byte fragment uniform, and physics-debug draws push
an explicit white multiplier. NPC presentation separation also remains active
against the retained dead avatar, so the attacker cannot consume the corpse
projection. The player-death oracle now requires at least 64 depth-tested
pixels for the local corpse rather than accepting a one-pixel sliver.

Direct macOS window acceptance then observed the exact sequence
`HP 60 -> 40 -> 20 -> 0/100 DEAD`, a clearly red retained local capsule, the
orange hostile separately readable behind it, and a visible respawn countdown.
In the normal product, `F` collect and `F` drop each reported
`carry_toggle/applied/none`; `Q` reported `melee/applied/none` with `miss`; F1,
F2, and F3 toggled without failure; and Escape shut the process down cleanly.
An out-of-range `E` attempt correctly reported
`vehicle_toggle/rejected/NoVehicleInRange`. Continuous movement, camera drag,
and vehicle hold controls remain covered by the installed S1/S2 graphical
scenarios because the UI driver can send discrete keys but cannot hold an SDL
key or right mouse button with product-equivalent duration.

## IV0 Evidence

### Preserved failing reproduction

The new real-Jolt test `virtual characters preserve capsule separation while
moving toward each other` initially failed at the continuous separation
assertion. Both controllers crossed because no character-vs-character
collision owner was installed. The failure was observed with:

```bash
zig build test -- --test-filter "virtual characters preserve capsule separation"
```

The command reported 42 passing tests and this one failure in the relevant
test binary. This is the preserved pre-correction evidence; the final tree does
not retain an expected-failing test.

### Selected contact boundary

`Physics` now owns one Jolt `CharacterVsCharacterCollisionSimple`. Every
successful `CharacterVirtual` creation installs and registers with it, and
destruction removes then detaches before releasing the native object. This adds
no rigid proxy bodies and keeps the existing 65-controller owner-thread cohort.

The same filtered command passes after the correction.

### Product-equivalent temporal journey

The normal-product renderer-free encounter test now:

- boots the same embedded client/authority placement, player, west district,
  product NPC initializer, vitals, encounter, death, and respawn owners;
- holds only the patrol goal so the contact fixture cannot drift into the
  separate district-transfer scenario;
- drives the player toward the NPC through ordinary session input;
- checks alive player/NPC presentation on every applicable tick;
- checks authoritative capsule separation continuously;
- provokes hostility once at contact, then observes NPC-caused death,
  character despawn, cooldown, explicit respawn, new avatar projection, and
  post-respawn survival.

It passes with:

```bash
zig build test -- --test-filter "normal product encounter survives NPC-caused death"
```

During development the authoritative minimum horizontal separation was about
`0.79 m` for the `0.40 m + 0.35 m` authored radii. Independently interpolated
presentation samples reached about `0.657 m`. The physical actors no longer
cross, but the visible samples can appear closer because the common lane is
20 Hz and the NPC lane is 10 Hz. IV2 retains that as a presentation-contact
pressure point.

The journey also exposed that chasing a still-patrolling fixture past the west
district boundary correctly trips `NpcUnexpectedOwnerTransfer`; the contact
scenario now freezes the patrol goal instead of weakening owner-transfer
invariants.

### Inherited gate

```bash
zig build test -Deditor=false --summary all
```

Result: exit zero, including dependency/replay cohort, M5, M6, MP6, logical
manifest, headless binary/source, product/validation, install, and complete
test dependencies.

### IV0 review

- The collision registry is adapter-owned and does not leak Jolt into gameplay.
- NPC/player feature capabilities remain unchanged.
- No rigid-body, persistence, protocol, or replay schema changed.
- O(n²) character checks at the declared 65-controller ceiling require IV2
  measurement before final contact acceptance.
- Causal action tracing, readable feedback, semantic GPU visibility, and the
  topology/fault matrix remain open exactly as assigned to IV1-IV5.

## IV1 Evidence

### Scenario kernel and catalog

`src/engine/gameplay_scenario.zig` owns a generic typed runner with exact fixed
tick advancement, condition waits, per-step and whole-scenario deadlines,
continuous invariants, press/hold/release semantics, checkpoints, and a
retained first failure. Its four direct tests prove action order, condition
waiting without wall-clock sleeps, immediate continuous-invariant failure,
deterministic repeated artifacts, and missed-deadline failure.

`src/sandbox_controls.zig` defines the shared typed intent for S1, S2, S7, and
S11 under the product names `character_blocker_and_facing`,
`vehicle_drive_wheel_and_exit`, `carry_collect_drop`, and
`hostile_npc_approach_contact_death_respawn`. The old S1/S2 graphical timings
are named adapter functions; the semantic steps, deadlines, invariants, and
checkpoints no longer live in the graphical root.

Focused commands:

```bash
zig test src/engine/gameplay_scenario.zig
zig build test-sandbox-controls
```

### Bounded causal trace

`src/engine/gameplay_trace.zig` owns the allocation-free fixed transition
journal and explicit JSON export. Three direct tests prove chronological wrap,
first-cause freeze/resume, saturation counters, and ordered self-describing
export. `src/session/gameplay_trace.zig` is the single shared projection from
protocol messages to causal records; the M5 gate rejected an initial local
placement dispatch and drove this ownership correction.

The normal-product encounter now proves monotonic causal records for melee and
respawn across client submission, authority admission, and client application,
plus the applied death transition. It also requires zero trace overwrite in
the bounded acceptance journey.

Focused commands:

```bash
zig test src/engine/gameplay_trace.zig
zig build test-sandbox-product-encounter-host
bash tools/verify_m5_architecture.sh
```

### Inherited gate and review

```bash
zig build test -Deditor=false --summary all
```

Result: `248/248` build steps and `875/875` tests passed, including M5, M6,
MP6, installed product/validation, headless source/binary, real Jolt, replay,
and product encounter gates.

- The kernel has no product or session imports.
- Capture is allocation-free; only explicit export allocates.
- A trace is gameplay evidence, not a replacement fault journal.
- Trace projection is session-owned rather than reimplemented by `local_solo`.
- The graphical fixed-timing adapters remain explicitly marked as legacy;
  IV2/IV3 add condition observations rather than another timing script.

## IV2 Evidence

### Contact, stand-off, and presentation policy

The IV0 Jolt character registry remains the authority non-penetration owner.
The encounter configuration now carries an explicit positive
`combat_standoff_distance` smaller than `melee_range`. Pursuit targets the
stand-off point on the actor-to-target axis; melee windup continues to use the
larger melee range so locomotion arrival tolerance cannot strand an NPC just
outside combat. The field participates in config validation, versioned replay
encoding, and the replay cohort fingerprint.

The normal-product journey exposed a second, non-authoritative defect: the
20 Hz common lane and 10 Hz NPC lane can each be valid while their independently
interpolated poses overlap visually. `replicated_world` now owns one
deterministic presentation-only NPC separation function. Embedded solo and
network graphical clients both call that function. It moves neither authority
state nor replicated state, and the journey still checks authoritative capsule
separation independently, so it cannot conceal a simulation penetration.

Focused evidence includes:

```bash
zig build test-sandbox-product-encounter-host
zig build test-physics
zig build test-replay
bash tools/verify_m5_architecture.sh
```

The product encounter passes continuous living presence, identity, authority
separation, presentation separation, causal damage/death/respawn ordering, and
new-incarnation projection. The direct replicated-world test proves the
presentation correction brings a `0.60 m` sample to the declared `0.75 m`
combined presentation radii without mutating its input observation.

### Declared cohort measurement

The real-Jolt measurement constructs one player plus 64 NPC virtual
controllers and advances all 65 for 30 ticks: 1,950 controller updates with a
monotonic clock. Observed development runs were approximately
`85–113 microseconds` per controller update on the current Apple Silicon host;
the checked acceptance is completion inside the routine test watchdog, not a
machine-specific timing threshold.

The simple character registry is still brute-force and owner-thread-only. That
is accepted for the measured 65-controller cohort. Replacing it with a spatial
provider remains an explicit future performance decision if representative
NPC density measurements justify the extra owner and synchronization policy.

### Topology, installed Metal, and inherited gates

```bash
zig build verify-s11 --summary all
zig build test -Deditor=false --summary all
```

Results:

- S11: `177/177` build steps and `239/239` tests passed, including the
  installed Metal combat smoke, solo/listen/dedicated graphical processes,
  replay, replacement, real GNS transport, and clean GPU/resource teardown.
- Complete repository: `248/248` build steps and `880/880` tests passed,
  including M5/M6/MP6 architecture checks, source/headless/product boundaries,
  dependency/replay cohort, installation, validation, and real Jolt.

### IV2 review

- Contact safety remains physics-owned; pleasant approach remains AI-owned.
- The presentation correction is shared by local and network clients and does
  not create a second source of truth.
- Replay schema/fingerprint changes are intentional greenfield cohort changes.
- No general collision abstraction or cross-platform branch was introduced.
- Selected-entity diagnosis and readable action outcomes remain assigned to
  IV3; semantic GPU occupancy remains assigned to IV4.

## IV3 Evidence

### Gameplay Inspector boundary

The optional editor now registers nine tools. `Gameplay Inspector` receives
only:

- a fixed 65-slot immutable player/NPC observation projection;
- a type-erased immutable chronological gameplay-trace borrow; and
- a fixed eight-request trace-control mailbox.

It can select the local player or cycle exact replicated
identity/incarnation, displays the mapped persistent identity when active, and
shows authority/presentation pose, velocity/facing, controller dimensions,
health/life, encounter state/deadline, nearest separation, last ordinary
action disposition, and the last 128 matching actor/target trace transitions.
Freeze, resume, clear, and JSON export are applied by the opaque developer
owner only after the editor frame borrow ends. Direct journal mutation,
session polling, feature handles, physics handles, and authority objects do not
cross the editor boundary.

The gameplay trace gained a capacity-independent immutable borrowed view and a
fixed request mailbox. Five direct tests prove wrap/freeze/export, immutable
chronology, and visible mailbox saturation.

### Player-facing communication

The product owns one three-second, tick-keyed projection of the last discrete
local submission/rejection/application. Expected session preflight failures
already enter the causal trace; host-only policy failures such as melee while
driving now enter it explicitly before returning to play.

An always-on screen-space product panel remains visible when F1 hides the
developer windows and names:

- local HP and received damage;
- death;
- hostile attack windup;
- melee cooldown;
- respawn countdown or `Press R to respawn`; and
- actionable local rejection with its stable error name.

The same immutable feedback is formatted into the macOS window title for
editor-disabled builds. Existing world-space health bars and markers remain,
but no required state depends on interpreting their color or geometry.

### Focused and installed evidence

```bash
bash tools/verify_m5_architecture.sh
zig test src/engine/gameplay_trace.zig
zig build -Deditor=true --summary all
zig build -Deditor=false --summary all
zig build smoke-installed-s11-macos --summary all
```

Results:

- M5 retained every client/authority/editor ownership boundary.
- Both editor cohorts installed successfully (`48/48` editor-enabled and
  `45/45` editor-disabled build steps).
- The editor-enabled repository gate passed `251/251` build steps and
  `882/882` tests.
- Installed real-Metal combat passed at 240 Hz and 80 Hz with clean teardown.
  Both runs explicitly observed product HUD health, damage, death, windup,
  respawn countdown, respawn-ready instruction, and action feedback.

### IV3 review

- Player communication reads client-owned immutable presentation, never live
  authority.
- Gameplay trace control remains distinct from the runtime fault journal.
- Bounded UI feedback does not become a durable or replicated source of truth.
- No general widget automation system, font renderer, remote telemetry, or
  cross-platform UI abstraction was introduced.
- Actual entity pixel occupancy and bounded image artifacts remain assigned to
  IV4.

## IV4 Evidence

### Actual Metal oracle and retained first failure

`src/visibility_oracle.zig` is a validation-only serial SDL GPU owner. It owns
two 320x180 RGBA8 render targets, a depth target in the renderer-selected
format, one graphics pipeline, one persistent download transfer buffer, and a
per-capture fence. It reuses the product triangle vertex shader and actual
capsule mesh buffers, model matrices, view-projection matrix, clockwise cull,
less-depth comparison, and depth writes. The dedicated fragment shader writes
a stable 24-bit object ID plus the selected entity's product presentation
color to two attachments.

The first 240 Hz installed run retained the intended failure:

```text
scenario=hostile_npc_approach_contact_death_respawn
checkpoint=player_respawn
authority_tick=534
presentation_frame=2120
object_id=2
```

Its ID/color images showed only the newly respawned player. The surviving NPC
was off-camera, so the scenario—not the renderer—had declared an invalid
expectation. The accepted contract now declares only entities whose semantic
checkpoint requires them on-camera: player+NPC at contact, retained dead
player+surviving NPC after player death, player at respawn, and player+dead NPC
at NPC death. This preserves the zero-pixel failure rule without confusing
world liveness with camera visibility. The post-human correction additionally
requires at least 64 player pixels at the death checkpoint; a barely exposed
edge is not meaningful human-visible evidence.

On the first declared zero-pixel failure, the oracle writes exactly one fixed
metadata file, ID-mask PPM, and selected-entity color-preview PPM beneath
`/tmp`, records an invisible causal trace transition, freezes the gameplay
trace, and returns the gameplay failure. Secondary artifact-write errors are
reported without replacing the original failure.

### Focused and installed evidence

```bash
zig build shaders --summary all
zig build test-shaders --summary all
bash tools/verify_m5_architecture.sh
zig build install -Deditor=false --summary all
zig build smoke-installed-s11-macos -Deditor=false --summary all
```

Results:

- shader generation: `17/17` build steps;
- shader interface/reflection gate: `19/19` build steps and `2/2` tests;
- M5 ownership/dependency architecture: pass;
- editor-disabled install: `48/48` build steps;
- installed Metal S11: `58/58` build steps, at both 240 Hz and 80 Hz;
- each cadence completed 960 scripted ticks, four fenced captures, seven
  declared visible-object observations, valid bounds, and clean shutdown; and
- the normal installed product does not retain visibility-oracle artifact or
  result strings; they occur only in `incinerator_validation`.

### IV4 review

- The adapter observes client presentation after product frame submission; it
  never becomes authority or changes presentation state.
- It adds no render graph, public scene API, generalized screenshot service,
  or cross-platform abstraction.
- GPU resources are created only in the validation composition, every capture
  waits its fence, and teardown releases the owner after the renderer drains
  but before device destruction.
- ID occupancy and bounds are exact semantic evidence; broad color golden
  images remain explicitly out of scope.
- Full topology/fault/fuzz/soak execution and aggregate failure bundles remain
  assigned to IV5.

## IV5 Evidence

### Shared scenario ownership and process placement

`src/sandbox/gameplay_scenarios.zig` is the single product-owned catalog for
scenario names, semantic actions, predicates, invariants, checkpoints, seeds,
steps, and deadlines. `src/sandbox_controls.zig` re-exports it for the embedded
solo graphical adapter. The graphical GNS client and private-listen client
import the same catalog and announce the exact scenario identity used by their
installed process adapters.

The real graphical process gates passed:

```text
zig build verify-s11-listen --summary all
S11_LISTEN_PROCESS_PASS graphical=2 host_local_link=true guest_real_gns=true shared_scenario=true npc_damage=true npc_death=true replacement=true
Build Summary: 41/41 steps succeeded; 6/6 tests passed

zig build verify-s11-dedicated --summary all
S11_DEDICATED_PROCESS_PASS graphical=2 real_gns=true shared_scenario=true npc_damage=true npc_death=true replacement=true
Build Summary: 41/41 steps succeeded; 6/6 tests passed
```

The listen guest is explicitly labeled `topology=listen`; a shared executable
name is not allowed to misreport the placement being exercised.

### Deterministic fault matrix and preserved failure

`tools/interaction_validation.zig` drives the production session client,
dedicated authority, and semantic impaired link with virtual time. It validates
the hostile contact, player death/cooldown/respawn, optional reconnect, NPC
death/replacement, finite and coherent projections, terminal action results,
bounded queues, and deterministic fingerprints. The fixed first-failure file
records scenario/profile/seed/tick/state and an exact reproduction command.

The first eight-seed matrix exposed a real cross-lane lifecycle defect. Under
nominal seed `20756` and adverse seed `20758`, a pre-death unreliable snapshot
arrived after reliable death feedback and restored the cached avatar to alive
while its authoritative character was absent. This prevented respawn without
faulting either owner. The preserved reproduction was:

```text
zig build run-interaction-validation -- --profile nominal --seed 20756 --ticks 4800 --reconnect
```

Life events now carry their authority tick, the client reconciles lifecycle by
authority tick and incarnation, and older same-incarnation state cannot
resurrect a dead avatar. This is an intentional wire change, so the exact
cohort advances to protocol revision 13. A focused client regression proves
that delayed alive feedback cannot override a newer dead snapshot. The session
contract gate then passed 145/145 tests.

After the correction:

```text
zig build verify-interaction-matrix --summary all
Build Summary: 17/17 steps succeeded; 3/3 tests passed
```

The matrix contains one repeat-checked clean seed, three nominal seeds, three
adverse seeds, and one adverse-plus-blackout seed. Every run reconnects. Across
the faulted runs the harness observed latency, jitter, unreliable loss,
duplication, reorder, upstream/downstream bandwidth pressure, and the explicit
two-way blackout while retaining zero queue overflow and complete terminal
action accounting.

### Seeded fuzz and soaks

The action fuzzer uses SplitMix64 and reports both action and accepted-ingress
fingerprints. It exercises movement direction cycles, jump, melee, respawn,
reconnect, rejection, relevance, and replacement using the same scenario and
session owners. Failures are replayed by profile, decimal seed, tick count, and
flags; no general scripting VM or parallel network implementation was added.

```text
zig build soak-interactions -Doptimize=ReleaseFast --summary all
IV5_INTERACTION_PASS profile=adverse seed=20817 ticks=8192 fuzz=true reconnect=true ... actions_melee=199/199 actions_respawn=8/8 ... queue_high=12/6
Build Summary: 8/8 steps succeeded

zig build soak-interactions-long -Doptimize=ReleaseFast --summary all
IV5_INTERACTION_PASS profile=adverse seed=20818 ticks=32768 fuzz=true reconnect=true ... actions_melee=1006/1006 actions_respawn=6/6 ... queue_high=12/8
Build Summary: 8/8 steps succeeded
```

The 8,192-tick soak is routine aggregate coverage. The 32,768-tick soak is an
explicit opt-in gate so normal iteration remains bounded.

### Aggregate gate and documentation strategy

The durable documentation split is now executable policy:

- ADR-020 owns why and long-lived architectural constraints;
- the design document owns current phase contracts, scope, and completion
  criteria;
- this ledger owns exact evidence, preserved failures, and retained risks; and
- root plans summarize status and link here instead of copying implementation
  detail.

`tools/verify_interaction_validation.sh` rejects unchecked phases, pending
ledger rows, missing owners, a missing protocol-cohort record, or drift in the
shared catalog imports. The filtered source-package gate explicitly requires
the ADR, design, ledger, shared catalog, interaction runner, Metal oracle, and
visibility shader. The aggregate command is:

```text
zig build verify-interactions --summary all
Build Summary: 198/198 steps succeeded; 246/246 tests passed
```

It composes the complete S11 solo/listen/dedicated and installed Metal gate,
the deterministic fault matrix, routine ReleaseFast interaction soak, M5
architecture boundary, source-package proof, and documentation audit. The
long soak remains explicit through `zig build soak-interactions-long
-Doptimize=ReleaseFast`.

### Inherited S8 gate correction

The final macOS readiness run exposed an obsolete coupling in the inherited S8
installed smoke. That smoke placed all 64 synthetic NPCs at one authored route
origin and required every actor to traverse the same narrow route. This was a
valid lifecycle shortcut before IV0, but it became physically impossible once
real character-to-character collision made those controllers solid.

The correction separates the two claims instead of disabling collision or
inflating a timeout:

- the installed Metal S8 smoke uses one NPC and proves the complete graphical
  spawn, destination-wait, district reload, route transfer, dormancy, resume,
  despawn, draw, controller, and queue lifecycle at both cadences; and
- `tools/s8_measure.zig`, the IV2 real-Jolt cohort, and bounded
  saturation/preflight tests retain the 64-NPC/65-controller capacity, scale,
  allocation, RSS, replay, and timing evidence.

This is an intentional single-responsibility correction to validation
architecture. The automatic playable cohort still uses six distinct authored
route nodes; a future representative crowd-density proof requires authored
non-overlapping placement rather than duplicated spawn positions.

The corrected installed command passes `55/55` build steps. At 240 Hz it
completed 188 frames / 51 fixed ticks; at 80 Hz it completed 63 frames / 51
ticks. Each run observed every exact one-count lifecycle transition, two
resident scenes, empty queues, zero final controllers/draws/entities, the
single ground body, and clean Metal teardown.

The complete inherited macOS readiness graph subsequently passed `86/86`
steps in ReleaseFast with the editor enabled. This includes S2 wheel behavior,
S3/S6 streaming, S7 ownership, corrected S8 lifecycle, S11 combat and semantic
visibility, window lifecycle, injected initialization/runtime faults, replay,
save, physics diagnostics, profiling, and authoring.

The final editor-free Debug repository graph passed `253/253` build steps and
`885/885` tests after its S8 evidence fixture was narrowed to the same
one-actor lifecycle contract. That fixture still rejects duplicate requests,
unknown identities, wrong-stage events, swapped despawns, and incomplete
per-identity evidence.

## Final Acceptance

All six phase reviews are accepted. The source/dependency audit retains one
shared scenario owner, validation-only GPU ownership, client/authority
separation, exact protocol cohorting, fixed-capacity traces/queues, and no
compatibility fallback or secondary-platform abstraction. The aggregate macOS
gate is the continuing acceptance contract for future gameplay changes.

The post-IV human-trace correction is also accepted. The last focused session
gate passed `46/46` steps and `148/148` tests, the shader contract passed
`19/19` steps and `2/2` tests, the installed S11 Metal gate passed `58/58`
steps at 240 Hz and 80 Hz with seven semantic observations at each cadence,
and the direct rendered acceptance above confirmed the actual swapchain color
and separation rather than relying only on the offscreen oracle. Its nested
source-package execution passed `182/182` steps and `406/406` tests, followed
by the independent cold product's `32/32` steps and `62/62` tests.

## 2026-07-19 open-world amendment

The disposition-6 trace above remains historical evidence of the defect. The
residency-gated drop policy and `destination_unavailable` protocol value no
longer exist. ADR-022 makes a carryable's district coordinate spatial metadata,
not a body/presentation lease; drop at an unauthored coordinate is now a tested
valid action. The intentional greenfield wire change advances to protocol revision 14
with no compatibility decoder. Snapshot and replay cohorts advance
to 12 for the corresponding ownership and vehicle-tuning semantics.
