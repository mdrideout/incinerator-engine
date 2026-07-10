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

## Supported Targets

| Platform | Architecture | Current graphics path | Status |
|---|---|---|---|
| macOS | Apple Silicon (`aarch64`) | Metal / MSL | Primary native development gate |
| Linux / SteamOS | `x86_64` | Vulkan / SPIR-V | CI workflow configured; hosted and native Vulkan runtime evidence remain release gates |
| Windows | `x86_64-windows-gnu` | D3D12 / DXIL by default | Offline generation and cross-link pass; hosted Windows and native D3D12 runtime evidence remain release gates |

`-Dwindows-gpu=vulkan` selects the provisional Windows Vulkan/SPIR-V fallback. Linux `x86_64` is also the intended future headless/server target. Mobile, web, consoles, and Intel macOS are outside the current support contract.

## Developer Environment Setup (macOS)

### Prerequisites

#### 1. Zig Compiler

Install Zig **0.16.0 exactly** using the official archive or a version manager. Do not use an unpinned package-manager `latest` as the project toolchain contract.

```bash
zig version  # Must print 0.16.0
```

#### 2. Shader Compilation Tools

The build compiles GLSL 4.50 into the selected target format: MSL on macOS, SPIR-V on Linux, and DXIL for the default Windows D3D12 path. The explicit Windows Vulkan fallback uses SPIR-V. Every path also generates canonical SPIR-V reflection data and validates the shader/renderer contract.

For local convenience on macOS, tools may come from `PATH`:

```bash
brew install shaderc spirv-cross
glslc --version
spirv-cross --version
```

CI and release validation use the exact-pinned base and Windows DXIL vcpkg manifests. The DXIL cohort also pins SDL_shadercross `3.0.0-preview2` and DXC `2026-05-27`; its executable is selected with `-Dshadercross=...` alongside `-Dglslc=...` and `-Dspirv-cross=...`. See [`tools/shader-toolchain/README.md`](tools/shader-toolchain/README.md). Generated shaders, reflection JSON, and embedding modules remain in the Zig cache; builds do not write generated artifacts into the source tree.

### Building

```bash
# Build the engine
zig build

# Build and run
zig build run

# Run the full kernel, feature, host, adapter, and shader contract
zig build test

# Run the SDL-free real Flecs/Jolt crate lifecycle suite
zig build test-headless

# Compile the headless artifact without invoking any shader tool
zig build check-headless \
  -Dglslc=/definitely/missing/glslc \
  -Dspirv-cross=/definitely/missing/spirv-cross \
  -Dshadercross=/definitely/missing/shadercross

# Run the SDL-free crate sandbox
zig build run-headless

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
```

## Content Boundary

The engine package intentionally excludes `assets`. Any GLB files under the working tree's `assets/models` directory are game-owned development content, not engine package or startup dependencies. The current sandbox uses generated primitives, and `--verify-install` does not load game content or initialize the GPU.

## Controls

| Key | Action |
|---|---|
| ESC | Quit |
| Right mouse + WASD | Move camera |
| Right mouse + drag | Look around |
| Right mouse + Q / E | Move camera down / up |
| W / E / R while using editor tools | Gizmo translate / rotate / scale |
| F1 | Toggle editor UI |
| F2 | Toggle ImGui demo |

Physics debug rendering and its former editor panel/hotkey were removed during the JoltC migration. A replacement is deferred until it can be implemented against the new adapter with explicit ownership and teardown rules.

## Architecture

The overhaul is converging on a thin kernel, feature-owned vertical slices, narrow capability contracts, backend adapters, and explicit host composition roots. See:

- [`OVERHAUL_PLAN.md`](OVERHAUL_PLAN.md)
- [`ADR-007: Product, Platform, and Compatibility Scope`](docs/adr/007-product-platform-and-compatibility-scope.md)
- [`ADR-008: Feature-Oriented Engine Architecture`](docs/adr/008-feature-oriented-engine-architecture.md)
- [`S0 Crate Lifecycle Design`](docs/design/s0-crate-lifecycle.md)
- the complete [`docs/adr`](docs/adr) directory

The engine loop separates input, fixed-rate simulation, and presentation:

```text
input pump (per frame) -> simulation ticks (fixed 120 Hz) -> presentation
```

The current M2/S0 boundary is intentionally concrete rather than a future
asset/framework abstraction:

- GPU textures have explicit `OwnedTexture` owners and copy-safe borrowed views;
- glTF/resource initialization unwinds transactionally with checked upload sizes;
- Jolt process lifetime is leased across worlds, while `BodyId` values are
  world-qualified and use an engine-owned 64-bit serial so Jolt's finite native
  generation cannot revive stale handles;
- physical input is maintained independently from ImGui capture and main-window
  focus loss, preventing captured releases from becoming stuck gameplay state;
- renderer failures propagate separately from benign unavailable frames, and
  scene/ImGui pipelines use the actual SDL swapchain and supported depth formats.
- `CrateFeature` owns typed commands/outcomes, Flecs components, coordinated
  body/entity lifecycle, V1 logical persistence, and immutable interpolated
  presentation records;
- the public engine module exposes feature-authoring contracts and a type-erased
  startup-only runtime/registry, while the concrete crate/Jolt `Simulation`
  remains an internal conformance composition rather than engine API;
- the headless artifact and its extracted-package tests contain no SDL, ImGui,
  renderer, asset-loader, or shader-tool edge.

The visual sandbox now renders the S0 crate from previous/current pose history;
legacy demo entities still use their latest ECS transforms during migration.
Fixed-rate simulation is not a claim of bitwise or cross-platform deterministic
lockstep. The current zflecs wrapper permits one owned world per process, so
successful atomic old/new world replacement remains an explicit open decision
before multi-world server architecture.

## License

The engine is intended to be open source and the game will be licensed separately. The engine license has not been selected yet; no license is granted by this repository at present.
