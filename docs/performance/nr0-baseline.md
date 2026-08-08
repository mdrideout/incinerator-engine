# NR0 Neural Rendering Performance Baseline

**Status:** NR-0001, NR0-A/B foundation, NR0-C standalone model, and NR0-D
offline stress evaluation measured; full installed runtime baseline open

**Date:** 2026-08-08

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
frame/GPU/memory instrumentation remain prerequisites for NR0-F acceptance.

## NR0-A/B foundation measurements

These figures characterize the input and capture foundation, not inference
performance or a shipping budget.

| Item | Result |
|---|---|
| Hardware/backend | Same Apple M2 Max host; debug build; SDL3 GPU Metal |
| Schema | `incinerator.neural-input.v1`, six 400×225 RGBA8 targets |
| Canonical paired target | 1600×900 RGBA8, derived from the exact submitted product scene before UI |
| Raw capture volume | 7,920,000 bytes per selected frame: 2,160,000 bytes of inputs plus 5,760,000 bytes of target, before PPM/manifests |
| Deterministic acceptance | Two 3,840-frame S13 launches at 240 Hz virtual presentation / 60 Hz simulation; 964 ticks each; six selected frames; zero capture failures; byte-identical declared buffers |
| Graphical lab smoke | Approximately 120 FPS / 8.3 ms reported by the existing debug frame counter with all six live targets and editor visible; not a percentile benchmark |
| Capture synchronization | Selected frames deliberately use a same-queue submit fence and blocking readback; normal frames do not pay this capture path |

The MRT pass itself still needs GPU timestamps, frame-time percentiles, memory
residency, and on/off A/B measurement in NR0-F. The deterministic 240 Hz value
is a scripted virtual presentation rate and must not be represented as measured
rendering throughput.

## NR0-C spatial candidate measurements

These numbers characterize the first 17-plane model and standalone Core ML
execution. They are not an installed end-to-end or shipping budget.

| Item | Result |
|---|---|
| Hardware/runtime | Same Apple M2 Max host; PyTorch 2.7.0 MPS; Core ML 9.0; macOS 15.7.7 |
| Model | 51,888 parameters; 24 features; three residual blocks; fixed 4× residual decoder |
| Stored artifacts | 213,685-byte PyTorch checkpoint; 119,721-byte Core ML package; 1,067,884,544-byte complete evidence root including 72 raw/debug paired frames and samples |
| Dimensions | 17 planes at 400×225; RGB output at 1600×900 |
| Precision/export | PyTorch FP32 training; FP16 macOS 15 ML Program candidate |
| Training | 80 epochs, 40 train frames, deterministic aligned 96×96 input patches, batch 4; epoch 80 selected by orbit-wide validation |
| Validation | model MAE 0.02556 / PSNR 22.51 dB / SSIM 0.8710; best baseline MAE 0.18025 / PSNR 13.91 dB / SSIM 0.8074 |
| Untouched test | model MAE 0.02556 / PSNR 24.18 dB / SSIM 0.8661; best baseline MAE 0.18479 / PSNR 13.90 dB / SSIM 0.7981 |
| PyTorch/Core ML agreement | mean absolute error 0.000103; maximum 0.000491 |
| Standalone Core ML prediction | `ALL`, 500 iterations after 50 warmups: p50 5.077 ms, p95 5.720 ms, p99 5.988 ms, max 6.096 ms |
| CPU+GPU comparison | 200 iterations after 20 warmups: p50 5.072 ms, p95 5.782 ms, p99 6.505 ms, max 6.771 ms |

The PyTorch full-frame p50 was approximately 2.8–2.9 ms after MPS warmup, but
that is an offline framework measurement and is not interchangeable with Core
ML or product frame timing. NR0-F still owns installed model/package memory,
activation residency, GPU timestamps, input raster cost, output composition,
UI/present, fallback transitions, sustained frame pacing, and end-to-end
latency.

## NR0-D offline stress-evaluation measurements

These figures describe exhaustive PyTorch/MPS evaluation and evidence
generation, not installed inference or a shipping memory/frame budget.

| Item | Result |
|---|---|
| Hardware/runtime | Same Apple M2 Max host; macOS 15.7.7; PyTorch 2.7.0 MPS; Python 3.13.12 |
| Candidate | Exact 51,888-parameter NR-0002 checkpoint; SHA-256 `35e286bc5d5018e0e6f2a409da5d23179f0cf1329d65d0f37c0da4e3917af749` |
| Cohort | Six immutable stress captures; 478 1600×900 canonical targets; 9,374 visible-instance records |
| Inference distribution | p50 3.430 ms; p95 5.784 ms; p99 7.473 ms; max 117.633 ms |
| Evaluation wall time | 1,417,652 ms (about 23.6 minutes) for metrics and 4,307 visual evidence files |
| Process peak RSS | 8,550,137,856 bytes |
| PyTorch MPS after evaluation | 399,396,352 bytes current allocated; 3,557,277,696 bytes driver allocated |
| External artifact volume | Approximately 11 GB retained run including the immutable superseded first report; crop-complete `evaluation-v2` approximately 2.3 GB |

The process and MPS values include the Python framework, complete metric
pipeline, and visual artifact generation. They cannot be used as model-runtime
residency. NR0-F must measure the promoted bundle through the installed
GPU-resident adapter before the engine accepts any runtime cost or hardware
envelope.
