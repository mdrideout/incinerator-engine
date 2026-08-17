# Neural Rendering Experiments

> **Product-track pause (2026-08-17):** Do not create, run, extend, or promote a
> neural-rendering experiment without an explicit product-owner request to
> resume the track. RF10 is the retained external, unpromoted stopping point.
> See [`docs/design/neural-rendering-pause.md`](../../docs/design/neural-rendering-pause.md).

This directory stores small, reviewable experiment definitions and conclusions.
It does not store mutable training runs or runtime-selected models.

Use monotonically assigned names such as:

```text
nr-0001-spatial-overfit/
nr-0002-spatial-held-out/
nr-0003-temporal-history/
```

`nr0-ab-input-capture/` is a conformance record for the engine input/capture
foundation, not a trained-model experiment and not part of the numbered model
candidate sequence.

Implemented numbered experiments:

- [`nr-0001-spatial-pipeline/`](nr-0001-spatial-pipeline/README.md): preliminary
  RGB pipeline proof; complete and unpromoted.
- [`nr-0002-multichannel-spatial-baseline/`](nr-0002-multichannel-spatial-baseline/README.md):
  accepted NR0-C 17-plane spatial candidate; complete and unpromoted. Its
  [NR0-D failure evaluation](nr-0002-multichannel-spatial-baseline/NR0-D-EVALUATION.md)
  accepts the evaluation phase but finds the candidate unsuitable for
  promotion.
- [`nr-0003-ltxv-2b-distilled/`](nr-0003-ltxv-2b-distilled/README.md):
  quality-first stock LTX-Video 2B distilled baseline on M2 Max; local
  512×288 throughput passes at roughly 1.5 FPS, while stock RGB conditioning
  is rejected because richness and authored-structure preservation do not
  overlap. Complete and unpromoted.
- [`nr-0004-high-fidelity-target-corpus/`](nr-0004-high-fidelity-target-corpus/README.md):
  from-scratch title-renderer data-factory experiment. NR4-A's exact static
  Cycles target and NR4-B's 18-frame/six-segment moving target are technically
  and human accepted as historical adapter/correspondence proofs. NR4-C's
  native `160×90 → 400×225` cohort and minimal global-control schema are
  accepted; NR4-D's 108-pair technical corpus gate passes; NR4-E accepts it
  for the initial NR5-A/B scope with explicit broader gaps.
- [`nr-0005-structural-title-renderer/`](nr-0005-structural-title-renderer/README.md):
  cohesive from-scratch framework, controlled overfit, held-out selection,
  single sealed-test opening, branch ablations, fresh native stress evaluation,
  exact export verification, and the live Core ML interactive spatial trial
  accepted. It authorizes NR6 temporal research but remains an external,
  unpromoted known-fixture candidate. RF0 through RF5 of the repository's
  rich-fidelity roadmap are now accepted; RF6 applies the same framework to
  that richer vocabulary before later temporal work.
- [`rf6-cumulative-rich-spatial/`](rf6-cumulative-rich-spatial/README.md):
  product-track application of the established corpus, random-origin training,
  held-out evaluation, export, and external live-trial framework to the
  RF0–RF5 rich sandbox vocabulary. RF6-A through RF6-F are technically
  complete with a fresh 108-pair corpus, random-origin held-out candidate,
  sealed test, fresh stress cohort, and live Core ML trial. Product-owner
  review was superseded by the RF7 resolution decision; this is never a
  model-promotion owner.
- [`rf7-direct-800x450-spatial/`](rf7-direct-800x450-spatial/README.md): historical
  direct native `160×90 → 800×450` spatial-fidelity cohort. It renders fresh
  native `800×450` truth, trains one learned 5× model from random
  initialization, and targets the existing live Core ML comparison path. It
  contains no `400×225` intermediate, supervision, comparison, or runtime
  image; product visual review is pre-approved for autonomous completion.
- [`rf8-direct-640x360-spatial-sharpness/`](rf8-direct-640x360-spatial-sharpness/README.md):
  historical direct native `160×90 → 640×360` spatial-fidelity cohort. It preserves
  exact 16:9 geometry and a uniform 4× mapping, renders wholly fresh native
  truth, adds native-grid reconstruction capacity and explicit spatial-quality
  losses/selection, and drives the centered unscaled live presentation. The
  retired `400×225` and `800×450` images have no RF8 training, comparison,
  export, or runtime role.
- [`rf9-spatial-quality-expansion/`](rf9-spatial-quality-expansion/README.md):
  completed direct native `160×90 → 640×360` material-conditioned campaign.
  It accepts only material-palette conditioning, rejects the tested learned
  pyramid/capacity/sampling/detail additions, and completes an external
  unpromoted Core ML trial.
- [`rf10-native-720p-spatial/`](rf10-native-720p-spatial/README.md): completed
  direct native `256×144 → 1280×720` replacement cohort. It regenerated all
  pixels and learned lineage, uses exact 5× mapping, passed controlled fit,
  validation-only selection, single-open test, new post-selection stress,
  exact Core ML export, and Metal runtime acceptance, and remains an external
  unpromoted trial without an intermediate rendered image.

Once tooling exists, each committed experiment directory should contain only
the information needed to reproduce and review intent:

- question and hypothesis;
- exact configuration and source/data fingerprints;
- declared train/validation/test cohorts;
- baseline and acceptance method;
- final small metric summary and representative comparisons;
- result: inconclusive, rejected, candidate, or promoted; and
- links or immutable IDs for the external run artifacts.

Generated datasets, full frames, checkpoints, optimizer state, temporary
exports, and exhaustive comparisons belong under an explicit external artifact
root, never beside source by accident. A future tool should require that root
as an explicit absolute argument and write one self-describing run folder per
invocation.

[ADR-026](../../docs/adr/026-from-scratch-title-neural-renderer.md) governs
model origin. Promotion-eligible candidates and every learned dependency begin
from declared random initialization and use title-owned data. External
pretrained models may have numbered comparison experiments, but they are not
candidate ancestors, teachers, pseudo-target producers, or promotion inputs.

Experiment state never selects the product model. Promotion crosses the
separate boundary documented in
[`../../models/neural-rendering/README.md`](../../models/neural-rendering/README.md).
