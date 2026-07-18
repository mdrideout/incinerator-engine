#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: verify_s11_listen_process.sh <graphical-listen-host> <graphical-guest>" >&2
    exit 2
fi

host=$1
guest=$2
port=$((37000 + ($$ % 17000)))
run_dir=$(mktemp -d "${TMPDIR:-/tmp}/incinerator-s11-listen.XXXXXX")
host_log="$run_dir/host.log"
guest_log="$run_dir/guest.log"
ticket="$run_dir/guest.room"
host_pid=
guest_pid=

cleanup() {
    status=$?
    if [[ $status -ne 0 ]]; then
        [[ -f "$host_log" ]] && cat "$host_log" >&2
        [[ -f "$guest_log" ]] && cat "$guest_log" >&2
    fi
    [[ -n "$guest_pid" ]] && kill "$guest_pid" 2>/dev/null || true
    [[ -n "$host_pid" ]] && kill "$host_pid" 2>/dev/null || true
    rm -rf "$run_dir"
    exit $status
}
trap cleanup EXIT

"$host" --port "$port" --ticket "$ticket" --max-frames 20000 --s11-observer \
    >"$host_log" 2>&1 &
host_pid=$!
for _ in {1..240}; do
    grep -q '^MP6_LISTEN_READY ' "$host_log" 2>/dev/null && break
    if ! kill -0 "$host_pid" 2>/dev/null; then
        cat "$host_log" >&2
        exit 1
    fi
    sleep 0.025
done
grep -q "^MP6_LISTEN_READY endpoint=127.0.0.1:$port " "$host_log"
test -f "$ticket"

"$guest" --ticket "$ticket" --max-frames 20000 --s11-attacker --s11-listen \
    >"$guest_log" 2>&1 &
guest_pid=$!
wait "$guest_pid"
guest_pid=
wait "$host_pid"
host_pid=

grep -q '^S11_CLIENT_NPC_DEATH ' "$guest_log"
grep -q '^S11_SCENARIO_ADAPTER topology=listen role=observer scenario=hostile_npc_approach_contact_death_respawn seed=5111 deadline_ticks=4800$' "$host_log"
grep -q '^S11_SCENARIO_ADAPTER topology=listen role=attacker scenario=hostile_npc_approach_contact_death_respawn seed=5111 deadline_ticks=4800$' "$guest_log"
grep -q '^S11_CLIENT_REPLACEMENT ' "$guest_log"
grep -q '^S11_CLIENT_PASS role=attacker npc_death=true replacement=true$' "$guest_log"
grep -q '^S11_LISTEN_OBSERVER_DEATH ' "$host_log"
grep -q '^S11_LISTEN_OBSERVER_REPLACEMENT ' "$host_log"
grep -q '^S11_LISTEN_OBSERVER_PASS npc_death=true replacement=true$' "$host_log"

if grep -Eiq 'admission_secret|reconnect_token|join_authorization|error:' \
    "$host_log" "$guest_log"; then
    echo "S11 listen logs exposed private material or an error" >&2
    exit 1
fi

echo "S11_LISTEN_PROCESS_PASS graphical=2 host_local_link=true guest_real_gns=true shared_scenario=true npc_damage=true npc_death=true replacement=true"
