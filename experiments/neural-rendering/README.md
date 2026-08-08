# Neural Rendering Experiments

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
  accepted NR0-C 17-plane spatial candidate; complete and unpromoted.

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

Experiment state never selects the product model. Promotion crosses the
separate boundary documented in
[`../../models/neural-rendering/README.md`](../../models/neural-rendering/README.md).
