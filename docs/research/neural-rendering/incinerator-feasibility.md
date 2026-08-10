# Incinerator Neural Rendering Feasibility

**Status:** Proposed technical baseline under accepted ADR-025

**Reviewed:** 2026-08-08

## Intended system

Incinerator continues to run the complete deterministic game. The neural model
does not receive keyboard input, make gameplay decisions, predict authority, or
invent entities. It translates a purpose-built presentation representation into
the final scene pixels.

```text
authoritative simulation
  -> immutable presentation extraction
  -> cheap deterministic rasterization
  -> versioned neural input textures
  -> title-specific runtime model
  -> final scene color
  -> conventional post/UI
  -> display
```

## Preliminary model baseline

Start with a compact spatial convolutional encoder-decoder trained from random
initialization on perfectly paired Incinerator frames:

- encode the low-resolution input;
- use local residual/convolutional blocks;
- upsample late, initially with explicit learned upsampling or pixel shuffle;
- predict a high-resolution RGB residual over a cheap deterministic base; and
- run one deterministic feed-forward inference per presented frame.

This was the correct first systems baseline and produced NR-0002. It was not a
quality ceiling. NR0-D subsequently demonstrated temporal, edge, and
fine-feature failures that another unconditioned compact reconstruction pass
would not answer by itself.

Initial losses should combine robust color error, spatial gradients or a
Laplacian term, structural similarity, frequency reconstruction, and explicit
semantic/instance boundary terms. No pretrained perceptual network participates
in training. Add a discriminator or learned detail objective from random
initialization only if measured results remain materially over-smoothed. Add
temporal loss after valid motion/depth reprojection and disocclusion masks
exist.

## Quality-first video-model baseline

NR-0003 next tested official LTX-Video 2B distilled at 512×288. It met the
target Mac proof rate at roughly 1.5 FPS and demonstrated a strong learned
material/lighting prior. Stock appearance-RGB video-to-video could not both
retain authored geometry and introduce high fidelity. That is a conditioning
failure, not a reason to return to increasingly elaborate small upscalers.

ADR-026 now fixes the recommended direction: implement a title-specific causal
neural renderer and train every learned component from random initialization.
The low-fidelity Incinerator render is the reference and a genuinely
high-fidelity render of the exact same frames is the target. Style is compiled
into title data, weights, and explicit artist controls rather than prompt text.
Depth, normals, motion, semantic identity, and instance identity remain the
durable engine contract and must not be silently discarded merely because the
stock research model accepted RGB. The detailed model and training sequence is
the [north star](../../design/title-neural-renderer-north-star.md).

## Input contract

The lowest useful baseline contains:

- low-resolution base color or albedo;
- linear depth;
- world- or view-space normals with one fixed convention;
- screen-space motion vectors with exact current/previous and jitter semantics;
- material and semantic class IDs;
- stable presentation instance IDs;
- roughness, metallic, and emissive values; and
- exposure and camera constants.

Useful later inputs include surface coordinates and explicit effect fields for
smoke, fire, water, weather, or particles. A model can only reproduce a target
difference when the input distinguishes the cause. If two different target
frames have identical inputs, training asks the model to average or invent.

Cheap appearance may be low resolution while depth, edges, IDs, or motion use
the `400×225` target extent when measurement proves that a structural pass
reduces model cost. The working proof uses only native `160×90 → 400×225`
material with an explicit 2.5× linear mapping. Historical artifacts at other
extents remain audit records and are excluded from generation, training,
comparison, preview, and acceptance. Other output resolutions are deferred.

## Paired data

One deterministic simulation/camera execution must produce both sides:

```text
same tick + camera + animation + effect seed + exposure
  -> cheap input buffer set
  -> high-quality conventional target
```

Incinerator replay can preserve the logical cohort. Capture must additionally
lock render dimensions, camera matrices and jitter, shader/content revisions,
random seeds, exposure/color transform, buffer schema, and target-renderer
configuration. Training, validation, and test splits must separate sequences or
camera paths rather than leaking adjacent frames across sets.

High-quality textures and effects may exist only in the title's training source
and need not ship to players. Their ownership and rights remain the title's
responsibility.

## Temporal extension

After the spatial baseline works:

1. reproject the previous output or compact feature state with motion vectors;
2. reject history using depth, instance identity, and disocclusion evidence;
3. use responsive masks for fast effects and newly revealed surfaces;
4. reset history on model change, resize, camera cut, content discontinuity,
   device recovery, replay seek, or invalid schema; and
5. keep the current frame independently renderable after a reset.

History must not feed authority or become durable game state.

## Primary unknowns

- Whether the current engine can produce sufficiently clean and complete input
  buffers without first building much of a conventional renderer.
- Whether a compact model can preserve small moving objects, textural identity,
  transparent effects, and disocclusions at the desired latency.
- Which Apple inference path provides the best end-to-end GPU scheduling and
  memory behavior for the supported hardware.
- Whether the target art renderer supplies enough variation without making the
  target internally inconsistent.
- Whether output-resolution activation/history memory, rather than weights,
  dominates the deployment envelope.
- Whether the title-specific model and target training data can be distributed
  under the eventual engine/game licensing arrangement.

NR0 exists to answer these with evidence before a broader renderer is designed.
