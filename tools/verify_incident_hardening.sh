#!/bin/sh
set -eu

if [ "$#" -lt 4 ] || [ "$#" -gt 5 ]; then
    echo "usage: verify_incident_hardening.sh PRODUCT INSPECTOR REPLAY CONTENT_ROOT [OUTPUT_ROOT]" >&2
    exit 2
fi

product=$1
inspector=$2
replay=$3
content_root=$4
output_root=${5:-${INCINERATOR_HARDENING_ROOT:-$(mktemp -d "${TMPDIR:-/tmp}/incinerator-incident-hardening.XXXXXX")}}

for required in "$product" "$inspector" "$replay"; do
    if [ ! -x "$required" ]; then
        echo "missing executable incident-hardening input: $required" >&2
        exit 1
    fi
done
if [ ! -d "$content_root" ]; then
    echo "missing installed content root: $content_root" >&2
    exit 1
fi
mkdir -p "$output_root"

profiles="queue_pressure visual_budget writer_budget screenshot_submission screenshot_fence"
for profile in $profiles; do
    profile_root="$output_root/$profile"
    mkdir -p "$profile_root"
    output="$output_root/$profile.out"
    INCINERATOR_CONTENT_ROOT="$content_root" \
        INCINERATOR_INCIDENT_ROOT="$profile_root" \
        "$product" "--incident-hardening=$profile" >"$output" 2>&1

    result=$(grep "^INCIDENT_HARDENING_RESULT profile=$profile " "$output")
    run_path=$(printf '%s\n' "$result" | sed -E 's/^.* run=([^ ]+) .*$/\1/')
    if [ ! -d "$run_path" ]; then
        echo "hardening profile $profile did not publish a run folder" >&2
        exit 1
    fi
    printf '%s\n' "$result" | grep -q ' clipboard_publications=1$'

    "$inspector" "$run_path" >"$output_root/$profile.inspect" 2>&1
    grep -q "^INCIDENT_BUNDLE_VALID run=$run_path$" "$output_root/$profile.inspect"
    grep -q "  status=partial hardening=$profile " "$output_root/$profile.inspect"

    "$replay" verify-incident "$run_path" "$content_root" \
        >"$output_root/$profile.replay" 2>&1
    grep -q '^verified S4 replay: ' "$output_root/$profile.replay"

    echo "INCIDENT_HARDENING_PROFILE_PASS profile=$profile run=$run_path"
done

echo "INCIDENT_HARDENING_PASS profiles=5 root=$output_root"
