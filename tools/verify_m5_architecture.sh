#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"

fail() {
  echo "M5 architecture failure: $*" >&2
  exit 1
}

reject_matches() {
  local description="$1"
  local pattern="$2"
  shift 2

  local matches=""
  local status=0
  matches="$(rg -n -i --glob '*.zig' -- "$pattern" "$@")" || status=$?
  case "$status" in
    0)
      printf '%s\n' "$matches" >&2
      fail "$description"
      ;;
    1) ;;
    *) fail "source scan failed while checking: $description" ;;
  esac
}

require_match() {
  local description="$1"
  local pattern="$2"
  local source="$3"

  local status=0
  rg -U -q -- "$pattern" "$source" || status=$?
  case "$status" in
    0) ;;
    1) fail "$description" ;;
    *) fail "source scan failed while checking: $description" ;;
  esac
}

main_source="$root/src/main.zig"
local_solo_source="$root/src/session/local_solo.zig"
mp2_client_source="$root/src/hosts/mp2_client.zig"
mp2_server_source="$root/src/hosts/mp2_server.zig"
developer_host_source="$root/src/hosts/sandbox_developer_host.zig"
authority_diagnostics_source="$root/src/session/authority_diagnostics.zig"
district_streaming_host_source="$root/src/hosts/district_streaming_host.zig"
snapshot_source="$root/src/session/snapshot_source.zig"

for required_source in \
  "$main_source" \
  "$local_solo_source" \
  "$mp2_client_source" \
  "$mp2_server_source" \
  "$developer_host_source" \
  "$authority_diagnostics_source" \
  "$district_streaming_host_source" \
  "$snapshot_source"; do
  test -f "$required_source" || fail "required source is missing: ${required_source#"$root/"}"
done

# Graphical products may compose a session/client role, but may not import the
# authority implementation or physics backend directly.
graphical_roots=(
  "$main_source"
  "$mp2_client_source"
  "$root/src/mp2_presentation.zig"
)
reject_matches \
  "a graphical product imports simulation authority or a physics backend directly" \
  '@import[[:space:]]*\([[:space:]]*"([^"/]*/)*(sandbox_simulation|simulation_snapshot|simulation|session_authority|authority|jolt_physics|jolt_c|zflecs)(\.zig)?"' \
  "${graphical_roots[@]}"
require_match \
  "the solo graphical host no longer composes local_solo_session" \
  '@import\("local_solo_session"\)' \
  "$main_source"

# Developer UI, profiling, diagnostics, and optional physics-debug resources
# are one heap-stable opaque host owner. App retains orchestration and borrows
# only typed authority/streaming ports; it must not grow those state lanes back.
require_match \
  "the graphical host does not compose the sandbox developer owner" \
  '@import\("hosts/sandbox_developer_host\.zig"\)' \
  "$main_source"
require_match \
  "App does not own the opaque developer owner allocation" \
  'developer:[[:space:]]*\*sandbox_developer_host\.Owner' \
  "$main_source"
require_match \
  "sandbox developer ownership is not opaque" \
  'pub const Owner[[:space:]]*=[[:space:]]*opaque' \
  "$developer_host_source"
reject_matches \
  "developer state leaked back into App" \
  'developer_(editor|controller|control_requests|diagnostic_requests|visualization_requests|profiler|active_frame_profile|physics_debug_cpu|physics_debug_overlay|physics_debug_frame_counter)' \
  "$main_source"
reject_matches \
  "the developer owner imports mutable authority or persistence implementations" \
  '@import\("(local_solo_session|session_authority|sandbox_simulation|simulation_snapshot|sandbox_persistence|sandbox_authoring|sandbox_interaction)"\)' \
  "$developer_host_source"
require_match \
  "the canonical authority diagnostics contract is not wired into the developer owner" \
  '@import\("session_authority_diagnostics"\)' \
  "$developer_host_source"

developer_owner_sources=(
  "$developer_host_source"
  "$root/src/hosts/developer_controls.zig"
  "$root/src/hosts/developer_diagnostics.zig"
  "$root/src/hosts/developer_profile.zig"
  "$root/src/hosts/developer_visualization.zig"
  "$authority_diagnostics_source"
)
for developer_owner_source in "${developer_owner_sources[@]}"; do
  test -f "$developer_owner_source" ||
    fail "developer-owner closure source is missing: ${developer_owner_source#"$root/"}"
done
reject_matches \
  "the developer-owner closure imports mutable authority, persistence, physics, or private feature implementations" \
  '@import[[:space:]]*\([[:space:]]*"([^"/]*/)*(local_solo_session|session_authority|sandbox_simulation|simulation_snapshot|sandbox_persistence|sandbox_authoring|sandbox_interaction|save_slots|jolt_physics|jolt_c|zflecs|crate_feature|character_feature|vehicle_feature|district_feature|interaction_feature|npc_feature)(\.zig)?"' \
  "${developer_owner_sources[@]}"
reject_matches \
  "session authority republishes compatibility diagnostics aliases" \
  '^[[:space:]]*pub const (AuthorityCycleStage|AuthorityCycleFault|AuthorityCycleTrace|Diagnostics)[[:space:]]*=' \
  "$root/src/session/authority.zig"
require_match \
  "the solo graphical host no longer composes its DTO-only authority boundary" \
  '@import\("sandbox_host_contracts"\)' \
  "$main_source"
require_match \
  "the multiplayer graphical host no longer composes the session client" \
  '@import\("session_client"\)' \
  "$mp2_client_source"
require_match \
  "the multiplayer graphical host no longer composes its presentation boundary" \
  '@import\("mp2_presentation"\)' \
  "$mp2_client_source"

# Placement is a composition root. Its only public operations are lifecycle
# construction and explicit role acquisition; mutations belong to those roles.
placement_public_methods="$({
  sed -n '/^pub const Placement = opaque {/,/^};/p' \
    "$local_solo_source" |
    sed -nE 's/^[[:space:]]*pub fn ([A-Za-z_][A-Za-z0-9_]*).*/\1/p'
})"
test -n "$placement_public_methods" || fail "could not identify the Placement public surface"

for method in $placement_public_methods; do
  case "$method" in
    initComposition|initCompositionWithDiagnosticFaultProbe|deinit|player|presentation|lifecycle|crates|characters|vehicles|districts|interactions|npcs|developer|inspection|residency) ;;
    *) fail "Placement exposes a flat public operation: $method" ;;
  esac
done

for required_lifecycle in \
  initComposition initCompositionWithDiagnosticFaultProbe deinit; do
  rg -qx -- "$required_lifecycle" <<<"$placement_public_methods" ||
    fail "Placement is missing the $required_lifecycle lifecycle operation"
done

for required_role in \
  player presentation lifecycle crates characters vehicles districts interactions npcs \
  developer inspection residency; do
  rg -qx -- "$required_role" <<<"$placement_public_methods" ||
    fail "Placement is missing the $required_role role accessor"
done

reject_matches \
  "local_solo republishes the concrete simulation namespace" \
  '^[[:space:]]*pub const [A-Za-z_][A-Za-z0-9_]*[[:space:]]*=[[:space:]]*sandbox\.' \
  "$local_solo_source"
reject_matches \
  "a public local-session handle exposes typed state or an owning Placement" \
  '^[[:space:]]*(state:[[:space:]]*\*State|owner:[[:space:]]*\*Placement)' \
  "$local_solo_source"
require_match \
  "Placement is not opaque at its public boundary" \
  'pub const Placement[[:space:]]*=[[:space:]]*opaque' \
  "$local_solo_source"

# Player-facing protocol requests and privileged local administration are
# distinct capabilities. Admin unions are deliberately closed to spawn/despawn;
# they may not become an alternate path for ordinary gameplay actions.
for admin_command in \
  CharacterAdminCommand VehicleAdminCommand InteractionAdminCommand; do
  admin_surface="$({
    sed -n "/^pub const ${admin_command} = union(enum) {/,/^};/p" \
      "$local_solo_source"
  })"
  test -n "$admin_surface" || fail "could not identify $admin_command"
  admin_tags="$({
    sed -nE 's/^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*):.*/\1/p' \
      <<<"$admin_surface"
  })"
  test -n "$admin_tags" || fail "$admin_command exposes no typed operations"
  for admin_tag in $admin_tags; do
    case "$admin_tag" in
      spawn|despawn) ;;
      *) fail "$admin_command admits player-facing operation: $admin_tag" ;;
    esac
  done
  for required_admin_tag in spawn despawn; do
    rg -qx -- "$required_admin_tag" <<<"$admin_tags" ||
      fail "$admin_command is missing $required_admin_tag"
  done
done

# Replicated client draw DTOs use session identity only. Presentation is built
# from replicated-world/prediction state and may not inspect authority state to
# recover durable identity or presentation values.
client_draw_surfaces="$({
  sed -n '/^pub const CharacterDraw = struct {/,/^pub const TickStage = enum {/p' \
    "$local_solo_source"
})"
test -n "$client_draw_surfaces" || fail "could not identify client draw DTOs"
if rg -n -- '^[[:space:]]*persistent_id[[:space:]]*:' \
  <<<"$client_draw_surfaces"; then
  fail "a client draw DTO exposes durable authority identity"
fi
client_presentation_surface="$({
  sed -n '/^[[:space:]]*fn characterPresentation(/,/^[[:space:]]*fn issueSnapshotSource(/p' \
    "$local_solo_source"
})"
test -n "$client_presentation_surface" ||
  fail "could not identify replicated client presentation construction"
if rg -n -- '\bauthority\b|inspection\(|persistent_id|replicatedId\(' \
  <<<"$client_presentation_surface"; then
  fail "client presentation reads authority inspection or durable identity"
fi

reject_matches \
  "the graphical DTO boundary reaches simulation or replay implementation" \
  '@import\("(incinerator_engine|sandbox_simulation|simulation_snapshot|sandbox_replay|simulation_diagnostics|crate_feature|character_feature|vehicle_feature|district_feature|interaction_feature|npc_feature|district_worker)"\)' \
  "$root/src/hosts/sandbox_host_contracts.zig"

for value_contract in \
  crate_contract character_contract vehicle_contract \
  interaction_feature_contract npc_contract sandbox_diagnostics_contract; do
  require_match \
    "the graphical DTO boundary does not import $value_contract" \
    "@import\(\"${value_contract}\"\)" \
    "$root/src/hosts/sandbox_host_contracts.zig"
done

reject_matches \
  "the graphical interaction mailbox imports mutable simulation authority" \
  '@import\("sandbox_simulation"\)' \
  "$root/src/hosts/sandbox_interaction.zig"
require_match \
  "the graphical interaction mailbox does not consume the canonical interaction contract" \
  '@import\("interaction_feature_contract"\)' \
  "$root/src/hosts/sandbox_interaction.zig"
reject_matches \
  "the graphical application imports the population implementation edge" \
  '@import\("population_feature"\)' \
  "$main_source"
require_match \
  "the graphical application does not consume the pure population contract" \
  '@import\("population_contract"\)' \
  "$main_source"

pure_authority_value_sources=(
  "$root/src/features/crates/contract.zig"
  "$root/src/features/character/contract.zig"
  "$root/src/features/vehicle/contract.zig"
  "$root/src/features/district/contract.zig"
  "$root/src/features/interaction/contract.zig"
  "$root/src/features/npc/contract.zig"
  "$root/src/features/npc/snapshot_validation.zig"
  "$root/src/features/population/contract.zig"
  "$root/src/district_worker_contract.zig"
  "$root/src/hosts/sandbox_diagnostics_contract.zig"
  "$root/src/hosts/sandbox_host_contracts.zig"
  "$authority_diagnostics_source"
  "$snapshot_source"
)
for pure_authority_value_source in "${pure_authority_value_sources[@]}"; do
  test -f "$pure_authority_value_source" ||
    fail "pure authority/value source is missing: ${pure_authority_value_source#"$root/"}"
done
reject_matches \
  "a pure authority/value source imports feature implementation, mutable simulation, replay, storage, or a visual/backend implementation" \
  '(@import[[:space:]]*\([[:space:]]*"([^"/]*/)*(crate_feature|character_feature|vehicle_feature|district_feature|interaction_feature|npc_feature|session_authority|sandbox_simulation|simulation_diagnostics|sandbox_replay|sandbox_save|save_slots|district_worker|jolt_physics|jolt_c|zflecs|sdl|renderer|physics_debug_gpu|mesh|texture|editor|zgui|shader_assets)(\.zig)?"|@cInclude[[:space:]]*\([[:space:]]*"(SDL|Jolt|jolt|jph)[^"]*")' \
  "${pure_authority_value_sources[@]}"

reject_matches \
  "the canonical simulation snapshot imports live authority, storage, feature implementation, or visual/backend code" \
  '(@import[[:space:]]*\([[:space:]]*"([^"/]*/)*(crate_feature|character_feature|vehicle_feature|district_feature|interaction_feature|npc_feature|session_authority|sandbox_simulation|simulation_diagnostics|sandbox_save|save_slots|district_worker|jolt_physics|jolt_c|zflecs|sdl|renderer|physics_debug_gpu|mesh|texture|editor|zgui|shader_assets)(\.zig)?"|@cInclude[[:space:]]*\([[:space:]]*"(SDL|Jolt|jolt|jph)[^"]*")' \
  "$root/src/hosts/simulation_snapshot.zig"
require_match \
  "the canonical simulation snapshot does not consume pure NPC snapshot validation" \
  '@import\("npc_snapshot_validation"\)' \
  "$root/src/hosts/simulation_snapshot.zig"

reject_matches \
  "the mutable simulation facade republishes a canonical value contract" \
  '^[[:space:]]*pub const [A-Za-z_][A-Za-z0-9_]*[[:space:]]*=[[:space:]]*(crates|characters|vehicles|districts|interactions|npcs|sandbox_host_contracts|sandbox_diagnostics|engine\.physics_debug)\.' \
  "$root/src/hosts/simulation.zig"
reject_matches \
  "a feature implementation root republishes canonical value declarations" \
  '^pub const [A-Za-z_][A-Za-z0-9_]*[[:space:]]*=' \
  "$root/src/features/crates/root.zig" \
  "$root/src/features/character/root.zig" \
  "$root/src/features/vehicle/root.zig" \
  "$root/src/features/district/root.zig" \
  "$root/src/features/interaction/root.zig" \
  "$root/src/features/npc/root.zig"
require_match \
  "the physics adapter does not consume the backend-neutral debug policy" \
  'const DebugConfig[[:space:]]*=[[:space:]]*physics_debug\.Config;' \
  "$root/src/physics.zig"
reject_matches \
  "the physics adapter republishes its backend-neutral debug policy" \
  '^[[:space:]]*pub const DebugConfig[[:space:]]*=' \
  "$root/src/physics.zig"

sandbox_contract_wiring="$({
  sed -n \
    '/const sandbox_host_contracts = b.createModule/,/^[[:space:]]*});/p' \
    "$root/tools/build/simulation_graph.zig"
})"
test -n "$sandbox_contract_wiring" ||
  fail "could not identify sandbox_host_contracts module wiring"
if rg -n -- 'module = (crates|character|vehicle|district|interaction|npc|district_worker|simulation_diagnostics)[[:space:]]*[,}]' \
  <<<"$sandbox_contract_wiring"; then
  fail "sandbox_host_contracts build wiring includes an implementation module"
fi

if rg -n -- 'addClientImport\([^\n]*"sandbox_simulation"' "$root/build.zig"; then
  fail "the graphical root receives sandbox_simulation as a direct build import"
fi

# Ordinary graphical player input must enter through PlayerRole. Bootstrap,
# editor, validation, and administrative paths may still use feature roles.
interactive_actions="$({
  sed -n \
    '/^[[:space:]]*fn submitInteractiveActions(/,/^[[:space:]]*fn submitInteractionToggle(/p' \
    "$main_source"
})"
interaction_toggle="$({
  sed -n \
    '/^[[:space:]]*fn submitInteractionToggle(/,/^[[:space:]]*fn maybeBootstrapCarryable(/p' \
    "$main_source"
})"
test -n "$interactive_actions" || fail "could not identify ordinary interactive actions"
test -n "$interaction_toggle" || fail "could not identify the carry interaction action"

if rg -n -i -- 'simulation\.(vehicles|interactions)\(\)\.submit|simulation\.submit(Vehicle|Interaction)[[:space:]]*\(' \
  <<<"$interactive_actions"; then
  fail "ordinary vehicle input bypasses PlayerRole"
fi
if rg -n -i -- 'simulation\.(vehicles|interactions)\(\)\.submit|simulation\.submit(Vehicle|Interaction)[[:space:]]*\(' \
  <<<"$interaction_toggle"; then
  fail "ordinary carry input bypasses PlayerRole"
fi
rg -q -- 'simulation\.player\(\)\.requestVehicleToggle\(' <<<"$interactive_actions" ||
  fail "ordinary enter/exit input is not routed through PlayerRole"
rg -q -- 'simulation\.player\(\)\.submitVehicleControl\(' <<<"$interactive_actions" ||
  fail "ordinary driving input is not routed through PlayerRole"
rg -q -- 'simulation\.player\(\)\.requestInteractionToggle\(' <<<"$interaction_toggle" ||
  fail "ordinary collect/drop input is not routed through PlayerRole"

require_match \
  "district prefetch does not use the prediction-facing PlayerRole" \
  'fn districtPrefetchPosition[\s\S]*simulation\.player\(\)\.focusPosition\(\)' \
  "$main_source"
require_match \
  "logical residency does not use the privileged authority value role" \
  'fn districtAuthorityFocusPosition[\s\S]*\.residency\(\)[\s\S]*\.authoritativeFocusPosition\(\)' \
  "$main_source"

require_match \
  "the graphical host does not compose the district-streaming owner" \
  '@import\("hosts/district_streaming_host\.zig"\)' \
  "$main_source"
require_match \
  "App does not own the opaque district-streaming allocation" \
  'district_streaming:[[:space:]]*\*district_streaming_host\.Owner' \
  "$main_source"
require_match \
  "district-streaming ownership is not opaque" \
  'pub const Owner[[:space:]]*=[[:space:]]*opaque' \
  "$district_streaming_host_source"
district_streaming_sources=(
  "$district_streaming_host_source"
  "$root/src/district_gpu_registry.zig"
  "$root/src/district_scene_adapter.zig"
  "$root/src/hosts/district_presentation.zig"
  "$root/src/hosts/district_content_catalog.zig"
)
reject_matches \
  "the district-streaming owner closure imports mutable authority, persistence, physics, or private feature implementations" \
  '@import[[:space:]]*\([[:space:]]*"([^"/]*/)*(local_solo_session|session_authority|sandbox_simulation|simulation_snapshot|sandbox_persistence|sandbox_save|save_slots|jolt_physics|jolt_c|zflecs|crate_feature|character_feature|vehicle_feature|district_feature|interaction_feature|npc_feature)(\.zig)?"' \
  "${district_streaming_sources[@]}"

authority_focus="$({
  sed -n '/fn districtAuthorityFocusPosition/,/^    }/p' "$main_source"
})"
test -n "$authority_focus" || fail "could not identify district authority focus"
if rg -n -- 'simulation\.(characters|vehicles)\(\)\.view\(' <<<"$authority_focus"; then
  fail "logical residency reads private character/vehicle authority views"
fi

# The embedded placement owns a client, a typed link, and one opaque authority
# placement. Semantic dispatch, admission, results, and replication stay in the
# single shared core instead of being reimplemented by a local protocol switch.
require_match \
  "local_solo does not compose the shared authority placement" \
  '@import\("session_authority"\)' \
  "$local_solo_source"
require_match \
  "local_solo does not construct EmbeddedAuthority" \
  'session_authority\.EmbeddedAuthority\.init' \
  "$local_solo_source"
require_match \
  "local_solo does not deliver client messages to the shared authority" \
  'authority\.session\(\)\.ingest\(' \
  "$local_solo_source"
require_match \
  "local_solo does not drain shared authority egress" \
  'authority\.session\(\)\.pollOutbound\(\)' \
  "$local_solo_source"
reject_matches \
  "local_solo imports mutable simulation or authority admission policy" \
  '@import\("(sandbox_simulation|gameplay_admission)"\)' \
  "$local_solo_source"
reject_matches \
  "local_solo reimplements shared protocol dispatch or snapshot construction" \
  '\.(hello|input|vehicle_input|vehicle_action|interaction_action|baseline_ack|snapshot_ack)[[:space:]]*=>|fn (publishSnapshot|ingestVehicleAction|ingestInteractionAction)|protocol\.Snapshot\.empty\(' \
  "$local_solo_source"
for routed_client_call in vehicleInput vehicleAction interactionAction; do
  require_match \
    "local_solo does not construct $routed_client_call through session_client" \
    "client\\.${routed_client_call}[[:space:]]*\\(" \
    "$local_solo_source"
done
require_match \
  "the shared authority core does not own semantic admission" \
  '@import\("gameplay_admission"\)' \
  "$root/src/session/authority.zig"
require_match \
  "the shared authority implementation is not private" \
  '^const AuthorityCore[[:space:]]*=[[:space:]]*struct' \
  "$root/src/session/authority.zig"
for authority_placement in DedicatedAuthority EmbeddedAuthority; do
  require_match \
    "$authority_placement is not an opaque placement handle" \
    "pub const ${authority_placement}[[:space:]]*=[[:space:]]*opaque" \
    "$root/src/session/authority.zig"
done
for forbidden_field in core simulation; do
  require_match \
    "authority role tests do not reject the $forbidden_field field" \
    "!@hasField\\(Role, \"${forbidden_field}\"\\)" \
    "$root/src/session/authority.zig"
done
for player_operation in \
  submitVehicleControl requestVehicleToggle requestInteractionToggle; do
  require_match \
    "PlayerRole is missing $player_operation" \
    "pub fn ${player_operation}[[:space:]]*\\(" \
    "$local_solo_source"
done

player_role_surface="$({
  sed -n '/^pub const PlayerRole = struct {/,/^pub const LifecycleRole = struct {/p' \
    "$local_solo_source"
})"
if rg -n -i -- 'authority\.(submit|tick)|owner\.submit(Vehicle|Interaction)\(' \
  <<<"$player_role_surface"; then
  fail "PlayerRole reaches authority or feature submission directly"
fi

for interpolation in interpolate interpolateVehicle interpolateCarryable interpolateNpc; do
  require_match \
    "embedded presentation is missing replicated-world ${interpolation}" \
    "replicated_world\.World\.${interpolation}[[:space:]]*\\(" \
    "$local_solo_source"
done
require_match \
  "embedded owned-character presentation ignores client prediction" \
  'client\.localPresentation\(\)' \
  "$local_solo_source"
require_match \
  "embedded owned-vehicle presentation ignores client prediction" \
  'client\.localVehiclePresentation\(\)' \
  "$local_solo_source"
require_match \
  "embedded interpolation is missing its snapshot-driven projection clock" \
  'fn projectionAlpha[\s\S]*projection_clock\.alpha' \
  "$local_solo_source"
require_match \
  "embedded NPC interpolation is missing its independent update clock" \
  'fn npcProjectionAlpha[\s\S]*npc_projection_clock\.alpha' \
  "$local_solo_source"
require_match \
  "authority input scheduling lacks a bounded per-target queue" \
  'const PendingInputs = struct[\s\S]*takeLatestDue' \
  "$root/src/session/authority.zig"
require_match \
  "replication acknowledges received input before authoritative application" \
  'snapshot\.acknowledged_input = target\.last_applied_input' \
  "$root/src/session/authority.zig"
require_match \
  "authority-cycle failures are not latched above the simulation runtime" \
  'fn latchCycleFault[\s\S]*first_cycle_fault' \
  "$root/src/session/authority.zig"
reject_matches \
  "embedded gameplay presentation bypasses the replicated client world" \
  'authority\.(characterPresentation|vehiclePresentation|interactionPresentation|npcPresentation)[[:space:]]*\(' \
  "$local_solo_source"

# The graphical owner may request persistence and inspect immutable feedback,
# but canonical bytes and the storage adapter remain inside sandbox_persistence.
require_match \
  "the graphical host no longer composes sandbox_persistence" \
  '@import\("sandbox_persistence"\)' \
  "$main_source"
reject_matches \
  "the graphical host can access canonical save bytes or durable storage" \
  '\b(OwnedSnapshot|SaveSlots|captureSnapshot|sandbox_save)\b' \
  "$main_source"
require_match \
  "sandbox_persistence does not own the durable save adapter" \
  '@import\("save_slots"\)' \
  "$root/src/hosts/sandbox_persistence.zig"
require_match \
  "sandbox_persistence does not expose immutable snapshot observations" \
  'pub const SnapshotObservation[[:space:]]*=[[:space:]]*struct' \
  "$root/src/hosts/sandbox_persistence.zig"
reject_matches \
  "Placement exposes canonical snapshot capture after composition" \
  'pub fn (persistence|issueSnapshotSource|captureSnapshot)[[:space:]]*\(' \
  "$local_solo_source"
require_match \
  "the persistence owner is not opaque at its public boundary" \
  'pub const Owner[[:space:]]*=[[:space:]]*opaque' \
  "$root/src/hosts/sandbox_persistence.zig"
require_match \
  "canonical capture bypasses operational quiescence" \
  'operationalQuiescenceReason\(\)' \
  "$local_solo_source"

require_match \
  "the graphical embedded authority clock is not fixed at 60 Hz" \
  'pub const tick_rate:[[:space:]]*u32[[:space:]]*=[[:space:]]*60;' \
  "$root/src/engine/fixed_step.zig"

# Enumerate the graphical network client's first-party Zig closure. This is an
# intentionally explicit closed set: adding a client dependency requires the
# gate owner to classify and scan it, instead of silently expanding authority.
client_sources=(
  "$mp2_client_source"
  "$root/src/mp2_presentation.zig"
  "$root/src/session/client.zig"
  "$root/src/session/replicated_world.zig"
  "$root/src/session/prediction.zig"
  "$root/src/session/vehicle_prediction.zig"
  "$root/src/session/client_clock.zig"
  "$root/src/session/reconnect_policy.zig"
  "$root/src/session/protocol.zig"
  "$root/src/session/identity.zig"
  "$root/src/session/transport_policy.zig"
  "$root/src/session/budgets.zig"
  "$root/src/adapters/transport/gns_direct.zig"
  "$root/src/sdl.zig"
  "$root/src/renderer.zig"
  "$root/src/primitives.zig"
  "$root/src/mesh.zig"
  "$root/src/camera.zig"
  "$root/src/texture.zig"
)
for client_source in "${client_sources[@]}"; do
  test -f "$client_source" || fail "client closure source is missing: ${client_source#"$root/"}"
done
reject_matches \
  "the graphical client closure imports authority, physics, storage, or feature internals" \
  '(@import[[:space:]]*\([^)]*(sandbox_simulation|simulation_snapshot|session_authority|jolt_physics|jolt_c|zflecs|save_slots|sandbox_save|sandbox_replay|crate_feature|character_feature|vehicle_feature|district_feature|interaction_feature|npc_feature|district_worker)|@cInclude[[:space:]]*\([^)]*(jolt|jph)|\bJPH_)' \
  "${client_sources[@]}"

client_imports="$({
  { rg -o --no-filename '@import\("[^"]+"\)' "${client_sources[@]}" ||
    test $? -eq 1; } |
    sed -E 's/^@import\("([^"]+)"\)$/\1/' |
    sort -u
})"
for imported in $client_imports; do
  case "$imported" in
    std|zmath|network_cohort_options|shader_assets|session_budgets|session_protocol|session_client|replicated_world|session_transport_policy|reconnect_policy|client_clock|gns_direct|mp2_presentation|session_identity|session_prediction|vehicle_prediction|sdl.zig|renderer.zig|primitives.zig|mesh.zig|camera.zig|texture.zig) ;;
    *) fail "unclassified dependency entered the graphical client closure: $imported" ;;
  esac
done

client_c_includes="$({
  { rg -o --no-filename '@cInclude\("[^"]+"\)' "${client_sources[@]}" ||
    test $? -eq 1; } |
    sed -E 's/^@cInclude\("([^"]+)"\)$/\1/' |
    sort -u
})"
for included in $client_c_includes; do
  case "$included" in
    gns_c_api.h|SDL3/SDL.h) ;;
    *) fail "unclassified C dependency entered the graphical client closure: $included" ;;
  esac
done

# Dedicated authority owns simulation/physics, but its source closure must stay
# free of windowing, GPU, editor, and client-side prediction dependencies.
authority_sources=(
  "$mp2_server_source"
  "$root/src/session/authority.zig"
  "$authority_diagnostics_source"
  "$root/src/session/gameplay_admission.zig"
  "$snapshot_source"
  "$root/src/session/protocol.zig"
  "$root/src/session/identity.zig"
  "$root/src/session/transport_policy.zig"
  "$root/src/session/budgets.zig"
  "$root/src/adapters/transport/gns_direct.zig"
  "$root/src/hosts/simulation.zig"
  "$root/src/hosts/simulation_snapshot.zig"
  "$root/src/hosts/simulation_diagnostics.zig"
  "$root/src/hosts/sandbox_host_contracts.zig"
  "$root/src/hosts/sandbox_diagnostics_contract.zig"
  "$root/src/hosts/district_replay_loader.zig"
  "$root/src/hosts/sandbox_navigation.zig"
  "$root/src/hosts/sandbox_replay.zig"
  "$root/src/district_worker.zig"
  "$root/src/district_worker_contract.zig"
  "$root/src/sandbox/district_recipe.zig"
  "$root/src/physics.zig"
  "$root/src/adapters/physics/jolt_c.zig"
  "$root/src/root.zig"
  "$root/src/engine"
  "$root/src/features"
)
reject_matches \
  "the dedicated authority closure imports visual, editor, or client-only code" \
  '(@import[[:space:]]*\([^)]*(sdl(\.zig)?|renderer(\.zig)?|physics_debug_gpu|mesh(\.zig)?|texture(\.zig)?|editor|sandbox_visual_resources|sandbox_controls|zgui|zmath|zmesh|zstbi|shader_assets|vulkan|d3d12|metal|mp2_presentation|session_client|replicated_world|client_clock|reconnect_policy|session_prediction|vehicle_prediction)|@cInclude[[:space:]]*\([^)]*(sdl|vulkan|d3d12|metal))' \
  "${authority_sources[@]}"

authority_imports="$({
  { rg -o --no-filename '@import\("[^"]+"\)' "${authority_sources[@]}" ||
    test $? -eq 1; } |
    sed -E 's/^@import\("([^"]+)"\)$/\1/' |
    sort -u
})"
for imported in $authority_imports; do
  case "$imported" in
    ../identity.zig|../transform.zig|builtin|character_contract|character_feature|contracts/diagnostics.zig|contracts/physics.zig|contracts/physics_debug.zig|contracts/rendering.zig|contracts/replay.zig|crate_contract|crate_feature|diagnostics.zig|district_contract|district_feature_contract|district_feature|district_replay_loader|district_worker_contract|district_worker|driver_contract|engine/bounded_queue.zig|engine/diagnostics.zig|engine/fixed_step.zig|engine/runtime.zig|engine_contracts|gameplay_admission|gns_direct|identity.zig|incinerator_engine|interaction_contract|interaction_feature_contract|interaction_feature|jolt_c|jolt_physics|navigation_contract|network_cohort_options|npc_contract|npc_feature|npc_snapshot_validation|sandbox_diagnostics_contract|sandbox_district_recipe|sandbox_host_contracts|sandbox_navigation|sandbox_replay|sandbox_simulation|session_authority|session_authority_diagnostics|session_budgets|session_identity|session_protocol|session_transport_policy|simulation_cohort_options|simulation_diagnostics|simulation_snapshot|snapshot_source|std|transform.zig|vehicle_contract|vehicle_feature|zflecs) ;;
    *) fail "unclassified dependency entered the dedicated authority closure: $imported" ;;
  esac
done

authority_c_includes="$({
  { rg -o --no-filename '@cInclude\("[^"]+"\)' "${authority_sources[@]}" ||
    test $? -eq 1; } |
    sed -E 's/^@cInclude\("([^"]+)"\)$/\1/' |
    sort -u
})"
for included in $authority_c_includes; do
  case "$included" in
    gns_c_api.h|joltc.h) ;;
    *) fail "unclassified C dependency entered the dedicated authority closure: $included" ;;
  esac
done
require_match \
  "the dedicated server no longer composes session_authority" \
  '@import\("session_authority"\)' \
  "$mp2_server_source"
require_match \
  "session_authority no longer composes sandbox_simulation" \
  '@import\("sandbox_simulation"\)' \
  "$root/src/session/authority.zig"

echo "M5_ARCHITECTURE_PASS graphical_authority=separate placement_surface=role_scoped player_actions=session_routed admission=shared presentation=replicated_gameplay persistence=owned_quiescent developer_owner=opaque district_streaming=opaque clock_hz=60 value_contracts=backend_free snapshot=authority_free client_closure=authority_free dedicated_closure=visual_free"
