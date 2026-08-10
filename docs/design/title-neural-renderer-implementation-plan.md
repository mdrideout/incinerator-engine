# Title Neural Renderer Implementation Plan

**Status:** NR-0004 and NR5-A/B accepted; NR5-C held-out structural renderer is
next

**Date:** 2026-08-08

**North star:**
[Title Neural Renderer North Star](title-neural-renderer-north-star.md)

**Decisions:**
[ADR-025](../adr/025-game-specific-neural-rendering-boundary.md) and
[ADR-026](../adr/026-from-scratch-title-neural-renderer.md)

**Validation ledger:**
[`../validation/nr0-neural-rendering-feasibility.md`](../validation/nr0-neural-rendering-feasibility.md)

## Outcome

Build the smallest complete Incinerator-owned path through which a title can:

1. produce a cheap deterministic render and explicit presentation controls;
2. render the exact same scene state as a materially richer reference;
3. assemble an inspectable, rights-attributed paired sequence corpus;
4. initialize and train a title renderer without inherited learned weights;
5. evaluate spatial, structural, temporal, and visual-detail behavior;
6. deliberately promote one immutable accepted export; and
7. run that exact bundle on Apple Silicon macOS with truthful fallback and
   diagnostics.

The first usable proof is not “a model ran.” It is one material-rich moving
scene in which the output becomes substantially richer while every authored
object, camera, pose, visibility decision, and event remains faithful.

## Current baseline

NR0-A through NR0-D already provide the engine-owned presentation seam,
six-buffer `incinerator.neural-input.v1` capture, a 17-plane spatial dataset,
random-initialization model training, Core ML export, deterministic stress
camera paths, and exhaustive failure analysis. NR-0003 proves that a larger
video prior can run at the requested local proof rate and also proves that
appearance-only conditioning cannot safely own a large visual transformation.

The conventional capture target remains an aligned flat-color render and must
not be used as title-training truth. NR4-A adds one exact, rights-clean,
high-fidelity Cycles still plus identity/depth/normal evidence and its visual
direction was human-accepted at its historical extent. NR4-B extends that
adapter through six causally isolated moving segments and a two-run technical
proof. That acceptance does not carry into the active cohort. Native target
re-acceptance, ambiguity-driven controls, corpus assembly, and coverage
acceptance remain open.

## Non-negotiable boundaries

- Deterministic simulation remains the only authority. Neural output is
  presentation-only and disposable.
- Promotion-eligible learned weights begin from a recorded random
  initialization and train only on title-owned or explicitly approved data.
- Pretrained models may be comparison evidence only. They cannot initialize,
  teach, score a training loss, produce pseudo-targets, or enter a promoted
  lineage.
- A target pair describes the same tick, camera, transforms, animation, effect
  phase, exposure, identities, and intended visibility. An attractive
  reinterpretation is invalid data.
- Missing information is added as deterministic presentation data; the model
  is not asked to guess authority state.
- Generated captures, targets, datasets, checkpoints, exhaustive reports, and
  exports remain beneath an explicit external artifact root. Git stores the
  contracts, tools, small fixture source, experiment intent, conclusions, and
  selected runtime content only after promotion.
- Runtime, graphical fallback, headless, validation, and server products do not
  acquire Blender, Python, PyTorch, or training-package dependencies.
- The implementation targets Apple Silicon macOS. No secondary-platform
  inference abstraction is introduced in this sequence.
- Each schema advances as one coordinated cohort with no compatibility decoder.
- No unmeasured dataset, model, memory, time, history, or frame-rate cap is
  invented. Real resource failures and measured product envelopes drive later
  constraints.

## Critical-path decisions

### NR-0004 target producer

Use **Blender/Cycles as the first offline high-fidelity target adapter**.

This is an NR-0004 experiment choice, not a permanent engine dependency or a
universal target-renderer abstraction. It is selected because it is open,
mature, scriptable, deterministic enough to fingerprint and reproduce under a
declared configuration, capable of producing linear HDR and identity/depth
evidence, and able to use Metal on the target Mac. Slow target generation is
acceptable because it manufactures training truth rather than shipping frames.

The first target scene uses repository-owned procedural geometry, materials,
lighting, and effects. External art assets are not required for the initial
proof. This keeps rights and exact correspondence auditable. Later title assets
may replace the fixture through a separately reviewed source manifest.

### Shared frame truth

Incinerator remains the owner of frame state. For selected presentation frames,
an offline export records the camera, projection, stable draw identities,
transforms, mesh/asset references, material references, exposure, effect state,
and source fingerprints. The Blender adapter consumes that exact package; it
does not recreate gameplay or advance simulation.

The target adapter emits:

- canonical linear scene color in OpenEXR;
- a declared display transform and a human-viewable derivative;
- stable identity/object coverage evidence;
- target depth and, where useful, normal evidence for alignment diagnosis; and
- exact Blender, Cycles, script, scene, asset, material, and configuration
  fingerprints.

Metadata and source identity must match exactly. Raster-edge differences are
measured and visualized rather than hidden behind an invented pass threshold.
No pair is accepted with an unexplained camera, object, pose, visibility, or
identity mismatch.

### NR4-C working resolution

The next implementation cohort uses `160×90` cheap appearance and initially
`160×90` controls to produce a `400×225` high-fidelity target. Both extents are
16:9. The 2.5× linear / 6.25× pixel reconstruction is explicit in the schema,
capture manifests, resampling convention, dataset, model, reports, and tests.

NR4-C-through-NR5 work uses only this exact resolution pair. NR4-A/B remain
immutable historical records of the target-adapter and
correspondence work, but their pixels, metrics, and visual acceptance do not
participate in this cohort. NR4-C regenerates the exact still and causal moving
sequence with native `160×90` inputs and direct native `400×225` Cycles targets.
The `400×225` target direction receives fresh human acceptance on its own terms.
No resampled or native artifact from another resolution is an input, target,
comparison, preview, quality reference, acceptance gate, or training material.

All controls begin at `160×90`. NR4-C may retain an individual structural
channel at `400×225` only after an ablation demonstrates a concrete edge,
identity, motion, or disocclusion benefit and records its measured GPU,
storage, and training cost.

Human comparison presents the native `160×90` inputs, a declared deterministic
`160×90 → 400×225` resize baseline, the native `400×225` target, and once a
model exists, its native `400×225` output. A viewer may zoom these panes for
legibility, but it does not emit or retain a different-resolution artifact.

### First title slice

Build one bounded urban-corner presentation fixture containing:

- static depth layers, long edges, thin geometry, and repeated occlusion;
- one character, one NPC, one vehicle with articulated wheels, and one prop;
- pavement, masonry, painted metal, rubber, glass, emissive, and patterned
  material responses;
- one controlled sun/sky state, a shadow boundary, and a local emissive source;
- one deterministic responsive effect only after its phase and coverage can be
  represented explicitly; and
- camera motion, a near pass, a disocclusion, a cut, and a resize.

The cheap path may use simpler shading and lower-frequency appearance, but it
must preserve the scene's authored structure. The target supplies the richer
materials, lighting, shadows, reflections, and applicable effect treatment.

This is a training/evaluation fixture, not a new gameplay map, generic scene
format, or replacement for the S13 sandbox.

## Ownership and intended locations

| Owner | Existing or intended location | Responsibility |
|---|---|---|
| Presentation contract | `src/engine/contracts/neural_rendering.zig` | Versioned channel, frame, identity, surface, material, lighting, and reset semantics only |
| Cheap GPU inputs | `src/hosts/neural_input_host.zig` plus neural shaders | Render the exact declared input targets from immutable draw records |
| Paired capture | `src/hosts/neural_capture_host.zig` | Fence and capture one exact presentation event; write atomic manifests and canonical raw inputs |
| Evaluation scene | `src/hosts/neural_evaluation_fixture.zig` and `fixtures/nr0_neural_renderer/` | Small, rights-clean fixture source and deterministic camera/effect programs |
| Target frame export | `src/hosts/` capture owner plus offline serializer | Export presentation state needed by the target producer without authority access |
| Blender target adapter | `tools/neural-rendering/targets/blender/` | Reconstruct the declared frame, render target/evidence passes, and record provenance |
| Dataset framework | `tools/neural-rendering/title_renderer/` | Validate, assemble, split, load, inspect, and digest the new paired corpus |
| Model framework | `tools/neural-rendering/title_renderer/models/` | Repository-defined architectures and deterministic initialization |
| Training/evaluation | `tools/neural-rendering/title_renderer/` | Train, resume through explicit lineage, compare, report, export, and conclude |
| Experiment intent | `experiments/neural-rendering/nr-NNNN-*/` | Question, exact configuration, cohort ownership, conclusion, and external evidence link |
| Live diagnostics | `src/editor/tools/neural_rendering_lab_tool.zig` | Inspect source, target, controls, model output, errors, history, identity, timing, and fallback |
| Runtime orchestration | `src/hosts/neural_rendering_host.zig` | Selected-model sequencing, history, inference/fallback, and composition |
| macOS backend | `src/adapters/neural_rendering/` | GPU resources, inference submission, synchronization, and backend diagnostics |
| Promoted content | `models/neural-rendering/` and `src/content/` | Exact immutable bundle, validation, installation, and explicit selection |

These paths identify responsibilities. A phase creates a path only when it has
a real consumer. Existing NR-0001/2/3 tools remain historical evidence and are
not reorganized merely for uniformity.

## Delivery board

| Order | Work package | Status | Depends on | Review gate |
|---:|---|---|---|---|
| 1 | NR4-A exact target still | **Accepted historical proof** | Accepted north star | Adapter, alignment, and human target review passed at its original extent |
| 2 | NR4-B material-rich moving target | **Accepted historical proof** | Human-accepted NR4-A | Causal sequence and correspondence method passed at its original extent |
| 3 | NR4-C native cohort reset, ambiguity audit, and input schema | **Accepted** | NR4-A/B adapter and causal-scenario methods | Native `160×90 → 400×225` still/sequence accepted; mapping and every new signal have demonstrated use |
| 4 | NR4-D paired capture and corpus assembly | **Technical gate passed** | NR4-C | Atomic provenance, split, and recapture proof |
| 5 | NR4-E coverage and corpus acceptance | **Accepted for NR5-A/B scope** | NR4-D | NR-0004 accepted with explicit gaps and sealed test |
| 6 | NR5-A title-training framework | **Accepted** | NR4 accepted | Clean-room/random-origin contracts pass |
| 7 | NR5-B controlled spatial overfit | **Accepted** | NR5-A | One sequence is faithfully reconstructed |
| 8 | NR5-C held-out structural renderer | Planned | NR5-B | Structure and material gains survive held-out views |
| 9 | NR5-D ablation and candidate conclusion | Planned | NR5-C | NR-0005 accepted or rejected, never auto-promoted |
| 10 | NR6 causal temporal renderer | Planned | NR5 accepted | Motion, reset, drift, and responsiveness pass |
| 11 | NR7 learned-detail residual | Conditional | Measured NR6 richness ceiling | Richness improves without structural substitution |
| 12 | NR0-E explicit promotion | Blocked | Promotion-worthy candidate | Immutable source-preserving selection |
| 13 | NR0-F installed macOS runtime | Blocked | NR0-E | Exact GPU-resident bundle and fallback behavior |
| 14 | NR0-G acceptance and audit | Blocked | NR0-F | End-to-end accepted or rejected with evidence |

## NR-0004 — High-fidelity target and corpus foundation

NR-0004 contains no promotion-eligible model training. Its product is trusted
data and the evidence needed to train against it.

### NR4-A — Exact target still

1. Record the exact Blender release, Python API, Cycles device/configuration,
   color management, sampling, and environment in the experiment definition.
   Disable learned denoising for NR-0004; high-sample Cycles output is the
   reference so no external learned denoiser enters target provenance.
2. Define a minimal target-frame package from existing immutable presentation
   records. Keep the format specific to this adapter until a second producer
   demonstrates a shared abstraction.
3. Export one static fixture frame with camera/projection matrices, stable draw
   identities, mesh kinds, transforms, base material assignments, lighting,
   exposure, and complete source fingerprints.
4. Reconstruct and render the exact frame through Blender/Cycles.
5. Emit linear HDR color, display preview, identity, depth, and alignment
   report artifacts into a new external run root.
6. Add an inspector that rejects incomplete manifests, digest mismatch,
   missing identity coverage, stale source, non-finite data, or inconsistent
   dimensions/conventions.
7. Produce a side-by-side source/target/identity/depth/alignment report.

**Exit evidence**

- One frame can be regenerated from an absent output root using only declared
  repository source and the pinned offline environment.
- Camera, transform, object, material, light, identity, and target provenance
  are exact and inspectable.
- Source and target show the same authored scene; every difference is intended
  rendering richness rather than state drift.
- A human explicitly accepts the target look before sequence generation.

This is the first required check-in. Training the wrong target more efficiently
has no value.

**Implementation checkpoint — 2026-08-08**

- `incinerator.nr4.blender-target-frame.v1` exports the same immutable camera,
  draw identity, transform, material assignment, lighting, exposure, and
  source lineage consumed by the cheap capture.
- The validation-only urban-corner fixture submits 26 paired draws at 400×225
  cheap input and 1600×900 target resolution. Ordinary sandbox draws are
  excluded only while this explicit target fixture is active.
- Blender 4.5.12 LTS and Cycles Metal are exactly pinned; 256 samples,
  deterministic seed 73, no adaptive sampling, no learned denoising, and no
  external art or pretrained weights are recorded in every target manifest.
- Two fresh absent-root proofs reproduced engine camera, effects, identities,
  six inputs, conventional target, normalized frame package, target identity,
  and target depth exactly. Both measured 0.975158 exact identity-over-union.
- Cycles' two GPU executions differed by at most one display-code value; target
  normal differences had 4.768e-7 maximum absolute error and 1.148e-8 RMSE.
  These measured renderer-float differences are recorded, not hidden behind a
  pass threshold.
- Canonical external evidence is retained at
  `~/Library/Application Support/Incinerator/neural-rendering/experiments/nr4-a-technical-20260808-v2`.
  Start with `acceptance.json`, `reproducibility.json`, and either run's
  `evaluation/nr4-a-review.png`.

The technical gate passed. On 2026-08-08 the product owner explicitly accepted
the upper-right high-fidelity target as a visual direction worth extending into
moving sequences, closing the NR4-A gate and authorizing NR4-B.

### NR4-B — Material-rich moving target

1. Extend the fixture with the declared material and lighting responses while
   retaining stable geometry and presentation identities.
2. Drive a short deterministic camera/object sequence from the existing
   capture-camera boundary. The Blender adapter consumes recorded frames; it
   never evaluates gameplay.
3. Add identity/depth correspondence reports for every frame and synchronized
   source/target video or contact sheets.
4. Test motion, near edges, wheel articulation, occlusion/disocclusion, and a
   lighting/effect transition separately so a failure has one cause.
5. Repeat the render from the same source package and compare declared logical
   state, provenance, and target artifact digests. If the renderer is not byte
   deterministic, record the measured numeric variation and preserve exact
   source identity rather than claiming byte identity.

**Exit evidence**

- The target is materially richer over motion, not just in one selected still.
- Stable objects do not change identity, pose, silhouette, or visibility for
  reasons absent from the presentation event.
- Temporal target variation follows authored camera, object, light, and effect
  changes rather than renderer noise.

**Implementation checkpoint — 2026-08-08**

- The adapter-local package advances without a compatibility decoder to
  `incinerator.nr4.blender-target-frame.v2`. It explicitly records material
  response, local-light state, and the causal segment/sample event while the
  engine-owned `incinerator.neural-input.v1` ABI remains deliberately unchanged.
- One 18-frame proof contains six independent three-sample segments:
  camera motion, rigid vehicle motion, a near-edge camera pass, wheel roll and
  front steering, NPC occlusion/disocclusion, and a sun/world/local/emissive
  transition. Segment starts are explicit history cuts.
- A machine causal audit proves that stable draw membership and identity never
  change and that each segment changes only its declared camera, object,
  articulation, NPC, or lighting/material owner.
- Every frame retains cheap input/canonical source, Cycles HDR/display,
  identity, depth, normal, alignment, and synchronized overview/detail contact
  sheets. No cheap-visible identity is omitted by the target.
- Two fresh executions reproduce all 18 engine captures, normalized target
  packages, target identity buffers, and target depth buffers exactly.
  Per-frame identity-over-union spans 0.974974–0.987851.
- Repeated Cycles display output varies by at most one 8-bit value; normal
  evidence varies by at most 5.960e-7 with at most 1.608e-8 RMSE. Authored
  target changes are materially larger: the subtle wheel segment reaches a
  local 77/255 display delta, while camera, object, occlusion, and lighting
  changes are unambiguous in the synchronized reports.
- Each run renders 18 1600×900 targets in 132.762 and 133.374 seconds of
  recorded Cycles time. This is offline truth-manufacturing cost, not runtime
  neural-renderer performance.
- The cheap conventional target hashes are identical across all three
  lighting-effect samples while the corresponding Cycles targets change. This
  is a concrete NR4-C ambiguity: the accepted v1 inputs do not encode the
  declared illumination/emissive cause strongly enough for a title renderer to
  reproduce it. It is evidence for investigation, not automatic authorization
  for any particular new channel.
- Canonical evidence is retained at
  `~/Library/Application Support/Incinerator/neural-rendering/experiments/nr4-b-technical-20260808-a`.
  Start with `acceptance.json`, `reproducibility.json`, and either run's
  `evaluation/reports/nr4-b-sequence-review.png` plus the six segment sheets.

The automated technical gate and agent visual audit pass. On 2026-08-08 the
product owner reviewed the synchronized overview supplied for approval and
explicitly accepted it, closing NR4-B and authorizing NR4-C. This accepts the
target direction and correspondence; it does not claim that a model has learned
the transformation.

### NR4-C — Native cohort reset, ambiguity audit, and schema advance

Do not copy the full candidate-channel wish list into the engine. Generate the
native cohort first, then use only that new target sequence to identify where
current inputs map one state to multiple target appearances or fail to preserve
important structure.

Begin by implementing and validating the native working cohort:

1. advance the new schema as one cohort with `160×90` cheap appearance and
   default controls plus a `400×225` linear-HDR target;
2. define exact top-left/pixel-center mapping for the 2.5× reconstruction and
   reject any producer, consumer, or artifact with mismatched extents;
3. generate and review a new native `400×225` Cycles still from the exact
   `160×90` source event; require fresh human target and alignment acceptance;
4. regenerate all 18 causal frames using the established scenario definitions,
   with native `160×90` inputs and direct native `400×225` targets; preserve
   frame, camera, identity, transform, material, and causal-event lineage while
   excluding all earlier target pixels and cross-resolution comparisons;
5. produce synchronized native source/target/alignment reports and record
   capture bytes, Cycles time, target time, GPU input-raster time where
   observable, dataset decode time, and process/GPU memory on the M2 Max; and
6. establish nearest, bilinear, and bicubic `160×90 → 400×225` baselines before
   any learned result is evaluated.

The native implementation is complete. Input schema v3, capture schema 4, and
target-frame schema v4 advance together. Capture stores the six native input
channels and four frame-global float32 controls; it does not emit a
conventional target that can be confused with high-fidelity truth. Two-run
still and 18-frame sequence gates pass from fresh absent roots, and every
current inspector fails closed on foreign extents. The direct target remains
scene-linear float32 OpenEXR at native `400×225`; reports and deterministic
resize baselines are display-only.

Executed roots:

```text
~/Library/Application Support/Incinerator/neural-rendering/experiments/nr4-c-native-still-20260808-b
~/Library/Application Support/Incinerator/neural-rendering/experiments/nr4-c-native-sequence-20260808-b
```

The executed native ambiguity audit found that lighting/material target changes
were absent from appearance, depth, normal, semantic, and instance. Motion B
alone changed because it is the history-validity bit, not a lighting owner. A
one-at-a-time ablation added four presentation-owned frame-global controls:
sun, world, local-light, and emissive strength. They resolve every observed
ambiguity for 16 bytes per frame with no new GPU raster target or pixel. The
product owner accepted the native target/alignment direction on 2026-08-08.
Native spatial illumination remains conditional on a later controlled-fit
failure. No model training is authorized by this checkpoint.

Closing evidence:

```text
~/Library/Application Support/Incinerator/neural-rendering/experiments/nr4-c-global-controls-still-20260808-a
~/Library/Application Support/Incinerator/neural-rendering/experiments/nr4-c-global-controls-sequence-20260808-a
```

Evaluate, independently:

- material and asset identity;
- stable surface coordinates;
- roughness, metallic, emissive, transmission/opacity, and material class;
- direct-light or irradiance approximation and shadow/visibility features;
- effect kind, phase, responsive mask, and deterministic seed;
- exposure, grade, weather, and time-of-day controls; and
- target-extent depth, normal, motion, coverage, and identity.

For each proposed signal, record:

1. the observed ambiguity or failure it resolves;
2. its deterministic source and presentation-only ownership;
3. GPU raster, storage, and capture cost on the actual scene;
4. machine encoding, precision, extent, coordinate convention, and reset
   semantics;
5. a human-readable debug decode;
6. an ablation showing whether it improves alignment or controlled fit; and
7. why a cheaper existing signal is insufficient.

The accepted set replaces `incinerator.neural-input.v1` as one explicit schema
cohort. Every shader, host, capture writer, inspector, dataset adapter, lab
view, test, bundle contract, and document changes together. No v1 compatibility
path is added.

Categorical asset/material/instance values are decoded as categorical IDs for
model embeddings, not treated as ordinal color. Continuous physical values are
trained in declared units or declared normalization. The target remains linear
HDR through training; display transforms are explicit evaluation derivatives.

**Exit evidence**

- Every channel has one owner, one meaning, one debug view, and one contract
  test.
- The 2.5× source-to-target coordinate mapping is exact and independently
  tested at frame borders, thin features, identity edges, and motion.
- The direct native `400×225` still and moving target direction receive fresh
  human acceptance without a cross-resolution reference.
- Every review and machine artifact proves it came only from the declared
  `160×90 → 400×225` cohort; foreign extents fail closed.
- Removed channels are proven redundant; added channels answer observed target
  ambiguity.
- Current and previous-frame semantics, visibility, and history reset behavior
  are unambiguous.
- Normal graphical, headless, and server dependency boundaries still pass.

### NR4-D — Paired capture and corpus assembly

1. Advance capture to store independently described `160×90` input targets,
   the `400×225` target frame package, canonical HDR result, auxiliary
   alignment passes, and display derivatives.
2. Make one frame identity join the engine inputs and target result. The target
   job may complete later, but it cannot change the source package.
3. Use atomic partial/complete state and fail closed on missing or stale target
   products.
4. Record engine/content/shader/schema/fixture/Blender/Cycles/configuration,
   rights, scene, camera, split, sequence, and artifact digests.
5. Assemble datasets by whole sequence. Reject a sequence appearing in more
   than one split and reject mismatched target or input provenance within a
   declared cohort.
6. Keep a separate controlled-overfit sequence, training sequences, validation
   sequences, an unopened test cohort, and newly captured native stress
   sequences that reuse NR0-D scenario definitions without reusing its frames.
7. Add complete inspectors and compact visual reports. Reports link back to
   exact raw artifacts; previews never become training input by accident.

**Exit evidence**

- Starting from an absent output root produces a complete, self-describing
  corpus without modifying source captures.
- Every training tensor can be traced to one source event, target render, title
  source, rights statement, and digest.
- No adjacent-frame split leakage exists.
- Corruption, wrong schema, target drift, missing frames, and identity mismatch
  fail before training.

The technical exit is implemented and retained at
`~/Library/Application Support/Incinerator/neural-rendering/experiments/nr4-d-corpus-20260808-b`.
Six independently inspected whole sequences contribute 108 native pairs across
overfit, train, validation, sealed test, and two stress programs. The
self-contained corpus re-inspects from its copied root, carries exact artifact
and provenance digests, rejects cross-sequence conditioning/pair reuse, and
keeps review derivatives outside training. The generated split sheet passes
agent visual audit. NR4-E owns the product-level coverage and corpus acceptance
decision; model training remains unauthorized.

### NR4-E — Coverage and corpus acceptance

Produce and review a coverage ledger for scene content, materials, lights,
camera distances, motion, occlusion, reset events, effects, and uncommon but
valid views. Coverage records facts; it does not invent a required frame count.

Run:

- two independent source-capture launches;
- two target renders of one declared source sequence;
- all schema, shader, capture, target-adapter, dataset, rights, and split tests;
- a cold repository test proving offline dependencies remain outside product
  graphs; and
- human inspection of the target sequence and worst alignment examples.

The coverage report scopes every quality, memory, and runtime claim to the exact
`160×90 → 400×225` cohort. It makes no claim about any other resolution.

Create `experiments/neural-rendering/nr-0004-high-fidelity-target-corpus/` with
the exact question, configuration, source fingerprints, external evidence
root, coverage result, known gaps, and accepted/rejected/inconclusive outcome.

**NR-0004 exit**

An inspectable corpus contains a visual transformation worth learning without
changing world state. Failure closes NR-0004 with evidence and returns to the
target or schema work; it does not advance to a larger model.

**Implementation checkpoint — 2026-08-09**

The product owner accepted the NR4-D review sheet. The read-only NR4-E audit at
`~/Library/Application Support/Incinerator/neural-rendering/experiments/nr4-e-coverage-20260809-b`
then accepted NR-0004 for NR5-A and NR5-B only. It records one scene, 26 stable
identities, nine materials, six causal segments, six camera programs, four
lighting/material states, 108 pairs, and every whole-sequence split. Test
metadata was inspected while test pixels remained sealed and excluded from the
review.

The same ledger carries explicit gaps: no title-wide location/asset diversity,
deformation, destruction, weather, atmosphere, particles, crowd variation, or
long temporal cohort. The acceptance therefore does not authorize NR5-C
generalization claims, NR6/NR7 training, promotion, or runtime selection.

## NR-0005 — From-scratch structural title renderer

### NR5-A — Training framework foundation

Create one cohesive Python package rather than another independent script
chain. Keep responsibilities explicit:

- schema and manifest types;
- title dataset loader and categorical/continuous channel decoding;
- deterministic initializer and architecture registry;
- trainer and lineaged resume;
- evaluator/baselines/ablations;
- visual reporting;
- export and numerical-agreement verification; and
- environment/provenance capture.

Every run starts in a new external root and records source/dirty identity,
environment, dataset/split digests, architecture/config hash, all seeds,
initializer, optimizer/scheduler state, checkpoint ancestry, metrics, timing,
memory, and disposition. Resume creates a new lineaged continuation; it does
not mutate the parent run.

Add a learned-artifact audit that enumerates every loaded weight tensor and
proves its origin is the run initializer or a title-trained ancestor. Ordinary
libraries are allowed; hidden pretrained feature extractors, losses, codecs,
and initializers are not.

**Gate:** a clean-room miniature fixture can initialize, train, resume,
evaluate, and export with complete lineage while engine/headless tests run
without importing the training environment.

**Implementation checkpoint — 2026-08-09**

The cohesive `tools/neural-rendering/title_renderer/` package now separates
cold corpus/provenance contracts from external Torch/OpenEXR training owners.
The clean-room proof at
`~/Library/Application Support/Incinerator/neural-rendering/experiments/nr5-a-clean-room-20260809-b`
creates and audits a random initializer, trains a deterministic synthetic
title-owned fixture, resumes into a new child while preserving the parent
digest, audits every loaded tensor as initializer/title-checkpoint lineage,
evaluates, and exports TorchScript with zero observed numerical difference.
All seven lifecycle checks pass in 575.688 ms on the named M2 Max host.

### NR5-B — Controlled spatial overfit

Implement the smallest useful two-branch structural model:

- low-resolution continuous appearance/control encoder;
- categorical asset/material/semantic/instance embeddings;
- shallow higher-resolution structural encoder;
- compressed residual backbone; and
- progressive reconstruction head with structural fusion at each output scale.

The first model consumes the accepted `160×90` schema cohort and produces
`400×225` linear-HDR color. Its reconstruction head must implement the declared
2.5× mapping explicitly; it may use deterministic interpolation followed by
learned reconstruction rather than inventing an integer-only pixel-shuffle
contract.

Train in declared linear HDR and evaluate display-space derivatives separately.
Use repository-defined color, robust reconstruction, gradient/frequency,
structural, semantic-boundary, instance-boundary, and authored-geometry losses.
No external learned perceptual loss participates.

Scale capacity only in response to observed underfit or resource evidence. The
first gate is controlled memorization of one short exact sequence with no
missing, duplicated, displaced, or identity-swapped geometry.

**Gate:** the model reconstructs the controlled target closely enough that
remaining visible failures are attributable to the model/capacity rather than
channel decoding, pair alignment, output transfer, or tooling.

**Implementation checkpoint — 2026-08-09**

The accepted run is retained at
`~/Library/Application Support/Incinerator/neural-rendering/experiments/nr5-b-controlled-overfit-20260809-c`.
A 448,175-parameter two-branch model trained for 240 declared epochs on MPS;
epoch 238 was retained by lowest overfit loss. Training took 208.399 seconds.
Every checkpoint tensor traces to the exact random initializer, the complete
configuration, NR4-E authorization, evaluation/environment/export manifests,
and all executing repository tool sources are snapshotted and hashed inside
the run. The TorchScript candidate matches PyTorch exactly for the export
fixture.

Across all 18 overfit frames, model linear-HDR MAE is `0.009956` versus
`0.447403` for the best deterministic resize. Diagnostic-display MAE is
`0.013717` versus `0.366620`; semantic-boundary MAE is `0.018672` versus
`0.276200`; instance-boundary MAE is `0.036004` versus `0.325507`. All 18
comparison sheets were inspected. Authored state and declared causal changes
remain faithful. Localized smoothing and chromatic ringing remain in severe
near-edge and high-emissive views; NR5-C must treat them as explicit
conditioning/architecture ablations. Test pixels remain unopened. Acceptance
authorizes NR5-C only, not promotion or runtime integration.

### NR5-C — Held-out structural reconstruction

Train on the declared training cohorts, select only on validation, then open
the test cohort once. Compare:

- cheap appearance at target size;
- nearest, bilinear, and bicubic reconstruction;
- the new model with each major input branch ablated; and
- the exact high-fidelity target.

Measure geometry/identity and material/lighting quality separately. Preserve
full-frame comparisons plus worst semantic boundary, instance boundary, thin
feature, reflective, emissive, transparent, and disocclusion examples.

**Gate:** held-out frames preserve authored structure and show an unambiguous
title-trained material/lighting improvement. A high aggregate score cannot
hide geometry substitution.

### NR5-D — Candidate conclusion

Re-execute the accepted NR0-D spatial/failure scenario and metric definitions
on newly captured native cohort frames, then add target-specific failures. Do
not reuse its earlier images, targets, model outputs, or metrics as comparisons.
Record local MPS training/evaluation time and memory as measurements, not
budgets. Export a candidate only after its exact PyTorch behavior is accepted,
then verify numerical and visual agreement through the export.

Create `experiments/neural-rendering/nr-0005-structural-title-renderer/` with
the immutable run identity and an explicit accepted, rejected, or inconclusive
conclusion. Acceptance permits temporal work; it does not promote the model.

## NR-0006 — Causal temporal title renderer

1. Define the exact history contract before adding state: inputs, feature/output
   ownership, alignment convention, rejection masks, lifecycle, and reset
   reasons.
2. Reproject prior features or output with engine motion. Reject history using
   depth, identity, coverage, disocclusion, responsive masks, and explicit
   reset state.
3. Add causal recurrent blocks first. Add compressed windowed attention only
   where measured long-range or temporal failures justify it.
4. Train clips containing ordinary motion, fast motion, articulation,
   disocclusion, lighting/effect change, invalid history, cuts, resize, model
   reset, and long uninterrupted runs.
5. Evaluate valid-history stability, current-frame responsiveness,
   disocclusion, reset recovery, surface-space detail stability, long-run
   drift, and window boundaries independently.
6. Preserve spatial/no-history and deterministic temporal baselines so history
   cannot conceal a worse current-frame renderer.

**Exit:** the causal model is more stable and responsive than NR-0005 on the
declared sequences; a reset frame remains independently readable; history is
disposable presentation cache; no object existence or event timing comes from
the model.

## NR-0007 — Conditional learned-detail residual

NR-0007 begins only if NR-0006 is structurally and temporally sound but remains
visibly over-smoothed against the target. The phase starts with a written
ceiling analysis identifying the missing material, texture, lighting, or effect
frequency.

1. Add the smallest title-trained residual mechanism that addresses the
   measured gap: first a jointly trained discriminator; a small conditional
   rectified-flow/diffusion head only if that fails.
2. Initialize every learned component, codec, discriminator, and loss network
   from scratch on the same title corpus.
3. Restrict the detail path to a residual over the accepted structural output
   and feed it the same explicit controls.
4. Anchor any stochastic state to stable surface/instance/time coordinates.
5. Penalize geometry, silhouette, identity, depth-edge, motion, and reset
   disagreement independently of richness.
6. Compare against NR-0006 with the detail head disabled on every evaluation
   sequence.

**Exit:** human-visible richness improves without geometry substitution,
identity drift, temporal repainting, sluggish response, or hidden external
learned ancestry. If it does not, reject NR-0007 and keep NR-0006.

## NR0-E through NR0-G — Selection and product integration

These phases remain blocked until NR-0005, NR-0006, or NR-0007 produces a
promotion-worthy candidate.

### NR0-E — Promotion

- Validate random-origin lineage, title data/rights, schema, evaluation,
  backend, dimensions, and every artifact digest.
- Copy one accepted export to a temporary bundle, verify copied bytes, publish
  the immutable bundle, and atomically update the exact selected-model manifest.
- Reject collisions, mutable source state, incomplete evaluation, or a foreign
  learned ancestor. Preserve the source run unchanged.

### NR0-F — Installed macOS runtime

- Replace the legacy explicit experiment path and CPU readback/upload bridge
  with selected-content loading and GPU-resident macOS inference.
- Keep frame sequencing, history, inference/fallback policy, and composition in
  the neural host; keep Core ML/MPSGraph/Metal resources in the macOS adapter.
- Compose neural scene color before conventional UI and diagnostics.
- Exercise absence/rejection, first frame, cut, resize, model change, device
  recovery, inference failure, and return from fallback explicitly.
- Expose selected bundle/schema/digest, input/history state, inference timing,
  memory, and fallback/reset reasons in the Neural Rendering Lab and incident
  bundles.

### NR0-G — Acceptance and architectural audit

- Prove authority/replay equivalence with neural mode on and off.
- Run bundle, schema, fallback, installed Metal, long-run, incident, and
  cold/headless dependency tests.
- Measure complete raster/inference/post/UI/present latency, frame pacing,
  residency, memory, power where observable, and transition costs on the named
  Mac cohort.
- Human-test motion, materials, identity, thin detail, transparency/effects,
  disocclusion, cuts, resize, fallback, and recovery.
- Audit dependency direction, monolithic renderer growth, stale experiment
  paths, generated artifact hygiene, rights/provenance, and documentation drift.

NR0 closes accepted or rejected. It does not become accepted because the model
is attractive in a selected clip.

## Diagnostics and evidence contract

Every phase must leave enough evidence for a fresh agent or human to answer
what ran, what data it used, what changed, and why it passed or failed.

### Live Neural Rendering Lab

Grow the existing tool only as capabilities become real. The final lab should
provide synchronized views of:

- cheap appearance and every auxiliary input with correct decoding;
- high-fidelity target when a captured frame is selected;
- model output and conventional fallback;
- absolute/gradient/frequency error and semantic/instance boundaries;
- history-use, rejection, disocclusion, and responsive masks;
- schema, model/bundle, source, target, camera, frame, and identity lineage;
- target/capture/training/inference status and exact last failure; and
- timings and memory measurements labeled by owner and scope.

Debug views are presentation diagnostics. They do not enter training unless
the schema explicitly names the underlying raw channel.

### External run shape

Each capture, target, training, evaluation, or export command receives an
absolute absent output root. A completed run has one immutable entry manifest
linking:

```text
source/        immutable input manifests or links plus digests
targets/       canonical HDR/evidence products
dataset/       assembled manifests, coverage, rights, and split ownership
checkpoints/   initializer and lineaged training checkpoints
evaluation/    metrics, ablations, complete visual reports, and failures
export/        runtime candidate plus numerical-agreement evidence
environment/   tool, OS, hardware, package, and source fingerprints
conclusion.*   pending review followed by one immutable disposition
```

The exact directory evolves with implemented consumers; the invariants are
explicit ownership, immutable evidence, complete lineage, and no `latest`.

### Phase-close ritual

At the end of every work package:

1. run focused unit/contracts first, then the affected full engine and boundary
   tests;
2. inspect machine manifests and complete visual evidence;
3. compare against the cheap renderer and relevant deterministic/model
   baselines;
4. record named hardware, source/data/model digests, commands, timing, memory,
   and external artifact paths;
5. write the accepted/rejected/inconclusive conclusion without overwriting the
   pending record;
6. update this board, the NR0 plan, validation ledger, performance baseline,
   experiment README, tooling README, and skill when their facts changed; and
7. run link, formatting, generated-file, cold-dependency, and Git hygiene
   checks before handoff.

## Test strategy

| Boundary | Required tests |
|---|---|
| Presentation schema | Formats, units, extents, coordinate systems, identity mapping, reset rules, shader reflection, and human debug decode |
| Target adapter | Exact input manifest, camera/transform round trip, identity coverage, HDR validity, deterministic source lineage, and partial-run rejection |
| Pair alignment | Per-frame object/depth correspondence, missing/extra identity report, camera projection diagnostics, and synchronized human review |
| Dataset | Digest verification, rights/provenance, whole-sequence split isolation, no stale target, channel decoding, and coverage report |
| Model origin | Declared initializer/seed, loaded-tensor inventory, checkpoint ancestry, resume immutability, and rejection of foreign weights |
| Training | Controlled overfit, held-out validation selection, unopened test, baseline/branch ablations, checkpoint recovery, and visual report completeness |
| Temporal | Warp convention, disocclusion, invalid history, cuts, resize, model reset, responsive changes, long-run drift, and causal-only inference |
| Export | Shape/schema agreement, numerical comparison, visual comparison, exact digest, and backend requirements |
| Promotion | Source preservation, transactionality, collision rejection, rights/schema/evaluation verification, and exact selected manifest |
| Runtime | Selected-only loading, GPU residency, UI boundary, fallback/recovery, model identity diagnostics, incidents, and frame/memory evidence |
| Architecture | No authority access, no training dependency in product/headless/server, no runtime experiment lookup, and no renderer-owner collapse |

## Explicitly deferred

- live LTX or another external pretrained model;
- fine-tuning, adapters, distillation, pseudo-targets, or pretrained losses;
- a general Blender/DCC interchange framework;
- a generic render graph rewrite;
- prompt-driven runtime style;
- a distributed trainer, hosted registry, cloud inference, or runtime training;
- a universal multi-title model;
- secondary-platform inference; and
- firearms, multiplayer, world simulation, or gameplay work done merely to add
  neural-rendering training variety.

## Immediate implementation sequence

NR4-A and the NR4-B technical implementation are complete:

1. **Complete:** accept the NR4-A target direction and exact still alignment;
2. **Complete:** advance the adapter-local target package to declared material,
   local-light, and causal-sequence state;
3. **Complete:** render six isolated three-sample moving segments;
4. **Complete:** inspect every frame, produce synchronized reports, and prove
   exact source/identity/depth recapture across two executions;
5. **Complete:** record measured Cycles numeric variation and offline cost; and
6. **Complete:** product-owner acceptance of the moving target and alignment
   direction.

**Current phase:** NR5-C trains on the declared training sequence, selects only
on validation, and opens the sealed test once after selection. It must preserve
the controlled-fit structure/material gain while addressing the near-edge and
emissive ringing recorded by NR5-B. No promotion or runtime integration is
authorized.
