# RF10 Native 720p Spatial Cohort

**Status:** Complete; accepted by the product owner as the retained external,
unpromoted stopping point; neural-rendering implementation paused

**Date:** 2026-08-17

**Track status:**
[Neural Rendering Product-Track Pause](neural-rendering-pause.md)

**North star:**
[Title Neural Renderer North Star](title-neural-renderer-north-star.md)

**Prior technical evidence:**
[RF9 Spatial Quality Expansion Validation](../validation/rf9-spatial-quality-expansion.md)

**Architectural decisions:**
[ADR-025](../adr/025-game-specific-neural-rendering-boundary.md) and
[ADR-026](../adr/026-from-scratch-title-neural-renderer.md)

## Decision

RF10 creates a completely new native spatial cohort:

```text
native 256x144 deterministic presentation inputs
  -> one title-specific model trained from random initialization
  -> native 1280x720 scene-linear HDR output
```

Both extents are 16:9 and the mapping is exactly 5:1 on each axis. The model
output is genuinely native `1280x720`; it is not a display enlargement of a
smaller neural image.

RF10 superseded RF9 as the active experimental contract after its own target,
corpus, model, sealed-test, stress, export, and graphical gates passed. RF9's
`160x90 -> 640x360` cohort remains immutable historical evidence only.

## Why this is a new cohort

Changing both sides of the learned mapping changes every artifact that can
support a quality claim:

- source rasters contain 2.56 times as many pixels;
- output and target frames contain four times as many pixels;
- the pixel-center mapping changes from 4:1 to 5:1;
- training activation, target decode, loss, evaluation, export, readback,
  upload, and presentation costs change;
- thin features and material detail become observable at different spatial
  frequencies; and
- RF9 metrics cannot be compared numerically as if they described the same
  problem.

The engine may reuse proven ownership and tooling structure. It may not reuse
RF9 source pixels, target pixels, checkpoints, optimizer state, model outputs,
split decisions, acceptance sheets, or promotion conclusions.

## Fixed contract

### Input

- Six native `256x144` RGBA8 presentation targets: appearance, linear depth,
  world normal, motion/history validity, semantic identity, and instance
  identity.
- Five frame-global Float32 presentation controls: sun strength, world
  strength, local-light strength, emissive strength, and material-palette
  intent.
- The material-palette control remains because RF9 proved a real ambiguity;
  RF10 must recapture its exact ambiguity fixtures and verify the signal at the
  new extents.
- No gameplay authority, input event, transport object, physics handle, entity
  pointer, or durable state enters the model.

### Output and target

- One native `1280x720` scene-linear HDR RGB prediction.
- One directly rendered native `1280x720` Cycles target for each pair.
- The exact target-to-source pixel-center coordinate is:

  `((target_index + 0.5) / 5) - 0.5`, with declared clamp-border behavior.
- UI and diagnostics remain conventional and are composited after neural scene
  inference.

### Presentation

- The main neural scene is presented at native `1280x720`, centered and
  unstretched.
- In the default `1600x900` window this produces 160-pixel horizontal and
  90-pixel vertical surround on each side.
- Larger windows receive additional black surround. Smaller windows use a
  centered crop until a separately designed scale policy is authorized.
- The Neural Input / Output window shows the native `256x144` source and
  correctly decoded auxiliary inputs; it does not duplicate or downscale the
  main neural result as a second authority for visual review.

## Explicit exclusions

No `160x90`, `400x225`, `640x360`, `800x450`, or `1600x900` image may be an
RF10 input, target, intermediate rendered image, supervision signal, model
output, export handoff, runtime neural surface, or quality reference.

Internal learned feature maps may use whatever extents the selected model
requires. They are not rendered intermediate images and may not receive
independent image supervision that silently creates a staged renderer.

RF10 does not add temporal history, promote a model, install learned content,
build a generic render graph, introduce a secondary platform, or expand the
gameplay scope merely to create training variation.

## Measured resource implications

The contract itself implies the following raw payloads before model-specific
activations:

| Resource | RF9 | RF10 | Change |
|---|---:|---:|---:|
| Pixels per input channel | 14,400 | 36,864 | 2.56x |
| Six RGBA8 input channels | 345,600 bytes | 884,736 bytes | 2.56x |
| RGBA8 output surface | 921,600 bytes | 3,686,400 bytes | 4x |
| Float32 RGB output/target tensor | 2,764,800 bytes | 11,059,200 bytes | 4x |

These are contract facts, not budgets. RF10 records actual MPS training memory,
Core ML residency where observable, target-render time, inference latency,
staged latency, readback/upload cost, and frame pacing on the named Mac. It
does not invent a parameter, memory, dataset, or FPS ceiling before a real
failure or product envelope exists.

## Coordinated compatibility cohort

RF10 is a greenfield schema change with no compatibility decoder. The
implementation advances all of these owners together:

| Owner | Required RF10 change |
|---|---|
| Engine contract | New input schema/fingerprint, `256x144` input extent, `1280x720` target extent, exact 5:1 mapping tests |
| Neural input host | Allocate and rasterize all six native `256x144` targets; retain exact frame identity and history semantics |
| Capture host and inspector | New capture-root/frame schemas, byte counts, filenames, manifests, debug derivatives, and foreign-extent rejection |
| Target contract/export | New target-frame schema with exact 5:1 mapping and native `1280x720` declaration |
| Blender/Cycles adapter | Render truth directly at `1280x720`; emit identity/depth/normal/alignment evidence at that extent |
| Corpus assembler/coverage | New purpose and working-resolution records; reject every earlier schema and pixel extent |
| Dataset and baselines | Decode only `256x144` inputs and `1280x720` targets; generate deterministic nearest/bilinear/bicubic baselines directly between them |
| Model | Fixed direct `256x144 -> 1280x720` output contract; random initialization; no RF9 checkpoint loader |
| Loss and evaluation | Full native-frame color/spatial/boundary evidence plus complete native and crop review without changing evaluation coverage |
| Core ML export | Fixed input shapes `[1,11,144,256]`, categorical shapes `[1,144,256]`, controls `[1,5]`, output `[1,3,720,1280]` |
| Trial bundle/loader | New bundle schema and RF10 kind; exact ABI, package, lineage, and digest validation |
| macOS adapter | Allocate fixed RF10 arrays and output resources; retain explicit preprocessing and unknown-category accounting |
| Runtime/presentation | Native centered `1280x720` scene, conventional fallback, `N` comparison, frame lineage, timing, and incident evidence |
| Neural diagnostics | Label `256x144` input and `1280x720` output exactly; expose active schema, bundle, model, failures, and measurements |
| Documentation/skill | Mark RF9 historical and RF10 active only after the implementation cohort actually lands |

Likely hard-coded resolution strings and filenames are part of the cohort and
must be removed or advanced rather than left as misleading diagnostics.

## Implementation phases

| Phase | Status | Purpose | Exit gate |
|---|---|---|---|
| RF10-A | Complete | Advance the native engine/capture/target ABI | Every producer and consumer rejects foreign extents and proves exact 5:1 correspondence |
| RF10-B | Complete | Produce and approve native 720p target truth | Direct `1280x720` targets are sharp, aligned, rights-clean, reproducible, and visually worth learning |
| RF10-C | Complete | Manufacture a fresh whole-sequence corpus | 306 fresh pairs across 17 whole sequences; sealed-test ownership remained closed through selection |
| RF10-D | Complete | Prove random-origin controlled fit | The 1,062,587-parameter direct model deliberately fit all 18 controlled frames from a recorded random initializer |
| RF10-E | Complete | Train and select on held-out validation | Epoch 110 was frozen using validation only and beat every deterministic and declared ablation baseline |
| RF10-F | Complete | Open test once and run fresh post-selection stress | The 54-frame test opened once, a second opening was rejected, and 54 newly manufactured disjoint stress frames passed |
| RF10-G | Complete | Export and exercise the native 720p Core ML trial | Core ML agreement, bundle inspection, 48-frame Metal execution, centered native presentation contract, fallback, diagnostics, and evidence passed |
| RF10-H | Complete | Record product disposition | Technical frame review passed; the product owner accepted RF10 as the retained external, unpromoted stopping point on 2026-08-17 and paused further neural work |

## RF10-A — Resolution and schema reset

1. Advance the engine input schema, frame-global schema only if its content
   changes, capture root/frame schemas, target-frame schema, corpus schema, and
   trial-bundle schema as one cohort.
2. Replace the native extents with `256x144` and `1280x720`; update byte counts,
   row pitches, texture allocations, output buffers, camera/target metadata,
   diagnostic names, evidence filenames, and human labels.
3. Add exact 5:1 first/last pixel-center, nearest-source, border, thin-edge,
   identity-edge, motion, and foreign-extent tests.
4. Prove every raw input and output allocation from the contract constants;
   remove stale literal dimensions from active RF10 paths.
5. Run cold/headless and conventional product tests to prove the schema change
   does not pull training or inference dependencies into authority products.

**Stop condition:** do not render targets while any producer, consumer, file,
or diagnostic can silently accept an older extent.

## RF10-B — Native 720p target gate

1. Render a fresh static pair using native `256x144` source inputs and a direct
   native `1280x720` Cycles target. Never upscale an RF9 target.
2. Audit raw scene-linear HDR, display transform, texture filtering, Cycles
   sampling, material scale, thin geometry, glass, wet surfaces, emissives,
   shadows, reflections, and local contrast at 1:1 target pixels.
3. Verify camera, transforms, visibility, stable identity, target depth, target
   normal, and source-to-target alignment at the new mapping.
4. Repeat from an absent root and record source and renderer reproducibility.
5. Produce a review sheet containing native source, direct deterministic 5x
   baselines, native target, identity/depth/alignment evidence, and selected
   1:1 crops. Require explicit human target approval before corpus generation.

**Stop condition:** if the direct native target is soft or inconsistent, fix
target production rather than train a model to reproduce the defect.

## RF10-C — Fresh corpus and authorization

1. Start from the proven RF9 visual-cause matrix—camera distance and angle,
   layouts, urban/copper/wet material variants, daylight/evening/night,
   characters, vehicle articulation, props, occlusion, lighting, and exact
   material ambiguity—but execute every pair anew at RF10 extents.
2. Expand causes when the target audit exposes a new 720p-specific failure;
   do not add adjacent frames merely to inflate corpus size.
3. Assign complete sequences to controlled-fit, train, validation, sealed
   test, and stress ownership before training. No frame crosses split owners.
4. Reprove that material-ambiguity pairs have identical RF10 raster inputs,
   camera, geometry, and lighting controls except `material_palette`, while
   every corresponding rich target differs.
5. Verify rights, hashes, stable identities, target provenance, exact pair
   correspondence, and review-material exclusion. Training authorization reads
   no sealed-test pixels.

**Stop condition:** absent visual causes require new data, not a larger model.

## RF10-D — Controlled fit and architecture entry

1. Begin from a newly initialized RF10 configuration. Reuse the small RF9
   bilinear-refinement topology only as a code/architecture baseline; load no
   RF9 tensor or optimizer state.
2. Implement the direct 5x mapping with one native `1280x720` output. Full-frame
   native supervision remains the primary contract; crops may supplement loss
   ownership but cannot replace complete-frame evaluation.
3. Fit one controlled sequence and inspect every frame for structure,
   identity, palette response, texture, thin edges, emissive behavior, negative
   radiance, and ringing.
4. Record parameter count, initializer digest, tensor ancestry, MPS training
   time, process memory, checkpoint recovery, and export-shape feasibility.
5. Change reconstruction or capacity only if controlled-fit evidence localizes
   a concrete failure to the model rather than target, data, conditioning, or
   decoding.

**Stop condition:** no held-out campaign begins until the complete native
pipeline can deliberately fit its controlled sequence.

## RF10-E — Held-out spatial selection

1. Train all candidates from declared random initializers on RF10 training
   sequences only.
2. Select checkpoint and candidate using validation only. Preserve nearest,
   bilinear, bicubic, appearance-only, no-semantic, no-instance,
   no-material-palette, and no-global-control evidence.
3. Measure scene-linear color, display diagnostic error, log luminance,
   chroma, gradient, high frequency, Laplacian, local contrast, semantic and
   instance boundaries, negative radiance, and structured artifacts.
4. Review every validation frame plus declared worst texture, thin-feature,
   material, glass, emissive, wet-night, character, vehicle, and occlusion
   crop at native scale.
5. Add capacity, a learned feature pyramid, structural raster, or detail
   objective only as a one-factor response to measured RF10 evidence. RF9's
   rejected candidates receive no presumption of value at the new mapping.

**Stop condition:** freeze one immutable candidate before any test pixel is
decoded. If no candidate is visually acceptable, reject the campaign without
opening test.

## RF10-F — Sealed test and new stress

1. Open the sealed test exactly once after immutable validation selection.
2. Execute a second opening and require rejection before pixel decoding.
3. After selection, manufacture a new stress root for unrepresented near-edge,
   high-angle, wet/night, fast-view, articulation, occlusion, material-swap,
   and lighting-response pressure. This root is not selection data.
4. Inspect every test and stress frame and retain complete numerical,
   per-cause, full-frame, crop, ablation, timing, and failure evidence.
5. Classify failures by target, correspondence, coverage, conditioning,
   architecture, objective, runtime, or unknown rather than averaging them
   into one score.

**Stop condition:** export is forbidden when sealed or stress evidence reveals
structure replacement, identity drift, wrong material intent, collapse, or an
unexplained systematic artifact.

## RF10-G — Core ML and playable 720p trial

1. Export the exact accepted checkpoint to a new external RF10 Core ML bundle.
2. Verify wrapper and Core ML numerical agreement on declared validation and
   fresh stress frames before engine execution.
3. Fail closed on bundle kind, schema, input/output shapes, preprocessing,
   vocabularies, control ranges, package inventory, source lineage, and every
   digest.
4. Run a deterministic graphical Metal gate, then the interactive fixture and
   default sandbox where supported. Exercise `N`, conventional fallback,
   resize, camera cut, inference failure, and clean shutdown.
5. Present the neural scene at native centered `1280x720`; verify pixel bounds
   from screenshots rather than relying only on metadata.
6. Record source and presented frame lineage, unknown categories, inference
   time, staged time, memory/residency where observable, failures, fixed native
   dimensions, and incident linkage.
7. Retain an automatic side-by-side evidence image made directly from the
   native `256x144` source and native `1280x720` output. It is diagnostic, not
   training material.

**Stop condition:** a numerically valid export is insufficient if the actual
Mac runtime stretches, crops unexpectedly, presents stale frames, fails
fallback, or cannot retain useful diagnostic evidence.

## RF10-H — Product review and conclusion

Human review answers these separately:

1. Is the native `1280x720` output large enough and correctly centered on the
   MacBook without display stretching?
2. Is it materially sharper and less fuzzy than the previous experience?
3. Does it faithfully preserve authored geometry, identity, material intent,
   lighting response, and state?
4. Which remaining defects are spatial, temporal, content, conditioning, or
   runtime problems?
5. Is the result accepted as another external trial, rejected, or ready to
   enter a separately planned promotion phase?

Acceptance does not automatically promote the model or start NR6. Those are
separate decisions based on the resulting evidence.

## Required review layout

Every validation, test, and stress review uses only RF10-native evidence:

```text
256x144 cheap appearance shown nearest-neighbor for inspection
direct deterministic nearest/bilinear/bicubic 256x144 -> 1280x720 baselines
current RF10 model output at native 1280x720
direct Cycles target at native 1280x720
error, boundary, identity, material-control, and selected native 1:1 crops
```

RF9 screenshots may appear only in a clearly labeled historical narrative,
never in an RF10 acceptance sheet or metric calculation.

## Artifact strategy

Git owns this plan, executable contracts and tools, small experiment
definitions, validation conclusions, and later deliberately promoted content.
The external neural-rendering root owns every RF10 capture, target, corpus,
checkpoint, optimizer state, exhaustive review frame, evaluation, export, and
trial bundle.

Suggested immutable external roots use descriptive RF10 IDs, for example:

```text
.../experiments/rf10-native-720p-target-<timestamp>
.../experiments/rf10-native-720p-corpus-<timestamp>
.../experiments/rf10-native-720p-campaign-<timestamp>
.../trial-bundles/rf10-native-720p-<timestamp>
```

Runtime never discovers the newest root. Every command receives an explicit
absolute path, and every generated root begins absent or resumes only through
an exact recorded lineage.

## Critical path

```text
RF10-A coordinated native ABI
  -> RF10-B direct 720p target approval
  -> RF10-C fresh paired corpus and sealed authorization
  -> RF10-D controlled random-origin fit
  -> RF10-E validation-only held-out selection
  -> RF10-F one test opening and new post-selection stress
  -> RF10-G exact Core ML and native live trial
  -> RF10-H product disposition
```

The implementation is complete through the external playable trial. The
accepted evidence, measurements, known limitations, rejected harness attempts,
and exact reproduction commands live in
[RF10 Native 720p Spatial Validation](../validation/rf10-native-720p-spatial.md).
No model promotion or temporal phase is implied by this conclusion.
