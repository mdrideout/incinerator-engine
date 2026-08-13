# NR0 Neural Rendering Feasibility Validation Ledger

**Status:** NR0-A through NR0-D, NR-0004, and NR5-A through NR5-E accepted;
RF0 through RF5 accepted; RF6 and RF7 retained as historical evidence; RF8
direct `160×90 → 640×360` spatial-sharpness/live-presentation trial accepted
externally and unpromoted; NR6 and NR0-E through NR0-G
open

**Date:** 2026-08-11

This ledger will record executed evidence for
[the NR0 plan](../design/nr0-neural-rendering-feasibility.md). Documentation and
directory scaffolding are not implementation acceptance.

## Required evidence

| Area | Required proof | Status |
|---|---|---|
| Buffer ABI | Exact format/convention tests and human debug views | **NR0-A passed:** schema v1, six MRT channels, shader contracts, live lab, raw captures, and contact-sheet inspection |
| Paired capture | Atomic manifest, fingerprints, alignment, split integrity, and provenance | **NR0-B passed:** schema-2 capture and two-launch deterministic comparison passed; train/validation/test ownership is explicit |
| Spatial baseline | Overfit proof followed by held-out comparison to non-neural baselines | **NR0-C passed:** 17-plane controlled fit, disjoint camera cohorts, held-out nearest/bilinear/bicubic comparison, human review, FP16 export, and standalone benchmark passed |
| Failure envelope | Thin/small geometry, boundaries, motion, disocclusion, cuts, resize, unusual views, exhaustive visual evidence | **NR0-D passed:** 478-frame six-path fixture, every visible instance, reset-aware temporal analysis, and human reset/failure review retained; NR-0002 judged unsuitable for promotion |
| High-fidelity truth | Same-frame rights-clean target, identity/depth alignment, exact environment and reproducibility | **NR4-C accepted:** native `160×90 → 400×225` still and sequence regenerated twice with foreign extents rejected; product direction accepted; four frame-global controls resolve the only observed ambiguity for 16 bytes/frame and no new raster target |
| Paired title corpus | Atomic complete state, whole-sequence splits, sealed test, per-artifact provenance/digests, no leakage, compact review | **NR4-E accepted for NR5-A/B:** the NR4-D 6-sequence/108-pair corpus passed product review and factual coverage audit; explicit gaps prevent title-wide, temporal, detail, or promotion claims; test remained sealed through this gate |
| From-scratch framework | Random initializer, tensor-origin audit, immutable resume ancestry, evaluation, export agreement, and cold dependency separation | **NR5-A passed:** clean-room initialize/train/resume/evaluate/export proof passed all seven checks; parent digest preserved; TorchScript agreement exact; cold contracts require no training packages |
| Controlled title overfit | Direct linear-HDR learning, deterministic resize comparison, complete visual review, structural/identity boundaries, exact export, sealed test | **NR5-B accepted:** all automated checks and 18-frame visual audit passed; MAE 0.009956 vs 0.447403 bilinear; localized near-edge/emissive ringing carried to NR5-C; test remained sealed through this gate |
| Held-out title reconstruction | Fixed entry authorization, validation-only selection, one sealed-test opening, branch ablations, complete visual evidence | **NR5-C accepted for the known fixture:** validation MAE 0.010291 vs 0.468340 bilinear; test MAE 0.016277 vs 0.424593; a real reopen was rejected before pixels; localized edge smoothing/ringing remains |
| Structural candidate conclusion | Fresh native stress capture, worst-frame review, export verification, timing/memory measurements, explicit disposition | **NR5-D accepted; NR6 authorized; unpromoted:** 36 stress frames pass at MAE 0.011826 vs 0.502818 bilinear; all-stress TorchScript agreement exact; visual limitations and one-fixture scope retained |
| Interactive spatial trial | Explicit external bundle, exact live six-channel preprocessing, Core ML agreement, graphical comparison, fallback, identity/timing/incident evidence | **NR5-E accepted; external and unpromoted:** 48/48 live predictions with zero failures or unknown category pixels; native cheap/neural visual evidence reviewed; known blur/ringing retained |
| Cumulative rich spatial candidate | Fresh RF0–RF5 corpus, random-origin fit, validation-only selection, sealed test, fresh stress, ablations, exact export, and live trial | **RF6 technical gate passed; external, unpromoted, and superseded by RF7's resolution decision:** 108 fresh pairs; validation MAE 0.010470 vs 0.451187 bilinear; test opened once at MAE 0.015084; stress MAE 0.012028; 48/48 live predictions pass |
| Direct 800×450 spatial candidate | Fresh native 800×450 truth, one direct learned 5× model, color-fidelity losses, validation-only selection, single-open test, stress, exact export, and live trial | **RF7 accepted as external and unpromoted:** 108 fresh `160×90 → 800×450` pairs; validation/test/stress MAE 0.011649/0.016473/0.013500; Core ML max error 0.00003147; 48/48 live predictions pass; no 400×225 stage |
| Direct 640×360 spatial-sharpness candidate | Fresh native 640×360 truth, one direct learned uniform 4× model, native-grid refinement, sharpness/color losses, spatial-quality validation selection, single-open test, stress, exact export, centered unscaled live trial | **RF8 accepted as external and unpromoted:** 108 wholly fresh `160×90 → 640×360` pairs; validation/test/stress MAE `0.010595`/`0.015272`/`0.012508`; Core ML max error `0.00003123`; 48/48 Metal predictions pass; no 400×225 or 800×450 pixels |
| Promotion | Source-preserving transactional copy, digest/schema verification, exact selection | Not started |
| Runtime | Installed Apple Silicon inference with GPU-owned textures and visible model identity | Preliminary explicit-path Core ML proof passed; blocking CPU staging and no promoted bundle prevent acceptance |
| Fallback | Missing/rejected model, resize, cut, device/inference failure, and recovery | Missing-model conventional fallback passed; remaining transitions open |
| Boundaries | No training dependency or authority/private-gameplay access | NR0-A/B presentation contract and GPU/capture hosts plus NR0-C offline tools pass cold/headless and M5 architecture boundaries; final source audit remains NR0-G |
| Performance | End-to-end latency, GPU time, frame pacing, and memory on named hardware | NR0-C standalone Core ML and NR0-D offline PyTorch/MPS distributions recorded; installed GPU/frame/residency profile remains NR0-F |
| Diagnostics | Debug views plus incident evidence for model/history/fallback state | Lab exposes six channels, schema/shader, history, identity collision, model, capture, failure, and timing state; incident integration remains open |
| Human acceptance | Motion, identity, detail, disocclusion, effects, UI, fallback, and recovery | Not started |

## NR-0003 quality-first video baseline

NR-0003 tested the official LTX-Video 2B 0.9.8 distilled checkpoint against an
accepted Incinerator NR0-D appearance sequence. It is a numbered model
experiment, not an accepted NR0 engine phase and not promotion evidence.

- Both final schema-2 candidate evidence inspectors passed, including immutable
  config/prompt snapshots, exact upstream/model/license identity, generated
  video and comparison hashes, environment, MPS timing, and process memory.
- The structure schedule generated 9 frames at 512×288 in 5.966 seconds
  (1.509 effective FPS) with 7,918,895,104 bytes peak process RSS.
- The richness schedule generated the same cohort in 6.079 seconds
  (1.480 effective FPS) with 7,918,878,720 bytes peak process RSS.
- Human comparison accepted the requested Mac proof-rate feasibility but
  rejected stock RGB conditioning: the structure schedule mostly smooths the
  primitive render, while the richness schedule substitutes unrelated
  buildings and vehicles for authored geometry.
- An upstream multiscale latent-shape failure is retained with terminal failed
  state; exploratory mutable-config candidates are explicitly superseded.

The canonical external evidence root is
`~/Library/Application Support/Incinerator/neural-rendering/experiments/nr-0003-ltxv-2b-20260808-a`.
Start with `candidate-structure-license-final/candidate.json` and
`candidate-rich-license-final/candidate.json`. The experiment conclusion is
recorded in
[`NR-0003`](../../experiments/neural-rendering/nr-0003-ltxv-2b-distilled/README.md).

## NR4-A exact high-fidelity target still

NR4-A implements the first target-only portion of NR-0004. It is data-factory
evidence, not a trained model and not promotion evidence.

- Blender 4.5.12 LTS Apple Silicon and its archive SHA-256 are pinned. Cycles
  uses Metal, 256 samples, seed 73, fixed sampling, scene-linear float32
  OpenEXR, AgX display output, and no learned denoising.
- A rights-clean procedural urban corner contributes exactly 26 stable draws:
  road/sidewalk/storefront, thin geometry, material classes, a four-wheel
  vehicle, character, NPC, carryable, and crate.
- The validation host exports one adapter-local frame package from the same
  immutable draw plans and camera used by six 400×225 engine input channels.
  The offline target is 1600×900 and includes beauty, object identity, linear
  depth, normals, provenance, and synchronized visual evidence.
- Two fresh runs completed with zero capture/export failures and reproduced
  the engine frame identity, camera, effects, six channel hashes, conventional
  target, identities, and normalized frame package. Target identity and depth
  are byte-identical.
- Both alignment reports measured 445,350 exact identity pixels over a 456,695
  pixel fixture union: 0.975158 exact identity-over-union with no missing
  target identity visible in the cheap source.
- Cycles beauty output varied by at most one 8-bit display value. The float32
  normal pass varied by at most 4.768e-7 absolute error (1.148e-8 RMSE), while
  geometry identity/depth remained exact. The comparison records this observed
  Metal floating-point behavior rather than inventing an acceptance threshold.
- The source and targets were visually inspected for both executions. The
  scene cohort and projection align; remaining magenta/cyan pixels are
  measured raster/geometry edge differences.
- The product owner explicitly accepted the upper-right target as a visual
  direction worth extending into moving sequences, closing NR4-A.

Canonical external evidence:
`~/Library/Application Support/Incinerator/neural-rendering/experiments/nr4-a-technical-20260808-v2`.
Start with `acceptance.json`, `reproducibility.json`, and
`run-a/evaluation/nr4-a-review.png`. The experiment definition is
[`NR-0004`](../../experiments/neural-rendering/nr-0004-high-fidelity-target-corpus/README.md).

## NR4-B material-rich moving target

NR4-B advances only the adapter-local target package to v2; the engine-owned
input ABI remains v1 pending the NR4-C ambiguity audit.

- Eighteen exact frames cover six three-sample, single-cause segments: camera
  motion, rigid vehicle motion, near-edge camera motion, wheel roll/front
  steering, NPC occlusion/disocclusion, and lighting/emissive response.
- The causal audit verifies stable draw identity/membership in every frame and
  rejects any transform, camera, scene, or material-response change outside
  the declared owner for that segment.
- Every frame includes source capture, immutable frame package, 1600×900
  Cycles target, object identity, depth, normal, alignment, and synchronized
  overview/detail evidence. No cheap-visible identity is missing in the target.
- Two fresh engine launches and 36 Cycles renders reproduced all engine
  captures, normalized frame packages, target identity, and target depth
  exactly. Per-frame identity-over-union spans 0.974974–0.987851.
- Repeated target displays differ by at most one 8-bit value. Normal evidence
  differs by at most 5.960e-7 absolute and 1.608e-8 RMSE. The recorded source
  causes and human sheets show substantially larger authored changes, including
  the deliberately subtle wheel-articulation response.
- All three cheap conventional targets in the lighting-effect segment are
  byte-identical while the exact Cycles target responds to the declared light
  and emissive changes. This observed many-to-one input mapping is retained as
  the first concrete NR4-C ambiguity; no replacement channel is assumed yet.
- The first and second 18-frame renders report 132.762 and 133.374 seconds of
  total Cycles time. Both inspectors and the cross-run comparator pass.
- Agent visual review accepts the technical correspondence and intended target
  variation. On 2026-08-08 the product owner reviewed and explicitly accepted
  the synchronized moving sequence, closing NR4-B and authorizing NR4-C.

Canonical external evidence:
`~/Library/Application Support/Incinerator/neural-rendering/experiments/nr4-b-technical-20260808-a`.
Start with `acceptance.json`, `reproducibility.json`, and
`run-a/evaluation/reports/nr4-b-sequence-review.png`.

## NR4-C native working-resolution validation

NR4-C implements a `160×90 → 400×225` 16:9 proof cohort. Prior target pixels
and acceptance do not satisfy this gate. The current implementation establishes:

- exact 2.5× top-left/pixel-center mapping across every producer and consumer;
- correct extents, byte counts, debug decodes, border coverage, thin features,
  identity edges, and motion vectors;
- a direct native `400×225` Cycles still with fresh human target/alignment
  acceptance and a regenerated native 18-frame causal sequence;
- rejection of target pixels, metrics, references, and previews from every
  foreign extent;
- nearest, bilinear, and bicubic baselines at the exact new extents;
- native `160×90`/`400×225` comparison views with UI zoom and resize baselines
  explicitly excluded from training material;
- two-launch logical and declared-byte reproducibility for the accepted causal
  sequence; and
- measured capture size, Cycles time, input-raster time where observable,
  dataset decode time, process/GPU memory, and evidence volume on the M2 Max.

The technical evidence roots are:

```text
~/Library/Application Support/Incinerator/neural-rendering/experiments/nr4-c-native-still-20260808-b
~/Library/Application Support/Incinerator/neural-rendering/experiments/nr4-c-native-sequence-20260808-b
```

Both two-run gates pass. All corresponding engine inputs, normalized frame
packages, target identity, and target depth reproduce exactly. Sequence display
variation is at most 1/255 and normal variation is at most `9.537e-7` absolute
with `1.767e-8` RMSE. The 18 direct targets render in 14.862 seconds in Run A;
peak Blender process RSS is 540,540,928 bytes. GPU raster timing and Blender
GPU-memory residency are unavailable and explicitly recorded as such. The
capture records CPU command encoding instead: 2.725 ms total and 0.229 ms
maximum over the 18 selected frames. Display-pair decode averages 6.454 ms.

Target-extent structural controls still require individual ablation evidence.
Every quality and performance claim is scoped to native `160×90 → 400×225`
evidence; other output extents are deferred. The product owner accepted the
native still/moving target and alignment direction on 2026-08-08.

The native ambiguity audit also passes as an executed diagnostic at
`~/Library/Application Support/Incinerator/neural-rendering/experiments/nr4-c-native-ambiguity-20260808-b`.
It found one semantic many-to-one segment: lighting/material target state
changed while every non-temporal input remained byte-identical. Motion B
changed only because history validity reset, so it was a spurious correlate
rather than a lighting owner.

The closing schema-4 evidence is retained at:

```text
~/Library/Application Support/Incinerator/neural-rendering/experiments/nr4-c-global-controls-still-20260808-a
~/Library/Application Support/Incinerator/neural-rendering/experiments/nr4-c-global-controls-sequence-20260808-a
```

Input schema v3 adds four presentation-owned frame-global float32 controls:
sun, world, local-light, and emissive strength. The ablation resolves the
lighting segment in both independent runs. Its measured contract cost is 16
bytes per frame, zero extra raster targets, and zero extra raster pixels.
Engine capture, normalized frame packages, target identity, and target depth
reproduce exactly; display variation is at most 1/255 and normal variation at
most `6.557e-7` absolute / `1.774e-8` RMSE. A spatial lighting control remains
conditional on future controlled-fit evidence.

## NR4-D paired-corpus validation

Canonical evidence is retained at
`~/Library/Application Support/Incinerator/neural-rendering/experiments/nr4-d-corpus-20260808-b`.
Start with `acceptance.json`, `corpus/corpus.json`, and
`corpus/review/nr4-d-corpus-review.png`.

- Six complete native sequences contain 108 exact pairs across overfit, train,
  validation, sealed test, and two stress camera programs.
- Every source run passes target-package, target-render, identity/depth/normal,
  rights, alignment, and artifact inspection before assembly; the copied
  corpus then passes the same sequence inspection from its own root.
- Frame identity joins capture, six raw channels, global controls, target
  package, scene-linear EXR, identity, depth, normal, and target run.
- All training and auxiliary artifacts carry exact size and SHA-256 records.
  Review PNG/PPM derivatives are present but explicitly training-ineligible.
- The review report excludes the sealed test split by executable contract. Its
  15 panels cover overfit, train, validation, and stress only; test receives
  machine integrity/alignment inspection without human pixel review.
- Whole sequences own one split. Cross-sequence conditioning and pair digest
  reuse fail closed; intentional repeated conditioning inside one sequence is
  allowed because it does not leak across a split.
- Focused negative contracts reject artifact corruption/removal and
  cross-sequence leakage. Existing strict inspectors reject wrong schemas,
  stale packages/targets, provenance drift, identity mismatch, missing target
  identities, foreign extents, and non-rights-clean targets.
- Agent review of all 18 selected source/target panels passes. The targets
  preserve authored structure while retaining the accepted richer material and
  lighting direction across each split.

The technical gate passes. Product-level coverage sufficiency and final corpus
acceptance belong to NR4-E. No model was trained or promoted.

## NR4-E coverage and corpus acceptance

Canonical evidence is retained at
`~/Library/Application Support/Incinerator/neural-rendering/experiments/nr4-e-coverage-20260809-b`.
Start with `acceptance.json`, `coverage.json`, and `coverage.md`.

- The product owner accepted the compact NR4-D review sheet.
- A read-only coverage consumer verified all 108 package manifests and every
  non-test training artifact while opening no test input or target pixels.
- The ledger records one procedural scene, 26 stable identities, six semantic
  classes, nine materials, six isolated causal segments, six camera programs,
  four lighting/material states, camera distances from 5.432 to 31.183 world
  units, explicit reset evidence, clean rights, and all whole-sequence splits.
- Known gaps explicitly include title-wide scene/asset diversity, deformation,
  destruction, weather, atmosphere, responsive effects, particles, crowds,
  and long temporal coverage.

NR-0004 is accepted only for NR5-A framework validation and NR5-B controlled
spatial overfit. The sealed test remains unopened; no model was trained or
promoted by NR4-E.

## NR5-A/B from-scratch framework and controlled overfit

NR5-A clean-room evidence is retained at
`~/Library/Application Support/Incinerator/neural-rendering/experiments/nr5-a-clean-room-20260809-c`.
It passed deterministic initialization, parent and resumed loss descent,
immutable parent ancestry, tensor-origin audit, exact TorchScript agreement,
and external-weight rejection contracts.

The accepted NR5-B run is retained at
`~/Library/Application Support/Incinerator/neural-rendering/experiments/nr5-b-controlled-overfit-20260809-c`.
Start with `conclusion.json`, `run.json`, `evaluation/evaluation.json`,
`checkpoints/checkpoint-audit.json`, and all 18 files under
`evaluation/samples/`; `evaluation/nr5-b-overfit-overview.png` is the complete
single-sheet visual index.

- A 448,175-parameter two-branch model trained only on the 18-frame overfit
  sequence from the exact recorded random initializer. The run snapshots and
  hashes the accepted NR4-E authorization, configuration, executing tools, and
  evaluation/environment/export manifests.
- Epoch 238 was retained by lowest overfit loss after 208.399 seconds of MPS
  training. The checkpoint owns 36 audited tensors and one exact initializer
  ancestor.
- Model linear-HDR MAE is `0.009956`, diagnostic-display MAE `0.013717`,
  semantic-boundary MAE `0.018672`, and instance-boundary MAE `0.036004`.
  Corresponding best bilinear values are `0.447403`, `0.366620`, `0.276200`,
  and `0.325507`.
- The TorchScript candidate agrees exactly on the export fixture. Offline MPS
  inference measured 7.151 ms median and 13.588 ms p95; this is not an
  installed runtime measurement.
- Agent inspection of every frame accepts authored-state fidelity and declared
  camera/object/wheel/occlusion/lighting response. Localized smoothing and
  chromatic ringing remain in severe near-edge/high-emissive views and become
  explicit NR5-C ablation work.

NR5-B authorized held-out NR5-C training only. Its candidate remains
unpromoted and is not a runtime bundle.

## NR5-C/D held-out reconstruction and structural conclusion

NR5-C entry authorization is retained at
`~/Library/Application Support/Incinerator/neural-rendering/experiments/nr5-c-entry-20260810-a`.
It binds the exact 108-pair known-fixture corpus, accepted NR4-E and NR5-B
lineage, split ownership, source snapshots, and one-test-open policy without
decoding test pixels.

Canonical NR5-C/D evidence is retained at
`~/Library/Application Support/Incinerator/neural-rendering/experiments/nr5-c-held-out-20260810-b`.
Start with `conclusion.json`, `run.json`, `selection.json`,
`test-opening.json`, `test-reopen-rejection.json`,
`stress-evaluation.json`, and `nr5-d-measurements.json`, then inspect all three
evaluation overviews and their frame sheets.

- The 448,175-parameter model trained on 36 frames and selected epoch 175 only
  on 18 validation frames after 349.955 seconds. Validation linear-HDR MAE is
  `0.010291` versus `0.468340` bilinear.
- The sealed 18-frame test opened once after immutable selection. Model MAE is
  `0.016277` versus `0.424593` bilinear. A subsequent invocation owns a separate
  rejection record and opened no pixels.
- A fresh Blender/Cycles Metal run at
  `nr5-d-native-stress-corpus-20260810-a` regenerated the entire native corpus.
  Its 36 stress frames measure `0.011826` model MAE versus `0.502818` bilinear;
  semantic/instance boundary MAE are `0.034780`/`0.074701` versus
  `0.280980`/`0.336319`.
- Appearance-only, no-semantic, no-instance, and no-global-control ablations
  all lose to the full model in aggregate. Every validation, test, and stress
  frame sheet plus the worst-error views was inspected.
- Authored geometry, identities, controlled object state, material response,
  and lighting remain faithful. Localized smoothing and chromatic ringing at
  emissive, glass, and high-contrast boundaries remain visible, especially in
  severe near/high views.
- TorchScript agrees exactly with PyTorch across all 36 stress frames. Offline
  MPS inference measured `6.983 ms` median and `10.862 ms` p95; a representative
  forward/backward process reached `1,027,063,808` bytes peak RSS. The original
  training process lacked RSS instrumentation, so its peak remains unknown.

The immutable NR5-D conclusion accepts only a known-fixture structural result
and authorizes NR6 causal temporal work. It does not claim title-wide
generalization, temporal readiness, art completion, promotion, or installed
runtime acceptance.

## NR5-E interactive spatial trial

NR5-E exports that exact selected checkpoint into an immutable external Core ML
trial bundle and runs it from Incinerator's live schema-v3 targets. The trial
loader fails closed on ABI, shape, preprocessing, vocabulary, control range,
source-lineage, package-membership, byte-count, or digest mismatch. It performs
no runtime candidate discovery and installs no learned content.

The 48-frame Metal gate produced 48 predictions with zero failures and zero
unknown semantic or instance pixels. The retained native comparison shows the
cheap flat-color structural source beside the model's aligned materialized and
lit `400×225` output. Warm evidence measured `11.281 ms` for the last Core ML
inference and a `33.475 ms` mean staged pipeline. The current path contains a
blocking GPU readback and CPU display conversion, so these are proof
measurements rather than a shipping budget. A cold first-use compilation
outlier near `1052 ms` remains recorded.

The accepted external bundle, command set, evidence location, exact digests,
runtime boundary, and remaining limitations are recorded in
[the NR5-E validation record](nr5-e-interactive-spatial-trial.md). NR5-E proves
the complete evaluation path but does not promote the candidate. Its NR6
authorization remains valid, but the rich-fidelity roadmap deliberately runs
RF0 through RF6 first so temporal work addresses the real sandbox vocabulary.

## RF6 cumulative rich spatial candidate

RF6 applies the accepted RF0–RF5 target direction to a completely new data and
model lineage. Its six whole sequences contain 108 newly rendered native pairs;
no earlier target pixels or checkpoints participate. The 448,359-parameter
candidate was selected at epoch 175 using validation only, after which the
18-frame sealed test opened once and a real reopen was rejected before pixels.
A separately regenerated 36-frame stress cohort then passed.

The full model measures `0.010470` validation linear-HDR MAE versus `0.451187`
bilinear, `0.015084` on sealed test versus `0.399686`, and `0.012028` on fresh
stress versus `0.487823`. Appearance-only and no-instance ablations fail
materially; no-global and no-semantic branches also lose. Complete visual
review retains localized glass/emissive/thin-edge ringing and softening.

The external Core ML trial produced 48 predictions from 48 live Metal
readbacks with zero failures and zero unknown category pixels. Exact roots,
digests, runtime measurements, review commands, and the remaining
product-owner interactive gate are in
[the RF6 validation record](rf6-cumulative-rich-spatial.md). This is technical
spatial acceptance, not promotion, installed content, temporal acceptance, or
title-wide coverage.

## Acceptance conclusion

NR0-A/B accept the engine-owned input ABI and deterministic paired-capture
foundation. NR0-C accepts the first multi-channel spatial reconstruction
candidate against the S13 conformance scene. NR0-D accepts the dedicated stress
fixture and exhaustive failure-analysis method, but finds NR-0002 unsuitable
for promotion because boundary sharpness and valid-history temporal residual
are worse than bilinear and visible thin/fine-feature failures remain. NR-0001
remains the preliminary local-loop proof. Both generated models remain
external and must not be copied into `models/neural-rendering/`.

NR-0003 additionally proves that the selected Mac can run a materially larger
pretrained video prior at the requested proof rate. It does not make stock LTX
a renderer or a checkpoint ancestor: the observed fidelity/structure tradeoff
rejects that conditioning path. ADR-026 requires exactly aligned high-fidelity
targets plus a repository-defined title renderer trained from random
initialization before NR0-E.

Executed NR0-D evidence on 2026-08-08:

- six independent installed Metal captures retained 478 frames across
  `near-pass`, `fast-orbit`, `disocclusion-sweep`, `camera-cut`, `top-down`, and
  `resize-cycle`, including real 1280x720, 1440x900, and restored 1600x900
  source target transitions;
- the evaluator retained all 478 frame records, 9,374 visible-instance
  records, 478 reset-aware temporal records, and 4,307 visual evidence files,
  including measured worst temporal and disocclusion crops;
- full-frame model MAE was 0.03811 versus bilinear 0.16700, while
  valid-history temporal residual MAE was worse at 0.04090 versus 0.03318;
- model semantic-boundary and instance-boundary gradient MAE were both worse
  than bilinear, matching human-observed blur, edge bleed, and thin-feature
  loss;
- camera-cut frames 60/120 and resize frames 120/180/240 were individually
  inspected and contained complete independently readable output; and
- the external evaluation integrity inspector passed after the immutable
  accepted phase conclusion. The conclusion keeps NR-0002 explicitly
  unpromoted and unsuitable for NR0-E;
- NR0-C Python contracts passed 3/3, NR0-D Python contracts passed 4/4, and the
  two neural shader contracts passed; and
- full editor and non-editor repository tests passed, followed by a fresh
  installed 1,200-frame Metal fixture smoke with 23 fixture draws, 25 neural
  draws, 300 simulation ticks, live auxiliary-buffer inspection, and clean
  shutdown.

Retained NR0-D evidence:
`~/Library/Application Support/Incinerator/neural-rendering/experiments/nr0-d-20260807-a`.
Start with `evaluation-v2/evaluation.json` and
`evaluation-v2/conclusion.json`. The immutable `evaluation/` directory is
retained but superseded by the crop-complete second pass.

Executed NR0-C evidence on 2026-08-06:

- four independent installed S13 Metal captures completed with zero failures:
  8 controlled-fit frames, 40 default-follow train frames, 12 orbit-wide
  validation frames, and 12 elevated-sweep test frames;
- the schema-2 inspector verified every raw channel, target, manifest, digest,
  identity map, and split owner; the assembler rejected cross-split sequence or
  provenance drift and declared the 17-plane model ABI;
- offline Python NR0-C contracts passed 3/3 tests; the complete repository
  passed 285/285 build steps and 963/963 tests with the training packages still
  absent from runtime/headless graphs;
- the 51,888-parameter controlled-fit model reduced MAE from 0.17685 to 0.03233;
- held-out validation reduced MAE from 0.18025 to 0.02556 and raised SSIM from
  0.8074 to 0.8710; untouched test reduced MAE from 0.18479 to 0.02556 and
  raised SSIM from 0.7981 to 0.8661;
- human inspection of train, validation, and test comparison sheets found no
  blank frame or geometry drift and confirmed restoration of target palette
  and scene structure; and
- the FP16 Core ML export agreed with PyTorch within 0.000491 maximum absolute
  error; 500 warmed standalone predictions measured 5.077 ms p50, 5.720 ms
  p95, and 5.988 ms p99 using Core ML `ALL` compute units.

Retained NR0-C evidence:
`~/Library/Application Support/Incinerator/neural-rendering/experiments/nr-0002-20260806-a`.
Start with `experiment.json`; the external folder is evidence, not source or a
runtime selection. Reproduction and exact parameters are recorded in
[`NR-0002`](../../experiments/neural-rendering/nr-0002-multichannel-spatial-baseline/README.md).

Executed automated evidence on 2026-08-05:

- `zig build test -Deditor=false --summary all`: 270/270 build steps and
  959/959 tests passed;
- installed S1 offscreen conventional smoke: 160/160 ready frames;
- three independent installed S13 captures: each completed 3,840 frames,
  960 controlled ticks, the full twelve-member cohort, and all role/activity
  observations;
- installed S13 neural run: 3,840 predictions and zero adapter failures;
- missing-model S1 run: explicit fallback, zero readbacks, and successful
  completion; and
- offline Python tool contracts: 3/3 tests passed.

Executed NR0-A/B evidence on 2026-08-05:

- `zig build test-shaders --summary failures`: neural primitive/model MRT
  shader entry points, locations, uniform sizes, samplers, and generated Metal
  reflections passed;
- `zig build test -Deditor=false --summary failures` and
  `zig build test -Deditor=true --summary failures`: full repository tests,
  installed products, and M5/M6/MP6 boundaries passed in both compositions;
- `zig build verify-nr0-ab`: two independent 3,840-frame S13 Metal runs each
  completed 964 simulation ticks, retained the full twelve-member population,
  observed every authored role/activity requirement, and captured frames 300,
  360, and 420 with zero capture failures;
- capture inspection verified six frames, schema/channel order, source and
  canonical extents, declared byte counts, SHA-256 hashes, shader/source/content
  provenance, cohort/sequence ownership, stable identity mappings, exact
  cross-channel coverage masks, grayscale depth, unit-length decoded normals,
  binary motion history, manifest-backed semantic/instance pixels, and no
  compact-ID collision;
- the two fresh launches produced identical frame identity, camera/effect
  metadata, stable mappings, six raw channel digests, and conventional target
  digests; and
- human inspection of the generated 1200×900 contact sheet confirmed aligned
  conventional/appearance geometry, readable monotonic depth, corrected +Y
  world normals, visible history/motion variation, distinct semantic classes
  and vehicle parts, and distinct instance colors.

Retained acceptance evidence for this execution:
`~/Library/Application Support/Incinerator/neural-rendering/acceptance/nr0-ab-20260805-accepted-v3`.
The external folder is evidence, not checked-in source; reproduce it with the
commands in the neural-rendering tool README.

Accepted capture provenance:

| Field | Value |
|---|---|
| Source revision | `192cf7c773dd5b0347b5edb4341617e519492f52` |
| Working-tree identity | Exact dirty-source SHA-256 recorded in each external `capture.json`; intentionally not copied into this hashed working tree |
| Content SHA-256 | `4cf1512641aa88af49b71a09c4504c528d8ef4edaa070d7a79699e88d6cce290` |
| Input schema | `incinerator.neural-input.v1`; fingerprint `nr1|rgba8|400x225|appearance-srgb|depth-view-linear-0.1-250|normal-world|motion-prev-to-current-ndc-2|semantic-palette-v1|instance-rgb24|top-left|pixel-center|reversed-y|no-jitter|exposure-1` |
| Shader contract | `nr-input-mrt-v1|primitive/model|world-normal|linear-view-depth|prev-current-ndc` |
| Compiled shader SHA-256 | `73771bbb3013f30300e419dd2d79a5fa028195659700122f12e73a94853c1bdc` |
