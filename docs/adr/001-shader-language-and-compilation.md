# ADR-001: Shader Language and Target-Specific Compilation

**Status:** Accepted, amended 2026-07-09

**Date:** 2024-12-05

**Decision Makers:** Matt, Claude

## Context

SDL3's GPU API consumes a shader format supported by the selected GPU driver. Incinerator needs one canonical shader source, build-time validation of the renderer-facing interface, reproducible release tools, and outputs that do not mutate the source tree.

The earlier version of this ADR said every backend format would be built on every host and selected at runtime. It also described generated files under `src/shaders/compiled`. Neither is the current design: the build produces only the selected target's format and exposes cache-generated assets as Zig modules.

## Decision

### Canonical source

Shaders are authored in GLSL 4.50 with Vulkan-style explicit locations, descriptor sets, and bindings. Shader compilation is an offline build concern; the shipped engine does not include a GLSL compiler.

### Target-specific output

The Zig target and, on Windows, the explicit backend option determine both the shader format embedded in the executable and the SDL GPU driver requested by the renderer:

| Zig target | Build output | SDL GPU driver | Runtime entry point | Support level |
|---|---|---|---|---|
| `aarch64-macos` | MSL generated through SPIR-V | `metal` | `main0` | Primary path |
| `x86_64-linux` | SPIR-V | `vulkan` | `main` | Supported target |
| `x86_64-windows-gnu` (default) | DXIL generated through SPIR-V | `direct3d12` | `main` | Intended release path; native evidence pending |
| `x86_64-windows-gnu -Dwindows-gpu=vulkan` | SPIR-V | `vulkan` | `main` | Explicit bootstrap fallback |

The build owns an offline DXIL path and defaults Windows to D3D12. The Vulkan path remains an explicit fallback when an SDL_shadercross/DXC host tool is unavailable. Offline generation and cross-link evidence are necessary but not sufficient: Windows remains unreleased until a hosted Windows build succeeds and a native D3D12 pipeline/runtime smoke passes.

Executables are target-specific. This ADR makes no claim that one binary or one set of embedded shader bytes runs on multiple operating systems.

Shader format selection does not imply a fixed render-target format. After SDL
claims the window, the renderer queries its actual swapchain format and selects
a supported depth-target format with `SDL_GPUTextureSupportsFormat`. Those
formats are supplied to every scene pipeline, depth texture, and ImGui pipeline;
BGRA8 and D32 are preferences/capabilities, not assumptions.

### Build graph and generated assets

For each selected target, the build graph is:

```text
GLSL source
    -> glslc -> SPIR-V intermediate
        -> target artifact
            -> SPIR-V directly for Vulkan
            -> spirv-cross --msl for Metal
            -> SDL_shadercross SPIR-V -> DXIL for D3D12
        -> spirv-cross --reflect -> JSON reflection
            -> cache-generated shader_assets and shader_reflections modules
                -> executable and shader contract tests
```

All intermediate and generated files are `std.Build.LazyPath` outputs in the Zig cache. A `WriteFiles` step assembles the generated modules and embeds the selected artifacts. The build must not write compiled shaders or reflection data into `src` or `shaders`.

`shader_assets` carries the target format, driver, entry-point metadata, and embedded vertex/fragment bytes. The renderer uses that metadata rather than independently guessing from the host OS.

### Reflection is a build contract

`zig build test-shaders` parses generated reflection JSON and verifies the interface used by SDL GPU pipeline creation:

- exactly one SPIR-V entry point named `main` with the expected stage;
- exact vertex input and stage output locations;
- exact texture descriptor sets and bindings;
- exact uniform-buffer sets, bindings, and block sizes.

The model vertex contract currently includes a 128-byte block containing the
MVP and inverse-transpose model matrix. This keeps object-space normals in the
fragment shader's declared world-space lighting frame under rotation and
non-uniform scale.

The reflection checks validate the canonical SPIR-V interface. A second artifact test checks the selected target container and entry-point contract: MSL source declares `main0`, SPIR-V starts with its binary magic, and DXIL uses a `DXBC` container with declared entry point `main`. That artifact check does not reflect DXIL resource bindings or prove native pipeline creation. New shaders are incomplete until both their compilation graph and renderer contract expectations are registered.

### Toolchain policy

Local development may resolve `glslc` and `spirv-cross` from `PATH` for convenience. That path is not a reproducibility guarantee.

CI and release validation use the base [`tools/shader-toolchain/vcpkg.json`](../../tools/shader-toolchain/vcpkg.json), including:

- vcpkg registry baseline `cd61e1e26a038e82d6550a3ebbe0fbbfe7da78e3`;
- shaderc `2026.2`;
- SPIRV-Cross `1.4.350.0`.

The Windows [`tools/shader-toolchain/dxil/vcpkg.json`](../../tools/shader-toolchain/dxil/vcpkg.json) manifest adds exact SDL_shadercross `3.0.0-preview2` and DirectX Shader Compiler `2026-05-27` packages. The exact executables are selected with `-Dglslc=...`, `-Dspirv-cross=...`, and, for DXIL, `-Dshadercross=...`. Host-specific vcpkg triplets produce isolated tool directories; those installed binaries are not committed.

## Rationale

- GLSL 4.50 provides one readable source language and a mature route to SPIR-V.
- Selecting one backend per target keeps the build graph honest about what the executable will request from SDL.
- Cache outputs preserve incremental-build semantics and keep generated artifacts out of version control.
- Reflection catches resource-layout drift before GPU pipeline creation or runtime rendering.
- Exact CI/release tools make tool upgrades reviewable as part of a compatibility cohort.

## Consequences

### Positive

- Shader source, renderer bindings, and target backend selection are tested together.
- Cross-compilation does not need to generate irrelevant backend formats.
- Normal builds leave the source tree clean.
- Local setup remains convenient while CI and release validation stay version-controlled.

### Negative

- Shader tools remain host prerequisites.
- Errors may arise in GLSL compilation, target translation, or reflection validation.
- Each new backend needs a real compiler/output path and backend-specific native validation.
- Windows remains unreleased until hosted Windows build evidence and a native D3D12 pipeline/runtime smoke pass, despite the implemented offline DXIL path.

## References

- [SDL3 GPU API](https://wiki.libsdl.org/SDL3/CategoryGPU)
- [GLSL 4.50 Specification](https://registry.khronos.org/OpenGL/specs/gl/GLSLangSpec.4.50.pdf)
- [SPIR-V Specification](https://registry.khronos.org/SPIR-V/specs/unified1/SPIRV.html)
- [shaderc](https://github.com/google/shaderc)
- [SPIRV-Cross](https://github.com/KhronosGroup/SPIRV-Cross)
- [`tools/shader-toolchain/README.md`](../../tools/shader-toolchain/README.md)
