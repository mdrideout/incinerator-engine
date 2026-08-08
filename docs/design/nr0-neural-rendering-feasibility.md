# NR0 Game-Specific Neural Rendering Feasibility Slice

**Status:** In progress; NR0-A through NR0-D complete, NR0-E through NR0-G open

**Date:** 2026-08-08

**Platform:** Apple Silicon macOS only

**Decision:**
[ADR-025](../adr/025-game-specific-neural-rendering-boundary.md)

**Evaluation scene:**
[NR0 Evaluation Scene](nr0-neural-rendering-evaluation-scene.md)

**NR0-D implementation plan:**
[Evaluation and failure analysis](nr0-d-evaluation-and-failure-analysis.md)

**Validation ledger:**
[`../validation/nr0-neural-rendering-feasibility.md`](../validation/nr0-neural-rendering-feasibility.md)

## Goal

Prove one end-to-end title-specific neural-rendering path in the real
Incinerator product: exact low-fidelity GPU inputs and a paired conventional
target produce an evaluated spatial model; a human deliberately promotes one
export; the installed macOS runtime loads that exact bundle, presents its
output, exposes its cost and identity, and falls back truthfully.

NR0 is a parallel core-rendering track. It does not replace or renumber the
gameplay S-series.

## Preliminary NR-0001 checkpoint

The first critical-path proof completed on 2026-08-05 before the richer NR0
buffer ABI was designed. It intentionally answers “can this repository and Mac
execute the whole loop?” before asking the art-quality question.

| Capability | Executed result | NR0 disposition |
|---|---|---|
| Product/UI boundary | Product scene renders offscreen and resolves before editor UI | Retain as core presentation boundary |
| Existing-frame tool smoke | MPS train/evaluate/export/Core ML predict succeeded | Superseded as primary evidence by engine capture; retained as loader smoke |
| Exact engine product-color pairs | Three independent S13 Metal runs captured 80 train, 80 validation, and 80 test frames | Valid pipeline evidence; insufficient for NR0-B auxiliary-buffer acceptance |
| Spatial baseline | 25,552 parameters; untouched-test MAE 0.04348 versus bicubic 0.05134 | Candidate pipeline passes; no art-direction claim |
| Export | FP16 ML Program; max PyTorch/Core ML error 0.001274 | Candidate export passes; not promoted content |
| Native runtime | 3,840-frame S13 run, 3,840 predictions, zero failures, UI outside inference | Technical proof passes; CPU-staged bridge is disposable |
| Failure | Missing model selected explicit conventional fallback and completed the Metal smoke | Preliminary fallback passes |
| Runtime cost | Standalone Core ML p50 0.465 ms; staged live mean 5.579 ms, max 11.409 ms at 80x45→320x180 | Confirms GPU-resident staging is required before NR0-F acceptance |

External evidence roots and exact commands are recorded in
[`../../experiments/neural-rendering/nr-0001-spatial-pipeline/README.md`](../../experiments/neural-rendering/nr-0001-spatial-pipeline/README.md).
No generated dataset, checkpoint, or model package is committed.

## Definition of the slice

The slice is not complete when a notebook produces an attractive image. It is
complete when one real evaluation scene traverses every boundary:

```text
deterministic replay/camera cohort
  -> cheap raster + exact auxiliary buffers
  -> paired target capture
  -> spatial training run
  -> held-out evaluation
  -> explicit immutable promotion
  -> installed runtime inference
  -> low-fidelity fallback
  -> diagnostics, incident evidence, and human comparison
```

## Phase sequence

### NR0-A — Presentation schema and debug views

**Status:** Complete on 2026-08-05.

- Define the smallest engine-owned input/output schema.
- Establish exact texture formats, coordinate systems, color/exposure, depth,
  motion-vector, jitter, semantic class, stable instance identity, and resize
  behavior.
- Extract immutable presentation data without exposing gameplay internals.
- Render every input independently in developer tooling and capture it in a
  machine-readable frame manifest.
- Record schema and content/shader fingerprints.

**Exit:** a human and an automated inspector can verify the meaning and
alignment of every buffer in the real evaluation scene.

Implemented as engine contract `incinerator.neural-input.v1`: 400×225 RGBA8
appearance, linear view depth, world normal, previous-to-current NDC motion,
semantic, and stable compact instance channels. The presentation-only GPU host
mirrors immutable product draws into one six-target pass. The Neural Rendering
Lab exposes all channels and schema, shader, history, identity-collision,
render, model, and capture diagnostics. Shader ABI/reflection tests and a human
contact sheet validate the encodings and alignment.

### NR0-B — Deterministic paired capture

**Status:** Complete on 2026-08-05.

- Add a capture host/tool path that runs the same simulation tick, camera,
  effect seed, exposure, and dimensions through cheap-input and target paths.
- Keep capture/training dependencies outside product and cold-authority graphs.
- Write atomic dataset manifests with frame identity, all fingerprints, and
  completeness status.
- Split training, validation, and test data by sequence/camera cohort.
- Prove recapture of the same cohort preserves logical identity and declared
  deterministic buffer digests where the renderer contract promises them.

**Exit:** one inspectable, rights-attributed paired corpus exists outside Git.

Implemented as capture schema 2. A selected frame is fenced after successful
presentation, writes the six raw input textures, human-readable PPM
derivatives, a canonical 1600×900 conventional target, stable identity
mappings, camera and frame state, source/content/schema/shader fingerprints,
and SHA-256 digests. Backend product color is normalized to canonical RGBA8
while retaining its source GPU format as provenance. Capture roots are
absolute, exclusive, external,
atomically marked partial/complete, and explicitly owned by cohort, sequence,
and camera path. The inspector rejects incomplete, corrupt, cross-cohort,
identity-drifting, or non-repeatable captures. `zig build verify-nr0-ab`
executes two fresh S13 runs, requires byte-identical declared buffers, and
emits a visual report.

### NR0-C — Spatial model baseline

**Status:** Complete on 2026-08-06.

- Implement the smallest feed-forward convolutional encoder-decoder that can
  overfit one controlled cohort.
- Advance to held-out camera paths, locations, motion, materials, identities,
  and lighting only after the overfit test proves the data path.
- Record exact environment, configuration, seeds, code/data revisions,
  checkpoints, metrics, samples, and exported candidates in one run folder.
- Compare against bilinear/bicubic and the cheap deterministic render.

**Exit:** an exported candidate beats declared non-neural baselines on the
accepted numerical and human comparison without test-frame leakage.

Implemented in
[`NR-0002`](../../experiments/neural-rendering/nr-0002-multichannel-spatial-baseline/README.md).
The schema-2 adapter packs the six RGBA8 captures into an explicit 17-plane
ABI. A 51,888-parameter low-resolution residual encoder/decoder first passed an
eight-frame controlled-fit gate, then trained on a separate default-follow
sequence. Epoch selection used only an orbit-wide validation path; the
elevated-sweep test path was evaluated once afterward. Nearest, bilinear,
bicubic, and model MAE/MSE/PSNR/SSIM are preserved with full-frame comparisons.
The held-out model beat every deterministic baseline, exported to a fixed-shape
FP16 Core ML package, and passed PyTorch/Core ML agreement. It remains an
external, unpromoted candidate. S13 establishes the spatial model baseline;
dedicated art materials, effects, temporal pressure, and failure-envelope work
remain NR0-D rather than being implied by this result.

### NR0-D — Evaluation and failure analysis

**Status:** Complete on 2026-08-08. The executed contract and findings are
recorded in
[NR0-D evaluation and failure analysis](nr0-d-evaluation-and-failure-analysis.md).

- Measure color/structure/perceptual quality and semantic edge/identity
  retention.
- Inspect motion, disocclusion, small-object, transparency/effect, camera-cut,
  resize, exposure, and out-of-distribution failures.
- Measure offline candidate inference, process/MPS memory, and capture/evidence
  cost on the declared Apple hardware; explicitly defer installed GPU-resident
  timing, residency, frame pacing, and fallback cost to NR0-F.
- Preserve full-frame and cropped comparisons for human review.

**Exit:** the candidate's useful envelope and unacceptable failures are
explicit; no promotion follows from one aggregate score.

Implemented with a 23-identity, presentation-only fixture; six deterministic
stress camera programs; explicit camera-cut and real-resize reset delivery; and
an exhaustive checkpoint evaluator covering every frame, visible instance,
boundary, valid-history pixel, and disoccluded pixel. The accepted external
evaluation retains 478 frames, 9,374 instance records, 478 temporal records,
and 4,307 visual artifacts, including measured worst temporal and disocclusion
crops. NR-0002 improves broad spatial and disocclusion
reconstruction, but is less boundary-sharp and less temporally stable than
bilinear and visibly loses thin/fine features. NR0-D is accepted; NR-0002 is
not suitable for promotion and remains external and unpromoted.

The next actual model step is a bounded NR-0003 spatial failure-correction
experiment evaluated against the unchanged NR0-D stress fixture. NR0-E remains
the next engine phase, but it should not begin by promoting a candidate already
shown to miss the accepted quality envelope.

### NR0-E — Explicit model promotion

- Implement a promotion tool that accepts one evaluated export and a target
  promoted-model source root.
- Validate rights/provenance, schema, dimensions, backend requirements,
  evaluation record, and artifact digests before mutation.
- Copy into a temporary bundle, verify the copied bytes, then atomically publish
  the immutable bundle and selected-model manifest.
- Reject destination collisions and partial/stale evaluation.
- Never modify or delete the original experiment run.

**Exit:** one exact candidate is selected without a mutable `latest` path.

### NR0-F — Installed macOS runtime

- Introduce the narrow engine rendering contract, neural host, content bundle
  loader, and one macOS adapter only when the live slice needs them.
- Keep inference textures on the GPU and record synchronization explicitly.
- Validate the selected manifest before allocating model/history resources.
- Compose scene inference before conventional UI and diagnostic overlays.
- Handle startup absence/rejection, resize, camera cut, model change, device
  loss, and inference failure through explicit history reset and fallback.
- Prove normal headless and conventional graphical builds do not acquire
  training dependencies.

**Exit:** the installed product loads only the selected digest, renders the
evaluation scene, identifies the active model/schema in diagnostics, and
survives every declared fallback transition.

### NR0-G — Acceptance, audit, and extraction

- Add renderer-neutral contract tests, model-bundle tests, installed Metal
  smoke, replay-driven visual comparisons, incident evidence, and repeated
  performance runs.
- Human-test motion, identity, fine detail, disocclusion, camera cuts, effects,
  resize, fallback, and return from fallback.
- Audit dependency direction, cold/headless closure, artifact provenance,
  generated-file hygiene, stale experiment references, and monolithic renderer
  growth.
- Update this plan, the validation ledger, performance baseline, architecture
  review, and README with measured results.

**Exit:** the end-to-end slice is accepted or rejected with preserved evidence.
Accepted capability contracts may then become core engine infrastructure.

## Implementation locations

The implemented foundation uses:

```text
src/adapters/neural_rendering/macos.h
src/adapters/neural_rendering/macos.m
src/hosts/neural_rendering_host.zig
src/hosts/neural_capture_host.zig
src/hosts/neural_input_host.zig
src/engine/contracts/neural_rendering.zig
src/editor/tools/neural_rendering_lab_tool.zig
```

The versioned input contract is now engine-owned. The promoted-bundle content
owner remains future NR0-E work and will live under `src/content/` only when
that phase begins.

Do not put capture, model selection, history policy, inference orchestration, or
experiment code into `src/renderer.zig`. That file may remain the owner of
renderer primitives and GPU presentation targets while the new owners retain
their own lifecycles.

The current repository scaffold is:

```text
docs/research/neural-rendering/   evidence and feasibility reasoning
experiments/neural-rendering/     committed experiment intent and conclusions
tools/neural-rendering/           capture inspection plus offline train/evaluate/export/promote tools
models/neural-rendering/          deliberately promoted sandbox runtime bundles
fixtures/nr0_neural_renderer/     conformance/evaluation source assets
```

Large mutable artifacts remain outside Git.

## Acceptance rules

- Authority and replay logical digests are unchanged by neural mode.
- The model receives no player input, transport object, authority pointer,
  Flecs entity, Jolt handle, or durable state.
- Buffer and bundle schemas fail closed; no compatibility decoder exists.
- The product never loads an experiment checkpoint or mutable `latest` path.
- The exact selected model ID and digest appear in runtime diagnostics,
  screenshots/incidents, and performance evidence.
- The conventional fallback is independently usable and visually labeled in
  developer evidence.
- UI remains readable and outside the inferred scene.
- Training dependencies are absent from runtime, headless, and server products.
- Promotion is repeatable, transactional, provenance-preserving, and never
  mutates the source run.
- Quality claims name the dataset split and baseline; performance claims name
  the hardware, build mode, resolution, model, and capture cost.
- Human acceptance covers temporal readability even before a temporal model is
  introduced.

## Deferred until evidence demands them

- temporal model state beyond an explicit follow-up experiment;
- diffusion, adversarial runtime sampling, or a full-resolution transformer;
- generic multi-title training or model marketplace support;
- cloud inference or runtime training;
- secondary-platform inference adapters;
- model hot reload in the normal product;
- arbitrary plugin graphs or a general render graph rewrite;
- a hosted experiment registry; and
- an engine license, game license, or model distribution policy.
