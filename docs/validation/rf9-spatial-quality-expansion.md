# RF9 Spatial Quality Expansion Validation

**Status:** Complete external technical trial; unpromoted; product review
superseded by the RF10 native-720p resolution decision

**Date:** 2026-08-13

**Plan:**
[RF9 Spatial Quality Expansion](../design/rf9-spatial-quality-expansion.md)

## Disposition

RF9 completed the direct native `160x90 -> 640x360` spatial campaign without
using RF8 pixels or weights. It accepts one new deterministic input—the
authored material-palette scalar—and retains the simpler bilinear-refinement
model. Learned pyramid reconstruction, wider context, deeper output
refinement, detail-focused sampling, and the conditional detail residual all
failed their held-out validation comparisons and are rejected.

The result is useful as an unpromoted technical and playable trial. It is not
product-quality approval, installed content, a temporal result, or promotion
authorization. Native review still shows softened texture and thin geometry,
edge ringing, exaggerated emissive/local contrast, and weaker sealed
wet-night generalization.

## Immutable external evidence

- Failure and target audit:
  `~/Library/Application Support/Incinerator/neural-rendering/experiments/rf9-failure-target-audit-20260812-a`
- Accepted corpus:
  `~/Library/Application Support/Incinerator/neural-rendering/experiments/rf9-direct-640x360-corpus-20260813-b`
- Campaign, candidates, evaluations, and trial bundle:
  `~/Library/Application Support/Incinerator/neural-rendering/experiments/rf9-spatial-campaign-20260813-b`
- Rejected development corpus:
  `~/Library/Application Support/Incinerator/neural-rendering/experiments/rf9-direct-640x360-corpus-20260812-a`
- Preserved interrupted candidate:
  `~/Library/Application Support/Incinerator/neural-rendering/experiments/rf9-spatial-campaign-20260813-b/rejected/capacity-context-interrupted-before-accepted-reconstruction`

The accepted corpus digest is
`07b8f5cb353b69f73537d7ddd845101f2f2ef106c7d0fd9868d86cfd75a10bd5`.
It contains 17 whole sequences and 306 native pairs: 18 controlled-fit, 90
train, 90 validation, 54 sealed-test, and 54 independently held stress frames.
Stress was manufactured and assigned before training but remained outside all
fitting and selection. The sealed test remained inaccessible until immutable
selection.

## Contract and causal coverage

- Input ABI: `incinerator.neural-input.v6`, six native `160x90` channels and
  five frame-global controls.
- Target ABI: native `640x360` scene-linear HDR target-frame v7.
- New control: `material_palette`; no raw authority or asset handle enters the
  model.
- Fixture variants: urban day, copper evening, wet night, urban copper
  material, and urban wet material.
- Exact material ambiguity pairs preserve the cheap rasters, camera, geometry,
  and lighting while changing only palette intent and the rich target. All 18
  controlled target pairs differ.
- Every learned candidate began from declared random initialization and used
  only this title-owned corpus.

No `400x225`, `800x450`, or `1600x900` pixel entered this lineage as an input,
target, intermediate rendered image, supervision source, or runtime surface.

## Validation-only model selection

Lower spatial-quality score is better.

| Candidate | Parameters | Spatial score | Chroma MAE | High-frequency MAE | Laplacian MAE | Disposition |
|---|---:|---:|---:|---:|---:|---|
| No material palette | 1,062,587 | 0.030141 | 0.005147 | 0.007132 | 0.006325 | Rejected |
| Full bilinear baseline | 1,062,587 | **0.028901** | **0.005053** | **0.006960** | **0.006228** | Selected |
| Learned pyramid | 1,367,339 | 0.029813 | 0.005335 | 0.007127 | 0.006373 | Rejected |
| Wider context | 1,459,411 | 0.029241 | 0.005164 | 0.006999 | 0.006254 | Rejected |
| Deeper output | 1,145,723 | 0.029190 | 0.005030 | 0.007026 | 0.006259 | Rejected |
| Detail-focused sampling | 1,062,587 | 0.029199 | 0.005070 | 0.007117 | 0.006339 | Rejected |
| Detail residual | 1,084,670 | 0.029192 | 0.005300 | 0.007062 | 0.006295 | Rejected |

The material-palette ablation improved both validation chroma and the aggregate
spatial score. The learned pyramid failed both of its required gates. The
larger and detail-focused candidates produced no complete held-out win. The
detail residual improved its own disabled branch but degraded high-frequency,
semantic-boundary, and instance-boundary evidence relative to the selected
structural model.

Selected lineage:

- Run: `runs/baseline-full`
- Run digest:
  `3566609238c7260a61cbc60762394731fb254f495754761810804db3bae425ce`
- Checkpoint digest:
  `e2977bad2877908689b411d0cb2d20e2dd571ad9ceb899f7d8a04ed4c20ccf86`
- Epoch: 120
- Parameters: 1,062,587
- Checkpoint bytes: 12,848,343

## Sealed test and stress

The sealed test opened once for 54 frames. A real second opening was rejected
before pixel access.

| Evidence | HDR MAE | Spatial score | Chroma MAE | High-frequency MAE | Laplacian MAE | Semantic boundary | Instance boundary |
|---|---:|---:|---:|---:|---:|---:|---:|
| Sealed test | 0.027136 | 0.044200 | 0.009535 | 0.008887 | 0.008459 | 0.085309 | 0.111548 |
| Held stress | 0.018653 | 0.032545 | 0.006329 | 0.007251 | 0.006683 | 0.070358 | 0.109647 |

Offline PyTorch full-frame inference on Apple Silicon measured a 31.67 ms test
median and 25.25 ms stress median. Cold compilation outliers are retained.
These are research-process measurements, not installed-runtime claims. A
representative forward/backward process peaked at 2,348,777,472 bytes; the
completed training process had already exited, so no retrospective training
RSS is invented.

## Export and live graphical proof

The explicit trial bundle is:

`~/Library/Application Support/Incinerator/neural-rendering/experiments/rf9-spatial-campaign-20260813-b/trial-bundle`

It is schema 4, kind
`incinerator.rf9.coreml-direct-spatial-trial-bundle`, Float32, requires macOS
15, and remains `trial_only_unpromoted`. Core ML maximum absolute agreement was
`0.00003433`, under the admitted `0.0001`; the export wrapper was bit-exact.

The final graphical verification completed 48 readbacks and 48 predictions
with zero failures and zero unknown semantic or instance pixels. The last
inference was 27.62 ms; the staged pipeline mean was 79.84 ms and maximum
123.65 ms. Its RF9-H evidence is retained at
`/tmp/incinerator-nr5-e-trial-rORinG`. The
captured comparison remained causally aligned and visibly richer than the cheap
input, while retaining the softness and ringing described above.

The bundle continues to use the established NR5-E external-trial packaging
mechanism; RF9 identity is carried by its bundle kind, input ABI, candidate
lineage, and RF9-H runtime evidence. That mechanism name does not make this an
NR5 model or authorize compatibility with an older ABI.

```sh
CAMPAIGN="$HOME/Library/Application Support/Incinerator/neural-rendering/experiments/rf9-spatial-campaign-20260813-b"
BUNDLE="$CAMPAIGN/trial-bundle"

zig build inspect-title-renderer-candidate -- "$CAMPAIGN/runs/baseline-full"
zig build inspect-nr5-e-trial-bundle -- "$BUNDLE"
zig build verify-nr5-e-trial -Deditor=true -- "$BUNDLE"

INCINERATOR_NR_TRIAL_BUNDLE="$BUNDLE" \
INCINERATOR_NR_TRIAL_FIXTURE=1 \
  zig build run -Deditor=true
```

Press `N` to switch the fixed centered `640x360` main presentation between the
conventional scene and neural result. The Neural Input / Output tool shows the
native `160x90` source. Larger windows receive black surround rather than a
stretched scene.

## Technical conclusion

RF9 proves that an explicit authored material signal solves a real ambiguity;
it does not prove that a more elaborate decoder or a larger network improves
this corpus. The evidence instead says that the current remaining defects are
dominated by spatial content/conditioning/objective/generalization work, not a
validated need for temporal history and not a validated need for more raw
capacity.

Promotion remains false. The product owner chose the fresh RF10 native
`256x144 -> 1280x720` cohort as the next gate. It begins from the observed
texture, thin-geometry, ringing, emissive-response, and wet-night failures but
inherits no RF9 pixels, learned state, metrics, or review approval.
