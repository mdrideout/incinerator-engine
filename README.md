# Incinerator Engine

Incinerator is a game-specific 3D engine with a completed single-player sandbox
foundation and an accepted multiplayer-first authoritative-session direction.
The intended experience supports solo play as a local form of the same
authority model used by optional private listen/invite and canonical public
dedicated sessions. The selected first network transport is the open-source
GameNetworkingSockets flat C API over direct IP; Steam networking remains an
optional non-vendored integration. It uses Zig, SDL3, Jolt Physics, Flecs, and
ImGui.

The engine is intended to become open source and the game will be licensed
separately. No engine license has been selected yet, so this repository
currently grants no license. The overhaul is greenfield: prototype APIs and
file formats may change without compatibility shims. See
[`OVERHAUL_PLAN.md`](OVERHAUL_PLAN.md) for the main roadmap,
[`ARCHITECTURE_REVIEW.md`](ARCHITECTURE_REVIEW.md) for the living architectural
assessment, [`MULTIPLAYER_PLAN.md`](MULTIPLAYER_PLAN.md) for the staged
multiplayer program and current MP0-MP2 status, and
[`CLEANUP_PLAN.md`](CLEANUP_PLAN.md) for the completed
post-M3 consolidation record.

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

# Manual three-terminal multiplayer test. Build/install once, then launch one authority
# and two graphical clients with distinct development accounts.
zig build install-mp2
./zig-out/bin/incinerator_mp2_server --port 27020
./zig-out/bin/incinerator_mp2_client --connect 127.0.0.1:27020 --account 1
./zig-out/bin/incinerator_mp2_client --connect 127.0.0.1:27020 --account 2

# Client controls: WASD move, Space jump, E enter/exit, F collect/drop, Escape quit. While
# driving, W/S are throttle/reverse, A/D steer, Space brakes, and Left Shift is
# the hand brake. P toggles vehicle prediction for live A/B comparison. F8
# manufactures a transport loss and reconnect while playing. Recoverable
# transport loss uses monotonic capped retry; rejection and authority shutdown
# terminate cleanly without reconnecting.
# The authority binds loopback by default. `--allow-remote` is only for trusted
# LAN/development testing because MP2 AccountId values are not authenticated.

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
logical collision independently, resolves a fallback until the Metal fence
signals, and then draws the authored scene instances. Adjacent hysteresis
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
| Space | Jump on foot; service brake while driving |
| Left Shift | Handbrake while driving |
| Right mouse + drag | Turn/look and orbit the current control target |
| F1 | Toggle editor UI |
| F2 | Toggle ImGui demo |
| F3 | Toggle editor input passthrough |

Open the editor with F1, then use **Tools → Physics Debug & Profiler**. Its
master switch and category checkboxes control bounded shapes, bounds, contacts,
centers of mass, and velocity evidence. The same panel shows persistent Metal
upload/draw state, visible capacity loss, fixed phase spans, and per-frame
draw/upload/stream/resource counts. These are host-only typed controls; they do
not mutate simulation state. Use Instruments and Metal capture for deeper
platform profiling.

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
- [`macOS Runtime Readiness Record`](docs/validation/macos-readiness.md)
- the complete [`docs/adr`](docs/adr) directory

The engine loop separates input, fixed-rate simulation, and presentation:

```text
input pump (per frame) -> simulation ticks (fixed 120 Hz) -> presentation
```

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
- the sandbox composition owns the current `SnapshotV7` save envelope, runtime
  clock and identity cursor, cross-feature identity validation, and
  authoritative restoration of feature-owned tuning, relationships, district,
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
The former `GameWorld`, borrowed Flecs/Jolt composition, direct ECS render
query, and editor mutation path have been removed. The editor keeps stats,
camera, render, diagnostics, profiling, physics-debug, and crate-authoring
panels. Persistent crate relocation now uses typed feature commands and exact
undo/redo change sets; the editor never receives raw Flecs/Jolt access.
Fixed-rate simulation is not a claim of bitwise or cross-platform deterministic
lockstep. The current zflecs wrapper permits one owned world per process. M3
accepts that as the operational model: replacement is a validated process
restart, while any future multi-world process requires a new architecture
decision.

## License

The engine is intended to be open source and the game will be licensed separately. The engine license has not been selected yet; no license is granted by this repository at present.
