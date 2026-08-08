# ADR-025: Game-Specific Neural Rendering Boundary and Model Promotion

**Status:** Accepted; NR0-A through NR0-C implemented, full NR0 remains open

**Date:** 2026-08-07

**Platform:** Apple Silicon macOS first

**Research:**
[`../research/neural-rendering/README.md`](../research/neural-rendering/README.md)

**Implementation plan:**
[`../design/nr0-neural-rendering-feasibility.md`](../design/nr0-neural-rendering-feasibility.md)

## Context

Incinerator is adopting a title-specific neural renderer as a core engine
direction. The game remains a deterministic simulation and produces a cheap,
low-fidelity raster representation. A model trained for the game's selected art
direction converts that representation into final scene pixels on the player's
machine.

This direction creates three lifecycles that must not be conflated:

1. engine/runtime code and its rendering contract;
2. mutable research datasets, runs, checkpoints, and comparisons; and
3. one deliberately promoted, immutable model bundle consumed as game content.

Putting all three inside `renderer.zig`, loading a mutable “latest” checkpoint,
or allowing the model to observe authority internals would erase ownership and
make runtime results impossible to reproduce.

## Decision

### Neural rendering is presentation infrastructure

Neural rendering is a horizontal presentation capability, not a gameplay
feature under `src/features/`. It may consume only immutable presentation data
and renderer-owned GPU resources. It cannot read or mutate Flecs, Jolt, session
authority, transport state, durable saves, or private gameplay components.

The delivered unit remains a vertical slice:

```text
real evaluation scene
  -> immutable presentation extraction
  -> cheap deterministic rasterizer
  -> versioned neural inputs
  -> selected runtime model
  -> final scene color
  -> post/UI and display
  -> diagnostics and acceptance evidence
```

The conventional low-fidelity result remains a valid fallback. UI, editor
chrome, diagnostic overlays, accessibility graphics, and text are composed
after neural scene inference unless a later measured experiment explicitly
proves another contract.

### Ownership

| Owner | Responsibility |
|---|---|
| Gameplay features | Authoritative behavior and immutable presentation values |
| Rendering contract | Versioned buffer meanings, formats, dimensions, color conventions, motion/depth semantics, and history reset events |
| Cheap rasterizer | Deterministic GPU textures required by the selected schema |
| Neural rendering host | Frame sequencing, input assembly, history lifecycle, inference/fallback selection, and composition |
| macOS neural adapter | Model loading, GPU resources, inference submission, synchronization, and backend diagnostics |
| Content loader | Exact promoted-bundle discovery, digest validation, and typed rejection |
| Experiment tools | Paired capture, training, evaluation, export, and candidate records outside the product runtime |
| Promotion tool | Transactional copy of one evaluated export into one immutable runtime bundle and explicit selection update |
| Title/game | Target art assets, datasets, experiment choices, promoted weights, distribution rights, and human art-direction acceptance |
| Open engine sandbox | A small redistributable conformance fixture/model when rights and size policy are explicitly accepted |

Training frameworks and Python packages cannot become runtime dependencies of
the engine or cold authority products.

### The model bundle is versioned game content

The runtime never searches for “best”, “newest”, or a mutable experiment path.
It loads the exact bundle named by a selected-model manifest. The selected
manifest and bundle are promoted together and record at least:

- model ID, immutable artifact digest, and model format;
- neural input/output schema versions;
- expected dimensions, scale, channels, texture formats, ordering, and
  normalization;
- color space, exposure, depth, motion-vector, jitter, semantic-ID, and
  instance-ID conventions;
- temporal inputs, state shape, and every reset condition;
- required backend and supported hardware cohort;
- source experiment, dataset, engine, content, shader, and target-renderer
  fingerprints;
- evaluation summary and performance evidence; and
- license or distribution-rights provenance.

An exact schema or digest mismatch is rejected. This greenfield track provides
no compatibility decoder for superseded model or buffer cohorts.

The future build installs only the selected bundle beneath
`share/incinerator/content/neural-rendering/`. Absence or rejection selects the
explicit conventional fallback; it does not silently choose another model.

### Experiment output is not runtime content

Large generated datasets, checkpoints, frame captures, and temporary exports
live in an explicit artifact root outside Git. Git retains experiment intent,
reproducible configuration once implemented, source revisions, small review
evidence, and conclusions. A filesystem-backed run registry is sufficient
until repeated work demonstrates a need for a service.

Promotion is a human decision after automated evaluation. It copies one exact
evaluated export into the promoted-model source area, creates provenance and
evaluation manifests, verifies digests and schema, and updates the explicit
selection atomically. Runtime code never reads directly from an experiment run.

### macOS first without a speculative portability layer

NR0 targets Apple Silicon macOS and evaluates Core ML, MPSGraph, and Metal
integration only as needed to choose the smallest working adapter. The public
engine contract names rendering semantics, not those frameworks. Linux,
SteamOS, Windows, CUDA, DirectML, Vulkan ML, and cross-vendor model formats
remain deferred until the product selects another platform.

## Consequences

## Implementation checkpoints

NR-0001 now implements a deliberately narrower proof beneath this decision:

- `Renderer` owns a product-only color texture and resolves it to the
  swapchain before conventional UI and diagnostics;
- an opt-in capture host records exact same-frame 80x45 input and 320x180
  conventional product-color target pairs with source/tick/frame identity and
  digests;
- repository-owned Python tools prepare declared whole-run splits, train one
  25,552-parameter spatial residual upscaler on MPS, compare against bicubic,
  export a fixed-shape FP16 ML Program, and benchmark Core ML;
- an opt-in macOS adapter performs native Core ML prediction from product color
  only, presents the result one frame later, toggles with `N`, and falls back
  on absence or rejection; and
- headless and server graphs remain free of Core ML and training dependencies.

This checkpoint does not change the model-bundle decision. Its model path is an
explicit developer experiment path, not runtime content or promotion. Its
blocking CPU readback/upload is a measured disposable bridge.

NR0-A/B subsequently establish the accepted foundation beneath this ADR:

- engine-owned `incinerator.neural-input.v1` defines six 400×225 RGBA8
  appearance, linear-depth, world-normal, motion, semantic, and instance
  channels with explicit coordinate, history, and identity conventions;
- a presentation-only Metal MRT host mirrors immutable product draws without
  authority access and exposes all channels and state in the Neural Rendering
  Lab;
- capture schema 2 pairs those exact raw inputs with the submitted scene at a
  canonical 1600×900, records full frame/camera/identity/provenance metadata,
  and hashes every artifact; and
- deterministic two-launch acceptance validates split ownership, identity
  stability, byte equality, and human-visible channel alignment.

NR0-C subsequently establishes the first multi-channel spatial candidate:

- a versioned dataset adapter packs the six captures into an explicit 17-plane
  model ABI without authority or private gameplay inputs;
- a 51,888-parameter residual convolutional model passes controlled fit before
  training on a separate sequence;
- validation and test own disjoint deterministic camera programs, with test
  evaluated only after validation selection;
- nearest, bilinear, and bicubic comparisons plus full-frame human evidence
  establish the spatial result; and
- one fixed-shape FP16 Core ML export and standalone benchmark remain external,
  immutable, and unpromoted.

NR0 still owes the dedicated failure-analysis fixture, temporal and
out-of-distribution evaluation, GPU-resident inference adapter, promotion,
installed bundle validation, full end-to-end performance evidence, and final
human acceptance.

### Positive

- Gameplay remains deterministic, headless, network-authoritative, and
  independently testable.
- Experiments can move quickly without making mutable research state part of
  the shipped game.
- Exact promotion makes a runtime build attributable and reproducible.
- The model can be replaced without changing gameplay ownership.
- A low-fidelity fallback preserves startup, diagnostics, device recovery, and
  unsupported-hardware behavior.

### Costs and risks

- The engine must produce clean, stable auxiliary buffers and exact motion and
  history semantics.
- Paired target rendering is a substantial content and tooling effort.
- Output-resolution activations and temporal history may dominate memory.
- Model and dataset rights belong to the title and must be proven before
  distribution.
- Human perceptual acceptance remains necessary even when numerical metrics
  pass.

## Explicit non-decisions

ADR-025 does not select a final model architecture, parameter count, memory
cap, inference framework, model file format, quantization, temporal design,
target art style, dataset size, frame rate, or distribution mechanism. NR0 must
measure those decisions rather than inventing limits.

It also does not authorize diffusion, a general video model, a learned world
model, authority feedback, runtime training, cloud inference, or replacement of
the deterministic renderer fallback.
