# RF8 Direct 640×360 Spatial Sharpness Validation

**Disposition:** Accepted as an explicit external live trial; unpromoted

**Date:** 2026-08-12

## Executed contract

RF8 replaces the active RF7 resolution and window-presentation cohort with one
exact 16:9 transformation:

```text
native low-fidelity 160×90 deterministic inputs
  → one random-initialized title model with native-grid refinement
  → native high-fidelity 640×360 scene-linear HDR output
```

The mapping is uniform 4:1 on both axes. Every rich target was rendered fresh
and directly at 640×360. No 400×225 or 800×450 image was used as an input,
target, intermediate, supervision signal, comparison source, acceptance
reference, export handoff, or runtime output. Those cohorts remain immutable
history.

Input schema v5 supplies native 160×90 appearance, depth, world normal,
motion/history, semantic identity, and instance identity plus four frame-global
lighting/material controls. Capture schema 6 and target-frame schema 6 own the
new extents and exact correspondence. The model adds native-output feature
capacity and is trained/selected using scene-linear color, log luminance,
chroma, multiscale color, gradient, high-frequency, Laplacian, local contrast,
semantic/instance edge, geometry, and negative-radiance evidence.

## Evidence roots

| Owner | External artifact root |
|---|---|
| Fresh corpus | `~/Library/Application Support/Incinerator/neural-rendering/experiments/rf8-direct-640x360-corpus-20260812-a` |
| Coverage authorization | `~/Library/Application Support/Incinerator/neural-rendering/experiments/rf8-direct-640x360-coverage-20260812-a` |
| Controlled fit | `~/Library/Application Support/Incinerator/neural-rendering/experiments/rf8-direct-640x360-controlled-fit-20260812-b` |
| Held-out entry | `~/Library/Application Support/Incinerator/neural-rendering/experiments/rf8-direct-640x360-held-out-entry-20260812-a` |
| Selected candidate | `~/Library/Application Support/Incinerator/neural-rendering/experiments/rf8-direct-640x360-held-out-20260812-a` |
| Core ML live trial | `~/Library/Application Support/Incinerator/neural-rendering/trial-bundles/rf8-direct-640x360-20260812-a` |
| Retained graphical evidence | `~/Library/Application Support/Incinerator/neural-rendering/experiments/rf8-direct-640x360-live-evidence-20260812-a` |

The controlled-fit `-a` root is retained failed diagnostic evidence. Its first
MPS step exposed a singular zero-variance local-contrast gradient; it was
stopped immediately and is excluded from lineage. RF8 stabilizes the
descriptor with an explicit epsilon under the square root, and a real MPS
forward/backward audit verifies finite loss and every parameter gradient before
the accepted `-b` run.

## Results

| Gate | Executed result |
|---|---|
| Corpus | 108 fresh pairs across six whole sequences: 18 overfit, 18 train, 18 validation, 18 sealed test, and 36 stress |
| Controlled fit | 1,060,987 parameters; MAE `0.009053` vs bilinear `0.426946`; spatial score `0.019879` vs `0.453498`; complete 18-frame visual review passed |
| Validation selection | Fresh random initializer; epoch 235 selected by validation spatial-quality score; MAE `0.010595` vs `0.451715`; spatial score `0.023531` vs `0.477380` |
| Sealed test | Opened once; MAE `0.015272` vs `0.400307`; spatial score `0.032047` vs `0.426868`; real second opening rejected before pixels |
| Stress | 36 frames; MAE `0.012508` vs `0.488265`; spatial score `0.025943` vs `0.509952`; every declared color, structure, Laplacian, and local-contrast gate passed |
| Export | Exact TorchScript agreement on all stress frames; Core ML max error `0.00003123`, mean `0.00000014` |
| Metal trial | 48 readbacks and 48 predictions; zero failures; zero unknown semantic or instance pixels |
| Trial timing | `18.704 ms` last inference; `70.529 ms` staged mean; `126.573 ms` staged maximum |
| Product presentation | Real 1600×900 window inspection passed: native 640×360 scene centered and unscaled with black surround; source-only Neural Input / Output tool; conventional editor/UI overlay |

Validation, test, and stress sheets preserve authored composition, identities,
target palette, materials, lighting, and near-edge geometry. The full model
materially beats interpolation and each ablation. Localized high-contrast and
emissive edge noise, a small negative-radiance fraction before display mapping,
the narrow single-fixture claim, and the blocking CPU-staged runtime path remain
known limitations. RF8 does not authorize promotion, installed game content,
temporal claims, or title-wide readiness.

## Live preview

From the repository root:

```sh
BUNDLE="$HOME/Library/Application Support/Incinerator/neural-rendering/trial-bundles/rf8-direct-640x360-20260812-a"

zig build inspect-nr5-e-trial-bundle -- "$BUNDLE"
zig build verify-nr5-e-trial -Deditor=true -- "$BUNDLE"

INCINERATOR_NR_TRIAL_BUNDLE="$BUNDLE" \
INCINERATOR_NR_TRIAL_FIXTURE=1 \
  zig build run -Deditor=true
```

The main presentation starts in neural mode. Press `N` to toggle conventional
and neural scene presentation. The collapsible **Neural Input / Output** tool
shows only the live native 160×90 source and model status because the 640×360
neural result is already the main scene. Resizing the window never stretches
the scene; extra space is black surround.

## Verification

```sh
zig build test -Deditor=false --summary all
zig build test-title-renderer-contracts --summary all
zig build inspect-title-renderer-run -- \
  "$HOME/Library/Application Support/Incinerator/neural-rendering/experiments/rf8-direct-640x360-controlled-fit-20260812-b"
zig build inspect-title-renderer-candidate -- \
  "$HOME/Library/Application Support/Incinerator/neural-rendering/experiments/rf8-direct-640x360-held-out-20260812-a"
zig build inspect-nr5-e-trial-bundle -- \
  "$HOME/Library/Application Support/Incinerator/neural-rendering/trial-bundles/rf8-direct-640x360-20260812-a"
zig build verify-nr5-e-trial -Deditor=true -- \
  "$HOME/Library/Application Support/Incinerator/neural-rendering/trial-bundles/rf8-direct-640x360-20260812-a"
```

RF8 closes the requested 16:9 resolution, sharper spatial reconstruction, and
fixed native presentation phase. NR6 temporal work remains deferred; the next
quality phase should broaden title-owned scene/material coverage or address the
measured high-contrast edge defects before adding history.
