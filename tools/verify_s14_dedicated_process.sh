#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: verify_s14_dedicated_process.sh <room-server> <graphical-client>" >&2
    exit 2
fi

server=$1
client=$2
port=$((32000 + ($$ % 19000)))
run_dir=$(mktemp -d "${TMPDIR:-/tmp}/incinerator-s14-dedicated.XXXXXX")
server_log="$run_dir/server.log"
attacker_log="$run_dir/attacker.log"
observer_log="$run_dir/observer.log"
server_pid=
attacker_pid=
observer_pid=

cleanup() {
    status=$?
    if [[ $status -ne 0 ]]; then
        [[ -f "$server_log" ]] && cat "$server_log" >&2
        [[ -f "$attacker_log" ]] && cat "$attacker_log" >&2
        [[ -f "$observer_log" ]] && cat "$observer_log" >&2
    fi
    [[ -n "$attacker_pid" ]] && kill "$attacker_pid" 2>/dev/null || true
    [[ -n "$observer_pid" ]] && kill "$observer_pid" 2>/dev/null || true
    [[ -n "$server_pid" ]] && kill "$server_pid" 2>/dev/null || true
    rm -rf "$run_dir"
    exit $status
}
trap cleanup EXIT

"$server" --port "$port" --max-ticks 1400 --ticket-dir "$run_dir/tickets" \
    >"$server_log" 2>&1 &
server_pid=$!
for _ in {1..240}; do
    grep -q '^MP6_SERVER_READY ' "$server_log" 2>/dev/null && break
    if ! kill -0 "$server_pid" 2>/dev/null; then
        cat "$server_log" >&2
        exit 1
    fi
    sleep 0.025
done
test -f "$run_dir/tickets/account-1.room"
test -f "$run_dir/tickets/account-2.room"

"$client" --ticket "$run_dir/tickets/account-1.room" --max-frames 30000 --s14-attacker \
    >"$attacker_log" 2>&1 &
attacker_pid=$!
"$client" --ticket "$run_dir/tickets/account-2.room" --max-frames 30000 --s14-observer \
    >"$observer_log" 2>&1 &
observer_pid=$!

wait "$attacker_pid"
attacker_pid=
wait "$observer_pid"
observer_pid=
wait "$server_pid"
server_pid=

grep -q '^S14_SCENARIO_ADAPTER topology=dedicated role=attacker ' "$attacker_log"
grep -q '^S14_SCENARIO_ADAPTER topology=dedicated role=observer ' "$observer_log"
grep -q '^S14_CLIENT_SHOT ' "$attacker_log"
grep -q '^S14_CLIENT_SHOT ' "$observer_log"
grep -Eq '^S14_CLIENT_PASS role=attacker hits=[4-9][0-9]* killed=true shot=true npc_death=true replacement=true$' "$attacker_log"
grep -q '^S14_CLIENT_PASS role=observer hits=0 killed=false shot=true npc_death=true replacement=true$' "$observer_log"

if grep -Eiq 'admission_secret|reconnect_token|join_authorization|error:' \
    "$server_log" "$attacker_log" "$observer_log"; then
    echo "S14 dedicated logs exposed private material or an error" >&2
    exit 1
fi

echo "S14_DEDICATED_PROCESS_PASS graphical=2 real_gns=true authority_hitscan=true observer_shot=true npc_death=true replacement=true"
