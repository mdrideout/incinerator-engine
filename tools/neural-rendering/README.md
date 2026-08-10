# Neural Rendering Offline Tools

This directory owns the macOS-local NR0 experiment toolchain. It contains the
preliminary NR-0001 existing-frame model loop, the accepted NR0-A/B
multi-channel capture/inspection tools, and the complete NR0-C 17-plane model
loop plus NR0-D stress evaluation. Promotion and an installed GPU-resident
runtime remain later NR0 phases.

Training frameworks and their environments stay here or in an explicitly
managed external environment. They cannot enter the product, validation-only
Metal host, headless authority, or server dependency graphs merely because a
build step can invoke the tool.

Prefer explicit paths and self-describing manifests. Do not discover a global
dataset, a mutable `latest` checkpoint, or an ambient model cache. A Zig build
step may orchestrate a tool after the command exists, but the underlying tool
must remain directly runnable and inspectable.

Promotion must follow
[ADR-025](../../docs/adr/025-game-specific-neural-rendering-boundary.md) and
must never mutate the source experiment run.

## macOS environment

Python 3.13 is deliberate. The repository pins the directly tested package
cohort; generated environments and package caches remain outside Git.

```sh
export INCINERATOR_NR_ROOT="$HOME/Library/Application Support/Incinerator/neural-rendering"
/opt/homebrew/opt/python@3.13/bin/python3.13 -m venv "$INCINERATOR_NR_ROOT/envs/nr0-poc"
"$INCINERATOR_NR_ROOT/envs/nr0-poc/bin/python" -m pip install --upgrade pip
"$INCINERATOR_NR_ROOT/envs/nr0-poc/bin/python" -m pip install -r tools/neural-rendering/requirements-macos.txt
```

Every run records `pip freeze`, Python, PyTorch, MPS availability, host, and
repository revision in its external manifest. Changing the pinned cohort is an
experiment/toolchain change and must be retested through export and prediction.

## NR-0001 existing-frame pipeline

Choose whole incident runs for validation and test; all remaining visual runs
become training sources. The output directory must be absolute and absent.
`--selection-stride` is an explicit recorded sampling decision, not a hidden
frame cap.

```sh
PYTHON="$INCINERATOR_NR_ROOT/envs/nr0-poc/bin/python"
DATASET="$INCINERATOR_NR_ROOT/datasets/nr-0001-existing-frames-20260805"
RUN="$INCINERATOR_NR_ROOT/runs/nr-0001-spatial-20260805"
EXPORT="$INCINERATOR_NR_ROOT/runs/nr-0001-coreml-20260805"

"$PYTHON" tools/neural-rendering/test_tools.py

"$PYTHON" tools/neural-rendering/prepare_incident_dataset.py \
  --incident-root "$HOME/Library/Logs/Incinerator/runs" \
  --output "$DATASET" \
  --validation-run 2026-07-19T18-46-02.658Z_solo_7a426367 \
  --test-run 2026-07-28T15-04-08.142Z_solo_905c53ab \
  --target-size 320x180 \
  --scale 4 \
  --selection-stride 5

"$PYTHON" tools/neural-rendering/train_spatial.py \
  --dataset "$DATASET/dataset.json" \
  --output "$RUN" \
  --epochs 20 \
  --batch-size 16 \
  --learning-rate 0.001 \
  --device mps

"$PYTHON" tools/neural-rendering/export_coreml.py \
  --checkpoint "$RUN/checkpoint.pt" \
  --output "$EXPORT" \
  --input-width 80 \
  --input-height 45

"$PYTHON" tools/neural-rendering/benchmark_coreml.py \
  --model "$EXPORT/spatial-upscaler.mlpackage" \
  --output "$EXPORT/benchmark-all.json" \
  --iterations 200 \
  --warmup 20 \
  --input-width 80 \
  --input-height 45 \
  --compute-units all
```

The experiment definition explains why these existing frames cannot satisfy
NR0 paired-capture or visual-quality acceptance:
[`../../experiments/neural-rendering/nr-0001-spatial-pipeline/README.md`](../../experiments/neural-rendering/nr-0001-spatial-pipeline/README.md).

## Native multi-channel input capture

The product now renders `incinerator.neural-input.v2` as six direct `160×90`
RGBA8 targets: appearance, linear depth, world normal, motion, semantic, and
instance. Capture schema 3 stores only those native inputs. It does not capture
or derive a conventional product target. High-fidelity truth is owned by the
separate direct `400×225` target adapter. Every raw buffer, debug PPM, stable
presentation identity, matrix, frame/tick, effect value, source, content,
schema, shader revision, and exact 5:2 mapping is recorded and hashed.

Every capture root must be absolute and absent. Cohort, sequence, and camera
path are mandatory. Adjacent frames from one sequence belong to one cohort;
never split a sequence across train, validation, and test.

```sh
zig build install-validation -Deditor=true

VALIDATION="$PWD/zig-out/libexec/incinerator/incinerator_validation"
CAPTURE="$INCINERATOR_NR_ROOT/datasets/nr0-ab-validation-s13-0001"

INCINERATOR_CONTENT_ROOT="$PWD/zig-out/share/incinerator/content" \
INCINERATOR_NR_CAPTURE_ROOT="$CAPTURE" \
INCINERATOR_NR_CAPTURE_START_FRAME=300 \
INCINERATOR_NR_CAPTURE_STRIDE=60 \
INCINERATOR_NR_CAPTURE_FRAMES=3 \
INCINERATOR_NR_COHORT=validation \
INCINERATOR_NR_SEQUENCE=s13-default-follow-0001 \
INCINERATOR_NR_CAMERA_PATH=default-follow \
  "$VALIDATION" --s13-population-smoke --frames=3840 --virtual-render-hz=240

zig build inspect-nr0-capture -- "$CAPTURE"
zig build nr0-visual-report -- "$CAPTURE" "$INCINERATOR_NR_ROOT/reports/nr0-ab-s13-0001.ppm"
```

A complete root contains `capture.json`, `frames.ndjson`, per-frame manifests,
and six raw/debug channel directories. Raw files are eligible input data; PPM
files and contact sheets are explicitly described human derivatives.
The inspector validates completeness, extents, byte counts, all digests,
schema/shader provenance, split ownership, stable/compact identity mapping,
cross-channel coverage, depth/normal/motion encoding, and semantic/instance
pixels against their declared frame mappings.

Use the acceptance step after changing the input contract, shaders, capture,
presentation identity, camera derivation, or relevant renderer seams:

```sh
zig build verify-nr0-ab
```

It launches the deterministic S13 cohort twice, requires the logical and byte
signatures to match, and prints the retained external evidence root containing
both captures and a contact sheet. To keep a named acceptance root, call the
underlying script with an absent fourth path:

```sh
zig build install-validation -Deditor=true
sh tools/verify_nr0_ab.sh \
  "$PWD/zig-out/libexec/incinerator/incinerator_validation" \
  "$PWD/zig-out/share/incinerator/content" \
  "$PWD" \
  "$INCINERATOR_NR_ROOT/acceptance/nr0-ab-20260805"
```

NR-0001/2 training tools consume historical schemas. Do not silently feed
capture-schema-3 roots to them. The next title model requires the NR4-D dataset
adapter defined against the accepted native cohort.

## NR0-C multi-channel spatial baseline

NR0-C has a separate schema-2 adapter and model family. It packs the accepted
capture channels into 17 named planes and never feeds camera, authority,
simulation, entity, or input-control state into the network. Capture-only
camera programs are real deterministic presentation poses, not metadata labels.

Run its focused contracts in the pinned environment:

```sh
PYTHON="$INCINERATOR_NR_ROOT/envs/nr0-poc/bin/python"
"$PYTHON" tools/neural-rendering/test_nr0_c_tools.py
```

The complete reproduction command is recorded in
[`NR-0002`](../../experiments/neural-rendering/nr-0002-multichannel-spatial-baseline/README.md).
`tools/run_nr0_c.sh` requires the installed validation binary, installed content
root, repository root, pinned Python, and a new absolute run root. It performs
four disjoint captures, inspection, dataset assembly, controlled fit, held-out
training/selection/test, Core ML export, and benchmark. Its final manifest uses
`pending` visual review deliberately; an agent or human must inspect the saved
comparison sheets and run `finalize_nr0_c.py --visual-review accepted` against
the same root to create the final `experiment.json`. Pending review writes
`experiment-pending.json`; neither file is overwritten. A completed accepted
or rejected run is immutable. Verify its retained digests and gates read-only:

```sh
"$PYTHON" tools/neural-rendering/inspect_nr0_experiment.py <absolute-run-root>
```

## Try the native proof

The model path is an explicit developer experiment path, not content selection
or promotion. It must be absolute. With the NR-0001 artifact produced above:

```sh
MODEL="$INCINERATOR_NR_ROOT/runs/nr0-engine-coreml-20260805-a/spatial-upscaler.mlpackage"
INCINERATOR_NR_MODEL="$MODEL" zig build run -Deditor=true
```

The neural scene starts enabled. Press `N` to compare it with the conventional
renderer. UI, editor chrome, and diagnostic overlays remain conventionally
rendered in either mode. Startup rejection or prediction failure selects the
conventional scene and emits `NEURAL_RENDERER_FALLBACK`; shutdown emits the
prediction, failure, Core ML, and staged-pipeline measurements.

This proof uses a blocking GPU readback, CPU tensor conversion, and GPU upload.
That path exists only to close and measure the loop. It is not the future
GPU-resident NR0 runtime and no artifact produced by these commands belongs in
`models/neural-rendering/` without the explicit promotion phase.

## NR0-D stress evaluation and failure analysis

NR0-D uses a dedicated presentation-only fixture and the `near-pass`,
`fast-orbit`, `disocclusion-sweep`, `camera-cut`, `top-down`, and
`resize-cycle` capture programs. The fixture represents rigid geometry,
categorical identity, occlusion, and motion pressure that the current renderer
actually exposes. It does not pretend current flat-color primitives prove
metallic, glossy, emissive, transparency, volumetric, or exposure-conditioned
rendering.

Run the focused metric contracts first:

```sh
PYTHON="$INCINERATOR_NR_ROOT/envs/nr0-poc/bin/python"
"$PYTHON" tools/neural-rendering/test_nr0_d_tools.py
```

The complete runner requires the installed validation host, installed content,
repository, pinned Python, exact NR-0002 checkpoint, and a new absolute root:

```sh
zig build install-validation -Deditor=true
tools/run_nr0_d.sh \
  "$PWD/zig-out/libexec/incinerator/incinerator_validation" \
  "$PWD/zig-out/share/incinerator/content" \
  "$PWD" \
  "$PYTHON" \
  "$INCINERATOR_NR_ROOT/experiments/nr-0002-20260806-a/heldout-run/checkpoint.pt" \
  "$INCINERATOR_NR_ROOT/experiments/<new-nr0-d-run-id>"
```

The external evaluation root retains complete frame, instance, semantic-edge,
temporal, inference, memory, and visual evidence. Inspect it read-only, then
append exactly one review conclusion:

```sh
"$PYTHON" tools/neural-rendering/inspect_nr0_d.py <evaluation-root>
"$PYTHON" tools/neural-rendering/finalize_nr0_d.py \
  --root <evaluation-root> \
  --review accepted \
  --note '<observed useful envelope and unacceptable failures>'
```

An accepted NR0-D review accepts the phase evidence, not the model for runtime
selection. NR0-E remains the only promotion boundary.

The accepted 2026-08-08 evaluation is retained at
`$INCINERATOR_NR_ROOT/experiments/nr0-d-20260807-a`; its crop-complete entry
point is `evaluation-v2/evaluation.json`. It covers 478 frames and 9,374
visible instances across all six paths. The evidence accepts NR0-D but finds
NR-0002 unsuitable for promotion because temporal residual and boundary
sharpness are worse than bilinear. The immutable `evaluation/` first pass is
retained but superseded because it omitted the promised measured temporal and
disocclusion convenience crops. See the committed
[evaluation conclusion](../../experiments/neural-rendering/nr-0002-multichannel-spatial-baseline/NR0-D-EVALUATION.md)
before designing the next candidate.

## NR-0003 LTX-Video 2B distilled baseline

NR-0003 is an offline quality-first experiment. Its Python environment,
official upstream checkout, model cache, generated sequence, and candidate
folders are external. It does not add LTX, Transformers, or Diffusers to any
engine product dependency graph.

Use the separate environment and exact upstream revision documented in the
[experiment conclusion](../../experiments/neural-rendering/nr-0003-ltxv-2b-distilled/README.md).
The tools enforce a complete capture-schema-2 source, an `8N+1` frame count,
32-pixel extent alignment, exact appearance hashes and frame lineage, explicit
absolute absent outputs, Apple MPS, the declared 2B distilled checkpoint,
disabled prompt enhancement, immutable config/prompt snapshots, model-license
evidence, synchronized warm timing, process RSS, generated-video hashes, and
source/output comparison sheets.

```sh
LTX_PYTHON="$INCINERATOR_NR_ROOT/envs/nr-0003-ltxv-2b/bin/python"
export HF_HOME="$INCINERATOR_NR_ROOT/model-cache/huggingface"
export PYTHONPATH="$PWD/tools/neural-rendering"

"$LTX_PYTHON" tools/neural-rendering/test_nr0003_ltxv_tools.py

"$LTX_PYTHON" tools/neural-rendering/prepare_ltxv_sequence.py \
  --capture <absolute-complete-capture> \
  --output <new-absolute-sequence-root> \
  --frames 9 --extent 512x288 --fps 8

export PYTHONPATH="$INCINERATOR_NR_ROOT/upstream/LTX-Video:$PWD/tools/neural-rendering"
"$LTX_PYTHON" tools/neural-rendering/run_ltxv_candidate.py \
  --repo "$PWD" \
  --upstream "$INCINERATOR_NR_ROOT/upstream/LTX-Video" \
  --sequence <absolute-sequence-root>/sequence.json \
  --config "$PWD/experiments/neural-rendering/nr-0003-ltxv-2b-distilled/ltxv-2b-v2v-mps.yaml" \
  --prompt "$PWD/experiments/neural-rendering/nr-0003-ltxv-2b-distilled/style-prompt.txt" \
  --output <new-absolute-candidate-root>

"$LTX_PYTHON" tools/neural-rendering/inspect_ltxv_candidate.py \
  <absolute-candidate-root>
```

The conservative config is the structure baseline. The separate `rich` config
is quality pressure that deliberately demonstrates the stock model's geometry
failure. Neither is promotion-eligible or an initialization source. ADR-026
retains LTX only as a comparison baseline. Do not continue stock
prompt/strength sweeps or implement fine-tuning in place of producing exact
high-fidelity target pairs and training the repository-owned title renderer
from random initialization.

## NR4-C native Blender/Cycles target still

NR4-C is a validation-only offline target factory. It does not add Blender or
Python to the engine, headless, server, or installed runtime dependency graph.
It exports an adapter-local package from the same immutable draw stream used by
the neural input capture, then reconstructs the selected frame in pinned
Cycles Metal.

Install the exact external Blender environment once:

```sh
export INCINERATOR_NR_ROOT="$HOME/Library/Application Support/Incinerator/neural-rendering"
bash tools/neural-rendering/targets/blender/install_macos.sh \
  "$INCINERATOR_NR_ROOT/envs/nr4-blender"
```

Build the validation host and run the two-proof gate from a new absent output
root:

```sh
zig build install-validation -Deditor=true --summary failures

NR_PYTHON="$INCINERATOR_NR_ROOT/envs/nr0-poc/bin/python"
BLENDER="$INCINERATOR_NR_ROOT/envs/nr4-blender/apps/Blender-4.5.12.app/Contents/MacOS/Blender"
OUTPUT="$INCINERATOR_NR_ROOT/experiments/nr4-c-native-still-$(date -u +%Y%m%dT%H%M%SZ)"

PYTHONPATH=tools/neural-rendering/targets/blender \
  "$NR_PYTHON" tools/neural-rendering/targets/blender/test_tools.py

  "$NR_PYTHON" tools/neural-rendering/targets/blender/verify_nr4_c_still.py \
  --validation "$PWD/zig-out/libexec/incinerator/incinerator_validation" \
  --content-root "$PWD/zig-out/share/incinerator/content" \
  --repo "$PWD" \
  --blender "$BLENDER" \
  --output "$OUTPUT"
```

Read `acceptance.json`, `reproducibility.json`, and both
`run-*/evaluation/native-baselines/native-160x90-to-400x225-review.png` files.
Each run also contains atomic engine
capture and target-package manifests, canonical scene-linear OpenEXR, AgX PNG,
identity/depth/normal buffers, alignment records, exact source/environment
fingerprints, and command logs. Inspect either proof independently with:

```sh
PYTHONPATH=tools/neural-rendering/targets/blender \
  "$NR_PYTHON" tools/neural-rendering/targets/blender/inspect_native_still.py \
  "$OUTPUT/run-a"
```

The accepted still evidence uses input schema v3, capture schema 4, and target
frame schema v4. Capture contains native `160×90` inputs plus four exact
frame-global float32 controls. Cycles emits the direct native `400×225` target;
UI zoom and deterministic resize baselines are explicitly excluded from
training material.

## NR4-C native material-rich moving target

NR4-C uses `incinerator.nr4.blender-target-frame.v4`, which adds explicit
material response, local-light state, and causal sequence metadata to the
offline adapter package and the exact 5:2 pixel-center mapping. It consumes
`incinerator.neural-input.v3` and its 16-byte frame-global control payload.

Run the focused contracts and two-proof gate from a new absolute absent root:

```sh
export INCINERATOR_NR_ROOT="$HOME/Library/Application Support/Incinerator/neural-rendering"
NR_PYTHON="$INCINERATOR_NR_ROOT/envs/nr0-poc/bin/python"
BLENDER="$INCINERATOR_NR_ROOT/envs/nr4-blender/apps/Blender-4.5.12.app/Contents/MacOS/Blender"
OUTPUT="$INCINERATOR_NR_ROOT/experiments/nr4-c-native-sequence-$(date -u +%Y%m%dT%H%M%SZ)"

zig build install-validation -Deditor=true --summary failures
PYTHONPATH=tools/neural-rendering/targets/blender \
  "$NR_PYTHON" tools/neural-rendering/targets/blender/test_tools.py

PYTHONPATH=tools/neural-rendering/targets/blender \
  "$NR_PYTHON" tools/neural-rendering/targets/blender/verify_nr4_c.py \
  --validation "$PWD/zig-out/libexec/incinerator/incinerator_validation" \
  --content-root "$PWD/zig-out/share/incinerator/content" \
  --repo "$PWD" \
  --blender "$BLENDER" \
  --output "$OUTPUT"
```

The runner records 18 exact frames across camera motion, rigid vehicle motion,
near-edge motion, wheel articulation, NPC occlusion/disocclusion, and
lighting/emissive response. It emits one source-cause audit, per-frame
identity/depth alignment, an overview, six detailed contact sheets, and a
second complete proof with measured Cycles variation.

Inspect retained evidence read-only:

```sh
PYTHONPATH=tools/neural-rendering/targets/blender \
  "$NR_PYTHON" tools/neural-rendering/targets/blender/inspect_sequence.py \
  "$OUTPUT/run-a"
```

Start human review with `acceptance.json`, `reproducibility.json`, and
`run-a/evaluation/reports/nr4-c-native-sequence-review.png`.

## NR4-C native working resolution status

NR4-C advances the engine/input/capture cohort together; existing NR4-A/B
commands and artifacts remain historical and are not accepted as sources for
new proof commands. The new commands use `160×90` cheap appearance/default
controls and `400×225` direct Cycles targets. The manifest must record both
extents and the exact 2.5× top-left, pixel-center mapping rather than a generic
integer scale.

The implemented validation sequence is:

1. add focused extent, byte-count, coordinate-mapping, border, thin-feature,
   identity-edge, and motion tests;
2. generate and obtain fresh human acceptance for a direct native `400×225`
   target still paired with the exact native `160×90` source event;
3. regenerate all 18 causal frames using native `160×90` inputs and direct
   native `400×225` targets, excluding all earlier target pixels and metrics;
4. emit synchronized native source/target/alignment reports and establish
   nearest, bilinear, and bicubic `160×90 → 400×225` baselines;
5. measure capture size, target time, input raster time where observable,
   dataset decode time, and process/GPU memory on the M2 Max; and
6. only then run one-at-a-time control-resolution and ambiguity ablations.

The producer, inspector, reports, and tests landed as one cohort. Tools reject
foreign extents and do not generate cross-resolution references. Other output
extents are deferred. The current external technical roots are recorded in the
NR-0004 experiment README and validation ledger. Human review is accepted.

Audit semantic conditioning without mutating a proof root:

```sh
PYTHONPATH=tools/neural-rendering/targets/blender \
  "$NR_PYTHON" tools/neural-rendering/targets/blender/audit_native_ambiguity.py \
  --run "$OUTPUT/run-a" \
  --output <new-absolute-ambiguity-root>
```

The original native audit isolated `lighting_effect`: scene/material target
state changed while only motion B (history validity) changed in the raster
inputs. The accepted ablation adds sun, world, local-light, and emissive
strength as presentation-owned frame-global values. Both independent runs now
have no ambiguous segment. The control costs 16 bytes per frame and no extra
GPU raster target; spatial lighting remains conditional.

## NR4-D paired-corpus proof

Generate six fresh whole sequences, assemble them transactionally, inspect the
self-contained copy, and retain a compact display-only split sheet:

```sh
export INCINERATOR_NR_ROOT="$HOME/Library/Application Support/Incinerator/neural-rendering"
NR_PYTHON="$INCINERATOR_NR_ROOT/envs/nr0-poc/bin/python"
BLENDER="$INCINERATOR_NR_ROOT/envs/nr4-blender/apps/Blender-4.5.12.app/Contents/MacOS/Blender"
OUTPUT="$INCINERATOR_NR_ROOT/experiments/nr4-d-corpus-$(date -u +%Y%m%dT%H%M%SZ)"

zig build install-validation -Deditor=true --summary failures
PYTHONPATH=tools/neural-rendering/targets/blender \
  "$NR_PYTHON" tools/neural-rendering/targets/blender/test_tools.py

PYTHONPATH=tools/neural-rendering/targets/blender \
  "$NR_PYTHON" tools/neural-rendering/targets/blender/verify_nr4_d.py \
  --validation "$PWD/zig-out/libexec/incinerator/incinerator_validation" \
  --content-root "$PWD/zig-out/share/incinerator/content" \
  --repo "$PWD" \
  --blender "$BLENDER" \
  --output "$OUTPUT"
```

Inspect an existing corpus without modifying it:

```sh
PYTHONPATH=tools/neural-rendering/targets/blender \
  "$NR_PYTHON" tools/neural-rendering/targets/blender/inspect_nr4_d_corpus.py \
  "$OUTPUT/corpus"
```

The corpus keeps overfit, train, validation, sealed test, and stress ownership
at whole-sequence granularity. It rejects cross-sequence conditioning/pair
reuse, provenance drift, incomplete targets, corruption, and identity
mismatch. Repeated conditioning inside one sequence is valid temporal context,
not split leakage. `corpus/review/` is display-only and never training input.

## NR4-E and NR5-A/B title-renderer framework

The cold contract suite imports no training dependency:

```sh
zig build test-title-renderer-contracts --summary all
```

Record a scoped NR4-E coverage decision in a new external root:

```sh
export INCINERATOR_NR_ROOT="$HOME/Library/Application Support/Incinerator/neural-rendering"
NR_PYTHON="$INCINERATOR_NR_ROOT/envs/nr0-poc/bin/python"

PYTHONPATH=tools/neural-rendering python3 \
  tools/neural-rendering/title_renderer/coverage.py \
  --corpus "$INCINERATOR_NR_ROOT/experiments/nr4-d-corpus-20260808-b/corpus" \
  --output <new-absolute-coverage-root> \
  --repository "$PWD" \
  --product-approval product_owner_approved_nr4_d_review_sheet_2026_08_09
```

The coverage command hashes non-test training artifacts and reads target-frame
metadata for every split, but never decodes test input/target pixels. Its
acceptance is scoped; it does not convert fixture coverage into a title-wide
claim.

Run the NR5-A clean-room lifecycle proof:

```sh
PYTHONPATH=tools/neural-rendering "$NR_PYTHON" \
  tools/neural-rendering/title_renderer/self_test.py \
  --output <new-absolute-clean-room-root>
```

Run an NR5-B controlled overfit only after NR4-E accepts the corpus:

```sh
PYTHONPATH=tools/neural-rendering "$NR_PYTHON" \
  tools/neural-rendering/title_renderer/train.py \
  --corpus "$INCINERATOR_NR_ROOT/experiments/nr4-d-corpus-20260808-b/corpus" \
  --coverage-acceptance <absolute-accepted-nr4-e-root>/acceptance.json \
  --configuration "$PWD/experiments/neural-rendering/nr-0005-structural-title-renderer/nr5-b-controlled-overfit.json" \
  --output <new-absolute-training-root> \
  --repository "$PWD"

zig build inspect-title-renderer-run -- <absolute-training-root>
```

The trainer opens only the overfit split, snapshots its configuration, saves
the exact random initializer and optimizer/scheduler lineage, reports every
frame, and emits an unpromoted TorchScript comparison candidate. Finalization
is a separate immutable review action:

```sh
PYTHONPATH=tools/neural-rendering python3 \
  tools/neural-rendering/title_renderer/finalize.py \
  --run <absolute-training-root> \
  --disposition accepted \
  --review '<specific complete visual-review conclusion>'
```
