# RF6 Cumulative Rich Spatial Validation

**Status:** Technical implementation complete; product-owner interactive review pending

**Date:** 2026-08-10

**Roadmap:** [Rich Fidelity Roadmap](../design/rich-fidelity-roadmap.md)

## Outcome

RF6 completes the first from-scratch spatial model campaign against the
human-accepted RF0–RF5 rich visual direction. A fresh 448,359-parameter model
learns the native `160×90` deterministic input to direct native `400×225`
rich-target mapping, survives validation-only selection, one sealed-test
opening, a fresh post-selection stress cohort, exact export checks, and the
real engine-to-Core-ML-to-Metal path.

The result is deliberately external and unpromoted. It proves the cumulative
rich spatial mapping for the bounded authored fixture; it does not establish
title-wide coverage, temporal stability, production performance, installed
runtime selection, or final art quality.

## Executed phase record

| Phase | Result | Evidence |
|---|---|---|
| RF6-A | Complete | RF5 product-owner approval, native extent contract, random-origin rule, whole-sequence split ownership, and external-only boundary retained |
| RF6-B | Complete | Shared 49-draw sandbox catalog exercised through six deterministic camera programs; one marginal character-facing part was corrected in the shared catalog rather than hidden behind a visibility threshold |
| RF6-C | Complete | Six fresh sequences and 108 native pairs manufactured and audited; 18 frames each for overfit, train, validation, sealed test, and two stress sequences; no previous pixels reused and no test pixels exposed in review |
| RF6-D | Complete | Controlled fit accepted, then a separately random-initialized held-out candidate selected at epoch 175 using validation only |
| RF6-E | Complete | Test opened once, real reopen rejected before pixels, fresh 36-frame stress cohort passed, all ablations and deterministic baselines retained, TorchScript exact on all stress frames, explicit accepted technical conclusion recorded |
| RF6-F | Complete | Explicit Core ML trial bundle validated and run for 48 live Metal frames with retained native input/output evidence, fallback preserved, and no category or inference failures |

## External evidence roots

Generated pixels, corpora, checkpoints, reports, and trial packages remain
outside Git by policy:

```text
~/Library/Application Support/Incinerator/neural-rendering/experiments/
  rf6-corpus-20260811T031455Z/
  rf6-coverage-20260811T032029Z/
  rf6-controlled-fit-20260811T032209Z/
  rf6-held-out-entry-20260811T032650Z/
  rf6-held-out-20260811T032650Z/
  rf6-stress-corpus-20260811T033325Z/

~/Library/Application Support/Incinerator/neural-rendering/trial-bundles/
  rf6-rich-spatial-20260811T034154Z/

/tmp/incinerator-nr5-e-trial-75XWhx/
```

The historical `NR5-*` names inside reusable trainer, conclusion, and trial
schemas identify the established component contract. RF6 owns the new corpus,
initializer, checkpoints, decision, and trial application; it does not clone
those component owners merely to rename them.

## Corpus and lineage

- Input ABI: `incinerator.neural-input.v3`, six native `160×90` RGBA8 targets
  plus four float32 frame-global controls.
- Target ABI: `incinerator.nr4.blender-target-frame.v4`, direct native
  `400×225` scene-linear HDR.
- Corpus: 108 new pairs across six whole sequences; the test sequence remained
  sealed until checkpoint selection.
- Model: 448,359 repository-defined parameters initialized from recorded fresh
  random seeds. No pretrained weights, earlier checkpoints, pseudo-targets,
  distillation, or external learned loss participated.
- Selected checkpoint SHA-256:
  `5db9ac57ad64c356d469b66d1b896fa89be9b1b53d4e3f990e227d492004bd6e`.
- The second test-open attempt produced an immutable rejection record and
  states `pixels_opened_by_rejected_attempt=false`.

## Quality results

All values are mean errors over their complete split. Lower is better.

| Split / branch | Linear-HDR MAE | Semantic-boundary MAE | Instance-boundary MAE |
|---|---:|---:|---:|
| Validation model | 0.010470 | 0.033807 | 0.050385 |
| Validation bilinear | 0.451187 | 0.284591 | 0.275313 |
| Validation appearance only | 0.291974 | 0.225728 | 0.351305 |
| Validation without globals | 0.019263 | 0.042089 | 0.069973 |
| Validation without instance | 0.061412 | 0.072214 | 0.176865 |
| Validation without semantic | 0.011971 | 0.040246 | 0.055555 |
| Sealed test model | 0.015084 | 0.055227 | 0.072215 |
| Sealed test bilinear | 0.399686 | 0.302961 | 0.267141 |
| Fresh stress model | 0.012028 | 0.044792 | 0.072547 |
| Fresh stress bilinear | 0.487823 | 0.289149 | 0.281280 |

The ablations establish concrete use for appearance, global controls, instance
identity, and semantic identity. Instance identity has the largest measured
structural effect. Semantic identity provides a smaller but consistent gain;
it is not removed on this one bounded result.

Complete visual review confirms that the model reconstructs the accepted lit,
materialized scene while preserving camera composition, characters, vehicle,
props, and built geometry. It also exposes the present failure envelope:
localized chromatic ringing and softening around close glass, emissive signs,
thin posts, and some object silhouettes. Those failures remain visible and are
the quality work for later spatial/data iterations; aggregate metrics do not
erase them.

## Execution and runtime measurements

| Measurement | Result |
|---|---:|
| Controlled-fit training | 240 epochs; 212.497 s |
| Held-out training | selected epoch 175; 335.238 s |
| Offline validation inference | 7.252 ms median; 9.803 ms p95 |
| Supplemental MPS stress inference | 8.119 ms median; 11.517 ms p95; 142.184 ms maximum cold outlier retained |
| Supplemental forward/backward process peak RSS | 1,020,002,304 bytes |
| TorchScript agreement, all 36 stress frames | exact; maximum absolute error 0 |
| Core ML conversion agreement | maximum absolute error 0.00000978; mean 0.000000148 |
| Live Metal/Core ML acceptance | 48 readbacks; 48 predictions; zero failures; zero unknown semantic/instance pixels |
| Live last inference | 10.551 ms |
| Live staged pipeline | 37.344 ms mean; 147.036 ms maximum, cold work retained |

The live path still performs blocking readback, CPU preprocessing, Core ML
inference, CPU display conversion, upload, and one-frame staging. These numbers
are feasibility evidence, not a shipping performance target.

## Final source and product regression

The final repository state passed:

- Blender/target adapter contracts: 16/16;
- cold title-renderer contracts: 5/5, including RF6 rich-material coverage;
- historical neural tool contracts in their declared environments;
- `zig build test -Deditor=false --summary all`: 283/283 build steps and
  979/979 tests;
- `zig build test -Deditor=true --summary all`: 286/286 build steps and
  979/979 tests;
- installed S2 vehicle Metal smoke at 240 and 80 virtual render Hz;
- installed S11 combat/death/respawn Metal smoke at 240 and 80 virtual render
  Hz;
- installed S13 authored-population Metal smoke at 240 and 40 virtual render
  Hz; and
- the 48-frame RF6 live Core ML/Metal acceptance described above.

All graphical cohorts completed cleanly with their expected vehicle,
articulation, collision, character visibility, health/death/respawn, twelve-NPC
role/activity, and population-readiness observations.

## Reproduce and review

```sh
export INCINERATOR_NR_ROOT="$HOME/Library/Application Support/Incinerator/neural-rendering"
export RF6_RUN="$INCINERATOR_NR_ROOT/experiments/rf6-held-out-20260811T032650Z"
export RF6_BUNDLE="$INCINERATOR_NR_ROOT/trial-bundles/rf6-rich-spatial-20260811T034154Z"

zig build inspect-title-renderer-candidate -- "$RF6_RUN"
zig build inspect-nr5-e-trial-bundle -- "$RF6_BUNDLE"
zig build verify-nr5-e-trial -Deditor=true -- "$RF6_BUNDLE"

INCINERATOR_NR_TRIAL_BUNDLE="$RF6_BUNDLE" \
INCINERATOR_NR_TRIAL_FIXTURE=1 \
zig build run -Deditor=true
```

The interactive command starts the exact in-distribution fixture. The main
window remains the conventional product view. The **Neural Input / Output**
window shows the native `160×90` deterministic appearance input above the
native `400×225` Core ML result. Press `N` to switch the main scene between
conventional and neural presentation. Conventional fallback remains available
if bundle loading or inference fails.

## Disposition and next boundary

RF6 is technically accepted as an external spatial experiment. The product
owner still needs to review the live fixture before the campaign is fully
closed. No model is copied into `models/neural-rendering/`, installed as game
content, or selected at runtime.

After that review, the next work is **NR6-A temporal need characterization**:
record motion, disocclusion, camera-cut, reset, and response failures of this
exact richer spatial candidate before choosing recurrent state or history
architecture. RF6 does not authorize skipping that diagnostic gate or jumping
directly to model complexity.
