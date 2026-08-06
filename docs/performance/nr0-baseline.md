# NR0 Neural Rendering Performance Baseline

**Status:** Preliminary NR-0001 proof measured; full NR0 baseline open

**Date:** 2026-08-05

Record the first accepted baseline here. Do not copy performance from research
papers into the Incinerator result table.

The report must name:

- Apple hardware, OS, power state, and relevant GPU/runtime backend;
- engine/model/content/shader/schema revisions and model digest;
- build mode and inference precision;
- input, structural-buffer, target, and display dimensions;
- model load time and resource residency;
- CPU frame, GPU raster, inference, post/UI, present, and end-to-end timing;
- p50, p95, p99, worst observed frame, and sustained frame pacing;
- model weights, activations, inputs, outputs, history, capture, and total process
  memory where observable;
- fallback cost and transition behavior; and
- whether capture/debug evidence was enabled.

No frame-rate, memory, model-size, or hardware support target is accepted until
this repository measures a repeatable real cohort.

## NR-0001 preliminary measurements

These numbers validate the local path; they are not an accepted shipping
budget.

| Item | Result |
|---|---|
| Hardware | MacBook Pro, Apple M2 Max, 38-core GPU, 64 GB unified memory |
| OS/runtime | macOS 15.7.7, Metal 3, Core ML, Python 3.13.12 |
| Training cohort | PyTorch 2.7.0, torchvision 0.22.0, MPS; 40 epochs over 80 exact engine train pairs |
| Model | 25,552 parameters, fixed 4x RGB residual upscaler, FP16 ML Program compute |
| Dimensions | 80x45 RGB input, 320x180 RGB output; live output linearly presented at the drawable size |
| Training wall time | 3,987 ms after environment/model startup |
| Validation | model MAE 0.04273 / PSNR 19.25 dB; bicubic MAE 0.05059 / PSNR 18.78 dB |
| Untouched test | model MAE 0.04348 / PSNR 19.16 dB; bicubic MAE 0.05134 / PSNR 18.68 dB |
| PyTorch/Core ML agreement | mean absolute error 0.000171; maximum 0.001274 |
| Core ML package load | 71.19 ms |
| Standalone Core ML prediction | 500 iterations after 50 warmups: p50 0.465 ms, p95 0.558 ms, p99 0.627 ms, max 0.716 ms |
| Native staged live path | 480 predictions: staged readback plus inference mean 5.579 ms, max 11.409 ms; last model inference 0.372 ms |
| Full scripted live proof | 3,840 S13 predictions, zero failures; S13 acceptance unchanged |

The staged number excludes asynchronous output-upload GPU completion and normal
scene/UI GPU work. It includes a blocking product-texture downsample/readback,
CPU layout conversion, and Core ML prediction. It therefore demonstrates the
cost center rather than hiding it: native Core ML execution is small for this
toy model, while CPU staging dominates. A GPU-resident adapter and complete
frame/GPU/memory instrumentation remain prerequisites for NR0-F/D acceptance.
