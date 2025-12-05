# ADR-001: Shader Language and Cross-Compilation Strategy

**Status:** Accepted
**Date:** 2024-12-05
**Updated:** 2024-12-05
**Decision Makers:** Matt, Claude

## Context

The Incinerator Engine uses SDL3's GPU API for rendering, which requires platform-native shader formats:
- **macOS/iOS:** Metal Shading Language (MSL)
- **Windows:** DXIL (DirectX) or SPIR-V (Vulkan)
- **Linux:** SPIR-V (Vulkan)

**Important:** SDL3 GPU does **not** accept GLSL source code directly. It requires pre-compiled, platform-native shader bytecode. There is no runtime compilation option - this is a hard requirement, not an optimization.

We need to decide:
1. Which shader language to write source code in
2. How to compile shaders for each target platform
3. How to handle cross-platform distribution

## Decision

### Shader Source Language: GLSL 4.50

We will write all shaders in **GLSL (OpenGL Shading Language) version 4.50** with Vulkan semantics.

### Compilation Strategy: Compile All, Select at Runtime

**At build time:** Compile ALL platform formats regardless of host machine.
**At runtime:** Select the correct format for the current platform.

This ensures:
- Builds are reproducible on any development machine
- A single binary works on all platforms
- Dev and prod use identical compiled shaders

### Compilation Pipeline

```
                         GLSL Source (.vert, .frag)
                                    │
                                    ▼
                              ┌──────────┐
                              │  glslc   │
                              └────┬─────┘
                                   │
                                   ▼
                          SPIR-V Bytecode (.spv)
                                   │
           ┌───────────────────────┼───────────────────────┐
           │                       │                       │
           ▼                       ▼                       ▼
    ┌─────────────┐         ┌─────────────┐         ┌─────────────┐
    │   Keep for  │         │ spirv-cross │         │ spirv-cross │
    │   Vulkan    │         │   --msl     │         │   --hlsl    │
    └─────────────┘         └──────┬──────┘         └──────┬──────┘
           │                       │                       │
           ▼                       ▼                       ▼
      .spv files              .metal files            .hlsl files
    (Linux, Windows)        (macOS, iOS)             (Windows DX)
```

### Build Output Structure

```
shaders/
├── triangle.vert              # GLSL source
├── triangle.frag              # GLSL source
└── compiled/
    ├── triangle.vert.spv      # SPIR-V (Vulkan - Linux, Windows)
    ├── triangle.frag.spv
    ├── triangle.vert.metal    # MSL (macOS, iOS)
    ├── triangle.frag.metal
    ├── triangle.vert.hlsl     # HLSL (Windows DirectX) - future
    └── triangle.frag.hlsl
```

### Runtime Selection

```zig
const std = @import("std");
const builtin = @import("builtin");

const vertex_shader = switch (builtin.os.tag) {
    .macos, .ios => @embedFile("shaders/compiled/triangle.vert.metal"),
    .linux => @embedFile("shaders/compiled/triangle.vert.spv"),
    .windows => @embedFile("shaders/compiled/triangle.vert.spv"), // or .hlsl for DX12
    else => @compileError("Unsupported platform"),
};
```

### Tools Required

| Tool | Source | Purpose |
|------|--------|---------|
| `glslc` | shaderc (Homebrew: `brew install shaderc`) | GLSL → SPIR-V |
| `spirv-cross` | Khronos (Homebrew: `brew install spirv-cross`) | SPIR-V → MSL/HLSL |

## Rationale

### Why GLSL over MSL or HLSL?

1. **Industry Standard:** GLSL is the most widely used shader language. Tutorials, documentation, and community knowledge are abundant.

2. **Transferable Skills:** Knowledge of GLSL applies to:
   - Vulkan (native SPIR-V from GLSL)
   - OpenGL/WebGL (direct GLSL)
   - Unity/Unreal (similar syntax)

3. **Single Source of Truth:** Write once, compile to all platforms. No need to maintain separate MSL and HLSL versions.

4. **Tooling Maturity:** The GLSL → SPIR-V → MSL/HLSL pipeline is battle-tested by major engines and tools (Godot, BGFX, etc.).

### Why GLSL 4.50?

- Version 4.50 is Vulkan-compatible with `#version 450`
- Supports all modern GPU features (compute shaders, SSBOs, etc.)
- Explicit `layout(location = N)` bindings required by SPIR-V

### Why Compile All Formats?

| Approach | Pros | Cons |
|----------|------|------|
| **Compile all (chosen)** | Single binary works everywhere; reproducible builds | Slightly longer build time |
| Compile only host format | Faster builds | Must rebuild for each platform; inconsistent testing |

### Why Offline Compilation?

SDL3 GPU **requires** pre-compiled shaders. There is no runtime GLSL interpretation.

| Offline Compilation | Runtime Compilation |
|---------------------|---------------------|
| Required by SDL3 GPU | Not supported |
| Errors caught at build time | N/A |
| Consistent dev/prod behavior | N/A |
| No compiler in shipped binary | N/A |

### Why Dev and Prod Use Same Compiled Shaders?

- **Accuracy:** What you test is what ships
- **Debugging:** Shader bugs appear in dev, not just prod
- **No surprises:** No "works on my machine" shader issues

## Consequences

### Positive

- **Learning:** Team learns industry-standard GLSL
- **Portability:** Same shaders work on all platforms from single source
- **Debugging:** SPIR-V tools (spirv-val, spirv-dis) can validate/inspect bytecode
- **Future-proof:** SPIR-V is Khronos standard, widely supported
- **Reproducible:** Any dev machine produces identical shader binaries

### Negative

- **Build Complexity:** Additional build step for shaders
- **Tool Dependencies:** Developers must install shaderc and spirv-cross
- **Two-Stage Errors:** Compilation errors may occur at either stage (GLSL→SPIR-V or SPIR-V→MSL)
- **Build Time:** Compiling all formats takes longer than single format

### Neutral

- Shader hot-reloading will require triggering recompilation (can be automated in build.zig)

## Implementation Notes

### Compilation Commands

```bash
# GLSL → SPIR-V
glslc triangle.vert -o compiled/triangle.vert.spv
glslc triangle.frag -o compiled/triangle.frag.spv

# SPIR-V → MSL (always, for macOS/iOS)
spirv-cross --msl compiled/triangle.vert.spv --output compiled/triangle.vert.metal
spirv-cross --msl compiled/triangle.frag.spv --output compiled/triangle.frag.metal

# SPIR-V → HLSL (always, for Windows DirectX) - future
spirv-cross --hlsl compiled/triangle.vert.spv --output compiled/triangle.vert.hlsl
spirv-cross --hlsl compiled/triangle.frag.spv --output compiled/triangle.frag.hlsl
```

### Build Integration

Shader compilation will be integrated into `build.zig` as a custom build step:

1. Find all `.vert` and `.frag` files in `shaders/`
2. Run `glslc` to produce `.spv` files
3. Run `spirv-cross --msl` to produce `.metal` files
4. Run `spirv-cross --hlsl` to produce `.hlsl` files (future)
5. Continue with Zig compilation

The Zig code uses `@embedFile` to include the correct compiled shader at compile time based on target platform.

## References

- [GLSL 4.50 Specification](https://registry.khronos.org/OpenGL/specs/gl/GLSLangSpec.4.50.pdf)
- [SPIR-V Specification](https://registry.khronos.org/SPIR-V/specs/unified1/SPIRV.html)
- [spirv-cross GitHub](https://github.com/KhronosGroup/SPIRV-Cross)
- [shaderc GitHub](https://github.com/google/shaderc)
- [SDL3 GPU API](https://wiki.libsdl.org/SDL3/CategoryGPU)
