# Engine Authoring Foundation

**Status:** Approved roadmap; EA0 and EA0.5 accepted; Phase 7 first-class CLI
agent-contract implementation/automated/native/clean-context/comprehensive-
manual-agent candidate complete with product-owner stop review pending; EA1-EA5
not started

**Date:** 2026-08-18

**Decision:**
[ADR-029](../adr/029-engine-game-authoring-boundary.md)

**Prerequisite:**
[S15 accepted](../validation/s15-content-rich-district-expansion.md)

## Outcome

Turn the sandbox's narrow texture, tuning, lighting, authoring, and map proofs
into practical reusable engine capabilities while keeping actual assets,
archetypes, light placements, map kits, and gameplay policy owned by a
separately buildable game.

The program is intentionally vertical. Each phase must deliver one ordinary
macOS workflow that a person and an LLM agent can inspect, change, validate,
revert, persist, and reproduce. Shared infrastructure is extracted only from
those real consumers.

## Current Baseline

| Concern | Proven today | Missing practical capability |
|---|---|---|
| Textures/materials | Offline glTF cook, embedded PNG decode, UV0, base-color factor/map, explicit sRGB texture upload, generational scene residency | External/GLB dependency workflow, ordinary image sizes, optional and richer material inputs, stable material assets, assignment and authoring |
| Vehicles | Typed validated tuning, real-Jolt descriptor, persistence/replay, wheel presentation, objective dynamics report | Archetype identity, per-archetype assets/tuning, selection, live revisioned edit, AI client, safe rebuild semantics |
| Lighting | Renderer-neutral directional sun plus ambient value, conventional lit shader, Render Lab evidence | Editable world-owned sun, stable point lights, selection/gizmos, persistence and AI control |
| Authoring | EA0 stable target identity and transaction envelope; crate-specific selection, typed relocation, revisions, undo/redo, and durable save | Additional owner-specific typed editors; no generic property bag |
| Maps | Deterministic four-district cook/catalog, streaming, collision/navigation metadata, visual composition | Game-owned map asset, placed-asset workflow, reusable kit, editor placement, deterministic recook |
| Diagnostics | Structured workspace, authored-change evidence, panel metadata, incident timelines/images/replay, semantic draw/gameplay evidence, and an implemented EA0.5 live-control path | Separate engine/game build/content identity and accepted per-feature schemas as later phases add them |
| Scripting | Zig composition and data contracts | No demonstrated VM requirement; decision deliberately deferred |

## Ownership Matrix

| Capability | Engine runtime | Engine tooling | Game/runtime content | Game tooling |
|---|---|---|---|---|
| Assets | Stable IDs, cooked formats, residency | Import/cook/validate | Source assets and manifests | Palettes and semantic inspectors |
| Materials | Renderer-neutral values and GPU binding | Material inspection/edit requests | Material definitions and texture files | Title previews and conventions |
| Vehicles | Physics capability and typed reconfiguration | Vehicle Lab/control adapter | Archetypes, tuning and visual bindings | Title tuning presets/tests |
| Lights | Directional/point-light contracts and evaluation | Lighting Lab/gizmos | Presets, placements and time policy | Title lighting workflows |
| Maps | Placement/collision/navigation/streaming primitives | Selection, transform, save/cook | Ground, roads, buildings and layouts | Map kit and title validation |
| Diagnostics | Generic IDs, lifecycle, revisions, timing, outcomes | Workspace and local query/control | Semantic names and expected rules | Custom panels/evidence projections |

## Cross-Cutting Authoring Contract

Every phase uses the same small rules without creating a universal mutable
object model:

1. Each owner defines a typed value, validation, immutable inspection view,
   request union, outcome union, and stable identity.
2. Descriptors provide field names, units, descriptions, data examples,
   defaults/current values, mutability class, and typed validation failures.
   UI slider ranges are presentation hints, never hidden authority limits.
3. Requests carry expected revision and transaction ID. Stale edits reject
   rather than overwrite another producer.
4. UI and local AI clients submit through the same owner/controller path.
5. Preview, authoritative session edit, and durable asset commit are visibly
   different actions.
6. Every result is correlated into developer diagnostics and incident evidence.
7. Undo/redo is an owner-defined inverse/exact transaction, not memory rewind.
8. Editor-disabled and headless products do not acquire ImGui, the developer
   endpoint, source importers, or mutable authoring state unless an explicit
   validation product requests it.

## Phase Sequence

### EA0 — Ownership, identity, and transaction boundary

Implementation status: accepted by the product owner on 2026-08-29 after the
automated, installed, native Metal, architecture, dead-code, documentation, and
manual editor-interaction gates passed. See the
[EA0 implementation plan](ea0-ownership-identity-transaction-boundary.md) and
[validation ledger](../validation/ea0-ownership-identity-transaction-boundary.md).

- Accept ADR-029 and classify current renderer/content/vehicle/map/editor code.
- Define engine-runtime, engine-tooling, game-runtime/content, and game-tooling
  dependency rules without performing a broad file move.
- Define `AssetId`, `AuthoringTarget`, edit scope, revision, transaction source,
  outcome, and authored-change diagnostic envelope.
- Add architecture checks preventing tools from reaching Flecs/Jolt/SDL owners
  and preventing runtime content from reaching source paths.
- Define the developer endpoint lifecycle and discovery record without adding
  transport to the EA0 scope.

Acceptance: ownership is executable in imports/build targets, the existing
product remains unchanged, and no generic property/CVar/command framework is
introduced.

### EA0.5 — Local developer endpoint and canonical CLI

Schedule amendment status: explicitly authorized by the product owner on
2026-08-29, ahead of EA1, and accepted on 2026-08-30. EA0.5 implements the
transport and canonical client that EA0 deliberately only described. Its
implementation, focused and aggregate automated gates, installed native Metal
journey, LLM-agent workflow, human usability checkpoint, and
architecture/security/dead-code/documentation review are complete. It does not
retroactively enlarge EA0. On 2026-08-30 the product owner eliminated the
planned MCP adapter because local coding agents always have shell access and
authorized Phase 7 to make the CLI catalog, result guidance, and repository
skill first-class instead.

- Expose a developer-only process-local macOS Unix socket with explicit
  lifecycle, run identity, protocol cohort, registered schema identities, and
  a deterministic schema digest.
- Add the reusable typed client and installed `incinerator-dev` CLI for world
  and content discovery, stable-target inspection/selection, Character and
  Free Camera control, exact camera pose/focus, crate relocation with optimistic
  revision, transaction inspection, undo/redo, world-snapshot save, and
  correlated frame evidence.
- Route selection, camera, authoring, persistence, and capture through their
  existing owners on the graphical main thread. Engine runtime owns the generic
  endpoint identity/lifecycle values; the concrete sandbox-aware protocol,
  Unix-socket transport, client, and CLI are game-tooling adapters. The socket
  thread owns bytes and request/response handoff only. The graphical
  composition owns schema projection, owner translation, and producer-local
  correlation; it is not another mutation authority.
- Keep world instances distinct from durable `AssetId` content. Until EA1
  creates real durable asset identities, `content list` is truthfully empty and
  the runtime crate appears only in `world list`.
- Compile the server only into explicit editor/developer products. Editor-free,
  validation, shipping, and headless compositions remain endpoint-free unless
  a named acceptance product explicitly requests it.
- Do not expose shell execution, filesystem browsing, arbitrary properties,
  raw engine objects, remote listening, or multiplayer administration.

Acceptance: UI and CLI enter the same typed owners; revisions, outcomes, and
diagnostics remain exact and producer-correlated; a second local process can
discover, inspect, select, observe, relocate, reject stale work, undo/redo,
save, and capture evidence; editor-disabled/headless binaries retain their
cold boundaries. See the
[editor interaction and agent control plan](../../EDITOR_INTERACTION_AND_AGENT_CONTROL_PLAN.md)
and [EA0.5 validation ledger](../validation/ea0-5-local-developer-endpoint-and-canonical-cli.md).

### EA1 — Practical texture and material vertical slice

#### EA1-A — Import and runtime material

- Admit `.glb` and safely rooted `.gltf` dependencies.
- Support external and embedded PNG/JPEG source images.
- Preserve base-color factors with optional base-color textures.
- Preserve explicit sRGB/linear semantics, sampler state, UV set, dependency
  digests, provenance, and deterministic repeated cooking.
- Replace fixture-sized assumptions only with requirements measured by the
  accepted textured scene; report exact content pressure and fail explicitly.
- Give cooked materials stable game-owned asset identities resolved through a
  renderer-owned resource registry.
- Apply a real texture to one building/environment asset and one reusable
  object outside the district-only path.

#### EA1-B — Conventional material response and authoring

- Add metallic/roughness, normal, occlusion, and emissive inputs as separate
  typed material capabilities after EA1-A is accepted.
- Add Material Lab selection, inspect, preview, revert, and durable commit.
- Record selected material/texture identities, dimensions, formats, residency,
  dependencies, and last draw use in diagnostics/incidents.
- Provide a headless cook/validation command and a native Metal visual matrix.

Acceptance: a project-owned textured asset imports, cooks reproducibly,
relocates, renders with the expected material, can be reassigned live and
persisted, and remains diagnosable without the renderer loading source files.

KTX2/Basis compression, virtual texturing, bindless materials, shader graphs,
and hot asset streaming remain evidence-gated follow-ups.

### EA2 — Vehicle archetypes and live developer control

- Introduce stable game-owned `VehicleArchetypeId` and a versioned definition
  containing tuning plus chassis/wheel material and visual bindings.
- Carry archetype identity/digest through authority state, save, replay,
  replication, presentation, and incident evidence.
- Replace the current client-side default layout assumption recorded in
  A-F029 with admitted archetype data.
- Add Vehicle Lab selection and complete typed field metadata.
- Classify edits as live-safe or rebuild-required. Apply through the authority
  tick boundary; preserve pose, velocity, and occupancy only when the owner can
  prove the transition safe, otherwise reject with a typed reason.
- Extend the accepted EA0.5 endpoint schemas with vehicle-archetype inspection,
  live tuning, revert, commit, and measurement actions rather than creating a
  second transport or client path.
- Connect committed and candidate tuning to the existing vehicle-dynamics
  report/skill and scripted stopping, turning, slip, slalom, recovery, and
  rollover measurements.

Acceptance: UI and CLI/LLM paths perform the same revisioned transaction, stale
or invalid edits reject identically, replay/save identity remains exact, an
agent can change-test-measure-revert without private code knowledge, and all
solo/listen/dedicated authority placements agree.

### EA3 — Authored sun and point lighting

- Retain one renderer-neutral directional sun/environment light and make its
  game-owned preset editable.
- Add stable, placed point-light identities with position, color, intensity,
  range, enabled state, and explicit presentation-only ownership.
- Add Lighting Lab, selection, light gizmos/contribution overlay, preview,
  revisioned commit, undo/redo, and the same developer-control path.
- Include complete selected/global light state and draw correlation in incident
  evidence.
- Validate one daytime preset and one deliberately different evening/local-
  light scene on the native Metal product.

Acceptance: UI and agent clients can select, change, verify, persist, and revert
sun/point-light state; editor-disabled rendering consumes only cooked game
content; lighting cannot affect gameplay authority.

Shadows, cascades, clustered/deferred lighting, image-based lighting, fog, and
day/night gameplay authority remain separate measured decisions.

### EA4 — Game-owned map and construction workflow

- Define a versioned map asset containing stable placed-asset identities,
  transforms, layer membership, explicit collision/navigation/streaming
  metadata, light references, and game extension data.
- Move the current S15 layout out of hard-coded composition arrays only after
  the new cooked map reproduces its accepted logical and visual behavior.
- Add selection, transform gizmos, snapping, duplicate, multi-select, layer
  visibility, save, recook, and dirty/revision state.
- Add collision, navigation, streaming, support, and light overlays plus
  validation that prevents visual obstacles from lying about collision.
- Build a game-owned starter kit for ground, modular roads/sidewalks,
  intersections, building shells, props, and lights.
- Keep traffic/navigation graphs separate from road render meshes.
- Create an `incinerator-map-authoring` skill after the schema is accepted. It
  records coordinate/scale conventions, Blender/glTF preparation, provenance,
  placement, collision/navigation rules, cook commands, and validation.

Acceptance: a human and agent can create or alter one district without editing
Zig, deterministically cook it, inspect dependencies, run the product, verify
collision/navigation/streaming honesty, and reproduce an incident.

Procedural spline roads, terrain sculpting, interiors, vertical navigation,
crowd simulation, and collaborative source control remain pressure-driven
follow-ups.

### EA5 / G1 — Separately built game proof

- Build one separate game composition against explicit engine modules.
- Move title-owned material catalogs, vehicle archetypes, light presets, map
  data, urban kit, population, and gameplay policy behind that composition.
- Package engine defaults/diagnostic assets separately from game content.
- Record engine build, game build, engine content, and game content identities
  separately in save/replay/incident manifests.
- Produce clear macOS game, editor-game, headless-authority, validation-tool,
  and engine-test targets.
- Generate third-party notices and preserve the current no-license/no-license-
  grant state until the product owner chooses an engine license.
- Do not promise a stable plugin ABI, scripting ABI, or binary SDK.

Acceptance: a relocated installed game runs without repository-relative or
source-asset dependencies; engine tests build without game content; game,
headless, replay, incident, and editor-on/off products agree on their explicit
cohorts; no title policy is required by the reusable engine package.

## Scripting Decision Gate

After EA5, review concrete title needs. Keep Zig composition plus data assets if
missions, triggers, dialogue, or rapidly iterated behaviors have not created a
real scripting requirement.

If scripting is justified, write a separate ADR and one vertical gameplay
slice. The engine owns VM lifecycle and narrow capability bindings; the game
owns scripts. Authority and presentation capability sets remain separate.
Lua 5.4 is the first mature C-API candidate. WebAssembly is considered only
for a demonstrated untrusted-mod/sandbox requirement.

## Following Product Work

After EA5 and the scripting gate, the preferred product pressure slice is a
proposed **S16 traffic and ambient vehicle activity** phase. It should exercise
vehicle archetypes, road/map data, navigation, collision, authority,
replication, relevance, and incident evidence with a small authored cohort
before introducing a generic traffic or crowd framework.

MP7 private Internet/Steam-compatible routing, dedicated deployment, public
services, and MMO operations remain later separate programs.

## Program Acceptance Rules

- Stop after every phase for architecture, dead-code, doc-drift, and native
  human review.
- Preserve the accepted S15 gameplay journey as a regression surface.
- Add editor-on/off, headless, save/replay, incident, relocation, and source-
  package evidence proportional to each phase.
- Measure real content/resource pressure before changing a capacity. Never
  truncate or silently drop authored data.
- Keep Apple Silicon macOS as the only active platform.
- Keep neural rendering paused and conventional deterministic rendering active.
