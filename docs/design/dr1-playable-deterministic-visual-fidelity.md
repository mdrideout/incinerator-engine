# DR1 Playable Deterministic Visual Fidelity

**Status:** Accepted; DR1-A through DR1-G implementation, automated/native
acceptance, agent-native inspection, and product-owner walkthrough complete

**Active renderer:** Conventional SDL GPU / Metal

**Platform:** Apple Silicon macOS

**Paused adjacent work:**
[Neural Rendering Product-Track Pause](neural-rendering-pause.md)

**Roadmap:** [`OVERHAUL_PLAN.md`](../../OVERHAUL_PLAN.md)

**Baseline evidence:**
[Deterministic Rendering Resumption Audit](../validation/deterministic-rendering-resumption.md)

**Implementation evidence:**
[DR1 Validation Record](../validation/dr1-playable-deterministic-visual-fidelity.md)

## Decision

DR1 is the implemented deterministic-rendering slice. It improves the ordinary deterministic product
that people actually play and test. It does not promote, install, train, resume,
or redesign a learned renderer.

The phase is deliberately vertical: one better-lit, more legible sandbox world;
the existing character, vehicle, carry, navigation, population, combat, death,
and incident journeys; one native Metal presentation path; and evidence that
the result remains independent of neural artifacts.

“Deterministic rendering” means that authoritative state, presentation
extraction, visual identity, material selection, light selection, and draw
ordering are explicit engine data. It does not promise byte-identical pixels
across GPU drivers or operating-system releases. Gameplay and replay remain
semantically deterministic; graphical acceptance uses semantic visibility and
human images instead of pretending floating-point rasterization is a consensus
protocol.

## Why this phase exists

The current conventional renderer is functional and unusually observable for a
learning engine, but its two product geometry paths no longer express one
cohesive visual contract:

- vertex-color primitives accept a tint but have no normals or lighting;
- loaded `pos_normal_uv` geometry uses a hard-coded directional light and
  ambient term inside the fragment shader;
- the renderer-neutral sandbox visual catalog already describes character and
  vehicle parts and surfaces, but the conventional path currently reduces that
  intent mostly to flat color;
- debug geometry and product geometry share the primitive path even though they
  have different visual requirements;
- the incident system can prove draw membership and human-visible pixels, but
  it does not yet identify the conventional render contract, scene-light state,
  or material role that produced those pixels; and
- RF10 proved an optional experimental path, then paused. The default product
  now needs an explicit, measured conventional baseline so historical neural
  experiments cannot remain the de facto definition of “fidelity.”

These are concrete product pressures. DR1 does not use them as an excuse for a
generic render graph, shader graph, PBR framework, scene graph, or asset-system
rewrite.

## Ownership and separation of concerns

### Authority and gameplay features

Authority continues to own poses, vitals, interaction state, vehicle wheel
state, navigation, population intent, and durable identity. No lighting or
material choice may change collision, AI perception, hit validation, interest,
or replay truth.

### Presentation extraction

Feature presentation owns semantic visual identity and gameplay-readable state
such as alive, hit, dead, hostile, occupied, carried, and dropped. It emits
immutable draw facts; it does not call SDL or choose GPU resources.

### Sandbox composition

The sandbox owns title-specific visual policy:

- the scene-light values for the evaluation world;
- the mapping from `sandbox_visual_catalog.Surface` to a small conventional
  material description;
- the authored environment palette and obvious non-colliding decoration; and
- the visual arrangement of character and vehicle parts.

The existing `sandbox_visual_catalog.zig` and
`sandbox_visual_composition.zig` remain the appropriate home for that policy.

### Renderer

The renderer owns GPU resources, pipelines, passes, shader contracts, resize,
submission, and presentation. It accepts explicit light and material values; it
does not infer gameplay roles or import sandbox features.

### Developer and incident hosts

Developer UI owns inspection and overlay controls. Incident capture owns
immutable evidence about the selected render path, visual schema, scene light,
semantic draw membership, and resulting product images. Neither becomes a
second renderer owner.

## Small contracts, not a framework

DR1 begins with two plain values:

1. `SceneLight`: one normalized world-space sun direction, linear sun color and
   intensity, and linear ambient color.
2. `SurfaceMaterial`: linear base color, emissive contribution, and an explicit
   lit/unlit choice.

The exact names and packing may change during implementation after shader
reflection is checked. The important constraint is ownership: the sandbox
chooses title values, the renderer transports them, and the shader evaluates
them. Do not add metallic/roughness workflows, image-based lighting, clustered
lights, material inheritance, or a universal property bag until authored
content proves a need.

Product solid geometry should converge on the existing normal-bearing
`pos_normal_uv` path wherever practical, using the placeholder texture for
untextured materials. Add normal-bearing procedural shapes for the current
ground, character, vehicle, and visual parts instead of creating another vertex
layout merely to carry color. Keep debug lines, fills, grids, and gizmos on the
unlit vertex-color path so diagnostic colors remain exact and readable.

## Phase sequence

Implementation state:

| Phase | Result |
|---|---|
| DR1-A | Complete |
| DR1-B | Complete |
| DR1-C | Complete |
| DR1-D | Complete |
| DR1-E | Complete; the grounding gate omitted a shadow pass |
| DR1-F | Complete |
| DR1-G | Accepted; automated/native, agent-native, and product-owner acceptance complete |

### DR1-A — Conventional baseline and independence gate

- Launch the installed ordinary product with every `INCINERATOR_NR_*`
  environment variable removed.
- Record renderer selection, executable link dependencies, installed content,
  frame cadence, draw counts, and representative product-only screenshots.
- Exercise the S12/S13 navigation, population, vehicle, carry, combat, death,
  replacement, and incident journey.
- Verify no model path, model digest, experiment root, or learned output is
  required or selected.
- Record the dormant Core ML/shader build reachability from A-F061 separately;
  runtime independence and build exclusion are different claims.

Exit: an honest baseline exists and any pre-existing visual correctness defect
is repaired before fidelity work begins.

### DR1-B — One lit product-geometry path

- Add normal-bearing procedural versions of only the product shapes currently
  required by the sandbox.
- Move ground, environment solids, character parts, vehicle parts, wheels, and
  carryables to the normal-bearing material path.
- Keep physics/debug primitives unlit and behaviorally unchanged.
- Preserve semantic visual IDs, part ordinals, wheel transforms, state colors,
  and draw membership.
- Delete superseded product-only flat-shape code rather than retaining a
  compatibility fork.

Exit: product solids and loaded district geometry consume the same lighting
frame while debug colors remain exact.

### DR1-C — Explicit scene light and bounded material response

- Replace shader-local hard-coded lighting with the explicit scene-light
  contract.
- Map the existing surface vocabulary to base color, emissive response, and
  lit/unlit behavior in sandbox composition.
- Preserve hit/death overrides across every character part and make headlights
  visibly emissive without making them gameplay light sources.
- Validate normal transforms under rotation and non-uniform scale.
- Keep all shader buffer layouts reflected and tested.

Exit: lighting and material policy is visible in data, shared by product
geometry, and absent from authority.

### DR1-D — Evaluation-world visual composition

- Improve the existing two-district scene with a coherent road/sidewalk/ground
  palette, route landmarks, building massing, activity-slot landmarks, and
  readable traversal seams.
- Separate NPC silhouettes and role palettes enough for human testing without
  encoding role into physics or navigation.
- Keep decorative surfaces visually obvious as non-blocking. Any object that
  reads as a solid obstacle must use the existing authored collision/content
  boundary rather than becoming a visual lie.
- Keep spawn separation and the current open traversal contract.

Exit: a tester can orient, identify actors and activity areas, and understand
state changes without depending on debug overlays.

### DR1-E — Grounding decision gate

Review the lit DR1-D product at the fixed S12/S13 cameras. If geometry still
reads as floating or spatial ordering remains ambiguous, implement one bounded
directional shadow map owned by the renderer and driven by the same scene sun.
If the lit composition is already readable, record that result and omit the
shadow pass. Do not add cascades, temporal filters, ambient occlusion, fog, or a
general render graph in this phase.

This is a visual acceptance gate, not an arbitrary feature checklist.

### DR1-F — Render Lab and incident evidence

- Add a compact Render Lab readout for conventional renderer identity, visual
  schema, scene-light values, product/debug path counts, and selected semantic
  visual/material identity.
- Add independent overlays only where they answer a real question: product
  bounds, semantic part identity, light direction, and collision-versus-visual
  ownership.
- Record renderer mode, visual schema, scene-light values, draw-path counts,
  and stable semantic part/material IDs in incident state/timeline evidence.
- Preserve the current -5 through +2 second human-visible screenshot contract
  and product-only trail.
- Keep the records grep-friendly and feature-owned; do not add a telemetry bus.

Exit: a human can flag a visual anomaly and a fresh agent can identify which
state, part, material, light, draw path, and image corresponded to it.

### DR1-G — Native acceptance and cleanup

- Run focused renderer, shader reflection, resource lifecycle, composition,
  incident, and semantic visibility tests.
- Run the aggregate editor and editor-free suites, cold headless/network
  products, and installed native Metal smokes.
- Exercise solo, listen, and dedicated graphical acceptance at the already
  supported cadences where the existing scenario harness applies.
- Compare frame-time and memory evidence with DR1-A; explain observed changes
  instead of inventing a new limit.
- Run the ordinary-product human walkthrough and capture any anomaly through the
  normal incident workflow.
- Remove superseded product rendering code and update this plan, the validation
  ledger, architecture review, README, and overhaul roadmap together.

Exit: deterministic rendering is the accepted default product path, the full
gameplay journey remains readable and correct, and the source tree has one
clear owner for each new contract.

## Required gameplay walkthrough

The final product walkthrough includes:

1. walk and rotate the camera while checking character facing;
2. observe multiple resident, worker, and visitor activity transitions;
3. inspect a destination change, route, contention wait, displacement replan,
   and safe replacement;
4. enter, drive, steer, brake, exit, and re-enter the vehicle while checking
   wheel roll and steering transforms;
5. cross district seams without actor, vehicle, carryable, or environment pop;
6. collect, carry, drop, and recollect the object;
7. approach, fight, kill, observe death, cooldown, and replacement;
8. receive damage, die, remain visibly dead, respawn, and reacquire the player;
9. toggle the relevant Render Lab and existing navigation/population overlays;
   and
10. flag one UI and one keyboard incident, then inspect the resulting bundle.

Automation must drive these state transitions wherever the scenario system can
own them. Human acceptance remains necessary for legibility, motion quality,
camera feel, and surprising visual output; it does not replace the semantic
tests.

## Acceptance criteria

- The default installed product starts and completes its journey with no neural
  bundle, model, experiment directory, or neural environment variable.
- Authority, replay, persistence, network protocol, and collision digests do
  not change merely because lighting or material presentation changes.
- Product solid geometry uses one explicit lighting frame; debug geometry
  remains intentionally unlit.
- Alive, hit, hostile, dead, carried, dropped, occupied, and replacement states
  remain visibly distinguishable in product-only screenshots.
- Character facing, vehicle chassis, wheel roll, wheel steering, navigation
  overlays, and semantic part IDs remain correct.
- No authority-live actor, vehicle, carryable, or authored environment object
  disappears because of presentation selection or district traversal.
- Incident evidence identifies the conventional render contract and enough
  semantic visual state to diagnose an anomaly without giant console JSON.
- Native Metal, installed-content, editor-free, headless/network, replay, and
  S12/S13 regression gates pass.
- The validation ledger clearly separates automated semantic acceptance from
  product-owner visual acceptance.

## Explicit non-goals

- resuming neural rendering or modifying RF10;
- bitwise cross-driver pixel determinism;
- a generic PBR/material/shader/render-graph framework;
- deferred Windows, Linux, or SteamOS abstractions;
- a new scene graph, ECS rendering framework, or asset database;
- animation, skeletal meshes, motion matching, facial rendering, or cloth;
- multiple dynamic lights, cascaded shadows, post-processing stacks, temporal
  antialiasing, upscaling, ray tracing, or global illumination;
- changing gameplay dimensions, collision, AI perception, relevance, or
  authority to make visuals easier; or
- disguising a failed visual acceptance with debug overlays.

## Documentation and evidence

Implementation created
`docs/validation/dr1-playable-deterministic-visual-fidelity.md` and records:

- the clean-environment baseline command and renderer selection;
- before/after representative images from outside incident run folders;
- shader and uniform contract revisions;
- product geometry migrations and deleted superseded paths;
- automated command results and exact test counts;
- measured frame-time/memory changes;
- incident bundle paths used for anomaly diagnosis; and
- an explicit automated-versus-human acceptance table.

Historical neural plans remain historical. DR1 links to them only to explain the
pause and authority boundary; it does not edit their measurements or disposition.
