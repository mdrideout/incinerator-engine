# Incinerator Engine - Development Plan

## Goal
Build a GTA III-style MMO game engine using Zig, SDL3, Jolt Physics, and ImGui.

## Rendering Choice: SDL3 GPU API
- Cross-platform abstraction over Vulkan/Metal/D3D12
- Modern shader-based pipeline
- Already part of SDL3 dependency
- Good fit for 3D game with open world

---

## Phase 1: Foundation ✅ COMPLETE

### ✅ Step 1.1: Window + Canonical Game Loop
**Status: COMPLETE**

Files created:
- `src/main.zig` - Entry point with canonical game loop
- `src/timing.zig` - High-precision frame timer (120Hz fixed timestep)
- `src/input.zig` - Buffered input system (keyboard, mouse, events)

Architecture implemented:
```
┌─────────────────────────────────────────────────────────────┐
│ Phase 1: INPUT PUMP (Per-Frame / Uncapped)                  │
│ - SDL_PollEvent drains OS events                            │
│ - Latches input state to InputBuffer struct                 │
├─────────────────────────────────────────────────────────────┤
│ Phase 2: SIMULATION TICK (Fixed 120Hz = 8.333ms)            │
│ - Accumulator pattern: while (accumulator >= TICK_RATE)     │
│ - Physics, gameplay logic consume buffered input            │
├─────────────────────────────────────────────────────────────┤
│ Phase 3: PRESENTATION (Interpolated)                        │
│ - alpha = accumulator / TICK_RATE                           │
│ - Ready for lerp(previous, current, alpha) when needed      │
└─────────────────────────────────────────────────────────────┘
```

### ✅ Step 1.2: SDL3 GPU Initialization
**Status: COMPLETE**

- Created `src/renderer.zig` with SDL_GPU device
- Created `src/sdl.zig` for shared C bindings
- Swapchain attached to window
- Command buffer / render pass pattern working
- Clear-to-color each frame

---

## Phase 2: 3D Rendering Basics

### ✅ Step 2.1: Shader Pipeline
**Status: COMPLETE**

Files created:
- `shaders/triangle.vert` - GLSL vertex shader
- `shaders/triangle.frag` - GLSL fragment shader
- `src/mesh.zig` - Vertex format, GPU buffer management
- `src/primitives.zig` - Built-in shape factories
- `src/world.zig` - Entity and scene management

Architecture documented in:
- `docs/adr/001-shader-language-and-compilation.md` - Shader strategy
- `docs/adr/002-module-architecture-and-layering.md` - Module organization

Features working:
- GLSL 4.50 shaders with Vulkan semantics
- Build-time compilation: GLSL → SPIR-V → Metal/HLSL
- Platform-aware shader loading via @embedFile
- Graphics pipeline with vertex layout
- Vertex buffer upload to GPU
- RGB gradient triangle rendering
- Layered module architecture (renderer/mesh/primitives/world)

### ✅ Step 2.2: 3D Camera
**Status: COMPLETE**

Files created/modified:
- `src/camera.zig` - First-person camera with yaw/pitch, view/projection matrices
- `src/primitives.zig` - Added createCube() with colored faces
- `src/renderer.zig` - Added uniform buffer support, drawMesh takes MVP matrix
- `src/main.zig` - Camera controls wired up
- `shaders/triangle.vert` - Added MVP uniform buffer

Features working:
- zmath integration for SIMD-optimized math
- Perspective projection with configurable FOV
- View matrix generation from camera position/orientation
- Uniform buffer pushing MVP matrix to shader
- WASD movement (forward/back/strafe)
- Q/E for vertical movement
- Right-click + drag for mouse look
- Unit cube with colored faces (6 colors, one per face)

### Step 2.3: Mesh Loading
- Basic OBJ or glTF loader
- Vertex buffers, index buffers
- Texture loading and sampling

---

## Phase 3: Engine Systems

### Step 3.1: ImGui Integration
- zgui with SDL3 GPU backend
- Debug windows (FPS graph, entity inspector, console)

### Step 3.2: Physics Integration
- Jolt physics world setup
- Ground plane + falling objects
- Debug visualization (wireframe colliders)

### Step 3.3: Entity/Component System
- Simple archetypal ECS or component bags
- Transform, Mesh, Physics components
- Scene graph for hierarchical transforms

---

## Phase 4: Game Features (Future)
- Asset pipeline (models, textures, audio)
- Networking foundation for MMO
- Open world streaming/chunking
- Character controller
- Vehicles (GTA-style)

---

## Current File Structure

```
src/
├── main.zig          # Entry point, App struct, game loop
├── renderer.zig      # SDL3 GPU device, pipelines, uniform buffers
├── camera.zig        # First-person camera, view/projection matrices
├── mesh.zig          # Vertex struct, Mesh type, buffer upload
├── primitives.zig    # Built-in shapes (triangle, cube)
├── world.zig         # Entity, Transform, World (scene management)
├── timing.zig        # FrameTimer, TICK_RATE, TICK_DURATION
├── input.zig         # InputBuffer, Key constants, MouseButton
├── sdl.zig           # Shared SDL3 C bindings
└── root.zig          # Library root (unused for now)

shaders/
├── triangle.vert     # GLSL vertex shader (with MVP uniform)
├── triangle.frag     # GLSL fragment shader
└── compiled/         # (gitignored) SPIR-V + Metal output

docs/adr/
├── 001-shader-language-and-compilation.md
└── 002-module-architecture-and-layering.md
```

---

## Next Task: Step 2.3 - Mesh Loading

Add support for loading 3D models from files (OBJ or glTF format).

**Note:** Depth testing should be added before mesh loading to ensure
proper 3D rendering (back faces shouldn't render in front of front faces).
