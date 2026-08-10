# NR-0005 — From-Scratch Structural Title Renderer

**Status:** NR5-A/B accepted; NR5-C next

**Date opened:** 2026-08-09

**Governing plan:**
[Title Neural Renderer Implementation Plan](../../../docs/design/title-neural-renderer-implementation-plan.md)

## Question

Can a repository-defined model initialized from recorded random state learn the
accepted native `160×90 → 400×225` title transformation while preserving the
authored fixture's identities and boundaries, without any inherited learned
weights?

## NR5-A framework contract

The cohesive `tools/neural-rendering/title_renderer/` package owns corpus
contracts, direct linear-HDR EXR loading, categorical semantic/instance
decoding, global-control normalization, deterministic architecture creation,
immutable checkpoint ancestry, learned-tensor origin audit, non-learned losses
and baselines, visual reports, export agreement, and run inspection.

Torch, OpenEXR, NumPy, and Pillow remain external training dependencies. Cold
contract tests import none of them, and no engine, graphical fallback,
headless, validation, or server product acquires a training dependency.

NR5-A's clean-room proof creates a random initializer, trains a tiny
repository-defined fixture, resumes into a new child root without changing its
parent, audits every learned tensor, evaluates, exports TorchScript, and checks
numerical agreement.

Executed evidence:

```text
~/Library/Application Support/Incinerator/neural-rendering/experiments/nr5-a-clean-room-20260809-c
```

All seven lifecycle/origin checks pass. Resume preserved the parent checkpoint
digest, the parent and resumed losses descended, and the TorchScript export
matched its PyTorch source exactly for the clean-room fixture.

## NR5-B configuration

[`nr5-b-controlled-overfit.json`](nr5-b-controlled-overfit.json) opens only the
declared overfit sequence. Validation and test are not model inputs. The first
model combines a low-resolution continuous/categorical/global branch with a
target-grid structural branch derived from the accepted inputs. It predicts
scene-linear HDR and is compared separately to nearest, bilinear, and bicubic
`160×90 → 400×225` reconstruction.

This phase does not authorize promotion or runtime integration.

## NR5-B disposition

Accepted evidence:

```text
~/Library/Application Support/Incinerator/neural-rendering/experiments/nr5-b-controlled-overfit-20260809-c
```

The accepted 448,175-parameter model retained epoch 238 after 208.399 seconds
of MPS training. All checkpoint tensors trace to the exact random initializer,
the export agrees exactly on its fixture, and no validation/test pixel was
opened.

Across all 18 overfit frames, model linear-HDR MAE is `0.009956` against
`0.447403` for bilinear. Diagnostic-display MAE is `0.013717` against
`0.366620`; semantic and instance boundary MAE are `0.018672` and `0.036004`
against `0.276200` and `0.325507`.

Agent inspection of every comparison sheet accepts the controlled-fit gate.
Authored state and causal transitions remain faithful. Severe near-edge and
high-emissive frames retain localized smoothing and chromatic ringing. NR5-C
must explicitly ablate those failures while evaluating held-out views. The
model remains an external, unpromoted candidate and is not a runtime bundle.
