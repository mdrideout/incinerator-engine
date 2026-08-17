# RF10 Native 720p Spatial Validation

**Status:** Accepted retained stopping point; external trial unpromoted;
neural-rendering implementation paused

**Date:** 2026-08-17

**Plan:**
[RF10 Native 720p Spatial Cohort](../design/rf10-native-720p-spatial-cohort.md)

## Outcome

RF10 completed a fresh, direct native `256x144 -> 1280x720` spatial campaign.
It uses six deterministic input rasters, five explicit frame-global controls,
one title-specific model trained from random initialization, and one directly
rendered native Cycles target per frame. There is no `400x225`, `640x360`, or
other rendered intermediate in the active model, dataset, export, or runtime
path.

The accepted checkpoint contains 1,062,587 parameters. It remains an external
Core ML trial and is not promoted game content.

On 2026-08-17 the product owner accepted the current live result as the retained
stopping point and paused further neural-rendering work. This closes the RF10
product-disposition gate; it does not authorize promotion or installed runtime
selection. See the
[pause decision](../design/neural-rendering-pause.md).

## Immutable evidence

| Evidence | External root |
|---|---|
| Accepted target audit | `~/Library/Application Support/Incinerator/neural-rendering/experiments/rf10-native-720p-target-20260813T232443Z` |
| Repeated target audit | `~/Library/Application Support/Incinerator/neural-rendering/experiments/rf10-native-720p-target-20260813T232514Z` |
| Accepted fresh corpus | `~/Library/Application Support/Incinerator/neural-rendering/experiments/rf10-native-720p-corpus-20260814T004013Z/corpus` |
| Controlled, held-out, test, stress, conclusion, and measurements | `~/Library/Application Support/Incinerator/neural-rendering/experiments/rf10-native-720p-campaign-20260814T015457Z` |
| Core ML trial bundle | `~/Library/Application Support/Incinerator/neural-rendering/experiments/rf10-native-720p-campaign-20260814T015457Z/trial-bundle` |

The accepted corpus contains 306 frames in 17 whole sequences: 18 controlled
fit, 90 train, 90 validation, 54 sealed test, and 54 predeclared stress frames.
The post-selection stress corpus contains another 54 frames in three wholly
new sequences. Its pixels were manufactured after immutable selection and its
camera/appearance conditioning is exactly disjoint from every retained
training-corpus sequence.

## Selection and quantitative result

The held-out run trained for 120 epochs. Epoch 110 was frozen because it had
the best declared validation spatial score; test pixels were still unopened.

| Split | Frames | Model linear-HDR MAE | Model spatial score | Model PSNR | Bilinear MAE | Appearance-only MAE |
|---|---:|---:|---:|---:|---:|---:|
| Validation | 90 | 0.012922 | 0.021908 | 44.69 dB | 0.477749 | 0.236021 |
| Sealed test | 54 | 0.023566 | 0.034788 | 38.52 dB | 0.393370 | 0.287514 |
| New post-selection stress | 54 | 0.015925 | 0.022922 | 40.68 dB | 0.449018 | 0.236972 |

All declared numerical gates passed. Test opened exactly once after selection;
the required second opening was rejected before decoding. Complete validation,
test, and stress review sheets cover all 198 evaluated frames.

## Technical visual conclusion

Frame-level review accepted the candidate. Across urban day, copper, wet,
night, close, high, orbit, and heavily occluded views, the selected model
preserves scene composition, storefront and road geometry, vehicle, avatars,
props, material-palette intent, and lighting state. No catastrophic frame,
whole-object disappearance, duplication, palette collapse, or camera
composition failure was observed.

Known limitations remain visible and are not averaged away:

- localized edge softness;
- loss of the finest small-object and surface detail; and
- occasional ringing around high-contrast emissive and silhouette edges.

These are quality inputs for the next spatial phase, not reasons to introduce
temporal history or an intermediate-resolution renderer.

## Export and macOS runtime

The RF10 bundle is schema 5 with kind
`incinerator.rf10.coreml-native-720p-spatial-trial-bundle`. It declares fixed
Core ML tensors `[1,11,144,256]`, `[1,144,256]`, `[1,144,256]`, `[1,5]`, and
one `[1,3,720,1280]` scene-linear output. Its float32 weight file is
15,314,368 bytes.

Core ML agreed with the selected wrapper to a maximum absolute error of
`0.0000534058`, below the admitted `0.0001`. The repository acceptance run
completed 48 readbacks and 48 predictions with zero failures, zero unknown
semantic IDs, and zero unknown instance IDs. Installed Core ML inference in
that smoke ended at 69.152 ms; the staged readback/inference/upload pipeline
mean was 268.522 ms. These are diagnostic measurements, not a product FPS
promise.

The main neural scene owns a fixed native `1280x720` centered rectangle. A
`1600x900` window therefore has 160 black pixels at left and right and 90 at
top and bottom. Resizing adds surround rather than stretching the model image.
The editor's Neural Input / Output tool shows the native `256x144` source only;
the learned output is the main scene. `N` toggles learned and conventional
presentation.

The graphical product launched with the accepted bundle and loaded its Metal
and Core ML path. Automated graphical acceptance passed. The final UI-control
screenshot inspection could not run because the validation Mac was locked;
that environmental limitation is recorded rather than converted into an
imagined result. The product owner's later 2026-08-17 acceptance of the live
result closes the product-disposition gate and establishes this retained
stopping point.

## Rejected harness evidence and lessons

Rejected attempts were preserved rather than overwritten:

- a first stress definition duplicated sealed-test conditioning and was
  rejected for leakage;
- a first preflight assumed a corpus field that did not exist and was rejected
  as a verifier error;
- a disocclusion camera exposed source/target visibility mismatch and was
  rejected as invalid paired evidence; and
- physically combining original and newly generated stress sequences was
  rejected for cross-provenance drift.

The accepted implementation therefore preflights conditioning against every
retained non-stress sequence, uses a dedicated stable post-selection orbit,
keeps stress as a separate single-provenance corpus, imports the frozen
training vocabulary/control normalization for evaluation, and resumes only an
exact partially completed stress attempt.

## Verification

```sh
CAMPAIGN="$HOME/Library/Application Support/Incinerator/neural-rendering/experiments/rf10-native-720p-campaign-20260814T015457Z"

zig build inspect-rf10-trial-bundle -- "$CAMPAIGN/trial-bundle"
zig build verify-rf10-trial -- "$CAMPAIGN/trial-bundle"

INCINERATOR_NR_TRIAL_BUNDLE="$CAMPAIGN/trial-bundle" \
INCINERATOR_NR_TRIAL_FIXTURE=1 \
  zig build run -Deditor=true
```

In the interactive run, press `N` to compare conventional and neural scene
presentation. Confirm that the learned image remains native, centered, and
unstretched while the window is resized, and open **Neural Input / Output** to
inspect the native `256x144` source and active bundle diagnostics.

Promotion remains false. A later promotion decision must deliberately copy an
immutable accepted bundle into title-owned runtime content and update the
runtime ownership record; no latest-run discovery is allowed.
