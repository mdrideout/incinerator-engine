# Apple Silicon macOS Runtime Readiness Record

**Evidence dates:** Historical baseline through 2026-07-14; post-S11 corrective,
interaction-validation, and rendered closeout on 2026-07-15

**Last reviewed:** 2026-07-15

**Status:** Post-S11 native automated and direct rendered readiness accepted;
current detail is owned by the linked interaction-validation ledger

## Scope

This record preserves the detailed S8 visual/runtime and M3 cold-headless
observations from the post-cleanup tree and records the complete M5 native
refresh. MP0-MP5/M4 are accepted separately in
[`m4-multiplayer-foundation.md`](m4-multiplayer-foundation.md); the current M5
ownership and clock result is accepted in
[`m5-client-authority-cohesion.md`](m5-client-authority-cohesion.md). Detailed
MP6 listen/dedicated graphical and real-GNS evidence is recorded separately in
[`mp6-playable-multiplayer-room-flow.md`](mp6-playable-multiplayer-room-flow.md).
S10's two-client graphical damage/death/respawn evidence is recorded in
[`s10-damage-death-respawn.md`](s10-damage-death-respawn.md).
S11's encounter evidence is recorded in
[`s11-npc-encounter-combat-response.md`](s11-npc-encounter-combat-response.md),
and its current runtime repair matrix is in the
[`post-S11 corrective audit`](post-s11-runtime-corrective-audit.md).
Scenario counts explicitly labeled historical below remain baseline evidence,
not current clock claims. Apple Silicon macOS with Metal is the sole current
platform target. Linux/SteamOS and Windows are future/deferred and impose no
build, shader, headless, runtime, packaging, CI, or compatibility gates.

All native commands below use Zig 0.16.0 and `ReleaseFast`. Historical S2-S4
gates remain valid with `-Deditor=false`; the aggregate uses `-Deditor=true` so
S5 also proves the optional editor path. Dedicated steps install their
executables and launch those Mach-O products with `/tmp` as the working
directory. They do not run Zig's cache artifact or depend on repository-relative
game content. Content-consuming S3-S11 commands remove
`INCINERATOR_CONTENT_ROOT`, forcing the
executable to derive installed cooked content from its own prefix.

Graphical scenario and fault commands now execute the separately installed
`zig-out/libexec/incinerator/incinerator_validation` host. The normal
`zig-out/bin/incinerator_engine` client remains the interactive product and is
not used as an acceptance harness. The aggregate `test` gate scans both emitted
Mach-O files: scenario and injected-fault markers must exist in the validation
host and must be absent from the normal client. Replay, save, and cold-authority
gates continue to execute their own installed non-graphical products.

## Repeatable Gate

```sh
zig build test-macos-readiness \
  -Doptimize=ReleaseFast -Deditor=true -j1 --summary all
```

The aggregate runs the following checks serially so concurrent graphical
processes cannot turn WindowServer or Metal contention into a false result.
The M5 refresh passed 81/81 build/runtime steps, and the earlier post-cleanup
invocation passed 80/80. Both are historical evidence for their dated trees.
The current post-IV invocation passes 86/86 steps.

### Historical pre-M5 installed S2 visual runtime

```sh
zig build smoke-installed-s2-macos \
  -Doptimize=ReleaseFast -Deditor=false
```

Historical 2026-07-13 result: Metal selected; 480 ready and zero unavailable
frames at 80 Hz; 720 fixed ticks; chassis/wheels rendered; vehicle movement,
steering, dynamic-crate displacement, character suppression/restoration, and
successful exit observed; normal teardown emitted
`S2_VISUAL_SMOKE_SHUTDOWN status=clean`.
The corresponding 1,440-frame 240 Hz run passed the same evidence with the same
720 fixed ticks. The historical installed S1 smoke also remains independently
available and green after the bootstrap-profile split.

Post-S11 correction: the installed S2 scenario now checks actual composed wheel
poses instead of inferring them from chassis motion. Both the 240 Hz and 80 Hz
Metal runs pass with wheel spin, wheel steering, vehicle movement, steering,
brake, handbrake, crate displacement, and enter/exit flags all true.

This proves that the installed validation host is self-contained for the
current procedural sandbox. Shaders are embedded, SDL and Jolt are statically
linked, and the runtime has no working-directory asset dependency. It is not
yet a signed/notarized `.app` packaging claim.

### Installed S3 cooked streaming runtime

```sh
zig build smoke-installed-s3-macos \
  -Doptimize=ReleaseFast -Deditor=false
```

Observed result: both serialized runs selected Metal and resolved the installed
868-byte cooked fixture from the executable prefix while running in `/tmp`.
The 240 Hz run completed in 36 frames and 18 fixed ticks with 18 zero-tick
frames; the 80 Hz run completed in 14 frames and 21 fixed ticks with seven
multi-tick frames. Each cancelled one admitted load, completed three
load-to-resident/unload-to-drained cycles, rejected the saved stale scene
handles, and emitted `S3_STREAMING_SMOKE_SHUTDOWN status=clean`.

Both cadences stayed at one live scene and one active upload batch, with exact
peaks of 344 staged CPU bytes and 116 bytes each of staged upload, in-flight
upload, and resident GPU ownership. Before shutdown, the content worker,
logical district, extracted draws, presentation coordinator, scene registry,
upload batches, and all tracked byte counters returned to zero. This is the
bounded one-scene S3 contract, not a signed/notarized application, general asset
system, pixel-readback proof, or secondary-platform claim.

Both runs also inspect the shared developer contract at real residency and
after final drain. They report `diagnostic_resident_snapshot=true` and
`diagnostic_drained_snapshot=true`, rather than inferring those states only
from private owner assertions.

### Installed S6 adjacent multi-district runtime

```sh
zig build smoke-installed-s6-macos \
  -Doptimize=ReleaseFast -Deditor=false
```

Observed result: both installed runs resolved the exact west/east catalog from
the executable prefix while running in `/tmp`. At 240 Hz the host completed in
84 frames / 42 fixed ticks with 42 zero-tick frames and no multi-tick frames;
at 80 Hz it completed in 30 frames / 45 ticks with 15 multi-tick frames and no
zero-tick frames. Each run validated three forward and three reverse adjacent
overlaps.

Every overlap contained exactly two logical districts, six district static
bodies, two canonical draws, and two authored resident Metal scenes. The
production developer snapshot reported both fixed slots, distinct lifecycle
correlations, exact content/logical/scene generations, worker idle state, and
matching GPU aggregates. Exact peaks were two live/resident scenes, one active
batch, 344 staged CPU bytes, 116 in-flight upload bytes, and 232 resident GPU
bytes. Each single-district stage drained only the departing handle while its
neighbor stayed resident; final snapshot and direct assertions returned the
worker, logical slots, bodies, draws, scenes, batches, and current GPU bytes to
baseline before clean shutdown.

Normal application startup now applies the same fail-fast composition check as
`--verify-install`: any catalog other than exactly west `(0,0)` and east
`(1,0)` is rejected before world activation. This remains a fixed two-slot S6
contract, not a general spatial streaming service.

### Installed S7 interaction ownership runtime

```sh
zig build smoke-installed-s7-macos \
  -Doptimize=ReleaseFast -Deditor=false
```

Observed result: both installed Metal runs resolved the west/east catalog from
their executable prefix and completed spawn, collect, source unload while held,
east crossing, transactional drop, destination unload/dormancy, reload/resume,
despawn, and complete logical/GPU drain. The 240 Hz run completed in 364 frames
/ 182 fixed ticks with 182 zero-tick frames and no multi-tick frames. The 80 Hz
run completed in 124 frames / 186 ticks with no zero-tick frames and 62
multi-tick frames.

Both runs rendered the carryable while district-owned and while held, omitted
it while dormant, preserved one logical record throughout ownership transfer,
and finished with zero entities, one sandbox ground body, zero carryable/
character/district draws, an idle worker, empty registry, and clean shutdown.
The SDL-free companion workload separately completed 128 ownership cycles,
including source-load cancellation while held and 512 canonical active/dormant
snapshots, before the same exact baseline cleanup. See
[the S7 performance record](../performance/s7-baseline.md).

This proves one bounded carry interaction and its cross-district authority
contract. It does not claim a general inventory, item database, ownership
graph, network replication, multiplayer behavior, or secondary-platform path.

### Installed S8 navigation/population runtime

```sh
zig build smoke-installed-s8-macos \
  -Doptimize=ReleaseFast -Deditor=false
```

Observed result after IV0 solid-character correction: both installed Metal
runs admitted the exact two-district route cohort and moved one stable NPC
identity through spawn, destination wait/resume, ownership transfer, dormancy,
native-controller restore, and despawn. The 240 Hz run completed in 188 frames
/ 51 fixed ticks; the 80 Hz run completed in 63 frames / 51 ticks.

Both runs peaked at one NPC draw and one native CharacterVirtual controller,
retained exact lifecycle evidence for wait/resume/transfer/dormancy, and
returned entities, native controllers, draws, queues, district/GPU ownership,
and bodies to the declared baseline. This graphical gate now has one
responsibility: authored route and residency lifecycle. The separate S8
fresh-process measurement, IV2 real-Jolt cohort, and saturation/preflight
tests retain the complete 64-NPC/65-controller scale and capacity claim.

### Installed S11 combat-presentation runtime

```sh
zig build smoke-installed-s11-macos \
  -Doptimize=ReleaseFast -Deditor=false
```

The installed validation host runs 3,840 frames at 240 Hz and 1,280 frames at
80 Hz from `/tmp` with repository content-root fallback removed. The contract
requires authoritative NPC spawn, melee, player death/respawn, NPC death, both
health bars, bounded hit flashes and expiry, windup, cooldown, respawn
countdown/ready, retained dead-avatar anchor, respawned-character and NPC-death
presentation, and clean Metal teardown. The current final-tree run passes at
240 Hz with 3,840 frames/960 scripted ticks and at 80 Hz with 1,280 frames/960
scripted ticks; every required presentation flag is true.

### Installed S4-A diagnostics and retained-fault runtime

```sh
zig build smoke-installed-s4-diagnostics-macos \
  -Doptimize=ReleaseFast -Deditor=false
```

Observed result: the installed S3 composition resolved cooked content from its
prefix, preserved byte-identical authoritative state through 600 paused frames
(20 virtual seconds), and executed exactly one requested fixed tick. It then
loaded one district to logical/Metal residency and raised the immutable
`InjectedDeveloperDiagnosticFault` on the next attempted tick while committed
state remained on the preceding tick. Only the validation composition
registers the dormant fixed-error commands-phase probe. The normal client,
headless, replay, save, and M3 products reject arming it as unavailable; M3's
healthy typed queue admission made the former district-capacity abuse fixture
obsolete.

The real validation-host catch/retain loop recorded content pumps `1/1`, streamed
GPU pumps `0/0`, unchanged completed-tick/stream/GPU state, one resident Metal
scene, one ready retained-fault inspection frame, and a consumed SDL quit. It
returned the original runtime error to the smoke harness, parsed the shared
text/JSON evidence, rejected terminal simulation progress without replacing
the fault through the shared authority's `AuthorityFaulted` closure, and
emitted `S4_DIAGNOSTICS_SMOKE_SHUTDOWN status=clean`. The same gate passes with
`-Deditor=true`, exercising the ImGui/Metal consumer.

### Installed S4-B same-cohort replay

```sh
zig build smoke-installed-s4-replay-macos \
  -Doptimize=ReleaseFast -Deditor=false
```

Observed result: the installed SDL/editor/GPU-free `incinerator_replay` tool
resolved and validated the cooked fixture from the installed content root,
recorded the current S8-era crate/character/vehicle/district/interaction/NPC
scenario to a 170,859-byte envelope over 689 fixed ticks, and matched all 689
logical tick digests. Controlled mutations reported exact first divergences at
tick 311 in district, tick 554 in interaction, and tick 314 in NPC. Restoring
each ingress matched again. The original S4-B acceptance record retains its
historical 56,752-byte/309-tick cohort rather than rewriting past evidence.

The recorder runs the real asynchronous worker during capture but starts no
worker during replay. A separate recording may therefore finish one tick
earlier or later; retaining and injecting that exact feature-consumption tick
is the contract being proven. The final replay Mach-O has a build-time linkage
gate against SDL, ImGui, editor, renderer, and GPU markers.

### Installed S4-C physics debug and focused profiling

```sh
zig build smoke-installed-s4-physics-debug-macos \
  -Doptimize=ReleaseFast -Deditor=false
```

Observed result: the installed validation host streamed the cooked district
alongside one crate, character, and vehicle, then ran 600 ready frames / 900
fixed ticks at 80 Hz. All five debug categories produced evidence, with peaks
of 524 lines and 84 opaque triangles and zero CPU primitive drops. The Metal adapter
completed 600 bounded copy submissions, 600 draws, and 600 accepted empty-command
post-submit fences with zero backpressure.

The fixed ring retained exactly three slots: six GPU and six transfer buffers,
16,515,072 reserved bytes, and a peak of two owned fences against the hard
maximum of three. Live execution used query-only fence polling; teardown alone
retired a partial frame and drained the device before releasing external GPU
owners. The profile rings retained 2,048 spans / 240 frames and visibly
reported 7,853 overwritten spans. This proves the installed render-command
path and ownership/accounting contract, not pixel-readback or physical-display
correctness.

### Installed S5 authoring, durable save, and cold restart

```sh
zig build smoke-installed-s5-authoring-macos \
  -Doptimize=ReleaseFast -Deditor=true
zig build smoke-installed-s5-save-macos \
  -Doptimize=ReleaseFast -Deditor=false
```

Observed result: the installed editor-enabled Metal validation host selected
its crate by persistent ID, committed a typed relocation, allowed one natural
physics tick without changing the authoring revision, then performed exact
undo and redo. The native path rendered four visible and one editor-hidden
frame, found no interpolation smear or hidden-editor authority mutation, and
committed the real slot with `save_sequence=1` at tick five.

After that process exited, the installed SDL/editor/GPU-free save tool opened
the same `sandbox.isav`, validated its exact build/world/content cohort and
integrity, constructed one fresh Flecs/Jolt world, restored the edited pose and
zero velocity, and produced byte-identical canonical payload/envelope bytes for
the then-current Snapshot V7 cohort: `payload=2036`, `envelope=2228`,
`canonical=true`, `editor_free=true`.

The separate headless gate independently writes and cold-restores a save in two
installed processes. The macOS storage sequence is candidate `F_FULLFSYNC`,
close, same-directory atomic rename, then directory `F_FULLFSYNC`; unsupported
full sync fails closed before rename. This is a power-loss-durability contract
for the supported macOS filesystem path, not autosave, cloud save, migration,
multiple-writer, or hot in-process world replacement support.

### Cold M3 operational authority

```sh
zig build -Dproduct=headless -Doptimize=ReleaseFast test --summary all
zig build -Dproduct=headless verify-cold-headless-product --summary all
```

At M3 closeout, the cold product passed 32/32 steps and 52/52 tests in both the
then-final Debug and `ReleaseFast` gates, including generated logical-manifest
identity verification,
exact config/content/save preflight, bounded two-producer routing,
real signal/lag/storage/corruption lifecycle cases, canonical restart, exact
three-file installation, source and final-binary marker checks, and only
`/usr/lib/libSystem.B.dylib` dynamic linkage. The isolated extracted tree runs
with visual package/cache/shader inputs absent.

The M3-final 32,768-tick routine ReleaseFast process recorded a 451,500 ns
fixed-tick p99, 733,394 peak allocated bytes, and 19,152,896 peak RSS bytes. The
M3-final 131,072-tick long process recorded a 443,292 ns fixed-tick p99,
1,519,514 peak allocated bytes, and 18,169,856 peak RSS bytes. Both passed the
automatic timing, allocation, absolute RSS, snapshot, and envelope ceilings with
canonical restore. See the [M3 acceptance record](m3-acceptance.md) and
[M3 performance baseline](../performance/m3-baseline.md).

### Native minimize and restore

```sh
zig build smoke-window-lifecycle-macos \
  -Doptimize=ReleaseFast -Deditor=false
```

Observed result: eight ready Metal frames before minimize, the main-window
`MINIMIZED` event, a 764.563 ms minimized dwell over 46 bounded wait
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

The same gate deliberately omits the paired physics-debug line/fill pipelines,
constructs the complete App with the overlay reported unavailable, advances
real simulation authority by one tick, tears down, and then performs the
healthy restart. Diagnostic pipeline creation is therefore best-effort rather
than a hidden visual-host startup requirement.

The isolated Jolt adapter additionally injects failure after runtime lease,
job/temp allocator creation, the three-filter bundle, and PhysicsSystem/filter
ownership transfer. Each checkpoint restores the process lease count and is
followed by a healthy same-process body lifecycle. These are focused ownership
seams, not a fake SDL/Jolt backend framework. Per-upload GPU failure injection
and pre/post-submit cancellation are covered separately by the S3 fake-backed
registry tests; the installed lifecycle above supplies the native Metal path.

## Post-Cleanup Architecture Boundary

The cleanup keeps one active Apple Silicon macOS/Metal graph and rejects every
other requested target before resolving engine dependencies. It also rejects
an Apple-Silicon macOS request with the wrong ABI or a non-Mach-O object format,
and the build refuses any Zig compiler other than exact 0.16.0. The visual and
cold products share one simulation/Flecs/Jolt graph; the cold branch still
resolves no SDL, GPU, editor, shader, or visual-content package. Flecs is built
with only the OS API required by the current engine rather than the former
HTTP, REST, script, metrics, module, and pipeline addon set. The editor leaves
the unconsumed ImPlot option disabled.

The reusable district contract now contains structural types, limits,
validation, and capabilities only. The installed west/east coordinates,
procedural collision, and exact route live in the sandbox district recipe used
by cook, load, replay, restore, and hostile preflight. Feature command queues
share one bounded ring mechanic while retaining their typed admission,
reservation, counter, and diagnostic behavior. Generated replay/simulation
cohort options are verified against the exact dependency manifests.

The editor owns its visibility, tool state, histories, and drafts per instance;
it retains no renderer pointer and receives narrow immutable frame inputs.
ImGui display scale comes from SDL window pixel density with a finite positive
fallback. Validation bootstrap state, constructors, scenario dispatch, and
injected-fault seams are compile-time-specialized out of the normal client and
remain unavailable to the cold authority. The final normal-product scanner
rejects the complete validation bootstrap-profile set as well as scenario and
fault-injection markers.

Removing the legacy single-bundle digest path intentionally changed the one
accepted content cohort. Current live cook/config verification uses these
post-cleanup identities; historical S7/S8 records retain the identities that
were true for those runs:

| Artifact or semantic cohort | Current SHA-256 |
|---|---|
| West `s3_fixture.icdb` | `0396ed142f96fd2d6d19d92a55ee62a703d187d09c1e175a1affb22463317f2b` |
| East `s6_east.icdb` | `fbf82af3f08570f1f503ae955aa282dd5c03f02a32a4ac52f1ddce810a1b4215` |
| Canonical `catalog.icat` | `13e5a79d1d277b4b8d344c8f906358e64c92920c2a8139e1e72d234a67f3af82` |
| Admitted `ContentCohort` | `53a65a03bee9d6b09edeb9fd8e8b9c781128c84aed84c77e45dcbf0b9910ac21` |

## Automated Baseline

The numeric bullets immediately below are the 2026-07-13 post-cleanup baseline,
not current S11 counts. They are retained so later regressions can identify the
tree that originally established each capability.

- Debug and ReleaseFast, editor excluded: 169/169 build steps and 589/589 tests
  pass in each mode on the post-cleanup tree. Debug with the editor enabled
  separately passes 172/172 steps and 589/589 tests. These gates include the
  generated dependency-cohort verifier, product/validation marker scan,
  installed validation relocation, and normal/cold linkage boundaries. Exact
  Zig and native macOS target/ABI/object-format negative guards also pass. The
  editor-enabled ReleaseFast application and native diagnostics/authoring
  consumers are compiled and exercised by the native aggregate.
- The filtered extracted source package passes 98/98 normal steps and 196/196
  tests with shader tools unavailable, then passes the cold product's 32/32
  steps and 52/52 tests independently.
- The fresh post-cleanup cooker gate passes 22/22 steps and 8/8 tests. Its live
  catalog verifier recomputes both bundle hashes, the catalog hash, and the
  semantic `ContentCohort`, then compares them with both checked-in cold
  configuration files.
- The cold product's final Debug and ReleaseFast gates each pass 32/32 steps and
  52/52 tests, including exact package allowlist, linkage, generated logical
  manifest, and M3 lifecycle verification. The standalone installed-product
  shell scan now enforces the same scenario, fault-injection, and storage-
  injection marker set as the canonical Zig final-binary scanner.
- Installed bundle/catalog admission and relocation passes 22/22 steps from
  `/tmp` with both exact bundles and the canonical catalog.
- Native installed ReleaseFast runtime: the 80/80-step aggregate passes S2,
  S3, S6 adjacent overlap/drain, S7 ownership, S8 population,
  minimize/restore, injected
  initialization/restart, S4-A diagnostics/fault inspection, S4-B installed
  capture/replay, S4-C bounded physics visualization/profiling, S5 editor
  authoring/cold restore, and the separate headless save/restart path serially,
  including when the caller supplies an invalid `INCINERATOR_CONTENT_ROOT`.
- `zig fmt --check` and `git diff --check`: pass.

### Historical post-S11 aggregate

This table records the post-S11 checkpoint before the later IV/IC corrective
cohorts. Current IC5-H evidence follows it.

| Evidence | Result |
|---|---|
| `zig build test-macos-readiness -Doptimize=ReleaseFast -Deditor=true -j1 --summary all` | **Pass — 86/86 steps** |
| Direct `-Dproduct=headless` test/lifecycle graph | **Pass — exit 0** |
| Installed S2 240/80 wheel presentation | **Pass — all wheel, vehicle, input, crate, and enter/exit flags true at both cadences** |
| Installed S8 240/80 route/residency lifecycle | **Pass — one physically valid actor planned/spawned/despawned; exact wait/resume/transfer/dormancy/controller lifecycle and clean drain at both cadences** |
| Installed S11 240/80 combat presentation | **Pass — 3,840/960 and 1,280/960 frame/scripted-tick cohorts; every required flag true** |
| Extracted source broad/cold graph | **Pass — 182/182 broad steps with 395/395 tests; 32/32 cold steps with 62/62 tests** |
| Current Debug regression | **Pass — 253/253 steps and 885/885 tests** |
| Current ReleaseFast regression | **Pass — failure-only summary exits 0 with no failures** |
| Direct rendered normal product | **Pass — later acceptance confirmed F1/F2/F3, collect/drop, melee feedback, exact rejected vehicle reason, a retained visibly red and separately readable player-death state, respawn countdown, and clean Escape shutdown. Held movement/camera/vehicle controls remain covered by their installed graphical scenarios; see the interaction-validation ledger.** |

### Current IC5-H corrective evidence — 2026-07-17

| Evidence | Result |
|---|---|
| `zig build test -Deditor=false --summary all` | **Pass — 255/255 steps and 922/922 tests** |
| `zig build verify-mp4c --summary all` | **Pass — 87/87 steps and 154/154 tests, including clean/nominal/adverse/blackout and real-GNS continuity** |
| `zig build test-sandbox-developer-host --summary all` | **Pass — 28/28 steps and 42/42 tests** |
| `zig build -Deditor=true --summary all` | **Pass — 53/53 install/build steps** |
| Installed Metal incident journey | **Pass — 2,166 ticks, four complete anomalies, both district crossings, stable vehicle/carry projection, semantic replay, and best-effort graphical replay** |

The exact run, inspector health, semantic vehicle-part evidence, stable identity
sample counts, and reproduction commands are recorded in the
[human-test incident validation ledger](human-test-incident-capture.md).

Hosted run `29211872146` established the deterministic macOS M1 contract before
S3-C: tests/builds, source packaging, installed-content relocation, and the
hosted headless boundary all passed. The expanded S3 source-package and
non-GPU relocation gates remain suitable for hosted CI. Graphical smokes stay
local because hosted WindowServer/Metal availability is not a reliable
contract.
