# RF9 Spatial Quality Expansion

**Status:** Planned; RF8 remains the accepted external spatial baseline

**Date:** 2026-08-12

**North star:**
[Title Neural Renderer North Star](title-neural-renderer-north-star.md)

**Architectural decisions:**
[ADR-025](../adr/025-game-specific-neural-rendering-boundary.md) and
[ADR-026](../adr/026-from-scratch-title-neural-renderer.md)

**Baseline evidence:**
[RF8 Direct 640x360 Spatial Sharpness Validation](../validation/rf8-direct-640x360-spatial-sharpness.md)

## Outcome

RF9 improves the perceptual fidelity, sharpness, material response, and scene
coverage of the title-owned spatial neural renderer before causal temporal
modeling begins. It keeps one direct native contract:

```text
native 160x90 deterministic presentation inputs
  -> one title-specific model trained from random initialization
  -> native 640x360 scene-linear HDR output
```

RF9 does not change the display resolution, introduce an intermediate image,
or reuse target pixels from an earlier cohort. It answers the quality questions
in dependency order:

1. Is the native rich target itself sharp and visually worth learning?
2. Does the paired corpus cover enough independent visual causes?
3. Do the deterministic inputs contain the facts needed to select the target?
4. Does learned multi-scale reconstruction recover detail better than RF8's
   bilinear feature expansion?
5. Does additional capacity improve held-out evidence rather than memorization?
6. Does a dedicated title-trained detail path add useful richness without
   changing authored structure?

NR6 remains deferred until RF9 establishes the spatial quality ceiling and
records which remaining defects are genuinely temporal.

## RF8 baseline and measured pressure points

RF8 is frozen comparison evidence, not a checkpoint ancestor. It established:

- `108` fresh native pairs across six whole sequences;
- approximately `36` training-owned frames from a narrow single fixture;
- a `1,060,987`-parameter spatial model;
- validation MAE `0.010595`, sealed-test MAE `0.015272`, and stress MAE
  `0.012508`;
- exact export agreement and a successful external Core ML/Metal trial; and
- a centered, unscaled native `640x360` product presentation.

Its observed limitations are:

- localized high-contrast and emissive edge noise or ringing;
- softened fine geometry and texture;
- limited material and scene diversity;
- possible ambiguity because material, surface, and local-light facts are not
  explicit spatial inputs; and
- a simple bilinear feature enlargement followed by output-grid refinement.

Those findings do not prove that parameter count is the primary bottleneck.
RF9 therefore does not begin by making the RF8 model larger.

## Fixed decisions and non-goals

### Fixed for the full phase

- Native cheap appearance and existing raster inputs remain `160x90` unless a
  controlled input ablation explicitly authorizes one structural channel at a
  different extent.
- Target and neural output remain direct native `640x360` scene-linear HDR.
- No `400x225`, `800x450`, or `1600x900` image may be an input, target,
  intermediate rendered image, supervision signal, comparison source, export
  handoff, or runtime neural surface.
- Every learned component starts from declared random initialization and uses
  title-owned paired data only.
- RF8 remains an immutable baseline. RF9 candidates receive no RF8 weights.
- Gameplay authority, collision, navigation, networking, UI, text, editor
  chrome, and diagnostics remain outside neural inference.
- Validation selects candidates. The sealed test opens once only after one
  immutable selection. Stress remains separate from selection and test.

### Not part of RF9

- temporal history, recurrent inference, frame generation, or interpolation;
- promotion or installation as selected game content;
- a generic asset, scene, shader-graph, or DCC authoring system;
- pretrained perceptual, image, video, VAE, discriminator, or foundation
  weights;
- arbitrary parameter, dataset, latency, or memory ceilings; or
- performance optimization that does not unblock quality evaluation.

Internal learned feature pyramids are permitted. They are model activations,
not intermediate rendered images, targets, or independent presentation stages.

## Quality hypotheses in priority order

### H1: Target quality is the upper bound

The model cannot recover texture, material response, or edge definition absent
from the native target. Target generation must be audited before model work for:

- native texture sharpness and filtering;
- Cycles sampling and denoising effects on fine detail;
- material scale, UV behavior, roughness, metallic, glass, and emissive response;
- shadow, reflection, exposure, and local-light quality;
- thin geometry, small props, character parts, wheels, and high-contrast edges;
  and
- exact correspondence with the cheap presentation event.

### H2: Coverage is the largest current limitation

Adjacent frames from one camera path are not equivalent to independent visual
coverage. The corpus should expand by distinct causes:

- near, medium, distant, elevated, obstructed, and unusual valid cameras;
- multiple environment layouts and surface arrangements;
- repeated geometry with different materials and repeated materials on
  different geometry;
- multiple characters and vehicles, including shared materials and state
  changes;
- sun, world, local-light, emissive, exposure, and declared effect variations;
- partial visibility, overlap, thin features, glass, reflections, and shadows;
  and
- playable interaction states such as vehicle articulation, carryables,
  hostility, damage, death, respawn, and population activity.

Corpus growth follows demonstrated coverage needs. RF9 sets no arbitrary image
count. Every added sequence must own a declared visual cause, provenance,
split, and reason for inclusion.

### H3: Missing deterministic facts cause avoidable averaging

RF8 knows appearance, depth, normals, motion/history validity, semantic
identity, instance identity, and four global controls. It may still lack the
facts needed to distinguish desired materials and local responses. Candidate
conditioning additions are:

- material and asset/part identity;
- stable UV or another surface-coordinate representation;
- compact roughness, metallic, emissive, opacity, or material-class values;
- direct-light, shadow-visibility, or local-effect features; and
- one cheap higher-resolution structural raster such as coverage, depth,
  normal, or identity when low-resolution sampling destroys a proven edge.

No channel is accepted because it seems useful. Each addition must have one
controlled ambiguity fixture, a complete ablation, measured benefit, and a
declared raster/storage/runtime cost. Private gameplay state and raw authority
handles remain forbidden.

### H4: RF8's reconstruction path establishes a smooth prior

RF8 bilinearly enlarges low-resolution feature maps before native-grid
refinement. RF9 should compare it with direct learned multi-scale feature
reconstruction:

```text
160x90 encoded features
  -> learned 320x180 features
  -> learned 640x360 features
  -> one native 640x360 scene-color result
```

Candidate blocks include resize-convolution, pixel shuffle, multi-scale skip
fusion, structural fusion at each scale, and separate low-frequency color and
high-frequency residual predictions. Checkerboard behavior, boundary ringing,
negative radiance, and Core ML exportability are explicit gates.

### H5: Capacity helps only after data and conditioning

Once the target, corpus, inputs, and learned reconstruction are accepted, RF9
runs a controlled capacity sweep. The sweep compares the smallest meaningful
changes rather than jumping to an arbitrary large model:

- RF8-equivalent capacity on the accepted RF9 data and inputs;
- wider low-resolution context;
- deeper native-output refinement;
- a larger structural branch; and
- one combined candidate only if the isolated changes justify it.

Capacity is useful when training, validation, per-kind evidence, and human
review improve together. Lower training loss with flat or worse validation is
memorization evidence and rejects the larger candidate.

### H6: Important detail occupies too few pixels

Full-frame objectives are dominated by large easy regions. RF9 should add
auditable crop and sampling ownership for:

- semantic and instance boundaries;
- thin and small geometry;
- emissive and high-contrast regions;
- glass and reflections;
- faces, limbs, wheels, lights, and props; and
- regions where the selected baseline has the greatest target residual.

Sampling may rebalance existing truth; it cannot crop away hard frames from
evaluation or allow one frame to cross split ownership.

### H7: A learned detail residual may be required

Only after H1 through H6 are measured may RF9 add an optional detail path. It
receives the accepted structural reconstruction and the same deterministic
controls, and predicts only missing high-frequency material, texture, lighting,
or effect detail.

Possible experiments are a frequency-separated residual head, a small
title-trained discriminator, or a small conditional flow objective. Every
learned dependency begins from random initialization on the same title corpus.
The detail path is rejected if it improves richness while degrading geometry,
identity, color responsiveness, edges, or deterministic repeatability.

## Implementation phases

| Phase | Status | Purpose | Exit gate |
|---|---|---|---|
| RF9-A | Planned | Freeze baseline and build failure atlas | Every RF8 defect is localized by frame, region, visual kind, likely owner, and metric; no test pixels opened |
| RF9-B | Planned | Audit and improve native targets | Accepted `640x360` targets are visibly sharper and retain exact correspondence; filtering/denoising/material decisions are recorded |
| RF9-C | Planned | Expand scene and state coverage | Coverage matrix spans declared cameras, layouts, materials, actors, vehicles, interactions, and lighting causes with whole-sequence split ownership |
| RF9-D | Planned | Resolve input ambiguity | Each proposed conditioning channel has a controlled fixture and ablation; only proven channels advance the schema as one greenfield cohort |
| RF9-E | Planned | Learn multi-scale direct reconstruction | One direct `160x90 -> 640x360` feature-reconstruction candidate beats the RF8 architecture on validation and complete visual evidence without new artifacts |
| RF9-F | Planned | Measure capacity and detail sampling | Validation establishes whether capacity or spatial sampling is limiting; one configuration is selected without opening test |
| RF9-G | Conditional | Add title-trained detail residual | Execute only if the selected deterministic model remains perceptually smooth; richness improves without structural substitution |
| RF9-H | Planned | Seal conclusion and playable trial | Test opens once, fresh stress passes, export agrees, live Core ML trial works, and human review records the spatial disposition |

## Phase details

### RF9-A — Baseline failure atlas

1. Reinspect every RF8 validation and stress frame at native scale and enlarged
   nearest-neighbor crops.
2. Classify failures as target, correspondence, coverage, conditioning,
   reconstruction, capacity, loss/sampling, display-transform, or unknown.
3. Retain exact frame and region coordinates, semantic/instance/material IDs,
   model residuals, and relevant auxiliary input crops.
4. Add dedicated challenge fixtures only for repeatable failures.
5. Freeze RF8 checkpoint, bundle, metrics, and evidence digests as comparison
   inputs; do not use RF8 weights as ancestry.

**Stop condition:** do not change the model until target defects and missing
coverage are distinguishable from model defects.

### RF9-B — Native target quality gate

1. Audit native `640x360` Cycles truth before training.
2. Improve only title-owned textures, materials, modest geometry, lighting, and
   target-render settings needed by observed failures.
3. Compare raw and denoised target evidence where denoising may erase detail.
4. Exercise repeated geometry/material swaps so art richness is not tied to one
   instance.
5. Require product-owner review of the complete native target sheet.

**Stop condition:** if the target itself remains fuzzy or inconsistent, revise
the target rather than training a larger model.

### RF9-C — Coverage expansion

1. Define a coverage manifest by visual cause, not frame count.
2. Manufacture exact native pairs from distinct deterministic scenarios.
3. Assign whole sequences to controlled-fit, train, validation, sealed test,
   and fresh stress before training.
4. Verify pair alignment, rights, stable identity, material/state variation,
   and capture reproducibility.
5. Publish train/validation review evidence while keeping sealed-test pixels
   inaccessible.

**Stop condition:** if new validation failures map to absent training causes,
expand coverage before changing architecture.

### RF9-D — Conditioning ablations

1. Create ambiguity fixtures where identical current inputs require different
   rich outputs.
2. Add the smallest deterministic signal that makes each mapping observable.
3. Train full and ablated branches from equivalent random initialization.
4. Compare color, boundary, material consistency, identity, and per-fixture
   evidence.
5. Advance every engine producer, capture, target adapter, dataset, model,
   exporter, runtime consumer, diagnostic, test, and document together when a
   signal is accepted. No compatibility decoder is retained.

**Stop condition:** reject channels that do not materially improve their
declared ambiguity case or whose cost outweighs the measured benefit.

### RF9-E — Multi-scale feature reconstruction

1. Keep one final native output and direct supervision path.
2. Compare RF8's bilinear feature expansion with learned multi-scale feature
   reconstruction under the same accepted data and conditioning.
3. Fuse structural information at each learned scale.
4. Measure thin edges, local contrast, Laplacian bands, high-frequency error,
   color, negative radiance, checkerboard energy, and human-visible crops.
5. Prove TorchScript/Core ML conversion before investing in a long selection
   run.

**Stop condition:** retain the simpler RF8 reconstruction if the learned path
does not improve held-out sharpness or introduces structured artifacts.

### RF9-F — Capacity and sampling conclusion

1. Run one-factor capacity comparisons on validation.
2. Add boundary/detail/error-aware training crops without changing evaluation
   coverage.
3. Record training fit, validation generalization, model size, activation
   memory, inference timing, and per-kind quality separately.
4. Select one candidate using immutable validation evidence and complete human
   review.

**Stop condition:** stop scaling when validation or human quality ceases to
improve, even if training loss continues downward.

### RF9-G — Conditional learned detail path

1. Authorize this phase only with retained evidence that the accepted RF9-F
   candidate remains structurally correct but perceptually over-smoothed.
2. Begin every detail component from random initialization.
3. Keep structural output directly supervised and separately inspectable.
4. Evaluate the detail path enabled and disabled on every frame.
5. Reject any result that repaints geometry, identity, material selection,
   lighting response, or deterministic state.

**Stop condition:** an attractive image is insufficient; faithful authored
state and repeatable rendering remain mandatory.

### RF9-H — Final spatial disposition

1. Freeze one validation-selected checkpoint and its complete lineage.
2. Open the sealed test exactly once and prove a second opening is rejected.
3. Manufacture and evaluate a fresh stress cohort after selection.
4. Verify export agreement and create an explicit external, unpromoted Core ML
   trial bundle.
5. Exercise the playable fixture and default sandbox where supported, including
   neural/conventional toggle, fallback, frame lineage, diagnostics, incident
   capture, fixed native presentation, and long interactive movement.
6. Record product-owner review and classify remaining failures as spatial,
   temporal, content, conditioning, runtime, or unknown.

**Exit:** RF9 either selects a materially improved external spatial trial or
retains RF8 with an evidence-backed explanation. Only then is NR6 replanned
against the remaining measured temporal failures.

## Evaluation contract

### Automated evidence

Every selected candidate reports, at minimum:

- scene-linear HDR MAE/MSE and per-channel error;
- display-space diagnostic error;
- log-luminance and chroma error;
- gradient, high-frequency, Laplacian, and local-contrast error;
- semantic, instance, material, and geometry-boundary error where available;
- negative-radiance fraction and structured/checkerboard artifact measures;
- per-kind and per-challenge-region results, not only global aggregates;
- all-input and accepted-channel ablations;
- random-origin, checkpoint, dataset, code, target, schema, and export digests;
  and
- model parameters, package bytes, activation/process memory, inference timing,
  staged timing, and failures as separate measurements.

Metrics rank evidence; they do not replace full-frame and crop review.

### Human evidence

Review sheets present the same native event as:

```text
160x90 cheap appearance shown nearest-neighbor
deterministic 4x resize baseline
RF8 frozen output
current RF9 candidate
native 640x360 rich target
error, boundary, material, and identity diagnostics
```

Review covers every validation and stress frame plus declared challenge crops.
The sealed test is not included until after immutable selection and its single
opening.

### Playable evidence

The graphical trial must expose:

- active bundle/checkpoint/schema/dataset identity;
- source and presented frame lineage;
- neural/conventional mode and fallback reason;
- unknown categorical inputs and inference failures;
- native `160x90` input inspection;
- fixed centered `640x360` neural scene with black surround; and
- incident linkage sufficient to retain the inputs, result, diagnostics, and
  human anomaly timestamp for a failed frame.

## Artifact and repository strategy

Git owns:

- this plan and later validation disposition;
- experiment definitions and executable source;
- schema, architecture, dataset, metric, export, and runtime code;
- small review summaries and exact external artifact paths; and
- changes to the neural-rendering skill when the accepted operating contract
  changes.

The external neural-rendering artifact root owns:

- native paired frames and manifests;
- crops, reports, and complete visual evidence;
- random initializers, training checkpoints, optimizer state, and exports;
- trial bundles and graphical evidence; and
- immutable run/environment/provenance records.

Generated datasets, checkpoints, exhaustive frames, and model bundles never
enter Git. Runtime never discovers a mutable or newest experiment.

## Recommended execution order

The critical path is:

```text
RF9-A failure atlas
  -> RF9-B target quality
  -> RF9-C coverage
  -> RF9-D conditioning
  -> RF9-E reconstruction
  -> RF9-F capacity and sampling
  -> RF9-G only if smoothing remains
  -> RF9-H sealed conclusion and live trial
```

The next implementation action is RF9-A, not a larger model. It establishes
whether each visible defect belongs to target content, missing data, missing
conditioning, or the reconstruction architecture before more training cost or
model capacity is introduced.
