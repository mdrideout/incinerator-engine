# Neural Rendering Experiments

This directory stores small, reviewable experiment definitions and conclusions.
It does not store mutable training runs or runtime-selected models.

Use monotonically assigned names such as:

```text
nr-0001-spatial-overfit/
nr-0002-spatial-held-out/
nr-0003-temporal-history/
```

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

