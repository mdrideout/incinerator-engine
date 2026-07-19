# Incinerator Engine

Incinerator is a game-specific 3D engine with a completed single-player sandbox
and an accepted Apple Silicon macOS multiplayer foundation. MP0-MP5/M4 prove a
server-authoritative direct-IP session with characters, vehicles, carry
interaction, district relevance, NPCs, prediction, reconnect, bounded delta
replication, and open room admission. M5 client/authority cohesion is accepted:
solo is a cohesive placement of the same client/authority model. M6 is also
accepted: authority ingress, mutation, durable disposition, and derivative
publication now follow one bounded fail-stop atomic-publication cycle. MP6 is
accepted as well: graphical clients now use one generation-safe room lifecycle
across constrained private listen and dedicated direct-IP placements. The S10
damage/death/respawn slice is accepted: players and NPCs share bounded
authoritative vitals, clients request server-validated melee, death tears down
the disposable physical avatar while retaining the participant, and explicit
safe respawn creates a new avatar incarnation. S11 is accepted as well: an
authority-owned hostile NPC perceives, pursues, attacks through vitals, reacts,
dies, and is safely replaced with a new generation and visible client and
developer feedback. The intended experience supports solo play as a local
placement of the same authority model
used by optional private listen/invite and canonical public dedicated sessions.
The selected network transport is the open-source GameNetworkingSockets flat C API over
direct IP; Steam networking remains an optional non-vendored integration. It
uses Zig, SDL3, Jolt Physics, Flecs, and ImGui.

The engine is intended to become open source and the game will be licensed
separately. No engine license has been selected yet, so this repository
currently grants no license. The overhaul is greenfield: prototype APIs and
file formats may change without compatibility shims. See
[`OVERHAUL_PLAN.md`](OVERHAUL_PLAN.md) for the main roadmap,
[`ARCHITECTURE_REVIEW.md`](ARCHITECTURE_REVIEW.md) for the living architectural
assessment, [`MULTIPLAYER_PLAN.md`](MULTIPLAYER_PLAN.md) for the completed
MP0-MP5/M4 foundation and accepted M5 cohesion gate, and
[`CLEANUP_PLAN.md`](CLEANUP_PLAN.md) for the completed post-M3 consolidation
record. M6 transactional authority hardening, MP6 playable room flow, and S10
damage/death/respawn are complete and accepted:
[`M6 (accepted)`](docs/validation/m6-transactional-authority-cycle.md) →
[`MP6 (accepted)`](docs/validation/mp6-playable-multiplayer-room-flow.md) →
[`S10 (accepted)`](docs/validation/s10-damage-death-respawn.md) →
[`S11 (accepted)`](docs/validation/s11-npc-encounter-combat-response.md).
Post-S11 manual real-window acceptance exposed a missing temporal gameplay
validation and causal-observability layer. IV0-IV5 are now complete and
accepted, including shared solo/listen/dedicated scenarios, deterministic
fault/fuzz/reconnect coverage, routine and long soaks, and semantic Metal
visibility. The continuing contract is recorded in the
[`interaction validation design`](docs/design/gameplay-interaction-validation-and-observability.md),
with durable rationale in
[`ADR-020`](docs/adr/020-gameplay-interaction-validation-and-observability.md)
and phase evidence in the
[`validation ledger`](docs/validation/gameplay-interaction-validation-and-observability.md).
Human acceptance further tightened that contract: physical controller teardown
on death now leaves a red, noninteractive replicated death proxy until
respawn; the hostile presentation separates from that proxy so it cannot hide
the corpse; primitive material tints are enforced by the real product shader;
carried objects are visibly released; drop placement stays within an active
district; and gameplay trace schema 2 preserves typed rejection reasons and
semantic presentation membership transitions.
The current correction also reserves incident capacity for notes/replay/
handoff, rejects unsupported player drops without moving the object, keeps the
two-district sandbox route resident behind visible collision, retains NPC
death presentation until replacement registration, and clamps the follow
camera to the target side of world blockers.

## Toolchain Cohort

These versions are one tested compatibility cohort and should be upgraded together rather than package-by-package:

| Component | Pinned version | Integration |
|---|---|---|
| Zig | `0.16.0` exact | Recorded in `.zigversion`; enforced by the build guard (the package manifest records the same minimum floor) |
| SDL | `3.4.12` | `castholm/SDL` wrapper `0.5.2` at an exact commit |
| Jolt Physics | `5.5.0` | Engine-owned JoltC build package with exact Jolt, JoltC, and Zig wrapper commits |
| Flecs | Exact development commit | `zflecs` wrapper pinned with an explicit ABI/feature cohort and one C-source owner |
| ImGui | Exact development commit | Optional `zgui` editor; its SDL3 backend is compiled by the engine against the selected SDL 3.4.12 headers |
| GameNetworkingSockets | `1.5.1` exact commit | Open-source direct-IP transport behind an engine-owned C ABI shim; Steamworks remains optional and absent |

The complete dependency identities live in `build.zig.zon` and [`third_party/joltc-zig/README.md`](third_party/joltc-zig/README.md). Dependency features that affect linkage, ABI, or compiled capabilities are selected explicitly; they are not inherited silently from wrapper defaults. The shared simulation build graph generates the replay cohort from those pins and physics limits, and an automatic verifier rejects manifest drift. Flecs is compiled as private ECS storage with only the OS API implementation addon, excluding its HTTP, REST, script, metrics, module, and pipeline surfaces. Jolt's cross-platform deterministic build mode is deliberately disabled. The future network model is an authoritative server, not client lockstep; enabling that mode would need a measured requirement and performance evaluation.

## Platform Priority

| Status | Platform | Architecture | Graphics path | Contract |
|---|---|---|---|---|
| Current | macOS | Apple Silicon (`aarch64`) | Metal / MSL | The only build, test, runtime, performance, editor, packaging, and CI target |
| Future/deferred | Linux / SteamOS | Undecided | Likely Vulkan / SPIR-V | No current support claim, build gate, CI job, or compatibility requirement |
| Future/deferred | Windows | Undecided | Likely D3D12 / DXIL | No current support claim, build gate, CI job, or compatibility requirement |

The active build retains no Linux, Windows, Vulkan, or D3D12 path. Porting
resumes only after a separate product decision selects a second platform; that
work will establish a new tested target cohort instead of constraining current
design around removed prototype branches.
Mobile, web, consoles, and Intel macOS are also outside the current contract.

The vendored `third_party/joltc-zig` package still contains upstream
OS/compiler conditionals for JoltC itself. Those are dependency-internal
portability code, not an Incinerator target, build option, test gate, or support
claim. The top-level client and cold-headless graphs reject every non-native
Apple Silicon macOS target before resolving that package.

## Developer Environment Setup (macOS)

### Prerequisites

#### 1. Zig Compiler

Install Zig **0.16.0 exactly** using the official archive or a version manager. Do not use an unpinned package-manager `latest` as the project toolchain contract.

```bash
zig version  # Must print 0.16.0
```

#### 2. Shader Compilation Tools

The maintained build compiles GLSL 4.50 to MSL for macOS and generates
canonical SPIR-V reflection data to validate the shader/renderer contract. No
secondary-platform shader branch is part of the active graph.

For local convenience on macOS, tools may come from `PATH`:

```bash
brew install shaderc spirv-cross
glslc --version
spirv-cross --revision
```

CI and release validation use the exact-pinned macOS manifest. Future platform
work must introduce its own reviewed toolchain cohort. See
[`tools/shader-toolchain/README.md`](tools/shader-toolchain/README.md).
Generated shaders, reflection JSON, and embedding modules remain in the Zig
cache; builds do not write generated artifacts into the source tree.

#### 3. Multiplayer Transport Build Tools

The MP2 direct-IP products build pinned GameNetworkingSockets from source.
On Apple Silicon macOS install its build-time dependencies with:

```bash
brew install cmake ninja protobuf openssl@3
```

The open engine does not require Steamworks, a Steam login, a cloud provider,
or a lobby service.

### Building

```bash
# Build the engine
zig build

# Build and run
zig build run

# The normal product creates one playable hostile encounter after the local
# player and west district are authority-ready. Use Q for melee and R to request
# respawn after death; this is ordinary product composition, not a validation
# scenario flag. A separate narrow product owner correlates NPC-caused player
# death, character despawn, cooldown, respawn, and the new avatar projection.

# Compile the cold MP2 authority and presentation-only graphical client, then
# run the real-GNS two-client acceptance proof and binary boundary audit.
zig build check-mp2
zig build verify-mp2 --summary all

# Run MP2.1/MP3 lifecycle, prediction, deterministic latency/jitter/loss/
# duplicate/reorder/blackout, accepted-ingress replay, real-GNS regression,
# and independent authority-stop process acceptance.
zig build verify-mp3 --summary all

# Run MP4-A authoritative vehicle replication plus bounded local prediction,
# correction/collision/lifecycle evidence, faults, replay, and GNS regressions.
zig build verify-mp4 --summary all

# Add authoritative carry interaction, disconnect cleanup, acknowledged
# district baselines, relevance hysteresis, JIP/reconnect, and GNS contention.
zig build verify-mp4b --summary all
zig build verify-mp4c --summary all
zig build verify-mp4d --summary all
zig build verify-mp4e --summary all
zig build verify-mp4-complete --summary all

# Run the focused open room/invite proof, or the full MP5 gate. Steamworks is
# not required; direct GNS IP remains the executable route.
zig build run-mp5-acceptance --summary all
zig build verify-mp5 --summary all

# Run the complete Apple Silicon macOS multiplayer-foundation gate.
zig build verify-m4 -j1 --summary all

# Run the accepted M5 cohesion aggregate. Its contract and measured evidence
# matrix are linked below.
zig build verify-m5 -j1 --summary all

# Run the accepted M6 transactional-authority gate, then the complete playable
# MP6 room gate (listen, dedicated, fault lifecycle, architecture, and inherited
# regressions).
zig build verify-m6 -j1 --summary all
zig build verify-mp6-room -j1 --summary failures

# Run the accepted authoritative damage/death/respawn slice. This starts two
# real graphical clients in both listen and dedicated placements.
zig build verify-s10 -Deditor=false -j1 --summary failures

# Run the accepted hostile-NPC encounter slice. This composes focused
# authority/persistence/replay/fault/scale gates, the normal-product host
# encounter lifecycle, installed solo Metal combat presentation, and graphical
# listen and dedicated death-and-replacement proofs. Characterize the declared 64-NPC/
# 16-participant synthetic ceiling separately in ReleaseFast.
zig build verify-s11 -Deditor=true -j1 --summary failures
zig build measure-s11 -Deditor=false -Doptimize=ReleaseFast

# Verify that the filtered Zig source package retains the M5/M6/MP6/S11
# architecture and can compile/run its product bootstrap, headless,
# persistence, snapshot, replay, and session closure.
zig build verify-source-package -Deditor=false --summary all

# Manual three-terminal multiplayer test. Build/install once, then launch one authority
# and two graphical clients with distinct development accounts.
zig build install-mp2
./zig-out/bin/incinerator_mp2_server --port 27020
./zig-out/bin/incinerator_mp2_client --connect 127.0.0.1:27020 --account 1
./zig-out/bin/incinerator_mp2_client --connect 127.0.0.1:27020 --account 2

# Client controls: WASD move, Space jump, E enter/exit, F collect/drop,
# Q melee, R request respawn after death, right mouse + drag to turn/look,
# Escape quit. While
# driving, W/S are throttle/reverse, A/D steer, Space brakes, and Left Shift is
# the hand brake. P toggles vehicle prediction for live A/B comparison. F8
# manufactures a transport loss and reconnect while playing. Recoverable
# transport loss uses monotonic capped retry; rejection and authority shutdown
# terminate cleanly without reconnecting.
# The authority binds loopback by default. `--allow-remote` is only for trusted
# LAN/development testing because MP2 AccountId values are not authenticated.

# Manual MP6 listen-room test. The host writes a permission-restricted guest
# ticket and prints its path; launch the graphical guest with that exact path.
zig build install-mp6
./zig-out/bin/incinerator_mp6_listen --port 27020 --ticket /tmp/incinerator-guest.room
./zig-out/bin/incinerator_mp2_client --ticket /tmp/incinerator-guest.room

# Manual MP6 dedicated-room test. The server writes one signed ticket per
# configured account; launch one graphical client for each printed ticket path.
./zig-out/bin/incinerator_mp6_server --port 27020 --ticket-dir /tmp/incinerator-room
./zig-out/bin/incinerator_mp2_client --ticket /tmp/incinerator-room/account-1.room
./zig-out/bin/incinerator_mp2_client --ticket /tmp/incinerator-room/account-2.room

# MP6 controls add C to cancel the active room operation and L to leave/close;
# Q performs authoritative melee, R requests respawn after death, and F8 still
# manufactures guest transport loss and bounded reconnect.

# Compile or explicitly install the separate visual-validation host. Normal
# `zig build` does not install validation; validation lives in libexec.
zig build check-validation -Deditor=false
zig build install-validation -Deditor=false
zig build verify-validation-boundary -Deditor=false

# Run the full kernel, feature, host, adapter, and shader contract
zig build test

# Run the SDL-free real Flecs/Jolt sandbox lifecycle suite
zig build test-headless -Deditor=false

# Build and test the genuinely cold operational headless product. This branch
# does not resolve SDL, GPU/editor packages, shaders, or visual content.
zig build -Dproduct=headless test --summary all

# Run the deterministic M3 authority soak (32,768 ticks) or its opt-in long
# cohort (131,072 ticks). Both require a ReleaseFast Apple Silicon macOS build.
zig build -Dproduct=headless -Doptimize=ReleaseFast measure-m3 --summary none
zig build -Dproduct=headless -Doptimize=ReleaseFast measure-m3-long --summary none

# Install only the operational binary plus its exact config/content manifests,
# then verify that allowlist and Mach-O boundary.
prefix=$(mktemp -d /tmp/incinerator-headless.XXXXXX)
zig build -Dproduct=headless -Doptimize=ReleaseFast \
  --prefix "$prefix" install-headless-product verify-installed-headless-product

# Run the installed product. Inputs must be absolute paths. The optional
# producers exercise bounded external work and exact completion delivery.
"$prefix/bin/incinerator_headless" \
  --config "$prefix/etc/incinerator/headless/config.example.json" \
  --content-manifest "$prefix/share/incinerator/headless/content.json" \
  --synthetic-producers

# Exercise the S4-B same-cohort replay contracts and compile the standalone
# SDL/editor/GPU-free replay verifier.
zig build test-replay -Deditor=false
zig build check-replay -Deditor=false

# Record and verify the installed cooked-content scenario from /tmp. This
# proves normal replay plus an exact district-ingress divergence.
zig build smoke-installed-s4-replay-macos \
  -Doptimize=ReleaseFast -Deditor=false

# Exercise bounded physics extraction, persistent Metal uploads/draws, and the
# fixed host profiler in the complete sandbox scenario.
zig build smoke-installed-s4-physics-debug-macos \
  -Doptimize=ReleaseFast -Deditor=false

# Exercise real editor relocation/undo/redo/save, then cold-restore that exact
# slot in a fresh installed SDL/editor/GPU-free process.
zig build smoke-installed-s5-authoring-macos \
  -Doptimize=ReleaseFast -Deditor=true

# Exercise the standalone two-process durable save/restart path.
zig build smoke-installed-s5-save-macos \
  -Doptimize=ReleaseFast -Deditor=false

# Exercise the complete carry lifecycle in the installed Metal host at both
# cadence extremes, then run the SDL-free 128-cycle ownership measurement.
zig build smoke-installed-s7-macos \
  -Doptimize=ReleaseFast -Deditor=false
zig build measure-s7 \
  -Doptimize=ReleaseFast -Deditor=false --summary none

# Run the current SDL-free 64-NPC/65-controller scale characterization.
zig build measure-s8 \
  -Doptimize=ReleaseFast -Deditor=false --summary none

# Run the renderer-free Jolt integration test
zig build test-physics

# Run shader reflection contract tests directly
zig build test-shaders

# Verify the release configuration
zig build -Doptimize=ReleaseFast

# Build without development editor dependencies
zig build -Deditor=false

# Verify the build-installed cooked content without initializing a window or
# GPU. This command runs Zig's cache artifact; use the installed smokes below
# when executable relocation is part of the proof.
zig build run -- --verify-install

# Exercise only the cooked bundle/catalog/admission and installed /tmp gates
zig build test-content -Deditor=false
zig build test-content-cooker -Deditor=false
zig build test-district-content-catalog -Deditor=false
zig build smoke-installed-content -Deditor=false

# Run the serialized Tier-1 installed-runtime readiness gate. This launches
# the separately named installed validation Mach-O from /tmp, not the normal
# product or Zig's cache artifact.
zig build test-macos-readiness \
  -Doptimize=ReleaseFast -Deditor=true

# The native gates can also be run independently. The historical S1 visual
# gate remains available as a regression check.
zig build smoke-installed-s1-macos \
  -Doptimize=ReleaseFast -Deditor=false
zig build smoke-installed-s2-macos \
  -Doptimize=ReleaseFast -Deditor=false
zig build smoke-installed-s3-macos \
  -Doptimize=ReleaseFast -Deditor=false
zig build smoke-installed-s6-macos \
  -Doptimize=ReleaseFast -Deditor=false
zig build smoke-installed-s7-macos \
  -Doptimize=ReleaseFast -Deditor=false
zig build smoke-installed-s8-macos \
  -Doptimize=ReleaseFast -Deditor=false
zig build smoke-installed-s11-macos \
  -Doptimize=ReleaseFast -Deditor=false
zig build smoke-installed-s4-diagnostics-macos \
  -Doptimize=ReleaseFast -Deditor=false
zig build smoke-installed-s4-replay-macos \
  -Doptimize=ReleaseFast -Deditor=false
zig build smoke-installed-s4-physics-debug-macos \
  -Doptimize=ReleaseFast -Deditor=false
zig build smoke-installed-s5-authoring-macos \
  -Doptimize=ReleaseFast -Deditor=true
zig build smoke-installed-s5-save-macos \
  -Doptimize=ReleaseFast -Deditor=false
zig build smoke-window-lifecycle-macos \
  -Doptimize=ReleaseFast -Deditor=false
zig build smoke-init-failures-macos \
  -Doptimize=ReleaseFast -Deditor=false
```

The installed S11 validation additionally performs four validation-only,
fenced Metal object-ID captures at contact, player death, respawn, and NPC
death. It asserts semantic pixel occupancy/bounds above and below the 60 Hz
authority cadence, including a meaningful minimum footprint for the retained
dead player. Shader reflection separately proves that primitive material tint
reaches the real color pass; the ID oracle is not treated as proof of product
swapchain color. The normal `incinerator_engine` binary contains none of the
oracle or first-failure artifact path; those remain in `incinerator_validation`.

`incinerator_engine` is the normal interactive client. Scripted slice
scenarios, lifecycle probes, initialization failpoints, and deliberate faults
are compiled only into `incinerator_validation`, which is installed under
`libexec/incinerator` only when a validation step requests it. The installed
smoke/readiness steps select that artifact automatically; validation-only
command-line flags are rejected by the normal client.

## Content Boundary

The engine package and repository intentionally exclude game-owned `assets`.
The retired unreferenced demo GLBs were removed; only the small self-authored,
provenance-recorded engine conformance fixtures under `fixtures/` participate
in cooking, packaging, or startup.

The runtime consumes versioned renderer-neutral cooked bundles from
an explicit absolute content root. Source glTF and image decoding exist only in
the host cooker; the runtime executable does not import the former prototype
glTF loader, zmesh, or zstbi. The build cooks two self-authored adjacent
fixtures and a canonical exact-identity catalog into the Zig cache, then
installs them beneath `share/incinerator/content/district/` with both
provenance records. The checked-in dependency closure is west -> east ->
catalog; identical inputs produce byte-identical outputs.
`zig build run` configures the installed content root explicitly, while a
relocated installed executable derives the same root from its application
prefix. `--content-root=/absolute/path` overrides either behavior.

Before logical or GPU activation, the shared admission boundary loads only
`district/catalog.icat`, validates both bundles and coordinate-specific logical
checksums, and creates the content fingerprint used by replay and durable
saves. Runtime scene requests recheck the exact admitted bundle identity, so a
bundle replaced after startup cannot publish ready content under the original
cohort.

The reusable district contract owns bounded payload shapes, structural
validation, checksums, tickets, and loader/navigation capabilities. The
sandbox-owned [`src/sandbox/district_recipe.zig`](src/sandbox/district_recipe.zig)
owns the installed west/east coordinates, collision fixtures, recipe cohort,
and exact route topology consumed by cooking, admission, streaming, restore,
replay, and preflight. Concrete game-world policy is therefore not part of the
engine feature contract.

The normal sandbox samples the character or occupied vehicle position at fixed
ticks through host-owned proximity hysteresis. Exactly two catalog-backed
stream slots share one joined content worker and one bounded GPU registry.
Entering a district reads and validates its exact cooked bundle, activates
logical collision, and immediately draws every mandatory blocking proxy.
Authored decorative scene instances are added after the Metal fence signals;
they never replace collision presentation. Adjacent hysteresis
permits both west and east districts to overlap while per-generation recycling
lets either drain without releasing its neighbor. `--verify-install` validates
installed cooked content without initializing SDL or a GPU. The installed S3
smoke preserves the single-district cancellation regression; the S6 smoke
proves three complete forward/reverse overlap cycles, truthful production
diagnostics, both render cadences, and complete two-slot drain from `/tmp`.

## Controls

| Key | Action |
|---|---|
| ESC | Quit |
| W / A / S / D | Move the character, or throttle/reverse and steer while driving |
| E | Enter or exit the sandbox vehicle |
| F | Collect the nearby carryable, or drop the held carryable into the current district |
| Q | Request authoritative melee against the nearest valid target |
| R | Request authoritative respawn after death and cooldown |
| Space | Jump on foot; service brake while driving |
| Left Shift | Handbrake while driving |
| Right mouse + drag | Turn/look and orbit the current control target |
| F1 | Toggle editor UI |
| F2 | Toggle ImGui demo |
| F3 | Toggle editor input passthrough |
| Command+Option+I | Recommended macOS shortcut to flag a human-test anomaly |
| F9 / Fn+F9 | Optional shortcut when macOS delivers the function key to SDL |
| Command+Shift+9 | Optional alternate anomaly shortcut |

Open the editor with F1, then use **Tools → Physics Debug & Profiler**. Its
master switch and category checkboxes control bounded shapes, bounds, contacts,
centers of mass, and velocity evidence. The same panel shows persistent Metal
upload/draw state, visible capacity loss, fixed phase spans, and per-frame
draw/upload/stream/resource counts. These are host-only typed controls; they do
not mutate simulation state. Use Instruments and Metal capture for deeper
platform profiling.

**Tools → Gameplay Inspector** explains the selected local player or NPC across
its durable/replicated identity, authority and presentation pose, health/life,
encounter deadline, separation, last action disposition, and filtered causal
trace. Trace freeze, resume, and clear are bounded developer requests; durable
incident streams replace the removed giant terminal JSON export. The tool
cannot mutate gameplay authority. The small gameplay panel
at the upper-left remains visible when F1 hides developer windows and gives
plain-language health, damage, attack, cooldown, death, respawn, and rejected
action feedback. A dead player remains visible in red until respawn, rather
than disappearing as an implicit representation of authority teardown.

Every Debug product run records a bounded schema-2 diagnostic bundle under
`~/Library/Logs/Incinerator/runs`. Press Command+Option+I near an anomaly (or
use F9/Fn+F9 when macOS actually delivers it), then open **Tools → Incident
Capture**, add a note, and click **Save note + Copy for LLM**. The note is
persisted before the handoff is refreshed and copied. The clipboard contains the
run path, current health, anomaly index, and evidence limits—not a giant JSON
payload. Each finalized anomaly has a 15-second typed pre-roll, four typed
materialized windows, a 15 FPS product-only trail, five human-visible anchors
stored at no more than 1280x720, a product-only flag frame, and a semantic-ID
image/map. Source and stored dimensions are indexed separately. A reserved
128 MiB nonvisual lane keeps notes, replay, manifests, and LLM handoff working
even after the bounded visual lane is exhausted; the UI reports whether the
durable handoff has landed.
Use `visual-index.ndjson` actual timestamps rather than filenames to order
images. To review a long trail chronologically without mutating the bundle:

```bash
zig build incident-visual-report -- <run-folder> <separate-output-folder>
```

Use an isolated root or run the graphical acceptance workflow with:

```bash
INCINERATOR_INCIDENT_ROOT=/tmp/incinerator-incidents \
  zig build run -- --incident-smoke

# Full scripted product journey: carry/drop, vehicle, both district crossings,
# death/respawn, NPC death/replacement, resize, rapid flags, and handoff.
INCINERATOR_INCIDENT_ROOT=/tmp/incinerator-journey \
  zig build run -- --incident-journey

# Same journey plus real SDL minimize/restore event acceptance.
INCINERATOR_INCIDENT_ROOT=/tmp/incinerator-window-journey \
  zig build run -- --incident-journey-window

# Paired installed-product capture cost measurement. Run both commands under
# comparable foreground conditions and compare the emitted p50/p95/p99 line.
INCINERATOR_INCIDENT_ROOT=/tmp/incinerator-capture-benchmark \
  zig build run -- --incident-benchmark
zig build run -Dincident-capture=false -- --incident-benchmark

zig build inspect-incident -- /absolute/path/to/run
zig build replay-incident -- /absolute/path/to/run \
  /Users/matt/repos/incinerator-engine/zig-out/share/incinerator/content

# Best-effort graphical control/camera re-execution; semantic replay above is
# the deterministic authority claim.
zig build run -- --replay-incident=/absolute/path/to/run
```

See [ADR-021](docs/adr/021-local-human-test-incident-bundles.md), the
[incident design](docs/design/human-test-incident-capture.md), and the
[validation record](docs/validation/human-test-incident-capture.md).

To author and persist the sandbox crate, supply an existing absolute save root
and enable the editor explicitly:

```bash
mkdir -p /tmp/incinerator-saves
zig build run -Deditor=true -- --save-root=/tmp/incinerator-saves
```

Open **Tools → Crate Authoring**, select the available crate, edit its draft
position, and use **Apply position**, **Undo**, **Redo**, and **Save**. The tool
only sees immutable records and emits typed requests that the host applies
after UI drawing. The committed slot is
`/tmp/incinerator-saves/sandbox.isav`. S5 intentionally exposes one relocation
producer and one fixed slot; CLI/automation routing, autosave, migration, and
multiple writers are future work.

Open **Tools → Interaction** to inspect the immutable carryable/holder state
and emit the same typed collect/drop requests used by F. A carryable is either
owned by one district, held by one character, or dormant because its owner is
unloaded; it never has both a world body and a holder. Pressing E while carrying
is a healthy typed rejection recorded in developer diagnostics, not an
application failure.

## Architecture

The engine uses a thin kernel, feature-owned vertical slices, narrow capability
contracts, backend adapters, and explicit host composition roots. See:

- [`OVERHAUL_PLAN.md`](OVERHAUL_PLAN.md)
- [`ARCHITECTURE_REVIEW.md`](ARCHITECTURE_REVIEW.md)
- [`MULTIPLAYER_PLAN.md`](MULTIPLAYER_PLAN.md)
- [`CLEANUP_PLAN.md`](CLEANUP_PLAN.md)
- [`ADR-007: Product, Platform, and Compatibility Scope`](docs/adr/007-product-platform-and-compatibility-scope.md)
- [`ADR-008: Feature-Oriented Engine Architecture`](docs/adr/008-feature-oriented-engine-architecture.md)
- [`S0 Crate Lifecycle Design`](docs/design/s0-crate-lifecycle.md)
- [`S0 Acceptance Record`](docs/validation/s0-acceptance.md)
- [`S0 Performance Baseline`](docs/performance/s0-baseline.md)
- [`S1 Character Slice Design`](docs/design/s1-character-slice.md)
- [`S1 Acceptance Record`](docs/validation/s1-acceptance.md)
- [`S1 Performance Baseline`](docs/performance/s1-baseline.md)
- [`S2 Vehicle Slice Design`](docs/design/s2-vehicle-slice.md)
- [`S2 Acceptance Record`](docs/validation/s2-headless-acceptance.md)
- [`S2 Performance Baseline`](docs/performance/s2-baseline.md)
- [`S3 District Streaming Design`](docs/design/s3-district-streaming.md)
- [`S3-A Acceptance Record`](docs/validation/s3a-headless-acceptance.md)
- [`S3-A Performance Baseline`](docs/performance/s3a-baseline.md)
- [`S3-B Acceptance Record`](docs/validation/s3b-acceptance.md)
- [`S3-B Resource Baseline`](docs/performance/s3b-baseline.md)
- [`S3-C Acceptance Record`](docs/validation/s3c-acceptance.md)
- [`S3-C Installed Lifecycle Baseline`](docs/performance/s3c-baseline.md)
- [`ADR-009: Runtime Content and Streaming Boundary`](docs/adr/009-runtime-content-and-streaming.md)
- [`ADR-010: Developer Diagnostics, Replay, and Debug Visualization`](docs/adr/010-developer-diagnostics-replay-and-debug-visualization.md)
- [`S4 Developer Diagnostics and Reproducibility`](docs/design/s4-developer-diagnostics.md)
- [`S4-A Validation Record`](docs/validation/s4a-acceptance.md)
- [`S4-B Validation Record`](docs/validation/s4b-acceptance.md)
- [`S4-C Validation Record`](docs/validation/s4c-acceptance.md)
- [`S4-C Physics Debug / Profiler Baseline`](docs/performance/s4c-baseline.md)
- [`ADR-011: Persistent Authoring and Durable Save Slots`](docs/adr/011-persistent-authoring-and-durable-save-slots.md)
- [`S5 Persistent Authoring and Durable Save Design`](docs/design/s5-persistent-authoring.md)
- [`S5 Validation Record`](docs/validation/s5-acceptance.md)
- [`ADR-012: Canonical District Catalog and Fixed Two-Slot Streaming`](docs/adr/012-canonical-district-catalog-and-fixed-two-slot-streaming.md)
- [`S6 Multi-District Content Design`](docs/design/s6-multi-district-content.md)
- [`S6 Validation Record`](docs/validation/s6-acceptance.md)
- [`S6 Two-District Streaming Baseline`](docs/performance/s6-baseline.md)
- [`ADR-013: Feature-Owned Carry Interaction and District Ownership`](docs/adr/013-feature-owned-carry-interaction-and-district-ownership.md)
- [`S7 Interaction and Cross-District Ownership Design`](docs/design/s7-interaction-ownership.md)
- [`S7 Validation Record`](docs/validation/s7-acceptance.md)
- [`S7 Interaction and Ownership Baseline`](docs/performance/s7-baseline.md)
- [`ADR-014: Bounded Navigation and Feature-Owned NPC Population`](docs/adr/014-bounded-district-navigation-and-feature-owned-npc-population.md)
- [`S8 Navigation and Population Design`](docs/design/s8-navigation-population.md)
- [`S8 Validation Record`](docs/validation/s8-acceptance.md)
- [`S8 Population and Scale Baseline`](docs/performance/s8-baseline.md)
- [`ADR-015: Apple Silicon macOS Pre-Server Readiness`](docs/adr/015-macos-pre-server-readiness.md)
- [`M3 Pre-Server Readiness Design`](docs/design/m3-pre-server-readiness.md)
- [`M3 Acceptance Record`](docs/validation/m3-acceptance.md)
- [`M3 Performance Baseline`](docs/performance/m3-baseline.md)
- [`ADR-016: Authority Session Topology`](docs/adr/016-authority-session-topology.md)
- [`ADR-017: Network Identity, Protocol, and Replication`](docs/adr/017-network-identity-protocol-and-replication.md)
- [`ADR-018: GameNetworkingSockets and Steam-Compatible Routing`](docs/adr/018-gamenetworkingsockets-and-steam-compatible-routing.md)
- [`MP4 Feature Replication Sequence`](docs/design/mp4-feature-replication-sequence.md)
- [`MP4 Architecture Closeout`](docs/validation/mp4-architecture-closeout.md)
- [`MP5 Open Room and Admission Boundary`](docs/design/mp5-open-room-and-admission-boundary.md)
- [`MP5 Acceptance Record`](docs/validation/mp5-acceptance.md)
- [`M4 Multiplayer Foundation Gate`](docs/validation/m4-multiplayer-foundation.md)
- [`M5 Client/Authority Cohesion Contract`](docs/design/m5-client-authority-cohesion.md)
- [`M5 Acceptance Record`](docs/validation/m5-client-authority-cohesion.md)
- [`M6 Transactional Authority Cycle`](docs/design/post-m5-transactional-authority-cycle.md)
- [`M6 Acceptance Record`](docs/validation/m6-transactional-authority-cycle.md)
- [`MP6 Playable Multiplayer Room Flow`](docs/design/mp6-playable-multiplayer-room-flow.md)
- [`MP6 Acceptance Record`](docs/validation/mp6-playable-multiplayer-room-flow.md)
- [`S10 Damage, Death, and Respawn`](docs/design/s10-damage-death-respawn.md)
- [`S10 Acceptance Record`](docs/validation/s10-damage-death-respawn.md)
- [`ADR-019: Authoritative NPC Encounter and Durable Replacement`](docs/adr/019-authoritative-npc-encounter-and-replacement.md)
- [`S11 Playable NPC Encounter and Combat Response`](docs/design/s11-npc-encounter-combat-response.md)
- [`S11 Acceptance Record`](docs/validation/s11-npc-encounter-combat-response.md)
- [`S11 Performance Baseline`](docs/performance/s11-baseline.md)
- [`Post-S11 Runtime Corrective Audit`](docs/validation/post-s11-runtime-corrective-audit.md)
- [`ADR-020: Gameplay Interaction Validation and Observability`](docs/adr/020-gameplay-interaction-validation-and-observability.md)
- [`Gameplay Interaction Validation and Observability Design`](docs/design/gameplay-interaction-validation-and-observability.md)
- [`Gameplay Interaction Validation and Observability Evidence`](docs/validation/gameplay-interaction-validation-and-observability.md)
- [`Human Test Incident Capture and LLM Diagnostic Handoff`](docs/design/human-test-incident-capture.md)
- [`ADR-021: Local Human-Test Incident Bundles`](docs/adr/021-local-human-test-incident-bundles.md)
- [`Human-Test Incident Capture Validation Record`](docs/validation/human-test-incident-capture.md)
- [`macOS Runtime Readiness Record`](docs/validation/macos-readiness.md)
- the complete [`docs/adr`](docs/adr) directory

The embedded-product loop separates input, fixed-rate authority, and
presentation:

```text
input pump (per frame) -> authority ticks (fixed 60 Hz) -> presentation
```

Embedded and dedicated placement now share the accepted 60 Hz authority rate;
rendering remains independently paced and embedded replication remains 20 Hz.
The embedded product routes character, vehicle, carry, melee, respawn, and NPC
encounter gameplay through the shared session behavior and consumes replicated
client state.
M5 acceptance records the owner, regression, native, package, and independent-
review evidence.

The current overhaul boundary is intentionally concrete rather than a future
asset/framework abstraction. S3-A owns logical simulation, S3-B owns cooked
visual content and streamed GPU residency, and S3-C keeps focus selection and
proximity policy in the host while exercising the complete lifecycle:

- GPU textures have explicit `OwnedTexture` owners and copy-safe borrowed views;
- glTF/resource initialization unwinds transactionally with checked upload sizes;
- Jolt process lifetime is leased across worlds, while `BodyId` values are
  world-qualified and use an engine-owned 64-bit serial so Jolt's finite native
  generation cannot revive stale handles;
- physical input is maintained independently from ImGui capture and main-window
  focus loss, preventing captured releases from becoming stuck gameplay state;
- a sandbox-owned action latch preserves edges across zero-tick frames and
  consumes them once across multi-tick frames before emitting device-independent
  character commands;
- renderer failures propagate separately from benign unavailable frames, and
  scene/ImGui pipelines use the actual SDL swapchain and supported depth formats.
- `CrateFeature` owns typed commands/outcomes, Flecs components, coordinated
  body/entity lifecycle, V1 records, and immutable interpolated
  presentation records;
- `CharacterFeature` independently owns locomotion commands, grounded-state
  events, Jolt CharacterVirtual lifecycle, canonical V1 records and persisted
  simulation tuning, and interpolated
  capsule/camera presentation without importing crates, SDL, or renderer code;
- `VehicleFeature` owns typed spawn/enter/drive/exit/despawn commands, explicit
  driver authority, logical vehicle records, and chassis/four-wheel extraction
  through backend-neutral vehicle and driver ports;
- `DistrictFeature` owns two bounded asynchronous logical lifecycle slots over
  one worker, up to two persistent district entities, transactional static-body ownership, typed
  outcomes/events, and renderer-neutral extraction through loader/static-body
  ports; the real worker publishes only fixed plain data and never touches
  Runtime, Flecs, Jolt, SDL, or renderer state;
- `InteractionFeature` owns the one carryable's district/held/dormant logical
  state and transactional collect/drop lifecycle through narrow carrier and
  district ports;
- `NpcFeature` owns bounded autonomous-character authority, semantic goals,
  district-aware navigation state, persistence, diagnostics, and presentation;
  a separate fixed population planner is only a producer;
- `VitalsFeature` owns bounded player/NPC health, damage application, and
  exactly-once death facts; `NpcEncounterFeature` owns hostile perception,
  target choice, attack timing, and locomotion/damage proposals without owning
  transforms or health;
- sandbox replacement policy owns durable delayed NPC replacement, while the
  normal-product encounter owner only submits the initial hostile after its
  player and west-district prerequisites are authority-ready;
- the normal graphical product's separate character-lifecycle owner correlates
  authority-owned local death, character despawn, respawn, and new replicated
  avatar state without owning those transitions;
- the automatic listen/dedicated product cohort is six NPCs, one per authored
  route node. The 64-NPC value remains a synthetic scale ceiling, not the
  automatic room population. The installed S8 graphical smoke uses one actor
  to prove route/residency lifecycle; dedicated scale measurements retain the
  complete 64-NPC/65-controller capacity claim;
- a private snapshot module owns the current `SnapshotV11` value, canonical
  codec, cold preflight, cross-feature identity validation, and exact
  build/world fingerprints; the live sandbox authority owns transactional
  capture/restoration of feature-owned tuning, relationships, district,
  interaction, and NPC state;
- exactly one composition-owned physics step advances crates, characters, and
  vehicles; no feature adapter privately advances the shared Jolt world;
- the public engine module exposes feature-authoring contracts and a type-erased
  startup-only runtime/registry, while the concrete sandbox/Jolt `Simulation`
  remains an internal conformance composition rather than engine API;
- the headless artifact and its extracted-package tests contain no SDL, ImGui,
  renderer, asset-loader, or shader-tool edge.

The visual sandbox and headless host construct the same owned logical
`Simulation`; the visual host additionally composes S3-B content and residency.
M4 deliberately retained a broad `local_solo` authority-administration facade.
M5 replaces it with an opaque embedded placement over the shared
authority core, role-scoped capabilities, replicated player-facing
presentation, explicit streaming/persistence owners, and one opaque heap-stable
developer owner. The complete aggregate regression and independent acceptance
review are recorded in the M5 acceptance document.
M5 records separate completion-aware placement and authority traces plus the
nested runtime phase observer. M6 completes the next boundary with
class-reserved ingress, an eight-stage fail-stop cycle, double-buffered
publication metadata, delivery leases and application receipts, bounded
reconnect replay, and stage-seven durable dispositions. Physical transport and
blocking storage remain outside the fixed tick, and M6 does not claim rollback
of an already stepped Jolt world. The current S11 cohort derives a conservative
172-publication participant-cycle bound, retains two cycles/344 records, and
drains them under the separate 16-message wire ceiling; a slow consumer that
exhausts the window is retired without faulting the room.
MP6 composes that authority through one generation-safe room coordinator in a
constrained listen owner and a ticketed dedicated owner. The host uses the
typed local link, guests use real GNS, graphical presentation remains
client-owned, and room closure deliberately provides no host migration.
S10 adds a backend-neutral bounded vitals feature plus authority-owned melee,
death cleanup, dead reconnect, safe explicit respawn, and disposable avatar
incarnation. The same protocol semantics are playable in local/listen and
dedicated placements; health and hit confirmation are never client authority.
S11 adds feature-owned hostile decisions, NPC melee proposals through vitals,
durable delayed replacement, explicit streamed-route restore modes, and one
renderer-neutral combat presentation owner. Automatic listen/dedicated
bootstrap uses six distinct authored route nodes; the normal embedded product
seeds one encounter through its host-managed authority; 64 NPCs remain a
synthetic scale ceiling rather than the default playable population. The
persistent headless host consumes restored encounter damage/death only through
exact attack correlation and preserves unrelated FIFO heads as fault evidence.
The former `GameWorld`, borrowed Flecs/Jolt composition, direct ECS render
query, and editor mutation path have been removed. The editor keeps stats,
camera, render, diagnostics, gameplay inspection, incident capture,
physics-debug, crate-authoring, and interaction panels. Persistent crate
relocation now uses typed feature commands and exact
undo/redo change sets; the editor never receives raw Flecs/Jolt access.
Fixed-rate simulation is not a claim of bitwise or cross-platform deterministic
lockstep. The current zflecs wrapper permits one owned world per process. M3
accepts that as the operational model: replacement is a validated process
restart, while any future multi-world process requires a new architecture
decision.

## License

The engine is intended to be open source and the game will be licensed separately. The engine license has not been selected yet; no license is granted by this repository at present.
