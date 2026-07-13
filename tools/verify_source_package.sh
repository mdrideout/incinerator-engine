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
grep -Fxq 'src/main.zig' "$tmp/package-files"
grep -Fxq 'src/engine/runtime.zig' "$tmp/package-files"
grep -Fxq 'src/engine/fixed_step.zig' "$tmp/package-files"
grep -Fxq 'src/features/crates/root.zig' "$tmp/package-files"
grep -Fxq 'src/features/character/root.zig' "$tmp/package-files"
grep -Fxq 'src/features/driver_contract.zig' "$tmp/package-files"
grep -Fxq 'src/features/vehicle/root.zig' "$tmp/package-files"
grep -Fxq 'src/sandbox_controls.zig' "$tmp/package-files"
grep -Fxq 'src/sandbox_visual_resources.zig' "$tmp/package-files"
grep -Fxq 'src/hosts/headless.zig' "$tmp/package-files"
grep -Fxq 'src/hosts/simulation.zig' "$tmp/package-files"
grep -Fxq 'third_party/joltc-zig/build.zig' "$tmp/package-files"
grep -Fxq 'shaders/triangle.vert' "$tmp/package-files"
grep -Fxq 'tools/shader-toolchain/vcpkg.json' "$tmp/package-files"
grep -Fxq 'tools/shader-toolchain/dxil/vcpkg.json' "$tmp/package-files"
grep -Fxq 'tools/build/zgui_sdl3_gpu.zig' "$tmp/package-files"
grep -Fxq 'tools/headless_boundary_test.zig' "$tmp/package-files"
grep -Fxq 'tools/headless_linkage_test.zig' "$tmp/package-files"
grep -Fxq 'tools/s0_measure.zig' "$tmp/package-files"
grep -Fxq 'tools/s1_measure.zig' "$tmp/package-files"
grep -Fxq 'tools/s2_measure.zig' "$tmp/package-files"
grep -Fxq 'docs/design/s0-crate-lifecycle.md' "$tmp/package-files"
grep -Fxq 'docs/design/s1-character-slice.md' "$tmp/package-files"
grep -Fxq 'docs/design/s2-vehicle-slice.md' "$tmp/package-files"
grep -Fxq 'docs/performance/s0-baseline.json' "$tmp/package-files"
grep -Fxq 'docs/performance/s1-baseline.json' "$tmp/package-files"
grep -Fxq 'docs/performance/s2-baseline.json' "$tmp/package-files"
grep -Fxq 'docs/validation/s0-acceptance.md' "$tmp/package-files"
grep -Fxq 'docs/validation/s1-acceptance.md' "$tmp/package-files"
grep -Fxq 'docs/validation/s2-headless-acceptance.md' "$tmp/package-files"
! grep -Eq '^assets(/|$)' "$tmp/package-files"
! grep -Eq '(^|/)\.DS_Store$' "$tmp/package-files"

mkdir "$tmp/extracted"
tar -xzf "$package_tar" -C "$tmp/extracted"
package_root=$(find "$tmp/extracted" -mindepth 1 -maxdepth 1 -type d -print -quit)
test -n "$package_root"
(
  cd "$package_root"
  "$zig" build test-headless -Deditor=false \
    -Dglslc=/definitely/missing/glslc \
    -Dspirv-cross=/definitely/missing/spirv-cross \
    -Dshadercross=/definitely/missing/shadercross \
    --summary all
)

echo "Filtered source package membership and headless execution verified."
