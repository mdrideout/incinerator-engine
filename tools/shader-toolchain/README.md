# Locked shader toolchain

The normal build accepts `glslc` and `spirv-cross` from `PATH` for convenience.
Reproducible CI and release validation use this vcpkg manifest, whose registry
baseline and tool versions are exact-pinned.

Install the host tools into an isolated directory:

```sh
vcpkg install \
  --x-manifest-root=tools/shader-toolchain \
  --x-install-root=.shader-tools \
  --triplet=arm64-osx
```

Then select those exact executables explicitly:

```sh
zig build \
  -Dglslc="$PWD/.shader-tools/arm64-osx/tools/shaderc/glslc" \
  -Dspirv-cross="$PWD/.shader-tools/arm64-osx/tools/spirv-cross/spirv-cross"
```

`.shader-tools` is an example local install root and must not be committed.

This is an Apple-Silicon macOS toolchain. The active shader contract is GLSL to
SPIR-V intermediate to MSL. Future platform work starts with a new, independently
tested toolchain contract; no dormant Windows or Linux shader path is retained.
