#!/bin/sh
set -eu

if [ "$#" -ne 3 ]; then
  printf '%s\n' 'usage: verify_nr5_e_trial.sh <validation-exe> <content-root> <absolute-trial-bundle>' >&2
  exit 2
fi

validation="$1"
content_root="$2"
trial_bundle="$3"
evidence_root="$(mktemp -d /tmp/incinerator-nr5-e-trial-XXXXXX)"

case "$trial_bundle" in
  /*) ;;
  *) printf '%s\n' 'NR5-E trial bundle must be absolute' >&2; exit 2 ;;
esac

INCINERATOR_CONTENT_ROOT="$content_root" \
INCINERATOR_NR_TRIAL_BUNDLE="$trial_bundle" \
INCINERATOR_NR_TRIAL_FIXTURE=1 \
INCINERATOR_NR_TRIAL_EVIDENCE_ROOT="$evidence_root" \
  "$validation" --nr0-evaluation-smoke --frames=48 --virtual-render-hz=60

printf 'NR5_E_TRIAL_ACCEPTANCE status=pass evidence=%s\n' "$evidence_root"
