# ADR-029: Engine, Game, and Authoring Ownership Boundary

**Status:** Accepted; EA0-EA5 implementation pending

**Date:** 2026-08-18

**Platform:** Apple Silicon macOS only

**Implementation plan:**
[Engine Authoring Foundation](../design/engine-authoring-foundation.md)

## Context

S15 closes the first content-rich sandbox cohort. It proves a strong runtime
foundation: fixed-tick authority, feature-owned state, cooked content,
renderer-owned GPU resources, persistent/replayable tuning, structured editor
panels, and incident evidence. It also exposes the next real pressure point.
Several capabilities exist only as slice-specific proofs:

- district content can carry one embedded PNG base-color texture, but the
  importer/material path is not yet practical for ordinary art production;
- vehicle tuning is typed, validated, persisted, replayed, and measured, but
  one startup configuration is shared by the current cohort and has no live
  authoring transaction or archetype identity;
- the renderer accepts one directional sun plus ambient light, but the sandbox
  supplies a fixed value and no authored local-light capability exists;
- revisioned selection, typed edit outcomes, undo/redo, and durable save exist
  only for crate relocation;
- district/map structure is largely expressed through game-specific Zig arrays
  rather than a game-owned map asset; and
- engine mechanics, developer tooling, and title semantics are intentionally
  separated in behavior but not yet packaged as a separately built game.

Adding a generic property system, unrestricted console, scripting VM, or
universal scene framework would hide these ownership questions instead of
answering them.

## Decision

Incinerator will implement EA0-EA5 as concrete vertical authoring slices before
the final open-engine/separate-game extraction.

### Four owners

1. **Engine runtime** owns reusable capabilities: typed asset identities,
   cooked scene/material data, GPU resource ownership, light evaluation,
   physics and gameplay capability contracts, streaming, typed mutation
   transactions, and generic diagnostic envelopes.
2. **Engine tooling** owns reusable development machinery: the workspace,
   selection transport, inspectors and gizmos, undo/redo infrastructure,
   cook/validation tools, and a local developer-control adapter. It is not part
   of the required shipping runtime.
3. **Game runtime/composition** owns title policy and data: vehicle archetypes,
   actual tuning values, materials and texture assets, light presets and
   placements, map layouts, roads, buildings, population, and gameplay rules.
4. **Game tooling** owns title vocabulary and workflows: semantic labels,
   palette contents, map-kit tools, title-specific validation, and custom
   incident projections. It uses engine tooling contracts without giving ImGui
   or a developer client direct access to authority, Flecs, Jolt, SDL, or the
   filesystem.

Tooling being supplied by the engine does not make authored game data engine
data. Likewise, an engine capability is not required to have a stable public
ABI while the repository remains greenfield.

### Typed authoring, not CVars

Every editable concern keeps a concrete owner-written value and command. UI and
AI clients consume the same manually registered description and transaction
surface. The engine will not introduce a string-to-any CVar registry,
reflection-driven ECS mutation, service locator, universal command bus, or
arbitrary code console.

Every accepted or rejected live edit identifies:

- the run and source (`ui`, local developer client, or scripted validation);
- stable target identity and expected revision;
- transaction ID and edit scope;
- before/requested/committed values where applicable;
- wall time, authority tick, and presentation frame;
- disposition and typed rejection reason; and
- durable asset identity/digest when the edit is committed as game content.

The three edit scopes are explicit:

- **preview** changes disposable presentation state only;
- **session** changes authoritative or host-owned live state through its normal
  tick/lifecycle boundary; and
- **asset commit** writes a new game-owned authored revision through a durable
  authoring owner.

No preview silently becomes authority or durable content.

### AI/developer control

Editor builds may expose a process-local macOS developer endpoint whose path,
protocol cohort, available schemas, and run identity are written to the run
manifest. A small CLI is the canonical client. It supports description,
inspection, typed apply, outcome polling, revert, durable commit, and bounded
test/measurement actions. It does not expose multiplayer administration,
production remote control, shell execution, or raw memory/object access.

ImGui tools and the CLI submit the same typed owner requests. The endpoint is
an adapter, not another state owner.

### Assets and maps

glTF 2.0 remains the canonical source interchange for mesh/material scenes.
Import and dependency resolution remain offline/editor-only. Runtime products
consume versioned cooked game content through explicit roots and stable asset
identities; the renderer never discovers arbitrary source paths.

The engine will supply reusable placed-scene, transform, static-collision,
navigation/streaming metadata, selection, cooking, and validation capabilities.
The game will supply ground, road, sidewalk, building, prop, lighting, spawn,
activity, navigation, and district content. Urban concepts are not promoted to
engine runtime types merely because the first title uses them.

### Scripting gate

No scripting VM is authorized by EA0-EA5. The current Zig game composition plus
data-driven assets is the game layer. After EA5/G1, a separate decision will
ask whether a concrete mission, trigger, dialogue, or rapidly iterated behavior
requires scripting.

If accepted later, gameplay scripts run only in the authority capability set;
presentation scripts use a separate client capability set. Scripts receive no
raw Flecs, Jolt, renderer, filesystem, or networking access. Lua 5.4 is the
first mature C-API candidate; WebAssembly is reserved for a demonstrated
untrusted-mod or sandboxing need.

## Consequences

- New material, vehicle, light, and map work lands in its intended owner from
  the start instead of being added to `main.zig` or another sandbox singleton.
- The existing crate-authoring controller is evidence for the transaction
  shape, not a generic object editor to be expanded indiscriminately.
- Engine diagnostics describe lifecycle, identity, revisions, timing,
  resources, and dispositions. Game diagnostics add semantic names, rules,
  expectations, and title-specific correlations.
- The final G1 extraction follows concrete second consumers instead of
  designing a speculative engine SDK.
- Current file and resource capacities remain accepted only for their measured
  conformance cohorts. New authored content records actual requirements and
  fails explicitly; it does not silently truncate or invent an unrelated cap.
- Secondary platforms, production asset collaboration, remote developer
  services, public scripting/plugin APIs, traffic, and multiplayer services
  remain deferred.

## References

- [glTF 2.0 specification](https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html)
- [SDL GPU texture creation](https://wiki.libsdl.org/SDL3/SDL_CreateGPUTexture)
- [Lua 5.4 reference manual](https://www.lua.org/manual/5.4/manual.html)
- [ADR-003 editor architecture](003-editor-architecture.md)
- [ADR-009 runtime content and streaming](009-runtime-content-and-streaming.md)
- [ADR-010 diagnostics and replay](010-developer-diagnostics-replay-and-debug-visualization.md)
- [ADR-011 persistent authoring](011-persistent-authoring-and-durable-save-slots.md)
- [ADR-028 four-district cohort](028-content-rich-four-district-cohort.md)
