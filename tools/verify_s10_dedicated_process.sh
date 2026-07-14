#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: verify_s10_dedicated_process.sh <room-server> <graphical-client>" >&2
    exit 2
fi

server=$1
client=$2
port=$((32000 + ($$ % 19000)))
run_dir=$(mktemp -d "${TMPDIR:-/tmp}/incinerator-s10-dedicated.XXXXXX")
server_log="$run_dir/server.log"
attacker_log="$run_dir/attacker.log"
victim_log="$run_dir/victim.log"
server_pid=
attacker_pid=
victim_pid=

cleanup() {
    status=$?
    if [[ $status -ne 0 ]]; then
        [[ -f "$server_log" ]] && cat "$server_log" >&2
        [[ -f "$attacker_log" ]] && cat "$attacker_log" >&2
        [[ -f "$victim_log" ]] && cat "$victim_log" >&2
    fi
    [[ -n "$attacker_pid" ]] && kill "$attacker_pid" 2>/dev/null || true
    [[ -n "$victim_pid" ]] && kill "$victim_pid" 2>/dev/null || true
    [[ -n "$server_pid" ]] && kill "$server_pid" 2>/dev/null || true
    rm -rf "$run_dir"
    exit $status
}
trap cleanup EXIT

"$server" --port "$port" --max-ticks 520 --ticket-dir "$run_dir/tickets" \
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

"$client" --ticket "$run_dir/tickets/account-1.room" --max-frames 8500 --s10-attacker \
    >"$attacker_log" 2>&1 &
attacker_pid=$!
"$client" --ticket "$run_dir/tickets/account-2.room" --max-frames 8500 --s10-victim \
    >"$victim_log" 2>&1 &
victim_pid=$!

wait "$attacker_pid"
attacker_pid=
wait "$victim_pid"
victim_pid=
wait "$server_pid"
server_pid=

grep -q '^S10_CLIENT_MELEE result=hit damage=34 health=66 killed=false$' "$attacker_log"
grep -q '^S10_CLIENT_MELEE result=hit damage=34 health=32 killed=false$' "$attacker_log"
grep -q '^S10_CLIENT_MELEE result=hit damage=32 health=0 killed=true$' "$attacker_log"
grep -q '^S10_CLIENT_ATTACKER_PASS hits=3 life_events=2$' "$attacker_log"
grep -q '^S10_CLIENT_LIFE .* state=dead health=0$' "$victim_log"
grep -q '^S10_CLIENT_RESPAWN result=respawned ' "$victim_log"
grep -q '^S10_CLIENT_VICTIM_PASS respawns=1 ' "$victim_log"

if grep -Eiq 'admission_secret|reconnect_token|join_authorization|error:' \
    "$server_log" "$attacker_log" "$victim_log"; then
    echo "S10 dedicated logs exposed private material or an error" >&2
    exit 1
fi

echo "S10_DEDICATED_PROCESS_PASS graphical=2 real_gns=true damage=true death=true respawn=true"
