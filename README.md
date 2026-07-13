# Incinerator Engine

Incinerator is a game-specific 3D engine being rebuilt for a single-player sandbox, with a deliberate path toward a future authoritative online game. It uses Zig, SDL3, Jolt Physics, Flecs, and ImGui.

The engine is intended to become open source and the game will be licensed separately. No engine license has been selected yet, so this repository currently grants no license. The overhaul is greenfield: prototype APIs and file formats may change without compatibility shims. See [`OVERHAUL_PLAN.md`](OVERHAUL_PLAN.md) for current status and delivery gates.

## Toolchain Cohort

These versions are one tested compatibility cohort and should be upgraded together rather than package-by-package:

| Component | Pinned version | Integration |
|---|---|---|
| Zig | `0.16.0` exact | Recorded in `.zigversion` and `build.zig.zon` |
| SDL | `3.4.12` | `castholm/SDL` wrapper `0.5.2` at an exact commit |
| Jolt Physics | `5.5.0` | Engine-owned JoltC build package with exact Jolt, JoltC, and Zig wrapper commits |
| Flecs | Exact development commit | `zflecs` wrapper pinned with an explicit ABI/feature cohort and one C-source owner |
| ImGui | Exact development commit | Optional `zgui` editor; its SDL3 backend is compiled by the engine against the selected SDL 3.4.12 headers |

The complete dependency identities live in `build.zig.zon` and [`third_party/joltc-zig/README.md`](third_party/joltc-zig/README.md). Dependency features that affect linkage, ABI, or compiled capabilities are selected in `build.zig`; they are not inherited silently from wrapper defaults. Jolt's cross-platform deterministic build mode is deliberately disabled. The future network model is an authoritative server, not client lockstep; enabling that mode would need a measured requirement and performance evaluation.

## Platform Priority

| Status | Platform | Architecture | Graphics path | Contract |
|---|---|---|---|---|
| Current | macOS | Apple Silicon (`aarch64`) | Metal / MSL | The only build, test, runtime, performance, editor, packaging, and CI target |
| Future/deferred | Linux / SteamOS | Undecided | Likely Vulkan / SPIR-V | No current support claim, build gate, CI job, or compatibility requirement |
| Future/deferred | Windows | Undecided | Likely D3D12 / DXIL | No current support claim, build gate, CI job, or compatibility requirement |

Existing Linux, Windows, Vulkan, and D3D12 code is dormant prior work, not a
maintained contract. It may break as the macOS architecture evolves. Porting
resumes only after a separate product decision selects a second platform; that
work may adapt or replace dormant paths instead of constraining current design.
Mobile, web, consoles, and Intel macOS are also outside the current contract.

## Developer Environment Setup (macOS)

### Prerequisites

#### 1. Zig Compiler

Install Zig **0.16.0 exactly** using the official archive or a version manager. Do not use an unpinned package-manager `latest` as the project toolchain contract.

```bash
zig version  # Must print 0.16.0
```

#### 2. Shader Compilation Tools

The maintained build compiles GLSL 4.50 to MSL for macOS and generates
canonical SPIR-V reflection data to validate the shader/renderer contract.
Dormant SPIR-V/DXIL branches may remain in the build, but they are not currently
run, tested, or treated as compatibility requirements.

For local convenience on macOS, tools may come from `PATH`:

```bash
brew install shaderc spirv-cross
glslc --version
spirv-cross --version
```

CI and release validation use the exact-pinned macOS base manifest. A historical
Windows DXIL manifest remains for future porting, but it is not a current gate.
See [`tools/shader-toolchain/README.md`](tools/shader-toolchain/README.md).
Generated shaders, reflection JSON, and embedding modules remain in the Zig
cache; builds do not write generated artifacts into the source tree.

### Building

```bash
# Build the engine
zig build

# Build and run
zig build run

# Run the full kernel, feature, host, adapter, and shader contract
zig build test

# Run the SDL-free real Flecs/Jolt sandbox lifecycle suite
zig build test-headless -Deditor=false

# Compile the headless artifact without invoking any shader tool
zig build check-headless -Deditor=false \
  -Dglslc=/definitely/missing/glslc \
  -Dspirv-cross=/definitely/missing/spirv-cross \
  -Dshadercross=/definitely/missing/shadercross

# Run the SDL-free sandbox composition
zig build run-headless -Deditor=false

# Run the renderer-free Jolt integration test
zig build test-physics

# Run shader reflection contract tests directly
zig build test-shaders

# Verify the release configuration
zig build -Doptimize=ReleaseFast

# Build without development editor dependencies
zig build -Deditor=false

# Verify an installed executable without initializing a window or GPU
zig build run -- --verify-install

# Exercise only the cooked bundle/schema and installed /tmp relocation gates
zig build test-content -Deditor=false
zig build test-content-cooker -Deditor=false
zig build smoke-installed-content -Deditor=false

# Record the ReleaseFast S0 characterization as versioned JSON
zig build measure-s0 -Doptimize=ReleaseFast -Deditor=false

# Record the ReleaseFast S1 character-slice characterization
zig build measure-s1 -Doptimize=ReleaseFast -Deditor=false

# Record the ReleaseFast S2 occupied-vehicle characterization
zig build measure-s2 -Doptimize=ReleaseFast -Deditor=false

# Record the ReleaseFast S3-A procedural district characterization
zig build measure-s3 -Doptimize=ReleaseFast -Deditor=false

# Self-terminating native visual cadence/shutdown checks
zig build run -Deditor=false -- \
  --visual-smoke --frames=480 --virtual-render-hz=240
zig build run -Deditor=false -- \
  --visual-smoke --frames=160 --virtual-render-hz=80

# Run the S1 character/jump/block/camera smoke above and below tick rate
zig build run -Deditor=false -- \
  --s1-visual-smoke --frames=480 --virtual-render-hz=240
zig build run -Deditor=false -- \
  --s1-visual-smoke --frames=160 --virtual-render-hz=80

# Run the S2 vehicle/steering/collision/authority smoke above and below tick rate
zig build run -Deditor=false -- \
  --s2-visual-smoke --frames=1440 --virtual-render-hz=240
zig build run -Deditor=false -- \
  --s2-visual-smoke --frames=480 --virtual-render-hz=80

# Run the serialized Tier-1 installed-runtime readiness gate. This launches
# the installed ReleaseFast Mach-O from /tmp, not Zig's cache artifact.
zig build test-macos-readiness \
  -Doptimize=ReleaseFast -Deditor=false

# The current three native gates can also be run independently. The historical
# S1 visual gate remains available as a regression check.
zig build smoke-installed-s1-macos \
  -Doptimize=ReleaseFast -Deditor=false
zig build smoke-installed-s2-macos \
  -Doptimize=ReleaseFast -Deditor=false
zig build smoke-window-lifecycle-macos \
  -Doptimize=ReleaseFast -Deditor=false
zig build smoke-init-failures-macos \
  -Doptimize=ReleaseFast -Deditor=false
```

## Content Boundary

The engine package intentionally excludes `assets`. Any GLB files under the
working tree's `assets/models` directory are game-owned development content,
not engine package or startup dependencies.

The S3-B runtime now consumes a versioned renderer-neutral cooked bundle from
an explicit absolute content root. Source glTF and image decoding exist only in
the host cooker; the runtime executable does not import the former prototype
glTF loader, zmesh, or zstbi. The build cooks the self-authored fixture into the
Zig cache and installs it beneath
`share/incinerator/content/district/s3_fixture.icdb` with its provenance record.
`zig build run` configures the installed content root explicitly, while a
relocated installed executable derives the same root from its application
prefix. `--content-root=/absolute/path` overrides either behavior.

Normal sandbox startup reads and validates the cooked bundle on a joined worker,
activates logical collision independently, resolves a fallback until the Metal
fence signals, and then draws the authored scene instances. `--verify-install`
validates the installed cooked content without initializing SDL or a GPU.
Host-owned proximity hysteresis and repeated installed load/cancel/unload/reload
evidence remain S3-C work.

## Controls

| Key | Action |
|---|---|
| ESC | Quit |
| W / A / S / D | Move the character, or throttle/reverse and steer while driving |
| E | Enter or exit the sandbox vehicle |
| Space | Jump on foot; service brake while driving |
| Left Shift | Handbrake while driving |
| Right mouse + drag | Turn/look and orbit the current control target |
| F1 | Toggle editor UI |
| F2 | Toggle ImGui demo |

Physics debug rendering and its former editor panel/hotkey were removed during the JoltC migration. A replacement is deferred until it can be implemented against the new adapter with explicit ownership and teardown rules.

## Architecture

The overhaul is converging on a thin kernel, feature-owned vertical slices, narrow capability contracts, backend adapters, and explicit host composition roots. See:

- [`OVERHAUL_PLAN.md`](OVERHAUL_PLAN.md)
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
- [`ADR-009: Runtime Content and Streaming Boundary`](docs/adr/009-runtime-content-and-streaming.md)
- [`macOS Runtime Readiness Record`](docs/validation/macos-readiness.md)
- the complete [`docs/adr`](docs/adr) directory

The engine loop separates input, fixed-rate simulation, and presentation:

```text
input pump (per frame) -> simulation ticks (fixed 120 Hz) -> presentation
```

The current overhaul boundary is intentionally concrete rather than a future
asset/framework abstraction. S3-A owns logical simulation; S3-B owns cooked
visual content and streamed GPU residency:

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
- `DistrictFeature` owns a bounded asynchronous logical lifecycle, one
  persistent district entity, transactional static-body ownership, typed
  outcomes/events, and renderer-neutral extraction through loader/static-body
  ports; the real worker publishes only fixed plain data and never touches
  Runtime, Flecs, Jolt, SDL, or renderer state;
- the sandbox composition owns the V4 save envelope, runtime clock and identity
  cursor, cross-feature identity validation, and authoritative restoration of
  feature-owned character/vehicle tuning, occupied relationships, and logical
  district state;
- exactly one composition-owned physics step advances crates, characters, and
  vehicles; no feature adapter privately advances the shared Jolt world;
- the public engine module exposes feature-authoring contracts and a type-erased
  startup-only runtime/registry, while the concrete sandbox/Jolt `Simulation`
  remains an internal conformance composition rather than engine API;
- the headless artifact and its extracted-package tests contain no SDL, ImGui,
  renderer, asset-loader, or shader-tool edge.

The visual sandbox and headless host construct the same owned logical
`Simulation`; the visual host additionally composes S3-B content and residency.
The former `GameWorld`, borrowed Flecs/Jolt composition, direct
ECS render query, and editor mutation path have been removed. The editor keeps
stats, camera, and render panels. Scene inspection/manipulation returns in a
later tooling slice through persistent IDs and typed feature commands rather
than raw Flecs/Jolt access.
Fixed-rate simulation is not a claim of bitwise or cross-platform deterministic
lockstep. The current zflecs wrapper permits one owned world per process, so
successful atomic old/new world replacement remains an explicit open decision
before multi-world server architecture.

## License

The engine is intended to be open source and the game will be licensed separately. The engine license has not been selected yet; no license is granted by this repository at present.
