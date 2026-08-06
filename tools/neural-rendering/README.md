# Neural Rendering Offline Tools

This directory owns the macOS-local NR0 experiment toolchain. It contains the
preliminary NR-0001 existing-frame model loop plus the accepted NR0-A/B
multi-channel capture, inspection, and visual-report tools. Spatial model work
against the new schema begins in NR0-C. Promotion and an installed GPU-resident
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

## NR0-A/B multi-channel paired capture

The product now renders schema-v1 neural inputs as six 400×225 RGBA8 targets:
appearance, linear depth, world normal, motion, semantic, and instance. A
selected frame is captured with the exact submitted conventional scene at a
canonical 1600×900 before editor UI and diagnostics. Every raw buffer, debug
PPM, stable presentation identity, matrix, frame/tick, effect value, source,
content, schema, and shader revision is recorded and hashed in capture schema 2.
Metal BGRA product color is normalized to canonical RGBA8 raw bytes; the source
GPU format remains in each frame manifest.

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
six raw/debug channel directories, and raw/debug conventional targets. Raw
files are training data; PPM files are explicitly described human derivatives.
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

NR-0001 training tools consume their earlier RGB-pair schema. Do not silently
feed schema-2 captures to them. NR0-C must define one multi-channel dataset
adapter and experiment before making a new quality claim.

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
