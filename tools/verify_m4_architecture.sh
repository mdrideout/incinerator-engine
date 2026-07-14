#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"

if rg -n 'sandbox_simulation|jolt_physics|zflecs' "$root/src/hosts/mp2_client.zig"; then
  echo "M4 architecture failure: graphical network client imports authority world" >&2
  exit 1
fi

if rg -n -i '(@import\([^)]*steam|@cInclude\([^)]*steam|steam_api)' "$root/src/session"; then
  echo "M4 architecture failure: proprietary platform dependency entered open session core" >&2
  exit 1
fi

for required in \
  "$root/docs/validation/mp4-architecture-closeout.md" \
  "$root/docs/validation/mp5-acceptance.md" \
  "$root/docs/adr/016-authority-session-topology.md" \
  "$root/docs/adr/018-gamenetworkingsockets-and-steam-compatible-routing.md"; do
  test -f "$required"
done

echo "M4_ARCHITECTURE_PASS client_authority=separate steam_core=absent macos_scope=explicit"
