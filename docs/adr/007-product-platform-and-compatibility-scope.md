# ADR-007: Product, Platform, and Compatibility Scope

**Status:** Accepted and implemented for product/package/platform compatibility;
the initial network delivery sequence was superseded by ADR-016 through ADR-018
on 2026-07-13

**Date:** 2026-07-09

**Decision Maker:** Matt

## Context

The engine started as a learning project and is now being rebuilt around a concrete game. Product ambition, dependency compatibility, platform backends, packaging boundaries, and licensing materially affect every lower-level architectural decision.

## Decision

### Product and network scope

At this decision's 2026-07-09 acceptance, Incinerator was scoped as a
game-specific engine for a single-player, GTA-style sandbox first. An
authoritative online/MMO game was an aspiration rather than a current delivery
commitment.

The initial engine preserves only the inexpensive properties that keep that future credible:

- GPU-independent, serializable logical simulation state;
- stable persistent identity distinct from process-local handles;
- authoritative simulation separated from presentation snapshots;
- a headless composition that can later become a server host;
- commands and events that do not assume input is local.

Replication, prediction, reconciliation, interest management, distributed
persistence, account services, and MMO operations were deferred until an
explicit multiplayer vertical slice was approved. ADR-016 through ADR-018
subsequently accepted that multiplayer-first architecture. MP0-MP6 now
implement its local/listen/dedicated authority foundation; public services,
distributed persistence, Steam routing, and MMO operations remain deferred.

The intended future model is an authoritative server, not deterministic peer/client lockstep. Jolt's cross-platform deterministic build option is therefore deliberately `false`. Fixed-rate simulation and stable scheduling remain valuable, but the engine does not promise bitwise-identical physics across architectures or platforms.

### Engine and game boundary

The engine is intended to become open source. The game, its content, and its assets will be packaged and licensed separately. The engine license is currently undecided, no root `LICENSE` is present, and no license is granted by this repository at present.

Implementation may continue while that choice is deferred, but public reuse or redistribution must not be described as licensed. Selecting and adding an engine license is a separate owner decision before an open-source release.

Engine packages must not silently include game-owned content. The unreferenced
demo GLBs formerly under `assets/models` were removed from the engine
repository. Small engine test fixtures may be added only when their provenance
and redistribution terms are recorded; current fixtures are narrow
self-authored conformance inputs rather than game content.

### Tested dependency cohort

The foundational versions form one compatibility cohort:

| Component | Contract |
|---|---|
| Zig | `0.16.0` exact in `.zigversion` and `build.zig.zon` |
| SDL | SDL `3.4.14` through `castholm/SDL` wrapper `0.5.3`, commit `fb2d799c4778832a34ccb3739e40dded700684bd` |
| Physics | Jolt Physics `5.5.0` (`23dadd0e603f1b321142d4c74df07fce85064989`) through JoltC (`52d8c98df523f449eb3e01b1060a0fde052970d1`) and the adapted wrapper based on `c7ff571d475ae4ef26e327e6ffcd81f158e93d97` |
| Other Zig wrappers | Exact development commits/hashes in `build.zig.zon`, with feature/linkage/ABI options fixed in `build.zig` |

These dependencies are upgraded and validated as a cohort, not independently under an “or later” promise. The physics adapter fixes the ABI policy: 32-bit object layers, single-precision world coordinates, exceptions disabled, and compile-time JoltC ABI assertions enabled. Flecs C and Zig bindings receive the same explicit debug, allocator, precision, addon, and layout options, with the imported module as the single owner of `flecs.c`. The engine compiles zgui's SDL3 GPU backend against the same SDL 3.4.14 headers as the linked runtime instead of zgui's transitive SDL snapshot.

### Platform priority and graphics backends

| Status | Platform | Architecture | Expected GPU path | Contract |
|---|---|---|---|---|
| Current | macOS | Apple Silicon (`aarch64`) | Metal with MSL | The only build, test, runtime, performance, editor, packaging, and CI target |
| Future/deferred | Linux, including SteamOS | Undecided | Likely Vulkan with SPIR-V | No current gate, compatibility promise, or required abstraction |
| Future/deferred | Windows | Undecided | Likely D3D12 with DXIL | No current gate, compatibility promise, or required abstraction |

Linux/SteamOS and Windows are product possibilities, not current engineering
targets. Greenfield cleanup removes their active backend/build/shader branches
instead of maintaining dormant compatibility paths. The engine will not
introduce multi-platform abstractions, cross-build constraints, CI jobs,
shader gates, packaging work, or runtime tests solely to preserve them.

The vendored `third_party/joltc-zig` build package retains upstream
Windows/Linux compiler and system-library conditionals. They are
dependency-internal portability code, not top-level engine platform policy or
support. Incinerator rejects a non-native-Apple-Silicon-macOS target before the
active client or cold-authority graph resolves that dependency.

A future platform is reactivated only by a new product decision that defines
its architecture, backend, packaging, and validation contract. Porting work
starts from the current contracts plus repository history. Linux
headless/server support must be explicitly selected before authoritative-server
implementation; it is not maintained in advance. Mobile, web, consoles, and
Intel macOS are also outside the current support contract.

Shader outputs, reflection JSON, and generated Zig modules live in the Zig
cache. macOS CI and release validation use the exact-pinned base manifest and
explicit tool paths. Historical SPIR-V/DXIL experiments exist in repository
history only and are not current validation requirements.

### Compatibility policy

The overhaul is greenfield. Existing internal and public APIs, file organization, editor layout, serialized data, and exact rendered output are not compatibility contracts.

Do not add migration shims, deprecated aliases, dual architectures, or abstraction layers solely to preserve prototype code. Each implementation stage must remain buildable, and the falling-crate behavior is retained only as the first end-to-end migration fixture.

Before a future stable engine release, the project may deliberately version a public API and content schema. That is a new decision, not an implied constraint on this overhaul.

### Initial hosts

- `sandbox`: the interactive game-development host;
- `headless`: simulation and behavior tests without renderer/editor linkage;
- optional in-process ImGui editor capabilities in development builds;
- a server composition only when the multiplayer slice begins.

This list records the initial host sequence. The later accepted topology in
ADR-016 now has executable embedded, constrained listen, and dedicated
placements over one authority/session model.

## Consequences

- The initial local program was judged by its single-player slice rather than
  hypothetical MMO scale; later multiplayer work is judged by ADR-016 through
  ADR-019 and the living architecture review.
- Persistence and presentation boundaries are established early because they are useful now as well as online later.
- Cross-platform deterministic physics is not a multiplayer prerequisite for the chosen authoritative-server strategy.
- Platform support is explicitly limited to Apple Silicon macOS. Secondary
  platforms impose no current compile-time, shader, runtime, packaging, or CI
  requirements.
- Prototype APIs may be removed directly instead of wrapped.
- Game-owned assets cannot become implicit engine repository, package, or
  runtime dependencies.
- The repository remains intentionally unlicensed until the owner selects an engine license.
