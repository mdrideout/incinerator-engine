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

## Deferred platform notes

Linux/SteamOS and Windows are future platforms with no current build, shader,
runtime, packaging, or CI contract. The remainder of this section records prior
Windows toolchain exploration only; these commands are not maintained and may
fail until a future Windows port is explicitly started.

The sibling `dxil/vcpkg.json` manifest adds
exact-pinned SDL_shadercross and DirectX Shader Compiler packages. The manifest
also disables SDL's default host window-system features because this SDL copy
belongs only to the offline shader-cross CLI:

```powershell
vcpkg install `
  --x-manifest-root=tools/shader-toolchain/dxil `
  --x-install-root=.shader-tools `
  --triplet=x64-windows

$env:PATH = "$PWD/.shader-tools/x64-windows/bin;$env:PATH"

zig build -Dtarget=x86_64-windows-gnu `
  -Dglslc="$PWD/.shader-tools/x64-windows/tools/shaderc/glslc.exe" `
  -Dspirv-cross="$PWD/.shader-tools/x64-windows/tools/spirv-cross/spirv-cross.exe" `
  -Dshadercross="$PWD/.shader-tools/x64-windows/tools/sdl3-shadercross/shadercross.exe"
```

The `bin` directory must remain on `PATH` while running `shadercross.exe` so its
exact `dxcompiler.dll` and `dxil.dll` are used rather than a machine-global copy.

The dormant build currently contains `-Dwindows-gpu=vulkan` and D3D12 branches.
They are implementation leftovers, not supported options or release promises.
