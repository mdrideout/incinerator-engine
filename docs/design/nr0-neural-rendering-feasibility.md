# NR0 Game-Specific Neural Rendering Feasibility Slice

**Status:** In progress; preliminary NR-0001 spatial pipeline proof complete,
NR0-A through NR0-G remain open

**Date:** 2026-08-05

**Platform:** Apple Silicon macOS only

**Decision:**
[ADR-025](../adr/025-game-specific-neural-rendering-boundary.md)

**Evaluation scene:**
[NR0 Evaluation Scene](nr0-neural-rendering-evaluation-scene.md)

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

### NR0-B — Deterministic paired capture

- Add a capture host/tool path that runs the same simulation tick, camera,
  effect seed, exposure, and dimensions through cheap-input and target paths.
- Keep capture/training dependencies outside product and cold-authority graphs.
- Write atomic dataset manifests with frame identity, all fingerprints, and
  completeness status.
- Split training, validation, and test data by sequence/camera cohort.
- Prove recapture of the same cohort preserves logical identity and declared
  deterministic buffer digests where the renderer contract promises them.

**Exit:** one inspectable, rights-attributed paired corpus exists outside Git.

### NR0-C — Spatial model baseline

- Implement the smallest feed-forward convolutional encoder-decoder that can
  overfit one controlled cohort.
- Advance to held-out camera paths, locations, motion, materials, identities,
  and lighting only after the overfit test proves the data path.
- Record exact environment, configuration, seeds, code/data revisions,
  checkpoints, metrics, samples, and exported candidates in one run folder.
- Compare against bilinear/bicubic and the cheap deterministic render.

**Exit:** an exported candidate beats declared non-neural baselines on the
accepted numerical and human comparison without test-frame leakage.

### NR0-D — Evaluation and failure analysis

- Measure color/structure/perceptual quality and semantic edge/identity
  retention.
- Inspect motion, disocclusion, small-object, transparency/effect, camera-cut,
  resize, exposure, and out-of-distribution failures.
- Measure end-to-end latency, GPU time, peak/resident memory, upload/readback,
  frame pacing, and fallback cost on the declared Apple hardware.
- Preserve full-frame and cropped comparisons for human review.

**Exit:** the candidate's useful envelope and unacceptable failures are
explicit; no promotion follows from one aggregate score.

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

The preliminary proof currently uses:

```text
src/adapters/neural_rendering/macos.h
src/adapters/neural_rendering/macos.m
src/hosts/neural_rendering_host.zig
src/hosts/neural_capture_host.zig
```

The versioned engine contract and promoted-bundle content owner remain future
NR0 work and will live under `src/engine/contracts/` and `src/content/` only
when those phases begin.

Do not put capture, model selection, history policy, inference orchestration, or
experiment code into `src/renderer.zig`. That file may remain the owner of
renderer primitives and GPU presentation targets while the new owners retain
their own lifecycles.

The current repository scaffold is:

```text
docs/research/neural-rendering/   evidence and feasibility reasoning
experiments/neural-rendering/     committed experiment intent and conclusions
tools/neural-rendering/           future offline capture/train/evaluate/export/promote entry points
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
