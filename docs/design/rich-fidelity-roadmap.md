# Rich Fidelity Roadmap

**Status:** RF0 through RF5 accepted; RF6 and RF7 retained as historical
evidence; RF8 direct `160×90 → 640×360` spatial-sharpness/live-presentation
trial accepted externally and unpromoted; RF9 historical; RF10 native
`256×144 → 1280×720` trial accepted as the external, unpromoted stopping point;
implementation paused indefinitely

**Date:** 2026-08-17

**Track status:**
[Neural Rendering Product-Track Pause](neural-rendering-pause.md)

**Neural-rendering direction:**
[Title Neural Renderer North Star](title-neural-renderer-north-star.md)

**Implementation plan:**
[Title Neural Renderer Implementation Plan](title-neural-renderer-implementation-plan.md)

**Architectural boundaries:**
[ADR-025](../adr/025-game-specific-neural-rendering-boundary.md) and
[ADR-026](../adr/026-from-scratch-title-neural-renderer.md)

## Decision

This roadmap is retained as historical rationale and evidence. It does not
authorize more implementation while the neural-rendering track is paused.
Deterministic rendering is the active product focus.

Incinerator will treat richer visual content as a dedicated **RF** product
track. It is not NR5-F, an incidental target-fixture improvement, or a reason
to begin NR6 temporal modeling.

The track starts by improving the real default sandbox with a small,
well-owned visual vocabulary:

- readable T-shaped player and NPC avatars assembled from simple parts;
- a basic but recognizable vehicle assembled from chassis, cabin, wheels,
  windows, and lights;
- a small built-environment kit for roads, sidewalks, walls, building faces,
  doors, windows, roofs, and a few props; and
- basic repository-owned textures and material assignments for surfaces such
  as asphalt, concrete, masonry, painted metal, rubber, glass, and fabric.

These visuals remain intentionally modest. Their job is to make the sandbox
legible and give the high-fidelity target renderer enough deterministic
structure, surface identity, and material intent to produce a substantially
nicer aligned target. The title renderer can then learn the declared
`160×90` cheap input to direct native `400×225` rich-target transformation.

## Historical rationale for the RF track

NR5-E proves the complete interactive path, but only for a narrow procedural
fixture. Adding history now would optimize temporal behavior around a visual
vocabulary that is still too primitive to represent the desired game. Richer
content changes the more important questions first:

- Does the cheap renderer preserve enough silhouette and part structure?
- Which surface and material facts must be explicit inputs?
- Can one title-trained spatial model learn meaningful differences in texture,
  material response, lighting, and local detail?
- Which failures come from insufficient deterministic conditioning rather than
  missing temporal history?

At that point NR6 was authorized by the NR5 result but deliberately deferred
until richer spatial mapping passed. This rationale led through RF10; it does
not authorize NR6 now that the product track is paused.

## Resolution and training truth

The default product window may continue to render conventionally at its normal
display extent for human play and debugging. Those pixels are not training
truth.

The currently implemented RF9 paired-training contract is `160×90 →
640×360`. The next clean RF10 cohort is:

```text
same immutable presentation event
  ├─ cheap profile: 256×144 deterministic neural inputs
  └─ rich profile: 1280×720 direct native high-fidelity target
```

- No earlier RF pixel is a target, source, intermediate, or art-direction
  reference for this cohort.
- No larger or smaller frame is resampled to create a `1280×720` target.
- The low and high profiles share the same camera, transforms, visibility,
  stable object/part identities, and gameplay state.
- The rich profile may add deterministic material, lighting, and declared
  geometric detail. It may not invent objects, poses, events, or visibility.
- If richer geometry cannot be inferred from the cheap silhouette and explicit
  controls, the missing fact is added to presentation data or the target is
  rejected; instance identity must not become an accidental material lookup.

## Architectural ownership

The implementation extends existing seams rather than creating a parallel
object or scene system.

| Owner | Existing seam | Rich-fidelity responsibility |
|---|---|---|
| Sandbox composition | `src/sandbox/district_recipe.zig` and sandbox population/presentation policy | Choose which stable visual roles appear in the default scene; retain gameplay, collision, navigation, and spawn truth |
| Renderer-neutral identity | `src/engine/contracts/rendering.zig` | Carry typed mesh, material, and scene handles without exposing GPU resources or art policy to simulation |
| Product visual catalog | `src/sandbox_visual_resources.zig` | Resolve the small explicit sandbox mesh/material vocabulary and own its GPU lifetime |
| Built-in geometry | `src/primitives.zig` and `src/mesh.zig` | Create the bounded simple mesh parts required by the first catalog |
| Streamed district content | `src/content/`, `src/district_scene_adapter.zig`, and district GPU ownership | Preserve authored district nodes, primitives, materials, textures, and instances where the existing streamed-content path is the real consumer |
| Conventional renderer | `src/renderer.zig` | Draw resolved mesh and material inputs; remain a renderer, not a scene/catalog orchestrator |
| Neural input host | `src/hosts/neural_input_host.zig` | Rasterize the exact cheap profile from immutable presentation records |
| Offline target adapter | `tools/neural-rendering/targets/blender/` | Resolve the same stable visual/material intent into the direct native rich target and evidence passes |
| Neural runtime | `src/hosts/neural_rendering_host.zig` | Evaluate an explicitly supplied model and preserve comparison/fallback/diagnostics; never own content authoring |

Collision geometry and visual geometry remain separate. Improving an avatar,
vehicle, wall, or building must not silently change authority collision or
navigation. The sandbox composition selects stable visual roles; it does not
create renderer objects directly.

## Deliberate scope boundary

This track does **not** build:

- a generic scene graph or universal entity-component rendering framework;
- a runtime asset browser, visual editor, prefab system, or DCC interchange
  layer;
- an arbitrary shader graph or general physically based material authoring
  suite;
- a broad model importer or automated asset-processing pipeline without a real
  title asset that requires it;
- multiple interchangeable rendering backends;
- final production art, animation, skinning, crowds, vegetation, weather, or a
  complete city kit; or
- neural temporal history merely because moving sequences are captured.

The first implementation uses an explicit catalog and small repository-owned
assets. A new abstraction is extracted only when a second real visual kind
proves the shared contract.

## Fidelity-kind vertical slice

Each new fidelity kind follows the same complete path:

```text
authored intent
  → default sandbox composition
  → cheap deterministic representation
  → rich deterministic target representation
  → exact paired capture
  → target review and correspondence audit
  → RF6 cumulative spatial training and ablation
  → accepted, revised, or rejected conclusion
```

This prevents an art-side backlog from growing independently of the data and
model contracts. It also lets the project add kinds incrementally without
building a full scene-authoring system in advance.

## Roadmap

| Phase | Status | Accepted evidence |
|---|---|---|
| RF0 | **Complete** | Shared bounded catalog; multipart T-shaped people and vehicle; Metal vehicle, combat, population, and streamed-district acceptance |
| RF1 | **Complete** | One 49-draw immutable event produces native `160×90` cheap inputs and direct native `400×225` targets with stable identity and exact camera/transform ownership |
| RF2 | **Complete** | Asphalt, sidewalk, masonry, roof, glass, door, trim, prop, and procedural surface responses are explicit and visually reviewed |
| RF3 | **Complete** | Player and NPC fabric/skin/facing parts share stable entity identity and preserve readable role/combat state in the product host |
| RF4 | **Complete** | Multipart metal/glass/emissive vehicle and four independently articulated wheels pass exact sequence and product vehicle acceptance |
| RF5 | **Accepted** | Explicit sun, world, local-light, and four-surface emissive response passes the six-segment causal sequence; product-owner target approval recorded 2026-08-10 |
| RF6 | **Technical complete; superseded by RF7 resolution decision** | Fresh 108-pair corpus; random-origin controlled and held-out training; validation-only selection; one test opening; fresh stress; exact export; 48-frame live Core ML/Metal trial; no promotion |
| RF7 | **Accepted external live trial; unpromoted** | 108 fresh direct native `160×90 → 800×450` pairs; one learned 5× model; validation-only selection; one test opening; stress; exact Core ML export; 48/48 live predictions; no `400×225` stage |
| RF8 | **Accepted external live trial; unpromoted** | 108 fresh direct native `160×90 → 640×360` pairs; uniform 4× mapping; native-grid refinement and sharpness-aware validation selection; single-open test and stress pass; exact Core ML export; 48/48 Metal predictions; centered unscaled main presentation with black surround; no `400×225` or `800×450` pixels |
| RF9 | **Complete external technical trial; unpromoted** | 306 fresh `160×90 → 640×360` pairs; material-palette conditioning accepted; more complex reconstruction/capacity/detail candidates rejected; sealed test, held stress, export, and live Metal trial pass |
| RF10 | **Complete; retained external, unpromoted stopping point** | 306 fresh direct native `256×144 → 1280×720` pairs plus 54 newly manufactured post-selection stress frames; exact 5× mapping; 1,062,587-parameter random-origin model; validation-only epoch-110 selection; single-open test; exact Core ML export; 48/48 Metal predictions; native centered 720p presentation; no intermediate rendered image |

### RF0 — Sandbox visual foundation

Build the modestly higher-fidelity conventional scene that every later kind
uses.

#### RF0-A — Catalog and contracts

- Inventory the current crate, capsule, chassis, wheel, static-box, and
  district-scene paths.
- Define the smallest explicit catalog of visual roles and stable part/material
  identities needed by the default sandbox.
- Keep product composition, resource lifetime, renderer submission, collision,
  and neural semantics independently owned.
- Add no generic loading or authoring abstraction without a concrete asset
  consumer.

**Review gate:** ownership is documented and contract tests prove that stale or
mismatched mesh/material handles fail visibly.

#### RF0-B — Character and NPC mesh kit

- Replace the capsule-only product presentation with a recognizable T-shaped
  avatar made from a torso, head, shoulder/arm bar, and simple lower-body parts.
- Preserve the authority-owned capsule and existing movement/combat dimensions.
- Give each character one stable entity identity plus stable semantic part and
  material identities suitable for incident and neural evidence.
- Retain clear player/NPC, role, hostility, hit, death, cooldown, and respawn
  visual states.

**Review gate:** player and NPC silhouettes, facing, movement, hostility, and
death remain readable in graphical and retained incident evidence.

#### RF0-C — Vehicle mesh kit

- Replace the cube-only chassis presentation with an explicit chassis, cabin,
  windows, lights, and four existing articulated wheels.
- Preserve vehicle physics, entry/exit, wheel steering, and wheel rotation as
  authority/presentation facts rather than deriving them from the mesh.
- Maintain one stable vehicle identity and stable part identities for chassis,
  cabin, wheels, windows, and lights.

**Review gate:** enter, drive, brake, steer, exit, re-enter, collide, and cross
district boundaries without visual/physics divergence or lost part identity.

#### RF0-D — Built environment and basic materials

- Add a small reusable kit for ground, road, sidewalk, wall/building face,
  corner, door, window, roof, and selected prop surfaces.
- Add only the texture sampling and material records required by those real
  assets; start with repository-owned small textures and explicit mappings.
- Use the existing district recipe/content path for world placement. Do not
  create a second training-only map or parallel scene format.
- Keep navigation and collision proxies deliberate and independently visible
  in debug tools.

**Review gate:** the two-district sandbox is spatially readable, materials do
not swim or change identity, streamed presentation remains complete, and
collision/navigation truth still matches its debug evidence.

#### RF0-E — Default-scene acceptance

- Exercise the complete playable sandbox in conventional mode on macOS.
- Capture stable semantic/part/material identities, missing-resource failures,
  presentation membership, district transitions, and screenshots in incident
  evidence.
- Record screenshots from representative near, middle, far, elevated, vehicle,
  combat, carryable, and population views.
- Audit `src/main.zig`, the resource catalog, and renderer responsibilities for
  accidental orchestration growth before closing the phase.

**Exit:** the actual default scene—not only an offline fixture—is more legible
and useful while remaining small, explicit, and architecturally clean.

### RF1 — Exact cheap/rich presentation profiles

- Export one immutable engine-submitted RF evaluation event through two
  explicit profiles. It uses the same bounded catalog as the default sandbox;
  it does not pretend to be a live gameplay capture.
- Render native `160×90` cheap inputs using the low-cost material/shading
  profile.
- Render the corresponding direct native `400×225` rich target using declared
  target materials, textures, lighting, and supported detail.
- Prove camera, object, part, material, transform, pose, and visibility
  correspondence across the profiles.
- Produce the human review layout: cheap input, deterministic resize, current
  model output when applicable, rich target, and diagnostic controls.

**Exit:** the engine can manufacture exact low/high pairs from its real input
host and shared catalog without using normal-window pixels. Extending target
provenance to arbitrary live district/gameplay events remains RF6 corpus work,
not an RF1 completion claim.

### RF2 — Environment and surface richness

- Expand asphalt, sidewalk, masonry, wall, roof, window, door, and prop target
  responses one material family at a time.
- Include material swaps, repeated materials on different instances, repeated
  geometry with different materials, camera distance/angle changes, and
  lighting variation.
- Audit whether material identity, surface coordinates, or compact material
  properties are required. Add a channel/control only after an ablation proves
  current inputs ambiguous.
- Manufacture and review exact pairs for every declared surface family. Do not
  begin cumulative training before the RF5 human target gate.

**Exit:** environmental target truth is explicit, aligned, and ready to test
for structural substitution, instance memorization, and texture instability in
RF6.

### RF3 — Character and NPC richness

- Add bounded target treatments for clothing, skin, role distinction,
  hostility, damage, death, and respawn while preserving T-shaped authored
  structure and exact pose/state.
- Capture different identities sharing materials and one identity changing
  declared state so identity cannot substitute for appearance intent.
- Evaluate paired target truth at near, far, partial occlusion, crowd overlap,
  motion, and state transitions before cumulative training.

**Exit:** character target truth is visually richer while entity, role, pose,
and gameplay state remain faithful and debuggable.

### RF4 — Vehicle richness

- Add bounded target treatments for painted bodywork, windows, rubber, lights,
  trim, damage-state cues, and wheel articulation.
- Capture camera, steering, wheel-spin, occupancy, collision, occlusion, and
  repeated-vehicle/material variants.
- Evaluate stable part identity, reflections, thin/high-contrast edges, and
  district transitions in exact pairs before cumulative training.

**Exit:** vehicle target truth gains material and lighting richness without
changing its authored silhouette, articulation, occupancy, or authority state.

### RF5 — Lighting and local-effect richness

- Expand deterministic sun/world/local-light states and a small number of
  explicitly phased presentation effects only after their state is exportable.
- Capture controlled combinations rather than asking the eventual model to
  infer hidden lighting state.
- Evaluate shadows, emissive response, reflections, exposure changes, and
  effect boundaries against exact targets.

**Exit:** lighting/effect richness is responsive to explicit controls and does
not repaint geometry or identity.

### RF6 — Cumulative rich spatial conclusion

- Assemble a whole-sequence corpus across every accepted fidelity kind with
  train/validation/test ownership fixed before selection.
- Train the best justified spatial architecture from random initialization;
  compare it with NR5-E, deterministic resize, and current-input ablations.
- Inspect complete visual evidence and stress near/far views, occlusion,
  material swaps, characters, vehicles, district transitions, and lighting
  changes.
- Export an external unpromoted macOS trial and exercise it in the Neural Input
  / Output window with fallback, lineage, timing, and incident evidence.

**Exit:** a materially richer spatial candidate works against the real
sandbox vocabulary. Only then does NR6 begin the temporal-history audit and
implementation. RF6 acceptance does not promote or install a model.

## Validation strategy

Every RF phase closes with evidence at four distinct boundaries:

| Boundary | Required evidence |
|---|---|
| Product visuals | Graphical walkthrough, representative retained screenshots, missing-resource behavior, and conventional fallback readability |
| Gameplay separation | Authority/replay equivalence, unchanged collision/navigation behavior, vehicle articulation, population state, and district lifecycle |
| Pair correctness | Exact event/camera/transform/visibility/identity correspondence, target provenance, native extents, and complete visual reports |
| Model behavior (RF6) | Random-origin lineage, held-out selection, deterministic baselines, input ablations, complete per-kind review, export agreement, and live incident evidence |

Moving captures begin with RF1 because they expose correspondence and
responsiveness failures. They do not authorize a recurrent model. During RF0
through RF5, retain motion evidence but do not train. RF6 trains the cumulative
spatial mapping after human target approval. NR6 later answers the separate
question of whether explicit history improves the accepted rich scene.

## RF6 execution sequence

1. **RF6-A — Authorization:** retain the accepted RF5 disposition, native
   extent contract, whole-sequence split policy, random-origin rule, and
   external-unpromoted boundary.
2. **RF6-B — Generalized pairing:** exercise the shared sandbox catalog through
   the playable neural fixture and six distinct deterministic camera programs;
   target truth remains an offline adapter result for the same presentation
   event.
3. **RF6-C — Corpus:** manufacture fresh overfit, train, validation, sealed
   test, and stress sequences; audit every native pair and publish no test
   pixels in review evidence.
4. **RF6-D — Training:** first prove controlled fit, then train a fresh
   random-initialized spatial candidate and select it on validation only.
5. **RF6-E — Conclusion:** open test once, prove reopen rejection, run a fresh
   stress cohort, evaluate all branches and baselines, and verify export
   agreement.
6. **RF6-F — Playable trial:** create an explicit external Core ML trial and
   exercise the exact live fixture through the Neural Input / Output window,
   fallback, diagnostics, and incident evidence.

The established NR4 corpus and NR5 title-renderer tools remain the historical component
owners beneath this campaign. RF6 creates new data, initialization, checkpoint,
evaluation, and trial evidence; it never reuses earlier target pixels or model
weights. No further neural phase is authorized while the product track is
paused.

All six RF6 implementation stages passed. Exact roots, metrics, visual findings,
and the interactive command are recorded in
[RF6 validation](../validation/rf6-cumulative-rich-spatial.md). Later RF7 through
RF10 cohorts superseded its product-review question. RF10 is the retained
stopping point; all candidates remain external and unpromoted.
