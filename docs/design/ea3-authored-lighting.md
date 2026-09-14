# EA3 — Authored lighting for the industrial game

**Status:** Implemented 2026-09-13/14. The [EA3 validation and running guide](../validation/ea3-authored-lighting.md)
records the implementation, native evidence, measured costs and remaining visual
review. The source-review baseline below is retained to explain the decisions;
its proposed steps now have working implementations.

The [performance research](ea3-lighting-performance-research.md) informed the
Metal buffer/depth-array ABI, pre-exposed HDR and reduced-resolution bloom.
The initial global forward light loop remains: measured street cost does not
justify clustered assignment or shadow caching in this milestone.

**Owners:** [ADR-029](../adr/029-engine-game-authoring-boundary.md), with
[ADR-030](../adr/030-editor-input-routing-and-interaction-capture.md) governing
selection, gizmos and capture. The [parent plan](engine-authoring-foundation.md)
remains the EA0–EA5 program. EA4 map editing and EA5 packaging retain their own
milestones.

## 1. Outcome and review conclusion

An author can build, inspect, adjust, switch, save and reproduce a daytime or
night-time industrial street containing sunlight, lamp posts, street lights,
neon, a backlit shop sign, an externally illuminated sign, a lit shop interior
visible through its window, and moving vehicle headlights. Those examples must
illuminate the actual materials and geometry around them. A bright texture
alone does not prove a working light.

The original sun-plus-point-light outline has sound ownership but does not
cover the requested examples. Expand the proposed EA3 scope to include:

1. Directional, point and spot lights, including moving parent attachments.
2. Separate visible emission, direct illumination and image bloom.
3. A linear HDR scene with explicit exposure, tone mapping and restrained bloom.
4. Direct-light shadows for opaque occluders, including moving vehicles.
5. One real shop opening/interior instead of a window rectangle on a solid box.
6. Stable fixture/member identity, shared UI/CLI authoring, precise presentation
   evidence and streaming lifetime rules.

HDR and direct shadows are recommended additions to the previous outline,
which deferred shadows. They follow directly from the neon, shop and headlight
brief; this is not a proposal for a general render graph, global illumination
or a new renderer. Start with one complete example and extend it in order.

## 2. Source baseline before EA3 implementation

| Current source | Finding | Consequence for EA3 |
| --- | --- | --- |
| `src/render_contract.zig`, `src/sandbox_visual_catalog.zig`, `src/main.zig` | One sun/ambient value is installed at startup; no conventional authored local-light list | Add a lighting asset and presentation owner rather than more startup constants |
| `shaders/model.frag` | World-space PBR material response evaluates one sun; emission is additive surface color | Reuse the material response for local lights; emission must remain distinct from illumination |
| `src/engine/contracts/material.zig` | Emission already accepts finite values above one | Keep that useful domain; do not invent another material brightness ceiling |
| `src/renderer.zig` | Product color uses the display format, shaders encode display color, and scene resolve is a blit | Introduce HDR shading and one display transform; updating only the light loop would still clip bright signs |
| `shaders/triangle.*`, `Renderer.drawMeshWithTextures` | Vertex-color primitives use a separate unlit color path | Include product primitives in the lighting decision; people/props must not stay artificially bright at night |
| `src/material_preview.zig` | Material preview borrows a renderer context and renders directly into a display-format target | Adapt preview with the product color pipeline while preserving its independent neutral environment |
| `game/industrial/generate.py` | Building shells are solid boxes; windows and lamp faces are surface boxes | Make one shallow shop with a real opening, opaque walls and overhead fixtures |
| `src/main.zig` vehicle presentation | Chassis and wheels use interpolated presentation poses | Headlight transforms must use the same chassis pose, not a second physics read or unsmoothed snapshot |
| `src/hosts/material_authoring*`, `src/engine/contracts/authoring.zig` | Typed owners, asset/member identities, previews, revisions and persistence already exist | Follow those contracts; add a concrete lighting owner, not a property bus |
| District presentation/streaming hosts | Logical relevance and retained visual residency are distinct | Lighting and shadow casters must follow contributing visual content, not just simulation district membership |

The active GLSL shaders, conventional renderer, content generator and authoring
owners were inspected for this review. Historical neural experiment light
fields are not product lighting and are not a reuse requirement. Neural
rendering remains paused.

## 3. Demonstration and acceptance matrix

Build these examples into the existing industrial neighborhood and adjacent
vehicle road. Keep the current driving route usable. Lighting additions do not
require an EA4 map editor or another scene replacement.

| Example | Visible fixture | Illumination and behavior | Acceptance proof |
| --- | --- | --- | --- |
| Daylight | Sun/environment preset | Directional sun, ambient fill, matching background and exposure; opaque shadows | Rotate sun; shadow and diffuse/specular response move coherently; save/restart reproduces preset |
| Pedestrian lamp post | Pole, bulb/globe and luminaire housing | Warm point light; emission on the bulb; occlusion by nearby geometry | Pavement/character/prop responds; moving a blocker changes the light contribution |
| Road street lights | Roadside poles with overhead lamp heads | Downward spots with soft cone edges and distance falloff | Pools overlap smoothly; road beyond range is unaffected; no change when the emitter leaves the camera view but still lights the road |
| Neon sign | Original emissive lettering/tubes | Colored surface emission plus explicitly authored local spill lights; bloom | Text remains recognizable; nearby wall/pavement receives colored light; emission, spill and bloom can be isolated independently |
| Illuminated store sign | Backlit sign panel | Emissive graphic and modest authored spill | Readable from the street at night without a white rectangle or oversized halo |
| Externally lit sign / loading-bay floodlight | Ordinary non-emissive sign and separate lamp | An aimed spot lights the sign and loading area | Switching the lamp off removes direct illumination; the sign does not glow by itself |
| Shop window and overhead lighting | Real window frame/opening, shallow room, ceiling luminaires, a few display surfaces | Wide overhead spots or points illuminate the interior; direct rays passing the aperture illuminate the outside | Window frame/walls mask the light; block the opening and exterior direct spill disappears; see lit interior surfaces through the opening |
| Vehicle headlights | Left/right lamp faces for each of the three vehicle profiles | Two chassis-attached spots plus lamp-face emission | Beams follow translation, turning and suspension smoothly; a wall/car blocks them; disappear with the parent and survive valid asset reloads |
| Portable work lamp | Lamp using an existing carryable's presentation pose | Same local-light capability on a second moving parent type | Collect/drop/move the existing object; light remains aligned without vehicle-specific engine logic |

The portable work lamp is a proposed additional example using existing carry
mechanics. It adds no new gameplay system. A decorative fixture may contain
more than one emitter; its emitter count is authored and inspectable, not a
hidden hard-coded shader trick.

### Shop geometry and glass

Replace one solid facade portion with modeled walls around a window opening,
a floor, ceiling and shallow interior. Update that object's collision together
with geometry; surrounding navigation and road access remain valid. Position
actual overhead emitters so their direct rays can pass through the aperture.
Do not fake window spill with an unexplained light outside the wall.

A clear/open aperture is sufficient for the first lighting proof. An optional
visible pane needs a declared thin transparent material and correct draw order;
the current opaque pipeline does not supply that automatically. Refraction,
colored transmission, caustics and general explorable interiors are not required
by this EA3 lighting proof. Do not present direct spill as simulated bounce
lighting or claim glass transport without implementing and testing it.

## 4. Light and presentation contracts

### Units, direction and falloff

Use metres, linear RGB, directional illuminance in lux, and point/spot luminous
intensity in candela. Store cone half-angles in radians; show degrees with a
clear half-angle label in tools. Point lights use inverse-square attenuation;
spots also have a smooth inner-to-outer cone transition. These conventions align
with [KHR_lights_punctual](https://github.com/KhronosGroup/glTF/blob/main/extensions/2.0/Khronos/KHR_lights_punctual/README.md).
This adopts useful semantics; glTF light import is not automatically part of EA3.

Use a documented emitted-ray direction for sun/spot contracts. The existing
`sun_direction` is surface-to-sun, so conversion must be explicit rather than
silently reversing the old convention. Attached emitters use local -Z as forward
and +Y as up. Directional lights ignore position; point lights ignore rotation.
Nonuniform visual scaling does not multiply intensity or silently change range.

Keep a light's optional distance cutoff separate from its brightness and any
numerical near-source regularization. An omitted cutoff is unbounded and is
never culled by an invented radius. Authored finite cutoffs fade continuously.
If a source radius is exposed, document its actual attenuation/softness effect;
do not advertise physical area-light shadows from a punctual implementation.

Validate finite nonnegative energy, valid poses/directions and ordered cones.
Expose field units, descriptions and mutability through the same typed metadata
as other authoring features. No arbitrary maximum brightness, light count or
shader-array truncation. GPU/device allocation limits produce explicit evidence.

### Fixtures, assets and attachments

Proposed concrete data boundaries, finalized before encoding in EA3-0:

- A versioned lighting library owns environment presets and stable fixture/light
  members. Industrial instances live in `game/industrial/lighting.iclight`.
- A fixture references existing mesh/material identities and owns local emitter
  poses, emitter values, a power/enabled state and optional emissive-part scales.
  It does not copy material definitions into a second mutable material store.
- A game-owned vehicle lighting library maps vehicle archetype IDs to headlight
  rigs. Keep visual light rigs separate from physics tuning/reconstruction.
- Static placement and attachment are explicit alternatives. A moving attachment
  resolves a stable presentation parent and a local pose in metres. Engine code
  receives a resolved pose; game composition supplies vehicle/carryable meaning.
- Identity is asset + member for authored lights, and parent instance/incarnation
  + rig member for dynamic instances. Storage positions, draw indices and labels
  never identify editable lights.

World rig editing does not introduce a general scene graph or prefab framework.
EA4 may reference these stable fixtures when its map schema arrives. Fixture
assets and placements remain distinct so two lamp posts can share a definition
without one placement edit moving both.

A fixture's power change must turn off its local contribution and its visible
emission in the same presented frame. Implement emission scaling as a typed
per-instance presentation override over the existing material, not a mutation
of a shared material asset. Material Lab remains the material authoring owner.
Keep surface brightness and illumination intensity separately inspectable; one
undocumented multiplier must not couple their tuning.

Use the exact presented chassis root pose for vehicle rigs, with authored local
lamp offsets for each body style. Preserve asset/member identity across vehicle
physics reconstruction; suppress/remove a light when its parent incarnation or
required visual content is absent. Test scene unload, exit/entry, respawn,
reconnect, archetype change and preview cleanup as applicable to those owners.

For EA3, the game preset enables headlights in evening/night scenes; Lighting
Lab can inspect and override them. No new player shortcut or replicated lighting
switch is assumed. Player-controlled switches, traffic rules and gameplay
visibility effects would require separate gameplay state, not renderer reads.

### Environment and color pipeline

Proposed frame order:

1. Resolve one immutable presentation frame: product draws, transforms,
   materials, light instances, environment/exposure and selected shadow casters.
2. Render shadow depth views from that same frame.
3. Shade opaque product geometry into linear HDR color.
4. Draw any explicitly supported transparent fixture detail in linear HDR.
5. Apply bloom, fixed authored exposure and one tone/display transform.
6. Composite editor/UI and exact diagnostic/semantic paths in their proper
   separate passes; submit with the existing fence/resource lifetime owner.

Start with a supported floating-point scene target, explicit manual exposure,
one documented tone operator and bloom with an off switch. Pre-expose or use an
appropriate precision so bright inputs cannot silently overflow the target.
If exposure is incorporated during shading, the display transform must not
apply it a second time; capture records the exact convention.
Query SDL format/type/usage support on the pinned Metal backend rather than
assuming it from a format name. [SDL format capability query](https://wiki.libsdl.org/SDL3/SDL_GPUTextureSupportsFormat).

The current model shader encodes display color; that encoding moves to the final
display pass. Make clear/background colors and unlit product materials follow
the same declared color space. UI colors must not change with world exposure.
The displayed product capture and offscreen product capture must pass through
the same resolve even when there is no swapchain. If raw HDR is captured, name
it distinctly and record exposure/tone settings alongside it. Preserve existing
semantic-ID correctness and product-only versus editor-inclusive captures.

Reuse the PBR direct-light evaluation for all light types. Give lit vertex-color
product primitives a valid world-space normal/position path; keep actual debug
geometry and explicitly unlit materials separate. Port the neutral Material Lab
preview to the same shading/display path with its own fixed environment.

Bloom supplies an optical halo, not light transport. A neon fixture uses real
local emitters for illumination. Analytic rectangle/tube lights and arbitrary
emissive-mesh lighting are later measured needs; authored punctual approximations
must be described honestly. This separation and the HDR/exposure approach are
informed by [Filament's lighting/color discussion](https://google.github.io/filament/main/filament.html).
Existing emissive values remain finite HDR RGB; introducing physical luminance
units requires a declared conversion, not relabeling existing numbers.

### Shadows, submission and streaming

Basic direct-light occlusion is part of the recommended expanded EA3 acceptance:
spot shadows for headlights/street/overhead lights, point-light shadows for
omnidirectional fixtures, and directional shadows for sun. Share opaque depth
submission and caster transforms; first prove one spot, then extend the same
path to point views and the directional view. Shadow enablement is explicit
per fixture. Unshadowed artistic fill must be labeled and cannot pass an
occlusion acceptance case.

The present renderer opens the color pass before receiving immediate draws.
Introduce a narrow frame draw description/collector so shadow and color passes
consume the same immutable geometry, materials, identities and transforms.
Do not separately reconstruct a shadow world in `main.zig` or build a general
render graph. Include resident district geometry, vehicles, carried props and
product actor meshes. Dynamic caster bounds must use the presented transforms.

Select contributors by light volume intersecting visible receivers, not by
whether the bulb is visible. Select casters in light space, including off-camera
objects that shadow visible receivers. An offscreen headlight or a lamp in an
adjacent visually retained district may still affect the scene. Light and caster
residency must not collapse back onto logical district interest.

Start with forward lighting and a growable frame light buffer;
[SDL fragment storage buffers](https://wiki.libsdl.org/SDL3/SDL_BindGPUFragmentStorageBuffers)
provide the transport capability. Prove its layout, stride and generated MSL
bindings: today's shader reflection tests do not validate storage buffers.
Use the initial global loop as a correctness reference. Conservative per-draw
light lists are the first practical street candidate; clustered forward is the
preferred scaling candidate if overlap or large meshes make those lists costly.
Measure list construction/upload as well as shading. CPU-built lists can use
the same indexed transport; compute construction is not an automatic first step.
Record submitted/culled identities with reasons. Never silently keep only the
nearest N lights or truncate a cluster's list.

Prove multi-shadow binding in EA3-2. SDL's declared sampler resources do not
grow just because the light table does. An indexed depth-array representation
is the first candidate, with layers for spot/sun views and six addressed views
for a point light; validate format support and face-edge sampling. A packed
atlas is an alternative driven by support or measured storage waste. Grow
resources under the existing fence owner, with explicit allocation failures.
This is required binding/storage work, not virtual shadow-map infrastructure.

Measure the first populated street as soon as local fixtures work. Separate
shadow caster submission, depth rendering and light evaluation. Track light
projection and caster changes so whole-view reuse has an exact validity rule;
implement cache reuse only when redraw measurements justify it. Static/dynamic
depth splitting needs its own cost comparison including copy/merge bandwidth.
Moving headlights retain current presented shadow transforms.

Use a reduced-resolution bloom pyramid and organize uploads, pass boundaries
and attachment load/store operations deliberately for Apple GPUs. Half-float
storage does not imply half-precision transforms or arithmetic. The linked
research provides source references, comparison criteria and backend caveats.

Use explicit shadow-view ownership and queried formats. Profile target sizes,
filtering, bias, caster count, overlap and GPU memory on the accepted views.
Choose resolutions from demonstrated quality/cost, not arbitrary engine caps.
A simple sun view is the first candidate; require stable near/far driving views
before deciding whether directional cascades are actually needed. Rebuild or
reuse resources according to observed content/pose/revision changes and retain
them through GPU completion. Camera movement must not cause stale shadows,
self-shadow acne, detached contact shadows or conspicuous resolution changes.

## 5. Authoring and engine/game ownership

| Owner | Responsibility |
| --- | --- |
| Engine runtime | Renderer-neutral light values, resolved transforms, frame submission, light evaluation, GPU buffers/targets/shadows, asset identity and validation primitives |
| Engine tooling | Lighting Lab widgets and projection/gizmo support, descriptor presentation, typed request transport and common editor infrastructure |
| Game content/runtime | Fixtures, placements, presets, sign art, shop geometry, lamp rig offsets and rules for enabling headlight rigs |
| Game tooling/composition | Concrete lighting library owner, authoring transaction/history, semantic fixture names, durable game directory, CLI projection and title acceptance scenes |

Keep the concrete title-aware authoring adapter honest about its owner, as the
material/vehicle workflows do. Tooling can submit typed requests but cannot
reach into SDL, physics, renderer resources or arbitrary files. `incinerator-dev`
remains the sole agent-control product. Its executable catalog is extended by
implementation; this document does not invent live command IDs.

A single lighting owner handles inspect, preview, apply, clear preview, revert,
undo/redo and durable commit. Requests carry source, stable target, expected
revision and transaction ID. Preview is producer-owned and disposable. Session
lighting is host-owned presentation state applied at the presentation boundary;
asset commit is a separate durable outcome. Persisting lights does not silently
save the world or rewrite materials/vehicles. Asset/member revisions and
installation/source roots must be visible.

Save immutable lighting assets with the same atomic-write and failure behavior
as existing authored assets. Runtime/editor-off builds consume installed assets
without the mutable owner or source-file discovery. Validate references and
content digests during cook/install, relocation and restart. If lighting becomes
a new catalog kind, update every relevant switch/serializer/schema together.

### Concrete interaction journey

- Select a live fixture/member in World Outliner or by its bounded viewport
  affordance. Content Browser selects the reusable lighting asset.
- Lighting Lab shows units, current/saved/draft state, parent attachment and
  contribution. Editing creates a preview; Apply emits one typed transaction.
- A gizmo press inside the visible handle captures that interaction before
  picking/gameplay. Retain the starting pose/cone, dirty state and projection.
- Drag modifies that preview. Release ends capture and leaves the edited draft;
  Apply commits once. Escape restores the capture-start draft, not older edits.
- Focus loss, minimization, panel closure, hidden editor, parent/selection loss
  or incompatible mode ends capture and clears its hit regions/preview according
  to the existing policy. Held buttons remain suppressed until release.
- Undo/redo operates on committed session history. Commit Asset writes durable
  content separately. Rejection leaves prior state/revisions unchanged.

World-transform gizmos operate on static fixtures; an attached light exposes
its local mount pose and clearly identified parent rather than relocating the
vehicle. Sun editing exposes orientation, not a fictitious sun position.
All overlays use bounded affordances; none covers the central scene with an
ImGui window. Native SDL routing acceptance uses a hidden window and injected queue events;
normal EA3 verification never activates a foreground window. Human usability
review uses the ordinary game launch.

## 6. Evidence and presentation replay

Lighting remains presentation-only. Editing a light, exposure or bloom must not
change authority digests, NPC decisions, damage, vehicle physics or simulation
pause. A dedicated server need not allocate light instances or GPU resources.
Clients can share installed lighting assets without replicating local previews.

Record the effective environment, asset/member/instance identities, revisions,
enabled state, emitter values, parent incarnation and presented transform,
light/caster inclusion reasons, shadow state, material emission bindings,
exposure, tone operator and bloom settings. Correlate these to frame/tick/time,
draw identity and authoring transaction. Include before/candidate/accepted
artifact digests for edits; record the state actually rendered, not just the UI
request.

Semantic accepted-ingress replay proves gameplay authority, not a lighting
image. Add a versioned presentation-side capture of initial lighting state and
typed subsequent changes for graphical re-execution. Reuse recorded presentation
time for any animated demonstration; never make visual verification depend on
unrecorded wall-clock time. Static committed-preset replay is the first proof;
a live edit followed by replay is required before EA3 closeout. Advance visual,
content, endpoint and evidence cohorts when their encoded meaning changes.

Per-frame snapshots identify effective values even when a lighting asset changed
since capture. Preserve the exact referenced revisions so reconstructing an
incident never substitutes today's sign, light rig or exposure. The validation
report must distinguish authority replay, presentation-event reconstruction,
image comparisons, measured frame cost and subjective visual judgment.

## 7. Ordered implementation backlog

Finish each slice's working path before expanding it. Each row includes code,
focused tests, content and a brief evidence update; do not build all capabilities
before the first visible result.

| Order | Deliverable | Exit evidence |
| --- | --- | --- |
| EA3-0 | Freeze light/direction/unit/color semantics, ownership, fixture IDs, attachment frame and evidence contract; retain current day/material/vehicle render baselines; verify pinned SDL shader/format transport | CPU light-equation references, storage-buffer reflection/MSL checks and native capability/layout probe; concrete schema and dependency review; no speculative caps |
| EA3-1 | One editable game-owned sun/environment preset, minimal Lighting Lab/CLI transaction path, HDR scene and display resolve | Daylight neutral-material chart, intensity/exposure changes, saved preset restart, UI excluded from exposure, identical offscreen/displayed resolve |
| EA3-2 | One point lamp and one spot street light, reusable local-light BRDF, lit product primitives, shared frame draw submission, initial spot shadow and indexed multi-shadow storage | Spot-light blocker proof, off-camera emitter/occluder proof, no illumination beyond authored cutoff; actual product geometry receives light; first repeated-fixture cost measurements |
| EA3-3 | Complete point/sun direct shadows; neon, backlit and floodlit signs; bloom and the shallow overhead-lit shop | Every static fixture row passes day/dusk/night and blocker tests; signs remain readable; real aperture controls direct exterior spill |
| EA3-4 | Attached headlight rigs on all three cars and a proposed carryable work lamp | Same presented parent transform across mixed render cadences; occlusion and lifecycle/streaming cleanup; existing vehicle dynamics remain unchanged |
| EA3-5 | Complete fixture/member selection and gizmos, undo/redo, durable authoring, frame inspection and presentation-edit reconstruction | UI and CLI edit the same targets with stale/failure/cancel coverage; exact committed reload and incident reproduction |
| EA3-6 | Assemble full street, profile actual content, close native/installed/editor-off/headless/relocation gates and human review | All fixture acceptance cases, performance evidence, complete diagnostics and updated roadmap/architecture ledger |

The first implementation target is EA3-0 followed immediately by the editable
sun/HDR slice. The capability/layout probe is part of EA3-0, not something this
planning review has already run.

### Verification matrix

- CPU/reference: units, direction, inverse-square behavior away from source
  regularization, cone center/edge/outside, finite cutoff, invalid values, parent
  transform composition and stable identity. No test merely mirrors a shader.
- Render: analytically comparable diffuse probes in linear HDR; separate specular,
  roughness, normal-map and emissive cases; on/off difference images; blocker
  and window-frame masks; readable colored signs with bloom on/off. Use explicit
  reference-camera/exposure presets and numerical tolerances justified by GPU
  sampling, not whole-frame universal hashes.
- Motion: stationary car, forward/reverse drive, steering, suspension motion and
  crossing district boundaries at 30/60/144/irregular render cadence. Compare
  lamp pose to the exact parent draw pose; check no duplicate/stale emitters.
- Ownership: lighting changes leave authority digests unchanged; stale requests,
  invalid parent/assets, cancellation and disk failures do not partially commit;
  one UI action means one outcome/history entry.
- Lifecycle: ordinary hidden Metal rendering, resize/minimize, resource recreation,
  asset reload, GPU completion and clean teardown. Test mixed local lights and
  retained districts together, not only isolated lamps on a fallback floor.
- Packaging: installed and relocated light/material/fixture content, editor-off
  product, headless authority, diagnostics and matching replays. The renderer
  must never load source glTF or use repository-relative asset paths.
- Performance: retain CPU light collection/culling/submission, GPU shading/shadow/
  postprocess measurements where supported, frame-time distributions, target
  memory, actual active lights and shadow views. Exercise overlap and the long
  road at the user's real drawable size. Report the performance impact before
  adding an optimization or changing quality. Do not invent a fixed light budget.
- Human review: lamp pool softness, sign legibility and glow, interior/exterior
  contrast, headlight usability and shadow stability while driving. Automated
  physics and image checks do not substitute for this judgment.

Use existing headless and hidden-render test infrastructure. Name new targets
when implemented and register them in the appropriate aggregate. Do not publish
commands for nonexistent targets as if they worked today.

## 8. Scope and remaining implementation decisions

EA3 delivers authored direct lighting and the examples above. Full map editing,
traffic, missions, player light-switch controls, a scripting VM, gameplay stealth,
weather/day-night simulation, volumetric beams/fog, global illumination, automatic
emissive-mesh transport, reflection probes and advanced glass remain separate
features. Headlight beams are visible on surfaces; suspended light shafts require
participating media and are not implied by a spotlight.

Area/tube lights, IES/projector profiles, automatic exposure, directional
cascades, clustered lighting and shadow caching are evaluated only if the named
examples or measured cost demonstrate a need. Do not preclude them with a fixed
contract cap, but do not build them ahead of that evidence. Indexed shadow
storage and validated light-buffer bindings are immediate integration needs;
they are distinct from those conditional optimizations.

Implemented choices: pre-exposed RGBA16F, Reinhard then sRGB once, reduced
bloom pyramid, growable 64-byte light records and 80-byte shadow records,
D32 depth-array views and 3×3 PCF. Directional shadows fit resident submitted
casters; point/hemispherical spots use six addressed faces. The validation
ledger separates measured frame costs, pixel/contract acceptance and human
visual tuning.
