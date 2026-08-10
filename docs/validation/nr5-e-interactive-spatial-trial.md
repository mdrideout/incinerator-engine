# NR5-E Interactive Spatial Trial

**Status:** Accepted as an external, unpromoted evaluation path

**Date:** 2026-08-10

**Candidate source:**
`~/Library/Application Support/Incinerator/neural-rendering/experiments/nr5-c-held-out-20260810-b`

**Trial bundle:**
`~/Library/Application Support/Incinerator/neural-rendering/trial-bundles/nr5-e-spatial-20260810-b`

## Purpose

NR5-E closes the end-to-end demonstration gap before temporal-model work. It
runs the accepted NR5-D spatial checkpoint against Incinerator's live six-target
GPU contract, presents its native `400×225` output in the Metal product, and
retains conventional fallback, model identity, timing, incident, and visual
evidence. This is a trial of a known-fixture spatial model, not promotion.

The model still begins from the accepted repository-owned random initializer
and contains no pretrained weights. The Core ML package is an export of that
immutable checkpoint. It remains beneath the external neural-rendering root and
is not copied into `models/neural-rendering/` or installed as game content.

## Runtime contract

- `INCINERATOR_NR_TRIAL_BUNDLE` names one absolute, explicit bundle root.
- The loader validates schema version, ABI name, fixed input/output shapes,
  preprocessing, categorical vocabularies, control ranges, source checkpoint,
  package membership, byte counts, and SHA-256 digests before loading Core ML.
- Six live `160×90` RGBA8 engine targets become 11 continuous planes, semantic
  and instance index maps, and four normalized global controls exactly as they
  did in training.
- Core ML produces direct `400×225` scene-linear HDR. The adapter applies the
  evaluation display transform and uploads a one-frame-delayed RGBA8
  presentation texture.
- `N` explicitly switches between neural and conventional presentation. A load
  or inference failure disables neural presentation and retains the ordinary
  renderer.
- Editor and incident diagnostics identify the bundle manifest, source
  checkpoint, source/presented frame lineage, inference and staged-pipeline
  time, failures, and unknown semantic/instance pixels.

`INCINERATOR_NR_TRIAL_FIXTURE=1` selects the exact NR4/NR5 authored fixture and
its causal camera sequence. Omitting it retains the playable sandbox. The
fixture is the in-distribution acceptance; the sandbox is deliberately
out-of-distribution and must not be described as generalized model quality.

## Reproduce

```sh
export INCINERATOR_NR_ROOT="$HOME/Library/Application Support/Incinerator/neural-rendering"
export NR5_E_BUNDLE="$INCINERATOR_NR_ROOT/trial-bundles/nr5-e-spatial-20260810-b"

zig build inspect-nr5-e-trial-bundle -- "$NR5_E_BUNDLE"
zig build verify-nr5-e-trial -Deditor=true -- "$NR5_E_BUNDLE"

INCINERATOR_NR_TRIAL_BUNDLE="$NR5_E_BUNDLE" \
  zig build run -Deditor=true
```

The third command is interactive. The conventional 1600x900 scene remains in
the main window while the Neural Input / Output window stacks the native
160x90 deterministic appearance input above the native 400x225 neural output.
Inference continues for that comparison when conventional presentation is
selected. Use `N` to optionally present the neural result in the main window;
expand Diagnostics or Auxiliary neural inputs for lineage, bundle identity,
timing, and the remaining five source channels.

Add `INCINERATOR_NR_TRIAL_FIXTURE=1` only to run the accepted authored fixture
instead of ordinary sandbox gameplay. The fixture deliberately starts with
neural scene presentation enabled for graphical acceptance.

## Accepted evidence

The automated graphical gate retained its external evidence at:

```text
/tmp/incinerator-nr5-e-trial-6Feokk
```

It ran 48 Metal frames with 48 readbacks, 48 predictions, zero inference
failures, zero unknown semantic pixels, and zero unknown instance pixels. The
last inference took `11.281 ms`; the warm staged pipeline measured `33.475 ms`
mean and `77.716 ms` maximum. A preceding cold run retained a first-use Core ML
compilation outlier near `1052 ms`; it is not hidden or treated as warm cost.

`comparison-cheap-left-neural-right-800x225.ppm` visibly demonstrates the
expected transformation: the left half is the categorical, flat-color cheap
input and the right half reconstructs the aligned materialized and lit urban
fixture. Geometry and object layout remain recognizable. Local blur and
chromatic ringing remain visible at high-contrast and emissive boundaries,
matching NR5-D's recorded limitations.

The exact external manifest digest is
`96122d89ddd360c1e9c2840b81273dde62d8c4587b87e04575c75d88f10a5be8`.
The bundle freezes and verifies all eight executing export/inspection/model/data
source modules, in addition to the complete Core ML package inventory.
Core ML float32 export agreed with its PyTorch wrapper to maximum absolute error
`0.00001955` and mean absolute error `0.00000017` on the export fixture.

The finite product incident smoke at
`/tmp/incinerator-nr5-e-incident-b-mtc4fB/2026-08-10T15-40-09.683Z_solo_3f5a70b3`
also completed cleanly. Its live metric stream contains 232
`kind:"neural_rendering"` records and the materialized anomaly window contains
170. The final window record binds the exact manifest/checkpoint, source frame
170, presented source frame 169, zero failures, and zero unknown category
pixels. `zig build inspect-incident` accepted all 1,678 records, four windows,
52 visuals, replay, and handoff with no warnings.

## Disposition

NR5-E is accepted because it proves a real engine-to-model-to-Metal path and a
human-reviewable comparison before further model complexity. It does not make
the checkpoint title-wide, temporal, art-complete, performance-ready,
promotion-eligible, or selected runtime content. NR6 remains the next research
phase and must preserve this exact fallback, identity, evidence, and explicit
selection boundary while adding causal history.
