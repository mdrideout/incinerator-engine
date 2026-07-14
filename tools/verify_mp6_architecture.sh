#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
coordinator="$root/src/session/room_coordinator.zig"
ticket="$root/src/session/room_ticket.zig"
socket_client="$root/src/hosts/mp2_client.zig"
listen_runtime="$root/src/hosts/mp6_listen_room.zig"
listen_client="$root/src/hosts/mp6_listen_client.zig"
dedicated_server="$root/src/hosts/mp6_server.zig"
scene="$root/src/client_scene.zig"

fail() {
    echo "MP6 architecture failure: $*" >&2
    exit 1
}

require() {
    local description=$1
    local pattern=$2
    local source=$3
    rg -U -q -- "$pattern" "$source" || fail "$description"
}

reject() {
    local description=$1
    local pattern=$2
    shift 2
    if rg -n --glob '*.zig' -- "$pattern" "$@"; then
        fail "$description"
    fi
}

for source in \
    "$coordinator" \
    "$ticket" \
    "$socket_client" \
    "$listen_runtime" \
    "$listen_client" \
    "$dedicated_server" \
    "$scene"; do
    test -f "$source" || fail "required source is missing: ${source#"$root/"}"
done

require "room coordinator has no nonzero generation gate" \
    'fn accepts[\s\S]*generation != 0[\s\S]*stale_completions' "$coordinator"
require "room coordinator does not separate lobby departure from network loss" \
    'pub fn lobbyDeparted[\s\S]*pub fn replaceMemberPresentation' "$coordinator"
require "room coordinator lacks bounded reconnect state" \
    'pub fn networkLost[\s\S]*reconnecting[\s\S]*reconnect_attempt' "$coordinator"
require "room coordinator does not expose a sanitized presentation value" \
    'pub const View = struct[\s\S]*stale_completions' "$coordinator"
reject "private connection material is publicly retrievable from the coordinator" \
    'pub const ConnectionPlan|pub fn connectionPlan' "$coordinator"

view_surface=$(sed -n '/^pub const View = struct {/,/^};/p' "$coordinator")
test -n "$view_surface" || fail "could not identify the room View surface"
if rg -n -- 'authorization|secret|reconnect|credential|provider_token' <<<"$view_surface" | \
    rg -v -- 'reconnect_attempt'; then
    fail "room presentation View exposes private connection material"
fi

require "ticket codec is not explicitly bounded" \
    'pub const maximum_bytes[\s\S]*512' "$ticket"
require "ticket artifact does not validate identity-bound signed authorization" \
    'fn validate\([\s\S]*authorization\.room_id[\s\S]*authorization\.authority_id[\s\S]*authorization\.authenticator' \
    "$ticket"
reject "ticket artifact persists an admission secret" \
    'AdmissionSecret|admission_secret|\.secret' "$ticket"

require "listen runtime does not own the embedded authority" \
    '@import\("session_authority"\)' "$listen_runtime"
require "listen runtime does not use the typed local host link" \
    '@import\("session_local_link"\)' "$listen_runtime"
require "listen runtime does not expose a real GNS guest listener" \
    '@import\("gns_direct"\)' "$listen_runtime"
require "listen runtime does not route host presentation through a protocol client" \
    'client: session_client\.Client' "$listen_runtime"
require "listen close does not drain registry and coordinator" \
    'pub fn close[\s\S]*beginDrain[\s\S]*registry\.close[\s\S]*coordinator\.closed' \
    "$listen_runtime"

reject "graphical listen host imports authority, registry, or transport directly" \
    '@import\("(session_authority|session_room|gns_direct|session_local_link)"\)' \
    "$listen_client"
require "graphical listen host does not consume the listen composition" \
    '@import\("mp6_listen_room"\)' "$listen_client"
require "graphical clients do not share the client-owned scene presenter" \
    '@import\("client_scene"\)' "$socket_client"
require "graphical listen host does not share the client-owned scene presenter" \
    '@import\("client_scene"\)' "$listen_client"
reject "shared client scene imports authority, transport, registry, or persistence" \
    '@import\("(session_authority|gns_direct|session_room|sandbox_persistence|save_slots)"\)' \
    "$scene"

reject "remote graphical socket client imports simulation or authority implementation" \
    '@import\("(session_authority|sandbox_simulation|simulation_snapshot|jolt_physics|zflecs)"\)' \
    "$socket_client"
require "remote graphical socket client bypasses the room coordinator" \
    '@import\("room_coordinator"\)' "$socket_client"
require "remote graphical socket client bypasses bounded room artifacts" \
    '@import\("room_ticket"\)' "$socket_client"

require "dedicated room server does not use CSPRNG admission material" \
    'arc4random_buf' "$dedicated_server"
require "dedicated room tickets are not atomically permission-restricted" \
    'createFileAtomic[\s\S]*0o600' "$dedicated_server"
require "listen room tickets are not atomically permission-restricted" \
    'createFileAtomic[\s\S]*0o600' "$listen_runtime"

reject "MP6 open-engine source directly imports Steamworks" \
    '@import\(".*steam|#include[[:space:]]*[<"].*steam' \
    "$coordinator" "$ticket" "$socket_client" "$listen_runtime" \
    "$listen_client" "$dedicated_server" "$scene"

echo "MP6_ARCHITECTURE_PASS coordinator=generation_safe view=sanitized host=typed_local guest=real_gns dedicated=ticketed presentation=client_owned steamworks=absent"
