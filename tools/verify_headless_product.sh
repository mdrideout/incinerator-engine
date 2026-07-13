#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
    echo "usage: verify_headless_product.sh INSTALL_PREFIX" >&2
    exit 64
fi

prefix=$(cd "$1" && /bin/pwd -P)
cd /tmp
binary="$prefix/bin/incinerator_headless"

if [ ! -x "$binary" ]; then
    echo "missing executable headless product: $binary" >&2
    exit 1
fi

expected_entries='bin
bin/incinerator_headless
etc
etc/incinerator
etc/incinerator/headless
etc/incinerator/headless/config.example.json
share
share/incinerator
share/incinerator/headless
share/incinerator/headless/content.json'
actual_entries=$(
    cd "$prefix"
    /usr/bin/find . -mindepth 1 -print | /usr/bin/sed 's#^\./##' | LC_ALL=C /usr/bin/sort
)
if [ "$actual_entries" != "$expected_entries" ]; then
    echo "headless install allowlist mismatch" >&2
    echo "expected:" >&2
    echo "$expected_entries" >&2
    echo "actual:" >&2
    echo "$actual_entries" >&2
    exit 1
fi

if /usr/bin/find "$prefix" -type l -print | /usr/bin/grep -q .; then
    echo "headless install must not contain symbolic links" >&2
    exit 1
fi

file_description=$(/usr/bin/file "$binary")
case "$file_description" in
    *"Mach-O 64-bit executable arm64"*) ;;
    *)
        echo "headless product is not an Apple Silicon Mach-O executable: $file_description" >&2
        exit 1
        ;;
esac

linked_libraries=$(
    /usr/bin/otool -L "$binary" |
        /usr/bin/tail -n +2 |
        /usr/bin/awk '{ print $1 }'
)
if [ "$linked_libraries" != "/usr/lib/libSystem.B.dylib" ]; then
    echo "unexpected headless Mach-O linkage:" >&2
    echo "$linked_libraries" >&2
    exit 1
fi

if LC_ALL=C /usr/bin/strings -a "$binary" | /usr/bin/grep -Eiq \
    'sdl_|sdl3|libsdl|imgui|cgltf|stbi_|meshopt_|metal\.framework|quartzcore\.framework|appkit\.framework|libvulkan|libx11|libwayland|libgl\.so|libegl|d3d12\.dll|dxgi\.dll|dxcompiler\.dll|opengl32\.dll|user32\.dll|gdi32\.dll|injecteddeveloperdiagnosticfault|diagnostics\.injected_fault_probe|initwithdiagnosticfaultprobe|injectedinitfailure|injectedvehiclecreatefailure|injected_partial_write|injected_before_replace|injected_after_replace'
then
    echo "forbidden dependency or diagnostic-smoke marker found in installed headless product" >&2
    exit 1
fi

echo "headless product allowlist and Mach-O boundary verified"
