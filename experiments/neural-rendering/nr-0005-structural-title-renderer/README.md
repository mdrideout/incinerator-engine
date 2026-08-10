# NR-0005 — From-Scratch Structural Title Renderer

**Status:** NR5-A through NR5-E accepted; NR6 authorized; unpromoted

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

## NR5-C held-out disposition

Canonical accepted evidence:

```text
~/Library/Application Support/Incinerator/neural-rendering/experiments/nr5-c-held-out-20260810-b
```

The entry gate authorizes exactly one known-fixture corpus and records the
accepted NR4-E/NR5-B lineage without decoding test pixels. The 448,175-parameter
model then trained from the recorded random initializer on the 18-frame
`overfit` and 18-frame `train` sequences. Epoch 175 was selected only by the
18-frame validation sequence after 349.955 seconds of MPS training. An earlier
architecture attempt is retained as diagnostic evidence; it exposed avoidable
categorical/continuous resampling ringing and was never allowed to open test.

The selected model records validation linear-HDR MAE `0.010291` against
`0.468340` bilinear. After selection became immutable, the 18-frame sealed test
was opened exactly once: model MAE is `0.016277` against `0.424593` bilinear.
A real second invocation was rejected before it decoded any pixel and owns a
separate immutable rejection record. Appearance-only, no-semantic,
no-instance, and no-global-control ablations all remain in the evidence.

Every validation and test comparison sheet was inspected. The candidate
preserves authored geometry, identities, state changes, materials, and lighting
substantially better than resize and appearance-only baselines. It still
smooths and produces localized chromatic ringing around emissive, glass, and
other high-contrast boundaries. The test result therefore supports only the
declared known-fixture structural claim.

## NR5-D conclusion

NR5-D recaptured a fresh six-sequence/108-pair native corpus at:

```text
~/Library/Application Support/Incinerator/neural-rendering/experiments/nr5-d-native-stress-corpus-20260810-a
```

The selected checkpoint evaluated the 36 fresh stress frames at linear-HDR MAE
`0.011826` versus `0.502818` bilinear. Semantic- and instance-boundary MAE are
`0.034780` and `0.074701` versus `0.280980` and `0.336319`. Every stress sheet,
the overview, and the worst-error high/top-down frames were visually inspected;
the same localized smoothing/ringing remains visible and is not hidden by the
aggregate score.

The TorchScript export agrees exactly with PyTorch across all 36 stress frames.
Offline MPS inference measured `6.983 ms` median and `10.862 ms` p95 in the
supplemental run, with cold compilation outliers retained. A representative
forward/backward process reached `1,027,063,808` bytes peak RSS. The completed
training process was not instrumented for RSS, so no retrospective training
peak is invented.

NR-0005 is accepted as the first from-scratch known-fixture structural title
renderer and authorizes NR6 causal temporal research. It is not title-wide,
art-complete, temporally accepted, promotion-eligible, runtime-selected, or
copied into `models/neural-rendering/`.

## NR5-E interactive spatial trial

NR5-E exports the immutable selected checkpoint into an explicit external
float32 Core ML trial bundle and evaluates it against live Incinerator
schema-v3 GPU targets. The fixture and ordinary sandbox modes share the same
model host, explicit `N` fallback toggle, editor diagnostics, incident records,
and source/presented-frame lineage. The fixture is in-distribution; the sandbox
is diagnostic out-of-distribution use.

The accepted graphical gate produced 48/48 predictions with zero inference
failures or unknown category pixels. The native cheap/neural comparison was
reviewed and preserves the expected geometry while adding the learned material
and lighting direction; known localized smoothing and chromatic ringing remain.
See [`docs/validation/nr5-e-interactive-spatial-trial.md`](../../../docs/validation/nr5-e-interactive-spatial-trial.md)
for commands, bundle identity, measurements, and exact disposition.
