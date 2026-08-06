# Neural Rendering Offline Tools

This directory owns the first macOS-local NR0 experiment toolchain. The current
commands prove existing-frame preparation, exact same-frame engine product-color
capture, whole-run dataset assembly, spatial training/evaluation, Core ML
export, and native in-engine prediction. This is the deliberately narrow
NR-0001 pipeline proof. Auxiliary-buffer capture, promotion, and an installed
GPU-resident runtime remain later NR0 phases.

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

## Exact engine product-color pipeline

The validation host can capture an exact same-frame 80x45 input and 320x180
conventional product-color target. Editor UI and diagnostics are composed later
and are absent from both images. Each capture root must be absolute and must not
already exist. Use separate complete runs as train, validation, and test
cohorts; never split neighboring frames from one run across those sets.

```sh
zig build install-validation -Deditor=false

VALIDATION="$PWD/zig-out/libexec/incinerator/incinerator_validation"
TRAIN_CAPTURE="$INCINERATOR_NR_ROOT/runs/nr0-engine-train-20260805-a"
VALIDATION_CAPTURE="$INCINERATOR_NR_ROOT/runs/nr0-engine-validation-20260805-a"
TEST_CAPTURE="$INCINERATOR_NR_ROOT/runs/nr0-engine-test-20260805-a"

INCINERATOR_NR_CAPTURE_ROOT="$TRAIN_CAPTURE" \
INCINERATOR_NR_CAPTURE_START_FRAME=300 \
INCINERATOR_NR_CAPTURE_STRIDE=5 \
INCINERATOR_NR_CAPTURE_FRAMES=80 \
  "$VALIDATION" --s13-population-smoke --frames=3840 --virtual-render-hz=240

INCINERATOR_NR_CAPTURE_ROOT="$VALIDATION_CAPTURE" \
INCINERATOR_NR_CAPTURE_START_FRAME=1400 \
INCINERATOR_NR_CAPTURE_STRIDE=5 \
INCINERATOR_NR_CAPTURE_FRAMES=80 \
  "$VALIDATION" --s13-population-smoke --frames=3840 --virtual-render-hz=240

INCINERATOR_NR_CAPTURE_ROOT="$TEST_CAPTURE" \
INCINERATOR_NR_CAPTURE_START_FRAME=2800 \
INCINERATOR_NR_CAPTURE_STRIDE=5 \
INCINERATOR_NR_CAPTURE_FRAMES=80 \
  "$VALIDATION" --s13-population-smoke --frames=3840 --virtual-render-hz=240
```

The frame windows above reproduce NR-0001; they are recorded sampling choices,
not engine limits. Each completed root contains `capture.json`, `frames.ndjson`,
and digest-addressed `inputs/` and `targets/`. If a model is also active, the
same record includes its corresponding `outputs/` image.

Assemble, train, export, and benchmark without a mutable `latest` alias:

```sh
PYTHON="$INCINERATOR_NR_ROOT/envs/nr0-poc/bin/python"
DATASET="$INCINERATOR_NR_ROOT/datasets/nr0-engine-product-pairs-20260805-a"
RUN="$INCINERATOR_NR_ROOT/runs/nr0-engine-spatial-20260805-a"
EXPORT="$INCINERATOR_NR_ROOT/runs/nr0-engine-coreml-20260805-a"

"$PYTHON" tools/neural-rendering/assemble_engine_dataset.py \
  --train-capture "$TRAIN_CAPTURE" \
  --validation-capture "$VALIDATION_CAPTURE" \
  --test-capture "$TEST_CAPTURE" \
  --output "$DATASET"

"$PYTHON" tools/neural-rendering/train_spatial.py \
  --dataset "$DATASET/dataset.json" \
  --output "$RUN" \
  --epochs 40 \
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
  --iterations 500 \
  --warmup 50 \
  --input-width 80 \
  --input-height 45 \
  --compute-units all
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
