# NR-0002 NR0-D Failure Evaluation

**Status:** Evaluation complete; candidate not suitable for promotion

**Date:** 2026-08-08

## Question

Where does the NR-0002 spatial result stop being useful under thin geometry,
small objects, rapid motion, disocclusion, camera cuts, unusual viewpoints, and
real target resizing?

## Cohort

The presentation-only NR0-D fixture contributes 23 stable identities and no
gameplay or authority state. Six stress camera programs captured 478 complete
frames. Evaluation retained every frame, all 9,374 visible-instance records,
reset-aware temporal records, and 4,307 generated visual artifacts, including
measured worst temporal and disocclusion crops, without sampling or instance
truncation.

The exact external evidence root is:

```text
~/Library/Application Support/Incinerator/neural-rendering/experiments/nr0-d-20260807-a/
```

The checkpoint SHA-256 is
`35e286bc5d5018e0e6f2a409da5d23179f0cf1329d65d0f37c0da4e3917af749`.
The fixture fingerprint is
`nr0-d-fixture-v1|rigid-edges|thin-features|small-objects|depth-layers|moving-occluder|rotating-parts|stable-identities`.

## Results

| Measurement | Bilinear | NR-0002 |
|---|---:|---:|
| Full-frame MAE | 0.16700 | 0.03811 |
| Mean-frame SSIM | 0.83490 | 0.87138 |
| Covered-pixel MAE | 0.16459 | 0.06543 |
| Semantic-boundary MAE | 0.18632 | 0.13114 |
| Semantic-boundary gradient MAE | 0.04918 | 0.05644 |
| Instance-boundary MAE | 0.17996 | 0.15133 |
| Instance-boundary gradient MAE | 0.05522 | 0.06191 |
| Valid-history temporal residual MAE | 0.03318 | 0.04090 |
| Disoccluded-current MAE | 0.16729 | 0.12051 |

NR-0002 has a genuine broad spatial advantage and handles newly revealed
pixels better than bilinear. It is nevertheless less sharp at semantic and
instance boundaries and less temporally stable on valid reprojected history.
Human inspection confirms thin-feature loss, smoothing of repeated fine
patterns, dark edge halos, color bleed, and out-of-distribution blur. Explicit
camera-cut and resize resets remain complete and do not produce blank frames.

## Conclusion

The NR0-D evaluation phase is accepted. NR-0002 is not promotion-worthy and
remains external and unpromoted. The next numbered model experiment should use
the fixture only as held-out evaluation while broadening training coverage and
correcting spatial boundary and temporal-readability losses. The evidence does
not yet justify assuming recurrent state or another temporal architecture.

Re-inspect the immutable result with:

```sh
"$HOME/Library/Application Support/Incinerator/neural-rendering/envs/nr0-poc/bin/python" \
  tools/neural-rendering/inspect_nr0_d.py \
  "$HOME/Library/Application Support/Incinerator/neural-rendering/experiments/nr0-d-20260807-a/evaluation-v2"
```
