#!/bin/sh
set -eu

validation="$1"
content_root="$2"
repo_root="$3"

if [ "$#" -ge 4 ]; then
  evidence_root="$4"
  mkdir "$evidence_root"
else
  evidence_root="$(mktemp -d /tmp/incinerator-nr0-ab-acceptance-XXXXXX)"
fi
capture_a="$evidence_root/capture-a"
capture_b="$evidence_root/capture-b"
sequence="s13-default-follow-0001"

capture() {
  root="$1"
  INCINERATOR_CONTENT_ROOT="$content_root" \
  INCINERATOR_NR_CAPTURE_ROOT="$root" \
  INCINERATOR_NR_CAPTURE_START_FRAME=300 \
  INCINERATOR_NR_CAPTURE_STRIDE=60 \
  INCINERATOR_NR_CAPTURE_FRAMES=3 \
  INCINERATOR_NR_COHORT=validation \
  INCINERATOR_NR_SEQUENCE="$sequence" \
  INCINERATOR_NR_CAMERA_PATH=default-follow \
    "$validation" --s13-population-smoke --frames=3840 --virtual-render-hz=240
}

capture "$capture_a"
capture "$capture_b"
inspection="$(python3 "$repo_root/tools/neural-rendering/inspect_nr0_capture.py" \
  --require-identical "$capture_a" "$capture_b")"
printf '%s\n' "$inspection"
printf '%s\n' "$inspection" > "$evidence_root/inspection.json"
python3 "$repo_root/tools/neural-rendering/nr0_visual_report.py" \
  "$capture_a" "$evidence_root/contact-sheet.ppm"

printf 'NR0_AB_ACCEPTANCE status=pass evidence=%s captures=2 frames=6 deterministic=true\n' \
  "$evidence_root"
