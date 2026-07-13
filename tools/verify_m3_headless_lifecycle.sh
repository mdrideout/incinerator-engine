#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
    echo "usage: verify_m3_headless_lifecycle.sh INSTALLED_PREFIX" >&2
    exit 2
fi

case $1 in
    /*) prefix=$1 ;;
    *) prefix=$(cd "$1" && pwd -P) ;;
esac
binary="$prefix/bin/incinerator_headless"
example="$prefix/etc/incinerator/headless/config.example.json"
manifest="$prefix/share/incinerator/headless/content.json"

for required in "$binary" "$example" "$manifest"; do
    if [ ! -f "$required" ]; then
        echo "missing installed M3 input: $required" >&2
        exit 1
    fi
done

work=$(mktemp -d "${TMPDIR:-/tmp}/incinerator-m3-lifecycle.XXXXXX")
child_pid=
cleanup() {
    if [ -n "$child_pid" ]; then
        # A hard-lag case deliberately stops the child. Make cleanup safe even
        # if an assertion fails while that process is suspended.
        kill -CONT "$child_pid" 2>/dev/null || true
        kill -TERM "$child_pid" 2>/dev/null || true
        wait "$child_pid" 2>/dev/null || true
    fi
    rm -rf "$work"
}
trap cleanup EXIT INT TERM

wait_for_ready() {
    ready_output=$1
    ready_label=$2
    ready=false
    attempt=0
    while [ "$attempt" -lt 500 ]; do
        if grep -q '^HEADLESS_READY ' "$ready_output" 2>/dev/null; then
            ready=true
            break
        fi
        if ! kill -0 "$child_pid" 2>/dev/null; then
            break
        fi
        sleep 0.01
        attempt=$((attempt + 1))
    done
    if [ "$ready" != true ]; then
        echo "$ready_label never published readiness" >&2
        exit 1
    fi
}

expect_failure() {
    failure_label=$1
    failure_output=$2
    shift 2
    if "$@" > "$failure_output" 2>&1; then
        echo "$failure_label unexpectedly succeeded" >&2
        exit 1
    fi
}

virtual_root="$work/virtual-save"
virtual_config="$work/virtual.json"
sed \
    -e "s#/tmp/incinerator-headless-saves#$virtual_root#" \
    -e 's/"virtual_ticks": 16384/"virtual_ticks": 256/' \
    "$example" > "$virtual_config"

first_output="$work/first.out"
second_output="$work/second.out"
"$binary" --config "$virtual_config" --content-manifest "$manifest" --synthetic-producers \
    > "$first_output" 2>&1
grep -q '"restored":false' "$first_output"
grep -q '"world_tick":256' "$first_output"
grep -Eq '"producer_ingress_high_water":[1-9]' "$first_output"
grep -Eq '"producer_submitted":\[[1-9][0-9]*,[1-9][0-9]*\]' "$first_output"
grep -Eq '"producer_completed":\[[1-9][0-9]*,[1-9][0-9]*\]' "$first_output"
test -f "$virtual_root/world.isav"

"$binary" --config "$virtual_config" --content-manifest "$manifest" --synthetic-producers \
    > "$second_output" 2>&1
grep -q '"restored":true' "$second_output"
grep -q '"world_tick":512' "$second_output"

# Startup policy is fail-closed: restore-required never creates a missing
# world, while fresh refuses to replace an existing committed slot.
restore_required_root="$work/restore-required-save"
restore_required_config="$work/restore-required.json"
sed \
    -e "s#$virtual_root#$restore_required_root#" \
    -e 's/"fresh_or_restore"/"restore_required"/' \
    "$virtual_config" > "$restore_required_config"
if "$binary" --config "$restore_required_config" --content-manifest "$manifest" --synthetic-producers \
    > "$work/restore-required.out" 2>&1; then
    echo "restore_required unexpectedly constructed a fresh world" >&2
    exit 1
fi
test ! -e "$restore_required_root/world.isav"

fresh_existing_config="$work/fresh-existing.json"
sed 's/"fresh_or_restore"/"fresh"/' "$virtual_config" > "$fresh_existing_config"
existing_before=$(shasum -a 256 "$virtual_root/world.isav" | awk '{print $1}')
if "$binary" --config "$fresh_existing_config" --content-manifest "$manifest" --synthetic-producers \
    > "$work/fresh-existing.out" 2>&1; then
    echo "fresh unexpectedly replaced an existing committed world" >&2
    exit 1
fi
existing_after=$(shasum -a 256 "$virtual_root/world.isav" | awk '{print $1}')
test "$existing_before" = "$existing_after"

fresh_root="$work/fresh-save"
fresh_config="$work/fresh.json"
sed "s#$virtual_root#$fresh_root#" "$fresh_existing_config" > "$fresh_config"
"$binary" --config "$fresh_config" --content-manifest "$manifest" --synthetic-producers \
    > "$work/fresh.out" 2>&1
grep -q '"restored":false' "$work/fresh.out"
test -f "$fresh_root/world.isav"

# A stale candidate is never promoted and is removed before the committed
# save is loaded. The canonical committed file must remain usable.
printf 'uncommitted candidate' > "$virtual_root/world.tmp"
"$binary" --config "$virtual_config" --content-manifest "$manifest" --synthetic-producers \
    > "$work/recovered.out" 2>&1
test ! -e "$virtual_root/world.tmp"
grep -q '"restored":true' "$work/recovered.out"

# Admission rejects a manifest that differs from the compiled logical catalog
# before world construction and cannot replace the last committed save.
before=$(shasum -a 256 "$virtual_root/world.isav" | awk '{print $1}')
bad_manifest="$work/content.bad.json"
sed 's/83d3376f8bd4/93d3376f8bd4/' "$manifest" > "$bad_manifest"
expect_failure \
    "mismatched compiled logical content" \
    "$work/rejected.out" \
    "$binary" --config "$virtual_config" --content-manifest "$bad_manifest" --synthetic-producers
grep -q 'IncompatibleLogicalCatalog' "$work/rejected.out"
after=$(shasum -a 256 "$virtual_root/world.isav" | awk '{print $1}')
test "$before" = "$after"

# A valid compiled manifest is independently rejected when the operator's
# configured cohort digest differs. This exercises config-to-manifest
# admission, rather than the compiled-manifest check above.
cohort_mismatch_config="$work/cohort-mismatch.json"
sed 's/83d3376f8bd4/93d3376f8bd4/' "$virtual_config" > "$cohort_mismatch_config"
expect_failure \
    "config-to-manifest cohort mismatch" \
    "$work/cohort-mismatch.out" \
    "$binary" --config "$cohort_mismatch_config" --content-manifest "$manifest" --synthetic-producers
grep -q 'IncompatibleContentCohort' "$work/cohort-mismatch.out"
after=$(shasum -a 256 "$virtual_root/world.isav" | awk '{print $1}')
test "$before" = "$after"

# The installed executable itself enforces missing, unknown, and oversized
# operator-input boundaries. Every rejection remains pre-authority, so the
# previously committed world must stay byte-identical.
expect_failure \
    "missing config" \
    "$work/missing-config.out" \
    "$binary" --config "$work/does-not-exist-config.json" --content-manifest "$manifest"
grep -q 'FileNotFound' "$work/missing-config.out"

expect_failure \
    "missing content manifest" \
    "$work/missing-manifest.out" \
    "$binary" --config "$virtual_config" --content-manifest "$work/does-not-exist-content.json"
grep -q 'FileNotFound' "$work/missing-manifest.out"

unknown_config="$work/unknown-config.json"
sed 's/"schema_version": 1,/"schema_version": 1, "unexpected": true,/' \
    "$virtual_config" > "$unknown_config"
expect_failure \
    "unknown config field" \
    "$work/unknown-config.out" \
    "$binary" --config "$unknown_config" --content-manifest "$manifest"
grep -q 'UnknownField' "$work/unknown-config.out"

unknown_manifest="$work/unknown-content.json"
sed 's/"schema_version": 1,/"schema_version": 1, "unexpected": true,/' \
    "$manifest" > "$unknown_manifest"
expect_failure \
    "unknown content-manifest field" \
    "$work/unknown-content.out" \
    "$binary" --config "$virtual_config" --content-manifest "$unknown_manifest"
grep -q 'UnknownField' "$work/unknown-content.out"

malformed_config="$work/malformed-config.json"
printf '{' > "$malformed_config"
expect_failure \
    "malformed config" \
    "$work/malformed-config.out" \
    "$binary" --config "$malformed_config" --content-manifest "$manifest"
grep -Eq 'SyntaxError|UnexpectedEndOfInput|UnexpectedToken' "$work/malformed-config.out"

malformed_manifest="$work/malformed-content.json"
printf '[' > "$malformed_manifest"
expect_failure \
    "malformed content manifest" \
    "$work/malformed-content.out" \
    "$binary" --config "$virtual_config" --content-manifest "$malformed_manifest"
grep -Eq 'SyntaxError|UnexpectedEndOfInput|UnexpectedToken' "$work/malformed-content.out"

oversized_config="$work/oversized-config.json"
awk 'BEGIN { for (i = 0; i < 65537; i++) printf "x" }' > "$oversized_config"
expect_failure \
    "oversized config" \
    "$work/oversized-config.out" \
    "$binary" --config "$oversized_config" --content-manifest "$manifest"
grep -q 'HeadlessInputSizeOutOfRange' "$work/oversized-config.out"

oversized_manifest="$work/oversized-content.json"
awk 'BEGIN { for (i = 0; i < 16385; i++) printf "x" }' > "$oversized_manifest"
expect_failure \
    "oversized content manifest" \
    "$work/oversized-content.out" \
    "$binary" --config "$virtual_config" --content-manifest "$oversized_manifest"
grep -q 'HeadlessInputSizeOutOfRange' "$work/oversized-content.out"

after=$(shasum -a 256 "$virtual_root/world.isav" | awk '{print $1}')
test "$before" = "$after"

# Corrupt and oversized committed slots fail closed without being rewritten.
# These copies isolate hostile-storage admission from the healthy reference
# slot whose bytes were proven above.
corrupt_root="$work/corrupt-save"
corrupt_config="$work/corrupt-save.json"
sed "s#$virtual_root#$corrupt_root#" "$virtual_config" > "$corrupt_config"
mkdir -p "$corrupt_root"
cp "$virtual_root/world.isav" "$corrupt_root/world.isav"
printf 'X' | dd of="$corrupt_root/world.isav" bs=1 seek=200 conv=notrunc 2>/dev/null
corrupt_before=$(shasum -a 256 "$corrupt_root/world.isav" | awk '{print $1}')
expect_failure \
    "corrupt committed save" \
    "$work/corrupt-save.out" \
    "$binary" --config "$corrupt_config" --content-manifest "$manifest"
grep -q 'SaveIntegrityMismatch' "$work/corrupt-save.out"
corrupt_after=$(shasum -a 256 "$corrupt_root/world.isav" | awk '{print $1}')
test "$corrupt_before" = "$corrupt_after"

oversized_root="$work/oversized-save"
oversized_save_config="$work/oversized-save.json"
sed "s#$virtual_root#$oversized_root#" "$virtual_config" > "$oversized_save_config"
mkdir -p "$oversized_root"
dd if=/dev/zero of="$oversized_root/world.isav" bs=1048576 count=9 2>/dev/null
oversized_before=$(shasum -a 256 "$oversized_root/world.isav" | awk '{print $1}')
expect_failure \
    "oversized committed save" \
    "$work/oversized-save.out" \
    "$binary" --config "$oversized_save_config" --content-manifest "$manifest"
grep -q 'HeadlessSaveLoadFailed' "$work/oversized-save.out"
oversized_after=$(shasum -a 256 "$oversized_root/world.isav" | awk '{print $1}')
test "$oversized_before" = "$oversized_after"

# A real pre-rename storage failure must preserve the last healthy committed
# bytes. Removing directory write permission forces candidate creation to fail
# after restore/ticks but before rename; restoring permission proves the old
# slot remains readable in a subsequent process.
storage_root="$work/storage-failure-save"
storage_bootstrap_config="$work/storage-bootstrap.json"
sed \
    -e "s#$virtual_root#$storage_root#" \
    -e 's/"virtual_ticks": 256/"virtual_ticks": 64/' \
    "$virtual_config" > "$storage_bootstrap_config"
"$binary" --config "$storage_bootstrap_config" --content-manifest "$manifest" --synthetic-producers \
    > "$work/storage-bootstrap.out" 2>&1
storage_before=$(shasum -a 256 "$storage_root/world.isav" | awk '{print $1}')
storage_failure_config="$work/storage-failure.json"
sed 's/"virtual_ticks": 64/"virtual_ticks": 1/' \
    "$storage_bootstrap_config" > "$storage_failure_config"
chmod 500 "$storage_root"
if "$binary" --config "$storage_failure_config" --content-manifest "$manifest" --synthetic-producers \
    > "$work/storage-failure.out" 2>&1; then
    chmod 700 "$storage_root"
    echo "read-only save root unexpectedly committed" >&2
    exit 1
fi
chmod 700 "$storage_root"
grep -q 'HeadlessSaveCommitFailed' "$work/storage-failure.out"
storage_after=$(shasum -a 256 "$storage_root/world.isav" | awk '{print $1}')
test "$storage_before" = "$storage_after"
"$binary" --config "$storage_failure_config" --content-manifest "$manifest" --synthetic-producers \
    > "$work/storage-recovered.out" 2>&1
grep -q '"restored":true' "$work/storage-recovered.out"

# Losing stdout after commit is an observability degradation, not an authority
# failure or a skipped-save claim. The process exits successfully, reports the
# committed disposition on stderr when possible, and leaves a loadable slot.
closed_stdout_root="$work/closed-stdout-save"
closed_stdout_config="$work/closed-stdout.json"
sed "s#$storage_root#$closed_stdout_root#" \
    "$storage_failure_config" > "$closed_stdout_config"
if ! "$binary" --config "$closed_stdout_config" --content-manifest "$manifest" --synthetic-producers \
    1>&- 2> "$work/closed-stdout.err"; then
    echo "post-commit stdout loss incorrectly failed authority" >&2
    exit 1
fi
grep -q 'HEADLESS_EXIT status=degraded .* save=committed' "$work/closed-stdout.err"
test -f "$closed_stdout_root/world.isav"
"$binary" --config "$closed_stdout_config" --content-manifest "$manifest" --synthetic-producers \
    > "$work/closed-stdout-restore.out" 2>&1
grep -q '"restored":true' "$work/closed-stdout-restore.out"

# Bootstrap a crate exactly at a producer batch boundary. Real-time authority
# must then convert SIGTERM into ordered producer drain + durable save, and the
# same slot must restore in a fresh process.
signal_root="$work/signal-save"
signal_bootstrap_config="$work/signal-bootstrap.json"
sed \
    -e "s#/tmp/incinerator-headless-saves#$signal_root#" \
    -e 's/"virtual_ticks": 16384/"virtual_ticks": 64/' \
    "$example" > "$signal_bootstrap_config"
"$binary" --config "$signal_bootstrap_config" --content-manifest "$manifest" --synthetic-producers \
    > "$work/signal-bootstrap.out" 2>&1

signal_config="$work/signal.json"
sed \
    -e 's/"mode": "virtual"/"mode": "real_time"/' \
    "$signal_bootstrap_config" > "$signal_config"
signal_output="$work/signal.out"
"$binary" --config "$signal_config" --content-manifest "$manifest" --synthetic-producers \
    > "$signal_output" 2>&1 &
child_pid=$!

wait_for_ready "$signal_output" "SIGTERM real-time headless product"
sleep 0.05
kill -TERM "$child_pid"
wait "$child_pid"
child_pid=
grep -q '"stop_reason":"signal"' "$signal_output"
grep -Eq '"producer_submitted":\[[1-9][0-9]*,[1-9][0-9]*\]' "$signal_output"
grep -Eq '"producer_completed":\[[1-9][0-9]*,[1-9][0-9]*\]' "$signal_output"
test -f "$signal_root/world.isav"

signal_restore_config="$work/signal-restore.json"
sed \
    -e 's/"mode": "real_time"/"mode": "virtual"/' \
    -e 's/"virtual_ticks": 16384/"virtual_ticks": 1/' \
    "$signal_config" > "$signal_restore_config"
"$binary" --config "$signal_restore_config" --content-manifest "$manifest" --synthetic-producers \
    > "$work/signal-restore.out" 2>&1
grep -q '"restored":true' "$work/signal-restore.out"

# SIGINT is an equally healthy lifecycle request: accepted external work is
# drained, a new committed save is produced, and that save restores.
interrupt_root="$work/interrupt-save"
interrupt_bootstrap_config="$work/interrupt-bootstrap.json"
sed \
    -e "s#/tmp/incinerator-headless-saves#$interrupt_root#" \
    -e 's/"virtual_ticks": 16384/"virtual_ticks": 64/' \
    "$example" > "$interrupt_bootstrap_config"
"$binary" --config "$interrupt_bootstrap_config" --content-manifest "$manifest" --synthetic-producers \
    > "$work/interrupt-bootstrap.out" 2>&1

interrupt_config="$work/interrupt.json"
sed 's/"mode": "virtual"/"mode": "real_time"/' \
    "$interrupt_bootstrap_config" > "$interrupt_config"
interrupt_before=$(shasum -a 256 "$interrupt_root/world.isav" | awk '{print $1}')
interrupt_output="$work/interrupt.out"
"$binary" --config "$interrupt_config" --content-manifest "$manifest" --synthetic-producers \
    > "$interrupt_output" 2>&1 &
child_pid=$!
wait_for_ready "$interrupt_output" "SIGINT real-time headless product"
sleep 0.05
kill -INT "$child_pid"
wait "$child_pid"
child_pid=
grep -q '"stop_reason":"signal"' "$interrupt_output"
grep -Eq '"producer_submitted":\[[1-9][0-9]*,[1-9][0-9]*\]' "$interrupt_output"
grep -Eq '"producer_completed":\[[1-9][0-9]*,[1-9][0-9]*\]' "$interrupt_output"
interrupt_after=$(shasum -a 256 "$interrupt_root/world.isav" | awk '{print $1}')
test "$interrupt_before" != "$interrupt_after"

interrupt_restore_config="$work/interrupt-restore.json"
sed 's/"mode": "real_time"/"mode": "virtual"/' \
    "$interrupt_config" > "$interrupt_restore_config"
"$binary" --config "$interrupt_restore_config" --content-manifest "$manifest" --synthetic-producers \
    > "$work/interrupt-restore.out" 2>&1
grep -q '"restored":true' "$work/interrupt-restore.out"

# Hard lag is unhealthy. Start from an empty committed tick-63 world so the
# synthetic producers must spawn and complete an external relocation before
# suspension. After SIGCONT, the strict lag policy enters the common ordered
# drain path, returns the terminal lag error, and skips the final save.
hard_lag_root="$work/hard-lag-save"
hard_lag_bootstrap_config="$work/hard-lag-bootstrap.json"
sed \
    -e "s#/tmp/incinerator-headless-saves#$hard_lag_root#" \
    -e 's/"virtual_ticks": 16384/"virtual_ticks": 63/' \
    "$example" > "$hard_lag_bootstrap_config"
"$binary" --config "$hard_lag_bootstrap_config" --content-manifest "$manifest" \
    > "$work/hard-lag-bootstrap.out" 2>&1
hard_lag_before=$(shasum -a 256 "$hard_lag_root/world.isav" | awk '{print $1}')

hard_lag_config="$work/hard-lag.json"
sed \
    -e 's/"mode": "virtual"/"mode": "real_time"/' \
    -e 's/"hard_lag_ticks": 120/"hard_lag_ticks": 16/' \
    "$hard_lag_bootstrap_config" > "$hard_lag_config"
hard_lag_output="$work/hard-lag.out"
"$binary" --config "$hard_lag_config" --content-manifest "$manifest" --synthetic-producers \
    > "$hard_lag_output" 2>&1 &
child_pid=$!
wait_for_ready "$hard_lag_output" "hard-lag real-time headless product"
sleep 0.10
kill -STOP "$child_pid"
sleep 0.25
kill -CONT "$child_pid"
if wait "$child_pid"; then
    child_pid=
    echo "hard-lag headless product unexpectedly exited successfully" >&2
    exit 1
fi
child_pid=

grep -q '^HEADLESS_READY restored=true world_tick=63 clock=real_time' "$hard_lag_output"
grep -q 'HEADLESS_EXIT status=fault error=HeadlessHardLagLimit save=skipped' "$hard_lag_output"
grep -q '^HEADLESS_DIAGNOSTICS_JSON ' "$hard_lag_output"
grep -Eq '"tick_index":(6[5-9]|[7-9][0-9]|[1-9][0-9]{2,})' "$hard_lag_output"
grep -q '"crates":{"active_count":1' "$hard_lag_output"
if grep -Eq 'HeadlessProducerDrainTimeout|HeadlessProducerShutdownInvariant|HeadlessSyntheticCompletionCountMismatch' \
    "$hard_lag_output"; then
    echo "hard-lag shutdown did not drain accepted producer work" >&2
    exit 1
fi
hard_lag_after=$(shasum -a 256 "$hard_lag_root/world.isav" | awk '{print $1}')
test "$hard_lag_before" = "$hard_lag_after"

echo "M3 headless startup, restart, recovery, bounded admission, SIGTERM/SIGINT, and hard-lag lifecycle verified"
