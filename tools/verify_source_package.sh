#!/usr/bin/env bash

set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
zig=${ZIG:-zig}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

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
grep -Fxq 'CLEANUP_PLAN.md' "$tmp/package-files"
grep -Fxq 'src/main.zig' "$tmp/package-files"
grep -Fxq 'src/engine/runtime.zig' "$tmp/package-files"
grep -Fxq 'src/engine/contracts/physics_debug.zig' "$tmp/package-files"
grep -Fxq 'src/engine/contracts/replay.zig' "$tmp/package-files"
grep -Fxq 'src/engine/fixed_step.zig' "$tmp/package-files"
grep -Fxq 'src/features/crates/root.zig' "$tmp/package-files"
grep -Fxq 'src/features/character/root.zig' "$tmp/package-files"
grep -Fxq 'src/features/driver_contract.zig' "$tmp/package-files"
grep -Fxq 'src/features/vehicle/root.zig' "$tmp/package-files"
grep -Fxq 'src/features/district_contract.zig' "$tmp/package-files"
grep -Fxq 'src/features/navigation_contract.zig' "$tmp/package-files"
grep -Fxq 'src/features/npc/root.zig' "$tmp/package-files"
grep -Fxq 'src/features/population/root.zig' "$tmp/package-files"
grep -Fxq 'src/hosts/sandbox_navigation.zig' "$tmp/package-files"
grep -Fxq 'src/features/district/root.zig' "$tmp/package-files"
grep -Fxq 'src/features/interaction/root.zig' "$tmp/package-files"
grep -Fxq 'src/features/interaction_contract.zig' "$tmp/package-files"
grep -Fxq 'src/district_worker.zig' "$tmp/package-files"
grep -Fxq 'src/hosts/district_replay_loader.zig' "$tmp/package-files"
grep -Fxq 'src/district_gpu_registry.zig' "$tmp/package-files"
grep -Fxq 'src/district_scene_adapter.zig' "$tmp/package-files"
grep -Fxq 'src/content/root.zig' "$tmp/package-files"
grep -Fxq 'src/content/district_bundle.zig' "$tmp/package-files"
grep -Fxq 'src/content/catalog.zig' "$tmp/package-files"
grep -Fxq 'src/sandbox_controls.zig' "$tmp/package-files"
grep -Fxq 'src/sandbox_visual_resources.zig' "$tmp/package-files"
grep -Fxq 'src/hosts/headless.zig' "$tmp/package-files"
grep -Fxq 'src/hosts/headless_authority.zig' "$tmp/package-files"
grep -Fxq 'src/hosts/headless_config.zig' "$tmp/package-files"
grep -Fxq 'src/hosts/headless_content.zig' "$tmp/package-files"
grep -Fxq 'src/hosts/headless_clock.zig' "$tmp/package-files"
grep -Fxq 'src/hosts/external_producers.zig' "$tmp/package-files"
grep -Fxq 'src/adapters/platform/macos_signals.zig' "$tmp/package-files"
grep -Fxq 'src/hosts/simulation.zig' "$tmp/package-files"
grep -Fxq 'src/hosts/sandbox_interaction.zig' "$tmp/package-files"
grep -Fxq 'src/hosts/sandbox_replay.zig' "$tmp/package-files"
grep -Fxq 'src/hosts/sandbox_authoring.zig' "$tmp/package-files"
grep -Fxq 'src/hosts/sandbox_save.zig' "$tmp/package-files"
grep -Fxq 'src/adapters/storage/save_slots.zig' "$tmp/package-files"
grep -Fxq 'src/hosts/developer_profile.zig' "$tmp/package-files"
grep -Fxq 'src/hosts/developer_controls.zig' "$tmp/package-files"
grep -Fxq 'src/hosts/developer_diagnostics.zig' "$tmp/package-files"
grep -Fxq 'src/hosts/developer_visualization.zig' "$tmp/package-files"
grep -Fxq 'src/hosts/district_presentation.zig' "$tmp/package-files"
grep -Fxq 'src/hosts/district_content_catalog.zig' "$tmp/package-files"
grep -Fxq 'src/physics_debug_gpu.zig' "$tmp/package-files"
grep -Fxq 'src/editor/tools/physics_debug_tool.zig' "$tmp/package-files"
grep -Fxq 'src/editor/tools/diagnostics_tool.zig' "$tmp/package-files"
grep -Fxq 'src/editor/tools/crate_authoring_tool.zig' "$tmp/package-files"
grep -Fxq 'src/editor/tools/interaction_tool.zig' "$tmp/package-files"
grep -Fxq 'third_party/joltc-zig/build.zig' "$tmp/package-files"
grep -Fxq 'shaders/triangle.vert' "$tmp/package-files"
grep -Fxq 'tools/shader-toolchain/vcpkg.json' "$tmp/package-files"
! grep -Eq '^tools/shader-toolchain/dxil(/|$)' "$tmp/package-files"
grep -Fxq 'tools/build/macos.zig' "$tmp/package-files"
grep -Fxq 'tools/build/simulation_graph.zig' "$tmp/package-files"
grep -Fxq 'tools/build/dependency_cohort.zig' "$tmp/package-files"
grep -Fxq 'tools/build/validation_boundary.zig' "$tmp/package-files"
grep -Fxq 'tools/build/zgui_sdl3_gpu.zig' "$tmp/package-files"
grep -Fxq 'tools/build/headless_product.zig' "$tmp/package-files"
grep -Fxq 'tools/verify_headless_product.sh' "$tmp/package-files"
grep -Fxq 'tools/verify_headless_cold_product.sh' "$tmp/package-files"
grep -Fxq 'tools/verify_m3_headless_lifecycle.sh' "$tmp/package-files"
grep -Fxq 'tools/headless_boundary_test.zig' "$tmp/package-files"
grep -Fxq 'tools/headless_linkage_test.zig' "$tmp/package-files"
! grep -Eq '^tools/s[0-3]_measure\.zig$' "$tmp/package-files"
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
grep -Fxq 'docs/performance/m3-baseline.md' "$tmp/package-files"
grep -Fxq 'docs/performance/m3-baseline.json' "$tmp/package-files"
grep -Fxq 'docs/adr/010-developer-diagnostics-replay-and-debug-visualization.md' "$tmp/package-files"
grep -Fxq 'docs/adr/011-persistent-authoring-and-durable-save-slots.md' "$tmp/package-files"
grep -Fxq 'docs/adr/012-canonical-district-catalog-and-fixed-two-slot-streaming.md' "$tmp/package-files"
grep -Fxq 'docs/adr/013-feature-owned-carry-interaction-and-district-ownership.md' "$tmp/package-files"
grep -Fxq 'docs/adr/014-bounded-district-navigation-and-feature-owned-npc-population.md' "$tmp/package-files"
grep -Fxq 'docs/adr/015-macos-pre-server-readiness.md' "$tmp/package-files"
grep -Fxq 'docs/design/s4-developer-diagnostics.md' "$tmp/package-files"
grep -Fxq 'docs/design/s5-persistent-authoring.md' "$tmp/package-files"
grep -Fxq 'docs/design/s6-multi-district-content.md' "$tmp/package-files"
grep -Fxq 'docs/design/s7-interaction-ownership.md' "$tmp/package-files"
grep -Fxq 'docs/design/s8-navigation-population.md' "$tmp/package-files"
grep -Fxq 'docs/design/m3-pre-server-readiness.md' "$tmp/package-files"
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
! grep -Eq '^assets(/|$)' "$tmp/package-files"
! grep -Eq '(^|/)\.DS_Store$' "$tmp/package-files"

mkdir "$tmp/extracted"
tar -xzf "$package_tar" -C "$tmp/extracted"
package_root=$(find "$tmp/extracted" -mindepth 1 -maxdepth 1 -type d -print -quit)
test -n "$package_root"
(
  cd "$package_root"
  "$zig" build test-headless test-content test-content-cooker \
    test-district-content-catalog test-replay \
    test-navigation-contract test-sandbox-navigation \
    test-npc-feature test-population-feature test-physics \
    test-sandbox-authoring test-sandbox-interaction test-sandbox-save test-save-slots \
    test-s7-measure test-s8-measure test-m3-soak \
    test-external-producers test-headless-authority \
    check-replay check-s5-save check-s8-measure check-m3-soak -Deditor=false \
    -Dglslc=/definitely/missing/glslc \
    -Dspirv-cross=/definitely/missing/spirv-cross \
    --summary all
)

(
  cd "$package_root"
  "$zig" build -Dproduct=headless test test-m3-lifecycle --summary all
)

echo "Filtered source package membership and headless execution verified."
