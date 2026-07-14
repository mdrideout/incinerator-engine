#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: verify_mp6_listen_process.sh <graphical-listen-host> <graphical-guest>" >&2
    exit 2
fi

host=$1
guest=$2
port=$((36000 + ($$ % 18000)))
run_dir=$(mktemp -d "${TMPDIR:-/tmp}/incinerator-mp6-listen.XXXXXX")
host_log="$run_dir/host.log"
guest_log="$run_dir/guest.log"
rejected_log="$run_dir/rejected.log"
ticket="$run_dir/guest.room"
host_pid=
guest_pid=
rejected_pid=

cleanup() {
    status=$?
    if [[ $status -ne 0 ]]; then
        [[ -f "$host_log" ]] && cat "$host_log" >&2
        [[ -f "$guest_log" ]] && cat "$guest_log" >&2
        [[ -f "$rejected_log" ]] && cat "$rejected_log" >&2
    fi
    [[ -n "$guest_pid" ]] && kill "$guest_pid" 2>/dev/null || true
    [[ -n "$rejected_pid" ]] && kill "$rejected_pid" 2>/dev/null || true
    [[ -n "$host_pid" ]] && kill "$host_pid" 2>/dev/null || true
    rm -rf "$run_dir"
    exit $status
}
trap cleanup EXIT

"$host" \
    --port "$port" \
    --ticket "$ticket" \
    --max-frames 4800 \
    --smoke-actions >"$host_log" 2>&1 &
host_pid=$!

for _ in {1..200}; do
    if grep -q '^MP6_LISTEN_READY ' "$host_log" 2>/dev/null; then
        break
    fi
    if ! kill -0 "$host_pid" 2>/dev/null; then
        cat "$host_log" >&2
        exit 1
    fi
    sleep 0.025
done

grep -q "^MP6_LISTEN_READY endpoint=127.0.0.1:$port host=1 guest=2" "$host_log"
test -f "$ticket"

"$guest" \
    --connect "127.0.0.1:$port" \
    --account 999 \
    --max-frames 600 >"$rejected_log" 2>&1 &
rejected_pid=$!
wait "$rejected_pid"
rejected_pid=
grep -q '^MP2_CLIENT_REJECTED reason=unauthorized$' "$rejected_log"
kill -0 "$host_pid"

"$guest" \
    --ticket "$ticket" \
    --max-frames 4200 \
    --smoke-actions >"$guest_log" 2>&1 &
guest_pid=$!

wait "$guest_pid"
guest_pid=
wait "$host_pid"
host_pid=

grep -q '^MP6_LISTEN_GUEST_JOINED account=2$' "$host_log"
grep -q '^MP6_LISTEN_HOST_CARRY action=collect result=collected$' "$host_log"
grep -q '^MP6_LISTEN_HOST_CARRY action=drop result=dropped$' "$host_log"
grep -q '^MP6_LISTEN_HOST_VEHICLE action=enter result=entered$' "$host_log"
grep -q '^MP6_LISTEN_HOST_VEHICLE action=exit result=exited$' "$host_log"
grep -q '^MP6_LISTEN_HOST_SMOKE_PASS walk=true drive=true carry=true ' "$host_log"
grep -q '^MP6_LISTEN_CLOSED .* host_migration=false$' "$host_log"

grep -q "^MP6_CLIENT_CONNECT endpoint=127.0.0.1:$port account=2 ticketed=true" "$guest_log"
test "$(grep -c '^MP2_CLIENT_JOINED participant=2:1 ' "$guest_log")" -eq 2
grep -q '^MP4_BASELINE id=2 ' "$guest_log"
grep -q '^MP4_INTERACTION_ACTION action=collect result=collected ' "$guest_log"
grep -q '^MP4_INTERACTION_ACTION action=drop result=dropped ' "$guest_log"
grep -q '^MP4_VEHICLE_ACTION action=enter result=entered ' "$guest_log"
grep -q '^MP4_VEHICLE_ACTION action=exit result=exited ' "$guest_log"
grep -q '^MP6_CLIENT_SMOKE_PASS account=2 walk=true drive=true carry=true reconnect=true ' "$guest_log"

if grep -Eiq 'admission_secret|reconnect_token|join_authorization|error:' \
    "$host_log" "$guest_log" "$rejected_log"; then
    echo "MP6 listen logs exposed private material or an error" >&2
    exit 1
fi

echo "MP6_LISTEN_PROCESS_PASS graphical=2 host_local_link=true guest_real_gns=true walk=true drive=true carry=true reconnect=true host_migration=false"
