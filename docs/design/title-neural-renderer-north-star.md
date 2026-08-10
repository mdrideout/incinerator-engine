# Incinerator Title Neural Renderer North Star

**Status:** Accepted product direction; NR-0004 and NR5-A through NR5-E
accepted; NR6 causal temporal reconstruction is next

**Date:** 2026-08-10

**Decision:**
[ADR-026](../adr/026-from-scratch-title-neural-renderer.md)

**Presentation and promotion boundary:**
[ADR-025](../adr/025-game-specific-neural-rendering-boundary.md)

**Implementation plan:**
[Title Neural Renderer Implementation Plan](title-neural-renderer-implementation-plan.md)

## Product outcome

Incinerator will provide a repeatable training and runtime framework through
which a game can build its own neural renderer from random initialization. The
game continues to simulate and cheaply rasterize the complete authored world.
The title model predicts the final high-fidelity scene pixels from that
deterministic representation.

The intended leap is larger than ordinary resolution enhancement:

```text
low-resolution geometry, color, and deliberately cheap shading
  + exact depth, motion, identity, surface, material, lighting, and history data
  + prior neural output/history
  -> high-resolution title-authored materials, lighting, texture, effects,
     antialiasing, denoising, and final scene color
```

The model is specific to the game and its art direction. It is trained only on
the game's paired corpus. No pretrained image/video/foundation model, inherited
VAE, text encoder, or fine-tuned external checkpoint is part of the product
lineage.

### Working resolution strategy

NR4-C through the first NR5 proof use one self-contained 16:9 cohort: a `160×90`
cheap appearance/control baseline and a `400×225` high-fidelity output target.
This is a deliberate 2.5× linear reconstruction with 6.25× as many output
pixels, not an integer-scale shortcut. It keeps capture, target rendering,
training, ablation, and visual iteration local and fast while exercising both
resolution reconstruction and the title-specific material/lighting
transformation.

Every active target is rendered directly at `400×225`. Every input, target,
baseline, model output, review image, metric, acceptance decision, and runtime
proof is derived from this native cohort. No image rendered at another
resolution is reduced, enlarged, compared, used as a visual reference, or
allowed into training or acceptance. Earlier NR4-A/B artifacts remain archived
technical history only; the native `400×225` still and moving sequence must be
generated and accepted again on their own terms. Output resolutions beyond
`400×225` are deferred and have no role in the current plan.

This is the guiding test for every future choice:

> Does this make it easier for a title to train, validate, reproduce, promote,
> and run its own faithful graphics predictor from deterministic engine inputs?

If not, it is not on the critical path.

## What the model is—and is not

The model is a **densely conditioned causal neural renderer**. It is a learned
part of the presentation pipeline with a supervised relationship to a
high-fidelity target renderer.

It is not:

- a world model;
- a gameplay or authority system;
- a text-to-video model;
- an asset generator at runtime;
- a universal renderer for arbitrary games;
- a wrapper around third-party weights;
- an excuse to omit information and let the model guess; or
- the owner of UI, text, editor chrome, diagnostics, or accessibility graphics.

The deterministic game owns what exists and what happens. The target corpus
owns what that state should look like. The model learns the mapping.

Training from scratch does not mean reproducing a general 2B video foundation
model and its internet-scale knowledge. Incinerator deliberately removes most
of that problem: no language understanding, arbitrary object vocabulary,
unknown camera, uncontrolled style, or natural-video world inference is
required. A narrower title model can spend its capacity on the finite asset,
material, lighting, effect, and motion distribution supplied by the game. The
corresponding cost is that the title data factory—not an inherited semantic
prior—must provide complete visual coverage.

## Lessons incorporated from existing systems

### DLSS-style reconstruction

Modern neural supersampling succeeds by consuming renderer information that
ordinary video does not have: sampled color, precise motion, depth, exposure,
and history. NVIDIA's current DLSS material describes Super Resolution as
combining lower-resolution samples, motion data, and previous-frame feedback;
its DLSS 5 announcement extends the idea toward learned lighting and materials
while emphasizing anchoring to 3D content, temporal consistency, and artist
controls.

Incinerator adopts the lesson, not the proprietary implementation: engine
signals are privileged conditioning, history is explicit, and artist intent is
controlled. Unlike universal DLSS, the model and corpus are title-specific.

Sources:

- [NVIDIA DLSS technology overview](https://developer.nvidia.com/rtx/dlss)
- [NVIDIA DLSS 5 announcement](https://nvidianews.nvidia.com/news/nvidia-dlss-5-delivers-ai-powered-breakthrough-in-visual-fidelity-for-games)
- [Neural Supersampling for Real-time Rendering](https://www.cs.jhu.edu/~misha/ReadingSeminar/Papers/Xiao20.pdf)

### High-resolution structural controls

Low-resolution color cannot contain every high-frequency silhouette or edge.
FuseSR demonstrates the value of combining low-resolution color with cheap
high-resolution auxiliary G-buffers. Incinerator should therefore optimize
each channel independently rather than force every control to the appearance
resolution. Low-cost high-resolution depth, normals, motion, coverage, and
identity may save more model work than they cost to rasterize.

Source:
[FuseSR](https://arxiv.org/abs/2310.09726)

### Temporal propagation and alignment

Video restoration research repeatedly identifies propagation, alignment,
aggregation, and upsampling as the essential temporal operations. Incinerator
has better alignment data than natural video because the engine supplies motion
vectors, depth, instance identity, camera cuts, and effect resets. The model
should use those signals rather than relearn optical flow as its first task.

Sources:

- [BasicVSR](https://arxiv.org/abs/2012.02181)
- [BasicVSR++](https://arxiv.org/abs/2104.13371)
- [Temporally Stable Joint Neural Denoising and Supersampling](https://www.intel.com/content/www/us/en/developer/articles/technical/temporally-stable-denoising-and-supersampling.html)

### LTX-style latent video processing

LTX-Video demonstrates why a causal video VAE, compressed spatiotemporal
tokens, full temporal attention at low resolution, and a decoder responsible
for final pixel detail can make a large video model tractable. NR-0003 confirms
that the 2B implementation runs on the target Mac at the desired proof rate.

Incinerator does not adopt LTX weights, text conditioning, natural-video
training, or unconstrained scene generation. The reusable lessons are:

- expensive global reasoning belongs in a compressed representation;
- the decoder must retain enough capacity to reconstruct fine pixel detail;
- spatial and temporal compression must be evaluated together;
- causal conditioning and frame history are first-class; and
- aggressive compression creates a measurable fine-detail failure envelope.

Source:
[LTX-Video technical report](https://arxiv.org/abs/2501.00103)

### AlayaRenderer-style world conditioning

AlayaRenderer-Flash is the closest public architectural analogue: structured
G-buffer streams condition a few-step autoregressive renderer that supports
continuous play, with lightweight codecs reducing the cost of latent encoding
and frame reconstruction. Its reported playable integration reinforces the
value of structured world state, streaming causal inference, cross-window
stability, and end-to-end codec/model co-design.

Incinerator does not adopt its teacher model, distillation lineage, prompt
interface, weights, or hardware assumptions. The reusable lesson is to train a
small streaming title renderer directly on Incinerator's exact paired corpus
and to evaluate window boundaries as part of temporal correctness.

Source:
[Generative World Renderer at the Speed of Play](https://arxiv.org/abs/2607.18703)

## End-to-end ownership

```text
title source assets and deterministic scenarios
  -> authoritative simulation/replay
  -> cheap reference raster and auxiliary controls
  -> exact high-fidelity target renderer
  -> paired sequence corpus
  -> repository-owned random initialization
  -> training, validation, ablation, and failure evaluation
  -> immutable external candidate
  -> explicit human promotion
  -> selected title model bundle
  -> macOS runtime inference
  -> conventional fallback, diagnostics, and incident evidence
```

The engine repository owns the framework and contracts. The separately
licensed title owns its target assets, corpus, trained weights, and selection.
Generated datasets and checkpoints remain outside Git. Deliberately promoted
bundles enter game content only through ADR-025's transactional boundary.

## Paired data is the product foundation

### One source event, two render paths

Every training example comes from one immutable presentation event:

```text
tick + camera + transforms + animation + effect phase + exposure + identities
  -> reference path: cheap low-fidelity inputs
  -> target path: exact high-fidelity scene color
```

The pair is invalid if either path changes composition, timing, camera,
visibility, identity, or deterministic effect state. A pretty but unaligned
target is not training data.

### Reference inputs

The current 17-plane ABI is a foundation, not the final contract:

- low-resolution appearance;
- linear depth;
- world/view normals with one convention;
- previous-to-current motion;
- coverage/history validity;
- semantic and stable instance identity.

The next schema should experimentally add only information required to remove
real ambiguity:

- material and asset identity;
- UV or another stable surface coordinate;
- roughness, metallic, emissive, and opacity classes;
- cheap direct-light, visibility, or shadow features;
- deterministic effect kind, phase, and responsive mask; and
- exposure, grade, weather, and time-of-day controls.

The next working appearance baseline is `160×90` and its target is `400×225`.
Controls begin at `160×90`; a structural control may use `400×225` only when a
measured ablation shows that the extra raster/storage cost resolves an observed
failure. The data contract records each channel independently.

### Target inputs and rights

The target renderer may be:

- a deterministic high-quality mode in Incinerator;
- an offline open renderer such as Blender/Cycles driven through an exact scene
  export and capture adapter; or
- another title-owned deterministic renderer with the same pair contract.

The target should contain the detail the runtime model is expected to learn:
final meshes and animation, authored materials and textures, high-sample
lighting and shadows, reflections, atmosphere, particles, smoke, fire, weather,
hair, cloth, and post-exposure color as applicable to the title slice.

Target generation can be slow. It is manufacturing ground truth, not shipping
runtime code. It must remain reproducible and rights-attributed.

### Coverage and splits

Capture is scenario-driven rather than a bag of adjacent frames. A corpus
manifest records coverage of:

- locations, assets, materials, characters, vehicles, props, and effects;
- camera distance, lens, motion, cuts, and occlusion/disocclusion;
- animation, deformation, destruction, attachment, and replacement;
- lighting, weather, exposure, transparency, and particle behavior; and
- unusual but valid views and history resets.

Training, validation, and test own whole sequences. Validation selects models;
the test cohort is opened only after selection. Separate tests distinguish
held-out cameras over known title content from genuinely new content that may
require retraining.

## Recommended model family

### Structural reconstruction path

Start from a repository-owned hybrid temporal reconstruction network:

1. encode low-resolution appearance and low-resolution controls;
2. encode higher-resolution structural controls in a shallow branch;
3. warp prior features/output using engine motion and reject them using depth,
   instance identity, coverage, and reset state;
4. aggregate current and historical features through causal recurrent blocks
   and windowed spatial/temporal attention at compressed resolutions;
5. progressively upsample, fusing structural features at each scale; and
6. predict linear/HDR scene color while exposing the engine-owned history-use
   mask and any learned confidence as separate diagnostics.

Convolutions remain appropriate for local reconstruction and efficient
upsampling. Attention belongs where long-range material, lighting, reflection,
and temporal relationships demonstrate value. Full-resolution global attention
is not the starting point.

### Learned-detail path

A supervised reconstruction model may average uncertain texture and lighting.
When measured evidence shows that ceiling, add a second title-trained head that
predicts only the missing high-frequency/material-lighting residual. Candidate
objectives include a jointly trained discriminator or a small conditional
rectified-flow/diffusion process initialized from scratch.

The detail head receives the structural reconstruction and the same controls.
It cannot replace geometry. Losses and acceptance masks penalize silhouette,
identity, depth-edge, and motion disagreement independently from visual
richness. If sampled noise is used, it is tied to stable surface/instance/time
coordinates so a surface does not repaint itself every frame.

### Why not start with a general video generator

A general model spends parameters learning language, natural-video semantics,
arbitrary objects, camera grammar, and broad style. Incinerator already knows
the world state and needs a much narrower conditional mapping. From-scratch
training should spend capacity on the title's materials, assets, lighting,
effects, temporal behavior, and failure envelope.

## Training methodology

### Stage 1: data-path overfit

Use one short exact sequence and prove the model can reconstruct it nearly
perfectly. This validates channel decoding, target alignment, output transfer,
losses, optimizer state, checkpointing, and visual reporting. Failure here is a
pipeline or capacity problem, not a request for more data.

### Stage 2: deterministic spatial reconstruction

Train across disjoint camera and composition cohorts without history. Establish
a strong structural baseline before adding a generative objective. Initial
losses should be computed in declared linear/HDR and display spaces and include:

- robust pixel/color error;
- multi-scale gradient and frequency reconstruction;
- structural similarity;
- semantic and instance boundary preservation;
- material/asset consistency where labels exist; and
- explicit penalties for missing, duplicated, or displaced authored geometry.

No externally pretrained perceptual network participates in training.

### Stage 3: causal temporal reconstruction

Train on clips with motion-warped history, scheduled invalid history, camera
cuts, resize/model resets, fast motion, animation, disocclusion, particles, and
transparency. Add:

- valid-history temporal reconstruction;
- disocclusion-specific current-frame reconstruction;
- stable material/detail losses in surface space where available;
- responsiveness penalties after real state changes; and
- long-run drift and recovery evaluation.

Training may use longer future context as a teacher only when that teacher is
another branch trained from scratch on the same title corpus and the shipped
student remains causal. Such distillation must preserve full lineage.

### Stage 4: learned visual richness

Add the residual detail objective only after structural and temporal baselines
are trustworthy. Train the discriminator, latent codec, flow model, or other
learned loss component from random initialization on the same title corpus.
Maintain ablations against the deterministic model so improved texture cannot
hide worse identity, motion, or geometry.

### Stage 5: runtime-shaped training

Once a quality candidate exists, train/evaluate with the chosen runtime
precision, history shape, tiling, scale, and decoder. Distillation, pruning,
quantization-aware training, and architecture reduction may optimize the
title-trained model without introducing external weights. Quality-first full
precision remains the reference.

## Repository-owned training framework

The framework should grow as explicit tools with one owner each:

```text
capture/target adapter      exact paired sequence production
dataset assembler           schema, split, rights, coverage, and digest checks
model package               architecture plus deterministic initialization
trainer                     configuration, resume lineage, metrics, checkpoints
evaluator                   baselines, ablations, temporal/identity/failure tests
visual reporter             complete comparisons and semantic evidence
exporter                    runtime format conversion and numerical agreement
promotion                   immutable source-preserving selected bundle
```

Each run records source and dirty fingerprints, content/target revisions,
dataset and split digests, architecture/config hash, initialization and training
seeds, environment, every ancestor checkpoint, optimizer/scheduler state,
metrics, images, timing, memory, disposition, and reason. Resume creates a
lineaged continuation rather than silently overwriting a run.

The framework must support a clean-room test: delete mutable caches, recreate
the environment and dataset from declared sources, train a small fixture, and
obtain the declared logical/model lineage. Exact floating-point weights need
only be promised where the backend is actually deterministic; deviations are
measured rather than hidden.

The first training host is the current Apple Silicon Mac through PyTorch/MPS so
the complete framework remains locally executable and inspectable. This is a
starting host, not a fabricated promise that every eventual quality model will
fit or train quickly on it. Model scale, activation memory, corpus throughput,
and training wall time are measured. If a demonstrated candidate outgrows the
Mac, the same open framework may run on user-controlled training hardware
without adopting external learned weights or changing the macOS-first runtime
contract.

## Acceptance dimensions

No single PSNR or attractive screenshot selects a renderer. Every candidate is
judged separately on:

- authored geometry, silhouette, pose, visibility, and identity;
- target material, texture, lighting, color, and effect fidelity;
- temporal stability, responsiveness, disocclusion, and reset recovery;
- small/thin features, transparency, particles, reflections, and UI boundary;
- held-out camera and scenario behavior;
- long interactive runs and incident evidence;
- local cold/warm latency, frame pacing, process/GPU memory, and power; and
- exact provenance, rights, export agreement, fallback, and runtime identity.

The conventional renderer and deterministic resize remain required baselines.
The expensive target is the quality reference. External models such as LTX may
appear only as clearly labeled research comparisons.

## Phase sequence from here

### NR-0004 — High-fidelity target and corpus foundation

- Select one narrow but materially rich title scene.
- Implement one deterministic target-renderer adapter.
- Regenerate and accept the exact target still and moving sequence natively as
  a self-contained `160×90 → 400×225` cohort.
- Advance the input schema for observed material/surface/lighting ambiguity.
- Produce exact paired clips across controlled train, validation, and test
  scenarios.
- Prove alignment, rights, coverage, recapture identity, and human target
  quality.

**Exit:** an inspectable corpus contains a visual transformation worth learning
without changing world state.

### NR-0005 — From-scratch structural title renderer

- Implement the first hybrid spatial model with repository-owned deterministic
  initialization.
- Pass controlled overfit, then held-out camera/composition evaluation.
- Compare the native cheap input, deterministic `160×90 → 400×225` upscales,
  the new model, and the direct native high-fidelity target.

**Exit:** structure and identity are faithful and the model learns a material/
lighting improvement from title data without external weights.

### NR-0006 — Causal temporal title renderer

- Add engine-guided feature/history reprojection and rejection.
- Train on motion, disocclusion, effects, cuts, resize, and invalid history.
- Reuse the NR0-D scenario and metric definitions, recapturing every evaluated
  frame natively at `160×90 → 400×225`.

**Exit:** temporal output is stable, responsive, independently resettable, and
better than the spatial candidate on declared sequences.

### NR-0007 — From-scratch visual-detail residual

- Measure the deterministic model's richness ceiling.
- Add only the smallest proven title-trained adversarial or conditional-flow
  residual path.
- Preserve structural and temporal ablations.

**Exit:** human-visible materials, lighting, texture, and effects improve
without geometry substitution or temporal repainting.

### NR0-E through NR0-G — Promotion, runtime, and acceptance

Resume ADR-025 promotion only after a candidate passes the quality envelope.
Then package one exact title model, implement GPU-resident macOS inference and
the `N` toggle, exercise fallback/history/incident behavior, and complete human
and architectural acceptance.

## Immediate next action

NR5-C/D prove known-fixture held-out spatial reconstruction: selection used
validation only, the test was opened once, a second open was rejected, and the
selected checkpoint passed a fresh native stress cohort plus all-input branch
ablations. Complete visual review still finds localized smoothing and chromatic
ringing at emissive, glass, and high-contrast edges. NR5-E then proves the
engine's live six-channel input can drive that exact checkpoint through an
explicit Core ML bundle with comparison, fallback, model/frame diagnostics,
incident linkage, and graphical evidence. NR6 is next: define the causal
history/reprojection/reset contract and determine whether temporal conditioning
improves stability without hiding those spatial limitations. The NR-0005
checkpoint and trial bundle remain external and unpromoted.
