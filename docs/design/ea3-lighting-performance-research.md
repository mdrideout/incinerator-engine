# EA3 lighting performance research

**Date:** 2026-09-13. **Status:** Research completed before implementation.
The subsequent [EA3 validation ledger](../validation/ea3-authored-lighting.md)
contains native capability probes and Incinerator measurements.
This supplements the [EA3 implementation plan](ea3-authored-lighting.md) and
[ADR-029](../adr/029-engine-game-authoring-boundary.md).

The first review checked lighting semantics and basic API availability. This
second review compares implementation costs, scaling paths and backend fit.
The recommendations below are engineering judgments for Incinerator, not
performance results borrowed from another engine. Foundational papers are dated
explicitly; their age does not make them new discoveries, and their published
frame rates do not predict this game's frame rate.

## Recommendation

Keep forward material shading. Establish a simple correctness reference, then
measure conservative spatial light lists if the actual street demonstrates a need. Clustered forward
is the preferred candidate if overlap makes simpler lists expensive. Treat
shadow submission, shadow storage and invalidation as separate problems from
light evaluation. Use pre-exposed HDR and a reduced-resolution bloom pyramid,
with pass/resource organization suited to Apple GPUs.

The earlier plan was too vague in deferring all light-list and shadow-storage
decisions until the end. Shader transport and multi-shadow binding must be
proven early; full-street cost must be measured as soon as local fixtures work.
Advanced culling and caching still require evidence before implementation.

## 1. What fits our actual renderer

Inspected `src/renderer.zig`, `shaders/model.frag`, `build.zig`,
`tools/shader_contract_test.zig`, `src/material_preview.zig` and the staged
SDL headers in `.zig-cache/o/d25f6a244010d2eaa89341d826e0e7aa/SDL3/`.
`SDL_version.h` identifies those cached headers as **3.4.14**, matching the
version in `build.zig.zon`. This is declaration inspection, not proof of device
format support or binary/header provenance for a newly built executable.

- The product is Apple Silicon macOS, SDL GPU/Metal, GLSL compiled through
  SPIR-V to embedded MSL. Existing product pipelines declare zero storage
  buffers; the material shader binds five material textures.
- Shader contract tests inspect textures and uniform buffers, but their
  reflection model does not validate storage-buffer layouts. Add stride,
  alignment, binding and generated-MSL coverage with the first light buffer.
- The staged API exposes ordinary vertex/fragment stages, separate compute
  passes, texture arrays and comparison samplers. It does not expose a tile
  shader/imageblock workflow through these public GPU interfaces.
- SDL shader creation declares resource counts. A growing light buffer does
  not provide a growing set of independently bound shadow textures. Resolve
  indexed shadow storage before building the multi-fixture scene.

The public [shader descriptor](https://wiki.libsdl.org/SDL3/SDL_GPUShaderCreateInfo),
[compute pipeline interface](https://wiki.libsdl.org/SDL3/SDL_CreateGPUComputePipeline)
and [sampler descriptor](https://wiki.libsdl.org/SDL3/SDL_GPUSamplerCreateInfo)
support those transport choices. Exact generated MSL bindings and depth-array
sampling still need the EA3-0/EA3-2 native probes. Do not assume native Metal
bindless features are automatically available through SDL.

## 2. Forward, tiled, clustered and deferred lighting

| Approach | Cost and fit | Incinerator decision |
| --- | --- | --- |
| Global forward light loop | Very simple reference, but visible lights can be evaluated on unrelated surfaces | Keep as an initial validation reference; do not declare the street scalable from this alone |
| Forward with per-draw spatial lists | CPU intersection work reduces the lights evaluated by each draw; large road/building meshes can still collect long lists | First practical candidate using presented bounds and authored ranges |
| Clustered forward | Divide view space in X/Y/depth and index only lights intersecting a fragment's cell; list construction has its own cost | Preferred measured scaling path for deep streets and overlapping lamps/headlights |
| Conventional multipass deferred | Adds a material G-buffer and lighting resolve; extra attachments and traffic must earn their cost | No renderer replacement for EA3 without a comparative result |
| Metal tile-shader forward/deferred | Exploits native tile-memory features | Research reference; not an SDL integration already available to our renderer |

The 2012 [Clustered Deferred and Forward Shading paper](https://research.chalmers.se/en/publication/161725)
groups view samples in three dimensions and reports better light assignment
than screen tiles under depth discontinuities. That is relevant to a street
where nearby shop fronts and distant roads share screen space. It is evidence
for a candidate algorithm, not evidence that Incinerator needs a GPU cluster
builder immediately.

[Filament](https://google.github.io/filament/main/filament.html) documents a
clustered forward path, making it a useful production-oriented reference.
For us, keep the light table independent of list construction. CPU-built lists
can be uploaded to the same indexed transport; introduce compute construction
only when measured CPU cost warrants it. A depth-independent frustum grid can
also avoid requiring an opaque-depth prepass solely to construct light lists.

Use conservative light/receiver tests: point sphere, spot cone or enclosing
bounds, plus the declared finite cutoff. An omitted cutoff stays unbounded.
Keep directional/unbounded contributors separate from finite local lists.
Do not use sampled opaque depth to exclude lights needed by an optional glass
surface. No fixed per-object/per-cell light truncation: construct counted index
ranges, grow storage as required and report allocation failures explicitly.

Measure list-build time, upload cost, light evaluations, overlap and total frame
time. A compact scene can favor a simple CPU path; a large mesh or deep overlap
can favor clusters. Changing fixture semantics to fit an algorithm is not an
acceptable optimization.

## 3. Shadows need their own strategy

Start with depth shadow maps and percentage-closer filtering: compare depths
and filter visibility. This is an established real-time method described by
[Bunnell and Pellacini](https://developer.nvidia.com/gpugems/gpugems/part-ii-lighting-and-shadows/chapter-11-shadow-map-antialiasing).
The cited implementation's hardware costs are historical; probe SDL comparison
sampling on our backend. Select filter width from the shop-frame/headlight
images and measured cost. A wide filter cannot recover detail lost to an
undersized shadow projection.

Prefer spots for genuinely directional fixtures such as headlights and road
lamps. Omnidirectional point shadows require coverage in all directions; a
cubemap representation has six faces, whereas a spot has one projection.
[Epic's current shadow documentation](https://dev.epicgames.com/documentation/unreal-engine/virtual-shadow-maps-in-unreal-engine)
illustrates this distinction and describes invalidation caused by changing
lights and casters. Six faces are not a promise of exactly six times total
frame cost: culling, coverage and geometry differ between views.

For Incinerator:

- Keep the true point-lamp example. Do not replace it with a cone just to hide
  the cost, or silently disable its required shadow.
- Use indexed depth-array layers as the first storage candidate, with one
  layer per shadow view and six addressed views for a point light. Validate
  sampling across face edges. A packed atlas is an alternative if array
  support or measured resolution waste justifies it. Neither needs virtual
  pages, bindless resources or a general render graph.
- Size storage from actual shadow views; grow/recreate it under the existing
  GPU lifetime owner. Quality and hardware allocation limits are explicit;
  sampler count must not become a hidden maximum number of lights.
- Reuse an entire shadow view only when projection, relevant caster membership,
  geometry/opacity and presented transforms are unchanged. Light color or
  intensity alone need not invalidate depth. Start with full-view invalidation.
- If repeated static geometry dominates measurements, evaluate a static-depth
  cache plus current dynamic casters. Include copy/merge bandwidth and memory
  in the comparison; do not assume this split is free. Remove old dynamic
  occluders correctly and invalidate on streaming/reload.
- Moving headlights require current light-space depth when their projection
  or casters change. Do not reduce update frequency and accept detached shadows
  as a performance success.

[Epic's Fortnite engineering report](https://www.unrealengine.com/tech-blog/virtual-shadow-maps-in-fortnite-battle-royale-chapter-4)
shows why caching benefits depend on motion and why its virtual shadow maps
are closely coupled to Nanite. Our conclusion is to borrow invalidation
discipline, not that architecture. Local stationary lamps are a plausible
cache beneficiary; moving headlights and changing sun projections are less so.

For the sun, first measure a stable camera-fitted orthographic view. Record
world-space texel footprint over the near car and far road. If a single view
cannot satisfy both at sensible cost, compare cascades before increasing one
map indefinitely. [Microsoft's CSM guidance](https://learn.microsoft.com/en-us/windows/win32/dxtecharts/cascaded-shadow-maps)
covers frustum partitions, projection stability and texel-aligned movement.
Cascades remain a conditional EA3 quality response, not an arbitrary cascade
count chosen now.

## 4. HDR, bloom and Apple GPU traffic

Use a supported half-float scene target as the initial HDR candidate.
Pre-exposure keeps useful photometric values representable; apply exposure
exactly once and record its convention. Filament's
[pre-exposed lighting discussion](https://google.github.io/filament/main/filament.html)
supports this approach. Format/type/usage support is a runtime
[SDL capability query](https://wiki.libsdl.org/SDL3/SDL_GPUTextureSupportsFormat),
not something the pixel-format enum establishes.

Bloom should start as a reduced-resolution downsample/upsample pyramid.
[Jorge Jimenez's Call of Duty postprocessing report](https://www.iryoku.com/next-generation-post-processing-in-call-of-duty-advanced-warfare/)
describes a pyramidal filter hierarchy aimed at stability. For our neon and
small headlamps, compare stationary and subpixel-moving fixtures, edges of the
screen, dark backgrounds and saturated colors. Choose pyramid depth/filtering
from those images and measurements. Keep it independent of direct illumination.

[Apple's Metal performance guidance](https://developer.apple.com/videos/play/wwdc2023/10125/)
emphasizes batching uploads before draws, grouping compatible work and using
load/store actions to avoid unnecessary memory traffic. Apply that within SDL:
prepare light/draw buffers before passes, store shadow depth because it is
sampled later, discard only attachments with no later reader, and combine
bloom composition/tone/display work where dependencies allow. Hardware TBDR
does not mean a deferred material renderer is automatically the best choice.

Keep HDR intermediates only where needed. RGBA16F nominally uses eight bytes
per pixel versus sixteen for RGBA32F; doubling both drawable dimensions
quadruples pixel storage/work before considering overdraw or compression.
Use the actual drawable extent, not just the logical window size, in reports.
Do not silently lower the main scene resolution to make lighting timings pass.

Half precision in shader arithmetic is a separate decision from half-float
storage. Preserve precision for world transforms, depth and accumulation until
range/error tests justify changing it. Inspect generated MSL rather than
assuming GLSL precision annotations produce the intended machine behavior.

## 5. More sophisticated alternatives

The [LTC reference implementation](https://github.com/selfshadow/ltc_code)
provides real-time polygonal area-light shading. It is a credible later option
if a shop panel or overhead fixture needs shape-correct highlights. It is not
a replacement for a visibility/shadow solution. Start EA3 with its stated
punctual approximations and keep that distinction visible in acceptance.

Baked lighting and environment probes can address different costs and missing
indirect response. They also introduce asset production, invalidation and
dynamic-object sampling work absent from our current source. They are not
required to establish editable direct lighting. Retain the current declared
ambient approximation; if metal surfaces/interior corners reveal an indirect
lighting limitation, record it instead of treating added direct lights or bloom
as a physical solution. This remains a separate scoped follow-up.

Ray tracing, virtual shadow maps, a full G-buffer, temporal reconstruction and
volumetric light shafts do not become EA3 prerequisites merely because modern
engines use them. Select further work from measured cost or a named visual
requirement. No neural-rendering work is reopened.

## 6. Experiments that decide implementation

| Experiment | Compare/control | Decision supported |
| --- | --- | --- |
| Isolated sun, point and spot | Analytic/reference response; emission/bloom off; fixed camera/exposure | Correctness before optimization |
| Repeated street fixtures and all car rigs | Simple lists versus clustered candidate when overlap costs justify one; same contributions and image | Whether spatial subdivision earns its build/upload cost |
| Identical local-light scene, shadows on/off | Separate caster collection, shadow rendering and fragment sampling cost | Whether to optimize lists, geometry submission or shadow storage |
| Stationary lamps with parked and moving cars | Redraw versus valid whole-view reuse; static/dynamic split only if needed | Actual cache savings and invalidation behavior |
| Near car plus far road; camera rotation and driving | Single stable sun view versus cascades if quality fails | Projection/resolution policy without arbitrary counts |
| Signs/headlights with bloom off/on | Same HDR scene, small moving emitters, actual drawable extent | Bloom quality, bandwidth and exposure correctness |

Use hidden/offscreen native tests for routine work. Report CPU collection,
upload and submission separately from GPU pass duration; a CPU fence wait is
not a substitute for a GPU timestamp. Use Metal capture/profiling for GPU
attribution where the pinned SDL interface has no timer facility. Report
warm/cold pipeline and content state, frame-time distributions, active lights,
list lengths, shadow views/redraws/cache reasons, target memory and drawable
size. Retain ordinary product presentation as a separate acceptance check.

No speedup or acceptable light count has been established yet. The next step
is the EA3-0 capability/layout probe and EA3-1 visible sun/HDR slice, followed by
the first measured local-light scene. The full plan owns implementation order.
