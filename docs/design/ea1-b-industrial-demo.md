# EA1-B Material Authoring and Industrial Demo

Status: implemented. See [validation](../validation/ea1-b-material-authoring.md).

The product owner authorized material authoring and an entirely new demo scene.
This supersedes the requirement to preserve the S15 scene, its dimensions,
layout, fixture capacities, and visual acceptance journey. Existing historical
evidence remains historical; new product evidence must exercise this scene.

## Product

Build an original industrial street, garage frontage, warehouse delivery yard,
and connecting alley at ordinary architectural and vehicle scale. Game-owned
geometry, material definitions, textures, collision, navigation, and spawn
placements replace the former evaluation world. Dimensions follow authored
geometry and usable travel routes rather than the former 16 m district cells.

## Ownership

The engine owns renderer-neutral material values, cooked formats, GPU binding,
and reusable authoring/preview machinery. The game owns named materials,
textures, meshes, surface assignments, and the industrial scene. The existing
typed local CLI and UI share a concrete material owner. No generic property bus
or second mutation authority is introduced. The source remains in one repository;
EA5's independently built game remains a later explicit proof.

## Delivery and acceptance

- [x] Reusable material values and full base-color, metallic/roughness, normal,
  occlusion, and emissive cook/render path.
- [x] Canonical game-owned material definitions, stable identities, explicit
  mesh assignment, and deterministic cooking/reimport ownership.
- [x] One revisioned owner for inspect, preview, apply, revert, and durable
  commit; shared UI and CLI journey with restart evidence.
- [x] Material Lab with neutral preview and correlated in-world presentation.
- [x] Fresh industrial geometry/materials and matching logical scene,
  navigation, spawns, content manifests, and installed product.
- [x] Focused contract/owner tests, editor-on/off and headless build gates,
  installed native Metal visual and authoring acceptance, and current docs.

Material controls edit a retained draft. A visible UI press owns its full drag
and release through the existing synchronous ImGui routing. Preview is
disposable presentation; Apply updates the material owner's session revision;
Commit durably writes game content. Escape ends an active control edit before
application menu routing. Focus loss ends transient capture; selection/panel
closure clears its disposable preview while retaining explicitly owned drafts.
External edits never silently overwrite a dirty UI draft. Both clients reject
stale revisions and report the actual terminal disposition.

Neural rendering remains paused. Vehicle archetype authoring, point-light
authoring, general map construction, and independent game packaging retain
their later EA2–EA5 ownership; this phase replaces the concrete demo data and
implements the material workflow they will consume.

## Concrete game source

`game/industrial/generate.py` emits original GLBs and matching collision data.
The initial neighborhood spans 128 × 128 metres across four streaming cells;
that is authored geography, not a world-size cap. Streets are 12 metres wide
with 2.6-metre sidewalks. The cells contain industrial building shells,
shutters, windows, yards, markings, and lamps. The shared generated dimensions
also drive collision. Twelve navigation nodes per cell connect the sidewalks
and street seams; twenty-four destinations and sixteen passive population
members use the new layout.

The generated scene defines the composition's spatial representation. CPU
scene uploads and resident mesh/material/texture/instance tables allocate from
actual content. This phase does not introduce an open-world streaming system,
traffic, interiors, vehicle archetypes, point lights, or general map editing.

`materials.icmat` is the canonical material and binding asset. Generation seeds
it only if absent; subsequent geometry/texture generation preserves every
saved authoring change. Names determine stable IDs. Renaming/removing authored
assets requires coordinating their definitions and bindings; runtime admission
rejects dangling references rather than substituting a legacy scene.

## Material rendering

The opaque, single-sided UV0 path evaluates base color, packed metallic/roughness,
normal, occlusion, and emission. Color maps use sRGB views; data maps use linear
views. A source texture used in both roles gets one shared-pixel linear view,
reused across materials. Generated Metal shaders preserve declared binding
indices. The UNORM output applies linear-to-sRGB encoding.
GPU textures generate full mip chains for minification; residency accounts for
their texel storage separately from the base-level upload payload.

Material Lab uses the same shader and maps on a neutral cube and in the game.
Metallic and roughness controls multiply their maps. Physical factor domains
are validated; emission and normal strength have no arbitrary authoring ceiling.
Transparency, additional UV sets, shader graphs, image-based lighting, and
shadows are not supplied by this slice. The street is a functional art and
architecture foundation; EA3 will supply the next lighting improvements.
