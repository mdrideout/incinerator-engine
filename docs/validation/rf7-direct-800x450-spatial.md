# RF7 Direct 800×450 Spatial Fidelity Validation

**Disposition:** Accepted as an explicit external live trial; unpromoted

**Date:** 2026-08-11

## Executed contract

RF7 replaces the active RF6 resolution cohort with one direct transformation:

```text
native low-fidelity 160×90 deterministic inputs
  → one learned 5× title model initialized from random weights
  → native high-fidelity 800×450 scene-linear HDR output
```

The native target adapter rendered every truth frame directly at `800×450`.
No `400×225` or `1600×900` image was used as an input, target, intermediate,
supervision signal, comparison source, acceptance reference, export handoff, or
runtime output. RF4–RF6 artifacts remain historical evidence only.

The model consumes six native `160×90` channels—appearance, linear depth,
world normal, motion/history, semantic identity, and instance identity—plus
four frame-global lighting/material controls. Its direct learned 5× projection
feeds output-grid residual blocks and predicts one native `800×450` result.

## Evidence roots

| Owner | External artifact root |
|---|---|
| Fresh corpus | `~/Library/Application Support/Incinerator/neural-rendering/experiments/rf7-direct-800x450-corpus-20260811-c` |
| Coverage authorization | `~/Library/Application Support/Incinerator/neural-rendering/experiments/rf7-direct-800x450-coverage-20260811-a` |
| Controlled fit | `~/Library/Application Support/Incinerator/neural-rendering/experiments/rf7-direct-800x450-controlled-fit-20260811-a` |
| Held-out entry | `~/Library/Application Support/Incinerator/neural-rendering/experiments/rf7-direct-800x450-held-out-entry-20260811-a` |
| Selected candidate | `~/Library/Application Support/Incinerator/neural-rendering/experiments/rf7-direct-800x450-held-out-20260811-a` |
| Core ML live trial | `~/Library/Application Support/Incinerator/neural-rendering/trial-bundles/rf7-direct-800x450-20260811-a` |
| Retained live evidence | `~/Library/Application Support/Incinerator/neural-rendering/experiments/rf7-direct-800x450-live-evidence-20260811-a` |

The two earlier `-a` and `-b` corpus roots are retained partial diagnostics from
the repaired capture-schema transition. They were never assembled, authorized,
or opened by training. Only the complete `-c` root is in the candidate lineage.

## Results

| Gate | Executed result |
|---|---|
| Corpus | 108 fresh pairs across six whole sequences: 18 overfit, 18 train, 18 validation, 18 sealed test, and 36 stress |
| Pair contract | Input schema v4, capture schema 5, target-frame schema v5, exact top-left pixel-center 5:1 mapping |
| Controlled fit | 1,245,147 parameters; epoch 220; linear-HDR MAE `0.013451` vs bilinear `0.427164`; exact TorchScript agreement |
| Validation selection | Fresh random initializer; epoch 215 selected using validation only; MAE `0.011649` vs bilinear `0.451924`; chroma MAE `0.003439` |
| Test | Opened once after immutable selection; MAE `0.016473` vs bilinear `0.400546`; the real second opening was rejected without reading pixels |
| Stress | 36 frames; MAE `0.013500` vs bilinear `0.488446`; every automated metric/boundary/ablation gate passed |
| Core ML | Float32 MLProgram; checkpoint-wrapper agreement exact; maximum Core ML error `0.00003147`, mean `0.000000135` |
| Metal trial | 48 readbacks and 48 predictions; zero failures; zero unknown semantic or instance pixels |
| Trial timing | First graphical gate: `19.631 ms` last inference, `107.024 ms` staged mean, `795.496 ms` cold maximum; retained warm evidence: `15.768 ms`, `91.127 ms`, `124.023 ms` respectively |

The validation, test, stress, and live sheets preserve the authored scene,
object identities, target palette, materials, and lighting. Compared with the
cheap source, the result adds the intended high-fidelity appearance directly at
800×450. Remaining defects are fine edge/texture noise around high-contrast
details, occasional emissive ringing, roughly 0.5–0.9% negative scene-linear
samples before display mapping, the narrow one-fixture generalization claim,
and the existing blocking CPU-staged runtime path. These do not authorize
promotion, installed game content, temporal claims, or title-wide readiness.

## Live preview

From the repository root:

```sh
BUNDLE="$HOME/Library/Application Support/Incinerator/neural-rendering/trial-bundles/rf7-direct-800x450-20260811-a"

zig build inspect-nr5-e-trial-bundle -- "$BUNDLE"
zig build verify-nr5-e-trial -Deditor=true -- "$BUNDLE"

INCINERATOR_NR_TRIAL_BUNDLE="$BUNDLE" \
INCINERATOR_NR_TRIAL_FIXTURE=1 \
  zig build run -Deditor=true
```

Open the collapsible **Neural Input / Output** tool. It shows the native
real-time `160×90` input above the native `800×450` neural result. Press `N` to
toggle the main presentation between conventional and neural output. The
bundle is loaded only through the explicit environment variable and remains
outside installed content.

## Verification commands

```sh
zig build test-title-renderer-contracts --summary all
zig build inspect-title-renderer-run -- \
  "$HOME/Library/Application Support/Incinerator/neural-rendering/experiments/rf7-direct-800x450-controlled-fit-20260811-a"
zig build inspect-title-renderer-candidate -- \
  "$HOME/Library/Application Support/Incinerator/neural-rendering/experiments/rf7-direct-800x450-held-out-20260811-a"
zig build inspect-nr5-e-trial-bundle -- \
  "$HOME/Library/Application Support/Incinerator/neural-rendering/trial-bundles/rf7-direct-800x450-20260811-a"
zig build verify-nr5-e-trial -Deditor=true -- \
  "$HOME/Library/Application Support/Incinerator/neural-rendering/trial-bundles/rf7-direct-800x450-20260811-a"
```

RF7 closes the requested direct spatial and live-preview path. NR6 temporal
work remains deferred until a later decision; the next fidelity work should be
driven by measured spatial defects and broader title-owned scene coverage.
