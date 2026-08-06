# Incinerator Neural Rendering Feasibility

**Status:** Proposed technical baseline under accepted ADR-025

**Reviewed:** 2026-08-05

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

## Recommended first model

Start with a compact spatial convolutional encoder-decoder trained from random
initialization on perfectly paired Incinerator frames:

- encode the low-resolution input;
- use local residual/convolutional blocks;
- upsample late, initially with explicit learned upsampling or pixel shuffle;
- predict a high-resolution RGB residual over a cheap deterministic base; and
- run one deterministic feed-forward inference per presented frame.

Do not begin with diffusion, GAN-only training, a full-resolution transformer,
prompt conditioning, a learned world model, or gameplay input.

Initial losses should combine robust color error, spatial gradients or a
Laplacian term, structural similarity, and a perceptual term. Add adversarial
training only if measured results remain materially over-smoothed. Add temporal
loss only after valid motion/depth reprojection and disocclusion masks exist.

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

Cheap appearance may be low resolution while depth, edges, IDs, or motion are
higher resolution when measurement proves that a cheap structural pass reduces
model cost. The current 1600×900 product has an exact 4× spatial baseline at
400×225. A 320×180 input maps cleanly to 1280×720; 320×240 does not match the
current 16:9 product.

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

