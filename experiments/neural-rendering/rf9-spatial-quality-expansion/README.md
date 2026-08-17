# RF9 Spatial Quality Expansion

This experiment implements the gated campaign in
[`docs/design/rf9-spatial-quality-expansion.md`](../../../docs/design/rf9-spatial-quality-expansion.md).

All candidates are direct native `160×90 -> 640×360`, random-initialized,
title-owned models. `baseline-no-palette.json` and `baseline-full.json` are the
controlled RF9-D material-palette ablation. `learned-pyramid.json` isolates the
RF9-E reconstruction change. The campaign then derives the RF9-F wider-context,
deeper-output, and detail-focused configurations from whichever reconstruction
actually passes validation. It similarly derives RF9-G from the
validation-selected RF9-F structural candidate. This prevents a rejected
architecture from becoming the implicit base of later experiments.

Generated corpora, runs, checkpoints, and trial bundles remain external.
Validation selects. The sealed test is not opened by any configuration here.

The campaign entry points are deliberately separate:

```sh
PYTHONPATH="$PWD/tools/neural-rendering" \
  <neural-python> tools/neural-rendering/title_renderer/run_rf9_campaign.py \
  --corpus <absolute-corpus-root> \
  --repository "$PWD" \
  --output <new-absolute-campaign-root>

# Resume only the same interrupted campaign and corpus. Complete immutable
# candidates are reused; partial candidates are preserved under rejected/.
PYTHONPATH="$PWD/tools/neural-rendering" \
  <neural-python> tools/neural-rendering/title_renderer/run_rf9_campaign.py \
  --corpus <absolute-corpus-root> \
  --repository "$PWD" \
  --output <existing-absolute-campaign-root> \
  --resume

# Only after inspecting every validation/test/stress sheet:
PYTHONPATH="$PWD/tools/neural-rendering" \
  <neural-python> tools/neural-rendering/title_renderer/finalize_rf9_campaign.py \
  --campaign <absolute-campaign-root> \
  --repository "$PWD" \
  --review '<factual technical visual-review disposition>'
```

The first command creates the immutable validation selection, opens the sealed
test once, proves a second opening is rejected, and evaluates stress. It stops
before claiming visual review or exporting a bundle. The second command writes
the technical conclusion, measurements, and explicit unpromoted Core ML trial
only after the caller has actually reviewed that evidence.

## Completed reference campaign

The completed external campaign is:

`~/Library/Application Support/Incinerator/neural-rendering/experiments/rf9-spatial-campaign-20260813-b`

It selects `runs/baseline-full`, a `1,062,587`-parameter bilinear-refinement
model with material-palette conditioning. Validation rejects the learned
pyramid, wider-context, deeper-output, detail-focused, and detail-residual
candidates. The sealed test opened exactly once, held stress was evaluated,
Core ML agreement passed, and the graphical bundle ran as an explicit
unpromoted trial. Read
[`docs/validation/rf9-spatial-quality-expansion.md`](../../../docs/validation/rf9-spatial-quality-expansion.md)
before interpreting or extending the result.

RF9 remains implemented and testable, but its product review was superseded
by the RF10 decision to establish a wholly fresh direct native
`256x144 -> 1280x720` cohort. RF9 supplies historical evidence and reusable
code structure only; it supplies no RF10 pixels, weights, optimizer state,
metrics, split approval, or acceptance.
