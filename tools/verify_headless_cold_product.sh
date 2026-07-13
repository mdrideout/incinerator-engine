#!/bin/sh
set -eu

if [ "$#" -ne 2 ]; then
    echo "usage: verify_headless_cold_product.sh SOURCE_ROOT ZIG_EXE" >&2
    exit 64
fi

source_root=$1
zig_exe=$2
work=$(/usr/bin/mktemp -d /tmp/incinerator-headless-cold.XXXXXX)
trap '/bin/rm -rf "$work"' EXIT HUP INT TERM

extracted="$work/source"
/bin/mkdir -p "$extracted"
for entry in .zigversion build.zig build.zig.zon config src third_party tools; do
    if [ -e "$source_root/$entry" ]; then
        /bin/cp -R "$source_root/$entry" "$extracted/"
    fi
done

# Every visual package points at an intentionally unreachable source. A cold
# headless build can succeed only if its graph never asks Zig to resolve one.
/usr/bin/perl -0pi -e '
    s{(\.(?:sdl|zgui|zmath|zmesh|zstbi)\s*=\s*\.\{.*?\.url\s*=\s*")[^"]+}{$1git+https://invalid.invalid/visual.git#0000000000000000000000000000000000000000}sg
' "$extracted/build.zig.zon"
replacement_count=$(/usr/bin/grep -c 'invalid.invalid' "$extracted/build.zig.zon")
if [ "$replacement_count" -ne 5 ]; then
    echo "failed to poison all five visual package sources" >&2
    exit 1
fi
if [ -e "$extracted/shaders" ] || [ -e "$extracted/fixtures" ]; then
    echo "cold headless extraction unexpectedly contains visual source assets" >&2
    exit 1
fi

global_cache="$work/global-cache"
/bin/mkdir -p "$global_cache/tmp"
for mode in Debug ReleaseFast; do
    local_cache="$work/cache-$mode"
    prefix="$work/install-$mode"
    /bin/mkdir -p "$local_cache" "$prefix"
    (
        cd "$extracted"
        PATH=/usr/bin:/bin "$zig_exe" build \
            --cache-dir "$local_cache" \
            --global-cache-dir "$global_cache" \
            --prefix "$prefix" \
            -Dproduct=headless \
            -Doptimize="$mode" \
            check-headless-product
        PATH=/usr/bin:/bin "$zig_exe" build \
            --cache-dir "$local_cache" \
            --global-cache-dir "$global_cache" \
            --prefix "$prefix" \
            -Dproduct=headless \
            -Doptimize="$mode" \
            install-headless-product
    )
    (
        cd /tmp
        PATH=/usr/bin:/bin /bin/sh \
            "$extracted/tools/verify_headless_product.sh" \
            "$prefix"
    )
done

echo "cold shaderless extracted headless product verified in Debug and ReleaseFast"
