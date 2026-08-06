# Game-Specific Neural Rendering Landscape — July 2026

**Status:** Research snapshot

**Reviewed:** 2026-08-05

## Question

Can a deterministic game continue to own simulation, visibility, interaction,
and camera state while a title-specific model converts a cheap rasterized scene
into the final rendered pixels on the player's machine?

The evidence says this is a credible research direction. It does not yet prove
Incinerator's desired 60 FPS, consumer-memory, temporal-quality, or production
operability targets.

## Closest current evidence

### AlayaRenderer-Flash

AlayaRenderer-Flash is the closest public research match found in July 2026.
It keeps deterministic game physics and feeds rasterized G-buffer information
such as albedo, depth, normals, roughness, and metallic values into a causal
generative renderer. Its SuperTuxKart demonstration reports playable output at
832×448 and 31.54 FPS on one H200 while using 16.2 GB. Training used eight H200
GPUs, and formal evaluation clips were five seconds long.

This demonstrates the architectural split, not Incinerator's deployment goal.
The reported runtime hardware and memory are far above a 4 GB consumer target,
and the public repository does not yet provide a complete reproducible training
and runtime implementation.

- [Paper](https://arxiv.org/abs/2607.18703)
- [HTML paper](https://arxiv.org/html/2607.18703v1)
- [Public repository](https://github.com/AlayaLab/AlayaRenderer-Flash)

### DLSS 5

NVIDIA announced DLSS 5 in March 2026 for release in fall 2026. NVIDIA describes
it as consuming the game's color and motion vectors each frame and infusing
lighting and material behavior while remaining grounded in the source scene and
temporally consistent. This is strong commercial confirmation of the direction,
but it is proprietary and is not a training or runtime baseline Incinerator can
own.

- [NVIDIA announcement](https://nvidianews.nvidia.com/news/nvidia-dlss-5-delivers-ai-powered-breakthrough-in-visual-fidelity-for-games)

## Mature foundations worth retaining

The useful mature baseline is temporal neural reconstruction, not open-ended
video generation:

- Neural Supersampling for Real-Time Rendering demonstrates feed-forward
  reconstruction from current color, depth, motion, and temporal samples.
- XeSS documents an established runtime contract built around color, motion,
  depth, jitter, history, and responsive masks.
- Recent mobile and high-resolution auxiliary-buffer work reinforces late
  upsampling, cheap structural inputs, occlusion-aware history, and lightweight
  feature processing.

These systems reconstruct pixels while the game remains authoritative. Their
temporal history is a visual cache, not persistent world state.

- [Neural Supersampling for Real-Time Rendering](https://www.cs.jhu.edu/~misha/ReadingSeminar/Papers/Xiao20.pdf)
- [Intel XeSS developer guide](https://www.intel.com/content/www/us/en/developer/articles/guide/xe-super-sampling-developer-guide.html)
- [Mobile Neural Supersampling](https://discovery.ucl.ac.uk/id/eprint/10215223/)
- [High-resolution auxiliary G-buffer supersampling](https://eprints.bournemouth.ac.uk/41604/)

Apple's Metal 4 work is relevant to the current macOS target because it can
place machine-learning work into the GPU command stream. TensorOps target newer
Apple hardware; Core ML and MPSGraph remain the wider Apple Silicon evaluation
paths. This supports a no-CPU-readback runtime, but backend choice remains an
NR0 measurement decision.

- [Apple WWDC26: Bring machine learning to Metal apps](https://developer.apple.com/videos/play/wwdc2026/359/)

## Emerging versus unsuitable starting points

A causal or diffusion video generator may eventually improve realism, but it is
not the first Incinerator baseline. General video models optimize for broad
generation, prompts, and long synthesis rather than deterministic,
frame-synchronous rendering under a tight interactive budget. MiniMax H3-class
capability may be useful as an offline teacher or target-data tool, but not as
the initial shipped renderer.

The first baseline should be a compact, game-specific, feed-forward
convolutional encoder-decoder trained on perfectly paired captures. Temporal
state should be introduced only after a spatial baseline proves the data,
schema, target renderer, and promotion path.

## Conclusions retained by Incinerator

1. Keep simulation, camera, visibility, identity, and gameplay deterministic.
2. Give the model explicit cheap facts rather than asking it to infer hidden
   state.
3. Train for one title and one art direction before considering generality.
4. Treat temporal history as disposable presentation state with explicit reset.
5. Measure quality, temporal stability, latency, and memory on Apple Silicon;
   do not infer them from research hardware.
6. Preserve a conventional low-fidelity fallback and keep UI out of the neural
   image until after inference.

