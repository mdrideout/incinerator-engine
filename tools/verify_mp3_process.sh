#!/usr/bin/env bash

set -euo pipefail

server=$1
client=$2
tmp=$(mktemp -d)
server_pid=

cleanup() {
  if [[ -n "$server_pid" ]]; then
    kill "$server_pid" 2>/dev/null || true
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT

"$server" --port 29733 --max-ticks 180 >"$tmp/server.log" 2>&1 &
server_pid=$!
sleep 0.25
"$client" 127.0.0.1:29733 >"$tmp/client.log" 2>&1
wait "$server_pid"
server_pid=

grep -Fq 'MP2_SERVER_STOP tick=180' "$tmp/server.log"
grep -Fq 'MP3_SHUTDOWN_CLIENT_PASS joined=true' "$tmp/client.log"
echo "MP3_PROCESS_PASS authority_stop=delivered reconnect_loop=false"
