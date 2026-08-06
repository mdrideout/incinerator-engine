# NR-0001 Spatial Pipeline Proof

**Status:** Complete pipeline proof; unpromoted and not an NR0 art candidate

**Date:** 2026-08-05

## Question

Can this Apple Silicon development machine execute a complete, reproducible
Incinerator frame workflow from external dataset preparation through MPS
training, held-out comparison, fixed-shape Core ML export, and native Core ML
prediction?

## Scope and non-claim

The experiment began with existing product-only incident frames as a loader
smoke, then advanced to exact same-frame pairs captured through the real
product-only renderer boundary. It tests tooling, split integrity, spatial
reconstruction, export, and local inference. The engine input remains a
downsample of conventional product color, not the cheap raster plus auxiliary
buffer schema required by NR0-B, and it does not test the proposed art
direction.

The final split unit is an entire engine capture run. Neighboring frames from
one run can never be divided across training, validation, and test cohorts.

## Model

- RGB input at 80x45 and RGB output at 320x180;
- two low-resolution convolutions;
- one learned RGB residual expanded by 4x pixel shuffle;
- bilinear reconstruction as the deterministic base;
- smooth-L1 reconstruction plus edge loss; and
- bicubic as the declared non-neural comparison.

The architecture is intentionally spatial and feed-forward. Temporal state,
GAN objectives, diffusion, perceptual losses, depth, normals, IDs, and motion
remain outside this pipeline proof.

## Reproduction contract

Use the exact environment and commands in
[`../../../tools/neural-rendering/README.md`](../../../tools/neural-rendering/README.md).
Each invocation receives an explicit absolute output path which must not exist.
Dataset and run artifacts remain under the external artifact root; no mutable
`latest` alias is created.

## Acceptance

- All three whole-run splits are non-empty and recorded with source digests.
- MPS training completes and emits a self-describing immutable run.
- The model is compared with bicubic on validation and untouched test runs.
- A fixed-shape FP16 ML Program export agrees numerically with PyTorch.
- Repeated Core ML predictions record load and percentile timings.
- This experiment remains a toolchain result, not a promoted runtime model.

## Result

Passed its declared pipeline question on 2026-08-05.

### Preserved external artifacts

All paths are local immutable run IDs under:

```text
~/Library/Application Support/Incinerator/neural-rendering/
```

- capture runs: `runs/nr0-engine-{train,validation,test}-20260805-a/`;
- assembled dataset: `datasets/nr0-engine-product-pairs-20260805-a/`;
- training: `runs/nr0-engine-spatial-20260805-a/`;
- Core ML export/benchmark: `runs/nr0-engine-coreml-20260805-a/`; and
- live input/output/target evidence:
  `runs/nr0-live-s13-output-evidence-20260805-a/`.

Each dataset split contains 80 frames from its own complete 3,840-frame S13
Metal run. On the untouched test capture, the model reduced MAE from bicubic's
0.05134 to 0.04348 and raised PSNR from 18.68 to 19.16 dB. Core ML agreed with
PyTorch within 0.001274 maximum absolute error. A 500-iteration Core ML
benchmark measured 0.465 ms p50 and 0.627 ms p99 prediction after warmup.

The native staged path completed 3,840 S13 predictions with no failure and
preserved the S13 acceptance result. A separate missing-model run selected the
conventional fallback and performed no readback. A 480-frame timing run measured
5.579 ms mean and 11.409 ms maximum for blocking readback plus inference, while
the final Core ML call was 0.372 ms. This evidence rejects CPU staging as the
final runtime design even though it proves the critical path.

The visual result is a slightly sharper reconstruction with edge/aliasing
artifacts, not a learned art style. No artifact was promoted or copied into the
runtime model source tree.
