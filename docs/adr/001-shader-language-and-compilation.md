# ADR-001: Shader Language and Cross-Compilation Strategy

**Status:** Accepted
**Date:** 2024-12-05
**Updated:** 2025-12-05
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
shaders/                           # GLSL source files (version controlled)
├── triangle.vert
├── triangle.frag
└── ...

src/shaders/compiled/              # Compiled shaders (gitignored, generated)
├── triangle.vert.spv              # SPIR-V (Vulkan - Linux, Windows)
├── triangle.frag.spv
├── triangle.vert.metal            # MSL (macOS, iOS)
├── triangle.frag.metal
├── triangle.vert.hlsl             # HLSL (Windows DirectX) - future
└── triangle.frag.hlsl
```

**Note:** Compiled shaders are placed in `src/shaders/compiled/` rather than `shaders/compiled/` because Zig's `@embedFile` can only access files within the module's package root (`src/`). This is a Zig language constraint.

### Runtime Selection

The renderer uses compile-time platform detection to embed the correct shader format:

```zig
// src/renderer.zig
const std = @import("std");
const builtin = @import("builtin");

const ShaderCode = struct {
    vertex: []const u8,
    fragment: []const u8,
    format: c.SDL_GPUShaderFormat,
};

fn getShaderCode() ShaderCode {
    return switch (builtin.os.tag) {
        .macos, .ios => .{
            .vertex = @embedFile("shaders/compiled/triangle.vert.metal"),
            .fragment = @embedFile("shaders/compiled/triangle.frag.metal"),
            .format = c.SDL_GPU_SHADERFORMAT_MSL,
        },
        // Linux and Windows use SPIR-V (Vulkan)
        else => .{
            .vertex = @embedFile("shaders/compiled/triangle.vert.spv"),
            .fragment = @embedFile("shaders/compiled/triangle.frag.spv"),
            .format = c.SDL_GPU_SHADERFORMAT_SPIRV,
        },
    };
}
```

This compiles the correct shader format directly into the binary at build time - no runtime file loading required.

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
# GLSL → SPIR-V (output to src/ for @embedFile access)
glslc shaders/triangle.vert -o src/shaders/compiled/triangle.vert.spv
glslc shaders/triangle.frag -o src/shaders/compiled/triangle.frag.spv

# SPIR-V → MSL (always, for macOS/iOS)
spirv-cross --msl src/shaders/compiled/triangle.vert.spv --output src/shaders/compiled/triangle.vert.metal
spirv-cross --msl src/shaders/compiled/triangle.frag.spv --output src/shaders/compiled/triangle.frag.metal

# SPIR-V → HLSL (always, for Windows DirectX) - future
spirv-cross --hlsl src/shaders/compiled/triangle.vert.spv --output src/shaders/compiled/triangle.vert.hlsl
spirv-cross --hlsl src/shaders/compiled/triangle.frag.spv --output src/shaders/compiled/triangle.frag.hlsl
```

### Build Integration

Shader compilation is integrated into `build.zig` as a dependency of the main executable:

```zig
// build.zig - shader compilation step
const shader_step = buildShaders(b);
exe.step.dependOn(shader_step);
```

The `buildShaders()` function:

1. Creates `src/shaders/compiled/` directory
2. For each shader in `shader_sources` (e.g., "triangle"):
   - Runs `glslc` on `.vert` and `.frag` files → produces `.spv`
   - Runs `spirv-cross --msl` on `.spv` files → produces `.metal`
3. Returns a step that the executable depends on

Shaders are compiled automatically on every `zig build`. The Zig compiler then uses `@embedFile` to include the correct compiled shader at compile time based on target platform.

### Adding New Shaders

To add a new shader:

1. Create `shaders/myshader.vert` and `shaders/myshader.frag`
2. Add `"myshader"` to the `shader_sources` array in `build.zig`
3. Reference in code: `@embedFile("shaders/compiled/myshader.vert.metal")`

## References

- [GLSL 4.50 Specification](https://registry.khronos.org/OpenGL/specs/gl/GLSLangSpec.4.50.pdf)
- [SPIR-V Specification](https://registry.khronos.org/SPIR-V/specs/unified1/SPIRV.html)
- [spirv-cross GitHub](https://github.com/KhronosGroup/SPIRV-Cross)
- [shaderc GitHub](https://github.com/google/shaderc)
- [SDL3 GPU API](https://wiki.libsdl.org/SDL3/CategoryGPU)
