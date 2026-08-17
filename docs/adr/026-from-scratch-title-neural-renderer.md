# ADR-026: From-Scratch Title-Specific Neural Renderer

**Status:** Accepted; implementation paused after RF10

**Date:** 2026-08-17

**Boundary:**
[ADR-025](025-game-specific-neural-rendering-boundary.md)

**North star:**
[`../design/title-neural-renderer-north-star.md`](../design/title-neural-renderer-north-star.md)

**Implementation plan:**
[`../design/title-neural-renderer-implementation-plan.md`](../design/title-neural-renderer-implementation-plan.md)

**Current portfolio status:**
[Neural Rendering Product-Track Pause](../design/neural-rendering-pause.md)

## Context

ADR-025 establishes neural rendering as presentation infrastructure and
separates engine/runtime code, mutable experiments, and deliberately promoted
game content. Early experiments proved the input, capture, evaluation, export,
fallback, and native inference seams. NR-0003 then used pretrained LTX-Video 2B
as an architectural probe. It demonstrated that a large learned video prior can
add dramatic materials and lighting at the requested proof rate, but stock RGB
conditioning replaces authored structure when asked to make a substantial
visual transformation.

The product goal is not to integrate or fine-tune a general video model. The
goal is an engine-supported method for each Incinerator title to train its own
graphics predictor from scratch:

```text
cheap deterministic title render + exact presentation controls
  -> title-owned model trained from random initialization
  -> high-fidelity pixels for the same world, camera, identities, and time
```

This is closer to game-trained neural supersampling, denoising, and material
reconstruction than prompt-driven video generation. The title's model may
learn a much larger visual difference than conventional supersampling, but it
must remain a renderer of authored state rather than a generator of substitute
state.

## Decision

### Promoted weights are trained from scratch for one title

Every promotion-eligible model and every learned component it depends on must:

- begin from a declared random initialization;
- be trained exclusively on data whose provenance and rights belong to the
  title or its explicitly approved source corpus;
- record the architecture source, initializer, seed, training recipe, dataset
  digest, engine/content/target-renderer revisions, and full checkpoint lineage;
- contain no inherited foundation-model, image-model, video-model, perceptual-
  model, VAE, text-encoder, control-adapter, or super-resolution weights; and
- be reproducible through the repository-owned training framework and external
  immutable run artifacts.

General numerical libraries, tensor runtimes, optimizers, codecs, and inference
backends are implementation dependencies rather than learned weights and may be
used when their licenses and provenance are recorded.

External pretrained models may be retained as research comparisons. They may
not initialize a candidate, teach through distillation, create pseudo-targets,
define a training loss, or cross the promotion boundary unless a future ADR
explicitly changes this decision. Learned evaluation metrics may be reported
as secondary research measurements, but they cannot be the sole acceptance
gate and cannot influence training under this contract.

### Incinerator owns a reusable title-training framework

The open engine owns the contracts and tools needed to:

1. render deterministic low-cost inputs and exact auxiliary controls;
2. invoke a title-selected high-fidelity target producer for the same frame;
3. validate, split, version, and inspect paired sequences;
4. initialize, train, resume, evaluate, compare, and export repository-defined
   model architectures;
5. retain immutable run, checkpoint, metric, visual, environment, and lineage
   evidence outside Git; and
6. transactionally promote one accepted title model into game content.

The engine does not ship one universal model. The engine framework is reusable;
datasets, target assets, weights, art direction, and promotion decisions belong
to each title.

### The high-fidelity target is visual truth

Training pairs must represent the same authoritative tick, camera, geometry,
animation, effect phase, exposure, identity, and intended composition. The
target may be produced by an offline renderer, a high-quality engine mode, or
another deterministic title-owned renderer adapter. It cannot be an unrelated
generated interpretation.

When low-cost inputs do not distinguish two desired outputs, the contract must
add a deterministic presentation signal rather than ask the model to guess.
Examples include material and asset identity, surface coordinates, lighting or
shadow features, effect phase, and history validity. Unique stable detail may
be encoded in title weights or title embeddings keyed by explicit presentation
identity; it may not be selected from private gameplay state.

### The model family is a causal, densely conditioned neural renderer

The initial architecture family is a game-specific spatiotemporal
reconstruction model, not a language-conditioned world model:

- a low-resolution appearance encoder;
- one or more compact high-resolution structural-control encoders;
- motion/depth/identity-guided alignment and history rejection;
- a causal recurrent or windowed-attention backbone;
- a high-resolution reconstruction head; and
- when deterministic reconstruction proves too smooth, an optional
  title-trained high-frequency residual head using adversarial or conditional
  flow objectives.

The structural path remains directly supervised and independently evaluable.
A learned detail path may enrich materials, lighting, texture, hair, smoke, or
other target phenomena, but it cannot own object existence, pose, silhouette,
camera, or time. Runtime noise, if an experiment proves it necessary, must be
deterministically anchored to stable surface/instance/time inputs and reset by
the declared presentation history contract.

The exact convolution/transformer balance, latent representation, parameter
count, temporal window, objective weights, precision, and runtime backend are
experimental decisions. They are not fixed by this ADR.

### Style is compiled into title data and weights

The runtime model does not require natural-language prompting. Art direction
comes from the target corpus and explicit deterministic artist controls such as
time of day, weather, grade, or effect intensity. A title may train multiple
deliberately selected model bundles, but runtime never invents a style from an
ambient prompt or downloads weights.

## Consequences

### Positive

- The final renderer is designed for Incinerator's exact inputs and one game's
  visual distribution rather than carrying a broad natural-video prior.
- Model and dataset provenance can be owned, audited, reproduced, and licensed
  with the separately licensed game.
- Dense engine controls can preserve authored structure more reliably than
  appearance-only generation.
- The engine can improve its general training framework while each title owns
  its art, data, and weights.
- No external model vendor or hosted inference service becomes a runtime or
  training dependency.

### Costs and risks

- The title must produce enough high-quality, varied, exactly paired target
  data to learn materials, lighting, effects, motion, and failure cases.
- Training from scratch removes the semantic prior that made stock LTX visually
  impressive, so corpus coverage and model curriculum become first-order work.
- A low-fidelity render alone cannot reconstruct stable unique details that are
  absent from every input; the presentation schema must expose sufficient
  identity and surface information.
- Target rendering, dataset generation, training, evaluation, and content
  refresh become part of the game's normal production pipeline.
- Large from-scratch video models may exceed local training capability. The
  framework must measure that honestly and scale architecture or training
  hardware without changing model provenance.

## Relationship to completed experiments

- NR-0001 and NR-0002 remain valid proofs of repository-owned random-
  initialization training, export, native inference, and failure evaluation.
- NR-0003 remains a valid external-model comparison and an architectural
  lesson about learned visual priors, latent video processing, and the failure
  of weak RGB anchoring. It is not an ancestor of a product checkpoint.
- No completed checkpoint is promotion-worthy. NR0-E remains blocked.

## Explicit non-decisions

This ADR does not select the final target renderer, art style, corpus size,
parameter count, temporal window, resolution, diffusion/flow formulation,
training hardware, inference backend, or performance budget. Those decisions
must follow measured experiments under the north-star sequence.
