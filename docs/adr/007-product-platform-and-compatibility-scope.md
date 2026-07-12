# ADR-007: Product, Platform, and Compatibility Scope

**Status:** Accepted, amended 2026-07-12

**Date:** 2026-07-09

**Decision Maker:** Matt

## Context

The engine started as a learning project and is now being rebuilt around a concrete game. Product ambition, dependency compatibility, platform backends, packaging boundaries, and licensing materially affect every lower-level architectural decision.

## Decision

### Product and network scope

Incinerator is a game-specific engine for a single-player, GTA-style sandbox first. A future authoritative online/MMO game is an aspiration, not a current delivery commitment.

The initial engine preserves only the inexpensive properties that keep that future credible:

- GPU-independent, serializable logical simulation state;
- stable persistent identity distinct from process-local handles;
- authoritative simulation separated from presentation snapshots;
- a headless composition that can later become a server host;
- commands and events that do not assume input is local.

Replication, prediction, reconciliation, interest management, distributed persistence, account services, and MMO operations remain deferred until an explicit multiplayer vertical slice is approved.

The intended future model is an authoritative server, not deterministic peer/client lockstep. Jolt's cross-platform deterministic build option is therefore deliberately `false`. Fixed-rate simulation and stable scheduling remain valuable, but the engine does not promise bitwise-identical physics across architectures or platforms.

### Engine and game boundary

The engine is intended to become open source. The game, its content, and its assets will be packaged and licensed separately. The engine license is currently undecided, no root `LICENSE` is present, and no license is granted by this repository at present.

Implementation may continue while that choice is deferred, but public reuse or redistribution must not be described as licensed. Selecting and adding an engine license is a separate owner decision before an open-source release.

Engine packages must not silently include game-owned content. The `build.zig.zon` package paths intentionally exclude `assets`. Existing GLB files under `assets/models` are optional game-owned development content; the sandbox startup and `--verify-install` path do not depend on them. Small engine test fixtures may be added later only when their provenance and redistribution terms are recorded.

### Tested dependency cohort

The foundational versions form one compatibility cohort:

| Component | Contract |
|---|---|
| Zig | `0.16.0` exact in `.zigversion` and `build.zig.zon` |
| SDL | SDL `3.4.12` through `castholm/SDL` wrapper `0.5.2`, commit `1b67d371a531ecb0499d4b80a865631c299f472a` |
| Physics | Jolt Physics `5.5.0` (`23dadd0e603f1b321142d4c74df07fce85064989`) through JoltC (`52d8c98df523f449eb3e01b1060a0fde052970d1`) and the adapted wrapper based on `c7ff571d475ae4ef26e327e6ffcd81f158e93d97` |
| Other Zig wrappers | Exact development commits/hashes in `build.zig.zon`, with feature/linkage/ABI options fixed in `build.zig` |

These dependencies are upgraded and validated as a cohort, not independently under an “or later” promise. The physics adapter fixes the ABI policy: 32-bit object layers, single-precision world coordinates, exceptions disabled, and compile-time JoltC ABI assertions enabled. Flecs C and Zig bindings receive the same explicit debug, allocator, precision, addon, and layout options, with the imported module as the single owner of `flecs.c`. The engine compiles zgui's SDL3 GPU backend against the same SDL 3.4.12 headers as the linked runtime instead of zgui's older transitive SDL snapshot.

### Platform priority and graphics backends

| Tier | Platform | Architecture | Current SDL GPU path | Contract |
|---|---|---|---|---|
| 1 | macOS | Apple Silicon (`aarch64`) | Metal with MSL | Sole current runtime-quality, development, performance, editor, and packaging target |
| 2 | Linux, including SteamOS | `x86_64` | Vulkan with SPIR-V | Portability-preservation target: cross-compile, shader-contract, and headless gates only; native client work deferred |
| 2 | Windows | `x86_64-windows-gnu` | D3D12 with DXIL by default | Portability-preservation target: cross-compile, shader-contract, and headless gates only; native client work deferred |

Linux `x86_64` is also the intended future headless/server target. Mobile, web, consoles, and Intel macOS are outside the current support contract.

The Windows build owns an offline DXIL path and explicitly selects SDL's D3D12
backend by default. `-Dwindows-gpu=vulkan` preserves a provisional SPIR-V
fallback. These paths are maintained to prevent architectural decay, not to
claim current runtime support. Native Vulkan/D3D12 client validation,
platform-specific packaging, and editor polish resume only when a secondary
client platform is selected for playtesting or release.

Linux headless validation becomes required before an authoritative server host
is implemented. Linux client portability must be reconsidered before S3's
cooked-content/streaming contract is finalized, because filesystem, packaging,
memory, and upload assumptions become more expensive to change after that
point. Cross-build, headless-linkage, and offline shader gates remain mandatory
throughout macOS-first development.

Shader generation is target- and backend-specific. Its outputs, reflection JSON, and generated Zig modules live in the Zig cache. Local builds may use shader tools from `PATH`, while CI and release validation use the exact-pinned base or DXIL vcpkg manifest and explicitly selected executable paths.

### Compatibility policy

The overhaul is greenfield. Existing internal and public APIs, file organization, editor layout, serialized data, and exact rendered output are not compatibility contracts.

Do not add migration shims, deprecated aliases, dual architectures, or abstraction layers solely to preserve prototype code. Each implementation stage must remain buildable, and the falling-crate behavior is retained only as the first end-to-end migration fixture.

Before a future stable engine release, the project may deliberately version a public API and content schema. That is a new decision, not an implied constraint on this overhaul.

### Initial hosts

- `sandbox`: the interactive game-development host;
- `headless`: simulation and behavior tests without renderer/editor linkage;
- optional in-process ImGui editor capabilities in development builds;
- a server composition only when the multiplayer slice begins.

## Consequences

- Near-term architecture is judged by the single-player slice, not hypothetical MMO scale.
- Persistence and presentation boundaries are established early because they are useful now as well as online later.
- Cross-platform deterministic physics is not a multiplayer prerequisite for the chosen authoritative-server strategy.
- Runtime support is explicitly limited to Apple Silicon macOS; secondary
  platforms retain compile-time portability evidence without a runtime promise.
- Windows Vulkan/SPIR-V remains an explicit bootstrap fallback rather than the default or release backend.
- Prototype APIs may be removed directly instead of wrapped.
- Game-owned GLBs cannot become implicit engine package or runtime dependencies.
- The repository remains intentionally unlicensed until the owner selects an engine license.
