#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"

if rg -n '(@import\([^)]*(zflecs|jolt_physics|sandbox_simulation)|engine\.PersistentId|JPH_)' \
  "$root/src/session/protocol.zig" \
  "$root/src/session/client.zig" \
  "$root/src/session/replicated_world.zig"; then
  echo "MP4 architecture failure: backend types leaked into the wire/client boundary" >&2
  exit 1
fi

if rg -n -i '(@import\([^)]*steam|@cInclude\([^)]*steam|steam_api)' "$root/src/session"; then
  echo "MP4 architecture failure: proprietary service dependency leaked into session core" >&2
  exit 1
fi

for required in \
  max_relevant_entities_per_client \
  max_baseline_bytes_per_client \
  average_client_down_bytes_per_second \
  snapshot_history_capacity; do
  rg -q "pub const ${required}" "$root/src/session/budgets.zig"
done

echo "MP4_ARCHITECTURE_PASS semantic_projection=clean steam_core=absent budgets=declared"
