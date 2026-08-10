#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <absolute-environment-root>" >&2
  exit 2
fi

root=$1
case "$root" in
  /*) ;;
  *) echo "environment root must be absolute: $root" >&2; exit 2 ;;
esac

version=4.5.12
archive=blender-$version-macos-arm64.dmg
expected=f4afdca92c56a9e231e45226445e6750879a70a0d2322cee80d82ce021a99fb0
url=https://download.blender.org/release/Blender4.5/$archive
download_dir="$root/downloads"
apps_dir="$root/apps"
dmg="$download_dir/$archive"
app="$apps_dir/Blender-$version.app"
binary="$app/Contents/MacOS/Blender"

mkdir -p "$download_dir" "$apps_dir"
if [ ! -f "$dmg" ]; then
  curl --fail --location --output "$dmg.partial" "$url"
  mv "$dmg.partial" "$dmg"
fi
actual=$(shasum -a 256 "$dmg" | awk '{print $1}')
if [ "$actual" != "$expected" ]; then
  echo "Blender archive digest mismatch: expected $expected got $actual" >&2
  exit 1
fi

if [ ! -x "$binary" ]; then
  if [ -e "$app" ]; then
    echo "partial Blender application already exists: $app" >&2
    exit 1
  fi
  mount=$(mktemp -d "${TMPDIR:-/tmp}/incinerator-blender.XXXXXX")
  cleanup() {
    hdiutil detach "$mount" >/dev/null 2>&1 || true
    rmdir "$mount" >/dev/null 2>&1 || true
  }
  trap cleanup EXIT INT TERM
  hdiutil attach -nobrowse -readonly -mountpoint "$mount" "$dmg" >/dev/null
  ditto "$mount/Blender.app" "$app.partial"
  mv "$app.partial" "$app"
  hdiutil detach "$mount" >/dev/null
  rmdir "$mount"
  trap - EXIT INT TERM
fi

observed=$("$binary" --version | sed -n '1s/^Blender //p' | awk '{print $1}')
if [ "$observed" != "$version" ]; then
  echo "installed Blender version mismatch: expected $version got $observed" >&2
  exit 1
fi

echo "$binary"
