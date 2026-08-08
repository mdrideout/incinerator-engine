#!/bin/sh
set -eu

if [ "$#" -ne 6 ]; then
    echo "usage: $0 <validation-binary> <installed-content-root> <repository-root> <python> <checkpoint.pt> <new-absolute-run-root>" >&2
    exit 2
fi

validation=$1
content_root=$2
repository=$3
python=$4
checkpoint=$5
run_root=$6

case "$run_root" in
    /*) ;;
    *) echo "run root must be absolute: $run_root" >&2; exit 2 ;;
esac
case "$checkpoint" in
    /*) ;;
    *) echo "checkpoint must be absolute: $checkpoint" >&2; exit 2 ;;
esac
if [ -e "$run_root" ]; then
    echo "run root already exists: $run_root" >&2
    exit 2
fi
if [ ! -x "$validation" ] || [ ! -x "$python" ] || [ ! -f "$checkpoint" ]; then
    echo "validation binary, Python, or checkpoint is missing" >&2
    exit 2
fi

mkdir -p "$run_root/captures"

capture() {
    sequence=$1
    camera=$2
    start=$3
    count=$4
    frames=$((start + count + 8))
    root="$run_root/captures/$sequence"
    INCINERATOR_CONTENT_ROOT="$content_root" \
    INCINERATOR_NR_CAPTURE_ROOT="$root" \
    INCINERATOR_NR_CAPTURE_START_FRAME="$start" \
    INCINERATOR_NR_CAPTURE_STRIDE=1 \
    INCINERATOR_NR_CAPTURE_FRAMES="$count" \
    INCINERATOR_NR_COHORT=stress \
    INCINERATOR_NR_SEQUENCE="$sequence" \
    INCINERATOR_NR_CAMERA_PATH="$camera" \
        "$validation" --nr0-evaluation-smoke --frames="$frames" --virtual-render-hz=240
    "$python" "$repository/tools/neural-rendering/inspect_nr0_capture.py" "$root"
}

# Consecutive frames are intentional: the motion ABI describes exactly the
# preceding presentation frame and cannot validate temporal behavior at a
# hidden sampling stride.
capture nr0-d-near-pass-0001 near-pass 90 64
capture nr0-d-fast-orbit-0001 fast-orbit 90 64
capture nr0-d-disocclusion-sweep-0001 disocclusion-sweep 90 64
capture nr0-d-camera-cut-0001 camera-cut 50 80
capture nr0-d-top-down-0001 top-down 90 64
capture nr0-d-resize-cycle-0001 resize-cycle 110 142

set --
for root in "$run_root"/captures/*; do
    set -- "$@" --capture "$root"
done

"$python" "$repository/tools/neural-rendering/evaluate_nr0_d.py" \
    --checkpoint "$checkpoint" \
    --output "$run_root/evaluation" \
    --device mps \
    "$@"
"$python" "$repository/tools/neural-rendering/inspect_nr0_d.py" "$run_root/evaluation"

echo "$run_root"
