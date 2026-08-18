#!/usr/bin/env bash

set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
zig=${ZIG:-zig}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

reject_package_path() {
  local path="$1"
  if grep -Fxq -- "$path" "$tmp/package-files"; then
    echo "unexpected path in filtered source package: $path" >&2
    exit 1
  fi
}

reject_package_pattern() {
  local pattern="$1"
  if grep -Eq -- "$pattern" "$tmp/package-files"; then
    echo "unexpected path pattern in filtered source package: $pattern" >&2
    exit 1
  fi
}

test "$($zig version)" = 0.16.0

# Zig 0.16 copies a directory before applying build.zig.zon's package paths.
# Archive a cache-free source snapshot first so an in-tree package cache can
# never recursively become part of the package-membership proof.
COPYFILE_DISABLE=1 tar -C "$root" -czf "$tmp/input.tar.gz" \
  --exclude='./.git' \
  --exclude='./.zig-cache' \
  --exclude='./zig-pkg' \
  --exclude='./zig-out' \
  --exclude='./.shader-tools' \
  --exclude='./.claude' \
  .

mkdir "$tmp/work"
tar -xzf "$tmp/input.tar.gz" -C "$tmp/work"

(
  cd "$tmp/work"
  "$zig" fetch "$tmp/input.tar.gz" \
    --global-cache-dir "$tmp/global-cache" > "$tmp/hash"
)

package_tar=$(find "$tmp/global-cache/p" -type f -name '*.tar.gz' -print -quit)
test -n "$package_tar"
tar -tzf "$package_tar" | sed 's#^[^/]*/##' > "$tmp/package-files"

grep -Fxq 'build.zig' "$tmp/package-files"
grep -Fxq '.github/workflows/ci.yml' "$tmp/package-files"
grep -Fxq 'ARCHITECTURE_REVIEW.md' "$tmp/package-files"
grep -Fxq 'CLEANUP_PLAN.md' "$tmp/package-files"
grep -Fxq 'MULTIPLAYER_PLAN.md' "$tmp/package-files"
grep -Fxq 'OVERHAUL_PLAN.md' "$tmp/package-files"
grep -Fxq 'PLAN_001.md' "$tmp/package-files"
grep -Fxq 'README.md' "$tmp/package-files"
grep -Fxq 'skills/incinerator-incident-diagnostics/SKILL.md' "$tmp/package-files"
grep -Fxq 'skills/incinerator-incident-diagnostics/agents/openai.yaml' "$tmp/package-files"
grep -Fxq 'skills/incinerator-incident-diagnostics/references/reproduction.md' "$tmp/package-files"
grep -Fxq 'skills/incinerator-incident-diagnostics/references/schema.md' "$tmp/package-files"
grep -Fxq 'skills/incinerator-incident-diagnostics/scripts/summarize_incident.py' "$tmp/package-files"
grep -Fxq 'skills/incinerator-vehicle-tuning/SKILL.md' "$tmp/package-files"
grep -Fxq 'skills/incinerator-vehicle-tuning/agents/openai.yaml' "$tmp/package-files"
grep -Fxq 'skills/incinerator-vehicle-tuning/references/metrics.md' "$tmp/package-files"
grep -Fxq 'src/main.zig' "$tmp/package-files"
grep -Fxq 'src/engine/runtime.zig' "$tmp/package-files"
grep -Fxq 'src/engine/contracts/physics_debug.zig' "$tmp/package-files"
grep -Fxq 'src/session/authority.zig' "$tmp/package-files"
grep -Fxq 'src/session/authority_diagnostics.zig' "$tmp/package-files"
grep -Fxq 'src/session/client.zig' "$tmp/package-files"
grep -Fxq 'src/session/combat_presentation.zig' "$tmp/package-files"
grep -Fxq 'src/session/gameplay_trace.zig' "$tmp/package-files"
grep -Fxq 'src/session/gameplay_admission.zig' "$tmp/package-files"
grep -Fxq 'src/session/local_link.zig' "$tmp/package-files"
grep -Fxq 'src/session/local_solo.zig' "$tmp/package-files"
grep -Fxq 'src/session/protocol.zig' "$tmp/package-files"
grep -Fxq 'src/session/replicated_world.zig' "$tmp/package-files"
grep -Fxq 'src/session/room_coordinator.zig' "$tmp/package-files"
grep -Fxq 'src/session/room_ticket.zig' "$tmp/package-files"
grep -Fxq 'src/session/snapshot_source.zig' "$tmp/package-files"
grep -Fxq 'src/session/vehicle_prediction.zig' "$tmp/package-files"
grep -Fxq 'src/adapters/transport/gns_direct.zig' "$tmp/package-files"
grep -Fxq 'src/hosts/mp2_server.zig' "$tmp/package-files"
grep -Fxq 'src/hosts/mp2_client.zig' "$tmp/package-files"
grep -Fxq 'src/client_scene.zig' "$tmp/package-files"
grep -Fxq 'src/hosts/mp6_server.zig' "$tmp/package-files"
grep -Fxq 'src/hosts/mp6_listen_room.zig' "$tmp/package-files"
grep -Fxq 'src/hosts/mp6_listen_client.zig' "$tmp/package-files"
grep -Fxq 'tools/mp2_loopback.zig' "$tmp/package-files"
grep -Fxq 'tools/s11_measure.zig' "$tmp/package-files"
grep -Fxq 'tools/s13_measure.zig' "$tmp/package-files"
grep -Fxq 'tools/interaction_validation.zig' "$tmp/package-files"
grep -Fxq 'tools/mp3_acceptance.zig' "$tmp/package-files"
grep -Fxq 'tools/mp4_acceptance.zig' "$tmp/package-files"
grep -Fxq 'tools/mp3_shutdown_client.zig' "$tmp/package-files"
grep -Fxq 'tools/verify_mp3_process.sh' "$tmp/package-files"
grep -Fxq 'tools/verify_s11_listen_process.sh' "$tmp/package-files"
grep -Fxq 'tools/verify_s11_dedicated_process.sh' "$tmp/package-files"
grep -Fxq 'tools/verify_s14_listen_process.sh' "$tmp/package-files"
grep -Fxq 'tools/verify_s14_dedicated_process.sh' "$tmp/package-files"
grep -Fxq 'tools/mouse_capture_acceptance.zig' "$tmp/package-files"
grep -Fxq 'tools/verify_interaction_validation.sh' "$tmp/package-files"
grep -Fxq 'tools/build_gamenetworking_sockets.sh' "$tmp/package-files"
grep -Fxq 'src/engine/contracts/replay.zig' "$tmp/package-files"
grep -Fxq 'src/engine/fixed_step.zig' "$tmp/package-files"
grep -Fxq 'src/features/crates/contract.zig' "$tmp/package-files"
grep -Fxq 'src/features/crates/root.zig' "$tmp/package-files"
grep -Fxq 'src/features/character/contract.zig' "$tmp/package-files"
grep -Fxq 'src/features/character/root.zig' "$tmp/package-files"
grep -Fxq 'src/features/driver_contract.zig' "$tmp/package-files"
grep -Fxq 'src/features/vehicle/contract.zig' "$tmp/package-files"
grep -Fxq 'src/features/vehicle/root.zig' "$tmp/package-files"
grep -Fxq 'src/features/district_contract.zig' "$tmp/package-files"
grep -Fxq 'src/features/navigation_contract.zig' "$tmp/package-files"
grep -Fxq 'src/features/district/contract.zig' "$tmp/package-files"
grep -Fxq 'src/features/npc/contract.zig' "$tmp/package-files"
grep -Fxq 'src/features/npc/snapshot_validation.zig' "$tmp/package-files"
grep -Fxq 'src/features/npc/root.zig' "$tmp/package-files"
grep -Fxq 'src/features/population/contract.zig' "$tmp/package-files"
reject_package_path 'src/features/population/root.zig'
grep -Fxq 'src/features/vitals/contract.zig' "$tmp/package-files"
grep -Fxq 'src/features/vitals/root.zig' "$tmp/package-files"
grep -Fxq 'src/features/npc_encounter/contract.zig' "$tmp/package-files"
grep -Fxq 'src/features/npc_encounter/root.zig' "$tmp/package-files"
grep -Fxq 'src/hosts/sandbox_navigation.zig' "$tmp/package-files"
grep -Fxq 'src/hosts/sandbox_population.zig' "$tmp/package-files"
grep -Fxq 'src/sandbox/population_catalog.zig' "$tmp/package-files"
grep -Fxq 'src/features/district/root.zig' "$tmp/package-files"
grep -Fxq 'src/features/interaction/contract.zig' "$tmp/package-files"
grep -Fxq 'src/features/interaction/root.zig' "$tmp/package-files"
grep -Fxq 'src/features/interaction_contract.zig' "$tmp/package-files"
grep -Fxq 'src/district_worker_contract.zig' "$tmp/package-files"
grep -Fxq 'src/district_worker.zig' "$tmp/package-files"
grep -Fxq 'src/hosts/district_replay_loader.zig' "$tmp/package-files"
grep -Fxq 'src/district_gpu_registry.zig' "$tmp/package-files"
grep -Fxq 'src/district_scene_adapter.zig' "$tmp/package-files"
grep -Fxq 'src/district_streaming_host_test.zig' "$tmp/package-files"
grep -Fxq 'src/hosts/district_streaming_host.zig' "$tmp/package-files"
grep -Fxq 'src/content/root.zig' "$tmp/package-files"
grep -Fxq 'src/content/district_bundle.zig' "$tmp/package-files"
grep -Fxq 'src/content/catalog.zig' "$tmp/package-files"
grep -Fxq 'src/sandbox_controls.zig' "$tmp/package-files"
grep -Fxq 'src/sandbox/gameplay_scenarios.zig' "$tmp/package-files"
grep -Fxq 'src/sandbox/product_character_lifecycle.zig' "$tmp/package-files"
grep -Fxq 'src/sandbox/product_feedback.zig' "$tmp/package-files"
grep -Fxq 'src/sandbox/product_presentation_trace.zig' "$tmp/package-files"
grep -Fxq 'src/hosts/sandbox_population_catalog_test.zig' "$tmp/package-files"
grep -Fxq 'src/hosts/sandbox_product_population_test.zig' "$tmp/package-files"
grep -Fxq 'src/sandbox_visual_resources.zig' "$tmp/package-files"
grep -Fxq 'src/hosts/headless.zig' "$tmp/package-files"
grep -Fxq 'src/hosts/headless_authority.zig' "$tmp/package-files"
grep -Fxq 'src/hosts/headless_config.zig' "$tmp/package-files"
grep -Fxq 'src/hosts/headless_content.zig' "$tmp/package-files"
grep -Fxq 'src/hosts/headless_clock.zig' "$tmp/package-files"
grep -Fxq 'src/hosts/external_producers.zig' "$tmp/package-files"
grep -Fxq 'src/adapters/platform/macos_signals.zig' "$tmp/package-files"
grep -Fxq 'src/hosts/simulation.zig' "$tmp/package-files"
grep -Fxq 'src/hosts/simulation_snapshot.zig' "$tmp/package-files"
grep -Fxq 'src/hosts/sandbox_host_contracts.zig' "$tmp/package-files"
grep -Fxq 'src/hosts/sandbox_diagnostics_contract.zig' "$tmp/package-files"
grep -Fxq 'src/hosts/sandbox_value_contracts_test.zig' "$tmp/package-files"
grep -Fxq 'src/hosts/simulation_diagnostics.zig' "$tmp/package-files"
grep -Fxq 'src/hosts/sandbox_interaction.zig' "$tmp/package-files"
grep -Fxq 'src/hosts/sandbox_invocation.zig' "$tmp/package-files"
grep -Fxq 'src/hosts/sandbox_replay.zig' "$tmp/package-files"
grep -Fxq 'src/hosts/sandbox_authoring.zig' "$tmp/package-files"
grep -Fxq 'src/hosts/sandbox_save.zig' "$tmp/package-files"
grep -Fxq 'src/hosts/sandbox_persistence.zig' "$tmp/package-files"
grep -Fxq 'src/hosts/sandbox_developer_host.zig' "$tmp/package-files"
grep -Fxq 'src/sandbox_developer_host_test.zig' "$tmp/package-files"
grep -Fxq 'src/adapters/storage/save_slots.zig' "$tmp/package-files"
grep -Fxq 'src/hosts/developer_profile.zig' "$tmp/package-files"
grep -Fxq 'src/hosts/developer_controls.zig' "$tmp/package-files"
grep -Fxq 'src/hosts/developer_diagnostics.zig' "$tmp/package-files"
grep -Fxq 'src/hosts/developer_visualization.zig' "$tmp/package-files"
grep -Fxq 'src/hosts/district_presentation.zig' "$tmp/package-files"
grep -Fxq 'src/hosts/district_content_catalog.zig' "$tmp/package-files"
grep -Fxq 'src/physics_debug_gpu.zig' "$tmp/package-files"
grep -Fxq 'src/visibility_oracle.zig' "$tmp/package-files"
grep -Fxq 'src/editor/tools/physics_debug_tool.zig' "$tmp/package-files"
grep -Fxq 'src/editor/tools/diagnostics_tool.zig' "$tmp/package-files"
grep -Fxq 'src/editor/tools/crate_authoring_tool.zig' "$tmp/package-files"
grep -Fxq 'src/editor/tools/interaction_tool.zig' "$tmp/package-files"
grep -Fxq 'src/editor/tools/population_lab_tool.zig' "$tmp/package-files"
grep -Fxq 'third_party/joltc-zig/build.zig' "$tmp/package-files"
grep -Fxq 'shaders/triangle.vert' "$tmp/package-files"
grep -Fxq 'shaders/visibility.frag' "$tmp/package-files"
grep -Fxq 'tools/shader-toolchain/vcpkg.json' "$tmp/package-files"
reject_package_pattern '^tools/shader-toolchain/dxil(/|$)'
grep -Fxq 'tools/build/macos.zig' "$tmp/package-files"
grep -Fxq 'tools/build/simulation_graph.zig' "$tmp/package-files"
grep -Fxq 'tools/build/dependency_cohort.zig' "$tmp/package-files"
grep -Fxq 'tools/build/validation_boundary.zig' "$tmp/package-files"
grep -Fxq 'tools/build/zgui_sdl3_gpu.zig' "$tmp/package-files"
grep -Fxq 'tools/build/headless_product.zig' "$tmp/package-files"
grep -Fxq 'tools/verify_headless_product.sh' "$tmp/package-files"
grep -Fxq 'tools/verify_headless_cold_product.sh' "$tmp/package-files"
grep -Fxq 'tools/verify_m3_headless_lifecycle.sh' "$tmp/package-files"
grep -Fxq 'tools/verify_m5_architecture.sh' "$tmp/package-files"
grep -Fxq 'tools/verify_m6_architecture.sh' "$tmp/package-files"
grep -Fxq 'tools/verify_mp6_architecture.sh' "$tmp/package-files"
grep -Fxq 'tools/verify_mp6_process.sh' "$tmp/package-files"
grep -Fxq 'tools/verify_mp6_listen_process.sh' "$tmp/package-files"
grep -Fxq 'tools/verify_s10_dedicated_process.sh' "$tmp/package-files"
grep -Fxq 'tools/verify_s10_listen_process.sh' "$tmp/package-files"
grep -Fxq 'tools/verify_incident_hardening.sh' "$tmp/package-files"
grep -Fxq 'tools/mp6_lifecycle_acceptance.zig' "$tmp/package-files"
grep -Fxq 'tools/headless_boundary_test.zig' "$tmp/package-files"
grep -Fxq 'tools/headless_linkage_test.zig' "$tmp/package-files"
reject_package_pattern '^tools/s[0-3]_measure\.zig$'
grep -Fxq 'tools/s7_measure.zig' "$tmp/package-files"
grep -Fxq 'tools/s8_measure.zig' "$tmp/package-files"
grep -Fxq 'tools/m3_soak.zig' "$tmp/package-files"
grep -Fxq 'config/headless.example.json' "$tmp/package-files"
grep -Fxq 'config/headless-content.json' "$tmp/package-files"
grep -Fxq 'tools/content_cooker.zig' "$tmp/package-files"
grep -Fxq 'tools/content_bundle_verify.zig' "$tmp/package-files"
grep -Fxq 'tools/content_relocation_test.zig' "$tmp/package-files"
grep -Fxq 'tools/content_catalog_cooker.zig' "$tmp/package-files"
grep -Fxq 'tools/content_catalog_verify.zig' "$tmp/package-files"
grep -Fxq 'tools/content_catalog_relocation_test.zig' "$tmp/package-files"
grep -Fxq 'tools/s4_replay.zig' "$tmp/package-files"
grep -Fxq 'tools/s5_save.zig' "$tmp/package-files"
grep -Fxq 'fixtures/s3_district/district.gltf' "$tmp/package-files"
grep -Fxq 'fixtures/s3_district/PROVENANCE.md' "$tmp/package-files"
grep -Fxq 'fixtures/s6_east/district.gltf' "$tmp/package-files"
grep -Fxq 'fixtures/s6_east/PROVENANCE.md' "$tmp/package-files"
grep -Fxq 'fixtures/s6_catalog/catalog.txt' "$tmp/package-files"
grep -Fxq 'fixtures/s6_catalog/README.md' "$tmp/package-files"
grep -Fxq 'docs/design/s0-crate-lifecycle.md' "$tmp/package-files"
grep -Fxq 'docs/design/s1-character-slice.md' "$tmp/package-files"
grep -Fxq 'docs/design/s2-vehicle-slice.md' "$tmp/package-files"
grep -Fxq 'docs/design/s3-district-streaming.md' "$tmp/package-files"
grep -Fxq 'docs/design/s13-authored-population-and-sandbox-activity.md' "$tmp/package-files"
grep -Fxq 'docs/design/s13-population-evaluation-world.md' "$tmp/package-files"
grep -Fxq 'docs/validation/s13-authored-population-and-sandbox-activity.md' "$tmp/package-files"
grep -Fxq 'docs/adr/024-authored-population-intent-and-activity-slots.md' "$tmp/package-files"
grep -Fxq 'docs/adr/009-runtime-content-and-streaming.md' "$tmp/package-files"
grep -Fxq 'docs/performance/s0-baseline.json' "$tmp/package-files"
grep -Fxq 'docs/performance/s1-baseline.json' "$tmp/package-files"
grep -Fxq 'docs/performance/s2-baseline.json' "$tmp/package-files"
grep -Fxq 'docs/performance/s3a-baseline.md' "$tmp/package-files"
grep -Fxq 'docs/performance/s3a-baseline.json' "$tmp/package-files"
grep -Fxq 'docs/performance/s3b-baseline.md' "$tmp/package-files"
grep -Fxq 'docs/performance/s3c-baseline.md' "$tmp/package-files"
grep -Fxq 'docs/performance/s4c-baseline.md' "$tmp/package-files"
grep -Fxq 'docs/performance/s6-baseline.md' "$tmp/package-files"
grep -Fxq 'docs/performance/s7-baseline.md' "$tmp/package-files"
grep -Fxq 'docs/performance/s7-baseline.json' "$tmp/package-files"
grep -Fxq 'docs/performance/s8-baseline.md' "$tmp/package-files"
grep -Fxq 'docs/performance/s8-baseline.json' "$tmp/package-files"
grep -Fxq 'docs/performance/s13-baseline.md' "$tmp/package-files"
grep -Fxq 'docs/performance/s13-baseline.json' "$tmp/package-files"
grep -Fxq 'docs/performance/m3-baseline.md' "$tmp/package-files"
grep -Fxq 'docs/performance/m3-baseline.json' "$tmp/package-files"
grep -Fxq 'docs/adr/010-developer-diagnostics-replay-and-debug-visualization.md' "$tmp/package-files"
grep -Fxq 'docs/adr/011-persistent-authoring-and-durable-save-slots.md' "$tmp/package-files"
grep -Fxq 'docs/adr/012-canonical-district-catalog-and-fixed-two-slot-streaming.md' "$tmp/package-files"
grep -Fxq 'docs/adr/013-feature-owned-carry-interaction-and-district-ownership.md' "$tmp/package-files"
grep -Fxq 'docs/adr/014-bounded-district-navigation-and-feature-owned-npc-population.md' "$tmp/package-files"
grep -Fxq 'docs/adr/015-macos-pre-server-readiness.md' "$tmp/package-files"
grep -Fxq 'docs/adr/016-authority-session-topology.md' "$tmp/package-files"
grep -Fxq 'docs/adr/017-network-identity-protocol-and-replication.md' "$tmp/package-files"
grep -Fxq 'docs/adr/018-gamenetworkingsockets-and-steam-compatible-routing.md' "$tmp/package-files"
grep -Fxq 'docs/adr/019-authoritative-npc-encounter-and-replacement.md' "$tmp/package-files"
grep -Fxq 'docs/adr/020-gameplay-interaction-validation-and-observability.md' "$tmp/package-files"
grep -Fxq 'docs/adr/024-authored-population-intent-and-activity-slots.md' "$tmp/package-files"
grep -Fxq 'docs/design/gameplay-interaction-validation-and-observability.md' "$tmp/package-files"
grep -Fxq 'docs/validation/gameplay-interaction-validation-and-observability.md' "$tmp/package-files"
grep -Fxq 'docs/design/mp0-network-contract.md' "$tmp/package-files"
grep -Fxq 'docs/design/mp1-client-authority-separation.md' "$tmp/package-files"
grep -Fxq 'docs/design/mp2-1-transport-lifecycle.md' "$tmp/package-files"
grep -Fxq 'docs/design/mp3-prediction-and-fault-harness.md' "$tmp/package-files"
grep -Fxq 'docs/design/mp4-feature-replication-sequence.md' "$tmp/package-files"
grep -Fxq 'docs/design/mp4a-authoritative-vehicle-replication.md' "$tmp/package-files"
grep -Fxq 'docs/design/mp4a2-bounded-vehicle-prediction.md' "$tmp/package-files"
grep -Fxq 'docs/validation/mp2-acceptance-and-audit.md' "$tmp/package-files"
grep -Fxq 'docs/validation/mp3-acceptance.md' "$tmp/package-files"
grep -Fxq 'docs/validation/mp4a-acceptance.md' "$tmp/package-files"
grep -Fxq 'docs/validation/mp4a2-acceptance.md' "$tmp/package-files"
grep -Fxq 'docs/performance/mp3-baseline.md' "$tmp/package-files"
grep -Fxq 'docs/performance/mp4a-baseline.md' "$tmp/package-files"
grep -Fxq 'docs/design/s4-developer-diagnostics.md' "$tmp/package-files"
grep -Fxq 'docs/design/s5-persistent-authoring.md' "$tmp/package-files"
grep -Fxq 'docs/design/s6-multi-district-content.md' "$tmp/package-files"
grep -Fxq 'docs/design/s7-interaction-ownership.md' "$tmp/package-files"
grep -Fxq 'docs/design/s8-navigation-population.md' "$tmp/package-files"
grep -Fxq 'docs/design/m3-pre-server-readiness.md' "$tmp/package-files"
grep -Fxq 'docs/design/m5-client-authority-cohesion.md' "$tmp/package-files"
grep -Fxq 'docs/design/post-m5-transactional-authority-cycle.md' "$tmp/package-files"
grep -Fxq 'docs/design/mp6-playable-multiplayer-room-flow.md' "$tmp/package-files"
grep -Fxq 'docs/design/s10-damage-death-respawn.md' "$tmp/package-files"
grep -Fxq 'docs/design/s11-npc-encounter-combat-response.md' "$tmp/package-files"
grep -Fxq 'docs/performance/s11-baseline.md' "$tmp/package-files"
grep -Fxq 'docs/validation/m6-transactional-authority-cycle.md' "$tmp/package-files"
grep -Fxq 'docs/validation/mp6-playable-multiplayer-room-flow.md' "$tmp/package-files"
grep -Fxq 'docs/validation/s10-damage-death-respawn.md' "$tmp/package-files"
grep -Fxq 'docs/validation/s11-npc-encounter-combat-response.md' "$tmp/package-files"
grep -Fxq 'docs/validation/s0-acceptance.md' "$tmp/package-files"
grep -Fxq 'docs/validation/s1-acceptance.md' "$tmp/package-files"
grep -Fxq 'docs/validation/s2-headless-acceptance.md' "$tmp/package-files"
grep -Fxq 'docs/validation/s3a-headless-acceptance.md' "$tmp/package-files"
grep -Fxq 'docs/validation/s3b-acceptance.md' "$tmp/package-files"
grep -Fxq 'docs/validation/s3c-acceptance.md' "$tmp/package-files"
grep -Fxq 'docs/validation/s4a-acceptance.md' "$tmp/package-files"
grep -Fxq 'docs/validation/s4b-acceptance.md' "$tmp/package-files"
grep -Fxq 'docs/validation/s4c-acceptance.md' "$tmp/package-files"
grep -Fxq 'docs/validation/s5-acceptance.md' "$tmp/package-files"
grep -Fxq 'docs/validation/s6-acceptance.md' "$tmp/package-files"
grep -Fxq 'docs/validation/s7-acceptance.md' "$tmp/package-files"
grep -Fxq 'docs/validation/s8-acceptance.md' "$tmp/package-files"
grep -Fxq 'docs/validation/m3-acceptance.md' "$tmp/package-files"
grep -Fxq 'docs/validation/m5-client-authority-cohesion.md' "$tmp/package-files"
reject_package_pattern '^assets(/|$)'
reject_package_pattern '(^|/)\.DS_Store$'

mkdir "$tmp/extracted"
tar -xzf "$package_tar" -C "$tmp/extracted"
package_root=$(find "$tmp/extracted" -mindepth 1 -maxdepth 1 -type d -print -quit)
test -n "$package_root"
(
  cd "$package_root"
  "$zig" build test-headless test-content test-content-cooker \
    test-district-content-catalog test-replay \
    test-navigation-contract test-sandbox-navigation \
    test-npc-feature test-npc-encounter \
    test-population-contract test-vitals-feature test-physics \
    test-sandbox-value-contracts test-sandbox-controls \
    test-sandbox-population-catalog test-sandbox-population-placement \
    test-sandbox-population test-sandbox-product-population-host \
    test-sandbox-authoring test-sandbox-interaction test-sandbox-save test-save-slots \
    test-sandbox-persistence test-simulation-snapshot test-session-contracts \
    test-s7-measure test-s8-measure test-s11-measure test-m3-soak \
    test-external-producers test-headless-authority \
    check-replay check-s5-save check-s8-measure check-s11-measure check-m3-soak \
    verify-m6-architecture verify-mp6-room-architecture \
    -Deditor=false \
    -Dglslc=/definitely/missing/glslc \
    -Dspirv-cross=/definitely/missing/spirv-cross \
    --summary all
)

(
  cd "$package_root"
  "$zig" build -Dproduct=headless test test-m3-lifecycle --summary all
)

echo "Filtered source package membership, M5/M6/MP6/S11 boundaries, and extracted execution verified."
