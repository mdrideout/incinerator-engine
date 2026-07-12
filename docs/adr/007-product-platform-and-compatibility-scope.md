# ADR-007: Product, Platform, and Compatibility Scope

**Status:** Accepted, amended 2026-07-12 (macOS-only scope)

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

| Status | Platform | Architecture | Expected GPU path | Contract |
|---|---|---|---|---|
| Current | macOS | Apple Silicon (`aarch64`) | Metal with MSL | The only build, test, runtime, performance, editor, packaging, and CI target |
| Future/deferred | Linux, including SteamOS | Undecided | Likely Vulkan with SPIR-V | No current gate, compatibility promise, or required abstraction |
| Future/deferred | Windows | Undecided | Likely D3D12 with DXIL | No current gate, compatibility promise, or required abstraction |

Linux/SteamOS and Windows are product possibilities, not current engineering
targets. Existing backend and build branches are dormant historical work and
may break without blocking macOS development. The engine will not introduce
multi-platform abstractions, cross-build constraints, CI jobs, shader gates,
packaging work, or runtime tests solely to preserve them.

A future platform is reactivated only by a new product decision that defines
its architecture, backend, packaging, and validation contract. Porting work may
adapt or replace dormant code. Linux headless/server support must be explicitly
selected before authoritative-server implementation; it is not maintained in
advance. Mobile, web, consoles, and Intel macOS are also outside the current
support contract.

Shader outputs, reflection JSON, and generated Zig modules live in the Zig
cache. macOS CI and release validation use the exact-pinned base manifest and
explicit tool paths. Historical SPIR-V/DXIL branches and manifests are not
current validation requirements.

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
- Platform support is explicitly limited to Apple Silicon macOS. Secondary
  platforms impose no current compile-time, shader, runtime, packaging, or CI
  requirements.
- Prototype APIs may be removed directly instead of wrapped.
- Game-owned GLBs cannot become implicit engine package or runtime dependencies.
- The repository remains intentionally unlicensed until the owner selects an engine license.
