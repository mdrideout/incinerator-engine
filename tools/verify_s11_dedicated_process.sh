#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: verify_s11_dedicated_process.sh <room-server> <graphical-client>" >&2
    exit 2
fi

server=$1
client=$2
port=$((32000 + ($$ % 19000)))
run_dir=$(mktemp -d "${TMPDIR:-/tmp}/incinerator-s11-dedicated.XXXXXX")
server_log="$run_dir/server.log"
attacker_log="$run_dir/attacker.log"
observer_log="$run_dir/observer.log"
server_pid=
attacker_pid=
observer_pid=
scenario_deadline_ticks=4800

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

"$server" --port "$port" --max-ticks "$scenario_deadline_ticks" --ticket-dir "$run_dir/tickets" \
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

"$client" --ticket "$run_dir/tickets/account-1.room" --max-frames 30000 --s11-attacker \
    >"$attacker_log" 2>&1 &
attacker_pid=$!
"$client" --ticket "$run_dir/tickets/account-2.room" --max-frames 30000 --s11-observer \
    >"$observer_log" 2>&1 &
observer_pid=$!

wait "$attacker_pid"
attacker_pid=
wait "$observer_pid"
observer_pid=
wait "$server_pid"
server_pid=

grep -q '^S11_CLIENT_NPC_DEATH ' "$attacker_log"
grep -q '^S11_SCENARIO_ADAPTER topology=dedicated role=attacker scenario=hostile_npc_approach_contact_death_respawn seed=5111 deadline_ticks=4800$' "$attacker_log"
grep -q '^S11_SCENARIO_ADAPTER topology=dedicated role=observer scenario=hostile_npc_approach_contact_death_respawn seed=5111 deadline_ticks=4800$' "$observer_log"
grep -q '^S11_CLIENT_REPLACEMENT ' "$attacker_log"
grep -q '^S11_CLIENT_PASS role=attacker npc_death=true replacement=true$' "$attacker_log"
grep -q '^S11_CLIENT_NPC_DEATH ' "$observer_log"
grep -q '^S11_CLIENT_REPLACEMENT ' "$observer_log"
grep -q '^S11_CLIENT_PASS role=observer npc_death=true replacement=true$' "$observer_log"

if grep -Eiq 'admission_secret|reconnect_token|join_authorization|error:' \
    "$server_log" "$attacker_log" "$observer_log"; then
    echo "S11 dedicated logs exposed private material or an error" >&2
    exit 1
fi

echo "S11_DEDICATED_PROCESS_PASS graphical=2 real_gns=true shared_scenario=true npc_damage=true npc_death=true replacement=true"
