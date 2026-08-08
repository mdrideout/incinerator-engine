# NR-0002 Multi-Channel Spatial Baseline

**Status:** Complete NR0-C candidate; NR0-D evaluated and unpromoted

**Date:** 2026-08-06

## Question

Can a compact feed-forward model learn the conventional Incinerator scene from
the accepted `incinerator.neural-input.v1` buffers, first on a controlled
cohort and then on disjoint camera paths, while beating deterministic spatial
reconstruction without test-frame leakage?

## Model and input

The model receives 17 normalized planes at 400×225:

- appearance RGB and coverage alpha;
- linear depth R;
- world-normal RGB;
- motion RG plus history validity B;
- semantic RGB; and
- compact instance RGB.

A 5×5 convolution encodes those planes into 24 low-resolution features, three
explicit residual blocks process them, and a 4× pixel-shuffle decoder predicts
an RGB residual over bilinear appearance. The model has 51,888 parameters and
no temporal state, diffusion, adversarial objective, pretrained perceptual
network, authority input, or gameplay-private input. Training uses aligned
96×96 low-resolution patches with smooth-L1 color, gradient L1, and SSIM loss;
evaluation always uses complete 1600×900 frames.

## Cohort and leakage policy

Every split owns a complete capture sequence and a real deterministic camera
program:

| Split | Frames | Camera path | Use |
|---|---:|---|---|
| Overfit | 8 | `orbit-close` | Data/model controlled-fit gate only |
| Train | 40 | `default-follow` | Held-out model optimization |
| Validation | 12 | `orbit-wide` | Epoch selection; epoch 80 selected |
| Test | 12 | `elevated-sweep` | Evaluated once after selection |

The assembler rejects a sequence appearing in multiple splits and requires
identical schema, shader, content, source, extent, and channel provenance. It
references immutable raw capture files directly rather than producing a second
mutable copy.

## Results

The controlled-fit run reduced MAE from the best non-neural baseline's 0.17685
to 0.03233 and raised PSNR from 13.94 to 23.49 dB.

| Held-out metric | Best non-neural | Model |
|---|---:|---:|
| Validation MAE | 0.18025 (bilinear) | 0.02556 |
| Validation PSNR | 13.91 dB (bicubic) | 22.51 dB |
| Validation SSIM | 0.8074 (bicubic) | 0.8710 |
| Test MAE | 0.18479 (bilinear) | 0.02556 |
| Test PSNR | 13.90 dB (bicubic) | 24.18 dB |
| Test SSIM | 0.7981 (bicubic) | 0.8661 |

Human inspection of default-follow, orbit-wide, and elevated-sweep comparison
sheets found target palette and scene structure restored without blank frames
or geometry drift. Small high-contrast edges retain ordinary spatial
reconstruction error.

The FP16 macOS 15 ML Program agreed with PyTorch within 0.000491 maximum and
0.000103 mean absolute error. On the M2 Max using Core ML `ALL` compute units,
500 predictions after 50 warmups measured 5.077 ms p50, 5.720 ms p95, and
5.988 ms p99. The checkpoint is 213,685 bytes and the Core ML package is
119,721 bytes. This is standalone model latency, not end-to-end frame time.

## Preserved evidence

The complete immutable external run is:

```text
~/Library/Application Support/Incinerator/neural-rendering/experiments/nr-0002-20260806-a/
```

`experiment.json` is the audit entry point. The folder also retains every raw
capture and manifest, dataset provenance, exact Python environment, seeds and
configuration, both checkpoints, loss/selection history, full-frame metrics,
comparison/error images, Core ML export with file digests, and benchmarks.

```sh
"$HOME/Library/Application Support/Incinerator/neural-rendering/envs/nr0-poc/bin/python" \
  tools/neural-rendering/inspect_nr0_experiment.py \
  "$HOME/Library/Application Support/Incinerator/neural-rendering/experiments/nr-0002-20260806-a"
```

Reproduce a fresh run after `zig build install-validation -Deditor=true`:

```sh
tools/run_nr0_c.sh \
  "$PWD/zig-out/libexec/incinerator/incinerator_validation" \
  "$PWD/zig-out/share/incinerator/content" \
  "$PWD" \
  "$HOME/Library/Application Support/Incinerator/neural-rendering/envs/nr0-poc/bin/python" \
  "$HOME/Library/Application Support/Incinerator/neural-rendering/experiments/<new-run-id>"
```

## Conclusion and non-claims

NR0-C passes as the first multi-channel spatial candidate. It demonstrates
learnable, held-out reconstruction on the S13 conformance world. It does not
establish temporal stability, final materials/effects or art direction,
out-of-distribution behavior, end-to-end runtime cost, or promotion. Those are
NR0-D through NR0-F responsibilities. Nothing from this run was copied into
`models/neural-rendering/` or selected by the engine.

The subsequent
[NR0-D failure evaluation](NR0-D-EVALUATION.md) established the omitted stress
envelope. It accepted the evaluation infrastructure but found NR-0002 less
temporally stable and less boundary-sharp than bilinear despite its broad
spatial advantage. NR-0002 is therefore not suitable for promotion.
