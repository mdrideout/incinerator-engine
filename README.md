# Incinerator Engine

A 3D game engine built with Zig, SDL3, Jolt Physics, and ImGui.

## Tech Stack

| Component | Library | Purpose |
|-----------|---------|---------|
| Language | Zig 0.15.2+ | Systems programming |
| Windowing/Input | SDL3 | Cross-platform window, input, GPU API |
| Physics | Jolt (zphysics) | 3D physics simulation |
| Debug UI | ImGui (zgui) | Developer tools and overlays |

## Developer Environment Setup (macOS)

### Prerequisites

**1. Zig Compiler**

```bash
brew install zig
```

Verify installation:
```bash
zig version  # Should be 0.15.2 or later
```

**2. Shader Compilation Tools**

The engine uses GLSL shaders compiled to platform-native formats (Metal on macOS).

```bash
# GLSL to SPIR-V compiler
brew install shaderc

# SPIR-V to Metal/HLSL cross-compiler
brew install spirv-cross
```

Verify installation:
```bash
glslc --version
spirv-cross --version
```

### Building

```bash
# Build the engine
zig build

# Build and run
zig build run

# Run tests
zig build test
```

## Controls

| Key | Action |
|-----|--------|
| ESC | Quit |
| WASD | Movement (placeholder) |
| Mouse | Look (placeholder) |

## Architecture

See architectural design review docs in [/docs/adr](/docs/adr)


The engine implements the **Canonical Game Loop** with fixed timestep simulation:

```
┌─────────────────────────────────────────────────────────────┐
│ Phase 1: INPUT PUMP (Per-Frame)                             │
│ - Poll SDL events, buffer input state                       │
├─────────────────────────────────────────────────────────────┤
│ Phase 2: SIMULATION TICK (Fixed 120Hz)                      │
│ - Physics, gameplay logic at deterministic rate             │
├─────────────────────────────────────────────────────────────┤
│ Phase 3: PRESENTATION (Interpolated)                        │
│ - GPU rendering with interpolation for smooth visuals       │
└─────────────────────────────────────────────────────────────┘
```

## License

TBD