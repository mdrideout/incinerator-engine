#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: verify_mp6_process.sh <room-server> <graphical-client>" >&2
    exit 2
fi

server=$1
client=$2
port=$((31000 + ($$ % 20000)))
run_dir=$(mktemp -d "${TMPDIR:-/tmp}/incinerator-mp6-process.XXXXXX")
server_log="$run_dir/server.log"
client_one_log="$run_dir/client-one.log"
client_two_log="$run_dir/client-two.log"
server_pid=
client_one_pid=
client_two_pid=

cleanup() {
    status=$?
    if [[ $status -ne 0 ]]; then
        [[ -f "$server_log" ]] && cat "$server_log" >&2
        [[ -f "$client_one_log" ]] && cat "$client_one_log" >&2
        [[ -f "$client_two_log" ]] && cat "$client_two_log" >&2
    fi
    [[ -n "$client_one_pid" ]] && kill "$client_one_pid" 2>/dev/null || true
    [[ -n "$client_two_pid" ]] && kill "$client_two_pid" 2>/dev/null || true
    [[ -n "$server_pid" ]] && kill "$server_pid" 2>/dev/null || true
    rm -rf "$run_dir"
    exit $status
}
trap cleanup EXIT

"$server" \
    --port "$port" \
    --max-ticks 360 \
    --ticket-dir "$run_dir/tickets" >"$server_log" 2>&1 &
server_pid=$!

for _ in {1..200}; do
    if grep -q '^MP6_SERVER_READY ' "$server_log" 2>/dev/null; then
        break
    fi
    if ! kill -0 "$server_pid" 2>/dev/null; then
        cat "$server_log" >&2
        exit 1
    fi
    sleep 0.025
done

grep -q '^MP6_SERVER_READY ' "$server_log"
test -f "$run_dir/tickets/account-1.room"
test -f "$run_dir/tickets/account-2.room"

"$client" \
    --ticket "$run_dir/tickets/account-1.room" \
    --max-frames 900 >"$client_one_log" 2>&1 &
client_one_pid=$!
"$client" \
    --ticket "$run_dir/tickets/account-2.room" \
    --max-frames 900 >"$client_two_log" 2>&1 &
client_two_pid=$!

wait "$client_one_pid"
client_one_pid=
wait "$client_two_pid"
client_two_pid=
wait "$server_pid"
server_pid=

grep -q "^MP6_CLIENT_CONNECT endpoint=127.0.0.1:$port account=1 ticketed=true" "$client_one_log"
grep -q '^MP2_CLIENT_JOINED ' "$client_one_log"
grep -q '^MP4_BASELINE ' "$client_one_log"
grep -q "^MP6_CLIENT_CONNECT endpoint=127.0.0.1:$port account=2 ticketed=true" "$client_two_log"
grep -q '^MP2_CLIENT_JOINED ' "$client_two_log"
grep -q '^MP4_BASELINE ' "$client_two_log"
grep -q '^MP6_SERVER_CLOSED .* participants=2 host_migration=false$' "$server_log"

if grep -Eiq 'admission_secret|reconnect_token|join_authorization|error:' \
    "$server_log" "$client_one_log" "$client_two_log"; then
    echo "MP6 process logs exposed private material or an error" >&2
    exit 1
fi

echo "MP6_DEDICATED_PROCESS_PASS clients=2 ticketed=true real_gns=true graphical=true host_migration=false"
