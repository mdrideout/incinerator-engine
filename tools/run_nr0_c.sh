#!/bin/sh
# Reproduce the complete NR0-C capture, fit, held-out, export, and benchmark path.
set -eu

if [ "$#" -ne 5 ]; then
    echo "usage: $0 <validation-bin> <content-root> <repo-root> <python> <new-absolute-run-root>" >&2
    exit 2
fi

validation=$1
content=$2
repo=$3
python=$4
root=$5

case "$root" in
    /*) ;;
    *) echo "run root must be absolute: $root" >&2; exit 2 ;;
esac
if [ -e "$root" ]; then
    echo "run root already exists; experiment runs are immutable: $root" >&2
    exit 2
fi

mkdir -p "$root/captures" "$root/logs"

capture() {
    split=$1
    sequence=$2
    camera=$3
    frames=$4
    stride=$5
    INCINERATOR_CONTENT_ROOT="$content" \
    INCINERATOR_NR_CAPTURE_ROOT="$root/captures/$split" \
    INCINERATOR_NR_CAPTURE_START_FRAME=300 \
    INCINERATOR_NR_CAPTURE_STRIDE="$stride" \
    INCINERATOR_NR_CAPTURE_FRAMES="$frames" \
    INCINERATOR_NR_COHORT="$split" \
    INCINERATOR_NR_SEQUENCE="$sequence" \
    INCINERATOR_NR_CAMERA_PATH="$camera" \
        "$validation" --s13-population-smoke --frames=3840 --virtual-render-hz=240 \
        > "$root/logs/capture-$split.log" 2>&1
}

capture overfit nr0002-overfit-orbit-close-0001 orbit-close 8 45
capture train nr0002-train-default-follow-0001 default-follow 40 45
capture validation nr0002-validation-orbit-wide-0001 orbit-wide 12 90
capture test nr0002-test-elevated-sweep-0001 elevated-sweep 12 90

cd "$repo"
"$python" tools/neural-rendering/inspect_nr0_capture.py \
    "$root/captures/overfit" "$root/captures/train" \
    "$root/captures/validation" "$root/captures/test" \
    > "$root/capture-inspection.json"
"$python" tools/neural-rendering/assemble_nr0_dataset.py \
    --overfit-capture "$root/captures/overfit" \
    --train-capture "$root/captures/train" \
    --validation-capture "$root/captures/validation" \
    --test-capture "$root/captures/test" \
    --output "$root/dataset"
"$python" tools/neural-rendering/train_nr0_spatial.py \
    --dataset "$root/dataset/dataset.json" --output "$root/overfit-run" \
    --stage overfit --epochs 60 --batch-size 2 --learning-rate 0.001 \
    --patch-size 96 --features 24 --blocks 3 --device mps --require-gate
"$python" tools/neural-rendering/train_nr0_spatial.py \
    --dataset "$root/dataset/dataset.json" --output "$root/heldout-run" \
    --stage heldout --epochs 80 --batch-size 4 --learning-rate 0.001 \
    --patch-size 96 --features 24 --blocks 3 --validation-every 10 \
    --device mps --require-gate
"$python" tools/neural-rendering/export_nr0_coreml.py \
    --checkpoint "$root/heldout-run/checkpoint.pt" \
    --dataset "$root/dataset/dataset.json" --output "$root/coreml-export"
"$python" tools/neural-rendering/benchmark_nr0_coreml.py \
    --model "$root/coreml-export/nr0-spatial.mlpackage" \
    --output "$root/coreml-export/benchmark-all.json" \
    --iterations 500 --warmup 50 --compute-units all
"$python" tools/neural-rendering/finalize_nr0_c.py \
    --root "$root" --visual-review pending \
    --visual-review-note "Numerical gates passed; comparison sheets require human review."
