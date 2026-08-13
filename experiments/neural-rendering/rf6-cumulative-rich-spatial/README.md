# RF6 Cumulative Rich Spatial Campaign

**Status:** Technical implementation complete; product-owner interactive review pending

**RF5 target disposition:** Accepted by the product owner on 2026-08-10

## Question

Can a fresh repository-owned spatial model learn the complete accepted RF0–RF5
mapping from native `160×90` deterministic presentation inputs to direct native
`400×225` rich targets while preserving authored geometry, identity, pose, and
state?

## Ownership

RF6 is a product-track campaign, not a new universal model family. It reuses
the existing responsible components:

- the NR4 native target adapter and whole-sequence corpus assembler;
- the NR5 random-origin trainer, validation selection, sealed-test guard,
  ablations, evaluator, exporter, and external Core ML trial boundary; and
- the engine's live RF fixture, six-channel input host, conventional fallback,
  Neural Input / Output window, and incident diagnostics.

Every RF6 dataset, initializer, checkpoint, export, and trial bundle is newly
generated beneath an explicit external root. Earlier NR4 target pixels and NR5
weights are comparison evidence only and cannot be copied, resumed, distilled,
or used as a learned loss.

## Contract

- Input: `incinerator.neural-input.v3`, six native `160×90` RGBA8 targets plus
  four float32 frame-global controls.
- Target: direct native `400×225` scene-linear HDR Cycles output through
  `incinerator.nr4.blender-target-frame.v4`.
- Splits: whole overfit, train, validation, sealed test, and stress sequences.
- Selection: validation only; test opens exactly once after immutable
  checkpoint selection.
- Model origin: declared random initialization; no external learned weights.
- Runtime result: external, explicit, unpromoted Core ML trial only.

## Gates

1. RF6-A records target approval and freezes this contract.
2. RF6-B validates the shared catalog in the live fixture and all deterministic
   camera programs without moving gameplay authority into presentation.
3. RF6-C manufactures and audits a fresh cumulative corpus.
4. RF6-D proves controlled fit, then trains and validation-selects the fresh
   cumulative candidate.
5. RF6-E opens test once, runs fresh stress and ablations, verifies export, and
   records the technical disposition after complete visual inspection.
6. RF6-F exports and exercises an external Core ML trial with fallback,
   lineage, timing, unknown-category, and incident evidence.

RF6 acceptance authorizes the NR6 temporal-history audit. It does not promote
or install a model.

## Executed result

RF6-A through RF6-F pass. The campaign manufactured 108 fresh native pairs,
trained controlled and held-out models from separate random initializers,
selected epoch 175 using validation only, opened the sealed test once, rejected
a real reopen before pixels, passed a fresh 36-frame stress cohort, and ran the
selected checkpoint through 48 live Core ML/Metal frames with zero failures or
unknown-category pixels.

The accepted technical checkpoint remains external and unpromoted. Visual
review retains localized edge ringing and softening around close glass,
emissive signs, thin posts, and some silhouettes. Full artifact roots, metrics,
reproduction commands, and the remaining human gate are recorded in
[`../../../docs/validation/rf6-cumulative-rich-spatial.md`](../../../docs/validation/rf6-cumulative-rich-spatial.md).
